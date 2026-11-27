# VariableContext — executor-service

Nơi lưu: `docs/api/docs/executor-service/variable-context.md`

Mục đích: giải thích kho biến của một job chấm, cách thay `${...}`, biến động `$UUID`/
`$FAKER_*`, truy cập sâu vào JSON, và các quy ước khi biến thiếu.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.scoring` |
| Loại | `public class` (không phải bean) — orchestrator tạo mới cho mỗi job |
| Lưu trữ | `ConcurrentHashMap<String, Object>` |
| Ai dùng | Ba executor DB, `HttpStepExecutor`, `AssertionEngine` |

## 2. API cơ bản

| Method | Ý nghĩa |
|---|---|
| `put(name, value)` | Ghi biến; value là `Object` (String, số, list/map từ JSON) |
| `get(name)` | Đọc thô, `null` nếu chưa có |
| `snapshot()` | `Map.copyOf` — bản chụp để đẩy sang kết quả/log |
| `substitute(template)` | Thay mọi `${...}` |

## 3. `substitute(String template)`

Regex `\$\{([^}]+)}`. Với từng match:

1. `resolveToken(token)`.
2. `null` → log warn `VARIABLE_NOT_FOUND` và thay bằng **chuỗi rỗng** (không giữ nguyên
   `${...}`, không ném lỗi).
3. Có giá trị → `Matcher.quoteReplacement` để `$`/`\` trong giá trị không bị hiểu là group.

`template == null` → trả `null`.

## 4. `resolveToken` — ba nhánh

### 4.1 Biến động (`$`-prefix)

| Token | Giá trị |
|---|---|
| `$UUID` | `UUID.randomUUID()` |
| `$TIMESTAMP` | `System.currentTimeMillis()` |
| `$FAKER_NAME` | Tên ngẫu nhiên từ mảng họ + tên đệm |
| `$FAKER_BOOK_TITLE` | Tựa sách + ` @<4 chữ số>` |
| `$FAKER_WORD` | Một từ trong danh sách |
| `$FAKER_EMAIL` | `<word><0-9999>@<domain>` |
| `$FAKER_*` khác | `faker-<0-99999>` (fallback để không làm hỏng bước) |

Biến động **không bao giờ được lưu** — mỗi lần thay sinh giá trị mới. Vì vậy cùng một
`${$UUID}` xuất hiện hai lần trong một template sẽ ra hai UUID khác nhau; muốn dùng lại thì
phải `extract` vào biến thường.

### 4.2 Truy cập sâu `base[...]`

`bracketIdx = token.indexOf('[')`; nếu > 0: `baseName` trước `[`, `nav` từ `[` trở đi.

- Base không tồn tại → `null` → thay rỗng.
- Nếu base là `String`, dùng nguyên chuỗi làm JSON; nếu là object/list, serialize bằng Gson.
- `JsonPath` với `Option.SUPPRESS_EXCEPTIONS` đọc `nav` (ví dụ `[0].id`).
- Lỗi navigate → warn, `null`.
- Kết quả stringify bằng `String.valueOf`.

Ví dụ: `extract as: "json"` lưu `[{"id":7}]` vào `books`; `${books[0].id}` → `7`.

### 4.3 Biến thường

`String.valueOf(value)`; không có → `null`.

## 5. Faker — vì sao tự cài

Không phụ thuộc thư viện ngoài; mảng dữ liệu cố định + `Random` của instance. Hệ quả: dữ
liệu không đa dạng như Faker thật nhưng đủ để test form/validate, và không thêm dependency
vào image executor.

## 6. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| `${missing}` | Chuỗi rỗng + warn |
| `${books[9].id}` ngoài phạm vi | JsonPath trả null → rỗng + warn |
| `${arr}` với arr là list | `String.valueOf(list)` → `[a, b]` (không phải JSON chuẩn) |
| Giá trị chứa `$1` | Được quote, không bị hiểu là backreference |
| Dùng chung giữa nhiều thread | `ConcurrentHashMap`, an toàn từng thao tác; không có giao dịch nhiều bước |

## 7. Liên kết

- `StepContext.variableContext` mang nó qua các bước.
- `HttpStepExecutor` ghi biến từ `extract[]`; `AssertionEngine` đọc để so sánh.
- Hằng số tên biến: `Constant.VariableContext` (`DB_PORT`, `DYNAMIC_UUID`, …).

---

## Chi tiết từng hàm

### `void put(String name, Object value)`

Ghi vào `ConcurrentHashMap` (job chấm chạy một luồng nhưng vẫn an toàn nếu tương lai chạy
song song). Không kiểm tra tên: `null` key sẽ NPE — orchestrator chỉ `put` tên lấy từ
`extract[].name` đã validate.

### `Object get(String name)`

Trả giá trị gốc (có thể là `Map`/`List` khi `extract as: json`), không stringify — nhờ vậy
`${books[0].id}` mới hoạt động. Không có → `null`.

### `Map<String,Object> snapshot()`

`Map.copyOf(variables)` — bản sao bất biến tại thời điểm gọi, dùng để lưu vào
`GradingStepResult.extractedVariables`/`extract_result` mà không lộ map sống.

### `String substitute(String template)`

| Khía cạnh | Nội dung |
|---|---|
| Input | chuỗi có `${...}` hoặc null |
| Output | chuỗi đã thay; null → null |

1. `VAR_PATTERN = \$\{([^}]+)\}` — mỗi `${...}` là một match riêng, nên một chuỗi có nhiều
   biến (`${a}-${b}`) được thay lần lượt; token không được lồng `${${a}}`.
2. Mỗi token: `resolveToken`; `null` → log warn `VARIABLE_NOT_FOUND`, thay bằng `""`
   (không làm hỏng URL/body).
3. Thay bằng `Matcher.quoteReplacement` để `$`/`\` trong giá trị không bị hiểu là group.
4. `appendTail` phần còn lại.

### `private String resolveToken(String token)`

1. Token bắt đầu bằng `$` (dynamic prefix) → `resolveDynamic`.
2. Có `[` ở vị trí > 0 → tách `base` + `nav`, lấy biến gốc rồi `navigateJson`; biến gốc
   không có → `null`.
3. Còn lại: tra map, `String.valueOf(value)`; không có → `null`.

### `private String resolveDynamic(String token)`

| Token | Giá trị |
|---|---|
| `$UUID` | `UUID.randomUUID().toString()` |
| `$TIMESTAMP` | `System.currentTimeMillis()` dạng chuỗi |
| `$FAKER_NAME` | tên ngẫu nhiên từ hai mảng họ/tên |
| `$FAKER_BOOK_TITLE` | tiêu đề sách + ` @` + số 1000–9999 |
| `$FAKER_WORD` | một từ trong `WORDS` |
| `$FAKER_EMAIL` | word + số 0–9999 + `@` + domain |
| `$FAKER_*` khác | `fakerFallback` → `"faker-" + random(100000)` |
| `$` khác | `null` → caller thay `""` |

Dynamic không bao giờ được lưu vào map, nên mỗi lần substitute lại sinh giá trị mới.

### `private Object navigateJson(Object base, String nav)`

1. `base` là `String` → dùng trực tiếp làm JSON; ngược lại `new Gson().toJson(base)`.
2. `JsonPath.using(jsonPathConfig).parse(json).read(nav)` với
   `Option.SUPPRESS_EXCEPTIONS`.
3. Ngoại lệ → log warn, trả `null`.

Ví dụ: `extract` lưu `books` dạng JSON string, `${books[0].id}` → `base = "books"`,
`nav = "[0].id"`.

### `private String fakerName()`

`FIRST_NAMES[random] + " " + LAST_NAMES[random]` — 8×8 tổ hợp, không phụ thuộc thư viện
faker ngoài.

### `private String fakerBookTitle()`

`BOOK_TITLES[random] + " @" + (1000 + random(9000))` — thêm hậu tố số để mỗi lần chạy tạo
tiêu đề khác nhau (tránh trùng unique constraint khi test tạo sách).

### `private String fakerWord()`

`WORDS[random]` — một trong 8 từ Hy Lạp.

### `private String fakerEmail()`

`fakerWord() + random(10000) + "@" + DOMAINS[random]` — không trùng tuyệt đối nhưng đủ cho
test.

### `private String fakerFallback(String token)`

`"faker-" + random(100000)` cho `$FAKER_*` chưa hỗ trợ, để plan dùng token lạ vẫn chạy thay
vì thành chuỗi rỗng.
