# Tài liệu chi tiết luồng API — course-service / AssignmentController

Nơi lưu: `docs/api/docs/course-service/assignment-controller.md`

Mục đích: giải thích chi tiết từng hàm/controller/service trong luồng quản lý bài tập (assignment) của course-service, bao gồm input, output, điều kiện tiên quyết, ví dụ request/response, và các mã lỗi có thể xảy ra. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`AssignmentController` là REST controller của service `course-service`, trỏ về base path `/api/v1/assignments`. Nó cung cấp các endpoint cho giảng viên (LECTURER) để quản lý bài tập: tạo, danh sách, xem chi tiết, cập nhật, xóa mềm, và xuất bản (publish).

Tất cả endpoint đều được bảo vệ bằng `@PreAuthorize("hasRole('LECTURER')")` và nhận `X-User-Id` từ header (giá trị mặc định `"anonymous"` nếu thiếu). Controller giao tiếp với `AssignmentService` để thực hiện logic nghiệp vụ.

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/assignments` | POST | Tạo bài tập mới | LECTURER |
| `/api/v1/assignments` | GET | Lấy danh sách bài tập của mình | LECTURER |
| `/api/v1/assignments/topics` | GET | Lấy danh sách chủ đề (topic) phân biệt | LECTURER |
| `/api/v1/assignments/{id}` | GET | Xem chi tiết một bài tập | LECTURER |
| `/api/v1/assignments/{id}` | PUT | Cập nhật bài tập | LECTURER |
| `/api/v1/assignments/{id}` | DELETE | Xóa mềm (soft-delete) bài tập | LECTURER |
| `/api/v1/assignments/{id}/publish` | POST | Xuất bản bài tập | LECTURER |

---

## 2. DTO liên quan

### 2.1 `CreateAssignmentRequest` (dto/request)
Dùng cho request tạo bài tập. Không dùng `@Builder` (ghi chú trong mã: để tránh Lombok xóa field initializer của no-args constructor, ảnh hưởng Jackson absent-property defaults).

| Trường | Kiểu | Bắt buộc | Mặc định | Mô tả |
|--------|------|----------|----------|-------|
| `title` | String | `@NotBlank` | — | Tên bài tập, không được trống |
| `description` | String | — | null | Mô tả bài tập |
| `classId` | UUID | — | null | ID lớp học sở hữu (bắt buộc nếu GRADED, phải null nếu PRACTICE) |
| `purpose` | AssignmentPurpose | — | `GRADED` | Loại: GRADED (chấm điểm) hoặc PRACTICE (tự luyện) |
| `topic` | String | `@NotBlank` | — | Chủ đề bài tập (ví dụ: "CRUD cơ bản") |
| `gradingStrategy` | GradingStrategy | — | `STUDENT_DOCKER_COMPOSE` | Chiến lược chấm điểm |
| `dockerComposeTemplate` | String | — | null | Template docker-compose (bắt buộc nếu LECTURER_DOCKER_COMPOSE) |
| `dockerComposePort` | Integer | `@NotNull`, 1–65535 | 8080 | Cổng container |
| `startupTimeoutMs` | Integer | `@NotNull`, ≥1 | 60000 | Timeout khởi động (ms) |
| `executionTimeoutMs` | Integer | `@NotNull`, ≥1 | 300000 | Timeout thực thi (ms) |
| `maxMemoryMb` | Integer | `@NotNull`, ≥64 | 256 | Giới hạn bộ nhớ (MB) |
| `maxCpu` | Double | 0.1–16.0 | 0.5 | Giới hạn CPU |

### 2.2 `UpdateAssignmentRequest` (dto/request)
Dùng cho request cập nhật. Có `@Builder`, các trường về số (port, timeout, memory, cpu) là optional (không `@NotNull`) để cho phép cập nhật riêng lẻ.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `title` | String | `@NotBlank` | Tên mới |
| `description` | String | — | Mô tả mới |
| `classId` | UUID | — | Không được thay đổi nếu khác stored class |
| `topic` | String | `@NotBlank` | Chủ đề mới |
| `gradingStrategy` | GradingStrategy | — | Chiến lược mới |
| `dockerComposeTemplate` | String | — | Template mới |
| `dockerComposePort` | Integer | — | Cổng mới |
| `startupTimeoutMs` | Integer | — | Timeout khởi động mới |
| `executionTimeoutMs` | Integer | — | Timeout thực thi mới |
| `maxMemoryMb` | Integer | — | Bộ nhớ mới |
| `maxCpu` | Double | — | CPU mới |

### 2.3 `AssignmentResponse` (dto/response)
Trả về cho client sau mỗi thao tác.

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
| `dockerComposeTemplate` | String | Template compose |
| `dockerComposePort` | Integer | Cổng container |
| `startupTimeoutMs` | Integer | Timeout khởi động |
| `executionTimeoutMs` | Integer | Timeout thực thi |
| `maxMemoryMb` | Integer | Giới hạn RAM |
| `maxCpu` | Double | Giới hạn CPU |
| `published` | Boolean | Đã xuất bản hay chưa |
| `createdAt` | OffsetDateTime | Thời điểm tạo |
| `updatedAt` | OffsetDateTime | Thời điểm cập nhật lần cuối |

---

## 3. Chi tiết từng hàm

### 3.1 `create` — Tạo bài tập mới

**Vị trí:** `AssignmentController.create(...)` → `AssignmentService.create(...)`

**Endpoint:** `POST /api/v1/assignments`

**Header đầu vào:**
- `X-User-Id`: ID giảng viên (String, mặc định `"anonymous"`)

**Request body:** `CreateAssignmentRequest`

**Luồng xử lý (Controller → Service):**

1. **Controller:** Nhận `ownerId` từ header `X-User-Id`, chuyển đổi sang `UUID`. Gọi `assignmentService.create(UUID.fromString(ownerId), request)`. Trả về `ResponseEntity` status `201 CREATED` kèm `AssignmentResponse`.
2. **Service `create`:**
   - Xác định `purpose`: nếu request null thì mặc định `GRADED`.
   - Xác định `classId` và `topic` (trim khoảng trắng).
   - **Kiểm tra GRADED:** nếu `purpose == GRADED` và `classId == null` → ném `BadRequestException("classId is required for GRADED assignments")`. Nếu có `classId` → gọi `requireOwnedClass(ownerId, classId)` để kiểm tra lớp tồn tại và thuộc về giảng viên.
   - **Kiểm tra PRACTICE:** nếu `purpose != GRADED` và `classId != null` → ném `BadRequestException("classId must be null for PRACTICE assignments")`. Điều này giữ ranh giới giữa bài chấm điểm và bài tự luyện bất biến.
   - **Kiểm tra trùng tiêu đề:** gọi `assignmentRepository.existsByOwnerIdAndTitleIgnoreCase(ownerId, title)`. Nếu tồn tại → ném `BadRequestException("Assignment '<title>' already exists")`. Uniqueness là theo owner, không phân biệt hoa thường, áp dụng cho cả GRADED và PRACTICE.
   - **Kiểm tra strategi:** gọi `validateStrategy(strategy, template)`. Nếu `LECTURER_DOCKER_COMPOSE` và template rỗng → ném `BadRequestException`.
   - **Lưu:** xây dựng `Assignment` entity với `published = false`, lưu qua `assignmentRepository.save(...)`, log thông tin.
   - **Trả về:** `assignmentMapper.toResponse(assignment)`.

**Ví dụ request:**
```http
POST /api/v1/assignments
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
Content-Type: application/json

