# ScoreService — tính điểm lớp học (course-service)

Tài liệu này đi vào **tầng service**, bổ sung cho `score-controller.md` (tầng HTTP).
Mỗi hàm ghi rõ: ai gọi, input, output, các bước xử lý, nhánh lỗi, và map entity ↔ DTO.

- Lớp: `vn.edu.ptit.web_grading_system.course_service.service.ScoreService`
- Controller gọi nó: `ScoreController`, `StudentClassController` (hàm `myScores`)
- Bảng DB: `score_components`, `student_scores`, `class_students`, `assignments`
- Dịch vụ ngoài: `result-service` (qua Feign `ResultServiceClient`)

---

## 1. Vai trò trong luồng nghiệp vụ

```
Giảng viên                    course-service                         result-service
   │                                │                                      │
   │ PUT /classes/{id}/score-components                                    │
   ├───────────────────────────────►│ replaceComponents()                   │
   │                                │  validateComponents()  (0.40, tổng 1) │
   │ PUT /classes/{id}/students/{code}/scores                              │
   ├───────────────────────────────►│ setStudentScores()                    │
   │                                │  (chặn EXERCISE nhập tay)             │
   │ GET /classes/{id}/students/{code}/scores                              │
   ├───────────────────────────────►│ getStudentScores() → buildScores()    │
   │                                │        │ computeExercise()           │
   │                                │        └── POST /internal/results/weighted ──►│
   │ GET /classes/{id}/transcript   │                                      │
   ├───────────────────────────────►│ transcript()                          │
   │                                │   └── POST /internal/results/weighted-batch ─►│
```

Quy ước quan trọng: **điểm `EXERCISE` không bao giờ nhập tay**. Nó luôn được tính từ
kết quả chấm tự động của các bài `GRADED` **đã publish** trong lớp.

---

## 2. Phụ thuộc (constructor injection)

| Thành phần | Dùng để |
|---|---|
| `CourseClassRepository` | `findByIdAndOwnerId` — kiểm tra lớp thuộc giảng viên đang gọi |
| `ScoreComponentRepository` | đọc/ghi `score_components` theo `classId` |
| `StudentScoreRepository` | đọc/ghi `student_scores` theo `(classId, studentCode, componentId)` |
| `ClassStudentRepository` | roster: `findByClassIdAndStudentCode`, `findAllByStudentUserId`, `findByClassIdFiltered` |
| `AssignmentRepository` | `findAllByClassIdAndPurposeAndPublished(classId, GRADED, true)` |
| `ScoreComponentMapper` | MapStruct: `ScoreComponent → ScoreComponentResponse` |
| `ResultServiceClient` | Feign: `weighted`, `weightedBatch` |
| `Tracer` | tạo span cho lời gọi Feign (Tempo) |

---

## 3. Hằng số và quy tắc

| Hằng số | Giá trị | Ý nghĩa |
|---|---|---|
| `ONE` | `1` | tổng trọng số hợp lệ |
| `WEIGHT_EPSILON` | `0.001` | sai số cho phép khi so tổng trọng số với 1 |
| `MIN_FINAL_EXAM_WEIGHT` | `0.40` | trọng số tối thiểu của `FINAL_EXAM` |

`ScoreComponentType` (enum, lưu dạng STRING):

| Giá trị | Nguồn điểm | Nhập tay? |
|---|---|---|
| `ATTENDANCE` | giảng viên nhập | có |
| `EXERCISE` | tự động: trung bình bài `GRADED` đã publish | **không** (400 nếu gửi) |
| `FINAL_EXAM` | giảng viên nhập | có (bắt buộc tồn tại, weight ≥ 0.40) |
| `ASSIGNMENT` | dự phòng/tương thích dữ liệu cũ | có — hiện không dùng trong luồng FE |

---

## 4. Bảng tổng hợp hàm public

