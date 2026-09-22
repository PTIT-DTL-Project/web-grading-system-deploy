# Phase 1: DB Port Allocation & Plumbing — Detailed Design

> **Date:** 2026-09-20
> **Plan:** `.opencode/plans/db-schema-grading-v1.0.md`
> **Scope:** Detect DB steps in plans, allocate DB host port, patch compose file, expose `db_port` in VariableContext

---

## Problem

GradingOrchestrator only allocates ONE port (the app port at line 152). When a plan contains DB step types (`DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`), the student app's database service needs a host port too so the executor can JDBC-connect to it via `jdbc:postgresql://localhost:<db_port>/<database>`. Currently:
- No DB port is allocated
- No DB service port is patched into the compose file
- No `db_port` variable exists in VariableContext
- All DB steps fall through to "Unknown step type" FAILED (Phase 2 will fix the executor; Phase 1 fixes the infrastructure)

---

## 1A. `Constant.java` — New Constants

### Location
`src-services/executor-service/src/main/java/vn/edu/ptit/web_grading_system/executor_service/Constant.java`

### Changes

**Inside `VariableContext` inner class** (lines 5-10), add:

```java
public static final String DB_PORT = "db_port";
```

**New inner class** (after `VariableContext`, before `HttpStep`):

```java
public static final class DbConnection {
    public static final String DB_SERVICE = "db_service";
    public static final String DB_PORT_CONFIG = "db_port";
    public static final int DB_PORT_DEFAULT = 5432;
    public static final String DB_DATABASE = "database";
    public static final String DB_USERNAME = "username";
    public static final String DB_PASSWORD = "password";
}
```

### Rationale
- `VariableContext.DB_PORT` — key used to store/retrieve the allocated host port from VariableContext. DB executors read `ctx.variableContext().get(Constant.VariableContext.DB_PORT)`.
- `DbConnection.*` — keys used to parse the `connection` block from DB step configs. Matches the JSON keys in `design-db-v1.0.md` §2.3.

---

## 1B. `GradingOrchestrator.grade()` — DB Step Detection + Port Allocation

### Location
`GradingOrchestrator.java`, between reading plans (line ~126) and `portAllocator.claim()` (line 152).

### Current code (lines 152-164)

```java
int port = portAllocator.claim();
long executionTimeoutMs = nz(config.getExecutionTimeoutMs(),
        executorProperties.container().maxExecutionTimeMs());
long startupTimeoutMs = nz(config.getStartupTimeoutMs(),
        executorProperties.container().startupTimeoutMs());
UUID bootRow = sagaTracker.step(sagaId, Constant.Saga.BOOT_COMPOSE, planId, null);
boolean booted = false;
try
{
    DockerComposePatcher.EffectiveCompose effective = DockerComposePatcher.writeEffectiveCompose(
            workDir, config.getGradingStrategy(), config.getDockerComposeTemplate(),
            port, nz(config.getDockerComposePort(), 8080),
            config.getMaxCpu(), config.getMaxMemoryMb());
```

### New code

Replace `int port = portAllocator.claim();` with the following block, then update the DockerComposePatcher call:

```java
int appPort = portAllocator.claim();

// Pre-scan for DB steps — extract connection info for compose patching
String dbService = null;
int dbContainerPort = Constant.DbConnection.DB_PORT_DEFAULT;
boolean hasDbSteps = false;
for (InternalPlanDto plan : plans) {
    if (plan.getSteps() == null) continue;
    for (InternalStepDto step : plan.getSteps()) {
        String type = step.getStepType();
        if (type != null && type.startsWith("DB_")) {
            hasDbSteps = true;
            try {
                JsonNode cfg = objectMapper.readTree(
                        step.getConfig() == null ? "{}" : step.getConfig());
                if (cfg.hasNonNull("connection")) {
                    JsonNode conn = cfg.get("connection");
                    if (conn.has(Constant.DbConnection.DB_SERVICE))
                        dbService = conn.path(Constant.DbConnection.DB_SERVICE).asText();
                    if (conn.has(Constant.DbConnection.DB_PORT_CONFIG))
                        dbContainerPort = conn.path(Constant.DbConnection.DB_PORT_CONFIG).asInt();
                }
            } catch (Exception e) {
                writeLog(job.getId(), submissionId, GradingLogLevel.WARN,
                        "Failed to parse DB step connection config: " + safeMessage(e));
            }
            break; // use first DB step's connection config
        }
    }
    if (hasDbSteps) break;
}

Integer dbPort = null;
if (hasDbSteps) {
    dbPort = portAllocator.claimDbPort();
    writeLog(job.getId(), submissionId, GradingLogLevel.INFO,
            "DB port allocated: host=" + dbPort + " service=" + dbService);
}
```

