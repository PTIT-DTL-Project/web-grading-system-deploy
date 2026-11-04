# Tài liệu chi tiết luồng API — course-service / ScoreController

Nơi lưu: `docs/api/docs/course-service/score-controller.md`

Mục đích: giải thích chi tiết từng hàm/controller/service trong luồng quản lý điểm số (score) của course-service, bao gồm input, output, điều kiện tiên quyết, ví dụ request/response, và các mã lỗi có thể xảy ra. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`ScoreController` là REST controller của service `course-service`, trỏ về base path `/api/v1/classes`. Nó cung cấp các endpoint cho giảng viên (LECTURER) để quản lý các thành phần điểm (score components), nhập điểm sinh viên, xem điểm và bảng điểm trung bình (transcript).

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/classes/{id}/score-components` | GET | Lấy danh sách thành phần điểm của lớp | LECTURER |
| `/api/v1/classes/{id}/score-components` | PUT | Thay thế toàn bộ thành phần điểm của lớp | LECTURER |
| `/api/v1/classes/{id}/students/{studentCode}/scores` | PUT | Cập nhật điểm của một sinh viên (nhập thủ công) | LECTURER |
| `/api/v1/classes/{id}/students/{studentCode}/scores` | GET | Xem chi tiết điểm của một sinh viên | LECTURER |
| `/api/v1/classes/{id}/transcript` | GET | Xem bảng điểm trung bình của toàn bộ lớp (phân trang) | LECTURER |

Tất cả endpoint đều `@PreAuthorize("hasRole('LECTURER')")`, nhận `X-User-Id` từ header. Controller giao tiếp với `ScoreService` để thực hiện logic nghiệp vụ.

---

## 2. DTO liên quan

### 2.1 `ScoreComponentRequest` (dto/request)
Dùng cho request tạo/cập nhật một thành phần điểm.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `type` | ScoreComponentType | ✅ | Loại thành phần: `ATTENDANCE`, `EXERCISE`, `FINAL_EXAM`, ... |
| `weight` | BigDecimal | ✅ | Trọng số (phải tổng = 1.000, FINAL_EXAM ≥ 0.40) |

### 2.2 `ScoreComponentResponse` (dto/response)
Trả về thông tin một thành phần điểm.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID thành phần |
| `classId` | UUID | ID lớp |
| `type` | ScoreComponentType | Loại thành phần |
| `weight` | BigDecimal | Trọng số |
| `createdAt` | OffsetDateTime | Thời điểm tạo |
| `deletedAt` | OffsetDateTime | Thời điểm xóa mềm (nếu có) |

### 2.3 `StudentScoreRequest` (dto/request)
Dùng cho request nhập điểm một sinh viên.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `componentType` | ScoreComponentType | ✅ | Loại thành phần điểm |
| `score` | BigDecimal | ✅ | Điểm số (ví dụ 8.5) |

### 2.4 `StudentScoresResponse` (dto/response)
Kết quả xem điểm chi tiết của một sinh viên.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `studentCode` | String | Mã sinh viên |
| `entries` | `List<StudentScoreEntryResponse>` | Danh sách điểm từng thành phần |
| `total` | BigDecimal | Tổng điểm (nếu đầy đủ) |
| `letterGrade` | String | Hệ chữ cái (A, B, C, D, F) |
| `gpa` | Double | Điểm GPA |

Lớp lồng `StudentScoreEntryResponse`:
| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `type` | ScoreComponentType | Loại thành phần |
| `weight` | BigDecimal | Trọng số |
| `score` | BigDecimal | Điểm số (null nếu chưa nhập) |

### 2.5 `TranscriptEntryResponse` (dto/response)
Một dòng trong bảng điểm trung bình (transcript) của lớp.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `studentCode` | String | Mã sinh viên |
| `studentName` | String | Họ tên sinh viên |
| `entries` | `List<StudentScoreEntryResponse>` | Danh sách điểm từng thành phần |
| `total` | BigDecimal | Tổng điểm |
| `letterGrade` | String | Hệ chữ cái |
| `gpa` | Double | Điểm GPA |

---

## 3. Chi tiết từng hàm

### 3.1 `getComponents` — Lấy danh sách thành phần điểm

**Vị trí:** `ScoreController.getComponents(...)` → `ScoreService.getComponents(...)`

**Endpoint:** `GET /api/v1/classes/{id}/score-components`

**Path variable:** `id` (UUID) — ID lớp học

**Header đầu vào:** `X-User-Id` (giảng viên sở hữu)

**Luồng xử lý:**
1. Controller gọi `scoreService.getComponents(id, UUID.fromString(ownerId))`.
2. Service `getComponents`:
   - Gọi `requireOwnedClass(classId, ownerId)` để kiểm tra lớp tồn tại và thuộc về giảng viên. Nếu không → `ResourceNotFoundException("Class not found: " + classId)`.
   - Truy vấn `scoreComponentRepository.findAllByClassId(classId)` → danh sách `ScoreComponent`.
   - Map từng thành phần sang `ScoreComponentResponse` qua `scoreComponentMapper::toResponse`.
   - Trả về `List<ScoreComponentResponse>`.

**Ví dụ request:**
```http
GET /api/v1/classes/03310ff7-b94f-423a-abf2-6332331c9471/score-components
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):**
```json
[
  {
    "id": "a1b2c3d4-...",
    "classId": "03310ff7-b94f-423a-abf2-6332331c9471",
    "type": "ATTENDANCE",
    "weight": "0.100",
    "createdAt": "2026-11-01T03:15:35.384324Z",
    "deletedAt": null
  },
  {
    "id": "e5f6g7h8-...",
    "classId": "03310ff7-b94f-423a-abf2-6332331c9471",
    "type": "EXERCISE",
    "weight": "0.200",
    "createdAt": "2026-11-01T03:15:35.384324Z",
    "deletedAt": null
  },
  {
    "id": "i9j0k1l2-...",
    "classId": "03310ff7-b94f-423a-abf2-6332331c9471",
    "type": "FINAL_EXAM",
    "weight": "0.700",
    "createdAt": "2026-11-01T03:15:35.384324Z",
    "deletedAt": null
  }
]
```

