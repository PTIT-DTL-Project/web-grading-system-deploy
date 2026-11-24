# 02 — Danh mục file: từng file làm gì

> Cách đọc: mỗi file có 5 dòng cố định — **Mục đích**, **Tạo ra / thay đổi gì**,
> **Chạy khi nào**, **Phụ thuộc**, **Lưu ý**. Nếu chỉ có thời gian đọc một mục,
> đọc bảng [1. Thứ tự chạy](#1-thứ-tự-chạy-tổng-thể).

---

## 1. Thứ tự chạy tổng thể

```
setup.sh  (chạy 1 lần khi dựng cụm mới)
 ├─[1] kiểm tra/khởi động k3s
 ├─[2] deploy/setup-namespace.sh          → namespace + 8 Secret + gateway-trust
 ├─[3] deploy/install-rustfs.sh           → PVC + Service + Deployment + Ingress (RustFS)
 ├─[4] deploy/install-ingress.sh          → 7 Ingress của service + Keycloak
 ├─[5] deploy/install-argocd.sh           → cài ArgoCD, sinh & apply 6 Application
 ├─[6] deploy/observability/install.sh    → Prometheus + Grafana + Tempo + Ingress Grafana
 ├─[7] kubectl apply deploy/keycloak/*    → Keycloak
 └─[8] cloudflare_tunnel_run.sh (tay)     → tunnel ra Internet
```

Sau bước 5, **6 microservice do ArgoCD tạo** — `setup.sh` không `kubectl apply`
service nào. Đây là điểm khác biệt cốt lõi so với cách deploy truyền thống.

Script vòng đời (dùng hàng ngày, không phải cài đặt):

| Script | Khi dùng | Tác động |
|---|---|---|
| `start.sh` | sau khi reboot | `systemctl start k3s`, chờ node Ready, in trạng thái |
| `stop.sh` | trước khi tắt máy | `systemctl stop k3s` (pod dừng, dữ liệu PVC còn) |
| `status.sh` | kiểm tra nhanh | đọc trạng thái, **không thay đổi gì** |
| `clean.sh` | reset toàn bộ | xoá 3 namespace + toàn bộ image trong containerd (giữ PVC) |
| `dev-scale.sh` | dev local | scale 1 service về 0/N, tạm treo ArgoCD sync |
| `set-log-level.sh` | debug | đổi `APP_LOG_LEVEL` cho cả 6 service |

---

## 2. `deploy/setup-namespace.sh` — nền móng của mọi thứ

**Mục đích.** Tạo namespace `web-grading` và **8 Secret** mà toàn bộ manifest
khác tham chiếu tới. Không có bước này, mọi pod sẽ kẹt ở
`CreateContainerConfigError`.

**Tạo ra / thay đổi gì.**

| Secret | Key | Nguồn giá trị |
|---|---|---|
| `db-secret` | `DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD` | `.env` (mặc định `postgres-service`/`5432`/`postgres`) |
| `rustfs-secret` | `RUSTFS_ENDPOINT`, `RUSTFS_PUBLIC_ENDPOINT`, `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY` | `.env` |
| `app-config` | `APP_LOG_LEVEL` | `.env`, mặc định `INFO` |
| `gateway-trust` | `GATEWAY_TRUSTED_SECRET` | `.env` nếu có; nếu không thì **tái dùng giá trị đang có trong cụm**; nếu cụm chưa có thì `openssl rand -hex 32` |
| `kafka-aiven-credentials` | `username`, `password`, `bootstrap-servers`, `ca.pem` (file) | `.env` + `KAFKA_CA_PATH` |
| `keycloak-db` | `KEYCLOAK_DB_URL/USERNAME/PASSWORD`, `KEYCLOAK_ADMIN_USERNAME/PASSWORD` | `.env` |
| `keycloak-admin-client` | `KEYCLOAK_ADMIN_CLIENT_ID/SECRET`, `KEYCLOAK_PASSWORD_CLIENT_ID/SECRET` | `.env` (bắt buộc, xem dưới) |
| `ai-credentials` | `AI_PROVIDER/API_KEY/MODEL_NAME/BASE_URL` + 4 biến `AI_AGENT_*` + 4 biến `AI_EXPLAIN_*` | `.env`, `AI_API_KEY` rỗng là hợp lệ |

**Chạy khi nào.** Một lần khi dựng cụm; chạy lại an toàn (mọi lệnh đều
`--dry-run=client -o yaml | kubectl apply -f -`).

**Phụ thuộc.** `kubectl` trỏ đúng cụm; file `.env` ở root repo (không bắt buộc —
script có giá trị mặc định, trừ 2 nhóm Keycloak bên dưới).

**Lưu ý (rất hay bị hỏi).**

1. **`gateway-trust` không tự sinh lại mỗi lần chạy.** Cập nhật Secret **không**
   làm pod restart, nên nếu script sinh secret mới trong khi pod đang chạy bằng
   secret cũ, mọi request sẽ 401 cho tới khi restart toàn bộ. Vì vậy logic là:
   `.env` có giá trị → dùng (xoay vòng có chủ đích); không có → đọc lại từ cụm;
   cụm trống → mới sinh mới.
2. **`gateway-trust` rỗng là fail closed**, không phải "tắt kiểm tra": 3 service
   (course/result/submission) sẽ trả 401 cho mọi request có xác thực.
3. **`keycloak-admin-client` fail loudly**: thiếu `KEYCLOAK_ADMIN_CLIENT_ID` hoặc
   `_SECRET` là script `exit 1` — vì giá trị này đến từ Keycloak (không tự sinh
   được), và secret rỗng sẽ âm thầm làm hỏng chức năng đổi mật khẩu.
4. Cặp `KEYCLOAK_PASSWORD_CLIENT_ID/SECRET` phải **đi cùng nhau**; set một nửa là
   `exit 1` (nửa cấu hình ⇒ `invalid_client` ⇒ 502 ở endpoint đổi mật khẩu).
5. Script `source` `.env` với `set -o allexport`, nên mọi biến trong `.env` đều
   trở thành biến môi trường của tiến trình — không tự bịa thêm tên biến.

---

## 3. `deploy/install-rustfs.sh` — object storage

**Mục đích.** Deploy RustFS (S3-compatible) để lưu file ZIP bài nộp, theo đúng
thứ tự PVC → Service → Deployment → Ingress.

**Tạo ra / thay đổi gì.** `kubectl apply` 4 file trong `deploy/rustfs/`; chờ pod
`app=rustfs` ready (timeout 120s, không fail cứng nếu chậm).

**Chạy khi nào.** Sau `setup-namespace.sh` (vì cần `rustfs-secret`), trước khi
submission-service nhận bài.

**Phụ thuộc.** Secret `rustfs-secret`. Script **kiểm tra trước** và in thông báo
hành động được nếu thiếu, thay vì để `kubectl apply` "thành công" rồi pod kẹt
`CreateContainerConfigError`.

**Lưu ý.** RustFS **không** do ArgoCD quản lý — sửa manifest thì phải
`kubectl apply` lại bằng tay (hoặc chạy lại script). README của thư mục ghi rõ
điều này.

---

## 4. `deploy/install-ingress.sh` — 7 Ingress của namespace `web-grading`

**Mục đích.** Apply toàn bộ `deploy/ingress/*.yaml` vào namespace đang dùng.

**Tạo ra / thay đổi gì.** 7 Ingress: `api-gateway`, `course-service`,
`submission-service`, `result-service`, `grading-service` (executor),
`ai-assistant-service`, `keycloak`. Chi tiết host → service → port ở
[05-ingress-va-cloudflare.md](05-ingress-va-cloudflare.md).

**Chạy khi nào.** Sau khi đã có namespace; có thể chạy trước khi service tồn tại
(Ingress trỏ tới Service chưa có chỉ đơn giản là 503, không lỗi cú pháp).

**Phụ thuộc.** Traefik (k3s cài sẵn, `ingressClassName: traefik`).

**Lưu ý.** Thư mục này còn một file `.env.observability.example` **không dùng
nữa** (nội dung nói về Alloy/Pyroscope — phiên bản observability cũ). Nó không
khớp `*.yaml` nên script không apply; coi là rác lịch sử, đừng sửa nó để "cấu
hình observability" — file đúng là `deploy/observability/.env.observability`.

---

## 5. `deploy/install-argocd.sh` — cài ArgoCD và giao quyền triển khai

**Mục đích.** Cài ArgoCD, ép nó chạy sau reverse proxy, tạo 6 Application trỏ
vào repo config, và **giới hạn RAM** cho từng thành phần ArgoCD.

**Tạo ra / thay đổi gì** (theo đúng thứ tự trong script):

1. Namespace `argocd`.
2. `kubectl apply -n argocd --server-side --force-conflicts -f .../argo-cd/stable/manifests/install.yaml`.
3. `kubectl wait` pod ArgoCD Ready (300s, `|| true` để không chặn).
4. Patch `argocd-server` thêm `--insecure` (vì TLS đã kết thúc ở Cloudflare).
5. Apply `deploy/argocd-ingress.yaml` (host `web-dev1-argocd...`).
6. Patch Service `argocd-server` về `ClusterIP` (bản upstream có thể tạo
   LoadBalancer — vô nghĩa trên k3s 1 node).
7. `generate-argocd-apps.sh` → sinh `generated/*.yaml`.
8. `kubectl apply -f generated/` → 6 Application.
9. `kubectl set resources` cho application-controller/repo-server/server/redis/dex.
10. `scale --replicas=0` cho notifications-controller và applicationset-controller.
11. In ra mật khẩu admin ban đầu.

**Chạy khi nào.** Một lần mỗi cụm; chạy lại an toàn (idempotent) trừ bước 11 (chỉ đọc).

**Phụ thuộc.** Internet (tải install.yaml), `kubectl`, repo config public.

**Lưu ý.**

- `--server-side --force-conflicts` là bắt buộc: CRD của ArgoCD quá lớn cho
  client-side apply (giới hạn 256 KB annotation).
- Bước 9 là để chống OOM: bản upstream không đặt requests/limits, nên trên node
  8 GB kernel sẽ chọn pod có RSS lớn nhất (thường `repo-server`) để kill, và toàn
  bộ sync dừng cho tới khi nó restart.
- Bước 10 tiết kiệm ~120–160 MiB: đồ án không dùng ApplicationSet (manifest sinh
  bằng script) và không có template notification nào.
- Bước 6–8 cho thấy ArgoCD chỉ **đọc** repo config; nó không ghi gì vào repo.

---

## 6. `deploy/argocd-apps/` — nơi định nghĩa "triển khai cái gì, từ đâu"

| File | Vai trò |
|---|---|
| `argocd-app-template.yaml` | Mẫu `Application`: repo config, `path: ${SERVICE_NAME}`, `valueFiles: [values-stg.yaml]`, đích `web-grading`, `syncPolicy.automated {prune, selfHeal}` |
| `services.env` | Danh sách 6 service (mỗi dòng một tên) — nguồn duy nhất cho cả `generate-argocd-apps.sh` và `dev-scale.sh`, `set-log-level.sh` |
| `generate-argocd-apps.sh` | `sed` thay `${SERVICE_NAME}` → sinh `generated/<service>.yaml` |
| `generated/` | Kết quả sinh ra — **gitignored**, không commit |
| `README.md` | Hướng dẫn dùng + mô tả luồng GitOps |

**Vì sao dùng template + script thay vì ApplicationSet:** ArgoCD ApplicationSet
cần một controller chạy thường trực (tốn RAM) và thêm một lớp CR. Với 6 service
cố định, sinh 6 file YAML là đủ và minh bạch — nhìn repo biết ngay có 6 app.

**Lưu ý.** `services.env` là **single source of truth**: thêm service mới = thêm 1
dòng vào đây, chạy lại `generate-argocd-apps.sh`, apply; `dev-scale.sh` và
`set-log-level.sh` tự nhận service mới.

---

## 7. `deploy/ingress/*.yaml` và `deploy/argocd-ingress.yaml`

7 Ingress của nghiệp vụ (namespace `web-grading`) + 1 Ingress của ArgoCD
(namespace `argocd`). Cấu trúc giống nhau: `ingressClassName: traefik`,
`rules[].host`, `paths[].pathType: Prefix`, `backend.service.name/port`.

Điểm cần biết: **không có `tls:`** trong bất kỳ Ingress nào — TLS kết thúc ở
Cloudflare, Traefik chỉ nghe HTTP. ArgoCD Ingress có thêm annotation
`traefik.ingress.kubernetes.io/router.entrypoints: web` để chắc chắn đi vào
entrypoint HTTP (không phải `websecure`).

---

## 8. `deploy/keycloak/` — OIDC provider

| File | Nội dung |
|---|---|
| `deployment.yaml` | 1 replica, image `quay.io/keycloak/keycloak:26.0`, `args: [start-dev]`, DB Postgres, hostname strict + proxy `edge`, JVM heap ép theo %RAM, `KC_METRICS_ENABLED=false`, resources 384Mi–768Mi |
| `service.yaml` | `ClusterIP`, port 8080 → 8080 |

**Vì sao `start-dev`:** đây là môi trường staging/đồ án, cần khởi động nhanh và
không yêu cầu cấu hình TLS nội bộ; `start-dev` **không** dùng cho production
(không cache cluster, cảnh báo trong log). Đây là điểm nên chủ động nêu khi bị
hỏi "sao không dùng `start`".

**Vì sao ép `-XX:MaxRAMPercentage=60`:** trước đây container không có memory
limit, JVM định cỡ heap theo RAM **của node** (7,6 GB) nên Keycloak chiếm
0,8–1,2 GB. Với limit 768Mi và `MaxRAMPercentage=60`, heap có trần xác định
(~460Mi) bất kể node còn bao nhiêu RAM; `InitialRAMPercentage=20` giữ heap khởi
tạo ~154Mi; phần còn lại cho metaspace/thread stack/code cache. Không chỉ định
GC vì thêm collector thứ hai làm JVM thoát với "Multiple garbage collectors
selected".

---

## 9. `deploy/rustfs/` — object storage

| File | Nội dung |
|---|---|
| `pvc.yaml` | `rustfs-pvc`, `ReadWriteOnce`, 10Gi, storage class mặc định (`local-path`) |
| `service.yaml` | `ClusterIP`, 9000 (S3 API) + 9001 (console) |
| `deployment.yaml` | 1 replica, image `rustfs/rustfs:1.0.5` (ghim, không `latest`), credentials từ `rustfs-secret`, webhook notify tới submission-service, CORS cho FE, resources 128Mi–512Mi |
| `ingress.yaml` | 2 host: console `web-dev1-rustfs...` → 9001, API `web-dev1-rustfs-api...` → 9000 |
| `README.md` | Quy tắc CORS + cách thêm origin mới + lệnh kiểm tra preflight |

Ba chi tiết đáng nhớ:

1. **`imagePullPolicy: IfNotPresent` + tag ghim** — với `latest` + `IfNotPresent`,
   mỗi node giữ bản build đầu tiên nó pull, nên phiên bản đang chạy là không xác
   định. Ghim 1.0.5 để pod restart không âm thầm đổi phiên bản S3 server giữa kỳ.
2. **Root credential lấy từ cùng Secret mà client đọc** ⇒ server và client không
   thể lệch nhau; `optional` **không** được set trên 2 key này, thiếu Secret thì
   pod phải fail ngay (`CreateContainerConfigError`) chứ không chạy với
   credential rỗng.
3. **Webhook nối vòng đời upload**: RustFS gọi
   `http://grading-submission-service:8082/api/v1/submissions/webhook/upload-complete`
   khi object upload xong; submission-service đối chiếu rồi phát event Kafka.

---

## 10. `deploy/kafka-ui/` — quan sát topic Kafka

| File | Nội dung |
|---|---|
| `service.yaml` | `ClusterIP` 8080 → 8080 |
| `deployment.yaml` | 1 replica, image `ghcr.io/kafbat/kafka-ui:v1.5.0` (ghim), đọc credential Aiven qua `envFrom secretRef`, SASL_SSL/SCRAM-SHA-256, truststore PEM, `dnsPolicy: None` + nameserver 8.8.8.8 + search `aivencloud.com`, readiness `/actuator/health`, resources 128Mi–512Mi |
| `ingress.yaml` | host `web-dev1-kafka-ui...` → service `kafka-ui:8080` |

**Vì sao `dnsPolicy: None` với 8.8.8.8:** broker Aiven phân giải qua zone
`aivencloud.com`; đặt nameserver công cộng + search domain giúp pod phân giải được
tên broker mà không phụ thuộc DNS nội bộ của cụm.

**Lưu ý.** `setup.sh` **không** deploy Kafka UI (chỉ deploy trong 2 script biến
thể `setup_without_*`); muốn có thì:
`kubectl apply -f deploy/kafka-ui/service.yaml -f deploy/kafka-ui/deployment.yaml -f deploy/kafka-ui/ingress.yaml`,
hoặc `kubectl -n web-grading scale deploy/kafka-ui --replicas=0` khi không cần xem
topic (tiết kiệm ~128Mi request).

---

## 11. `deploy/observability/` — stack giám sát "Lite"

| File | Vai trò |
|---|---|
| `install.sh` | Cài Tempo 2.4.0 rồi kube-prometheus-stack 92.11.0 từ **OCI GHCR**, apply Ingress Grafana, cảnh báo nếu còn pod node-exporter/kube-state-metrics |
| `uninstall.sh` | `helm uninstall monitoring` + `tempo`, xoá Ingress; **giữ PVC** |
| `charts/kube-prometheus-stack-values.yaml` | Tắt mọi thứ không cần (Alertmanager, node-exporter, KSM, control-plane scrape), bật Prometheus 3d/1500MB, Grafana 2 datasource khai báo tường minh |
| `charts/tempo-values.yaml` | Tắt ballast, `GOMEMLIMIT=800MiB`, bật `streamOverHttpEnabled`, `metricsGenerator` + `local-blocks`, probe cổng 3200 |
| `manifests/ingress/grafana.yaml` | host `web-dev1-grafana...` → `monitoring-grafana:80` (namespace `observability`) |
| `templates/application-observability.yaml` | **Mẫu** để merge vào `application.yaml` của service: `management.*` + `logging.pattern` có traceId/spanId |
| `.env.observability` (gitignored) / `.example` | `GRAFANA_ADMIN_PASSWORD`, `GRAFANA_DOMAIN` |
| `README.md` | Kiến trúc, tích hợp Spring Boot, ngân sách RAM, troubleshooting |

**Vì sao tải chart từ OCI GHCR:** đường `helm repo add` cổ điển trỏ tới
`github.com/.../releases/download/...`, CDN của GitHub từng trả 504 và làm hỏng
cả lần cài. Script retry **bước tải** (3 lần, 10s/20s) chứ không retry `helm
install` — retry một release đang dở sẽ báo "another operation in progress".

---

## 12. `deploy/cleanup-old-images.sh` — dọn image trên node

**Mục đích.** Giữ image của các pod **đang chạy**, xoá phần còn lại (mỗi lần
ArgoCD sync một tag mới, node tích thêm vài trăm MB → đầy đĩa).

**Cách làm.** Lấy `image` của mọi container đang chạy trong `web-grading` →
tách tag → `sudo k3s crictl images -o json` → Python lọc ảnh có
`web-grading`/`vucongtuanduong` trong tên → `crictl rmi` ảnh không nằm trong tập
tag đang chạy → lặp lại với `docker images` (nếu máy có Docker).

**Lưu ý.** So khớp theo **tag**, không theo digest: nếu hai repo khác nhau dùng
cùng tag (ví dụ `latest`) thì có thể giữ/xoá nhầm. Script dùng cho môi trường
staging 1 node, không dùng cho cụm nhiều node.

---

## 13. Script ở root repo

### `setup.sh` — cài đặt một lần

8 bước như bảng thứ tự chạy. Điểm cần nói: nó **gọi** 4 script trong `deploy/`
chứ không nhân bản logic; nó in ra toàn bộ URL public sau khi xong.

### `setup_without_cloudflared.sh`, `setup_without_observability.sh`, `setup_without_cloudflared_observability.sh`

Ba biến thể cho máy yếu/không dùng Cloudflare. Khác biệt duy nhất là **bỏ bước**
tương ứng và (ở hai bản đầu) **thêm bước deploy Kafka UI**. Dùng khi demo offline:
service chỉ truy cập qua `kubectl port-forward`.

### `start.sh` / `stop.sh` / `status.sh`

| Script | Làm gì | Không làm gì |
|---|---|---|
| `start.sh` | `systemctl start k3s`, `kubectl wait node Ready`, in namespace/ArgoCD app/pod | không deploy, không sửa manifest |
| `stop.sh` | `systemctl stop k3s` | không xoá gì; PVC và manifest còn nguyên |
| `status.sh` | đọc: systemd, 3 namespace, 6 app ArgoCD, Deployment/Pod/Service, pod observability, tiến trình `cloudflared` | hoàn toàn read-only |

### `clean.sh` — reset

Xoá lần lượt `argocd`, `observability`, `web-grading` (namespace), rồi
`sudo k3s crictl rmi --all` (xoá **toàn bộ** image). **PVC được giữ** — muốn xoá
phải làm tay (`kubectl get pvc -A` → `kubectl delete pvc ...`), vì đây là dữ liệu
của RustFS/Prometheus/Tempo/Grafana.

### `dev-scale.sh` — dev local với ArgoCD đang bật

**Vấn đề nó giải:** ArgoCD có `selfHeal: true`, nên `kubectl scale ... --replicas=0`
sẽ bị revert trong vài phút. Script này **gỡ `spec.syncPolicy.automated`** khỏi
Application (lưu lại giá trị cũ vào `.dev-scale-state/<svc>.json`, gitignored),
scale, rồi **phục hồi** khi bật lại.

```
bash dev-scale.sh                    # menu tương tác
bash dev-scale.sh executor off       # scale về 0, treo sync
bash dev-scale.sh executor on        # về 2 replica (mặc định), phục hồi sync
bash dev-scale.sh executor on 3      # 3 replica, sync vẫn treo (phải sửa values cho khớp)
bash dev-scale.sh status             # bảng replicas + trạng thái sync
```

**Lưu ý.** Scale lên N>1 mà không sửa `values-stg.yaml` thì lần sync sau sẽ quay
về số trong values — script in cảnh báo đúng điểm này. Tên service chấp nhận cả
`executor` và `executor-service`.

### `set-log-level.sh` — đổi mức log toàn hệ

Cập nhật Secret `app-config` (key `APP_LOG_LEVEL`) rồi `rollout restart` từng
Deployment trong `services.env` và chờ `rollout status` (timeout 180s). Vì Secret
đổi không tự restart pod, **bắt buộc** phải restart — đây chính là lý do script
tồn tại.

### `cloudflare_tunnel_run.sh` — đường ra Internet

Một dòng: `cloudflared tunnel run --token <TUNNEL_TOKEN>`. File này **bị
gitignore** (`**/cloudflare_tunnel_run.sh`) vì chứa token tunnel — token đó tương
đương quyền đẩy traffic vào cụm, không được commit, không được dán vào báo cáo.
Chạy foreground trong terminal riêng; `Ctrl+C` để dừng; `status.sh` kiểm tra bằng
`pgrep -f "cloudflared tunnel"`.

---

## 14. `config-services/` — repo config (Helm chart), không phải thư mục deploy

Trong workspace này `config-services/` là **bản checkout của repo riêng**
`PTIT-DTL-Project/web-grading-system-services-config` (và bị
`.gitignore: **/config-services/**` của repo deploy). ArgoCD đọc **repo đó**, không
đọc thư mục này.

| File | Vai trò |
|---|---|
| `generate-charts.sh` | Sinh **khung** chart cho 6 service (Chart.yaml, values-stg.yaml, `_helpers.tpl`, deployment, service) từ một map `service → port:db`. Dùng một lần để scaffold; sau đó chart được sửa tay |
| `<service>/Chart.yaml` | `apiVersion: v2`, `name`, `version: 1.0.0`, `appVersion: "1.0"` |
| `<service>/values-stg.yaml` | Toàn bộ tham số môi trường staging (xem [03](03-helm-chart-va-tham-so.md)) |
| `<service>/templates/_helpers.tpl` | Helper đặt tên `name`/`fullname` (fullname = release name nếu chứa chart name ⇒ `grading-<service>`) |
| `<service>/templates/deployment.yaml` | Deployment + env + probe + resources |
| `<service>/templates/service.yaml` | `ClusterIP` + port |
| `README.md` | Cấu trúc values, luồng cập nhật, lệnh `helm lint`/`helm template`/`helm get values` |

Bảng map trong `generate-charts.sh` (cũng là bảng "service nào dùng DB nào"):

| Service | Port | DB |
|---|---|---|
| api-gateway | 8080 | `api_gateway_db` (khai trong script; values thật không dùng) |
| course-service | 8081 | `assignment_db` |
| submission-service | 8082 | `submission_db` |
| executor-service | 8083 | `executor_db` |
| result-service | 8084 | `result_db` |
| ai-assistant-service | 8086 | `ai_db` |

---

## 15. Bảng tra nhanh: "tôi muốn đổi X thì sửa file nào"

| Muốn đổi | Sửa ở đâu | Có cần restart? |
|---|---|---|
| Phiên bản image của 1 service | `config-services/<svc>/values-stg.yaml` → `image.tag` | ArgoCD sync → rolling update |
| Số replica | `values-stg.yaml` → `replicaCount` (chỉ executor có) hoặc thêm key + template | rolling update |
| RAM/CPU của service | `values-stg.yaml` → `resources` | rolling update (pod mới) |
| Mức log | `bash set-log-level.sh DEBUG` | script tự restart |
| DB name/host | `values-stg.yaml` (`spring.dbName`) / Secret `db-secret` | restart pod (Secret không hot-reload) |
| Domain mới | `deploy/ingress/*.yaml` + Cloudflare public hostname + (Keycloak) `KC_HOSTNAME` | apply Ingress; Keycloak cần restart |
| Origin FE cho upload | `deploy/rustfs/deployment.yaml` → `RUSTFS_CORS_ALLOWED_ORIGINS` | apply → pod restart |
| Retention Prometheus | `deploy/observability/charts/*.yaml` | `bash install.sh` (helm upgrade) |
| Danh sách service ArgoCD quản lý | `deploy/argocd-apps/services.env` | chạy lại `generate-argocd-apps.sh` + apply |
| Mật khẩu/credential | `.env` → `bash deploy/setup-namespace.sh` → `rollout restart` | **bắt buộc restart** |
