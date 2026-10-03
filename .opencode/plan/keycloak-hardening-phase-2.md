# Phase 2 — Hardening Keycloak & session (không thêm feature)

> Ghi: 2026-10-03. Quyết định chốt trong hội thoại, 6 điểm D1–D6.
> Phase 1 (code-complete, runtime CHƯA verify): `docs/design/keycloak-password-gateway-plan-2026-10-03-v1.md`
> Plan đầy đủ + bằng chứng: `docs/design/hardening-phase-2-plan-2026-10-03-v1.md` (có 2 lỗi phải sửa, xem §7)
> Lệnh runtime: `docs/guide/PASSWORD-GATEWAY-RUNBOOK.md` (sẽ thêm §9)
>
> **Điều kiện tiên quyết:** Phase 1 runbook §3–§6 phải chạy xong trước P2-2a/P2-3b/P2-4.
> Cluster hiện đang down → toàn bộ việc runtime ghi vào runbook, không tự chạy.

---

## Quyết định

| # | Câu hỏi | Chọn |
|---|---|---|
| D1 | Bật `revokeRefreshToken`? | **A** — code cross-tab lock trước, test 2 tab ×10 rồi mới bật |
| D2 | `passwordPolicy` chặt tới đâu? | **strict** — `length(8) + specialChars + upperCase + digits` |
| D3 | `start-dev` → `start`? | **Bỏ qua** — không verify được khi cluster down |
| D4 | Route chết prefix cũ? | **Xóa hẳn block** |
| D5 | Admin reset có enforce policy? | **Probe trước**, chỉ code gateway validate nếu probe trả `204` |
| D6 | Kèm `notUsername`? | **Có** |

### Chuỗi policy đã chốt

```
length(8) and specialChars(1) and upperCase(1) and digits(1) and notUsername
```

> Syntax lấy từ Keycloak 26.8 Admin CLI docs: separator là **`and`**, tên policy là
> `specialChars` / `upperCase` / `digits` / `length` / `notUsername`.
> Sai lầm thường gặp (đã mắc ở bản draft): `special(1)`, `upper(1)`, phân cách bằng space hay `;`.
>
> `passwordPolicy` là attribute **của realm** → đặt trên `ptit-wgs` thì user `admin`
> (realm `master`) **không bị ảnh hưởng** → không có risk tự khóa admin console.
> Docs: policy **không retroactive** — *"will not be effective for existing users"*.

---

## 1. Thứ tự thực thi

```
0. [điều kiện] Phase 1 runbook §3–§6 chạy xong
1. P2-0  rotate secret wgs-user-service      ← cửa sổ lộ, làm sớm
2. P2-1  đổi mật khẩu admin console
3. P2-4  chặn /admin (Cloudflare Access)
4. P2-2a PUT realm policy  +  P2-2b FE mirror rules + i18n
5. P2-2c PROBE admin-reset → chỉ code gateway nếu trả 204
6. P2-3a Web Lock trong keycloak.ts → build/lint → P2-3b bật rotation + test 2 tab ×10
7. P2-6  xóa block route chết application-local.yaml:16-41
```

P2-0/P2-1/P2-4 độc lập, không cần code → làm trong 1 buổi.
P2-5 (`start-dev` → `start`) **bỏ**. P2-7 (tunnel token) đã verify **không** phải việc.

---

## 2. Việc CODE (thực thi trong lần này)

### 2.1 P2-3a — Cross-tab refresh lock · `keycloak.ts`

**Vấn đề:** FE dedup refresh chỉ trong 1 tab (`refreshPromise` `keycloak.ts:77`,
`isRefreshing` `http.ts:39`), không có `storage` listener, không `BroadcastChannel`.
Khi bật rotation, 2 tab cùng đọc RT1 rồi POST đồng thời → 1 tab thành công, tab kia
`invalid_grant` "Maximum allowed refresh token reuse exceeded" → `clearSession()` → đá ra `/login`.

**Bằng chứng:** `keycloak.ts:112-114` đọc `localStorage` **ngoài** `refreshPromise`
→ lock phải bọc **cả 112 → 132** (đọc → POST → persist), không chỉ phần POST.

**Cách:** Web Locks API (`navigator.locks`) — trình duyệt cấp quyền exclusive xuyên tab.

