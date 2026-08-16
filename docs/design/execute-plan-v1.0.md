# Execute Plan v1.0 — Cách thực thi grading thật

> **Version:** v1.0
> **Ngày:** 2026-08-16
> **Trạng thái:** Current
> **Phạm vi:** Luồng chấm bài đầy đủ từ lúc sinh viên nộp đến khi có điểm — tập trung vào executor-service, phần khó nhất của hệ thống.
> **Tài liệu liên quan:** Service & giao tiếp → `system-design-v1.0.md` · Schema → `design-db-v1.0.md`

---

## Mục lục

1. [Tổng quan luồng](#1-tổng-quan-luồng)
2. [Trigger: nộp bài → Kafka](#2-trigger-nộp-bài--kafka)
3. [Pipeline chấm bài của executor](#3-pipeline-chấm-bài-của-executor)
4. [Step execution engine](#4-step-execution-engine)
5. [Tính điểm & báo kết quả](#5-tính-điểm--báo-kết-quả)
6. [Failure paths](#6-failure-paths)
7. [Concurrency & scale](#7-concurrency--scale)
8. [Bảo mật & an toàn](#8-bảo-mật--an-toàn)
9. [Changelog](#9-changelog)

---

## 1. Tổng quan luồng

```
Sinh viên                              Submission Service              Executor Service (N pods)          Result Service
   │                                           │                               │                              │
   │ 1. POST /submissions/presigned-url        │                               │                              │
   │◄──── uploadUrl + submissionId ────────────│                               │                              │
   │ 2. PUT file zip lên RustFS (presigned)    │                               │                              │
   │                                           │◄── RustFS webhook upload-complete ──│                     │
   │                                           │ 3. status = PENDING               │                              │
   │                                           │ 4. publish Kafka: grading-jobs ──▶│                              │
   │                                           │                               │ 5. persist grading_job      │
   │                                           │                               │ 6. fetch assignment+plans   │
   │                                           │◄── PATCH status=GRADING ───────│                              │
   │                                           │                               │ 7. download+unzip zip      │
   │                                           │                               │ 8. patch compose + up (DinD)│
   │                                           │                               │ 9. chạy từng step          │
   │                                           │                               │ 10. tính điểm              │
   │                                           │◄── PATCH status=DONE/FAILED ───│                              │
   │                                           │                               │── POST /internal/results ─▶│
   │◄────────── GET /results/{submissionId} ─────────────────────────────────────────────────────────────────│
```

Toàn bộ grading là **bất đồng bộ**: sinh viên nộp xong nhận ngay `submissionId`, điểm có sau khi executor xử lý xong (FE poll trạng thái).

---

## 2. Trigger: nộp bài → Kafka

Đã có sẵn flow upload (presigned URL + webhook). Cần thêm 1 bước:

**SubmissionService.handleUploadComplete** (sau khi xác nhận file đã lên RustFS — qua webhook hoặc confirm từ FE):

1. Cập nhật `submissions.status = PENDING` (đã có).
2. Nếu submission đang có `latest = true` cũ → set `latest = false` (đã có ở bước tạo presigned).
3. Publish message vào Kafka topic `grading-jobs`, key = `submissionId`.

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

> Webhook RustFS có thể gọi nhiều lần cho cùng object → cần **idempotent**: trước khi publish, check submission đã ở trạng thái `GRADING`/`DONE`/`FAILED` thì bỏ qua (hoặc dùng Kafka key trùng submissionId + dedupe ở executor qua `grading_jobs.submission_id` unique).

---

## 3. Pipeline chấm bài của executor

`GradingJobConsumer` (Kafka listener, `concurrency = N` thread) → `GradingOrchestrator.execute(job)`.

### Bước 0 — Nhận job & persist

- Tạo `grading_jobs` row: `status = PENDING`.
- Chống trùng: nếu đã có job `DONE`/`RUNNING` cho submissionId → bỏ qua (idempotent).

### Bước 1 — Fetch cấu hình chấm (Feign → assignment-service)

```
GET /api/v1/internal/assignments/{assignmentId}
GET /api/v1/internal/assignments/{assignmentId}/plans
```

Nhận được:
- `grading_strategy`, `docker_compose_template`, `docker_compose_port`
- `startup_timeout_ms`, `execution_timeout_ms`, `max_memory_mb`, `max_cpu`
- Danh sách plans + steps (đã sắp xếp theo `sequence_order`/`step_order`)

Nếu `job.planId != null` → chỉ chạy plan đó. Ngược lại chạy tất cả plans tuần tự.

### Bước 2 — Download & giải nén

- Tải zip từ RustFS (S3 SDK, presigned download hoặc SDK trực tiếp) vào `/tmp/grading/<submissionId>/submission.zip`.
- Giải nén vào `/tmp/grading/<submissionId>/`.
- **Chống zip-slip:** validate từng entry path khi giải nén (không cho `../`, không cho absolute path).

### Bước 3 — Chuẩn bị docker-compose

**Strategy `STUDENT_DOCKER_COMPOSE`:**
- Tìm `docker-compose.yml` (hoặc `.yaml`) trong zip. Không có → FAIL ngay: "docker-compose.yml not found".
- Dùng compose của SV.

**Strategy `LECTURER_DOCKER_COMPOSE`:**
- Ghi `docker_compose_template` vào `/tmp/grading/<submissionId>/docker-compose.yml`.
- Giải nén mã nguồn SV vào `/tmp/grading/<submissionId>/app/`.
- Template phải khai báo volume mount code: `./app:/app` (giảng viên viết template đúng quy ước này).

### Bước 4 — Patch compose

`DockerComposePatcher` sửa compose với 3 việc:

1. **Resource limits** — thêm vào mỗi service:
   ```yaml
   deploy:
     resources:
       limits:
         cpus: '<max_cpu>'
         memory: <max_memory_mb>M
   ```
   (lấy từ `assignments.max_memory_mb`, `max_cpu`).

2. **Port mapping app** — tìm service là app (service đầu tiên có khai báo `ports` trong compose gốc), expose lên port đã cấp:
   ```yaml
   ports:
     - "<allocatedAppPort>:<docker_compose_port>"
   ```
   `docker_compose_port` = port app lắng nghe trong container (mặc định 8080).

3. **Port mapping DB** — nếu plan có step type DB (`DB_QUERY`/`DB_SCHEMA_CHECK`/`DB_MIGRATION`):
   - Lấy `connection.db_service` (mặc định `db`) + `connection.db_port` (mặc định 5432).
   - Patch service `db_service` expose ra port đã cấp:
     ```yaml
     ports:
       - "<allocatedDbPort>:<db_port>"
     ```
   - Service DB không tồn tại trong compose → step DB đó sẽ FAILED với message rõ ràng.

> Nếu compose SV không khai báo `ports` cho app (chỉ build, không publish) — fallback: patch service đầu tiên.

### Bước 5 — Docker compose up (qua DinD)

```bash
docker compose -p sub-<submissionId> -f docker-compose.yml up -d --build
```

- Chạy với **timeout** = `startup_timeout_ms` + thời gian build hợp lý (vd 5 phút build). Quá hạn → kill, FAILED.
- Executor chạy trong K8s pod có **DinD sidecar** (Docker daemon riêng cho pod) → không phụ thuộc docker.sock trên node k3s, cô lập giữa các executor pod.
- Log output build vào `grading_logs` (level INFO) để dễ debug.

### Bước 6 — Chờ container ready

Poll `http://localhost:<allocatedAppPort>` với các path phổ biến (`/`, `/api`, `/health`, `/actuator/health`, `/api/v1`...) cho đến khi:
- Nhận status < 500 → ready; hoặc
- Hết `startup_timeout_ms` → FAILED: "Container failed to start within timeout".

### Bước 7 — Chạy các plans & steps

Chi tiết ở mục 4. Mỗi plan chạy tuần tự các step; kết quả ghi vào `grading_step_results`.

### Bước 8 — Cleanup (luôn chạy, kể cả khi fail — `finally`)

1. `docker compose -p sub-<submissionId> down --volumes --remove-orphans --timeout 10`
2. Xoá `/tmp/grading/<submissionId>/`
3. Giải phóng port trong `PortAllocator`

---

## 4. Step execution engine

### 4.1 VariableContext — chia sẻ biến giữa các step

Một `Map<String, Object>` sống trong suốt 1 job, chứa:

- **Biến built-in** (executor tự đặt trước khi chạy steps):
  - `app_port` — port host của app SV
  - `db_port` — port host của DB (nếu có DB steps)
  - `submission_id`, `assignment_id`, `student_id`
- **Biến từ `EXTRACT` steps** và **biến cố định** (`value` trong EXTRACT config).
- **Biến từ DB steps**: result của `DB_QUERY`/`DB_MIGRATION` có thể extract.

**Substitution:** trước khi execute mỗi step, executor replace mọi `${var}` trong `config` (path, headers, body, query, connection, expected...) bằng giá trị trong context. Thiếu biến → thay bằng chuỗi rỗng + ghi WARN (bước sau có thể fail và ta biết lý do).

### 4.2 StepExecutor — interface chung

```java
public interface StepExecutor {
    StepType type();
    StepResult execute(StepContext ctx);   // ctx: config đã substitute + variableContext + resolved connection
}
```

Mỗi step type 1 executor. Registry `Map<StepType, StepExecutor>` — thêm type mới = thêm 1 class, không đổi gì khác.

### 4.3 Từng executor

**HTTP_REQUEST** — `java.net.http.HttpClient` (JDK built-in, không cần Feign động):
1. Build request: method, path (đã resolve + thay biến), headers, body (JSON string).
2. Send với timeout = `step.timeout_ms`.
3. Capture: status, headers, body.
4. Chạy `AssertionEngine` với `expected_status` + `assertions` (xem 4.4).
5. Nếu có `extract` → JSONPath lấy giá trị từ response body, đưa vào `VariableContext`.
6. Ghi `grading_step_results` (đầy đủ request/response/expected/actual/assertion_result).

**DB_QUERY** — JDBC PostgreSQL driver:
1. Lấy connection đã resolve: `jdbc:postgresql://localhost:<db_port>/<database>`, user/pass từ config.
2. Execute query (parameter đã thay biến), đọc ResultSet.
3. So sánh với `expected`: `row_count`, `columns`, `sample` (so sánh cấu trúc key-value, không so sánh chính xác toàn bộ).
4. Ghi `extracted_variables` nếu config có extract.

**DB_SCHEMA_CHECK**:
1. Kết nối như trên.
2. Chạy từng `check` qua `information_schema`/`pg_indexes`:
   - `TABLE_EXISTS`, `COLUMN_EXISTS` (+ optional `data_type`), `PRIMARY_KEY`, `INDEX_EXISTS`.
3. Mỗi check là 1 assertion; pass khi tất cả đúng.

**DB_MIGRATION**:
1. Kết nối như trên.
2. Chạy từng statement (mỗi statement 1 lần, không auto-commit nhiều lần).
3. Dùng để setup data trước các bước kiểm tra (chống hardcode).

**EXTRACT**:
1. Với biến có `value` → đặt thẳng vào context.
2. Với biến có `from` + `expression` → lấy kết quả step đã chỉ định (response body hoặc extracted_variables của step đó), JSONPath lấy giá trị, đặt vào context.
3. Step này không có assertion — luôn PASSED (trừ khi trích xuất lỗi → ERROR).

**DELAY**: `Thread.sleep(duration_ms)` (giới hạn bởi execution_timeout tổng). Luôn PASSED.

### 4.4 AssertionEngine

Các kiểu assertion trong `config.assertions` (HTTP steps) và `expected` (DB steps):

| kind | Ý nghĩa |
|---|---|
| `status` + `equals` | So sánh status code |
| `body_structure` + `json` | Gson deep-compare **cấu trúc** (key đúng, bỏ qua value) |
| `body_equals` + `json` | So sánh chính xác JSON |
| `json_path` + `path` + `exists` | JSONPath tồn tại / không tồn tại |
| `contains` + `text` | Response body chứa chuỗi |

**Gson deep-compare cấu trúc** (chống hardcode, so key không so value):
- Map: so tập key + đệ quy từng key.
- List: so độ dài + đệ quy từng phần tử.
- Primitive: so type (không so value).

`assertion_result` ghi chi tiết từng assertion pass/fail → hiển thị cho SV biết lỗi ở đâu, và là input cho AI nhận xét sau này.

### 4.5 Thứ tự & điều kiện dừng

- Chạy tuần tự theo `step_order` (bắt buộc — các step phụ thuộc biến nhau).
- Step fail + `is_required = true` → **plan dừng**, các step còn lại của plan đánh `SKIPPED`; job vẫn chạy các plan kế tiếp.
- Step fail + `is_required = false` → plan tiếp tục, step chỉ không được cộng điểm.
- Toàn bộ plans phải xong trong `execution_timeout_ms` → quá hạn: job FAILED, cleanup ngay.

---

## 5. Tính điểm & báo kết quả

### 5.1 Tính điểm

```
score = (tổng weight của steps PASSED / tổng weight của tất cả steps đã chạy) × max_score
```

- Chỉ tính theo **các steps thực sự chạy** (SKIPPED do required-fail không tính vào mẫu số? — **quyết định:** SKIPPED không tính vào cả tử và mẫu; steps chạy nhưng FAILED tính vào mẫu).
- Làm tròn 2 chữ số thập phân.
- Job FAILED (compose không up, timeout...) → score = 0, `summary_log` ghi rõ lý do.

### 5.2 Ghi kết quả (Feign → result-service)

```
POST /api/v1/internal/results
```

```json
{
  "submissionId": "...",
  "assignmentId": "...",
  "studentId": "...",
  "planId": "...",
  "score": 8.5,
  "maxScore": 10.0,
  "status": "DONE",
  "summaryLog": "Passed 5/7 steps, Score: 8.5/10",
  "stepResults": [
    {"planId": "...", "stepId": "...", "stepName": "...", "stepType": "HTTP_REQUEST",
     "passed": true, "weight": 2, "actualValue": {...}, "expectedValue": {...}, "errorMessage": null}
  ]
}
```

- result-service đánh `is_latest`: đúng với submission mới nhất của (assignment, student).
- Ghi `grading_jobs.status = DONE/FAILED` + `completed_at` trước khi gọi Feign (để dù Feign lỗi vẫn biết job đã xong, có thể retry ghi result sau).

### 5.3 Cập nhật trạng thái submission (Feign)

```
PATCH /api/v1/submissions/{id}/status  {"status": "GRADING"}   // đầu pipeline
PATCH /api/v1/submissions/{id}/status  {"status": "DONE|FAILED"} // cuối pipeline
```

### 5.4 Ghi log

Mọi bước quan trọng ghi `grading_logs` (step, message, level) — để lecturer đọc lại luồng chấm và là nguồn cho AI nhận xét.

---

## 6. Failure paths

| # | Lỗi | Hành động | Trạng thái |
|---|---|---|---|
| 1 | Zip không phải zip / lỗi giải nén | FAIL job, message rõ | `FAILED`, score 0 |
| 2 | Zip-slip (path ra ngoài) | Từ chối giải nén entry đó | `FAILED` |
| 3 | Thiếu docker-compose.yml (strategy STUDENT) | FAIL | `FAILED` |
| 4 | Compose build/up lỗi hoặc timeout | Kill, cleanup | `FAILED` |
| 5 | Container không ready sau startup_timeout | `compose down`, cleanup | `FAILED` |
| 6 | Step execute lỗi (exception) | Ghi `ERROR` cho step, chạy tiếp | Step `ERROR`, plan tiếp tục nếu is_required=false |
| 7 | Step required fail | Dừng plan, đánh SKIPPED các step sau | Step `FAILED`, plan còn lại `SKIPPED` |
| 8 | Hết execution_timeout tổng | Dừng toàn bộ, cleanup | `FAILED` |
| 9 | Feign ghi result lỗi | Log + job vẫn DONE; retry ghi result theo `retry_count` | Job `DONE`, result có thể thiếu → cảnh báo |
| 10 | Kafka consume lỗi ngoài mong đợi | Không commit offset → message được consume lại | Tự phục hồi (idempotent nhờ bước 0) |

**Nguyên tắc:** không nuốt lỗi — mọi lỗi đều có `grading_logs` + trạng thái rõ ràng, sinh viên luôn thấy được lý do fail.

---

## 7. Concurrency & scale

### 7.1 Kiến trúc worker

```
Kafka: grading-jobs (3 partitions)
   partition-0 ──► executor pod 1 (concurrency 2 threads)
   partition-1 ──► executor pod 2 (concurrency 2 threads)
   partition-2 ──► executor pod 3 (concurrency 2 threads)
```

- Topic có N partitions; executor là consumer group → tối đa N pods tiêu thụ song song.
- Mỗi thread xử lý 1 job; mỗi job chạy độc lập (compose project name = `sub-<submissionId>`).
- Scale: tăng partition + tăng executor pods. Với k3s 1 node, giới hạn thực tế là RAM node (mỗi job ước tính 512MB-1GB gồm cả student container).

### 7.2 Port allocation — pod-local

- Mỗi executor pod có **PortAllocator riêng** (20000–30000, `ConcurrentHashMap` + synchronized).
- Pod trong K8s có network namespace riêng → port không đụng nhau giữa các pods, chỉ cần tránh đụng trong cùng pod (giữa các thread).
- Không cần quản lý port tập trung cross-node (khác với thiết kế cũ).

### 7.3 Image warm-up

- Khi giảng viên lưu bài tập, assignment-service có thể báo executor (hoặc executor định kỳ) pull sẵn các images trong `docker_images` → giảm thời gian build/pull khi SV nộp.
- Docker layer cache trong DinD volume (PVC cho `/var/lib/docker` nếu muốn giữ cache qua restart pod).

### 7.4 Concurrency của Spring Kafka

- `max-poll-records=1` + `concurrency = threads` (giống thiết kế cũ) — xử lý xong 1 job mới nhận tiếp, dễ kiểm soát tài nguyên.
- Có thể dùng thread pool riêng nếu muốn batch poll; v1 dùng max-poll-records=1 cho đơn giản.

---

## 8. Bảo mật & an toàn

| Biện pháp | Cách làm |
|---|---|
| Resource limits | Patch `deploy.resources` cho mọi container SV (RAM/CPU từ assignment) |
| Timeout toàn cục | `execution_timeout_ms` — kill compose sau khi hết hạn |
| Timeout từng step | `step.timeout_ms` cho HTTP/DB steps |
| Không cho privileged | Kiểm tra compose SV: chứa `privileged: true` hoặc volume mount `docker.sock` → FAIL ngay |
| Cô lập network | Student containers chạy trong network riêng của compose project, không publish ra pod khác |
| DinD sidecar | Docker daemon riêng từng pod — SV không đụng được daemon của hệ thống |
| Zip-slip | Validate path khi giải nén |
| Cleanup bắt buộc | `compose down --volumes` + xoá workdir trong `finally` — không để container SV sống sót sau chấm |
| DB connection | Executor chỉ connect tới port đã patch trên localhost — không expose DB ra ngoài pod |

---

## 9. Changelog

| Version | Ngày | Thay đổi |
|---|---|---|
| v1.0 | 2026-08-16 | Bản đầu tiên. Pipeline 8 bước, step execution engine (6 step types, VariableContext, AssertionEngine), tính điểm, failure paths, scale & bảo mật |