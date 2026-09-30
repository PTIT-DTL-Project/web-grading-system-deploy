# Plan: Tách API kết quả theo vai trò + gỡ LECTURER bypass không scope

> **Date:** 2026-09-30 · **Status:** planned, not started · **Repo:** `web-grading-system-deploy`
> **Scope:** `src-services/{result,submission,course}-service` + docs + skills
> **Depends on:** slice 1 (X-Gateway-Secret trust boundary, uncommitted) + slice 2 (role enforcement, uncommitted)
> **Origin:** user review of slice 2 — *"giảng viên không nên xem kết quả sinh viên qua API của sinh viên; cần API riêng cho giảng viên xem cả lớp và từng sinh viên"*

---

## 1. Decisions locked with the user (2026-09-30)

| # | Topic | Decision |
|---|---|---|
| D1 | Route "xem kết quả của giảng viên" đặt ở đâu | **course-service** — dùng lại `assignmentRepository.findByIdAndOwnerId` + `ResultServiceClient` (Feign đã có). Chỉ 1 nơi quyết định ownership; không thêm Feign ở service dữ liệu |
| D2 | 2 route submission bị bypass | **Xử lý luôn trong cùng slice** — gỡ bypass, giảng viên xem qua route riêng owner-scoped |
| D3 | Role bypass trong service dữ liệu | **Gỡ toàn bộ** `hasRole("LECTURER")` khỏi `ResultController` và `SubmissionController`. result/submission-service không còn biết tới role giảng viên |
| D4 | Route public `GET /api/v1/submissions/assignment/{id}` | **Chuyển thành internal** (`/api/v1/internal/submissions/...`), giảng viên đi qua route course-service |

**Rejected alternatives:**
- *Route giảng viên ở result-service* → phải thêm Feign mới ở result-service (hiện **không** khai báo `@FeignClient` nào, chỉ có `@EnableFeignClients`), và ownership check sẽ bị nhân ra nhiều service → dễ lệch.
- *Giữ bypass nhưng thêm class-scope ngay trong controller* → kiểm soát sở hữu lớp nằm rải rác ở 3 service.
- *Thêm `hasRole("STUDENT")` cho endpoint sinh viên* → row-level (enrollment/ownership) đã mạnh hơn; fail-closed khi realm Keycloak chưa có role `STUDENT`; ở direct mode caller tự gửi được header → không tăng an ninh.

---

## 2. Hiện trạng (evidence)

### 2.1 result-service có **đúng một** endpoint công khai

```
GET /api/v1/results/{submissionId}        ResultController.java:25,31
```

Trả `List<ResultResponse>` — mỗi row = một plan đã chấm (`planId`, `planWeight`, `score`, `maxScore`, `status`, `summaryLog`, `latest`, `steps[]`).

Hai vai trò dùng chung **một route**, phân nhánh trong method:

```java
if (!SecurityUtils.hasRole("LECTURER") && xUserId != null && !results.isEmpty()) { ... 403 }
```

Internal (`permitAll`, không qua gateway): `POST /api/v1/internal/results` (executor ghi),
`POST /api/v1/internal/results/weighted` (course-service tính điểm EXERCISE — `ScoreService.java:190`).

### 2.2 View cả lớp / từng sinh viên **đã có** — nhưng ở course-service

| Endpoint | Nội dung | Trạng thái |
|---|---|---|
| `GET /api/v1/classes/{id}/transcript` | `studentCode, studentName, entries[], total, letterGrade, gpa` | đã gated `LECTURER`, owner-scoped (`transcript(id, ownerId)`) |
| `GET /api/v1/classes/{id}/students/{code}/scores` | điểm 1 sinh viên | đã gated `LECTURER`, owner-scoped |
| `GET /api/v1/classes/{id}/score-components` | khung điểm | đã gated `LECTURER` |

→ **Chưa có** view chi tiết kết quả auto-grading (step nào pass/fail, `summaryLog`, status) cho giảng viên.
→ **FE chưa có màn nào gọi results**: `frontend-src/web-grading-system-fe/src/shared/types/score.ts` chỉ khai báo `TranscriptEntryResponse` / `StudentScoresResponse`. Màn xem kết quả chi tiết chưa dựng → **sửa lúc này là rẻ, không phá contract đang dùng thật.**

### 2.3 Vấn đề

