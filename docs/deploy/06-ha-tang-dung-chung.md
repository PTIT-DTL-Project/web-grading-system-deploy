# 06 — Hạ tầng dùng chung: PostgreSQL, Keycloak, RustFS, Kafka, Observability

> "Dùng chung" = không thuộc nghiệp vụ nào nhưng mọi service phụ thuộc. Phần này
> giải thích **từng biến cấu hình** của 4 nhóm hạ tầng và **vì sao** chọn giá trị
> đó, kèm các bẫy đã gặp thật.

---

## 1. PostgreSQL (Neon — managed, ngoài cụm)

### 1.1 Cách nối

Cả 6 service đọc **cùng một** Secret `db-secret` (4 key), nhưng **khác `DB_NAME`**
(chart quy định):

```
DB_HOST, DB_PORT, DB_USERNAME, DB_PASSWORD   ← Secret db-secret  (dùng chung)
DB_NAME = assignment_db | submission_db | executor_db | result_db | ai_db
```

| Service | `DB_NAME` |
|---|---|
| course-service | `assignment_db` |
| submission-service | `submission_db` |
| executor-service | `executor_db` |
| result-service | `result_db` |
| ai-assistant-service | `ai_db` |
| api-gateway | — (không dùng) |

Keycloak dùng Secret **riêng** `keycloak-db` với `KEYCLOAK_DB_URL` (JDBC URL đầy
đủ, thường là database `keycloak` riêng) — tách khỏi `db-secret` vì Keycloak không
phải service Spring của đồ án.

### 1.2 Vì sao dùng Neon (serverless Postgres)

| Ưu | Nhược (đã gặp thật) |
|---|---|
| Không phải chạy StatefulSet Postgres trên node 8 GB (tiết kiệm ~300–500 MB + PVC) | Compute **tự suspend** khi rỗi; request đầu tiên phải chờ ~10–15s để wake up |
| Backup, PITR, TLS do nhà cung cấp lo | Phụ thuộc Internet: mất mạng ⇒ mọi API 500 |
| Năm database tách biệt dễ tạo/xoá | Trần connection theo gói ⇒ pool phải nhỏ |

**Hệ quả thiết kế quan trọng:** vì Neon wake-up chậm, readiness probe của
ai-assistant-service trỏ `/actuator/health/readiness` (không chạm DB) thay vì
`/actuator/health` (có indicator `db`). Với timeout 1s mặc định, probe DB sẽ fail
3 lần liên tiếp và kubelet restart pod — đã xảy ra ngày 2026-10-17.

### 1.3 Kiểm tra kết nối

```bash
kubectl -n web-grading get secret db-secret -o jsonpath='{.data.DB_HOST}' | base64 -d; echo
kubectl -n web-grading logs deploy/grading-course-service | grep -i hikari | head
```

Lưu ý: `DB_HOST` sai ⇒ pod vẫn **Ready** (Hikari khởi tạo lazy) nhưng mọi API 500;
`DB_PASSWORD` sai ⇒ `/actuator/health` = DOWN ⇒ readiness fail ⇒ pod không nhận
traffic. Hai kiểu hỏng khác nhau, dễ chẩn đoán nhầm.

---

## 2. Keycloak — OIDC provider

### 2.1 Cấu hình từng biến

