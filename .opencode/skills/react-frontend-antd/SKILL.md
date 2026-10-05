---
name: react-frontend-antd
description: Frontend conventions for this project's React + TypeScript + antd + axios app under frontend-src/web-grading-system-fe - use when writing or reviewing FE components, API calls, theming, i18n/translation files, routing, identity (X-User-Id), vite proxy config, keycloak-js init/bootstrap gate, memory-only token rule, or when adding a new screen, translation key, or endpoint consumer. Covers the ApiResponse envelope unwrap, red/white Roboto theme tokens, vi.json/en.json parity, and the FE definition of done.
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
- The whole mapping is one pure function, `getErrorMessage(error, t)`, keyed on
  `ApiError.kind` (the hook is a thin `useTranslation` wrapper):

  | kind | condition | shown |
  |---|---|---|
  | `network` | no response, `status 0`, `≥502`, or axios `timeout: 30_000` | `errors.network` |
  | `http` | `≥500` (below 502) | `errors.server({{status}})` |
  | `http` | `404` / `403` | `errors.notFound` / `errors.forbidden` |
  | `http` | any other 4xx | `errors.unknown` |
  | `envelope` | body matched `{status,message,…}` | server `message` as-is, plus `: detail` when present ("Validation failed: name: must not be blank") |

  Never render a raw caught `error`: without this mapping a dead gateway shows axios's
  "Request failed with status code 502".
- `401` gets **exactly one** refresh-and-retry per request, then signs out and redirects
  to `/login`; a transport failure during the refresh fails the request and **keeps** the
  session (§23.5). `403` is a normal refusal (e.g. "Not owner") and must **not** log the
  user out.

## 5. Identity = Keycloak JWT (`Authorization: Bearer`)

> **Phase 3 (2026-10-03, D7/D8):** the bullets below describe the interim password-grant
> flow. Under Phase 3 the session is **memory-only** (`keycloak-js`, no
> `localStorage['wgs.auth']`) and login is a **redirect** to Keycloak — see **§23** for the
> rules that then apply; storage-related steps here are historical.

- All identity is derived from the Keycloak access JWT stored in
  `localStorage['wgs.auth']` (`{accessToken, refreshToken, expiresAt, userId, email, role}`).
  `http.ts` sends `Authorization: Bearer <token>`; the gateway strips any client-supplied
  `X-User-*` and re-stamps identity from the validated token. `shared/auth/identity.ts`
  reads the session — it is the only seam.
- Role normalization accepts both forms in `realm_access.roles`: `LECTURER` and
  `ROLE_LECTURER` (strip `ROLE_` prefix). A token with no allowed role renders the
  `/no-role` page with a sign-out button — avoids the `RequireRole ↔ HomeRedirect` loop.
- Login form (`LoginPage`) is username + password (Keycloak password grant).
  Errors map to i18n: `invalid_credentials` → `auth.loginError`, network → `auth.networkError`.
- `401` → silent refresh once, then clear session → `/login`. `403` is a normal refusal
  (ownership) and must **not** log the user out.
- `401` on refresh → clear session → `/login`. `AppLayout` shows `session.email`
  (fallback `userId`) + logout which calls `keycloak.logout()`.

### 5.1 Keycloak temporary password → forced change (must_change_password)

> **Phase 3 (D7/D10):** with login being a redirect, Keycloak renders its **own**
> `UPDATE_PASSWORD` page during the flow — the FE 2-field branch described here is then
> dead code (delete only after D10 is confirmed; see plan `.opencode/plan/phase-3-pkce.md`).
> The voluntary header modal is unchanged and still goes through the gateway.

- When a user has `requiredActions: ["UPDATE_PASSWORD"]` (or `credentials.temporary: true`),
  Keycloak password-grant returns
  `{"error":"invalid_grant","error_description":"Account is not fully set up"}`.
  `keycloak.ts` catches this **before** `invalid_grant` and throws `must_change_password`.
- **Since 2026-10-03 the FE does NOT call the Keycloak Admin API at all.**
  `VITE_KEYCLOAK_ADMIN_URI` / `VITE_KEYCLOAK_ADMIN_CLIENT_ID` /
  `VITE_KEYCLOAK_ADMIN_CLIENT_SECRET` are gone — the admin secret lives only in the
  K8s Secret `keycloak-admin-client`; never reintroduce it in FE env or code.
- Both entry points submit to the **gateway** endpoint (public, no Bearer, never 401):
  `POST /api/v1/account/change-password` via `shared/api/endpoints/account.ts`
  (`{username, currentPassword, newPassword}` → 204; errors are machine codes:
  `current_password_invalid` · `weak_password` · `validation_failed` · `rate_limited`
  (429) · `identity_provider_unavailable` (502)).
  - **Forced change:** `LoginPage` keeps the just-typed login password as
    `currentPassword` (React state only) and shows a 2-field form (new + confirm).
  - **Voluntary change:** header user menu → 3-field `ChangePasswordModal` → on 204 the
    user **stays logged in**.
- Logout is a **full-page end-session redirect** (D12, 2026-10-03): `logout()` in
  `keycloak.ts` calls `keycloak.logout({ redirectUri: <origin>/login })` — Keycloak
  terminates the SSO session and sends the browser back to `/login`. The old
  fire-and-forget XHR revoke is gone (it left the SSO cookie alive → `/login` bounced
  back into the app). Realm must allow it: `post.logout.redirect.uris` on
  `web-grading-fe` (see `keycloak` skill §7 — multi-origin separator is `##`, a
  comma/space-joined value gives 400 "Invalid redirect uri" on every logout). Never
  `clearSession()` first — keycloak-js
  needs `idToken` for `id_token_hint`.
