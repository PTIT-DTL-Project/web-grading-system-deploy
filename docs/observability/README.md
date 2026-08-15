# Observability Stack — Kiến trúc và Luồng dữ liệu

Mục lục
=======
1. [Tổng quan](#1-tổng-quan)
2. [Kiến trúc hệ thống](#2-kiến-trúc-hệ-thống)
3. [Các công nghệ sử dụng](#3-các-công-nghệ-sử-dụng)
4. [Luồng dữ liệu Logs](#4-luồng-dữ-liệu-logs)
5. [Luồng dữ liệu Metrics](#5-luồng-dữ-liệu-metrics)
6. [Luồng dữ liệu Traces](#6-luồng-dữ-liệu-traces)
7. [Trace ↔ Log Correlation](#7-trace--log-correlation)
8. [Spring Boot — Cấu hình chi tiết](#8-spring-boot--cấu-hình-chi-tiết)
9. [Grafana Dashboard](#9-grafana-dashboard)
10. [Cloudflare Tunnel](#10-cloudflare-tunnel)
11. [Quản lý tài nguyên](#11-quản-lý-tài-nguyên)
12. [Thêm service mới](#12-thêm-service-mới)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Tổng quan

Hệ thống observability theo mô hình **Three Pillars of Observability**: Logs, Metrics, Traces. Mỗi pillar có backend riêng và được tích hợp thống nhất thông qua Grafana.

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Grafana (Dashboard)                         │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│   │  Explore  │  │Dashboard │  │Alert     │  │Service Graph     │  │
│   │  (query)  │  │(panels)  │  │(future)  │  │(node graph)      │  │
│   └─────┬─────┘  └─────┬────┘  └────┬─────┘  └────────┬─────────┘  │
│         │              │            │                   │            │
└─────────┼──────────────┼────────────┼───────────────────┼────────────┘
          │              │            │                   │
    ┌─────▼─────┐  ┌─────▼─────┐ ┌───▼────┐       ┌─────▼─────┐
    │   Loki    │  │   Mimir   │ │ Tempo  │       │  Mimir    │
    │  (logs)   │  │ (metrics) │ │(traces)│       │(span mets)│
    └─────▲─────┘  └─────▲─────┘ └───▲────┘       └─────▲─────┘
          │              │            │                   │
          │         ┌────┴────┐       │                   │
          │         │  Alloy  │       │                   │
          │         │  (OTLP) │───────┘                   │
          │         └────▲────┘                           │
          │              │                                │
     ┌────┴────┐    ┌────┴────────────────────────────────┘
     │  Alloy  │    │
     │(DaemonSet)   │
     └────▲────┘    │
          │         │
   ┌──────┴─────────┴──────┐
   │    Spring Boot Services │  (submission-service, ...)
   │    + Micrometer OTel    │
   └─────────────────────────┘
```

**Tóm tắt luồng:**
- **Logs**: Service ghi log JSON → Alloy DaemonSet thu thập → Loki lưu trữ → Grafana query
- **Metrics**: Service export OTLP metrics → Alloy OTel nhận → Mimir lưu trữ → Grafana query
- **Traces**: Service export OTLP traces → Alloy OTel nhận → Tempo lưu trữ → Grafana query
- **Correlation**: Grafana tự động link trace↔log qua `trace_id`

---

## 2. Kiến trúc hệ thống

### 2.1 Namespace

Tất cả components chạy trong namespace `observability`, tách biệt với business namespace `web-grading`.

```
k3s cluster
├── kube-system          (k3s built-in: Traefik, CoreDNS, etcd)
├── web-grading          (business services: submission-service, ...)
└── observability        (Grafana, Loki, Mimir, Tempo, Alloy)
```

### 2.2 Bảng tài nguyên ước tính

| Component | CPU Request | Memory Request | CPU Limit | Memory Limit | Storage |
|-----------|-------------|----------------|-----------|--------------|---------|
| Loki | 100m | 256Mi | 500m | 512Mi | 5Gi |
| Mimir | 200m | 512Mi | 1000m | 1Gi | 10Gi |
| Tempo | 100m | 256Mi | 500m | 512Mi | 5Gi |
| Alloy (DaemonSet) | 50m | 64Mi | 200m | 128Mi | — |
| Alloy-OTel (Deployment) | 100m | 128Mi | 300m | 256Mi | — |
| Grafana | 100m | 256Mi | 500m | 512Mi | 2Gi |
| **Tổng** | **550m** | **~1.2Gi** | **3Gi** | **~3Gi** | **22Gi** |

Tổng RAM request: ~1.2Gi, limit: ~3Gi. Trên cluster 8GB, còn lại ~5Gi cho business services + k3s system.

### 2.3 Deployment modes

| Component | Mode | Lý do |
|-----------|------|-------|
| Loki | **Monolithic** (single binary) | Đơn giản, đủ cho <10 service, tiết kiệm memory |
| Mimir | **Single binary** | Không dùng mimir-distributed (quá nặng cho 8GB) |
| Tempo | **Single binary** | Tương tự Mimir |
| Alloy (logs) | **DaemonSet** | Mỗi node 1 pod, collect logs từ tất cả pods trên node |
| Alloy (OTel) | **Deployment** | 1 pod duy nhất, nhận OTLP từ tất cả services |

---

## 3. Các công nghệ sử dụng

### 3.1 Grafana

**Phiên bản:** latest (Helm chart `grafana/grafana`)
**Vai trò:** Dashboard UI — là giao diện duy nhất để visualise logs, metrics, traces.

Grafana là open-source analytics & monitoring platform. Trong hệ thống này, Grafana đóng vai trò "trung tâm" — kết nối đến tất cả backends (Loki, Mimir, Tempo) và hiển thị dữ liệu trên các dashboard.

**Datasources được cấu hình tự động:**
- **Loki** — query logs bằng LogQL
- **Mimir** — query metrics bằng PromQL
- **Tempo** — query traces bằng TraceQL

**Dashboard provisioning:** Grafana sử dụng sidecar container để tự động load dashboard từ ConfigMaps có label `grafana_dashboard=1`. Khi bạn cập nhật ConfigMap, dashboard tự cập nhật trong vòng 30 giây.

### 3.2 Loki

**Phiên bản:** 3.1.1 (Helm chart `grafana/loki`, Monolithic mode)
**Vai trò:** Log aggregation — lưu trữ và query logs.

Loki là hệ thống log aggregation do Grafana Labs phát triển, thiết kế tương tự Prometheus nhưng dành cho logs. Khác với ELK Stack (Elasticsearch), Loki **không index nội dung logs** mà chỉ index metadata (labels), giúp tiết kiệm tài nguyên đáng kể.

**Đặc điểm kỹ thuật:**
- **Storage:** Filesystem (local disk) — chunks được lưu trên PVC
- **Schema:** TSDB (Time Series Database) — schema v13
- **Retention:** 7 ngày (168h), tự động xóa qua compactor
- **Query language:** LogQL — tương tự PromQL nhưng dành cho logs
- **Ingestion rate:** 10MB/s, burst 20MB
- **Max streams:** 10,000 streams per user

**Cách Loki lưu trữ logs:**
1. Logs được push lên Loki qua HTTP API (`/loki/api/v1/push`)
2. Loki gom logs thành **chunks** (thường 1 chunk = 1MB hoặc 1 giờ)
3. Chunks được compress và lưu vào filesystem (`/loki/chunks`)
4. Index (labels → chunks mapping) được lưu trong TSDB
5. Compactor chạy mỗi 10 phút, merge các chunks nhỏ và xóa data quá hạn

**LogQL basics:**
```logql
# Tìm tất cả logs từ namespace web-grading
{namespace="web-grading"}

# Tìm logs có chứa "ERROR"
{namespace="web-grading"} |= "ERROR"

# Tính log rate theo service
sum(rate({namespace="web-grading"} [5m])) by (pod)

# JSON parsing + filter
{namespace="web-grading"} | json | trace_id != ""
```

### 3.3 Mimir

**Phiên bản:** 2.12.0 (raw manifests, single-binary mode)
**Vai trò:** Metrics storage — lưu trữ và query metrics (Prometheus-compatible).

Mimir là hệ thống time-series database do Grafana Labs phát triển, tương thích hoàn toàn với Prometheus. Nó giải quyết các hạn chế của Prometheus đơn: horizontal scaling, multi-tenancy, và long-term storage.

**Đặc điểm kỹ thuật:**
- **Storage:** Filesystem (local disk) — blocks được lưu trên PVC
- **Ingestion:** OTLP (OpenTelemetry Protocol) — Alloy push metrics trực tiếp
- **Query API:** Prometheus-compatible (`/prometheus/api/v1/query`)
- **Retention:** 7 ngày (168h)
- **Max series:** 500,000 per user
- **Max cardinality:** 100,000

**Cách Mimir hoạt động (single-binary mode):**
```
Distributor → Ingester → Querier → Query Frontend
     │            │          │            │
     │            ▼          │            │
     │     TSDB (WAL)       │            │
     │            │          │            │
     │            ▼          │            │
     │     Filesystem        │            │
     │     (/mimir/blocks)   │            │
     │                       │            │
     └───────────────────────┘            │
              Compactor                   │
              (merge + retention)         │
                                          │
              Store Gateway ◄─────────────┘
              (block metadata cache)
```

Trong single-binary mode, tất cả các component trên chạy trong 1 process duy nhất với ring `inmemory` (không cần external KV store như etcd/Consul).

**PromQL basics:**
```promql
# Request rate theo service
sum(rate(traces_span_metrics_calls_total[5m])) by (service_name)

# Error rate
sum(rate(traces_span_metrics_calls_total{status_code="STATUS_CODE_ERROR"}[5m])) by (service_name)

# Duration P99
histogram_quantile(0.99, sum(rate(traces_span_metrics_latency_bucket[5m])) by (le, service_name))

# CPU usage theo pod
sum(rate(container_cpu_usage_seconds_total{namespace="web-grading"}[5m])) by (pod)
```

### 3.4 Tempo

**Phiên bản:** 2.6.1 (raw manifests, single-binary mode)
**Vai trò:** Distributed tracing backend — lưu trữ và query traces.

Tempo là hệ thống distributed tracing do Grafana Labs phát triển, thiết kế để nhận traces qua OTLP và lưu trữ hiệu quả. Khác với Jaeger/Zipkin, Tempo **không có built-in search** — nó dựa hoàn toàn vào Grafana + TraceQL để query.

**Đặc điểm kỹ thuật:**
- **Storage:** Filesystem (WAL + blocks)
- **Ingestion:** OTLP gRPC (port 4317) và OTLP HTTP (port 4318)
- **Query language:** TraceQL — query traces by service, operation, duration, tags
- **Metrics generation:** Tự động tạo span metrics (request rate, error rate, duration)
- **Service graphs:** Tự động tạo service dependency graph

**Cách Tempo lưu trữ traces:**
1. Traces được push lên Tempo qua OTLP (gRPC/HTTP)
2. Distributor nhận và validate traces
3. Ingester gom spans thành batches, write WAL (Write-Ahead Log)
4. WAL được flush thành blocks trên disk
5. Compactor merge blocks, xóa data quá hạn
6. Store Gateway cache block metadata cho querying

**Metrics generation từ traces:**
Tempo có thể tự động generate Prometheus metrics từ traces:
- `traces_span_metrics_calls_total` — request rate (RED metrics)
- `traces_span_metrics_latency_bucket` — duration histogram
- `traces_span_metrics_exceptions_total` — error count

Các metrics này được push đến Mimir, cho phép xem RED metrics trực tiếp trên Grafana mà không cần instrument thêm code.

**TraceQL basics:**
```traceql
# Tìm traces từ service "submission-service"
{ resource.service.name = "submission-service" }

# Tìm traces có error
{ status = error }

# Tìm traces chậm hơn 1s
{ duration > 1s }

# Tìm traces có HTTP method GET
{ span.http.method = "GET" }

# Kết hợp nhiều điều kiện
{ resource.service.name = "submission-service" && duration > 500ms && status = error }
```

### 3.5 Alloy

**Loại:** 2 instances — DaemonSet (logs) + Deployment (OTLP receiver)
**Vai trò:** Telemetry collector — thu thập logs, metrics, traces từ services và forward đến backends.

Alloy là unified telemetry collector do Grafana Labs phát triển, thay thế cho Grafana Agent + Promtail. Alloy hỗ trợ cả_metrics_, _logs_, và _traces_ trong một binary duy nhất, cấu hình bằng Alloy config syntax.

**Architecture:**

```
┌─────────────────────────────────────────────────────────────────┐
│                    Alloy (DaemonSet) — Log Collection            │
│                                                                  │
│  discovery.kubernetes.pods  →  loki.source.kubernetes            │
│  (tìm tất cả pods)           (thu thập logs)                     │
│                              │                                   │
│                              ▼                                   │
│                       loki.process.add_labels                    │
│                       (thêm cluster, environment labels)         │
│                              │                                   │
│                              ▼                                   │
│                       loki.write.default                         │
│                       (push đến Loki)                            │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                Alloy-OTel (Deployment) — OTLP Receiver           │
│                                                                  │
│  otelcol.receiver.otlp     →  otelcol.exporter.otlphttp.tempo  │
│  (nhận OTLP từ services)      (forward traces đến Tempo)        │
│                              │                                   │
│                              ├──► otelcol.exporter.otlphttp.mimir│
│                              │    (forward metrics đến Mimir)    │
│                              │                                   │
│                              └──► otelcol.processor.service_graph│
│                                   (generate RED metrics)        │
└─────────────────────────────────────────────────────────────────┘
```

**Port exposures:**

| Port | Protocol | Purpose |
|------|----------|---------|
| 12345 | HTTP | Alloy self-monitoring UI |
| 4317 | gRPC | OTLP gRPC receiver (services push traces/metrics) |
| 4318 | HTTP | OTLP HTTP receiver (services push traces/metrics) |

**Service discovery:**
Alloy tự động discover services và pods trong Kubernetes thông qua API server.它使用relabel rules để filter chỉ collect từ namespace `web-grading` và `observability`.

### 3.6 Micrometer + OpenTelemetry (Spring Boot side)

**Vai trò:** Instrument application code — tạo traces, metrics, và inject trace context vào logs.

Spring Boot 3+/4+ sử dụng **Micrometer Tracing** làm facade cho distributed tracing, với **OpenTelemetry** làm tracer implementation và export qua **OTLP**.

**Stack:**
```
Spring Boot Application
├── Micrometer Tracing (facade API)
│   └── micrometer-tracing-bridge-otel (bridge to OTel API)
├── OpenTelemetry SDK
│   └── opentelemetry-exporter-otlp (export via OTLP)
├── Micrometer Registry
│   └── micrometer-registry-otlp (export metrics via OTLP)
└── Spring Boot Actuator
    └── /actuator/prometheus (Prometheus scrape endpoint)
```

**Auto-instrumentation:**
Khi thêm dependencies, Spring Boot tự động tạo traces cho:
- HTTP requests (incoming & outgoing)
- Database queries (JDBC, R2DBC, JPA)
- HTTP clients (RestTemplate, WebClient, RestClient)
- Message listeners (Kafka, RabbitMQ)
- Scheduled tasks (@Scheduled)

**MDC injection:**
Micrometer tự động inject vào MDC (Mapped Diagnostic Context):
- `traceId` — unique ID cho toàn bộ distributed trace
- `spanId` — unique ID cho span hiện tại
- `traceFlags` — trace sampling flags

Khi dùng `logback-spring.xml` với `%X{traceId}` và `%X{spanId}`, mỗi dòng log sẽ chứa trace context, cho phép correlation giữa logs và traces.

---

## 4. Luồng dữ liệu Logs

### 4.1 Chi tiết luồng

```
1. Service ghi log (Logback → JSON format)
   {
     "timestamp": "2025-01-15T10:30:00Z",
     "level": "INFO",
     "service": "submission-service",
     "trace_id": "abc123def456",
     "span_id": "789ghi012",
     "message": "Processing submission",
     ...
   }
         │
         ▼
2. Log được ghi ra stdout/stderr
   Kubernetes container runtime bắt stdout
         │
         ▼
3. Alloy DaemonSet (mỗi node 1 pod)
   - Đọc log từ /var/log/pods/ (hoặc Docker container logs)
   - discovery.kubernetes.pods tự discover tất cả pods
   - loki.source.kubernetes thu thập logs
   - relabel_rules filter: chỉ lấy namespace web-grading + observability
         │
         ▼
4. Alloy process logs
   - loki.process.add_labels: thêm labels static (cluster, environment)
   - Label namespace, pod, container, service được extract từ k8s metadata
         │
         ▼
5. Alloy push logs đến Loki
   - HTTP POST đến http://loki.observability.svc.cluster.local:3100/loki/api/v1/push
   - Batch logs thành entries trước khi push (efficiency)
         │
         ▼
6. Loki nhận và lưu trữ
   - Distributor validate logs
   - Ingester gom logs thành chunks (1 chunk ≈ 1MB hoặc 1 giờ)
   - Chunks được compress (Snappy) và write vào filesystem
   - TSDB index được cập nhật (labels → chunks mapping)
         │
         ▼
7. Compactor chạy mỗi 10 phút
   - Merge các chunks nhỏ thành chunks lớn hơn
   - Xóa data quá hạn (retention: 7 ngày)
         │
         ▼
8. Grafana query logs
   - User mở Grafana → Explore → Loki
   - Query LogQL: {namespace="web-grading", service="submission-service"} |= "ERROR"
   - Querier đọc chunks từ filesystem, filter theo labels + content
   - Kết quả trả về dạng log lines với highlighted matches
```

### 4.2 Log format

Logs được lưu dưới dạng structured JSON, mỗi log entry có:

```json
{
  "@timestamp": "2025-01-15T10:30:00.123Z",
  "level": "INFO",
  "service": "submission-service",
  "environment": "staging",
  "trace_id": "abc123def45678901234567890123456",
  "span_id": "7890123456789012",
  "trace_flags": "01",
  "message": "Processing submission id=123",
  "logger_name": "vn.edu.ptit.web_grading_system.submission_service.service.SubmissionService",
  "thread_name": "http-nio-8082-exec-1",
  "stack_trace": null
}
```

**Các field quan trọng:**
- `trace_id` + `span_id`: Dùng cho trace↔log correlation
- `service`: Tên service (từ `spring.application.name`)
- `namespace`, `pod`, `container`: Kubernetes metadata (thêm bởi Alloy)

### 4.3 Label indexing

Loki không index nội dung logs, chỉ index **labels**. Mỗi log stream được định danh bởi bộ labels:

```
{namespace="web-grading", pod="submission-service-abc123", container="submission-service", service="submission-service", cluster="k3s-local", environment="staging"}
```

**Lưu ý quan trọng:**
- Labels cardinality phải thấp. Nếu mỗi log có label unique (ví dụ `request_id`), sẽ tạo quá many streams
- Nội dung logs chỉ được filter khi query (full-text scan), không phải khi ingest
- Do đó, Loki tiết kiệm resources hơn Elasticsearch đáng kể, nhưng query chậm hơn trên lượng data lớn

---

## 5. Luồng dữ liệu Metrics

### 5.1 Chi tiết luồng

```
1. Spring Boot Actuator export metrics
   - /actuator/prometheus (Prometheus format)
   - OTLP export qua micrometer-registry-otlp
         │
         ▼
2. Service push metrics qua OTLP HTTP
   - POST http://alloy-otel.observability.svc.cluster.local:4318/v1/metrics
   - Metrics data theo OpenTelemetry protobuf format
         │
         ▼
3. Alloy-OTel nhận metrics
   - otelcol.receiver.otlp (port 4318) nhận OTLP metrics
   - otelcol.exporter.otlphttp.mimir forward đến Mimir
         │
         ▼
4. Mimir nhận và lưu trữ
   - Distributor validate metrics
   - Ingester gom metrics thành WAL → blocks
   - TSDB index được cập nhật
         │
         ▼
5. Compactor chạy mỗi 15 phút
   - Merge blocks
   - Xóa data quá hạn (retention: 7 ngày)
         │
         ▼
6. Grafana query metrics
   - User mở Grafana → Explore → Mimir
   - Query PromQL: rate(container_cpu_usage_seconds_total{namespace="web-grading"}[5m])
   - Querier đọc blocks từ filesystem
   - Kết quả trả về dạng time series
```

### 5.2 Span-based metrics (từ traces)

Ngoài metrics từ Actuator, Alloy-OTel còn tự động generate RED metrics từ traces:

```
1. Service gửi traces (OTLP) đến Alloy-OTel
         │
         ▼
2. otelcol.processor.span tạo span metrics
   - traces_span_metrics_calls_total (counter: request rate)
   - traces_span_metrics_latency_bucket (histogram: duration)
   - traces_span_metrics_exceptions_total (counter: error rate)
         │
         ▼
3. otelcol.processor.service_graph tạo service graph metrics
   - traces_service_graph_request_total
   - traces_service_graph_request_milliseconds
         │
         ▼
4. Metrics được push đến Mimir
   - Query: sum(rate(traces_span_metrics_calls_total[5m])) by (service_name)
   - Cho phép xem request rate theo operation mà không cần instrument thêm code
```

### 5.3 Kubernetes metrics

Alloy DaemonSet cũng scrape metrics từ Kubernetes:

- **Pod metrics:** `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`
- **Service metrics:** Từ annotation `prometheus.io/scrape: "true"`
- **Alloy self-monitoring:** Metrics của chính Alloy

---

## 6. Luồng dữ liệu Traces

### 6.1 Chi tiết luồng

```
1. Spring Boot tạo span
   - HTTP request incoming → span created (自动)
   - Database query → child span created (自动)
   - HTTP outgoing → child span created (自动)
   - Mỗi span chứa: trace_id, span_id, operation name, duration, status, tags
         │
         ▼
2. Span processor batch spans
   - OpenTelemetry SDK gom spans thành batches
   - BatchSpanProcessor flush mỗi 5s hoặc khi batch đủ 512 spans
         │
         ▼
3. OtlpHttpSpanExporter export
   - POST http://alloy-otel.observability.svc.cluster.local:4318/v1/traces
   - Traces data theo OpenTelemetry protobuf format
         │
         ▼
4. Alloy-OTel nhận traces
   - otelcol.receiver.otlp (port 4318) nhận OTLP traces
   - otelcol.exporter.otlphttp.tempo forward đến Tempo
         │
         ▼
5. Tempo nhận và lưu trữ
   - Distributor validate traces
   - Ingester gom spans thành batches
   - WAL (Write-Ahead Log) được write
   - WAL flush thành blocks trên disk
         │
         ▼
6. Metrics generation (song song)
   - otelcol.processor.span tạo span metrics → Mimir
   - otelcol.processor.service_graph tạo service graph metrics → Mimir
         │
         ▼
7. Compactor chạy mỗi 5 phút
   - Merge blocks
   - Xóa data quá hạn (retention: 7 ngày)
         │
         ▼
8. Grafana query traces
   - User mở Grafana → Explore → Tempo
   - Native Search: filter theo service, operation, duration, tags
   - TraceQL: { resource.service.name = "submission-service" && duration > 1s }
   - Kết quả: danh sách traces, click để xem span tree
```

### 6.2 Span structure

Mỗi span chứa:

```json
{
  "traceID": "abc123def45678901234567890123456",
  "spanID": "7890123456789012",
  "parentSpanID": "fedcba9876543210",
  "operationName": "POST /api/submissions",
  "serviceName": "submission-service",
  "startTime": "2025-01-15T10:30:00.123Z",
  "duration": 250,
  "tags": {
    "http.method": "POST",
    "http.url": "/api/submissions",
    "http.status_code": 201,
    "db.system": "postgresql",
    "db.statement": "INSERT INTO submissions ...",
    "net.peer.name": "database-host"
  },
  "logs": [
    {
      "timestamp": "2025-01-15T10:30:00.200Z",
      "fields": {
        "event": "Processing completed",
        "error": false
      }
    }
  ]
}
```

### 6.3 Sampling

Sampling quyết định bao nhiêu traces được lưu trữ:

```yaml
management:
  tracing:
    sampling:
      probability: 1.0  # 100% — giữ tất cả traces (dev/staging)
      # probability: 0.1  # 10% — chỉ lưu 10% traces (production)
```

**Chiến lược sampling:**
- **Dev/Staging:** `1.0` (100%) — cần xem tất cả traces để debug
- **Production low-traffic:** `0.5` (50%) — cân bằng giữa visibility và storage
- **Production high-traffic:** `0.1` (10%) — tiết kiệm storage, vẫn bắt được errors
- **Head-based sampling:** Sampler quyết định ngay khi span tạo (không cần biết trace đầy đủ)
- **Tail-based sampling:** Sampler quyết định sau khi trace hoàn thành (cần backend support)

---

## 7. Trace ↔ Log Correlation

### 7.1 Cách correlation hoạt động

```
┌─────────────────────────────────────────────────────────────────┐
│                        Grafana UI                                │
│                                                                  │
│  ┌─────────────────┐     ┌─────────────────────────────────┐    │
│  │  Tempo (Traces)  │────►│  "View logs" button              │    │
│  │                  │     │  → nhảy sang Loki, filter theo   │    │
│  │  Click 1 span   │     │    trace_id = "abc123..."        │    │
│  └─────────────────┘     └─────────────────────────────────┘    │
│                                                                  │
│  ┌─────────────────┐     ┌─────────────────────────────────┐    │
│  │  Tempo (Traces)  │────►│  "Derived metrics" button        │    │
│  │                  │     │  → nhảy sang Mimir, query RED    │    │
│  │  Click 1 span   │     │    metrics cho operation đó      │    │
│  └─────────────────┘     └─────────────────────────────────┘    │
│                                                                  │
│  ┌─────────────────┐     ┌─────────────────────────────────┐    │
│  │  Loki (Logs)     │────►│  Click trace_id trong log       │    │
│  │                  │     │  → nhảy sang Tempo, xem trace    │    │
│  │  Log stream     │     │    tree đầy đủ                   │    │
│  └─────────────────┘     └─────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 Điều kiện để correlation hoạt động

1. **Logs phải có `trace_id` và `span_id`**
   - Spring Boot: Micrometer tự động inject vào MDC
   - Logback: `%X{traceId}` và `%X{spanId}` trong log pattern
   - Structured logging (JSON): `trace_id` và `span_id` là fields riêng

2. **Logs phải được parse bởi Loki**
   - Alloy phải extract `trace_id` field từ logs
   - Hoặc logs phải dạng JSON với field `trace_id`

3. **Grafana Tempo datasource phải cấu hình đúng**
   ```yaml
   tracesToLogsV2:
     datasourceUid: Loki
     filterByTraceID: true
   tracesToMetrics:
     datasourceUid: Mimir
   ```

### 7.3 Flow sử dụng trên Grafana

**Xem trace từ log:**
1. Mở Grafana → Explore → Loki
2. Query: `{namespace="web-grading"} | json | trace_id != ""`
3. Click vào log entry → xem field `trace_id`
4. Copy `trace_id` → Explore → Tempo → paste vào search
5. Xem span tree đầy đủ của request đó

**Xem logs từ trace:**
1. Mở Grafana → Explore → Tempo
2. Search traces: service = "submission-service", duration > 1s
3. Click vào 1 trace → xem span tree
4. Click vào span → button "View logs"
5. Tự nhảy sang Loki, filter log theo `trace_id` và `span_id` của span đó

**Xem metrics từ trace:**
1. Mở Grafana → Explore → Tempo
2. Click vào span → button "Derived metrics"
3. Tự nhảy sang Mimir, query RED metrics cho operation đó
4. Xem request rate, error rate, duration P99

---

## 8. Spring Boot — Cấu hình chi tiết

### 8.1 Dependencies (pom.xml)

**Spring Boot 4.x:**
```xml
<!-- OpenTelemetry starter (bao gồm micrometer-tracing + OTLP exporter) -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-opentelemetry</artifactId>
</dependency>

<!-- Actuator (metrics endpoint + health check) -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
```

**Spring Boot 3.x:**
```xml
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-tracing-bridge-otel</artifactId>
</dependency>
<dependency>
    <groupId>io.opentelemetry</groupId>
    <artifactId>opentelemetry-exporter-otlp</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
```

### 8.2 application.yaml

```yaml
spring:
  application:
    name: submission-service  # Tên service, hiển thị trong traces

management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
  tracing:
    enabled: true
    sampling:
      probability: 1.0  # 100% (dev). Giảm xuống 0.1-0.3 cho prod
  otlp:
    tracing:
      endpoint: http://alloy-otel.observability.svc.cluster.local:4318/v1/traces
      transport: http
    metrics:
      export:
        url: http://alloy-otel.observability.svc.cluster.local:4318/v1/metrics
        step: 30s

logging:
  pattern:
    level: "%5p [${spring.application.name:},%X{traceId:-},%X{spanId:-}]"
```

### 8.3 logback-spring.xml

```xml
<configuration>
    <springProperty scope="context" name="APP_NAME" source="spring.application.name"/>
    <springProperty scope="context" name="APP_ENV" source="spring.profiles.active"/>

    <appender name="JSON" class="ch.qos.logback.core.ConsoleAppender">
        <encoder class="net.logstash.logback.encoder.LogstashEncoder">
            <includeMdcKeyName>trace_id</includeMdcKeyName>
            <includeMdcKeyName>span_id</includeMdcKeyName>
            <includeMdcKeyName>trace_flags</includeMdcKeyName>
            <customFields>
                {"service":"${APP_NAME}","environment":"${APP_ENV}"}
            </customFields>
        </encoder>
    </appender>

    <root level="INFO">
        <appender-ref ref="JSON"/>
    </root>
</configuration>
```

### 8.4 Verification

Sau khi deploy, kiểm tra:

```bash
# 1. Kiểm tra logs có trace_id không
kubectl logs -n web-grading -l app=submission-service --tail=5 | grep trace_id

# 2. Kiểm tra metrics endpoint
kubectl port-forward -n web-grading svc/submission-service 8082:8082
curl http://localhost:8082/actuator/prometheus | grep traces_span_metrics

# 3. Kiểm tra traces trong Tempo
kubectl port-forward -n observability svc/tempo 3200:3200
curl http://localhost:3200/api/traces/search?service=submission-service
```

---

## 9. Grafana Dashboard

### 9.1 Dashboard layout

Dashboard "General — All Services" có các sections:

| Section | Panels | Datasource |
|---------|--------|------------|
| **Cluster Overview** | Total Pods, Running Pods, Running Deployments, CPU%, Memory%, Not Ready Pods | Mimir |
| **CPU & Memory by Service** | CPU Usage by Pod, Memory Usage by Pod | Mimir |
| **Logs** | Log Volume by Service, Log Volume by Container, Log Stream | Loki |
| **Traces & Service Map** | Service Map (node graph), Request Rate, Error Rate, Duration P99 | Tempo + Mimir |
| **Trace Search** | Trace Search (Tempo native search) | Tempo |
| **Trace ↔ Log Correlation** | Logs with Traces, Trace-derived RED Metrics, Correlated Logs | Loki + Mimir |

### 9.2 Template variables

| Variable | Type | Purpose |
|----------|------|---------|
| `$namespace` | Query | Filter theo namespace (default: All) |
| `$service` | Query | Filter theo service/pod (default: All) |
| `$filter` | Textbox | LogQL filter thêm vào log stream |
| `$DS_MIMIR` | Datasource | Chọn Prometheus datasource |
| `$DS_LOKI` | Datasource | Chọn Loki datasource |
| `$DS_TEMPO` | Datasource | Chọn Tempo datasource |

### 9.3 How to add new dashboard

Khi muốn thêm dashboard mới cho service riêng:

1. Tạo file JSON trong `dashboards/`
2. Thêm label `grafana_dashboard: "1"` khi tạo ConfigMap
3. Service name phải match `spring.application.name` trong service

Ví dụ thêm dashboard cho submission-service:
```bash
kubectl create configmap grafana-dashboards-submission \
  --from-file=submission-service.json=dashboards/submission-service.json \
  -n observability \
  --dry-run=client -o yaml | \
  sed 's/^  labels:/  labels:\n    grafana_dashboard: "1"/' | kubectl apply -f -
```

---

## 10. Cloudflare Tunnel

### 10.1 Tại sao cần cloudflared

- K3s chạy trên máy local (8GB RAM), không có public IP
- Cloudflare Tunnel tạo encrypted tunnel từ cloudflared → Cloudflare edge → user
- Không cần mở port trên router/firewall
- Được SSL/TLS certificate miễn phí

### 10.2 Flow traffic

```
User (trình duyệt)
    │
    ▼ HTTPS
Cloudflare Edge (vucongtuanduong.dpdns.org)
    │
    ▼ Encrypted Tunnel
cloudflared (container, network_mode: host)
    │
    ▼ HTTP
localhost:30566 (Traefik NodePort)
    │
    ▼ Ingress routing
Traefik → Ingress rule → Service → Pod
```

### 10.3 DNS routing

M mỗi service có 1 subdomain riêng:

| Service | Subdomain |
|---------|-----------|
| API Gateway | `web-dev1-api.vucongtuanduong.dpdns.org` |
| Grafana | `web-dev1-grafana.vucongtuanduong.dpdns.org` |
| Keycloak | `web-dev1-keycloak.vucongtuanduong.dpdns.org` |
| ArgoCD | `web-dev1-argocd.vucongtuanduong.dpdns.org` |
| RustFS | `web-dev1-rustfs.vucongtuanduong.dpdns.org` |

Pattern: `web-dev1-{service}.vucongtuanduong.dpdns.org`

### 10.4 Tại sao không expose Loki/Mimir/Tempo

- Cloudflare Free plan có bandwidth limit
- Loki/Mimir/Tempo là internal services, chỉ Grafana truy cập
- Grafana sống trong cùng cluster, dùng Kubernetes service DNS
- Expose thêm sẽ tăng surface area attack không cần thiết

---

## 11. Quản lý tài nguyên

### 11.1 Memory budget cho 8GB RAM

```
Total RAM: 8192 MiB
├── k3s system (kube-apiserver, etcd, kubelet, etc.): ~1.5Gi
├── Traefik (ingress controller): ~256Mi
├── Business services (web-grading namespace): ~2Gi
└── Observability stack: ~3Gi
    ├── Loki: 512Mi
    ├── Mimir: 1Gi
    ├── Tempo: 512Mi
    ├── Alloy (DaemonSet): 128Mi
    ├── Alloy-OTel (Deployment): 256Mi
    └── Grafana: 512Mi
```

### 11.2 Disk usage

| Component | Storage | Growth rate | Retention |
|-----------|---------|-------------|-----------|
| Loki | 5Gi | ~100MB/day (10 service) | 7 days |
| Mimir | 10Gi | ~200MB/day | 7 days |
| Tempo | 5Gi | ~50MB/day | 7 days |
| **Total** | **20Gi** | **~350MB/day** | — |

### 11.3 Scaling considerations

Khi thêm service mới:
- **Logs:** Mỗi service ~10-50 new log streams. Loki limit: 10,000 streams
- **Metrics:** Mỗi service ~100-500 new time series. Mimir limit: 500,000 series
- **Traces:** Mỗi request = 1 trace. Sampling 10% → ~10% storage increase

Khi đạt giới hạn, cần:
- Tăng resources cho observability stack
- Hoặc migrate sang Mimir distributed mode (microservices)
- Hoặc migrate Loki sang Simple Scalable mode

---

## 12. Thêm service mới

### 12.1 Checklist

Khi thêm service Spring Boot mới vào hệ thống:

```
□ 1. pom.xml
   ├── spring-boot-starter-opentelemetry (hoặc micrometer-tracing-bridge-otel + opentelemetry-exporter-otlp)
   └── spring-boot-starter-actuator

□ 2. application.yaml
   ├── spring.application.name: {service-name}
   ├── management.tracing.enabled: true
   ├── management.otlp.tracing.endpoint: http://alloy-otel.observability.svc.cluster.local:4318/v1/traces
   └── management.otlp.metrics.export.url: http://alloy-otel.observability.svc.cluster.local:4318/v1/metrics

□ 3. logback-spring.xml (copy từ template)

□ 4. Kubernetes Deployment
   └── Thêm annotation:
       annotations:
         prometheus.io/scrape: "true"
         prometheus.io/port: "8080"

□ 5. Không cần thay đổi observability stack
   ├── Alloy DaemonSet tự discover pods mới
   ├── Alloy OTel tự nhận traces từ service mới
   └── Dashboard tự hiển thị service mới (qua kube_pod_info)
```

### 12.2 Verification

Sau khi deploy service mới:

```bash
# Kiểm tra traces xuất hiện trong Tempo
kubectl port-forward -n observability svc/tempo 3200:3200
curl "http://localhost:3200/api/traces/search?service=new-service&limit=5"

# Kiểm tra metrics xuất hiện trong Mimir
kubectl port-forward -n observability svc/mimir 9009:9009
curl "http://localhost:9009/prometheus/api/v1/query?query=up{job='new-service'}"

# Kiểm tra logs xuất hiện trong Loki
kubectl port-forward -n observability svc/loki 3100:3100
curl -G "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="web-grading", service="new-service"}' \
  --data-urlencode 'limit=5'
```

---

## 13. Troubleshooting

### 13.1 Không có traces trong Tempo

```
□ Kiểm tra service có export OTLP không:
  kubectl logs -n web-grading -l app={service} | grep -i "otlp\|opentelemetry"

□ Kiểm tra Alloy-OTel nhận được traces không:
  kubectl logs -n observability -l app=alloy-otel | grep -i "traces"

□ Kiểm tra Tempo có nhận data không:
  kubectl logs -n observability -l app=tempo | grep -i "push\|ingest"

□ Kiểm tra endpoint OTLP có đúng không:
  kubectl exec -n web-grading {pod} -- curl -s http://alloy-otel.observability.svc.cluster.local:4318/v1/traces
```

### 13.2 Không có logs trong Loki

```
□ Kiểm tra Alloy DaemonSet có chạy không:
  kubectl get pods -n observability -l app=alloy

□ Kiểm tra Alloy có collect logs không:
  kubectl logs -n observability -l app=alloy --tail=50 | grep -i "loki"

□ Kiểm tra Loki có nhận data không:
  kubectl logs -n observability -l app=loki | grep -i "push\|ingest"

□ Kiểm tra log format (có JSON không):
  kubectl logs -n web-grading -l app={service} --tail=5 | head -5
```

### 13.3 Không có metrics trong Mimir

```
□ Kiểm tra service có expose metrics không:
  kubectl port-forward -n web-grading svc/{service} 8080:8080
  curl http://localhost:8080/actuator/prometheus

□ Kiểm tra Alloy có scrape metrics không:
  kubectl logs -n observability -l app=alloy | grep -i "scrape\|metrics"

□ Kiểm tra Mimir có nhận data không:
  kubectl port-forward -n observability svc/mimir 9009:9009
  curl "http://localhost:9009/prometheus/api/v1/query?query=up"
```

### 13.4 Grafana không load dashboard

```
□ Kiểm tra ConfigMap có label đúng không:
  kubectl get configmap grafana-dashboards -n observability -o yaml | grep grafana_dashboard

□ Kiểm tra Grafana sidecar có log error không:
  kubectl logs -n observability -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard

□ Kiểm tra dashboard JSON có hợp lệ không:
  python3 -m json.tool dashboards/k8s-general.json
```

### 13.5 Grafana không accessible qua cloudflared

```
□ Kiểm tra Grafana ingress:
  kubectl get ingress -n observability
  kubectl describe ingress grafana -n observability

□ Kiểm tra Traefik có route đúng không:
  curl -H "Host: web-dev1-grafana.vucongtuanduong.dpdns.org" http://localhost:30566

□ Kiểm tra cloudflared config:
  cat ~/.cloudflared/config.yml | grep grafana

□ Kiểm tra DNS routing:
  cloudflared tunnel route dns web-dev1-web-grading web-dev1-grafana.vucongtuanduong.dpdns.org
```

---

## A. Links tham khảo

- [Grafana Loki Documentation](https://grafana.com/docs/loki/latest/)
- [Grafana Mimir Documentation](https://grafana.com/docs/mimir/latest/)
- [Grafana Tempo Documentation](https://grafana.com/docs/tempo/latest/)
- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/latest/)
- [Spring Boot Micrometer Tracing](https://docs.spring.io/spring-boot/reference/actuator/tracing.html)
- [OpenTelemetry Specification](https://opentelemetry.io/docs/specs/)
- [TraceQL Reference](https://grafana.com/docs/tempo/latest/traceql/)
- [LogQL Reference](https://grafana.com/docs/loki/latest/query/)
- [PromQL Reference](https://prometheus.io/docs/prometheus/latest/querying/basics/)