```ts
const REFRESH_LOCK = 'wgs.token.refresh'

export async function refreshSession(): Promise<AuthSession> {
  if (refreshPromise) return refreshPromise
  refreshPromise = exclusiveRefresh()
  try {
    return await refreshPromise
  } finally {
    refreshPromise = null
  }
}

async function exclusiveRefresh(): Promise<AuthSession> {
  const locks = navigator.locks
  if (!locks) return refreshOnce()                 // fallback = hành vi y như hiện tại
  return locks.request(REFRESH_LOCK, async () => {
    // Tab khác vừa refresh xong trong lúc mình chờ lock → dùng luôn, đừng gọi Keycloak lần nữa
    if (!isSessionExpired()) return getSession()!
    return refreshOnce()
  })
}
```

`refreshOnce()` = body cũ (đọc RT → POST `/token` → `sessionFromTokens` → `persist`).

Ba điểm bắt buộc:
1. Dùng lại helper **đã có sẵn** `isSessionExpired(bufferMs = 30_000)` ở `keycloak.ts:154` — không viết hàm mới.
2. `throw new Error('no_session')` phải chuyển vào **trong** lock.
3. Không deadlock: `refreshPromise` / `isRefreshing` vẫn per-tab; lock chỉ serialize **giữa** các tab.

Đã confirm: TypeScript **6.0.3** → `navigator.locks` có type trong `lib.dom`, không cần cast.
Cần secure context: `localhost` (dev) ✓, https (prod) ✓; nếu thiếu → fallback, không regression.

⚠️ **FE không có test runner** (package.json chỉ có `typescript`, không vitest/jest/playwright)
→ verify bằng protocol thủ công 2 tab, không có unit test.

### 2.2 P2-2b — Mirror policy ở FE

| File | Hiện tại | Cần |
|---|---|---|
| `ChangePasswordModal.tsx:86-89` | `required` + `min: 8` | thêm rule special/upper/digit |
| `LoginPage.tsx:148,156` | **chỉ `required`, không có cả `min:8`** | thêm đầy đủ — đây là lỗ UX sẵn có của Phase 1 |
| `locales/vi.json` + `en.json` | chỉ có `passwordTooShort` | thêm key mới, **parity bắt buộc** |

Rule phải khớp chính xác realm policy: ≥8 ký tự, ≥1 chữ hoa, ≥1 chữ số, ≥1 ký tự đặc biệt,
không trùng username. `notUsername` FE không check được (biết username ở nơi khác) → bỏ qua
phần này ở client, realm lo.

### 2.3 P2-6 — Xóa block route chết · `application-local.yaml:16-41`

Prefix cũ `spring.cloud.gateway.routes` không bao giờ bind
(`GatewayProperties.PREFIX = "spring.cloud.gateway.server.webflux"`),
trong đó route `wgs-user-service → localhost:8081` trỏ backend **không tồn tại**.
Xóa block → zero behavior change (hiện tại chúng vốn không bind).

### 2.4 P2-2c — Gateway validate · CHỈ NẾU probe trả `204`

Không code trước. Chờ evidence.

---

## 3. Việc RUNTIME (ghi vào runbook §9, không tự chạy khi cluster down)

### P2-0 · Rotate secret `wgs-user-service`
1. Admin Console → realm `ptit-wgs` → Clients → `wgs-user-service` → Credentials → **Rotate**
2. Cập nhật `.env` → `KEYCLOAK_ADMIN_CLIENT_SECRET=<mới>`
3. Cập nhật **`src-services/keycloak/ptit-wgs-realm.json`** — client này đang mang `secret`
   trong export (git-tracked). **Khuyến nghị xóa hẳn trường `secret`** để không sync secret trong git.
4. `./deploy/setup-namespace.sh` → roll gateway
5. Verify: `POST /api/v1/account/change-password` vẫn `204`

⚠️ Giữa bước 1–4 endpoint trả `502`. Làm trong 1 lần.
⚠️ Secret cũ vẫn còn trong lịch sử git `src-services` → **không tự ý rewrite history** (destructive).

### P2-1 · Đổi mật khẩu admin console
⚠️ **`KC_BOOTSTRAP_ADMIN_PASSWORD` chỉ được đọc lúc boot đầu** khi `master` chưa tồn tại
(Keycloak 26 docs: *"parses these values at first startup to create an initial user"*).
Sửa `.env` + `kubectl rollout restart` **không đổi** mật khẩu `admin` đang có.

Cách đúng: Admin Console → Master realm → Users → `admin` → Credentials → Set password
(bỏ tick *Temporary*) → Save. Rồi mới cập nhật `.env` `KEYCLOAK_ADMIN_PASSWORD` +
`./deploy/setup-namespace.sh` + restart pod.
Verify: login mật khẩu mới OK, mật khẩu cũ `admin` **fail**.

