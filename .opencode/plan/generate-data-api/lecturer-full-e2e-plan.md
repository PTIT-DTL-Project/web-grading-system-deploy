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

---

## 18.7 Assignment mẫu A — Dùng `data[]` tạo nhiều dữ liệu khác nhau trong 1 step

Mục tiêu: Thay vì viết 4 step riêng cho 4 sách, dùng 1 step có `data[]` 4 phần tử. Mỗi phần tử sinh 1 request HTTP, extract ra `bookId_0`…`bookId_3`.

**API:** `POST /api/v1/assignments`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:**
```json
{
  "title": "Tạo nhiều sách cùng lúc (data[])",
  "description": "1 step chạy 4 lần qua data[], mỗi lần title/year khác nhau, extract bookId_index",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Vòng lặp dữ liệu",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```
**Expected:** `201 Created`, `data.id` = `{assignmentId_dataLoop}`.

**Plan:**
```json
{ "name": "Data loop — tạo 4 sách", "description": "data[] 4 phần tử, extract bookId_${index}", "sequenceOrder": 1, "weight": 10 }
```
**Expected:** `201 Created`, `data.id` = `{planId_dataLoop}`.

**Step 1 — Tạo 4 sách qua data[] (không cần 4 step riêng):**
```json
{
  "stepOrder": 1,
  "name": "Tạo 4 sách khác nhau",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/books",
    "headers": { "Content-Type": "application/json" },
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
  "weight": 1
}
```

**Lưu ý:** `${title}`, `${year}` được substitute từ từng bản ghi `data[]`; `${index}` là 0,1,2,3. Extract `bookId_0`…`bookId_3` lưu vào `VariableContext`, bước sau có thể dùng `${bookId_1}` v.v.

**Negative (lưu step → 400):** `data[]` 11 phần tử → `400 "at most 10 entries"`; `data[]` rỗng → `400 "non-empty array"`; entry không phải object → `400 "data entries must be objects"`.

---

## 18.8 Assignment mẫu B — Dùng `auto_inject_headers` cấp Plan (login 1 lần, tiêm cho mọi bước sau)

Mục tiêu: Bước login extract `accessToken`, khai báo `auto_inject_headers`; các bước sau KHÔNG cần gán `Authorization: Bearer ${token}` thủ công.

**API:** `POST /api/v1/assignments`

**Body:**
```json
{
  "title": "Tự động tiêm header auth (auto_inject_headers)",
  "description": "Login lấy token, auto_inject_headers tiêm Authorization vào bước 2,3; không gán thủ công mỗi bước",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Tự động tiêm header",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```
**Expected:** `201 Created`, `data.id` = `{assignmentId_autoInject}`.

**Plan:**
```json
{ "name": "Auto inject header", "description": "Login → tiêm Authorization cho bước sau", "sequenceOrder": 1, "weight": 10 }
```
**Expected:** `201 Created`, `data.id` = `{planId_autoInject}`.