**(a) LECTURER bypass không có scope theo lớp — nghiêm trọng nhất.**
`hasRole("LECTURER")` cho phép mọi giảng viên đọc kết quả / danh sách nộp bài của **mọi lớp**.
- `ResultController.getBySubmission` — bypass không kiểm tra assignment thuộc lớp nào
- `SubmissionController.java:94` `listByAssignment` — `@PreAuthorize` **không kèm owner check**
- `SubmissionController.java:85` `getById` — bypass không scope

Đối lập với course-service, nơi **mọi** route đều scope bằng ownerId: `findByIdAndOwnerId`,
`listMine(ownerId)`, `transcript(id, ownerId)`, `listPlans(assignmentId, ownerId)`.

**(b) Một route, hai vai trò, phân nhánh bằng `if`.** Khó audit, khó test, FE phải biết role
mới biết route nào gọi, đổi chính sách là phải sửa ở service dữ liệu.

**(c) Thiếu API thật sự cho giảng viên** — chưa có endpoint nào trả `ResultResponse[]`
theo assignment/lớp. Đây là **thêm mới**, không chỉ tách route.

---

## 3. Thiết kế API cuối cùng

### 3.1 Sinh viên — strict ownership, không bypass

```
GET    /api/v1/results/{submissionId}      ✂ bỏ nhánh LECTURER → 403 nếu không phải mình
GET    /api/v1/submissions                 (my) giữ nguyên
GET    /api/v1/submissions/{id}            ✂ bỏ nhánh LECTURER → 404 nếu không phải mình
GET    /api/v1/student/assignments/*       giữ nguyên (enrollment → 404)
POST   /api/v1/submissions/presigned-url   giữ nguyên (gap enrollment → backlog)
```

### 3.2 Giảng viên — mới, đều ở course-service, đều owner-scoped

```
GET /api/v1/assignments/{assignmentId}/results?studentCode=&includeSteps=true
    @PreAuthorize("hasRole('LECTURER')")
    + assignmentRepository.findByIdAndOwnerId(assignmentId, ownerId)  → 404 nếu không phải lớp mình
    → 200: kết quả auto-grading group theo sinh viên

GET /api/v1/assignments/{assignmentId}/submissions
    @PreAuthorize("hasRole('LECTURER')")
    + findByIdAndOwnerId                                           → 404 nếu không phải lớp mình
    → 200: danh sách nộp bài của assignment (thay route cũ)
```

- **"Cả lớp"** = không truyền `studentCode` · **"Từng sinh viên"** = `?studentCode=SV0001`
- **Bảng điểm tổng hợp cả lớp đã có** ở `GET /api/v1/classes/{id}/transcript` → không trùng.
  Hai view bổ sung nhau: transcript = tổng hợp điểm, endpoint mới = chi tiết từng submission/step.

### 3.3 Internal endpoints mới (`permitAll`, không qua gateway)

```
result-service    GET /api/v1/internal/results/assignment/{assignmentId}?studentUserId=&includeSteps=
                  → [{ studentUserId, exerciseScore,
                       results: [{ planId, planWeight, score, maxScore, status, summaryLog,
                                   latest, submissionId, startedAt, completedAt, steps[] }]}]
                  (field is `results`, not `plans` — same record type binds the Feign payload
                   and the FE response in course-service, no duplicated DTO)
                  exerciseScore tính bằng ĐÚNG formula `weightedScoreByPlan` đang có
                  (không được nhân bản công thức bên course-service)

submission-service GET /api/v1/internal/submissions/assignment/{assignmentId}
                  → List<SubmissionResponse>   (dùng lại SubmissionService.listByAssignment, :133)
```

### 3.4 Route bị gỡ

```
✗  GET /api/v1/submissions/assignment/{assignmentId}   (public) → chuyển thành internal (3.3)
```

Gateway **không** có catch-all — chỉ 3 route `Path=` explicit
(`/api/v1/classes/**,/api/v1/assignments/**,/api/v1/docker-images/**,/api/v1/student/**`,
`/api/v1/submissions/**`, `/api/v1/results/**` — `api-gateway/.../application.yaml:18-28`),
nên `/api/v1/internal/**` không lộ ra ngoài (đã kiểm chứng).

---

## 4. Thay đổi theo từng service

### 4.1 result-service

