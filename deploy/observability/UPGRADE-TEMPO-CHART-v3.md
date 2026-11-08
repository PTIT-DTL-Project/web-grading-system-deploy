# Upgrade Plan: Tempo Chart v1.21.1 → v3.1.0

**Date:** 2026-11-08  
**Priority:** Medium (fixes port mismatch + gets latest features)  
**Estimated Time:** 5-10 minutes  
**Requires:** Helm access to production cluster  

---

## Why Upgrade?

### Current Issue
- **Chart v1.21.1** ships Tempo app **v2.7.1** → default port **3100** (legacy)
- We have to manually override `server.http_listen_port: 3200` in values file
- Grafana expects port **3200** → causes timeout if override is missed

### After Upgrade to v3.1.0
- Chart ships Tempo app **v2.8+** → default port **3200** (native)
- **No manual override needed** — port 3200 is the default
- Reduces configuration drift risk
- Gets latest Tempo features (TraceQL improvements, performance fixes)

---

## What Changed in Tempo 2.8+

From [Tempo 2.8 Release Notes](https://grafana.com/docs/tempo/latest/release-notes/v2-8/):

> **Changed the default listening port**  
> With Tempo 2.8, the default `http_listen_port` changes from **80 to 3200**.

This aligns with:
- Tempo v2.x best practice (port 3200 is standard)
- Grafana datasource defaults
- Reduces confusion with legacy Loki/Cortex port 3100

**Additional improvements in Tempo 2.8:**
- TraceQL: `topk()`, `bottomk()`, `sum_over_time()`, `most_recent=true`
- 50%+ memory reduction (removed large trace pooling)
- Query performance improvements
- Distroless base images (better security)
- Go 1.24+ (CVE fixes)

---

## Pre-Upgrade Checklist

### 1. Check Current Version

```bash
helm list -n observability
# NAME      NAMESPACE        REVISION  STATUS    CHART           APP VERSION
# tempo     observability    1         deployed  tempo-1.21.1    2.7.1
```

### 2. Backup Current Config

```bash
helm get values tempo -n observability > /tmp/tempo-values-backup.yaml
```

### 3. Review Breaking Changes

**Chart v3.x changes from v1.x:**
- Port 3200 is now default (our override becomes redundant but harmless)
- No other breaking changes affect our setup (single-binary mode)

**Tempo app 2.8 breaking changes:**
- Default port change (we already use 3200 ✅)
- Removed serverless backend (we don't use ✅)
- Enforced max attribute size (default is safe ✅)

**Conclusion:** ✅ Safe to upgrade with our current config.

---

## Upgrade Steps

### Option 1: Helm Upgrade (Recommended)

```bash
cd /path/to/web-grading-system-deploy/deploy/observability

# Pull latest chart
helm pull oci://ghcr.io/grafana-community/helm-charts/tempo --version 3.1.0 -d /tmp

# Upgrade with existing values
helm upgrade tempo /tmp/tempo-3.1.0.tgz \
  -n observability \
  -f charts/tempo-values.yaml \
  --wait --timeout 10m
```

**Downtime:** ~30 seconds during pod restart  
**Data loss:** None (traces persist in PVC)

### Option 2: Clean Install (If Upgrade Fails)

```bash
# Uninstall old release
helm uninstall tempo -n observability

# Wait for PVC to remain
kubectl get pvc -n observability
# NAME                    STATUS
# storage-tempo-0         Bound    (this persists)

# Install new version
helm install tempo oci://ghcr.io/grafana-community/helm-charts/tempo \
  --version 3.1.0 \
  -n observability \
  -f charts/tempo-values.yaml \
  --wait --timeout 10m
```

**Note:** PVC `storage-tempo-0` will be reused automatically.

---

## Update Config Files

After successful upgrade, update repo to reflect new chart version.

### 1. Update `tempo-values.yaml`

```bash
cd /path/to/web-grading-system-deploy/deploy/observability/charts
```

**Edit header comment:**

```yaml
# =============================================================================
# Tempo Helm Values
# Chart: grafana-community/tempo v3.1.0 (app 2.8.x)
# Trace storage only. Services push OTLP/HTTP straight to :4318.
# =============================================================================
```

**Optional: Remove explicit port override** (since 3200 is now default):

```yaml
# BEFORE (chart v1.x needed this):
server:
  http_listen_port: 3200  # Override legacy 3100 default
  grpc_listen_port: 9095

# AFTER (chart v3.x, port 3200 is default):
server:
  grpc_listen_port: 9095
  # http_listen_port: 3200 is implicit default, no override needed
```

**Recommendation:** Keep the explicit `http_listen_port: 3200` for clarity in documentation, even though it's now redundant. Comment can be updated to:

```yaml
# Tempo 2.8+ default is 3200 (explicit for documentation clarity).
# Matches Grafana datasource: http://tempo.observability.svc.cluster.local:3200
server:
  http_listen_port: 3200
  grpc_listen_port: 9095
```

### 2. Update `install.sh`

Change chart pull command:

```bash
# OLD:
helm_pull oci://ghcr.io/grafana/helm-charts/tempo 1.21.1

# NEW:
helm_pull oci://ghcr.io/grafana-community/helm-charts/tempo 3.1.0
```

And upgrade command:

```bash
# OLD:
helm upgrade --install tempo "$CHARTS_TMP/tempo-1.21.1.tgz" \

# NEW:
helm upgrade --install tempo "$CHARTS_TMP/tempo-3.1.0.tgz" \
```

### 3. Update README.md

Find the Tempo version reference and update:

```markdown
# OLD:
- Tempo v1.21.1 (app 2.7.1) - distributed tracing storage

# NEW:
- Tempo v3.1.0 (app 2.8.x) - distributed tracing storage, default port 3200
```

---

## Verification (After Upgrade)

### 1. Check Pod Status

```bash
kubectl get pods -n observability -l app.kubernetes.io/name=tempo
# NAME      READY   STATUS    RESTARTS   AGE
# tempo-0   1/1     Running   0          2m
```

### 2. Verify Port 3200 (Should be default now)

```bash
kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
# Expected: http_listen_port: 3200
```

### 3. Test Grafana Query

```bash
kubectl exec -n observability deployment/monitoring-grafana -- \
  wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready
# Expected: HTTP 200 or "Ingester not ready: waiting for..."
```

### 4. Check Grafana UI

Open: https://web-dev1-grafana.vucongtuanduong.dpdns.org/a/grafana-exploretraces-app/explore

- Select datasource: "Tempo"
- Run a query
- **Expected:** Traces load without timeout

### 5. Verify App Version

```bash
kubectl exec -n observability tempo-0 -- tempo --version
# Expected: tempo, version 2.8.x (branch: ..., revision: ...)
```

---

## Rollback (If Issues)

### Quick Rollback

```bash
helm rollback tempo -n observability
```

This restores chart v1.21.1 + Tempo app v2.7.1.

### Manual Rollback

If Helm history is corrupted:

```bash
helm uninstall tempo -n observability
helm install tempo oci://ghcr.io/grafana/helm-charts/tempo \
  --version 1.21.1 \
  -n observability \
  -f /tmp/tempo-values-backup.yaml \
  --wait
```

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Upgrade fails | Low | Medium | Test in dev first; rollback available |
| Port mismatch after upgrade | Very Low | Low | Verification step checks port 3200 |
| Data loss | Very Low | High | PVC persists; traces stored in backend |
| Breaking changes | Very Low | Medium | Pre-upgrade checklist confirms compatibility |

**Overall Risk:** 🟢 Low

---

## Timeline

1. **Dev/Staging Test:** 1 day (optional but recommended)
2. **Production Upgrade:** 10 minutes
3. **Verification:** 5 minutes
4. **Config Update (repo):** 10 minutes

**Total:** ~25 minutes production work, 1 day if including staging test.

---

## Decision

**Recommendation:** ✅ **Upgrade to Tempo chart v3.1.0**

**Rationale:**
- Eliminates root cause of port mismatch (3200 becomes default)
- Reduces config drift risk (one less override to maintain)
- Gets 2.8.x improvements (TraceQL features, 50% memory reduction, security fixes)
- Low risk (no breaking changes for our setup)
- Future-proof (aligns with Tempo v2.x best practice)

**Alternative (Not Recommended):** Keep v1.21.1 and manually override port.
- **Why not:** Requires maintaining override forever, risk of missing it in future deploys.

---

## References

- [Tempo 2.8 Release Notes](https://grafana.com/docs/tempo/latest/release-notes/v2-8/) - Port 3200 default, breaking changes
- [Tempo Helm Chart](https://github.com/grafana/helm-charts/tree/main/charts/tempo) - Official chart repo
- [Tempo v3.1.0 on ArtifactHub](https://artifacthub.io/packages/helm/grafana-community/tempo/3.1.0) - Latest chart version
- [Issue #4945](https://github.com/grafana/tempo/issues/4945) - Rationale for port 3200 default
- [PR #4960](https://github.com/grafana/tempo/pull/4960) - Implementation of port change

---

**Prepared by:** AI Agent  
**Review date:** 2026-11-08  
**Status:** Ready for execution
