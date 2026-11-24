# 03 — Helm chart và từng tham số

> Mỗi tham số dưới đây được đọc từ `config-services/<service>/values-stg.yaml` và
> `config-services/<service>/templates/deployment.yaml` của repo hiện tại. Cột
> "Giá trị staging" là giá trị **thật đang dùng**, không phải ví dụ.

---

## 1. Một chart gồm những gì

```
config-services/api-gateway/
├── Chart.yaml              # danh tính chart: apiVersion v2, name, version, appVersion
├── values-stg.yaml         # tham số môi trường (cái bạn sửa khi deploy)
└── templates/
    ├── _helpers.tpl        # hàm đặt tên: api-gateway.name / api-gateway.fullname
    ├── deployment.yaml     # Pod template: image, env, probe, resources
    └── service.yaml        # Service ClusterIP
```

Luồng render (ArgoCD làm thay bạn):

```
values-stg.yaml ──┐
                  ├──► helm template ──► YAML cuối cùng ──► kubectl apply ──► cụm
templates/*.yaml ─┘        (thay {{ .Values.x }}, {{ include "..." . }})
```

Hai điều cần nói rõ khi thuyết trình:

1. **Chart không chứa secret.** Mọi credential đi qua `valueFrom.secretKeyRef`
   ⇒ trong Git chỉ có *tên* Secret và *tên* key, không có giá trị.
2. **`values-stg.yaml` là hợp đồng với CI.** Pipeline chỉ sửa đúng dòng
   `tag: ...`; mọi thứ còn lại do người viết chart quyết định.

---

## 2. Quy tắc đặt tên (và vì sao Ingress khớp được)

`templates/_helpers.tpl`:

```
api-gateway.name      = chart name (hoặc nameOverride)          → "api-gateway"
api-gateway.fullname  = nếu release name CHỨA chart name
                        thì fullname = release name
                        ngược lại  = "<release>-<chart>"
```

ArgoCD đặt tên release = `grading-<service>` (theo `metadata.name` của
Application). Vì `"grading-api-gateway"` chứa `"api-gateway"`, fullname =
**`grading-api-gateway`**.

Đây chính là lý do:

| Thứ | Giá trị | Ai tham chiếu |
|---|---|---|
| Deployment | `grading-api-gateway` | `kubectl logs deploy/grading-api-gateway` |
| Service | `grading-api-gateway` | Ingress backend, `COURSE_SERVICE_URI`… |
| Pod label | `app: api-gateway` | Service selector, Prometheus relabel `app` |
| ArgoCD App | `grading-api-gateway` | `kubectl get applications -n argocd` |

Nếu đổi tên release (không phải `grading-*`), **mọi** Ingress backend và
`*_SERVICE_URI` sẽ trỏ sai — nên `install.sh` cho observability cũng ghi chú
"release name cố định là `monitoring`".

---

## 3. Values dùng chung cho cả 6 service

### 3.1 `global.*`

| Key | Giá trị | Có được template dùng? |
|---|---|---|
| `global.domain` | `vucongtuanduong.dpdns.org` | **Không** — hiện chỉ là metadata cho người đọc (Ingress viết tay trong `deploy/ingress/`) |
| `global.prefix` | `web-dev1` | **Không** — cùng lý do |

Nói thẳng điều này nếu bị hỏi: đây là 2 key "tài liệu hoá quy ước đặt tên", không
sinh ra resource. Việc dùng thật nằm ở host trong `deploy/ingress/*.yaml`.

### 3.2 `image.*`

| Key | Giá trị staging (ví dụ gateway) | Vai trò |
|---|---|---|
| `image.registry` | `docker.io` | Registry gốc |
| `image.repository` | `vucongtuanduong/web-grading-system-api-gateway` | Tên image (Docker Hub) |
| `image.tag` | `v1.0.23` | **Thứ CI sửa**; mỗi service một số khác nhau |
| `image.pullPolicy` | `Always` | Luôn kiểm tra registry khi tạo pod (tag semver nhưng vẫn `Always` để tránh node giữ bản cũ) |

Tag hiện tại của 6 service: gateway `v1.0.23`, course `v1.0.42`, submission
`v1.0.35`, executor `v1.0.40`, result `v1.0.39`, ai `v1.0.22`. Số patch tăng tự
động trong CI (xem [04](04-gitops-argocd.md)).

### 3.3 `spring.*`

