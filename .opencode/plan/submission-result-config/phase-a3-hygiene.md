# Phase A3 — DETAIL: hygiene (truncation markers, dead column, EXTRACT/DELAY reject)

> Parent: `README.md` (master plan). Status: detailed, not started.
> Goal: no silent truncation, no ghost column, no creatable-but-unrunnable step types.
> Three independent items; each verifiable alone. No behavior change to scoring.

## 1. Unify truncation markers (3 sites, 1 format)

**Current state (verified):**
- Executor `HttpStepExecutor.java:191,194` (`http_log` rows): silent
  `substring(0, 20000)`, no marker — a cut body reads as the full body.
- Executor `stepItem` (A1): `...(truncated N/M)` marker (A1 doc §2).
- result-service `HttpLogService.truncate:79-81`: `...(truncated)` marker
  **without** N/M numbers.
- The three services are separate Maven projects (no shared class possible).

**Exact changes:**
1. `HttpStepExecutor.java:191,194`: append `...(truncated 20000/<len>)` using
   the same `N/M` format as A1 (compute `reqBody.length()` /
   `respBody.length()` already in hand — no extra pass).
2. `HttpLogService.truncate:79-81`: extend marker to `...(truncated N/M)`
   (`value.length()` known; `MAX_CAPTURE_CHARS` is N).
3. Format contract (documented in all 3 code comments):
   `...(truncated <kept>/<original>)`, kept Biase ASCII-char counts matching
   existing `substring`/`length` semantics (no char-vs-byte migration).

**Tests:** unit per site (20001-char input → suffix `...(truncated 20000/20001)`;
exact-20000 input → unchanged; short input → unchanged). Existing suites green.

**Verify:** manual on a >20000-char response body: `http_log`, result payload,
and FE panel all show the same marker with matching numbers.

## 2. Drop dead `expected_response_body` (executor)

**Current state (verified):** column exists (`executor V1 migration:47`,
entity `GradingStepResult.java:71-72`) and **zero** writers/readers repo-wide
(grep: only those two sites). Docs already record it as unpopulated.

**Exact changes:**
1. New executor migration `V8__<date>__drop_expected_response_body.sql`:
   `ALTER TABLE grading_step_results DROP COLUMN IF EXISTS expected_response_body;`
2. Remove the entity field (`GradingStepResult.java:71-72`) + its import fallout
   (none — plain String field).
3. Validate V1→V8 on docker Postgres 16 (established pattern).

**Tests:** migration apply clean; executor suite green (no test references the
field — verified by grep; if one surfaces at execution, update it, don't keep
the column).

**Out of scope:** result-service has no such column (nothing to drop there).

## 3. Reject standalone EXTRACT/DELAY at validation (course-service + FE)

**Current state (verified):**
- `StepType` enum (both services) keeps all 6 values — must stay (stored rows
  reference them; result-service parses reports with them).
- `StepRegistry` has executors for 4 types only → EXTRACT/DELAY steps always
  die at runtime with cryptic `UNKNOWN_STEP_TYPE`.
- `StepConfigValidator.validateAndSerialize` (`course-service/.../service/
  StepConfigValidator.java:37`) switch arms EXTRACT/DELAY → validate-only.
  Sole production caller: `TestPlanService.java:144,192` (create/update step),
  so throwing there surfaces as 400 with zero controller changes. B2's
  `validateStepDraft` reuses the same entry — stays consistent automatically.
- FE `StepEditor.tsx`: `STEP_TYPES` const (`:40-47`) drives the creation
  `Select` (`:665-673`); a warning banner (`:978-985`,
  `step.unsupportedStepWarn`) shows for the two types.

**Exact changes:**
1. **BE** `StepConfigValidator`: in `validateAndSerialize`, replace the
   EXTRACT/DELAY arms with throws:
   - EXTRACT → `"standalone EXTRACT steps are not runnable; use the HTTP step's extract[] instead"`.
   - DELAY → `"standalone DELAY steps are not supported"`.
   - Delete now-dead `validateExtract`/`validateDelay` private methods (verify
     no other callers at execution — grep showed only the switch).
   - Keep the `StepType` enum values (stored data + report parsing).
2. **BE tests**: `StepConfigValidatorTest.java:267-300` EXTRACT/DELAY sections —
   `assertDoesNotThrow` → `assertThrows(IllegalArgumentException)` with message
   match; keep the invalid-shape cases (now asserting the new messages).
3. **FE** `StepEditor.tsx`: remove `'EXTRACT'`, `'DELAY'` from the creation
   `STEP_TYPES` dropdown only. Keep: the `StepType` union (legacy rows still
   render), the warning banner (legacy rows still explain themselves),
   `step.unsupportedStepWarn` + `step.typeOptions.*` i18n keys (still referenced
   — no parity churn).
4. Existing EXTRACT/DELAY rows in DB: still grade to `UNKNOWN_STEP_TYPE`
   (executor untouched) — lecturers recreate them as HTTP `extract[]`. No data
   migration (rewriting lecturer configs silently would be worse). Note this in
   the service log message? No — out of scope; the banner + validator message
   already point the way.

**Tests/verify:** course-service suite green; FE build (parity — no key
removed) + lint; manual: creating EXTRACT/DELAY impossible in UI, API answers
400 with the actionable message, legacy EXTRACT row still displays with banner.

## 4. Execution order within A3 (independent, any order)

Markers → dead column → EXTRACT/DELAY reject. Deploy per service as usual
(executor → course-service → FE); no cross-service ordering constraint.
