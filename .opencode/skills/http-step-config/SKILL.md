name = "http-step-config"
description = "Conventions for the grading HTTP step config: data[] data-driven loop, Loop Safety Governor, auto_inject_headers at plan scope, virtual threads + sendAsync, Faker/dynamic variables, DB Isolation Sandbox, and Dry-Run Mode in the executor-service grading engine."

# HTTP Step Config (grading engine) — conventions

## Trigger
Editing or reviewing HTTP_REQUEST step config handling in `executor-service` (`HttpStepExecutor`, `GradingOrchestrator`, `Constant`, `HttpClientConfig`, `DbSandboxService`, `DryRunController`) or course-service step validation (`StepConfigValidator`). Keywords: `data[]`, `auto_inject_headers`, `loop safety governor`, `virtual thread`, `sendAsync`, `Faker`, `VariableContext`, `AssertionEngine`, `db sandbox`, `DB isolation`, `dry-run`.

## data[] data-driven loop (executor-service)
- A step with a non-empty `data[]` array runs once per row. Each row's fields substitute `${field}` and `${index}` (0-based) into a deep copy of the config.
- Placeholders must live in **quoted JSON string positions** (e.g. `"year": "${year}"`). A raw unquoted token in a numeric position is not valid JSON and fails to parse.
- Rows substitute into a fresh config; the shared `VariableContext` is reused, so `${accessToken}`, `${$UUID}` and previously extracted vars still resolve per iteration.
- Extracts such as `bookId_${index}` are written into the **shared** context and survive the loop (later steps can read `${bookId_0}`…).
- Step status = PASSED only if every iteration passes; FAILED if any failed; ERROR if any errored. Assertion details and extracted variables are merged into the single step-result row; HTTP metadata comes from the last iteration. Each iteration logs its own `HttpLog` row.
- `StepContext.withConfig(JsonNode)` builds an iteration context sharing job/step/variables.

## Loop Safety Governor
- course-service `StepConfigValidator` rejects inline `data[]` with > 10 entries (400 at save) and requires each entry to be an object.
- executor `Constant.Loop.FOREACH_TRUNCATE = 20` truncates a large for-each at runtime so one lecturer cannot start thousands of requests in a step.
- `Constant.Loop.DATA_INLINE_MAX = 10` (executor) mirrors the validator's 10 (separate Maven modules → constant stated in both places).

## auto_inject_headers (plan scope, executor `GradingOrchestrator.runSteps`)
- Declared on a step (typically login), not on every step. It is **plan-scoped**: accumulated into a per-plan map and injected into every subsequent `HTTP_REQUEST` step in the same plan.
- Header templates are substituted against the current `VariableContext` at injection time, so `${accessToken}` resolves after the login step extracted it. Already-set headers on a step are not overridden.
- The key `auto_inject_headers` is removed from the config before reaching `HttpStepExecutor` (orchestrator concern, not an executor config key).
- course-service `StepConfigValidator` requires `auto_inject_headers` to be an object of string values (400 otherwise).

## Virtual Threads + sendAsync (Phase 4)
- `HttpStepExecutor` no longer calls blocking `HttpClient.send()`. Instead it submits `() -> httpClient.sendAsync(...).join()` to `Executors.newVirtualThreadPerTaskExecutor()`.
- A hanging/slow student app blocks a cheap virtual thread, not a scarce platform thread; throughput is much higher when many students submit simultaneously.
- `HttpClient` remains a singleton bean (thread-safe); `sendAsync()` is safe to call concurrently.
- `safeMessage(Throwable)` unwraps `ExecutionException`/`CompletionException` from the virtual-thread wrapper so the root-cause message (e.g. "Connection refused") is surfaced in step error messages.
- No new dependencies: uses `java.net.http.HttpClient` (JDK built-in) + `java.util.concurrent.Executors`.

## Faker / Dynamic variables (Phase 4)
- `VariableContext.resolveDynamic()` generates built-in `$`-prefixed tokens on every reference (never cached): `$UUID`, `$TIMESTAMP`, `$FAKER_NAME`, `$FAKER_BOOK_TITLE`, `$FAKER_WORD`, `$FAKER_EMAIL`.
- Unknown `$FAKER_*` tokens fall back to `faker-<random>` via `fakerFallback()` so the step never breaks.
- `Constant.VariableContext` holds all FAKER token constants (`FAKER_NAME`, `FAKER_BOOK_TITLE`, `FAKER_WORD`, `FAKER_EMAIL`, `DYNAMIC_FAKER_PREFIX = "$FAKER_"`).
- Faker values are deterministic (no external dependency) using small built-in word lists + `java.util.Random`.

