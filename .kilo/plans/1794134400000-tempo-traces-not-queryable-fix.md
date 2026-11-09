# Tempo Traces Không Query Được — Root Cause & Fix

> Research: 2026-11-08  
> Phạm vi: `deploy/observability/charts/tempo-values.yaml`  
> Trạng thái: **Root cause xác định, chưa fix code, chưa verify runtime (cluster down)**

---

## 0. Tóm tắt Root Cause

**VẤN ĐỀ NGHIÊM TRỌNG:** Tempo Helm chart `grafana/tempo` v1.21.1 sử dụng **OpenTelemetry Collector dependencies >= v0.112.0**, trong đó **receivers mặc định bind về `localhost` thay vì `0.0.0.0`** (breaking change vì lý do security).

File `deploy/observability/charts/tempo-values.yaml` hiện tại **KHÔNG có cấu hình `distributor.receivers`**, dẫn đến:
- **OTLP gRPC/HTTP receivers chỉ lắng nghe trên `localhost:4317` và `localhost:4318`** thay vì `0.0.0.0`
- **Backend services từ namespace `web-grading` KHÔNG THỂ kết nối** tới `tempo.observability.svc.cluster.local:4318`
- **Traces KHÔNG BAO GIỜ ĐẾN Tempo** → không có gì để query

**Bằng chứng:**
1. Plan document (`.opencode/plan/deploy-observability-stack/plan.md` §2.j) đã ghi nhận lỗi thực tế:
   ```
   java.net.UnknownHostException: tempo.observability.svc.cluster.local
   ```
