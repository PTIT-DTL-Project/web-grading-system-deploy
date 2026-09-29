# Plan: Address Pullfrog review on structured class filter

Review reference: Pullfrog PR review on commit `bbb7545` against `edf1ab7`.

The structured-search behaviour is correct and verified against Hibernate/H2.  
The remaining work is structural cleanup, one validation-order fix, and tests.

---

## 1. Single-source the searchable-field allow-list

**Files:** `Constant.java`, `ClassFilter.java`

- `Constant.CourseClassAttr.SEARCHABLE` is the canonical set.  
- `ClassFilter.SEARCHABLE` currently duplicates it as string literals and is the only set the parser actually consults.  
- Change `ClassFilter.SEARCHABLE` to reference `CourseClassAttr.SEARCHABLE` directly.  
- Update `ClassFilter` Javadoc (`:9-10`) to point at `CourseClassAttr.SEARCHABLE` instead of the now-removed private set.

---

## 2. Make `ClassFilter.parse` delegate to `FilterParser`

**Files:** `ClassFilter.java`, `FilterParser.java`

- `FilterParser.parse(String, Set<String>)` is the verified generic implementation.  
- `ClassFilter.parse` contains a hand-inlined copy of the same algorithm (same 500-char cap, same `MAX_TERMS = 10`, same 200-char value cap, near-verbatim messages). The two already diverge (`missingColon` hardcodes `name, semester`).  
- Replace `ClassFilter.parse`'s body with a single call to `FilterParser.parse(search, CourseClassAttr.SEARCHABLE)`, then extract `name` / `semester` from the returned map and construct the record.  
- Delete the duplicated limit checks, tokenizer loop, and `sorted()` helper from `ClassFilter`.

---

## 3. Fix validation order in the parser

**File:** `FilterParser.java`

- `FilterParser.parse` already checks `searchable.contains(field)` before blank/length in the generic version, so this is fixed by step 2.  
- Verify `ClassFilter.parse` no longer has its own checks that could run in the wrong order.

---

## 4. Fix `FilterSpecifications`

**File:** `FilterSpecifications.java`

- Remove the dead bean-getter fallback (`else` branch `:72-92`, `isGetter`, `fieldNameFromGetter`). The only caller always passes a record; the fallback is unreachable and contains the `getURL()` → `"uRL"` bug.  
- Narrow the `catch (Exception e)` at `:68-70` and `:88-90` to `ReflectiveOperationException` so a `BadRequestException` thrown by a builder propagates as 400 instead of being wrapped in 500.  
- Fix Javadoc (`:36`) — remove the "Reflection is avoided" claim; reflection (`getRecordComponents`, `getAccessor().invoke`) is used.

---

## 5. Clean up dead imports

**Files:** `ClassFilter.java`, `FilterSpecifications.java`, `CourseClassSpecifications.java`

- `ClassFilter.java:3` — remove `import java.util.Locale;` (only used in the now-deleted inline parse body).  
- `FilterSpecifications.java:3-5` — remove `CriteriaBuilder`, `CriteriaQuery`, `Root` imports (unused after the dead bean branch is deleted; lambdas infer all three).  
- `CourseClassSpecifications.java:3-5` — remove the same three unused imports.

---

## 6. Fix Javadoc and comments

**Files:** `ClassFilter.java`, `CourseClassSpecifications.java`

- `ClassFilter.java:7` — the `{@link CourseClass}` link does not resolve (no import, not in `spec.filter`). Replace with plain text `CourseClass` or add the import.  
- `CourseClassSpecifications.java:26-29` — the comment narrates removing `SEARCH_PATTERN_FORMAT` from a file this PR creates from scratch, and sits above methods that never used it. Delete the comment block.

---

## 7. Remove unused `ClassFilter` contract methods

**File:** `ClassFilter.java`

- `hasName()`, `hasSemester()`, `isEmpty()` have zero call sites. `FilterSpecifications.compose` handles null/blank via reflection.  
- Delete all three methods.

---

