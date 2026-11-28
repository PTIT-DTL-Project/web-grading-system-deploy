# 09 — Dàn ý thuyết trình và bộ câu hỏi – đáp án

> Mục tiêu: 10 phút trình bày + 5–10 phút hỏi đáp, không cần mở thêm tài liệu nào
> khác ngoài file này và [01](01-kien-truc-tong-the.md).

---

## 1. Dàn ý 10 phút (10 slide)

| # | Slide | Nội dung | Câu chốt | Thời lượng |
|---|---|---|---|---|
| 1 | Một câu về hệ thống | 6 microservice Java/Spring Boot chấm bài lập trình tự động, chạy trên k3s 1 node, triển khai bằng GitOps | "Em không deploy bằng tay — Git là nguồn sự thật" | 30s |
| 2 | Kiến trúc tổng thể | Sơ đồ: Browser → Cloudflare → Traefik → gateway → 4 service; executor 2 replica + dind; Keycloak/RustFS/Kafka/Neon | "Một cửa vào, nhiều service phía sau" | 1,5' |
| 3 | Ba namespace | `web-grading` / `argocd` / `observability` | "Tách theo vòng đời, không chỉ theo chức năng" | 45s |
| 4 | Một pod gồm gì | Deployment = image + env từ Secret + 3 probe + resources; executor có sidecar dind | "Mọi thứ khai báo, không cấu hình tay trong container" | 1,5' |
| 5 | GitOps | 3 repo; CI build → push image → sửa 1 dòng tag → ArgoCD sync; `prune` + `selfHeal` | "Deploy = merge PR; rollback = revert commit" | 1,5' |
| 6 | Ingress + Cloudflare | 12 hostname; TLS ở Cloudflare; tunnel outbound-only; Keycloak hostname strict | "Cụm không mở port nào ra Internet" | 1' |
| 7 | Hạ tầng dùng chung | Keycloak (OIDC), RustFS (S3 + webhook), Kafka Aiven (event), Neon (5 DB) | "Stateful đẩy ra managed service, cụm chỉ giữ stateless" | 1' |
| 8 | Observability | Prometheus pull 30s, Tempo OTLP 4318, Grafana 2 datasource; "Lite" vì 8 GB RAM | "Đo được mới sửa được" | 1' |
| 9 | Bảo mật | `X-Gateway-Secret` fail closed; Secret ngoài Git; JWT verify `iss` | "Thiếu cấu hình thì từ chối, không mở quyền" | 1' |
| 10 | Kết quả + hạn chế | 6 service `Synced/Healthy`, deploy 5–7 phút không thao tác tay; hạn chế: 1 node, chưa HA, chưa có backup RustFS | "Biết giới hạn của mình" | 1' |

### Bản 3 phút (nếu bị rút thời gian)

1. Kiến trúc: Cloudflare → Traefik → gateway → 4 service; executor chấm bài bằng dind.
2. Triển khai: Helm chart trong repo config, ArgoCD sync, CI chỉ sửa `image.tag`.
3. Hạ tầng: Keycloak/RustFS/Kafka/Neon là dịch vụ ngoài hoặc cấu hình riêng; cụm giữ stateless.
4. Bảo mật: gateway đóng dấu secret, service fail closed, secret không vào Git.
5. Giới hạn: 1 node, không HA, chưa backup object storage — đã ghi ở Hướng phát triển.

---

## 2. Số liệu nên trích (đã kiểm chứng từ manifest)

