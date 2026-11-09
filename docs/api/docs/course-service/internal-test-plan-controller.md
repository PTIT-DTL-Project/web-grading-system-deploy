# Tài liệu chi tiết luồng API — course-service / InternalTestPlanController

Nơi lưu: `docs/api/docs/course-service/internal-test-plan-controller.md`

Mục đích: giải thích chi tiết từng hàm/controller/service trong luồng kiểm tra cấu trúc test-plan (validate) của course-service, dùng bởi ai-assistant-service để kiểm tra config shape trước khi tạo pending action, bao gồm input, output, điều kiện tiên quyết, ví dụ request/response, và các mã lỗi có thể xảy ra. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`InternalTestPlanController` là REST controller của service `course-service`, trỏ về base path `/api/v1/internal/test-plans`. Nó cung cấp các endpoint kiểm tra cấu trúc payload test-plan (plan + steps) **không lưu bất cứ thứ gì vào cơ sở dữ liệu**.

Đây là controller quan trọng trong luồng AI agent: ai-assistant-service gọi endpoint này để kiểm tra hình dạng config trước khi tạo pending action, sodass agent nhận được một "repair loop" (vòng sửa lỗi) thay vì nhận lỗi 400 tại thời điểm confirm.

| Endpoint | Method | Mục đích | Gọi bởi |
|----------|--------|----------|---------|
| `/api/v1/internal/test-plans/validate` | POST | Kiểm tra toàn bộ payload câu hỏi (plan + các bước) | ai-assistant-service |
| `/api/v1/internal/test-plans/validate-step` | POST | Kiểm tra config của một bước đơn lẻ | ai-assistant-service |
| `/api/v1/internal/test-plans/capabilities` | GET | Trả về JSON Schema + mô tả năng lực của validator | ai-assistant-service / FE |

**Quan trọng:** Route nằm dưới `/api/v1/internal/**` which is `permitAll` (`SecurityConfig.java:34`), nên có thể reachable từ ai-assistant-service mà không cần token LECTURER. Tuy nhiên, đây chỉ là validate shape config — không kiểm tra sở hữu assignment, không lưu dữ liệu.

Controller giao tiếp trực tiếp với `StepConfigValidator` (utility tĩnh, không cần Spring context) để validate cấu trúc config JSON theo từng loại bước.

---

## 2. DTO liên quan (nội bộ, không envelope)

### 2.1 `ValidateQuestionRequest` (dto/internal)
Yêu cầu validate toàn bộ câu hỏi (một plan kèm các bước).

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `steps` | `List<ValidateStepRequest>` | ✅ | Danh sách các bước cần validate |

### 2.2 `ValidateStepRequest` (dto/internal)
Yêu cầu validate config của một bước đơn lẻ.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `stepType` | `StepType` | ✅ | Loại bước: `HTTP_REQUEST`, `DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION` |
| `config` | `JsonNode` | ✅ | JSON config của bước |

### 2.3 `ValidateQuestionResponse` (dto/internal)
Phản hồi kết quả validate.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `valid` | boolean | `true` nếu toàn bộ payload hợp lệ, `false` nếu có lỗi |
| `errors` | `List<ValidationError>` | Danh sách lỗi validation (rỗng nếu valid) |

Lớp lồng `ValidateQuestionResponse.ValidationError`:
| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `field` | String | Tên trường bị lỗi (ví dụ `steps[0].config`, `config`) |
| `defaultMessage` | String | Thông báo lỗi chi tiết |

### 2.4 `StepType` (entity)
Enum loại bước: `HTTP_REQUEST`, `DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`, `EXTRACT`, `DELAY`. Hai loại cuối (`EXTRACT`, `DELAY`) không thể chạy độc lập và sẽ bị validator từ chối.

---

## 3. Chi tiết từng hàm

### 3.1 `validate` — Kiểm tra toàn bộ payload câu hỏi (plan + steps)

