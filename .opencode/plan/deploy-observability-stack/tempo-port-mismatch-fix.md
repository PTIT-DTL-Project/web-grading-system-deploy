# Tempo Port Mismatch Fix — Root Cause & Solution

> Phát hiện: 2026-11-08 20:10 UTC  
> Phạm vi: `deploy/observability/charts/tempo-values.yaml`  
> Trạng thái: **Root cause xác định, có runtime evidence, chưa apply fix**

---

## 0. Tóm Tắt Root Cause

**VẤN ĐỀ NGHIÊM TRỌNG:** Tempo HTTP server đang listen trên port **3100** (chart default), nhưng:
- Grafana datasource config trỏ tới port **3200**
- Service định nghĩa targetPort **3200**
- **Không có process nào listen port 3200** → tất cả queries từ Grafana timeout

**Bằng chứng từ runtime:**

```bash
# Tempo config
server:
  http_listen_port: 3100  # ❌ SAI

# Tempo logs
level=info msg="server listening on addresses" http=[::]:3100
                                                         ^^^^

# Netstat
tcp  0  0  :::3100  :::*  LISTEN  1/tempo  # ← HTTP đang ở 3100
# KHÔNG CÓ :3200 trong netstat output

# Service endpoints
ENDPOINTS: 10.42.0.48:55680,10.42.0.48:4317,10.42.0.48:55678...
# KHÔNG CÓ :3200 trong endpoints

# Grafana datasource
url: http://tempo.observability.svc.cluster.local:3200
                                                  ^^^^
# → dial tcp 10.43.246.196:3200: i/o timeout
```

**Kết quả:**
```
Grafana → Service:3200 → Pod IP:3200 ❌ (không có process listen)
                             ↓
                          TIMEOUT (10s)
                             ↓
              "failed get to tempo: i/o timeout"
```

---

## 1. Runtime Evidence (2026-11-08)

### 1.1. Pod Status
```bash
$ kubectl get pod -n observability tempo-0 -o wide
NAME      READY   STATUS    RESTARTS   AGE     IP
tempo-0   1/1     Running   0          5m44s   10.42.0.48
```
Pod Running ✅, nhưng query vẫn fail.

### 1.2. Tempo Logs
```
level=info ts=2026-11-08T13:05:13.700018383Z caller=server.go:248 
  msg="server listening on addresses" http=[::]:3100 grpc=[::]:9095
                                            ^^^^^^^^
```
HTTP server bind port **3100**, không phải 3200.

### 1.3. Netstat Output
```bash
$ kubectl exec -n observability tempo-0 -- ss -tlnp
tcp  0  0  :::3100   :::*  LISTEN  1/tempo  # ← HTTP query API (port SAI)
tcp  0  0  :::4318   :::*  LISTEN  1/tempo  # ← OTLP HTTP ✅
tcp  0  0  :::4317   :::*  LISTEN  1/tempo  # ← OTLP gRPC ✅
tcp  0  0  :::9095   :::*  LISTEN  1/tempo  # ← gRPC internal
tcp  0  0  :::14250  :::*  LISTEN  1/tempo  # ← Jaeger gRPC
tcp  0  0  :::14268  :::*  LISTEN  1/tempo  # ← Jaeger HTTP
```
**KHÔNG CÓ port 3200** trong list → không có process listen.

### 1.4. Service Endpoints
```bash
$ kubectl get endpoints -n observability tempo
ENDPOINTS: 10.42.0.48:55680,10.42.0.48:4317,10.42.0.48:55678 + 8 more...
```
Không có `:3200` trong exposed ports → Service không route được tới 3200.

### 1.5. Connectivity Test Từ Grafana Pod
```bash
$ kubectl exec -n observability deployment/monitoring-grafana -- \
    wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready
Connecting to tempo.observability.svc.cluster.local:3200 (10.43.246.196:3200)
wget: download timed out
command terminated with exit code 1
```
Timeout sau 5s → không có response từ pod.

### 1.6. Tempo Config File
```bash
$ kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep -A2 "server:"
server:
  http_listen_port: 3100  # ❌ Chart default, KHÔNG phải 3200
```