| Env | Giá trị | Vai trò / vì sao |
|---|---|---|
| `KC_DB` | `postgres` | Dùng Postgres (Neon), không dùng H2 mặc định |
| `KC_DB_URL` | từ Secret `keycloak-db` | JDBC URL đầy đủ (đã gồm host/port/db) |
| `KC_DB_USERNAME` / `KC_DB_PASSWORD` | từ Secret `keycloak-db` | Credential DB |
| `KC_BOOTSTRAP_ADMIN_USERNAME` / `..._PASSWORD` | từ Secret, `optional: true` | Chỉ dùng ở **lần khởi động đầu** để tạo admin; các lần sau bị bỏ qua |
| `KC_HTTP_PORT` | `8080` | Cổng HTTP trong container (khớp Service/Ingress) |
| `KC_HTTP_ENABLED` | `true` | Cho phép HTTP (TLS do Cloudflare) |
| `KC_HOSTNAME_STRICT` | `true` | Không cho Host header tùy ý quyết định URL sinh ra |
| `KC_HOSTNAME` | `https://web-dev1-keycloak.vucongtuanduong.dpdns.org` | **Issuer** trong token = `<KC_HOSTNAME>/realms/ptit-wgs`. Phải khớp `KEYCLOAK_ISSUER_URI` của gateway |
| `KC_HOSTNAME_ADMIN` | như trên | Host cho Admin Console (dùng khi cần tách host admin) |
| `KC_PROXY` | `edge` | Tin `X-Forwarded-*` từ proxy (Cloudflare/Traefik) ⇒ redirect và URL tuyệt đối đúng scheme `https` |
| `JAVA_OPTS_APPEND` | `-XX:MaxRAMPercentage=60 -XX:InitialRAMPercentage=20 -Xss512k` | Ép heap theo **limit container** (768Mi ⇒ heap ~460Mi), không theo RAM node; `-Xss512k` giảm stack mỗi thread HTTP |
| `KC_METRICS_ENABLED` | `false` | Không scrape Keycloak ⇒ tắt endpoint Micrometer cho gọn |

### 2.2 Vì sao `args: [start-dev]` và điều cần nói thêm

`start-dev` bật chế độ dev: khởi động nhanh, không cần cấu hình cache/cluster, log
cảnh báo rõ "not for production". Với staging 1 node, đây là lựa chọn hợp lý; nếu
lên production phải chuyển sang `start` + `KC_CACHE=ispn` + TLS nội bộ + backup DB.

### 2.3 Realm và client (phần hay bị hỏi)

| Client | Loại | Dùng cho |
|---|---|---|
| `web-grading-fe` | Public, PKCE, **Direct Access Grants OFF** | Trình duyệt (FE React) |
| `wgs-postman` | Public/confidential tuỳ cấu hình, password grant ON | Test API bằng Postman (lấy token bằng password grant) |
| `wgs-user-service` | Confidential, service account có quyền `manage-users` | Gateway gọi Admin API (tìm user, reset password) |
| `wgs-password-verify` | Confidential, password grant ON | Gateway **xác minh mật khẩu hiện tại** khi user đổi mật khẩu |

Vì `web-grading-fe` tắt Direct Access Grants (Phase 3), gateway không thể dùng nó
để verify password ⇒ cần client riêng `wgs-password-verify`. Đây là lý do tồn tại
cặp biến `KEYCLOAK_PASSWORD_CLIENT_ID/SECRET`.

Gateway **không** kiểm tra `azp`/client_id, chỉ verify chữ ký + `iss`, nên token
từ `wgs-postman` đi qua gateway y như token từ FE.

### 2.4 Tài nguyên và vì sao

| Thông số | Giá trị | Lý do |
|---|---|---|
| requests | 100m / 384Mi | Đủ cho 1 realm nhỏ, khởi động nhanh |
| limits | 500m / 768Mi | Có trần để kubelet có căn cứ evict; heap ~460Mi |
| replicas | 1 | Không HA (1 node); `start-dev` cũng không hỗ trợ cluster |

---

## 3. RustFS — object storage S3-compatible

### 3.1 Từng biến

