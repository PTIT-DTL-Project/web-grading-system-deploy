# Tài liệu chi tiết luồng API — course-service / TestPlanController

Nơi lưu: `docs/api/docs/course-service/test-plan-controller.md`

Mục đích: giải thích chi tiết từng hàm/controller/service trong luồng quản lý test plan/test step của giảng viên (TestPlanController), bao gồm input, output, điều kiện tiên quyết, ví dụ request/response, và các mã lỗi có thể xảy ra. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`TestPlanController` là REST controller của service `course-service`, trỏ về base path `/api/v1/assignments/{assignmentId}`. Nó cung cấp các endpoint cho giảng viên (LECTURER) để quản lý test plan (câu hỏi) và test step (bước chấm điểm) của một bài tập.

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/assignments/{assignmentId}/plans/with-steps` | POST | Tạo plan kèm các bước (tạo câu hỏi hoàn chỉnh) | LECTURER |
| `/api/v1/assignments/{assignmentId}/plans` | POST | Tạo plan mới | LECTURER |
| `/api/v1/assignments/{assignmentId}/plans` | GET | Lấy danh sách plan của bài tập | LECTURER |
| `/api/v1/assignments/{assignmentId}/plans/{planId}` | PUT | Cập nhật plan | LECTURER |
| `/api/v1/assignments/{assignmentId}/plans/{planId}` | DELETE | Xóa mềm plan (và các bước) | LECTURER |
| `/api/v1/assignments/{assignmentId}/plans/{planId}/steps` | POST | Tạo bước cho plan | LECTURER |
| `/api/v1/assignments/{assignmentId}/plans/{planId}/steps` | GET | Lấy danh sách bước của plan (flat) | LECTURER |
| `/api/v1/assignments/{assignmentId}/plans/{planId}/steps/{stepId}` | PUT | Cập nhật bước | LECTURER |
| `/api/v1/assignments/{assignmentId}/plans/{planId}/steps/{stepId}` | DELETE | Xóa mềm bước | LECTURER |

Tất cả endpoint đều `@PreAuthorize("hasRole('LECTURER')")`, nhận `X-User-Id` từ header. Controller giao tiếp với `TestPlanService` để thực hiện logic nghiệp vụ.

---

## 2. DTO liên quan

### 2.1 `CreateQuestionRequest` (dto/request)
Tạo plan kèm các bước trong một request.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `plan` | `CreatePlanRequest` | ✅ | Thông tin plan |
| `steps` | `List<CreateStepRequest>` | ✅ | Danh sách bước của plan |

### 2.2 `CreatePlanRequest` (dto/request)
Tạo plan mới.

| Trường | Kiểu | Bắt buộc | Mặc định | Mô tả |
|--------|------|----------|----------|-------|
| `name` | String | `@NotBlank` | — | Tên plan |
| `description` | String | — | null | Mô tả |
| `sequenceOrder` | Integer | `@NotNull`, `@Min(0)` | — | Thứ tự plan |
| `weight` | Integer | `@Min(1)` | 1 | Trọng số |

### 2.3 `UpdatePlanRequest` (dto/request)
Cập nhật plan.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `name` | String | `@NotBlank` | — | Tên mới |
| `description` | String | — | null | Mô tả mới |
| `sequenceOrder` | Integer | — | null | Thứ tự mới (không được trùng) |
| `weight` | Integer | — | null | Trọng số mới |

### 2.4 `CreateStepRequest` (dto/request)
Tạo bước mới.

| Trường | Kiểu | Bắt buộc | Mặc định | Mô tả |
|--------|------|----------|----------|-------|
| `stepOrder` | Integer | `@NotNull`, `@Min(0)` | — | Thứ tự bước |
| `name` | String | `@NotBlank` | — | Tên bước |
| `description` | String | — | null | Mô tả |
| `stepType` | StepType | `@NotNull` | — | Loại bước |
| `config` | JsonNode | — | null | JSON config |
| `expectedResult` | JsonNode | — | null | JSON kết quả kỳ vọng |
| `weight` | Integer | `@Min(1)` | 1 | Trọng số |
| `timeoutMs` | Integer | `@Min(1)` | null | Timeout (ms) |
| `required` | Boolean | — | true | Bắt buộc |

### 2.5 `UpdateStepRequest` (dto/request)
Cập nhật bước.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `stepOrder` | Integer | — | null | Thứ tự mới |
| `name` | String | `@NotBlank` | — | Tên mới |
| `description` | String | — | null | Mô tả mới |
| `stepType` | StepType | — | null | Loại mới (nếu đổi thì config bắt buộc) |
| `config` | JsonNode | — | null | Config mới |
| `expectedResult` | JsonNode | — | null | Kết quả kỳ vọng mới |
| `weight` | Integer | — | null | Trọng số mới |
| `timeoutMs` | Integer | — | null | Timeout mới |
| `required` | Boolean | — | null | Bắt buộc mới |

### 2.6 `PlanResponse` (dto/response)
Trả về plan kèm danh sách bước.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID plan |
| `name` | String | Tên plan |
| `description` | String | Mô tả |
| `sequenceOrder` | Integer | Thứ tự |
| `weight` | Integer | Trọng số |
| `steps` | `List<StepResponse>` | Danh sách bước |

### 2.7 `StepResponse` (dto/response)
Thông tin một bước.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID bước |
| `stepOrder` | Integer | Thứ tự |
| `name` | String | Tên bước |
| `description` | String | Mô tả |
| `type` | String | Loại bước |
| `config` | JsonNode | Config |
| `expectedResult` | JsonNode | Kết quả kỳ vọng |
| `weight` | Integer | Trọng số |
| `timeoutMs` | Integer | Timeout |
| `required` | Boolean | Bắt buộc |

### 2.8 `StepType` (entity)
Enum: `HTTP_REQUEST`, `DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`, `EXTRACT`, `DELAY`.

---

## 3. Chi tiết từng hàm

### 3.1 `createQuestion` — Tạo plan kèm các bước (tạo câu hỏi hoàn chỉnh)

**Vị trí:** `TestPlanController.createQuestion(...)` → `TestPlanService.createQuestion(...)`

**Endpoint:** `POST /api/v1/assignments/{assignmentId}/plans/with-steps`

**Path variable:** `assignmentId` (UUID)

**Header đầu vào:** `X-User-Id`

**Request body:** `CreateQuestionRequest`

**Luồng xử lý:**
1. Controller gọi `testPlanService.createQuestion(assignmentId, UUID.fromString(ownerId), request)`. Trả về `201 CREATED`.
2. Service `createQuestion`:
   - Gọi `createPlan(assignmentId, ownerId, request.getPlan())` → tạo plan, trả về `PlanResponse` có `id`.
   - Duyệt `request.getSteps()`, gọi `createStep(assignmentId, ownerId, created.getId(), step)` cho mỗi bước.
   - Truy vấn lại danh sách plan, lọc plan vừa tạo (`plan.getId().equals(created.getId())`), trả về `PlanResponse` đầy đủ (có steps).

**Ví dụ request:**
```http
POST /api/v1/assignments/16cebadb-2485-4494-be5b-7f6641887559/plans/with-steps
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
Content-Type: application/json

