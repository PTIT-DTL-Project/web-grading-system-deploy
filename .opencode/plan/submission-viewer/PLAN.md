# PLAN: Tính năng xem nội dung file zip nộp bài (tree + editor read-only)

Trạng thái: **ĐÃ IMPLEMENT XONG** (code compile thành công cả course-service và submission-service)

Thư mục lưu plan: `.opencode/plan/submission-viewer/`

## 1. Mục tiêu

Giảng viên (sở hữu lớp của assignment) và sinh viên (chủ sở hữu submission) có thể xem nội dung file zip mà sinh viên nộp, dưới dạng:
- **Tree view** của thư mục trong zip (folder và file).
- **Editor read-only** khi nhấn vào một file văn bản (Java, Python, Markdown, ...).
- File nhị phân chỉ hiển thị thông báo, không mở editor.

Không giải nén zip ra đĩa server; dùng `java.util.zip.ZipFile` để đọc trực tiếp từ RustFS.

## 2. Phạm vi (in-scope / out-of-scope)

### In-scope
- Thêm endpoint công khai trong `submission-service`:
  - `GET /api/v1/submissions/{submissionId}/tree` — trả về cây thư mục của zip.
  - `GET /api/v1/submissions/{submissionId}/file?path=...` — trả về nội dung một entry trong zip.
- Kiểm tra quyền sở hữu (giảng viên sở hữu lớp của assignment; sinh viên chủ sở hữu submission).
- Bảo mật: chống zip slip, giới hạn kích thước file hiển thị, phân loại text/nhị phân.
- Cập nhật tài liệu API trong `docs/api/docs/submission-service/`.
- Cập nhật `AGENTS.md` nếu cần (đã có phần API reference documentation).

### Out-of-scope
- Xem ảnh/PDF preview trong editor (chỉ text read-only).

## 3. Các file liên quan trong repo

| File | Vai trò |
|------|---------|
| `src-services/submission-service/src/main/java/.../controller/SubmissionController.java` | Thêm 2 endpoint `tree` và `file` |
| `src-services/submission-service/src/main/java/.../service/SubmissionService.java` | Thêm logic đọc zip từ RustFS, build tree, đọc entry |
| `src-services/submission-service/src/main/java/.../dto/response/SubmissionZipTreeResponse.java` | DTO cây thư mục |
| `src-services/submission-service/src/main/java/.../dto/response/SubmissionZipFileResponse.java` | DTO nội dung file |
| `src-services/submission-service/src/main/java/.../client/RustFSClient.java` | (Nếu chưa có) client tải metadata/nội dung zip từ RustFS |
| `docs/api/docs/submission-service/submission-zip-viewer-controller.md` | Tài liệu API chi tiết (theo mẫu đã viết) |

## 4. Chi tiết endpoint

### 4.1 `GET /api/v1/submissions/{submissionId}/tree`

**Mục đích:** Trả về cây thư mục (folder/file) của file zip nộp bài.

**Path variable:**
- `submissionId` (UUID)

**Header đầu vào:**
- `X-User-Id` (String, bắt buộc): ID người gọi (JWT sub).

**Luồng xử lý:**
1. Controller nhận `submissionId` và `X-User-Id`.
2. Gọi `submissionService.getSubmissionTree(submissionId, callerId)`.
3. Service:
   - Truy vấn `submissionRepository.findById(submissionId)`. Nếu không tìm thấy → `ResourceNotFoundException`.
   - Kiểm tra quyền sở hữu:
     - Nếu `callerId == submission.getStudentId()` → cho phép (sinh viên xem của mình).
     - Nếu không → gọi course-service (hoặc kiểm tra nội bộ) để xác nhận `callerId` là giảng viên sở hữu lớp của `submission.getAssignmentId()`. Nếu không → `ResourceNotFoundException` (404, không phân biệt không tồn tại vs không sở hữu).
   - Lấy `rustfsPath` từ submission.
   - Tải nội dung zip từ RustFS (hoặc mở stream từ RustFS nếu client hỗ trợ).
   - Dùng `ZipFile` duyệt các entry, loại bỏ các entry hệ thống (`__MACOSX`, `.DS_Store`, ...), chống zip slip (chặn path chứa `../` hoặc tuyệt đối).
   - Xây dựng JSON tree các cấp (folder và file), mỗi node có: `name`, `type` (`folder`/`file`), `path`, `size` (nếu file), `mime` (đoán từ extension).
   - Giới hạn tổng số entry (ví dụ 5.000). Nếu vượt quá → ném `BadRequestException`.
   - Trả về `SubmissionZipTreeResponse`.

