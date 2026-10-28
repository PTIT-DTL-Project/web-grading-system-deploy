# Kế hoạch nâng cấp cấu hình Test Plan & Test Step (Phases 1–7)

**Dự án:** Web Grading System (microservices Java, k3s, Helm)  
**Thư mục chứa plan:** `.opencode/plan/http-config-assertion-advanced/`  
**Ngôn ngữ:** Tiếng Việt  
**Mục tiêu:** Nâng tầm hệ thống từ "chạy script kiểm tra API đơn thuần" thành hệ thống chấm bài chuyên nghiệp, chịu tải tốt, thân thiện giảng viên, chống gian lận.

---

## 1. Tổng quan & bối cảnh

Hệ thống hiện tại cho phép giảng viên viết test plan/test step dưới dạng JSON lưu trong `course-service`, executor-service thực thi từng bước HTTP request, trích xuất biến `${var}`, đánh giá assertion và tính điểm.

Các vấn đề đã xác định từ việc đọc mã nguồn (`HttpStepExecutor`, `VariableContext`, `AssertionEngine`, `StepConfigValidator`, entities `TestStep`/`TestPlan`/`GradingStepResult`) và tài liệu thiết kế:

1. **Extract chỉ lưu chuỗi đơn** (`String.valueOf(val)`), không lưu được mảng/object toàn bộ.
2. **Không có biến cố định / pre-set variables**; lecturer phải gọi API trước mới có biến dùng sau.
3. **Không có cơ chế auth tập trung**; phải gán `Authorization: Bearer ${token}` thủ công ở mỗi bước.
4. **Không có vòng lặp dữ liệu**; tạo 4 sách khác nhau phải viết 4 step riêng, hardcode từng body.
5. **Assertion yếu cho danh sách**; không có `array_length`, `contains_item`, toán tử `>`, `<`, regex.
6. **Không phòng thủ null/missing**; `JsonPathException` có thể crash toàn bộ grading job.
7. **HttpClient đồng bộ (`send()`)**; một step treo 5 giây chiếm 1 thread, dễ nghẽn khi nhiều sinh viên nộp cùng lúc.
8. **Không có Faker / dữ liệu động**; sinh viên có thể hardcode kết quả cố định (anti-cheat yếu).
9. **Không có DB sandbox**; nhiều job cùng lúc trên DB chung gây flaky test.
10. **Không có Dry-Run**; giảng viên không thể chạy thử config trước khi áp dụng cho toàn lớp.

Bản kế hoạch dưới đây chia làm **7 Phase**, từ dễ đến phức tạp, nhằm tránh phá vỡ kiến trúc cũ.

---

## 2. Bản đồ đường đi (Roadmap)

| Phase | Nhóm | Mục tiêu chính | Độ ưu tiên | Phụ thuộc |
|-------|------|----------------|------------|-----------|
| **1** | Backend (nhẹ) | Mở rộng Assertion Engine (`array_length`, `contains_item`, `greater_than`, `less_than`, `matches_regex`) + Fallback biến (`fallback`) | Cao | Không |
| **2** | Backend (cơ sở) | Nâng cấp `VariableContext`: lưu Object, truy cập mảng `${books[0].id}`, built-in `${$UUID}`, `${$TIMESTAMP}`, `as: "json"` | Cao | Phase 1 |
| **3** | Backend (cấu trúc step) | Vòng lặp `data[]` với Loop Safety Governor (max 10 inline, truncate 20 runtime); `auto_inject_headers` cấp Plan; `ANY_OF` assertion | Cao | Phase 2 |
| **4** | Backend (lõi engine) | Virtual Threads + `HttpClient.sendAsync()`; Dynamic Faker `${$FAKER_*}` | Cao nhất | Phase 3 |
| **5** | Backend (infra) | DB Isolation Sandbox: mỗi job DB cô lập, snapshot/rollback sau mỗi Plan | Cao | Phase 4 |
| **6** | Backend + API | Dry-Run Mode: endpoint internal chạy thử config + reference code, trả báo cáo chi tiết | Trung bình | Phase 5 |
| **7** | Frontend-heavy | JSON Schema xuất từ `StepConfigValidator`; Visual Editor kéo thả; Import Postman/OpenAPI | Thấp / sau | Phase 6 |

