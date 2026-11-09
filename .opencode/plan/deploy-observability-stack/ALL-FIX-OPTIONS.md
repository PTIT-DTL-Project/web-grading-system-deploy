# Tất Cả Các Cách Fix Tempo Port 3200 (Không Cần Helm)

> **Vấn đề:** Tempo listen port 3100, Grafana expect 3200 → timeout  
> **Mục tiêu:** Đổi Tempo sang port 3200

---

## 🎯 Option 1: Kubectl Patch ConfigMap (NHANH NHẤT - 30s)

**Không cần Helm, không cần restart pod ban đầu**

### Step 1: Backup ConfigMap hiện tại
```bash
kubectl get configmap -n observability tempo -o yaml > tempo-configmap-backup.yaml
```

### Step 2: Edit ConfigMap trực tiếp
```bash
kubectl edit configmap -n observability tempo
```

Trong editor, tìm section `server:` và sửa:
```yaml
server:
  http_listen_port: 3100  # ← Đổi thành 3200
  grpc_listen_port: 9095
```

Save và thoát (`:wq` nếu vim).

### Step 3: Restart Tempo pod để áp dụng config mới
```bash
kubectl delete pod -n observability tempo-0
# Pod sẽ tự restart với config mới
```

### Step 4: Verify
```bash
# Đợi pod ready
kubectl wait --for=condition=ready pod/tempo-0 -n observability --timeout=120s

# Check config
kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
# Expected: http_listen_port: 3200

# Test
kubectl exec -n observability deployment/monitoring-grafana -- \
  wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready
```

**Pros:**
- ✅ Nhanh nhất (30s)
- ✅ Không cần Helm
- ✅ Không cần edit local files

**Cons:**
- ❌ Change không persist nếu Helm upgrade lại
- ❌ Phải nhớ làm lại nếu re-deploy

---

## 🎯 Option 2: Kubectl Patch StatefulSet (KHÔNG KHUYẾN NGHỊ)

**Patch trực tiếp StatefulSet, bypass Helm**

```bash
kubectl patch statefulset tempo -n observability --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/args/-",
    "value": "-server.http-listen-port=3200"
  }
]'
```

**Pros:**
- ✅ Không cần Helm
- ✅ Không cần edit ConfigMap

**Cons:**
- ❌ Helm sẽ conflict khi upgrade
- ❌ Khó rollback
- ❌ Không recommended

---

## 🎯 Option 3: ArgoCD/GitOps Workflow

**Nếu bạn dùng ArgoCD để deploy**

### Step 1: Edit values trong Git repo
```bash
cd /path/to/config-repo
vim helm-values/observability/tempo-values.yaml
```

Thêm:
```yaml
server:
  http_listen_port: 3200
```

### Step 2: Commit + Push
```bash
git add helm-values/observability/tempo-values.yaml
git commit -m "fix: Tempo HTTP port 3200"
git push
```

### Step 3: Sync ArgoCD
```bash
argocd app sync observability
# hoặc click "Sync" trong UI
```

**Pros:**
- ✅ GitOps compliant
- ✅ Change được tracked
- ✅ Dễ rollback

**Cons:**
- ❌ Cần có ArgoCD access
- ❌ Phụ thuộc vào CI/CD pipeline

---

## 🎯 Option 4: Manual YAML Apply (KHÔNG CẦN HELM)

**Generate manifest từ Helm, rồi kubectl apply**

### Step 1: Generate full manifest
```bash
cd /path/to/web-grading-system-deploy/deploy/observability

# Cần Helm để render (chỉ 1 lần)
helm template tempo oci://ghcr.io/grafana/helm-charts/tempo \
  --version 1.21.1 \
  -f charts/tempo-values.yaml \
  -n observability > tempo-manifests.yaml
```

### Step 2: Apply trực tiếp
```bash
kubectl apply -f tempo-manifests.yaml -n observability
```

### Step 3: Force restart
```bash
kubectl rollout restart statefulset/tempo -n observability
```

**Pros:**
- ✅ Không cần Helm trên production
- ✅ Full control

**Cons:**
- ❌ Cần Helm để render lần đầu
- ❌ Phải re-generate khi change values

---

## 🎯 Option 5: Kustomize Overlay (CHO DECLARATIVE SETUP)

