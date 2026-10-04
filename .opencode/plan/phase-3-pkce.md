# Phase 3 — keycloak-js + authorization code + PKCE (cắt R3/R4)

> Ghi 2026-10-03, Plan mode. **Chưa implement.**
> Tiền đề: **Phase 1 và Phase 2 mới code-complete, runtime CHƯA chạy** (cluster down).
> Phase 3 **không bắt đầu** cho tới khi runbook §3–§9 xong — nếu không thì không biết luồng nào đang sống.
>
> Race: Phase 1 `docs/design/keycloak-password-gateway-plan-2026-10-03-v1.md` ·
> Phase 2 `.opencode/plan/keycloak-hardening-phase-2.md` ·
> Sketch cũ `docs/design/frontend-keycloak-login.md` §7 (có 2 chỗ sai, xem §2)

---

## 0. Quyết định đã chốt (2026-10-03)

| # | Câu hỏi | Chọn |
|---|---|---|
| **D7** | UX login | **A** — redirect toàn trang sang login của Keycloak (`keycloak.login()`) |
| **D8** | Token lưu ở đâu | **A** — memory-only + `check-sso` iframe, **tự fallback sang redirect** nếu iframe bị chặn |
| **D11** | Gateway xác minh `currentPassword` | **A** — client riêng `wgs-password-verify` **confidential** + property `passwordClientSecret` · **✅ client tạo 2026-10-03** (ROPC 200/401 verify, secret trong `.env`) |
| — | Origin FE | **chỉ dev `http://localhost:5173`** — FE chưa deploy, không có ingress/Dockerfile |
| **D9** | Xóa Web Lock Phase 2 | ⏳ *đề xuất: giữ tới khi Phase 3 verify xong, dọn ở commit riêng* — **chưa chốt** |
| **D10** | Xóa nhánh forced-change FE | ⏳ *đề xuất: Keycloak tự hiện trang `UPDATE_PASSWORD`* — **chưa chốt** |
| **D12** | Logout | ✅ **chốt 2026-10-03: phương án B — `keycloak.logout()` full-page**, bỏ XHR revoke |

> D9/D10 chưa chốt (còn D12 đã chốt 2026-10-03, implement cùng ngày) → phần còn lại
> phải xác nhận trước khi implement, không tự ý làm.

---

## 1. Mục tiêu

Cắt 2 risk **High** còn lại, không thêm feature:

| Risk | Hiện tại | Cắt bằng |
|---|---|---|
| **R3** | FE nhận mật khẩu qua JS (ROPC `grant_type=password`) → XSS đọc được password | browser **không bao giờ** thấy form password → Keycloak host login |
| **R4** | access + refresh token trong `localStorage['wgs.auth']` → XSS ăn cắp session ≤ 10h | token chỉ ở **memory** (keycloak-js) |

Không đổi contract API gateway, trừ 1 việc cấu hình + ~10 dòng Java (D11).

---

## 2. Bằng chứng đã thu (đọc code, không suy đoán)

1. **`keycloak.ts` là seam duy nhất** — header file tự ghi: *"Phase B will swap the grant for keycloak-js … this module stays the only place that talks to the Keycloak token and logout endpoints"*.
   Consumers: `http.ts` (`getSession`/`refreshSession`/`clearSession`), `identity.ts`, `AppLayout.tsx`, `LoginPage.tsx`, `ChangePasswordModal.tsx`, `RequireIdentity.tsx`, `RequireRole.tsx`.
2. **Chưa có `keycloak-js`** — `package.json` chỉ có antd/axios/i18next/react/react-router → Phase 3 thêm 1 dependency.
3. **FE không có test runner** (không vitest/jest/playwright) → verify = `npm run build` + `npm run lint` + E2E thủ công.
4. **Gateway bước 2 của change-password = ROPC trên chính `web-grading-fe`**
   (`KeycloakAdminWebClient.java:68` → `passwordGrantForm(properties.passwordClientId(), …)`,
   `application.yaml:62` → `password-client-id: web-grading-fe`).
   ⇒ **Tắt Direct Access Grants trên `web-grading-fe` sẽ làm hỏng endpoint Phase 1.** Đây là chỗ plan cũ **bỏ sót**.
