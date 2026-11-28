# 07 — Secret và biến môi trường

> Nguyên tắc của đồ án: **không một credential nào nằm trong Git**. Git chỉ chứa
> *tên* Secret và *tên* key; giá trị đi vào cụm qua `deploy/setup-namespace.sh`
> đọc từ `.env` (đã gitignore).

---

## 1. `.env` là gì trong đồ án này

| Đặc điểm | Chi tiết |
|---|---|
| Vị trí | `<repo>/.env` (root), gitignore ở `.gitignore:31` (`**/.env`) |
| Ai đọc | `deploy/setup-namespace.sh`, `deploy/observability/install.sh` (file riêng), `set-log-level.sh`, `setup.sh` (chỉ `GATEWAY_PORT`) |
| Quyền file nên đặt | `chmod 600 .env` (hiện có thể là `644` ⇒ nên siết) |
| Mẫu | `.env.example` — **không** chứa giá trị thật, chỉ tên biến + giải thích |
| Ai không đọc | Không service nào đọc `.env` trực tiếp; tất cả đọc env do Kubernetes inject từ Secret |

Các file bị gitignore liên quan trực tiếp:

```
**/.env
**/.env.observability
**/cloudflare_tunnel_run.sh        # chứa token tunnel
**/docker/kafka-ca.pem             # CA của Aiven
**/config-services/**              # repo riêng (ArgoCD đọc bản trên GitHub)
**/src-services/**                 # repo riêng
```

---

## 2. Tám Secret của namespace `web-grading`

| # | Secret | Key | Ai đọc | Giá trị lấy từ | Sai/thiếu thì hỏng thế nào |
|---|---|---|---|---|---|
| 1 | `db-secret` | `DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD` | 6 service (gateway không dùng) | `.env` | Sai host ⇒ API 500 dù pod Ready; sai password ⇒ health DOWN ⇒ readiness fail |
| 2 | `rustfs-secret` | `RUSTFS_ENDPOINT`, `RUSTFS_PUBLIC_ENDPOINT`, `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY` | submission, executor **và chính pod RustFS** | `.env` | Sai endpoint ⇒ presign/upload hỏng; sai key ⇒ upload 403 |
| 3 | `app-config` | `APP_LOG_LEVEL` | 6 service | `.env` hoặc `set-log-level.sh` | Sai level ⇒ app vẫn chạy, chỉ log khác (không phải lỗi chặn) |
| 4 | `gateway-trust` | `GATEWAY_TRUSTED_SECRET` | gateway (đóng dấu) + course/result/submission (kiểm tra) | `.env` → cụm → sinh mới | **Lệch/thiếu ⇒ 401 toàn bộ API có auth** (fail closed) |
| 5 | `kafka-aiven-credentials` | `username`, `password`, `bootstrap-servers`, `ca.pem` | submission (producer), executor (consumer), Kafka UI | `.env` + `KAFKA_CA_PATH` | Thiếu ⇒ upload xong nhưng bài **mãi PENDING** (không có event) |
| 6 | `keycloak-db` | `KEYCLOAK_DB_URL`, `KEYCLOAK_DB_USERNAME`, `KEYCLOAK_DB_PASSWORD`, `KEYCLOAK_ADMIN_USERNAME`, `KEYCLOAK_ADMIN_PASSWORD` | pod Keycloak | `.env` | Sai URL ⇒ Keycloak CrashLoop; sai admin ⇒ chỉ mất lần bootstrap admin đầu |
| 7 | `keycloak-admin-client` | `KEYCLOAK_ADMIN_CLIENT_ID`, `KEYCLOAK_ADMIN_CLIENT_SECRET`, `KEYCLOAK_PASSWORD_CLIENT_ID`, `KEYCLOAK_PASSWORD_CLIENT_SECRET` | gateway | `.env` (**bắt buộc**, script `exit 1` nếu thiếu) | Thiếu ⇒ đổi mật khẩu 502; nửa cặp ⇒ `invalid_client` ⇒ 502 |
| 8 | `ai-credentials` | `AI_PROVIDER`, `AI_API_KEY`, `AI_MODEL_NAME`, `AI_BASE_URL`, `AI_AGENT_*` (4), `AI_EXPLAIN_*` (4) | ai-assistant-service | `.env` (`AI_API_KEY` rỗng **hợp lệ**) | Rỗng ⇒ fallback template, không lỗi |

Secret ngoài `web-grading`:

