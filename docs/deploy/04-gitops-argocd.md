# 04 — GitOps với ArgoCD và luồng CI/CD

> Câu chốt: **cụm không được "deploy bằng tay"**. Trạng thái mong muốn nằm trong
> Git; ArgoCD liên tục so sánh Git với cụm và kéo cụm về đúng Git.

---

## 1. Ba repo, ba vai trò

| Repo | Nội dung | Ai ghi |
|---|---|---|
| `web-grading-system-backend-services` | Source code 6 service + 2 workflow GitHub Actions | Lập trình viên (PR) |
| `web-grading-system-services-config` | 6 Helm chart + `values-stg.yaml` | **CI ghi** dòng `image.tag`; người viết chart sửa phần còn lại |
| `web-grading-system-deploy` (repo này) | Script cài đặt, manifest hạ tầng (`deploy/`), Application template | Người vận hành (PR) |

Trong workspace này `config-services/` là bản checkout của repo config (bị
`.gitignore` ở repo deploy) — ArgoCD đọc **repo trên GitHub**, không đọc đĩa local.

---

## 2. Application: 9 trường quyết định tất cả

`deploy/argocd-apps/argocd-app-template.yaml` (đã render thành
`generated/<service>.yaml`):

| Trường | Giá trị | Ý nghĩa | Sai thì sao |
|---|---|---|---|
| `metadata.name` | `grading-${SERVICE_NAME}` | Tên Application; **cũng là Helm release name** ⇒ quyết định tên Deployment/Service | Đổi tên ⇒ Ingress backend và `*_SERVICE_URI` trỏ sai |
| `metadata.namespace` | `argocd` | Nơi lưu object Application | |
| `spec.project` | `default` | Project mặc định của ArgoCD (không giới hạn repo/namespace) | |
| `source.repoURL` | `.../web-grading-system-services-config.git` | Repo chứa chart | Sai ⇒ `ComparisonError` |
| `source.targetRevision` | `main` | Nhánh theo dõi | Muốn staging riêng thì tạo nhánh `stg` |
| `source.path` | `<service>` | Thư mục chart trong repo config | Sai ⇒ "path does not exist" |
| `source.helm.valueFiles` | `[values-stg.yaml]` | File values được dùng | Thiếu ⇒ dùng `values.yaml` mặc định (không có ⇒ giá trị rỗng, pod lỗi) |
| `destination.server` | `https://kubernetes.default.svc` | Cụm đích = cụm đang chạy ArgoCD | |
| `destination.namespace` | `web-grading` | Namespace đích | |
| `syncPolicy.automated.prune` | `true` | Xoá resource **không còn trong Git** | Tắt ⇒ resource thừa nằm lại mãi |
| `syncPolicy.automated.selfHeal` | `true` | Sửa lại resource bị sửa tay | Tắt ⇒ cụm trôi khỏi Git |
| `syncOptions` | `CreateNamespace=false` | **Không** tự tạo namespace | Namespace phải tồn tại trước (do `setup-namespace.sh`) — nếu không ArgoCD báo lỗi và không sync |

### Vì sao `CreateNamespace=false`

Vì namespace `web-grading` phải có **Secret trước** khi pod được tạo
(`db-secret`, `gateway-trust`…). Nếu để ArgoCD tự tạo namespace, nó có thể tạo
pod trước khi Secret tồn tại ⇒ pod kẹt `CreateContainerConfigError` và ArgoCD cứ
hiển thị "Progressing". Việc tách "tạo namespace + Secret" ra khỏi GitOps là **có
chủ đích**: secret không nằm trong Git.

---

## 3. ArgoCD quản lý cái gì — và không quản lý cái gì

| Thành phần | Ai quản lý | Hệ quả |
|---|---|---|
| 6 microservice (Deployment/Service) | **ArgoCD** | Sửa tay sẽ bị `selfHeal` revert |
| Keycloak | `kubectl apply` tay (`setup.sh` bước 7) | Sửa manifest phải apply lại |
| RustFS (PVC/Service/Deployment/Ingress) | `install-rustfs.sh` | README nói rõ: "ArgoCD does **not** manage RustFS" |
| Kafka UI | `kubectl apply` tay | |
| Prometheus/Grafana/Tempo | Helm release `monitoring` + `tempo` (`install.sh`) | Không phải ArgoCD Application |
| Ingress của nghiệp vụ | `install-ingress.sh` (apply tay) | Không bị prune khi sync service |
| Secret | `setup-namespace.sh` | Không bao giờ nằm trong Git |

