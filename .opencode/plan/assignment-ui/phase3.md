# Assignment UI — Phase 3: Results page

## Goal
Grading view for lecturer — see student results + step detail.

## API layer additions
- `getResults(assignmentId, { studentCode, includeSteps })` → `StudentResultResponse[]`
- `getSubmissions(assignmentId)` → `SubmissionResponse[]`

## Components

### ResultsPage.tsx
- Route: `/classes/:classId/assignments/:id/results`
- Table: student code, name, plan, score, status
- Expandable rows: step detail (passed, weight, score, actual, expected, error, duration)

### ResultsTable.tsx
- Per-student results with weighted total
- Letter grade display

### SubmissionsTable.tsx
- Submission list: student, zip file, status, createdAt
- Download zip action

## i18n keys
- assignment.results.title, submissions.title
- assignment.result.student, plan, score, status, grade
- assignment.result.step.passed, weight, actual, expected, error, duration
- assignment.submission.student, file, status, date