**Câu trả lời trực tiếp:** Đối với môn Lập trình Web, tập trung **Phase 4 (Virtual Threads + Dynamic Faker)** trước, sau đó **Phase 5 (DB Isolation)**, rồi **Phase 6 (Dry-Run)**. Visual Editor (Phase 7) làm cuối cùng khi API config ổn định.

---

## 3. Phase 1 — Mở rộng Assertion & Fallback biến

**Mục tiêu:** Làm sắc bén các assertion cho list/filter và tránh crash job khi biến trích xuất bị thiếu/null.

### 3.1 Các tính năng

| Mã | Tính năng | Mô tả |
|----|-----------|-------|
| **D8** | `array_length` | Kiểm tra số phần tử mảng tại JsonPath: `{ "kind": "array_length", "path": "$.items", "equals": 4 }` |
| **D8** | `contains_item` | Kiểm tra mảng chứa giá trị: `{ "kind": "contains_item", "path": "$[*].title", "equals": "Dế Mèn" }` |
| **D9** | `json_path_equals` | So sánh giá trị tại JsonPath với biến/giá trị (hỗ trợ số, boolean, không chỉ chuỗi) |
| **D10** | `greater_than` / `less_than` / `matches_regex` | Toán tử so sánh số và regex cho chuỗi (giá > X, định dạng ngày ISO, ...) |
| **A4** | `fallback` trong `extract` | Nếu JsonPath không tìm thấy, gán giá trị mặc định (literal hoặc `""`) thay vì ném `JsonPathException` crash job |

### 3.2 File cần sửa

- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/scoring/AssertionEngine.java`
  - Thêm các case mới trong `evaluateHttp()`: `array_length`, `contains_item`, `json_path_equals`, `greater_than`, `less_than`, `matches_regex`.
  - Cập nhật `AssertionDetail` nếu cần.
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/step/impl/HttpStepExecutor.java`
  - Bọc xử lý `extract` trong try-catch; khi lỗi JsonPath và có `fallback`, gán giá trị fallback thay để crash.
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/Constant.java`
  - Thêm hằng số assertion kind mới (`ARRAY_LENGTH`, `CONTAINS_ITEM`, `JSON_PATH_EQUALS`, `GREATER_THAN`, `LESS_THAN`, `MATCHES_REGEX`, `FALLBACK`).
- `src-services/course-service/src/main/java/vn/edu/ptit/web_grading_system/course_service/service/StepConfigValidator.java`
  - Validate cấu trúc các assertion kind mới và trường `fallback` trong `extract`.

### 3.3 Ví dụ JSON config

```json
{
  "method": "GET",
  "path": "/api/v1/books",
  "query_params": {"title": "${searchTitle}"},
  "expected_status": 200,
  "extract": [
    { "name": "firstBookId", "from": "response_body", "expression": "$[0].id", "fallback": "" }
  ],
  "assertions": [
    { "kind": "status", "equals": 200 },
    { "kind": "array_length", "path": "$", "equals": "${expectedCount}" },
    { "kind": "contains_item", "path": "$[*].title", "equals": "${searchTitle}" },
    { "kind": "greater_than", "path": "$[*].year", "value": 1900 }
  ]
}
```

### 3.4 Rủi ro / lưu ý

- `array_length` và `contains_item` cần parse body thành JSON rồi đánh giá JsonPath; nếu body không phải JSON mảng, trả về `FAILED` không crash.
- `fallback` chỉ áp dụng khi `expression` không khớp; không dùng cho lỗi mạng/timeout.

### 3.5 Definition of Done

- Unit test mới cho từng assertion kind trong `AssertionEngine`.
- `HttpStepExecutor` không còn crash do `JsonPathException` khi thiếu trường và có `fallback`.
- `StepConfigValidator` từ chối config assertion kind mới sai cấu trúc (400 khi lưu step).

---

## 4. Phase 2 — Nâng cấp VariableContext

**Mục tiêu:** Cho phép lưu biến phức tạp (object, mảng), truy cập phần tử mảng, và cung cấp biến sinh động nội built-in.

### 4.1 Các tính năng

| Mã | Tính năng | Mô tả |
|----|-----------|-------|
| **A1** | `as: "json"` trong `extract` | Lưu toàn bộ object/mảng tại JsonPath thành chuỗi JSON vào biến, sau đó dùng `${var}` trong body/query của bước khác. |
| **A3** | Truy cập mảng từ biến | `${books[0].id}`, `${books[*].id}` được `VariableContext` hiểu khi thay vào path/body. |
| **A5** | Built-in dynamic variables | `${$UUID}` (UUID ngẫu nhiên), `${$TIMESTAMP}` (thời gian thực) — lecturer không cần định nghĩa. |

### 4.2 File cần sửa

- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/scoring/VariableContext.java`
  - Đổi `Map<String, Object>` giữ nguyên kiểu Object (không ép về `String.valueOf` sớm).
  - Thêm phương thức sinh giá trị động cho token bắt đầu bằng `$` (`$UUID`, `$TIMESTAMP`).
  - Hỗ trợ truy cập phần tử mảng khi substitute `${var[index].field}` (hoặc để executor tự xử lý sau khi lấy biến object).
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/step/impl/HttpStepExecutor.java`
  - Khi `extract` có `as: "json"`, serialize giá trị JsonPath bằng Gson và lưu vào `VariableContext`.
  - Khi substitute, nếu biến là object/mảng, lecturer có thể dùng `${var}` trực tiếp trong body (chuỗi JSON) hoặc `${var[0].id}`.
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/Constant.java`
  - Thêm hằng cho built-in tokens (`$UUID`, `$TIMESTAMP`) và `as` key.

