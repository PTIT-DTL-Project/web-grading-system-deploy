# Plan: AI Agent tự động construct config test plan từ ý định giảng viên (tiếng Việt)

## 1. Mục tiêu

Giảng viên nhập tin nhắn tiếng Việt tự nhiên vào chat AI assistant (ví dụ: *"Tạo bài quản lý sách, tạo sách rồi lấy sách ra, sửa tiêu đề, xóa sách, kiểm tra đã xóa, kiểm tra bảng trong DB có cột id là primary key"*). AI agent sẽ:

1. Parse ý định bằng LLM sang Intermediate Representation (IR).
2. Sinh JSON config chuẩn theo `grading-config-reference.md`.
3. Trả về **raw JSON config** cho giảng viên xem trên FE (raw text, không cần FE form phức tạp).
4. Nếu giảng viên đồng ý, gọi API course-service để tạo thật (assignment + plan + steps).
5. **Không chạy dry-run** (vì không có dữ liệu mẫu tiếng Việt).

---

## 2. Kiến trúc hiện tại (evidence từ code đã đọc)

### 2.1 Course-service đã có sẵn endpoint tạo plan/step
| Endpoint | Method | DTO request | Mô tả |
|----------|--------|-------------|-------|
| `POST /api/v1/assignments/{aid}/plans/with-steps` | POST | `CreateQuestionRequest` (plan + steps[]) | Tạo 1 plan kèm toàn bộ steps |
| `POST /api/v1/assignments/{aid}/plans` | POST | `CreatePlanRequest` | Tạo plan trống |
| `GET /api/v1/assignments/{aid}/plans` | GET | - | Liệt kê plans |
| `PUT /api/v1/assignments/{aid}/plans/{pid}` | PUT | `UpdatePlanRequest` | Cập nhật plan |
| `DELETE /api/v1/assignments/{aid}/plans/{pid}` | DELETE | - | Xóa plan |
| `POST /api/v1/assignments/{aid}/plans/{pid}/steps` | POST | `CreateStepRequest` | Tạo 1 step |
| `GET /api/v1/assignments/{aid}/plans/{pid}/steps` | GET | - | Liệt kê steps |
| `PUT /api/v1/assignments/{aid}/plans/{pid}/steps/{sid}` | PUT | `UpdateStepRequest` | Cập nhật step |
| `DELETE /api/v1/assignments/{aid}/plans/{pid}/steps/{sid}` | DELETE | - | Xóa step |

### 1.2 `CreateStepRequest` (đã có sẵn)
```java
public class CreateStepRequest {
    @NotNull @Min(0) private Integer stepOrder;
    @NotBlank private String name;
    private String description;
    @NotNull private StepType stepType; // HTTP_REQUEST, DB_QUERY, DB_SCHEMA_CHECK, DB_MIGRATION, EXTRACT, DELAY
    @NotNull private JsonNode config;     // config JSON thô
    private JsonNode expectedResult;
    @Min(1) private Integer weight = 1;
    @Min(1) private Integer timeoutMs;
    private Boolean required = true;
}
```

### 1.3 `ai-assistant-service` đã có sẵn
- `ChatController`: `POST/GET /api/v1/ai/conversations/{id}/messages`
- `ConversationService.sendMessage()`: tạo `Run`, gọi `RunWorker.processRunAsync()`
- `AgentOrchestrator.executeRun()`: vòng đời run (QUEUED → RUNNING → SUCCEEDED/FAILED)
- `AgentRuntime.execute()`: vòng lặp agent: gọi LLM → tool calling → xử lý kết quả
- `LlmClient`: gọi Spring AI `ChatClient`, có `generateCompletion()`, `generateEntity()`, `streamCompletion()`
- `DomainApiTool`: gọi API domain qua `RestClient`, hỗ trợ FEIGN headers (`X-User-Id`, `X-User-Roles`, `X-Gateway-Secret`)
- `ToolRegistry`: đăng ký `AgentTool`, tra cứu theo tên
- `ToolExecutor`: thực thi tool, kiểm tra role, gọi `tool.execute()`
- `PromptBuilder`: build system prompt & user prompt cho AI explanation