### 1.7. Readiness Probe Failures
```bash
$ kubectl get events -n observability | grep tempo | grep Unhealthy
6m21s  Warning  Unhealthy  pod/tempo-0  Readiness probe failed: HTTP probe failed with statuscode: 503
6m21s  Warning  Unhealthy  pod/tempo-0  Liveness probe failed: HTTP probe failed with statuscode: 503
```
Probe hit `/ready` trên port 3100 và nhận 503 → Tempo chưa fully ready, nhưng đây là **vấn đề phụ**.

### 1.8. Grafana Logs (Từ User)
```
logger=tsdb.tempo endpoint=queryData pluginId=tempo dsName=Tempo dsUID=tempo uname=admin 
  t=2026-11-08T13:07:45.461485216Z level=error 
  msg="Failed to send request to Tempo" 
  error="Get \"http://tempo.observability.svc.cluster.local:3200/api/metrics/query_range?...\": 
         dial tcp 10.43.246.196:3200: i/o timeout"
```
Grafana cố connect tới **10.43.246.196:3200** (ClusterIP của Service) và bị timeout.

---

## 2. Root Cause Analysis

### 2.1. Port Mismatch Chain

```
┌─────────────────────────────────────────────────────────────────┐
│ kube-prometheus-stack-values.yaml (Grafana datasource config)  │
│ additionalDataSources:                                          │
│   - name: Tempo                                                 │
│     url: http://tempo.observability.svc.cluster.local:3200      │
│                                                             ^^^^ │
└────────────────────────────┬────────────────────────────────────┘
                             │ Grafana sends requests to :3200
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ Service: tempo.observability.svc.cluster.local                  │
│ ClusterIP: 10.43.246.196                                        │
│ Port mapping:                                                   │
│   - name: http                                                  │
│     port: 3200                                                  │
│     targetPort: 3200  ← forwards to pod port 3200               │
└────────────────────────────┬────────────────────────────────────┘
                             │ Service forwards to pod IP:3200
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ Pod: tempo-0 (10.42.0.48)                                       │
│ Container: tempo                                                │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ Tempo process (PID 1)                                       │ │
│ │ Listening ports:                                            │ │
│ │   :::3100  ← HTTP server ❌ WRONG PORT                      │ │
│ │   :::4318  ← OTLP HTTP ✅                                   │ │
│ │   :::4317  ← OTLP gRPC ✅                                   │ │
│ │   :::9095  ← gRPC internal ✅                               │ │
│ │                                                             │ │
│ │ NO PROCESS listening on :3200 ❌                            │ │
│ └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                             ▲
                             │ Traffic arrives at pod IP:3200
                             │ but NO LISTENER
                             │
                      Connection timeout
```

### 2.2. Tại Sao Port 3100?

**Chart `grafana/tempo` v1.21.1 default config:**
```yaml
# https://github.com/grafana/helm-charts/blob/main/charts/tempo/values.yaml
# Default server config (nếu không override)
server:
  http_listen_port: 3100  # ← Legacy Loki port, Tempo v1.x default
```

**Nhưng Tempo v2.x docs khuyến cáo dùng 3200:**
- Port 3100: legacy (từ Loki, Cortex lineage)
- Port 3200: Tempo v2.x standard

**Grafana datasource trong stack này dùng 3200** (đúng với Tempo v2.x best practice), nhưng chart default vẫn là 3100 → **mismatch**.

### 2.3. Tại Sao Không Phát Hiện Sớm Hơn?

1. **Pod status healthy:** `1/1 Running`, không crash
2. **OTLP ingestion hoạt động:** Ports 4317/4318 đúng, traces có thể vào (nếu backend gửi)
3. **Chỉ query API bị lỗi:** Port 3200 mismatch không ảnh hưởng ingestion
4. **Readiness probe hit port 3100:** Probe config đúng với chart default, nên không fail liên tục
   ```yaml
   readinessProbe:
     httpGet:
       path: /ready
       port: 3100  # ← Probe đúng port, nhưng trả 503 vì distributor chưa ready
   ```
