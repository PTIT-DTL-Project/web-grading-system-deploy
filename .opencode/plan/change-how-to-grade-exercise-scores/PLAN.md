# Plan: Thay đổi cách tính điểm exercise — bài chưa làm tính 0, chia theo tổng số bài (có trọng số)

## Trạng thái: HOÀN TẤT (đã implement và chạy test)

## Vấn đề đã giải quyết

1. **Bài chưa làm tính 0, vẫn cộng trọng số vào mẫu số** — `maxPerPlanAverage` enumerates mọi plan từ course-service, plan không có result row → `score = 0` nhưng vẫn cộng `weight` vào mẫu số.
2. **Failed stepless FULL run → missing/null, không phải 0.00** — nếu `best` rỗng (không có attempt scorable nào), trả `null` sớm trước khi enumerating `allPlanWeights`. Giữ quy tắc documented: lỗi hệ thống không làm hỏng điểm sinh viên.
3. **Draft/unpublished GRADED assignment không vào mẫu số EXERCISE** — `ScoreService` lọc `published = true` khi build `assignmentIds` cả ở `computeExercise()` và `transcript()`.

## Files đã thay đổi

### 1. `result-service/.../service/ResultService.java`
- `maxPerPlanAverage`: thêm kiểm tra `if (best.isEmpty()) return null;` sớm, trước khi enumerating `allPlanKeys`. Cập nhật Javadoc + comment review `Review: 2026-10-31`.

### 2. `course-service/.../repository/AssignmentRepository.java`
- Thêm method `findAllByClassIdAndPurposeAndPublished(UUID classId, AssignmentPurpose purpose, boolean published)`.

### 3. `course-service/.../service/ScoreService.java`
- `computeExercise()` (dòng 208): dùng `findAllByClassIdAndPurposeAndPublished(classId, GRADED, true)` thay vì `findAllByClassIdAndPurpose`.
- `transcript()` (dòng 254): tương tự.
- Cập nhật comment giải thích lý do lọc published.

### 4. `result-service/.../service/ResultServiceTest.java`
- `weightedScoreByPlan_steplessFullRowContributesNothing`: stub plan list thật (2 plan weight 1, 2), sinh viên chỉ có 1 FAILED FULL run không steps → kỳ vọng `null` (không phải 0.00).
- Thêm `weightedScoreByPlan_unsubmittedPlanScoresZeroWhenBestNotEmpty`: 1 bài nộp 8.00 (weight 1), 1 bài chưa nộp (weight 3) → kỳ vọng `2.00` (= 8/4).

### 5. `result-service/.../service/ResultServiceReadTest.java`
- Test cũ `getByAssignment_fallsBackToTheLatestRowWhenNothingIsScorable` vẫn pass (stub plan list rỗng → `allPlanWeights` trống → `best` rỗng → trả null).
- Test `getByAssignment_unsubmittedPlanScoresZeroWithWeight` đã có từ trước: 5 plan, 4 nộp, 1 chưa nộp → 5.11.

## Files không thay đổi
- `course-service/.../client/ResultServiceClient.java`
- `result-service/.../controller/ResultInternalController.java`
- `result-service/.../client/CourseServicePlansClient.java`
- `result-service/.../dto/response/AssignmentResultGroupResponse.java` (Javadoc đã cập nhật từ lần trước)

## Verification (đã chạy)
- `result-service`: 68 tests pass (0 failures). Lỗi duy nhất `ResultServiceApplicationTests.contextLoads` — pre-existing do thiếu DB/Redis infra.
- `course-service`: 206 tests pass (0 failures). Lỗi duy nhất `CourseServiceApplicationTests.contextLoads` — pre-existing.

## Kết quả kỳ vọng (đã kiểm tra qua test)

| Trường hợp | Có attempt scorable? | Điểm exercise |
|------------|---------------------|---------------|
| Chưa nộp bài nào | Không | `null` (missing) |
| Nộp bài lỗi hệ thống (FAILED FULL, không steps) | Không | `null` (missing) |
| Nộp bài làm sai hết (score = 0) | Có | `0.00` (với weight) |
| Nộp 4/5 bài, 1 bài chưa nộp, weight bằng 1 | Có | `8.00` |
| 5 plan, weight [2,1,3,1,2], 4 nộp [8,6,10,7], 1 chưa nộp | Có | `5.11` (= 46/9) |
| 1 bài nộp 8.00 (w=1), 1 bài chưa nộp (w=3) | Có | `2.00` (= 8/4) |
