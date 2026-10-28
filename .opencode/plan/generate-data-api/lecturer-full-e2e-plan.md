# Plan kiểm thử toàn luồng phía Giảng viên (Lecturer Full E2E)

Mục đích: Kiểm thử toàn bộ chức năng phía giảng viên từ tạo lớp, import CSV, cấu hình thành phần điểm, tạo bài tập kiểm tra (graded) với test plan đầy đủ cấu hình & assertion, tạo bài tập luyện tập (practice), kịch bản khó (tạo 3 bài rồi lọc danh sách), xem kết quả chấm bài, nhập điểm thủ công và bảng điểm.

Tất cả gọi qua **API Gateway**: `https://web-dev1-api.vucongtuanduong.dpdns.org/`
Keycloak: `https://web-dev1-keycloak.vucongtuanduong.dpdns.org/`

Hệ thống trả về envelope chuẩn:
```json
{ "status": 200, "message": "Success", "data": { ... }, "error": null }
```

---

## 1. Điểm cuối (Base URLs) & Header chuẩn

| Mục | Giá trị |
|-----|---------|
| API Gateway | `https://web-dev1-api.vucongtuanduong.dpdns.org` |
| Keycloak | `https://web-dev1-keycloak.vucongtuanduong.dpdns.org` |
| Realm | `ptit-wgs` |
| Header lecturer | `Authorization: Bearer <access_token>`<br>`X-User-Id: <lecturer-uuid>`<br>`X-Gateway-Secret: <secret>` |

Lưu ý: `X-User-Id`, `X-User-Email`, `X-User-Roles` được gatewayスタン từ JWT sau khi xác thực Keycloak. Lecturer phải có role `LECTURER`.

---

## 2. Chuẩn bị (Prerequisites)

Trước khi chạy plan, cần có:

| Mục | Nguồn | Ghi chú |
|-----|-------|---------|
| Keycloak username/password lecturer | Bạn cung cấp sau | Để lấy access token |
| File CSV danh sách sinh viên | Bạn cung cấp sau | Cột: `studentCode, studentName, email, studentUserId` |
| UUID lecturer | Lấy từ JWT `sub` | Dùng xuyên suốt toàn luồng |
| Docker image sinh viên | Tuỳ chọn | Nếu có mới trigger grading thật qua Kafka/executor |

---

## 3. Luồng xác thực (Auth)

1. Gọi Keycloak với username/password lecturer → nhận `access_token`.
2. Gateway xác thực JWT, cấp `X-User-Id`, `X-User-Roles`.
3. Mọi API phía giảng viên đều kèm header trên.

---

## 4. Dữ liệu test chuẩn (dùng xuyên suốt)

| Trường | Giá trị mẫu |
|------|-------------|
| Tên lớp | `PTIT CNTT-K68` |
| Học kỳ | `20261` |
| Tên môn graded | `Lab 01 - Quản lý sách REST API` |
| Tên môn practice | `Luyện tập SQL cơ bản` |
| Topic practice | `Truy vấn cơ bản` |
| Grading strategy | `STUDENT_DOCKER_COMPOSE` |
| dockerComposePort | `8080` |
| startupTimeoutMs | `60000` |
| executionTimeoutMs | `300000` |
| maxMemoryMb | `256` |
| maxCpu | `0.5` |

---

## 5. Phase 1 — Quản lý lớp (UC-01)

### 5.1 Tạo lớp

**API:** `POST /api/v1/classes`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:**
```json
{
  "name": "PTIT CNTT-K68",
  "semester": "20261"
}
```

**Expected:** `201 Created`, `data = { id, ownerId, name, semester, status: "ACTIVE" }`. Lưu `data.id` làm `{classId}` dùng cho toàn luồng sau.

**Negative:** trùng tên + học kỳ cùng giảng viên → `400`.

---

### 5.2 Cấu hình thành phần điểm (bắt buộc trước khi nhập điểm)

**API:** `PUT /api/v1/classes/{classId}/score-components`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:**
```json
[
  { "type": "ATTENDANCE", "weight": 0.10 },
  { "type": "EXERCISE",   "weight": 0.20 },
  { "type": "FINAL_EXAM", "weight": 0.70 }
]
```

**Expected:** `200 OK` với danh sách component đã chuẩn hóa.

**Validation (nếu sai → 400):**
- Trùng type → 400
- Phải có `FINAL_EXAM` → 400 nếu thiếu
- Weight `FINAL_EXAM` < 0.40 → 400
- Tổng weight != 1.000 (sai số ±0.001) → 400

---

### 5.3 Danh sách lớp (filter)

**API:** `GET /api/v1/classes?search=name:PTIT;semester:20261&page=0&size=20`

**Expected:** `200`, `data = { meta: { page, pageSize, pages, total }, result: [...] }`. Có lớp vừa tạo trong `result`.

**Lưu ý:** Grammar `search` ở `/api/v1/classes` là `field:value` cách nhau bởi `;` (khác với `/api/v1/assignments` dùng plain text).

---

## 6. Phase 2 — Import sinh viên từ CSV (UC-01)

### 6.1 Import CSV

**API:** `POST /api/v1/classes/{classId}/students/import`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:** `multipart/form-data`, trường `file` = `students-import.csv`

**Cột CSV mẫu:**
```
studentCode,studentName,email,studentUserId
S001,Nguyen Van A,sv001@ptit.edu.vn,
S002,Tran Thi B,sv002@ptit.edu.vn,
```

**Expected:** `200 OK`, `data = { imported: N, skipped: M }`.

**Negative:**
- Import lại file cũ → tất cả `skipped` (unique per class + student code)
- Sai content type (không phải multipart) → `400 "Malformed multipart request"`

**Self-healing:** Nếu CSV không có cột `studentUserId`, dòng đó sẽ `student_user_id = NULL`, sau đó khi sinh viên gọi API sinh viên, `StudentIdentityService` sẽ điền UUID dựa trên email khớp (case-insensitive), không ghi đè dòng đã có chủ sở hữu.

---

### 6.2 Xem danh sách sinh viên trong lớp

**API:** `GET /api/v1/classes/{classId}/students?page=0&size=20`

**Expected:** `200`, danh sách sinh viên đã import trong lớp.

---

## 7. Phase 3 — Tạo bài tập kiểm tra (graded assignment) + test plan đầy đủ (UC-02, UC-03)

Phần quan trọng nhất: phải cover **tất cả** assertion type, HTTP method, DB step, extract/chaining biến.

### 7.1 Tạo assignment (graded)

**API:** `POST /api/v1/assignments`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:**
```json
{
  "title": "Lab 01 - Quản lý sách REST API",
  "description": "Xây dựng REST API quản lý sách với CRUD đầy đủ",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Lập trình web",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```

**Expected:** `201 Created`, `data.id` = `{assignmentId}`, `published: false`.

**Negative:**
- Trùng title của giảng viên (không phân biệt purpose/lớp) → `400`
- classId không sở hữu (graded) → `404`
- LECTURER strategy thiếu `dockerComposeTemplate` → `400`
- Field validation lỗi → `400` chi tiết

---

### 7.2 Tạo plan chấm bài

**API:** `POST /api/v1/assignments/{assignmentId}/plans`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:**
```json
{
  "name": "CRUD Book API — Full",
  "description": "Kiểm tra toàn bộ vòng đời sách: tạo, đọc, cập nhật, xóa, validate DB",
  "sequenceOrder": 1,
  "weight": 10
}
```

**Expected:** `201 Created`, `data.id` = `{planId}`.

**Negative:** trùng `sequenceOrder` trong cùng assignment → `400`.

---

### 7.3 Tạo các step (cover hết assertion + method + extract)

Mỗi step gọi:
**API:** `POST /api/v1/assignments/{assignmentId}/plans/{planId}/steps`

#### Step 1 — POST tạo sách (extract bookId)

**Body:**
```json
{
  "stepOrder": 1,
  "name": "Tạo sách mới",
  "description": "POST /api/v1/books, trả về id để dùng cho bước sau",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/books",
    "headers": { "Content-Type": "application/json" },
    "body": { "title": "Dế Mèn Phiêu Lưu Ký", "author": "Tô Hoài", "year": 1941 },
    "expected_status": 201,
    "assertions": [
      { "kind": "status", "equals": 201 },
      { "kind": "json_path", "path": "$.id", "exists": true },
      { "kind": "json_path", "path": "$.title", "exists": true },
      { "kind": "contains", "text": "Dế Mèn" }
    ],
    "extract": [
      { "name": "bookId", "from": "response_body", "expression": "$.id" }
    ],
    "required": true,
    "timeoutMs": 5000
  },
  "expectedResult": null,
  "weight": 1
}
```

#### Step 2 — GET sách theo ID (dùng biến bookId từ step 1)

**Body:**
```json
{
  "stepOrder": 2,
  "name": "Lấy sách theo ID",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/books/${bookId}",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "body_structure", "json": { "id": "", "title": "", "author": "", "year": "" } },
      { "kind": "field_equals", "path": "$.id", "equals": "${bookId}" }
    ]
  },
  "expectedResult": null,
  "weight": 1
}
```

#### Step 3 — GET danh sách sách (contains + json_path array)