{
  "title": "Bài kiểm tra CRUD quản lý sinh viên",
  "description": "Bài kiểm tra CRUD cơ bản cho API quản lý sinh viên",
  "classId": "03310ff7-b94f-423a-abf2-6332331c9471",
  "purpose": "GRADED",
  "topic": "quản lý sinh viên",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```

**Ví dụ response (201):**
```json
{
  "id": "16cebadb-2485-4494-be5b-7f6641887559",
  "ownerId": "2be57808-9203-4150-8f29-19aecbe9f725",
  "classId": "03310ff7-b94f-423a-abf2-6332331c9471",
  "title": "Bài kiểm tra CRUD quản lý sinh viên",
  "description": "Bài kiểm tra CRUD cơ bản cho API quản lý sinh viên",
  "purpose": "GRADED",
  "topic": "quản lý sinh viên",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5,
  "published": false,
  "createdAt": "2026-11-01T03:15:35.384324Z",
  "updatedAt": "2026-11-01T03:15:35.384337Z"
}
```

**Mã lỗi có thể xảy ra:**
- `400 BadRequestException`: `classId` bắt buộc cho GRADED, `classId` phải null cho PRACTICE, tiêu đề đã tồn tại, dockerComposeTemplate thiếu cho LECTURER_DOCKER_COMPOSE, validation `@NotBlank`, `@NotNull`, range.
- `404 ResourceNotFoundException`: `classId` không tìm thấy hoặc không thuộc về giảng viên.
- `401/403`: nếu không có quyền LECTURER hoặc header auth lỗi (xử lý trước bởi Spring Security).

---

### 3.2 `listMine` — Lấy danh sách bài tập của mình

**Vị trí:** `AssignmentController.listMine(...)` → `AssignmentService.listMine(...)`

**Endpoint:** `GET /api/v1/assignments`

**Query params:**
| Param | Kiểu | Bắt buộc | Mặc định | Mô tả |
|-------|------|----------|----------|-------|
| `classId` | UUID | — | null | Lọc theo lớp |
| `purpose` | AssignmentPurpose | — | null | Lọc GRADED / PRACTICE |
| `topic` | String | — | null | Lọc chính xác chủ đề (không phân biệt hoa thường) |
| `published` | Boolean | — | null | Lọc theo trạng thái xuất bản |
| `search` | String | — | null | Tìm kiếm trong tiêu đề hoặc chủ đề (chứa chuỗi, không phân biệt hoa thường) |
| `page` | int | — | 0 | Trang (0-based) |
| `size` | int | — | 20 | Kích thước trang |

**Header đầu vào:** `X-User-Id` (giảng viên sở hữu)

**Luồng xử lý:**
1. Controller tạo `Pageable` từ `page` và `size` (`PageRequest.of(page, size)`).
2. Gọi `assignmentService.listMine(ownerId, classId, purpose, topic, published, search, pageable)`.
3. Service trim `search` và `topic` nếu có. Gọi `assignmentRepository.findMine(ownerId, classId, purpose, topic, published, search, pageable)`.
4. Map từng `Assignment` sang `AssignmentResponse` qua `assignmentMapper::toResponse`, trả về `Page<AssignmentResponse>`.

**Ví dụ request:**
```http
GET /api/v1/assignments?classId=03310ff7-b94f-423a-abf2-6332331c9471&purpose=GRADED&search=CRUD&page=0&size=20
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
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
      "topic": "quản lý sinh viên",
      "purpose": "GRADED",
      "published": false,
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

---

### 3.3 `listTopics` — Lấy danh sách chủ đề phân biệt

**Vị trí:** `AssignmentController.listTopics(...)` → `AssignmentService.listTopics(...)`

**Endpoint:** `GET /api/v1/assignments/topics`

**Query params:**
- `purpose` (AssignmentPurpose, bắt buộc): lọc chủ đề theo loại bài tập.

**Header đầu vào:** `X-User-Id`

**Luồng xử lý:**
1. Controller gọi `assignmentService.listTopics(UUID.fromString(ownerId), purpose)`.
2. Service gọi `assignmentRepository.findDistinctTopics(ownerId, purpose)`.
3. Trả về `List<String>` các chủ đề phân biệt, dùng cho bộ lọc topic ở FE.

**Ví dụ request:**
```http
GET /api/v1/assignments/topics?purpose=GRADED
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):**
```json
["quản lý sinh viên", "CRUD cơ bản", "Xử lý lỗi", "Extract & biến"]
```

---

### 3.4 `getById` — Xem chi tiết bài tập

**Vị trí:** `AssignmentController.getById(...)` → `AssignmentService.getById(...)`

**Endpoint:** `GET /api/v1/assignments/{id}`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`

**Luồng xử lý:**
1. Controller gọi `assignmentService.getById(id, UUID.fromString(ownerId))`.
2. Service gọi `requireOwnedAssignment(id, ownerId)`: truy vấn `assignmentRepository.findByIdAndOwnerId(id, ownerId)`. Nếu không tìm thấy → ném `ResourceNotFoundException("Assignment not found: " + id)`.
3. Map sang `AssignmentResponse` qua `assignmentMapper.toResponse`, trả về.

**Ví dụ request:**
```http
GET /api/v1/assignments/16cebadb-2485-4494-be5b-7f6641887559
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):** Giống response của `create` ở mục 3.1.

**Mã lỗi:**
- `404`: bài tập không tồn tại hoặc không thuộc về giảng viên gọi.

---

### 3.5 `update` — Cập nhật bài tập

**Vị trí:** `AssignmentController.update(...)` → `AssignmentService.update(...)`

**Endpoint:** `PUT /api/v1/assignments/{id}`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`

**Request body:** `UpdateAssignmentRequest`

**Luồng xử lý (Service `update`):**

1. Gọi `requireOwnedAssignment(id, ownerId)` để lấy assignment hiện tại. Nếu không tìm thấy → `ResourceNotFoundException`.
2. **Kiểm tra immutability của classId:** nếu request cung cấp `classId` và khác với `assignment.getClassId()` đã lưu → ném `BadRequestException("class_id cannot be changed after creation")`. ClassId không bao giờ thay đổi sau khi tạo, để không làm hỏng ranh giới class/practice và không mồ côni điểm số/kết quả.
3. **Kiểm tra strategi:** gọi `validateStrategy()` với strategi mới (hoặc giữ 전략 cũ nếu request null) và template mới (hoặc cũ).
4. **Kiểm tra trùng tiêu đề:** gọi `assignmentRepository.existsByOwnerIdAndTitleIgnoreCaseAndIdNot(ownerId, title, id)`. Nếu tồn tại (trừ bản hiện tại) → `BadRequestException`.
5. **Cập nhật các trường:** title (trim), topic (trim, bắt buộc không blank, legacy backfill 'Chung'), description (giữ cũ nếu request null), gradingStrategy, dockerComposeTemplate, dockerComposePort, startupTimeoutMs, executionTimeoutMs, maxMemoryMb, maxCpu — chỉ set khi request cung cấp non-null.
6. Lưu qua `assignmentRepository.save(assignment)`, log, trả về `AssignmentResponse`.

**Ví dụ request:**
```http
PUT /api/v1/assignments/16cebadb-2485-4494-be5b-7f6641887559
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
Content-Type: application/json

{
  "title": "Bài kiểm tra CRUD quản lý sinh viên (cập nhật)",
  "topic": "quản lý sinh viên",
  "executionTimeoutMs": 600000
}
```

**Ví dụ response (200):** Giống `AssignmentResponse` ở mục 2.3 với các giá trị mới.

**Mã lỗi:**
- `400`: classId không được thay đổi, tiêu đề trùng, validation lỗi.
- `404`: bài tập không tìm thấy.

---

### 3.6 `delete` — Xóa mềm bài tập

**Vị trí:** `AssignmentController.delete(...)` → `AssignmentService.delete(...)`

**Endpoint:** `DELETE /api/v1/assignments/{id}`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`

**Luồng xử lý (Service `delete`):**
1. Gọi `requireOwnedAssignment(id, ownerId)`. Nếu không tìm thấy → `ResourceNotFoundException`.
2. Gán `assignment.setDeletedAt(OffsetDateTime.now())` — soft-delete, không xóa vật lý.
3. Lưu qua `assignmentRepository.save(assignment)`.
4. Log `"Assignment soft-deleted: id=..., title=..."`.
5. Controller trả về `ResponseEntity.ok().build()` (200 OK, không body).

**Ví dụ request:**
```http
DELETE /api/v1/assignments/16cebadb-2485-4494-be5b-7f6641887559
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):** Rỗng (không body).

