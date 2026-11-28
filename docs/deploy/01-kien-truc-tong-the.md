# 01 — Kiến trúc tổng thể trên cụm k3s

> Đọc kèm: [02-danh-muc-file.md](02-danh-muc-file.md) (file nào tạo ra thành phần nào),
> [05-ingress-va-cloudflare.md](05-ingress-va-cloudflare.md) (đường vào từ Internet),
> [06-ha-tang-dung-chung.md](06-ha-tang-dung-chung.md) (Keycloak/RustFS/Kafka/Observability).

---

## 1. Mô hình vật lý: một node, một binary k3s

| Hạng mục | Giá trị thực tế của đồ án |
|----------|---------------------------|
| Orchestrator | **k3s** (Kubernetes nhẹ, single binary, đóng gói sẵn containerd + Traefik + ServiceLB) |
| Số node | **1 node** (vừa control-plane vừa worker; mọi pod nằm chung một máy) |
| Service type dùng | Chỉ `ClusterIP` — không LoadBalancer, không NodePort cho service nghiệp vụ |
| Điểm vào từ Internet | **Cloudflare Zero Trust Tunnel** → Traefik (NodePort) → Ingress |
| RAM khả dụng cho workload | ~**7,6 GiB** (con số được ghi trong comment của nhiều manifest) |
| Container runtime | containerd (do k3s quản lý), thao tác bằng `sudo k3s crictl` |
| Storage class | `local-path` (mặc định của k3s, PV nằm trên đĩa của node) |

Hệ quả cần nói khi thuyết trình:

- **Không có High Availability thật**: node chết là cả hệ thống dừng. Bù lại, mọi
  thứ đều khai báo bằng manifest nên dựng lại từ đầu chỉ cần `bash setup.sh`.
- **RAM là tài nguyên khan hiếm nhất**, không phải CPU. Vì vậy mọi manifest đều
  có `requests`/`limits`, và nhiều quyết định cấu hình (tắt node-exporter,
  `memBallastSizeMbs: 0`, `maxSurge: 0` cho executor) là để bảo vệ RAM.
- **Không có autoscaling** (không HPA): số replica cố định trong values; muốn đổi
  phải sửa `values-stg.yaml` (ArgoCD sync) hoặc dùng `dev-scale.sh` (tạm thời).

---

## 2. Ba namespace và ranh giới tin cậy

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ NODE k3s (1 máy)                                                             │
│                                                                              │
│  ┌── namespace: web-grading ──────────────────────────────────────────────┐   │
│  │  [Tin cậy: chỉ nhận traffic đã qua gateway hoặc có X-Gateway-Secret]   │   │
│  │                                                                        │   │
│  │  grading-api-gateway:8080 ──┬── grading-course-service:8081            │   │
│  │  (Deployment 1 pod)         ├── grading-submission-service:8082        │   │
│  │                             ├── grading-result-service:8084            │   │
│  │                             └── grading-ai-assistant-service:8086      │   │
│  │                                                                        │   │
│  │  grading-executor-service:8083 ×2  (mỗi pod: app + sidecar dind)       │   │
│  │                                                                        │   │
│  │  keycloak:8080      ← OIDC provider, phát JWT                          │   │
│  │  rustfs:9000/9001   ← S3 API + console, PVC 10Gi                       │   │
│  │  kafka-ui:8080      ← xem topic (không thuộc đường chạy nghiệp vụ)     │   │
│  │                                                                        │   │
│  │  Secret: db-secret, rustfs-secret, app-config, gateway-trust,          │   │
│  │          kafka-aiven-credentials, keycloak-db,                         │   │
│  │          keycloak-admin-client, ai-credentials                         │   │
│  └────────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  ┌── namespace: argocd ─────────────┐   ┌── namespace: observability ──────┐ │
│  │  ArgoCD server / repo-server /   │   │  Prometheus (pull metrics 30s)   │ │
│  │  application-controller / redis  │   │  Grafana (UI, 2 datasource)      │ │
│  │  (notifications & applicationset│   │  Tempo (nhận OTLP 4318)          │ │
│  │   scale = 0)                     │   │  prometheus-operator             │ │
│  └──────────────────────────────────┘   └──────────────────────────────────┘ │
│                                                                              │
│  ┌── namespace: kube-system ─────────────────────────────────────────────┐  │
│  │  Traefik (k3s built-in): đọc mọi Ingress của cả 3 namespace            │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
        │                                    ▲
        │ JDBC/TLS                           │ SASL_SSL
        ▼                                    │
   PostgreSQL (Neon, managed)          Kafka (Aiven, managed)      LLM API (HTTPS)
