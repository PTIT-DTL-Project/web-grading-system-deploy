# Plan: Frontend base — Course UI (lecturer + student)

> Date: 2026-09-28 · Living document · FE root: `frontend-src/web-grading-system-fe/`
> Conventions: `.opencode/skills/react-frontend-antd/SKILL.md` · Run book: `frontend-src/web-grading-system-fe/README.md`
> Stack: React 19 + TypeScript + Vite 8 · antd ^6 · axios · react-router ^8 ·
> i18next + react-i18next · `@ant-design/icons` · `@fontsource/roboto` · oxlint

---

## 1. Decisions (agreed 2026-09-28)

| # | Topic | Decision |
|---|---|---|
| D1 | Student has no "my class / my score" API | **Add 3 student endpoints** in `course-service` — they ride the existing `/api/v1/student/**` gateway predicate, so **no api-gateway change** |
| D2 | Identity (`X-User-Id`) | **Dev identity picker** at `/login` (role + UUID) → `localStorage`, axios interceptor sends the header. One module is the swap seam for Keycloak. No backend change. |
| D3 | UI language | **i18n**: `src/locales/vi.json` + `en.json`, antd locale follows. **Every new key added to BOTH files**, enforced by `npm run i18n:check` (wired into `npm run build`) |
| D4 | Phase-1 screen scope | **Lecturer course module only** (class list → class detail: roster, score components, score entry, transcript). Student screens = Phase 5 |
| D5 | Deployment | **Local dev only** (Vite proxy → gateway). Dockerfile / CI / Helm / ArgoCD = backlog |
| D6 | Colors / font | Red + white; red single-sourced in `shared/theme/tokens.ts` (`#C8102E`). Roboto self-hosted via `@fontsource/roboto` |
| D7 | Rules persistence | `.opencode/skills/react-frontend-antd/SKILL.md` + FE `README.md` |

Rejected: mock/MSW student data · FE-only student screens (nothing to render) ·
Keycloak now (blocks the first UI) · Redux/TanStack Query (no need yet).

---

## 2. Backend contract (evidence)

- Gateway routes — `src-services/api-gateway/src/main/resources/application.yaml:9-21`:
  `/api/v1/classes/**`, `/api/v1/assignments/**`, `/api/v1/docker-images/**`,
  `/api/v1/student/**` → course-service · `/api/v1/submissions/**` → submission ·
  `/api/v1/results/**` → result. `/api/v1/internal/**` is **not** routed — the FE must
  never call it.
- The gateway injects **nothing** today (no filter, no CORS) → the **client sends
  `X-User-Id`**.
- Envelope (`course-service/util/FormatRestResponse.java`): `{status, message, data, error}`;
  `Page<T>` → `data = {meta:{page,pageSize,pages,total}, result:[…]}`, **0-based `page`**;
  excluded paths (`/internal/`, `webhook`, `health`, `version`) stay raw.
- `ScoreComponentType = ATTENDANCE | EXERCISE | FINAL_EXAM | ASSIGNMENT`;
  **only `EXERCISE` is auto-graded** and rejected by `PUT .../scores` (`ScoreService:126`).

### Phase 2–3 endpoints (all existing)

| Method | Path | Used by |
|---|---|---|
| GET | `/api/v1/classes?page&size` | Class list (paged) |
| POST | `/api/v1/classes` `{name, semester}` | Create class → 201 |
| GET | `/api/v1/classes/{id}` | Class header |
| PUT | `/api/v1/classes/{id}/archive` | Archive (idempotent) |
| GET | `/api/v1/classes/{id}/students?page&size` | Roster |
| POST | `/api/v1/classes/{id}/students/import` (multipart `file`) | CSV import → `{imported, skipped}` |
| GET/PUT | `/api/v1/classes/{id}/score-components` | Score components |
| GET/PUT | `/api/v1/classes/{id}/students/{code}/scores` | Score entry |
| GET | `/api/v1/classes/{id}/transcript` | Class transcript |

Validation to mirror client-side (server stays the source of truth): no duplicate
component type · `FINAL_EXAM` required & weight ≥ 0.40 · Σ = 1.000 (±0.001) · scores 0–10 ·
`EXERCISE` never sent · unknown student → 404.

