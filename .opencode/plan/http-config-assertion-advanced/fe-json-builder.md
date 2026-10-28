# Kế hoạch FE: Giao diện hỗ trợ build JSON config Test Plan/Step

**Dự án:** Web Grading System — `frontend-src/web-grading-system-fe`  
**Thư mục:** `.opencode/plan/http-config-assertion-advanced/` (cùng nhóm với plan backend)  
**File:** `fe-json-builder.md`  
**Ngôn ngữ:** Tiếng Việt  
**Mục tiêu:** Giảng viên không phải gõ thô cục JSON dài hàng nghìn dòng. Giao diện form-step, validate real-time, preview JSON, import Postman/OpenAPI, xuất JSON Schema từ backend.

---

## 1. Nghiên cứu mã nguồn FE hiện tại

### 1.1 Tech stack
| Thành phần | Phiên bản | Ghi chú |
|------------|-----------|---------|
| React | 19.2.8 | |
| Ant Design | 6.6.5 | Thư viện UI chính |
| Vite | 8.2.1 | Build tool |
| TypeScript | 6.0.3 | |
| i18next / react-i18next | 26 / 17 | `src/locales/vi.json`, `en.json` |
| axios | 1.20.0 | `src/shared/api/http.ts`, có unwrap envelope, refresh token 401 |
| TanStack Query | 5.104.1 | Đã cài nhưng **chưa dùng** trong `features/assignments` (dùng custom hook `useState`+`useEffect`) |

### 1.2 Cấu trúc thư mục liên quan
```
src/features/assignments/
├── StepEditor.tsx          # Form soạn step (guided + advanced JSON), 1031 dòng
├── TestPlanEditor.tsx      # Modal tạo/sửa plan
├── PlanCard.tsx            # Card plan, nhúng StepEditor
├── ConnectionFields.tsx    # Form kết nối DB (postgres/mysql/mariadb)
├── stepConfig.ts           # Helpers: buildConnection, SYSTEM_VARIABLES, RESTRICTED_HEADERS
├── useTestPlans.ts         # Hook CRUD plan
├── useTestSteps.ts         # Hook CRUD step
├── useAssignments.ts
├── AssignmentResultsPage.tsx
├── AssignmentSubmissionsPage.tsx
├── LecturerStepEvidence.tsx
├── CreateAssignmentModal.tsx
├── EditAssignmentModal.tsx
└── SubmissionDetailCard.tsx

src/shared/
├── api/
│   ├── endpoints/assignments.ts   # API: list/create/update/delete plan & step
│   ├── http.ts                    # Axios instance, unwrap envelope, 401 retry
│   └── errors.ts                  # ApiError class
├── types/
│   └── assignment.ts              # StepCreateBody, StepUpdateBody, TestStep, TestPlan, StepType, ...
└── ui/
    ├── stepDetail.ts              # StepDetailModel, normalizeLecturerStep, maskHeaders, maskSensitiveValues
    └── StepDetailView.tsx         # Xem chi tiết step (lecturer full / student contract)

src/locales/
├── vi.json       # Có section "step" (đã đủ các key cơ bản HTTP/DB)
└── en.json       # Đồng key với vi.json
```

### 1.3 Hiện trạng soạn config step
- `StepEditor` có 2 chế độ: **Guided** (form antd) và **Advanced** (JSON thô).
- Guided hỗ trợ: `HTTP_REQUEST` (method, path, headers, query_params, body, assertions, extract), `DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION` (connection + query/checks/statements).
- Có preview JSON (ẩn mật khẩu/authorization).
- Có cảnh báo: biến chưa định nghĩa, header bị cấm, body bị bỏ qua, status/check thiếu.
- **Chưa có:** nhập biến cố định (`variables[]` cấp plan/step), `data[]` lặp, `auto_inject_headers`, `fallback` trong extract, `as: "json"`, Faker token, import Postman/OpenAPI, JSON Schema endpoint.

### 1.4 Giao diện i18n hiện có (section `step`)
`vi.json` và `en.json` đã có các key: `name`, `type`, `config`, `weight`, `timeout`, `required`, `description`, `mode` (guided/advanced), `httpMethod`, `httpPath`, `httpExpectedStatus`, assertions (`status`, `json_path`, `contains`, `field_equals`, `body_equals`, `body_structure`), extract, DB connection/query/checks/statements, warnings.  
**Thiếu:** các key cho `data[]`, `auto_inject_headers`, `fallback`, `as`, Faker, import Postman/OpenAPI, JSON Schema.

