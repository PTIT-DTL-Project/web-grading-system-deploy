# Tài liệu chi tiết luồng API — ai-assistant-service / AiExplanationController

Nơi lưu: `docs/api/docs/ai-assistant-service/ai-explanation-controller.md`

Mục đích: giải thích chi tiết từng hàm/controller/service trong luồng giải thích bài nộp bằng AI (AiExplanationController), bao gồm input, output, điều kiện tiên quyết, ví dụ request/response, và các mã lỗi có thể xảy ra. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`AiExplanationController` là REST controller của service `ai-assistant-service`, trỏ về base path `/api/v1/ai`. Nó cung cấp các endpoint để sinh viên và giảng viên xem/tạo giải thích AI về kết quả chấm bài của một submission.

**Quan trọng:** Các route được tách theo đối tượng người dùng (audience) thay vì chia sẻ một path với hai vai trò:
- Sinh viên (`STUDENT`): xem/tạo giải thích cho submission của chính mình.
- Giảng viên (`LECTURER`): xem/tạo giải thích cho submission trong một assignment mà mình sở hữu.

Mỗi handler đều có role gate (`@PreAuthorize`) **và** quyền kiểm tra sở hữu bên trong `AiExplanationService`. Quyền đơn lẻ không đủ — một lecturer không thể xem giải thích của submission không thuộc assignment của mình.

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/ai/submissions/{submissionId}/explain` | GET | Xem giải thích AI đã có (cache) của một submission | STUDENT (chủ sở hữu) |
| `/api/v1/ai/submissions/{submissionId}/explain` | POST | Tạo giải thích AI mới cho một submission (hoặc trả về cached) | STUDENT (chủ sở hữu) |
| `/api/v1/ai/assignments/{assignmentId}/submissions/{submissionId}/explain` | GET | Xem giải thích AI đã có (cache-only, 404 = chưa tạo hoặc không thuộc assignment của caller) | LECTURER (sở hữu assignment) |
| `/api/v1/ai/assignments/{assignmentId}/submissions/{submissionId}/explain` | POST | Tạo giải thích AI mới (hoặc trả về cached) cho submission trong assignment của caller | LECTURER (sở hữu assignment) |

Controller giao tiếp với `AiExplanationService` để thực hiện logic nghiệp vụ.

---

## 2. DTO liên quan

### 2.1 `AiExplanationResponse` (dto)
Phản hồi chứa giải thích AI của một submission.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID bản giải thích |
| `submissionId` | UUID | ID submission |
| `category` | String | Danh mục giải thích (ví dụ `FULL_ANALYSIS`) |
| `fromCache` | Boolean | Là giải thích từ cache hay tạo mới |
| `overallSummary` | String | Tóm tắt tổng thể về kết quả chấm |
| `stepAnalyses` | `List<StepAnalysis>` | Chi tiết phân tích từng bước |
| `createdAt` | OffsetDateTime | Thời điểm tạo |

Lớp lồng `StepAnalysis` (xem tài liệu `AiExplanationService` chi tiết hơn): chứa `stepId`, `stepName`, `stepType`, `passed`, `category`, `diagnosis`, `suspectedLocation`, `actionableHints`, `learningKeywords`, `telemetryAudit`.

---

## 3. Chi tiết từng hàm

### 3.1 `getExplanation` — Xem giải thích AI (sinh viên)

**Vị trí:** `AiExplanationController.getExplanation(...)` → `AiExplanationService.getExplanation(...)`

**Endpoint:** `GET /api/v1/ai/submissions/{submissionId}/explain`

**Path variable:** `submissionId` (UUID)

**Header đầu vào:**
- `X-User-Id` (String, mặc định `"00000000-0000-0000-0000-000000000000"`): ID sinh viên (JWT sub)

**Luồng xử lý:**
1. Controller nhận `submissionId` và `userId` từ header `X-User-Id`.
2. Gọi `explanationService.getExplanation(submissionId, UUID.fromString(userId))`.
3. Service `getExplanation`:
   - Truy vấn `explanationRepository.findBySubmissionIdAndCategory(submissionId, CATEGORY)`.
   - Nếu tìm thấy entity:
     - Kiểm tra `studentId.equals(entity.getStudentId())`. Nếu không khớp → ném `ResponseStatusException(HttpStatus.FORBIDDEN, "Forbidden: Not your submission")`.
     - Trả về `toResponse(entity, true)` (fromCache = true).
   - Nếu không tìm thấy → trả về `Optional.empty()`.
4. Controller: nếu có kết quả → `ResponseEntity.ok(...)`. Nếu không → `ResponseEntity.notFound().build()` (404).

**Ví dụ request:**
```http
GET /api/v1/ai/submissions/c49eb1e3-1234-5678-90ab-cdef12345678/explain
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
```

**Ví dụ response (200):**
```json
{
  "id": "a1b2c3d4-...",
  "submissionId": "c49eb1e3-1234-5678-90ab-cdef12345678",
  "category": "FULL_ANALYSIS",
  "fromCache": true,
  "overallSummary": "Bài nộp đã được phân tích toàn bộ 5 bước, tất cả đều PASSED.",
  "stepAnalyses": [
    {
      "stepId": "15ba2249-...",
      "stepName": "POST tạo sinh viên mới",
      "stepType": "HTTP_REQUEST",
      "passed": true,
      "category": "OPTIMIZE_PASS",
      "diagnosis": "Step đã vượt qua kiểm thử chức năng thành công.",
      ...
    }
  ],
  "createdAt": "2026-11-01T10:22:30.000+07:00"
}
```

**Ví dụ response (404):** Rỗng (chưa có giải thích cho submission này).

**Mã lỗi:**
- `403`: sinh viên không phải chủ sở hữu submission.
- `404`: chưa có giải thích cho submission này.

---

### 3.2 `explainSubmission` — Tạo giải thích AI mới (sinh viên)

**Vị trí:** `AiExplanationController.explainSubmission(...)` → `AiExplanationService.explainSubmission(...)`

**Endpoint:** `POST /api/v1/ai/submissions/{submissionId}/explain`

**Path variable:** `submissionId` (UUID)

**Header đầu vào:** `X-User-Id` (giảng viên/sinh viên)

**Luồng xử lý:**
1. Controller gọi `explanationService.explainSubmission(submissionId, UUID.fromString(userId))`.
2. Service `explainSubmission`:
   - **Bước 1 — Kiểm tra idempotency:** nếu đã có bản giải thích cached → trả về cached (giống `getExplanation`).
   - **Bước 2 — Lấy kết quả chấm:** gọi `fetchResultsAsStudent(submissionId, studentId)` → `List<ResultDto>`. Lấy `result = results.get(0)`. Kiểm tra `studentId.equals(result.getStudentId())` (nếu không → 403).
   - **Bước 3 — Lấy metadata assignment:** gọi `studentAssignmentMetadata(result.getAssignmentId(), studentId)` → `AssignmentDetailDto` (title, description, ...).
   - **Bước 4 — Gọi LLM:** `generate(submissionId, studentId, assignment, results)`:
     - Xây dựng system prompt và user prompt qua `PromptBuilder`.
     - Gọi `llmClient.generateEntity(systemPrompt, userPrompt, AiExplanationResultDto.class)`.
     - Nếu null (LLM lỗi/offline) → retry qua `generateStrictCompletion`. Nếu vẫn null → degrade về fallback response (không cache).
     - Nếu có structured output và không phải fallback → lưu vào `AiExplanation` repository (cache), bắt `DataIntegrityViolationException` nếu có concurrent write (unique index V2).
     - Trả về `AiExplanationResponse`.
3. Controller trả về `ResponseEntity.ok(...)`.

**Ví dụ request:**
```http
POST /api/v1/ai/submissions/c49eb1e3-1234-5678-90ab-cdef12345678/explain
X-User-Id: e4ab4157-8970-4169-90fb-b88d788a124c
```

**Ví dụ response (200):** Giống `getExplanation` nhưng `fromCache = false` (tạo mới).

**Mã lỗi:**
- `403`: không phải chủ sở hữu submission.
- `404`: không có kết quả chấm cho submission.
- `502`: result-service/course-service không khả dụng.

---

### 3.3 `getExplanationForLecturer` — Xem giải thích AI (giảng viên, cache-only)

**Vị trí:** `AiExplanationController.getExplanationForLecturer(...)` → `AiExplanationService.getExplanationForLecturer(...)`

**Endpoint:** `GET /api/v1/ai/assignments/{assignmentId}/submissions/{submissionId}/explain`

**Path variable:** `assignmentId` (UUID), `submissionId` (UUID)

**Header đầu vào:** `X-User-Id` (ID giảng viên)

**Luồng xử lý:**
1. Controller gọi `explanationService.getExplanationForLecturer(assignmentId, submissionId, UUID.fromString(lecturerId))`.
2. Service `getExplanationForLecturer`:
   - Gọi `authorizeLecturer(assignmentId, submissionId, lecturerId)` để kiểm tra giảng viên sở hữu assignment của submission (xem chi tiết tại mục 3.5).
   - Gọi `cachedExplanationFor(submissionId, target.studentId())` → tra cứu cache.
   - Nếu có cache → trả về `toResponse(entity, true)`.
   - Nếu không → trả về `Optional.empty()`.
3. Controller: nếu có → `ResponseEntity.ok(...)`. Nếu không → `ResponseEntity.notFound().build()` (404).

**Lưu ý:** Đây là **cache-only** — không gọi LLM. Trả về 404 nếu chưa có bản giải thích nào (do sinh viên tạo trước đó, hoặc lecturer tạo qua endpoint POST). 404 cũng bao gồm mọi submission nằm ngoài assignment của caller.

**Ví dụ request:**
```http
GET /api/v1/ai/assignments/16cebadb-2485-4494-be5b-7f6641887559/submissions/c49eb1e3-1234-5678-90ab-cdef12345678/explain
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):** Giống `getExplanation` (sinh viên) nhưng được gọi bởi lecturer.