**Step 1 — Đăng nhập (khai báo auto_inject_headers, extract accessToken):**
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
  "weight": 1
}
```

**Step 2 — GET sách (KHÔNG có header Authorization trong config, phụ thuộc auto_inject_headers từ bước 1):**
```json
{
  "stepOrder": 2,
  "name": "Lấy danh sách sách (dùng token từ bước 1)",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/books",
    "query_params": { "title": "Dế Mèn" },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "json_path", "path": "$", "exists": true }
    ]
  },
  "weight": 1
}
```

**Lưu ý triển khai:**
- Bước 1 có `auto_inject_headers` → executor tiêm `Authorization: Bearer ${accessToken}` vào bước 2 (và mọi bước sau trong cùng plan).
- Bước 2 config **không** chứa khóa `headers.Authorization` — chứng minh header được tiêm runtime bởi orchestrator, không lưu cứng config.
- Nếu bước 2 tự gán `Authorization` trong `headers`, giá trị đó sẽ giữ nguyên (không bị `auto_inject_headers` ghi đè).

---

## 18.9 Assignment mẫu C — Dùng `ANY_OF` assertion (toán tử OR)

Mục tiêu: Chỉ cần 1 điều kiện con đúng là step PASS. Ví dụ: định dạng ngày `YYYY-MM-DD` HOẶC `DD/MM/YYYY` đều chấp nhận.

**API:** `POST /api/v1/assignments`

**Body:**
```json
{
  "title": "Kiểm tra định dạng linh hoạt (ANY_OF)",
  "description": "ANY_OF: ít nhất 1 trong 2 định dạng ngày khớp → PASSED",
  "classId": "{classId}",
  "purpose": "GRADED",
  "topic": "Assertion linh hoạt",
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 60000,
  "executionTimeoutMs": 300000,
  "maxMemoryMb": 256,
  "maxCpu": 0.5
}
```
**Expected:** `201 Created`, `data.id` = `{assignmentId_anyOf}`.

**Plan:**
```json
{ "name": "ANY_OF assertion", "description": "OR operator — 1 điều kiện con đúng là pass", "sequenceOrder": 1, "weight": 10 }
```
**Expected:** `201 Created`, `data.id` = `{planId_anyOf}`.

**Step 1 — Kiểm tra định dạng ngày (ANY_OF 2 pattern):**
```json
{
  "stepOrder": 1,
  "name": "Kiểm tra ngày xuất bản (YYYY-MM-DD hoặc DD/MM/YYYY)",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/books",
    "query_params": { "title": "Dế Mèn" },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "json_path", "path": "$[0].published_date", "exists": true },
      { "kind": "any_of", "assertions": [
        { "kind": "matches_regex", "path": "$[0].published_date", "pattern": "^\\d{4}-\\d{2}-\\d{2}$" },
        { "kind": "matches_regex", "path": "$[0].published_date", "pattern": "^\\d{2}/\\d{2}/\\d{4}$" }
      ]}
    ]
  },
  "weight": 1
}
```

**Kết quả chạy:**
- Nếu `published_date = "2026-10-28"` → pattern 1 khớp → `ANY_OF` PASSED.
- Nếu `published_date = "28/10/2026"` → pattern 2 khớp → `ANY_OF` PASSED.
- Nếu `published_date = "not-a-date"` → cả 2 sai → `ANY_OF` FAILED → step FAILED.

**Negative (lưu step → 400):** `any_of` thiếu `assertions` hoặc `assertions` rỗng → `400 "'assertions' must be a non-empty array"`.

---

## 18.10 Bảng tổng hợp assignment dùng tính năng mới (Phase 18)

| # | Assignment | Tính năng chính | assignmentId | planId | Steps |
|---|------------|-----------------|--------------|--------|-------|
| A | Tạo nhiều sách cùng lúc (data[]) | `data[]` 4 phần tử, `${index}`, extract `bookId_${index}` | `{assignmentId_dataLoop}` | `{planId_dataLoop}` | 1 |
| B | Tự động tiêm header auth | `auto_inject_headers` bước 1, bước 2 không gán Authorization thủ công | `{assignmentId_autoInject}` | `{planId_autoInject}` | 2 |
| C | Kiểm tra định dạng linh hoạt | `ANY_OF` 2 pattern ngày (OR) | `{assignmentId_anyOf}` | `{planId_anyOf}` | 1 |

**Lưu ý:** Các assignment này có thể chạy độc lập hoặc gộp thành 1 plan nhiều step như trong section 18.2–18.4.

---

## 18.11 Cập nhật Definition of Done (tổng hợp Phase 18)

- [ ] Assignment A (`data[]`): tạo thành công, step chạy 4 lần, extract `bookId_0`…`bookId_3`.
- [ ] Assignment B (`auto_inject_headers`): login extract `accessToken`, bước sau không gán `Authorization` thủ công, `GET /plans` xác nhận bước 2 không lưu header `Authorization`.
- [ ] Assignment C (`ANY_OF`): 1 trong 2 pattern ngày khớp → PASSED; cả 2 sai → FAILED.
- [ ] Negative cases: `data[]` >10 → 400; `data[]` rỗng → 400; entry không phải object → 400; `any_of` assertions rỗng → 400; `auto_inject_headers` sai dạng → 400.
- [ ] Tất cả assignment đã publish (`POST /publish` → 200).

---

---

## 19. Phase 19 — DB Isolation Sandbox (Backend Phase 5)

Mục tiêu: Xác thực rằng mỗi grading job có database riêng, cô lập, không bị ảnh hưởng dữ liệu giữa các lần chấm (không flaky test). Đây là tính năng backend orchestration, lecturer không gọi trực tiếp API riêng mà quan sát qua log và kết quả chấm.

### 19.1 Nguyên tắc hoạt động

- Mỗi grading job claim `appPort` + `dbPort` riêng từ range 20000-30000 (PortAllocator).
- Compose boot: App + DB container cô lập cho job này.
- Sau mỗi Plan: executor gọi `DbSandboxService.resetDatabase()` → kết nối DB hệ thống (`postgres` cho PostgreSQL, `mysql` cho MySQL/MariaDB), thực hiện `DROP DATABASE IF EXISTS <db>; CREATE DATABASE <db>` → DB trống cho plan tiếp theo.
- Sau job kết thúc: dọn dẹp container DB, giải phóng port.

**Lưu ý:** PostgreSQL hỗ trợ transaction rollback DDL/DML tốt; MySQL/MariaDB force implicit commit trên DDL (`CREATE/ALTER/DROP`, `TRUNCATE`) — lecturer nên tách DDL và DML thành các step riêng.

### 19.2 Lệnh verify (giảng viên quan sát qua log và kết quả chấm)

Lecturer không gọi trực tiếp API reset DB (là internal orchestration), nhưng có thể verify qua:

1. **Xem log grading job:** Tìm thông báo `"DB port allocated: host=<port> service=<db_service> db_type=<db_type>"` → xác nhận mỗi job có port DB riêng.
2. **Chạy 2 plan liên tiếp trên cùng assignment:** Plan 1 tạo data, Plan 2 chạy trên DB sạch (dữ liệu Plan 1 không bị carry-over).
3. **Kiểm tra DB_QUERY/DB_SCHEMA_CHECK:** Các step DB chạy độc lập, không bị ảnh hưởng dữ liệu từ plan trước.

### 19.3 Danh sách kiểm tra hoàn tất (Definition of Done) cho Phase 19

- [ ] Mỗi grading job có DB container riêng, port DB không trùng với job khác.
- [ ] Sau mỗi Plan, DB được reset về trạng thái sạch (drop + recreate).
- [ ] Dữ liệu từ Plan trước không ảnh hưởng Plan sau.
- [ ] Lecturer verify qua log grading job có thông tin dbPort riêng.

---

## 20. Phase 20 — Dry-Run Mode (Backend Phase 6)

Mục tiêu: Lecturer chạy thử cấu hình chấm bài trước khi áp dụng cho sinh viên, không ghi điểm vào result-service và không cập nhật submission-status.

### 20.1 Endpoint

**API:** `POST /api/v1/internal/assignments/{assignmentId}/dry-run`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Body:**
```json
{
  "referenceCodeZipUrl": "rustfs://bucket/ref-code-123.zip",
  "config": { ... test plan config ... }
}
```

**Trả về:** `200` với `DryRunReport`:
```json
{
  "dryRunId": "...",
  "steps": [
    {
      "stepOrder": 1,
      "status": "PASSED",
      "durationMs": 340,
      "extractedVariables": {"accessToken": "tok-123"},
      "errorMessage": null
    },
    {
      "stepOrder": 2,
      "status": "FAILED",
      "durationMs": 120,
      "errorMessage": "Expected 200 but got 404"
    }
  ],
  "summary": "Passed 1/2 steps, Score: 5.00/10.00"
}
```

**Negative:**
- Assignment không tồn tại → `404`
- Không phải `LECTURER` → `403`
- Thiếu `X-Gateway-Secret` → `401`
- Config không hợp lệ → `400` (từ `StepConfigValidator`)
- Reference code zip không tồn tại → `502`

### 20.2 Lưu ý

- **Không có side effect:** Không ghi điểm vào `result-service`, không cập nhật `submission-status`. An toàn để lecturer chạy thử vô số lần.
- Thời gian timeout mặc định cho dry-run là 5 phút (300.000 ms).
- Lecturer có thể xem biến `extractedVariables` được sinh ra ở mỗi bước để tinh chỉnh config.

### 20.3 Danh sách kiểm tra hoàn tất (Definition of Done) cho Phase 20

- [ ] Endpoint dry-run trả về báo cáo chi tiết từng bước (status, durationMs, extractedVariables, errorMessage).
- [ ] Không có side effect ghi điểm vào `result-service` sau dry-run.
- [ ] Lecturer có thể xem biến extract để tinh chỉnh config.
- [ ] Negative cases: 404, 403, 401, 400, 502 hoạt động đúng.

---

## 21. Phase 21 — JSON Schema cho Step Config (Backend Phase 7)

Mục tiêu: Lecturer lấy schema chuẩn của cấu hình step để validate real-time trước khi lưu, giảm lỗi cấu hình.

### 21.1 Endpoint

**API:** `GET /api/v1/internal/assignments/{id}/config-schema`

**Headers:** `X-User-Id`, `X-Gateway-Secret`

**Trả về:** `200` với JSON Schema (draft-07):

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "HTTP_REQUEST step config",
  "type": "object",
  "required": ["method", "path"],
  "properties": {
    "method": { "type": "string", "enum": ["GET","POST","PUT","PATCH","DELETE","HEAD","OPTIONS"] },
    "path": { "type": "string", "pattern": "^/" },
    "expected_status": { "type": "integer", "minimum": 100, "maximum": 599 },
    "headers": { "type": "object" },
    "query_params": { "type": "object" },
    "body": {},
    "assertions": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["kind"],
        "properties": {
          "kind": {
            "type": "string",
            "enum": ["status","body_structure","body_equals","json_path","contains","field_equals","array_length","contains_item","json_path_equals","greater_than","less_than","matches_regex","any_of"]
          },
          "path": { "type": "string" },
          "equals": {},
          "text": { "type": "string" },
          "pattern": { "type": "string" },
          "value": {},
          "exists": { "type": "boolean" },
          "json": {},
          "assertions": { "type": "array" }
        }
      }
    },
    "extract": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "from", "expression"],
        "properties": {
          "name": { "type": "string" },
          "from": { "type": "string" },
          "expression": { "type": "string" },
          "as": { "type": "string", "enum": ["scalar", "json"] },
          "fallback": { "type": "string" }
        }
      }
    },
    "data": {
      "type": "array",
      "items": { "type": "object" }
    },
    "auto_inject_headers": { "type": "object" }
  }
}
```

