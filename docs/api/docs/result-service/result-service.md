# ResultService — lưu kết quả chấm & công thức điểm bài tập (result-service)

Đây là **nguồn duy nhất** của công thức điểm `EXERCISE` mà course-service đọc về.
Tài liệu bổ sung cho `result-controller.md` và `result-internal-controller.md`.

- Lớp: `result-service/service/ResultService.java`
- Bảng DB: `results`, `step_results` (đều soft-delete)
- Client: `CourseServicePlansClient` (Feign, đọc trọng số plan), `Tracer` (span)
- Controller dùng service này: `ResultController`, `ResultInternalController`

---

## 1. Mô hình dữ liệu

```
results (1 dòng = 1 lần chấm của 1 phạm vi)
  id, submission_id, assignment_id, student_id
  plan_id          null  = chấm cả bài (scope FULL)
                   có id = chấm 1 plan (scope PLAN)
  scope            FULL | PLAN        (suy ra từ plan_id, không nhận từ client)
  plan_weight      trọng số plan tại thời điểm chấm (dự phòng khi course-service chết)
  score, max_score (mặc định 10.00)
  status           PENDING | RUNNING | DONE | FAILED
  summary_log
  is_latest        chỉ 1 dòng latest cho mỗi (student, assignment, scope/plan)
  started_at, completed_at

step_results (1 dòng = 1 bước trong lần chấm đó)
  id, result_id, plan_id, step_id, step_order, step_name, step_type
  passed, skipped, weight, score
  actual_value, expected_value, error_message, duration_ms
  assertion_details, extracted_vars, request_url, request_body, response_status
  db_query_count, db_query_logs, stack_trace, peak_memory_mb
```

`step_results` là **bằng chứng** của điểm: từ đó result-service dựng lại điểm từng plan.

---

## 2. Bảng tổng hợp hàm

| Hàm | Input | Output | Dùng bởi |
|---|---|---|---|
| `weightedScoreByPlan(assignmentIds, studentId)` | `List<UUID>`, UUID | `BigDecimal` (0–10) hoặc `null` | course-service `computeExercise` |
| `weightedScoreByPlanBatch(assignmentIds, studentIds)` | 2 `List<UUID>` | `Map<UUID, BigDecimal>` | course-service `transcript` |
| `getByAssignment(assignmentId, studentUserId, includeSteps)` | UUID, UUID (nullable), boolean | `List<AssignmentResultGroupResponse>` | course-service `results()` |
| `getBySubmissionId(submissionId)` | UUID | `List<ResultResponse>` | FE poll kết quả 1 bài nộp |
| `createResult(CreateResultRequest)` | DTO | UUID (id mới) | executor-service (internal) |

Private: `maxPerPlanAverage`, `perPlanBests`, `higher`, `gradedRows`, `normalized`, `planSubtotals`,
`stepsByResultIds`, `coursePlanWeights`, `toResponse`, `toStepResponse`; record `PlanKey`, `PlanBest`,
`PlanBests`, `CachedPlans`.

---

## 3. Công thức điểm (phần quan trọng nhất)

### 3.1 Hai tầng

```
TẦNG 1 — trong một bài tập:
    score_assignment = Σ(score_plan × weight_plan) / Σ(weight_plan)
    (plan chưa nộp = 0 điểm nhưng VẪN cộng weight vào mẫu số)

TẦNG 2 — giữa các bài tập:
    exercise = Σ(score_assignment) / số_bài_đã_tính
    (mỗi bài một phiếu, không phụ thuộc số plan/weight của bài đó)
```

Điểm của một plan lấy từ **lần chấm tốt nhất** (max), không phải lần mới nhất.
Nhờ vậy sinh viên nộp lại một file lỗi không làm mất điểm cao trước đó.

### 3.2 Ví dụ số

Tầng 1 — bài có 4 plan, weight `100/100/100/10`, điểm tốt nhất `10/10/9/(chưa nộp)`:

```
(10×100 + 10×100 + 9×100 + 0×10) / 310 = 2900/310 = 9.354839
```

Tầng 2 — bài A = `7.25`, bài B = `10.00`:

```
(7.25 + 10.00) / 2 = 8.625 → 8.63
```

Nếu cộng trực tiếp mọi plan của mọi bài (cách cũ) thì bài 4 plan weight 100 sẽ nặng gấp 40 lần bài
1 plan weight 10 — vì vậy mới phải tách hai tầng.

### 3.3 Quy tắc làm tròn