| Hàm | Input | Output | Ghi DB | Gọi ngoài |
|---|---|---|---|---|
| `getComponents(classId, ownerId)` | 2 UUID | `List<ScoreComponentResponse>` | không | không |
| `replaceComponents(classId, ownerId, requests)` | 2 UUID + `List<ScoreComponentRequest>` | `List<ScoreComponentResponse>` | có (upsert + soft-delete) | không |
| `setStudentScores(classId, ownerId, studentCode, requests)` | 2 UUID + String + `List<StudentScoreRequest>` | `void` | có (upsert) | không |
| `getStudentScores(classId, ownerId, studentCode)` | 2 UUID + String | `StudentScoresResponse` | không | `weighted` |
| `getMyScores(classId, studentId)` | 2 UUID | `StudentScoresResponse` | không | `weighted` |
| `transcript(classId, ownerId, search, pageable)` | 2 UUID + String + `Pageable` | `Page<TranscriptEntryResponse>` | không | `weighted-batch` |

Hàm private: `buildScores`, `computeExercise`, `evaluateGrade`, `fetchBatchExerciseScores`,
`validateComponents`, `requireOwnedClass`, `requireStudentInClass`, `likePattern`,
`traceFeign` (2 overload), record `BatchExercise`.

---

## 5. Chi tiết từng hàm

### 5.1 `getComponents(UUID classId, UUID ownerId)`

Input:

| Tham số | Kiểu | Nguồn |
|---|---|---|
| `classId` | UUID | path variable `{id}` |
| `ownerId` | UUID | header `X-User-Id` do gateway đóng dấu từ JWT `sub` |

Xử lý:

1. `requireOwnedClass(classId, ownerId)` → 404 `Class not found: {classId}` nếu lớp không thuộc owner.
2. `scoreComponentRepository.findAllByClassId(classId)` (đã có `@SQLRestriction("deleted_at IS NULL")`).
3. Map từng entity qua `ScoreComponentMapper.toResponse`.

Output: `List<ScoreComponentResponse>` — mỗi phần tử `{type, weight}`; rỗng nếu lớp chưa cấu hình.

### 5.2 `replaceComponents(UUID classId, UUID ownerId, List<ScoreComponentRequest> requests)`

Đây là **PUT = thay toàn bộ bộ trọng số** (không phải merge từng phần tử).

Input mỗi phần tử (`ScoreComponentRequest`):

| Trường | Kiểu | Bắt buộc | Ràng buộc |
|---|---|---|---|
| `type` | `ScoreComponentType` | ✔ `@NotNull` | không trùng trong danh sách |
| `weight` | BigDecimal | ✔ `@NotNull` | `0.001 … 1.000` (`@DecimalMin/@DecimalMax`) |

Các bước:

1. `requireOwnedClass` → 404 nếu không sở hữu.
2. `validateComponents(requests)` → 400 nếu vi phạm (xem 5.2.1).
3. Nạp bản ghi hiện có vào `Map<type, ScoreComponent> existing`.
4. Với mỗi request: lấy entity khỏi map (`remove`) → có thì cập nhật `weight`, không có thì `build()` mới với `classId` + `type`; `save`.
5. Các entity **còn lại trong map** = loại bị bỏ khỏi request → set `deletedAt = now()`.
   Vì entity đang managed trong `@Transactional`, Hibernate dirty-checking ghi UPDATE khi commit
   (không cần gọi `save`).
6. Trả lại danh sách sau khi ghi (đọc lại từ DB, đã lọc bản ghi xoá mềm).

#### 5.2.1 `validateComponents` — 4 luật

| Luật | Kiểm tra | Thông điệp lỗi (400) |
|---|---|---|
| 1 | mỗi `type` xuất hiện 1 lần | `Duplicate component type: {TYPE}` |
| 2 | phải có `FINAL_EXAM` | `FINAL_EXAM component is required` |
| 3 | `weight(FINAL_EXAM) ≥ 0.40` | `FINAL_EXAM weight must be >= 0.40` |
| 4 | `abs(Σweight − 1) ≤ 0.001` | `Weights must sum to 1.000, got {sum}` |

