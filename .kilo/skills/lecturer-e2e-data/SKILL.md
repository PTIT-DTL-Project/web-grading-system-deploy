---
name: lecturer-e2e-data
description: Lecturer-scope E2E data generation against the dev gateway - Keycloak password-grant client for scripts (wgs-postman, NOT web-grading-fe), class create, student CSV import format, score components, and the assignment -> plan -> steps -> publish chain with exact payloads. Use when seeding demo/E2E data, writing Postman/curl recipes for course-service, debugging 401/unauthorized_client on a lecturer script, CSV import returning skipped rows, or step creation 400s.
---

# Lecturer-scope E2E data generation

Verified 2026-10-27 against `https://web-dev1-api.vucongtuanduong.dpdns.org`
(realm `ptit-wgs`, lecturer `gv002`, `ROLE_LECTURER`).

## 1. Auth for scripts

```bash
KC=https://web-dev1-keycloak.vucongtuanduong.dpdns.org
curl -s -X POST "$KC/realms/ptit-wgs/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=wgs-postman&username=<user>&password=<pass>"
```

- Use client **`wgs-postman`** (public, Direct Access Grants ON). `web-grading-fe` answers
  `unauthorized_client` because direct grants are off there (keycloak skill §10).
- `invalid_grant: Account is not fully set up` = correct password but required action
  `UPDATE_PASSWORD` pending. Fix without admin access: `POST /api/v1/account/change-password`
  with `{username, currentPassword, newPassword}` (no Authorization header) → `204`, then
  grant again.
- Only `Authorization: Bearer` is needed at the gateway; it strips any inbound
  `X-User-Id`/`X-Gateway-Secret` and injects its own (`sub` → `X-User-Id`). Sending them
  manually is pointless; a token without `sub` yields 400 downstream.

## 2. Class

```bash
POST /api/v1/classes          {"name":"D22CQKH02-B","semester":"20261"}   -> 201 {"data":{"id":"<classId>"}}
GET  /api/v1/classes?page=0&size=20                                      -> owner-scoped page
```

`PUT /api/v1/classes/{id}/score-components` (PUT, replaces the whole set):

```json
[{"type":"ATTENDANCE","weight":0.10},{"type":"EXERCISE","weight":0.20},{"type":"FINAL_EXAM","weight":0.70}]
```

`FINAL_EXAM` required and weight ≥ 0.40; weights must sum to 1.000 (±0.001); duplicate type → 400.

## 3. Student CSV import

```bash
POST /api/v1/classes/{classId}/students/import      # multipart, field name "file"
-F 'file=@students.csv;type=text/csv'               -> 200 {"data":{"imported":59,"skipped":0}}
```

Header: `studentCode,studentName,email,studentUserId`.
- Column order is positional (`row[0..3]`); header row is auto-skipped only when col 0 is
  `studentCode` / `mã sinh viên` / `ma_sv`.
- `studentUserId` is optional but must be a UUID **or the whole import fails** (throws on the
  first bad row). Leave it blank if unknown — never guess: it links the roster row to the
  Keycloak/student account used by student-side flows.
- Duplicate `studentCode` within the class → counted in `skipped`, not an error.
- Naive parser: `line.split(",")`. No quoting support → names containing commas break the
  row; keep CSV cells comma-free.
- Verify: `GET /api/v1/classes/{classId}/students?page=0&size=100` → `meta.total`.

## 4. Assignment chain (per assignment)

1. `POST /api/v1/assignments` → 201 `data.id`
2. `POST /api/v1/assignments/{aid}/plans` → 201 `data.id`
3. `POST /api/v1/assignments/{aid}/plans/{planId}/steps` (repeat per step) → 201
4. `POST /api/v1/assignments/{aid}/publish` → 200

Assignment body (required fields):

```json
{"title":"...","description":"...","classId":"<uuid|null>","purpose":"GRADED|PRACTICE",
 "topic":"...","gradingStrategy":"STUDENT_DOCKER_COMPOSE","dockerComposePort":8080,
 "startupTimeoutMs":60000,"executionTimeoutMs":300000,"maxMemoryMb":256,"maxCpu":0.5}
```

- `purpose` defaults to GRADED when omitted; build it with `AssignmentPurpose` semantics:
  GRADED needs `classId` + feeds EXERCISE score, PRACTICE omits `classId` entirely.
- Fields with initializers (`dockerComposePort` etc.) stay populated on absent JSON because the
  DTO deliberately has no `@Builder` — do not "add builder" to `CreateAssignmentRequest`.
- Draft-then-publish: `publish` is what flips `published=true`; students see nothing before it.

Step body: `{"stepOrder","name","stepType","config","weight","timeoutMs","required"}`.
`stepType` ∈ `HTTP_REQUEST | DB_QUERY | DB_SCHEMA_CHECK | DB_MIGRATION` — standalone `EXTRACT`
and `DELAY` are rejected at save time (400): extract via the HTTP step's `config.extract[]`.

`config` keys are **snake_case** and only structurally validated (`StepConfigValidator`):
- HTTP: `method` (GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS), `path` must start with `/`,
  `headers`, `query_params`, `body`, `expected_status` (int 100–599), `extract[]`,
  `data[]` (≤10 rows, one request per row), `auto_inject_headers` (harvested after the step,
  applied to the following steps of the plan).