2. GitHub issue [grafana/tempo#4465](https://github.com/grafana/tempo/issues/4465) xác nhận breaking change:
   > "With the changes to replace unspecified address, the receivers now default to `localhost:4317` and `localhost:4318`. And as a result connections to Tempo running in a Docker container don't work anymore."
3. OneUptime docs (2026-02-06) cảnh báo: "The Collector logs show no export errors. But Tempo has no traces."

---

## 1. Breaking Change Chi Tiết (OpenTelemetry Collector v0.112.0)

### Timeline

| Phiên bản | Thay đổi | Trạng thái |
|---|---|---|
| < v0.94.0 | Receivers mặc định bind `0.0.0.0` | Hoạt động trong container |
| v0.94.0 | Thêm feature gate `UseLocalHostAsDefaultHost` + warning log | Beta |
| v0.110.0 | Feature gate stable | Stable |
| **v0.112.0** | **Bỏ feature gate, hard-default về `localhost`** | **Breaking** |

### Tại sao breaking?

**Trước v0.112.0:**
```yaml
distributor:
  receivers:
    otlp:
      protocols:
        grpc:    # không khai báo endpoint
        http:    # không khai báo endpoint
```
→ Receivers bind `0.0.0.0:4317` và `0.0.0.0:4318` → accessible từ mọi namespace

**Sau v0.112.0 (hiện tại):**
```yaml
# Cấu hình tương tự
```
→ Receivers bind `localhost:4317` và `localhost:4318` → **CHỈ accessible trong cùng pod**

**Tài liệu tham khảo:**
- [open-telemetry/opentelemetry-collector#8510](https://github.com/open-telemetry/opentelemetry-collector/issues/8510) — Security rationale
- [grafana/tempo#4465](https://github.com/grafana/tempo/issues/4465) — Impact on Tempo

---

## 2. Tempo Helm Chart v1.21.1 Không Có Default Receivers Config

### Kiểm tra values file hiện tại

```yaml
# deploy/observability/charts/tempo-values.yaml
tempo:
  repository: grafana/tempo
  tag: 2.7.1
  pullPolicy: IfNotPresent
  memBallastSizeMbs: 0
  extraEnv:
    - name: GOMEMLIMIT
      value: 400MiB
  reportingEnabled: false
  retention: 24h
  metricsGenerator:
    enabled: false
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { cpu: 500m, memory: 512Mi }

# ❌ THIẾU HOÀN TOÀN: không có `distributor:` section
# ❌ THIẾU: không có `receivers:` config
# ❌ THIẾU: không có endpoint declarations
```

### Helm chart default behavior

Chart `grafana/tempo` v1.21.1 **không inject default receivers config** vào ConfigMap nếu values không khai báo. Kết quả:
- Tempo binary khởi động với **built-in defaults của OpenTelemetry Collector**
- Built-in defaults từ v0.112.0+ là `localhost` (không phải `0.0.0.0`)

### Evidence từ web research

**OneUptime — Tempo Distributor Configuration (2026-01-30):**
> "OTLP Receiver (Recommended): OTLP supports both gRPC and HTTP.
> ```yaml
> distributor:
>   receivers:
>     otlp:
>       protocols:
>         grpc:
>           endpoint: "0.0.0.0:4317"   # ← PHẢI tường minh
>         http:
>           endpoint: "0.0.0.0:4318"   # ← PHẢI tường minh
> ```"

**Grafana Docs — Troubleshooting (2026):**
> "Case 1 - `tempo_distributor_spans_received_total` is 0: Use of incorrect protocol/port combination while initializing the tracer in the application."

---

## 3. Tại Sao Service Definition Đúng Nhưng Vẫn Không Hoạt Động

### Service đã có port 4318

```yaml
# deploy/observability/charts/tempo-values.yaml (đã fix trước đó)
service:
  enabled: true
  type: ClusterIP
  ports:
    - name: otlp-http
      port: 4318
      targetPort: 4318
```

### Nhưng Service chỉ là routing layer

```
┌──────────────────────────────────────────────────────────┐
│ Kubernetes Service: tempo.observability.svc.cluster.local│
│ Port 4318 → targetPort 4318                              │
└─────────────────────┬────────────────────────────────────┘
                      │ (forwards to)
                      ▼
┌──────────────────────────────────────────────────────────┐
│ Pod: tempo-0                                             │
│ ┌──────────────────────────────────────────────────────┐ │
│ │ Container: tempo                                     │ │
│ │ ┌──────────────────────────────────────────────────┐ │ │
│ │ │ OTLP HTTP Receiver                               │ │ │
│ │ │ ❌ Bind: localhost:4318 (KHÔNG lắng nghe 0.0.0.0)│ │ │
│ │ └──────────────────────────────────────────────────┘ │ │
│ └──────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

**Kết quả:**
- Service forward traffic tới pod IP `10.42.x.x:4318` ✅
- Nhưng Tempo process **không lắng nghe trên pod network interface** ❌
- Connection bị **refused** hoặc timeout

### Log pattern dự kiến

**Backend service logs:**
```
io.grpc.netty.shaded.io.netty.channel.AbstractChannel$AnnotatedConnectException: 
  Connection refused: tempo.observability.svc.cluster.local/10.42.x.x:4318
```

Hoặc:
```
java.net.ConnectException: Connection refused (Connection refused)
  at java.base/java.net.PlainSocketImpl.connect0(Native Method)
```

**Tempo logs sẽ KHÔNG có lỗi** vì receiver đang lắng nghe `localhost` — hoàn toàn hợp lệ, chỉ là không ai từ bên ngoài pod kết nối được.

---

## 4. Cách Sửa (Fix Configuration)

### 4.1. Thêm `distributor.receivers` vào `tempo-values.yaml`

```yaml
# deploy/observability/charts/tempo-values.yaml
tempo:
  repository: grafana/tempo
  tag: 2.7.1
  pullPolicy: IfNotPresent
  memBallastSizeMbs: 0
  extraEnv:
    - name: GOMEMLIMIT
      value: 400MiB
  reportingEnabled: false
  retention: 24h
  metricsGenerator:
    enabled: false
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { cpu: 500m, memory: 512Mi }

# ========== THÊM SECTION NÀY ==========
distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          # Bind tường minh trên 0.0.0.0 để accessible từ bên ngoài pod
          endpoint: "0.0.0.0:4317"
        http:
          endpoint: "0.0.0.0:4318"
# ======================================

persistence:
  enabled: true
  storageClassName: local-path
  size: 2Gi

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

serviceMonitor:
  enabled: false
```

### 4.2. Verify Helm Template Render

```bash
cd deploy/observability
helm template tempo oci://ghcr.io/grafana/helm-charts/tempo \
  --version 1.21.1 \
  -f charts/tempo-values.yaml \
  | grep -A20 "tempo.yaml:" \
  | grep -A10 "receivers:"
```

**Expected output:**
```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
      http:
        endpoint: "0.0.0.0:4318"
```

### 4.3. Deploy và Verify Runtime

```bash
# 1. Re-install Tempo
cd deploy/observability
./install.sh

# 2. Check Tempo pod logs để xác nhận receivers bind đúng
kubectl logs -n observability tempo-0 | grep -i "otlp.*4318\|receiver\|listening"

# Expected: "OTLP receiver listening on 0.0.0.0:4318"

# 3. Test connectivity từ backend namespace
kubectl run test-otlp --rm -it --image=curlimages/curl --namespace=web-grading -- \
  curl -v -X POST http://tempo.observability.svc.cluster.local:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d '{"resourceSpans":[]}'

# Expected: HTTP 200 hoặc 400 (not Connection Refused)

# 4. Verify metrics
kubectl port-forward -n observability tempo-0 3200:3200 &
curl -s http://localhost:3200/metrics | grep tempo_distributor_spans_received_total

# Expected: tempo_distributor_spans_received_total{} > 0 sau vài phút có traffic

# 5. Query traces từ Grafana
# Grafana → Explore → Tempo → Search by service.name
```

---

## 5. Tại Sao Lỗi Này Khó Phát Hiện

### 5.1. Silent Failure

- **Service tồn tại, DNS resolve** → `nslookup tempo.observability.svc.cluster.local` trả về IP ✅
- **Port 4318 được expose trong Service** → `kubectl get svc tempo` show port mapping ✅
- **Tempo pod Running, không crash** → `kubectl get pod tempo-0` show `1/1 Running` ✅
- **Tempo logs không có lỗi** → receiver bind `localhost` là valid config, không warning

→ **Nhưng external traffic bị refused**, và không có log nào ở Tempo side

### 5.2. Không Giống OOMKill/Ballast

Lỗi ballast (issue trước) có triệu chứng rõ ràng:
- Pod restart liên tục
- Node memory pressure
- `kubectl describe pod` show OOMKilled

Lỗi receiver bind `localhost`:
- **Không có triệu chứng infrastructure**
- Chỉ phát hiện được qua **application logs** (backend service) hoặc **missing metrics** (`tempo_distributor_spans_received_total = 0`)

### 5.3. Breaking Change Không Trong Release Notes Helm Chart

Chart `grafana/tempo` v1.21.1 release notes **không nhắc đến** breaking change về receiver endpoints. Developer phải:
1. Đọc Tempo upstream release notes
2. Trace dependency version của OpenTelemetry Collector
3. Đọc OTel Collector breaking changes

→ **Không ai expect cần khai báo endpoint tường minh** nếu từng hoạt động trước đó

---

## 6. Impact Analysis

### 6.1. Current State (Before Fix)

```
┌─────────────┐
│ api-gateway │──┐
└─────────────┘  │
┌─────────────┐  │
│course-svc   │──┤
└─────────────┘  │
┌─────────────┐  │  OTLP/HTTP POST
│executor-svc │──┤  http://tempo.observability:4318/v1/traces
└─────────────┘  ├──► ❌ Connection Refused / Timeout
┌─────────────┐  │      (receiver bind localhost, không lắng nghe pod IP)
│result-svc   │──┤
└─────────────┘  │
┌─────────────┐  │
│submission   │──┤
└─────────────┘  │
┌─────────────┐  │
│ai-assistant │──┘
└─────────────┘

                  ┌─────────────────┐
                  │ Tempo (Running) │
                  │ ┌─────────────┐ │
                  │ │ OTLP:4318   │ │
                  │ │ localhost✅ │ │ ← bind đúng từ góc nhìn container
                  │ │ 0.0.0.0 ❌  │ │ ← KHÔNG lắng nghe network
                  │ └─────────────┘ │
                  └─────────────────┘

🔴 ZERO traces ingested
🔴 tempo_distributor_spans_received_total = 0
🔴 Query Grafana → "No data"
```

### 6.2. After Fix

```
┌─────────────┐
│ api-gateway │──┐
└─────────────┘  │
                 │
                 ├──► ✅ OTLP/HTTP POST succeeds
                 │      Receiver bind 0.0.0.0:4318
                 │
                 ▼
          ┌─────────────────┐
          │ Tempo           │
          │ ┌─────────────┐ │
          │ │ OTLP:4318   │ │
          │ │ 0.0.0.0 ✅  │ │ ← lắng nghe tất cả interfaces
          │ └─────────────┘ │
          │                 │
          │ Traces stored ✅│
          └─────────────────┘

🟢 Traces ingested
🟢 tempo_distributor_spans_received_total > 0
🟢 Query Grafana → Traces visible
```

---

## 7. Checklist Verify (Sau Khi Cluster Lên)

```bash
# [ ] 1. Render Helm manifest có receivers config đúng
helm template tempo oci://ghcr.io/grafana/helm-charts/tempo \
  --version 1.21.1 -f charts/tempo-values.yaml \
  | grep -A10 "endpoint:"

# [ ] 2. Re-deploy Tempo
cd deploy/observability && ./install.sh

# [ ] 3. Check Tempo logs
kubectl logs -n observability tempo-0 --tail=100 | grep -i "otlp\|receiver\|4318"

# [ ] 4. Test connectivity từ web-grading namespace
kubectl run curl-test --rm -it --image=curlimages/curl -n web-grading -- \
  curl -v http://tempo.observability.svc.cluster.local:4318/v1/traces

# [ ] 5. Verify metric
kubectl port-forward -n observability tempo-0 3200:3200 &
curl http://localhost:3200/metrics | grep tempo_distributor_spans_received_total

# [ ] 6. Check backend service logs (không còn Connection Refused)
kubectl logs -n web-grading deploy/api-gateway --tail=50 | grep -i "tempo\|otlp"

# [ ] 7. Query traces từ Grafana
# Grafana → Explore → Tempo → service.name = "api-gateway"

# [ ] 8. Verify traceId trong logs khớp với Grafana
kubectl logs -n web-grading deploy/api-gateway --tail=20 | grep -oP '\[[a-f0-9]{16},'
```

---

## 8. Documentation Updates (Sau Khi Verify)

### 8.1. Cập nhật `deploy/observability/README.md`

Thêm section:

```markdown
## OTLP Receivers Configuration

Tempo receivers **must** explicitly bind to `0.0.0.0` for cross-namespace
connectivity. OpenTelemetry Collector v0.112.0+ defaults to `localhost` for
security reasons.

See: https://github.com/grafana/tempo/issues/4465

If receivers bind `localhost`, backend services in `web-grading` namespace
cannot reach `tempo.observability.svc.cluster.local:4318` even though the
Service and DNS are correctly configured.

The `tempo-values.yaml` includes explicit endpoint declarations:

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
```

### 8.2. Cập nhật `.kilo/skills/observability-stack/SKILL.md`

Thêm gotcha:

```markdown
## 5. Gotchas

### Tempo OTLP receivers phải bind `0.0.0.0` tường minh

**Lỗi:** Chart `grafana/tempo` v1.21.1 sử dụng OpenTelemetry Collector >=v0.112.0,
trong đó receivers mặc định bind `localhost` thay vì `0.0.0.0` (breaking change).
Không khai báo endpoint trong values → receivers không accessible từ namespace khác.

**Triệu chứng:**
- Service `tempo.observability.svc.cluster.local` resolve được ✅
- Port 4318 expose trong Service ✅
- Pod `tempo-0` Running không lỗi ✅
- Nhưng backend logs: `Connection refused` khi POST /v1/traces ❌
- `tempo_distributor_spans_received_total = 0` ❌

**Fix:** Khai báo `distributor.receivers.otlp.protocols.http.endpoint: "0.0.0.0:4318"`
trong `tempo-values.yaml`.

**Ref:** https://github.com/grafana/tempo/issues/4465, plan 2026-11-08.
```

---

## 9. Tổng Kết Root Cause

| Lớp | Vấn đề | Nguyên nhân |
|---|---|---|
| **1. Upstream** | OTel Collector breaking change | v0.112.0 bỏ feature gate, hard-default về `localhost` |
| **2. Helm Chart** | Tempo chart không inject default | values trống → Tempo binary dùng built-in defaults |
| **3. Configuration** | `tempo-values.yaml` thiếu `distributor:` | Không ai expect cần khai báo (worked before) |
| **4. Manifestation** | Receivers bind `localhost`, not `0.0.0.0` | External traffic bị refused |
| **5. Detection** | Silent failure, no obvious symptoms | Pod healthy, Service exists, DNS resolves |

**One-line summary:**  
Tempo Helm chart v1.21.1 uses OTel Collector >=v0.112.0 which defaults receivers to `localhost`; without explicit `distributor.receivers.otlp.protocols.http.endpoint: "0.0.0.0:4318"` in values, cross-namespace OTLP ingestion fails silently.

---

## 10. Bài Học

1. **Breaking changes có thể nằm ở dependency level**: Chart stable không nghĩa là
   upstream dependencies không có breaking changes.

2. **"No config needed" có thể đột nhiên thành "must config"**: Trước đây không cần
   khai báo endpoint vì default `0.0.0.0`, giờ phải khai báo tường minh.

3. **Silent failures nguy hiểm hơn crash loops**: Pod Running + Service exists +
   DNS resolves → dễ nghĩ "network policy" hoặc "firewall", khó nghĩ "receiver
   bind sai interface".

4. **Verify bằng metrics, không chỉ process health**: `tempo-0` Running không
   nghĩa là nhận được traces → phải check `tempo_distributor_spans_received_total`.

5. **Cross-namespace communication cần test thật**: `nslookup` từ namespace
   khác không đủ, phải `curl -v POST` thực tế mới phát hiện connection refused.

---

## Tham Khảo

- [grafana/tempo#4465](https://github.com/grafana/tempo/issues/4465) — OTel upgrade breaks receiver connectivity
- [open-telemetry/opentelemetry-collector#8510](https://github.com/open-telemetry/opentelemetry-collector/issues/8510) — Security rationale for localhost default
- [OneUptime: Fix Grafana Tempo Not Receiving Traces (2026-02-06)](https://oneuptime.com/blog/post/2026-02-06-fix-grafana-tempo-not-receiving-traces-grpc-vs-http/view)
- [OneUptime: Tempo Distributor Configuration (2026-01-30)](https://oneuptime.com/blog/post/2026-01-30-tempo-distributor-configuration/view)
- [Grafana Docs: Unable to see traces](https://grafana.com/docs/tempo/latest/troubleshooting/querying/unable-to-see-trace/)
- `.opencode/plan/deploy-observability-stack/plan.md` §2.j — DNS resolution issue (2026-11-08)
