# Migration Guide: Multi-Repo → Mono-Repo

Hướng dẫn chi tiết để migration từ kiến trúc multi-repo (mỗi service 2 repos) sang mono-repo (2 repos chính).

## 📊 Kiến trúc cũ vs mới

### Kiến trúc cũ (Multi-Repo)

```
submission-service-repo/        (Source + CI/CD)
submission-config-repo/         (Helm values)
executor-service-repo/          (Source + CI/CD)
executor-service-config-repo/   (Helm values)
api-gateway-repo/               (Source + CI/CD)
api-gateway-config-repo/        (Helm values)
...
= 12+ repositories cho 6 services
```

### Kiến trúc mới (Mono-Repo)

```
web-grading-system-services/    (All source code + CI/CD)
web-grading-system-config/      (All Helm charts)
web-grading-system-deploy/      (ArgoCD orchestration)
= 3 repositories
```

## 🎯 Lợi ích

### Quản lý đơn giản hơn
- ✅ Giảm từ 12+ repos xuống 3 repos
- ✅ Một chỗ để quản lý CI/CD workflow
- ✅ Một chỗ để quản lý Helm configurations

### CI/CD thông minh hơn
- ✅ Tự động detect service thay đổi
- ✅ Chỉ build services cần thiết
- ✅ Parallel builds cho nhiều services
- ✅ Shared core library được tự động rebuild

### Version management tốt hơn
- ✅ Semantic versioning cho từng service
- ✅ Tags rõ ràng: `<service>-v<version>`
- ✅ Dễ track history và rollback

## 🚀 Migration Steps

### Step 1: Tạo Source Mono-Repo

```bash
# Tạo repo mới trên GitHub
# Repository name: web-grading-system-services

# Clone và setup
git clone https://github.com/PTIT-DTL-Project/web-grading-system-services.git
cd web-grading-system-services

# Copy cấu trúc từ deploy repo
cp -r ../web-grading-system-deploy/src-services/* .

# Commit initial structure
git add .
git commit -m "Initial mono-repo structure for all services"
git push origin main
```

### Step 2: Tạo Config Mono-Repo

```bash
# Tạo repo mới trên GitHub
# Repository name: web-grading-system-config

# Clone và setup
git clone https://github.com/Duong-Vu-practice-workspace/web-grading-system-config-test
cd web-grading-system-config

# Copy cấu trúc từ deploy repo
cp -r ../web-grading-system-deploy/config-services/* .

# Commit initial structure
git add .
git commit -m "Initial mono-repo structure for all Helm charts"
git push origin main
```

### Step 3: Configure GitHub Secrets

Cả 2 repos cần các secrets sau:

**web-grading-system-services:**
```
DOCKERHUB_USERNAME     - Docker Hub username
DOCKERHUB_TOKEN        - Docker Hub access token
CONFIG_REPO_TOKEN      - GitHub PAT with write access to config repo
```

**web-grading-system-config:**
```
(No secrets needed - read-only by ArgoCD)
```

Tạo GitHub Personal Access Token:
1. GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate new token
3. Select scopes: `repo` (full control)
4. Copy token và add vào secrets

### Step 4: Update ArgoCD Applications

```bash
cd web-grading-system-deploy/deploy/argocd-apps

# Generate ArgoCD manifests
./generate-argocd-apps.sh

# Apply to cluster
kubectl apply -f generated/

# Verify applications
kubectl get applications -n argocd
```

### Step 5: Verify Workflow

```bash
# Test build workflow
cd web-grading-system-services

# Make a change to a service
echo "// Test change" >> submission-service/README.md

# Commit and push
git add .
git commit -m "test: trigger CI/CD for submission-service"
git push origin main

# Monitor workflow
# GitHub → Actions → Build and Push Services
# Should only build submission-service
```

### Step 6: Clean Up Old Repos

⚠️ **Chỉ thực hiện sau khi verify mọi thứ hoạt động!**

```bash
# Archive old repositories (không xóa ngay)
# GitHub → Repository Settings → Danger Zone → Archive this repository

# Sau 1-2 tuần, nếu mọi thứ ổn định, có thể xóa
```

