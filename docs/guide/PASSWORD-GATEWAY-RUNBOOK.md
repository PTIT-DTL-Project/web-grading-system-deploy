# Runbook — Phase 1: Đổi mật khẩu qua API Gateway

> **Tạo:** 2026-10-03 — máy dev vừa reboot (~3 phút uptime), `k3s` đang `inactive` + `disabled`,
> docker chưa chạy → mọi tunnel hostname trả Cloudflare **530** (lỗi 1033 = origin down).
> Code + config đã viết xong, **verify runtime chưa chạy lần nào**. File này là danh sách lệnh
> cần chạy lại khi cluster lên, theo đúng thứ tự.
>
> Plan: `docs/design/keycloak-password-gateway-plan-2026-10-03-v1.md`

---

## 0. Trạng thái

| # | Việc | Trạng thái | Lệnh ở |
|---|---|---|---|
| 1 | Build/test local (`mvn test`, `npm run build`, `npm run lint`) | **✓ 2026-10-03** — gateway 37/37, FE build+lint exit 0, i18n 159/159 parity | §1 |
| 2 | Realm `bruteForceProtected=true` (runtime) | **✓ 2026-10-03** — `true`, failureFactor 30, maxFailureWait 900s, permanentLockout false | §3 |
| 3 | Secret `keycloak-admin-client` | **CHƯA TẠO** — k3s inactive | §4 |
| 4 | Build image + deploy qua ArgoCD | **CHƯA** — k3s inactive, image đang là v1.0.8 cũ | §5 |
| 5 | Endpoint không 404 + E2E | **§6.1–§6.2 ✓ trên gateway local 8080** — sai MK/unknown user/missing field đúng contract; `weak_password` chưa có (realm chưa có passwordPolicy → weak pw trả 204). §6.3 browser E2E **CHƯA** | §6 |
| 6 | Rotate secret `wgs-user-service` | **CHƯA** — làm sau khi ship | §7 |

**Đã tìm và fix khi verify 2026-10-03:** Keycloak 26 trả **401** (không phải 400) cho
`invalid_grant` / `Invalid user credentials` → `KeycloakAdminWebClient.passwordVerdict`
chỉ nhận 400 nên mọi case sai MK thành 502. Đã nhận cả 400 và 401 (giới hạn theo body),
thêm test → 37/37 pass.

**Cũng 2026-10-03 (không cần cluster):** §10.3 PKCE **đã enforce S256** (lưu dưới attribute
`pkce.code.challenge.method` — body `pkceMethod` top-level bị KC 400, xem §10.3), thêm
`post.logout.redirect.uris`; D12 logout chuyển `kc.logout()` full-page (FE `keycloak.ts`).
Behavioral test §10.3 ✓ (không challenge → `invalid_request`; có S256 → login page).
**Cũng 2026-10-03:** §10.2 client `wgs-password-verify` đã tạo + secret trong `.env`;
§10.6 đã tắt direct grants `web-grading-fe` (lệch thứ tự, user chấp nhận — chi tiết ở §10.6).
**Browser E2E của login/logout sau các thay đổi này chưa chạy** — checklist §6.3 + verify #9.

---

## 1. Build / test local — không cần cluster

```bash
cd src-services/api-gateway && ./mvnw test
cd ../../frontend-src/web-grading-system-fe && npm run build && npm run lint
```

- `npm run build` = `i18n:check` → `tsc -b` → `vite build`.
- Dự kiến: i18n **154 keys** (147 cũ + 7 mới), vi/en parity.
- Endpoint mới **không** được trả 404 — kiểm ở §6.2.

---

## 2. Môi trường

```bash
./start.sh                       # bắt đầu k3s (start.sh dòng 17: sudo systemctl start k3s)
sudo systemctl is-active k3s     # active
kubectl get nodes
# tunnel (docker compose, xem stop.sh để biết file)
docker compose -f deploy/cloudflared/docker-compose.yml up -d
```

Kiểm tra tunnel + Keycloak sống (phải **200**, không phải 530):

```bash
BASE="https://web-dev1-keycloak.vucongtuanduong.dpdns.org"
curl -sS -o /dev/null -w 'keycloak %{http_code}\n' \
  "$BASE/realms/ptit-wgs/.well-known/openid-configuration"
curl -sS -o /dev/null -w 'gateway  %{http_code}\n' \
  https://web-dev1-api.vucongtuanduong.dpdns.org/actuator/health
```

> `k3s.service` đang **disabled** → sau mỗi reboot phải chạy lại `./start.sh`.
> Muốn tự khởi động cùng boot: `sudo systemctl enable k3s`.

---

## 3. Bật brute force cho realm `ptit-wgs`  ← §6.1 của plan

**Bắt buộc pattern GET → sửa field → PUT**, vì `PUT /admin/realms/{realm}` là **FULL REPLACE**:
PUT một body rời rạc sẽ xoá sạch các field khác của realm. Luôn lấy realm đầy đủ về, đổi đúng
1 field, PUT lại chính cái đó.

```bash
cd /path/to/web-grading-system-deploy
BASE="https://web-dev1-keycloak.vucongtuanduong.dpdns.org"
ADMIN_U="$(grep -E '^KEYCLOAK_ADMIN_USERNAME=' .env | cut -d= -f2-)"
ADMIN_P="$(grep -E '^KEYCLOAK_ADMIN_PASSWORD=' .env | cut -d= -f2-)"

# 1. admin token (admin-cli, password grant)
TOKEN=$(curl -sS --max-time 20 \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=admin-cli" \
  --data-urlencode "username=${ADMIN_U:-admin}" \
  --data-urlencode "password=${ADMIN_P}" \
  "$BASE/realms/master/protocol/openid-connect/token" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

# 2. GET full realm
curl -sS -H "Authorization: Bearer $TOKEN" \
  "$BASE/admin/realms/ptit-wgs" -o /tmp/realm.json

# 3. đổi đúng 4 field brute force
python3 - <<'PY'
import json
p = "/tmp/realm.json"
r = json.load(open(p))
print("before:", {k: r.get(k) for k in
      ("bruteForceProtected", "failureFactor", "maxFailureWaitSeconds", "permanentLockout")})
r["bruteForceProtected"] = True
r.setdefault("failureFactor", 30)
r.setdefault("maxFailureWaitSeconds", 900)
r.setdefault("permanentLockout", False)
json.dump(r, open(p, "w"), ensure_ascii=False, indent=2)
print("after :", {k: r.get(k) for k in
      ("bruteForceProtected", "failureFactor", "maxFailureWaitSeconds", "permanentLockout")})
PY

# 4. PUT lại full realm (đã GET, chỉ khác 4 field ở trên)
curl -sS -o /dev/null -w 'PUT realm -> HTTP %{http_code}\n' -X PUT \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary @/tmp/realm.json "$BASE/admin/realms/ptit-wgs"

# 5. verify
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/admin/realms/ptit-wgs" \
  | python3 -c 'import sys,json;r=json.load(sys.stdin);print({k:r.get(k) for k in
      ("bruteForceProtected","failureFactor","maxFailureWaitSeconds","permanentLockout","passwordPolicy")})'
# kỳ vọng: bruteForceProtected True
```

