---
name: executor-grading
description: Executor-service grading pipeline - Kafka GRADE_SUBMISSION consume, RustFS zip download, Testcontainers compose boot via DinD, HTTP step execution, scoring, result reporting. Use when touching executor-service grading flow, GradingOrchestrator, DockerComposeRunner/Patcher, step executors, or the result-service internal write API.
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
daemon needed. DB port remapping is deferred (HTTP-only MVP).

## 4. Step execution scope (MVP)

Only `HTTP_REQUEST` has an executor. Unknown types (DB_*, etc.) resolve to a
`FAILED` step row with "Unknown step type" — never throw out of the loop.
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
