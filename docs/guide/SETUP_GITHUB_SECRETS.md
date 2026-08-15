# 🔐 Hướng dẫn Setup GitHub Secrets

## ⚠️ QUAN TRỌNG - BẮT BUỘC PHẢI LÀM

Workflow sẽ **KHÔNG HOẠT ĐỘNG** nếu thiếu các secrets này!

---

## 📍 Bước 1: Truy cập GitHub Secrets

Mở link này trong trình duyệt:

```
https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/settings/secrets/actions
```

Hoặc đi theo path:
1. Vào repository: `web-grading-system-services-test`
2. Click **Settings** (tab trên cùng)
3. Sidebar trái → **Secrets and variables** → **Actions**

---

## 🔑 Bước 2: Thêm 3 Secrets

### Secret #1: DOCKERHUB_USERNAME

```
Name: DOCKERHUB_USERNAME
Value: vucongtuanduong
```

Click **New repository secret** → Paste tên và value → **Add secret**

---

### Secret #2: DOCKERHUB_TOKEN

#### Tạo Docker Hub Token:

1. **Đăng nhập Docker Hub**: https://hub.docker.com/

2. **Vào Settings**:
   - Click avatar góc phải trên
   - Chọn **Account Settings**

3. **Tạo Access Token**:
   - Tab **Security** (https://hub.docker.com/settings/security)
   - Click **New Access Token**
   - Description: `GitHub Actions - web-grading-system`
   - Access permissions: **Read, Write, Delete**
   - Click **Generate**

4. **Copy token** (chỉ hiện 1 lần!)

5. **Thêm vào GitHub**:
   ```
   Name: DOCKERHUB_TOKEN
   Value: [paste token vừa copy]
   ```

---

### Secret #3: CONFIG_REPO_TOKEN ⚠️ QUAN TRỌNG NHẤT

#### Tạo GitHub Personal Access Token:

1. **Vào GitHub Settings**:
   ```
   https://github.com/settings/tokens
   ```
   Hoặc: Avatar → Settings → Developer settings → Personal access tokens → Tokens (classic)

2. **Generate new token (classic)**:
   - Click **Generate new token (classic)**
   - Nhập password GitHub nếu yêu cầu

3. **Cấu hình token**:
   ```
   Note: GitHub Actions - Config Repo Access
   Expiration: No expiration (hoặc 1 year)
   ```

4. **Chọn permissions** (QUAN TRỌNG!):
   - ✅ **repo** - Full control of private repositories
     - ✅ repo:status
     - ✅ repo_deployment
     - ✅ public_repo
     - ✅ repo:invite
     - ✅ security_events
   
   - ✅ **workflow** - Update GitHub Action workflows

5. **Generate token** → **Copy token** (chỉ hiện 1 lần!)

6. **Thêm vào GitHub Secrets**:
   ```
   Name: CONFIG_REPO_TOKEN
   Value: [paste token vừa copy]
   ```

---

## ✅ Bước 3: Verify Secrets

Sau khi thêm xong, bạn sẽ thấy 3 secrets:

```
✓ DOCKERHUB_USERNAME
✓ DOCKERHUB_TOKEN
✓ CONFIG_REPO_TOKEN
```

**Lưu ý**: Bạn không thể xem lại value của secrets, chỉ có thể update hoặc xóa.

---

## 🧪 Bước 4: Test Workflow

### Cách 1: Automatic (push code)

Code đã được sửa sẵn, chỉ cần push:

```bash
cd src-services
git add .
git commit -m "test: trigger workflow with secrets configured"
git push origin main
```

### Cách 2: Manual Trigger

1. Vào: https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/actions

2. Click workflow **"Publish Docker Image (Manual)"**

3. Click **Run workflow**:
   - Branch: `main`
   - Service: `submission-service`
   - Version: (để trống)

4. Click **Run workflow**

---

## 📊 Bước 5: Kiểm tra kết quả

### 1. GitHub Actions Logs

Mở: https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/actions

Workflow phải:
- ✅ Chạy thành công (màu xanh)
- ✅ Tất cả steps passed
- ✅ Build → Tag → Release → Docker Push → Update Config

### 2. GitHub Releases

Mở: https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/releases

Phải có:
- ✅ Release mới: `submission-service-v1.0.0`
- ✅ Có JAR file đi kèm

### 3. GitHub Tags

```bash
cd src-services
git fetch --tags
git tag -l
```

Phải thấy: `submission-service-v1.0.0`

### 4. Docker Hub

Mở: https://hub.docker.com/r/vucongtuanduong/web-grading-system-submission-service

Phải có tags:
- ✅ `v1.0.0`
- ✅ `latest`

### 5. Config Repo

Mở: https://github.com/Duong-Vu-practice-workspace/web-grading-system-config-test

Phải có:
- ✅ Commit mới: `chore(submission-service): update image tag to v1.0.0`
- ✅ File `submission-service/values-stg.yaml` có `tag: "v1.0.0"`

---

## ❌ Troubleshooting

### Lỗi: "DOCKERHUB_TOKEN not set"

```
→ Secret chưa được thêm hoặc sai tên
→ Kiểm tra lại tên phải là: DOCKERHUB_TOKEN (viết hoa, không dấu cách)
```

### Lỗi: "Failed to clone config repo"

```
→ CONFIG_REPO_TOKEN không có quyền
→ Tạo lại token với đầy đủ permissions (repo + workflow)
```

### Lỗi: "Maven build failed"

```
→ Không liên quan đến secrets
→ Kiểm tra pom.xml và dependencies
```

### Workflow không chạy khi push

```
→ Push vào đúng branch: main, develop, hoặc feat/**
→ Thay đổi phải trong thư mục service (không phải root)
```

---

## 📝 Checklist

Trước khi test, đảm bảo:

- [ ] Đã thêm DOCKERHUB_USERNAME
- [ ] Đã thêm DOCKERHUB_TOKEN (từ Docker Hub)
- [ ] Đã thêm CONFIG_REPO_TOKEN (từ GitHub, có quyền repo + workflow)
- [ ] Đã push code (hoặc manual trigger)
- [ ] Đã kiểm tra logs trên GitHub Actions

---

## 🎯 Kết luận

Sau khi setup xong 3 secrets, workflow sẽ tự động:

1. Detect changed services
2. Build JAR file
3. Tạo git tag với version
4. Tạo GitHub Release
5. Build và push Docker image
6. Update config repo

**Lần đầu tiên sẽ tạo version v1.0.0, các lần sau tự động tăng v1.0.1, v1.0.2, ...**
