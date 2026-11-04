# Tài liệu chi tiết luồng API — submission-service / SubmissionWebhookController

Nơi lưu: `docs/api/docs/submission-service/submission-webhook-controller.md`

Mục đích: giải thích chi tiết webhook RustFS của submission-service, bao gồm input, output, luồng xử lý, ví dụ, và mã lỗi. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`SubmissionWebhookController` là REST controller của service `submission-service`, trỏ về base path `/api/v1/submissions/webhook`. Nó cung cấp endpoint nhận sự kiện từ RustFS (object storage) khi sinh viên PUT file zip nộp bài hoàn thành. Đây là **một trong những trigger duy nhất** để khởi động quy trình chấm điểm (kèm theo `ResetGradingJobController` của executor-service cho việc chạy lại chấm điểm).

| Endpoint | Method | Mục đích | Gửi bởi |
|----------|--------|----------|---------|
| `/api/v1/submissions/webhook/upload-complete` | POST | Nhận sự kiện RustFS `ObjectCreated:Put` trên object `submissions/*.zip`, khởi tạo chấm điểm | RustFS (ObjectCreated:Put webhook) |

**Không kiểm tra identity** — webhook đến từ RustFS (object storage infrastructure), không có JWT hay header auth. Controller chỉ lọc sự kiện theo tên sự kiện (`ObjectCreated:Put`) và đường dẫn object (`submissions/` + kết thúc `.zip`).

Controller giao tiếp với `SubmissionService.handleUploadCompleteAsync(...)` để xử lý sự kiện.

---

## 2. DTO liên quan (webhook payload)

### 2.1 `RustFsPayload` (dto/webhook)
Toàn bộ payload gửi từ RustFS webhook.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `rootEventName` | String | Tên sự kiện gốc (mapped từ JSON `EventName`) |
| `rootKey` | String | Tên object gốc (mapped từ JSON `Key`) |
| `records` | `List<RustFsRecord>` | Danh sách bản ghi sự kiện |

Ghi chú: Dùng `@JsonIgnoreProperties(ignoreUnknown = true)` để bỏ qua các trường không xác định từ RustFS.

### 2.2 `RustFsRecord` (dto/webhook)
Một bản ghi sự kiện trong payload.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `eventName` | String | Tên sự kiện của bản ghi (ví dụ `ObjectCreated:Put`) |
| `s3` | `RustFsS3` | Thông tin object storage (bucket, object) |

### 2.3 `RustFsS3` (lớp lồng bên trong RustFsRecord)
| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `object` | `RustFsS3Object` | Thông tin object |

### 2.4 `RustFsS3Object` (lớp lồng bên trong RustFsS3)
| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `key` | String | Tên/đường dẫn object (ví dụ `submissions/c49eb1e3-...zip`) |
| `size` | long | Kích thước object (bytes) |

---

## 3. Chi tiết hàm `handleRustFsWebhook`

**Vị trí:** `SubmissionWebhookController.handleRustFsWebhook(...)` → `SubmissionService.handleUploadCompleteAsync(...)`

**Endpoint:** `POST /api/v1/submissions/webhook/upload-complete`

**Request body:** `RustFsPayload`

**Luồng xử lý:**

1. **Controller:** Nhận `RustFsPayload payload`.
   - Lấy `records = payload.getRecords()`.
   - Nếu `records` null hoặc rỗng → log `"RustFS empty payload."`, trả về `ResponseEntity.ok().build()` (200 OK, không làm gì).
   - Log `"RustFS webhook received: {} event(s)"` với số lượng records.
   - Duyệt từng `RustFsRecord record` trong `records`:
     - **Lọc sự kiện:** Nếu `record.getEventName()` null hoặc **không chứa** `ObjectCreated:Put` → bỏ qua (`continue`).
     - **Kiểm tra object:** Nếu `record.getS3()` null hoặc `record.getS3().getObject()` null → `continue`.
     - Lấy `rawKey = record.getS3().getObject().getKey()`.
     - Giải mã URL: `decodedKey = URLDecoder.decode(rawKey, StandardCharsets.UTF_8)`.
     - **Lọc đường dẫn object:** Nếu `decodedKey` **không bắt đầu bằng** `submissions/` **hoặc** **không kết thúc bằng** `.zip` → bỏ qua (`continue`).
     - Log `"Submission upload detected: key={}, size={}"`.
     - Gọi `submissionService.handleUploadCompleteAsync(decodedKey)` — xử lý bất đồng bộ (`@Async`).
   - Trả về `ResponseEntity.ok().build()` (200 OK) sau khi đã phân phối tất cả sự kiện hợp lệ.

2. **Service `SubmissionService.handleUploadCompleteAsync(String objectName)` (@Async):**
   - Gọi `handleUploadComplete(objectName)`.

3. **Service `SubmissionService.handleUploadComplete(String objectName)` (@Transactional):**
   - Truy vấn `submissionRepository.findByRustfsPath(objectName)`. Nếu null → log warn `"Webhook received for unknown object: {}"`, trả về.
   - Lấy `previous = submission.getStatus()`.
   - Nếu `previous == null` hoặc `previous == PENDING`:
     - Đặt `submission.setStatus(PENDING)`, lưu.
     - Log `"Upload confirmed by webhook: id={}, objectName={}"`.
   - Ngược lại (đã GRADING/DONE/FAILED):
     - Log `"Webhook ignored, submission already {}: id={}"` — **không hồi quy status** (tránh webhook trùng/làm muộn làm quay về trạng thái cũ).
   - Gọi `publishGradingIfNotStarted(submission, previous)`.

