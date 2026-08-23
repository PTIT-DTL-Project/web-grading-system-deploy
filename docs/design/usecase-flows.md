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
