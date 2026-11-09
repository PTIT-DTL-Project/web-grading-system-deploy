# Tài liệu chi tiết luồng API — submission-service / SubmissionInternalController

Nơi lưu: `docs/api/docs/submission-service/submission-internal-controller.md`

Mục đích: giải thích chi tiết các endpoint nội bộ của submission-service dành cho executor-service và course-service, bao gồm input, output, luồng xử lý, ví dụ, và mã lỗi. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`SubmissionInternalController` là REST controller của service `submission-service`, trỏ về base path `/api/v1/internal/submissions`. Nó cung cấp các endpoint nội bộ (không được routed qua API gateway, không dùng `ApiResponse` envelope) cho executor-service và course-service.

| Endpoint | Method | Mục đích | Gọi bởi |
|----------|--------|----------|---------|
| `/api/v1/internal/submissions/assignment/{assignmentId}` | GET | Lấy danh sách bài nộp của một bài tập (view chấm điểm lecturer) | course-service (`AssignmentGradingController.submissions`) |
| `/api/v1/internal/submissions/{id}/status` | PUT | Cập nhật trạng thái bài nộp (GRADING/DONE/FAILED) | executor-service (`GradingOrchestrator.patchSubmission`) |

**Internal-only:** không được routed qua api-gateway, và được loại trừ khỏi `ApiResponse` envelope (xem `FormatRestResponse`). course-service là caller duy nhất của danh sách bài nộp theo assignment và đã xác thực quyền sở hữu assignment trước khi gọi. executor-service là caller duy nhất của cập nhật status.

Controller giao tiếp trực tiếp với `SubmissionService`.

---

## 2. DTO liên quan

### 2.1 `UpdateStatusRequest` (dto/request)

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `status` | String | `@NotNull` | Trạng thái mới của submission (ví dụ `GRADING`, `DONE`, `FAILED`) |

---

## 3. Chi tiết từng hàm

### 3.1 `listByAssignment` — Lấy danh sách bài nộp của một bài tập

**Vị trí:** `SubmissionInternalController.listByAssignment(...)` → `SubmissionService.listByAssignment(...)`

**Endpoint:** `GET /api/v1/internal/submissions/assignment/{assignmentId}`

**Path variable:**
- `assignmentId` (UUID): ID bài tập

**Query params:**
| Param | Kiểu | Bắt buộc | Mặc định | Mô tả |
|-------|------|----------|----------|-------|
| `page` | Integer | — | null | Trang (0-based). Nếu null hoặc `size` null → trả về toàn bộ danh sách (unpaged) |
| `size` | Integer | — | null | Kích thước trang |

**Luồng xử lý:**
1. Controller nhận `assignmentId`, `page`, `size`.
2. Xác định `Pageable`:
   - Nếu cả `page` và `size` khác null → `PageRequest.of(page, size)`.
   - Ngược lại → `Pageable.unpaged()` (trả về toàn bộ danh sách).
3. Gọi `submissionService.listByAssignment(assignmentId, pageable)`.
4. Service `listByAssignment`:
   - Nếu `pageable.isUnpaged()` → truy vấn `submissionRepository.findByAssignmentIdOrderByCreatedAtDesc(assignmentId)`, map sang danh sách, trả về `new PageImpl<>(list)`.
   - Ngược lại → truy vấn `submissionRepository.findByAssignmentIdOrderByCreatedAtDesc(assignmentId, pageable)`, trả về `Page<SubmissionResponse>`.
5. Controller trả về `ResponseEntity.ok(Page<SubmissionResponse>)`.

**Ghi chú (plan role-split-result-apis-v1.0, D4):** Endpoint này là đường dẫn nội bộ của route công khai cũ `GET /api/v1/submissions/assignment/{id}`. Trên route công khai,唯一 guard là role check (bất kỳ lecturer nào cũng có thể xem submissions của bất kỳ lớp nào). Hiện tại course-service là caller duy nhất và đã kiểm tra role (`LECTURER`) và quyền sở hữu lớp (owner-scoped) trước khi gọi endpoint nội bộ này.

