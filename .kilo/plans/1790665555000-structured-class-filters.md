# Plan: Generic structured-search parser driven by entity metadata

## Context

Instead of a `ClassSearchFilters` record hardcoded to `name` and `semester`, build a reusable parser abstraction that:
1. Reads the **allowed searchable fields** from the entity class itself (via a constant set or annotation)
2. Returns a generic `Map<String, String>` of field → raw value
3. Lets any entity reuse the same parser by simply declaring its searchable attributes

This way, when `Assignment` or `Student` needs structured search later, there is zero parser logic to rewrite — only the spec composition changes.

---

## Abstraction design

### 1. Entity-side contract: a `SEARCHABLE` constant

Each entity declares its own searchable attributes as a `Set<String>` of JPA attribute names. This is the **only** entity-specific piece.

```java
// Constant.java — inside CourseClassAttr
public static final Set<String> SEARCHABLE = Set.of(NAME, SEMESTER);
```

The parser validates field names against this set. Unknown fields are silently ignored (forward-compatible).

### 2. Generic parser: `SearchParser.parse(String, Set<String>)`

A static utility that knows nothing about CourseClass specifically. It takes:
- the raw `search` string
- the entity's `SEARCHABLE` set

And returns a `Map<String, String>` of parsed field → value.

```java
public final class SearchParser {

    private SearchParser() {}

    /**
     * Parses structured search expressions:
     *   "name:PTIT;semester:20261"     → {name=PTIT, semester=20261}
     *   "semester:20261"               → {semester=20261}
     *   "PTIT"                         → {name=PTIT, semester=PTIT}  (bare-value legacy path)
     *   "name:PTIT;unknown:foo"        → {name=PTIT}  (unknown fields silently dropped)
     *
     * @param search       raw query string from the request
     * @param searchable   allowed field names for this entity; unknown keys are ignored
     * @return immutable map of field → value; empty map when search is blank
     */
    public static Map<String, String> parse(String search, Set<String> searchable) {
        if (search == null || search.isBlank()) return Map.of();

        String term = search.trim();
        Map<String, String> result = new LinkedHashMap<>();

        for (String token : term.split(";")) {
            int colon = token.indexOf(':');
            if (colon < 0) {
                // Bare value — legacy behavior: apply to every searchable field
                for (String field : searchable) {
                    result.put(field, token);
                }
                continue;
            }
            String field = token.substring(0, colon).trim().toLowerCase(Locale.ROOT);
            String value = token.substring(colon + 1).trim();
            if (value.isBlank() || !searchable.contains(field)) continue;
            result.put(field, value);
        }
        return Map.copyOf(result);
    }
}
```

**Why this is abstract:**
- No entity-specific types, no generics, no inheritance
- The only coupling is the `SEARCHABLE` set passed in at the call site
- `Assignment` would call `SearchParser.parse(search, AssignmentAttr.SEARCHABLE)` — same method, different set

### 3. Named spec methods per entity (no `qMatches`)

Each entity gets focused `xxxMatches` methods that each apply one field:

```java
public static Specification<CourseClass> nameMatches(String name) {
    if (name == null || name.isBlank()) return (root, q, cb) -> cb.conjunction();
    String escaped = escapeLike(name.trim().toLowerCase(Locale.ROOT));
    String pattern = "%" + escaped + "%";
    return (root, q, cb) -> cb.like(cb.lower(root.get(CourseClassAttr.NAME)), pattern, '\\');
}

public static Specification<CourseClass> semesterMatches(String semester) {
    if (semester == null || semester.isBlank()) return (root, q, cb) -> cb.conjunction();
    String escaped = escapeLike(semester.trim().toLowerCase(Locale.ROOT));
    String pattern = "%" + escaped + "%";
    return (root, q, cb) -> cb.like(cb.lower(root.get(CourseClassAttr.SEMESTER)), pattern, '\\');
}

private static String escapeLike(String term) {
    return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
}
```

`qMatches` is deprecated — it had the dual responsibility of parsing AND matching, which is now split.

### 4. Repository composes generically from the parsed map