```

Vì sao tách 3 namespace:

| Namespace | Lý do tách |
|-----------|-----------|
| `web-grading` | Workload nghiệp vụ + Secret của ứng dụng; đây là nơi ArgoCD ghi manifest |
| `argocd` | Công cụ triển khai; tách để `clean.sh` xoá ứng dụng mà không đụng công cụ, và để giới hạn RAM riêng |
| `observability` | Stack giám sát dùng chung; tách để bật/tắt (`install.sh`/`uninstall.sh`) độc lập với hệ thống |

**Ranh giới tin cậy quan trọng nhất** nằm giữa gateway và 4 service nội bộ:
service không tin bất cứ ai gọi trực tiếp; chúng chỉ chấp nhận request có header
`X-Gateway-Secret` khớp Secret `gateway-trust`. Vì Secret rỗng ⇒ so sánh thất bại
⇒ 401, nên cấu hình thiếu là **fail closed**, không phải "mở toang".

---

## 3. Sáu microservice: vai trò, cổng, database

| Service (Deployment) | Port | Database (`DB_NAME`) | Vai trò trong hệ thống | Replica |
|---|---|---|---|---|
| `grading-api-gateway` | 8080 | — (không dùng DB) | Cửa duy nhất cho FE: xác thực JWT, đóng dấu header tin cậy, route sang service | 1 |
| `grading-course-service` | 8081 | `assignment_db` | Lớp, sinh viên, bài tập, test plan, thành phần điểm, tính điểm/học bảng | 1 |
| `grading-submission-service` | 8082 | `submission_db` | Nhận bài nộp, presigned URL, webhook từ RustFS, phát event Kafka | 1 |
| `grading-executor-service` | 8083 | `executor_db` | Chấm bài: gọi Docker (dind), chạy test plan, ghi kết quả | **2** |
| `grading-result-service` | 8084 | `result_db` | Lưu kết quả từng bước, tính điểm plan/bài (max-per-plan), API kết quả | 1 |
| `grading-ai-assistant-service` | 8086 | `ai_db` | Trợ lý AI: giải thích kết quả chấm, agent hội thoại, fallback khi không có API key | 1 |

Bốn điểm dễ bị hỏi:

1. **Gateway không có datasource.** Chart vẫn inject `DB_*` (boilerplate dùng chung)
   nhưng `api-gateway/values-stg.yaml` không khai `spring.dbName`, nên `DB_NAME`
   render ra chuỗi rỗng — vô hại vì gateway không mở kết nối DB nào.
2. **Chỉ executor có 2 replica.** Lý do ghi trực tiếp trong `values-stg.yaml`:
   một pod rollout/restart không được làm mất toàn bộ năng lực chấm bài.
3. **Các service còn lại 1 replica** ⇒ trong lúc rolling update có vài giây gián
   đoạn. Đây là đánh đổi có ý thức trên node 8 GB, không phải sơ suất.
4. **Mỗi service một database riêng** (5 DB cho 5 service trên cùng một PostgreSQL
   Neon, cộng 1 DB riêng cho Keycloak), không dùng chung schema — ranh giới dữ
   liệu khớp ranh giới service.

---

## 4. Tài nguyên: requests vs limits

`requests` = con số scheduler dùng để xếp pod; `limits` = trần kernel/CFS áp lên
container. Trong đồ án, tổng `requests` phải vừa 7,6 GiB, còn tổng `limits` cố ý
**vượt** RAM node (overcommit có kiểm soát).

### 4.1 Namespace `web-grading`

| Workload | Replica | CPU req / lim (mỗi pod) | RAM req / lim (mỗi pod) |
|---|---|---|---|
| 5 service Java (gateway, course, submission, result, ai) | 1 mỗi cái | 200m / 500m | 256Mi / 512Mi |
| executor-service (app) | 2 | 200m / 500m | 256Mi / 512Mi |
| executor-service (sidecar `dind`) | 2 | 100m / 1000m | 256Mi / 1Gi |
| keycloak | 1 | 100m / 500m | 384Mi / 768Mi |
| rustfs | 1 | 50m / 500m | 128Mi / 512Mi |
| kafka-ui | 1 | 50m / 500m | 128Mi / 512Mi |

Tính ra:

- **requests**: CPU = **1,8 core**, RAM = **2944 Mi ≈ 2,9 GiB**
  (CPU: 5×200m + 2×200m + 2×100m + 100m + 50m + 50m = 1800m;
   RAM: 5×256 + 2×256 + 2×256 + 384 + 128 + 128 = 2944 Mi)
- **limits**: CPU = **7,0 core**, RAM = **7424 Mi ≈ 7,25 GiB**
  (CPU: 5×500m + 2×500m + 2×1000m + 500m + 500m + 500m = 7000m;
   RAM: 5×512 + 2×512 + 2×1024 + 768 + 512 + 512 = 7424 Mi)

### 4.2 Namespace `observability` và `argocd`

| Workload | CPU req / lim | RAM req / lim | Ghi chú |
|---|---|---|---|
| Prometheus | 100m / 500m | 256Mi / 768Mi | giữ 3 ngày, dừng ở 1500 MB |
| Grafana | 200m / 750m | 384Mi / 768Mi | đã nâng sau khi bị OOMKilled |
| Tempo | 100m / 500m | 256Mi / 1Gi | `local-blocks` giữ trace trong RAM |
| prometheus-operator | 50m / 200m | 64Mi / 256Mi | |
| ArgoCD application-controller | 100m / 500m | 192Mi / 512Mi | |
| ArgoCD repo-server | 100m / 500m | 128Mi / 384Mi | pod hay bị OOM nhất nếu không đặt limit |
| ArgoCD server | 100m / 500m | 128Mi / 384Mi | |
| ArgoCD redis | 50m / 200m | 64Mi / 192Mi | |
| ArgoCD dex-server | 50m / 200m | 64Mi / 192Mi | |
| argocd-notifications / applicationset | 0 replica | — | `scale --replicas=0` |

Tổng cộng toàn cụm (3 namespace): **requests ≈ 2,65 core / 4,4 GiB**,
**limits ≈ 10,8 core / 11,6 GiB**.

**Cách giải thích khi bị hỏi "limits vượt RAM thì có sao không":**
Không sao, vì limit chỉ là trần cho từng container. Cái quyết định pod có được xếp
lịch là `requests` (~4,4 GiB < 7,6 GiB). Overcommit cho phép các service Java
"vay" RAM của nhau theo thời điểm (JVM chỉ chạm trần khi chịu tải), nhưng vì mỗi
container đều có trần riêng, kernel có căn cứ để chọn nạn nhân khi buộc phải
OOM-kill thay vì để một pod nuốt hết node.

---

## 5. Bốn luồng request tiêu biểu

### 5.1 Đăng nhập (OIDC + PKCE)

```
Browser ──GET /realms/ptit-wgs/protocol/openid-connect/auth──► Keycloak (web-dev1-keycloak)
        ◄─ 302 kèm authorization code ───────────────────────┘