### 4.3 Ví dụ JSON config

```json
{
  "method": "POST",
  "path": "/api/v1/books",
  "body": {"title": "Sách A", "author": "Tô Hoài"},
  "extract": [
    { "name": "book1", "from": "response_body", "expression": "$", "as": "json" },
    { "name": "uniqueId", "expression": "${$UUID}" }
  ]
}
```

Bước sau có thể dùng:
- `${book1}` → chuỗi JSON toàn bộ đối tượng sách vừa tạo.
- `${uniqueId}` → UUID ngẫu nhiên, tránh trùng unique constraint khi chấm nhiều lần.

### 4.4 Rủi ro / lưu ý

- `VariableContext` là per-job; biến object lớn (mảng 100 phần tử) sẽ chiếm RAM nhưng nằm trong phạm vi 1 job, chấp nhận được.
- Built-in token phải sinh **mỗi lần tham chiếu**, không cache, để mỗi lần gọi API nhận giá trị mới (tránh lecturer dùng `${$UUID}` ở 2 bước khác nhau mà nhận cùng giá trị nếu không ý muốn).

### 4.5 Definition of Done

- `VariableContext.put` giữ kiểu Object; `substitute` xử lý đúng `${$UUID}`, `${$TIMESTAMP}`.
- `extract` với `as: "json"` lưu chuỗi JSON đầy đủ, không bị cắt ngắn thành `"[object Object]"`.
- Unit test kiểm tra truy cập phần tử mảng từ biến object.

---

## 5. Phase 3 — Vòng lặp dữ liệu, Inject Header, ANY_OF

**Mục tiêu:** Hỗ trợ tạo nhiều dữ liệu khác nhau trong 1 step, giảm thủ công gán header auth, và cho phép assertion linh hoạt (OR).

### 5.1 Các tính năng

| Mã | Tính năng | Mô tả |
|----|-----------|-------|
| **C6** | `data[]` (data-driven loop) | Step chạy N lần, mỗi lần gán biến từ một bản ghi trong mảng `data`. |
| **C8** | Loop Safety Governor | Validator từ chối `data[]` inline > 10 phần tử; runtime truncate mảng for-each > 20 phần tử. |
| **B6** | `auto_inject_headers` cấp Plan | Khi bước login trích xuất token, tự động tiêm `Authorization: Bearer ${token}` vào mọi bước `HTTP_REQUEST` sau trong cùng Plan. |
| **E13** | `ANY_OF` assertion | Toán tử OR trong 1 step: chỉ cần 1 điều kiện con đúng là step PASS (ví dụ định dạng ngày YYYY-MM-DD hoặc ISO). |