### 21.2 Lưu ý

- Schema được sinh từ `StepConfigValidator.generateHttpSchema()` và luôn đồng bộ với validation logic backend.
- Nếu validator thay đổi, schema cũng thay đổi theo (không cần lecturer cập nhật thủ công).
- Schema chỉ mô tả cấu trúc nhận diện được (syntactic validation). Các ràng buộc chéo (ví dụ: `data[]` entries phải là object) được kiểm tra thêm bởi `StepConfigValidator.validateAndSerialize`.
- Endpoint là internal, không được exposing qua API gateway — chỉ course-service và executor-service nội bộ có thể gọi.

### 21.3 Danh sách kiểm tra hoàn tất (Definition of Done) cho Phase 21

- [ ] Endpoint `GET /api/v1/internal/assignments/{id}/config-schema` trả về JSON Schema hợp lệ (draft-07).
- [ ] Schema có đầy đủ các trường: `method`, `path`, `expected_status`, `assertions`, `extract`, `data`, `auto_inject_headers`.
- [ ] Schema đồng bộ với `StepConfigValidator` (không có trường thiếu hoặc thừa).

---

## 22. Bảng tổng hợp tất cả tính năng phức tạp đã triển khai (Phases 5-7)

| # | Tính năng | Endpoint | Backend | FE |
|---|-----------|----------|---------|-----|
| 1 | DB Isolation Sandbox | Internal (orchestration) | ✅ `DbSandboxService`, `GradingOrchestrator.runSteps` | - |
| 2 | Dry-Run Mode | `POST /api/v1/internal/assignments/{id}/dry-run` | ✅ `DryRunController`, `GradingOrchestrator.dryRun()` | - |
| 3 | JSON Schema | `GET /api/v1/internal/assignments/{id}/config-schema` | ✅ `StepConfigValidator.generateHttpSchema()`, `InternalAssignmentController` | ✅ `SchemaPreview.tsx`, `schema.ts` endpoint |
| 4 | `data[]` loop | - | ✅ `HttpStepExecutor`, `StepConfigValidator` | ✅ `HttpStepForm.tsx` |
| 5 | `auto_inject_headers` | - | ✅ `GradingOrchestrator.runSteps` | ✅ `HttpStepForm.tsx` |
| 6 | `ANY_OF` assertion | - | ✅ `AssertionEngine.checkAnyOf`, `StepConfigValidator` | ✅ `HttpStepForm.tsx` |
| 7 | Virtual Threads + `sendAsync()` | - | ✅ `HttpStepExecutor` | - |
| 8 | Dynamic Faker `${$FAKER_*}` | - | ✅ `VariableContext.resolveDynamic()` | ✅ `HttpStepForm.tsx` |

---

## 23. Danh sách kiểm tra hoàn tất (Definition of Done) tổng hợp

- [ ] Tạo lớp thành công, có `classId`.
- [ ] Import CSV thành công, `imported > 0`.
- [ ] Cấu hình score components thành công (ATTENDANCE/EXERCISE/FINAL_EXAM).
- [ ] Tạo graded assignment, có `assignmentId`.
- [ ] Tạo plan, có `planId`.
- [ ] Tạo 8 step cơ bản, cover tất cả assertion type, HTTP method, DB_SCHEMA_CHECK, DB_QUERY, extract biến giữa step.
- [ ] Tạo practice assignment (purpose=PRACTICE, không classId).
- [ ] Tạo 3 assignment khác nhau, lọc danh sách theo classId/search/topic/purpose đúng dữ liệu.
- [ ] Tạo 10 bài tập đa dạng (Graded + Practice) - Phase 17.
- [ ] Tạo assignment dùng `data[]` loop (tạo 4 sách khác nhau trong 1 step).
- [ ] Tạo assignment dùng `auto_inject_headers` (login 1 lần, bước sau không gán Authorization thủ công).
- [ ] Tạo assignment dùng `ANY_OF` assertion (1 trong 2 điều kiện con đúng là pass).
- [ ] Tạo assignment dùng các assertion nâng cao: `array_length`, `contains_item`, `greater_than`, `less_than`, `matches_regex`, `json_path_equals`, `fallback`, `as: "json"`.
- [ ] Publish tất cả assignment.
- [ ] Xem kết quả chấm bài giảng viên (results + submissions).
- [ ] Nhập điểm thủ công, xem transcript.
- [ ] Negative cases: 404 unowned, 403 non-lecturer, 400 validation (data[] >10, any_of assertions rỗng, auto_inject_headers sai dạng, method sai, path thiếu `/`, expected_status ngoài range, kind viết hoa, db_type oracle, ...).
- [ ] Verify DB Isolation: mỗi job có DB riêng, sau mỗi plan DB được reset.
- [ ] Verify Dry-Run: chạy thử config mà không ghi điểm, xem báo cáo chi tiết từng bước.
- [ ] Verify JSON Schema: `GET /config-schema` trả về schema đầy đủ, đồng bộ với validator.

---

*Phases 19-23 added to lecturer-full-e2e-plan.md. Date added: 2026-10-28. Backend Phases 5-7 (DB Isolation, Dry-Run, JSON Schema) và FE Phase 7 (ImportModal, SchemaPreview, schema.ts endpoint) đã triển khai và verify qua unit test.*

---

## 24. Lệnh thực thi chi tiết (API Request Specifications)

Tất cả lệnh dưới đây gọi qua **API Gateway**: `https://web-dev1-api.vucongtuanduong.dpdns.org`

Header chuẩn mọi request:
```bash
export GATEWAY="https://web-dev1-api.vucongtuanduong.dpdns.org"
export LECTURER_TOKEN="<access_token_tu_Keycloak>"
export LECTURER_UUID="<lecturer_uuid_tu_JWT_sub>"
export GATEWAY_SECRET="<x_gateway_secret>"
export CLASS_ID="<classId>"
export ASSIGNMENT_ID="<assignmentId>"
export PLAN_ID="<planId>"
```

---

### 24.1 Tạo lớp (UC-01)

```bash
curl -X POST "$GATEWAY/api/v1/classes" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "PTIT CNTT-K68",
    "semester": "20261"
  }'
# Expected: 201 Created, data.id = {classId}
```

---

### 24.2 Tạo graded assignment + plan + steps (UC-02, UC-03)