| File | Thay đổi |
|---|---|
| `controller/ResultController.java:39-45` | **Xoá** nhánh `!SecurityUtils.hasRole("LECTURER")` → còn lại check thuần ownership |
| `controller/ResultInternalController.java` | Thêm `@GetMapping("/assignment/{assignmentId}")` |
| `service/ResultService.java` | Thêm `getByAssignment(assignmentId, studentUserId, includeSteps)` |
| `repository/ResultRepository.java` | Thêm finder theo `assignmentId` + `latestTrue` — **hiện chưa có** (chỉ có `findBySubmissionId`, `findByAssignmentIdInAndStudentIdAndLatestTrue`, `findByStudentIdAndAssignmentIdAndPlanIdAndLatestTrue`) |
| `security/SecurityUtils.java` | **Giữ lại** (`hasRole` vẫn cần cho `HeaderAuthenticationFilter`/`@PreAuthorize`), controller không dùng nữa |

### 4.2 submission-service

| File | Thay đổi |
|---|---|
| `controller/SubmissionController.java:94-98` | **Xoá** `listByAssignment` khỏi controller public (kèm `@PreAuthorize`) |
| `controller/SubmissionController.java:85` | **Xoá** `!SecurityUtils.hasRole("LECTURER")` → còn `!callerId.equals(...)` → 404 |
| `controller/SubmissionInternalController.java` | Thêm `@GetMapping("/assignment/{assignmentId}")` → `submissionService.listByAssignment` (**đã có sẵn**) |

### 4.3 course-service

| File | Thay đổi |
|---|---|
| `client/ResultServiceClient.java` | Thêm method `GET /api/v1/internal/results/assignment/{id}` |
| `client/SubmissionInternalClient.java` | **Mới** — pattern giống `executor-service/client/CourseInternalClient.java`: `@FeignClient(name="submission-service", url="${feign.submission-service.url}", configuration=FeignLoggingConfiguration.class)` |
| `src/main/resources/application.yaml` | Thêm `feign.submission-service.url: ${SUBMISSION_SERVICE_URI:http://grading-submission-service:8082}` — **default là in-cluster DNS → không sửa Helm chart** (cùng lý do `allowed-roles`) |
| `service/AssignmentGradingService.java` | **Mới** — owner-check → 2 Feign call → map `studentUserId → studentCode` bằng `classStudentRepository.findAllByClassId` (đã có) |
| `controller/AssignmentGradingController.java` | **Mới** — `@RequestMapping("/api/v1/assignments/{assignmentId}")`, cấu trúc giống `TestPlanController` đã có |
| `dto/response/*` | **Mới** — dùng `@Builder` (quy tắc >2 field, skill §§12.6–12.7) |

`CourseServiceApplication` đã có `@EnableFeignClients` + `@ConfigurationPropertiesScan` → không sửa.

**Thứ tự owner-check:** phải chạy **trước** Feign call — không gọi nội bộ nếu không phải lớp mình
(không để lộ thành oracle dò id).

---

## 5. Tests

Dùng lại recipe `@WebMvcTest` đã ghi ở skill §12.10
(dep `spring-boot-webmvc-test` · package `org.springframework.boot.webmvc.test.autoconfigure` ·
`@EnableConfigurationProperties` không phải `@Import` · `@MockitoBean HttpLogService` ·
chain-only MockMvc · trust headers thật).

| Test class | Nội dung |
|---|---|
| `result-service` `ResultControllerAuthorizationTest` | **Đảo ngược** `lecturerMayReadAnyStudentsResults` → mong **403**, rename `lecturerMayNotReadOtherStudentsResultsThroughTheStudentEndpoint`. 4 test còn lại giữ nguyên |
| `submission-service` `SubmissionControllerAuthorizationTest` | 2 test list-by-assignment → route public biến mất → mong **404**; `lecturerMayReadAnySubmission` → giờ **404**; ownership tests giữ nguyên |
| `course-service` `AssignmentGradingAuthorizationTest` (**mới**) | Ma trận 4 case × 2 endpoint: giảng viên chủ lớp → 200 · giảng viên lớp khác → **404** · sinh viên → 403 · không role → 403 |
| `course-service` service test | Mock Feign, verify owner-check chạy trước Feign call |

Kiểm tra lại `ResultControllerTest` (3 test) và `SubmissionControllerTest` (4 test) —
có thể đang assert hành vi cũ → đọc lại và sửa nếu mâu thuẫn.

---

## 6. Docs & skills (bắt buộc theo `AGENTS.md`)