5. **Sketch cũ sai hướng**: `frontend-keycloak-login.md:276` đề xuất *"tạo confidential SPA client `web-grading-fe-spa`"* → confidential secret sẽ lọt vào bundle, đúng cái Phase 1 vừa dọn. Client SPA **phải là public + PKCE**.
6. **Realm export không trung thực**: `src-services/keycloak/ptit-wgs-realm.json` **không chứa `web-grading-fe`** (0 match) — client này chỉ có ở realm live, tạo tay (`frontend-keycloak-login.md` §3).
   Export chỉ có `wgs-postman` (public, `redirectUris: ['*']`, `webOrigins: ['+']`, direct ON) và `wgs-user-service` (confidential, **`secret` plaintext trong git**).
7. **Không có FE ingress/Dockerfile nào** trong `deploy/` → FE hiện chỉ chạy dev `vite` tại `localhost:5173`.
   **Đã chốt: chỉ cần redirect URI dev.** Khi deploy FE sau → phải bổ sung origin prod ngay (đánh dấu trong runbook).
8. **`RequireIdentity`/`RequireRole` đọc `getIdentity()` đồng bộ khi render.** `keycloak.init()` là bất đồng bộ → **bắt buộc có bootstrap loading gate**, không là reload nào cũng bị đá về `/login`.
9. Forced change hiện phát hiện qua lỗi ROPC `Account is not fully set up` → `must_change_password` (`keycloak.ts:92`).
10. `sessionFromTokens` throw `token_no_allowed_role` nếu token thiếu `LECTURER`/`STUDENT`.

---

## 3. Quyết định

### D7 ✅ — UX login: redirect sang trang login của Keycloak

Authorization-code + PKCE **bắt buộc redirect** — không có cách giữ form password trong FE.

**Chọn A**: `keycloak.login()` → toàn trang Keycloak → callback về app.
Hệ quả:
- R3 cắt thật.
- Keycloak **tự hiện trang `UPDATE_PASSWORD`** trong luồng (xem D10).
- Mất control UI login → cần theme/branding nếu muốn khớp giao diện.
- `redirectUris` / `webOrigins` của client là bắt buộc (§4).

### D8 ✅ — Token: memory-only + `check-sso` iframe, fallback redirect

**Chọn A**:
- Token chỉ trong memory → **R4 cắt** (`localStorage['wgs.auth']` không còn).
- Reload → `keycloak.init({ onLoad: 'check-sso' })` qua iframe `/silent-check-sso.html`.
- Keycloak **khác origin** → **third-party cookie risk** (Chrome third-party phaseout, Safari ITP).
  Nếu iframe bị chặn → bắt `onError` của `init` và **chạy lại với `silentCheckSsoRedirect: false`** (redirect toàn trang) → không mất session, chỉ nháy 1 lần.

### D9 ⏳ — Web Lock Phase 2 còn cần không? *(chưa chốt)*

keycloak-js mỗi tab 1 instance, 1 refresh token **riêng** → không còn hiện tượng 2 tab dùng chung RT → `REFRESH_LOCK` + `exclusiveRefresh` (`keycloak.ts:110-165`) thành **dead code**.

**Đề xuất:** giữ nguyên tới khi Phase 3 verify xong, xóa ở commit dọn dẹp riêng.
**Không xóa trước** — nếu Phase 3 phải rollback thì mất luôn protection vừa build.

### D10 ⏳ — Forced change *(chưa chốt)*

Trong luồng redirect, Keycloak tự hiện trang `UPDATE_PASSWORD` cho user có required action → form 2-field của FE (`LoginPage.tsx:139-170`) thành thừa.

**Lợi kép:** trang login gốc của Keycloak **chắc chắn** enforce password policy → nhánh forced-change không còn phụ thuộc kết quả probe P2-2c.

**Đề xuất:** xóa nhánh forced-change + i18n keys liên quan. **Modal tự nguyện (header menu) giữ nguyên** — vẫn qua gateway.

### D11 ✅ — Gateway xác minh `currentPassword`

Bước 2 của `POST /api/v1/account/change-password` là ROPC trên `web-grading-fe`. Tắt direct grants trên client đó = endpoint hỏng.

