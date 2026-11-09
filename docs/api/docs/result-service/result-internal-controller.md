# Tài liệu chi tiết luồng API — result-service / ResultInternalController

Nơi lưu: `docs/api/docs/result-service/result-internal-controller.md`

Mục đích: giải thích chi tiết các endpoint nội bộ của result-service dành cho course-service và ai-assistant-service (tính điểm trung bình có trọng số, lấy kết quả theo assignment/submission, tạo kết quả chấm), bao gồm input, output, luồng xử lý, ví dụ, và mã lỗi. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`ResultInternalController` là REST controller của service `result-service`, trỏ về base path `/api/v1/internal/results`. Nó cung cấp các endpoint nội bộ (không được routed qua API gateway) cho course-service và ai-assistant-service.

| Endpoint | Method | Mục đích | Gọi bởi |
|----------|--------|----------|---------|
| `/api/v1/internal/results/weighted` | POST | Tính điểm trung bình có trọng số của 1 sinh viên trên nhiều assignment | course-service (`ScoreService.computeExercise`) |
| `/api/v1/internal/results/weighted-batch` | POST | Tính điểm trung bình có trọng số cho nhiều sinh viên trên nhiều assignment (1 truy vấn DB) | course-service (`ScoreService.fetchBatchExerciseScores`) |
| `/api/v1/internal/results/assignment/{assignmentId}` | GET | Lấy kết quả chấm theo assignment, nhóm theo sinh viên (view chấm điểm của lecturer) | course-service (`AssignmentGradingService.results`) |
| `/api/v1/internal/results/submission/{submissionId}` | GET | Lấy mọi dòng kết quả của 1 submission (không kiểm tra identity) | ai-assistant-service (`AiExplanationService`) |
| `/api/v1/internal/results` | POST | Tạo 1 kết quả chấm mới (từ executor-service sau khi chấm xong) | executor-service (`GradingOrchestrator.postResult`) |

**Internal-only:** không được exposing qua API gateway. course-service là caller duy nhất của một số endpoint và đã tự xác thực quyền sở hữu assignment trước khi gọi.

Controller giao tiếp trực tiếp với `ResultService`.

---

## 2. DTO liên quan

### 2.1 `AverageRequest` (record, nội bộ)

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `assignmentIds` | `List<UUID>` | Danh sách ID bài tập |
| `studentId` | UUID | ID sinh viên |

### 2.2 `BatchAverageRequest` (record, nội bộ)

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `assignmentIds` | `List<UUID>` | Danh sách ID bài tập |
| `studentIds` | `List<UUID>` | Danh sách ID sinh viên |

### 2.3 `CreateResultRequest` (dto/request)
Yêu cầu tạo kết quả chấm (gửi từ executor-service).

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `submissionId` | UUID | ✅ | ID submission |
| `assignmentId` | UUID | ✅ | ID bài tập |
| `studentId` | UUID | ✅ | ID sinh viên |
| `planId` | UUID | — | ID plan (null = FULL scope, toàn bộ assignment) |
| `planWeight` | Integer | — | Trọng số plan |
| `score` | BigDecimal | ✅ | Điểm số |
| `maxScore` | BigDecimal | — | Điểm tối đa (mặc định 10.00) |
| `status` | String | — | `DONE`, `FAILED`, ... (mặc định DONE) |
| `summaryLog` | String | — | Tóm tắt kết quả |
| `stepResults` | `List<StepResultItem>` | — | Chi tiết từng bước |

Lớp lồng `CreateResultRequest.StepResultItem`:
| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `planId` | UUID | ID plan |
| `stepId` | UUID | ID bước |
| `stepOrder` | Integer | Thứ tự bước |
| `stepName` | String | Tên bước |
| `stepType` | String | Loại bước |
| `passed` | Boolean | Đã vượt qua hay không |
| `skipped` | Boolean | Đã bỏ qua hay không |
| `weight` | Integer | Trọng số bước |
| `score` | BigDecimal | Điểm bước |
| `actualValue` | String | Giá trị thực (đã redact) |
| `expectedValue` | String | Giá trị kỳ vọng |
| `errorMessage` | String | Thông báo lỗi |
| `durationMs` | Integer | Thời gian thực thi (ms) |
| `assertionDetails` | String | Chi tiết từng assertion |
| `extractedVars` | String | Biến đã trích xuất |
| `requestUrl` | String | URL yêu cầu (đã redact) |
| `requestBody` | String | Body yêu cầu (đã redact/cắt) |
| `responseStatus` | Integer | Mã trạng thái HTTP |
| `dbQueryCount` | Integer | Số truy vấn DB |
| `dbQueryLogs` | String | Log truy vấn DB |
| `stackTrace` | String | Stack trace (đã cắt) |
| `peakMemoryMb` | Integer | Đỉnh bộ nhớ (MB) |

