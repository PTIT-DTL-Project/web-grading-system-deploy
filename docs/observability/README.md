# Observability Stack — Kiến trúc và Luồng dữ liệu

Tài liệu này mô tả stack **Lite** đang chạy trên cluster k3s 8 GB RAM:
Prometheus + Grafana + Tempo. Các thành phần của stack cũ (Loki, Mimir, Alloy,
Pyroscope, node-exporter, kube-state-metrics, Alertmanager) **không còn được
triển khai**; xem mục 11 để biết lý do và cách xử lý tàn dư.

Mục lục
=======
1. [Tổng quan](#1-tổng-quan)
2. [Kiến trúc](#2-kiến-trúc)
3. [Thành phần và tài nguyên](#3-thành-phần-và-tài-nguyên)
4. [Luồng dữ liệu Metrics](#4-luồng-dữ-liệu-metrics)
5. [Luồng dữ liệu Traces](#5-luồng-dữ-liệu-traces)
6. [Log và trace correlation](#6-log-và-trace-correlation)
7. [Cấu hình Spring Boot](#7-cấu-hình-spring-boot)
8. [Grafana](#8-grafana)
9. [Cloudflare Tunnel](#9-cloudflare-tunnel)
10. [Ngân sách RAM cho máy 8 GB](#10-ngân-sách-ram-cho-máy-8-gb)
11. [Troubleshooting](#11-troubleshooting)
12. [Thêm service mới](#12-thêm-service-mới)

---

## 1. Tổng quan

Hệ thống chỉ giữ hai tín hiệu cần thiết cho đồ án:

- **Metrics**: Prometheus kéo (pull) `/actuator/prometheus` từ sáu service
  Spring Boot.
- **Traces**: mỗi service đẩy OTLP/HTTP trực tiếp tới Tempo.

Grafana là giao diện duy nhất để query cả hai. Không có log aggregation tập
trung: log vẫn nằm ở stdout container và xem bằng `kubectl logs`.

---

## 2. Kiến trúc

```
                    ┌─────────────────────────────────────────────┐
                    │                  Grafana                    │
                    │      Prometheus datasource + Tempo          │
                    └───┬─────────────────────────────────────┬───┘
                        │ query                               │ query
                        ▼                                     ▼
                 ┌─────────────┐                       ┌─────────────┐
                 │ Prometheus  │                       │   Tempo     │
                 │  :9090      │                       │  :3200      │
                 └──────▲──────┘                       └──────▲──────┘
                        │ pull /actuator/prometheus            │ OTLP/HTTP :4318
                        │ mỗi 30s                              │
                 ┌──────┴──────────────────────────────────────┴──────┐
                 │              Pods web-grading                       │
                 │  api-gateway, course, submission, executor,        │
                 │  result, ai-assistant                              │
                 └────────────────────────────────────────────────────┘
```

Namespace:

```
k3s cluster
├── kube-system     (k3s built-in: Traefik, CoreDNS, ...)
├── web-grading     (sáu service nghiệp vụ)
└── observability   (Prometheus, Grafana, Tempo)
```

---

## 3. Thành phần và tài nguyên

| Thành phần | Cài đặt | CPU request/limit | RAM request/limit | Ghi chú |
|---|---|---|---|---|
| Prometheus | kube-prometheus-stack | 100m / 500m | 256Mi / 768Mi | TSDB 2Gi, retention 3 ngày, cắt ở 1500MB |
| Grafana | kube-prometheus-stack | 200m / 750m | 384Mi / 768Mi | PVC 2Gi |
| Tempo | grafana-community/tempo 2.4.0 | 100m / 500m | 256Mi / 1Gi | PVC 2Gi, retention 24h, port 3200, `GOMEMLIMIT=800MiB` |

Tổng request khoảng **0.9Gi**, tổng limit khoảng **2.5Gi**. Đây là mức tối đa
nên dành cho observability trên máy 8 GB; phần còn lại phải chia cho k3s,
ArgoCD, Keycloak, RustFS và sáu service nghiệp vụ. Limit của Grafana và Tempo
đã được nâng sau các lần OOMKill (Grafana 768Mi, Tempo 1Gi cho `local-blocks`),
nên phần RAM cần cắt phải đến từ các thành phần khác — xem mục 10.

Các thành phần **không triển khai**:

| Thành phần | Lý do |
|---|---|
| Loki + promtail/Alloy | Log aggregation chiếm RAM/disk; `kubectl logs` đủ cho dev |
| Mimir | Prometheus đã đủ cho 3 ngày retention |
| Alloy | Service đẩy OTLP trực tiếp tới Tempo, không cần collector |
| Pyroscope | Continuous profiling không cần thiết, agent đã bị tắt |
| node-exporter | Không cần host metrics cho phạm vi đồ án |
| kube-state-metrics | Không cần object metrics |
| Alertmanager | Không có alerting |

> Hai thành phần cuối được tắt bằng **key camelCase** `nodeExporter.enabled` và
> `kubeStateMetrics.enabled` (chart 72.x). Key kebab-case
> `prometheus-node-exporter.enabled` / `kube-state-metrics.enabled` chỉ là
> namespace values của subchart nên **bị bỏ qua im lặng** — đặt `false` mà
> DaemonSet/Deployment vẫn được tạo.

---

## 4. Luồng dữ liệu Metrics

```
1. Spring Boot Actuator mở /actuator/prometheus (Micrometer Prometheus registry).
2. Prometheus dùng Kubernetes pod service discovery trong namespace web-grading.
3. Relabel chỉ giữ:
   - pod có label app thuộc sáu service;
   - pod đang Running và Ready;
   - container port 8080/8081/8082/8083/8084/8086.
4. Prometheus scrape mỗi 30 giây, lưu vào TSDB trên PVC.
5. Grafana query Prometheus bằng PromQL.
```

Điểm quan trọng: Prometheus **không gửi ServiceAccount token** khi scrape pod.
Token chỉ dùng cho Kubernetes API để discovery. Nếu gắn
`bearer_token_file` vào scrape config, `api-gateway` sẽ trả 401 vì
resource-server filter chạy trước `permitAll()` của `/actuator/prometheus`.

Service nào cũng phải mở endpoint này trong SecurityConfig. Hiện tại cả sáu
service đều permit `/actuator/**` hoặc `/actuator/prometheus`.

---

## 5. Luồng dữ liệu Traces

```
1. Spring Boot tạo span cho HTTP request, JDBC, Feign/RestClient...
2. Micrometer Tracing bridge OpenTelemetry gom span theo batch.
3. OtlpHttpSpanExporter POST tới:
   http://tempo.observability.svc.cluster.local:4318/v1/traces
4. Tempo nhận, ghi WAL rồi flush thành block trên PVC.
5. Grafana query Tempo bằng TraceQL hoặc Search.
```

Cấu hình sampling mặc định là 100% cho dev. Có thể giảm mà không cần build lại:

```bash
OTEL_TRACES_SAMPLING_PROBABILITY=0.1
```

Tempo **không** nhận metrics. Vì vậy mọi service phải đặt
`management.otlp.metrics.export.enabled: false`; nếu không, Spring Boot 4.x
mặc định bật OTLP metrics và sẽ gửi lỗi mỗi 60 giây.

---

## 6. Log và trace correlation

Không có Loki nên không có "View logs" trong Grafana. Tuy vậy log vẫn mang
trace context để đối chiếu thủ công:

```yaml
logging:
  pattern:
    level: "%5p [${spring.application.name:},%X{traceId:-},%X{spanId:-}]"
```

- Micrometer inject MDC key `traceId` và `spanId` (viết hoa chữ I).
- Dùng `trace_id`/`span_id` sẽ cho giá trị rỗng.
- Khi cần xem log của một trace: lấy trace ID từ Grafana → Tempo, rồi
  `kubectl logs -n web-grading deploy/<service> | grep <traceId>`.

---

## 7. Cấu hình Spring Boot

### 7.1 Dependencies

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-opentelemetry</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
```

### 7.2 application.yaml

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
  tracing:
    sampling:
      probability: ${OTEL_TRACES_SAMPLING_PROBABILITY:1.0}
    # Boot 4.1 mặc định true (key cũ management.tracing.enabled bị báo error).
    # Khai báo tường minh để 6 service dùng cùng một bộ key.
    export:
      enabled: true
  # Spring Boot 4.x. Không dùng management.otlp.tracing.* hay
  # management.tracing.enabled nữa: cả hai đã deprecated ở mức error.
  # Đã đối chiếu metadata spring-boot-*-4.1.0.
  opentelemetry:
    tracing:
      export:
        otlp:
          endpoint: ${OTLP_TRACES_ENDPOINT:http://tempo.observability.svc.cluster.local:4318/v1/traces}
  otlp:
    metrics:
      # Metrics vẫn ở namespace management.otlp.metrics.* trong Boot 4.1 và
      # mặc định enabled=true. Đổi sang management.opentelemetry.metrics.* sẽ
      # bị bỏ qua (key không tồn tại) và push tự bật lại.
      export:
        enabled: false

logging:
  pattern:
    # MDC key do micrometer-tracing-bridge-otel đặt: traceId/spanId.
    level: "%5p [${spring.application.name:},%X{traceId:-},%X{spanId:-}]"
```

### 7.3 Kiểm tra nhanh

```bash
# Metrics endpoint (trong pod hoặc port-forward)
kubectl port-forward -n web-grading svc/api-gateway 8080:8080
curl -s http://localhost:8080/actuator/prometheus | head

# Prometheus thấy target không
kubectl port-forward -n observability svc/monitoring-kube-prometheus-prometheus 9090:9090
# Mở http://localhost:9090/targets, tìm job backend-services

# Tempo nhận trace không
kubectl port-forward -n observability svc/tempo 3200:3200
curl -s --get "http://localhost:3200/api/search" \
  --data-urlencode 'q={ resource.service.name = "api-gateway" }' \
  --data-urlencode 'limit=5'
```

---

## 8. Grafana

- Cả hai datasource (Prometheus + Tempo) khai báo tường minh trong
  `grafana.additionalDataSources`, kèm `uid` cố định; Prometheus là `isDefault`.
- `defaultDatasourceEnabled: false`: chart không tự provision nữa, vì bản tự
  động luôn kèm datasource Alertmanager dù Alertmanager không được deploy
  (dead datasource trong UI).
- ConfigMap sinh ra được **mount trực tiếp** vào pod Grafana tại
  `/etc/grafana/provisioning/datasources/datasource.yaml`
  (`grafana.extraConfigmapMounts`), `forceDeployDatasources: true`, sidecar
  datasource **tắt**. Lý do: sidecar ghi file *sau* khi Grafana đã đọc thư mục
  provisioning → cài mới có thể không thấy datasource nào; sidecar còn cần
  image quay.io và quyền watch ConfigMap.
- Vì dùng `subPath`, sửa `additionalDataSources` xong phải
  `kubectl -n observability rollout restart deploy/monitoring-grafana`.
  `install.sh` tự kiểm tra file provision bên trong pod ở bước cuối.
- Không có dashboard được provision sẵn (`defaultDashboardsEnabled: false`,
  dashboards sidecar tắt). Dùng **Explore** để query PromQL/TraceQL.
- Nếu thêm dashboard: bật lại sidecar dashboards và tạo ConfigMap label
  `grafana_dashboard=1`.

Cấu hình host phải khớp ingress:

```yaml
grafana.ini:
  server:
    domain: web-dev1-grafana.vucongtuanduong.dpdns.org
    root_url: "https://%(domain)s/"
    serve_from_sub_path: false
```

Không đặt chuỗi `${GRAFANA_DOMAIN:-...}` trong values: Helm không expand biến
môi trường trong file values, Grafana sẽ nhận nguyên chuỗi đó làm domain.

---

## 9. Cloudflare Tunnel

- Cluster không có public IP; Cloudflare Tunnel đưa traffic vào Traefik.
- Hostname: `web-dev1-grafana.vucongtuanduong.dpdns.org` → Traefik NodePort →
  ingress `grafana` → service `monitoring-grafana:80`.
- Không expose Prometheus/Tempo ra ngoài; Grafana trong cluster gọi qua DNS
  nội bộ.

---

## 10. Ngân sách RAM cho máy 8 GB

Số đo trước khi tối ưu: **~6.7 GB / 7.6 GB khả dụng** (node 8 GB), tức gần như
không còn chỗ cho page cache và cho một pod Java khởi động lại. Sau khi áp
dụng các thay đổi dưới đây, mục tiêu là **~6.1-6.3 GB**, dư ~1.3-1.5 GB.

```
Tổng RAM: 8192 MiB (khả dụng ~7.6Gi)
├── k3s system (apiserver, etcd, kubelet, containerd):        ~1.4Gi
├── Sáu service nghiệp vụ (7 pod: 5 × 256Mi + 2 × 256Mi):  1.75Gi request / 3.5Gi limit
├── dind sidecar của executor (2 × 256Mi):                   512Mi request / 2Gi limit
├── Keycloak (đã có limit 768Mi):                            384Mi request / 768Mi limit
├── Kafka UI + RustFS:                                       256Mi request / 1Gi limit
├── ArgoCD (đã tắt 2 controller thừa):                       ~0.55Gi request / ~1.6Gi limit
└── Observability Lite:                                     ~0.95Gi request / ~2.75Gi limit
---------------------------------------------------------------
Tổng request ~4.4Gi; tổng limit ~11.6Gi (overcommit bình thường,
limit chỉ có tác dụng khi một pod thực sự phình lên).
```

### 10.1 Đã áp dụng

1. **executor-service GIỮ 2 replica** (yêu cầu nghiệp vụ: chấm song song và
   không mất năng lực chấm khi một pod restart/rollout). Mỗi replica gồm app
   512Mi + dind 1Gi limit, tức ~512Mi request / ~1.5Gi limit — đây là khoản tốn
   RAM lớn nhất trong namespace và **không** cắt được. Bù lại, chart đặt
   `strategy.rollingUpdate.maxSurge: 0` để lúc cập nhật image không sinh pod
   thứ ba (pod thứ ba = thêm ~500 MB thực khi node đang khít RAM). Tạm thời
   chạy 1 pod khi code local: `bash dev-scale.sh executor-service on 1`.
2. **Keycloak có requests/limits** (384Mi/768Mi) kèm `JAVA_OPTS_APPEND`
   `-XX:MaxRAMPercentage=60 -XX:InitialRAMPercentage=20 -Xss512k` và
   `KC_METRICS_ENABLED=false`. Không có limit thì JVM định cỡ heap theo RAM
   node, đây là lý do Keycloak từng chiếm ~0.8-1.2 GB.
3. **ArgoCD**: `install-argocd.sh` scale `argocd-notifications-controller` và
   `argocd-applicationset-controller` về 0 (không dùng ApplicationSet, không có
   notification template) và đặt requests/limits cho controller, repo-server,
   server, redis, dex. Trước đó các pod này không có limit nào.
4. **RustFS có trần 512Mi** (request 128Mi) — trước đây không giới hạn nên có
   thể phình theo kích thước upload.
5. **Kafka UI**: request 256Mi → 128Mi (limit giữ 512Mi) để scheduler không
   giữ chỗ vô ích trên node 8 GB.
6. **Image trong `deploy/` đã pin version thay `:latest`**: RustFS `1.0.5`,
   Kafka UI `v1.5.0` (tra ngày 2026-11-11: digest của `latest` trùng đúng tag
   version, xem comment trong manifest). Lý do: `latest` cộng pullPolicy mặc
   định khiến mỗi lần pod restart hoặc kéo một build S3 server khác, hoặc
   đóng băng node ở bản pull đầu tiên — trong khi limit RAM 512Mi được chỉnh
   theo hành vi của đúng bản đang chạy. Khi cần nâng: sửa tag + comment digest
   mới, không quay lại `latest`.

### 10.2 Tuỳ chọn khi vẫn thiếu RAM

1. Tắt metrics-server của k3s nếu không dùng HPA: thêm `--disable=metrics-server`
   vào `/etc/rancher/k3s/config.yaml` rồi `sudo systemctl restart k3s` (~40 MB).
2. Scale `kafka-ui` về 0 khi không cần xem topic:
   `kubectl -n web-grading scale deploy/kafka-ui --replicas=0` (~250 MB).
3. Giảm trace sampling xuống 0.1-0.2 khi không debug
   (`OTEL_TRACES_SAMPLING_PROBABILITY`) — giảm tải Tempo.
4. Chạy chế độ không observability (`setup_without_observability.sh`) khi chỉ
   cần demo nghiệp vụ: tiết kiệm toàn bộ ~0.9 GB request của mục 2.5.

Không tăng limit của Prometheus/Tempo/Grafana trên máy này; nguyên nhân quá
tải thường là thành phần ngoài observability hoặc release cũ còn sót lại.

---

## 11. Troubleshooting

### 11.1 Tempo OOMKilled / restart liên tục

```
kubectl -n observability describe pod tempo-0   # xem Last State
```

Kiểm tra `charts/tempo-values.yaml`:

- `tempo.memBallastSizeMbs: 0` — mặc định 1024 MB, gấp đôi limit 512Mi.
- `resources` phải nằm dưới `tempo:`. Nếu đặt top-level, chart bỏ qua và pod
  không có limit.
- `GOMEMLIMIT=400MiB` giúp Go GC sớm.

### 11.2 Prometheus báo target api-gateway 401

`additionalScrapeConfigs` không được có:

```yaml
bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
tls_config:
  ca_file: ...
```

Hai dòng này áp dụng cho **target pod**, không phải Kubernetes API. Gateway
thấy Bearer token không hợp lệ và trả 401 trước khi tới `permitAll()`.

### 11.3 Không thấy metrics của một service

```
# Trong Prometheus: up{service="<tên-service>"} == 0?
```

- Pod có label `app: <tên-service>` không?
- Pod có Ready không?
- Port có nằm trong dải 8080-8084/8086 không?
- `/actuator/prometheus` có trả 200 khi curl trực tiếp không?

### 11.4 Grafana login loop / redirect sai host

- `server.domain` và `root_url` phải khớp hostname công khai.
- `serve_from_sub_path` phải là `false` vì ingress route `/`, không phải
  `/grafana`.
- Ingress phải trỏ `monitoring-grafana:80`.

### 11.5 Máy vẫn lag sau khi cài

```bash
helm list -A
kubectl get pods -A -o wide
kubectl top pods -A          # nếu có metrics-server
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

Tìm release cũ (`loki`, `mimir`, `alloy`, `pyroscope`) hoặc pod bị OOMKilled.
`install.sh` có bước preflight cảnh báo các release lạ trong namespace
`observability`.

### 11.6 Không có traces

- Service có `spring-boot-starter-opentelemetry` và endpoint đúng chưa?
- `OTEL_TRACES_ENDPOINT` có bị trỏ sai namespace không?
- Tempo pod có Running/Ready không?
- Sampling có bị đặt 0 không?

---

## 12. Thêm service mới

Checklist:

```
□ pom.xml: spring-boot-starter-opentelemetry + spring-boot-starter-actuator
□ application.yaml:
   ├── spring.application.name
   ├── management.opentelemetry.tracing.export.otlp.endpoint
   ├── management.otlp.metrics.export.enabled: false
   └── management.tracing.sampling.probability (env-driven)
□ SecurityConfig: permit /actuator/prometheus
□ Kubernetes Deployment: label app=<tên-service>, container port trong dải scrape
□ Cập nhật regex trong deploy/observability/charts/kube-prometheus-stack-values.yaml
   nếu tên service mới không thuộc sáu tên hiện có
□ Không cần sửa Tempo/Prometheus/Grafana
```

Kiểm tra sau deploy:

```bash
kubectl -n web-grading get pods -l app=<tên-service>
kubectl -n web-grading port-forward deploy/<tên-service> 8080:8080
curl -s http://localhost:8080/actuator/prometheus | head
```

---

## A. Links tham khảo

- [Prometheus Configuration](https://prometheus.io/docs/prometheus/latest/configuration/configuration/)
- [Grafana Tempo Documentation](https://grafana.com/docs/tempo/latest/)
- [Spring Boot Tracing](https://docs.spring.io/spring-boot/reference/actuator/tracing.html)
- [Micrometer Tracing](https://docs.micrometer.io/tracing/reference/)
- [TraceQL Reference](https://grafana.com/docs/tempo/latest/traceql/)
- [PromQL Reference](https://prometheus.io/docs/prometheus/latest/querying/basics/)
