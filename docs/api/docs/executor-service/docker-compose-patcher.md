# DockerComposePatcher — executor-service

Nơi lưu: `docs/api/docs/executor-service/docker-compose-patcher.md`

Mục đích: giải thích phần logic thuần (không Docker) của việc chuẩn bị compose: chọn service
app, xác định container port, chặn directive nguy hiểm, gắn resource limit và publish cổng DB.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.docker` |
| Loại | `public final class`, constructor private, static |
| Ai gọi | `GradingOrchestrator` trước `DockerComposeRunner.boot` |
| Vì sao tách | Không dính Docker nên mọi nhánh unit-test được |

## 2. `record EffectiveCompose(serviceName, containerPort, composeFile)`

| Trường | Ý nghĩa |
|---|---|
| `serviceName` | Service app — thứ Testcontainers chờ |
| `containerPort` | Cổng app lắng nghe **trong** container |
| `composeFile` | File compose đã ghi đè (`.yml` hoặc `.yaml`) |

## 3. `writeEffectiveCompose(...)`

Tham số: `workDir`, `gradingStrategy`, `template`, `appPort`, `dockerComposePort`, `maxCpu`,
`maxMemoryMb`, `dbService`, `dbPort`, `dbContainerPort`.

### 3.1 Chọn nguồn compose

| Strategy | Hành vi |
|---|---|
| `LECTURER_DOCKER_COMPOSE` | `template` bắt buộc (blank → `NO_COMPOSE_TEMPLATE`); ghi đè `docker-compose.yml` trong workdir |
| Còn lại (sinh viên tự nộp) | Tìm `docker-compose.yml`; nếu không có thì `docker-compose.yaml`; không có cả hai → `NO_COMPOSE_FILE` |

### 3.2 Parse và kiểm tra cấu trúc

- `load`: SnakeYAML; top-level không phải Map → `NO_TOP_LEVEL`.
- `servicesOf`: thiếu `services` hoặc không phải Map → `NO_SERVICES_SECTION`.
- `services.isEmpty()` → `NO_SERVICES`.

### 3.3 Chọn service app — `identifyAppService`

Duyệt theo thứ tự khai báo, bỏ qua service có tên chứa `db`, `database`, `postgres`,
`mysql`, `mongo`, `redis`, `kafka`, `zipkin`; chọn service đầu tiên có `ports`. Không có →
lấy key đầu tiên.

Hệ quả: service tên `my-db-app` cũng bị bỏ qua (chứa `db`). Đặt tên service rõ ràng
(`app`, `web`, `backend`) để tránh nhầm.

### 3.4 Xác định `containerPort` — `resolveContainerPort`

Đọc `ports` của service app, lấy entry dạng `"host:container"` (theo dấu `:` cuối), parse
phần sau. Không parse được entry nào → `dockerComposePort` (nếu > 0) → `8080`.

Vì sao không tin config: nếu config nói 20000 nhưng app nghe 8080 trong container,
Testcontainers chờ một cổng không được expose và boot timeout. Sự cố 2026-11-06 "Target
port 20000 is not exposed".

### 3.5 Chặn directive nguy hiểm — `rejectUnsafe`

| Kiểm tra | Lỗi |
|---|---|
| `privileged: true` | `PRIVILEGED_MODE_PREFIX + service` |
| `volumes` chứa `/var/run/docker.sock` | `MOUNTS_DOCKER_SOCK_PREFIX + service` |

Chạy cho **mọi** service, không riêng app.

### 3.6 Resource limit — `applyLimits`

Tạo `deploy.resources.limits` với `cpus` (String) và/hoặc `memory` (`<n>M`) khi cấu hình
dương. Không có limit nào → không đụng vào `deploy`. `deploy` đã có thì ghi đè `resources`.

### 3.7 Publish cổng DB

Chỉ khi `dbService != null && dbPort != null && dbContainerPort > 0`:

- Service DB không có trong compose → log warn (DB step sẽ fail kết nối với lỗi rõ ràng).
- Có → **thêm** `"<dbPort>:<dbContainerPort>"` vào `ports` (không thay thế entry sẵn có).

### 3.8 Ghi đè cổng app

`ports` của service app bị **thay** bằng `[<appPort>:<containerPort>]` — chỉ một ánh xạ,
tránh xung đột với cổng cũ trong compose.

### 3.9 Ghi file

`new Yaml().dump(compose, writer)` — format lại toàn bộ file; comment trong compose gốc bị
mất. Trả `EffectiveCompose`.

## 4. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| Compose chỉ có service DB | App service = key đầu tiên (DB) — boot sẽ fail ở bước sau |
| `ports` là chuỗi thay vì list | `resolveContainerPort` bỏ qua, dùng config/8080; bước ghi `ports` vẫn thay được |
| `ports` entry dạng `"8080"` | Không có `:`, bỏ qua entry đó |
| `dbContainerPort = 0` | Không publish DB, không cảnh báo |
| `deploy` là scalar | `applyLimits` bỏ qua (không phải Map) |

## 5. Liên kết

- `PortAllocator` cấp `appPort`/`dbPort` trước khi gọi patcher.
- `DockerComposeRunner` nhận `EffectiveCompose` để boot.
- Hằng số: `Constant.DockerCompose`, `Constant.Strategy`, `Constant.Message`.

---

## Chi tiết từng hàm

### `DockerComposePatcher()` — private

Lớp `final` toàn `static`, không trạng thái; chặn khởi tạo để không ai `new`.

### `record EffectiveCompose(String serviceName, int containerPort, Path composeFile)`

Kết quả trả về cho `DockerComposeRunner.boot`: tên service app, port **trong container** mà
app lắng nghe, và đường dẫn file compose đã ghi (có thể là `docker-compose.yaml` nếu file
`.yml` không tồn tại).

### `static EffectiveCompose writeEffectiveCompose(Path workDir, String gradingStrategy, String template, int appPort, int dockerComposePort, Double maxCpu, Integer maxMemoryMb, String dbService, Integer dbPort, Integer dbContainerPort)`

| Khía cạnh | Nội dung |
|---|---|
| Input | thư mục giải nén, chiến lược (`LECTURER_DOCKER_COMPOSE` hay không), template, port cấp cho app, port cấu hình, giới hạn CPU/RAM, service/port DB |
| Output | `EffectiveCompose` |
| Lỗi | `IllegalStateException` khi thiếu template/file/services/`services` sai kiểu, hoặc compose chứa chỉ thị nguy hiểm |

1. Xác định file đích `workDir/docker-compose.yml`.
2. Nếu chiến lược là `LECTURER_DOCKER_COMPOSE`: template rỗng → ném `NO_COMPOSE_TEMPLATE`;
   ngược lại ghi template thành file (bỏ qua compose sinh viên nộp).
3. Nếu không: đòi `docker-compose.yml` là file thường; thiếu thì thử
   `docker-compose.yaml`; thiếu cả hai → `NO_COMPOSE_FILE`.
4. `load(composeFile)` → map YAML; `servicesOf` → map services (rỗng → `NO_SERVICES`).
5. `identifyAppService(services)` → tên service app.
6. `resolveContainerPort(services, appService, dockerComposePort)` → port trong container.
7. Với **mọi** service: `rejectUnsafe(name, service)` rồi `applyLimits(service, maxCpu,
   maxMemoryMb)`.
8. Nếu có `dbService` + `dbPort` + `dbContainerPort > 0`: thêm `"dbPort:dbContainerPort"`
   vào **cuối** danh sách `ports` của service DB (tạo list nếu chưa có, không thay thế port
   sẵn có). Service DB không tồn tại → chỉ log warn, DB steps sẽ fail kết nối với lỗi rõ.
9. Ghi đè `ports` của service app bằng đúng một entry `"appPort:containerPort"` — thay thế
   hoàn toàn để không lộ port sinh viên tự khai.
10. Ghi lại YAML (SnakeYAML `dump`) rồi trả `EffectiveCompose`.

### `private static int resolveContainerPort(Map<String,Object> services, String appService, int dockerComposePort)`

1. Service app không tồn tại → `dockerComposePort > 0 ? dockerComposePort : 8080`.
2. Duyệt `ports`: lấy entry dạng chuỗi, cắt sau dấu `:` **cuối** (`"20000:8080"` → `8080`),
   parse int; entry hỏng thì thử entry kế.
3. Không tìm được → `dockerComposePort > 0 ? dockerComposePort : 8080`.

Vì sao đọc từ compose trước: nếu config nói 20000 nhưng app nghe 8080 trong container,
Testcontainers chờ đúng port không được expose và boot timeout (sự cố 2026-11-06).

### `private static Map<String,Object> load(Path composeFile)`

`new Yaml().load(in)`; kết quả không phải `Map` (YAML rỗng, list) → `NO_TOP_LEVEL`.

### `private static Map<String,Object> servicesOf(Map<String,Object> compose)`

`compose["services"]` không phải `Map` → `NO_SERVICES_SECTION`; ngược lại trả map (có thể
rỗng — caller kiểm tra tiếp).

### `private static String identifyAppService(Map<String,Object> services)`

1. Duyệt theo thứ tự YAML; bỏ qua service có tên chứa `db`, `database`, `postgres`, `mysql`,
   `mongo`, `redis`, `kafka`, `zipkin` (không phân biệt hoa thường).
2. Chọn service đầu tiên còn lại **và** có `ports` khác null.
3. Không có → trả service đầu tiên trong map (kể cả là DB) — compose tối giản vẫn boot được,
   nhưng có thể chọn sai nếu sinh viên đặt tên lạ.

### `private static void rejectUnsafe(String name, Map<String,Object> service)`

- `privileged: true` → `IllegalStateException(PRIVILEGED_MODE_PREFIX + name)`.
- Bất kỳ volume nào chứa chuỗi `/var/run/docker.sock` → `MOUNTS_DOCKER_SOCK_PREFIX + name`.

Chạy cho **mọi** service, kể cả DB — sinh viên không thể leo thang qua DinD socket.

### `private static void applyLimits(Map<String,Object> service, Double maxCpu, Integer maxMemoryMb)`

Dựng `limits` từ `maxCpu > 0` (ghi `cpus` dạng chuỗi) và `maxMemoryMb > 0` (ghi
`"<mb>M"`). Không có giới hạn nào → không sửa service. Có → lấy/tạo `deploy`, rồi đặt
`deploy.resources.limits = limits` (ghi đè limits cũ, giữ nguyên `reservations` nếu có).