### 2.4 `AssignmentResultGroupResponse` (dto/response)
Kết quả nhóm theo sinh viên.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `studentUserId` | UUID | ID sinh viên |
| `exerciseScore` | BigDecimal | Điểm bài tập (công thức weight-weighted) |
| `results` | `List<ResultResponse>` | Danh sách kết quả từng attempt |

### 2.5 `ResultResponse` (dto/response)
Một dòng kết quả chấm.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID kết quả |
| `submissionId` | UUID | ID submission |
| `assignmentId` | UUID | ID bài tập |
| `studentId` | UUID | ID sinh viên |
| `planId` | UUID | ID plan (null = FULL) |
| `planWeight` | Integer | Trọng số plan |
| `scope` | String | `FULL` / `PLAN` |
| `score` | BigDecimal | Điểm số |
| `maxScore` | BigDecimal | Điểm tối đa |
| `status` | String | Trạng thái chấm |
| `summaryLog` | String | Tóm tắt |
| `latest` | Boolean | Mới nhất hay không |
| `startedAt` / `completedAt` | OffsetDateTime | Thời gian |
| `steps` | `List<StepResultResponse>` | Chi tiết từng bước |

### 2.6 `StepResultResponse` (dto/response)
Chi tiết một bước chấm.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID kết quả bước |
| `planId` | UUID | ID plan |
| `stepId` | UUID | ID bước |
| `stepOrder` | Integer | Thứ tự |
| `stepName` | String | Tên bước |
| `stepType` | String | Loại bước |
| `passed` | Boolean | Đã vượt qua |
| `skipped` | Boolean | Đã bỏ qua |
| `weight` | Integer | Trọng số |
| `score` | BigDecimal | Điểm bước |
| `actualValue` / `expectedValue` | String | Giá trị thực/kỳ vọng |
| `errorMessage` | String | Thông báo lỗi |
| `durationMs` | Integer | Thời gian (ms) |
| `assertionDetails` / `extractedVars` | String | Chi tiết assertion / biến trích xuất |
| `requestUrl` / `requestBody` | String | URL/Body yêu cầu (đã redact) |
| `responseStatus` | Integer | Mã trạng thái HTTP |
| `dbQueryCount` / `dbQueryLogs` | Integer / String | Truy vấn DB |
| `stackTrace` | String | Stack trace (đã cắt) |
| `peakMemoryMb` | Integer | Đỉnh bộ nhớ (MB) |

---

## 3. Chi tiết từng hàm

### 3.1 `weighted` — Tính điểm trung bình có trọng số (1 sinh viên, nhiều assignment)

**Vị trí:** `ResultInternalController.weighted(...)` → `ResultService.weightedScoreByPlan(...)`

**Endpoint:** `POST /api/v1/internal/results/weighted`

**Request body:** `AverageRequest` (`assignmentIds`, `studentId`)

**Luồng xử lý:**
1. Controller gọi `resultService.weightedScoreByPlan(request.assignmentIds(), request.studentId())`.
2. Service `weightedScoreByPlan`:
   - Truy vấn `resultRepository.findByAssignmentIdInAndStudentId(assignmentIds, studentId)` → tất cả result của sinh viên trên các assignment.
   - Nếu rỗng → trả về `BigDecimal.ZERO`.
   - Truy vấn tất cả `StepResult` của các result này (`stepResultRepository.findByResultIdIn`).
   - Tính `perPlanBests` (điểm tốt nhất mỗi plan, max over attempts).
   - Lấy `coursePlanWeights(assignmentIds)` — trọng số plan từ course-service (cache 5 phút), nếu lỗi thì dùng carried weights từ rows.
   - Gọi `maxPerPlanAverage(perPlan, allPlanWeights, assignmentIds)` → tính điểm trung bình có trọng số.
   - Trả về `Map.of("average", weighted)`.
