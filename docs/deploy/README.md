# Deploy trên cụm k3s — bộ tài liệu chi tiết

> Mục đích: giải thích **toàn bộ** phần triển khai của hệ thống Web Grading System
> trên cụm k3s: kiến trúc, từng file làm gì, từng tham số có vai trò gì, luồng
> GitOps, ingress/Cloudflare, hạ tầng dùng chung, secret, vận hành và bộ câu hỏi
> thuyết trình. Mọi con số trong tài liệu này lấy trực tiếp từ manifest/values
> trong repo, không phải ước lượng.
>
> Tài liệu **khái niệm** (K8s là gì, Pod/Deployment/Service, Helm là gì) nằm ở
> [`../deploy-concepts.md`](../deploy-concepts.md). Bộ này là tài liệu **triển khai
> cụ thể của đồ án**: file nào, tham số nào, vì sao.

---

## Mục lục

| # | File | Trả lời câu hỏi |
|---|------|-----------------|
| 1 | [01-kien-truc-tong-the.md](01-kien-truc-tong-the.md) | Hệ thống chạy trên cụm gồm những gì, chia namespace thế nào, request đi qua những tầng nào, ngân sách RAM ra sao? |
| 2 | [02-danh-muc-file.md](02-danh-muc-file.md) | **Từng file** trong `deploy/`, `config-services/` và các script ở root làm gì, chạy khi nào, phụ thuộc file nào, idempotent không? |
| 3 | [03-helm-chart-va-tham-so.md](03-helm-chart-va-tham-so.md) | Một Helm chart gồm gì? **Từng key values** và **từng biến môi trường** có vai trò gì, đổi nó thì điều gì xảy ra, hỏng theo kiểu gì? |
| 4 | [04-gitops-argocd.md](04-gitops-argocd.md) | ArgoCD Application là gì, `prune`/`selfHeal` nghĩa là gì, CI cập nhật tag ảnh thế nào, rollback ra sao, `dev-scale.sh` can thiệp vào đâu? |
| 5 | [05-ingress-va-cloudflare.md](05-ingress-va-cloudflare.md) | 12 hostname public ánh xạ vào service nào, Traefik đứng ở đâu, Cloudflare Zero Trust tunnel hoạt động thế nào, CORS của RustFS vì sao phải khai? |
| 6 | [06-ha-tang-dung-chung.md](06-ha-tang-dung-chung.md) | Keycloak, RustFS, Kafka (Aiven) + Kafka UI, Prometheus/Grafana/Tempo, PostgreSQL (Neon) — mỗi thành phần cấu hình gì và vì sao? |
| 7 | [07-secrets-va-bien-moi-truong.md](07-secrets-va-bien-moi-truong.md) | Có bao nhiêu Secret, key nào, ai đọc, xoay vòng thế nào, sai thì hỏng ra sao? `.env` chứa gì? |
| 8 | [08-van-hanh-va-xu-ly-su-co.md](08-van-hanh-va-xu-ly-su-co.md) | Cài lần đầu, deploy phiên bản mới, rollback, đổi log level, scale, chẩn đoán lỗi — lệnh nào, kiểm tra gì? |
| 9 | [09-thuyet-trinh-va-hoi-dap.md](09-thuyet-trinh-va-hoi-dap.md) | Dàn ý thuyết trình 10 phút, số liệu nên trích, 25 câu hỏi – đáp án, các lỗi hay bị hỏi vặn. |
| 10 | [../design/backend-concepts-va-system-design.md](../design/backend-concepts-va-system-design.md) | Kiến thức nền tảng phản biện: sync/async, polling vs push, layer của một request, reverse/forward proxy, idempotency, khó khăn microservices, circuit breaker, orchestration, HA/scalability, public/private subnet, object/block/file storage — mỗi mục gắn với ví dụ thật trong đồ án. |

---

## Bức tranh trong 60 giây