- Realm-side details (flat reset-password body, service-account roles, brute force,
  `Account is not fully set up` semantics) live in the repo **`keycloak` skill** —
  read it instead of duplicating them here (drift risk).

### 5.2 `sub` missing in user tokens → gateway `X-User-Id` empty (client scope `basic`)

- Since Keycloak 24+/26 the **`sub` claim is produced by a protocol mapper inside the
  `basic` client scope**, not hardcoded. A client whose `defaultClientScopes` are only
  `web-origins, roles, profile, email` issues user access tokens **without `sub`** →
  `AuthenticationContextFilter.jwt.getSubject()` returns `null` → `X-User-Id` is stamped
  empty → downstream `HeaderAuthenticationFilter` rejects. `email`/`realm_access` still
  decode fine, so the token itself is valid (misleading).
- Diagnosis (2 independent signals):
  1. Decode the token payload → `sub` absent, claim count 16.
  2. `POST .../token -d "...&scope=basic"` → `invalid_scope: Invalid scopes: basic`
     (scope not assigned to that client).
- Note `client_credentials` (service-account) tokens **still carry `sub`**, so admin/change-password
  flows work — only user (password grant) tokens break. Do not use them to test.
- Fix via Admin API (creds: `admin` / `KEYCLOAK_ADMIN_PASSWORD` from repo `.env`):
  ```
  BID=$(GET /admin/realms/ptit-wgs/client-scopes  → id of "basic")
  CID=$(GET /admin/realms/ptit-wgs/clients?clientId=web-grading-fe → id)
  PUT /admin/realms/ptit-wgs/clients/$CID/default-client-scopes/$BID   # expect 204
  ```
  Verify: fresh password-grant token has `sub` = user UUID.
- Clients that needed it: `web-grading-fe`, `wgs-postman`, `wgs-user-service` (all three
  had the 4-scope list). `web-grading-fe` is **not** in `ptit-wgs-realm.json`, so it is created
  by hand — the JSON now carries `"basic"` in each client's `defaultClientScopes`; re-importing
  the old file silently drops it again.
- Tokens issued **before** the fix keep lacking `sub` for their whole lifetime — the user must
  log out/in (or clear `localStorage['wgs.auth']`) to obtain a fresh one.
- If `GET /clients/{id}/client-scopes` returns 404, that endpoint does not exist — use
  `/default-client-scopes` and `/optional-client-scopes`.

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

## 8. Sidebar collapse controls

- **Placement**: a circular chevron button at the bottom‑right edge of the Sider, only the brand header compacts to show a short name (`app.shortName`).
- **Icons**: `LeftOutlined («)` when the sidebar is visible; clicking it slides it to the left (collapsed). `RightOutlined (`›`) when collapsed; clicking expands it to the right.
- **Labels**: `title`/`aria-label` come from i18n keys `nav.collapseSidebar` and `nav.expandSidebar` — added in both `vi.json` and `en.json`.
- **Brand behavior**: on collapse (`collapsed={true}`), the brand shows `t('app.shortName')` (`WGS`) only and hides the tagline, preserving the 72px header height.
- **Implementation**: uses the existing `sidebarCollapsed` state in `AppLayout.tsx`; the old top‑right toggle has been removed (it used wrong icons and invisible color).
- **Sticky**: the button is `position: sticky; bottom: 16px` so it stays visible without scrolling (UX review 2026-09-29).
- **Sizing**: touch target 36×36px, icon 20px `fontSize`, subtle `boxShadow` — keep tap targets ≥36px and icons ≥20px (UX review 2026-09-29).
- **Utilities**: the chevron button uses only `antd` icons — do not import from other libraries.

## 9. i18n — both files, always

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
    auth/     keycloak.ts · identity.ts · RequireIdentity.tsx · RequireRole.tsx · NoRolePage.tsx
    theme/    tokens.ts
    layout/   AppLayout.tsx
    types/    envelope.ts · pagination.ts · <domain>.ts
    ui/       ComingSoon.tsx · ErrorState.tsx · FilterBar.tsx · ListPage.tsx · StandardPagination.tsx
    hooks/    useList.ts
    format/   formatDateTime.ts
  locales/    vi.json · en.json · i18n.ts
  features/<domain>/   pages + components + hooks (e.g. classes/useClasses.ts)
```

- Feature folders never import from each other — only from `shared/`.
- Types mirror the backend DTOs exactly (`shared/types/*`); do not invent fields.
- Routes: `/login` · `/` → role redirect · `/classes`, `/classes/:classId` (wrapped in
  `RequireRole role="LECTURER"`) · `/student/classes` (`STUDENT`) · `*` → 404 inside the
  layout. A wrong role renders `<Navigate to="/" />`, which `HomeRedirect` resolves to
  that role's landing page — the blocked page never mounts, so it fires **no** request
  (verified: a student hitting `/classes` produced 0 `/api/v1/classes` calls).
- Dates: `shared/format/formatDateTime.ts` uses `Intl.DateTimeFormat(lang, {dateStyle:
  'medium', timeStyle:'short'})` with a raw-string fallback. No `dayjs` — antd bundles its
  own copy for its components, but app code must not add a second date library.

## 11. Generic list-view abstraction (`useList` + `ListPage`)

Every paged + filtered endpoint shares the same shape: `Page<T> = { meta, result }`,
filters, loading/error/empty states, and server-side pagination. Duplicating this per
page leads to drift. Use the shared abstraction instead.

### 11.1 `useList<F>` hook

