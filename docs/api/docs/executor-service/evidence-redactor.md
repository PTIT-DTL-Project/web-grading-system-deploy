# EvidenceRedactor — executor-service

Nơi lưu: `docs/api/docs/executor-service/evidence-redactor.md`

Mục đích: giải thích bộ che dữ liệu nhạy cảm duy nhất cho mọi bằng chứng chấm điểm gửi
tới sinh viên: che theo key JSON, đi xuống chuỗi JSON lồng nhau, quét token dạng văn bản,
và nguyên tắc fail-closed.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.scoring` |
| Loại | `public final class`, constructor private, toàn bộ static |
| Ai gọi | `HttpStepExecutor` (request/response/vars), đường ghi `GradingStepResult` |
| Nguyên tắc | Một hàm `redact`, áp ở mọi đầu ra; lỗi nội bộ → `"***"` |

## 2. `redact(String input)`

| Input | Output |
|---|---|
| `null` | `null` |
| Chuỗi blank | nguyên bản (không biến thành mask) |
| Nội dung thật | chuỗi đã che, hoặc `"***"` nếu có lỗi bất kỳ (`Throwable`) |

Việc giữ nguyên blank/null quan trọng vì hàm được gọi trên mọi phía `extract[]`, kể cả phía
không tồn tại; biến field rỗng thành `***` sẽ gây hiểu nhầm.

## 3. `redactJsonAware(input)`

1. `MAPPER.readTree(input)` — nếu parse được:
   - `maskNode(tree, dirty)` che theo cấu trúc.
   - Nếu `dirty[0]` thì serialize lại; **nếu không có gì bị che thì trả nguyên chuỗi gốc**
     (byte-identical passthrough — không đổi format/thứ tự key của JSON sạch).
2. Nếu không parse được (văn bản thường): `sweep(input)`.
3. Luôn chạy `sweep` trên kết quả cuối để bắt token nằm trong chuỗi.

## 4. Che theo key — `maskNode`

Với `ObjectNode`: duyệt snapshot `new ArrayList<>(obj.properties())` (Jackson 3 ném lỗi nếu
`set()` trong lúc duyệt view sống), mỗi key lowercase:

- Thuộc `SECRET_KEYS` → thay value bằng `"***"`, đánh dấu dirty.
- Ngược lại: thử `maskNestedString(value)`; nếu không phải chuỗi JSON thì đệ quy tiếp.

`SECRET_KEYS` (khớp chính xác, không so chuỗi con): `password`, `passwd`, `pwd`,
`authorization`, `secret`, `token`, `api_key`, `apikey`, `api-key`, `access_token`,
`accesstoken`, `access-token`, `client_secret`, `clientsecret`, `auth_token`, `authtoken`,
`auth-token`, `refresh_token`, `refreshtoken`, `id_token`, `idtoken`, `private_key`,
`privatekey`.

Vì sao khớp chính xác: so chuỗi con sẽ che nhầm field hợp lệ như `tokens` (số token dùng
trong bài). Các dạng tự do (`Bearer ...`, `token=...`, JDBC URL) do `sweep` xử lý.

Với `ArrayNode`: phần tử object/array đệ quy; phần tử vô hướng thử `maskNestedString`,
nếu là chuỗi JSON thì thay bằng bản đã che.

## 5. `maskNestedString` — chuỗi JSON lồng

Ví dụ: `verdict` bên trong mảng assertion là một chuỗi chứa JSON đã escape; regex sweep
không nhìn xuyên qua escape. Hàm này:

1. Chỉ xử lý `isTextual()`; trim phải bắt đầu `{` hoặc `[`.
2. Parse lại; phải là object/array.
3. Che đệ quy; nếu không có gì đổi → trả `null` (giữ nguyên byte gốc).
4. Có đổi → serialize lại thành chuỗi.

## 6. `sweep` — quét văn bản

Ba pattern, thay theo thứ tự:

| Pattern | Ví dụ | Kết quả |
|---|---|---|
| `\b(Bearer\|Basic)\s+[A-Za-z0-9\-._~+/=]+` | `Bearer eyJhbGci...` | `Bearer ***` |
| `(?i)(password\|passwd\|secret\|token)\s*[:=]\s*[^\s&]+` | `token=abc&x=1` | `token=***&x=1` |
| `(://[^:/\s]+:)[^/\s]*(@)` | `jdbc:mysql://u:p@ss@host/db` | `jdbc:mysql://u:***@host/db` |

Ghi chú trong code: `[^\s&]+` (không phải `\S+`) để một secret query param không "ăn"
các param vô tội phía sau. Pattern JDBC khớp tới `@` **cuối cùng** trước `/`, nên mật khẩu
chứa `@` vẫn được che; mật khẩu chứa `/` nằm ngoài khả năng (đã ghi trong tài liệu phase).

## 7. Không giới hạn độ sâu

Cố ý: độ sâu bám theo input hữu hạn; input bệnh lý sẽ fail-closed qua catch-all `Throwable`
→ `"***"`. Nhờ vậy không có nhánh nào trả về dữ liệu chưa che khi lỗi.

## 8. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| JSON sạch | Trả nguyên chuỗi gốc (không reformat) |
| Key `Token` viết hoa | Lowercase trước khi so → bị che |
| Field tên `tokens` | Không bị che (khớp chính xác) |
| Chuỗi JSON lồng không parse được | Giữ nguyên, sweep vẫn chạy |
| Lỗi bất kỳ trong quá trình | `"***"` |

Xem thêm: `http-log-service.md` (che log HTTP), `http-step-executor.md` (nơi gọi).