| Bước | Scale | Ghi chú |
|---|---|---|
| `normalized(score, maxScore)` | 4 | quy đổi điểm plan về thang 10 |
| `planSubtotals` (từ step) | 4 | `10 × passedWeight / ranWeight` |
| tầng 1 (trong bài) | 6 | **chưa** làm tròn hiển thị |
| tầng 2 (kết quả cuối) | 2, `HALF_UP` | làm tròn **một lần** ở đây |

Ví dụ vì sao không làm tròn sớm: 3 plan `10/10/9` → `9.666667`; nếu làm tròn thành `9.67` rồi mới
trung bình với bài `10.00` sẽ ra `9.84`, trong khi đúng phải là `9.83`.

### 3.4 Plan "chưa nộp" và plan "không chấm được"

| Tình huống | Điểm plan | Vào mẫu số? |
|---|---|---|
| Có result `PLAN` với `score/maxScore` hợp lệ | theo điểm chuẩn hoá | có |
| Không có result nào cho plan đó | `0` | **có** (weight vẫn cộng) |
| Chỉ có 1 lần `FAILED` scope `FULL` (executor không post step) | — | **không** (không có gì để quy cho plan) |
| Plan có step nhưng tổng weight = 0 | bị bỏ qua | không |

Vì vậy: sinh viên chưa nộp bài nào = `0.00`; còn sinh viên chỉ có một lần chấm `FAILED` không step =
`null` (chưa xác định).

### 3.5 Cách tính điểm 1 plan từ `step_results` (`planSubtotals`)

```
ran(plan)    = Σ weight của mọi step có planId        // step SKIPPED vẫn tính vào ran
passed(plan) = Σ weight của step có passed=true và skipped=false
score(plan)  = 10 × passed / ran                      // scale 4; ran = 0 → bỏ qua
```

Khác với `ScoreCalculator` của executor (bỏ step skipped khỏi cả tử và mẫu): ở đây **step bị skip vẫn
kéo điểm plan xuống** vì nó đã được "chạy" nhưng không đạt.

---

## 4. Chi tiết từng hàm

### 4.1 `weightedScoreByPlan(List<UUID> assignmentIds, UUID studentId)`

```
rows = results.findByAssignmentIdInAndStudentId(assignmentIds, studentId)
rows rỗng                        → BigDecimal.ZERO           (chưa nộp gì = 0.00)
stepsByResult = stepsByResultIds(rows)                        (1 query cho mọi result)
perPlan       = perPlanBests(rows, stepsByResult)
planWeights   = coursePlanWeights(assignmentIds)              (Feign + cache 5')
return maxPerPlanAverage(perPlan, planWeights, assignmentIds) // có thể null
```

### 4.2 `weightedScoreByPlanBatch(List<UUID> assignmentIds, List<UUID> studentIds)`

- Input rỗng (một trong hai) → `Map.of()`.
- 1 query `findByAssignmentIdInAndStudentIdIn` cho tất cả sinh viên.
- Gom `rows` theo `studentId`; sinh viên **không có dòng nào** → `0.00`.
- Mỗi sinh viên còn lại: `perPlanBests` + `maxPerPlanAverage` (dùng chung `planWeights` đã cache).

Output: `LinkedHashMap<studentId, điểm>` — **có thể chứa value `null`** cho sinh viên chỉ có lần chấm
`FAILED` không step (xem §7).

### 4.3 `maxPerPlanAverage(perPlan, allPlanWeights, assignmentIds)` — hàm lõi

```
if perPlan.best rỗng                       → null            (không có attempt nào chấm được)

plansByAssignment = {}
for assignmentId in assignmentIds:
    nếu allPlanWeights có assignment đó → đưa toàn bộ plan + weight thật vào
for key in perPlan.best:
    putIfAbsent(key.planId, carried weight hoặc 1)             (chỉ khi course-service không trả)

for (assignment, plans) in plansByAssignment:
    weightedSum = Σ(score_plan × weight_plan)                  (thiếu → score = 0)
    weightTotal = Σ(weight_plan)
    nếu weightTotal == 0 → bỏ qua bài này
    assignmentSum += weightedSum / weightTotal   (scale 6)
    scoredAssignments++

nếu scoredAssignments == 0 → null
return assignmentSum / scoredAssignments         (scale 2, HALF_UP)
```

Ghi chú: `putIfAbsent` nghĩa là **weight thật từ course-service luôn thắng** weight lưu trên row.

### 4.4 `perPlanBests(rows, stepsByResult)`

| Loại row | Cách lấy điểm plan |
|---|---|
| `scope = PLAN` và `planId != null` | `normalized(score, maxScore)`; bỏ qua nếu null |
| `scope = FULL` (hoặc dữ liệu cũ) | `planSubtotals(steps của row)` → mỗi plan một điểm |