| Key | Giá trị | Env sinh ra | Vai trò |
|---|---|---|---|
| `spring.profilesActive` | `stg` | `SPRING_PROFILES_ACTIVE=stg` | Chọn `application-stg.yaml` trong image (log JSON, endpoint, timeout…) |
| `spring.dbName` | `assignment_db` (course)… | `DB_NAME=<dbName>` | **Tên database**, không phải host. Host/user/pass lấy từ Secret `db-secret` |

Lưu ý: `api-gateway` **không** có `spring.dbName` ⇒ `DB_NAME` render thành chuỗi
rỗng. Vô hại vì gateway không có datasource; nhưng nếu ai đó thêm datasource vào
gateway, đây là chỗ phải sửa.

### 3.4 `observability.*`

| Key | Giá trị | Env | Vai trò |
|---|---|---|---|
| `observability.region` | `dev` | `REGION=dev` | Gắn vào log/metric để phân biệt môi trường |
| `observability.cluster` | `k3s-local` | `CLUSTER=k3s-local` | Như trên (nhãn cụm) |

### 3.5 `service.*`

| Key | Giá trị | Ảnh hưởng |
|---|---|---|
| `service.type` | `ClusterIP` | Service chỉ có IP nội bộ cụm; không lộ trực tiếp ra ngoài |
| `service.port` | 8080/8081/8082/8083/8084/8086 | `containerPort` **và** `Service.port` **và** cổng của cả 3 probe |

Vì `service.port` được dùng cho cả container, Service và probe, đổi nó là đổi
đồng bộ — nhưng **phải** đổi cả `deploy/ingress/*.yaml` (backend `number`) và
`*_SERVICE_URI` ở gateway, nếu không traffic sẽ 503.

### 3.6 `resources.*`

| Key | Giá trị | Vai trò |
|---|---|---|
| `resources.limits.cpu` | `500m` | Trần CPU (CFS quota) — 0,5 core mỗi service |
| `resources.limits.memory` | `512Mi` | Trần RAM ⇒ JVM đặt heap theo `MaxRAMPercentage` |
| `resources.requests.cpu` | `200m` | Scheduler dùng để xếp pod |
| `resources.requests.memory` | `256Mi` | Như trên; cũng là ngưỡng để kubelet xếp hạng eviction |

Vì sao `limits.memory` quan trọng với Java: nếu **không** có limit, JVM đọc RAM
của **node** (7,6 GB) và đặt heap ~1,9 GB ⇒ pod vượt xa phần RAM hợp lý của nó.
Có limit 512Mi, Boot 4/JVM tự tính heap ~128Mi–256Mi, phần còn lại cho metaspace,
code cache, thread stack.

### 3.7 Probe (giống nhau ở 5 service; ai-assistant khác — xem §5)

| Probe | Đường dẫn | Tham số | Ý nghĩa |
|---|---|---|---|
| `startupProbe` | `/actuator/health` | period 10s, timeout 5s, **failureThreshold 30** | Cho JVM tối đa **300s** để khởi động; trong thời gian này liveness chưa chạy |
| `readinessProbe` | `/actuator/health` | initialDelay 30s, period 10s | Pod chỉ được thêm vào Endpoints khi trả 200 ⇒ không nhận traffic khi chưa sẵn sàng |
| `livenessProbe` | `/actuator/health` | initialDelay 90s, period 30s, failureThreshold 3 | 3 lần fail liên tiếp (~90s) ⇒ kubelet restart container |

Vì sao cần **cả** startup và liveness: nếu chỉ có liveness với `initialDelay 90s`,
một pod khởi động chậm (Neon wake-up, tải image) sẽ bị kill oan và rơi vào
CrashLoopBackOff. `startupProbe` tách "đang khởi động" khỏi "đang chạy".

---

## 4. Values riêng của từng service

### 4.1 `api-gateway` — định tuyến và tin cậy

| Key | Giá trị | Env | Vai trò |
|---|---|---|---|
| `serviceUris.course` | `http://grading-course-service:8081` | `COURSE_SERVICE_URI` | Đích route `/api/v1/classes/**`, `/assignments/**`, `/scores/**`… |
| `serviceUris.submission` | `http://grading-submission-service:8082` | `SUBMISSION_SERVICE_URI` | Đích route nộp bài/presign |
| `serviceUris.result` | `http://grading-result-service:8084` | `RESULT_SERVICE_URI` | Đích route kết quả chấm |
| `serviceUris.ai_assistant` | `http://grading-ai-assistant-service:8086` | `AI_ASSISTANT_SERVICE_URI` | Đích route trợ lý AI |
| `keycloak.issuerUri` | `https://web-dev1-keycloak.../realms/ptit-wgs` | `KEYCLOAK_ISSUER_URI` | `iss` mà resource server chấp nhận; thiếu ⇒ mọi request có auth fail ở lần dùng đầu (không fail lúc boot) |
| `rateLimit.enabled` | `true` | `RATE_LIMIT_ENABLED` | Công tắc **đăng ký endpoint** `POST /api/v1/account/change-password`: `true` = có endpoint, `false` = 404 (fail closed) |

