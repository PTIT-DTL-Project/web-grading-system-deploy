# API Test Guide — Web Grading System

Per-endpoint reference for every API currently implemented. Each entry: method, full URL,
headers, params, request body, expected response, and the negative checks that matter.

> Flow-level (chained) testing: `docs/design/usecase-flows.md` (UC-01/02/03) and
> `docs/api/scenarios/*.sh`. This guide is endpoint-level.

**Prerequisites**

| What | Where |
|---|---|
| course-service on `http://localhost:8081` | `src-services/course-service` (`mvnw spring-boot:run` with Neon env vars, e.g. `SERVER_PORT=18081` if another instance is already on 8081) |
| submission-service on `http://localhost:8082` | `src-services/submission-service` |
| result-service on `http://localhost:8084` | `src-services/result-service` |
| executor-service on `http://localhost:8083` | `src-services/executor-service` (Kafka-demo: see `wgs-events` flow at the end) |

**Envelope contract (public endpoints)** — every non-excluded response is wrapped:

```json
{
  "status": 200,
  "message": "Success or @ApiMessage value",
  "data": { "…": "…" },        // or {"meta":{…},"result":[…]} for paged endpoints
  "error": "only when failed"
}
```

Paged lists: `data.meta = { page, pageSize, pages, total }`, `data.result = […]`.
Excluded from wrapping: `/api/v1/internal/**`, `*/webhook*`, `/health`, `/version`,
`/v3/api-docs*`, `/swagger-ui*`.

**Identity (pre-Keycloak):** send `X-User-Id: <uuid>` on every request that cares about
ownership. Missing header → `anonymous` → currently 400 (invalid UUID). Wrong owner's UUID
→ indistinguishable 404.

---

## 1. course-service — `http://localhost:8081`

### 1.1 Classes

**POST `/api/v1/classes` — create class**

Headers: `X-User-Id: <uuid>`, `Content-Type: application/json`

```json
{ "name": "PTIT CNTT-K68", "semester": "20261" }
```

→ `201` Posted; `data.id` is the new classId. `name` trimmed.

Negative: same `name`+`semester` same owner → `400` "Class '…' already exists in semester …".

**GET `/api/v1/classes?page=0&size=20` — list mine (paged)**

**GET `/api/v1/classes/{{classId}}` — detail** → 200 envelope or 404 if not your class.

**PUT `/api/v1/classes/{{classId}}/archive`** (no body) → 200, flips `status` to `ARCHIVED`.

**POST `/api/v1/classes/{{classId}}/students/import`** — CSV import.

Headers: `X-User-Id: <uuid>`. Body: `multipart/form-data`, part name **`file`**, a `.csv`.

CSV format (header optional): `studentCode,studentName,email[,studentUserId]`.
→ 200 with `data: { imported: N, skipped: M }`. Negative: empty file → 400 "CSV file is empty";
wrong extension → 400; malformed multipart → 400; oversized → 413.

**GET `/api/v1/classes/{{classId}}/students?page=0&size=20`** — paged roster.

DB check: `select * from class_students where class_id='<id>'`.

### 1.2 Scores (components + per-student + transcript)

**PUT `/api/v1/classes/{{classId}}/score-components`** — configure scoring weights.

```json
[
  { "type": "ATTENDANCE",  "weight": 0.10 },
  { "type": "EXERCISE",    "weight": 0.20 },
  { "type": "FINAL_EXAM",  "weight": 0.70 }
]
```

Rules (all → 400 with descriptive message): types must be unique · `FINAL_EXAM` mandatory
with `weight >= 0.40` · weights must sum to `1.000` (±0.001).

**GET `/api/v1/classes/{{classId}}/score-components`** — current config array.

**PUT `/api/v1/classes/{{classId}}/students/{{studentCode}}/scores`** — write manual scores.

```json
[
  { "componentType": "ATTENDANCE",  "score": 9.0 },
  { "componentType": "FINAL_EXAM",  "score": 8.5 }
]
```

Rules: `EXERCISE` entries rejected → 400 (auto-graded only); score range 0–10;
unknown student → 404 ("Student 'X' not found in class …"); unknown component → 400.

**GET `/api/v1/classes/{{classId}}/students/{{studentCode}}/scores`** — per-student view:

```json
{ "data": { "studentCode": "B22DCCN001", "entries": [ { "type": "ATTENDANCE",
  "score": 9.0, "weight": 0.1 } ], "total": 9.25, "letterGrade": "A", "gpa": 3.7 } }
```

