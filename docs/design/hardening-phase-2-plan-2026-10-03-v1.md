# Phase 2 — Hardening Keycloak & session (không thêm feature)

> **Status:** Phase 1 **code-complete** (BE/FE/deploy/docs/skills xong, runtime chưa verify);
> Phase 2 — quyết định D1–D6 **chốt 2026-10-03**, chưa thực hiện runtime. Viết 2026-10-03.
> Phase 1: `docs/design/keycloak-password-gateway-plan-2026-10-03-v1.md`
> Lệnh runtime: `docs/guide/PASSWORD-GATEWAY-RUNBOOK.md` — **đã có §9 cho Phase 2** (2026-10-03).
>
> **Điều kiện tiên quyết:** Phase 1 phải **verify runtime xong** trước khi làm P2-3 và P2-4.
> Hiện Phase 1 mới code xong, cluster đang down.

---

## 0. Trả lời câu "Phase 1 xong chưa?"

| | Trạng thái |
|---|---|
| Code BE / FE / deploy config / docs / skills | ✅ xong — `./mvnw test` 43 xanh, `npm run build` + `lint` PASS, `diff -r skills` CLEAN |
| **Runtime** (bật brute force, tạo secret, deploy, E2E) | ❌ **chưa chạy** — cluster down, lệnh nằm ở runbook |
| Post-ship bắt buộc: rotate secret `wgs-user-service` | ❌ chưa |

→ **Phase 1 = code-complete, không phải verified-complete.** Không bắt đầu Phase 2 cho tới khi
runbook §3–§6 chạy xong.

---

## 1. Scope

**Làm:** hạ nguy cơ từ R6/R7/R8/R9 + rò rỉ secret còn sót + config chết.
**Không làm:** R3/R4 (password qua JS, token ở `localStorage`) — chỉ Phase 3 (PKCE) cắt được.
**Không thêm:** endpoint mới, dependency mới, service mới. Hầu hết là config Keycloak + 1 quyết định FE.

### Bằng chứng đã thu (không suy đoán)

| Sự kiện | Bằng chứng |
|---|---|
| Keycloak **26.0** | `deploy/keycloak/deployment.yaml:20` → `quay.io/keycloak/keycloak:26.0` |
| Admin console **public** | `deploy/ingress/keycloak.yaml` → `host: web-dev1-keycloak…`, `path: /` (Prefix) → cả `/admin` đi qua Traefik + Cloudflare tunnel |
| `KC_BOOTSTRAP_ADMIN_*` chỉ tạo admin **ở lần boot đầu** | Keycloak 26 doc: *"parses these values at first startup to create an initial user"*; forum confirm *"parsing is only done at the first startup"* → đổi `.env` + restart **không** reset mật khẩu admin đang có |
| Chạy `start-dev` (dev profile) | `deployment.yaml:23` → `args: [start-dev]`; dev profile: HTTP on, strict hostname **off** (mặc định), theme/template cache **tắt** |
| Chưa bật rotation | realm `revokeRefreshToken: false`, `refreshTokenMaxReuse: 0` |
| Lỗi khi replay RT đã dùng | `invalid_grant` + `"Maximum allowed refresh token reuse exceeded"` |
| 2 tab cắn nhau khi bật rotation | Keycloak forum #266: tab1 refresh → tab2 không còn RT hợp lệ → bị đá |
| FE **không** đồng bộ cross-tab | `grep` toàn `src/` → không có `storage` listener, không `BroadcastChannel`; `refreshPromise` (`keycloak.ts:77`) và `isRefreshing` (`http.ts:39`) đều per-tab |
| FE đã enforce min 8 | `ChangePasswordModal.tsx:88` → `{ min: 8, message: t('auth.passwordTooShort') }` |
| Chưa có password policy | realm `passwordPolicy: None` |
| Secret từng nằm trong bundle FE | Phase 1, biến `VITE_KEYCLOAK_ADMIN_CLIENT_SECRET` |
| Export realm chứa secret của client | `src-services/keycloak/ptit-wgs-realm.json` → client `wgs-user-service` có trường `secret` (24 ký tự), **git-tracked** |
| Route prefix cũ chết | `application-local.yaml:16-41` dùng `spring.cloud.gateway.routes`; hằng thật là `spring.cloud.gateway.server.webflux.routes` |
| Tunnel token chưa bị commit | `git log --all --diff-filter=A -- cloudflare_tunnel_run.sh` → rỗng; `.gitignore:35` có `**/cloudflare_tunnel_run.sh` |

---

## 2. Task list

