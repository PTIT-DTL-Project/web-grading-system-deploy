# 08 — Vận hành và xử lý sự cố

> Toàn bộ lệnh dưới đây là lệnh đã dùng khi dựng cụm thật của đồ án. Không có lệnh
> nào cần quyền đặc biệt ngoài `sudo` cho `systemctl`/`crictl`.

---

## 1. Điều kiện trước khi cài

| Thành phần | Kiểm tra | Ghi chú |
|---|---|---|
| k3s | `kubectl get nodes` | Chưa có thì `curl -sfL https://get.k3s.io \| sh -` |
| kubectl | `kubectl version --client` | k3s tạo sẵn `/etc/rancher/k3s/k3s.yaml` |
| helm ≥ 3.16 | `helm version --short` | Cần cho OCI chart của observability |
| docker | `docker version` | Chỉ cần cho `cleanup-old-images.sh` (phần docker) |
| cloudflared | `cloudflared --version` | Cần cho tunnel |
| openssl | `openssl version` | Sinh `gateway-trust` |
| python3 | `python3 --version` | Dùng trong `cleanup-old-images.sh` |
| `.env` | `ls -l .env && chmod 600 .env` | Xem [07](07-secrets-va-bien-moi-truong.md) |

Kiểm tra nhanh trước khi bắt đầu:

```bash
kubectl get nodes -o wide
kubectl get svc -n kube-system traefik \
  -o jsonpath='{.spec.ports[?(@.name=="web")].nodePort}'; echo
# Ghi lại số này — đó là GATEWAY_PORT trong .env
```

---

## 2. Cài lần đầu: từng bước kèm kiểm tra

### Bước 0 — Chuẩn bị `.env`

```bash
cp .env.example .env
chmod 600 .env
$EDITOR .env       # DB_*, RUSTFS_*, KEYCLOAK_*, KAFKA_*, AI_*, GATEWAY_PORT
```

Bắt buộc có giá trị: `DB_*`, `RUSTFS_*`, `KEYCLOAK_DB_*`,
`KEYCLOAK_ADMIN_CLIENT_ID`, `KEYCLOAK_ADMIN_CLIENT_SECRET`.
Nếu thiếu 2 biến cuối, bước 1 sẽ **dừng có chủ đích** với thông báo lỗi.

### Bước 1 — Namespace + Secret

```bash
bash deploy/setup-namespace.sh
```

Kiểm tra:

```bash
kubectl -n web-grading get secret
# Kỳ vọng 8 secret: db-secret, rustfs-secret, app-config, gateway-trust,
#                  kafka-aiven-credentials, keycloak-db,
#                  keycloak-admin-client, ai-credentials
```

### Bước 2 — RustFS

```bash
bash deploy/install-rustfs.sh
kubectl -n web-grading get pvc,pods -l app=rustfs
```

Kỳ vọng: PVC `rustfs-pvc` = `Bound`, pod `1/1 Running`. Nếu pod
`CreateContainerConfigError` ⇒ chưa có Secret `rustfs-secret`.

### Bước 3 — Ingress

```bash
bash deploy/install-ingress.sh
kubectl -n web-grading get ingress
```

7 Ingress. Ở bước này chưa có Service nào ⇒ chưa truy cập được, đó là bình thường.

### Bước 4 — ArgoCD + 6 Application

```bash
bash deploy/install-argocd.sh
```

Script in ra mật khẩu admin. Kiểm tra:

```bash
kubectl -n argocd get applications
kubectl -n web-grading get deploy
```

Kỳ vọng: 6 Application, sau ~2–5 phút 6 Deployment có `READY 1/1`
(riêng executor `2/2`).

### Bước 5 — Observability

```bash
cp deploy/observability/.env.observability.example deploy/observability/.env.observability
# đặt GRAFANA_ADMIN_PASSWORD mạnh
bash deploy/observability/install.sh
```

Kiểm tra:

```bash
kubectl -n observability get pods
# Kỳ vọng: prometheus-*, monitoring-grafana-*, tempo-0, operator-*
# KHÔNG được có node-exporter hay kube-state-metrics
```

### Bước 6 — Keycloak

```bash
kubectl apply -n web-grading -f deploy/keycloak/deployment.yaml
kubectl apply -n web-grading -f deploy/keycloak/service.yaml
kubectl -n web-grading rollout status deploy/keycloak --timeout=180s
```

Lần đầu Keycloak chạy migration DB (Neon) nên có thể mất 1–3 phút. Kiểm tra:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  https://web-dev1-keycloak.vucongtuanduong.dpdns.org/realms/ptit-wgs/.well-known/openid-configuration
# Kỳ vọng 200, và issuer trong JSON phải là https://web-dev1-keycloak.../realms/ptit-wgs
```

### Bước 7 — Tunnel

```bash
bash cloudflare_tunnel_run.sh     # terminal riêng, foreground
```

### Bước 8 — Kiểm tra đầu-cuối

```bash
# a) tất cả pod Ready
kubectl -n web-grading get pods