| Env | Giá trị | Vai trò |
|---|---|---|
| `RUSTFS_ROOT_USER` / `RUSTFS_ROOT_PASSWORD` | từ Secret `rustfs-secret` (`RUSTFS_ACCESS_KEY`/`RUSTFS_SECRET_KEY`) | Credential root; **cùng** Secret mà client đọc ⇒ server/client không lệch |
| `args` | `server /data --console-address :9001` | Chạy chế độ server, dữ liệu ở `/data` (PVC), console ở 9001 |
| `RUSTFS_NOTIFY_ENABLE` | `on` | Bật hệ thống event |
| `RUSTFS_NOTIFY_WEBHOOK_ENABLE_PRIMARY` | `on` | Bật webhook "primary" |
| `RUSTFS_NOTIFY_WEBHOOK_ENDPOINT_PRIMARY` | `http://grading-submission-service:8082/api/v1/submissions/webhook/upload-complete` | Khi object upload xong, gọi submission-service |
| `RUSTFS_NOTIFY_WEBHOOK_QUEUE_DIR_PRIMARY` | `/tmp/rustfs-events` | Nơi xếp hàng event khi webhook lỗi (retry) |
| `RUSTFS_OUTBOUND_ALLOW_ORIGINS` | `http://grading-submission-service:8082` | Cho phép RustFS gọi ra đúng origin đó |
| `RUSTFS_CORS_ALLOWED_ORIGINS` | 3 origin (localhost:5173, FE staging, localhost:5174) | Cho browser PUT presigned URL (xem [05](05-ingress-va-cloudflare.md) §6) |
| `image` | `rustfs/rustfs:1.0.5` + `IfNotPresent` | Ghim phiên bản: `latest` + `IfNotPresent` khiến mỗi node giữ bản build đầu tiên ⇒ phiên bản không xác định |
| resources | req 50m/128Mi, lim 500m/512Mi | Rust/tokio không có heap JVM; trần để upload lớn không ăn RAM của pod Java |

### 3.2 Vòng đời một file upload

```
1. FE  → gateway → submission-service: POST /api/v1/submissions/presign
2. submission-service: build objectName = "submissions/<submissionId>.zip"
                       ký presigned PUT bằng SDK (endpoint nội bộ, host public)
3. FE  → PUT https://web-dev1-rustfs-api.../<bucket>/submissions/<id>.zip
4. RustFS lưu file vào PVC, phát webhook tới submission-service
5. submission-service: xác thực, cập nhật DB, publish Kafka `wgs-events-deploy`
6. executor tiêu thụ event → chấm bài
```

Chi tiết dễ sai: `buildObjectName` trả `"submissions/" + submissionId + ".zip"`
(không phải thư mục con ngẫu nhiên) ⇒ nếu đổi quy ước này phải đổi cả nơi đọc.

### 3.3 PVC và dữ liệu

`rustfs-pvc`: 10Gi, `ReadWriteOnce`, storage class mặc định `local-path` ⇒ dữ liệu
nằm trên đĩa node, **không** nhân bản. Mất node = mất file bài nộp (DB vẫn còn
metadata). Đây là lý do phần "Hướng phát triển" của báo cáo có mục backup.

---

## 4. Kafka (Aiven) + Kafka UI

### 4.1 Kafka managed

| Thông số | Giá trị | Ghi chú |
|---|---|---|
| Bootstrap | Secret `kafka-aiven-credentials/bootstrap-servers` | Host:port của Aiven |
| Bảo mật | `SASL_SSL` + `SCRAM-SHA-256` | Cả 6 biến liên quan nằm trong Secret (username/password/ca.pem) |
| CA | `/etc/kafka/secrets/ca.pem` (volume từ Secret) | Aiven dùng CA riêng ⇒ phải mount, không dùng CA hệ thống |
| Topic | `wgs-events-deploy` | Khai trong values (`wgs.events.topic`) ⇒ submission dùng để **publish**, executor để **subscribe** |
| Ai dùng | submission-service (producer), executor-service (consumer) | |

Cấu hình Kafka trong pod (chart):

```yaml
env:
  - name: KAFKA_BOOTSTRAP_SERVERS   # secretKeyRef, optional
  - name: KAFKA_USERNAME            # secretKeyRef, optional
  - name: KAFKA_PASSWORD            # secretKeyRef, optional
  - name: KAFKA_CA_PATH             # /etc/kafka/secrets/ca.pem
volumeMounts:
  - name: kafka-ca                  # secret kafka-aiven-credentials, item ca.pem
    mountPath: /etc/kafka/secrets
```

`optional: true` ở 3 biến credential là có chủ đích: service vẫn khởi động được
khi chưa cấu hình Kafka (dùng cho môi trường chỉ test API read). Nhưng khi đó
**upload thành công mà không có event** ⇒ bài nằm mãi `PENDING`.

### 4.2 Kafka UI (chỉ để quan sát)

