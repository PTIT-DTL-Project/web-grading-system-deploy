# Tài liệu chi tiết luồng API — course-service / StudentClassController

Nơi lưu: `docs/api/docs/course-service/student-class-controller.md`

Mục đích: giải thích chi tiết từng hàm/controller/service trong luồng xem lớp học của sinh viên (StudentClassController), bao gồm input, output, điều kiện tiên quyết, ví dụ request/response, và các mã lỗi có thể xảy ra. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`StudentClassController` là REST controller của service `course-service`, trỏ về base path `/api/v1/student/classes`. Nó cung cấp các endpoint cho sinh viên (STUDENT) để xem danh sách lớp họ đang đăng ký, chi tiết lớp, điểm của mình trong lớp, và danh sách bạn cùng lớp (roster).

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/student/classes` | GET | Lấy danh sách lớp học sinh viên đang đăng ký (có lọc, tìm kiếm, phân trang) | STUDENT |
| `/api/v1/student/classes/{id}` | GET | Xem chi tiết một lớp đã đăng ký | STUDENT |
| `/api/v1/student/classes/{id}/my-scores` | GET | Xem điểm của chính mình trong lớp | STUDENT |
| `/api/v1/student/classes/{id}/students` | GET | Xem danh sách bạn cùng lớp (mã + tên) | STUDENT |

**Không có `@PreAuthorize`** — quyền kiểm soát qua header `X-User-Id` (JWT sub) và `X-User-Email`, plus `studentIdentityService.linkStudent(...)`. Sinh viên chỉ sees lớp họ đang đăng ký (`class_students.student_user_id`). Lớp không thuộc về sinh viên → `404` (không thể phân biệt với không tồn tại).

Controller giao tiếp với `StudentClassService` (xem lớp, roster) và `ScoreService` (xem điểm của mình).

---

## 2. DTO liên quan

### 2.1 `StudentClassResponse` (dto/response)
Thông tin một lớp học dành cho sinh viên (giống `ClassResponse` trừ `ownerId`).

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID lớp học |
| `name` | String | Tên lớp |
| `semester` | String | Học kỳ |
| `status` | String | `ACTIVE` / `ARCHIVED` |
| `createdAt` | OffsetDateTime | Thời điểm tạo |

### 2.2 `StudentScoresResponse` (dto/response)
Kết quả xem điểm chi tiết của một sinh viên trong lớp.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `studentCode` | String | Mã sinh viên |
| `entries` | `List<StudentScoreEntryResponse>` | Điểm từng thành phần |
| `total` | BigDecimal | Tổng điểm |
| `letterGrade` | String | Hệ chữ cái |
| `gpa` | Double | Điểm GPA |

Lớp lồng `StudentScoreEntryResponse`: `type` (ScoreComponentType), `weight` (BigDecimal), `score` (BigDecimal, null nếu chưa nhập).

### 2.3 `StudentRosterResponse` (dto/response)
Một dòng trong danh sách bạn cùng lớp.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `studentCode` | String | Mã sinh viên |
| `studentName` | String | Họ tên sinh viên |

Ghi chú: Không có email hay user id — bạn cùng lớp chỉ biết mã và tên. Bao gồm cả dòng chưa liên kết user id (đã import CSV là đã là thành viên lớp).

### 2.4 `ClassStatus` (entity)
Enum: `ACTIVE`, `ARCHIVED`.

---

## 3. Chi tiết từng hàm

### 3.1 `list` — Lấy danh sách lớp học đã đăng ký

**Vị trí:** `StudentClassController.list(...)` → `StudentClassService.listEnrolledClasses(...)`

**Endpoint:** `GET /api/v1/student/classes`

**Header đầu vào:**
- `X-User-Id` (String, mặc định `"anonymous"`): ID sinh viên (JWT sub)
- `X-User-Email` (String, mặc định `""`): Email sinh viên

**Query params:**
| Param | Kiểu | Bắt buộc | Mặc định | Mô tả |
|-------|------|----------|----------|-------|
| `search` | String | — | null | Chuỗi tìm kiếm có cấu trúc (ví dụ `name:Lap;semester:20261`) |
| `status` | ClassStatus | — | null | Lọc `ACTIVE` / `ARCHIVED` |
| `page` | int | — | 0 | Trang |
| `size` | int | — | 20 | Kích thước trang |

**Luồng xử lý:**
1. Controller tạo `Pageable` với `PageRequest.of(page, size, Sort.by("createdAt").descending())`.
2. Gọi `studentClassService.listEnrolledClasses(studentId, email, search, status, pageable)`.
3. Service `listEnrolledClasses`:
   - Gọi `studentIdentityService.linkStudent(studentId, email)` — liên kết identidad sinh viên.
   - Lấy `classIds = enrolledClassIds(studentId)` (các lớp sinh viên đang đăng ký qua `class_students.student_user_id`).
   - Nếu rỗng → `Page.empty(pageable)`.
   - Gọi `courseClassRepository.findEnrolled(classIds, ClassFilter.parse(search), status, pageable)` → danh sách lớp đã đăng ký, lọc theo search/status, sắp xếp theo createdAt DESC.
   - Map qua `classMapper::toStudentResponse` (không có `ownerId`).
   - Trả về `Page<StudentClassResponse>`.

**Ví dụ request:**
```http
GET /api/v1/student/classes?search=name:Lap;semester:20261&status=ACTIVE&page=0&size=20
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
X-User-Email: b22dckh024@example.com
```

**Ví dụ response (200):**
```json
{
  "content": [
    {
      "id": "03310ff7-b94f-423a-abf2-6332331c9471",
      "name": "Lập trình hướng đối tượng",
      "semester": "20261",
      "status": "ACTIVE",
      "createdAt": "2026-11-01T03:15:35.384324Z"
    }
  ],
  "pageable": { "pageNumber": 0, "pageSize": 20, "sort": [{"property":"createdAt","direction":"DESC"}] },
  "totalElements": 1,
  "totalPages": 1,
  "last": true,
  ...
}
```

**Mã lỗi:**
- `404`: không có lớp nào phù hợp (trả về trang rỗng, không phải lỗi).

---

### 3.2 `detail` — Xem chi tiết lớp học đã đăng ký

**Vị trí:** `StudentClassController.detail(...)` → `StudentClassService.getEnrolledClass(...)`

**Endpoint:** `GET /api/v1/student/classes/{id}`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`, `X-User-Email`