## 8. Document `;` as reserved in the filter grammar

**File:** `ClassFilter.java` Javadoc (or `FilterParser.java` Javadoc)

- Add a note: `;` is the token separator and has no escape; values containing `;` cannot be searched.  
- This is a deliberate decision, not a bug — class names containing `;` are unlikely, and adding escape syntax would complicate the grammar.

---

## 9. Document the intentional grammar divergence

**Files:** `docs/design/usecase-flows.md`, `AssignmentController` / `AssignmentService` (optional)

- `/api/v1/classes?search=lab` returns 400 (requires `field:value`).  
- `/api/v1/assignments?search=lab` and `/api/v1/student/assignments?search=lab` still accept plain text.  
- This is intentional: structured search on classes fails loudly rather than silently ignoring the param.  
- Add a note in `usecase-flows.md` under UC-01 Step 0 and UC-02 Step 2 stating the two conventions differ and why.  
- If a future listing endpoint is added, it should adopt one convention explicitly.

---

## 10. Add `ClassFilterTest`

**File:** `src/test/.../spec/filter/ClassFilterTest.java`

Plain JUnit 5, no Spring context needed. Mirror the patterns in `DockerImageRepositoryTest`.

Test cases:
- `null` / blank → empty filter (both fields null)
- `name:PTIT` → name set, semester null
- `semester:20261` → semester set, name null
- `name:PTIT;semester:20261` → both set
- Case-insensitive field name: `NAME:PTIT` → name set
- LIKE escaping round-trip: `name:back\slash` → value contains `back\slash`
- LIKE wildcard literal: `name:50%` → value contains `50%`, LIKE pattern escapes it
- Missing colon: `bareword` → `InvalidFilterException`
- Blank value: `name:` → `InvalidFilterException`
- Oversize value (>200 chars) → `InvalidFilterException`
- Oversize total (>500 chars) → `InvalidFilterException`
- Too many tokens (>10) → `InvalidFilterException`
- Unknown field: `badfield:x` → `InvalidFilterException`
- Duplicate field: `name:a;name:b` → `InvalidFilterException`
- Verify error message for unknown field lists allowed fields in sorted order

---

## 11. Verify

- Run `./mvnw test` in `src-services/course-service/` and confirm all existing tests pass plus the new `ClassFilterTest` is green.  
- Run `./mvnw compile` to confirm no unused-import or compilation issues after cleanup.

---

## Out of scope

- Converging the assignments `search` grammar with the classes grammar — that is a separate endpoint-design decision.  
- Frontend changes — frontend lives outside this repo.  
- Adding a second searchable entity — the generic `FilterParser` is kept so this is possible later without further parser work.

---

## Remaining Pullfrog review items (round 2)

These are small, mostly one-line fixes. None change filter behaviour.

### 1. Parameterise `missingColon` in FilterParser

**File:** `spec/filter/FilterParser.java`

- `missingColon(String)` at line 84-87 hardcodes `"Allowed fields: name, semester"` inside a class whose Javadoc promises it is reusable across entities.  
- Change signature to `missingColon(String token, Set<String> searchable)` and build the message from `sorted(searchable)` like `unknownField` does at line 89-92.  
- Update the single call site at line 59 to pass `searchable`.

### 2. Use `CourseClassAttr` constants in ClassFilter lookups

**File:** `spec/filter/ClassFilter.java`

- Lines 44-45: `map.getOrDefault("name", null)` and `map.getOrDefault("semester", null)` spell field names as bare literals.  
- Replace with `CourseClassAttr.NAME` and `CourseClassAttr.SEMESTER`. The file already imports `CourseClassAttr` for `SEARCHABLE` on line 3.  
- This ties the lookup to the same source of truth; a field added to `SEARCHABLE` and the record would currently be silently dropped here.

### 3. Reword FilterSpecifications Javadoc

**File:** `spec/filter/FilterSpecifications.java`

- Line 36: change `"the field to be skipped with an IllegalStateException"` to `"the field causes compose to throw IllegalStateException"`. The code throws; it does not skip.

