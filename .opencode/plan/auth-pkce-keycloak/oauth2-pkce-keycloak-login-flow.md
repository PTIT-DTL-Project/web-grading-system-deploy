# OAuth2.0, PKCE và luồng đăng nhập hiện tại của web-grading-system

Tài liệu này giải thích chi tiết:

1. **OAuth 2.0** là gì, vai trò các thành phần, các grant type phổ biến, tại sao SPA không dùng password grant.
2. **PKCE (Proof Key for Code Exchange)** là gì, vấn đề giải quyết, cơ chế `code_verifier` / `code_challenge`, phương pháp `S256`.
3. **Luồng đăng nhập hiện tại** của hệ thống được implement như nào, dựa trên code thực tế trong repo (không nói chung chung).

Nguồn sự thật: code thực tế trong repository `web-grading-system-deploy`, đặc biệt là:

- `frontend-src/web-grading-system-fe/src/shared/auth/keycloak.ts`
- `.opencode/plan/phase-3-pkce.md` (quyết định D7–D12, ghi 2026-10-03)
- `src-services/keycloak/ptit-wgs-realm.json` (realm config)
- `.opencode/skills/keycloak/SKILL.md` và `.opencode/skills/react-frontend-antd/SKILL.md`

---

## 1. OAuth 2.0 — tổng quan

### 1.1 Vai trò các thành phần (theo RFC 6749)

| Thành phần | Ý nghĩa trong hệ thống |
|------------|------------------------|
| **Resource Owner** (chủ sở hữu tài nguyên) | Người dùng (sinh viên / giảng viên / admin) sở hữu tài khoản Keycloak. |
| **Client** | Ứng dụng frontend React (`web-grading-system-fe`), chạy trên trình duyệt. |
| **Authorization Server** (máy chủ cấp phép) | Keycloak realm `ptit-wgs`, xác thực người dùng và cấp token. |
| **Resource Server** (máy chủ tài nguyên) | API Gateway + các backend microservices (course-service, submission-service, …) bảo vệ API bằng access token. |

### 1.2 Luồng OAuth 2.0 tổng quát (Authorization Code Flow)

```
Người dùng ──> Trình duyệt ──> Keycloak (đăng nhập)
                                      │
                                      │ cấp authorization code
                                      ◀─────────────────────
                                      │
Trình duyệt ──> Keycloak (đổi code lấy token)
                                      │
                                      │ cấp access_token / refresh_token / id_token
                                      ◀─────────────────────
                                      │
Trình duyệt ──> API Gateway (gắn Bearer token)
                                      │
                                      │ xác thực token, truyền X-User-Id
                                      ▼
                               Backend services xử lý business logic
```

### 1.3 Các grant type phổ biến

| Grant type | Đối tượng sử dụng | Tại sao hệ thống KHÔNG dùng trong trình duyệt |
|------------|-------------------|-----------------------------------------------|
| **Authorization Code** | Server-side app, SPA (với PKCE) | Luồng chính hiện tại sử dụng. |
| **Implicit** | SPA cũ (không khuyến khích) | Token rò rỉ qua URL, không an toàn. |
| **Password** (ROPC) | Ứng dụng tin cậy | Yêu cầu frontend thu thập mật khẩu → XSS có thể đọc được. Hệ thống đã cắt (risk R3). |
| **Client Credentials** | Machine-to-machine | Không có người dùng can thiệp, không dùng cho login người dùng. |

### 1.4 Tại sao SPA là public client

SPA chạy 100% trên trình duyệt, toàn bộ source code (bao gồm JavaScript bundle) có thể được xem bởi bất kỳ ai. Do đó:

- SPA **không thể bảo mật được `client_secret`** — nếu nhét secret vào bundle, attacker dễ dàng trích xuất.
- OAuth 2.0 phân loại SPA là **public client** (client công cộng).
- Public client không được dùng `client_secret` để xác thực khi đổi authorization code lấy token. Thay vào đó, nó dùng **PKCE** để bảo vệ mã authorization code khỏi bị interception.

