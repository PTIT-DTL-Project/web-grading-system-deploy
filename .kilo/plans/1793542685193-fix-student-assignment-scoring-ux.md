# Plan: Fix student assignment scoring and UX issues

## Goal
Fix the issues identified in the code review for the uncommitted frontend changes (student assignment scoring display, expand/collapse behavior, error resilience).

## Affected files
- `frontend-src/web-grading-system-fe/src/features/student/assignments/StudentAssignmentDetailPage.tsx`
- `frontend-src/web-grading-system-fe/src/features/student/assignments/useStudentAssignment.ts`
- `frontend-src/web-grading-system-fe/src/features/student/results/SubmissionResultPage.tsx`
- `frontend-src/web-grading-system-fe/src/shared/api/endpoints/results.ts` (review only - may need minor adjustments)

## Issues to fix

### 1) Make score fetching resilient (non-blocking)
**Problem:** `useStudentAssignment` does `Promise.all([getStudentAssignment, getAssignmentPlans, getMyAssignmentResults])` so failure of results fetch breaks the whole page.

**Fix:**
- Fetch results separately with `Promise.allSettled` or in its own try/catch after core data loads.
- Add `myResults` state initialized to `null`, set it only if results fetch succeeds; don't fail the hook if it fails.
- Keep `reload()` working for all fetches.

### 2) Fix expand/collapse logic
**Problem:** When `expandAll` is true and user clicks individual expand/collapse, code sets `expandAll(false)` and clears `expandedStepIds` → collapses everything.

**Fix:** Use a model where "expand all" sets a base state and individual toggles work as exceptions.
- Option A: Track `collapsedIds` when `expandAll` is true; track `expandedIds` when `expandAll` is false. Compute `isStepExpanded(id)` as `expandAll ? !collapsedIds.has(id) : expandedIds.has(id)`. Toggle flips the relevant set.
- Option B: Always track `expandedIds`; `expandAll` sets all step IDs into it (or a separate flag), individual toggle adds/removes from `expandedIds` and also updates `expandAll` based on whether all are expanded/collapsed.
- Prefer Option A for clarity. Update `toggleExpandAll` and individual click handler accordingly.

### 3) Make plan score/submit detection more defensive
**Problem:** `planScore` falls back to any row with `!r.planId` (full row) and scans steps; `planSubmitted` similar. Could misclassify with multiple full rows or unexpected shapes.

**Fix:**
- Prefer PLAN rows first (already done). For fallback, be more defensive: if multiple full rows exist, maybe prefer latest/completed? Or just pick the first with steps? Or skip derivation if ambiguous and rely on backend `exerciseScore`/flags.
- Add guards: check `Array.isArray`, validate numbers. If derivation is ambiguous (multiple full rows), don't guess - fall back to null/"—" appropriately.
- Keep behavior consistent with backend contract.

### 4) Handle assignment score fetch in SubmissionResultPage gracefully
**Problem:** Query added but no loading/error handling; could show confusing UI.

**Fix:**
- Destructure `isLoading`/`isError` from `useQuery` for assignment results.
- Show loading state or hide/fade card if loading? Or show "—" with subtle indicator. Better: if loading, show card with skeleton or just don't show score yet; if error, don't show card or show "—" without misleading hint.

### 5) Minor improvements
- Ensure translation keys exist (already added in both locales per diff)
- AssignmentTab refresh button - ensure error handling is fine

## Implementation plan
1. Update `useStudentAssignment.ts` to fetch results separately with error isolation
2. Update `StudentAssignmentDetailPage.tsx` expand/collapse logic (Option A)
3. Harden `planScore`/`planSubmitted` with defensive checks
4. Update `SubmissionResultPage.tsx` to handle query states

## Validation
- Test expand/collapse behavior
- Test with unsubmitted plans showing 0.00
- Test when results fetch fails - page should still load
- Check lint/types if possible

## Notes
- Follow existing codebase patterns (antd, react-query where used, etc.)
- No backend changes needed
