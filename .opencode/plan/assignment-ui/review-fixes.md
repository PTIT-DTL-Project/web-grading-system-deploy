# Assignment UI — Pullfrog review fixes

Status: implemented on 2026-10-05. `npm run build` passes; `npm run lint` passes with two pre-existing warnings in unrelated class-list files. Browser matrix still needs a manual run.

`Review: 2026-10-05, Pullfrog PR review.`

## P0 — merge blockers

### 1. DockerImagePage never loads
- Add mount-time fetch (useEffect or useDockerImages hook)
- Fix `resp.result ?? resp` → consume `resp.result` (Page shape)
- Confirm backend default page size or add pager

### 2. keycloak.ts init failure → reload loop
- Remove unconditional `window.location.href = '/login'` on init rejection
- Let init errors reach AuthGate failed state with Retry
- Preserve D8 simplified retry path

### 3. silentCheckSsoFallback: false breaks 3p-cookie recovery
- Restore library default (full-page prompt=none for blocked 3p cookies)
- Fix/remove misleading hasAuthCallback() comment

## P1 — correctness and UX

### 4. Results/submissions can never refresh
- Remove global `staleTime: Infinity`; scope per query
- Expose Refresh/Retry via refetch()
- Replace raw `String(error)` with useApiErrorMessage()

### 5. Null step verdict shown as failure
- Add explicit passed / failed / pending states
- Type steps as AssignmentResultStepResponse[], not any[]
- Add assignment.pending key

### 6. Create modal destroys input on failure
- Keep modal open and preserve values on backend failure
- Only reset/close on success
- Fix hidden dockerComposeTemplate carryover and hardcoded dockerComposePort

### 7. Archived classes remain editable
- Thread archived through TestPlanEditor → PlanCard → StepEditor
- Wire refreshToken into AssignmentTab / useAssignments

### 8. Excess requests and fake pagination
- Gate useTestSteps on card expansion
- Fix StepEditor staying open and incorrect saving flag
- Pass real page/pageSize to assignments; use shared standardPagination

### 9. i18n gaps
- Add 10 missing runtime keys to both locales
- Replace hardcoded English labels with t() keys
- Keep vi.json / en.json key order identical

### 10. Guards, brand, dead code
- Move sessionStorage write into redirect effect
- Decide `/` behavior for signed-in users
- Fix brand link semantics or remove navigation
- Delete HomeRedirect.tsx or fix stale references
- Delete or adopt dead AssignmentCard.tsx

## P2 — verify before merge
- Confirm `/results?includeSteps=` and array vs Page<> shapes against backend
- Confirm deep-link redirect URIs registered for web-grading-fe
- Final lint/build/browser verification

## Execution order
1 → 2 → 3 (P0) → 4 → 5 → 6 → 7 → 8 → 9 → 10 (P1) → 11 → 12 (P2)