### P2-0 · Rotate secret `wgs-user-service` — **BẮT BUỘC, làm đầu tiên**

Secret này đã ship trong browser bundle → coi như lộ.

1. Admin Console → realm `ptit-wgs` → **Clients** → `wgs-user-service` → **Credentials** → **Rotate**.
2. Cập nhật `.env` → `KEYCLOAK_ADMIN_CLIENT_SECRET=<mới>`.
3. Cập nhật **`src-services/keycloak/ptit-wgs-realm.json`** — client `wgs-user-service` đang mang
   `secret` trong export (git-tracked). **Khuyến nghị: xóa hẳn trường `secret` khỏi export**
   để không phải sync secret trong git nữa; nếu giữ thì phải update đúng giá trị mới.
4. `./deploy/setup-namespace.sh` → roll gateway.
5. Verify: `POST /api/v1/account/change-password` vẫn `204` (gateway đọc đúng secret mới).

⚠️ **Cửa sổ rủi ro:** giữa bước 1 và bước 4, endpoint đổi mật khẩu trả `502`. Làm trong 1 lần,
đừng để qua ngày.
⚠️ Secret **cũ** vẫn còn trong lịch sử git của repo `src-services`. Không tự ý rewrite history
(destructive) — ghi nhận và để người quyết định.

### P2-1 · Đổi mật khẩu admin console (R8 · High)

**⚠️ Bẫy đã xác minh:** `KC_BOOTSTRAP_ADMIN_PASSWORD` (`deployment.yaml:51`) chỉ được đọc lúc
**boot đầu tiên** khi `master` realm chưa tồn tại. Sửa `.env` rồi `kubectl rollout restart`
**không đổi** mật khẩu `admin` hiện tại.

Cách làm đúng:
1. Đăng nhập admin → **Master realm** → **Users** → `admin` → **Credentials** → **Set
   password** (bỏ tick *Temporary*) → Save.
   (Cách CLI tương đương: `kcadm.sh set-password --username admin`.)
2. Cập nhật `.env` → `KEYCLOAK_ADMIN_PASSWORD=<mới>` để script và người vận hành khớp nhau.
3. `./deploy/setup-namespace.sh` (secret `keycloak-db` được tạo lại từ `.env`) + restart pod
   Keycloak. Lưu ý `optional: true` ở 2 env `KC_BOOTSTRAP_*` (`deployment.yaml:50,56`).

Verify: logout → login bằng mật khẩu **mới** OK; mật khẩu cũ `admin` phải **fail**.

### P2-2 · Password policy (R7 · Medium)

**Đã chốt D2 (2026-10-03) — strict.** Chuỗi policy:

```
length(8) and specialChars(1) and upperCase(1) and digits(1) and notUsername
```

Set qua cùng recipe GET → sửa → PUT như runbook §3 (PUT realm là **full replace**).

- **Syntax Keycloak thật:** separator là **` and `** (không phải space, không phải `;`), tên
  provider là `length`, `specialChars`, `upperCase`, `lowerCase`, `digits`, `notUsername`,
  `hashIterations`, `passwordHistory`. Bản draft trước đây ghi sai tên provider
  (`special`, `upper`) và phân cách bằng space — những ID đó không tồn tại.
  Nguồn: Keycloak 26.8 Server Admin Guide, Admin CLI § *Setting a password policy*:
  `kcadm.sh update realms/demorealm -s 'passwordPolicy="hashIterations(300000) and specialChars(2) and upperCase(2) and lowerCase(2) and digits(2) and length(9) and notUsername and passwordHistory(4)"'`
- FE **đã** enforce `min: 8` (`ChangePasswordModal.tsx:88`) → không có regression phía client;
  P2-2b mirror nốt rule special/upper/digit.
- Endpoint Phase 1 **đã** có sẵn mã `400 weak_password` → không cần sửa code (trừ khi probe
  P2-2c trả `204`, xem D5).

⚠️ **Không có rủi ro tự khóa admin console:** `passwordPolicy` là **attribute của realm** —
đặt trên realm `ptit-wgs` thì user `admin` (sống ở realm `master`) **không bị ảnh hưởng**.
Ảnh hưởng thật duy nhất là user realm `ptit-wgs` (giảng viên/sinh viên) bị bắt đặt mật khẩu
đúng cách **tại lần đổi tới**.

⚠️ Policy mới **không** rà lại mật khẩu cũ (*"will not be effective for existing users"*):
`Duongvct@kh02` vẫn dùng được cho tới lần đổi tiếp theo. Muốn bắt buộc đổi thì phải thêm
required action — việc riêng, không gộp.