**Mã lỗi:**
- `404`: lớp không tồn tại hoặc không thuộc giảng viên gọi.
- `401/403`: không có quyền LECTURER.

---

### 3.2 `replaceComponents` — Thay thế toàn bộ thành phần điểm

**Vị trí:** `ScoreController.replaceComponents(...)` → `ScoreService.replaceComponents(...)`

**Endpoint:** `PUT /api/v1/classes/{id}/score-components`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`

**Request body:** `List<ScoreComponentRequest>`

**Luồng xử lý (Service `replaceComponents`):**

1. Gọi `requireOwnedClass(classId, ownerId)` để kiểm tra sở hữu lớp.
2. Gọi `validateComponents(requests)` để kiểm tra ràng buộc:
   - Không được trùng loại thành phần (`Duplicate component type`).
   - Tổng trọng số phải bằng `1.000` (sai lệch ≤ 0.001).
   - Phải có thành phần `FINAL_EXAM`.
   - Trọng số `FINAL_EXAM` phải ≥ `0.40`.
3. Lấy danh sách thành phần hiện có của lớp (`findAllByClassId`), thu gom thành map theo `type`.
4. Duyệt từng request:
   - Nếu loại thành phần đã tồn tại → cập nhật trọng số, lưu.
   - Nếu chưa tồn tại → tạo mới `ScoreComponent` với `classId`, `type`, trọng số, lưu.
5. Các thành phần còn lại trong map (không có trong request) → gán `deletedAt = now` (soft-delete), lưu.
6. Truy vấn lại danh sách thành phần của lớp, map sang response, trả về.

**Ví dụ request:**
```http
PUT /api/v1/classes/03310ff7-b94f-423a-abf2-6332331c9471/score-components
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
Content-Type: application/json