```tsx
interface ClassesFilters extends ListFilters {
  search: string
  status: string
}

const { rows, meta, loading, error, reload, page, setPage, filters, setFilter, resetFilters } =
  useList<ClassResponse, ClassesFilters>({
    fetcher: (params) => listClasses(params.page, params.size, params.search, params.status),
    filters: { search: '', status: '' },
    pageSize: 20,
  })
```

Key behavior:
- Owns `page`, `filters`, `version` (refresh token), and `AbortController` stale-race guard.
- Text filters are debounced by 300 ms; enum/boolean filters apply immediately.
- Changing any filter resets `page` to `0` and refetches.
- URL persistence: filters are synced to `?search=…&status=…` via `history.replaceState`
  (no full navigation). Read initial values from the URL on mount. Disable with
  `persistFilters: false`.
- External refresh: pass `refreshToken` and bump it from the parent after mutations
  (archive, create, import) to force a refetch without remounting.

### 11.2 `ListPage` component

`ListPage` is the **render-only** shell. It does **not** own mutations (archive, create,
import) — those stay in the page component.

```tsx
<ListPage<ClassResponse, ClassesFilters>
  fetcher={(params) => listClasses(params.page, params.size, params.search, params.status)}
  filters={[
    { key: 'search', type: 'text', label: t('classes.search'), placeholder: t('classes.searchPlaceholder') },
    { key: 'status', type: 'select', label: t('classes.status'), options: [
      { label: t('classes.all'), value: '' },
      { label: t('classes.statusActive'), value: 'ACTIVE' },
      { label: t('classes.statusArchived'), value: 'ARCHIVED' },
    ]},
  ]}
  initialFilters={{ search: '', status: '' }}
  columns={columns}
  pageSize={20}
  rowKey="id"
  headerTitle={t('classes.title')}
  headerActions={<Button ... />}
  emptyTitle={t('classes.empty')}
  emptyHint={t('classes.emptyHint')}
  showTotal={(total) => t('classes.total', { total })}
  refreshToken={refreshToken}
/>
```

Render order inside `ListPage`:
1. Header (title + actions)
2. `FilterBar`
3. Error-first state (`ErrorState`) — when `error && rows.length === 0`
4. Empty state — when no rows, no error, not loading
5. Stale-with-error alert — when `error && rows.length > 0`, keep rows + retry
6. `Table` + `standardPagination`

### 11.3 Shared UI primitives

- `FilterBar` — renders a row of `Input.Search` + `Select` from `FilterConfig[]`.
  `type: 'text'` → `Input.Search`; `type: 'select'` → `Select`.
- `standardPagination` — returns antd `Table` `pagination` config with the project's
  standard wiring: `current = page + 1`, `showSizeChanger: false`, `showTotal`.

### 11.4 Type-safe filter schema

Define a filter interface per view that extends `ListFilters`:

```tsx
interface ClassesFilters extends ListFilters {
  search: string
  status: string // 'ACTIVE' | 'ARCHIVED' | ''
}
```

`setFilter` is typed: `setFilter('status', 'ARCHIVED')` compiles; `setFilter('status', 'INVALID')` does not.

### 11.5 When to use `useList` vs per-page hooks

Use `useList` for any endpoint that returns `Page<T>` with filters. Keep a per-page
hook only when the data shape is not paged (e.g. `useTranscript` which does client-side
pagination on an array).

### 11.6 Migrating an existing page

1. Define the `Filters` interface.
2. Replace `useXxx(page, pageSize, ...)` with `useList`.
3. Move columns into the page (they contain mutations and formatters).
4. Replace inline filter UI + table + pagination with `<ListPage ... />`.
5. Pass mutations (archive, create, import) through the page; call `setRefreshToken`
   after success to trigger a refetch.
6. Remove the old `useXxx` hook only after `ListPage` is verified.

### 11.7 Explicit-submit filters (`submitOnEnter`)

When a list view needs user-chosen filter fields with explicit submit (Enter or **Lọc**
button), use `submitOnEnter: true` in `FilterConfig<F>`.

Behavior:
- Text inputs render as `Input` (not `Input.Search`) and update `localFilters` on
  every keystroke, but do NOT trigger a fetch.
- Pressing Enter or clicking **Lọc** calls `submitFilters()`, which copies
  `localFilters` → `submittedFilters` and bumps `submitVersion` → triggers fetch.
- **Xóa lọc** calls `resetFilters()`, which resets both `localFilters` and
  `submittedFilters` to initial values and refetches.
- Select filters bypass submit and apply immediately (changing a dropdown is always
  intentional).
- URL persistence writes `submittedFilters` only, never `localFilters` (URL never
  reflects half-typed text).

`FilterBar` renders **Lọc** / **Xóa lọc** buttons only when at least one field has
`submitOnEnter: true`.

Example (two independent search fields mapped to a single backend `search` param):

```tsx
interface ClassesFilters extends ListFilters {
  nameSearch: string
  semesterSearch: string
  status: string
}

const filters: FilterConfig<ClassesFilters>[] = [
  { key: 'nameSearch', type: 'text', label: t('classes.name'), placeholder: t('classes.namePlaceholder'), submitOnEnter: true },
  { key: 'semesterSearch', type: 'text', label: t('classes.semester'), placeholder: t('classes.semesterPlaceholder'), submitOnEnter: true },
  { key: 'status', type: 'select', label: t('classes.status'), options: [...] },
]

<ListPage<ClassResponse, ClassesFilters>
  fetcher={(params) => {
    const search = params.nameSearch || params.semesterSearch || ''
    return listClasses(params.page, params.size, search, params.status)
  }}
  ...
/>
```