---

## 2. PKCE — Proof Key for Code Exchange

### 2.1 Vấn đề PKCE giải quyết

Trong Authorization Code Flow, sau khi người dùng đăng nhập thành công, Authorization Server redirect trở lại client kèm `authorization code`. Nếu không có PKCE:

- Một application độc hại trên cùng thiết bị có thể intercept `authorization code` từ redirect URI.
- Application đó sau đó dùng code đó (cùng `client_id`, public client không có secret) để đổi lấy token → đăng nhập thay vì người dùng.

PKCE (RFC 7636, bắt buộc cho public client theo RFC 8252) ngăn chặn việc này bằng cách yêu cầu client chứng minh nó là cùng một bên đã khởi tạo yêu cầu đăng nhập.

### 2.2 Cơ chế code_verifier / code_challenge

| Thuật ngữ | Mô tả |
|-----------|-------|
| **code_verifier** | Chuỗi ngẫu nhiên entropy cao, sinh bởi client trước khi redirect sang Keycloak. |
| **code_challenge** | Giá trị băm của `code_verifier`, gửi kèm yêu cầu đăng nhập. |
| **S256** | Phương pháp băm: `code_challenge = Base64URL-Encode(SHA-256(code_verifier))`. |

Luồng bảo vệ:

1. Client sinh `code_verifier` (ngẫu nhiên).
2. Client tính `code_challenge` từ `code_verifier` bằng S256.
3. Client gửi `code_challenge` + `code_challenge_method=S256` khi yêu cầu authorization code.
4. Keycloak lưu `code_challenge` cùng với authorization code đã cấp.
5. Client đổi code lấy token bằng cách gửi lại `code_verifier` thật.
6. Keycloak băm `code_verifier` nhận được, so khớp với `code_challenge` đã lưu. Nếu khớp → cấp token. Nếu không → từ chối.

### 2.3 Tại sao PKCE không thay thế client_secret hoàn toàn

PKCE bảo vệ mã authorization code, nhưng không xác thực danh tính client. Vì public client không có secret, attacker nếu biết `client_id` vẫn có thể gửi yêu cầu authorization. Tuy nhiên, attacker không thể sinh ra `code_verifier` khớp với `code_challenge` của victime, nên không thể đổi được code đó thành token.

---

## 3. Cấu hình Keycloak của hệ thống (theo code thực tế)

Thông tin sau lấy từ `.opencode/plan/phase-3-pkce.md` và `keycloak.ts`:

### 3.1 Client `web-grading-fe` (trên realm live)

| Thuộc tính | Giá trị |
|------------|---------|
| `clientId` | `web-grading-fe` |
| `publicClient` | `true` |
| `standardFlowEnabled` | `true` |
| `directAccessGrantsEnabled` | `false` (đã tắt 2026-10-03, trước khi deploy) |
| `pkce.code.challenge.method` (client attribute) | `S256` |
| `redirectUris` | `["http://localhost:5173/*"]` (chỉ dev origin, FE chưa deploy) |
| `webOrigins` | `["http://localhost:5173"]` |
| `post.logout.redirect.uris` | `http://localhost:5173/*` |

### 3.2 Client `wgs-password-verify` (khác, dùng cho gateway)

| Thuộc tính | Giá trị |
|------------|---------|
| `clientId` | `wgs-password-verify` |
| `publicClient` | `false` (confidential) |
| `directAccessGrantsEnabled` | `true` |
| `secret` | Chỉ nằm trong secret của gateway, **không** trong bundle FE |

Client này dùng cho bước xác minh `currentPassword` khi đổi mật khẩu qua gateway (`/api/v1/account/change-password`), **không** tham gia luồng PKCE đăng nhập của người dùng thông thường.

### 3.3 Realm

- Realm: `ptit-wgs`
- Issuer URL: dạng `https://<host>/realms/ptit-wgs`
- Lưu ý: File realm export tại `src-services/keycloak/ptit-wgs-realm.json` **không chứa** client `web-grading-fe` (client này tạo tay trên realm live). Cần export lại realm sau khi cấu hình xong để mirror chính xác.

