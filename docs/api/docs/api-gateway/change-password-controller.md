# Tài liệu chi tiết luồng API — api-gateway / ChangePasswordController

Nơi lưu: `docs/api/docs/api-gateway/change-password-controller.md`

Mục đích: giải thích chi tiết endpoint đổi mật khẩu tự phục vụ (self-service change-password, UC-14) của api-gateway, bao gồm input, output, luồng xử lý, ví dụ, và mã lỗi. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`ChangePasswordController` là REST controller của service `api-gateway`, trỏ về base path `/api/v1/account`. Nó cung cấp endpoint cho người dùng đổi mật khẩu của mình (xác thực mật khẩu hiện tại rồi đặt mật khẩu mới) thông qua Keycloak Admin API — **không để frontend gọi trực tiếp Keycloak Admin API** (tránh rò rỉ admin secret vào browser bundle).

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/account/change-password` | POST | Đổi mật khẩu (xác thực mật khẩu hiện tại → tra cứu user → đặt mật khẩu mới) | Không cần Bearer token (forced password change chưa có token) |

**Đặc điểm quan trọng về bảo mật:**
- Endpoint **có thể truy cập không cần Bearer token** (vì forced password change chưa có token session). Một `SecurityWebFilterChain` riêng covers `/api/v1/account/**` không dùng `oauth2ResourceServer`, nên token hết hạn/h»*
- Tất cả thất bại đều trả về dạng `ApiEnvelope` (kể cả lỗi không mong muốn), để frontend nhận diện được envelope.
- Đăng ký **chỉ khi** `rate-limit.enabled=true` trong `application.yaml` (mặc định `false`). Vốn chưa có gateway-side limiter, nên một déploi không cấu hình **không được hiển thị một oracle xác thực mật khẩu ẩn danh** — endpoint trả 404 cho đến khi déploi chọn vào (và xác nhận realm brute-force protection đã bật).
- Thứ tự chạy負荷: xác thực mật khẩu hiện tại **trước** khi tra cứu user, và "mật khẩu sai" và "không có user" trả **cùng mã** `current_password_invalid` — người gọi chưa xác thực không bao giờ biết tên user có tồn tại trong realm hay không (tránh user enumeration).

Controller giao tiếp với `PasswordChangeService` để thực hiện logic nghiệp vụ 4 bước.

---

## 2. DTO liên quan

### 2.1 `ChangePasswordRequest` (dto/web, record)
Thân yêu cầu đổi mật khẩu.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `username` | String | `@NotBlank` | Tên đăng nhập (hoặc email — realm cho phép login bằng email) |
| `currentPassword` | String | `@NotBlank` | Mật khẩu hiện tại |
| `newPassword` | String | `@NotBlank` | Mật khẩu mới |

Có named factory `of(...)` để tránh viết positional constructor >2 tham chiếu (theo quy ước dự án).

### 2.2 `ApiEnvelope` (dto/web, record)
Thân phản hồi duy nhất của endpoint này (ngoài `204 No Content`). Frontend nhận diện envelope qua `keys ⊆ {status,message,data,error}` với `status` là số.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `status` | int | HTTP status (gần mirror vào body, frontend đọc từ hoặc) |
| `message` | String | Mã máy (machine code) frontend map sang i18n, **không phải câu văn để hiển thị thô**. Các mã: `current_password_invalid`, `weak_password`, `validation_failed`, `identity_provider_unavailable` |
| `data` | Object | Dữ liệu kèm (thường là null cho lỗi) |

Phương thức tĩnh `error(HttpStatus status, String message)` tạo envelope với `data = null`.

---

## 3. Chi tiết từng hàm

### 3.1 `changePassword` — Đổi mật khẩu

**Vị trí:** `ChangePasswordController.changePassword(...)` → `PasswordChangeService.changePassword(...)`

**Endpoint:** `POST /api/v1/account/change-password`

**Request body:** `ChangePasswordRequest`

**Luồng xử lý (Controller → Service):**

1. **Controller:** Nhận `ChangePasswordRequest request` (đã `@Valid` — Spring Framework 7 validate handler argument). Gọi `passwordChangeService.changePassword(request)` (trả về `Mono<Void>`), sau đó `then(Mono.fromSupplier(() -> ResponseEntity.noContent().build()))` → trả về `204 No Content` khi thành công.
2. **Service `PasswordChangeService.changePassword` (4 bước theo UC-14):**
   - **Bước 0 — Kiểm tra trường bắt buộc:** Nếu `username`, `currentPassword`, hoặc `newPassword` thiếu/blank → ném `ChangePasswordException.validationFailed()` (mã `validation_failed`, status 400).
   - **Bước 1 — Xác thực mật khẩu hiện tại:** `keycloak.verifyPassword(request.username(), request.currentPassword())`. Nếu Keycloak không khả dụng → `ChangePasswordException.identityProviderUnavailable(cause)` (mã `identity_provider_unavailable`, status 502). Nếu mật khẩu **sai** → ném `ChangePasswordException.currentPasswordInvalid()` (mã `current_password_invalid`, status 400).
   - **Bước 2 — Tra cứu user:** `keycloak.findUserId(request.username())`. Nếu không tìm thấy (`switchIfEmpty`) → ném **cùng mã** `current_password_invalid` (để người gọi chưa xác thực không biết user có tồn tại hay không). Nếu Keycloak lỗi → `identity_provider_unavailable`.
   - **Bước 3 — Đặt mật khẩu mới:** `keycloak.resetPassword(userId, request.newPassword())`. Nếu Keycloak lỗi → `identity_provider_unavailable`. Nếu Keycloak trả `applied = false` (mật khẩu mới không đạt password policy của realm) → ném `ChangePasswordException.weakPassword()` (mã `weak_password`, status 400). Nếu thành công (`applied = true`) → trả về `Mono.empty()`.

**Thứ tự chạy負荷:** `verifyCurrentPassword` chạy **trước** `lookupAndReset` — người gọi chưa chứng thực không bao giờ tra cứu được realm.

**Ví dụ request:**
```http
POST /api/v1/account/change-password
Content-Type: application/json

{
  "username": "b22dckh024",
  "currentPassword": "oldPassword123",
  "newPassword": "NewPassword456"
}
```

**Ví dụ response (204):** Rỗng (không body) — thành công.

**Ví dụ response (400, mật khẩu sai/user không tồn tại):**
```json
{
  "status": 400,
  "message": "current_password_invalid",
  "data": null
}
```

**Ví dụ response (400, mật khẩu mới yếu):**
```json
{
  "status": 400,
  "message": "weak_password",
  "data": null
}
```

**Ví dụ response (400, thiếu trường):**
```json
{
  "status": 400,
  "message": "validation_failed",
  "data": null
}
```

**Ví dụ response (502, Keycloak không khả dụng):**
```json
{
  "status": 502,
  "message": "identity_provider_unavailable",
  "data": null
}
```

**Mã lỗi (qua `@ExceptionHandler`):**

| Mã | Nguyên nhân | Ném từ / Xử lý bởi |
|----|-------------|---------------------|
| 400 | `current_password_invalid` — mật khẩu hiện tại sai **hoặc** user không tồn tại (cùng mã) | `ChangePasswordException.currentPasswordInvalid()` → `handleChangePassword` |
| 400 | `weak_password` — mật khẩu mới không đạt policy realm | `ChangePasswordException.weakPassword()` → `handleChangePassword` |
| 400 | `validation_failed` — trường thiếu/blank | `ChangePasswordException.validationFailed()`, `HandlerMethodValidationException`, `ServerWebInputException` |
| 502 | `identity_provider_unavailable` — Keycloak không khả dụng | `ChangePasswordException.identityProviderUnavailable(cause)` → `handleChangePassword` |
| 500 | Lỗi không mong muốn (safety net) | `handleUnexpected` → `internal_error` |

---

## 4. Các `@ExceptionHandler` trong controller

| Handler | Xử lý |
|---------|-------|
| `handleChangePassword(ChangePasswordException ex)` | Trả về envelope với `status = ex.status()`, `message = ex.code()`. Cause được log để chẩn đoán, không gửi tới client. |
| `handleValidation(HandlerMethodValidationException ex)` | Trả về `validation_failed`, status 400. |
| `handleUnreadableBody(ServerWebInputException ex)` | Trả về `validation_failed`, status 400 (JSON không đọc được / thiếu body). |
| `handleUnexpected(Exception ex)` | Safety net: log error, trả về `internal_error`, status 500 — để envelope shape vẫn được bảo toàn (Spring default error body có keys frontend không nhận diện). |

---

## 5. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 400 | `current_password_invalid`: mật khẩu sai hoặc user không tồn tại | `ChangePasswordException.currentPasswordInvalid()` |
| 400 | `weak_password`: mật khẩu mới không đạt policy | `ChangePasswordException.weakPassword()` |
| 400 | `validation_failed`: thiếu trường / JSON không hợp lệ | `ChangePasswordException.validationFailed()` / validation handler |
| 502 | `identity_provider_unavailable`: Keycloak không khả dụng | `ChangePasswordException.identityProviderUnavailable()` |
| 500 | Lỗi không mong muốn | `handleUnexpected` |

---

## 6. Luồng dữ liệu từ đầu đến cuối (ví dụ người dùng đổi mật khẩu)

```
Người dùng (FE, chưa có token vì forced change)
   │ POST /api/v1/account/change-password
   │    body: { username, currentPassword, newPassword }
   ▼
Gateway: ChangePasswordController.changePassword()
   │ 1. Nhận ChangePasswordRequest (đã @Valid)
   │ 2. Gọi PasswordChangeService.changePassword(request)
   ▼
PasswordChangeService.changePassword()
   │ 3. Kiểm tra 3 trường không blank (validation_failed nếu thiếu)
   │ 4. verifyCurrentPassword(username, currentPassword) → Keycloak verifyPassword
   │    - Sai → current_password_invalid (400)
   │    - Keycloak lỗi → identity_provider_unavailable (502)
   │ 5. lookupAndReset: findUserId(username)
   │    - Không tìm thấy → current_password_invalid (400, cùng mã với sai mật khẩu)
   │    - Tìm thấy → resetPassword(userId, newPassword)
   │       - Mới yếu → weak_password (400)
   │       - Thành công → Mono.empty()
   │ 6. Trả về Mono<Void> thành công
   ▼
ChangePasswordController.changePassword()
   │ 7. Trả về 204 No Content (không body)
   ▼
FE nhận 204 → cho phép người dùng đăng nhập lại bằng mật khẩu mới
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/api-gateway/`. Tiếp theo sẽ viết tài liệu cho `UserImportController`.*
