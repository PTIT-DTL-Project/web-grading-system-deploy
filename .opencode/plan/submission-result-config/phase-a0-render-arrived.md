# Phase A0 — DETAIL: render what already arrives (FE-only)

> Parent: `README.md` (master plan). Status: detailed, not started.
> Goal: every byte A1 sends becomes visible immediately; verdicts read
> unambiguously (pass / fail / infra-error / skipped).
> Depends on: nothing (works on today's payloads; A1 values appear automatically
> once deployed). Touches only `frontend-src/web-grading-system-fe`.

## 1. Current behavior (verified)

`features/student/results/SubmissionResultPage.tsx:113-161` (`stepColumns`):
- Verdict column (`:116-132`) already splits SKIPPED (neutral tag, 2026-10-10)
  but renders both FAILED and ERROR as the same red ✕ — infra errors
  (timeout, connection refused, UNKNOWN_STEP_TYPE) read as "my code is wrong".
- `errorMessage` column (`:146-160`) renders single-line small red text, no
  wrap toggle — A1's joined verdicts (`"status: expected 201, got 404; …"`)
  will overflow.
- `actualValue` / `expectedValue` arrive on the wire (`shared/types/result.ts`)
  but no column renders them — the two most useful debug fields are invisible.
- `summaryLog` Alert per result card (`:224-235`) exists; keep as-is.

## 2. Exact changes (1 file + i18n, ~60 lines)

In `SubmissionResultPage.tsx`:

1. **Expandable step rows** (antd `Table expandable`, per-row, no new route):
   ```tsx
   expandable={{
     expandedRowRender: (r: StepResultResponse) => <StepEvidence step={r} />,
     rowExpandable: (r) => !!(r.actualValue || r.expectedValue || r.errorMessage),
   }}
   ```
   New in-file component `StepEvidence` (same file, ~40 lines — no new file
   for one panel):
   - `actualValue`: label + `Typography.Paragraph code copyable pre-wrap`
     (antd `copyable` gives the copy button free, with clipboard fallback
     built in — no manual `navigator.clipboard` code).
   - `expectedValue`: same block, only when non-null.
   - `errorMessage`: full text pre-wrap (the column keeps its 1-line clamp).
   - Each block guarded by null (a passed step with no expected shows only actual).
2. **Split ERROR from FAILED** in the verdict column:
   - Needs an error/infra signal: use `stepType`? No — derive from
     `errorMessage` content? Fragile. Correct source: backend does not send a
     distinct status on the wire today (`passed: false` covers both).
   - Decision (explicit): v1 keeps red ✕ for all non-pass/non-skip, but the
     label under the expandable panel prefixes infra-looking messages.
     Defer exact ERROR styling to A2, which adds structured verdicts.
     (This doc supersedes the master plan's ERROR-amber item — reason: no wire
     signal exists yet; A2's `assertionDetails` provides it.)
3. **i18n**: at most 2 new keys per locale — `result.evidence` ("Chi tiết
   chấm"/"Grading detail"), `result.expectedValue` ("Kỳ vọng"/"Expected").
   Check collisions with existing `result.*` keys at build time
   (`npm run build` runs `i18n:check` parity).

## 3. Explicit non-goals (later phases)

- Per-assertion table, request block, extract vars → A2 (needs new wire fields).
- Truncation markers on display → A1 already marks in data; FE shows as-is.
- `summaryLog` format changes → none (Alert stays).

## 4. Tests / verify

- FE has no component-test harness in this repo (verified: no `*.test.tsx`) —
  verification is build + lint + manual, per project convention for UI text:
  1. `npm run build` (tsc + i18n parity 400+ keys) and `npm run lint` (only the
     2 pre-existing warnings).
  2. Manual on staging: one passing + one failing real submission —
     expandable opens, actual/expected/copy work, long bodies don't break layout
     (Table `size="small"`, panel `pre-wrap` + antd ellipsis on the column).
  3. Regression: SKIPPED tag, scope badge, assignment title, summary Alert all
     unchanged (visual pass over the same page).

## 5. Risks

- Long `actualValue` (≤20000 chars) in DOM: acceptable (one expanded row at a
  time; antd only mounts expanded content). No virtualization needed.
- `copyable` on huge text: antd copies full string — fine, user-initiated.
