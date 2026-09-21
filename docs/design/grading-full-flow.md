# Hướng Dẫn Full Luồng: Tạo Đề Bài Và Chấm Bài Sinh Viên

> **Status:** Canonical user-facing guide for lecturers and developers
> **Scope:** How to create an assignment, configure test steps, and understand how the system grades each submission end-to-end
> **Related:** `http-test-plan-config.md` (technical config schema) · `http-grading-execution-plan.md` (execution plan) · `usecase-flows.md` (use case flows)

---

## Mục Lục

1. [Tổng Quan](#1-tổng-quan)
2. [Vai Trò Của Các Thành Phần](#2-vai-trò-của-các-thành-phần)
3. [Tạo Đề Bài (Assignment)](#3-tạo-đề-bài-assignment)
4. [Cấu Hình Test Plan Và Test Step](#4-cấu-hình-test-plan-và-test-step)
5. [HttpStepExecutor Thực Hiện Step](#5-httpstepexecutor-thực-hiện-step)
6. [AssertionEngine Kiểm Tra Điều Kiện](#6-assertionengine-kiểm-tra-điều-kiện)
7. [Truyền Biến Giữa Các Step (autoInjectExtracts)](#7-truyền-biến-giữa-các-step-autoinjectextracts)
8. [Full Luồng Chấm Bài](#8-full-luồng-chấm-bài)
9. [Ví Dụ Chi Tiết](#9-ví-dụ-chi-tiết)
10. [Các Trường Hợp Đặc Biệt](#10-các-trường-hợp-đặc-biệt)
11. [Bảng Tóm Tắt](#11-bảng-tóm-tắt)

---

## 1. Tổng Quan

Hệ thống chấm bài hoạt động theo mô hình **event-driven** (điều khiển bởi Kafka). Khi sinh viên nộp bài, hệ thống tự động:

```
[Sinh viên nộp bài]
        ↓
[Kafka: GRADE_SUBMISSION event]
        ↓
[GradeSubmissionHandler: lưu PENDING job]
        ↓
[GradingOrchestrator: chạy async]
        ↓
[Lấy config → Tải artifact → Boot app → Chấm từng bước → Tính điểm → Báo kết quả]
```

Mỗi "bài toán" (assignment) được giảng viên tạo trên course-service, bao gồm:

- **Docker Compose template**: định nghĩa app sinh viên cần boot (ví dụ: một app Spring Boot có API để kiểm tra)
- **Test Plans**: một hoặc nhiều kế hoạch chấm, mỗi plan gồm nhiều **Steps**
- **Steps**: mỗi step là một HTTP request (GET, POST, PUT, DELETE...) tới app sinh viên

---

## 2. Vai Trò Của Các Thành Phần

| Thành phần | Nằm trong | Vai trò |
|-------------|------------|---------|
| **course-service** | Microservice | Lưu assignment, test plans, test steps. Cung cấp config cho executor |
| **executor-service** | Microservice | Thực thi grading: boot app, chạy steps, chấm điểm, báo kết quả |
| **result-service** | Microservice | Lưu kết quả chấm cuối cùng |
| **submission-service** | Microservice | Cập nhật trạng thái submission |
| **GradeSubmissionHandler** | executor-service | Nhận Kafka event, tạo job PENDING, gọi gradeAsync |
| **GradingOrchestrator** | executor-service | Orchestrator chính: điều phối toàn bộ flow |
| **HttpStepExecutor** | executor-service | Thực thi HTTP request, extract biến, validate status |
| **AssertionEngine** | executor-service | Kiểm tra response đúng như kỳ vọng không |
| **DockerComposeRunner** | executor-service | Boot app sinh viên via Testcontainers |
| **ArtifactService** | executor-service | Tải code sinh viên, kiểm tra wrapper |
| **PortAllocator** | executor-service | Cấp port cho app sinh viên (20000-30000) |
| **SagaTracker** | executor-service | Theo dõi các bước đã thực hiện |
| **StaleJobReaper** | executor-service | Recovery job bị stuck |
| **ScoreCalculator** | executor-service | Tính điểm |

---

## 3. Tạo Đề Bài (Assignment)

### 3.1 Bước 1: Giảng Viên Tạo Assignment Trên course-service

Assignment là "đề bài" bao gồm:

| Thuộc tính | Mô tả | Ví dụ |
|------------|--------|--------|
| `title` | Tên đề bài | "Bài tập quản lý sách" |
| `description` | Mô tả yêu cầu | "Tạo và quản lý sách trong hệ thống" |
| `dockerComposeTemplate` | Docker Compose template | (xem bên dưới) |
| `gradingStrategy` | Chiến lược chấm | `STUDENT_DOCKER_COMPOSE` (sinh viên cung cấp app) |
| `startupTimeoutMs` | Thời gian chờ app boot | 10000 (10 giây) |
| `executionTimeoutMs` | Thời gian tối đa chấm | 60000 (60 giây) |
| `plans` | Danh sách kế hoạch chấm | (xem bên dưới) |

### 3.2 Docker Compose Template

Template mô tả app sinh viên cần boot. Đây là app mà sinh viên viết code, và executor-service sẽ boot nó để kiểm tra.

```yaml
services:
  app:
    image: student-book-api:latest
    ports:
      - "8080:8080"
    environment:
      - SPRING_PROFILES_ACTIVE=test
```

**Lưu ý:**
- `app` là tên service chính (first service with ports → được xác định là app)
- Port 8080 là port mặc định mà executor-service sẽ map
- Executor-service sẽ tự động patch template này (thêm resource limits, port mapping) trước khi boot

### 3.3 Tạo Test Plan

Test Plan là nhóm các bước chấm. Mỗi assignment có thể có nhiều plan, nhưng thường chỉ có 1 plan.

Ví dụ: Plan "grade-books" với 6 steps để kiểm tra CRUD sách.

### 3.4 Tạo Test Steps

Mỗi step là một HTTP request. Cấu hình step bằng JSON (xem phần 4 chi tiết).

---

## 4. Cấu Hình Test Plan Và Test Step

### 4.1 Test Plan

```json
{
  "id": "plan-uuid",
  "name": "grade-books",
  "sequenceOrder": 1,
  "weight": 1,
  "steps": [
    { "method": "POST", "path": "/api/v1/books", "expected_status": 201 },
    { "method": "GET", "path": "/api/v1/books", "expected_status": 200 }
  ]
}
```

| Trường | Mô tả |
|--------|--------|
| `id` | UUID của plan |
| `name` | Tên plan (cho người đọc) |
| `sequenceOrder` | Thứ tự chạy (nếu có nhiều plan) |
| `weight` | Trọng số plan trong scoring |
| `steps` | Danh sách các bước |

### 4.2 Test Step — Tất Cả Các Trường Cấu Hình

```json
{
  "method": "POST",
  "path": "/api/v1/books",
  "expected_status": 201,
  "extract": [
    { "name": "bookId", "from": "response_body", "expression": "$.id" }
  ],
  "assertions": [
    { "kind": "STATUS", "equals": 201 },
    { "kind": "JSON_PATH", "path": "$.id", "exists": true },
    { "kind": "CONTAINS", "text": "Test Book" }
  ],
  "required": true,
  "timeoutMs": 5000
}
```

#### 4.2.1 `method` — HTTP Method (Bắt buộc)

| Giá trị | Khi nào dùng | Ví dụ |
|---------|---------------|--------|
| `GET` | Lấy dữ liệu | `/api/v1/books`, `/api/v1/books/${id}` |
| `POST` | Tạo mới | `/api/v1/books` |
| `PUT` | Cập nhật toàn bộ | `/api/v1/books/${id}` |
| `PATCH` | Cập nhật một phần | `/api/v1/books/${id}` |
| `DELETE` | Xóa | `/api/v1/books/${id}` |

#### 4.2.2 `path` — Đường Dẫn URL (Bắt buộc)

- Đường dẫn bắt đầu bằng `/`
- Có thể chứa biến `${tên_biến}`
- Biến được thay thế bằng giá trị từ `VariableContext` (trích xuất từ bước trước)

**Ví dụ:**
```json
// Không có biến
{ "path": "/api/v1/books" }

// Có biến (cần extract từ bước trước)
{ "path": "/api/v1/books/${bookId}" }

// Nhiều biến
{ "path": "/api/v1/books/${bookId}/reviews/${reviewId}" }
```

#### 4.2.3 `expected_status` — HTTP Status Mong Đợi (Khuyến khích)

| Giá trị | Ý nghĩa | Khi nào |
|---------|----------|----------|
| 200 | OK | Lấy dữ liệu thành công |
| 201 | Created | Tạo mới thành công |
| 204 | No Content | Xóa thành công |
| 400 | Bad Request | Dữ liệu không hợp lệ |
| 404 | Not Found | Không tìm thấy tài nguyên |

#### 4.2.4 `extract` — Trích Xuất Biến (Tùy chọn)

Trích xuất giá trị từ response body để dùng ở các bước sau.

```json
{
  "name": "bookId",
  "from": "response_body",
  "expression": "$.id"
}
```

| Trường | Mô tả |
|--------|--------|
| `name` | Tên biến (dùng trong `${tên_biến}`) |
| `from` | Nguồn dữ liệu (mặc định: `response_body`) |
| `expression` | JsonPath để trích xuất giá trị |

**Các dạng JsonPath:**

| Expression | Ý nghĩa | Ví dụ Response | Kết quả |
|------------|----------|----------------|----------|
| `$.id` | Trường id ở root | `{"id":"abc"}` | "abc" |
| `$.name` | Trường name ở root | `{"name":"John"}` | "John" |
| `$.data.id` | Trường lồng nhau | `{"data":{"id":"1"}}` | "1" |
| `$.items[0].id` | Phần tử mảng | `{"items":[{"id":"a"}]}` | "a" |
| `$..id` | Đệ quy tất cả id | `{"a":{"id":"1"}}` | ["1"] |

#### 4.2.5 `assertions` — Điều Kiện Kiểm Tra (Tùy chọn)

Danh sách các điều kiện. Tất cả phải PASS thì step mới PASS. Xem [phần 6](#6-assertionengine-kiểm-tra-điều-kiện) để biết chi tiết từng loại.

#### 4.2.6 `required` — Bắt Buộc (Tùy chọn, mặc định false)

| Giá trị | Ý nghĩa |
|---------|----------|
| `true` | Nếu step FAIL → plan DỪNG → bước sau = SKIPPED |
| `false` | Nếu step FAIL → plan TIẾP TỤC → bước sau vẫn chạy |

#### 4.2.7 `timeoutMs` — Thời Gian Timeout (Tùy chọn)

- Thời gian tối đa cho HTTP request (ms)
- Mặc định: lấy từ cấu hình toàn cục

---

## 5. HttpStepExecutor Thực Hiện Step

### 5.1 Vai Trò

`HttpStepExecutor` là nơi thực sự gửi HTTP request tới app sinh viên và phân tích response. Được đăng ký là `@Component`, được `StepRegistry` quản lý.

### 5.2 Đầu Vào

Mỗi step được đóng gói trong `StepContext`:

```java
record StepContext(
    UUID jobId,          // ID của grading job
    UUID planId,         // ID của plan hiện tại
    UUID stepId,         // ID của step
    int stepOrder,       // Thứ tự bước trong plan
    String stepName,     // Tên bước
    JsonNode config,     // Cấu hình JSON của step
    VariableContext vars, // Biến từ các bước trước
    long timeoutMs       // Thời gian timeout
)
```

### 5.3 Quy Trình Thực Hiện

```
execute(StepContext ctx)
    │
    ├── 1. Parse config JSON
    │      ├── method: GET, POST, PUT, PATCH, DELETE
    │      ├── path: URL path (có thể chứa ${varName})
    │      ├── expected_status: HTTP status mong đợi
    │      ├── extract: danh sách biến cần trích xuất
    │      └── assertions: danh sách điều kiện kiểm tra
    │
    ├── 2. Substitute variables in path
    │      Thay thế ${varName} bằng giá trị từ VariableContext
    │      Ví dụ: /api/books/${bookId} → /api/books/abc-123
    │
    ├── 3. Send HTTP request
    │      Dùng java.net.http.HttpClient
    │
    ├── 4. Receive response
    │      ├── status code
    │      ├── response body (JSON string)
    │      └── response headers
    │
    ├── 5. Validate expected_status
    │      Nếu actual != expected → FAILED
    │
    ├── 6. Evaluate assertions
    │      Gọi AssertionEngine.evaluateHttp()
    │
    ├── 7. Extract variables
    │      Từ response body theo cấu hình extract
    │      Lưu vào VariableContext (per-job)
    │
    └── 8. Return GradingStepResult
           status: PASSED / FAILED / ERROR
           actualStatusCode, assertionResults
           extractedVariables, requestUrl, responseBody
```

### 5.4 Ví Dụ Thực Hiện

**Step config:**
```json
{
  "method": "POST",
  "path": "/api/v1/books",
  "expected_status": 201,
  "extract": [
    { "name": "bookId", "from": "response_body", "expression": "$.id" }
  ]
}
```

**Response từ app sinh viên:**
```json
{"id": "abc-123", "title": "Test Book"}
```

**HttpStepExecutor thực hiện:**
1. Thay biến trong path (không có → giữ nguyên `/api/v1/books`)
2. Gửi POST `/api/v1/books`
3. Nhận response: status=201, body=`{"id":"abc-123","title":"Test Book"}`
4. Kiểm tra expected_status=201 → 201==201 → **PASS**
5. Trích xuất: `$.id` → `"abc-123"` → lưu `vars.put("bookId", "abc-123")`
6. Kết quả: **PASSED**

---

## 6. AssertionEngine Kiểm Tra Điều Kiện

### 6.1 Vai Trò

Kiểm tra response từ app sinh viên có đúng như kỳ vọng không. So sánh response thực tế với các điều kiện được định nghĩa trong step config.

### 6.2 Các Loại Assertion

#### 6.2.1 STATUS — So Sánh HTTP Status Code

**Config:**
```json
{ "kind": "STATUS", "equals": 200 }
```

**Logic:** So sánh `actualStatus == expectedStatus`

| Response | Expected | Kết quả | Message |
|----------|----------|---------|---------|
| 200 | 200 | ✅ PASS | "Status matched" |
| 404 | 200 | ❌ FAIL | "Expected status 200 but got 404" |
| 201 | 201 | ✅ PASS | "Status matched" |
| 500 | 200 | ❌ FAIL | "Expected status 200 but got 500" |

**Các status hay dùng:**
- 200 OK — Lấy dữ liệu thành công
- 201 Created — Tạo mới thành công
- 204 No Content — Xóa thành công
- 400 Bad Request — Dữ liệu không hợp lệ
- 404 Not Found — Không tìm thấy tài nguyên

#### 6.2.2 CONTAINS — Kiểm Tra Substring Trong Body

**Config:**
```json
{ "kind": "CONTAINS", "text": "Test Book" }
```

**Logic:** Kiểm tra `actualBody.contains(text)` (phân biệt chữ hoa/thường)

| Response Body | Text | Kết quả |
|---------------|------|---------|
| `{"title":"Test Book","id":"1"}` | "Test Book" | ✅ PASS |
| `{"title":"Other Book"}` | "Test Book" | ❌ FAIL |
| `{"title":"Hello World"}` | "world" | ❌ FAIL (case-sensitive) |

**Dùng khi:** Kiểm tra tên, message, hoặc bất kỳ chuỗi nào trong response.

#### 6.2.3 JSON_PATH — Kiểm Tra Sự Tồn Tại Của Trường

**Config:**
```json
{ "kind": "JSON_PATH", "path": "$.id", "exists": true }
```

**Logic:** Dùng JsonPath để đọc path từ response body. Kiểm tra kết quả có tồn tại (không null và không rỗng).

| Response | Path | Exists | Kết quả |
|----------|------|--------|---------|
| `{"id":"abc","title":"Test"}` | `$.id` | true | ✅ PASS |
| `{"title":"Test"}` | `$.id` | true | ❌ FAIL |
| `{"title":"Test"}` | `$.id` | false | ✅ PASS |
| `{"error":"bad"}` | `$.error` | false | ❌ FAIL |

**Các dạng path:**

| Path | Ý nghĩa | Ví dụ |
|------|----------|-------|
| `$.id` | Trường ở root | `$.id` → "abc" |
| `$.author.name` | Trường lồng nhau | `$.author.name` → "A" |
| `$..id` | Đệ quy tất cả | Tìm tất cả trường `id` |
| `$.items[0]` | Phần tử mảng | `$.items[0]` → first item |
| `$.items[*]` | Tất cả phần tử | `$.items[*]` → all items |

**Dùng khi:**
- Kiểm tra response có trường bắt buộc không (`exists: true`)
- Kiểm tra response KHÔNG có trường lỗi (`exists: false`)

#### 6.2.4 BODY_EQUALS — So Sánh Toàn Bộ Response Body

**Config:**
```json
{ "kind": "BODY_EQUALS", "json": { "id": "abc-123", "title": "Test Book" } }
```

**Logic:** So sánh JSON response thực tế với JSON kỳ vọng (so sánh content, không so sánh thứ tự field).

| Response Body | Expected | Kết quả |
|---------------|----------|---------|
| `{"title":"Test Book","id":"abc-123"}` | `{"id":"abc-123","title":"Test Book"}` | ✅ PASS (khác thứ tự vẫn bằng) |
| `{"id":"abc-123"}` | `{"id":"abc-123","title":"Test"}` | ❌ FAIL (thiếu title) |
| `{"id":"abc-456"}` | `{"id":"abc-123"}` | ❌ FAIL (khác giá trị) |

**Lưu ý:** So sánh nội dung, không thứ tự field. Giá trị phải khớp chính xác.

#### 6.2.5 BODY_STRUCTURE — So Sánh Cấu Trúc Response Body

**Config:**
```json
{ "kind": "BODY_STRUCTURE", "json": { "id": "", "title": "" } }
```

**Logic:** So sánh cấu trúc JSON (có những trường nào), **không so sánh giá trị**. Dùng `GsonStructureComparator`.

| Response Body | Expected Structure | Kết quả |
|---------------|-------------------|---------|
| `{"id":"abc","title":"Test","extra":"x"}` | `{"id":"","title":""}` | ✅ PASS (có id + title) |
| `{"id":"abc","title":"Test"}` | `{"id":"","title":""}` | ✅ PASS |
| `{"id":"abc"}` | `{"id":"","title":""}` | ❌ FAIL (thiếu title) |

**Dùng khi:** Chỉ kiểm tra response có những trường cần thiết, không quan tâm giá trị (ví dụ: giá trị thay đổi theo thời gian).

#### 6.2.6 FIELD_EQUALS — Kiểm Tra 1 Trường = Giá Trị Kỳ Vọng

**Config:**
```json
{ "kind": "FIELD_EQUALS", "path": "$.id", "equals": "${book1Id}" }
```

**Logic:**
1. Đọc giá trị tại JsonPath `path` từ response body
2. Thay thế `${var}` trong `equals` bằng giá trị từ `VariableContext`
3. So sánh `actual == expected` (chuỗi)

| Response Body | Config | Kết quả |
|---------------|--------|---------|
| `{"id":"abc1","title":"Sach A"}` | `equals: "${book1Id}"` (book1Id="abc1") | ✅ PASS |
| `{"id":"abc1","title":"Sach A"}` | `equals: "${book1Id}"` (book1Id="abc2") | ❌ FAIL |
| `{"title":"Sach A"}` | `path: "$.id"` | ❌ FAIL (path không tồn tại) |

**Dùng khi:** Kiểm tra 1 field có đúng giá trị kỳ vọng (không hardcode). Kết hợp với `autoInjectExtracts` để truyền biến giữa các steps.

**Anti-hardcode:** Luôn dùng `${var}` trong `equals`, KHÔNG dùng literal như `"abc1"`.

### 6.3 Đa Dạng Assertion Trong Một Step

Một step có thể có nhiều assertion, tất cả phải PASS:

```json
{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200,
  "assertions": [
    { "kind": "STATUS", "equals": 200 },
    { "kind": "JSON_PATH", "path": "$.id", "exists": true },
    { "kind": "JSON_PATH", "path": "$.title", "exists": true },
    { "kind": "CONTAINS", "text": "Test Book" }
  ]
}
```

### 6.4 Kết Quả Assertion

| Kết quả | Khi nào |
|---------|----------|
| **PASSED** | Tất cả assertion đúng (status code + assertion-level) |
| **FAILED** | Có ít nhất 1 assertion sai (HTTP-level check hoặc assertion-level check) |
| **ERROR** | Có lỗi xảy ra khi thực thi HTTP request (network error, timeout) |

---

## 7. Truyền Biến Giữa Các Step (autoInjectExtracts)

### 7.1 Vấn Đề

Bước 1 tạo một resource (POST → trả về `id`). Bước 2 cần dùng `id` đó (GET `/resource/${id}`). Làm sao để truyền biến giữa các bước?

### 7.2 Giải Pháp

`autoInjectExtracts` tự động thêm `extract` entries vào bước trước đó, dựa trên các biến `${...}` được tìm thấy trong bước sau.

### 7.3 Thuật Toán

```
Với mỗi step (từ cuối về đầu, trừ step đầu tiên):
  1. Tìm tất cả ${tênBiến} trong config của step hiện tại
  2. Với mỗi biến tìm được:
     a. Kiểm tra bước trước đó đã extract biến đó chưa
     b. Nếu chưa → THÊM extract entry vào bước trước đó:
        { "name": "tênBiến", "from": "response_body", "expression": "$." + tênBiến }
```

### 7.4 Ví Dụ

**Trước autoInjectExtracts:**

| Step | Config |
|------|--------|
| Step 1 | `{"method":"POST","path":"/api/books"}` |
| Step 2 | `{"method":"GET","path":"/api/books/${bookId}"}` |
| Step 3 | `{"method":"GET","path":"/api/books/${bookId}/reviews"}` |

**Sau autoInjectExtracts:**

| Step | Config |
|------|--------|
| Step 1 | `{"method":"POST","path":"/api/books","extract":[{"name":"bookId","from":"response_body","expression":"$.bookId"}]}` |
| Step 2 | `{"method":"GET","path":"/api/books/${bookId}"}` |
| Step 3 | `{"method":"GET","path":"/api/books/${bookId}/reviews"}` |

**Lưu ý quan trọng:**
- Chỉ inject khi biến **chưa được extract** (tránh trùng lặp)
- Bước đầu tiên (step 1) **không bị xử lý như "current step"** (chỉ là "previous step")
- Biến được lưu trong `VariableContext` — một object **per-job** (mỗi job có 1)

---

## 8. Full Luồng Chấm Bài

### 8.1 Sơ Đồ

```
[Sinh viên nộp bài]
        ↓
[Kafka: GRADE_SUBMISSION event]
        ↓
[GradeSubmissionHandler.handle()]
   ├── Persist grading_job (status=PENDING)
   ├── Nếu duplicate + FAILED → ResetGradingJobService.reset()
   └── Call GradingOrchestrator.gradeAsync() [@Async]
        ↓
[GradingOrchestrator.gradeAsync()]
   ├── Try-catch bao bọc toàn bộ
   └── Gọi grade()
        ↓
[grade(jobId, ...)]
   ├── 1. Load GradingJob từ DB
   ├── 2. Fetch grading config từ course-service
   │      (AssignmentGradingConfigDto: strategy, ports, timeouts)
   ├── 3. Fetch plans từ course-service
   │      (List<InternalPlanDto>)
   ├── 4. Download artifact từ RustFS (ZIP)
   │      (ArtifactService.fetchWorkDir)
   │      - Restore wrapper executable bit
   │      - Patch wrapper distribution URL
   ├── 5. Boot student app (DockerComposeRunner.boot)
   │      - DockerComposePatcher.patchCompose()
   │      - PortAllocator.claim() (20000-30000)
   │      - Testcontainers ComposeContainer
   │      - Docker sidecar (docker:27-dind)
   ├── 6. Với mỗi plan:
   │      ├── autoInjectExtracts(steps) ← truyền biến giữa steps
   │      ├── Với mỗi step:
   │      │   ├── HttpStepExecutor.execute()
   │      │   │   ├── Thay biến trong path
   │      │   │   ├── Gửi HTTP request
   │      │   │   ├── Kiểm tra status
   │      │   │   ├── AssertionEngine.evaluateHttp()
   │      │   │   ├── Extract biến → VariableContext
   │      │   │   └── Return GradingStepResult
   │      │   ├── SagaTracker.step() ← theo dõi tiến trình
   │      │   └── Persist kết quả vào DB
   │      └── ScoreCalculator.calculate()
   │         ├── score = (passedWeight / ranWeight) * 10.00
   │         └── Summary: "Passed X/Y steps (P%, Score: S/10.00)"
   ├── 7. Save grading_job (DONE/FAILED + completedAt)
   ├── 8. POST /api/v1/internal/results → result-service
   │      (retry với backoff, skip 4xx ngoại 408/429)
   └── 9. PUT /api/v1/internal/submissions/{id}/status → submission-service
```

### 8.2 Chi Tiết Từng Giai Đoạn

#### Giai Đoạn 1: Receive & Persist
- Event `GRADE_SUBMISSION` từ Kafka → `GradeSubmissionHandler.handle()`
- Tạo `GradingJob` với status=PENDING
- Unique constraint trên `submission_id` = idempotency backstop
- Gọi `gradeAsync()` (async)

#### Giai Đoạn 2: Fetch Config
- `courseInternalClient.gradingConfig(assignmentId)` → `AssignmentGradingConfigDto`
- Cung cấp: `gradingStrategy`, `dockerComposePort`, `startupTimeoutMs`, `executionTimeoutMs`, `maxCpu`, `maxMemoryMb`

#### Giai Đoạn 3: Fetch Plans
- `courseInternalClient.plans(assignmentId)` → `List<InternalPlanDto>`
- Nếu `planId` khác null → chỉ plan có ID khớp mới chạy

#### Giai Đoạn 4: Download Artifact
- `ArtifactService.fetchWorkDir(submissionId, rustfsPath)` tải ZIP từ RustFS
- `restoreWrapperPermissions()` → chmod +x cho `mvnw`/`gradlew`
- `patchWrapperDistributionUrl()` → rewrite URL nếu cần

#### Giai Đoạn 5: Boot Student App
- `DockerComposePatcher.patchCompose()`:
  - Rewrite ports: `<allocated>:<dockerComposePort|8080>`
  - Inject resource limits
  - Validate: `privileged:true` và `docker.sock` → REJECT
- `DockerComposeRunner.boot()`:
  - Testcontainers `ComposeContainer` với `DOCKER_HOST=tcp://localhost:2375` (DinD sidecar)
  - `TESTCONTAINERS_RYUK_DISABLED=true` (Ryuk không chạy được trong pod)
- `PortAllocator.claim()` → cấp port từ 20000-30000

#### Giai Đoạn 6: Execute Steps

**6a. AutoInjectExtracts** (dòng 226 trong `grade()`):
- Tự động thêm extract entries khi bước sau cần biến từ bước trước

**6b. Thực thi từng bước:**
- `HttpStepExecutor.execute()`:
  1. Parse config JSON
  2. Thay `${varName}` trong path bằng giá trị từ VariableContext
  3. Gửi HTTP request
  4. Nhận response (status, body, headers)
  5. Validate expected_status
   6. `AssertionEngine.evaluateHttp()`: kiểm tra STATUS, CONTAINS, JSON_PATH, BODY_EQUALS, BODY_STRUCTURE, FIELD_EQUALS
  7. Extract biến từ response → VariableContext
  8. Return GradingStepResult (PASSED/FAILED/ERROR)

**6c. Per-step persistence:**
- `SagaTracker.step()` → ghi bước vào `grading_saga_steps`
- `stepResultRepository.save()` → ghi kết quả vào `grading_step_results`

**6d. Scoring:**
- `ScoreCalculator.calculate()`: `score = (passedWeight / ranWeight) * 10.00`
- SKIPPED không tính cả 2 phía
- HALF_UP, 2 decimals

#### Giai Đoạn 7: Finalize Job
- `gradingJobRepository.save(job)` → status=DONE/FAILED, completedAt, errorMessage
- **Trước** khi gọi downstream (đảm bảo job đã hoàn tất)

#### Giai Đoạn 8: Report Results
- `POST /api/v1/internal/results` → result-service
  - Retry với backoff tuyến tính (`attempt * 2000L` ms)
  - Skip retry trên `FeignException 4xx` (trừ 408/429)
- `PUT /api/v1/internal/submissions/{id}/status` → submission-service (defensive, try/catch + warn)

### 8.3 Crash Recovery

`StaleJobReaper` (`@Scheduled`, mỗi 5 phút):
- Tìm job ở trạng thái `PENDING`/`FETCHING`/`BUILDING`
- Nếu `startedAt` cũ hơn `staleAfterMinutes` (mặc định 30)
- Và `retryCount < maxAttempts` (mặc định 3)
- Gọi `gradeAsync()` để retry
- **RUNNING không được reap** (tránh double grading)

---

## 9. Ví Dụ Chi Tiết

### 9.1 Đề Bài: Quản Lý Sách

**Assignment:**
- Title: "Bài tập quản lý sách"
- Description: "Tạo và quản lý sách trong hệ thống"
- Grading Strategy: STUDENT_DOCKER_COMPOSE

### 9.2 Docker Compose Template

```yaml
services:
  app:
    image: student-book-api:latest
    ports:
      - "8080:8080"
    environment:
      - SPRING_PROFILES_ACTIVE=test
```

### 9.3 Plan: "grade-books" (6 steps)

#### Step 1: Tạo sách mới (POST)
```json
{
  "method": "POST",
  "path": "/api/v1/books",
  "expected_status": 201,
  "extract": [
    { "name": "bookId", "from": "response_body", "expression": "$.id" }
  ],
  "assertions": [
    { "kind": "STATUS", "equals": 201 },
    { "kind": "JSON_PATH", "path": "$.id", "exists": true },
    { "kind": "JSON_PATH", "path": "$.title", "exists": true }
  ],
  "required": true
}
```
**Mục đích:** Tạo sách mới, lấy ID để dùng cho các bước sau

#### Step 2: Lấy sách theo ID (GET)
```json
{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200,
  "assertions": [
    { "kind": "STATUS", "equals": 200 },
    { "kind": "BODY_STRUCTURE", "json": { "id": "", "title": "" } }
  ]
}
```
**Mục đích:** Kiểm tra sách có trong DB, cấu trúc đúng

#### Step 3: Lấy danh sách sách (GET)
```json
{
  "method": "GET",
  "path": "/api/v1/books",
  "expected_status": 200,
  "assertions": [
    { "kind": "STATUS", "equals": 200 },
    { "kind": "JSON_PATH", "path": "$", "exists": true },
    { "kind": "CONTAINS", "text": "books" }
  ]
}
```
**Mục đích:** Kiểm tra endpoint list hoạt động

#### Step 4: Cập nhật sách (PATCH)
```json
{
  "method": "PATCH",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200,
  "assertions": [
    { "kind": "STATUS", "equals": 200 }
  ]
}
```

#### Step 5: Xóa sách (DELETE)
```json
{
  "method": "DELETE",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 204,
  "assertions": [
    { "kind": "STATUS", "equals": 204 }
  ],
  "required": true
}
```

#### Step 6: Kiểm tra sách đã xóa (GET)
```json
{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 404,
  "assertions": [
    { "kind": "STATUS", "equals": 404 }
  ]
}
```
**Mục đích:** Kiểm tra xóa thành công (404 khi lấy lại)

### 9.4 Flow Khi Chấm

```
Step 1: POST /api/v1/books → 201 → extract bookId="abc-123" → PASSED ✓
Step 2: GET /api/v1/books/abc-123 → 200 → cấu trúc đúng → PASSED ✓
Step 3: GET /api/v1/books → 200 → có sách trong list → PASSED ✓
Step 4: PATCH /api/v1/books/abc-123 → 200 → PASSED ✓
Step 5: DELETE /api/v1/books/abc-123 → 204 → PASSED ✓
Step 6: GET /api/v1/books/abc-123 → 404 → PASSED ✓

Score: 6/6 passed, ranWeight=6, passedWeight=6
→ Score = (6/6) × 10 = 10.00/10.00
```

### 9.5 Khi Sinh Viên Nộp Sai

Nếu Step 2 trả về 404 (không tìm thấy sách):
- `expected_status` = 200, `actual_status` = 404
- STATUS assertion: **FAIL**
- Step 2: **FAILED**
- Nếu step 2 `required=true`: plan dừng, bước 3-6 = SKIPPED
- Score: (2/3) × 10 = 6.67/10.00 (bước 1,2 pass, bước 3 FAIL)

---

## 10. Các Trường Hợp Đặc Biệt

### 10.1 Duplicate Submission

Khi cùng 1 `submissionId` được gửi 2 lần:
1. Lần 1: Tạo PENDING → gradeAsync() → DONE
2. Lần 2: **DataIntegrityViolation** (unique constraint)
3. Handler kiểm tra: job tồn tại + status = FAILED?
   - Nếu FAILED → reset → re-grade
   - Nếu không → log duplicate, bỏ qua

### 10.2 Pool Saturated

Khi `gradingTaskExecutor` (corePoolSize=1, queueCapacity=10) đã đầy:
- `GradeSubmissionHandler` bắt `TaskRejectedException`
- Job giữ nguyên trạng thái PENDING
- `StaleJobReaper` sẽ retry sau 30 phút

### 10.3 Pool Saturated

Khi `gradingTaskExecutor` (corePoolSize=1, queueCapacity=10) đã đầy:
- `GradeSubmissionHandler` bắt `TaskRejectedException`
- Job giữ nguyên trạng thái PENDING
- `StaleJobReaper` sẽ retry sau 30 phút

### 10.4 HTTP Error (Connection Failed)

Khi app sinh viên không chạy:
- Result: **ERROR**
- ErrorMessage: "Connection refused" (hoặc timeout message)
- Log: `httpLogService.save()` được gọi

### 10.5 RUNNING Job Not Reaped

Pod chết khi job đang RUNNING:
- `StaleJobReaper` **không** re-enqueue RUNNING jobs
- Phải reset thủ công qua `ResetGradingJobService`
- Lý do: wall-clock không thể phân biệt job đang chạy vs dead job

---

## 11. Bảng Tóm Tắt

### 11.1 Các Loại Assertion

| Kind | Kiểm tra | Cấu hình |
|------|----------|----------|
| STATUS | HTTP status code | `{ "kind": "STATUS", "equals": 200 }` |
| CONTAINS | Substring trong body | `{ "kind": "CONTAINS", "text": "hello" }` |
| JSON_PATH | Trường tồn tại trong JSON | `{ "kind": "JSON_PATH", "path": "$.id", "exists": true }` |
| BODY_EQUALS | Toàn bộ body bằng nhau | `{ "kind": "BODY_EQUALS", "json": { "id": "abc" } }` |
| BODY_STRUCTURE | Cấu trúc body (không giá trị) | `{ "kind": "BODY_STRUCTURE", "json": { "id": "" } }` |
| FIELD_EQUALS | 1 field = giá trị kỳ vọng | `{ "kind": "FIELD_EQUALS", "path": "$.id", "equals": "${bookId}" }` |

### 11.2 Các Loại HTTP Method

| Method | Dùng khi | Expected Status |
|--------|----------|-----------------|
| GET | Lấy dữ liệu | 200 |
| POST | Tạo mới | 201 |
| PUT | Cập nhật toàn bộ | 200 |
| PATCH | Cập nhật một phần | 200 |
| DELETE | Xóa | 204 |

### 11.3 Các Kết Quả Step

| Status | Khi nào |
|--------|----------|
| PASSED | Tất cả assertion đúng, HTTP request thành công |
| FAILED | Có assertion sai (status code hoặc assertion-level) |
| ERROR | Có lỗi xảy ra (network error, timeout, parse error) |
| SKIPPED | Bước bị bỏ qua do bước required trước đó FAIL |

### 11.4 Các Trường Hợp Đặc Biệt Của Step

| Trường hợp | Cấu hình | Ý nghĩa |
|------------|----------|----------|
| Bắt buộc | `"required": true` | FAIL → plan dừng, bước sau SKIPPED |
| Không bắt buộc | `"required": false` | FAIL → plan tiếp tục |
| Timeout | `"timeoutMs": 5000` | Request chạy quá 5s → ERROR |
| Có extract | `"extract": [...]` | Trích biến từ response |
| Không có assertion | `"assertions": []` | Chỉ kiểm tra status (nếu có expected_status) |
