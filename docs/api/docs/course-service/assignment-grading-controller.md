# Tài liệu chi tiết luồng API — course-service / AssignmentGradingController

Nơi lưu: `docs/api/docs/course-service/assignment-grading-controller.md`

Mục đích: giải thích chi tiết từng hàm/controller/service trong luồng xem kết quả chấm bài và danh sách nộp bài của giảng viên (AssignmentGradingController), bao gồm input, output, điều kiện tiên quyết, ví dụ request/response, và các mã lỗi có thể xảy ra. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`AssignmentGradingController` là REST controller của service `course-service`, trỏ về base path `/api/v1/assignments/{assignmentId}`. Nó cung cấp hai endpoint cho giảng viên (LECTURER) để xem auto-grading results và danh sách submissions của một bài tập:

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/assignments/{assignmentId}/results` | GET | Xem kết quả chấm bài (per-plan / per-step detail) của cả lớp hoặc một sinh viên | LECTURER |
| `/api/v1/assignments/{assignmentId}/submissions` | GET | Xem danh sách bài nộp của một bài tập | LECTURER |

Cả hai đều `@PreAuthorize("hasRole('LECTURER')")`, nhận `X-User-Id` từ header, hỗ trợ phân trang tuỳ chọn (`page`/`size`). Nếu bỏ trống cả hai, trả về `Page` bao toàn bộ danh sách (hỗ trợ ngược với FE dùng `ListPage` trên `meta.total`).

Controller giao tiếp với `AssignmentGradingService`, làm authority duy nhất về "giảng viên có thể xem assignment này hay không" — result-service và submission-service không có logic role/sở hữu, nên mọi kiểm tra sở hữu được thực hiện **trước** bất kỳ Feign call nào.

---

## 2. DTO liên quan

### 2.1 `StudentResultResponse` (dto/response)
Một kết quả chấm bài của một sinh viên cho một bài tập, dùng cho view chấm điểm của giảng viên.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `studentUserId` | UUID | ID người dùng (Keycloak sub) của sinh viên |
| `studentCode` | String | Mã sinh viên (được course-service enrichment từ roster lớp) |
| `studentName` | String | Họ tên sinh viên (được course-service enrichment từ roster lớp) |
| `exerciseScore` | BigDecimal | Điểm bài tập đã được tính toán sẵn bởi result-service (công thức weighted duy nhất) |
| `results` | `List<AssignmentResultResponse>` | Danh sách kết quả chi tiết từng plan/step |

Ghi chú: `exerciseScore` được result-service tính sẵn, course-service **không tự tính lại** để không sai lệch so với transcript. Điểm ở view chấm một assignment sẽ khác tổng transcript khi lớp có nhiều assignment.

### 2.2 `SubmissionResponse` (dto/response)
Một dòng bài nộp của một assignment, truyền thẳng từ submission-service qua Feign.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID bài nộp |
| `assignmentId` | UUID | ID bài tập |
| `studentId` | UUID | ID sinh viên (Keycloak sub) |
| `zipFileName` | String | Tên file zip nộp |
| `status` | String | Trạng thái nộp/chấm (PENDING, GRADING, DONE, FAILED, …) |
| `latest` | Boolean | Là bài nộp mới nhất hay không |
| `createdAt` | OffsetDateTime | Thời điểm nộp |
| `planId` | UUID | Null = nộp toàn bộ assignment; có giá trị = sinh viên chọn một plan cụ thể |
| `studentCode` | String | Mã sinh viên enrichment từ roster (course-service bổ sung) |
| `studentName` | String | Họ tên sinh viên enrichment từ roster (course-service bổ sung) |

### 2.3 `AssignmentGradingConfigDto` (dto/internal)
Tham số nội bộ gửi sang executor-service (không có envelope). Không dùng trực tiếp trong controller này nhưng là phần của ngữ cảnh grading.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID assignment |
| `classId` | UUID | ID lớp |
| `gradingStrategy` | String | Chiến lược chấm điểm |
| `dockerComposeTemplate` | String | Template docker-compose |
| `dockerComposePort` | Integer | Cổng container |
| `startupTimeoutMs` | Integer | Timeout khởi động |
| `executionTimeoutMs` | Integer | Timeout thực thi |
| `maxMemoryMb` | Integer | Giới hạn RAM |
| `maxCpu` | Double | Giới hạn CPU |

---

## 3. Chi tiết từng hàm

### 3.1 `results` — Xem kết quả chấm bài (per-plan / per-step detail)

**Vị trí:** `AssignmentGradingController.results(...)` → `AssignmentGradingService.results(...)`

**Endpoint:** `GET /api/v1/assignments/{assignmentId}/results`

**Path variable:**
- `assignmentId` (UUID): ID bài tập

**Header đầu vào:**
- `X-User-Id` (String, mặc định `"anonymous"`): ID giảng viên sở hữu

**Query params:**
| Param | Kiểu | Bắt buộc | Mặc định | Mô tả |
|-------|------|----------|----------|-------|
| `studentCode` | String | — | null | Mã sinh viên (roster code, ví dụ `SV0001`). Null/trống = trả về cả lớp |
| `includeSteps` | boolean | — | `false` | `true` đểFE xem chi tiết từng bước (step) của mỗi plan; `false` giữ payload nhỏ |
| `page` | Integer | — | null | Trang (0-based). Null = trả về toàn bộ danh sách (không phân trang server-side) |
| `size` | Integer | — | null | Kích thước trang. Null = trả về toàn bộ |

**Luồng xử lý (Controller → Service):**

1. **Controller:** Nhận `assignmentId`, `ownerId` (từ header `X-User-Id`, chuyển sang UUID), các query param. Gọi `assignmentGradingService.results(assignmentId, ownerId, studentCode, includeSteps, page, size)`. Trả về `ResponseEntity.ok(Page<StudentResultResponse>)`.
2. **Service `results`:**
   - **Bước 1 — Kiểm tra sở hữu:** gọi `requireOwnedAssignment(assignmentId, ownerId)`. Nếu không tìm thấy hoặc không thuộc về giảng viên → ném `ResourceNotFoundException("Assignment not found: " + assignmentId)`. Đây là 404, không bao giờ là 403, để id không sở hữu không thể phân biệt với id không tồn tại.
   - **Bước 2 — Lấy roster lớp:** `classId = assignment.getClassId()`. Gọi `rosterByUserId(classId)` để nạp danh sách sinh viên của lớp (map `studentUserId → ClassStudent`). Nếu `classId == null` (bài PRACTICE không gắn lớp) → roster trống.
   - **Bước 3 — Dịch mã sinh viên sang user id:** Nếu `studentCode` có giá trị, gọi `studentIdFor(roster, studentCode)` để tìm `studentUserId`. Nếu `studentCode` không blank mà không tìm thấy trong roster → trả về `Page.empty()` (danh sách rỗng, không ném lỗi, giữ không thể phân biệt "mã không tồn tại" và "chưa có kết quả nào").
   - **Bước 4 — Gọi result-service:** `resultServiceClient.assignmentResults(assignmentId, studentUserId, includeSteps)`. **Lỗi Feign không được swallow** (quy tắc degrade-gracefully không áp dụng ở đây): nếu result-service down/timeout → ném `ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, ...)` / 500, vì danh sách rỗng sẽ lừa giảng viên cho rằng "chưa ai nộp" và đưa ra quyết định chấm điểm sai.
   - **Bước 5 — Enrich code/tên sinh viên:**
     - Nếu `classId == null` (bài PRACTICE, không có roster): gọi `identityByUserId(...)` lấy danh sách `ClassStudent` theo `student_user_id` của các kết quả đã có.
     - Nếu có lớp: dùng roster đã nạp.
     - Với mỗi `StudentResultResponse`, nếu tìm thấy sinh viên trong identity/roster → gán `studentCode` và `studentName`. Nếu sinh viên đã rời khỏi roster → giữ nguyên `studentUserId` với code/name null (không ẩn dòng, tránh khiến view lớp trông như hoàn chỉnh).
   - **Bước 6 — Tổng hợp sinh viên chưa có kết quả (chỉ khi xem cả lớp và có lớp):** Nếu `studentUserId == null` và `classId != null`: duyệt roster, đối với mỗi sinh viên chưa có trong `byUser` → tạo `StudentResultResponse` với `exerciseScore = BigDecimal.ZERO` (tạm thời, không phải điểm chấm thực), `results = List.empty()`. Sinh viên chưa có user id (imported nhưng chưa liên kết) → bỏ qua (tránh hàng null-keyed làm bẫy click trên view của giảng viên).
   - **Bước 7 — Sắp xếp:** Sắp xếp theo `studentCode` (nulls last) để cột sinh viên ổn định khi render lại.
   - **Bước 8 — Phân trang:** Nếu `page` hoặc `size` null → trả về `new PageImpl<>(ordered)` (toàn bộ danh sách). Nếu có cả hai → tính `from`, `to`, trả về `new PageImpl<>(subList, PageRequest.of(page, size), ordered.size())`.

**Ví dụ request (xem cả lớp):**
```http
GET /api/v1/assignments/16cebadb-2485-4494-be5b-7f6641887559/results?includeSteps=false&page=0&size=20
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):**
```json
{
  "content": [
    {
      "studentUserId": "e4ab4157-8970-4169-90fb-b88d788a124c",
      "studentCode": "b22dckh024",
      "studentName": "Nguyen Van A",
      "exerciseScore": "8.50",
      "results": [
        {
          "planId": "7e31465c-2764-4848-abf3-854832c64361",
          "planName": "Câu 1: Tạo sinh viên mới",
          "planWeight": 100,
          "score": 8.5,
          "stepResults": [...]
        }
      ]
    }
  ],
  "pageable": { "pageNumber": 0, "pageSize": 20, ... },
  "totalElements": 1,
  "totalPages": 1,
  "last": true,
  ...
}
```

