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