**Ví dụ response (200):**
```json
{
  "submissionId": "c49eb1e3-...",
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
            "mime": "text/x-java"
          }
        ]
      },
      {
        "name": "README.md",
        "type": "file",
        "path": "README.md",
        "size": 890,
        "mime": "text/markdown"
      }
    ]
  }
}
```

**Mã lỗi:**
- `404`: submission không tồn tại hoặc người gọi không có quyền xem.
- `400`: zip lỗi, quá nhiều entry, ...

---

### 4.2 `GET /api/v1/submissions/{submissionId}/file`

**Mục đích:** Trả về nội dung văn bản của một entry trong zip, dùng cho editor read-only.

**Path variable:**
- `submissionId` (UUID)

**Query params:**
- `path` (String, bắt buộc): Đường dẫn entry trong zip (ví dụ `src/Main.java`).

**Header đầu vào:**
- `X-User-Id` (String, bắt buộc): ID người gọi.

**Luồng xử lý:**
1. Controller nhận `submissionId`, `path`, `X-User-Id`.
2. Gọi `submissionService.getZipFileContent(submissionId, path, callerId)`.
3. Service:
   - Kiểm tra quyền sở hữu như endpoint `tree`.
   - Sanitize `path`: chặn `../`, đường dẫn tuyệt đối, path ra ngoài root zip. Nếu vi phạm → `BadRequestException`.
   - Mở `ZipFile` từ RustFS, lấy `ZipEntry` theo `path`. Nếu không tìm thấy → `ResourceNotFoundException` (404).
   - Đọc bytes của entry với giới hạn kích thước (ví dụ tối đa 2 MB). Nếu lớn hơn → trả về `isBinary = true` hoặc `truncated = true` với nội dung phần đầu.
   - Phát hiện MIME theo extension (`.java` → `text/x-java`, `.md` → `text/markdown`, `.json` → `application/json`, ...).
   - Nếu là nhị phân → trả về `isBinary = true`, `content = null`, thông báo không xem được.
   - Nếu là văn bản → trả về nội dung chuỗi (UTF-8), kèm `truncated` nếu bị cắt.

**Ví dụ response (200, text):**
```json
{
  "path": "src/Main.java",
  "size": 1234,
  "mime": "text/x-java",
  "isBinary": false,
  "content": "public class Main { ... }",
  "truncated": false
}
```

**Ví dụ response (200, nhị phân):**
```json
{
  "path": "data.bin",
  "size": 1048576,
  "mime": "application/octet-stream",
  "isBinary": true,
  "content": null,
  "message": "File nhị phân, không thể hiển thị trong editor"
}
```

**Mã lỗi:**
- `404`: submission không tồn tại, entry không tìm thấy, hoặc người gọi không có quyền.
- `400`: `path` không hợp lệ (chống zip slip), zip lỗi.

---

### 4.3 `GET /api/v1/submissions/{submissionId}/download`

**Mục đích:** Trả về presigned URL download file zip từ RustFS, frontend dùng để tải toàn bộ zip về máy.

**Path variable:**
- `submissionId` (UUID)

**Header đầu vào:**
- `X-User-Id` (String, bắt buộc): ID người gọi (JWT sub).

**Luồng xử lý:**
1. Controller nhận `submissionId` và `X-User-Id`. Kiểm tra UUID canonical.
2. Gọi `submissionService.getSubmissionDownloadUrl(submissionId, callerId)`.
3. Service:
   - Kiểm tra quyền sở hữu (giống endpoint `tree`).
   - Lấy `rustfsPath` từ submission.
   - Gọi `rustfsService.generatePresignedDownloadUrl(objectName)` để lấy URL tải file zip.
   - Trả về `SubmissionZipDownloadResponse` với `downloadUrl` và `expiresInMinutes`.

**Ví dụ request:**
```http
GET /api/v1/submissions/c49eb1e3-1234-5678-90ab-cdef12345678/download
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
```

**Ví dụ response (200):**
```json
{
  "submissionId": "c49eb1e3-1234-5678-90ab-cdef12345678",
  "downloadUrl": "https://rustfs.example.com/submissions/c49eb1e3.zip?X-Amz-...",
  "expiresInMinutes": 60
}
```

