# Assignment UI — Phase 1

## Goal
List, create, edit, publish/unpublish assignments inside ClassDetailPage.

## API layer — `shared/api/endpoints/assignments.ts`

### Types
- `CreateAssignmentRequest` — classId, ownerId, title, description, gradingStrategy, dockerComposeTemplate, dockerComposePort, startupTimeoutMs, executionTimeoutMs, maxMemoryMb, maxCpu
- `UpdateAssignmentRequest` — partial (title, description, timeouts, resources)
- `AssignmentResponse` — all fields + published

### Functions
- `listAssignments(classId, { published, search, page, size })` → `Page<AssignmentResponse>`
- `getAssignment(id)` → `AssignmentResponse`
- `createAssignment(req)` → `AssignmentResponse`
- `updateAssignment(id, req)` → `AssignmentResponse`
- `deleteAssignment(id)` → void
- `publishAssignment(id)` → `AssignmentResponse`
- `assignDockerImages(id, imageIds[])` → void

## Components

### AssignmentTab.tsx
- Mounted inside ClassDetailPage
- Header: "Bài tập" + "Thêm bài tập" button
- Table columns: Tiêu đề, Chiến lược chấm, Published, Created, Actions
- Actions: Edit (modal), Delete (confirm dialog), Publish toggle (chip)
- Empty state: "Chưa có bài tập nào" + button to create
- Pagination: StandardPagination

### CreateAssignmentModal.tsx
- Fields: title (required), description, grading strategy (radio), docker compose template (textarea), timeouts (number inputs), resources (memory/CPU number inputs)
- Validation: title required, strategy LECTURER_DOCKER_COMPOSE → template required
- Submit: call createAssignment, close modal, refresh list

### AssignmentCard.tsx
- Row component: title, strategy badge, published chip, actions dropdown

## Hook — `features/assignments/useAssignments.ts`

```typescript
useAssignments(classId) → { data, loading, error, refetch, create, update, delete, publish }
```

## i18n keys
- assignment.title, create, edit, delete, publish, unpublish
- assignment.strategy.student, strategy.lecturer
- assignment.form.title, description, strategy, timeouts, resources

## Scope — NOT included
- Docker image attach UI (API exists, picker deferred)
- Test plan editor (Phase 2)
- Results page (Phase 3)
- Student view (Phase 4)
