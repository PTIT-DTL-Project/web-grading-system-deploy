---
name: executor-grading
description: Executor-service grading pipeline - Kafka GRADE_SUBMISSION consume, RustFS zip download, Testcontainers compose boot via DinD, HTTP step execution, scoring, result reporting, multi-DBMS DB grading (connection.db_type dialect layer). Use when touching executor-service grading flow, GradingOrchestrator, DockerComposeRunner/Patcher, step executors, DbDialect/service-db package, DB port pre-scan, or the result-service internal write API.
---

# Executor grading pipeline conventions

End-to-end flow: `wgs-events` (key=`submissionId`, envelope `{action:GRADE_SUBMISSION,
version, traceId, payload}`) → `WgsEventsConsumer` → `GradeSubmissionHandler`
(persist `PENDING`, unique `submission_id` = idempotency backstop) → async
`GradingOrchestrator.gradeAsync` → `POST /api/v1/internal/results` (result-service)
+ `PUT /api/v1/internal/submissions/{id}/status` (submission-service, executor-only).

## 1. Single-job gate (load-bearing)

One DinD daemon per pod + tight resources → `GradingOrchestrator`
relies on `@Async` concurrency control (no explicit `Semaphore`);
`gradeAsync` runs sequentially per job. Never parallelize without raising
dind limits AND `replicas`/partition math (`execute-plan-v1.0.md` §7).

## 2. Container boot via Testcontainers library (not CLI)