**Luồng xử lý:**
1. Controller gọi `studentClassService.getEnrolledClass(studentId, email, id)`.
2. Service `getEnrolledClass`:
   - Gọi `studentIdentityService.linkStudent(studentId, email)`.
   - Kiểm tra `enrolledClassIds(studentId)` chứa `classId`. Nếu không → `ResourceNotFoundException("Class not found: " + classId)`.
   - Truy vấn `courseClassRepository.findById(classId)`. Nếu null → `ResourceNotFoundException`.
   - Map qua `classMapper::toStudentResponse`, trả về.

**Ví dụ request:**
```http
GET /api/v1/student/classes/03310ff7-b94f-423a-abf2-6332331c9471
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
X-User-Email: b22dckh024@example.com
```

**Ví dụ response (200):** Giống `StudentClassResponse` ở mục 2.1.

**Mã lỗi:**
- `404`: lớp không tồn tại hoặc sinh viên không đăng ký lớp này.

---

### 3.3 `myScores` — Xem điểm của chính mình trong lớp

**Vị trí:** `StudentClassController.myScores(...)` → `StudentClassService.getEnrolledClass(...)` → `ScoreService.getMyScores(...)`

**Endpoint:** `GET /api/v1/student/classes/{id}/my-scores`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`, `X-User-Email`

**Luồng xử lý:**
1. Controller gọi `studentClassService.getEnrolledClass(studentUuid, email, id)` để kiểm tra sinh viên đang đăng ký lớp (nếu không → 404).
2. Gọi `scoreService.getMyScores(id, studentUuid)`.
3. Service `ScoreService.getMyScores`:
   - Lấy `studentCode` của sinh viên trong lớp này: quét `classStudentRepository.findAllByStudentUserId(studentId)`, lọc theo `classId`, lấy `studentCode` đầu tiên. Nếu không tìm thấy → `ResourceNotFoundException("Class not found: " + classId)`.
   - Gọi `buildScores(classId, code)`:
     - Lấy tất cả thành phần điểm của lớp.
     - Lấy điểm thủ công của sinh viên.
     - Tính điểm bài tập tự động (`computeExercise`) qua `resultServiceClient.weighted(...)` cho các assignment GRADED đã publish.
     - Tính tổng, xếp loại.
   - Trả về `StudentScoresResponse`.

**Ví dụ request:**
```http
GET /api/v1/student/classes/03310ff7-b94f-423a-abf2-6332331c9471/my-scores
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
X-User-Email: b22dckh024@example.com
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
- `404`: sinh viên không đăng ký lớp này.

