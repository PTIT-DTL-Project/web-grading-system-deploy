# ArgoCD Applications

Thư mục này chứa template và script để generate ArgoCD Application manifests cho tất cả microservices.

## 📁 Files

- `argocd-app-template.yaml` - Template cho ArgoCD Application
- `services.env` - Danh sách services cần tạo Application
- `generate-argocd-apps.sh` - Script generate manifests
- `generated/` - Thư mục chứa manifests đã generate (gitignored)

## 🚀 Usage

### Generate ArgoCD Applications

```bash
./generate-argocd-apps.sh
```

Script sẽ tạo các file manifest trong thư mục `generated/`:
- `submission-service.yaml`
- `executor-service.yaml`
- `api-gateway.yaml`
- `result-service.yaml`
- `assignment-service.yaml`

### Apply to Cluster

```bash
# Apply all applications
kubectl apply -f generated/

# Apply specific application
kubectl apply -f generated/submission-service.yaml
```

### Verify Applications

```bash
# List all applications
kubectl get applications -n argocd

# Check specific application status
kubectl get application grading-submission-service -n argocd

# View application details
argocd app get grading-submission-service
```

## 🔧 Configuration

### Add New Service

1. Thêm service name vào `services.env`:
```bash
echo "new-service" >> services.env
```

2. Đảm bảo Helm chart tương ứng đã tồn tại trong config repo:
```
config-services/
└── new-service/
    ├── Chart.yaml
    ├── values-stg.yaml
    └── templates/
```

3. Re-generate applications:
```bash
./generate-argocd-apps.sh
```

4. Apply to cluster:
```bash
kubectl apply -f generated/new-service.yaml
```

### Customize Template

Edit `argocd-app-template.yaml` để thay đổi:
- Repository URL
- Target revision (branch)
- Sync policy
- Destination namespace

Sau đó re-generate applications.

## 📝 Template Variables

Template sử dụng các biến sau:

- `${SERVICE_NAME}` - Tên service (từ services.env)

Ví dụ:
- Application name: `grading-${SERVICE_NAME}` → `grading-submission-service`
- Chart path: `${SERVICE_NAME}` → `submission-service`

## 🔄 GitOps Flow

```
1. Code changes → Source Repo (web-grading-system-services)
2. CI/CD build → Docker Image
3. CI/CD update → Config Repo (web-grading-system-config)
4. ArgoCD detect → Config changes
5. ArgoCD sync → Deploy to K8s
```

## 🎯 ArgoCD Application Structure

Mỗi Application có:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: grading-<service-name>
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/Duong-Vu-practice-workspace/web-grading-system-config-test
    path: <service-name>  # Path to Helm chart in mono-repo
    helm:
      valueFiles:
        - values-stg.yaml
  destination:
    namespace: web-grading
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## 🔗 Related

- Config Repo: https://github.com/PTIT-DTL-Project/web-grading-system-config
- Source Repo: https://github.com/PTIT-DTL-Project/web-grading-system-services