**Body:**
```json
{
  "stepOrder": 3,
  "name": "Lấy danh sách sách",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/books",
    "query_params": { "title": "Dế Mèn" },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "json_path", "path": "$", "exists": true },
      { "kind": "contains", "text": "Dế Mèn" }
    ]
  },
  "expectedResult": null,
  "weight": 1
}
```

#### Step 4 — PATCH cập nhật sách

**Body:**
```json
{
  "stepOrder": 4,
  "name": "Cập nhật sách",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "PATCH",
    "path": "/api/v1/books/${bookId}",
    "headers": { "Content-Type": "application/json" },
    "body": { "title": "Dế Mèn Phiêu Lưu Ký - Bản sửa" },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "Bản sửa" }
    ]
  },
  "expectedResult": null,
  "weight": 1
}
```

#### Step 5 — DELETE sách

**Body:**
```json
{
  "stepOrder": 5,
  "name": "Xóa sách",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "DELETE",
    "path": "/api/v1/books/${bookId}",
    "expected_status": 204,
    "assertions": [
      { "kind": "status", "equals": 204 }
    ],
    "required": true,
    "timeoutMs": 5000
  },
  "expectedResult": null,
  "weight": 1
}
```

#### Step 6 — GET lại kiểm tra đã xóa (404)

**Body:**
```json
{
  "stepOrder": 6,
  "name": "Kiểm tra sách đã xóa",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/books/${bookId}",
    "expected_status": 404,
    "assertions": [
      { "kind": "status", "equals": 404 }
    ]
  },
  "expectedResult": null,
  "weight": 1
}
```

#### Step 7 — DB_SCHEMA_CHECK (kiểm tra bảng books trong DB sinh viên)

**Body:**
```json
{
  "stepOrder": 7,
  "name": "Kiểm tra schema bảng books",
  "stepType": "DB_SCHEMA_CHECK",
  "config": {
    "connection": {
      "db_type": "postgres",
      "database": "bookstore",
      "username": "postgres",
      "password": "postgres"
    },
    "checks": [
      { "kind": "TABLE_EXISTS", "table_name": "books" },
      { "kind": "COLUMN_EXISTS", "table_name": "books", "column_name": "title" },
      { "kind": "PRIMARY_KEY", "table_name": "books", "column": "id" }
    ],
    "timeoutMs": 30000
  },
  "expectedResult": null,
  "weight": 1
}
```

#### Step 8 — DB_QUERY (kiểm tra dữ liệu đã xóa)

**Body:**
```json
{
  "stepOrder": 8,
  "name": "Kiểm tra dữ liệu sách đã xóa",
  "stepType": "DB_QUERY",
  "config": {
    "connection": {
      "db_type": "postgres",
      "database": "bookstore",
      "username": "postgres",
      "password": "postgres"
    },
    "query": "SELECT COUNT(*) FROM books WHERE id = ${bookId}",
    "expected": { "row_count": 1, "columns": ["count"] },
    "timeoutMs": 30000
  },
  "expectedResult": { "row_count": 1 },
  "weight": 1
}
```

---

### 7.4 Verify plan & steps (lấy lại)

**API:** `GET /api/v1/assignments/{assignmentId}/plans`

**Expected:** `200`, danh sách plans sắp xếp theo `sequenceOrder`, mỗi plan lồng `steps` sắp xếp theo `stepOrder`, `config` round-trip đúng.

---

### 7.5 Publish assignment

**API:** `POST /api/v1/assignments/{assignmentId}/publish`

**Expected:** `200 OK`, idempotent, `published: true`.

---

### 7.6 (Tuỳ chọn) Link Docker images

**API:** `PUT /api/v1/assignments/{assignmentId}/docker-images`

**Body:**
```json
{ "dockerImageIds": ["<uuid-image>"] }
```

**Expected:** `200 OK`. Cần đã đăng ký image qua UC-10 trước.

---

## 8. Phase 4 — Tạo bài tập luyện tập (practice) (UC-02b)

### 8.1 Tạo practice assignment (không gắn lớp)

**API:** `POST /api/v1/assignments`

**Body:**
```json
{
  "title": "Luyện tập SQL cơ bản",
  "description": "Bài luyện tập truy vấn SQL cơ bản cho sinh viên",
  "purpose": "PRACTICE",
  "topic": "Truy vấn cơ bản",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```

**Lưu ý quan trọng:**
- `classId` **không gửi** (null). Nếu gửi `classId` với `purpose=PRACTICE` → `400`.
- `topic` bắt buộc.
- `title` phải duy nhất với mọi bài của giảng viên.

**Expected:** `201 Created`, `published: false`, `purpose: "PRACTICE"`.

---

### 8.2 Tạo plan & steps cho practice

Tương tự Phase 3, nhưng đơn giản hơn (ví dụ 2-3 step HTTP cơ bản: health check, query đơn giản). Sau đó publish.

---

### 8.3 Lọc danh sách practice

**API:** `GET /api/v1/assignments?purpose=PRACTICE&topic=Truy vấn cơ bản&page=0&size=20`

**Expected:** `200`, chỉ có bài practice của giảng viên này.

---

## 9. Phase 5 — Kịch bản khó: tạo 3 bài khác nhau, rồi lọc danh sách (UC-02)

Mục tiêu: kiểm tra `GET /api/v1/assignments` filter đúng dữ liệu, không bị trộn lẫn.

### 9.1 Tạo 3 assignment (giống classId, khác title/topic/purpose)

**Lần 1 (Graded):**
```json
POST /api/v1/assignments
{
  "title": "Lab 01 - Quản lý sách REST API",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Lập trình web",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```

**Lần 2 (Graded):**
```json
POST /api/v1/assignments
{
  "title": "Lab 02 - Quản lý độc giả",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Lập trình web",
  ...
}
```

**Lần 3 (Practice, không gắn lớp):**
```json
POST /api/v1/assignments
{
  "title": "Luyện tập SQL cơ bản",
  "purpose": "PRACTICE",
  "topic": "Truy vấn cơ bản",
  ...
  // classId không gửi
}
```

Lưu lại 3 `{assignmentId}`.

### 9.2 Lọc danh sách & kiểm tra dữ liệu

| Test | URL | Expected |
|------|-----|----------|
| Tất cả của lớp | `GET /api/v1/assignments?classId={classId}&page=0&size=20` | `total >= 2` (2 bài graded), sorted `createdAt desc` |
| Lọc theo search title | `GET /api/v1/assignments?classId={classId}&search=Quản lý sách&page=0&size=20` | Chỉ bài Lab 01 (case-insensitive contains, title hoặc topic) |
| Lọc theo topic | `GET /api/v1/assignments?classId={classId}&topic=Truy vấn cơ bản&page=0&size=20` | Chỉ bài practice |
| Lọc theo purpose | `GET /api/v1/assignments?classId={classId}&purpose=GRADED&page=0&size=20` | Chỉ 2 bài graded |
| Không kết quả | `GET /api/v1/assignments?classId={classId}&search=KhongTonTai&page=0&size=20` | `result = []`, `total = 0` |
| Trang vượt quá | `GET /api/v1/assignments?classId={classId}&page=999&size=20` | `result = []`, `total` vẫn đúng |

**Lưu ý:** `search` ở `/api/v1/assignments` là plain text (title hoặc topic, case-insensitive contains), **không** phải grammar `field:value` như `/api/v1/classes`.

---

## 10. Phase 6 — Ma trận cover tất cả assertion type & config case

Tạo thêm 1 assignment riêng để chạy ma trận này. Mỗi case là 1 step hoặc 1 plan nhỏ.

| # | Case | Config step (một phần) | Expected |
|---|------|----------------------|----------|
| 1 | HTTP POST + status 201 | `method: POST, path: /books, expected_status: 201, assertions: [{kind:status, equals:201}]` | PASSED nếu app trả 201 |
| 2 | HTTP GET + status 200 | `method: GET, path: /books/${id}, expected_status: 200` | PASSED |
| 3 | HTTP PATCH + status 200 | `method: PATCH, path: /books/${id}, expected_status: 200` | PASSED |
| 4 | HTTP DELETE + status 204 | `method: DELETE, path: /books/${id}, expected_status: 204` | PASSED |
| 5 | HTTP GET + 404 | `method: GET, path: /books/unknown, expected_status: 404` | PASSED |
| 6 | Assertion contains | `assertions: [{kind:contains, text:"Dế Mèn"}]` | PASSED nếu body có chuỗi (case-sensitive) |
| 7 | Assertion json_path exists=true | `assertions: [{kind:json_path, path:$.id, exists:true}]` | PASSED nếu trường id tồn tại |
| 8 | Assertion json_path exists=false | `assertions: [{kind:json_path, path:$.error, exists:false}]` | PASSED nếu body KHÔNG có trường error |
| 9 | Assertion body_equals | `assertions: [{kind:body_equals, json:{id:"abc", title:"Sách A"}}]` | PASSED nếu body khớp chính xác (bất kể thứ tự field) |
| 10 | Assertion body_structure | `assertions: [{kind:body_structure, json:{id:"", title:""}}]` | PASSED nếu body có key id, title (giá trị bị bỏ qua) |
| 11 | Assertion field_equals với biến | `assertions: [{kind:field_equals, path:$.id, equals:"${bookId}"}]` | PASSED nếu id trả về bằng biến đã extract |
| 12 | Extract biến | `extract: [{name:bookId, from:response_body, expression:$.id}]` | Bước sau có thể dùng `${bookId}` |
| 13 | required=true, step fail | `required: true` + step bị fail | Step sau = SKIPPED, plan dừng |
| 14 | required=false, step fail | `required: false` + step bị fail | Step sau vẫn chạy |
| 15 | timeoutMs quá thấp | `timeoutMs: 1` + app chậm | ERROR |
| 16 | DB_SCHEMA_CHECK | `stepType: DB_SCHEMA_CHECK, checks: [{kind:TABLE_EXISTS, table_name:books}]` | PASSED nếu bảng tồn tại |
| 17 | DB_QUERY | `stepType: DB_QUERY, query: SELECT ..., expected: {row_count:1}` | PASSED nếu query trả đúng |

