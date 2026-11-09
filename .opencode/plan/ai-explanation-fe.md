# Phase F1 — AI explanation in the student result page (FE-only)

> Status: detailed, not started. Touches only `frontend-src/web-grading-system-fe`
> plus `docs/design/usecase-flows.md` (UC-18 flow update).
> Backend is done and deployed (`ai-assistant-service`, UC-18) — no BE change.

## Goal

A student opens a graded submission and can read the AI explanation of it on the
same page as the grading evidence. The expensive LLM call happens **once, on
explicit request**, and every later view is a cache read.

---

## 1. Research — what the backend actually offers (verified)

Controller: `src-services/ai-assistant-service/.../controller/AiExplanationController.java:18-32`
Gateway route: `src-services/api-gateway/src/main/resources/application.yaml:29-32`
(`Path=/api/v1/ai/**` → `AI_ASSISTANT_SERVICE_URI`). Reachable from the FE at
`/api/v1/ai/**` through the Vite proxy — same origin, no CORS (`react-frontend-antd` §3).

| Method | Path | Cost | Body | Cache |
|---|---|---|---|---|
| `GET` | `/api/v1/ai/submissions/{submissionId}/explain` | cheap, DB-only | `200` DTO / `404` empty / `403` non-owner | reads only, never writes |
| `POST` | same | **LLM, ~5-6 s** | `200` DTO (`fromCache=false` first time) / `404` no results / `403` / `502` result-service down | returns cache when present; idempotent (unique index backstop) |

Evidence:
- GET is cache-only, `.map(...).orElseGet(notFound)` —
  `AiExplanationService.java:46-55`, controller `:18-25`.
- POST is idempotent: cached row returned first (`:62-70`); the LLM runs only on a
  miss (`:114`); a post-timeout result-service read maps to `502` (`:79-86`);
  "no results" maps to `404` (`:88-90`).
- **No `ApiResponse` envelope** on this service (raw DTO) — `usecase-flows.md:1102`.
  `http.ts:12-35` passes it through untouched because the keys are not
  `{status,message,data,error}`. So the FE gets the DTO, and a `404` reaches the
  caller as `ApiError{status:404, kind:'http'}`.

Response shape (mirrors `AiExplanationResponse`/`StepAnalysis`/`TelemetryAudit`):
`overallSummary`, `stepAnalyses[]` (per step: `stepName`, `passed`, `category`
`DEBUG_FAIL|OPTIMIZE_PASS`, `diagnosis`, `suspectedLocation`, `actionableHints[]`,
`learningKeywords[]`, `telemetryAudit`), `fromCache`, `createdAt`.

### Mount point (verified)

- Route `student/submissions/:submissionId/results` → `SubmissionResultPage`
  (`app/router.tsx:112`), reached from `MySubmissionsPage` row button
  (`MySubmissionsPage.tsx:75`, enabled only for `DONE`/`FAILED`).
- `SubmissionResultPage` already waits for grading results before rendering the
  real content (`useSubmissionResult`, `isReady = results.length > 0`,
  `useSubmissionResult.ts:87`). That gate is exactly the precondition the AI
  endpoint needs (POST `404`s without result rows), so the AI card mounts only
  when `isReady`.
- TanStack Query v5 **is installed and wired** (`package.json`,
  `app/providers.tsx:10-17,28`) and already used for a read on this page
  (`SubmissionResultPage.tsx:226-231`). So `useQuery` for GET is an existing
  pattern; `useMutation` would be the app's first (no `useMutation` anywhere yet).

---

## 2. The trigger decision — locked: GET on view, POST on click

| Event | Call | Why |
|---|---|---|
| Result page reaches `isReady` (results exist) | `GET` | Cheap, read-only, instant on a cache hit; safe on every mount. |
| Student clicks **Tạo giải thích AI** | `POST` | The only call that costs an LLM round-trip (~5-6 s) and writes a row. |
| After a successful POST | none | `setQueryData` seeds the cache; the next mount's GET is a hit (`fromCache=true`). |
| Re-click | none | POST is idempotent (returns the cached row) — hide the button after success. |

Backed by the AI-UX literature, not preference:

- **Constrained-AI pattern** — generation that is expensive and side-effecting is
  explicitly user-triggered; "explicit triggers help avoid unnecessary computation
  and give users a stronger sense of intent and agency" (web.dev, *Design AI user
  experiences*).
- **Generate-on-demand + cache** — "you cannot call the LLM on every product page
  load… generate on first access, cache the result" (Harper, *Caching AI
  generations*); prefetch is reserved for shared, predictable content via a cron
  job, "not on every request" (Akousa, *LLMs in Production Web Apps*).
- **The frontend shapes spend** — cache idempotent results and block double
  submission (llmbestpractices, *Frontend best practices for AI-first apps*).

