# Hướng dẫn tích hợp đăng nhập Keycloak cho frontend

> Ngày: 2026-10-01 · FE root: `frontend-src/web-grading-system-fe/` · Realm: `ptit-wgs`
> Stack: React 19 + TypeScript · Vite 8 · antd 6 · axios · i18next
> Luồng interim: **password grant** qua Keycloak token API (HTTP thuần, không dùng `keycloak-js` — `keycloak-js` chỉ dùng cho Phase B authorization-code+PKCE).
>
> **Cập nhật 2026-10-03 (Phase 1):** đổi mật khẩu chuyển vào **api-gateway** — FE không còn
> gọi Keycloak Admin API, không còn `VITE_KEYCLOAK_ADMIN_*`; logout nay **revoke** phiên
> Keycloak. Chi tiết ở mục 10.

---

## 1. Tổng quan luồng đăng nhập

```
Browser (FE :5173)
   │
   ├─ POST /realms/ptit-wgs/protocol/openid-connect/token   (CORS: webOrigins)
   │    client_id=web-grading-fe, grant_type=password,
   │    username, password
   │    → { access_token, refresh_token, expires_in }
   │
   ├─ lưu wgs.auth = { accessToken, refreshToken, expiresAt, userId, email, role }
   │    trong localStorage (không lưu secret)
   │
   └─ mọi API call → Authorization: Bearer <access_token>
        │
        ▼
   api-gateway (:8080 / tunnel :30195 / web-dev1-api…)
        │  ├─ JWT resource server validates token against KEYCLOAK_ISSUER_URI
        │  ├─ AuthenticationContextFilter strips X-User-*, X-Gateway-Secret
        │  ├─ X-User-Id = sub, X-User-Email = email,
        │  │  X-User-Roles = realm_access.roles ∩ allowed-roles
        │  └─ forwards to course-service / submission-service / result-service
        │
        ▼
   downstream (HeaderAuthenticationFilter)
        └─ ROLE_ prefix tự động thêm vào Spring authority
           → @PreAuthorize hasRole('LECTURER') matches ROLE_LECTURER
```

**Lưu ý**: FE **không bao giờ** gửi `X-User-Id`, `X-Gateway-Secret`, `X-User-Roles` nữa — gateway tự đánh dấu lại từ JWT. Trước thay đổi này FE gửi `X-User-Id` trực tiếp (identity picker `/login`) — code đó đã bị thay bằng Bearer token.

---

## 2. Chuẩn bị Keycloak (realm `ptit-wgs`)

### 2.1 Đã có sẵn (không đụng)

| Mục | Giá trị | Bằng chứng |
|---|---|---|
| Realm | `ptit-wgs` | `GET /admin/realms` → có |
| Test users | `lecturer_test` (sub `11111111-...`), `student_test` (sub `22222222-...`) | sub cố định, email đã set |
| Realm roles | `ROLE_LECTURER`, `ROLE_STUDENT` | tên có prefix `ROLE_` |
| Postman client | `wgs-postman` (public, dag on, redirect `*`) | có sẵn, **không dùng cho FE** |

### 2.2 Vai trò — điểm cần sửa trước khi chạy được

Vấn đề **block toàn bộ** sau khi có token:

| Lớp | Giá trị hiện tại | Hành vi |
|---|---|---|
| Token realm roles | `ROLE_LECTURER`, `ROLE_STUDENT` | do test users được gán |
| Gateway allowlist mặc định | `LECTURER,STUDENT` (không set env `GATEWAY_ALLOWED_ROLES` ở đâu) | khớp chính xác — **không strip ROLE_** |
| Kết quả | giao nhau rỗng | `X-User-Roles` không được gửi → downstream 403 với mọi `@PreAuthorize` |

