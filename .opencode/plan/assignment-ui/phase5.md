# Assignment UI — Phase 5: Polish

## Goal
Loading states, empty states, error handling, i18n, routes.

## Tasks
- Loading spinners on all async operations
- Empty states for list, results, submissions
- Error handling with ErrorState component
- Retry on network failure
- Full i18n parity (vi.json + en.json)
- Register routes in router.tsx
- Route guards (RequireRole LECTURER for lecturer pages, STUDENT for student)

## i18n keys (complete)
- assignment.* (all keys from phases 1-4)
- assignment.error.* (network, notFound, permission)
- assignment.empty.* (no assignments, no results, no submissions)
