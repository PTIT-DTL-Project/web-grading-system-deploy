# Luồng thực thi DB step sau khi cấp db_port

> **Phiên bản:** v1.0
> **Ngày:** 2026-09-26
> **Trạng thái:** Đã triển khai (Phase 2)
> **Liên quan:** `.opencode/plans/db-multi-dbms-v1.0.md` · `docs/design/vi/db-multi-dbms-flow-v1.0.md` · `docs/design/usecase-flows.md` (UC-05) · `docs/design/grading-config-reference.md` §3.5

---

## Tổng quan

Sau khi `GradingOrchestrator` cấp `db_port` cho plan và đẩy vào `VariableContext`, bước `runSteps` bắt đầu duyệt từng step của plan. Với step type `DB_QUERY`, `DB_SCHEMA_CHECK`, hoặc `DB_MIGRATION`, `StepRegistry` sẽ resolve ra executor tương ứng và gọi `executor.execute(StepContext)`. Toàn bộ logic JDBC nằm trong executor + `DbConnectionHelper` + lớp dialect — engine-agnostic nhờ `connection.db_type`.

```
┌─────────────────────────────────────────────────────────────────────┐
│  GradingOrchestrator.runSteps(plan)                                 │
│    └─ for each step in plan:                                        │
│         vars.put("db_port", allocatedHostPort)   ← đã có sẵn      │
│         runStep(job, plan, step, vars)                             │
│              └─ stepRegistry.of(stepType)                          │
│                   ├─ HTTP_REQUEST → HttpStepExecutor               │
│                   ├─ DB_QUERY        → DbQueryExecutor             │
│                   ├─ DB_SCHEMA_CHECK → DbSchemaCheckExecutor       │
│                   └─ DB_MIGRATION    → DbMigrationExecutor         │
│                        └─ executor.execute(StepContext)             │
│                             └─ DbConnectionHelper.withConnection()  │
│                                  └─ DbDialectRegistry.resolve(dbType)│
│                                       └─ dialect.jdbcUrl(hostPort)  │
│                                            └─ DriverManager.connect │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 1. Đầu vào — StepContext

Mọi executor nhận cùng một `StepContext` (record trong `HttpStepExecutor`):

| Field | Type | Nguồn | Ý nghĩa |
|---|---|---|---|
| `jobId` | `UUID` | `GradingJob` | Job đang chấm |
| `planId` | `UUID` | `InternalPlanDto` | Plan hiện tại |
| `stepId` | `UUID` | `InternalStepDto` | Bước hiện tại |
| `stepOrder` | `Integer` | `step.getStepOrder()` | Thứ tự bước trong plan |
| `stepName` | `String` | `step.getName()` | Tên step hiển thị |
| `config` | `JsonNode` | `objectMapper.readTree(step.getConfig())` | Toàn bộ JSON config của step |
| `variableContext` | `VariableContext` | `vars` từ `runSteps` | Chứa `DB_PORT`, `APP_PORT`, `submission_id`... |
| `timeoutMs` | `Integer` | `step.getTimeoutMs()` | Thời gian tối đa cho bước |

**Quan trọng:** `config` là JSON gốc của step (ví dụ `{"connection":{...},"query":"SELECT ...","expected":{...}}`). `variableContext.get("db_port")` trả về port host đã cấp.

---

## 2. Giải quyết executor — StepRegistry

`StepRegistry` là `@Component`, constructor nhận `List<StepExecutor>` (Spring tự inject tất cả bean executor):

```java
public StepRegistry(List<StepExecutor> executors) {
    this.executors = executors.stream()
        .collect(Collectors.toUnmodifiableMap(StepExecutor::type, Function.identity()));
}
public StepExecutor of(String type) {
    // type = "HTTP_REQUEST" | "DB_QUERY" | "DB_SCHEMA_CHECK" | "DB_MIGRATION"
}
```

4 bean executor tự đăng ký (cùng pattern `@Component @RequiredArgsConstructor`):
- `HttpStepExecutor` → `type() = "HTTP_REQUEST"`
- `DbQueryExecutor` → `type() = "DB_QUERY"`
- `DbSchemaCheckExecutor` → `type() = "DB_SCHEMA_CHECK"`
- `DbMigrationExecutor` → `type() = "DB_MIGRATION"`

Thêm engine mới = thêm 1 `@Component` + 1 `DbDialect` → không cần sửa `StepRegistry`.

Nếu `type` không có trong map → `IllegalArgumentException` → `runStep` catch → `FAILED` với `UNKNOWN_STEP_TYPE`.

---

## 3. `runStep` — cầu nối từ GradingOrchestrator

```
runStep(job, plan, step, vars):
  1. config = objectMapper.readTree(step.getConfig())
  2. executor = stepRegistry.of(step.getStepType())   // hoặc FAILED
  3. result = executor.execute(new StepContext(..., config, vars, step.getTimeoutMs()))
  4. return stepResultRepository.save(result)
  // catch (Exception e) → persist ERROR với safeMessage(e)