5. **Grafana logs mơ hồ:** "i/o timeout" không nói rõ "no listener", dễ nhầm với network policy hoặc firewall

---

## 3. Secondary Issue: OTLP Receivers Bind `localhost`

**Lỗi thứ hai** (đã dự đoán trong research trước, nhưng không phải nguyên nhân timeout 3200):

File `tempo-values.yaml` hiện tại **KHÔNG có `distributor.receivers` config** → receivers dùng built-in defaults.

**OpenTelemetry Collector v0.112.0+ defaults:**
```yaml
# Default receivers (nếu không khai báo endpoint)
distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: "localhost:4317"  # ❌ Không accessible từ bên ngoài pod
        http:
          endpoint: "localhost:4318"  # ❌ Không accessible từ bên ngoài pod
```

**Evidence từ logs:**
```
ts=2026-11-08T13:05:13Z level=info msg="Starting GRPC server" component=tempo endpoint=0.0.0.0:4317
ts=2026-11-08T13:05:13Z level=info msg="Starting HTTP server" component=tempo endpoint=0.0.0.0:4318
```
→ **Logs cho thấy `0.0.0.0`** → nghĩa là chart **ĐÃ inject endpoint config đúng** (hoặc Tempo v2.7.1 override default).

**Netstat confirm:**
```
tcp  0  0  :::4318  :::*  LISTEN  # ← bind IPv6 any (equivalent 0.0.0.0)
tcp  0  0  :::4317  :::*  LISTEN
```
→ OTLP receivers **KHÔNG phải localhost**, đang OK.

**Nhưng để chắc chắn và explicit:** vẫn nên khai báo tường minh trong values để tránh regression khi upgrade chart/Tempo version.

---

## 4. Solution: Fix Configuration

### 4.1. File Cần Sửa

`deploy/observability/charts/tempo-values.yaml`

### 4.2. Nội Dung Sửa Đổi

```yaml
# =============================================================================
# Tempo Helm Values
# Chart: grafana/tempo v1.21.1 (app 2.7.1)
# Trace storage only. Services push OTLP/HTTP straight to :4318.
# =============================================================================

tempo:
  repository: grafana/tempo
  tag: 2.7.1
  pullPolicy: IfNotPresent

  # Tempo 2.x allocates a 1 GiB ballast by default. That alone is twice the
  # container limit below, so the default guarantees an OOMKill / node pressure.
  memBallastSizeMbs: 0
  # Go soft memory limit: GC earlier instead of letting the heap reach 512Mi.
  extraEnv:
    - name: GOMEMLIMIT
      value: 400MiB

  reportingEnabled: false
  retention: 24h

  # Span metrics need the metrics generator plus a remote-write target; both
  # cost CPU/RAM we do not have here. HTTP metrics come from Prometheus.
  metricsGenerator:
    enabled: false

  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { cpu: 500m, memory: 512Mi }

# ========== FIX 1: HTTP SERVER PORT ==========
# Chart default: 3100 (legacy Loki port)
# Grafana datasource expects: 3200 (Tempo v2.x standard)
# Review: 2026-11-08, runtime evidence port mismatch.
server:
  http_listen_port: 3200
  grpc_listen_port: 9095
# =============================================

# ========== FIX 2: OTLP RECEIVERS EXPLICIT BIND ==========
# OpenTelemetry Collector v0.112.0+ defaults to localhost for security.
# Must explicitly bind 0.0.0.0 for cross-namespace connectivity.
# Chart v1.21.1 may already inject this, but explicit is safer for upgrades.
# Review: 2026-11-08, Grafana Tempo issue #4465.
distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: "0.0.0.0:4317"
        http:
          endpoint: "0.0.0.0:4318"
# ========================================================

persistence:
  enabled: true
  storageClassName: local-path
  size: 2Gi

# Service phải được bật rõ ràng và khai báo port 4318 (OTLP HTTP) để các backend
# ở namespace khác (web-grading) có thể resolve DNS: tempo.observability.svc.cluster.local:4318
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

# Prometheus already scrapes the services; Tempo self-metrics are not needed.
serviceMonitor:
  enabled: false
```

### 4.3. Diff Summary

