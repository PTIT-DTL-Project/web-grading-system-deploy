# Tài liệu chi tiết luồng API — api-gateway / AuthenticationContextFilter

Nơi lưu: `docs/api/docs/api-gateway/authentication-context-filter.md`

Mục đích: giải thích chi tiết filter `AuthenticationContextFilter` của service `api-gateway`, bao gồm input, output, luồng xử lý, ví dụ, và mã lỗi. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`AuthenticationContextFilter` là `GlobalFilter` của service `api-gateway`, chạy **sau** Spring Security đã xác thực JWT (order = 0, sau security filter chain tại -100). Nó trích xuất danh tính người dùng từ `Jwt` đã được xác thực và inject vào HTTP request header dưới dạng `X-User-*` cho các microservice phía sau gateway, cùng với `X-Gateway-Secret` để các service tin tưởng header đã đến từ gateway.

Bảo mật: mọi header `X-User-*` và `X-Gateway-Secret` gửi từ client bị **bỏ hoàn toàn (stripped)** trước khi xét principal — người dùng không bao giờ có thể giả mạo danh tính bằng cách gửi header giả. Nếu không có principal được xác thực (chưa đăng nhập), exchange được forwarded không có header (downstream sẽ từ chối 401 nếu thiếu `X-Gateway-Secret`).

| Thành phần | Mô tả |
|------------|-------|
| Base path | Áp dụng cho mọi route qua gateway |
| Order | 0 (chạy sau Spring Security, trước custom filter khác) |
| Nguyên liệu | `JwtAuthenticationToken` (đã được Spring Security xác thực) |
| Header đầu ra | `X-User-Id`, `X-User-Email`, `X-User-FirstName`, `X-User-LastName`, `X-User-Roles`, `X-Gateway-Secret` |

---

## 2. Chi tiết từng hàm

### 2.1 `filter` — Điểm vào chính của GlobalFilter

**Vị trí:** `AuthenticationContextFilter.filter(ServerWebExchange, GatewayFilterChain)`

**Input:** `ServerWebExchange exchange`, `GatewayFilterChain chain`

**Output:** `Mono<Void>`

**Luồng xử lý:**

1. **Strip header giả:** Xoá tất cả header `X-User-Id`, `X-User-Email`, `X-User-FirstName`, `X-User-LastName`, `X-User-Roles`, `X-Gateway-Secret` khỏi request đến từ client — đảm bảo người dùng không bao giờ truyền header danh tính giả mạo.
2. **Lấy principal:** `exchange.getPrincipal()` → lọc chỉ khi là `JwtAuthenticationToken` → ép kiểu `JwtAuthenticationToken` → lấy `Jwt` từ `jwtAuth.getToken()`.
3. **Nếu không có principal:** `defaultIfEmpty(cleaned)` → forward exchange đã được strip (không có header danh tính) → downstream sẽ từ chối nếu cần authentication.
4. **Nếu có principal:** Gọi `withIdentity(cleaned, jwt)` để inject header danh tính và trust secret.
5. **Tiếp tục chain:** `chain.filter(...)` forward exchange đã sửa sang xuống service phía sau.

**Ví dụ request (trước filter, client gửi):**
```http
GET /api/v1/results/student/assignment/uuid-here
X-User-Id: attacker-uuid  <-- bị strip
Authorization: Bearer <jwt>
```

**Ví dụ request (sau filter, gửi xuốngstream):**
```http
GET /api/v1/results/student/assignment/uuid-here
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
X-User-Email: gv002@ptit.edu.vn
X-User-FirstName: Nguyễn Văn
X-User-LastName: A
X-User-Roles: LECTURER
X-Gateway-Secret: <trusted-secret>
Authorization: Bearer <jwt>
```

---

### 2.2 `withIdentity` — Inject danh tính vào request

**Vị trí:** `AuthenticationContextFilter.withIdentity(ServerWebExchange, Jwt)`

**Input:** `ServerWebExchange exchange`, `Jwt jwt` (đã xác thực)

**Output:** `ServerWebExchange` (đã có header danh tính được inject)

**Luồng xử lý:**

1. **Kiểm tra `gateway.security.secret`:** Nếu secret trống → log lỗi một lần → trả về `exchange` không có header (downstream sẽ trả 401).
2. **Trích xuất claims từ JWT:**
   - `userId = jwt.getSubject()` → `sub` claim
   - `email = jwt.getClaimAsString("email")`
   - `firstName = jwt.getClaimAsString("firstName")` ← **mới**
   - `lastName = jwt.getClaimAsString("lastName")` ← **mới**
3. **Xây dựng request builder:** Inject các header:
   - `X-User-Id`: giá trị `userId` hoặc rỗng nếu null
   - `X-User-Email`: giá trị `email` hoặc rỗng nếu null
   - `X-User-FirstName`: giá trị `firstName` hoặc rỗng nếu null ← **mới**
   - `X-User-LastName`: giá trị `lastName` hoặc rỗng nếu null ← **mới**
   - `X-Gateway-Secret`: giá trị `properties.secret()`
