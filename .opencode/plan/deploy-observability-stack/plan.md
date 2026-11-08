# Observability Lite — sự cố node quá tải: lỗi, nguyên nhân, cách sửa

> Ghi: 2026-11-08. Phạm vi: `deploy/observability/**`, `src-services/*/src/main/resources/application.yaml`,
> 5 `pom.xml`, 5 `Dockerfile`, `src-services/ai-assistant-service/src/main/resources/logback-spring.xml`,
> `docs/observability/README.md`, `deploy/observability/README.md`, `README.md`, skill `observability-stack`
> (`.opencode/` + `.kilo/`).
>
> Trạng thái: **config đã sửa + đã render/parse kiểm chứng offline**. Chưa có số đo runtime vì cluster
> `127.0.0.1:6443` connection refused tại thời điểm kiểm chứng.

---

## 0. Kết luận ngắn

Node quá tải **không** phải vì "observability nặng". Có 4 lỗi cấu hình khiến tài nguyên bị cấp sai
(Tempo unbounded + ballast 1 GiB) và 2 luồng telemetry chạy sai hướng (Prometheus scrape bị 401,
OTLP metrics push vào chỗ không ai nhận). Stack Lite (Prometheus + Grafana + Tempo) **vẫn phù hợp**
với box 8 GB sau khi sửa — không cần bỏ thành phần nào.

| # | Lỗi | File | Mức độ |
|---|---|---|---|
| a | Tempo không có requests/limits + ballast mặc định 1 GiB | `deploy/observability/charts/tempo-values.yaml` | Trực tiếp gây OOMKill |
| b | Prometheus gắn SA token vào scrape target → gateway trả 401 | `charts/kube-prometheus-stack-values.yaml` | Metrics gateway mất |
| c | Property tracing Boot 4.1 sai + OTLP metrics bật mặc định | `templates/application-observability.yaml` + 6 `application.yaml` | Retry storm + log không nối trace |
| d | Grafana lệch `domain` / `root_url` / `serve_from_sub_path` + key sai tên | `charts/kube-prometheus-stack-values.yaml` | Redirect loop qua ingress |
| e | Backend `web-grading` không resolve `tempo.observability.svc.cluster.local` | `charts/tempo-values.yaml` | Trace không lên, log đầy `UnknownHostException` |
| f | Tempo OTLP receivers bind `localhost` (không phải `0.0.0.0`) | `charts/tempo-values.yaml` | Connection refused từ backend, zero traces ingested |
| g | Tempo HTTP server listen port 3100 (không phải 3200) | `charts/tempo-values.yaml` | Grafana i/o timeout, không query được traces |

---

## 1. Triệu chứng quan sát được

- Node vào trạng thái pressure, pod bị `Evicted`/`OOMKilled`; Tempo là pod chết đầu tiên.
- `kubectl -n observability get pod` cho thấy Tempo restart liên tục, không có `resources` trong spec.
- Prometheus target `backend-services` có `api-gateway` ở trạng thái DOWN, lỗi `401`.
- Log 6 service backend lặp lại lỗi export OTLP metrics tới `http://localhost:4318/v1/metrics`.
- Log có `[,,]` ở phần MDC → trace không nối được với log.
- Truy cập Grafana qua ingress bị redirect loop (`ERR_TOO_MANY_REDIRECTS`).

---

## 2. Nguyên nhân gốc và cách sửa

### 2.a — Tempo không có giới hạn bộ nhớ, lại alloc thêm 1 GiB ballast

**Lỗi (trước):**

```yaml
# tempo-values.yaml (bản cũ)
image:                      # ← top-level
  repository: grafana/tempo
  tag: 2.7.1
resources:                  # ← top-level
  requests: { memory: 256Mi }
  limits:   { memory: 512Mi }
```

**Nguyên nhân:** chart `grafana/tempo` 1.21.1 đọc `image` và `resources` dưới nhánh **`tempo.*`**.
Key top-level bị bỏ qua **im lặng** — Helm không báo lỗi, không có warning. Kết quả: pod Tempo chạy
**không requests/limits**, scheduler xếp nó như workload best-effort. Cộng thêm `memBallastSizeMbs`
mặc định **1024 MB** của Tempo 2.x → container alloc 1 GiB ngay khi start, gấp đôi "limit" tưởng tượng
ở trên → `OOMKilled`, node memory pressure, eviction dây chuyền.

Đây là **nguyên nhân trực tiếp** của sự cố, và là lý do "thêm 1 GiB nữa là đủ đẩy node qua ngưỡng".

**Cách sửa (sau):**

```yaml
tempo:
  repository: grafana/tempo
  tag: 2.7.1
  pullPolicy: IfNotPresent
  memBallastSizeMbs: 0                 # bỏ ballast 1 GiB
  extraEnv:
    - name: GOMEMLIMIT
      value: 400MiB                     # GC sớm, chừa headroom so với limit 512Mi
  reportingEnabled: false
  retention: 24h
  metricsGenerator:
    enabled: false                      # không có remote-write target, chỉ tốn CPU/RAM
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 512Mi }

persistence:
  enabled: true
  storageClassName: local-path
  size: 2Gi

serviceMonitor:
  enabled: false                        # Prometheus đã scrape service; self-metrics Tempo không cần
```

