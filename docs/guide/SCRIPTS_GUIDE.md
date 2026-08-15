# Scripts Guide

Hướng dẫn sử dụng các scripts quản lý Web Grading System.

## 📋 Overview

Hệ thống cung cấp các scripts để quản lý lifecycle của toàn bộ cluster:

| Script | Mục đích | Khi nào dùng |
|--------|----------|--------------|
| `setup.sh` | Setup toàn bộ hệ thống lần đầu | Lần đầu tiên hoặc sau khi clean |
| `start.sh` | Khởi động hệ thống | Sau khi reboot máy |
| `stop.sh` | Dừng hệ thống | Khi cần tắt máy hoặc maintenance |
| `clean.sh` | Xóa toàn bộ hệ thống | Reset về trạng thái ban đầu |
| `status.sh` | Kiểm tra trạng thái hệ thống | Bất cứ lúc nào |

## 🚀 setup.sh - Initial Setup

### Mục đích
Setup toàn bộ hệ thống từ đầu, bao gồm:
- ✅ Start k3s cluster
- ✅ Create namespaces và secrets
- ✅ Deploy RustFS (object storage)
- ✅ Configure ingress
- ✅ Install và configure ArgoCD
- ✅ Deploy tất cả microservices qua ArgoCD
- ✅ Install observability stack (Grafana, Prometheus, etc.)
- ✅ Setup Cloudflare Tunnel

### Khi nào dùng
- Lần đầu tiên setup hệ thống
- Sau khi chạy `clean.sh`
- Khi muốn rebuild toàn bộ từ đầu

### Cách dùng
```bash
# Basic usage
bash setup.sh

# With custom gateway port
bash setup.sh 31243

# Or using environment variable
GATEWAY_PORT=31243 bash setup.sh
```

### Output
Script sẽ hiển thị:
- Progress của từng bước
- URLs của các services
- ArgoCD admin password
- Useful commands

### Thời gian
- First run: ~5-10 phút (tùy network speed)
- Subsequent runs: ~3-5 phút

### Prerequisites
- ✅ k3s installed
- ✅ kubectl installed
- ✅ Docker installed (cho Cloudflare Tunnel)
- ✅ .env file configured (optional)

## ▶️ start.sh - Start System

### Mục đích
Khởi động lại hệ thống sau khi stop hoặc reboot máy.

### Khi nào dùng
- Sau khi reboot máy
- Sau khi chạy `stop.sh`
- Mỗi khi bật máy lên (nếu không enable auto-start)

### Cách dùng
```bash
bash start.sh
```

### Output
Script sẽ:
- Start k3s
- Start Cloudflare Tunnel
- Show cluster status
- Display service URLs

### Thời gian
- ~1-2 phút

### Notes
- Pods có thể mất thêm vài phút để fully ready
- ArgoCD sẽ tự động sync nếu có thay đổi
- Check status với `bash status.sh`

## ⏹️ stop.sh - Stop System

### Mục đích
Dừng hệ thống một cách graceful.

### Khi nào dùng
- Trước khi tắt máy
- Khi cần maintenance
- Khi muốn tiết kiệm tài nguyên

### Cách dùng
```bash
bash stop.sh
```

### Output
- Stops Cloudflare Tunnel
- Stops k3s

### Thời gian
- ~30 giây

### Notes
- Data vẫn được giữ trong PVCs
- Có thể start lại bất cứ lúc nào với `start.sh`
- Không xóa bất kỳ data nào

## 🗑️ clean.sh - Clean System

### Mục đích
Xóa toàn bộ hệ thống, trở về trạng thái ban đầu.

### ⚠️ WARNING
- Xóa tất cả namespaces (argocd, web-grading, observability)
- Xóa tất cả container images
- **PVCs cần xóa manual để đảm bảo an toàn data**

### Khi nào dùng
- Reset hệ thống về trạng thái ban đầu
- Trước khi re-setup với config mới
- Khi gặp vấn đề không fix được

### Cách dùng
```bash
bash clean.sh
# Nhập 'yes' để confirm
```

### Interactive Confirmation
Script sẽ yêu cầu confirmation trước khi xóa:
```
Are you sure? (yes/no):
```

### Thời gian
- ~2-3 phút

### After Clean
Để setup lại:
```bash
bash setup.sh
```