## DB Isolation Sandbox (Phase 5)
- Each grading job claims its own `dbPort` via `PortAllocator.claimDbPort()`. The DB service port is published via `DockerComposePatcher.writeEffectiveCompose()`.
- `DbSandboxService.resetDatabase(connectionConfig, hostPort)` resets the DB between plans: connects to the system DB (`postgres` for PG, `mysql` for MySQL/MariaDB), terminates existing PG connections, then `DROP DATABASE IF EXISTS <db>; CREATE DATABASE <db>`.
- `GradingOrchestrator.runSteps` calls `dbSandbox.resetDatabase()` after each plan completes, so each plan starts with a pristine DB.
- `Constant.DbSandbox` holds SQL templates and system DB names.
- `DbRequirements` record now carries `database` (target DB name) extracted from the first DB step's config.
- **MySQL/MariaDB caveat:** DDL causes implicit commit. A failed migration leaves partial schema. Lecturers should keep DDL and DML in separate steps.
- MySQL/MariaDB alias: `mariadb` resolves to the MySQL dialect.

## Dry-Run Mode (Phase 6)

### Backend (executor-service)
- `GradingOrchestrator.dryRun(DryRunRequest)` — synchronous dry-run: downloads reference code zip, boots compose, runs all steps, **does NOT** persist `GradingStepResult` to DB, **does NOT** POST to result-service, **does NOT** patch submission status. Returns `DryRunReport` with per-step status, duration, extracted variables, and error messages.
- `DryRunController` — `POST /api/v1/internal/grading/dry-run`, accepts `DryRunRequest` (assignmentId, referenceCodeZipUrl, plans), returns `DryRunReport`.
- Internal-only endpoint — not exposed via the API gateway.
- Dry-run steps are collected in-memory; SKIPPED steps (due to required-step failure) are included in the report with `status = "SKIPPED"`.
- Default dry-run execution timeout: 5 minutes (300_000 ms).

### Frontend→Backend contract (course-service)
- `InternalAssignmentController.POST /api/v1/internal/assignments/{id}/dry-run` — lecturer calls this to dry-run a plan config. Normalizes `assignmentId` from the path variable, delegates to executor-service via `ExecutorInternalClient`.
- `ExecutorInternalClient` (Feign) — course-service → executor-service dry-run endpoint. Requires `feign.executor-service.url` property.
- Course-service DTOs (`DryRunRequest`, `DryRunReport`, `DryRunStepReport`) mirror executor-service DTOs via JSON structure (separate Maven modules, no shared classes).

## JSON Schema generation (Phase 7)

- `StepConfigValidator.generateHttpSchema()` returns a JSON Schema (draft-07) `JsonNode` describing the HTTP_REQUEST step config structure accepted by `validateAndSerialize`.
- Schema covers: `method` (enum), `path` (pattern `^/`), `expected_status` (integer 100–599), `headers` (object), `query_params` (object), `body` (JSON), `assertions` (array with kind enum + recursive any_of), `extract` (array with name/from/expression/as/fallback), `data` (array of objects), `auto_inject_headers` (object).
- Schema is generated fresh each call — safe to mutate by callers.
- `InternalAssignmentController.GET /api/v1/internal/assignments/{id}/config-schema` — returns the schema as `JsonNode`. Internal-only endpoint, not gateway-exposed.
- Course-service DTOs (`DryRunRequest`, `DryRunReport`, `DryRunStepReport`) mirror executor-service DTOs via JSON structure (separate Maven modules, no shared classes).