Ví dụ hợp lệ: `ATTENDANCE 0.2 + EXERCISE 0.3 + FINAL_EXAM 0.5 = 1.0`.
Ví dụ sai: `ATTENDANCE 0.5 + FINAL_EXAM 0.3` → vi phạm luật 3 (0.3 < 0.4) **và** luật 4 (0.8 ≠ 1).

### 5.3 `setStudentScores(UUID classId, UUID ownerId, String studentCode, List<StudentScoreRequest> requests)`

Input mỗi phần tử (`StudentScoreRequest`):

| Trường | Kiểu | Bắt buộc | Ràng buộc |
|---|---|---|---|
| `componentType` | `ScoreComponentType` | ✔ | phải tồn tại trong cấu hình lớp |
| `score` | BigDecimal | ✔ | `0.00 … 10.00` |

Xử lý:

1. `requireStudentInClass(classId, ownerId, studentCode)`:
   - `requireOwnedClass` → 404 lớp;
   - `studentCode` trim; rỗng hoặc không có trong roster → 404 `Student '{code}' not found in class {classId}`.
2. Nạp cấu hình điểm của lớp → map `type → component`. Rỗng → 400 `No score components configured for class {classId}`.
3. Mỗi phần tử:
   - loại không có trong cấu hình → 400 `Unknown component type: {TYPE}`;
   - `EXERCISE` → 400 `EXERCISE is auto-graded from results, cannot set manually`;
   - tìm `student_scores` theo `(classId, studentCode, componentId)`; có → cập nhật `score`; chưa có → tạo mới.
4. Không trả body (`ResponseEntity<Void>`), không tính lại điểm tổng (điểm tổng tính khi đọc).

Ghi chú: gửi danh sách rỗng = no-op (không xoá điểm cũ).

### 5.4 `getStudentScores` / `getMyScores` / `buildScores`

| Hàm | Khác biệt |
|---|---|
| `getStudentScores(classId, ownerId, studentCode)` | giảng viên đọc theo mã sinh viên; kiểm tra ownership lớp + roster |
| `getMyScores(classId, studentId)` | sinh viên tự đọc; mã sinh viên suy ra từ `class_students.student_user_id`; không tìm thấy → 404 `Class not found: {classId}` |

Cả hai đều gọi `buildScores(classId, code)`. `getMyScores` có `@Transactional(readOnly = true)`;
nếu một user id ứng với nhiều dòng roster (dữ liệu bất thường) thì **dòng đầu tiên thắng**.

#### `buildScores(UUID classId, String code)` — thuật toán

```
components = findAllByClassId(classId)                      // thứ tự DB
manual     = {componentId → score} của (classId, code)      // student_scores
exercise   = computeExercise(classId, code)                 // 5.5, có thể null hoặc 0

entries = []
total = 0
complete = true
for c in components:
    score = (c.type == EXERCISE) ? exercise : manual[c.id]   // có thể null
    entries += {type: c.type, weight: c.weight, score: score}
    if score == null: complete = false
    else:             total += score * c.weight

finalTotal = complete ? total.setScale(2, HALF_UP) : null
grade      = evaluateGrade(finalTotal, entries)
return {studentCode: code, entries, total: finalTotal,
        letterGrade: grade?.display, gpa: grade?.gpa}
```

Điểm cần nhớ:

- `entries` **luôn đủ mọi thành phần** đã cấu hình, kể cả khi chưa có điểm (score = null).
- `total` chỉ có giá trị khi **tất cả** thành phần đều có điểm.
- Làm tròn **một lần duy nhất** ở cuối (`setScale(2, HALF_UP)`), không làm tròn từng tích.

Output (`StudentScoresResponse`):