---

## 2. Kiến trúc đề xuất cho FE JSON Builder

### 2.1 Nguyên tắc thiết kế
- **Không thay thế** `StepEditor` hiện tại ngay lập tức; xây dựng thành **tab/mode bổ sung** hoặc **component độc lập** song song, sau đó dần hợp nhất.
- Mỗi loại step (HTTP_REQUEST, DB_QUERY, ...) có **form riêng**, render theo `stepType`.
- Validate real-time khi lecturer nhập, hiển thị lỗi antd `Form.Item` trước khi nhấn Lưu.
- Preview JSON luôn hiện ở cuối form, tự động cập nhật khi thay đổi trường nào.
- Dùng `Form.List` cho mảng (headers, query_params, assertions, extracts, checks, statements, data rows).
- Mật khẩu/token được mask trong preview và form (`Input.Password`).

### 2.2 Thành phần mới đề xuất

| File | Mô tả |
|------|-------|
| `src/features/assignments/stepBuilder.ts` | Helpers chung: build config JSON từ form values theo từng step type, reverse-map JSON sang form, validation rules |
| `src/features/assignments/StepBuilderForm.tsx` | Form cha, chọn `stepType`, render tab con tương ứng |
| `src/features/assignments/HttpStepForm.tsx` | Form HTTP_REQUEST: method, path, headers, query_params, body, assertions, extracts, `data[]`, `auto_inject_headers`, `fallback`, `as` |
| `src/features/assignments/DbStepForm.tsx` | Form DB: connection, query/checks/statements, expected result |
| `src/features/assignments/ImportModal.tsx` | Modal import Postman Collection / OpenAPI Spec → sinh steps thô |
| `src/features/assignments/SchemaPreview.tsx` | Hiển thị JSON Schema từ backend (dùng cho tab Advanced hoặc side panel) |
| `src/features/assignments/useStepBuilder.ts` | Hook quản lý state form, submit, lỗi |
| `src/shared/api/endpoints/schema.ts` | (Mới) Endpoint `GET /api/v1/internal/assignments/{id}/config-schema` |

### 2.3 Luồng dữ liệu
```
Lecturer chọn stepType
  └─> StepBuilderForm render form tương ứng
       ├─> Nhập liệu → validate real-time (antd rules)
       ├─> Preview JSON tự động sinh ra (gộp cấu trúc backend mong đợi)
       ├─> Nhấn Lưu → gọi createStep/updateStep (API hiện có)
       └─> Backend StepConfigValidator Validate → 201/400
```

### 2.4 Tích hợp backend (đang được lên kế hoạch riêng)
- Backend cần exposes `GET /api/v1/internal/assignments/{id}/config-schema` trả về JSON Schema.
- FE gọi endpoint này khi mở tab Advanced / side panel, dùng để hiển thị schema hoặc validate client-side trước khi gửi.

---

## 3. Các Phase FE (theo nhóm kế hoạch tổng thể)

### Phase FE-1 — Nâng cấp StepEditor hiện tại (không phá gì)

Thêm các trường vào form guided hiện có để hỗ trợ config mới từ plan backend.

| Mã FE | Tính năng | File sửa |
|-------|-----------|----------|
| FE-1.1 | Thêm trường `fallback` vào mỗi dòng extract (Input) | `StepEditor.tsx` (tab Variables), `stepConfig.ts` |
| FE-1.2 | Thêm select `as` (scalar/json) vào mỗi dòng extract | `StepEditor.tsx` |
| FE-1.3 | Thêm assertion kinds mới: `array_length`, `contains_item`, `greater_than`, `less_than`, `matches_regex`, `any_of` | `StepEditor.tsx` (tab Tests), `AssertionFields` |
| FE-1.4 | Cảnh báo unresolved variable bao gồm Faker token và built-in `${$UUID}`, `${$TIMESTAMP}`, `${$FAKER_*}` | `StepEditor.tsx` (`collectUsedVars`) |
| FE-1.5 | Cập nhật i18n vi.json/en.json các key mới | `src/locales/vi.json`, `en.json` |

