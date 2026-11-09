# Plan: FIELD_EQUALS Assertion & autoInjectExtracts Scale-Up

> **Date:** 2026-09-20
> **Version:** v1.0
> **Status:** Pending approval
> **Author:** Plan mode
> **Scope:** Add `FIELD_EQUALS` assertion type + redesign `autoInjectExtracts` for multi-reference variable resolution
> **Related:** `grading-full-flow.md` · `grading-config-reference.md` · `http-test-plan-config.md` · `http-grading-execution-plan.md`

---

## 1. Context & Motivation

### 1.1 Problem 1: No assertion checks a single field value

Hiện tại các assertion chỉ kiểm tra:
- `STATUS` — HTTP status code (không kiểm tra body)
- `CONTAINS` — substring trong body (không so sánh field)
- `JSON_PATH` — sự tồn tại của trường (không so sánh giá trị)
- `BODY_EQUALS` — toàn bộ body bằng nhau (cồng kềnh, dễ hardcode)
- `BODY_STRUCTURE` — cấu trúc (không so sánh giá trị)

**Thiếu:** Assertion kiểm tra **1 field = 1 giá trị** (ví dụ: `$.id` phải bằng `id` đã extract từ bước POST trước).

### 1.2 Problem 2: autoInjectExtracts chỉ tìm bước i-1

`autoInjectExtracts` (GradingOrchestrator.java:330-383) luôn inject extract vào bước **ngay trước đó** (`result.get(i-1)`). Không hỗ trợ scenario nhiều POST tạo nhiều resource khác nhau:

```
Step 1: POST /api/books → {id: "abc1"}
Step 2: POST /api/books → {id: "abc2"}
Step 3: POST /api/books → {id: "abc3"}
Step 4: GET /api/books/${book1Id}   ← cần từ Step 1, KHÔNG phải Step 3
Step 5: GET /api/books/${book2Id}   ← cần từ Step 2, KHÔNG phải Step 3
Step 7: GET list?ids=${book1Id},${book2Id},${book3Id} ← cần cả 3
```

### 1.3 Anti-hardcode yêu cầu

Giảng viên phải dùng `${book1Id}` (biến) thay vì hardcode `"abc1"` (literal) trong assertions. Hệ thống cần đảm bảo pattern này hoạt động đúng.

---

## 2. Item 1: FIELD_EQUALS Assertion

### 2.1 Mô tả

Assertion mới kiểm tra **một trường JSON có giá trị bằng giá trị kỳ vọng**. Giá trị kỳ vọng có thể là literal hoặc biến `${var}` (được substitute trước khi so sánh).

### 2.2 Cấu hình

```json
{ "kind": "FIELD_EQUALS", "path": "$.id", "equals": "${book1Id}" }
```

| Trường | Bắt buộc | Mô tả | Ví dụ |
|--------|----------|--------|-------|
| `kind` | ✅ | Loại assertion | `"FIELD_EQUALS"` |
| `path` | ✅ | JsonPath đến field cần kiểm tra | `"$.id"`, `"$.title"` |
| `equals` | ✅ | Giá trị kỳ vọng (literal hoặc `${var}`) | `"${book1Id}"`, `"ACTIVE"` |

### 2.3 Logic hoạt động

```
1. Đọc giá trị từ response body theo JsonPath (path)
   → responseBody = {"id": "abc1", "title": "Sach A"}
   → JsonPath.read("$.id") → "abc1"

2. Thay biến trong equals
   → "${book1Id}" → VariableContext.substitute() → "abc1"

3. So sánh: actual == expected
   → "abc1" == "abc1" → PASS
```

### 2.4 Khi nào dùng

| Scenario | Assertion | Ví dụ |
|----------|-----------|--------|
| GET by id → verify id đúng | FIELD_EQUALS | `{"kind": "FIELD_EQUALS", "path": "$.id", "equals": "${book1Id}"}` |
| GET by id → verify title | FIELD_EQUALS | `{"kind": "FIELD_EQUALS", "path": "$.title", "equals": "Sach A"}` |
| GET list → verify size | FIELD_EQUALS | `{"kind": "FIELD_EQUALS", "path": "$.total", "equals": "3"}` |
| GET by id → verify field exists AND correct | Kết hợp JSON_PATH + FIELD_EQUALS | `{"kind": "JSON_PATH", "path": "$.id", "exists": true}` + `{"kind": "FIELD_EQUALS", "path": "$.id", "equals": "${book1Id}"}` |

