# Plan: Student identity linking — auto-bind Keycloak UUID from CSV email

> Status: IMPLEMENTED + VERIFIED live twice (2026-10-08 and 2026-10-09).
> Goal: when a lecturer imports a CSV, students whose email matches automatically
> get linked (`class_students.student_user_id` filled), without touching Keycloak.
> Decided: match by **email** (must match Keycloak account email, case-insensitive).

## 1. Problem

CSV import stores `student_user_id = NULL` unless the lecturer hand-fills a 4th
UUID column (`ClassService.importStudents`, `ClassService.java:107-114`). Every
student read path joins on `student_user_id` (`findAllByStudentUserId`), so an
unlinked student is invisible forever — and **nothing backfills the column today**
(no `setStudentUserId` call exists anywhere in `src-services`).

Asking lecturers to look up Keycloak UUIDs is the pain this plan removes.

## 2. Why no Keycloak change is needed

- The gateway already stamps `X-User-Email` from the validated JWT
  (`AuthenticationContextFilter.java:96-97`) and strips client-supplied headers,
  so the email cannot be forged.
- Matching is therefore done fully inside `course-service`: no admin API calls,
  no custom Keycloak attributes, no gateway/FE changes.

## 3. Design: lazy binding, NULL-slots only

On every student read, run one idempotent UPDATE first:

```sql
-- only rows that have never been linked
UPDATE class_students
   SET student_user_id = :studentId
 WHERE student_user_id IS NULL
   AND lower(email) = lower(:email)
   AND deleted_at IS NULL
```

Safety invariants (write these into code comments):

1. **Never overwrite** a row that already has an owner — prevents account takeover
   by email collision.
2. **Skip blank emails** — a Keycloak user without email links nothing.
3. The UPDATE returns a count; callers ignore it (no response or behavior change).
4. Retroactive: previously imported CSVs heal on the student's next API call.
   Students who never log in stay unlinked (they can't use the system anyway).

## 4. File changes (course-service only)

### 4.1 `repository/ClassStudentRepository.java` — add query

Mirror the existing `@Modifying + @Query` style
(`AssignmentDockerImageRepository.java:26-33`):

```java
@Modifying
@Query("""
    update ClassStudent s
       set s.studentUserId = :studentId
     where s.studentUserId is null
       and lower(s.email) = lower(:email)
       and s.deletedAt is null""")
int linkStudentIdentity(@Param("studentId") UUID studentId,
                        @Param("email") String email);
```

### 4.2 `service/StudentIdentityService.java` — new, ~15 lines

```java
@Service
@RequiredArgsConstructor
public class StudentIdentityService {

    private final ClassStudentRepository classStudentRepository;

    // Review: <date> — student reads run @Transactional(readOnly=true), so the
    // link needs its own read-write transaction; idempotent, safe to repeat.
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public int linkStudent(UUID studentId, String email) {
        if (email == null || email.isBlank()) {
            return 0;
        }
        return classStudentRepository.linkStudentIdentity(studentId, email.trim());
    }
}
```

### 4.3 Controllers — add one header to the 6 student endpoints

`StudentClassController` (2 methods) + `StudentAssignmentController`
(list/detail/plans/images — 4 methods):

```java
@RequestHeader(value = "X-User-Email", defaultValue = "") String email
```

Pass it through; each service read method calls
`studentIdentityService.linkStudent(studentId, email)` as its **first line**.
No response shape changes, no FE changes, no new i18n keys.

## 5. Tests

- **Repo slice** (`@SpringBootTest` + H2, mirror `DockerImageRepositoryTest`):
  seed (a) NULL row with case-variant email → linked, returns 1;
  (b) already-owned row, same email → untouched; (c) different email → untouched.
- **Linker unit test** (Mockito): blank/null email → repository never called.
- Re-run related suites (`ClassServiceTest`, spec tests).

## 6. Verification (live)

Verified live twice against local course-service + Postgres (2026-10-08 and
2026-10-09), real responses recorded in `usecase-flows.md` UC-15/import note:

1. Import CSV **without** the UUID column.
2. Log in as the matching student → class list / assignments visible.
3. Check DB: `student_user_id` filled on exactly the matching rows.
4. Log in again → idempotent, no duplicates, no errors.
5. Seed a row already owned by user X, log in as user Y with the same email →
   row keeps X (no overwrite).
6. `npm run` suites green; note added to `usecase-flows.md` UC import section
   documenting the email-matching convention.

## 7. Explicit non-goals (do NOT expand scope here)

- No Keycloak custom attributes, no Admin API resolution at import time
  (heavier, same outcome — rejected).
- No `ImportResult.linked` count (lazy design resolves on student action, so
  import time knows nothing — would always be 0).
- No per-row linked badge in `StudentsTab` (separate FE follow-up if wanted).
- No migration for Keycloak email changes (old row keeps old sub; lecturer
  re-imports or fixes manually).
- Email match is case-insensitive + trimmed; CSV emails must equal Keycloak
  account emails modulo case/space — record as precondition, not code.