**Negative cases (phải nhận 400 khi tạo step):**
- `method: TELEPORT` → 400 (phương thức không hợp lệ)
- `path: books` (thiếu `/` đầu) → 400
- `expected_status: 999` hoặc `600` → 400 (phạm vi 100–599)
- `kind: STATUS` (viết hoa) → 400 (validator yêu cầu chữ thường)
- `connection.db_type: oracle` → 400 (engine không hỗ trợ, chỉ postgres/mysql/mariadb)
- `stepType: DB_MIGRATION` với `statements: []` → 400
- `EXTRACT` step thiếu `value` và thiếu `from`+`expression` → 400

---

## 11. Phase 7 — Xem kết quả chấm bài giảng viên (UC-06)

Sau khi sinh viên nộp bài (hoặc grading chạy xong), giảng viên xem kết quả toàn lớp.

### 11.1 Xem kết quả toàn lớp

**API:** `GET /api/v1/assignments/{assignmentId}/results?studentCode=&includeSteps=false`

**Headers:** `X-User-Id`, `X-User-Roles: LECTURER`, `X-Gateway-Secret`

**Expected:** `200`, mảng:
```json
[
  {
    "studentUserId": "...",
    "studentCode": "S001",
    "studentName": "Nguyen Van A",
    "exerciseScore": 8.5,
    "results": [
      {
        "planId": "...",
        "planWeight": 10,
        "score": 8.5,
        "maxScore": 10,
        "status": "DONE",
        "summaryLog": null,
        "latest": true,
        "startedAt": "...",
        "completedAt": "...",
        "steps": []
      }
    ]
  }
]
```

**Negative:**
- Không sở hữu assignment → `404`
- Không phải LECTURER → `403`
- Thiếu `X-Gateway-Secret` → `401`

### 11.2 Xem kết quả một sinh viên (có steps chi tiết)

**API:** `GET /api/v1/assignments/{assignmentId}/results?studentCode=S001&includeSteps=true`

**Expected:** `200`, chỉ dòng của S001, có kèm `steps[]` chi tiết.

### 11.3 Xem danh sách nộp bài

**API:** `GET /api/v1/assignments/{assignmentId}/submissions`

**Expected:** `200`, tất cả submissions của assignment.

---

## 12. Phase 8 — Nhập điểm thủ công & bảng điểm (UC-01)

### 12.1 Nhập điểm một sinh viên

**API:** `PUT /api/v1/classes/{classId}/students/{studentCode}/scores`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:**
```json
[
  { "componentType": "ATTENDANCE", "score": 8.5 },
  { "componentType": "EXERCISE",   "score": 7.0 },
  { "componentType": "FINAL_EXAM", "score": 6.5 }
]
```

**Expected:** `200 OK`.

**Negative:**
- `EXERCISE` không cho nhập thủ công (auto-graded only) → `400`
- Score ngoài 0–10 → `400` validation
- Student code không có trong roster → `404 "Student '<code>' not found in class <classId>"`

---

### 12.2 Xem điểm một sinh viên

**API:** `GET /api/v1/classes/{classId}/students/{studentCode}/scores`

**Expected:** `200`, có `entries` per component, `total`, `letterGrade`, `gpa`.

**Quy tắc PTIT:** A+ ≥9.0, A ≥8.5, B+ ≥8.0, B ≥7.0, C+ ≥6.5, C ≥5.5, D+ ≥5.0, D ≥4.0, F <4.0.

---

### 12.3 Bảng điểm toàn lớp

**API:** `GET /api/v1/classes/{classId}/transcript`

**Expected:** `200`, một dòng mỗi sinh viên với code, name, per-component entries, total, letterGrade, gpa.

---

## 13. Công thức tính điểm chấm bài (tham khảo lecturer)

```
Score = (passedWeight / ranWeight) × 10.00
```

- `passedWeight`: tổng weight các bước PASSED
- `ranWeight`: tổng weight PASSED + FAILED (SKIPPED không tính)
- Làm tròn HALF_UP, 2 số lẻ
- Ví dụ: 3 bước, 2 pass 1 fail → (2/3)×10 = 6.67

---

## 14. Lịch trình thực hiện (khi chuyển sang agent build)

| Bucket | Hành động | Ghi chú |
|--------|-----------|---------|
| T0 | Lấy Keycloak token từ bạn (user/pass lecturer) | Bạn cung cấp |
| T1 | Tạo lớp, import CSV, cấu hình score components | Cần file CSV từ bạn |
| T2 | Tạo graded assignment + plan + 8 step (cover hết assertion/DB) | |
| T3 | Tạo practice assignment | |
| T4 | Kịch bản khó: tạo 3 assignment, lọc danh sách | |
| T5 | Ma trận assertion riêng biệt (17 case) | |
| T6 | Publish tất cả assignment | |
| T7 | Xem kết quả chấm bài (nếu có submission) | Cần sinh viên nộp bài hoặc mock |
| T8 | Nhập điểm thủ công + xem transcript | |

---

## 15. Danh sách kiểm tra hoàn tất (Definition of Done)

- [ ] Tạo lớp thành công, có `classId`.
- [ ] Import CSV thành công, `imported > 0`.
- [ ] Cấu hình score components thành công (ATTENDANCE/EXERCISE/FINAL_EXAM).
- [ ] Tạo graded assignment, có `assignmentId`.
- [ ] Tạo plan, có `planId`.
- [ ] Tạo 8 step, cover tất cả assertion type (status, contains, json_path, body_equals, body_structure, field_equals), HTTP method (POST/GET/PATCH/DELETE), DB_SCHEMA_CHECK, DB_QUERY, extract biến giữa step.
- [ ] Tạo practice assignment (purpose=PRACTICE, không classId).
- [ ] Tạo 3 assignment khác nhau, lọc danh sách theo classId/search/topic/purpose đúng dữ liệu.
- [ ] Publish assignment.
- [ ] Xem kết quả chấm bài giảng viên (results + submissions).
- [ ] Nhập điểm thủ công, xem transcript.
- [ ] Negative cases: 404 unowned, 403 non-lecturer, 400 validation.

---

## 17. Phase 17 — Tạo 10 bài tập đa dạng (Graded + Practice) cho lecturer

Mục tiêu: Tạo 10 bài tập với tên gọi và loại hình đa dạng, đủ loại hình (GRADED + PRACTICE), bao gồm đầy đủ request body JSON, test plan, test steps, và lệnh verify qua API Gateway.

Tất cả gọi qua **API Gateway**: `https://web-dev1-api.vucongtuanduong.dpdns.org/`

Header chuẩn mọi request: `Authorization: Bearer <access_token>`, `X-User-Id: <lecturer-uuid>`, `X-Gateway-Secret: <secret>`.

### 17.1 Summary of 10 assignments

| # | Title | Type | Topic | Class | Short description |
|---|-------|------|-------|-------|-------------------|
| 1 | Book Management REST API | GRADED | Web Programming | Yes | Book CRUD: POST/GET/PATCH/DELETE |
| 2 | Student Management | GRADED | Information Systems | Yes | Student CRUD, unique code check |
| 3 | Order Management | GRADED | E-commerce | Yes | Create orders, update order status |
| 4 | Library Management | GRADED | Library System | Yes | Borrow/return books, check due date |
| 5 | Grading System | GRADED | Teaching | Yes | Enter grades, calculate average, classify |
| 6 | Warehouse Management | GRADED | Logistics | Yes | Warehouse in/out, check stock |
| 7 | Basic SQL Practice | PRACTICE | Databases | No | SELECT, WHERE, simple JOIN |
| 8 | REST API Practice | PRACTICE | Web Programming | No | GET list, GET by ID |
| 9 | Java OOP Practice | PRACTICE | OOP | No | Create class, inheritance, polymorphism |
| 10 | Asset Management | GRADED | Assets | Yes | Add/edit/delete assets, check depreciation |

**Rules:**
- `GRADED` → requires `classId`, counts toward EXERCISE component
- `PRACTICE` → **do not send `classId`** (null), self-graded, no class score
- `topic` required for every assignment
- `title` must be unique per lecturer

---

### 17.2 Bài tập 1 — Quản lý sách REST API (GRADED)