**Cách sửa (đã thống nhất):** set `GATEWAY_ALLOWED_ROLES=ROLE_LECTURER,ROLE_STUDENT` trên gateway deployed. Downstream `HeaderAuthenticationFilter` tự strip prefix `ROLE_` → authority `ROLE_LECTURER` → `hasRole('LECTURER')` match. Xem `src-services/api-gateway/src/main/java/.../filter/AuthenticationContextFilter.java` + test `AuthenticationContextFilterTest`.

**Không** đổi tên realm role (không đụng user mappings), FE cũng không tự fix được — FE chỉ đọc token và nhận diện cả hai dạng `LECTURER`/`ROLE_LECTURER`.

---

## 3. Tạo client `web-grading-fe` cho FE

### 3.1 Bằng Keycloak Admin Console

1. Đăng nhập admin console: `https://web-dev1-keycloak.vucongtuanduong.dpdns.org/admin/ptit-wgs/console` (admin / admin)
2. **Clients → Create**
   - Client ID: `web-grading-fe`
   - Client type: **Public**
   - Root URL: `http://localhost:5173`
   - Standard Flow Enabled: **ON**
   - Direct Access Grants (password) Enabled: **ON**
   - Valid Redirect URIs: `http://localhost:5173/*`
   - Web Origins: `http://localhost:5173`  ← **bắt buộc**, không để trống
   - Save
3. Roles → Create realm role: `LECTURER`, `STUDENT` *(tuỳ chọn — hiện tại `ROLE_LECTURER`/`ROLE_STUDENT` đã đủ vì gateway allowlist sẽ khớp đúng tên; tạo role mới chỉ cần nếu muốn theo chuẩn không prefix)*
4. Users → `lecturer_test` / `student_test` → Reset password → set mật khẩu dev (ví dụ `Dev2026!`) → tick **Temporary** = off (hoặc on nếu muốn bắt đổi lại).

### 3.2 Bằng Admin REST API (curl)

```bash
KC="https://web-dev1-keycloak.vucongtuanduong.dpdns.org"
REALM="ptit-wgs"

# 1) Admin token
AT=$(curl -s -m 10 -d "client_id=admin-cli" \
       -d "username=admin" -d "password=admin" \
       -d "grant_type=password" \
       "$KC/realms/master/protocol/openid-connect/token" \
     | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

# 2) Tạo client FE
curl -s -m 10 -X POST "$KC/admin/realms/$REALM/clients" \
  -H "Authorization: Bearer $AT" -H "Content-Type: application/json" \
  -d '{
    "clientId":"web-grading-fe","publicClient":true,
    "standardFlowEnabled":true,"directAccessGrantsEnabled":true,
    "redirectUris":["http://localhost:5173/*"],
    "webOrigins":["http://localhost:5173"],
    "defaultClientScopes":["web-origins","roles","profile","email"]
  }'

# 3) (Tuỳ chọn) Thêm realm roles không-prefix
for R in LECTURER STUDENT; do
  curl -s -m 10 -X POST "$KC/admin/realms/$REALM/roles" \
    -H "Authorization: Bearer $AT" -H "Content-Type: application/json" \
    -d "{\"name\":\"$R\"}"
done

# 4) Gán role cho test users (ví dụ lecturer_test → ROLE_LECTURER + LECTURER)
UID_L=$(curl -s -m 10 -H "Authorization: Bearer $AT" \
        "$KC/admin/realms/$REALM/users?username=lecturer_test" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
RID=$(curl -s -m 10 -H "Authorization: Bearer $AT" \
      "$KC/admin/realms/$REALM/roles?realm=true&search=ROLE_LECTURER" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
curl -s -m 10 -X POST "$KC/admin/realms/$REALM/users/$UID_L/role-mappings/realm" \
  -H "Authorization: Bearer $AT" -H "Content-Type: application/json" \
  -d "[{\"id\":\"$RID\",\"name\":\"ROLE_LECTURER\"}]"
```