```

Bước 3 gọi `executor.execute()`. Mọi exception bong ra (kể cả `IllegalArgumentException` từ dialect unknown) đều bị catch ở bước trên → persisted thành `StepResultStatus.ERROR`.

---

## 4. Mở JDBC connection — `DbConnectionHelper.withConnection`

Mỗi executor gọi `db.withConnection(config, hostPort, timeoutMs, action)` trong một lambda. Đây là entrypoint JDBC duy nhất.

```
withConnection(config, hostPort, timeoutMs, action):
  connBlock = config.path("connection")          // trích block connection
  dbType    = connBlock.path("db_type").asString("postgres")
  database  = connBlock.path("database").asString("")
  username  = connBlock.path("username").asString("")
  password  = connBlock.path("password").asString("")
  dialect   = dialectRegistry.resolve(dbType)     // PostgresDialect / MysqlDialect
  url       = dialect.jdbcUrl(hostPort, database) // engine-specific URL

  start = now()
  Connection conn = null
  retry 5 lần:
    if now() - start > timeoutMs: timeout!
    setLoginTimeout(5s)
    try conn = DriverManager.getConnection(url, username, password): break
    catch SQLException: sleep 1s (nếu chưa phải lần cuối && budget còn)
  if conn == null: throw SQLException(dialectHint + last.getMessage())
  try: return action.apply(conn)   // ← KHÔNG retry, failure propagate ngay
  finally: conn.close()