**Ví dụ response (404):** Rỗng (chưa có giải thích, hoặc lecturer không sở hữu assignment).

**Mã lỗi:**
- `404`: chưa có giải thích, hoặc submission không thuộc assignment của lecturer.
- `403`: lecturer không có quyền (xử lý trước bởi `@PreAuthorize`).

---

### 3.4 `explainSubmissionForLecturer` — Tạo giải thích AI (giảng viên)

**Vị trí:** `AiExplanationController.explainSubmissionForLecturer(...)` → `AiExplanationService.explainSubmissionForLecturer(...)`

**Endpoint:** `POST /api/v1/ai/assignments/{assignmentId}/submissions/{submissionId}/explain`

**Path variable:** `assignmentId` (UUID), `submissionId` (UUID)

**Header đầu vào:** `X-User-Id` (ID giảng viên)

**Luồng xử lý:**
1. Controller gọi `explanationService.explainSubmissionForLecturer(assignmentId, submissionId, UUID.fromString(lecturerId))`.
2. Service `explainSubmissionForLecturer`:
   - Gọi `authorizeLecturer(assignmentId, submissionId, lecturerId)`.
   - Kiểm tra cache (`cachedExplanationFor`). Nếu có → trả về cached.
   - Gọi `generate(submissionId, target.studentId(), target.assignment(), target.results())` — cùng logic tạo LLM như `explainSubmission` (sinh viên).
   - Bản giải thích được lưu dưới `studentId` của submission, nên lecturer tạo sẽ warming cache mà sinh viên đọc sau.
