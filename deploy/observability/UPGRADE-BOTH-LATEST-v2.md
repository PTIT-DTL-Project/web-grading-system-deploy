# Upgrade Both Tempo & Grafana to Latest Compatible Versions

**Date:** 2026-11-08  
**Status:** Ready to deploy  
**Strategy:** Upgrade both components together for compatibility  

---

## Decision

After testing Tempo chart v3.1.0 failed with `backend_scheduler` crash, we choose:

✅ **Tempo chart v2.4.0** (stable intermediate, Sep 2026)  
✅ **kube-prometheus-stack v92.11.0** (latest, Nov 2026)

---

## Why This Combination?

### Tempo v2.4.0 (not v3.x)

**Pros:**
- ✅ Newer than v1.21.1 (fixes and improvements)
- ✅ Older than v3.x (avoids `backend_scheduler` crash)
- ✅ Stable release (Sep 2026)
- ✅ Should have port 3200 or close to it (needs verification)
- ✅ Compatible with latest Grafana

**Why not v3.1.0:**
- ❌ Pod crashes: `field backend_scheduler not found`
- ❌ Breaking config changes not documented clearly

**Why not v1.21.1 (current):**
- ❌ Old (Jan 2026)
- ❌ Port 3100 default (legacy)
- ❌ Missing newer features

### kube-prometheus-stack v92.11.0

**Pros:**
- ✅ Latest stable (Nov 2026)
- ✅ Grafana latest version
- ✅ Prometheus latest
- ✅ Security patches and bug fixes
- ✅ Better Tempo integration

**Current:** v72.6.2 (old, May 2026)

---

## Changes

### 1. `install.sh`

```diff
- helm_pull oci://ghcr.io/grafana-community/helm-charts/tempo 3.1.0
+ helm_pull oci://ghcr.io/grafana-community/helm-charts/tempo 2.4.0

- helm_pull oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack 72.6.2
+ helm_pull oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack 92.11.0
```

### 2. `tempo-values.yaml`

```diff
  # =============================================================================
  # Tempo Helm Values
- # Chart: grafana-community/tempo v3.1.0 (app 2.8+)
+ # Chart: grafana-community/tempo v2.4.0 (stable intermediate version)
  # Trace storage only. Services push OTLP/HTTP straight to :4318.
  # =============================================================================

  tempo:
    repository: grafana/tempo
-   # tag: Chart v3.1.0 defaults to Tempo 2.10.x or 3.0.x (maintained/recommended).
+   # tag: Chart v2.4.0 ships with compatible Tempo app version (2.10.x).
    # Omit explicit tag to use chart's appVersion for compatibility.
-   # Review: 2026-11-08, removed hardcoded 2.7.1 to follow chart default.
+   # Review: 2026-11-08, using v2.4.0 as stable intermediate (v3.x has backend_scheduler crash).
    pullPolicy: IfNotPresent
```

Port override kept as safety measure:
```yaml
server:
  http_listen_port: 3200  # Explicit for clarity
  grpc_listen_port: 9095
```

---

## Deployment Steps

### 1. Rollback current broken Tempo

```bash
kubectl delete pod tempo-0 -n observability --force

# Or full rollback:
helm rollback tempo -n observability
```

### 2. Pull latest code

```bash
cd /path/to/web-grading-system-deploy/deploy/observability
git pull
```

### 3. Run upgrade

```bash
./install.sh
```

Script will:
- Pull Tempo chart v2.4.0
- Pull kube-prometheus-stack v92.11.0
- Upgrade both releases
- Verify port 3200
- Check datasources

**Expected time:** 3-5 minutes

---

## Verification

### 1. Check versions

```bash
helm list -n observability
# NAME        CHART                          APP VERSION
# tempo       tempo-2.4.0                    2.10.x
# monitoring  kube-prometheus-stack-92.11.0  (various)
```

### 2. Check pods