---

## 4. Luồng đăng nhập hiện tại — chi tiết theo actor

Dưới đây là luồng thực sự được implement trong `keycloak.ts` (Phase 3, D7–D12). Mỗi bước ghi rõ: Actor, Hành động, Request (nếu có), Precondition, Expected result.

### Danh sách actor

| Actor | Vai trò |
|-------|---------|
| **Người dùng** | Sinh viên / giảng viên / admin dùng trình duyệt. |
| **Trình duyệt (FE SPA)** | React app tại `http://localhost:5173` (dev), gọi `keycloak-js`, không giữ client secret. |
| **Keycloak** | IdP realm `ptit-wgs`, cung cấp trang login hosted, cấp code và token. |
| **API Gateway** | Tiếp nhận request kèm `Authorization: Bearer <access_token>`, xác thực qua `HeaderAuthenticationFilter`, truyền `X-User-Id` sang backend. |

### Bước 0 — Khởi tạo trước khi render router

**Actor:** Trình duyệt (FE SPA)

**Hành động:** Gọi `initAuth()` (file `keycloak.ts:145`).

**Cấu hình keycloak-js:**
```ts
{
  onLoad: 'check-sso',
  pkceMethod: 'S256',
  checkLoginIframe: false,
  silentCheckSsoRedirectUri: `${origin}/silent-check-sso.html`  (nếu không phải trang callback)
}
```

**Precondition:**
- Biến môi trường `VITE_KEYCLOAK_AUTHORITY` có dạng `https://<host>/realms/<realm>`. Ngược lại ném `KeycloakConfigError`.
- File tĩnh `public/silent-check-sso.html` phải tồn tại (keycloak-js đọc theo mặc định).

**Expected result:**
- Nếu có session IdP hợp lệ (qua silent-check-sso iframe): keycloak-js khôi phục token vào memory, FE sinh `AuthSession`, router mount bình thường.
- Nếu không có session hoặc iframe bị chặn (third-party cookie): `init()` resolve `false`, FE vẫn mount landing page, chờ người dùng bấm nút Đăng nhập. Không redirect ngay.

### Bước 1 — Người dùng nhấn Đăng nhập

**Actor:** Người dùng → Trình duyệt

**Hành động:** Gọi `redirectToKeycloakLogin()` (`keycloak.ts:212`).

**Chi tiết:**
- Xác định `redirectUri`: lấy từ `sessionStorage` key `wgs.postLoginUrl` nếu có, ngược lại dùng `origin + pathname` hiện tại.
- Gọi `kc.login({ redirectUri })`.
- keycloak-js tự sinh `code_verifier` (entropy cao) và `code_challenge = Base64URL(SHA-256(code_verifier))`, phương pháp `S256`.

**Precondition:** `keycloak` instance đã được khởi tạo (`initAuth` đã chạy).

**Expected result:** Trình duyệt được điều hướng toàn trang đến trang login hosted của Keycloak. Trình duyệt **không bao giờ** thấy form mật khẩu của FE (cắt risk R3 — ROPC `grant_type=password` đã được gỡ bỏ).

### Bước 2 — Trình duyệt yêu cầu mã xác thực từ Keycloak

**Actor:** Trình duyệt → Keycloak

**Request (mẫu):**
```
GET {issuer}/protocol/openid-connect/auth
  ?client_id=web-grading-fe
  &redirect_uri=http://localhost:5173/...
  &response_type=code
  &scope=openid
  &state=<ngẫu nhiên>
  &code_challenge=<Base64URL(SHA-256(code_verifier))>
  &code_challenge_method=S256
```

