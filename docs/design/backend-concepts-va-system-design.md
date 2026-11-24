# Kiến thức nền tảng Backend & System Design (áp vào đồ án Web Grading System)

> Tài liệu ôn tập phản biện: mỗi mục gồm **định nghĩa ngắn → bảng so sánh → ví dụ
> thật trong đồ án (kèm file/tham số) → khi nào dùng → câu trả lời mẫu 30–60 giây →
> câu hỏi nối tiếp**. Chỗ nào đồ án **chưa** làm, tài liệu nói thẳng là chưa làm.

---

## Mục lục

1. [Sync vs Async](#1-sync-vs-async)
2. [Polling vs Push, Short vs Long Polling](#2-polling-vs-push-short-vs-long-polling)
3. [Một API request đi qua những layer nào](#3-một-api-request-đi-qua-những-layer-nào)
4. [Reverse proxy vs Forward proxy](#4-reverse-proxy-vs-forward-proxy)
5. [Idempotency](#5-idempotency)
6. [Khó khăn của Microservices so với Monolith](#6-khó-khăn-của-microservices-so-với-monolith)
7. [Circuit breaker](#7-circuit-breaker)
8. [Vì sao cần container orchestration](#8-vì-sao-cần-container-orchestration)
9. [Resiliency vs High Availability vs Scalability](#9-resiliency-vs-high-availability-vs-scalability)
10. [Horizontal vs Vertical scaling](#10-horizontal-vs-vertical-scaling)
11. [Public subnet vs Private subnet](#11-public-subnet-vs-private-subnet)
12. [Object vs Block vs File storage](#12-object-vs-block-vs-file-storage)
13. [Bảng trả lời nhanh 1 dòng](#13-bảng-trả-lời-nhanh-1-dòng)

---

## 1. Sync vs Async

### 1.1 Định nghĩa

| | Sync (đồng bộ) | Async (bất đồng bộ) |
|---|---|---|
| Luồng gọi | Bên gọi **chờ** kết quả rồi mới đi tiếp | Bên gọi **không chờ**; kết quả đến sau (callback/event/poll) |
| Ràng buộc | Hai bên phải sống cùng lúc | Không cần sống cùng lúc (có buffer/hàng đợi) |
| Lỗi | Lỗi lan ngay sang bên gọi (fail fast) | Lỗi phải xử lý riêng: retry, dead-letter, đối soát |
| Độ trễ cảm nhận | Thấp nếu việc ngắn | Cao hơn (phải chờ xử lý nền) nhưng không giữ kết nối |
| Nhất quán | Thường mạnh (cùng transaction) | Thường eventual |
| Dùng khi | Việc ngắn, cần kết quả ngay (đọc dữ liệu, validate) | Việc dài, có thể thất bại, cần tách tải (chấm bài, gửi mail, index) |

### 1.2 Trong đồ án

**Sync (HTTP request/response):**

| Luồng | Cơ chế | File |
|---|---|---|
| FE → gateway → course/submission/result/ai | Spring Cloud Gateway route (reactive), chờ response | `api-gateway/src/main/resources/application.yaml` |
| course-service → executor (dry-run test plan) | Feign `FEIGN_EXECUTOR_SERVICE_URL` | `course-service` |
| result-service / ai-assistant → course-service (đọc trọng số plan) | Feign `COURSE_SERVICE_URI` | `result-service`, `ai-assistant-service` |
| executor → result-service (ghi kết quả) | HTTP client nội bộ, chờ 2xx | `executor-service` |

**Async (event / nền):**

| Luồng | Cơ chế | Điểm đáng nói |
|---|---|---|
| Upload xong → chấm bài | Kafka topic `wgs-events-deploy` (submission publish, executor consume) | Producer không chờ chấm xong; executor chết vẫn không mất event (trong retention của Kafka) |
| Webhook RustFS → cập nhật DB | `@Async handleUploadCompleteAsync` | Trả 200 ngay cho RustFS, tránh webhook timeout và retry dồn dập |
| AI run (agent nhiều bước) | `RunWorker` chạy nền + `SseBroadcaster` đẩy event | Client không giữ request 2 phút; xem §2 |
| Đặt tên hội thoại AI | `ConversationTitleWorker` (`@Async`) | Việc phụ, không chặn câu trả lời chính |
| Chấm bài bên trong executor | `gradingTaskExecutor` (core=max=1, queue 10) | Giới hạn concurrency để không mở 10 môi trường Docker cùng lúc |

### 1.3 Câu trả lời mẫu

> "Em dùng sync cho những việc cần kết quả ngay và ngắn: FE gọi API, service gọi
> nhau bằng Feign. Em dùng async cho việc dài và có thể thất bại: upload xong thì
> submission-service bắn event Kafka, executor tiêu thụ rồi chấm; webhook của RustFS
> được xử lý `@Async` để trả 200 ngay. Ranh giới em chọn là: nếu người dùng phải
> chờ kết quả để làm bước tiếp theo thì sync; nếu chỉ cần biết 'đã nhận' thì async
> + thông báo/poll."

### 1.4 Câu hỏi nối tiếp

- *"Async rồi làm sao biết chấm xong?"* → FE poll `GET /api/v1/results/{submissionId}`
  mỗi 3 giây (tối đa 10 phút), xem §2.
- *"Nếu executor chết giữa lúc chấm?"* → Hiện **chưa có retry tự động** cho event
  đã nhận; có `StaleJobReaper` quét job `PENDING/FETCHING/BUILDING` quá 30 phút,
  tối đa 3 lần. Đây là mục đã ghi ở Hướng phát triển.
- *"Async có làm mất nhất quán không?"* → Có, eventual. Ví dụ điểm bài tập chỉ
  xuất hiện sau khi result-service ghi xong; trong khoảng giữa, `EXERCISE` có thể
  là 0 (chưa có bài GRADED publish) — đã xử lý bằng cách trả `null`/0 có quy ước.

---

## 2. Polling vs Push, Short vs Long Polling

### 2.1 Định nghĩa

| Cơ chế | Cách hoạt động | Ưu | Nhược |
|---|---|---|---|
| **Short polling** | Client gọi lặp theo chu kỳ (1s, 3s…) | Đơn giản, chịu lỗi tốt, không cần giữ kết nối | Tốn request vô ích, trễ tối đa 1 chu kỳ, tăng tải |
| **Long polling** | Client gọi, server **giữ** request tới khi có dữ liệu hoặc timeout | Gần realtime hơn, ít request rỗng | Chiếm connection/thread, khó scale, timeout proxy |
| **Push (WebSocket/SSE)** | Server chủ động đẩy khi có event | Realtime, ít request | Cần giữ kết nối, reconnect, state; LB/proxy phải hỗ trợ |
| **Webhook** | Server A gọi HTTP sang server B khi có sự kiện | Tách hệ thống, không cần giữ kết nối | Cần xác thực, retry, idempotent (B phải chịu được gọi lặp) |

### 2.2 Đồ án dùng **cả ba**, có lý do cho từng chỗ

| Tình huống | Cơ chế | Tham số thật | Vì sao chọn |
|---|---|---|---|
| Chờ kết quả chấm bài | **Short polling** | `POLL_INTERVAL_MS = 3000`, `MAX_POLL_MS = 600000` (`useSubmissionResult.ts`) | Kết quả có thể mất vài phút; polling 3s đủ nhanh, đơn giản, chịu được mất mạng; có trần 10 phút để không quay vô hạn |
| Trạng thái AI run | **Short polling + SSE** | Poll `getRunStatus` mỗi **1s** song song với SSE (`useRunEvents.ts`) | SSE có thể đứt (proxy, sleep); poll là lưới an toàn để trạng thái cuối luôn đúng |
| Nội dung AI stream (token, tool call) | **Push: SSE** | `GET /api/v1/ai/runs/{id}/events?afterSequence=N`, `Accept: text/event-stream` | Cần đẩy nhiều event nhỏ; SSE đơn giản hơn WebSocket (1 chiều, chạy trên HTTP, qua được gateway) |
| Upload xong | **Webhook** | RustFS → `POST /api/v1/submissions/webhook/upload-complete` | RustFS không thể gọi ngược kiểu "chờ"; webhook + retry queue (`/tmp/rustfs-events`) |
| Chấm bài | **Message queue (push qua Kafka)** | topic `wgs-events-deploy` | Tách producer/consumer, chịu được consumer chết |

Hai chi tiết đáng nêu khi bị hỏi sâu:

1. **SSE trong đồ án không dùng `EventSource`** mà dùng `fetch()` + đọc stream.
   Lý do: `EventSource` **không gửi được header `Authorization`**, mà gateway yêu cầu
   Bearer token. Cách làm: `fetch` với `Accept: text/event-stream`, đọc
   `response.body` qua `TextDecoderStream`, tự parse `event:`/`id:`/`data:`.
2. **SSE có resume**: client gửi `afterSequence` (sequence cuối đã nhận); server
   replay từ đó. Khi stream đóng, client reconnect sau 1s. Đây là cách chống mất
   event mà không cần lưu toàn bộ lịch sử ở client.

### 2.3 Khi nào dùng cái nào (quy tắc chọn)

| Chọn polling khi | Chọn push khi |
|---|---|
| Kết quả đến trong vài giây–vài phút, không cần tức thời | Cần hiển thị tiến trình/token theo thời gian thực |
| Hạ tầng có proxy/LB chặn long-lived connection | Kiểm soát được timeout của proxy (SSE cần timeout > thời gian chạy) |
| Số client lớn nhưng tần suất event thấp | Nhiều event/giây, ít client |
| Muốn đơn giản, dễ debug, dễ chịu lỗi | Đã có cơ chế reconnect + resume |

Với đồ án: **polling cho kết quả chấm** (thưa, chậm), **SSE cho AI** (nhiều event,
cần cảm giác realtime), **webhook + Kafka cho tích hợp hệ thống** (không có người
dùng ngồi chờ).

### 2.4 Câu trả lời mẫu

> "Em không chọn một cơ chế cho tất cả. Kết quả chấm bài em cho FE poll mỗi 3 giây,
> tối đa 10 phút, vì kết quả đến chậm và polling chịu lỗi tốt. Phần AI em dùng SSE
> để đẩy từng event, kèm poll trạng thái 1 giây làm lưới an toàn và `afterSequence`
> để reconnect không mất event. Tích hợp giữa hệ thống thì em dùng webhook và
> Kafka, vì lúc đó không có client nào ngồi chờ."

### 2.5 Câu hỏi nối tiếp

- *"Sao không dùng WebSocket?"* → Nhu cầu chỉ một chiều (server → client), SSE
  nhẹ hơn, đi qua HTTP/1.1 và gateway dễ hơn, không cần handshake nâng cấp.
- *"Polling 3 giây có tốn tài nguyên?"* → 1 user chờ ~5 phút = ~100 request; chấp
  nhận được. Nếu 1.000 user cùng chờ thì phải chuyển sang push hoặc tăng interval
  + backoff.
- *"Long polling có dùng không?"* → Không. Nó chiếm thread trong lúc chờ, và SSE
  giải quyết đúng bài toán đó gọn hơn.

---

## 3. Một API request đi qua những layer nào

### 3.1 Hành trình đầy đủ (ví dụ `GET /api/v1/classes?page=0`)

```
[1] Browser: fetch + Bearer access_token
        │ HTTPS
[2] Cloudflare edge: DNS, TLS termination, WAF/DDoS
        │ Zero Trust tunnel (outbound-only từ cloudflared trên host)
[3] cloudflared → http://localhost:<NodePort Traefik>
[4] Traefik (kube-system): đọc Host + Ingress rule → Service grading-api-gateway:8080
[5] kube-proxy/iptables → EndpointSlice → chọn pod gateway (chỉ pod Ready)
[6] gateway (Spring Cloud Gateway, Netty, reactive):
      6a. Spring Security WebFilterChain: verify JWT (chữ ký + iss), map sang JwtAuthenticationToken
      6b. AuthenticationContextFilter (GlobalFilter, Ordered):
          - XOÁ mọi header X-User-* / X-Gateway-Secret do client gửi
          - lấy sub/email/realm_access.roles từ JWT, lọc theo allowlist
          - đóng dấu X-User-Id, X-User-Email, X-User-Roles, X-Gateway-Secret
      6c. route predicate Path=/api/v1/classes/** → COURSE_SERVICE_URI
      6d. (observability) tạo span, propagate traceparent
        │ HTTP nội bộ trong cụm (ClusterIP, không TLS)
[7] Service course (Tomcat, servlet):
      7a. Filter chain: HeaderAuthenticationFilter (so X-Gateway-Secret; sai ⇒ anonymous)
      7b. Spring Security: anyRequest().authenticated(), @PreAuthorize theo role
      7c. DispatcherServlet → HandlerInterceptor (nếu có) → Controller
      7d. Controller: nhận @RequestParam/@AuthenticationPrincipal, gọi Service
[8] Service layer: @Transactional, validate nghiệp vụ, gọi Repository/Feign
[9] Repository (Spring Data JPA) → Hibernate → HikariCP pool → JDBC
[10] PostgreSQL (Neon) qua TLS: parse, plan, execute, trả resultset
[11] Quay lại: entity → DTO/mapper → ApiResponse (JSON)
      11a. GlobalExceptionHandler map exception → HTTP status + body chuẩn
      11b. MDC log: traceId/spanId (từ micrometer-tracing) + user id
[12] Response đi ngược qua Traefik → cloudflared → Cloudflare → Browser
```

### 3.2 Bảng layer theo trách nhiệm

| # | Layer | Trách nhiệm | Nếu thiếu/sai |
|---|---|---|---|
| 1 | Edge (Cloudflare) | TLS, DNS, chống DDoS, ẩn origin | Lộ IP, không có HTTPS |
| 2 | Ingress (Traefik) | Route theo Host/path, LB tới pod Ready | 404/503 |
| 3 | Gateway | Xác thực JWT, phân quyền thô, đóng dấu danh tính, route | Service bị gọi trực tiếp, không biết user |
| 4 | Web/Filter layer của service | Tin cậy nội bộ, dựng SecurityContext, CORS/CSRF (đang tắt vì stateless) | 401/403 sai, giả mạo header |
| 5 | Controller | Parse/validate input, map DTO, chọn status code | 400/415/500 khó hiểu |
| 6 | Service | Nghiệp vụ, transaction boundary, gọi service khác | Logic rò rỉ vào controller |
| 7 | Repository/ORM | Truy vấn, mapping bảng, lazy loading | N+1, sai kiểu dữ liệu |
| 8 | Datasource/DB | Lưu trữ, ràng buộc, index | Mất nhất quán, chậm |
| 9 | Cross-cutting | Log MDC, trace, metric, exception handler | Không debug được |

### 3.3 Chi tiết đáng nhớ

- **Gateway xoá header trước khi tin**: nếu client gửi `X-User-Id: admin`, filter
  xoá **vô điều kiện** rồi mới đóng dấu từ JWT. Nhờ vậy không thể giả danh bằng
  header.
- **Hai lần "xác thực"**: gateway xác thực **người dùng** (JWT); service xác thực
  **người gọi** (`X-Gateway-Secret`). Thiếu lớp thứ hai, ai vào được service là
  bypass toàn bộ authz.
- **Exception không tự thành 500**: `GlobalExceptionHandler` map
  `BadRequestException` → 400, `NotFoundException` → 404, lỗi còn lại → 500 kèm
  `traceId` để tra log.
- **Observability là layer cắt ngang**: cùng một `traceId` xuất hiện ở log gateway,
  service, executor → lần theo một request xuyên 4 service.

### 3.4 Câu trả lời mẫu

> "Request đi qua edge Cloudflare, ingress Traefik, rồi gateway — nơi verify JWT và
> đóng dấu danh tính kèm secret tin cậy — rồi tới filter của service để kiểm secret,
> qua Spring Security, controller, service, repository, xuống Postgres. Em tách hai
> lớp xác thực: gateway xác thực người dùng, service xác thực người gọi."

---

## 4. Reverse proxy vs Forward proxy

### 4.1 Định nghĩa

| | Forward proxy | Reverse proxy |
|---|---|---|
| Đứng về phía | **Client** | **Server** |
| Ai biết nó tồn tại | Client được cấu hình để dùng nó | Client không biết, chỉ thấy domain của server |
| Ẩn ai | Ẩn **client** với server | Ẩn **server** với client |
| Ví dụ | Proxy công ty, `HTTP_PROXY` của curl/Postman, VPN gateway, Squid | Nginx, Traefik, Cloudflare, ALB, Envoy |
| Chức năng chính | Kiểm soát truy cập ra ngoài, cache, ẩn IP nội bộ, audit | TLS termination, LB, routing, rate limit, cache, bảo vệ origin |

```
Forward proxy:   Client ──► [Forward Proxy] ──► Internet ──► Server
                              (thay mặt client)

Reverse proxy:   Client ──► Internet ──► [Reverse Proxy] ──► Server nội bộ
                                            (thay mặt server)
```

### 4.2 Trong đồ án

| Thành phần | Loại | Vai trò |
|---|---|---|
| Cloudflare edge | Reverse proxy (managed) | TLS, DNS, DDoS, WAF |
| `cloudflared` tunnel | Reverse proxy/connector | Nhận request từ Cloudflare, đẩy vào Traefik (không mở inbound port) |
| Traefik | Reverse proxy + ingress controller | Route theo Host, LB tới pod, đọc Ingress |
| Gateway | Reverse proxy **ở tầng ứng dụng** | Route theo path, authN/authZ, đóng dấu header |

Đồ án **không** dùng forward proxy ở runtime. Chỉ có tình huống gặp forward proxy:
khi máy dev/CI nằm sau proxy công ty thì `curl`/Maven/Docker phải set `HTTP_PROXY`,
`HTTPS_PROXY`, `NO_PROXY`.

### 4.3 Vì sao gọi gateway là reverse proxy?

Vì nó đứng thay mặt **server** (service nghiệp vụ): client chỉ biết
`web-dev1-api...`, không biết `grading-course-service:8081`. Nó chấm dứt kết nối
client, mở kết nối mới tới backend, và có thể thêm/bớt header — đúng định nghĩa.

### 4.4 Câu trả lời mẫu

> "Forward proxy đại diện cho client đi ra ngoài, reverse proxy đại diện cho server
> nhận vào. Trong đồ án, Cloudflare và Traefik là reverse proxy; gateway cũng là
> reverse proxy ở tầng ứng dụng vì nó route theo path và xác thực thay cho service.
> Forward proxy chỉ xuất hiện khi máy dev nằm sau proxy công ty."

---

## 5. Idempotency

### 5.1 Định nghĩa

Một thao tác là **idempotent** nếu thực hiện **nhiều lần** cho **cùng kết quả trạng
thái** như thực hiện một lần. Khác với "an toàn" (safe): safe = không đổi trạng
thái; idempotent = đổi trạng thái nhưng lặp lại không đổi thêm.

### 5.2 Method nào idempotent

| Method | Safe | Idempotent | Ghi chú |
|---|---|---|---|
| `GET` | ✅ | ✅ | Chỉ đọc; vẫn phải chú ý side effect ẩn (logging, counter) |
| `HEAD` | ✅ | ✅ | Như GET, không body |
| `OPTIONS` | ✅ | ✅ | CORS preflight |
| `PUT` | ❌ | ✅ | Thay thế toàn bộ resource ⇒ gửi lại cùng body cho cùng kết quả |
| `DELETE` | ❌ | ✅ | Xoá lần 2 trả 404 nhưng trạng thái cuối vẫn là "đã xoá" |
| `PATCH` | ❌ | **Không đảm bảo** | Tuỳ ngữ nghĩa: `set status=DONE` idempotent; `increment +1` thì không |
| `POST` | ❌ | **Không** | Tạo mới mỗi lần ⇒ cần **idempotency key** nếu muốn an toàn khi retry |

Câu chốt: *"PUT và DELETE là idempotent theo đặc tả; POST không, nên POST cần cơ
chế riêng."*

### 5.3 Đồ án đã dùng idempotency ở đâu (4 ví dụ thật)

**Ví dụ 1 — Publish bài tập: POST nhưng idempotent bằng kiểm tra trạng thái**

```java
// AssignmentService.publish
if (!Boolean.TRUE.equals(assignment.getPublished())) {
    assignment.setPublished(true);
    assignment = assignmentRepository.save(assignment);
    log.info("Assignment published: id={}", id);
} else {
    log.info("Assignment already published: id={}", id);   // no-op
}
```

Gọi publish 5 lần ⇒ 1 lần đổi trạng thái, 4 lần no-op. Không có bảng "published"
trùng, không có event trùng.

**Ví dụ 2 — Webhook RustFS: gọi lặp nhưng không chấm lại**

```java
// SubmissionService.handleUploadComplete
SubmissionStatus previous = submission.getStatus();
if (previous == null || previous == SubmissionStatus.PENDING) {
    submission.setStatus(SubmissionStatus.PENDING);
} else {
    // Late/duplicate delivery after grading moved on — never regress the status.
    log.info("Webhook ignored, submission already {}: id={}", previous, submission.getId());
}
publishGradingIfNotStarted(submission, previous);   // chỉ publish khi còn PENDING
```

RustFS có thể gửi webhook nhiều lần (retry queue). Nhờ kiểm tra `previous`, event
chấm bài chỉ được publish **một lần**; một webhook đến muộn không kéo trạng thái
từ `DONE` về `PENDING`.

**Ví dụ 3 — Ghi kết quả chấm: "latest" thay vì chặn trùng**

`result-service` cho phép chấm lại (regrade). Thay vì từ chối, nó **hạ `latest`**
của bản cũ rồi ghi bản mới, và DB có unique index bảo vệ:

```sql
CREATE UNIQUE INDEX idx_results_latest
  ON results(student_id, assignment_id, plan_id)
  WHERE is_latest = true;             -- V2__...plan_weight_and_latest.sql
```

Nhờ vậy: cùng một (sinh viên, bài, plan) luôn có **đúng một** bản `latest`; ghi
lặp lại không tạo ra 2 bản "mới nhất". Kèm theo là một chi tiết thứ tự rất dễ sai:

```java
resultRepository.saveAllAndFlush(previous);   // flush UPDATE trước
Result result = resultRepository.save(newResult);  // rồi mới INSERT
```

**Vì sao cần flush:** Hibernate trong cùng transaction thực hiện INSERT **trước**
UPDATE. Nếu không flush, INSERT `latest=true` chạm unique index khi bản cũ vẫn
`latest=true` ⇒ 409, và executor coi là lỗi 4xx rồi bỏ báo cáo.

**Ví dụ 4 — PUT thay thế toàn bộ thành phần điểm**

`PUT /api/v1/classes/{id}/score-components` thay **toàn bộ** danh sách thành phần
điểm và validate lại tổng trọng số = 1.000 (±0.001). Gửi lại cùng body ⇒ cùng
trạng thái cuối. Đây là lý do chọn PUT thay vì POST "thêm thành phần".

### 5.4 Chỗ **chưa** idempotent (trả lời thẳng)

| Chỗ | Bản chất | Cách xử lý hiện tại | Nếu cần chặt hơn |
|---|---|---|---|
| `POST /submissions/presign` | Tạo/lấy URL ký | `objectName = submissions/<submissionId>.zip` **xác định** ⇒ upload lại ghi đè cùng key, không sinh file rác | Thêm `Idempotency-Key` + bảng lưu key/response |
| `POST /classes/{id}/students/import` | Import CSV | Validate + báo lỗi theo dòng | Idempotency-Key hoặc upsert theo `studentCode` |
| Kafka consumer | At-least-once | Guard theo `status` (ví dụ 2) — chống chấm lại khi đã `DONE` | Bảng `processed_event_id` |
| `POST /assignments` | Tạo mới | Chặn trùng theo `(ownerId, title)` | Trả 409 + `Idempotency-Key` |

### 5.5 Cách thiết kế idempotency key (nếu bị hỏi "làm sao")

```
Client sinh key (UUID) cho một "ý định" (một lần bấm nộp), gửi header
  Idempotency-Key: 5f0c...
Server:
  1. INSERT key vào bảng idempotency(key, request_hash, status, response, created_at)
     với UNIQUE(key) — nếu trùng thì đọc bản ghi cũ
  2. Nếu bản ghi cũ đang PROCESSING → trả 409/202
  3. Nếu DONE → trả lại đúng response cũ (cùng status code, cùng body)
  4. Nếu request_hash khác → 422 (cùng key nhưng payload khác)
  5. TTL 24h để bảng không phình
```

### 5.6 Câu trả lời mẫu

> "GET/PUT/DELETE là idempotent theo đặc tả, POST thì không. Trong đồ án em xử lý
> idempotency ở ba chỗ: publish bài tập kiểm tra cờ `published` nên gọi lại là
> no-op; webhook upload của RustFS có thể gửi lặp nên em chỉ publish event chấm khi
> trạng thái còn `PENDING`, không bao giờ kéo lùi `DONE`; và ghi kết quả chấm thì
> em hạ cờ `latest` của bản cũ rồi mới insert bản mới, có unique partial index bảo
> vệ. Với POST tạo mới, em chưa có Idempotency-Key — đó là hạng mục cải tiến."

---

## 6. Khó khăn của Microservices so với Monolith

### 6.1 Bảng so sánh

| Khó khăn | Monolith | Microservices | Đồ án gặp ở đâu |
|---|---|---|---|
| Giao dịch | 1 transaction ACID | **Distributed transaction**: không có ACID xuyên service | Chấm bài: submission (DB A) → executor (DB B) → result (DB C); dùng **Saga + bù trừ**, chấp nhận eventual |
| Nhất quán dữ liệu | Mạnh, tức thời | Eventual; phải định nghĩa "trạng thái trung gian hợp lệ" | Bài nộp `PENDING → GRADING → DONE/FAILED`; điểm `EXERCISE` có thể tạm 0 khi chưa có kết quả |
| Join dữ liệu | JOIN thoải mái | Không join được xuyên DB | Tìm bài nộp theo **tên file** vì `Assignment` nằm ở `assignment_db`, không join được (`SubmissionService.listByStudent`) |
| Lỗi mạng | Gần như không | Mọi call có thể timeout/partial failure | Feign gateway↔service, executor↔result; phải có timeout + retry có giới hạn |
| Debug/trace | 1 stack trace | Phải có traceId xuyên service | Micrometer Tracing + Tempo; log có `traceId/spanId` |
| Deploy | 1 artifact | 6 artifact, 6 pipeline, 6 version | Helm chart + ArgoCD + CI path filter |
| Vận hành | 1 process | 9 workload, 8 Secret, 3 namespace | `docs/deploy/` toàn bộ là chi phí này |
| Versioning API | Nội bộ, dễ đổi | Hợp đồng phải giữ tương thích | `CreateResultRequest` giữa executor và result-service |
| Test | Unit + integration 1 chỗ | Cần contract test, test với service giả | Test slice + Testcontainers trong CI |
| Bảo mật | 1 chu vi | Nhiều chu vi, cần tin cậy nội bộ | `X-Gateway-Secret` fail closed |
| Chi phí hạ tầng | Thấp | Cao hơn: RAM mỗi JVM ~256–512Mi | Node 8 GB chỉ đủ cho 6 service + hạ tầng |

### 6.2 Vì sao vẫn chọn microservices cho đồ án

| Lý do | Thể hiện |
|---|---|
| Ranh giới nghiệp vụ rõ (lớp/bài tập/điểm/bài nộp/chấm) | Mỗi service một DB, một owner dữ liệu |
| Chấm bài cần cách ly và scale riêng | executor có 2 replica + dind, không ảnh hưởng CRUD |
| Học và thể hiện đủ kỹ thuật phân tán | Saga, event, idempotency, observability, GitOps |
| Có thể thay một service mà không build lại tất cả | CI path filter + chart riêng |

### 6.3 Câu trả lời mẫu

> "Khó khăn lớn nhất không phải code mà là **mất ACID**: mỗi service một DB nên
> không thể transaction xuyên service. Đồ án dùng Saga cho luồng chấm, chấp nhận
> eventual consistency và định nghĩa rõ trạng thái trung gian. Cộng thêm: không join
> được xuyên DB, mọi call có thể timeout, debug phải có traceId, và chi phí vận
> hành tăng gấp nhiều lần monolith — 9 workload thay vì 1 process."

### 6.4 Câu hỏi nối tiếp

- *"Sao không gộp lại thành monolith?"* → Với quy mô đồ án, monolith sẽ đơn giản
  hơn; microservices được chọn để thể hiện bài toán phân tán và vì chấm bài cần
  scale/cách ly riêng.
- *"Saga của em bù trừ thế nào?"* → Nếu chấm thất bại: submission chuyển `FAILED`,
  ghi result `FAILED` (nếu có), dọn container/dind, không để job treo; chi tiết ở
  Chương 2 của báo cáo.
- *"Làm sao biết event bị mất?"* → Hiện dựa vào trạng thái `PENDING` quá lâu +
  `StaleJobReaper`; chưa có outbox pattern — đã ghi ở Hướng phát triển.

---

## 7. Circuit breaker

### 7.1 Vì sao cần

Trong hệ phân tán, một service chậm sẽ **lan** sang service gọi nó:

```
course-service → executor (chậm 30s)
   ⇒ thread/connection của course bị giữ
   ⇒ hết pool ⇒ course chết theo
   ⇒ gateway chờ course ⇒ hết connection ⇒ toàn hệ thống treo
```

Đây là **cascading failure**. Circuit breaker biến "chờ đợi vô vọng" thành "thất
bại nhanh", và cho hệ thống thời gian hồi phục.

### 7.2 Ba trạng thái

| Trạng thái | Hành vi | Chuyển tiếp |
|---|---|---|
| **Closed** | Cho request đi qua, đếm lỗi | Vượt ngưỡng lỗi (vd 50% trong 10s) → **Open** |
| **Open** | **Không gọi** downstream, trả fallback/503 ngay | Sau `waitDuration` → **Half-open** |
| **Half-open** | Cho **một số ít** request thử | Thành công đủ → **Closed**; lỗi → **Open** lại |

Kèm theo (thường đi cùng): **timeout** (chặn chờ vô hạn), **retry có giới hạn +
backoff** (lỗi tạm thời), **bulkhead** (giới hạn concurrency để một phụ thuộc
không nuốt hết thread pool), **fallback** (trả dữ liệu mặc định/cache).

### 7.3 Đồ án hiện có gì (trung thực)

| Cơ chế | Trạng thái | Bằng chứng |
|---|---|---|
| Timeout | ✅ Có | ai-assistant Feign → course/result: `connectTimeout: 2000`, `readTimeout: 3000`; executor: `startup-timeout-ms: 60000`, `max-execution-time-ms: 300000`; LLM có trần `AGENT_ACTIVE_TIMEOUT_SECONDS=120` |
| Retry có giới hạn | ✅ Một phần | `StaleJobReaper` (stale-after 30 phút, interval 5 phút, `max-attempts: 3`); SSE reconnect 1s ở FE |
| Bulkhead | ✅ Một phần | `gradingTaskExecutor` (bean trong `ExecutorServiceApplication`): core=1, max=1, queue=10 ⇒ không chấm vô hạn song song |
| Fail fast | ✅ Có | `X-Gateway-Secret` sai ⇒ 401 ngay; thiếu secret ⇒ 401 (fail closed) |
| Async decoupling | ✅ Có | Kafka tách submission khỏi executor |
| **Circuit breaker** | ❌ **Chưa có** | Không có `resilience4j`/`@CircuitBreaker` trong repo |

Nói thẳng khi bị hỏi: *"Đồ án chưa có circuit breaker. Em có timeout, retry giới
hạn và tách async bằng Kafka để giảm lan truyền lỗi, nhưng thiếu CB. Đây là hạng
mục em sẽ thêm bằng Resilience4j ở gateway và ở các Feign client."*

### 7.4 Nếu thêm thì đặt ở đâu

| Vị trí | CB bảo vệ cái gì | Fallback hợp lý |
|---|---|---|
| Gateway → service | 1 service chết không làm treo toàn bộ route | 503 + `Retry-After` |
| course-service → executor (dry-run) | Dry-run chậm không giữ thread | Trả "executor unavailable" |
| executor → result-service | Không ghi được kết quả ⇒ dừng chấm, không treo job | Đánh dấu `FAILED`, đẩy retry |
| ai-assistant → LLM API | Provider chậm/5xx | Trả fallback template (đã có sẵn cơ chế này khi thiếu API key) |

Cấu hình mẫu (Resilience4j):

```yaml
resilience4j.circuitbreaker.instances.llmClient:
  slidingWindowSize: 20
  failureRateThreshold: 50
  waitDurationInOpenState: 30s
  permittedNumberOfCallsInHalfOpenState: 3
  slowCallDurationThreshold: 5s
  slowCallRateThreshold: 80
```

### 7.5 Câu trả lời mẫu

> "Circuit breaker để chặn cascading failure: khi downstream chậm/chết, thay vì giữ
> thread chờ, ta fail fast và cho downstream thời gian hồi phục. Ba trạng thái là
> closed, open, half-open. Đồ án chưa có CB — em có timeout, retry giới hạn, bulkhead
> cho executor và tách async bằng Kafka; thêm Resilience4j là việc tiếp theo."

---

## 8. Vì sao cần container orchestration

### 8.1 Docker Compose làm được gì

| Việc | Compose |
|---|---|
| Chạy nhiều container trên **một máy** | ✅ |
| Network nội bộ, volume, env | ✅ |
| `depends_on` (chỉ thứ tự start, không phải readiness) | ⚠️ Hạn chế |
| Restart khi container chết | ✅ (`restart: unless-stopped`) |
| Scale nhiều replica | ⚠️ `--scale`, nhưng không có LB/service discovery thật |
| Rolling update không downtime | ❌ |
| Health check + tự rút khỏi LB | ❌ (chỉ có healthcheck, không có endpoint management) |
| Phân bổ pod lên nhiều node | ❌ |
| Resource requests/limits + eviction | ❌ (chỉ có `--memory`, không có scheduler) |
| Secret/Config tập trung, RBAC | ❌ |
| GitOps/desired-state reconciliation | ❌ |

### 8.2 Kubernetes thêm gì

| Khả năng | Cơ chế K8s | Đồ án dùng ở đâu |
|---|---|---|
| **Desired state + reconcile loop** | Controller so `spec` với thực tế, tự sửa | ArgoCD + Deployment/ReplicaSet |
| **Service discovery + LB nội bộ** | Service + EndpointSlice + kube-proxy | `grading-course-service:8081` |
| **Health-aware routing** | readinessProbe rút pod khỏi Endpoints | cả 6 service |
| **Rolling update/rollback** | Deployment strategy + revision | executor `maxSurge: 0`, `maxUnavailable: 1` |
| **Scheduling + tài nguyên** | requests/limits, eviction, OOM score | toàn bộ manifest |
| **Cấu hình/secret** | ConfigMap/Secret + `secretKeyRef` | 8 Secret |
| **GitOps** | CRD Application (ArgoCD) | 6 Application |
| **Namespace/RBAC** | cách ly logic | 3 namespace |
| **PVC** | lưu trữ bền cho stateful | RustFS 10Gi, Prometheus/Tempo/Grafana 2Gi |

### 8.3 Vì sao **vẫn** dùng Compose trong đồ án

Executor chấm bài bằng cách chạy **project compose của sinh viên** trong dind. Đó
là workload **bên trong** một pod, không phải hạ tầng. K8s không phù hợp để tạo
một deployment cho mỗi bài nộp (tạo/xoá hàng trăm object, cần network riêng, thời
gian sống vài phút). Vì vậy: **K8s quản lý nền tảng, Compose quản lý bài chấm.**

### 8.4 Câu trả lời mẫu

> "Compose đủ để chạy nhiều container trên một máy, nhưng thiếu đúng những thứ cần
> cho vận hành: rolling update, health-aware routing, scheduling theo tài nguyên,
> service discovery thật, RBAC và GitOps. K8s có reconcile loop nên trạng thái mong
> muốn trong Git luôn được kéo về. Đồ án vẫn dùng Compose — nhưng ở bên trong
> executor, để chạy bài nộp, không phải để chạy nền tảng."

---

## 9. Resiliency vs High Availability vs Scalability

### 9.1 Phân biệt

| Khái niệm | Câu hỏi trả lời | Đo bằng | Cơ chế |
|---|---|---|---|
| **Resiliency** (khả năng phục hồi) | "Khi có sự cố, hệ thống có **tiếp tục đúng chức năng** (có thể giảm cấp) và **tự hồi** không?" | MTTR, tỉ lệ request thành công trong sự cố | retry, timeout, CB, bulkhead, fallback, degrade, idempotency, self-heal |
| **High Availability** | "Hệ thống có **luôn sẵn sàng** không, kể cả khi một phần chết?" | Uptime %, số 9 (99.9% = 8.76h/năm) | replica ≥2, nhiều node/AZ, LB, failover, DB HA, PDB |
| **Scalability** | "Tăng tải thì có **tăng năng lực** tương ứng không?" | Throughput vs latency theo tải, chi phí/request | horizontal scale, stateless, cache, sharding, async |

Quan hệ: **HA ⊂ resiliency** (HA là một phần của chịu lỗi), còn **scalability độc
lập** — hệ có thể scale tốt nhưng không HA, hoặc HA nhưng không scale.

### 9.2 Đồ án đang ở đâu (nói thật)

| Tiêu chí | Trạng thái | Bằng chứng |
|---|---|---|
| Resiliency | **Một phần** | Có timeout, retry giới hạn, bulkhead executor, webhook/Kafka chịu lỗi tạm thời, fail closed; **chưa có CB**, chưa có DLQ/outbox |
| High Availability | **Không** | 1 node, 5/6 service 1 replica, Keycloak 1 replica, không PDB, không multi-AZ |
| Scalability | **Có thiết kế, chưa đo** | Stateless service (JWT + DB), scale bằng replica; executor tách riêng; DB managed scale dọc; **chưa có HPA**, chưa đo > 5 VU |

### 9.3 Câu trả lời mẫu

> "Ba khái niệm khác nhau: resiliency là chịu lỗi và tự hồi; HA là luôn sẵn sàng
> khi một phần chết; scalability là tăng năng lực khi tăng tải. Đồ án em làm tốt
> phần resiliency ở mức cơ bản — timeout, retry giới hạn, async, fail closed —
> nhưng **không HA** vì 1 node và phần lớn 1 replica. Scalability có thiết kế
> stateless và scale ngang, nhưng chưa đo tải cao."

### 9.4 Câu hỏi nối tiếp

- *"Muốn HA thì làm gì trước?"* → replica ≥2 cho gateway/course/result/submission,
  PDB, ≥3 node, DB HA (Neon multi-AZ), Keycloak cluster hoặc ít nhất 2 replica sau
  LB; và bỏ phụ thuộc `local-path` cho dữ liệu quan trọng.
- *"Resiliency khác fault tolerance?"* → Fault tolerance là chịu lỗi mà **không
  giảm chức năng**; resiliency rộng hơn, gồm cả degrade và phục hồi.

---

## 10. Horizontal vs Vertical scaling

### 10.1 So sánh

| | Vertical (scale up) | Horizontal (scale out) |
|---|---|---|
| Cách làm | Thêm CPU/RAM cho **một** instance | Thêm **nhiều** instance |
| Giới hạn | Trần phần cứng/VM, thường đắt phi tuyến | Gần như không giới hạn (thêm node) |
| Downtime | Thường phải restart | Rolling, không downtime |
| Yêu cầu | Không cần sửa app | App phải **stateless** hoặc có shared state |
| Consistency | Đơn giản | Cần LB, session/JWT, lock, cache coherence |
| Chi phí | Tăng theo bậc (RAM lớn rất đắt) | Tuyến tính, nhưng tăng độ phức tạp vận hành |
| Phù hợp | DB, cache, app nhỏ, tải tăng chậm | Web/API, worker, tải biến động |

### 10.2 Trong đồ án

| Thành phần | Cách scale hiện tại | Ghi chú |
|---|---|---|
| 5 service CRUD | **Vertical gián tiếp** (limit 512Mi/service, cố định 1 replica) | Muốn scale ngang: tăng `replicas` + PDB + resources |
| executor | **Horizontal**: `replicaCount: 2` | Mỗi pod có dind riêng ⇒ scale ngang an toàn vì job không gắn với pod |
| Keycloak | Vertical (768Mi limit) | `start-dev` không cluster ⇒ không scale ngang thật |
| PostgreSQL (Neon) | **Vertical** (managed) + read replica nếu cần | Scale ngang DB cần sharding/partitioning — ngoài phạm vi |
| RustFS | Vertical (1 pod, PVC RWO) | Scale ngang cần distributed mode + shared storage |
| Prometheus/Tempo | Vertical (RAM/PVC) | Scale ngang cần sharding/remote storage |

Vì sao service CRUD **có thể** scale ngang: chúng **stateless** — token JWT tự
chứa danh tính, không session server-side; dữ liệu ở Postgres dùng chung. Đó là
lý do không cần sticky session.

### 10.3 Khi nào chọn cái nào

| Chọn vertical khi | Chọn horizontal khi |
|---|---|
| Tải còn nhỏ, tăng chậm | Tải biến động, cần co giãn |
| App có state khó tách (DB) | App stateless |
| Muốn đơn giản, ít thành phần | Cần HA kèm theo (nhiều instance = chịu lỗi) |
| Ngân sách hạn chế ở quy mô nhỏ | Cần chịu tải lớn, dài hạn |

Quy tắc thực dụng: **scale dọc trước cho DB, scale ngang cho app**; nhưng trên
node 8 GB thì scale dọc bị chặn bởi RAM node ⇒ phải thêm node trước khi scale ngang.

### 10.4 Câu trả lời mẫu

> "Vertical là thêm tài nguyên cho một máy, horizontal là thêm instance. Đồ án
> scale ngang cho executor vì job chấm không gắn với pod; các service CRUD thiết kế
> stateless nên scale ngang được nhưng em giữ 1 replica vì node 8 GB. DB và RustFS
> em scale dọc. Thứ tự thực tế: thêm node rồi mới tăng replica, vì thêm replica
> trên node đã khít RAM chỉ tạo pod Pending."

---

## 11. Public subnet vs Private subnet

### 11.1 Định nghĩa (trong VPC/cloud network)

| | Public subnet | Private subnet |
|---|---|---|
| Route ra Internet | Có route `0.0.0.0/0` → **Internet Gateway** | Không có IGW; ra ngoài qua **NAT Gateway** (one-way out) |
| Ai vào được từ Internet | Tài nguyên có public IP / LB | Không; chỉ vào được qua bastion/LB/VPN |
| Dùng cho | Load balancer, bastion host, NAT Gateway | App server, database, cache, worker |
| Bảo mật | Bề mặt tấn công lớn hơn | Mặc định không tiếp cận được từ ngoài |

### 11.2 Đồ án ánh xạ thế nào

Đồ án **không tự thiết kế VPC/subnet** (1 node, dịch vụ managed). Ánh xạ khái niệm:

| Vai trò public | Vai trò private |
|---|---|
| Cloudflare edge: điểm duy nhất nhận traffic Internet | Cluster network: pod chỉ có IP nội bộ, Service `ClusterIP` |
| Cloudflare tunnel: kênh **outbound-only** từ node | Không có inbound port nào mở trên router/firewall |
| DNS public: `web-dev1-*.vucongtuanduong.dpdns.org` | `grading-*:8080..8086` chỉ phân giải trong cụm |
| — | PostgreSQL Neon, Kafka Aiven: nằm trong VPC của nhà cung cấp, truy cập qua TLS + credential |

Điểm mạnh: mô hình "không mở inbound port" đạt được lợi ích **tương đương private
subnet** (origin không tiếp cận trực tiếp) mà không cần NAT Gateway/bastion.
Điểm yếu: không có cách ly mạng thật giữa các pod (không NetworkPolicy), và tunnel
là single point of failure.

### 11.3 Nếu làm đúng chuẩn cloud

```
VPC 10.0.0.0/16
├── Public subnet 10.0.1.0/24   → ALB/NLB, NAT Gateway, bastion
├── Private subnet 10.0.2.0/24  → node/pod app (không public IP)
└── Private subnet 10.0.3.0/24  → RDS/ElastiCache (chỉ nhận từ app SG)
Security Group: ALB → app:8080; app → DB:5432; không rule nào từ 0.0.0.0/0 vào app/DB
```

### 11.4 Câu trả lời mẫu

> "Public subnet có route ra Internet Gateway nên tài nguyên có thể nhận traffic
> trực tiếp; private subnet ra ngoài qua NAT và không nhận inbound. Đồ án không
> thiết kế subnet riêng: origin không mở port nào, traffic vào qua Cloudflare
> tunnel outbound-only, còn DB/Kafka là managed service nằm trong VPC của nhà cung
> cấp. Về bản chất là 'private by default', nhưng thiếu NetworkPolicy để cách ly
> giữa các pod."

---

## 12. Object vs Block vs File storage

### 12.1 So sánh

| | **Object storage** | **Block storage** | **File storage** |
|---|---|---|---|
| Đơn vị | Object (key → bytes + metadata) | Block (sector) | File trong thư mục |
| Truy cập | HTTP/S3 API (GET/PUT), presigned URL | Gắn vào máy như ổ đĩa, đọc/ghi block | Giao thức file: NFS/SMB |
| Cấu trúc | Phẳng (bucket + key), không thư mục thật | Không có cấu trúc; cần filesystem | Cây thư mục, permission |
| Scale | Rất lớn, ngang | Giới hạn theo volume | Trung bình, phụ thuộc server |
| Sửa file | Ghi lại toàn bộ object | Sửa từng block | Sửa từng phần file |
| Độ trễ | ms–chục ms, qua mạng | µs–ms (gắn trực tiếp) | ms (qua mạng) |
| Consistency | Thường strong per-object (tuỳ provider) | Do filesystem/DB đảm bảo | Do NFS server |
| Dùng cho | Ảnh, video, backup, file tải lên, data lake | Database, OS disk, PVC của app | Chia sẻ file giữa nhiều máy, home dir, CMS cũ |
| Ví dụ | S3, GCS, **RustFS**, MinIO | EBS, Cinder, ổ SSD/HDD, `local-path` PV | EFS, NFS, SMB/CIFS, GlusterFS |

### 12.2 Đồ án dùng loại nào

| Dữ liệu | Loại | Cụ thể |
|---|---|---|
| ZIP bài nộp | **Object** | RustFS bucket `submission-files`, key `submissions/<id>.zip`, presigned PUT 15 phút |
| Database (lớp, điểm, kết quả) | **Block** (ẩn bên dưới) | Neon chạy trên block storage; Postgres quản lý file/trang |
| PVC RustFS (10Gi), Prometheus/Tempo/Grafana (2Gi) | **Block** | StorageClass `local-path` ⇒ PV là thư mục trên filesystem của đĩa node, cấp cho pod như ổ `ReadWriteOnce` |
| Chia sẻ file giữa nhiều node | **File** | **Không dùng** — mọi thứ cần share đều đi qua API/object storage |

Lưu ý ngôn ngữ: `local-path` PV thực chất là **thư mục trên đĩa** ⇒ với pod nó
hành xử như block device đã format; nó **không** phải file storage chia sẻ, vì chỉ
gắn được `ReadWriteOnce` trên một node.

### 12.3 Vì sao ZIP bài nộp dùng object storage

| Lý do | Giải thích |
|---|---|
| Upload trực tiếp từ browser | Presigned URL cho phép FE `PUT` thẳng lên storage, không qua backend (không tốn RAM/bandwidth của service) |
| File lớn, không cần sửa từng phần | Object ghi một lần, đọc nhiều lần (immutable) |
| Scale ngang | Thêm dung lượng không cần gắn ổ vào từng node |
| Cách ly | Backend chỉ giữ metadata (DB), không giữ file |
| Không cần POSIX | Không ai `open()` file ZIP trên storage; executor tải về rồi giải nén trong workspace |

### 12.4 Câu trả lời mẫu

> "Object storage làm việc với object qua HTTP API, phẳng, scale ngang, phù hợp file
> bài nộp; block storage là ổ đĩa cho database/PVC, độ trễ thấp nhưng gắn một máy;
> file storage chia sẻ cây thư mục qua NFS/SMB. Đồ án dùng RustFS (object) cho ZIP,
> block cho DB và PVC, và không dùng file storage."

---

## 13. Bảng trả lời nhanh 1 dòng

| Câu hỏi | Trả lời 1 dòng |
|---|---|
| Sync vs Async | Sync chờ kết quả và fail ngay; async tách qua event/queue, chấp nhận eventual |
| Polling vs Push | Polling client hỏi định kỳ (đơn giản, chịu lỗi); push server đẩy (realtime, cần reconnect) |
| Short vs Long polling | Short lặp theo chu kỳ; long giữ request tới khi có dữ liệu/timeout |
| Khi nào polling | Kết quả chậm, tần suất thấp, hạ tầng chặn long-lived connection |
| Khi nào push | Nhiều event/giây, cần realtime, kiểm soát được timeout proxy |
| Layer của 1 request | Edge → ingress → gateway (authN, header) → service filter (trust) → controller → service → repository → DB |
| Reverse proxy | Đứng thay server, ẩn backend, TLS/LB/routing (Cloudflare, Traefik, gateway) |
| Forward proxy | Đứng thay client, ẩn client, kiểm soát chiều ra (`HTTP_PROXY`) |
| Idempotent methods | GET, HEAD, OPTIONS, PUT, DELETE; PATCH tuỳ; POST không |
| Idempotency trong đồ án | publish no-op, webhook dedupe theo status, result "latest" + unique index, PUT replace components |
| Khó nhất của microservices | Mất ACID/join xuyên DB, lỗi mạng, debug phân tán, chi phí vận hành |
| Vì sao circuit breaker | Chặn cascading failure, fail fast, cho downstream thời gian hồi phục |
| Vì sao orchestration | Desired state + reconcile, rolling update, health routing, scheduling, GitOps |
| Compose vs K8s | Compose: 1 máy, không rolling/health-routing; K8s: nhiều node, tự hồi, GitOps |
| Resiliency | Chịu lỗi + tự hồi (kể cả giảm cấp) |
| High Availability | Luôn sẵn sàng khi một phần chết (replica, multi-node/AZ, failover) |
| Scalability | Tăng năng lực khi tăng tải (throughput/latency theo tải) |
| Horizontal vs Vertical | Thêm instance vs thêm tài nguyên; ngang cần stateless |
| Public vs Private subnet | Public có route IGW, nhận inbound; private ra ngoài qua NAT, không inbound |
| Object vs Block vs File | Object qua HTTP/S3 phẳng; block là ổ đĩa; file là cây thư mục qua NFS/SMB |