**Chọn A:**
- Tạo client **`wgs-password-verify`** — confidential, Direct Access Grants ON, secret chỉ nằm trong secret của gateway.
- Thêm property `passwordClientSecret` vào `KeycloakAdminProperties` + gửi `client_secret` trong `passwordGrantForm`.
- Env: `KEYCLOAK_PASSWORD_CLIENT_ID=wgs-password-verify`, `KEYCLOAK_PASSWORD_CLIENT_SECRET=<mới>`.
- **~10 dòng Java + test + wiring env/secret** (`setup-namespace.sh`, `config-services/api-gateway/templates/deployment.yaml`, `values-stg.yaml`, `.env.example`).

### D12 ✅ — Logout — chốt 2026-10-03: **phương án B, `keycloak.logout()` full-page**

- Bỏ XHR revoke fire-and-forget: cookie SSO vẫn sống → sau logout, lần `/login` kế
  tiếp bị AuthGate bounce thẳng vào app (người dùng không đăng nhập tài khoản khác được).
- `logout()` gọi `keycloak.logout({ redirectUri: <origin>/login })` (default
  `logoutMethod=GET` → `location.replace` với `client_id` + `id_token_hint` +
  `post_logout_redirect_uri`). keycloak-js luôn thêm scope `openid` nên `id_token` có
  cho `id_token_hint`. KHÔNG gọi `clearSession()` trước — `keycloak.clearToken()` sẽ
  làm mất `idToken` khi đang dựng URL.
- Realm: client attribute `post.logout.redirect.uris = http://localhost:5173/*`
  (thiếu thì Keycloak hiện trang "logged out" của nó, không quay về app).
- Session terminate cũng revoke token trong session → verify #9 vẫn đúng; access
  token đã phát hành sống tối đa 300s như cũ.

---

## 4. Cấu hình Keycloak (P3-1, runtime)

Client `web-grading-fe` — sửa trên realm **live**:
```
publicClient: true
standardFlowEnabled: true
directAccessGrantsEnabled: false      ← ĐÃ LÀM 2026-10-03, TRƯỚC khi deploy (user chấp
                                         nhận cửa sổ 502 cho gateway cluster; verify dứt
                                         điểm = curl §10.4 sau deploy)
attributes: {                          ← KHÔNG có field pkceMethod top-level
  "pkce.code.challenge.method": "S256",              # body pkceMethod → 400 (2026-10-03)
  "post.logout.redirect.uris": "http://localhost:5173/*"   # D12 full-page logout
}
redirectUris: ["http://localhost:5173/*"]     ← dev-only theo chốt ở §2.7
webOrigins: ["http://localhost:5173"]         ← KHÔNG dùng "*" khi có credentials
                                                (đã vấp 2026-10-01, xem frontend-keycloak-login.md:131)
```
> ⚠️ **Khi deploy FE sau phải bổ sung origin prod vào `redirectUris` + `webOrigins` NGAY**,
> không là login quay về không được. Ghi vào runbook như 1 checklist item.

- Tạo client `wgs-password-verify` (confidential, direct ON, secret).
- Thêm `frontend-src/web-grading-system-fe/public/silent-check-sso.html` (keycloak-js mặc định đọc path này).

### Realm export (P3-1 kèm)
- **Export lại realm** — bản hiện tại thiếu `web-grading-fe` → không phải mirror.
- Dọn `secret` của `wgs-user-service` khỏi export (P2-0 đã ghi).
- Kiểm tra `wgs-postman`: `redirectUris: ['*']` + `webOrigins: ['+']` + direct ON → doc ghi *"có sẵn, chưa dùng cho FE"* nhưng **chưa xác nhận** còn dùng cho API test không → nếu không thì thu hẹp hoặc xóa.

---

## 5. Phân đoạn thực thi

