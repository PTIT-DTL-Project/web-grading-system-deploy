# Tài liệu chi tiết luồng API — course-service / ClassController

Nơi lưu: `docs/api/docs/course-service/class-controller.md`

Mục đích: giải thích chi tiết từng hàm/controller/service trong luồng quản lý lớp học (class) của course-service, bao gồm input, output, điều kiện tiên quyết, ví dụ request/response, và các mã lỗi có thể xảy ra. Viết bằng tiếng Việt.

---

## 1. Tổng quan

`ClassController` là REST controller của service `course-service`, trỏ về base path `/api/v1/classes`. Nó cung cấp các endpoint cho giảng viên (LECTURER) để quản lý lớp học: tạo, danh sách, xem chi tiết, lưu trữ (archive), nhập danh sách sinh viên từ CSV, và xem danh sách sinh viên trong lớp.

| Endpoint | Method | Mục đích | Quyền |
|----------|--------|----------|-------|
| `/api/v1/classes` | POST | Tạo lớp học mới | LECTURER |
| `/api/v1/classes` | GET | Lấy danh sách lớp học của mình (có tìm kiếm, lọc trạng thái, phân trang) | LECTURER |
| `/api/v1/classes/{id}` | GET | Xem chi tiết một lớp | owner-scoped (không role gate) |
| `/api/v1/classes/{id}/archive` | PUT | Lưu trữ (archived) một lớp | LECTURER |
| `/api/v1/classes/{id}/students/import` | POST | Nhập danh sách sinh viên từ file CSV | LECTURER |
| `/api/v1/classes/{id}/students` | GET | Lấy danh sách sinh viên trong lớp | LECTURER |

Ghi chú về quyền: `GET /api/v1/classes/{id}` (xem chi tiết) **không** có `@PreAuthorize` — nó chỉ owner-scoped qua `findByIdAndOwnerId` → 404 nếu không sở hữu. Điều này cho phép sau này mở cho sinh viên đã đăng ký xem chi tiết lớp của mình. Còn các endpoint còn lại đều `@PreAuthorize("hasRole('LECTURER')")`.

Tất cả endpoint nhận `X-User-Id` từ header (giá trị mặc định `"anonymous"` nếu thiếu). Controller giao tiếp với `ClassService` để thực hiện logic nghiệp vụ.

---

## 2. DTO liên quan

### 2.1 `CreateClassRequest` (dto/request)
Dùng cho request tạo lớp học.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `name` | String | `@NotBlank` | Tên lớp học |
| `semester` | String | `@NotBlank` | Học kỳ (ví dụ: `20261`, `HK1-2026`) |

Có `@Builder`, `@AllArgsConstructor` — khác với `CreateAssignmentRequest` deliberately không dùng `@Builder`.

### 2.2 `ClassResponse` (dto/response)
Trả về cho client sau mỗi thao tác lớp học.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID lớp học |
| `ownerId` | UUID | ID giảng viên sở hữu |
| `name` | String | Tên lớp |
| `semester` | String | Học kỳ |
| `status` | String | `ACTIVE` hoặc `ARCHIVED` |
| `createdAt` | OffsetDateTime | Thời điểm tạo |

### 2.3 `ClassStudentResponse` (dto/response)
Thông tin một sinh viên trong lớp (dùng cho danh sách sinh viên).

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `id` | UUID | ID dòng roster (class_students) |
| `studentCode` | String | Mã sinh viên |
| `studentName` | String | Họ tên sinh viên |
| `email` | String | Email (có thể null) |

### 2.4 `ClassService.ImportResult` (record)
Kết quả nhập CSV trả về cho endpoint import.

| Trường | Kiểu | Mô tả |
|--------|------|-------|
| `imported` | int | Số sinh viên được import thành công |
| `skipped` | int | Số dòng bị bỏ qua (trùng mã, thiếu dữ liệu, …) |

---

## 3. Chi tiết từng hàm

### 3.1 `create` — Tạo lớp học mới

**Vị trí:** `ClassController.create(...)` → `ClassService.create(...)`

**Endpoint:** `POST /api/v1/classes`

**Header đầu vào:**
- `X-User-Id` (String, mặc định `"anonymous"`): ID giảng viên sở hữu

**Request body:** `CreateClassRequest`

**Luồng xử lý (Controller → Service):**

