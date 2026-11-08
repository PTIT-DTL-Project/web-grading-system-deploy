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
| Grafana | kube-prometheus-stack | 100m / 500m | 256Mi / 512Mi | PVC 2Gi |
| Tempo | grafana/tempo 1.21.1 | 100m / 500m | 256Mi / 512Mi | PVC 2Gi, retention 24h |
| Grafana datasource sidecar | kube-prometheus-stack | 10m / 50m | 32Mi / 64Mi | Chỉ sidecar datasource |

Tổng request khoảng **0.8Gi**, tổng limit khoảng **1.8Gi**. Đây là mức tối đa
nên dành cho observability trên máy 8 GB; phần còn lại phải chia cho k3s,
ArgoCD, Keycloak, RustFS và sáu service nghiệp vụ.

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
  # Spring Boot 4.x. Không dùng management.otlp.tracing.* hay
  # management.tracing.enabled nữa: cả hai đã deprecated ở mức error.
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

- Prometheus datasource: tự tạo bởi `defaultDatasourcesEnabled: true`.
- Tempo datasource: khai báo trong `additionalDataSources`.
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

```
Tổng RAM: 8192 MiB
├── k3s system (apiserver, etcd, kubelet, containerd): ~1.5Gi
├── ArgoCD: ~1Gi
├── Keycloak: ~0.8-1.2Gi (chưa đặt limit)
├── Sáu service Spring Boot: ~2-2.5Gi
├── executor-service: 2 replica + 2 dind (nếu bật) ~2-3Gi limit
└── Observability Lite: ~0.8Gi request / ~1.8Gi limit
```

Ở mức limit hiện tại, cluster **overcommit** ngay cả khi request còn thấp.
Muốn giảm áp lực:

1. Giảm `replicaCount` của executor từ 2 xuống 1 trong `config-services`
   (tiết kiệm ~0.6-1 GB cùng với dind).
2. Đặt resource limit cho Keycloak và RustFS.
3. Tắt Dex/Notifications/ApplicationSet của ArgoCD nếu không dùng.
4. Cân nhắc tắt metrics-server của k3s nếu không dùng HPA.
5. Giảm trace sampling xuống 0.1-0.2 khi không debug.

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
