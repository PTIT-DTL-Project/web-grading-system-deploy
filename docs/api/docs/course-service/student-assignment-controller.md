# Tài liệu chi tiết luồng API — course-service / StudentAssignmentController

Nơi lưu: `docs/api/docs/course-service/student-assignment-controller.md`

Mục đích: giải thích chi tiết từng hàm/controller/service trong luồng xem bài tập của sinh viên (StudentAssignmentController), bao gồm input, output, điều kiện tiên quyết, ví dụ request/response, và các mã lỗi có thể xảy ra. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`StudentAssignmentController` là REST controller của service `course-service`, trỏ về base path `/api/v1/student/assignments`. Nó cung cấp các endpoint cho sinh viên (STUDENT) để xem danh sách bài tập, chi tiết bài tập, và danh sách plan của một bài tập.

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/student/assignments` | GET | Lấy danh sách bài tập của sinh viên (có lọc, tìm kiếm, phân trang) | STUDENT |
| `/api/v1/student/assignments/topics` | GET | Lấy danh sách chủ đề của bài tập tự luyện đã xuất bản | STUDENT |
| `/api/v1/student/assignments/{id}` | GET | Xem chi tiết một bài tập | STUDENT |
| `/api/v1/student/assignments/{id}/plans` | GET | Lấy danh sách plan của một bài tập (config đã sanitize) | STUDENT |

**Không có `@PreAuthorize`** — quyền kiểm soát qua header `X-User-Id` (JWT sub) và `X-User-Email`, plus `studentIdentityService.linkStudent(...)` để liên kết identidad. Sinh viên chỉ sees bài tập đã `published` của lớp họ đang đăng ký (hoặc bài PRACTICE class-independent). Bài tập không thuộc về sinh viên hoặc chưa publish → `404` (không thể phân biệt với không tồn tại).

Controller giao tiếp với `StudentAssignmentService` để thực hiện logic nghiệp vụ.

---

## 2. DTO liên quan

### 2.1 `AssignmentResponse` (dto/response)
Chi tiết một bài tập.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID bài tập |
| `ownerId` | UUID | ID giảng viên sở hữu |
| `classId` | UUID | ID lớp (null nếu PRACTICE) |
| `title` | String | Tên bài tập |
| `description` | String | Mô tả |
| `purpose` | String | GRADED / PRACTICE |
| `topic` | String | Chủ đề |
| `gradingStrategy` | String | Chiến lược chấm điểm |
| `dockerComposePort` | Integer | Cổng container |
| `published` | Boolean | Đã xuất bản |
| `createdAt` / `updatedAt` | OffsetDateTime | Thời điểm tạo/cập nhật |

### 2.2 `PlanResponse` (dto/response)
Một plan (câu hỏi) của bài tập.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID plan |
| `name` | String | Tên plan |
| `description` | String | Mô tả |
| `sequenceOrder` | Integer | Thứ tự |
| `weight` | Integer | Trọng số |
| `steps` | `List<StepResponse>` | Danh sách bước (đã sanitize) |

### 2.3 `StepResponse` (dto/response)
Một bước trong plan (phiên bản sinh viên, đã sanitize).

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID bước |
| `stepOrder` | Integer | Thứ tự bước |
| `name` | String | Tên bước |
| `description` | String | Mô tả |
| `type` | String | Loại bước (HTTP_REQUEST, DB_QUERY, ...) |
| `config` | JsonNode | Config (đã strip `connection`, `extract`, `expected`) |
| `expectedResult` | JsonNode | Kết quả kỳ vọng (đã strip) |
| `weight` | Integer | Trọng số |
| `timeoutMs` | Integer | Timeout (ms) |
| `required` | Boolean | Bắt buộc |

### 2.4 `AssignmentPurpose` (entity)
Enum: `GRADED` (chấm điểm), `PRACTICE` (tự luyện).

---

## 3. Chi tiết từng hàm

### 3.1 `list` — Lấy danh sách bài tập của sinh viên

**Vị trí:** `StudentAssignmentController.list(...)` → `StudentAssignmentService.listAssignments(...)`

**Endpoint:** `GET /api/v1/student/assignments`

**Header đầu vào:**
- `X-User-Id` (String, mặc định `"anonymous"`): ID sinh viên (JWT sub)
- `X-User-Email` (String, mặc định `""`): Email sinh viên

**Query params:**
| Param | Kiểu | Bắt buộc | Mặc định | Mô tả |
|-------|------|----------|----------|-------|
| `classId` | UUID | — | null | Lọc theo lớp (chỉ ảnh hưởng GRADED) |
| `purpose` | AssignmentPurpose | — | `GRADED` | GRADED hoặc PRACTICE |
| `topic` | String | — | null | Lọc chính xác chủ đề |
| `search` | String | — | null | Tìm kiếm trong tiêu đề/chủ đề |
| `page` | int | — | 0 | Trang |
| `size` | int | — | 20 | Kích thước trang |

**Luồng xử lý:**
1. Controller tạo `Pageable` từ `page`, `size`. Gọi `studentAssignmentService.listAssignments(studentId, email, classId, purpose, topic, search, pageable)`.
2. Service `listAssignments`:
   - Gọi `studentIdentityService.linkStudent(studentId, email)` — liên kết identidad sinh viên (gán `student_user_id` vào roster nếu chưa có, khớp qua email).
   - Xác định `effective = purpose != null ? purpose : GRADED`.
   - Trim `topic` nếu có.
   - **Nếu PRACTICE:** gọi `assignmentRepository.findPublishedPractice(topic, search, pageable)` → bài tập tự luyện đã xuất bản, class-independent (không cần đăng ký lớp). Map sang `AssignmentResponse`, trả về `Page`.
   - **Nếu GRADED:** lấy `classIds = enrolledClassIds(studentId)` (các lớp sinh viên đang đăng ký qua `class_students.student_user_id`). Nếu rỗng → `Page.empty(pageable)`. Ngược lại gọi `assignmentRepository.findPublishedForStudent(classIds, classId, topic, search, pageable)` → bài tập GRADED đã publish của các lớp đã đăng ký (lọc thêm theo `classId` nếu cung cấp). Map sang response.

**Ví dụ request:**
```http
GET /api/v1/student/assignments?purpose=GRADED&topic=CRUD&search=bai&page=0&size=20
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
X-User-Email: b22dckh024@example.com
```

**Ví dụ response (200):**
```json
{
  "content": [
    {
      "id": "16cebadb-2485-4494-be5b-7f6641887559",
      "ownerId": "2be57808-9203-4150-8f29-19aecbe9f725",
      "classId": "03310ff7-b94f-423a-abf2-6332331c9471",
      "title": "Bài kiểm tra CRUD quản lý sinh viên",
      "purpose": "GRADED",
      "topic": "quản lý sinh viên",
      "published": true,
      ...
    }
  ],
  "pageable": { "pageNumber": 0, "pageSize": 20, ... },
  "totalElements": 1,
  "totalPages": 1,
  "last": true,
  ...
}
```

**Mã lỗi:**
- `404`: không có bài tập nào phù hợp (trả về trang rỗng, không phải lỗi).

---

### 3.2 `listTopics` — Lấy danh sách chủ đề bài tập tự luyện

**Vị trí:** `StudentAssignmentController.listTopics()` → `StudentAssignmentService.listTopics()`

**Endpoint:** `GET /api/v1/student/assignments/topics`

**Luồng xử lý:**
1. Controller gọi `studentAssignmentService.listTopics()`.
2. Service gọi `assignmentRepository.findDistinctPublishedTopics(AssignmentPurpose.PRACTICE)` → danh sách chủ đề phân biệt của bài tập PRACTICE đã publish.
3. Trả về `List<String>`.

**Ví dụ request:**
```http
GET /api/v1/student/assignments/topics
```

**Ví dụ response (200):**
```json
["CRUD cơ bản", "Xử lý lỗi", "Extract & biến"]
```

---

### 3.3 `detail` — Xem chi tiết bài tập

**Vị trí:** `StudentAssignmentController.detail(...)` → `StudentAssignmentService.getAssignment(...)`

**Endpoint:** `GET /api/v1/student/assignments/{id}`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`, `X-User-Email`