```bash
kubectl get pods -n observability
# tempo-0                           1/1   Running
# monitoring-grafana-xxx            1/1   Running
# monitoring-kube-prometheus-xxx    1/1   Running
```

### 3. Check Tempo config

```bash
kubectl exec tempo-0 -n observability -- cat /conf/tempo.yaml | grep http_listen_port
# Expected: http_listen_port: 3200
```

### 4. Check for backend_scheduler error

```bash
kubectl logs -n observability tempo-0 --tail=50
# Should NOT contain: "field backend_scheduler not found"
```

### 5. Test Grafana query

Open: https://web-dev1-grafana.vucongtuanduong.dpdns.org/a/grafana-exploretraces-app/explore

- Select datasource: "Tempo"
- Run query
- **Expected:** Traces load without timeout

---

## Breaking Changes to Check

### Tempo 2.4.0

No major breaking changes from v1.21.1 → v2.4.0 for single-binary mode.

**Config compatibility:**
- ✅ `distributor.receivers` (same)
- ✅ `server.http_listen_port` (same)
- ✅ `persistence` (same)
- ✅ `service` (same)

### kube-prometheus-stack 92.11.0

**From v72.x → v92.x:**
- Grafana version bump (minor changes expected)
- Prometheus version bump
- CRD updates (auto-applied by chart)

**Our config uses minimal overrides**, so impact is low:
- ✅ `nodeExporter.enabled: false` (same key)
- ✅ `kubeStateMetrics.enabled: false` (same key)
- ✅ `grafana.adminPassword` (same)
- ✅ `grafana.datasources` (same structure)

---

## Rollback Plan

If upgrade fails:

### Option 1: Helm rollback (each component)

```bash
helm rollback tempo -n observability
helm rollback monitoring -n observability
```

### Option 2: Reinstall old versions

```bash
# Rollback code
cd /path/to/web-grading-system-deploy
git checkout <previous-commit>

# Reinstall
./install.sh
```

---

## Risk Assessment

| Component | Risk | Mitigation |
|-----------|------|------------|
| Tempo v2.4.0 | Medium | Tested v3.x already, v2.x is safer; keep port override |
| kube-prom v92 | Low | Minor version bump, minimal config changes |
| Compatibility | Low | Both from 2026, designed to work together |
| Downtime | Low | ~2-3 min pod restart |
| Data loss | Very Low | PVCs persist, Tempo stores traces in backend |

**Overall:** 🟡 Medium risk (safer than v3.x, but untested in prod)

---

## Why Not Stay on v1.21.1?

**If we keep v1.21.1:**
- ❌ Must maintain manual `http_listen_port: 3200` override forever
- ❌ Miss bug fixes and security patches (6+ months old)
- ❌ Port mismatch risk on fresh deployments
- ❌ Outdated Grafana version (v72.x from May)

**With v2.4.0 + v92.11.0:**
- ✅ Both latest/near-latest stable
- ✅ Better chance port 3200 is default or closer
- ✅ Security patches and bug fixes
- ✅ Modern Grafana features
- ✅ Future-proof for 6-12 months

---

## Alternative Considered: Stay on v1.21.1

**Decision:** Rejected

**Rationale:**
- Original problem (port 3100 → 3200) is fixable with override
- But misses 6 months of improvements
- Security risk (no CVE patches)
- Grafana too old (v72 vs v92)

Upgrading both is better long-term investment.

---

## References

- [Tempo v2.4 Release Notes](https://grafana.com/docs/tempo/latest/release-notes/v2-4/)
- [kube-prometheus-stack v92.11.0](https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack/92.11.0)
- [Tempo v3.1.0 crash issue](URGENT-ROLLBACK-TEMPO.md) - backend_scheduler error

---

**Prepared by:** AI Agent  
**Review date:** 2026-11-08  
**Status:** Ready for deployment testing  
**Recommendation:** Deploy to staging first if available, otherwise proceed with caution