4. **Lấy roles:** `allowedRealmRoles(jwt)` → nếu không null → inject `X-User-Roles`.
5. **Trả về exchange đã sửa.**

**Tham chiếu:** `jwt.getClaimAsString("firstName")` và `jwt.getClaimAsString("lastName")` đọc các claim mà Keycloak đã đưa vào access token qua Protocol Mapper (xem mục 6 cấu hình Keycloak).

---

### 2.3 `allowedRealmRoles` — Lọc roles từ JWT

**Vị trí:** `AuthenticationContextFilter.allowedRealmRoles(Jwt)`

**Input:** `Jwt jwt`

**Output:** `String` (danh sách roles cách nhau bởi dấu phẩy) hoặc `null`

**Luồng xử lý:**

1. Lấy danh sách role được phép từ `GatewayTrustProperties.allowedRoles()`. Nếu null/trống → trả về `null`.
2. Đọc claim `realm_access` từ JWT (dạng `Map`). Nếu null → trả về `null`.
3. Lấy giá trị `roles` từ map (phải là `Collection`). Nếu sai kiểu → trả về `null`.
4. Lọc: chỉ giữ role nằm trong allowlist, trim, distinct.
5. Nếu danh sách rỗng → trả về `null`. Ngược lại → trả về chuỗi cách nhau bởi `,`.

**Mục đích:** Đảm bảo downstream chỉ nhận được roles đã được gateway whitelist, tránh người dùng tự gán role `LECTURER` qua header.

---

## 3. DTO liên quan

Không có DTO riêng — filter đọp claims trực tiếp từ `Jwt` (Spring Security OAuth2) và inject vào `ServerHttpRequest` headers.

---

## 4. Mã lỗi / xử lý ngoại lệ

| Trường hợp | Hành vi |
|------------|---------|
| `gateway.security.secret` trống | Log lỗi 1 lần, forward không có header, downstream trả 401 |
| Không có `JwtAuthenticationToken` (chưa đăng nhập) | Forward exchange đã strip, không có header `X-User-*`, downstream `@PreAuthorize` sẽ thất bại |
| Claim `firstName`/`lastName` không có trong JWT | Inject header rỗng (`""`), downstream có thể xử lý giá trị rỗng |
| Claim `realm_access` sai kiểu hoặc thiếu | `allowedRealmRoles` trả về `null`, không inject `X-User-Roles` |

---

## 5. Cấu hình Keycloak (bắt buộc để `firstName`/`lastName` có trong JWT)

Để filter đọc được `firstName` và `lastName` từ JWT, cần cấu hình Keycloak realm như sau:

### 5.1 Tạo Client Scope
Vào **Keycloak Admin Console** → **Client Scopes** → **Create client scope**:

| Trường | Giá trị |
|--------|---------|
| Name | `user-name-profile` |
| Description | Profile claims for JWT |
| Type | `None` |
| Protocol | `OpenID Connect` |
| Display on consent screen | `On` |
| **Include in token scope** | **`On`** (bắt buộc) |

### 5.2 Thêm Protocol Mapper (2 mapper)

**Mapper 1 — `firstName`:**
- Mapper Type: `User Attribute`
- Name: `first-name-claim`
- User Attribute: `firstName`
- Claim Name: `firstName`
- JSON Type: `String`
- Add to access token: ✅ `On`

**Mapper 2 — `lastName`:**
- Mapper Type: `User Attribute`
- Name: `last-name-claim`
- User Attribute: `lastName`
- Claim Name: `lastName`
- JSON Type: `String`
- Add to access token: ✅ `On`

### 5.3 Gán scope cho client
Vào **Clients** → `web-grading-fe` → tab **Client Scopes** → thêm `user-name-profile` vào **Default scopes**.

---

## 6. Luồng dữ liệu từ đầu đến cuối (ví dụ người dùng gọi API xem kết quả bài tập)

```
Người dùng (FE, có Bearer JWT)
   │ GET /api/v1/results/student/assignment/{assignmentId}
   │    Authorization: Bearer <jwt có claims sub, email, firstName, lastName, realm_access.roles>
   ▼
API Gateway: AuthenticationContextFilter.filter()
   │ 1. Strip mọi header X-User-* và X-Gateway-Secret từ request đến từ client
   │ 2. Lấy principal → JwtAuthenticationToken → Jwt
   │ 3. Gọi withIdentity(): trích xuất sub, email, firstName, lastName, realm_access.roles
   │ 4. Inject headers: X-User-Id, X-User-Email, X-User-FirstName, X-User-LastName, X-User-Roles, X-Gateway-Secret
   ▼
Result-service (hoặc course-service, executor-service, …)
   │ Nhận request đã header X-User-Id, X-User-FirstName, X-User-LastName, …
   │ Xác thực X-Gateway-Secret → tin tưởng danh tính
   │ Xử lý nghiệp vụ (xem kết quả bài tập, v.v.)
   ▼
Trả về phản hồi cho FE
```

---

*Tài liệu này là phần của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/api-gateway/`. Cập nhật theo AGENTS.md khi thêm/thay đổi controller, endpoint, hoặc hàm client-facing.*