| File | Thay đổi |
|---|---|
| `docs/design/usecase-flows.md` UC-04 Step 4 | **Xoá** dòng `X-User-Roles: LECTURER ⇒ ownership rule skipped` (đã thêm ở slice 2 — nay sai) |
| `docs/design/usecase-flows.md` | Thêm **UC-06: Giảng viên xem & chấm kết quả auto-grading** — numbered steps với 2 endpoint mới, preconditions (sở hữu lớp), expected 200/404/403 |
| `docs/api/API-TEST-GUIDE.md` | Sửa dòng `GET /api/v1/submissions/assignment/...` (§2.2), mục result-service (§3), negative matrix (§4) |
| `src-services/docs/api/postman/FULL_FLOW_TESTING_GUIDE.md` §0 *Role rule* | Bỏ "per-assignment submission + results bypass", thêm 2 endpoint mới; §7 checklist cập nhật |
| Postman collection | Thêm 2 request mới, gỡ request bị gỡ, cập nhật description |
| `src-services/README.md` | Bảng role: sửa 2 dòng submission/results, thêm 2 dòng mới |
| **Skills `.opencode/` + `.kilo/` (giống hệt nhau)** | **§12.9 phải viết lại** — hiện ghi *"Where one endpoint needs either (read a result if owner or lecturer), `@PreAuthorize` cannot express it — use `SecurityUtils.hasRole` inside the method"*. **Quy tắc mới:** không bao giờ đặt role bypass trong ownership check; khi một vai trò cần dữ liệu rộng hơn → mở route riêng owner-scoped ở course-service. Để nguyên sẽ dạy sai người sau |

---

## 7. Thứ tự thực hiện

```
1. result-service       internal GET + gỡ bypass + đảo test           ← độc lập
2. submission-service   internal GET + gỡ route public + gỡ bypass + đảo test  ← độc lập
    (1 và 2 chạy song song được)
3. course-service       Feign client + service + controller + tests   ← phụ thuộc 1,2
4. Docs + skills
5. Validate: ./mvnw test ×4 service · mvn clean package -DskipTests ×4 · helm template ×4
```

**Lưu ý:** bước 3 mới là bước hợp lệ hoá 2 endpoint mới. Sau bước 1–2 thì route giảng viên
chưa có nơi nào gọi → **phải làm đủ cả 3 bước, không dừng ở 1–2.**

---

## 8. Rủi ro

- **Cluster unreachable** (`127.0.0.1:6443`) → không verify end-to-end, chỉ verify bằng test.
  Keycloak realm `ptit-wgs` vẫn chưa có role `LECTURER`/`STUDENT` → e2e role chưa kiểm chứng được.
- **Breaking change**: gỡ route public `GET /api/v1/submissions/assignment/{id}`.
  FE chưa dựng màn này → an toàn; Postman collection có request đó (đã tính ở §6).
- Filter topology gotcha (đã ghi ở skill §12.10): MockMvc auto-config đặt `Filter` bean **trước**
  `springSecurityFilterChain`, đảo thứ tự so với container → mọi request 401. Test phải tự build
  chain-only MockMvc.
- Các thay đổi chưa commit của slice 1 + slice 2 (44 file `src-services`, 10 file outer repo)
  vẫn nằm ở nhánh `duong/feat/DAT-8` / `main` → plan này tiếp tục lên trên đó.

---

## 9. Ngoài scope (đề nghị tách slice riêng)

1. **`POST /api/v1/submissions/presigned-url` không check enrollment** — `SubmissionService.requestUpload:42`
   nhận `assignmentId` + header `studentId` và persist ngay: không check `class_students`,
   không check assignment tồn tại (`InternalAssignmentController /{id}/exists` **không có caller**
   và chỉ trả `boolean exists`, không có `classId`), không check `planId` thuộc assignment.
   submission-service **không có** Feign client nào. → Bất kỳ ai giữ `GATEWAY_TRUSTED_SECRET`
   có thể tạo submission cho assignment bất kỳ, stamp `studentId` bất kỳ.
   `hasRole('STUDENT')` **không sửa được lỗ này** (cần enrollment check qua Feign course-service).
   Đây là lỗ hổng thật, nghiêm trọng hơn chuyện tách route.
2. **Nhất quán mã lỗi**: results trả `403` khi sai owner, submissions trả `404` —
   convention của project là 404 không phân biệt. Muốn chuẩn hoá thì làm cùng slice.

---

## 10. Chưa được làm trong plan này

- Chưa sửa bất kỳ file nào (trừ file plan này).
- Chưa cập nhật skill khi viết plan — skill §12.9 vẫn còn quy tắc cũ, sẽ được sửa ở bước 4 khi implement.