- `assertions[]` accepts all 13 kinds the executor scores: `status{equals}`, `json_path{path,exists}`,
  `contains{text}`, `body_equals{json}`, `body_structure{json}` (same key set and primitive types,
  values ignored), `field_equals{path,equals}`, `json_path_equals{path,equals}`,
  `array_length{path,equals}`, `contains_item{path,equals}`, `greater_than{path,value}`,
  `less_than{path,value}`, `matches_regex{path,pattern}` (`String.matches`, whole string),
  `any_of{assertions[]}`.
- `extract[]` entries are `{name, from:"response_body", expression:"$...."}` with optional
  `as: scalar|json` and `fallback`. Inside a `data[]` loop the name is a template
  (`bookId_${index}`); row fields and `${index}` are substituted into a fresh copy of the config.
- `${var}` is substituted in `path`, `headers`, `query_params`, `body`, `extract[].name`, and in
  the `equals` of `field_equals` / `json_path_equals`. It is not substituted in `contains.text`,
  `matches_regex.pattern`, `array_length.equals`, `contains_item.equals` or the `value` of
  `greater_than` / `less_than`.
- DB: optional `connection{db_type: postgres|mysql|mariadb, database (bare [A-Za-z0-9_$]+), db_port 1–65535}`,
  `query` (DB_QUERY), `checks[]` (DB_SCHEMA_CHECK: TABLE_EXISTS/COLUMN_EXISTS/INDEX_EXISTS/PRIMARY_KEY).
- Config `required`/`timeoutMs` duplicate the step-level columns; unknown keys are tolerated.

Response shapes to remember: plan steps expose **`type`**, not `stepType`; plans are read back
nested via `GET /api/v1/assignments/{aid}/plans` (each plan carries `steps[]`).

### 4.1 Plan language and data (2026-10-30)

- Plan name, step names, descriptions and every string in `config` are **English**. Vietnamese
  test data is a defect: it turns encoding bugs into assertion mismatches and hides the cause.
- Keep `contains` / `body_equals` text ASCII. Flask's `jsonify` escapes non-ASCII as `\uXXXX`,
  so `contains "Tô Hoài"` can never match a body that really contains "Tô Hoài". Vietnamese
  content belongs in the assignment title/topic/description, not in step data.
- `query_params` values are raw (`?title=The Little Prince`, never pre-encoded); the executor
  percent-encodes names and values as UTF-8, space becomes `%20`.
- Give every HTTP step `timeoutMs` 10000. A 12-step plan with one `data[]` loop makes ~15
  requests, so the 30 s per-request default can exhaust `executionTimeoutMs` 300000 on a broken
  app; at 10 s the worst case still fits.
- Only add a step the student app can satisfy. Read the mock's `docker-compose.yml` first: a
  Flask-only mock has no Postgres, so DB steps can never pass there.

## 5. Verify filters

`GET /api/v1/assignments?classId=&purpose=GRADED|PRACTICE&topic=&published=true&search=&page=0&size=50`
(owner-scoped; all filters combinable) and
`GET /api/v1/assignments/topics?purpose=GRADED|PRACTICE` for the distinct-topic list.

## 6. DB step pattern (Phase 17)

DB steps only pass when the student's `docker-compose.yml` starts a reachable DB service
(the executor connects to `localhost:<db_port>` from inside the graded container network).
The Flask mock `mock/book-app-login-v1` ships no database, so the book assignment plan is
HTTP-only; see §17.17 of `.opencode/plan/generate-data-api/lecturer-full-e2e-plan.md`.

DB steps are added **after** HTTP steps on each plan, running on the student container:

```bash
POST /api/v1/assignments/{aid}/plans/{pid}/steps
```

DB_SCHEMA_CHECK body:
```json
{"stepOrder":N,"name":"Kiểm tra cấu trúc DB (<db>)","stepType":"DB_SCHEMA_CHECK",
 "config":{"connection":{"db_type":"postgres","database":"<db>","db_port":<port>},
           "checks":[{"kind":"TABLE_EXISTS","table_name":"<table>"},{"kind":"PRIMARY_KEY","column":"id"}]},
 "weight":1,"required":true,"timeoutMs":5000}
```

DB_QUERY body:
```json
{"stepOrder":N,"name":"Truy vấn dữ liệu (<db>)","stepType":"DB_QUERY",
 "config":{"connection":{"db_type":"postgres","database":"<db>","db_port":<port>},
           "query":"SELECT COUNT(*) FROM <table>","expected":{"row_count":0}},
 "weight":1,"required":false,"timeoutMs":5000}
```

Phase 17 DB mapping (lecturer-defined; sinh viên phải tuân theo):

| # | Bài | DB | Port | Table |
|---|-----|----|------|-------|
| 1 | Quản lý sách REST API | `books_db` | 8080 | `books` |
| 2 | Quản lý sinh viên | `students_db` | 8081 | `students` |
| 3 | Quản lý đơn hàng | `orders_db` | 8082 | `orders` |
| 4 | Quản lý thư viện | `library_db` | 8083 | `library` |
| 5 | Hệ thống chấm điểm | `grades_db` | 8084 | `grades` |
| 6 | Quản lý kho hàng | `inventory_db` | 8085 | `inventory` |
| 10 | Quản lý tài sản | `assets_db` | 8086 | `assets` |
| 8 | Luyện tập REST API | `api_practice_db` | 8081 | — |
| 9 | Luyện tập Java OOP | `oop_practice_db` | 8082 | — |
