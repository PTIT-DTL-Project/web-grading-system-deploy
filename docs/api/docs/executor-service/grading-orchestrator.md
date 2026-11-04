# Tài liệu chi tiết luồng chấm điểm — executor-service / GradingOrchestrator

Nơi lưu: `docs/api/docs/executor-service/grading-orchestrator.md`

Mục đích: giải thích chi tiết `GradingOrchestrator` — dịch vụ chấm điểm chính của executor-service, bao gồm luồng end-to-end (FETCHING → BUILDING → RUNNING → DONE/FAILED), cách chạy bước (HTTP, DB), công thức tính điểm, biến thay thế, auto_inject_headers, DB sandbox, dry-run, và các mã lỗi. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`GradingOrchestrator` là `@Service` của `executor-service`, chịu trách nhiệm chạy một công việc chấm điểm (grading job) từ đầu đến cuối:

1. **FETCHING** — lấy grading config và danh sách plan từ course-service.
2. **BUILDING** — tải submission zip từ RustFS, cấp phát cổng, boot docker-compose (student app + DB nếu có).
3. **RUNNING** — chạy từng bước của từng plan (HTTP request, DB query, DB schema check, DB migration), tính điểm, ghi log.
4. **DONE / FAILED** — đăng kết quả lên result-service, cập nhật submission status.

**Single-job gate:** Một pod chỉ chạy một job tại một thời điểm (một DinD daemon, tài nguyên pod chật), nên các bản build compose song sẽ cạnh tranh. Orchestrator chạy `@Async` trên `gradingTaskExecutor`.

Controller gọi vào:
- `DryRunController.dryRun(...)` → `GradingOrchestrator.dryRun(...)` (chấm thử, không side effect).
- `ResetGradingJobController.reset(...)` → `GradingOrchestrator.gradeAsync(...)` (chạy lại sau khi reset).

---

## 2. Các thành phần chính được inject

| Thành phần | Vai trò |
|------------|---------|
| `GradingJobRepository` | Lưu/truy vấn `GradingJob` (trạng thái, lỗi, thời gian) |
| `GradingStepResultRepository` | Lưu kết quả từng bước |
| `GradingLogRepository` | Lưu log chi tiết từng giai đoạn |
| `CourseInternalClient` | Gọi course-service: `gradingConfig(assignmentId)`, `plans(assignmentId)` |
| `SubmissionStatusClient` | Cập nhật status submission (GRADING, DONE, FAILED) |
| `ResultServiceClient` | Đăng kết quả chấm (`create(result)`) |
| `ArtifactService` | Tải submission zip từ RustFS, giải nén thư mục làm việc |
| `PortAllocator` | Cấp phát cổng host cho app và DB |
| `DockerComposeRunner` | Boot docker-compose, trả về cổng app đã chạy |
| `StepRegistry` | Tra cứu `StepExecutor` theo `stepType` |
| `SagaTracker` | Theo dõi từng giai đoạn/chapter của job (saga pattern) |
| `DbDialectRegistry` | Tra cứu dialect DB theo `db_type` |
| `DbSandboxService` | Reset database sau mỗi plan (cách ly DB) |
| `ScoreCalculator` | Tính điểm theo công thức weight-weighted |
| `VariableContext` | Quản lý biến thay thế `${var}` trong quá trình chấm |
| `ExecutorProperties` | Cấu hình executor (timeout, resources) |

---

## 3. Các enum quan trọng

### 3.1 `GradingJobStatus`
| Giá trị | Ý nghĩa |
|---------|---------|
| `FETCHING` | Đang lấy config và plans |
| `BUILDING` | Đang tải artifact và boot compose |
| `RUNNING` | Đang chạy các bước |
| `DONE` | Chấm xong thành công |
| `FAILED` | Chấm thất bại (lỗi infra, config, timeout) |
| `PENDING` | Chờ chạy (sau khi reset) |

### 3.2 `StepResultStatus`
| Giá trị | Ý nghĩa |
|---------|---------|
| `PASSED` | Bước vượt qua tất cả assertion |
| `FAILED` | Bước thất bại (assertion không khớp) |
| `SKIPPED` | Bước bị bỏ qua (bước required trước đó thất bại) |
| `ERROR` | Lỗi khi chạy bước (config sai, executor không tìm thấy, exception) |

### 3.3 `SagaStatus`
| Giá trị | Ý nghĩa |
|---------|---------|
| `STARTED` | Saga bắt đầu |
| `DONE` | Saga hoàn thành |
| `FAILED` | Saga thất bại |