**Mã lỗi:**
- `400`: `X-User-Id` không phải UUID chính xác.
- `404`: submission không tồn tại hoặc người gọi không có quyền.
- `502`: RustFS không khả dụng.

---

## 5. DTO đề xuất

### 5.1 `SubmissionZipTreeResponse`
| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `submissionId` | UUID | ID submission |
| `root` | `ZipTreeNode` | Nút gốc của cây |

### 5.2 `ZipTreeNode` (lồng nhau)
| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `name` | String | Tên folder/file |
| `type` | String | `folder` hoặc `file` |
| `path` | String | Đường dẫn tương đối trong zip |
| `size` | Long | Kích thước bytes (chỉ file) |
| `mime` | String | Loại nội dung (chỉ file) |
| `children` | `List<ZipTreeNode>` | Các nút con (chỉ folder) |

### 5.3 `SubmissionZipFileResponse`
| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `path` | String | Đường dẫn entry |
| `size` | Long | Kích thước bytes |
| `mime` | String | Loại nội dung |
| `isBinary` | Boolean | Có phải nhị phân hay không |
| `content` | String | Nội dung văn bản (null nếu nhị phân) |
| `truncated` | Boolean | Có bị cắt do quá lớn hay không |
| `message` | String | Thông báo bổ sung (nếu nhị phân/lớn) |

### 5.4 `SubmissionZipDownloadResponse`
| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `submissionId` | UUID | ID submission |
| `downloadUrl` | String | URL tải file zip từ RustFS (presigned URL) |
| `expiresInMinutes` | long | Thời gian hết hạn URL (phút) |

## 6. Bảo mật và giới hạn

| Vấn đề | Giải pháp |
|--------|-----------|
| Quyền xem | Chỉ giảng viên sở hữu lớp của assignment hoặc sinh viên chủ sở hữu submission |
| Không phân biệt tồn tại vs sở hữu | Trả về 404 trong cả 2 trường hợp |
| Zip slip | Chặn entry path chứa `../` hoặc bắt đầu bằng `/` |
| File quá lớn | Giới hạn đọc nội dung (ví dụ 2 MB), trả về `truncated = true` |
| Zip bomb | Giới hạn tổng số entry (ví dụ 5.000) |
| File nhị phân | Phân loại theo extension/magic bytes, không decode thành văn bản |
| RustFS không khả dụng | Trả về lỗi 502 hoặc thông báo rõ ràng, không crash server |

## 7. Luồng dữ liệu end-to-end (giảng viên xem bài)

```
Giảng viên (FE course-service portal)
   │ Nhấn "Xem nội dung file nộp" trên submission
   ▼
FE: GET /api/v1/submissions/{submissionId}/tree
   │    X-User-Id: <giảng viên-id>
   ▼
submission-service: SubmissionController.tree()
   │ 1. Kiểm tra X-User-Id
   │ 2. Gọi SubmissionService.getSubmissionTree(submissionId, callerId)
   ▼
SubmissionService.getSubmissionTree()
   │ 3. Tìm submission theo id (404 nếu không tìm thấy)
   │ 4. Kiểm tra quyền sở hữu (giảng viên lớp hoặc sinh viên chủ sở hữu)
   │ 5. Lấy rustfsPath, mở ZipFile từ RustFS
   │ 6. Duyệt entries, build JSON tree, giới hạn số entry
   │ 7. Trả về SubmissionZipTreeResponse
   ▼
FE: Hiển thị antd Tree / DirectoryTree
   │
   │ Giảng viên nhấn file src/Main.java
   ▼
FE: GET /api/v1/submissions/{submissionId}/file?path=src/Main.java
   ▼
submission-service: SubmissionController.file()
   │ 8. Kiểm tra quyền sở hữu
   │ 9. Sanitize path (chống zip slip)
   │ 10. Mở ZipFile, lấy entry, đọc bytes (tối đa 2 MB)
   │ 11. Phát hiện MIME, phân loại text/nhị phân
   │ 12. Trả về SubmissionZipFileResponse
   ▼
FE: Nếu text → mở Monaco Editor read-only (readOnly = true)
    Nếu binary → thông báo "File nhị phân, không thể xem trước"
```

## 8. Dự án công việc (work items)