{
  "plan": { "name": "Câu 1", "description": "...", "sequenceOrder": 1, "weight": 100 },
  "steps": [
    { "stepOrder": 1, "name": "POST tạo sinh viên", "stepType": "HTTP_REQUEST", "config": {...}, "weight": 30 }
  ]
}
```

**Ví dụ response (201):** Giống `PlanResponse` kèm `steps`.

**Mã lỗi:**
- `400`: trùng `sequenceOrder` của plan, trùng `step_order` của bước, config bước không hợp lệ (qua `StepConfigValidator`).
- `404`: assignment không tồn tại hoặc không thuộc giảng viên.

---

### 3.2 `createPlan` — Tạo plan mới

**Vị trí:** `TestPlanController.createPlan(...)` → `TestPlanService.createPlan(...)`

**Endpoint:** `POST /api/v1/assignments/{assignmentId}/plans`

**Luồng xử lý (Service `createPlan`):**
1. Gọi `requireOwnedAssignment(assignmentId, ownerId)` → kiểm tra assignment tồn tại và sở hữu.
2. Trim `name`.
3. Kiểm tra `testPlanRepository.existsByAssignmentIdAndSequenceOrder(assignmentId, sequenceOrder)`. Nếu có → `BadRequestException("A plan with sequence_order X already exists in this assignment")`.
4. Tạo `TestPlan` với `assignmentId`, `name`, `description`, `sequenceOrder`, `weight` (mặc định 1), lưu qua repository.
5. Log `"Test plan created: id=..., name=..., assignment=..."`.
6. Trả về `toPlanResponse(plan, List.of())` (plan rỗng chưa có bước).

**Ví dụ request:**
```http
POST /api/v1/assignments/16cebadb-2485-4494-be5b-7f6641887559/plans
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
Content-Type: application/json