3. Controller trả về `ResponseEntity.ok(...)`.

**Ví dụ request:**
```http
POST /api/v1/ai/assignments/16cebadb-2485-4494-be5b-7f6641887559/submissions/c49eb1e3-1234-5678-90ab-cdef12345678/explain
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):** Giống `explainSubmission` (sinh viên).

**Mã lỗi:**
- `404`: assignment/submission không tồn tại hoặc lecturer không sở hữu.
- `502`: result-service/course-service/LLM không khả dụng.

---

### 3.5 `authorizeLecturer` (private helper trong AiExplanationService)

**Input:** `assignmentId`, `submissionId`, `lecturerId`.

**Output:** `LecturerTarget(studentId, assignment, results)`.

**Luồng xử lý:**
1. Gọi `courseServiceClient.getOwnedAssignment(assignmentId, lecturerId.toString(), LECTURER_AUTHORITY, gatewayProperties.secret())`.
   - Endpoint này `@PreAuthorize("hasRole('LECTURER')")` + owner-scoped. Nếu lecturer không sở hữu assignment → course-service trả về 404.
   - Nếu `FeignException.NotFound` → ném `ResponseStatusException(HttpStatus.NOT_FOUND, "Assignment not found: " + assignmentId)` (không bao giờ là 403, để id không sở hữu không thể phân biệt với id không tồn tại).
   - Nếu `FeignException` khác → ném `ResponseStatusException(HttpStatus.BAD_GATEWAY, "Course service unavailable")`.
2. Lấy `assignment = envelope.getData()`.
3. Gọi `readGradingResults(submissionId, ...)` → `List<ResultDto>` qua result-service internal route.
   - Lấy `first = results.get(0)`. Kiểm tra `assignmentId.equals(first.getAssignmentId())` (ngăn id pair bị lộn xộn). Nếu không → 404.
4. Trả về `new LecturerTarget(first.getStudentId(), assignment, results)`.

**Quy tắc thứ tự:** Xác thực sở hữu assignment **trước** khi đọc bất kỳ dòng kết quả nào — id assignment không sở hữu không bao giờ tới result-service.

---

## 4. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 403 | Sinh viên không phải chủ sở hữu submission | `AiExplanationService.getExplanation` / `explainSubmission` |
| 404 | Chưa có giải thích (cache trống) / submission không thuộc assignment của lecturer | `AiExplanationController` (getExplanationForLecturer, explainSubmissionForLecturer) |
| 404 | Assignment không tồn tại / lecturer không sở hữu | `AiExplanationService.authorizeLecturer` (via course-service 404) |
| 502 | course-service / result-service không khả dụng | `AiExplanationService.authorizeLecturer` / `readGradingResults` |
| 401/403 | Không có quyền STUDENT/LECTURER | Spring Security (`@PreAuthorize`) |

---

## 5. Luồng dữ liệu từ đầu đến cuối (ví dụ sinh viên yêu cầu giải thích)

```
Sinh viên (FE)
   │ POST /api/v1/ai/submissions/{submissionId}/explain
   │ header X-User-Id: e4ab4157-... (JWT sub)
   ▼