**API:** `POST /api/v1/assignments`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:**
```json
{
  "title": "Quản lý sách REST API",
  "description": "Xây dựng REST API quản lý sách với chức năng tạo, đọc, cập nhật, xóa sách",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Lập trình web",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```
**Expected:** `201 Created`, `data.id` = `{assignmentId_1}`, `published: false`.

**Tạo plan:**
```json
{
  "name": "CRUD Sách — Full",
  "description": "Kiểm tra toàn bộ vòng đời sách",
  "sequenceOrder": 1,
  "weight": 10
}
```
**Expected:** `201 Created`, `data.id` = `{planId_1}`.

**Steps (6 bước):**

**Step 1 — POST tạo sách (extract bookId):**
```json
{
  "stepOrder": 1,
  "name": "Tạo sách mới",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/books",
    "headers": { "Content-Type": "application/json" },
    "body": { "title": "Dế Mèn Phiêu Lưu Ký", "author": "Tô Hoài", "year": 1941 },
    "expected_status": 201,
    "assertions": [
      { "kind": "status", "equals": 201 },
      { "kind": "json_path", "path": "$.id", "exists": true },
      { "kind": "contains", "text": "Dế Mèn" }
    ],
    "extract": [
      { "name": "bookId", "from": "response_body", "expression": "$.id" }
    ],
    "required": true,
    "timeoutMs": 5000
  },
  "weight": 1
}
```

**Step 2 — GET sách theo ID:**
```json
{
  "stepOrder": 2,
  "name": "Lấy sách theo ID",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/books/${bookId}",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "body_structure", "json": { "id": "", "title": "", "author": "", "year": "" } },
      { "kind": "field_equals", "path": "$.id", "equals": "${bookId}" }
    ]
  },
  "weight": 1
}
```

**Step 3 — GET danh sách sách:**
```json
{
  "stepOrder": 3,
  "name": "Lấy danh sách sách",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/books",
    "query_params": { "title": "Dế Mèn" },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "json_path", "path": "$", "exists": true },
      { "kind": "contains", "text": "Dế Mèn" }
    ]
  },
  "weight": 1
}
```

**Step 4 — PATCH cập nhật sách:**
```json
{
  "stepOrder": 4,
  "name": "Cập nhật sách",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "PATCH",
    "path": "/api/v1/books/${bookId}",
    "headers": { "Content-Type": "application/json" },
    "body": { "title": "Dế Mèn Phiêu Lưu Ký - Bản sửa" },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "Bản sửa" }
    ]
  },
  "weight": 1
}
```

**Step 5 — DELETE sách:**
```json
{
  "stepOrder": 5,
  "name": "Xóa sách",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "DELETE",
    "path": "/api/v1/books/${bookId}",
    "expected_status": 204,
    "assertions": [
      { "kind": "status", "equals": 204 }
    ],
    "required": true,
    "timeoutMs": 5000
  },
  "weight": 1
}
```

**Step 6 — GET kiểm tra đã xóa (404):**
```json
{
  "stepOrder": 6,
  "name": "Kiểm tra sách đã xóa",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/books/${bookId}",
    "expected_status": 404,
    "assertions": [
      { "kind": "status", "equals": 404 }
    ]
  },
  "weight": 1
}
```

**Publish:**
```bash
POST /api/v1/assignments/{assignmentId_1}/publish
```
Expected: `200 OK`.

---

### 17.3 Bài tập 2 — Quản lý sinh viên (GRADED)

**API:** `POST /api/v1/assignments`

**Body:**
```json
{
  "title": "Quản lý sinh viên",
  "description": "CRUD quản lý sinh viên với kiểm tra mã sinh viên unique",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Hệ thống thông tin",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8081,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 512,
  "maxCpu": 1.0
}
```

**Plan:** `name: "CRUD Sinh viên — Cơ bản"`, `sequenceOrder: 1`, `weight: 8`

**Steps (6 bước):**

**Step 1 — POST tạo sinh viên (extract studentId):**
```json
{
  "stepOrder": 1,
  "name": "Tạo sinh viên mới",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/students",
    "headers": { "Content-Type": "application/json" },
    "body": { "studentCode": "S001", "fullName": "Nguyen Van A", "email": "sv001@ptit.edu.vn" },
    "expected_status": 201,
    "assertions": [
      { "kind": "status", "equals": 201 },
      { "kind": "json_path", "path": "$.id", "exists": true },
      { "kind": "contains", "text": "S001" }
    ],
    "extract": [
      { "name": "studentId", "from": "response_body", "expression": "$.id" }
    ],
    "required": true
  },
  "weight": 1
}
```

**Step 2 — GET sinh viên theo ID:**
```json
{
  "stepOrder": 2,
  "name": "Lấy sinh viên theo ID",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/students/${studentId}",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "body_structure", "json": { "id": "", "studentCode": "", "fullName": "", "email": "" } },
      { "kind": "field_equals", "path": "$.studentCode", "equals": "S001" }
    ]
  },
  "weight": 1
}
```

**Step 3 — GET danh sách sinh viên:**
```json
{
  "stepOrder": 3,
  "name": "Lấy danh sách sinh viên",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/students",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "S001" }
    ]
  },
  "weight": 1
}
```

**Step 4 — PUT cập nhật sinh viên:**
```json
{
  "stepOrder": 4,
  "name": "Cập nhật thông tin sinh viên",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "PUT",
    "path": "/api/v1/students/${studentId}",
    "headers": { "Content-Type": "application/json" },
    "body": { "fullName": "Nguyen Van A Updated", "email": "sv001.new@ptit.edu.vn" },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "Updated" }
    ]
  },
  "weight": 1
}
```

**Step 5 — DELETE sinh viên:**
```json
{
  "stepOrder": 5,
  "name": "Xóa sinh viên",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "DELETE",
    "path": "/api/v1/students/${studentId}",
    "expected_status": 204,
    "assertions": [
      { "kind": "status", "equals": 204 }
    ],
    "required": true
  },
  "weight": 1
}
```

**Step 6 — GET kiểm tra đã xóa (404):**
```json
{
  "stepOrder": 6,
  "name": "Kiểm tra sinh viên đã xóa",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/students/${studentId}",
    "expected_status": 404,
    "assertions": [
      { "kind": "status", "equals": 404 }
    ]
  },
  "weight": 1
}
```

**Publish:**
```bash
POST /api/v1/assignments/{assignmentId_2}/publish
```
Expected: `200 OK`.

---

### 17.4 Bài tập 3 — Quản lý đơn hàng (GRADED)

**API:** `POST /api/v1/assignments`

**Body:**
```json
{
  "title": "Quản lý đơn hàng",
  "description": "Hệ thống quản lý đơn hàng thương mại điện tử",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Thương mại điện tử",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8082,
  "startupTimeoutMs": 90000,
  "executionTimeoutMs": 400000,
  "maxMemoryMb": 512,
  "maxCpu": 1.0
}
```

**Plan:** `name: "Đơn hàng — Quy trình"`, `sequenceOrder: 1`, `weight: 12`

**Steps (5 bước):**

**Step 1 — POST tạo đơn hàng (extract orderId):**
```json
{
  "stepOrder": 1,
  "name": "Tạo đơn hàng mới",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/orders",
    "headers": { "Content-Type": "application/json" },
    "body": { "customerName": "Tran Thi B", "items": ["Sach A", "Sach B"], "total": 250000 },
    "expected_status": 201,
    "assertions": [
      { "kind": "status", "equals": 201 },
      { "kind": "json_path", "path": "$.id", "exists": true },
      { "kind": "json_path", "path": "$.status", "exists": true }
    ],
    "extract": [
      { "name": "orderId", "from": "response_body", "expression": "$.id" }
    ],
    "required": true
  },
  "weight": 1
}
```

**Step 2 — GET đơn hàng theo ID:**
```json
{
  "stepOrder": 2,
  "name": "Lấy đơn hàng theo ID",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/orders/${orderId}",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "body_structure", "json": { "id": "", "customerName": "", "items": [], "total": 0, "status": "" } },
      { "kind": "field_equals", "path": "$.status", "equals": "PENDING" }
    ]
  },
  "weight": 1
}
```

**Step 3 — PATCH cập nhật trạng thái đơn hàng:**
```json
{
  "stepOrder": 3,
  "name": "Cập nhật trạng thái đơn hàng",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "PATCH",
    "path": "/api/v1/orders/${orderId}",
    "headers": { "Content-Type": "application/json" },
    "body": { "status": "SHIPPED" },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "SHIPPED" }
    ]
  },
  "weight": 1
}
```

**Step 4 — DELETE đơn hàng:**
```json
{
  "stepOrder": 4,
  "name": "Xóa đơn hàng",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "DELETE",
    "path": "/api/v1/orders/${orderId}",
    "expected_status": 204,
    "assertions": [
      { "kind": "status", "equals": 204 }
    ],
    "required": true
  },
  "weight": 1
}
```

**Step 5 — GET kiểm tra đã xóa (404):**
```json
{
  "stepOrder": 5,
  "name": "Kiểm tra đơn hàng đã xóa",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/orders/${orderId}",
    "expected_status": 404,
    "assertions": [
      { "kind": "status", "equals": 404 }
    ]
  },
  "weight": 1
}
```

