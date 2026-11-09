# Exercise Management Plan v1.0 — Assignments (bài tập)

> **Status:** Approved (assignment CRUD slice)
> **Date:** 2026-08-23
> **Scope:** Assignment lifecycle APIs in course-service. Plans/steps, docker-image linking,
> internal executor endpoints, and student-facing listing are **follow-up tasks**.
> **Related:** system-design-v1.0.md §3.2 · usecase-flows.md UC-02 · AGENTS.md rules

---

## 1. API surface

| Method | Path | Purpose | Notes |
|---|---|---|---|
| POST | `/api/v1/assignments` | Create assignment in an owned class | 201 + envelope |
| GET | `/api/v1/assignments` | List mine, paged + filtered | filters: `classId`, `published`, `search` |
| GET | `/api/v1/assignments/{id}` | Detail (owned only) | 404 otherwise |
| PUT | `/api/v1/assignments/{id}` | Update fields | `class_id` immutable |
| POST | `/api/v1/assignments/{id}/publish` | Publish (one-way, idempotent) | |
| DELETE | `/api/v1/assignments/{id}` | Soft delete | row kept, `deleted_at` set |

Identity: `X-User-Id` header = lecturer UUID (pre-Keycloak interim).
Envelope/status codes follow skill §1–§3 (auto-wrap, PUT-only, descriptive errors).

## 2. Validation & business rules

| Rule | Failure |
|---|---|
| `title` @NotBlank | 400 field detail |
| `classId` must reference a class **owned by caller** | 404 indistinguishable |
| Duplicate `(ownerId, classId, title)` (trimmed) | 400 `"Assignment 'T' already exists in this class"` (pre-check; no DB index needed) |
| `gradingStrategy == LECTURER_DOCKER_COMPOSE` ⇒ `dockerComposeTemplate` required | 400 |
| `dockerComposePort` 1–65535; timeouts > 0; `maxMemoryMb` ≥ 64; `maxCpu` > 0 | 400 bean validation |
| Update must not move `class_id` (body classId != stored ⇒ 400) | 400 explicit |
| Publish on already-published | 200 idempotent, no-op |
| Delete = soft (`deleted_at`) — invisible everywhere, row preserved | GET→404 after |

List semantics: sorted `createdAt DESC`; filters combinable; `search` = case-insensitive
title contains; page beyond last → empty `result`, correct `meta.total`.

## 3. Files

| Type | File |
|---|---|
| Repository | `repositories/AssignmentRepository.java` (owner-scoped derived queries + `@Query` dynamic filter/search) |
| Service | `services/AssignmentService.java` (all business rules above) |
| Controller | `controller/AssignmentController.java` |
| Requests | `dto/request/CreateAssignmentRequest.java`, `UpdateAssignmentRequest.java` |
| Response | `dto/response/AssignmentResponse.java` + `mapper/AssignmentMapper.java` (MapStruct) |
| Unit tests | `test/…/service/AssignmentServiceTest.java` (validation matrix, publish/delete semantics) |

No migration required — V1 schema already complete.

## 4. Integration scenario catalog (executable)

Runner: `docs/api/scenarios/exercise-management.sh` (curl+jq against live service,
default `http://localhost:18081`; hard asserts, non-zero exit on failure; DB checks via
`psql $DATABASE_URL` — skipped with warning if psql unavailable).

Prereqs seeded by script: class A + class B (owned by lecturer 1), lecturer 2 identity.

| ID | Chain | API expect | DB expect |
|---|---|---|---|
| EX-01 | POST valid (STUDENT strategy) | 201, envelope fields | row: owner/title/published=false/deleted_at NULL |
| EX-02 | POST missing title | 400 + field detail | no new row |
| EX-03 | POST to other lecturer's class | 404 | — |
| EX-04 | POST LECTURER strategy w/o template | 400 | — |
| EX-05 | POST duplicate title same class | 400 descriptive | still single row |
| EX-06 | GET list paging + meta | result/meta correct | COUNT(*) matches total |
| EX-07 | GET `?classId=A` vs `?classId=B` | isolation | counts match per class |
| EX-08 | GET `?published=true` | only published | matches SQL |
| EX-09 | GET `?search=` partial/case-insens. | matches subset | matches SQL ILIKE |
| EX-10 | GET `{id}` detail | echoes stored fields | row equals |
| EX-11 | GET other owner's id | 404 | — |
| EX-12 | PUT title/timeouts | 200 reflected | values + updated_at changed |
| EX-13 | PUT changing class_id | 400 | class_id unchanged in DB |
| EX-14 | PUT duplicate title excluding self | 400 | unchanged |
| EX-15 | DELETE → GET 404 → list excludes | 404 | row present, deleted_at SET |
| EX-16 | PUBLISH → PUBLISH again | 200 both, idempotent | published=true once |
| EX-17 | combined filters `classId+published+search` | subset correct | matches SQL |

