# AssignmentService — bài tập & publish (course-service)

Bổ sung cho `assignment-controller.md`. Tài liệu mô tả từng hàm, từng map DTO ↔ entity, các bất biến
(immutable) và ảnh hưởng của `publish` tới điểm `EXERCISE`.

- Lớp: `course-service/service/AssignmentService.java`
- Mapper: `course-service/mapper/AssignmentMapper.java` (MapStruct, `componentModel = "spring"`)
- Bảng DB: `assignments` (soft-delete), `course_classes`
- Controller: `AssignmentController` (`/api/v1/assignments`), `StudentAssignmentController` (đọc phía sinh viên)

---

## 1. Hai loại bài tập

| `purpose` | `classId` | Ai thấy | Vào điểm lớp? |
|---|---|---|---|
| `GRADED` | **bắt buộc**, lớp phải thuộc giảng viên | sinh viên trong lớp (sau khi publish) | **có** — nguồn của thành phần `EXERCISE` |
| `PRACTICE` | **bắt buộc null** | mọi sinh viên (sau khi publish), không cần enrollment | không |

Ranh giới này được chốt **lúc tạo** và không đổi được về sau (`class_id cannot be changed after creation`).

---

## 2. Bảng tổng hợp hàm

| Hàm | Input | Output | Ghi chú |
|---|---|---|---|
| `create(ownerId, CreateAssignmentRequest)` | UUID + DTO | `AssignmentResponse` | `@Transactional`, `published=false` |
| `listMine(ownerId, classId, purpose, topic, published, search, pageable)` | 7 tham số | `Page<AssignmentResponse>` | ủy quyền cho repository |
| `listTopics(ownerId, purpose)` | 2 tham số | `List<String>` | topic distinct |
| `getById(id, ownerId)` | 2 UUID | `AssignmentResponse` | 404 nếu không sở hữu |
| `update(id, ownerId, UpdateAssignmentRequest)` | 2 UUID + DTO | `AssignmentResponse` | partial update |
| `delete(id, ownerId)` | 2 UUID | `void` | soft-delete |
| `publish(id, ownerId)` | 2 UUID | `AssignmentResponse` | idempotent |

Helper private: `requireOwnedClass`, `requireOwnedAssignment`, `validateStrategy`.

---

## 3. Chi tiết từng hàm

### 3.1 `create(UUID ownerId, CreateAssignmentRequest request)`

Input (`CreateAssignmentRequest`, tất cả field + ràng buộc):

| Trường | Kiểu | Bắt buộc | Mặc định | Ràng buộc |
|---|---|---|---|---|
| `title` | String | ✔ `@NotBlank` | — | duy nhất theo owner, không phân biệt hoa/thường |
| `description` | String | ✖ | null | |
| `classId` | UUID | tuỳ `purpose` | null | `GRADED`: bắt buộc + phải thuộc owner; `PRACTICE`: phải null |
| `purpose` | `AssignmentPurpose` | ✖ | `GRADED` | `GRADED` / `PRACTICE` |
| `topic` | String | ✔ `@NotBlank` | — | `trim()`; null nếu rỗng |
| `gradingStrategy` | `GradingStrategy` | ✖ | `STUDENT_DOCKER_COMPOSE` | `STUDENT_DOCKER_COMPOSE` / `LECTURER_DOCKER_COMPOSE` |
| `dockerComposeTemplate` | String | điều kiện | null | bắt buộc khi strategy = `LECTURER_DOCKER_COMPOSE` |
| `dockerComposePort` | Integer | ✖ | `8080` | `@NotNull @Min(1) @Max(65535)` |
| `startupTimeoutMs` | Integer | ✖ | `60000` | `@NotNull @Min(1)` |
| `executionTimeoutMs` | Integer | ✖ | `300000` | `@NotNull @Min(1)` |
| `maxMemoryMb` | Integer | ✖ | `256` | `@NotNull @Min(64)` |
| `maxCpu` | Double | ✖ | `0.5` | `@NotNull @DecimalMin("0.1") @DecimalMax("16.0")` |

Thứ tự kiểm tra (giữ nguyên để thông điệp lỗi khớp tài liệu):

