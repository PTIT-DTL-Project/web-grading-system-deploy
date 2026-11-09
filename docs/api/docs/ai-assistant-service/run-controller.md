# Tài liệu chi tiết luồng API — ai-assistant-service / RunController

Nơi lưu: `docs/api/docs/ai-assistant-service/run-controller.md`

Mục đích: giải thích chi tiết các endpoint quản lý agent run (chạy tác vụ AI) của ai-assistant-service, bao gồm input, output, luồng xử lý, ví dụ, và mã lỗi. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`RunController` là REST controller của service `ai-assistant-service`, trỏ về base path `/api/v1/ai/runs`. Nó cung cấp các endpoint để theo dõi trạng thái và sự kiện của một agent run (tác vụ chạy nền của AI agent sau khi sinh viên/giảng viên gửi tin nhắn trong cuộc hội thoại).

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/ai/runs/{id}/events` | GET (SSE) | Đăng ký nhận sự kiện thời gian thực của một agent run (Server-Sent Events) | Người dùng đã xác thực (chủ sở hữu) |
| `/api/v1/ai/runs/{id}` | GET | Xem trạng thái hiện tại của một agent run | Người dùng đã xác thực (chủ sở hữu) |
| `/api/v1/ai/runs/{id}/cancel` | POST | Hủy một agent run (nếu đang QUEUED/RUNNING/WAITING_USER/WAITING_APPROVAL) | Người dùng đã xác thực (chủ sở hữu) |

**Quyền:** Nhận `UserPrincipal` qua `@AuthenticationPrincipal`. Không có `@PreAuthorize` — quyền kiểm tra sở hữu run được thực hiện bên trong repository/service (nếu cần). Controller chỉ truy vấn `RunRepository` và sử dụng `SseBroadcaster` để phát sự kiện SSE.

Controller giao tiếp trực tiếp với `RunRepository` và `SseBroadcaster` (không qua service class riêng).

---

## 2. DTO liên quan

### 2.1 `RunResponse` (dto/response, record)
Thông tin trạng thái của một agent run.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID run |
| `conversationId` | UUID | ID cuộc hội thoại liên quan |
| `status` | `RunStatus` | Trạng thái run (`QUEUED`, `RUNNING`, `WAITING_USER`, `WAITING_APPROVAL`, `DONE`, `FAILED`, `CANCELLED`, ...) |
| `errorCode` | String | Mã lỗi (nếu run thất bại) |
| `errorMessage` | String | Thông báo lỗi chi tiết (nếu run thất bại) |
| `startedAt` | Instant | Thời điểm bắt đầu chạy |
| `finishedAt` | Instant | Thời điểm kết thúc chạy |

### 2.2 `RunStatus` (entity enum)
Trạng thái của một agent run. Các giá trị phổ biến:
- `QUEUED`: Đang trong hàng chờ chạy
- `RUNNING`: Đang thực thi (LLM đang xử lý, có thể gọi tool)
- `WAITING_USER`: Đang chờ người dùng nhập thông tin bổ sung
- `WAITING_APPROVAL`: Đang chờ lecturer xác nhận pending action (tạo plan/step, ...)
- `DONE`: Hoàn thành thành công
- `FAILED`: Thất bại (có errorCode/errorMessage)
- `CANCELLED`: Đã bị hủy

---

## 3. Chi tiết từng hàm

### 3.1 `subscribeEvents` — Đăng ký nhận sự kiện run qua SSE

**Vị trí:** `RunController.subscribeEvents(...)`

**Endpoint:** `GET /api/v1/ai/runs/{id}/events` (produces `text/event-stream`)

**Path variable:** `id` (UUID) — ID run

**Header đầu vào:** `UserPrincipal`

**Luồng xử lý:**
1. Controller nhận `UserPrincipal principal` và `id` từ path variable.
2. Gọi `sseBroadcaster.subscribe(id)` → trả về `SseEmitter`.
3. Trả về `SseEmitter` (Spring sẽ tự động stream các sự kiện đến client qua kết nối HTTP dài hạn).

**Ghi chú:** Endpoint này dùng `Server-Sent Events (SSE)` để client có thể theo dõi tiến độ của agent run theo thời gian thực (ví dụ: LLM đang phân tích intent, đã gọi tool nào, đã tạo plan/step nào, đang chờ xác nhận, ...). Client sẽ lắng nghe các sự kiện `message` từ stream này.

**Ví dụ request:**
```http
GET /api/v1/ai/runs/e5f6g7h8-.../events
Accept: text/event-stream
```

**Ví dụ response (200, SSE stream):**
```
data: {"type":"RUN_STARTED","runId":"e5f6g7h8-...","status":"RUNNING"}

data: {"type":"TOOL_CALL","tool":"createPlan","args":{...}}

data: {"type":"RUN_STATUS","status":"WAITING_APPROVAL","message":"Waiting for lecturer confirmation"}