```

**Phân tách retry / action:**
- Chỉ **connection-establishment** failure được retry (DB container chưa xong khởi động).
- Failures do `action.apply(conn)` (lecturer SQL, migration, schema-check) **không retry** và **không bị wrap** bởi dialect hint — chúng propagate raw về executor, được gắn tiền tố `SQL_EXECUTION_ERROR`.
- `timeoutMs` dừng retry khi budget hết → throw **`DbStepTimeoutException`** với message `SQL_TIMEOUT_ERROR + ...` (không có dialect hint — xem §7).
- `DriverManager.setLoginTimeout(5)` an toàn vì single-job gate mỗi pod (SKILL §1).
- Mỗi executor đọc `timeoutMs` từ **step config** (`config.path("timeoutMs")`) trước, rồi mới dùng `ctx.timeoutMs()` làm fallback — giống `HttpStepExecutor`. (Xem `Constant.DbStep.TIMEOUT_MS`.)

**Lưu ý:** `config` truyền vào là TOÀN BỘ JSON config step (không phải chỉ `connection` block). `withConnection` tự trích `connection` block bên trong — nên executor truyền `ctx.config()` một cách tự nhiên. Variable substitution dùng giá trị từ `VariableContext`, vốn được feed bởi `extract[]` đọc response của sinh viên; DB grading là per-job disposable nên blast radius giới hạn ở grade của chính sinh viên đó.

**Các exception `withConnection` throw:**
- **`DbConnectionException`** (retry exhaustion): message = dialect hint, cause = lỗi driver cuối cùng. Executor surface verbatim.
- **`DbStepTimeoutException`** (budget exhaustion): message = `SQL_TIMEOUT_ERROR + ...`. Executor surface verbatim.
- Action failure: propagate raw (đọc bên trên).

---

## 5. Ba executor — logic chi tiết sau khi có connection

Sau khi `withConnection` mở được connection và gọi `action.apply(conn)`, executor chạy logic riêng bên trong lambda.

### 5.1 `DB_QUERY` — `DbQueryExecutor`

**Mục:** Chạy câu SQL của giảng viên, so sánh kết quả với `expected`.

```
execute(StepContext ctx):
  query = substitute(config.path("query"))              // thay ${var}
  hostPort = variableContext.get("db_port")
  timeoutMs = ctx.timeoutMs() != null ? ctx.timeoutMs() : 30_000
  timeoutSeconds = ceil(timeoutMs / 1000)

  rowCount = 0; columns = []
  db.withConnection(config, hostPort, timeoutMs, conn -> {
    try (Statement stmt = conn.createStatement()) {
      stmt.setQueryTimeout(timeoutSeconds)               // bound statement
      try (ResultSet rs = stmt.executeQuery(query)) {
        meta = rs.getMetaData()
        for i = 1..meta.getColumnCount(): columns.add(meta.getColumnLabel(i))
        while (rs.next()): rowCount++
      }
    }
    return null
  })

  details = []
  expected = config.path("expected")
  if expected is object:
    if expected has "row_count":
      detail = assertion("row_count", exp, rowCount, exp==rowCount, ...)
    if expected has "columns":
      expCols = expected["columns"].map(c -> c.asText().toLowerCase())
      actCols = columns.map(c -> c.toLowerCase())
      ok = (expCols.size()==actCols.size()) && expCols.zip(actCols).allMatch(equals ignoreCase)
      detail = assertion("columns", expCols, columns, ok, ...)

  passed = details.allMatch(isPassed)
  return PASSED if passed else FAILED
```

**`AssertionDetail` output:**
- `kind = "row_count"`: `expected` = số nguyên, `actual` = số nguyên, `passed` = boolean.
- `kind = "columns"`: `expected` = danh sách tên cột lower-case, `actual` = danh sách tên cột gốc, `passed` = boolean.
- `assertionResult` = JSON mảng `[{kind, expected, actual, passed, message}, ...]`.

**Ví dụ config:**
```json
{
  "connection": {"db_type":"mysql","database":"bookstore","username":"root","password":"root"},
  "query": "SELECT id, title FROM books WHERE id = ${bookId}",
  "expected": {"row_count": 1, "columns": ["id", "title"]}
}
```
`${bookId}` được thay bằng giá trị từ `extract` của bước trước (nếu có) hoặc `variableContext`.

### 5.2 `DB_SCHEMA_CHECK` — `DbSchemaCheckExecutor`

**Mục:** Kiểm tra schema DB (bảng, cột, khóa chính, index) engine-agnostic.

```
execute(StepContext ctx):
  connection = config.path("connection")
  dbType     = connection.path("db_type").asString("postgres")
  hostPort   = variableContext.get("db_port")
  timeoutMs  = config.path("timeoutMs") != null ? config.path("timeoutMs") : ctx.timeoutMs()
  deadline   = now() + timeoutMs       // single wall-clock budget cho toàn bộ checks[]

  details = []
  db.withConnection(config, hostPort, timeoutMs, conn -> {
    dialect = db.resolve(dbType)                     // PostgresDialect / MysqlDialect
    for check in config.path("checks"):
      remaining = deadline - now()
      if remaining <= 0: throw DbStepTimeoutException(SQL_TIMEOUT_ERROR + timeoutMs)
      details.add(runCheck(conn, dialect, check, max(1, ceil(remaining / 1000))))
    return null
  })

  passed = details.allMatch(isPassed)
  return PASSED if passed else FAILED