### 5.2 File cần sửa

- `src-services/course-service/src/main/java/vn/edu/ptit/web_grading_system/course_service/service/StepConfigValidator.java`
  - Validate `data[]`: mảng không rỗng, mỗi entry là object, số phần tử ≤ 10 (inline).
  - Validate `auto_inject_headers` ở cấp Plan (nếu lưu ở cấp Plan) hoặc cấp step.
  - Validate cấu trúc `ANY_OF` assertion.
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/step/impl/HttpStepExecutor.java`
  - Thêm vòng lặp qua `data[]`: mỗi lần substitute biến từ entry, gán biến tạm (`${index}`, `${title}`, ...), gửi request, extract riêng.
  - Áp dụng truncate 20 phần tử nếu for-each trên biến danh sách lớn.
  - Sau bước login trong Plan, nếu có `auto_inject_headers`, tiêm header vào các bước tiếp theo.
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/scoring/AssertionEngine.java`
  - Thêm case `any_of`: đánh giá mảng assertion con, trả về passed nếu ít nhất 1 đúng.
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/Constant.java`
  - Thêm hằng `DATA`, `AUTO_INJECT_HEADERS`, `ANY_OF`.

### 5.3 Ví dụ JSON config

```json
{
  "name": "Plan test bảo mật với auth tự động",
  "auto_inject_headers": {
    "Authorization": "Bearer ${accessToken}"
  },
  "steps": [
    {
      "stepOrder": 1,
      "name": "Login",
      "stepType": "HTTP_REQUEST",
      "config": {
        "method": "POST",
        "path": "/api/v1/auth/login",
        "body": {"username": "lecturer", "password": "secret"},
        "extract": [{"name": "accessToken", "from": "response_body", "expression": "$.accessToken"}]
      }
    },
    {
      "stepOrder": 2,
      "name": "Tạo 4 sách khác nhau",
      "stepType": "HTTP_REQUEST",
      "config": {
        "method": "POST",
        "path": "/api/v1/books",
        "data": [
          {"title": "Sách A", "year": 1941},
          {"title": "Sách B", "year": 1950},
          {"title": "Sách C", "year": 1960},
          {"title": "Dế Mèn Phiêu Lưu Ký", "year": 1941}
        ],
        "body": {"title": "${title}", "author": "Tô Hoài", "year": ${year}},
        "extract": [{"name": "bookId_${index}", "from": "response_body", "expression": "$.id"}]
      }
    },
    {
      "stepOrder": 3,
      "name": "Filter search",
      "stepType": "HTTP_REQUEST",
      "config": {
        "method": "GET",
        "path": "/api/v1/books",
        "query_params": {"title": "Dế Mèn"},
        "assertions": [
          { "kind": "status", "equals": 200 },
          { "kind": "array_length", "path": "$", "equals": 1 },
          { "kind": "contains_item", "path": "$[*].title", "equals": "Dế Mèn Phiêu Lưu Ký" }
        ]
      }
    }
  ]
}
```

Lưu ý: Bước 2 không cần viết `Authorization` vì `auto_inject_headers` ở cấp Plan đã tiêm sau bước 1.

### 5.4 Rủi ro / lưu ý

- `data[]` với 10 phần tử tạo 10 request HTTP; nếu mỗi request timeout 5s, step này có thể chạy tới 50s. Cần tính vào `executionTimeoutMs` của assignment.
- `auto_inject_headers` chỉ áp dụng cho bước **sau** bước trích xuất token trong cùng Plan; bước trước token tồn tại không bị ảnh hưởng.
- `ANY_OF` cần làm rõ: nếu assertion con là `status` và `json_path`, chỉ cần 1 trong 2 đúng → step PASS. Điều này có thể giảm độ nghiêm ngặt nếu lecturer lạm dụng.

### 5.5 Definition of Done

- `data[]` chạy đúng N lần, mỗi lần có biến riêng (`bookId_0`, `bookId_1`, ...).
- `auto_inject_headers` tiêm đúng `Authorization` vào bước 2, 3 sau khi bước 1 extract `accessToken`.
- `ANY_OF` trả về PASSED khi ít nhất 1 assertion con đúng.
- Validator từ chối `data[] > 10` phần tử (400 khi lưu step).

---

## 6. Phase 4 — Virtual Threads + Dynamic Faker

**Mục tiêu:** Tăng throughput executor, không bị nghẽn thread khi sinh viên nộp cùng lúc; chống sinh viên hardcode kết quả cố định.

### 6.1 Các tính năng

| Mã | Tính năng | Mô tả |
|----|-----------|-------|
| **5** | Virtual Threads + `sendAsync()` | Thay `HttpClient.send()` (blocking) bằng `sendAsync()` chạy trên Virtual Thread (Java 21 Project Loom). Một step treo 5 giây không chiếm thread nền. |
| **4** | Dynamic Data Injection / Faker | Token nội built-in: `${$FAKER_NAME}`, `${$FAKER_BOOK_TITLE}`, `${$FAKER_WORD}`, ... Sinh chuỗi ngẫu nhiên mỗi lượt chấm, sinh viên không thể hardcode. |

### 6.2 File cần sửa

- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/step/impl/HttpStepExecutor.java`
  - Thay `httpClient.send(builder.build(), HttpResponse.BodyHandlers.ofString())` bằng `httpClient.sendAsync(...).join()` hoặc chạy trong `Executors.newVirtualThreadPerTaskExecutor()`.
  - Đảm bảo `HttpClient` singleton thread-safe với `sendAsync`.
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/scoring/VariableContext.java`
  - Thêm sinh giá trị cho token `${$FAKER_*}` (có thể dùng class helper `FakerGenerator` mới).
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/Constant.java`
  - Thêm prefix `FAKER` và danh sách token Faker hỗ trợ.