[
  { "type": "ATTENDANCE", "weight": "0.100" },
  { "type": "EXERCISE", "weight": "0.200" },
  { "type": "FINAL_EXAM", "weight": "0.700" }
]
```

**Ví dụ response (200):** Giống `getComponents` với danh sách thành phần mới.

**Mã lỗi có thể xảy ra:**
- `400 IllegalArgumentException`: trùng loại thành phần, tổng trọng số không bằng 1.000, thiếu FINAL_EXAM, FINAL_EXAM < 0.40.
- `404`: lớp không tồn tại.

---

### 3.3 `setStudentScores` — Cập nhật điểm của một sinh viên

**Vị trí:** `ScoreController.setStudentScores(...)` → `ScoreService.setStudentScores(...)`

**Endpoint:** `PUT /api/v1/classes/{id}/students/{studentCode}/scores`

**Path variable:**
- `id` (UUID): ID lớp học
- `studentCode` (String): Mã sinh viên

**Header đầu vào:** `X-User-Id`

**Request body:** `List<StudentScoreRequest>`

**Luồng xử lý (Service `setStudentScores`):**

1. Gọi `requireStudentInClass(classId, ownerId, studentCode)`:
   - Kiểm tra lớp tồn tại và sở hữu (`requireOwnedClass`).
   - Trim `studentCode`. Nếu trống hoặc không tìm thấy trong roster lớp (`classStudentRepository.findByClassIdAndStudentCode`) → `ResourceNotFoundException("Student '<code>' not found in class " + classId)`.
   - Trả về mã sinh viên đã trim.
2. Lấy tất cả thành phần điểm của lớp, thu gom thành map theo `type`.
3. Nếu không có thành phần nào → `IllegalArgumentException("No score components configured for class " + classId)`.
4. Duyệt từng request:
   - Tìm thành phần theo `componentType`. Nếu không tìm thấy → `IllegalArgumentException("Unknown component type: " + ...)`.
   - Nếu loại thành phần là `EXERCISE` → `IllegalArgumentException("EXERCISE is auto-graded from results, cannot set manually")` (điểm bài tập được tính tự động từ kết quả chấm, không nhập thủ công).
   - Tìm hoặc tạo `StudentScore` với `classId`, `studentCode`, `componentId`.
   - Gán `score = req.getScore()`, lưu qua `studentScoreRepository.save(score)`.
5. Controller trả về `ResponseEntity.ok().build()` (200 OK, không body).

**Ví dụ request:**
```http
PUT /api/v1/classes/03310ff7-b94f-423a-abf2-6332331c9471/students/b22dckh024/scores
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
Content-Type: application/json

[
  { "componentType": "ATTENDANCE", "score": "10.00" },
  { "componentType": "FINAL_EXAM", "score": "8.50" }
]
```

**Ví dụ response (200):** Rỗng (không body).

**Mã lỗi:**
- `404`: lớp không tồn tại, sinh viên không có trong lớp.
- `400`: không có thành phần điểm nào, loại thành phần không xác định, không được nhập điểm EXERCISE thủ công.

---

### 3.4 `getStudentScores` — Xem chi tiết điểm của một sinh viên

**Vị trí:** `ScoreController.getStudentScores(...)` → `ScoreService.getStudentScores(...)`

**Endpoint:** `GET /api/v1/classes/{id}/students/{studentCode}/scores`

**Path variable:** `id` (UUID), `studentCode` (String)

**Header đầu vào:** `X-User-Id`

**Luồng xử lý (Service `getStudentScores`):**

1. Gọi `requireStudentInClass(classId, ownerId, studentCode)` để kiểm tra lớp và sinh viên.
2. Gọi `buildScores(classId, code)`:
   - Lấy tất cả thành phần điểm của lớp.
   - Lấy điểm nhập thủ công của sinh viên (`findAllByClassIdAndStudentCode`), thu gom thành map `componentId → score`.
   - Tính điểm bài tập tự động (`computeExercise`):
     - Lấy `studentUserId` từ roster (`findByClassIdAndStudentCode`). Nếu null → trả về null (chưa có mapping user, không thể chấm tự động).
     - Lấy danh sách assignment `GRADED` đã publish của lớp (`findAllByClassIdAndPurposeAndPublished`).
     - Nếu không có assignment nào → trả về null.
     - Gọi `resultServiceClient.weighted(new AverageRequest(assignmentIds, studentUserId))` → lấy giá trị `"average"`.
     - Nếu lỗi (service down, không có kết quả) → log warns, trả về null (degrade gracefully, không làm fail toàn bộ bảng điểm).
   - Duyệt từng thành phần:
     - Nếu là `EXERCISE` → lấy điểm từ `computeExercise`.
     - Ngược lại → lấy điểm từ map điểm thủ công.
   - Tính tổng có trọng số, làm tròn 2 chữ số (`HALF_UP`) nếu đầy đủ.
   - Xếp loại (`evaluateGrade`): nếu tổng null → null. Nếu có bất kỳ sub-score nào ≤ 0 hoặc tổng < 4.00 → F. Ngược lại dùng `LetterGrade.fromTotal(total)`.
3. Trả về `StudentScoresResponse` với `studentCode`, `entries`, `total`, `letterGrade`, `gpa`.

**Ví dụ request:**
```http
GET /api/v1/classes/03310ff7-b94f-423a-abf2-6332331c9471/students/b22dckh024/scores
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):**
```json
{
  "studentCode": "b22dckh024",
  "entries": [
    { "type": "ATTENDANCE", "weight": "0.100", "score": "10.00" },
    { "type": "EXERCISE", "weight": "0.200", "score": "8.50" },
    { "type": "FINAL_EXAM", "weight": "0.700", "score": "7.00" }
  ],
  "total": "7.60",
  "letterGrade": "C",
  "gpa": 2.0
}
```