Then update the DockerComposePatcher call:

```java
DockerComposePatcher.EffectiveCompose effective = DockerComposePatcher.writeEffectiveCompose(
        workDir, config.getGradingStrategy(), config.getDockerComposeTemplate(),
        appPort, nz(config.getDockerComposePort(), 8080),
        config.getMaxCpu(), config.getMaxMemoryMb(),
        dbService, dbPort, dbContainerPort);
```

### Finally block (lines 194-199)

Current:
```java
finally
{
    portAllocator.release(port);
```

New:
```java
finally
{
    portAllocator.release(appPort);
    if (dbPort != null) {
        portAllocator.release(dbPort);
    }
```

### Edge cases handled in this code

| Scenario | Behavior |
|----------|----------|
| No DB steps in any plan | `hasDbSteps = false`, `dbPort = null`, `dbService = null`. DockerComposePatcher skips DB patching. VariableContext has no `db_port`. Existing behavior unchanged. |
| DB steps in Plan A but not Plan B | DB port allocated once. VariableContext has `db_port` for ALL plans. |
| DB step config parse error | Log WARN, use defaults (`dbService = null` or `dbContainerPort = 5432`). |
| PortAllocator exhausted | `IllegalStateException` from `claimDbPort()` → caught by grade()'s outer catch → job FAILED. |
| Multiple DB steps with different `db_service` | First one wins for compose patching. |

---

## 1C. `runSteps()` — Signature Change + VariableContext Update

### Location
`GradingOrchestrator.java`, line 204.

### Current signature

```java
private void runSteps(GradingJob job, UUID submissionId, UUID assignmentId, UUID studentId,
        UUID planId, UUID sagaId, List<InternalPlanDto> plans, int appPort, long executionTimeoutMs)
```

### New signature

```java
private void runSteps(GradingJob job, UUID submissionId, UUID assignmentId, UUID studentId,
        UUID planId, UUID sagaId, List<InternalPlanDto> plans, int appPort, Integer dbPort,
        long executionTimeoutMs)
```

Note: `dbPort` is `Integer` (nullable) not `int` — null when no DB steps exist.

### VariableContext update (lines 210-214)

Current:
```java
VariableContext vars = new VariableContext();
vars.put(Constant.VariableContext.APP_PORT, appPort);
vars.put(Constant.VariableContext.SUBMISSION_ID, submissionId.toString());
vars.put(Constant.VariableContext.ASSIGNMENT_ID, assignmentId.toString());
vars.put(Constant.VariableContext.STUDENT_ID, studentId.toString());
```

New (add 2 lines after APP_PORT):
```java
VariableContext vars = new VariableContext();
vars.put(Constant.VariableContext.APP_PORT, appPort);
if (dbPort != null) {
    vars.put(Constant.VariableContext.DB_PORT, dbPort);
}
vars.put(Constant.VariableContext.SUBMISSION_ID, submissionId.toString());
vars.put(Constant.VariableContext.ASSIGNMENT_ID, assignmentId.toString());
vars.put(Constant.VariableContext.STUDENT_ID, studentId.toString());
```

### Caller update

The `runSteps` call site is inside `grade()` method, inside the `try (DockerComposeRunner.RunningCompose running = ...)` block. Current call (line 173):

```java
runSteps(job, submissionId, assignmentId, studentId, planId, sagaId, plans,
        running.port(), executionTimeoutMs);
```

New:
```java
runSteps(job, submissionId, assignmentId, studentId, planId, sagaId, plans,
        running.port(), dbPort, executionTimeoutMs);
```

---

## 1D. `PortAllocator.java` — `claimDbPort()` Method

### Location
`PortAllocator.java` (new method after `claim()`).

### Implementation

```java
/**
 * Hands out a host port for the student app's DB service.
 * Reuses the same BitSet as claim() — no collision with app ports
 * since both draw from the same 20000-30000 range in the same pod.
 */
public synchronized int claimDbPort()
{
    int idx = used.nextClearBit(0);
    if (idx > MAX_PORT - MIN_PORT)
    {
        throw new IllegalStateException(Constant.Message.NO_FREE_PORTS_PREFIX + MIN_PORT + "-" + MAX_PORT);
    }
    used.set(idx);
    return MIN_PORT + idx;
}
```

### Rationale
- Same BitSet, same range — prevents collision with app port in the same pod.
- Synchronized like `claim()` — same thread-safety guarantee.
- Same error behavior when exhausted.
- Separate method name for readability and future extension (e.g., tracking which port is app vs DB).

---

## 1E. `DockerComposePatcher.java` — DB Port Patching

### Location
`DockerComposePatcher.java`, line 30 (signature change) + new logic block before app service port patching (around line 72).

### Signature change