The decisive local fact: an explanation is **per-student-per-submission**, so the
"generate on first access" pattern's whole benefit (amortise one generation across
many readers of the same page) does not apply — there is exactly one viewer. Cost
per view equals cost per generation, so eager generation is pure waste. Eager
precompute is also out: every graded submission would trigger a paid LLM call
whether or not the student ever opens the result.

Latency stays legible because generation is short and non-streaming: the button
carries an antd `loading` state and `ai.generatingHint` states the expected wait,
and `mutation.isPending` disables the button so a double-click cannot fire two
calls. (Streaming is the right call for long output — Redis/Akousa both push it —
but this payload is one JSON DTO, so a single spinner is the polished choice.)

---

## 3. Exact changes

### 3.1 `shared/types/aiExplanation.ts` (new, ~35 lines)

Mirror the DTOs exactly (`verbatimModuleSyntax`, no `enum`):

```ts
export interface TelemetryAudit {
  durationMs: number | null
  expectedThresholdMs: number | null
  nPlusOneDetected: boolean | null
  queryCount: number | null
  sensitiveFieldsExposed: string[] | null
  peakMemoryMb: number | null
}
export interface StepAnalysis {
  stepId: string | null
  stepName: string | null
  stepType: string | null
  passed: boolean | null
  category: 'DEBUG_FAIL' | 'OPTIMIZE_PASS' | null
  diagnosis: string | null
  suspectedLocation: string | null
  actionableHints: string[] | null
  learningKeywords: string[] | null
  telemetryAudit: TelemetryAudit | null
}
export interface AiExplanationResponse {
  id: string
  submissionId: string
  category: string
  fromCache: boolean
  overallSummary: string | null
  stepAnalyses: StepAnalysis[]
  createdAt: string
}
```

### 3.2 `shared/api/endpoints/aiExplanation.ts` (new, ~20 lines)

```ts
// 404 means "not generated yet", not an error: normalise it to null so the card
// renders the CTA instead of the generic errors.notFound text
// (getErrorMessage maps 404 → errors.notFound).
export function getAiExplanation(submissionId, options?): Promise<AiExplanationResponse | null> {
  return getData<AiExplanationResponse>(`/api/v1/ai/submissions/${submissionId}/explain`, undefined, options)
    .catch((err: unknown) => {
      if (isApiError(err) && err.status === 404) return null
      throw err
    })
}
export function generateAiExplanation(submissionId: string): Promise<AiExplanationResponse> {
  return sendData<AiExplanationResponse, undefined>(`/api/v1/ai/submissions/${submissionId}/explain`, 'post')
}
```

`sendData` with `undefined` body is an existing convention (`assignments.ts:39`).

### 3.3 `features/student/results/useAiExplanation.ts` (new, ~30 lines)

```ts
export function useAiExplanation(submissionId: string, enabled: boolean) {
  const queryClient = useQueryClient()
  const query = useQuery({
    queryKey: ['ai-explanation', submissionId],
    queryFn: ({ signal }) => getAiExplanation(submissionId, { signal }),
    enabled: enabled && !!submissionId,
  })
  const mutation = useMutation({
    mutationFn: () => generateAiExplanation(submissionId),
    onSuccess: (data) => queryClient.setQueryData(['ai-explanation', submissionId], data),
  })
  return {
    explanation: query.data ?? null,
    loading: query.isLoading,
    error: query.error,
    generate: mutation.mutateAsync,
    generating: mutation.isPending,
  }
}
```

GET keeps the global `retry: 1` (safe, idempotent). POST uses the mutation default
(`retry: 0`) — a retried LLM call must never be automatic.

### 3.4 `features/student/results/AiExplanationCard.tsx` (new, ~120 lines)

One antd `Card` (`borderColor: colors.border`, matching the sibling plan cards).
State machine, in order:

1. `loading` → `Card` with `Skeleton` (no layout jump).
2. `error` (GET, non-404) → `Alert type="error"` + `useApiErrorMessage(error)` +
   Retry that calls `queryClient.invalidateQueries` for the key.
3. `explanation === null` → title `ai.title`, `ai.notGeneratedHint`, primary
   button `ai.generate`. On click → `generate()`; the button shows antd `loading`
   with `ai.generating` while `generating`; on failure `App.useApp().message.error(toMessage(err))`
   and the CTA stays (retryable).