| Trường | Kiểu | Ý nghĩa |
|---|---|---|
| `studentCode` | String | mã roster đã trim |
| `entries` | `List<StudentScoreEntryResponse>` | `{type, weight, score}` theo thứ tự cấu hình |
| `total` | BigDecimal | điểm 10 đã làm tròn 2 chữ số, hoặc `null` nếu chưa đủ |
| `letterGrade` | String | `A+ … F`, hoặc `null` nếu chưa đủ |
| `gpa` | BigDecimal | 4.0 … 0.0, hoặc `null` nếu chưa đủ |

### 5.5 `computeExercise(UUID classId, String studentCode)` — điểm bài tập tự động

Trả về `BigDecimal` hoặc `null`. Thứ tự nhánh rất quan trọng:

| # | Điều kiện | Trả về | Vì sao |
|---|---|---|---|
| 1 | dòng roster chưa liên kết tài khoản (`student_user_id == null`) | `ZERO` | chưa có tài khoản thì không thể nộp bài → 0 thật, không phải "chưa biết" |
| 2 | lớp **không có** bài `GRADED` nào đã publish | `null` | chưa có gì để chấm → thành phần chưa xác định |
| 3 | gọi `result-service` lỗi (timeout/5xx/không reachable) | `null` | sự cố hạ tầng, không được biến cả lớp thành 0 |
| 4 | `result-service` trả `average` có giá trị | giá trị đó | điểm bài tập thật |
| 5 | `result-service` trả `average == null` (ví dụ chỉ có 1 lần nộp `FAILED` không có step) | `ZERO` | đã có attempt nhưng không chấm được → 0 |

Bước 1–2 chạy trên DB nội bộ; bước 3–5 là lời gọi Feign
`POST /api/v1/internal/results/weighted` với body:

```json
{ "assignmentIds": ["<uuid>", "..."], "studentId": "<student_user_id>" }
```

`assignmentIds` = **chỉ** bài `purpose = GRADED` và `published = true` (bài `PRACTICE` không bao giờ
vào điểm lớp; bài draft không được kéo điểm cả lớp xuống).

Lời gọi được bọc `traceFeign("client.result-service.weighted", …)` để có span trên Tempo.

### 5.6 `evaluateGrade(BigDecimal finalTotal, List<StudentScoreEntryResponse> entries)`

```
if finalTotal == null           → null            (chưa đủ điểm, không xếp loại)
if có entry.score <= 0          → F               (0 ở bất kỳ thành phần nào = F)
if finalTotal < 4.00            → F
else                            → LetterGrade.fromTotal(finalTotal)
```

Bảng quy đổi (`LetterGrade`, cận dưới **bao gồm**):

| Tổng điểm | Điểm chữ | GPA |
|---|---|---|
| ≥ 9.00 | A+ | 4.0 |
| ≥ 8.50 | A | 3.7 |
| ≥ 8.00 | B+ | 3.5 |
| ≥ 7.00 | B | 3.0 |
| ≥ 6.50 | C+ | 2.5 |
| ≥ 5.50 | C | 2.0 |
| ≥ 5.00 | D+ | 1.5 |
| ≥ 4.00 | D | 1.0 |
| < 4.00 hoặc có thành phần = 0 | F | 0.0 |

### 5.7 `transcript(UUID classId, UUID ownerId, String search, Pageable pageable)`

Mục đích: bảng điểm cả lớp, **một dòng / một sinh viên**, có lọc và phân trang.

Các bước:

