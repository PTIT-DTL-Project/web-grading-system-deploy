# Tài liệu chi tiết luồng API — ai-assistant-service / PendingActionController

Nơi lưu: `docs/api/docs/ai-assistant-service/pending-action-controller.md`

Mục đích: giải thích chi tiết các endpoint quản lý pending action (thao tác chờ xác nhận) của AI agent, bao gồm input, output, luồng xử lý, ví dụ, và mã lỗi. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`PendingActionController` là REST controller của service `ai-assistant-service`, trỏ về base path `/api/v1/ai/pending-actions`. Nó cung cấp các endpoint để liệt kê, xem chi tiết, xác nhận (confirm) và từ chối (reject) các thao tác ghi dữ liệu mà AI agent đang chờ người dùng xác nhận trước khi thực hiện.

**Lý do tồn tại:** Theo quy ước hệ thống, AI agent không tự ý thực hiện các thao tác ghi (tạo assignment, plan, step, ...) mà phải "hỏi giảng viên trước" — giảng viên xem xét cấu hình JSON đã sinh, chỉnh sửa nếu cần, rồi mới nhấn lưu/xác nhận. Pending action là cơ chế trung gian giữa việc AI sinh cấu hình và việc thực tế ghi vào cơ sở dữ liệu.

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/ai/pending-actions/conversation/{conversationId}` | GET | Liệt kê các pending action của một cuộc hội thoại | Người dùng đã xác thực |
| `/api/v1/ai/pending-actions/{id}` | GET | Xem chi tiết một pending action | Người dùng đã xác thực (chủ sở hữu) |
| `/api/v1/ai/pending-actions/{id}/confirm` | POST | Xác nhận thực hiện pending action | Người dùng đã xác thực (chủ sở hữu) |
| `/api/v1/ai/pending-actions/{id}/reject` | POST | Từ chối pending action (hủy bỏ) | Người dùng đã xác thực (chủ sở hữu) |

**Quyền:** Nhận `UserPrincipal` qua `@AuthenticationPrincipal`. Không có `@PreAuthorize` — quyền kiểm tra sở hữu được thực hiện bên trong `WriteApprovalService`.

Controller giao tiếp trực tiếp với `WriteApprovalService` (không qua repository trực tiếp).

---

## 2. DTO liên quan

Các endpoint này trả về `ResponseEntity<Object>` — kiểu trả về chung `Object` (tùy theo loại pending action: assignment, plan, step, ...). Cấu trúc cụ thể phụ thuộc vào `WriteApprovalService` trả về. Khả năng cao chứa các trường: id, commandType, status, config JSON (đã sinh bởi LLM), resultRef, attempts, createdAt, updatedAt.

---

## 3. Chi tiết từng hàm

### 3.1 `list` — Liệt kê pending action của một cuộc hội thoại

**Vị trí:** `PendingActionController.list(...)` → `WriteApprovalService.list(...)`

**Endpoint:** `GET /api/v1/ai/pending-actions/conversation/{conversationId}`

**Path variable:** `conversationId` (UUID) — ID cuộc hội thoại

**Header đầu vào:** `UserPrincipal`

**Luồng xử lý:**
1. Controller nhận `UserPrincipal principal` và `conversationId`.
2. Gọi `service.list(conversationId, principal)`.
3. Trả về `ResponseEntity.ok(service.list(...))` — kiểu `Object` (danh sách pending action của cuộc hội thoại, chỉ những action thuộc về người gọi).

**Ví dụ request:**
```http
GET /api/v1/ai/pending-actions/conversation/a1b2c3d4-...
```

**Ví dụ response (200):** Danh sách pending action (kiểu Object, phụ thuộc vào implementation của WriteApprovalService).

---

### 3.2 `get` — Xem chi tiết một pending action

**Vị trí:** `PendingActionController.get(...)` → `WriteApprovalService.get(...)`

**Endpoint:** `GET /api/v1/ai/pending-actions/{id}`

**Path variable:** `id` (UUID) — ID pending action

**Header đầu vào:** `UserPrincipal`

**Luồng xử lý:**
1. Controller nhận `UserPrincipal principal` và `id`.
2. Gọi `service.get(id, principal)`.
3. Trả về `ResponseEntity.ok(service.get(...))` — kiểu `Object` (chi tiết một pending action, bao gồm config JSON đã sinh, status, ...).

**Ví dụ request:**
```http
GET /api/v1/ai/pending-actions/e5f6g7h8-...
```

**Ví dụ response (200):** Chi tiết pending action (kiểu Object).

---

### 3.3 `confirm` — Xác nhận thực hiện pending action

**Vị trí:** `PendingActionController.confirm(...)` → `WriteApprovalService.confirm(...)`

**Endpoint:** `POST /api/v1/ai/pending-actions/{id}/confirm`

**Path variable:** `id` (UUID) — ID pending action

**Header đầu vào:** `UserPrincipal`

**Luồng xử lý:**
1. Controller nhận `UserPrincipal principal` và `id`.
2. Gọi `service.confirm(id, principal)`.
3. Service:
   - Kiểm tra pending action tồn tại và thuộc về người gọi.
   - Kiểm tra status hiện tại (chỉ confirm được khi đang `PENDING`/`WAITING_APPROVAL`).
   - Thực hiện thao tác ghi dữ liệu (gọi course-service API: tạo assignment, plan, step, ...).
   - Cập nhật status thành `DONE` (hoặc `FAILED` nếu thực hiện thất bại).
   - Tạo/ghi lại `Operation` để theo dõi (liên quan đến `OperationController`).
4. Trả về `ResponseEntity.ok(service.confirm(...))` — kiểu `Object` (kết quả sau khi xác nhận, ví dụ ID assignment/plan/step đã tạo).

**Ví dụ request:**
```http
POST /api/v1/ai/pending-actions/e5f6g7h8-.../confirm
```

**Ví dụ response (200):** Kết quả xác nhận (kiểu Object, ví dụ { assignmentId: "16cebadb-..." }).

**Mã lỗi:**
- `400`: pending action không ở trạng thái cho phép confirm (ví dụ đã DONE/FAILED).
- `404`: pending action không tìm thấy hoặc không thuộc về người gọi.
- `502`: course-service không khả dụng khi thực hiện thao tác ghi.

---

### 3.4 `reject` — Từ chối pending action

**Vị trí:** `PendingActionController.reject(...)` → `WriteApprovalService.reject(...)`

**Endpoint:** `POST /api/v1/ai/pending-actions/{id}/reject`

**Path variable:** `id` (UUID) — ID pending action

**Header đầu vào:** `UserPrincipal`

**Luồng xử lý:**
1. Controller nhận `UserPrincipal principal` và `id`.
2. Gọi `service.reject(id, principal)`.
3. Service:
   - Kiểm tra pending action tồn tại và thuộc về người gọi.
   - Cập nhật status thành `REJECTED` (hoặc `CANCELLED`).
   - Không thực hiện bất kỳ thao tác ghi dữ liệu nào.
4. Trả về `ResponseEntity.ok(service.reject(...))` — kiểu `Object` (kết quả sau khi từ chối).

**Ví dụ request:**
```http
POST /api/v1/ai/pending-actions/e5f6g7h8-.../reject
```

**Ví dụ response (200):** Kết quả từ chối (kiểu Object, ví dụ { status: "REJECTED" }).

**Mã lỗi:**
- `400`: pending action không ở trạng thái cho phép từ chối.
- `404`: pending action không tìm thấy hoặc không thuộc về người gọi.

---

## 4. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 404 | Pending action không tồn tại / không thuộc người gọi | `WriteApprovalService` |
| 400 | Pending action không ở trạng thái cho phép confirm/reject | `WriteApprovalService` |
| 502 | course-service không khả dụng khi thực hiện confirm | `WriteApprovalService` (qua course-service client) |

---

## 5. Luồng dữ liệu từ đầu đến cuối (ví dụ lecturer xác nhận tạo plan/step)

```
AI agent (ai-assistant-service)
   │ 1. Sinh ra plan/step config JSON từ intent tiếng Việt của lecturer (qua LLM)
   │ 2. Gọi course-service validate config (GET /api/v1/internal/test-plans/validate)
   │ 3. Tạo một PendingAction (status=PENDING/WAITING_APPROVAL), chứa config JSON
   │ 4. Trả về pending action ID cho lecturer
   ▼