`total/letterGrade/gpa = null` while any component lacks a score (the EXERCISE chain needs
`class_students.student_user_id` + class assignments + results — `src-services/README.md:202-212`).
The UI must explain the gap, not look broken.

### Phase 4 endpoints (new — D1)

| Method | Path | Response | Guard |
|---|---|---|---|
| GET | `/api/v1/student/classes?page&size` | `Page<ClassResponse>` (enrolled only) | enrollment via `class_students.student_user_id` |
| GET | `/api/v1/student/classes/{id}` | `StudentClassDetailResponse {name, semester, status, createdAt, students:[…]}` (`ownerId` omitted) | 404 if not enrolled |
| GET | `/api/v1/student/classes/{id}/my-scores` | `StudentScoresResponse` for the caller's own `studentCode` | 404 if not enrolled |

---

## 3. Phases

### Phase 1 — Foundation ✅ (2026-09-28)

Proxy + env, red/white Roboto theme, i18n with parity check, axios layer (envelope unwrap +
`ApiError`), identity picker + route guard, router + app shell (Sider/Header/outlet/404),
template cruft removed.

**Verified**

| Check | Result |
|---|---|
| `npm run lint` | 0 warnings / 0 errors |
| `npm run build` (i18n:check + tsc -b + vite build) | exit 0, 32 keys in sync |
| Login renders (vi) | red band `rgb(200,16,46)`, layout bg `rgb(245,246,248)`, full form text |
| Identity → shell | `/` → `/classes`; Sider menu "Lớp học"; header role tag + short UUID; selected menu color = `rgb(200,16,46)` |
| Role → landing route | `STUDENT` → `/student/classes` |
| i18n switch | `wgs.lang=en` → "Automated grading platform / My classes / Student / Page not found" and antd built-ins follow |
| Route guard | identity cleared → `/classes` bounces to `/login` |
| 404 | rendered inside the layout |
| Proxy + header | `GET localhost:5173/api/v1/classes?page=0&size=5` → `x-user-id: 0b2e22e3-…`, `sec-fetch-site: same-origin`, `host: localhost:5173` (no CORS) |

**Not verified (environment):** a live 200 from the gateway — k3s is down
(`kubectl` → connection refused, tunnel → HTTP 530), so the proxy answered **502** and the
error path returned `ApiError{status:502, kind:'http'}`. Re-run the check once the cluster
is up. Screenshots/clicks were unavailable (desktop window not visible); DOM + a11y
snapshot + network headers were used instead.

### Phase 2 — Lecturer: class list (done, verified 2026-09-28)

**Scope:** paged class table, create-class modal, archive action, role guard,
loading/empty/error states, 25 new i18n keys.
**Out:** class detail (Phase 3), student screens (Phase 5), any backend change,
search/status filter.

**Decisions (agreed 2026-09-28)**

| # | Question | Decision |
|---|---|---|
| P2-D1 | `GET /classes` has no `sort` → row order undefined, a created class may not be where you look | **FE-only**: refetch the current page after create, rely on the success message. Server-side `sort` → backlog |
| P2-D2 | Search / status filter | **Backlog** — a client-side filter only matches rows on the loaded page (≤20) and contradicts `meta.total`. Plan a `q` + `status` param alongside Phase 4 |
| P2-D3 | Live verification target | **Local course-service** via `.env.development.local` → `VITE_API_PROXY_TARGET=http://localhost:8081` (still proxied ⇒ still same-origin, so the no-CORS property is what gets tested). k3s/gateway stays the default `:30195` |

**Backend contract (read from source, not recalled)**

| Method | Path | Success body |
|---|---|---|
| GET | `/api/v1/classes?page=0&size=20` | `200` `{status:200, message:"Success", data:{meta,result}}` — GETs carry **no `@ApiMessage`**, so `message` is `"Success"` |
| POST | `/api/v1/classes` `{name, semester}` | `201` `{status:201, message:"Class created", data:{id,ownerId,name,semester,status,createdAt}}` |
| PUT | `/api/v1/classes/{id}/archive` | `200` `{message:"Class archived", data:{…, status:"ARCHIVED"}}` |

