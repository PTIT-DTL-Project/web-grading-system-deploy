# Tài liệu chi tiết luồng API — course-service / InternalAssignmentController

Nơi lưu: `docs/api/docs/course-service/internal-assignment-controller.md`

Mục đích: giải thích chi tiết từng hàm/controller/service trong luồng hợp đồng nội bộ (internal contracts) của course-service dành cho executor-service và submission-service, bao gồm input, output, điều kiện tiên quyết, ví dụ request/response, và các mã lỗi có thể xảy ra. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`InternalAssignmentController` là REST controller của service `course-service`, trỏ về base path `/api/v1/internal/assignments`. Nó cung cấp các hợp đồng nội bộ (raw DTOs, không có envelope) cho `executor-service` và `submission-service`. **Không bao giờ được exposing qua API gateway** — chỉ các service nội bộ gọi được.

| Endpoint | Method | Mục đích | Gọi bởi |
|----------|--------|----------|---------|
| `/api/v1/internal/assignments/{id}` | GET | Lấy grading config của assignment (chiến lược, cổng, timeout, resources) | executor-service |
| `/api/v1/internal/assignments/{id}/plans` | GET | Lấy danh sách plan + step của assignment (dùng để chấm) | executor-service |
| `/api/v1/internal/assignments/{id}/exists` | GET | Kiểm tra assignment có tồn tại và đã publish hay không | submission-service |
| `/api/v1/internal/assignments/{id}/dry-run` | POST | Chạy dry-run grading config đối với mã tham chiếu, không ghi kết quả | lecturer (qua course-service) |
| `/api/v1/internal/assignments/{id}/config-schema` | GET | Trả về JSON Schema (draft-07) cho config của một bước | FE step editor |

Controller giao tiếp với `TestPlanService` (đối với grading config, plans, exists) và `ExecutorInternalClient` (Feign client gọi executor-service cho dry-run). Có một số endpoint không cần kiểm tra sở hữu giảng viên vì là hợp đồng nội bộ giữa service.

---

## 2. DTO liên quan (nội bộ, không envelope)

### 2.1 `AssignmentGradingConfigDto` (dto/internal)
Tham số grading của một assignment, gửi sang executor-service để biết cách khởi chạy container và chấm điểm.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID assignment |
| `classId` | UUID | ID lớp (null nếu PRACTICE) |
| `gradingStrategy` | String | Chiến lược chấm điểm (ví dụ `STUDENT_DOCKER_COMPOSE`) |
| `dockerComposeTemplate` | String | Template docker-compose (bắt buộc nếu LECTURER_DOCKER_COMPOSE) |
| `dockerComposePort` | Integer | Cổng container |
| `startupTimeoutMs` | Integer | Timeout khởi động (ms) |
| `executionTimeoutMs` | Integer | Timeout thực thi (ms) |
| `maxMemoryMb` | Integer | Giới hạn RAM (MB) |
| `maxCpu` | Double | Giới hạn CPU |

### 2.2 `InternalPlanDto` (dto/internal)
Một plan trong ngữ cảnh nội bộ (kèm danh sách bước).

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID plan |
| `name` | String | Tên plan |
| `sequenceOrder` | Integer | Thứ tự 계획 |
| `weight` | Integer | Trọng số |
| `steps` | `List<InternalStepDto>` | Danh sách bước trong plan |

### 2.3 `InternalStepDto` (dto/internal)
Một bước trong plan nội bộ.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID bước |
| `stepOrder` | Integer | Thứ tự bước |
| `name` | String | Tên bước |
| `stepType` | String | Loại bước (`HTTP_REQUEST`, `DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`) |
| `config` | String | JSON config của bước (chuỗi đã serialize) |
| `expectedResult` | String | JSON kết quả kỳ vọng (chuỗi đã serialize, có thể null) |
| `weight` | Integer | Trọng số bước |
| `timeoutMs` | Integer | Timeout bước (ms) |
| `required` | Boolean | Bắt buộc hay không |

### 2.4 `AssignmentExistsResponse` (dto/internal)
| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `exists` | boolean | Assignment có tồn tại và đã publish hay không |

### 2.5 `DryRunRequest` (dto/internal)
Yêu cầu dry-run gửi sang executor-service.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `assignmentId` | UUID | ✅ ID assignment (được overwrite từ path variable) |
| `referenceCodeZipUrl` | String | URL zip mã tham chiếu trên RustFS |
| `plans` | `List<InternalPlanDto>` | Danh sách plan cần chạy dry-run |

