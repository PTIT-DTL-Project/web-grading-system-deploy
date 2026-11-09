# Tài liệu chi tiết luồng API — executor-service / DryRunController

Nơi lưu: `docs/api/docs/executor-service/dry-run-controller.md`

Mục đích: giải thích chi tiết endpoint dry-run grading của executor-service, bao gồm input, output, luồng xử lý, ví dụ, và mã lỗi. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`DryRunController` là REST controller của service `executor-service`, trỏ về base path `/api/v1/internal/grading`. Nó cung cấp endpoint chạy chấm thử (dry-run) toàn bộ quy trình chấm điểm (boot compose, chạy các bước) nhưng **không** đăng kết quả lên result-service và **không** cập nhật submission status. Trả về báo cáo chi tiết từng bước cho giảng viên xem trước.

| Endpoint | Method | Mục đích | Gọi bởi |
|----------|--------|----------|---------|
| `/api/v1/internal/grading/dry-run` | POST | Chạy chấm thử grading config, trả về báo cáo từng bước | course-service (`InternalAssignmentController.dryRun`) |

**Internal-only:** không được exposing qua API gateway. Chỉ course-service gọi được.

Controller giao tiếp với `GradingOrchestrator.dryRun(...)` để thực hiện.

---

## 2. DTO liên quan

### 2.1 `DryRunRequest` (dto/internal)
Yêu cầu dry-run gửi từ course-service.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `assignmentId` | UUID | ✅ | ID bài tập |
| `referenceCodeZipUrl` | String | ✅ | URL zip mã tham chiếu trên RustFS |
| `plans` | `List<InternalPlanDto>` | ✅ | Danh sách plan cần chạy dry-run |

### 2.2 `DryRunReport` (dto/internal)
Báo cáo kết quả dry-run.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `dryRunId` | UUID | ID dry-run (sinh ngẫu nhiên) |
| `steps` | `List<DryRunStepReport>` | Chi tiết từng bước |
| `summary` | String | Tóm tắt kết quả (ví dụ: "Passed 7/7 steps (100%), Score: 10.00/10.00") |

### 2.3 `DryRunStepReport` (dto/internal)
Kết quả của một bước trong dry-run.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `stepOrder` | Integer | Thứ tự bước |
| `stepName` | String | Tên bước |
| `stepType` | String | Loại bước |
| `status` | String | `PASSED` / `FAILED` / `ERROR` / `SKIPPED` |
| `durationMs` | Integer | Thời gian thực thi (ms) |
| `extractedVariables` | `Map<String, Object>` | Các biến đã trích xuất |
| `errorMessage` | String | Thông báo lỗi (nếu có) |

---

## 3. Chi tiết hàm `dryRun`

**Vị trí:** `DryRunController.dryRun(...)` → `GradingOrchestrator.dryRun(...)`

**Endpoint:** `POST /api/v1/internal/grading/dry-run`

**Request body:** `DryRunRequest`

**Luồng xử lý:**

1. **Controller:** Nhận `DryRunRequest request`. Log thông tin yêu cầu (assignmentId, số plans, referenceCodeZipUrl). Gọi `gradingOrchestrator.dryRun(request)`. Trả về `ResponseEntity.ok(DryRunReport)`.

2. **Service `GradingOrchestrator.dryRun` (Phase 6):**
   - Lấy `assignmentId`, `referenceCodeZipUrl`, `plans` từ request. Nếu `plans` null → danh sách rỗng.
   - Sắp xếp plans theo `sequenceOrder`.
   - Nếu plans rỗng → ném `IllegalArgumentException("Assignment has no test plans")`.
   - Gọi `scanDbRequirements(plans)` để xác định yêu cầu DB (engine, cổng, database). Nếu engine không xác định → ném `IllegalArgumentException`.
   - Tải artifact: `artifactService.fetchWorkDir(UUID.randomUUID(), referenceCodeZipUrl)` → thư mục làm việc tạm.
   - Claim cổng app (`portAllocator.claim()`). Nếu có DB step → claim cổng DB (`portAllocator.claimDbPort()`).
   - Gọi `DockerComposePatcher.writeEffectiveCompose(...)` với strategy `STUDENT_DOCKER_COMPOSE`, template null, cổng app, cổng container 8080, yêu cầu DB.
   - Boot compose qua `composeRunner.boot(effective, 60_000L)` → chạy container student app + DB (nếu có).
   - Gọi `dryRunSteps(plans, running.port(), dbPort, 300_000)` → chạy tất cả các bước, thu thập báo cáo.
   - Trả về `DryRunReport`.
   - **Finally:** Giải phóng cổng app và cổng DB (nếu có), xóa thư mục làm việc tạm.