Verify (probe P2-2c): MK `abcdefgh` (8 ký tự, có hoa/thường/số nhưng **không** ký tự đặc biệt)
→ `400 weak_password` nếu admin reset **enforce** policy; `204` nếu bypass (lúc đó mới code
gateway validate — D5). MK `abc` → `400 weak_password` + FE chặn trước ở bước submit.

### P2-3 · Refresh token rotation (R9 · Medium) — **CẦN QUYẾT ĐỊNH, không tự làm**

Trạng thái hiện tại: `revokeRefreshToken: false` → refresh token sống tới khi session hết
(`ssoSessionMaxLifespan: 36000` = 10h), không xoay.

Bật = `revokeRefreshToken: true` + `refreshTokenMaxReuse: 0` → RT dùng **1 lần duy nhất**.

**Vấn đề đã xác minh ở code FE:** dedup refresh chỉ trong **một tab**
(`refreshPromise` / `isRefreshing`, đều per-module). Không có `storage` listener, không
`BroadcastChannel`. Kịch bản hỏng:

```
Tab A: đọc RT1 từ localStorage → POST /token (đang chạy)
Tab B: đọc RT1 từ localStorage → POST /token (đang chạy)   ← cùng lúc
→ 1 request thành công (RT1 bị thu hồi, phát RT2)
→ request kia fail: invalid_grant "Maximum allowed refresh token reuse exceeded"
→ Tab B: clearSession() → window.location.assign('/login')
```

- **Cùng 1 tab** → an toàn (dedup + persist RT mới ngay).
- **2 tab tuần tự** → an toàn (cùng localStorage, tab sau đọc RT mới).
- **2 tab đồng thời** → 1 tab bị đá. Xác suất thấp nhưng có thật.

