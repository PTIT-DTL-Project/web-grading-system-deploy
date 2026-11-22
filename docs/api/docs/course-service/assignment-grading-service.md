# AssignmentGradingService — màn chấm bài của giảng viên (course-service)

Bổ sung cho `assignment-grading-controller.md`. Service này **không tự tính điểm**: nó kiểm tra
quyền sở hữu, gọi `result-service` / `submission-service`, rồi làm giàu dữ liệu bằng roster của lớp.

- Lớp: `course-service/service/AssignmentGradingService.java`
- Controller: `AssignmentGradingController` — 2 endpoint dưới `/api/v1/assignments/{assignmentId}`
- Client: `ResultServiceClient` (Feign), `SubmissionInternalClient` (Feign)
- Bảng DB đọc: `assignments`, `class_students`

---

## 1. Nguyên tắc thiết kế

1. **course-service là nơi duy nhất quyết định quyền**: `result-service` và `submission-service`
   không có logic role/ownership. Vì vậy mọi hàm ở đây kiểm tra owner **trước** khi gọi Feign, để
   một `assignmentId` không thuộc giảng viên không bao giờ chạm tới service khác.
2. **Không `@Transactional`**: mỗi lời gọi repository là một read ngắn; bọc transaction quanh 2 lời gọi
   HTTP sẽ giữ connection DB qua thời gian chờ mạng.
3. **Lỗi phụ thuộc phải nổi lên**: `results()` cố ý **không** nuốt exception của `result-service`.
   Trả danh sách rỗng sẽ bị hiểu là "chưa ai nộp bài" và có thể khiến giảng viên kết luận sai → 500.
4. **Không bịa dòng**: chỉ màn "cả lớp" mới tổng hợp thêm sinh viên chưa có kết quả (điểm 0 tạm thời).

---

## 2. Bảng tổng hợp hàm

| Hàm | Input | Output | Gọi ngoài |
|---|---|---|---|
| `results(assignmentId, ownerId, studentCode, includeSteps, page, size)` | 2 UUID, String, boolean, 2 Integer | `Page<StudentResultResponse>` | `POST/GET internal/results/assignment/{id}` (Feign) |
| `submissions(assignmentId, ownerId, studentCode, page, size)` | 2 UUID, String, 2 Integer | `Page<SubmissionResponse>` | `GET internal/submissions/assignment/{id}` (Feign) |

Helper private: `requireOwnedAssignment`, `rosterByUserId`, `identityByUserId`, `studentIdFor`,
`traceFeign` (2 overload).

---

## 3. `results(...)` — kết quả chấm tự động theo bài

### 3.1 Input

| Tham số | Kiểu | Ý nghĩa |
|---|---|---|
| `assignmentId` | UUID | path `{assignmentId}` |
| `ownerId` | UUID | `X-User-Id` do gateway đóng dấu |
| `studentCode` | String | null/rỗng = cả lớp; có giá trị = lọc 1 sinh viên theo **mã roster** |
| `includeSteps` | boolean | `true` → kèm chi tiết từng bước; `false` → payload nhỏ |
| `page`, `size` | Integer | null cả hai = trả toàn bộ (PageImpl 1 trang) |

### 3.2 Các bước

```
1. requireOwnedAssignment(assignmentId, ownerId)        → 404 nếu không sở hữu
2. classId  = assignment.classId                        (null với PRACTICE)
   roster   = rosterByUserId(classId)                   → Map<studentUserId, ClassStudent>
3. wantedId = studentIdFor(roster, studentCode)
   nếu studentCode có giá trị mà wantedId rỗng → return Page.empty()
4. groups = Feign assignmentResults(assignmentId, studentUserId, includeSteps)
5. identity = (classId == null) ? identityByUserId(userIds trong groups) : roster
6. với mỗi group: gán studentCode/studentName từ identity (nếu tìm thấy)
7. nếu studentUserId == null && classId != null:  tổng hợp sinh viên còn thiếu
8. sắp xếp theo studentCode (nulls last)
9. phân trang nếu page/size != null
```

### 3.3 Bước 7 — tổng hợp sinh viên chưa có kết quả