## 🔧 Configuration Details

### GitHub Actions Workflow

File: `src-services/.github/workflows/build-services.yml`

**Features:**
- Path-based change detection
- Matrix strategy for parallel builds
- Automatic versioning
- Docker image build & push
- Auto-update config repo

**Trigger:**
- Push to `main`, `develop`, or `feat/*` branches
- Pull requests to `main` or `develop`

### Helm Charts Structure

```
config-services/
├── <service-name>/
│   ├── Chart.yaml
│   ├── values-stg.yaml
│   ├── values-prod.yaml (optional)
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       └── service.yaml
```

### ArgoCD Application Template

File: `deploy/argocd-apps/argocd-app-template.yaml`

**Points to:**
- Repo: `web-grading-system-config`
- Path: `${SERVICE_NAME}` (dynamic)
- Values: `values-stg.yaml`

## 📝 Development Workflow

### Adding a New Service

1. **Add to source repo:**
```bash
cd web-grading-system-services
mkdir new-service
# Add source code, pom.xml, Dockerfile
```

2. **Update workflow paths:**
Edit `.github/workflows/build-services.yml`, add to `filters`:
```yaml
new-service:
  - 'new-service/**'
```

3. **Create Helm chart:**
```bash
cd web-grading-system-config
./generate-charts.sh  # Or create manually
```

4. **Add ArgoCD Application:**
```bash
cd web-grading-system-deploy/deploy/argocd-apps
echo "new-service" >> services.env
./generate-argocd-apps.sh
kubectl apply -f generated/new-service.yaml
```

### Making Changes to a Service

```bash
# 1. Create feature branch
git checkout -b feat/my-feature

# 2. Make changes
vim submission-service/src/...

# 3. Push and create PR
git push origin feat/my-feature
# Create PR on GitHub

# 4. CI/CD runs automatically
# - Detects changed service
# - Builds with feature tag
# - Pushes Docker image

# 5. Merge to main
# - Increments version
# - Creates GitHub release
# - Updates config repo
# - ArgoCD auto-syncs
```

## 🔍 Troubleshooting

### Workflow không detect service changes

**Kiểm tra:**
```bash
# Verify paths-filter configuration
cat .github/workflows/build-services.yml | grep -A 10 "filters:"
```

**Fix:** Đảm bảo path khớp với cấu trúc thư mục

### ArgoCD không sync

**Kiểm tra:**
```bash
# Check application status
kubectl get application grading-submission-service -n argocd -o yaml

# Check sync status
argocd app get grading-submission-service
```

**Fix:**
- Verify repoURL trong Application manifest
- Check ArgoCD có quyền access repo
- Verify Helm chart syntax: `helm lint submission-service/`

### Image tag không update

**Kiểm tra:**
```bash
# Verify CONFIG_REPO_TOKEN secret
gh secret list

# Check workflow logs
# GitHub → Actions → Latest run → Update config repo step
```

**Fix:**
- Ensure token has `repo` scope
- Verify config repo path: `${service}/values-stg.yaml`

## 📚 References

- [Source Mono-Repo README](../../src-services/README.md)
- [Config Mono-Repo README](../../config-services/README.md)
- [ArgoCD Apps README](../argocd-apps/README.md)
- [GitHub Actions Matrix Strategy](https://docs.github.com/en/actions/using-jobs/using-a-matrix-for-your-jobs)
- [Helm Charts Best Practices](https://helm.sh/docs/chart_best_practices/)

## 🎉 Success Criteria

Sau khi migration thành công:

- ✅ Tất cả services có thể build từ 1 repo
- ✅ CI/CD tự động detect và build đúng service
- ✅ Config repo được update tự động
- ✅ ArgoCD sync và deploy thành công
- ✅ Health checks pass cho tất cả services
- ✅ Có thể rollback về version cũ dễ dàng

## 🆘 Support

Nếu gặp vấn đề:
1. Check GitHub Actions logs
2. Check ArgoCD application status
3. Verify Kubernetes pods: `kubectl get pods -n web-grading`
4. Check pod logs: `kubectl logs <pod-name> -n web-grading`