**Precondition:**
- Client `web-grading-fe` là `publicClient: true`, `standardFlowEnabled: true`.
- Thuộc tính client `pkce.code.challenge.method` phải là `S256` (lưu dưới `attributes`, **không** phải field top-level `pkceMethod` — gửi top-level sẽ nhận HTTP 400 `Unrecognized field`, đã verify 2026-10-03).
- `redirect_uri` phải khớp một giá trị trong `redirectUris` đã đăng ký (`http://localhost:5173/*`).

**Expected result:**
- Nếu thiếu `code_challenge` khi client yêu cầu PKCE → Keycloak trả `error=invalid_request` (Missing parameter: code_challenge_method), đã verify behaviorally 2026-10-03.
- Nếu hợp lệ → Keycloak hiển thị trang đăng nhập hosted của mình.

### Bước 3 — Người dùng nhập mật khẩu trên trang Keycloak

**Actor:** Người dùng → Keycloak

**Hành động:** Trình duyệt hiển thị form login của Keycloak (không phải form của FE). Người dùng nhập tài khoản/mật khẩu.

**Bảo mật:** Mật khẩu **không đi qua JavaScript của FE** → XSS không đọc được (cắt risk R3).

**Điều kiện đặc biệt:** Nếu người dùng có required action (ví dụ `UPDATE_PASSWORD` do mật khẩu tạm), Keycloak tự hiện trang đó trong cùng luồng redirect (D10).

**Expected result:** Xác thực thành công → Keycloak sinh một `authorization code` one-time.

### Bước 4 — Keycloak redirect trở lại FE kèm mã

**Actor:** Keycloak → Trình duyệt → FE

**Response (mẫu):**
```
302 {redirect_uri}?code=<authorization_code>&state=<state>
```

Trình duyệt thực hiện redirect, URL của FE bây giờ chứa `?code=…&state=…`.

**Expected result:** FE nhận được `authorization code` và `state` trên URL.

### Bước 5 — FE đổi authorization code lấy token

**Actor:** Trình duyệt (FE SPA) → Keycloak

`initAuth()` phát hiện URL có `code` + `state` (hàm `hasAuthCallback` tại `keycloak.ts:159`), keycloak-js gọi token endpoint:

**Request (mẫu):**
```
POST {issuer}/protocol/openid-connect/token
  grant_type=authorization_code
  client_id=web-grading-fe
  code=<authorization_code>
  code_verifier=<code_verifier thật>
  redirect_uri=<cùng Bước 2>
```

**Precondition:** `code_verifier` phải khớp với `code_challenge` đã gửi ở Bước 2 (Keycloak băm lại bằng S256 để so khớp).

**Expected result:** Keycloak trả JSON chứa:
- `access_token`
- `refresh_token`
- `id_token`
- `expires_in`

keycloak-js giữ toàn bộ trong **bộ nhớ của instance Keycloak**, không ghi `localStorage` (cắt risk R4 — không có `localStorage['wgs.auth']`).

### Bước 6 — FE sinh session nội bộ

**Actor:** Trình duyệt (FE SPA)

Hàm `buildSession()` (`keycloak.ts:130`) decode phần payload (JWT) của `access_token`:

- Lấy `sub` → `userId`.
- Lấy `email`.
- Lấy `realm_access.roles`, chuẩn hóa bỏ prefix `ROLE_`, rồi so khớp với allow-list `LECTURER | STUDENT | ADMIN`.
- Nếu role không nằm trong danh sách → ném `token_no_allowed_role`, **không tạo session**.

Lưu vào biến in-memory `session` (`AuthSession` có `accessToken`, `refreshToken`, `userId`, `email`, `role`).

**Expected result:** `getSession()` trả về `AuthSession` hợp lệ, có thể dùng cho các request API sau này.

### Bước 7 — Router mount, người dùng vào ứng dụng

**Actor:** Trình duyệt (FE SPA) → API Gateway → Backend

**Hành động:**
- `AuthGate` chờ `initAuth()` xong mới mount router.
- Các route guard `RequireIdentity` / `RequireRole` đọc `getSession()` đồng bộ tại render time.
- Có session + role phù hợp → vào trang được phép.
- Không có session và không phải trang công khai → điều hướng `/login` → `LoginPage` tự gọi `redirectToKeycloakLogin()` (quay về Bước 1).