| Tuỳ chọn | Việc làm | Ưu | Nhược |
|---|---|---|---|
| **A** | Bật rotation **+** thêm cross-tab lock ở FE (BroadcastChannel hoặc `localStorage` lock có TTL, ~40 dòng) | an toàn, giữ được rotation | thêm code + test mới |
| **B** | Bật với `refreshTokenMaxReuse: 1` (cho dùng lại 1 lần) | không cần code | mở replay window (Keycloak discussion #15590) |
| **C** | Không bật ở Phase 2 | 0 rủi ro UX | giữ nguyên R9 |

**Khuyến nghị: A**, nhưng **chỉ sau khi Phase 1 verify xong**. Nếu muốn Phase 2 thuần config
thì chọn **C** và đẩy rotation sang Phase 3 (lúc đó `keycloak-js` lo vòng đời token).

**Test protocol bắt buộc trước khi bật (chọn A hoặc B):**
1. Tăng `accessTokenLifespan` tạm xuống `60` giây để không phải chờ 5 phút.
2. Mở 2 tab cùng user → để cả 2 hết hạn token → kích hoạt cả 2 tab gần như đồng thời →
   **cả 2 vẫn hoạt động, không tab nào bị redirect `/login`**.
3. Lặp lại 10 lần.
4. Lấy RT đã dùng → replay bằng curl → **phải** `invalid_grant` /
   `Maximum allowed refresh token reuse exceeded`.
5. Trả `accessTokenLifespan` về `300`.

### P2-4 · Chặn `/admin` của Keycloak (R8 kèm theo)

`deploy/ingress/keycloak.yaml` expose `path: /` Prefix →
`https://web-dev1-keycloak…/admin/…` gọi được từ internet (trừ khi Cloudflare đã chặn sẵn).

| Cách | Ưu | Nhược |
|---|---|---|
| **Cloudflare Zero Trust Access** policy cho `/admin*` | không đụng cluster, hợp stack đang dùng tunnel | cần cấu hình bên Cloudflare |
| **Traefik Middleware** (IP allowlist / BasicAuth) gắn vào Ingress `keycloak` | kiểm soát trong repo | cần biết dải IP; thay IP là hỏng |
| Bỏ qua | — | giữ nguyên cửa ngõ |

**Khuyến nghị:** Cloudflare Access.

⚠️ **KHÔNG chặn** `/realms/`, `/protocol/`, `/resources/`, `/js/` → sẽ phá luôn luồng đăng
nhập và token của FE + gateway.

Verify: mở `/admin/` ở cửa sổ chưa qua Access → bị chặn; đăng nhập user thường
(`/realms/ptit-wgs/protocol/...`) vẫn chạy bình thường; FE login vẫn OK.

### P2-5 · `start-dev` → `start` (KHÔNG bắt buộc · cần verify)

Hiện: `deployment.yaml:23` → `args: [start-dev]`, kèm `KC_HTTP_ENABLED=true`,
`KC_PROXY=edge`, `KC_HOSTNAME` + `KC_HOSTNAME_ADMIN`, `KC_HOSTNAME_STRICT=true`.

- Dev profile: HTTP on, strict hostname **tắt theo mặc định**, **theme/template cache tắt**.
- Production profile (`start`): secure-by-default, HTTP off (nhưng `KC_HTTP_ENABLED=true`
  đã set), expects hostname + HTTPS — TLS terminate ở tunnel/ingress nên Keycloak vẫn nói
  HTTP với proxy `edge`.

**Lợi:** bật cache, hết cảnh báo dev mode, secure by default.
**Rủi ro:** **không verify được khi cluster đang down** → không làm trong lần này.
Chỉ làm khi có cửa sổ deploy. Backup: đổi lại `start-dev` + `kubectl rollout restart deployment/keycloak`.

### P2-6 · Dọn config route chết (debt)

`application-local.yaml:16-41` nằm dưới prefix cũ `spring.cloud.gateway.routes` → **không bao
giờ bind** (đã chứng minh `GatewayProperties.PREFIX = "spring.cloud.gateway.server.webflux"`).
Trong đó có route `wgs-user-service → localhost:8081` trỏ tới backend **không tồn tại** trong repo.

- **Khuyến nghị:** migrate 4 route sang prefix mới và **bỏ** route `wgs-user-service`.
- `GatewayRoutesTest` chỉ load `application.yaml` (không active profile `local`) → migrate
  không làm nó đỏ; nếu muốn phủ thêm thì thêm test chạy với `local`.

### P2-7 · Ghi nhận (không làm gì cả)

- `cloudflare_tunnel_run.sh` chứa tunnel token dạng plaintext trên disk. **Đã verify chưa
  từng được `git add`** (`git log --all --diff-filter=A` rỗng) và đang bị ignore
  (`.gitignore:35`) → không phải lỗ hổng repo, chỉ là điều kiện tại chỗ. Không cần hành động.
- `NEW_RELIC_LICENSE_KEY` trong `.env` — `.env` được ignore (`**/.env`) ✓, không cần hành động.

---

## 3. Điểm cần bạn quyết định (đã chốt — xem §3b)

| # | Câu hỏi | Lựa chọn |
|---|---|---|
| **D1** | P2-3 rotation? | **A** (code lock, khuyến nghị) · **B** (`maxReuse=1`) · **C** (bỏ qua, đẩy sang Phase 3) |
| **D2** | P2-2 policy chặt tới đâu? | `length(8)` · thêm `special/upper/digits` |
| **D3** | P2-5 `start-dev` → `start`? | Làm (cần cửa sổ deploy + verify) · Bỏ qua lần này |
| **D4** | P2-6 route chết? | Migrate + bỏ route wgs-user-service · Xóa hẳn block · Bỏ qua |

---

## 3b. Quyết định D1–D6 (chốt 2026-10-03)

Bản đầy đủ + bằng chứng: `.opencode/plan/keycloak-hardening-phase-2.md`.

| # | Câu hỏi | Chọn |
|---|---|---|
| D1 | Bật `revokeRefreshToken`? | **A** — code cross-tab lock trước, test 2 tab ×10 rồi mới bật |
| D2 | `passwordPolicy` chặt tới đâu? | **strict** — `length(8) + specialChars + upperCase + digits` |
| D3 | `start-dev` → `start`? | **Bỏ qua** — không verify được khi cluster down |
| D4 | Route chết prefix cũ? | **Xóa hẳn block** |
| D5 | Admin reset có enforce policy? | **Probe trước**, chỉ code gateway validate nếu probe trả `204` |
| D6 | Kèm `notUsername`? | **Có** |

Chuỗi policy đã chốt (D2 + D6):

```
length(8) and specialChars(1) and upperCase(1) and digits(1) and notUsername
```

---

## 4. Thứ tự thực thi

```
0. (điều kiện) Phase 1 runbook §3–§6 chạy xong
1. P2-0 rotate secret          ← bắt buộc, làm sớm để thu hẹp cửa sổ lộ
2. P2-1 đổi mật khẩu admin    ← High, độc lập
3. P2-4 chặn /admin           ← High, độc lập, không phụ thuộc code
4. P2-2 password policy       ← thứ tự không bắt buộc (admin realm master không bị ảnh hưởng)
5. D1 → P2-3 rotation          ← CHỈ KHI có test protocol xong
6. D4 → P2-6 route chết        ← khi rảnh, không đụng runtime
7. D3 → P2-5 start → start     ← chỉ khi có cửa sổ deploy
```

1–4 độc lập với nhau và không cần code mới → có thể làm trong 1 buổi.

---

## 5. Verify

| Task | Check |
|---|---|
| P2-0 | `POST /api/v1/account/change-password` vẫn `204` sau rotate; secret cũ không còn dùng được |
| P2-1 | login bằng mật khẩu admin mới OK; `admin` cũ fail |
| P2-2 | MK ngắn → `400 weak_password` + FE chặn; MK ≥8 → `204` |
| P2-3 | test protocol ở mục P2-3 (2 tab × 10 lần + replay curl fail) |
| P2-4 | `/admin/` bị chặn; login user thường + FE login vẫn chạy |
| P2-5 | Keycloak khởi động bằng `start`, login + token + admin console đều OK |
| P2-6 | `./mvnw test` xanh; local dev route vẫn vào được service đúng |

---

## 6. Docs & skills (rule bắt buộc)

| File | Nội dung |
|---|---|
| `docs/guide/PASSWORD-GATEWAY-RUNBOOK.md` | Thêm **§9. Phase 2** — toàn bộ lệnh runtime ở trên, để có 1 điểm vào duy nhất khi cluster sống lại |
| `.opencode/skills/keycloak/SKILL.md` **+** `.kilo/skills/keycloak/SKILL.md` | Thêm: `KC_BOOTSTRAP_ADMIN_*` chỉ tạo admin ở boot đầu (không reset mật khẩu) · rotation semantics + lỗi replay · `/admin` exposure · recipe policy. Giữ 2 bản identical |
| `docs/design/keycloak-password-gateway-plan-2026-10-03-v1.md` | Bổ sung mục "Phase 2" trỏ sang file này |
| `usecase-flows.md` | UC-14 thêm ghi chú password policy — không có endpoint mới |

---

## 7. Sang Phase 3 (chỉ ghi nhận, không lên chi tiết ở đây)

**Nguồn sự thật của Phase 3 là `.opencode/plan/phase-3-pkce.md`** (viết 2026-10-03) — phân đoạn
P3-1..P3-5, thứ tự, risk register và ma trận verify 12 mục nằm ở đó. Các quyết định đã chốt
**D7–D12** (cùng file, §0/§3):

| # | Quyết định |
|---|---|
| **D7** | UX login = redirect toàn trang sang trang login của Keycloak (`keycloak.login()`) — authorization code + PKCE không giữ được form password trong FE |
| **D8** | Token **memory-only** + `check-sso` iframe, fallback redirect toàn trang nếu iframe bị third-party cookie chặn |
| **D9** | Web Lock Phase 2 — ⏳ đề xuất giữ tới khi Phase 3 verify xong, **chưa chốt** |
| **D10** | Xóa nhánh forced-change của FE — ⏳ Keycloak tự hiện trang `UPDATE_PASSWORD`, **chưa chốt** |
| **D11** | Gateway xác minh `currentPassword` chuyển sang client riêng **`wgs-password-verify`** (confidential, direct grants ON, secret chỉ trong K8s Secret) — code + test + wiring đã nằm trong repo |
| **D12** | Logout — ⏳ đề xuất giữ XHR revoke + `clearToken()`, **chưa chốt** |

- **R3** password đi qua JS · **R4** token ở `localStorage` → chỉ `keycloak-js` + authorization
  code + PKCE cắt được; token chuyển sang memory, silent refresh qua SSO iframe.
- Tắt direct access grants trên `web-grading-fe` **CHỈ SAU** khi thay đổi D11 của gateway
  deploy xong — không là `POST /api/v1/account/change-password` trả 502 (gateway vẫn đang
  ROPC trên client đó). Thứ tự và lệnh runtime: runbook **§10**.
- Phase 3 đổi nhiều permutation → `keycloak.ts` giữ làm seam; `identity.ts` / `http.ts` ít đổi.

---

## 8. Rollback

Mọi task Phase 2 đều là config → rollback = PUT lại realm với giá trị cũ (recipe runbook §3)
hoặc `kubectl rollout restart` với manifest cũ. Không có migration dữ liệu, không có đổi schema.
Ngoại lệ **P2-0** (rotate secret): không rollback được — secret cũ đã bị vô hiệu; nếu gateway
hỏng thì cập nhật lại secret cho đúng.