```

**`runCheck(conn, dialect, check, timeoutSec)` — switch `kind`:** mỗi nhánh tạo `PreparedStatement`, gọi `ps.setQueryTimeout(timeoutSec)`, rồi `executeQuery`.

| `kind` | Dialect method | Params | So sánh |
|---|---|---|---|
| `TABLE_EXISTS` | `dialect.tableExistsSql()` | `[table_name]` | `COUNT(*) > 0` |
| `COLUMN_EXISTS` | `dialect.columnExistsSql()` | `[table_name, column_name]` | `dialect.sameType(expectedDataType, columnType)` |
| `PRIMARY_KEY` | `dialect.primaryKeySql()` | `[table_name, column]` | `COUNT(*) > 0` |
| `INDEX_EXISTS` | `dialect.indexExistsSql()` | `[table_name, index_name]` | `COUNT(*) > 0` |

**`COLUMN_EXISTS` chi tiết:**
- Truy vấn: `SELECT data_type FROM information_schema.columns WHERE ...` (PG) hoặc `SELECT column_type ...` (MySQL).
- `dialect.sameType("varchar", "character varying")` → true (normalize).
- `dialect.sameType("boolean", "bit")` → true cho MySQL/MariaDB (BIT(1) expected-side guard).
- `AssertionDetail.expected` = `data_type` từ config, `actual` = chuỗi trả về DB, `passed` = `sameType` result.

**Ví dụ config:**
```json
{
  "connection": {"db_type":"postgres","database":"bookstore","username":"u","password":"p"},
  "checks": [
    {"kind":"TABLE_EXISTS","table_name":"books"},
    {"kind":"COLUMN_EXISTS","table_name":"books","column_name":"title","data_type":"varchar"},
    {"kind":"PRIMARY_KEY","table_name":"books","column":"id"},
    {"kind":"INDEX_EXISTS","table_name":"books","index_name":"idx_books_title"}
  ]
}
```
**Output:** Một `AssertionDetail` per check → `assertionResult` = JSON mảng 4 phần tử.

### 5.3 `DB_MIGRATION` — `DbMigrationExecutor`

**Mục:** Chạy từng câu DML/DDL của giảng viên trong MỘT transaction — commit tất cả hoặc rollback tất cả. *(Atomicity engine-dependent: PostgreSQL honours DDL+DDL; MySQL/MariaDB force an implicit commit on DDL, so DDL migrations there are best-effort.)*

```
execute(StepContext ctx):
  config, hostPort
  timeoutMs  = config.path("timeoutMs") != null ? config.path("timeoutMs") : ctx.timeoutMs()
  deadline   = now() + timeoutMs       // single wall-clock budget cho toàn bộ migration
  details = [] (không có assertion)

  db.withConnection(config, hostPort, timeoutMs, conn -> {
    conn.setAutoCommit(false)
    try:
      for stmt in config.path("statements"):
        remaining = deadline - now()
        if remaining <= 0: throw DbStepTimeoutException(SQL_TIMEOUT_ERROR + timeoutMs)
        try (PreparedStatement ps = conn.prepareStatement(substitute(stmt.asText()))) {
          ps.setQueryTimeout(max(1, ceil(remaining / 1000)))  // thời gian còn lại
          ps.executeUpdate()
        }
      conn.commit()                    // tất cả thành công
    catch SQLException e:
      conn.rollback()                  // rollback toàn bộ
      throw e                          // để catch bên ngoài báo ERROR
    finally:
      conn.setAutoCommit(true)         // restore cho bước kế tiếp
    return null
  })

  return PASSED (không có assertion)
```

**Ghi chú:**
- `statements[]`: mảng chuỗi SQL, mỗi câu được `substitute(${var})`.
- `PreparedStatement` cho mọi statement (dù DDL hay DML) để tránh injection.
- DDL trong một transaction là dialect-specific (PG hỗ trợ, MySQL một số DDL implicit-commit) — đây là caveat đã được document trong thiết kế.
- Không có `assertionResult`, không có `extractedVariables` (by design).

**Ví dụ config:**
```json
{
  "connection": {"db_type":"mysql","database":"bookstore","username":"root","password":"root"},
  "statements": [
    "INSERT INTO books (id, title) VALUES ('1', 'Bài A')",
    "INSERT INTO books (id, title) VALUES ('2', 'Bài B')"
  ]
}
```

---

## 6. Xây dựng `GradingStepResult`

Mọi executor đều trả về `GradingStepResult` thông qua `DbStepResults.buildResult(mapper, ctx, stepType, status, details, err, started)`:

```
buildResult(mapper, ctx, stepType, status, details, err, started):
  assertionJson = details.isEmpty() ? null : mapper.writeValueAsString(details)
  durationMs = now() - started
  return GradingStepResult.builder()
      .jobId(ctx.jobId()).planId(ctx.planId()).stepId(ctx.stepId())
      .stepOrder(ctx.stepOrder()).stepName(ctx.stepName())
      .stepType(stepType).status(status)
      .assertionResult(assertionJson)    // null nếu không có assertion (DB_MIGRATION)
      .errorMessage(err)                  // null nếu PASSED
      .durationMs(durationMs)
      .startedAt(OffsetDateTime.now()
              .minusNanos((System.currentTimeMillis() - started) * 1_000_000L))
      .completedAt(OffsetDateTime.now())
      .build()