```diff
# deploy/observability/charts/tempo-values.yaml

+ # ========== FIX 1: HTTP SERVER PORT ==========
+ server:
+   http_listen_port: 3200
+   grpc_listen_port: 9095
+ # =============================================

+ # ========== FIX 2: OTLP RECEIVERS EXPLICIT BIND ==========
+ distributor:
+   receivers:
+     otlp:
+       protocols:
+         grpc:
+           endpoint: "0.0.0.0:4317"
+         http:
+           endpoint: "0.0.0.0:4318"
+ # ========================================================
```

**Chỉ thêm 2 sections mới**, không sửa gì khác.

---

## 5. Deploy Steps

### 5.1. Backup Current Config
```bash
cd /home/duongvct/Documents/workspace/PTIT/web-grading-system-deploy/deploy/observability
cp charts/tempo-values.yaml charts/tempo-values.yaml.backup-$(date +%Y%m%d-%H%M%S)
```

### 5.2. Apply Fix
Sửa file `charts/tempo-values.yaml` theo section 4.2 trên (thêm `server:` và `distributor:` blocks).

### 5.3. Render Template Verify
```bash
helm template tempo oci://ghcr.io/grafana/helm-charts/tempo \
  --version 1.21.1 \
  -f charts/tempo-values.yaml \
  | grep -A3 "http_listen_port\|endpoint:"
```

**Expected output:**
```yaml
http_listen_port: 3200
          endpoint: "0.0.0.0:4317"
          endpoint: "0.0.0.0:4318"
```

### 5.4. Re-install Tempo
```bash
./install.sh
```

Wait for pod to be Running and Ready:
```bash
kubectl wait --for=condition=ready pod/tempo-0 -n observability --timeout=180s
```

### 5.5. Verification Commands

```bash
# 1. Check Tempo logs — port 3200
kubectl logs -n observability tempo-0 --tail=50 | grep "listening on addresses"
# Expected: http=[::]:3200 (không phải 3100)

# 2. Check netstat — port 3200 present
kubectl exec -n observability tempo-0 -- ss -tlnp | grep :3200
# Expected: tcp  0  0  :::3200  :::*  LISTEN  1/tempo

# 3. Check Service endpoints — :3200 trong list
kubectl get endpoints -n observability tempo -o yaml | grep "3200"
# Expected: - port: 3200

# 4. Test connectivity từ Grafana pod
kubectl exec -n observability deployment/monitoring-grafana -- \
  wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready
# Expected: HTTP response (không phải timeout)
# Có thể trả 503 nếu chưa fully ready, nhưng PHẢI có response trong <5s

# 5. Test query API
kubectl exec -n observability deployment/monitoring-grafana -- \
  wget -O- --timeout=5 "http://tempo.observability.svc.cluster.local:3200/api/search/tags"
# Expected: JSON response (có thể rỗng nếu chưa có traces)

# 6. Check pod readiness
kubectl get pod -n observability tempo-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Expected: True

# 7. Query traces từ Grafana UI
# Grafana → Explore → Tempo → service.name = "api-gateway"
# Expected: Không còn "dial tcp ... i/o timeout"
```

---

## 6. Expected Results After Fix

### 6.1. Tempo Logs
```
level=info ts=... caller=server.go:248 
  msg="server listening on addresses" http=[::]:3200 grpc=[::]:9095
                                            ^^^^^^^^
ts=... level=info msg="Starting HTTP server" component=tempo endpoint=0.0.0.0:4318
ts=... level=info msg="Starting GRPC server" component=tempo endpoint=0.0.0.0:4317
```

### 6.2. Netstat Output
```bash
$ kubectl exec -n observability tempo-0 -- ss -tlnp
tcp  0  0  :::3200   :::*  LISTEN  1/tempo  # ← HTTP query API ✅
tcp  0  0  :::4318   :::*  LISTEN  1/tempo  # ← OTLP HTTP ✅
tcp  0  0  :::4317   :::*  LISTEN  1/tempo  # ← OTLP gRPC ✅
tcp  0  0  :::9095   :::*  LISTEN  1/tempo  # ← gRPC internal ✅
```