Each text field is independent (different filter key). The `fetcher` decides which
value to send. In this example the first non-empty value becomes the single `search`
param the backend understands.

### 11.7 Builder-mode filters (`type: 'builder'`)

When a list view needs a filter-builder bar (user picks fields from a dropdown,
enters values, and submits as a structured query), use `type: 'builder'` in
`FilterConfig<F>`.

This is the preferred pattern when the backend accepts a single `search` param
with structured content like `name:foo;semester:2025.1`.

Behavior:
- `FilterBar` renders chips for active rules (`name: Test ×`) and an **Add filter**
  dropdown of available fields.
- After picking a field:
  - `text` → `Input` for value entry
  - `select` → `Select` dropdown; selection immediately submits
- Enter in a text field or selecting a value stores the rule as a chip.
- **Lọc** submits all rules; **Xóa lọc** clears all chips.
- URL persistence writes the serialized filter string.

Filter schema:
```tsx
interface FilterRule {
  field: 'name' | 'semester' | 'status'
  value: string
}

interface ClassesFilters extends ListFilters {
  rules: FilterRule[]
}
```

FilterConfig:
```tsx
{
  key: 'rules',
  type: 'builder',
  label: t('classes.filter'),
  fields: [
    { name: 'name', label: t('classes.name'), type: 'text' },
    { name: 'semester', label: t('classes.semester'), type: 'text' },
    {
      name: 'status',
      label: t('classes.status'),
      type: 'select',
      options: [
        { label: t('classes.all'), value: '' },
        { label: t('classes.statusActive'), value: 'ACTIVE' },
        { label: t('classes.statusArchived'), value: 'ARCHIVED' },
      ],
    },
  ]
}
```

Serialization helper:
```tsx
function serializeRules(rules: FilterRule[]): string {
  return rules
    .filter((r) => r.value !== '' && r.value != null)
    .map((r) => `${r.field}:${r.value}`)
    .join(';')
}
```

Fetcher wiring:
```tsx
<ListPage<ClassResponse, ClassesFilters>
  fetcher={(params) => {
    const search = serializeRules(params.rules)
    return listClasses(params.page, params.size, search)
  }}
  filters={filterConfig}
  initialFilters={{ rules: [] }}
  ...
/>
```

## 12. Definition of done (FE)

1. `npm run lint` → 0 warnings / 0 errors.
2. `npm run build` → passes (i18n:check + tsc + vite).
3. The flow is exercised in a browser: screens render, states are covered
   (loading / empty / error), language switch works, role menus are right.
4. Network evidence for any new call: request goes to `localhost:5173/api/...`
   (same-origin) and carries `x-user-id`.
5. Any endpoint added/changed on the backend → update
   `docs/design/usecase-flows.md` in the same task.

Useful verification tricks:

- `browser.network.get({tabID, id})` returns `requestHeaders` — that is how the
  `x-user-id` + `sec-fetch-site: same-origin` evidence is captured.
- `browser.click` raises `UnknownVizError` on this headless desktop, so drive the UI from
  `browser.evaluate`: `el.click()` for buttons, and for React-controlled inputs set the
  value through the native setter then dispatch a bubbling `input` event
  (`Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el, v); el.dispatchEvent(new Event('input',{bubbles:true}))`).
  Wait inside the page script with `await new Promise(r => setTimeout(r, ms))` — Code
  Mode itself has no `setTimeout`.
- Re-read state in a *later* call to judge timing-sensitive behaviour (antd toasts
  auto-dismiss in ~3 s, so a message inspected one tool-call later looks "missing").

## 12. Backend is not always up

`localhost:30195` / the tunnel being down makes the proxy answer **502** — that is a dead
gateway, not an FE bug (the interceptor then yields `ApiError{status:502, kind:'http'}`,
which `getErrorMessage` renders as `errors.network`). Check `kubectl get pods -n
web-grading` before debugging the frontend for a failed call.

For phases that only need one service (class list/detail touch course-service + Postgres,
no Feign), run it locally instead of the cluster:

```bash
docker start wgs-pg 2>/dev/null || docker run -d --name wgs-pg -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:16
docker exec wgs-pg psql -U postgres -c "CREATE DATABASE assignment_db"   # first run only
cd src-services/course-service && nohup ./mvnw -q spring-boot:run > /tmp/course-service.log 2>&1 &
curl -s localhost:8081/actuator/health                                 # wait for {"status":"UP"}
printf 'VITE_API_PROXY_TARGET=http://localhost:8081\n' > frontend-src/web-grading-system-fe/.env.development.local
```

- Vite **restarts itself and reloads open pages** when `.env.development.local` changes —
  edit the file rather than restarting the server by hand.
- Upstream refusing the connection → proxy answers **502** immediately; upstream accepting
  but never answering (e.g. Postgres stopped under a running service) → axios fails at
  `timeout: 30_000`. Both surface as `errors.network` + a Retry that re-fires the request.
- `docker exec wgs-pg psql -U postgres -d assignment_db` is the fastest way to seed or
  clean test rows; soft-delete with `deleted_at = now()` to match `@SQLRestriction`.
- After a delegated task, `cat` any env/config file it claims to have written — a report
  once said `localhost:8081` while the file held a dead tunnel hostname (proxy → 530).

## 13. Server-paged list screens (worked example: `features/classes`)

- One hook per list: `useClasses(page, pageSize)` → `{rows, meta, loading, error, reload}`.
  It owns an `AbortController` per effect run and swallows `isCancel` — without that a
  slow older response overwrites a newer page (stale rows, wrong `current`). Initial `meta`
  must be a defined placeholder so `meta.page + 1` never derefs `undefined`.
