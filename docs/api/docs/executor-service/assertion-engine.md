# AssertionEngine — executor-service

Nơi lưu: `docs/api/docs/executor-service/assertion-engine.md`

Mục đích: giải thích toàn bộ engine so khớp assertion cho bước HTTP: 13 loại assertion,
ngữ nghĩa `json_path`, so sánh số/chuỗi, `any_of` lồng nhau, và cách lỗi được báo.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.scoring` |
| Annotation | `@Component` |
| Ai gọi | `HttpStepExecutor` sau mỗi request |
| Output | `List<AssertionDetail>` — mỗi phần tử là một kết quả có `kind/expected/actual/passed/message` |

Dùng Gson để so JSON và Jayway JsonPath (cấu hình `SUPPRESS_EXCEPTIONS`) để đọc field.

## 2. `AssertionDetail`

| Trường | Ý nghĩa |
|---|---|
| `kind` | Loại assertion (`status`, `contains`, `json_path`, …) |
| `expected` | Giá trị kỳ vọng (có thể là path, pattern, số, object JSON) |
| `actual` | Giá trị thực tế |
| `passed` | Kết quả |
| `message` | Thông điệp người đọc được |

## 3. `evaluateHttp(actualStatus, actualBody, config, vars)`

1. `config == null` → danh sách rỗng.
2. Nếu có `expected_status` → thêm một detail `status` (so sánh trực tiếp).
3. Nếu không có `assertions[]` (hoặc không phải array) → trả những gì đã có.
4. Lặp `assertions[]`: đọc `kind`, gọi hàm tương ứng; `kind` lạ → detail `passed = false`
   với `UNKNOWN_ASSERTION_KIND_PREFIX + kind`.

## 4. Bảng assertion

| `kind` | Field cấu hình | Logic |
|---|---|---|
| `status` | `equals` (int) | `actualStatus == expected` |
| `contains` | `text` | `actualBody.contains(text)`; body null → fail |
| `json_path` | `path`, `exists` (mặc định true) | Đọc path; `exists` tính là "khác null và list không rỗng"; so với `exists` |
| `body_equals` | `json` | Parse cả hai bằng Gson, `JsonElement.equals` |
| `body_structure` | `json` | `GsonStructureComparator.sameStructure` — chỉ so cấu trúc/kiểu, bỏ giá trị |
| `field_equals` | `path`, `equals` (string, có thể chứa biến) | Đọc path rồi `fieldEquals` |
| `array_length` | `path`, `equals` (int) | `arrayLength(result)` so với expected |
| `contains_item` | `path`, `equals` (string) | List chứa item (so `String.valueOf`) |
| `json_path_equals` | `path`, `equals` (string, có biến) | Như `field_equals` nhưng kind riêng |
| `greater_than` | `path`, `value` | `actual > value` theo `BigDecimal`; actual không phải Number → fail |
| `less_than` | `path`, `value` | Tương tự, `<` |
| `matches_regex` | `path`, `pattern` | `String.matches(pattern)` trên `String.valueOf(result)` |
| `any_of` | `assertions[]` | Đúng nếu **ít nhất một** assertion con đúng |

## 5. Ngữ nghĩa quan trọng

### 5.1 `json_path` với `exists`

- `exists` không khai → mặc định `true`.
- Giá trị đọc được: `result != null` và (nếu là `List`) không rỗng.
- Kết quả `passed = (exists == shouldExist)` — nên `exists: false` dùng để kiểm tra field
  **không** xuất hiện.
- Ngoại lệ khi đọc path: `passed = !shouldExist`; message `JSON_PATH_CORRECTLY_NOT_FOUND`
  nếu đúng kỳ vọng không tồn tại, ngược lại message lỗi.

### 5.2 `fieldEquals` — số vs chuỗi

```text
actual == null            → false (field thiếu hoặc null đều fail)
actual là Number          → expected parse BigDecimal, so compareTo (1.0 == 1)
actual kiểu khác          → expected.equals(String.valueOf(actual)) ("00123" ≠ "123")
```

Ghi chú: review 2026-09-20, Pullfrog PR #16.

### 5.3 Biến trong expected

`field_equals` và `json_path_equals` chạy `vars.substitute(expectedRaw)` — cho phép kỳ vọng
tham chiếu biến đã extract (ví dụ `${submission_id}`). Các kind khác không thay biến.

### 5.4 `any_of`

- `assertions` rỗng/không phải array → fail với `no sub-assertions configured`.
- Duyệt con, trả ngay khi một con đúng (`ANY_OF_MATCHED`).
- `status` con trong `any_of` được gọi với `actualStatus = 0` (comment trong code: status
  không có ngữ cảnh thực trong any_of) — nên tránh đặt `status` trong `any_of`.
- Không hỗ trợ `any_of` lồng `any_of` (nhánh default coi là kind lạ → fail).

### 5.5 Regex

`String.matches` khớp **toàn bộ** chuỗi, không phải tìm chuỗi con. Muốn tìm con phải dùng
`.*pattern.*`.

## 6. Trường hợp biên

| Tình huống | Kết quả |
|---|---|
| Body không phải JSON, assertion `json_path` | JsonPath ném lỗi (bị suppress → null) → `exists=false` |
| `greater_than` với expected không parse số | Exception → fail với message lỗi path |
| `array_length` trên scalar | `arrayLength` trả 1 |
| `contains_item` trên scalar | So `String.valueOf` scalar với expected |
| `body_equals` với body null | Parse `null` literal → so với expected |
| `config.assertions` có phần tử null | `assertion.path(...)` NPE → lan ra ngoài (không bọc) |

## 7. Liên kết

- `HttpStepExecutor` gọi `evaluateHttp`, gộp detail vào `GradingStepResult`.
- `EvidenceRedactor` che `expected/actual` trước khi lưu/gửi.
- `VariableContext.substitute` cấp biến cho `field_equals`/`json_path_equals`.

---

## Chi tiết từng hàm

### `List<AssertionDetail> evaluateHttp(int actualStatus, String actualBody, JsonNode config, VariableContext vars)`

| Khía cạnh | Nội dung |
|---|---|
| Input | status thực, body thực (có thể null), config bước, context biến |
| Output | danh sách `AssertionDetail` theo thứ tự: `expected_status` trước, rồi `assertions[]` |
| Config null | trả list rỗng (coi như không có assertion) |

1. Nếu `config.expected_status` có giá trị → tạo detail `status` so bằng; message
   `STATUS_MATCHED` hoặc `Expected status X but got Y`.
2. Không có `assertions` hoặc không phải array → trả list hiện tại (chỉ có status).
3. Với từng phần tử `assertions[]`: đọc `kind`, `switch` sang hàm kiểm tương ứng; `kind` lạ →
   detail `passed = false` với `UNKNOWN_ASSERTION_KIND_PREFIX + kind` (không ném).

`evaluateHttp` **không** tự quyết định bước pass/fail — `HttpStepExecutor` kiểm
`allMatch(passed)`; nhờ vậy bước có 0 assertion vẫn `PASSED` khi request chạy được.

### `checkStatus(assertion, actualStatus)`

Đọc `equals` (int), so bằng với status thực; detail `kind = status`, expected/actual là số.

### `checkContains(assertion, actualBody)`

Đọc `text`, kiểm `actualBody != null && actualBody.contains(text)` — so chuỗi con thô,
không parse JSON, phân biệt hoa thường. Body null → fail.

### `checkJsonPath(assertion, actualBody)`

1. `path`; `shouldExist = !has(exists) || exists == true` (mặc định true).
2. `JsonPath.parse(actualBody != null ? body : "{}").read(path)`.
3. `exists = result != null && (!(result instanceof List) || list không rỗng)` — mảng rỗng bị
   coi là không tồn tại.
4. `passed = exists == shouldExist`; detail `expected = path`, `actual = result`.
5. Ngoại lệ JsonPath: `passed = !shouldExist` (path hỏng + kỳ vọng không tồn tại → pass),
   message `JSON_PATH_CORRECTLY_NOT_FOUND` hoặc lỗi.

### `checkBodyEquals(assertion, actualBody)`

So **cấu trúc JSON đầy đủ** bằng Gson: parse `assertion.json` và body (body null →
`null` JSON), so `JsonElement.equals` (thứ tự key không quan trọng với object nhưng mảng
phải cùng thứ tự). Parse lỗi → detail fail, message `BODY_EQUALS_PARSE_ERROR_PREFIX`.

### `checkBodyStructure(assertion, actualBody)`

Parse hai phía rồi `GsonStructureComparator.sameStructure(expected, actual)` — chỉ so hình
dạng (kiểu node, tập key, độ dài mảng), bỏ qua giá trị. Dùng khi chỉ cần "đúng schema".

### `checkFieldEquals(assertion, actualBody, vars)`

1. `path`, `expected = vars.substitute(assertion.equals)` (biến được thay trong giá trị kỳ
   vọng).
2. Đọc field; so qua `fieldEquals` (null → fail; Number → `BigDecimal.compareTo`, nên
   `1.0 == 1`; còn lại so chuỗi chính xác nên `"00123" != "123"`).
3. Ngoại lệ JsonPath → fail với `JSON_PATH_ERROR_PREFIX`.

### `checkArrayLength(assertion, actualBody)`

Đọc mảng tại `path`, tính độ dài qua `arrayLength`, so bằng với `equals` (int). Không phải
mảng: `arrayLength` trả 1 cho scalar, 0 cho null.

### `checkContainsItem(assertion, actualBody)`

Đọc mảng tại `path`, `containsItem` so `String.valueOf(item)` với `equals` — so chuỗi, nên
`{"id":1}` cần `equals` đúng dạng chuỗi. Scalar được coi là list 1 phần tử.

### `checkJsonPathEquals(assertion, actualBody, vars)`

Như `checkFieldEquals` nhưng `kind = json_path_equals`; dùng khi giảng viên muốn nêu rõ
đang so JsonPath (khác biệt chủ yếu ở nhãn hiển thị).

### `checkGreaterThan(assertion, actualBody)` / `checkLessThan(...)`

1. `expected = new BigDecimal(assertion.value)` — không substitute biến (khác
   `field_equals`).
2. Giá trị tại `path` không phải `Number` → fail với message "value is not a number".
3. So `BigDecimal.compareTo` với `> 0` (hoặc `< 0`). `expected` không parse được → nhánh
   catch, fail với `JSON_PATH_ERROR_PREFIX`.

### `checkMatchesRegex(assertion, actualBody)`

Đọc `pattern`, lấy chuỗi tại `path` (`null` → `""`), `actualStr.matches(pattern)` —
**khớp toàn chuỗi**, không phải `find()`; muốn khớp một phần phải viết `.*pattern.*`.

### `checkAnyOf(assertion, actualBody, vars)`

1. `assertions` con rỗng/không phải array → fail "no sub-assertions configured".
2. Duyệt từng sub, `switch` như `evaluateHttp`; `status` con dùng `actualStatus = 0` vì
   không có status thật trong ngữ cảnh này (ghi rõ trong chú thích mã).
3. Sub đầu tiên pass → trả `passed = true`, message `ANY_OF_MATCHED` (không chạy tiếp).
4. Không sub nào pass → fail "none of the sub-assertions passed".
5. `any_of` **không** lồng `any_of` (không có case) — sub `any_of` rơi vào default → fail.

### `private int arrayLength(Object result)`

`null` → 0; `List` → `size()`; `Object[]` → `length`; còn lại → 1.

### `private boolean containsItem(Object result, String expected)`

`null` → false; `List` → duyệt, so `expected.equals(String.valueOf(item))`; scalar → so
chuỗi trực tiếp.

### `private boolean fieldEquals(String expected, Object actual)`

| Kiểu actual | Cách so |
|---|---|
| null | luôn `false` (field thiếu hoặc JSON null không bao giờ khớp) |
| `Number` | `new BigDecimal(expected).compareTo(new BigDecimal(actual)) == 0`; parse lỗi → `false` |
| khác | `expected.equals(String.valueOf(actual))` |

Chủ ý: `1.0` khớp `1` (số), nhưng `"00123"` không khớp `"123"` (chuỗi). Review 2026-09-20,
Pullfrog PR #16.

### `private static String safeMessage(Exception e)`

`getMessage()` nếu có, ngược lại `toString()`. Tránh NPE khi dựng message lỗi từ exception
không có message.