## Constants (executor-service `Constant.java`)
- `HttpStep.DATA = "data"`, `HttpStep.AUTO_INJECT_HEADERS = "auto_inject_headers"`.
- `Loop.DATA_INLINE_MAX = 10`, `Loop.FOREACH_TRUNCATE = 20`.
- `DbSandbox.PG_SYSTEM_DB`, `DbSandbox.MYSQL_SYSTEM_DB`, `DbSandbox.PG_DROP_DB`, `DbSandbox.PG_CREATE_DB`, `DbSandbox.PG_TERMINATE_CONNECTIONS`, `DbSandbox.MYSQL_DROP_DB`, `DbSandbox.MYSQL_CREATE_DB`, `DbSandbox.RESET_TIMEOUT_MS`.
- Assertion kind `ANY_OF = "any_of"` (already implemented in `AssertionEngine.checkAnyOf` + validator).
- No new dependencies: substitution uses `tools.jackson.databind.ObjectMapper` tree walk (`.properties()` on objects, enhanced-for on arrays), not string regex on raw JSON.

## Validation (course-service `StepConfigValidator.validateHttp`)
- `data`: non-empty array, entries objects, ≤ 10 entries.
- `auto_inject_headers`: object of strings.
- Reuse existing `ASSERTION_KINDS` set (already includes `any_of` and Phase 1/2 kinds).

## Frontend (step editor — `web-grading-system-fe`)
- `stepConfig.ts` exports `DYNAMIC_VARIABLES` (`$UUID`, `$TIMESTAMP`, `$FAKER_NAME`, `$FAKER_BOOK_TITLE`, `$FAKER_WORD`, `$FAKER_EMAIL`) — built-in tokens generated fresh at runtime by the executor.
- `PlanCard.tsx` merges `DYNAMIC_VARIABLES` into `editorVariables` (alongside `SYSTEM_VARIABLES` and extract vars from earlier steps) and passes them to `StepEditor`/`HttpStepForm` as `availableVariables`.
- `HttpStepForm.tsx` renders each available variable as a clickable copy button (`${name}`). Dynamic variables (names starting with `$`, present in `DYNAMIC_VARIABLES`) get a `⚡` prefix and green border. A note explains they are generated at runtime, never stored.
- `copyVar(name)` copies `${name}` to the clipboard via `navigator.clipboard`.
- `stepBuilder.ts` exports `HttpFormValues`, `DataRow`, `ExtractEntry`, `AssertionEntry`, `buildHttpConfig()`, `buildDbConfig()`, `reverseMapHttpConfig()`, `reverseMapDbConfig()`, `toPairs()`, `parseJsonOrUndefined()` — builds/config reverses HTTP_REQUEST and DB step configs between form values and backend JSON.
- `HttpStepForm.tsx` — full HTTP_REQUEST step editor with tabs: Params (query_params), Headers, Body, Tests (assertions), Variables (extracts), Data rows (data[] loop). Supports `fallback`, `as` (scalar/json), all assertion kinds including `any_of`, `data[]` (max 10 rows), `auto_inject_headers`.
- `ImportModal.tsx` — modal to paste/parse Postman Collection JSON or OpenAPI Spec into HTTP_REQUEST steps.
- `SchemaPreview.tsx` — modal to display JSON Schema from backend endpoint `GET /api/v1/internal/assignments/{id}/config-schema`.
- `src/shared/api/endpoints/schema.ts` — `getConfigSchema(assignmentId)` function calling the dry-run schema endpoint.
- i18n keys added: `step.dataRows`, `step.dataRowLimit`, `step.autoInjectHeaderLabel`, `step.autoInjectHeaderHint`, `step.addAutoInjectHeader`, `step.importTitle`, `step.importPlaceholder`, `step.importPreview`, `step.schemaTitle`, plus all assertion kinds and extract fields.

## What not to do
- Do not re-parse `${...}` placeholders with string regex on the raw config JSON (breaks on quoted values).
- Do not store per-iteration data fields (title, year) in `VariableContext`; they exist only within the iteration via config substitution.
- Do not add a plan-level config field to `TestPlan`/`InternalPlanDto` for `auto_inject_headers` — step-config declaration achieves the same plan-scoped behavior without schema changes.
- Do not call blocking `HttpClient.send()` in `HttpStepExecutor` — use `sendAsync()` on the virtual thread executor.
- Do not assume MySQL/MariaDB migration rollback is atomic — DDL statements force implicit commit.
- Do not write grading results or patch submission status inside `dryRun()` — dry-run is strictly read-only with respect to grading side effects.