`total = Σ(score × weight)`; `letterGrade`/`gpa` per PTIT table (`total<4` or any
`score ≤ 0` → instant `F`/`0.0` — **entering 0 is valid input** that fails the course).

**GET `/api/v1/classes/{{classId}}/transcript`** — all roster entries with totals.

### 1.3 Assignments (exercises)

**POST `/api/v1/assignments`** — create an assignment in a class you own.

```json
{
  "title": "Lab 01 - Book API",
  "classId": "{{classId}}",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "description": "REST basics",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```

Only `title`, `classId`, `gradingStrategy` are required — the rest have the defaults above.
For `LECTURER_DOCKER_COMPOSE` also send `dockerComposeTemplate` (required → 400 otherwise).
Duplicate title in same class+owner → 400 "Assignment 'X' already exists in this class".
Class owned by another lecturer → 404.

**GET `/api/v1/assignments?classId=&published=&search=&page=0&size=20`**
Filters composable; `search` is case-insensitive title-substring. Page beyond last →
empty `result`, correct `meta.total`.

**GET `/api/v1/assignments/{{id}}`** · **PUT `/api/v1/assignments/{{id}}`** (partial;
sending a different `classId` → 400 "class_id cannot be changed after creation") ·
**POST `/api/v1/assignments/{{id}}/publish`** (idempotent; `published: true`) ·
**DELETE `/api/v1/assignments/{{id}}`** → 200; GET afterwards → 404 (row kept, soft delete).

### 1.4 Test plans & steps

**POST `/api/v1/assignments/{{id}}/plans`**

```json
{ "name": "CRUD Book API — Basic", "description": "basic flow",
  "sequenceOrder": 1, "weight": 10 }
```

Duplicate `sequenceOrder` in same assignment → 400 "A plan with sequence_order N already exists
in this assignment".

**GET `/api/v1/assignments/{{id}}/plans`** — plans sorted by `sequenceOrder`, each with steps
nested and sorted by `stepOrder`.

**PUT `/api/v1/assignments/{{id}}/plans/{{planId}}`** — `{ "name": "…", "sequenceOrder": 2 }`.
Moving onto an occupied sequence → 400 (free the slot first).

**DELETE `/api/v1/assignments/{{id}}/plans/{{planId}}`** — soft-deletes plan AND its steps.

**POST `/api/v1/assignments/{{id}}/plans/{{planId}}/steps`**

All fields:

```json
{
  "stepOrder": 1,
  "name": "Create a book",
  "stepType": "HTTP_REQUEST",
  "weight": 2,
  "timeoutMs": 30000,
  "required": true,
  "config": { "…type-specific object…" },
  "expectedResult": { "row_count": 1 }
}
```

`stepOrder` clash within the plan → 400 ("step_order N already exists").
`config` must be a JSON object (`[]` or string → 400) and is validated structurally per type
(unknown `method`, `path` without `/`, missing `statements[]`/`checks[]`/`variables[]`,
missing `extract.expression`, non-positive `duration_ms` … all → 400 naming the key).

**Config per stepType** (put into `config` above):

`HTTP_REQUEST`:

```json
{
  "method": "POST",
  "path": "/api/v1/books",
  "headers": { "Content-Type": "application/json", "Authorization": "Bearer ${token}" },
  "query_params": { "title": "De Men" },
  "body": { "title": "De Men", "author": "To Hoai" },
  "expected_status": 201,
  "assertions": [
    { "kind": "status",        "equals": 201 },
    { "kind": "contains",      "text": "De Men" },
    { "kind": "json_path",     "path": "$.id", "exists": true },
    { "kind": "body_structure","json": "{\"id\":\"\",\"title\":\"\"}" },
    { "kind": "body_equals",   "json": "{\"id\":\"b1\"}" }
  ],
  "extract": [ { "name": "bookId", "from": "response_body", "expression": "$.id" } ]
}
```

`DB_QUERY` / `DB_SCHEMA_CHECK` / `DB_MIGRATION` — see `docs/db/README.md` for exact
JSON examples (note the `connection` block with `db_service`/`database`/`username`/`password`).

`EXTRACT`: `{ "variables": [ {"name":"pageSize","value":"10"},
{"name":"bookId","from":"step_1","expression":"$.id"} ] }` (each variable: `value` XOR
`from`+`expression`).

`DELAY`: `{ "duration_ms": 5000 }`.

**PUT `/api/v1/assignments/{{id}}/plans/{{planId}}/steps/{{stepId}}`** — partial update.
Changing `stepType` requires a valid new `config` in the same request, else 400
"config is required when changing stepType".