## 5. Definition of done

Skill §12: unit matrix green · regression green · scenario script exits 0 against a live
boot (SERVER_PORT=18081, Neon env) · UC-02 written into usecase-flows.md · README section added.

## 6. Follow-ups (explicitly out of scope here)

Docker-image declaration/linking · test plans & steps (the "steps that test students'
exercises" epic — HTTP_REQUEST/DB_QUERY engine per execute-plan-v1.0.md) · internal
endpoints for executor/submission · student-facing listing (submission epic).

---

# Phase 2 v1.0 — Exercise Definition: Test Plans & Steps

> **Status:** Approved · **Date:** 2026-08-23
> Lecturer authors grading exercises = test plans + ordered steps (per-type config JSON).
> Executor runs them at grading time (execute-plan-v1.0.md). Steps stay editable after publish.

## API surface

| Method | Path | Notes |
|---|---|---|
| POST | `/api/v1/assignments/{id}/plans` | `{name, description?, sequenceOrder, weight?}` |
| GET | `/api/v1/assignments/{id}/plans` | plans sorted by sequenceOrder, each nests steps sorted by stepOrder |
| PUT | `/api/v1/assignments/{id}/plans/{pid}` | partial update (rename/reorder/description) |
| DELETE | `/api/v1/assignments/{id}/plans/{pid}` | soft delete (**extension** — absent from original design) |
| POST | `…/plans/{pid}/steps` | full step payload, typed `config` validated per type |
| PUT | `…/steps/{sid}` | partial; changing `stepType` requires a new valid `config` in same request |
| DELETE | `…/steps/{sid}` | soft delete |

Ownership chain: assignment owner → plan.assignmentId → step.planId (scoped lookups,
indistinguishable 404s). Editing allowed even when published (v1 decision).

## Per-type config validation (server-side structural)

- HTTP_REQUEST: method ∈ GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS; path starts "/";
  headers object-of-scalar-strings; body any JSON; expected_status 100–599 optional;
  assertions[] optional kinds {status+equals, body_structure+json, body_equals+json,
  json_path+path(+exists), contains+text}; extract[] items {name, from, expression}.
- DB_QUERY: query non-blank; expected? {row_count?, columns?: [string], sample?: object}
- DB_SCHEMA_CHECK: checks[] non-empty; kinds TABLE_EXISTS(table_name),
  COLUMN_EXISTS(table_name,column_name[,data_type]), INDEX_EXISTS(index_name),
  PRIMARY_KEY(column)
- DB_MIGRATION: statements[] non-empty strings
- EXTRACT: variables[] each {name} + value XOR (from + expression)
- DELAY: duration_ms int > 0

Malformed config / unknown keys tolerated; wrong structure → 400 naming the key.
Ordering: app-level uniqueness — step_order unique per plan, sequence_order unique per
assignment (collisions → 400 naming the conflict; no auto-swap).

## Internal contracts (raw DTOs, envelope-exempt)

- GET `/api/v1/internal/assignments/{id}` → grading config or 404
- GET `/api/v1/internal/assignments/{id}/plans` → plans+steps both levels sorted, config as raw JSON string
- GET `/api/v1/internal/assignments/{id}/exists` → always 200 `{exists}` (= not deleted AND published)

## Scenarios (exercise-steps.sh)

Seeds class + published assignment → builds docs/db §8.1 "CRUD Book" plan verbatim
(5 chained steps with ${bookId} extraction) → deep assert nesting/ordering/config fields →
conflict cases (duplicate seq/order, cross-assignment access, invalid configs matrix:
bad method, missing table_name, negative delay, empty statements, EXTRACT without
value/from, config="[]") → reorder dance (s2→6 frees slot, move s5) → delete step →
plan rename/reorder + second plan ordering → internal config/plans shapes + exists
true/false (unpublished second assignment) → psql/docker DB checks where available.

## Appendix A — Detailed endpoint sequence (copy-paste ready)

All calls need `X-User-Id: <lecturer-uuid>` (same UUID entire flow). Envelope is auto-wrapped; `data` holds the payload.

### 0) Prerequisite — class
```
POST /api/v1/classes
{ "name": "PTIT CNTT-K68", "semester": "20261" }
→ 201 data.id = {{classId}} (reuse for every assignment below)
```

### 1) POST /api/v1/assignments — Create
Minimal:
```json
{ "title": "Lab 01 - Book API", "classId": "{{classId}}", "gradingStrategy": "STUDENT_DOCKER_COMPOSE" }
```
Full (all tunables):
```json
{
  "title": "Lab 01 - Book API",
  "description": "REST basics",
  "classId": "{{classId}}",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```
LECTURER variant adds required `dockerComposeTemplate: "services:\n  app:\n    build: ./app\n..."`

→ 201 save `assignmentId`. Next: `GET /api/v1/assignments?classId={{classId}}` should list it.

### 2) GET /api/v1/assignments?classId=&published=&search=&page=&size= — List/filter
Examples:
`GET /api/v1/assignments?classId={{classId}}&published=false&search=Lab&page=0&size=20` → `data.meta.total / data.result[]`.

### 3) PUT /api/v1/assignments/{{assignmentId}} — Update
```json
{ "title": "Lab 01 - Book API v2", "description": "updated", "maxMemoryMb": 512 }
```
Sending `classId` different from stored → 400 `class_id cannot be changed`. Duplicate title same class → 400.

### 4) POST /api/v1/assignments/{{assignmentId}}/publish
No body. Idempotent. Then `GET ...?published=true` must include it. DB `published=true`.
`GET /api/v1/internal/assignments/{{assignmentId}}/exists` → `{"exists":true}`.

### 5) POST /api/v1/assignments/{{assignmentId}}/plans — Create plan
```json
{ "name": "CRUD Book API — Basic", "description": "basic flow", "sequenceOrder": 1, "weight": 10 }
```
→ 201 save `planId`. Duplicate `sequenceOrder:1` → 400.

### 6) POST /api/v1/assignments/{{assignmentId}}/plans/{{planId}}/steps — Create step
Five chained examples (copy `docs/db/README.md` §8.1):
- S1 `stepOrder:1` HTTP_REQUEST: `{"method":"POST","path":"/api/v1/books","headers":{"Content-Type":"application/json"},"body":{"title":"Dế Mèn Phiêu Lưu Ký","author":"Tô Hoài","year":1941},"expected_status":201,"extract":[{"name":"bookId","from":"response_body","expression":"$.id"}]}`
- S2 `stepOrder:2` HTTP_REQUEST: `{"method":"GET","path":"/api/v1/books/${bookId}","expected_status":200,"expected_body_contains":"Dế Mèn Phiêu Lưu Ký"}`
- S3 `stepOrder:3` HTTP_REQUEST: `{"method":"GET","path":"/api/v1/books","query_params":{"title":"Dế Mèn"},"expected_status":200,"expected_body_contains":"${bookId}"}`
- S4 `stepOrder:4` DB_SCHEMA_CHECK: `{"checks":[{"kind":"TABLE_EXISTS","table_name":"books"},{"kind":"COLUMN_EXISTS","table_name":"books","column_name":"title"},{"kind":"PRIMARY_KEY","table_name":"books","column":"id"}]}`
- S5 `stepOrder:5` DB_QUERY: `{"query":"SELECT title, author FROM books WHERE id = ${bookId}","expected":{"row_count":1,"columns":["title","author"]}}` + `expectedResult: {"row_count":1}`

Other types:
- `DELAY`: `{"duration_ms":5000}`
- `DB_MIGRATION`: `{"statements":["INSERT INTO books ..."]}`
- `EXTRACT`: `{"variables":[{"name":"pageSize","value":"10"},{"name":"firstBookId","from":"step_1","expression":"$.id"}]}`

Duplicate `stepOrder:3` → 400. Invalid method `TELEPORT` → 400.

### 7) GET /api/v1/assignments/{{assignmentId}}/plans — Verify nesting
Expect `data[0].steps` sorted `1,2,3,4,5` and `config.method` round-trips.

### 8) PUT .../plans/{{planId}}/steps/{{stepId}} — Rename/reorder
```json
{ "name": "Verify book details v2", "stepOrder": 6 }
```
Reorder onto occupied slot → 400 (move the other step first). Type change needs new `config` in same request.

### 9) DELETE .../steps/{{stepId}} and DELETE .../plans/{{planId}}
→ 200 soft-delete; next GET excludes them.

### 10) Internal (executor, raw, no envelope)
`GET /api/v1/internal/assignments/{{assignmentId}}` → grading config
`GET /api/v1/internal/assignments/{{assignmentId}}/plans` → sorted plans+steps, config as JSON string
`GET /api/v1/internal/assignments/{{assignmentId}}/exists` → `{"exists":true/false}`

Negatives to run after each section: other lecturer's `X-User-Id` → 404 indistinguishable; `config:[]` → 400.