3. **Phương thức `dryRunSteps`:**
   - Tạo `VariableContext` với `APP_PORT`, `DB_PORT` (nếu có), `SUBMISSION_ID="dry-run"`, `ASSIGNMENT_ID="dry-run"`, `STUDENT_ID="dry-run"`.
   - Thiết lập deadline = now + executionTimeoutMs (300s).
   - Duyệt từng plan (sắp xếp theo `stepOrder`):
     - Gọi `autoInjectExtracts(steps)` để tự động tiêm các bước extract cho biến được tham chiếu trước khi có nguồn tạo ra.
     - Duyệt từng bước trong plan:
       - Nếu quá deadline → đánh dấu timed out, dừng.
       - Nếu plan đã dừng (bước required trước đó thất bại) → đánh dấu bước này `SKIPPED`, không tính điểm.
       - Parse config JSON. Nếu lỗi → báo cáo `ERROR`, nếu required → dừng plan.
       - Tiêm các header đã tích lũy từ bước trước (`injectPlanHeaders`).
       - Lấy executor từ `stepRegistry.of(stepType)`. Nếu không tìm thấy → `FAILED`, nếu required → dừng plan.
       - Chạy bước qua `executor.execute(new StepContext(...))`. Nếu ném exception → `ERROR`.
       - Thu thập các header `auto_inject_headers` từ bước này để áp dụng cho bước sau.
       - Phân tích các biến đã trích xuất từ kết quả bước.
       - Thêm báo cáo bước vào danh sách.
       - Nếu bước thất bại/lỗi và là required → đánh dấu `planStopped = true` (các bước sau trong plan bị bỏ qua).
   - Nếu timed out → trả về báo cáo với summary "Dry-run timed out after 300000ms".
   - Tính điểm qua `ScoreCalculator.score(outcomes, BigDecimal.TEN)`.
   - Tính số bước đã chạy (ran), số bước passed, phần trăm.
   - Tạo summary: "Passed X/Y steps (Z%), Score: S.SS/10.00".
   - Trả về `DryRunReport`.

**Ví dụ request:**
```http
POST /api/v1/internal/grading/dry-run
Content-Type: application/json

{
  "assignmentId": "16cebadb-2485-4494-be5b-7f6641887559",
  "referenceCodeZipUrl": "https://rustfs.example.com/submissions/student-management-solution.zip",
  "plans": [
    {
      "id": "7e31465c-2764-4848-abf3-854832c64361",
      "name": "Câu 1: Tạo sinh viên mới",
      "sequenceOrder": 1,
      "weight": 100,
      "steps": [
        {
          "id": "15ba2249-9919-450f-82cf-3c534cf219aa",
          "stepOrder": 1,
          "name": "POST tạo sinh viên mới",
          "stepType": "HTTP_REQUEST",
          "config": "{\"method\":\"POST\",\"path\":\"/api/students\",\"body\":{...},\"expected_status\":201,...}",
          "weight": 30,
          "timeoutMs": 5000,
          "required": true
        }
      ]
    }
  ]
}
```

**Ví dụ response (200):**
```json
{
  "dryRunId": "d5b186e6-87d8-4e16-a67e-84686937bdc0",
  "steps": [
    {
      "stepOrder": 1,
      "stepName": "POST tạo sinh viên mới",
      "stepType": "HTTP_REQUEST",
      "status": "PASSED",
      "durationMs": 345,
      "extractedVariables": { "studentId": "eb66723c-...", "studentEmail": "test@example.com" },
      "errorMessage": null
    }
  ],
  "summary": "Passed 5/5 steps (100%), Score: 10.00/10.00"
}
```

**Mã lỗi:**
- `400`: `IllegalArgumentException` từ `GradingOrchestrator` (không có plan, engine DB không xác định).
- `500`: Lỗi khi boot compose, tải artifact, hoặc chạy bước (được ném lại dưới dạng `RuntimeException("Dry-run failed: ...")`).

---

## 4. Điểm khác biệt giữa dry-run và grade thực tế

| Đặc điểm | Dry-run | Grade thực tế (`grade`) |
|----------|---------|------------------------|
| Đồng bộ/bất đồng bộ | Đồng bộ, trả về report ngay | Bất đồng bộ (`@Async`), chạy nền |
| Lưu kết quả DB | Không lưu `GradingStepResult` | Lưu `GradingStepResult` |
| Đăng kết quả | Không gọi result-service | Gọi `resultServiceClient.create(...)` (retry 3 lần) |
| Cập nhật submission status | Không cập nhật | Cập nhật qua `submissionStatusClient` |
| Xóa artifacts | Xóa sau khi chạy | Xóa sau khi chạy |

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/executor-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
