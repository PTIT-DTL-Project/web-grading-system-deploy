# HttpStepExecutor — executor-service

Nơi lưu: `docs/api/docs/executor-service/http-step-executor.md`

Mục đích: giải thích **từng hàm** của bước `HTTP_REQUEST` — executor quan trọng nhất của
tầng chấm điểm: dựng URL, gửi request trên virtual thread, đánh giá assertion, trích biến,
ghi log HTTP, và vòng lặp `data[]` gộp kết quả.

---

## 0. Tổng quan lớp

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.step.impl` |
| Annotation | `@Component`, `@RequiredArgsConstructor`, `@Slf4j` |
| `type()` | `Constant.HttpStep.HTTP_REQUEST` (`HTTP_REQUEST`) |
| Phụ thuộc inject | `HttpLogService`, `AssertionEngine`, `HttpClient` |

### Trạng thái khởi tạo (field final)

| Field | Vai trò |
|---|---|
| `virtualThreadExecutor` | `Executors.newVirtualThreadPerTaskExecutor()` — chạy `sendAsync().join()` trên virtual thread |
| `jsonPathConfig` | Jayway `Configuration` với `Option.SUPPRESS_EXCEPTIONS` — path sai trả null thay vì ném |
| `gson` | Serialize assertion/extracted/headers sang JSON |
| `objectMapper` | Jackson 3 cho `data[]`: clone config, parse kết quả từng vòng |

### Danh mục hàm

| Hàm | Kiểu | Vai trò |
|---|---|---|
| `type()` | public | Trả `HTTP_REQUEST` cho `StepRegistry` |
| `execute(ctx)` | public | Điểm vào; chọn single hay `data[]` loop |
| `executeSingle(ctx)` | private | Một request đầy đủ: dựng → gửi → assert → extract → kết quả |
| `encodeQueryComponent(value)` | private static | Percent-encode query name/value |
| `executeDataLoop(ctx)` | private | Lặp request theo `data[]`, gộp kết quả |
| `substituteDataVars(node, replacements)` | private | Deep copy + thay `${key}` trong textual node |
| `cutForLog(body)` | private static | Cắt body 20.000 ký tự cho `http_logs` |
| `buildResult(...)` | private | Tạo `HttpLog` + `GradingStepResult` |
| `extractSqlQueries(logContent)` | public static | Bắt câu SQL từ log app |
| `extractStackTrace(responseBody)` | public static | Trích stack trace từ body/lỗi |
| `safeMessage(t)` | private static | Bóc `ExecutionException`/`CompletionException` |

---

## 1. `String type()`

| Khía cạnh | Nội dung |
|---|---|
| Input | không |
| Output | `Constant.HttpStep.HTTP_REQUEST` (chuỗi `HTTP_REQUEST`) |
| Ai dùng | `StepRegistry` gom map `type → executor`; orchestrator tra khi gặp bước loại này |

Trả hằng số, không đọc config. Trùng `type()` với executor khác làm ứng dụng không khởi
động (xem `step-registry.md`).

## 2. `GradingStepResult execute(StepContext ctx)`

| Khía cạnh | Nội dung |
|---|---|
| Input | `ctx` — config bước + `VariableContext` |
| Output | luôn một `GradingStepResult` (kể cả khi lỗi) |
| Quyết định | `data[]` tồn tại, là array, `size() > 0` → `executeDataLoop`; ngược lại `executeSingle` |

Điều kiện dùng `hasNonNull(...).isArray()` trước `size()` để tránh NPE khi `data` là
object/chuỗi cấu hình sai. `data: []` rơi về single, không phải loop 0 lần.

## 3. `executeSingle(StepContext ctx)` — một request

### 3.1 Chuẩn bị biến cục bộ

`start` (millis), `startedAt`, `attemptStatus = 0`, `responseBody = null`,
`responseHeaders = Map.of()`, `errorMessage = null`, `assertionDetails = List.of()` — các
biến này quyết định nhánh kết quả khi lỗi giữa chừng.

### 3.2 Dựng URL

1. `method` = `config.method` → substitute biến; rỗng → `GET`.
2. `rawPath` = `config.path` → substitute; rỗng → `/`.
3. `url = "http://localhost:" + vars.get(APP_PORT) + rawPath`.
   - `APP_PORT` do orchestrator đặt sau khi container app lên; thiếu → URL chứa `null` và
     `URI.create` sẽ ném lỗi ở bước gửi.
4. `query_params` (nếu là object): mỗi cặp → substitute value, encode **cả key và value**
   qua `encodeQueryComponent`, nối `&`; nếu path đã có `?` thì nối `&`, không thì `?`.

Encode ở đây là bắt buộc: `URI.create` từ chối khoảng trắng và ký tự non-ASCII, nên title
`"The Little Prince"` hay `"Dế Mèn"` từng làm bước fail trước khi gửi request
(review 2026-10-29, mock book-app).

### 3.3 Headers và body

- `headers` (object): substitute từng value, giữ nguyên tên header.
- `body`: nếu `hasNonNull(body)` → `config.get(body).toString()` rồi substitute — nhờ vậy
  body JSON giữ nguyên cấu trúc, biến nằm trong chuỗi vẫn được thay.

### 3.4 Timeout

`config.timeout_ms` → `ctx.timeoutMs` → 30.000 ms (`asInt` của Jackson 3 nhận default).

### 3.5 Gửi request

1. `HttpRequest.newBuilder().uri(URI.create(url)).timeout(Duration.ofMillis(timeoutMs))`.
2. `method.toUpperCase()` rồi switch: `POST`/`PUT` dùng `publisher`; `PATCH` và `HEAD` dùng
   `builder.method(...)`; `DELETE` bỏ body; còn lại `GET`.
3. `publisher` = `ofString(bodyStr)` nếu có body, ngược lại `noBody()`.
4. `headers.forEach(builder::header)`; nếu có body và chưa khai `Content-Type` → thêm
   `application/json`.
5. Gửi:

```java
virtualThreadExecutor.submit(() ->
    httpClient.sendAsync(builder.build(), BodyHandlers.ofString()).join()).get()
