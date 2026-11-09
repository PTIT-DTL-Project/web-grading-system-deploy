# Tài liệu chi tiết luồng API — ai-assistant-service / OperationController

Nơi lưu: `docs/api/docs/ai-assistant-service/operation-controller.md`

Mục đích: giải thích chi tiết endpoint xem chi tiết thao tác (operation) của AI agent, bao gồm input, output, ví dụ, và mã lỗi. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`OperationController` là REST controller của service `ai-assistant-service`, trỏ về base path `/api/v1/ai/operations`. Nó cung cấp endpoint để xem chi tiết một thao tác (operation) đã được ghi lại — dùng để theo dõi trạng thái các thao tác ghi dữ liệu (create/update/delete assignment, plan, step, ...) mà AI agent thực hiện sau khi người dùng xác nhận.

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/ai/operations/{id}` | GET | Xem chi tiết một thao tác (operation) | Người dùng đã xác thực |

**Quyền:** Nhận `UserPrincipal` qua `@AuthenticationPrincipal`. Không có `@PreAuthorize` — quyền kiểm tra được thực hiện bên trong service/repository (nếu cần). Controller chỉ truy vấn `OperationRepository` và trả về `OperationResponse`.

Controller giao tiếp trực tiếp với `OperationRepository` (không qua service class riêng).

---

## 2. DTO liên quan

### 2.1 `OperationResponse` (dto/response, record)
Thông tin chi tiết một thao tác (operation).

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID thao tác |
| `taskId` | UUID | ID tác vụ (run/task) liên quan |
| `idempotencyKey` | String | Khóa idempotency (đảm bảo không thực hiện trùng) |
| `commandType` | String | Loại lệnh thao tác (ví dụ `CREATE_ASSIGNMENT`, `UPDATE_PLAN`, `DELETE_STEP`, ...) |
| `status` | `OperationStatus` | Trạng thái thao tác (`PENDING`, `RUNNING`, `DONE`, `FAILED`, ...) |
| `resultRef` | String | Tham chiếu tới kết quả (ví dụ ID assignment/plan/step đã tạo) |
| `attempts` | Integer | Số lần thử thực hiện |
| `nextCheckAt` | Instant | Thời điểm kiểm tra tiếp theo (nếu đang pending/running) |
| `createdAt` | Instant | Thời điểm tạo thao tác |
| `updatedAt` | Instant | Thời điểm cập nhật lần cuối |

### 2.2 `OperationStatus` (entity enum)
Trạng thái của một operation: `PENDING`, `RUNNING`, `DONE`, `FAILED`, ... (xem source để biết danh sách đầy đủ).

---

## 3. Chi tiết hàm `getOperation`

**Vị trí:** `OperationController.getOperation(...)`

**Endpoint:** `GET /api/v1/ai/operations/{id}`

**Path variable:** `id` (UUID) — ID thao tác cần xem

**Header đầu vào:** `UserPrincipal` (từ `@AuthenticationPrincipal`)

**Luồng xử lý:**
1. Controller nhận `UserPrincipal principal` và `id` từ path variable.
2. Gọi `operationRepository.findById(id)`.
3. Nếu không tìm thấy → ném `IllegalArgumentException("Operation not found: " + id)` (sẽ trở thành `400 Bad Request` hoặc `500` tùy theo global exception handler).
4. Nếu tìm thấy → xây dựng `OperationResponse` với các trường:
   - `op.getId()`
   - `op.getTaskId()`
   - `op.getIdempotencyKey()`
   - `op.getCommandType()`
   - `op.getStatus()`
   - `op.getResultRef()`
   - `op.getAttempts()`
   - `op.getNextCheckAt()`
   - `op.getCreatedAt()`
   - `op.getUpdatedAt()`
5. Trả về `ResponseEntity.ok(OperationResponse)`.

**Ví dụ request:**
```http
GET /api/v1/ai/operations/a1b2c3d4-...
```

**Ví dụ response (200):**
```json
{
  "id": "a1b2c3d4-...",
  "taskId": "e5f6g7h8-...",
  "idempotencyKey": "op-create-assignment-12345",
  "commandType": "CREATE_ASSIGNMENT",
  "status": "DONE",
  "resultRef": "16cebadb-2485-4494-be5b-7f6641887559",
  "attempts": 1,
  "nextCheckAt": null,
  "createdAt": "2026-11-01T10:30:00Z",
  "updatedAt": "2026-11-01T10:30:05Z"
}
```

**Ví dụ response (400/500):** Nếu operation không tìm thấy (`IllegalArgumentException`).

**Mã lỗi:**
- `400` / `500`: operation không tìm thấy (tùy theo global exception handler ánh xạ `IllegalArgumentException`).

---

## 4. Luồng dữ liệu từ đầu đến cuối (ví dụ theo dõi trạng thái thao tác tạo assignment)

```
AI agent (ai-assistant-service)
   │ 1. Sau khi lecturer xác nhận tạo assignment (qua PendingActionController confirm)
   │ 2. Tạo một Operation entity (commandType=CREATE_ASSIGNMENT, status=RUNNING)
   │ 3. Thực hiện gọi course-service tạo assignment
   │ 4. Cập nhật Operation: status=DONE, resultRef=<assignmentId>, attempts=1
   ▼
executor/lecturer (FE) theo dõi:
   │ GET /api/v1/ai/operations/{operationId}
   │    (UserPrincipal từ JWT)
   ▼
ai-assistant-service: OperationController.getOperation()
   │ 1. Gọi operationRepository.findById(id)
   │ 2. Nếu không tìm thấy → ném IllegalArgumentException
   │ 3. Xây dựng OperationResponse từ entity
   │ 4. Trả về ResponseEntity.ok(OperationResponse)
   ▼
FE hiển thị trạng thái thao tác (DONE, kết quả là assignmentId đã tạo)
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/ai-assistant-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
