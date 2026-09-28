---
name: react-frontend-antd
description: Frontend conventions for this project's React + TypeScript + antd + axios app under frontend-src/web-grading-system-fe - use when writing or reviewing FE components, API calls, theming, i18n/translation files, routing, identity (X-User-Id), vite proxy config, or when adding a new screen, translation key, or endpoint consumer. Covers the ApiResponse envelope unwrap, red/white Roboto theme tokens, vi.json/en.json parity, and the FE definition of done.
---

# React + TypeScript + antd frontend conventions

Applies to the single SPA in `frontend-src/web-grading-system-fe/`.
The plan this skill was built from lives in the repo at
`docs/design/frontend-course-ui-plan.md` (phases, scope, backlog).

## 1. Commands

```bash
cd frontend-src/web-grading-system-fe
npm run dev         # vite dev server on :5173, proxies /api -> gateway
npm run lint        # oxlint (0 warnings expected)
npm run build       # i18n:check && tsc -b && vite build  ← the definition of done
npm run i18n:check  # vi.json / en.json key parity only
```

`npm run build` runs `i18n:check` first on purpose — a translation file that drifted
cannot ship.

## 2. Stack (installed versions — do not reintroduce a second library for these)

| Concern | Choice |
|---|---|
| Build | Vite 8 + `@vitejs/plugin-react`, TypeScript strict-ish template (`tsc -b`) |
| UI | `antd@6` + `@ant-design/icons@6` |
| Routing | `react-router@8` (`createBrowserRouter` from `react-router`, not `react-router-dom`) |
| HTTP | `axios@1` (one instance, `shared/api/http.ts`) |
| i18n | `i18next` + `react-i18next` |
| Font | `@fontsource/roboto` (self-hosted, offline — **never** Google Fonts CDN) |
| Lint | `oxlint` (config `.oxlintrc.json`) |

No state library (Redux/Zustand/TanStack Query), no CSS framework, no ProComponents.
Per-feature `useX` hooks over `shared/api` are enough — add a library only when a real
need appears.

## 3. Talk to the API gateway only

- Paths are absolute and already include the version: `/api/v1/classes`, …
  `http.ts` sets `baseURL: ''` — leave it that way.
- **Never** call a service directly (`:8081`, …) and **never** call
  `/api/v1/internal/**` — the gateway does not route it.
- Dev goes through the Vite proxy (`vite.config.ts`, `/api` → `VITE_API_PROXY_TARGET`,
  default `http://localhost:30195`). This keeps the browser on a **single origin**, so no
  CORS preflight ever happens (the gateway has zero CORS config — a direct
  `baseURL` to another origin would be blocked on the `X-User-Id` header).
  Machine-specific target → `.env.development.local` (gitignored by `*.local`).
- The proxy is dev-only; production must be same-origin too (FE host routes `/api` to the
  gateway). If the FE is ever hosted separately, CORS becomes a gateway change.

## 4. Response envelope — unwrap once, in the interceptor

Every client-facing endpoint answers `{status, message, data?, error?}`
(`FormatRestResponse`); paged bodies are `data = {meta:{page,pageSize,pages,total}, result:[]}`
with a **0-based `page`** (antd `Table.pagination.current` is 1-based → `meta.page + 1`).

- `shared/api/http.ts` unwraps `data` for success and throws `ApiError` for failures.
  Detection = *"every key of the body is one of `status|message|data|error` AND `status`
  is a number"* — this matches `{"status":200,"message":"..."}` (where `data` is dropped
  by `@JsonInclude(NON_NULL)`) without ever mistaking a real DTO for an envelope.
- Screens never touch `res.data`/`res.status`: call the typed functions in
  `shared/api/endpoints/*.ts` and `await` them.
- Errors reach the UI through `useApiErrorMessage()` (from `shared/api/errors.ts`).
  Backend `message` strings are English and are displayed as-is — they are the source of
  truth for validation ("Weights must sum to 1.000"); only transport-level failures are
  translated.
- `401` clears the identity and redirects to `/login`. `403` is a normal refusal
  (e.g. "Not owner") and must **not** log the user out.

## 5. Identity = `X-User-Id` header

- All identity lives in `shared/auth/identity.ts` (`localStorage['wgs.identity']` =
  `{role: 'LECTURER'|'STUDENT', userId}`); `http.ts` injects the header.
  **This module is the only seam** — when Keycloak lands, replace the read there and drop
  the header injection. Do not read `localStorage` anywhere else.
- The UUID is validated in the login form (`isValidUuid`) because the backend runs
  `UUID.fromString` → a bad value becomes a 400 on every request.