| Secret | Namespace | Do ai tạo | Ghi chú |
|---|---|---|---|
| `argocd-initial-admin-secret` | `argocd` | ArgoCD | Mật khẩu admin ban đầu; `install-argocd.sh` in ra |
| `monitoring-grafana` | `observability` | helm (từ `--set grafana.adminPassword`) | Lấy từ `.env.observability`; **không** hardcode trong values |
| `tempo-*`, `monitoring-*` | `observability` | helm | Secret nội bộ của chart |

---

## 3. Bảng biến trong `.env.example` (theo nhóm)

### 3.1 Cụm và cổng

| Biến | Mặc định | Ai dùng | Ý nghĩa |
|---|---|---|---|
| `GATEWAY_PORT` | `31242` | `setup.sh` | NodePort của Traefik entrypoint `web` — **mỗi máy khác nhau** |
| `NAMESPACE` | `web-grading` | script | Namespace đích |
| `DOMAIN` | `vucongtuanduong.dpdns.org` | tài liệu/tunnel | Domain public |
| `TUNNEL_NAME` | `web-dev1-web-grading` | Cloudflare dashboard | Tên tunnel (không dùng trong code) |

### 3.2 Database

| Biến | Ý nghĩa |
|---|---|
| `JDBC_URL` | JDBC đầy đủ (ưu tiên nếu có); dùng khi chạy service ngoài cụm |
| `DB_HOST` / `DB_PORT` / `DB_USERNAME` / `DB_PASSWORD` | **Bộ 4 biến thực sự đi vào Secret `db-secret`** |
| `DB_NAME` | Chỉ dùng khi chạy local; trong cụm DB name lấy từ `values-stg.yaml` |

### 3.3 RustFS

| Biến | Ý nghĩa | Bẫy |
|---|---|---|
| `RUSTFS_ENDPOINT` | Endpoint **nội bộ** (`http://rustfs:9000`) dùng để SDK ký | |
| `RUSTFS_PUBLIC_ENDPOINT` | Host **public** xuất hiện trong presigned URL | Sai ⇒ FE upload tới host không phân giải được, backend không có log |
| `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` | Root credential, dùng cho **cả server và client** | |
| `RUSTFS_BUCKET_NAME` | `submission-files` | Không nằm trong Secret; chart hardcode env |
| `PRESIGNED_URL_EXPIRY_MINUTES` | `15` | Chỉ dùng khi chạy submission-service ngoài cụm; chart **không** inject biến này vào pod (giá trị trong cụm lấy từ `application-stg.yaml` của service) |

### 3.4 Kafka (Aiven)

`KAFKA_BOOTSTRAP_SERVERS`, `KAFKA_USERNAME`, `KAFKA_PASSWORD`, `KAFKA_CA_PATH` —
cả 4 vào Secret `kafka-aiven-credentials`, trong đó `KAFKA_CA_PATH` trỏ tới file
CA trên máy bạn để `--from-file=ca.pem=`.

### 3.5 Keycloak

| Biến | Bắt buộc | Ý nghĩa |
|---|---|---|
| `KEYCLOAK_DB_URL` / `KEYCLOAK_DB_USERNAME` / `KEYCLOAK_DB_PASSWORD` | Có | DB của Keycloak (Neon, database riêng) |
| `KEYCLOAK_ADMIN_USERNAME` / `KEYCLOAK_ADMIN_PASSWORD` | Không (mặc định `admin`) | Chỉ dùng ở lần bootstrap đầu |
| `KEYCLOAK_ISSUER_URI` | Có (dùng cho local) | Phải khớp `KC_HOSTNAME` của pod Keycloak |
| `KEYCLOAK_ADMIN_CLIENT_ID` / `_SECRET` | **Có** | Client service-account `wgs-user-service` |
| `KEYCLOAK_PASSWORD_CLIENT_ID` / `_SECRET` | Cặp (cùng có hoặc cùng trống) | Client `wgs-password-verify` |

### 3.6 Gateway và bảo mật

| Biến | Ý nghĩa |
|---|---|
| `GATEWAY_TRUSTED_SECRET` | Để trống ⇒ script tái dùng giá trị trong cụm, hoặc sinh mới nếu cụm trống. Điền giá trị ⇒ **xoay vòng có chủ đích** |
| `VALKEY_URL` | URL Valkey cho rate limit endpoint đổi mật khẩu; trống ⇒ tắt rate limit (Keycloak brute-force vẫn bảo vệ) |

### 3.7 AI