**Gọi API:** `http.ts` gắn header:
```
Authorization: Bearer <access_token>
```

Gateway xác thực token, trích `sub` từ JWT, gán `X-User-Id`, truyền sang backend service (course-service, submission-service, …).

---

## 5. Luồng làm mới token (refresh)

**Actor:** Trình duyệt → Keycloak

Khi request API trả `401`, `http.ts` gọi `refreshSession()` (`keycloak.ts:232`):

**Request (mẫu):**
```
POST {issuer}/protocol/openid-connect/token
  grant_type=refresh_token
  client_id=web-grading-fe
  refresh_token=<refresh_token hiện có>
```

**Mécanisme bảo vệ:**
- Dedupe trong tab qua `refreshPromise` (nhiều `401` cùng lúc chỉ refresh một lần).
- Cross-tab: dùng Web Lock `wgs.token.refresh` để serialize (giữ từ Phase 2, D9). Tuy nhiên mỗi tab giữ **của mình** một refresh token riêng (memory-only), nên không có trạng thái "đã fresh" chia sẻ giữa tab — lock chỉ serialize, không làm bỏ qua refresh cần thiết.

**Kết quả có thể xảy ra:**

| Kết quả | Xử lý |
|---------|-------|
| Thành công | `buildSession()` lấy token cặp mới, ghi đè `session`. |
| `400 invalid_grant` (refresh token đã hết/hồi thu) | `clearSession()`, ném `REFRESH_DEAD`, `http.ts` điều hướng đăng nhập lại. |
| Lỗi mạng / 5xx | Giữ session cũ, ném `REFRESH_UNREACHABLE`, không đăng xuất ngốn người dùng. |

Access token leben tối đa 300s (5 phút) theo plan; refresh token sống lâu hơn.

---

## 6. Luồng đăng xuất

**Actor:** Người dùng → Trình duyệt → Keycloak → FE

**Hành động:** Gọi `logout()` (`keycloak.ts:307`).

**Chi tiết:**
1. Gọi `keycloak.logout({ redirectUri: origin + '/login' })` — full-page redirect (phương án B, D12).
2. Trình duyệt đến:

```
GET {issuer}/protocol/openid-connect/logout
  ?client_id=web-grading-fe
  &id_token_hint=<id_token>
  &post_logout_redirect_uri=http://localhost:5173/login
```

3. Keycloak chấm hết SSO session (cookie SSO bị xóa) và revoke các token được cấp dưới session đó.
4. Keycloak chuyển hướng trở lại `/login` trên FE.
5. FE reload → `initAuth()` chạy `check-sso` → không có session IdP → hiển thị form đăng nhập thật (không bị vòng lặp redirect).
6. `clearSession()` **không gọi trước** `logout()` vì keycloak-js cần `idToken` để dựng `id_token_hint`; phiên in-memory của FE bị xóa khi trang reload.

**Precondition:** Realm client attribute `post.logout.redirect.uris` phải đã đăng ký (`http://localhost:5173/*`). Nếu không, Keycloak chỉ hiện trang "logged out" của nó, không quay về app.

**Lý do chọn full-page logout (không dùng XHR revoke):** XHR revoke cũ không chạm cookie SSO của trình duyệt, nên sau logout, lần `/login` tiếp theo bị AuthGate bounce thẳng vào app (người dùng không đăng nhập tài khoản khác được).

---

## 7. Bootstrap và silent SSO (reload trang)

**Actor:** Trình duyệt (FE SPA)

`initAuth()` dùng `onLoad: 'check-sso'`:

- keycloak-js tạo iframe tới `/silent-check-sso.html` (tại FE origin) để kiểm tra session IdP qua third-party cookie.
- Nếu thành công → khôi phục session trong memory, không cần đăng nhập lại.
- Nếu iframe bị chặn (Chrome third-party cookie phaseout, Safari ITP) → `init()` resolve `false`, FE không redirect ngay (để landing page hiển thị), người dùng bấm login → `redirectToKeycloakLogin()`.
- Có fallback `silentCheckSsoRedirect: false` nếu muốn dùng full-page thay vì iframe.