---

## 4. Luồng chấm điểm end-to-end (`grade`)

### Bước 0 — Nhận job
`gradeAsync(UUID jobId, UUID submissionId, UUID assignmentId, UUID studentId, UUID planId, String rustfsPath, String traceId)` được đánh dấu `@Async("gradingTaskExecutor")`. Nó gọi `grade(...)` và bắt mọi exception (log warn, không ném ra ngoài).

### Bước 1 — FETCHING: lấy config và plans
1. Truy vấn `gradingJobRepository.findById(jobId)`. Nếu null → log warn, trả về.
2. Cập nhật submission status thành `GRADING` (`patchSubmission`).
3. Đặt `job.status = FETCHING`, `startedAt = now`, lưu.
4. Ghi log `"Fetching grading config and artifact"`.
5. Bắt đầu saga: `sagaTracker.begin(job.getId())`.
6. Bước saga `FETCH_CONFIG`:
   - Gọi `courseInternalClient.gradingConfig(assignmentId)` → `AssignmentGradingConfigDto` (strategy, cổng, timeout, resources).
   - Gọi `courseInternalClient.plans(assignmentId)` → `List<InternalPlanDto>` (các plan + bước).
   - Nếu thành công → kết thúc bước saga `DONE`.
   - Nếu lỗi → kết thúc bước saga `FAILED`, gọi `fail(...)` với lý `"Failed to fetch grading config: ..."`, trả về.
7. Nếu `planId != null` → lọc plans chỉ giữ plan có id khớp.
8. Sắp xếp plans theo `sequenceOrder`.
9. Nếu plans rỗng → `fail(...)` với lý `"Assignment has no test plans"`, trả về.

### Bước 2 — Kiểm tra yêu cầu DB (engine validation)
10. Gọi `scanDbRequirements(plans)`:
    - Quét tất cả bước có loại bắt đầu bằng `DB_` (`DB_QUERY`, `DB_SCHEMA_CHECK`, `DB_MIGRATION`).
    - Đọc khối `connection` của bước DB đầu tiên: `db_service`, `db_port` (container-internal), `db_type`, `database`.
    - Nếu `db_type` không xác định (null hoặc không trong `{postgres, mysql, mariadb}`) → `dialectRegistry.resolve(dbType)` ném `IllegalArgumentException` → `fail(...)` ngay **trước khi** tải artifact và cấp cổng.
    - Nếu `db_port` cấu hình ngoài khoảng 1–65535 → dùng cổng mặc định của dialect (5432 postgres / 3306 mysql).
    - Nếu có bước DB thứ hai với kết nối khác (service/engine/cổng khác) → log warn, bỏ qua (chỉ lấy kết nối đầu tiên).
    - Trả về `DbRequirements(present, dbService, dbContainerPort, dbType, database, parseError)`.
    - **Lưu ý:** `db_port` trong config là cổng container-internal; cổng host được cấp phát riêng và.inject vào `VariableContext` dưới tên `${db_port}`.

### Bước 3 — BUILDING: tải artifact và boot compose
11. Đặt `job.status = BUILDING`, lưu.
12. Ghi log `"Downloading submission and booting app"`.
13. Bước saga `DOWNLOAD_ARTIFACT`:
    - `workDir = artifactService.fetchWorkDir(submissionId, rustfsPath)` → tải zip, giải nén thư mục làm việc.
    - Nếu lỗi → kết thúc bước saga `FAILED`, `fail(...)` với lý `"Failed to download submission: ..."`, trả về.
14. Nếu có lỗi parse DB config → log warn (không fail job).
15. Cấp cổng app: `appPort = portAllocator.claim()`.
16. Nếu có DB yêu cầu → cấp cổng DB: `dbPort = portAllocator.claimDbPort()`, ghi log cổng DB đã cấp.
17. Lấy `executionTimeoutMs` (từ config hoặc executor properties mặc định), `startupTimeoutMs`.
18. Bước saga `BOOT_COMPOSE`:
    - Gọi `DockerComposePatcher.writeEffectiveCompose(workDir, strategy, template, appPort, dockerComposePort, maxCpu, maxMemoryMb, dbService, dbPort, dbContainerPort)`:
      - Viết file `docker-compose.yml` (hoặc dùng template nếu `LECTURER_DOCKER_COMPOSE`).
      - Patch cổng app thành `{allocatedAppPort}:{containerPort}` (containerPort từ config hoặc 8080).
      - Nếu có DB → thêm cổng DB `{allocatedDbPort}:{dbContainerPort}` vào service DB.
      - Áp dụng giới hạn CPU/memory nếu có.
      - Trả về `EffectiveCompose(serviceName, containerPort, composeFile)`.
    - `composeRunner.boot(effective, startupTimeoutMs)` → khởi động container, đợi healthcheck, trả về `RunningCompose` (có `running.port()` = cổng host của app).
    - Nếu boot thành công → kết thúc bước saga `DONE`, đánh dấu `booted = true`.
    - Nếu lỗi boot → kết thúc bước saga `FAILED` (nếu chưa booted), `fail(...)` với lý `"Failed grading infra: ..."`, trả về.
