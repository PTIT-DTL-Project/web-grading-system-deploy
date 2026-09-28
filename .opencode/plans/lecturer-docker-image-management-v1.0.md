# Plan: Lecturer Docker Image Management + Async Pre-Pull Scanner (Axis 2)

> **Date:** 2026-09-27
> **Version:** v1.0
> **Status:** Phase 1 DONE (2026-09-27, 120/120 tests green, `BUILD SUCCESS` — PR #20 closed in two rounds). Round 1 applied the three blockers (UUID system principal, V4 SET NOT NULL+DEFAULT, reachable @sha256 regex) and all nitpicks. Round 2 (this commit) fixed the one-line blocker the review caught — a miskeyed softDeleteByAssignmentId in DockerImageService.delete that wrote to the assignment_id column with an image id, and resolved the 5 remaining `#N` review markers. Round 3 added §18–§19 to java-spring-boot-backend/SKILL.md as durable conventions. Phases 2–4 to follow.
> **Scope:** Lecturer controls a library of Docker images (DB images, Java SDK, …); picks which images an assignment uses; students see the allowed images; executor-service runs a periodic async task that inspects each image in the executor pod's DinD store and pulls it if absent.
> **Axis relationship:** Axis 1 (multi-DBMS dialect layer, [db-multi-dbms-v1.0.md](db-multi-dbms-v1.0.md)) is DONE — an image maps to exactly one dialect. Axis 2 is DONE (Phase 2 scanner + Phase 3 grading-time guarantee).
> **Seams already reserved:** `ENSURE_IMAGES` slot in `grade()` (`grading-config-reference.md:165`), `ensureImages(List<String>, long)` sibling of `scanDbRequirements`, `ExecutorProperties` nested-record convention, `docker_images`/`assignment_docker_images` tables (`V1__2026-08-16__init_schema.sql:67-90`).

---

## Problem

Currently the system can **reference** Docker images (a lecturer writes a `docker_compose_template` that names `openjdk:17` or `postgres:16`) but cannot **manage** them: no CRUD, no library, no pull. The `docker_images` tables are reserved but dormant (entities exist; no repository, service, or controller). There is no mechanism to pre-pull images — grading relies on `docker compose up` pulling at boot time (works, but can exhaust `startupTimeoutMs` for large images and gives no early failure when an image name is wrong).

The `ENSURE_IMAGES` seam is documented and empty; the executor already reaches Docker via `DOCKER_HOST=tcp://localhost:2375` with `docker-java-api` on the compile classpath.

---

## Architectural constraints (determine the design)

| Constraint | Evidence | Consequence |
|---|---|---|
| `replicas: 2`, each with its own `emptyDir` DinD at `/var/lib/docker` | `deployment.yaml:8,134-145` | "Pulled locally" is **per-pod** and wiped on pod restart → pull status must be per-pod; a **periodic** scan is required (one-shot pull-on-save is insufficient) |
| No docker CLI in the runtime image | `DockerComposeRunner:16` ("only the TCP daemon") | Inspect/pull via `DockerClientFactory.instance().client()` (docker-java-api compile-scope) |
| `@Scheduled` default pool size is 1 thread | Spring Boot convention | A long pull stalls `StaleJobReaper` → bump `spring.task.scheduling.pool.size` |
| course-service has **no Kafka** (`pom.xml` has no `spring-kafka`) | `course-service/pom.xml` | Trigger via **periodic polling**, not events; no producer dependency added |
| `docker_images` has **no `owner_id`** | `V1__2026-08-16__init_schema.sql:67-75` | Image library is **global** across lecturers (per-lecturer would need a migration) |
| `docker-java-api` 3.7.1 (compile) + `docker-java-transport-zerodep` + `DockerClientFactory` | `testcontainers-2.0.5.pom`, `.m2` | `InspectImageCmd` (→ `NotFoundException`), `PullImageCmd` + `PullImageResultCallback` available with no extra dep |
| `DOCKER_HOST=tcp://localhost:2375` per pod | `deployment.yaml:24` | `DockerClientFactory` resolves it automatically; no Helm change needed |
| 5-topic Aiven Kafka limit (`wgs-events`) | `application.yaml:112` | One more topic would be costly; polling avoids it |

---

## The two halves

- **course-service** (lecturer + student API): image CRUD, assignment linkage, student visibility, internal read for the scanner, `dockerImageUrls` in the grading config.
- **executor-service** (async pull + grading-time guarantee): per-pod pull state, periodic scanner, `ENSURE_IMAGES` at boot.

---

## Phase 1 — course-service: bring the dormant image library to life

### Goal
Lecturers can create/list/update/delete images and link them to an assignment; students can see which images an assignment allows.

### Tasks
1. `DockerImageRepository` / `AssignmentDockerImageRepository` (Spring Data JPA; entities already carry `@SQLRestriction` soft-delete)
2. `DockerImageController` `@RequestMapping("/api/v1/docker-images")`:
   - `POST` — create; validate `imageUrl` = `registry/repo:tag` with **explicit tag** (repo rule: never resolve `latest` at runtime, cf. `ExecutorProperties.Maven`); `name` required ≤255; description ≤ TEXT
   - `GET` — paged list
   - `GET /{id}` — one
   - `PUT /{id}` — update
   - `DELETE /{id}` — soft delete (`deleted_at`)
   - all methods take `X-User-Id` header (existing convention)
3. `PUT /api/v1/assignments/{id}/docker-images` body `{dockerImageIds:[UUID]}` — full-sync replace the join table (diff → soft-delete/insert), reuses `idx_assign_docker_unique`
4. `GET /api/v1/student/assignments/{id}/docker-images` — published-only, mirrors `StudentAssignmentController.detail` → *"student sees which images they can use"*
5. `GET /api/v1/internal/docker-images` — returns active images `[{id, imageUrl, name}]`, no envelope, follows `InternalAssignmentController`
6. add `dockerImageUrls: List<String>` to `AssignmentGradingConfigDto`; update course-service `internalGradingConfig()` to populate it from `assignment_docker_images` → `docker_images`
7. Validation classes: extract image-url pattern into a `Constant.Image` inner class (regex + max lengths)
8. Postman collection + real-response capture for every new endpoint (SKILL §12.5)
9. `docs/design/usecase-flows.md` — new section on image management flow (AGENTS.md mandatory)

### Out of scope
Per-lecturer image ownership (would need an `owner_id` migration); image pruning.

---

## Phase 2 — executor: async scanner + per-pod state

### Goal
A `@Scheduled` task on every executor pod inspects every active image in the DinD store and pulls it if absent, recording per-pod state.

### Tasks
1. **Migration `V7__2026-09-27__docker_image_state.sql`** (executor DB, follow `grading_jobs` convention):
   ```sql
   CREATE TABLE docker_image_state (id UUID PK, image_url VARCHAR(500) NOT NULL,
       pod_id VARCHAR(255) NOT NULL, status VARCHAR(20) NOT NULL,
       last_checked_at, last_pulled_at TIMESTAMPTZ, error_message TEXT,
       created_at/updated_at/deleted_at);
   UNIQUE (image_url, pod_id) WHERE deleted_at IS NULL;
   ```
   `pod_id` = K8s default hostname (pod name) — no downward-API change needed.
2. **`ExecutorProperties.ImageScan`** nested record (`enabled`, `interval-ms`, `pull-timeout-ms`, `fail-backoff-ms`) + `application.yaml` block + `EXECUTOR_IMAGE_SCAN_*` env overrides
3. **`DockerImageGateway`** interface + `DockerImageGatewayImpl` over `DockerClientFactory.instance().client()`: `boolean present(String)` / `void pull(String, Duration)`
4. **`ImageScanner`** `@Scheduled(fixedDelayString = "${executor.image-scan.interval-ms:300000}")`:
   - skip if disabled/in-progress
   - fetch active images via `CourseInternalClient.images()`
   - per image: inspect → `PULLED` / pull (bounded by `pull-timeout-ms`) → upsert `(image_url, pod_id)` row
   - `FAILED` rows skipped until `fail-backoff-ms` elapses
   - per-image error catching (one bad image never aborts the cycle)
   - `Constant.ImageScan` inner-class literals
5. **Threading fix:** `spring.task.scheduling.pool.size: 4` in `application.yaml` (comment: long pulls must not stall `StaleJobReaper`)
6. `StaleJobReaper` continues unchanged (it doesn't see image rows)

### Out of scope
Kafka events (no course-service producer); digest-drift re-pull (presence only).

---

## Phase 3 — grading-time guarantee (`ENSURE_IMAGES` slot)

### Goal
Before `composeRunner.boot()`, ensure every image the assignment declared actually exists in this pod's DinD — close the emptyDir race.

### Tasks
1. In `GradingOrchestrator.grade()`, between DB-port pre-scan/claim and `composeRunner.boot()`, call `ensureImages(assignmentImages, timeout)`
2. inspect → absent → pull (bounded by `imageScan.pull-timeout-ms`) → failure → job `FAILED` with a message naming the image (mirrors `db_type` fail-fast-before-port-claim)
3. the existing `finally` still releases the port
4. add `ImageEnsureTest` to the orchestrator test suite

**Status:** DONE (2026-09-28, commit `5762f91`; 206→211 tests; green with `KAFKA_CA_PATH=/nonexistent`).

---

## Phase 4 — docs & SKILL

- `.opencode/skills/executor-grading/SKILL.md` §9 — *Axis 2: FUTURE* → built (seam naming, gateway pattern, state table, backoff rule); §10 conventions update
- `docs/design/usecase-flows.md` — image-management section
- `docs/design/design-db-v1.0.md` — docker_images notes + changelog v1.2
- `docs/design/execute-plan-v1.0.md:370` — mark realized
- `docs/design/grading-full-flow.md` — note `ENSURE_IMAGES` filled
- `src-services/README.md` — test recipes
- plan document itself (this file)

**Status:** DONE (2026-09-28, outer-repo commit `86090f2`).

---

## Commit sequence (one concern per commit)

1. course-service: repos + CRUD + validation + tests
2. course-service: assignment linkage + student/internal endpoints + grading-config `dockerImageUrls` + Postman + flows
3. executor: `V7` migration + `ImageScan` props + gateway + `ImageScanner` + scheduler pool + tests
4. executor: `ENSURE_IMAGES` in orchestrator + tests (`5762f91`)
5. docs + SKILL (`86090f2`)
6. plan document itself

---

## Risks

- **Docker Hub rate limit** (100 anon pulls/6h/IP): inspect-before-pull + `fail-backoff-ms` mitigate; two replicas double the pull count but stay far under the limit.
- **`emptyDir` disk growth**: noted; pruning is a separate ops concern (out of scope).
- **Mutable upstream tags**: presence-only check (YAGNI).
- **Large images** vs startup timeout: Phase 3 bounds each pull; compose boot is the fallback.