---

### 3.7 `publish` — Xuất bản bài tập

**Vị trí:** `AssignmentController.publish(...)` → `AssignmentService.publish(...)`

**Endpoint:** `POST /api/v1/assignments/{id}/publish`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`

**Luồng xử lý (Service `publish`):**
1. Gọi `requireOwnedAssignment(id, ownerId)`. Nếu không tìm thấy → `ResourceNotFoundException`.
2. Nếu `published` chưa true → gán `true`, lưu qua repository, log `"Assignment published: id=..., title=..."`.
3. Nếu đã true rồi → log `"Assignment already published: id=..."`, không thay đổi gì.
4. Trả về `AssignmentResponse` đã map.

**Ví dụ request:**
```http
POST /api/v1/assignments/16cebadb-2485-4494-be5b-7f6641887559/publish
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):** `AssignmentResponse` với `published = true`.

---

## 4. Các hàm helper private trong AssignmentService

### 4.1 `requireOwnedClass(UUID ownerId, UUID classId)`
- **Input:** ownerId, classId.
- **Output:** `CourseClass` nếu tìm thấy.
- **Làm gì:** Truy vấn `courseClassRepository.findByIdAndOwnerId(classId, ownerId)`. Nếu null → ném `ResourceNotFoundException("Class not found: " + classId)`. Dùng để đảm bảo giảng viên chỉ tạo bài GRADED cho lớp sở hữu.