`AI_PROVIDER`, `AI_API_KEY`, `AI_MODEL_NAME`, `AI_BASE_URL` + 4 biến `AI_AGENT_*`
+ 4 biến `AI_EXPLAIN_*`. Tất cả đi vào Secret `ai-credentials`.

### 3.8 Observability (file riêng `deploy/observability/.env.observability`)

| Biến | Ý nghĩa |
|---|---|
| `GRAFANA_ADMIN_PASSWORD` | Bắt buộc (`install.sh` dùng `: "${...:?}"` để fail nếu thiếu) |
| `GRAFANA_DOMAIN` | Phải khớp host trong `manifests/ingress/grafana.yaml`, nếu không redirect/login sai |

---

## 4. Ma trận: biến nào tới service nào

| Biến (env trong pod) | gateway | course | submission | executor | result | ai |
|---|---|---|---|---|---|---|
| `SPRING_PROFILES_ACTIVE` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `DB_HOST/PORT/USERNAME/PASSWORD` | ✅ (không dùng) | ✅ | ✅ | ✅ | ✅ | ✅ |
| `DB_NAME` | ✅ (rỗng) | ✅ | ✅ | ✅ | ✅ | ✅ |
| `REGION`, `CLUSTER` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `APP_LOG_LEVEL` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `GATEWAY_TRUSTED_SECRET` | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| `RUSTFS_*` (4 biến) | — | — | ✅ | ✅ | — | — |
| `KAFKA_*` (3 + CA path) | — | — | ✅ | ✅ | — | — |
| `WGS_EVENTS_TOPIC` | — | — | ✅ | ✅ | — | — |
| `COURSE_SERVICE_URI` | ✅ | — | — | — | ✅ | ✅ |
| `SUBMISSION_SERVICE_URI` | ✅ | — | — | — | — | — |
| `RESULT_SERVICE_URI` | ✅ | — | — | — | — | ✅ |
| `AI_ASSISTANT_SERVICE_URI` | ✅ | — | — | — | — | — |
| `FEIGN_EXECUTOR_SERVICE_URL` | — | ✅ | — | — | — | — |
| `COURSE/SUBMISSION/RESULT_SERVICE_URL` | — | — | — | ✅ | — | — |
| `KEYCLOAK_ISSUER_URI` | ✅ | — | — | — | — | — |
| `KEYCLOAK_ADMIN_*`, `KEYCLOAK_PASSWORD_*` | ✅ | — | — | — | — | — |
| `RATE_LIMIT_ENABLED` | ✅ | — | — | — | — | — |
| `AI_*`, `AGENT_*` | — | — | — | — | — | ✅ |
| `DOCKER_HOST`, `TESTCONTAINERS_RYUK_DISABLED`, `RUSTFS_BUCKET_NAME` | — | — | — | ✅ | — | — |

Điểm đáng chú ý khi bị hỏi:

- **`GATEWAY_TRUSTED_SECRET` không có ở executor**: executor nhận request từ Kafka
  và từ course-service (Feign, đường nội bộ), không đi qua gateway.
- **course/result/ai có `COURSE_SERVICE_URI`/`RESULT_SERVICE_URI`**: chúng gọi
  nhau bằng internal API (đường tắt trong cụm, không qua gateway).
- **gateway có DB_* nhưng không dùng**: boilerplate chart; xem
  [03](03-helm-chart-va-tham-so.md) §3.3.

---

## 5. Xoay vòng (rotation) từng nhóm

### 5.1 Quy trình chung

```
1. Sửa .env (hoặc giá trị trong Keycloak/Neon)
2. bash deploy/setup-namespace.sh          # ghi Secret mới
3. kubectl -n web-grading rollout restart deployment/grading-<svc>   # BẮT BUỘC
4. Kiểm tra: kubectl exec ... env | grep <KEY>; gọi 1 API thật
```

**Vì sao bước 3 bắt buộc:** env `valueFrom.secretKeyRef` chỉ được đọc **một lần**
khi container start. Sửa Secret không làm container restart, nên pod vẫn dùng giá
trị cũ. Đây là lỗi "đã đổi secret mà vẫn 401" phổ biến nhất.

### 5.2 Từng Secret