```

- `sendAsync` không block thread nền; `.join()` chờ kết quả trên virtual thread.
- Caller (platform thread của pool chấm) chỉ block ở `Future.get()` — một app treo chỉ
  park virtual thread, không chiếm platform thread.
- `get()` bọc lỗi trong `ExecutionException`; `safeMessage` mở ra ở nhánh catch.

### 3.6 Sau response

1. Lưu `attemptStatus`, `responseBody`; headers gộp nhiều giá trị bằng `", "`.
2. `assertionDetails = assertionEngine.evaluateHttp(status, body, config, vars)`.
3. `allPassed = details.isEmpty() || mọi passed` — không có assertion nào nghĩa là chỉ cần
   request thành công.
4. `extract[]` (nếu là array), mỗi phần tử:

| Field | Mặc định | Xử lý |
|---|---|---|
| `name` | — | Tên biến |
| `from` | `body` | Hiện chỉ dùng body |
| `expression` | — | JsonPath đọc trên `responseBody` (null → `"{}"`) |
| `as` | `scalar` | `json` → `gson.toJson(val)`, ngược lại `String.valueOf(val)` |
| `fallback` | — | Dùng khi `val == null` hoặc JsonPath ném lỗi |

   - Luôn `vars.put(name, strVal)` và ghi vào map `extracted` (kể cả khi dùng fallback/`""`).
   - Lỗi JsonPath → log warn `EXTRACT_FAILED`, dùng fallback/`""`, **không** làm bước `ERROR`.
5. `status = allPassed ? PASSED : FAILED`.
6. `assertionJson = gson.toJson(details)`; `extractedJson = null` nếu không extract gì.
7. `buildResult(ctx, status, attemptStatus, url, headers, bodyStr, attemptStatus,
   responseHeaders, responseBody, assertionJson, extractedJson, null, start, startedAt)`.

### 3.7 Nhánh lỗi

Bắt `Exception` (kể cả `URI.create` lỗi, timeout, `ExecutionException`):

1. `errorMessage = safeMessage(e)`.
2. Log warn `HTTP_STEP_FAILED` kèm tên bước.
3. `buildResult(ERROR, actualStatus = null, respStatus = null, Map.of(), null, "[]", null,
   errorMessage, ...)` — vẫn ghi `HttpLog` (request đã có thể được gửi) và trả kết quả thay
   vì ném ra ngoài.

## 4. `encodeQueryComponent(String value)`

| Khía cạnh | Nội dung |
|---|---|
| Input | chuỗi thô (null → `""`) |
| Output | percent-encoded UTF-8, space thành `%20` |

`URLEncoder.encode(value, UTF_8)` rồi `.replace("+", "%20")` — `URLEncoder` sinh `+` theo
kiểu form-urlencoded, nhưng `query_params` là URI query nên `+` sẽ bị server hiểu là dấu
cộng. Giá trị đã escape sẵn (`%20`) bị escape lần hai → giảng viên không được pre-encode.

## 5. `executeDataLoop(StepContext ctx)`

### 5.1 Chuẩn bị

1. Gom `data[]` thành `List<JsonNode>`; nếu không phải array thì danh sách rỗng.
2. `limit = min(size, Constant.Loop.FOREACH_TRUNCATE)`; vượt → log warn (loop safety
   governor, chặn giảng viên vô tình tạo hàng nghìn request trong một bước).
3. Khởi tạo `allDetailsArray`, `allExtractedObj`, `overall = PASSED`, `lastResult = null`.

### 5.2 Mỗi vòng lặp `i`

1. `replacements = {index: i}` + từng field của row (stringify).
2. `iterConfig = substituteDataVars(config, replacements)`.
3. `executeSingle(ctx.withConfig(iterConfig))` — dùng chung `VariableContext` nên biến của
   vòng trước đọc được ở vòng sau.
4. Gộp `assertionResult` (array) vào `allDetailsArray`; parse lỗi → warn, bỏ qua vòng đó.
5. Gộp `extractedVariables` (object) vào `allExtractedObj`; parse lỗi → warn.
6. Cập nhật `overall` theo thứ tự ưu tiên: `ERROR` > `FAILED` > `PASSED`.
   - Gặp `ERROR` → đặt `ERROR` vĩnh viễn (không nhánh nào hạ xuống).
   - Gặp `FAILED` khi chưa `ERROR` → `FAILED`.

### 5.3 Kết quả gộp

- `base = lastResult`; nếu `data[]` rỗng thì vòng lặp không chạy và `base` null → NPE. Thực
  tế `execute` chỉ gọi loop khi `size() > 0`, nên nhánh này không xảy ra.
- Metadata HTTP (`actualStatusCode`, `requestUrl/Headers/Body`, `response*`) lấy từ **lần
  lặp cuối**; assertion và biến gộp toàn bộ.
- `expectedStatusCode` lấy từ config gốc (không phải iterConfig).
- `stackTrace` trích từ `errorMessage` của lần cuối.
- `durationMs` tính từ đầu vòng lặp, không phải tổng từng request.

Hệ quả: một bước `data[]` chỉ tạo **một** dòng `grading_step_results`, nhưng `HttpLog` vẫn
có một dòng cho mỗi request (do `executeSingle` tự ghi).

## 6. `substituteDataVars(JsonNode node, Map<String,String> replacements)`

Đệ quy theo kiểu node:

| Kiểu | Hành vi |
|---|---|
| object | Tạo `ObjectNode` mới, đệ quy từng field |
| array | Tạo `ArrayNode` mới, đệ quy từng phần tử |
| textual | Thay lần lượt `"${" + key + "}"` bằng value, trả node mới |
| number/boolean/null | Trả nguyên node (không copy) |

Trả **deep copy** để config gốc không bị sửa giữa các vòng; replacement chỉ áp cho chuỗi,
nên `${year}` trong field JSON number phải được khai dạng chuỗi trong `data`.

## 7. `cutForLog(String body)`

`null` hoặc ≤ 20.000 ký tự → nguyên bản; dài hơn → 20.000 ký tự đầu +
`"...(truncated 20000/<độ dài gốc>)"`.

Marker dùng chung với result-service (phase A3) để người đọc biết body đã bị cắt. Log phía
operator **không** bị redact (khác bằng chứng gửi sinh viên).

## 8. `buildResult(...)`

### 8.1 Ghi `HttpLog`

1. Build `HttpLog`: `serviceName = executor-service`, `direction = OUTBOUND`, `method`,
   `url`, `port` (= `APP_PORT`), request headers/body (`cutForLog`), status code
   (`respStatus` nếu có, không thì `actualStatus`), response headers/body (`cutForLog`),
   `durationMs`.
2. `httpLogService.save(...)` trong try/catch — lỗi lưu log chỉ warn `HTTP_LOG_SAVE_FAILED`,
   không làm hỏng kết quả bước.

### 8.2 Stack trace

`respStatus >= 500` hoặc `actualStatus >= 500` → `extractStackTrace(respBody)`; nếu null và
có `err` → `extractStackTrace(err)`.

### 8.3 `GradingStepResult`

Build đầy đủ: job/plan/step, `stepType = type()`, status, actual/expected status code,
request & response (headers/body lưu **nguyên bản**, không cắt — chỉ `HttpLog` bị cắt),
`extractedVariables`, `assertionResult`, `errorMessage`, `stackTrace`, `durationMs`,
`startedAt`, `completedAt`.

## 9. `extractSqlQueries(String logContent)` — `public static`

| Khía cạnh | Nội dung |
|---|---|
| Input | log app (có thể null/blank) |
| Output | `List<String>` các dòng SQL, rỗng nếu không có |

Regex `(?i)(statement:\s*|Hibernate:\s*)(SELECT|INSERT|UPDATE|DELETE)\b.*` (MULTILINE),
gom `matcher.group().trim()`. Dùng khi app sinh viên log SQL/Hibernate để hiển thị bằng
chứng; không phân tích cú pháp, chỉ bắt dòng.

## 10. `extractStackTrace(String responseBody)` — `public static`

| Khía cạnh | Nội dung |
|---|---|
| Input | body response hoặc error message (null/blank → null) |
| Output | stack trace (tối đa 10.000 ký tự) hoặc null |

Regex `(?s)(?:at\s+[\w\.$_]+\(.*?:\d+\)|Exception:.*)`; nếu match → trả body (cắt
10.000 ký tự) vì body thường chỉ gồm stack trace; không match → null.

## 11. `safeMessage(Throwable t)` — `private static`

Bóc liên tiếp `ExecutionException`/`CompletionException` để lấy cause gốc (do
`sendAsync().join()` bọc checked exception). Cause null → `"Unknown error"`; message null →
`root.toString()`.

## 12. Trường hợp biên tổng hợp

| Tình huống | Kết quả |
|---|---|
| Path chứa khoảng trắng/non-ASCII (không qua query) | `URI.create` ném lỗi → `ERROR` (path không được encode) |
| `query_params` value null | `encodeQueryComponent(null)` → `""` |
| `body` là object JSON | `toString()` giữ JSON, substitute trong chuỗi |
| `DELETE` kèm body | Body bị bỏ |
| App trả 500 | Status assertion quyết định; stack trace được trích |
| `data[]` rỗng | Rơi về `executeSingle` |
| `data[]` toàn lỗi | `overall = ERROR`, metadata lần cuối |
| Response quá lớn | `http_logs` cắt 20.000; `GradingStepResult.responseBody` giữ nguyên |
| `APP_PORT` chưa có | URL `.../null...` → lỗi gửi → `ERROR` |

## 13. Liên kết

- `assertion-engine.md` — 13 loại assertion và ngữ nghĩa so khớp.
- `evidence-redactor.md` — che bằng chứng ở đường gửi sinh viên.
- `http-log-service.md` — lưu/che log HTTP (khác lớp này: log operator không redact).
- `variable-context.md` — `substitute`, `put`, `APP_PORT`.
- `grading-orchestrator.md` — nơi gọi executor qua `StepRegistry`.