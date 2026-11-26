# HttpStepExecutor — executor-service

Nơi lưu: `docs/api/docs/executor-service/http-step-executor.md`

Mục đích: giải thích bước `HTTP_REQUEST` — dựng URL, gửi request trên virtual thread, đánh
giá assertion, trích biến, ghi log HTTP, và vòng lặp `data[]` gộp kết quả.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.step.impl` |
| Annotation | `@Component`, `@RequiredArgsConstructor`, `@Slf4j` |
| `type()` | `Constant.HttpStep.HTTP_REQUEST` (`HTTP_REQUEST`) |
| Phụ thuộc | `HttpLogService`, `AssertionEngine`, `HttpClient` (bean) |
| Executor riêng | `Executors.newVirtualThreadPerTaskExecutor()` cho `sendAsync().join()` |

## 2. Cấu hình bước

| Trường | Mặc định | Ý nghĩa |
|---|---|---|
| `method` | `GET` | `GET/POST/PUT/PATCH/DELETE/HEAD` |
| `path` | `/` | Path trên app sinh viên; có thể chứa `${var}` |
| `query_params` | — | Object name → value, value có thể chứa `${var}` |
| `headers` | — | Object header → value, value có thể chứa `${var}` |
| `body` | — | Chuỗi JSON; `toString()` của node rồi thay biến |
| `timeout_ms` | `ctx.timeoutMs` hoặc 30.000 | Timeout request |
| `expected_status` | — | Assertion status tự động |
| `assertions[]` | — | Danh sách assertion cho `AssertionEngine` |
| `extract[]` | — | Trích biến từ response |
| `data[]` | — | Nếu có, chạy bước một lần cho mỗi dòng |

Port app lấy từ `VariableContext` key `APP_PORT`; URL luôn `http://localhost:<port><path>`
(executor chạy cùng pod với container app).

## 3. `execute(ctx)` — hai nhánh

```text
data[] tồn tại, là array, size > 0 → executeDataLoop
ngược lại                      → executeSingle
```

## 4. `executeSingle(ctx)`

### 4.1 Dựng request

1. `method`/`path`: thay biến, rỗng thì dùng mặc định.
2. `query_params`: với từng cặp, thay biến ở value, encode cả key lẫn value bằng
   `encodeQueryComponent`; nối `?` hoặc `&`.
3. `headers`: thay biến, đưa vào map.
4. `body`: nếu có, `config.get("body").toString()` rồi thay biến — nhờ vậy body JSON giữ
   cấu trúc và biến nằm trong chuỗi vẫn được thay.
5. `timeoutMs`.

### 4.2 Gửi

`HttpRequest.newBuilder().uri(URI.create(url)).timeout(...)`; chọn method:

| Method | Publisher |
|---|---|
| `POST` | `ofString(body)` hoặc `noBody()` |
| `PUT` | như POST |
| `PATCH` | `method("PATCH", publisher)` |
| `DELETE` | `DELETE()` (body bị bỏ) |
| `HEAD` | `method("HEAD", noBody())` |
| khác | `GET()` |

Header `Content-Type: application/json` chỉ thêm khi có body và caller chưa khai.

Gửi bằng `virtualThreadExecutor.submit(() -> httpClient.sendAsync(...).join()).get()`:
caller (platform thread) được giải phóng khi chờ; app sinh viên treo chỉ park virtual
thread. `get()` chờ kết quả, exception bị `ExecutionException` bọc và được `safeMessage` mở.

### 4.3 Sau response

1. `assertionDetails = assertionEngine.evaluateHttp(status, body, config, vars)`.
2. `allPassed = details rỗng hoặc mọi passed`.
3. `extract[]`: với từng phần tử:

| Field | Mặc định | Ý nghĩa |
|---|---|---|
| `name` | — | Tên biến |
| `from` | `body` | Nguồn (hiện chỉ dùng body) |
| `expression` | — | JsonPath |
| `as` | `scalar` | `json` → serialize bằng Gson (giữ list/object cho truy cập sâu) |
| `fallback` | — | Giá trị khi path không khớp |

   - `val == null` → dùng `fallback` hoặc `""`.
   - `as = json` → `gson.toJson(val)`.
   - Ngược lại `String.valueOf(val)`.
   - `put(name, strVal)` vào `VariableContext`; ghi vào map `extracted`.
   - JsonPath ném lỗi → cũng dùng fallback/`""`, log warn `EXTRACT_FAILED`, **không** làm
     hỏng bước.
4. `status = PASSED/FAILED`; `assertionJson = gson.toJson(details)`;
   `extractedJson` null nếu không extract gì.
