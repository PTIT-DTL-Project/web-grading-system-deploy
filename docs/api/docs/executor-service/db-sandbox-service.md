# DbSandboxService — executor-service

Nơi lưu: `docs/api/docs/executor-service/db-sandbox-service.md`

Mục đích: giải thích cách reset database của sinh viên giữa các plan (drop + create), vì
sao phải nối vào database hệ thống, và xử lý riêng của PostgreSQL.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.db` |
| Annotation | `@Component` |
| Phụ thuộc | `DbConnectionHelper`, Jackson `ObjectMapper` |
| Ai gọi | `GradingOrchestrator` sau mỗi plan, trước plan kế tiếp |

Mục tiêu: mỗi plan bắt đầu với DB sạch, không thấy dữ liệu plan trước để lại. Container
app + DB vẫn sống suốt job; chỉ nội dung DB bị reset.

## 2. `resetDatabase(JsonNode connectionConfig, Integer hostPort)`

| Khía cạnh | Nội dung |
|---|---|
| Input | Khối cấu hình connection của bài nộp, cổng host của DB |
| Output | Không (void) |
| Lỗi | `RuntimeException` bọc `SQLException` với message nêu tên database |

### Luồng

1. Đọc `connection.database`; rỗng/blank → **no-op** (bài không dùng DB).
2. Đọc `connection.db_type`, mặc định `postgres`.
3. `buildSystemConfig`: copy khối `connection`, thay `database` bằng DB hệ thống
   (`postgres` cho PG, `mysql` cho MySQL/MariaDB), bọc lại thành `{"connection": {...}}`.
4. `db.withConnection(systemConfig, hostPort, RESET_TIMEOUT_MS, ...)`:
   - Với PostgreSQL: chạy `PG_TERMINATE_CONNECTIONS` trước, vì còn connection đang mở
     (app sinh viên) thì `DROP DATABASE` sẽ fail.
   - `DROP DATABASE` rồi `CREATE DATABASE` theo dialect.
5. Bọc `SQLException` thành `RuntimeException` để orchestrator fail job với thông điệp rõ.

### Vì sao nối vào DB hệ thống

Không thể `DROP DATABASE` đang là database hiện tại của connection. Nối vào `postgres`/
`mysql` rồi drop DB đích là cách duy nhất qua JDBC thuần.

## 3. SQL theo dialect

| db_type | DROP | CREATE |
|---|---|---|
| `mysql`, `mariadb` | `MYSQL_DROP_DB` | `MYSQL_CREATE_DB` |
| còn lại | `PG_DROP_DB` | `PG_CREATE_DB` |

Chuỗi SQL nằm trong `Constant.DbSandbox`, có `.formatted(database)`.

## 4. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| Không khai `database` | Bỏ qua, không lỗi |
| `db_type` lạ | Rơi vào nhánh mặc định PG |
| DB đang có connection mở (PG) | Đã terminate trước khi drop |
| Timeout/reset lỗi | `RuntimeException` → job `FAILED` |
| Tên database chứa ký tự lạ | Không kiểm tra ở đây — `DbDialect.requireSafeDatabase` chỉ áp cho JDBC URL; SQL drop dùng chuỗi cấu hình nên cần cấu hình tin cậy từ course-service |

## 5. Liên kết

- `DbConnectionHelper.withConnection` — xem `db-connection-helper.md`.
- Gọi trong `GradingOrchestrator` giữa các plan — xem `grading-orchestrator.md`.
- Hằng số: `Constant.DbSandbox` (`RESET_TIMEOUT_MS`, `PG_TERMINATE_CONNECTIONS`, …).

---

## Chi tiết từng hàm

### `DbSandboxService(DbConnectionHelper db, ObjectMapper mapper)`

Lưu hai phụ thuộc; `mapper` là Jackson 3 dùng để deep-copy block `connection`.

### `void resetDatabase(JsonNode connectionConfig, Integer hostPort)`

| Khía cạnh | Nội dung |
|---|---|
| Input | config bước + port DB |
| Output | không (void) |
| No-op | `connection.database` rỗng/blank — không có gì để reset |
| Lỗi | mọi `SQLException` bọc `RuntimeException("DB sandbox reset failed for database 'x': ...")` |

1. Đọc `database`, `db_type` (mặc định `postgres`).
2. `withConnection(buildSystemConfig(...), hostPort, RESET_TIMEOUT_MS, action)`.
3. Trong action: PostgreSQL chạy `pg_terminate_backend` cho mọi kết nối tới DB đích trước
   (nếu không, `DROP DATABASE` fail vì còn session); MySQL/MariaDB bỏ qua bước này.
4. `DROP DATABASE` (nếu tồn tại) rồi `CREATE DATABASE` — thứ tự cố định để DB trắng.
5. Lỗi SQL → RuntimeException để orchestrator fail job với thông điệp rõ, thay vì lỗi
   assertion khó hiểu sau đó.

### `JsonNode buildSystemConfig(JsonNode connectionConfig, String dbType)`

Tạo `{"connection": {...}}` mới: deep-copy từng field của block gốc rồi ghi đè `database`
bằng DB hệ thống (`mysql` cho MySQL/MariaDB, `postgres` cho phần còn lại). Nhờ vậy kết nối
để DROP/CREATE không trỏ vào chính DB đang bị xoá. Bản gốc không bị sửa.

### `String getDropSql(String dbType, String database)`

`switch`: MySQL/MariaDB → `MYSQL_DROP_DB`, còn lại → `PG_DROP_DB`; `formatted(database)`.
`database` đã qua `requireSafeDatabase` khi dựng URL, nhưng hàm này không tự kiểm tra — gọi
trực tiếp với chuỗi lạ có thể tạo SQL sai.

### `String getCreateSql(String dbType, String database)`

Tương tự với `MYSQL_CREATE_DB` / `PG_CREATE_DB`, giữ nguyên charset/collation mặc định của
image. Luôn chạy ngay sau DROP trong cùng action.