**Ví dụ request:**
```http
GET /api/v1/internal/submissions/assignment/16cebadb-2485-4494-be5b-7f6641887559?page=0&size=20
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

**Mã lỗi:** Không có mã lỗi HTTP đặc biệt (luôn trả về 200, danh sách rỗng nếu không có submission nào).

---

### 3.2 `updateStatus` — Cập nhật trạng thái bài nộp

**Vị trí:** `SubmissionInternalController.updateStatus(...)` → `SubmissionService.updateStatus(...)`

**Endpoint:** `PUT /api/v1/internal/submissions/{id}/status`

**Path variable:**
- `id` (UUID): ID bài nộp cần cập nhật

**Request body:** `UpdateStatusRequest`
| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `status` | String | `@NotNull` | Trạng thái mới (`GRADING`, `DONE`, `FAILED`) |

**Luồng xử lý:**
1. Controller nhận `id` từ path variable và `UpdateStatusRequest request` từ body.
2. Gọi `submissionService.updateStatus(id, request.getStatus())`.
3. Service `updateStatus` (@Transactional):
   - Truy vấn `submissionRepository.findById(id)`. Nếu không tìm thấy → `ResourceNotFoundException("Submission not found: " + id)`.
   - Đặt `submission.setStatus(SubmissionStatus.valueOf(status))`. Nếu `status` không phải giá trị hợp lệ của enum `SubmissionStatus` → ném `IllegalArgumentException`.
   - Lưu qua `submissionRepository.save(submission)`.
   - Log `"Submission status updated: id={}, status={}"`.
4. Controller trả về `ResponseEntity.noContent().build()` (204 No Content, không body).

**Ghi chú:** Endpoint này được executor-service gọi sau khi chấm xong (thành công hoặc thất bại) để cập nhật status submission. `GradingOrchestrator.patchSubmission(submissionId, Constant.GradingLog.STEP_DONE)` hoặc `STEP_FAILED`.

**Ví dụ request:**
```http
PUT /api/v1/internal/submissions/c49eb1e3-1234-5678-90ab-cdef12345678/status
Content-Type: application/json

{ "status": "DONE" }
```

**Ví dụ response (204):** Rỗng (không body).

**Mã lỗi:**
- `404`: submission không tồn tại (`ResourceNotFoundException`).
- `400`: `status` không hợp lệ (không phải giá trị enum `SubmissionStatus`) hoặc thiếu trường `status` (`@NotNull`).

---

## 4. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 404 | Submission không tồn tại | `SubmissionService.updateStatus` |
| 400 | `status` thiếu hoặc không phải giá trị enum hợp lệ | `SubmissionService.updateStatus` (`@NotNull`, `SubmissionStatus.valueOf`) |

---

## 5. Luồng dữ liệu từ đầu đến cuối (ví dụ executor cập nhật status sau chấm xong)

```
executor-service: GradingOrchestrator.grade() (chấm xong)
   │ 1. Gọi patchSubmission(submissionId, Constant.GradingLog.STEP_DONE) hoặc STEP_FAILED
   ▼
submission-service: SubmissionInternalController.updateStatus()
   │ 2. Nhận id + body { status: "DONE" }
   │ 3. Gọi SubmissionService.updateStatus(id, "DONE")
   ▼
SubmissionService.updateStatus()  (@Transactional)
   │ 4. Tìm submission theo id (404 nếu không tìm thấy)
   │ 5. Đặt status = SubmissionStatus.DONE
   │ 6. Lưu, log "Submission status updated: id=..., status=DONE"
   ▼
SubmissionInternalController.updateStatus()
   │ 7. Trả về 204 No Content (không body)
   ▼
executor-service hoàn thành công việc chấm điểm
FE/sinh viên có thể xem status DONE qua GET /api/v1/submissions (của sinh viên) hoặc course-service grading view
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/submission-service/`. Tiếp theo sẽ viết tài liệu cho `SubmissionWebhookController`.*