**Cách phát hiện / verify:** `helm template tempo grafana/tempo -f charts/tempo-values.yaml` phải ra
`-mem-ballast-size-mbs=0`, `GOMEMLIMIT=400MiB`, `image: grafana/tempo:2.7.1` và `resources` nằm trong
container spec. Nếu render ra pod không có `resources` → key vẫn sai nhánh.

**Bài học:** với Helm chart, **không tin key đã đúng** — luôn `helm template` rồi grep vào spec container.
Key sai nhánh không gây lỗi, chỉ gây "config tàng hình".

---

### 2.b — Prometheus gửi ServiceAccount token tới backend → gateway trả 401

**Lỗi (trước):** `additionalScrapeConfigs` có

```yaml
bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
tls_config:
  ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  insecure_skip_verify: true
honor_labels: true
```

**Nguyên nhân:** `bearer_token_file` / `tls_config` trong scrape config áp lên **target được scrape**
(các service backend), **không** áp lên Kubernetes service discovery. Prometheus dùng chính SA token của
nó để gọi API server (việc đó Pod-SD tự làm), nhưng ở đây token bị đính vào request
`GET :8080/actuator/prometheus`.

`api-gateway` là **reactive resource server** → filter security chạy **trước** `permitAll()`, thấy
`Authorization: Bearer <token lạ>` liền trả **401**. `permitAll()` trên `/actuator/prometheus`
không bao giờ được xét tới. Hệ quả: series của gateway không lên Prometheus — mất đúng service
quan trọng nhất.

**Cách sửa (sau):** bỏ hẳn 3 key trên, siết lại relabel để chỉ scrape đúng thứ cần:

```yaml
additionalScrapeConfigs: |
  - job_name: "backend-services"
    metrics_path: "/actuator/prometheus"
    scheme: http
    scrape_interval: 30s
    kubernetes_sd_configs:
      - role: pod
        namespaces: { names: [web-grading] }
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        regex: "api-gateway|course-service|executor-service|result-service|submission-service|ai-assistant-service"
        action: keep
      - source_labels: [__meta_kubernetes_pod_phase]
        regex: Running
        action: keep
      - source_labels: [__meta_kubernetes_pod_ready]
        regex: "true"
        action: keep
      - source_labels: [__meta_kubernetes_pod_container_port_number]
        regex: "8080|8081|8082|8083|8084|8086"
        action: keep
      - { source_labels: [__meta_kubernetes_namespace], target_label: namespace }
      - { source_labels: [__meta_kubernetes_pod_name], target_label: pod }
      - { source_labels: [__meta_kubernetes_pod_label_app], target_label: service }
```

**Vì sao thêm filter port:** sidecar `dind` của executor mở `2375`; nếu không lọc port, Prometheus sẽ cố
scrape Docker daemon và tạo target down vĩnh viễn.

**Verify:** Prometheus → Status → Targets, job `backend-services` phải có đủ 6 service, tất cả `UP`,
và `curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[].health'` không còn `"down"`.

---

### 2.c — Property tracing của Spring Boot 4.1 sai + OTLP metrics bật mặc định

Có ba lỗi con trong cùng một chùm.

**(c1) Property bị deprecate ở mức `error`.**

| Cũ (sai) | Mới (đúng, Boot 4.1) |
|---|---|
| `management.tracing.enabled` | `management.tracing.export.enabled` |
| `management.otlp.tracing.endpoint` | `management.opentelemetry.tracing.export.otlp.endpoint` |
| `management.otlp.metrics.export.enabled` | **giữ nguyên** (Boot 4.1 vẫn dùng tên này, default `true`) |

Boot 4.1 nâng mức deprecate của các key cũ lên **error**, nên service có thể fail-fast khi start
(hoặc bỏ qua cấu hình tracing) tuỳ đường đi. Không được để lại key cũ ở bất kỳ file nào.

**(c2) OTLP metrics export bật mặc định.** Boot 4.1 tự bật export metrics qua OTLP, trỏ
`http://localhost:4318/v1/metrics`. Stack Lite **chỉ pull** bằng Prometheus, không có collector trong
pod → 6 service retry export thất bại mỗi 60 giây, log đầy lỗi, tốn CPU vô ích. Phải tắt tường minh:

```yaml
management:
  otlp:
    metrics:
      export:
        enabled: false
```

**(c3) MDC key sai.** Log pattern dùng `%X{trace_id}` / `%X{span_id}`, nhưng Micrometer Tracing đặt
`traceId` / `spanId` (camelCase). Kết quả log in ra `[,,]` — **trace không nối được với log**, mất luôn
giá trị của việc có trace. Sửa ở **tất cả** nơi có pattern: 6 `application.yaml` + `logback-spring.xml`
của `ai-assistant-service`.