| Chủ đề | Con số | Nguồn |
|---|---|---|
| Số microservice | 6 | `deploy/argocd-apps/services.env` |
| Số namespace | 3 | `web-grading`, `argocd`, `observability` |
| Số Ingress public | 12 host | 7 trong `deploy/ingress/` + 1 ArgoCD + 1 Grafana + 2 RustFS + 1 Kafka UI |
| RAM node | ~7,6 GiB | comment trong manifest (node 8 GB) |
| Tổng requests toàn cụm | ≈ 2,65 core / **4,4 GiB** | tổng bảng [01](01-kien-truc-tong-the.md) §4 |
| Tổng limits toàn cụm | ≈ 10,8 core / **11,6 GiB** | overcommit có kiểm soát |
| Executor | **2 replica**, mỗi pod app 512Mi + dind 1Gi | `values-stg.yaml`, `deployment.yaml` |
| Image tag hiện tại | gw `v1.0.23`, course `v1.0.42`, submission `v1.0.35`, executor `v1.0.40`, result `v1.0.39`, ai `v1.0.22` | 6 file `values-stg.yaml` |
| Prometheus | giữ **3 ngày**, dừng ở **1500 MB**, PVC 2Gi, scrape **30s** | `kube-prometheus-stack-values.yaml` |
| Tempo | giữ **24h**, `GOMEMLIMIT=800MiB`, ballast **0**, PVC 2Gi | `tempo-values.yaml` |
| Keycloak | limit 768Mi ⇒ heap ~460Mi (`MaxRAMPercentage=60`) | `keycloak/deployment.yaml` |
| RustFS | PVC **10Gi**, image ghim **1.0.5** | `rustfs/pvc.yaml`, `deployment.yaml` |
| Deploy một service | ~**5–7 phút** (build 1–3' + push 20–60s + ArgoCD ≤3' + rollout 30–90s) | [04](04-gitops-argocd.md) §4.4 |
| Secret | **8** trong `web-grading` (+3 ngoài) | [07](07-secrets-va-bien-moi-truong.md) §2 |

Lưu ý khi trích: các con số RAM/CPU là **khai báo trong manifest**, không phải số
đo thực tế. Nếu bị hỏi "đo được chưa", trả lời đúng: đã có kiểm thử hiệu năng trên
staging cho **API read + một luồng chấm smoke** (trình bày ở Chương 3 của báo cáo);
chưa đo tải cao > 5 VU.

---

## 3. 25 câu hỏi – đáp án

### Nhóm A — Kiến trúc (A1–A7)

**A1. Vì sao dùng Kubernetes mà không dùng Docker Compose?**
Vì cần: (1) rollout/rollback từng service độc lập, (2) health check + tự restart,
(3) khai báo tài nguyên (requests/limits) để 9 workload cùng sống trên 1 node 8 GB,
(4) GitOps — trạng thái mong muốn nằm trong Git. Compose không có 4 thứ đó. Đồ án
vẫn dùng compose **bên trong** executor để chạy bài nộp (mỗi bài là 1 project
compose), nhưng đó là chuyện của workload, không phải của hạ tầng.

**A2. Vì sao chọn k3s?**
Nhẹ (1 binary, ~70 MB), có sẵn containerd + Traefik + local-path provisioner, cài
trong 1 lệnh, phù hợp 1 node. Bản K8s đầy đủ sẽ tốn thêm RAM cho control-plane và
không mang lại lợi ích gì khi chỉ có 1 node.

**A3. Vì sao 3 namespace?**
Tách theo vòng đời và quyền: `web-grading` (nghiệp vụ + Secret), `argocd` (công cụ
triển khai), `observability` (giám sát). Lợi ích: `clean.sh` xoá ứng dụng không
đụng công cụ; giới hạn RAM riêng; dễ phân quyền RBAC sau này.

**A4. Gateway có phải single point of failure không?**
Có, ở mức 1 replica — giống 5/6 service còn lại. Đây là đánh đổi có ý thức trên
node 8 GB. Nếu cần HA: tăng replica + PodDisruptionBudget + thêm node.

**A5. Vì sao chỉ executor có 2 replica?**
Vì chấm bài là tác vụ dài, nặng, và cần tiếp tục khi 1 pod bị rollout. Comment
trong `values-stg.yaml` ghi rõ: 2 replica là mức tối thiểu để một pod
rollout/restart không làm mất toàn bộ năng lực chấm. Các service khác là CRUD nhẹ,
1 replica đủ và tiết kiệm ~256Mi request mỗi cái.

**A6. Vì sao mỗi service một database?**
Ranh giới dữ liệu khớp ranh giới service: không service nào đọc bảng của service
khác; giao tiếp qua API. Đổi lại phải chấp nhận nhất quán eventual (ví dụ điểm
tổng hợp lấy từ result-service).