Errors (`GlobalExceptionHandler` / `ClassService`):

| Status | `message` | Trigger |
|---|---|---|
| 400 | `Class 'X' already exists in semester Y` | duplicate `owner+name+semester` pre-check (`ClassService:44-48`) |
| 400 | `Validation failed`, `error` = `name: must not be blank; …` | bean validation — the detail lives in `error` |
| 400 | `Invalid UUID string: anonymous` | missing/tampered `X-User-Id` (`IllegalArgumentException` handler) |
| 404 | `Class not found: <uuid>` | unknown **or not owned** — `findOwned()` filters by `ownerId`, so foreign classes are indistinguishable from missing ones |
| 409 | `Resource already exists or violates a constraint` | race on `idx_classes_owner_name_sem`, or a value over the column limit |
| 500 | `An unexpected error occurred` | anything unhandled |

DB (`V1__2026-08-16__init_schema.sql`): `name VARCHAR(255)`, **`semester VARCHAR(20)`**,
`status VARCHAR(20)`, unique partial index `(owner_id, name, semester) WHERE deleted_at IS NULL`.
The entity declares no `length` and `ddl-auto: validate` does not check it, so an
over-long `semester` reaches Postgres and comes back as a generic 409 — **the FE rule
`semester ≤ 20` is therefore load-bearing**, not cosmetic.

Behaviour the UI must respect: `listMine` returns ACTIVE **and** ARCHIVED (no filter);
there is **no unarchive endpoint** (archive is one-way, idempotent); no `q`/`status`
params exist.

**Screen (`features/classes/ClassesPage.tsx`)**

| State | Condition | Render |
|---|---|---|
| Error-first | `error && !rows.length` | `ErrorState` (`Result status="error"` + message + **Thử lại**) |
| Loading | `loading` | Table spinner, headers stay (no layout shift) |
| Empty | no rows, no error | `Empty` + hint + primary CTA opening the create modal |
| Content | rows | table |
| Stale-with-error | `error && rows.length` | keep rows + `Alert` above the table with message + retry |

Columns (`rowKey="id"`): `name` (`ellipsis`, 255-char max) · `semester` (w110) · `status`
(`ACTIVE` → `colors.primary` on `colors.primaryLight`, `ARCHIVED` → antd default gray,
**label always carries the text**) · `createdAt` (via `Intl.DateTimeFormat(lang, {dateStyle:'medium', timeStyle:'short'})`,
raw string on parse failure, no `dayjs` dependency) · actions (w170, right): **Mở** →
`/classes/:id`, **Lưu trữ** → `Popconfirm` **only when `status === 'ACTIVE'`**.

Pagination is server-side: `current = meta.page + 1`, `pageSize = meta.pageSize`,
`total = meta.total`, `showSizeChanger: false`, `showTotal` → `classes.total`.

**Create modal:** `name` required/whitespace + `max 255`; `semester` required/whitespace +
`max 20`; no pattern (the backend enforces none). 201 → success message + reset + close +
`reload()`. 400/409 → modal stays open, `message.error(text)` from `useApiErrorMessage`
(the duplicate message is already fully descriptive), antd `App.useApp()` only.

**Archive:** `Popconfirm` (`okButtonProps:{danger:true}`, `okText` = action label) →
`archiveClass(id)` → success message → `reload()`. Button hidden for `ARCHIVED` because the
action is irreversible from the FE; the confirm copy says so.

**Shared-layer changes**

- `useClasses(page, pageSize)` → `{ meta, rows, loading, error, reload }`, with an
  `AbortController` cancelled on re-run/unmount and `CanceledError` swallowed — otherwise a
  slow older response overwrites a newer page (stale rows, wrong `current`).
- `getData`/`sendData`/`listClasses` gain an optional `{ signal }`.
- `errors.ts`: replace the marker-string logic with
  `getErrorMessage(error, t)` + a thin `useApiErrorMessage()` wrapper —
  `network` → `errors.network`; `http` → `0`/`≥502` → `errors.network`, `≥500` →
  `errors.server(status)`, `404` → `errors.notFound`, `403` → `errors.forbidden`, else
  `errors.unknown`; `envelope` → server message (English, source of truth) plus
  `: detail` when present (`"Validation failed: name: must not be blank"`).
  Without the status mapping a dead gateway renders axios's raw
  `"Request failed with status code 502"`.

