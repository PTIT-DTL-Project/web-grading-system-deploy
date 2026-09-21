# Fix Plan: FIELD_EQUALS Numeric Branch Scoping

> **Date:** 2026-09-20
> **Version:** v1.2
> **Status:** Pending approval
> **Scope:** Pullfrog review — scope numeric comparison to Number instances only, use BigDecimal
> **Related:** docs/design/grading-plan-2026-09-20-v1.1.md, commit 26a316f

---

## Problem

`fieldEquals` uses `Double.parseDouble()` on BOTH sides unconditionally. This means string fields that merely look numeric also get compared numerically:

- `"00123"` (String) matches `equals: "123"` → PASS (wrong — string fields should be exact)
- `"1e3"` (String) matches `equals: "1000"` → PASS (wrong)
- `9007199254740992` (long) matches `equals: "9007199254740993"` → PASS (wrong — precision loss in double)

These silently flip grading outcomes on edge data.

## Fix

**File:** `AssertionEngine.java` — replace `fieldEquals()` method body

### Before (current):
```java
private boolean fieldEquals(String expected, Object actual)
{
    if (actual == null)
    {
        return false;
    }
    String actualStr = String.valueOf(actual);
    try
    {
        double expectedNum = Double.parseDouble(expected);
        double actualNum = Double.parseDouble(actualStr);
        return expectedNum == actualNum;
    }
    catch (NumberFormatException e)
    {
        return expected.equals(actualStr);
    }
}
```

### After:
```java
private boolean fieldEquals(String expected, Object actual)
{
    if (actual == null)
    {
        return false;
    }
    if (actual instanceof Number actualNum)
    {
        try
        {
            BigDecimal expectedNum = new BigDecimal(expected);
            return expectedNum.compareTo(new BigDecimal(actualNum.toString())) == 0;
        }
        catch (NumberFormatException e)
        {
            return false;
        }
    }
    return expected.equals(String.valueOf(actual));
}
```

### Key changes:
1. **`instanceof Number` guard** — only JSON numbers (Integer, Long, Double, etc.) enter numeric comparison
2. **BigDecimal** — no precision loss for large integers or scientific notation
3. **String fallback** — non-Number actuals use exact string equality

### Requires import:
Add `import java.math.BigDecimal;` to AssertionEngine.java

---

## Test Updates

### Existing tests (should still pass):
- `fieldEquals_passAndFail`: `{"id":"b1"}` equals `"b1"` → PASS (string, not Number)
- `fieldEquals_withVariable`: `{"id":"b1"}` equals `${bookId}`="b1" → PASS
- `fieldEquals_missingField`: path not found → null → FAIL
- `fieldEquals_nullBody`: body null → FAIL
- `fieldEquals_numericComparison`: `{"score":1.0}` (Number) equals `"1"` → PASS; `{"score":1.5}` equals `"1"` → FAIL

### New tests to add:
| Test | Body | Expected | Result | Why |
|------|------|----------|--------|-----|
| `fieldEquals_stringNumericNoMatch` | `{"id":"00123"}` | `"123"` | FAIL | String "00123" ≠ "123" (exact match) |
| `fieldEquals_largeNumber` | `{"id":9007199254740992}` | `"9007199254740992"` | PASS | BigDecimal handles large ints |
| `fieldEquals_stringNumberExactMatch` | `{"id":"123"}` | `"123"` | PASS | String "123" = "123" (exact) |

---

## Execution Order

```
1. AssertionEngine.java — replace fieldEquals() body, add BigDecimal import
2. AssertionEngineTest.java — add 3 new tests
3. Run all tests (AssertionEngineTest + GradingOrchestratorTest)
4. Update plan doc to v1.2
