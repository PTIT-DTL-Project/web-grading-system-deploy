# TestPlanService — câu hỏi chấm & các bước (course-service)

Bổ sung cho `test-plan-controller.md` (tầng HTTP). Tài liệu này mô tả **từng hàm** của service,
**từng map** DTO ↔ entity, và toàn bộ luật validate `config` của bước chấm.

- Lớp: `course-service/service/TestPlanService.java`
- Validate config: `course-service/service/StepConfigValidator.java`
- Bảng DB: `test_plans`, `test_steps` (cả hai soft-delete), `assignments`
- Controller: `TestPlanController` (route gốc `/api/v1/assignments/{assignmentId}`),
  `InternalTestPlanController` (route `/api/v1/internal/assignments/{id}/…`, không qua gateway)

---

## 1. Mô hình dữ liệu

```
assignment (1) ───< test_plan (1) ───< test_step
   id                 id                id
   owner_id           assignment_id     plan_id
   published          name              step_order
   grading_strategy   sequence_order    step_type
   docker_*           weight            config            (JSON dạng chuỗi)
   timeouts/mem/cpu   deleted_at        expected_result   (JSON dạng chuỗi)
                                        weight, timeout_ms, required
                                        deleted_at
```

- **Plan** = một "câu hỏi" trong bài; `sequence_order` duy nhất trong một bài; `weight` là trọng số
  của câu (tương đối trong bài).
- **Step** = một bước chấm trong câu; `step_order` duy nhất trong một plan; `weight` tương đối
  trong plan; `required` = bắt buộc pass (dùng ở tầng executor).
- `config` / `expected_result` lưu **chuỗi JSON** trong DB, ra/vào API dưới dạng object.

---

## 2. Bảng tổng hợp hàm

| Hàm | Input | Output | Ghi chú |
|---|---|---|---|
| `createQuestion(assignmentId, ownerId, CreateQuestionRequest)` | 2 UUID + DTO | `PlanResponse` (kèm steps) | transaction: tạo plan + n steps |
| `createPlan(assignmentId, ownerId, CreatePlanRequest)` | 2 UUID + DTO | `PlanResponse` (steps rỗng) | |
| `listPlans(assignmentId, ownerId)` | 2 UUID | `List<PlanResponse>` | 1 query plan + 1 query step |
| `updatePlan(assignmentId, ownerId, planId, UpdatePlanRequest)` | 3 UUID + DTO | `PlanResponse` | partial update |
| `deletePlan(assignmentId, ownerId, planId)` | 3 UUID | `void` | soft-delete plan + steps |
| `createStep(assignmentId, ownerId, planId, CreateStepRequest)` | 3 UUID + DTO | `StepResponse` | validate config |
| `updateStep(assignmentId, ownerId, planId, stepId, UpdateStepRequest)` | 4 UUID + DTO | `StepResponse` | validate config hiệu lực |
| `deleteStep(assignmentId, ownerId, planId, stepId)` | 4 UUID | `void` | soft-delete |
| `internalGradingConfig(assignmentId)` | UUID | `AssignmentGradingConfigDto` | cho executor |
| `internalPlans(assignmentId)` | UUID | `List<InternalPlanDto>` | cho executor |
| `internalExists(assignmentId)` | UUID | `AssignmentExistsResponse` | published? |
| `internalAssignmentOwner(assignmentId)` | UUID | `AssignmentOwnerResponse` | ownerId |

Helper private: `requireOwnedAssignment`, `requirePlan`, `requireStep`, `rootMessage`,
`serializeIfPresent`, `parse`, `toStepResponse`, `toPlanResponse`.

---

## 3. Chuỗi kiểm tra quyền (áp dụng cho mọi hàm giảng viên)

```
requireOwnedAssignment(assignmentId, ownerId)      // assignments.owner_id = JWT sub
        │  không thấy → 404 "Assignment not found: {id}"
        ▼
requirePlan(planId, assignmentId)                  // test_plans.assignment_id khớp
        │  không thấy → 404 "Plan not found: {id}"
        ▼
requireStep(stepId, planId)                        // test_steps.plan_id khớp
           không thấy → 404 "Step not found: {id}"
```

Nhờ vậy một `planId` của bài khác (dù tồn tại) vẫn trả 404 — không phân biệt được với "không tồn tại".

---

## 4. Chi tiết từng hàm

### 4.1 `createQuestion(UUID assignmentId, UUID ownerId, CreateQuestionRequest request)`