```bash
# 1. Tạo assignment
curl -X POST "$GATEWAY/api/v1/assignments" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Lab 01 - Quản lý sách REST API",
    "description": "Xây dựng REST API quản lý sách",
    "classId": "'"$CLASS_ID"'",
    "purpose": "GRADED",
    "topic": "Lập trình web",
    "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
    "dockerComposePort": 8080,
    "startupTimeoutMs": 60000,
    "executionTimeoutMs": 300000,
    "maxMemoryMb": 256,
    "maxCpu": 0.5
  }'
# Expected: 201, data.id = {assignmentId}

# 2. Tạo plan
curl -X POST "$GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/plans" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "CRUD Book API — Full",
    "sequenceOrder": 1,
    "weight": 10
  }'
# Expected: 201, data.id = {planId}

# 3. Tạo step 1 — POST tạo sách (extract bookId)
curl -X POST "$GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/plans/$PLAN_ID/steps" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
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
  }'
# Expected: 201 Created

# 4. Publish assignment
curl -X POST "$GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/publish" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET"
# Expected: 200 OK
```

---

### 24.2b Tạo assignment dùng `data[]` loop (tạo 4 sách khác nhau trong 1 step)

```bash
curl -X POST "$GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/plans/$PLAN_ID/steps" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "stepOrder": 2,
    "name": "Tạo 4 sách khác nhau (data[])",
    "stepType": "HTTP_REQUEST",
    "config": {
      "method": "POST",
      "path": "/api/v1/books",
      "headers": { "Content-Type": "application/json" },
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
    "weight": 1
  }'
# Expected: 201 Created
# Lúc chạy: step chạy 4 lần, extract bookId_0..bookId_3
```

---

### 24.3 Tạo assignment dùng `auto_inject_headers` (login 1 lần, bước sau không gán Authorization thủ công)

```bash
# Bước 1: Login + khai báo auto_inject_headers
curl -X POST "$GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/plans/$PLAN_ID/steps" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
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
    "weight": 1
  }'

# Bước 2: GET sách (KHÔNG gán Authorization thủ công, phụ thuộc auto_inject_headers)
curl -X POST "$GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/plans/$PLAN_ID/steps" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "stepOrder": 2,
    "name": "Lấy danh sách sách",
    "stepType": "HTTP_REQUEST",
    "config": {
      "method": "GET",
      "path": "/api/v1/books",
      "query_params": { "title": "Dế Mèn" },
      "expected_status": 200,
      "assertions": [
        { "kind": "status", "equals": 200 },
        { "kind": "json_path", "path": "$", "exists": true }
      ]
    },
    "weight": 1
  }'
# Executor tiêm Authorization: Bearer ${accessToken} vào bước 2 tự động
```

---

### 24.4 Tạo assignment dùng `ANY_OF` assertion

```bash
curl -X POST "$GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/plans/$PLAN_ID/steps" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "stepOrder": 3,
    "name": "Lọc sách (ANY_OF định dạng ngày)",
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
    "weight": 1
  }'
# ANY_OF PASSED nếu ít nhất 1 định dạng ngày khớp
```

---

### 24.5 Dry-Run Mode (Phase 20)

```bash
# Chạy thử config trước khi áp dụng cho sinh viên
curl -X POST "$GATEWAY/api/v1/internal/assignments/$ASSIGNMENT_ID/dry-run" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "referenceCodeZipUrl": "rustfs://bucket/ref-code-123.zip",
    "config": {
      "method": "POST",
      "path": "/api/v1/books",
      "body": { "title": "Test Book", "author": "Author", "year": 2000 },
      "expected_status": 201,
      "assertions": [
        { "kind": "status", "equals": 201 },
        { "kind": "json_path", "path": "$.id", "exists": true }
      ],
      "extract": [
        { "name": "bookId", "from": "response_body", "expression": "$.id" }
      ]
    }
  }'
# Expected: 200 với DryRunReport chi tiết từng bước
# Không ghi điểm vào result-service, không cập nhật submission-status
```

---

### 24.6 JSON Schema (Phase 21)

```bash
# Lấy JSON Schema cho HTTP_REQUEST step config
curl -X GET "$GATEWAY/api/v1/internal/assignments/$ASSIGNMENT_ID/config-schema" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET" \
  -H "Content-Type: application/json"
# Expected: 200 với JSON Schema draft-07
```

---

### 24.7 Negative cases (phải nhận 400)

```bash
# data[] 11 phần tử
curl -X POST "$GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/plans/$PLAN_ID/steps" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "stepOrder": 99,
    "name": "data[] quá lớn",
    "stepType": "HTTP_REQUEST",
    "config": {
      "method": "POST",
      "path": "/api/v1/books",
      "data": [
        {"title":"S1","year":"1941"},{"title":"S2","year":"1942"},{"title":"S3","year":"1943"},
        {"title":"S4","year":"1944"},{"title":"S5","year":"1945"},{"title":"S6","year":"1946"},
        {"title":"S7","year":"1947"},{"title":"S8","year":"1948"},{"title":"S9","year":"1949"},
        {"title":"S10","year":"1950"},{"title":"S11","year":"1951"}
      ],
      "body": {"title": "${title}", "year": "${year}"}
    }
  }'
# Expected: 400 "data must contain at most 10 entries"

# any_of assertions rỗng
curl -X POST "$GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/plans/$PLAN_ID/steps" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "stepOrder": 99,
    "name": "any_of rỗng",
    "stepType": "HTTP_REQUEST",
    "config": {
      "method": "GET",
      "path": "/api/v1/books",
      "expected_status": 200,
      "assertions": [{"kind": "any_of", "assertions": []}]
    }
  }'
# Expected: 400 "'assertions' must be a non-empty array"

# method sai
curl -X POST "$GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/plans/$PLAN_ID/steps" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H "X-User-Id: $LECTURER_UUID" \
  -H "X-Gateway-Secret: $GATEWAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "stepOrder": 99,
    "name": "method sai",
    "stepType": "HTTP_REQUEST",
    "config": {
      "method": "TELEPORT",
      "path": "/api/v1/books",
      "expected_status": 200
    }
  }'
# Expected: 400 "unknown method"
```

---

### 24.8 Verify log DB Isolation (Phase 19)

```bash
# Sau khi chạy grading job, xem log để xác nhận mỗi job có dbPort riêng
GET /api/v1/grading-jobs/$JOB_ID/logs
# Tìm: "DB port allocated: host=24567 service=db db_type=postgres"
```

---

*Phase 24 added to lecturer-full-e2e-plan.md. Date added: 2026-10-28. API request specifications cho các tính năng phức tạp (Phases 19-23) đã bổ sung.*

---

## 24. Cấu hình JSON chi tiết cho các tính năng phức tạp (Chi tiết nhất)

Phần này cung cấp các ví dụ JSON config chi tiết nhất, cover tất cả các loại assertion, step types, và cấu trúc phức tạp mà backend hỗ trợ. Lecturer có thể copy-paste trực tiếp vào API để tạo step.

### 24.1 HTTP_REQUEST — Tất cả assertion types

#### 24.1.1 status assertion

```json
{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200,
  "assertions": [
    { "kind": "status", "equals": 200 }
  ],
  "required": true,
  "timeoutMs": 5000
}
```

#### 24.1.2 json_path assertion