**Mã lỗi:**
- `404`: lớp không tồn tại, sinh viên không có trong lớp.

---

### 3.5 `getMyScores` — Xem điểm của chính mình (sinh viên)

**Vị trí:** `ScoreService.getMyScores(...)` — gọi nội bộ từ `StudentClassController.myScores`

**Luồng xử lý:**

1. Lấy `studentCode` của sinh viên trong lớp này bằng cách quét `classStudentRepository.findAllByStudentUserId(studentId)`, lọc theo `classId`, lấy `studentCode` đầu tiên. Nếu không tìm thấy → `ResourceNotFoundException("Class not found: " + classId)`.
   - **Lưu ý:** Không kiểm tra `ownerId` vì đây là sinh viên xem điểm của mình, risol identity qua `student_user_id` (JWT sub).
2. Gọi `buildScores(classId, code)` tương tự `getStudentScores`.
3. Trả về `StudentScoresResponse`.

**Ghi chú:** Phương thức này không có controller riêng, được gọi từ `StudentClassController.myScores` (xem tài liệu `student-class-controller.md`).

---

### 3.6 `transcript` — Xem bảng điểm trung bình của lớp

**Vị trí:** `ScoreController.transcript(...)` → `ScoreService.transcript(...)`

**Endpoint:** `GET /api/v1/classes/{id}/transcript`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`

**Query params:** `page` (int, mặc định 0), `size` (int, mặc định 20) — qua `Pageable`

**Luồng xử lý (Service `transcript`):**

1. Gọi `requireOwnedClass(classId, ownerId)` để kiểm tra sở hữu lớp.
2. Lấy tất cả thành phần điểm của lớp.
3. Lấy trang danh sách sinh viên trong lớp (`classStudentRepository.findAllByClassId(classId, pageable)`).
4. Nếu danh sách rỗng → trả về `Page.empty(pageable)`.
5. Lấy điểm thủ công của tất cả sinh viên trong lớp (`findAllByClassId`), nhóm theo `studentCode`.
6. Lấy danh sách assignment `GRADED` đã publish của lớp.
7. Lấy danh sách `student_user_id` của các sinh viên trong trang (bỏ qua null).
8. Gọi `resultServiceClient.weightedBatch(new BatchAverageRequest(assignmentIds, studentUserIds))` để lấy điểm bài tập cho toàn bộ trang trong **1 HTTP call** (batch).
9. Duyệt từng sinh viên trong trang:
   - Lấy điểm thủ công theo `studentCode`.
   - Lấy điểm bài tập từ map batch theo `studentUserId`.
   - Tính từng thành phần (EXERCISE từ batch, còn lại từ manual).
   - Tính tổng, làm tròn 2 chữ số nếu đầy đủ.
   - Xếp loại (F nếu có sub-score ≤ 0 hoặc tổng < 4.00).
10. Trả về `new PageImpl<>(entries, pageable, rosterPage.getTotalElements())`.

**Ví dụ request:**
```http
GET /api/v1/classes/03310ff7-b94f-423a-abf2-6332331c9471/transcript?page=0&size=20
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):**
```json
{
  "content": [
    {
      "studentCode": "b22dckh024",
      "studentName": "Nguyen Van A",
      "entries": [
        { "type": "ATTENDANCE", "weight": "0.100", "score": "10.00" },
        { "type": "EXERCISE", "weight": "0.200", "score": "8.50" },
        { "type": "FINAL_EXAM", "weight": "0.700", "score": "7.00" }
      ],
      "total": "7.60",
      "letterGrade": "C",
      "gpa": 2.0
    }
  ],
  "pageable": { "pageNumber": 0, "pageSize": 20, ... },
  "totalElements": 25,
  "totalPages": 2,
  "last": false,
  ...
}
```

**Mã lỗi:**
- `404`: lớp không tồn tại hoặc không thuộc giảng viên gọi.

---

## 4. Các hàm private helper trong ScoreService

### 4.1 `requireOwnedClass(UUID classId, UUID ownerId)`
- **Input:** classId, ownerId.
- **Output:** `CourseClass`.
- **Làm gì:** `courseClassRepository.findByIdAndOwnerId(classId, ownerId)`. Nếu null → `ResourceNotFoundException("Class not found: " + classId)`.

### 4.2 `requireStudentInClass(UUID classId, UUID ownerId, String studentCode)`
- **Input:** classId, ownerId, studentCode.
- **Output:** mã sinh viên đã trim (String).
- **Làm gì:** Kiểm tra lớp sở hữu, trim mã sinh viên, kiểm tra tồn tại trong roster. Nếu không tìm thấy → `ResourceNotFoundException`.

