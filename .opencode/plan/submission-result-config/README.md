# Verbose grading logs + AI chatbot — master plan

> Status: planning (2026-10-10). Details live in per-phase files in this folder.
> Next: user picks a phase → assistant writes the phase-detail doc (if missing),
> then executes.

## Problem (verified by code, not assumed)

Students see almost nothing when a step fails: `errorMessage = null` on every
assertion failure, so the FE error column is empty and the summary falls back
to generic `"assertion failed"`. The executor captures plenty
(URL/headers/body of request and response, per-assertion verdicts, extracted
vars, timing) but `GradingOrchestrator.stepItem` forwards only a subset to
result-service. Response bodies forward only when the step PASSED — backwards
for debugging. The FE does not even render two fields that already arrive
(`actualValue`, `expectedValue`).

Key evidence (all paths verified in `src-services/`):
- `executor-service/.../service/grading/GradingOrchestrator.java:788-811`
  (`stepItem`) is the single choke point executor → result-service.
- Assertion verdicts live in `GradingStepResult.assertionResult` (JSON) and
  never reach the wire; request/response/extract live in
  `GradingStepResult.requestUrl/requestBody/responseBody/extractedVariables`.
- `ScoreCalculator`: `10 × passedWeight/ranWeight`, skipped excluded, HALF_UP.
- Variable syntax is `${var}` (`VariableContext`), JSONPath is `$…` (Jayway);
  assertion kinds are lowercase-only.
- Sanitization precedent: `StudentAssignmentService.sanitizeConfig` strips
  `connection/extract/expected` + drops DELAY/EXTRACT steps.
- Lecturer prose knowledge base: `docs/design/grading-config-reference.md`,
  `docs/design/http-test-plan-config.md` (§3 schemas, §8 mismatch list),
  `docs/design/grading-assertion-engine-test-plan.md`, `docs/design/usecase-flows.md`.

## Decisions log

| Date | Decision |
|---|---|
| 2026-10-10 | A (verbose logs) before B (chatbot); logs are the chatbot's mandatory input |
| 2026-10-10 | Rule-based explainer before any LLM; LLM paraphrase default OFF, last |
| 2026-10-10 | New `chatbot-service` (port 8085), not a package in course-service |
| 2026-10-10 | `EXTRACT`/`DELAY` standalone: reject at validation with a clear message (no executors) |
| 2026-10-10 | Dead column `expected_response_body`: drop (migration) rather than keep a ghost column |
| 2026-10-10 | Chatbot reads user-scoped data **only via APIs**, never direct DB (risks in `appendix-db-read-policy.md`) |

## Execution order

A1 (+minimal redact) → A0 → A4 full → A2 → A3 → B1 → B2 skeleton+tools →
B2 static retrieval → B3/pgvector (if needed). Each phase verified
independently per its file; deploy per phase (executor → result-service → FE).

## Files

| File | Phase |
|---|---|
| `phase-a1-verdict-join.md` | A1 — errorMessage + actualValue for every verdict (BE, no migration) |
| `phase-a0-render-arrived.md` | A0 — render what already arrives (FE-only) |
| `phase-a4-sanitize.md` | A4 — centralized sanitize |
| `phase-a2-blobs-and-evidence.md` | A2 — JSON blobs + request/response (migration + DTOs + FE) |
| `phase-a3-hygiene.md` | A3 — truncation markers, dead column, EXTRACT/DELAY reject |
| `phase-b1-rule-explainer.md` | B1 — rule-based explainer, no LLM |
| `phase-b2-lecturer-agent.md` | B2 — lecturer agentic assistant |
| `appendix-response-schema.md` | F1 AI response JSON contract |
| `appendix-db-read-policy.md` | DB-read policy (binding) + smallest safe experiment |
