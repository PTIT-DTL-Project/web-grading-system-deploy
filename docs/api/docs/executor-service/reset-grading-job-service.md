# ResetGradingJobService — executor-service

Nơi lưu: `docs/api/docs/executor-service/reset-grading-job-service.md`

Mục đích: giải thích nghiệp vụ reset một grading job về `PENDING` để chấm lại, dữ liệu
nào bị xoá, dữ liệu nào được giữ, và các trường hợp bị từ chối.

---

## 1. Tổng quan

`ResetGradingJobService` là `@Service` `@Transactional`, xử lý yêu cầu "chấm lại" cho một
bài nộp. Nó không chạy lại job — chỉ dọn trạng thái để pipeline có thể nhận job lần nữa.

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.grading` |
| Annotation | `@Service`, `@Slf4j`, `@RequiredArgsConstructor`, method `@Transactional` |
| Ai gọi | `ResetGradingJobController` (HTTP nội bộ), `DryRunController` không dùng lớp này |

## 2. Phụ thuộc

| Repository | Vai trò |
|---|---|
| `GradingJobRepository` | Tìm job theo `submissionId`, lưu job sau khi reset |
| `GradingSagaRepository` | Liệt kê saga của job, reset trạng thái saga |
| `GradingSagaStepRepository` | Xoá từng bước của saga |
| `GradingStepResultRepository` | Xoá kết quả từng bước của job |

## 3. API

### 3.1 `ResetResult reset(UUID submissionId)`

| Khía cạnh | Nội dung |
|---|---|
| Input | `submissionId` — bài nộp cần chấm lại |
| Output | `record ResetResult(boolean success, String message, UUID jobId, GradingJob job)` |
| Transaction | Có — toàn bộ thay đổi commit cùng nhau |

## 4. Luồng chi tiết

1. `gradingJobRepository.findBySubmissionId(submissionId)`.
2. Nếu không có job: log warn (`RESET_NOT_FOUND_PREFIX`), trả
   `ResetResult(false, "No grading job found for submission", null, null)`.
3. Nếu job đang `DONE`: log warn (`RESET_FAILED_PREFIX`), trả
   `ResetResult(false, "Job is already DONE, current status: ...", jobId, job)`.
   Lý do: job đã có kết quả cuối, reset sẽ làm mất dấu kết quả đã công bố; muốn chấm lại
   phải tạo job mới ở luồng nộp bài.
4. Xoá `grading_step_results` theo `jobId`.
5. Với từng saga của job: xoá `grading_saga_steps` theo `sagaId`, log lại việc xoá.
6. `gradingSagaRepository.resetByJobId(jobId, SagaStatus.STARTED)` — đưa mọi saga về mốc
   bắt đầu để lần chạy sau ghi lại tiến trình từ đầu.
7. Cập nhật job:
   - `status = PENDING`
   - `errorMessage = null`
   - `startedAt = null`, `completedAt = null`
   - `retryCount = retryCount + 1`
8. Lưu job, log `RESET_PREFIX` và `RESET_SUCCESS_PREFIX`, trả `ResetResult(true, "Job reset
   to PENDING", jobId, job)`.

## 5. Vì sao xoá step results và saga steps

- `grading_step_results` là kết quả chi tiết của lần chấm trước; giữ lại sẽ khiến UI hiển
  thị trộn kết quả cũ/mới và `GradingOrchestrator` cộng sai điểm.
- `grading_saga_steps` là tiến trình từng chương của saga; xoá để lần chạy mới không
  tưởng các bước đã hoàn thành.

## 6. Trường hợp biên

| Tình huống | Kết quả |
|---|---|
| Không tìm thấy job | `success=false`, `jobId=null` |
| Job `DONE` | `success=false`, giữ nguyên dữ liệu |
| Job `RUNNING` | Vẫn reset (không chặn) — gọi khi job đang chạy có thể tranh chấp với worker; controller phía trên chịu trách nhiệm chỉ gọi khi job đã dừng |
| Saga không có step | Vòng lặp không xoá gì, vẫn reset trạng thái saga |

## 7. Liên kết

- Gọi từ: `ResetGradingJobController` — xem `reset-grading-job-controller.md`.
- Sau khi reset, job được đẩy lại qua `StaleJobReaper` (job `PENDING` quá hạn) hoặc qua
  lời gọi `GradingOrchestrator.gradeAsync` từ controller.
- Xem thêm: `stale-job-reaper.md`, `grading-orchestrator.md`.

---

## Chi tiết từng hàm

### `ResetResult reset(UUID submissionId)` — `@Transactional`

| Khía cạnh | Nội dung |
|---|---|
| Input | id submission |
| Output | `ResetResult(success, message, jobId, job)` |
| Transaction | một khối: xoá step results + saga steps + reset saga + reset job |

1. `findBySubmissionId`; rỗng → log warn `RESET_NOT_FOUND_PREFIX`, trả
   `(false, "No grading job found for submission", null, null)`.
2. Job đang `DONE` → log warn `RESET_FAILED_PREFIX`, trả `(false, "Job is already DONE, current
   status: ...", jobId, job)` — không cho chấm lại bài đã có điểm.
3. `deleteByJobId(jobId)` xoá toàn bộ `grading_step_results` của job.
4. Với từng `GradingSaga` của job: `deleteBySagaId(sagaId)` rồi log; sau vòng lặp
   `sagaRepository.resetByJobId(jobId, STARTED)` (một câu UPDATE, không load lại entity).
5. Reset job: `status = PENDING`, `errorMessage = null`, `startedAt = null`, `completedAt = null`,
   `retryCount = retryCount + 1` (lần chấm lại có chủ đích được tính là một lượt, để reaper
   không re-enqueue vô hạn khi job hỏng lặp lại), save.
6. Log `RESET_PREFIX` + `RESET_SUCCESS_PREFIX`; trả `(true, "Job reset to PENDING", jobId, job)`.

Vì `@Transactional`, lỗi giữa chừng (ví dụ xoá step results xong nhưng save job lỗi) rollback
toàn bộ — DB không ở trạng thái nửa vời. Sau khi trả về, controller tự đẩy job PENDING vào
hàng đợi chấm (xem `reset-grading-job-controller.md`).

### `record ResetResult(boolean success, String message, UUID jobId, GradingJob job)`

`job` có thể null (không tìm thấy); controller dùng `success`/`message` để trả HTTP, `jobId`
để log/trace. Accessor do record sinh.