4. `explanation !== null` →
   - `overallSummary` in a `Typography.Paragraph`.
   - `stepAnalyses` in an antd `List` (or `Collapse`) — per row: `stepName`,
     a pass/fail tag (reuse `result.passed` / the ✓/✗ icons + `colors.success|error`,
     matching `SubmissionResultPage.tsx:309-317`), `diagnosis`,
     `suspectedLocation` (small secondary text), `actionableHints` and
     `learningKeywords` as `Tag` lists. Null arrays → render nothing (never `Map`
     a null array — the same NPE class the BE fixed at `AiExplanationService.java:144-153`).
   - Footnote: `ai.generatedAt` (`formatDateTime(createdAt, i18n.language)`) and
     `ai.fromCache` when `fromCache`.
   - **Do not render `telemetryAudit`** in v1 — those values are the inert
     placeholder telemetry (`expectedThresholdMs`, `peakMemoryMb`, …); showing
     "expected ≤200 ms" to a student would read as a real judgment. Render only
     when the values become real (tracked separately).

No second `ConfigProvider`, tokens only, no `.ant-*` selectors, `App.useApp()`
for toasts — `react-frontend-antd` §6.

### 3.5 `SubmissionResultPage.tsx` (edit, 2 lines)

Import the card and render it once, after the total-score `Row` and before the
`results.map(...)` plan cards (`:371-393`):

```tsx
<AiExplanationCard submissionId={submissionId ?? ''} enabled={isReady} />
```

Nothing else in the page changes; the card owns its own data.

### 3.6 i18n — `locales/vi.json` + `locales/en.json` (both, same order)

New `ai.*` block:

| key | vi | en |
|---|---|---|
| `ai.title` | Giải thích bằng AI | AI explanation |
| `ai.generate` | Tạo giải thích AI | Generate AI explanation |
| `ai.generating` | AI đang phân tích… | AI is analysing… |
| `ai.generatingHint` | Quá trình này mất vài giây và chỉ chạy một lần cho mỗi bài nộp. | This takes a few seconds and runs once per submission. |
| `ai.notGeneratedHint` | Chưa có giải thích cho bài nộp này. | No explanation has been generated for this submission yet. |
| `ai.summary` | Tóm tắt | Summary |
| `ai.stepAnalyses` | Phân tích theo bước | Step-by-step analysis |
| `ai.suspectedLocation` | Vị trí nghi vấn | Suspected location |
| `ai.hints` | Gợi ý khắc phục | How to fix |
| `ai.keywords` | Từ khóa kiến thức | Learning keywords |
| `ai.noSteps` | AI chưa đưa ra phân tích cho từng bước. | The model returned no per-step analysis. |
| `ai.loadFailed` | Không tải được giải thích | Could not load the explanation |
| `ai.generatedAt` | Tạo lúc {{time}} | Generated {{time}} |
| `ai.fromCache` | Đã lưu | Cached |

`npm run i18n:check` enforces parity.

### 3.7 Docs — `docs/design/usecase-flows.md` UC-18 (edit)

Add a short "Client flow" block to UC-18: the FE calls `GET` when the result page
becomes ready and `POST` only on the *Tạo giải thích AI* button; 404 = CTA, 502 =
retryable toast, 403 = forced-change/ownership (mapped by `useApiErrorMessage`).

---

## 4. Out of scope (v1)

- Lecturer-side view (`AssignmentResultsPage`) — students only.
- Streaming / progress for the LLM call — antd `loading` button is enough.
- Regenerate / refresh an existing explanation — POST is idempotent, so there is
  nothing to refresh; a "force regenerate" needs a BE parameter first.
- Prefetching explanations in the submissions list.
- Rendering `telemetryAudit` (placeholder data).
- Any backend change.

---

## 5. Verification

1. `npm run lint` → 0 warnings.
2. `npm run build` → i18n:check + `tsc -b` + vite.
3. Browser matrix (gateway up):
   - fresh submission → card shows the CTA, **no POST** fired on load (network tab).
   - click → button loading ~5-6 s → summary + step analyses render; exactly one POST.
   - reload → card renders immediately, network shows one **GET**, `fromCache: true`.
   - kill the gateway → GET fails → `Alert` with `errors.network` + working Retry.
   - POST while result-service is down (deploy gap) → toast with `errors.network`
     (502 maps to network in `getErrorMessage`), CTA stays.
4. Network evidence: both calls hit `localhost:5173/api/v1/ai/submissions/{id}/explain`
   (same-origin) carrying `x-user-id`.

---

## 6. Files touched

- new `shared/types/aiExplanation.ts`
- new `shared/api/endpoints/aiExplanation.ts`
- new `features/student/results/useAiExplanation.ts`
- new `features/student/results/AiExplanationCard.tsx`
- edit `features/student/results/SubmissionResultPage.tsx` (+2 lines)
- edit `locales/vi.json`, `locales/en.json`
- edit `docs/design/usecase-flows.md` (UC-18 client flow)
- skill note: `react-frontend-antd` §2 says "no state library" but TanStack Query
  v5 is installed and used — correct that section when this lands, and record
  `useMutation` as the mutation pattern.
