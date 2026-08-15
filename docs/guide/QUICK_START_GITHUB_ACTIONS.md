# ⚡ QUICK START - Kiểm tra GitHub Actions ngay

## ✅ Đã hoàn thành

1. ✅ Fixed workflow files (CONFIG_REPO path)
2. ✅ Updated submission-service code
3. ✅ Pushed to GitHub
4. ✅ Created comprehensive documentation

## 🔴 BẠN CẦN LÀM NGAY (5 phút)

### Bước 1: Setup GitHub Secrets ⚠️ BẮT BUỘC

**Mở file này và làm theo**: `SETUP_GITHUB_SECRETS.md`

Hoặc đọc tóm tắt dưới đây:

#### 1.1. Truy cập GitHub Secrets

```
https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/settings/secrets/actions
```

#### 1.2. Thêm 3 secrets:

**Secret 1:**
```
Name: DOCKERHUB_USERNAME
Value: vucongtuanduong
```

**Secret 2:**
```
Name: DOCKERHUB_TOKEN
Value: [Lấy từ https://hub.docker.com/settings/security]
       - Click "New Access Token"
       - Permissions: Read, Write, Delete
       - Copy token
```

**Secret 3:**
```
Name: CONFIG_REPO_TOKEN
Value: [Lấy từ https://github.com/settings/tokens]
       - Click "Generate new token (classic)"
       - Chọn: repo + workflow
       - Copy token
```

---

## 🧪 Bước 2: Kiểm tra Workflow

### Cách 1: Xem workflow vừa trigger (Recommended)

Code đã được push, workflow đang chạy!

**Mở ngay**: https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/actions

Bạn sẽ thấy:
- **Nếu chưa có secrets**: ❌ Failed (trong vài giây)
- **Sau khi thêm secrets**: Cần push lại hoặc manual trigger

### Cách 2: Manual trigger (sau khi setup secrets)

1. Mở: https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/actions/workflows/publish.yml

2. Click **"Run workflow"** button

3. Chọn:
   - Branch: `main`
   - Service: `submission-service`
   - Version: (để trống)

4. Click **"Run workflow"**

5. Xem progress tại tab Actions

---

## 📊 Bước 3: Verify Kết quả

Sau khi workflow chạy thành công (✅ màu xanh), kiểm tra:

### 3.1. GitHub Release
```
https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/releases
```
→ Phải có: `submission-service-v1.0.0`

### 3.2. Docker Hub
```
https://hub.docker.com/r/vucongtuanduong/web-grading-system-submission-service/tags
```
→ Phải có tags: `v1.0.0` và `latest`

### 3.3. Config Repo
```
https://github.com/Duong-Vu-practice-workspace/web-grading-system-config-test/commits/main
```
→ Phải có commit: `chore(submission-service): update image tag to v1.0.0`

### 3.4. Git Tags
```bash
cd src-services
git fetch --tags
git tag -l
```
→ Phải thấy: `submission-service-v1.0.0`

---

## ❌ Nếu workflow failed

### Trường hợp 1: Failed trong 5-20 giây
```
Nguyên nhân: Secrets chưa được setup
Giải pháp: Làm Bước 1 (Setup Secrets)
```

### Trường hợp 2: Failed ở step "Docker push"
```
Nguyên nhân: DOCKERHUB_TOKEN không đúng
Giải pháp: Tạo lại token trên Docker Hub
```

### Trường hợp 3: Failed ở step "Update config repo"
```
Nguyên nhân: CONFIG_REPO_TOKEN không có quyền
Giải pháp: Tạo lại token với permissions: repo + workflow
```

### Trường hợp 4: Failed ở step "Maven build"
```
Nguyên nhân: Code có lỗi compile
Giải pháp: Kiểm tra logs chi tiết, fix code
```

---

## 🎯 Kết quả mong đợi

Workflow thành công sẽ:
1. ✅ Detect thay đổi trong submission-service
2. ✅ Build JAR file với Maven
3. ✅ Tạo tag: `submission-service-v1.0.0`
4. ✅ Tạo GitHub Release với JAR file
5. ✅ Build và push Docker image với tag `v1.0.0` và `latest`
6. ✅ Update config repo với version mới

**Lần sau push code, version sẽ tự động tăng lên v1.0.1, v1.0.2, ...**

---

## 📚 Tài liệu đầy đủ

- `SETUP_GITHUB_SECRETS.md` - Hướng dẫn chi tiết setup secrets
- `GITHUB_ACTIONS_TROUBLESHOOTING.md` - Troubleshooting guide
- `check-github-actions.sh` - Script kiểm tra health

---

## 🆘 Cần help?

Chạy health check:
```bash
./check-github-actions.sh
```

Xem logs chi tiết:
```
https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/actions
→ Click vào workflow run → Click vào failed step → Xem error message
```