1. **Controller:** Nhận `ownerId` từ header `X-User-Id`, chuyển đổi sang `UUID`. Gọi `classService.create(UUID.fromString(ownerId), request)`. Trả về `ResponseEntity` status `201 CREATED` kèm `ClassResponse`.
2. **Service `create`:**
   - Trim `name` và `semester` từ request.
   - **Kiểm tra trùng:** gọi `courseClassRepository.existsByOwnerIdAndNameAndSemester(ownerId, name, semester)`. Nếu đã tồn tại lớp cùng tên, cùng học kỳ, cùng chủ sở hữu → ném `BadRequestException("Class '<name>' already exists in semester <semester>")`. Uniqueness là theo owner (giảng viên), không phân biệt classes của giảng viên khác.
   - **Tạo entity:** xây dựng `CourseClass` với `ownerId`, `name`, `semester`, `status = ClassStatus.ACTIVE`.
   - **Lưu:** `courseClassRepository.save(courseClass)`.
   - **Trả về:** `classMapper.toResponse(courseClass)`.
   - Log `"Class created: id=..., name=..., semester=..."`.

**Ví dụ request:**
```http
POST /api/v1/classes
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
Content-Type: application/json

{
  "name": "Lập trình hướng đối tượng",
  "semester": "20261"
}
```

**Ví dụ response (201):**
```json
{
  "id": "03310ff7-b94f-423a-abf2-6332331c9471",
  "ownerId": "2be57808-9203-4150-8f29-19aecbe9f725",
  "name": "Lập trình hướng đối tượng",
  "semester": "20261",
  "status": "ACTIVE",
  "createdAt": "2026-11-01T03:15:35.384324Z"
}
```

**Mã lỗi có thể xảy ra:**
- `400 BadRequestException`: lớp đã tồn tại (cùng owner + tên + học kỳ), validation `@NotBlank` trên `name`/`semester`.
- `401/403`: không có quyền LECTURER.

---

### 3.2 `listMine` — Lấy danh sách lớp học của mình

**Vị trí:** `ClassController.listMine(...)` → `ClassService.listMine(...)`

**Endpoint:** `GET /api/v1/classes`

**Query params:**
| Param | Kiểu | Bắt buộc | Mặc định | Mô tả |
|-------|------|----------|----------|-------|
| `page` | int | — | 0 | Trang (0-based) |
| `size` | int | — | 20 | Kích thước trang |
| `search` | String | — | null | Chuỗi tìm kiếm có cấu trúc (ví dụ `name:PTIT;semester:20261`). Xem chi tiết ở `ClassFilter.parse` |
| `status` | ClassStatus | — | null | Lọc theo trạng thái: `ACTIVE` hoặc `ARCHIVED`; null = cả hai |

**Header đầu vào:** `X-User-Id`

**Luồng xử lý:**
1. Controller tạo `Pageable` với `PageRequest.of(page, size, Sort.by("createdAt").descending())` — sắp xếp giảm dần theo thời điểm tạo để kết quả phân trang ổn định (không bị bỏ qua hoặc trùng dòng giữa các trang).
2. Gọi `classService.listMine(UUID.fromString(ownerId), search, status, pageable)`.
3. Service gọi `ClassFilter.parse(search)` để phân tích chuỗi search thành `ClassFilter` (typed filter với `name` và `semester`). Validation (trường không xác định, thiếu `:`, giá trị blank, giới hạn) xảy ra ở đây, repository chỉ.compose specs từ đối tượng đã biết là tốt.
4. Gọi `courseClassRepository.findMine(ownerId, filter, status, pageable)` — sử dụng `JpaSpecificationExecutor.findAll` với các specification: `ownedBy(ownerId)`, `from(filter)`, `statusIs(status)`.
5. Map từng `CourseClass` sang `ClassResponse` qua `classMapper::toResponse`, trả về `Page<ClassResponse>`.