**Liên quan:** Chi tiết `buildScores`, `computeExercise`, `evaluateGrade` xem tài liệu `score-controller.md`.

---

### 3.4 `roster` — Xem danh sách bạn cùng lớp

**Vị trí:** `StudentClassController.roster(...)` → `StudentClassService.listRoster(...)`

**Endpoint:** `GET /api/v1/student/classes/{id}/students`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`, `X-User-Email`

**Query params:** `page` (int, mặc định 0), `size` (int, mặc định 20)

**Luồng xử lý:**
1. Controller tạo `Pageable` với `PageRequest.of(page, size, Sort.by("studentCode").ascending())`.
2. Gọi `studentClassService.listRoster(studentId, email, id, pageable)`.
3. Service `listRoster`:
   - Gọi `getEnrolledClass(studentId, email, classId)` để kiểm tra đăng ký (404 nếu không) và side-effect `linkStudent`.
   - Gọi `classStudentRepository.findAllByClassId(classId, pageable)` → danh sách `ClassStudent`.
   - Map từng dòng sang `StudentRosterResponse` với `studentCode`, `studentName`.
   - Trả về `Page<StudentRosterResponse>`.

**Ví dụ request:**
```http
GET /api/v1/student/classes/03310ff7-b94f-423a-abf2-6332331c9471/students?page=0&size=20
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
X-User-Email: b22dckh024@example.com
```

**Ví dụ response (200):**
```json
{
  "content": [
    { "studentCode": "b22dckh024", "studentName": "Nguyen Van A" },
    { "studentCode": "b22dckh025", "studentName": "Tran Thi B" }
  ],
  "pageable": { "pageNumber": 0, "pageSize": 20, ... },
  "totalElements": 25,
  "totalPages": 2,
  "last": false,
  ...
}
```

**Mã lỗi:**
- `404`: sinh viên không đăng ký lớp này.

---

## 4. Các hàm private helper trong StudentClassService

### 4.1 `enrolledClassIds(UUID studentId)`
- **Input:** studentId.
- **Output:** `List<UUID>` (danh sách classId).
- **Làm gì:** `classStudentRepository.findAllByStudentUserId(studentId)` → map sang `classId`.

---

## 5. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 404 | Sinh viên không đăng ký lớp này | `StudentClassService.getEnrolledClass` |
| 404 | (list/roster) Không có lớp phù hợp | Trả về `Page.empty()` (không phải lỗi) |

---

## 6. Luồng dữ liệu từ đầu đến cuối (ví dụ sinh viên xem lớp và điểm của mình)

```
Sinh viên (FE)
   │ GET /api/v1/student/classes?page=0&size=20
   │ header X-User-Id: e4ab4157-... (JWT sub)
   │ header X-User-Email: b22dckh024@example.com
   ▼
course-service: StudentClassController.list()
   │ 1. Tạo Pageable (sort createdAt DESC)
   │ 2. Gọi StudentClassService.listEnrolledClasses(studentId, email, search, status, pageable)
   ▼
StudentClassService.listEnrolledClasses()
   │ 3. linkStudent(studentId, email) → liên kết identidad
   │ 4. enrolledClassIds(studentId) → danh sách classId đã đăng ký
   │ 5. findEnrolled(classIds, ClassFilter.parse(search), status, pageable)
   │ 6. Map → Page<StudentClassResponse> (không có ownerId)
   ▼
StudentClassController.list()
   │ 7. Trả về ResponseEntity.ok(Page<StudentClassResponse>)
   ▼
FE hiển thị danh sách lớp học

Sinh viên chọn một lớp → xem điểm của mình:
   │ GET /api/v1/student/classes/{id}/my-scores
   ▼
StudentClassController.myScores()
   │ 1. getEnrolledClass(...) → kiểm tra đăng ký (404 nếu không)
   │ 2. Gọi ScoreService.getMyScores(id, studentUuid)
   ▼
ScoreService.getMyScores()
   │ 3. Lấy studentCode từ roster theo studentId + classId
   │ 4. buildScores(...) → tính điểm từng thành phần, tổng, xếp loại
   │ 5. Trả về StudentScoresResponse
   ▼
FE hiển thị điểm của sinh viên trong lớp
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/course-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
