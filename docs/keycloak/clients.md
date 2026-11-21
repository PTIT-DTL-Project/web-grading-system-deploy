# Client Keycloak của hệ thống (realm `ptit-wgs`)

Tài liệu này liệt kê toàn bộ client trong realm `ptit-wgs`, mỗi client dùng ở đâu, theo luồng nào,
và những điểm phải giữ đúng khi thay đổi cấu hình xác thực.

Nguồn dữ liệu: `src-services/keycloak/realm-export.json` (bản export đầy đủ của realm),
`src-services/api-gateway/src/main/resources/application.yaml`,
`frontend-src/web-grading-system-fe/.env.example`.
Quy ước chi tiết hơn về Keycloak nằm ở `.opencode/skills/keycloak/SKILL.md`.

## 1. Tổng quan

| Client | Loại | Grant đang bật | Dùng ở đâu |
|---|---|---|---|
| `account` | public | standard flow | Trang tự phục vụ của người dùng (Keycloak tự sinh) |
| `account-console` | public, PKCE S256 | standard flow | Giao diện mới của trang account |
| `security-admin-console` | public, PKCE S256 | standard flow | Admin Console của realm |
| `admin-cli` | public | direct access grant | Thao tác tay bằng CLI/Admin API |
| `broker` | confidential | standard flow | Liên kết đăng nhập nhà cung cấp ngoài (không dùng) |
| `realm-management` | confidential | standard flow | Chứa các role quản trị realm |
| `web-grading-fe` | public, PKCE S256 | standard flow | Giao diện React của sinh viên và giảng viên |
| `wgs-password-verify` | confidential | direct access grant | Gateway xác minh mật khẩu hiện tại |
| `wgs-user-service` | confidential, service account | client credentials | Gateway gọi Keycloak Admin API |
| `wgs-postman` | public | standard flow + direct access grant | Lấy token khi kiểm thử API bằng Postman |

## 2. Client do Keycloak tự sinh

Sáu client dưới đây có sẵn khi tạo realm, không phải client nghiệp vụ nhưng vẫn xuất hiện trong
realm và có thể ảnh hưởng đến luồng đăng nhập.

- **`account`** - trang tự phục vụ: xem và sửa hồ sơ, đổi mật khẩu, xem phiên đăng nhập. Đây là nơi
  người dùng bị đưa tới khi vướng required action `UPDATE_PASSWORD` hoặc `VERIFY_EMAIL`, và cũng là
  trang hiện ra sau khi import CSV bắt buộc đổi mật khẩu ở lần đăng nhập đầu.
- **`account-console`** - giao diện mới của trang account, dùng PKCE `S256`.
- **`security-admin-console`** - Admin Console (`/admin/ptit-wgs/console/`), dùng PKCE `S256`.
- **`admin-cli`** - client dòng lệnh, bật direct access grant để đổi username/password lấy token khi
  thao tác tay. Chỉ dùng cho vận hành và kiểm thử, không đưa vào code.
- **`broker`** - chỉ dùng khi cấu hình identity brokering (đăng nhập qua Google, Facebook, ...).
  Hệ thống hiện không dùng.
- **`realm-management`** - không dùng để đăng nhập mà là nơi chứa các role quản trị realm:
  `manage-users`, `view-users`, `query-users`, `query-groups`, `view-realm`, `create-client`.
  Các role này được gán cho service account của `wgs-user-service`.

## 3. Client của dự án

### 3.1. `web-grading-fe` - client của giao diện React

- Public client (`publicClient: true`), PKCE `S256`, bật standard flow (Authorization Code),
  **tắt** direct access grants.
- Cấu hình phía frontend: `VITE_KEYCLOAK_AUTHORITY` (đúng dạng `https://<host>/realms/ptit-wgs`)
  và `VITE_KEYCLOAK_CLIENT_ID=web-grading-fe`.
- Luồng: trình duyệt chuyển tới trang đăng nhập của Keycloak, nhận authorization code, đổi lấy
  access token, refresh token và ID token; `keycloak-js` giữ token trong bộ nhớ.
- Vì là public client nên tuyệt đối không cấu hình secret và không gán role quản trị ở đây. Mọi
  thao tác cần quyền quản trị phải đi qua backend.

### 3.2. `wgs-password-verify` - xác minh mật khẩu hiện tại

