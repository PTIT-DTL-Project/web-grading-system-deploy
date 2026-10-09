# Plan: Student portal Phase 3 — "My scores" tab (executed 2026-10-09)

## Goal

Give students a read-only scores view: per-component entries + total +
letter grade + GPA, with an explicit incomplete state. No new computation —
reuse the exact core serving the lecturer transcript row so the two can never
drift.

## Backend (course-service, no gateway/schema changes)

- `ScoreService`: extracted the computation body of `getStudentScores` into
  private `buildScores(classId, code)`; lecturer path behavior unchanged.
- `ScoreService.getMyScores(classId, studentId)`: resolves the caller's
  `studentCode` from `findAllByStudentUserId` filtered by class; absent →
  `404 "Class not found"` (ownership convention); several rows for one user
  (shouldn't happen) → first wins, documented in code.
- `StudentClassController`: `GET /api/v1/student/classes/{id}/my-scores`
  (`X-User-Id` + `X-User-Email` headers like its siblings; no `@PreAuthorize`
  — enrollment check in service is sufficient, same pattern as the other
  student endpoints). Calls `getEnrolledClass` first (link side-effect +
  gate), then `getMyScores`.
- `computeExercise` already degrades to null when unlinked or result-service
  is down — the tab inherits that without extra code.

## Frontend

- `endpoints/studentClasses.ts`: `getMyScores(classId)` → existing
  `StudentScoresResponse` type, no new types.
- `tabs/useStudentScores.ts` + `tabs/StudentScoresTab.tsx`: summary
  (total, grade tag via local `GRADE_COLORS` copy — features never import
  across each other, per repo rule), entries table (type via
  `components.typeLabel`, weight as % like transcript, score or empty),
  incomplete Alert naming the missing components.
- `StudentClassDetailPage`: new `scores` tab. Single new i18n key for the
  whole phase: `detail.tabMyScores` ("Điểm của tôi" / "My scores"); everything
  else reuses `transcript.*` / `scores.*` / `common.*`.
- Read-only tab: archived classes show it without any disabled state, mirroring
  the lecturer `TranscriptTab`.

## Deliberately out of scope

- Roster visibility for students (privacy by default; needs new endpoints).
- Lecturer flows (zero behavior change — verified by untouched tests).
- Notifications on new scores.

## Verification

- [x] Unit: enrolled→scores, not-enrolled→404 without touching score repos,
      unlinked→404 (Mockito, no context).
- [x] Related suites green (ScoreServiceTest 8, incl. pre-existing grade math).
- [x] Live (local course-service + Postgres, seeded components + scores):
      complete → `8.50/A/3.7`; incomplete → all nulls; stranger → generic 404.
      Real responses recorded in `usecase-flows.md` UC-16.
- [x] FE `npm run build` (i18n:check 376 keys + tsc + vite), `npm run lint`
      (only 2 pre-existing warnings).
- [ ] Browser: complete vs incomplete rendering, VI/EN, archived class tab.
