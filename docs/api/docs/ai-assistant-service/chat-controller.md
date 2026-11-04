# Tài liệu chi tiết luồng API — ai-assistant-service / ChatController

Nơi lưu: `docs/api/docs/ai-assistant-service/chat-controller.md`

Mục đích: giải thích chi tiết từng hàm/controller/service trong luồng hội thoại AI chat (ChatController), bao gồm input, output, điều kiện tiên quyết, ví dụ request/response, và các mã lỗi có thể xảy ra. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`ChatController` là REST controller của service `ai-assistant-service`, trỏ về base path `/api/v1/ai/conversations`. Nó cung cấp các endpoint để quản lý cuộc hội thoại (conversation) và gửi tin nhắn với AI agent (chat mode).

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/ai/conversations` | POST | Tạo cuộc hội thoại mới | Người dùng đã xác thực |
| `/api/v1/ai/conversations` | GET | Lấy danh sách cuộc hội thoại của mình (phân trang) | Người dùng đã xác thực |
| `/api/v1/ai/conversations/{id}` | GET | Xem chi tiết một cuộc hội thoại | Người dùng đã xác thực (chủ sở hữu) |
| `/api/v1/ai/conversations/{id}` | PUT | Cập nhật tiêu đề cuộc hội thoại | Người dùng đã xác thực (chủ sở hữu) |
| `/api/v1/ai/conversations/{id}` | DELETE | Xóa một cuộc hội thoại | Người dùng đã xác thực (chủ sở hữu) |
| `/api/v1/ai/conversations/{id}/messages` | POST | Gửi tin nhắn mới (kích hoạt agent run, trả về 202 ACCEPTED) | Người dùng đã xác thực (chủ sở hữu) |
| `/api/v1/ai/conversations/{id}/messages` | GET | Lấy danh sách tin nhắn trong cuộc hội thoại (phân trang) | Người dùng đã xác thực (chủ sở hữu) |

**Quyền:** Các endpoint đều nhận `UserPrincipal` qua `@AuthenticationPrincipal` (được gateway inject từ JWT). Không có `@PreAuthorize` ở controller level — quyền kiểm tra sở hữu conversation được thực hiện bên trong `ConversationService`. Gửi tin nhắn trả về `202 ACCEPTED` (chấp nhận, xử lý bất đồng bộ qua agent run).

Controller giao tiếp với `ConversationService` để thực hiện logic nghiệp vụ.

---

## 2. DTO liên quan

### 2.1 `CreateConversationRequest` (dto/request)
Yêu cầu tạo cuộc hội thoại mới.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| (xem file source) | — | — | Yêu cầu tạo conversation (chi tiết xem source) |

### 2.2 `UpdateConversationTitleRequest` (dto/request)
Yêu cầu cập nhật tiêu đề.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `title` | String | ✅ | Tiêu đề mới của cuộc hội thoại |

### 2.3 `SendMessageRequest` (dto/request)
Yêu cầu gửi tin nhắn mới.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| (xem file source) | — | — | Nội dung tin nhắn gửi đến AI agent |

### 2.4 `ConversationResponse` (dto/response, record)
Thông tin một cuộc hội thoại.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID cuộc hội thoại |
| `ownerId` | UUID | ID người dùng sở hữu |
| `title` | String | Tiêu đề |
| `activeTaskId` | UUID | ID tác vụ (run) đang active |
| `createdAt` | Instant | Thời điểm tạo |
| `updatedAt` | Instant | Thời điểm cập nhật lần cuối |

### 2.5 `SendMessageResponse` (dto/response, record)
Phản hồi sau khi gửi tin nhắn.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `conversationId` | UUID | ID cuộc hội thoại |
| `runId` | UUID | ID run (agent run) được tạo |
| `messageId` | UUID | ID tin nhắn |

### 2.6 `MessageResponse` (dto/response, record)
Thông tin một tin nhắn trong cuộc hội thoại.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID tin nhắn |
| `conversationId` | UUID | ID cuộc hội thoại |
| `runId` | UUID | ID run liên quan |
| `role` | String | Vai trò (`user`, `assistant`, `tool`) |
| `content` | String | Nội dung tin nhắn |
| `toolCallId` | String | ID tool call (nếu là tool message) |
| `toolName` | String | Tên tool (nếu là tool message) |
| `toolArguments` | String | Tham số tool (JSON) |
| `toolResult` | String | Kết quả tool (JSON) |
| `clientMessageId` | String | ID tin nhắn phía client |
| `sequenceNo` | Integer | Số thứ tự tin nhắn |
| `createdAt` | Instant | Thời điểm tạo |

### 2.7 `UserPrincipal` (security record)
Thông tin người dùng hiện tại từ JWT.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `userId` | UUID | ID người dùng |
| `email` | String | Email |
| `authorities` | `Collection<GrantedAuthority>` | Danh sách quyền (ví dụ `ROLE_STUDENT`, `ROLE_LECTURER`) |

---

## 3. Chi tiết từng hàm

### 3.1 `createConversation` — Tạo cuộc hội thoại mới

**Vị trí:** `ChatController.createConversation(...)` → `ConversationService.createConversation(...)`

**Endpoint:** `POST /api/v1/ai/conversations`

**Header đầu vào:** `UserPrincipal` (từ `@AuthenticationPrincipal`, gateway inject từ JWT)

**Request body:** `CreateConversationRequest` (optional, `required = false`)

**Luồng xử lý:**
1. Controller nhận `UserPrincipal principal` và `CreateConversationRequest request` (có thể null).
2. Gọi `conversationService.createConversation(principal, request)`.
3. Trả về `ResponseEntity.status(HttpStatus.CREATED).body(ConversationResponse)`.

**Ví dụ request:**
```http
POST /api/v1/ai/conversations
Content-Type: application/json

