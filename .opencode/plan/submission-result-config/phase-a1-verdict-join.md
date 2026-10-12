# Phase A1 — DETAIL: errorMessage + actualValue for every verdict

> Parent: `README.md` (master plan). Status: detailed, not started.
> Goal: every failed step tells WHAT failed and WHAT the server returned.
> No migration. No DTO/entity change. No FE change (renders in A0).

## 1. Current behavior (verified)

`GradingOrchestrator.stepItem` (`executor-service/.../service/grading/
GradingOrchestrator.java:788-811`):
- `actualValue` (lines 804-806): response body ≤20000 **only when the step
  passed**, else `null`. Failed steps — the ones needing debug — show nothing.
- `errorMessage` (line 808): passed straight through. For assertion failures it
  is always `null` (HTTP: `HttpStepExecutor.java:163-165` passes `null err`;
  DB: `DbQueryExecutor.java:113-116`, `DbSchemaCheckExecutor.java:79-81`).
  Only exceptions (ERROR) and infra paths carry a message.
- Net effect today: failed row = name + `"assertion failed"` summary fallback
  (`buildSummary:821-825`) + empty error column.

Available but unused in `stepItem`: `result.getAssertionResult()` (JSON array
of `{kind, expected, actual, passed, message}` — `AssertionEngine.java:33-40`,
`@Data`, serialized by Gson in `HttpStepExecutor.java:160`; DB steps via
`DbStepResults.buildResult:41-57`), `result.getResponseBody()`.

Accessors exist via Lombok `@Getter` on `GradingStepResult`. The orchestrator
already imports `tools.jackson.databind.ObjectMapper` (Jackson 3) — reuse it,
no new dependency. DB-step `assertionResult` shape may differ slightly → parse
defensively (see §3).

## 2. Exact changes (1 method + 2 private helpers, ~25 lines)

In `stepItem`, replace lines 804-808 with calls to two helpers:

```java
.actualValue(truncateForStudent(result == null ? null : result.getResponseBody()))
.expectedValue(step.getExpectedResult())   // unchanged
.errorMessage(errorMessage != null ? errorMessage
        : joinFailedVerdicts(result == null ? null : result.getAssertionResult()))
```

Helper 1 — `truncateForStudent(String body)`:
- `null` → `null`.
- Redact the INTACT body first (`EvidenceRedactor`, phase A4), then cap the
  redacted result at 20000 with `...(truncated 20000/<redacted-len>)`.
  Order is load-bearing (Pullfrog security review): cutting first breaks JSON
  and silently disables key masking past 20000 chars.
- (A3 later unifies the other two truncation sites onto the `N/M` marker;
  A1 introduces the marker here first.)

Helper 2 — `joinFailedVerdicts(String assertionJson)`:
- blank/null → `null` (keeps today's `"assertion failed"` summary fallback working).
- parse as JSON array with the existing `ObjectMapper`; for each element with
  `passed == false`, emit `kind + ": expected " + expected + ", got " + actual`
  (fall back to element `message` when expected/actual are both absent; skip
  malformed elements, never throw — catch-all returns `null` on unparseable
  input so one weird blob cannot break the whole report).
- Cap each expected/actual side at 500 chars (`...(truncated 500/N)`) — a
  `contains` verdict embeds the whole body, and uncapped it would swallow
  `errorMessage`/`summaryLog`. Each side is redacted WHILE INTACT before
  capping (the joined line is not JSON, so end-of-line redaction alone misses
  JSON keys — Pullfrog JSON-key leak review). Then cap entries at 5 +
  `"; …(N more)"`.
- Whole joined line goes through `EvidenceRedactor` once more at the end
  (idempotent safety net).

Helper 3 — minimal redact inside both (full version in A4):
- mask JSON string values for keys matching `authorization|password|secret|token`
  (case-insensitive) in `actualValue`; mask `Bearer …` / `Basic …` token shapes
  in `errorMessage`. Reuse the key list FE `TestPlanEditor` already uses for
  its preview masking (same constant values, documented in code comment).

`buildSummary` untouched — it automatically picks up the richer `errorMessage`
via items (`:821-825`).

## 3. Edge cases (explicit decisions)

| Case | Behavior |
|---|---|
| `result == null` (persist-fallback rows) | Both helpers return null → identical to today |
| `assertionResult` unparseable / unexpected shape (DB rows) | `joinFailedVerdicts` returns null → summary fallback, report still saves |
| Skipped steps (`skipStep` passes explicit message) | `errorMessage != null` branch wins, verdict-join never runs |
| `fail()` path (empty items, score 0) | Unchanged — no steps, no items |
| Body exactly 20000 chars | Unchanged (no marker); marker only when strictly longer |
| Secrets in verdict `message` text | Masked by the same key patterns (best-effort on free text) |

## 4. Tests (executor-service, no Spring context needed)

New `GradingOrchestratorStepItemTest` (or extend the closest existing unit test
file if one covers `stepItem` — check at execution; pure unit via direct method
or via `postResult` with mocked client — prefer the smallest seam that reaches
`stepItem` without Kafka/Docker):
1. Failed HTTP verdict JSON `[{kind:"status",expected:201,actual:404,passed:false},
   {kind:"contains",expected:"ok",actual:"err",passed:false}]` with null err →
   `errorMessage == "status: expected 201, got 404; contains: expected ok, got err"`.
2. Failed step with 20001-char body → `actualValue` length 20000 + marker suffix
   containing both numbers.
3. Passed step body unchanged (regression: today's behavior preserved).
4. Malformed `assertionResult` (`"not-json{"`) → `errorMessage == null`, no throw.
5. Body `{"password":"x"}` → masked; header dump with `Bearer abc` → masked.
6. Explicit err (skip message) passes through verbatim, verdict-join skipped.

Existing executor suite must stay green (216/216 baseline).

## 5. Verify (manual, after deploy)

1. Deploy executor-service only (no other service changes in this phase).
2. Rerun a known-failing submission (e.g. the book-app assertion-fail case):
   - FE error column shows `status: expected …, got …` (after A0 renders it;
     before A0, confirm via `GET /api/v1/results/{submissionId}` raw JSON).
   - `actualValue` present on the failed step with truncation marker when long.
3. No contract change: same fields, same endpoints — result-service/FE need no
   deploy for this phase to be safe.

## 6. Explicitly out of scope (later phases)

- New wire fields (`assertionDetails`, request line, extract vars) → A2.
- Full centralized sanitize → A4 (A1 ships minimal masking only).
- FE rendering/expansion → A0. Truncation unification + dead column → A3.
- `EXTRACT`/`DELAY` handling → A3.
