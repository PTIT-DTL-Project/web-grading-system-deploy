# Tài liệu chi tiết luồng API — executor-service / ResetGradingJobController (+ ResetGradingJobService)

Nơi lưu: `docs/api/docs/executor-service/reset-grading-job-controller.md`

Mục đích: giải thích chi tiết endpoint reset grading job của executor-service, cho phép lecturer chạy lại chấm điểm cho một submission đã nộp, bao gồm input, output, luồng xử lý, ví dụ, và mã lỗi. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`ResetGradingJobController` là REST controller của service `executor-service`, trỏ về base path `/api/v1/internal/grading-jobs`. Nó cung cấp endpoint reset grading job cho một submission — đặt trạng thái công việc chấm điểm về `PENDING`, xóa các kết quả bước cũ và saga, sau đó kích hoạt lại chấm điểm bất đồng bộ.

| Endpoint | Method | Mục đích | Gọi bởi |
|----------|--------|----------|---------|
| `/api/v1/internal/grading-jobs/{submissionId}/reset` | POST | Reset grading job của submission, chạy lại chấm điểm | course-service / lecturer |

**Internal-only:** không được exposing qua API gateway.

Controller giao tiếp với:
- `ResetGradingJobService.reset(...)` — đặt lại trạng thái job.
- `GradingOrchestrator.gradeAsync(...)` — kích hoạt chấm điểm lại sau khi reset thành công.
- `GradingJobRepository` — truy vấn job.

---

## 2. DTO liên quan

### 2.1 `ResetGradingJobRequest` (dto/request)

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `submissionId` | UUID | — | ID submission (đã có từ path variable) |
| `assignmentId` | UUID | — | ID bài tập |
| `studentId` | UUID | — | ID sinh viên |
| `planId` | UUID | — | ID plan (null = chấm toàn bộ assignment) |
| `rustfsPath` | String | — | Đường dẫn zip nộp trên RustFS |
| `traceId` | String | — | ID truy vết |

### 2.2 `ResetGradingJobService.ResetResult` (record)

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `success` | boolean | Reset thành công hay không |
| `message` | String | Thông báo kết quả |
| `jobId` | UUID | ID grading job |
| `job` | `GradingJob` | Đối tượng job (có thể null) |

---

## 3. Chi tiết hàm `reset`

**Vị trí:** `ResetGradingJobController.reset(...)` → `ResetGradingJobService.reset(...)` → `GradingOrchestrator.gradeAsync(...)`

**Endpoint:** `POST /api/v1/internal/grading-jobs/{submissionId}/reset`

**Path variable:**
- `submissionId` (UUID): ID submission cần reset

**Request body:** `ResetGradingJobRequest`

**Luồng xử lý (Controller → Service):**

1. **Controller:** Nhận `submissionId` từ path variable và `ResetGradingJobRequest request`. Log thông tin yêu cầu. Gọi `resetGradingJobService.reset(submissionId)`.
2. **Service `ResetGradingJobService.reset` (transactional):**
   - Truy vấn `gradingJobRepository.findBySubmissionId(submissionId)`. Nếu không tìm thấy → trả về `ResetResult(false, "No grading job found for submission", null, null)`.
   - Lấy `job`. Nếu `job.getStatus() == GradingJobStatus.DONE` → trả về `ResetResult(false, "Job is already DONE, current status: ...", job.getId(), job)` — không cho phép reset job đã hoàn thành.
   - Lấy `jobId = job.getId()`.
   - Xóa tất cả kết quả bước của job: `gradingStepResultRepository.deleteByJobId(jobId)`.
   - Lấy tất cả saga của job (`gradingSagaRepository.findByJobId(jobId)`). Với mỗi saga:
     - Xóa tất cả bước saga: `gradingSagaStepRepository.deleteBySagaId(sagaId)`.
     - Log `"Deleted saga steps for saga={}, reset saga to STARTED for job={}"`.
   - Reset trạng thái saga về `STARTED`: `gradingSagaRepository.resetByJobId(jobId, SagaStatus.STARTED)`.
   - Cập nhật job: `status = PENDING`, `errorMessage = null`, `startedAt = null`, `completedAt = null`, `retryCount = retryCount + 1`. Lưu qua `gradingJobRepository.save(job)`.
   - Log `"Job reset to PENDING"` và `"RESET_SUCCESS_PREFIX"`.
   - Trả về `ResetResult(true, "Job reset to PENDING", jobId, job)`.
