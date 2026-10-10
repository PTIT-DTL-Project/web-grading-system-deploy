# Use-case Flows

Canonical end-to-end flows for every client-facing API in the system.
One section per use case: numbered steps (method + path + body example),
preconditions, and expected responses.

Rules for maintaining this file live in the project root `AGENTS.md`
(Use-case flow documentation).

---

## Role requirements (slice 2, since 2026-09-30)

Identity and role now travel via the Keycloak JWT: the FE sends `Authorization: Bearer`.
The gateway validates the JWT against `KEYCLOAK_ISSUER_URI`, derives `X-User-Id` (`sub`),
`X-User-Email` (`email`) and `X-User-Roles` (`realm_access.roles` ∩ the configured
`gateway.security.allowed-roles`), then forwards them. Direct mode (`X-User-Id` + `X-Gateway-Secret`)
is deprecated — the secret cannot live in a browser. A service only reads roles **after**
the gateway stamps them; a missing/unknown role means *no* role.

Everything that creates or edits grading data requires `LECTURER` and answers `403` to
anyone else — including a request that carries no `X-User-Roles` at all:

- UC-01: `GET/POST /api/v1/classes`, `PUT /api/v1/classes/{id}/archive`, students import/list,
  score components, entering/reading scores, transcript — the one carve-out is
  `GET /api/v1/classes/{id}`, which stays owner-scoped with no role gate so an enrolled
  student can still open their own class
- UC-02: every `/api/v1/assignments` endpoint (create, list, detail, update, publish,
  soft delete, docker-image assignment)
- UC-03: every `/api/v1/assignments/{assignmentId}` plan & step endpoint
- docker images: every `/api/v1/docker-images` endpoint
- **UC-06 (slice 3):** `GET /api/v1/assignments/{assignmentId}/results` and
  `GET /api/v1/assignments/{assignmentId}/submissions` — the lecturer's grading view.
  Each carries the role gate **and** an ownership check inside the service, so an assignment
  the caller does not own answers `404`. These two replaced the role-only guards that used to
  sit on `GET /api/v1/results/{submissionId}` and `GET /api/v1/submissions/assignment/{id}`.

Role is *not* what guards UC-04 (the student flow): `/api/v1/student/**` and the submission
upload endpoints key off enrollment/ownership, and `GET /api/v1/submissions/{id}` answers
`404` for a non-owner — for **every** role, `LECTURER` included. `GET /api/v1/results/{submissionId}`
is the same rule with `403`: its rows belong to whoever submitted them. Since slice 3 neither
data service carries role logic at all; a lecturer sees another student's rows only through a
course-service endpoint they own.

**Actor line for each use case below still says who the flow is for; this section is the
authoritative list of which endpoints actually enforce it.**

---

## UC-01: Lecturer manages classes & scores

**Actor:** lecturer. Identity is the Keycloak token `sub`, injected by the api-gateway as `X-User-Id` (since 2026-09-30). The FE sends `Authorization: Bearer`; the gateway validates the JWT, derives identity, and stamps headers. Use one consistent UUID for the whole flow.
**Service:** course-service (`http://localhost:8081` directly, or via gateway).

**Preconditions:** service running; lecturer UUID chosen.

### Step 0 — List my classes (FE entry point)

```
GET /api/v1/classes?page=0&size=20
GET /api/v1/classes?page=0&size=20&search=name:PTIT;semester:20261
GET /api/v1/classes?page=0&size=20&search=semester:20261&status=ARCHIVED
X-User-Id: <lecturer-uuid>
```

Expected: `200` with `data = {meta:{page,pageSize,pages,total}, result:[...]}` and a **0-based
`page`**. Returns the caller's ACTIVE **and** ARCHIVED classes, ordered by `createdAt desc`.

Query params:
- `search` (optional): structured filter expression. Format is `field:value` pairs
  concatenated with `;`. Supported fields: `name`, `semester`.
  Examples: `search=name:PTIT;semester:20261`, `search=semester:20261`.
  Malformed expressions (missing `:`, unknown field, blank value) → `400`.
  Note: `;` is reserved as the token separator and has no escape mechanism;
  class names containing `;` cannot be searched.
- `status` (optional): `ACTIVE` or `ARCHIVED`; filters to that status only.
- Both params can be combined. Blank/null values are ignored.

Note: the `search` grammar on `/api/v1/classes` requires `field:value` tokens
and returns `400` for bare words. This differs from `/api/v1/assignments` and
`/api/v1/student/assignments`, where `search` is plain text. The strict grammar
fails loudly rather than silently ignoring the parameter.

Negative cases:
- `?search=name:PTIT;semester:20261` → 200, AND of both filters
- `?search=badfield:x` → 400 "Unknown filter field: 'badfield'. Allowed fields: name, semester"
- `?search=bareword` → 400 "Malformed filter 'bareword': expected 'field:value'. Allowed fields: name, semester"
- `?search=name:` → 400 "Filter value for 'name' must not be blank"
- `?search=` → 200 unfiltered (blank input is ignored)