### 4.2 `requireOwnedAssignment(UUID id, UUID ownerId)`
- **Input:** id bài tập, ownerId.
- **Output:** `Assignment` nếu tìm thấy.
- **Làm gì:** Truy vấn `assignmentRepository.findByIdAndOwnerId(id, ownerId)`. Nếu null → ném `ResourceNotFoundException("Assignment not found: " + id)`. Dùng ở tất cả endpoint đọc/ghi chi tiết để kiểm soát sở hữu.

### 4.3 `validateStrategy(GradingStrategy strategy, String template)`
- **Input:** strategi chấm điểm, template docker-compose.
- **Output:** void.
- **Làm gì:** Nếu strategi là `LECTURER_DOCKER_COMPOSE` và template rỗng/null → ném `BadRequestException("dockerComposeTemplate is required for LECTURER_DOCKER_COMPOSE strategy")`.

---

## 5. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 400 | Validation `@NotBlank`, `@NotNull`, range (`@Min`, `@Max`, `@DecimalMin`, `@DecimalMax`) | Spring Validation / controller |
| 400 | `classId` bắt buộc cho GRADED / phải null cho PRACTICE | `AssignmentService.create` |
| 400 | Tiêu đề đã tồn tại (owner-scoped) | `AssignmentService.create`, `update` |
| 400 | `dockerComposeTemplate` thiếu cho LECTURER_DOCKER_COMPOSE | `AssignmentService.validateStrategy` |
| 400 | Không thể đổi `classId` sau khi tạo | `AssignmentService.update` |
| 404 | Lớp không tìm thấy / không thuộc giảng viên | `AssignmentService.requireOwnedClass` |
| 404 | Bài tập không tìm thấy / không thuộc giảng viên | `AssignmentService.requireOwnedAssignment` |
| 401/403 | Không có quyền LECTURER / auth lỗi | Spring Security (`@PreAuthorize`) |