Chi tiết template đáng chú ý: biến `RATE_LIMIT_ENABLED` dùng `hasKey` chứ không
dùng `default`. Lý do: Go template coi `false` là "empty", nên `default true` sẽ
nuốt mất giá trị `false` mà người dùng cố tình đặt.

Vòng lặp `range $name, $uri := .Values.serviceUris` sinh env theo quy ước
`{{ $name | upper }}_SERVICE_URI` ⇒ thêm service mới chỉ cần thêm 1 dòng values.

Env lấy từ Secret (không nằm trong values):

| Env | Secret/key | Vai trò |
|---|---|---|
| `GATEWAY_TRUSTED_SECRET` | `gateway-trust/GATEWAY_TRUSTED_SECRET` | Giá trị đóng dấu vào header `X-Gateway-Secret` |
| `KEYCLOAK_ADMIN_CLIENT_ID` / `_SECRET` | `keycloak-admin-client` | Client service-account để gọi Admin API (tìm user, reset password) |
| `KEYCLOAK_PASSWORD_CLIENT_ID` / `_SECRET` | `keycloak-admin-client` | Client confidential `wgs-password-verify` dùng password grant để **xác minh mật khẩu hiện tại** (vì client FE đã tắt Direct Access Grants) |
| `DB_*` | `db-secret` | Không dùng (gateway không có datasource) |

### 4.2 `course-service`

| Key | Giá trị | Env | Vai trò |
|---|---|---|---|
| `spring.dbName` | `assignment_db` | `DB_NAME` | DB của lớp/bài tập/điểm |
| `feign.executorService.url` | `http://grading-executor-service:8083` | `FEIGN_EXECUTOR_SERVICE_URL` | Đích gọi executor (dry-run test plan) |

### 4.3 `submission-service`

| Key | Giá trị | Env | Vai trò |
|---|---|---|---|
| `spring.dbName` | `submission_db` | `DB_NAME` | DB bài nộp |
| `wgs.events.topic` | `wgs-events-deploy` | `WGS_EVENTS_TOPIC` | Topic Kafka phát event `submission.uploaded` |

Env từ Secret: `RUSTFS_ENDPOINT`, `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY`,
`RUSTFS_PUBLIC_ENDPOINT` (dùng để ký presigned URL trỏ ra ngoài),
`GATEWAY_TRUSTED_SECRET`, `KAFKA_*`, và volume `kafka-ca` mount tại
`/etc/kafka/secrets` (`KAFKA_CA_PATH=/etc/kafka/secrets/ca.pem`).

### 4.4 `executor-service` — service duy nhất có 2 replica và sidecar

| Key | Giá trị | Env | Vai trò |
|---|---|---|---|
| `replicaCount` | `2` | — | 2 pod; một pod rollout không làm mất toàn bộ năng lực chấm |
| `spring.dbName` | `executor_db` | `DB_NAME` | DB job chấm |
| `wgs.events.topic` | `wgs-events-deploy` | `WGS_EVENTS_TOPIC` | Topic tiêu thụ |

Env cố định trong template (không nằm trong values):

| Env | Giá trị | Vai trò |
|---|---|---|
| `DOCKER_HOST` | `tcp://localhost:2375` | App nói chuyện với Docker daemon của **sidecar** qua localhost (chung network namespace của pod) |
| `RUSTFS_BUCKET_NAME` | `submission-files` | Bucket chứa ZIP |
| `COURSE_SERVICE_URL` / `SUBMISSION_SERVICE_URL` / `RESULT_SERVICE_URL` | `http://grading-*:8081/8082/8084` | Gọi nội bộ (khác tên biến với gateway: `*_URL` vs `*_URI`) |
| `TESTCONTAINERS_RYUK_DISABLED` | `true` | Tắt Ryuk reaper: trong pod, reaper container thường không dọn được và giữ lại container rác |
| `KAFKA_CA_PATH` | `/etc/kafka/secrets/ca.pem` | Truststore PEM cho Aiven |