**Luồng xử lý:**
1. Controller gọi `studentAssignmentService.getAssignment(studentId, email, id)`.
2. Service `getAssignment`:
   - Gọi `studentIdentityService.linkStudent(studentId, email)`.
   - Gọi `requireVisible(studentId, assignmentId)`:
     - Truy vấn `assignmentRepository.findById(assignmentId)`. Nếu null → `ResourceNotFoundException("Assignment not found: " + id)`.
     - Nếu `published != true` → `ResourceNotFoundException` (404, không phân biệt).
     - Nếu PRACTICE → trả về assignment (không cần đăng ký lớp).
     - Nếu GRADED → kiểm tra `enrolledClassIds(studentId)` chứa `assignment.getClassId()`. Nếu không → `ResourceNotFoundException` (404).
   - Map sang `AssignmentResponse` qua `assignmentMapper.toResponse`, trả về.

**Ví dụ request:**
```http
GET /api/v1/student/assignments/16cebadb-2485-4494-be5b-7f6641887559
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
X-User-Email: b22dckh024@example.com
```

**Ví dụ response (200):** Giống `AssignmentResponse` ở mục 2.1.

**Mã lỗi:**
- `404`: bài tập không tồn tại, chưa publish, hoặc sinh viên không đăng ký lớp (đối với GRADED).

---

### 3.4 `plans` — Lấy danh sách plan của bài tập (config đã sanitize)

**Vị trí:** `StudentAssignmentController.plans(...)` → `StudentAssignmentService.listPlans(...)`