{ "name": "Câu 1: Tạo sinh viên mới", "sequenceOrder": 1, "weight": 100 }
```

**Ví dụ response (201):** `PlanResponse` với `steps = []`.

---

### 3.3 `listPlans` — Lấy danh sách plan của bài tập

**Vị trí:** `TestPlanController.listPlans(...)` → `TestPlanService.listPlans(...)`

**Endpoint:** `GET /api/v1/assignments/{assignmentId}/plans`

**Luồng xử lý (Service `listPlans`):**
1. Gọi `requireOwnedAssignment(assignmentId, ownerId)`.
2. Truy vấn `testPlanRepository.findAllByAssignmentIdOrderBySequenceOrderAsc(assignmentId)`.
3. Nếu rỗng → trả về `List.of()`.
4. Truy vấn tất cả bước của tất cả plan (`findAllByPlanIdInOrderByStepOrderAsc`).
5. Map từng plan sang `PlanResponse` với `steps` là các bước thuộc plan đó (đã sắp xếp theo `stepOrder`).

**Ví dụ request:**
```http
GET /api/v1/assignments/16cebadb-2485-4494-be5b-7f6641887559/plans
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):** `List<PlanResponse>` mỗi plan có danh sách `steps`.

---

### 3.4 `updatePlan` — Cập nhật plan

**Vị trí:** `TestPlanController.updatePlan(...)` → `TestPlanService.updatePlan(...)`

**Endpoint:** `PUT /api/v1/assignments/{assignmentId}/plans/{planId}`

**Luồng xử lý (Service `updatePlan`):**
1. `requireOwnedAssignment(assignmentId, ownerId)`.
2. `requirePlan(planId, assignmentId)` → `testPlanRepository.findByIdAndAssignmentId(planId, assignmentId)`, null → `ResourceNotFoundException`.
3. Nếu `sequenceOrder` được cung cấp và khác với giá trị hiện tại → kiểm tra trùng `existsByAssignmentIdAndSequenceOrder`. Nếu trùng → `BadRequestException`.
4. Cập nhật `name` (trim), `description` (nếu non-null), `sequenceOrder` (nếu non-null), `weight` (nếu non-null).
5. Lưu, log, trả về `toPlanResponse(plan, steps của plan)`.

**Ví dụ request:**
```http
PUT /api/v1/assignments/.../plans/{planId}
X-User-Id: ...
Content-Type: application/json

{ "name": "Câu 1 (cập nhật)", "weight": 150 }
```

---

### 3.5 `deletePlan` — Xóa mềm plan

**Vị trí:** `TestPlanController.deletePlan(...)` → `TestPlanService.deletePlan(...)`

**Endpoint:** `DELETE /api/v1/assignments/{assignmentId}/plans/{planId}`

**Luồng xử lý (Service `deletePlan`):**
1. `requireOwnedAssignment(assignmentId, ownerId)`.
2. `requirePlan(planId, assignmentId)`.
3. Lấy `now = OffsetDateTime.now()`.
4. Duyệt tất cả bước của plan, gán `deletedAt = now`, lưu tất cả (`saveAll`).
5. Gán `plan.setDeletedAt(now)`, lưu plan.
6. Log `"Test plan soft-deleted with its steps: id=..., assignment=..."`.
7. Controller trả về `200 OK` (không body).