**A7. Vì sao Keycloak, RustFS, Kafka, Postgres không nằm trong GitOps?**
Vì chúng stateful và/hoặc chứa secret: `prune` có thể xoá PVC, còn Secret không
được nằm trong Git. Chúng được cài bằng script idempotent (hoặc là managed
service). GitOps áp dụng cho **workload stateless** — đây là ranh giới có chủ đích,
không phải thiếu sót.

### Nhóm B — Triển khai (B1–B8)

**B1. ArgoCD khác `kubectl apply` ở đâu?**
`kubectl apply` là mệnh lệnh một lần; ArgoCD là vòng lặp liên tục so Git ↔ cụm.
Có `selfHeal` (sửa drift) và `prune` (xoá resource thừa) — hai thứ `kubectl` không
làm. Ngoài ra ArgoCD cho biết **khác ở đâu** (diff) trước khi sync.

**B2. CI/CD chạy thế nào?**
2 workflow: `Build and Test` (phát hiện service đổi bằng path filter, build, test)
→ `Publish` (tăng version patch từ git tag, tạo GitHub Release kèm JAR, push image
`:version` + `:latest`, clone repo config và `sed` đúng dòng `image.tag`). ArgoCD
đọc repo config và sync. Không có bước nào ssh vào server.

**B3. Vì sao `syncOptions: CreateNamespace=false`?**
Vì namespace phải có **Secret trước** khi pod start; nếu ArgoCD tự tạo namespace,
pod có thể được tạo trước Secret ⇒ `CreateContainerConfigError`. Việc tạo namespace
+ Secret là bước riêng, có kiểm soát.

**B4. Rollback thế nào cho đúng?**
Revert commit trong repo config (GitOps chuẩn, có audit). `argocd app rollback` chỉ
dùng chữa cháy vì lần sync sau sẽ ghi đè. `kubectl rollout undo` **không dùng** —
`selfHeal` sẽ revert.

**B5. `dev-scale.sh` giải quyết vấn đề gì?**
`selfHeal` revert `kubectl scale` trong ~3 phút. Script tạm gỡ
`spec.syncPolicy.automated` khỏi Application, lưu trạng thái cũ, scale, rồi phục
hồi. Đây là ví dụ "thao tác khẩn cấp phải có đường quay lại".

**B6. Thêm một service mới cần làm gì?**
(1) Tạo chart trong repo config, (2) thêm tên vào `deploy/argocd-apps/services.env`,
(3) chạy `generate-argocd-apps.sh` + apply, (4) thêm Ingress + route ở gateway,
(5) thêm Secret nếu cần, (6) CI tự nhận service mới qua path filter.

**B7. Vì sao `pullPolicy: Always` với tag semver?**
Để node không dùng bản cache khi tag bị push lại (đã từng xảy ra khi rebuild
image cùng tag). Cái giá: mỗi pod start phải kiểm tra registry.

**B8. Deploy mất bao lâu, và mất bao lâu để biết hỏng?**
5–7 phút từ merge tới pod mới chạy. Biết hỏng trong vòng 30–90 giây sau khi pod
mới start: `startupProbe` fail ⇒ pod không Ready ⇒ `rollout status` treo và
ArgoCD báo `Progressing`/`Degraded`; pod cũ vẫn phục vụ (với executor
`maxUnavailable: 1` nên còn 1 pod).

### Nhóm C — Hạ tầng (C1–C6)

**C1. Vì sao Neon mà không chạy Postgres trong cụm?**
Tiết kiệm RAM/PVC trên node 8 GB, có backup/PITR/TLS sẵn. Cái giá: phụ thuộc mạng
và độ trễ wake-up ~10–15s khi compute suspend (đã xử lý bằng readiness probe
không chạm DB ở ai-assistant-service).

