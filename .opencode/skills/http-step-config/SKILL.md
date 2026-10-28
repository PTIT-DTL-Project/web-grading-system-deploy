name = "http-step-config"
description = "Conventions for the grading HTTP step config: data[] data-driven loop, Loop Safety Governor, auto_inject_headers at plan scope, and variable substitution rules in the executor-service grading engine."

# HTTP Step Config (grading engine) — conventions

## Trigger
Editing or reviewing HTTP_REQUEST step config handling in `executor-service` (`HttpStepExecutor`, `GradingOrchestrator`, `Constant`) or course-service step validation (`StepConfigValidator`). Keywords: `data[]`, `auto_inject_headers`, `loop safety governor`, `VariableContext`, `AssertionEngine`.

## data[] data-driven loop (executor-service)
- A step with a non-empty `data[]` array runs once per row. Each row's fields substitute `${field}` and `${index}` (0-based) into a deep copy of the config.
- Placeholders must live in **quoted JSON string positions** (e.g. `"year": "${year}"`). A raw unquoted token in a numeric position is not valid JSON and fails to parse.
- Rows substitute into a fresh config; the shared `VariableContext` is reused, so `${accessToken}`, `${$UUID}` and previously extracted vars still resolve per iteration.
- Extracts such as `bookId_${index}` are written into the **shared** context and survive the loop (later steps can read `${bookId_0}`…).
- Step status = PASSED only if every iteration passes; FAILED if any failed; ERROR if any errored. Assertion details and extracted variables are merged into the single step-result row; HTTP metadata comes from the last iteration. Each iteration logs its own `HttpLog` row.
- `StepContext.withConfig(JsonNode)` builds an iteration context sharing job/step/variables.

## Loop Safety Governor
- course-service `StepConfigValidator` rejects inline `data[]` with > 10 entries (400 at save) and requires each entry to be an object.
- executor `Constant.Loop.FOREACH_TRUNCATE = 20` truncates a large for-each at runtime so one lecturer cannot start thousands of requests in a step.
- `Constant.Loop.DATA_INLINE_MAX = 10` (executor) mirrors the validator's 10 (separate Maven modules → constant stated in both places).

## auto_inject_headers (plan scope, executor `GradingOrchestrator.runSteps`)
- Declared on a step (typically login), not on every step. It is **plan-scoped**: accumulated into a per-plan map and injected into every subsequent `HTTP_REQUEST` step in the same plan.
- Header templates are substituted against the current `VariableContext` at injection time, so `${accessToken}` resolves after the login step extracted it. Already-set headers on a step are not overridden.
- The key `auto_inject_headers` is removed from the config before reaching `HttpStepExecutor` (orchestrator concern, not an executor config key).
- course-service `StepConfigValidator` requires `auto_inject_headers` to be an object of string values (400 otherwise).

## Constants (executor-service `Constant.java`)
- `HttpStep.DATA = "data"`, `HttpStep.AUTO_INJECT_HEADERS = "auto_inject_headers"`.
- Assertion kind `ANY_OF = "any_of"` (already implemented in `AssertionEngine.checkAnyOf` + validator).
- No new dependencies: substitution uses `tools.jackson.databind.ObjectMapper` tree walk (`.properties()` on objects, enhanced-for on arrays), not string regex on raw JSON.

## Validation (course-service `StepConfigValidator.validateHttp`)
- `data`: non-empty array, entries objects, ≤ 10 entries.
- `auto_inject_headers`: object of strings.
- Reuse existing `ASSERTION_KINDS` set (already includes `any_of` and Phase 1/2 kinds).

## What not to do
- Do not re-parse `${...}` placeholders with string regex on the raw config JSON (breaks on quoted values).
- Do not store per-iteration data fields (title, year) in `VariableContext`; they exist only within the iteration via config substitution.
- Do not add a plan-level config field to `TestPlan`/`InternalPlanDto` for `auto_inject_headers` — step-config declaration achieves the same plan-scoped behavior without schema changes.