### 2.5 Xử lý edge cases

| Trường hợp | Xử lý |
|------------|--------|
| Response body null | FAIL — "Response body is null" |
| Path không tồn tại trong body | FAIL — "Path $.xxx not found" |
| Giá trị là null | FAIL — "Actual value is null" |
| Expected là `${var}` nhưng var không tồn tại | FAIL — "Variable ${var} not found" |
| Cả actual và expected đều null | FAIL — "Actual value is null" |

### 2.6 Files to modify

| File | Thay đổi | Ghi chú |
|------|----------|---------|
| `Constant.java` | Thêm `FIELD_EQUALS`, `PATH`, `EQUALS` constants | Assertion type + field names |
| `AssertionEngine.java` | Thêm `checkFieldEquals()` method + register in `evaluateHttp()` | ~20 lines |
| `StepConfigValidator.java` (course-service) | Validate FIELD_EQUALS requires `path` + `equals` | ~5 lines |
| `AssertionEngineTest.java` | Test FIELD_EQUALS: pass, fail, null body, missing path, variable substitute | ~100 lines |
| `http-test-plan-config.md` | Document FIELD_EQUALS assertion | ~15 lines |

---

## 3. Item 2: autoInjectExtracts Scale-Up (2-Phase Redesign)

### 3.1 Mô tả

Thiết kế lại `autoInjectExtracts` để tìm **đúng bước nguồn** (không chỉ bước i-1) bằng cách:
1. **Phase 1**: Build variable map từ tất cả extract entries đã có (explicit + auto-injected)
2. **Phase 2**: Duyệt ngược, với mỗi `${var}` cần tìm: nếu đã có nguồn → skip; nếu chưa → tìm bước nguồn thông minh hoặc fallback về i-1

### 3.2 Thuật toán mới

```
PHASE 1: Build variable source map
  varSourceMap = {}
  for i = 0 to size-1:
    for each extract entry in steps[i]:
      varName = extract.name
      if varSourceMap does NOT have varName:
        varSourceMap[varName] = i    // first occurrence = source

PHASE 2: Smart injection (duyệt ngược)
  for i = size-1 down to 1:
    neededVars = collectVarRefs(steps[i])
    for each var in neededVars:
      if varSourceMap has var:
        SKIP (đã extract ở bước đúng)
      else:
        targetStep = findSourceStep(steps, i, var) // tìm bước nguồn
        if targetStep < 0:
          targetStep = i - 1          // fallback (cũ)
        addExtract(steps[targetStep], var)
        varSourceMap[var] = targetStep

findSourceStep(steps, currentIdx, var):
  for j = currentIdx-1 down to 0:
    if steps[j].config contains "${var}":  // bước j truyền biến vào
      return j + 1                       // bước j+1 tạo biến
  return -1
```

### 3.3 Ví dụ chạy

#### Scenario: 3 POST + 3 GET by id + 1 GET list

```
Input steps (config only):
  Step 0: POST /api/books → extract: [{name: book1Id, expression: $.id}]
  Step 1: POST /api/books → extract: [{name: book2Id, expression: $.id}]
  Step 2: POST /api/books → extract: [{name: book3Id, expression: $.id}]
  Step 3: GET /api/books/${book1Id} → no extract
  Step 4: GET /api/books/${book2Id} → no extract
  Step 5: GET /api/books/${book3Id} → no extract
  Step 6: GET /api/books?ids=${book1Id},${book2Id},${book3Id} → no extract

PHASE 1: varSourceMap = {book1Id: 0, book2Id: 1, book3Id: 2}

PHASE 2:
  i=6: vars={book1Id, book2Id, book3Id} → ALL in map → SKIP all ✓
  i=5: vars={book3Id} → in map → SKIP ✓
  i=4: vars={book2Id} → in map → SKIP ✓
  i=3: vars={book1Id} → in map → SKIP ✓ (Step 1 refs → Step 0 extracts)
  i=2: vars={} → SKIP (no refs in step 2 config)
  i=1: vars={} → SKIP

Result: No injects needed (all sources already explicit) ✓
```

#### Fallback scenario: Simple chain (old behavior preserved)

```
Input steps:
  Step 0: POST /api/books → no extract
  Step 1: GET /api/books/${bookId} → no extract

PHASE 1: varSourceMap = {}

PHASE 2:
  i=1: vars={bookId} → NOT in map →
    findSourceStep(steps, 1, "bookId"):
      j=0: steps[0].config = POST /api/books → contains "${bookId}"? NO →
    return -1 → fallback targetStep = 0 (i-1)
  addExtract(steps[0], bookId): extract: [{name: bookId, expression: $.bookId}]
  varSourceMap = {bookId: 0}

Result: Extract injected into Step 0 ✓ (same as old behavior)
```