**C2. Vì sao dùng RustFS thay vì MinIO/S3?**
S3-compatible, nhẹ, chạy được trong cụm với PVC 10Gi, có webhook notify (dùng để
nối vòng đời upload) và CORS cho presigned PUT. S3 thật (AWS) sẽ tốt hơn cho
production nhưng phát sinh chi phí và cấu hình ngoài phạm vi đồ án.

**C3. Vì sao dùng Kafka? Không dùng gọi HTTP trực tiếp?**
Upload xong phải kích hoạt chấm bài — tác vụ dài, có thể thất bại và cần retry.
Kafka tách producer (submission) khỏi consumer (executor), chịu được executor
restart, và cho phép nhiều consumer. Gọi HTTP trực tiếp sẽ buộc submission phải
chờ/retry và làm mất event khi executor down.

**C4. Vì sao Tempo không có OTel Collector?**
Ít thành phần = ít RAM. Spring Boot export OTLP/HTTP trực tiếp tới Tempo :4318.
Collector chỉ cần khi phải fan-out nhiều backend hoặc biến đổi dữ liệu.

**C5. Vì sao "Lite" observability, thiếu Loki/Alertmanager?**
Node 8 GB: thêm Loki + Alloy + Alertmanager + node-exporter + KSM sẽ tốn thêm
~700 MB–1 GB và dễ gây OOM cho pod Java. Log lấy bằng `kubectl logs`; alert do
người vận hành quan sát. Đã ghi rõ trong README "Do not re-add them on the 8 GB box".

**C6. Trace đi từ đâu tới đâu?**
Service (Boot 4 + micrometer-tracing + OTLP) → Tempo `:4318/v1/traces` →
Grafana query Tempo; Tempo đồng thời `remote_write` span metrics/service graph
sang Prometheus để Grafana hiển thị "Span rate".

### Nhóm D — Bảo mật (D1–D6)

**D1. Vì sao cần `X-Gateway-Secret` khi đã có JWT?**
JWT chứng minh **người dùng**, không chứng minh **người gọi**. Service chỉ nên tin
request đến từ gateway (nơi đã verify JWT và lọc role). Secret đảm bảo điều đó;
thiếu ⇒ service coi request là anonymous ⇒ 401. Đây là mô hình "zero trust nội bộ"
ở mức đơn giản.

**D2. Secret được quản lý thế nào?**
Kubernetes Secret, tạo bằng `setup-namespace.sh` từ `.env` (gitignored). Không có
credential trong Git. Hạn chế: Secret lưu base64 trong etcd ⇒ production nên dùng
Sealed Secrets/External Secrets + KMS.

**D3. Vì sao gateway không kiểm tra `azp`/client_id?**
Vì cần chấp nhận token từ nhiều client (FE `web-grading-fe` và Postman
`wgs-postman`) trong cùng realm, và gateway chỉ cần biết token do Keycloak phát
hợp lệ. Hạn chế: token của bất kỳ client nào trong realm đều qua được ⇒ production
nên thêm allowlist `azp`.

**D4. Rủi ro khi expose trực tiếp course/result/submission qua Ingress?**
Các service khai `/api/v1/internal/**` là `permitAll` (dành cho gọi nội bộ, không
qua gateway). Vì vậy nếu hostname public tồn tại, API nội bộ có thể bị gọi từ
ngoài. Đã ghi nhận và đưa vào Hướng phát triển: bỏ Ingress nội bộ, hoặc giới hạn
path, hoặc NetworkPolicy chỉ cho pod gateway.

**D5. Nếu lộ `cloudflare_tunnel_run.sh` thì sao?**
Token tunnel cho phép đẩy traffic vào cụm ⇒ phải thu hồi tunnel trong Cloudflare
Zero Trust và tạo token mới. File này đã gitignore; không bao giờ đưa vào báo cáo.

**D6. Vì sao Keycloak chạy `start-dev`?**
Staging 1 node, cần khởi động nhanh, không cần cluster cache. Production phải dùng
`start` + `KC_CACHE=ispn` + TLS nội bộ. Đây là điểm **đã biết**, không nên nói là
"production-ready".

### Nhóm E — Câu hỏi bẫy (E1–E6)

