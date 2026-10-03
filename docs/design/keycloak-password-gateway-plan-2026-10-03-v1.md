# Phase 1 — Chuyển đổi mật khẩu sang API Gateway + revoke logout + rate limit

> **Status:** CODE COMPLETE — **verify runtime CHƯA CHẠY**. Duyệt + thực thi 2026-10-03.
> **Đã làm:** BE (8 file mới + 3 sửa, `./mvnw test` 43 tests xanh) · FE (`npm run build` +
> `npm run lint` PASS, i18n 154 keys parity) · deploy config · docs/skills · realm export
> `bruteForceProtected: true`.
> **CHƯA verify:** bật brute force runtime, tạo secret, deploy, E2E — toàn bộ lệnh nằm ở
> `docs/guide/PASSWORD-GATEWAY-RUNBOOK.md` (cluster đang down). Không coi là verified.
> **Sửa sau khi BE xanh:** lookup đổi sang `?email=` khi input chứa `@` và match **exact**
> (trước đó modal hỏng với mọi user, và `users[0]` có thể chọn nhầm account khác) —
> xem UC-14.
> Scope: `frontend-src/web-grading-system-fe` (FE) · `src-services/api-gateway` (BE) · Keycloak realm `ptit-wgs` · `deploy/` + `config-services/api-gateway` (hạ tầng).
>
> Lưu ý repo: `src-services/` là **git repo riêng** (bị gitignore ở `.gitignore:27`) → commit BE và commit deploy/docs nằm ở 2 repo khác nhau.

---

## 1. Mục tiêu

1. **Đưa `VITE_KEYCLOAK_ADMIN_CLIENT_SECRET` ra khỏi FE** (R1/R2 Critical): endpoint đổi mật khẩu chạy ở gateway, secret nằm trong K8s Secret.
2. **Logout phải revoke** Keycloak session (R5): hiện `logout()` chỉ `localStorage.removeItem`, refresh token sống tới 10h.
3. **Rate limit cho endpoint không cần xác thực** — Valkey (managed) + Keycloak brute force, cả hai.

Không làm trong lần này: `keycloak-js` + PKCE (Phase 3), hardening realm còn lại (Phase 2).

---

## 2. Quyết định đã chốt (và bằng chứng)

| # | Quyết định | Bằng chứng |
|---|---|---|
| **D1** | Endpoint đặt ở **api-gateway**, không phải `wgs-user-service` | `wgs-user-service` backend **không tồn tại** trong `src-services/` (chỉ có api-gateway, course, executor, result, submission). Route tới nó ở `application-local.yaml:36-40` dùng prefix **cũ** `spring.cloud.gateway.routes` → **config chết**: decompile `spring-cloud-gateway-server-webflux-5.0.2` cho `GatewayProperties.PREFIX = "spring.cloud.gateway.server.webflux"`, không class nào chứa hằng `spring.cloud.gateway.routes`. |
| **D2** | Dùng **`@RestController` + Service**, không dùng `GlobalFilter` | `AuthenticationContextFilter` là `GlobalFilter` → **chỉ chạy cho routed request**. Endpoint này do `DispatcherHandler` xử lý. |
| **D3** | Path `/api/v1/account/change-password` | Không route nào match (`application.yaml:16-28` chỉ có classes/assignments/docker-images/student, submissions, results). An toàn thêm nữa: `RoutePredicateHandlerMapping` order mặc định = **1** (bytecode `iconst_1`), `RequestMappingHandlerMapping` = 0 → controller thắng kể cả khi path trùng route. |
| **D4** | Endpoint **không cần Bearer** và **không được trả 401** | Luồng forced-change không có token (password grant thất bại). Trả 401 → `http.ts:98` trigger silent refresh → redirect `/login` → loop. |
| **D5** | Verify mật khẩu hiện tại **bằng password grant**, **trước** khi lookup user | `loginWithEmailAllowed: True` → dùng được email làm username. Verify trước → chưa chứng minh MK thì không enumerate được. Cùng 1 mã lỗi `current_password_invalid` cho "sai MK" và "không tồn tại user". |
| **D6** | Luồng forced-change **tự động dùng mật khẩu vừa gõ** ở form đăng nhập (form giữ 2 ô) | Password chỉ nằm trong React state của đúng luồng đó, không persist. Tránh bắt user gõ lại mật khẩu tạm 2 giây trước. |
| **D7** | Rate limit: **Valkey (managed online) + Keycloak brute force, cả hai** | Keycloak brute force (per-user) chặn đoán password cho 1 tài khoản; limiter per-IP+username chặn **quét lan nhiều username** (mỗi user 1 lần → không ai đạt `failureFactor: 30` → không ai bị lock, nhưng attacker vẫn có oracle). Hai cơ chế không trùng nhau. |
| **D8** | **Không** chuyển login (ROPC) sang gateway | `web-grading-fe` là **public client → không có client secret để giấu**. Chuyển ROPC vào gateway không giảm rủi ro (password vẫn đi qua JS của FE) mà chỉ thêm 1 hop. Thứ cắt được R3/R4 là PKCE (Phase 3). |
| **D9** | Rate limiter **không** dùng `RedisRateLimiter` có sẵn của Spring Cloud Gateway | Nó là `GatewayFilter` → chỉ chạy cho routed request (xem D2). Phải tự viết logic Valkey. |