Lecturer (FE)
   │ GET /api/v1/ai/pending-actions/conversation/{conversationId}
   │    (Xem danh sách pending action cần xác nhận)
   ▼
PendingActionController.list()
   │ 1. Gọi WriteApprovalService.list(conversationId, principal)
   │ 2. Trả về danh sách pending action
   ▼
FE hiển thị config JSON cho lecturer xem xét (có thể chỉnh sửa)
   │
   │ Lecturer nhấn "Xác nhận"/"Lưu"
   ▼
   │ POST /api/v1/ai/pending-actions/{id}/confirm
   ▼
PendingActionController.confirm()
   │ 1. Gọi WriteApprovalService.confirm(id, principal)
   ▼
WriteApprovalService.confirm()
   │ 2. Kiểm tra pending action tồn tại, thuộc lecturer, status PENDING
   │ 3. Gọi course-service API tạo assignment/plan/step (theo config JSON)
   │ 4. Cập nhật pending action status = DONE
   │ 5. Tạo Operation entity để theo dõi (liên quan OperationController)
   │ 6. Trả về kết quả (assignmentId/planId/stepId đã tạo)
   ▼
PendingActionController.confirm()
   │ 7. Trả về 200 OK + kết quả
   ▼
FE hiển thị thông báo "Đã tạo thành công" + redirect đến trang chi tiết bài tập
```

```
Lecturer từ chối:
   │ POST /api/v1/ai/pending-actions/{id}/reject
   ▼
PendingActionController.reject()
   │ 1. Gọi WriteApprovalService.reject(id, principal)
   ▼
WriteApprovalService.reject()
   │ 2. Cập nhật status = REJECTED (không ghi dữ liệu gì)
   │ 3. Trả về kết quả
   ▼
FE hiển thị "Đã từ chối"
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/ai-assistant-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