{ "title": "Hỏi về bài tập chấm điểm" }
```

**Ví dụ response (201):**
```json
{
  "id": "a1b2c3d4-...",
  "ownerId": "e4ab4157-8970-4169-90fb-b88d788a124c",
  "title": "Hỏi về bài tập chấm điểm",
  "activeTaskId": null,
  "createdAt": "2026-11-01T10:30:00Z",
  "updatedAt": "2026-11-01T10:30:00Z"
}
```

---

### 3.2 `listConversations` — Lấy danh sách cuộc hội thoại

**Vị trí:** `ChatController.listConversations(...)` → `ConversationService.listConversations(...)`

**Endpoint:** `GET /api/v1/ai/conversations`

**Header đầu vào:** `UserPrincipal`

**Query params:**
| Param | Kiểu | Bắt buộc | Mặc định | Mô tả |
|-------|------|----------|----------|-------|
| `page` | int | — | 0 | Trang (0-based) |
| `size` | int | — | 20 | Kích thước trang |

**Luồng xử lý:**
1. Controller tạo `Pageable` với `PageRequest.of(page, size)`.
2. Gọi `conversationService.listConversations(principal, pageable)`.
3. Trả về `ResponseEntity.ok(Page<ConversationResponse>)`.

**Ví dụ request:**
```http
GET /api/v1/ai/conversations?page=0&size=20
```

**Ví dụ response (200):** `Page<ConversationResponse>`.

---

### 3.3 `getConversation` — Xem chi tiết cuộc hội thoại

**Vị trí:** `ChatController.getConversation(...)` → `ConversationService.getConversation(...)`

**Endpoint:** `GET /api/v1/ai/conversations/{id}`

**Path variable:** `id` (UUID) — ID cuộc hội thoại

**Header đầu vào:** `UserPrincipal`

**Luồng xử lý:**
1. Controller gọi `conversationService.getConversation(principal, id)`.
2. Service kiểm tra sở hữu conversation (chủ sở hữu mới xem được).
3. Trả về `ResponseEntity.ok(ConversationResponse)`.

**Ví dụ request:**
```http
GET /api/v1/ai/conversations/a1b2c3d4-...
```

**Ví dụ response (200):** `ConversationResponse`.

**Mã lỗi:** `404` nếu conversation không tồn tại hoặc không thuộc về người gọi.

---

### 3.4 `updateConversationTitle` — Cập nhật tiêu đề cuộc hội thoại

**Vị trí:** `ChatController.updateConversationTitle(...)` → `ConversationService.updateTitle(...)`

**Endpoint:** `PUT /api/v1/ai/conversations/{id}`

**Path variable:** `id` (UUID)

**Header đầu vào:** `UserPrincipal`

**Request body:** `UpdateConversationTitleRequest` (có `title()`)

**Luồng xử lý:**
1. Controller gọi `conversationService.updateTitle(principal, id, request.title())`.
2. Service cập nhật tiêu đề (chủ sở hữu mới được cập nhật).
3. Trả về `ResponseEntity.ok(ConversationResponse)`.

**Ví dụ request:**
```http
PUT /api/v1/ai/conversations/a1b2c3d4-...
Content-Type: application/json