FE     ──POST /token (code + PKCE verifier)──────────────────► Keycloak
        ◄─ access_token (JWT, ~5 phút) + refresh_token ──────┘
FE     ──GET https://web-dev1-api.../api/v1/... ────────────► Cloudflare → Traefik → gateway
              Authorization: Bearer <JWT>
```

Gateway chỉ **verify chữ ký + `iss`** (không kiểm tra `azp`/client_id), nên token
phát cho FE hay cho Postman (`wgs-postman`) đều đi qua được. Token hết hạn ~5 phút,
`refresh_token` là **one-time use**.

### 5.2 Gọi API nghiệp vụ (qua gateway)

```
FE → Cloudflare → Traefik Ingress (Host: web-dev1-api...) → Service grading-api-gateway:8080
   gateway:
     1. Resource Server verify JWT (issuer = https://web-dev1-keycloak.../realms/ptit-wgs)
     2. Đóng dấu X-User-Id / X-User-Roles / X-Gateway-Secret
     3. Route theo path: /api/v1/classes/** → COURSE_SERVICE_URI
                         /api/v1/submissions/** → SUBMISSION_SERVICE_URI
                         /api/v1/results/** → RESULT_SERVICE_URI
                         /api/v1/ai/** → AI_ASSISTANT_SERVICE_URI
   service đích:
     4. HeaderAuthenticationFilter so X-Gateway-Secret với Secret gateway-trust
        → sai/thiếu = 401 (fail closed)
     5. Xử lý nghiệp vụ, trả JSON
```

### 5.3 Nộp bài (presigned URL + webhook + Kafka)

```
FE ──POST /api/v1/submissions/presign──► gateway ──► submission-service
                                                └─ tạo presigned PUT (RustFS SDK)
                                                └─ trả { uploadUrl, objectName }
FE ──PUT <uploadUrl>────────────────────────────────────────► RustFS (web-dev1-rustfs-api)
                                                              (cần CORS cho origin FE!)
RustFS ──POST /api/v1/submissions/webhook/upload-complete───► submission-service
submission-service ──publish──► Kafka topic wgs-events-deploy (Aiven)
executor-service (consumer) ──► chấm bài (sidecar dind) ──► result-service (internal API)
                                                       └──► PATCH submission status DONE/FAILED
```

Chi tiết đáng nói: **FE upload trực tiếp lên RustFS**, không qua backend, nên
`RUSTFS_CORS_ALLOWED_ORIGINS` phải chứa đúng origin của FE; thiếu nó thì preflight
`OPTIONS` không có `Access-Control-Allow-Origin` và trình duyệt chặn `PUT` — trong
khi CI vẫn xanh vì lỗi chỉ xảy ra trên browser.

### 5.4 Observability (pull metrics + push traces)

```
Prometheus ──GET /actuator/prometheus (30s, pod service discovery)──► 6 service
            (chỉ pod có label app ∈ 6 tên service, chỉ port 8080-8084/8086)
Service    ──OTLP/HTTP POST :4318/v1/traces────────────────────────► Tempo
Tempo      ──remote_write (span metrics, service graph)───────────► Prometheus
Grafana    ──query──► Prometheus (uid: prometheus) + Tempo (uid: tempo)
```

---

## 6. Lưu trữ và dữ liệu

| Loại dữ liệu | Nơi lưu | Ai ghi |
|---|---|---|
| Lớp, bài tập, điểm, test plan | PostgreSQL Neon, DB `assignment_db` | course-service |
| Bài nộp (metadata + trạng thái) | PostgreSQL, `submission_db` | submission-service |
| File ZIP bài nộp | RustFS bucket `submission-files` trên PVC `rustfs-pvc` (10Gi, RWO) | submission-service (presign), FE (PUT) |
| Kết quả chấm, step result | PostgreSQL, `result_db` | executor → result-service |
| Lịch sử hội thoại AI | PostgreSQL, `ai_db` | ai-assistant-service |
| Job chấm (hàng đợi) | PostgreSQL, `executor_db` | executor-service |
| Metric (3 ngày) | PVC Prometheus 2Gi (`local-path`) | Prometheus |
| Trace (24 giờ) | PVC Tempo 2Gi | Tempo |
| Dashboard, user Grafana | PVC Grafana 2Gi | Grafana |
| Vị trí sync ArgoCD | etcd của k3s + Redis của ArgoCD | ArgoCD |

Điểm cần nhớ: **PVC dùng `local-path`** ⇒ dữ liệu nằm trên đĩa node, không nhân
bản. `clean.sh` xoá namespace nhưng **giữ PVC** (phải xoá tay) — đó là lý do
script in ra hướng dẫn xoá PVC/PV.

---

## 7. Những gì cụm này **không** có (và vì sao)

| Không có | Vì sao | Nếu cần thì làm gì |
|---|---|---|
| HPA / autoscaling | 1 node, RAM đã khít; scale thêm chỉ tạo pod Pending | Thêm node, hoặc `dev-scale.sh <svc> on <n>` tạm thời |
| PodDisruptionBudget | 1 replica phần lớn service ⇒ PDB vô nghĩa | Tăng replica trước |
| NetworkPolicy | Cụm 1 node, traffic nội bộ đã có `X-Gateway-Secret` | Bật CNI hỗ trợ + viết policy egress/ingress |
| TLS trong cụm | TLS kết thúc ở Cloudflare; Traefik chỉ mở entrypoint `web` (HTTP) | cert-manager + entrypoint `websecure` |
| Service mesh | Không cần cho quy mô đồ án | Istio/Linkerd nếu cần mTLS tự động |
| Loki (log tập trung) | Tốn RAM; log lấy bằng `kubectl logs` | Thêm Loki + Alloy khi có node lớn hơn |
| Alertmanager | Không có ai trực on-call | Bật lại trong values kube-prometheus-stack |
| Backup tự động | Ngoài phạm vi đồ án | `pg_dump` định kỳ + snapshot PVC (xem mục Hướng phát triển của báo cáo) |

---

## 8. Sơ đồ quan hệ giữa các thành phần (một trang)

```
                    ┌──────────────────────────┐
                    │  Git: config-services     │  values-stg.yaml (image.tag)
                    └────────────┬─────────────┘
                                 │ ArgoCD pull (GitOps)
                                 ▼
   ┌─────────────────────────────────────────────────────────┐
   │ ArgoCD (ns argocd) → render Helm → apply vào web-grading │
   └────────────────────────────┬────────────────────────────┘
                                ▼
   Deployment ──► ReplicaSet ──► Pod ──► container
        │                          │
        │                          ├── env from Secret (db-secret, gateway-trust, ...)
        │                          └── probes: startup → readiness → liveness (/actuator/health)
        ▼
     Service (ClusterIP) ──► EndpointSlice (IP các pod Ready) ──► kube-proxy
        ▲
        │ Host-based routing
   Ingress (traefik) ──► Traefik (kube-system) ──► NodePort ──► cloudflared ──► Cloudflare ──► Browser
```

Bốn quy tắc vận hành rút ra từ sơ đồ:

1. **Sửa gì cũng phải sửa trong Git** (`config-services` hoặc `deploy/`), không
   `kubectl edit` — ArgoCD sẽ revert (`selfHeal: true`).
2. **Pod chỉ nhận traffic khi readiness = true** ⇒ probe hỏng thì pod bị rút khỏi
   Service, đây là cơ chế "không đẩy traffic vào pod chưa sẵn sàng".
3. **Secret đổi nhưng pod không tự restart** ⇒ phải `rollout restart` (xem
   [07](07-secrets-va-bien-moi-truong.md) mục xoay vòng).
4. **Image tag là hợp đồng giữa CI và cụm**: CI sửa `values-stg.yaml`, ArgoCD đọc
   lại, pod mới được tạo. Không có bước "copy file lên server" nào.