### 1.4 `CourseServiceClient` hiện có
- `GET /api/v1/assignments/{id}` → `getAssignment()`
- `GET /api/v1/assignments/{id}/owned` → `getOwnedAssignment()`
- `POST /api/v1/assignments` → `createAssignment()`
- **CHƯA CÓ**: endpoint tạo plan/step. Cần bổ sung `PlanSubmissionClient` (FeignClient hoặc RestClient).

---

## 3. Plan chi tiết (5 track)

### Track A: Intent Parser — Hiểu ý định giảng viên từ tiếng Việt

**File mới:**
- `src/main/java/.../service/plan/PlanIntentParserService.java`
- `src/main/java/.../dto/plan/IntentRequest.java`
- `src/main/java/.../dto/plan/PlanIntent.java`

**Chi tiết:**
- `IntentRequest`: `conversationId`, `userMessage` (tiếng Việt), `assignmentContext` (tuỳ chọn: classId, topic)
- `PlanIntent`: `assignmentTitle`, `assignmentTopic`, `steps[]` (mỗi step: `stepType`, `entityName`, `method`, `pathPattern`, `payloadFields`, `expectedStatus`, `assertions[]`, `extractName`, `dbTable`, `dbChecks[]`, `dbQuery`)
- `PlanIntentParserService.parse()`: gọi `LlmClient.generateEntity()` với system prompt specially crafted, trả về JSON IR. Nếu JSON bị cắt/truncated → fallback về giá trị an toàn hoặc báo lỗi rõ ràng (không để crash).

**Các intent pattern cần hỗ trợ:**
| Intent | Method | Path | Assertion chính | Extract |
|--------|--------|------|-----------------|---------|
| Tạo tài nguyên | POST | `/api/v1/{entity}` | status 201, json_path `$.id` exists, contains tên | `entityId = $.id` |
| Lấy theo ID | GET | `/api/v1/{entity}/${id}` | status 200, body_structure, field_equals | - |
| Cập nhật | PATCH | `/api/v1/{entity}/${id}` | status 200, contains giá trị mới | - |
| Xóa | DELETE | `/api/v1/{entity}/${id}` | status 204 | - |
| Kiểm tra đã xóa | GET | `/api/v1/{entity}/${id}` | status 404 | - |
| Lọc/tìm kiếm | GET | `/api/v1/{entity}?search=...` | status 200, contains | - |
| Kiểm tra cấu trúc DB | DB_SCHEMA_CHECK | - | TABLE_EXISTS, PRIMARY_KEY | - |
| Truy vấn DB | DB_QUERY | - | `SELECT id FROM t WHERE id = '${id}'` → row_count: 0 | - |

---

### Track B: Config Builder — Sinh JSON config chuẩn từ IR

**File mới:**
- `src/main/java/.../service/plan/PlanConfigBuilderService.java`
- `src/main/java/.../dto/plan/PlanConfigResult.java`

**Chi tiết:**
- Nhận `PlanIntent` từ Track A.
- Sinh JSON config cho mỗi step theo đúng schema `grading-config-reference.md`:
  - **POST tạo:** `method: POST`, `path: /api/v1/{entity}`, `body`: fields từ intent, `assertions`: status 201, `json_path $.id` exists, `contains <tên>`, `extract: $.id → ${entityId}`.
  - **GET theo ID:** `method: GET`, `path: /api/v1/{entity}/${entityId}`, `assertions`: status 200, `body_structure` 4-5 keys, `field_equals` trường quan trọng.
  - **PATCH cập nhật:** `method: PATCH`, `path: /api/v1/{entity}/${id}`, `body`: field cập nhật, `assertions`: status 200, `contains` giá trị mới.
  - **DELETE xóa:** `method: DELETE`, `path: /api/v1/{entity}/${id}`, `assertions`: status 204.
  - **GET sau xóa:** `method: GET`, `path: /api/v1/{entity}/${id}`, `assertions`: status 404.
  - **DB_SCHEMA_CHECK:** `connection` block đầy đủ (`db_type: postgres`, `db_service: db`, `db_port: 5432`, `database`, `username`, `password`), `checks[]`: `TABLE_EXISTS` + `PRIMARY_KEY` với `table_name`.
  - **DB_QUERY:** `connection` block đầy đủ, `query: SELECT id FROM <table> WHERE id::text = '${entityId}'`, `expected.row_count: 0`.
