# DbSchemaCheckExecutor — executor-service

Nơi lưu: `docs/api/docs/executor-service/db-schema-check-executor.md`

Mục đích: giải thích bước `DB_SCHEMA_CHECK`: bốn loại kiểm tra schema, cách dùng SQL của
dialect, cách gộp kết quả thành `AssertionDetail`, và giới hạn thời gian chung.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.step.impl` |
| Annotation | `@Component`, `@RequiredArgsConstructor` |
| `type()` | `Constant.DbStep.TYPE_SCHEMA_CHECK` (`DB_SCHEMA_CHECK`) |
| Phụ thuộc | `DbConnectionHelper`, `ObjectMapper` |

## 2. Cấu hình

| Trường | Ý nghĩa |
|---|---|
| `connection.*` | `db_type`, `database`, `username`, `password` |
| `timeout_ms` | Ngân sách cho toàn bộ danh sách check |
| `checks[]` | Mỗi phần tử có `kind` và tham số theo loại |

### Các `kind`

| `kind` | Tham số | Câu SQL dialect |
|---|---|---|
| `TABLE_EXISTS` | `table_name` | `tableExistsSql()` |
| `COLUMN_EXISTS` | `table_name`, `column_name`, `data_type` (tuỳ chọn) | `columnExistsSql()` |
| `PRIMARY_KEY` | `table_name`, `column` | `primaryKeySql()` |
| `INDEX_EXISTS` | `table_name`, `index_name` | `indexExistsSql()` |

## 3. Luồng `execute(ctx)`

1. Đọc `db_type` từ `config.connection`, lấy `hostPort` từ `VariableContext.DB_PORT`.
2. `deadline = now + timeoutMs`.
3. `db.withConnection(...)`: resolve dialect một lần qua `db.resolve(dbType)`, rồi lặp
   `checks`:
   - `remaining <= 0` → `DbStepTimeoutException(SQL_TIMEOUT_ERROR + timeoutMs + "ms")`.
   - `runCheck(conn, dialect, check, max(1, ceil(remaining/1000)))`.
4. `SQLException` → `ERROR` (message qua `DbStepResults.message`).
5. Không lỗi → `passed = mọi detail.passed` → `PASSED`/`FAILED`.

## 4. `runCheck` theo từng loại

### 4.1 `TABLE_EXISTS`

`SELECT COUNT(*) ... table_name = ?`; `ok = count > 0`. Message: `table 'x' exists` /
`table 'x' missing`. Expected luôn `true`.

### 4.2 `COLUMN_EXISTS`

Không có dòng trả về → `actualType = null` → `sameType` false → fail với message
`column 'c' is null, expected <type>`.

Có dòng: `ok = dialect.sameType(expectedType, actualType)`. Message khi đạt:
`column 'c' is <expected>`, khi hỏng: `column 'c' is <actual>, expected <expected>`.

`data_type` rỗng (`""`) vẫn được so — `sameType` trả false nếu một phía null nhưng `""`
không null; vì vậy check chỉ tồn tại cột nên khai `data_type` bỏ trống sẽ fail. Cấu hình
đúng nên bỏ hẳn key `data_type` nếu không muốn kiểm kiểu.

### 4.3 `PRIMARY_KEY`

`COUNT(*)` join constraint/key_column_usage; `ok = count > 0`. Message:
`PRIMARY KEY (c) on 't'` / `PRIMARY KEY (c) missing on 't'`.

### 4.4 `INDEX_EXISTS`

`COUNT(*)`; message `index 'i' on 't'` / `index 'i' missing on 't'`.

### 4.5 `kind` lạ

`throw new SQLException(UNKNOWN_CHECK_KIND + kind)` → toàn bộ bước `ERROR` (không phải
`FAILED`), vì đây là lỗi cấu hình chứ không phải schema sai.

## 5. Trường hợp biên

| Tình huống | Kết quả |
|---|---|
| `checks` rỗng | `details` rỗng → `PASSED` |
| Check đầu fail, check sau vẫn chạy | Có (không short-circuit) — báo đủ mọi lỗi schema |
| Timeout giữa danh sách | Các detail đã chạy vẫn được lưu, status `ERROR` |
| Cột tồn tại nhưng khác kiểu | `FAILED`, message nêu cả hai kiểu |
| Bảng ở schema khác | PG: chỉ `public`; MySQL: chỉ database hiện tại |

Xem thêm: `db-dialect.md`, `db-connection-helper.md`, `db-step-results.md`.