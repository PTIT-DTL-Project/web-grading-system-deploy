# Database Design v1 — Web Grading System

> Dành cho 4 service: Assignment, Submission, Grading, Result.
> Thiết kế hỗ trợ grading linh hoạt: HTTP request đơn lẻ, plan-based multi-step, DB schema check,...

---

## Mục lục

1. [Nguyên tắc thiết kế](#1-nguyên-tắc-thiết-kế)
2. [Core Library — Shared Entities](#2-core-library--shared-entities)
3. [Assignment Service](#3-assignment-service)
4. [Submission Service](#4-submission-service)
5. [Grading Service](#5-grading-service)
6. [Result Service](#6-result-service)
7. [Sơ đồ ER tổng thể](#7-sơ-đồ-er-tổng-thể)
8. [Ví dụ kịch bản grading](#8-ví-dụ-kịch-bản-grading)

---

## 1. Nguyên tắc thiết kế

- **UUID làm primary key** — không dùng sequence, tránh va chạm khi scale ngang
- **Không dùng `@GeneratedValue`** — entity tự set ID trong code (`UUID.randomUUID()`), tránh lỗi Hibernate merge
- **Timestamp chung** — mọi entity có `created_at`, `updated_at`, `deleted_at` (soft delete)
- **JSONB cho config linh hoạt** — `test_steps.config` chứa toàn bộ cấu hình tuỳ theo step type, không cần thêm cột mới
- **Soft delete** — không xoá dữ liệu gốc, chỉ set `deleted_at`
- **Index đầy đủ** — FK, status, các cột hay filter

---

## 2. Core Library — Shared Entities

Các entity dùng chung, được định nghĩa trong core library (`vn.edu.ptit.web_grading_system.core.entities`). Service nào cần thì thêm bảng tương ứng trong DB của service đó.

#### http_exchange_logs

Lưu toàn bộ chi tiết một HTTP request/response — cả **inbound** (service nhận request) và **outbound** (service gọi service khác). Dùng để debug, audit, recheck kết quả chấm điểm sau này.

| Column | Type | Constraint | Ghi chú |
|--------|------|-----------|---------|
| id | UUID | PK | |
| service_name | VARCHAR(50) | NOT NULL | Service tạo log (vd: `grading-service`, `submission-service`) |
| correlation_id | UUID | | ID xuyên suốt để trace 1 request qua nhiều service |
| direction | VARCHAR(10) | NOT NULL | `INBOUND` hoặc `OUTBOUND` |
| method | VARCHAR(10) | NOT NULL | GET, POST, PUT, DELETE, PATCH |
| url | TEXT | NOT NULL | Full URL (đã resolve hết biến) |
| request_headers | JSONB | | |
| request_body | TEXT | | |
| status_code | INT | | |
| response_headers | JSONB | | |
| response_body | TEXT | | |
| duration_ms | INT | | |
| created_at | TIMESTAMPTZ | NOT NULL | |

Cách implement: mỗi service dùng Spring `HandlerInterceptor` (inbound) + `FeignClientInterceptor` / `RestTemplateInterceptor` (outbound) để tự động ghi log vào bảng này.

```sql
CREATE TABLE http_exchange_logs (
    id UUID PRIMARY KEY,
    service_name VARCHAR(50) NOT NULL,
    correlation_id UUID,
    direction VARCHAR(10) NOT NULL,
    method VARCHAR(10) NOT NULL,
    url TEXT NOT NULL,
    request_headers JSONB,
    request_body TEXT,
    status_code INT,
    response_headers JSONB,
    response_body TEXT,
    duration_ms INT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_http_logs_service ON http_exchange_logs(service_name);
CREATE INDEX idx_http_logs_correlation ON http_exchange_logs(correlation_id);
CREATE INDEX idx_http_logs_created ON http_exchange_logs(created_at);
CREATE INDEX idx_http_logs_direction ON http_exchange_logs(direction);
```

---

## 3. Assignment Service

### 3.1 Tổng quan

Assignment Service quản lý:
- Bài tập (`assignments`)
- Docker image cho bài tập (`docker_images`)
- Test plan — tập hợp các bước kiểm tra (`test_plans`, `test_steps`)

> **Lưu ý:** Mỗi assignment có thể có nhiều test plan. Mỗi plan là một kịch bản kiểm tra độc lập, chạy tuần tự các step. Các step trong plan có thể exchange biến với nhau.

### 3.2 Chiến lược Docker Compose

Mỗi bài tập có 2 chế độ cho sinh viên:

| Chế độ | Giá trị | Sinh viên nộp | Grading Service xử lý |
|--------|---------|--------------|----------------------|
| **Tự viết compose** | `STUDENT_DOCKER_COMPOSE` | Zip chứa mã nguồn + `docker-compose.yml` tự viết | Giải nén → patch resource limits → `docker compose up` → auto-detect port |
| **Compose từ giảng viên** | `LECTURER_DOCKER_COMPOSE` | Zip chứa mã nguồn (không cần compose) | Lấy compose template từ assignment → mount/inject code vào container → `docker compose up` → port biết trước từ template |

Chế độ nào cũng không ảnh hưởng tới `test_plans` / `test_steps` — grading service tự xử lý khác nhau ở phase build/run, nhưng cùng một plan chạy HTTP request với port đã biết.

### 3.3 Tables

#### assignments

| Column | Type | Constraint | Ghi chú |
|--------|------|-----------|---------|
| id | UUID | PK | |
| owner_id | UUID | NOT NULL | Giảng viên tạo bài |
| title | VARCHAR(255) | NOT NULL | |
| description | TEXT | | |
| grading_strategy | VARCHAR(30) | NOT NULL DEFAULT 'STUDENT_DOCKER_COMPOSE' | `STUDENT_DOCKER_COMPOSE` hoặc `LECTURER_DOCKER_COMPOSE` |
| docker_compose_template | TEXT | | Nội dung docker-compose.yml mẫu (nếu grading_strategy = LECTURER_DOCKER_COMPOSE) |
| docker_compose_port | INT | DEFAULT 8080 | Port student app sẽ chạy (trong container) |
| startup_timeout_ms | INT | DEFAULT 60000 | Thời gian chờ container ready |
| execution_timeout_ms | INT | DEFAULT 300000 | Thời gian tối đa chạy grading |
| max_memory_mb | INT | DEFAULT 256 | RAM limit cho student container |
| max_cpu | REAL | DEFAULT 0.5 | CPU limit |
| published | BOOLEAN | NOT NULL DEFAULT false | |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |
| deleted_at | TIMESTAMPTZ | | |

#### docker_images

| Column | Type | Constraint | Ghi chú |
|--------|------|-----------|---------|
| id | UUID | PK | |
| name | VARCHAR(255) | NOT NULL | Tên hiển thị |
| image_url | VARCHAR(500) | NOT NULL | Docker image tag |
| description | TEXT | | |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |
| deleted_at | TIMESTAMPTZ | | |

#### assignment_docker_images

| Column | Type | Constraint | Ghi chú |
|--------|------|-----------|---------|
| id | UUID | PK | |
| assignment_id | UUID | NOT NULL FK → assignments | |
| docker_image_id | UUID | NOT NULL FK → docker_images | |
| created_at | TIMESTAMPTZ | NOT NULL | |

#### test_plans

| Column | Type | Constraint | Ghi chú |
|--------|------|-----------|---------|
| id | UUID | PK | |
| assignment_id | UUID | NOT NULL FK → assignments | |
| name | VARCHAR(255) | NOT NULL | |
| description | TEXT | | |
| sequence_order | INT | NOT NULL DEFAULT 0 | Thứ tự chạy |
| weight | INT | NOT NULL DEFAULT 1 | Trọng số tính điểm |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |
| deleted_at | TIMESTAMPTZ | | |

#### test_steps

Đây là bảng cốt lõi. Mỗi step có `step_type` quyết định cấu trúc của `config`.

| Column | Type | Constraint | Ghi chú |
|--------|------|-----------|---------|
| id | UUID | PK | |
| plan_id | UUID | NOT NULL FK → test_plans | |
| step_order | INT | NOT NULL | Thứ tự trong plan |
| name | VARCHAR(255) | NOT NULL | |
| step_type | VARCHAR(50) | NOT NULL | Xem danh sách bên dưới |
| config | JSONB | NOT NULL | Cấu hình tuỳ theo type |
| expected_result | JSONB | | Kết quả mong đợi (có thể ghi đè config) |
| weight | INT | NOT NULL DEFAULT 1 | Trọng số so với các step khác |
| timeout_ms | INT | DEFAULT 30000 | Timeout riêng cho step này |
| is_required | BOOLEAN | DEFAULT true | false = step không bắt buộc pass |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |
| deleted_at | TIMESTAMPTZ | | |

**Các step_type hiện tại:**

| Type | Mục đích |
|------|---------|
| `HTTP_REQUEST` | Gửi HTTP request đến student app, kiểm tra response |
| `DB_QUERY` | Chạy SQL query trực tiếp trên DB của student app |
| `DB_SCHEMA_CHECK` | Kiểm tra cấu trúc DB (bảng, cột, kiểu dữ liệu, index) |
| `DB_MIGRATION` | Chạy SQL migration (setup data trước khi test) |
| `EXTRACT` | Trích xuất biến từ response/DB của step trước |
| `DELAY` | Chờ một khoảng thời gian |
| `SCRIPT` | Chạy script tuỳ chỉnh (Groovy, JS) |

**Cấu trúc `config` JSONB theo từng type:**

HTTP_REQUEST:
```json
{
  "type": "HTTP_REQUEST",
  "method": "POST",
  "path": "/api/v1/books",
  "headers": {
    "Content-Type": "application/json",
    "Authorization": "Bearer ${token}"
  },
  "body": {
    "title": "Dế Mèn Phiêu Lưu Ký",
    "author": "Tô Hoài",
    "year": 1941
  },
  "extract": [
    {"name": "bookId", "from": "response_body", "expression": "$.id"}
  ]
}
```

DB_QUERY:
```json
{
  "type": "DB_QUERY",
  "query": "SELECT id, title, author FROM books WHERE title = ${title}",
  "expected": {
    "row_count": 1,
    "columns": ["id", "title", "author"],
    "sample": {"title": "Dế Mèn Phiêu Lưu Ký", "author": "Tô Hoài"}
  }
}
```

DB_SCHEMA_CHECK:
```json
{
  "type": "DB_SCHEMA_CHECK",
  "checks": [
    {"kind": "TABLE_EXISTS", "table_name": "books"},
    {"kind": "COLUMN_EXISTS", "table_name": "books", "column_name": "title", "data_type": "VARCHAR(255)"},
    {"kind": "COLUMN_EXISTS", "table_name": "books", "column_name": "id", "data_type": "UUID"},
    {"kind": "INDEX_EXISTS", "table_name": "books", "index_name": "idx_books_title"},
    {"kind": "PRIMARY_KEY", "table_name": "books", "column": "id"}
  ]
}
```

DB_MIGRATION:
```json
{
  "type": "DB_MIGRATION",
  "statements": [
    "INSERT INTO books (id, title, author, year) VALUES ('11111111-1111-1111-1111-111111111111', 'Book A', 'Author A', 2000)",
    "INSERT INTO books (id, title, author, year) VALUES ('22222222-2222-2222-2222-222222222222', 'Book B', 'Author B', 2001)"
  ]
}
```

EXTRACT:
```json
{
  "type": "EXTRACT",
  "variables": [
    {"name": "pageSize", "value": "10"},
    {"name": "firstBookId", "from": "step_1", "expression": "$.id"}
  ]
}
```

DELAY:
```json
{
  "type": "DELAY",
  "duration_ms": 5000
}
```

### 3.4 Indexes

```sql
CREATE INDEX idx_assignments_owner ON assignments(owner_id);
CREATE INDEX idx_assignments_published ON assignments(published) WHERE deleted_at IS NULL;
CREATE INDEX idx_test_plans_assignment ON test_plans(assignment_id);
CREATE INDEX idx_test_steps_plan ON test_steps(plan_id);
CREATE INDEX idx_test_steps_plan_order ON test_steps(plan_id, step_order);
```

### 3.5 SQL script

```sql
-- V1__init_assignment_service.sql

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================
-- assignments
-- ============================================================
CREATE TABLE assignments (
    id UUID PRIMARY KEY,
    owner_id UUID NOT NULL,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    grading_strategy VARCHAR(30) NOT NULL DEFAULT 'STUDENT_DOCKER_COMPOSE',
    docker_compose_template TEXT,
    docker_compose_port INT NOT NULL DEFAULT 8080,
    startup_timeout_ms INT NOT NULL DEFAULT 60000,
    execution_timeout_ms INT NOT NULL DEFAULT 300000,
    max_memory_mb INT NOT NULL DEFAULT 256,
    max_cpu REAL NOT NULL DEFAULT 0.5,
    published BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX idx_assignments_owner ON assignments(owner_id);
CREATE INDEX idx_assignments_published ON assignments(published) WHERE deleted_at IS NULL;

-- ============================================================
-- docker_images
-- ============================================================
CREATE TABLE docker_images (
    id UUID PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    image_url VARCHAR(500) NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

-- ============================================================
-- assignment_docker_images
-- ============================================================
CREATE TABLE assignment_docker_images (
    id UUID PRIMARY KEY,
    assignment_id UUID NOT NULL REFERENCES assignments(id),
    docker_image_id UUID NOT NULL REFERENCES docker_images(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_assign_docker_unique ON assignment_docker_images(assignment_id, docker_image_id);
CREATE INDEX idx_assign_docker_assign ON assignment_docker_images(assignment_id);

-- ============================================================
-- test_plans
-- ============================================================
CREATE TABLE test_plans (
    id UUID PRIMARY KEY,
    assignment_id UUID NOT NULL REFERENCES assignments(id),
    name VARCHAR(255) NOT NULL,
    description TEXT,
    sequence_order INT NOT NULL DEFAULT 0,
    weight INT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX idx_test_plans_assignment ON test_plans(assignment_id);
CREATE INDEX idx_test_plans_order ON test_plans(assignment_id, sequence_order);

-- ============================================================
-- test_steps
-- ============================================================
CREATE TABLE test_steps (
    id UUID PRIMARY KEY,
    plan_id UUID NOT NULL REFERENCES test_plans(id),
    step_order INT NOT NULL,
    name VARCHAR(255) NOT NULL,
    step_type VARCHAR(50) NOT NULL,
    config JSONB NOT NULL DEFAULT '{}',
    expected_result JSONB,
    weight INT NOT NULL DEFAULT 1,
    timeout_ms INT DEFAULT 30000,
    is_required BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX idx_test_steps_plan ON test_steps(plan_id);
CREATE INDEX idx_test_steps_plan_order ON test_steps(plan_id, step_order);
CREATE INDEX idx_test_steps_type ON test_steps(step_type);
```

---

## 4. Submission Service

### 4.1 Tổng quan

Submission Service quản lý bài nộp của sinh viên và tương tác với RustFS để lưu file.

### 4.2 Tables

#### submissions

| Column | Type | Constraint | Ghi chú |
|--------|------|-----------|---------|
| id | UUID | PK | |
| assignment_id | UUID | NOT NULL | |
| student_id | UUID | NOT NULL | |
| plan_id | UUID | | Chọn plan cụ thể để chấm (null = chạy tất cả) |
| rustfs_path | TEXT | NOT NULL | Đường dẫn file zip trên RustFS |
| zip_file_name | TEXT | | Tên file gốc |
| status | VARCHAR(20) | NOT NULL DEFAULT 'PENDING' | PENDING, GRADING, DONE, FAILED |
| latest | BOOLEAN | NOT NULL DEFAULT true | Nhiều lần nộp, 1 cái latest |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |
| deleted_at | TIMESTAMPTZ | | |

### 4.3 Indexes

```sql
CREATE INDEX idx_submissions_student ON submissions(student_id);
CREATE INDEX idx_submissions_assignment ON submissions(assignment_id);
CREATE INDEX idx_submissions_status ON submissions(status);
CREATE INDEX idx_submissions_latest ON submissions(assignment_id, student_id) WHERE latest = true AND deleted_at IS NULL;
```

### 4.4 SQL script

```sql
-- V1__init_submission_service.sql

CREATE TABLE submissions (
    id UUID PRIMARY KEY,
    assignment_id UUID NOT NULL,
    student_id UUID NOT NULL,
    plan_id UUID,
    rustfs_path TEXT NOT NULL,
    zip_file_name TEXT,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    latest BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX idx_submissions_student ON submissions(student_id);
CREATE INDEX idx_submissions_assignment ON submissions(assignment_id);
CREATE INDEX idx_submissions_status ON submissions(status);
CREATE INDEX idx_submissions_latest ON submissions(assignment_id, student_id) WHERE latest = true AND deleted_at IS NULL;
CREATE INDEX idx_submissions_assign_status ON submissions(assignment_id, status);
```

---

## 5. Grading Service

### 5.1 Tổng quan

Grading Service là Kafka consumer — nhận job từ Submission Service, chạy grading, ghi log, gửi kết quả cho Result Service.

### 5.2 Tables

#### grading_jobs

| Column | Type | Constraint | Ghi chú |
|--------|------|-----------|---------|
| id | UUID | PK | |
| submission_id | UUID | NOT NULL | |
| assignment_id | UUID | NOT NULL | |
| student_id | UUID | NOT NULL | |
| status | VARCHAR(20) | NOT NULL DEFAULT 'PENDING' | PENDING, FETCHING, BUILDING, RUNNING, DONE, FAILED |
| started_at | TIMESTAMPTZ | | |
| completed_at | TIMESTAMPTZ | | |
| retry_count | INT | DEFAULT 0 | Số lần thử lại |
| error_message | TEXT | | |
| created_at | TIMESTAMPTZ | NOT NULL | |

#### grading_step_results

Kết quả từng step trong plan. Lưu đầy đủ request, response (cả expected và actual) để recheck sau này mà không cần join với assignment_service.

| Column | Type | Constraint | Ghi chú |
|--------|------|-----------|---------|
| id | UUID | PK | |
| job_id | UUID | NOT NULL FK → grading_jobs | |
| plan_id | UUID | NOT NULL | |
| step_id | UUID | NOT NULL | |
| step_order | INT | NOT NULL | |
| step_name | VARCHAR(255) | NOT NULL | |
| step_type | VARCHAR(50) | NOT NULL | |
| status | VARCHAR(20) | NOT NULL | PASSED, FAILED, SKIPPED, ERROR |
| actual_status_code | INT | | Status code thực tế nhận được |
| request_url | TEXT | | URL thực tế đã gọi (đã thay thế biến) |
| request_headers | JSONB | | Headers đã gửi đi |
| request_body | TEXT | | Body đã gửi đi |
| response_status_code | INT | | Status code trả về |
| response_headers | JSONB | | Headers nhận được |
| response_body | TEXT | | Body nhận được (actual) |
| expected_status_code | INT | | Status code mong đợi |
| expected_response_body | TEXT | | Body mong đợi |
| extracted_variables | JSONB | | Biến trích xuất được từ step này |
| assertion_result | JSONB | | Kết quả so sánh chi tiết (pass/fail từng field) |
| error_message | TEXT | | |
| duration_ms | INT | | |
| started_at | TIMESTAMPTZ | NOT NULL | |
| completed_at | TIMESTAMPTZ | | |

#### grading_logs

| Column | Type | Constraint | Ghi chú |
|--------|------|-----------|---------|
| id | UUID | PK | |
| job_id | UUID | NOT NULL FK → grading_jobs | |
| submission_id | UUID | NOT NULL | |
| step | VARCHAR(100) | | Tên bước trong orchestrator |
| message | TEXT | NOT NULL | |
| level | VARCHAR(10) | NOT NULL DEFAULT 'INFO' | INFO, WARN, ERROR |
| created_at | TIMESTAMPTZ | NOT NULL | |

### 5.3 Indexes

```sql
CREATE INDEX idx_grading_jobs_submission ON grading_jobs(submission_id);
CREATE INDEX idx_grading_jobs_status ON grading_jobs(status);
CREATE INDEX idx_grading_step_results_job ON grading_step_results(job_id);
CREATE INDEX idx_grading_step_results_step ON grading_step_results(step_id);
CREATE INDEX idx_grading_logs_job ON grading_logs(job_id);
CREATE INDEX idx_grading_logs_submission ON grading_logs(submission_id);
CREATE INDEX idx_grading_logs_created ON grading_logs(created_at);
```

### 5.4 SQL script

```sql
-- V1__init_grading_service.sql

-- ============================================================
-- grading_jobs
-- ============================================================
CREATE TABLE grading_jobs (
    id UUID PRIMARY KEY,
    submission_id UUID NOT NULL,
    assignment_id UUID NOT NULL,
    student_id UUID NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    retry_count INT NOT NULL DEFAULT 0,
    error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_grading_jobs_submission ON grading_jobs(submission_id);
CREATE INDEX idx_grading_jobs_status ON grading_jobs(status);
CREATE INDEX idx_grading_jobs_created ON grading_jobs(created_at);

-- ============================================================
-- grading_step_results
-- ============================================================
CREATE TABLE grading_step_results (
    id UUID PRIMARY KEY,
    job_id UUID NOT NULL REFERENCES grading_jobs(id),
    plan_id UUID NOT NULL,
    step_id UUID NOT NULL,
    step_order INT NOT NULL,
    step_name VARCHAR(255) NOT NULL,
    step_type VARCHAR(50) NOT NULL,
    status VARCHAR(20) NOT NULL,
    actual_status_code INT,
    request_url TEXT,
    request_headers JSONB,
    request_body TEXT,
    response_status_code INT,
    response_headers JSONB,
    response_body TEXT,
    expected_status_code INT,
    expected_response_body TEXT,
    extracted_variables JSONB,
    assertion_result JSONB,
    error_message TEXT,
    duration_ms INT,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ
);

CREATE INDEX idx_grading_step_results_job ON grading_step_results(job_id);
CREATE INDEX idx_grading_step_results_step ON grading_step_results(step_id);
CREATE INDEX idx_grading_step_results_status ON grading_step_results(status);

-- ============================================================
-- grading_logs
-- ============================================================
CREATE TABLE grading_logs (
    id UUID PRIMARY KEY,
    job_id UUID NOT NULL REFERENCES grading_jobs(id),
    submission_id UUID NOT NULL,
    step VARCHAR(100),
    message TEXT NOT NULL,
    level VARCHAR(10) NOT NULL DEFAULT 'INFO',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_grading_logs_job ON grading_logs(job_id);
CREATE INDEX idx_grading_logs_submission ON grading_logs(submission_id);
CREATE INDEX idx_grading_logs_created ON grading_logs(created_at);
```

---

## 6. Result Service

### 6.1 Tổng quan

Result Service lưu kết quả chấm điểm, cho phép giảng viên và sinh viên xem điểm, thống kê.

### 6.2 Tables

#### results

| Column | Type | Constraint | Ghi chú |
|--------|------|-----------|---------|
| id | UUID | PK | |
| submission_id | UUID | NOT NULL | |
| assignment_id | UUID | NOT NULL | |
| student_id | UUID | NOT NULL | |
| plan_id | UUID | | |
| score | DECIMAL(5,2) | NOT NULL | |
| max_score | DECIMAL(5,2) | NOT NULL | |
| status | VARCHAR(20) | NOT NULL DEFAULT 'PENDING' | PENDING, RUNNING, DONE, FAILED |
| summary_log | TEXT | | |
| is_latest | BOOLEAN | NOT NULL DEFAULT true | Nhiều lần nộp → chỉ 1 latest |
| started_at | TIMESTAMPTZ | | |
| completed_at | TIMESTAMPTZ | | |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |

#### scenario_results

| Column | Type | Constraint | Ghi chú |
|--------|------|-----------|---------|
| id | UUID | PK | |
| result_id | UUID | NOT NULL FK → results | |
| plan_id | UUID | | |
| step_id | UUID | | |
| step_order | INT | NOT NULL | |
| step_name | VARCHAR(255) | NOT NULL | |
| step_type | VARCHAR(50) | NOT NULL | |
| passed | BOOLEAN | NOT NULL | |
| weight | INT | DEFAULT 1 | |
| score | DECIMAL(5,2) | DEFAULT 0 | Điểm step này |
| actual_value | JSONB | | Output thực tế |
| expected_value | JSONB | | Output mong đợi |
| error_message | TEXT | | |
| duration_ms | INT | | |
| created_at | TIMESTAMPTZ | NOT NULL | |

### 6.3 Indexes

```sql
CREATE INDEX idx_results_submission ON results(submission_id);
CREATE INDEX idx_results_student ON results(student_id);
CREATE INDEX idx_results_assignment ON results(assignment_id);
CREATE INDEX idx_results_latest ON results(student_id, assignment_id) WHERE is_latest = true;
CREATE INDEX idx_scenario_results_result ON scenario_results(result_id);
```

### 6.4 SQL script

```sql
-- V1__init_result_service.sql

-- ============================================================
-- results
-- ============================================================
CREATE TABLE results (
    id UUID PRIMARY KEY,
    submission_id UUID NOT NULL,
    assignment_id UUID NOT NULL,
    student_id UUID NOT NULL,
    plan_id UUID,
    score DECIMAL(5,2) NOT NULL,
    max_score DECIMAL(5,2) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    summary_log TEXT,
    is_latest BOOLEAN NOT NULL DEFAULT true,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_results_submission ON results(submission_id);
CREATE INDEX idx_results_student ON results(student_id);
CREATE INDEX idx_results_assignment ON results(assignment_id);
CREATE INDEX idx_results_latest ON results(student_id, assignment_id) WHERE is_latest = true;
CREATE INDEX idx_results_status ON results(status);

-- ============================================================
-- scenario_results
-- ============================================================
CREATE TABLE scenario_results (
    id UUID PRIMARY KEY,
    result_id UUID NOT NULL REFERENCES results(id),
    plan_id UUID,
    step_id UUID,
    step_order INT NOT NULL,
    step_name VARCHAR(255) NOT NULL,
    step_type VARCHAR(50) NOT NULL,
    passed BOOLEAN NOT NULL,
    weight INT NOT NULL DEFAULT 1,
    score DECIMAL(5,2) NOT NULL DEFAULT 0,
    actual_value JSONB,
    expected_value JSONB,
    error_message TEXT,
    duration_ms INT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_scenario_results_result ON scenario_results(result_id);
CREATE INDEX idx_scenario_results_passed ON scenario_results(passed);
```

---

## 7. Sơ đồ ER tổng thể

```
┌─────────────────────────────────────────────────────────────┐
│                   ASSIGNMENT SERVICE                        │
│                                                             │
│  ┌──────────┐     ┌──────────────────────┐  ┌─────────────┐│
│  │docker_   │◄───►│assignment_docker_    │  │assignments  ││
│  │images    │     │images                │  │             ││
│  └──────────┘     └──────────────────────┘  │ id          ││
│                                             │ owner_id    ││
│  ┌──────────┐                               │ title       ││
│  │test_     │──┐                            │ published   ││
│  │steps     │  │                            │ ...         ││
│  │          │  │                            └──────┬──────┘│
│  │ id       │  │                                   │       │
│  │ plan_id  │◄─┘  ┌──────────────────┐             │       │
│  │ step_type│     │   test_plans     │             │       │
│  │ config   │     │                  │             │       │
│  │ ...      │     │ id               │◄────────────┘       │
│  └──────────┘     │ assignment_id    │                     │
│                   │ sequence_order   │                     │
│                   │ weight           │                     │
│                   └──────────────────┘                     │
└─────────────────────────────────────────────────────────────┘
         │
         │ (submission.assignment_id)
         ▼
┌─────────────────────────────────────────────────────────────┐
│                   SUBMISSION SERVICE                        │
│                                                             │
│  ┌──────────┐                                               │
│  │submissions│                                              │
│  │          │                                               │
│  │ id       │                                               │
│  │ assign_id│                                               │
│  │ student  │                                               │
│  │ rustfs.. │                                               │
│  │ status   │                                               │
│  └──────────┘                                               │
└─────────────────────────────────────────────────────────────┘
         │
         │ (grading_jobs.submission_id)
         ▼
┌─────────────────────────────────────────────────────────────┐
│                   GRADING SERVICE                           │
│                                                             │
│  ┌──────────┐     ┌──────────────────┐                     │
│  │grading_  │     │grading_step_     │                     │
│  │jobs      │────►│results           │                     │
│  │          │     │                  │                     │
│  │ id       │     │ job_id           │                     │
│  │ submission│    │ step_id          │                     │
│  │ status   │     │ status           │                     │
│  │ ...      │     │ response_body    │                     │
│  └──────────┘     │ extracted_vars   │                     │
│       │           └──────────────────┘                     │
│       ▼                                                    │
│  ┌──────────┐                                               │
│  │grading_  │                                               │
│  │logs      │                                               │
│  └──────────┘                                               │
└─────────────────────────────────────────────────────────────┘
         │
         │ (Feign: resultClient.saveResult)
         ▼
┌─────────────────────────────────────────────────────────────┐
│                   RESULT SERVICE                            │
│                                                             │
│  ┌──────────┐     ┌──────────────────┐                     │
│  │results   │────►│scenario_results   │                     │
│  │          │     │                  │                     │
│  │ id       │     │ result_id        │                     │
│  │ submission│    │ step_id          │                     │
│  │ score    │     │ passed           │                     │
│  │ status   │     │ actual_value     │                     │
│  │ ...      │     │ expected_value   │                     │
│  └──────────┘     └──────────────────┘                     │
└─────────────────────────────────────────────────────────────┘
```

---

## 8. Ví dụ kịch bản grading

### 8.1 Plan: "CRUD Book API — Basic"

```sql
-- Plan
INSERT INTO test_plans (id, assignment_id, name, sequence_order, weight)
VALUES ('p1', 'a1', 'CRUD Book API — Basic', 1, 10);

-- Step 1: POST tạo sách, trích xuất bookId
INSERT INTO test_steps (id, plan_id, step_order, name, step_type, config, weight)
VALUES ('s1', 'p1', 1, 'Create a book', 'HTTP_REQUEST', '{
  "method": "POST",
  "path": "/api/v1/books",
  "headers": {"Content-Type": "application/json"},
  "body": {
    "title": "Dế Mèn Phiêu Lưu Ký",
    "author": "Tô Hoài",
    "year": 1941
  },
  "expected_status": 201,
  "extract": [
    {"name": "bookId", "from": "response_body", "expression": "$.id"},
    {"name": "bookTitle", "from": "response_body", "expression": "$.title"}
  ]
}', 2);

-- Step 2: GET kiểm tra sách vừa tạo
INSERT INTO test_steps (id, plan_id, step_order, name, step_type, config, weight)
VALUES ('s2', 'p1', 2, 'Verify book details', 'HTTP_REQUEST', '{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200,
  "expected_body_contains": "Dế Mèn Phiêu Lưu Ký"
}', 2);

-- Step 3: GET search theo tên
INSERT INTO test_steps (id, plan_id, step_order, name, step_type, config, weight)
VALUES ('s3', 'p1', 3, 'Search by title', 'HTTP_REQUEST', '{
  "method": "GET",
  "path": "/api/v1/books",
  "query_params": {"title": "Dế Mèn"},
  "expected_status": 200,
  "expected_body_contains": "${bookId}"
}', 2);

-- Step 4: Kiểm tra DB schema
INSERT INTO test_steps (id, plan_id, step_order, name, step_type, config, weight)
VALUES ('s4', 'p1', 4, 'Check DB schema', 'DB_SCHEMA_CHECK', '{
  "checks": [
    {"kind": "TABLE_EXISTS", "table_name": "books"},
    {"kind": "COLUMN_EXISTS", "table_name": "books", "column_name": "title", "data_type": "VARCHAR"},
    {"kind": "COLUMN_EXISTS", "table_name": "books", "column_name": "id", "data_type": "UUID"},
    {"kind": "PRIMARY_KEY", "table_name": "books", "column": "id"}
  ]
}', 2);

-- Step 5: DB query kiểm tra dữ liệu
INSERT INTO test_steps (id, plan_id, step_order, name, step_type, config, weight)
VALUES ('s5', 'p1', 5, 'Verify data in DB', 'DB_QUERY', '{
  "query": "SELECT title, author, year FROM books WHERE id = ${bookId}",
  "expected": {
    "row_count": 1,
    "columns": ["title", "author", "year"]
  }
}', 2);
```

### 8.2 Mở rộng sau này

Cách thiết kế này cho phép thêm step type mới mà không cần thay đổi schema:

- **`DOCKER_EXEC`** — chạy command bên trong student container (`exec`)
- **`FILE_EXISTS`** — kiểm tra file có tồn tại trong container
- **`WEBSOCKET`** — kiểm tra WebSocket endpoint
- **`GRPC_CALL`** — gọi gRPC endpoint
- **`RATE_LIMIT`** — kiểm tra rate limiting
- **`SECURITY_SCAN`** — quét lỗ hổng cơ bản

Chỉ cần thêm type mới vào enum và implement executor tương ứng trong Grading Service.
