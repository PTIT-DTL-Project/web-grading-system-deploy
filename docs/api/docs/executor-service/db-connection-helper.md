# DbConnectionHelper — executor-service

Nơi lưu: `docs/api/docs/executor-service/db-connection-helper.md`

Mục đích: giải thích cách mở JDBC connection cho bước DB, cơ chế retry, cách phân biệt lỗi
kết nối với lỗi câu lệnh, và cách giới hạn thời gian chờ.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.db` |
| Annotation | `@Component`, `@RequiredArgsConstructor`, `@Slf4j` |
| Phụ thuộc | `DbDialectRegistry` |
| Ai dùng | `DbQueryExecutor`, `DbSchemaCheckExecutor`, `DbMigrationExecutor`, `DbSandboxService` |

Hằng số: `CONNECT_RETRIES = 5`, `CONNECT_RETRY_MS = 1000`, `LOGIN_TIMEOUT_SECONDS = 5`.

## 2. `withConnection(config, hostPort, timeoutMs, action)`

```java
<T> T withConnection(JsonNode config, Integer hostPort, int timeoutMs,
        ConnectionAction<T> action) throws SQLException
```

### Luồng

1. Đọc `connection.db_type` (mặc định `postgres`), `database`, `username`, `password`.
2. `dialectRegistry.resolve(dbType)` → dialect; `dialect.jdbcUrl(hostPort, database)`.
3. Lưu `DriverManager.getLoginTimeout()` cũ, đặt 5 giây, và **luôn khôi phục** trong
   `finally`. Lý do an toàn: mỗi pod chỉ chấm một job (single-job gate) nên không có hai
   thread cùng sửa login timeout.
4. Vòng lặp tối đa 5 lần:
   - Nếu đã vượt `timeoutMs` → `DbStepTimeoutException` với message
     `SQL_TIMEOUT_ERROR + "... waiting for database connection"`. Nhờ vậy DB chậm không giữ
     thread chấm quá `EXECUTOR_MAX_EXECUTION_MS`, và lỗi được báo là timeout thay vì
     "kiểm tra db_type" (review 2026-09-26, Pullfrog round 4).
   - `DriverManager.getConnection`; thành công → thoát vòng lặp.
   - Thất bại → lưu `last`, nếu còn lượt **và** `elapsed + 1000 <= timeoutMs` thì log warn
     và `Thread.sleep(1000)`. Ngắt giữa chừng → set interrupt flag và ném `SQLException`.
5. Hết lượt mà `conn == null` → `DbConnectionException` với message
   `CONNECTION_DIALECT_PREFIX + dbType + CONNECTION_DIALECT_SUFFIX + ": " + last.message`,
   cause là lỗi driver cuối.
6. Chạy `action.apply(conn)`, đóng connection trong `finally`.

### Vì sao retry

Container DB có thể còn đang khởi tạo khi bước đầu tiên chạy (`mysql:8` entrypoint mất hàng
chục giây). Retry 5 lần × 1 giây bù được khoảng chờ đó mà không cần sleep dài cố định.

### Vì sao chỉ retry lỗi kết nối

Lỗi từ `action.apply` (SQL giảng viên, migration, schema check) là lỗi logic/câu lệnh —
retry không giúp gì và có thể chạy lặp tác dụng phụ. Chúng được ném thẳng ra ngoài để
executor gắn nhãn `SQL_EXECUTION_ERROR` (trừ hai exception đã có message riêng).

## 3. `resolve(String key)`

Chuyển tiếp `dialectRegistry.resolve(key)` cho nơi cần SQL riêng của dialect (schema check)
nhưng không cần mở connection.

## 4. `interface ConnectionAction<T>`

`T apply(Connection conn) throws SQLException` — callback nhận connection đã mở; helper lo
đóng connection.

## 5. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| DB lên sau ~3 giây | Lần thử 4 thành công |
| DB không bao giờ lên, `timeoutMs = 30000` | Hết 5 lượt → `DbConnectionException` |
| `timeoutMs` nhỏ (ví dụ 2000) | Có thể chỉ thử 2 lần rồi `DbStepTimeoutException` |
| `hostPort` null | `jdbcUrl` nối chuỗi ra `localhost:null` → lỗi kết nối, bọc thành `DbConnectionException` |
| Action ném `SQLException` | Truyền thẳng, connection vẫn được đóng |

## 6. Liên kết

- `DbDialectRegistry` — xem `db-dialect-registry.md`.
- Ba executor DB — xem `db-query-executor.md`, `db-schema-check-executor.md`, `db-migration-executor.md`.
- `DbStepResults.message` phân biệt `DbConnectionException`/`DbStepTimeoutException` với lỗi SQL thường.

---

## Chi tiết từng hàm

### `DbConnectionHelper(...)` (constructor)

Nhận `DbDialectRegistry`; hằng số lớp: `CONNECT_RETRIES = 5`, `CONNECT_RETRY_MS = 1000`,
`LOGIN_TIMEOUT_SECONDS = 5`.

### `DbDialect resolve(String key)`

Uỷ quyền thẳng cho `dialectRegistry.resolve(key)`; dùng cho `DbSchemaCheckExecutor` khi cần
SQL của dialect mà không mở connection. Không cache thêm.

### `<T> T withConnection(JsonNode config, Integer hostPort, int timeoutMs, ConnectionAction<T> action)`

| Khía cạnh | Nội dung |
|---|---|
| Input | `config` cấp bước (có block `connection`), `hostPort` đã cấp cho DB, budget bước, lambda thao tác |
| Output | giá trị `action` trả về |
| Ném | `SQLException` (action lỗi), `DbConnectionException` (hết 5 lần thử), `DbStepTimeoutException` (hết budget) |

Trình tự:

1. Đọc `db_type` (mặc định `postgres`), `database`, `username`, `password` từ `config.connection`.
2. `dialect.jdbcUrl(hostPort, database)` — dialect tự `requireSafeDatabase(database)`.
3. Ghi nhớ `DriverManager.getLoginTimeout()`, đặt 5 giây; khôi phục trong `finally` để
   không rò cấu hình toàn JVM sang job khác.
4. Vòng tối đa 5 lần: trước mỗi lần kiểm tra `now - start > timeoutMs` → `DbStepTimeoutException`
   (budget cạn thì báo timeout, **không** báo "sai db_type" gây nhiễu).
   - `getConnection` thành công → thoát vòng.
   - `SQLException` → lưu `last`; nếu còn lượt **và** `elapsed + 1000 <= timeoutMs` thì log
     warn rồi `Thread.sleep(1000)`; interrupt → set interrupt, ném `SQLException`.
5. Sau vòng, `conn == null` → `DbConnectionException` kèm prefix/suffix dialect và message
   lỗi cuối — người đọc biết ngay nên kiểm tra `connection.db_type` hay DB chưa lên.
6. `action.apply(conn)` trong try, `conn.close()` trong `finally` — kể cả action ném, kết nối
   vẫn đóng.

### `interface ConnectionAction<T>`

`@FunctionalInterface` với `T apply(Connection conn) throws SQLException` — cho phép lambda
làm việc với `Connection` mà vẫn khai báo checked exception, nhờ đó helper giữ được
`throws SQLException` và caller (`DbQueryExecutor`, `DbMigrationExecutor`, `DbSandboxService`)
đóng gói thành lỗi bước.