**Publish:**
```bash
POST /api/v1/assignments/{assignmentId_3}/publish
```
Expected: `200 OK`.

---

### 17.5 Bài tập 4 — Quản lý thư viện (GRADED)

**API:** `POST /api/v1/assignments`

**Body:**
```json
{
  "title": "Quản lý thư viện",
  "description": "Hệ thống mượn/trả sách trong thư viện",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Hệ thống thư viện",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8083,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```

**Plan:** `name: "Thư viện — Mượn trả"`, `sequenceOrder: 1`, `weight: 10`

**Steps (5 bước):**

**Step 1 — POST tạo sách thư viện (extract libBookId):**
```json
{
  "stepOrder": 1,
  "name": "Thêm sách vào thư viện",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/library/books",
    "headers": { "Content-Type": "application/json" },
    "body": { "title": "Lập trình Python", "isbn": "978-1234567890", "available": true },
    "expected_status": 201,
    "assertions": [
      { "kind": "status", "equals": 201 },
      { "kind": "json_path", "path": "$.id", "exists": true }
    ],
    "extract": [
      { "name": "libBookId", "from": "response_body", "expression": "$.id" }
    ],
    "required": true
  },
  "weight": 1
}
```

**Step 2 — GET sách theo ID:**
```json
{
  "stepOrder": 2,
  "name": "Lấy thông tin sách",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/library/books/${libBookId}",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "Lập trình Python" }
    ]
  },
  "weight": 1
}
```

**Step 3 — PATCH cập nhật trạng thái mượn:**
```json
{
  "stepOrder": 3,
  "name": "Cập nhật trạng thái mượn",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "PATCH",
    "path": "/api/v1/library/books/${libBookId}",
    "headers": { "Content-Type": "application/json" },
    "body": { "available": false },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "false" }
    ]
  },
  "weight": 1
}
```

**Step 4 — DELETE sách:**
```json
{
  "stepOrder": 4,
  "name": "Xóa sách khỏi thư viện",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "DELETE",
    "path": "/api/v1/library/books/${libBookId}",
    "expected_status": 204,
    "assertions": [
      { "kind": "status", "equals": 204 }
    ],
    "required": true
  },
  "weight": 1
}
```

**Step 5 — GET kiểm tra đã xóa (404):**
```json
{
  "stepOrder": 5,
  "name": "Kiểm tra sách đã xóa",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/library/books/${libBookId}",
    "expected_status": 404,
    "assertions": [
      { "kind": "status", "equals": 404 }
    ]
  },
  "weight": 1
}
```

**Publish:**
```bash
POST /api/v1/assignments/{assignmentId_4}/publish
```
Expected: `200 OK`.

---

### 17.6 Bài tập 5 — Hệ thống chấm điểm (GRADED)

**API:** `POST /api/v1/assignments`

**Body:**
```json
{
  "title": "Hệ thống chấm điểm",
  "description": "Nhập điểm, tính trung bình, xếp loại học lực",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Giảng dạy",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8084,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```

**Plan:** `name: "Chấm điểm — Nhập và xử lý"`, `sequenceOrder: 1`, `weight: 10`

**Steps (6 bước):**

**Step 1 — POST nhập điểm (extract scoreId):**
```json
{
  "stepOrder": 1,
  "name": "Nhập điểm sinh viên",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/scores",
    "headers": { "Content-Type": "application/json" },
    "body": { "studentCode": "S001", "subject": "Toán", "score": 8.5 },
    "expected_status": 201,
    "assertions": [
      { "kind": "status", "equals": 201 },
      { "kind": "json_path", "path": "$.id", "exists": true },
      { "kind": "contains", "text": "8.5" }
    ],
    "extract": [
      { "name": "scoreId", "from": "response_body", "expression": "$.id" }
    ],
    "required": true
  },
  "weight": 1
}
```

**Step 2 — GET điểm theo ID:**
```json
{
  "stepOrder": 2,
  "name": "Lấy điểm theo ID",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/scores/${scoreId}",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "field_equals", "path": "$.score", "equals": "8.5" }
    ]
  },
  "weight": 1
}
```

**Step 3 — GET danh sách điểm:**
```json
{
  "stepOrder": 3,
  "name": "Lấy danh sách điểm",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/scores",
    "query_params": { "studentCode": "S001" },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "S001" }
    ]
  },
  "weight": 1
}
```

**Step 4 — PATCH cập nhật điểm:**
```json
{
  "stepOrder": 4,
  "name": "Cập nhật điểm",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "PATCH",
    "path": "/api/v1/scores/${scoreId}",
    "headers": { "Content-Type": "application/json" },
    "body": { "score": 9.0 },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "9.0" }
    ]
  },
  "weight": 1
}
```

**Step 5 — DELETE điểm:**
```json
{
  "stepOrder": 5,
  "name": "Xóa điểm",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "DELETE",
    "path": "/api/v1/scores/${scoreId}",
    "expected_status": 204,
    "assertions": [
      { "kind": "status", "equals": 204 }
    ],
    "required": true
  },
  "weight": 1
}
```

**Step 6 — GET kiểm tra đã xóa (404):**
```json
{
  "stepOrder": 6,
  "name": "Kiểm tra điểm đã xóa",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/scores/${scoreId}",
    "expected_status": 404,
    "assertions": [
      { "kind": "status", "equals": 404 }
    ]
  },
  "weight": 1
}
```

**Publish:**
```bash
POST /api/v1/assignments/{assignmentId_5}/publish
```
Expected: `200 OK`.

---

### 17.7 Bài tập 6 — Quản lý kho hàng (GRADED)

**API:** `POST /api/v1/assignments`

**Body:**
```json
{
  "title": "Quản lý kho hàng",
  "description": "Nhập kho, xuất kho, kiểm tra tồn kho",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Logistics",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8085,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```

**Plan:** `name: "Kho hàng — Nhập/Xuất"`, `sequenceOrder: 1`, `weight: 10`

**Steps (5 bước):**

**Step 1 — POST nhập kho (extract inboundId):**
```json
{
  "stepOrder": 1,
  "name": "Nhập kho",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/inventory/inbound",
    "headers": { "Content-Type": "application/json" },
    "body": { "product": "Máy tính", "quantity": 10, "unitPrice": 15000000 },
    "expected_status": 201,
    "assertions": [
      { "kind": "status", "equals": 201 },
      { "kind": "json_path", "path": "$.id", "exists": true }
    ],
    "extract": [
      { "name": "inboundId", "from": "response_body", "expression": "$.id" }
    ],
    "required": true
  },
  "weight": 1
}
```

**Step 2 — POST xuất kho (extract outboundId):**
```json
{
  "stepOrder": 2,
  "name": "Xuất kho",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/inventory/outbound",
    "headers": { "Content-Type": "application/json" },
    "body": { "product": "Máy tính", "quantity": 2 },
    "expected_status": 201,
    "assertions": [
      { "kind": "status", "equals": 201 },
      { "kind": "json_path", "path": "$.id", "exists": true }
    ],
    "extract": [
      { "name": "outboundId", "from": "response_body", "expression": "$.id" }
    ]
  },
  "weight": 1
}
```

**Step 3 — GET kiểm tra tồn kho:**
```json
{
  "stepOrder": 3,
  "name": "Kiểm tra tồn kho",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/inventory/stock/Máy%20tính",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "8" }
    ]
  },
  "weight": 1
}
```

**Step 4 — GET chi tiết phiếu nhập:**
```json
{
  "stepOrder": 4,
  "name": "Lấy chi tiết phiếu nhập",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/inventory/inbound/${inboundId}",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "field_equals", "path": "$.product", "equals": "Máy tính" }
    ]
  },
  "weight": 1
}
```

**Step 5 — DELETE phiếu xuất:**
```json
{
  "stepOrder": 5,
  "name": "Xóa phiếu xuất",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "DELETE",
    "path": "/api/v1/inventory/outbound/${outboundId}",
    "expected_status": 204,
    "assertions": [
      { "kind": "status", "equals": 204 }
    ],
    "required": true
  },
  "weight": 1
}
```

**Publish:**
```bash
POST /api/v1/assignments/{assignmentId_6}/publish
```
Expected: `200 OK`.

---

### 17.8 Bài tập 7 — Luyện tập SQL cơ bản (PRACTICE, không classId)

**API:** `POST /api/v1/assignments`

**Body:**
```json
{
  "title": "Luyện tập SQL cơ bản",
  "description": "Bài tập luyện tập truy vấn SQL cơ bản: SELECT, WHERE, ORDER BY, JOIN đơn giản",
  "purpose": "PRACTICE",
  "topic": "Cơ sở dữ liệu",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```

**Plan:** `name: "SQL — SELECT & WHERE"`, `sequenceOrder: 1`, `weight: 10`

**Steps (3 bước):**

