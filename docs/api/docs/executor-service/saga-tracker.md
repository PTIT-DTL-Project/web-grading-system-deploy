# SagaTracker — executor-service

Nơi lưu: `docs/api/docs/executor-service/saga-tracker.md`

Mục đích: giải thích lớp theo dõi tiến trình chấm theo saga, vì sao mọi method nuốt lỗi và
trả `null`, và cách orchestrator dùng id trả về.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.grading` |
| Annotation | `@Service`, `@RequiredArgsConstructor`, `@Slf4j` |
| Phụ thuộc | `GradingSagaRepository`, `GradingSagaStepRepository` |
| Ai gọi | `GradingOrchestrator` (begin/step/finishStep/finish), `ResetGradingJobService` (reset dữ liệu) |

Triết lý (Javadoc): *best-effort* — tracking không bao giờ được làm hỏng việc chấm. Mỗi
method bắt mọi `Exception`, log warn, trả `null` (hoặc void). Caller truyền thẳng id nhận
được vào lần gọi sau, kể cả `null`.

## 2. API

### 2.1 `UUID begin(UUID jobId)`

Tạo `GradingSaga` mới cho job, trả `id`. Lỗi → warn `Saga begin failed`, trả `null`.

### 2.2 `UUID step(UUID sagaId, String name, UUID planId, UUID stepId)`

1. `sagaId == null` → trả `null` ngay (không gọi DB).
2. `currentStep(sagaId, name)` cập nhật `current_step` của saga.
3. Tạo `GradingSagaStep` với `stepName`, `planId`, `stepId`, trả `id`.
4. Lỗi bất kỳ → warn `Saga step failed`, `null`.

### 2.3 `void finishStep(UUID stepRowId, SagaStepStatus status, String error)`

`stepRowId == null` → no-op. Tìm dòng, set `status`, `errorMessage`, `completedAt = now`,
lưu. Không tìm thấy → im lặng. Lỗi → warn.

### 2.4 `void finish(UUID sagaId, SagaStatus status)`

`sagaId == null` → no-op. Tìm saga, set `status`, `completedAt`, lưu.

### 2.5 `private currentStep(sagaId, name)`

Cập nhật `current_step` để UI hiển thị "đang ở bước nào"; lỗi chỉ warn.

## 3. Vì sao nuốt lỗi

Các bảng saga là dữ liệu quan sát (observability), không tham gia tính điểm. Nếu DB saga
đầy/lỗi mà ném ra ngoài, một job đang chấm tốt sẽ bị đánh `FAILED` oan. Đổi lại, khi tracking
lỗi thì UI có thể thiếu bước — chấp nhận được.

## 4. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| `begin` lỗi | `null`; các lần `step` sau cũng no-op vì `sagaId` null |
| `step` lỗi sau khi đã tạo saga | Saga không có step; `finish` vẫn chạy được |
| `finishStep` gọi lại lần hai | Ghi đè status/completedAt |
| Xoá saga giữa chừng (reset) | `findById` rỗng → im lặng |

## 5. Quan hệ

```text
GradingOrchestrator
   │ sagaId = begin(jobId)
   ├── stepId = step(sagaId, "FETCH_CONFIG", planId, stepId)
   ├── finishStep(stepId, DONE, null)
   └── finish(sagaId, SagaStatus.DONE | FAILED)
```

`ResetGradingJobService` xoá `grading_saga_steps` và reset saga về `STARTED` — xem
`reset-grading-job-service.md`.