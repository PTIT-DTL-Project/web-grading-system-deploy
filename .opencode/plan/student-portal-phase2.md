# Plan: Student portal Phase 2 — step descriptions in assignment detail (executed 2026-10-09)

## Goal

Honor UC-04 Step 2: render each grading step's lecturer-authored `description`
verbatim; fall back to auto-generated text from the (sanitized) `config` only
when description is null/empty. Previously the plan panels showed name, weight,
step count and plan description — individual steps were never rendered.

## Evidence that no backend work was needed

`PlanResponse.steps[]` already carries everything: `name`, `description`
(nullable), `type`, `config` (object, server-sanitized: `connection`, `extract`
and `expected` stripped by `StudentAssignmentService.sanitizeConfig`), `weight`.
Steps arrive sorted by `stepOrder`.

## Changes (FE only)

- `features/student/assignments/StudentAssignmentDetailPage.tsx`:
  - Each plan `Collapse` panel now lists its steps: name (strong) + text.
  - Text rule: `description?.trim()` wins; else `stepAutoText()`; else name only.
  - `stepAutoText` per type, using only post-sanitize fields:
    - `HTTP_REQUEST`: `METHOD path` + `→ expect {status}` when present.
    - `DB_QUERY`: first line of `query`, cut at ~120 chars.
    - `DB_SCHEMA_CHECK`: `N checks (KIND1, KIND2…)` with deduped kinds.
    - `DB_MIGRATION`: `N statements`.
    - Anything else / unparseable config → `null` (name only).
  - `config` is typed `unknown`: guarded by `asRecord` (object, non-array)
    before any field access; every field read is type-checked.
- Locales (both files, same position): `step.expectStatus`
  ("→ expect {{status}}" / "→ mong đợi {{status}}"), `step.schemaChecks`
  ("{{count}} checks" / "{{count}} kiểm tra"), `step.migrationStatements`
  ("{{count}} statements" / "{{count}} câu lệnh"). Method/path/SQL/kinds stay
  raw protocol text, untranslated by design.

## Deliberately out of scope

- My-scores endpoint + tab (needs backend) → Phase 3.
- Auto-text for `DELAY`/`EXTRACT` (server drops them from student view anyway).
- No changes to hooks, endpoints, editor, or backend.

## Verification

- [x] `npm run build` (i18n:check + tsc + vite), `npm run lint`.
- [ ] Browser with one assignment covering both description states × all four
      visible step types; VI/EN switch.