**Ghi chú:** Soft-delete, không xóa vật lý.

---

### 3.6 `createStep` — Tạo bước cho plan

**Vị trí:** `TestPlanController.createStep(...)` → `TestPlanService.createStep(...)`

**Endpoint:** `POST /api/v1/assignments/{assignmentId}/plans/{planId}/steps`

**Luồng xử lý (Service `createStep`):**
1. `requireOwnedAssignment(assignmentId, ownerId)`.
2. `requirePlan(planId, assignmentId)`.
3. Validate config: `StepConfigValidator.validateAndSerialize(request.getStepType(), request.getConfig())`. Nếu `IllegalArgumentException` → `BadRequestException(e.getMessage())`.
4. Serialize `expectedResult` nếu có (`serializeIfPresent`).
5. Kiểm tra `testStepRepository.existsByPlanIdAndStepOrder(planId, order)`. Nếu có → `BadRequestException("step_order X already exists in plan '...'")`.
6. Tạo `TestStep` với `planId`, `stepOrder`, `name` (trim), `description`, `stepType`, `config` (chuỗi JSON), `expectedResult`, `weight` (mặc định 1), `timeoutMs`, `required` (mặc định true).
7. Lưu, log, trả về `toStepResponse(step)`.

**Ví dụ request:**
```http
POST /api/v1/assignments/.../plans/{planId}/steps
X-User-Id: ...
Content-Type: application/json

{ "stepOrder": 1, "name": "POST tạo sinh viên", "stepType": "HTTP_REQUEST", "config": {...}, "weight": 30 }
```

---

### 3.7 `listSteps` — Lấy danh sách bước của plan (flat)

**Vị trí:** `TestPlanController.listSteps(...)`

**Endpoint:** `GET /api/v1/assignments/{assignmentId}/plans/{planId}/steps`

**Luồng xử lý:**
1. Gọi `testPlanService.listPlans(assignmentId, ownerId)` → danh sách plan (mỗi plan đã nesting steps).
2. Lọc plan có `id` bằng `planId`. Nếu không tìm thấy → `ResourceNotFoundException("Plan not found: " + planId)`.
3. Trả về `plan.getSteps()` (danh sách bước flat, đã sắp xếp theo `stepOrder`).

**Ghi chú:** Danh sách plan đã nesting steps từ service, nên controller chỉ lọc và trích xuất.

---

### 3.8 `updateStep` — Cập nhật bước

**Vị trí:** `TestPlanController.updateStep(...)` → `TestPlanService.updateStep(...)`

**Endpoint:** `PUT /api/v1/assignments/{assignmentId}/plans/{planId}/steps/{stepId}`

**Luồng xử lý (Service `updateStep`):**
1. `requireOwnedAssignment(assignmentId, ownerId)`.
2. `requirePlan(planId, assignmentId)`.
3. `requireStep(stepId, planId)` → `testStepRepository.findByIdAndPlanId(stepId, planId)`, null → `ResourceNotFoundException`.
4. Nếu `stepType` được đổi và `config` null → `BadRequestException("config is required when changing stepType to ...")`.
5. Xác định `effectiveType` (mới hoặc cũ). Lấy `effectiveConfig` (mới hoặc parse từ config cũ).
6. `validateAndSerialize(effectiveType, effectiveConfig)`. Nếu lỗi → `BadRequestException`.
7. Nếu `stepOrder` đổi và trùng với bước khác trong plan → `BadRequestException("step_order X already exists in this plan — free the slot first ...")`.
8. Cập nhật các trường: `name` (trim), `description` (nếu non-null), `stepType` (nếu đổi), `config`, `expectedResult` (nếu non-null), `weight`, `timeoutMs`, `required`.
9. Lưu, log, trả về `toStepResponse(step)`.

---

### 3.9 `deleteStep` — Xóa mềm bước

**Vị trí:** `TestPlanController.deleteStep(...)` → `TestPlanService.deleteStep(...)`

**Endpoint:** `DELETE /api/v1/assignments/{assignmentId}/plans/{planId}/steps/{stepId}`

