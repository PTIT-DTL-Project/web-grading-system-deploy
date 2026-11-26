# DockerComposeRunner — executor-service

Nơi lưu: `docs/api/docs/executor-service/docker-compose-runner.md`

Mục đích: giải thích cách executor boot docker-compose của bài nộp bằng Testcontainers
trên DinD, cách chờ app sẵn sàng, và cách dọn container khi boot thất bại.

---

## 1. Tổng quan

`DockerComposeRunner` là `@Service` bọc `ComposeContainer` của Testcontainers. Nó không
gọi docker CLI (image executor không có CLI), chỉ nói chuyện với daemon qua
`DOCKER_HOST=tcp://localhost:2375` — sidecar DinD.

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.docker` |
| Annotation | `@Service`, `@Slf4j` |
| Ai gọi | `GradingOrchestrator` ở giai đoạn `BUILDING` |

## 2. Kiểu dữ liệu

### 2.1 `record RunningCompose(ComposeContainer compose, String host, int port) implements AutoCloseable`

| Trường | Ý nghĩa |
|---|---|
| `compose` | Container đang chạy, cần để stop |
| `host` | Host mà app lắng nghe (Testcontainers trả về) |
| `port` | Cổng ánh xạ ra host, dùng để gọi HTTP/DB |

`close()` gọi `stopQuietly(compose)` — orchestrator dùng try-with-resources để bảo đảm
container dừng dù chấm thành công hay thất bại.

## 3. `boot(EffectiveCompose effective, long startupTimeoutMs)`

| Khía cạnh | Nội dung |
|---|---|
| Input | `effective` — compose đã vá (service name, container port, file), `startupTimeoutMs` |
| Output | `RunningCompose` |
| Lỗi | Ném lại `RuntimeException` của Testcontainers sau khi đã dọn container |

### Các bước

1. Tạo `ComposeContainer(new DockerImageName("docker:25.0.5"), effective.composeFile())`.
2. `withExposedService(serviceName, containerPort, Wait.forHttp("/")...)`:
   - Chờ HTTP `/` trả mã `< 500` — chấp nhận 2xx/3xx/4xx vì nhiều app trả 404 ở root
     nhưng đã sẵn sàng nhận request nghiệp vụ; chỉ 5xx mới coi là chưa lên.
   - `withStartupTimeout(startupTimeoutMs * 2)` cho riêng wait strategy — rộng hơn timeout
     tổng để app còn kịp build/khởi động.
3. `withBuild(true)`: cho phép compose `build:` (bài nộp hay có Dockerfile riêng).
4. `withStartupTimeout(startupTimeoutMs)`: trần tổng cho cả project.
5. `compose.start()`.
6. Nếu start ném `RuntimeException`: gọi `stopQuietly(compose)` rồi ném lại.
   - Lý do (comment trong code): start lỗi vẫn để lại container của project; Ryuk bị tắt nên
     không ai dọn, cổng host bị giữ và job sau chết với `port is already allocated`.
     Sự cố tham chiếu: `Bind for 0.0.0.0:20000 failed`, 2026-10-29.
7. Lấy `host`/`port` qua `getServiceHost` / `getServicePort`, log `Grading container up`,
   trả `RunningCompose`.

## 4. `stopQuietly(ComposeContainer)`

Bọc `compose.stop()` trong try/catch, chỉ log warn (`COMPOSE_STOP_FAILED`) — dọn dẹp
không được phép che lỗi gốc.

## 5. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| App không phản hồi `/` trong `startupTimeoutMs*2` | Start timeout → stop container → ném lỗi |
| Compose file sai/không build được | `RuntimeException` → stop → ném lỗi |
| Image không có trong registry | Lỗi pull, cùng đường xử lý |
| `stop()` lỗi | Log warn, không ném |

## 6. Liên kết

- `DockerComposePatcher` tạo ra `EffectiveCompose` (vá service, cổng, build context).
- `PortAllocator` cấp cổng host trước khi boot để tránh trùng.
- `GradingOrchestrator` gọi `boot(...)` rồi dùng `host:port` cho các bước HTTP.
- Xem thêm: `docker-compose-patcher.md`, `port-allocator.md`, `grading-orchestrator.md`.