```
Người dùng (trình duyệt)
   │ HTTPS  web-dev1-*.vucongtuanduong.dpdns.org
   ▼
Cloudflare (DNS + TLS + Zero Trust Tunnel)      ← cloudflared chạy trên máy host
   │ http://localhost:<NodePort của Traefik>
   ▼
Traefik Ingress (k3s, namespace kube-system)    ← đọc Ingress object, route theo Host
   │
   ├── web-dev1-api...      → grading-api-gateway:8080       (cửa duy nhất vào nghiệp vụ)
   │        │ Feign/WebClient nội bộ
   │        ├── grading-course-service:8081
   │        ├── grading-submission-service:8082
   │        ├── grading-result-service:8084
   │        └── grading-ai-assistant-service:8086
   ├── web-dev1-grading...  → grading-executor-service:8083 (chấm bài, có sidecar dind)
   ├── web-dev1-keycloak... → keycloak:8080                 (OIDC, cấp JWT)
   ├── web-dev1-rustfs[-api]→ rustfs:9001 / :9000           (S3, presigned URL)
   ├── web-dev1-kafka-ui... → kafka-ui:8080                 (xem topic)
   ├── web-dev1-grafana...  → monitoring-grafana:80         (namespace observability)
   └── web-dev1-argocd...   → argocd-server:80              (namespace argocd)

Ngoài cụm (managed/external):
   PostgreSQL (Neon)  ← 5 database, mỗi service một DB
   Kafka (Aiven)      ← topic wgs-events-deploy, SASL_SSL/SCRAM-SHA-256
   LLM API (OpenAI-compatible) ← ai-assistant-service
```

Ba namespace, ba vai trò:

| Namespace | Nội dung | Ai tạo |
|-----------|----------|--------|
| `web-grading` | 6 microservice + Keycloak + RustFS + Kafka UI | `deploy/setup-namespace.sh` + ArgoCD + script cài tay |
| `argocd` | ArgoCD (server, repo-server, application-controller, redis, dex) | `deploy/install-argocd.sh` |
| `observability` | Prometheus + Grafana + Tempo (kube-prometheus-stack + tempo) | `deploy/observability/install.sh` |

---

## Ba câu chốt để mở đầu phần thuyết trình

1. **Triển khai theo GitOps, không `kubectl apply` service bằng tay.** 6 service
   được ArgoCD quản lý: manifest nằm trong repo `web-grading-system-services-config`
   (Helm chart), CI chỉ sửa đúng một dòng `image.tag`, ArgoCD tự đồng bộ vào cụm.
2. **Một node k3s, mọi thứ đều có `requests`/`limits`.** Toàn bộ cấu hình được
   tính theo ngân sách RAM ~7,6 GiB của node: 6 service Java (512Mi limit mỗi cái),
   executor 2 replica + sidecar dind, Keycloak, RustFS, ArgoCD, stack observability.
3. **Bảo mật theo nguyên tắc "fail closed".** Gateway đóng dấu `X-Gateway-Secret`
   lên mọi request nội bộ; service từ chối request không có nó (secret rỗng ⇒ 401,
   không phải "tin tưởng tất cả"). Không một credential nào nằm trong Git: tất cả
   đi qua Kubernetes Secret do `setup-namespace.sh` tạo từ `.env` (đã gitignore).

---

## Cách dùng bộ tài liệu này

- **Chuẩn bị slide:** đọc `01` (kiến trúc) → `04` (GitOps) → `06` (hạ tầng) →
  `09` (dàn ý + Q&A).
- **Bị hỏi "file này để làm gì":** mở `02`, tra theo tên file.
- **Bị hỏi "tham số này để làm gì":** mở `03` (values/env của service) hoặc `06`
  (tham số của Keycloak/RustFS/Observability).
- **Bị hỏi "làm sao chứng minh chạy được":** mở `08`, mục "kiểm tra sau khi deploy"
  — toàn lệnh `kubectl`/`curl` đã dùng thật khi dựng cụm.

## Quy ước trong tài liệu

| Ký hiệu | Nghĩa |
|---------|-------|
| `grading-<service>` | Tên Deployment/Service thật trong cụm (Helm release = `grading-<chart>`) |
| "idempotent" | Chạy lại nhiều lần cho cùng kết quả, không tạo trùng resource |
| "fail closed" | Thiếu cấu hình ⇒ từ chối request (401/404), không mở quyền |
| "managed" | Dịch vụ ngoài cụm (Neon, Aiven, LLM API) — cụm không tự vận hành |
| `values-stg.yaml` | File values của môi trường staging trong repo config |
