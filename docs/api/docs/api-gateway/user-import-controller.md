# Tài liệu chi tiết luồng API — api-gateway / UserImportController

Nơi lưu: `docs/api/docs/api-gateway/user-import-controller.md`

Mục đích: giải thích chi tiết endpoint nhập bulk tài khoản người dùng (bulk account import, UC-17) của api-gateway, bao gồm input, output, luồng xử lý, ví dụ, và mã lỗi. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`UserImportController` là REST controller của service `api-gateway`, trỏ về base path `/api/v1/admin/users`. Nó cung cấp endpoint nhập hàng loạt tài khoản từ file CSV — một dòng CSV tạo một user Keycloak (sinh viên hoặc giảng viên) với mật khẩu tạm thời và bắt buộc đổi mật khẩu khi đăng nhập lần đầu (`UPDATE_PASSWORD`).

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/admin/users/import` | POST (multipart/form-data) | Nhập bulk tài khoản từ file CSV | Chỉ ADMIN |

**Đặc điểm quan trọng về bảo mật:**
- Endpoint **chỉ ADMIN** qua kiểm tra trong handler (`isAdmin(...)`) — gateway không có `@PreAuthorize` cho routes của mình (roles được stamp cho downstream services), nên kiểm tra này nằm ở controller để có thể kiểm tra kiểm toán.
- Việc bulk-create lecturer là lý do endpoint này chỉ admin — một `LECTURER` không bao giờ được tạo tài khoản cao hơn quyền của mình qua endpoint này.
- Giữ resource server (token cũ/stale trả `401` trước khi handler chạy) và trả mọi thất bại — kể cả thất bại授權 — dưới dạng `ApiEnvelope`.
- CSV fields: `username, fullName, email, role?` — `role` là `STUDENT` hoặc `LECTURER` (tuỳ chọn, chấp nhận tiền tố `ROLE_`), blank có nghĩa là `STUDENT` (mặc định an toàn: quyền thấp hơn). Giá trị role không xác định làm lỗi dòng đó, không làm lỗi toàn bộ batch.

Controller giao tiếp với `UserImportService` để thực hiện logic nghiệp vụ.

---

## 2. DTO liên quan

### 2.1 `ApiEnvelope` (dto/web, record)
Thân phản hồi của endpoint.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `status` | int | HTTP status |
| `message` | String | Thông điệp (ví dụ `"success"`, hoặc mã máy `"forbidden"`, `"validation_failed"`, `"internal_error"`) |
| `data` | Object | Dữ liệu kèm — khi thành công là `ImportSummary` |

### 2.2 `UserImportService.ImportSummary` (record, nội bộ)
Báo cáo kết quả import batch.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `created` | `Map<String, Integer>` | Số lượng tạo thành công theo từng role (`STUDENT`, `LECTURER`) |
| `skipped` | int | Số dòng bị bỏ qua (trùng username có password, trùng email) |
| `failed` | `List<RowResult>` | Danh sách dòng thất bại |

### 2.3 `UserImportService.RowResult` (record, nội bộ)
Kết quả của một dòng CSV.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `row` | int | Số dòng (1-based) |
| `username` | String | Tên đăng nhập |
| `role` | String | Vai trò |
| `outcome` | String | `created` / `skipped` / `failed` |
| `reason` | String | Lý do (nếu skipped/failed) |

---

## 3. Chi tiết hàm `importUsers`

**Vị trí:** `UserImportController.importUsers(...)` → `UserImportService.importUsers(...)`

**Endpoint:** `POST /api/v1/admin/users/import` (consumes `multipart/form-data`)

**Request part:**
| Part | Kiểu | Bắt buộc | Mô tả |
|------|------|----------|-------|
| `file` | `FilePart` | ✅ | File CSV nhập tài khoản |

**Header đầu vào:** `JwtAuthenticationToken` (từ Spring Security, gateway inject từ JWT)

**Luồng xử lý (Controller → Service):**

1. **Controller:**
   - Nhận `JwtAuthenticationToken authentication` và `FilePart file`.
   - Gọi `isAdmin(authentication)`:
     - Nếu `authentication == null` → `false`.
     - Lấy `Jwt jwt = authentication.getToken()`.
     - Lấy `realmAccess = jwt.getClaimAsMap("realm_access")`. Nếu null → `false`.
     - Lấy `roles = realmAccess.get("roles")`. Nếu không phải `List<?>` → `false`.
     - Duyệt roles, chuẩn hóa (bỏ tiền tố `ROLE_` nếu có), kiểm tra có `"ADMIN"` nào không. Nếu có → `true`.
   - Nếu không phải admin → trả về `ResponseEntity.status(HttpStatus.FORBIDDEN).body(ApiEnvelope.error(403, "forbidden"))`.
   - Nếu admin → gọi `userImportService.importUsers(file)`.
   - `map(summary -> ResponseEntity.ok(new ApiEnvelope(200, "success", summary)))` → trả về `200 OK` với envelope chứa `ImportSummary`.

2. **Service `UserImportService.importUsers(FilePart file)`:**
   - **Bước 1 — Kiểm tra file:** Lấy `fileName = file.filename()`. Nếu null hoặc không kết thúc bằng `.csv` (không phân biệt hoa thường) → ném `UserImportException.validationFailed()` (mã `validation_failed`, status 400).
   - **Bước 2 — Đọc bytes:** `readBytes(file)` → đọc toàn bộ nội dung file vào `byte[]`. Trong quá trình đọc, nếu tổng kích thước > `MAX_BYTES` (2 MB) → ném `UserImportException.fileTooLarge()` (mã `file_too_large`, status 400). Nếu bytes rỗng → `validationFailed()`.
   - **Bước 3 — Parse CSV:** `parseCsv(bytes)` → `List<String[]>`.
     - Chia dòng theo `\r?\n`, bỏ qua dòng trống.
     - Chia cột theo dấu phẩy (`,`), không dùng thư viện trích dẫn (dependency-free).
     - Dòng đầu tiên nếu cột đầu là `username`, `studentcode`, hoặc `code` (không phân biệt hoa thường) → coi là header, bỏ qua.
     - Giới hạn `MAX_ROWS` (2000 dòng). Nếu quá → ném `UserImportException.tooManyRows()` (mã `too_many_rows`, status 400).
   - **Bước 4 — Chạy import:** `runImport(rows)`:
     - Tạo `KeycloakAdminClient.BulkOperations admin = keycloak.bulk()` (một admin token chung cho toàn bộ batch, session memoize nó).
     - Tạo `roleCache` (map role → realm role representation), giải quyết lazy: import chỉ sinh viên không bao giờ đụng đến `ROLE_LECTURER`, nên vắng mặt hoặc không đọc được không làm abort batch.
     - Duyệt các dòng qua `Flux.fromIterable(rows).index().flatMap(..., 3)` (tối đa 3 dòng cùng lúc — tránh Keycloak đơn node trả 400/500/connection reset khi quá 10 concurrently).
     - Thu thập danh sách `RowResult`, gọi `summarize(...)` → `ImportSummary`.
   - **Bước 5 — Xử lý mỗi dòng (`importRow`):**
     - Nếu `cols.length < 3` → `failed` với lý `not_enough_columns`.
     - Chuẩn hóa `username = cols[0].trim().toLowerCase()` (Keycloak lưu username lowercase nhưng giữ password nguyên vẻ — import "B22DCCN001" tạo user `b22dccn001` với password `B22DCCN001` — khó đoán).
     - `fullName = cols[1].trim()`, `email = cols[2].trim()`.
     - Nếu `username` hoặc `email` blank → `failed` với lý `blank_username_or_email`.
     - `role = normalizeRole(cols[3] nếu có)`. Nếu role null (giá trị không xác định) → `failed` với lý `unknown_role` (chỉ fail dòng này, không abort batch).
     - **Tra cứu trùng:**
       - `admin.findUserId(username)`: nếu tìm thấy → `completeOrSkip(...)` (xem dưới).
       - Nếu không (empty): `admin.findUserId(email)`: nếu tìm thấy → `skipped` với lý `duplicate_email`.
       - Nếu cả hai đều không tìm thấy → `roleRep(...)` (lấy realm role rep) → `createAndProvision(...)` (tạo user, đặt mật khẩu tạm = username, gán realm role).
     - Xử lý lỗi provider: nếu lỗi là `UserImportException` → ném lại (lỗi file-level). Ngược lại → `failed` với lý `provider_error`.
   - **Bước 6 — Hoàn thành hoặc bỏ qua dòng trùng (`completeOrSkip`):**
     - `admin.hasPassword(userId)`: nếu đã có password → `skipped` với lý `duplicate_username` (tài khoản từ import trước đã có password).
     - Nếu chưa có password (tài liệu bán thành công từ lần import trước bị giữa chừng) → `roleRep(...)` → `setTemporaryPassword(userId, username)` → `assignRealmRoles(userId, [rep])` → `created` (lần này là lần làm cho tài khoản có thể dùng).
   - **Bước 7 — Tạo mới và cung cấp (`createAndProvision`):**
     - Tách tên: `splitName(fullName)` → `[firstName, lastName]` (token đầu tiên là họ/family name = lastName, phần còn lại là tên = firstName). Single token fills both. Blank fills neither → caller fallback sang username cho cả hai.
     - `admin.createUser(username, email, firstName, lastName)`: realm user profile yêu cầu non-blank firstName AND lastName.
     - Nếu `createUser` trả 409 → `skipped` với lý `duplicate_username` (race condition). Nếu 400 → `failed` với lý `invalid_input`. Ngược lại → `provider_error`.
     - Nếu tạo thành công → `setTemporaryPassword(userId, username)` → nếu `applied = false` → `failed` (`weak_password`). Nếu thành công → `assignRealmRoles(userId, [roleRep])` → `created`; nếu gán role thất bại → `failed` (`role_not_assigned`, tài khoản đã có password nhưng có thể chưa có role — re-run sẽ bị skip là duplicate_username, báo cáo phải mô tả chính xác khoảng trống để sửa thủ công).
   - **Bước 8 — Tóm tắt (`summarize`):**
     - Duyệt các `RowResult`: `created` → cộng vào `created[role]`; `skipped` → tăng `skipped`; `failed` → thêm vào danh sách `failed`.
     - Trả về `ImportSummary(created, skipped, failed)`.

**Lưu ý về lỗi hàng dòng:** Lỗi hàng dòng **không bao giờ** làm abort toàn bộ batch — mỗi dòng thất bại landed vào báo cáo (`failed`), batch tiếp tục xử lý các dòng còn lại. Chỉ lỗi file-level (unreadable, over caps, wrong extension, empty) và authorization failure mới làm abort toàn bộ request.

**Ví dụ request (multipart/form-data):**
```http
POST /api/v1/admin/users/import
Authorization: Bearer <admin-jwt-token>
Content-Type: multipart/form-data