**Ví dụ request (xem một sinh viên theo mã):**
```http
GET /api/v1/assignments/16cebadb-2485-4494-be5b-7f6641887559/results?studentCode=b22dckh024&includeSteps=true
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Mã lỗi có thể xảy ra:**
- `404 ResourceNotFoundException`: assignment không tồn tại hoặc không thuộc về giảng viên gọi.
- `500`: result-service không khả dụng (lỗi Feign không được swallow).
- `401/403`: không có quyền LECTURER.

---

### 3.2 `submissions` — Xem danh sách bài nộp của một assignment

**Vị trí:** `AssignmentGradingController.submissions(...)` → `AssignmentGradingService.submissions(...)`

**Endpoint:** `GET /api/v1/assignments/{assignmentId}/submissions`

**Path variable:**
- `assignmentId` (UUID): ID bài tập

**Header đầu vào:**
- `X-User-Id` (String, mặc định `"anonymous"`): ID giảng viên sở hữu

**Query params:**
| Param | Kiểu | Bắt buộc | Mặc định | Mô tả |
|-------|------|----------|----------|-------|
| `studentCode` | String | — | null | Mã sinh viên. Null/trống = trả về toàn bộ danh sách bài nộp |
| `page` | Integer | — | null | Trang (0-based). Null = trả về toàn bộ |
| `size` | Integer | — | null | Kích thước trang. Null = trả về toàn bộ |

**Luồng xử lý (Controller → Service):**

1. **Controller:** Nhận `assignmentId`, `ownerId` (từ header `X-User-Id`), các query param. Gọi `assignmentGradingService.submissions(assignmentId, ownerId, studentCode, page, size)`. Trả về `ResponseEntity.ok(Page<SubmissionResponse>)`.
2. **Service `submissions`:**
   - **Bước 1 — Kiểm tra sở hữu:** gọi `requireOwnedAssignment(assignmentId, ownerId)`. Nếu không tìm thấy → `ResourceNotFoundException`.
   - **Bước 2 — Lấy roster lớp:** `classId = assignment.getClassId()`. Gọi `rosterByUserId(classId)`.
   - **Bước 3 — Dịch mã sinh viên sang user id:** Nếu `studentCode` có giá trị, gọi `studentIdFor(roster, studentCode)`. Nếu không tìm thấy → trả về `Page.empty()`.
   - **Bước 4 — Gọi submission-service:** `submissionInternalClient.listByAssignment(assignmentId, page, size)`. Trả về `Page<SubmissionResponse>`. Lấy danh sách nội dung (`getContent()`).
   - **Bước 5 — Enrich code/tên sinh viên:** Tương tự `results`, nếu `classId == null` (PRACTICE) thì dùng `identityByUserId` theo `student_id` của các submission; nếu có lớp thì dùng roster. Với mỗi dòng, gán `studentCode`/`studentName` nếu tìm thấy.
   - **Bước 6 — Lọc theo sinh viên (nếu có studentCode):** Nếu `studentUserId != null` → lọc rows giữ những dòng có `studentId` trùng. Nếu null → giữ toàn bộ.
   - **Bước 7 — Phân trang:** Nếu `page` hoặc `size` null → trả về `new PageImpl<>(narrowed)`. Nếu có cả hai → tính `from`, `to`, trả về `new PageImpl<>(subList, PageRequest.of(page, size), narrowed.size())`.

**Ví dụ request (xem tất cả bài nộp):**
```http
GET /api/v1/assignments/16cebadb-2485-4494-be5b-7f6641887559/submissions?page=0&size=20
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):**
```json
{
  "content": [
    {
      "id": "c49eb1e3-1234-5678-90ab-cdef12345678",
      "assignmentId": "16cebadb-2485-4494-be5b-7f6641887559",
      "studentId": "e4ab4157-8970-4169-90fb-b88d788a124c",
      "zipFileName": "student-management-solution.zip",
      "status": "DONE",
      "latest": true,
      "createdAt": "2026-11-01T10:21:58.494+07:00",
      "planId": null,
      "studentCode": "b22dckh024",
      "studentName": "Nguyen Van A"
    }
  ],
  "pageable": { "pageNumber": 0, "pageSize": 20, ... },
  "totalElements": 1,
  "totalPages": 1,
  "last": true,
  ...
}
```