3. **Controller (tiếp theo):** Nếu `result.success() == true`:
   - Truy vấn `gradingJobRepository.findById(result.jobId())` → lấy `GradingJob job`.
   - Nếu `job != null` → gọi `gradingOrchestrator.gradeAsync(result.jobId(), submissionId, job.getAssignmentId(), job.getStudentId(), job.getPlanId(), job.getRustfsPath(), request.getTraceId())` — kích hoạt chấm điểm bất đồng bộ.
   - Nếu `gradingOrchestrator.gradeAsync` ném `TaskRejectedException` (pool quá tải) → log warns, chấm điểm bị hoãn lại cho reaper xử lý sau.
4. **Controller trả về:** `ResponseEntity.ok(Map.of("success", result.success(), "message", result.message(), "jobId", result.jobId()))`.

**Ví dụ request:**
```http
POST /api/v1/internal/grading-jobs/c49eb1e3-1234-5678-90ab-cdef12345678/reset
Content-Type: application/json

{
  "submissionId": "c49eb1e3-1234-5678-90ab-cdef12345678",
  "assignmentId": "16cebadb-2485-4494-be5b-7f6641887559",
  "studentId": "e4ab4157-8970-4169-90fb-b88d788a124c",
  "planId": null,
  "rustfsPath": "submissions/student-management-solution.zip",
  "traceId": "trace-abc123"
}
```

**Ví dụ response (200, thành công):**
```json
{
  "success": true,
  "message": "Job reset to PENDING",
  "jobId": "a1b2c3d4-..."
}
```

**Ví dụ response (200, job đã DONE):**
```json
{
  "success": false,
  "message": "Job is already DONE, current status: DONE",
  "jobId": "a1b2c3d4-..."
}
```

**Ví dụ response (200, không tìm thấy job):**
```json
{
  "success": false,
  "message": "No grading job found for submission",
  "jobId": null
}
```

**Mã lỗi:** Không có mã lỗi HTTP (luôn trả về 200). Thành công/thất bại truyền qua trường `success` và `message` trong body.

---

## 4. Luồng dữ liệu từ đầu đến cuối (ví dụ lecturer chạy lại chấm điểm)

```
Lecturer / course-service
   │ POST /api/v1/internal/grading-jobs/{submissionId}/reset
   │    body: { submissionId, assignmentId, studentId, planId, rustfsPath, traceId }
   ▼
executor-service: ResetGradingJobController.reset()
   │ 1. Log yêu cầu reset
   │ 2. Gọi ResetGradingJobService.reset(submissionId)
   ▼
ResetGradingJobService.reset()  (@Transactional)
   │ 3. Tìm grading job theo submissionId (404 nếu không tìm thấy -> success=false)
   │ 4. Nếu job status = DONE -> trả về success=false (không cho reset job hoàn thành)
   │ 5. Xóa tất cả GradingStepResult của job
   │ 6. Lấy tất cả GradingSaga của job, xóa tất cả GradingSagaStep
   │ 7. Reset GradingSaga về STARTED
   │ 8. Cập nhật GradingJob: status=PENDING, errorMessage=null, startedAt=null,
   │    completedAt=null, retryCount+=1. Lưu.
   │ 9. Trả về ResetResult(success=true, message, jobId, job)
   ▼
ResetGradingJobController.reset()
   │ 10. Nếu success: gọi GradingOrchestrator.gradeAsync(jobId, submissionId, ...)
   │     (chạy nền, @Async "gradingTaskExecutor")
   │     Nếu pool quá tải (TaskRejectedException): log warn, hoãn lại cho reaper
   │ 11. Trả về 200 OK { success, message, jobId }
   ▼
executor-service (nền): GradingOrchestrator.gradeAsync() → grade()
   │ 12. Chạy toàn bộ luồng chấm điểm (FETCHING → BUILDING → RUNNING → DONE/FAILED)
   │     (xem chi tiết tài liệu grading-orchestrator.md)
   ▼
Lecturer nhận phản hồi reset, sau đó theo dõi kết quả chấm điểm qua result-service
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/executor-service/`. Tiếp theo sẽ viết tài liệu chi tiết cho `GradingOrchestrator` (cách chấm điểm).*
