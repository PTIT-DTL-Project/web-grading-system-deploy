# Grafana Tempo Metrics Query Error: "empty ring"

**Date:** 2026-11-08  
**Error:** `error finding generators: empty ring`  
**Impact:** Grafana Explore Traces UI shows errors when loading  

---

## Error Logs

```
logger=plugin.tempo level=error msg="Error processing TraceQL query"
error="failed to execute TraceQL query: {} | rate() 
Status: 500 Internal Server Error 
Body: error querying generators in Querier.queryRangeRecent: error finding generators: empty ring"
```

---

## Root Cause

**Grafana UI automatically runs metrics queries** like:
```
{nestedSetParent<0 && true} | rate()
{} | rate()
```

The **`| rate()`** operator requires **metrics generator** component, but:
- `metricsGenerator.enabled: false` in tempo-values.yaml
- This is intentional for dev (saves 100-200MB RAM)
- Grafana UI doesn't respect this and tries metrics query anyway

---

## Quick Fix (User Side)

### In Grafana Explore Traces UI:

1. Open: https://web-dev1-grafana.vucongtuanduong.dpdns.org/a/grafana-exploretraces-app/explore

2. **Avoid "Rate" and metrics visualizations:**
   - Don't use `| rate()`, `| histogram()`, or metrics aggregations
   - Use **Search** or **TraceQL select** only:
     ```
     { span.http.status_code > 400 }
     { resource.service.name = "api-gateway" }
     ```

3. **Switch to classic Tempo datasource query:**
   - Go to **Explore** (not Traces App)
   - Select datasource: **Tempo**
   - Use **Search** tab or **TraceQL** tab (without metrics operators)

---

## Permanent Fix Options

### Option 1: Disable metrics in Grafana datasource (RECOMMENDED)

Edit Tempo datasource config in Grafana UI:

1. Go to: **Connections → Data sources → Tempo**
2. Scroll to **Additional settings**
3. Find **"Enable metrics queries"** → **Uncheck** (if available)
4. Save

**OR** update datasource YAML:

```yaml
# In kube-prometheus-stack-values.yaml
grafana:
  datasources:
    datasource.yaml:
      datasources:
        - name: Tempo
          type: tempo
          url: http://tempo.observability.svc.cluster.local:3200
          jsonData:
            tracesToMetrics:
              datasourceUid: prometheus
            # Add this:
            enableMetrics: false  # Disable metrics queries
```

---

### Option 2: Enable metrics generator (if metrics needed)

**Cost:** +100-200MB RAM, +50-100m CPU

Edit `tempo-values.yaml`:

```yaml
tempo:
  metricsGenerator:
    enabled: true
    
  resources:
    requests: { cpu: 200m, memory: 384Mi }  # Increase from 100m/256Mi
    limits: { cpu: 600m, memory: 768Mi }    # Increase from 500m/512Mi
```

**Then add remote_write to Prometheus:**

```yaml
tempo:
  metricsGenerator:
    enabled: true
    config:
      storage:
        remote_write:
          - url: http://monitoring-kube-prometheus-prometheus.observability.svc.cluster.local:9090/api/v1/write
```

**Deploy:**
```bash
cd deploy/observability
./install.sh
```

---

### Option 3: Ignore errors (workaround)

Errors are **non-fatal**:
- ✅ Trace search still works
- ✅ TraceQL select queries work
- ❌ Only metrics queries fail

**If you only need traces (not metrics),** just **ignore the errors** in Grafana logs.

---

## Verification

### After fix, check:

1. **Grafana logs should NOT show:**
   ```
   error finding generators: empty ring
   ```

2. **Grafana UI should load without errors:**
   - No red error banners
   - Traces load successfully

3. **Test query:**
   ```
   { span.http.method = "GET" }
   ```
   Should return traces without 500 error.

---

## Why This Happens

**Grafana Explore Traces App (grafana-exploretraces-app)** is designed for **production observability** where:
- Metrics generator is expected to be enabled
- Users want RED metrics (Rate, Errors, Duration)
- TraceQL metrics queries are common

**But in dev/lite setup:**
- We disable metrics generator to save resources
- UI doesn't adapt and still tries metrics queries
- Results in harmless but noisy errors

---

## Related

- [Tempo Metrics Generator Docs](https://grafana.com/docs/tempo/latest/metrics-generator/)
- [TraceQL Metrics](https://grafana.com/docs/tempo/latest/traceql/metrics-queries/)
- tempo-values.yaml comment: "Span metrics need the metrics generator..."

---

**Prepared by:** AI Agent  
**Review date:** 2026-11-08  
**Status:** Error identified, workarounds documented  
**Recommendation:** Option 1 (disable metrics in datasource config) or Option 3 (ignore)
