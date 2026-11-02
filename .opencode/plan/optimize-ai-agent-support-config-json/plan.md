# Plan: Tối ưu hỗ trợ AI Agent cấu hình JSON test plan/step (P1 + P2 + P3)

## Mục tiêu
- **Enforce bắt buộc** `connection.username`, `connection.password`, `connection.database` cho các DB step (`DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`) ở cả validation, chat guidance và tài liệu.
- Đồng bộ hoàn toàn giữa `lecturer-plan-context.md`, `GetTestStepCapabilitiesTool`, `StepConfigValidator`, corpus golden và runtime.
- Chuẩn hóa flow validate/schema/capabilities thành **single source of truth** (P2): sinh từ `StepConfigValidator`, bổ sung endpoint mới, FE preview schema theo `stepType`.
- Sửa các lỗ hổng: `auto_inject_headers` (vị trí khai báo + shield), `updateTestStep` validate contract, `any_of.status`, `expected.columns`, schema preview sai loại step ở FE, config chết `max-validation-repairs`, v.v. (P1 + P3).
- Cập nhật docs (`grading-config-reference.md`, `usecase-flows.md`, `http-test-plan-config.md` nếu cần), skills (`http-step-config`, `ai-assistant-service`) và đồng bộ `.opencode/skills/` ↔ `.kilo/skills/`.