file: (file CSV)
```

**Nội dung file CSV mẫu:**
```
username,fullName,email,role
b22dckh024,Nguyen Van A,nguyenvana@example.com,STUDENT
b22dckh025,Tran Thi B,tranthib@example.com,LECTURER
```

**Ví dụ response (200, thành công):**
```json
{
  "status": 200,
  "message": "success",
  "data": {
    "created": { "STUDENT": 1, "LECTURER": 1 },
    "skipped": 0,
    "failed": []
  }
}
```

**Ví dụ response (200, có dòng thất bại):**
```json
{
  "status": 200,
  "message": "success",
  "data": {
    "created": { "STUDENT": 1, "LECTURER": 0 },
    "skipped": 0,
    "failed": [
      { "row": 3, "username": "badrole", "role": "INVALID", "outcome": "failed", "reason": "unknown_role" }
    ]
  }
}
```

**Ví dụ response (403, không phải admin):**
```json
{
  "status": 403,
  "message": "forbidden",
  "data": null
}
```

**Ví dụ response (400, file quá lớn):**
```json
{
  "status": 400,
  "message": "file_too_large",
  "data": null
}
```

**Ví dụ response (400, quá nhiều dòng):**
```json
{
  "status": 400,
  "message": "too_many_rows",
  "data": null
}
```

**Ví dụ response (400, không phải CSV):**
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

**Ví dụ response (500, lỗi không mong muốn):**
```json
{
  "status": 500,
  "message": "internal_error",
  "data": null
}
```

---

## 4. Các `@ExceptionHandler` trong controller

| Handler | Xử lý |
|---------|-------|
| `handleUserImport(UserImportException ex)` | Trả về envelope với `status = ex.status()`, `message = ex.code()`. Cause được log để chẩn đoán, không gửi tới client. |
| `handleUnexpected(Exception ex)` | Safety net: log error, trả về `internal_error`, status 500 — để envelope shape vẫn được bảo toàn. |
| `handleUnreadableBody(ServerWebInputException ex)` | Trả về `validation_failed`, status 400 (multipart không đọc được / thiếu part `file`). |

---

## 5. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 403 | Không phải ADMIN | `isAdmin(...)` → controller trả về trực tiếp |
| 400 | File không phải CSV / thiếu file / JSON multipart không đọc được | `UserImportException.validationFailed()` / `handleUnreadableBody` |
| 400 | File quá lớn (> 2 MB) | `UserImportException.fileTooLarge()` |
| 400 | Quá nhiều dòng (> 2000) | `UserImportException.tooManyRows()` |
| 502 | Keycloak không khả dụng | `UserImportException.identityProviderUnavailable()` |
| 500 | Lỗi không mong muốn | `handleUnexpected` |
| 200 (có `failed[]`) | Một số dòng CSV lỗi (role không xác định, provider lỗi, ...) | `UserImportService` — dòng thất bại landed vào báo cáo, batch tiếp tục |

---

## 6. Luồng dữ liệu từ đầu đến cuối (ví dụ admin nhập bulk tài khoản)

```
Admin (FE)
   │ POST /api/v1/admin/users/import
   │    Authorization: Bearer <admin-jwt>
   │    Content-Type: multipart/form-data
   │    file: users.csv (username,fullName,email,role)
   ▼