**Step 1 — DB_SCHEMA_CHECK kiểm tra bảng:**
```json
{
  "stepOrder": 1,
  "name": "Kiểm tra bảng cơ sở dữ liệu",
  "stepType": "DB_SCHEMA_CHECK",
  "config": {
    "connection": {
      "db_type": "postgres",
      "database": "practice_db",
      "username": "postgres",
      "password": "postgres"
    },
    "checks": [
      { "kind": "TABLE_EXISTS", "table_name": "students" },
      { "kind": "COLUMN_EXISTS", "table_name": "students", "column_name": "name" },
      { "kind": "PRIMARY_KEY", "table_name": "students", "column": "id" }
    ],
    "timeoutMs": 30000
  },
  "weight": 1
}
```

**Step 2 — DB_QUERY kiểm tra dữ liệu:**
```json
{
  "stepOrder": 2,
  "name": "Truy vấn dữ liệu sinh viên",
  "stepType": "DB_QUERY",
  "config": {
    "connection": {
      "db_type": "postgres",
      "database": "practice_db",
      "username": "postgres",
      "password": "postgres"
    },
    "query": "SELECT COUNT(*) FROM students WHERE status = 'active'",
    "expected": { "row_count": 1, "columns": ["count"] },
    "timeoutMs": 30000
  },
  "expectedResult": { "row_count": 1 },
  "weight": 1
}
```

**Step 3 — HTTP GET kiểm tra API practice:**
```json
{
  "stepOrder": 3,
  "name": "Kiểm tra API practice",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/practice/students",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "student" }
    ]
  },
  "weight": 1
}
```

**Publish:**
```bash
POST /api/v1/assignments/{assignmentId_7}/publish
```
Expected: `200 OK`.

---

### 17.9 Bài tập 8 — Luyện tập REST API (PRACTICE, không classId)

**API:** `POST /api/v1/assignments`

**Body:**
```json
{
  "title": "Luyện tập REST API",
  "description": "Bài tập luyện tập phương thức GET lấy danh sách, lấy theo ID",
  "purpose": "PRACTICE",
  "topic": "Lập trình web",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8081,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```

**Plan:** `name: "REST — GET danh sách và chi tiết"`, `sequenceOrder: 1`, `weight: 8`

**Steps (3 bước):**

**Step 1 — GET danh sách sản phẩm:**
```json
{
  "stepOrder": 1,
  "name": "Lấy danh sách sản phẩm",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/practice/products",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "json_path", "path": "$", "exists": true },
      { "kind": "contains", "text": "product" }
    ]
  },
  "weight": 1
}
```

**Step 2 — GET sản phẩm theo ID:**
```json
{
  "stepOrder": 2,
  "name": "Lấy sản phẩm theo ID",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/practice/products/1",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "body_structure", "json": { "id": "", "name": "", "price": 0 } }
    ]
  },
  "weight": 1
}
```

**Step 3 — GET sản phẩm không tồn tại (404):**
```json
{
  "stepOrder": 3,
  "name": "Kiểm tra sản phẩm không tồn tại",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/practice/products/999999",
    "expected_status": 404,
    "assertions": [
      { "kind": "status", "equals": 404 }
    ]
  },
  "weight": 1
}
```

**Publish:**
```bash
POST /api/v1/assignments/{assignmentId_8}/publish
```
Expected: `200 OK`.

---

### 17.10 Bài tập 9 — Luyện tập Java OOP (PRACTICE, không classId)

**API:** `POST /api/v1/assignments`

**Body:**
```json
{
  "title": "Luyện tập Java OOP",
  "description": "Bài tập luyện tập hướng đối tượng: tạo class, kế thừa, đa hình",
  "purpose": "PRACTICE",
  "topic": "Hướng đối tượng",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8082,
  "startupTimeoutMs": 90000,
  "executionTimeoutMs": 400000,
  "maxMemoryMb": 512,
  "maxCpu": 1.0
}
```

**Plan:** `name: "Java OOP — Class & Inheritance"`, `sequenceOrder: 1`, `weight: 10`

**Steps (3 bước):**

**Step 1 — POST nộp mã nguồn Java (extract javaSubmissionId):**
```json
{
  "stepOrder": 1,
  "name": "Nộp mã nguồn Java",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/practice/java/submit",
    "headers": { "Content-Type": "application/json" },
    "body": { "className": "Animal", "code": "class Animal { void makeSound() {} }" },
    "expected_status": 201,
    "assertions": [
      { "kind": "status", "equals": 201 },
      { "kind": "json_path", "path": "$.submissionId", "exists": true }
    ],
    "extract": [
      { "name": "javaSubmissionId", "from": "response_body", "expression": "$.submissionId" }
    ],
    "required": true
  },
  "weight": 1
}
```

**Step 2 — GET kiểm tra kết quả nộp:**
```json
{
  "stepOrder": 2,
  "name": "Kiểm tra kết quả nộp Java",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/practice/java/result/${javaSubmissionId}",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "compiled" }
    ]
  },
  "weight": 1
}
```

**Step 3 — GET danh sách nộp bài:**
```json
{
  "stepOrder": 3,
  "name": "Lấy danh sách nộp bài Java",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/practice/java/submissions",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "Animal" }
    ]
  },
  "weight": 1
}
```

**Publish:**
```bash
POST /api/v1/assignments/{assignmentId_9}/publish
```
Expected: `200 OK`.

---

### 17.11 Bài tập 10 — Quản lý tài sản (GRADED)

**API:** `POST /api/v1/assignments`

**Body:**
```json
{
  "title": "Quản lý tài sản",
  "description": "Thêm/sửa/xóa tài sản, kiểm tra giảm hao",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Tài sản",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8086,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```

**Plan:** `name: "Tài sản — Quản lý"`, `sequenceOrder: 1`, `weight: 10`

**Steps (5 bước):**

**Step 1 — POST tạo tài sản (extract assetId):**
```json
{
  "stepOrder": 1,
  "name": "Thêm tài sản mới",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/assets",
    "headers": { "Content-Type": "application/json" },
    "body": { "name": "Máy chủ Dell", "category": "Thiết bị", "purchaseDate": "2024-01-15", "originalValue": 50000000 },
    "expected_status": 201,
    "assertions": [
      { "kind": "status", "equals": 201 },
      { "kind": "json_path", "path": "$.id", "exists": true },
      { "kind": "contains", "text": "Máy chủ Dell" }
    ],
    "extract": [
      { "name": "assetId", "from": "response_body", "expression": "$.id" }
    ],
    "required": true
  },
  "weight": 1
}
```

**Step 2 — GET tài sản theo ID:**
```json
{
  "stepOrder": 2,
  "name": "Lấy tài sản theo ID",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/assets/${assetId}",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "body_structure", "json": { "id": "", "name": "", "category": "", "purchaseDate": "", "originalValue": 0 } }
    ]
  },
  "weight": 1
}
```

**Step 3 — PATCH cập nhật giá trị tài sản:**
```json
{
  "stepOrder": 3,
  "name": "Cập nhật giá trị tài sản",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "PATCH",
    "path": "/api/v1/assets/${assetId}",
    "headers": { "Content-Type": "application/json" },
    "body": { "currentValue": 40000000 },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "40000000" }
    ]
  },
  "weight": 1
}
```

**Step 4 — DELETE tài sản:**
```json
{
  "stepOrder": 4,
  "name": "Xóa tài sản",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "DELETE",
    "path": "/api/v1/assets/${assetId}",
    "expected_status": 204,
    "assertions": [
      { "kind": "status", "equals": 204 }
    ],
    "required": true
  },
  "weight": 1
}
```

**Step 5 — GET kiểm tra đã xóa (404):**
```json
{
  "stepOrder": 5,
  "name": "Kiểm tra tài sản đã xóa",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/assets/${assetId}",
    "expected_status": 404,
    "assertions": [
      { "kind": "status", "equals": 404 }
    ]
  },
  "weight": 1
}
```

**Publish:**
```bash
POST /api/v1/assignments/{assignmentId_10}/publish
```
Expected: `200 OK`.

---

### 17.12 Lệnh verify (GET filter danh sách)

Sau khi tạo xong 10 bài, chạy lệnh sau để kiểm tra:

```bash
# Xem tất cả bài của giảng viên
GET /api/v1/assignments?classId={classId}&page=0&size=20

# Lọc theo purpose=GRADED
GET /api/v1/assignments?classId={classId}&purpose=GRADED&page=0&size=20

# Lọc theo purpose=PRACTICE
GET /api/v1/assignments?purpose=PRACTICE&page=0&size=20

# Lọc theo search (title hoặc topic, case-insensitive)
GET /api/v1/assignments?classId={classId}&search=Quan ly&page=0&size=20

# Lọc theo topic
GET /api/v1/assignments?classId={classId}&topic=Co so du lieu&page=0&size=20

# Xem chi tiết một assignment
GET /api/v1/assignments/{assignmentId}

# Xem plan và step của một assignment
GET /api/v1/assignments/{assignmentId}/plans
```

---

### 17.13 Thứ tự thực hiện đề xuất

