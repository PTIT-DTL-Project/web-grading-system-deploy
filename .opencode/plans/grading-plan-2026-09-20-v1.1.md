# Fix Plan: Pullfrog Review Issues

> **Date:** 2026-09-20
> **Version:** v1.1
> **Status:** Pending approval
> **Scope:** 3 critical issues from Pullfrog PR review on FIELD_EQUALS + autoInjectExtracts
> **Related:** docs/design/grading-plan-2026-09-20-v1.md (v1.0)

---

## 1. autoInjectExtracts: Skip only if source precedes referencing step

### Problem
Phase 1 marks a variable as sourced regardless of step order. If S2 has explicit extract but S1 references it, the map short-circuits injection. S1's `${var}` silently becomes "" (WARN only), failing grading with confusing mismatch.

**Concrete failure:**
```
S0: POST → no extract (creates token in response)
S1: GET /api/books/${token} → needs token (runs before S2)
S2: POST → extract token (for later steps)
```
- Old code: injected extract into S0 → S1 resolves token ✓
- New code: map says `token→2`, `2 < 1` is false → falls to i-1 = S0 → works ✓
- BUT if S2 was BEFORE S1 in order... wait — let me re-examine

Actually the reviewer's scenario is:
```
S0: POST (no extract)
S1: GET /api/books/${token}
S2: POST (explicit extract token)
```
New code at S1 (i=1): `varSourceMap.get("token")` = 2 (S2 has explicit extract). `2 < 1` = false → DON'T skip → inject into S0 ✓

Old code at S1 (i=1): also injects into S0 ✓

So the fix ensures S1 still gets the injection when the explicit producer runs AFTER.

### Fix
**File:** `GradingOrchestrator.java` lines 369-372

**Old:**
```java
if (varSourceMap.containsKey(varName))
{
    continue;
}
```

**New:**
```java
// Only skip if source step actually runs before this step.
// If producer runs AFTER referencing step, inject into adjacent step.
Integer src = varSourceMap.get(varName);
if (src != null && src < i)
{
    continue;
}
```

### Test update
Add test: `autoInjectExtracts_doesNotSkipWhenProducerRunsAfter()`
```
S0: POST (no extract)
S1: GET /api/books/${token}
S2: POST → extract token
→ S0 should GET an extract (not skipped)
```

---

## 2. Stale comment in StepConfigValidator

### Problem
Line 93: `default -> { /* body_structure / body_equals / field_equals carry 'json' of any shape */ }` — field_equals has its own case (requires path + equals), does NOT fall through to default. Comment is misleading.

### Fix
**File:** `StepConfigValidator.java` line 93

**Old:** `default -> { /* body_structure / body_equals / field_equals carry 'json' of any shape */ }`

**New:** `default -> { /* body_structure / body_equals carry 'json' of any shape */ }`

---

## 3. FIELD_EQUALS: Fix null + number comparison

### Problem
`expected.equals(String.valueOf(actual))` has 2 issues:
1. **Missing field passes**: `null` → `"null"` → `equals("null")` → PASS (wrong)
2. **Number formatting leak**: `{"score": 1.0}` → `String.valueOf(1.0)` = `"1.0"` ≠ `"1"` → FAIL (wrong)

### Fix
**File:** `AssertionEngine.java` — modify `checkFieldEquals()`, add `fieldEquals()` helper

**Old:**
```java
boolean passed = expected.equals(String.valueOf(actual));
```

**New:**
```java
boolean passed = fieldEquals(expected, actual);
```

Add helper method:
```java
private boolean fieldEquals(String expected, Object actual)
{
    if (actual == null)
    {
        return false; // Never allow missing field to pass
    }
    String actualStr = String.valueOf(actual);
    try
    {
        double expectedNum = Double.parseDouble(expected);
        double actualNum = Double.parseDouble(actualStr);
        return expectedNum == actualNum; // Numeric comparison
    }
    catch (NumberFormatException e)
    {
        return expected.equals(actualStr); // String fallback
    }
}
```

### Test updates
- `fieldEquals_nullBody` → update to verify missing field FAILS (already does, but verify)
- Add `fieldEquals_numericComparison` — `{"id": 1.0}` with `equals: "1"` → PASS
- Add `fieldEquals_missingFieldExplicitNull` — `{"id": null}` with `equals: "null"` → FAIL

---

## Execution Order

```
1. GradingOrchestrator.java — fix autoInjectExtracts ordering
2. StepConfigValidator.java — fix stale comment
3. AssertionEngine.java — fix FIELD_EQUALS comparison
4. AssertionEngineTest.java — add/update tests
5. GradingOrchestratorTest.java — add ordering test
6. Run all tests
7. Update plan doc version to v1.1
```

---

## Definition of Done

- [ ] All 3 fixes implemented
- [ ] New tests pass
- [ ] All existing tests still pass (backward compatibility)
- [ ] Code compiles cleanly
