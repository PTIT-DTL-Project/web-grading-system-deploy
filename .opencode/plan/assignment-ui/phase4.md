# Assignment UI — Phase 4: Student view

## Goal
Student sees published assignments, plans (sanitized), docker images.

## Components

### StudentAssignmentsPage.tsx
- Route: `/student/assignments`
- List published assignments for enrolled classes
- Search, filter by class

### StudentAssignmentDetail.tsx
- Route: `/student/assignments/:id`
- Assignment detail (published + enrolled check)
- Sanitized plans (no DELAY/EXTRACT/credentials)
- Docker image metadata list

## API calls
- `GET /api/v1/student/assignments` — list
- `GET /api/v1/student/assignments/{id}` — detail
- `GET /api/v1/student/assignments/{id}/plans` — sanitized plans
- `GET /api/v1/student/assignments/{id}/docker-images` — images