```
0. [blocker]  Phase 1 runbook §3–§6  +  Phase 2 runbook §9  chạy xong
1. [blocker]  chốt D9, D10, D12
2. P3-1  cấu hình Keycloak (client + redirect + silent-check) + export lại realm
3. P3-2  code FE:
         - viết lại `keycloak.ts` quanh `keycloak-js`, GIỮ NGUYÊN export:
           keycloakLogin→login, refreshSession, getSession, clearSession, logout,
           isSessionExpired, type Role/AuthSession
           → `http.ts` / `identity.ts` / `RequireIdentity` / `RequireRole` KHÔNG đổi
         - bootstrap async gate ở `main.tsx`/`router` (chưa init xong thì không render route)
         - nếu D10 chốt: xóa nhánh forced-change + i18n keys
         - bỏ `AUTH_KEY` / `persist()` / `decodeJwt` (theo D8-A)
4. P3-3  gateway: thêm `passwordClientSecret` (D11) + test + wiring env/secret
5. P3-4  bật Direct Access Grants OFF trên `web-grading-fe`
         (CHỈ SAU khi P3-3 deploy xong — không là endpoint đổi MK trả 502)
6. P3-5  verify E2E  →  nếu D9 chốt: dọn Web Lock Phase 2
```

**Thứ tự 4 → 5 là bắt buộc**, không đảo.

---

## 6. Verify

| # | Check | Chứng minh |
|---|---|---|
| 1 | `npm run build` + `npm run lint` | pass |
| 2 | `./mvnw test` (gateway) | 43+ (D11=A → có test mới cho `client_secret`) |
| 3 | **Không còn `grant_type=password` trong `dist/assets/*.js`** | **R3** |
| 4 | **`localStorage['wgs.auth']` không tồn tại / không chứa token** | **R4** |
| 5 | Login → redirect Keycloak → quay lại app có role | luồng mới (D7) |
| 6 | **Reload trang** → không bị đá về `/login` (D8-A) hoặc chỉ nháy redirect (fallback) | bootstrap gate |
| 7 | 401 → tự refresh → request chạy tiếp | interceptor giữ nguyên |
| 8 | 2 tab cùng user, thao tác song song | không đá nhau |
| 9 | Logout → refresh token cũ dùng lại **fail** | revoke vẫn chạy |
| 10 | User có mật khẩu tạm → Keycloak hiện `UPDATE_PASSWORD` | D10 |
| 11 | Đổi MK tự nguyện qua modal → `204`; MK yếu → `400 weak_password` | gateway còn sống |
| 12 | Student vào `/classes` → `/no-role`, không logout | role gate không đổi |

---

## 7. Rủi ro / điểm mở

| # | Rủi ro | Xử lý |
|---|---|---|
| 1 | **Silent SSO iframe bị third-party cookie chặn** (Chrome, Safari ITP) → reload mất session | D8-A đã kèm fallback `silentCheckSsoRedirect: false` |
| 2 | Origin FE khi deploy → `redirectUris` dev-only | ✅ đã chốt (chưa deploy); runbook ghi checklist "bổ sung origin prod khi deploy" |
| 3 | Tắt direct grants trước khi D11 deploy → endpoint đổi MK 502 | thứ tự §5 bước 4 → 5 |
| 4 | Xóa Web Lock Phase 2 trước khi verify → mất protection nếu rollback | D9: giữ tới khi xong |
| 5 | Export realm không mirror → re-import là hỏng app | export lại ở P3-1 |
| 6 | FE không có test runner → hồi quy chỉ phát hiện bằng tay | §6 bắt buộc chạy đủ 12 mục |
| 7 | D9/D10/D12 chưa chốt | blocker ở §5 bước 1 |

---

## 8. Docs & skills (rule bắt buộc, làm cùng lúc)

- `.opencode/plan/` + `docs/design/keycloak-password-gateway-plan-2026-10-03-v1.md` §Phase 3 → ghi D7–D12
- `docs/design/frontend-keycloak-login.md` §7 → **sửa sketch sai** (confidential → public+PKCE) + bổ sung D11
- `docs/design/usecase-flows.md` → luồng login + forced change đổi (D7/D10) → **phải cập nhật**
- `docs/guide/PASSWORD-GATEWAY-RUNBOOK.md` → thêm §10 (P3-1..P3-5) + checklist origin prod
- `.opencode/skills/react-frontend-antd/SKILL.md` + `.kilo/` → keycloak-js init/bootstrap gate pattern
- `.opencode/skills/keycloak/SKILL.md` + `.kilo/` → client config PKCE + direct-grants dependency của gateway
- 2 cây skills phải `diff -r` CLEAN

---

## 9. Không làm

- Không sửa R10 (FE role parsing) — đã ghi là wontfix.
- Không thêm dependency ngoài `keycloak-js`.
- Không đổi contract API gateway.
