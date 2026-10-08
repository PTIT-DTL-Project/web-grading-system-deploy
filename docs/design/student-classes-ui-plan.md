# Plan: Student class list + class detail (FE first)

> Date: 2026-10-08 · Status: FE implemented against the contract below; backend
> endpoints do NOT exist yet, so the pages show error states until the backend lands.
> Backend task is tracked in the same file (§Backend contract).

## Goal

Replace the `ComingSoon` placeholder on `/student/classes` with a class list
mirroring the lecturer `ClassesPage` (paged + builder filter), plus a student
class-detail page mirroring `ClassDetailPage` (header + archived banner + one
Assignments tab). Lecturer decisions applied 1:1:

- Click a class → detail page (`/student/classes/:classId`), like lecturer.
- ARCHIVED classes are listed but fully read-only (submit buttons disabled),
  like lecturer.

## Why the backend is required

No backend endpoint returns enrolled classes today. Verified 2026-10-08:

- `GET /api/v1/classes` is `@PreAuthorize("hasRole('LECTURER')")` +
  `listMine(ownerId)` — a student gets 403, and it returns owned (not enrolled)
  classes anyway.
- `GET /api/v1/student/assignments` returns assignments only (`classId` without
  names) — deriving a class list from it would render bare UUIDs.
- The placeholder's own comment says Phase 5 replaces it with
  `GET /api/v1/student/classes`.

## Backend contract (implemented 2026-10-08)

- `GET /api/v1/student/classes?page&size&search&status` → `Page<StudentClassResponse>`
  (no `ownerId`); `GET /api/v1/student/classes/{id}` → enrollment-checked 404.
- Building blocks: `CourseClassSpecifications.enrolledIn(ids)` +
  `CourseClassRepository.findEnrolled(...)` (mirrors `findMine`) +
  `StudentClassController` + `StudentClassService` (empty ids → `Page.empty`).
- Verified live: isolation (2/1/0 classes), name/semester/status filters,
  pagination, enrolled detail 200, non-enrolled detail 404, missing secret 401,
  malformed search 400 — all with real responses in `usecase-flows.md` UC-15.
- Unit tests: `StudentClassServiceTest` (5 tests); related suites green
  (24 tests total, 0 failures).

## FE structure (implemented)

- `shared/api/endpoints/studentClasses.ts` — `listStudentClasses(page, size,
  search?, status?)`, `getStudentClass(classId)`.
- `features/student/StudentClassesPage.tsx` — `ListPage` mirroring
  `ClassesPage` (builder filter name/semester/status, server-side pagination,
  row Open → detail). No create/archive actions.
- `features/student/StudentClassDetailPage.tsx` + `useStudentClass.ts` —
  header/back/semester/status tag/archived banner mirroring `ClassDetailPage`.
- `features/student/tabs/StudentClassAssignmentsTab.tsx` — published
  assignments of the class via existing `listStudentAssignments(..., classId)`;
  Details + Submit navigate to `/student/assignments/:id[?submit=1]`
  (reuses the tested submit flow, no modal duplication); actions disabled when
  archived.
- Router: `student/classes/:classId` behind `RequireRole STUDENT`.
- i18n: reuse `classes.*` / `detail.*` / `assignments.*` / `common.*` only.

## Deliberately out of scope

- Roster / score-components / transcript / my-scores tabs for students: all
  corresponding endpoints are `@PreAuthorize("hasRole('LECTURER')")` (403 for
  students). Separate backend + FE follow-up, not snuck into this task.
- `classId` filter UI on the global `/student/assignments` page: follow-up.

## Verification

- [x] `npm run lint`, `npm run build` (i18n:check + tsc + vite) — 2026-10-08.
  372 keys in sync, **zero new i18n keys needed** (full reuse confirmed).
  Lint: only 2 pre-existing warnings in untouched files.
- [ ] Backend live: student A sees only enrolled classes; B sees none of A's;
      filters/pagination work; non-enrolled detail → error state; VI/EN.
- [ ] Archived class: listed, banner shown, all submit buttons disabled.