**E1. "Hệ thống có High Availability không?"**
**Không.** 1 node, phần lớn 1 replica. Trả lời thẳng: "Không, và đây là giới hạn
đã ghi trong báo cáo. HA cần ≥3 node, replica ≥2 cho mọi service, PDB, và
Postgres/Kafka tự vận hành."

**E2. "Chịu được bao nhiêu người dùng đồng thời?"**
Trả lời theo số đo thật: đã kiểm thử API read ở mức 3 VU (~150s, 276 request, 0%
lỗi, p95 ~653ms) trên staging; chưa có số đo vượt 5 VU nên **không kết luận** năng
lực tải tối đa. Nói rõ đây là hạn chế của phần đánh giá, không phải suy đoán.

**E3. "Sao không dùng Terraform/Ansible?"**
Script bash + manifest đủ cho 1 cụm và dễ đọc trong phạm vi đồ án. Terraform sẽ
tốt hơn khi có nhiều môi trường/nhà cung cấp; đã ghi ở Hướng phát triển.

**E4. "Sao không bật HPA?"**
1 node, RAM đã khít: scale thêm chỉ tạo pod `Pending`. HPA cần cluster có chỗ
trống + metric server ổn định. Trước khi bật HPA phải giải bài toán tài nguyên.

**E5. "Nếu pod executor chết giữa lúc chấm bài thì sao?"**
Bài đó sẽ không có kết quả và ở trạng thái `GRADING`/`FAILED`. Hiện **chưa có retry
tự động** — đây là mục "khả năng phục hồi" trong Hướng phát triển (dùng Kafka
redelivery + idempotency key). Nói thẳng thay vì nhận là đã có.

**E6. "Số liệu RAM/CPU kia là đo hay khai báo?"**
Khai báo trong manifest (`requests`/`limits`). Số **đo** nằm ở Chương 3 (kiểm thử
hiệu năng) và chỉ cho luồng API read + một grading smoke. Không trộn hai loại số.

---

## 3.5 Câu hỏi nền tảng (không chỉ về deploy)

Nếu hội đồng hỏi ra ngoài phạm vi triển khai — sync/async, polling vs push, một
request đi qua layer nào, reverse/forward proxy, idempotency, khó khăn của
microservices, circuit breaker, orchestration, resiliency/HA/scalability,
horizontal/vertical scaling, public/private subnet, object/block/file storage —
câu trả lời mẫu và ví dụ trong đồ án nằm ở
[`../design/backend-concepts-va-system-design.md`](../design/backend-concepts-va-system-design.md)
(mục 13 có bảng trả lời 1 dòng cho từng khái niệm).

---

## 4. Ba điều tuyệt đối tránh khi trình bày

| Tránh | Vì sao | Nói thay thế |
|---|---|---|
| Nói "hệ thống HA / production-ready" | Sai sự thật: 1 node, 1 replica, `start-dev` | "Thiết kế cho staging 1 node, có đường nâng cấp lên HA" |
| Nói "RustFS/Keycloak do ArgoCD quản lý" | Sai: chúng cài bằng script | "GitOps cho 6 workload nghiệp vụ; hạ tầng stateful dùng script idempotent" |
| Đọc/chiếu secret, token, connection string lên màn hình | Lộ credential trong buổi demo | Chỉ chiếu **tên** Secret và **độ dài** giá trị |

---

## 5. Checklist 10 phút trước khi vào phòng

```bash
bash status.sh                                   # mọi thứ xanh
kubectl -n argocd get applications               # 6 app Synced + Healthy
kubectl -n web-grading get pods                  # không CrashLoop, RESTARTS thấp
curl -s -o /dev/null -w '%{http_code}\n' https://web-dev1-api.vucongtuanduong.dpdns.org/actuator/health
pgrep -f "cloudflared tunnel" >/dev/null && echo "tunnel OK"
test -f .env && echo ".env present (không mở ra khi chiếu)"
```

Nếu tunnel chưa chạy: `bash cloudflare_tunnel_run.sh` (terminal riêng) — không có
tunnel thì mọi hostname public trả lỗi, dù cụm vẫn khoẻ.