**Luồng xử lý (Service `deleteStep`):**
1. `requireOwnedAssignment(assignmentId, ownerId)`.
2. `requirePlan(planId, assignmentId)`.
3. `requireStep(stepId, planId)`.
4. Gán `step.setDeletedAt(OffsetDateTime.now())`, lưu.
5. Log `"Test step soft-deleted: id=..., plan=..."`.
6. Controller trả về `200 OK` (không body).

---

## 4. Các hàm private helper trong TestPlanService

### 4.1 `requireOwnedAssignment(UUID assignmentId, UUID ownerId)`
- `assignmentRepository.findByIdAndOwnerId(assignmentId, ownerId)`. Null → `ResourceNotFoundException`.

### 4.2 `requirePlan(UUID planId, UUID assignmentId)`
- `testPlanRepository.findByIdAndAssignmentId(planId, assignmentId)`. Null → `ResourceNotFoundException("Plan not found: " + planId)`.

### 4.3 `requireStep(UUID stepId, UUID planId)`
- `testStepRepository.findByIdAndPlanId(stepId, planId)`. Null → `ResourceNotFoundException("Step not found: " + stepId)`.

### 4.4 `toPlanResponse(TestPlan plan, List<TestStep> steps)`
- Map plan sang `PlanResponse`, steps map qua `toStepResponse`.

### 4.5 `toStepResponse(TestStep step)`
- Map bước sang `StepResponse`, parse `config` và `expectedResult` từ chuỗi JSON sang `JsonNode`.

### 4.6 `serializeIfPresent(JsonNode node)`
- Nếu null → null. Ngược lại `objectMapper.writeValueAsString(node)`. Lỗi → `IllegalArgumentException`.

### 4.7 `rootMessage(Throwable t)`
- Lấy message gốc của exception (duyệt qua cause).

---

## 5. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 400 | Validation `@NotBlank`, `@NotNull`, `@Min` | Spring Validation |
| 400 | Trùng `sequence_order` của plan | `TestPlanService.createPlan`, `updatePlan` |
| 400 | Trùng `step_order` của bước | `TestPlanService.createStep`, `updateStep` |
| 400 | Config bước không hợp lệ (thiếu trường, kiểu sai) | `TestPlanService.createStep`, `updateStep` (qua `StepConfigValidator`) |
| 400 | Đổi `stepType` mà không cung cấp `config` | `TestPlanService.updateStep` |
| 404 | Assignment không tồn tại / không thuộc giảng viên | `TestPlanService.requireOwnedAssignment` |
| 404 | Plan không tồn tại / không thuộc assignment | `TestPlanService.requirePlan` |
| 404 | Bước không tồn tại / không thuộc plan | `TestPlanService.requireStep` |
| 401/403 | Không có quyền LECTURER | Spring Security |

---

## 6. Luồng dữ liệu từ đầu đến cuối (ví dụ giảng viên tạo câu hỏi_complete)

```
Giảng viên (FE)
   │ POST /api/v1/assignments/{id}/plans/with-steps
   │    body: { plan: {...}, steps: [{stepType, config}, ...] }
   │    header X-User-Id: 2be57808-...
   ▼
course-service: TestPlanController.createQuestion()
   │ 1. Chuyển ownerId String → UUID
   │ 2. Gọi TestPlanService.createQuestion(assignmentId, ownerId, request)
   ▼
TestPlanService.createQuestion()
   │ 3. createPlan(...) → kiểm tra sở hữu assignment, kiểm tra trùng sequence_order
   │ 4. Lưu TestPlan, trả về PlanResponse (có id)
   │ 5. Với mỗi bước: createStep(...) → validate config qua StepConfigValidator
   │ 6. Lưu TestStep, kiểm tra trùng step_order
   │ 7. Truy vấn lại plan vừa tạo, map → PlanResponse đầy đủ (có steps)
   ▼
TestPlanController.createQuestion()
   │ 8. Trả về ResponseEntity 201 CREATED + PlanResponse
   ▼
FE nhận câu hỏi vừa tạo (plan + các bước đã validate)
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/course-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
