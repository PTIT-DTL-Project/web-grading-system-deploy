# HTTP Grading Execution Plan v1.0

> **Date:** 2026-08-26
> **Status:** Approved — implements `execute-plan-v1.0.md` §4.3 + `design-db-v1.0.md` §2.2
> **Decisions:** http logs `lecturer-only` · structure compare `unordered, keys-only` · `Jayway JsonPath 2.9.0` with `JacksonJsonNodeJsonProvider`
> **Scope:** executor-service client that tests student's server, response checks, log persistence, student comments
> **Canonical as-built reference:** `http-test-plan-config.md`

## 1. Goals

Provide, in code, the lecturer's grading exercise as an HTTP client that hits the student's app, checks the response against expected assertions, saves full HTTP evidence for later investigation, and produces a human-readable comment per step and per job.

## 2. Client Setup (`java.net.http.HttpClient`)

*   **Library:** `java.net.http.HttpClient` (JDK 21 built-in). Reuse of `tools.jackson` ObjectMapper for JSON. No `RestTemplate`/`WebClient`/`Feign` — static interfaces cannot express lecturer-defined dynamic paths/headers.
*   **Instance:** singleton `HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).version(HTTP_1_1).build()` bean. Per-step timeout via `HttpRequest.timeout(Duration.ofMillis(step.timeoutMs))`.
*   **Request building:** `VariableContext.substitute(String)` replaces every `${var}` in `method`, `path`, `query_params`, `headers` values, `body` string before building.
    `path` → `http://localhost:${app_port}${path}` + query string. `headers` filtered through `HttpLogService`-style sanitization (no log of auth after substitution).
*   **Error paths:** `HttpTimeoutException` → `ERROR` step, `grading_logs` WARN, `http_log` saved with `status_code=null`.

## 3. Response Checks (`AssertionEngine`)

Input: `actual {statusCode:int, body:String, headers:Map}` + `config.expected_status` / `config.assertions[]`.

| kind | Check |
| `status` + `equals` | `actualStatus == expected` |
| `contains` + `text` | `body.contains(text)` |
| `json_path` + `path` + `exists` | Jayway `JsonPath.compile(path)` on body → exists = result != null && (if list → not empty). `exists:false` inverts. |
| `body_equals` + `json` | `Gson` deep equals `actualBodyJson == expectedJson` |
| `body_structure` + `json` | `GsonStructureComparator.sameStructure(expected, actual)` — unordered key-set compare, recurses, ignores values, checks primitive type |

Output: `List<AssertionDetail>{kind, expected, actual, passed, message}` → serialized to `grading_step_results.assertion_result` (JSONB). Step `PASSED` iff all pass.

`body_structure` algorithm:
*   both `JsonObject` → key sets equal (unordered) and for each key `sameStructure(expected[k], actual[k])`
*   both `JsonArray` → same size and each index `sameStructure`
*   primitives → same `JsonPrimitive` type (`isString/isNumber/isBoolean`) — value ignored

## 4. Variable Extraction (`VariableContext` + JsonPath)

*   After assertions, if `config.extract[]` present: each `{"name","from":"response_body","expression":"$.id"}` → `JsonPath.read(body, expression)` → `context.put(name, resultAsString)`.
*   `EXTRACT` step type handled by same engine: `value` → direct put, `from` → read from prior step's `grading_step_results.response_body` via `extractedVariables` JSON.

## 5. HTTP Log Persistence (for investigation)

**Two sinks for same evidence:**

1.  **`http_log` table (DB_PER_SERVICE):** `HttpLogService.save()` with `direction=OUTBOUND`, `serviceName="executor-grading"`, `url` via `sanitizeUrl()` (redacts `x-amz-*`), `requestBody/responseBody` via `truncate()` (20KB + REDACTED suffix), `requestHeaders/responseHeaders` via `headersToJson()` (drops `authorization` etc.). Private to lecturer — `result-service` read API checks `assignment.ownerId == caller` before exposing. Queryable via `SELECT` and Loki.
2.  **`grading_step_results` denormalized:** `request_url/headers/body`, `response_status/headers/body`, `expected_status/body`, `assertion_result`, `extracted_variables`, `duration_ms`, `error_message`. No join needed to replay a submission.

Every HTTP step saves both, even on `ERROR` (timeout, connection refused).

## 6. Student Comment / Feedback

*   Per-step `error_message`: first failed assertion's `message` (e.g., `"Expected status 201 but got 404"` or `"JSON key 'id' missing"`).
*   Per-job `summary_log` (stored in `grading_jobs.summary_log` and `results.summary_log`): `"Passed 3/5 steps (60%), Score: 6.0/10. Failed: Verify book details — status mismatch, Check DB schema — column 'title' missing type VARCHAR"`
*   Future AI input: `assertion_result` JSON is the structured source for LLM comment generation (deferred).

## 7. File Changes

| File | Action |
| `executor-service/pom.xml` | + `com.jayway.jsonpath:json-path:2.9.0` (Jackson provider) |
| `service/VariableContext.java` | new — `${var}` substitution map |
| `util/GsonStructureComparator.java` | new — unordered structure compare |
| `service/AssertionEngine.java` | new — 5-kind evaluator |
| `service/step/HttpStepExecutor.java` | new — implements `StepExecutor`, uses `HttpClient` + `AssertionEngine` + `HttpLogService` |

## 8. Verification

*   Unit: `GsonStructureComparatorTest` (unordered/ordered/type-mismatch) · `VariableContextTest` (substitution, missing var → empty + WARN) · `AssertionEngineTest` (matrix: status/contains/json_path/body_* × pass/fail) · `HttpStepExecutorTest` (WireMock localhost student stub, variable substitution, timeout → ERROR, http_log persisted).
*   Integration: manual `grading-jobs` produce → executor consumes → assert `grading_step_results` + `http_log` rows, score `PASSED/weightTotal*10`.

## 9. Decisions Log

*   `Jayway` over `Jackson JsonPointer`: preserves `$.id` syntax from `design-db` examples, supports wildcards/filters for future lecturer needs.
*   `INFO` level for grading logs + `http_log`, not `DEBUG` — must survive `INFO` prod level.

## 10. Changelog

| v1.0 | 2026-08-26 | Initial approved plan |