---

## 3. Risk register

| # | Rủi ro | Bằng chứng | Sev | Sửa ở |
|---|---|---|---|---|
| R1 | Admin client secret trong FE bundle → reset mật khẩu mọi user = account takeover | `.env.development.local` `VITE_KEYCLOAK_ADMIN_CLIENT_SECRET` | **Critical** | **Phase 1** |
| R2 | Cùng secret có role `manage-users` → tạo/sửa/xóa user | roles đã verify: `manage-users, view-users, query-users, query-groups, create-client` | **Critical** | Phase 1 |
| R3 | FE nhận mật khẩu qua JS (password grant) → XSS đọc được password | `keycloak.ts:77 keycloakLogin` | High | Phase 3 |
| R4 | Access + refresh token trong `localStorage` → XSS ăn cắp session ≤ 10h | `keycloak.ts:12 AUTH_KEY`; `ssoSessionMaxLifespan: 36000` | High | Phase 3 |
| R5 | Logout không revoke → refresh token vẫn sống | `keycloak.ts:161` chỉ `clearSession()`; realm `revokeRefreshToken: False` | High | **Phase 1** |
| R6 | Không brute force → oracle dò password | realm `bruteForceProtected: False` | High | **Phase 1** |
| R7 | Không có password policy server-side | realm `passwordPolicy: None` | Medium | Phase 2 |
| R8 | Admin console `admin/admin`, Keycloak public qua Cloudflare | `.env:44`; `deploy/setup-namespace.sh:69` (default `admin`) | High | Phase 2 (user) |
| R9 | Refresh token không rotate | `revokeRefreshToken: False`, `refreshTokenMaxReuse: 0` | Medium | Phase 2 (⚠️ test multi-tab) |
| R10 | FE tự parse role từ JWT | `identity.ts` | Low — server vẫn enforce `@PreAuthorize` + `X-User-Roles` | Không sửa |
| R11 | CORS Keycloak Admin API từ browser | Web Origins = `http://localhost:5173` (không phải `*`) | Low | Tự hết khi R1 xong |
| R12 | `GATEWAY_TRUSTED_SECRET` để rỗng → `setup-namespace.sh` random, không persist | `.env:45` rỗng; script dòng 45-46 | Medium | Quy trình: phải set sẵn |

### Những điều phân tích bên ngoài nêu nhưng **không có bằng chứng**

- *"Token quá lớn làm `IndexOutOfBoundsException` ở service cấp dưới"* — **đã grep**: không service nào (`course`/`result`/`submission`) đọc header `Authorization`. Downstream chỉ nhận `X-User-Id` / `X-User-Roles` / `X-Gateway-Secret`.
- *"Phải mở Web Origins: `*`"* — thực tế cấu hình là `http://localhost:5173`; Keycloak cũng không cho `*` kèm credentials.
- *"BFF làm token nhỏ lại"* — không đúng với kiến trúc này: FE vẫn phải nhận access token để gateway validate JWT mỗi request. Token thêm `sub` + `auth_time` sau fix chỉ ~100 byte.
- *"Forward vào mạng nội bộ Cluster"* — **deployed đã đúng** (`values-stg.yaml` → `serviceUris.course: http://grading-course-service:8081`). Chỉ dev local mới ra tunnel public, và đó là chủ đích (máy dev không có DNS in-cluster).