> **CORS đã kiểm tra thực tế** (2026-10-01): `POST /token` với `client_id=wgs-postman` trả 401 **không kèm** `access-control-allow-origin` → trình duyệt chặn. Client mới **phải** có `webOrigins` thì POST mới trả ACAO cho origin `http://localhost:5173` (preflight OPTIONS đã trả 200 với origin đó từ client hiện có — nhưng POST thì không, nên phải sửa client).

---

## 4. Cài đặt FE

### 4.1 Env

`.env.development.local` (gitignored):
```bash
# Gateway deployed (tunnel) — local gateway/course-service không đi được từ browser
VITE_API_PROXY_TARGET=https://web-dev1-api.vucongtuanduong.dpdns.org

# Keycloak — phải khớp KEYCLOAK_ISSUER_URI của gateway
VITE_KEYCLOAK_AUTHORITY=https://web-dev1-keycloak.vucongtuanduong.dpdns.org/realms/ptit-wgs
VITE_KEYCLOAK_CLIENT_ID=web-grading-fe
```

`.env.development` — giữ comment gợi ý 2 dòng cuối cho `VITE_KEYCLOAK_AUTHORITY` / `VITE_KEYCLOAK_CLIENT_ID`.

> **Từ 2026-10-03:** FE **không đọc** `VITE_KEYCLOAK_ADMIN_URI`,
> `VITE_KEYCLOAK_ADMIN_CLIENT_ID`, `VITE_KEYCLOAK_ADMIN_CLIENT_SECRET` nữa — đổi mật khẩu
> đi qua api-gateway, secret chỉ nằm trong K8s Secret `keycloak-admin-client` ở cluster.
> (Lưu ý: `frontend-src/web-grading-system-fe/.env.development` vẫn còn 3 dòng này tính đến
> lúc viết — theo plan §6.5 chúng phải bị xoá; chưa verify ai xoá.) Xem mục 10.

### 4.2 Các file thay đổi

| File | Thay đổi |
|---|---|
| `src/shared/auth/keycloak.ts` *(mới)* | `login(username, pw)` gọi token endpoint, `refresh()`, decode base64url JWT, session `localStorage['wgs.auth']`, `logout()`, `isExpired()` |
| `src/shared/auth/identity.ts` | đọc identity từ session token; nhận diện cả `LECTURER` lẫn `ROLE_LECTURER` (strip prefix); giữ `isValidUuid(sub)` guard |
| `src/shared/api/http.ts` | interceptor gửi `Authorization: Bearer`; bỏ `X-User-Id`; 401 → clear session → `/login`; 403 → thông báo, không logout |
| `src/shared/auth/RequireRole.tsx` | nếu đã login nhưng vai trò không đúng → redirect `/no-role` (tránh vòng lặp với `/`) |
| `src/shared/auth/RequireIdentity.tsx` | không đổi (check session null/expired) |
| `src/features/auth/LoginPage.tsx` | form username + password (không còn role radio / UUID) |
| `src/shared/layout/AppLayout.tsx` | header hiện `preferred_username`/email + nút logout |
| `src/app/router.tsx` | thêm route `/no-role` → `NoRolePage` |
| `src/locales/vi.json`, `en.json` | đổi khóa `auth.*` cho login (xem mục 5 bên dưới) |

### 4.3 keycloak.ts — chi tiết

- Endpoint: `{authority}/protocol/openid-connect/token`
- Body: `client_id`, `grant_type=password`, `username`, `password` (form-urlencoded)
- CORS: browser gửi Origin; Keycloak trả ACAO nếu client `webOrigins` match
- Lưu: `{ accessToken, refreshToken, expiresAt: Date.now()+expires_in*1000, userId, email, role }`
- Refresh: khi `expiresAt - now < 30s` hoặc nhận 401 → POST cùng endpoint với `grant_type=refresh_token` + `refresh_token`; ghi đè session; **dedupe** (một request đang refresh → đợi promise chung)
- Decode JWT payload: `base64url → decodeURIComponent(escape(atob(...))) → JSON` (không cần library)
- Xoá session khi logout / 401 không phải hết hạn → `/login`
- **Từ 2026-10-03 — logout revoke**: trước khi xoá session, `POST {authority}/protocol/openid-connect/logout`
  với `client_id` + `refresh_token` (form-urlencoded; `web-grading-fe` là public client →
  **không** cần secret), fire-and-forget `.catch(() => {})` để lỗi mạng không block logout
