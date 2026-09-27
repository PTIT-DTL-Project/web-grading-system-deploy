# Luồng chấm DB đa engine (multi-DBMS) — Trình bày chi tiết

> **Phiên bản:** v1.0
> **Ngày:** 2026-09-26
> **Trạng thái:** Đã triển khai
> **Liên quan:** `.opencode/plans/db-multi-dbms-v1.0.md` · `docs/design/design-db-v1.0.md` §2.3 · `docs/design/grading-config-reference.md` §3.5

---

## Mục lục

1. [Tổng quan — hai trục thiết kế](#1-tổng-quan--hai-trục-thiết-kế)
2. [Luồng `grade()` — từng bước](#2-luồng-grade--từng-bước)
3. [`scanDbRequirements(plans)` — pre-scan và phân giải engine](#3-scandbrequirementsplans--prescan-và-phân-giải-engine)
4. [Cấp port: appPort + dbPort](#4-cấp-port-appport--dbport)
5. [Patch compose & boot](#5-patch-compose--boot)
6. [`runSteps` — `db_port` vào VariableContext](#6-runsteps--db_port-vào-variablecontext)
7. [Finally — giải phóng port](#7-finally--giải-phóng-port)
8. [Lớp dialect (`service/db/`)](#8-lớp-dialect-service-db)
9. [Giai đoạn DB executor (Phase 2)](#9-giai-đoạn-db-executor-phase-2)
10. [Giai đoạn image pre-pull (Axis 2) — future, chỉ giữ seam](#10-giai-đoạn-image-pre-pull-axis-2--future-chỉ-gi�ữ-seam)
11. [Các trường hợp lỗi & hành vi tương ứng](#11-các-trường-hợp-lỗi--hành-vi-tương-ứng)
12. [Tóm tắt thứ tự thực thi](#12-tóm-tắt-thứ-tự-thực-thi)

---

## 1. Tổng quan — hai trục thiết kế

Hệ thống chấm DB hỗ trợ **nhiều engine** (Postgres, MySQL, MariaDB). Hai trục **độc lập** với nhau, giữ riêng để tránh rối:

| Trục | Ý nghĩa | Trạng thái |
|---|---|---|
| **Axis 1 — Nói chuyện với DB** | `connection.db_type` → chọn JDBC dialect, URL, SQL kiểm tra schema engine-specific | **Đã build** |
| **Axis 2 — Lấy bytes trên máy** | Lecturer đăng ký image (DB image, Java SDK…); async scan & pull image thiếu | **Future** — chỉ giữ seam |

Chúng gặp nhau tại **một điểm duy nhất**: giai đoạn pre-scan/boot trong `grade()`.

### Cấu hình của giảng viên

```json
{
  "connection": {
    "db_type": "mysql",
    "db_service": "db",
    "db_port": 3306,
    "database": "bookstore",
    "username": "root",
    "password": "root"
  }
}
```

| Field | Bắt buộc | Mặc định | Ghi chú |
|---|---|---|---|
| `db_type` | không | `postgres` | `postgres` \| `mysql` \| `mariadb`, không phân biệt hoa thường. MariaDB = alias của MySQL dialect (wire-compatible) |
| `db_port` | không | dialect default (5432 / 3306) | port **trong container**, không phải host port |
| `db_service` | không | — | service name trong compose của sinh viên |
| `database`, `username`, `password` | không | — | cần khi kết nối (Phase 2) |

Validation hai tầng:
- `StepConfigValidator` (course-service) chặn `db_type` lạ **lúc lưu step** → 400.
- `scanDbRequirements()` trong executor fail-fast **lúc chấm** (dữ liệu legacy) → job FAILED, **trước khi cấp port**.

---

## 2. Luồng `grade()` — từng bước

```
grade()
  │
  ├─ plans sắp xếp theo sequenceOrder, rỗng → fail("Assignment has no test plans")
  │
  ├─ job.status = BUILDING; lưu job
  │
  ├─ [Giai đoạn download]
  │     artifactService.fetchWorkDir(submissionId, rustfsPath)
  │     fail("Failed to download submission") nếu lỗi → return (không port nào bị claim)
  │
  ├─ [Giai đoạn pre-scan DB — mới]
  │     scanDbRequirements(plans)
  │       → biết dbService, dbContainerPort, dbType
  │       → engine sai → fail ngay, return (không appPort, không dbPort)
  │
  ├─ [Cấp port]
  │     appPort = portAllocator.claim()
  │     nếu dbReq.present(): dbPort = portAllocator.claimDbPort()
  │
  ├─ [Boot compose]
  │     writeEffectiveCompose(...)  // patch app + DB port vào compose
  │     composeRunner.boot(effective, startupTimeoutMs)
  │
  ├─ [Chấm]
  │     runSteps(job, ..., appPort, dbPort, ...)
  │       → db_port nằm trong VariableContext cho mọi step
  │
  └─ [Finally — luôn thực thi]
        release(appPort)
        nếu dbPort != null → release(dbPort)
        cleanupWorkDir(workDir)
```

---

## 3. `scanDbRequirements(plans)` — Pre-scan và phân giải engine

**Thay thế** vòng lặp inline cũ (Phase 1). Duyệt mọi plan/step, tìm **first DB step** (stepType bắt đầu bằng `DB_`), đọc block `connection` JSON, trích xuất 3 thứ:

| field | nguồn JSON | ý nghĩa |
|---|---|---|
| `dbService` | `connection.db_service` | service name trong compose để patch port |
| `dbContainerPort` | `connection.db_port` | port lecturer đặt (có thể thiếu) |
| `dbType` | `connection.db_type` | engine key; có thể null |

Hai việc xảy ra **bên trong scan, trước bất kỳ port nào**:

### 3.1 Phân giải default port theo engine

Nếu `dbContainerPort == null` (lecturer không đặt) → `dialectRegistry.resolve(dbType).defaultPort()`:

- `db_type` vắng mặt → default engine = **postgres** → **5432**
- `"mysql"` hoặc `"mariadb"` → **MysqlDialect** → **3306**
- `"oracle"` (hoặc khóa lạ) → `IllegalArgumentException`: `"Unknown db_type: oracle (allowed: postgres, mysql, mariadb)"`

### 3.2 Lỗi parse JSON

Nếu block `connection` bị malformed → bắt exception, lưu vào `parseError`. Record vẫn trả về thành công; `grade()` chỉ log **WARN** (không fail cứng).

```
if (scan throws IllegalArgumentException)
    → fail(job, ..., unknownEngine.getMessage())
    → return                       // status = FAILED, không port nào bị claim
if (parseError != null)
    → writeLog(WARN, "Failed to parse DB step connection config: ...")
```

**Named seam**: phương thức tương lai `scanImageRequirements(...)` sẽ ngồi bên cạnh nó — cùng giai đoạn pre-boot, hai mối quan tâm độc lập (Axis 1 vs Axis 2).

---

## 4. Cấp port: appPort + dbPort

```java
int appPort = portAllocator.claim();          // BitSet 20000–30000, luôn có
Integer dbPort = null;
if (dbReq.present())
    dbPort = portAllocator.claimDbPort();     // cùng BitSet, đảm bảo ≠ appPort
```

- `claim()` luôn chạy — app service luôn cần port.
- `claimDbPort()` chỉ chạy khi **có DB step** trong plan.
- `dbPort` ở đây là **host port** (port được publish ra host).
- `dbContainerPort` (port nghe trong container, 5432 hoặc 3306) đã được phân giải sẵn bên trong `scanDbRequirements`, nằm ở `dbReq.dbContainerPort()`.

Log INFO: `"DB port allocated: host=<dbPort> service=<dbService> db_type=<dbType>"`.

---

## 5. Patch compose & boot

```java
DockerComposePatcher.writeEffectiveCompose(workDir, strategy, template,
    appPort, dockerComposePort, maxCpu, maxMemoryMb,
    dbReq.dbService(), dbPort, dbReq.dbContainerPort());
```

Bên trong patcher, nhánh DB:

```
if (dbService != null && dbPort != null && dbContainerPort != null && dbContainerPort > 0)
    dbSvc = services[dbService]
    if dbSvc == null → WARN "DB service 'db' not found in compose — DB steps will fail to connect"
    else → append "<hostPort>:<containerPort>" vào dbSvc.ports
```

Compose nhận được, ví dụ: `ports: ["8080:8080", "23457:3306"]`. Như vậy:
- App container trong pod có thể JDBC-connect đến DB tại `localhost:23457`.
- DB nghe trên cổng nội bộ `3306`.

Comment được generic hóa từ `jdbc:postgresql://...` → `jdbc:<engine>://localhost:<dbPort>/<database>`.

Nếu plan **không có DB step** (`dbService == null`) hoặc compose **không có service đó** → **bỏ qua** patch; step sau đó fail với lỗi connection rõ ràng thay vì âm thầm.

`composeRunner.boot(effective, startupTimeoutMs)` khởi động compose (student app + service DB đã publish port).

---

## 6. `runSteps(...)` — `db_port` vào VariableContext

```java
VariableContext vars = new VariableContext();
vars.put("app_port", appPort);
if (dbPort != null)
    vars.put("db_port", dbPort);   // giá trị host port, có hoặc không tuỳ DB step
// rồi SUBMISSION_ID, ASSIGNMENT_ID, STUDENT_ID...
```

- `db_port` **có mặt** trong context của **mọi step** (kể cả HTTP step chạy trước DB step) — vì được `put` trước vòng lặp step.
- Giá trị là **host port** (ví dụ `23457`). Phase 2 DB executor sẽ dùng nó để xây JDBC URL: `jdbc:<engine>://localhost:23457/<database>` — **prefix do dialect sở hữu** (`jdbc:postgresql://` vs `jdbc:mysql://?useSSL=false...`).
- Không có DB step → `db_port` không có trong context (`null` khi đọc).

---

## 7. Finally — giải phóng port (không leak)

```java
finally
    portAllocator.release(appPort)
    if (dbPort != null) portAllocator.release(dbPort)
    cleanupWorkDir(workDir)
```

Thực thi **luôn**: cả đường `fail()` lẫn exception đều đi vào finally. Cả appPort lẫn dbPort đều trả về BitSet.

Lưu ý: bước `fail()` cho engine sai đã được **di chuyển ra trước** `claim()` → engine sai không gây leak cả appPort.

---

## 8. Lớp dialect (`service/db/`)

### 8.1 `DbDialect` (interface)

```java
String keys();                    // "postgres" | "mysql","mariadb"
int defaultPort();                // 5432 / 3306
String jdbcUrl(int hostPort, String database);  // driver-specific URL
String tableExistsSql();          // (table_name) → COUNT
String columnExistsSql();         // (table_name, column_name) → data_type
String primaryKeySql();           // (table_name, column_name) → COUNT
String indexExistsSql();          // (table_name, index_name) → COUNT
boolean sameType(String expected, String actual);  // so sánh sau normalize, case-insensitive
```

Contract:
- `tableExistsSql` → COUNT (>0 = tồn tại)
- `columnExistsSql` → trả về **data_type** (không row = thiếu column) — một query cover cả existence **lẫn type**, nên kiểm tra type không cần round-trip thứ 2
- `primaryKeySql`, `indexExistsSql` → COUNT

### 8.2 `PostgresDialect` (`@Component`)

- URL: `jdbc:postgresql://localhost:{hostPort}/{database}`
- Schema: `table_schema = 'public'` (PG information_schema trải nhiều schema)
- Index: `pg_indexes WHERE schemaname='public' AND tablename=? AND indexname=?`
- `sameType` normalize: `character varying`→`varchar`, `timestamp with time zone`→`timestamptz`, `timestamp without time zone`→`timestamp`, `double precision`→`float8`, `bool`→`boolean`, `int`→`integer`. Cắt display width `(255)`.

### 8.3 `MysqlDialect` (`@Component`, handles `mysql` + `mariadb`)

- URL: `jdbc:mysql://localhost:{hostPort}/{database}?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC`
  — mysql:8 mặc định auth `caching_sha2_password`; SSL tắt → client **bắt buộc** phải retrieve public key, nếu không mọi kết nối đều fail auth.
- Schema: `table_schema = DATABASE()` (MySQL information_schema.table_schema = tên DB)
- Index: `information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ?`
- `sameType` normalize: `tinyint(1)`→`boolean`, strip `(11)` widths, `int`/`integer`→`integer`.
- `mariadb` = alias → cùng instance với `mysql` (wire-compatible, 1 driver, 1 set SQL).

### 8.4 `DbDialectRegistry` (`@Component`, bean-collected — StepRegistry pattern)

```java
public DbDialectRegistry(List<DbDialect> dialects) { ... }   // Spring inject all @Component
public DbDialect resolve(String key) { ... }
```

- `dialects` được bean-collected: thêm engine = 1 `@Component` mới + có thể 1 dependency driver, **zero registry edit**.
- Khóa blank/null → default engine (postgres) — cấu hình lưu không có `db_type` vẫn hoạt động.
- Khóa lạ → `IllegalArgumentException`, liệt kê `Constant.DbConnection.ALLOWED_DB_TYPES` (**List có thứ tự**, nên message xác định).
- **Startup guard**: nếu không có dialect default (postgres) được đăng → `IllegalStateException`. Nếu không, mọi cấu hình thiếu `db_type` sẽ NPE sau.

---

## 9. Giai đoạn DB executor (Phase 2)

Ba executor đã build và đăng ký trong `StepRegistry`:
`DbQueryExecutor` (`DB_QUERY`), `DbSchemaCheckExecutor` (`DB_SCHEMA_CHECK`),
`DbMigrationExecutor` (`DB_MIGRATION`). Chúng **không** cần thay đổi khi thêm engine
mới — mọi thứ engine-specific đều nằm ở lớp dialect (§8): URL JDBC, driver,
thông tin schema SQL, và so sánh kiểu `sameType()`.

**Luồng thực thi** (mỗi step chạy trong `runSteps`, sau khi compose boot):
1. Đọc `db_port` từ `VariableContext` (cấp bởi `GradingOrchestrator` khi allocate port).
2. Lấy `connection` block từ config step → `DbDialectRegistry.resolve(db_type)` lấy dialect.
3. `DbConnectionHelper.withConnection(connection, hostPort, action)` mở JDBC
   connection (retries 5×1s khi fail, gói lỗi cuối cùng với dialect hint).
4. Executor chạy SQL theo loại:
   - `DB_QUERY`: chạy câu SQL của giảng viên, so sánh `expected.row_count` / `expected.columns`
     (case-insensitive, đúng thứ tự) → một `AssertionDetail` cho mỗi check.
   - `DB_SCHEMA_CHECK`: duyệt `checks[]`, mỗi check chạy query thông-schema engine-specific
     của dialect → một `AssertionDetail` per check (dùng `dialect.sameType()` để so sánh kiểu).
   - `DB_MIGRATION`: chạy từng statement trong một transaction (`autoCommit=false`,
     commit nếu hết bước, rollback nếu lỗi) → không assertion, PASSED nếu không exception.
5. Connection hoặc SQL failure → `StepResultStatus.ERROR` với message phân biệt:
   dialect-hint cho connection failure, `SQL_EXECUTION_ERROR` cho SQL failure.

**Config shape** (do `StepConfigValidator` course-service xác nhận):
- `connection`: `{db_type, db_service, database, username, password}` — xem §3.5.
- `query` (DB_QUERY): câu SQL, có thể dùng `${var}`. `expected`: `{row_count?, columns?}`.
- `checks` (DB_SCHEMA_CHECK): mảng `{kind, table_name, column_name?, data_type?, column?, index_name?}`.
- `statements` (DB_MIGRATION): mảng câu SQL.

Driver đã sẵn sàng: `org.postgresql:postgresql` + `com.mysql:mysql-connector-j` (scope `runtime`).

---

## 10. Giai đoạn image pre-pull (Axis 2) — future, chỉ giữ seam

Tính năng lecturer đăng ký image (DB image, Java SDK…) rồi async scan/pull image thiếu **chưa build**, nhưng cấu trúc đã được dành sẵn, không cần phẫu thuật khi đến lúc:

1. **`scanDbRequirements()` là named seam** — `scanImageRequirements(...)` tương lai sẽ ngồi bên cạnh nó trong `grade()`.
2. **Điểm chèn `ENSURE_IMAGES` saga step**: giữa block pre-scan/claim port và `composeRunner.boot()` — **hoặc** một `@Scheduled` scanner độc lập nếu việc pull không nên chặn grading. Kế hoạch không cố định lựa chọn nào; cả hai đều không yêu cầu reordered bước hiện tại.
3. **`DockerComposePatcher.load()` / `servicesOf()`** tĩnh + side-effect-free → tái sử dụng để duyệt entries `image:` thay vì parse lại YAML.
4. **Config**: sẽ theo pattern nested-record của `ExecutorProperties` (ví dụ future `ImageScan` record). Hiện tại không có placeholder config nào (YAGNI).
5. **Persistence đã thiết kế**: bảng `docker_images` + `assignment_docker_images` (`design-db-v1.0.md` §2.2) → feature không cần thay đổi schema.

---

## 11. Các trường hợp lỗi & hành vi tương ứng

| Trường hợp | Hành vi | Cổng bị leak? |
|---|---|---|
| Plan rỗng | `fail("Assignment has no test plans")` → return | Không (trước claim) |
| Download thất bại | `fail("Failed to download submission")` → return | Không (trước claim) |
| `db_type` lạ (ví dụ `"oracle"`) | `scanDbRequirements` throw → `fail("Unknown db_type: oracle (allowed: ...)")` → return | Không (claim ở **sau** scan) |
| JSON `connection` malformed | `parseError` → WARN log, tiếp tục chấm | Không |
| Không có DB step | `dbReq.present()==false` → không `claimDbPort`, không put `db_port` | Không |
| `dbService` không có trong compose | Patcher WARN, bỏ patch → step sau fail với lỗi connection rõ ràng | Không |
| Lỗi boot compose | catch → `fail(FAILED_GRADING_INFRA...)` → finally release app+db | Không (finally) |
| Lỗi khi chấm step | catch trong `runSteps` → fail job → finally release | Không (finally) |
| Job chạy timeout | `deadline` → break → finally release | Không (finally) |

---

## 12. Tóm tắt thứ tự thực thi

```
[1] Sắp xếp plan
[2] job = BUILDING
[3] fetchWorkDir (download zip)         ── fail sớm (không port)
[4] scanDbRequirements(plans)           ── engine sai → fail sớm (không port)
[5] appPort = claim()
[6] if DB present: dbPort = claimDbPort()
[7] writeEffectiveCompose (patch app + DB port)
[8] composeRunner.boot (student + DB)
[9] runSteps:
       put app_port, db_port vào VariableContext
       cho mọi step (HTTP + future DB)
[10] finally: release(appPort); release(dbPort); cleanupWorkDir
```

**Quy tắc bảo vệ port**: mọi `fail()` phát sinh từ lỗi **trước bước 5** đều không claim port; bước 6–10 luôn được `finally` bao phủ. Không có trường hợp nào leak port ở trạng thái hiện tại.

---

## 13. Quy ước Jackson 3 — `JsonNode.asString()`

Dự án dùng **Jackson 3** (`tools.jackson.databind.ObjectMapper`, Boot 4 tự cấu hình). Trong Jackson 3, phương thức `JsonNode.asText()` đã bị **deprecated** — thay bằng `JsonNode.asString()`.

- Toàn bộ code production phải dùng `.asString()` — **không dùng `.asText()`**.
- Khi sửa/edit bất kỳ file nào có `node.path(...).asText()` hoặc `node.get(...).asText()` → đổi sang `.asString()`.
- Các file liên quan: `GradingOrchestrator.java`, `GradingOrchestratorTest.java`, `StepConfigValidator.java`, `AssertionEngine.java`, `HttpStepExecutor.java`...
- Ghi nhận trong changelog: `docs/design/execute-plan-v1.0.md` (migration v1.2, 2026-09-12) và `AGENTS.md` / `java-spring-boot-backend/SKILL.md` §10.