**DoD:** Lecturer có thể chọn `as: "json"`, nhập `fallback`, thêm assertion `array_length`/`greater_than`, preview JSON đúng cấu trúc backend.

---

### Phase FE-2 — Form builder độc lập (StepBuilderForm)

Tách logic build config ra file riêng, tạo form builder có thể reuse giữa Create/Edit step.

| Mã FE | Tính năng | File mới/sửa |
|-------|-----------|--------------|
| FE-2.1 | Tạo `stepBuilder.ts` với `buildHttpConfig()`, `buildDbConfig()`, `reverseMapHttpConfig()`, `reverseMapDbConfig()` | `stepBuilder.ts` (mới) |
| FE-2.2 | Tạo `StepBuilderForm.tsx` — form cha chọn stepType, render `HttpStepForm` hoặc `DbStepForm` | `StepBuilderForm.tsx` (mới) |
| FE-2.3 | Tạo `HttpStepForm.tsx` — form HTTP đầy đủ: headers/query/body/assertions/extracts/data[]/auto_inject_headers | `HttpStepForm.tsx` (mới) |
| FE-2.4 | Tạo `DbStepForm.tsx` — form DB: connection, query/checks/statements | `DbStepForm.tsx` (mới) |
| FE-2.5 | Hook `useStepBuilder.ts` quản lý state form, submit, lỗi validation | `useStepBuilder.ts` (mới) |
| FE-2.6 | Tích hợp vào `PlanCard`: mở `StepBuilderForm` thay vì `StepEditor` (hoặc làm tab trong StepEditor) | `PlanCard.tsx`, `StepEditor.tsx` |

**DoD:** Tạo/sửa step không cần chạm JSON thô, form validate trước khi lưu, JSON preview khớp với cấu trúc backend.

---

### Phase FE-3 — Data-driven loop & Auth inject UI

Hỗ trợ các cấu trúc phức tạp hơn trong form.

| Mã FE | Tính năng | File |
|-------|-----------|------|
| FE-3.1 | Form nhập `data[]` (mảng các bản ghi), mỗi dòng là một biến set, mỗi bản ghi sinh 1 request khi chạy | `HttpStepForm.tsx` (section Data rows) |
| FE-3.2 | Giới hạn UI: tối đa 10 dòng `data[]` (mirror C8 backend), hiển thị cảnh báo khi đạt ngưỡng | `HttpStepForm.tsx` |
| FE-3.3 | Checkbox `auto_inject_headers` cấp Plan (hoặc cấp step) — tự động tiêm `Authorization: Bearer ${token}` vào các bước sau | `StepBuilderForm.tsx` / `PlanCard` (cấp plan) |
| FE-3.4 | Chọn biến từ danh sách biến đã extract (có sẵn từ `availableVariables`) để đưa vào header/body/query | `HttpStepForm.tsx` |

**DoD:** Lecturer tạo 4 dòng dữ liệu khác nhau trong 1 step, preview sinh 4 cấu hình request; chọn auto-inject token không cần gõ header thủ công.

---

### Phase FE-4 — Import Postman / OpenAPI (Config by Example)

Giảng viên không bắt tay từ blank form.

| Mã FE | Tính năng | File |
|-------|-----------|------|
| FE-4.1 | Modal `ImportModal`: nhập dán văn bản Postman Collection JSON hoặc upload file `.json` | `ImportModal.tsx` (mới) |
| FE-4.2 | Parse Postman item → sinh `HTTP_REQUEST` steps thô (method, url→path, header, body), assertion mặc định status 200 + body_structure | `ImportModal.tsx` (parser) |
| FE-4.3 | (Tùy chọn) Parse OpenAPI Spec (Swagger) → sinh steps từ `paths` | `ImportModal.tsx` |
| FE-4.4 | Sau import, lecturer vào `StepBuilderForm` tinh chỉnh assertions/extract | `PlanCard` → `StepBuilderForm` |

**DoD:** Dán Postman collection → thấy danh sách step đã sinh, chỉ cần chỉnh assertions/extract.

---

### Phase FE-5 — JSON Schema & Visual Editor side panel