`ownerId` is always the filter (someone else's class is simply not in the page).

FE: `/classes` (`ClassesPage`) issues this call with `current = meta.page + 1`, and
is guarded by `RequireRole` so only a LECTURER identity reaches it.

### Step 1 — Create class

```
POST /api/v1/classes
X-User-Id: <lecturer-uuid>
{ "name": "PTIT CNTT-K68", "semester": "20261" }
```

Expected: `201` with `data = {id, ownerId, name, semester, status:"ACTIVE"}`.
Save `data.id` as `{classId}`.
Duplicate name+semester for same owner → `400` with descriptive message.

### Step 2 — Import students from CSV

```
POST /api/v1/classes/{classId}/students/import
X-User-Id: <lecturer-uuid>
form-data: file = students-import.csv
```

Sample file: `docs/samples/students-import.csv`.
Columns: `studentCode, studentName, email (optional), studentUserId UUID (optional)`.

Expected: `200` with `data = {imported, skipped}`. Re-importing the same file → all
rows skipped (unique per class + student code). Wrong content type (not multipart) →
`400 "Malformed multipart request"`.

Identity linking (no Keycloak change needed): rows imported without the UUID
column stay `student_user_id = NULL` and self-heal — on the student's next
student-API call, `StudentIdentityService` fills their UUID into still-unlinked
rows whose email matches `X-User-Email` (case-insensitive), never overwriting
an owned row. Precondition: CSV email must equal the Keycloak account email.

### Step 3 — Configure score components (required before entering scores)

```
PUT /api/v1/classes/{classId}/score-components
[
  { "type": "ATTENDANCE", "weight": 0.10 },
  { "type": "EXERCISE",   "weight": 0.20 },
  { "type": "FINAL_EXAM", "weight": 0.70 }
]
```

Expected: `200` with the normalized component list.
Validation errors → `400`: duplicate type; missing FINAL_EXAM; FINAL_EXAM weight
< 0.40; weights not summing to 1.000 (±0.001).

### Step 4 — Enter manual scores per student

```
PUT /api/v1/classes/{classId}/students/{studentCode}/scores
[
  { "componentType": "ATTENDANCE", "score": 8.5 },
  { "componentType": "FINAL_EXAM", "score": 7 }
]
```

Expected: `200`, message "Student scores updated".
`EXERCISE` rejected with 400 (auto-graded only). Scores outside 0–10 → validation 400.
Unknown component type → 400. Student code not in the class roster → `404` with
`"Student '<code>' not found in class <classId>"` (code is trimmed before lookup).

### Step 5 — Read one student's scores

```
GET /api/v1/classes/{classId}/students/{studentCode}/scores
```

Expected: `200` with entries per component (type, weight, score), plus
`total`, `letterGrade`, `gpa`. `total = Σ score × weight` on band 10;
`total = null` while any component score is missing (see EXERCISE conditions
below) — and an incomplete total also leaves `letterGrade/gpa` null.

Grading rules (PTIT table): A+ ≥9.0, A ≥8.5, B+ ≥8.0, B ≥7.0, C+ ≥6.5, C ≥5.5,
D+ ≥5.0, D ≥4.0, F <4.0 (thang-4: 4.0/3.7/3.5/3.0/2.5/2.0/1.5/1.0/0).
Any sub-score ≤ 0 → immediate F regardless of total.
Student code not in the roster (including stray whitespace in the path variable,
which is trimmed first) → `404 Student '<code>' not found in class <classId>`.

### Step 6 — Class transcript

```
GET /api/v1/classes/{classId}/transcript
```

Expected: `200` with one entry per imported student: code, name, per-component
entries, total + letterGrade + gpa (all null when incomplete).

### Step 7 — Archive class (one-way)

```
PUT /api/v1/classes/{classId}/archive
X-User-Id: <lecturer-uuid>
```

Expected: `200` with `data.status = "ARCHIVED"`. Idempotent (already archived → same
`200`); unknown or not owned → `404 Class not found: <uuid>`. **There is no unarchive
endpoint** — archive is permanent.

FE: **Lưu trữ** sits behind a Popconfirm (`okButtonProps danger`), rendered only for
`ACTIVE` rows; after success the row keeps rendering with an **Archived** tag and loses the
action. The backend does not block score entry on an `ARCHIVED` class, so the FE has to
(Phase 3).

### EXERCISE auto-grading chain

`exercise = avg(score / max_score × 10)` over the student's latest results across the
class's assignments, computed live via result-service internal API. All three must hold,
otherwise exercise and total are null:

1. `class_students.student_user_id` is set (CSV column 4 or DB update)
2. The class has assignments
3. result-service has results for those (assignment, student) pairs

### Error behavior (all steps)

Every error returns the standard envelope `{status, message, data:null, error}`:
404 unknown/unowned class · 400 business/validation violations · 409 constraint races ·
500 unexpected (logged server-side).

---

## UC-02: Lecturer manages assignments (exercises)

**Actor:** lecturer (`X-User-Id`, same UUID throughout).
**Service:** course-service. **Preconditions:** class exists and is owned by caller
(UC-01 step 1). Canonical runner: `docs/api/scenarios/exercise-management.sh`.

### Step 1 — Create assignment

```
POST /api/v1/assignments
{ "title": "Lab 01", "classId": "<classId>", "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8080, "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000, "maxMemoryMb": 256, "maxCpu": 0.5 }
```

Expected: `201` with full assignment in `data` (`published:false`).
Errors: duplicate title in same class → 400 descriptive · unknown/unowned class → 404 ·
LECTURER strategy without `dockerComposeTemplate` → 400 · field violations → 400 detail.

### Step 2 — List / filter my assignments

```
GET /api/v1/assignments?classId=&published=&search=&page=0&size=20
```

Expected: `200` paged envelope; filters combinable; `search` is plain text
(case-insensitive title contains), not the structured `field:value` grammar
used by `/api/v1/classes`. Sorted `createdAt desc`; page beyond last → empty
result, correct `meta.total`.

### Step 3 — Detail

`GET /api/v1/assignments/{id}` → 200 or 404 (unowned/deleted).

### Step 4 — Update

```
PUT /api/v1/assignments/{id}
{ "title": "...", "description": "...", "maxMemoryMb": 512 }
```

Expected: `200` reflected. `classId` cannot be moved (400). Duplicate title check
excludes self. Partial semantics: null fields keep stored values.

### Step 5 — Publish

`POST /api/v1/assignments/{id}/publish` → `200` idempotent, `published:true`.

### Step 6 — Soft delete

`DELETE /api/v1/assignments/{id}` → `200`; GET → 404 afterwards; row preserved in DB.

---

## UC-03: Lecturer authors grading exercises (plans & steps)

**Actor:** lecturer (`X-User-Id`). **Preconditions:** published assignment exists (UC-02).
Steps define how the executor will grade a student's submission later
(execute-plan-v1.0.md): HTTP_REQUEST calls against the student's app, chained via
extracted variables (`${bookId}`), plus DB checks. Canonical runner:
`docs/api/scenarios/exercise-steps.sh`.

### Step 1 — Create plan

`POST /api/v1/assignments/{assignmentId}/plans`
`{ "name": "CRUD Book API — Basic", "sequenceOrder": 1, "weight": 10 }`
→ 201. Duplicate sequenceOrder → 400 descriptive.

### Step 2 — List plans (nested steps, both sorted)

`GET /api/v1/assignments/{assignmentId}/plans` → plans by sequenceOrder; each nests
steps by stepOrder with parsed `config`.

### Step 3 — Add steps (chained)

POST `…/plans/{planId}/steps` ×N. Example chain (docs/db §8.1):
1. HTTP_REQUEST POST /api/v1/books, extract bookId
2. HTTP_REQUEST GET /api/v1/books/${bookId}
3. HTTP_REQUEST GET search
4. DB_SCHEMA_CHECK tables/columns/PK
5. DB_QUERY verify row

Errors: duplicate step_order → 400 naming it · invalid config structure → 400 naming
the key · unknown `connection.db_type` (DB_* steps) → 400 listing allowed engines
`postgres, mysql, mariadb` · step of another assignment → 404.

FE notes: the step editor auto-assigns `stepOrder` as `max + 1` and sends `config` /
`expectedResult` as parsed JSON objects (backend `StepResponse` returns `type`, not
`stepType`, plus JSON values — normalized once in `endpoints/assignments.ts`). HTTP steps
use a Postman-style editor (method+path bar, Params/Headers/Body/Tests/Variables tabs,
per-row enabled toggles, variable panel with copy, runtime warnings for unchecked steps /
ignored bodies / restricted headers / unresolved `${var}`). DB types share one connection
editor; schema-check and migration have list builders; EXTRACT/DELAY show an unsupported
banner because no executor exists yet. DB-query `expected` is mirrored into top-level
`expectedResult`. Steps support edit (Advanced JSON prefilled from the stored step) and
delete; the config preview redacts `password` and `authorization` values because step
config is stored in cleartext. When editing, the variable panel only lists variables
from earlier steps.

### Step 4 — Update / reorder

PUT `…/steps/{stepId}` partial; moving onto an occupied order → 400 (free the slot first);
changing stepType requires a valid config in the same request.

### Step 5 — Delete

DELETE `…/steps/{stepId}` or DELETE `…/plans/{planId}` (soft delete).

### Internal contracts (executor/submission, raw DTOs)

GET `/api/v1/internal/assignments/{id}` → grading config (404 if missing) ·
GET `/api/v1/internal/assignments/{id}/plans` → plans+steps sorted, config as JSON string ·
GET `/api/v1/internal/assignments/{id}/exists` → always 200 `{exists}` where exists =
not deleted AND published.

### Notes

Steps stay editable after publish; the executor reads config at job time.
SCRIPT step type deferred (not in enum/engine v1).

---

## UC-04: Student reads exercises & submits per plan (auto-grade)

**Actor:** student (`X-User-Id` = `class_students.student_user_id`). Identified by the
gateway-injected header. Must be enrolled in the assignment's class.
**Service:** course-service (read) · submission-service (upload) · executor-service
(Kafka consumer) · result-service (score). **FE not built yet — this UC is the contract.**
Plans/steps API shape: `PlanResponse` / `StepResponse` (`course-service/.../dto/response`).
### Step 1 — List visible assignments

```
GET /api/v1/student/assignments?classId=&search=&page=0&size=20
X-User-Id: <student-uuid>
```

Enrollment = `class_students.student_user_id = X-User-Id`. Only `published=true`
assignments of enrolled classes are returned (otherwise empty page). Not enrolled /
not published → `404` on detail (indistinguishable), never a list leak.

`search` is plain text (case-insensitive title contains), not the structured
`field:value` grammar used by `/api/v1/classes`.

### Step 2 — Read an assignment + its plans as a problem set

```
GET /api/v1/student/assignments/{id}
GET /api/v1/student/assignments/{id}/plans
```
`/plans` returns plans by `sequenceOrder`, each with steps by `stepOrder`. Grading
plumbing is hidden from students:
- Steps of type `DELAY` / `EXTRACT` are dropped.
- `config` is sanitized: keys `connection` (DB credentials), `extract`, `expected`
  are stripped server-side (`StudentAssignmentService.sanitizeConfig`).
- `StepResponse.description` (lecturer-authored note) is returned; **FE shows it
  verbatim and only falls back to auto-generated text from `config` when `description`
  is null/empty.** Auto-text example: `HTTP_REQUEST POST /api/v1/books {…} → expect 201`.

### Step 3 — Submit a plan (per-plan grading)

```
POST /api/v1/submissions/presigned-url?assignmentId={id}&zipFileName={name}&planId={planId}
X-User-Id: <student-uuid>                    ← required (400 when absent)
→ 201 { submissionId, uploadUrl, objectName, expiresInMinutes }
```
Query params only, no body. `planId` is optional: omitted ⇒ executor grades **all** plans; set ⇒ only that plan's
steps run (`execute-plan-v1.0.md` §3 step 1). `X-User-Id` (`class_students.student_user_id`) stamps `submissions.student_id`.
Each plan gets its own zip (full student app per plan is acceptable). Student PUTs the zip to RustFS;
no confirm call exists — the RustFS `ObjectCreated:Put` webhook on `submissions/*.zip` is the sole trigger:
webhook → status `PENDING` → submission-service publishes `GRADE_SUBMISSION` to Kafka
(`wgs-events`) with `planId` → executor persists a `grading_jobs` row carrying
`planId` (`GradeSubmissionHandler`) → async `GradingOrchestrator` runs the job:
`FETCHING` (course-service config + plans) → `BUILDING` (RustFS zip download +
Testcontainers compose boot via DinD) → `RUNNING` (targeted plan's steps when
`planId` is set, else all plans; HTTP steps only — other step types fail gracefully
until their executors land) → `DONE`/`FAILED`. One job at a time (single-job gate).
Score = weight-weighted passed/ran ratio (`ScoreCalculator`), reported via
`POST /api/v1/internal/results` (result-service) which writes one `results` row
(`plan_id` + `plan_weight`, `is_latest` flip) plus `step_results` rows; submission
status is patched `GRADING` → `DONE`/`FAILED` along the way.

### Step 4 — Poll score

```
GET /api/v1/results/{submissionId}
X-User-Id: <student-uuid>               (rows of someone else ⇒ 403 "Not owner")
                                X-User-Roles: LECTURER   ⇒ ownership rule skipped (grading view)
GET /api/v1/student/assignments/{id}   (re-read, shows score after result lands)
```
One `results` row per graded plan (each with its `step_results`), enveloped as
`{status, message, data, error}`. Empty list while the submission is queued or
grading — poll until rows appear.
`results.is_latest` is unique per `(student_id, assignment_id, plan_id)`, so each plan
keeps its own latest result. Assignment exercise score = **weight-weighted average of
per-plan scores** (`result_service ResultService.weightedScoreByPlan`, weighted by
`test_plans.weight` carried into `results.plan_weight`); unsubmitted plans are ignored
(live partial). `course-service` `ScoreService.computeExercise` calls
`POST /api/v1/internal/results/weighted`.

### Error behavior

`404` for any assignment the student isn't enrolled in or that isn't published. Upload
errors and grading failures behave as in UC-03 / `execute-plan-v1.0.md` §6.

---

## UC-05: Auto-grading a DB step (`DB_QUERY` / `DB_SCHEMA_CHECK` / `DB_MIGRATION`)

**Actor:** executor-service (Kafka consumer `GRADE_SUBMISSION`). **Not a human-facing UC.**
**Service:** executor-service (after compose boot). **FE:** n/a.

**Preconditions:** plan's compose started and healthy (`RUNNING`); the plan's step
has type `DB_QUERY`, `DB_SCHEMA_CHECK`, or `DB_MIGRATION`; `connection.db_type` set
(default `postgres`, allowed `{postgres, mysql, mariadb}`; MariaDB = MySQL alias).

### Step 1 — Resolve engine and port

1. `GradingOrchestrator.runSteps` reads the step's `connection` block and
   `connection.db_type`.
2. `VariableContext.DB_PORT` holds the host port published from the student
   compose (allocated by `GradingOrchestrator`).
3. `DbDialectRegistry.resolve(db_type)` picks the dialect (engine-agnostic,
   single `@Component` per engine; MariaDB resolves to the MySQL dialect).

### Step 2 — Open JDBC connection (all DB types)

`DbConnectionHelper.withConnection(connection, hostPort, action)` builds the
dialect-owned JDBC URL and opens a connection, retrying up to 5 times
(1 s each) if the DB container is still initialising. On final failure the
exception is wrapped with `Constant.Message.Db` dialect hint:
`"Connection failed using dialect '<key>'. If your DB is MySQL/MariaDB, set connection.db_type"`.

### Step 3 — Execute step-specific logic

**`DB_QUERY`** (`DbQueryExecutor`):
1. Substitute `${var}` in the lecturer's `query`.
2. Run via `Statement.executeQuery`; collect column labels and row count.
3. Compare against `expected.row_count` (exact) and/or `expected.columns`
   (exact ordered list, case-insensitive) — each yields one
   `AssertionEngine.AssertionDetail` (`kind = "row_count"` / `"columns"`).
4. All assertions pass → `PASSED`; else → `FAILED` with details.

**`DB_SCHEMA_CHECK`** (`DbSchemaCheckExecutor`):
1. Iterate the `checks[]` array; for each check run the dialect's
   information-schema query (`tableExistsSql`, `columnExistsSql`,
   `primaryKeySql`, `indexExistsSql`) with the documented params.
2. `COLUMN_EXISTS` compares the returned `data_type`/`column_type` via
   `dialect.sameType(expected, actual)` (normalises engine-specific names,
   e.g. `varchar` ↔ `character varying`, `boolean` ↔ `bit`).
3. One `AssertionDetail` per check → all pass → `PASSED`; first fail →
   `FAILED` with the per-check details.

**`DB_MIGRATION`** (`DbMigrationExecutor`):
1. Run each statement in `statements[]` in a single transaction
   (`autoCommit=false`).
2. Commit only if every statement succeeds; rollback on the first error.
3. Restore `autoCommit=true` in `finally`.
4. No assertions → `PASSED` (no `assertionResult`, no `extractedVariables`);
   on error → `ERROR` with `Constant.Message.Db.SQL_EXECUTION_ERROR` prefix.

### Step 4 — Error handling

- **Connection failure** (dialect can't reach the DB) → `StepResultStatus.ERROR`
  with a dialect-hint message distinguishing it from SQL errors.
- **SQL / execution failure** (lecturer's query/statement/migration errored) →
  `StepResultStatus.ERROR` prefixed with `"DB step SQL error: "` so the
  lecturer's mistake is distinguishable from infrastructure failure.
- Both paths throw inside the existing `runSteps` wrapper → persisted as
  `ERROR` rows with `errorMessage`; the plan continues (other steps / plans).

### Step 5 — Persist and continue

`GradingOrchestrator` persists the `GradingStepResult` (status, `assertionResult`
JSON, `errorMessage`, `durationMs`) exactly as for `HTTP_REQUEST` steps, then
continues to the next step/plan. DB steps contribute to the plan's score like
any other step.

### Notes

- `ENSURE_IMAGES` (UC-13 Step 2) runs before compose boot; DB executors
  still run after boot inside `runSteps`, so neither gate touches the dialect layer.
- `StepRegistry` bean-collects all four `StepExecutor` implementations;
  adding a new DB type = one `@Component` + `DbDialect` (zero registry changes).
- `db_type` is validated at step-creation time by `StepConfigValidator`
  (course-service); the executor fail-fasts early if a legacy row slips through.

---

## UC-06: Lecturer reviews auto-grading results and submissions (slice 3)

**Actor:** lecturer. **Service:** course-service (proxies result-service and
submission-service).

**Preconditions:** the lecturer owns the assignment's class.

### Step 1 — Request the class-wide results (with optional filters)

```
GET /api/v1/assignments/{assignmentId}/results?studentCode=&includeSteps=false
X-User-Id: <lecturer-uuid>
X-User-Roles: LECTURER
X-Gateway-Secret: <secret>
```

`studentCode` narrows to one roster row (trimmed; unknown code → `[]`).
`includeSteps=true` batch-loads step rows in one extra query; default `false`
keeps the class-wide read to the result rows only.

**Expected:** `200` — `[{ studentUserId, studentCode, studentName, exerciseScore,
results: [{ planId, planWeight, score, maxScore, status, summaryLog, latest,
startedAt, completedAt, steps[] }] }]`. A student gone from the roster keeps
their row with null code/name. A result row whose student left the roster keeps
its raw `studentUserId` with null code/name rather than being hidden.
An assignment the caller does not own → `404`. A non-lecturer → `403`. No trust
secret → `401`.

`exerciseScore` uses the **same weight-weighted formula** as the transcript,
**scoped to this assignment** (the transcript applies it across all class
assignments — figures agree only when the class has one assignment).

### Step 2 — Request the submissions list

```
GET /api/v1/assignments/{assignmentId}/submissions
X-User-Id: <lecturer-uuid>
X-User-Roles: LECTURER
X-Gateway-Secret: <secret>
```

**Expected:** `200` — all submissions of the owned assignment. Not owner → `404`.

---

## UC-10: Lecturer manages the Docker image library

**Actor:** lecturer (`X-User-Id` header).
**Service:** course-service (`:8081`, or via gateway for `/api/v1/docker-images/**`).

**Preconditions:** service running; lecturer UUID chosen.

### Step 1 — Register an image

```
POST /api/v1/docker-images
X-User-Id: <lecturer-uuid>
{ "name": "Postgres 16", "imageUrl": "postgres:16", "description": "..." }
```

Validation (single-sourced in `Constant.Image.IMAGE_URL_REGEX`):
- `imageUrl` must be `registry[:port]/repo:tag` **or** `name@sha256:<digest>` —
  userinfo (`user:pass@`) is rejected; digest pinning is accepted.
- The tag must be **explicit**: `:latest` is forbidden (grading reproducibility).
- `name` ≤ 255 chars, `imageUrl` ≤ 500 chars (`@Size` on the request DTO).

Expected: `201` with `data = {id, name, imageUrl, description}`.
The owning lecturer's `X-User-Id` is stamped as `ownerId`.

### Step 2 — List / search / get images

```
GET /api/v1/docker-images?name=postgres&page=0&size=20
GET /api/v1/docker-images/{id}
```

Expected: paged/global read (all lecturers can see the shared library).
`?name=` does a case-insensitive contains filter on image name.

### Step 3 — Update / delete an image

```
PUT  /api/v1/docker-images/{id}  { "imageUrl": "postgres:17" }
DELETE /api/v1/docker-images/{id}
```

Only the owning lecturer (or the system principal for backfilled defaults)
can mutate; everyone else gets `404` (identity is not silently ignored).
`DELETE` returns `409` if any `assignment_docker_images` row still references
the image — deleting a shared image would silently remove an image from the
executor's grading-config fetch for assignments that depend on it.

---

## UC-11: Lecturer links images to an assignment

**Actor:** lecturer.
**Service:** course-service.

**Preconditions:** image(s) registered (UC-10); assignment exists and is owned by the lecturer.

### Step 1 — Full-sync the image set

```
PUT /api/v1/assignments/{id}/docker-images
X-User-Id: <lecturer-uuid>
{ "dockerImageIds": ["<uuid>", ...] }
```

Full-sync replace: old links are soft-deleted, then the supplied ids are inserted.
- `dockerImageIds = null` (missing `@NotNull`) → `400`.
- `dockerImageIds = []` → clears all images (documented PUT semantics).
- Duplicate ids are collapsed once up front (the partial unique index
  `idx_assign_docker_unique WHERE deleted_at IS NULL` would otherwise 409 on a repeat).
- An unknown/soft-deleted id → `400 "unknown or soft-deleted"`.
- `404` if the assignment doesn't belong to the caller.

---

## UC-12: Student views allowed images for an assignment

**Actor:** student (`X-User-Id` header).
**Service:** course-service.

**Preconditions:** assignment exists and is published; student is enrolled in its class.

### Step 1 — Read the allowed images

```
GET /api/v1/student/assignments/{id}/docker-images
X-User-Id: <student-uuid>
```

Expected: `200` with `[{id, name, imageUrl, description}, ...]` — only images
linked to the published assignment, gated by the same `requireVisible` guard
that hides the assignment itself (published + enrolled).

---

## UC-13: Executor pre-pulls images before grading

**Actor:** executor-service (one `@Scheduled` scanner per pod; `ENSURE_IMAGES` at grading boot).
**Service:** executor-service + course-service (internal HTTP).

**Preconditions:** assignment linked to images (UC-11); service running.

### Step 1 — Periodic scanner

Each executor pod, every `executor.image-scan.interval-ms` (default 5 min):

1. `CourseInternalClient.images()` → `GET /api/v1/internal/docker-images`
   returns the active image URLs (`List<String>`, no envelope).
2. For each URL, inspect the local DinD store:
   - present → mark `PULLED`, record `last_checked_at`.
   - absent → `pullImageCmd` bounded by `pull-timeout-ms` → `PULLED` or `FAILED`,
     record `last_pulled_at` / `error_message`.
3. Upsert per-pod state in `docker_image_state` (`(image_url, pod_id)` unique).
4. A `FAILED` row is skipped until `fail-backoff-ms` elapses (Docker Hub rate-limit mitigation).
5. Per-image errors never abort the cycle.

### Step 2 — Grading-time guarantee (`ENSURE_IMAGES`)

Inside `GradingOrchestrator.grade()`, in **slot B** — after `appPort` and
`dbPort` are claimed and the artifact is unzipped (status already `BUILDING`),
immediately before `sagaTracker.step(BOOT_COMPOSE)` / `composeRunner.boot()`:

0. **Skipped entirely** when `executor.image-scan.enabled` is `false`, or
   `imageScan` is unconfigured, or the assignment declares no images
   (the common case) — `enabled=false` is byte-for-byte pre-Phase-3 behavior.
1. `writeLog(INFO, "Ensuring images: " + urls)`.
2. For each declared URL, `DockerImageGateway.present()` → present ⇒ next;
   absent ⇒ `pull(url, Duration.ofMillis(pull-timeout-ms))` (default 600 s —
   its own budget, not the 60 s `startup-timeout-ms` compose budget).
3. Pull failure ⇒ `ImagePullException` re-wrapped as
   `Image pull failed: <url>: <registry message>` ⇒ `fail(...)` ⇒ job `FAILED`
   with that message, `grade()` returns. The boot saga row is never created.
4. The existing `finally` releases **both** `appPort` and `dbPort`.

This closes the `emptyDir` race: a pod restart wipes its DinD store, so the
periodic scanner re-warms each pod and `ENSURE_IMAGES` guarantees the image
before compose boot.

### Deliberate non-goals

- **No saga step.** `Constant.Saga` has no `ENSURE_IMAGES`; the guarantee is an
  inline pre-boot call, and `fail()` already persists the error.
- **No `docker_image_state` write at grading time.** The periodic scanner
  self-heals within one `interval-ms` (default 5 min) and upserts warmth on its
  next cycle.
- Status shown while ensuring is `BUILDING` (set before the slot), not `FETCHING`.

### Notes

- The internal endpoint is **not** routed by the gateway (`/api/v1/internal/**` absent
  from `application.yaml`), so only the executor reaches it.
- `dockerImageUrls` is populated by `TestPlanService.internalGradingConfig` from
  `assignment_docker_images`; the executor receives it as part of `AssignmentGradingConfigDto`.
- `syncAssignmentImages` does not check `published` — changing the image set on a
  published assignment changes the pre-pull list but not the graded workload
  (compose decides the runtime image). Deleting an image still referenced by a
  live assignment is blocked with `409`.

---

## UC-14: Đổi mật khẩu (Self-service + Forced change)

**Actor:** any realm `ptit-wgs` user — the endpoint itself requires **no session**.
**Service:** api-gateway (`POST /api/v1/account/change-password`).
**Since:** 2026-10-03, plan `docs/design/keycloak-password-gateway-plan-2026-10-03-v1.md`.

**Preconditions:**
- **Gate:** the controller only exists when `rate-limit.enabled=true`
  (`RATE_LIMIT_ENABLED`, base default `false`; the local profile sets it) — with the gate
  off the path answers **404** (fail-closed: no anonymous password oracle on an
  unconfigured deployment). There is no limiter behind the switch yet.
- **Never `401`** — structural, since 2026-10-04: the path is served by a dedicated
  `SecurityWebFilterChain` *without* `oauth2ResourceServer`, so an expired/invalid
  `Authorization` header on the request is never validated (on the old single chain,
  `permitAll` could not prevent the resource-server entry point from answering `401`).
  A `401` would make the FE interceptor silent-refresh and redirect `/login`, which loops
  in the forced-change flow, where no token exists yet.
- Realm brute-force protection (`bruteForceProtected=true`, **live-verified 2026-10-04**,
  runbook §3 + §6.2.1) is the compensating control for the open password-grant surface.

### The endpoint (shared by both entry points)

```
POST /api/v1/account/change-password
Content-Type: application/json
NO Authorization header needed — if one is sent it is ignored (the dedicated chain
does no bearer processing), never validated, never answered with 401

{
  "username": "lecturer_test",     // username OR email (realm loginWithEmailAllowed=true)
  "currentPassword": "...",
  "newPassword": "..."
}
```

Expected responses:

| HTTP | Body | When |
|---|---|---|
| `404` | (framework) | gate off (`rate-limit.enabled=false`) — no controller registered; expected fail-closed, **not** a routing bug |
| `204` | (empty) | password changed |
| `400` | `{"status":400,"message":"current_password_invalid","data":null}` | wrong current password **OR** unknown user — deliberately the same code (no user enumeration) |
| `400` | `{"status":400,"message":"weak_password","data":null}` | Keycloak password policy rejected the new password — **unreachable today**: the live realm's `passwordPolicy` is `None` (verified 2026-10-04), so a weak `newPassword` answers `204` until the Phase 2 policy is applied |
| `400` | `{"status":400,"message":"validation_failed","data":null}` | missing/blank field |
| `502` | `{"status":502,"message":"identity_provider_unavailable","data":null}` | Keycloak token/admin API unreachable or errored (envelope `status` is `502` too) |

Server order: gate (`rate-limit.enabled` decides whether this controller exists) →
verify current password via a password grant — since Phase 3 (2026-10-03, D11) with the gateway's own
**confidential** client **`wgs-password-verify`** (`client_id` + `client_secret`, env
`KEYCLOAK_PASSWORD_CLIENT_*`; before Phase 3 it was the public `web-grading-fe` with no
secret — but since 2026-10-03 `web-grading-fe` has Direct Access Grants **OFF** (§10.6), so
a blank/missing pair now fails with `502`: the pair is mandatory in practice) (an
`Account is not fully set up` answer counts as *password correct*) → lookup user via the
admin API with the `wgs-user-service` service account — the query parameter comes from the
identifier's shape (`@` → `?email=`, otherwise `?username=`) and the returned row is matched
**exactly**, because Keycloak's search is a prefix query →
`PUT /admin/realms/{realm}/users/{id}/reset-password` with the **flat** body
`{"type":"password","value":"<new>","temporary":false}`. Verify runs before lookup so an
unauthenticated caller cannot enumerate users.

**Realm password policy (Phase 2, 2026-10-03):** once `passwordPolicy` is enabled on realm
`ptit-wgs` (recipe in `docs/guide/PASSWORD-GATEWAY-RUNBOOK.md` §9.4), a non-compliant
`newPassword` on this endpoint yields `400` with error code `weak_password` (whether the
admin reset path enforces the policy is settled by the runtime probe, runbook §9.5). The
policy is **not retroactive** — existing passwords keep working until the next change
(Keycloak: *"will not be effective for existing users"*). The FE mirrors the same rules
client-side in antd form rules (skill `react-frontend-antd` §22.1) so client and realm
cannot drift.

### Flow A — Forced change (temporary password)

**Preconditions:** user's password was set `temporary: true` (required action
`UPDATE_PASSWORD` pending).

**Since Phase 3 (2026-10-03, D7/D10) this flow no longer touches the FE or the gateway:**
login is an authorization-code + PKCE **redirect**, and Keycloak renders its **own**
`UPDATE_PASSWORD` page for the pending required action — the FE's 2-field form is gone
and the gateway endpoint plays no role here (it stays for the voluntary Flow B).
While the automatic `keycloak.login()` redirect is pending, `/login` renders
**only a spinner** (2026-10-04): the card with the **Đăng nhập** button is the
fallback for a redirect that could not start (blocked navigation / uninitialized
adapter) — so reloading a deep link such as `/classes/:id` shows loading and is
sent to Keycloak, never the card.

1. App → `keycloak.login()` → full-page redirect to Keycloak:

   ```
   GET {issuer}/protocol/openid-connect/auth
     ?client_id=web-grading-fe
     &redirect_uri=http%3A%2F%2Flocalhost%3A5173%2F
     &response_type=code&scope=openid&state=...&nonce=...
     &code_challenge=...&code_challenge_method=S256
   ```

   → login page (`200`, hosted by Keycloak — the password never enters FE JS).
2. After the credentials check Keycloak sees the pending required action and redirects to
   **its own** `UPDATE_PASSWORD` form (still on the Keycloak origin):

   ```
   GET {issuer}/login-actions/required-action?...&execution=UPDATE_PASSWORD&client_id=web-grading-fe
   ```

   User submits the new password → Keycloak applies the realm `passwordPolicy` itself
   (the very same page enforces it — no `400 weak_password` code is involved, the FE never
   sees the request) → required action cleared.
3. Keycloak redirects back to `http://localhost:5173/?code=...&state=...` → `keycloak-js`
   exchanges the code (+ PKCE verifier) at `POST {issuer}/protocol/openid-connect/token` →
   tokens in **memory only** → app renders with the user's role.
4. Next login with the new password proceeds straight through step 1–3 with no
   `UPDATE_PASSWORD` page.

<details>
<summary>Interim flow (pre-Phase 3, kept for rollback reference)</summary>

1. Login `POST /protocol/openid-connect/token` (`grant_type=password`) →
   `400 {"error":"invalid_grant","error_description":"Account is not fully set up"}`
   (password correct, forced change pending) → FE keeps the just-typed password in React
   state and shows a **2-field** form (new + confirm).
2. `POST /api/v1/account/change-password` with
   `{"username":"lecturer_test","currentPassword":"<just-typed password>","newPassword":"Dev2026!!"}`
   → `204` (errors: `current_password_invalid` / `weak_password` / `validation_failed` /
   `identity_provider_unavailable`; `404` when the gate is off).
3. User logs in again with the new password → tokens, `requiredActions` cleared.

</details>

### Flow B — Voluntary change (header user menu, stays logged in)

**Preconditions:** user is logged in — a live session from `keycloak-js` held **in memory**
(Phase 3, D8; pre-Phase 3 it lived in `localStorage['wgs.auth']` — same session shape,
different storage).

1. Header user menu → **Đổi mật khẩu** → modal with **3 fields** (current, new, confirm).
   Client-side rules block short (<8) and mismatched passwords before any request.
2. Submit:

   ```
   POST /api/v1/account/change-password
   { "username": "<session.email>", "currentPassword": "...", "newPassword": "..." }
   ```

   → `204` → success toast, modal closes, **session unchanged — the user stays logged in**.
3. Errors: same table as "The endpoint" above. A stale bearer token on this request can
   no longer produce `401` (dedicated chain, see Preconditions); Keycloak brute force is
   what throttles repeated wrong passwords realm-side.

### Exposure gate (the 404) and what actually throttles

`rate-limit.enabled` (`RATE_LIMIT_ENABLED`, base default `false`, local profile `true`)
only decides whether the controller is registered — **no limiter is implemented** (the
original Valkey fixed-window design from plan §5 was never built; its `rate_limited`/429
code was removed 2026-10-04 as unreachable). Until a real limiter ships:

- unconfigured deployment → endpoint **absent** (404), so there is no open
  password-guessing oracle;
- an opted-in deployment relies on **Keycloak brute force** as the throttle:
  `bruteForceProtected=true` (live-verified 2026-10-04), `failureFactor=30`,
  `permanentLockout=false` → a locked account waits ~15 min; E2E tests that guess
  passwords can lock `lecturer_test`.
- Known trade-off (accepted, plan §6.1): the counter is **per user**, not per IP — an
  anonymous caller can drive a targeted account into temporary lockout, and a successful
  login clears the counter. Lockout and a wrong password both surface as
  `current_password_invalid` here (the gateway does not distinguish them).

---

## Logout: revoke the Keycloak session

**Actor:** logged-in user. **Service:** FE `keycloak.ts` → Keycloak directly (public
client, no secret). **Since:** 2026-10-03.

1. `POST {authority}/protocol/openid-connect/logout`, form-urlencoded:

   ```
   client_id=web-grading-fe
   refresh_token=<the session's refresh token>
   ```

   → `204`. Fire-and-forget: a failed call is swallowed (`.catch(() => {})`) so logout
   never blocks the UX.
2. FE clears `localStorage['wgs.auth']` → redirect `/login`.
   *(Phase 3 note, 2026-10-03: with D8 the session is **memory-only**, so "clears
   localStorage" becomes dropping the in-memory session + `keycloak.clearToken()`; the XHR
   revoke above is kept as-is — the redirect-vs-in-place question is decision **D12**, still
   open in `.opencode/plan/phase-3-pkce.md`, do not treat this step as settled for Phase 3.)*

Before this change logout only cleared localStorage, leaving the refresh token alive up
to `ssoSessionMaxLifespan` (10 h). Revocation kills the **refresh** token; an
access token issued earlier still lives until `accessTokenLifespan` (300 s) expires.



---

## UC-15: Student views enrolled classes

**Actor:** student (`X-User-Id` header).
**Service:** course-service.

**Preconditions:** rows in `class_students` linking `student_user_id` to classes.
Students see only enrolled classes; anything else answers 404,
indistinguishable from missing — the project's ownership convention.

### Step 1 — List enrolled classes (paged + filtered)

```
GET /api/v1/student/classes?page=0&size=20
X-User-Id: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
X-Gateway-Secret: <secret>
```

Real response (verified 2026-10-08 against local course-service; student
enrolled in 2 of 3 classes):

```json
{"status":200,"message":"Success","data":{"meta":{"page":0,"pageSize":20,"pages":1,"total":2},"result":[
{"id":"11111111-1111-1111-1111-111111111111","name":"Lop Test A","semester":"20261","status":"ACTIVE","createdAt":"2026-10-08T16:10:20.950669Z"},
{"id":"22222222-2222-2222-2222-222222222222","name":"Lop Test B Archive","semester":"20261","status":"ARCHIVED","createdAt":"2026-10-08T16:10:20.950669Z"}]}}
```

- No `ownerId` in the payload (lecturer linkage is not the student's business).
- A student with no enrollments gets `total: 0`, `result: []` (not 404).
- `search` reuses the lecturer structured format (`name:..;semester:..`,
  `ClassFilter.parse`); malformed input → `400 Malformed filter 'foo':
  expected 'field:value'. Allowed fields: name, semester`.
- `status` optional (`ACTIVE`/`ARCHIVED`); absent = both, like the lecturer list.
- Missing `X-Gateway-Secret` → `401 Unauthorized: Missing or invalid identity
  header` (fail-closed, same as every service).

### Step 2 — Class detail (enrollment-checked)

```
GET /api/v1/student/classes/11111111-1111-1111-1111-111111111111
X-User-Id: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
X-Gateway-Secret: <secret>
```

Expected: `200` with the single class object (same shape as list rows).
A class the caller is not enrolled in → `404 {"status":404,"message":"Class
not found: <id>"}` (verified).

---

## UC-16: Student views own scores

**Actor:** student (`X-User-Id` header).
**Service:** course-service.

**Preconditions:** caller enrolled in the class (resolved from
`class_students.student_user_id`, same convention as UC-15). Computation is the
shared `buildScores` core also serving the lecturer transcript row, so the two
can never drift.

### Step 1 — Read my scores

```
GET /api/v1/student/classes/{id}/my-scores
X-User-Id: <student-uuid>
X-Gateway-Secret: <secret>
```

Real responses (verified 2026-10-09 against local course-service; class with
ATTENDANCE 0.5 + FINAL_EXAM 0.5):

Complete (S001: 9.00 + 8.00):
```json
{"status":200,"message":"Success","data":{"studentCode":"S001","entries":[
{"type":"ATTENDANCE","weight":0.5000,"score":9.00},
{"type":"FINAL_EXAM","weight":0.5000,"score":8.00}],
"total":8.50,"letterGrade":"A","gpa":3.7}}
```

Incomplete (S002: only ATTENDANCE scored):
```json
{"status":200,"message":"Success","data":{"studentCode":"S002","entries":[
{"type":"ATTENDANCE","weight":0.5000,"score":7.00},
{"type":"FINAL_EXAM","weight":0.5000,"score":null}],
"total":null,"letterGrade":null,"gpa":null}}
```

Not enrolled → `404 {"status":404,"message":"Class not found: <id>"}`.
`total`/`letterGrade`/`gpa` are null while any component score is missing;
EXERCISE degrades to null when grading data is unavailable (never fails the call).

### Step 3 — Class roster (enrolled students only)

```
GET /api/v1/student/classes/{id}/students?page=0&size=20
X-User-Id: <student-uuid>
X-Gateway-Secret: <secret>
```

Expected: `200` with classmates as `{studentCode, studentName}` only — no
emails, no user ids (privacy decision, 2026-10-09). Includes not-yet-linked
rows (imported = member). Sorted by `studentCode`. Not enrolled → `404
{"status":404,"message":"Class not found: <id>"}` (verified live 2026-10-09).

### Step detail views (FE, 2026-10-09)

- Lecturer plan rows expand to the full authored config (connection, expected,
  extract, per-kind assertions, weight/timeout/required).
- Student step rows expand to the request/response contract only: method, path,
  query, headers, body, expected status / query / checks / statements. No
  assertions, extract, expected values, or connection block.
- Sensitive header values (`authorization`, `cookie`, `set-cookie`,
  `proxy-authorization`, `x-api-key`, `x-gateway-secret` — same set as backend
  `HttpLogService`) render masked student-side; follow-up filed to strip them
  in `sanitizeConfig` server-side as well.

---

## UC-17: System admin bulk-imports user accounts

**Actor:** system admin (JWT must carry the realm `ADMIN` role; anything else →
`403 forbidden`). Lecturers and students can never reach this endpoint.
**Service:** api-gateway (owns every Keycloak Admin interaction so the
service-account secret never enters the browser bundle).

**Preconditions:** the admin client's service account holds `manage-users`
(realm-management) on the live realm; Keycloak default user profile does not
require `lastName`.

### Step 1 — Upload the CSV

```
POST /api/v1/admin/users/import
Authorization: Bearer <admin-jwt>
Content-Type: multipart/form-data; file = users-import.csv
```

Columns: `username, fullName, email, role?` — `role` is `STUDENT`/`LECTURER`
(optional `ROLE_` prefix tolerated), blank means `STUDENT` (secure default).
Unknown role values fail the row, never the batch. Caps: 2 MB, 2000 rows.

### Step 2 — Per-row orchestration (server-side, sequential)

For each row: duplicate check by username, then email (either hit → `skipped`
with reason) → `POST users` (`enabled: true`,
`requiredActions: ["UPDATE_PASSWORD"]`) → temporary password (= the username)
→ realm role from a per-import cache. A `409` race on create degrades to
`skipped`; any other row failure lands in the report with a machine reason
(`unknown_role`, `not_enough_columns`, `blank_username_or_email`,
`invalid_input`, `weak_password`, `provider_error`, `role_not_assigned`,
`duplicate_username`, `duplicate_email`).

### Step 3 — Read the report

Expected: `200` with
`data = {created: {STUDENT, LECTURER}, skipped, failed: [{row, username, role,
reason}]}`. Re-running a file is safe (created rows skip as duplicates), with
one caveat: a row that failed at role assignment stays role-less on re-run —
repair it manually, the report names it via `role_not_assigned`.

### Step 4 — First login (no app changes needed)

The temporary credential auto-stamps `UPDATE_PASSWORD`, so Keycloak forces a
password change at first sign-in and the existing `must_change_password` flow
handles it. The initial password equals the username (known to both admin and
account holder), so no out-of-band secret exchange is needed.