### 4.3 `validateComponents(List<ScoreComponentRequest> requests)`
- **Input:** danh sách yêu cầu thành phần điểm.
- **Output:** void.
- **Làm gì:** Kiểm tra trùng loại, tổng trọng số = 1.000, có FINAL_EXAM, FINAL_EXAM ≥ 0.40. Ném `IllegalArgumentException` nếu sai.

### 4.4 `computeExercise(UUID classId, String studentCode)`
- **Input:** classId, studentCode.
- **Output:** `BigDecimal` điểm bài tập, hoặc null nếu chưa có.
- **Làm gì:** Lấy `studentUserId` từ roster, lấy danh sách assignment GRADED đã publish, gọi `resultServiceClient.weighted(...)` để lấy điểm trung bình có trọng số. Lỗi → log warn, trả về null.

### 4.5 `evaluateGrade(BigDecimal finalTotal, List<StudentScoreEntryResponse> entries)`
- **Input:** tổng điểm, danh sách điểm từng thành phần.
- **Output:** `LetterGrade` hoặc null.
- **Làm gì:** Nếu tổng null → null. Nếu có sub-score ≤ 0 hoặc tổng < 4.00 → F. Ngược lại `LetterGrade.fromTotal(total)`.

### 4.6 `fetchBatchExerciseScores(List<UUID> assignmentIds, List<UUID> studentUserIds)`
- **Input:** danh sách assignment id, danh sách student user id.
- **Output:** `Map<UUID, BigDecimal>` (studentUserId → điểm).
- **Làm gì:** Gọi `resultServiceClient.weightedBatch(...)` cho toàn bộ danh sách. Lỗi → trả về map rỗng.

---

## 5. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 400 | Trùng loại thành phần, tổng trọng số ≠ 1.000, thiếu FINAL_EXAM, FINAL_EXAM < 0.40 | `ScoreService.validateComponents` |
| 400 | Không có thành phần điểm nào cho lớp | `ScoreService.setStudentScores` |
| 400 | Loại thành phần không xác định | `ScoreService.setStudentScores` |
| 400 | Không được nhập điểm EXERCISE thủ công (tự động chấm) | `ScoreService.setStudentScores` |
| 404 | Lớp không tồn tại / không thuộc giảng viên | `ScoreService.requireOwnedClass` |
| 404 | Sinh viên không có trong lớp | `ScoreService.requireStudentInClass` |
| 401/403 | Không có quyền LECTURER | Spring Security |

---

## 6. Luồng dữ liệu từ đầu đến cuối (ví dụ nhập điểm + xem transcript)

```
Bước 1 — Thiết lập thành phần điểm:
Giảng viên (FE)
   │ PUT /api/v1/classes/{id}/score-components + body [ATTENDANCE 0.1, EXERCISE 0.2, FINAL_EXAM 0.7]
   ▼
course-service: ScoreController.replaceComponents()
   │ 1. Kiểm tra sở hữu lớp (requireOwnedClass)
   │ 2. Validate components (tổng = 1.0, FINAL_EXAM ≥ 0.4)
   │ 3. Tạo/cập nhật/xóa mềm các ScoreComponent
   │ 4. Trả về danh sách ScoreComponentResponse
   ▼
FE nhận danh sách thành phần điểm

Bước 2 — Nhập điểm thủ công cho sinh viên:
Giảng viên (FE)
   │ PUT /api/v1/classes/{id}/students/{studentCode}/scores + body [{ATTENDANCE, 10}, {FINAL_EXAM, 8.5}]
   ▼
course-service: ScoreController.setStudentScores()
   │ 1. Kiểm tra sinh viên trong lớp (requireStudentInClass)
   │ 2. Lưu mỗi StudentScore vào repository
   │ 3. Trả về 200 OK (không body)
   ▼
FE nhận xác nhận

Bước 3 — Xem bảng điểm trung bình của lớp:
Giảng viên (FE)
   │ GET /api/v1/classes/{id}/transcript?page=0&size=20
   ▼
course-service: ScoreController.transcript()
   │ 1. Kiểm tra sở hữu lớp
   │ 2. Lấy trang danh sách sinh viên (roster)
   │ 3. Lấy điểm thủ công của tất cả sinh viên
   │ 4. Gọi result-service weightedBatch (1 call cho toàn bộ trang) → điểm EXERCISE
   │ 5. Tính tổng, xếp loại cho mỗi sinh viên
   │ 6. Trả về Page<TranscriptEntryResponse>
   ▼
FE hiển thị bảng điểm trung bình phân trang
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/course-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