3. Controller trả về `ResponseEntity.ok(Map.of("average", weighted))`.

**Công thức:** `Σ(điểm_plan_i × trọng_số_i) / Σ(trọng_số_i)`. Plan chưa nộp → điểm 0 nhưng còn trọng số.

**Ví dụ request:**
```http
POST /api/v1/internal/results/weighted
Content-Type: application/json

{
  "assignmentIds": ["16cebadb-2485-4494-be5b-7f6641887559"],
  "studentId": "e4ab4157-8970-4169-90fb-b88d788a124c"
}
```

**Ví dụ response (200):**
```json
{ "average": "8.50" }
```

**Mã lỗi:** Không có (luôn trả về 200, lỗi course-service degrade gracefully).

---

### 3.2 `weightedBatch` — Tính điểm cho nhiều sinh viên (batch)

**Vị trí:** `ResultInternalController.weightedBatch(...)` → `ResultService.weightedScoreByPlanBatch(...)`

**Endpoint:** `POST /api/v1/internal/results/weighted-batch`

**Request body:** `BatchAverageRequest` (`assignmentIds`, `studentIds`)

**Luồng xử lý:**
1. Nếu `assignmentIds` hoặc `studentIds` null/rỗng → trả về map rỗng.
2. Truy vấn `resultRepository.findByAssignmentIdInAndStudentIdIn(assignmentIds, studentIdIn)` (1 truy vấn DB thay vì N lần).
3. Nhóm result theo `studentId`.
4. Với mỗi sinh viên:
   - Nếu không có attempt nào → điểm `0.00` (chưa nộp submission nào).
   - Ngược lại → tính `perPlanBests` và `maxPerPlanAverage`.
5. Trả về `Map<UUID, BigDecimal>` (studentId → điểm).

**Ví dụ request:**
```http
POST /api/v1/internal/results/weighted-batch
Content-Type: application/json

{
  "assignmentIds": ["16cebadb-2485-4494-be5b-7f6641887559"],
  "studentIds": ["e4ab4157-8970-4169-90fb-b88d788a124c", "another-student-id"]
}
```

**Ví dụ response (200):**
```json
{
  "e4ab4157-8970-4169-90fb-b88d788a124c": "8.50",
  "another-student-id": "0.00"
}
```

---

### 3.3 `byAssignment` — Lấy kết quả theo assignment (view chấm điểm lecturer)

**Vị trí:** `ResultInternalController.byAssignment(...)` → `ResultService.getByAssignment(...)`

**Endpoint:** `GET /api/v1/internal/results/assignment/{assignmentId}`

**Path variable:**
- `assignmentId` (UUID)

**Query params:**
| Param | Kiểu | Bắt buộc | Mặc định | Mô tả |
|-------|------|----------|----------|-------|
| `studentUserId` | UUID | — | null | Lọc 1 sinh viên; null = toàn bộ lớp |
| `includeSteps` | boolean | — | `false` | `true` để bao gồm chi tiết từng bước |

**Luồng xử lý:**
1. Controller gọi `resultService.getByAssignment(assignmentId, studentUserId, includeSteps)`.
2. Service `getByAssignment`:
   - Truy vấn `resultRepository.findByAssignmentId(assignmentId)`.
   - Lọc theo `studentUserId` nếu có.
   - Nếu rỗng → trả về danh sách rỗng.
   - Truy vấn tất cả `StepResult` của các result (1 truy vấn batched).
   - Lấy `coursePlanWeights(Set.of(assignmentId))` — trọng số plan.
   - Nhóm result theo `studentId`.
   - Với mỗi sinh viên:
     - Tính `perPlanBests`, `exerciseScore = maxPerPlanAverage(...)`.
     - Lấy `gradedRows(attempts, stepsByResult)` — các attempt có điểm được tính (best attempt per plan, không phải latest; fallback latest nếu không có scorable).
     - Map từng result sang `ResultResponse` (có steps nếu `includeSteps=true`).
   - Trả về `List<AssignmentResultGroupResponse>`.
