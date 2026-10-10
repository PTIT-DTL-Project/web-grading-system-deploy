# Plan: Step detail views — contract for students, full for lecturers (executed 2026-10-09)

## Goal

Replace one-line step summaries with expandable per-step detail: students see
the request/response contract only; lecturers see the full authored config.

## Key finding during research

The student config keeps `headers` — so a lecturer `Authorization` header
would leak to students. Fixed in this task by client-side masking; filed as
backend follow-up to strip sensitive headers in `sanitizeConfig` too (mirror
the `HttpLogService` sensitive set).

## Design

- `shared/ui/stepDetail.ts` (no JSX, Fast Refresh safe): `StepDetailModel`,
  `normalizeLecturerStep` (`stepType` + JSON-string config),
  `normalizeStudentStep` (`type` + object config), `maskHeaders` (mirrors
  backend `HttpLogService`: authorization, cookie, set-cookie,
  proxy-authorization, x-api-key, x-gateway-secret), `stringPairs`, `isRecord`.
- `shared/ui/StepDetailView.tsx`: prop `variant: 'contract' | 'full'`.
  - Student contract: request line (METHOD + path + expected status), query
    table, headers table (masked values), body JSON, DB query block, schema
    checks in plain words, migration statements. No assertions, no extract,
    no expected values, no connection block, no weight/timeout meta.
  - Lecturer full: everything above unmasked + connection (own creds) +
    expected + extract list + per-kind assertion breakdown + meta row.
  - Unparseable config → header + `step.invalidJson` note, never a crash.
- `PlanCard.tsx` (lecturer): per-row expand/collapse → full variant.
- `StudentAssignmentDetailPage.tsx`: Phase-2 one-liner kept as collapsed
  summary; expand shows the contract card.
- i18n: zero new keys — reused editor/tab keys (`tabParams/tabHeaders`,
  `step.body/httpExpectedStatus/dbQuery/checks/statements/dbConnection/*`,
  `step.assertion*`, `step.extract*`, `step.weight/timeout/required`,
  `common.expand/collapse`). Strategy labels and protocol values stay raw.
- Code-block styling uses `colors.layoutBg`/`colors.border` tokens only.

## Deliberately out of scope

- Showing assertion details or expected values to students (contract decision).
- Server-side header stripping (backend follow-up filed).
- Hooks, endpoints, backend: untouched.

## Verification

- [x] `npm run build` (i18n:check 376 keys + tsc + vite), `npm run lint`
      (only 2 pre-existing warnings).
- [ ] Browser matrix: 4 step types × 2 roles × 2 locales; student sees masked
      auth header + no connection block; lecturer sees own full config;
      unparseable config fallback; expand/collapse.

## Follow-up 2026-10-09 — credential masking beyond headers (Pullfrog)

Backend `sanitizeConfig` returns request `body`/`query_params` verbatim to
students, so a credential-bearing body (e.g. login-test `{"password": ...}`)
would leak. Fixed client-side without touching the lecturer `full` variant:

- `stepDetail.ts`: single `SENSITIVE_KEYS` set (backend-mirrored header names
  + generic credential key names) + recursive `maskSensitiveValues()`.
- `StepDetailView` contract variant masks query values and body at any depth;
  keys stay visible so the contract still reads whole.
- Server-side stripping in `sanitizeConfig` remains filed as backend follow-up
  (UI masking only protects the FE).

## Follow-up 2026-10-09 — roster empty hint voice

`StudentRosterTab` used lecturer-voiced `students.emptyHint` ("Import students
from CSV..."). New key `students.emptyRosterHint` ("No classmates enrolled
yet" / "Chưa có bạn học nào trong lớp"); i18n now 377 keys in sync.
