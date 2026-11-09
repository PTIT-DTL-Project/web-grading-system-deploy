# Fix Plan: Update checkFieldEquals Comment

> **Date:** 2026-09-20
> **Version:** v1.3
> **Status:** Pending approval
> **Scope:** Pullfrog nitpick — comment at checkFieldEquals doesn't match helper semantics
> **Related:** docs/design/grading-plan-2026-09-20-v1.2.md, commit 7a31c44

---

## Problem

The comment block at `AssertionEngine.java:186-192` (in `checkFieldEquals`) says:
```
- numeric values → compare as doubles (1.0 == 1)
- everything else → string equality
```
But the helper `fieldEquals` now:
1. Uses `instanceof Number` guard (not "numeric values" broadly)
2. Compares Numbers via `BigDecimal.compareTo()` (not doubles)
3. Uses exact string equality for non-Numbers (not everything else)

Readers of `checkFieldEquals` would get wrong semantics from this comment.

## Fix

**File:** `AssertionEngine.java:189-190`

### Before:
```java
             * - numeric values → compare as doubles (1.0 == 1)
             * - everything else → string equality
```

### After:
```java
             * - Number instances → compare via BigDecimal (1.0 == 1, exact)
             * - non-Number types → exact string equality
```

### No other changes needed.
- The helper's own comment was already updated in v1.2 (7a31c44).
- The `fieldEquals` method code is unchanged.
- No test changes needed.

---

## Execution

```
1. AssertionEngine.java:189-190 — update comment lines
2. Verify comment matches helper semantics
```

Only 2 lines changed.