- Chuẩn hóa tên entity sang tiếng Anh cho path (sách→books, tài sản→assets, sinh viên→students, đơn hàng→orders, kho hàng→inventory, bệnh nhân→patients, bác sĩ→doctors, lịch hẹn→appointments).
- Xác định `dockerComposePort` từ assignment config (nếu có) hoặc dùng mặc định (8080–8088).

**Output:** `PlanConfigResult` chứa `plans[]` (mỗi plan có `steps[]` với config đầy đủ) và `configJson` (dạng pretty-print raw text để hiển thị trên FE).

---

### Track C: Config Validator — Kiểm tra trước khi gửi API

**File mới:**
- `src/main/java/.../service/plan/PlanConfigValidatorService.java`

**Chi tiết:**
- Kiểm tra `method` trong danh sách hợp lệ (GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS).
- Kiểm tra `path` bắt đầu bằng `/`.
- Kiểm tra `expected_status` trong 100–599.
- Kiểm tra `assertions.kind` trong 13 kind: `status`, `contains`, `json_path`, `body_equals`, `body_structure`, `field_equals`, `array_length`, `contains_item`, `json_path_equals`, `greater_than`, `less_than`, `matches_regex`, `any_of`.
- Kiểm tra `connection.db_type` trong `postgres`, `mysql`, `mariadb`.
- Kiểm tra `data[]` tối đa 10 phần tử (loop safety governor).
- Kiểm tra `extract.name` chỉ chữ cái, số, gạch dưới.
- Kiểm tra biến `${...}` trong path/body/headers đã được extract ở bước trước (tránh tham chiếu biến chưa tồn tại).
- Trả về `ValidationResult`: `valid: boolean`, `errors[]` (mỗi error có `field`, `message`, `stepOrder`).

---

### Track D: Auto-submit API (tùy chọn, khi giảng viên muốn làm luôn)

**File mới:**
- `src/main/java/.../service/plan/PlanSubmissionService.java`
- `src/main/java/.../client/PlanSubmissionClient.java` (FeignClient hoặc RestClient gọi course-service)

**Chi tiết:**
- Gọi `POST /api/v1/assignments` để tạo assignment (nếu chưa có), lấy `assignmentId`.
- Gọi `POST /api/v1/assignments/{aid}/plans` để tạo plan, lấy `planId`.
- Gọi `PUT /api/v1/assignments/{aid}/plans/{pid}/steps/{sid}` cho từng step.
- Xử lý lỗi 400/401/403/502 từ gateway/course-service.
- Trả về `SubmissionResult`: `assignmentId`, `planId`, `steps[]` (mỗi step có `stepId`, `status`, `errorMessage`).

> **Lưu ý:** `CourseServiceClient` hiện có `createAssignment` (POST `/api/v1/assignments`). Cần bổ sung `PlanSubmissionClient` (FeignClient hoặc RestClient) để gọi `POST /api/v1/assignments/{aid}/plans` và `PUT /api/v1/assignments/{aid}/plans/{pid}/steps/{sid}`.

---

### Track E: FE-facing API — Trả về config JSON để giảng viên xem/chỉnh sửa

**File mới:**
- `src/main/java/.../controller/PlanGenerationController.java`
- `src/main/java/.../dto/plan/PlanGenerationRequest.java`
- `src/main/java/.../dto/plan/PlanGenerationResponse.java`

**Chi tiết:**
- `POST /api/v1/ai/conversations/{id}/plan-generate`: nhận tin nhắn tiếng Việt, trả về `PlanConfigResult` (JSON config chưa lưu, dưới dạng raw text).
- `POST /api/v1/ai/conversations/{id}/plan-submit`: nhận config đã chỉnh sửa từ FE, gọi `PlanSubmissionService` để lưu vào course-service.
- `PlanGenerationResponse`: chứa `plans[]`, `configJson` (dạng pretty-print), `warnings[]` (nếu có).

---

## 4. Luồng làm việc (workflow)