**Ví dụ request (tìm kiếm có cấu trúc):**
```http
GET /api/v1/classes?search=name:Lap%20trinh;semester:20261&status=ACTIVE&page=0&size=20
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):**
```json
{
  "content": [
    {
      "id": "03310ff7-b94f-423a-abf2-6332331c9471",
      "ownerId": "2be57808-9203-4150-8f29-19aecbe9f725",
      "name": "Lập trình hướng đối tượng",
      "semester": "20261",
      "status": "ACTIVE",
      "createdAt": "2026-11-01T03:15:35.384324Z"
    }
  ],
  "pageable": { "pageNumber": 0, "pageSize": 20, "sort": [{"property":"createdAt","direction":"DESC"}] },
  "totalElements": 1,
  "totalPages": 1,
  "last": true,
  ...
}
```

**Mã lỗi:**
- `400`: chuỗi `search` malformed (ví dụ token không có `:`, trường không xác định, giá trị blank) → `InvalidFilterException` từ `ClassFilter.parse`.

---

### 3.3 `getById` — Xem chi tiết lớp học

**Vị trí:** `ClassController.getById(...)` → `ClassService.getById(...)`

**Endpoint:** `GET /api/v1/classes/{id}`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`

**Luồng xử lý:**
1. Controller gọi `classService.getById(id, UUID.fromString(ownerId))`.
2. Service gọi `findOwned(id, ownerId)` → `courseClassRepository.findByIdAndOwnerId(id, ownerId)`.
3. Nếu không tìm thấy → ném `ResourceNotFoundException("Class not found: " + id)`.
4. Map sang `ClassResponse` qua `classMapper.toResponse`, trả về.

**Lưu ý về quyền:** Endpoint này không có `@PreAuthorize("hasRole('LECTURER')")`, nhưng vẫn owner-scoped qua `findByIdAndOwnerId`. Một id không sở hữu sẽ nhận 404 (không thể phân biệt với id không tồn tại). Điều này giữ tính bảo mật và cho phép mở rộng sau này cho sinh viên đăng ký.

**Ví dụ request:**
```http
GET /api/v1/classes/03310ff7-b94f-423a-abf2-6332331c9471
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):** Giống `ClassResponse` ở mục 2.2.

**Mã lỗi:** `404` nếu lớp không tồn tại hoặc không thuộc về giảng viên gọi.

---

### 3.4 `archive` — Lưu trữ lớp học

**Vị trí:** `ClassController.archive(...)` → `ClassService.archive(...)`

**Endpoint:** `PUT /api/v1/classes/{id}/archive`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`

**Luồng xử lý (Service `archive`):**
1. Gọi `findOwned(id, ownerId)`. Nếu không tìm thấy → `ResourceNotFoundException("Class not found: " + id)`.
2. Gán `courseClass.setStatus(ClassStatus.ARCHIVED)`.
3. Lưu qua `courseClassRepository.save(courseClass)`.
4. Trả về `ClassResponse` đã map (status = `ARCHIVED`).