| Mã FE | Tính năng | File |
|-------|-----------|------|
| FE-5.1 | API endpoint `GET /api/v1/internal/assignments/{id}/config-schema` | `src/shared/api/endpoints/schema.ts` (mới) |
| FE-5.2 | Component `SchemaPreview`: hiển thị schema, có thể expand/collapse từng trường | `SchemaPreview.tsx` (mới) |
| FE-5.3 | Tab "JSON Schema" bên cạnh Advanced trong StepEditor, hoặc side panel khi mở Advanced | `StepEditor.tsx` |
| FE-5.4 | Validate client-side trước khi gửi (dùng schema đơn giản hoặc antd rules đã có) | `useStepBuilder.ts` / `StepBuilderForm.tsx` |

**DoD:** Lecturer xem schema chuẩn từ backend khi cần, form luôn validate theo schema đó.

---

## 4. Chi tiết từng thành phần mới

### 4.1 `stepBuilder.ts` — helpers build/reverse config

```typescript
// Ví dụ ý định (chưa viết code thực):
export function buildHttpConfig(values: HttpFormValues): Record<string, unknown> {
  const config: Record<string, unknown> = {
    method: values.method,
    path: values.path,
  }
  if (values.expectedStatus) config.expected_status = values.expectedStatus
  if (values.headers?.length) config.headers = toMap(values.headers)
  if (values.queryParams?.length) config.query_params = toMap(values.queryParams)
  if (values.body) config.body = parseJson(values.body)
  if (values.assertions?.length) config.assertions = values.assertions.map(buildAssertion)
  if (values.extracts?.length) config.extract = values.extracts.map(buildExtract) // có fallback, as
  if (values.dataRows?.length) config.data = values.dataRows
  return config
}

export function reverseMapHttpConfig(config: Record<string, any>): HttpFormValues {
  // Ngược lại: JSON → form values
}
```

### 4.2 `HttpStepForm.tsx` — cấu trúc form
- Method select (GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS)
- Path input (bắt buộc, bắt đầu bằng `/`)
- Expected status InputNumber (100–599)
- Tabs: Params (Form.List key/value/enabled), Headers (Form.List), Body (none/raw, Input.TextArea), Tests (Form.List assertions), Variables (Form.List extracts + `as`, `fallback`), Data (Form.List data rows, max 10)
- Danh sách biến có sẵn (`availableVariables`) hiển thị dưới dạng nút copy `${var}`

### 4.3 `ImportModal.tsx` — parser Postman
- Input textarea dán JSON Postman Collection
- Nút "Import" → parse `item[]` → mỗi item thành step thô:
  - `request.method` → `method`
  - `request.url.raw` hoặc `url.path` → `path`
  - `request.header[]` → `headers`
  - `request.body.raw` → `body`
  - Assertion mặc định: `{ kind: "status", equals: 200 }`
- Lecturer review từng step trước khi import vào plan

---

## 5. Cập nhật i18n (vi.json + en.json)

Thêm key mới vào section `step`:

```json
"step": {
  ...
  "extractAs": "Kiểu lưu",
  "extractAsScalar": "Chuỗi (scalar)",
  "extractAsJson": "JSON đầy đủ",
  "extractFallback": "Giá trị mặc định nếu thiếu",
  "dataRows": "Dòng dữ liệu (lặp)",
  "dataRowLimit": "Tối đa 10 dòng",
  "autoInjectHeaders": "Tự động tiêm header auth vào các bước sau",
  "assertionArrayLength": "Độ dài mảng",
  "assertionContainsItem": "Mảng chứa mục",
  "assertionGreaterThan": "Lớn hơn",
  "assertionLessThan": "Nhỏ hơn",
  "assertionMatchesRegex": "Khớp regex",
  "assertionAnyOf": "Thỏa mãn ít nhất 1 (OR)",
  "importTitle": "Nhập Postman / OpenAPI",
  "importPlaceholder": "Dán JSON collection hoặc spec ở đây",
  "importPreview": "{{count}} bước đã sinh",
  "schemaTitle": "JSON Schema chuẩn"
}
```

Cập nhật cả `vi.json` và `en.json` để giữ đồng bộ.

---

## 6. File cần tạo/sửa (tổng hợp)

