# Plan: Bulk user import — students + lecturers (executed 2026-10-09)

## Goal

Let the system admin (who already knows every name/email) bulk-create student
**and lecturer** accounts from one CSV, each with its username as the initial
password and a forced change on first login. No Keycloak Console handwork per user.

## Decisions (all confirmed before implementation)

- **Owner: api-gateway, not FE.** The Admin API needs the service-account
  secret, which must never enter the browser bundle (established rule, §5.1
  precedent); FE cannot call Keycloak Admin directly (CORS + creds); per-row
  orchestration and error aggregation belong server-side. The "FE converts
  CSV→Keycloak JSON" variant still needs a secret-holding forwarder, so it
  saves nothing and couples FE to Keycloak's representation format.
- **No `partialImport`.** Single-shot with coarse per-batch SKIP/OVERWRITE/FAIL
  policies and no per-row reporting — wrong shape for an admin UX that must say
  which row failed and why.
- **CSV:** `username, fullName, email, role?` — role `STUDENT`/`LECTURER`
  (optional `ROLE_` prefix tolerated), blank defaults to `STUDENT` (secure
  default: the lower privilege). Unknown role fails the row only.
- **Initial password = username** (known to both admin and holder, no
  out-of-band exchange) + `temporary: true` (Keycloak 26 auto-stamps
  `UPDATE_PASSWORD`; existing forced-change flow handles first login).
- **Duplicates skip + report** (re-runnable files); no class enrollment
  bundling (separate step, as today).
- **First/last names:** full name → `firstName`, `lastName` omitted (verify the
  live user-profile doesn't require it — Keycloak default does not).

## Backend (api-gateway)

- `KeycloakAdminClient` + `KeycloakAdminWebClient`: `createUser` (201 +
  `Location` id; non-201 → typed `CreateUserException` carrying status so
  `409`→skip vs `400`→invalid vs rest→provider-error),
  `setTemporaryPassword` (flat credential, `temporary: true`, reusing
   `resetVerdict`), `findRealmRole` (`{id, name}`), `assignRealmRoles` (204),
   plus a `bulk()` session sharing one memoized token across an import.
   Existing `resetCredential(temporary: false)` untouched.
- `UserImportService`: caps (2 MB, 2000 rows), header heuristic mirroring
  `ClassService.parseCsv`, sequential per-row orchestration (deterministic
  report order, gentle on Keycloak), one `BulkOperations` session per import
  sharing a single memoized admin token, role reps resolved lazily per used
  role (a student-only file never touches ROLE_LECTURER, so a missing lecturer
  role cannot abort it; a failed role lookup fails that row only).
- `UserImportController`: `POST /api/v1/admin/users/import`, ADMIN gate via
  explicit in-handler JWT role check (gateway has no `@PreAuthorize`; 403
  envelope otherwise). Must stay admin-only precisely because it can mint
  lecturer accounts. Response `{created: {STUDENT, LECTURER}, skipped,
  failed: [{row, username, role, reason}]}`. Known partial state: a
  role-assignment failure leaves user+password without role — reported as
  `role_not_assigned` for manual repair, since re-runs skip as duplicate.

## Frontend

- `Role` gains `'ADMIN'` (deliberate allow-list edit + comment; `RequireRole`
  works generically; wrong-role still lands on `/no-role`).
- Route `/admin/users`, sidebar entry (`nav.adminUsers`), landing branch.
- `AdminUsersPage`: upload UI mirroring `StudentsTab` (`customRequest`,
  `.csv` check, template download), result summary + per-row failure table with
  reason-code → i18n mapping (raw fallback for unknown codes).
- `endpoints/admin.ts` (`FormData` post, mirror `importStudents`), sample
  `public/samples/users-import.csv`.
- i18n: `auth.admin`, `nav.adminUsers`, full `admin.*` set, both locales.

## Deliberately out of scope

- Class enrollment bundling, notifications on import, editing existing users,
  password-policy alignment (realm export shows none — live may differ; the
  `weak_password` mapping already covers rejection).

## Verification

- [x] Gateway: 52/52 tests (10 new: 6 client wire incl. single-token-grant
      session test + 4 service incl. mixed batch and student-only lazy-role
      test; pre-existing 42 untouched).
- [x] FE `npm run build` (i18n:check 402 keys + tsc + vite), `npm run lint`
      (only 2 pre-existing warnings).
- [ ] Live: service account holds `manage-users` on the live realm (export file
      is stale — verify first); 4-row file (new student, new lecturer,
      duplicate, bad email) → both log in with correct roles, both forced to
      change password, re-run fully skips; `lastName`-omitted creation accepted.
- [ ] Ops note for the admin: initial password = username; service-account
      role requirement.