**Ví dụ request:**
```http
PUT /api/v1/classes/03310ff7-b94f-423a-abf2-6332331c9471/archive
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):** `ClassResponse` với `status = "ARCHIVED"`.

**Mã lỗi:** `404` nếu lớp không tìm thấy.

---

### 3.5 `importStudents` — Nhập danh sách sinh viên từ CSV

**Vị trí:** `ClassController.importStudents(...)` → `ClassService.importStudents(...)`

**Endpoint:** `POST /api/v1/classes/{id}/students/import`

**Path variable:** `id` (UUID)

**Header đầu vào:** `X-User-Id`

**Request param (multipart):**
- `file` (MultipartFile, bắt buộc): file CSV chứa danh sách sinh viên.

**Luồng xử lý (Service `importStudents`):**

1. **Kiểm tra sở hữu lớp:** `findOwned(classId, ownerId)`. Nếu không tìm thấy → `ResourceNotFoundException("Class not found: " + classId)`.
2. **Kiểm tra file:** nếu `file == null` hoặc `file.isEmpty()` → `BadRequestException("CSV file is empty")`.
3. **Kiểm tra định dạng:** lấy `fileName = file.getOriginalFilename()`. Nếu null hoặc không kết thúc bằng `.csv` (không phân biệt hoa thường) → `BadRequestException("Only CSV files are accepted")`.
4. **Parse CSV:** gọi `parseCsv(file)` — đọc file theo UTF-8, dùng `BufferedReader`, tách dòng bởi dấu phẩy (`,`), giữ các trường trống (`split(",", -1)`). Dòng đầu tiên được coi là header nếu cột đầu tiên (trim) là `studentCode`, `mã sinh viên`, hoặc `ma_sv` → bỏ qua dòng header. Các dòng trống được bỏ qua.
   - **Ghi chú quan trọng (ponytail):** Chỉ split đơn giản, không dùng thư viện CSV. Header được skip bằng heuristic dòng đầu tiên.
5. **Duyệt từng dòng:**
   - Nếu `row.length < 2` hoặc `row[0]` trống → `skipped++`, tiếp tục dòng tiếp theo.
   - `studentCode = row[0].trim()`, `studentName = row[1].trim()`, `email = row.length > 2 ? row[2].trim() : null`.
   - **Quan trọng:** `student_user_id` được để cố định là `NULL` khi import CSV. Cột index 3 trong CSV (nếu có) có thể chứa một UUID **không phải là Keycloak subject (sub)**. Gán nó ở đây sẽ làm mất khớp vĩnh viễn giữa dòng roster và sub của sinh viên trong JWT, khiến sinh viên không hiển thị trên `GET /api/v1/student/classes`. `student_user_id` đúng được điền lazy bởi `StudentIdentityService.linkStudent()` khi sinh viên đọc lớp đầu tiên, dùng `X-User-Id` (JWT sub) được gateway stamp, khớp qua email. Xem `ClassStudentRepository.linkStudentIdentity()`.
   - Nếu `classStudentRepository.existsByClassIdAndStudentCode(classId, studentCode)` → `skipped++` (trùng mã sinh viên trong lớp), tiếp tục.
   - Lưu `ClassStudent` mới với `classId`, `studentCode`, `studentName`, `email`, `studentUserId = null`.
   - `imported++`.
6. Log `"Import finished for class {}: imported={}, skipped={}"`.
7. Trả về `new ImportResult(imported, skipped)`.

**Ví dụ request (multipart/form-data):**
```http
POST /api/v1/classes/03310ff7-b94f-423a-abf2-6332331c9471/students/import
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
Content-Type: multipart/form-data

file: (file CSV)
```

**Nội dung CSV mẫu:**
```
studentCode,studentName,email
b22dckh024,Nguyen Van A,nguyenvana@example.com
b22dckh025,Tran Thi B,tranthib@example.com
```

**Ví dụ response (200):**
```json
{
  "imported": 2,
  "skipped": 0
}
```

**Mã lỗi có thể xảy ra:**
- `404`: lớp không tồn tại hoặc không thuộc giảng viên gọi.
- `400`: file CSV rỗng, không phải định dạng CSV.
- `401/403`: không có quyền LECTURER.

---

### 3.6 `listStudents` — Lấy danh sách sinh viên trong lớp

**Vị trí:** `ClassController.listStudents(...)` → `ClassService.listStudents(...)`

**Endpoint:** `GET /api/v1/classes/{id}/students`

**Path variable:** `id` (UUID) — ID lớp học

**Header đầu vào:** `X-User-Id`

**Query params:**
| Param | Kiểu | Bắt buộc | Mặc định | Mô tả |
|-------|------|----------|----------|-------|
| `page` | int | — | 0 | Trang (0-based) |
| `size` | int | — | 20 | Kích thước trang |

**Luồng xử lý:**
1. Controller tạo `Pageable` với `PageRequest.of(page, size)` (không sort mặc định).
2. Gọi `classService.listStudents(id, UUID.fromString(ownerId), pageable)`.
3. Service gọi `findOwned(classId, ownerId)` để kiểm tra lớp tồn tại và sở hữu. Nếu không → `ResourceNotFoundException("Class not found: " + classId)`.
4. Gọi `classStudentRepository.findAllByClassId(classId, pageable)` → trả về `Page<ClassStudent>`.
5. Map từng `ClassStudent` sang `ClassStudentResponse` qua `classStudentMapper::toResponse`, trả về `Page<ClassStudentResponse>`.

**Ví dụ request:**
```http
GET /api/v1/classes/03310ff7-b94f-423a-abf2-6332331c9471/students?page=0&size=20
X-User-Id: 2be57808-9203-4150-8f29-19aecbe9f725
```

**Ví dụ response (200):**
```json
{
  "content": [
    {
      "id": "a1b2c3d4-...",
      "studentCode": "b22dckh024",
      "studentName": "Nguyen Van A",
      "email": "nguyenvana@example.com"
    },
    {
      "id": "e5f6g7h8-...",
      "studentCode": "b22dckh025",
      "studentName": "Tran Thi B",
      "email": null
    }
  ],
  "pageable": { "pageNumber": 0, "pageSize": 20, ... },
  "totalElements": 2,
  "totalPages": 1,
  "last": true,
  ...
}
```

**Mã lỗi:** `404` nếu lớp không tìm thấy.

---

## 4. Các hàm private helper trong ClassService

### 4.1 `findOwned(UUID id, UUID ownerId)`
- **Input:** id lớp, ownerId.
- **Output:** `Optional<CourseClass>`.
- **Làm gì:** Truy vấn `courseClassRepository.findByIdAndOwnerId(id, ownerId)`. Dùng ở `getById`, `archive`, `importStudents`, `listStudents` để kiểm soát sở hữu.

### 4.2 `parseCsv(MultipartFile file)` (static)
- **Input:** file CSV multipart.
- **Output:** `List<String[]>` các dòng đã tách cột.
- **Làm gì:** Đọc file UTF-8 qua `BufferedReader`. Dùng `line.split(",", -1)` để giữ các trường trống. Dòng đầu tiên nếu trông như header (`studentCode`, `mã sinh viên`, `ma_sv`) thì bỏ qua. Dòng trống bỏ qua. Nếu có `IOException` khi đọc → ném `IllegalStateException("Failed to read CSV file", e)`.

---

## 5. Mã lỗi tóm tắt

| Mã | Nguyên nhân | Ném từ |
|----|-------------|--------|
| 400 | Validation `@NotBlank` trên `name`/`semester` | Spring Validation / controller |
| 400 | Lớp đã tồn tại (cùng owner + tên + học kỳ) | `ClassService.create` |
| 400 | Chuỗi `search` malformed (trường không xác định, thiếu `:`, giá trị blank) | `ClassFilter.parse` → `InvalidFilterException` |
| 400 | File CSV rỗng | `ClassService.importStudents` |
| 400 | File không phải định dạng CSV | `ClassService.importStudents` |
| 404 | Lớp không tồn tại / không thuộc giảng viên gọi | `ClassService.findOwned` |
| 401/403 | Không có quyền LECTURER | Spring Security (`@PreAuthorize`) |

---

## 6. Luồng dữ liệu từ đầu đến cuối (ví dụ tạo lớp + import sinh viên)

```
Bước 1 — Tạo lớp:
Giảng viên (FE)
   │ POST /api/v1/classes + body {name, semester} + header X-User-Id
   ▼