19. Bước saga `RUN_STEPS`:
    - Gọi `runSteps(job, submissionId, assignmentId, studentId, planId, sagaId, plans, running.port(), dbPort, executionTimeoutMs, dbReq)`.
    - Nếu lỗi → kết thúc bước saga `FAILED`, ném lại để `fail(...)` xử lý.

### Bước 4 — FINALLY: dọn dẹp
20. Giải phóng cổng app (`portAllocator.release(appPort)`; `-1` là no-op).
21. Giải phóng cổng DB nếu có.
22. Xóa thư mục làm việc tạm (`cleanupWorkDir`).

---

## 5. Chạy các bước (`runSteps`)

### Bước 1 — Khởi tạo
1. Đặt `job.status = RUNNING`, lưu.
2. Ghi log `"Running N plans"`.
3. Tạo `VariableContext`:
   - `APP_PORT = appPort` (cổng host của student app).
   - `DB_PORT = dbPort` (nếu có DB bước).
   - `SUBMISSION_ID`, `ASSIGNMENT_ID`, `STUDENT_ID` (chuỗi UUID).
4. Thiết lập deadline = now + executionTimeoutMs.
5. Danh sách `outcomes` (điểm từng bước), `items` (chi tiết gửi result-service), cờ `timedOut`.

### Bước 2 — Duyệt từng plan
6. Duyệt từng `plan` (đã sắp xếp `sequenceOrder`):
   - Lấy danh sách bước, sắp xếp theo `stepOrder`.
   - Gọi `autoInjectExtracts(steps)` (xem mục 7).
   - Đặt `planStopped = false` (cờ dừng plan khi bước required thất bại).
   - Map `injectedHeaders` (auto_inject_headers theo plan, xem mục 8).

### Bước 3 — Duyệt từng bước trong plan
7. Với mỗi bước:
   - **Kiểm tra deadline:** nếu `now > deadline` → `timedOut = true`, thoát khỏi vòng lặp ngoài.
   - **Kiểm tra planStopped:** nếu true → gọi `skipStep(...)` (đánh dấu `SKIPPED`, không tính điểm), tiếp tục bước tiếp theo.
   - Bắt đầu bước saga (`STEP_PREFIX + stepName`).
   - **Parse config JSON:** nếu lỗi → persist `ERROR`, nếu required → `planStopped = true`, ghi log warn.
   - **Tiêm headers:** `injectPlanHeaders(config, injectedHeaders, vars)` — hợp nhất các header đã tích lũy từ bước trước vào config bước hiện tại (header đã có trên bước được ưu tiên, không bị ghi đè). Xóa khóa `auto_inject_headers` khỏi config (là orchestrator concern).
   - **Chạy bước:** `runStep(job, plan, step, effectiveConfig, vars)`:
     - Lấy executor từ `stepRegistry.of(stepType)`. Nếu không tìm thấy → persist `FAILED` với lý `"Unknown step type: ..."`.
     - Gọi `executor.execute(new StepContext(jobId, planId, stepId, stepOrder, name, config, vars, timeoutMs))`.
     - Lưu kết quả qua `stepResultRepository.save(result)`.
     - Nếu ném exception → persist `ERROR` với lý `safeMessage(e)`.
   - **Thu thập auto_inject_headers:** `harvestAutoInjectHeaders(config, injectedHeaders)` — sau khi bước chạy, lấy các header khai báo trong `auto_inject_headers` của bước này vào map plan-scoped (để bước sau dùng, ví dụ `${accessToken}` sau bước login).
   - **Xác định passed:** `result.getStatus() == PASSED`.
   - Kết thúc bước saga (`DONE` hoặc `FAILED`).
   - Thêm `outcomes` (`StepScore(passed, false, weight)`) và `items` (`StepResultItem` chi tiết).
   - **Nếu bước thất bại/lỗi và required:** `planStopped = true`, ghi log warn `"Required step failed: <stepName>"`.

