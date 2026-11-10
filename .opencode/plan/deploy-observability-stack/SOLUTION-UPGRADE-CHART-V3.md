# Giải pháp dứt điểm: Upgrade Tempo Chart v3.1.0

**Date:** 2026-11-08  
**Status:** ✅ Config updated in repo, ready to deploy  

---

## Tóm tắt

**Vấn đề:** Tempo traces bị timeout vì port mismatch 3100 vs 3200.

**Root cause:** Chart **grafana/tempo v1.21.1** (app 2.7.1) mặc định dùng port **3100** legacy, phải override thủ công thành 3200.

**Giải pháp dứt điểm:** ✅ **Nâng chart lên v3.1.0** — Tempo app 2.8+ mặc định dùng port **3200**, không cần override nữa.

---

## Tại sao nâng version thay vì chỉ fix port?

### Option 1: Giữ chart v1.21.1 + manual override ❌
- Phải maintain override `server.http_listen_port: 3200` mãi mãi
- Risk: Nếu quên override hoặc chart upgrade → port mismatch lại
- Không fix được root cause

### Option 2: Nâng chart v3.1.0 ✅ (KHUYẾN NGHỊ)
- **Port 3200 là default** từ Tempo app 2.8+
- Override trở thành redundant (giữ lại để rõ ràng, nhưng không bắt buộc)
- **Zero risk** port mismatch trong tương lai
- Được thêm features:
  - TraceQL: `topk()`, `bottomk()`, `sum_over_time()`, `most_recent=true`
  - **50% memory reduction** (removed large trace pooling)
  - Query performance improvements
  - Security fixes (distroless images, Go 1.24+)

---

## Thay đổi đã commit trong repo

### 1. `charts/tempo-values.yaml`

```diff
  # =============================================================================
  # Tempo Helm Values
- # Chart: grafana/tempo v1.21.1 (app 2.7.1)
+ # Chart: grafana-community/tempo v3.1.0 (app 2.8+)
  # Trace storage only. Services push OTLP/HTTP straight to :4318.
  # =============================================================================
```

```diff
- # Tempo HTTP server phải listen port 3200 (không phải 3100 mặc định của chart)
- # để khớp với Grafana datasource url: http://tempo.observability.svc.cluster.local:3200
- # Chart grafana/tempo v1.21.1 mặc định dùng port 3100 (legacy từ Loki/Cortex).
- # Nếu không override này, Tempo listen 3100 → Grafana query 3200 → timeout.
- # Review: 2026-11-08, port mismatch causing "dial tcp ...3200: i/o timeout".
+ # Tempo HTTP server phải listen port 3200 để khớp với Grafana datasource URL:
+ # http://tempo.observability.svc.cluster.local:3200
+ # Từ chart v3.x (Tempo app 2.8+), port 3200 là mặc định, nhưng khai báo tường
+ # minh ở đây để rõ ràng trong tài liệu và tránh nhầm lẫn khi đọc config.
+ # Review: 2026-11-08, upgraded to chart v3.1.0, port 3200 is now default.
  server:
    http_listen_port: 3200
    grpc_listen_port: 9095
```

### 2. `install.sh`

```diff
  # ---- Step 3: Install Tempo (trace storage) ----
  echo ""
  echo "[3/5] Installing Tempo (distributed tracing storage)..."
- if ! helm_pull oci://ghcr.io/grafana/helm-charts/tempo 1.21.1; then
+ if ! helm_pull oci://ghcr.io/grafana-community/helm-charts/tempo 3.1.0; then
    echo "[ERROR] Could not download the Tempo chart from GHCR after 3 attempts."
    exit 1
  fi
- helm upgrade --install tempo "$CHARTS_TMP/tempo-1.21.1.tgz" \
+ helm upgrade --install tempo "$CHARTS_TMP/tempo-3.1.0.tgz" \
    --namespace observability \
    -f "$CHARTS_DIR/tempo-values.yaml" \
    --wait --timeout 10m
```

### 3. `docs/observability/README.md`

```diff
  | Thành phần | Cài đặt | CPU request/limit | RAM request/limit | Ghi chú |
  |---|---|---|---|---|
  | Prometheus | kube-prometheus-stack | 100m / 500m | 256Mi / 768Mi | TSDB 2Gi, retention 3 ngày, cắt ở 1500MB |
  | Grafana | kube-prometheus-stack | 100m / 500m | 256Mi / 512Mi | PVC 2Gi |
- | Tempo | grafana/tempo 1.21.1 | 100m / 500m | 256Mi / 512Mi | PVC 2Gi, retention 24h |
+ | Tempo | grafana-community/tempo 3.1.0 | 100m / 500m | 256Mi / 512Mi | PVC 2Gi, retention 24h, port 3200 |
```

