# Phase 4 — Student-Facing

## Scope

After Phase 3 (lecturer workflow done), Phase 4 is the student side: login → view enrolled classes → view published assignments → submit → view results.

## Backend — 1 missing endpoint

**`GET /api/v1/student/classes`** — returns list of classes the student is enrolled in (join `class_students`). Reuses existing `ClassResponse` DTO. All other student endpoints already exist and are ownership-scoped.

## Frontend — 5 screens, 4 routes

### 1. `/student/classes` — Enrolled class list
- Replace ComingSoon with table: class name, semester, status
- Use `ClassResponse` DTO

### 2. `/student/assignments` — Published assignments
- Table: title, class, strategy, published date
- Only show published assignments of enrolled classes

### 3. `/student/assignments/:assignmentId` — Assignment detail + submit
- Show info, test plans, docker images
- "Submit" button → upload zip → `POST /api/v1/submissions/presigned-url`
- Upload via RustFS presigned URL

### 4. `/student/submissions` — My submissions
- Table: assignment, file, status, latest, time
- Use `GET /api/v1/submissions`

### 5. `/student/submissions/:submissionId/results` — Grading results
- Per-plan, per-step results
- Use `GET /api/v1/results/{submissionId}`

## Order
1. Backend `GET /api/v1/student/classes`
2. Student classes list (screen 1)
3. Student assignments list (screen 2)
4. Submission upload + my submissions (screens 3 + 4)
5. Results (screen 5)

## Reuse from Phase 3
- `useResults`, `useSubmissions` hooks → student reuses
- `AssignmentResultsPage` → same UI, different access control
- i18n keys → already complete