# PortAllocator — executor-service

Nơi lưu: `docs/api/docs/executor-service/port-allocator.md`

Mục đích: giải thích cách cấp cổng host cho container chấm bài, vì sao có thêm bind probe,
vì sao điểm bắt đầu ngẫu nhiên, và cách tránh trùng cổng app/DB trong cùng pod.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.infra` |
| Annotation | `@Component` |
| Dải cổng | `MIN_PORT = 20000` … `MAX_PORT = 30000` |
| Ai gọi | `GradingOrchestrator` (cổng app), `DbSandboxService`/bước DB (cổng DB) |

## 2. Trạng thái nội bộ

- `BitSet used` kích thước 10.001 bit: bit `i` bật nghĩa là cổng `20000 + i` đã cấp.
- `Random random`: chọn điểm bắt đầu tìm cổng trống.
- Mọi method `synchronized` — an toàn khi nhiều thread gọi (dù pool chấm hiện là 1).

## 3. `claim()`

1. Chọn `startIdx = random.nextInt(range)`.
2. `used.nextClearBit(startIdx)`; nếu vượt cuối dải thì quay về `nextClearBit(0)` — tìm
   vòng tròn.
3. Với từng bit trống:
   - Đánh dấu đã dùng **trước** khi thử bind.
   - `isBindable(port)`: mở `ServerSocket` với `setReuseAddress(false)`, bind
     `0.0.0.0:port`, đóng ngay. Bind được → trả cổng.
   - Bind lỗi → giữ bit đã bật (không bao giờ cấp lại trong vòng đời JVM) và thử cổng kế.
4. Hết dải → `IllegalStateException` với `NO_FREE_PORTS_PREFIX + "20000-30000"`.

### Vì sao cần bind probe

K8s netns cách ly pod, nên chỉ va chạm trong pod mới đáng lo. Nhưng một container sót lại
từ lần boot compose thất bại vẫn giữ cổng host trong netns của pod; BitSet không biết điều
đó. Probe phát hiện đúng trường hợp này, tránh lỗi `port is already allocated` khi boot
(sự cố 2026-10-29: `Bind for 0.0.0.0:20000 failed`).

### Vì sao điểm bắt đầu ngẫu nhiên

Trước đây allocator luôn trả 20000 trước, khiến cổng đó thành "cổng nóng" trên mọi pod và
dễ đụng container sót. Random hoá giảm xác suất (review 2026-11-06, sự cố "Target port
20000 is not exposed").

## 4. `claimDbPort()`

Gọi thẳng `claim()` — dùng chung BitSet với cổng app để chắc chắn cổng DB và cổng app
không bao giờ trùng, vì cả hai được publish trong cùng netns pod.

## 5. `release(int port)`

Chỉ clear bit khi `port` nằm trong dải; cổng ngoài dải bị bỏ qua im lặng. Orchestrator gọi
trong `finally` sau khi container dừng.

## 6. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| Hết cổng | `IllegalStateException` — job `FAILED` với thông điệp rõ |
| Cổng bị chiếm bởi process ngoài JVM | Bit giữ nguyên vĩnh viễn, thử cổng khác |
| `release` cổng chưa cấp | Clear bit (vô hại) |
| Container dừng nhưng chưa nhả cổng kịp | Bit đã clear; lần `claim` sau probe lại và có thể fail tạm thời |

## 7. Liên kết

- `DockerComposePatcher` dùng cổng để ghi đè `ports:` trong compose.
- `DockerComposeRunner.boot` nhận cổng đã cấp.
- Xem thêm: `docker-compose-patcher.md`, `docker-compose-runner.md`.