# Tài liệu chi tiết luồng API — result-service / ResultController

Nơi lưu: `docs/api/docs/result-service/result-controller.md`

Mục đích: giải thích chi tiết từng hàm/controller/service trong luồng xem kết quả chấm bài của sinh viên và giảng viên (ResultController), bao gồm input, output, điều kiện tiên quyết, ví dụ request/response, và các mã lỗi có thể xảy ra. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`ResultController` là REST controller của service `result-service`, trỏ về base path `/api/v1/results`. Nó cung cấp các endpoint công khai (được routed qua API gateway) để xem kết quả chấm bài.

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/results/{submissionId}` | GET | Xem tất cả kết quả chấm của một submission (mỗi plan một dòng) | STUDENT (chủ sở hữu) hoặc LECTURER (bypass) |
| `/api/v1/results/student/assignment/{assignmentId}` | GET | Xem kết quả của chính sinh viên trên một bài tập (điểm bài tập + chi tiết từng plan) | STUDENT |

**Không có `@PreAuthorize`** — quyền kiểm soát trong controller:
- Bắt buộc header `X-User-Id` (không có → 403 "Caller identity required").
- Nếu gọi là lecturer (`ROLE_LECTURER` trong SecurityContext, được HeaderAuthenticationFilter parse từ `X-User-Roles`) → có thể xem kết quả của bất kỳ submission nào (bypass kiểm tra chủ sở hữu).
- Nếu gọi là student → chỉ được xem khi `callerId == result.getStudentId()` cho **tất cả** dòng kết quả (không có 403 "Not owner of submission").

Controller giao tiếp với `ResultService` để thực hiện logic nghiệp vụ.

---

## 2. DTO liên quan

### 2.1 `ResultResponse` (dto/response)
Một dòng kết quả chấm của một plan (hoặc toàn bộ assignment).

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID kết quả |
| `submissionId` | UUID | ID submission |
| `assignmentId` | UUID | ID bài tập |
| `studentId` | UUID | ID sinh viên |
| `planId` | UUID | ID plan (null = toàn bộ assignment / FULL scope) |
| `planWeight` | Integer | Trọng số plan |
| `scope` | String | `FULL` (toàn bộ assignment) / `PLAN` (một plan) |
| `score` | BigDecimal | Điểm số |
| `maxScore` | BigDecimal | Điểm tối đa (mặc định 10.00) |
| `status` | String | `DONE`, `FAILED`, ... |
| `summaryLog` | String | Tóm tắt kết quả chấm |
| `latest` | Boolean | Là kết quả mới nhất hay không |
| `startedAt` / `completedAt` | OffsetDateTime | Thời gian bắt đầu/kết thúc chấm |
| `steps` | `List<StepResultResponse>` | Chi tiết từng bước (nếu `includeSteps=true`) |

### 2.2 `AssignmentResultGroupResponse` (dto/response)
Kết quả nhóm theo sinh viên trên một bài tập.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `studentUserId` | UUID | ID sinh viên (JWT sub) |
| `exerciseScore` | BigDecimal | Điểm bài tập (công thức weight-weighted, max over attempts) |
| `results` | `List<ResultResponse>` | Danh sách kết quả từng attempt (chỉ các attempt có điểm được tính) |

---

## 3. Chi tiết từng hàm

### 3.1 `getBySubmission` — Xem tất cả kết quả của một submission

**Vị trí:** `ResultController.getBySubmission(...)` → `ResultService.getBySubmissionId(...)`

**Endpoint:** `GET /api/v1/results/{submissionId}`

**Path variable:**
- `submissionId` (UUID): ID submission

**Header đầu vào:**
- `X-User-Id` (String, required): ID người gọi (JWT sub). Không có hoặc trống → `403 "Caller identity required"`.

**Luồng xử lý:**
1. Controller gọi `resultService.getBySubmissionId(submissionId)` → trả về `List<ResultResponse>` (mỗi plan một dòng, kèm step rows).
2. Kiểm tra `xUserId`: nếu null hoặc blank → ném `ResponseStatusException(HttpStatus.FORBIDDEN, "Caller identity required")`.
3. Chuyển `xUserId` sang `UUID callerId`.
4. Kiểm tra quyền lecturer:
   - Đọc `SecurityContextHolder.getContext().getAuthentication().getAuthorities()`.
   - Nếu có quyền `ROLE_LECTURER` (khớp chính xác, không dùng substring match để tránh nhận nhầm `LECTURER_ASSISTANT`) → `isLecturer = true`.
5. Kiểm tra chủ sở hữu: nếu **không phải lecturer** và **không phải mọi dòng kết quả đều có `studentId == callerId`** → ném `ResponseStatusException(HttpStatus.FORBIDDEN, "Not owner of submission")`.
6. Trả về `ResponseEntity.ok(results)`.

**Ghi chú:** Danh sách rỗng khi submission đang trong hàng chờ hoặc đang chấm — caller phải poll (lặp lại gọi) cho đến khi có dòng kết quả.

**Ví dụ request:**
```http
GET /api/v1/results/c49eb1e3-1234-5678-90ab-cdef12345678
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
```

**Ví dụ response (200):**
```json
[
  {
    "id": "a1b2c3d4-...",
    "submissionId": "c49eb1e3-1234-5678-90ab-cdef12345678",
    "assignmentId": "16cebadb-2485-4494-be5b-7f6641887559",
    "studentId": "e4ab4157-8970-4169-90fb-b88d788a124c",
    "planId": "7e31465c-2764-4848-abf3-854832c64361",
    "planWeight": 100,
    "scope": "PLAN",
    "score": "8.50",
    "maxScore": "10.00",
    "status": "DONE",
    "summaryLog": "Passed 5/5 steps (100%), Score: 8.50/10.00",
    "latest": true,
    "startedAt": "2026-11-01T10:21:58.494+07:00",
    "completedAt": "2026-11-01T10:22:30.000+07:00",
    "steps": [
      {
        "stepOrder": 1,
        "stepName": "POST tạo sinh viên mới",
        "stepType": "HTTP_REQUEST",
        "passed": true,
        "skipped": false,
        "weight": 30,
        "score": "30.00",
        "errorMessage": null
      }
    ]
  }
]
```

**Mã lỗi:**
- `403`: thiếu `X-User-Id`, hoặc người gọi không phải chủ sở hữu submission và không phải lecturer.
- `404`: submission không tồn tại (trả về danh sách rỗng, không phải lỗi).

---

### 3.2 `myAssignmentResults` — Xem kết quả của chính mình trên một bài tập

**Vị trí:** `ResultController.myAssignmentResults(...)` → `ResultService.getByAssignment(...)`

**Endpoint:** `GET /api/v1/results/student/assignment/{assignmentId}`

**Path variable:**
- `assignmentId` (UUID): ID bài tập

**Header đầu vào:**
- `X-User-Id` (String, required): ID sinh viên (JWT sub). Không có hoặc trống → `403 "Caller identity required"`.

**Luồng xử lý:**
1. Kiểm tra `xUserId`: nếu null hoặc blank → ném `ResponseStatusException(HttpStatus.FORBIDDEN, "Caller identity required")`.
2. Chuyển `xUserId` sang `UUID studentId`.
3. Gọi `resultService.getByAssignment(assignmentId, studentId, true)` → trả về `List<AssignmentResultGroupResponse>` (gồm 1 nhóm vì đã lọc theo studentId).
4. Nếu danh sách rỗng (chưa có submission nào) → trả về `AssignmentResultGroupResponse` với `studentUserId = studentId`, `exerciseScore = 0.00`, `results = []`.
   - **Ghi chú (Review: 2026-10-31):** Chưa nộp bài nào → `exerciseScore = 0.00` (không phải null), vì các plan chưa nộp tính điểm 0 và còn cộng trọng số vào mẫu số.
5. Nếu có → trả về nhóm đầu tiên (`groups.get(0)`).

**Ví dụ request:**
```http
GET /api/v1/results/student/assignment/16cebadb-2485-4494-be5b-7f6641887559
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
```

**Ví dụ response (200, đã nộp):**
```json
{
  "studentUserId": "e4ab4157-8970-4169-90fb-b88d788a124c",
  "exerciseScore": "8.50",
  "results": [
    {
      "id": "a1b2c3d4-...",
      "submissionId": "c49eb1e3-1234-5678-90ab-cdef12345678",
      "planId": "7e31465c-2764-4848-abf3-854832c64361",
      "planWeight": 100,
      "scope": "PLAN",
      "score": "8.50",
      "maxScore": "10.00",
      "status": "DONE",
      "summaryLog": "Passed 5/5 steps (100%), Score: 8.50/10.00",
      "latest": true,
      "steps": []
    }
  ]
}
```

**Ví dụ response (200, chưa nộp):**
```json
{
  "studentUserId": "e4ab4157-8970-4169-90fb-b88d788a124c",
  "exerciseScore": "0.00",
  "results": []
}
```

**Mã lỗi:**
- `403`: thiếu `X-User-Id`.

---

## 4. Các hàm liên quan trong ResultService

### 4.1 `getBySubmissionId(UUID submissionId)`
- **Input:** submissionId.
- **Output:** `List<ResultResponse>`.
- **Làm gì:** Truy vấn `resultRepository.findBySubmissionId(submissionId)`, với mỗi result truy vấn `stepResultRepository.findByResultId(result.getId())`, map sang `ResultResponse` qua `toResponse(...)`.

### 4.2 `getByAssignment(UUID assignmentId, UUID studentUserId, boolean includeSteps)`
- **Input:** assignmentId, studentUserId (null = toàn bộ lớp), includeSteps.
- **Output:** `List<AssignmentResultGroupResponse>`.
- **Làm gì:** Truy vấn tất cả result của assignment, lọc theo studentId nếu có. Nhóm theo studentId. Với mỗi sinh viên:
  - Tính `perPlanBests` (điểm tốt nhất mỗi plan).
  - Tính `exerciseScore = maxPerPlanAverage(...)` (công thức weight-weighted).
  - Lấy `gradedRows(...)` (các attempt có điểm được tính — best attempt per plan, không phải latest).
  - Map từng result sang `ResultResponse` (có steps nếu `includeSteps=true`).

---

## 5. Công thức tính điểm bài tập (tóm tắt)

Điểm bài tập của một sinh viên trên một bài tập = trung bình có trọng số của điểm **tốt nhất mỗi plan** (max over every attempt, không phải latest):

- Mỗi plan có trọng số `planWeight` (từ course-service, cache 5 phút).
- Điểm mỗi plan = điểm tốt nhất trong các attempt của plan đó (chuẩn hóa về thang 10).
- Nếu plan chưa nộp → điểm 0 nhưng **vẫn cộng trọng số vào mẫu số** (Review: 2026-10-31).
- Điểm bài tập = `Σ(điểm_plan_i × trọng_số_i) / Σ(trọng_số_i)`, làm tròn 2 chữ số, `HALF_UP`.
- Nếu không có attempt nào có thể tính điểm → `null` (không phải 0).
- Nếu chưa nộp submission nào → `0.00` (mọi plan chưa nộp tính 0).

**Ví dụ:** 2 plan trọng số 50 và 50. Sinh viên nộp plan 1 đạt 10, chưa nộp plan 2 → điểm = (10×50 + 0×50) / 100 = 5.00.

---

## 6. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 403 | Thiếu header `X-User-Id` | `ResultController.getBySubmission`, `myAssignmentResults` |
| 403 | Người gọi không phải chủ sở hữu submission và không phải lecturer | `ResultController.getBySubmission` |

---

## 7. Luồng dữ liệu từ đầu đến cuối (ví dụ sinh viên xem kết quả bài tập của mình)

```
Sinh viên (FE)
   │ GET /api/v1/results/student/assignment/{assignmentId}
   │ header X-User-Id: e4ab4157-... (JWT sub)
   ▼
