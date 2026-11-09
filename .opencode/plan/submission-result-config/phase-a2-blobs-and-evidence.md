# Phase A2 — DETAIL: expose JSON blobs + request/response (migration + DTOs + FE)

> Parent: `README.md` (master plan). Status: detailed, not started.
> Goal: drill down to each assertion, the sent request, and extracted vars —
> and feed chatbot B1.
> Depends on: A4 redactor (all 5 new fields route through `EvidenceRedactor`;
> if A4 hasn't executed yet, A2 execution includes it — never ship unredacted).

## 1. Current state (verified)

- Executor captures per step and persists executor-side (`GradingStepResult`):
  `assertionResult` (JSON string), `extractedVariables` (JSON string),
  `requestUrl` (String), `requestBody` (String), `actualStatusCode` (Integer),
  `expectedStatusCode` (Integer). Getters exist via Lombok `@Getter`.
- Wire drops all of them: executor `ResultServiceClient.StepResultItem`
  ends at `durationMs` (line ~55+); result-service `CreateResultRequest.
  StepResultItem`, entity `StepResult`, `toStepResponse`, `StepResultResponse`,
  FE `result.ts` likewise have none of the 5.
- Read path already batches steps (`StepResultRepository.findByResultIdIn`),
  so no N+1 is introduced by wider rows.
- Note: `step_results.actual_value/expected_value` columns are JSONB (V1);
  the 5 new columns use TEXT (like `error_message`/`summary_log`) — no JSON
  validity constraint on free-text evidence.

## 2. Exact changes

### 2.1 Migration V7 (result-service, 1 file)

`V7__<date>__step_evidence.sql`:
```sql
ALTER TABLE step_results ADD COLUMN IF NOT EXISTS assertion_details TEXT;
ALTER TABLE step_results ADD COLUMN IF NOT EXISTS extracted_vars TEXT;
ALTER TABLE step_results ADD COLUMN IF NOT EXISTS request_url TEXT;
ALTER TABLE step_results ADD COLUMN IF NOT EXISTS request_body TEXT;
ALTER TABLE step_results ADD COLUMN IF NOT EXISTS response_status INT;
```
No backfill (historical rows keep NULLs = "not captured", rendered as absent
in FE — never backfilled with guesses). No index (read pattern is always
`WHERE result_id IN`, covered by `idx_step_results_result`).
Validate on docker Postgres 16 like V5/V6.

### 2.2 DTO/entity chain (field additions only, no logic)

Same 5 fields, same names, same nullability (all nullable), in order:
1. Executor `ResultServiceClient.StepResultItem`:
   `assertionDetails, extractedVars, requestUrl, requestBody` (String),
   `responseStatus` (Integer).
2. result-service `CreateResultRequest.StepResultItem`: same 5.
3. Entity `StepResult`: same 5 with `@Column(name=...)` matching migration.
4. `ResultService.createResult` persist block: set all 5 from the item
   (no re-redact: the executor's `stepItem` is the trust boundary — separate
   Maven projects, so the redactor class cannot be shared; verified 2026-10-11).
5. `toStepResponse` + `StepResultResponse`: same 5.
6. Executor `stepItem` fill (the only logic touch, ~8 lines):
   - `assertionDetails(item)` = `result.getAssertionResult()` as-is (raw JSON
     string; parsing/pretty-printing is FE's job).
   - `extractedVars` = `result.getExtractedVariables()` as-is.
   - `requestUrl` = `result.getRequestUrl()`, `requestBody` truncated with the
     A1 `truncateForStudent` marker logic, `responseStatus` =
     `result.getActualStatusCode()`.
   - All 4 strings redacted; `null` stays `null` (persist-fallback rows,
     `fail()` path, DB steps without HTTP evidence).

### 2.3 FE — "Grading detail" panel

In `SubmissionResultPage.tsx` expandable area (built in A0 — reuse its
`StepEvidence` component, extend, don't fork):
1. **Assertions table** (only when `assertionDetails` non-null): parse JSON
   defensively (try/catch → hide section on failure, never crash); columns
   kind / expected / actual / verdict icon. Cap 20 rows + "+N more".
2. **Request block**: `METHOD + requestUrl` line (method from `stepType`?
   No — request line isn't stored; show URL + body only, labeled honestly),
   `requestBody` pre-wrap collapsed after 2000 chars with "show more".
3. **Extracted vars**: `extractedVars` pretty-printed JSON, collapsed.
4. i18n: new keys per locale (`result.assertions`, `result.request`,
   `result.extractVars`, `result.showMore` — collision-check at build).

## 3. Edge cases (explicit decisions)

| Case | Behavior |
|---|---|
| Historical rows (5 × NULL) | Sections hidden (absent ≠ empty) — no backfill, no guessing |
| `assertionDetails` unparseable in FE | Section hidden, no crash (same rule as A0 evidence blocks) |
| `fail()` path / persist-fallback rows | All 5 null → panel shows only A0 blocks |
| DB steps (`DB_QUERY` etc.) | Whatever the executor captured (often null bodies) → hidden sections; no special-casing |
| `requestBody` > display budget | Collapsed + "show more" (data already marker-truncated at ≤20000 by A1 logic) |
| Redactor throws mid-persist | Fail-closed per A4 (`"***"`), row still saves |

## 4. Tests

- **Migration**: clean apply V1→V7 on docker PG16 (established pattern).
- **Wire end-to-end** (result-service unit, mocked repos): `CreateResultRequest`
  carrying all 5 → persisted entity asserts all 5 (redacted fixture asserts
  masking applied); `toStepResponse` asserts all 5 present.
- **Executor unit**: `stepItem` on a `GradingStepResult` with all evidence →
  item carries all 5; null-evidence result → all 5 null, no throw.
- **Regression**: both service suites green; FE build (parity) + lint.
- **Redact coverage**: secret-bearing `requestBody` + `extractedVars` fixtures
  → masked in persisted entity (proves A4 wiring, not just A4 unit tests).

## 5. Verify (manual, after deploy executor + result-service)

1. Failing HTTP submission → detail panel shows assertions table (each kind),
   request URL+body, extract vars; secrets masked.
2. Old submission (pre-A2 rows) → panel shows A0 blocks only, no empty
   sections, no crash.
3. Raw `GET /api/v1/results/{submissionId}` JSON contains the 5 fields.

## 6. Explicitly out of scope (other phases own them)

- `actualValue`-for-all-verdicts + verdict-join → A1 (prerequisite behavior,
  panel displays whatever arrives).
- Central redact function itself → A4 (A2 only calls it).
- Rendering already-arrived fields → A0. Markers/dead column → A3.
- B1 consumes `assertionDetails`/`extractedVars` as its primary evidence —
  no B1 change needed when A2 lands (same response DTO).