### Bước 4 — DB Sandbox (cách ly DB giữa các plan)
8. Sau mỗi plan, nếu `dbReq.present()` && `dbPort != null` && `dbReq.database() != null`:
   - Lấy khối `connection` đầu tiên của plan (`findFirstDbConfig`).
   - Gọi `dbSandbox.resetDatabase(dbConfig, dbPort)` → xóa/tạo lại database để plan tiếp theo bắt đầu từ database sạch.
   - Ghi log `"DB sandbox reset after plan '<planName>'"`.

### Bước 5 — Kết thúc
9. Nếu `timedOut` → `fail(...)` với trọng số của plan hiện tại, lý `"Exceeded timeout"`, trả về.
10. Bước saga `SCORE_REPORT`.
11. Tính điểm: `ScoreCalculator.score(outcomes, BigDecimal.TEN)` (xem mục 9).
12. Xây dựng summary qua `buildSummary(outcomes, items, score)` (xem mục 10).
13. Đặt `job.status = DONE`, `completedAt = now`, lưu.
14. Ghi log summary.
15. Gọi `postResult(job, submissionId, assignmentId, studentId, planId, plans, score, summary, items, DONE)`:
    - Xây dựng `CreateResultRequest` với `submissionId`, `assignmentId`, `studentId`, `planId`, `planWeight`, `score`, `maxScore = 10`, `status`, `summaryLog`, `stepResults`.
    - Gọi `resultServiceClient.create(request)`, retry tối đa 3 lần (cách nhau 2s, 4s). Nếu lỗi validation (Feign 4xx ngoại trừ 408/429) → không retry, log warn.
16. Cập nhật submission status thành `DONE` (`patchSubmission`).
17. Kết thúc bước saga `DONE`, kết thúc saga `DONE`.

---

## 6. Tự động tiêm biến extract (`autoInjectExtracts`)

Đây là cơ chế "smart injection" để biến `${var}` được trích xuất từ bước trước có thể dùng ở bước sau, ngay cả khi bước sau không khai báo rõ ràng bước extract nguồn.

1. **Phase 1 — Xây dựng biến → bước nguồn:** Quét tất cả bước, tìm các entry trong `config.extract[]` (có `name`, `from`, `expression`). Ghi nhớ biến đầu tiên được khai báo tại bước index `src`.
2. **Phase 2 — Tiêm thông minh:** Duyệt các bước từ cuối về đầu (index `i` từ `steps.size()-1` đến 1):
   - Thu thập tất cả tham chiếu `${var}` trong config của bước `i` (qua regex `\$\{([^}]+)\}`).
   - Với mỗi biến `varName`:
     - Nếu bước nguồn `src` tồn tại và `src < i` (nguồn chạy trước bước tham chiếu) → bỏ qua (bước nguồn đã có extract rồi).
     - Ngược lại (nguồn chạy sau hoặc không có nguồn rõ ràng) → tiêm bước extract vào bước `i-1` (bước liền trước):
       - Nếu bước `i-1` chưa có entry extract với `name = varName` → thêm entry `{name: varName, from: "response_body", expression: "$.<varName>"}`.
       - Cập nhật `varSourceMap` cho biến này là bước `i-1`.
   - **Lý do:** Nếu bước S1 khai báo `extract studentId` nhưng bước S2 (chạy trước S1) lại tham chiếu `${studentId}`, thì S2 sẽ nhận chuỗi rỗng và chấm fail gây hiểu nhầm. Với smart injection, bước extract được đẩy về bước liền trước S2 để biến được tạo ra kịp thời.

---

## 7. Auto inject headers (`injectPlanHeaders` / `harvestAutoInjectHeaders`)

Cơ chế plan-scoped: các header được khai báo trong `config.auto_inject_headers` của một bước (thường là bước login trích xuất `${accessToken}`) sẽ được tiêm vào mọi bước HTTP_REQUEST sau trong cùng plan.