ai-assistant-service: AiExplanationController.explainSubmission()
   │ 1. Chuyển userId String → UUID
   │ 2. Gọi AiExplanationService.explainSubmission(submissionId, studentId)
   ▼
AiExplanationService.explainSubmission()
   │ 3. Kiểm tra idempotency (có cache? → trả về cached)
   │ 4. fetchResultsAsStudent(submissionId, studentId) → gọi result-service (Feign)
   │ 5. Kiểm tra studentId == result.getStudentId() (403 nếu không)
   │ 6. studentAssignmentMetadata(assignmentId, studentId) → gọi course-service (Feign)
   │ 7. generate(...) → Xây dựng prompt, gọi LLM qua llmClient.generateEntity
   │    - Nếu LLM lỗi → retry qua generateStrictCompletion
   │    - Nếu vẫn lỗi → degrade về fallback response (không cache)
   │ 8. Nếu có structured output thực tế → lưu AiExplanation vào repository (cache)
   │    - Bắt DataIntegrityViolationException (concurrent write, unique index V2)
   │ 9. Trả về AiExplanationResponse
   ▼
AiExplanationController.explainSubmission()
   │ 10. Trả về ResponseEntity.ok(AiExplanationResponse)
   ▼
FE hiển thị giải thích AI (tóm tắt + chi tiết từng bước)
```

```
Giảng viên xem giải thích (cache-only):
   │ GET /api/v1/ai/assignments/{assignmentId}/submissions/{submissionId}/explain
   │ header X-User-Id: 2be57808-... (lecturer sub)
   ▼
AiExplanationController.getExplanationForLecturer()
   │ 1. Gọi AiExplanationService.getExplanationForLecturer(assignmentId, submissionId, lecturerId)
   ▼
AiExplanationService.getExplanationForLecturer()
   │ 2. authorizeLecturer(...) → gọi course-service getOwnedAssignment (404 nếu không sở hữu)
   │ 3. cachedExplanationFor(...) → tra cứu cache (chưa tạo? → 404)
   │ 4. Trả về Optional.empty() nếu chưa có
   ▼
AiExplanationController.getExplanationForLecturer()
   │ 5. Trả về 404 Not Found nếu không có cache
   ▼
FE hiển thị thông báo "chưa có giải thích" (hoặc lecturer phải tạo qua POST)
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/ai-assistant-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