# b) health từng service (qua ingress)
for h in api course submission result grading ai; do
  printf '%-12s %s\n' "$h" \
    "$(curl -s -o /dev/null -w '%{http_code}' https://web-dev1-$h.vucongtuanduong.dpdns.org/actuator/health)"
done

# c) đăng nhập thật qua Keycloak (an toàn: chỉ in mã HTTP)
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://web-dev1-keycloak.vucongtuanduong.dpdns.org/realms/ptit-wgs/protocol/openid-connect/token \
  -d grant_type=password -d client_id=wgs-postman \
  -d username=<user> -d password=<pass>
# 200 = Keycloak + DB + client OK

# d) ArgoCD
kubectl -n argocd get applications
```

---

## 3. Vận hành hàng ngày

### 3.1 Deploy phiên bản mới (đường chuẩn)

```
merge PR vào main
  → CI build + test → push image → commit tag vào repo config
  → ArgoCD sync (≤ 3 phút)
```

Theo dõi:

```bash
watch -n 5 'kubectl -n argocd get applications; kubectl -n web-grading get pods'
kubectl -n web-grading rollout status deploy/grading-course-service --timeout=300s
```

### 3.2 Deploy tay (khi chưa có CI, ví dụ demo)

```bash
# sửa tag trong repo config, commit, push → ArgoCD tự sync
cd ../web-grading-system-services-config
sed -i 's|tag: .*|tag: "v1.0.43"|' course-service/values-stg.yaml
git commit -am "chore: course-service v1.0.43" && git push
```

Hoặc ép sync ngay (không chờ poll):

```bash
argocd app sync grading-course-service
# hoặc
kubectl -n argocd annotate application grading-course-service \
  argocd.argoproj.io/refresh=hard --overwrite
```

### 3.3 Rollback

```bash
# Cách đúng (GitOps): revert commit tag
cd ../web-grading-system-services-config
git revert <sha> && git push