### Manual Cleanup (if needed)
```bash
# List PVCs
kubectl get pvc -A

# Delete specific PVC
kubectl delete pvc <name> -n <namespace>

# List PVs
kubectl get pv

# Delete specific PV
kubectl delete pv <name>
```

## 📊 status.sh - Check Status

### Mục đích
Kiểm tra trạng thái của toàn bộ hệ thống.

### Khi nào dùng
- Sau khi start để verify
- Khi troubleshoot
- Để xem overview nhanh

### Cách dùng
```bash
bash status.sh
```

### Output
Script hiển thị:
- ✅ k3s status
- ✅ Namespaces
- ✅ ArgoCD Applications
- ✅ Services và Pods
- ✅ Observability status
- ✅ Cloudflare Tunnel status
- ✅ Service URLs
- ✅ Useful commands

### Example Output
```
============================================================
  Web Grading System - Status
============================================================

🔧 k3s Status:
  ✓ Running
  NAME       STATUS   ROLES                  AGE   VERSION
  localhost  Ready    control-plane,master   5d    v1.28.4+k3s1

📦 Namespaces:
  NAME            STATUS   AGE
  web-grading     Active   5d
  argocd          Active   5d
  observability   Active   5d

🚀 ArgoCD Applications:
  NAME                          SYNC STATUS   HEALTH STATUS
  grading-submission-service    Synced        Healthy
  grading-api-gateway           Synced        Healthy
  ...
```

## 🔄 Common Workflows

### Daily Startup (After Reboot)
```bash
# Start system
bash start.sh

# Check status
bash status.sh

# Watch pods come up
kubectl get pods -n web-grading -w
```

### First Time Setup
```bash
# Run full setup
bash setup.sh

# Verify everything is running
bash status.sh

# Check ArgoCD password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### Maintenance/Troubleshooting
```bash
# Check status
bash status.sh

# Stop system
bash stop.sh

# Clean everything
bash clean.sh

# Setup fresh
bash setup.sh
```

### Before Shutdown
```bash
# Stop gracefully
bash stop.sh

# Or if you want to clean
bash clean.sh
```

## 🐛 Troubleshooting

### Script fails during setup
```bash
# Check what failed
bash status.sh

# Try manual steps
cd deploy
bash setup-namespace.sh
bash install-rustfs.sh
bash install-argocd.sh
```

### Services not starting
```bash
# Check pods
kubectl get pods -n web-grading

# Check specific pod
kubectl describe pod <pod-name> -n web-grading

# Check logs
kubectl logs <pod-name> -n web-grading

# Restart deployment
kubectl rollout restart deployment/<service> -n web-grading
```

### ArgoCD not syncing
```bash
# Check applications
kubectl get applications -n argocd

# Manual sync
argocd app sync <app-name>

# Or via kubectl
kubectl patch application <app-name> -n argocd \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### Clean doesn't work
```bash
# Force delete namespaces
kubectl delete namespace web-grading --force --grace-period=0
kubectl delete namespace argocd --force --grace-period=0
kubectl delete namespace observability --force --grace-period=0

# Clean images manually
sudo k3s crictl images
sudo k3s crictl rmi <image-id>
```

## 📝 Environment Variables

Scripts sử dụng `.env` file nếu có:

```bash
# .env example
GATEWAY_PORT=31242
DOMAIN=vucongtuanduong.dpdns.org
PREFIX=web-dev1
```

## 🔧 Advanced Usage

### Custom Configuration

Edit scripts để customize:
- Ports
- Domains
- Resource limits
- Namespace names

### Integration with Systemd

Tạo systemd service để auto-start:

```bash
# Create service file
sudo tee /etc/systemd/system/web-grading.service <<EOF
[Unit]
Description=Web Grading System
After=network.target k3s.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/path/to/web-grading-system-deploy
ExecStart=/bin/bash start.sh
ExecStop=/bin/bash stop.sh
User=root

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable web-grading.service
sudo systemctl start web-grading.service
```

## 📚 Related Documentation

- [README.md](./README.md) - Main documentation
- [MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md) - Migration guide
- [QUICK_REFERENCE.md](./QUICK_REFERENCE.md) - Command reference
- [DEPLOYMENT_CHECKLIST.md](./DEPLOYMENT_CHECKLIST.md) - Deployment checklist