1. **Tìm hiểu RustFS client hiện tại:** Kiểm tra submission-service đã có client tải file từ RustFS chưa (`RustFSClient`, `rustfsService.buildObjectName`, ...). Nếu chưa, tạo client đơn giản để lấy bytes zip từ RustFS theo `objectName`.
2. **Tạo DTO:** `SubmissionZipTreeResponse`, `ZipTreeNode`, `SubmissionZipFileResponse` trong `dto/response/`.
3. **Thêm service:** Phương thức `getSubmissionTree(...)` và `getZipFileContent(...)` trong `SubmissionService.java`.
4. **Thêm controller:** 2 endpoint `GET /tree` và `GET /file` trong `SubmissionController.java`.
5. **Viết tài liệu API:** `docs/api/docs/submission-service/submission-zip-viewer-controller.md` theo mẫu đã viết (chi tiết input/output/luồng/ví dụ/mã lỗi), bằng tiếng Việt.
6. **Kiểm tra quy ước:** Tuân thủ `AGENTS.md` (không `@Value`, không positional constructor >2 args, `asString()` thay `asText()`, comment review nếu sửa bug, ...).
7. **Review và duyệt plan** trước khi implement code.

## 9. Khuyến nghị frontend (đề xuất, không implement trong plan này)

- Dùng **Monaco Editor** hoặc **CodeMirror**, set `readOnly = true`.
- Dùng **antd `Tree`** hoặc `DirectoryTree` để hiển thị cây thư mục.
- Khi nhấn file văn bản: mở editor read-only, hiển thị nội dung.
- Khi nhấn file nhị phân: hiển thị thông báo "File nhị phân, không thể xem trước" + nút tải file (nếu cần).
- Giới kích thước file hiển thị (ví dụ 2 MB), file lớn hơn → cắt và thông báo.

## 10. Triển khai frontend (Monaco Editor read-only + antd Tree + download entry)

### 10.1 Dependencies
| Package | Lý do |
|---------|-------|
| `@monaco-editor/react` | Editor code read-only với syntax highlighting |

Cài đặt: `pnpm add @monaco-editor/react` (hoặc `npm install @monaco-editor/react`).

### 10.2 TypeScript types (`shared/types/submission.ts`)

```typescript
export interface ZipTreeNode {
  name: string
  type: 'folder' | 'file'
  path: string
  size?: number
  mime?: string
  children?: ZipTreeNode[]
}

export interface SubmissionZipTreeResponse {
  submissionId: string
  root: ZipTreeNode
}

export interface SubmissionZipFileResponse {
  submissionId: string
  path: string
  size: number
  mime: string
  isBinary: boolean
  content: string | null
  truncated: boolean | null
  message: string | null
}

export interface SubmissionZipDownloadResponse {
  submissionId: string
  downloadUrl: string
  expiresInMinutes: number
}
```

### 10.3 API client (`shared/api/endpoints/submissions.ts`)

Thêm 2 hàm:

```typescript
export async function getSubmissionTree(
  submissionId: string
): Promise<SubmissionZipTreeResponse> {
  return getData<SubmissionZipTreeResponse>(
    `/api/v1/submissions/${submissionId}/tree`
  )
}

export async function getSubmissionFile(
  submissionId: string,
  path: string
): Promise<SubmissionZipFileResponse> {
  return getData<SubmissionZipFileResponse>(
    `/api/v1/submissions/${submissionId}/file`,
    { path }
  )
}

export async function getSubmissionDownloadUrl(
  submissionId: string
): Promise<SubmissionZipDownloadResponse> {
  return getData<SubmissionZipDownloadResponse>(
    `/api/v1/submissions/${submissionId}/download`
  )
}
```

Lưu ý: `X-User-Id` được gateway inject tự động từ JWT, frontend không cần set thủ công.

### 10.3 Component chính: `SubmissionZipViewer.tsx`

Nơi lưu: `frontend-src/web-grading-system-fe/src/features/submissions/SubmissionZipViewer.tsx`

**Props:**
```typescript
interface SubmissionZipViewerProps {
  submissionId: string
  zipFileName: string
  onClose?: () => void
}
```