Ranh giới này nên nói rõ: **GitOps áp dụng cho workload nghiệp vụ**, còn hạ tầng
dùng chung (stateful, secret, công cụ) được cài bằng script idempotent. Lý do:
trộn PVC/Secret vào GitOps sẽ khiến `prune` có thể xoá dữ liệu, và Secret thì
không được nằm trong Git.

---

## 4. Pipeline CI/CD từ commit tới pod chạy code mới

### 4.1 Workflow 1 — `Build and Test Services` (`build-services.yml`)

```
push/PR vào main
  └─ job detect-changes: dorny/paths-filter → service nào có file đổi
        → xuất matrix JSON + upload artifact "changed-services"
  └─ job build (matrix, fail-fast: false)
        ├─ mvn clean package -DskipTests -U
        └─ mvn test -Dtest='!*ApplicationTests' -Dsurefire.failIfNoSpecifiedTests=false
```

Điểm cần biết:

- **Chỉ build service bị ảnh hưởng** ⇒ pipeline ngắn, không phí 6 lần build.
- `-Dtest='!*ApplicationTests'` loại các test `contextLoads` cần hạ tầng; nếu
  không có cờ này, `api-gateway` (chỉ có đúng 1 class `*ApplicationTests`) sẽ
  chọn **0 class** và fail.
- `fail-fast: false`: một service fail không chặn các service khác.

### 4.2 Workflow 2 — `Publish Docker Images` (`publish.yml`)

Chỉ chạy khi workflow 1 **thành công** trên nhánh `main`:

```
workflow_run(completed, success, main)
  └─ job detect-changes: tải lại artifact "changed-services"
  └─ job publish (matrix từng service)
        1. Tính version: tag gần nhất = git tag "<svc>-v*" → tăng patch
           (không có tag → v1.0.0)
        2. mvn clean package -DskipTests
        3. gh release create "<svc>-v<version>" kèm file .jar
        4. docker/build-push-action: push 2 tag
             docker.io/<user>/web-grading-system-<svc>:<version>
             docker.io/<user>/web-grading-system-<svc>:latest
  └─ job update-config
        1. clone repo config bằng CONFIG_REPO_TOKEN
        2. sed -i "s|tag: .*|tag: \"<version>\"|" <svc>/values-stg.yaml
        3. git commit -m "chore: update image tags for changed services" && git push
```

### 4.3 Workflow 3 — ArgoCD (không phải GitHub Actions)

```
ArgoCD poll repo config (mặc định ~3 phút, hoặc webhook)
  → thấy values-stg.yaml đổi
  → helm template lại
  → diff với cụm
  → OutOfSync → sync: apply Deployment mới (image tag mới)
  → RollingUpdate: pod mới Ready rồi pod cũ bị xoá
```

### 4.4 Dòng thời gian một lần deploy (số liệu thực tế của pipeline này)

| Bước | Thời gian điển hình | Ghi chú |
|---|---|---|
| Build + test 1 service | 1–3 phút | Maven cache trong Actions |
| Push image | 20–60 giây | Image Spring Boot ~250–350 MB |
| Update config repo | < 10 giây | 1 commit, 1 dòng |
| ArgoCD phát hiện | ≤ 3 phút | chu kỳ poll mặc định |
| Rolling update | 30–90 giây | startupProbe cho tới 300s nếu JVM chậm |

Tổng: **~5–7 phút** từ merge tới pod chạy code mới, **không thao tác tay** trên cụm.

---

## 5. Trạng thái và cách đọc chúng

```
kubectl get applications -n argocd
NAME                        SYNC STATUS   HEALTH STATUS
grading-api-gateway         Synced        Healthy
grading-course-service      OutOfSync     Healthy
grading-executor-service    Synced        Progressing
```

| SYNC STATUS | Nghĩa | Hành động |
|---|---|---|
| `Synced` | Manifest trong Git = manifest trong cụm | — |
| `OutOfSync` | Có khác biệt (thường là vừa đổi values, hoặc ai đó `kubectl edit`) | Chờ poll, hoặc `argocd app sync <app>` |
| `Unknown` | Không so sánh được (repo lỗi, mất mạng) | `argocd app get <app>` xem `ComparisonError` |

| HEALTH STATUS | Nghĩa | Hành động |
|---|---|---|
| `Healthy` | Mọi Deployment đủ replica Ready | — |
| `Progressing` | Pod đang rollout/chưa Ready | `kubectl rollout status deploy/grading-<svc>` |
| `Degraded` | Có pod CrashLoop/ImagePullBackOff | `kubectl describe pod`, `kubectl logs` |
| `Missing` | Resource trong Git chưa có trong cụm | `argocd app sync <app>` |