1. `requireOwnedClass` → 404 nếu không sở hữu.
2. Nạp cấu hình điểm của lớp (`components`).
3. `classStudentRepository.findByClassIdFiltered(classId, likePattern(search), pageable)`:
   - `search` null/rỗng → không lọc;
   - ngược lại: lower-case + escape `\`, `%`, `_`, bọc `%…%`, so với **mã sinh viên hoặc tên**;
   - roster rỗng → trả `Page.empty(pageable)` (total = 0).
4. Lấy toàn bộ `student_scores` của lớp, giữ lại các dòng thuộc trang hiện tại, gom theo `studentCode`.
5. Lấy `assignmentIds` = bài `GRADED` đã publish của lớp.
6. Lấy `studentUserIds` của trang (bỏ null).
7. `fetchBatchExerciseScores(assignmentIds, studentUserIds)` → **1 lời gọi HTTP cho cả trang**.
8. Với từng sinh viên: dựng `entries` như `buildScores`, tính `total`, `letterGrade`, `gpa`.
9. Trả `PageImpl(entries, pageable, rosterPage.getTotalElements())`.

Output (`TranscriptEntryResponse`):

| Trường | Kiểu | Ghi chú |
|---|---|---|
| `studentCode`, `studentName` | String | từ roster |
| `entries` | `List<StudentScoreEntryResponse>` | đủ thành phần, score có thể null |
| `total`, `letterGrade`, `gpa` | BigDecimal/String/BigDecimal | null khi chưa đủ |

`likePattern` là hàm private static: escape **backslash trước**, rồi `%`, rồi `_`
(nếu làm ngược thứ tự, escape vừa thêm sẽ bị escape lần hai).

### 5.8 `fetchBatchExerciseScores` + record `BatchExercise`

```java
private record BatchExercise(Map<UUID, BigDecimal> scores, boolean usable) {
    static BatchExercise ungradable() { return new BatchExercise(Map.of(), false); }
    static BatchExercise of(Map<UUID, BigDecimal> scores) {
        return new BatchExercise(scores != null ? scores : Map.of(), true);
    }
}
```

| Nhánh | `usable` | `scores` | Ý nghĩa |
|---|---|---|---|
| `assignmentIds` rỗng | `false` | rỗng | chưa publish bài nào để chấm |
| `studentUserIds` rỗng | `true` | rỗng | cả trang chưa liên kết tài khoản → mỗi em 0 điểm |
| Feign lỗi | `false` | rỗng | sự cố result-service |
| Feign OK | `true` | map `studentUserId → điểm` | em vắng mặt trong map = chưa nộp = 0 |

Cách transcript đọc kết quả:

| `studentUserId` | `usable` | `exercise` |
|---|---|---|
| `null` | bất kỳ | `0` |
| khác null | `false` | `null` (tổng để trống) |
| khác null | `true`, có trong map | giá trị trong map |
| khác null | `true`, không có trong map | `0` |

### 5.9 Các helper

| Helper | Việc làm | Lỗi |
|---|---|---|
| `requireOwnedClass(classId, ownerId)` | `findByIdAndOwnerId` | 404 `Class not found: {id}` |
| `requireStudentInClass(classId, ownerId, code)` | gọi `requireOwnedClass`, trim code, kiểm tra roster | 404 `Student '{code}' not found in class {id}` |
| `likePattern(search)` | chuẩn hoá `%search%` đã escape | không |
| `traceFeign(name, Supplier)` | mở span, ghi error, đóng span | ném lại exception gốc |
| `traceFeign(name, Runnable)` | như trên cho lời gọi `void` | ném lại exception gốc |

---

## 6. Map entity ↔ DTO

### 6.1 `ScoreComponentMapper` (MapStruct, `componentModel = "spring"`)

| Entity `ScoreComponent` | DTO `ScoreComponentResponse` | Ghi chú |
|---|---|---|
| `type` | `type` | cùng enum |
| `weight` | `weight` | giữ nguyên scale DB (`0.2000`) |
| `id`, `classId`, `createdAt`, `deletedAt` | — | không expose |

### 6.2 `StudentScore` → `StudentScoreEntryResponse` (map thủ công trong `buildScores`)

| Nguồn | Đích | Quy tắc |
|---|---|---|
| `ScoreComponent.type` | `type` | |
| `ScoreComponent.weight` | `weight` | |
| `EXERCISE` → `exercise`; khác → `student_scores.score` | `score` | `null` khi chưa có |

### 6.3 `ClassStudent` + điểm → `TranscriptEntryResponse`

| Nguồn | Đích |
|---|---|
| `ClassStudent.studentCode` | `studentCode` |
| `ClassStudent.studentName` | `studentName` |
| vòng lặp `components` | `entries[]` |
| tổng có trọng số | `total` |
| `evaluateGrade(...)` | `letterGrade`, `gpa` |

---

## 7. Công thức và ví dụ số

### 7.1 Điểm tổng lớp

```
total = Σ (score_i × weight_i)      với mọi thành phần đã có điểm
total = round_half_up(total, 2)
```

Ví dụ: `ATTENDANCE 0.2 → 8.5`, `EXERCISE 0.3 → 7.25`, `FINAL_EXAM 0.5 → 7.0`

```
0.2×8.5 = 1.700
0.3×7.25 = 2.175
0.5×7.0  = 3.500
tổng     = 7.375  → 7.38  → hạng B (≥7.00), GPA 3.0
```

### 7.2 Quy tắc "có thành phần 0 là F"

`ATTENDANCE 0`, `EXERCISE 10`, `FINAL_EXAM 9` với trọng số 0.2/0.3/0.5:

```
0 + 3.0 + 4.5 = 7.50  → bảng sẽ cho B, nhưng vì ATTENDANCE = 0 nên kết quả là F, GPA 0.0
```

Điểm 0 là **dữ liệu hợp lệ** (không phải "thiếu điểm"), nên nó vừa kéo tổng xuống vừa kích hoạt F.

### 7.3 Điểm `EXERCISE` (do result-service tính)

Hai tầng:

```
1) trong 1 bài tập:  Σ(score_plan × weight_plan) / Σ(weight_plan)     // plan chưa nộp = 0, vẫn cộng weight
2) giữa các bài:     trung bình cộng các giá trị tầng 1               // mỗi bài một phiếu
```

Ví dụ tầng 1 (bài có 4 plan, weight 100/100/100/10; plan cuối chưa nộp):

```
(10×100 + 10×100 + 9×100 + 0×10) / 310 = 2900/310 = 9.354839
```

Ví dụ tầng 2 (bài A = 7.25, bài B = 10.00):

```
(7.25 + 10.00) / 2 = 8.625 → 8.63
```

Nếu cộng thẳng mọi plan của mọi bài (cách cũ) thì một bài 4 plan weight 100 sẽ đè bài 1 plan
weight 10 theo tỉ lệ 40:1 — đó là lý do phải tách hai tầng.

### 7.4 Làm tròn: chỉ ở cuối

3 plan điểm 10 / 10 / 9 cùng weight, bài thứ hai 1 plan điểm 10:

```
tầng 1 bài A = 29/3 = 9.666667   (scale 6, chưa làm tròn hiển thị)
tầng 2       = (9.666667 + 10) / 2 = 9.833333 → 9.83
nếu làm tròn sớm: (9.67 + 10)/2 = 9.835 → 9.84   ← sai 0.01
```

Đây là lý do `maxPerPlanAverage` dùng scale 6 ở tầng 1 và chỉ `setScale(2)` ở kết quả cuối.

---

## 8. Ma trận "null hay 0" cho `EXERCISE`

| Tình huống | `getStudentScores` (1 em) | `transcript` (batch) |
|---|---|---|
| Roster chưa liên kết tài khoản | `0` → có tổng | `0` → có tổng |
| Lớp chưa publish bài `GRADED` nào | `null` → tổng trống | `null` → tổng trống |
| `result-service` lỗi | `null` → tổng trống | `null` → tổng trống |
| Có bài publish, sinh viên chưa nộp | `0` → có tổng | `0` → có tổng |
| Chỉ có 1 lần nộp `FAILED` không có step | `0` → có tổng | `0` → có tổng |

Dòng cuối từng là **khác biệt giữa hai đường đọc**: `result-service` trả `null` cho em đó trong
batch (map **có key nhưng value null**), và `Map.getOrDefault(key, ZERO)` trả lại chính `null` —
khiến bảng điểm lớp trống trong khi tab điểm cá nhân vẫn có tổng. Đã sửa 2026-11-22: `transcript`
đọc giá trị rồi mới fallback (`scored != null ? scored : ZERO`), nên khi `usable = true` thì
`null` được coi là `0` giống `computeExercise`. Test:
`transcript_nullBatchValue_countsExerciseAsZeroLikeSingleRead` và
`transcript_batchUnusable_leavesTotalNull` (13/13 trong `ScoreServiceTest`).

---

## 9. Bảng lỗi

| HTTP | Nguồn | Thông điệp |
|---|---|---|
| 404 | `requireOwnedClass` | `Class not found: {classId}` |
| 404 | `requireStudentInClass` | `Student '{code}' not found in class {classId}` |
| 400 | `validateComponents` | `Duplicate component type: {TYPE}` |
| 400 | `validateComponents` | `FINAL_EXAM component is required` |
| 400 | `validateComponents` | `FINAL_EXAM weight must be >= 0.40` |
| 400 | `validateComponents` | `Weights must sum to 1.000, got {sum}` |
| 400 | `setStudentScores` | `No score components configured for class {classId}` |
| 400 | `setStudentScores` | `Unknown component type: {TYPE}` |
| 400 | `setStudentScores` | `EXERCISE is auto-graded from results, cannot set manually` |
| 400 | bean validation | `Validation failed` + chi tiết từng trường (`errors`) |
| 403 | Spring Security | token không có `ROLE_LECTURER` (endpoint giảng viên) |

`IllegalArgumentException` và `BadRequestException` đều map về 400 trong
`GlobalExceptionHandler` của course-service.

---

## 10. Luồng dữ liệu (plain text)

```
PUT /classes/{id}/score-components
  body: [{type, weight}, ...]
    → ScoreController.replaceComponents
    → requireOwnedClass                        (course_class, owner_id)
    → validateComponents                       (trùng? FINAL_EXAM? 0.40? tổng 1?)
    → upsert score_components + soft-delete phần bỏ
    → 200 [{type, weight}, ...]