---

## 4. API contract

```
POST /api/v1/account/change-password          ← KHÔNG cần Bearer, KHÔNG được trả 401
Content-Type: application/json
{
  "username": "lecturer_test",       // hoặc email — realm loginWithEmailAllowed=true
  "currentPassword": "...",
  "newPassword": "..."
}

204  No Content                                              → OK
400  {"status":400,"message":"current_password_invalid","data":null}   // sai MK HOẶC không tồn tại user — CÙNG code
400  {"status":400,"message":"weak_password","data":null}              // Keycloak policy từ chối
400  {"status":400,"message":"validation_failed","data":null}          // thiếu field
429  {"status":429,"message":"rate_limited","data":null}
502  {"status":502,"message":"identity_provider_unavailable","data":null}
```

- Envelope `{"status","message","data"}` khớp `ENVELOPE_KEYS` ở `frontend-src/web-grading-system-fe/src/shared/api/http.ts:7`.
- `message` là **mã máy** → FE map sang i18n (giữ parity vi/en, không show tiếng Anh thô).

---

## 5. Server flow (reactive, `WebClient`)

```
1. Rate limit (Valkey)
   key = "rl:pwd:" + ip + ":" + lowercase(username)
   INCR key; nếu result == 1 → EXPIRE key window
   count > max → 429 rate_limited

2. VERIFY current password
   POST {issuer}/protocol/openid-connect/token
     grant_type=password, client_id=web-grading-fe (public client — KHÔNG cần secret)
   - 200                                              → mật khẩu đúng
   - error_description ∋ "Account is not fully set up" → mật khẩu ĐÚNG (đang forced change) → đi tiếp
   - invalid_grant / "Invalid user credentials"        → 400 current_password_invalid
   - lỗi mạng/Không reaches Keycloak                    → 502 identity_provider_unavailable
   ⚠️ KHÔNG persist token (không đè phiên hiện tại + refresh token)

3. Lookup user
   GET {adminBase}/admin/realms/{realm}/users?username={urlencoded}
   (service account wgs-user-service)
   - rỗng → 400 current_password_invalid      // CÙNG code với bước 2 → không enumerate

4. Đổi mật khẩu
   PUT {adminBase}/admin/realms/{realm}/users/{id}/reset-password
   body FLAT: {"type":"password","value":"<new>","temporary":false}
   ⚠️ KHÔNG bọc trong "credential" → 400 nếu bọc
   - 204 → trả 204
   - khác → 502 identity_provider_unavailable
```

**Thứ tự bắt buộc**: verify (bước 2) **trước** lookup (bước 3).

---

## 6. Task list

### 6.1 Keycloak realm config (làm trước — có hiệu lực bảo vệ ngay)

```
GET /admin/realms/ptit-wgs  →  set bruteForceProtected=true  →  PUT lại
```

- **Bắt buộc pattern GET → sửa field → PUT** (PUT realm là *full replace*, PUT body rời rạc sẽ xoá config khác).
- Giữ nguyên `failureFactor: 30`, `permanentLockout: false`, `maxFailureWaitSeconds: 900` → lock tạm, không vĩnh viễn.
- ⚠️ **DoS lên tài khoản nạn nhân**: ai cố nhập sai 30 lần sẽ lock người đó ~15 phút. Chấp nhận được với `permanentLockout=false`, phải ghi vào docs.
- ⚠️ Khi E2E test nhập sai nhiều lần sẽ tự lock `lecturer_test` → chờ hết hạn hoặc reset qua admin.

### 6.2 Backend — `src-services/api-gateway` (repo git riêng)

**File mới:**