- **Từ 2026-10-03 — `keycloakChangePassword` đã bị xoá**: FE không còn gọi
  `{adminUri}/admin/realms/.../reset-password`; gọi thay bằng
  `POST /api/v1/account/change-password` trên gateway (xem mục 10)

### 4.4 Nhận diện vai trò từ token

```ts
function normalizeRole(raw: string): Role | null {
  const r = raw.replace(/^ROLE_/, '') as Role
  return r === 'LECTURER' || r === 'STUDENT' ? r : null
}
// realm_access.roles = ['ROLE_LECTURER','offline_access'] → 'LECTURER'
// realm_access.roles = ['LECTURER']                       → 'LECTURER'
// không có vai trò hợp lệ → trạng thái "no allowed role"
```

FE dùng normalized role cho `RequireRole` + AppLayout tag + `HomeRedirect`.

### 4.5 i18n — khóa mới (thêm vào **cả** `vi.json` + `en.json`, key-identical)

| Khóa | vi | en |
|---|---|---|
| `auth.title` | Đăng nhập | Sign in |
| `auth.subtitle` | Nhập tài khoản Keycloak để bắt đầu. | Sign in with your Keycloak account. |
| `auth.username` | Tên đăng nhập | Username |
| `auth.usernamePlaceholder` | vd: lecturer_test | e.g. lecturer_test |
| `auth.password` | Mật khẩu | Password |
| `auth.passwordPlaceholder` | Nhập mật khẩu | Enter password |
| `auth.login` | Đăng nhập | Sign in |
| `auth.loggingIn` | Đang đăng nhập… | Signing in… |
| `auth.logout` | Đăng xuất | Sign out |
| `auth.sessionExpired` | Phiên hết hạn — đăng nhập lại | Session expired — sign in again |
| `auth.noRole` | Tài khoản không có vai trò truy cập ứng dụng. | This account has no access to the application. |
| `auth.loginError` | Sai tài khoản hoặc mật khẩu. | Invalid username or password. |
| `auth.networkError` | Không thể kết nối máy chủ xác thực. | Cannot reach the authentication server. |

> `npm run i18n:check` phải `OK — N keys in sync` trước khi build.

---

## 5. Cấu hình gateway deployed (D2)

### 5.1 Git-tracked config

- `config-services/api-gateway/templates/deployment.yaml`: thêm env
  ```yaml
  - name: GATEWAY_ALLOWED_ROLES
    valueFrom:
      secretKeyRef:
        name: gateway-trust
        key: GATEWAY_ALLOWED_ROLES
  ```
- `config-services/api-gateway/values-stg.yaml`: thêm `gateway: { allowedRoles: "ROLE_LECTURER,ROLE_STUDENT" }` (hoặc để template đọc secret trực tiếp — template đã chọn đọc secret, nên cập nhật secret luôn).
- `deploy/setup-namespace.sh`: đọc `GATEWAY_ALLOWED_ROLES` từ `.env`, đưa vào `gateway-trust` secret.
- `.env`: thêm `GATEWAY_ALLOWED_ROLES=ROLE_LECTURER,ROLE_STUDENT`.

### 5.2 Triển khai (ArgoCD)

1. `git commit` các thay đổi trên
2. ArgoCD tự sync Helm chart → gateway pod restart
3. Verify: `curl -s https://web-dev1-api.../actuator/health` + thử login

> Local dev (`:30195` Traefik hoặc tunnel) cũng cần secret này nếu dùng gateway cục bộ — hoặc giữ `.env.development.local` pointing thẳng course-service (chỉ dev transient, đã deprecated).

---

## 6. Xác minh (browser)

