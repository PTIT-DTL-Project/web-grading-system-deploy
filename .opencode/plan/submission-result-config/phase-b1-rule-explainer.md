# Phase B1 — DETAIL: rule-based explainer, no LLM (after A)

> Parent: `README.md` (master plan). Status: detailed, not started.
> Goal: students read what was asked, what is missing, how to fix — no model.
> Depends on: A-phases for evidence richness (works on today's payloads, gets
> better as A1/A2 land — every input is null-tolerated, see §3).

## 1. Contract point (verified)

`ResultController.getBySubmission` (`result-service/.../controller/
ResultController.java:30-60`): `GET /api/v1/results/{submissionId}` takes
`X-User-Id` (gateway-stamped, fail-closed on blank) and 403s unless **every**
returned row belongs to the caller. The new endpoint copies this exact shape —
no new auth logic, no new gateway route (`Path=/api/v1/results/**` already
forwards).

## 2. Exact changes

### 2.1 `ExplanationBuilder` (new, `result-service/.../chatbot/`, pure static)

Signature: `StudentExplanation explain(List<ResultResponse> results, String locale)`
(`locale`: `"vi"` default, `"en"` — templates in-code both languages, no i18n
files server-side; FE picks by UI language).

Output: `appendix-response-schema.md` (assignmentId/submissionId from rows;
summary counts + `scoreText`; per-step entries; `nextActions` ≤3; disclaimer const).

Mapping table (first match wins, per failed/error step):
| Signal in step row | `whatMissing` template | `howToFix` template |
|---|---|---|
| `failedAssertionKinds` ∋ `status` (+ evidence expected/actual) | "Yêu cầu mã trạng thái {expected}, server trả {actual}" | "Kiểm tra route/method/ID — 404 thường là sai đường dẫn hoặc id không tồn tại" |
| ∋ `json_path` | "Response thiếu trường `{path}`" (path from detail or detail message) | "Trả đúng tên trường, đúng kiểu; so key từng chữ" |
| ∋ `contains` | "Body không chứa đoạn `{text}`" | "Chú ý hoa/thường và khoảng trắng" |
| ∋ `body_equals` | "Đúng key nhưng sai value" | "Diff từng value với đề bài" |
| ∋ `body_structure` | "Thừa/thiếu key so với cấu trúc yêu cầu" | "Căn đúng cấu trúc mẫu, không thêm key lạ" |
| ∋ `field_equals` | "Không khớp biến `{var}` từ bước trước" | "Kiểm tra extract ở bước trước có ra giá trị không" |
| status `SKIPPED` | "Bỏ qua do step required trước đó FAIL" (never blame student) | "Sửa step required trước, nộp lại" |
| status ERROR / timeout message | "Không kết luận đúng/sai — hạ tầng lỗi" | "Kiểm tra app có boot không rồi nộp lại" |
| Fallback (no details — pre-A1/A2 rows) | Generic from `summaryLog`/errorMessage or "chưa có chi tiết — xem body" | "Mở chi tiết chấm để đối chiếu" |

`failedAssertionKinds` source, in order: parsed `assertionDetails` (A2) →
parsed legacy `errorMessage` verdict-join (A1, `"kind: expected X, got Y"`
regex) → empty (template falls back to `whatMissing` from status only).
`whatAsked`: `"<METHOD?> <stepName>"` + expected status when known; never
invents requirements not present in the row.
`evidence`: expected/actual status ints when parseable, else null.
`nextActions`: top-3 distinct `howToFix` shortened ≤200ch.
Hard rules (tested): hints only, never solution code; no raw bodies/secrets
(inputs are already redacted upstream — builder additionally drops any
`actualValue`/`requestBody` content, using only verdicts + statuses);
no other students' data (input is one submission's rows); SKIPPED/ERROR wording
exact per table.

### 2.2 Endpoint (result-service, 1 controller method)

`POST /api/v1/results/{submissionId}/explanations`
(`ExplainController` or method on `ResultController` — decide at execution by
file size; prefer new `chatbot/ExplainController.java` to keep the chatbot
slice greppable):
- Same `X-User-Id` header + same all-rows-belong-to-caller 403 check (copy the
  block, don't refactor the original).
- Body: `{ "locale": "vi" }` optional (default vi).
- Returns the Explanation JSON (validates against schema before return —
  builder constructs it, so validation is an assert, not a filter).
- Empty (ungraded) submission → 200 with zeroed summary + `nextActions:
  ["Chờ chấm xong rồi xem lại"]` (mirrors the `200 []` polling contract,
  never 404).

### 2.3 FE (3 small touches)

1. `shared/api/endpoints/chatbot.ts`: `explainSubmission(submissionId, locale?)`.
2. `features/student/results/ExplainDrawer.tsx`: `FloatButton` (question icon,
   bottom-right on `SubmissionResultPage`) + `Drawer` rendering summary /
   per-step cards (`whatAsked → whatMissing → evidence → howToFix`) /
   `nextActions` / disclaimer footnote. Reuse `ResultScopeBadge`/Tag patterns.
3. i18n keys for drawer chrome only (content arrives translated from BE):
   `result.explain` ("Giải thích kết quả"), `result.explainHint`,
   `result.nextActions` — both locales, parity via build.

## 3. Null-tolerance (works pre/post A1/A2)

Every builder input is optional-chained: no `assertionDetails` → try
`errorMessage` verdict parse → neither → status-only templates. A pre-A1 row
(all evidence null) still yields a well-formed explanation ("xem body", "chờ
chi tiết"). Add a test per degradation level (full / A1-only / bare).

## 4. Tests

- `ExplanationBuilderTest` (pure unit, table-driven): one case per mapping row
  (§2.1) + SKIPPED + ERROR + fallback-bare + EN locale spot-check + schema
  field presence (required keys non-null, `nextActions ≤ 3`, disclaimer const).
- Negative tests: input containing secret-looking body → output contains
  neither the secret nor any body text (builder never reads bodies — assert by
  construction + test).
- Controller test: owner 403 (rows of another student), blank identity 403,
  empty submission 200-zeroed. Mirror `ResultControllerTest` style.
- Existing suites green.

## 5. Verify (manual)

1. Two real submissions (pass + fail on `BODY_STRUCTURE`): 100% of failed
   steps cite the exact cause; drawer opens from the result page; EN+VI both.
2. Output scan: no secret/PII/solution dump in any rendered string.

## 6. Explicitly out of scope (later)

- LLM paraphrase (B3): same endpoint gains `?mode=llm` later; input restricted
  to the Explanation JSON, output schema-validated, fallback to these templates.
- Lecturer agent (B2): separate service/route; shares only the schema shapes.
- Persisting explanations (no table — recomputed, always fresh with latest rows).