Sidecar `dind` (Docker-in-Docker):

| Thuộc tính | Giá trị | Vì sao |
|---|---|---|
| image | `docker:27-dind` | Docker daemon thật, để chạy `docker compose` của bài nộp |
| `securityContext.privileged` | `true` | dind cần quyền tạo namespace/mount để chạy nested containers |
| `DOCKER_TLS_CERTDIR` | `""` (rỗng) | Tắt TLS của dind ⇒ daemon nghe `tcp://localhost:2375` không cần cert (chỉ trong pod, không lộ ra ngoài) |
| port | `2375` | App kết nối qua localhost |
| volume `dind-storage` | `emptyDir`, mount `/var/lib/docker` ở **cả 2 container** | Layer/image của bài chấm nằm trong emptyDir ⇒ xoá pod là sạch, không tích vào đĩa node |
| resources | req 100m/256Mi, lim 1000m/1Gi | dind là thành phần ngốn RAM thứ hai sau JVM |

`strategy` của Deployment executor: `maxSurge: 0`, `maxUnavailable: 1` — khi lên
image mới **không bao giờ** có pod thứ 3 (pod thứ 3 = thêm ~500 MB thực trên node
đang khít RAM); đổi lại, luôn có 1 pod tạm ngừng phục vụ trong lúc rollout.

### 4.5 `result-service`

| Key | Giá trị | Env | Vai trò |
|---|---|---|---|
| `spring.dbName` | `result_db` | `DB_NAME` | DB kết quả chấm |
| — | — | `COURSE_SERVICE_URI=http://grading-course-service:8081` | Đọc trọng số plan (internal API) để tính điểm bài |

### 4.6 `ai-assistant-service` — nhiều tham số nhất

Nhóm LLM (từ Secret `ai-credentials`, `optional: true`):

| Env | Ý nghĩa | Rỗng thì sao |
|---|---|---|
| `AI_PROVIDER` / `AI_API_KEY` / `AI_MODEL_NAME` / `AI_BASE_URL` | Model mặc định (chat) | `AI_API_KEY` rỗng ⇒ **fallback template sư phạm cục bộ**, không gọi provider |
| `AI_AGENT_*` (4 biến) | Model riêng cho agent/tool-calling | Rỗng ⇒ dùng cấu hình chung |
| `AI_EXPLAIN_*` (4 biến) | Model riêng cho phần giải thích kết quả chấm | Rỗng ⇒ dùng cấu hình chung |
| `AI_MAX_COMPLETION_TOKENS` | `4096` | Giới hạn token đầu ra (chat) |
| `AI_EXPLAIN_MAX_COMPLETION_TOKENS` | `4096` | Giới hạn token đầu ra (giải thích) |

Nhóm agent (từ `values-stg.yaml`, `agent.*`):

| Key | Giá trị | Vai trò |
|---|---|---|
| `agent.limits.maxModelSteps` | 8 | Số vòng "model → tool" tối đa |
| `agent.limits.maxToolCalls` | 12 | Tổng số lần gọi tool tối đa |
| `agent.limits.maxModelAttempts` | 16 | Số lần gọi model tối đa (kể cả retry) |
| `agent.limits.maxValidationRepairs` | 2 | Số lần sửa output sai schema |
| `agent.limits.maxLookupRounds` | 1 | Số vòng tra cứu dữ liệu |
| `agent.limits.activeTimeoutSeconds` | 120 | Trần thời gian một lượt agent |
| `agent.retry.modelMaxRetries` | 2 | Retry khi model lỗi |
| `agent.retry.safeToolMaxRetries` | 2 | Retry cho tool an toàn (idempotent) |
| `agent.context.maxInputTokens` | 64000 | Trần context gửi model |
| `agent.context.outputReserve` | 4096 | Phần dành cho output |
| `agent.context.safetyMargin` | 2000 | Biên an toàn |
| `agent.context.historyWindowSize` | 10 | Số message lịch sử giữ lại |
| `agent.context.toolSearchLimit` | 6 | Số tool tối đa trả về khi tìm |
| `agent.context.historyMaxTokens` | 40000 | Trần token cho lịch sử |
| `agent.context.toolMaxTokens` | 24000 | Trần token cho kết quả tool |
| `agent.context.storedToolResultTtlMinutes` | 60 | TTL cache kết quả tool |