Mỗi `(assignmentId, planId)` giữ **điểm cao nhất**; hoà thì **lần sớm hơn thắng**.
`carried` lưu weight đọc từ row (`planWeight`, mặc định `1`) để dùng khi course-service không trả.

### 4.5 `gradedRows(attempts, stepsByResult)` — chọn dòng để hiển thị

1. Lấy tập `resultId` của các best row trong `perPlanBests`.
2. Trả các row trong tập đó (**đúng bằng chứng của điểm**).
3. Nếu tập rỗng (ví dụ chỉ có `FAILED` FULL) → trả các row `latest = true` để màn chi tiết không trống.

Nhờ vậy màn chi tiết không bao giờ hiện "điểm 10 nhưng dòng bên dưới là 5" (lỗi đã sửa 2026-10-17).

### 4.6 `normalized(score, maxScore)`

```
null nếu score null / maxScore null / maxScore == 0
ngược lại: score × 10 / maxScore, scale 4 HALF_UP
```

Không bao giờ ném exception (dữ liệu rác chỉ cho ra `null`).

### 4.7 `stepsByResultIds(rows)`

1 query `findByResultIdIn(ids)` rồi `groupingBy(StepResult::getResultId)` — tránh N+1.

### 4.8 `coursePlanWeights(Set<UUID> assignmentIds)`

| Bước | Chi tiết |
|---|---|
| cache | `ConcurrentHashMap<assignmentId, CachedPlans>`; TTL **5 phút** |
| cache hit | dùng luôn, không gọi Feign |
| cache miss | `plansClient.plans(assignmentId)` → `Map<planId, weight>` (weight null → 1) |
| lỗi Feign | log warn, **không cache**, trả về không có assignment đó → `maxPerPlanAverage` dùng carried weight |

Lỗi không được cache để hệ thống tự phục hồi ngay khi course-service sống lại.

### 4.9 `getByAssignment(UUID assignmentId, UUID studentUserId, boolean includeSteps)`

`@Transactional(readOnly = true)`.

```
rows = results.findByAssignmentId(assignmentId)
nếu studentUserId != null: lọc rows theo studentId
rows rỗng → List.of()
stepsByResult  = stepsByResultIds(rows)
planWeights    = coursePlanWeights({assignmentId})
gom theo studentId
mỗi sinh viên:
    perPlan       = perPlanBests(attempts, stepsByResult)
    exerciseScore = maxPerPlanAverage(perPlan, planWeights, {assignmentId})
    results       = gradedRows(attempts, stepsByResult) → toResponse(row,
                        includeSteps ? steps của row : null)
```

Output: `List<AssignmentResultGroupResponse>` — mỗi phần tử `{studentUserId, exerciseScore, results[]}`.
`steps` = `null` khi `includeSteps = false` (khác với "không có step").

### 4.10 `getBySubmissionId(UUID submissionId)`

`findBySubmissionId` → mỗi row map `toResponse(result, steps của row)` — **luôn kèm steps**.
Đây là endpoint FE poll sau khi nộp bài: rỗng = chưa chấm xong.

### 4.11 `createResult(CreateResultRequest)` — executor gọi

#### Validate

| Điều kiện | Lỗi (400) |
|---|---|
| thiếu `submissionId` / `assignmentId` / `studentId` / `score` | `submissionId, assignmentId, studentId and score are required` |
| `status` không thuộc `ResultStatus` | `Unknown result status: {status}` |
| `stepResults[].stepType` không thuộc `StepType` | `Unknown step type: {type}` |

`status` null → `DONE`. `scope` **suy ra**: `planId == null ? FULL : PLAN` (client không gửi scope).

#### Hạ `latest` của lần chấm trước

| Scope mới | Dòng bị hạ |
|---|---|
| `FULL` | **mọi** row `latest = true` của `(studentId, assignmentId)` — vì 1 dòng FULL đã gộp cả bài, giữ thêm row PLAN sẽ bị tính hai lần |
| `PLAN` | chỉ row `latest = true` của đúng `(studentId, assignmentId, planId)` |

Sau khi set `latest = false`, gọi **`saveAllAndFlush`** trước khi insert. Lý do: Hibernate flush INSERT
trước UPDATE trong cùng transaction, nên nếu không flush sớm, row mới `latest = true` sẽ đụng unique
index `idx_results_latest` khi row cũ vẫn còn `true` → 409, và executor âm thầm mất báo cáo
(Review 2026-10-12, phát hiện bằng Postman).