**Endpoint:** `GET /api/v1/student/assignments/{id}/plans`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`, `X-User-Email`

**Luồng xử lý:**
1. Controller gọi `studentAssignmentService.listPlans(studentId, email, id)`.
2. Service `listPlans`:
   - Gọi `studentIdentityService.linkStudent(studentId, email)`.
   - Gọi `requireVisible(studentId, assignmentId)` (giống `detail`).
   - Truy vấn `testPlanRepository.findAllByAssignmentIdOrderBySequenceOrderAsc(assignmentId)` → danh sách plan.
   - Truy vấn `testStepRepository.findAllByPlanIdInOrderByStepOrderAsc(...)` → tất cả bước của các plan.
   - Dùng `toSanitizedStep` cho mỗi bước:
     - Bỏ qua bước loại `DELAY` và `EXTRACT` (không hiển thị cho sinh viên).
     - Gọi `sanitizeConfig(step.getConfig())`: parse JSON, xóa các trường `connection` (thông tin kết nối DB), `extract` (biến trích xuất), `expected` (kết quả kỳ vọng) — để không lộ cấu hình chấm điểm.
   - Map sang `PlanResponse` với `steps` đã sanitize.
3. Trả về `List<PlanResponse>`.

**Ví dụ request:**
```http
GET /api/v1/student/assignments/16cebadb-2485-4494-be5b-7f6641887559/plans
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
X-User-Email: b22dckh024@example.com
```

**Ví dụ response (200):**
```json
[
  {
    "id": "7e31465c-2764-4848-abf3-854832c64361",
    "name": "Câu 1: Tạo sinh viên mới",
    "description": "Kiểm tra tạo sinh viên mới...",
    "sequenceOrder": 1,
    "weight": 100,
    "steps": [
      {
        "id": "15ba2249-9919-450f-82cf-3c534cf219aa",
        "stepOrder": 1,
        "name": "POST tạo sinh viên mới",
        "type": "HTTP_REQUEST",
        "config": { "method": "POST", "path": "/api/students", ... },
        "weight": 30,
        "timeoutMs": 5000,
        "required": true
      }
    ]
  }
]
```

**Mã lỗi:**
- `404`: bài tập không tồn tại, chưa publish, hoặc sinh viên không đăng ký lớp.

---

## 4. Các hàm private helper trong StudentAssignmentService

### 4.1 `enrolledClassIds(UUID studentId)`
- **Input:** studentId.
- **Output:** `List<UUID>` (danh sách classId sinh viên đang đăng ký).
- **Làm gì:** `classStudentRepository.findAllByStudentUserId(studentId)` → map sang `classId`.

### 4.2 `requireVisible(UUID studentId, UUID assignmentId)`
- **Input:** studentId, assignmentId.
- **Output:** `Assignment`.
- **Làm gì:** Kiểm tra assignment tồn tại, đã publish, và (nếu GRADED) sinh viên đang đăng ký lớp. Nếu không thỏa mãn → `ResourceNotFoundException("Assignment not found: " + assignmentId)` (404, không phân biệt).

### 4.3 `toSanitizedStep(TestStep step)`
- **Input:** `TestStep`.
- **Output:** `StepResponse`.
- **Làm gì:** Map bước sang response, gọi `sanitizeConfig(config)` để xóa `connection`, `extract`, `expected`.

### 4.4 `sanitizeConfig(String configJson)`
- **Input:** chuỗi JSON config.
- **Output:** `JsonNode` (đã strip) hoặc null.
- **Làm gì:** Parse JSON, deep copy, xóa `List.of("connection", "extract", "expected")`.

---

## 5. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 404 | Bài tập không tồn tại / chưa publish / sinh viên không đăng ký lớp | `StudentAssignmentService.requireVisible` |
| 404 | (list) Không có bài tập phù hợp | Trả về `Page.empty()` (không phải lỗi) |

---

## 6. Luồng dữ liệu từ đầu đến cuối (ví dụ sinh viên xem bài tập và plan)

```
Sinh viên (FE)
   │ GET /api/v1/student/assignments?purpose=GRADED&page=0&size=20
   │ header X-User-Id: e4ab4157-... (JWT sub)
   │ header X-User-Email: b22dckh024@example.com
   ▼
course-service: StudentAssignmentController.list()
   │ 1. Tạo Pageable
   │ 2. Gọi StudentAssignmentService.listAssignments(studentId, email, ...)
   ▼
StudentAssignmentService.listAssignments()
   │ 3. linkStudent(studentId, email) → liên kết identidad (gán student_user_id vào roster nếu chưa có)
   │ 4. Nếu PRACTICE: findPublishedPractice(...) (không cần enrolled class)
   │ 5. Nếu GRADED: enrolledClassIds(studentId) → findPublishedForStudent(...)
   │ 6. Map → Page<AssignmentResponse>
   ▼
StudentAssignmentController.list()
   │ 7. Trả về ResponseEntity.ok(Page<AssignmentResponse>)
   ▼
FE hiển thị danh sách bài tập

Sinh viên chọn một bài → xem plan:
   │ GET /api/v1/student/assignments/{id}/plans
   ▼
StudentAssignmentController.plans()
   │ 1. linkStudent(...)
   │ 2. requireVisible(...) → kiểm tra publish + enrolled (404 nếu không)
   │ 3. Lấy plans + steps, lọc bỏ DELAY/EXTRACT
   │ 4. sanitizeConfig → xóa connection/extract/expected
   │ 5. Trả về List<PlanResponse>
   ▼
FE hiển thị danh sách plan và bước (không thấy thông tin kết nối DB)
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/course-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
