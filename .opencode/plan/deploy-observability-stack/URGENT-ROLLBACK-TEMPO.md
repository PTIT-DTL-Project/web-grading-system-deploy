# 🚨 URGENT: Rollback Tempo Immediately

**Date:** 2026-11-08 21:28  
**Status:** CRITICAL - Tempo pods crashing  
**Priority:** P0 - Immediate action required  

---

## Problem

Tempo pod is in **CrashLoopBackOff** after upgrade to chart v3.1.0:

```
NAME      READY   STATUS             RESTARTS     AGE
tempo-0   0/1     CrashLoopBackOff   7 (8s ago)   10m
```

**Error:**
```
failed parsing config: failed to parse configFile /conf/tempo.yaml: yaml: unmarshal errors:
  line 7: field backend_scheduler not found in type app.Config
```

**Root cause:** Chart v3.1.0 injects `backend_scheduler` field that Tempo v3.x no longer supports.

---

## ROLLBACK NOW

### Option 1: Helm rollback (fastest)

```bash
helm rollback tempo -n observability
```

This will restore chart v1.21.1 + Tempo app v2.7.1 (last working state).

### Option 2: Manual rollback

```bash
helm uninstall tempo -n observability

# Wait for pod to terminate
kubectl wait --for=delete pod/tempo-0 -n observability --timeout=60s

# Reinstall old version
helm install tempo oci://ghcr.io/grafana/helm-charts/tempo \
  --version 1.21.1 \
  -n observability \
  -f charts/tempo-values.yaml \
  --wait
```

### Option 3: Edit ConfigMap to remove backend_scheduler

```bash
kubectl edit configmap tempo -n observability

# Remove the line with "backend_scheduler"
# Save and exit

kubectl rollout restart statefulset/tempo -n observability
```

---

## Verify after rollback

```bash
kubectl get pods -n observability
# Expected: tempo-0   1/1   Running

kubectl logs -n observability tempo-0 --tail=20
# Should NOT show "field backend_scheduler not found"

kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
# Expected: http_listen_port: 3100 (old version) or 3200 (if override worked)
```

---

## Root Cause Analysis

**Chart migration issue:**
- Chart repo migrated from `grafana/tempo` to `grafana-community/tempo`
- Chart v3.1.0 may have incorrect template or incompatible default config
- The `backend_scheduler` field was removed in Tempo 2.4+ but chart still injects it

**Why this happened:**
- We upgraded chart from v1.21.1 → v3.1.0 to fix port 3200 default
- Chart v3.1.0 has breaking config incompatibility
- Our values file is correct, but chart's default template is broken

---

## Next Steps

1. **Immediate:** Rollback to chart v1.21.1 (working version)
2. **Short-term:** Keep chart v1.21.1 + manual port override
3. **Long-term:** Research alternative:
   - Try chart v2.x (intermediate version)
   - Wait for chart v3.2+ bugfix
   - Use `tempo-distributed` chart instead (microservices mode)
   - Stick with v1.21.1 + manual override (safest)

---

## Revert Code Changes

After rollback succeeds, revert repo to old config:

```bash
cd /path/to/web-grading-system-deploy
git revert HEAD~2  # Revert the upgrade commits
git push origin main
```

Or manually restore:

```bash
git checkout c266faa -- deploy/observability/charts/tempo-values.yaml
git checkout c266faa -- deploy/observability/install.sh
git commit -m "revert: rollback Tempo to chart v1.21.1 due to backend_scheduler crash"
```

---

## Apology Note

**To reviewer/admin:**

I apologize for this issue. The upgrade to chart v3.1.0 was intended to fix the port mismatch at root cause, but introduced a worse problem (pod crash). 

**What I should have done:**
1. Test in staging first
2. Check chart changelog for breaking changes
3. Verify chart v3.1.0 actually uses correct Tempo app version

**Lesson learned:**
- Major chart version upgrades (v1 → v3) need staging validation
- "Fix at root cause" doesn't always mean "upgrade to latest"
- Sometimes manual override is safer than version upgrade

I will create a proper test plan if we attempt this upgrade again in the future.

---

**Prepared by:** AI Agent  
**Incident time:** 2026-11-08 21:28  
**Action required:** Immediate rollback
