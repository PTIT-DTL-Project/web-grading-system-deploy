# Phụ Lục Cấu Hình Toàn Diện: Tất Cả Tùy Chọn Trong Hệ Thống Chấm Bài

> **Status:** Canonical reference for every configurable option in the grading pipeline
> **Scope:** Assignment config, test plan config, test step config, assertion config, extract config, executor service properties, HTTP client config, scoring config, deployment config
> **Audience:** Lecturers configuring assignments, developers modifying grading engine, DevOps deploying services
> **Related:** `grading-full-flow.md` (full flow explanation) · `http-test-plan-config.md` (technical schema) · `http-grading-execution-plan.md` (execution details)

---

## Mục Lục

1. [Assignment-Level Config](#1-assignment-level-config)
2. [Test Plan Config](#2-test-plan-config)
3. [Test Step Config](#3-test-step-config)
4. [Assertion Config](#4-assertion-config)
5. [Extract Config](#5-extract-config)
6. [GraderConfig DTO (Internal)](#6-graderconfig-dto-internal)
7. [Executor Service Properties](#7-executor-service-properties)
8. [HTTP Client Config](#8-http-client-config)
9. [Variable Resolution](#9-variable-resolution)
10. [Scoring Formula](#10-scoring-formula)
11. [Deployment Config](#11-deployment-config)
12. [Docker Compose Template](#12-docker-compose-template)
13. [Bảng Tổng Hợp](#13-bảng-tổng-hợp)

---

## 1. Assignment-Level Config

Cấu hình ở cấp **Assignment** — do giảng viên thiết lập khi tạo đề bài.

### 1.1 Các Trường Của Assignment

| Trường | Kiểu | Bắt buộc | Mô tả | Ví dụ |
|--------|------|----------|--------|-------|
| `title` | String | ✅ | Tên đề bài hiển thị cho giảng viên và SV | `"Bài tập quản lý sách"` |
| `description` | String | ❌ | Mô tả chi tiết yêu cầu | `"Tạo CRUD sách với REST API"` |
| `graderConfig` | GraderConfig | ✅ | Cấu hình chấm (xem mục 6) | (xem bên dưới) |
| `plans` | List\<Plan\> | ✅ | Danh sách kế hoạch chấm | (xem mục 2) |

### 1.2 Các Loại Grading Strategy

| Strategy | Mô tả | Docker Compose |
|----------|--------|----------------|
| `STUDENT_DOCKER_COMPOSE` | Sinh viên cung cấp app qua Docker Compose | Cần dockerComposeTemplate |
| (Future: `INLINE_CODE`) | Sinh viên nộp code, executor build & run | Không cần template |

---

## 2. Test Plan Config

Plan là nhóm các bước chấm, có trọng số trong scoring.

### 2.1 Các Trường Của Plan

| Trường | Kiểu | Bắt buộc | Mặc định | Mô tả | Ví dụ |
|--------|------|----------|----------|--------|-------|
| `id` | UUID | ✅ | — | Định danh duy nhất của plan | `"550e8400-e29b-41d4-a716-446655440000"` |
| `name` | String | ✅ | — | Tên plan (cho người đọc) | `"grade-books"` |
| `description` | String | ❌ | `""` | Mô tả plan | `"Kiểm tra CRUD sách"` |
| `sequenceOrder` | int | ✅ | — | Thứ tự chạy (nếu nhiều plan) | `1` |
| `weight` | int | ✅ | `1` | Trọng số plan trong tính điểm | `1` |
| `steps` | List\<Step\> | ✅ | — | Danh sách các bước | (xem mục 3) |

### 2.2 Kế Hoạch Chấm Nhiều Plan

Khi 1 assignment có nhiều plan, các plan chạy theo `sequenceOrder`. Plan đầu tiên FAIL → plan sau KHÔNG chạy.

```
Plan 1 (sequenceOrder=1, weight=1): 6 steps → PASSED
Plan 2 (sequenceOrder=2, weight=1): 4 steps → NOT RUN (vì plan 1 đã fail ở bước 3)
```

---

## 3. Test Step Config

Step là một HTTP request đơn lẻ trong plan. Xem [grading-full-flow.md §4.2](#422-test-step--tất-cả-các-trường-cấu-hình) cho giải thích chi tiết từng trường.

### 3.1 Bảng Tổng Hợp Các Trường Step

| Trường | Kiểu | Bắt buộc | Mặc định | Mô tả |
|--------|------|----------|----------|--------|
| `method` | String | ✅ | — | HTTP method: GET, POST, PUT, PATCH, DELETE |
| `path` | String | ✅ | — | URL path (có thể chứa `${var}`) |
| `expected_status` | int | ❌ | — | HTTP status mong đợi (khuyến khích dùng) |
| `extract` | List\<Extract\> | ❌ | `[]` | Trích xuất biến từ response |
| `assertions` | List\<Assertion\> | ❌ | `[]` | Điều kiện kiểm tra response |
| `required` | boolean | ❌ | `false` | FAIL step → plan dừng? |
| `timeoutMs` | long | ❌ | Từ config toàn cục | Timeout HTTP request (ms) |

### 3.2 Các Giá Trị Hợp Lệ Của `method`

| Giá trị | Ý nghĩa | Ví dụ |
|---------|----------|-------|
| `GET` | Lấy dữ liệu | `/api/v1/books` |
| `POST` | Tạo mới | `/api/v1/books` |
| `PUT` | Cập nhật toàn bộ | `/api/v1/books/123` |
| `PATCH` | Cập nhật một phần | `/api/v1/books/123` |
| `DELETE` | Xóa | `/api/v1/books/123` |

### 3.3 Các Giá Trị Hợp Lệ Của `expected_status`

| Giá trị | Ý nghĩa | Thường dùng khi |
|---------|----------|-----------------|
| `200` | OK | GET, PUT, PATCH thành công |
| `201` | Created | POST tạo mới thành công |
| `204` | No Content | DELETE thành công |
| `400` | Bad Request | Dữ liệu không hợp lệ |
| `404` | Not Found | Tài nguyên không tồn tại |

### 3.4 Ví Dụ Full Step

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

---

## 4. Assertion Config

### 4.1 Bảng Tổng Hợp Các Loại Assertion

| Kind | Cấu hình | Kiểm tra gì | Ví dụ |
|------|----------|--------------|--------|
| `STATUS` | `{ "kind": "STATUS", "equals": 200 }` | HTTP status code | So sánh actual == expected |
| `CONTAINS` | `{ "kind": "CONTAINS", "text": "hello" }` | Substring trong response body | actualBody.contains(text) |
| `JSON_PATH` | `{ "kind": "JSON_PATH", "path": "$.id", "exists": true }` | Trường tồn tại trong JSON | JsonPath.compile(path).read(body) != null |
| `BODY_EQUALS` | `{ "kind": "BODY_EQUALS", "json": { "id": "abc" } }` | Toàn bộ body bằng nhau | Gson deep equals |
| `BODY_STRUCTURE` | `{ "kind": "BODY_STRUCTURE", "json": { "id": "" } }` | Cấu trúc JSON (không giá trị) | Same key set, same types |
| `FIELD_EQUALS` | `{ "kind": "FIELD_EQUALS", "path": "$.id", "equals": "${bookId}" }` | 1 field = giá trị kỳ vọng | JsonPath read + equals |

### 4.2 Chi Tiết Từng Loại

#### STATUS

```json
{ "kind": "STATUS", "equals": 200 }
```

| `equals` | Khi nào dùng |
|----------|--------------|
| `200` | Lấy dữ liệu thành công |
| `201` | Tạo mới thành công |
| `204` | Xóa thành công |
| `400` | Dữ liệu không hợp lệ |
| `404` | Không tìm thấy tài nguyên |

#### CONTAINS

```json
{ "kind": "CONTAINS", "text": "Test Book" }
```

- **Phân biệt chữ hoa/thường**: `Test Book` ≠ `test book`
- **Tìm trong toàn bộ response body** (string)
- Dùng kiểm tra: `body.contains(text)`

#### JSON_PATH

```json
{ "kind": "JSON_PATH", "path": "$.id", "exists": true }
```

| `path` | Ý nghĩa | Ví dụ response | Kết quả |
|--------|----------|-----------------|----------|
| `$.id` | Trường ở root | `{"id":"abc"}` | `"abc"` |
| `$.author.name` | Trường lồng nhau | `{"author":{"name":"A"}}` | `"A"` |
| `$..id` | Đệ quy tất cả `id` | `{"a":{"id":"1"}}` | `["1"]` |
| `$.items[0]` | Phần tử mảng | `{"items":[{"id":"a"}]}` | `{"id":"a"}` |
| `$.items[*]` | Tất cả phần tử | `{"items":[{"id":"a"},{"id":"b"}]}` | `[{"id":"a"},{"id":"b"}]` |

| `exists` | Ý nghĩa |
|----------|----------|
| `true` | Kiểm tra trường **có tồn tại** |
| `false` | Kiểm tra trường **không tồn tại** |

#### BODY_EQUALS

```json
{ "kind": "BODY_EQUALS", "json": { "id": "abc-123", "title": "Test Book" } }
```

- So sánh JSON response với JSON kỳ vọng
- **Không phân biệt thứ tự field**: `{"a":1,"b":2}` == `{"b":2,"a":1}`
- **Giá trị phải khớp chính xác**
- Dùng Gson deep equals

#### BODY_STRUCTURE

```json
{ "kind": "BODY_STRUCTURE", "json": { "id": "", "title": "" } }
```

- So sánh **cấu trúc** (có những trường nào), **không so sánh giá trị**
- Field name phải khớp, key set phải bằng nhau (unordered)
- Kiểu dữ liệu phải khớp (string, number, boolean, object, array)
- Giá trị trong expected **bị bỏ qua** (để `""` thay vì giá trị thật)

#### FIELD_EQUALS

```json
{ "kind": "FIELD_EQUALS", "path": "$.id", "equals": "${book1Id}" }
```

- Đọc giá trị tại JsonPath `path` từ response body
- Thay thế `${var}` trong `equals` bằng giá trị từ `VariableContext`
- So sánh `actual == expected` (chuỗi)
- Khi body null hoặc path không tồn tại → FAIL
- **Dùng để chống hardcode**: dùng `${var}` thay vì literal

### 4.3 Kết Quả Assertion

| Kết quả | Khi nào | Action |
|---------|----------|--------|
| **PASS** | Assertion đúng | Tiếp tục |
| **FAIL** | Assertion sai | Ghi log, step FAIL |

---

## 5. Extract Config

### 5.1 Bảng Tổng Hợp

| Trường | Kiểu | Bắt buộc | Mô tả | Ví dụ |
|--------|------|----------|--------|-------|
| `name` | String | ✅ | Tên biến (dùng trong `${tên}`) | `"bookId"` |
| `from` | String | ✅ | Nguồn dữ liệu | `"response_body"` |
| `expression` | String | ✅ | JsonPath | `"$.id"` |

### 5.2 Các Giá Trị Của `from`

| Giá trị | Mô tả | Hiện tại hỗ trợ |
|----------|--------|-----------------|
| `response_body` | Trích từ body response HTTP | ✅ Có |

### 5.3 Các Dạng JsonPath Được Hỗ Trợ

| JsonPath | Ý nghĩa | Ví dụ |
|----------|----------|-------|
| `$.fieldName` | Trường ở root | `$.id` |
| `$.parent.child` | Trường lồng nhau | `$.author.name` |
| `$.items[0]` | Phần tử mảng (index 0) | `$.items[0]` |
| `$.items[-1]` | Phần tử cuối | `$.items[-1]` |
| `$.items[*]` | Tất cả phần tử | `$.items[*]` |
| `$..fieldName` | Đệ quy tất cả | `$..id` |

### 5.4 Quy Tắc Tên Biến

- Chỉ chứa: chữ cái, số, dấu gạch dưới
- Phân biệt chữ hoa/thường
- `${bookId}` ≠ `${bookid}`
- Dùng camelCase: `${bookId}`, `${studentName}`

---

## 6. GraderConfig DTO (Internal)

`GraderConfig` là object nội bộ được `GradingOrchestrator` đọc từ course-service qua `AssignmentGradingConfigDto`.

### 6.1 Các Trường Của GraderConfig

| Trường | Kiểu | Mô tả | Ví dụ |
|--------|------|--------|-------|
| `gradingStrategy` | String | Chiến lược chấm | `"STUDENT_DOCKER_COMPOSE"` |
| `ports` | List\<PortMapping\> | Cổng cần map | `[{"dockerComposePort":8080}]` |
| `startupTimeoutMs` | Long | Timeout chờ app boot | `10000` |
| `executionTimeoutMs` | Long | Timeout toàn bộ grading | `60000` |
| `maxCpu` | String | CPU limit | `"500m"` |
| `maxMemoryMb` | Long | RAM limit (MB) | `512` |

### 6.2 Port Mapping

| Trường | Mô tả | Ví dụ |
|--------|--------|-------|
| `dockerComposePort` | Port trong Docker Compose template | `8080` |
| (mapped auto) | Port cấp bởi PortAllocator (20000-30000) | `24567` |

Quy tắc: URL app sinh viên = `http://localhost:{mappedPort}`

---

## 7. Executor Service Properties

Cấu hình trong `application.yaml` của executor-service. Đọc qua `@ConfigurationProperties` record.

### 7.1 Grading Properties (`grading.*`)

| Property | Kiểu | Mặc định | Mô tả |
|----------|------|----------|--------|
| `grading.task-core-pool-size` | int | `1` | Số thread tối thiểu cho grading pool |
| `grading.task-max-pool-size` | int | `2` | Số thread tối đa cho grading pool |
| `grading.task-queue-capacity` | int | `10` | Queue capacity khi pool đầy |
| `grading.task-keep-alive-seconds` | int | `60` | Thời gian giữ thread idle |
| `grading.pool-name` | String | `"grading-task-executor"` | Tên thread pool |
| `grading.dind.image` | String | `"docker:27-dind"` | Docker-in-Docker image |
| `grading.dind.cpu` | String | `"500m"` | CPU cho DinD container |
| `grading.dind.memory` | String | `"512m"` | RAM cho DinD container |
| `grading.dind-privileged` | boolean | `true` | DinD cần privileged mode |
| `grading.stale-job-reaper.interval-ms` | long | `300000` | Interval kiểm tra stale job (5 phút) |
| `grading.stale-job-reaper.stale-after-minutes` | int | `30` | Thời gian coi job là stale |
| `grading.stale-job-reaper.max-attempts` | int | `3` | Số lần retry tối đa |
| `grading.step-completion-timeout-ms` | long | `60000` | Timeout chờ step hoàn thành (1 phút) |
| `grading.result-service.retry.max-attempts` | int | `3` | Retry khi gọi result-service |
| `grading.result-service.retry.base-delay-ms` | long | `2000` | Base delay giữa retry (2 giây) |
| `grading.grading-notification.url` | String | `""` | Webhook URL thông báo |
| `grading.grading-notification.connect-timeout` | int | `10` | Connection timeout webhook |
| `grading.grading-notification.read-timeout` | int | `10` | Read timeout webhook |
| `grading.grading-notification.max-payload-size` | int | `10485760` | Max payload webhook (10MB) |

### 7.2 Resource Properties (`resource.*`)

| Property | Kiểu | Mô tả |
|----------|------|--------|
| `resource.type` | String | Loại storage: `"rustfs"` |
| `resource.endpoint` | String | RustFS endpoint URL |
| `resource.bucket-name` | String | Bucket name |
| `resource.region` | String | Region |
| `resource.access-key` | String | Access key (secret) |
| `resource.secret-key` | String | Secret key (secret) |

### 7.3 Course Service Properties (`course-service.*`)

| Property | Kiểu | Mô tả |
|----------|------|--------|
| `course-service.url` | String | URL course-service |
| `course-service.username` | String | Basic auth username |
| `course-service.password` | String | Basic auth password |

### 7.4 Result Service Properties (`result-service.*`)

| Property | Kiểu | Mô tả |
|----------|------|--------|
| `result-service.url` | String | URL result-service |
| `result-service.username` | String | Basic auth username |
| `result-service.password` | String | Basic auth password |

### 7.5 Submission Service Properties (`submission.service.*`)

| Property | Kiểu | Mô tả |
|----------|------|--------|
| `submission.service.url` | String | URL submission-service |
| `submission.service.username` | String | Basic auth username |
| `submission.service.password` | String | Basic auth password |

### 7.6 Internal Properties (`internal.*`)

| Property | Kiểu | Mô tả |
|----------|------|--------|
| `internal.kafka.topic` | String | Kafka topic: `"GRADE_SUBMISSION"` |
| `internal.kafka.group-id` | String | Consumer group ID |
| `internal.kafka.bootstrap-servers` | String | Kafka bootstrap servers |
| `internal.kafka.auto-offset-reset` | String | Offset reset: `"earliest"` |
| `internal.kafka.enable-auto-commit` | boolean | Auto commit |
| `internal.kafka.max-poll-records` | int | Max poll records |
| `internal.kafka.session-timeout-ms` | int | Session timeout |
| `internal.kafka.heartbeat-interval-ms` | int | Heartbeat interval |

### 7.7 Kafka Consumer Properties (`kafka.consumer.*`)

| Property | Kiểu | Mặc định | Mô tả |
|----------|------|----------|--------|
| `kafka.consumer.key-deserializer` | String | `StringDeserializer` | Deserializer cho key |
| `kafka.consumer.value-deserializer` | String | `KafkaJsonDeserializer` | Deserializer cho value |
| `kafka.consumer.value-class` | String | `SubmissionGradingEvent.class` | Java class cho JSON |
| `kafka.consumer.properties.spring.json.type.mapping` | String | `SubmissionGradingEvent=vn.edu.ptit...` | Type mapping |
| `kafka.consumer.properties.spring.json.trusted.packages` | String | `"*"` | Trusted packages |

### 7.8 Logging Properties

| Property | Mô tả | Giá trị |
|----------|--------|---------|
| Spring profile active | Xác định môi trường | `stg`, `prod`, hoặc `!stg & !prod` |
| File log path | Nơi lưu log file | `${project.basedir}/logs/` (dev) |
| Log pattern | Console pattern | `%d{yyyy-MM-dd HH:mm:ss} [%thread] %-5level %logger{36} - %msg%n` |

---

## 8. HTTP Client Config

### 8.1 HttpClient Configuration

| Property | Giá trị | Mô tả |
|----------|---------|--------|
| Implementation | `java.net.http.HttpClient` | JDK 21 built-in |
| Connect timeout | 10 seconds | Timeout kết nối |
| HTTP version | HTTP_1_1 | Dùng HTTP/1.1 |
| Instance | Singleton (bean) | Reused across requests |

### 8.2 Per-Step Timeout

- Từ `step.timeoutMs` (cấu hình step)
- Mặc định: `grading.step-completion-timeout-ms` từ application.yaml
- Áp dụng cho HttpRequest: `HttpRequest.timeout(Duration.ofMillis(timeoutMs))`

### 8.3 Request Building

```
1. VariableContext.substitute(path) → thay ${varName}
2. Build URI: http://localhost:{port}{path} + query string
3. Build HttpRequest với method, headers, body
```

### 8.4 Response Handling

| Trường hợp | Xử lý |
|------------|--------|
| 2xx | Parse body, run assertions |
| 4xx/5xx | Parse body (nếu có), run assertions, status != expected → FAIL |
| Timeout | `HttpTimeoutException` → ERROR step |
| Connection refused | ERROR step, log warning |
| Empty body | Handle gracefully, assertions trên body sẽ fail |

---

## 9. Variable Resolution

### 9.1 VariableContext

`VariableContext` là object **per-job** (mỗi grading job có 1 instance). Lưu trữ các biến được trích xuất từ response body.

### 9.2 Quy Trình Thay Biến

```
1. Bước trước extract biến → VariableContext.put(name, value)
2. Bước sau sử dụng ${name} trong path → VariableContext.substitute(path)
3. Thay thế: /api/books/${bookId} → /api/books/abc-123
4. Biến không tìm thấy → giữ nguyên ${bookId} trong path
```

### 9.3 autoInjectExtracts

Tự động thêm extract entries vào bước trước khi bước sau cần biến đó.

### 9.4 Quy Tắc Tên Biến

| Quy tắc | Mô tả |
|----------|--------|
| Ký tự hợp lệ | Chữ cái, số, dấu gạch dưới |
| Phân biệt | Case-sensitive |
| Phạm vi | Per-job (không chia sẻ giữa các job) |
| Overwrite | Biến cùng tên sẽ bị ghi đè |
| Lifecycle | Được tạo khi extract, xóa khi job kết thúc |

---

## 10. Scoring Formula

### 10.1 Công Thức

```
Score = (passedWeight / ranWeight) × 10.00
```

### 10.2 Định Nghĩa Các Biến

| Biến | Ý nghĩa |
|------|----------|
| `passedWeight` | Tổng weight các bước PASSED |
| `ranWeight` | Tổng weight các bước PASSED + FAILED (không tính SKIPPED) |
| `10.00` | Điểm tối đa |

### 10.3 Quy Tắc

| Quy tắc | Mô tả |
|----------|--------|
| SKIPPED | Không tính cả passedWeight lẫn ranWeight |
| Chia cho 0 | Nếu ranWeight = 0 (all skipped) → Score = 0 |
| Làm tròn | HALF_UP, 2 decimal places |
| Ví dụ: 2/3 pass | `(2/3) × 10 = 6.67` |
| Ví dụ: 3/3 pass | `(3/3) × 10 = 10.00` |
| Ví dụ: 0/3 pass | `(0/3) × 10 = 0.00` |

### 10.4 Ví Dụ Tính Điểm

| Steps | Status | Passed Weight | Ran Weight | Score |
|-------|--------|---------------|------------|-------|
| 3 steps | P, P, P | 3 | 3 | 10.00 |
| 3 steps | P, P, F | 2 | 3 | 6.67 |
| 3 steps | P, F, F | 1 | 3 | 3.33 |
| 3 steps | P, S, S | 1 | 1 | 10.00 |
| 6 steps | P, P, P, P, P, P | 6 | 6 | 10.00 |

---

## 11. Deployment Config

### 11.1 Kubernetes Deployment (config-services)

| Trường | Giá trị | Mô tả |
|--------|---------|--------|
| `replicas` | `{{ .Values.replicaCount \| default 2 }}` | Số pod (mặc định 2) |
| `replicaCount` (values-stg) | `2` | Số replica ở stg |

### 11.2 dev-scale.sh Commands

| Command | Hành động | ArgoCD |
|---------|------------|--------|
| `bash dev-scale.sh <service> on` | Scale về 2 | Default |
| `bash dev-scale.sh <service> on <n>` | Scale về n | Suspended (tạm) |
| `bash dev-scale.sh <service> off` | Scale về 0 | Suspended |

### 11.3 Logback Profile Gating

| Profile | Output |
|---------|--------|
| `!stg & !prod` (dev) | Console + File (`${project.basedir}/logs/`) |
| `stg` | Console only (stdout → Loki) |
| `prod` | Console only (stdout → Loki) |

### 11.4 Resource Filtering

| Pattern | Xử lý |
|---------|--------|
| `@project.basedir@` | Maven lọc → absolute path |
| `${property.xxx}` | Not filtered (safety) |
| `${spring.application.name}` | Filtered (framework internal) |

### 11.5 Docker Compose Patcher Rules

| Rule | Hành động |
|------|-----------|
| Port rewrite | `<allocated>:<dockerComposePort\|8080>` |
| Privileged check | `privileged:true` → REJECT |
| Docker socket check | Mount `/var/run/docker.sock` → REJECT |
| Resource limits | Inject CPU/Memory limits |

---

## 12. Docker Compose Template

### 12.1 Cấu Hình Tối Thiểu

```yaml
services:
  app:
    image: student-app:latest
    ports:
      - "8080:8080"
```

### 12.2 Cấu Hình Đầy Đủ

```yaml
services:
  app:
    image: student-book-api:latest
    ports:
      - "8080:8080"
    environment:
      - SPRING_PROFILES_ACTIVE=test
      - SPRING_DATASOURCE_URL=jdbc:h2:mem:testdb
    command: ["sh", "-c", "sleep 5 && java -jar app.jar"]
```

### 12.3 Các Trường Của Service

| Trường | Bắt buộc | Mô tả |
|--------|----------|--------|
| `image` | ✅ | Docker image |
| `ports` | ✅ | Ít nhất 1 port (để xác định service chính) |
| `environment` | ❌ | Biến môi trường |
| `command` | ❌ | Override command |
| `volumes` | ❌ | Mount volumes |
| `depends_on` | ❌ | Service phụ thuộc |

### 12.4 Quy Tắc Xác Định Service Chính

1. Service đầu tiên có trường `ports` → là app chính
2. Port mặc định: `8080` nếu không chỉ định trong compose template
3. Executor-service map port: `{allocated_port}:{docker_compose_port}`

---

## 13. Bảng Tổng Hợp

### 13.1 Tất Cả Các Loại Assertion

| Kind | Cấu hình | Kiểm tra |
|------|----------|----------|
| `STATUS` | `{ "kind": "STATUS", "equals": 200 }` | HTTP status code |
| `CONTAINS` | `{ "kind": "CONTAINS", "text": "hello" }` | Substring trong body |
| `JSON_PATH` | `{ "kind": "JSON_PATH", "path": "$.id", "exists": true }` | Trường tồn tại |
| `BODY_EQUALS` | `{ "kind": "BODY_EQUALS", "json": { ... } }` | Body bằng nhau |
| `BODY_STRUCTURE` | `{ "kind": "BODY_STRUCTURE", "json": { ... } }` | Cấu trúc khớp |
| `FIELD_EQUALS` | `{ "kind": "FIELD_EQUALS", "path": "$.id", "equals": "${bookId}" }` | 1 field = giá trị |

### 13.2 Tất Cả Các HTTP Methods

| Method | expected_status | Mô tả |
|--------|----------------|--------|
| `GET` | 200 | Lấy dữ liệu |
| `POST` | 201 | Tạo mới |
| `PUT` | 200 | Cập nhật toàn bộ |
| `PATCH` | 200 | Cập nhật một phần |
| `DELETE` | 204 | Xóa |

### 13.3 Tất Cả Các Kết Quả Step

| Status | Khi nào |
|--------|----------|
| `PASSED` | HTTP + assertions đều OK |
| `FAILED` | Có assertion sai hoặc HTTP status không khớp |
| `ERROR` | Lỗi xảy ra (timeout, connection, parse) |
| `SKIPPED` | Bị bỏ do bước required trước FAIL |

### 13.4 Tất Cả Các Trường Step

| Trường | Bắt buộc | Kiểu | Mô tả |
|--------|----------|------|--------|
| `method` | ✅ | String | HTTP method |
| `path` | ✅ | String | URL path |
| `expected_status` | ❌ | int | Status mong đợi |
| `extract` | ❌ | List | Trích biến |
| `assertions` | ❌ | List | Điều kiện kiểm tra |
| `required` | ❌ | boolean | Bắt buộc? |
| `timeoutMs` | ❌ | long | Timeout |

### 13.5 Tất Cả Các Trường Extract

| Trường | Bắt buộc | Mô tả |
|--------|----------|--------|
| `name` | ✅ | Tên biến |
| `from` | ✅ | Nguồn (response_body) |
| `expression` | ✅ | JsonPath |

### 13.6 Tất Cả Các Trường GraderConfig

| Trường | Mô tả |
|--------|--------|
| `gradingStrategy` | Chiến lược chấm |
| `ports` | Danh sách port mapping |
| `startupTimeoutMs` | Timeout boot app |
| `executionTimeoutMs` | Timeout toàn bộ |
| `maxCpu` | CPU limit |
| `maxMemoryMb` | RAM limit |

### 13.7 Tất Cả Các Biến Số Làm Tròn Scoring

| Biến | Giá trị | Mô tả |
|------|---------|--------|
| Số decimal | 2 | HALF_UP |
| Điểm max | 10.00 | Điểm tối đa |
| SKIPPED | Không tính | Không计入 passed/ran weight |