- Body order: `error && rows.length === 0` → `ErrorState` (headline + specific reason +
  Retry) · `loading` → `Table` spinner with headers kept · no rows and no error → `Empty`
  + hint + CTA · `error && rows.length > 0` → keep the rows and show an `Alert` with
  Retry · otherwise the table.
- Pagination is server-side: `current = meta.page + 1`, `pageSize = meta.pageSize`,
  `total = meta.total`, `showSizeChanger: false`, `onChange` → `setPage(page - 1)`.
- Mutations: `await create/archive` → success toast via `App.useApp().message` →
  `reload()`. On 4xx the modal **stays open** with typed values intact and the toast
  carries the server message.
- `showTotal` text must be count-agnostic: `{{total}} classes in total` renders "1 classes
  in total". Use `Total classes: {{total}}` / `Tổng số lớp: {{total}}`.

## 14. Local-draft then save (full-array PUT endpoints)

Some backends accept only the full array on a single `PUT` (e.g.
`PUT /api/v1/classes/{id}/score-components`). The FE must never call that endpoint
on every add/edit — batch all local mutations and send once on explicit Save.

Pattern (worked example: `ScoreComponentsTab`):

1. Keep a local `draftRows` state, synced from server `rows` whenever `loading` flips
   to `false` (or whenever `rows` changes from the hook).
2. Add flow: open a `Modal` (Select + InputNumber), on confirm append to `draftRows`
   locally — **no API call**.
3. Inline edit: `onChange` updates `draftRows` only — **no API call**.
4. Save button: calls `save(draftRows)` once. On success the hook replaces its `rows`
   with the server-returned array, which re-syncs `draftRows`.
5. Error toast: use `useApiErrorMessage()` so backend validation messages like
   `"Weights must sum to 1.000"` surface verbatim. Never swallow the error with a
   generic "Could not save" — that hides actionable feedback.

Bottom action bar: place Add + total weight + Save in one padded flex row at the
bottom of the list, matching the row card styling (`background`, `border`,
`borderRadius`, `padding`). Do not leave Save as a floating header button — it
drifts visually from the list it persists.

## 15. i18n nested objects and interpolation

- Locale JSON keys are flat dot-keys, but values can be nested objects (e.g.
  `components.typeLabel` maps `{ ATTENDANCE: "Attendance", … }`).
- Access them with **dynamic dot paths**, not interpolation params:
  ```tsx
  // Correct
  t(`components.typeLabel.${row.type}`)
  // Wrong — passes {type: …} into a value that is an object, not a string template
  t('components.typeLabel', { type: row.type })
  ```
- When a translation value already contains a character (e.g. `"{{weight}}%"`),
  do not append that character again in JSX. `20%%` is a common symptom.

## 16. Row alignment in Space/List layouts

- Every row in a `space-between` row must have the **same number of children**.
  A conditional extra child on one row type (e.g. an inline "auto-graded" label
  only for EXERCISE) shifts columns and breaks alignment.
- For secondary hints that apply to only one variant, use a hover-only `Tooltip`
  wrapping a small `QuestionCircleOutlined` icon, placed inline next to the label.
  The icon's `marginLeft`, `fontSize`, and `color` must not alter the row's baseline.
- `align="center"` (not `baseline`) keeps mixed-size children on one line.
- Bottom bars that mirror a column (total weight, save) must use the same `padding`
  as the row cards so the text lands at the same edge.

## 17. Cross-tab freshness (`refreshToken` pattern)

