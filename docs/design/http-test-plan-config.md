# HTTP test-plan config and executor behavior

> **Status:** Canonical as-built reference for lecturer-authored test plans and the implemented HTTP grading path.
> **Scope:** Test-plan/step config schema for all step types, plus exactly how the executor reads, substitutes, sends, checks, extracts, and persists an `HTTP_REQUEST` step.
> **Related:** `http-grading-execution-plan.md` (approved executor plan) · `execute-plan-v1.0.md` (grading pipeline) · `design-db-v1.0.md` (schema) · `docs/api/scenarios/exercise-steps.sh` (real payloads).

## 1. Mental model

A lecturer authors grading as data, not code:

```text
assignment
└── test plan (ordered scenario, weighted)
    └── test step (ordered operation, typed config JSON)
```

At grading time, the executor receives plans/steps through the internal course-service contract, resolves `${variables}`, sends HTTP traffic to the student app, evaluates assertions, extracts values for later steps, and persists request/response evidence.

Two boundaries matter:

- **Authoring boundary:** course-service validates structure and stores canonical JSON.
- **Execution boundary:** executor-service parses that JSON, substitutes variables, performs I/O, and writes grading evidence.

## 2. Test-plan and test-step fields

### 2.1 `test_plans`

Source: `src-services/course-service/src/main/java/vn/edu/ptit/web_grading_system/course_service/entities/TestPlan.java`

| Field | Meaning |
|---|---|
| `assignmentId` | Assignment that owns the plan. |
| `name` | Lecturer-facing plan name. |
| `description` | Optional plan-level instruction/context. |
| `sequenceOrder` | Execution order across plans in one assignment. |
| `weight` | Plan weight used by assignment-level scoring. |

Plans are returned in `sequenceOrder` order by `TestPlanService.internalPlans()`.

### 2.2 `test_steps`

Source: `src-services/course-service/src/main/java/vn/edu/ptit/web_grading_system/course_service/entities/TestStep.java`

| Field | Meaning |
|---|---|
| `planId` | Owning plan. |
| `stepOrder` | Execution order inside the plan. Chained steps depend on this order. |
| `name` | Short human title, for example `Create a book`. |
| `description` | Optional lecturer-authored instruction. If empty, frontend may generate text from `config`; grading does not depend on it. |
| `stepType` | One of `HTTP_REQUEST`, `DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`, `EXTRACT`, `DELAY`. |
| `config` | JSONB object whose required shape depends on `stepType`. |
| `expectedResult` | Optional JSONB override, used by DB-type steps. |
| `weight` | Step weight used in scoring. |
| `timeoutMs` | Optional per-step timeout override. |
| `required` | Whether a failed step stops its plan. |

Steps are returned in `stepOrder` order.

### 2.3 Ordering and update rules

Implemented in `TestPlanService.java:100-229`:

- Duplicate `sequence_order` in one assignment is rejected.
- Duplicate `step_order` in one plan is rejected.
- Reordering onto an occupied `step_order` is rejected; free the slot first.
- Changing `stepType` requires a valid replacement `config` in the same request.
- Null fields in an update generally preserve stored values; `name` is trimmed on create/update.

## 3. Config schema by step type

Validation is structural, not semantic. Source: `StepConfigValidator.java:30-48,56-171`.

Unknown JSON keys are tolerated for forward compatibility. Tolerance does not mean the executor understands those keys.

### 3.1 `HTTP_REQUEST`

```json
{
  "method": "POST",
  "path": "/api/v1/books",
  "headers": {"Content-Type": "application/json"},
  "query_params": {"title": "Dế Mèn"},
  "body": {"title": "Dế Mèn Phiêu Lưu Ký", "author": "Tô Hoài", "year": 1941},
  "expected_status": 201,
  "assertions": [
    {"kind": "status", "equals": 201},
    {"kind": "json_path", "path": "$.id"},
    {"kind": "contains", "text": "Dế Mèn"},
    {"kind": "body_structure", "json": {"id": "", "title": ""}},
    {"kind": "body_equals", "json": {"title": "Dế Mèn Phiêu Lưu Ký"}}
  ],
  "extract": [
    {"name": "bookId", "from": "response_body", "expression": "$.id"}
  ]
}
```

Rules:

- `method` must be one of `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS`, case-insensitively.
- `path` must be non-empty and start with `/`.
- `headers` and `query_params`, when present and non-null, must be JSON objects.
- `expected_status`, when present, must be an integer from `100` to `599`.
- `assertions`, when an array, supports only `status`, `body_structure`, `body_equals`, `json_path`, and `contains`.
- `status` needs `equals`; `json_path` needs `path`; `contains` needs `text`.
- Every `extract` item needs `name`, `from`, and `expression`.

Real chained example: `docs/api/scenarios/exercise-steps.sh:80-100`.

### 3.2 `DB_QUERY`

```json
{
  "query": "SELECT title, author FROM books WHERE id = ${bookId}",
  "expected": {"row_count": 1, "columns": ["title", "author"]}
}
```