**Rollback:** chạy lại đúng recipe với `r["bruteForceProtected"] = False`.

**⚠️ Cảnh báo DoS lên tài khoản nạn nhân:** `failureFactor=30` + `permanentLockout=false` →
ai nhập sai 30 lần sẽ **lock tạm那个人 ~15 phút** (`maxFailureWaitSeconds=900`). Chấp nhận được
vì không lock vĩnh viễn, nhưng các ca E2E cố ý nhập sai nhiều lần sẽ tự khóa `lecturer_test` —
đợi hết hạn, hoặc reset qua admin console.

**File repo đã đồng bộ:** `src-services/keycloak/ptit-wgs-realm.json` đã được thêm
`bruteForceProtected/failureFactor/maxFailureWaitSeconds/permanentLockout` ở lần sửa này.
Lưu ý file export này **không** được chart nào import (grep không thấy consumer) — nó là tài liệu
tham chiếu, nên đổi runtime ở trên không tự ghi ngược vào đây.

---

## 4. Secret

### 4.1 Thêm vào `.env` (gitignored — **không** commit)

```bash
# lấy từ Keycloak: Clients → wgs-user-service → Credentials → Secret
KEYCLOAK_ADMIN_CLIENT_ID=wgs-user-service
KEYCLOAK_ADMIN_CLIENT_SECRET=<24 ký tự từ Keycloak>
```

### 4.2 Tạo secret trong cluster

```bash
./deploy/setup-namespace.sh            # namespace mặc định: web-grading
kubectl get secret keycloak-admin-client -n web-grading
```

- `setup-namespace.sh` **fail loud** nếu `KEYCLOAK_ADMIN_CLIENT_ID/SECRET` trống
  (không tạo secret rỗng) — cố ý, vì secret rỗng sẽ làm endpoint đổi mật khẩu hỏng âm thầm.

---

## 5. Deploy (GitOps — không deploy tay)

```
1. push src-services/   → GitHub Actions build-services.yml: test + build image + push
                        → publish.yml: clone config repo, bump tag trong <service>/values-stg.yaml
2. push config-services/ (checkout của repo config) → ArgoCD auto-sync → pods roll
```

```bash
# render chart locally TRƯỚC khi push (chart không có values.yaml mặc định):
helm template api-gateway config-services/api-gateway -f config-services/api-gateway/values-stg.yaml

kubectl get applications -n argocd
kubectl rollout status deployment/api-gateway -n web-grading
kubectl logs deploy/api-gateway -n web-grading --tail=100
```

Việc cần có trước khi deploy:
- image tag mới của `api-gateway` (tự bump qua `publish.yml` sau khi push `src-services/`).
- secret §4 đã tạo trong namespace.

---

## 6. Verify runtime

### 6.1 Endpoint không được 404

Controller (`RequestMappingHandlerMapping` order 0) phải thắng route predicate
(`RoutePredicateHandlerMapping` order 1) — **đây là điều mới chỉ verify bằng bytecode, chưa e2e.**

```bash
# local (gateway chạy từ IntelliJ, port 8080)
curl -i -X POST http://localhost:8080/api/v1/account/change-password \
  -H 'Content-Type: application/json' \
  -d '{"username":"lecturer_test","currentPassword":"x","newPassword":"y"}'
# deployed
curl -i -X POST https://web-dev1-api.vucongtuanduong.dpdns.org/api/v1/account/change-password \
  -H 'Content-Type: application/json' \
  -d '{"username":"lecturer_test","currentPassword":"x","newPassword":"y"}'
```

**Phải KHÔNG phải `404`.** Nếu vẫn 404 → fallback (ghi vào code):
`RouterFunction` (order `-1`) hoặc `spring.cloud.gateway.server.webflux.handler-mapping.order`.

### 6.2 Contract

| Case | Lệnh / thao tác | Kỳ vọng |
|---|---|---|
| Sai MK hiện tại | curl trên với `currentPassword` sai | `400 current_password_invalid` |
| User không tồn tại | curl với `username=khongton_tai` | `400 current_password_invalid` — **cùng code** |
| Thiếu field | `-d '{}'` | `400 validation_failed` |
| Thành công | `currentPassword` đúng, `newPassword` ≥ 8 | `204` |
| MK mới quá yếu | `newPassword` < 8 (nếu realm có policy) | `400 weak_password` |
| Keycloak chết | chặn network tới Keycloak | `502 identity_provider_unavailable` |

### 6.3 E2E trên browser (dev local)

- [ ] Header → menu user → **Đổi mật khẩu** (đứng **trước** Đăng xuất) → Modal 3 ô.
- [ ] Nhập sai MK hiện tại → toast lỗi, và **Network không có call nào tới Keycloak admin**
      (`/admin/realms/...`) — chỉ được thấy `POST /api/v1/account/change-password`.
- [ ] MK mới < 8 → rule FE chặn; xác nhận lệch → rule chặn.
- [ ] Đổi hợp lực → toast success → **đăng xuất, đăng nhập bằng MK mới** → vào `/classes`.
- [ ] Forced flow: đăng nhập bằng MK tạm → form **2 ô** (không có ô MK hiện tại) → đổi → login MK mới.
- [ ] **R5 — chứng minh revoke chạy thật:** TRƯỚC khi logout, lấy `refresh_token` cũ
      (token memory-only từ Phase 3 — đọc ở Network tab, response của request
      `/protocol/openid-connect/token` lần refresh/login gần nhất), rồi
      ```bash
      curl -sS -X POST "$BASE/realms/ptit-wgs/protocol/openid-connect/token" \
        --data-urlencode 'client_id=web-grading-fe' \
        --data-urlencode 'grant_type=refresh_token' \
        --data-urlencode "refresh_token=$OLD_REFRESH"
      ```
      → **phải fail** (`invalid_grant` / 400), không được trả access token.
