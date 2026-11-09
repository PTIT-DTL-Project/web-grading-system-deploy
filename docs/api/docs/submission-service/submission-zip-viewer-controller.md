# Tài liệu chi tiết luồng API — submission-service / SubmissionController (Zip Viewer)

Nơi lưu: `docs/api/docs/submission-service/submission-zip-viewer-controller.md`

Mục đích: giải thích chi tiết endpoint xem nội dung file zip nộp bài (tree + editor read-only) của submission-service, bao gồm input, output, luồng xử lý, ví dụ, và mã lỗi. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`SubmissionController` cung cấp hai endpoint để xem nội dung file zip mà sinh viên nộp:

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/submissions/{submissionId}/tree` | GET | Trả về cây thư mục (folder/file) của zip nộp bài | Sinh viên chủ sở hữu HOẶC giảng viên sở hữu lớp của assignment |
| `/api/v1/submissions/{submissionId}/file` | GET | Trả về nội dung văn bản của một entry trong zip (dùng cho editor read-only) | Sinh viên chủ sở hữu HOẶC giảng viên sở hữu lớp của assignment |

**Quyền:**
- Sinh viên: `submission.studentId == callerId` → được xem.
- Giảng viên: `callerId == ownerId` của assignment (quyền sở hữu lớp) → được xem. submission-service gọi course-service internal API `GET /api/v1/internal/assignments/{assignmentId}/owner` để lấy `ownerId` và so sánh với `callerId`.
- Không phải chủ sở hữu và không phải giảng viên sở hữu lớp → `404` (không phân biệt không tồn tại vs không sở hữu, theo quy ước dự án).

**Bảo mật:**
- Không giải nén zip ra đĩa server; dùng `java.util.zip.ZipInputStream` đọc trực tiếp từ bytes tải từ RustFS.
- Chống **zip slip**: chặn entry path chứa `../` hoặc bắt đầu bằng `/`.
- Chống **zip bomb**: giới hạn tổng số entry (mặc định 5.000).
- Giới hạn kích thước file văn bản hiển thị (mặc định 2 MB); file lớn hơn bị cắt (`truncated = true`).
- Phân loại text/nhị phân theo extension hoặc tên file đặc biệt (Dockerfile, mvnw, gradlew, Makefile, các dotfile như `.gitignore`); file nhị phân trả về `isBinary = true`, `content = null`.
- Nội dung văn bản không chỉ giới hạn ở `text/*`: `application/xml`, `application/json` và các MIME có hậu tố `+xml`/`+json` cũng được xem trước (ví dụ `pom.xml`).

Controller giao tiếp với `SubmissionService` để thực hiện logic nghiệp vụ. `SubmissionService` gọi `CourseServiceClient` (Feign) để lấy `ownerId` của assignment từ course-service khi cần kiểm tra lecturer access.

---

## 2. DTO liên quan

### 2.1 `SubmissionZipTreeResponse` (dto/response)
Cây thư mục của zip nộp bài.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `submissionId` | UUID | ID submission |
| `root` | `ZipTreeNode` | Nút gốc của cây |

### 2.2 `ZipTreeNode` (dto/response)
Một nút trong cây thư mục: folder (có children) hoặc file (có size/mime).

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `name` | String | Tên folder/file |
| `type` | String | `folder` hoặc `file` |
| `path` | String | Đường dẫn tương đối trong zip (rỗng cho root) |
| `size` | Long | Kích thước bytes (chỉ file) |
| `mime` | String | Loại nội dung (chỉ file) |
| `children` | `List<ZipTreeNode>` | Các nút con (chỉ folder) |

### 2.3 `SubmissionZipFileResponse` (dto/response)
Nội dung một entry file trong zip, dùng cho editor read-only.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `submissionId` | UUID | ID submission |
| `path` | String | Đường dẫn entry trong zip |
| `size` | Long | Kích thước bytes |
| `mime` | String | Loại nội dung (ví dụ `text/x-java`, `text/markdown`) |
| `isBinary` | Boolean | `true` nếu nhị phân, `false` nếu văn bản |
| `content` | String | Nội dung văn bản (`null` nếu nhị phân) |
| `truncated` | Boolean | `true` nếu nội dung bị cắt do quá lớn |
| `message` | String | Thông báo bổ sung (ví dụ "File nhị phân, không thể xem trước") |

---

## 3. Chi tiết từng hàm

### 3.1 `getTree` — Lấy cây thư mục của zip

**Vị trí:** `SubmissionController.getTree(...)` → `SubmissionService.getSubmissionTree(...)`

**Endpoint:** `GET /api/v1/submissions/{submissionId}/tree`

**Path variable:**
- `submissionId` (UUID): ID submission

**Header đầu vào:**
- `X-User-Id` (String, bắt buộc): ID người gọi (JWT sub). Không phải UUID chính xác → `400`.

**Luồng xử lý:**
1. Controller nhận `submissionId` và `X-User-Id`. Kiểm tra UUID canonical.
2. Gọi `submissionService.getSubmissionTree(submissionId, callerId)`.
3. Service:
   - Truy vấn `submissionRepository.findById(submissionId)`. Không tìm thấy → `ResourceNotFoundException`.
   - Kiểm tra quyền sở hữu:
     - Nếu `submission.getStudentId().equals(callerId)` → cho phép (sinh viên xem của mình).
     - Ngược lại → gọi `courseServiceClient.getAssignmentOwner(submission.getAssignmentId())` để lấy `ownerId` của assignment. Nếu `ownerId.equals(callerId)` → cho phép (giảng viên sở hữu lớp). Nếu không → `ResourceNotFoundException` (404).
   - Lấy `rustfsPath` từ submission, tải bytes zip từ RustFS qua `rustfsService.downloadObject(...)`.
   - Dùng `ZipInputStream` duyệt các entry:
     - Bỏ qua `__MACOSX/`, `.DS_Store`.
     - Chặn path chứa `../` hoặc bắt đầu bằng `/` → `BadRequestException`.
     - Giới hạn 5.000 entry → vượt quá → `BadRequestException`.
   - Xây dựng cây thư mục (folder có `children`, file có `size`/`mime`).
   - Trả về `SubmissionZipTreeResponse`.

**Ví dụ request:**
```http
GET /api/v1/submissions/c49eb1e3-1234-5678-90ab-cdef12345678/tree
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):**
```json
{
  "submissionId": "c49eb1e3-1234-5678-90ab-cdef12345678",
  "root": {
    "name": "root",
    "type": "folder",
    "path": "",
    "children": [
      {
        "name": "src",
        "type": "folder",
        "path": "src",
        "children": [
          {
            "name": "Main.java",
            "type": "file",
            "path": "src/Main.java",
            "size": 1234,
            "mime": "text/x-java",
            "children": null
          }
        ]
      },
      {
        "name": "README.md",
        "type": "file",
        "path": "README.md",
        "size": 890,
        "mime": "text/markdown",
        "children": null
      }
    ]
  }
}
```

**Mã lỗi:**
- `400`: `X-User-Id` không phải UUID chính xác; zip chứa đường dẫn không an toàn; quá nhiều entry.
- `404`: submission không tồn tại hoặc người gọi không phải chủ sở hữu và không phải giảng viên sở hữu lớp.
- `502`: RustFS không khả dụng hoặc course-service không khả dụng (khi kiểm tra lecturer).

---

### 3.2 `getFile` — Lấy nội dung một entry trong zip

**Vị trí:** `SubmissionController.getFile(...)` → `SubmissionService.getZipFileContent(...)`

**Endpoint:** `GET /api/v1/submissions/{submissionId}/file`

**Path variable:**
- `submissionId` (UUID)

**Query params:**
| Param | Kiểu | Bắt buộc | Mô tả |
|-------|------|----------|-------|
| `path` | String | ✅ | Đường dẫn entry trong zip (ví dụ `src/Main.java`) |

**Header đầu vào:**
- `X-User-Id` (String, bắt buộc): ID người gọi (JWT sub).

**Luồng xử lý:**
1. Controller nhận `submissionId`, `path`, `X-User-Id`. Kiểm tra UUID canonical.
2. Gọi `submissionService.getZipFileContent(submissionId, path, callerId)`.
3. Service:
   - Kiểm tra quyền sở hữu như endpoint `tree`.
   - Sanitize `path`: chặn `../`, đường dẫn tuyệt đối → `BadRequestException`.
   - Tải bytes zip từ RustFS, dùng `ZipInputStream` tìm entry theo `path`.
   - Không tìm thấy entry → `ResourceNotFoundException` (404).
   - Phát hiện MIME theo extension hoặc tên file đặc biệt (`Dockerfile`, `mvnw`, `gradlew`, `Makefile`, dotfile); phân loại text/nhị phân.
   - Văn bản gồm `text/*`, `application/xml`, `application/json` và MIME có hậu tố `+xml`/`+json`; còn lại là nhị phân.
   - Nếu nhị phân → trả về `isBinary = true`, `content = null`, thông báo không xem được.
   - Nếu văn bản → đọc bytes (tối đa 2 MB), chuyển sang chuỗi UTF-8, gán `truncated` nếu quá lớn.
   - Trả về `SubmissionZipFileResponse`.

**Ví dụ request:**
```http
GET /api/v1/submissions/c49eb1e3-1234-5678-90ab-cdef12345678/file?path=src/Main.java
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200, văn bản):**
```json
{
  "submissionId": "c49eb1e3-1234-5678-90ab-cdef12345678",
  "path": "src/Main.java",
  "size": 1234,
  "mime": "text/x-java",
  "isBinary": false,
  "content": "public class Main { ... }",
  "truncated": false,
  "message": null
}
```

**Ví dụ response (200, nhị phân):**
```json
{
  "submissionId": "c49eb1e3-1234-5678-90ab-cdef12345678",
  "path": "data.bin",
  "size": 1048576,
  "mime": "application/octet-stream",
  "isBinary": true,
  "content": null,
  "truncated": false,
  "message": "File nhị phân, không thể xem trước trong editor"
}
```

**Mã lỗi:**
- `400`: `X-User-Id` không phải UUID chính xác; `path` không hợp lệ (chống zip slip).
- `404`: submission không tồn tại, entry không tìm thấy, hoặc người gọi không có quyền.
- `502`: RustFS không khả dụng hoặc course-service không khả dụng (khi kiểm tra lecturer).

---

## 4. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 400 | `X-User-Id` không phải UUID chính xác | `SubmissionController` |
| 400 | `path` chứa `../` hoặc tuyệt đối (chống zip slip) | `SubmissionService.sanitizeZipPath` |
| 400 | Zip chứa quá nhiều entry (> 5.000) | `SubmissionService.buildTree` |
| 404 | Submission không tồn tại | `SubmissionService.requireOwnedSubmission` |
| 404 | Người gọi không phải chủ sở hữu và không phải giảng viên sở hữu lớp | `SubmissionService.requireOwnedSubmission` |
| 404 | Entry không tìm thấy trong zip | `SubmissionService.getZipFileContent` |
| 502 | RustFS không khả dụng | `RustFSService.downloadObject` |
| 502 | Course-service không khả dụng (khi kiểm tra lecturer) | `CourseServiceClient.getAssignmentOwner` |

---

## 5. Luồng dữ liệu end-to-end

### 5.1 Sinh viên xem bài của mình

```
Sinh viên (FE)
   │ Nhấn "Xem nội dung file nộp" trên submission của mình
   ▼
FE: GET /api/v1/submissions/{submissionId}/tree
   │    X-User-Id: <sinh viên-id>
   ▼
submission-service: SubmissionController.getTree()
   │ 1. Kiểm tra X-User-Id là UUID canonical
   │ 2. Gọi SubmissionService.getSubmissionTree(submissionId, callerId)
   ▼
SubmissionService.getSubmissionTree()
   │ 3. Tìm submission theo id (404 nếu không tìm thấy)
   │ 4. Kiểm tra submission.studentId == callerId (404 nếu không khớp)
   │ 5. Lấy rustfsPath, tải bytes zip từ RustFS
   │ 6. Dùng ZipInputStream duyệt entries → build JSON tree
   │ 7. Trả về SubmissionZipTreeResponse
   ▼
FE: Hiển thị antd Tree / DirectoryTree
   │
   │ Sinh viên nhấn file src/Main.java
   ▼
FE: GET /api/v1/submissions/{submissionId}/file?path=src/Main.java
   ▼
submission-service: SubmissionController.getFile()
   │ 8. Kiểm tra X-User-Id, sanitize path (chống zip slip)
   │ 9. Gọi SubmissionService.getZipFileContent(submissionId, path, callerId)
   ▼
SubmissionService.getZipFileContent()
   │ 10. Kiểm tra quyền sở hữu (sinh viên chủ sở hữu)
   │ 11. Tải bytes zip từ RustFS, dùng ZipInputStream tìm entry
   │ 12. Phát hiện MIME, phân loại text/nhị phân
   │ 13. Đọc nội dung văn bản (tối đa 2 MB), gán truncated nếu quá lớn
   │ 14. Trả về SubmissionZipFileResponse
   ▼
FE: Nếu văn bản → mở Monaco Editor read-only (readOnly = true)
    Nếu nhị phân → thông báo "File nhị phân, không thể xem trước"
```

### 5.2 Giảng viên xem bài của sinh viên trong lớp mình giảng dạy

```
Giảng viên (FE course-service portal)
   │ Nhấn "Xem nội dung file nộp" trên submission của sinh viên
   ▼
FE: GET /api/v1/submissions/{submissionId}/tree
   │    X-User-Id: <giảng viên-id>
   ▼
submission-service: SubmissionController.getTree()
   │ 1. Kiểm tra X-User-Id là UUID canonical
   │ 2. Gọi SubmissionService.getSubmissionTree(submissionId, callerId)
   ▼
SubmissionService.getSubmissionTree()
   │ 3. Tìm submission theo id (404 nếu không tìm thấy)
   │ 4. submission.studentId != callerId (sinh viên khác lecturer)
   │ 5. Gọi courseServiceClient.getAssignmentOwner(submission.getAssignmentId())
   │    → course-service InternalAssignmentController.owner()
   │    → TestPlanService.internalAssignmentOwner() → trả về ownerId
   │ 6. Kiểm tra ownerId == callerId (giảng viên sở hữu lớp)
   │    Nếu khớp → cho phép xem; nếu không → 404
   │ 7. Lấy rustfsPath, tải bytes zip từ RustFS
   │ 8. Dùng ZipInputStream duyệt entries → build JSON tree
   │ 9. Trả về SubmissionZipTreeResponse
   ▼
FE: Hiển thị antd Tree / DirectoryTree
   │
   │ Giảng viên nhấn file src/Main.java
   ▼
FE: GET /api/v1/submissions/{submissionId}/file?path=src/Main.java
   ▼
submission-service: SubmissionController.getFile()
   │ 10. Kiểm tra X-User-Id, sanitize path (chống zip slip)
   │ 11. Gọi SubmissionService.getZipFileContent(submissionId, path, callerId)
   ▼
SubmissionService.getZipFileContent()
   │ 12. Kiểm tra quyền sở hữu (giảng viên sở hữu lớp)
   │ 13. Tải bytes zip từ RustFS, dùng ZipInputStream tìm entry
   │ 14. Phát hiện MIME, phân loại text/nhị phân
   │ 15. Đọc nội dung văn bản (tối đa 2 MB), gán truncated nếu quá lớn
   │ 16. Trả về SubmissionZipFileResponse
   ▼
FE: Nếu văn bản → mở Monaco Editor read-only (readOnly = true)
    Nếu nhị phân → thông báo "File nhị phân, không thể xem trước"
```

---

## 6. Khuyến nghị frontend (đề xuất, chưa implement)

- Dùng **Monaco Editor** hoặc **CodeMirror**, set `readOnly = true`.
- Dùng **antd `Tree`** hoặc `DirectoryTree` để hiển thị cây thư mục.
- Khi nhấn file văn bản: mở editor read-only, hiển thị nội dung.
- Khi nhấn file nhị phân: hiển thị thông báo "File nhị phân, không thể xem trước".
- Giới kích thước file hiển thị (2 MB), file lớn hơn → cắt và thông báo.

---

## 7. Các file đã thay đổi/tạo

| File | Thay đổi |
|------|----------|
| `src-services/submission-service/.../dto/response/SubmissionZipTreeResponse.java` | Mới |
| `src-services/submission-service/.../dto/response/ZipTreeNode.java` | Mới |
| `src-services/submission-service/.../dto/response/SubmissionZipFileResponse.java` | Mới |
| `src-services/submission-service/.../dto/internal/AssignmentOwnerResponse.java` | Mới (dùng nội bộ trong submission-service) |
| `src-services/submission-service/.../client/CourseServiceClient.java` | Mới (Feign client gọi course-service) |
| `src-services/submission-service/.../config/FeignLoggingConfiguration.java` | Mới (Feign config placeholder) |
| `src-services/submission-service/.../service/SubmissionService.java` | Sửa: thêm 2 method `getSubmissionTree`, `getZipFileContent`, `requireOwnedSubmission` (thêm kiểm tra lecturer) |
| `src-services/submission-service/.../service/RustFSService.java` | Sửa: thêm `downloadObject(String objectName)` |
| `src-services/submission-service/.../controller/SubmissionController.java` | Sửa: thêm 2 endpoint `GET /tree` và `GET /file` |
| `src-services/submission-service/pom.xml` | Sửa: bỏ `<optional>true</optional>` trên lombok |
| `src-services/submission-service/src/main/resources/application.yaml` | Sửa: thêm `feign.course-service.url` |
| `src-services/course-service/.../dto/internal/AssignmentOwnerResponse.java` | Mới |
| `src-services/course-service/.../controller/InternalAssignmentController.java` | Sửa: thêm endpoint `GET /{id}/owner` |
| `src-services/course-service/.../service/TestPlanService.java` | Sửa: thêm method `internalAssignmentOwner(UUID)`, thêm import |
| `docs/api/docs/submission-service/submission-zip-viewer-controller.md` | Mới (tài liệu API này) |

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/submission-service/`. Viết theo quy ước đã cập nhật trong `AGENTS.md` (API reference documentation).*
