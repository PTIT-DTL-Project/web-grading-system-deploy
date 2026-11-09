# Tài liệu chi tiết luồng API — submission-service / SubmissionController

Nơi lưu: `docs/api/docs/submission-service/submission-controller.md`

Mục đích: giải thích chi tiết từng hàm/controller/service trong luồng nộp bài (submission) của submission-service, bao gồm input, output, điều kiện tiên quyết, ví dụ request/response, và các mã lỗi có thể xảy ra. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`SubmissionController` là REST controller của service `submission-service`, trỏ về base path `/api/v1/submissions`. Nó cung cấp các endpoint để sinh viên nộp bài (lấy URL upload presigned), xem danh sách bài nộp của mình, và xem chi tiết một bài nộp.

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/submissions/presigned-url` | POST | Yêu cầu URL upload zip nộp bài (tạo submission PENDING) | STUDENT |
| `/api/v1/submissions` | GET | Lấy danh sách bài nộp của mình (có lọc, tìm kiếm, phân trang) | STUDENT |
| `/api/v1/submissions/{id}` | GET | Xem chi tiết một bài nộp | STUDENT (chủ sở hữu) |
| `/api/v1/submissions/health` | GET | Health check + thông tin phiên bản | Public |
| `/api/v1/submissions/version` | GET | Thông tin phiên bản và build | Public |

**Quan trọng về quyền:** Tất cả endpoint nghiệp vụ đều bắt buộc header `X-User-Id` (không có `@PreAuthorize`, kiểm tra trong controller/service). `X-User-Id` phải là UUID chính xác (canonical form), không chấp nhận shorthand như `1-1-1-1-1` (tránh đóng dấu sinh viên ảo). Sinh viên chỉ xem được bài nộp của chính mình (`callerId == submission.getStudentId()`), không có bypass cho lecturer ở đây (lecturer xem qua `GET /api/v1/assignments/{id}/submissions` của course-service).

Controller giao tiếp với `SubmissionService` để thực hiện logic nghiệp vụ.

---

## 2. DTO liên quan

### 2.1 `PresignedUrlResponse` (dto/response)
Trả về sau khi yêu cầu URL upload.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `submissionId` | UUID | ID submission vừa tạo |
| `uploadUrl` | String | URL presigned để PUT file zip lên RustFS |
| `objectName` | String | Tên object trên RustFS (ví dụ `submissions/<uuid>.zip`) |
| `expiresInMinutes` | long | Thời gian hết hạn của URL (phút) |

### 2.2 `SubmissionResponse` (dto/response)
Thông tin một bài nộp.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID bài nộp |
| `assignmentId` | UUID | ID bài tập |
| `studentId` | UUID | ID sinh viên (JWT sub) |
| `zipFileName` | String | Tên file zip nộp |
| `status` | String | `PENDING`, `GRADING`, `DONE`, `FAILED` |
| `latest` | Boolean | Là bài nộp mới nhất hay không |
| `createdAt` | OffsetDateTime | Thời điểm nộp |
| `planId` | UUID | Null = nộp toàn bộ assignment; có giá trị = chọn một plan cụ thể |

---

## 3. Chi tiết từng hàm

### 3.1 `requestUpload` — Yêu cầu URL upload zip nộp bài

**Vị trí:** `SubmissionController.requestUpload(...)` → `SubmissionService.requestUpload(...)`

**Endpoint:** `POST /api/v1/submissions/presigned-url`

**Query params (bắt buộc):**
| Param | Kiểu | Mô tả |
|-------|------|-------|
| `assignmentId` | UUID | ID bài tập |
| `zipFileName` | String | Tên file zip |
| `planId` | UUID | — | ID plan (null = nộp toàn bộ assignment) |

**Header đầu vào:**
- `X-User-Id` (String, **bắt buộc**, không có default): ID sinh viên. Không có → `400 MissingRequestHeaderException`. Blank/sai định dạng → `400 IllegalArgumentException`.

**Luồng xử lý (Controller → Service):**

1. **Controller:**
   - Lấy `studentIdHeader` từ header `X-User-Id`.
   - Chuyển sang `UUID studentId = UUID.fromString(studentIdHeader)`.
   - **Kiểm tra canonical UUID:** `studentId.toString().equalsIgnoreCase(studentIdHeader)`. Nếu sai (ví dụ shorthand `1-1-1-1-1` parse được UUID nhưng không phải canonical) → ném `IllegalArgumentException("X-User-Id must be a canonical UUID")`. Điều này tránh đóng dấu sinh viên ảo.
   - Gọi `submissionService.requestUpload(assignmentId, studentId, zipFileName, planId)`.
   - Trả về `ResponseEntity.status(HttpStatus.CREATED).body(PresignedUrlResponse)`.

2. **Service `SubmissionService.requestUpload` (@Transactional):**
   - **Demote các latest row cũ:** `submissionRepository.findAllLatestByAssignmentAndStudent(assignmentId, studentId)`, với mỗi row cũ đặt `latest = false`. Điều này tự healing nếu race condition để lại nhiều row `latest=true` (Review: 2026-09-28, Pullfrog PR #24).
   - Tạo `submissionId = UUID.randomUUID()`.
   - Tạo `objectName = rustfsService.buildObjectName(submissionId)` (ví dụ `submissions/<uuid>.zip`).
   - Xây dựng entity `Submission` với `id`, `assignmentId`, `studentId`, `planId`, `rustfsPath = objectName`, `zipFileName`, `status = PENDING`, `latest = true`.
   - `entityManager.persist(submission)`.
   - `uploadUrl = rustfsService.generatePresignedUploadUrl(objectName)`.
   - Log `"Presigned URL generated: submissionId={}, objectName={}"`.
   - Trả về `PresignedUrlResponse` với `submissionId`, `uploadUrl`, `objectName`, `expiresInMinutes`.

**Ví dụ request:**
```http
POST /api/v1/submissions/presigned-url?assignmentId=16cebadb-2485-4494-be5b-7f6641887559&zipFileName=student-management-solution.zip&planId=7e31465c-2764-4848-abf3-854832c64361
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
```

**Ví dụ response (201):**
```json
{
  "submissionId": "c49eb1e3-1234-5678-90ab-cdef12345678",
  "uploadUrl": "https://rustfs.example.com/submissions/c49eb1e3-...zip?X-Amz-...",
  "objectName": "submissions/c49eb1e3-1234-5678-90ab-cdef12345678.zip",
  "expiresInMinutes": 60
}
```

**Mã lỗi có thể xảy ra:**
- `400`: thiếu `X-User-Id` (MissingRequestHeaderException), `X-User-Id` không phải UUID chính xác (IllegalArgumentException).
- `401/403`: nếu gateway không xác thực (xử lý trước controller).

---

### 3.2 `listMySubmissions` — Lấy danh sách bài nộp của mình

**Vị trí:** `SubmissionController.listMySubmissions(...)` → `SubmissionService.listByStudent(...)`

**Endpoint:** `GET /api/v1/submissions`

**Query params:**
| Param | Kiểu | Bắt buộc | Mặc định | Mô tả |
|-------|------|----------|----------|-------|
| `page` | int | — | 0 | Trang (0-based) |
| `size` | int | — | 20 | Kích thước trang |
| `search` | String | — | null | Tìm kiếm theo tên file zip (chứa chuỗi, không phân biệt hoa thường) |
| `assignmentId` | UUID | — | null | Lọc theo một bài tập cụ thể |

**Header đầu vào:**
- `X-User-Id` (String, **bắt buộc**): ID sinh viên.

**Luồng xử lý:**
1. Controller tạo `Pageable` với `PageRequest.of(page, size)`.
2. Gọi `submissionService.listByStudent(UUID.fromString(studentId), assignmentId, search, pageable)`.
3. Service `listByStudent`:
   - Nếu `assignmentId == null`:
     - Nếu `search` null/trống → `findByStudentIdOrderByCreatedAtDesc(studentId, pageable)`.
     - Ngược lại → `findByStudentIdAndZipFileNameContainingIgnoreCaseOrderByCreatedAtDesc(studentId, search, pageable)`.
   - Nếu `assignmentId != null`:
     - Nếu `search` null/trống → `findByStudentIdAndAssignmentIdOrderByCreatedAtDesc(studentId, assignmentId, pageable)`.
     - Ngược lại → `findByStudentIdAndAssignmentIdAndZipFileNameContainingIgnoreCaseOrderByCreatedAtDesc(studentId, assignmentId, search, pageable)`.
   - Map qua `submissionMapper::toResponse`, trả về `Page<SubmissionResponse>`.

**Ghi chú:** Tìm kiếm `search` chỉ match trên tên file zip (`zipFileName`) — thông tin title bài tập nằm trong `assignment_db`, không join được ở đây (submission_service chỉ có `assignment_db` riêng).

**Ví dụ request:**
```http
GET /api/v1/submissions?page=0&size=20&search=solution&assignmentId=16cebadb-2485-4494-be5b-7f6641887559
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
```

**Ví dụ response (200):**
```json
{
  "content": [
    {
      "id": "c49eb1e3-1234-5678-90ab-cdef12345678",
      "assignmentId": "16cebadb-2485-4494-be5b-7f6641887559",
      "studentId": "e4ab4157-8970-4169-90fb-b88d788a124c",
      "zipFileName": "student-management-solution.zip",
      "status": "DONE",
      "latest": true,
      "createdAt": "2026-11-01T10:21:58.494+07:00",
      "planId": null
    }
  ],
  "pageable": { "pageNumber": 0, "pageSize": 20, ... },
  "totalElements": 1,
  "totalPages": 1,
  "last": true,
  ...
}
```

**Mã lỗi:**
- `400`: thiếu `X-User-Id`.
- `401/403`: nếu gateway không xác thực.

---

### 3.3 `getById` — Xem chi tiết một bài nộp

**Vị trí:** `SubmissionController.getById(...)` → `SubmissionService.getById(...)`

**Endpoint:** `GET /api/v1/submissions/{id}`

**Path variable:** `id` (UUID) — ID bài nộp

**Header đầu vào:**
- `X-User-Id` (String, **bắt buộc**): ID người gọi.

**Luồng xử lý:**
1. Controller chuyển `callerIdHeader` sang `UUID callerId`.
2. Gọi `submissionService.getById(id)`:
   - Truy vấn `submissionRepository.findById(id)`. Nếu không tìm thấy → `ResourceNotFoundException("Submission not found: " + id)`.
   - Map qua `submissionMapper.toResponse`, trả về `SubmissionResponse`.
3. **Kiểm tra chủ sở hữu:** Nếu `callerId` khác `submission.getStudentId()` → ném `ResourceNotFoundException("Submission not found: " + id)`.
   - **Lý do:** Trả về 404 (không phải 403) để id không sở hữu không thể phân biệt với id không tồn tại — theo quy ước sở hữu của dự án.
   - **Lịch sử (Review: 2026-09-30):** Trước đây endpoint này có `@PreAuthorize("hasRole('LECTURER')")` cho phép bất kỳ lecturer nào xem bất kỳ submission nào — đã bị loại bỏ vì không kiểm tra xem assignment có thuộc lớp lecturer sở hữu hay không. Lecturer hiện tại xem qua course-service (`GET /api/v1/assignments/{id}/submissions`), role-gated và owner-scoped.
4. Trả về `ResponseEntity.ok(submission)`.

**Ví dụ request:**
```http
GET /api/v1/submissions/c49eb1e3-1234-5678-90ab-cdef12345678
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
```

**Ví dụ response (200):**
```json
{
  "id": "c49eb1e3-1234-5678-90ab-cdef12345678",
  "assignmentId": "16cebadb-2485-4494-be5b-7f6641887559",
  "studentId": "e4ab4157-8970-4169-90fb-b88d788a124c",
  "zipFileName": "student-management-solution.zip",
  "status": "DONE",
  "latest": true,
  "createdAt": "2026-11-01T10:21:58.494+07:00",
  "planId": null
}
```

**Mã lỗi:**
- `404`: bài nộp không tồn tại hoặc không thuộc về người gọi.
- `400`: thiếu `X-User-Id` hoặc UUID không chính xác.

---

### 3.4 `health` — Health check

**Vị trí:** `SubmissionController.health()`

**Endpoint:** `GET /api/v1/submissions/health`

**Luồng xử lý:**
1. Lấy phiên bản từ `getClass().getPackage().getImplementationVersion()`. Nếu null → `"dev"`.
2. Trả về `ResponseEntity.ok(Map.of(...))` với:
   - `status`: `"UP"`
   - `service`: `"submission-service"`
   - `version`: phiên bản
   - `timestamp`: `Instant.now().toString()`
   - `description`: `"Submission Service - Handles code submission operations"`

**Ví dụ response (200):**
```json
{
  "status": "UP",
  "service": "submission-service",
  "version": "dev",
  "timestamp": "2026-11-01T10:30:00Z",
  "description": "Submission Service - Handles code submission operations"
}
```

---

### 3.5 `version` — Thông tin phiên bản và build

**Vị trí:** `SubmissionController.version()`

**Endpoint:** `GET /api/v1/submissions/version`

**Luồng xử lý:**
1. Lấy phiên bản từ `getClass().getPackage().getImplementationVersion()`. Nếu null → `"dev"`.
2. Trả về `ResponseEntity.ok(Map.of(...))` với:
   - `service`: `"submission-service"`
   - `version`: phiên bản
   - `buildDate`: `LocalDate.now().toString()`
   - `commitSha`: `System.getenv().getOrDefault("GIT_COMMIT", "unknown")`

**Ví dụ response (200):**
```json
{
  "service": "submission-service",
  "version": "dev",
  "buildDate": "2026-11-01",
  "commitSha": "eca0900"
}
```

---

## 4. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 400 | Thiếu header `X-User-Id` | `SubmissionController.requestUpload` / `listMySubmissions` / `getById` |
| 400 | `X-User-Id` không phải UUID canonical (ví dụ shorthand) | `SubmissionController.requestUpload` |
| 404 | Submission không tồn tại / không thuộc người gọi | `SubmissionService.getById` |
| 401/403 | Gateway không xác thực | Xử lý trước controller |

---

## 5. Luồng dữ liệu từ đầu đến cuối (ví dụ sinh viên nộp bài và xem lại)

```
Sinh viên (FE)
   │ 1. POST /api/v1/submissions/presigned-url?assignmentId=...&zipFileName=...&planId=...
   │    header X-User-Id: e4ab4157-...
   ▼