**Vị trí:** `InternalTestPlanController.validate(...)`

**Endpoint:** `POST /api/v1/internal/test-plans/validate`

**Request body:** `ValidateQuestionRequest`

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `steps` | `List<ValidateStepRequest>` | ✅ | Danh sách bước |

**Luồng xử lý:**

1. **Controller:** Nhận `ValidateQuestionRequest request` và `BindingResult bindingResult` (Spring Validation tự động bind).
2. **Bước 1 — Kiểm tra lỗi binding:** Nếu `bindingResult.hasErrors()` → duyệt từng `FieldError`, tạo `ValidationError(field, defaultMessage)` cho mỗi lỗi, trả về `ResponseEntity.ok(ValidateQuestionResponse.builder().valid(false).errors(errors).build())`. **Trả về 200 OK** (không phải 400) với `valid = false`, để caller dễ xử lý nhất quán.
3. **Bước 2 — Validate từng bước config:** Duyệt `request.getSteps()` theo chỉ số `i`:
   - Tạo prefix `steps[i].` (ví dụ `steps[0].config`).
   - Gọi `StepConfigValidator.validateAndSerialize(step.getStepType(), step.getConfig())`.
   - Nếu ném `IllegalArgumentException` → thêm `ValidationError(prefix + ".config", e.getMessage())` vào danh sách lỗi.
   - **Tiếp tục duyệt các bước còn lại** (không dừng ở bước lỗi đầu tiên), để caller nhận được tất cả lỗi cùng lúc.
4. **Bước 3 — Trả về kết quả:** `valid = errors.isEmpty()`, `errors` là danh sách lỗi đã thu thập. Trả về `ResponseEntity.ok(...)`.

**Ví dụ request (hợp lệ):**
```http
POST /api/v1/internal/test-plans/validate
Content-Type: application/json

{
  "steps": [
    {
      "stepType": "HTTP_REQUEST",
      "config": {
        "method": "POST",
        "path": "/api/students",
        "body": {
          "email": "${$FAKER_EMAIL}",
          "fullName": "${$FAKER_NAME}",
          "studentCode": "SV${$TIMESTAMP}"
        },
        "expected_status": 201,
        "assertions": [
          { "kind": "status", "equals": 201 },
          { "kind": "json_path", "path": "$.id" }
        ],
        "extract": [
          { "name": "studentId", "from": "response_body", "expression": "$.id" }
        ]
      }
    }
  ]
}
```

**Ví dụ response (200, hợp lệ):**
```json
{
  "valid": true,
  "errors": []
}
```

**Ví dụ response (200, có lỗi):**
```json
{
  "valid": false,
  "errors": [
    {
      "field": "steps[0].config",
      "defaultMessage": "HTTP_REQUEST: path must start with '/'"
    },
    {
      "field": "steps[1].config",
      "defaultMessage": "DB_QUERY: connection is required"
    }
  ]
}
```

**Mã lỗi:** Không có mã lỗi HTTP (luôn trả về 200). Lỗi được truyền qua trường `valid` và `errors` trong body.

---

### 3.2 `validate-step` — Kiểm tra config của một bước đơn lẻ

**Vị trí:** `InternalTestPlanController.validateStep(...)`

**Endpoint:** `POST /api/v1/internal/test-plans/validate-step`

**Request body:** `ValidateStepRequest`

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `stepType` | `StepType` | ✅ | Loại bước |
| `config` | `JsonNode` | ✅ | JSON config |

**Luồng xử lý:**

1. **Controller:** Nhận `ValidateStepRequest request` và `BindingResult bindingResult`.
2. **Bước 1 — Kiểm tra lỗi binding:** Tương tự `validate` — nếu có lỗi binding → trả về `valid = false` kèm danh sách `ValidationError`.
3. **Bước 2 — Validate config:** Gọi `StepConfigValidator.validateAndSerialize(request.getStepType(), request.getConfig())`.
   - Nếu thành công (không ném exception) → bước hợp lệ.
   - Nếu ném `IllegalArgumentException` → thêm `ValidationError("config", e.getMessage())`.