**New role guard:** `shared/auth/RequireRole.tsx` wraps `/classes` + `/classes/:classId`
(`LECTURER`) and `/student/classes` (`STUDENT`); wrong identity → `<Navigate to="/" />`.
Prevents a student typing `/classes` and meeting a bare 404.

**i18n — 25 new keys, both files**

`classes.title · create · createTitle · name · namePlaceholder · nameRequired · nameMax ·
semester · semesterPlaceholder · semesterRequired · semesterMax · status · statusActive ·
statusArchived · createdAt · open · archive · confirmArchive · archived · created ·
loadFailed · empty · emptyHint · total` + `errors.server`.
Reused: `common.actions · cancel · confirm · empty · retry`.

| Key | vi | en |
|---|---|---|
| `classes.title` | Lớp học | Classes |
| `classes.create` | Tạo lớp học | New class |
| `classes.createTitle` | Tạo lớp học mới | Create a new class |
| `classes.name` | Tên lớp | Class name |
| `classes.namePlaceholder` | vd: PTIT CNTT-K68 | e.g. PTIT CNTT-K68 |
| `classes.nameRequired` | Vui lòng nhập tên lớp | Please enter a class name |
| `classes.nameMax` | Tên lớp tối đa 255 ký tự | Class name is at most 255 characters |
| `classes.semester` | Học kỳ | Semester |
| `classes.semesterPlaceholder` | vd: 20261 | e.g. 20261 |
| `classes.semesterRequired` | Vui lòng nhập học kỳ | Please enter a semester |
| `classes.semesterMax` | Học kỳ tối đa 20 ký tự | Semester is at most 20 characters |
| `classes.status` | Trạng thái | Status |
| `classes.statusActive` | Đang hoạt động | Active |
| `classes.statusArchived` | Đã lưu trữ | Archived |
| `classes.createdAt` | Ngày tạo | Created at |
| `classes.open` | Mở | Open |
| `classes.archive` | Lưu trữ | Archive |
| `classes.confirmArchive` | Lưu trữ lớp này? Không thể hoàn tác từ giao diện. | Archive this class? This cannot be undone from the UI. |
| `classes.archived` | Đã lưu trữ lớp học | Class archived |
| `classes.created` | Đã tạo lớp học | Class created |
| `classes.loadFailed` | Không tải được danh sách lớp học | Could not load your classes |
| `classes.empty` | Chưa có lớp học nào | No classes yet |
| `classes.emptyHint` | Tạo lớp học đầu tiên để bắt đầu | Create your first class to get started |
| `classes.total` | Tổng cộng {{total}} lớp | {{total}} classes in total |
| `errors.server` | Máy chủ trả về lỗi ({{status}}) | The server returned an error ({{status}}) |

**Execution order**

1. `errors.ts` rewrite + `errors.server` key
2. `AbortSignal` through `http.ts` → `endpoints/classes.ts`
3. `RequireRole` + `app/router.tsx`
4. `features/classes/useClasses.ts`
5. `shared/ui/ErrorState.tsx` + `shared/format/formatDateTime.ts`
6. `ClassesPage`
7. `CreateClassModal`
8. Archive `Popconfirm`
9. 25 i18n keys in both files
10. Docs: this file + skill

Steps 1–3 are shared-layer and independent of the UI; 6 depends on 4–5.

**Verification prerequisites** (`course-service/src/main/resources/application.yaml`) —
these three endpoints touch only course-service + Postgres (no Feign):

1. Postgres on `localhost:5432`, database `assignment_db`, `postgres`/`postgres`
2. `mvn spring-boot:run` in `src-services/course-service` (port 8081, Flyway `V1`–`V4`);
   pre-check `curl -s localhost:8081/actuator/health`
3. `.env.development.local` → `VITE_API_PROXY_TARGET=http://localhost:8081`

**Definition of done**

1. `npm run lint` → 0/0 · `npm run build` (i18n:check + `tsc -b` + vite) → exit 0
2. Backend down: student bounces off `/classes`; empty state + CTA; validation in vi then
   en; 502 → *"Không thể kết nối máy chủ"* + working retry; failed create keeps the modal open