submission-service: SubmissionController.requestUpload()
   │ 2. Kiểm tra X-User-Id là UUID canonical
   │ 3. Gọi SubmissionService.requestUpload(assignmentId, studentId, zipFileName, planId)
   ▼
SubmissionService.requestUpload()  (@Transactional)
   │ 4. Demote các submission latest=true cũ của cùng (assignmentId, studentId)
   │ 5. Tạo Submission entity (status=PENDING, latest=true), persist
   │ 6. Tạo presigned upload URL từ RustFS
   │ 7. Trả về PresignedUrlResponse{submissionId, uploadUrl, objectName, expiresInMinutes}
   ▼
SubmissionController.requestUpload()
   │ 8. Trả về 201 CREATED + PresignedUrlResponse
   ▼
FE nhận uploadUrl, PUT file zip lên RustFS
   │ 9. RustFS lưu zip, phát sự kiện ObjectCreated:Put
   ▼
submission-service: SubmissionWebhookController.handleRustFsWebhook()
   │ 10. Nhận webhook RustFS, lọc event ObjectCreated:Put và key bắt đầu submissions/ kết thúc .zip
   │ 11. Gọi submissionService.handleUploadCompleteAsync(objectName)
   │     - Tìm submission theo objectName
   │     - Nếu status PENDING (hoặc null) → giữ PENDING, lưu
   │     - Nếu đã GRADING/DONE/FAILED → bỏ qua (không cố trở lại)
   │     - Gọi publishGradingIfNotStarted → publish GRADE_SUBMISSION đến Kafka (wgs-events)
   ▼
Kafka consumer → executor-service tạo GradingJob, chạy chấm điểm
   │ 12. Sau khi chấm xong, executor gọi submission-service PUT /internal/submissions/{id}/status
   │     để cập nhật status = DONE/FAILED
   ▼
Sinh viên xem lại:
   │ GET /api/v1/submissions?page=0&size=20
   │ header X-User-Id: e4ab4157-...
   ▼
SubmissionController.listMySubmissions()
   │ 13. Gọi SubmissionService.listByStudent(studentId, null, null, pageable)
   │ 14. Trả về Page<SubmissionResponse> (kèm status DONE, latest)
   ▼
FE hiển thị danh sách bài nộp
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/submission-service/`. Tiếp theo sẽ viết tài liệu cho `SubmissionInternalController` và `SubmissionWebhookController`.*