| Điều kiện | Hành vi |
|---|---|
| Đang xem **cả lớp** (`studentCode` rỗng) và bài thuộc lớp | mỗi sinh viên trong roster chưa có group được thêm dòng `exerciseScore = 0`, `results = []` |
| Đang xem **1 sinh viên** | **không** tổng hợp (không bịa dòng cho người không có kết quả) |
| Bài `PRACTICE` (không có lớp) | **không** tổng hợp (không có roster) |
| Dòng roster chưa liên kết tài khoản (`studentUserId == null`) | bị bỏ qua — không thể key/drill-down |

Điểm 0 ở đây là **0 tạm thời** ("chưa chấm"), không phải 0 đã chấm. Nó giúp bảng cả lớp không trông
như đã hoàn tất khi còn sinh viên chưa nộp.

### 3.4 Bước 9 — phân trang

| `page` / `size` | Kết quả |
|---|---|
| cả hai null | `new PageImpl<>(ordered)` — toàn bộ danh sách trong 1 trang, `total = size` |
| có giá trị | cắt `[page*size, page*size + size)`, `PageRequest.of(page, size)`, `total = ordered.size()` |

`from` được kẹp vào `[0, size]` nên `page` vượt quá không gây exception (trả trang rỗng).

### 3.5 Output

`Page<StudentResultResponse>`; một phần tử:

| Trường | Kiểu | Nguồn |
|---|---|---|
| `studentUserId` | UUID | result-service |
| `studentCode`, `studentName` | String | **course-service** làm giàu từ roster |
| `exerciseScore` | BigDecimal | result-service (công thức max-per-plan, xem `result-service.md`) |
| `results` | `List<AssignmentResultResponse>` | result-service; mỗi phần tử là 1 plan đã chấm |

`exerciseScore` **không** được tính lại ở đây, nên không thể lệch với `result-service`.

---

## 4. `submissions(...)` — danh sách bài nộp của bài

### 4.1 Các bước

```
1. requireOwnedAssignment
2. roster   = rosterByUserId(classId)
3. wantedId = studentIdFor(roster, studentCode);  không khớp → Page.empty()
4. fetched  = Feign listByAssignment(assignmentId, page, size)
5. identity = (classId == null) ? identityByUserId(studentIds trong fetched) : roster
6. với mỗi row: gán studentCode/studentName (nếu tìm thấy)
7. nếu có wantedId: lọc rows theo studentUserId
8. page/size null → PageImpl(narrowed)
   ngược lại      → cắt lại narrowed theo page/size, total = narrowed.size()
```

### 4.2 Output

`Page<SubmissionResponse>`; một phần tử:

| Trường | Kiểu | Nguồn |
|---|---|---|
| `id`, `assignmentId`, `studentId`, `zipFileName`, `status`, `latest`, `createdAt`, `planId` | nhiều | submission-service (truyền thẳng) |
| `studentCode`, `studentName` | String | course-service làm giàu từ roster |

`status` là trạng thái của **submission**, không phải kết quả chấm:
`PENDING → GRADING → DONE | FAILED`.

### 4.3 Lưu ý về phân trang + lọc 1 sinh viên

`page`/`size` được **forward xuống submission-service ngay từ đầu**; việc lọc theo `studentCode` xảy
ra **sau** khi trang đã được cắt. Vì vậy khi vừa truyền `studentCode` vừa truyền `page/size`, kết quả
là "trong trang N của bài, các dòng của sinh viên đó" — không phải "trang N của riêng sinh viên đó".
FE hiện không gửi `page/size` khi xem 1 sinh viên, nên trường hợp này chỉ gặp khi gọi tay.

---

## 5. Helper

| Helper | Input | Output | Ghi chú |
|---|---|---|---|
| `requireOwnedAssignment(assignmentId, ownerId)` | 2 UUID | `Assignment` | 404 `Assignment not found: {id}` |
| `rosterByUserId(classId)` | UUID (có thể null) | `Map<UUID, ClassStudent>` | null → map rỗng; trùng `studentUserId` thì **dòng đầu thắng** |
| `identityByUserId(userIds)` | `Collection<UUID>` | `Map<UUID, ClassStudent>` | dùng cho bài `PRACTICE` (không có roster lớp) |
| `studentIdFor(roster, studentCode)` | Map + String | `Optional<UUID>` | blank/không khớp/chưa liên kết → empty |
| `traceFeign(name, Supplier)` | tên span + lambda | giá trị trả về | span Tempo, ghi error, đóng span |