```
1. purpose rỗng → GRADED
2. nếu GRADED:   classId == null            → 400 "classId is required for GRADED assignments"
                 requireOwnedClass(...)      → 404 "Class not found: {classId}"
   nếu PRACTICE: classId != null            → 400 "classId must be null for PRACTICE assignments"
3. title = trim(title)
   existsByOwnerIdAndTitleIgnoreCase(owner,title) → 400 "Assignment '{title}' already exists"
4. validateStrategy(strategy, template)
   LECTURER_DOCKER_COMPOSE && template rỗng  → 400 "dockerComposeTemplate is required for LECTURER_DOCKER_COMPOSE strategy"
5. save(...) với published = false
```

Lưu ý: `title` duy nhất trên **toàn bộ bài của một giảng viên**, không phải theo lớp — nên không thể
đặt trùng tên cho một bài `GRADED` và một bài `PRACTICE`.

### 3.2 `listMine(...)`

Không xử lý nghiệp vụ, chỉ chuẩn hoá đầu vào rồi gọi
`assignmentRepository.findMine(ownerId, classId, purpose, topic, published, search, pageable)`:

| Tham số | Chuẩn hoá |
|---|---|
| `search` | trim; rỗng → `null` (không lọc) |
| `topic` | trim; rỗng → `null` |
| `classId`, `purpose`, `published` | truyền nguyên (null = không lọc) |

Output: `Page<AssignmentResponse>` (đã bọc `ResultPaginationDTO` ở tầng response advice).

### 3.3 `listTopics(ownerId, purpose)`

`findDistinctTopics(ownerId, purpose)` → danh sách `String` đã distinct, dùng cho bộ lọc topic ở FE.
`purpose` null = gộp cả hai loại.

### 3.4 `getById(id, ownerId)`

`requireOwnedAssignment` → map. 404 khi bài không tồn tại **hoặc** của giảng viên khác (không phân biệt).

### 3.5 `update(id, ownerId, UpdateAssignmentRequest)`

| Trường | Kiểu | Bắt buộc | Nếu null | Nếu có giá trị |
|---|---|---|---|---|
| `title` | String | ✔ `@NotBlank` | — (400 từ validation) | `trim()` rồi đổi; kiểm tra trùng (trừ chính nó) |
| `description` | String | ✖ | giữ nguyên | thay |
| `classId` | UUID | giữ nguyên | chỉ chấp nhận **đúng giá trị cũ**; khác → 400 `class_id cannot be changed after creation` |
| `topic` | String ✔ `@NotBlank` | — (400 từ validation) | trim + thay |
| `gradingStrategy` | enum | giữ nguyên | thay |
| `dockerComposeTemplate` | String | giữ nguyên | thay |
| `dockerComposePort` `@Min(1) @Max(65535)` | Integer | giữ nguyên | thay |
| `startupTimeoutMs` | Integer | giữ nguyên | thay |
| `executionTimeoutMs` | Integer | giữ nguyên | thay |
| `maxMemoryMb` | Integer | giữ nguyên | thay |
| `maxCpu` `@DecimalMin(0.1) @DecimalMax(16.0)` | Double | giữ nguyên | thay |

`validateStrategy` chạy trên **giá trị hiệu lực** (request nếu có, ngược lại giá trị đang lưu), nên
không thể "lách" bằng cách đổi strategy mà bỏ trống template.

### 3.6 `delete(id, ownerId)`

Soft-delete: set `deletedAt = now`, lưu. Không xoá plan/step/result (chúng vẫn còn nhưng không truy vấn
được qua assignment đã xoá). Trả 204.

### 3.7 `publish(id, ownerId)` — quan trọng cho tính điểm

```
requireOwnedAssignment
if published != true:
    published = true; save; log "Assignment published"
else:
    log "Assignment already published"      // idempotent, không lỗi
return AssignmentResponse
```

Ảnh hưởng dây chuyền:

| Hệ quả | Ở đâu |
|---|---|
| Sinh viên thấy bài trong `GET /api/v1/student/assignments` | course-service |
| Bài `GRADED` bắt đầu được tính vào `EXERCISE` | `ScoreService.computeExercise` — chỉ lấy `published = true` |
| Bài `PRACTICE` xuất hiện cho mọi sinh viên (không cần enrollment) | student query |
| `internalExists` trả `true` cho executor | `TestPlanService.internalExists` |