`DockerComposeRunner` uses Testcontainers `ComposeContainer` against
`DOCKER_HOST=tcp://localhost:2375` (DinD sidecar). The runtime image has no
`docker` CLI, so shelling out to `docker compose` is not an option.
`TESTCONTAINERS_RYUK_DISABLED=true` is set in the chart (Ryuk can't run in-pod).
`testcontainers` is a **compile**-scope dep in executor-service `pom.xml`.

## 3. Compose patching is pure logic (`DockerComposePatcher`)

`STUDENT_DOCKER_COMPOSE` requires `docker-compose.yml` in the zip root (else job
`FAILED`); `LECTURER_DOCKER_COMPOSE` writes the assignment template. App service =
first service with `ports`, fallback first service; port rewrite
`<allocated>:<dockerComposePort|8080>` from `PortAllocator` (20000–30000, in-pod
map); `deploy.resources.limits` injected on every service; `privileged:true` and
`docker.sock` mounts are rejected → job `FAILED`. All branches unit-tested, no
daemon needed. DB port patching (Phase 1, 2026-09-26): when any plan step has a
`DB_*` type, `grade()` calls `scanDbRequirements(plans)` — reads the first DB
step's `connection` block (`db_service`, `db_port`, `db_type`), resolves the
engine through `DbDialectRegistry` (unknown `db_type` → job FAILED *before* any
port is claimed; omitted `db_port` → dialect default 5432/3306) →
`PortAllocator.claimDbPort()` (same 20000–30000 BitSet as `claim()`, so app/DB
ports can't collide) →
`writeEffectiveCompose` appends `<hostPort>:<containerPort>` to that service's
`ports` list (never replaces); service missing from compose → WARN only, the DB
step later fails with a clear connection error. Released in `finally`.

## 4. Step execution scope (MVP)

Four step executors are registered in `StepRegistry`: `HTTP_REQUEST`,
`DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`. Unknown types resolve to a
`FAILED` step row with "Unknown step type" — never throw out of the loop.
Each DB executor runs inside the existing `runSteps` wrapper (after compose
boot) so the `ENSURE_IMAGES` slot stays empty — Axis 2 image pre-pull
remains a future seam. DB executors go through the dialect layer (§8) so
they are engine-agnostic from day one; connection failures wrap with
`Constant.Message.Db` dialect hint, lecturer SQL errors wrap with
`Constant.Message.Db.SQL_EXECUTION_ERROR`.
`planId != null` runs only that plan, else all plans sequentially.
Required-step failure stops the plan (rest `SKIPPED` + persisted rows), next plan
continues. Global `executionTimeoutMs` deadline → job `FAILED`.

## 5. Scoring (`ScoreCalculator`)

`score=(passedWeight/ranWeight)*10.00`, HALF_UP 2 decimals; `SKIPPED` excluded
from both sides; empty run = `0.00`; infra failure = `0`. Per-step item score =
weight if passed else 0. Summary: `Passed X/Y steps (P%), Score: S/10.00` +
`Failed: <step> — <reason>` list.

## 6. Persist-then-report ordering

Write `grading_jobs` `DONE`/`FAILED` (+ `completedAt`, `errorMessage`) BEFORE the
result-service Feign call; Feign and submission-status PATCH are defensive
(try/catch + warn) so a downstream outage never un-does a finished job.
`POST /api/v1/internal/results` → `201 {id}`; `is_latest` flips per
`(student, assignment, plan)` (`V2__..._plan_weight_and_latest.sql` partial unique
index). Read side: `GET /api/v1/results/{submissionId}` (public `ResultController`,
gateway-routed) returns one entry per graded plan with step rows; empty list while
queued/grading — callers poll. New internal endpoints need a Postman request with a real response
(or empty response + explicit note when the service can't boot).

## 7. Gotchas
- `AssertionEngine` must be a Spring bean (`@Component`) — `HttpStepExecutor`
  injects it; plain-class + `new` in tests only.
- `VariableContext` is per-job state: `new` per run, never a bean.
- `HttpStepExecutor` targets `http://localhost:${app_port}` — `app_port` must be
  seeded before the first step.
- `WgsEventsConsumer` swallows everything with auto-commit: poison payloads only
  log; the job row is the source of truth, not the offset.
- `GradingJob.rustfsPath` column exists (`V3` migration); handler persists it from
  the event payload for debuggability.
- Zip extraction must reject `..`/absolute entries (zip-slip); covered by
  `ArtifactServiceTest`.

## 8. Crash recovery + saga tracking (v1.2)

- `StaleJobReaper` (`@Scheduled`, `@EnableScheduling` on the app): re-enqueues
  non-terminal jobs (`PENDING`/`FETCHING`/`BUILDING`/`RUNNING`) older than
  `executor.reaper.stale-after-minutes` (default 30), bumps `retry_count`, skips
  past `max-attempts` (default 3). stale-after MUST exceed startup + execution
  timeouts or live jobs get double-graded.
- `SagaTracker` writes `grading_sagas` (one row per `grade()` run) +
  `grading_saga_steps` (phase rows + `STEP:<name>` rows with `plan_id`/`step_id`).
  Best-effort: swallows its own exceptions, returns null — tracking never breaks
  grading. "Which step of which plan is running" = `WHERE status='STARTED'`.
- `Constant.java` — shared constants: `VariableContext` (keys), `HttpStep` (config
  keys), `Assertion` (assertion fields), `DockerCompose` (compose fields),
  `Saga` (step names), `Message` (error/log message strings). All string literal
  keys and messages extracted here — no raw string literals in production code.
  Saga entities have NO `@SQLRestriction`/`deleted_at` and NO `attempt` column
  (best-effort tracking, terminal states need neither).
- `GradingOrchestrator.grade()` uses `safeMessage(e)` helper and `cleanupWorkDir()`
  instead of inline try-with-resources.
- All production code follows Allman bracket style (`{` on next line).
- **Jackson 3 (`tools.jackson`) uses `JsonNode.asString()`, not the deprecated
  `asText()`** — if you touch any code reading a JsonNode, use `.asString()`.
  See `java-spring-boot-backend/SKILL.md` §10 and `AGENTS.md`.

## 9. Multi-DBMS dialect layer + future image pre-pull seam (v1.1, 2026-09-26)

Two **orthogonal axes** — never conflate them:

- **Axis 1: how to talk to the DB** (built). Engine comes from explicit
  `connection.db_type` — default `postgres`, allow-set `{postgres, mysql,
  mariadb}` (case-insensitive; `mariadb` = alias of the `mysql` dialect,
  wire-compatible). No auto-inference from compose image names (user decision
  2026-09-26 — a custom `myfork/postgres:15` image still uses the postgres
  dialect). Package `service/db/`:
  - `DbDialect` interface: `keys()`, `defaultPort()`, `jdbcUrl(hostPort, db)`,
    4 schema-check SQLs (`tableExistsSql` → COUNT; `columnExistsSql` → returns
    `data_type` so existence+type = one query; `primaryKeySql`/`indexExistsSql`
    → COUNT), `sameType(expected, actual)` normalization.
  - `PostgresDialect` (5432, `table_schema='public'`, `pg_indexes`,
    alias normalization `character varying`→`varchar` etc.);
    `MysqlDialect` (3306, `table_schema=DATABASE()`,
    `information_schema.statistics`, strips display widths, `tinyint(1)`→boolean;
    URL MUST carry `useSSL=false&allowPublicKeyRetrieval=true` or mysql:8
    caching_sha2 auth fails).
  - `DbDialectRegistry` is **bean-collected** (StepRegistry pattern): adding an
    engine = 1 new `@Component` + maybe 1 driver dep, zero registry edits;
    blank/null key → default engine; unknown key → `IllegalArgumentException`
    listing `Constant.DbConnection.ALLOWED_DB_TYPES` (ordered list, not a
    Set — deterministic message). Guards default engine presence at startup.
  - Two-tier validation: `StepConfigValidator` (course-service) rejects unknown
    `db_type` at save time; `scanDbRequirements()` fails fast during grading
    (legacy rows) **before ports are claimed**. Connection-failure messages use
    `Constant.Message.Db` dialect hint. Drivers: `org.postgresql:postgresql` +
    `com.mysql:mysql-connector-j`, both `runtime` scope.
  - DB_QUERY/DB_MIGRATION SQL stays **lecturer-written** (engine-specific by
    nature); only schema-check SQL + JDBC URLs are dialect-owned.
   - **DB error-labelling rule (durable):** `DbStepResults.message(SQLException)` is the single place that decides the `errorMessage` prefix. `DbConnectionException` (connect retry exhausted) and `DbStepTimeoutException` (budget exhausted) surface their message verbatim; every other `SQLException` is prefixed `Constant.Message.Db.SQL_EXECUTION_ERROR`. The three DB executors call `DbStepResults.message(e)`, never a local variant. `withConnection` throws `DbConnectionException` / `DbStepTimeoutException`; never a plain `SQLException`.
     See `docs/design/vi/db-step-execution-flow-v1.0.md` §7.
   - **Per-step DB budget = one deadline across the list** (`DbQueryExecutor`, `DbSchemaCheckExecutor`, `DbMigrationExecutor`): compute `deadline = now() + timeoutMs` once, give each statement/check its remaining time (clamped ≥ 1 s), throw `DbStepTimeoutException` when spent. Partial results stay in `details`. Never `setQueryTimeout(timeoutMs/1000)` for every item — that is `N × budget`.
- **Axis 2: getting bytes on the box** (FUTURE — lecturer registers images
  like DB images/Java SDKs; async task scans and pulls missing ones). NOT
  built; structure reserved so it needs no surgery:
  1. `GradingOrchestrator.scanDbRequirements(plans)` is the **named seam** —
     its future sibling `scanImageRequirements(...)` sits beside it in `grade()`
     (same pre-boot phase, independent concern).
  2. Insertion point for a future `ENSURE_IMAGES` saga step: between the
     pre-scan/port-claim block and `composeRunner.boot()` — or an independent
     `@Scheduled` scanner if pulls must not block grading. Deliberately not
     fixed yet; either choice never reorders existing steps.
  3. `DockerComposePatcher.load()`/`servicesOf()` are static and
     side-effect-free — reuse them to enumerate `image:` entries instead of
     re-parsing YAML.
  4. Config will follow the `ExecutorProperties` nested-record pattern (e.g.
     a future `ImageScan` record). No placeholder config exists today (YAGNI).
  5. Persistence already designed: `docker_images` +
     `assignment_docker_images` (`design-db-v1.0.md` §2.2) — the feature needs
     no schema change.

## 10. DB integration tests (Testcontainers 2.x)

Module artifacts renamed in Testcontainers 2.x (managed by the Spring Boot 4 parent BOM — no version needed):
- `org.testcontainers:testcontainers-postgresql` (**not** `org.testcontainers:postgresql`, which 404s at 2.x)
- `org.testcontainers:testcontainers-mysql`
- `org.testcontainers:testcontainers-junit-jupiter`
Class packages: `org.testcontainers.postgresql.PostgreSQLContainer`, `org.testcontainers.mysql.MySQLContainer`.
Guard Docker availability with `org.testcontainers.DockerClientFactory.instance().isDockerAvailable()` (JUnit5 `Assumptions.assumeTrue`) — the suite skips cleanly when Docker is absent.

**Wiring recipe** (see `Db*Test` in `executor-service`): construct a real `DbConnectionHelper(new DbDialectRegistry(List.of(new PostgresDialect())))` and hand it to the executor; a single package-private `TestPostgresContainer` is shared across the three DB test classes, seeded once and kept clean with `DELETE FROM books` between tests. `VariableContext.DB_PORT` must be set to the container's mapped port; `${var}` substitutions in SQL must be quoted in the query string (e.g. `WHERE id = '${bookId}'`).

    - Never place a Docker assumption in `@BeforeAll`: a failing
      `Assumptions.assumeTrue` there aborts the whole class container
      so the pre-existing Mockito tests inside the same class vanish
      (`Tests run: 0, Skipped: 0`). Scope the gate to the container
      tests themselves and keep `@AfterAll` guarded (`stop()` is a
      no-op when the container never started).
    - Testcontainers 2.x package for the PostgreSQL container is
      `org.testcontainers.postgresql.PostgreSQLContainer`; the old
      `org.testcontainers.containers.PostgreSQLContainer` is
      `@Deprecated` in 2.0.5. Both classes are `@Deprecated` in the
      resolved 2.0.5 jars, so either compiles with one warning —
      use the new package.
    - MySQL DDL is non-atomic, so DDL-rollback tests are PostgreSQL
      only; MySQL tests cover connection/auth (`caching_sha2` via
      `useSSL=false&allowPublicKeyRetrieval=true`), schema-check
      dialect SQL, and DML migration commit/rollback.
    - CI test command: `mvn test -Dtest='!*ApplicationTests' -Dsurefire.failIfNoSpecifiedTests=false` runs
      per changed service (the matrix is generated by dorny/paths-filter).
      The flag excludes the pre-existing infra-failing `contextLoads`
      (`*ApplicationTests`) and is required because `api-gateway`
      has exactly one test class which is itself an `*ApplicationTests`,
      so without it the entry selects zero classes and would fail.
      Widen the step to each service as its suite is confirmed green in CI.