`query` must be non-empty. `expected`, when present, must be an object.

### 3.3 `DB_SCHEMA_CHECK`

```json
{
  "checks": [
    {"kind": "TABLE_EXISTS", "table_name": "books"},
    {"kind": "COLUMN_EXISTS", "table_name": "books", "column_name": "title"},
    {"kind": "INDEX_EXISTS", "index_name": "idx_books_title"},
    {"kind": "PRIMARY_KEY", "column": "id"}
  ]
}
```

`checks` must be a non-empty array. Supported kinds and required fields are exactly those validated in `StepConfigValidator.java:109-135`.

### 3.4 `DB_MIGRATION`

```json
{
  "statements": [
    "INSERT INTO books (id, title) VALUES ('...', 'Book A')"
  ]
}
```

`statements` must be a non-empty array of non-empty strings.

### 3.5 `EXTRACT`

```json
{
  "variables": [
    {"name": "pageSize", "value": "10"},
    {"name": "bookId", "from": "step_1", "expression": "$.id"}
  ]
}
```

Each variable needs a `name`, plus either a direct `value` or both `from` and `expression`.

### 3.6 `DELAY`

```json
{
  "duration_ms": 5000
}
```

`duration_ms` must be a positive integer.

## 4. Internal executor contract

Course-service exposes executor-facing DTOs without the public response envelope:

- `InternalPlanDto`: `id`, `name`, `sequenceOrder`, `weight`, ordered `steps`.
- `InternalStepDto`: `id`, `stepOrder`, `name`, `stepType`, `config` as a JSON string, `expectedResult`, `weight`, `timeoutMs`, `required`.

`TestPlanService.internalPlans()` fetches all plans for the assignment in `sequenceOrder` order, fetches their steps in `stepOrder` order, then nests steps under their plans.

Current boundary status:

- `GradeSubmissionHandler` persists `planId` from the grading event.
- Executor-side filtering to run only that plan is still pending; do not document it as implemented.

## 5. HTTP executor pipeline

### 5.1 Executor selection

`StepRegistry` maps an executor by the string returned from `StepExecutor.type()`. For HTTP, that string is `"HTTP_REQUEST"`. An unknown type throws `IllegalArgumentException`.

The HTTP executor receives `HttpStepExecutor.StepContext` containing `jobId`, `planId`, `stepId`, `stepOrder`, `stepName`, parsed `config`, `VariableContext`, and optional `timeoutMs`.

### 5.2 Variable substitution

`VariableContext.substitute()` replaces every `${name}` with the value stored under `name`.

Important behavior:

- Substitution is applied to method, path, query values, header values, and stringified body.
- A missing variable is replaced with an empty string and logged as a warning.
- Replacement text is quoted safely for regex replacement.

This is how a later step can call `/api/v1/books/${bookId}` after an earlier step extracted `bookId`.

### 5.3 Request construction

Implemented in `HttpStepExecutor.java:54-115`.

1. Resolve method, defaulting to `GET`.
2. Resolve path, defaulting to `/`.
3. Build the URL as:

```text
http://localhost:${app_port}${path}[?query]
```

4. Append each `query_params` entry as `key=value`, joined with `&`. Keys and values are not URL-encoded by the current implementation.
5. Substitute every header value; no request is sent without processing configured headers first.
6. If `body` is present, stringify it and substitute variables inside the resulting string.
7. If a body exists and no `Content-Type` header is present, add `Content-Type: application/json`.

Method handling in the current implementation:

| Configured method | Actual request |
|---|---|
| `POST` | POST with body publisher, possibly empty. |
| `PUT` | PUT with body publisher, possibly empty. |
| `PATCH` | `PATCH` with body publisher. |
| `DELETE` | DELETE with no body; a configured body is ignored. |
| `HEAD` | HEAD with no body. |
| Any other value, including validated-but-unmatched `OPTIONS` | `GET`. |

### 5.4 Timeouts and HTTP client

Source: `HttpClientConfig.java:11-20`, `HttpStepExecutor.java:90-117`.

- Shared singleton JDK `HttpClient`.
- Connect timeout: 10 seconds.
- HTTP version: HTTP/1.1.
- Redirect policy: normal redirects.
- Per-request timeout: `config.timeoutMs`, else the step-level `timeoutMs` supplied in `StepContext`, else 30 seconds.

A timeout or transport error produces an `ERROR` step result, not a silent retry.

### 5.5 Assertions

Source: `AssertionEngine.java:40-117`.

`evaluateHttp()` first checks `expected_status` when present, then evaluates every object in `assertions[]`.

| Assertion | Pass condition |
|---|---|
| Implicit `expected_status` | Actual status equals configured status. |
| `status` + `equals` | Actual status equals configured status. |
| `contains` + `text` | Response body contains the configured substring. |
| `json_path` + `path` | JsonPath result exists, or does not exist when `exists: false`. An empty list counts as absent. |
| `body_equals` + `json` | Parsed actual JSON deeply equals parsed expected JSON. |
| `body_structure` + `json` | Same structure under `GsonStructureComparator`. |
| Unknown `kind` | Fails that assertion. |

