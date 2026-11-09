# Cấu hình Tempo + Grafana cho trace streaming

## Vấn đề

Grafana Explore时报 lỗi khi query TraceQL qua datasource Tempo:

```
gRPC streaming call failed: rpc error: code = Unavailable desc =
connection error: desc = "error reading server preface: http2: failed
reading the frame payload: http2: frame too large, note that the frame
header looked like an HTTP/1.1 header"
```

HTTP query (`queryData`, `/api/search`) vẫn OK (được 500+ traces), nhưng Grafana Tempo plugin vẫn cố mở **gRPC stream** cho tính năng "live search". Tempo 2.10.8 (chart v2.4.0) expose gRPC trên port 9095, nhưng port 3200 (URL datasource) chỉ trả **HTTP/1.1**, vì `stream_over_http_enabled` mặc định là `false`. Grafana Tempo plugin không có setting `grpc.address` — nó luôn dial gRPC vào chính URL datasource (port 3200), nên mọi lần thêm `grpc.address` đều bị bỏ qua.

## Root cause

Tempo config chạy với:

```
stream_over_http_enabled: false
```

→ Port 3200 là HTTP/1.1 thuần. Grafana mở gRPC/h2c vào port này → mismatch khung HTTP/2 → lỗi `frame too large`.

## Thay đổi

### 1. `deploy/observability/charts/tempo-values.yaml`

Ghi toàn bộ cấu hình vào block `tempo:` (chart `grafana/tempo` v2.4.0 chỉ đọc `config:` render từ `tempo.*`; các khóa cấp gốc như `server:`, `distributor:` bị bỏ qua im lặng).

```yaml
tempo:
  ...
  # Bắt buộc để Grafana streaming TraceQL hoạt động.
  streamOverHttpEnabled: true

  metricsGenerator:
    enabled: true
    # Prometheus của kube-prometheus-stack đã bật enableRemoteWriteReceiver.
    remoteWriteUrl: "http://monitoring-kube-prometheus-prometheus.observability.svc.cluster.local:9090/api/v1/write"

persistence:
  enabled: true
  storageClassName: local-path
  size: 2Gi

serviceMonitor:
  enabled: false
```

Lưu ý: `metricsGenerator.enabled` đã đúng là nằm trong `tempo:` (không phải cấp gốc), giữ nguyên. `remoteWriteUrl` trỏ đúng Prometheus trong namespace `observability` thay vì giá trị mặc định `prometheus.monitoring` (không tồn tại).

### 2. `deploy/observability/charts/kube-prometheus-stack-values.yaml`

Gán lại cấu hình Grafana Tempo datasource, **xóa `grpc.address`** (bị bỏ qua), **bật lại streaming**:

```yaml
    - name: Tempo
      type: tempo
      uid: tempo
      access: proxy
      url: http://tempo.observability.svc.cluster.local:3200
      editable: false
      jsonData:
        tracesToMetrics:
          datasourceUid: prometheus
        streamingEnabled:
          search: true
          metrics: false
```

### 3. Redeploy

```bash
helm upgrade --install tempo /tmp/tempo-2.4.0.tgz -n observability \
  -f deploy/observability/charts/tempo-values.yaml --wait --timeout 5m

helm upgrade --install monitoring /tmp/kube-prometheus-stack-92.11.0.tgz -n observability \
  -f deploy/observability/charts/kube-prometheus-stack-values.yaml --wait --timeout 10m
```

## Kết quả kiểm chứng

| Item | Kết quả |
|------|---------|
| `stream_over_http_enabled` trong configmap tempo | `true` ✓ |
| HTTP/2 trên port 3200 | `HTTP version: 2, status: 200` ✓ |
| Tempo pod | 1/1 Running, `grpc=[::]:9095`, `http=[::]:3200` ✓ |
| Grafana datasource ConfigMap | không khai báo `grpc.address`, `streamingEnabled.search: true` ✓ |
| `queryData` status | `ok` ✓ |
| Grafana log lỗi `http2: frame too large` | Không còn mới sau restart ✓ |
| Traces Drilldown "Span rate" | có dữ liệu (span metrics remote-write sang Prometheus) ✓ |

Ghi chú về `grpc.address`: ConfigMap provisioning không còn khai báo field
này, nhưng Grafana DB vẫn có thể giữ giá trị cũ từ lần tạo datasource trước
(provisioned datasource không xóa được field qua API, DELETE trả 403). Tempo
plugin dial gRPC/h2c trên chính URL datasource (port 3200), không đọc
`jsonData.grpc.address`, nên giá trị cũ không ảnh hưởng streaming. Muốn sạch
hẳn thì xóa datasource trong Grafana DB thủ công rồi restart pod.

## Span rate / Traces Drilldown

"Span rate" không đọc trace storage trực tiếp; nó query Prometheus các series
do Tempo metrics-generator sinh ra (`traces_spanmetrics_*`,
`traces_service_graph_*`). Vì vậy Tempo phải chạy metrics-generator với:

```yaml
tempo:
  metricsGenerator:
    enabled: true
    remoteWriteUrl: "http://monitoring-kube-prometheus-prometheus.observability.svc.cluster.local:9090/api/v1/write"
    processor:
      span_metrics: { enable_target_info: true }
      service_graphs: { wait: 10s }
      local_blocks: { flush_to_storage: true }
  overrides:
    defaults:
      metrics_generator:
        processors: [service-graphs, span-metrics, local-blocks]
```

Thiếu `processors` thì Prometheus rỗng ("Span rate: No data"); thiếu
`local-blocks` thì Drilldown báo `localblocks processor not found`. Kiểm tra:

```bash
kubectl -n observability port-forward svc/tempo 3200:3200
curl -s 'http://127.0.0.1:3200/metrics' | grep tempo_metrics_generator | head

kubectl -n observability port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
curl -s 'http://127.0.0.1:9090/api/v1/query?query=count(traces_spanmetrics_calls_total)'
```

## Lời khuyên khi dùng Grafana UI

Truy cập đúng domain (Traefik, không có Cloudflare tunnel):

```
https://web-dev2-grafana.vucongtuanduong.dpdns.org/a/grafana-exploretraces-app/explore
```

- Chọn datasource **Tempo**.
- Hard refresh trình duyệt (Ctrl+F5) để nạp cấu hình datasource mới.
- TraceQL mẫu:
  - `{resource.service.name != nil}` — tất cả traces
  - `{resource.service.name != nil && span.http.target != "/actuator/health"}` — lọc bỏ actuator
  - `{resource.service.name != nil} | rate() by(resource.service.name)` — tỷ lệ theo service (cần metrics generator đã bật)

Nếu chưa thấy traces từ business operations, hãy tạo traffic trên web app (tạo assignment, submit bài…) rồi refresh Grafana Explore.

## Files đã sửa

- `deploy/observability/charts/tempo-values.yaml`
- `deploy/observability/charts/kube-prometheus-stack-values.yaml`