**DELETE** the same path → soft-delete the step.

### 1.5 Internal contracts (raw, no envelope)

Behind `/api/v1/internal/**`; gateway never routes these externally.

- `GET /api/v1/internal/assignments/{{id}}` → grading config (404 if deleted)
- `GET /api/v1/internal/assignments/{{id}}/plans` → plans+steps both levels sorted,
  `config` as raw JSON string
- `GET /api/v1/internal/assignments/{{id}}/exists` → `{"exists": bool}` (`not deleted && published`)

---

## 2. submission-service — `http://localhost:8082`

### 2.1 Upload flow

**POST `/api/v1/submissions/presigned-url?assignmentId=<uuid>&zipFileName=lab01.zip`**

→ 200 with

```json
{ "data": { "submissionId": "…", "uploadUrl": "https://<rustfs-host>/submission-files/…zip?X-Amz-…",
  "objectName": "submissions/…zip", "expiresInMinutes": 15 } }
```

Then **PUT `{uploadUrl}`** with the zip as raw binary `Body → form-data` NOT needed here —
use `curl -T lab01.zip "$uploadUrl"` or Postman `Body → binary`.

**POST `/api/v1/submissions/{{submissionId}}/confirm`** — client-side confirm (webhook also
confirms via RustFS). Response 200; publishing `GRADE_SUBMISSION` onto `wgs-events` happens here
(idempotent — previously GRADING/DONE/FAILED → no duplicate Kafka message).

### 2.2 Queries

- `GET /api/v1/submissions` — `X-User-Id: <student-uuid>`, paged
- `GET /api/v1/submissions/{{id}}` — detail
- `GET /api/v1/submissions/assignment/{{assignmentId}}` — `List<SubmissionResponse>`
- `GET /api/v1/submissions/{{id}}/download` → `{ "downloadUrl": "https://…/presigned" }`
- `GET /api/v1/submissions/{{id}}/download/file` → raw file stream (not enveloped)

### 2.3 Status update (used by executor)

**PUT `/api/v1/submissions/{{id}}/status`** with body `{ "status": "GRADING" }` —
values: `PENDING | GRADING | DONE | FAILED`. Missing/invalid → 400. 404 if not found.

### 2.4 Webhook + health

- `POST /api/v1/submissions/webhook/upload-complete` — called by RustFS only (raw, no envelope)
- `GET /api/v1/submissions/health` · `GET /api/v1/submissions/version` — raw, no envelope

---

## 3. result-service — `http://localhost:8084` and executor internal contracts

**POST `/api/v1/internal/results/average`** (raw, Feign-targeted by course-service)

```json
{ "assignmentIds": ["<uuid>", "…"], "studentId": "<uuid>" }
```

→ `{ "average": 8.50 }` (or `null` when no results exist — null-safe by design review).

### executor-service

No public HTTP API. It only consumes the `wgs-events` Kafka topic. To trigger:

```json
{ "action": "GRADE_SUBMISSION", "version": 1, "timestamp": "…", "traceId": "…",
  "payload": { "submissionId": "…", "assignmentId": "…", "studentId": "…",
               "planId": null, "rustfsPath": "submissions/…zip" } }
```

via Kafka producer tooling (e.g. Kafka UI at `https://web-dev1-kafka-ui.vucongtuanduong.dpdns.org`
once deployed on the cluster).

---

## 4. Negative-check matrix (applies everywhere)

| Mistake | Code | Message hint |
|---|---|---|
| wrong HTTP verb (PATCH on our PUT endpoints, GET on POST-only, …) | 405 | "Method not allowed on this endpoint" |
| unknown path | 404 | "No handler for this path" |
| broken JSON body | 400 | "Malformed request body" |
| wrong Content-Type on JSON POST/PUT | 415 | "Unsupported Content-Type" |
| missing required query param | 400 | "Missing required parameter: <name>" |
| missing `X-User-Id` | 400 | invalid UUID "anonymous" |
| wrong-owner access everywhere | 404 | indistinguishable (no leak) |
| duplicate unique (class name+semester, assignment title, plan seq, step order) | 400 | descriptive message |
| deleted resource referenced | 404 | (soft-delete filter) |
| oversized CSV | 413 | "Uploaded file is too large" |
| constraint race (concurrent duplicate) | 409 | "Resource already exists or violates a constraint" |
| `DELETE` twice on same id | 404 | idempotent from client perspective |

Webhook/internal endpoints deliberately NOT enveloped; every other error path returns
`{ status, message, error }` with `data` absent or null.