- **`injectPlanHeaders(config, injectedHeaders, vars)`:** Trước khi chạy bước hiện tại, hợp nhất các header đã tích lũy vào `config.headers`. Template header được thay thế biến qua `vars.substitute(template)` (ví dụ `Bearer ${accessToken}` → `Bearer abc123`). Header đã có trên bước được ưu tiên (không bị ghi đè).
- **`harvestAutoInjectHeaders(config, injectedHeaders)`:** Sau khi bước chạy, đọc `config.auto_inject_headers` (map tên header → mẫu giá trị), đưa vào `injectedHeaders` để bước sau dùng.

---

## 8. Quét yêu cầu DB (`scanDbRequirements`)

1. Quét tất cả bước của tất cả plan, tìm bước có loại bắt đầu bằng `DB_`.
2. Đọc khối `connection` của bước DB đầu tiên.
3. Giải quyết dialect qua `dialectRegistry.resolve(dbType)`:
   - Nếu `db_type` không xác định → ném `IllegalArgumentException` (fail job ngay).
   - Nếu `db_container_port` null hoặc ngoài 1–65535 → dùng cổng mặc định của dialect (5432 postgres / 3306 mysql).
4. So sánh kết nối của bước DB thứ hai với bước đầu tiên (`sameConnection`): cùng `db_service`, cùng dialect (đối tượng Spring singleton), cùng `db_container_port`. Nếu khác → log warn, bỏ qua bước thứ hai (chỉ hỗ trợ một kết nối DB per assignment).
5. Trả về `DbRequirements`.

---

## 9. Công thức tính điểm (`ScoreCalculator`)

```java
public static BigDecimal score(List<StepScore> steps, BigDecimal maxScore)
```

- `StepScore(passed, skipped, weight)`.
- `ranWeight` = tổng trọng số các bước **không bị skip**.
- `passedWeight` = tổng trọng số các bước **không bị skip và passed**.
- Nếu `ranWeight == 0` → điểm = 0.00.
- Điểm = `maxScore × passedWeight / ranWeight`, làm tròn 2 chữ số, `HALF_UP`.
- **SKIPPED** không tính vào cả hai bên (không làm kéo điểm xuống).
- Ví dụ: 3 bước trọng số 30, 25, 25. Bước 1 passed, bước 2 failed, bước 3 skipped → ranWeight = 55, passedWeight = 30 → điểm = 10 × 30/55 = 5.45.

---

## 10. Xây dựng summary (`buildSummary`)

```java
private String buildSummary(List<StepScore> outcomes, List<StepResultItem> items, BigDecimal score)
```

- `ran` = số bước không skip.
- `passed` = số bước không skip và passed.
- `pct` = `passed × 100 / ran` (làm tròn).
- Chuỗi cơ bản: `"Passed X/Y steps (Z%), Score: S.SS/10.00"`.
- Nếu có bước thất bại → thêm `". Failed: <tên bước> — <lỗi>; ..."` (tối đa các bước thất bại).

---

## 11. Dry-run (`dryRun`)

Mode chấm thử (Phase 6), đồng bộ, không side effect:
- Không lưu `GradingStepResult` vào DB.
- Không đăng kết quả lên result-service.
- Không cập nhật submission status.
- Trả về `DryRunReport` có `dryRunId`, `steps` (danh sách `DryRunStepReport` với status, durationMs, extractedVariables, errorMessage), `summary`.
- Luồng tương tự `grade` nhưng:
  - Dùng `referenceCodeZipUrl` từ request thay vì `rustfsPath` của job.
  - Strategy cố định `STUDENT_DOCKER_COMPOSE`, template null.
  - Timeout cố định 300s, startup 60s.
  - Sau khi boot compose → gọi `dryRunSteps(...)` thay vì `runSteps(...)`.
  - `dryRunSteps` không persist kết quả, không gọi result-service, không patch submission status.
  - Nếu timeout → trả về summary `"Dry-run timed out after 300000ms"`.
  - Luôn giải phóng cổng và xóa thư mục tạm trong `finally`.

---

## 12. Các phương thức hỗ trợ quan trọng

