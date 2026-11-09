# Tempo Traces Issue - Solution Summary (Dứt Điểm)

> **Trạng thái:** Code đã fix dứt điểm trong repo ✅  
> **Cần làm:** Re-deploy trên production cluster để apply fix  
> **Thời gian:** ~3 phút

---

## ✅ Đã Fix Trong Repo (Permanent Solutions)

### 1. **`tempo-values.yaml`** - Config đã đúng
```yaml
server:
  http_listen_port: 3200  # ✅ Đúng port (Grafana expects 3200)
  grpc_listen_port: 9095

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: "0.0.0.0:4317"  # ✅ Bind tường minh
        http:
          endpoint: "0.0.0.0:4318"
```

**Comments đã thêm:** Giải thích tại sao cần port 3200 và 0.0.0.0 binding.

### 2. **`install.sh`** - Auto-verify port 3200
Thêm verification step:
```bash
[verify] Tempo HTTP port...
```
- Check runtime config trong pod
- Fail ngay nếu port ≠ 3200
- Người deploy biết ngay có vấn đề

### 3. **`deploy/observability/README.md`** - Troubleshooting guide
Thêm section đầy đủ:
- Diagnosis commands
- Fix steps
- Verification checklist

### 4. **Skill files** (`.kilo/` & `.opencode/`)
Update với critical warning:
```
**CRITICAL: HTTP server port must be 3200.**
```
AI agents sẽ biết gotcha này khi làm việc với observability stack.

### 5. **Plan files**
- `tempo-port-mismatch-fix.md` - Root cause analysis đầy đủ
- `MANUAL-FIX-STEPS.md` - Hướng dẫn chi tiết
- `URGENT-tempo-redeploy-fix.sh` - Script tự động

---

## 🚀 Apply Fix Trên Production (3 Phút)

### Option A: Run Script (Recommended)

```bash
# SSH vào production cluster
ssh your-production-server

# Navigate
cd /path/to/web-grading-system-deploy/.opencode/plan/deploy-observability-stack

# Run script
chmod +x URGENT-tempo-redeploy-fix.sh
./URGENT-tempo-redeploy-fix.sh
```

Script sẽ:
1. ✅ Backup config
2. ✅ Pull chart từ GHCR (retry 3 lần)
3. ✅ Upgrade Tempo release
4. ✅ Verify port 3200
5. ✅ Test connectivity

### Option B: Manual Commands

```bash
# Navigate
cd /path/to/web-grading-system-deploy/deploy/observability

# Pull chart
CHARTS_TMP=$(mktemp -d)
helm pull oci://ghcr.io/grafana/helm-charts/tempo --version 1.21.1 -d "$CHARTS_TMP"

# Upgrade Tempo
helm upgrade --install tempo "$CHARTS_TMP/tempo-1.21.1.tgz" \
  -n observability -f charts/tempo-values.yaml --wait --timeout 5m

# Verify
kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
# Expected: http_listen_port: 3200
```

### Option C: Use Install Script

```bash
cd /path/to/web-grading-system-deploy/deploy/observability
./install.sh
```

Install script bây giờ có verification và sẽ fail nếu port sai.

---

## ✓ Verification (Sau Deploy)

```bash
# 1. Check pod ready
kubectl get pod -n observability tempo-0
# Expected: 1/1 Running

# 2. Check port trong config
kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
# Expected: http_listen_port: 3200 (NOT 3100)

# 3. Test connectivity từ Grafana
kubectl exec -n observability deployment/monitoring-grafana -- \
  wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready
# Expected: Response trong <5s, KHÔNG timeout

# 4. Check Grafana UI
# Open: https://web-dev1-grafana.vucongtuanduong.dpdns.org/a/grafana-exploretraces-app/explore
# Try query → KHÔNG còn "dial tcp...3200: i/o timeout"
```

---

## 📋 Files Changed (Permanent)

| File | Change | Purpose |
|---|---|---|
| `deploy/observability/charts/tempo-values.yaml` | Comments + verification notes | Giải thích rõ tại sao cần port 3200 |
| `deploy/observability/install.sh` | Add verification step | Auto-check port 3200 sau deploy |
| `deploy/observability/README.md` | Troubleshooting section | Guide cho người deploy |
| `.kilo/skills/observability-stack/SKILL.md` | Update Tempo section | AI agents biết gotcha |
| `.opencode/skills/observability-stack/SKILL.md` | Sync with .kilo | Consistency |

---

## 🎯 Root Cause Recap

**Vấn đề:**
- Chart `grafana/tempo` v1.21.1 default port: **3100** (legacy Loki port)
- Grafana datasource expects: **3200** (Tempo v2.x standard)
- Nếu không override → **timeout** (Grafana connects 3200, Tempo listens 3100)

**Tại sao khó phát hiện:**
- Pod status: `1/1 Running` ✅
- Service DNS: resolves ✅
- OTLP ingestion: hoạt động ✅ (port 4318)
- Chỉ query API fail (port 3200) ❌
- Error: "i/o timeout" (không nói rõ "no listener")

**Fix:**
```yaml
server:
  http_listen_port: 3200  # Override chart default 3100
```

**Prevention:**
- `install.sh` bây giờ verify runtime
- Skill files document rõ ràng
- Comments trong code giải thích why

---

## 🔄 Workflow Going Forward

### Lần Sau Deploy Từ Đầu:

```bash
cd deploy/observability
./install.sh
```

→ Script tự verify port 3200 và **fail rõ ràng** nếu sai  
→ Người deploy fix ngay, không phải debug sau

### Nếu Upgrade Helm Chart:

1. Test trên staging trước
2. Verify `tempo-values.yaml` vẫn có `server.http_listen_port: 3200`
3. Chạy `helm template` và grep port
4. Deploy
5. Run verification commands

### Nếu Thấy Timeout Lại:

```bash
# 1. Check port ngay
kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port

# 2. Nếu ≠ 3200 → re-deploy
cd deploy/observability && ./install.sh

# 3. Verify lại
kubectl exec tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
```

---

## 📚 Reference Documents

1. **Root cause analysis:**  
   `.opencode/plan/deploy-observability-stack/tempo-port-mismatch-fix.md`

2. **Manual fix steps:**  
   `.opencode/plan/deploy-observability-stack/MANUAL-FIX-STEPS.md`

3. **Auto-fix script:**  
   `.opencode/plan/deploy-observability-stack/URGENT-tempo-redeploy-fix.sh`

4. **Skill file:**  
   `.kilo/skills/observability-stack/SKILL.md` (section 3: Tempo)

5. **README:**  
   `deploy/observability/README.md` (troubleshooting section)

---

## ✨ Tóm Tắt

✅ **Code đã fix dứt điểm trong repo**  
✅ **Documentation đầy đủ**  
✅ **Auto-verification trong install script**  
✅ **AI agents biết gotcha**  
✅ **Không ai bị lỗi này nữa**

❗ **Cần làm bây giờ:** Re-deploy trên production cluster (3 phút)

```bash
# Quick command
cd /path/to/web-grading-system-deploy/deploy/observability && ./install.sh
```

Xong! 🎉