**File tĩnh cần có:** `frontend-src/web-grading-system-fe/public/silent-check-sso.html`.

---

## 8. Bảo mật — các risk đã cắt

| Risk | Mô tả | Cách hệ thống xử lý |
|------|-------|---------------------|
| **R3** | FE nhận/mã hóa mật khẩu trong JS → XSS đọc được password | Đã cắt: trình duyệt không bao giờ thấy form mật khẩu; Keycloak host login; code FE không còn `grant_type=password`. |
| **R4** | access + refresh token trong `localStorage['wgs.auth']` → XSS ăn cắp session | Đã cắt: token chỉ ở memory trong instance keycloak-js, không ghi localStorage. Reload mất session, phải check-sso lại. |

### Giới hạn của thiết kế hiện tại

- FE chưa deploy → không có ingress/Dockerfile trong `deploy/`, chỉ chạy dev `vite` tại `localhost:5173`. Do đó `redirectUris`/`webOrigins` chỉ có origin dev. Khi deploy FE prod phải bổ sung origin prod vào Keycloak client ngay, không là login quay về không được.
- Realm export chưa mirror: `ptit-wgs-realm.json` không chứa client `web-grading-fe`, cần export lại realm sau khi cấu hình xong trên realm live.
- Chưa có test runner cho FE → verify phải bằng `npm run build` + `npm run lint` + E2E thủ công.
- Access token đã phát hành sống tối đa 300s; sau khi logout, access token cũ vẫn hiệu lực đến khi hết hạn (Keycloak revoke session nhưng không thể thu hồi access token đã phát hành ngay lập tức trừ khi có cơ chế introspection/revoke bổ sung).

---

## 9. Files tham khảo trong repo

| Đường dẫn | Mục đích |
|-----------|----------|
| `frontend-src/web-grading-system-fe/src/shared/auth/keycloak.ts` | Module Keycloak chính: `initAuth`, `redirectToKeycloakLogin`, `refreshSession`, `logout`, `buildSession`, `getSession`, `clearSession`. |
| `.opencode/plan/phase-3-pkce.md` | Quyết định D7–D12 (2026-10-03): public+PKCE, memory-only token, logout full-page, client `wgs-password-verify`. |
| `src-services/keycloak/ptit-wgs-realm.json` | Realm export (chưa chứa client `web-grading-fe`). |
| `.opencode/skills/keycloak/SKILL.md` | Convention Keycloak: realm, client scope, PKCE/S256, direct grants, gateway password-verify client. |
| `.opencode/skills/react-frontend-antd/SKILL.md` | Convention FE: keycloak-js init/bootstrap gate, memory-only token rule. |

---

## 10. Điều kiện tiên quyết trước khi vận hành thực tế

1. Cấu hình Keycloak client `web-grading-fe`: `publicClient=true`, `standardFlowEnabled=true`, `directAccessGrantsEnabled=false`, attribute `pkce.code.challenge.method=S256`, `redirectUris`/`webOrigins` chứa origin FE thực tế.
2. Tạo file `public/silent-check-sso.html` trong FE.
3. Export lại realm `ptit-wgs` để `ptit-wgs-realm.json` mirror chính xác.
4. Khi deploy FE prod: bổ sung origin prod vào `redirectUris` + `webOrigins` + `post.logout.redirect.uris` ngay.
5. Verify E2E: login → redirect Keycloak → quay lại app có role; reload không bị đá về `/login`; 401 → tự refresh; logout → refresh token cũ dùng lại fail.

---

*Tài liệu này được viết dựa trên code thực tế trong repository `web-grading-system-deploy` tại `/home/duongvct/Documents/workspace/PTIT/web-grading-system-deploy`. Ngày viết: 2026-10-26.*