### 2.6 `DryRunReport` (dto/internal)
Báo cáo kết quả dry-run.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `dryRunId` | UUID | ID dry-run |
| `steps` | `List<DryRunStepReport>` | Chi tiết từng bước |
| `summary` | String | Tóm tắt kết quả |

### 2.7 `StepType` (entity)
Enum loại bước: `HTTP_REQUEST`, `DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`, `EXTRACT`, `DELAY`. Hai loại cuối (`EXTRACT`, `DELAY`) không thể chạy độc lập.

---

## 3. Chi tiết từng hàm

### 3.1 `gradingConfig` — Lấy grading config của assignment

**Vị trí:** `InternalAssignmentController.gradingConfig(...)` → `TestPlanService.internalGradingConfig(...)`

**Endpoint:** `GET /api/v1/internal/assignments/{id}`

**Path variable:**
- `id` (UUID): ID assignment

**Luồng xử lý:**
1. Controller nhận `id`, gọi `testPlanService.internalGradingConfig(id)`. Trả về `ResponseEntity.ok(AssignmentGradingConfigDto)`.
2. Service `internalGradingConfig`:
   - Truy vấn `assignmentRepository.findById(assignmentId)`. Nếu không tìm thấy → ném `ResourceNotFoundException("Assignment not found: " + assignmentId)`.
   - **Lưu ý:** Endpoint này **không kiểm tra ownerId** — đây là hợp đồng nội bộ, executor-service gọi trực tiếp bằng assignment id.
   - Xây dựng `AssignmentGradingConfigDto` từ entity `Assignment`: id, classId, gradingStrategy (tên enum), dockerComposeTemplate, dockerComposePort, startupTimeoutMs, executionTimeoutMs, maxMemoryMb, maxCpu.
   - Trả về DTO.

**Ví dụ request:**
```http
GET /api/v1/internal/assignments/16cebadb-2485-4494-be5b-7f6641887559
```

**Ví dụ response (200):**
```json
{
  "id": "16cebadb-2485-4494-be5b-7f6641887559",
  "classId": "03310ff7-b94f-423a-abf2-6332331c9471",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposeTemplate": null,
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```

**Mã lỗi:**
- `404 ResourceNotFoundException`: assignment không tồn tại.

---

### 3.2 `plans` — Lấy danh sách plan + step của assignment

**Vị trí:** `InternalAssignmentController.plans(...)` → `TestPlanService.internalPlans(...)`

**Endpoint:** `GET /api/v1/internal/assignments/{id}/plans`

**Path variable:**
- `id` (UUID): ID assignment

**Luồng xử lý:**
1. Controller gọi `testPlanService.internalPlans(id)`. Trả về `ResponseEntity.ok(List<InternalPlanDto>)`.
2. Service `internalPlans`:
   - Kiểm tra `assignmentRepository.findById(assignmentId)`. Nếu không tìm thấy → `ResourceNotFoundException("Assignment not found: " + assignmentId)`.
   - Truy vấn `testPlanRepository.findAllByAssignmentIdOrderBySequenceOrderAsc(assignmentId)` → danh sách plan.
   - Nếu rỗng → trả về danh sách rỗng.
   - Truy vấn `testStepRepository.findAllByPlanIdInOrderByStepOrderAsc(...)` với tất cả plan id → tất cả bước.
   - Dành các bước vào từng plan theo `planId`, map sang `InternalStepDto` (id, stepOrder, name, stepType tên enum, config, expectedResult, weight, timeoutMs, required).
   - Map sang `InternalPlanDto` (id, name, sequenceOrder, weight, steps).
   - Trả về danh sách.

**Ví dụ request:**
```http
GET /api/v1/internal/assignments/16cebadb-2485-4494-be5b-7f6641887559/plans
```

**Ví dụ response (200):**
```json
[
  {
    "id": "7e31465c-2764-4848-abf3-854832c64361",
    "name": "Câu 1: Tạo sinh viên mới",
    "sequenceOrder": 1,
    "weight": 100,
    "steps": [
      {
        "id": "15ba2249-9919-450f-82cf-3c534cf219aa",
        "stepOrder": 1,
        "name": "POST tạo sinh viên mới",
        "stepType": "HTTP_REQUEST",
        "config": "{\"method\":\"POST\",\"path\":\"/api/students\",...}",
        "expectedResult": null,
        "weight": 30,
        "timeoutMs": 5000,
        "required": true
      }
    ]
  }
]
```