Input (`CreateQuestionRequest`):

| Trường | Kiểu | Bắt buộc | Ghi chú |
|---|---|---|---|
| `plan` | `CreatePlanRequest` | ✔ `@NotNull @Valid` | |
| `steps` | `List<CreateStepRequest>` | ✔ `@NotEmpty @Valid` | ít nhất 1 bước |

Xử lý:

1. `createPlan(...)` → tạo plan (đã kiểm tra quyền + `sequence_order`).
2. Với từng bước: `createStep(assignmentId, ownerId, createdPlanId, step)` (mỗi bước validate config).
3. `listPlans(...)` rồi lọc đúng plan vừa tạo để trả **kèm steps đã lưu** (không tự ghép tay).

Toàn bộ nằm trong một `@Transactional`: bước nào sai → rollback cả plan (không để lại plan rỗng).

Output: `PlanResponse` với `steps[]` đầy đủ, thứ tự theo `step_order`.

### 4.2 `createPlan(UUID assignmentId, UUID ownerId, CreatePlanRequest request)`

| Trường `CreatePlanRequest` | Kiểu | Bắt buộc | Mặc định | Ghi chú |
|---|---|---|---|---|
| `name` | String | ✔ | — | được `trim()` trước khi lưu |
| `description` | String | ✖ | null | |
| `sequenceOrder` | Integer | ✔ `@NotNull @Min(0)` | — | duy nhất trong bài |
| `weight` | Integer `@Min(1)` | ✖ | `1` | |

Xử lý: kiểm tra quyền → nếu `existsByAssignmentIdAndSequenceOrder` → 400
`A plan with sequence_order {n} already exists in this assignment` → lưu → trả `PlanResponse(steps = [])`.

### 4.3 `listPlans(UUID assignmentId, UUID ownerId)`

1. Kiểm tra quyền.
2. `findAllByAssignmentIdOrderBySequenceOrderAsc`.
3. Rỗng → `List.of()`.
4. Một query `findAllByPlanIdInOrderByStepOrderAsc` cho **tất cả** plan, rồi gom theo `planId`
   (tránh N+1).
5. Map sang `PlanResponse` + `steps[]`.

### 4.4 `updatePlan(UUID assignmentId, UUID ownerId, UUID planId, UpdatePlanRequest request)`

Partial update — trường null = giữ nguyên:

| Trường | Kiểu | Bắt buộc | Nếu null | Nếu có giá trị |
|---|---|---|---|---|
| `name` | String | ✔ `@NotBlank` | — (400 từ validation) | `trim()` rồi đổi tên |
| `description` | String | ✖ | giữ nguyên | thay |
| `sequenceOrder` | Integer `@Min(0)` | ✖ | giữ nguyên | đổi, nhưng phải không trùng plan khác |
| `weight` | Integer `@Min(1)` | ✖ | giữ nguyên | thay |

Kiểm tra trùng `sequence_order` chỉ chạy khi giá trị **khác** giá trị hiện tại. Output: `PlanResponse`
kèm steps hiện có của plan.

### 4.5 `deletePlan(UUID assignmentId, UUID ownerId, UUID planId)`

1. Kiểm tra quyền bài + plan.
2. Lấy steps của plan, set `deletedAt = now` cho từng bước, `saveAll`.
3. Set `deletedAt` cho plan, `save`.

Xoá mềm: dữ liệu vẫn còn trong DB, `@SQLRestriction("deleted_at IS NULL")` làm nó biến mất khỏi mọi
truy vấn. **Kết quả chấm đã lưu ở result-service không bị ảnh hưởng.**

### 4.6 `createStep(UUID assignmentId, UUID ownerId, UUID planId, CreateStepRequest request)`

| Trường `CreateStepRequest` | Kiểu | Bắt buộc | Mặc định | Ghi chú |
|---|---|---|---|---|
| `stepOrder` | Integer | ✔ `@NotNull @Min(0)` | — | duy nhất trong plan |
| `name` | String | ✔ `@NotBlank` | — | `trim()` |
| `description` | String | ✖ | null | |
| `stepType` | `StepType` | ✔ `@NotNull` | — | xem §5 |
| `config` | JsonNode | ✔ `@NotNull` | — | validate theo `stepType` |
| `expectedResult` | JsonNode | ✖ | null | serialize nguyên văn |
| `weight` | Integer `@Min(1)` | ✖ | `1` | |
| `timeoutMs` | Integer `@Min(1)` | ✖ | null → executor dùng mặc định | |
| `required` | Boolean | ✖ | `true` | |

