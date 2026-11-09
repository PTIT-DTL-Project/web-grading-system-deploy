# Plan: Student portal Batch 1 fixes (executed 2026-10-09)

## Goal

Close the 3 FE-only gaps + 1 nit found in the student-portal audit, without
touching the backend. Bigger items (my-scores endpoint+tab, step descriptions
in assignment detail) stay in later batches.

## Findings (evidence)

1. **FAILED results unreachable.** `MySubmissionsPage.tsx` gated the result
   button on `status === 'GRADED'`, but the backend writes a result row for
   FAILED runs too (`GradingOrchestrator.fail()` → `postResult(FAILED)` →
   `ResultService.createResult` persists the row even with empty items).
   Failed students could never see why they failed.
2. **Forced plan selection contradicts contract.** UC-04 Step 3 + backend
   (`@RequestParam(required = false) UUID planId`) define planId as optional
   (omitted = grade all plans), but the submit modal had a `required` rule.
3. **NaN-red score.** `SubmissionResultPage` compared `totalScore / totalMax`
   with `totalMax = 0` → NaN → false → error color on a non-error state.
4. History button target is fine as-is: its label already says global history,
   and `listByStudent` has no per-assignment filter (that would need backend).

## Changes

- `features/student/submissions/MySubmissionsPage.tsx` — enable the result
  button for `GRADED` **and** `FAILED`; non-terminal states stay locked.
  The results page already renders FAILED rows + `summaryLog`, no change needed.
- `features/student/assignments/SubmitAssignmentModal.tsx` — drop the required
  rule; explicit `""` "All plans" option as default; `allowClear`. The endpoint
  builder already omits falsy `planId`, so `handleSubmit` is untouched.
- `features/student/results/SubmissionResultPage.tsx` — `totalMax > 0 &&`
  guard on the score color.
- Locales (both files, same order): add `submitModal.allPlans`
  ("All plans" / "Tất cả plans"); delete now-unused `submitModal.planRequired`.
- Review comments per repo convention on each fix.

## Decisions recorded

- Default submit = all plans (matches backend default semantics; one-click
  submit for the common case).
- Keep the global-history button unchanged (label is accurate; per-assignment
  history needs a backend filter — separate task if wanted).
- My-scores tab and step-description rendering stay in later batches.

## Verification

- [x] `npm run build` (i18n:check + tsc + vite), `npm run lint`.
- [ ] Browser: seed one FAILED submission → button enabled → details + error
      log visible; submit with/without plan pick → presigned URL with/without
      `planId`; zero-max submission → neutral color; VI/EN switch.
