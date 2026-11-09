# Plan: DB Schema Grading

> **Date:** 2026-09-20
> **Version:** v1.0
> **Status:** Pending approval
> **Scope:** Implement DB step types (DB_QUERY, DB_SCHEMA_CHECK, DB_MIGRATION) in executor-service
> **Related:** `docs/design/design-db-v1.0.md` · `docs/design/execute-plan-v1.0.md`

---

## Problem

Three DB step types (`DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`) are fully designed in `design-db-v1.0.md` and validated in course-service's `StepConfigValidator`, but have **no executor implementation**. When used in a grading plan, all DB steps resolve to FAILED with "Unknown step type". Additionally, GradingOrchestrator only allocates a single port (app port) — there is no DB port allocation, no DB service port patching in DockerComposePatcher, and no `db_port` variable in VariableContext.

## Phase 1: DB Port Allocation & Plumbing

### Files to modify

| File | Change |
|------|--------|
| `Constant.java` | Add `VariableContext.DB_PORT = "db_port"` and `DockerCompose.DB_SERVICE`, `DB_PORT`, `DB_PORT_DEFAULT` constants |
| `GradingOrchestrator.java` | Detect DB steps in plans → allocate DB port via PortAllocator → pass to DockerComposePatcher + put `db_port` in VariableContext |
| `PortAllocator.java` | Add `claimDbPort()` method (reuses same BitSet range 20000-30000) |
| `DockerComposePatcher.java` | Add DB port patching: find service by `db_service` name, add `"<dbHostPort>:<containerDbPort>"` to its ports list |
| `GradingOrchestratorTest.java` | Add tests: DB port allocation, VariableContext injection, DockerComposePatcher DB port patching |

### Design decisions

- **PortAllocator**: `claimDbPort()` reuses the same BitSet as `claim()` — both methods draw from the same 20000-30000 range, preventing collision between app and DB ports in the same pod.
- **runSteps() signature**: Change from `runSteps(..., int appPort, long executionTimeoutMs)` to `runSteps(..., int appPort, Integer dbPort, long executionTimeoutMs)`. `dbPort` is null when no DB steps exist.
- **DockerComposePatcher**: New method `writeEffectiveCompose(..., String dbService, Integer dbContainerPort)` — null-safe. When null, skip DB port patching (existing behavior unchanged).
- **VariableContext**: `db_port` is put in by `runSteps()` after allocation. DB executors read it via `ctx.variableContext().get("db_port")`.

### Flow

```
grade()
  → runSteps(..., appPort, dbPort, executionTimeoutMs)
    → detect DB steps in plans (scan step_type for DB_* prefix)
    → if DB steps found: dbPort = portAllocator.claimDbPort()
    → put db_port in VariableContext
    → DockerComposePatcher.writeEffectiveCompose(..., dbService, dbContainerPort)
    → run steps (DB executors read db_port for JDBC URL)
    → finally: portAllocator.release(dbPort) if allocated
```

---

## Phase 2: DBStepExecutor Implementations

### Files to create

| File | Change |
|------|--------|
| `DbConnectionHelper.java` | New: builds JDBC URL from VariableContext + connection config, manages connection lifecycle, executes queries |
| `DbQueryExecutor.java` | New: @Component, type="DB_QUERY" |
| `DbSchemaCheckExecutor.java` | New: @Component, type="DB_SCHEMA_CHECK" |
| `DbMigrationExecutor.java` | New: @Component, type="DB_MIGRATION" |
| `Constant.java` | Add DB constants: connection keys, check kinds, assertion kinds |

### DbConnectionHelper design

```java
@Component
public class DbConnectionHelper {
    // Builds: jdbc:postgresql://localhost:{db_port}/{database}
    // user/pass from connection config
    // Manages Connection lifecycle (open/close per step)
    // Executes queries, returns ResultSet as List<Map<String, Object>>
}
```

### Per-step type behavior