Gateway (xác thực JWT, stamps X-User-Id)
   │
   ▼
course-service: ClassController.create()
   │ 1. Chuyển ownerId String → UUID
   │ 2. Gọi ClassService.create(ownerId, request)
   ▼
ClassService.create()
   │ 3. Trim name, semester
   │ 4. Kiểm tra trùng: existsByOwnerIdAndNameAndSemester
   │ 5. Tạo CourseClass (status=ACTIVE), lưu repository
   │ 6. Map → ClassResponse
   ▼
ClassController.create()
   │ 7. Trả về ResponseEntity 201 CREATED + ClassResponse
   ▼
Gateway → FE nhận lớp vừa tạo (có id)

Bước 2 — Import sinh viên vào lớp:
Giảng viên (FE)
   │ POST /api/v1/classes/{id}/students/import + file CSV + header X-User-Id
   ▼
course-service: ClassController.importStudents()
   │ 1. Chuyển ownerId String → UUID
   │ 2. Gọi ClassService.importStudents(id, ownerId, file)
   ▼
ClassService.importStudents()
   │ 3. Kiểm tra lớp tồn tại & sở hữu (findOwned)
   │ 4. Kiểm tra file không rỗng, định dạng .csv
   │ 5. parseCsv → tách dòng, bỏ qua header nếu có
   │ 6. Dùng dòng: kiểm tra trùng studentCode, lưu ClassStudent (studentUserId=null)
   │ 7. Trả về ImportResult{imported, skipped}
   ▼
ClassController.importStudents()
   │ 8. Trả về ResponseEntity.ok(ImportResult)
   ▼
Gateway → FE nhận {imported, skipped}
```

---

*Tài liệu này là phần tiếp theo của bộ dokument chi tiết luồng API theo plan mode, nằm trong thư mục `docs/api/docs/course-service/`. Các controller/service khác sẽ được viết tiếp theo theo cùng mẫu.*