Current (line 30-31):
```java
public static EffectiveCompose writeEffectiveCompose(Path workDir, String gradingStrategy,
        String template, int appPort, int dockerComposePort, Double maxCpu, Integer maxMemoryMb)
```

New:
```java
public static EffectiveCompose writeEffectiveCompose(Path workDir, String gradingStrategy,
        String template, int appPort, int dockerComposePort, Double maxCpu, Integer maxMemoryMb,
        String dbService, Integer dbPort, Integer dbContainerPort)
```

### New logic block (inserted after `applyLimits` loop, line 72, before app service lookup)

```java
// DB service port patching (if DB steps present)
if (dbService != null && dbPort != null && dbContainerPort > 0) {
    @SuppressWarnings("unchecked")
    Map<String, Object> dbSvc = (Map<String, Object>) services.get(dbService);
    if (dbSvc == null) {
        log.warn("DB service '{}' not found in compose — DB steps will fail to connect", dbService);
    } else {
        @SuppressWarnings("unchecked")
        List<Object> dbPorts = (List<Object>) dbSvc.get(Constant.DockerCompose.PORTS);
        if (dbPorts == null) {
            dbPorts = new ArrayList<>();
            dbSvc.put(Constant.DockerCompose.PORTS, dbPorts);
        }
        dbPorts.add(dbPort + ":" + dbContainerPort);
    }
}
```

### Notes
- If DB service doesn't exist in compose: log WARN, skip patching. DB steps at runtime will fail with connection error (clear).
- If DB service already has ports: new port ADDED to existing list (not replaced).
- The format `"<hostPort>:<containerPort>"` matches how app port is patched (line 75).
- `log` field: DockerComposePatcher currently has no logger. Add `private static final Logger log = LoggerFactory.getLogger(DockerComposePatcher.class);` or use System.out. Since it's a pure logic class with no logger currently, a simple `System.out.warn()` or adding a slf4j logger is fine. Recommend adding slf4j logger for consistency.

---

## 1F. Test Plan

### Tests for GradingOrchestrator (GradingOrchestratorTest.java)

| Test name | What it verifies |
|-----------|------------------|
| `testDbPortAllocatedWhenDbStepsPresent` | When plan has DB_QUERY step, `claimDbPort()` is called, VariableContext has `db_port` |
| `testNoDbPortAllocatedWithoutDbSteps` | When plan has only HTTP_REQUEST steps, no DB port allocated, VariableContext has no `db_port` |
| `testDbPortReleasedOnFailure` | DB port released in finally block even when grading fails |
| `testDbPortPassToDockerComposePatcher` | DockerComposePatcher receives dbService + dbPort params |
| `testRunStepsSetsDbPortInContext` | `runSteps` puts `db_port` in VariableContext when dbPort != null |

### Tests for DockerComposePatcher (DockerComposePatcherTest.java)

| Test name | What it verifies |
|-----------|------------------|
| `testDbPortPatchedIntoCompose` | Given compose with service `db`, dbPort=25432, dbContainerPort=5432 → YAML has `ports: ["25432:5432"]` on db service |
| `testDbPortAddedToExistingPorts` | DB service already has `["5432:5432"]` → after patch: `["5432:5432", "25432:5432"]` |
| `testNoDbPortWhenNull` | dbService=null → no changes to compose |
| `testDbServiceNotFound` | dbService="missing_db" → log warning, no crash, no changes |

### Test approach
- GradingOrchestrator tests: mock PortAllocator (verify `claimDbPort()` called or not called based on plan), mock DockerComposePatcher (verify params), check VariableContext contents.
- DockerComposePatcher tests: pure function — create YAML string, call method, parse result back, assert ports list.

---

## 1G. Execution Order

1. **Constant.java** — add constants first (no dependencies on other changes)
2. **PortAllocator.java** — add `claimDbPort()` (depends only on Constant)
3. **DockerComposePatcher.java** — add DB port patching + signature change (depends on Constant)
4. **GradingOrchestrator.java** — wire it all (depends on all above)
5. **Tests** — write and run after each change

---

## 1H. Files Summary

| File | Type | Change |
|------|------|--------|
| `Constant.java` | modify | Add `VariableContext.DB_PORT` + `DbConnection` inner class |
| `PortAllocator.java` | modify | Add `claimDbPort()` method |
| `DockerComposePatcher.java` | modify | Add `dbService`, `dbPort`, `dbContainerPort` params + patching logic |
| `GradingOrchestrator.java` | modify | Pre-scan DB steps, allocate DB port, pass to DockerComposePatcher + runSteps |
| `GradingOrchestratorTest.java` | modify | Add DB port allocation tests |
| `DockerComposePatcherTest.java` | create | Test DB port patching in compose YAML |