```json
{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200,
  "assertions": [
    { "kind": "json_path", "path": "$.id", "exists": true },
    { "kind": "json_path", "path": "$.title", "exists": true },
    { "kind": "json_path", "path": "$.author", "exists": true },
    { "kind": "json_path", "path": "$.year", "exists": true },
    { "kind": "json_path", "path": "$.metadata.created_at", "exists": false }
  ]
}
```

#### 24.1.3 contains assertion

```json
{
  "method": "GET",
  "path": "/api/v1/books",
  "query_params": { "title": "Dế Mèn" },
  "expected_status": 200,
  "assertions": [
    { "kind": "contains", "text": "Dế Mèn" },
    { "kind": "contains", "text": "Tô Hoài" }
  ]
}
```

#### 24.1.4 field_equals assertion

```json
{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200,
  "assertions": [
    { "kind": "field_equals", "path": "$.id", "equals": "${bookId}" },
    { "kind": "field_equals", "path": "$.title", "equals": "Dế Mèn Phiêu Lưu Ký" },
    { "kind": "field_equals", "path": "$.author", "equals": "Tô Hoài" },
    { "kind": "field_equals", "path": "$.year", "equals": "1941" }
  ]
}
```

#### 24.1.5 array_length assertion

```json
{
  "method": "GET",
  "path": "/api/v1/books",
  "query_params": { "title": "Dế Mèn" },
  "expected_status": 200,
  "assertions": [
    { "kind": "array_length", "path": "$", "equals": 1 },
    { "kind": "array_length", "path": "$", "equals": 0 },
    { "kind": "array_length", "path": "$.books", "equals": 5 },
    { "kind": "array_length", "path": "$.missing", "equals": 0 }
  ]
}
```

#### 24.1.6 contains_item assertion

```json
{
  "method": "GET",
  "path": "/api/v1/books",
  "query_params": { "title": "Dế Mèn" },
  "expected_status": 200,
  "assertions": [
    { "kind": "contains_item", "path": "$[*].title", "equals": "Dế Mèn Phiêu Lưu Ký" },
    { "kind": "contains_item", "path": "$[*].title", "equals": "Sách A" },
    { "kind": "contains_item", "path": "$[*].year", "equals": "1941" },
    { "kind": "contains_item", "path": "$.books[*].id", "equals": "abc-123" }
  ]
}
```

#### 24.1.7 json_path_equals assertion

```json
{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200,
  "assertions": [
    { "kind": "json_path_equals", "path": "$.id", "equals": "${bookId}" },
    { "kind": "json_path_equals", "path": "$.year", "equals": "1941" },
    { "kind": "json_path_equals", "path": "$.available", "equals": "true" }
  ]
}
```

#### 24.1.8 greater_than assertion

```json
{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200,
  "assertions": [
    { "kind": "greater_than", "path": "$.year", "value": "1900" },
    { "kind": "greater_than", "path": "$.price", "value": "100000" },
    { "kind": "greater_than", "path": "$.rating", "value": "4.0" }
  ]
}
```

#### 24.1.9 less_than assertion

```json
{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200,
  "assertions": [
    { "kind": "less_than", "path": "$.year", "value": "2020" },
    { "kind": "less_than", "path": "$.price", "value": "500000" },
    { "kind": "less_than", "path": "$.rating", "value": "5.0" }
  ]
}
```

#### 24.1.10 matches_regex assertion

```json
{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200,
  "assertions": [
    { "kind": "matches_regex", "path": "$.isbn", "pattern": "^ISBN-\\d{4}$" },
    { "kind": "matches_regex", "path": "$.email", "pattern": "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$" },
    { "kind": "matches_regex", "path": "$.phone", "pattern": "^\\+84\\d{9,10}$" },
    { "kind": "matches_regex", "path": "$.code", "pattern": "^[A-Z]{2}-\\d{3}$" }
  ]
}
```

#### 24.1.11 any_of assertion (OR operator)

```json
{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200,
  "assertions": [
    { "kind": "status", "equals": 200 },
    { "kind": "json_path", "path": "$[0].published_date", "exists": true },
    {
      "kind": "any_of",
      "assertions": [
        { "kind": "matches_regex", "path": "$[0].published_date", "pattern": "^\\d{4}-\\d{2}-\\d{2}$" },
        { "kind": "matches_regex", "path": "$[0].published_date", "pattern": "^\\d{2}/\\d{2}/\\d{4}$" },
        { "kind": "matches_regex", "path": "$[0].published_date", "pattern": "^\\d{2}-\\d{2}-\\d{4}$" }
      ]
    },
    {
      "kind": "any_of",
      "assertions": [
        { "kind": "field_equals", "path": "$[0].status", "equals": "published" },
        { "kind": "field_equals", "path": "$[0].status", "equals": "draft" },
        { "kind": "field_equals", "path": "$[0].status", "equals": "archived" }
      ]
    }
  ]
}
```

---

### 24.2 HTTP_REQUEST — Extract variables (extract[])

#### 24.2.1 Extract scalar (mặc định)

```json
{
  "method": "POST",
  "path": "/api/v1/books",
  "body": { "title": "Sách A", "author": "Tô Hoài", "year": 1941 },
  "expected_status": 201,
  "extract": [
    { "name": "bookId", "from": "response_body", "expression": "$.id" }
  ]
}
```

#### 24.2.2 Extract as JSON (toàn bộ object/mảng)

```json
{
  "method": "POST",
  "path": "/api/v1/books",
  "body": { "title": "Sách A", "author": "Tô Hoài", "year": 1941 },
  "expected_status": 201,
  "extract": [
    { "name": "wholeBook", "from": "response_body", "expression": "$", "as": "json" },
    { "name": "bookList", "from": "response_body", "expression": "$", "as": "json" }
  ]
}
```

#### 24.2.3 Extract với fallback

```json
{
  "method": "GET",
  "path": "/api/v1/books/${bookId}",
  "expected_status": 200,
  "extract": [
    { "name": "author", "from": "response_body", "expression": "$.author", "fallback": "Unknown" },
    { "name": "isbn", "from": "response_body", "expression": "$.isbn", "fallback": "N/A" },
    { "name": "description", "from": "response_body", "expression": "$.description", "fallback": "" }
  ]
}
```

#### 24.2.4 Extract indexed (${index})

```json
{
  "method": "POST",
  "path": "/api/v1/books",
  "data": [
    { "title": "Sách A", "year": "1941" },
    { "title": "Sách B", "year": "1950" },
    { "title": "Sách C", "year": "1960" }
  ],
  "body": { "title": "${title}", "author": "Tô Hoài", "year": "${year}" },
  "expected_status": 201,
  "extract": [
    { "name": "bookId_${index}", "from": "response_body", "expression": "$.id" }
  ]
}
```

---

### 24.3 HTTP_REQUEST — data[] loop (vòng lặp dữ liệu)

#### 24.3.1 data[] với 4 bản ghi

```json
{
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
}
```

#### 24.3.2 data[] với nhiều fields