**Probe khác 5 service còn lại** — đây là chi tiết rất đáng nêu:

| Probe | Path |
|---|---|
| startup | `/actuator/health/liveness` |
| readiness | `/actuator/health/readiness` |
| liveness | `/actuator/health/liveness` |

Lý do: `/actuator/health` gốc **có chạy health indicator `db`**, mà Neon (serverless)
khi bị suspend cần ~14s để wake up. Với timeout 1s mặc định, probe fail 3 lần liên
tiếp ⇒ kubelet SIGTERM pod ⇒ vòng lặp restart. Hai group `liveness`/`readiness`
chỉ trả lời trạng thái nội bộ trong vài ms và **không chạm DB**.

---

## 5. Bảng tổng hợp: biến môi trường nào đến từ đâu

| Nguồn | Cách khai | Ví dụ | Đổi có cần restart? |
|---|---|---|---|
| `values-stg.yaml` → literal trong template | `value: {{ .Values.x \| quote }}` | `SPRING_PROFILES_ACTIVE`, `REGION`, `COURSE_SERVICE_URI` | Có (pod template đổi ⇒ rollout) |
| Secret (bắt buộc) | `valueFrom.secretKeyRef` (không `optional`) | `DB_PASSWORD`, `GATEWAY_TRUSTED_SECRET` | Có — **Secret đổi không tự restart** |
| Secret (tuỳ chọn) | `secretKeyRef` + `optional: true` | `APP_LOG_LEVEL`, `KAFKA_*`, `RUSTFS_*`, `AI_*` | Có; thiếu key ⇒ biến không tồn tại, app dùng default |
| File trong Secret | volume + `items` | `ca.pem` → `/etc/kafka/secrets/ca.pem` | Có (volume mount) |
| Cố định trong template | `value: "..."` | `DOCKER_HOST`, `RUSTFS_BUCKET_NAME`, `TESTCONTAINERS_RYUK_DISABLED` | Sửa template |

Bảng "sai thì hỏng thế nào" (rất hữu ích khi bảo vệ đồ án):

| Biến sai/thiếu | Triệu chứng thực tế |
|---|---|
| `DB_HOST`/`DB_PORT` sai | Pod **Ready nhưng mọi API 500**; startup vẫn qua vì Hikari lazy-init |
| `DB_PASSWORD` sai | `/actuator/health` = DOWN (`db` indicator), readiness fail ⇒ pod không nhận traffic |
| `GATEWAY_TRUSTED_SECRET` lệch giữa gateway và service | Mọi request có auth trả **401**, dù token hợp lệ |
| `KEYCLOAK_ISSUER_URI` sai | Gateway verify JWT fail ⇒ 401 ở mọi endpoint bảo vệ |
| `RUSTFS_PUBLIC_ENDPOINT` sai | Presigned URL trỏ sai host ⇒ FE upload **lỗi mạng/CORS**, backend không thấy log |
| `KAFKA_*` sai | Submission vẫn nhận bài nhưng event không tới executor ⇒ bài **mãi ở PENDING** |
| `AI_API_KEY` rỗng | Không lỗi: service trả lời bằng template fallback |
| `service.port` đổi mà không đổi Ingress | 503 từ Traefik |

---

## 6. Ba câu hỏi lý thuyết hay gặp về chart này

**"Vì sao `pullPolicy: Always` dù tag là semver?"**
Tag `v1.0.x` là duy nhất, nhưng `Always` đảm bảo node không dùng bản cache cũ khi
tag bị push lại (đã từng xảy ra khi rebuild). Cái giá: mỗi pod start phải kiểm tra
registry (vài trăm ms tới vài giây) và cần Internet.

**"Vì sao không dùng `ConfigMap` cho cấu hình thay vì env?"**
Cấu hình ở đây phần lớn là *định danh hạ tầng* (URL service, port, profile) — phù
hợp env. Phần nhạy cảm buộc phải là Secret. `application.yaml` trong image vẫn giữ
default; env chỉ override. Mount ConfigMap sẽ cần thêm volume + restart vẫn phải
làm, không lợi hơn.

**"Vì sao mỗi service một chart thay vì một chart umbrella?"**
Sáu chart độc lập cho phép: (a) ArgoCD sync riêng từng service (một service lỗi
không chặn service khác), (b) CI chỉ sửa 1 file values, (c) rollback độc lập.
Umbrella chart sẽ khiến một lần bump tag của course-service kéo theo sync toàn bộ.