**Tạo Kustomize patch**

### Step 1: Tạo kustomization structure
```bash
mkdir -p deploy/observability/overlays/production
cd deploy/observability/overlays/production
```

### Step 2: Tạo patch file
```bash
cat > tempo-port-patch.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo
  namespace: observability
data:
  tempo.yaml: |
    server:
      http_listen_port: 3200
      grpc_listen_port: 9095
    # ... rest of config
EOF
```

### Step 3: Tạo kustomization.yaml
```bash
cat > kustomization.yaml <<'EOF'
resources:
  - ../../base  # hoặc trỏ tới Helm output

patchesStrategicMerge:
  - tempo-port-patch.yaml
EOF
```

### Step 4: Apply
```bash
kubectl apply -k deploy/observability/overlays/production
```

**Pros:**
- ✅ Declarative
- ✅ Easy to version control
- ✅ Reusable

**Cons:**
- ❌ Setup overhead
- ❌ Cần refactor existing deployment

---

## 🎯 Option 6: Port Forward Workaround (TEMPORARY HACK)

**Không sửa Tempo, forward port từ pod**

### Setup port forward service
```bash
# Run continuously (in background or systemd)
kubectl port-forward -n observability tempo-0 3200:3100 &
```

### Update Grafana datasource
```yaml
# Point to forwarded port
url: http://localhost:3200  # forwards to tempo:3100
```

**Pros:**
- ✅ Không thay đổi Tempo
- ✅ Quick workaround

**Cons:**
- ❌ Port forward can break
- ❌ Single point of failure
- ❌ **TERRIBLE idea for production**
- ❌ Chỉ dùng để test thôi!

---

## 🎯 Option 7: Nhờ Người Có Quyền (REALISTIC)

**Nếu bạn không có quyền deploy**

### Step 1: Tạo request ticket/email
```
Subject: [URGENT] Fix Tempo Port Configuration

Hi team,

Grafana đang bị timeout khi query Tempo vì port mismatch:
- Tempo listening: port 3100
- Grafana expects: port 3200

Fix đã ready trong repo tại:
  web-grading-system-deploy/deploy/observability/charts/tempo-values.yaml

Chỉ cần chạy:
  cd deploy/observability && ./install.sh

Hoặc nếu không có Helm, có thể:
  kubectl edit configmap tempo -n observability
  Đổi http_listen_port: 3100 → 3200
  kubectl delete pod tempo-0 -n observability

Thời gian: ~3 phút
Downtime: ~30s (traces buffer và retry tự động)

Chi tiết: .opencode/plan/deploy-observability-stack/tempo-port-mismatch-fix.md

Thanks!
```

**Pros:**
- ✅ Đúng process
- ✅ Có người có quyền làm

**Cons:**
- ❌ Phải chờ

---

## 🎯 Option 8: Script Tự Động (ONE-CLICK)

**Chạy script tự detect và fix**

```bash
cd /path/to/web-grading-system-deploy/.opencode/plan/deploy-observability-stack

# Script sẽ tự:
# 1. Check có Helm không
# 2. Nếu có → helm upgrade
# 3. Nếu không → kubectl edit configmap + restart pod
# 4. Verify
./URGENT-tempo-redeploy-fix.sh
```

**Hoặc nếu không có Helm, chạy script này:**

```bash
#!/bin/bash
# quick-fix-no-helm.sh

set -e

echo "=== Quick Fix Tempo Port (No Helm) ==="

# Backup
kubectl get configmap tempo -n observability -o yaml > tempo-cm-backup-$(date +%s).yaml
echo "[1/4] Backup created"

# Patch ConfigMap
kubectl get configmap tempo -n observability -o yaml | \
  sed 's/http_listen_port: 3100/http_listen_port: 3200/' | \
  kubectl apply -f -
echo "[2/4] ConfigMap patched"

# Restart pod
kubectl delete pod tempo-0 -n observability
echo "[3/4] Pod restarting..."

# Wait
kubectl wait --for=condition=ready pod/tempo-0 -n observability --timeout=120s
echo "[4/4] Pod ready"

# Verify
PORT=$(kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port | awk '{print $2}')
if [ "$PORT" = "3200" ]; then
  echo "✓ SUCCESS: Tempo now on port 3200"
else
  echo "✗ FAIL: Port is $PORT"
  exit 1
fi
```

