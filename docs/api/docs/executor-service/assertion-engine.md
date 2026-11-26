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