api-gateway: UserImportController.importUsers()
   │ 1. Nhận JwtAuthenticationToken, FilePart file
   │ 2. Gọi isAdmin(authentication) → kiểm tra realm_access.roles có "ADMIN"
   │ 3. Nếu không phải admin → trả về 403 {forbidden}
   │ 4. Gọi UserImportService.importUsers(file)
   ▼
UserImportService.importUsers()  (@Service)
   │ 5. Kiểm tra file tên kết thúc .csv, không rỗng, ≤ 2MB, ≤ 2000 dòng
   │ 6. parseCsv → danh sách dòng (bỏ qua header, dòng trống)
   │ 7. Duyệt từng dòng (tối đa 3 cùng lúc):
   │    - Chuẩn hóa username (lowercase), fullName, email
   │    - Kiểm tra blank → failed
   │    - Kiểm tra role (STUDENT/LECTURER, optional ROLE_ prefix) → failed nếu không xác định
   │    - findUserId(username) → có: completeOrSkip (đã có password → skipped duplicate_username; chưa có password → đặt temporary password + gán role → created)
   │    - findUserId(email) → có → skipped duplicate_email
   │    - Không tìm thấy cả hai → createUser → setTemporaryPassword (=username) → assignRealmRoles → created
   │    - Lỗi hàng dòng → failed (không abort batch)
   │ 8. summarize → ImportSummary{created, skipped, failed}
   │ 9. Trả về ImportSummary
   ▼
UserImportController.importUsers()
   │ 10. Trả về 200 OK { status: 200, message: "success", data: ImportSummary }
   ▼
FE hiển thị báo cáo import (số tạo theo role, số bỏ qua, số thất bại kèm lý do)
```

---

*Tài liệu này là phần cuối cùng của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/api-gateway/`. Tất cả 24 controller/service đã được viết đầy đủ theo plan.*