| Phương thức | Ý nghĩa |
|-------------|---------|
| `fail(job, submissionId, ..., planWeight, reason)` | Đặt job `FAILED`, ghi lỗi, kết thúc saga FAILED, đăng kết quả 0 điểm lên result-service, patch submission `FAILED`. |
| `postResult(...)` | Gọi result-service create kết quả, retry 3 lần, không retry lỗi validation 4xx. |
| `patchSubmission(submissionId, status)` | Gọi submission-service cập nhật status (GRADING/DONE/FAILED). Lỗi → log warn, không fail job. |
| `writeLog(jobId, submissionId, level, message)` | Lưu `GradingLog`. Lỗi → log warn. |
| `persist(job, plan, step, status, errorMessage)` | Lưu `GradingStepResult` với trạng thái, thời gian bắt đầu/kết thúc, thông báo lỗi. |
| `runStep(...)` | Lấy executor từ registry, chạy bước qua `StepContext`, lưu kết quả. |
| `skipStep(...)` | Đánh dấu bước `SKIPPED` khi plan đã dừng do bước required trước thất bại. |
| `truncateForStudent(body)` | Redact thông tin nhạy cảm (`EvidenceRedactor.redact`), sau đó cắt tối đa 20.000 ký tự, đánh dấu `...(truncated 20000/N)`. |
| `joinFailedVerdicts(assertionJson)` | Ghép các assertion thất bại thành một dòng đọc được, ví dụ `"status: expected 201, got 404; contains: expected ok, got err"`, tối đa 5 verdict, mỗi bên cắt 500 ký tự. |
| `cleanupWorkDir(workDir)` | Xóa đệ quy thư mục làm việc tạm. |
| `nz(value, fallback)` | Trả về giá trị nếu non-null, ngược lại fallback. |
| `safeMessage(e)` | Lấy message exception, null → `toString()`. |

---

## 13. Mã lỗi / trạng thái tóm tắt

| Trạng thái job | Ý nghĩa |
|---------------|---------|
| `FETCHING` | Đang lấy config/plans từ course-service |
| `BUILDING` | Đang tải artifact và boot docker-compose |
| `RUNNING` | Đang chạy các bước grading |
| `DONE` | Chấm xong, đã đăng kết quả |
| `FAILED` | Thất bại (lỗi infra, config, timeout, fetch) |

| Trạng thái bước | Ý nghĩa |
|----------------|---------|
| `PASSED` | Bước vượt qua tất cả assertion |
| `FAILED` | Bước thất bại (assertion không khớp hoặc unknown step type) |
| `SKIPPED` | Bước bị bỏ qua do bước required trước thất bại |
| `ERROR` | Lỗi khi chạy bước (config JSON sai, executor exception) |

| Lỗi thường gặp | Nguyên nhân |
|---------------|-------------|
| `Failed to fetch grading config: ...` | course-service không trả về config/plans |
| `Unknown db_type '...'` | `connection.db_type` không trong `{postgres, mysql, mariadb}` |
| `Failed to download submission: ...` | RustFS không tải được zip |
| `Failed grading infra: ...` | Docker compose boot thất bại |
| `Exceeded timeout` | Quá thời gian chấm (executionTimeoutMs) |
| `Unknown step type: ...` | `stepType` không có executor tương ứng |
| `Invalid step config: ...` | Config JSON không hợp lệ (qua `StepConfigValidator`) |
| `Assignment has no test plans` | Bài tập không có plan nào |

---

## 14. Luồng dữ liệu chi tiết (ví dụ chấm một bài sinh viên)

```
Kafka consumer (GRADE_SUBMISSION) → SubmissionService
   │ 1. Tạo GradingJob (status=PENDING), gửi GRADE_SUBMISSION
   ▼
executor-service: GradingOrchestrator.gradeAsync(jobId, ...)  (@Async)
   │ 2. Gọi grade(jobId, submissionId, assignmentId, studentId, planId, rustfsPath, traceId)
   ▼
GradingOrchestrator.grade()
   │ 3. FETCHING: gradingConfig(assignmentId) + plans(assignmentId) từ course-service
   │ 4. scanDbRequirements(plans) → xác định engine DB, cổng container
   │ 5. BUILDING: tải zip từ RustFS, cấp cổng app + DB, boot docker-compose
   │ 6. RUNNING: chạy từng bước của từng plan
   │    - Bước HTTP: gọi app qua http://localhost:<appPort>/api/...
   │    - Bước DB: JDBC jdbc:postgresql://localhost:<dbPort>/<database>
   │    - Tính điểm từng bước, ghi GradingStepResult, ghi GradingLog
   │    - DB sandbox reset giữa các plan
   │ 7. DONE: tính tổng điểm (ScoreCalculator), gọi result-service.create(...)
   │ 8. Patch submission status = DONE
   ▼
result-service lưu kết quả, submission-service cập nhật status
FE hiển thị điểm cho lecturer/sinh viên
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/executor-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