### 6.3. Service Endpoints
```bash
$ kubectl get endpoints -n observability tempo
ENDPOINTS: 10.42.0.48:3200,10.42.0.48:4317,10.42.0.48:4318,...
                     ^^^^
```

### 6.4. Grafana Query
```bash
$ kubectl exec -n observability deployment/monitoring-grafana -- \
    wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready
Connecting to tempo.observability.svc.cluster.local:3200 (10.43.246.196:3200)
saving to 'stdout'
-                    100% |********************************|     4  0:00:00 ETA
'stdout' saved
```
Response nhận được trong <1s, không timeout.

### 6.5. Grafana Logs
```
level=info msg="Request Completed" method=POST path=/api/ds/query status=200
# Không còn error "dial tcp ... i/o timeout"
```

---

## 7. Rollback Plan (Nếu Cần)

```bash
cd /home/duongvct/Documents/workspace/PTIT/web-grading-system-deploy/deploy/observability

# Restore backup
cp charts/tempo-values.yaml.backup-YYYYMMDD-HHMMSS charts/tempo-values.yaml

# Re-deploy
./install.sh
```

**Lưu ý:** Rollback sẽ khôi phục lại lỗi port 3100 → Grafana query vẫn fail.

---

## 8. Related Issues và Bài Học

### 8.1. Lỗi Đã Fix Trước Đó (Plan 2026-11-08)

| Issue | Plan File | Trạng thái |
|---|---|---|
| Tempo ballast 1 GiB | `plan.md` §2.a | ✅ Đã fix |
| Prometheus scrape 401 | `plan.md` §2.b | ✅ Đã fix |
| Boot 4.1 property sai | `plan.md` §2.c | ✅ Đã fix |
| Grafana redirect loop | `plan.md` §2.d | ✅ Đã fix |
| Tempo Service thiếu ports | `plan.md` §2.j | ⚠️ Partial fix (ports có, nhưng targetPort sai) |
| **Tempo HTTP port 3100** | **Chưa có trong plan** | ❌ **Issue mới phát hiện** |

### 8.2. Tại Sao Plan Trước Không Phát Hiện?

Plan 2026-11-08 focus vào:
- **Ingestion path** (backend → Tempo port 4318)
- **DNS resolution** (`UnknownHostException`)
- **OTel breaking change** (receivers bind localhost)

Nhưng **không test query path** (Grafana → Tempo port 3200) → bỏ sót port mismatch.

**Root cause của root cause:** Cluster không chạy lúc research → không có runtime evidence → chỉ analyze config offline.

### 8.3. Bài Học

1. **Chart defaults không đáng tin:** Chart v1.21.1 dùng port legacy 3100, không align với Tempo v2.x best practice (3200).

2. **Config phải verify cả 2 chiều:**
   - Ingestion: backend → Tempo (4318) ✅
   - Query: Grafana → Tempo (3200) ❌ missed

3. **Runtime verification > Static analysis:**
   - Chỉ khi có `netstat` output mới thấy rõ port 3100 ≠ 3200
   - Logs + config file + Service definition đều cần, nhưng không đủ

4. **Timeout ≠ Connection Refused:**
   - Timeout: Service route OK, nhưng pod không listen → port mismatch
   - Connection Refused: Service/DNS issue hoặc NetworkPolicy block

5. **Probe pass ≠ Service healthy:**
   - Readiness probe hit port 3100 (đúng), trả 503 (chưa ready)
   - Nhưng Grafana hit port 3200 → hoàn toàn không liên quan với probe status

---

## 9. Post-Fix Documentation Updates

### 9.1. Update `deploy/observability/README.md`

Thêm section sau phần "8 GB tuning notes":

```markdown
## Port Configuration

Tempo HTTP server listens on **port 3200** (Tempo v2.x standard), not 3100
(legacy Loki/Cortex port). The Grafana datasource is configured to query
`http://tempo.observability.svc.cluster.local:3200`.

Chart `grafana/tempo` v1.21.1 defaults to port 3100. The `tempo-values.yaml`
overrides this with `server.http_listen_port: 3200` to match the datasource.

