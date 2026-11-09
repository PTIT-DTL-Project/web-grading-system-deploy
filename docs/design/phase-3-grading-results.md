# Phase 3 — Grading & Results

## Implemented

### 3a. Lecturer Grading Results ✅
- Backend: `GET /api/v1/assignments/{assignmentId}/results?includeSteps=true`
- FE: `useResults` hook, `AssignmentResultsPage.tsx`
- Route: `/classes/:classId/assignments/:assignmentId/results`
- Display: per-student, per-plan, per-step scores with expandable rows

### 3b. Lecturer Submissions ✅
- Backend: `GET /api/v1/assignments/{assignmentId}/submissions`
- FE: `useSubmissions` hook, `AssignmentSubmissionsPage.tsx`
- Route: `/classes/:classId/assignments/:assignmentId/submissions`
- Display: student, file, status, latest, createdAt

### 3c. Docker Image management ✅
- Backend: `DockerImageController` CRUD (`GET/POST/PUT/DELETE /api/v1/docker-images`)
- FE: `DockerImagePage.tsx` with CRUD modals
- Route: `/docker-images`

## Actions column simplification
- Draft: "Publish" button only
- Published: "Results" + "Submissions" buttons (navigate to pages)
- Delete: kept in actions column

## Files changed
- `shared/types/assignment.ts` — added StudentResultResponse, AssignmentResultResponse, AssignmentResultStepResponse, SubmissionResponse, DockerImageResponse
- `shared/api/endpoints/assignments.ts` — added listResults, listSubmissions, docker images CRUD
- `features/assignments/useResults.ts` — new hook
- `features/assignments/useSubmissions.ts` — new hook
- `features/assignments/AssignmentResultsPage.tsx` — new page
- `features/assignments/AssignmentSubmissionsPage.tsx` — new page
- `features/docker/DockerImagePage.tsx` — new page
- `features/classes/tabs/AssignmentTab.tsx` — simplified actions column, navigate to pages
- `app/router.tsx` — added 3 new routes
- `locales/vi.json`, `locales/en.json` — added keys