PUT /classes/{id}/students/{code}/scores
  body: [{componentType, score}, ...]
    → ScoreController.setStudentScores
    → requireStudentInClass                    (class_students)
    → chặn EXERCISE / loại lạ
    → upsert student_scores (class_id, student_code, component_id)
    → 204

GET /classes/{id}/students/{code}/scores
    → ScoreController.getStudentScores
    → buildScores
        ├── score_components
        ├── student_scores
        └── computeExercise
              ├── class_students.student_user_id
              ├── assignments (GRADED + published)
              └── POST result-service /internal/results/weighted
    → 200 {studentCode, entries[], total, letterGrade, gpa}

GET /classes/{id}/transcript?search=&page=&size=
    → ScoreController.transcript
    → requireOwnedClass
    → class_students (lọc theo mã/tên, phân trang)
    → student_scores của lớp
    → assignments (GRADED + published)
    → POST result-service /internal/results/weighted-batch   (1 lần cho cả trang)
    → 200 Page{content:[{studentCode, studentName, entries[], total, letterGrade, gpa}], meta}
```

---

## 11. Ghi chú triển khai

- Mọi endpoint đều **owner-scoped**: `ownerId` lấy từ header gateway đóng dấu, không tin body/query.
- Đọc điểm không bao giờ ném lỗi vì `result-service` chết — chỉ để `total = null`.
- `student_scores` là nguồn duy nhất cho `ATTENDANCE`/`FINAL_EXAM`; `EXERCISE` **không** có dòng
  trong bảng này.
- Soft-delete: `score_components` bị bỏ khỏi PUT sẽ có `deleted_at`, nên
  `findAllByClassId` không trả lại; dữ liệu `student_scores` cũ vẫn còn nhưng không được đọc.
- Hai lời gọi Feign đều có span riêng nhờ `traceFeign` (Review 2026-11-09, PR #93).