**Mã lỗi có thể xảy ra:**
- `404 ResourceNotFoundException`: assignment không tồn tại hoặc không thuộc về giảng viên gọi.
- `500`: submission-service không khả dụng (lỗi Feign).
- `401/403`: không có quyền LECTURER.

---

## 4. Các hàm private helper trong AssignmentGradingService

### 4.1 `requireOwnedAssignment(UUID assignmentId, UUID ownerId)`
- **Input:** assignmentId, ownerId.
- **Output:** `Assignment` entity.
- **Làm gì:** Truy vấn `assignmentRepository.findByIdAndOwnerId(assignmentId, ownerId)`. Nếu không tìm thấy → ném `ResourceNotFoundException("Assignment not found: " + assignmentId)`. Được gọi đầu tiên ở cả hai handler, trước mọi Feign call, để id không sở hữu không bao giờ leakage sang downstream service.

### 4.2 `rosterByUserId(UUID classId)`
- **Input:** classId.
- **Output:** `Map<UUID, ClassStudent>` (key là `studentUserId`).
- **Làm gì:** Nếu `classId == null` → trả về map rỗng. Ngược lại gọi `classStudentRepository.findAllByClassId(classId)`, thu gom thành map. Nếu có `student_user_id` trùng nhau → lấy phần tử đầu tiên (không ném exception như `Collectors.toMap` mặc định), khớp với hành vi của `findByClassIdAndStudentCode` trả về `Optional`.

