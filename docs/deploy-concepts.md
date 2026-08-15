# Deploy Concepts — Kubernetes, Helm, ArgoCD, Cloudflare

> Mục đích: giải thích các khái niệm K8s, Helm, ArgoCD, Cloudflare, RustFS
> và cách chúng kết nối với nhau trong folder `deploy/` của project này.

---

## Mục lục

1. [Kubernetes (K8s) là gì?](#1-kubernetes-k8s-là-gì)
2. [Các khái niệm K8s cốt lõi](#2-các-khái-niệm-k8s-cốt-lõi)
3. [Helm Chart là gì?](#3-helm-chart-là-gì)
4. [ArgoCD & GitOps](#4-argocd--gitops)
5. [Cấu trúc thư mục `deploy/`](#5-cấu-trúc-thư-mục-deploy)
6. [Luồng CI/CD hoàn chỉnh](#6-code--docker--cung-cấp-hình-ảnh-đóng-gói-cài-đặt-gitops)
7. [RustFS là gì?](#7-rustfs-là-gì)
8. [Cloudflare Tunnel](#8-cloudflare-tunnel)
9. [Sơ đồ mối quan hệ](#9-sơ-đồ-mối-quan-hệ)

---

## 1. Kubernetes (K8s) là gì?

**Kubernetes (K8s)** là một hệ thống điều phối container (container orchestrator). Nó tự động hoá việc:

- **Triển khai** (deploy) container lên cluster
- **Scale** (tăng/giảm số lượng bản sao)
- **Health check** & tự động restart nếu container chết
- **Service discovery** & load balancing nội bộ
- **Rollout** / **Rollback** phiên bản mới

### Cluster

Một **K8s cluster** gồm:
- **Control plane** (master): quản lý cluster, lưu trạng thái, lên lịch
- **Worker nodes** (máy chạy container thật)

Trong project này, cluster là **k3s** (K8s nhẹ, single binary, chạy trên 1 máy).

---

## 2. Các khái niệm K8s cốt lõi

Đây là những resource (tài nguyên) bạn khai báo trong file YAML để K8s hiểu
bạn muốn chạy cái gì.

### Pod

**Pod** là đơn vị nhỏ nhất trong K8s. Một pod chứa một hoặc nhiều container
chạy trên cùng một worker node. Các container trong pod share network namespace
(cùng IP, cùng port range).

> Trong thực tế, bạn **không** tạo Pod trực tiếp — bạn tạo Deployment quản lý Pod.

### Deployment

**Deployment** quản lý một tập hợp các Pod giống hệt nhau (ReplicaSet). Nó đảm bảo:

- Luôn có đúng `replicas` Pod đang chạy
- Rolling update khi bạn thay đổi image version
- Rollback nếu bản mới lỗi

Ví dụ `deploy/rustfs/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rustfs
spec:
  replicas: 1             # Chỉ chạy 1 bản sao
  selector:
    matchLabels:
      app: rustfs         # Chọn Pod nào nó quản lý
  template:
    metadata:
      labels:
        app: rustfs        # Label gắn trên Pod
    spec:
      containers:
        - name: rustfs
          image: rustfs/rustfs:latest
          ports:
            - containerPort: 9000   # Cổng container lắng nghe
          env:
            - name: RUSTFS_ROOT_USER
              value: minioadmin
          volumeMounts:
            - name: data
              mountPath: /data     # Mount PVC vào /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: rustfs-pvc  # Dùng PVC tên rustfs-pvc
```

**Các field quan trọng:**

| Field | Ý nghĩa |
|-------|---------|
| `replicas` | Số Pod muốn chạy |
| `selector.matchLabels` | Cách Deployment tìm Pod của nó |
| `template.spec.containers[].image` | Docker image |
| `template.spec.containers[].ports` | Cổng container expose |
| `template.spec.containers[].env` | Biến môi trường (env var) |
| `template.spec.containers[].volumeMounts` | Mount ổ đĩa vào container |
| `template.spec.volumes` | Khai báo ổ đĩa |

### Service

**Service** là một abstract layer cho phép các Pod giao tiếp với nhau qua một
tên DNS ổn định, bất kể Pod thực tế ở đâu hoặc có IP bao nhiêu.

Ví dụ `deploy/rustfs/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: rustfs              # Tên service → DNS nội bộ: rustfs
spec:
  type: ClusterIP           # Chỉ gọi được trong cluster
  ports:
    - port: 9000            # Cổng service
      targetPort: 9000      # Chuyển tiếp tới port này trên Pod
      name: s3
  selector:
    app: rustfs             # Chọn Pod có label app=rustfs
```

**Các loại Service (type):**

| Type | Truy cập từ | Dùng khi |
|------|-------------|----------|
| `ClusterIP` (mặc định) | Trong cluster | Giao tiếp nội bộ giữa các service |
| `NodePort` | Bên ngoài (qua IP node + port) | Dev / testing |
| `LoadBalancer` | Bên ngoài (qua load balancer cloud) | Production trên cloud |
| `ExternalName` | Trong cluster → external DNS | Gọi service ngoài cluster |

**Cách DNS hoạt động trong K8s:**
Tên service = DNS name. Các Pod trong cùng namespace có thể gọi nhau bằng
tên service. Ví dụ: Service tên `submission-service` trong namespace
`web-grading` có DNS đầy đủ là `submission-service.web-grading.svc.cluster.local`,
nhưng chỉ cần gọi `submission-service` là đủ (nếu cùng namespace).

### PersistentVolumeClaim (PVC)

**PVC** là request lưu trữ (storage). Nó yêu cầu K8s cấp phát một ổ đĩa với
kích thước và access mode nhất định.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rustfs-pvc
spec:
  accessModes:
    - ReadWriteOnce      # Chỉ 1 node được mount
  resources:
    requests:
      storage: 10Gi       # 10 Gigabytes
```

Dùng khi container cần lưu dữ liệu tồn tại sau khi Pod restart (stateful).

### Namespace

**Namespace** là cách chia cluster thành nhiều "virtual cluster" riêng biệt.
Trong project này, dùng namespace `web-grading` để cô lập tài nguyên grading
với namespace `argocd` hay bất kỳ namespace nào khác.

### Secret

**Secret** lưu thông tin nhạy cảm (DB password, API key, token). Các Pod
đọc secret thông qua `valueFrom.secretKeyRef` (xem Helm chart phía dưới).

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
type: Opaque
data:
  DB_HOST: cG9zdGdyZXM=
  DB_PASSWORD: cG9zdGdyZXM=
```

> `data` là base64-encoded. Dùng `kubectl create secret` để tạo an toàn hơn
> (không cần encode thủ công).

### ConfigMap

Giống Secret nhưng dùng cho config không nhạy cảm (không mã hoá).

### Ingress

**Ingress** cho phép truy cập từ bên ngoài internet vào service trong cluster
(HTTP/HTTPS). Thường đi kèm với Ingress Controller (trong project này là
ArgoCD Ingress, được cấu hình trong `deploy/argocd-ingress.yaml`).

### Mối quan hệ giữa các resource

```
Deployment ──quản lý──► Pod ──expose──► Service ──route──► Ingress ──► Internet
   │                         │
   │                         ├── Mount PVC → data tồn tại sau restart
   │                         └── Đọc Secret/ConfigMap → env var
   │
   └── Ở trong 1 Namespace
```

---

## 3. Helm Chart là gì?

**Helm** là package manager cho K8s. Một **Helm chart** là một bundle các file
YAML K8s được template hoá (dùng Go template). Giúp:

- Tái sử dụng cấu hình cho nhiều môi trường (dev, stg, prd)
- Chỉ cần thay đổi `values.yaml` thay vì sửa từng file YAML
- Quản lý version, upgrade, rollback dễ dàng

### Cấu trúc Helm chart chuẩn

```
submission-config/
├── Chart.yaml          # Metadata: tên, version, mô tả
├── values-stg.yaml     # Giá trị cho môi trường staging
├── templates/
│   ├── _helpers.tpl    # Hàm helper dùng chung
│   ├── deployment.yaml # Template Deployment
│   └── service.yaml    # Template Service
```

### Chart.yaml

```yaml
apiVersion: v2
name: submission-service
description: Helm chart cho submission-service
type: application
version: 0.1.0
appVersion: "1.0.0"
```

### values-stg.yaml

File chứa các giá trị mặc định. Khi `helm install` hoặc ArgoCD deploy,
Helm sẽ đọc file này và điền vào template:

```yaml
image:
  registry: docker.io
  repository: vucongtuanduong/web-grading-system-submission-service
  tag: "v1.2"
  pullPolicy: Always

spring:
  profilesActive: stg
  dbName: submission_db

rustfs:
  endpoint: http://rustfs:9000
  accessKey: minioadmin
  secretKey: minioadmin
  bucketName: submission-files

service:
  type: ClusterIP
  port: 8082
```

### templates/deployment.yaml (có template)

Helm dùng cú pháp `{{ .Values.xxx }}` để lấy giá trị từ `values.yaml`:

```yaml
image: "{{ .Values.image.registry }}/{{ .Values.image.repository }}:{{ .Values.image.tag }}"
```
→ Kết quả: `docker.io/vucongtuanduong/web-grading-system-submission-service:v1.2`

Secret được inject qua `valueFrom.secretKeyRef`:

```yaml
- name: DB_HOST
  valueFrom:
    secretKeyRef:
      name: db-secret
      key: DB_HOST
```

### Mối quan hệ Helm ↔ application.yaml

**application.yaml** trong source code Spring Boot cũng có template tương tự
nhưng dùng `${ENV_VAR:default_value}` (cú pháp Spring):

```yaml
url: ${JDBC_URL:jdbc:postgresql://${DB_HOST:localhost}:${DB_PORT:5432}/${DB_NAME:submission_db}}
username: ${DB_USERNAME:postgres}
```

Helm chart set env var → Spring Boot đọc env var → kết nối DB thật.

**Luồng dữ liệu:**
```
values-stg.yaml ──► Helm template ──► Deployment YAML
                                              │
                                              ▼
                                       K8s tạo Pod
                                              │
                                              ▼
                                     Container có env var
                                              │
                                              ▼
                                    Spring đọc ${DB_HOST}
                                              │
                                              ▼
                                     Kết nối PostgreSQL
```

---

## 4. ArgoCD & GitOps

**ArgoCD** là một GitOps tool cho K8s.

### GitOps là gì?

**GitOps** = Git + Operations. Toàn bộ cấu hình cluster được lưu trong Git
repo. ArgoCD chạy trong cluster, liên tục so sánh trạng thái Git với trạng
thái cluster. Nếu khác, nó tự động đồng bộ (sync) để cluster khớp với Git.

**Nguyên lý:**
```
Git repo (nguồn thật) ──► ArgoCD ──► K8s cluster
                              ▲
                              │ (sync tự động)
                              │
                     Phát hiện khác biệt
```

### ArgoCD Application

Một **Application** trong ArgoCD là kết nối giữa một Git repo và một
namespace trên cluster:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: grading-submission-service
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/PTIT-DTL-Project/submission-config.git
    targetRevision: main
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: web-grading
  syncPolicy:
    automated:
      prune: true     # Xoá resource không còn trong Git
      selfHeal: true  # Tự sửa nếu ai đó sửa tay trên cluster
```

### Luồng GitOps trong project

1. Developer push code lên GitHub
2. GitHub Actions build Docker image, push lên Docker Hub
3. CI tạo tag version mới (ví dụ `v1.3`)
4. CI clone config repo (`submission-config`), sửa `tag: v1.2` → `tag: v1.3`
5. ArgoCD phát hiện Git khác cluster → sync, deploy image mới

### Cách `deploy/argocd-apps/` hoạt động

`install-argocd.sh` đọc file `services.env` (danh sách service:config_repo),
dùng template `argocd-app-template.yaml` để sinh ra N Application YAML
(ví dụ `grading-submission-service`), rồi `kubectl apply`.

```
services.env:
  submission-service:submission-config

Template ──thay thế ${SERVICE_NAME} và ${CONFIG_REPO}──► Application YAML
                                                              │
                                                              ▼
                                                        kubectl apply -f -
```

---

## 5. Cấu trúc thư mục `deploy/`

```
deploy/
├── argocd-apps/
│   ├── argocd-app-template.yaml   # Template Application ArgoCD
│   └── services.env               # Danh sách service:config_repo
├── argocd-ingress.yaml            # Ingress cho ArgoCD UI
├── cloudflared/
│   ├── config.yml                 # Config Cloudflare Tunnel
│   ├── docker-compose.yml         # Chạy cloudflared bằng Docker
│   └── setup-tunnel.sh            # Script setup tunnel
├── cleanup-old-images.sh          # Dọn Docker image cũ trên node
├── install-argocd.sh              # Cài ArgoCD + tạo Application từ template
├── install-rustfs.sh              # Deploy RustFS (PVC + Service + Deployment)
├── keycloak/
│   └── (chưa có)                  # Config Keycloak
├── rustfs/
│   ├── deployment.yaml            # K8s Deployment cho RustFS
│   ├── service.yaml               # K8s Service cho RustFS
│   └── pvc.yaml                   # PersistentVolumeClaim 10Gi
└── setup-namespace.sh             # Tạo namespace web-grading + db-secret
```

### File nào chạy trước? Mối quan hệ thứ tự

```
setup.sh (tổng điều phối)
│
├── 1. K3s (kiểm tra hoặc khởi động)
│
├── 2. setup-namespace.sh
│   ├── Tạo namespace web-grading
│   └── Tạo db-secret (DB_HOST, DB_PORT, DB_USERNAME, DB_PASSWORD)
│
├── 3. install-rustfs.sh
│   ├── pvc.yaml       →  PVC 10Gi
│   ├── service.yaml   →  Service "rustfs" port 9000
│   └── deployment.yaml → Deployment rustfs (cần PVC, chạy RUSTFS_NOTIFY_*)
│
├── 4. install-argocd.sh
│   ├── Tạo namespace argocd
│   ├── Apply ArgoCD manifest
│   ├── Patch ArgoCD server (--insecure + ClusterIP)
│   ├── Apply argocd-ingress.yaml
│   └── Sinh Application từ template + services.env
│
├── 5. cloudflared
│   ├── setup-tunnel.sh
│   └── docker-compose up cloudflared
│
└── Done → ArgoCD tự sync submission-service từ config repo
```

### Scripts root (trên cùng project)

| File | Mục đích |
|------|----------|
| `setup.sh` | Chạy toàn bộ deploy sequence (ở trên) |
| `start.sh` | Sau reboot: k3s + cloudflared |
| `stop.sh` | Dừng sạch sẽ |
| `clean.sh` | Xoá toàn bộ cluster resource |

---

## 6. Code → Docker → Config → GitOps

Luồng hoàn chỉnh từ code đến deploy:

```
                    GitHub
                    ┌─────────────────────────┐
                    │  PTIT-DTL-Project/       │
                    │  submission-service    │
                    │  (source code)         │
                    │                        │
                    │  .github/workflows/    │
                    │   publish.yml          │
                    └────────┬────────────────┘
                             │ push main
                             ▼
                    GitHub Actions
                    ┌─────────────────────────┐
                    │ 1. Build JAR với Maven  │
                    │ 2. git tag v1.N         │
                    │ 3. gh release create    │
                    │ 4. Build Docker image   │
                    │ 5. Push lên Docker Hub  │
                    │ 6. Clone config repo    │
                    │    → sửa tag: v1.N      │
                    │    → commit + push      │
                    └────────┬────────────────┘
                             │
                             ▼
              ┌──────────────┴──────────────┐
              │                             │
              ▼                             ▼
      Docker Hub                    PTIT-DTL-Project/
      vucongtuanduong/              submission-config
      web-grading-system-           (Helm chart repo)
      submission-service:
      - latest
      - v1.N
              │                             │
              │                             │
              └──────────┬──────────────────┘
                         │
                         ▼
                   ArgoCD (trong cluster)
                   ┌─────────────────────────┐
                   │ Phát hiện: Git khác     │
                   │ cluster (tag mới)       │
                   │                         │
                   │ Sync: re-deploy với     │
                   │ image tag mới           │
                   └────────┬────────────────┘
                            │
                            ▼
                ┌──────────────────────┐
                │ K8s cluster          │
                │ - Pull image mới     │
                │ - Rolling update pod │
                │ - Health check       │
                └──────────────────────┘
```

---

## 7. RustFS là gì?

**RustFS** là một S3-compatible object storage server (giống MinIO) viết bằng
Rust. Dùng để lưu file zip bài nộp của sinh viên.

### Tại sao dùng RustFS thay vì MinIO?

- Nhẹ hơn MinIO
- RustFS hỗ trợ webhook notification qua env var (`RUSTFS_NOTIFY_*`)
- MinIO cần gọi API `setBucketNotification` (code Java) — RustFS cũng cần nhưng
  dùng `putBucketNotificationConfiguration` qua AWS SDK

### Kiến trúc RustFS trong project

```
submission-service ───presigned URL──► Student upload file zip
       │                                        │
       │                               Student PUT file lên
       │                               RustFS (presigned URL)
       │                                        │
       │                                        ▼
       │                               RustFS nhận file
       │                                        │
       │                               RUSTFS_NOTIFY_WEBHOOK_ENDPOINT_PRIMARY
       │                                        │
       │                                        ▼
       │◄──── POST /api/v1/submissions/webhook/upload-complete ────┘
       │           (RustFS gọi lại submission-service)
       │
       ▼
submission-service xử lý file:
  - Cập nhật DB
  - Gửi Kafka message cho grading service
```

### RustFS K8s config

Trong `deploy/rustfs/deployment.yaml`:

| Env var | Giá trị | Mục đích |
|---------|---------|----------|
| `RUSTFS_ROOT_USER` | minioadmin | User admin |
| `RUSTFS_ROOT_PASSWORD` | minioadmin | Password admin |
| `RUSTFS_NOTIFY_ENABLE` | on | Bật notification |
| `RUSTFS_NOTIFY_WEBHOOK_ENDPOINT_PRIMARY` | `http://submission-service:8082/api/v1/submissions/webhook/upload-complete` | Gọi submission-service khi có file mới |
| `RUSTFS_NOTIFY_WEBHOOK_QUEUE_DIR_PRIMARY` | `/tmp/rustfs-events` | Thư mục tạm chứa event queue |

Ở docker-compose (cho dev local), endpoint là `http://host.docker.internal:8082`
vì chạy trên host machine, không qua K8s DNS.

---

## 8. Cloudflare Tunnel

**Cloudflare Tunnel** (cloudflared) tạo một kết nối an toàn từ internet vào
K8s cluster mà không cần mở port firewall. Nó chạy như một Docker container
với `--network host` và ánh xạ domain → ingress của cluster.

```
Internet ──► Cloudflare Edge ──► cloudflared (tunnel) ──► localhost ──► Ingress ──► Service
```

### File liên quan

- `deploy/cloudflared/docker-compose.yml` — chạy `cloudflared` container
- `deploy/cloudflared/config.yml` — mapping URL → localhost (ArgoCD, service)
- `deploy/cloudflared/setup-tunnel.sh` — đăng ký tunnel với Cloudflare (chạy 1 lần)

### Tại sao cloudflared ở docker-compose không phải K8s?

Vì cloudflared cần `--network host` để truy cập ingress trên localhost.
Trong K8s, pod có network riêng, không truy cập được localhost của node.
Do đó chạy docker-compose riêng.

---

## 9. Sơ đồ mối quan hệ

```
K8s Cluster
│
├── Namespace: web-grading
│   │
│   ├── Secret: db-secret (DB_HOST, DB_USERNAME, DB_PASSWORD...)
│   │
│   ├── RustFS ──data──► PVC: rustfs-pvc (10Gi)
│   │   │
│   │   └── Service: rustfs:9000
│   │
│   └── Submission Service (deploy qua ArgoCD)
│       │
│       ├── Service: submission-service:8082
│       │
│       ├── Đọc env var từ: db-secret + values-stg.yaml
│       │
│       └── Webhook endpoint:
│           POST /api/v1/submissions/webhook/upload-complete
│           ── RustFS gọi đến khi có file mới
│
├── Namespace: argocd
│   │
│   ├── Application: grading-submission-service
│   │   └── source: github.com/PTIT-DTL-Project/submission-config
│   │
│   └── ArgoCD Ingress → Cloudflare Tunnel
│
└── Cloudflare Tunnel (docker-compose, host network)
    └── Mapping:
        web-dev1-argocd.vucongtuanduong.dpdns.org  → localhost (ArgoCD)
        web-dev1-submission.vucongtuanduong.dpdns.org → localhost (submission)
```

**Tóm tắt:** `deploy/` chứa toàn bộ script và manifest để từ một máy trắng
(k3s installed) chạy lên thành hệ thống hoàn chỉnh. `setup.sh` chạy tuần tự
các bước. Mọi thay đổi về phiên bản đều qua CI/CD (GitHub Actions → Docker
Hub → config repo → ArgoCD sync).
