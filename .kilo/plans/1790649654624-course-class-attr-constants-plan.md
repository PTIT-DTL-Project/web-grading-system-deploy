# Plan: Replace raw `root.get("name")` / `root.get("semester")` etc. with `CourseClassAttr` constants

## Context

`Constant.java` defines the inner class `CourseClassAttr` with the four column-name constants:

```java
OWNER_ID = "ownerId"
NAME     = "name"
SEMESTER = "semester"
STATUS   = "status"
```

`CourseClassSpecifications.java` already imports `CourseClassAttr` (line 11) but does not actually use it — every `root.get(...)` call still passes a raw string literal. `CourseClassRepository.java` has the same problem plus duplicated specification factory methods.

---

## Tasks (ordered)

### 1. Fix `CourseClassSpecifications.java`
Replace all raw string literals in `root.get(...)` calls with the matching constant.

| Before | After |
|--------|-------|
| `root.get("ownerId")` | `root.get(CourseClassAttr.OWNER_ID)` |
| `root.get("name")` | `root.get(CourseClassAttr.NAME)` |
| `root.get("semester")` | `root.get(CourseClassAttr.SEMESTER)` |
| `root.get("status")` | `root.get(CourseClassAttr.STATUS)` |

Also remove the duplicate import block (lines 13–17 — identical to lines 3–7).

### 2. Fix `CourseClassRepository.java`
Same replacements for the four `root.get(...)` calls in the three static factory methods.

Then **delete the three static factory methods entirely** (`ownedBy`, `qMatches`, `statusIs`, lines 46–68) because:
- `findMine` (line 34) already calls `CourseClassSpecifications.ownedBy(...).and(...).and(...)`.
- No other call-site in the repo references these static methods on the repository.
- Keeping them creates a second, slightly divergent implementation of the same spec (the `SEARCH_PATTERN_FORMAT` constant differs between the two files, which is already a latent bug).

After deletion, the repository interface consists only of:
- `findByIdAndOwnerId`
- `existsByOwnerIdAndNameAndSemester`
- `findAll(Specification, Pageable)`
- `findMine(UUID, String, ClassStatus, Pageable)` default method

### 3. Verify compilation
Run the course-service build (`./mvnw compile -pl src-services/course-service` or equivalent) to confirm no unresolved symbols.

### 4. Update `docs/design/usecase-flows.md` if affected
The use-case flows doc already describes the endpoint behaviour; no text changes expected because this is an internal refactor with no API contract change.

---

## Risks / Notes
- `SEARCH_PATTERN_FORMAT` in `CourseClassSpecifications` uses `String.formatted("%s")` which produces `"%{}%"`; the repository inline version builds the same pattern with string concatenation. Removing the duplicate methods eliminates this divergence.
- The `import vn.edu.ptit.web_grading_system.course_service.Constant.CourseClassAttr` in `CourseClassSpecifications.java` becomes active (used) after the replacements — no further import cleanup needed.

## Out of scope
- Renaming the `Constant` class or the `CourseClassAttr` inner class.
- Changing the API endpoint contracts or `CourseClass` entity fields.