data: {"type":"RUN_DONE","runId":"e5f6g7h8-...","status":"DONE"}
```

---

### 3.2 `getRunStatus` — Xem trạng thái run

**Vị trí:** `RunController.getRunStatus(...)`

**Endpoint:** `GET /api/v1/ai/runs/{id}`

**Path variable:** `id` (UUID) — ID run

**Header đầu vào:** `UserPrincipal`

**Luồng xử lý:**
1. Controller nhận `UserPrincipal principal` và `id`.
2. Gọi `runRepository.findById(id)`.
3. Nếu không tìm thấy → ném `IllegalArgumentException("Run not found: " + id)`.
4. Nếu tìm thấy → xây dựng `RunResponse` với các trường:
   - `run.getId()`
   - `run.getConversationId()`
   - `run.getStatus()`
   - `run.getErrorCode()`
   - `run.getErrorMessage()`
   - `run.getStartedAt()`
   - `run.getFinishedAt()`
5. Trả về `ResponseEntity.ok(RunResponse)`.

**Ví dụ request:**
```http
GET /api/v1/ai/runs/e5f6g7h8-...
```

**Ví dụ response (200):**
```json
{
  "id": "e5f6g7h8-...",
  "conversationId": "a1b2c3d4-...",
  "status": "WAITING_APPROVAL",
  "errorCode": null,
  "errorMessage": null,
  "startedAt": "2026-11-01T10:30:05Z",
  "finishedAt": null
}
```

**Ví dụ response (400/500):** Nếu run không tìm thấy (`IllegalArgumentException`).

**Mã lỗi:**
- `400` / `500`: run không tìm thấy (tùy theo global exception handler ánh xạ `IllegalArgumentException`).

---

### 3.3 `cancelRun` — Hủy agent run

**Vị trí:** `RunController.cancelRun(...)`

**Endpoint:** `POST /api/v1/ai/runs/{id}/cancel`

**Path variable:** `id` (UUID) — ID run

**Header đầu vào:** `UserPrincipal`

**Luồng xử lý:**
1. Controller nhận `UserPrincipal principal` và `id`.
2. Gọi `runRepository.findById(id)`.
3. Nếu không tìm thấy → ném `IllegalArgumentException("Run not found: " + id)`.
4. Nếu tìm thấy:
   - Kiểm tra `run.getStatus()` có phải là một trong các trạng thái cho phép hủy: `QUEUED`, `RUNNING`, `WAITING_USER`, `WAITING_APPROVAL`.
   - Nếu có → đặt `run.setStatus(RunStatus.CANCELLED)`, lưu qua `runRepository.save(run)`.
   - Nếu không (ví dụ đã `DONE`/`FAILED`/`CANCELLED`) → không làm gì (bỏ qua).
5. Trả về `ResponseEntity.ok().build()` (200 OK, không body).

**Ghi chú:** Chỉ có thể hủy run khi nó chưa hoàn thành (không ở trạng thái terminal `DONE`/`FAILED`/`CANCELLED`). Run ở trạng thái `WAITING_APPROVAL` (đang chờ lecturer xác nhận pending action) cũng có thể hủy để dừng luồng xử lý.

**Ví dụ request:**
```http
POST /api/v1/ai/runs/e5f6g7h8-.../cancel
```

**Ví dụ response (200):** Rỗng (không body).

**Mã lỗi:**
- `400` / `500`: run không tìm thấy (`IllegalArgumentException`).

---

## 4. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 400 / 500 | Run không tìm thấy | `RunController.getRunStatus`, `cancelRun` (via `IllegalArgumentException`) |
| 401/403 | Chưa xác thực | Spring Security (`@AuthenticationPrincipal`) |

---

## 5. Luồng dữ liệu từ đầu đến cuối (ví dụ theo dõi agent run qua SSE)

```
Sinh viên/giảng viên (FE)
   │ POST /api/v1/ai/conversations/{id}/messages
   │    body: { "content": "Tạo bài tập quản lý sinh viên..." }
   ▼
ai-assistant-service: ChatController.sendMessage()
   │ 1. Tạo Run mới (status=QUEUED/RUNNING)
   │ 2. Trả về SendMessageResponse{runId}
   ▼
FE nhận runId, bắt đầu theo dõi:
   │ GET /api/v1/ai/runs/{runId}/events (SSE)
   ▼
RunController.subscribeEvents()
   │ 1. Gọi sseBroadcaster.subscribe(runId)
   │ 2. Trả về SseEmitter (stream sự kiện realtime)
   ▼
AgentRuntime/AgentOrchestrator (chạy nền)
   │ 3. LLM phân tích intent tiếng Việt
   │ 4. Gọi tool (course-service validate config, ...)
   │ 5. Tạo pending action (status=WAITING_APPROVAL)
   │ 6. SseBroadcaster phát sự kiện: RUN_STATUS(WAITING_APPROVAL)
   ▼
FE nhận sự kiện SSE, hiển thị:
   - "Đang phân tích yêu cầu của bạn..."
   - "Đang tạo cấu hình bài tập..."
   - "Chờ bạn xác nhận trước khi lưu" (hiển thị nút Xác nhận/Từ chối)
   
Lecturer nhấn Xác nhận:
   │ POST /api/v1/ai/pending-actions/{id}/confirm
   ▼
PendingActionController.confirm() → WriteApprovalService.confirm()
   │ 7. Thực hiện ghi dữ liệu (tạo assignment/plan/step)
   │ 8. Cập nhật Run status = DONE
   │ 9. SseBroadcaster phát sự kiện: RUN_DONE
   ▼
FE nhận RUN_DONE, hiển thị "Đã tạo bài tập thành công"
```

```
Hủy run khi đang chờ xác nhận:
   │ POST /api/v1/ai/runs/{runId}/cancel
   ▼
RunController.cancelRun()
   │ 1. Kiểm tra status = WAITING_APPROVAL (cho phép hủy)
   │ 2. Đặt status = CANCELLED, lưu
   │ 3. Trả về 200 OK
   ▼
FE hiển thị "Đã hủy thao tác"
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/ai-assistant-service/`. Tất cả 5 controller của ai-assistant-service hiện đã viết đầy đủ. Tiếp theo sẽ viết tài liệu cho api-gateway (2 controller).*
