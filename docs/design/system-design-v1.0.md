# System Design v1.0 — Web Grading System

> **Version:** v1.0
> **Ngày:** 2026-08-16
> **Trạng thái:** Current
> **Thay thế:** `docs/architecture/architecture.md` (thiết kế cũ có Eureka/Config Server/notification service — không còn khớp repo hiện tại)
> **Tài liệu liên quan:** DB chi tiết → `design-db-v1.0.md` · Cách chấm thật → `execute-plan-v1.0.md`

---

## Mục lục

1. [Mục tiêu & nguyên tắc](#1-mục-tiêu--nguyên-tắc)
2. [Use cases → Service](#2-use-cases--service)
3. [Danh sách services](#3-danh-sách-services)
4. [Giao tiếp giữa services](#4-giao-tiếp-giữa-services)
5. [Kafka topics & message contracts](#5-kafka-topics--message-contracts)
6. [Không làm trong v1 (deferred)](#6-không-làm-trong-v1-deferred)
7. [Changelog](#7-changelog)

---

## 1. Mục tiêu & nguyên tắc

### 1.1 Bài toán

Hệ thống chấm bài tự động môn Lập trình Web. Giảng viên tạo bài tập gồm các test plan (kịch bản test nhiều bước, kiểm tra HTTP API và DB). Sinh viên nộp file zip (Dockerfile + docker-compose.yml). Hệ thống chạy container của sinh viên lên, thực thi các test plan và chấm điểm tự động.

### 1.2 Nguyên tắc thiết kế

1. **Single Responsibility** — mỗi service chỉ làm 1 việc, đúng tên gọi.
2. **DB-per-Service** — mỗi service có DB riêng, không share trực tiếp.
3. **Async grading** — nộp bài không block; chấm qua Kafka.
4. **Stateless** — mọi service stateless, trạng thái nằm trong DB/Kafka.
5. **Không Eureka / Không Config Server** — K8s Service (DNS) + Helm values + env var đã đủ cho phạm vi đồ án.
6. **Pragmatic scale** — phần cứng giới hạn (RAM), chỉ thêm service khi thật sự cần.

### 1.3 Tech stack (hiện tại)

| Layer | Công nghệ |
|---|---|
| Service framework | Spring Boot 4.1, Java 21 |
| Message queue | Kafka |
| Database | PostgreSQL (1 DB / service) |
| Object storage | RustFS (S3-compatible) |
| Auth | Keycloak (JWT, qua API Gateway) |
| Container runtime | Docker (DinD sidecar trong executor pod) |
| Frontend | React + TypeScript |
| Deployment | K8s (k3s) + Helm + ArgoCD |

---

## 2. Use cases → Service

### 2.1 Giảng viên

| Use case | Service xử lý |
|---|---|
| Quản lý lớp: tạo lớp, archive theo kỳ | course-service |
| Import sinh viên vào lớp (CSV/Excel) | course-service |
| Tạo bài tập, khai báo docker image, compose template | course-service |
| Tạo test plan / test step (endpoint, DB, auth, multi-step) | course-service |
| Chấm điểm (tự động khi SV nộp) | executor-service |
| Nhập tay điểm chuyên cần / điểm khác | result-service |
| Xem điểm, xem thống kê | result-service |
| Xem log chấm bài từng bước | result-service (đọc từ result DB) |

### 2.2 Sinh viên

| Use case | Service xử lý |
|---|---|
| Đổi mật khẩu lần đầu | Keycloak (không thuộc hệ thống) |
| Xem lớp của mình, danh sách sinh viên trong lớp | course-service |
| Xem danh sách/chi tiết bài tập | course-service |
| Nộp bài (zip), kiểm tra trạng thái | submission-service |
| Xem điểm, nhận xét | result-service |

### 2.3 Hệ thống

| Use case | Service xử lý |
|---|---|
| Chạy container SV, thực thi test steps | executor-service |
| Ghi log chi tiết từng step (input cho AI sau này) | executor-service |

---

## 3. Danh sách services

| # | Service | Port | DB | Trạng thái hiện tại |
|---|---|---|---|---|
| 1 | api-gateway | 8080 | — | Skeleton |
| 2 | course-service | 8081 | `assignment_db` | Skeleton |
| 3 | submission-service | 8082 | `submission_db` | Hoạt động (presigned + webhook), thiếu Kafka |
| 4 | executor-service | 8083 | `executor_db` | Skeleton |
| 5 | result-service | 8084 | `result_db` | Skeleton |

### 3.1 api-gateway

**Trách nhiệm:** Entry point duy nhất. Validate JWT (OAuth2 Resource Server), route theo path, inject header `X-User-Id`, `X-User-Role` cho downstream services.

**Không có DB.**

**Route table:**

| Path | Target | Ghi chú |
|---|---|---|
| `/api/v1/classes/**` | course-service | |
| `/api/v1/assignments/**` | course-service | |
| `/api/v1/docker-images/**` | course-service | |
| `/api/v1/submissions/**` | submission-service | |
| `/api/v1/results/**` | result-service | |

**Chặn ngoài gateway:** mọi internal endpoint (`/api/v1/internal/**`) không expose ra ngoài (chỉ gọi trong cluster network).

### 3.2 course-service

**Trách nhiệm:** Toàn bộ nội dung giảng viên tạo — lớp học, sinh viên trong lớp, bài tập, docker images, test plans, test steps.

**Public API:**

```
POST   /api/v1/classes                     — Tạo lớp
GET    /api/v1/classes                     — DS lớp của tôi (phân trang)
GET    /api/v1/classes/{id}                — Chi tiết lớp
PATCH  /api/v1/classes/{id}/archive        — Archive lớp khi hết kỳ
POST   /api/v1/classes/{id}/students/import — Import SV từ CSV
GET    /api/v1/classes/{id}/students       — DS sinh viên trong lớp

POST   /api/v1/assignments                 — Tạo bài tập (thuộc 1 lớp)
GET    /api/v1/assignments                 — DS bài tập
GET    /api/v1/assignments/{id}            — Chi tiết
PUT    /api/v1/assignments/{id}            — Sửa
DELETE /api/v1/assignments/{id}            — Xoá (soft delete)
POST   /api/v1/assignments/{id}/publish    — Publish cho SV nộp

POST   /api/v1/assignments/{id}/plans      — Tạo test plan
GET    /api/v1/assignments/{id}/plans      — DS plans
PUT    /api/v1/assignments/{id}/plans/{pid}          — Sửa plan
POST   /api/v1/assignments/{id}/plans/{pid}/steps     — Thêm step
PUT    /api/v1/assignments/{id}/plans/{pid}/steps/{sid} — Sửa step
DELETE /api/v1/assignments/{id}/plans/{pid}/steps/{sid} — Xoá step

POST   /api/v1/docker-images               — Khai báo docker image
GET    /api/v1/docker-images               — DS images
DELETE /api/v1/docker-images/{id}          — Xoá
```

**Internal API (chỉ service khác gọi Feign):**

```
GET /api/v1/internal/assignments/{id}                 — executor: toàn bộ cấu hình chấm (strategy, template, port, timeout, resource limits)
GET /api/v1/internal/assignments/{id}/plans           — executor: plans + steps (đã sắp xếp)
GET /api/v1/internal/assignments/{id}/exists          — submission: validate assignment tồn tại + published
```

**Kế thừa:** class + student import là domain mới; phần assignment/plan/step lấy từ thiết kế `docs/db/README.md`.

### 3.3 submission-service

**Trách nhiệm:** Nhận bài nộp — presigned URL upload lên RustFS, confirm upload (webhook), lưu bản ghi submission, publish message grading qua Kafka.

**Public API (đã có, giữ nguyên):**

```
POST  /api/v1/submissions/presigned-url     — Request upload URL
POST  /api/v1/submissions/{id}/confirm      — Confirm upload (FE gọi)
GET   /api/v1/submissions                   — Bài nộp của tôi
GET   /api/v1/submissions/{id}              — Chi tiết
GET   /api/v1/submissions/assignment/{id}   — DS bài nộp của 1 bài tập
GET   /api/v1/submissions/{id}/download     — Presigned download URL
GET   /api/v1/submissions/{id}/download/file — Stream file
POST  /api/v1/submissions/webhook/upload-complete  — RustFS webhook (đã có)
```

**Internal API:**

```
PATCH /api/v1/submissions/{id}/status       — executor cập nhật trạng thái (đã có)
```

**Thay đổi cần làm trong v1:**
- Thêm cột `plan_id` cho `submissions` (SV có thể chọn plan để chấm; null = chạy tất cả).
- Thêm Kafka producer: khi webhook/confirm xác nhận upload xong → publish message vào topic `grading-jobs`.

### 3.4 executor-service

**Trách nhiệm:** Service quan trọng nhất — Kafka consumer. Nhận job, tải zip từ RustFS, chạy docker compose (qua DinD), thực thi từng test step, tính điểm, ghi `grading_step_results`, báo kết quả cho result-service và cập nhật trạng thái submission.

**Không có public API.** Chỉ có:
- Kafka consumer (`grading-jobs`)
- Feign clients: course-service (lấy plan), submission-service (PATCH status), result-service (lưu kết quả)
- RustFS client (download zip)
- Docker client (DinD socket)

**Cấu trúc module đề xuất:**

```
executor-service/
├── consumer/GradingJobConsumer.java        # @KafkaListener, điều phối
├── service/
│   ├── GradingOrchestrator.java            # Luồng chấm 1 job
│   ├── DockerService.java                  # compose up/down, readiness
│   ├── DockerComposePatcher.java           # Patch resource limits + port
│   ├── PortAllocator.java                  # Cấp port nội bộ pod
│   ├── step/
│   │   ├── StepExecutor.java               # Interface chung
│   │   ├── HttpStepExecutor.java
│   │   ├── DbQueryStepExecutor.java
│   │   ├── DbSchemaCheckStepExecutor.java
│   │   ├── DbMigrationStepExecutor.java
│   │   ├── ExtractStepExecutor.java
│   │   └── DelayStepExecutor.java
│   ├── VariableContext.java                # Biến chia sẻ giữa các step
│   ├── AssertionEngine.java                # So sánh expected vs actual
│   └── ScoreCalculator.java
├── client/                                 # Feign + RustFS
└── repository/                             # grading_jobs, grading_step_results, grading_logs
```

### 3.5 result-service

**Trách nhiệm:** Lưu điểm, kết quả từng step, điểm nhập tay; phục vụ xem điểm & thống kê.

**Public API:**

```
GET  /api/v1/results/{submissionId}                      — Kết quả 1 bài nộp
GET  /api/v1/results/my                                  — Điểm của tôi
GET  /api/v1/results/assignment/{assignmentId}           — Điểm toàn bộ bài tập (lecturer)
GET  /api/v1/results/assignment/{assignmentId}/stats     — Thống kê (avg, distribution)
GET  /api/v1/results/class/{classId}                     — Bảng điểm cả lớp (lecturer)

POST /api/v1/results/manual-scores                       — Nhập tay điểm chuyên cần...
GET  /api/v1/results/manual-scores?classId=...           — DS điểm nhập tay
PUT  /api/v1/results/manual-scores/{id}                  — Sửa
```

**Internal API:**

```
POST /api/v1/internal/results                            — executor ghi kết quả chấm
```

---

## 4. Giao tiếp giữa services

| From | To | Protocol | Mục đích |
|---|---|---|---|
| Client | api-gateway | HTTP | Mọi request từ FE |
| api-gateway | Tất cả services | HTTP (K8s DNS) | Route + inject auth headers |
| submission-service | course-service | Feign | Validate assignment tồn tại + published |
| submission-service | RustFS | S3 SDK | Presigned URL upload |
| submission-service | Kafka | Producer | `grading-jobs` |
| executor-service | Kafka | Consumer | `grading-jobs` |
| executor-service | RustFS | S3 SDK | Download zip |
| executor-service | course-service | Feign | Lấy assignment + plans/steps |
| executor-service | submission-service | Feign | PATCH status |
| executor-service | result-service | Feign | Ghi kết quả |
| executor-service | Docker (DinD) | Docker socket | Chạy container SV |

**Không dùng service discovery:** tên service = DNS trong K8s (vd `course-service.web-grading.svc.cluster.local`), cấu hình qua env var trong Helm values.

---

## 5. Kafka topics & message contracts

### 5.1 `grading-jobs`

| Thuộc tính | Giá trị |
|---|---|
| Partitions | 3 (dev) — ≥ concurrency của executor |
| Replication | 1 (dev) / 3 (prod) |
| Retention | 7 ngày |
| Key | `submissionId` |
| Producer | submission-service |
| Consumer | executor-service (consumer group `executor-group`) |

**Payload:**

```json
{
  "submissionId": "550e8400-e29b-41d4-a716-446655440000",
  "assignmentId": "660e8400-e29b-41d4-a716-446655440001",
  "studentId": "770e8400-e29b-41d4-a716-446655440002",
  "planId": null,
  "rustfsPath": "submissions/550e8400-e29b-41d4-a716-446655440000.zip",
  "timestamp": "2026-08-16T10:00:00Z"
}
```

### 5.2 Không có topic khác trong v1

Không tạo `notifications` topic khi chưa có consumer — chờ khi làm notification service (xem mục 6).

---

## 6. Không làm trong v1 (deferred)

| Hạng mục | Lý do | Khi nào làm |
|---|---|---|
| **Notification service (WebSocket)** | Giới hạn RAM cluster; FE poll trạng thái submission là đủ | Khi cần realtime, thêm service + topic `notifications` |
| **Eureka / Config Server** | K8s DNS + Helm values đã đủ | Không cần |
| **Service riêng cho user/class** | Class nằm trong course-service, auth nằm ở Keycloak | Không cần |
| **DB test cho MySQL/MariaDB** | Chỉ hỗ trợ PostgreSQL trong v1 | Khi có bài tập yêu cầu DB khác |
| **Step type `SCRIPT`** | Chạy script tuỳ chỉnh — rủi ro bảo mật cao, chưa có nhu cầu cụ thể | Khi có yêu cầu thật |
| **AI module (Agent tạo bài tập, chatbot nhận xét)** | Nghiên cứu, chưa phải việc chính | Sau khi hệ thống chấm ổn định |

---

## 7. Changelog

| Version | Ngày | Thay đổi |
|---|---|---|
| v1.0 | 2026-08-16 | Bản đầu tiên. Tách 5 services theo use case, định nghĩa giao tiếp và Kafka contract |