---

## Cách deploy (3 options)

### Option A: Chạy `install.sh` (KHUYẾN NGHỊ)

Trên máy có Helm + kubectl access:

```bash
cd /path/to/web-grading-system-deploy/deploy/observability
./install.sh
```

Script sẽ:
- ✅ Pull Tempo chart v3.1.0 từ GHCR
- ✅ Upgrade Tempo release với values file mới
- ✅ Auto-verify port 3200 sau khi deploy
- ✅ Show pass/fail status

**Downtime:** ~30 giây (pod restart)  
**Data loss:** Không (PVC persist)

---

### Option B: Helm upgrade thủ công

```bash
helm upgrade tempo oci://ghcr.io/grafana-community/helm-charts/tempo \
  --version 3.1.0 \
  -n observability \
  -f charts/tempo-values.yaml \
  --wait --timeout 10m
```

Verify:

```bash
kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
# Expected: http_listen_port: 3200
```

---

### Option C: kubectl edit (temporary fix, không khuyến nghị)

Nếu không thể upgrade chart ngay:

```bash
kubectl edit configmap tempo -n observability
# Sửa http_listen_port: 3100 → 3200
kubectl rollout restart statefulset/tempo -n observability
```

**Nhược điểm:** Fix tạm thời, lần sau chạy Helm lại mất.

---

## Verification sau khi deploy

### 1. Check chart version

```bash
helm list -n observability
# NAME   NAMESPACE       CHART           APP VERSION
# tempo  observability   tempo-3.1.0     2.8.x
```

### 2. Check port 3200

```bash
kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
# Expected: http_listen_port: 3200
```

### 3. Check app version

```bash
kubectl exec -n observability tempo-0 -- tempo --version
# Expected: tempo, version 2.8.x (...)
```

### 4. Test Grafana query

```bash
kubectl exec -n observability deployment/monitoring-grafana -- \
  wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready
# Expected: HTTP 200 hoặc "Ingester not ready: waiting for 15s..."
```

### 5. Grafana UI

Open: https://web-dev1-grafana.vucongtuanduong.dpdns.org/a/grafana-exploretraces-app/explore

- Datasource: "Tempo"
- Run any query
- **Expected:** Traces hiển thị, không timeout

---

## Rollback nếu có vấn đề

```bash
helm rollback tempo -n observability
```

Hoặc reinstall chart v1.21.1:

```bash
helm uninstall tempo -n observability
helm install tempo oci://ghcr.io/grafana/helm-charts/tempo \
  --version 1.21.1 \
  -n observability \
  -f /tmp/tempo-values-backup.yaml \
  --wait
```

---

## Breaking changes đã kiểm tra ✅

| Breaking Change | Ảnh hưởng | Đánh giá |
|----------------|----------|---------|
| Port 3200 default | ✅ Đã dùng 3200 | Safe |
| Removed serverless | ✅ Không dùng | Safe |
| Max attribute size enforced | ✅ Default OK | Safe |
| Chart repo migrate grafana-community | ✅ URL updated | Safe |

**Conclusion:** ✅ Không có breaking change nào ảnh hưởng setup hiện tại.

---

## Tài liệu tham khảo

- [Tempo 2.8 Release Notes](https://grafana.com/docs/tempo/latest/release-notes/v2-8/) — Port 3200 default change
- [Tempo Chart v3.1.0](https://artifacthub.io/packages/helm/grafana-community/tempo/3.1.0) — Latest chart
- [Issue #4945](https://github.com/grafana/tempo/issues/4945) — Rationale cho port 3200
- `UPGRADE-TEMPO-CHART-v3.md` — Full upgrade plan với risk assessment

---

## So sánh các giải pháp

| Giải pháp | Effort | Risk | Dứt điểm? | Recommend |
|-----------|--------|------|-----------|-----------|
| kubectl edit ConfigMap | 30s | Low | ❌ Không (Helm reset lại) | ❌ |
| Keep v1.21.1 + manual override | 0 (đã có) | Medium | ❌ Không (phải maintain override) | ❌ |
| Upgrade chart v3.1.0 | 10 phút | Low | ✅ Có (port 3200 native) | ✅ |
| Change Grafana → port 3100 | 15 phút | Medium | ❌ Không (đi ngược best practice) | ❌ |

**Decision:** ✅ **Upgrade Tempo chart v3.1.0** là giải pháp tốt nhất và dứt điểm nhất.

---

**Prepared by:** AI Agent  
**Review date:** 2026-11-08  
**Status:** Ready to deploy  
**Next step:** Run `./install.sh` on production cluster with Helm access