Câu hỏi hay gặp: *"OutOfSync mà Healthy là sao?"* — nghĩa là cụm đang chạy được
nhưng lệch Git (ví dụ ai đó vừa `kubectl scale`, hoặc `image.tag` mới chưa sync).
Với `selfHeal: true`, nó sẽ tự về `Synced` trong vài phút.

---

## 6. Ba cách rollback (và cách đúng trong GitOps)

| Cách | Lệnh | Đánh giá |
|---|---|---|
| **1. Revert commit trong repo config** (chuẩn GitOps) | `git revert <sha> && git push` | ArgoCD sync → về tag cũ. Có audit trail, đúng triết lý GitOps |
| 2. ArgoCD rollback | `argocd app history grading-course-service` → `argocd app rollback grading-course-service <id>` | Nhanh, nhưng **lệch Git**: lần sync sau sẽ quay lại bản mới. Chỉ dùng để chữa cháy |
| 3. `kubectl rollout undo` | `kubectl rollout undo deploy/grading-course-service` | Bị `selfHeal` revert trong ~3 phút. **Không dùng** |

Nói thêm: vì mỗi service có chart riêng, rollback **độc lập** — hạ course-service
không ảnh hưởng executor.

---

## 7. `dev-scale.sh` và mâu thuẫn với `selfHeal`

`kubectl scale` bị ArgoCD revert vì Git nói `replicas: 2`. Script giải quyết bằng
cách **tạm gỡ `spec.syncPolicy.automated`** khỏi Application (ArgoCD vẫn giữ
resource, chỉ ngừng tự đồng bộ), lưu giá trị cũ vào `.dev-scale-state/<svc>.json`,
rồi khôi phục khi bật lại:

```
trước:  spec.syncPolicy.automated = { prune: true, selfHeal: true }
off:    xoá path /spec/syncPolicy/automated  → scale replicas=0
on:     patch merge trả lại automated (đọc từ state file)  → scale replicas=2
```

Đây là ví dụ tốt để nói về **"GitOps không cấm thao tác khẩn cấp, nhưng mọi thao
tác khẩn cấp phải có đường quay lại và phải được ghi lại"**. Nếu scale N>1 mà
không sửa `values-stg.yaml`, lần sync sau sẽ kéo về số cũ — script cảnh báo đúng
điều đó.

---

## 8. Những giới hạn của thiết kế GitOps ở đồ án này

| Giới hạn | Ảnh hưởng | Cách khắc phục nếu mở rộng |
|---|---|---|
| Chỉ có 1 môi trường (`values-stg.yaml`) | Không có staging/prod song song | Thêm `values-prod.yaml` + Application thứ hai trỏ `path` khác hoặc `targetRevision` khác |
| Không có ArgoCD Image Updater | Tag do CI ghi, không tự dò registry | Thêm Image Updater nếu muốn |
| Không có ApplicationSet | Thêm service phải chạy lại script | ApplicationSet + generator từ `services.env` |
| Repo config public, token chỉ dùng để CI ghi | ArgoCD đọc không cần credential | Đổi sang private + `repository` secret |
| Poll 3 phút thay vì webhook | Deploy chậm tối đa 3 phút | Cấu hình webhook GitHub → ArgoCD |
| Không có notification | Không ai được báo khi sync fail | Bật `argocd-notifications` (đang scale 0) |
| Sync toàn bộ chart, không wave | Không kiểm soát thứ tự giữa các resource trong 1 chart | Thêm `argocd.argoproj.io/sync-wave` nếu chart phức tạp |

---

## 9. Bảo mật của chính ArgoCD

| Hạng mục | Trạng thái hiện tại | Ghi chú khi bị hỏi |
|---|---|---|
| Mật khẩu admin | `argocd-initial-admin-secret` (in ra khi cài) | Nên đổi và lưu ngoài Git |
| TLS | Kết thúc ở Cloudflare; `argocd-server` chạy `--insecure` | Nội bộ cụm vẫn là HTTP ⇒ không nên expose NodePort trực tiếp |
| SSO | Không dùng (dex chạy nhưng không cấu hình connector) | Có thể nối Keycloak OIDC nếu cần |
| RBAC | `project: default`, tài khoản admin | Mọi người dùng chung 1 tài khoản ⇒ không có audit theo người |
| Quyền ghi repo | ArgoCD **read-only** với repo config | Chỉ CI có `CONFIG_REPO_TOKEN` để ghi |
