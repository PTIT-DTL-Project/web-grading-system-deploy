# DbDialectRegistry — executor-service

Nơi lưu: `docs/api/docs/executor-service/db-dialect-registry.md`

Mục đích: giải thích bảng tra `db_type` → `DbDialect`, quy ước fallback về PostgreSQL khi
cấu hình cũ thiếu `db_type`, và cách thông điệp lỗi tự cập nhật khi thêm engine mới.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.db` |
| Annotation | `@Component` |
| Constructor | `DbDialectRegistry(List<DbDialect>)` |
| Ai dùng | `DbQueryExecutor`, `DbSchemaCheckExecutor`, `DbMigrationExecutor`, `GradingOrchestrator` (resolve dialect cho bước DB) |

## 2. Cơ chế gom bean

1. Spring inject toàn bộ `DbDialect` bean (hiện có `MysqlDialect`, `PostgresDialect`).
2. Với mỗi dialect, lặp qua `keys()` và đưa vào map; key được `toLowerCase(Locale.ROOT)`.
   `MysqlDialect` khai hai key `mysql`, `mariadb` cùng trỏ về một implementation.
3. Trùng key → `IllegalStateException` nêu tên hai class. Lỗi lộ ra lúc khởi động.
4. Map làm `Map.copyOf` (bất biến).
5. Kiểm tra `Constant.DbConnection.DEFAULT_DB_TYPE` (postgres) có mặt trong map; thiếu →
   `IllegalStateException`, vì nếu không mọi config không khai `db_type` sẽ NPE về sau.

## 3. `DbDialect resolve(String key)`

| Input | Kết quả |
|---|---|
| `null` hoặc chuỗi rỗng | `defaultDialect` (PostgreSQL) |
| `"mysql"`, `"MySQL"`, `" mariadb "` | dialect tương ứng (trim + lowercase) |
| key lạ | `IllegalArgumentException` với message `UNKNOWN_DIALECT` + danh sách key hợp lệ |

Danh sách key hợp lệ trong message được dựng từ `byKey.keySet()` đã sort alphabet, nên
thêm dialect mới thì message tự đúng, không phải sửa tay. Ghi chú trong code: review
2026-09-26, Pullfrog PR #17 (F6).

## 4. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| Thiếu bean PostgresDialect | Khởi động thất bại — wiring error |
| Dialect khai `keys()` rỗng | Không map được key nào; nếu là postgres thì lỗi khởi động |
| `db_type` hoa/thường lẫn lộn | Chuẩn hoá trước khi tra, chấp nhận mọi kiểu viết |

## 5. Sơ đồ

```text
config.connection.db_type
   │ null/blank → default
   ▼
DbDialectRegistry.resolve
   ├── "mysql"    → MysqlDialect
   ├── "mariadb"  → MysqlDialect
   └── "postgres" → PostgresDialect
   ▼
DbConnectionHelper / executor bước DB
```

Xem thêm: `db-dialect.md`, `mysql-dialect.md`, `postgres-dialect.md`.