| Env | Vai trò |
|---|---|
| `KAFKA_CLUSTERS_0_NAME` = `aiven-grading` | Tên hiển thị |
| `KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS` | từ Secret |
| `KAFKA_CLUSTERS_0_PROPERTIES_SECURITY_PROTOCOL` = `SASL_SSL` | |
| `KAFKA_CLUSTERS_0_PROPERTIES_SASL_MECHANISM` = `SCRAM-SHA-256` | |
| `KAFKA_CLUSTERS_0_PROPERTIES_SASL_JAAS_CONFIG` | `ScramLoginModule required username="$(username)" password="$(password)";` — biến `${username}`/`${password}` được `envFrom` bơm vào |
| `SSL_TRUSTSTORE_TYPE` = `PEM`, `SSL_TRUSTSTORE_LOCATION` = `/etc/kafka/secrets/ca.pem` | Truststore PEM |
| `dnsPolicy: None`, nameserver `8.8.8.8`, search `aivencloud.com` | Phân giải tên broker Aiven mà không phụ thuộc DNS cụm |
| resources | req 128Mi (hạ từ 256Mi vì request giữ chỗ vô ích), lim 512Mi |
| readiness | `/actuator/health`, initialDelay 20s |

Kafka UI **không** thuộc đường chạy nghiệp vụ: tắt bằng
`kubectl -n web-grading scale deploy/kafka-ui --replicas=0` khi không cần.

---

## 5. Observability "Lite": Prometheus + Grafana + Tempo

### 5.1 Kiến trúc (không có collector trung gian)

```
service (6 pod) ──pull /actuator/prometheus (30s)──► Prometheus ──query──► Grafana
service (6 pod) ──push OTLP/HTTP :4318────────────► Tempo      ──query──► Grafana
Tempo ──remote_write span metrics / service graph──► Prometheus
```