- Confidential client, bật **direct access grant** (Resource Owner Password Grant), tắt standard
  flow.
- Dùng trong luồng đổi mật khẩu: api-gateway gửi `username` + mật khẩu hiện tại lên token endpoint
  bằng client này để biết mật khẩu đúng hay sai, rồi mới đi tiếp.
- Không thể mượn `web-grading-fe` cho việc này: client đó là public (không giữ được secret) và đã
  tắt direct access grant.
- Cấu hình: `KEYCLOAK_PASSWORD_CLIENT_ID`, `KEYCLOAK_PASSWORD_CLIENT_SECRET`. Secret rỗng không
  phải phương án dự phòng: gọi vào confidential client mà không có secret sẽ trả `unauthorized_client`
  (gateway đổi thành 502), cố ý để lỗi cấu hình lộ ra ngay.

### 3.3. `wgs-user-service` - service account gọi Admin API

- Confidential client, `serviceAccountsEnabled: true`, tắt standard flow và direct access grants.
- Backend dùng **Client Credentials Grant** để lấy admin token ngắn hạn, rồi gọi
  `/admin/realms/ptit-wgs/...`. Token được lấy lại cho mỗi lần gọi (endpoint lưu lượng thấp, không
  cache) trong `KeycloakAdminWebClient`.
- Việc dùng admin token:
  - tìm người dùng theo `username` hoặc `email` (sau khi đã xác minh mật khẩu hiện tại, tránh biến
    endpoint thành công cụ dò tài khoản);
  - tạo người dùng khi import CSV, kèm mật khẩu tạm và required action đổi mật khẩu;
  - đặt lại mật khẩu khi người dùng tự đổi mật khẩu.
- Service account cần các role: `manage-users`, `view-users`, `query-users`, `query-groups`,
  `create-client`; import CSV cần thêm `view-realm` (tra role theo tên sẽ trả 403 nếu thiếu).
  Thiếu `manage-users` thì lệnh reset password trả 403.
- Cấu hình: `KEYCLOAK_ADMIN_CLIENT_ID` (mặc định `wgs-user-service`),
  `KEYCLOAK_ADMIN_CLIENT_SECRET`. `KEYCLOAK_ISSUER_URI` phải trùng với issuer mà gateway dùng để
  kiểm JWT, nếu không sẽ có tình trạng xác thực JWT ở một Keycloak còn gửi mật khẩu sang Keycloak khác.
- Tên client mang chữ `user-service` là tên lịch sử (trước đây dịch vụ người dùng làm việc này);
  hiện api-gateway là nơi gọi Admin API.

### 3.4. `wgs-postman` - client phục vụ kiểm thử

- Public client, bật cả standard flow và direct access grant, `redirectUris: *`, `webOrigins: +`.
- Chỉ dùng để lấy token khi thử endpoint bằng Postman.
- Đây là cấu hình lỏng: nếu realm phục vụ Internet lâu dài thì nên tắt direct access grant, giới hạn
  redirect URI, hoặc xoá client khi không còn nhu cầu kiểm thử.

## 4. Ba luồng end-to-end

### 4.1. Đăng nhập và gọi API

1. Người dùng mở giao diện, chưa có token → frontend chuyển hướng tới Keycloak với client
   `web-grading-fe` (PKCE).
2. Keycloak xác thực, trả authorization code về `redirectUris` của frontend.
3. Frontend đổi code lấy access token, refresh token, ID token.
4. Frontend gọi API Gateway kèm `Authorization: Bearer <access token>`.
5. Gateway kiểm chữ ký, thời hạn và vai trò (`LECTURER`, `STUDENT`, `ADMIN`) rồi chuyển tiếp yêu cầu.

### 4.2. Đổi mật khẩu (UC-14)

1. Frontend gọi `POST /api/v1/account/change-password` với mật khẩu hiện tại và mật khẩu mới.
2. Gateway dùng `wgs-password-verify` (password grant) để xác minh mật khẩu hiện tại.
3. Nếu đúng, gateway dùng `wgs-user-service` (client credentials) lấy admin token.
4. Gateway tra người dùng theo đúng trường đã xác thực (`username` hoặc `email`) và lấy bản ghi khớp
   chính xác, không lấy phần tử đầu tiên của kết quả tìm kiếm.
5. Gateway gọi Admin API đặt mật khẩu mới.