```json
{
  "method": "POST",
  "path": "/api/v1/orders",
  "body": {
    "customerName": "${customerName}",
    "items": "${items}",
    "total": "${total}",
    "status": "${status}"
  },
  "expected_status": 201,
  "data": [
    { "customerName": "Nguyen Van A", "items": "[\"Sach A\",\"Sach B\"]", "total": "250000", "status": "PENDING" },
    { "customerName": "Tran Thi B", "items": "[\"Sach C\"]", "total": "150000", "status": "SHIPPED" },
    { "customerName": "Le Van C", "items": "[\"Sach D\",\"Sach E\",\"Sach F\"]", "total": "450000", "status": "DELIVERED" }
  ],
  "extract": [
    { "name": "orderId_${index}", "from": "response_body", "expression": "$.id" },
    { "name": "orderStatus_${index}", "from": "response_body", "expression": "$.status" }
  ]
}
```

#### 24.3.3 data[] kết hợp với auto_inject_headers

```json
{
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
}
```

---

### 24.4 HTTP_REQUEST — auto_inject_headers

#### 24.4.1 Login step (khai báo auto_inject_headers)

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
  }
}
```

#### 24.4.2 Bước sau (không gán Authorization thủ công)

```json
{
  "stepOrder": 2,
  "name": "Lấy danh sách sách",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/books",
    "query_params": { "title": "Dế Mèn" },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "json_path", "path": "$", "exists": true }
    ]
  },
  "weight": 1
}
```

#### 24.4.3 Nhiều auto_inject_headers

```json
{
  "method": "POST",
  "path": "/api/v1/auth/login",
  "body": { "username": "lecturer", "password": "secret" },
  "expected_status": 200,
  "auto_inject_headers": {
    "Authorization": "Bearer ${accessToken}",
    "X-Client-Id": "lecturer-web",
    "X-Request-Source": "grading-system"
  },
  "assertions": [
    { "kind": "status", "equals": 200 },
    { "kind": "json_path", "path": "$.accessToken", "exists": true }
  ],
  "extract": [
    { "name": "accessToken", "from": "response_body", "expression": "$.accessToken" }
  ],
  "required": true
}
```

---

### 24.5 DB_SCHEMA_CHECK

```json
{
  "stepOrder": 1,
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
      { "kind": "COLUMN_EXISTS", "table_name": "books", "column_name": "author", "data_type": "VARCHAR" },
      { "kind": "COLUMN_EXISTS", "table_name": "books", "column_name": "year", "data_type": "INTEGER" },
      { "kind": "PRIMARY_KEY", "table_name": "books", "column": "id" },
      { "kind": "INDEX_EXISTS", "table_name": "books", "index_name": "idx_books_title" }
    ],
    "timeoutMs": 30000
  },
  "weight": 1
}
```

---

### 24.6 DB_QUERY

```json
{
  "stepOrder": 2,
  "name": "Kiểm tra dữ liệu sách đã tạo",
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

```json
{
  "stepOrder": 3,
  "name": "Kiểm tra dữ liệu sinh viên",
  "stepType": "DB_QUERY",
  "config": {
    "connection": {
      "db_type": "mysql",
      "database": "students_db",
      "username": "root",
      "password": "root"
    },
    "query": "SELECT COUNT(*) FROM students WHERE class_id = ${classId}",
    "expected": { "row_count": 1, "columns": ["count"] },
    "timeoutMs": 30000
  },
  "weight": 1
}
```

---

### 24.7 DB_MIGRATION

```json
{
  "stepOrder": 1,
  "name": "Tạo bảng books",
  "stepType": "DB_MIGRATION",
  "config": {
    "connection": {
      "db_type": "postgres",
      "database": "bookstore",
      "username": "postgres",
      "password": "postgres"
    },
    "statements": [
      "CREATE TABLE IF NOT EXISTS books (id SERIAL PRIMARY KEY, title VARCHAR(255) NOT NULL, author VARCHAR(255), year INTEGER, created_at TIMESTAMP DEFAULT NOW())",
      "CREATE INDEX IF NOT EXISTS idx_books_title ON books(title)",
      "CREATE INDEX IF NOT EXISTS idx_books_author ON books(author)"
    ],
    "timeoutMs": 30000
  },
  "weight": 1
}
```

---

### 24.8 Multi-step chaining (chuỗi bước liên kết)

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
    "auto_inject_headers": { "Authorization": "Bearer ${accessToken}" },
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
  "weight": 1
}

{
  "stepOrder": 2,
  "name": "Tạo sách (extract bookId)",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/books",
    "body": { "title": "Sách A", "author": "Tô Hoài", "year": 1941 },
    "expected_status": 201,
    "assertions": [
      { "kind": "status", "equals": 201 },
      { "kind": "json_path", "path": "$.id", "exists": true }
    ],
    "extract": [
      { "name": "bookId", "from": "response_body", "expression": "$.id" }
    ],
    "required": true,
    "timeoutMs": 5000
  },
  "weight": 1
}

{
  "stepOrder": 3,
  "name": "Lấy sách theo ID (dùng bookId từ step 2)",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "GET",
    "path": "/api/v1/books/${bookId}",
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "field_equals", "path": "$.id", "equals": "${bookId}" },
      { "kind": "json_path", "path": "$.title", "exists": true }
    ]
  },
  "weight": 1
}

{
  "stepOrder": 4,
  "name": "Cập nhật sách (dùng bookId)",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "PATCH",
    "path": "/api/v1/books/${bookId}",
    "body": { "title": "Sách A - Bản sửa" },
    "expected_status": 200,
    "assertions": [
      { "kind": "status", "equals": 200 },
      { "kind": "contains", "text": "Bản sửa" }
    ]
  },
  "weight": 1
}

{
  "stepOrder": 5,
  "name": "Xóa sách (dùng bookId)",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "DELETE",
    "path": "/api/v1/books/${bookId}",
    "expected_status": 204,
    "required": true
  },
  "weight": 1
}