{ "title": "Bài tập CRUD sinh viên" }
```

**Ví dụ response (200):** `ConversationResponse` với tiêu đề mới.

**Mã lỗi:** `404` nếu conversation không tồn tại hoặc không thuộc về người gọi.

---

### 3.5 `deleteConversation` — Xóa cuộc hội thoại

**Vị trí:** `ChatController.deleteConversation(...)` → `ConversationService.deleteConversation(...)`

**Endpoint:** `DELETE /api/v1/ai/conversations/{id}`

**Path variable:** `id` (UUID)

**Header đầu vào:** `UserPrincipal`

**Luồng xử lý:**
1. Controller gọi `conversationService.deleteConversation(principal, id)`.
2. Service xóa conversation (chủ sở hữu mới được xóa).
3. Trả về `ResponseEntity.noContent().build()` (204 No Content, không body).

**Ví dụ request:**
```http
DELETE /api/v1/ai/conversations/a1b2c3d4-...
```

**Ví dụ response (204):** Rỗng.

**Mã lỗi:** `404` nếu conversation không tồn tại hoặc không thuộc về người gọi.

---

### 3.6 `sendMessage` — Gửi tin nhắn mới (kích hoạt agent run)

**Vị trí:** `ChatController.sendMessage(...)` → `ConversationService.sendMessage(...)`

**Endpoint:** `POST /api/v1/ai/conversations/{id}/messages`

**Path variable:** `id` (UUID) — ID cuộc hội thoại

**Header đầu vào:** `UserPrincipal`

**Request body:** `SendMessageRequest` (nội dung tin nhắn)

**Luồng xử lý:**
1. Controller gọi `conversationService.sendMessage(id, principal, request)`.
2. Service:
   - Lưu tin nhắn của người dùng vào conversation.
   - Tạo một `Run` (agent run) mới với status `QUEUED`/`RUNNING`.
   - Bắt đầu agent run bất đồng bộ (LLM phân tích intent, có thể gọi tool, tạo plan/step, ...).
   - Trả về `SendMessageResponse` với `conversationId`, `runId`, `messageId`.
3. Controller trả về `ResponseEntity.status(HttpStatus.ACCEPTED).body(SendMessageResponse)`.

**Ghi chú:** Trả về `202 ACCEPTED` (chấp nhận yêu cầu, xử lý bất đồng bộ). Client có thể theo dõi trạng thái qua `GET /api/v1/ai/runs/{runId}/events` (SSE) hoặc `GET /api/v1/ai/runs/{runId}`.

**Ví dụ request:**
```http
POST /api/v1/ai/conversations/a1b2c3d4-.../messages
Content-Type: application/json

{ "content": "Tôi muốn tạo bài tập quản lý sinh viên với các bước tạo, lấy, sửa, xóa" }
```

**Ví dụ response (202):**
```json
{
  "conversationId": "a1b2c3d4-...",
  "runId": "e5f6g7h8-...",
  "messageId": "i9j0k1l2-..."
}
```

---

### 3.7 `getMessages` — Lấy danh sách tin nhắn

**Vị trí:** `ChatController.getMessages(...)` → `ConversationService.getMessages(...)`

**Endpoint:** `GET /api/v1/ai/conversations/{id}/messages`

**Path variable:** `id` (UUID) — ID cuộc hội thoại

**Header đầu vào:** `UserPrincipal`

**Query params:**
| Param | Kiểu | Bắt buộc | Mặc định | Mô tả |
|-------|------|----------|----------|-------|
| `page` | int | — | 0 | Trang (0-based) |
| `size` | int | — | 50 | Kích thước trang |

**Luồng xử lý:**
1. Controller tạo `Pageable` với `PageRequest.of(page, size)`.
2. Gọi `conversationService.getMessages(id, principal, pageable)`.
3. Trả về `ResponseEntity.ok(Page<MessageResponse>)`.

**Ví dụ request:**
```http
GET /api/v1/ai/conversations/a1b2c3d4-.../messages?page=0&size=50
```

**Ví dụ response (200):** `Page<MessageResponse>`.

---

## 4. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 404 | Cuộc hội thoại không tồn tại / không thuộc người gọi | `ConversationService` |
| 401/403 | Chưa xác thực / không có quyền | Spring Security (gateway + `@AuthenticationPrincipal`) |
| 202 | Yêu cầu gửi tin nhắn đã được chấp nhận, đang xử lý bất đồng bộ | `ChatController.sendMessage` |

---

## 5. Luồng dữ liệu từ đầu đến cuối (ví dụ sinh viên gửi tin nhắn tạo bài tập)

```
Sinh viên (FE)
   │ POST /api/v1/ai/conversations/{id}/messages
   │    body: { "content": "Tôi muốn tạo bài tập quản lý sinh viên..." }
   │    (UserPrincipal từ JWT: userId = e4ab4157-...)
   ▼
ai-assistant-service: ChatController.sendMessage()
   │ 1. Nhận UserPrincipal, conversationId, SendMessageRequest
   │ 2. Gọi ConversationService.sendMessage(id, principal, request)
   ▼
ConversationService.sendMessage()
   │ 3. Lưu tin nhắn user vào conversation
   │ 4. Tạo Run mới (status QUEUED/RUNNING)
   │ 5. Bắt đầu agent run bất đồng bộ (AgentOrchestrator/AgentRuntime)
   │    - LLM phân tích intent tiếng Việt
   │    - Có thể gọi tool (course-service API, ...)
   │    - Tạo plan/step config (nếu lecturer hỏi tạo bài tập)
   │    - Hỏi lecturer xác nhận trước khi lưu ("hỏi giảng viên trước... giảng viên muốn tạo hết cho thì mới nhấn lưu")
   │ 6. Trả về SendMessageResponse{conversationId, runId, messageId}
   ▼
ChatController.sendMessage()
   │ 7. Trả về 202 ACCEPTED + SendMessageResponse
   ▼
FE nhận runId, có thể theo dõi tiến độ qua SSE:
   │ GET /api/v1/ai/runs/{runId}/events (SSE)
   │ GET /api/v1/ai/runs/{runId} (xem status)
   ▼
Agent run hoàn thành → FE hiển thị phản hồi của AI (có thể là JSON config để lecturer xem xét, hoặc thông báo đã tạo plan/step)
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/ai-assistant-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