**Luồng hoạt động:**
1. Mount → gọi `getSubmissionTree(submissionId)`.
2. Hiển thị `antd Tree` bên trái (width ~280px), editor Monaco bên phải.
3. Click folder → expand/collapse (antd Tree `expandedKeys`/`onExpand`).
4. Click file → gọi `getSubmissionFile(submissionId, path)`.
   - Nếu `isBinary === true` → hiển thị `Alert` thông báo "File nhị phân, không thể xem trước" + nút tải file (nếu có download endpoint).
   - Nếu `isBinary === false` → mở Monaco Editor với `content`, `readOnly = true`, ngôn ngữ theo `mime`/extension (`.java` → `java`, `.py` → `python`, `.js` → `javascript`, `.md` → `markdown`, ...).
5. Nút "Tải toàn bộ zip" → gọi `getSubmissionDownloadUrl(submissionId)` để lấy presigned URL, rồi `window.location.assign(downloadUrl)` để tải file zip về máy.
6. `useEffect` cleanup: `editor.dispose()` để tránh memory leak.

**Giao diện:** `antd Layout` — `Layout.Sider` trái cho Tree, `Layout.Content` phải cho Editor/Alert.

### 10.3 Routes (`app/router.tsx`)

Thêm 2 route bên trong `RequireIdentity`:

```tsx
// Lecturer xem bài sinh viên trong lớp mình dạy
{
  path: 'classes/:classId/assignments/:assignmentId/submissions/:submissionId/viewer',
  element: (
    <RequireRole role="LECTURER">
      <SubmissionZipViewer />
    </RequireRole>
  ),
},
// Sinh viên xem bài của mình
{
  path: 'student/submissions/:submissionId/viewer',
  element: (
    <RequireRole role="STUDENT">
      <SubmissionZipViewer />
    </RequireRole>
  ),
},
```

### 10.4 Translation keys (`locales/vi.json` / `locales/en.json`)

Thêm vào namespace `submission`:

```json
"submission": {
  "viewZip": "Xem nội dung file nộp",
  "zipTree": "Cây thư mục",
  "fileContent": "Nội dung file",
  "binaryFile": "File nhị phân, không thể xem trước",
  "downloadFile": "Tải file này",
  "downloadZip": "Tải toàn bộ zip",
  "largeFile": "File quá lớn, chỉ hiển thị phần đầu {{size}}KB",
  "loadError": "Không tải được nội dung file",
  "back": "Quay lại danh sách nộp"
}
```

### 10.5 Integration trên các trang hiện có
- `MySubmissionsPage.tsx`: thêm nút "Xem nội dung file" (`EyeOutlined`) trên mỗi hàng submission → navigate đến `/student/submissions/:id/viewer`.
- `AssignmentSubmissionsPage.tsx`: thêm nút tương tự → navigate đến `/classes/:classId/assignments/:assignmentId/submissions/:submissionId/viewer`.

## 11. Dự án công việc (work items) — FE

1. **API client:** Thêm `getSubmissionTree`, `getSubmissionFile`, `getSubmissionDownloadUrl` vào `shared/api/endpoints/submissions.ts`.
2. **Types:** Thêm `SubmissionZipTreeResponse`, `ZipTreeNode`, `SubmissionZipFileResponse`, `SubmissionZipDownloadResponse` vào `shared/types/submission.ts`.
3. **Dependency:** `pnpm add @monaco-editor/react`.
4. **Backend:** Thêm endpoint `GET /api/v1/submissions/{submissionId}/download` vào `SubmissionController` + phương thức `getSubmissionDownloadUrl` vào `SubmissionService` + phương thức `generatePresignedDownloadUrl` vào `RustFSService`.
5. **Component:** Tạo `SubmissionZipViewer.tsx` (Tree + Monaco Editor read-only + nút "Tải toàn bộ zip").
6. **Routes:** Thêm 2 route vào `app/router.tsx` (lecturer + student).
7. **Translations:** Thêm keys vào `locales/vi.json` và `locales/en.json`.
8. **Integration:** Thêm nút "Xem nội dung file" trên `MySubmissionsPage` và `AssignmentSubmissionsPage`.
9. **Build check:** `pnpm run build` (hoặc `npm run build`) để xác nhận không lỗi compile.

## 12. Kết quả sau khi implement