```

| status | `assertionResult` | `errorMessage` | `extractedVariables` |
|---|---|---|---|
| `PASSED` | JSON mảng assertion (hoặc null với DB_MIGRATION) | null | null |
| `FAILED` | JSON mảng assertion (có `passed=false`) | null | null |
| `ERROR` | null | `"Connection failed using dialect '...'"` hoặc `"DB step SQL error: ..."` | null |

---

## 7. Xử lý lỗi — phân biệt connection failure vs SQL error

`runSteps` wrap `executor.execute()` trong `try/catch (Exception e)` → persist `ERROR` với `safeMessage(e)`.

`runSteps` wrap `executor.execute()` trong `try/catch (Exception e)` → persist `ERROR` với `safeMessage(e)`. Mỗi executor catch `SQLException` và phân biệt nguồn gốc qua **exception type** (thay vì `e.getCause()` sniffe cũ):

- **`DbConnectionException`** (connect retry exhaustion): message đã chứa dialect hint → surface verbatim (**không** thêm prefix `SQL_EXECUTION_ERROR`).
- **`DbStepTimeoutException`** (budget exhaustion — connect hoặc migration): message đã chứa `SQL_TIMEOUT_ERROR` → surface verbatim.
- **SQL / execution failure** (bên trong lambda executor — câu SQL của giảng viên lỗi): bất kỳ `SQLException` nào khác → thêm prefix `"DB step SQL error: "`.
- **Unknown `db_type`** (legacy row không bị `StepConfigValidator` chặn):
- **Unknown `db_type`** (legacy row không bị `StepConfigValidator` chặn):
```
IllegalArgumentException: "Unknown db_type: oracle"
```
→ NOT caught bởi executor (không phải SQLException) → `runSteps` catch → `ERROR`.

**`errorMessage` carries the message exactly once** — `DbStepResults.message(SQLException)` already names the prefix (or verbatim for `DbConnectionException`/`DbStepTimeoutException`), so callers must pass it alone; never append `e.getMessage()` again. See `.opencode/skills/executor-grading/SKILL.md`.

**Lưu ý về statement timeout từ driver:** pgjdbc (`PSQLException`, SQLSTATE 57014) và MySQL (`MySQLTimeoutException`) đều report timeout với `cause == null`, nên không thể phân biệt với một syntax error chỉ qua `getCause()`. Đó là lý do rule trên dùng **exception type do chính helper throw** (không phải `getCause()`). Statement-level driver timeout vì vậy vẫn mang prefix `SQL_EXECUTION_ERROR` — là trade-off đã biết, sẽ xử lý riêng nếu cần.

---

## 8. Lớp dialect — engine-agnostic trong executor

`DbDialectRegistry` bean-collects tất cả `@Component` `DbDialect` (hiện tại `PostgresDialect`, `MysqlDialect`). MariaDB resolve cùng instance `MysqlDialect` (alias).

Mỗi dialect cung cấp:
- `jdbcUrl(int hostPort, String database)` → `jdbc:postgresql://host:port/db` hoặc `jdbc:mysql://host:port/db?useSSL=false&...`
- `tableExistsSql()`, `columnExistsSql()`, `primaryKeySql()`, `indexExistsSql()` → câu query thông-schema engine-specific (dùng `?` params)
- `sameType(String expected, String actual)` → normalize engine-specific type names trước khi so sánh