If you see "dial tcp ...3200: i/o timeout" errors in Grafana logs, verify
Tempo is listening on 3200:

```bash
kubectl exec -n observability tempo-0 -- ss -tlnp | grep :3200
```

Should return:
```
tcp  0  0  :::3200  :::*  LISTEN  1/tempo
```

See: `.opencode/plan/deploy-observability-stack/tempo-port-mismatch-fix.md`
```

### 9.2. Update `.kilo/skills/observability-stack/SKILL.md`

Thêm gotcha:

```markdown
## 5. Gotchas

### Tempo HTTP server phải listen port 3200, không phải 3100

**Lỗi:** Chart `grafana/tempo` v1.21.1 mặc định dùng port **3100** (legacy từ
Loki/Cortex), nhưng Grafana datasource trong stack này config port **3200**
(Tempo v2.x standard). Nếu không override `server.http_listen_port`, Tempo
listen 3100 → Grafana query timeout.

**Triệu chứng:**
- Grafana logs: `dial tcp 10.43.246.196:3200: i/o timeout`
- Tempo pod Running, không crash ✅
- OTLP ingestion hoạt động (port 4318) ✅
- Nhưng query API không trả lời ❌
- `netstat` show `:3100`, không có `:3200` ❌

**Fix:** Thêm `server: { http_listen_port: 3200 }` vào `tempo-values.yaml`.

**Ref:** `.opencode/plan/deploy-observability-stack/tempo-port-mismatch-fix.md`,
runtime evidence 2026-11-08.
```

### 9.3. Update Main Plan File

Thêm vào `.opencode/plan/deploy-observability-stack/plan.md` section §2:

```markdown
### 2.k — Tempo HTTP server port mismatch (2026-11-08, sau khi cluster lên)

**Triệu chứng:** Grafana query Tempo timeout: `dial tcp 10.43.246.196:3200: i/o timeout`.

**Nguyên nhân:** Chart default `server.http_listen_port: 3100`, nhưng Grafana datasource
và Service targetPort đều expect **3200**. Runtime `netstat` không có `:3200` trong listen
ports.

**Cách sửa:** Thêm explicit override:

```yaml
# tempo-values.yaml
server:
  http_listen_port: 3200  # Chart default 3100, must override
  grpc_listen_port: 9095
```

**Verify:** `kubectl exec tempo-0 -- ss -tlnp | grep :3200` phải trả về LISTEN.

Chi tiết: `tempo-port-mismatch-fix.md` (cùng thư mục).
```

---

## 10. Summary

| Metric | Before Fix | After Fix |
|---|---|---|
| Tempo HTTP server | Port 3100 ❌ | Port 3200 ✅ |
| Grafana query | Timeout 10s ❌ | Response <1s ✅ |
| Netstat :3200 | Not present ❌ | LISTEN ✅ |
| Service endpoints | No :3200 ❌ | Has :3200 ✅ |
| OTLP receivers | Already 0.0.0.0 ✅ | Explicit config ✅ |

**One-line fix:**
```yaml
server: { http_listen_port: 3200 }
distributor:
  receivers:
    otlp:
      protocols:
        grpc: { endpoint: "0.0.0.0:4317" }
        http: { endpoint: "0.0.0.0:4318" }
```

**Impact:** Grafana có thể query traces từ Tempo, không còn timeout.

**Effort:** 2 phút sửa config + 3 phút re-deploy + 5 phút verify = **~10 phút total**.

**Risk:** Low — chỉ thêm config, không sửa gì khác. Rollback bằng cách restore backup.

---

## Appendix A: Full Error Log (User-Provided)

```
logger=tsdb.tempo endpoint=queryData pluginId=tempo dsName=Tempo dsUID=tempo uname=admin 
  t=2026-11-08T13:07:45.461485216Z level=error 
  msg="Failed to send request to Tempo" 
  error="Get \"http://tempo.observability.svc.cluster.local:3200/api/metrics/query_range?end=1794143244&q=%7BnestedSetParent%3C0+%26%26+true+%26%26+resource.service.name+%21%3D+nil%7D+%7C+rate%28%29+by%28resource.service.name%29&start=1794141444&step=28s\": dial tcp 10.43.246.196:3200: i/o timeout"