Không có OTel Collector, không Loki, không Mimir, không Alloy, không Pyroscope,
không Alertmanager, không node-exporter, không kube-state-metrics. Đây là quyết
định vì RAM, được ghi rõ trong `deploy/observability/README.md` ("Do not re-add
them on the 8 GB box").

### 5.2 Prometheus — tham số và ý nghĩa

| Key | Giá trị | Vì sao |
|---|---|---|
| `prometheus.prometheusSpec.retention` | `3d` | 3 ngày đủ để xem lại một buổi demo/kiểm thử |
| `retentionSize` | `1500MB` | Chặn cứng **trước** khi PVC 2Gi đầy (Prometheus còn giữ head chunks) |
| `size` / `storageClassName` | `2Gi` / `local-path` | PVC trên đĩa node |
| `enableRemoteWriteReceiver` | `true` | Để Tempo `remote_write` được metrics vào |
| `scrape_interval` (trong `additionalScrapeConfigs`) | `30s` | Đủ mịn cho dashboard, giảm write amplification |
| `kubernetes_sd_configs.role: pod`, namespace `web-grading` | | Tự phát hiện pod, không cần khai từng Service |
| relabel: `app` ∈ 6 tên service | | Loại Keycloak/RustFS/Kafka UI khỏi scrape |
| relabel: `pod_phase=Running`, `pod_ready=true` | | Không scrape pod đang chết |
| relabel: `container_port ∈ 8080..8084, 8086` | | **Loại sidecar dind (2375)** khỏi scrape |
| **không** dùng `bearer_token_file` | | Token ServiceAccount gắn vào request làm gateway trả 401 trước `permitAll()` ⇒ metric gateway "tối" |
| `kubelet.serviceMonitor.interval` / `cAdvisorInterval` | `30s` / `30s` | cAdvisor mặc định 10s là lãng phí trên 1 node |
| `kubeControllerManager/kubeScheduler/kubeProxy/kubeEtcd.enabled` | `false` | k3s chạy chúng trong 1 process ⇒ nếu bật sẽ có target luôn DOWN |
| `nodeExporter.enabled` / `kubeStateMetrics.enabled` | `false` | **camelCase** mới là công tắc thật trên chart 72.x; dạng kebab-case bị bỏ qua im lặng (đã từng làm pod vẫn deploy) |
| `alertmanager.enabled` | `false` | Không có ai trực on-call |
| `defaultRules.create` | `false` | Không tạo bộ rule mặc định (tránh alert vô chủ) |
| resources | req 100m/256Mi, lim 500m/768Mi | |

### 5.3 Grafana — 3 quyết định đáng nói

1. **Tắt sidecar** (`sidecar.dashboards.enabled: false`,
   `sidecar.datasources.enabled: false`) và **mount trực tiếp** ConfigMap
   datasource vào `/etc/grafana/provisioning/datasources/datasource.yaml`
   (`extraConfigmapMounts` + `forceDeployDatasources: true`).
   *Vì sao:* sidecar ghi file **sau** khi Grafana đã đọc thư mục ⇒ lần cài mới có
   thể lên với danh sách datasource rỗng; sidecar còn cần thêm image từ quay.io và
   RBAC watch ConfigMap.
   *Cái giá:* mount dùng `subPath` nên sửa `additionalDataSources` phải
   `kubectl -n observability rollout restart deploy/monitoring-grafana`.
2. **Khai báo tường minh 2 datasource** (`Prometheus` uid `prometheus` isDefault,
   `Tempo` uid `tempo`) và tắt provisioning mặc định
   (`defaultDatasourceEnabled: false`). *Vì sao:* provisioning mặc định luôn thêm
   datasource Alertmanager, mà Alertmanager không tồn tại ⇒ Grafana hiện một
   datasource chết.
3. **`grafana.ini` phải là host thật** — Helm **không** expand `${...}` trong
   values file, nên giá trị kiểu `"${GRAFANA_DOMAIN:-...}"` sẽ thành domain rác và
   làm hỏng redirect. Hiện tại: `domain` + `root_url` = host public.

Datasource Tempo cần thêm:

| Key | Giá trị | Vì sao |
|---|---|---|
| `jsonData.tracesToMetrics.datasourceUid` | `prometheus` | Nút "View related metrics" trong trace view |
| `jsonData.streamingEnabled.search` | `true` | TraceQL search dùng gRPC trên port 3200 |
| `jsonData.streamingEnabled.metrics` | `false` | Giảm tải; `\| rate()` vẫn chạy qua `query_range` |

### 5.4 Tempo — tham số và bẫy

| Key | Giá trị | Vì sao |
|---|---|---|
| `tempo.memBallastSizeMbs` | `0` | Tempo 2.x mặc định ballast **1 GiB** ⇒ gấp đôi limit container ⇒ OOMKill liên tục |
| `tempo.extraEnv GOMEMLIMIT` | `800MiB` | Giữ heap Go dưới limit 1Gi (local-blocks cần RAM cho trace buffer) |
| `tempo.retention` | `24h` | Đủ cho debug một ngày |
| `tempo.streamOverHttpEnabled` | `true` | **Bắt buộc**: thiếu cờ này Tempo trả HTTP/1.1 trên 3200 và Grafana báo `http2: frame too large ... looked like an HTTP/1.1 header` |
| `metricsGenerator.enabled` | `true` | Sinh `traces_spanmetrics_*` + service graph ⇒ nguồn cho ô "Span rate" của Traces Drilldown |
| `metricsGenerator.remoteWriteUrl` | `http://monitoring-kube-prometheus-prometheus.observability...:9090/api/v1/write` | Đẩy metric sang Prometheus |
| `metricsGenerator.storage.path` | `/var/tempo/generator/wal` | **Không** dùng `/var/tempo/wal` (WAL của trace storage) — dùng chung sẽ hỏng cả hai |
| `metricsGenerator.processor.local_blocks.flush_to_storage` | `true` | Query được cửa sổ > 1h và không mất dữ liệu khi pod restart |
| `tempo.overrides.defaults.metrics_generator.processors` | `service-graphs`, `span-metrics`, `local-blocks` | Thiếu block này Tempo vẫn chạy generator nhưng **không sinh metric nào** ⇒ "Span rate: No data" |
| probe `liveness/readiness` | `/ready` port **3200** | 3200 là HTTP API; chart mặc định đã đúng, khai tường minh để không bị đổi âm thầm |
| resources | req 100m/256Mi, lim 500m/1Gi | local-blocks giữ trace trong RAM trước khi cắt block |

**Nguyên tắc số 1 khi sửa chart Tempo:** không override `config:` ở cấp gốc. Chart
render `tempo.yaml` từ các khoá dưới `tempo.*`; đặt `config: |` ở gốc sẽ **bỏ qua
im lặng** toàn bộ nhánh `tempo.*` (probe, service, metricsGenerator…).

### 5.5 Phía ứng dụng: cần gì để có metric/trace

`deploy/observability/templates/application-observability.yaml` là mẫu merge vào
`application.yaml` của mỗi service:

| Key | Giá trị | Vai trò |
|---|---|---|
| `management.endpoints.web.exposure.include` | `health,info,prometheus` | Mở endpoint để Prometheus pull |
| `management.tracing.sampling.probability` | `${OTEL_TRACES_SAMPLING_PROBABILITY:1.0}` | 1.0 = 100% (staging); production nên 0.1–0.3 |
| `management.tracing.export.enabled` | `true` | Bật export trace |
| `management.opentelemetry.tracing.export.otlp.endpoint` | `http://tempo.observability.svc.cluster.local:4318/v1/traces` | Đích OTLP |
| `management.otlp.metrics.export.enabled` | `false` | Prometheus **pull** rồi; bật OTLP metrics sẽ đẩy sang Tempo (không nhận metrics) mỗi 60s |
| `logging.pattern.level` | `%5p [service,%X{traceId:-},%X{spanId:-}]` | In traceId/spanId ra log — **camelCase**, vì micrometer-tracing-bridge-otel đặt MDC key là `traceId` (không phải `trace_id`) |

### 5.6 Ngân sách RAM của stack

| Thành phần | RAM request | RAM limit |
|---|---|---|
| Prometheus | 256Mi | 768Mi |
| Grafana | 384Mi | 768Mi |
| Tempo | 256Mi | 1Gi |
| prometheus-operator | 64Mi | 256Mi |
| **Tổng** | **960Mi** | **~2,8Gi** |

---

## 6. Thứ tự phụ thuộc khi dựng cụm (và vì sao)

```
1. namespace + Secret        ← mọi pod cần Secret trước khi start
2. PostgreSQL (Neon)         ← ngoài cụm, chỉ cần tồn tại + đúng credential
3. Keycloak                  ← service verify JWT cần issuer sống (không cần lúc boot)
4. RustFS                    ← submission cần endpoint + credential (không cần lúc boot)
5. Kafka (Aiven)             ← producer/consumer cần bootstrap + CA
6. 6 microservice (ArgoCD)   ← phụ thuộc 1..5
7. Ingress                   ← có thể trước hoặc sau, chỉ route
8. Observability             ← sau cùng, chỉ quan sát
```

Vì sao thứ tự này "mềm": hầu hết phụ thuộc là **runtime**, không phải **boot**.
Service vẫn khởi động khi Keycloak/RustFS/Kafka chưa sẵn sàng; lỗi xuất hiện ở
request đầu tiên. Đó là lý do phải có checklist kiểm tra sau deploy
([08](08-van-hanh-va-xu-ly-su-co.md)) chứ không chỉ nhìn "pod Running".

---

## 7. Trạng thái dữ liệu và backup

| Thành phần | Stateful? | Nơi lưu | Backup hiện tại |
|---|---|---|---|
| PostgreSQL (Neon) | Có | Managed | Neon PITR (do nhà cung cấp) |
| RustFS | Có | PVC `rustfs-pvc` 10Gi (`local-path`) | **Chưa có** — nằm trong Hướng phát triển |
| Prometheus | Có | PVC 2Gi | Không cần (metric 3 ngày) |
| Tempo | Có | PVC 2Gi | Không cần (trace 24h) |
| Grafana | Có | PVC 2Gi (dashboard do người dùng tạo) | Nên export JSON dashboard vào Git |
| Kafka (Aiven) | Managed | Aiven | Theo gói Aiven |
| Keycloak | Stateless (DB ở Neon) | `keycloak` DB | Theo Neon |

Câu trả lời mẫu khi bị hỏi "mất node thì sao": mất **file ZIP bài nộp** và
dashboard Grafana cục bộ; dữ liệu nghiệp vụ (điểm, bài tập, user) vẫn còn vì nằm
ở Neon. Đây là ranh giới stateful/stateless được thiết kế có chủ đích.
