# Use-case Flows

Canonical end-to-end flows for every client-facing API in the system.
One section per use case: numbered steps (method + path + body example),
preconditions, and expected responses.

Rules for maintaining this file live in the project root `AGENTS.md`
(Use-case flow documentation).

---

## UC-01: Lecturer manages classes & scores

**Actor:** lecturer (identified by `X-User-Id` header until Keycloak integration —
use one consistent UUID for the whole flow).
**Service:** course-service (`http://localhost:8081` directly, or via gateway).

**Preconditions:** service running; lecturer UUID chosen.

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

Expected: `200` paged envelope; filters combinable; search = case-insensitive title
contains; sorted createdAt desc; page beyond last → empty result, correct meta.total.

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
the key · step of another assignment → 404.

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
POST /api/v1/submissions/presigned-url?assignmentId={id}&planId={planId}
X-User-Id: <student-uuid>
{ "zipFileName": "solution.zip" }
→ 201 { submissionId, uploadUrl, objectName, expiresInMinutes }
```
`planId` is optional: omitted ⇒ executor grades **all** plans; set ⇒ only that plan's
steps run (`execute-plan-v1.0.md` §3 step 1). Each plan gets its own zip (full student
app per plan is acceptable). Student PUTs the zip to RustFS, then:
```
POST /api/v1/submissions/{submissionId}/confirm
```
→ status `PENDING` → submission-service publishes `GRADE_SUBMISSION` to Kafka
(`wgs-events`) with `planId` → executor persists a `grading_jobs` row carrying
`planId` (`GradeSubmissionHandler`) → boots the student container → runs the targeted
plan's steps → writes one `results` row per plan with `plan_id` + `plan_weight`.

### Step 4 — Poll score

```
GET /api/v1/results/{submissionId}
GET /api/v1/student/assignments/{id}   (re-read, now shows score after result lands)
```
`results.is_latest` is unique per `(student_id, assignment_id, plan_id)`, so each plan
keeps its own latest result. Assignment exercise score = **weight-weighted average of
per-plan scores** (`result_service ResultService.weightedScoreByPlan`, weighted by
`test_plans.weight` carried into `results.plan_weight`); unsubmitted plans are ignored
(live partial). `course-service` `ScoreService.computeExercise` calls
`POST /api/v1/internal/results/weighted`.

### Error behavior

`404` for any assignment the student isn't enrolled in or that isn't published. Upload
errors and grading failures behave as in UC-03 / `execute-plan-v1.0.md` §6.

