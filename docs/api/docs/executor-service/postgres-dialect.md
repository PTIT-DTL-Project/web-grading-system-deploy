# PostgresDialect — executor-service

Nơi lưu: `docs/api/docs/executor-service/postgres-dialect.md`

Mục đích: giải thích implementation `DbDialect` cho PostgreSQL: SQL kiểm tra schema trong
`public`, alias kiểu dữ liệu, và các quyết định phạm vi schema.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.db.impl` |
| Annotation | `@Component` |
| `keys()` | `{"postgres"}` |
| `defaultPort()` | `5432` |
| Là dialect mặc định | Có — `Constant.DbConnection.DEFAULT_DB_TYPE` = `postgres` |

## 2. `jdbcUrl(int hostPort, String database)`

Gọi `DbDialect.requireSafeDatabase(database)` trước khi nối chuỗi, rồi trả
`jdbc:postgresql://localhost:<hostPort>/<database>`.

Vì sao `localhost`: executor chạy trong pod, container DB publish cổng vào netns pod, nên
JDBC trỏ loopback. Kiểm tra an toàn chặn tên DB chứa `?`, `&`, `/`, … có thể chèn
connection property (review 2026-09-26, Pullfrog PR #17 F4).

## 3. SQL kiểm tra schema (luôn giới hạn `table_schema = 'public'`)

### 3.1 `tableExistsSql()`

```sql
SELECT COUNT(*) FROM information_schema.tables
WHERE table_schema = 'public' AND table_name = ?
```

### 3.2 `columnExistsSql()`

```sql
SELECT data_type FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = ? AND column_name = ?
```

Trả `data_type` (không kèm độ dài) — khác MySQL trả `column_type`. Không có dòng = cột
không tồn tại.

### 3.3 `primaryKeySql()`

Join `information_schema.table_constraints` với `key_column_usage`, lọc
`constraint_type = 'PRIMARY KEY'`, trả `COUNT(*)`.

### 3.4 `indexExistsSql()`

```sql
SELECT COUNT(*) FROM pg_indexes
WHERE schemaname = 'public' AND tablename = ? AND indexname = ?
```

### Vì sao cố định schema `public`

App sinh viên chạy với `search_path` mặc định; `information_schema` của PG trải mọi schema
(khác MySQL, nơi `table_schema` chính là database), nên không lọc sẽ đếm cả bảng hệ thống
hoặc schema khác. Ghi chú trong Javadoc của lớp.

## 4. `sameType(expected, actual)`

`null` ở một trong hai → false. Ngược lại so sánh `normalize(expected)` với
`normalize(actual)`.

### Chuẩn hoá

1. Trim + lowercase.
2. Bỏ phần trong ngoặc (ví dụ `varchar(50)` → `varchar`), vì catalog PG không bao giờ báo
   độ dài nhưng giảng viên hay ghi kèm.
3. Map alias dài → tên ngắn:

| PG báo | Chuẩn hoá |
|---|---|
| `character varying` | `varchar` |
| `timestamp with time zone` | `timestamptz` |
| `timestamp without time zone` | `timestamp` |
| `double precision` | `float8` |
| `bool` | `boolean` |
| `int` | `integer` |
| `character` | `char` |
| `time without time zone` | `time` |
| `time with time zone` | `timetz` |

Review 2026-09-26, Pullfrog PR #17 (F3).

## 5. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| Bảng ở schema khác `public` | Bị coi là không tồn tại — đúng chủ đích |
| `data_type` = `USER-DEFINED` (enum) | So sánh chuỗi thô, không map sang tên enum |
| Tên bảng/cột hoa thường | PG fold về lowercase; config phải viết thường |

Xem thêm: `db-dialect.md`, `db-dialect-registry.md`, `mysql-dialect.md`.

---

## Chi tiết từng hàm

### `Set<String> keys()`

`Set.of("postgres")` — không nhận alias `postgresql`; plan khai `postgresql` sẽ bị registry
báo lỗi kèm danh sách hợp lệ.

### `int defaultPort()`

`5432`, port trong container.

### `String jdbcUrl(int hostPort, String database)`

`requireSafeDatabase(database)` rồi `jdbc:postgresql://localhost:<port>/<database>` — không
thêm tham số URL; schema luôn `public` (mọi SQL catalog đều lọc `table_schema = 'public'`).

### `String tableExistsSql()`

`SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = ?`.

### `String columnExistsSql()`

`SELECT data_type FROM information_schema.columns ...` — PostgreSQL chỉ trả tên kiểu dài
(`character varying`), **không** kèm độ dài; `sameType` lo phần quy đổi.

### `String primaryKeySql()`

Join `table_constraints` + `key_column_usage` theo `constraint_name` và `table_schema`, lọc
`constraint_type = 'PRIMARY KEY'`, `table_schema = 'public'`; trả `COUNT(*)`.

### `String indexExistsSql()`

`SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public' AND tablename = ? AND indexname = ?`.

### `boolean sameType(String expected, String actual)`

`null` ở một trong hai → `false`; ngược lại so `normalize(expected).equals(normalize(actual))`.

### `private static String normalize(String type)`

Trim + lowercase, bỏ phần trong ngoặc (`varchar(50)` → `varchar` — catalog PostgreSQL không
bao giờ trả độ dài nên giảng viên hay viết kèm), rồi map tên dài về alias:

| PostgreSQL trả | Chuẩn hoá |
|---|---|
| `character varying` | `varchar` |
| `timestamp with time zone` | `timestamptz` |
| `timestamp without time zone` | `timestamp` |
| `double precision` | `float8` |
| `bool` | `boolean` |
| `int` | `integer` |
| `character` | `char` |
| `time without time zone` / `time with time zone` | `time` / `timetz` |
