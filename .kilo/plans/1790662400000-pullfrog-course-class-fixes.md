# Plan: Fix Pullfrog review findings on CourseClass spec/repository

## Context

The new `CourseClassSpecifications` + `CourseClassRepository` + `ClassController.listMine` + `ClassService.listMine` chain has a critical bug and several correctness/doc issues flagged by Pullfrog. The FE currently does **not** send `q` or `search` on the classes list (`useClasses` calls `listClasses(page, pageSize)` with no filter params), so none of these paths are exercised in production yet — but they all break on first use.

---

## Tasks (ordered by severity)

### 1. Fix `SEARCH_PATTERN_FORMAT` — CRITICAL, causes 500 on every `?q=anything`

**File:** `CourseClassSpecifications.java:21-28`

`SEARCH_PATTERN_FORMAT = "%s%"` is used as a `String.formatted(...)` format string. `String.formatted` = `String.format(this, args)`, so a trailing bare `%` is parsed as a conversion specifier and throws `UnknownFormatConversionException: Conversion = '%'` for every non-blank input.

Because the spec factories run eagerly (outside the returned lambda), the throw happens in `ClassService.listMine` before the repository is reached, and `@ExceptionHandler(Exception.class)` maps it to 500.

**Fix:**
- Delete `SEARCH_PATTERN_FORMAT` constant entirely.
- Build the pattern by concatenation: `"%" + q.trim().toLowerCase(Locale.ROOT) + "%"`.
- Use `Locale.ROOT` (Turkish locale maps `I` → dotless ı, breaking case-insensitive matching).

Also add `import java.util.Locale;`.

### 2. Escape LIKE wildcards (`%`, `_`) in qMatches

**File:** `CourseClassSpecifications.java:30-39`

The current code passes `'\\'` as the escape char to `criteriaBuilder.like()`, but `term` is never actually escaped — `q=%` still reaches the pattern as a live wildcard and returns every class. Pullfrog verified this against H2: `search=%` returned all rows, `search=D_t` matched "Database".

**Fix:**
```java
String escaped = term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
String pattern = "%" + escaped + "%";
return (root, query, criteriaBuilder) -> criteriaBuilder.or(
        criteriaBuilder.like(criteriaBuilder.lower(root.get(CourseClassAttr.NAME)), pattern, '\\'),
        criteriaBuilder.like(criteriaBuilder.lower(root.get(CourseClassAttr.SEMESTER)), pattern, '\\')
);
```

Order matters: escape `\` first so we don't double-escape the backslashes we insert for `%` and `_`.

### 2b. Fix inaccurate escaping comment

**File:** `CourseClassSpecifications.java:33-35`

The comment currently says the escaping "matches the sibling AssignmentRepository behavior". This is false: `AssignmentRepository` builds patterns via `concat('%', cast(:search as string), '%')` with no ESCAPE clause, so a user-typed `%` there is still a live wildcard. The escaping in `CourseClassSpecifications` is actually a divergence from `AssignmentRepository`, not a parity.

**Fix:** Reword the comment to describe what this file does, without claiming parity:

```java
// Review: 2026-09-29, Pullfrog PR — escape LIKE wildcards before wrapping
// in %...%. criteriaBuilder.like() with escape '\\' treats user-typed '%'
// and '_' as literals. This is stricter than AssignmentRepository, which
// does not escape wildcards.
```

### 3. Fix Javadoc on `CourseClassAttr` — wrong terminology causes runtime errors

**File:** `Constant.java:31`

Current: `/** Database column names used in CourseClass entity queries. */`
- `OWNER_ID = "ownerId"` is a **JPA attribute name**; the mapped column is `owner_id`.
- `root.get(String)` resolves the **attribute path**, not the column name.
- A reader who "corrects" `OWNER_ID` to `"owner_id"` to match the comment gets `IllegalArgumentException` on every class query.

**Fix:** Change Javadoc to:
```java
/** JPA attribute names used by CourseClassSpecifications. root.get() resolves these
 *  against the entity attribute path, NOT the database column name.
 *  OWNER_ID is "ownerId" (attribute); the mapped column is "owner_id". */