- Pre-Keycloak there is no server-side session: gating is `RequireIdentity` +
  role-based menus in `AppLayout`.

## 6. Theme: red + white, tokens only

- `src/shared/theme/tokens.ts` is the **only** file with a hex/rgb. Primary red is
  `#C8102E` (change the school red there, nowhere else).
- One root `ConfigProvider` in `src/app/providers.tsx` (theme tokens + antd `locale` +
  `<AntdApp>`). Never mount a second ConfigProvider.
- Use `App.useApp()` / the `App` context for `message`/`notification`/`Modal.confirm` —
  the static `message.*` helpers bypass the tree and the theme.
- Styling order: theme tokens → component tokens (`token`/`component` props) →
  `classNames`/`styles`. **No global `.ant-*` selectors, no inline hex.**
- `src/index.css` is a reset only; keep it that way.

## 7. antd v6 gotchas (verified against `node_modules`)

- **Locales are NOT exported from the package root.** Use the documented deep path:
  `import viVN from 'antd/locale/vi_VN'` / `import enUS from 'antd/locale/en_US'`.
  `import { viVN } from 'antd'` does not exist in v6.
- Query a component's API before writing against it:
  `npx -y @ant-design/cli info <Component> --format json`
  (and `npx -y @ant-design/cli lint <path> --format json` after). Do not rely on memory
  for props, and do not invent props or reach into `.ant-*` DOM.
- `Table` always gets a stable `rowKey`.
- antd is ~930 kB in the bundle today (single vendor chunk) — known, in the plan backlog;
  do not "fix" it by adding a bundler plugin mid-feature.

## 8. i18n — both files, always

- Resources: `src/locales/vi.json` + `src/locales/en.json`, flat **dot keys**
  (`classes.title`, `common.save`). Init in `src/locales/i18n.ts`
  (`useSuspense: false`, default `vi`, persisted in `localStorage['wgs.lang']`).
- **Every user-visible string goes through `t('...')` and every new key is added to BOTH
  files.** `npm run i18n:check` (in `scripts/i18n-check.mjs`) fails the build on drift.
- No hardcoded Vietnamese or English in TSX. antd's own strings follow the same switch
  via `ConfigProvider locale`.
- Keep the two files byte-for-byte key-identical and in the same key order.

## 9. TypeScript constraints from the template

- `verbatimModuleSyntax: true` → type-only imports must be `import type`.
- `erasableSyntaxOnly: true` → **no `enum`, no `namespace`, no parameter properties**;
  use string literal unions + `const` objects.
- `resolveJsonModule: true` (added for the locale JSON imports).
- `noUnusedLocals`/`noUnusedParameters` are on — unused imports fail `tsc -b`.

## 10. Structure

```
src/
  app/        App.tsx · providers.tsx · router.tsx · HomeRedirect.tsx
  shared/
    api/      http.ts · errors.ts · endpoints/<domain>.ts
    auth/     identity.ts · RequireIdentity.tsx
    theme/    tokens.ts
    layout/   AppLayout.tsx
    types/    envelope.ts · pagination.ts · <domain>.ts
    ui/       ComingSoon.tsx
  locales/    vi.json · en.json · i18n.ts
  features/<domain>/   pages + components + hooks
```

- Feature folders never import from each other — only from `shared/`.
- Types mirror the backend DTOs exactly (`shared/types/*`); do not invent fields.
- Routes: `/login` · `/` → role redirect · `/classes`, `/classes/:classId` (lecturer) ·
  `/student/classes` (student) · `*` → 404 inside the layout.

## 11. Definition of done (FE)

1. `npm run lint` → 0 warnings / 0 errors.
2. `npm run build` → passes (i18n:check + tsc + vite).
3. The flow is exercised in a browser: screens render, states are covered
   (loading / empty / error), language switch works, role menus are right.
4. Network evidence for any new call: request goes to `localhost:5173/api/...`
   (same-origin) and carries `x-user-id`.
5. Any endpoint added/changed on the backend → update
   `docs/design/usecase-flows.md` in the same task.

Useful verification trick: `browser.network.get({tabID, id})` returns `requestHeaders`,
which is how the `x-user-id` + `sec-fetch-site: same-origin` evidence is captured.

## 12. Backend is not always up

`localhost:30195` / the tunnel being down makes the proxy answer **502** — that is a dead
gateway, not an FE bug (the interceptor then yields `ApiError{status:502, kind:'http'}`).
Check `kubectl get pods -n web-grading` before debugging the frontend for a failed call.
