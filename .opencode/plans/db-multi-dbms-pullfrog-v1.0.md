# Plan: Pullfrog fixes for DB multi-DBMS dialect layer — v1.0

> **Date:** 2026-09-26
> **Version:** v1.0
> **Status:** Approved — executing
> **PR:** #17
> **Review:** `Review: 2026-09-26, Pullfrog PR #17`
> **Scope:** Fix the 4 ⚠️ findings and the 2 ℹ️ items that have an easy safe fix;
> leave optional extras (`int2`/`int8`/`float4` aliases, MySQL `BIT(1)`-as-boolean,
> hard-fail for second differing DB step) as tracked follow-ups.
> **Related:** `.opencode/plans/db-multi-dbms-v1.0.md` (original multi-DBMS plan)
>
> ---
>
> ## Problem statement (from the review)
>
> The dialect layer landed in a shape that passes unit tests but is provably wrong
> against a real server in three places (`MysqlDialect.normalize` boolean branch
> unreachable via `data_type`; `PostgresDialect.normalize` missing `character` and
> the `time` family), plus a port/workDir lifecycle hole in `grade()`,
> an unvalidated `database` JDBC-URL primitive, an unvalidated `db_port`,
> and a four-way duplicated allow-set.
>
> ---
>
> ## Design decisions (already decided)
>
> - **F1 lifecycle**: move `scanDbRequirements` + unknown-engine `fail` ABOVE the
>   download (scan needs only `plans`); one `try` opens after download; sentinels
>   `workDir = null`, `appPort = -1`, `dbPort = null`, `bootRow = null`; `finally`
>   covers parseError-WARN → claims → `bootRow` → boot/run; catch guards
>   `bootRow != null && !booted`. `PortAllocator.release()` range-guards, so
>   `release(-1)` is a safe no-op.
> - **F2**: `MysqlDialect.columnExistsSql` projects `column_type` (not `data_type`)
>   so MySQL 8 + MariaDB report `tinyint(1)` for `BOOLEAN`. Update `DbDialect`
>   Javadoc contract. `tinyint(4)` stays non-boolean.
> - **F3**: PG switch adds `character → char`, `time without time zone → time`,
>   `time with time zone → timetz` only (`int2`/`int8`/`float4` are follow-ups).
> - **F4**: validator checks `connection.database` present → `^[A-Za-z0-9_$]+$`
>   else 400; both dialects call a shared identifier guard in `jdbcUrl()`; no
>   `requireText` (would break existing connection tests that omit `database`).
> - **F5**: validator mirrors the `expected_status` pattern (`:77–82`) for
>   `db_port` (1..65535, present && (`!isInt` || `<1` || `>65535`) → 400); scan
>   falls out-of-range to the dialect default + `log.warn`; Javadoc notes
>   `connection.db_port` = **container** port vs `${db_port}` = **host** port.
> - **F6**: executor registry message built from sorted `byKey.keySet()`;
>   delete `Constant.DbConnection.ALLOWED_DB_TYPES`; validator message built from
>   sorted `DB_TYPES`; update order-sensitive assertions. Cross-service drift
>   acknowledged (separate Maven projects, no cross-test possible).
> - **F7**: second differing DB step → `log.warn` naming the ignored step;
>   first-wins preserved.
> - **F8**: pom comment + `grading-config-reference.md` §3.5 sequencing note
>   (DB steps still `UNKNOWN_STEP_TYPE` until Phase 2).
> - **F9**: `Review: 2026-09-26, Pullfrog PR #17` above each fix block
>   (AGENTS.md "Code comments for future review").
>
> ---
>
> ## Execution steps
>
> ### F1 — GradingOrchestrator lifecycle (highest priority)
>
> 1. Add `ArtifactService artifacts` to the test `Fixture` record (needed for the
>    never-called assertion).
> 2. Move the `scanDbRequirements` block + `catch (IllegalArgumentException)`
>    + `fail()` return to **before** `job.setStatus(BUILDING)` (i.e. before
>    `artifactService.fetchWorkDir`).
> 3. Replace the standalone `int appPort = claim()` / `dbPort` block and the
>    `UUID bootRow` declaration with sentinel declarations before a single `try`:
>    ```java
>    Path workDir = null;
>    int appPort = -1;
>    Integer dbPort = null;
>    UUID bootRow = null;
>    boolean booted = false;
>    try {
>        // download (fetchWorkDir) still inside its own inner try/catch for the
>        // DOWNLOAD saga row; on failure it returns before the outer try.
>        if (dbReq.parseError() != null) log.warn(...);
>        appPort = portAllocator.claim();
>        if (dbReq.present()) { dbPort = portAllocator.claimDbPort(); ... }
>        executionTimeoutMs / startupTimeoutMs;
>        bootRow = sagaTracker.step(BOOT_COMPOSE, ...);
>        // boot + runSteps (unchanged)
>    } catch (Exception e) {
>        if (bootRow != null && !booted)
>            sagaTracker.finishStep(bootRow, SagaStepStatus.FAILED, safeMessage(e));
>        fail(job, ..., 1, Constant.Message.FAILED_GRADING_INFRA + safeMessage(e));
>    } finally {
>        portAllocator.release(appPort);       // -1 → no-op (range-guarded)
>        if (dbPort != null) portAllocator.release(dbPort);
>        if (workDir != null) cleanupWorkDir(workDir);
>    }
>    ```
>    `sagaTracker.step(BOOT_COMPOSE, ...)` moves **inside** the try (so a claim
>    throw leaves `bootRow == null` → catch skips it safely).
> 4. `writeEffectiveCompose` call and surrounding boot/run body unchanged.
>
> ### F2–F5 — Dialect + validator corrections
>
> - **F2**: `MysqlDialect.columnExistsSql` → `SELECT column_type FROM ...`;
>   `DbDialect.columnExistsSql()` Javadoc updated to "type descriptor" (PG
>   `data_type`; MySQL `column_type` — includes width, so `tinyint(1)` survives).
> - **F3**: `PostgresDialect.normalize` add three cases.
> - **F4**: `StepConfigValidator.validateConnection` — present `database` must match
>   `^[A-Za-z0-9_$]+$`; both dialects' `jdbcUrl` call a shared `DbDialect` guard
>   (`static String requireSafeDatabase(String)` throwing `IllegalArgumentException`).
> - **F5**: `StepConfigValidator.validateConnection` — `db_port` range check mirror
>   `expected_status` pattern; `GradingOrchestrator.scanDbRequirements` —
>   `dbContainerPort` out of 1..65535 → fall to dialect default + `log.warn`;
>   scan Javadoc adds the container-vs-host naming note.
>
> ### F6–F7 — Single-source allow-set + second-DB-step visibility
>
> - **F6**: `DbDialectRegistry.resolve` message from `byKey.keySet().stream().sorted()`;
>   delete `Constant.DbConnection.ALLOWED_DB_TYPES` and its `List` import (if unused);
>   validator message from sorted `DB_TYPES`; update test assertions to
>   `mariadb, mysql, postgres` (sorted); update the cross-service comment on both
>   sides.
> - **F7**: `scanDbRequirements` continues the loop after the first DB step; when a
>   later `DB_*` step has a different `dbService`/`dbType`, `log.warn` names it
>   (step name + type + its db_service) and keeps the first result.
>
> ### F8–F9 — Docs/comments
>
> - **F8**: `executor-service/pom.xml` mysql-driver comment adds the MariaDB support-
>   matrix note (ed25519/PARSEC → MariaDB error 1251; Boot BOM manages
>   `org.mariadb.jdbc:mariadb-java-client`); `grading-config-reference.md` §3.5
>   adds "DB steps still fail `UNKNOWN_STEP_TYPE` until Phase 2 executors land".
> - **F9**: `Review: 2026-09-26, Pullfrog PR #17` above each fix block in production
>   code.
>
> ---
>
> ## Tests
>
> | File | New/changed assertions |
> |---|---|
> | `GradingOrchestratorTest.Fixture` | gains `ArtifactService artifacts` field |
> | `GradingOrchestratorTest` | `unknownDbType_failsJobBeforeAnyPortClaim`: assert
>   `fetchWorkDir` never called; `claimDbPortThrows_appPortReleasedAndWorkDirCleaned`:
>   job FAILED, `release(23456)`, `Files.notExists(workDir)`, no step results |
> | `DbDialectTest` | SQL projects `column_type` (MySQL); sameType vs realistic values
>   (`tinyint(1)`→boolean, `tinyint(4)`→not boolean); PG `character`/`time` cases |
> | `DbDialectRegistryTest` | unknown-key message order `mariadb, mysql, postgres` |
> | `StepConfigValidatorTest` | injection `database` → 400; `db_port` 0/70000/"abc" → 400,
>   3306 passes; existing known-db_type tests still pass (omit `database`) |
> | `DockerComposePatcherTest` | unchanged |
>
> Full suite: expect the same 2 pre-existing `contextLoads` infra failures
> (no local Postgres) on both services.
>
> ---
>
> ## Follow-ups (explicitly deferred — not in this PR)
>
> - `int2`/`int8`/`float4` PG aliases (`default` arm covers `real`; optional).
> - MySQL `BIT(1)`-as-boolean (needs a `bit(1)` case; not required).
> - Hard-fail instead of WARN for a second differing DB step (log chosen;
>   no new failure mode).
> - A cross-service test proving executor `ALLOWED_DB_TYPES` equals validator
>   `DB_TYPES` — impossible across separate Maven projects without a shared
>   dependency; documented duplication accepted.
> - Phase 2 DB executors + async image pre-pull feature (separate plan).
>
> ---
>
> ## Verification
>
> 1. Targeted: `mvn test -f src-services/executor-service/pom.xml
>    -Dtest='GradingOrchestratorTest,DbDialectRegistryTest,DbDialectTest,
>    DockerComposePatcherTest'` → all pass
> 2. Targeted: `mvn test -f src-services/course-service/pom.xml
>    -Dtest=StepConfigValidatorTest` → all pass
> 3. Full suites both services → only pre-existing `contextLoads` failures
> 4. Docs/skill readback for accuracy
