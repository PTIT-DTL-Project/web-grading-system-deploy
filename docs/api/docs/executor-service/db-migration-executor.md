# DbMigrationExecutor — executor-service

Nơi lưu: `docs/api/docs/executor-service/db-migration-executor.md`

Mục đích: giải thích bước `DB_MIGRATION`: chạy danh sách câu lệnh trong một transaction,
giới hạn thời gian theo deadline chung, và cảnh báo về atomicity khác nhau giữa
PostgreSQL với MySQL/MariaDB.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.step.impl` |
| Annotation | `@Component`, `@RequiredArgsConstructor` |
| `type()` | `Constant.DbStep.TYPE_MIGRATION` (`DB_MIGRATION`) |
| Phụ thuộc | `DbConnectionHelper`, `ObjectMapper` |

## 2. Cấu hình bước

| Trường | Ý nghĩa |
|---|---|
| `statements[]` | Danh sách câu SQL, mỗi câu có thể chứa `${var}` |
| `timeout_ms` | Ngân sách thời gian cho **toàn bộ** danh sách |
| `connection.*` | Như các bước DB khác |

## 3. Luồng `execute(ctx)`

1. Tính `timeoutMs` (config → `ctx.timeoutMs` → 30.000) và `deadline = now + timeoutMs`.
2. `db.withConnection(...)`:
   - `conn.setAutoCommit(false)`.
   - Với từng câu:
     - `remaining = deadline - now`; `<= 0` → `DbStepTimeoutException(SQL_TIMEOUT_ERROR +
       timeoutMs + "ms")`.
     - `prepareStatement(substitute(stmt))`.
     - `ps.setQueryTimeout(max(1, ceil(remaining/1000)))` — mỗi câu chỉ được dùng phần ngân
       sách còn lại.
     - `executeUpdate()`.
   - Thành công hết → `commit()`.
   - `SQLException` → `rollback()` rồi ném lại.
   - `finally`: `setAutoCommit(true)`.
3. `SQLException` → `ERROR` với `DbStepResults.message(e)` (giữ message gốc nếu là connection/
   timeout).
4. Không lỗi → `PASSED`, không assertion, không biến trích xuất.

## 4. Atomicity — điểm phải hiểu đúng

| Engine | DDL trong transaction |
|---|---|
| PostgreSQL | Atomic thật: DDL + DML cùng commit/rollback |
| MySQL, MariaDB | DDL gây **implicit commit** (`CREATE/ALTER/DROP TABLE`, `CREATE/DROP INDEX`, `TRUNCATE`, …) |

Hệ quả với MySQL: migration gồm DDL rồi một câu lỗi thì DDL đã commit vĩnh viễn,
`rollback()` không hoàn tác được, nhưng bước vẫn báo `ERROR` mà không nói rõ schema đã bị
migrate một phần. Đây là best-effort, được ghi rõ trong Javadoc (dẫn MySQL §15.3.3 và
MariaDB "SQL statements Causing an Implicit Commit").

`commit`/`rollback` không bị giới hạn bởi deadline; lock wait khi commit do server chặn
(MySQL: `innodb_lock_wait_timeout`).

## 5. Trường hợp biên

| Tình huống | Kết quả |
|---|---|
| `statements` rỗng | Không chạy gì, `commit()` → `PASSED` (nên tránh cấu hình rỗng) |
| Câu lỗi giữa chừng (PG) | Rollback toàn bộ → `ERROR` |
| Câu lỗi sau DDL (MySQL) | DDL đã áp dụng, `ERROR`, schema lệch một phần |
| Hết ngân sách giữa các câu | `DbStepTimeoutException` → rollback (trừ DDL MySQL) |
| Connection lỗi | `DbConnectionException` → `ERROR` với gợi ý dialect |

Xem thêm: `db-connection-helper.md`, `db-step-results.md`, `db-query-executor.md`.