Tabs inside a `Tabs` component cache their data on first mount. Without an external
trigger, a tab opened once stays stale after another tab mutates shared state
(e.g. CSV import → transcript count doesn't update).

Pattern (worked example: `ClassDetailPage` + tabs):

1. Parent owns a `refreshToken` state (`number`, starts at `0`) and a `refreshAll()`
   callback that increments it and also calls the parent's own `reload()`.
2. Each tab accepts `refreshToken?: number` and `onSaved?: () => void`.
3. Inside each tab hook (`useTranscript`, `useStudents`, `useScoreComponents`),
   add a `useEffect` on `refreshToken` that calls `reload()` when it changes.
4. After any mutation (import, save), call `onSaved?.()` so the parent increments
   the token and all tabs refetch.

This keeps every tab current without unmounting/remounting the `Tabs` component.

## 18. StudentScoreDrawer integration

`StudentScoreDrawer` (in `features/classes/tabs/StudentScoreDrawer.tsx`) is the
single entry point for per-student manual score entry.

- Open it from a transcript row **Nhập điểm** button — never `alert()`.
- Pass `entries={record.entries}` from the current transcript row so the drawer
  knows which component types to render (it filters out `EXERCISE` automatically).
- The drawer loads fresh scores from `GET …/students/{code}/scores` on open, so
  the parent does not need to pre-fetch.
- On save success call `onSave()` (which should trigger `refreshAll()` in the
  parent) then close the drawer.

## 19. Single archived banner

An `ARCHIVED` class is read-only. Render **one** warning banner under the class
header in `ClassDetailPage`, not one per tab. Each tab keeps its mutations
disabled via the `archived` prop but must not render its own banner.

## 20. TS2322: `unknown && ReactNode`

Hooks expose `error: unknown`. The pattern `{error && <Alert …/>}` fails strict
TypeScript because `unknown && ReactNode` evaluates to `unknown`, not `ReactNode`.

Fix: derive a boolean first:
```tsx
const hasError = Boolean(error)
{hasError && <Alert …/>}
```

This applies to every conditional render of `error` in alert/error states.

## 21. Client-side column sorting

Sorting is handled in `ListPage` and operates on the **current page only** (server-paginated context).

`ListPage` sort props:

```tsx
interface ListPageProps<T, F extends ListFilters> {
  // ... existing props ...
  sortField?: keyof T
  sortOrder?: 'ascend' | 'descend'
  onSortChange?: (field: keyof T, order: 'ascend' | 'descend' | null) => void
  columnSorter?: Record<string, (a: T, b: T) => number>
}
```

Behavior:
- `ListPage` owns local `sortField` / `sortOrder` state, initialized from props.
- A `useMemo` produces `sortedRows` from `rows` + current sort state.
- The antd `Table` `onChange` handler updates local sort state, calls `onSortChange`,
  and resets page to `0`.
- `sortedRows` is passed to `Table` instead of `rows`.
- Sort state is NOT persisted in the URL in v1.

Column config in the page component:

```tsx
{
  title: t('classes.name'),
  dataIndex: 'name',
  key: 'name',
  sorter: true,
  sortOrder: sortField === 'name' ? sortOrder : null,
}
```

Rules:
- `actions` column must NOT get `sorter: true`.
- Default comparator handles strings (via `localeCompare`), numbers, and nulls.
- For non-primitive columns (e.g. `status` enum), pass a custom comparator via
  `columnSorter`:

```tsx
const columnSorter = {
  status: (a: ClassResponse, b: ClassResponse) => {
    const order = ['ACTIVE', 'ARCHIVED']
    return order.indexOf(a.status) - order.indexOf(b.status)
  },
}
```

- Initial sort should match the backend default (`createdAt DESC`).
- Because `useList` fetches one page at a time, sorting applies to the currently
  loaded page only (default 20 rows). Full-dataset sorting requires either
  increasing page size or a backend unsorted mode.

## 14. Local-draft then save (full-array PUT endpoints)

Some backends accept only the full array on a single `PUT` (e.g.
`PUT /api/v1/classes/{id}/score-components`). The FE must never call that endpoint
on every add/edit — batch all local mutations and send once on explicit Save.

Pattern (worked example: `ScoreComponentsTab`):

1. Keep a local `draftRows` state, synced from server `rows` whenever `loading` flips
   to `false` (or whenever `rows` changes from the hook).
2. Add flow: open a `Modal` (Select + InputNumber), on confirm append to `draftRows`
   locally — **no API call**.
3. Inline edit: `onChange` updates `draftRows` only — **no API call**.
4. Save button: calls `save(draftRows)` once. On success the hook replaces its `rows`
   with the server-returned array, which re-syncs `draftRows`.
5. Error toast: use `useApiErrorMessage()` so backend validation messages like
   `"Weights must sum to 1.000"` surface verbatim. Never swallow the error with a
   generic "Could not save" — that hides actionable feedback.

Bottom action bar: place Add + total weight + Save in one padded flex row at the
bottom of the list, matching the row card styling (`background`, `border`,
`borderRadius`, `padding`). Do not leave Save as a floating header button — it
drifts visually from the list it persists.

## 15. i18n nested objects and interpolation

- Locale JSON keys are flat dot-keys, but values can be nested objects (e.g.
  `components.typeLabel` maps `{ ATTENDANCE: "Attendance", … }`).
- Access them with **dynamic dot paths**, not interpolation params:
  ```tsx
  // Correct
  t(`components.typeLabel.${row.type}`)
  // Wrong — passes {type: …} into a value that is an object, not a string template
  t('components.typeLabel', { type: row.type })
  ```
- When a translation value already contains a character (e.g. `"{{weight}}%"`),
  do not append that character again in JSX. `20%%` is a common symptom.

## 16. Row alignment in Space/List layouts

- Every row in a `space-between` row must have the **same number of children**.
  A conditional extra child on one row type (e.g. an inline "auto-graded" label
  only for EXERCISE) shifts columns and breaks alignment.
- For secondary hints that apply to only one variant, use a hover-only `Tooltip`
  wrapping a small `QuestionCircleOutlined` icon, placed inline next to the label.
  The icon's `marginLeft`, `fontSize`, and `color` must not alter the row's baseline.
- `align="center"` (not `baseline`) keeps mixed-size children on one line.
- Bottom bars that mirror a column (total weight, save) must use the same `padding`
  as the row cards so the text lands at the same edge.

## 22. Phase 2 hardening: mirror realm password policy + cross-tab refresh lock

`Review: 2026-10-03, Phase 2 hardening (D1–D6).` Plan: `.opencode/plan/keycloak-hardening-phase-2.md`.

### 22.1 Mirror the Keycloak password policy in antd form rules

- Realm `ptit-wgs` policy (decisions D2 + D6) is
  `length(8) and specialChars(1) and upperCase(1) and digits(1) and notUsername`. The antd
  rules in `LoginPage` and `ChangePasswordModal` must mirror it exactly (≥8 chars, ≥1
  uppercase, ≥1 digit, ≥1 special char) so client and realm **cannot drift**: anything the
  form accepts must be accepted by the server too, and vice versa (otherwise the user gets
  a `400 weak_password` they were never warned about).
- `notUsername` cannot be checked client-side (the form does not reliably know the target
  username in every flow) → skip it in FE rules; the realm enforces it server-side.
- New rule messages go into BOTH `locales/vi.json` and `locales/en.json` (i18n parity is
  enforced by `npm run i18n:check` — §9).
- If the realm policy ever changes, update the antd rules **and** both locale files in the
  same task — one source of truth, mirrored, never assumed.

### 22.2 Serialise token refresh across tabs with `navigator.locks` (Web Locks API)

- Once refresh rotation is on (`revokeRefreshToken: true`, `refreshTokenMaxReuse: 0`, one
  refresh token = one use), two tabs refreshing the **same** refresh token concurrently
  means exactly one wins; the loser gets `invalid_grant` +
  "Maximum allowed refresh token reuse exceeded" and is redirected to `/login`. The
  per-tab dedup (`refreshPromise` in `keycloak.ts`, `isRefreshing` in `http.ts`) does not
  span tabs — there is no `storage` listener and no `BroadcastChannel`.
- Fix: wrap the **whole** refresh window — read RT from `localStorage` → POST `/token` →
  persist new tokens — inside `navigator.locks.request('wgs.token.refresh', ...)`, so the
  browser grants one tab at a time across tabs. Locking only the POST is not enough: the
  stale read happens before it.
- **Skip-if-fresh inside the lock was REMOVED (2026-10-04)** — and must not come back:
  after Phase 3's memory-only tokens each tab owns its own keycloak-js token pair, so a
  peer tab's refresh can never make *this* tab's session fresh and there is no shared
  refresh token for a peer to have spent. The branch read only the local session, could
  never fire, and its comment promised a cross-tab dedup that does not exist
  (serialization alone cannot dedupe a spent refresh token). What remains is exactly what
  the lock name says: **serialization**. The lock stays only because D9 retained it until
  Phase 3 is verified end-to-end — do not treat it as a dedup guarantee.
- Fallback: `navigator.locks` missing (non-secure context) → previous per-tab behaviour, no
  regression. TypeScript 6 types `navigator.locks` in `lib.dom` — no cast needed; secure
  context is `localhost` in dev and https in prod.
- No FE test runner exists → verify manually: 2 tabs of the same user, refresh nearly
  simultaneously ×10, no tab may land on `/login`; replay the used refresh token via curl →
  `invalid_grant` (protocol in `docs/guide/PASSWORD-GATEWAY-RUNBOOK.md` §9.6).

## 23. Phase 3: keycloak-js bootstrap gate + memory-only tokens

`Review: 2026-10-03, Phase 3 PKCE plan (D7–D12).` Plan: `.opencode/plan/phase-3-pkce.md`;
runtime checklist `docs/guide/PASSWORD-GATEWAY-RUNBOOK.md` §10.

### 23.1 Bootstrap gate: route guards must NOT run before `keycloak.init()` settles

- `keycloak.init()` is **async**, while `RequireIdentity`/`RequireRole` read
  `getIdentity()` **synchronously** during render. Rendering routes while `init()` is still
  pending means every guarded route sees a null/expired session — **every reload bounces to
  `/login`** even when the SSO session is perfectly valid (plan §2.8). This is the single
  most likely "it logs in but reloads kick me out" cause.
- Pattern: async bootstrap in `main.tsx` / router entry —
  `await keycloak.init({ onLoad: 'check-sso', ... })` → flip a `ready` flag → only then
  mount `<RouterProvider>`; until then render a loading state (antd `Spin`), **never** the
  route tree. Guards stay synchronous and unchanged afterwards.
- **Third-party-cookie fallback (D8):** Keycloak is a different origin, so the
  `check-sso` iframe can be blocked (Chrome phaseout, Safari ITP). Catch `onError` of
  `init()` and re-run with `silentCheckSsoRedirect: false` (full-page redirect) — one flash,
  session survives. Do not "handle" a blocked iframe by persisting tokens (§23.2).
- **Callback loads skip the 3p-cookies probe** (2026-10-04): when the URL already carries
  an OIDC callback (`state` + `code|error`, hash or query — `response_mode=fragment` puts
  it in the hash), `runInit` omits `silentCheckSsoRedirectUri`, so keycloak-js skips its
  3p-cookies probe (~2 tunnel round trips ≈ 0.5 s) before the code exchange; the silent
  path is never used on a callback load. `vite.config.ts` also injects `preconnect` links
  to the Keycloak origin (derived from `VITE_KEYCLOAK_AUTHORITY`) so DNS/TLS overlaps
  bundle parsing.
- Files: `frontend-src/web-grading-system-fe/public/silent-check-sso.html` must exist
  (keycloak-js reads that path by default).

### 23.2 Memory-only tokens — never persist to storage (R4)

- Access + refresh tokens live **only in the `keycloak-js` instance's memory**. Never write
  them to `localStorage`, `sessionStorage`, a cookie, or any custom store — that is exactly
  R4 (XSS steals a session valid ≤ 10 h), which Phase 3 exists to cut.
- Read tokens fresh at call time: `http.ts` uses `keycloak.token` in the interceptor;
  drop `AUTH_KEY` / `persist()` / decode-from-storage — anything that "fixes" a reload
  problem by saving the token **reopens R4**. A reload that loses the session is a §23.1
  gate/`check-sso` problem, not a storage problem.
- Session shape for consumers (`identity.ts`, `RequireRole`, `AppLayout`) is **derived from
  the in-memory token on read**, not restored from storage.
- `localStorage['wgs.auth']` must not exist after login (runbook §10.9 check #4).

### 23.3 Login is a redirect, not a form post (D7/R3)

- `keycloak.login()` → full-page Keycloak login → callback with `?code=` + PKCE. The FE
  never handles the password and never calls the token endpoint with
  `grant_type=password` → `grep -r "grant_type=password" dist/assets/*.js` must return
  nothing (runbook §10.9 check #3).
- Forced password change renders **Keycloak's own `UPDATE_PASSWORD` page** — no FE branch
  (§5.1 note). The voluntary 3-field modal still posts to the gateway endpoint.
- Verify = `npm run build` + `npm run lint` + the 12-item matrix (no FE test runner):
  reload each protected route, 2-tab refresh, logout replay, `/no-role` gate.

### 23.4 `/login` MUST guard an existing session — otherwise infinite redirect

`Review: 2026-10-03, infinite-redirect fix (LoginPage).`

- keycloak-js's callback handling **keeps the path**: `#parseCallback` only strips the
  query/hash (`replaceState`, `keycloak.js` ~:807) and `login()`'s default `redirect_uri`
  is `location.href`. So after a successful sign-in the app is still at `/login`.
- If `LoginPage` auto-fires `login()` on mount, that round-trip hits Keycloak with a live
  SSO session → immediate new code → back to `/login` → **endless ping-pong** (reported
  2026-10-03: "sau khi đăng nhập thành công bị redirect vô hạn").
- Guard is required in **TWO places, same commit**: (1) inside the auto-redirect
  `useEffect` (`if (authenticated) return`) and (2) render-time
  `if (authenticated) return <Navigate to="/" replace />`. Guarding only the render does
  not work — returning `<Navigate>` does not cancel the effect scheduled by that commit,
  so the redirect fires once before navigation.
- Read the session via `getIdentity()` (the identity seam, §5); `AuthGate` has already
  settled `keycloak.init()` before the router mounts, so the synchronous read is reliable.
- Hook order stays unconditional (Rules of Hooks): all hooks first, conditional return last.
- **`/login` renders a spinner while the auto-redirect is in flight** (2026-10-04):
  the card with the login button is the fallback only when
  `redirectToKeycloakLogin()` rejected (blocked navigation / uninitialized
  adapter). keycloak-js's `login()` always calls `window.location.assign` and
  its promise never settles, so the spinner can never hang. A reload of a deep
  link (`/classes/:id`) shows loading, never the card flash.
- A persistent 401 (dead/wrong proxy target) is now **capped**: one refresh-and-retry per
  request, then sign-out → `/login` (§23.5) — check `VITE_API_PROXY_TARGET` first when a
  user reports being bounced to `/login` with a live IdP session.

### 23.5 401 handling: one retry, and only a dead grant may sign out

`Review: 2026-10-04, Pullfrog (Keycloak session PR).`

- **Exactly one refresh-and-retry per logical request.** `http.ts` marks the request
  config (`RetriableConfig._retried`, set before the refresh) and a **second** 401 skips
  the refresh path and signs out → `/login`. Without the cap a 401 the gateway keeps
  answering (audience/issuer mismatch, SSO session killed server-side) loops forever:
  `updateToken(30)` resolves `false` without contacting Keycloak while the token is still
  "fresh", so the retry is byte-identical and the caller's promise never settles.
- **Two refresh outcomes, one branch point.** `refreshOnce()` classifies the failure
  **inside its `catch`, on kc's token state** (`!kc.authenticated || !kc.token ||
  !kc.refreshToken` → `clearSession()` + `REFRESH_DEAD`; otherwise
  `REFRESH_UNREACHABLE`). The classification MUST live in the catch, not after it:
  keycloak-js clears its own tokens **and rejects in the same tick** on a 400
  invalid_grant (`keycloak.js` updateToken catch: `clearToken()` then `p.reject`), and
  `updateToken` never resolves with cleared tokens — so a `buildSession(kc) === null`
  check after `await updateToken()` only ever sees resolve-path failures
  (`token_no_allowed_role`), while the genuinely dead grant (idle tab past the 30 min
  default, SSO ended, admin revoke) gets filed as UNREACHABLE, keeps a tokenless
  session, and never reaches `/login` (Pullfrog caught exactly this inversion,
  2026-10-04). Transport failures (network/5xx) leave kc's tokens intact → session
  kept, request fails, no redirect. Never collapse every `updateToken` rejection into
  a sign-out either: a one-second blip would discard a still-valid refresh token.
- **Waiters adopt the leader's outcome** (the failedQueue no longer swallows failures):
  a rejected refresh rejects every queued request too, otherwise waiters would retry
  with the very token that just 401'd.
- **Attach the token whenever one exists** — including within 30 s of expiry. Skipping it
  made every request in that window go out anonymous, 401, and spend a refresh round-trip.
  Expiry tracking lives in keycloak-js alone; the session carries no `expiresAt`.
- **Logout call sites must NOT clear the session first.** `clearSession()` →
  `keycloak.clearToken()` drops `idToken` → empty `id_token_hint` → Keycloak's
  logout-confirmation screen instead of `/login`. Drop `clearIdentity()` from
  `AppLayout.handleLogout` and `NoRolePage.handleLogout`; the navigation after
  `logout()` wipes the in-memory session (invariant documented on `logout()` itself).
- **Role allow-list governs every branch:** strip the realm `ROLE_` prefix for matching,
  then accept the result only if it equals `LECTURER`/`STUDENT`. Casting an untested
  `ROLE_*` string to `Role` lets `ROLE_ADMIN` through, and `HomeRedirect` treats
  anything that is not `STUDENT` as a lecturer.
- **`AuthGate` failed state:** `token_no_allowed_role` renders a **sign-out** button
  (reload reproduces the identical failure — Retry is a dead end, and the router's
  `/no-role` page is unreachable because no session exists); a `KeycloakConfigError`
  shows the thrown message verbatim (it names the offending `VITE_KEYCLOAK_AUTHORITY`)
  instead of the generic `auth.initFailed`. Both keys are documented in
  `.env.example` — a production build cannot start without
  `VITE_KEYCLOAK_AUTHORITY`.