4. **Bước 3 — Trả về kết quả:** `valid = errors.isEmpty()`. Trả về `ResponseEntity.ok(...)`.

**Ví dụ request:**
```http
POST /api/v1/internal/test-plans/validate-step
Content-Type: application/json

{
  "stepType": "DB_QUERY",
  "config": {
    "query": "SELECT id FROM students WHERE id = '${studentId}'",
    "expected": { "row_count": 1 },
    "connection": {
      "db_type": "postgres",
      "db_service": "db",
      "db_port": 5432,
      "database": "wgs",
      "username": "postgres",
      "password": "postgres"
    }
  }
}
```

**Ví dụ response (200, hợp lệ):**
```json
{
  "valid": true,
  "errors": []
}
```

**Ví dụ response (200, sai):**
```json
{
  "valid": false,
  "errors": [
    {
      "field": "config",
      "defaultMessage": "DB_QUERY: connection.database must be a bare identifier [A-Za-z0-9_$]+"
    }
  ]
}
```

**Mã lỗi:** Không có mã lỗi HTTP (luôn trả về 200).

---

### 3.3 `capabilities` — Trả về JSON Schema + mô tả năng lực

**Vị trí:** `InternalTestPlanController.capabilities()`

**Endpoint:** `GET /api/v1/internal/test-plans/capabilities`

**Luồng xử lý:**

1. **Controller:** Gọi `StepConfigValidator.capabilities()`.
2. **Trả về:** `ResponseEntity.ok(JsonNode)` — một JSON node chứa:
   - `stepTypes`: danh sách các loại bước có thể chạy (`HTTP_REQUEST`, `DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`).
   - `dbConnection`: object với `required = true` và `requiredFields` (`database`, `username`, `password`).
   - `httpMethods`: danh sách các phương thức HTTP cho phép.
   - `assertionKinds`: danh sách các loại assertion (`status`, `body_structure`, `body_equals`, `json_path`, `contains`, `field_equals`, `array_length`, `contains_item`, `json_path_equals`, `greater_than`, `less_than`, `matches_regex`, `any_of`).
   - `schemaCheckKinds`: danh sách các loại kiểm tra schema (`TABLE_EXISTS`, `COLUMN_EXISTS`, `INDEX_EXISTS`, `PRIMARY_KEY`).
   - `limits`: object với `dataMaxItems = 10`.
   - `schemas`: object chứa JSON Schema draft-07 cho từng loại bước (`HTTP_REQUEST`, `DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`).

**Ví dụ request:**
```http
GET /api/v1/internal/test-plans/capabilities
```

**Ví dụ response (200) — đoạn trích:**
```json
{
  "stepTypes": ["DB_MIGRATION", "DB_QUERY", "DB_SCHEMA_CHECK", "HTTP_REQUEST"],
  "dbConnection": { "required": true, "requiredFields": ["database", "username", "password"] },
  "httpMethods": ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"],
  "assertionKinds": ["any_of", "array_length", "contains", "contains_item", "field_equals", "greater_than", "json_path", "json_path_equals", "less_than", "matches_regex", "status", "body_equals", "body_structure"],
  "schemaCheckKinds": ["COLUMN_EXISTS", "INDEX_EXISTS", "PRIMARY_KEY", "TABLE_EXISTS"],
  "limits": { "dataMaxItems": 10 },
  "schemas": {
    "HTTP_REQUEST": { "$schema": "http://json-schema.org/draft-07/schema#", ... },
    "DB_QUERY": { ... },
    ...
  }
}
```

**Mã lỗi:** Không có (luôn trả về 200).

---

## 4. StepConfigValidator (cơ chế validation phía sau)

`StepConfigValidator` là utility class tĩnh (không cần Spring context), dùng bởi cả `InternalTestPlanController` và `TestPlanService`. Nó cung cấp:

- `validateAndSerialize(StepType type, JsonNode config)`: validate cấu trúc config JSON theo loại bước, rồi serialize thành chuỗi. Ném `IllegalArgumentException` nếu không hợp lệ.
  - **HTTP_REQUEST:** bắt buộc `method` (trong tập cho phép), `path` (bắt đầu bằng `/`); `expected_status` phải là integer 100–599; assertions phải có `kind` hợp lệ và các trường bắt buộc theo kind; `extract[]` phải có `name`, `from`, `expression`; `data[]` tối đa 10 entry (loop safety governor); `auto_inject_headers` phải là object của chuỗi.
  - **DB_QUERY:** bắt buộc `connection` (database, username, password), `query`; `db_type` phải là postgres/mysql/mariadb; `database` phải là bare identifier `[A-Za-z0-9_$]+`.
  - **DB_SCHEMA_CHECK:** bắt buộc `connection`, `checks[]` không rỗng; mỗi check phải có `kind` (TABLE_EXISTS/COLUMN_EXISTS/INDEX_EXISTS/PRIMARY_KEY) và các trường bắt buộc theo kind.
  - **DB_MIGRATION:** bắt buộc `connection`, `statements[]` không rỗng, mỗi entry là chuỗi không rỗng.
  - **EXTRACT/DELAY:** ném lỗi (không thể chạy độc lập).
- `generateSchema(StepType type)`: trả về JSON Schema draft-07 cho loại bước.
- `capabilities()`: trả về mô tả năng lực (step types, db connection required fields, http methods, assertion kinds, schema check kinds, limits, schemas).

---

## 5. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 200 (valid=false) | Lỗi binding `@Valid` (trường thiếu, kiểu sai) | `BindingResult` |
| 200 (valid=false) | Config bước không hợp lệ (thiếu trường, kiểu sai, values ngoài phạm vi) | `StepConfigValidator.validateAndSerialize` |
| 200 (valid=true) | Toàn bộ payload hợp lệ | — |

Lưu ý: Controller **không bao giờ trả về 400** cho lỗi validation config — tất cả đều được gói vào body `valid = false` kèm `errors`. Điều này giúp ai-assistant-service dễ dàng_parse và hiển thị lỗi cho lecturer để sửa.

---

## 6. Luồng dữ liệu từ đầu đến cuối (ví dụ ai-assistant-service validate trước khi tạo pending action)

```
AI agent (ai-assistant-service)
   │ 1. Sinh ra plan config JSON từ intent của giảng viên (bằng LLM)
   │ 2. Gọi POST /api/v1/internal/test-plans/validate
   │    body: { steps: [ {stepType, config}, ... ] }
   ▼
course-service: InternalTestPlanController.validate()
   │ 3. Kiểm tra BindingResult (nếu có)
   │ 4. Duyệt từng bước, gọi StepConfigValidator.validateAndSerialize(stepType, config)
   │ 5. Thu thập tất cả lỗi (không dừng ở bước đầu)
   │ 6. Trả về 200 OK { valid, errors }
   ▼
AI agent
   │ 7. Nếu valid = false: hiển thị errors cho giảng viên, cho sửa và gửi lại
   │ 8. Nếu valid = true: tạo pending action, chờ giảng viên confirm → lưu thật
```

```
AI agent (ai-assistant-service) — validate một bước đơn lẻ
   │ POST /api/v1/internal/test-plans/validate-step
   │    body: { stepType, config }
   ▼
course-service: InternalTestPlanController.validateStep()
   │ 1. Kiểm tra BindingResult
   │ 2. Gọi StepConfigValidator.validateAndSerialize(stepType, config)
   │ 3. Trả về 200 OK { valid, errors }
   ▼
AI agent nhận kết quả validate từng bước
```

---

*Tài liệu này là phần tiếp theo của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/course-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