| File | Hành động | Mô tả |
|------|-----------|-------|
| `src/features/assignments/stepBuilder.ts` | Tạo | Helpers build/reverse config JSON |
| `src/features/assignments/StepBuilderForm.tsx` | Tạo | Form cha chọn stepType |
| `src/features/assignments/HttpStepForm.tsx` | Tạo | Form HTTP_REQUEST chi tiết |
| `src/features/assignments/DbStepForm.tsx` | Tạo | Form DB step |
| `src/features/assignments/ImportModal.tsx` | Tạo | Modal import Postman/OpenAPI |
| `src/features/assignments/SchemaPreview.tsx` | Tạo | Hiển thị JSON Schema |
| `src/features/assignments/useStepBuilder.ts` | Tạo | Hook quản lý state form |
| `src/features/assignments/StepEditor.tsx` | Sửa | Thêm `fallback`, `as`, assertion mới, Faker warnings |
| `src/features/assignments/PlanCard.tsx` | Sửa | Tích hợp `StepBuilderForm` (hoặc tab trong StepEditor) |
| `src/features/assignments/stepConfig.ts` | Sửa | Thêm helper cho extract `fallback`/`as` |
| `src/shared/api/endpoints/schema.ts` | Tạo | Endpoint config-schema |
| `src/shared/types/assignment.ts` | Sửa | Thêm kiểu `DataRow`, `ExtractEntry` (fallback, as), `AutoInjectHeaders` |
| `src/locales/vi.json` | Sửa | Thêm key FE mới |
| `src/locales/en.json` | Sửa | Thêm key FE mới |

---

## 7. Đánh giá rủi ro & lưu ý

| Rủi ro | Mức độ | Giải pháp |
|--------|--------|-----------|
| Form state phức tạp (nhiều Form.List lồng nhau) | Trung bình | Giữ mỗi form component nhỏ, dùng `form.getFieldValue()` cẩn thận, tránh `forceRender`過多 |
| Reverse-map JSON sang form khi edit thất bại (JSON lạ) | Thấp | Dùng `try/catch`, fallback giữ nguyên giá trị cũ, hiển thị cảnh báo |
| Import Postman có nhiều biến môi trường/pre-request script | Trung bình | Chỉ import phần cơ bản (method, path, headers, body), lecturer tự tinh chỉnh assertions/extract |
| JSON Schema backend chưa có | Cao | FE-5.1 phụ thuộc backend expose endpoint; trước đó có thể hardcode schema tạm hoặc bỏ qua tab Schema |
| i18n key lệch giữa vi/en | Thấp | Cập nhật song song 2 file, chạy `npm run i18n:check` |

---

## 8. Definition of Done (FE)

1. Lecturer có thể tạo/sửa step HTTP_REQUEST bằng form, không gõ JSON thô (trừ khi chọn Advanced).
2. Form có các trường mới: `fallback` trong extract, `as` (scalar/json), assertion `array_length`/`contains_item`/`greater_than`/`less_than`/`matches_regex`/`any_of`, `data[]` (tối đa 10 dòng), `auto_inject_headers`.
3. Preview JSON tự động sinh ra và khớp với cấu trúc backend `StepConfigValidator` chấp nhận.
4. Import Postman Collection JSON sinh được danh sách step thô.
5. i18n vi.json + en.json có đầy đủ key mới, `npm run i18n:check` pass.
6. Không xảy ra lỗi TypeScript khi `tsc -b` và `vite build`.

---

## 9. Liên kết với plan backend

File này nằm cùng nhóm với plan backend tại `.opencode/plan/http-config-assertion-advanced/`. Các phase FE này chạy song song hoặc sau các phase backend tương ứng:

- FE-1 (trường extract/assertion mới) đi kèm backend Phase 1.
- FE-2 (form builder độc lập) đi kèm backend Phase 2–3 (VariableContext, `data[]`, `auto_inject_headers`).
- FE-3 (loop + auth inject UI) đi kèm backend Phase 3–4.
- FE-4 (import Postman) độc lập, có thể làm sau backend Phase 3.
- FE-5 (JSON Schema) phụ thuộc backend expose endpoint config-schema (backend Phase 6+ hoặc riêng).

---

## 10. Lệnh kiểm tra FE (khi implement)

```bash
cd frontend-src/web-grading-system-fe
npm run lint          # oxlint
npm run i18n:check    # kiểm tra vi/en đồng key
npx tsc -b            # type check
npm run build         # vite build
```

Kết thúc kế hoạch FE.