- **Code đã compile thành công cả course-service và submission-service** (không lỗi).
- **Files đã tạo/sửa trong submission-service:**
  - `dto/response/SubmissionZipTreeResponse.java` (mới)
  - `dto/response/ZipTreeNode.java` (mới)
  - `dto/response/SubmissionZipFileResponse.java` (mới)
  - `dto/internal/AssignmentOwnerResponse.java` (mới)
  - `client/CourseServiceClient.java` (mới, Feign client gọi course-service)
  - `config/FeignLoggingConfiguration.java` (mới)
  - `service/SubmissionService.java` (sửa: thêm `getSubmissionTree`, `getZipFileContent`, `getSubmissionDownloadUrl`, `requireOwnedSubmission` có kiểm tra lecturer)
  - `service/RustFSService.java` (sửa: thêm `downloadObject`, `generatePresignedDownloadUrl`)
  - `controller/SubmissionController.java` (sửa: thêm 3 endpoint `GET /tree`, `GET /file`, `GET /download`)
  - `dto/response/SubmissionZipDownloadResponse.java` (mới)
  - `pom.xml` (sửa: bỏ `<optional>true</optional>` trên lombok)
  - `src/main/resources/application.yaml` (sửa: thêm `feign.course-service.url`)
- **Files đã tạo/sửa trong course-service:**
  - `dto/internal/AssignmentOwnerResponse.java` (mới)
  - `controller/InternalAssignmentController.java` (sửa: thêm endpoint `GET /{id}/owner`)
  - `service/TestPlanService.java` (sửa: thêm `internalAssignmentOwner(UUID)`, thêm import)
- **Tài liệu API:** `docs/api/docs/submission-service/submission-zip-viewer-controller.md` (mới, bao gồm cả lecturer access)
- **Lombok:** Đã sửa được bằng cách bỏ `<optional>true</optional>` khỏi dependency lombok trong `pom.xml`, sau đó dùng `@Data`, `@Builder`, `@NoArgsConstructor`, `@AllArgsConstructor` bình thường.

**Quyền truy cập:**
- Sinh viên chủ sở hữu submission: được xem.
- Giảng viên sở hữu lớp của assignment: được xem (qua course-service internal API `GET /api/v1/internal/assignments/{id}/owner`).
- Người khác: 404.

**Sẵn sàng để FE tích hợp (Monaco Editor read-only + antd Tree + nút tải toàn bộ zip).**

- **Code đã compile thành công cả course-service và submission-service** (không lỗi).
- **Files đã tạo/sửa trong submission-service:**
  - `dto/response/SubmissionZipTreeResponse.java` (mới)
  - `dto/response/ZipTreeNode.java` (mới)
  - `dto/response/SubmissionZipFileResponse.java` (mới)
  - `dto/internal/AssignmentOwnerResponse.java` (mới)
  - `client/CourseServiceClient.java` (mới, Feign client gọi course-service)
  - `config/FeignLoggingConfiguration.java` (mới)
  - `service/SubmissionService.java` (sửa: thêm `getSubmissionTree`, `getZipFileContent`, `getSubmissionDownloadUrl`, `requireOwnedSubmission` có kiểm tra lecturer)
  - `service/RustFSService.java` (sửa: thêm `downloadObject`, `generatePresignedDownloadUrl`)
  - `controller/SubmissionController.java` (sửa: thêm 3 endpoint `GET /tree`, `GET /file`, `GET /download`)
  - `dto/response/SubmissionZipDownloadResponse.java` (mới)
  - `pom.xml` (sửa: bỏ `<optional>true</optional>` trên lombok)
  - `src/main/resources/application.yaml` (sửa: thêm `feign.course-service.url`)
- **Files đã tạo/sửa trong course-service:**
  - `dto/internal/AssignmentOwnerResponse.java` (mới)
  - `controller/InternalAssignmentController.java` (sửa: thêm endpoint `GET /{id}/owner`)
  - `service/TestPlanService.java` (sửa: thêm `internalAssignmentOwner(UUID)`, thêm import)
- **Tài liệu API:** `docs/api/docs/submission-service/submission-zip-viewer-controller.md` (mới, bao gồm cả lecturer access)
- **Lombok:** Đã sửa được bằng cách bỏ `<optional>true</optional>` khỏi dependency lombok trong `pom.xml`, sau đó dùng `@Data`, `@Builder`, `@NoArgsConstructor`, `@AllArgsConstructor` bình thường.

**Quyền truy cập:**
- Sinh viên chủ sở hữu submission: được xem.
- Giảng viên sở hữu lớp của assignment: được xem (qua course-service internal API `GET /api/v1/internal/assignments/{id}/owner`).
- Người khác: 404.

**Sẵn sàng để FE tích hợp (Monaco Editor read-only + antd Tree + nút tải toàn bộ zip).**
