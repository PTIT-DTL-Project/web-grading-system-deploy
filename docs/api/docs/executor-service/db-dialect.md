# DbDialect — executor-service

Nơi lưu: `docs/api/docs/executor-service/db-dialect.md`

Mục đích: giải thích trừu tượng hoá dialect DB (MySQL/MariaDB, PostgreSQL), hợp đồng SQL
cho các bước kiểm tra schema, và cách registry tự gom implementation.

---

## 1. Tổng quan

`DbDialect` là interface mô tả "cách nói chuyện với một engine DB" cho các bước chấm DB.

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.db` |
| Loại | `public interface` |
| Implementation | `db/impl/MysqlDialect` (`mysql`, `mariadb`), `db/impl/PostgresDialect` (`postgresql`, `postgres`) |
| Ai dùng | `DbDialectRegistry`, `DbQueryExecutor`, `DbSchemaCheckExecutor`, `DbMigrationExecutor`, `DbSandboxService` |

Tài liệu trong code gọi đây là **Axis 1** của tính đa dạng DB: "nói chuyện với DB thế nào",
khoá theo `connection.db_type`. **Axis 2** (image có sẵn hay phải pull) độc lập — mỗi image
ánh xạ đúng một dialect.

## 2. Các method

| Method | Ý nghĩa |
|---|---|
| `Set<String> keys()` | Các giá trị `db_type` mà dialect nhận, chữ thường (mysql + alias mariadb) |
| `int defaultPort()` | Cổng DB trong container khi config không khai `db_port` |
| `String jdbcUrl(int hostPort, String database)` | URL JDBC trỏ cổng host được cấp |
| `String tableExistsSql()` | SQL 1 tham số `(table_name)` trả `COUNT(*)` |
| `String columnExistsSql()` | SQL 2 tham số `(table_name, column_name)` trả mô tả kiểu |
| `String primaryKeySql()` | SQL 2 tham số, `COUNT(*)` > 0 nghĩa là cột là PK |
| `String indexExistsSql()` | SQL 2 tham số `(table_name, index_name)`, `COUNT(*)` > 0 |
| `boolean sameType(String expected, String actual)` | So sánh kiểu sau chuẩn hoá |

### 2.1 Hợp đồng `columnExistsSql`

Trả **một** query vừa xác định tồn tại vừa trả kiểu:

- PostgreSQL trả `data_type` (không kèm độ dài) → `varchar`, `integer`, …
- MySQL trả `column_type` (giữ `tinyint(1)`, `varchar(255)`) → cần cho check kiểu chính xác.

Không có dòng = cột không tồn tại; nhờ vậy một lần round-trip đủ cho cả `COLUMN_EXISTS` và
check `data_type`, không cần query thứ hai.

### 2.2 `requireSafeDatabase(String)` — chặn injection qua tên DB

Static helper kiểm tra `database` khớp `[A-Za-z0-9_$]+` trước khi nối vào JDBC URL.
Giá trị chứa `?`, `&`, `#`, `/`, `:` có thể chèn connection property vào URL (ví dụ đổi
`user`, `socketFactory`), nên bị chặn với `IllegalArgumentException`.

Xuất xứ: review 2026-09-26, Pullfrog PR #17 (F4).

### 2.3 `sameType`

Dialect đặt tên kiểu khác nhau (`character varying` vs `varchar`), nên so sánh là sau chuẩn
hoá và không phân biệt hoa thường. Implementation quyết định bảng alias cụ thể.

## 3. Vì sao tách interface

- Thêm engine = thêm một `@Component` implements `DbDialect`, `DbDialectRegistry` tự gom
  (cùng pattern `StepRegistry`) — không sửa executor.
- Các bước DB (`DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`) không cần biết engine, chỉ
  cần dialect đúng.

## 4. Sơ đồ

```text
grading config: connection.db_type = "mysql"
        │
        ▼
DbDialectRegistry.of("mysql") → MysqlDialect
        │  defaultPort() = 3306
        │  jdbcUrl(hostPort, database)
        ▼
DbQueryExecutor / DbSchemaCheckExecutor / DbMigrationExecutor
```

## 5. Mã lỗi

| Tình huống | Nơi phát sinh | Kết quả |
|---|---|---|
| `db_type` không có dialect | `DbDialectRegistry.of` | Exception với thông điệp loại DB không hỗ trợ |
| `connection.database` không an toàn | `requireSafeDatabase` | `IllegalArgumentException` |
| Hai dialect cùng `keys()` | `DbDialectRegistry` constructor | Lỗi khởi động (trùng khoá) |

Xem thêm: `db-dialect-registry.md`, `mysql-dialect.md`, `postgres-dialect.md`.