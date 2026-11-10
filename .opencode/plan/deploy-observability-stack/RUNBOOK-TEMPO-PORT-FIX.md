# RUNBOOK: Fix Tempo Traces Query Timeout

**Date:** 2026-11-08  
**Priority:** High  
**Estimated Time:** 2-5 minutes  
**Requires:** kubectl access to production cluster  

---

## Problem

Grafana cannot query Tempo traces. Error in Grafana logs:
```
dial tcp 10.43.145.208:3200: i/o timeout
```

**Root Cause:** Tempo is listening on port 3100 (chart default), but Grafana datasource expects port 3200.

---

## Verification (Before Fix)

Run this to confirm the issue:

```bash
kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
```

**Expected output (WRONG):**
```
http_listen_port: 3100
```

---

## Fix Options

### Option 1: kubectl edit (Fastest - 30 seconds)

**Recommended if you need immediate fix without Helm.**

```bash
# Step 1: Edit ConfigMap
kubectl edit configmap tempo -n observability
```

Find line:
```yaml
http_listen_port: 3100
```

Change to:
```yaml
http_listen_port: 3200
```

Save and exit (`:wq` in vim).

```bash
# Step 2: Restart Tempo
kubectl rollout restart statefulset/tempo -n observability

# Step 3: Wait for rollout
kubectl rollout status statefulset/tempo -n observability
# Wait until: "statefulset rolling update complete"
```

---

### Option 2: Helm Upgrade (Recommended for production)

**Use this if you want the fix to persist across future Helm operations.**

```bash
cd /path/to/web-grading-system-deploy/deploy/observability

# Upgrade Tempo with values file
helm upgrade tempo grafana/tempo \
  -n observability \
  -f charts/tempo-values.yaml \
  --version 1.21.1 \
  --wait

# The tempo-values.yaml already has the fix:
# server:
#   http_listen_port: 3200
```

---

### Option 3: Run install.sh (Simplest)

**If you have Helm and want automated verification.**

```bash
cd /path/to/web-grading-system-deploy/deploy/observability
./install.sh
```

The script will:
1. Install/upgrade all observability components
2. Auto-verify Tempo is listening on port 3200
3. Show pass/fail status

---

## Verification (After Fix)

### 1. Check Config

```bash
kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
```

**Expected output (CORRECT):**
```
http_listen_port: 3200
```

### 2. Test Connectivity from Grafana

```bash
kubectl exec -n observability deployment/monitoring-grafana -- \
  wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready
```

**Expected:** HTTP 200 response or "Ingester not ready: waiting for 15s after being ready"

### 3. Check Grafana UI

Open: https://web-dev1-grafana.vucongtuanduong.dpdns.org/a/grafana-exploretraces-app/explore

- Select datasource: "Tempo"
- Run a query (e.g., select any service from dropdown)
- **Before fix:** Timeout error
- **After fix:** Traces displayed

---

## Rollback (If Needed)

If you used **kubectl edit**:
```bash
kubectl edit configmap tempo -n observability
# Change http_listen_port back to 3100
kubectl rollout restart statefulset/tempo -n observability
```

If you used **Helm**:
```bash
helm rollback tempo -n observability
```

---

## Why Port 3200?

- **Tempo v2.x best practice:** Port 3200 is the standard HTTP port
- **Grafana datasource config:** Already configured to use port 3200
- **OTLP ingestion:** Backend services use port 4318 (not affected by this change)
- **Minimal changes:** Only 1 file needs update vs. changing Grafana (3-4 files)

---

## Notes

- **Downtime:** ~30 seconds during Tempo pod restart
- **Data loss:** None (Tempo stores traces in storage backend)
- **Backend services:** No changes needed (they send to port 4318 OTLP endpoint)
- **Future deployments:** Fix is already committed in repo (`charts/tempo-values.yaml`)

---

## Contact

If you encounter issues:
1. Check Tempo pod logs: `kubectl logs -n observability tempo-0 -f`
2. Check Grafana datasource config: Grafana UI → Connections → Data sources → Tempo
3. Verify network policy: `kubectl get networkpolicy -n observability`

---

**Prepared by:** AI Agent  
**Review date:** 2026-11-08  
**Purpose:** Fix Tempo HTTP port mismatch causing trace query timeouts in production