4. **Phương thức `publishGradingIfNotStarted(Submission submission, SubmissionStatus previous)`:**
   - Nếu `previous` là `GRADING`, `DONE`, hoặc `FAILED` → log `"Grading message skipped (already {}): id={}"`, trả về (không publish lại).
   - Ngược lại → publish sự kiện `GradeSubmissionPayload` qua `wgsEventsProducer.publishGradeSubmission(...)` với:
     - `submissionId`
     - `assignmentId`
     - `studentId`
     - `planId`
     - `rustfsPath`
   - Sự kiện này được gửi đến Kafka topic `wgs-events`, executor-service consumer (`GRADE_SUBMISSION`) nhận và tạo `GradingJob` để chạy chấm điểm.

**Ví dụ request body (RustFS webhook):**
```json
{
  "Records": [
    {
      "eventName": "ObjectCreated:Put",
      "s3": {
        "object": {
          "key": "submissions/c49eb1e3-1234-5678-90ab-cdef12345678.zip",
          "size": 7253
        }
      }
    }
  ]
}
```

**Ví dụ response (200):** Rỗng (không body).

**Mã lỗi:** Không có mã lỗi HTTP (luôn trả về 200 OK ngay cả khi không có sự kiện hợp lệ hoặc object không tìm thấy — log warn thay vì ném lỗi).

---

## 4. Mã lỗi / xử lý đặc biệt

| Tình huống | Xử lý |
|------------|-------|
| Payload `records` null hoặc rỗng | Log `"RustFS empty payload."`, trả về 200 OK |
| `eventName` không chứa `ObjectCreated:Put` | Bỏ qua bản ghi đó |
| `s3` hoặc `s3.object` null | Bỏ qua bản ghi đó |
| Object key không bắt đầu `submissions/` hoặc không kết thúc `.zip` | Bỏ qua bản ghi đó |
| `objectName` không tìm thấy submission nào | Log warn `"Webhook received for unknown object: {}"`, trả về (không làm gì) |
| Submission đã GRADING/DONE/FAILED | Bỏ qua publish grading (không hồi quy status), log thông báo |
| Webhook bị gửi nhiều lần (duplicate) | Bản thứ hai trở đi thấy status đã != PENDING → bỏ qua publish |

---

## 5. Luồng dữ liệu từ đầu đến cuối (ví dụ sinh viên PUT zip lên RustFS)

```
Sinh viên (FE)
   │ 1. PUT file zip lên RustFS uploadUrl (từ presigned-url)
   ▼
RustFS
   │ 2. Lưu object `submissions/<uuid>.zip`
   │ 3. Phát sự kiện ObjectCreated:Put đến webhook submission-service
   ▼
submission-service: SubmissionWebhookController.handleRustFsWebhook()
   │ 4. Nhận payload RustFsPayload
   │ 5. Lọc eventName = ObjectCreated:Put, key bắt đầu submissions/ kết thúc .zip
   │ 6. Gọi submissionService.handleUploadCompleteAsync(decodedKey)
   ▼
SubmissionService.handleUploadCompleteAsync()  (@Async)
   │ 7. Gọi handleUploadComplete(objectName)
   ▼
SubmissionService.handleUploadComplete()  (@Transactional)
   │ 8. Tìm submission theo rustfsPath = objectName
   │ 9. Nếu status PENDING/null → giữ PENDING, lưu
   │    Nếu đã GRADING/DONE/FAILED → bỏ qua (không hồi quy)
   │ 10. Gọi publishGradingIfNotStarted(submission, previous)
   │     - Nếu previous là GRADING/DONE/FAILED → bỏ qua publish
   │     - Ngược lại → publish GradeSubmissionPayload đến Kafka (wgs-events)
   ▼
Kafka (wgs-events) → executor-service consumer (GRADE_SUBMISSION)
   │ 11. Tạo GradingJob (status=PENDING), chạy chấm điểm
   │     (xem chi tiết tài liệu grading-orchestrator.md)
   │ 12. Sau khi chấm xong, executor gọi submission-service
   │     PUT /api/v1/internal/submissions/{id}/status → status = DONE/FAILED
   ▼
FE/sinh viên xem status qua GET /api/v1/submissions hoặc course-service grading view
```

---

## 6. Lý do thiết kế quan trọng

| Quyết định | Lý do |
|------------|-------|
| Trả về 200 OK luôn (không ném lỗi) | Webhook từ infrastructure không nên làm fail do sự kiện không liên quan; log warn thay vì ném lỗi |
| Không hồi quy status khi đã GRADING/DONE/FAILED | Tránh webhook trùng/gửi làm muộn làm quay lại trạng thái cũ, gây lỗi chấm điểm |
| `@Async` trên `handleUploadCompleteAsync` | Webhook phản hồi ngay cho RustFS, xử lý publish Kafka ở nền |
| Chỉ lọc `submissions/*.zip` | Bỏ qua các sự kiện object khác trên cùng bucket (ví dụ metadata, log) |

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/submission-service/`. Các controller/service của submission-service hiện đã viết đầy đủ (3 file). Tiếp theo sẽ viết tài liệu cho ai-assistant-service (5 controller).*