**Thêm engine mới** = thêm 1 `@Component` triển khai `DbDialect` + `DbDialectRegistry` tự collect. Executor không thay đổi.

---

## 9. Axis 2 seam — không ảnh hưởng

DB executor chạy **bên trong** `runSteps` (sau khi compose boot đã hoàn tất). Do đó:
- `ENSURE_IMAGES` saga step vẫn **rỗng** — không có DB image nào cần pull trước khi bước chạy.
- `DockerComposePatcher` không thay đổi.
- `ExecutorProperties` nested-record pattern giữ nguyên (future `ImageScan` có thể thêm mà không phá cấu trúc).

---

## 10. Thứ tự thực thi tổng thể

```
GradingOrchestrator.grade(job):
  allocate port → vars.put("db_port", dbPort)
  composeRunner.boot()                          // student app + DB container up
  runSteps(job, plan, steps, vars):
    for each step in steps:
      runStep(job, plan, step, vars):
        if step.type == "HTTP_REQUEST":
          HttpStepExecutor.execute(ctx)
        else if step.type == "DB_QUERY":
          DbQueryExecutor.execute(ctx)
            └─ DbConnectionHelper.withConnection(config, dbPort, timeoutMs, action)
        else if step.type == "DB_SCHEMA_CHECK":
          DbSchemaCheckExecutor.execute(ctx)
            └─ DbConnectionHelper.withConnection(config, dbPort, timeoutMs, action)
        else if step.type == "DB_MIGRATION":
          DbMigrationExecutor.execute(ctx)
            └─ DbConnectionHelper.withConnection(config, dbPort, timeoutMs, action)
        else:
          → FAILED (UNKNOWN_STEP_TYPE)
        persist(result)
  finally: release port
```

---

## 11. Test coverage

| Test file | Loại | Số test | Mô tả |
|---|---|---|---|
| `DbConnectionHelperTest` | Unit | 5 | `resolve` (null/mysql/mariadb/case/fold/unknown), retry + dialect-hint |
| `DbQueryExecutorTest` | Unit (mock) | 4 | passed (row+columns), row mismatch, connection error |
| `DbSchemaCheckExecutorTest` | Unit (mock) | 5 | all pass, failing check, `sameType`, connection error |
| `DbMigrationExecutorTest` | Unit (mock) | 3 | all succeed (commit), statement fail (rollback) |
| `AssertionEngineTest` | Unit | 16 | AssertionEngine logic |
| `DbDialectTest` + `DbDialectRegistryTest` | Unit | 20 | Dialect SQL + `sameType` + registry |

Tất cả 3 executor test dùng **mock** `DbConnectionHelper` (no Docker) → nhanh, hermetic, ổn định. `DbConnectionHelper` retry/hint test dùng `DriverManager` kết nối localhost:1 (refused) → ~4s, 1 test duy nhất.

---

## 12. Các file liên quan

| File | Vai trò |
|---|---|
| `service/db/DbConnectionHelper.java` | Mở JDBC connection, retry, dialect hint |
| `service/db/DbDialectRegistry.java` | Bean-collect `DbDialect` |
| `service/db/DbDialect.java` | Interface dialect (SQL, URL, `sameType`) |
| `service/db/PostgresDialect.java` | Postgres dialect |
| `service/db/MysqlDialect.java` | MySQL/MariaDB dialect |
| `service/step/DbQueryExecutor.java` | `DB_QUERY` executor |
| `service/step/DbSchemaCheckExecutor.java` | `DB_SCHEMA_CHECK` executor |
| `service/step/DbMigrationExecutor.java` | `DB_MIGRATION` executor |
| `service/step/DbStepResults.java` | Shared `GradingStepResult` factory |
| `Constant.java` (`DbStep`, `DbConnection`, `Message.Db`) | String constants + messages |
| `service/step/StepRegistry.java` | Bean-collected executor registry |
| `service/GradingOrchestrator.java` (`runStep`) | Cầu nối → `executor.execute(StepContext)` |