---

## 6. Map dữ liệu

### 6.1 Kết quả Feign ↔ response công khai

`ResultServiceClient.assignmentResults` trả `List<StudentResultResponse>` và **chính record đó** được
dùng làm response công khai (không có DTO thứ hai) — chỉ bổ sung 2 trường roster:

| Trường | Trước khi làm giàu | Sau khi làm giàu |
|---|---|---|
| `studentUserId` | có | giữ nguyên |
| `studentCode` | null | từ `class_students` |
| `studentName` | null | từ `class_students` |
| `exerciseScore` | có | giữ nguyên |
| `results[]` | có | giữ nguyên |

Nếu sinh viên đã rời roster: giữ `studentUserId`, `studentCode/studentName` = null, **không ẩn dòng**
(ẩn đi sẽ làm bảng lớp trông đầy đủ giả tạo).

### 6.2 `AssignmentResultResponse` (1 plan)

Truyền thẳng từ result-service, field-for-field:

| Trường | Kiểu | Ghi chú |
|---|---|---|
| `id`, `submissionId`, `assignmentId`, `studentId`, `planId` | UUID | |
| `planWeight` | Integer | trọng số plan tại thời điểm chấm |
| `scope` | String | `FULL` (chấm cả bài) / `PLAN` (chấm 1 plan) |
| `score`, `maxScore` | BigDecimal | |
| `status` | String | `DONE` / `FAILED` / … |
| `summaryLog` | String | log tổng hợp của lần chấm |
| `latest` | Boolean | còn là lần mới nhất của scope đó hay không |
| `startedAt`, `completedAt` | OffsetDateTime | |
| `steps` | `List<AssignmentResultStepResponse>` | null khi `includeSteps=false` |

### 6.3 `SubmissionResponse`

| Trường | Nguồn |
|---|---|
| `id`, `assignmentId`, `studentId`, `zipFileName`, `status`, `latest`, `createdAt`, `planId` | submission-service |
| `studentCode`, `studentName` | course-service (roster) |

---

## 7. Bảng lỗi

| HTTP | Tình huống | Nguồn |
|---|---|---|
| 404 | bài không tồn tại / của giảng viên khác | `requireOwnedAssignment` |
| 403 | token không có `ROLE_LECTURER` | `@PreAuthorize` |
| 500 | `result-service` hoặc `submission-service` lỗi/timeout | Feign exception — **cố ý không nuốt** |
| 200 | `studentCode` không có trong lớp | `Page.empty()` (không lỗi) |
| 200 | trang vượt quá số dòng | trang rỗng |

---

## 8. Luồng dữ liệu

```
GET /api/v1/assignments/{assignmentId}/results?studentCode=&includeSteps=true&page=&size=
  → AssignmentGradingController.results
  → requireOwnedAssignment                        (assignments.owner_id = JWT sub)
  → class_students của classId                    (roster: code, name, user_id)
  → [studentCode?] roster code → studentUserId    (không khớp → 200 [])
  → Feign GET result-service /api/v1/internal/results/assignment/{id}
        ?studentUserId=&includeSteps=
        ← [{ studentUserId, exerciseScore, results:[{plan…, steps:[…]}] }]
  → làm giàu code/name (bài PRACTICE: tra class_students theo student_user_id)
  → [cả lớp] tổng hợp sinh viên chưa có kết quả: exerciseScore=0, results=[]
  → sort theo studentCode → phân trang
  → 200 Page<StudentResultResponse>

GET /api/v1/assignments/{assignmentId}/submissions?studentCode=&page=&size=
  → requireOwnedAssignment → roster
  → Feign GET submission-service /api/v1/internal/submissions/assignment/{id}?page=&size=
  → làm giàu code/name
  → [studentCode?] lọc theo studentUserId
  → phân trang lại (nếu có page/size)
  → 200 Page<SubmissionResponse>
```