**Mã lỗi:**
- `404 ResourceNotFoundException`: assignment không tồn tại.

---

### 3.3 `exists` — Kiểm tra assignment tồn tại và đã publish

**Vị trí:** `InternalAssignmentController.exists(...)` → `TestPlanService.internalExists(...)`

**Endpoint:** `GET /api/v1/internal/assignments/{id}/exists`

**Path variable:**
- `id` (UUID): ID assignment

**Luồng xử lý:**
1. Controller gọi `testPlanService.internalExists(id)`. Trả về `ResponseEntity.ok(AssignmentExistsResponse)`.
2. Service `internalExists`:
   - Gọi `assignmentRepository.existsByIdAndPublished(assignmentId, true)`.
   - Trả về `new AssignmentExistsResponse(exists)`.
3. **Lưu ý:** Chỉ trả về `true` khi assignment tồn tại **và** `published = true`. Dùng cho submission-service để kiểm tra xem một assignment có thể nhận bài nộp hay không.

**Ví dụ request:**
```http
GET /api/v1/internal/assignments/16cebadb-2485-4494-be5b-7f6641887559/exists
```

**Ví dụ response (200):**
```json
{
  "exists": true
}
```

**Mã lỗi:** Không có (luôn trả về 200 với `exists` true/false).

---

### 3.4 `dryRun` — Chạy dry-run grading config

**Vị trí:** `InternalAssignmentController.dryRun(...)` → `ExecutorInternalClient.dryRun(...)`

**Endpoint:** `POST /api/v1/internal/assignments/{id}/dry-run`

**Path variable:**
- `id` (UUID): ID assignment

**Request body:** `DryRunRequest`
| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `assignmentId` | UUID | ✅ (được overwrite từ path variable) |
| `referenceCodeZipUrl` | String | ✅ URL zip mã tham chiếu |
| `plans` | `List<InternalPlanDto>` | ✅ Danh sách plan cần chạy |

**Luồng xử lý:**
1. Controller nhận `id` và `DryRunRequest request`.
2. Chuẩn hóa request: xây dựng `DryRunRequest` mới bằng builder, gán `assignmentId = id` (ghi đè giá trị từ body để đảm bảo nhất quán), giữ `referenceCodeZipUrl` và `plans` từ request gốc.
3. Gọi `executorInternalClient.dryRun(normalized)` — Feign client gọi `POST /api/v1/internal/grading/dry-run` trên executor-service.
4. Trả về `ResponseEntity<DryRunReport>` từ executor-service.
5. **Ghi chú (Phase 6):** Dry-run chạy grading config đối với mã tham chiếu mà **không** đăng kết quả lên result-service và **không** cập nhật submission status. An toàn để lecturer chạy thử vô số lần.

**Ví dụ request:**
```http
POST /api/v1/internal/assignments/16cebadb-2485-4494-be5b-7f6641887559/dry-run
Content-Type: application/json

{
  "assignmentId": "16cebadb-2485-4494-be5b-7f6641887559",
  "referenceCodeZipUrl": "https://rustfs.example.com/submissions/student-management-solution.zip",
  "plans": [
    {
      "id": "7e31465c-2764-4848-abf3-854832c64361",
      "name": "Câu 1: Tạo sinh viên mới",
      "sequenceOrder": 1,
      "weight": 100,
      "steps": [...]
    }
  ]
}
```

**Ví dụ response (200):**
```json
{
  "dryRunId": "d5b186e6-87d8-4e16-a67e-84686937bdc0",
  "steps": [
    {
      "stepOrder": 1,
      "name": "POST tạo sinh viên mới",
      "status": "PASSED",
      "actualStatus": 201,
      "expectedStatus": 201,
      "detail": null
    }
  ],
  "summary": "7/7 bước PASSED, 10.00/10"
}
```

**Mã lỗi:**
- `502`: executor-service không khả dụng (lỗi Feign).
- `400`: request body không hợp lệ.

---

### 3.5 `configSchema` — Trả về JSON Schema cho config bước

**Vị trí:** `InternalAssignmentController.configSchema(...)` → `StepConfigValidator.generateSchema(...)`