### 3.4 Anti-harcoding pattern

Khi 3 POST cùng extract `id` từ `$.id`:
```
// SAI — hardcode cùng tên biến → last write wins
Step 0: extract: [{name: id, expression: $.id}]  → "abc1"
Step 1: extract: [{name: id, expression: $.id}]  → "abc2" (overwrite!)
Step 2: extract: [{name: id, expression: $.id}]  → "abc3" (overwrite!)
Step 3: GET /api/books/${id} → luôn lấy "abc3" → FAIL

// ĐÚNG — dùng tên biến RIÊNG BIỆT
Step 0: extract: [{name: book1Id, expression: $.id}]
Step 1: extract: [{name: book2Id, expression: $.id}]
Step 2: extract: [{name: book3Id, expression: $.id}]
Step 3: GET /api/books/${book1Id} → lấy "abc1" → CORRECT ✓
```

### 3.5 Files to modify

| File | Thay đổi | Ghi chú |
|------|----------|---------|
| `GradingOrchestrator.java` | Rewrite `autoInjectExtracts` (lines 330-383) | 2-phase algorithm |
| `GradingOrchestratorTest.java` | 4-5 test mới | Multi-reference, fallback, explicit extracts |
| `http-test-plan-config.md` | Document extract behavior update if needed | — |

### 3.6 Tests mới cho autoInjectExtracts

| Test | Mô tả | Input → Expected |
|------|--------|------------------|
| `findsVariableFromNonAdjacentStep` | 4 steps, step 3 refs `${bookId}` từ step 0 | Extract inject vào step 0, không phải step 2 |
| `multipleVariablesFromDifferentSources` | 7 steps, 3 POST (extract 3 ids) + 4 GET | All refs resolve to correct sources, no injection needed |
| `fallbackToPreviousStep` | 2 steps, POST no extract → GET refs ${bookId} | Extract inject vào step 0 (i-1, old behavior) |
| `explicitExtractNoDuplicate` | Step 0 đã extract sẵn, step 1 refs biến đó | Không inject thêm (map đã có) |
| `alreadyInjectedNoDuplicate` | Kết hợp auto-inject + later ref | Không duplicate extract |

---

## 4. Execution Order

```
Phase A: Document (this file) — DONE
Phase B: FIELD_EQUALS assertion
  B1. Constant.java — add FIELD_EQUALS, PATH, EQUALS constants
  B2. AssertionEngine.java — add checkFieldEquals() + integrate into evaluateHttp()
  B3. StepConfigValidator.java (course-service) — validate FIELD_EQUALS config
  B4. AssertionEngineTest.java — write tests
  B5. http-test-plan-config.md — document FIELD_EQUALS

Phase C: autoInjectExtracts redesign
  C1. GradingOrchestrator.java — rewrite autoInjectExtracts
  C2. GradingOrchestratorTest.java — add new tests
  C3. http-test-plan-config.md — update extract docs if needed

Phase D: Verify
  D1. Run all executor-service tests
  D2. Run all course-service tests
  D3. Full build (mvn compile)
  D4. Update docs/grading-config-reference.md with FIELD_EQUALS
```

---

## 5. Risk & Mitigation

| Risk | Mitigation |
|------|------------|
| `$.{varName}` expression wrong (field ≠ variable name) | Document: user must explicitly add extract for non-standard field names |
| Variable name collisions (multiple POST same `id`) | Document: MUST use unique variable names |
| Breaking change in autoInjectExtracts behavior | Fallback to i-1 preserves old behavior; tests cover both |
| FIELD_EQUALS confused with JSON_PATH | Different semantics: JSON_PATH = exists, FIELD_EQUALS = value equality |

---

## 6. Definition of Done

- [ ] FIELD_EQUALS assertion implemented and tested
- [ ] autoInjectExtracts handles non-adjacent variable references
- [ ] All existing tests still pass (backward compatibility)
- [ ] New tests cover multi-reference scenarios
- [ ] Documentation updated (http-test-plan-config.md, grading-config-reference.md)
- [ ] Code compiles cleanly (mvn compile)
- [ ] Anti-hardcode pattern documented (use `${var}` not literal)