logger=context userId=1 orgId=1 uname=admin 
  t=2026-11-08T13:07:45.461657781Z level=error 
  msg="Request Completed" method=POST path=/api/ds/query status=500 
  remote_addr=10.42.0.1 time_ms=10017 duration=10.017184757s size=107 
  referer="https://web-dev1-grafana.vucongtuanduong.dpdns.org/a/grafana-exploretraces-app/explore?..."
  status_source=downstream errorReason=InternalError errorMessageID=plugin.requestFailureError 
  error="client: failed to query data: failed get to tempo: Get \"http://tempo.observability.svc.cluster.local:3200/api/metrics/query_range?...\": dial tcp 10.43.246.196:3200: i/o timeout"

logger=data-proxy-log userId=1 orgId=1 uname=admin 
  path=/api/datasources/proxy/uid/tempo/api/search/tags remote_addr=10.42.0.1 
  t=2026-11-08T13:07:45.494808662Z level=error 
  msg="Proxy request failed" err="dial tcp 10.43.246.196:3200: i/o timeout"

logger=grafana-apiserver 
  t=2026-11-08T13:07:48.863678341Z level=info 
  msg="[core] [Channel #2 SubChannel #3]grpc: addrConn.createTransport failed to connect to {Addr: \"tempo.observability.svc.cluster.local:3200\", ServerName: \"tempo.observability.svc.cluster.local:3200\", }. Err: connection error: desc = \"transport: Error while dialing: dial tcp 10.43.246.196:3200: i/o timeout\""
```

**Pattern:** Tất cả đều cố connect tới **:3200**, tất cả đều timeout sau 10s.

---

## Appendix B: Quick Fix One-Liner Script

```bash
#!/bin/bash
# Quick patch script for Tempo port mismatch
# Run: bash tempo-port-fix.sh

set -euo pipefail

DEPLOY_DIR="/home/duongvct/Documents/workspace/PTIT/web-grading-system-deploy/deploy/observability"
VALUES_FILE="$DEPLOY_DIR/charts/tempo-values.yaml"

cd "$DEPLOY_DIR"

# Backup
cp "$VALUES_FILE" "${VALUES_FILE}.backup-$(date +%Y%m%d-%H%M%S)"
echo "[1/4] Backup created"

# Check if fix already applied
if grep -q "http_listen_port: 3200" "$VALUES_FILE"; then
  echo "[SKIP] Fix already applied (http_listen_port: 3200 found)"
  exit 0
fi

# Append fix
cat >> "$VALUES_FILE" <<'EOF'

# Fix: HTTP server must listen on 3200 (not chart default 3100)
# Fix: OTLP receivers must bind 0.0.0.0 (not localhost)
# Review: 2026-11-08, port mismatch runtime evidence.
server:
  http_listen_port: 3200
  grpc_listen_port: 9095

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: "0.0.0.0:4317"
        http:
          endpoint: "0.0.0.0:4318"
EOF

echo "[2/4] Config patched"

# Re-deploy
./install.sh
echo "[3/4] Tempo re-deployed"

# Wait for pod
kubectl wait --for=condition=ready pod/tempo-0 -n observability --timeout=180s
echo "[4/4] Pod ready"

# Verify
echo ""
echo "=== VERIFICATION ==="
echo "Port 3200 listening:"
kubectl exec -n observability tempo-0 -- ss -tlnp 2>/dev/null | grep :3200 || echo "  [FAIL] Port 3200 not found"

echo ""
echo "Test connectivity:"
if kubectl exec -n observability deployment/monitoring-grafana -- \
  wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready &>/dev/null; then
  echo "  [PASS] Grafana → Tempo :3200 OK"
else
  echo "  [WARN] Connection test failed (may be 503 if not fully ready)"
fi

echo ""
echo "Done. Check Grafana → Explore → Tempo."
```

Save as `tempo-port-fix.sh`, make executable, run:
```bash
chmod +x tempo-port-fix.sh
./tempo-port-fix.sh
```
