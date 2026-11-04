# PLAN: Viết docs API chi tiết cho tất cả controller/service

Trạng thái: **HOÀN TẤT** (24/24 controller/service đã viết)

Thư mục lưu trữ: `docs/api/docs/<service>/<controller-name>.md`

## Danh sách đã hoàn tất (24 file)

### course-service (5 controller + 3 service)
- [x] `assignment-controller.md` — AssignmentController (tạo/danh sách/chi tiết/cập nhật/xóa mềm/xuất bản bài tập)
- [x] `assignment-grading-controller.md` — AssignmentGradingController (xem kết quả chấm + danh sách nộp bài của giảng viên)
- [x] `class-controller.md` — ClassController (tạo/danh sách/chi tiết/lưu trữ/nhập CSV sinh viên/xem danh sách sinh viên lớp)
- [x] `score-controller.md` — ScoreController (thành phần điểm/nhập điểm thủ công/xem điểm sinh viên/bảng điểm trung bình)
- [x] `student-assignment-controller.md` — StudentAssignmentController (xem bài tập/plan của sinh viên, config đã sanitize)
- [x] `student-class-controller.md` — StudentClassController (xem lớp đã đăng ký/điểm của mình/bạn cùng lớp)
- [x] `test-plan-controller.md` — TestPlanController (tạo plan/step, danh sách, cập nhật, xóa mềm)
- [x] `internal-assignment-controller.md` — InternalAssignmentController (grading config, plans, exists, dry-run, config-schema cho executor/submission)
- [x] `internal-test-plan-controller.md` — InternalTestPlanController (validate plan/step config, capabilities schema cho ai-assistant-service)

### executor-service (2 controller + 1 service quan trọng)
- [x] `dry-run-controller.md` — DryRunController (chấm thử, không side effect)
- [x] `reset-grading-job-controller.md` — ResetGradingJobController + ResetGradingJobService (reset job, chạy lại chấm điểm)
- [x] `grading-orchestrator.md` — GradingOrchestrator (luồng chấm điểm FETCHING→BUILDING→RUNNING→DONE/FAILED, công thức điểm, biến thay thế, auto_inject_headers, DB sandbox, dry-run)

### result-service (2 controller + 1 service)
- [x] `result-controller.md` — ResultController (xem kết quả theo submission, xem kết quả bài tập của mình)
- [x] `result-internal-controller.md` — ResultInternalController + ResultService (điểm trung bình có trọng số, by assignment, by submission, tạo kết quả chấm)

### submission-service (3 controller + 1 service)
- [x] `submission-controller.md` — SubmissionController (presigned-url, danh sách nộp của mình, chi tiết nộp, health, version)
- [x] `submission-internal-controller.md` — SubmissionInternalController (danh sách nộp theo assignment, cập nhật status)
- [x] `submission-webhook-controller.md` — SubmissionWebhookController (webhook RustFS ObjectCreated:Put, khởi động chấm điểm qua Kafka)

### ai-assistant-service (5 controller)
- [x] `ai-explanation-controller.md` — AiExplanationController (giải thích AI cho sinh viên/giảng viên, cache-only lecturer)
- [x] `chat-controller.md` — ChatController (tạo/danh sách/chi tiết/cập nhật/xóa cuộc hội thoại, gửi tin nhắn, lấy tin nhắn)
- [x] `operation-controller.md` — OperationController (xem chi tiết thao tác/operation)
- [x] `pending-action-controller.md` — PendingActionController (liệt kê/xem/xác nhận/từ chối pending action)
- [x] `run-controller.md` — RunController (SSE sự kiện run, xem trạng thái run, hủy run)

### api-gateway (2 controller)
- [x] `change-password-controller.md` — ChangePasswordController (đổi mật khẩu tự phục vụ UC-14, không cần token, ApiEnvelope)
- [x] `user-import-controller.md` — UserImportController (nhập bulk tài khoản CSV, chỉ ADMIN, báo cáo chi tiết từng dòng)

## Mẫu viết cho mỗi file
1. Tổng quan (endpoint, method, mục đích, quyền)
2. DTO liên quan (request/response, từng trường)
3. Chi tiết từng hàm (controller → service): input, output, luồng xử lý từng bước, ví dụ request/response HTTP, mã lỗi
4. Các hàm private helper quan trọng
5. Mã lỗi tóm tắt
6. Luồng dữ liệu end-to-end (dạng sơ đồ văn bản)

## Quy tắc đã tuân thủ
- Viết bằng tiếng Việt
- Không bịa đặt API, đọc source code trước khi viết
- Một file controller/service một file .md
- GradingOrchestrator viết riêng, tập trung vào luồng chấm điểm (FETCHING → BUILDING → RUNNING → DONE/FAILED, DB step, HTTP step, score formula, single-job gate)