- [ ] **R6:** nhập sai MK nhiều lần → Keycloak lock tạm (xem §3 cảnh báo).
- [ ] **R1:** `grep -r "VITE_KEYCLOAK_ADMIN" frontend-src/` → không ra gì (đã verify offline),
      và bundle build không còn chứa secret cũ.

### 6.4 Quét secret cũ trong bundle

```bash
cd frontend-src/web-grading-system-fe && npm run build
grep -rl "wgs-user-service" dist/ && echo "CÒN SECRET/BUNDLE LEAK" || echo "sạch"
```

---

## 7. Rotate secret `wgs-user-service` — làm SAU khi ship

Secret này từng nằm trong bundle FE và trong `.env.development.local` → coi như đã lộ.

**Cách chắc chắn nhất — Admin Console (không cần verify API):**

1. `https://<keycloak-host>` → log in bằng `admin` (đọc `.env`, key `KEYCLOAK_ADMIN_PASSWORD`).
2. Realm `ptit-wgs` → **Clients** → `wgs-user-service` → tab **Credentials** → **Rotate**.
3. Copy secret mới → cập nhật:
   - `.env`: `KEYCLOAK_ADMIN_CLIENT_SECRET=<mới>`
   - `frontend-src/web-grading-system-fe/.env.development.local`: nếu còn dòng nào — **không**, biến đó đã bị xóa; chỉ cần `.env`.
   - `src-services/keycloak/ptit-wgs-realm.json`: client `wgs-user-service` có trường `secret` (24 ký tự) **đang nằm trong git** → cập nhật hoặc **xóa hẳn trường đó khỏi export**.
4. `./deploy/setup-namespace.sh` → restart/roll gateway.

**Cách REST (CHƯA VERIFY — chưa chạy được):**

```bash
# lấy internal id của client
curl -sS -H "Authorization: Bearer $TOKEN" \
  "$BASE/admin/realms/ptit-wgs/clients?clientId=wgs-user-service" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])'
# GET client đầy đủ -> set secret -> PUT lại (lưu ý FULL REPLACE như §3)
# ...chưa xác minh được Keycloak có nhận trường "secret" khi PUT ClientRepresentation hay không,
# nên mặc định dùng Admin Console ở trên.
```

Sau khi rotate: kiểm `POST /api/v1/account/change-password` vẫn `204` (nghĩaa gateway đọc đúng secret mới).

---

## 8. Việc lẻ / rủi ro còn lại

- **R3 + R4 chưa cắt** — password vẫn đi qua JS, token vẫn trong `localStorage`. Chỉ Phase 3
  (`keycloak-js` + PKCE) cắt được.
- **Access token đã phát hành vẫn sống tới 5 phút sau logout** (`accessTokenLifespan=300`) —
  revoke chặn refresh, không thu hồi token đang phát hành.
- **`.env` chứa `KEYCLOAK_ADMIN_PASSWORD=admin`** (R8) — High, chưa sửa (Phase 2).
- **Cạnh bên, chưa thuộc scope:** `cloudflare_tunnel_run.sh` ở repo root chứa **Cloudflare tunnel
  token dạng plaintext** (dòng 1). Ghi nhận location, không đụng tới trong lần này.
- **`.env.development`** còn 3 dòng `VITE_KEYCLOAK_ADMIN_*` placeholder → đã xóa (không tham chiếu ở `src/`).

---

## 9. Phase 2 — Hardening

> Quyết định D1–D6 + bằng chứng: `.opencode/plan/keycloak-hardening-phase-2.md` và
> `docs/design/hardening-phase-2-plan-2026-10-03-v1.md` (§3b).
> **Điều kiện tiên quyết:** §3–§6 của runbook này phải chạy xong trước P2-2a / P2-3b / P2-4.
> **Thứ tự bắt buộc (plan §1):** P2-0 → P2-1 → P2-4 → P2-2a → P2-2c → (P2-3a code FE) → P2-3b.

Chuỗi policy đã chốt (D2 + D6):

```
length(8) and specialChars(1) and upperCase(1) and digits(1) and notUsername
```

Toàn bộ lệnh dưới đây dùng `$BASE` + `$TOKEN` theo đúng recipe §3 (lấy token admin):

```bash
BASE="https://web-dev1-keycloak.vucongtuanduong.dpdns.org"
ADMIN_U="$(grep -E '^KEYCLOAK_ADMIN_USERNAME=' .env | cut -d= -f2-)"
ADMIN_P="$(grep -E '^KEYCLOAK_ADMIN_PASSWORD=' .env | cut -d= -f2-)"
TOKEN=$(curl -sS --max-time 20 \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=admin-cli" \
  --data-urlencode "username=${ADMIN_U:-admin}" \
  --data-urlencode "password=${ADMIN_P}" \
  "$BASE/realms/master/protocol/openid-connect/token" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
```

### 9.1 P2-0 · Rotate secret `wgs-user-service` — làm đầu tiên

1. Admin Console → realm `ptit-wgs` → **Clients** → `wgs-user-service` → tab **Credentials** →
   **Rotate**.
2. Cập nhật `.env` → `KEYCLOAK_ADMIN_CLIENT_SECRET=<mới>`.
3. Cập nhật **`src-services/keycloak/ptit-wgs-realm.json`** — client `wgs-user-service` đang
   mang trường `secret` **plaintext trong export git-tracked** → cập nhật giá trị mới, hoặc
   (khuyến nghị) **xóa hẳn trường `secret`** để không sync secret trong git nữa.
4. `./deploy/setup-namespace.sh` → roll gateway.

⚠️ **Cửa sổ 502:** giữa bước 1 và bước 4 endpoint đổi mật khẩu trả `502` → làm trong 1 lần,
đừng để qua ngày.
⚠️ Secret **cũ** vẫn còn trong lịch sử git repo `src-services` → **không tự ý rewrite history**
(destructive) — ghi nhận, để người quyết định.

**Verify:**