**Endpoint:** `GET /api/v1/internal/assignments/{id}/config-schema`

**Path variable:**
- `id` (UUID): ID assignment (không dùng trong logic, chỉ định danh endpoint)

**Query params:**
| Param | Kiểu | Bắt buộc | Mặc định | Mô tả |
|-------|------|----------|----------|-------|
| `type` | String | — | `HTTP_REQUEST` | Loại bước: `HTTP_REQUEST`, `DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`. Giá trị không hợp lệ sẽ fallback về `HTTP_REQUEST` |

**Luồng xử lý:**
1. Controller nhận `id` và `type`.
2. Xác định `StepType stepType`: mặc định `HTTP_REQUEST`. Nếu `type` không null và không blank → gọi `StepType.valueOf(type.trim())`. Nếu ném exception (giá trị không hợp lệ) → bắt và fallback về `HTTP_REQUEST`.
3. Gọi `StepConfigValidator.generateSchema(stepType)`:
   - `HTTP_REQUEST` → `generateHttpSchema()` (schema chi tiết cho method, path, headers, body, assertions, extract, data, auto_inject_headers)
   - `DB_QUERY` → `generateDbQuerySchema()` (query, connection, expected)
   - `DB_SCHEMA_CHECK` → `generateSchemaCheckSchema()` (checks, connection)
   - `DB_MIGRATION` → `generateMigrationSchema()` (statements, connection)
   - `EXTRACT`, `DELAY` → ném `IllegalArgumentException` (không thể chạy độc lập)
4. Trả về `ResponseEntity.ok(JsonNode)` — JSON Schema draft-07.
5. **Ghi chú (Phase 7):** FE dùng schema này để validate step editor theo thời gian thực trước khi lưu lên backend. Assignment existence được kiểm tra ngầm bởi caller; endpoint này chỉ về schema và không phụ thuộc trạng thái assignment.

**Ví dụ request (schema cho HTTP_REQUEST):**
```http
GET /api/v1/internal/assignments/16cebadb-2485-4494-be5b-7f6641887559/config-schema?type=HTTP_REQUEST
```