3. Backend up: network evidence for `GET …/classes?page=0&size=20` (same-origin +
   `x-user-id`), `POST` → 201 → refetch, duplicate → 400 message, `PUT …/archive` → tag
   flips + action disappears, pagination `current = meta.page + 1` across pages

**Backlog (Phase 6):** server-side `sort`, `q`, `status`; Phase 3 must gate score editing on
`ARCHIVED` (the backend does not).

**Verification (2026-09-28, local course-service `:8081` + Docker `wgs-pg`, not the gateway)**

| Check | Evidence |
|---|---|
| lint / build | `oxlint` **0 warnings / 0 errors**; `npm run build` exit **0**, `i18n:check OK — 57 keys in sync` |
| list + same-origin + identity | `GET localhost:5173/api/v1/classes?page=0&size=20` → **200**, `x-user-id: 0b2e22e3-…`, `sec-fetch-site: same-origin`, `host: localhost:5173` (no CORS) |
| empty state | "Chưa có lớp học nào" + hint + CTA, no table |
| client validation (vi → en) | empty submit → "Vui lòng nhập tên lớp" / "Vui lòng nhập học kỳ" then "Please enter a class name" / "Please enter a semester"; modal stays open |
| create 201 | `POST` → 201 → toast "Class created", row `Sep 28, 2026, 10:50 PM`, `Total classes: 1` |
| duplicate 400 | `POST` → **400** (no second row), toast `Class 'PTIT CNTT-K68 TEST' already exists in semester 20261`; isolated re-run: modal still open at **+7 s** with both values retained |
| archive | Popconfirm copy → `PUT` → 200 → tag **Active → Archived**, toast "Class archived", **Lưu trữ** action gone |
| pagination | 22 rows: page 1 = 20 rows (`?page=0&size=20`), page 2 = 2 rows (`?page=1&size=20`), active item `1`/`2`, `current = meta.page + 1` |
| role guard | STUDENT identity → `/classes` → lands on `/student/classes`, and **0** `/api/v1/classes` requests fired (`ClassesPage` never mounts) |
| i18n switch | VI ↔ EN via the real segmented control switches page **and** antd locale: `22:50 28 thg 9, 2026` ↔ `Sep 28, 2026, 10:50 PM` |
| backend down (proxy → dead port, **502**) | `ErrorState`: title "Không tải được danh sách lớp học", subtitle "Không thể kết nối máy chủ. Vui lòng kiểm tra API gateway.", **Thử lại** re-fires the request (network count 1 → 2) |
| backend down (Postgres stopped → axios `timeout: 30_000`) | request `state: failed, durationMs: 30002` → same `errors.network` UI; after `docker start wgs-pg`, **Thử lại** → 200 → 20 rows rendered |
| identity validation | `userId: 'anonymous'` in `localStorage` → `getIdentity()` returns `null` → bounced to `/login`. The backend's `Invalid UUID string` 400 is **unreachable from the FE** |

Two adjustments made while verifying (behavior unchanged from the spec):
`classes.total` reads `Tổng số lớp: {{total}}` / `Total classes: {{total}}` — the draft's
`{{total}} classes in total` rendered "1 classes in total" — and `ErrorState` gained an
optional `title` so `classes.loadFailed` is the headline and the specific reason (backend
text or translated transport failure) is the subtitle.