| File | Nội dung |
|---|---|
| `config/KeycloakAdminProperties.java` | record `@ConfigurationProperties(prefix = "keycloak.admin")` — `issuerUri`, `adminClientId`, `adminClientSecret`, `passwordClientId`. Bind từ env. **KHÔNG dùng `@Value`** (rule dự án). `issuerUri` derive từ `KEYCLOAK_ISSUER_URI` đã có ở `application.yaml:11` → không thêm config URI mới. Javadoc + `Review: 2026-10-03` theo rule comment. |
| `config/RateLimitProperties.java` | record `@ConfigurationProperties(prefix = "rate-limit")` — `enabled`, `maxAttempts`, `windowSeconds` |
| `web/ChangePasswordRequest.java` | record 3 field + `@NotBlank` (Jackson construct — tránh `new X(a,b,c)` ở call site) |
| `web/ApiEnvelope.java` | record `{status, message, data}` + static factory `error(...)` |
| `web/ChangePasswordController.java` | `@RestController` → `Mono<ResponseEntity<Void>>`; validate `@Valid` |
| `service/PasswordChangeService.java` | flow 4 bước ở §5; khai báo interface `KeycloakAdminClient` bên trong hoặc file riêng để mock khi test |
| `service/KeycloakAdminClient.java` | wrapper `WebClient` cho 3 call Keycloak (verify ROPC, lookup, reset) |
| `service/ValkeyRateLimiter.java` | xem §6.3 |

**Sửa file có sẵn:**

| File | Sửa |
|---|---|
| `config/SecurityConfig.java:17-21` | thêm `"/api/v1/account/**"` vào `PUBLIC_PATHS` + comment **lý do** (thiếu → 401 → `http.ts:98` refresh-loop) |
| `application.yaml` | thêm section `keycloak.admin` + `rate-limit` với `${...}` placeholder; thêm `spring.data.redis.url` |
| `pom.xml` | thêm `spring-boot-starter-data-redis` |

**Test** (`src/test/...`): sai MK → 400 `current_password_invalid` · `Account is not fully set up` → đi tiếp → 204 · lookup rỗng → 400 **cùng code** · thiếu field → 400 · vượt rate limit → 429 · Valkey down → fail-open (204) · admin reset fail → 502.

### 6.3 Valkey rate limiter (managed online — chỉ kết nối)

**Quyết định: D7 + D9** — dùng service Valkey online, tự viết ~40 dòng, không dùng `RedisRateLimiter` của gateway.

- **Dependency**: `spring-boot-starter-data-redis` (Lettuce) — speaking RESP nên tương thích Valkey. Không thêm thư viện thứ ba.
- **Config** (tất cả qua `@ConfigurationProperties`, không `@Value`):

```yaml
spring:
  data:
    redis:
      url: ${VALKEY_URL:}
      timeout: 200ms          # fail-fast để fail-open không làm chậm request

rate-limit:
  enabled: ${RATE_LIMIT_ENABLED:false}
  max-attempts: ${RATE_LIMIT_MAX_ATTEMPTS:10}
  window-seconds: ${RATE_LIMIT_WINDOW_SECONDS:300}
```

- **Algorithm**: fixed window — `INCR` rồi `EXPIRE` khi `result == 1`. Không dùng sliding window/ZSET (over-engineering cho 1 endpoint).
- **Key**: `rl:pwd:{ip}:{lowercase(username)}`.
- **IP lấy từ**: `X-Forwarded-For` hop đầu (traffic đi qua tunnel/ingress) → fallback `remoteAddress`. ⚠️ Ghi chú trong code: XFF spoofable nếu gateway bị gọi trực tiếp → **primary protection vẫn là Keycloak brute force**.
- **Fail-open**: Valkey lỗi / `enabled=false` → **cho qua request**, log `ERROR` 1 lần (dùng `AtomicBoolean` như pattern `SECRET_WARNED` ở `AuthenticationContextFilter.java:51`). Lý do: không để sự cố cache làm sập luồng đổi mật khẩu; Keycloak brute force vẫn bảo vệ.
- **Local dev**: `RATE_LIMIT_ENABLED=false` (không cần kết nối Valkey); nếu muốn thì trỏ cùng instance online.
- **Secret**: tạo secret `valkey-conn` (key `VALKEY_URL`) trong `deploy/setup-namespace.sh` theo pattern `gateway-trust` / `keycloak-db`; `config-services/api-gateway/templates/deployment.yaml` thêm `env` `secretKeyRef`.
- **Lưu ý multi-pod**: hiện `config-services/api-gateway/templates/deployment.yaml:8` hardcode `replicas: 1`. Khi scale ≥2 thì Valkey + Keycloak brute force đều tập trung → vẫn đúng. Không cần thay đổi gì thêm.

### 6.4 Deploy / secret