3. Controller trả về `ResponseEntity.ok(list)`.

**Ghi chú:** Endpoint này không routed qua gateway, course-service là caller duy nhất và đã xác thực quyền sở hữu assignment trước khi gọi.

**Ví dụ request:**
```http
GET /api/v1/internal/results/assignment/16cebadb-2485-4494-be5b-7f6641887559?studentUserId=e4ab4157-8970-4169-90fb-b88d788a124c&includeSteps=true
```

**Ví dụ response (200):**
```json
[
  {
    "studentUserId": "e4ab4157-8970-4169-90fb-b88d788a124c",
    "exerciseScore": "8.50",
    "results": [
      {
        "id": "a1b2c3d4-...",
        "submissionId": "c49eb1e3-...",
        "planId": "7e31465c-...",
        "planWeight": 100,
        "scope": "PLAN",
        "score": "8.50",
        "maxScore": "10.00",
        "status": "DONE",
        "summaryLog": "Passed 5/5 steps (100%), Score: 8.50/10.00",
        "latest": true,
        "steps": [...]
      }
    ]
  }
]
```

---

### 3.4 `bySubmission` — Lấy mọi kết quả của 1 submission (identity-free)

**Vị trí:** `ResultInternalController.bySubmission(...)` → `ResultService.getBySubmissionId(...)`

**Endpoint:** `GET /api/v1/internal/results/submission/{submissionId}`

**Path variable:**
- `submissionId` (UUID)

**Luồng xử lý:**
1. Controller gọi `resultService.getBySubmissionId(submissionId)` → trả về `List<ResultResponse>` (mỗi plan một dòng, kèm step rows).
2. **Không kiểm tra identity** — caller đã tự xác thực quyền (ai-assistant-service résolution assignment và owner từ rows sau khi xác nhận lecturer sở hữu assignment).
3. Trả về `ResponseEntity.ok(list)`.

**Ghi chú:** Endpoint công khai `GET /api/v1/results/{submissionId}` giữ kiểm tra `caller == studentId` của riêng nó, sinh viên vẫn đi qua đường đó.

**Ví dụ request:**
```http
GET /api/v1/internal/results/submission/c49eb1e3-1234-5678-90ab-cdef12345678
```

**Ví dụ response (200):** `List<ResultResponse>` (giống `getBySubmission` ở ResultController).

---

### 3.5 `create` — Tạo kết quả chấm mới (từ executor-service)

**Vị trí:** `ResultInternalController.create(...)` → `ResultService.createResult(...)`

**Endpoint:** `POST /api/v1/internal/results`

**Request body:** `CreateResultRequest`

**Luồng xử lý (Controller → Service):**

1. **Controller:** Gọi `resultService.createResult(request)`. Trả về `201 CREATED` kèm `Map.of("id", resultId)`.