### 4.3 `identityByUserId(Collection<UUID> userIds)`
- **Input:** tập hợp user id.
- **Output:** `Map<UUID, ClassStudent>`.
- **Làm gì:** Nếu null/trống → map rỗng. Ngược lại gọi `classStudentRepository.findAllByStudentUserIdIn(userIds)`, lọc bỏ phần tử có `studentUserId` null, thu gom thành map (trùng key → lấy phần tử đầu tiên). Dùng khi assignment là PRACTICE (không có lớp, không có roster sẵn) nhưng vẫn cần enrich code/tên từ các sinh viên đã từng tham gia ít nhất một lớp.

### 4.4 `studentIdFor(Map<UUID, ClassStudent> roster, String studentCode)`
- **Input:** roster map, mã sinh viên.
- **Output:** `Optional<UUID>` (studentUserId).
- **Làm gì:** Nếu `studentCode` null/trống → trả về `Optional.empty()`. Ngược lại quét roster, tìm entry có `studentCode` khớp (trim, so sánh chính xác), lấy `studentUserId`, lọc bỏ null, trả về phần tử đầu tiên. Trả về empty khi mã không thuộc lớp này, hoặc sinh viên có mã nhưng chưa có user id (imported nhưng chưa liên kết) — cả hai đều là "không có sinh viên khớp", không thể phân biệt với "không có dòng nào".