Xử lý:

1. `requireOwnedAssignment` → `requirePlan`.
2. `StepConfigValidator.validateAndSerialize(stepType, config)`:
   - `IllegalArgumentException` → bọc thành `BadRequestException` (400) giữ nguyên message.
3. `serializeIfPresent(expectedResult)` → chuỗi JSON hoặc null.
4. Trùng `step_order` → 400 `step_order {n} already exists in plan '{planName}'`.
5. Lưu entity → `toStepResponse`.

### 4.7 `updateStep(UUID assignmentId, UUID ownerId, UUID planId, UUID stepId, UpdateStepRequest request)`

Điểm khó: **config luôn được validate lại**, kể cả khi request không gửi `config`.

```
typeChanged = request.stepType != null && request.stepType != step.stepType
if typeChanged && request.config == null  → 400
    "config is required when changing stepType to {type}"

effectiveType   = typeChanged ? request.stepType : step.stepType
effectiveConfig = request.config != null ? request.config : parse(step.config)
configJson      = StepConfigValidator.validateAndSerialize(effectiveType, effectiveConfig)
```

Sau đó:

| Trường | Bắt buộc | Nếu null | Nếu có |
|---|---|---|---|
| `stepOrder` `@Min(0)` | ✖ | giữ nguyên | đổi nếu khác, phải không trùng (`... free the slot first (update the other step's order, then retry)`) |
| `name` | ✔ `@NotBlank` | — (400 từ validation) | `trim()` rồi đổi |
| `description` | ✖ | giữ nguyên | thay |
| `stepType` | giữ nguyên | đổi (kèm điều kiện config ở trên) |
| `config` | dùng lại config cũ đã parse | validate + lưu |
| `expectedResult` | giữ nguyên | serialize + lưu |
| `weight` `@Min(1)`, `timeoutMs` `@Min(1)`, `required` | giữ nguyên | thay |

Lỗi parse config cũ: `Invalid step config: {rootCauseMessage}` (400).

### 4.8 `deleteStep(...)`

Kiểm tra quyền 3 tầng → set `deletedAt` → save. Không đụng tới plan.

### 4.9 Các hàm nội bộ (executor gọi thẳng, không qua gateway)

#### `internalGradingConfig(UUID assignmentId)`

Map `Assignment` → `AssignmentGradingConfigDto`:

| Entity `Assignment` | DTO | Ghi chú |
|---|---|---|
| `id` | `id` | |
| `classId` | `classId` | null với bài `PRACTICE` |
| `gradingStrategy` | `gradingStrategy` | `.name()` → String |
| `dockerComposeTemplate` | `dockerComposeTemplate` | |
| `dockerComposePort` | `dockerComposePort` | |
| `startupTimeoutMs` | `startupTimeoutMs` | |
| `executionTimeoutMs` | `executionTimeoutMs` | |
| `maxMemoryMb` | `maxMemoryMb` | |
| `maxCpu` | `maxCpu` | |

Không kiểm tra owner (đây là contract nội bộ); assignment không tồn tại → 404.

#### `internalPlans(UUID assignmentId)`

Giống `listPlans` nhưng trả DTO nội bộ, `config`/`expectedResult` là **chuỗi JSON gốc** (executor tự parse):

| `TestPlan` | `InternalPlanDto` | | `TestStep` | `InternalStepDto` |
|---|---|---|---|---|
| `id` | `id` | | `id` | `id` |
| `name` | `name` | | `stepOrder` | `stepOrder` |
| `sequenceOrder` | `sequenceOrder` | | `name` | `name` |
| `weight` | `weight` | | `stepType.name()` | `stepType` |
| — | `steps[]` | | `config` (String) | `config` |
| | | | `expectedResult` (String) | `expectedResult` |
| | | | `weight` | `weight` |
| | | | `timeoutMs` | `timeoutMs` |
| | | | `required` | `required` |

#### `internalExists(UUID assignmentId)` / `internalAssignmentOwner(UUID assignmentId)`

- `exists` = `existsByIdAndPublished(id, true)` → `{ "exists": true|false }`.
- `owner` = `{ "ownerId": "<uuid>" }`; không tồn tại → 404.

---

## 5. Luật validate `config` theo `stepType` (StepConfigValidator)