| Bucket | Hành động | Ghi chú |
|--------|-----------|---------|
| T0 | Get Keycloak token from lecturer (user/pass) | You provide |
| T1 | Create 1-2 classes (get classId) | Needed for GRADED assignments |
| T2 | Import CSV students into class | Need CSV file from you |
| T3 | Create 7 GRADED assignments (#1-6, 10) with classId | Create assignment → plan → steps → publish |
| T4 | Create 3 PRACTICE assignments (#7-9) without classId | Create assignment → plan → steps → publish |
| T5 | Verify list and filters | GET /api/v1/assignments with filters |

---

### 17.14 Definition of Done

- [x] Class created successfully, has `classId` — `b3782e35-7593-4497-9fa8-35a449a2d7b2`
- [x] CSV import successful, `imported > 0` — `imported=59, skipped=0`
- [x] Score components configured (ATTENDANCE/EXERCISE/FINAL_EXAM) — `PUT /score-components` → `200`
- [x] Created 7 GRADED assignments, each with `assignmentId`, `planId`, steps, published
- [x] Created 3 PRACTICE assignments, each with `assignmentId`, `planId`, steps, published
- [x] Each GRADED covers at least 1 HTTP method (POST/GET/PATCH/DELETE)
- [x] Each assignment covers at least 2 assertion types
- [x] At least 1 assignment uses extract variable between steps
- [x] At least 1 assignment uses DB step (DB_QUERY or DB_SCHEMA_CHECK) — assignment 7
- [x] All 7 GRADED (#1–6, #10) have 2 DB steps (DB_SCHEMA_CHECK + DB_QUERY) — run on student container
- [x] PRACTICE #8, #9 each have 1 DB_SCHEMA_CHECK
- [x] Verify via GET filter successful, data correct
- [ ] Negative cases: 404 unowned, 403 non-lecturer, 400 validation — not yet run

---

### 17.15 Execution results (2026-10-27)

Environment: gateway `https://web-dev1-api.vucongtuanduong.dpdns.org`, realm `ptit-wgs`,
client `wgs-postman` (password grant), lecturer `gv002` (role `ROLE_LECTURER`,
`sub = 2be57808-9203-4150-8f29-19aecbe9f725`).

**Auth note:** `web-grading-fe` has Direct Access Grants disabled → password grant returns
`unauthorized_client`. Use `wgs-postman` (or `admin-cli`). If account has pending
`UPDATE_PASSWORD` required action, password grant returns
`invalid_grant: Account is not fully set up`; call `POST /api/v1/account/change-password`
first (here returned `204` keeping the same password), then grant again.

**Class:** `b3782e35-7593-4497-9fa8-35a449a2d7b2` — `D22CQKH02-B`, semester `20261`,
`status=ACTIVE`.

**Students:** file `.opencode/plan/generate-data-api/students-import.csv` (59 data rows,
header `studentCode,studentName,email,studentUserId`), import `59`, `skipped=0`.
Verify: `GET /api/v1/classes/{classId}/students?page=0&size=100` → `total=59`.

**Assignments created (all `published=true`):**

| # | Title | Purpose | DB | Port | assignmentId | planId | Steps |
|---|-------|---------|----|------|--------------|--------|-------|
| 1 | Book Management REST API | GRADED | `books_db` | 8080 | `bab5b767-a86a-4e26-aea0-eb5add50f4a6` | `8135a33d-00e1-4669-a454-3634ffad1c78` | 8/8 (6 HTTP + 2 DB) |
| 2 | Student Management | GRADED | `students_db` | 8081 | `c4a883cc-f6a7-412a-9a8c-a3e20642543d` | `25f08002-a2fc-44a6-89b0-7d0a1bb2030c` | 8/8 (6 HTTP + 2 DB) |
| 3 | Order Management | GRADED | `orders_db` | 8082 | `bd2b9ea6-9454-4f0b-ae25-2394265ea07f` | `36e2af52-7372-4844-839a-5c1e29f70928` | 7/7 (5 HTTP + 2 DB) |
| 4 | Library Management | GRADED | `library_db` | 8083 | `155e2459-c734-4425-b926-0f84d96e7821` | `7ad3bf24-75b7-48d8-b574-4bd9fa92d1a1` | 7/7 (5 HTTP + 2 DB) |
| 5 | Grading System | GRADED | `grades_db` | 8084 | `4d127dd9-ad03-4d88-b2d1-9e39dc4d22f7` | `97b64df7-4118-4b31-8b4f-d0fea38fe06c` | 8/8 (6 HTTP + 2 DB) |
| 6 | Warehouse Management | GRADED | `inventory_db` | 8085 | `e39e0f42-c8c9-4da7-8a8d-53e357e9848a` | `c3ed9afa-c3fa-4398-a3c2-b61d469787c4` | 7/7 (5 HTTP + 2 DB) |
| 7 | Basic SQL Practice | PRACTICE | `practice_db` | 8080 | `370af4b1-249f-4295-bf70-514e7ca8cef8` | `9dbb663b-37ad-40d9-a17b-f1c46360dbfe` | 3/3 (có sẵn DB steps) |
| 8 | REST API Practice | PRACTICE | `api_practice_db` | 8081 | `ca57be8d-bde7-4217-be03-ab80465410cf` | `352e6e03-263f-4d5b-b9d1-0db0ea15dde5` | 4/4 (3 HTTP + 1 DB) |
| 9 | Java OOP Practice | PRACTICE | `oop_practice_db` | 8082 | `4fcbd0b9-132b-41bd-adde-7c35388e694d` | `0a64e4b5-0eee-40e5-a4ee-af1c5c5f1753` | 4/4 (3 HTTP + 1 DB) |
| 10 | Asset Management | GRADED | `assets_db` | 8086 | `83580461-ee6e-478a-84f6-ec1bb63e9548` | `b7631721-53bf-410a-ba38-c1fa4c784b34` | 7/7 (5 HTTP + 2 DB) |

Total: 10 assignments, 10 plans, 63 steps, 10 publishes `200`.

**Filter results (verify):**

| Filter | Expected | Actual |
|--------|----------|--------|
| `GET /api/v1/assignments` | 10 | 10 |
| `purpose=GRADED` | 7 | 7 |
| `purpose=PRACTICE` | 3 | 3 |
| `classId={classId}` | 7 | 7 |
| `published=true` | 10 | 10 |
| `topic=Logistics` | 1 | 1 |
| `GET /assignments/topics?purpose=GRADED` | 7 topics | 7 |
| `GET /assignments/topics?purpose=PRACTICE` | 3 topics | 3 |

---

### 17.16 DB steps added (2026-10-27)

Each GRADED assignment (#1–6, #10) gets 2 DB steps **after** the HTTP steps, running on
the corresponding student container:

| Step | Type | Purpose | required |
|------|------|---------|----------|
| N+1 | `DB_SCHEMA_CHECK` | Check main table and primary key exist | true |
| N+2 | `DB_QUERY` | Check data created via HTTP exists in DB | false |

DB connection config (students must follow):

| # | Assignment | DB | Port | Main table |
|---|------------|----|------|------------|
| 1 | Book Management REST API | `books_db` | 8080 | `books` |
| 2 | Student Management | `students_db` | 8081 | `students` |
| 3 | Order Management | `orders_db` | 8082 | `orders` |
| 4 | Library Management | `library_db` | 8083 | `library` |
| 5 | Grading System | `grades_db` | 8084 | `grades` |
| 6 | Warehouse Management | `inventory_db` | 8085 | `inventory` |
| 10 | Asset Management | `assets_db` | 8086 | `assets` |

PRACTICE #8, #9 each add 1 `DB_SCHEMA_CHECK` step:
- #8 REST API Practice → `api_practice_db`, port 8081
- #9 Java OOP Practice → `oop_practice_db`, port 8082

**Note:** Database names and ports are set by the lecturer for students to follow.
Student containers must expose DB on the corresponding port and create the database
with the correct name when compose up.

---

**Not yet run:** negative cases (404/403/400) and real grading (needs Docker image +
student submission). Score components configured: ATTENDANCE 0.10 / EXERCISE 0.20 / FINAL_EXAM 0.70.


---

*This section was added to lecturer-full-e2e-plan.md. Date added: 2026-10-27.*

*This document was written based on actual code in repo `web-grading-system-deploy`: `docs/design/grading-config-reference.md`, `docs/design/http-test-plan-config.md`, `docs/design/exercise-management-plan.md`, `docs/design/usecase-flows.md`, `src-services/course-service/.../controller/*.java`, `src-services/course-service/.../dto/request/*.java`. Date written: 2026-10-27.*
---

## 18. Phase 18 — Các tính năng bước phức tạp mới (data[] loop, auto_inject_headers, ANY_OF)

Mục đích: Kiểm thử 3 tính năng backend vừa hỗ trợ ở Phase 3 (xem plan `.opencode/plan/http-config-assertion-advanced/plan.md` §5):

- **`data[]` (data-driven loop)**: 1 step chạy N lần, mỗi lần gán biến từ 1 bản ghi trong mảng `data` (tạo 4 sách khác nhau trong 1 step, extract ra `bookId_0`…`bookId_3`).
- **`auto_inject_headers` cấp Plan**: khai báo trên bước login, executor tự động tiêm `Authorization: Bearer ${accessToken}` vào mọi bước HTTP_REQUEST **sau** bước đó trong cùng plan (giảng viên không gán thủ công `Authorization` mỗi bước).
- **`ANY_OF` assertion**: toán tử OR — chỉ cần 1 điều kiện con đúng là step PASS (ví dụ định dạng ngày `YYYY-MM-DD` hoặc `DD/MM/YYYY`).

Tất cả gọi qua **API Gateway**: `https://web-dev1-api.vucongtuanduong.dpdns.org/`. Header chuẩn mỗi request: `Authorization: Bearer <access_token>`, `X-User-Id: <lecturer-uuid>`, `X-Gateway-Secret: <secret>`.

### 18.1 Tạo assignment & plan cho tính năng mới

**API:** `POST /api/v1/assignments`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:**
```json
{
  "title": "Kiểm tra tính năng bước nâng cao (data[], auto_inject_headers, ANY_OF)",
  "description": "Cover data[] loop, auto_inject_headers sau login, ANY_OF assertion",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Tính năng bước nâng cao",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```

**Expected:** `201 Created`, `data.id` = `{assignmentId}` (dùng cho toàn phase này), `published: false`.

**Negative:** trùng title của giảng viên → `400`.

---

**API:** `POST /api/v1/assignments/{assignmentId}/plans`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:**
```json
{
  "name": "Plan tính năng bước nâng cao",
  "description": "Login → tạo 4 sách qua data[] → filter/search ANY_OF",
  "sequenceOrder": 1,
  "weight": 10
}
```

**Expected:** `201 Created`, `data.id` = `{planId}`.

**Negative:** trùng `sequenceOrder` trong cùng assignment → `400`.

---

### 18.2 Step 1 — Đăng nhập lấy accessToken (khai báo auto_inject_headers, KHÔNG gán Authorization thủ công)

**API:** `POST /api/v1/assignments/{assignmentId}/plans/{planId}/steps`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:**
```json
{
  "stepOrder": 1,
  "name": "Đăng nhập lấy token",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/auth/login",
    "body": { "username": "lecturer", "password": "secret" },
    "expected_status": 200,
    "auto_inject_headers": {
      "Authorization": "Bearer ${accessToken}"
    },
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "json_path", "path": "$.accessToken", "exists": true }
    ],
    "extract": [
      { "name": "accessToken", "from": "response_body", "expression": "$.accessToken" }
    ],
    "required": true,
    "timeoutMs": 5000
  },
  "expectedResult": null,
  "weight": 1
}
```

**Expected:** `201 Created` (step lưu thành công). Biến `accessToken` được lưu vào `VariableContext` per-job.

**Lưu ý triển khai:**
- Khối `auto_inject_headers` được khai báo trên bước login. Executor **không** tiêm header vào chính bước này (chỉ tiêm cho các bước SAU trong cùng plan).
- Giá trị template `Bearer ${accessToken}` được substitute lúc chạy các bước sau, khi `accessToken` đã có trong context.
- Header đã có trên bước sẽ không bị `auto_inject_headers` ghi đè.

---

### 18.3 Step 2 — Tạo 4 sách khác nhau qua data[] (không gán Authorization thủ công, phụ thuộc auto_inject_headers từ bước 1)

**API:** `POST /api/v1/assignments/{assignmentId}/plans/{planId}/steps`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:**
```json
{
  "stepOrder": 2,
  "name": "Tạo 4 sách khác nhau (data[])",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/books",
    "body": { "title": "${title}", "author": "Tô Hoài", "year": "${year}" },
    "expected_status": 201,
    "data": [
      { "title": "Sách A", "year": "1941" },
      { "title": "Sách B", "year": "1950" },
      { "title": "Sách C", "year": "1960" },
      { "title": "Dế Mèn Phiêu Lưu Ký", "year": "1941" }
    ],
    "extract": [
      { "name": "bookId_${index}", "from": "response_body", "expression": "$.id" }
    ],
    "required": true,
    "timeoutMs": 10000
  },
  "expectedResult": null,
  "weight": 1
}
```

**Expected:** `201 Created` (step lưu thành công). Lúc chạy grading:
- Step chạy 4 lần (một lần mỗi bản ghi `data`).
- Mỗi lần substitute `${title}`, `${year}`, `${index}` (0-based) vào config.
- Executor tiêm `Authorization: Bearer ${accessToken}` (từ bước 1) vào mỗi lần chạy.
- Extract `bookId_0`, `bookId_1`, `bookId_2`, `bookId_3` vào context dùng cho bước sau.

**Giới hạn an toàn (Loop Safety Governor):**
- Validator course-service chặn `data[]` inline > 10 phần tử → `400` lúc lưu step.
- Runtime executor truncate về 20 phần tử nếu mảng lớn hơn.
- Placeholder `${...}` phải nằm trong vị trí **chuỗi JSON** (ví dụ `"year": "${year}"`). Token thô không dấu ngoặc trong vị trí số không phải JSON hợp lệ.

**Negative (lưu step → 400):**
- `data[]` có 11 phần tử → `400 "data must contain at most 10 entries"`.
- `data[]` rỗng `[]` → `400 "data must be a non-empty array"`.
- Entry trong `data[]` không phải object → `400 "data entries must be objects"`.

---

### 18.4 Step 3 — Filter/search sách với ANY_OF assertion (không gán Authorization thủ công)

**API:** `POST /api/v1/assignments/{assignmentId}/plans/{planId}/steps`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:**
```json
{
  "stepOrder": 3,
  "name": "Lọc sách theo tiêu đề (ANY_OF định dạng ngày)",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/books",
    "query_params": { "title": "Dế Mèn" },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "array_length", "path": "$", "equals": 1 },
      { "kind": "contains_item", "path": "$[*].title", "equals": "Dế Mèn Phiêu Lưu Ký" },
      { "kind": "any_of", "assertions": [
        { "kind": "matches_regex", "path": "$[0].published_date", "pattern": "^\\d{4}-\\d{2}-\\d{2}$" },
        { "kind": "matches_regex", "path": "$[0].published_date", "pattern": "^\\d{2}/\\d{2}/\\d{4}$" }
      ]}
    ]
  },
  "expectedResult": null,
  "weight": 1
}
```

**Expected:** `201 Created` (step lưu thành công). Lúc chạy grading:
- Executor tiêm `Authorization: Bearer ${accessToken}` (từ bước 1).
- Assertion `ANY_OF` PASS nếu **ít nhất 1** trong 2 định dạng ngày khớp (`YYYY-MM-DD` hoặc `DD/MM/YYYY`).
- Nếu cả 2 đều sai → `ANY_OF` FAILED → step FAILED.

**Negative (lưu step → 400):**
- `any_of` thiếu trường `assertions` hoặc `assertions` rỗng → `400 "'assertions' must be a non-empty array"`.
- `auto_inject_headers` không phải object hoặc giá trị không phải string → `400`.

---

### 18.5 Verify plan & steps đã lưu đúng cấu trúc mới

**API:** `GET /api/v1/assignments/{assignmentId}/plans`

**Expected:** `200`, danh sách plans sắp xếp theo `sequenceOrder`, mỗi plan lồng `steps` theo `stepOrder`.

Kiểm tra cấu trúc đã lưu:
- Bước 1 (`Đăng nhập lấy token`): config **có** khóa `auto_inject_headers: { "Authorization": "Bearer ${accessToken}" }`, extract `accessToken`.
- Bước 2 (`Tạo 4 sách`): config **không** chứa header `Authorization` thủ công (phụ thuộc `auto_inject_headers` từ bước 1), có `data[]` 4 phần tử, extract `bookId_${index}`.
- Bước 3 (`Lọc sách`): config **không** chứa header `Authorization` thủ công, có assertion `any_of`.

**Lưu ý:** Header `Authorization` được executor tiêm vào runtime (không lưu trong config bước 2/3), do đó `GET /plans` của bước 2/3 không thấy `Authorization` — đây là hành vi đúng, chứng minh `auto_inject_headers` hoạt động ở tầng orchestrator chứ không phải lưu cứng config.

---

### 18.6 Danh sách kiểm tra hoàn tất (Definition of Done) cho Phase 18

- [ ] Tạo assignment & plan thành công, có `assignmentId`, `planId`.
- [ ] Bước login lưu thành công, có `auto_inject_headers`, extract `accessToken`.
- [ ] Bước `data[]` lưu thành công (≤ 10 entries), chạy 4 lần, extract `bookId_0`…`bookId_3`.
- [ ] Bước filter/search lưu thành công, có assertion `any_of`.
- [ ] Negative: `data[]` > 10 → 400; `data[]` rỗng → 400; `any_of` assertions rỗng → 400; `auto_inject_headers` sai dạng → 400.
- [ ] `GET /plans` xác nhận bước 2/3 không gán `Authorization` thủ công (phụ thuộc `auto_inject_headers`).

---

*Phase 18 added to lecturer-full-e2e-plan.md. Date added: 2026-10-28. Backend Phase 3 (data[] loop, auto_inject_headers, ANY_OF) đã triển khai và verify qua unit test executor-service + course-service.*

*This document was written based on actual code in repo `web-grading-system-deploy`: `docs/design/grading-config-reference.md`, `docs/design/http-test-plan-config.md`, `docs/design/exercise-management-plan.md`, `docs/design/usecase-flows.md`, `src-services/course-service/.../controller/*.java`, `src-services/course-service/.../dto/request/*.java`. Date written: 2026-10-27.*