### 4.3. Import danh sách sinh viên bằng CSV

1. Giảng viên gửi tệp CSV.
2. Backend dùng `wgs-user-service` tạo người dùng với `lastName` (bắt buộc theo user profile của
   Keycloak 26), mật khẩu tạm và required action `UPDATE_PASSWORD`.
3. Người dùng đăng nhập lần đầu, bị đưa sang trang `account` để đổi mật khẩu.

## 5. Biến môi trường liên quan

| Biến | Nơi đọc | Ý nghĩa |
|---|---|---|
| `KEYCLOAK_ISSUER_URI` | api-gateway | Issuer của realm, cũng là gốc để suy ra địa chỉ Admin API |
| `KEYCLOAK_ADMIN_CLIENT_ID` | api-gateway | Client service account, mặc định `wgs-user-service` |
| `KEYCLOAK_ADMIN_CLIENT_SECRET` | api-gateway | Secret của client đó, chỉ nằm ở backend |
| `KEYCLOAK_PASSWORD_CLIENT_ID` | api-gateway | Client xác minh mật khẩu, mặc định `wgs-password-verify` |
| `KEYCLOAK_PASSWORD_CLIENT_SECRET` | api-gateway | Secret của client xác minh mật khẩu |
| `VITE_KEYCLOAK_AUTHORITY` | frontend | Issuer dùng cho `keycloak-js`, phải trùng `KEYCLOAK_ISSUER_URI` |
| `VITE_KEYCLOAK_CLIENT_ID` | frontend | Mặc định `web-grading-fe` |

Secret không bao giờ đặt trong mã nguồn, trong biến `VITE_*` (Vite nhúng vào bundle) hay trong Helm
values. Khi chạy local chúng nằm trong `.env` (đã bị `.gitignore`); trên cụm chúng nằm trong Secret
`keycloak-admin-client` và được mount thành biến môi trường.

## 6. Nguyên tắc khi thêm hoặc sửa client

1. Client chạy trên trình duyệt: public, PKCE `S256`, chỉ bật standard flow.
2. Client chạy ở backend: confidential, chỉ bật đúng grant cần dùng (client credentials cho gọi
   Admin API, password grant chỉ cho bước xác minh mật khẩu).
3. Quyền quản trị chỉ gán cho service account, không gán cho client public.
4. Một client chỉ nên phục vụ một mục đích; đừng dùng lại client của frontend cho grant của backend.
5. Sau khi sửa realm trên môi trường thật, export lại realm và cập nhật file trong
   `src-services/keycloak/`.

## 7. Kiểm tra nhanh

Lấy admin token bằng client credentials (thay biến bằng giá trị thật trong `.env`, không dán vào
tài liệu hay chat):

```bash
curl -s -X POST "$KEYCLOAK_ISSUER_URI/protocol/openid-connect/token" \
  -d grant_type=client_credentials \
  -d client_id="$KEYCLOAK_ADMIN_CLIENT_ID" \
  -d client_secret="$KEYCLOAK_ADMIN_CLIENT_SECRET" | jq -r .access_token
```

Tra một người dùng bằng token vừa lấy:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "$KEYCLOAK_SERVER/admin/realms/ptit-wgs/users?username=<username>&exact=true" | jq '.[0].id'
```

Nếu lệnh thứ hai trả 403 thì service account thiếu `manage-users`; nếu lệnh thứ nhất trả
`unauthorized_client` thì sai client id hoặc secret.

## 8. Sai lệch đang tồn tại giữa hai file realm

- `src-services/keycloak/ptit-wgs-realm.json` (bản cũ, 4.4KB): **không chứa** `web-grading-fe` và
  khai báo `wgs-user-service` với `standardFlowEnabled: false`.
- `src-services/keycloak/realm-export.json` (bản export đầy đủ, 83KB): có đủ 10 client như bảng
  trên, nhưng `wgs-user-service` đang để `standardFlowEnabled: true`.

Hệ quả: dựng lại realm từ file cũ sẽ thiếu client của giao diện nên không đăng nhập được; còn cờ
standard flow trên `wgs-user-service` là quyền thừa (client này chỉ cần service account). Việc cần
làm: chốt `standardFlowEnabled: false` cho `wgs-user-service` trên realm thật, export lại và dùng
một file realm duy nhất làm nguồn.