Chỉ **4 loại bước chạy được**: `HTTP_REQUEST`, `DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`.
`EXTRACT` và `DELAY` bị từ chối khi đứng riêng:

| Loại | Message 400 |
|---|---|
| `EXTRACT` | `standalone EXTRACT steps are not runnable; use the HTTP step's extract[] instead` |
| `DELAY` | `standalone DELAY steps are not supported` |

Chung: `config` phải là **JSON object**, nếu không → `config must be a JSON object`. Key lạ được bỏ qua
(forward-compatible). Sau khi validate, config được serialize lại thành chuỗi chuẩn.

### 5.1 `HTTP_REQUEST`

| Key | Kiểu | Bắt buộc | Luật |
|---|---|---|---|
| `method` | string | ✔ | một trong `GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS` (không phân biệt hoa/thường) |
| `path` | string | ✔ | phải bắt đầu bằng `/` |
| `headers` | object | ✖ | object của string |
| `query_params` | object | ✖ | object |
| `body` | any | ✖ | gửi nguyên văn (JSON) |
| `expected_status` | int | ✖ | 100–599 |
| `assertions` | array | ✖ | xem 5.1.1 |
| `extract` | array | ✖ | mỗi phần tử cần `name`, `from`, `expression`; tuỳ chọn `as` (`scalar`/`json`), `fallback` |
| `data` | array | ✖ | 1–10 phần tử, mỗi phần tử là object (loop safety governor) |
| `auto_inject_headers` | object | ✖ | name → string; áp dụng cho các bước sau trong plan |

#### 5.1.1 Các `kind` của assertion và key bắt buộc

| `kind` | Key bắt buộc thêm |
|---|---|
| `status` | `equals` |
| `json_path` | `path` (kiểm tra tồn tại; `exists: false` để kiểm tra không tồn tại) |
| `contains` | `text` |
| `field_equals` | `path`, `equals` |
| `array_length` | `path`, `equals` |
| `contains_item` | `path`, `equals` |
| `json_path_equals` | `path`, `equals` |
| `greater_than`, `less_than` | `path`, `value` |
| `matches_regex` | `path`, `pattern` |
| `any_of` | `assertions` (array không rỗng; **không** được lồng `status`) |
| `body_structure`, `body_equals` | `json` (hình dạng tuỳ ý) |

### 5.2 `connection` — dùng chung cho 3 loại bước DB

| Key | Bắt buộc | Luật |
|---|---|---|
| `database` | ✔ | khớp `[A-Za-z0-9_$]+` (chặn inject vào URL) |
| `username` | ✔ | không rỗng |
| `password` | ✔ | không rỗng |
| `db_type` | ✖ | `postgres`, `mysql`, `mariadb` |
| `db_port` | ✖ | int 1–65535 (port **trong container**) |
| `db_service` | ✖ (validator) | tên service DB trong compose của bài nộp; executor đọc để tra port sandbox. Thiếu thì bước DB không kết nối được, nên luôn khai báo |

### 5.3 `DB_QUERY`

| Key | Bắt buộc | Ghi chú |
|---|---|---|
| `connection` | ✔ | §5.2 |
| `query` | ✔ | SQL, không rỗng |
| `expected` | ✖ | object; ví dụ `{"row_count": 1, "columns": ["id","title"]}` |

### 5.4 `DB_SCHEMA_CHECK`

| Key | Bắt buộc | Ghi chú |
|---|---|---|
| `connection` | ✔ | §5.2 |
| `checks` | ✔ | array không rỗng |

Mỗi check có `kind` + key riêng:

| `kind` | Key bắt buộc |
|---|---|
| `TABLE_EXISTS` | `table_name` |
| `COLUMN_EXISTS` | `table_name`, `column_name`, `data_type` |
| `INDEX_EXISTS` | `index_name`, `table_name` |
| `PRIMARY_KEY` | `column`, `table_name` |

### 5.5 `DB_MIGRATION`

| Key | Bắt buộc | Ghi chú |
|---|---|---|
| `connection` | ✔ | §5.2 |
| `statements` | ✔ | array không rỗng của string không rỗng |

---

## 6. Map DTO ↔ entity

### 6.1 `CreatePlanRequest` → `TestPlan`

| Request | Entity | Quy tắc |
|---|---|---|
| `name` | `name` | `trim()` |
| `description` | `description` | nguyên văn |
| `sequenceOrder` | `sequenceOrder` | |
| `weight` | `weight` | `null → 1` |
| — | `assignmentId` | từ path |
| — | `id`, `createdAt` | `BaseEntity` sinh tự động |

