# GitHub Actions Troubleshooting Guide

## Vấn đề hiện tại
GitHub Actions không tự động build và tag Docker images với versioning như "v1", "v2", ...

## Kiến trúc và cách hoạt động

### Workflow Flow
```
Push code → Build & Test → Detect changes → Build Docker images → Tag & Release → Update config repo
```

### Repositories
1. **web-grading-system-services-test** (Source repo)
   - Chứa source code của các services
   - Có workflow tự động build và deploy
   - Location: `src-services/` trong repo chính

2. **web-grading-system-deploy-test** (Config repo)
   - Chứa Helm charts và configurations
   - Được update tự động bởi CI/CD
   - Location: `config-services/` trong repo chính

## Các bước kiểm tra

### 1. Kiểm tra GitHub Secrets ⚠️ QUAN TRỌNG

Truy cập: https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/settings/secrets/actions

Cần có 3 secrets:

#### a) DOCKERHUB_USERNAME
```
Giá trị: vucongtuanduong
```

#### b) DOCKERHUB_TOKEN
- Tạo token tại: https://hub.docker.com/settings/security
- Permissions: Read, Write, Delete
- Copy token và thêm vào GitHub Secrets

#### c) CONFIG_REPO_TOKEN
- Tạo GitHub Personal Access Token (classic)
- Truy cập: https://github.com/settings/tokens
- Permissions cần thiết:
  - ✅ `repo` (Full control of private repositories)
  - ✅ `workflow` (Update GitHub Action workflows)
- Copy token và thêm vào GitHub Secrets

**Lưu ý**: Token phải có quyền write vào repo `web-grading-system-deploy-test`

### 2. Kiểm tra workflow logs

Sau khi push code, kiểm tra logs tại:
https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/actions

Các lỗi thường gặp:

#### a) Build failed (11-21s)
```
Nguyên nhân: Maven build lỗi hoặc dependencies không đủ
Giải pháp: Kiểm tra pom.xml và dependencies
```

#### b) Docker push failed
```
Nguyên nhân: DOCKERHUB_TOKEN sai hoặc không có quyền
Giải pháp: Tạo lại token với đúng permissions
```

#### c) Config update failed
```
Nguyên nhân: CONFIG_REPO_TOKEN sai hoặc không có quyền write
Giải pháp: 
1. Kiểm tra token có quyền repo
2. Kiểm tra tên repo đúng: Duong-Vu-practice-workspace/web-grading-system-deploy-test
```

### 3. Kiểm tra versioning logic

Workflow sử dụng git tags để auto-increment version:

```bash
# Lần đầu tiên (không có tag)
→ v1.0.0

# Có tag: submission-service-v1.0.0
→ v1.0.1

# Có tag: submission-service-v1.0.5
→ v1.0.6
```

Tags được tạo theo format: `{service-name}-v{version}`

Ví dụ:
- `submission-service-v1.0.0`
- `executor-service-v1.0.1`
- `api-gateway-v1.0.2`

### 4. Kiểm tra Docker images trên Docker Hub

Truy cập: https://hub.docker.com/u/vucongtuanduong

Các images cần có:
- `web-grading-system-submission-service`
- `web-grading-system-executor-service`
- `web-grading-system-api-gateway`
- `web-grading-system-result-service`
- `web-grading-system-assignment-service`

Mỗi image cần có tags:
- `latest` (luôn update)
- `v1.0.0`, `v1.0.1`, ... (version tags)

## Test workflow

### Manual trigger (không cần push code)

1. Truy cập: https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/actions/workflows/publish.yml

2. Click "Run workflow"

3. Chọn:
   - Branch: `main`
   - Service: Chọn một service (hoặc để trống để build tất cả)
   - Version: Để trống để auto-increment

4. Click "Run workflow"

### Automatic trigger (push code)

```bash
cd src-services

# Thay đổi code trong một service
echo "// Test change" >> submission-service/README.md

# Commit và push
git add .
git commit -m "test: trigger workflow"
git push origin main

# Kiểm tra workflow chạy
# https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/actions
```

## Verify kết quả

### 1. GitHub Release
- Truy cập: https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/releases
- Phải có release mới với tag `{service}-v{version}`
- Release chứa JAR file của service

### 2. GitHub Tags
```bash
cd src-services
git fetch --tags
git tag -l
```

Phải thấy tags mới được tạo.

### 3. Docker Hub
- Images mới được push với đúng tag version
- Tag `latest` được update

### 4. Config Repo
```bash
cd config-services/{service-name}
cat values-stg.yaml | grep tag
```

Tag trong values file phải được update thành version mới.

## Common Issues

### Issue 1: Workflow chạy nhưng không có changes detected
**Nguyên nhân**: Push vào branch khác hoặc thay đổi file ngoài thư mục services

**Giải pháp**: 
- Đảm bảo push vào `main`, `develop`, hoặc `feat/**` branches
- Thay đổi phải trong thư mục service (không phải root)

### Issue 2: Version không tăng
**Nguyên nhân**: Git tags không được fetch đúng

**Giải pháp**:
```bash
cd src-services
git fetch --tags
git tag -l  # kiểm tra tags
```

### Issue 3: Config repo không update
**Nguyên nhân**: 
- CONFIG_REPO_TOKEN không đúng
- Không có quyền write
- Sai tên repo

**Giải pháp**:
1. Tạo lại token với đầy đủ quyền
2. Kiểm tra tên repo trong workflow: `Duong-Vu-practice-workspace/web-grading-system-deploy-test`

### Issue 4: Docker push failed
**Nguyên nhân**:
- DOCKERHUB_TOKEN hết hạn
- Không có quyền write
- Docker Hub repository không tồn tại

**Giải pháp**:
1. Tạo lại token trên Docker Hub
2. Tạo repositories trên Docker Hub (nếu chưa có)

## Next Steps

Sau khi đã setup đúng:

1. ✅ Mỗi lần push code vào main → auto build và tag version mới
2. ✅ Docker images được push với version mới
3. ✅ Config repo được update tự động
4. ✅ ArgoCD sẽ detect changes và deploy

## Support

Nếu vẫn gặp vấn đề:
1. Chạy script: `./check-github-actions.sh`
2. Kiểm tra logs chi tiết trên GitHub Actions
3. Xem errors trong step nào bị failed
