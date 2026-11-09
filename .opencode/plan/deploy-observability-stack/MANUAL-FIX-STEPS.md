# Manual Fix Steps - Tempo Port 3200

> **Cần chạy trên production cluster** (nơi có kubectl access tới observability namespace)

## Vấn Đề Hiện Tại

```bash
# Evidence
$ kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
http_listen_port: 3100  # ❌ SAI - phải là 3200

# Grafana logs
dial tcp 10.43.145.208:3200: i/o timeout  # Timeout vì không có process listen 3200
```

---

## Option 1: Chạy Script Tự Động (Khuyến Nghị)

```bash
cd /path/to/web-grading-system-deploy/.opencode/plan/deploy-observability-stack
chmod +x URGENT-tempo-redeploy-fix.sh
./URGENT-tempo-redeploy-fix.sh
```

Script sẽ:
1. Verify config hiện tại
2. Backup values file
3. Pull Tempo chart từ GHCR
4. Upgrade Helm release
5. Verify fix applied
6. Test connectivity

---

## Option 2: Manual Steps (Nếu Script Fail)

### Step 1: Verify fix trong values file

```bash
cd /path/to/web-grading-system-deploy/deploy/observability
grep -A5 "^server:" charts/tempo-values.yaml
```

**Expected output:**
```yaml
server:
  http_listen_port: 3200
  grpc_listen_port: 9095
```

**Nếu KHÔNG có hoặc vẫn là 3100:** Edit file và thêm/sửa section `server:` như trên.

### Step 2: Pull Tempo chart

```bash
CHARTS_TMP=$(mktemp -d)
helm pull oci://ghcr.io/grafana/helm-charts/tempo --version 1.21.1 -d "$CHARTS_TMP"
# Output: tempo-1.21.1.tgz trong $CHARTS_TMP
```

### Step 3: Upgrade Tempo

```bash
helm upgrade --install tempo "$CHARTS_TMP/tempo-1.21.1.tgz" \
  --namespace observability \
  --values charts/tempo-values.yaml \
  --wait \
  --timeout 5m
```

Wait for completion (~1-2 minutes).

### Step 4: Verify pod restart

```bash
kubectl get pod -n observability tempo-0 -w
# Wait for: Running + 1/1 READY
```

### Step 5: Verify config applied

```bash
# Check config trong pod
kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep -A5 "^server:"

# Expected:
# server:
#   http_listen_port: 3200

# Check listening port
kubectl exec -n observability tempo-0 -- netstat -tln | grep :3200
# Expected: tcp  0  0  :::3200  :::*  LISTEN
```

### Step 6: Test connectivity

```bash
# Từ Grafana pod
kubectl exec -n observability deployment/monitoring-grafana -- \
  wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready

# Expected: Output HTML/JSON trong <5s, KHÔNG timeout
```

### Step 7: Verify trong Grafana UI

1. Mở: https://web-dev1-grafana.vucongtuanduong.dpdns.org
2. Go to: **Explore** → **Tempo**
3. Try search traces hoặc query
4. **Expected:** Không còn "dial tcp...3200: i/o timeout"

---

## Troubleshooting

### Nếu helm pull bị timeout

```bash
# Retry với exponential backoff
for i in 1 2 3; do
  helm pull oci://ghcr.io/grafana/helm-charts/tempo --version 1.21.1 -d /tmp && break
  echo "Retry $i/3..."
  sleep $((i * 10))
done
```

### Nếu pod không ready sau upgrade

```bash
# Check events
kubectl describe pod -n observability tempo-0 | tail -30

# Check logs
kubectl logs -n observability tempo-0 --tail=100

# Common issues:
# - OOMKilled → increase memory limits (already set to 512Mi, should be OK)
# - CrashLoopBackOff → config syntax error, check logs
```

### Nếu vẫn timeout sau fix

```bash
# 1. Verify Service có port 3200
kubectl get svc -n observability tempo -o yaml | grep -A10 "ports:"
# Must have: - port: 3200, targetPort: 3200

# 2. Verify endpoints
kubectl get endpoints -n observability tempo
# Must have: 10.42.x.x:3200 in list

# 3. Check pod logs cho lỗi startup
kubectl logs -n observability tempo-0 | grep -i "error\|fail\|listen"

# 4. Test direct pod IP (bypass Service)
POD_IP=$(kubectl get pod -n observability tempo-0 -o jsonpath='{.status.podIP}')
kubectl run curl-test --rm -it --image=curlimages/curl -- \
  curl -v http://$POD_IP:3200/ready
```

---

## Rollback (Nếu Cần)

```bash
# Restore backup values
cd /path/to/web-grading-system-deploy/deploy/observability
cp charts/tempo-values.yaml.backup-YYYYMMDD-HHMMSS charts/tempo-values.yaml

# Re-deploy với config cũ
helm upgrade --install tempo oci://ghcr.io/grafana/helm-charts/tempo \
  --version 1.21.1 \
  --namespace observability \
  --values charts/tempo-values.yaml \
  --wait
```

**Lưu ý:** Rollback sẽ khôi phục lại lỗi port 3100 → Grafana vẫn timeout.

---

## Expected Timeline

| Step | Duration |
|---|---|
| Pull chart | 10-30s |
| Helm upgrade | 30-60s |
| Pod restart | 20-40s |
| Tempo ready | 10-30s |
| **Total** | **~2-3 minutes** |

Traces ingestion bị pause trong thời gian pod restart (~30-60s). Traces được buffer ở backend services và retry sau khi Tempo lên lại.

---

## Verification Checklist

- [ ] Config file có `server.http_listen_port: 3200`
- [ ] Helm upgrade complete không lỗi
- [ ] Pod `tempo-0` ở trạng thái `1/1 Running`
- [ ] Config trong pod show `http_listen_port: 3200`
- [ ] `netstat` show port `:3200` listening
- [ ] Wget từ Grafana pod tới Tempo:3200 không timeout
- [ ] Service endpoints có `:3200` trong list
- [ ] Grafana UI không còn timeout error

---

## Quick Commands Summary

```bash
# Navigate
cd /path/to/web-grading-system-deploy/deploy/observability

# Verify current state
kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port

# Pull chart + upgrade (all-in-one)
CHARTS_TMP=$(mktemp -d) && \
helm pull oci://ghcr.io/grafana/helm-charts/tempo --version 1.21.1 -d "$CHARTS_TMP" && \
helm upgrade --install tempo "$CHARTS_TMP/tempo-1.21.1.tgz" \
  -n observability -f charts/tempo-values.yaml --wait --timeout 5m

# Wait for ready
kubectl wait --for=condition=ready pod/tempo-0 -n observability --timeout=120s

# Verify
kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
kubectl exec -n observability tempo-0 -- netstat -tln | grep :3200
kubectl exec -n observability deployment/monitoring-grafana -- \
  wget -O- --timeout=5 http://tempo:3200/ready
```

---

## Contact

Nếu vẫn gặp vấn đề sau khi follow tất cả steps:
1. Capture full output của mỗi command
2. Copy Tempo logs: `kubectl logs -n observability tempo-0 --tail=200`
3. Copy Service definition: `kubectl get svc -n observability tempo -o yaml`
4. Gửi cho team để debug thêm
