# Design DB v1.0 — Web Grading System

> **Version:** v1.0
> **Ngày:** 2026-08-16
> **Trạng thái:** Current
> **Thay thế:** `docs/db/README.md` (thiết kế DB v1 cũ — giữ nguyên tinh thần, thêm `classes`, `class_students`, `manual_scores`, đổi tên `grading_db` → `executor_db`, `scenario_results` → `step_results`)
> **Tài liệu liên quan:** Tách service → `system-design-v1.0.md` · Cách chấm thật → `execute-plan-v1.0.md`

---

## Mục lục

1. [Nguyên tắc thiết kế](#1-nguyên-tắc-thiết-kế)
2. [assignment_db](#2-assignment_db)
3. [submission_db](#3-submission_db)
4. [executor_db](#4-executor_db)
5. [result_db](#5-result_db)
6. [Sơ đồ ER tổng thể](#6-sơ-đồ-er-tổng-thể)
7. [Changelog](#7-changelog)

---

## 1. Nguyên tắc thiết kế

- **UUID làm primary key** — entity tự set ID trong code (`UUID.randomUUID()`), tránh va chạm khi scale ngang.
- **Timestamp chung** — mọi entity có `created_at`, `updated_at`, `deleted_at` (soft delete).
- **JSONB cho config linh hoạt** — `test_steps.config` chứa toàn bộ cấu hình theo `step_type`, thêm kiểu test mới không cần đổi schema.
- **Soft delete** — không xoá dữ liệu gốc.
- **DB-per-Service** — 4 DB: `assignment_db`, `submission_db`, `executor_db`, `result_db`.
- **Chỉ hỗ trợ PostgreSQL** trong v1 (cho cả DB của student app khi test DB).

---

## 2. assignment_db

### 2.1 Tổng quan

Assignment Service quản lý toàn bộ nội dung giảng viên tạo: lớp học, sinh viên trong lớp, bài tập, docker images, test plans & steps.

Mỗi assignment có thể có nhiều **test plan**; mỗi plan là một kịch bản kiểm tra độc lập, chạy tuần tự các **step**. Các step trong plan có thể trao đổi biến với nhau (bắt hardcode).

Mỗi assignment có 2 chế độ chạy:

| Chế độ | Giá trị | Sinh viên nộp | Executor xử lý |
|---|---|---|---|
| Tự viết compose | `STUDENT_DOCKER_COMPOSE` | Zip chứa mã nguồn + `docker-compose.yml` | Giải nén → patch → `docker compose up` |
| Compose từ giảng viên | `LECTURER_DOCKER_COMPOSE` | Zip chứa mã nguồn (không cần compose) | Dùng template từ assignment, mount code vào container |

### 2.2 Tables

#### classes

| Column | Type | Constraint | Ghi chú |
|---|---|---|---|
| id | UUID | PK | |
| owner_id | UUID | NOT NULL | Giảng viên quản lý lớp |
| name | VARCHAR(255) | NOT NULL | Tên lớp |
| semester | VARCHAR(20) | NOT NULL | Kỳ, vd `20261`, `20262` |
| status | VARCHAR(20) | NOT NULL DEFAULT 'ACTIVE' | `ACTIVE` / `ARCHIVED` |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |
| deleted_at | TIMESTAMPTZ | | |

#### class_students

Sinh viên được import vào lớp bằng CSV (username mặc định = mã sinh viên, password = mã sinh viên — account thật tạo ở Keycloak).

| Column | Type | Constraint | Ghi chú |
|---|---|---|---|
| id | UUID | PK | |
| class_id | UUID | NOT NULL FK → classes | |
| student_code | VARCHAR(50) | NOT NULL | Mã sinh viên |
| student_name | VARCHAR(200) | NOT NULL | |
| email | VARCHAR(200) | | |
| created_at | TIMESTAMPTZ | NOT NULL | |

#### assignments

| Column | Type | Constraint | Ghi chú |
|---|---|---|---|
| id | UUID | PK | |
| class_id | UUID | NOT NULL FK → classes | Bài tập thuộc 1 lớp |
| owner_id | UUID | NOT NULL | Giảng viên tạo |
| title | VARCHAR(255) | NOT NULL | |
| description | TEXT | | |
| grading_strategy | VARCHAR(30) | NOT NULL DEFAULT 'STUDENT_DOCKER_COMPOSE' | `STUDENT_DOCKER_COMPOSE` / `LECTURER_DOCKER_COMPOSE` |
| docker_compose_template | TEXT | | Nội dung compose mẫu (nếu strategy = LECTURER) |
| docker_compose_port | INT | NOT NULL DEFAULT 8080 | Port app SV chạy trong container |
| startup_timeout_ms | INT | NOT NULL DEFAULT 60000 | Chờ container ready |
| execution_timeout_ms | INT | NOT NULL DEFAULT 300000 | Tổng thời gian chấm tối đa |
| max_memory_mb | INT | NOT NULL DEFAULT 256 | RAM limit mỗi container SV |
| max_cpu | REAL | NOT NULL DEFAULT 0.5 | CPU limit |
| published | BOOLEAN | NOT NULL DEFAULT false | |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |
| deleted_at | TIMESTAMPTZ | | |

#### docker_images

| Column | Type | Constraint | Ghi chú |
|---|---|---|---|
| id | UUID | PK | |
| name | VARCHAR(255) | NOT NULL | Tên hiển thị |
| image_url | VARCHAR(500) | NOT NULL | Docker image tag |
| description | TEXT | | |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |
| deleted_at | TIMESTAMPTZ | | |

#### assignment_docker_images

| Column | Type | Constraint |
|---|---|---|
| id | UUID | PK |
| assignment_id | UUID | NOT NULL FK → assignments |
| docker_image_id | UUID | NOT NULL FK → docker_images |
| created_at | TIMESTAMPTZ | NOT NULL |

#### test_plans

| Column | Type | Constraint | Ghi chú |
|---|---|---|---|
| id | UUID | PK | |
| assignment_id | UUID | NOT NULL FK → assignments | |
| name | VARCHAR(255) | NOT NULL | |
| description | TEXT | | |
| sequence_order | INT | NOT NULL DEFAULT 0 | Thứ tự chạy |
| weight | INT | NOT NULL DEFAULT 1 | Trọng số tính điểm |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |
| deleted_at | TIMESTAMPTZ | | |

#### test_steps — bảng cốt lõi

| Column | Type | Constraint | Ghi chú |
|---|---|---|---|
| id | UUID | PK | |
| plan_id | UUID | NOT NULL FK → test_plans | |
| step_order | INT | NOT NULL | Thứ tự trong plan |
| name | VARCHAR(255) | NOT NULL | |
| step_type | VARCHAR(50) | NOT NULL | Xem danh sách dưới |
| config | JSONB | NOT NULL | Cấu hình theo type |
| expected_result | JSONB | | Ghi đè kỳ vọng (tuỳ chọn) |
| weight | INT | NOT NULL DEFAULT 1 | |
| timeout_ms | INT | DEFAULT 30000 | Timeout riêng cho step |
| is_required | BOOLEAN | DEFAULT true | false = không bắt buộc pass |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |
| deleted_at | TIMESTAMPTZ | | |

**Các `step_type` trong v1:**

| Type | Mục đích |
|---|---|
| `HTTP_REQUEST` | Gửi HTTP request đến app SV, kiểm tra response |
| `DB_QUERY` | Chạy SQL query trên DB của app SV |
| `DB_SCHEMA_CHECK` | Kiểm tra cấu trúc DB (bảng, cột, PK, index) |
| `DB_MIGRATION` | Chạy SQL để setup data trước khi test |
| `EXTRACT` | Trích xuất biến từ kết quả step trước |
| `DELAY` | Chờ một khoảng thời gian |

> `SCRIPT` (chạy script tuỳ chỉnh) — để dành version sau (rủi ro bảo mật).

**Cấu trúc `config` JSONB theo từng type:**

HTTP_REQUEST:
```json
{
  "method": "POST",
  "path": "/api/v1/books",
  "headers": {
    "Content-Type": "application/json",
    "Authorization": "Bearer ${token}"
  },
  "body": {
    "title": "Dế Mèn Phiêu Lưu Ký",
    "author": "Tô Hoài"
  },
  "expected_status": 201,
  "assertions": [
    {"kind": "status", "equals": 201},
    {"kind": "body_structure", "json": "{\"id\": \"\", \"title\": \"\"}"},
    {"kind": "json_path", "path": "$.id", "exists": true}
  ],
  "extract": [
    {"name": "bookId", "from": "response_body", "expression": "$.id"}
  ]
}
```

DB_QUERY (và DB_SCHEMA_CHECK, DB_MIGRATION) — block `connection`:
```json
{
  "connection": {
    "db_service": "db",
    "db_port": 5432,
    "database": "bookstore",
    "username": "postgres",
    "password": "postgres"
  },
  "query": "SELECT title, author FROM books WHERE id = ${bookId}",
  "expected": {
    "row_count": 1,
    "columns": ["title", "author"]
  }
}
```

| Field trong `connection` | Ý nghĩa |
|---|---|
| `db_service` | Tên service DB trong docker-compose của SV (mặc định `db`) — executor sẽ expose port của service này ra host |
| `db_port` | Port DB trong container (mặc định 5432) |
| `database`, `username`, `password` | Thông tin kết nối |

DB_SCHEMA_CHECK:
```json
{
  "connection": { "db_service": "db", "database": "bookstore", "username": "postgres", "password": "postgres" },
  "checks": [
    {"kind": "TABLE_EXISTS", "table_name": "books"},
    {"kind": "COLUMN_EXISTS", "table_name": "books", "column_name": "title", "data_type": "VARCHAR"},
    {"kind": "PRIMARY_KEY", "table_name": "books", "column": "id"},
    {"kind": "INDEX_EXISTS", "table_name": "books", "index_name": "idx_books_title"}
  ]
}
```

DB_MIGRATION:
```json
{
  "connection": { "db_service": "db", "database": "bookstore", "username": "postgres", "password": "postgres" },
  "statements": [
    "INSERT INTO books (id, title, author, year) VALUES ('11111111-1111-1111-1111-111111111111', 'Book A', 'Author A', 2000)",
    "INSERT INTO books (id, title, author, year) VALUES ('22222222-2222-2222-2222-222222222222', 'Book B', 'Author B', 2001)"
  ]
}
```

EXTRACT:
```json
{
  "variables": [
    {"name": "pageSize", "value": "10"},
    {"name": "bookId", "from": "step_1", "expression": "$.id"}
  ]
}
```

DELAY:
```json
{
  "duration_ms": 5000
}
```

### 2.3 SQL script

```sql
-- V1__init_assignment_service.sql

-- ============================================================
-- classes
-- ============================================================
CREATE TABLE classes (
    id UUID PRIMARY KEY,
    owner_id UUID NOT NULL,
    name VARCHAR(255) NOT NULL,
    semester VARCHAR(20) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX idx_classes_owner ON classes(owner_id);
CREATE UNIQUE INDEX idx_classes_owner_name_sem ON classes(owner_id, name, semester) WHERE deleted_at IS NULL;

-- ============================================================
-- class_students
-- ============================================================
CREATE TABLE class_students (
    id UUID PRIMARY KEY,
    class_id UUID NOT NULL REFERENCES classes(id),
    student_code VARCHAR(50) NOT NULL,
    student_name VARCHAR(200) NOT NULL,
    email VARCHAR(200),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_class_students_class ON class_students(class_id);
CREATE UNIQUE INDEX idx_class_students_code ON class_students(class_id, student_code);

-- ============================================================
-- assignments
-- ============================================================
CREATE TABLE assignments (
    id UUID PRIMARY KEY,
    class_id UUID NOT NULL REFERENCES classes(id),
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

CREATE INDEX idx_assignments_class ON assignments(class_id);
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

## 3. submission_db

### 3.1 Tổng quan

Quản lý bài nộp của sinh viên + tương tác RustFS.

### 3.2 Tables

#### submissions

| Column | Type | Constraint | Ghi chú |
|---|---|---|---|
| id | UUID | PK | |
| assignment_id | UUID | NOT NULL | |
| student_id | UUID | NOT NULL | |
| plan_id | UUID | | Plan được chọn để chấm; null = chạy tất cả |
| rustfs_path | TEXT | NOT NULL | Đường dẫn zip trên RustFS |
| zip_file_name | TEXT | | Tên file gốc |
| status | VARCHAR(20) | NOT NULL DEFAULT 'PENDING' | `PENDING`, `GRADING`, `DONE`, `FAILED` |
| latest | BOOLEAN | NOT NULL DEFAULT true | Nhiều lần nộp, 1 cái latest |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |
| deleted_at | TIMESTAMPTZ | | |

### 3.3 SQL script

```sql
-- V1__init_submission_service.sql (đã tồn tại trong repo)
-- V2__add_plan_id.sql — migration mới:

ALTER TABLE submissions ADD COLUMN plan_id UUID;

CREATE INDEX idx_submissions_student ON submissions(student_id);
CREATE INDEX idx_submissions_assignment ON submissions(assignment_id);
CREATE INDEX idx_submissions_status ON submissions(status);
CREATE INDEX idx_submissions_assign_student ON submissions(assignment_id, student_id);
CREATE INDEX idx_submissions_latest ON submissions(assignment_id, student_id) WHERE latest = true AND deleted_at IS NULL;
CREATE INDEX idx_submissions_assign_status ON submissions(assignment_id, status);
```

---

## 4. executor_db

### 4.1 Tổng quan

Executor Service là Kafka consumer — nhận job, chấm, ghi log và kết quả từng step. Đây là DB lưu **bằng chứng chấm điểm** (expected vs actual của từng step) để review, recheck, và làm input cho AI nhận xét sau này.

### 4.2 Tables

#### grading_jobs

| Column | Type | Constraint | Ghi chú |
|---|---|---|---|
| id | UUID | PK | |
| submission_id | UUID | NOT NULL | |
| assignment_id | UUID | NOT NULL | |
| student_id | UUID | NOT NULL | |
| plan_id | UUID | | null = chạy tất cả plans |
| status | VARCHAR(20) | NOT NULL DEFAULT 'PENDING' | `PENDING`, `FETCHING`, `BUILDING`, `RUNNING`, `DONE`, `FAILED` |
| retry_count | INT | NOT NULL DEFAULT 0 | |
| error_message | TEXT | | |
| started_at | TIMESTAMPTZ | | |
| completed_at | TIMESTAMPTZ | | |
| created_at | TIMESTAMPTZ | NOT NULL | |

#### grading_step_results

Kết quả từng step — lưu đủ request/response (cả expected và actual) để recheck không cần join sang assignment_db.

| Column | Type | Constraint | Ghi chú |
|---|---|---|---|
| id | UUID | PK | |
| job_id | UUID | NOT NULL FK → grading_jobs | |
| plan_id | UUID | NOT NULL | |
| step_id | UUID | NOT NULL | |
| step_order | INT | NOT NULL | |
| step_name | VARCHAR(255) | NOT NULL | |
| step_type | VARCHAR(50) | NOT NULL | |
| status | VARCHAR(20) | NOT NULL | `PASSED`, `FAILED`, `SKIPPED`, `ERROR` |
| actual_status_code | INT | | |
| request_url | TEXT | | URL đã thay biến |
| request_headers | JSONB | | |
| request_body | TEXT | | |
| response_status_code | INT | | |
| response_headers | JSONB | | |
| response_body | TEXT | | |
| expected_status_code | INT | | |
| expected_response_body | TEXT | | |
| extracted_variables | JSONB | | Biến trích xuất từ step này |
| assertion_result | JSONB | | Chi tiết pass/fail từng assertion |
| error_message | TEXT | | |
| duration_ms | INT | | |
| started_at | TIMESTAMPTZ | NOT NULL | |
| completed_at | TIMESTAMPTZ | | |

#### grading_logs

| Column | Type | Constraint | Ghi chú |
|---|---|---|---|
| id | UUID | PK | |
| job_id | UUID | NOT NULL FK → grading_jobs | |
| submission_id | UUID | NOT NULL | |
| step | VARCHAR(100) | | Tên bước trong orchestrator |
| message | TEXT | NOT NULL | |
| level | VARCHAR(10) | NOT NULL DEFAULT 'INFO' | `INFO`, `WARN`, `ERROR` |
| created_at | TIMESTAMPTZ | NOT NULL | |

### 4.3 SQL script

```sql
-- V1__init_executor_service.sql

-- ============================================================
-- grading_jobs
-- ============================================================
CREATE TABLE grading_jobs (
    id UUID PRIMARY KEY,
    submission_id UUID NOT NULL,
    assignment_id UUID NOT NULL,
    student_id UUID NOT NULL,
    plan_id UUID,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    retry_count INT NOT NULL DEFAULT 0,
    error_message TEXT,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
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

## 5. result_db

### 5.1 Tổng quan

Lưu kết quả chấm, điểm nhập tay; phục vụ xem điểm & thống kê. Executor ghi kết quả qua internal endpoint; điểm nhập tay do giảng viên nhập.

### 5.2 Tables

#### results

| Column | Type | Constraint | Ghi chú |
|---|---|---|---|
| id | UUID | PK | |
| submission_id | UUID | NOT NULL | |
| assignment_id | UUID | NOT NULL | |
| student_id | UUID | NOT NULL | |
| plan_id | UUID | | |
| score | DECIMAL(5,2) | NOT NULL | |
| max_score | DECIMAL(5,2) | NOT NULL DEFAULT 10.00 | |
| status | VARCHAR(20) | NOT NULL DEFAULT 'PENDING' | `PENDING`, `RUNNING`, `DONE`, `FAILED` |
| summary_log | TEXT | | |
| is_latest | BOOLEAN | NOT NULL DEFAULT true | |
| started_at | TIMESTAMPTZ | | |
| completed_at | TIMESTAMPTZ | | |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |

#### step_results

| Column | Type | Constraint | Ghi chú |
|---|---|---|---|
| id | UUID | PK | |
| result_id | UUID | NOT NULL FK → results | |
| plan_id | UUID | | |
| step_id | UUID | | |
| step_order | INT | NOT NULL | |
| step_name | VARCHAR(255) | NOT NULL | |
| step_type | VARCHAR(50) | NOT NULL | |
| passed | BOOLEAN | NOT NULL | |
| weight | INT | NOT NULL DEFAULT 1 | |
| score | DECIMAL(5,2) | NOT NULL DEFAULT 0 | |
| actual_value | JSONB | | Output thực tế |
| expected_value | JSONB | | Output mong đợi |
| error_message | TEXT | | |
| duration_ms | INT | | |
| created_at | TIMESTAMPTZ | NOT NULL | |

#### manual_scores

Điểm giảng viên nhập tay (chuyên cần, thuyết trình...). `assignment_id` null = điểm chung của lớp (không gắn bài tập cụ thể).

| Column | Type | Constraint | Ghi chú |
|---|---|---|---|
| id | UUID | PK | |
| class_id | UUID | NOT NULL | |
| student_code | VARCHAR(50) | NOT NULL | |
| assignment_id | UUID | | null = điểm chung |
| score | DECIMAL(5,2) | NOT NULL | |
| comment | TEXT | | Nhận xét |
| created_by | UUID | NOT NULL | Giảng viên nhập |
| created_at | TIMESTAMPTZ | NOT NULL | |
| updated_at | TIMESTAMPTZ | NOT NULL | |

### 5.3 SQL script

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
    max_score DECIMAL(5,2) NOT NULL DEFAULT 10.00,
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
-- step_results
-- ============================================================
CREATE TABLE step_results (
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

CREATE INDEX idx_step_results_result ON step_results(result_id);
CREATE INDEX idx_step_results_passed ON step_results(passed);

-- ============================================================
-- manual_scores
-- ============================================================
CREATE TABLE manual_scores (
    id UUID PRIMARY KEY,
    class_id UUID NOT NULL,
    student_code VARCHAR(50) NOT NULL,
    assignment_id UUID,
    score DECIMAL(5,2) NOT NULL,
    comment TEXT,
    created_by UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_manual_scores_class ON manual_scores(class_id);
CREATE INDEX idx_manual_scores_student ON manual_scores(class_id, student_code);
```

---

## 6. Sơ đồ ER tổng thể

```
┌──────────────────────────── ASSIGNMENT SERVICE ────────────────────────────┐
│                                                                             │
│  classes ───< class_students                                                │
│    ▲                                                                        │
│    │                                                                        │
│  assignments ───< test_plans ───< test_steps                                │
│    │                                                                        │
│    └──< assignment_docker_images >─── docker_images                         │
└─────────────────────────────────────────────────────────────────────────────┘
        │ (submission.assignment_id, plan_id)
        ▼
┌──────────────────────────── SUBMISSION SERVICE ────────────────────────────┐
│  submissions (assignment_id, student_id, plan_id, rustfs_path, status)      │
└─────────────────────────────────────────────────────────────────────────────┘
        │ (Kafka: grading-jobs → grading_jobs.submission_id)
        ▼
┌──────────────────────────── EXECUTOR SERVICE ──────────────────────────────┐
│  grading_jobs ───< grading_step_results                                     │
│       │                                                                     │
│       └───< grading_logs                                                    │
└─────────────────────────────────────────────────────────────────────────────┘
        │ (Feign: saveResult → results.submission_id)
        ▼
┌──────────────────────────── RESULT SERVICE ────────────────────────────────┐
│  results ───< step_results                                                  │
│  manual_scores (class_id, student_code, assignment_id?)                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Changelog

| Version | Ngày | Thay đổi |
|---|---|---|
| v1.0 | 2026-08-16 | Bản đầu tiên. Kế thừa `docs/db/README.md`; thêm `classes`, `class_students`, `manual_scores`; đổi `grading_db` → `executor_db`, `scenario_results` → `step_results`; thêm `connection` block cho DB steps; bỏ step type `SCRIPT` ra khỏi v1 |