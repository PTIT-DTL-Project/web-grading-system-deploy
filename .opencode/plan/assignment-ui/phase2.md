# Assignment UI — Phase 2: TestPlanEditor

## Goal
CRUD for test plans and steps inside AssignmentTab expandable rows.

## API layer additions — `shared/api/endpoints/assignments.ts`

### Types
- `TestPlan` — id, assignmentId, name, description, sequenceOrder, weight
- `TestStep` — id, planId, stepOrder, name, description, stepType, config, expectedResult, weight, timeoutMs, required
- `StepType` — HTTP_REQUEST | DB_QUERY | DB_SCHEMA_CHECK | DB_MIGRATION | EXTRACT | DELAY

### Functions
- `listPlans(assignmentId)` → TestPlan[]
- `createPlan(assignmentId, request)` → TestPlan
- `updatePlan(planId, request)` → TestPlan
- `deletePlan(planId)` → void
- `createStep(planId, request)` → TestStep
- `updateStep(stepId, request)` → TestStep
- `deleteStep(stepId)` → void

## Components

### TestPlanEditor.tsx
- Plan list (left) + step editor (right)
- Add plan button, delete plan button
- Each plan: name, description, sequenceOrder, weight
- Steps list per plan

### PlanCard.tsx
- Plan name (editable inline), weight, sequenceOrder
- Expand/collapse to show steps
- Steps list with step name, type, weight, required

### StepEditor.tsx
- Step type selector
- Type-specific config fields:
  - HTTP_REQUEST: method, URL, headers (JSON), body (JSON), expectedStatus
  - DB_QUERY: connection.db_type, SQL, expectedRows
  - DB_SCHEMA_CHECK: table, columns
  - DB_MIGRATION: SQL scripts
  - EXTRACT: source, target, mapping (JSON)
  - DELAY: seconds
- Config JSON editor for config/expectedResult
- Weight, timeoutMs, required toggle

## i18n keys
- assignment.plan.title, create, edit, delete
- assignment.step.title, type, weight, required, timeout
- assignment.stepType.http, dbQuery, dbSchema, migration, extract, delay
- assignment.status, statusPublished, statusDraft

## File structure
```
features/assignments/
  useAssignments.ts (extend with plans + steps)
  AssignmentTab.tsx (extend - expandable rows)
  AssignmentCard.tsx (extend - expand trigger)
  TestPlanEditor.tsx (new)
  PlanCard.tsx (new)
  StepEditor.tsx (new)
```