| File | Nội dung |
|---|---|
| `deploy/setup-namespace.sh` | secret mới `keycloak-admin-client` (2 key `KEYCLOAK_ADMIN_CLIENT_ID`, `KEYCLOAK_ADMIN_CLIENT_SECRET`) + secret `valkey-conn` (`VALKEY_URL`). **Bắt buộc đọc từ `.env`, không để rỗng** (lesson từ R12). |
| `.env.example` | thêm `KEYCLOAK_ADMIN_CLIENT_ID`, `KEYCLOAK_ADMIN_CLIENT_SECRET`, `VALKEY_URL` + ghi chú phải persist |
| `config-services/api-gateway/templates/deployment.yaml` | thêm 3 `env` `secretKeyRef` |

### 6.5 Frontend — `frontend-src/web-grading-system-fe`

| File | Thay đổi |
|---|---|
| `src/shared/api/endpoints/account.ts` | **Mới** — `changePassword({username, currentPassword, newPassword})` → `sendData<void, ...>('/api/v1/account/change-password', 'post', body)` |
| `src/shared/auth/keycloak.ts` | **Xóa** `keycloakChangePassword` (dòng 166-221). **Thêm revoke logout**: `POST {AUTHORITY}/protocol/openid-connect/logout` body `client_id` + `refresh_token` (public client, **không cần admin secret**), fire-and-forget `.catch(() => {})` **trước** `clearSession()`. Vẫn nằm trong file này vì header dòng 9 cam kết đây là module duy nhất talk tới token endpoint. |
| `src/features/auth/LoginPage.tsx` | **Xóa** block admin inline (dòng 45-73). Thêm `const [loginPassword, setLoginPassword] = useState('')`; ở `onFinish` khi bắt được `must_change_password` → `setLoginPassword(password)` (D6). `onPasswordChange` → `changePassword({username: loginUsername, currentPassword: loginPassword, newPassword})`. Form **giữ 2 ô**. Sau success: `setLoginPassword('')` + `setMustChangePassword(false)` + `setError(t('auth.passwordChanged'))`. Map lỗi `current_password_invalid` → `t('auth.currentPasswordWrong')`, còn lại → `useApiErrorMessage()`. |
| `src/features/auth/ChangePasswordModal.tsx` | **Mới** — antd `Modal` + `Form` 3 ô, clone pattern `src/features/classes/CreateClassModal.tsx`. Dùng `App.useApp()` (đã bọc `<AntdApp>` ở `src/app/providers.tsx`) — **không** static `message.*`. `username` = `session.email`. Rules: `currentPassword` required; `newPassword` required + `{min: 8, message: t('auth.passwordTooShort')}`; `confirmPassword` validator so với `newPassword`. Success → `message.success(t('auth.changePasswordSuccess'))` + `form.resetFields()` + `onClose()`, **ở lại app**. |
| `src/shared/layout/AppLayout.tsx` | Thêm `KeyOutlined` (import dòng 1). `const [changePwdOpen, setChangePwdOpen] = useState(false)`. Dropdown items (dòng 165-167): `{key:'change-password', icon:<KeyOutlined/>, label:t('nav.changePassword')}` → `{type:'divider'}` → `{key:'logout', ...}`. `handleUserMenu` (dòng 43) thêm nhánh `change-password`. Render `<ChangePasswordModal open onClose />`. |
| `src/locales/vi.json` + `en.json` | **7 key mới, cùng thứ tự, cả 2 file** (147 → 154) |
| `.env.development.local` | **Xóa** `VITE_KEYCLOAK_ADMIN_URI`, `VITE_KEYCLOAK_ADMIN_CLIENT_ID`, `VITE_KEYCLOAK_ADMIN_CLIENT_SECRET` |

**7 key i18n:**

| key | vi | en |
|---|---|---|
| `nav.changePassword` | Đổi mật khẩu | Change password |
| `auth.currentPassword` | Mật khẩu hiện tại | Current password |
| `auth.currentPasswordPlaceholder` | Nhập mật khẩu hiện tại | Enter current password |
| `auth.currentPasswordWrong` | Mật khẩu hiện tại không đúng. | Current password is incorrect. |
| `auth.passwordMismatch` | Mật khẩu xác nhận không khớp. | Passwords do not match. |
| `auth.passwordTooShort` | Mật khẩu phải có ít nhất 8 ký tự. | Password must be at least 8 characters. |
| `auth.changePasswordSuccess` | Đổi mật khẩu thành công. | Password changed successfully. |

