# Plan: Multi-DBMS Support (explicit db_type) — Detailed

> **Date:** 2026-09-26
> **Version:** v1.0
> **Status:** Done — all 9 steps implemented and verified (executor 139/140,
> course 87/88; the 2 failures are pre-existing `contextLoads` infra tests that
> need a live local Postgres)
> **Scope:** Make DB grading engine-agnostic (postgres/mysql/mariadb) so any SQL DBMS
> docker image chosen by the lecturer works; structure the code to leave seams for the
> future lecturer image-registration + async image-pull feature.
> **Related:** `.opencode/plans/db-schema-grading-v1.0.md` (3-phase plan, Phase 1 done) ·
> `.opencode/plans/db-schema-grading-phase1-detail.md` · `docs/design/design-db-v1.0.md` §2.3

---

## Problem

Current DB grading settings are PostgreSQL-only:

1. `Constant.DbConnection.DB_PORT_DEFAULT = 5432` hardcoded (Phase 1 pre-scan default).
2. Planned Phase 2 schema SQLs are PG-specific (`pg_indexes`, `table_schema='public'`).
3. Planned JDBC URL is `jdbc:postgresql://...` only.
4. No MySQL/MariaDB JDBC driver in the repo.
5. No engine field exists anywhere — validator never inspects the `connection` block.

Lecturer picks the DB image in compose (`postgres:16`, `mysql:8`, `mariadb:11`, ...);
the system must connect and run schema checks engine-agnostically.

## Two axes (architectural invariant)

- **Axis 1 (this plan): how to talk to the DB** → dialect layer, keyed by `connection.db_type`.
  A custom image `myfork/postgres:15-custom` still uses the postgres dialect.
- **Axis 2 (future): getting bytes on the box** → image inventory + async scan/pull of
  lecturer-registered images (DB images, Java SDK, ...). Persistence already designed:
  `docker_images` + `assignment_docker_images` tables exist in `design-db-v1.0.md` §2.2.

They meet at exactly one seam: the boot phase in `grade()`.

## Decision (user, 2026-09-26)

Engine detection = **explicit `connection.db_type` only** (option 1 of 3 discussed).
No auto-inference from compose image names. `db_type` optional, default `postgres`
(backward compatible with saved configs); image inference can be layered later without
breaking anything.

---

## Config change (lecturer-facing)

```json
"connection": {
  "db_type": "mysql",
  "db_service": "db",
  "db_port": 3306,
  "database": "bookstore",
  "username": "root",
  "password": "root"
}
```

| Field | Required | Default | Notes |
|---|---|---|---|
| `db_type` | no | `postgres` | `postgres` \| `mysql` \| `mariadb`, case-insensitive. MariaDB = MySQL dialect alias (wire-compatible) |
| `db_port` | no | dialect default (5432/3306) | container-internal port |
| `db_service`, `database`, `username`, `password` | unchanged | — | — |

---

## Execution steps

### Step 1 — `StepConfigValidator` (course-service)

New helper `validateConnection(JsonNode c, String ctx)` called from
`validateDbQuery`, `validateSchemaCheck`, `validateMigration`:

- if `connection` present and not null → must be `object`, else throw
- if `connection.db_type` present → lowercased must be in
  `Set.of("postgres","mysql","mariadb")`, else throw naming allowed values
- unknown keys tolerated (existing forward-compat convention)

### Step 2 — new package `executor-service/.../service/db/`

**`DbDialect`** (interface):

```java
public interface DbDialect {
    String key();                                   // "postgres" | "mysql" | "mariadb"
    int defaultPort();                              // 5432 / 3306
    String jdbcUrl(int hostPort, String database);  // driver-specific URL + params
    String tableExistsSql();
    String columnExistsSql();
    String primaryKeySql();
    String indexExistsSql();
    boolean sameType(String expected, String actual); // normalization for COLUMN_EXISTS data_type
}
```

**`PostgresDialect`** (`@Component`):
- URL: `jdbc:postgresql://localhost:{hostPort}/{database}`
- schema filter: `table_schema = 'public'` (PG `information_schema` spans all schemas)
- index: `pg_indexes WHERE indexname = ?` (also scope `tablename`)
- `sameType`: normalize `character varying`→`varchar`, `timestamp with time zone`→`timestamptz`,
  compare case-insensitively after normalization

**`MysqlDialect`** (`@Component`, handles `mysql` + `mariadb` keys):
- URL: `jdbc:mysql://localhost:{hostPort}/{database}?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC`
  (docker mysql8 default auth `caching_sha2` needs `allowPublicKeyRetrieval` when SSL off)
- schema filter: `table_schema = DATABASE()` (MySQL `information_schema.table_schema` = db name)
- index: `information_schema.statistics WHERE index_name = ? AND table_schema = DATABASE()`
- `sameType`: normalize `int`→`integer`, `tinyint(1)`→`boolean`-ish tolerated, case-insensitive

**`DbDialectRegistry`** (`@Component`, **bean-collected — mirrors `StepRegistry`**):

```java
public DbDialectRegistry(List<DbDialect> dialects) {
    this.byKey = dialects.stream().collect(toUnmodifiableMap(DbDialect::key, identity()));
    // mariadb → same instance as mysql (alias) — MysqlDialect registers both keys
}
public DbDialect resolve(String key)   // null/blank → postgres; unknown → IllegalArgumentException
```

Adding a future engine = 1 new `@Component` class (+ maybe 1 driver dep), zero registry edits.

### Step 3 — `Constant.java`