**DbQueryExecutor** (`DB_QUERY`):
1. Build JDBC URL from VariableContext.db_port + connection config (database, username, password)
2. Execute query (variables already substituted in config by VariableContext.substitute())
3. Read ResultSet → `List<Map<String, Object>>`
4. Compare with `expected` config:
   - `row_count`: compare actual vs expected
5. Extract results to VariableContext if config has `extract`
6. Record `extracted_variables` in GradingStepResult

**DbSchemaCheckExecutor** (`DB_SCHEMA_CHECK`):
1. Build JDBC URL
2. For each check in `checks` array, query information_schema/pg_indexes:
   - `TABLE_EXISTS`: `SELECT COUNT(*) FROM information_schema.tables WHERE table_name = ?`
   - `COLUMN_EXISTS`: `SELECT COUNT(*) FROM information_schema.columns WHERE table_name = ? AND column_name = ?` (optional: data_type match)
   - `PRIMARY_KEY`: `SELECT COUNT(*) FROM information_schema.table_constraints WHERE table_name = ? AND constraint_type = 'PRIMARY KEY'`
   - `INDEX_EXISTS`: `SELECT COUNT(*) FROM pg_indexes WHERE tablename = ? AND indexname = ?`
3. Each check = 1 assertion; pass when all true
4. No extraction (schema check is read-only)

**DbMigrationExecutor** (`DB_MIGRATION`):
1. Build JDBC URL
2. Set connection to manual commit (`connection.setAutoCommit(false)`)
3. Execute each statement in `statements` array
4. Commit if all succeed, rollback on any failure
5. No assertion (always PASSED if no exception)
6. No extraction

### StepExecutor interface compatibility

The existing `StepExecutor` interface uses `HttpStepExecutor.StepContext` as the parameter type. StepContext is a record with: jobId, planId, stepId, stepOrder, stepName, config (JsonNode), variableContext, timeoutMs. It has no HTTP-specific fields, so DB executors can use it directly. No interface change needed.

---

## Phase 3: Tests, Documentation & Polish

### Files to modify/create

| File | Change |
|------|--------|
| `DbQueryExecutorTest.java` | New: Testcontainers PostgreSQL — test row_count match, row_count mismatch, extract variable |
| `DbSchemaCheckExecutorTest.java` | New: Testcontainers PostgreSQL — test TABLE_EXISTS, COLUMN_EXISTS, PRIMARY_KEY, INDEX_EXISTS, mixed checks |
| `DbMigrationExecutorTest.java` | New: Testcontainers PostgreSQL — test insert + commit, insert + rollback |
| `docs/design/grading-full-flow.md` | Add DB step execution section |
| `docs/design/http-test-plan-config.md` | Add DB step config examples |
| `.opencode/skills/executor-grading/SKILL.md` | Update with DB step executor conventions |

### Test approach

- Use Testcontainers PostgreSQL (may need to add `testcontainers-postgres` dependency)
- Each test boots a real PostgreSQL container, creates schema, runs the executor, verifies results
- Phase 1 tests use mock PortAllocator + parse compose YAML to verify DB port patching

---

## Out of Scope

- DB port remapping when compose service name differs from `db_service` config (Phase 1 handles: compose must have a service named `db_service`)
- Dynamic DB schema versioning (future)
- DB_LOG table (logging covers it)

---

## Verification Plan

1. **Phase 1**: GradingOrchestratorTest — verify DB step detection, port allocation, VariableContext injection, compose patching
2. **Phase 2**: DbQueryExecutorTest + DbSchemaCheckExecutorTest + DbMigrationExecutorTest — Testcontainers PostgreSQL, all 3 step types
3. **End-to-end**: Create assignment with DB steps via course-service → submit → verify grading produces PASSED for DB steps with correct configs

---

## Estimated Effort

- Phase 1: 1-2 days
- Phase 2: 2-3 days
- Phase 3: 1-2 days
- **Total**: 4-7 days