Test data: 22 rows (21 SQL `SEED class *` + 1 created through the UI) were soft-deleted
afterwards (`deleted_at = now()`, matching the app's `@SQLRestriction`), so
`GET /classes` returns `total: 0` again and the empty state is what a fresh run shows.

**Environment note:** the three endpoints touch only course-service + Postgres, so local
verification runs `VITE_API_PROXY_TARGET=http://localhost:8081` in
`.env.development.local` — still proxied, so the no-CORS property is what gets tested.
One earlier subagent report claimed this file was written correctly while it actually
contained the tunnel hostname (proxy → **530**); always `cat` the file after a delegated task.

### Phase 3 — Lecturer: class detail (`/classes/:classId`, antd `Tabs`) (done, 2026-09-29)

| Tab | Endpoints | UI |
|---|---|---|
| Sinh viên | students list + import | paged table; `Upload` showing `{imported, skipped}`; empty state with hint; removed dead shortcut buttons |
| Thành phần điểm | score-components GET/PUT | local draft + explicit Save; delete-row button; client validation (FINAL_EXAM required, weight ≥ 0.40, Σ = 1.000 ± 0.001); sum display `.toFixed(3)` with green/red tint |
| Bảng điểm | transcript | component columns + `total` + `letterGrade` tag (color-coded A/B/C/D/F) + `gpa`; per-row **Nhập điểm** → `StudentScoreDrawer` |
| (Drawer) | student scores GET/PUT | `ATTENDANCE`/`FINAL_EXAM`/`ASSIGNMENT` 0–10, `EXERCISE` never sent; 404 surfaced from `message` |

Maps 1:1 onto `docs/design/usecase-flows.md` UC-01 steps 1–6.

Class header: back button (`ArrowLeftOutlined`), semester, localized status tag
(`classes.statusActive` / `classes.statusArchived` with `colors.statusActive` /
`colors.statusArchived` tokens). Single archived warning banner under the header;
tabs keep mutations disabled via `archived` prop.

Cross-tab freshness: parent `ClassDetailPage` owns a `refreshToken` counter and
`refreshAll()` callback; tabs receive it as a prop and call `reload()` from their
hooks when it changes, so imports/saves in one tab are visible in the others
without remounting.

List-view abstraction shipped in the same phase: `useList<F>` hook + `ListPage`
render shell + `FilterBar` + `standardPagination`. `ClassesPage` migrated to it.
Filters persist to URL query string via `history.replaceState`.

Class list filter UI: builder-mode `FilterBar` with chips for active rules
(`name: Test ×`, `semester: 2025.1 ×`), an **Add filter** dropdown of available
fields (`Tên lớp`, `Học kỳ`, `Trạng thái`), and **Lọc** / **Xóa lọc** buttons.
Rules serialize into `search=name:Test;semester:2025.1`. Backend parser will be
added later to match this format.

Class list table: client-side column sorting added. Sort applies to current page only
(server-paginated). Default sort on load: `createdAt DESC`.

Verified: `npm run lint` 0/0, `npm run build` exit 0, `i18n:check OK — 135 keys`.

### Phase 4 — Student endpoints (backend, pending)

`StudentClassController` + `StudentClassService`, `CourseClassRepository.findAllByIdIn`,
`ClassStudentRepository.findByClassIdAndStudentUserId`, DTO `StudentClassDetailResponse`;
reuse `ScoreService`'s entry/total/letter/gpa computation behind an **enrollment** guard.
Follows `.opencode/skills/java-spring-boot-backend/SKILL.md`: builder/named factory for
>2-arg construction, `.asString()`, tests for happy + enrollment-404 paths, **Postman
entries with live 200 and 404**, new **UC-14** in `docs/design/usecase-flows.md`.

### Phase 5 — Student course UI (pending)

`/student/classes` → `/student/classes/:classId` (class info + read-only roster +
"Điểm của tôi"). Nav switches by role.

### Phase 6 — Hardening + docs (pending)

Lint/tsc/build/i18n green · loading/empty/error audit · a11y basics · keep the skill and
this plan in sync with what shipped.

### Backlog

Assignment & plan/step authoring · docker-image library · submission upload + result
polling · Dockerfile/CI/Helm/ArgoCD deploy · Keycloak JWT + gateway header injection ·
bundle split (antd ≈930 kB single chunk today).

---

## 4. Risks / notes

- `#C8102E` is a placeholder school red — one-line change in `shared/theme/tokens.ts`.
- `EXERCISE`/`total` stay `null` on a fresh dev DB → the UI must explain, not look broken.
- `frontend-src/` was **untracked** in git when this plan was written — commit the scaffold.
- `GET /api/v1/classes` has no `search` param → class-list filtering is client-side on the
  loaded page only (never invent a query the API ignores).
- Score `PUT` is a full replace per student → the drawer must always load before save.
- Backend messages are English while the UI is i18n'd — they are shown as-is for now;
  revisiting that means localizing the backend, not the FE.