**Cấu hình chuẩn sau khi sửa (mỗi service):**

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
  tracing:
    sampling:
      probability: ${OTEL_TRACES_SAMPLING_PROBABILITY:1.0}
    export:
      enabled: true
  opentelemetry:
    tracing:
      export:
        otlp:
          endpoint: ${OTLP_TRACES_ENDPOINT:http://tempo.observability.svc.cluster.local:4318/v1/traces}
  otlp:
    metrics:
      export:
        enabled: false

logging:
  pattern:
    level: "%5p [${spring.application.name:},%X{traceId:-},%X{spanId:-}]"
  level:
    io.micrometer.tracing: INFO
```

`io.micrometer.tracing: INFO` để chặn log DEBUG của chính instrumentation (nếu không, mỗi span sinh vài
dòng log vô nghĩa).

**Sampling:** mặc định `1.0` cho dev; staging/prod đặt `OTEL_TRACES_SAMPLING_PROBABILITY=0.1–0.2`
qua env, không sửa file.

**Verify:** log phải có `[api-gateway,6f3c... ,9a1b...]` (không rỗng); Tempo → Search theo
`service.name` thấy trace; không còn dòng `Failed to export metrics` trong log service.

---

### 2.d — Grafana lệch host config, gây redirect loop qua ingress

**Lỗi (trước):**

```yaml
grafana:
  grafana.ini:
    server:
      domain: "${GRAFANA_DOMAIN:-web-dev1-grafana...}"   # Helm KHÔNG expand ${...}
  sidecar:
    datasources:
      defaultDatasourcesEnabled: true                    # key không tồn tại
```

**Nguyên nhân:**

1. **Helm không expand `${VAR}` trong values file.** Chuỗi literal `"${GRAFANA_DOMAIN:-...}"` trở thành
   `domain` thật của Grafana → URL tuyệt đối và cookie domain sai → ingress redirect qua lại.
2. `domain` / `root_url` / `serve_from_sub_path` không nhất quán. Ingress expose ở `/`, nên
   `serve_from_sub_path` phải `false` và `root_url` phải khớp `domain`.
3. Key đúng là **`defaultDatasourceEnabled`** (số ít), không phải `defaultDatasourcesEnabled`.
   Key sai bị bỏ qua im lặng. Hiện đặt **`false`** và khai báo cả 2 datasource tường minh: bản tự
   động của chart luôn kèm datasource **Alertmanager** dù `alertmanager.enabled: false` → Grafana
   hiện một datasource trỏ tới service không tồn tại.

**Cách sửa (sau):**

```yaml
grafana:
  defaultDashboardsEnabled: false
  sidecar:
    dashboards:  { enabled: false }
    datasources:
      enabled: true
      defaultDatasourceEnabled: false       # số ít; tắt auto-provision
      label: grafana_datasource
      labelValue: "1"
    resources:                              # sidecar luôn chạy → phải bound
      requests: { cpu: 10m, memory: 32Mi }
      limits:   { cpu: 50m, memory: 64Mi }
  grafana.ini:
    server:
      domain: web-dev1-grafana.vucongtuanduong.dpdns.org
      root_url: "https://%(domain)s/"
      serve_from_sub_path: false
    auth.anonymous: { enabled: false }   # section phải phẳng (xem 2.f)
    users:
      allow_sign_up: false
  additionalDataSources:
    - name: Prometheus
      type: prometheus
      uid: prometheus
      access: proxy
      url: http://monitoring-kube-prometheus-prometheus.observability.svc.cluster.local:9090
      isDefault: true
      editable: false
      jsonData: { httpMethod: POST, timeInterval: 30s }
    - name: Tempo
      type: tempo
      uid: tempo
      access: proxy
      url: http://tempo.observability.svc.cluster.local:3200
      editable: false
```

**Verify:** `helm template monitoring ... | grep -A5 'grafana.ini'` phải ra domain literal (không còn
`${`); mở Grafana qua ingress không redirect loop; Connections → Data sources có cả Prometheus và Tempo.

---

### 2.e — Các sửa phụ trong cùng đợt

| Vấn đề | Cách sửa |
|---|---|
| `install.sh` echo mật khẩu Grafana ra stdout | Không echo; chỉ in "password from .env.observability" |
| Password có `,` hoặc `\` làm hỏng `helm --set` | Escape một lần bằng bash replacement rồi `--set-string` |
| Thiếu password vẫn chạy | `: "${GRAFANA_ADMIN_PASSWORD:? ...}"` fail sớm |
| Release cũ còn sót chiếm RAM | Bước `[0/5]` liệt kê release lạ trong namespace `observability` và cảnh báo |
| Helm treo vô hạn | `--wait --timeout 10m` cho cả Tempo và KPS |
| Số bước trong echo sai | Đánh số lại `[0/5]`…`[5/5]`; `uninstall.sh` sửa tương ứng |
| `prometheus` đầy PVC 2Gi | `retention: 3d` + `retentionSize: "1500MB"` (Prometheus vẫn giữ head chunks) |
| Control-plane target down vĩnh viễn | Tắt `kubeControllerManager`, `kubeScheduler`, `kubeProxy`, `kubeEtcd` — k3s chạy trong process server, không scrape được |
| cAdvisor scrape 10s quá dày | `kubelet.serviceMonitor.interval/cAdvisorInterval = 30s` |
| Pyroscope chết (không có server, agent vẫn nạp) | Bỏ `io.pyroscope:agent` khỏi 5 `pom.xml`, bỏ block Pyroscope trong 5 `Dockerfile`, bỏ block config trong 6 `application.yaml` |

---

### 2.f — Hai lỗi phát sinh lúc chạy `install.sh` (2026-11-08)

**(f1) `504 Gateway Timeout` khi tải chart Tempo.**

```
Error: failed to fetch https://github.com/grafana/helm-charts/releases/download/tempo-1.21.1/tempo-1.21.1.tgz : 504 Gateway Timeout
```

**Nguyên nhân:** `helm repo add grafana ...` trỏ tới GitHub Pages index, nhưng `urls` của từng chart lại
là **GitHub Releases CDN**. Tại thời điểm chạy, `curl -I` chính URL trên trả **HTTP 504** từ edge
`x-github-edge-region: southeastasia` với mọi tag (thử cả `1.21.0`). Đây là lỗi hạ tầng của GitHub,
không phải mạng local, không phải sai version: cả `tempo-1.21.1` và `kube-prometheus-stack-72.6.2`
đều có trên GHCR (`ghcr.io/grafana/helm-charts/tempo`, `ghcr.io/prometheus-community/charts/kube-prometheus-stack`).

**Cách sửa:** `install.sh` bỏ hẳn `helm repo add/update`, **pull chart qua OCI (retry 3 lần, backoff
10s/20s)** rồi cài từ file `.tgz` local. Retry đặt ở bước **download**, không phải bước install: fetch
lỗi không tạo release nào, còn retry một release đang dở sẽ báo `another operation in progress` và để
release ở trạng thái `pending`.

```bash
CHARTS_TMP="$(mktemp -d)"
trap 'rm -rf "$CHARTS_TMP"' EXIT

helm_pull() {
  local url="$1" version="$2" attempt
  for attempt in 1 2 3; do
    if helm pull "$url" --version "$version" -d "$CHARTS_TMP"; then return 0; fi
    echo "[WARN] helm pull ${url}:${version} failed (attempt ${attempt}/3)"
    [[ "$attempt" -lt 3 ]] && sleep $(( attempt * 10 ))
  done
  return 1
}

helm_pull oci://ghcr.io/grafana/helm-charts/tempo 1.21.1
helm upgrade --install tempo "$CHARTS_TMP/tempo-1.21.1.tgz" ...
```

Tên file `helm pull` sinh ra là `<chart>-<version>.tgz` (đã kiểm tra thực tế: `tempo-1.21.1.tgz`,
`kube-prometheus-stack-72.6.2.tgz`).

Bước `[1/5]` đổi từ `helm repo add/update` thành kiểm tra `helm` có trong `PATH`.

**Verify:** `helm template tempo oci://ghcr.io/grafana/helm-charts/tempo --version 1.21.1 -f charts/tempo-values.yaml`
pull được từ GHCR và render đúng `-mem-ballast-size-mbs=0` + `resources`.

**(f2) `grafana.ini` render ra `anonymous = map[enabled:false]`.**

**Nguyên nhân:** mỗi section của `grafana.ini` là map phẳng key→scalar. Viết lồng
`auth: { anonymous: { enabled: false } }` thì chart in giá trị Go của map ra INI, thành option
`anonymous` không tồn tại → Grafana bỏ qua, không hề tắt anonymous như ý định.

**Cách sửa:** dùng tên section phẳng `auth.anonymous:` → render `[auth.anonymous]` + `enabled = false`.
**Verify:** `helm template ... | grep -c 'map\['` phải bằng **0**.

---

### 2.g — Đối chiếu review PR #87 (verdict 3/3: không có lỗi thật)

Review của Pullfrog nêu 3 điểm và tự ghi "can't verify". Đã kiểm tra bằng chính
`META-INF/spring-configuration-metadata.json` của các jar Spring Boot **4.1.0** trong `~/.m2`
(đây là metadata Spring dùng để bind, nên là nguồn chuẩn hơn docs):

| Review nói | Thực tế | Kết luận |
|---|---|---|
| ai-assistant đổi sang `management.opentelemetry...` trong khi 5 service kia giữ `management.tracing.otlp.tracing.endpoint` | Cả 6 service **đều** dùng `management.opentelemetry.tracing.export.otlp.endpoint`; không file nào còn `management.tracing.otlp.*` | Nhận xét sai, không sửa key |
| Gỡ `management.tracing.enabled: true` làm đổi default tracing của ai-assistant | Key này bị deprecate mức **error**, replacement `management.tracing.export.enabled` có default **true** → không đổi hành vi | Thêm `export.enabled: true` cho đồng bộ 6 service |
| Đổi MDC `trace_id`→`traceId` phải chắc pipeline parse được | `Slf4JEventListener` (micrometer-tracing-bridge-otel 1.7.0) ghi literal `traceId`/`spanId`; log chỉ ra stdout, không có aggregator nào parse | Nhận xét đúng, không cần sửa |

Bằng chứng metadata (rút gọn):

```
management.tracing.export.enabled                                  default=True
management.tracing.enabled            dep=error -> management.tracing.export.enabled
management.tracing.export.otlp.enabled                             default=True
management.opentelemetry.tracing.export.otlp.endpoint              (live)
management.otlp.tracing.endpoint      dep=error -> management.opentelemetry.tracing.export.otlp.endpoint
management.otlp.metrics.export.enabled                             default=True  (vẫn là tên đúng)
management.tracing.sampling.probability                            default=0.1
```

Bài học: **property sai không gây lỗi khởi động** — Spring bỏ qua key lạ. Vì vậy phải đối chiếu
metadata/`@ConfigurationProperties` chứ không "đọc code thấy hợp lý là xong".

---

### 2.h — Grafana không hiện datasource sau install (2026-11-08)

**Triệu chứng:** `./install.sh` chạy xong, mở Grafana thấy danh sách Data sources trống
(hoặc thiếu Prometheus).

**Nguyên nhân:** datasource được nạp qua sidecar `k8s-sidecar` (image quay.io): sidecar mount
một `emptyDir` vào `/etc/grafana/provisioning/datasources` rồi **ghi** `datasource.yaml`.
Grafana đọc thư mục provisioning lúc khởi động, nên nếu sidecar ghi xong sau đó thì file
không được nạp; sidecar có gọi API reload nhưng phụ thuộc credential admin và thời điểm.
Sidecar còn là moving part thứ hai: image ngoài registry + quyền watch ConfigMap/Secret.

**Cách sửa:**

- `grafana.forceDeployDatasources: true` — template ConfigMap chỉ render khi sidecar bật
  **hoặc** cờ này bật.
- `grafana.sidecar.datasources.enabled: false` — bỏ hẳn sidecar (bớt 1 container, bớt image quay.io).
- `grafana.extraConfigmapMounts` mount chính ConfigMap đó vào
  `/etc/grafana/provisioning/datasources/datasource.yaml` (`subPath: datasource.yaml`).
  Grafana đọc file ngay khi start — không còn đua thời điểm.
- Tên ConfigMap theo helper fullname: `<release>-kube-prometheus-grafana-datasource`, nên
  trong values dùng `'{{ .Release.Name }}-kube-prometheus-grafana-datasource'`
  (release cố định `monitoring` trong `install.sh`).
- `install.sh` thêm bước `[verify]`: `kubectl exec` đọc đúng file trong pod và fail rõ ràng
  nếu thiếu.

**Đánh đổi:** `subPath` không cập nhật tại chỗ → sửa `additionalDataSources` phải
`kubectl -n observability rollout restart deploy/monitoring-grafana`.

**Verify:** `helm template ... | sed -n '/datasource.yaml: |-/,/^---/p'` ra đúng 2 datasource;
deployment Grafana không còn container `grafana-sc-datasources`; volume `grafana-datasources`
trỏ đúng tên ConfigMap vừa render.

---

### 2.i — node-exporter và kube-state-metrics vẫn deploy dù values ghi "disabled" (2026-11-08)

**Triệu chứng:** sau khi install bản Lite, `kubectl -n observability get pods` vẫn có
`monitoring-prometheus-node-exporter-*` (DaemonSet) và `monitoring-kube-state-metrics-*`, kèm loạt
restart trong vài phút: operator `0/1` (restart 2), KSM restart 2, node-exporter restart 2 — dấu hiệu
node bị ép bộ nhớ chứ không phải một pod lỗi riêng lẻ.

**Nguyên nhân:** chart 72.6.2 gate subchart bằng `Chart.yaml` →
`dependencies[].condition`, và điều kiện là **camelCase**: `kubeStateMetrics.enabled`,
`nodeExporter.enabled`. Block `kube-state-metrics:` / `prometheus-node-exporter:` trong values file
chỉ là **namespace values của subchart**, không phải công tắc bật/tắt. Đặt `enabled: false` ở đó bị
bỏ qua **im lặng** — values trông đúng, comment ghi "disabled", nhưng cả hai workload vẫn render.

**Cách sửa:**

- `nodeExporter.enabled: false` và `kubeStateMetrics.enabled: false` (giữ đúng 2 key này, đừng quay
  lại key kebab-case).
- `install.sh` thêm `[verify] Lite stack composition`: liệt kê pod `node-exporter|kube-state-metrics`
  còn sót. Chỉ **warn**, không fail, vì ngay sau upgrade pod cũ đang terminating.

**Verify:** `helm template monitoring … -f charts/kube-prometheus-stack-values.yaml` cho
`kind: DaemonSet` = **0**, `kind: StatefulSet` = **0** (Prometheus do operator tạo từ CR, không nằm
trong output Helm), `kind: Deployment` = **2** (`monitoring-grafana`, `monitoring-kube-prometheus-operator`),
và không còn chuỗi `kube-state-metrics` / `prometheus-node-exporter` trong manifest render.

**Hệ quả:** mất object metrics (pod/deployment phase, restart count…) và host metrics — đúng phạm vi
đồ án (chỉ cần metrics HTTP của 6 service). Đổi lại bớt 2 workload khỏi node 8 GB, giảm đúng loại áp
lực đã gây eviction dây chuyền.

---

### 2.j — Backend namespace `web-grading` không resolve DNS Tempo (2026-11-08, sau khi cluster lên)

**Triệu chứng:** Log `ai-assistant-service` (cổng 8086, namespace `web-grading`) lặp lại:

```
java.net.UnknownHostException: tempo.observability.svc.cluster.local
```

Tempo pod `tempo-0` ở namespace `observability` chạy `1/1 Running`, và `nslookup` từ **trong**
namespace `observability` resolve được `tempo.observability.svc.cluster.local` → `10.43.138.83`.
Nhưng backend ở namespace khác không resolve được.

**Nguyên nhân:** File `charts/tempo-values.yaml` khối `service:` chỉ có `type: ClusterIP`,
thiếu `enabled: true` và các port định nghĩa. Chart `grafana/tempo` có thể không render Service
đúng tên/port → không có DNS record `tempo.observability.svc.cluster.local` accessible từ namespace
khác. Backend OTLP endpoint trong `application-observability.yaml` trỏ
`http://tempo.observability.svc.cluster.local:4318/v1/traces` — nếu Service không có port 4318
hoặc không tồn tại, DNS fail.

**Cách sửa:** Khai báo rõ ràng `enabled: true` và các port cần thiết:

```yaml
service:
  enabled: true
  type: ClusterIP
  ports:
    - name: http
      port: 3200
      targetPort: 3200
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
```

Port 4318 là quan trọng nhất — đó là port OTLP HTTP mà 6 backend push trace tới.

**Verify sau khi cluster ổn định:**

```bash
# 1. Kiểm tra Service Tempo có tồn tại
kubectl get svc -n observability tempo -o wide

# 2. Kiểm tra DNS từ pod backend
kubectl exec -n web-grading deploy/course-service -- sh -c 'getent hosts tempo.observability.svc.cluster.local || ping -c1 tempo.observability.svc.cluster.local'

# 3. Kiểm tra trace có lên Tempo không (tìm theo service.name)
# Mở Grafana → Explore → Tempo → service.name=ai-assistant-service
```

**Lưu ý:** `nslookup` không có sẵn trong container backend (image JRE minimal), nên dùng
`getent hosts` hoặc `ping` thay thế.

---

### 2.k — Tempo OTLP receivers bind `localhost` (không phải `0.0.0.0`) — các trace không đến Tempo (2026-11-08)

**Triệu chứng:**
- Service `tempo.observability.svc.cluster.local` resolve được ✅
- Port 4318 expose trong Service ✅
- Pod `tempo-0` Running, không crash ✅
- Nhưng backend logs: `Connection refused` khi POST OTLP traces ❌
- `tempo_distributor_spans_received_total = 0` ❌
- Grafana Explore Tempo → "No data" ❌

**Root cause:** Tempo chart `grafana/tempo` v1.21.1 dùng OpenTelemetry Collector >=v0.112.0,
trong đó receivers mặc định bind **`localhost`** thay vì `0.0.0.0` (breaking change vì lý do security).
File `charts/tempo-values.yaml` **không có cấu hình `distributor.receivers`** → Tempo binary khởi
động với built-in defaults của Collector → OTLP gRPC/HTTP chỉ lắng nghe trên `localhost:4317`/`localhost:4318`
trong container → backend từ namespace `web-grading` không kết nối được.

**Bằng chứng:** [grafana/tempo#4465](https://github.com/grafana/tempo/issues/4465) xác nhận breaking change này.

**Cách sửa:** Thêm cấu hình `distributor.receivers.otlp.protocols.*.endpoint: "0.0.0.0:4317/4318"`
vào `deploy/observability/charts/tempo-values.yaml`:

```yaml
distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: "0.0.0.0:4317"
        http:
          endpoint: "0.0.0.0:4318"
```

**Verify sau khi cluster ổn định:**
```bash
# 1. Render Helm manifest có receivers config đúng
helm template tempo grafana/tempo --version 1.21.1 -f deploy/observability/charts/tempo-values.yaml \
  | grep -A10 "endpoint:"

# 2. Re-deploy Tempo
cd deploy/observability && ./install.sh

# 3. Kiểm tra Tempo logs
kubectl logs -n observability tempo-0 --tail=100 | grep -i "otlp\|receiver\|4318"

# 4. Test connectivity từ web-grading namespace
kubectl run curl-test --rm -it --image=curlimages/curl -n web-grading -- \
  curl -v http://tempo.observability.svc.cluster.local:4318/v1/traces

# 5. Verify metric ingested
kubectl port-forward -n observability tempo-0 3200:3200 &
curl http://localhost:3200/metrics | grep tempo_distributor_spans_received_total

# 6. Query traces từ Grafana Explore → Tempo → service.name = "ai-assistant-service"
```

---

### 2.l — Tempo HTTP server listen port 3100 (không phải 3200) — Grafana không kết nối được (2026-11-08)

**Triệu chứng:**
- Tempo pod Running, Service có port 4318/4317 ✅
- Nhưng Grafana datasource Tempo trả `i/o timeout` khi connect `tempo.observability.svc.cluster.local:3200` ❌
- Tempo logs: `server listening on addresses http=[::]:3100 grpc=[::]:9095` ❌ (listen 3100, không phải 3200)
- Service Endpoints không có `:3200` ❌

**Root cause:** Chart `grafana/tempo` v1.21.1 mặc định dùng **port 3100** cho HTTP server (legacy port).
Grafana datasource được cấu hình trong `kube-prometheus-stack-values.yaml` trỏ tới
`http://tempo.observability.svc.cluster.local:3200` → mismatch port → Grafana không query được traces.

**Cách sửa:** Thêm cấu hình `server.http_listen_port: 3200` vào `deploy/observability/charts/tempo-values.yaml`:

```yaml
server:
  http_listen_port: 3200
  grpc_listen_port: 9095
```

Service `tempo` đã khai báo `port: 3200, targetPort: 3200` → giờ pod sẽ listen đúng 3200, Service forward đúng.

**Verify sau khi cluster ổn định:**
```bash
# 1. Render Helm manifest có server config đúng
helm template tempo grafana/tempo --version 1.21.1 -f deploy/observability/charts/tempo-values.yaml \
  | grep -A5 "http_listen_port"

# 2. Re-deploy Tempo
cd deploy/observability && ./install.sh

# 3. Kiểm tra pod listen port 3200
kubectl exec -n observability tempo-0 -- ss -tlnp | grep :3200

# 4. Kiểm tra Service Endpoints có :3200
kubectl get endpoints -n observability tempo -o yaml | grep "3200"

# 5. Test từ Grafana pod
kubectl exec -n observability deployment/monitoring-grafana -- \
  wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready

# 6. Kiểm tra readiness probe
kubectl get pod -n observability tempo-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Expected: True
```

---

## 3. Vì sao 8 GB không đủ (ngân sách tài nguyên)

Số dưới đây là **limits/ước tính đọc từ manifest**, không phải RSS đo runtime (cluster không truy cập
được):

| Thành phần | Ngân sách |
|---|---|
| k3s + system | ~1.5 GiB |
| ArgoCD | ~1.0 GiB |
| Keycloak (không đặt limits) | 0.8–1.2 GiB |
| 6 service backend (6 × 512Mi) | 3.0 GiB |
| executor 2 replica + 2 × dind | ~3.0 GiB |
| Observability Lite | ~1.8 GiB |
| **Tổng** | **~10.3–10.7 GiB** |

Overcommit khoảng **30%**. Ở mức đó hệ thống vẫn "sống" nhờ phần lớn container dùng ít hơn limit,
nhưng **chỉ cần Tempo alloc thêm 1 GiB ballast** là đủ đẩy node qua ngưỡng → eviction dây chuyền.
Nói cách khác: sự cố là do cấu hình sai, không phải do bản thân stack Lite.

---

## 4. Tổng hợp file đã sửa

| Nhóm | File | Nội dung |
|---|---|---|
| Helm values | `deploy/observability/charts/tempo-values.yaml` | 2.a, 2.j (service ports), 2.k (distributor receivers 0.0.0.0), 2.l (HTTP server port 3200) |
| Helm values | `deploy/observability/charts/kube-prometheus-stack-values.yaml` | 2.b, 2.d, 2.f2, 2.h (datasource mount), 2.i (key camelCase cho KSM/node-exporter), retention, tắt control-plane |
| Script | `deploy/observability/install.sh`, `uninstall.sh` | 2.e, 2.f1 (OCI + retry), 2.h (verify datasource), 2.i (verify Lite composition) |
| Template | `deploy/observability/templates/application-observability.yaml` | 2.c (viết lại theo Boot 4.1) |
| Backend | 6 × `src-services/*/src/main/resources/application.yaml` | 2.c — MDC key, sampling theo env, bỏ property deprecated, tắt OTLP metrics, bỏ block Pyroscope |
| Backend | `src-services/ai-assistant-service/.../logback-spring.xml` | 2.c — MDC key |
| Build | 5 × `pom.xml`, 5 × `Dockerfile` | bỏ Pyroscope agent |
| Docs | `docs/observability/README.md`, `deploy/observability/README.md`, `README.md` | cập nhật theo cấu hình mới |
| Skill | `.opencode/skills/observability-stack/SKILL.md` + `.kilo/...` | gotcha chart schema, 401, Boot 4.1 property, MDC key (2 bản phải identical) |

---

## 5. Kiểm chứng đã chạy

| Check | Kết quả |
|---|---|
| `helm template` Tempo (Helm 3.16.4) | ✅ `-mem-ballast-size-mbs=0`, `GOMEMLIMIT=400MiB`, `grafana/tempo:2.7.1`, `resources` đúng trong container spec |
| `helm template` Tempo (distributor) | ✅ `distributor.receivers.otlp.protocols.http.endpoint: "0.0.0.0:4318"`, `grpc.endpoint: "0.0.0.0:4317"` |
| `helm template` Tempo (server port) | ✅ `server.http_listen_port: 3200`, `grpc_listen_port: 9095` |
| `helm template` kube-prometheus-stack | ✅ scrape config không còn bearer token, có filter app/phase/ready/port; Grafana config domain literal; `retentionSize`; đúng **2 datasource** (Prometheus isDefault + Tempo), không còn Alertmanager; không còn ServiceMonitor control-plane |
| `helm template` qua OCI (GHCR, helm 3.16.4) | ✅ `tempo` + `kube-prometheus-stack` pull được, không phụ thuộc GitHub Releases CDN |
| `grafana.ini` render | ✅ `[auth.anonymous] enabled = false`; `grep -c 'map\['` = 0 |
| Parse 11 file YAML bằng PyYAML | ✅ 0 lỗi |
| `bash -n install.sh uninstall.sh` | ✅ pass |
| `helm template` sau 2.i | ✅ `DaemonSet=0`, `StatefulSet=0`, `Deployment=2` (grafana + operator), 0 ref tới `kube-state-metrics`/`prometheus-node-exporter` |
| `helm template` sau 2.h | ✅ 1 container `grafana` (không sidecar), mount `…/datasources/datasource.yaml` trỏ ConfigMap `monitoring-kube-prometheus-grafana-datasource`, CM có `name: Prometheus` + `name: Tempo` |
| `ApiGatewayApplicationTests` | ✅ pass |

---

## 6. Chưa kiểm chứng / giới hạn

- **Không có số đo runtime**: cluster `127.0.0.1:6443` connection refused → chưa xác nhận được
  RSS thực tế của pod, không có bằng chứng `Evicted` sau khi sửa, chưa xem target health thật.
- `CourseServiceApplicationTests` fail vì PostgreSQL local `localhost:5432` không chạy — **không liên quan**
  thay đổi này.
- Image tag trong `config-services/*/values-stg.yaml` có thể cũ hơn source hiện tại; deploy lại cần build
  image mới để các thay đổi `application.yaml`/`Dockerfile` có hiệu lực.

**Việc còn phải làm khi cluster lên lại:**

```bash
# 1. Render lại trước khi apply
helm template tempo grafana/tempo --version 1.21.1 -f deploy/observability/charts/tempo-values.yaml \
  | grep -E "ballast|GOMEMLIMIT|resources" -A2

# 2. Cài lại stack
cd deploy/observability && ./install.sh

# 3. Kiểm tra tài nguyên thật
kubectl -n observability get pod tempo-0 -o jsonpath='{.spec.containers[0].resources}{"\n"}'
kubectl -n observability top pod
kubectl -n observability get events --sort-by=.lastTimestamp | grep -Ei "evict|oom" || echo "no eviction"

# 4. Prometheus targets
kubectl -n observability port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/targets | python3 -c 'import json,sys; [print(t["labels"]["job"], t["health"], t.get("lastError","")) for t in json.load(sys.stdin)["data"]["activeTargets"]]'

# 5. Log nối trace
kubectl -n web-grading logs deploy/api-gateway --tail=50 | grep -E "\[api-gateway,[0-9a-f]+,[0-9a-f]+\]"
```

---

## 7. Đề xuất chưa áp dụng (ngoài scope)

1. `executor-service` `replicaCount: 2 → 1`: tiết kiệm ~1.5 GiB limit.
2. Keycloak + RustFS: đặt requests/limits và probe; RustFS bỏ tag `latest`.
3. ArgoCD: tắt Dex, Notifications, ApplicationSet nếu không dùng (~0.3–0.5 GiB).
4. Cân nhắc tắt metrics-server của k3s nếu không dùng HPA.
5. Đặt `OTEL_TRACES_SAMPLING_PROBABILITY=0.1–0.2` ở staging để giảm tải Tempo và log.
6. Cân nhắc thêm `livenessProbe`/`readinessProbe` cho Tempo trước khi tin vào `--wait` của Helm.

---

## 8. Bài học rút ra

1. **Helm chart không validate key.** Key sai nhánh hoặc sai tên bị bỏ qua im lặng. Luôn `helm template`
   rồi grep vào spec container/datasource, đừng tin values file trông "đúng".
2. **`bearer_token_file` trong scrape config là của target**, không phải của discovery. Resource server
   reactive trả 401 trước `permitAll()`.
3. **Boot 4.1 bật OTLP metrics mặc định.** Mọi service chỉ dùng Prometheus pull phải tắt tường minh.
4. **MDC key là `traceId`/`spanId`** (camelCase), không phải `trace_id`/`span_id`.
5. **Grafana: `defaultDatasourceEnabled` số ít**, và Helm không expand `${...}`.
6. **Không đặt `memBallastSizeMbs` mặc định 1024 trên box nhỏ** — đó là 2× limit của container.
7. **Đọc limit không đủ để kết luận "stack nặng"**: phải xem pod có thực sự nhận limit không.
8. **OTel Collector >=v0.112.0 binding receivers đến `localhost`**: với `grafana/tempo` 1.21.1,
   phải khai báo `distributor.receivers.otlp.protocols.http.endpoint: "0.0.0.0:4318"` tường minh,
   nếu không cross-namespace OTLP ingestion fail im lặng (pod healthy, Service exists, DNS resolves,
   nhưng connection refused).
