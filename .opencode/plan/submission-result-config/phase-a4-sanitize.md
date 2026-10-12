# Phase A4 — DETAIL: centralized sanitize (complete before A2 ships)

> Parent: `README.md` (master plan). Status: detailed, not started.
> Goal: no secret/PII ever reaches students or the future chatbot — one function,
> applied at every evidence output path, fail-closed.
> Depends on: none (pure addition). A1's "minimal inline redact" is superseded:
> when A1 executes, it calls `EvidenceRedactor` directly instead of inline
> masking (A1 doc §2 amended at that time). A2/B1 must route their new fields
> through it (noted in their docs at execution).

## 1. Precedents (verified, reuse key lists)

- BE: `StudentAssignmentService.sanitizeConfig`
  (`course-service/.../service/StudentAssignmentService.java:136-144`) — drops
  whole `connection/extract/expected` keys from config JSON (Jackson deepCopy).
- FE: `StepEditor.redactSecrets`
  (`frontend-src/.../features/assignments/StepEditor.tsx:551-580`) — recursive
  mask of keys `password|authorization` → `'***'`, payload otherwise untouched.
- A4 unifies both key lists server-side and extends to free-text bodies.

## 2. Exact change (1 new file + call sites, ~80 lines + tests)

New `executor-service/.../service/scoring/EvidenceRedactor.java` (final class,
static methods only, zero dependencies beyond Jackson already on classpath):

```java
// Key substrings masked anywhere in a JSON key path (case-insensitive):
// password, passwd, authorization, secret, token, api_key, apikey,
// access_token, client_secret.
public static String redact(String input)
```

Algorithm (order matters):
1. `null` → `null` (field absent stays absent; fail-closed rule below never
   invents a placeholder for missing data).
2. Try parse as JSON (existing Jackson `ObjectMapper`):
   - Success → recursive walk mirroring the FE `redactSecrets` shape, with an
     **exact** key set (lowercased, camelCase flattened: password, passwd, pwd,
     authorization, secret, token, api_key[variants], access_token[variants],
     client_secret, auth_token[variants], refresh_token, id_token, private_key).
     Substring matching was tried and rejected — it over-masked legit fields
     (`"tokens"`, caught by test). Exotic names fall through to the sweep layer.
   - Jackson 3 notes: iterate a **snapshot** (`new ArrayList<>(properties())`)
     — mutating via `set()` while iterating the live view throws; `fields()`
     no longer exists, use `properties()`.
   - Track a `dirty` flag: if nothing masked, return the **original string
     verbatim** (byte-identical passthrough — no whitespace churn on clean bodies).
     If masked, re-serialize compact.
3. Regex sweep on the raw text (applied to non-JSON input AND to the
   re-serialized output — belt and braces for secrets embedded in strings):
   - `Bearer|Basic <token>` → `$1 ***`.
   - `(?i)(password|passwd|secret|token)\s*[:=]\s*\S+` → `$1=***`.
   - JDBC `(://user:)<pass>(@)` → `$1***$2`, matching up to the LAST `@`
     before a slash so passwords containing `@` stay fully covered
     (a password containing `/` is out of reach — documented limitation).
4. Catch-all: any `Throwable` inside redact → return `"***"` (fail-closed and
   LOUD — a masked-everything field triggers investigation; never fail-open by
   returning the input, never fail-silent by returning null for present data).

Call sites (this phase):
- `GradingOrchestrator.stepItem`: `actualValue = redact(truncated body)`,
  `errorMessage = redact(joined verdicts/original err)`.
- NOT yet: A2's 5 new fields (wired at A2 execution), B1 paraphrase in/out
  (wired at B1 execution) — both recorded as explicit follow-ups, not forgotten.

Deliberately NOT redacted: step names, plan names, assertion kinds, status
codes, durations, scores/weights (operational, non-sensitive).

## 3. Edge cases (explicit decisions)

| Case | Behavior |
|---|---|
| Clean JSON, no secrets | Byte-identical return (dirty flag) — diffs stay reviewable |
| Clean plain text | Unchanged |
| `null` in / `null` out | Missing data never becomes a placeholder |
| Malformed JSON with `password: x` inside | Regex layer still masks |
| Nested arrays/objects, mixed case keys (`PassWord`) | Recursive + case-insensitive |
| Redactor itself throws (OOM除外 — untestable) | `"***"` + error log naming the field (fail-closed) |
| `jdbc:...user:pass@host` in DB error text | Credential part masked, host kept (needed for debug) |
| Unicode bodies | Regexes are ASCII-shape-based; JSON walk is encoding-agnostic — covered by test |

## 4. Tests (new `EvidenceRedactorTest`, pure unit)

1. Nested JSON `{user:{password:"x"}, tokens:["a",{authorization:"b"}]}` →
   masked, structure intact, non-secret values byte-equal.
2. Clean JSON pretty-printed with spaces → returned **byte-identical**.
3. Plain text `"Authorization: Bearer abc.def-ghi"` → `"Authorization: Bearer ***"`.
4. `"connect password: s3cret"` (case variants `PASSWORD=`, `Secret :`) → masked.
5. JDBC `"jdbc:postgresql://app:P@ss@db:5432/x"` → user+host kept, pass masked.
6. `null` → `null`; `""` → `""`; `"not json at all"` unchanged.
7. `Bearer` inside a JSON string value → masked (layer 3 runs post-serialize).
8. Fuzz-ish: 20000-char body with secret at the tail → masked, length sane.

Existing executor suite stays green (216/216 baseline).

## 5. Verify

- Unit tests + full executor suite.
- Manual fixture: submit against a stub asserting password-echo (e.g. an echo
  endpoint returning the `Authorization` header) → stored/displayed evidence
  shows `***`, nothing else altered.

## 6. Explicitly out of scope (other phases own them)

- Wiring A2's new fields and B1's paraphrase path through the redactor
  (recorded above; one line each at execution).
- FE preview masking — already exists (`StepEditor.redactSecrets`); untouched.
- Key rotation / secret storage — infra topic, not this phase.
- PII beyond secrets (student names in logs are legitimate grading context).