## Phạm vi
- **course-service**: `StepConfigValidator`, `InternalTestPlanController`, `InternalAssignmentController`, DTO mới, tests (`StepConfigValidatorTest`, `PlanCorpusTest`, `TestPlanServiceTest` nếu cần)
- **ai-assistant-service**: `DomainApiTool`, `DomainToolConfiguration`, bỏ `GetTestStepCapabilitiesTool` cũ (hoặc thay thế), bỏ `agent.limits.max-validation-repairs`, cập nhật `lecturer-plan-context.md`, tests (`DomainApiToolTest`, `ContextBuilderTest`, `AgentRuntimeTest`)
- **course-service src/test/resources/plan-corpus**: sửa `03-auth-jwt-auto-headers.json` + mở rộng linter
- **frontend-src/web-grading-system-fe**: `schema.ts`, `StepEditor.tsx` (fetch schema theo stepType)
- **docs/design/**: `grading-config-reference.md`, `usecase-flows.md`, `http-test-plan-config.md`
- **.opencode/skills/** và **.kilo/skills/**: cập nhật `http-step-config`, `ai-assistant-service`

## Lưu ý quan trọng
- **Không push thẳng lên `main`**. Tạo branch `fix/optimize-ai-agent-support-config-json` (hoặc `feat/...`) trong repo liên quan theo quy tắc dự án.
- **DB credentials bắt buộc**: validator sẽ bắt buộc `database` + `username` + `password` cho mọi DB step. Các bước DB cũ không đủ credentials sẽ bị chặn khi update/create qua agent path — đây là hành vi mong muốn (khớp thực tế runtime + sandbox `DbSandboxService`).
- **Auto-inject**: chỉ có tác dụng từ bước **trước** trở đi; bước khai báo header để dùng cho chính nó **không** hiệu quả. Bước âm tính cần "shield" bằng cách tự đặt header (hoặc giá trị cụ thể).
- **`updateTestStep`**: contract validate phải hỗ trợ single-step payload, không chặn sửa config bình thường.
- **Single source of truth**: mọi "capabilities/schema required fields" phải sinh từ `StepConfigValidator`.

---

## P1 — Sửa đúng/sai và đồng bộ guidance + validation

### A. course-service: `StepConfigValidator`
**File:** `src-services/course-service/src/main/java/vn/edu/ptit/web_grading_system/course_service/service/StepConfigValidator.java`

- [ ] **Thêm constants chung**
  - `private static final List<String> DB_CONN_REQUIRED = List.of("database", "username", "password");`
  - Gom các required fields theo stepType để dùng chung cho `validate*` và `capabilities()`.
- [ ] **`validateConnection(JsonNode conn)`**
  - Yêu cầu `conn` là object, không null/empty.
  - Bắt buộc có đủ `database`, `username`, `password` (không cho trống/blank). Nếu thiếu → báo lỗi rõ: `"connection thiếu trường bắt buộc: 'database'/'username'/'password'..."` theo style message hiện tại.
  - Giữ validation `db_type` (`postgres|mysql|mariadb`), `db_port` (integer >=1), `db_service` string.
- [ ] **Áp dụng cho DB steps**
  - `validateDbQuery`, `validateDbSchemaCheck`, `validateDbMigration`: phải gọi `validateConnection` (bắt buộc). Bỏ hành vi "connection optional".
- [ ] **`validateSchemaCheck`**
  - Đồng bộ required fields rõ ràng, gom lỗi thiếu field vào 1 pass (thuận tiện repair loop).
- [ ] **`validateHttp`**
  - **Chặn** `status` assertion lồng trong `any_of`. Nếu phát hiện `any_of` chứa item có `kind=status` → trả lỗi rõ.
- [ ] **`validateDbQuery`**
  - Hỗ trợ/khai báo rõ `expected.columns` (array of strings) bên cạnh `expected.row_count` (int >=0).
- [ ] **Schemas**
  - Cập nhật `generateHttpSchema()`, `generateDbQuerySchema()`, `generateDbSchemaCheckSchema()`, `generateDbMigrationSchema()`:
    - `connection` object: thêm `"required": ["db_type"? hoặc chỉ các bắt buộc, đảm bảo database/username/password bắt buộc]` theo đúng nghĩa. Thực tế: **bắt buộc** `database`, `username`, `password`. `db_type` có default `postgres` ở runtime nhưng schema/validation cần rõ ràng — ưu tiên bắt buộc theo yêu cầu user.
    - Các DB step schema: thêm `"connection"` vào `required` của step config.
    - `data`: `maxItems: 10`.
    - `expected` (DB): mô tả `row_count`, `columns`.
  - Giữ forward compatible, unknown keys vẫn tolerable nếu không phá cấu trúc.
- [ ] **Cập nhật javadoc**: sửa các comment còn nói "connection optional"/"defaultsToPostgres" sang trạng thái bắt buộc hiện tại.
- [ ] **Thêm `capabilities()` method**
  ```java
  public static JsonNode capabilities() {
      // build từ constants + schemas, trả về cấu trúc ổn định cho agent/FE
  }
  ```
  Đảm bảo output chứa: step types, required fields, assertion kinds, connection required, `data.maxItems`, `auto_inject_headers` notes nếu cần.

### B. course-service: Controllers/DTO
**Files:** `controller/InternalTestPlanController.java`, `controller/InternalAssignmentController.java`, DTO mới

- [ ] **`InternalTestPlanController`**
  - Thêm `POST /api/v1/internal/test-plans/validate-step`
    - Request: `{ "stepType": "DB_QUERY|HTTP_REQUEST|DB_SCHEMA_CHECK|DB_MIGRATION", "config": {...} }`
    - Response: reuse `ValidateQuestionResponse` (ok + errors with paths)
  - Thêm `GET /api/v1/internal/test-plans/capabilities` → trả về `StepConfigValidator.capabilities()`
- [ ] **DTO mới** `dto/internal/ValidateStepRequest.java` (jakarta validation)
- [ ] **`InternalAssignmentController`**
  - Thay đổi `GET /{id}/config-schema` hỗ trợ `?type=HTTP_REQUEST|DB_QUERY|DB_SCHEMA_CHECK|DB_MIGRATION` (default `HTTP_REQUEST` giữ backward compat)
  - Gọi `StepConfigValidator.generateSchema(type)` (cần thêm public static method nếu chưa có)

### C. course-service: Tests
- [ ] **`StepConfigValidatorTest`**
  - Xóa/đổi test `connection_absent_passes_defaultsToPostgres` → `connection_absent_fails_for_db_steps`
  - Thêm test: DB step thiếu `username`/`password`/`database` → fail với message chứa tên field
  - Thêm test: `any_of` có `status` assertion → fail
  - Thêm test: `DB_QUERY` với `expected.columns` hợp lệ → pass
  - Thêm test: schema có `connection` required cho DB
  - Thêm test: `capabilities()` có đủ keys
- [ ] **`PlanCorpusTest`**
  - Linter mới:
    - DB step phải có `config.connection.database|username|password` đầy đủ
    - Nếu `auto_inject_headers` được dùng, phải khai báo ở **bước có index < bước dùng** (hoặc log vị trí khai báo). Bước âm tính auth cần "shield" (tự đặt header) — linter check cơ bản
    - Cấm `expectedResult` cấp step (nếu phát hiện → fail với hướng dẫn)
  - Chạy lại toàn bộ corpus phải pass sau khi sửa corpus 03
- [ ] **`TestPlanServiceTest`** (nếu cần): kiểm tra không break flow hiện tại

### D. course-service: Sửa corpus
**File:** `src/test/resources/plan-corpus/03-auth-jwt-auto-headers.json`

- [ ] Di chuyển `auto_inject_headers` sang **bước 0 "Login lấy access token"** (khai báo tại bước sinh token)
- [ ] **Bước 3 "Kiểm tra 401 khi không token"**: thêm `headers` rõ ràng để **shield** (không phụ thuộc auto-inject). Ví dụ bỏ `Authorization` hoặc đặt giá trị sai theo đúng kịch bản
- [ ] **Bước 4 "Kiểm tra 403 khi không quyền"**: xử lý tương tự nếu cần
- [ ] Đảm bảo steps sau (2) vẫn nhận header đúng cách

---

## P2 — Single source of truth + FE đồng bộ

### E. ai-assistant-service: DomainApiTool
**File:** `src-services/ai-assistant-service/src/main/java/vn/edu/ptit/web_grading_system/ai_assistant_service/tools/DomainApiTool.java`

- [ ] **`validateStepPayloads` rewrite**
  - `createTestQuestion`: validate câu hỏi như hiện tại
  - `createTestStep`: gửi `{steps:[payload]}` đến `POST /api/v1/internal/test-plans/validate-step`? HOẶC giữ `/validate` nếu endpoint cũ vẫn hỗ trợ, nhưng ưu tiên dùng `/validate-step` mới (rõ ràng hơn). Cần đảm bảo backward compat.
  - `updateTestStep`: 
    - Nếu payload có `stepType` và `config` → wrap `{steps:[{stepType, config}]}` gọi `/validate-step`
    - Nếu payload **không có config** → **bỏ qua validate** (không gọi API) 
    - Nếu payload có `config` nhưng **thiếu `stepType`** → trả `ToolResult.error("INVALID_ARGUMENTS", "... cần stepType khi validate config...")` hướng dẫn rõ
  - Thêm logging ngắn gọn
- [ ] **Mirror offline mode** theo logic mới

### F. ai-assistant-service: Tools wiring
- [ ] **Thay thế `getTestStepCapabilities`**
  - `DomainApiTool` thêm action `getTestStepCapabilities` gọi `GET /api/v1/internal/test-plans/capabilities` (assignment-scoped không bắt buộc, endpoint internal)
  - Xóa hoặc bỏ đăng ký class `tools/lecturer/GetTestStepCapabilitiesTool.java` (tránh duplicate)
- [ ] **Thêm tool `getStepConfigSchema`**
  - Gọi `GET /api/v1/internal/assignments/{assignmentId}/config-schema?type={stepType}` 
  - Cần `assignmentId` trong args (validate)
- [ ] **`DomainToolConfiguration`** cập nhật đăng ký tools

### G. ai-assistant-service: Config cleanup
- [ ] Xóa `agent.limits.max-validation-repairs` khỏi `AgentProperties.java`
- [ ] Xóa khỏi `src/main/resources/application.yaml`
- [ ] Xóa mọi usage (grep để đảm bảo)

### H. Frontend: Schema preview theo stepType
**Files:** `frontend-src/web-grading-system-fe/src/shared/api/endpoints/schema.ts`, `src/features/assignments/StepEditor.tsx`

- [ ] **`schema.ts`**
  - `getConfigSchema(assignmentId, type?)` truyền query `type` (default `HTTP_REQUEST` hoặc undefined cho backward compat)
- [ ] **`StepEditor.tsx`**
  - Fetch schema khi `assignmentId` và `stepType` có giá trị thay đổi
  - Re-fetch trên thay đổi `stepType` (debounce nhẹ không cần, thay đổi form là đủ)
  - Hiển thị SchemaPreview đúng schema của loại step đang chọn

---

## P3 — Docs, skills, polish

### I. Cập nhật prompt hướng dẫn AI
**File:** `src-services/ai-assistant-service/src/main/resources/prompts/lecturer-plan-context.md`

Cập nhật các mục:

- [ ] **§Cấu trúc config theo stepType / DB**
  - `connection`: liệt kê **bắt buộc** `database`, `username`, `password`. `db_type` (mặc định `postgres`), `db_service`, `db_port` optional nhưng cần khớp thực tế
  - Thêm note: "Sandbox reset giữa các plan dùng chính credentials này (cần quyền tạo/xóa DB) — nếu thiếu quyền sẽ fail toàn bộ job"
- [ ] **HTTP_REQUEST / auto_inject_headers**
  - "Khai báo `auto_inject_headers` tại **bước login/bước sinh token** (bước chạy trước). Chỉ có hiệu lực với các HTTP_REQUEST **sau** bước đó."
  - "Bước cần header riêng hoặc bước kiểm tra **âm tính** (vd 401/403) phải tự đặt header (shield). Nếu đã có header cùng tên trên step, auto-inject sẽ không ghi đè."
- [ ] **Intake hỏi nhanh**
  - Khi tạo plan DB: hỏi **engine, db_service, database, username, password** (gợi ý mặc định hợp lý)
- [ ] **Assertions**
  - `expected_status`: khuyến nghị **luôn đặt** 
  - Chặn `status` trong `any_of`
- [ ] **DB_QUERY expected**
  - Thêm `expected.columns` (array)
- [ ] **Cảnh báo**
  - DDL MySQL/MariaDB tự commit
  - Không gửi `expectedResult` cấp step
- [ ] Đồng bộ với capabilities mới

### J. Cập nhật docs thiết kế
**Files:** `docs/design/grading-config-reference.md`, `docs/design/usecase-flows.md`, `docs/design/http-test-plan-config.md`

- [ ] **`grading-config-reference.md`**
  - Bảng connection: đổi `username/password/database` từ optional → **required** cho DB steps
  - Thêm note sandbox quyền DDL
  - Mục auto_inject_headers rõ vị trí + shield
  - Thêm `expected.columns`
  - Ghi rõ `?type=` cho config-schema
- [ ] **`usecase-flows.md`**
  - Cập nhật **UC-05** (DB steps) phản ánh credentials bắt buộc
  - Thêm/ cập nhật flow **validate** (`/validate-step`) và **capabilities** cho agent
- [ ] **`http-test-plan-config.md`**: rà soát mâu thuẫn, cập nhật nếu có

### K. Cập nhật skills (đồng bộ .opencode + .kilo)
**Skills:** `http-step-config`, `ai-assistant-service`

- [ ] **`http-step-config/SKILL.md`** 
  - Thêm rule "DB connection credentials bắt buộc (database/username/password)"
  - Cập nhật auto_inject_headers (vị trí + shield + không áp cho chính step)
  - Thêm `expected.columns`, chặn `any_of.status`
- [ ] **`ai-assistant-service/SKILL.md`**
  - Thêm endpoint mới: `validate-step`, `capabilities`, `config-schema?type=`
  - Quy tắc updateTestStep validation
  - Thay thế getTestStepCapabilities → từ capabilities endpoint
  - Đồng bộ cả `.opencode/skills/` và `.kilo/skills/` (identical)

---

## Thứ tự thực thi

1. **A-B-C-D** (course-service core + corpus) — nền tảng validation
2. **E-F-G-H** (ai-assistant + FE) — tích hợp agent + UI
3. **I-J-K** (docs + skills) — đồng bộ knowledge base
4. **Verify** (chạy tests toàn bộ)

## Verification

### Tests
- [ ] `cd src-services/course-service && ./mvnw -o test -Dtest=StepConfigValidatorTest,PlanCorpusTest`
- [ ] `cd src-services/course-service && ./mvnw -o test` (toàn module nếu thời gian cho phép)
- [ ] `cd src-services/ai-assistant-service && ./mvnw -o test -Dtest=DomainApiToolTest,ContextBuilderTest,AgentRuntimeTest`
- [ ] `cd src-services/ai-assistant-service && ./mvnw -o test`

### Manual checks
- [ ] Agent tạo DB step thiếu credentials → validation trả lỗi rõ ràng
- [ ] Agent sửa DB step (`updateTestStep`) với config hợp lệ → validate chạy đúng qua `/validate-step` (hoặc skip nếu không có config)
- [ ] `getTestStepCapabilities` trả dữ liệu từ `/capabilities` đồng bộ với validator
- [ ] FE mở editor DB step → SchemaPreview hiển thị schema DB, HTTP step hiển thị schema HTTP
- [ ] Corpus 03 pass linter mới
- [ ] Plan DB có credentials đầy đủ chạy bình thường

### Repo hygiene
- [ ] Skills đồng bộ `.opencode/` ↔ `.kilo/` hoàn toàn giống nhau
- [ ] Không có `max-validation-repairs` còn sót
- [ ] `GetTestStepCapabilitiesTool` cũ không còn gây duplicate (hoặc đã xóa)
- [ ] Docs cập nhật đầy đủ

## Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Validator bắt buộc credentials gây break existing data/flows | Cao | Chỉ enforce ở validation API + agent path; TestPlanService hiện tại đã dùng `validateAndSerialize` — cần kiểm tra kỹ callers. Thêm thông báo lỗi rõ ràng. |
| Thay đổi contract `updateTestStep` validate | Cao | Xử lý 3 case rõ ràng, test đầy đủ, mirror offline mode. |
| Corpus 03 sửa sai break PlanCorpusTest | Trung bình | Chạy `PlanCorpusTest` ngay sau sửa, đọc kỹ logic auto-inject runtime. |
| FE schema fetch theo stepType gây thêm request | Thấp | Re-fetch hợp lý, fallback về HTTP schema nếu lỗi. |

## Definition of Done
- [ ] Tất cả checklist trên hoàn thành
- [ ] Tests liên quan pass
- [ ] Docs + skills đồng bộ
- [ ] Không còn tài liệu/cheat sheet nào nói "connection optional" cho DB steps
- [ ] Single source of truth đã thiết lập (capabilities/schema từ validator)
- [ ] Sẵn sàng tạo PR (không push thẳng `main`)