**Pros:**
- ✅ Automated
- ✅ Idempotent
- ✅ Has verification

**Cons:**
- ❌ Cần kubectl access

---

## 📋 Comparison Table

| Option | Speed | Persistence | Helm Required | Risk | Recommended |
|---|---|---|---|---|---|
| 1. kubectl edit ConfigMap | ⚡ 30s | ❌ No | ❌ No | ⭐ Low | ✅ YES (quick fix) |
| 2. kubectl patch StatefulSet | ⚡ 1min | ⚠️ Conflict | ❌ No | ⭐⭐⭐ High | ❌ NO |
| 3. ArgoCD/GitOps | 🐢 5min | ✅ Yes | ❌ No | ⭐ Low | ✅ YES (if using ArgoCD) |
| 4. Manual YAML apply | 🐢 3min | ⚠️ Manual | ✅ Yes (once) | ⭐⭐ Medium | ⚠️ OK |
| 5. Kustomize | 🐢 10min | ✅ Yes | ❌ No | ⭐ Low | ⚠️ Overkill |
| 6. Port forward | ⚡ 10s | ❌ No | ❌ No | ⭐⭐⭐⭐ Very High | ❌ NEVER |
| 7. Ask admin | 🐢 varies | ✅ Yes | ✅ Yes | ⭐ None | ✅ YES (no access) |
| 8. Auto script | ⚡ 2min | ⚠️ Depends | ⚠️ Optional | ⭐ Low | ✅ YES |

---

## 🚀 RECOMMENDED WORKFLOW

### Nếu có kubectl access:

```bash
# Quick fix (30 seconds)
kubectl edit configmap tempo -n observability
# Change http_listen_port: 3100 → 3200
# Save + exit

kubectl delete pod tempo-0 -n observability
kubectl wait --for=condition=ready pod/tempo-0 -n observability --timeout=120s

# Verify
kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
```

Done! ✅

### Persist the fix:

Sau khi quick fix, update repo để lần sau deploy không bị:
```bash
# Repo đã có fix rồi, chỉ cần note
git commit --allow-empty -m "fix: Tempo port 3200 applied to production"
git push
```

---

## ❓ Bạn Đang Ở Trường Hợp Nào?

1. **Có kubectl access, không có Helm?**  
   → Option 1: `kubectl edit configmap`

2. **Có Helm, có kubectl access?**  
   → Run `./install.sh` trong repo

3. **Không có quyền gì?**  
   → Option 7: Nhờ admin với email/ticket template trên

4. **Dùng GitOps (ArgoCD/Flux)?**  
   → Option 3: Push to git, sync

5. **Chỉ muốn test nhanh, không care persistence?**  
   → Option 1, rồi fix đàng hoàng sau

---

## 🆘 Nếu Tất Cả Fail

**Last resort: Deploy Tempo độc lập không qua Helm**

```bash
# 1. Get Tempo binary
kubectl run tempo-manual -n observability \
  --image=grafana/tempo:2.7.1 \
  --port=3200 \
  -- /tempo -config.file=/etc/tempo/tempo.yaml \
     -server.http-listen-port=3200

# 2. Expose service
kubectl expose pod tempo-manual -n observability \
  --name=tempo-manual \
  --port=3200 \
  --target-port=3200

# 3. Update Grafana datasource
# url: http://tempo-manual.observability.svc.cluster.local:3200
```

**CHỈ dùng khi desperate!** Không recommended cho production.

---

## 💡 Câu Hỏi Nhanh

**Q: Tại sao không dùng `kubectl port-forward` để fix?**  
A: Port-forward dễ break, không scale, không dùng được cho production.

**Q: ConfigMap edit có persist không nếu Helm upgrade?**  
A: Không. Helm sẽ overwrite. Nhưng là quick fix tốt để test ngay.

**Q: Làm sao biết đã fix thành công?**  
A: Chạy verification commands trong mỗi option. Key check:
```bash
kubectl exec tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
# → 3200 = success
```

**Q: Có mất dữ liệu traces không?**  
A: Không. Traces được buffer ở backend services và retry tự động.

---

Bạn thuộc case nào? Tôi sẽ guide cụ thể hơn!