{
  "stepOrder": 6,
  "name": "Kiểm tra đã xóa (404)",
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

---

### 24.9 Faker / Dynamic variables

```json
{
  "method": "POST",
  "path": "/api/v1/books",
  "body": {
    "title": "${$FAKER_BOOK_TITLE}",
    "author": "${$FAKER_NAME}",
    "isbn": "${$UUID}",
    "email": "${$FAKER_EMAIL}"
  },
  "expected_status": 201,
  "assertions": [
    { "kind": "status", "equals": 201 },
    { "kind": "json_path", "path": "$.id", "exists": true },
    { "kind": "json_path", "path": "$.isbn", "exists": true }
  ],
  "extract": [
    { "name": "bookId", "from": "response_body", "expression": "$.id" }
  ]
}
```

---

### 24.10 Kết hợp toàn bộ tính năng trong 1 step (phức tạp nhất)

```json
{
  "stepOrder": 1,
  "name": "Tạo 4 sách khác nhau với data[] và auto_inject_headers",
  "stepType": "HTTP_REQUEST",
  "config": {
    "method": "POST",
    "path": "/api/v1/books",
    "body": {
      "title": "${title}",
      "author": "Tô Hoài",
      "year": "${year}",
      "isbn": "${$UUID}"
    },
    "expected_status": 201,
    "auto_inject_headers": {
      "Authorization": "Bearer ${accessToken}"
    },
    "data": [
      { "title": "Sách A", "year": "1941" },
      { "title": "Sách B", "year": "1950" },
      { "title": "Sách C", "year": "1960" },
      { "title": "Dế Mèn Phiêu Lưu Ký", "year": "1941" }
    ],
    "extract": [
      { "name": "bookId_${index}", "from": "response_body", "expression": "$.id", "fallback": "" },
      { "name": "wholeResponse_${index}", "from": "response_body", "expression": "$", "as": "json" }
    ],
    "assertions": [
      { "kind": "status", "equals": 201 },
      { "kind": "json_path", "path": "$.id", "exists": true },
      { "kind": "array_length", "path": "$", "equals": 1 },
      { "kind": "any_of", "assertions": [
        { "kind": "matches_regex", "path": "$.title", "pattern": "^Sách [A-C]$" },
        { "kind": "matches_regex", "path": "$.title", "pattern": "^Dế Mèn" }
      ]}
    ],
    "required": true,
    "timeoutMs": 10000
  },
  "weight": 1
}
```

---

### 17.17 Nâng cấp plan bài 1 sang tiếng Anh (2026-10-30)

Mục này thay thế cấu hình 6 bước HTTP và 2 bước DB của §17.2, §17.16 cho assignment
"Quản lý sách REST API" ở lớp `D22CQKH02-B`. Hai lý do:

- Mock `mock/book-app-login-v1` là Flask thuần, `docker-compose.yml` chỉ có service `book-app`,
  không có Postgres, nên 2 bước DB không bao giờ pass.
- Dữ liệu tiếng Việt ("Dế Mèn", "Tô Hoài") vừa làm `contains`/`body_equals` lệch (Flask escape
  non-ASCII thành `\uXXXX`) vừa che mất lỗi encode query của executor.

Plan hiện tại: **Book CRUD - Full grading plan**, 12 bước HTTP, tổng weight 18.

| # | Bước | Request | Assertion chính | Weight |
|---|------|---------|-----------------|--------|
| 1 | Health check | `GET /api/v1/health` | `field_equals` status=healthy, service=book-grading-mock; `json_path` `$.status` | 1 |
| 2 | Log in and extract the access token | `POST /api/v1/auth/login` | `json_path` accessToken; `matches_regex` `^mock-access-token-[0-9a-f-]{36}$`; `greater_than`/`less_than` expires_in; extract `accessToken`; `auto_inject_headers` Authorization | 2 |
| 3 | Reject a wrong password | `POST /api/v1/auth/login` (sai mật khẩu) | `expected_status` 401; `json_path` `$.error`; `any_of` gồm `contains` "Invalid credentials" hoặc `field_equals` error | 1 |
| 4 | Create a book and extract its id | `POST /api/v1/books` | `body_structure` 7 khoá; `matches_regex` isbn `^ISBN-[0-9a-f]{8}$`; `contains` author; extract `bookId` | 2 |
| 5 | Read the book by id | `GET /api/v1/books/${bookId}` | `field_equals` id, title, year | 1 |
| 6 | Filter books by title | `GET /api/v1/books?title=The Little Prince` | `array_length` `$` = 1; `contains_item` `$[*].title`; `json_path_equals` `$[0].author` | 2 |
| 7 | Update the book title | `PATCH /api/v1/books/${bookId}` | `field_equals` title; `contains` "Updated"; `json_path` `$.isbn` | 1 |
| 8 | Re-read the updated book | `GET /api/v1/books/${bookId}` | `field_equals` title | 1 |
| 9 | Create four books with a data[] loop | `POST /api/v1/books`, 4 dòng `data[]` | `field_equals` title/author theo `${title}`/`${author}`; `matches_regex` isbn; extract `bookId_${index}` | 3 |
| 10 | List every book | `GET /api/v1/books` | `array_length` `$` = 5; `contains_item` title và author; `json_path` `$[0].id` | 1 |
| 11 | Delete the book | `DELETE /api/v1/books/${bookId}` | `expected_status` 204 | 1 |
| 12 | Confirm the deleted book returns 404 | `GET /api/v1/books/${bookId}` | `expected_status` 404; `body_equals` `{"error":"Book not found"}`; `field_equals` `$.error` | 2 |

Phủ đủ 13 assertion kind: `status`, `json_path`, `contains`, `body_structure`, `body_equals`,
`field_equals`, `array_length`, `contains_item`, `json_path_equals`, `greater_than`, `less_than`,
`matches_regex`, `any_of`.

Kết quả chấm thật ngày 2026-10-30 (submission `c49eb1e3`, zip `book-app-login-v1.zip`):
12/12 bước PASSED, điểm 10.00/10; bước 6 gọi đúng URL
`/api/v1/books?title=The%20Little%20Prince`; bước 9 tạo đủ 4 sách và extract `bookId_0..3`.

Quy ước khi sửa plan (đã ghi vào skill `lecturer-e2e-data`):

- Tên bước, mô tả và dữ liệu viết bằng tiếng Anh.
- Chuỗi trong `contains`/`body_equals` chỉ dùng ASCII.
- `query_params` nhận giá trị thô, executor tự percent-encode.
- Mỗi bước đặt `timeoutMs` 10000.

### 17.18 Sửa plan "Quản lý tài sản" để chấm đủ 7 bước HTTP + DB (2026-10-30)

Assignment `83580461-ee6e-478a-84f6-ec1bb63e9548`, plan
`b7631721-53bf-410a-ba38-c1fa4c784b34` ("Tài sản — Quản lý"), 7 bước, weight 10.
Bốn lỗi cấu hình làm bước DB không thể pass dù app đúng:

| Lỗi | Triệu chứng | Sửa |
|-----|-------------|-----|
| `connection` thiếu `db_service`, `username`, `password` | Executor không publish port DB; JDBC `localhost:<hostPort>` connection refused | Thêm `"db_service":"db","username":"postgres","password":"postgres"` |
| `db_port: 8086` (app port) | Patcher publish `<host>:8086`; Postgres nghe 5432 | Đổi `"db_port":5432` (port trong container) |
| `PRIMARY_KEY` thiếu `table_name` | `PRIMARY KEY (id) missing on ''` | Thêm `"table_name":"assets"` vào chính check đó |
| `SELECT COUNT(*) FROM assets` + `row_count:0` | `row_count` đếm số dòng result-set; `COUNT(*)` luôn trả 1 dòng | Đổi query thành `SELECT id FROM assets` |

Plan sau khi sửa (7 bước, weight 10):

| # | Bước | Request / query | Assertion chính |
|---|------|-----------------|-----------------|
| 1 | Add new asset | `POST /api/v1/assets` | 201; `json_path $.id`; `contains "Máy chủ Dell"`; extract `assetId` |
| 2 | Get asset by ID | `GET /api/v1/assets/${assetId}` | 200; `body_structure` đúng 5 khoá `id,name,category,purchaseDate,originalValue` |
| 3 | Update asset value | `PATCH /api/v1/assets/${assetId}` `{"currentValue":40000000}` | 200; `contains "40000000"` |
| 4 | Delete asset | `DELETE /api/v1/assets/${assetId}` | 204 |
| 5 | Check asset deleted | `GET /api/v1/assets/${assetId}` | 404 |
| 6 | Check DB structure (assets_db) | `TABLE_EXISTS assets`, `PRIMARY_KEY assets.id` | cả hai true |
| 7 | Query data (assets_db) | `SELECT id FROM assets` | `row_count: 0` |

`GET` chỉ trả 5 khoá vì bước 2 dùng `body_structure`; `currentValue` chỉ xuất hiện ở response
`PATCH` (bước 3 chỉ kiểm tra substring).

Mock solution: `mock/asset-management-solution/` (Flask + psycopg + Postgres 16, service
`asset-app` cổng 8086 và service `db` database `assets_db`), zip phẳng
`mock/asset-management-solution.zip` gồm 5 file. Đã kiểm tra local 15/15 check (HTTP + psql)
và chấm thật submission `d5b186e6-87d8-4e16-a67e-84686937bdc0`: 7/7 bước PASSED, 10.00/10.

### 17.19 Sửa plan "Quản lý kho hàng" để chấm đủ 7 bước HTTP + DB (2026-10-30)

Assignment `e39e0f42-c8c9-4da7-8a8d-53e357e9848a`, plan
`c3ed9afa-c3fa-4398-a3c2-b61d469787c4` ("Kho hàng — Nhập/Xuất"), 7 bước, weight 10.
Như plan tài sản, 4 lỗi cấu hình DB phải sửa mới chấm được bước 6 và 7:

| Lỗi | Triệu chứng | Sửa |
|-----|-------------|-----|
| `connection` thiếu `db_service`, `username`, `password` | Executor không publish port DB; JDBC connection refused | Thêm `"db_service":"db","username":"postgres","password":"postgres"` |
| `db_port: 8085` (app port) | Patcher publish `<host>:8085`; Postgres nghe 5432 | Đổi `"db_port":5432` |
| `PRIMARY_KEY` thiếu `table_name` | `PRIMARY KEY (id) missing on ''` | Thêm `"table_name":"inventory"` vào check đó |
| `SELECT COUNT(*)` + `row_count: 0` | `COUNT(*)` luôn trả 1 dòng | Query `SELECT id FROM inventory WHERE id::text = '${outboundId}'` |

Lý do query bước 7 lọc theo id: inbound receipt vẫn còn trong bảng `inventory`, nên không thể asserted toàn bảng rỗng. `row_count` đếm số dòng result-set, nên `SELECT COUNT(*)` không bao giờ bằng 0.

Mock solution: `mock/inventory-management-solution/` (Flask + psycopg + Postgres 16, service `inventory-app` cổng 8085 và service `db` database `inventory_db`), zip phẳng
`mock/inventory-management-solution.zip` gồm 5 file. Đã kiểm tra local 16/16 check (HTTP + psql)
và chấm thật submission `004d7e34-902a-44bb-baa5-2a2dfe79e2b5`: 7/7 bước PASSED, 10.00/10.

---

### 17.20 Sửa plan "Hệ thống chấm điểm" để chấm đủ 8 bước HTTP + DB (2026-10-30)

Assignment `4d127dd9-ad03-4d88-b2d1-9e39dc4d22f7`, plan
`97b64df7-4118-4b31-8b4f-d0fea38fe06c` ("Chấm điểm — Nhập và xử lý"), 8 bước, weight 10.
Như hai plan trước, 4 lỗi cấu hình DB phải sửa mới chấm được bước 7 và 8:

| Lỗi | Triệu chứng | Sửa |
|-----|-------------|-----|
| `connection` thiếu `db_service`, `username`, `password` | Executor không publish port DB; JDBC connection refused | Thêm `"db_service":"db","username":"postgres","password":"postgres"` |
| `db_port: 8084` (app port) | Patcher publish `<host>:8084`; Postgres nghe 5432 | Đổi `"db_port":5432` |
| `PRIMARY_KEY` thiếu `table_name` | `PRIMARY KEY (id) missing on ''` | Thêm `"table_name":"grades"` vào check đó |
| `SELECT COUNT(*)` + `row_count: 0` | `COUNT(*)` luôn trả 1 dòng | Query `SELECT id FROM grades WHERE id::text = '${scoreId}'` |

Lý do query bước 8 lọc theo id: chỉ xóa một bản ghi theo scoreId, bảng grades vẫn có thể chứa bản ghi khác, nên không thể asserted toàn bảng rỗng. `row_count` đếm số dòng result-set, nên `SELECT COUNT(*)` không bao giờ bằng 0.

Mock solution: `mock/grades-management-solution/` (Flask + psycopg + Postgres 16, service `grades-app` cổng 8084 và service `db` database `grades_db`), zip phẳng
`mock/grades-management-solution.zip` gồm 5 file. Đã kiểm tra local 15/15 check (HTTP + psql)
và chấm thật submission `c2279f84-e940-4953-9cc6-2633eae5944e`: 8/8 bước PASSED, 10.00/10.

---

### 17.21 Sửa plan "Quản lý thư viện" để chấm đủ 7 bước HTTP + DB (2026-10-30)

Assignment `155e2459-c734-4425-b926-0f84d96e7821`, plan
`7ad3bf24-75b7-48d8-b574-4bd9fa92d1a1` ("Thư viện — Mượn trả"), 7 bước, weight 10.
Như ba plan trước, 4 lỗi cấu hình DB phải sửa mới chấm được bước 6 và 7:

| Lỗi | Triệu chứng | Sửa |
|-----|-------------|-----|
| `connection` thiếu `db_service`, `username`, `password` | Executor không publish port DB; JDBC connection refused | Thêm `"db_service":"db","username":"postgres","password":"postgres"` |
| `db_port: 8083` (app port) | Patcher publish `<host>:8083`; Postgres nghe 5432 | Đổi `"db_port":5432` |
| `PRIMARY_KEY` thiếu `table_name` | `PRIMARY KEY (id) missing on ''` | Thêm `"table_name":"library"` vào check đó |
| `SELECT COUNT(*)` + `row_count: 0` | `COUNT(*)` luôn trả 1 dòng | Query `SELECT id FROM library WHERE id::text = '${libBookId}'` |

Lý do query bước 7 lọc theo id: chỉ xóa một cuốn sách theo libBookId, bảng library vẫn có thể chứa sách khác, nên không thể asserted toàn bảng rỗng. `row_count` đếm số dòng result-set, nên `SELECT COUNT(*)` không bao giờ bằng 0.

Mock solution: `mock/library-management-solution/` (Flask + psycopg + Postgres 16, service `library-app` cổng 8083 và service `db` database `library_db`), zip phẳng
`mock/library-management-solution.zip` gồm 5 file. Đã kiểm tra local 12/12 check (HTTP + psql)
và chấm thật submission `c9c3e863-41ca-45c2-8f79-2ef73ae09247`: 7/7 bước PASSED, 10.00/10.

---

*Section 24 added to lecturer-full-e2e-plan.md. Date added: 2026-10-28. Cấu hình JSON chi tiết nhất cho tất cả tính năng phức tạp (Phases 1-7) đã bổ sung.*

*This document is based on actual code in repo `web-grading-system-deploy`. Date written: 2026-10-28.*