- `DbConnection.DB_TYPE = "db_type"` key
- `DbConnection.ALLOWED_DB_TYPES` = `Set.of("postgres","mysql","mariadb")`
- `Message.Db` inner class with the dialect-hint error prefix:
  `CONNECTION_FAILED_DIALECT_HINT = " (connection attempted with dialect '"` ... —
  concrete format: `"Connection failed using dialect '<key>'. If your DB is MySQL/MariaDB, set connection.db_type"` —
  built in executor error path (Phase 2), constant defined now so message lives in one place.

### Step 4 — `GradingOrchestrator`: extract `scanDbRequirements()` + dialect default port

Replace the inline Phase-1 pre-scan loop with:

```java
private DbRequirements scanDbRequirements(List<InternalPlanDto> plans) { ... }
record DbRequirements(boolean present, String dbService, Integer dbContainerPort, String dbType) {}
```

- reads first `DB_*` step's `connection` block → `dbType` (null → absent)
- `dbContainerPort` from config; **null → `registry.resolve(dbType).defaultPort()`**
  (replaces hardcoded `5432` constant; `DB_PORT_DEFAULT` constant removed or kept only as
  PostgresDialect's own value)
- in `grade()`: `DbRequirements dbReq = scanDbRequirements(plans);` then
  `dbPort = dbReq.present() ? portAllocator.claimDbPort() : null;`
- **future image feature adds `scanImageRequirements(...)` beside this method** — named seam,
  no re-entrant surgery into port logic

Constructor gains `DbDialectRegistry` (field #14) — `@RequiredArgsConstructor`, all tests
constructing `GradingOrchestrator` directly must add the arg.

### Step 5 — `DockerComposePatcher` comment + reusable YAML helpers

- Line ~86 comment `jdbc:postgresql://localhost:<dbPort>/<database>` → generic
  `jdbc://localhost:<dbPort>/<database>` phrasing (comment-accuracy rule)
- Keep `load()` / `servicesOf()` static, side-effect-free, package-visible as-is —
  future image scanner enumerates `image:` entries through them instead of re-parsing YAML.

### Step 6 — Error-path hint

No DB executor exists yet (Phase 2). Constant from Step 3 is the deliverable now;
Phase 2 executors must use it when wrapping connection failures.

### Step 7 — `executor-service/pom.xml`

+ `com.mysql:mysql-connector-j` (version managed by Spring Boot BOM; `runtime` scope —
same as existing `org.postgresql:postgresql`; we only use `java.sql` interfaces at compile time).

### Step 8 — Tests

**course-service** `StepConfigValidatorTest`:
- `connection` with valid `db_type: "mysql"` → passes
- `connection.db_type: "oracle"` → throws naming allowed values
- `connection` not an object → throws
- `connection` absent → passes (default)

**executor-service**:
- `DbDialectRegistryTest`: default resolve (null/blank→postgres), `mariadb` alias →
  MySQL dialect instance, unknown key → IllegalArgumentException
- `DbDialectTest` (or per-dialect): URL shape + port interpolation for both dialects;
  `sameType` cases (`varchar` vs `character varying` = equal; `int` vs `integer` = equal;
  `varchar` vs `int` = not equal)
- `GradingOrchestratorTest`: plan with `db_type: "mysql"` and no `db_port` →
  allocated `db_port` context value uses 3306 default path (assert via pre-scan result /
  `scanDbRequirements` reflection or fixture spy); existing Phase-1 DB tests keep passing
  (postgres default unchanged)

### Step 9 — Docs + SKILL.md

- `docs/design/design-db-v1.0.md` §2.3: connection block table + `db_type` row
- `docs/design/grading-config-reference.md`: connection block section + allowed values
- `.opencode/skills/executor-grading/SKILL.md`:
  - new subsection: dialect pattern (bean-collected registry, how to add an engine)
  - "Future: image pre-pull" note naming the seam: `scanImageRequirements` sibling of
    `scanDbRequirements`, `ENSURE_IMAGES` saga step between pre-scan and `composeRunner.boot()`,
    or fully independent `@Scheduled` scanner; `ExecutorProperties` nested-record pattern
    for future `ImageScan` config; `docker_images`/`assignment_docker_images` tables already reserved

---

## Extension-point commitments (space to scale — user requirement)

1. `DbDialectRegistry` bean-collected (StepRegistry pattern) → engine = 1 class
2. `scanDbRequirements()` named seam → future `scanImageRequirements()` sits beside it
3. Documented boot insertion point for future `ENSURE_IMAGES` saga step (between
   pre-scan/port-claim and `composeRunner.boot()`) or independent `@Scheduled` scanner —
   plan does NOT hardcode which; no existing step reordering ever required
4. Patcher YAML helpers kept reusable for image enumeration
5. `ExecutorProperties` nested-record convention noted for future `ImageScan` config —
   no placeholder config added now (YAGNI)
6. Schema space already reserved (`docker_images`, `assignment_docker_images`) —
   this plan touches no schema
7. SKILL.md documents both axes + seam so later work follows the structure

No placeholder code, no speculative config: space lives in structure only.

## Out of scope

- Async image-scan/pull feature itself (separate plan, user's "latter instruction")
- Image auto-inference from compose (option 2/3, deferred — config stays compatible)
- Phase 2 DB executors (built after this, engine-agnostic by construction)
- Oracle/SQL Server/etc. dialects (registry makes them additive)

## Verification

1. course-service: `mvn test -pl . -Dtest=StepConfigValidatorTest` → all pass
2. executor-service: full `mvn test` → only pre-existing `contextLoads` error allowed
3. Docs/skill readback for accuracy