5. `buildResult(...)`.

### 4.4 Nhánh lỗi

Bất kỳ exception → log warn `HTTP_STEP_FAILED`, `buildResult(ERROR, ...)` với
`assertionResult = "[]"`, không có extracted.

## 5. `executeDataLoop(ctx)`

1. Gom `data[]` thành list; `limit = min(size, Constant.Loop.FOREACH_TRUNCATE)` — vượt thì
   log warn và cắt (loop safety governor, tránh hàng nghìn request).
2. Với `i` trong `0..limit-1`:
   - `replacements`: `index = i`, cộng từng field của row (stringify).
   - `iterConfig = substituteDataVars(config, replacements)` — thay `${key}` trong mọi
     textual node, deep copy.
   - `iterCtx = ctx.withConfig(iterConfig)` — dùng chung `VariableContext`.
   - `executeSingle(iterCtx)`.
   - Gộp `assertionResult` (array) vào mảng chung; gộp `extractedVariables` (object) vào
     object chung.
   - Cập nhật `overall`: `ERROR` thắng tất cả; `FAILED` chỉ ghi khi chưa `ERROR`.
3. Kết quả cuối: một dòng `GradingStepResult` với:
   - `status = overall`.
   - Metadata HTTP (url, headers, body, status code) lấy từ **lần lặp cuối**.
   - `assertionResult` gộp mọi lần; `extractedVariables` gộp mọi lần.
   - `expectedStatusCode` lấy từ config gốc.
   - `durationMs` tính từ đầu vòng lặp.
   - `stackTrace` trích từ `errorMessage` của lần cuối.

Hệ quả: điểm bước là pass/fail tổng; log HTTP vẫn có một dòng cho **mỗi** lần lặp vì
`executeSingle` tự ghi.

## 6. Helper

| Helper | Vai trò |
|---|---|
| `encodeQueryComponent` | `URLEncoder` UTF-8 rồi đổi `+` → `%20`; value đã escape sẵn sẽ bị escape lần hai (giảng viên không được pre-encode) |
| `substituteDataVars` | Deep copy, thay `${key}` trong textual node |
| `cutForLog` | Cắt body > 20.000 ký tự + hậu tố `...(truncated 20000/<len>)` |
| `extractSqlQueries` | Regex bắt `statement:`/`Hibernate:` + SELECT/INSERT/UPDATE/DELETE từ log app |
| `extractStackTrace` | Regex tìm `at ...(...:line)` hoặc `Exception:`; cắt 10.000 ký tự |
| `safeMessage` | Bóc `ExecutionException`/`CompletionException` để lấy message gốc |

## 7. `buildResult(...)`

1. Tạo `HttpLog` (service `executor-service`, direction `OUTBOUND`, method, url, port,
   headers/body request, status/headers/body response, duration) với body đã `cutForLog`, lưu
   qua `httpLogService.save` trong try/catch (lỗi log chỉ warn).
2. `stackTrace`: nếu response/actual status >= 500 → `extractStackTrace(respBody)`; nếu vẫn
   null và có `err` → `extractStackTrace(err)`.
3. Build `GradingStepResult` đầy đủ (status, request/response, expected, extracted,
   assertions, error, stackTrace, duration, startedAt/completedAt).

Lưu ý: log HTTP phía operator **không** bị che — khác bằng chứng gửi sinh viên (đã qua
`EvidenceRedactor` ở đường khác).

## 8. Trường hợp biên

| Tình huống | Kết quả |
|---|---|
| Path chứa khoảng trắng/ký tự Unicode | `encodeQueryComponent` chỉ áp cho query; path vẫn có thể làm `URI.create` ném lỗi → `ERROR` |
| `query_params` value null | `encodeQueryComponent(null)` → `""` |
| `body` là object JSON | `toString()` giữ JSON, thay biến trong chuỗi |
| `DELETE` kèm body | Body bị bỏ qua |
| App trả 500 | Assertion quyết định pass/fail; stackTrace được trích |
| `data[]` rỗng | Rơi về `executeSingle` (điều kiện size > 0) |
| `data[]` toàn lỗi | `overall = ERROR`, metadata lấy từ lần cuối |
| Response quá lớn | Body trong `http_logs` bị cắt 20.000; `GradingStepResult.responseBody` giữ nguyên |

## 9. Liên kết

- `assertion-engine.md`, `evidence-redactor.md`, `http-log-service.md`, `variable-context.md`.
- `GradingOrchestrator` gọi executor qua `StepRegistry` — xem `grading-orchestrator.md`.