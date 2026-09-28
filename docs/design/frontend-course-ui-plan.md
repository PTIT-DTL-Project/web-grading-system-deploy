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

### Phase 2 — Lecturer: class list (pending)

`GET /classes` paged `Table` (`rowKey="id"`, `current = meta.page + 1`) · create `Modal` +
`Form` (400 duplicate rendered inline) · `PUT /{id}/archive` behind `Popconfirm` ·
loading / empty / error states everywhere.

### Phase 3 — Lecturer: class detail (`/classes/:classId`, antd `Tabs`) (pending)

| Tab | Endpoints | UI |
|---|---|---|
| Sinh viên | students list + import | paged table; `Upload` (`showUploadList:false`, `beforeUpload → false`, then `FormData{file}`) showing `{imported, skipped}`; template download from `public/samples/students-import.csv` |
| Thành phần điểm | score-components GET/PUT | dynamic rows (type `Select` + weight `InputNumber`), client validation per §2, `EXERCISE` read-only ("tự động chấm") |
| Bảng điểm | transcript | component columns + `total` + `letterGrade` tag + `gpa`; `null` → `—` + tooltip; per-row **Nhập điểm** → `Drawer` |
| (Drawer) | student scores GET/PUT | `ATTENDANCE`/`FINAL_EXAM`/`ASSIGNMENT` 0–10, `EXERCISE` never sent; 404 surfaced from `message` |

Maps 1:1 onto `docs/design/usecase-flows.md` UC-01 steps 1–6.

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