2. **Service `createResult` (@Transactional):**
   - **Kiểm tra bắt buộc:** `submissionId`, `assignmentId`, `studentId`, `score` phải non-null. Nếu thiếu → `IllegalArgumentException("submissionId, assignmentId, studentId and score are required")`.
   - **Xác định status:** Nếu `request.getStatus()` null → `DONE`. Ngược lại `ResultStatus.valueOf(status)`. Nếu status không xác định → `IllegalArgumentException("Unknown result status: ...")`.
   - **Xác định scope:** Nếu `planId == null` → `FULL` (toàn bộ assignment), ngược lại → `PLAN` (một plan).
   - **Demote các latest row cũ:**
     - Nếu `FULL`: tìm tất cả rows `latest=true` của cùng `(studentId, assignmentId)` → đặt `latest = false`. (Một run FULL aggregates tất cả plan, giữ row latest cũ sẽ làm double-count trong trung bình.)
     - Nếu `PLAN`: tìm tất cả rows `latest=true` của cùng `(studentId, assignmentId, planId)` → đặt `latest = false`. (Chỉ demote scope của plan này, để nguyên các plan khác.)
     - Gọi `resultRepository.saveAllAndFlush(previous)` — **flush trước khi insert** để tránh vi vieille unique index `idx_results_latest` (Hibernate flush INSERT trước UPDATE trong cùng transaction; nếu không flush, row mới `latest=true` sẽ va chạm với row cũ vẫn còn `true` → lỗi 409, executor sẽ bỏ qua report).
   - **Tạo row mới:** `Result.builder().submissionId(...).assignmentId(...).studentId(...).planId(...).scope(...).planWeight(...).score(...).maxScore(...).status(...).summaryLog(...).latest(true).completedAt(now).build()`, lưu qua `resultRepository.save(result)`.
   - **Lưu các bước:** Với mỗi `StepResultItem` trong `request.getStepResults()`:
     - Xác định `stepType` (mặc định `HTTP_REQUEST`, `StepType.valueOf(...)` nếu có). Nếu không xác định → `IllegalArgumentException("Unknown step type: ...")`.
     - Lưu `StepResult` với `resultId`, `planId`, `stepId`, `stepOrder`, `stepName`, `stepType`, `passed`, `skipped`, `weight`, `score`, `actualValue`, `expectedValue`, `errorMessage`, `durationMs`, `assertionDetails`, `extractedVars`, `requestUrl`, `requestBody`, `responseStatus`, `dbQueryCount`, `dbQueryLogs`, `stackTrace`, `peakMemoryMb`.
     - **Lưu ý (Review: 2026-10-11, phase A2):** 5 trường evidence (assertionDetails, extractedVars, requestUrl, requestBody, stackTrace) đã được executor redact trước khi gửi (trust boundary, các Maven project riêng biệt nên không thể chia sẻ class redactor).
   - Trả về `result.getId()`.

**Ví dụ request:**
```http
POST /api/v1/internal/results
Content-Type: application/json

{
  "submissionId": "c49eb1e3-1234-5678-90ab-cdef12345678",
  "assignmentId": "16cebadb-2485-4494-be5b-7f6641887559",
  "studentId": "e4ab4157-8970-4169-90fb-b88d788a124c",
  "planId": "7e31465c-2764-4848-abf3-854832c64361",
  "planWeight": 100,
  "score": "8.50",
  "maxScore": "10.00",
  "status": "DONE",
  "summaryLog": "Passed 5/5 steps (100%), Score: 8.50/10.00",
  "stepResults": [
    {
      "stepOrder": 1,
      "stepName": "POST tạo sinh viên mới",
      "stepType": "HTTP_REQUEST",
      "passed": true,
      "weight": 30,
      "score": "30.00"
    }
  ]
}
```

**Ví dụ response (201):**
```json
{ "id": "a1b2c3d4-..." }
```

**Mã lỗi:**
- `400`: thiếu trường bắt buộc, status không xác định, step type không xác định.

---

## 4. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 400 | Thiếu `submissionId`/`assignmentId`/`studentId`/`score` | `ResultService.createResult` |
| 400 | `status` không xác định | `ResultService.createResult` |
| 400 | `stepType` không xác định | `ResultService.createResult` |

---

## 5. Luồng dữ liệu từ đầu đến cuối (ví dụ executor-service đăng kết quả chấm)

```
executor-service: GradingOrchestrator.grade() (chấm xong)
   │ 1. Tính tổng điểm (ScoreCalculator), xây dựng summary
   │ 2. Gọi postResult(...) → ResultInternalController.create (POST /api/v1/internal/results)
   │    body: CreateResultRequest { submissionId, assignmentId, studentId, planId, score, stepResults: [...] }
   ▼
result-service: ResultInternalController.create()
   │ 3. Kiểm tra các trường bắt buộc
   │ 4. Xác định scope (FULL nếu planId null, ngược lại PLAN)
   │ 5. Demote các latest row cũ cùng scope (saveAllAndFlush — tránh vi vieille unique index)
   │ 6. Tạo Result row mới (latest=true, completedAt=now)
   │ 7. Lưu từng StepResult (kèm evidence đã redact)
   │ 8. Trả về resultId
   ▼
executor-service: GradingOrchestrator.postResult()
   │ 9. Gọi resultServiceClient.create(request), retry tối đa 3 lần (2s, 4s)
   │    Nếu lỗi validation 4xx (trừ 408/429) → không retry, log warn
   ▼
executor-service: patch submission status = DONE
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/result-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