#### Insert

| Trường `Result` | Giá trị |
|---|---|
| `submissionId`, `assignmentId`, `studentId`, `planId` | từ request |
| `scope` | suy ra như trên |
| `planWeight` | request |
| `score` | request |
| `maxScore` | request, null → `10.00` |
| `status` | request hoặc `DONE` |
| `summaryLog` | request |
| `latest` | `true` |
| `completedAt` | `now` |

#### Insert `step_results`

Với từng `StepResultItem`: `stepType` null → `HTTP_REQUEST`; `passed`/`skipped` null → `false`;
`weight` null → `1`; `score` null → `0`; các trường bằng chứng (assertion, request/response, DB log,
stack trace, memory) copy nguyên văn — **executor đã redact trước khi gửi**.

Trả về `id` của `Result` vừa tạo.

### 4.12 Hành vi ở tầng controller bọc quanh service (quan trọng khi làm báo cáo)

`ResultController` không chỉ gọi service — nó còn kiểm soát **ai được xem gì**:

| Endpoint | Kiểm tra | Hành vi |
|---|---|---|
| `GET /api/v1/results/{submissionId}` | thiếu `X-User-Id` | 403 `Caller identity required` |
| | là `ROLE_LECTURER` (so khớp **chính xác**, không phải contains) | được xem mọi submission (deep-link từ màn chấm) |
| | là sinh viên, không sở hữu submission | 403 `Not owner of submission` |
| | là sinh viên, sở hữu | trả kết quả **đã lọc** (xem bảng dưới) |
| `GET /api/v1/results/student/assignment/{assignmentId}` | thiếu `X-User-Id` | 403 |
| | không có kết quả | trả group rỗng với `exerciseScore = 0`, `results = []` |
| | có kết quả | group của chính caller, đã lọc |

Bộ lọc cho sinh viên (`stripSensitiveStepDetails`) — giữ lại để sinh viên biết phải gọi gì:

| Giữ | Bỏ |
|---|---|
| `id`, `stepId`, `stepOrder`, `stepName`, `stepType`, `planId` | `assertionDetails` (lộ đáp án) |
| `requestUrl`, `requestBody` | `expectedValue`, `actualValue` |
| `score`, `passed`, `skipped`, `weight`, `durationMs`, `responseStatus` | `errorMessage`, `stackTrace` |
| ở mức result: `id`, `submissionId`, `assignmentId`, `studentId`, `planId`, `planWeight`, `scope`, `score`, `maxScore`, `status`, `latest`, `startedAt`, `completedAt` | `summaryLog` (có thể chứa expected value / chi tiết lỗi) |

Giảng viên nhận payload đầy đủ (không lọc) — đây là lý do màn chấm của giảng viên thấy được
assertion details còn sinh viên thì không.

---

## 5. Map DTO ↔ entity

### 5.1 `CreateResultRequest` → `Result`

| Request | Entity | Quy tắc |
|---|---|---|
| `submissionId` | `submissionId` | bắt buộc |
| `assignmentId` | `assignmentId` | bắt buộc |
| `studentId` | `studentId` | bắt buộc |
| `planId` | `planId` | |
| — | `scope` | `planId == null ? FULL : PLAN` |
| `planWeight` | `planWeight` | |
| `score` | `score` | bắt buộc |
| `maxScore` | `maxScore` | null → `10.00` |
| `status` | `status` | null → `DONE` |
| `summaryLog` | `summaryLog` | |
| — | `latest` | `true` |
| — | `completedAt` | `now()` |

### 5.2 `CreateResultRequest.StepResultItem` → `StepResult`

| Item | Entity | Quy tắc |
|---|---|---|
| `planId`, `stepId`, `stepOrder`, `stepName` | cùng tên | |
| `stepType` | `stepType` | null → `HTTP_REQUEST` |
| `passed`, `skipped` | `passed`, `skipped` | null → `false` |
| `weight` | `weight` | null → `1` |
| `score` | `score` | null → `0` |
| `actualValue`, `expectedValue`, `errorMessage`, `durationMs` | cùng tên | |
| `assertionDetails`, `extractedVars`, `requestUrl`, `requestBody`, `responseStatus`, `dbQueryCount`, `dbQueryLogs`, `stackTrace`, `peakMemoryMb` | cùng tên | bằng chứng đã redact |
| — | `resultId` | id của `Result` vừa insert |

### 5.3 `Result` → `ResultResponse` (map thủ công, `toResponse`)