### 6.2 `CreateStepRequest` → `TestStep`

| Request | Entity | Quy tắc |
|---|---|---|
| `stepOrder` | `stepOrder` | |
| `name` | `name` | `trim()` |
| `description` | `description` | |
| `stepType` | `stepType` | enum |
| `config` (JsonNode) | `config` (String) | `StepConfigValidator.validateAndSerialize` |
| `expectedResult` (JsonNode) | `expectedResult` (String) | `serializeIfPresent` |
| `weight` | `weight` | `null → 1` |
| `timeoutMs` | `timeoutMs` | |
| `required` | `required` | `null → true` |
| — | `planId` | từ path |

### 6.3 `TestPlan` → `PlanResponse`

| Entity | DTO | Ghi chú |
|---|---|---|
| `id` | `id` | |
| `name` | `name` | |
| `description` | `description` | |
| `sequenceOrder` | `sequenceOrder` | |
| `weight` | `weight` | |
| (steps của plan) | `steps[]` | danh sách `StepResponse` đã sắp theo `stepOrder` |

### 6.4 `TestStep` → `StepResponse`

| Entity | DTO | Ghi chú |
|---|---|---|
| `id` | `id` | |
| `stepOrder` | `stepOrder` | |
| `name` | `name` | |
| `description` | `description` | |
| `stepType.name()` | `type` | **tên trường khác** (`type`, không phải `stepType`) |
| `config` (String) | `config` (JsonNode) | `parse()`; JSON hỏng → `null` + log warn (không ném lỗi) |
| `expectedResult` (String) | `expectedResult` (JsonNode) | như trên |
| `weight` | `weight` | |
| `timeoutMs` | `timeoutMs` | |
| `required` | `required` | |

---

## 7. Bảng lỗi

| HTTP | Hàm | Thông điệp |
|---|---|---|
| 404 | mọi hàm giảng viên | `Assignment not found: {id}` |
| 404 | hàm có plan | `Plan not found: {id}` |
| 404 | hàm có step | `Step not found: {id}` |
| 400 | `createPlan` / `updatePlan` | `A plan with sequence_order {n} already exists in this assignment` |
| 400 | `createStep` / `updateStep` | `step_order {n} already exists in plan '{name}'` |
| 400 | `updateStep` | `config is required when changing stepType to {type}` |
| 400 | `updateStep` | `Invalid step config: {rootCause}` |
| 400 | validator | `config must be a JSON object` |
| 400 | validator HTTP | `HTTP_REQUEST: unknown method '{m}'`, `path must start with '/'`, … |
| 400 | validator DB | `DB_QUERY: connection thiếu trường bắt buộc: [database]`, … |
| 400 | validator | `DB_SCHEMA_CHECK.checks: unknown check kind '{k}'` |
| 400 | validator | `DB_MIGRATION: 'statements' must be a non-empty array` |
| 400 | validator | `standalone EXTRACT steps are not runnable; …` / `standalone DELAY steps are not supported` |
| 409 | DB constraint | `Resource already exists or violates a constraint` |

---

## 8. Luồng dữ liệu

```
POST /api/v1/assignments/{assignmentId}/plans/with-steps
  { plan: {...}, steps: [{...}, ...] }
    → TestPlanController.createQuestion
    → requireOwnedAssignment
    → createPlan        (check sequence_order)
    → createStep x N    (validate config theo stepType)
    → listPlans         → 201 PlanResponse{ id, name, sequenceOrder, weight, steps[] }

POST .../plans/{planId}/steps
    → TestPlanController.createStep
    → requireOwnedAssignment → requirePlan
    → StepConfigValidator.validateAndSerialize
    → check step_order trùng
    → 201 StepResponse{ id, stepOrder, type, config, expectedResult, weight, timeoutMs, required }

PUT .../plans/{planId}/steps/{stepId}
    → validate lại config hiệu lực (kể cả khi không gửi config)
    → 200 StepResponse

DELETE .../plans/{planId}
    → soft-delete plan + toàn bộ step của nó → 204

GET /api/v1/internal/assignments/{id}/plans        (executor)
    → TestPlanService.internalPlans
    → InternalPlanDto[] { id, name, sequenceOrder, weight,
                          steps[{ id, stepOrder, name, stepType,
                                  config(String), expectedResult(String),
                                  weight, timeoutMs, required }] }
```