---

## 5. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 404 | Assignment không tồn tại / không thuộc giảng viên gọi | `AssignmentGradingService.requireOwnedAssignment` |
| 500 | result-service / submission-service không khả dụng (lỗi Feign) | `AssignmentGradingService.results` / `submissions` (không swallow) |
| 401/403 | Không có quyền LECTURER / auth lỗi | Spring Security (`@PreAuthorize`) |
| 200 (danh sách rỗng) | `studentCode` không nằm trong roster, hoặc chưa có kết quả/nộp nào | `results` / `submissions` trả về `Page.empty()` |

---

## 6. Luồng dữ liệu từ đầu đến cuối (ví dụ xem kết quả cả lớp)

```
Giảng viên (FE)
   │ GET /api/v1/assignments/{id}/results?includeSteps=false&page=0&size=20
   │ header X-User-Id: 2be57808-...
   ▼
Gateway (xác thực JWT, stamps X-User-Id từ token)
   │
   ▼
course-service: AssignmentGradingController.results()
   │ 1. Chuyển ownerId String → UUID
   │ 2. Gọi AssignmentGradingService.results(assignmentId, ownerId, studentCode, includeSteps, page, size)
   ▼
AssignmentGradingService.results()
   │ 3. requireOwnedAssignment → kiểm tra assignment tồn tại & sở hữu (404 nếu không)
   │ 4. rosterByUserId(classId) → nạp danh sách sinh viên lớp
   │ 5. (nếu có studentCode) studentIdFor → dịch mã sang userId
   │ 6. resultServiceClient.assignmentResults(...) → gọi result-service (Feign)
   │ 7. Enrich studentCode/studentName từ roster hoặc identityByUserId
   │ 8. Tổng hợp sinh viên chưa nộp: exerciseScore = 0, results = []
   │ 9. Sắp xếp theo studentCode, phân trang theo page/size
   │ 10. Trả về Page<StudentResultResponse>
   ▼
AssignmentGradingController.results()
   │ 11. Trả về ResponseEntity.ok(Page<StudentResultResponse>)
   ▼
Gateway → FE nhận danh sách kết quả chấm bài có phân trang
```

---

*Tài liệu này là phần tiếp theo của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/course-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