Không dùng lại `auth.passwordChanged` cho modal — text hiện tại là *"Bạn có thể đăng nhập bằng mật khẩu mới"*, hợp luồng forced-change, **không** hợp thao tác tự nguyện.

### 6.6 Rotate secret sau khi ship

`wgs-user-service` client secret từng nằm trong bundle FE + `.env` → **regenerate** sau khi Phase 1 lên production, cập nhật `VITE_KEYCLOAK_ADMIN_CLIENT_SECRET`... không, biến đó đã bị xóa. Cập nhật: `.env` (nếu có dùng cho script), secret `keycloak-admin-client` trong k8s, và `.env.development.local` nếu dev vẫn cần.

---

## 7. Verify

**Build / test:**
1. `mvn test` trong `src-services/api-gateway` (confirm `./mvnw` hay `mvn` lúc chạy)
2. `npm run build` (= `i18n:check` + `tsc -b` + `vite build`) trong `frontend-src/web-grading-system-fe`
3. `npm run lint`

**E2E (dev local):**
- [ ] `curl -X POST localhost:8080/api/v1/account/change-password` với body hợp lệ → **không 404** (verify điều đã decompile: controller order 0 vs route order 1). Fallback nếu fail: dùng `RouterFunction` (order `-1`) hoặc set `spring.cloud.gateway.server.webflux.handler-mapping.order`.
- [ ] Header → Đổi mật khẩu → sai MK hiện tại → toast lỗi, **Network không có call nào tới Keycloak admin**
- [ ] MK mới <8 → rule FE chặn; confirm lệch → rule chặn
- [ ] Đổi hợp lệ → toast success → **logout → login bằng MK mới** → `/classes`
- [ ] Forced flow: login bằng MK tạm → form **2 ô** → đổi → login MK mới
- [ ] **R5 (chứng minh revoke chạy thật)**: logout → lấy `refresh_token` cũ khỏi `localStorage['wgs.auth']` → `POST /token grant_type=refresh_token` → **phải fail**
- [ ] **R6**: nhập sai MK nhiều lần → Keycloak lock tạm
- [ ] **Rate limit**: bật `RATE_LIMIT_ENABLED=true` + `VALKEY_URL` → gửi 11 request sai MK → request thứ 11 → 429 `rate_limited`
- [ ] **Fail-open**: tắt `VALKEY_URL` + `enabled=true` → request vẫn qua (không 500), log ERROR 1 lần

---

## 8. Docs & skills (rule bắt buộc)

| File | Nội dung |
|---|---|
| `docs/design/usecase-flows.md` | **Thêm flow mới** "Đổi mật khẩu (header + forced)" — numbered steps, method + path + body example, preconditions, expected response (format sẵn) |
| `docs/api/API-TEST-GUIDE.md` | curl cho endpoint mới + case 429 |
| `docs/design/frontend-keycloak-login.md` | Cập nhật: FE không còn gọi Admin API; logout có revoke |
| `docs/design/keycloak-password-gateway-plan-2026-10-03-v1.md` | File này — đánh dấu status khi xong |
| `.opencode/skills/keycloak/SKILL.md` **+** `.kilo/skills/keycloak/SKILL.md` | **Tạo mới** (2 bản identical) cho realm-side: `basic` client scope → `sub`, brute force, password policy, refresh rotation, service account roles, admin creds, PUT realm = full replace |
| `.opencode/skills/react-frontend-antd/SKILL.md` **+** `.kilo/...` | Cập nhật §5: FE không còn `VITE_KEYCLOAK_ADMIN_*` + `keycloakChangePassword`; thêm 1 dòng trỏ sang skill `keycloak` để tránh trùng lặp gây drift |
| `.opencode/skills/java-spring-boot-backend/SKILL.md` **+** `.kilo/...` | (nếu có pattern endpoint mới đáng ghi: envelope từ gateway, `PUBLIC_PATHS`) |

**Rule**: mọi file skill phải cập nhật ở **cả 2 chỗ** `.opencode/skills/` và `.kilo/skills/`, `diff` phải clean.

---

## 9. Deferred — KHÔNG làm lần này