# Chữa cháy nhanh (sẽ bị sync sau ghi đè):
argocd app history grading-course-service
argocd app rollback grading-course-service <id>
```

### 3.4 Đổi mức log

```bash
bash set-log-level.sh DEBUG     # tự cập nhật Secret + restart toàn bộ 6 service
bash set-log-level.sh INFO      # trả lại
```

### 3.5 Scale tạm thời / tắt service để code local

```bash
bash dev-scale.sh status
bash dev-scale.sh executor off      # 0 replica, ArgoCD sync tạm treo
bash dev-scale.sh executor on       # về 2 replica, phục hồi sync
```

### 3.6 Dọn image cũ trên node (khi đĩa đầy)

```bash
df -h /            # kiểm tra trước
bash deploy/cleanup-old-images.sh
```

### 3.7 Khởi động lại sau reboot

```bash
bash start.sh      # k3s + chờ node Ready + in trạng thái
bash cloudflare_tunnel_run.sh   # terminal riêng
```

`start.sh` **không** start tunnel (tunnel chạy foreground, có token riêng).

---

## 4. Bảng chẩn đoán sự cố

### 4.1 Pod

| Triệu chứng | Lệnh | Nguyên nhân thường gặp | Xử lý |
|---|---|---|---|
| `ImagePullBackOff` | `kubectl -n web-grading describe pod <pod>` | Tag không tồn tại, Docker Hub rate limit, sai repository | Sửa `image.tag` trong repo config |
| `CreateContainerConfigError` | `kubectl -n web-grading describe pod <pod>` | Thiếu Secret/key | `bash deploy/setup-namespace.sh` |
| `CrashLoopBackOff` | `kubectl -n web-grading logs <pod> --previous` | Thiếu env, DB sai, port trùng, OOM | Xem log dòng cuối; kiểm tra `exit code 137` = OOMKilled |
| `Pending` | `kubectl -n web-grading describe pod <pod>` | Node hết RAM/CPU request | `kubectl top nodes`; tắt Kafka UI/scale service không dùng |
| `Running` nhưng `0/1` | `kubectl -n web-grading describe pod <pod> \| grep -A5 Readiness` | Probe fail (DB down, Keycloak chậm) | Xem `Events` + log |
| Restart liên tục không log | `kubectl -n web-grading describe pod` | Liveness/startup fail trước khi app kịp log | Tăng `failureThreshold`/`initialDelay` hoặc sửa probe path |

### 4.2 Hạ tầng

| Triệu chứng | Nguyên nhân | Kiểm tra |
|---|---|---|
| Tất cả API 401 dù token mới | `gateway-trust` lệch | So sánh env gateway vs service (mục 5.3 của [07](07-secrets-va-bien-moi-truong.md)) |
| Keycloak 502/503 | Pod chưa Ready hoặc hostname mismatch | `kubectl -n web-grading logs deploy/keycloak`; so `KC_HOSTNAME` với issuer |
| Upload ZIP lỗi CORS | Origin FE chưa có trong `RUSTFS_CORS_ALLOWED_ORIGINS` | `curl -X OPTIONS` ([05](05-ingress-va-cloudflare.md) §6.2) |
| Bài nộp mãi `PENDING` | Kafka không kết nối được, executor không consume | `kubectl -n web-grading logs deploy/grading-executor-service \| grep -i kafka`; xem topic trên Kafka UI |
| `PENDING` và executor không có log | Kafka event không tới | Kiểm tra Secret `kafka-aiven-credentials`, topic `wgs-events-deploy` |
| Chấm bài treo | dind trong executor lỗi | `kubectl -n web-grading logs <executor-pod> -c dind --tail=100` |
| Grafana "No data" phần trace | Tempo thiếu metrics_generator processors | Kiểm tra `overrides.defaults.metrics_generator.processors` |
| Grafana báo `http2: frame too large` | Tempo thiếu `streamOverHttpEnabled` | Bật lại trong `tempo-values.yaml`, helm upgrade |
| ArgoCD `ComparisonError` | Repo config không truy cập được / path sai | `kubectl -n argocd logs deploy/argocd-repo-server` |
| ArgoCD pod OOMKilled | Thiếu limits (bản upstream) | Chạy lại `install-argocd.sh` (bước set resources) |
| Node hết đĩa | Image cũ tích tụ | `bash deploy/cleanup-old-images.sh` |

### 4.3 Lệnh "nhìn nhanh" toàn hệ thống

```bash
bash status.sh                 # tổng hợp: k3s, namespace, app, pod, tunnel
kubectl top nodes
kubectl top pods -n web-grading --sort-by=memory | head
kubectl -n web-grading get events --sort-by=.lastTimestamp | tail -20
kubectl -n web-grading get endpoints   # service nào không có endpoint = có vấn đề
```

---

## 5. Kiểm tra sức khoẻ định kỳ (health review 15 phút)

| Việc | Lệnh | Kỳ vọng |
|---|---|---|
| Pod không restart nhiều | `kubectl -n web-grading get pods` (cột RESTARTS) | 0 hoặc tăng chậm |
| Không OOMKilled | `kubectl -n web-grading get pods -o json \| jq '.items[].status.containerStatuses[] \| select(.lastState.terminated.reason=="OOMKilled")'` | rỗng |
| ArgoCD đồng bộ | `kubectl -n argocd get applications` | tất cả `Synced`, `Healthy` |
| Ingress có đích | `kubectl -n web-grading get endpoints` | mỗi service có ≥1 IP |
| Metric chảy | Grafana → Explore → `up{namespace="web-grading"}` | 6 series = 1 |
| Trace chảy | Grafana → Explore → Tempo → Search | có trace trong 24h |
| Đĩa còn chỗ | `df -h /` | < 80% |
| RAM còn chỗ | `kubectl top nodes` | < 85% |

---

## 6. Việc **không** được làm (và lý do)

| Không làm | Vì sao | Nếu buộc phải làm |
|---|---|---|
| `kubectl delete pvc` | Mất file bài nộp / metric / dashboard vĩnh viễn | Backup trước; nói rõ hậu quả |
| `kubectl edit deploy` service nghiệp vụ | Bị `selfHeal` revert, gây khó hiểu | Sửa repo config |
| `kubectl scale` khi không treo sync | Bị revert sau ≤ 3 phút | Dùng `dev-scale.sh` |
| Commit `.env`, `cloudflare_tunnel_run.sh`, `*.pem` | Lộ credential vào lịch sử Git | `git check-ignore -v <file>` trước khi `git add` |
| `kubectl exec` sửa file trong container | Mất khi pod restart, không audit | Sửa image/config |
| `docker system prune` trên node | Có thể xoá image dind đang dùng | Dùng `cleanup-old-images.sh` (giữ image đang chạy) |
| Tắt `livenessProbe` để "hết restart" | Che giấu lỗi thật, pod chết vẫn nhận traffic | Sửa nguyên nhân (probe path/timeout) |

---

## 7. Cheat sheet một trang

```bash
# --- trạng thái ---
bash status.sh
kubectl -n web-grading get pods,svc,ingress
kubectl -n argocd get applications
kubectl top pods -n web-grading --sort-by=memory

# --- log ---
kubectl -n web-grading logs deploy/grading-api-gateway -f --tail=100
kubectl -n web-grading logs <pod> -c dind --tail=100
kubectl -n web-grading logs <pod> --previous

# --- vào trong pod ---
kubectl -n web-grading exec -it deploy/grading-course-service -- sh
kubectl -n web-grading exec deploy/grading-course-service -- printenv | sort

# --- restart / rollout ---
kubectl -n web-grading rollout restart deploy/grading-course-service
kubectl -n web-grading rollout status deploy/grading-course-service
kubectl -n web-grading rollout history deploy/grading-course-service

# --- secret (không in giá trị) ---
kubectl -n web-grading get secret gateway-trust -o jsonpath='{.data.GATEWAY_TRUSTED_SECRET}' | base64 -d | wc -c

# --- gitops ---
argocd app list
argocd app get grading-course-service
argocd app sync grading-course-service
argocd app history grading-course-service

# --- dọn dẹp ---
bash deploy/cleanup-old-images.sh
kubectl -n web-grading scale deploy/kafka-ui --replicas=0     # tiết kiệm RAM

# --- reset toàn bộ (cẩn thận: xoá namespace, GIỮ PVC) ---
bash clean.sh
```