Vì vậy một bài `GRADED` còn draft **không** kéo điểm `EXERCISE` của cả lớp xuống 0 — đây là lý do có
điều kiện `published = true` trong cả ba chỗ (single read, transcript, batch).

---

## 4. Map `Assignment` ↔ `AssignmentResponse` (AssignmentMapper)

MapStruct map theo tên; các trường enum được đổi sang `String`:

| Entity `Assignment` | DTO `AssignmentResponse` | Quy tắc |
|---|---|---|
| `id` | `id` | |
| `ownerId` | `ownerId` | |
| `classId` | `classId` | null với `PRACTICE` |
| `title` | `title` | |
| `description` | `description` | |
| `purpose` (`AssignmentPurpose`) | `purpose` (String) | `GRADED` / `PRACTICE` |
| `topic` | `topic` | |
| `gradingStrategy` (`GradingStrategy`) | `gradingStrategy` (String) | enum name |
| `dockerComposeTemplate` | `dockerComposeTemplate` | |
| `dockerComposePort` | `dockerComposePort` | |
| `startupTimeoutMs` | `startupTimeoutMs` | |
| `executionTimeoutMs` | `executionTimeoutMs` | |
| `maxMemoryMb` | `maxMemoryMb` | |
| `maxCpu` | `maxCpu` | |
| `published` | `published` | |
| `createdAt`, `updatedAt` (`BaseEntity`) | `createdAt`, `updatedAt` | |
| `deletedAt` | — | không expose |

## 5. Map `CreateAssignmentRequest` → `Assignment` (thủ công trong `create`)

| Request | Entity | Quy tắc |
|---|---|---|
| `title` | `title` | `trim()` |
| `description` | `description` | nguyên văn |
| `classId` | `classId` | đã validate theo `purpose` |
| `purpose` | `purpose` | `null → GRADED` |
| `topic` | `topic` | `trim()`; rỗng → `null` |
| `gradingStrategy` | `gradingStrategy` | |
| `dockerComposeTemplate` | `dockerComposeTemplate` | |
| `dockerComposePort` | `dockerComposePort` | |
| `startupTimeoutMs` | `startupTimeoutMs` | |
| `executionTimeoutMs` | `executionTimeoutMs` | |
| `maxMemoryMb` | `maxMemoryMb` | |
| `maxCpu` | `maxCpu` | |
| — | `ownerId` | từ JWT (`X-User-Id`) |
| — | `published` | luôn `false` khi tạo |

---

## 6. Bảng lỗi

| HTTP | Điều kiện | Thông điệp |
|---|---|---|
| 400 | `GRADED` thiếu class | `classId is required for GRADED assignments` |
| 400 | `PRACTICE` có class | `classId must be null for PRACTICE assignments` |
| 400 | trùng title (create) | `Assignment '{title}' already exists` |
| 400 | trùng title (update) | `Assignment '{title}' already exists` |
| 400 | đổi class khi update | `class_id cannot be changed after creation` |
| 400 | thiếu template | `dockerComposeTemplate is required for LECTURER_DOCKER_COMPOSE strategy` |
| 400 | body sai kiểu/thiếu field | `Validation failed` + `errors[]` |
| 404 | không sở hữu / không tồn tại | `Assignment not found: {id}` |
| 404 | lớp không thuộc owner | `Class not found: {classId}` |
| 409 | vi phạm ràng buộc DB | `Resource already exists or violates a constraint` |

---

## 7. Luồng dữ liệu

```
POST /api/v1/assignments
  {title, description, classId, purpose:GRADED, topic, gradingStrategy, dockerComposePort, ...}
    → AssignmentController.create (ownerId từ JWT)
    → purpose mặc định GRADED
    → GRADED: requireOwnedClass | PRACTICE: classId phải null
    → title unique theo owner
    → validateStrategy
    → INSERT assignments (published=false, owner_id=sub)
    → 201 AssignmentResponse

PUT /api/v1/assignments/{id}/publish
    → AssignmentController.publish
    → requireOwnedAssignment
    → published=true (idempotent)
    → 200 AssignmentResponse
    ↓  (hiệu lực)
    GET /api/v1/student/assignments        → sinh viên thấy bài
    ScoreService.computeExercise           → bài GRADED đã publish vào điểm EXERCISE
```