```

### 4. Remove misleading Javadoc + redundant `findAll` redeclaration

**File:** `CourseClassRepository.java:24-28`

Lines 24-28 redeclare `JpaSpecificationExecutor.findAll(Specification, Pageable)` with a Javadoc copied from `AssignmentRepository.findMine`. The Javadoc claims "Owner-scoped listing with optional combinable filters. Null filter arguments are ignored." — but this is a plain framework override with no owner scope and no null-ignoring logic. The description belongs to `findMine` below it.

**Fix:** Delete lines 24-28 (the Javadoc + redeclaration). `JpaSpecificationExecutor` already provides `findAll(Specification, Pageable)`. Keep `findMine`'s Javadoc where it is.

### 5. Resolve `findMine` duplication — make `ClassService` use it

**Files:** `CourseClassRepository.java`, `ClassService.java`

Pullfrog's observation: `findMine` is dead code — `ClassService.listMine` composes the same three-spec chain inline at `ClassService.java:62-67`. The two copies already differ (service pre-trims `q`; `findMine` passes raw `q`). Next filter change has to land in two places.

**Fix:**
- Move trim/blank normalisation into `qMatches` (which already guards blank).
- Make `ClassService.listMine` call `courseClassRepository.findMine(ownerId, q, status, pageable)`.
- This makes the two paths genuinely equivalent and `findMine` the single source of truth for the spec chain.

### 6. Rename `q` → `search` in controller + service for consistency

**Files:** `ClassController.java:44`, `ClassService.java:60`

Both `AssignmentController` (line 43) and `StudentAssignmentController` (line 28) expose their text filter as `@RequestParam(required = false) String search`. The classes endpoint uses `q`. Both are optional, but a UI sending `search=` to `/api/v1/classes` gets a silently unfiltered 200 instead of an error — a UX failure.

**Fix:** Rename `@RequestParam String q` → `@RequestParam String search` in `ClassController`, and rename the method parameter in `ClassService.listMine`.

Note: The FE `listClasses(page, pageSize)` currently sends no filter at all, so this rename is safe from a client perspective. When the search box is wired in the FE, it will use `search` consistently across both list endpoints.

### 7. Add sort to `PageRequest`

**File:** `ClassController.java:46`

`PageRequest.of(page, size)` has no sort. Paging through one's own classes can skip/overlap rows. The comparable `AssignmentRepository.findMine` orders by `a.createdAt desc`.

**Fix:**
```java
Pageable pageable = PageRequest.of(page, size, Sort.by("createdAt").descending());
```

---

## Status

All 7 tasks completed. Pullfrog re-reviewed commit edf1ab7 and confirmed all threads across reviews 5348734885, 5349304650, 5349599294 and 5349623597 are resolved. Nothing blocking remains on the PR.

## Carried forward (not blocking)

- **No test coverage for escaping** — the one non-obvious logic piece has no test pin. `DockerImageRepositoryTest` is the ready template (~30 lines to adapt for `CourseClassRepositoryTest`).
- **Postman collection** — still documents only `page/size` for "get list mine classes paging". Update separately.
- **Specification-chain vs JPQL convention split** — `/classes` now uses `Specification` chain with escaped LIKE; assignment endpoints use JPQL with unescaped LIKE. Divergence is intentional but undecided for future endpoints.

---

## Validation

1. `./mvnw compile -pl src-services/course-service` — no compile errors.
2. `./mvnw test -pl src-services/course-service` — existing tests still pass.
3. Manual smoke test against running course-service:
   - `GET /api/v1/classes` → 200 (no params)
   - `GET /api/v1/classes?search=ptit` → 200, filtered
   - `GET /api/v1/classes?search=20261` → 200, filtered by semester
   - `GET /api/v1/classes?search=%` → 200, no crash (escaped)
   - `GET /api/v1/classes?status=ACTIVE` → 200
   - `GET /api/v1/classes?search=anything&status=ARCHIVED` → 200, both filters compose