### P2-2a · PUT realm policy
Recipe GET → sửa → PUT (runbook §3) với chuỗi ở trên. PUT realm là **full replace**.
Verify: MK `abcdefgh` (8 ký tự, có hoa/thường/số nhưng **không ký tự đặc biệt**) →
- `400 weak_password` → policy đi qua ✓, không cần code gateway
- `204` → admin reset **bypass** → quay lại §2.4 mới code

### P2-3b · Bật rotation
Sau khi P2-3a code xong: `revokeRefreshToken: true`, `refreshTokenMaxReuse: 0`.

**Test protocol (bắt buộc, 10 lần):**
1. Tăng `accessTokenLifespan` tạm xuống `60` giây
2. Mở 2 tab cùng user → để hết hạn token → kích hoạt cả 2 tab gần như đồng thời
3. **Cả 2 vẫn hoạt động, không tab nào bị redirect `/login`**
4. Replay RT đã dùng bằng curl → phải `invalid_grant` /
   `Maximum allowed refresh token reuse exceeded`
5. Trả `accessTokenLifespan` về `300`

### P2-4 · Chặn `/admin`
`deploy/ingress/keycloak.yaml` expose `path: /` Prefix → `/admin/...` public qua tunnel.
Khuyến nghị: **Cloudflare Zero Trust Access** policy cho `/admin*`.
⚠️ **KHÔNG chặn** `/realms/`, `/protocol/`, `/resources/`, `/js/` → sẽ phá luôn login + token.
Verify: `/admin/` bị chặn; login user thường + FE login vẫn chạy.

---

## 4. Verify

| Task | Check |
|---|---|
| 2.1 | `npm run build` + `npm run lint` PASS; test 2 tab ×10 không tab nào bị đá |
| 2.2 | `npm run build` + `npm run lint`; `vi.json`/`en.json` cùng số key |
| 2.3 | `./mvnw test` (gateway) xanh |
| P2-0 | endpoint vẫn `204` sau rotate |
| P2-1 | login mật khẩu mới OK, `admin` cũ fail |
| P2-2a | MK yếu → `400 weak_password` |
| P2-4 | `/admin/` bị chặn, login thường chạy |

---

## 5. Docs & skills (rule bắt buộc, làm cùng lúc implement)

| File | Nội dung |
|---|---|
| `docs/design/hardening-phase-2-plan-2026-10-03-v1.md` | Sửa 2 lỗi (§7 dưới đây) + ghi D1–D6 |
| `docs/guide/PASSWORD-GATEWAY-RUNBOOK.md` | Thêm **§9. Phase 2** — toàn bộ lệnh runtime §3 |
| `.opencode/skills/keycloak/SKILL.md` **+** `.kilo/skills/keycloak/SKILL.md` | syntax policy `and` + tên provider · gotcha `KC_BOOTSTRAP_*` chỉ boot đầu · rotation semantics + lỗi replay · caveat admin-reset. **2 bản phải identical** |
| `.opencode/skills/react-frontend-antd/SKILL.md` **+** `.kilo/` | rule mirror password policy + Web Lock pattern |
| `docs/design/usecase-flows.md` UC-14 | ghi chú password policy realm áp cho endpoint đổi MK |

---

## 6. Rollback

Mọi task runtime đều là config → PUT lại realm với giá trị cũ, hoặc `kubectl rollout restart`
với manifest cũ. Không migration, không đổi schema.
Ngoại lệ **P2-0**: không rollback được — secret cũ đã vô hiệu; nếu gateway hỏng thì cập nhật
secret cho đúng.
Code 2.1 → bỏ `exclusiveRefresh`, quay về body cũ (git revert).
Code 2.2 → bỏ rule (FE-only, không ảnh hưởng server).

---

## 7. 2 lỗi phải sửa trong `docs/design/hardening-phase-2-plan-2026-10-03-v1.md`

1. **Nhãn option D2 sai syntax** — `special(1) upper(1) digits(1)` →
   `length(8) and specialChars(1) and upperCase(1) and digits(1) and notUsername`.
2. **Câu *"áp cho mọi user kể cả admin"* SAI** → `passwordPolicy` là attribute realm,
   đặt trên `ptit-wgs` thì user `admin` ở realm `master` **không bị ảnh hưởng**.

---

## 8. Bỏ qua / không làm

- **P2-5** `start-dev` → `start`: cần cửa sổ deploy + verify, để phase sau.
- **P2-7** tunnel token plaintext: đã verify `git log --all --diff-filter=A` rỗng,
  `.gitignore:35` ignore sẵn → không phải lỗ hổng repo.
- **Phase 3** (R3/R4, keycloak-js + PKCE): riêng, chưa lên chi tiết.