### 4. Document or enforce record-only contract for non-record filters

**File:** `spec/filter/FilterSpecifications.java`

- Design decision: the class is new and its only caller passes a record. Two options:
  - **A (recommended): throw for non-record filters.** A non-record filter currently falls through `isRecord()` to a bare `conjunction()`, silently ignoring every field — the exact failure mode this commit set out to close. Throwing makes the contract fail loudly.  
  - **B: document record-only in Javadoc.** Smaller change, but a future caller hitting the silent path gets no warning.
- Add `else { throw new IllegalStateException("FilterSpecifications.compose only supports record filters, got " + clazz.getName()); }` after the `isRecord()` block.

### 5. Delete deprecated `qMatches` from CourseClassSpecifications

**File:** `spec/CourseClassSpecifications.java`

- `qMatches` at line 69-95 is `@Deprecated` with zero call sites anywhere in the tree.  
- It inlines its own second copy of the `\%/_` escaping chain that `LikePatterns.escapeContains` owns — same drift the commit just removed on the parsing side.  
- Delete the entire method.

### 6. Add `LikePatternsTest`

**File:** `src/test/.../spec/filter/LikePatternsTest.java`

- Plain JUnit 5, no Spring context needed.  
- Three cases pinning the three transformations:
  - `"back\\slash"` → `"%back\\slash%"`
  - `"50%"` → `"%50\\%%"`
  - `"a_b"` → `"%a\\_b%"`
- These are the transformations an earlier iteration got wrong while looking fixed, and they are still untested.

### 7. ClassFilterTest polish

**File:** `src/test/.../spec/filter/ClassFilterTest.java`

- Line 6: remove unused `import java.util.Arrays;`.
- Lines 24, 27, 42: replace `assertEquals(null, f.semester())` and `assertEquals(null, f.name())` with `assertNull(f.semester())` / `assertNull(f.name())`.
- Add `import static org.junit.jupiter.api.Assertions.assertNull;`.

### 8. Verify

- Run `./mvnw test -Dtest='!*ApplicationTests'` in `src-services/course-service/`.  
- Run `./mvnw compile` to confirm no unused-import or compilation issues.  
- Expected: 134+ tests, 0 failures, including all 14 `ClassFilterTest` cases plus the new `LikePatternsTest`.

---

## Remaining Pullfrog review items (round 3)

One minor suggestion inline on the new `LikePatternsTest` inputs. No behaviour change.

### 1. Strengthen `LikePatternsTest` inputs

**File:** `src/test/.../spec/filter/LikePatternsTest.java`

Two gaps in the current three-case file:
- Lowercasing is unpinned: all inputs are already lowercase, so removing `toLowerCase` from `LikePatterns.java:32` leaves the file fully green while `search=name:PTIT` silently returns nothing against `lower(name)`.
- `escapeContains_backslashIsEscapedFirst` does not verify that the backslash is escaped *first*: its input holds no `%` or `_`, so the three `replace` calls are order-independent for it.

Fix both with one mixed input change plus one new case:
- Change the backslash case input from `"back\\slash"` to `"back\\slash%off"`, expected `"%back\\\\slash\\%off%"`. This input contains both a backslash and `%`, so the two orders produce different strings: correct order gives `%back\\slash\%off%`, backslash-pass-last gives `%back\\slash\\%off%`.
- Add one mixed-case case: input `"PTIT"`, expected `"%ptit%"`, so `toLowerCase` is load-bearing to the suite.

The three cases after edit:
- `escapeContains_backslashIsEscapedFirst` → input `"back\\slash%off"`, expected `"%back\\\\slash\\%off%"`
- `escapeContains_percentIsEscaped` → input `"50%"`, expected `"%50\\%%"`
- `escapeContains_underscoreIsEscaped` → input `"a_b"`, expected `"%a\\_b%"`
- `escapeContains_lowercasesInput` → input `"PTIT"`, expected `"%ptit%"`

No source-code changes required for this item; it is test-only.