Chạy `npm run dev` rồi kiểm tra:

1. **Token POST CORS** — Network: `POST /protocol/openid-connect/token` → 200, response `access_token`, response header `access-control-allow-origin: http://localhost:5173`
2. **Không gửi X-User-Id** — mọi request chỉ có `Authorization: Bearer ...`, không có `X-User-Id`
3. **Lecturer login** (`lecturer_test`) → redirect `/` → `/classes`, bảng lớp hiện ra (200 từ gateway — chứng minh D2 đã生效)
4. **Wrong password** → toast lỗi, không crash, không redirect
5. **401 (token hết hạn/mock)** → clear session → `/login`
6. **403** (ví dụ student thử `/classes`) → thông báo "Không có quyền", **không** logout
7. **Logout** → redirect toàn trang `GET /protocol/openid-connect/logout` (`client_id` + `id_token_hint` + `post_logout_redirect_uri=/login`) → Keycloak terminate session → quay về `/login` → hiện form đăng nhập (D12, 2026-10-03)
8. **Student login** → `/student/classes`
9. **Trạng thái "no allowed role"** → `/no-role` + nút đăng xuất (chỉ khi token không có vai trò hợp lệ)

### 6.1 Negative tests

- Gọi `/api/v1/classes` không có token → 401 từ gateway (không phải 502)
- Token của `student_test` vào `/classes` → 403 (ownership/role gate)
- Sửa `localStorage['wgs.auth']` sửa token → 401 → redirect login

---

## 7. Phase B / Phase 3 — thay thế password grant (keycloak-js + PKCE)

> **Viết lại 2026-10-03.** Bản sketch cũ trong mục này (2026-10-01) đề nghị tạo một client
> **confidential** riêng cho SPA — **sai ở 2 chỗ**: (1) secret confidential nhúng vào bundle
> trình duyệt chính là lỗ hổng R1/R2 mà Phase 1 vừa dọn (`VITE_KEYCLOAK_ADMIN_CLIENT_SECRET`);
> SPA **bắt buộc public + PKCE**; (2) tên client đặt riêng đó chưa từng tồn tại trong realm —
> client dùng thật là **`web-grading-fe`**. Nguồn sự thật: `.opencode/plan/phase-3-pkce.md`
> (quyết định **D7–D12**); runtime commands ở `docs/guide/PASSWORD-GATEWAY-RUNBOOK.md` **§10**.

Password grant bị OAuth 2.1/OWASP khuyến cáo không dùng cho SPA (R3: password đi qua JS;
R4: token trong `localStorage`). Thay bằng:

1. **Cài dependency duy nhất**: `keycloak-js` (`npm i keycloak-js`).
2. **Client `web-grading-fe` — giữ PUBLIC, bật PKCE** (không tạo client mới, không có secret):
   ```
   publicClient: true
   standardFlowEnabled: true
   pkceMethod: S256
   redirectUris: ["http://localhost:5173/*"]
   webOrigins:   ["http://localhost:5173"]     ← explicit, KHÔNG bao giờ "*" khi có credentials
   directAccessGrantsEnabled: false            ← CHỈ SAU khi gateway đã deploy client wgs-password-verify
   ```
   Lệnh Admin Console / Admin REST: runbook §10.3.
3. **Login = redirect toàn trang** (D7): `keycloak.login()` → trang login của Keycloak →
   callback về `http://localhost:5173/*`. FE không còn nhận mật khẩu, không còn form password
   gửi lên token endpoint. Keycloak **tự hiện trang `UPDATE_PASSWORD`** cho user có required
   action → nhánh forced-change 2-field của FE thành thừa (D10).
4. **Token chỉ ở memory** (D8): `keycloak.init({ onLoad: 'check-sso' })` +
   `silent-check-sso.html`; iframe bị third-party cookie chặn → bắt `onError` và init lại với
   `silentCheckSsoRedirect: false` (redirect toàn trang, không mất session).
   **Không bao giờ** ghi token vào `localStorage`/`sessionStorage`.