`body_structure` means:

- Objects must have the same key set; values are checked recursively.
- Arrays must have the same length; elements are compared by index, not as sets.
- Primitives must have the same JSON type; values are ignored.
- Null only matches null.

A step passes when every evaluated assertion passes. If there are no `expected_status` and no `assertions`, a successfully completed request is therefore a smoke probe that passes.

### 5.6 Variable extraction

Implemented in `HttpStepExecutor.java:129-145`.

After assertions, every configured `extract` entry is processed:

- `name` becomes the variable name.
- `expression` is evaluated as JsonPath against the response body.
- JsonPath uses suppressed-exception configuration.
- The extracted value is stringified and stored in `VariableContext`.
- The name/value map for that step is also persisted as `extracted_variables`.

Current limitation: although `extract` validation requires `from`, the HTTP implementation always parses the current response body. An `extract.from` pointing at another step is not branched in this executor.

## 6. Grading evidence

### 6.1 `grading_step_results`

Source: `GradingStepResult.java:21-93`.

Every HTTP execution writes:

- Job/plan/step identity: `jobId`, `planId`, `stepId`, `stepOrder`, `stepName`, `stepType`.
- Status: `PASSED`, `FAILED`, `SKIPPED`, or `ERROR`.
- Actual request: `requestUrl`, `requestHeaders`, `requestBody`.
- Actual response: `responseStatusCode`, `responseHeaders`, `responseBody`.
- Expectations: `expectedStatusCode`; `expected_response_body` is available in the table but not populated by the current HTTP executor.
- Machine-readable verdicts: `assertionResult` JSON and `extracted_variables` JSON.
- Diagnostics: `errorMessage`, `durationMs`, `startedAt`, `completedAt`.

`status` values mean:

- `PASSED`: all evaluated assertions passed.
- `FAILED`: at least one evaluated assertion failed.
- `ERROR`: transport/timeout/processing exception before or during evaluation.
- `SKIPPED`: assigned by orchestration policy outside this executor, for example after a required-step failure.

### 6.2 `http_log`

Source: `HttpLog.java:24-61`, `HttpStepExecutor.java:163-186`, `HttpLogService.java:23-83`.

The HTTP executor also saves an `OUTBOUND` log with service name `executor-grading`, method, substituted URL, allocated `app_port`, headers, bodies, status, duration, and response headers.

Two precision notes:

- `HttpLogService` provides helpers for sensitive-header removal, signed-query redaction, file-content detection, and byte truncation.
- The current HTTP executor path serializes the substituted headers directly and truncates request/response bodies at 20,000 characters. It does not call `sanitizeUrl()` or `headersToJson()` in the reviewed code path, so lecturers should avoid placing real secrets in step config unless an outer orchestration/sanitization layer is added.

## 7. Worked example

Lecturer config:

```json
{
  "stepOrder": 1,
  "name": "Create a book",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/books",
    "headers": {"Content-Type": "application/json"},
    "body": {"title": "Dế Mèn Phiêu Lưu Ký", "author": "Tô Hoài", "year": 1941},
    "expected_status": 201,
    "extract": [
      {"name": "bookId", "from": "response_body", "expression": "$.id"}
    ]
  }
}
```

Executor behavior:

1. Substitute variables. No variables are present, so the body remains unchanged.
2. Send:

```text
POST http://localhost:${app_port}/api/v1/books
Content-Type: application/json
{"title":"Dế Mèn Phiêu Lưu Ký","author":"Tô Hoài","year":1941}
```

3. Check that status is `201`.
4. Evaluate `$.id` against the response body.
5. Store `bookId` as a string for step 2.
6. Persist `PASSED` or `FAILED`, response evidence, assertion result, and extracted variables.

A follow-up step can then use:

```json
{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200
}
```

If `bookId` was never extracted, the executor logs a warning, sends `/api/v1/books/`, and the resulting failure evidence shows why.

## 8. Known config/executor mismatches to preserve

Do not silently “fix” these in prose. They are load-bearing implementation facts:

- `OPTIONS` passes authoring validation but currently executes as `GET`.
- `DELETE` accepts a body in validation but sends no body.
- Query parameters are appended without URL-encoding.
- Legacy `expected_body_contains` may appear in old scenario payloads, but the current assertion engine does not evaluate it.
- HTTP extraction always uses the current response body; `extract.from` is validated but not used to select another source.
- Internal plans currently return all assignment plans sorted; per-`planId` executor filtering is pending.
- `GradingStepResult.expected_response_body` exists but is not populated by the current HTTP executor.
- Current HTTP `http_log` persistence does not invoke every `HttpLogService` redaction helper in this path.

## 9. Verification notes

This is a docs-only change. Validation for the later build step is:

- Read back the created Markdown and check headings, tables, code fences, JSON examples, and code references.
- Confirm every behavioral claim traces to the files cited above.
- Keep the executor/orchestrator boundary explicit: implemented HTTP execution versus pending orchestrator filtering/scoring behavior.