**Ví dụ response (200) — đoạn trích:**
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "HTTP_REQUEST step config",
  "type": "object",
  "required": ["method", "path"],
  "properties": {
    "method": { "type": "string", "enum": ["DELETE","GET","HEAD","OPTIONS","PATCH","POST","PUT"] },
    "path": { "type": "string", "pattern": "^/" },
    "expected_status": { "type": "integer", "minimum": 100, "maximum": 599 },
    "headers": { "type": "object" },
    "query_params": { "type": "object" },
    "body": { "description": "Request body (JSON), optional" },
    "assertions": { "type": "array", ... },
    "extract": { "type": "array", ... },
    "data": { "type": "array", ... },
    "auto_inject_headers": { "type": "object" }
  }
}
```

**Ví dụ request (schema cho DB_QUERY):**
```http
GET /api/v1/internal/assignments/16cebadb-2485-4494-be5b-7f6641887559/config-schema?type=DB_QUERY
```

**Mã lỗi:**
- `400`: nếu `StepType.valueOf` ném exception... (trong thực tế được bắt và fallback, nên hiếm khi lỗi). Nếu `generateSchema` nhận `EXTRACT`/`DELAY` (không thể xảy ra qua `type` param vì `StepType.valueOf` sẽ thành công nhưng `generateSchema` ném lỗi) → có thể trả về lỗi. Tuy nhiên controller không bắt lỗi này, nên sẽ trở thành 500.

---

## 4. Các lớp liên quan trong TestPlanService (phần nội bộ)

### 4.1 `internalGradingConfig(UUID assignmentId)`
- **Input:** assignmentId.
- **Output:** `AssignmentGradingConfigDto`.
- **Làm gì:** Truy vấn assignment theo id (không qua owner). Xây dựng DTO chứa grading strategy, cổng, timeout, resources. Nếu assignment không tìm thấy → `ResourceNotFoundException`.

### 4.2 `internalPlans(UUID assignmentId)`
- **Input:** assignmentId.
- **Output:** `List<InternalPlanDto>`.
- **Làm gì:** Kiểm tra assignment tồn tại. Lấy tất cả plan theo sequenceOrder, lấy tất cả bước theo stepOrder, gộp bước vào plan, trả về danh sách DTO.

### 4.3 `internalExists(UUID assignmentId)`
- **Input:** assignmentId.
- **Output:** `AssignmentExistsResponse`.
- **Làm gì:** Gọi `assignmentRepository.existsByIdAndPublished(assignmentId, true)`. Trả về exists = true chỉ khi assignment tồn tại và đã publish.

---

## 5. StepConfigValidator (tạo schema + validate config)

`StepConfigValidator` là utility class tĩnh (không cần Spring context) dùng để:
- `validateAndSerialize(StepType type, JsonNode config)`: validate cấu trúc config JSON theo loại bước, rồi serialize thành chuỗi. Ném `IllegalArgumentException` nếu không hợp lệ.
  - HTTP_REQUEST: bắt buộc `method`, `path` (bắt đầu bằng `/`); method trong tập cho phép; `expected_status` 100–599; assertions phải có `kind` hợp lệ và các trường bắt buộc theo kind; `extract[]` phải có `name`, `from`, `expression`; `data[]` tối đa 10 entry; `auto_inject_headers` phải là object của chuỗi.
  - DB_QUERY: bắt buộc `connection` (database, username, password), `query`; `db_type` phải là postgres/mysql/mariadb; `database` phải là bare identifier.
  - DB_SCHEMA_CHECK: bắt buộc `connection`, `checks[]` không rỗng; mỗi check phải có `kind` (TABLE_EXISTS/COLUMN_EXISTS/INDEX_EXISTS/PRIMARY_KEY) và các trường bắt buộc theo kind.
  - DB_MIGRATION: bắt buộc `connection`, `statements[]` không rỗng, mỗi entry là chuỗi không rỗng.
  - EXTRACT/DELAY: ném lỗi (không thể chạy độc lập).
- `generateSchema(StepType type)`: trả về JSON Schema draft-07 cho loại bước. Dùng cho endpoint `config-schema`.
- `capabilities()`: trả về mô tả năng lực (step types, db connection required fields, http methods, assertion kinds, schema check kinds, limits).

---

## 6. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 404 | Assignment không tồn tại | `TestPlanService.internalGradingConfig`, `internalPlans` |
| 502 | Executor-service không khả dụng (lỗi Feign) | `ExecutorInternalClient.dryRun` |
| 400 | Request body dry-run không hợp lệ | Executor-service (qua Feign) |
| 500 | `config-schema` với type EXTRACT/DELAY (không chạy độc lập) | `StepConfigValidator.generateSchema` |

---

## 7. Luồng dữ liệu từ đầu đến cuối (ví dụ executor-service lấy grading config + plans)

```
executor-service (Kafka consumer GRADE_SUBMISSION)
   │ GET /api/v1/internal/assignments/{id}
   │ GET /api/v1/internal/assignments/{id}/plans
   ▼
course-service: InternalAssignmentController.gradingConfig() / plans()
   │ 1. Gọi TestPlanService.internalGradingConfig(id) / internalPlans(id)
   ▼
TestPlanService
   │ 2. Truy vấn assignmentRepository / testPlanRepository / testStepRepository
   │ 3. Map sang AssignmentGradingConfigDto / InternalPlanDto (+ InternalStepDto)
   ▼
InternalAssignmentController
   │ 4. Trả về ResponseEntity.ok(DTO) — raw JSON, không envelope
   ▼
executor-service nhận DTO, dùng để khởi động docker-compose và chạy từng bước grading
```

---

## 8. Luồng dữ liệu dry-run (Phase 6)

```
Giảng viên (FE)
   │ POST /api/v1/internal/assignments/{id}/dry-run + body DryRunRequest
   ▼
course-service: InternalAssignmentController.dryRun()
   │ 1. Override assignmentId từ path variable vào DryRunRequest
   │ 2. Gọi ExecutorInternalClient.dryRun(normalized) → Feign executor-service
   ▼
executor-service: POST /api/v1/internal/grading/dry-run
   │ 3. Chạy grading config đối với reference code zip
   │ 4. Không ghi kết quả vào result-service, không cập nhật submission status
   │ 5. Trả về DryRunReport (dryRunId, steps, summary)
   ▼
course-service: InternalAssignmentController.dryRun()
   │ 6. Trả về ResponseEntity.ok(DryRunReport)
   ▼
FE hiển thị báo cáo dry-run cho lecturer xem trước
```

---

*Tài liệu này là phần tiếp theo của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/course-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
