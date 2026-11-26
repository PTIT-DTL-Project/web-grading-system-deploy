# StepExecutor — executor-service

Nơi lưu: `docs/api/docs/executor-service/step-executor.md`

Mục đích: giải thích hợp đồng (interface) mà mọi loại bước chấm phải thực hiện, cách
`GradingOrchestrator` dùng nó, và các ràng buộc khi thêm một loại bước mới.

---

## 1. Tổng quan

`StepExecutor` là interface SPI của tầng chấm điểm: mỗi loại bước (`HTTP`, `DB_QUERY`,
`DB_SCHEMA_CHECK`, `DB_MIGRATION`, …) là một `@Component` implements interface này và
tự đăng ký vào `StepRegistry`. Bản thân interface không có trạng thái, không phụ thuộc
Spring — nó chỉ khai báo hai method.

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.step` |
| Loại | `public interface` |
| Bean | Không (là hợp đồng, các implementation mới là bean) |
| Ai gọi | `StepRegistry.of(type)` trả về implementation, `GradingOrchestrator` gọi `execute(ctx)` |

## 2. Hai method của hợp đồng

### 2.1 `String type()`

Trả về khoá định danh loại bước, khớp với trường `step_type` trong cấu hình chấm
(grading config) mà course-service trả về. Khoá này là duy nhất trên toàn bộ các
implementation — `StepRegistry` ném `IllegalStateException` ngay khi khởi động nếu hai
bean khai báo cùng một `type()`.

Giá trị thực tế trong hệ thống: xem `StepRegistry` và các lớp trong `step/impl/`.

### 2.2 `GradingStepResult execute(StepContext ctx)`

Chạy một bước với tham số trong `ctx` và trả về kết quả đã chuẩn hoá để lưu xuống
`grading_step_results`.

Đầu vào `StepContext` gồm: `jobId`, `planId`, `stepId`, `stepOrder`, `stepName`,
`config` (JsonNode của bước), `variableContext` (biến thay thế `${...}`), `timeoutMs`.

Đầu ra `GradingStepResult` phải điền tối thiểu:

| Trường | Ý nghĩa |
|---|---|
| `status` | `PASSED` / `FAILED` / `SKIPPED` / `ERROR` |
| `requestUrl/Headers/Body`, `responseStatusCode/Headers/Body` | Bằng chứng thô của bước HTTP |
| `assertionResult` | JSON danh sách `AssertionDetail` |
| `extractedVariables` | Biến đã trích, dạng JSON object |
| `errorMessage`, `stackTrace` | Lỗi và stack trace (nếu có) |
| `durationMs`, `startedAt`, `completedAt` | Thời gian chạy bước |

`GradingStepResult` **không** có cột điểm/trọng số: điểm do `GradingOrchestrator` tính từ
`status` + `weight` trong cấu hình bước (mặc định 1) qua `ScoreCalculator`, rồi mới ghi
vào kết quả plan. Executor chỉ cần trả trạng thái và bằng chứng đúng.

## 3. Ràng buộc khi thêm loại bước mới

1. Tạo class `@Component` implements `StepExecutor` trong `service/step/impl/`.
2. `type()` trả về chuỗi không trùng với bất kỳ executor nào khác (nếu trùng, ứng dụng
   không khởi động được — xem `StepRegistry`).
3. `execute()` không được ném exception ra ngoài: lỗi cấu hình/parse phải được bắt và
   trả về `GradingStepResult` với `status = ERROR`, kèm thông điệp. Nếu ném ra ngoài,
   `GradingOrchestrator` sẽ đánh dấu cả job `FAILED` thay vì chỉ bước đó.
4. Mọi giá trị nhạy cảm trong `config`/response phải đi qua `EvidenceRedactor` trước khi
   ghi vào kết quả, vì log và kết quả được đẩy sang result-service và hiển thị cho sinh viên.
5. Tôn trọng `ctx.getTimeoutMs()` (nếu loại bước có timeout riêng) và không chặn vô hạn.

## 4. Quan hệ với các lớp khác

```text
GradingOrchestrator
   │  stepType = step.getStepType()
   ▼
StepRegistry.of(stepType)
   │  Map<String, StepExecutor>
   ▼
StepExecutor.execute(new StepContext(...))
   ├── HTTP            → HttpStepExecutor
   ├── DB_QUERY        → DbQueryExecutor
   ├── DB_SCHEMA_CHECK → DbSchemaCheckExecutor
   └── DB_MIGRATION    → DbMigrationExecutor
   ▼
GradingStepResult (lưu DB + đẩy sang result-service)
```

## 5. Mã lỗi liên quan

| Tình huống | Nơi phát sinh | Kết quả |
|---|---|---|
| `step_type` không có executor | `StepRegistry.of` | `IllegalArgumentException` (message `UNKNOWN_STEP_TYPE + type`) |
| Hai executor cùng `type()` | `StepRegistry` constructor | `IllegalStateException`, ứng dụng dừng khởi động |
| Executor ném exception | `execute` | Bước bị đánh `ERROR`, job có thể `FAILED` tuỳ orchestrator |