| Secret | Cách xoay | Lưu ý riêng |
|---|---|---|
| `db-secret` | Đổi password trong Neon → `.env` → script → restart 5 service | Neon cho phép nhiều role; nên tạo role mới rồi chuyển |
| `rustfs-secret` | Đổi `RUSTFS_*_KEY` → script → **restart cả pod RustFS và submission/executor** | RustFS đọc credential lúc start; đổi một phía là 403 |
| `gateway-trust` | `.env` đặt giá trị mới → script → restart **gateway + course + result + submission cùng lúc** | Trong khoảng giữa 2 lần restart sẽ có 401; nên làm khi không có traffic |
| `kafka-aiven-credentials` | Đổi trong Aiven → `.env` → script → restart submission/executor/kafka-ui | CA pem cũng có thể đổi theo |
| `keycloak-db` | Đổi trong Neon → `.env` → script → restart Keycloak | Keycloak không tự migrate nếu URL sai ⇒ CrashLoop |
| `keycloak-admin-client` | Tạo secret mới trong Keycloak Admin Console → `.env` → script → restart gateway | Script từ chối cặp nửa vời |
| `ai-credentials` | Đổi key/model → `.env` → script → restart ai-assistant | Không cần restart nếu chỉ đổi model name? **Có** — vì env chỉ đọc lúc start |
| `app-config` | `bash set-log-level.sh DEBUG` | Script tự restart toàn bộ |
| Grafana admin | Sửa `.env.observability` → `bash deploy/observability/install.sh` (helm upgrade) | `helm upgrade` tự restart Grafana |

### 5.3 Kiểm tra an toàn (không in secret ra terminal dùng chung)

```bash
# chỉ in độ dài, không in giá trị
kubectl -n web-grading get secret gateway-trust \
  -o jsonpath='{.data.GATEWAY_TRUSTED_SECRET}' | base64 -d | wc -c

# so sánh 2 nơi mà không lộ giá trị
a=$(kubectl -n web-grading get secret gateway-trust -o jsonpath='{.data.GATEWAY_TRUSTED_SECRET}')
b=$(kubectl -n web-grading exec deploy/grading-api-gateway -- printenv GATEWAY_TRUSTED_SECRET | base64 -w0)
[ "$a" = "$b" ] && echo MATCH || echo MISMATCH
```

---

## 6. Những sai lầm đã gặp thật (nên kể như bài học)

| Sai lầm | Triệu chứng | Nguyên nhân gốc |
|---|---|---|
| Chạy lại `setup-namespace.sh` sinh `gateway-trust` mới trong khi pod đang chạy | 401 toàn bộ API | Secret mới ≠ env trong pod; phải restart. Script đã được sửa để **tái dùng** giá trị trong cụm |
| Điền mật khẩu staging vào **Initial value** của Postman Environment | Vô tình commit credential | Initial value được sync/export; chỉ điền **Current value** |
| Dùng chung client `web-grading-fe` cho password grant | `unauthorized_client` | Phase 3 tắt Direct Access Grants trên client browser; phải dùng `wgs-postman`/`wgs-password-verify` |
| `KEYCLOAK_PASSWORD_CLIENT_ID` có nhưng secret rỗng | 502 ở endpoint đổi mật khẩu | Cặp nửa vời ⇒ `invalid_client`; script đã chặn |
| `RUSTFS_PUBLIC_ENDPOINT` để host nội bộ | Upload từ browser lỗi mạng | Trình duyệt không phân giải được `rustfs` |
| Đổi `.env` nhưng không restart | "Đã sửa mà không có tác dụng" | env chỉ đọc lúc container start |
| `AI_API_KEY` để trống và tưởng là lỗi | Log có fallback, không có exception | Thiết kế: trống = dùng template sư phạm cục bộ |

---

## 7. Checklist trước khi trình bày/demo

```bash
# 1. 8 Secret tồn tại trong web-grading
kubectl -n web-grading get secret

# 2. Không có key nào rỗng ở 3 secret bắt buộc
for s in gateway-trust keycloak-admin-client; do
  kubectl -n web-grading get secret "$s" -o go-template='{{range $k,$v := .data}}{{$k}}={{len $v}} {{end}}{{"\n"}}'
done

# 3. gateway và service dùng cùng trust secret (so sánh, không in)
# 4. .env không nằm trong git
git check-ignore -v .env deploy/observability/.env.observability cloudflare_tunnel_run.sh

# 5. Không có credential trong manifest đã commit
git grep -nE 'BEGIN (RSA|OPENSSH) PRIVATE KEY|password: [^ ]|token [A-Za-z0-9_-]{20,}' -- deploy/ || echo "clean"
```

Kết quả mong đợi của bước 4: cả 3 file đều hiện `.gitignore:<dòng>:<pattern>`.
Nếu bước 5 in ra dòng nào, đó là credential đã lọt vào Git — phải xoay vòng ngay,
không chỉ xoá file (lịch sử Git vẫn còn).
