# MysqlDialect — executor-service

Nơi lưu: `docs/api/docs/executor-service/mysql-dialect.md`

Mục đích: giải thích implementation `DbDialect` cho MySQL/MariaDB: vì sao có tham số JDBC
đặc biệt, vì sao dùng `column_type` thay `data_type`, và cách xử lý `tinyint(1)`/`bit(1)`.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.db.impl` |
| Annotation | `@Component` |
| `keys()` | `{"mysql", "mariadb"}` — MariaDB tương thích wire protocol, dùng chung driver/SQL |
| `defaultPort()` | `3306` |

## 2. `jdbcUrl(hostPort, database)`

```text
jdbc:mysql://localhost:<port>/<database>?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC
```

Ba tham số đều có lý do:

| Tham số | Vì sao |
|---|---|
| `useSSL=false` | DB trong pod, không có TLS; bật SSL sẽ fail handshake |
| `allowPublicKeyRetrieval=true` | `mysql:8` mặc định `caching_sha2_password`; khi không SSL, client phải được phép lấy public key, nếu không mọi kết nối fail auth |
| `serverTimezone=UTC` | Tránh lệch múi giờ khi driver đọc `DATETIME` |

Trước khi nối chuỗi, gọi `DbDialect.requireSafeDatabase(database)` để chặn tên DB chứa ký
tự có thể chèn connection property (review 2026-09-26, Pullfrog PR #17 F4).

## 3. SQL kiểm tra schema

Phạm vi schema dùng `DATABASE()` — trong MySQL, `information_schema.table_schema` chính là
tên database hiện tại, không phải schema như PostgreSQL.

| Method | Câu SQL | Ghi chú |
|---|---|---|
| `tableExistsSql` | `information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?` | `COUNT(*)` |
| `columnExistsSql` | `information_schema.columns` trả `column_type` | giữ `tinyint(1)`, `varchar(255)` |
| `primaryKeySql` | join `table_constraints` + `key_column_usage` theo `constraint_schema` | `COUNT(*)` |
| `indexExistsSql` | `information_schema.statistics` | `COUNT(*)` |

### Vì sao `column_type`

`data_type` chỉ trả tên trần (`tinyint`, `varchar`), làm mất khả năng phân biệt boolean
(`tinyint(1)`) với số nguyên. `column_type` giữ nguyên độ rộng nên check kiểu chính xác hơn.
Ghi chú: review 2026-09-26, Pullfrog PR #17 (F2).

## 4. `sameType(expected, actual)`

`null` → false. Nếu `normalize(expected)` là `boolean` thì chấp nhận `normalize(actual) =
boolean` **hoặc** `actual` viết đúng `bit(1)` — vì `normalize` cắt `bit(1)` thành `bit`,
nên nếu chỉ so sánh chuẩn hoá thì `boolean` vs `bit(1)` sẽ trượt dù cùng nghĩa. Nhánh đặc
biệt này chỉ mở khi giảng viên khai `boolean`, nhờ đó `bit` vs `bit(1)` vẫn khớp như cũ.

### `normalize`

1. Trim + lowercase.
2. `tinyint(1)` (và các biến thể có tiền tố) → `boolean`.
3. Cắt phần trong ngoặc (độ rộng hiển thị không thuộc kiểu).
4. `bool`/`boolean` → `boolean`; `int`/`integer` → `integer`.

## 5. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| `expected = "boolean"`, `actual = "bit(1)"` | Khớp (nhánh đặc biệt) |
| `expected = "bit"`, `actual = "bit(1)"` | Khớp sau khi cắt ngoặc |
| `expected = "varchar(50)"`, `actual = "varchar(50)"` | Khớp (cắt ngoặc cả hai) |
| DB `mariadb` | Dùng cùng SQL/driver; `DATABASE()` hoạt động tương đương |

Xem thêm: `db-dialect.md`, `db-dialect-registry.md`, `postgres-dialect.md`.

---

## Chi tiết từng hàm

### `Set<String> keys()`

Trả `Set.of("mysql", "mariadb")` — một dialect phục vụ cả hai tên; registry gắn cả hai khoá
vào cùng instance.

### `int defaultPort()`

`3306`, port trong container khi config không khai `db_port`.

### `String jdbcUrl(int hostPort, String database)`

1. `DbDialect.requireSafeDatabase(database)` — chặn injection qua tên DB.
2. Trả `jdbc:mysql://localhost:<port>/<database>?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC`.

`allowPublicKeyRetrieval=true` là bắt buộc với `mysql:8`: server mặc định
`caching_sha2_password`, client tắt SSL không lấy được public key thì mọi kết nối fail auth.
`serverTimezone=UTC` tránh lệch múi giờ khi chấm `timestamp`.

### `String tableExistsSql()`

`SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?`
— tham số 1 là tên bảng; `> 0` nghĩa là tồn tại. Dùng `DATABASE()` để không phụ thuộc schema
cứng.

### `String columnExistsSql()`

`SELECT column_type FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?`
— trả kiểu kèm độ dài (`varchar(255)`, `tinyint(1)`) để phân biệt boolean với số; không có
dòng = cột không tồn tại.

### `String primaryKeySql()`

Join `table_constraints` với `key_column_usage` theo `constraint_schema` + `constraint_name`
(MySQL không đảm bảo `constraint_name` duy nhất toàn server, phải kèm schema), lọc
`constraint_type = 'PRIMARY KEY'` và `kcu.column_name = ?`; `> 0` nghĩa là cột thuộc PK.

### `String indexExistsSql()`

`SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ?`.

### `boolean sameType(String expected, String actual)`

| Khía cạnh | Nội dung |
|---|---|
| Input | kiểu giảng viên khai, kiểu `column_type` đọc được (null → `false`) |
| Output | khớp sau chuẩn hoá |

1. Nếu `normalize(expected) == "boolean"`: chấp nhận `normalize(actual) == boolean` **hoặc**
   `actual` đúng bằng `bit(1)` (cách viết boolean hiếm gặp của MySQL) — nhờ vậy
   `boolean` khớp `bit(1)` mà `bit` vẫn khớp `bit(1)`.
2. Ngược lại so `normalize(expected) == normalize(actual)`.

### `private static String normalize(String type)`

1. Trim + lowercase.
2. `tinyint(1)` (tiền tố) → `boolean` — vì `BOOL`/`BOOLEAN` được MySQL lưu thành
   `tinyint(1)`.
3. Cắt phần trong ngoặc (`varchar(255)` → `varchar`) vì display width không thuộc kiểu.
4. Map `bool`/`boolean` → `boolean`, `int`/`integer` → `integer`, còn lại giữ nguyên.