`findMine` iterates the parsed map and composes specs dynamically. This is the reusable composition pattern:

```java
default Page<CourseClass> findMine(UUID ownerId, String q, ClassStatus status, Pageable pageable) {
    Map<String, String> filters = SearchParser.parse(q, CourseClassAttr.SEARCHABLE);
    Specification<CourseClass> spec = CourseClassSpecifications.ownedBy(ownerId);
    for (Map.Entry<String, String> entry : filters.entrySet()) {
        spec = spec.and(fieldSpec(entry.getKey(), entry.getValue()));
    }
    spec = spec.and(CourseClassSpecifications.statusIs(status));
    return findAll(spec, pageable);
}
```

`fieldSpec` is a private helper that maps field names to spec methods:

```java
private static Specification<CourseClass> fieldSpec(String field, String value) {
    return switch (field) {
        case CourseClassAttr.NAME     -> CourseClassSpecifications.nameMatches(value);
        case CourseClassAttr.SEMESTER -> CourseClassSpecifications.semesterMatches(value);
        default -> (root, q, cb) -> cb.conjunction();
    };
}
```

**Reuse path for Assignment:**
```java
// Assignment repository
default Page<Assignment> findMine(UUID ownerId, String q, Pageable pageable) {
    Map<String, String> filters = SearchParser.parse(q, AssignmentAttr.SEARCHABLE);
    Specification<Assignment> spec = AssignmentSpecifications.ownedBy(ownerId);
    for (Map.Entry<String, String> entry : filters.entrySet()) {
        spec = spec.and(AssignmentSpecifications.fieldSpec(entry.getKey(), entry.getValue()));
    }
    return findAll(spec, pageable);
}
```

Only `AssignmentAttr.SEARCHABLE` and `AssignmentSpecifications.fieldSpec` are Assignment-specific. The parser, the composition loop, and the escape logic are shared.

---

## Tasks

### 1. Add `SEARCHABLE` set to `CourseClassAttr`

**File:** `Constant.java`

Add `public static final Set<String> SEARCHABLE = Set.of(NAME, SEMESTER);` inside `CourseClassAttr`.

Add `import java.util.Set;` and `import java.util.Locale;` if not already present.

### 2. Create `SearchParser` utility

**New file:** `SearchParser.java` in `vn.edu.ptit.web_grading_system.course_service.spec`

Static `parse(String search, Set<String> searchable)` method returning `Map<String, String>`.

Add `import java.util.Locale;`, `import java.util.Map;`, `import java.util.LinkedHashMap;`, `import java.util.Set;`.

### 3. Refactor `CourseClassSpecifications`

**File:** `CourseClassSpecifications.java`

- Remove `qMatches` (or mark `@Deprecated` with Javadoc pointing to `SearchParser` + `nameMatches`/`semesterMatches`)
- Add private `escapeLike(String)` helper
- Add `nameMatches(String)` and `semesterMatches(String)` public methods
- Add review attribution comment above the new methods

### 4. Update `CourseClassRepository.findMine`

**File:** `CourseClassRepository.java`

Replace the current composition with the generic loop over `SearchParser.parse(q, CourseClassAttr.SEARCHABLE)`.

Add a private `fieldSpec(String, String)` helper that maps attribute names to spec methods.

### 5. Add review attribution comments

Per AGENTS.md convention, add inline comments with review date and reference above:
- `SearchParser.parse` — the structured-filter design
- `nameMatches` / `semesterMatches` — the LIKE escaping fix
- `fieldSpec` / composition loop in `findMine` — the generic composition pattern

### 6. Update docs

**File:** `docs/design/usecase-flows.md`

Update UC-01 Step 0 to document the structured `search` format with examples.

---

## Out of scope

- FE changes — keep `ClassesPage`, `useClasses`, `endpoints/classes.ts` as-is for now
- `qMatches` removal — keep `@Deprecated` until confirmed no callers
- Postman collection
- Test coverage (add `CourseClassRepositoryTest` in follow-up)
- No other entity migration yet — the parser is ready for `Assignment`, `Student`, etc. when they need it
