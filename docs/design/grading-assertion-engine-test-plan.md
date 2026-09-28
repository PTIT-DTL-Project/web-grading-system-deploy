# Grading Task Verification — Assertion Engine Test Plan v1.0

> **Status:** Current
> **Scope:** Complete reference for every assertion type, plus a real end-to-end test plan with exact API calls, request bodies, expected responses, and verification steps
> **Audience:** Lecturers configuring assignments, TAs verifying grading, developers debugging the assertion engine
> **Related:** `grading-full-flow.md` (full flow) · `http-test-plan-config.md` (schema) · `API-TEST-GUIDE.md` (endpoint reference) · `design-db-v1.0.md` (DB schema)

---

## Mục lục

1. [Tổng quan Assertion Engine](#1-tổng-quan-assertion-engine)
2. [Các loại Assertion — Chi tiết từng loại](#2-các-loại-assertion)
3. [Bảng tổng hợp Assertion](#3-bảng-tổng-hợp-assertion)
4. [Các loại Step ngoài HTTP_REQUEST](#4-các-loại-step-khác-http_request)
5. [Test plan thực tế — "CRUD Book API"](#5-test-plan-thực-tế)
6. [Chi tiết từng bước trong test plan](#6-chi-tết-từng-bước)
7. [Test plan nâng cao — DB step kiểm tra](#7-test-plan-nâng-cao-db-step)
8. [Các trường hợp đặc biệt & failure paths](#8-các-trường-hợp-đặc-biệt)
9. [How to run — Bash script mẫu](#9-how-to-run)
10. [Xác minh kết quả grading](#10-xác-minh-kết-quả-grading)

---

## 1. Tổng quan Assertion Engine

Assertion Engine (`executor-service/service/AssertionEngine.java`) kiểm tra response từ app sinh viên so với các điều kiện được định nghĩa trong step config.

### Quy trình tổng thể

```
Step config (JSON)
    │
    ├── assertions[] → AssertionEngine.evaluateHttp()
    │       ├── expected_status check (implicit)
    │       ├── STATUS check
    │       ├── CONTAINS check
    │       ├── JSON_PATH check
    │       ├── BODY_EQUALS check
    │       ├── BODY_STRUCTURE check
    │       └── FIELD_EQUALS check
    │
    └── result: PASSED (all assertions pass) / FAILED (any assertion fails)
```

### Các kết quả có thể

| Kết quả | Khi nào | Ý nghĩa |
|---------|---------|----------|
| **PASSED** | Tất cả assertion đúng, HTTP request thành công | Step đạt |
| **FAILED** | Có ít nhất 1 assertion sai hoặc HTTP status không khớp | Step fail |
| **ERROR** | Lỗi mạng, timeout, parse error | Không thể đánh giá |
| **SKIPPED** | Bước required trước đó FAIL → dừng plan | Bị bỏ qua |

---

## 2. Các loại Assertion — Chi tiết từng loại

### 2.1 STATUS — So sánh HTTP Status Code

**Cấu hình:**
```json
{ "kind": "STATUS", "equals": 201 }
```

**Logic:** `actualStatus == expectedStatus`

**Tất cả các trường hợp kiểm tra:**

| # | HTTP Response | Expected | Kết quả | Message |
|---|---------------|----------|---------|---------|
| 1 | `201` | `201` | PASS | Status matched |
| 2 | `200` | `201` | FAIL | Expected status 201 but got 200 |
| 3 | `404` | `200` | FAIL | Expected status 200 but got 404 |
| 4 | `500` | `200` | FAIL | Expected status 200 but got 500 |
| 5 | `204` | `204` | PASS | Status matched |
| 6 | `200` | `200` | PASS | Status matched |

**Khi nào dùng:**

| Method | Thường dùng expected_status |
|--------|----------------------------|
| POST (tạo mới) | 201 |
| GET (lấy dữ liệu) | 200 |
| PUT (cập nhật toàn bộ) | 200 |
| PATCH (cập nhật một phần) | 200 |
| DELETE (xóa) | 204 |

**Test case cho mỗi status:**

```bash
# Test POST -> 201
curl -X POST http://localhost:8081/api/v1/books \
  -H "Content-Type: application/json" \
  -d '{"title":"Test","author":"A"}'

# Test GET -> 200
curl -X GET http://localhost:8081/api/v1/books/1

# Test DELETE -> 204
curl -X DELETE http://localhost:8081/api/v1/books/1

# Test GET on deleted resource -> 404
curl -X GET http://localhost:8081/api/v1/books/9999
```

---

### 2.2 CONTAINS — Kiem Tra Substring Trong Body

**Cau hinh:**
```json
{ "kind": "CONTAINS", "text": "Test Book" }
```

**Logic:** `actualBody.contains(text)` — phan biet chu hoa thuong

**Tat ca cac truong hop kiem tra:**

| # | Response Body | Text | Kết quả |
|---|---------------|------|---------|
| 1 | {"title":"Test Book","id":"1"} | "Test Book" | PASS |
| 2 | {"title":"Other Book"} | "Test Book" | FAIL |
| 3 | {"title":"Hello World"} | "world" | FAIL (case-sensitive) |
| 4 | {"title":"Hello World"} | "World" | PASS |
| 5 | {"message":"Book created"} | "created" | PASS |
| 6 | {"error":"Not found"} | "success" | FAIL |
| 7 | "" (empty) | "anything" | FAIL |
| 8 | {"books":[...]} | "books" | PASS |

**Khi nao dung:**
- Kiem tra message thanh cong
- Kiem tra title/name co dung khong
- Kiem tra mot tu khoa cu the trong response

**Test cases:**

```json
// Case 1: exact match — PASS
{ "kind": "CONTAINS", "text": "Dems Mèn Phiêu Lưu Ký" }

// Case 2: partial match — PASS
{ "kind": "CONTAINS", "text": "Dems Mèn" }

// Case 3: case-sensitive — FAIL
{ "kind": "CONTAINS", "text": "dems mèn" }
// Response: "Dems Mèn Phiêu Lưu Ký"
// FAIL because "dems mèn" not found (case-sensitive)
```

---

### 2.3 JSON_PATH — Kiem Tra Sự Tồn Tại Của Trường

**Cấu hình:**
```json
{ "kind": "JSON_PATH", "path": "$.id", "exists": true }
```

**Logic:** Dùng Jayway JsonPath đọc path từ response body. Kiểm tra kết quả có tồn tại (không null và không rỗng). `exists:false` đảo ngược.

**Tất cả các dạng JsonPath:**

| JsonPath | Ý nghĩa | Ví dụ Response | Kết quả |
|----------|----------|----------------|---------|
| $.id | Trường ở root | {"id":"abc"} | "abc" |
| $.author.name | Trường lồng nhau | {"author":{"name":"A"}} | "A" |
| $..id | Đệ quy tất cả id | {"a":{"id":"1"}} | ["1"] |
| $.items[0] | Phần tử mảng | {"items":[{"id":"a"}]} | {"id":"a"} |
| $.items[*] | Tất cả phần tử | {"items":[{"id":"a"},{"id":"b"}]} | [{"id":"a"},{"id":"b"}] |
| $.data[0].title | Mảng lồng nhau | {"data":[{"title":"X"}]} | "X" |

**Tất cả các trường hợp:**

| # | Response | Path | exists | Kết quả |
|---|----------|------|--------|---------|
| 1 | {"id":"abc"} | $.id | true | PASS |
| 2 | {"title":"Test"} | $.id | true | FAIL |
| 3 | {"title":"Test"} | $.id | false | PASS |
| 4 | {"error":"bad"} | $.error | false | FAIL |
| 5 | {"data":{"id":1}} | $.data.id | true | PASS |
| 6 | {"data":{}} | $.data.id | true | FAIL |
| 7 | {"items":[{"id":"a"}]} | $.items[0].id | true | PASS |
| 8 | [] | $.id | true | FAIL |
| 9 | null | $.id | false | PASS |

**Khi nao dung:**
- exists: true → Kiem tra trường bắt buộc tồn tại
- exists: false → Kiem tra trường lỗi KHÔNG tồn tại

---

### 2.4 BODY_EQUALS — So Sanh Toan Bo Response Body

**Cấu hình:**
```json
{ "kind": "BODY_EQUALS", "json": { "id": "abc-123", "title": "Test Book" } }
```

**Logic:** So sánh JSON response thực tế với JSON kỳ vọng. **Không phân biệt thứ tự field.** Giá trị phải khớp chính xác.

**Tất cả các trường hợp:**

| # | Response Body | Expected | Kết quả | Lý do |
|---|---------------|----------|---------|-------|
| 1 | {"id":"abc","title":"Test"} | {"id":"abc","title":"Test"} | PASS | Exact match |
| 2 | {"title":"Test","id":"abc"} | {"id":"abc","title":"Test"} | PASS | Order doesn't matter |
| 3 | {"id":"abc"} | {"id":"abc","title":"Test"} | FAIL | Thiếu title |
| 4 | {"id":"abc","title":"Other"} | {"id":"abc","title":"Test"} | FAIL | Giá trị khác |
| 5 | {"id":"abc","title":"Test","extra":"x"} | {"id":"abc","title":"Test"} | FAIL | Thừa field |
| 6 | {"id":null,"title":""} | {"id":null,"title":""} | PASS | Null/empty match |
| 7 | {"number":42} | {"number":42} | PASS | Number match |
| 8 | {"number":42.0} | {"number":42} | FAIL | Type mismatch |

**Khi nao dung:**
- Xac nhan response chính xác xác
- Kiem tra response sau khi cập nhật (PUT/PATCH)

---

### 2.5 BODY_STRUCTURE — So Sanh Cau Truc Response Body

**Cấu hình:**
```json
{ "kind": "BODY_STRUCTURE", "json": { "id": "", "title": "" } }
```

**Logic:** So sánh **cấu trúc JSON** (có những trường nào), **không so sánh giá trị**. Dùng `GsonStructureComparator`. Key set phải bằng nhau (unordered), giá trị bị bỏ qua.

**Tất cả các trường hợp:**

| # | Response Body | Expected Structure | Kết quả |
|---|---------------|-------------------|---------|
| 1 | {"id":"abc","title":"Test"} | {"id":"","title":""} | PASS |
| 2 | {"id":"abc","title":"Test","extra":"x"} | {"id":"","title":""} | FAIL |
| 3 | {"id":"abc"} | {"id":"","title":""} | FAIL |
| 4 | {"title":"Test","id":"abc"} | {"id":"","title":""} | PASS |
| 5 | {"id":1,"title":"Test"} | {"id":"","title":""} | PASS |
| 6 | {"bookId":"123","name":"Test"} | {"id":"","title":""} | FAIL |

**Nested objects:**

| # | Response | Structure | Kết quả |
|---|----------|-----------|---------|
| 1 | {"data":{"id":"1","title":"T"}} | {"data":{"id":"","title":""}} | PASS |
| 2 | {"data":{"id":"1","name":"X"}} | {"data":{"id":"","title":""}} | FAIL |
| 3 | {"items":[{"id":"1"},{"id":"2"}]} | {"items":[{"id":""},{"id":""}]} | PASS |
| 4 | {"items":[{"id":"1"}]} | {"items":[{"id":""},{"id":""}]} | FAIL |

**Khi nao dung:**
- Giá trị thay đổi theo thời gian (timestamp, auto-generated ID)
- Chỉ kiểm tra response có đúng schema không

---

### 2.6 FIELD_EQUALS — Kiem Tra 1 Truong = Gia Tri Ky Vong

**Cấu hình:**
```json
{ "kind": "FIELD_EQUALS", "path": "$.id", "equals": "${bookId}" }
```

**Logic:**
1. Đọc giá trị tại JsonPath `path` từ response body
2. Thay thế `${var}` trong `equals` bằng giá trị từ `VariableContext`
3. So sánh `actual == expected` (chuỗi)

**Tất cả các trường hợp:**

| # | Response Body | Path | equals | Kết quả |
|---|---------------|------|--------|---------|
| 1 | {"id":"abc1"} | $.id | "${book1Id}" (book1Id="abc1") | PASS |
| 2 | {"id":"abc1"} | $.id | "${book1Id}" (book1Id="abc2") | FAIL |
| 3 | {"title":"Sach A"} | $.id | "abc1" | FAIL |
| 4 | {"id":"abc1"} | $.id | "abc1" (literal) | PASS (but hardcode) |
| 5 | {"user":{"id":"xyz"}} | $.user.id | "xyz" | PASS |
| 6 | {"id":123} | $.id | "${id}" (id="123") | PASS |
| 7 | null | $.id | "anything" | FAIL |

**Khi nao dung:**
- Kiem tra 1 field có đúng giá trị kỳ vọng
- Dùng với `autoInjectExtracts` để truyền biến giữa steps
- **Luôn dùng `${var}`** để chống hardcode

---

### 2.7 expected_status — Kiem Tra Trang Thai HTTP (Implicit)

**Logic:** Nếu step config có `expected_status`, AssertionEngine tự động kiểm tra `actualStatus == expectedStatus`. Đây là assertion **ngầm định**.

```json
{
  "method": "POST",
  "path": "/api/v1/books",
  "expected_status": 201
}
```

| actualStatus | expected_status | Kết quả |
|-------------|-----------------|---------|
| 201 | 201 | PASS |
| 200 | 201 | FAIL |
| 204 | 204 | PASS |
| 500 | 200 | FAIL |
| 404 | 404 | PASS |

---

## 3. Bảng tổng hợp Assertion

| Kind | Cấu hình | Kiểm tra | Case-sensitive |
|------|----------|----------|----------------|
| `STATUS` | `{ "kind": "STATUS", "equals": 201 }` | HTTP status code | N/A |
| `CONTAINS` | `{ "kind": "CONTAINS", "text": "hello" }` | Substring trong body | Có |
| `JSON_PATH` | `{ "kind": "JSON_PATH", "path": "$.id", "exists": true }` | Trường tồn tại | N/A |
| `BODY_EQUALS` | `{ "kind": "BODY_EQUALS", "json": {...} }` | Toàn bộ body | N/A |
| `BODY_STRUCTURE` | `{ "kind": "BODY_STRUCTURE", "json": {...} }` | Cấu trúc (không value) | N/A |
| `FIELD_EQUALS` | `{ "kind": "FIELD_EQUALS", "path": "$.id", "equals": "${var}" }` | 1 field = value | N/A |
| Implicit | `"expected_status": 201` | Status code | N/A |

**Rules:**
- Tất cả assertion trong 1 step phải PASS → step PASSED
- Nếu `assertions: []` và `expected_status` không có → bước chỉ kiểm tra HTTP request hoàn tất thành công (smoke test)
- `kind` không hợp lệ → assertion đó tự động FAIL
- `status` assertion cần `equals`; `json_path` cần `path`; `contains` cần `text`

---

## 4. Các loại Step ngoài HTTP_REQUEST

### 4.1 DB_QUERY

**Config:**
```json
{
  "connection": {"db_type": "postgres", "database": "bookstore", "username": "u", "password": "p"},
  "query": "SELECT title, author FROM books WHERE id = ${bookId}",
  "expected": {"row_count": 1, "columns": ["title", "author"]},
  "timeoutMs": 30000
}
```

**Assertion check:**
- `expected.row_count` — exact match
- `expected.columns` — case-insensitive ordered column name match
- All must pass → PASSED

### 4.2 DB_SCHEMA_CHECK

```json
{
  "connection": {"db_type": "postgres", "database": "bookstore", "username": "u", "password": "p"},
  "checks": [
    {"kind": "TABLE_EXISTS", "table_name": "books"},
    {"kind": "COLUMN_EXISTS", "table_name": "books", "column_name": "title"},
    {"kind": "PRIMARY_KEY", "table_name": "books", "column": "id"},
    {"kind": "INDEX_EXISTS", "index_name": "idx_books_title"}
  ]
}
```

**Assertion check:** One `AssertionDetail` per check. All pass → PASSED.

### 4.3 DB_MIGRATION

```json
{
  "connection": {"db_type": "postgres", "database": "bookstore", "username": "u", "password": "p"},
  "statements": ["INSERT INTO books VALUES (...)"]
}
```

**No assertions** → PASSED if all statements commit. Any error → ROLLBACK + ERROR.

**MySQL/MariaDB caveat:** DDL migration followed by failing statement is best-effort. Keep DDL and DML in separate steps.

### 4.4 EXTRACT & DELAY

- `EXTRACT` — No assertions. Always PASSED (unless extraction error → ERROR).
- `DELAY` — No assertions. Always PASSED.

---

## 5. Test Plan Thực Tế — "CRUD Book API"

### 5.1 Thông tin assignment

```
Title: "Bài tập quản lý sách — CRUD"
Description: "Tạo và kiểm tra API quản lý sách với Spring Boot"
Grading Strategy: STUDENT_DOCKER_COMPOSE
Plans: 1 plan ("grade-books", sequenceOrder=1, weight=10)
```

### 5.2 Docker Compose Template

```yaml
services:
  app:
    image: student-book-api:latest
    ports:
      - "8080:8080"
    environment:
      - SPRING_PROFILES_ACTIVE=test
```

### 5.3 Test Plan — Tạo plan

```json
POST /api/v1/assignments/{assignmentId}/plans
{
  "name": "grade-books",
  "description": "CRUD book API — tất cả các assertion",
  "sequenceOrder": 1,
  "weight": 10
}
```

**Response:**
```json
{
  "status": 201,
  "message": "Created",
  "data": {
    "id": "plan-uuid-001",
    "name": "grade-books",
    "sequenceOrder": 1,
    "weight": 10
  }
}
```

Lưu lại `data.id` làm `PLAN_ID`.

---

## 6. Chi Tiết Từng Bước Trong Test Plan

### Step 1: Tạo sách mới (POST)

**Mục đích:** Tạo resource, kiểm tra `expected_status`, `JSON_PATH`, `CONTAINS`, extract `bookId`.

```json
POST /api/v1/assignments/{assignmentId}/plans/{PLAN_ID}/steps
{
  "stepOrder": 1,
  "name": "Create a book",
  "stepType": "HTTP_REQUEST",
  "weight": 2,
  "required": true,
  "timeoutMs": 5000,
  "config": {
    "method": "POST",
    "path": "/api/v1/books",
    "headers": {"Content-Type": "application/json"},
    "body": {
      "title": "Dems Mèn Phiêu Lưu Ký",
      "author": "Tô Hoài",
      "year": 1941
    },
    "expected_status": 201,
    "extract": [
      {"name": "bookId", "from": "response_body", "expression": "$.id"},
      {"name": "bookTitle", "from": "response_body", "expression": "$.title"}
    ],
    "assertions": [
      {"kind": "STATUS", "equals": 201},
      {"kind": "JSON_PATH", "path": "$.id", "exists": true},
      {"kind": "JSON_PATH", "path": "$.title", "exists": true},
      {"kind": "CONTAINS", "text": "Dems Mèn"}
    ]
  }
}
```

**Yêu cầu từ app sinh viên:**
```json
{"id": "abc-123", "title": "Dems Mèn Phiêu Lưu Ký", "author": "Tô Hoài", "year": 1941}
```

**Assertion evaluation:**

| Assertion | Logic | Kết quả |
|-----------|-------|---------|
| STATUS 201 | actualStatus == 201 | PASS |
| JSON_PATH $.id exists | body.id != null | PASS |
| JSON_PATH $.title exists | body.title != null | PASS |
| CONTAINS "Dems Mèn" | body.toString().contains("Dems Mèn") | PASS |

**Variable extraction:** bookId = "abc-123", bookTitle = "Dems Mèn Phiêu Lưu Ký"

---

### Step 2: Lấy sách theo ID (GET)

**Mục đích:** Kiểm tra BODY_STRUCTURE.

```json
{
  "stepOrder": 2,
  "name": "Verify book details",
  "stepType": "HTTP_REQUEST",
  "weight": 2,
  "required": true,
  "config": {
    "method": "GET",
    "path": "/api/v1/books/${bookId}",
    "expected_status": 200,
    "assertions": [
      {"kind": "STATUS", "equals": 200},
      {"kind": "BODY_STRUCTURE", "json": {"id": "", "title": "", "author": "", "year": 0}}
    ]
  }
}
```

**Assertion evaluation — BODY_STRUCTURE:**

Key set {"id","title","author","year"} matches → PASSED (structure matches, values ignored).

Nếu response thiếu author → FAILED (key set mismatch).
Nếu response thừa extra → FAILED.

---

### Step 3: Tìm kiếm sách (GET)

**Mục đích:** Kiểm tra CONTAINS với biến ${bookTitle}, JSON_PATH trên mảng.

```json
{
  "stepOrder": 3,
  "name": "Search by title",
  "stepType": "HTTP_REQUEST",
  "weight": 2,
  "required": true,
  "config": {
    "method": "GET",
    "path": "/api/v1/books?title=${bookTitle}",
    "expected_status": 200,
    "assertions": [
      {"kind": "STATUS", "equals": 200},
      {"kind": "JSON_PATH", "path": "$", "exists": true},
      {"kind": "CONTAINS", "text": "${bookTitle}"}
    ]
  }
}
```

**Variable substitution:** ${bookTitle} → "Dems Mèn Phiêu Lưu Ký"

---

### Step 4: Cập nhật sách (PATCH)

**Mục đích:** Kiểm tra BODY_EQUALS với biến ${bookId}.

```json
{
  "stepOrder": 4,
  "name": "Update book",
  "stepType": "HTTP_REQUEST",
  "weight": 2,
  "required": true,
  "config": {
    "method": "PATCH",
    "path": "/api/v1/books/${bookId}",
    "expected_status": 200,
    "headers": {"Content-Type": "application/json"},
    "body": {"title": "Dems Mèn — Bản cập nhật", "year": 1975},
    "assertions": [
      {"kind": "STATUS", "equals": 200},
      {"kind": "BODY_EQUALS", "json": {"id": "${bookId}", "title": "Dems Mèn — Bản cập nhật", "year": 1975}}
    ]
  }
}
```

**Lưu ý:** Nếu app trả về thừa field author, BODY_EQUALS sẽ FAIL vì Gson deep equals so sánh cả key set. Dùng BODY_STRUCTURE nếu không quan tâm field thừa.

---

### Step 5: Xóa sách (DELETE)

**Mục đích:** Kiểm tra expected_status: 204 và JSON_PATH exists: false.

```json
{
  "stepOrder": 5,
  "name": "Delete book",
  "stepType": "HTTP_REQUEST",
  "weight": 2,
  "required": true,
  "config": {
    "method": "DELETE",
    "path": "/api/v1/books/${bookId}",
    "expected_status": 204,
    "assertions": [
      {"kind": "STATUS", "equals": 204},
      {"kind": "JSON_PATH", "path": "$.id", "exists": false}
    ]
  }
}
```

**Response:** 204 No Content, body = "" → JSON_PATH $.id exists:false → PASS.

---

### Step 6: Xác nhận xóa (GET)

```json
{
  "stepOrder": 6,
  "name": "Verify deletion",
  "stepType": "HTTP_REQUEST",
  "weight": 2,
  "required": false,
  "config": {
    "method": "GET",
    "path": "/api/v1/books/${bookId}",
    "expected_status": 404,
    "assertions": [
      {"kind": "STATUS", "equals": 404},
      {"kind": "CONTAINS", "text": "Not found"}
    ]
  }
}
```

---

### Step 7 (Optional): Kiểm tra lỗi validation

```json
{
  "stepOrder": 7,
  "name": "Create book with empty title",
  "stepType": "HTTP_REQUEST",
  "weight": 1,
  "required": false,
  "config": {
    "method": "POST",
    "path": "/api/v1/books",
    "expected_status": 400,
    "headers": {"Content-Type": "application/json"},
    "body": {"title": "", "author": "Test"},
    "assertions": [
      {"kind": "STATUS", "equals": 400},
      {"kind": "CONTAINS", "text": "validation"}
    ]
  }
}
```

---

### Step 8: DB_QUERY

```json
{
  "stepOrder": 8,
  "name": "Verify book in DB",
  "stepType": "DB_QUERY",
  "weight": 2,
  "required": true,
  "timeoutMs": 15000,
  "config": {
    "connection": {"db_type": "postgres", "db_service": "db", "database": "bookstore", "username": "postgres", "password": "postgres"},
    "query": "SELECT title, author, year FROM books WHERE id = ${bookId}",
    "expected": {"row_count": 1, "columns": ["title", "author", "year"]}
  }
}
```

### Step 9: DB_SCHEMA_CHECK

```json
{
  "stepOrder": 9,
  "name": "Check DB schema",
  "stepType": "DB_SCHEMA_CHECK",
  "weight": 2,
  "required": true,
  "config": {
    "connection": {"db_type": "postgres", "db_service": "db", "database": "bookstore", "username": "postgres", "password": "postgres"},
    "checks": [
      {"kind": "TABLE_EXISTS", "table_name": "books"},
      {"kind": "COLUMN_EXISTS", "table_name": "books", "column_name": "title"},
      {"kind": "PRIMARY_KEY", "table_name": "books", "column": "id"}
    ]
  }
}
```

### Step 10: DB_MIGRATION

```json
{
  "stepOrder": 10,
  "name": "Seed data",
  "stepType": "DB_MIGRATION",
  "weight": 1,
  "required": true,
  "config": {
    "connection": {"db_type": "postgres", "db_service": "db", "database": "bookstore", "username": "postgres", "password": "postgres"},
    "statements": [
      "INSERT INTO books (id, title, author, year) VALUES ('11111111-1111-1111-1111-111111111111', 'Book A', 'Author A', 2000)"
    ]
  }
}
```

---

## 7. Test Plan Nâng Cao — DB Step Kiểm Tra

### 7.1 Multi-DBMS Test (MySQL/MariaDB)

```json
{
  "stepOrder": 11,
  "name": "MySQL book check",
  "stepType": "DB_QUERY",
  "weight": 2,
  "required": true,
  "config": {
    "connection": {"db_type": "mysql", "db_service": "db", "database": "bookstore", "username": "root", "password": "root"},
    "query": "SELECT title FROM books WHERE id = ${bookId}",
    "expected": {"row_count": 1, "columns": ["title"]}
  }
}
```

**db_type giá trị hợp lệ:** postgres (mặc định), mysql, mariadb (alias của mysql). Blank/unknown → FAIL trước khi claim port.

### 7.2 DB Migration trên MySQL/MariaDB — Cảnh báo

DDL migration followed by failing statement is best-effort trên MySQL/MariaDB (DDL already durably applied, rollback cannot undo). Giảng viên nên keep DDL và DML trong separate steps.

---

## 8. Các Trường Hợp Đặc Biệt & Failure Paths

### 8.1 Step FAIL với required=true

```
Step 1 FAIL (required=true) → Plan STOPS → Steps 2-N = SKIPPED
Score = (weight of passed steps before step 1) / (weight of all steps that ran) × 10
```

### 8.2 Step FAIL với required=false

```
Step 1 PASSED, Step 2 FAILED (required=false), Step 3 PASSED
→ Plan CONTINUES
Score = (passedWeight) / (ranWeight) × 10
```

### 8.3 Score Formula

```
Score = (passedWeight / ranWeight) × 10.00

Ví dụ:
  All 6 steps PASSED:  (6/6) × 10 = 10.00
  4/6 pass:            (4/6) × 10 = 6.67
  0/6 pass:            (0/6) × 10 = 0.00
  Steps 1,2 pass; Step 3 FAIL (required=true) → Steps 4-6 SKIPPED:
    passedWeight = 4 (Steps 1,2)
    ranWeight = 6 (Steps 1,2,3)
    Score = (4/6) × 10 = 6.67
```

### 8.4 Missing variable in path

```
Path: "/api/v1/books/${bookId}"
bookId never extracted → VariableContext.substitute() replaces with ""
Path becomes "/api/v1/books/" → wrong URL → 404 → FAILED
WARN logged: "Variable 'bookId' not found in context"
```

### 8.5 Duplicate step_order

```
POST step with stepOrder=3, but stepOrder=3 already exists in plan
→ 400 "step_order 3 already exists in plan 'grade-books'"
```

### 8.6 Duplicate plan sequenceOrder

```
POST plan with sequenceOrder=1, but already exists
→ 400 "A plan with sequence_order 1 already exists in this assignment"
```

### 8.7 Invalid config → 400

| Invalid Config | Error |
|---------------|-------|
| method: "TELEPORT" | 400 — invalid HTTP method |
| path: "no-slash" | 400 — path must start with / |
| expected_status: 42 | 400 — must be 100-599 |
| assertions: [{"kind":"magic"}] | 400 — unknown assertion kind |
| DB_SCHEMA_CHECK checks: [] | 400 — checks must be non-empty |
| DELAY duration_ms: -5 | 400 — must be positive |
| DB_MIGRATION statements: [] | 400 — statements must be non-empty |
| EXTRACT variables: [{"name":"orphan"}] | 400 — missing from/expression |

### 8.8 Ownership Check

```bash
# Lecturer 1 creates assignment and plan
# Lecturer 2 tries to access:
GET /api/v1/assignments/{assignmentId}/plans
X-User-Id: <lecturer2-uuid>
# → 404 (indistinguishable from not-found)
```

### 8.9 Duplicate Submission — Idempotency

Cùng submissionId gửi 2 lần:
- Lần 1: PENDING → gradeAsync() → DONE
- Lần 2: DataIntegrityViolationException (unique constraint)
- Nếu job tồn tại + FAILED → reset → re-grade
- Nếu không → log duplicate, bỏ qua

### 8.10 Pool Saturated

gradingTaskExecutor (corePoolSize=1, queueCapacity=10) đã đầy → TaskRejectedException → Job giữ PENDING → StaleJobReaper retry sau 30 phút.

---

## 9. How to Run — Bash Script Mẫu

### 9.1 Setup Variables

```bash
export BASE_URL=http://localhost:8081
export OWNER="2d93941a-4221-458b-a03d-43bd6315d02e"  # lecturer UUID
export STAMP=$(date +%s)
```

### 9.2 Complete Script

```bash
#!/usr/bin/env bash
# Full grading test plan — CRUD Book API
# Usage: BASE_URL=http://localhost:18081 ./grading-test-plan.sh
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:18081}"
OWNER="${OWNER:-2d93941a-4221-458b-a03d-43bd6315d02e}"
PASS=0; FAIL=0

assert_eq() {
    if [ "$2" == "$3" ]; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1 (actual='$2' expected='$3')"; fi
}

call_api() {
    local method=$1 path=$2 body=${3:-}
    local tmp; tmp=$(mktemp)
    if [ -n "$body" ]; then
        STATUS=$(curl -s -m 30 -o "$tmp" -w "%{http_code}" -X "$method" "$BASE_URL$path" \
            -H "X-User-Id: $OWNER" -H "Content-Type: application/json" -d "$body")
    else
        STATUS=$(curl -s -m 30 -o "$tmp" -w "%{http_code}" -X "$method" "$BASE_URL$path" \
            -H "X-User-Id: $OWNER")
    fi
    BODY=$(cat "$tmp"); rm -f "$tmp"
}

# ─── Phase 1: Setup ───
call_api POST "/api/v1/classes" "{\"name\":\"test-class-$STAMP\",\"semester\":\"20261\"}"
assert_eq "Create class" "$STATUS" "201"
CLASS_ID=$(echo "$BODY" | jq -r '.data.id')

call_api POST "/api/v1/assignments" "{\"title\":\"CRUD Book API\",\"classId\":\"$CLASS_ID\",\"gradingStrategy\":\"STUDENT_DOCKER_COMPOSE\"}"
assert_eq "Create assignment" "$STATUS" "201"
ASSIGN_ID=$(echo "$BODY" | jq -r '.data.id')

call_api POST "/api/v1/assignments/$ASSIGN_ID/publish"
assert_eq "Publish" "$STATUS" "200"

call_api POST "/api/v1/assignments/$ASSIGN_ID/plans" "{\"name\":\"grade-books\",\"sequenceOrder\":1,\"weight\":10}"
assert_eq "Create plan" "$STATUS" "201"
PLAN_ID=$(echo "$BODY" | jq -r '.data.id')

# ─── Phase 2: Create Steps ───
# Step 1: POST
call_api POST "/api/v1/assignments/$ASSIGN_ID/plans/$PLAN_ID/steps" '{
  "stepOrder":1,"name":"Create a book","stepType":"HTTP_REQUEST","weight":2,"required":true,
  "config":{"method":"POST","path":"/api/v1/books","expected_status":201,
    "extract":[{"name":"bookId","from":"response_body","expression":"$.id"}],
    "assertions":[{"kind":"STATUS","equals":201},{"kind":"JSON_PATH","path":"$.id","exists":true},{"kind":"CONTAINS","text":"Test"}]}
}'
assert_eq "Step 1" "$STATUS" "201"

# Step 2: GET (BODY_STRUCTURE)
call_api POST "/api/v1/assignments/$ASSIGN_ID/plans/$PLAN_ID/steps" '{
  "stepOrder":2,"name":"Verify book","stepType":"HTTP_REQUEST","weight":2,"required":true,
  "config":{"method":"GET","path":"/api/v1/books/${bookId}","expected_status":200,
    "assertions":[{"kind":"STATUS","equals":200},{"kind":"BODY_STRUCTURE","json":{"id":"","title":""}}]}
}'
assert_eq "Step 2" "$STATUS" "201"

# Step 3: GET (CONTAINS)
call_api POST "/api/v1/assignments/$ASSIGN_ID/plans/$PLAN_ID/steps" '{
  "stepOrder":3,"name":"Search books","stepType":"HTTP_REQUEST","weight":2,"required":true,
  "config":{"method":"GET","path":"/api/v1/books","expected_status":200,
    "assertions":[{"kind":"STATUS","equals":200},{"kind":"CONTAINS","text":"books"}]}
}'
assert_eq "Step 3" "$STATUS" "201"

# Step 4: PATCH (BODY_EQUALS)
call_api POST "/api/v1/assignments/$ASSIGN_ID/plans/$PLAN_ID/steps" '{
  "stepOrder":4,"name":"Update book","stepType":"HTTP_REQUEST","weight":2,"required":true,
  "config":{"method":"PATCH","path":"/api/v1/books/${bookId}","expected_status":200,
    "assertions":[{"kind":"STATUS","equals":200},{"kind":"BODY_EQUALS","json":{"id":"${bookId}"}}]}
}'
assert_eq "Step 4" "$STATUS" "201"

# Step 5: DELETE (204)
call_api POST "/api/v1/assignments/$ASSIGN_ID/plans/$PLAN_ID/steps" '{
  "stepOrder":5,"name":"Delete book","stepType":"HTTP_REQUEST","weight":2,"required":true,
  "config":{"method":"DELETE","path":"/api/v1/books/${bookId}","expected_status":204,
    "assertions":[{"kind":"STATUS","equals":204},{"kind":"JSON_PATH","path":"$.id","exists":false}]}
}'
assert_eq "Step 5" "$STATUS" "201"

# Step 6: GET (404)
call_api POST "/api/v1/assignments/$ASSIGN_ID/plans/$PLAN_ID/steps" '{
  "stepOrder":6,"name":"Verify deletion","stepType":"HTTP_REQUEST","weight":2,"required":false,
  "config":{"method":"GET","path":"/api/v1/books/${bookId}","expected_status":404,
    "assertions":[{"kind":"STATUS","equals":404},{"kind":"CONTAINS","text":"Not found"}]}
}'
assert_eq "Step 6" "$STATUS" "201"

# Invalid config test
call_api POST "/api/v1/assignments/$ASSIGN_ID/plans/$PLAN_ID/steps" '{
  "stepOrder":99,"name":"bad","stepType":"HTTP_REQUEST","config":{"method":"TELEPORT","path":"/x"}
}'
assert_eq "Invalid config → 400" "$STATUS" "400"

# Step 7: DB_QUERY
call_api POST "/api/v1/assignments/$ASSIGN_ID/plans/$PLAN_ID/steps" '{
  "stepOrder":7,"name":"Verify in DB","stepType":"DB_QUERY","weight":2,"required":true,
  "timeoutMs":15000,
  "config":{"connection":{"db_type":"postgres","database":"bookstore","username":"postgres","password":"postgres"},
    "query":"SELECT title FROM books WHERE id = ${bookId}","expected":{"row_count":1,"columns":["title"]}}
}'
assert_eq "DB_QUERY step" "$STATUS" "201"

# Step 8: DB_SCHEMA_CHECK
call_api POST "/api/v1/assignments/$ASSIGN_ID/plans/$PLAN_ID/steps" '{
  "stepOrder":8,"name":"Check DB schema","stepType":"DB_SCHEMA_CHECK","weight":2,"required":true,
  "config":{"connection":{"db_type":"postgres","database":"bookstore","username":"postgres","password":"postgres"},
    "checks":[{"kind":"TABLE_EXISTS","table_name":"books"},{"kind":"COLUMN_EXISTS","table_name":"books","column_name":"title"}]}
}'
assert_eq "DB_SCHEMA_CHECK" "$STATUS" "201"

echo ""
echo "=============================="
if [ $FAIL -eq 0 ]; then echo "ALL $PASS ASSERTIONS PASSED"; else echo "$FAIL ASSERTIONS FAILED ($PASS passed)"; fi
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
```

---

## 10. Xác Minh Kết Quả Grading

### 10.1 Kiểm tra grading job status

```bash
GET /api/v1/internal/grading-jobs/{submissionId}
# Response: {"status": "DONE", "completedAt": "..."}
```

### 10.2 Kiểm tra step results

```bash
GET /api/v1/internal/grading-jobs/{submissionId}/step-results
# Response:
# data: [{stepOrder:1, stepName:"Create a book", status:"PASSED",
#   assertionResult:[{kind:"STATUS",passed:true,message:"Status matched"}],
#   extractedVariables:{bookId:"abc-123"}, durationMs:150}]
```

### 10.3 Kiểm tra điểm

```bash
GET /api/v1/results/{submissionId}
# Response:
# {score: 10.00, maxScore: 10.00, status: "DONE",
#  summaryLog: "Passed 6/6 steps (100%), Score: 10.00/10"}
```

### 10.4 Kiểm tra http_log INBOUND (tất cả 4 service)

```sql
SELECT direction, method, url, status_code, duration_ms
FROM http_log
WHERE service_name = 'course-service' AND direction = 'INBOUND'
ORDER BY created_at DESC;
-- Expected: INBOUND requests from api-gateway
```

### 10.5 Kiểm tra http_log OUTBOUND (executor grading)

```sql
SELECT direction, method, url, status_code, duration_ms
FROM http_log
WHERE service_name = 'executor-grading' AND direction = 'OUTBOUND'
ORDER BY created_at DESC;
-- Expected: OUTBOUND calls from executor to student app
```

---

## Appendix A — Complete Request Body Reference

### A.1 Create Class

```json
POST /api/v1/classes
Headers: X-User-Id: <uuid>, Content-Type: application/json
{ "name": "PTIT CNTT-K68", "semester": "20261" }
```

### A.2 Create Assignment

```json
POST /api/v1/assignments
{ "title": "Lab 01", "classId": "<classId>", "gradingStrategy": "STUDENT_DOCKER_COMPOSE" }
```

### A.3 Publish Assignment

```json
POST /api/v1/assignments/{id}/publish
```

### A.4 Create Plan

```json
POST /api/v1/assignments/{id}/plans
{ "name": "grade-books", "sequenceOrder": 1, "weight": 10 }
```

### A.5 Create Step — HTTP Request (full)

```json
{
  "stepOrder": 1, "name": "Create a book", "stepType": "HTTP_REQUEST",
  "weight": 2, "required": true, "timeoutMs": 5000,
  "config": {
    "method": "POST", "path": "/api/v1/books",
    "headers": {"Content-Type": "application/json"},
    "query_params": {"title": "Dems Mèn"},
    "body": {"title": "Dems Mèn Phiêu Lưu Ký", "author": "Tô Hoài"},
    "expected_status": 201,
    "assertions": [
      {"kind": "STATUS", "equals": 201},
      {"kind": "JSON_PATH", "path": "$.id", "exists": true},
      {"kind": "CONTAINS", "text": "Dems Mèn"},
      {"kind": "BODY_STRUCTURE", "json": {"id": "", "title": ""}},
      {"kind": "BODY_EQUALS", "json": {"title": "Dems Mèn Phiêu Lưu Ký"}}
    ],
    "extract": [{"name": "bookId", "from": "response_body", "expression": "$.id"}]
  }
}
```

### A.6 Create Step — DB Query

```json
{
  "stepOrder": 2, "name": "Verify in DB", "stepType": "DB_QUERY",
  "weight": 2, "required": true, "timeoutMs": 15000,
  "config": {
    "connection": {"db_type": "postgres", "database": "bookstore", "username": "postgres", "password": "postgres"},
    "query": "SELECT title, author FROM books WHERE id = ${bookId}",
    "expected": {"row_count": 1, "columns": ["title", "author"]}
  }
}
```

### A.7 Create Step — DB Schema Check

```json
{
  "stepOrder": 3, "name": "Check DB schema", "stepType": "DB_SCHEMA_CHECK",
  "weight": 2, "required": true,
  "config": {
    "connection": {"db_type": "postgres", "database": "bookstore", "username": "postgres", "password": "postgres"},
    "checks": [
      {"kind": "TABLE_EXISTS", "table_name": "books"},
      {"kind": "COLUMN_EXISTS", "table_name": "books", "column_name": "title"},
      {"kind": "PRIMARY_KEY", "table_name": "books", "column": "id"}
    ]
  }
}
```

### A.8 Create Step — DB Migration

```json
{
  "stepOrder": 4, "name": "Seed data", "stepType": "DB_MIGRATION",
  "weight": 1, "required": true,
  "config": {
    "connection": {"db_type": "postgres", "database": "bookstore", "username": "postgres", "password": "postgres"},
    "statements": ["INSERT INTO books (id, title) VALUES ('1', 'Book A')"]
  }
}
```

### A.9 Create Step — Extract Variable

```json
{
  "stepOrder": 5, "name": "Extract variables", "stepType": "EXTRACT",
  "weight": 1,
  "config": {
    "variables": [
      {"name": "pageSize", "value": "10"},
      {"name": "bookId", "from": "step_1", "expression": "$.id"}
    ]
  }
}
```

### A.10 Create Step — Delay

```json
{
  "stepOrder": 6, "name": "Wait", "stepType": "DELAY",
  "weight": 1,
  "config": {"duration_ms": 5000}
}
```

---

## Appendix B — AssertionResult JSON Format

```json
[
  {
    "kind": "STATUS",
    "expected": 201,
    "actual": 201,
    "passed": true,
    "message": "Status matched"
  },
  {
    "kind": "JSON_PATH",
    "expected": "exists:true",
    "actual": "found",
    "passed": true,
    "message": "$.id exists"
  },
  {
    "kind": "CONTAINS",
    "expected": "Dems Mèn",
    "actual": "Dems Mèn Phiêu Lưu Ký",
    "passed": true,
    "message": "Body contains 'Dems Mèn'"
  },
  {
    "kind": "BODY_EQUALS",
    "expected": {"title":"Test"},
    "actual": {"title":"Test","id":"abc"},
    "passed": false,
    "message": "Body not equal: extra field 'id'"
  }
]
```

---

## Appendix C — Changelog

| Version | Ngày | Thay đổi |
|---------|------|----------|
| v1.0 | 2026-09-16 | Bản đầu tiên — tất cả assertion types, test plan thực tế, bash script |