- (Tùy chọn) Tạo class mới: `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/scoring/FakerGenerator.java`

### 6.3 Ví dụ JSON config

```json
{
  "method": "POST",
  "path": "/api/v1/books",
  "body": {
    "title": "${$FAKER_BOOK_TITLE}",
    "author": "${$FAKER_NAME}",
    "isbn": "${$UUID}"
  },
  "extract": [
    { "name": "createdIsbn", "from": "response_body", "expression": "$.isbn" }
  ]
}
```

Mỗi lượt chấm, `title`, `author`, `isbn` đều khác nhau → sinh viên phải lưu thật vào DB, không thể trả về JSON cứng chuẩn trước.

### 6.4 Rủi ro / lưu ý

- Virtual Thread với `sendAsync().join()` vẫn block virtual thread nhưng không block platform thread; throughput cao hơn nhiều.
- Cần kiểm tra `HttpClient` redirect, timeout, connection pool hoạt động đúng với virtual thread (JDK 21 đã hỗ trợ tốt).
- Faker token sinh ngẫu nhiên có thể làm lecturer khó đoán kết quả để viết assertion; khuyến khích dùng `field_equals` với `${$UUID}` extract ra sau đó so sánh, hoặc dùng `contains_item`/`regex`.

### 6.5 Definition of Done

- `HttpStepExecutor` sử dụng `sendAsync` + virtual thread; không còn `send()` blocking platform thread.
- Unit test giả lập student app treo 10 giây: executor vẫn nhận được các grading job khác không bị nghẽn.
- `${$FAKER_NAME}`, `${$UUID}` sinh giá trị khác nhau tại các lần tham chiếu khác nhau trong cùng job.

---

## 7. Phase 5 — DB Isolation Sandbox

**Mục tiêu:** Mỗi grading job có database riêng, không bị ảnh hưởng dữ liệu giữa các lượt chấm (không flaky test).

### 7.1 Các tính năng

| Mã | Tính năng | Mô tả |
|----|-----------|-------|
| **3** | DB Isolation (mỗi job 1 DB) | Tận dụng `grading.dind.image` đã có: container DB của sinh viên khởi tạo cô lập cùng với App trong 1 grading job. |
| **3** | Snapshot / Rollback DB | Sau mỗi Plan (hoặc toàn bộ Job), thực thi lệnh ngầm để snapshot hoặc rollback DB về trạng thái nguyên bản, giúp lượt sau không bị rác dữ liệu. |

### 7.2 File cần sửa

- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/infra/DockerComposeRunner.java` (hoặc class tương ứng boot compose)
  - Đảm bảo compose template của sinh viên có service DB (postgres/mysql) và port DB được claim riêng cho job.
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/orchestrator/GradingOrchestrator.java`
  - Trước khi boot compose: claim `dbPort` riêng, khởi tạo DB container.
  - Sau mỗi Plan: gọi lệnh rollback/snapshot DB (ví dụ `pg_dump` restore, hoặc xóa và tạo lại database test).
  - Sau toàn bộ Job: dọn dẹp container DB.
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/Constant.java`
  - Thêm hằng cấu hình DB sandbox (tên database mặc định, lệnh rollback, ...).
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/entity/GradingStepResult.java`
  - Có thể thêm cột ghi chú DB snapshot status nếu cần theo dõi.

### 7.3 Ví dụ luồng hoạt động

```
Job bắt đầu
  └─> Claim appPort + dbPort (20000-30000)
  └─> Boot compose: App + DB (cô lập cho job này)
  └─> Chạy Plan 1 (tạo 4 sách, filter, ...)
  └─> Rollback DB về trạng thái trống (hoặc snapshot ban đầu)
  └─> Chạy Plan 2 (nếu có) trên DB sạch
  └─> Dọn dẹp DB container, giải phóng port
Job kết thúc
```

### 7.4 Rủi ro / lưu ý

- PostgreSQL hỗ trợ transaction rollback DDL/DML tốt; MySQL/MariaDB **force implicit commit** trên DDL (`CREATE/ALTER/DROP`, `TRUNCATE`) — rollback không hoàn toàn undo schema đã thay đổi (đã ghi chú trong `grading-config-reference.md §3.5`). Lecturer trên MySQL nên tách DDL và DML thành các step riêng.
- Việc khởi tạo DB container cho mỗi job tăng thời gian boot (FETCHING/BUILDING dài hơn). Cần cân bằng với `executionTimeoutMs`.
- Port DB không được trùng giữa các job chạy song song; `PortAllocator` đã quản lý range 20000-30000, cần đảm bảo `dbPort` cũng được claim từ range này.

### 7.5 Definition of Done

- Mỗi grading job có DB container riêng, port DB không trùng với job khác.
- Sau mỗi Plan, DB được reset về trạng thái sạch; dữ liệu từ Plan trước không影響 Plan sau.
- Integration test với Testcontainers (postgres:16, mysql:8) verify rollback/snapshot.

---

## 8. Phase 6 — Dry-Run Mode

**Mục tiêu:** Giảng viên chạy thử cấu hình chấm bài trước khi áp dụng cho toàn khóa học.

### 8.1 Các tính năng

| Mã | Tính năng | Mô tả |
|----|-----------|-------|
| **6** | Dry-Run endpoint | `POST /api/v1/internal/assignments/{id}/dry-run`: nhận config + reference code zip, chạy toàn bộ flow, trả báo cáo chi tiết (biến extract, thời gian từng step, pass/fail) mà không ghi điểm cuối cho sinh viên. |

### 8.2 File cần sửa

- `src-services/course-service/src/main/java/vn/edu/ptit/web_grading_system/course_service/controller/...` (controller internal)
  - Thêm endpoint `POST /api/v1/internal/assignments/{id}/dry-run`.
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/orchestrator/GradingOrchestrator.java`
  - Thêm mode `dry-run`: chạy toàn bộ step nhưng **không** gọi `POST /api/v1/internal/results` và không cập nhật `submission-status` cuối cùng.
  - Trả báo cáo chi tiết: mỗi step status, extracted variables, durationMs, assertion result.
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/entity/GradingStepResult.java`
  - Có thể đánh dấu kết quả là dry-run (không lưu vào bảng chính hoặc lưu vào bảng tạm) nếu cần phân biệt.

### 8.3 Ví dụ payload

```json
POST /api/v1/internal/assignments/{assignmentId}/dry-run
{
  "referenceCodeZipUrl": "rustfs://bucket/ref-code-123.zip",
  "config": { ... test plan ... }
}
```