```
1. Giảng viên nhập tin nhắn tiếng Việt vào chat:
   "Tạo bài quản lý sách, tạo sách rồi lấy sách ra, sửa tiêu đề, xóa sách, kiểm tra đã xóa, kiểm tra bảng trong DB có cột id là primary key."

2. ChatController.sendMessage → ConversationService.sendMessage → AgentOrchestrator.executeRun

3. AgentOrchestrator chạy AgentRuntime, LLM sinh phản hồi.
   - Nếu LLM nhận diện đây là yêu cầu tạo plan (có từ khóa như "tạo bài", "tạo plan", "tạo test", "quản lý..."):
     a. PlanIntentParserService.parse(userMessage) → PlanIntent (danh sách intent).
     b. PlanConfigBuilderService.build(intent) → PlanConfigResult (JSON config chuẩn).
     c. PlanConfigValidatorService.validate(config) → ValidationResult.
     d. Nếu valid:
        - Nếu giảng viên chọn "tự động lưu": PlanSubmissionService.submit(...) → tạo assignment/plan/step thực tế qua API.
        - Nếu giảng viên chọn "xem trước": trả về PlanConfigResult (JSON config) để FE hiển thị.
     e. LLM sinh phản hồi tự nhiên cho giảng viên, kèm config JSON (hoặc thông báo đã tạo thành công).
4. FE hiển thị config JSON (raw text), giảng viên có thể chỉnh sửa và nhấn "Lưu" → gọi lại PlanSubmissionService.
```

---

## 5. Danh sách file cần tạo/chỉnh

| File | Loại | Mục đích |
|------|------|----------|
| `.../service/plan/PlanIntentParserService.java` | Mới | Parse ý định tiếng Việt → IR |
| `.../dto/plan/IntentRequest.java` | Mới | Request DTO |
| `.../dto/plan/PlanIntent.java` | Mới | IR DTO |
| `.../service/plan/PlanConfigBuilderService.java` | Mới | Sinh JSON config từ IR |
| `.../dto/plan/PlanConfigResult.java` | Mới | Result DTO |
| `.../service/plan/PlanConfigValidatorService.java` | Mới | Validate config trước khi lưu |
| `.../service/plan/PlanSubmissionService.java` | Mới | Gọi API tạo assignment/plan/step |
| `.../client/PlanSubmissionClient.java` | Mới | FeignClient/RestClient gọi course-service |
| `.../controller/PlanGenerationController.java` | Mới | Endpoint FE-facing |
| `.../dto/plan/PlanGenerationRequest.java` | Mới | Request DTO |
| `.../dto/plan/PlanGenerationResponse.java` | Mới | Response DTO |
| `.../service/plan/PlanIntentParserServiceTest.java` | Test | Test parse tiếng Việt |
| `.../service/plan/PlanConfigBuilderServiceTest.java` | Test | Test sinh config chuẩn |
| `.../service/plan/PlanConfigValidatorServiceTest.java` | Test | Test validation |
| `.../controller/PlanGenerationControllerTest.java` | Test | Test endpoint |

**File không cần sửa (đã có sẵn, tái sử dụng):** `ChatController`, `ConversationService`, `AgentOrchestrator`, `AgentRuntime`, `LlmClient`, `ToolRegistry`, `ToolExecutor`, `PromptBuilder`.

---

## 6. Các câu hỏi cuối cần xác nhận trước khi triển khai code

1. **CourseServiceClient hiện có `createAssignment` (POST /api/v1/assignments). Có endpoint tạo plan (POST /api/v1/assignments/{aid}/plans) và tạo step (PUT /api/v1/assignments/{aid}/plans/{pid}/steps/{sid}) chưa?** Nếu chưa, cần bổ sung Feign client mới hoặc dùng `RestClient` trực tiếp.
2. **Bạn có dữ liệu mẫu (mock student app) cho mỗi loại kiểm tra chưa?** Để AI agent có thể chạy dry-run và kiểm tra config chuẩn trước khi lưu (hiện tại bạn nói chưa có, nên ta sẽ bỏ qua dry-run).
3. **Bạn muốn AI agent dùng LLM để parse ý định tiếng Việt, hay dùng rule-based pattern matching?** Nếu dùng LLM, bạn có API key/model đã cấu hình trong `AiModelProperties` chưa?

Hãy trả lời 3 câu hỏi này, sau đó tôi sẽ triển khai code theo plan này. Nếu bạn đồng ý với plan và muốn tôi bắt đầu code ngay, hãy nói tôi **switch sang Goal mode** (hoặc agent khác có quyền viết code).