5. **Bootstrap gate**: `keycloak.init()` bất đồng bộ còn `RequireIdentity`/`RequireRole` đọc
   session đồng bộ → phải render loading cho tới khi `init()` settle, nếu không reload nào
   cũng bị đá về `/login`.
6. `http.ts` interceptor **không đổi** (vẫn gửi Bearer) — `keycloak.ts` giữ nguyên là seam duy
   nhất; `identity.ts`, `LoginPage`, `AppLayout` chỉ đổi theo.
7. **Gateway không đụng tới login của FE, nhưng đổi client xác minh MK** (D11): Direct Access
   Grants tắt trên `web-grading-fe` sẽ làm hỏng `POST /api/v1/account/change-password` nếu
   gateway còn ROPC trên chính client đó → client riêng confidential **`wgs-password-verify`**
   (secret nằm trong K8s Secret `keycloak-admin-client`, env `KEYCLOAK_PASSWORD_CLIENT_*`).
   **Thứ tự bắt buộc**: gateway deploy xong (§10.4) rồi mới tắt direct grants (§10.6).
8. Không còn secret nào của FE: `VITE_KEYCLOAK_CLIENT_SECRET` / `VITE_KEYCLOAK_ADMIN_*` đều
   không tồn tại — nếu thấy lại là regression.

---

## 8. Troubleshooting

| Triệu chứng | Nguyên nhân | Fix |
|---|---|---|
| POST /token 401 *(chỉ luồng interim, ROPC)* | sai client_id / secret / grant_type | kiểm tra client `web-grading-fe`, Direct Access Grants ON. **Sau Phase 3:** trình duyệt **không còn** POST `/token` (login = redirect) — nếu vẫn thấy, hoặc direct grants bị tắt sớm, row này áp cho gateway (`wgs-password-verify`, xem runbook §10.6) chứ không phải FE |
| POST /token 403 CORS *(interim)* | `webOrigins` thiếu origin hoặc `*` không đủ với credentials | set `webOrigins: ["http://localhost:5173"]`, không dùng `*` khi credentials. Sau Phase 3 không còn POST `/token` từ browser, nhưng `webOrigins` vẫn quyết định CORS cho các call XHR còn lại (silent-check-sso, logout revoke) — vẫn phải set explicit |
| 401 trên mọi request | `KEYCLOAK_ISSUER_URI` gateway ≠ realm issuer | phải khớp chính xác (`.../realms/ptit-wgs`) |
| 403 Lecturer sau khi login | `GATEWAY_ALLOWED_ROLES` chưa set / sai tên role | set `ROLE_LECTURER,ROLE_STUDENT`, restart gateway |
| Vòng lặp `/login` → `/` → `/login` | `RequireRole` navigate `/` khi sai role → HomeRedirect → RequireRole | đã fix bằng route `/no-role`. **Phase 3 thêm một vòng lặp nữa:** route guard chạy trước khi `keycloak.init()` settle → luôn thấy session rỗng → phải có bootstrap loading gate (skill `react-frontend-antd` §23) |
| Reload bị đá về `/login` *(sai từ Phase 3)* | Cũ: nghĩ `localStorage['wgs.auth']` mất → sửa bằng `sessionStorage` | **KHÔNG được lưu token vào storage** (D8 — memory-only). Reload do `keycloak.init({ onLoad: 'check-sso' })` khôi phục; iframe bị chặn thì `onError` → fallback redirect (`silentCheckSsoRedirect: false`). Session "mất" thật khi đó là guard chạy trước `init()` xong |
| refresh token fail | refresh_token hết hạn / revoked | clear session → buộc login lại. Sau Phase 3 vòng đời do `keycloak-js` lo, replay refresh token cũ vẫn phải fail (revoke còn chạy) |

---

## 9. Các file đã thay đổi (khi hoàn thành)

