# StaleJobReaper — executor-service

Nơi lưu: `docs/api/docs/executor-service/stale-job-reaper.md`

Mục đích: giải thích cơ chế tự phục hồi sau crash — tìm job kẹt ở giai đoạn đầu và đẩy
lại vào hàng chấm, kèm giới hạn số lần thử và lý do không đụng tới job `RUNNING`.

---

## 1. Tổng quan

`StaleJobReaper` là `@Service` chạy theo lịch (`@Scheduled`) để xử lý các job bị bỏ rơi khi
pod chết giữa chừng.

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.docker` |
| Annotation | `@Service`, `@Slf4j`, `@Scheduled(fixedDelayString = "${executor.reaper.interval-ms:300000}")` |
| Chu kỳ mặc định | 300000 ms (5 phút), `fixedDelay` nên lần sau tính từ lúc lần trước kết thúc |

## 2. Cấu hình liên quan (`ExecutorProperties.reaper`)

| Key | Ý nghĩa | Mặc định trong yaml |
|---|---|---|
| `executor.reaper.interval-ms` | Chu kỳ quét | `300000` |
| `executor.reaper.stale-after-minutes` | Tuổi tối thiểu để coi là kẹt | `30` |
| `executor.reaper.max-attempts` | Số lần đẩy lại tối đa | `3` |

Comment trong `application.yaml` nhấn mạnh: `stale-after-minutes` **phải lớn hơn** tổng
startup + execution timeout (6 phút), nếu không job đang chạy hợp lệ sẽ bị đẩy lại và bị
chấm hai lần.

## 3. Tập trạng thái được quét

```text
ACTIVE = [PENDING, FETCHING, BUILDING]
```

`RUNNING` bị loại **có chủ đích**:

- Đẩy lại một job `RUNNING` đang thực sự chạy sẽ khiến hai worker chấm cùng một bài.
- Thời gian tường (wall clock) không phân biệt được worker còn sống hay đã chết; muốn phân
  biệt cần lease/heartbeat — hệ thống hiện chưa có.
- Hệ quả: pod chết giữa `RUNNING` cần reset thủ công (`ResetGradingJobService`).

## 4. Luồng `reap()`

1. Đọc `staleAfterMinutes`, `maxAttempts` từ `ExecutorProperties`.
2. Tính `cutoff = now - staleAfterMinutes`.
3. Lấy `findByStatusIn(ACTIVE)`, lọc:
   - `isStale(job, cutoff)`: mốc thời gian là `startedAt`, nếu null thì `createdAt`; phải
     `isBefore(cutoff)`.
   - `retryCount < maxAttempts`: job đã thử quá số lần thì để cho người vận hành xử lý.
4. Với từng job kẹt:
   - Gọi `gradingOrchestrator.gradeAsync(..., Constant.Reaper.TRACE_ID)` để đẩy lại.
   - Nếu pool chấm đầy (`TaskRejectedException`): log warn và **không tăng** `retryCount` —
     job ở lại hàng chờ cho chu kỳ sau, không bị trừ lượt oan.
   - Ngược lại: tăng `retryCount`, lưu job, log `REENQUEUE_PREFIX` kèm trạng thái cũ.

## 5. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| Job không có `startedAt` lẫn `createdAt` | `isStale` trả false — không bị đụng |
| Job `PENDING` vừa tạo (< 30 phút) | Bỏ qua |
| Retry đã bằng `maxAttempts` | Bỏ qua, cần can thiệp thủ công |
| Orchestrator ném lỗi khác `TaskRejectedException` | Không bắt — lỗi lan ra scheduler, job giữ nguyên `retryCount` |

## 6. Quan hệ

```text
@Scheduled reap()
   ├── GradingJobRepository.findByStatusIn([PENDING, FETCHING, BUILDING])
   ├── ExecutorProperties.reaper()
   └── GradingOrchestrator.gradeAsync(...)  → gradingTaskExecutor (core=max=1, queue=10)
```

Đây là lưới an toàn phía executor-service; phía submission-service vẫn có thể phát lại sự
kiện Kafka nếu message bị lỗi, nhưng reaper xử lý trường hợp message đã mất.

---

## Chi tiết từng hàm

### `void reap()` — `@Scheduled(fixedDelayString = "${executor.reaper.interval-ms:300000}")`

| Khía cạnh | Nội dung |
|---|---|
| Input | `ExecutorProperties.reaper().staleAfterMinutes()` (mặc định 30), `.maxAttempts()` (mặc định 3) |
| Output | không; side effect: `gradeAsync` + tăng `retryCount` |

1. `cutoff = now - staleAfterMinutes`.
2. `findByStatusIn(ACTIVE)` với `ACTIVE = [PENDING, FETCHING, BUILDING]`.
3. Lọc `isStale(job, cutoff)` và `retryCount < maxAttempts` — job đã cạn lượt cần người xử
   lý, reaper không đụng.
4. Với từng job: `gradeAsync(jobId, submissionId, assignmentId, studentId, planId,
   rustfsPath, Constant.Reaper.TRACE_ID)`.
   - `TaskRejectedException` (pool bão hoà, queue 10 đầy) → log warn, `continue` **không**
     tăng `retryCount`: job vẫn còn nguyên lượt cho vòng sau.
5. Thành công → `retryCount + 1`, save, log `REENQUEUE_PREFIX`.

Vì sao loại `RUNNING`: re-enqueue một job đang chạy sẽ chấm hai lần; không có lease/heartbeat
thì không phân biệt được worker sống với pod đã chết, nên job chết giữa `RUNNING` phải reset
thủ công (`ResetGradingJobService`).

### `private static boolean isStale(GradingJob job, OffsetDateTime cutoff)`

`start = startedAt != null ? startedAt : createdAt`; trả `start != null && start.isBefore(cutoff)`.
Ưu tiên `startedAt` để job đã bắt đầu (FETCHING/BUILDING) không bị coi là mới chỉ vì
`createdAt` cũ; job chưa có `startedAt` dùng `createdAt`. Cả hai null → không bao giờ stale
(an toàn: bỏ qua thay vì chấm lại bừa).