result-service: ResultController.myAssignmentResults()
   │ 1. Kiểm tra X-User-Id không blank (403 nếu thiếu)
   │ 2. Gọi ResultService.getByAssignment(assignmentId, studentId, true)
   ▼
ResultService.getByAssignment()
   │ 3. Truy vấn tất cả Result của assignment
   │ 4. Lọc theo studentId
   │ 5. Tính perPlanBests (điểm tốt nhất mỗi plan)
   │ 6. Tính exerciseScore = maxPerPlanAverage(...) (công thức weight-weighted)
   │ 7. Lấy gradedRows (best attempt per plan, không phải latest)
   │ 8. Map → AssignmentResultGroupResponse
   ▼
ResultController.myAssignmentResults()
   │ 9. Nếu rỗng → trả về exerciseScore = 0.00, results = []
   │ 10. Trả về ResponseEntity.ok(AssignmentResultGroupResponse)
   ▼
FE hiển thị điểm bài tập và chi tiết từng attempt
```

```
Giảng viên xem chi tiết submission:
   │ GET /api/v1/results/{submissionId}? (qua gateway)
   │ header X-User-Id: 2be57808-... (lecturer sub)
   ▼
result-service: ResultController.getBySubmission()
   │ 1. Kiểm tra X-User-Id (403 nếu thiếu)
   │ 2. Lấy danh sách ResultResponse của submission
   │ 3. Nếu không phải lecturer → kiểm tra mọi dòng có studentId == callerId (403 nếu không)
   │ 4. Nếu là lecturer → bỏ qua kiểm tra chủ sở hữu (ROLE_LECTURER bypass)
   │ 5. Trả về danh sách ResultResponse
   ▼
FE hiển thị kết quả chấm từng bước
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/result-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