- `docs/design/frontend-keycloak-login.md` (file này)
- `.env`, `.env.development`, `.env.development.local`
- `config-services/api-gateway/templates/deployment.yaml`, `values-stg.yaml`
- `deploy/setup-namespace.sh`
- `frontend-src/web-grading-system-fe/src/shared/auth/keycloak.ts` (mới)
- `frontend-src/web-grading-system-fe/src/shared/auth/identity.ts`
- `frontend-src/web-grading-system-fe/src/shared/api/http.ts`
- `frontend-src/web-grading-system-fe/src/shared/auth/RequireRole.tsx`
- `frontend-src/web-grading-system-fe/src/features/auth/LoginPage.tsx`
- `frontend-src/web-grading-system-fe/src/shared/layout/AppLayout.tsx`
- `frontend-src/web-grading-system-fe/src/app/router.tsx`
- `frontend-src/web-grading-system-fe/src/locales/vi.json`, `en.json`
- `src-services/api-gateway/src/main/resources/application.yaml` (default giữ nguyên, ghi chú)

---

## 10. Cập nhật 2026-10-03 — đổi mật khẩu qua gateway + logout revoke (Phase 1)

Plan: `docs/design/keycloak-password-gateway-plan-2026-10-03-v1.md` (nguồn sự thật).

### 10.1 Đổi mật khẩu — FE gọi gateway, KHÔNG gọi Keycloak Admin API

Trước 2026-10-03 `LoginPage`/`keycloak.ts` gọi trực tiếp Keycloak Admin API
(`GET /admin/realms/.../users` + `PUT .../reset-password`) với
`VITE_KEYCLOAK_ADMIN_CLIENT_SECRET` nhúng trong bundle trình duyệt — secret có role
`manage-users` ⇒ ai lấy được bundle reset được mọi password (R1/R2 Critical).

Nay (theo plan §6.5 — phần FE đang được viết song song, **chưa verify runtime**):

- Endpoint duy nhất: `POST /api/v1/account/change-password` trên **api-gateway**
  (không cần Bearer, không bao giờ trả 401). Contract đầy đủ + curl:
  `docs/design/usecase-flows.md` UC-14 và `docs/api/API-TEST-GUIDE.md` §5.
- **Forced change**: password grant trả `Account is not fully set up` → form 2 ô →
  FE lấy mật khẩu vừa gõ làm `currentPassword` (chỉ nằm trong React state) → 204 →
  đăng nhập lại bằng mật khẩu mới.
- **Self-service**: menu user ở header → modal 3 ô → 204 → **ở lại app, không logout**.
- `VITE_KEYCLOAK_ADMIN_*` không còn được dùng — secret nằm server-side
  (K8s Secret `keycloak-admin-client`, chỉ api-gateway đọc).
- Realm-side (flat reset-password body, service-account roles, brute force) → xem
  skill `keycloak` của repo, không lặp lại ở đây.

### 10.2 Logout — full-page end-session (D12, chốt 2026-10-03)

`logout()` trong `keycloak.ts` gọi `keycloak.logout({ redirectUri: <origin>/login })` —
keycloak-js dựng `GET {authority}/protocol/openid-connect/logout?client_id&
id_token_hint&post_logout_redirect_uri` rồi `location.replace` tới đó: Keycloak
terminate browser SSO session (token trong session bị revoke ngay) và điều hướng về
`/login`. XHR revoke (`POST .../logout` với `client_id` + `refresh_token`) **đã bỏ** —
nó không xoá được cookie SSO nên sau logout lần `/login` kế tiếp bounce thẳng vào app.
Yêu cầu realm: attribute `post.logout.redirect.uris` trên `web-grading-fe` (skill
`keycloak` §7). Access token đã phát hành vẫn sống tới `accessTokenLifespan` (300s).

> **Trạng thái ghi nhận:** các thay đổi FE/BE nay **chưa được e2e verify** lúc viết
> (cluster down 2026-10-03) — xem checklist §7 của plan.