```bash
curl -sS -o /dev/null -w 'change-password -> HTTP %{http_code}\n' -X POST \
  https://web-dev1-api.vucongtuanduong.dpdns.org/api/v1/account/change-password \
  -H 'Content-Type: application/json' \
  -d '{"username":"lecturer_test","currentPassword":"sai","newPassword":"x"}'
# mong đợi 400 (current_password_invalid) — KHÔNG được 502 → gateway đọc đúng secret mới
```

### 9.2 P2-1 · Đổi mật khẩu admin console

⚠️ **Gotcha (đã xác minh):** `KC_BOOTSTRAP_ADMIN_PASSWORD` chỉ được đọc **lần boot đầu tiên**
để tạo user `admin` (Keycloak 26: *"parses these values at first startup to create an initial
user"*). Sửa `.env` rồi `kubectl rollout restart` **KHÔNG đổi** mật khẩu `admin` đang có —
env đó không được đọc lại nữa.

Cách đúng (Admin Console):
1. Đăng nhập admin → **Master realm** → **Users** → `admin` → **Credentials** →
   **Set password** (bỏ tick *Temporary*) → Save.
   (Tương đương CLI: `kcadm.sh set-password --username admin --temporary=false`.)
2. Mới cập nhật `.env` → `KEYCLOAK_ADMIN_PASSWORD=<mới>` (khớp script + người vận hành).
3. `./deploy/setup-namespace.sh` (secret `keycloak-db` tạo lại từ `.env`) + restart pod Keycloak.

**Verify:** logout → login bằng mật khẩu **mới** OK; mật khẩu cũ **fail**.

### 9.3 P2-4 · Chặn `/admin` (Cloudflare Zero Trust Access)

`deploy/ingress/keycloak.yaml` expose `path: /` Prefix → `/admin/...` public qua tunnel.

- **Khuyến nghị:** tạo **Cloudflare Zero Trust Access policy** match `/admin*` trên hostname
  Keycloak (không đụng cluster, hợp stack đang dùng tunnel).
- ⚠️ **KHÔNG chặn** `/realms/`, `/protocol/`, `/resources/`, `/js/` — chặn những path đó là
  **login + token flow của FE và gateway hỏng hết** (redirect login lặp, `invalid_client` vì
  không tải được JWKS/register resources). Chỉ `pathCallback` của Access phải là `/admin*`.

**Verify:** mở `https://<keycloak-host>/admin/` ở cửa sổ chưa qua Access → bị chặn; đăng nhập
user thường (`/realms/ptit-wgs/protocol/...`) + FE login vẫn chạy bình thường.

### 9.4 P2-2a · PUT realm `passwordPolicy`

Recipe **GET → sửa 1 field → PUT full body** như §3 (PUT realm là **FULL REPLACE**):

```bash
# 1. GET full realm (dùng $TOKEN ở trên)
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/admin/realms/ptit-wgs" -o /tmp/realm.json

# 2. đổi đúng 1 field
python3 - <<'PY'
import json
p = "/tmp/realm.json"
r = json.load(open(p))
print("before:", r.get("passwordPolicy"))
r["passwordPolicy"] = "length(8) and specialChars(1) and upperCase(1) and digits(1) and notUsername"
json.dump(r, open(p, "w"), ensure_ascii=False, indent=2)
print("after :", r["passwordPolicy"])
PY

# 3. PUT lại full realm
curl -sS -o /dev/null -w 'PUT realm -> HTTP %{http_code}\n' -X PUT \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary @/tmp/realm.json "$BASE/admin/realms/ptit-wgs"

# 4. verify
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/admin/realms/ptit-wgs" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("passwordPolicy"))'
```

Cách CLI tương đương (Keycloak 26.8 Admin CLI):

```bash
kcadm.sh update realms/ptit-wgs -s 'passwordPolicy="length(8) and specialChars(1) and upperCase(1) and digits(1) and notUsername"'
```

Lưu ý:
- Separator là **` and `**, tên provider là `length`/`specialChars`/`upperCase`/`digits`/
  `notUsername` — **không** có `special(...)`, `upper(...)` (ID không tồn tại).
- `passwordPolicy` là attribute **của realm `ptit-wgs`** → user `admin` ở realm `master`
  **không bị ảnh hưởng**, không có rủi ro tự khóa admin console.
- Policy **không retroactive** — mật khẩu cũ vẫn dùng được tới lần đổi sau.

**Verify:** GET ở bước 4 trả đúng chuỗi policy ở trên.

### 9.5 P2-2c · PROBE — admin reset có enforce policy không?

Sau khi P2-2a xong, gọi endpoint với MK mới `abcdefgh` (8 ký tự, **đủ** hoa/thường/số nhưng
**thiếu ký tự đặc biệt** → không thỏa policy):

```bash
curl -i -X POST https://web-dev1-api.vucongtuanduong.dpdns.org/api/v1/account/change-password \
  -H 'Content-Type: application/json' \
  -d '{"username":"lecturer_test","currentPassword":"<MK hiện tại còn đúng>","newPassword":"abcdefgh"}'
```

Diễn giải (D5):
- **`400 weak_password`** → policy đi qua được path admin-reset của gateway → **không cần
  code gateway**.
- **`204`** → admin reset **bypass** policy → bắt buộc thêm validation phía gateway
  (plan §2.4).

⚠️ **KHÔNG viết code gateway trước khi probe này quyết định** — chưa verify được
Keycloak admin reset-password endpoint có enforce realm policy hay không.

**Verify:** kết quả là 1 trong 2 trường hợp trên, ghi lại vào plan trước khi làm tiếp.

### 9.6 P2-3b · Bật refresh rotation + test protocol

⚠️ **Điều kiện:** P2-3a (Web Locks `navigator.locks` trong `keycloak.ts` — cross-tab refresh
lock) đã **build/lint PASS và deploy xong**. Chưa có lock thì **không bật** (D1).

```bash
# GET realm -> bật rotation, đồng thời hạ tạm accessTokenLifespan để test
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/admin/realms/ptit-wgs" -o /tmp/realm.json
python3 - <<'PY'
import json
p = "/tmp/realm.json"
r = json.load(open(p))
print("before:", {k: r.get(k) for k in
      ("revokeRefreshToken", "refreshTokenMaxReuse", "accessTokenLifespan")})
r["revokeRefreshToken"] = True
r["refreshTokenMaxReuse"] = 0      # RT dùng 1 lần duy nhất
r["accessTokenLifespan"] = 60      # tạm cho test protocol
json.dump(r, open(p, "w"), ensure_ascii=False, indent=2)
PY
curl -sS -o /dev/null -w 'PUT realm -> HTTP %{http_code}\n' -X PUT \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary @/tmp/realm.json "$BASE/admin/realms/ptit-wgs"
```

**Test protocol (bắt buộc, lặp 10 lần):**

1. `accessTokenLifespan` đang tạm = `60` giây.
2. Mở **2 tab cùng user** → để token hết hạn → kích hoạt cả 2 tab gần như đồng thời.
3. **Cả 2 tab vẫn hoạt động, không tab nào bị redirect `/login`** — lặp lại 10 lần.
4. Replay refresh token đã dùng:

   ```bash
   # $USED_RT lấy từ Network tab (response /protocol/openid-connect/token)
   # TRƯỚC khi dùng nó — token memory-only, không còn localStorage (D8)
   curl -sS -X POST "$BASE/realms/ptit-wgs/protocol/openid-connect/token" \
     --data-urlencode 'client_id=web-grading-fe' \
     --data-urlencode 'grant_type=refresh_token' \
     --data-urlencode "refresh_token=$USED_RT"
   # mong đợi 400 invalid_grant: "Maximum allowed refresh token reuse exceeded"
   ```

5. Trả `accessTokenLifespan` về `300` (chạy lại recipe với `r["accessTokenLifespan"] = 300`,
   **giữ nguyên** `revokeRefreshToken: true` / `refreshTokenMaxReuse: 0` nếu test pass).

**Verify:** 10/10 lần cả 2 tab sống + replay curl trả `invalid_grant` /
`Maximum allowed refresh token reuse exceeded`; GET realm cho `accessTokenLifespan: 300`.
Rollback: PUT lại `revokeRefreshToken: false` (recipe §3).

### 9.7 P2-6 · Xóa block route chết (code — đã làm trong repo)

`src-services/api-gateway/src/main/resources/application-local.yaml` — block dưới
`spring.cloud.gateway.routes` (prefix cũ, không bao giờ bind; route
`wgs-user-service → localhost:8081` trỏ backend không tồn tại) **đã bị xóa**.

**Verify:** `cd src-services/api-gateway && ./mvnw test` — **44 tests** (43 của Phase 1 +
1 test mới `verifyPassword_configuredSecret_sendsClientSecret` cho `client_secret`, Phase 3/D11),
0 failures.

---

## 10. Phase 3 — keycloak-js + PKCE

> **Nguồn sự thật:** `.opencode/plan/phase-3-pkce.md` — quyết định **D7–D12**, phân đoạn
> P3-1..P3-5, ma trận verify. Cắt **R3** (password đi qua JS) và **R4** (token trong
> `localStorage`): login chuyển sang redirect authorization-code + PKCE (D7), token chỉ ở
> memory (D8), gateway đổi sang client xác minh riêng `wgs-password-verify` (D11 — code
> `passwordClientSecret` đã nằm trong repo).
>
> ⚠️ **Thứ tự 10.2 → 10.3 → 10.4 → 10.5 → 10.6 là bắt buộc, không đảo** — tắt Direct Access
> Grants trên `web-grading-fe` trước khi gateway dùng client riêng = endpoint đổi mật khẩu
> trả 502 (plan §7 rủi ro 3).
>
> Toàn bộ lệnh dùng `$BASE` + `$TOKEN` theo đúng recipe §3 (lấy token admin).

### 10.1 Điều kiện tiên quyết

Phase 3 **viết lại login** — nếu Phase 1 §3–§6 và Phase 2 §9 chưa chạy thì không biết luồng
nào đang sống, nên không phân biệt được "hồi quy do Phase 3" với "lỗi cũ chưa fix". Bắt buộc
xong trước khi đụng lệnh nào ở dưới:

- Phase 1: runbook **§3–§6** · Phase 2: runbook **§9** · các quyết định **D9/D10** của
  plan phải **đã chốt** (plan §5 bước 1) trước khi code FE dọn Web Lock / nhánh
  forced-change — chưa chốt thì ghi nhận, không tự ý làm.
  (D12 logout đã chốt + implement 2026-10-03: `kc.logout()` full-page.)

```bash
BASE="https://web-dev1-keycloak.vucongtuanduong.dpdns.org"
curl -sS -o /dev/null -w 'keycloak      -> %{http_code}\n' \
  "$BASE/realms/ptit-wgs/.well-known/openid-configuration"
# endpoint đổi mật khẩu phải đang sống TRƯỚC khi đổi client (đây là thứ §10 phải giữ)
curl -sS -o /dev/null -w 'gw wrong-pw   -> %{http_code}\n' -X POST \
  https://web-dev1-api.vucongtuanduong.dpdns.org/api/v1/account/change-password \
  -H 'Content-Type: application/json' \
  -d '{"username":"lecturer_test","currentPassword":"sai","newPassword":"Dev2026!!"}'
```

**Verify:** dòng 1 = `200`, dòng 2 = `400` (`current_password_invalid`) — **không** được là
`502`; `502` nghĩa là Phase 1/2 chưa xong → dừng, làm nốt §3–§9 trước.

### 10.2 Tạo client `wgs-password-verify` + secret vào `.env`

> **✓ Đã chạy 2026-10-03** (qua Admin REST, không cần cluster): client tạo `201`, secret
> ghi vào `.env` local (gitignored, 2 dòng `KEYCLOAK_PASSWORD_CLIENT_*`), verify ROPC
> `200` với MK đúng / `401 invalid_grant` với MK sai. Recipe bên dưới giữ lại để chạy lại
> khi cần. **Lưu ý:** các test change-password cùng ngày đã vô tình đổi mật khẩu
> `lecturer_test` → đã reset về `Dev2026!!` bằng `PUT …/users/{id}/reset-password`.

Bước 2 của `POST /api/v1/account/change-password` là ROPC xác minh `currentPassword`.
Tắt Direct Access Grants trên `web-grading-fe` (10.6) sẽ làm hỏng nó **nếu gateway vẫn ROPC
trên client đó** → client **riêng** (D11): confidential, Direct Access Grants **ON**,
Standard Flow **OFF**, Service Accounts **OFF** (chỉ cần password grant), secret chỉ nằm
trong K8s Secret.

**Admin Console:**
1. `https://<keycloak-host>/admin/ptit-wgs/console` → realm `ptit-wgs` → **Clients → Create**.
2. Client ID `wgs-password-verify` → Client type **openid-connect** → **Next**.
3. **Settings**: *Standard Flow Enabled* = **OFF** · *Direct Access Grants Enabled* = **ON** ·
   *Service Accounts Enabled* = **OFF** · *Valid Redirect URIs* + *Web Origins* để trống
   (client này không bao giờ redirect từ trình duyệt) → **Save**.
4. Tab **Credentials** → copy secret → **lập tức ghi vào `.env`** (gitignored).

**Admin REST (tương đương):**

```bash
curl -sS -o /dev/null -w 'create -> HTTP %{http_code}\n' -X POST "$BASE/admin/realms/ptit-wgs/clients" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{
    "clientId": "wgs-password-verify",
    "protocol": "openid-connect",
    "publicClient": false,
    "standardFlowEnabled": false,
    "directAccessGrantsEnabled": true,
    "serviceAccountsEnabled": false,
    "redirectUris": [],
    "webOrigins": []
  }'
# 201 = tạo; 409 = đã tồn tại → chạy tiếp phần đọc secret

CID=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  "$BASE/admin/realms/ptit-wgs/clients?clientId=wgs-password-verify" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')
curl -sS -H "Authorization: Bearer $TOKEN" \
  "$BASE/admin/realms/ptit-wgs/clients/$CID/client-secret" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])'
# -> in secret ra terminal để ghi vào .env; KHÔNG commit, KHÔNG paste vào doc
```

**kcadm.sh (tương đương, chưa chạy):**

```bash
kcadm.sh config-credentials --server "$BASE" --realm master --user "$ADMIN_U" --password "$ADMIN_P"
kcadm.sh create clients --realm ptit-wgs -s clientId=wgs-password-verify \
  -s enabled=true -s publicClient=false -s standardFlowEnabled=false \
  -s directAccessGrantsEnabled=true -s serviceAccountsEnabled=false
CID=$(kcadm.sh get clients --realm ptit-wgs -q clientId=wgs-password-verify --fields id -o csv --noquotes | tail -n1)
kcadm.sh get client-secret --realm ptit-wgs "$CID"    # in value
```

**`.env`** (gitignored — **không** commit):

```bash
# Phase 3 (D11) — gateway xác minh MK hiện tại qua client confidential riêng
KEYCLOAK_PASSWORD_CLIENT_ID=wgs-password-verify
KEYCLOAK_PASSWORD_CLIENT_SECRET=<giá trị đọc ở trên>
```

**Verify:**

```bash
grep -c '^KEYCLOAK_PASSWORD_CLIENT_' .env                       # phải là 2
./deploy/setup-namespace.sh                                     # fail-loud nếu set 1 trong 2
kubectl get secret keycloak-admin-client -n web-grading \
  -o jsonpath='{.data.KEYCLOAK_PASSWORD_CLIENT_ID}' | base64 -d # phải in: wgs-password-verify
```

### 10.3 Cập nhật client `web-grading-fe` — public + PKCE (**direct grants vẫn ON**)

**Admin Console** → Clients → `web-grading-fe` → **Settings**:

| Field | Giá trị |
|---|---|
| Client type | **Public** (`publicClient: true`) |
| Valid Redirect URIs | `http://localhost:5173/*` |
| Web Origins | `http://localhost:5173` — **explicit, KHÔNG bao giờ `*` khi credentials liên quan** (team đã vấp CORS 2026-10-01, xem `frontend-keycloak-login.md` §3 chú thích CORS) |
| Standard Flow Enabled | **ON** |
| PKCE Method | **S256** |
| Direct Access Grants Enabled | **ON — GIỮ NGUYÊN tới 10.6** |
| Service Accounts Enabled | OFF |

**Admin REST — GET → sửa → PUT** (PUT client cũng là **FULL REPLACE**, không gửi body rời rạc):

```bash
CID_FE=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  "$BASE/admin/realms/ptit-wgs/clients?clientId=web-grading-fe" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')
curl -sS -H "Authorization: Bearer $TOKEN" \
  "$BASE/admin/realms/ptit-wgs/clients/$CID_FE" -o /tmp/fe-client.json

python3 - <<'PY'
import json
p = "/tmp/fe-client.json"
c = json.load(open(p))
attrs = c.get("attributes") or {}
print("before:", {k: c.get(k) for k in
      ("publicClient","standardFlowEnabled","directAccessGrantsEnabled")},
      "| pkce attr:", attrs.get("pkce.code.challenge.method"))
c["publicClient"] = True
c["standardFlowEnabled"] = True
# PKCE S256 là ATTRIBUTE, không phải field top-level: ClientRepresentation không có
# "pkceMethod" — body mang tên đó bị KC 400 "Unrecognized field" (xác minh 2026-10-03).
attrs = c.setdefault("attributes", {})
attrs["pkce.code.challenge.method"] = "S256"
# D12 (2026-10-03): logout chuyển sang kc.logout() full-page — thiếu attribute này
# Keycloak từ chối post_logout_redirect_uri và chỉ hiện trang "logged out" của nó.
attrs["post.logout.redirect.uris"] = "http://localhost:5173/*"
c["redirectUris"] = ["http://localhost:5173/*"]
c["webOrigins"] = ["http://localhost:5173"]
# directAccessGrantsEnabled KHÔNG đổi ở đây — tắt ở 10.6 (thứ tự bắt buộc)
json.dump(c, open(p, "w"), ensure_ascii=False, indent=2)
PY

curl -sS -o /dev/null -w 'PUT fe-client -> HTTP %{http_code}\n' -X PUT \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary @/tmp/fe-client.json "$BASE/admin/realms/ptit-wgs/clients/$CID_FE"
```

Kèm theo (P3-1): file `frontend-src/web-grading-system-fe/public/silent-check-sso.html`
phải tồn tại — `keycloak-js` mặc định đọc path này cho `check-sso` iframe.

**Verify:**

```bash
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/admin/realms/ptit-wgs/clients/$CID_FE" \
  | python3 -c 'import sys,json;c=json.load(sys.stdin);a=c.get("attributes") or {};print(
      {k:c.get(k) for k in ("publicClient","standardFlowEnabled","directAccessGrantsEnabled",
                            "redirectUris","webOrigins")},
      "| pkce attr:", a.get("pkce.code.challenge.method"),
      "| post-logout:", a.get("post.logout.redirect.uris"))'
# kỳ vọng: public True · standardFlow True · directAccessGrants TRUE (còn ON!)
#          redirectUris ["http://localhost:5173/*"] · webOrigins ["http://localhost:5173"]
#          pkce attr "S256" · post-logout "http://localhost:5173/*"
test -f frontend-src/web-grading-system-fe/public/silent-check-sso.html && echo silent-check ok

# Behavioral — enforce phải THẬT: không code_challenge → bị từ chối,
# có S256 challenge → vào được login page (chạy 2026-10-03, cả 2 đúng)
VC_HASH=$(python3 -c 'import hashlib,base64;print(base64.urlsafe_b64encode(
  hashlib.sha256(b"test-verifier-abc123XYZ").digest()).rstrip(b"=").decode())')
curl -sS -o /dev/null -w 'no-challenge  -> %{http_code} %{redirect_url}\n' \
  "$BASE/realms/ptit-wgs/protocol/openid-connect/auth?client_id=web-grading-fe\
&redirect_uri=http%3A%2F%2Flocalhost%3A5173%2F&response_type=code&scope=openid&state=t"
#  kỳ vọng: 302 ... error=invalid_request (Missing parameter: code_challenge_method)
curl -sS -o /dev/null -w 'with-S256     -> %{http_code}\n' \
  "$BASE/realms/ptit-wgs/protocol/openid-connect/auth?client_id=web-grading-fe\
&redirect_uri=http%3A%2F%2Flocalhost%3A5173%2F&response_type=code&scope=openid&state=t\
&code_challenge_method=S256&code_challenge=$VC_HASH"
#  kỳ vọng: 200 = login page của Keycloak (không phải trang lỗi)
```

### 10.4 Deploy gateway (GitOps) — chứng minh endpoint đổi mật khẩu còn sống

Gateway mới mang `passwordClientSecret` (D11) + 2 env `KEYCLOAK_PASSWORD_CLIENT_*` từ secret.

```bash
./deploy/setup-namespace.sh        # ghi 2 key mới vào secret keycloak-admin-client
# GitOps: push src-services/ (build image api-gateway) rồi push config-services/
# (deployment có env mới) → ArgoCD auto-sync. Render TRƯỚC khi push:
helm template api-gateway config-services/api-gateway \
  -f config-services/api-gateway/values-stg.yaml | grep -A4 KEYCLOAK_PASSWORD_CLIENT
kubectl rollout status deployment/api-gateway -n web-grading --timeout=180s
kubectl exec deploy/api-gateway -n web-grading -- printenv KEYCLOAK_PASSWORD_CLIENT_ID
# (secret thì chỉ check độ dài, KHÔNG in giá trị)
kubectl exec deploy/api-gateway -n web-grading -- sh -c 'printenv KEYCLOAK_PASSWORD_CLIENT_SECRET | wc -c'
```

```bash
# a) sai MK hiện tại → 400 = grant ĐÃ tới Keycloak và trả invalid_grant (502 = invalid_client)
curl -sS -o /dev/null -w 'wrong-current -> HTTP %{http_code}\n' -X POST \
  https://web-dev1-api.vucongtuanduong.dpdns.org/api/v1/account/change-password \
  -H 'Content-Type: application/json' \
  -d '{"username":"lecturer_test","currentPassword":"sai","newPassword":"Dev2026!!"}'
# b) đúng MK hiện tại (MK mới ≥ policy) → 204
curl -sS -o /dev/null -w 'change        -> HTTP %{http_code}\n' -X POST \
  https://web-dev1-api.vucongtuanduong.dpdns.org/api/v1/account/change-password \
  -H 'Content-Type: application/json' \
  -d '{"username":"lecturer_test","currentPassword":"<MK hiện tại đúng>","newPassword":"Dev2026!!"}'
```

**Verify:** `printenv KEYCLOAK_PASSWORD_CLIENT_ID` = `wgs-password-verify` · secret độ dài
`> 0` · (a) `400` · (b) `204` — tức là gateway đang xác thực qua `wgs-password-verify`
(không `502`). *Lưu ý trung thực:* ~~tới đây `web-grading-fe` vẫn còn direct grants nên (b)
một mình **chưa** chứng minh được client nào đang được dùng~~ → **với 10.6 đã chạy
(2026-10-03, xem §10.6)**: ROPC `web-grading-fe` đã chết, nên curl (b) `400`/`204` **chính là
chứng minh dứt điểm** gateway đang dùng `wgs-password-verify` — curl nào trả `502` là
env chưa wiring.

### 10.5 Deploy FE + verify login redirect

```bash
cd frontend-src/web-grading-system-fe
ls public/silent-check-sso.html          # thiếu là reload không khôi phục được session
npm run build && npm run lint            # build xanh = tsc + i18n parity
npm run dev                              # FE hiện chỉ dev tại localhost:5173
```

**Verify (browser):**
- [ ] Mở `http://localhost:5173` → **bị redirect toàn trang** sang login của Keycloak →
      đăng nhập `lecturer_test` → quay về app **có role** (`/classes`) — luồng mới D7.
- [ ] **Reload trang** → không bị đá về `/login` (check-sso) hoặc chỉ nháy redirect 1 lần
      (fallback D8).
- [ ] Application → Local Storage: **không** có `wgs.auth` (R4 đã cắt).

### 10.6 BẬT OFF Direct Access Grants trên `web-grading-fe` — chỉ SAU 10.4/10.5

> **✓ Đã chạy 2026-10-03 — TRƯỚC 10.4/10.5, lệch thứ tự có chủ đích** (user chấp nhận
> cửa sổ): `directAccessGrantsEnabled=false` (PUT full-replace, attrs pkce/post-logout giữ
> nguyên), ROPC `web-grading-fe` → `400 unauthorized_client`, gateway **local** đổi MK vẫn
> `400`/`204` = chứng minh đi qua `wgs-password-verify`. Hệ quả: gateway **cluster** (image
> cũ chưa có env password) đổi MK trả `502` tới khi MR backend được deploy (§10.4) — curl
> verify §10.4 chạy sau đó là verify dứt điểm luôn.

```bash
curl -sS -H "Authorization: Bearer $TOKEN" \
  "$BASE/admin/realms/ptit-wgs/clients/$CID_FE" -o /tmp/fe-client.json
python3 - <<'PY'
import json
p = "/tmp/fe-client.json"
c = json.load(open(p))
print("before:", c.get("directAccessGrantsEnabled"))
c["directAccessGrantsEnabled"] = False
json.dump(c, open(p, "w"), ensure_ascii=False, indent=2)
PY
curl -sS -o /dev/null -w 'PUT -> HTTP %{http_code}\n' -X PUT \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary @/tmp/fe-client.json "$BASE/admin/realms/ptit-wgs/clients/$CID_FE"

# ROPC của client trình duyệt phải CHẾT:
curl -sS -o /dev/null -w 'ROPC web-grading-fe -> HTTP %{http_code}\n' -X POST \
  "$BASE/realms/ptit-wgs/protocol/openid-connect/token" \
  --data-urlencode 'grant_type=password' --data-urlencode 'client_id=web-grading-fe' \
  --data-urlencode 'username=lecturer_test' --data-urlencode 'password=<MK đúng>'
# mong đợi 400 (invalid_client / unauthorized_client)

# và endpoint đổi mật khẩu vẫn sống — CHẠY LẠI 2 curl của §10.4:
#   sai MK  -> 400      đúng MK -> 204
```

**Verify:** cả `400` + `204` ở trên — **không** được `502`.
**Nếu trả `502`, env var chưa được wiring — nói đúng như vậy:** `KEYCLOAK_PASSWORD_CLIENT_ID`/
`KEYCLOAK_PASSWORD_CLIENT_SECRET` chưa tới gateway. Kiểm theo thứ tự: `.env` (§10.2) →
`./deploy/setup-namespace.sh` (secret có 2 key chưa) → `templates/deployment.yaml` (env có
entrée chưa) → pod mới đã roll chưa (`kubectl exec … printenv`). Endpoint này **không** tự
hồi được — cứ để đó là mọi user đổi được mật khẩu đều thấy 502.

### 10.7 Refresh realm export + dọn secret/client thừa

Bản export `src-services/keycloak/ptit-wgs-realm.json` **không trung thực**: không chứa
`web-grading-fe` (client này chỉ sống ở realm live, xem skill `keycloak` §1) → re-import là
mất app. Export lại từ realm **live** (Admin Console → Realm settings → **Partial export**,
tick *Clients* + *Roles* + *Users*), rồi sanitize:

```bash
python3 - <<'PY'
import json
p = "src-services/keycloak/ptit-wgs-realm.json"
r = json.load(open(p))
ids = sorted(c["clientId"] for c in r.get("clients", []))
print("clients:", ids)
# 1. secret KHÔNG được nằm trong git — với MỌI client confidential
for c in r.get("clients", []):
    c.pop("secret", None)
# 2. 2 client của Phase 3 phải có mặt
missing = {"web-grading-fe", "wgs-password-verify"} - set(ids)
print("missing:", missing or "none")
json.dump(r, open(p, "w"), ensure_ascii=False, indent=2)
PY
```

**`wgs-postman` — kiểm trước khi giữ:** client này đang có `redirectUris: ["*"]` +
`webOrigins: ["+"]` + Direct Access Grants ON. Repo grep ngày 2026-10-03:

```bash
grep -rn "wgs-postman" --exclude-dir=node_modules --exclude-dir=.git . | grep -v 'skills/\|docs/\|realm'
# kỳ vọng: không ra gì — chỉ docs/skill/export nhắc tới, không code, không collection Postman nào dùng
```

Nếu không còn bộ test nào dùng (hỏi lại người từng tạo) → **thu hẹp** (`redirectUris` đúng
origin của Postman app, `webOrigins` explicit, hoặc xoá hẳn client); **không** để `*` cho
client có direct grants.

**Verify:** chạy đoạn python → `missing: none`, và file không còn trường `secret` nào
(`grep -c '"secret"' src-services/keycloak/ptit-wgs-realm.json` → `0`).

### 10.8 ⚠️ Checklist bắt buộc: FE origin khi deploy ra nơi khác

FE **hiện chỉ dev** tại `http://localhost:5173` — không có FE ingress/Dockerfile nào trong
`deploy/`. `redirectUris`/`webOrigins` phía trên vì vậy **chỉ** chứa origin dev.

> **MOMENT FE deploy ở bất kỳ origin nào khác** (Dockerfile, ingress, static host…):
> origin đó **PHẢI** được thêm vào **cả** `redirectUris` **và** `webOrigins` của
> `web-grading-fe` NGAY, không là login chạy xong **không quay về được app**
> (`invalid_redirect_uri`) — thêm origin mới **không** được xoá origin dev khi còn dev.

**Verify:**

```bash
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/admin/realms/ptit-wgs/clients/$CID_FE" \
  | python3 -c 'import sys,json;c=json.load(sys.stdin);print("redirectUris:",c["redirectUris"]);print("webOrigins:",c["webOrigins"])'
# mọi origin đang deploy phải xuất hiện ở cả 2 danh sách
```

### 10.9 E2E verification matrix (chạy đủ 12 mục — plan §6)

| # | Check | Chứng minh |
|---|---|---|
| 1 | `npm run build` + `npm run lint` | pass |
| 2 | `./mvnw test` (gateway) | 43+ (D11=A → có test mới cho `client_secret`) — tại thời điểm ghi: **44** |
| 3 | **Không còn `grant_type=password` trong `dist/assets/*.js`** | **R3** |
| 4 | **`localStorage['wgs.auth']` không tồn tại / không chứa token** | **R4** |
| 5 | Login → redirect Keycloak → quay lại app có role | luồng mới (D7) |
| 6 | **Reload trang** → không bị đá về `/login` (D8-A) hoặc chỉ nháy redirect (fallback) | bootstrap gate |
| 7 | 401 → tự refresh → request chạy tiếp | interceptor giữ nguyên |
| 8 | 2 tab cùng user, thao tác song song | không đá nhau |
| 9 | Logout → refresh token cũ dùng lại **fail** | full-page logout terminate session (D12, 2026-10-03) |
| 10 | User có mật khẩu tạm → Keycloak hiện `UPDATE_PASSWORD` | D10 |
| 11 | Đổi MK tự nguyện qua modal → `204`; MK yếu → `400 weak_password` | gateway còn sống |
| 12 | Student vào `/classes` → `/no-role`, không logout | role gate không đổi |

**Verify:** 12/12 check pass, ghi lại kết quả vào plan §6 (mục này copy từ đó — nếu lệch thì
plan là nguồn sự thật và file này phải sửa theo).