**Trả về:**
```json
{
  "dryRunId": "...",
  "steps": [
    { "stepOrder": 1, "status": "PASSED", "durationMs": 340, "extractedVariables": {"bookId": "abc-123"} },
    { "stepOrder": 2, "status": "FAILED", "durationMs": 120, "errorMessage": "Expected 200 but got 404" }
  ],
  "summary": "Passed 1/2 steps, Score: 5.00/10.00"
}
```

### 8.4 Rủi ro / lưu ý

- Dry-run cần reference code (instructor's reference code) để chạy app sinh viên; nếu không có, chỉ chạy được config logic mà không có app thực.
- Không được ghi kết quả dry-run vào `result-service` (tránh lecturers vô tình cập nhật điểm sinh viên).
- Cần phân biệt endpoint internal này chỉ gọi được từ executor-service hoặc lecturer authenticated (gateway/internal route).

### 8.5 Definition of Done

- Endpoint dry-run trả về báo cáo chi tiết từng bước.
- Không có side effect ghi điểm vào result-service sau dry-run.
- Lecturer có thể xem biến extract được sinh ra ở mỗi bước để tinh chỉnh config.

---

## 9. Phase 7 — Visual Editor, JSON Schema, Import Postman/OpenAPI

**Mục tiêu:** Giảm tải việc viết JSON thủ công cho giảng viên (Trục 1 — Config nâng cao).

### 9.1 Các tính năng

| Mã | Tính năng | Mô tả |
|----|-----------|-------|
| **1** | JSON Schema xuất từ code | `StepConfigValidator` xuất file JSON Schema chính thức mô tả cấu trúc config cho từng step type. |
| **1** | Visual Test Blueprint Editor | Giao diện frontend kéo thả / form-step, validate real-time trước khi lưu vào `course-service`. |
| **2** | Import Postman Collection / OpenAPI | Phân tách file Postman JSON hoặc OpenAPI Spec, tự động sinh `HTTP_REQUEST` steps cơ bản (status 200, body_structure). Lecturer chỉ cần tinh chỉnh extract variables. |

### 9.2 File cần sửa

- `src-services/course-service/src/main/java/vn/edu/ptit/web_grading_system/course_service/service/StepConfigValidator.java`
  - Thêm phương thức xuất JSON Schema (hoặc dùng thư viện sinh schema từ class cấu hình).
- `src-services/course-service/src/main/java/vn/edu/ptit/web_grading_system/course_service/controller/...` (internal hoặc public)
  - Endpoint `GET /api/v1/internal/assignments/{id}/config-schema` trả về JSON Schema.
- `frontend-src/web-grading-system-fe/` (React + antd)
  - Xây dựng Visual Editor (form kéo thả, tabs Params/Headers/Body/Tests/Variables).
  - Tích hợp import Postman/OpenAPI (nếu FE được phân công).
- `docs/design/grading-config-reference.md`
  - Bổ sung mô tả JSON Schema và cách dùng Visual Editor.

### 9.3 Ví dụ JSON Schema (đoạn minh họa)

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "HTTP_REQUEST step config",
  "type": "object",
  "required": ["method", "path"],
  "properties": {
    "method": {"type": "string", "enum": ["GET","POST","PUT","PATCH","DELETE","HEAD","OPTIONS"]},
    "path": {"type": "string", "pattern": "^/"},
    "expected_status": {"type": "integer", "minimum": 100, "maximum": 599},
    "extract": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "from", "expression"],
        "properties": {
          "name": {"type": "string"},
          "from": {"type": "string"},
          "expression": {"type": "string"},
          "as": {"type": "string", "enum": ["scalar", "json"]},
          "fallback": {"type": "string"}
        }
      }
    }
  }
}
```

### 9.4 Rủi ro / lưu ý

- JSON Schema phải **đồng bộ** với `StepConfigValidator`; nếu validator thay đổi mà schema không cập nhật, frontend validate sai lệch so với backend.
- Import Postman/OpenAPI có nhiều định dạng edge case (biến môi trường Postman, pre-request script, ...). Backend chỉ chuyển đổi phần cơ bản (method, path, headers, body), lecturer vẫn phải tinh chỉnh assertion/extract.
- Visual Editor là công việc frontend lớn; nên làm sau khi backend API config ổn định (sau Phase 6).

### 9.5 Definition of Done

- JSON Schema có sẵn qua internal endpoint và khớp với `StepConfigValidator`.
- FE có form tạo/chỉnh step với validation real-time (ví dụ gõ sai `STATUS` thành chữ hoa báo đỏ ngay).
- Tính năng import Postman Collection cơ bản sinh được danh sách step `HTTP_REQUEST` ban đầu.

---

## 10. Ưu tiên triển khai & câu trả lời trực tiếp

**Đối với môn Lập trình Web hiện tại**, tôi khuyên thực hiện theo thứ tự:

1. **Phase 4** (Virtual Threads + Dynamic Faker) — backend, nhanh, giá trị cao, chống block IO và hardcode.
2. **Phase 5** (DB Isolation Sandbox) — backend, phức tạp hơn, cần test container thực.
3. **Phase 6** (Dry-Run Mode) — backend + API, giúp lecturer kiểm thử config.
4. **Phase 1–3** (Assertion, VariableContext, Loop/Header/ANY_OF) — có thể xen kẽ với Phase 4–6, không phụ thuộc nhiều vào nhau.
5. **Phase 7** (Visual Editor, JSON Schema, Postman Import) — frontend-heavy, làm cuối cùng khi API config ổn định.

**Tính năng cấp thiết nhất:** B6 (auto_inject_headers cấp Plan) + C8 (Loop Safety Governor) + D10 (toán tử so sánh) + A4 (fallback biến). Bộ này giải quyết ngay bài toán kinh điển: tạo nhiều data → login lấy token → filter/search → chống hardcode.

---

## 11. Lưu ý cập nhật tài liệu (bắt buộc theo AGENTS.md)

Khi triển khai bất kỳ phase nào thay đổi cấu hình hoặc API client-facing, phải cập nhật:

| File | Nội dung cần bổ sung |
|------|---------------------|
| `docs/design/grading-config-reference.md` | Bảng trường step mới (`data[]`, `auto_inject_headers`, `fallback`, `as`); assertion kinds mới (`array_length`, `contains_item`, `greater_than`, `less_than`, `matches_regex`, `any_of`); extract `as: "json"`, built-in `${$UUID}`, `${$TIMESTAMP}`, `${$FAKER_*}`. |
| `docs/design/http-test-plan-config.md` | Schema config mới, runtime behavior (truncate loop 20 phần tử, virtual thread, DB sandbox, dry-run). |
| `docs/design/usecase-flows.md` | Section **UC-03** (Lecturer authors grading exercises — plans & steps): thêm flow login + auto-inject header, flow tạo nhiều data với `data[]`, flow filter/search, flow dry-run. |
| `.opencode/skills/` và `.kilo/skills/` | Nếu thêm convention mới (ví dụ cách viết step data-driven, cách dùng Faker), cập nhật skill file giữ identical giữa 2 thư mục (theo AGENTS.md convention maintenance). |

---

## 12. File tham chiếu mã nguồn (đã xem xét trong nghiên cứu)

- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/step/impl/HttpStepExecutor.java` (lines 54–176)
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/scoring/VariableContext.java` (lines 17–61)
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/scoring/AssertionEngine.java` (lines 42–237)
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/service/step/StepContext.java` (lines 16–53)
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/Constant.java` (full)
- `src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/entity/GradingStepResult.java` (lines 21–101)
- `src-services/course-service/src/main/java/vn/edu/ptit/web_grading_system/course_service/service/StepConfigValidator.java` (lines 37–210)
- `src-services/course-service/src/main/java/vn/edu/ptit/web_grading_system/course_service/entity/TestStep.java` (lines 21–57)
- `src-services/course-service/src/main/java/vn/edu/ptit/web_grading_system/course_service/entity/TestPlan.java` (lines 24–41)
- `docs/api/scenarios/exercise-steps.sh` (ví dụ payload thực tế EXS-05)

---

Kết thúc kế hoạch. Khi bạn sẵn sàng chuyển sang agent Implement, hãy chọn phase muốn bắt đầu (khuyên là **Phase 4** hoặc **Phase 4 + Phase 1 kết hợp**) để tôi tiếp tục chi tiết file cần sửa và test case.