### Phase 2 (config, 0 code, ~1h)
1. **Đổi mật khẩu admin console** (`admin/admin` → mạnh) — cập nhật `.env` + secret `keycloak-db`. Keycloak public qua Cloudflare nên đây là cửa ngõ thật.
2. `passwordPolicy: "length(8)"` → rule FE min-8 không còn là ranh giới duy nhất.
3. `revokeRefreshToken: true` + `refreshTokenMaxReuse: 0` → rotate mỗi lần refresh. ⚠️ **Bắt buộc test multi-tab trước**: 2 tab refresh cùng 1 token → token bị revoke → đá 1 tab. FE có dedup trong-tab (`refreshPromise`) nhưng cross-tab chưa có.
4. Chặn `/admin/**` bằng Cloudflare Access / WAF rule.

### Phase 3 — `keycloak-js` + authorization code + PKCE

**Nguồn sự thật: `.opencode/plan/phase-3-pkce.md`** (2026-10-03) — phân đoạn P3-1..P3-5,
bằng chứng, risk register, ma trận verify 12 mục; runtime commands ở runbook **§10**.
Quyết định đã chốt **D7–D12** (file đó §0/§3):

- **D7** — login = redirect toàn trang sang `keycloak.login()` (PKCE không giữ được form
  password trong FE) → **R3** cắt thật, Keycloak tự hiện trang `UPDATE_PASSWORD`.
- **D8** — token **memory-only** (`localStorage['wgs.auth']` biến mất) + `check-sso` iframe,
  fallback redirect khi iframe bị chặn → **R4** cắt thật.
- **D9** ⏳ Web Lock Phase 2 — giữ tới khi Phase 3 verify xong, **chưa chốt**.
- **D10** ⏳ Xóa nhánh forced-change của FE (Keycloak tự hiện `UPDATE_PASSWORD`),
  modal tự nguyện giữ nguyên — **chưa chốt**.
- **D11** ✅ — gateway **không** dùng `web-grading-fe` cho ROPC xác minh `currentPassword`
  nữa: client riêng confidential **`wgs-password-verify`** + property `passwordClientSecret`
  (`KeycloakAdminProperties`), secret chỉ nằm trong K8s Secret của gateway.
- **D12** ⏳ logout (giữ XHR revoke + `clearToken()` hay redirect `keycloak.logout()`) —
  **chưa chốt**.

⚠️ Sửa so với ghi nhận cũ: *"tắt direct access grants trên `web-grading-fe` → ROPC biến mất
hoàn toàn"* **sai một nửa** — ROPC của gateway vẫn tồn tại (D11), chỉ client của trình duyệt
mất direct grants. Vì vậy thứ tự **bắt buộc**: deploy thay đổi gateway (P3-3) **TRƯỚC** khi
tắt direct grants (P3-4), không là endpoint đổi mật khẩu trả 502.

`keycloak.ts` vẫn là seam duy nhất đổi permutation; `identity.ts` / `http.ts` ít đổi.

### Việc lẻ (không gộp)
- Route chết `spring.cloud.gateway.routes` (prefix cũ) trong `application-local.yaml:18-41` — cần migrate sang `spring.cloud.gateway.server.webflux.routes` hoặc xóa.
- Cân nhắc giới hạn `/admin/**` của Keycloak.

---

## 10. Rủi ro còn lại sau Phase 1 (không được quên)

- **R3 + R4 vẫn còn** — password vẫn đi qua JS, token vẫn trong `localStorage`. Chỉ Phase 3 cắt được.
- **Access token đã phát hành vẫn sống tới 5 phút sau logout** (`accessTokenLifespan: 300`) — revoke chặn refresh, không thu hồi token đang phát hành.
- **Rate limiter fail-open** — khi Valkey down thì không có limit tầng gateway; Keycloak brute force vẫn là primary.
- **Chưa chạy thật** `@RestController` trong gateway (order đã verify bằng bytecode, chưa e2e) → xem fallback ở §7.
- **Chưa test** Keycloak có revoke session hiện tại sau admin reset hay không (mặc định **không**). Contingency nếu bị đá ra: sau success → `clearIdentity()` + `navigate('/login')` + toast bảo đăng nhập lại.
- **Admin secret cũ chưa rotate** → làm sau khi ship (§6.6).