---

## 6. Luồng dữ liệu từ đầu đến cuối (ví dụ tạo bài)

```
Giảng viên (FE)
   │ POST /api/v1/assignments + body CreateAssignmentRequest + header X-User-Id
   ▼
Gateway (xác thực JWT, stamps X-User-Id từ token)
   │
   ▼
course-service: AssignmentController.create()
   │ 1. Chuyển ownerId String → UUID
   │ 2. Gọi AssignmentService.create(ownerId, request)
   ▼
AssignmentService.create()
   │ 3. Xác định purpose, classId, topic (trim)
   │ 4. Nếu GRADED: requireOwnedClass → kiểm tra lớp tồn tại & sở hữu
   │ 5. Kiểm tra trùng tiêu đề (existsByOwnerIdAndTitleIgnoreCase)
   │ 6. validateStrategy
   │ 7. Tạo Assignment entity (published=false), lưu repository
   │ 8. Map → AssignmentResponse
   ▼
AssignmentController.create()
   │ 9. Trả về ResponseEntity 201 CREATED + AssignmentResponse
   ▼
Gateway → FE nhận JSON bài tập vừa tạo
```

---

*Tài liệu này là phần đầu của bộ dokument chi tiết luồng API theo plan mode. Các service/controller khác sẽ được viết tiếp theo theo cùng mẫu, tất cả nằm trong thư mục `docs/api/docs/`.*