| Entity | DTO | Ghi chú |
|---|---|---|
| `id`, `submissionId`, `assignmentId`, `studentId`, `planId`, `planWeight` | cùng tên | |
| `scope` (enum) | `scope` (String) | `.name()`; null giữ null |
| `score`, `maxScore` | cùng tên | |
| `status` (enum) | `status` (String) | `.name()` |
| `summaryLog`, `latest`, `startedAt`, `completedAt` | cùng tên | |
| (steps) | `steps` | `null` = "không yêu cầu", `[]` = "không có step" |

### 5.4 `StepResult` → `StepResultResponse` (`toStepResponse`)

| Entity | DTO |
|---|---|
| `id`, `planId`, `stepId`, `stepOrder`, `stepName` | cùng tên |
| `stepType` (enum) | `stepType` (String) |
| `passed`, `skipped`, `weight`, `score` | cùng tên |
| `actualValue`, `expectedValue`, `errorMessage`, `durationMs` | cùng tên |
| `assertionDetails`, `extractedVars`, `requestUrl`, `requestBody`, `responseStatus`, `dbQueryCount`, `dbQueryLogs`, `stackTrace`, `peakMemoryMb` | cùng tên |

### 5.5 Nhóm cho màn giảng viên (`AssignmentResultGroupResponse`)

| Trường | Nguồn |
|---|---|
| `studentUserId` | key của nhóm `studentId` |
| `exerciseScore` | `maxPerPlanAverage(...)` — cùng công thức với `weightedScoreByPlan` |
| `results` | `gradedRows(...)` map qua `toResponse` |

## 6. Bảng lỗi

| HTTP | Hàm | Thông điệp |
|---|---|---|
| 400 | `createResult` | `submissionId, assignmentId, studentId and score are required` |
| 400 | `createResult` | `Unknown result status: {status}` |
| 400 | `createResult` | `Unknown step type: {type}` |
| 400 | bean validation | `Validation failed` + `errors[]` |
| 409 | `createResult` | `Resource already exists or violates a constraint` (đụng unique index `latest`) |
| 403 | `getBySubmissionId` | sinh viên đọc bài nộp của người khác (kiểm tra ở controller) |
| 404 | `ResultController` | không có kết quả / không thuộc quyền |

---

## 7. Ma trận "null hay 0" (góc nhìn result-service)

| Input | `weightedScoreByPlan` | `weightedScoreByPlanBatch` |
|---|---|---|
| Không có row nào | `0` (BigDecimal.ZERO) | `0` cho sinh viên đó |
| Có row nhưng mọi plan không chấm được (FAILED FULL, không step) | `null` | `null` trong map |
| Có plan chấm được, plan khác chưa nộp | trung bình có plan chưa nộp = 0 | giống |
| `assignmentIds` rỗng | `0` (rows rỗng) | `Map.of()` |
| course-service chết | vẫn tính, dùng `planWeight` lưu trên row | giống |

Điểm khác biệt cuối bảng là lý do course-service phải xử lý `null` riêng cho từng đường đọc
(`computeExercise` map null → 0; batch thì không) — xem `score-service.md` §8.

---

## 8. Luồng dữ liệu

```
executor-service (sau mỗi plan / cả bài)
  POST /api/v1/internal/results
    { submissionId, assignmentId, studentId, planId?, planWeight?, score, maxScore?,
      status?, summaryLog?, stepResults:[{planId, stepId, stepOrder, stepName, stepType,
      passed, skipped, weight, score, actualValue, expectedValue, …}] }
      → ResultInternalController.create
      → ResultService.createResult
          ├── validate bắt buộc
          ├── scope = planId == null ? FULL : PLAN
          ├── hạ latest của scope tương ứng + saveAllAndFlush
          ├── insert results (latest=true)
          └── insert step_results (bằng chứng)
      ← 201 { id }

course-service (khi tính điểm EXERCISE)
  POST /api/v1/internal/results/weighted        { assignmentIds, studentId }
      → weightedScoreByPlan
      ← { "average": 7.25 }                    (hoặc null)

  POST /api/v1/internal/results/weighted-batch  { assignmentIds, studentIds }
      → weightedScoreByPlanBatch
      ← { "<studentUuid>": 7.25, ... }

course-service (màn chấm của giảng viên)
  GET /api/v1/internal/results/assignment/{assignmentId}?studentUserId=&includeSteps=
      → getByAssignment
      ← [{ studentUserId, exerciseScore, results:[{…, steps?:[…]}] }]

FE (poll sau khi nộp)
  GET /api/v1/results/{submissionId}
      → getBySubmissionId
      ← [{ id, planId, scope, score, maxScore, status, summaryLog, latest, steps:[…] }]
```
