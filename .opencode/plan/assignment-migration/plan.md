# Plan: Bài tập luyện tập theo chủ đề / Practice exercises by topic

## 0. Mục đích / Purpose

Thêm khái niệm "bài tập luyện tập theo chủ đề": giảng viên tạo bài tập, chia theo chủ đề, không tính vào điểm thành phần của lớp, nhưng sinh viên vẫn được nộp bài và xem kết quả chấm (đâu đúng/đâu sai).

Add "practice exercises by topic": lecturers create exercises grouped by topic, not counted toward the class score component, but students can still submit and see grading results (which questions pass/fail).

---

## 1. Quyết định cuối cùng (đã chốt) / Final decisions

| Yêu cầu | Cách làm | Requirement | Decision |
|---|---|---|---|
| Có chấm, xem chi tiết câu đúng/sai | Giữ nguyên executor/result-service; practice vẫn chạy pipeline chấm như assignment thường | Graded, see pass/fail detail | Keep executor/result-service unchanged; practice runs same grading pipeline |
| Điểm không vào điểm thành phần | `ScoreService.computeExercise` chỉ lấy `purpose = GRADED` | Score not in component | `ScoreService.computeExercise` filters `purpose = GRADED` |
| Độc lập ngoài lớp | `assignments.class_id` cho phép `NULL`; practice có `class_id = NULL` | Independent of class | `assignments.class_id` nullable; practice `class_id = NULL` |
| Mọi bài đều có topic | Backfill cũ bằng `Chung`; DB `topic NOT NULL`; API `@NotBlank` | Every assignment has topic | Backfill legacy rows to `Chung`; DB `topic NOT NULL`; API `@NotBlank` |
| Filter/tìm theo topic | Cột `topic` + query param `topic` + search khớp title/topic + endpoint danh sách topic | Filter/search by topic | `topic` column + `topic` param + title/topic search + distinct-topics endpoint |
| Không trùng tên với bất kỳ bài nào | Check unique theo `owner_id + title` (case-insensitive) | No duplicate title per owner | Unique by `owner_id + title`, case-insensitive |
| Sinh viên thấy practice | Published practice hiển thị cho mọi sinh viên, không cần enrollment | Students see practice | Published practice visible to all students, no enrollment needed |

---

## 2. Phạm vi / Scope

**Thay đổi**: chỉ `course-service` + `frontend`.
**Không đụng tới**: `submission-service`, `executor-service`, `result-service`, migration V1–V6.

**Changed**: only `course-service` + `frontend`.
**Untouched**: `submission-service`, `executor-service`, `result-service`, migrations V1–V6.

---

## 3. Cơ sở dữ liệu — course-service / Database — course-service

Tạo migration mới `V7__2026-10-26__assignment_purpose_topic.sql` (đã có file, chưa commit):

```sql
ALTER TABLE assignments ALTER COLUMN class_id DROP NOT NULL;

ALTER TABLE assignments ADD COLUMN IF NOT EXISTS purpose VARCHAR(20) NOT NULL DEFAULT 'GRADED';
ALTER TABLE assignments ADD COLUMN IF NOT EXISTS topic VARCHAR(255);

-- topic bắt buộc: backfill dòng cũ rồi siết NOT NULL
UPDATE assignments SET topic = 'Chung' WHERE topic IS NULL OR btrim(topic) = '';
ALTER TABLE assignments ALTER COLUMN topic SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_assignments_owner_purpose
    ON assignments(owner_id, purpose) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_assignments_topic
    ON assignments(topic) WHERE deleted_at IS NULL;
```

- Không sửa V1–V6 (dùng migration mới, tuân thủ rule "không sửa migration đã apply").
- Dòng cũ tự `GRADED` + `topic = 'Chung'` → tương thích ngược.
- Rollback: drop 2 cột + index, khôi phục `class_id NOT NULL` sau khi xóa practice.

Create new migration `V7__2026-10-26__assignment_purpose_topic.sql` (file exists, uncommitted):

```sql
ALTER TABLE assignments ALTER COLUMN class_id DROP NOT NULL;

ALTER TABLE assignments ADD COLUMN IF NOT EXISTS purpose VARCHAR(20) NOT NULL DEFAULT 'GRADED';
ALTER TABLE assignments ADD COLUMN IF NOT EXISTS topic VARCHAR(255);

-- topic mandatory: backfill old rows then enforce NOT NULL
UPDATE assignments SET topic = 'Chung' WHERE topic IS NULL OR btrim(topic) = '';
ALTER TABLE assignments ALTER COLUMN topic SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_assignments_owner_purpose
    ON assignments(owner_id, purpose) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_assignments_topic
    ON assignments(topic) WHERE deleted_at IS NULL;
```

- Do not edit V1–V6 (new migration, comply with "do not modify applied migrations" rule).
- Legacy rows become `GRADED` + `topic = 'Chung'` → backward compatible.
- Rollback: revert code; drop columns + index; restore `class_id NOT NULL` after deleting practices.

---

## 4. Backend — course-service

### 4.1 Entity / DTO / Entity / DTO

**Mới**: `entity/AssignmentPurpose.java` (`GRADED`, `PRACTICE`) — đã có file.

**New**: `entity/AssignmentPurpose.java` (`GRADED`, `PRACTICE`) — already created.

**Assignment.java**: `classId` nullable; thêm `purpose` (default `GRADED`), `topic`.

**Assignment.java**: `classId` nullable; add `purpose` (default `GRADED`), `topic`.

**CreateAssignmentRequest**: bỏ `@NotNull classId`; thêm `purpose`; `topic` **`@NotBlank`**.

**CreateAssignmentRequest**: remove `@NotNull classId`; add `purpose`; `topic` **`@NotBlank`**.

**UpdateAssignmentRequest**: thêm `topic` **`@NotBlank`** (update là full-update, giống `title`); không cho đổi `purpose`/`classId`.

**UpdateAssignmentRequest**: add `topic` **`@NotBlank`** (full-update semantics like `title`); no change to `purpose`/`classId`.

**AssignmentResponse**: thêm `purpose`, `topic` (MapStruct enum → String).

**AssignmentResponse**: add `purpose`, `topic` (MapStruct enum → String).

### 4.2 Repository / Repository

`AssignmentRepository`:
- `findAllByClassIdAndPurpose(UUID classId, AssignmentPurpose purpose)` — dùng cho ScoreService.
- `existsByOwnerIdAndTitleIgnoreCase(UUID ownerId, String title)` + `...AndIdNot(...)`.
- `findMine(ownerId, classId, purpose, topic, published, search, pageable)` — thêm `purpose`, `topic`; `search` khớp `title` **hoặc** `topic`.
- `findPublishedForStudent(classIds, classId, purpose, topic, search, pageable)` — chỉ GRADED.
- `findPublishedPractice(topic, search, pageable)` — published + PRACTICE + `classId is null`.
- `findDistinctTopics(ownerId, purpose, classId?)`.
- `findDistinctPublishedTopics(purpose)`.

`AssignmentRepository`:
- `findAllByClassIdAndPurpose(UUID classId, AssignmentPurpose purpose)` — for ScoreService.
- `existsByOwnerIdAndTitleIgnoreCase(UUID ownerId, String title)` + `...AndIdNot(...)`.
- `findMine(ownerId, classId, purpose, topic, published, search, pageable)` — add `purpose`, `topic`; `search` matches `title` **or** `topic`.
- `findPublishedForStudent(classIds, classId, purpose, topic, search, pageable)` — GRADED only.
- `findPublishedPractice(topic, search, pageable)` — published + PRACTICE + `classId is null`.
- `findDistinctTopics(ownerId, purpose, classId?)`.
- `findDistinctPublishedTopics(purpose)`.

`ClassStudentRepository`: thêm `findAllByStudentUserIdIn(Collection<UUID>)` để enrich code/name cho practice (không có roster lớp).

`ClassStudentRepository`: add `findAllByStudentUserIdIn(Collection<UUID>)` to enrich code/name for practice (no class roster).

### 4.3 Service / Service

**AssignmentService.create**:
- `GRADED`: bắt buộc `classId`, kiểm tra class thuộc owner.
- `PRACTICE`: bắt buộc `classId == null` (nếu gửi classId → 400).
- `topic`: trim, bắt buộc cả 2 loại.
- Unique title theo owner (case-insensitive) trên toàn bộ assignment (không phân biệt purpose).

**AssignmentService.create**:
- `GRADED`: `classId` required, verify class owned by owner.
- `PRACTICE`: `classId` must be null (400 if provided).
- `topic`: trimmed, required for both types.
- Unique title per owner (case-insensitive) across all assignments (regardless of purpose).

**AssignmentService.update**: không đổi `purpose`/`classId`; cập nhật `topic`; check unique title.

**AssignmentService.update**: no change to `purpose`/`classId`; update `topic`; check unique title.

**listMine(...)** thêm `purpose`, `topic`; `listTopics(ownerId, purpose)`.

**listMine(...)** add `purpose`, `topic`; `listTopics(ownerId, purpose)`.

**StudentAssignmentService**:
- `listAssignments(...)`: `purpose` mặc định `GRADED`.
  - `PRACTICE` → `findPublishedPractice(topic, search, pageable)`, bỏ qua enrollment và `classIds.isEmpty()`.
  - `GRADED` → query cũ + `purpose = GRADED`.
- `requireVisible`: practice chỉ cần `published = true`; graded vẫn check enrollment.
- `listTopics()` cho practice.

**StudentAssignmentService**:
- `listAssignments(...)`: `purpose` default `GRADED`.
  - `PRACTICE` → `findPublishedPractice(topic, search, pageable)`, ignore enrollment & empty `classIds`.
  - `GRADED` → existing query + `purpose = GRADED`.
- `requireVisible`: practice needs only `published = true`; graded keeps enrollment check.
- `listTopics()` for practice.

**ScoreService**:
- `computeExercise` đổi `findAllByClassId(classId)` → `findAllByClassIdAndPurpose(classId, GRADED)` (dòng ~204). Practice có `class_id NULL` nên cũng không lọt, nhưng filter tường minh để an toàn.

**ScoreService**:
- `computeExercise` changes `findAllByClassId(classId)` → `findAllByClassIdAndPurpose(classId, GRADED)` (line ~204). Practice has `class_id NULL` so it's excluded anyway, but explicit filter for safety.

**AssignmentGradingService**:
- `rosterByUserId(null)` → `Map.of()`.
- Khi `classId == null`: enrich identity (code/name) của các `student_user_id` có kết quả/submission qua `findAllByStudentUserIdIn`; không synthesize học viên chưa nộp.
- `results`/`submissions` vẫn dùng chung endpoint.

**AssignmentGradingService**:
- `rosterByUserId(null)` → `Map.of()`.
- When `classId == null`: enrich identity (code/name) of `student_user_id`s having results/submissions via `findAllByStudentUserIdIn`; no synthesis of non-submitters.
- `results`/`submissions` keep same endpoint.

### 4.4 Controller / API / Controller / API

`AssignmentController` (LECTURER):
- `GET /api/v1/assignments` thêm `purpose`, `topic`.
- `GET /api/v1/assignments/topics?purpose=&classId=` → `string[]`.
- `POST/PUT` nhận thêm `purpose`/`topic`.

`AssignmentController` (LECTURER):
- `GET /api/v1/assignments` add `purpose`, `topic`.
- `GET /api/v1/assignments/topics?purpose=&classId=` → `string[]`.
- `POST/PUT` accept `purpose`/`topic`.

`StudentAssignmentController`:
- `GET /api/v1/student/assignments` thêm `purpose` (default `GRADED`), `topic`.
- `GET /api/v1/student/assignments/topics` → topic của practice đã publish.

`StudentAssignmentController`:
- `GET /api/v1/student/assignments` add `purpose` (default `GRADED`), `topic`.
- `GET /api/v1/student/assignments/topics` → published practice topics.

Không đổi submission-service / executor-service / result-service.

Do not change submission-service / executor-service / result-service.

---

## 5. Frontend / Frontend

### 5.1 Types & API / Types & API

`shared/types/assignment.ts`:
- `export type AssignmentPurpose = 'GRADED' | 'PRACTICE'`.
- `AssignmentResponse.classId: string | null`, thêm `purpose: AssignmentPurpose`, `topic: string`.
- `CreateAssignmentRequest.topic` bắt buộc, `classId?`, `purpose?`.
- `UpdateAssignmentRequest.topic` bắt buộc.

`shared/types/assignment.ts`:
- `export type AssignmentPurpose = 'GRADED' | 'PRACTICE'`.
- `AssignmentResponse.classId: string | null`, add `purpose: AssignmentPurpose`, `topic: string`.
- `CreateAssignmentRequest.topic` required, `classId?`, `purpose?`.
- `UpdateAssignmentRequest.topic` required.

`shared/api/endpoints/assignments.ts`:
- `listAssignments({ classId?, purpose?, topic?, page, size, search?, published? })`.
- `listAssignmentTopics(purpose, classId?)`.

`shared/api/endpoints/assignments.ts`:
- `listAssignments({ classId?, purpose?, topic?, page, size, search?, published? })`.
- `listAssignmentTopics(purpose, classId?)`.

`shared/api/endpoints/studentAssignments.ts`:
- `listStudentAssignments(page, size, search?, classId?, purpose?, topic?)`.
- `listStudentPracticeTopics()`.

`shared/api/endpoints/studentAssignments.ts`:
- `listStudentAssignments(page, size, search?, classId?, purpose?, topic?)`.
- `listStudentPracticeTopics()`.

`useAssignments` refactor sang options object `{ classId?, purpose?, topic?, page, pageSize, refreshToken }`.

`useAssignments` refactor to options object `{ classId?, purpose?, topic?, page, pageSize, refreshToken }`.

### 5.2 Lecturer / Lecturer

- `CreateAssignmentModal`: prop `purpose` (default GRADED); field **Chủ đề** bắt buộc, hiện ở cả 2 mode; payload có `purpose`/`topic`.
- `EditAssignmentModal`: field Chủ đề bắt buộc; prefill `record.topic ?? ''`.
- `AssignmentTab`: thêm cột Topic + filter topic (graded, theo class).
- Trang mới `features/practice/PracticePage.tsx`:
  - `ListPage` gọi `listAssignments({ purpose: 'PRACTICE', topic, ... })`.
  - Filter: `search` (text) + `topic` (select từ `listAssignmentTopics('PRACTICE')`).
  - Cột: title, topic (Tag), status, createdAt, actions (Results, Submissions, Publish, Delete, Edit).
  - Expand row → `TestPlanEditor` để soạn đề/chấm.
  - Nút "Tạo bài luyện tập" → `CreateAssignmentModal purpose="PRACTICE"` (không classId).

- `CreateAssignmentModal`: prop `purpose` (default GRADED); required **Chủ đề** field in both modes; payload with `purpose`/`topic`.
- `EditAssignmentModal`: required Chủ đề field; prefill `record.topic ?? ''`.
- `AssignmentTab`: add Topic column + topic filter (graded, per class).
- New page `features/practice/PracticePage.tsx`:
  - `ListPage` calls `listAssignments({ purpose: 'PRACTICE', topic, ... })`.
  - Filters: `search` (text) + `topic` (select from `listAssignmentTopics('PRACTICE')`).
  - Columns: title, topic (Tag), status, createdAt, actions (Results, Submissions, Publish, Delete, Edit).
  - Expand row → `TestPlanEditor` to author plan/grading.
  - Button "Tạo bài luyện tập" → `CreateAssignmentModal purpose="PRACTICE"` (no classId).

### 5.3 Student / Student

- `StudentAssignmentsPage` + `StudentClassAssignmentsTab`: thêm cột Topic + filter topic (graded).
- Trang mới `features/student/practice/StudentPracticePage.tsx`:
  - `listStudentAssignments(page, size, search, undefined, 'PRACTICE', topic)`.
  - Filter search + topic select.
  - Cột: title (link `/student/practice/:id`), topic, actions Xem/Nộp.
- `StudentAssignmentDetailPage`: nút Back chọn `/student/practice` nếu path bắt đầu bằng `/student/practice`, ngược lại `/student/assignments`.

- `StudentAssignmentsPage` + `StudentClassAssignmentsTab`: add Topic column + topic filter (graded).
- New page `features/student/practice/StudentPracticePage.tsx`:
  - `listStudentAssignments(page, size, search, undefined, 'PRACTICE', topic)`.
  - Filters: search + topic select.
  - Columns: title (link `/student/practice/:id`), topic, actions View/Submit.
- `StudentAssignmentDetailPage`: Back button chooses `/student/practice` when path starts with `/student/practice`, else `/student/assignments`.

### 5.4 Reuse results/submissions / Reuse results/submissions

- `AssignmentResultsPage` / `AssignmentSubmissionsPage`: `useParams<{ classId?: string; assignmentId: string }>`.
  - Base path: `classId ? /classes/${classId}/assignments/${id} : /practice/${id}`.
  - Ẩn filter chọn sinh viên khi không có `classId` (practice không có roster).
  - `useAssignmentStudents(classId ?? '')` đã tự disable khi rỗng.

- `AssignmentResultsPage` / `AssignmentSubmissionsPage`: `useParams<{ classId?: string; assignmentId: string }>`.
  - Base path: `classId ? /classes/${classId}/assignments/${id} : /practice/${id}`.
  - Hide student filter when no `classId` (practice has no roster).
  - `useAssignmentStudents(classId ?? '')` already disabled when empty.

### 5.5 Router / nav / i18n / Router / nav / i18n

Routes:
- `/practice`, `/practice/:assignmentId/results`, `/practice/:assignmentId/submissions` (LECTURER).
- `/student/practice`, `/student/practice/:id` (STUDENT).

Routes:
- `/practice`, `/practice/:assignmentId/results`, `/practice/:assignmentId/submissions` (LECTURER).
- `/student/practice`, `/student/practice/:id` (STUDENT).

`AppLayout`: thêm menu "Bài luyện tập" cho lecturer và student.

`AppLayout`: add "Practice exercises" menu for lecturer and student.

`locales/vi.json` + `locales/en.json`: thêm key `nav.practiceExercises`, `nav.practice`, nhóm `practice.*`, `assignment.purpose*`, `assignment.topic*` (giữ parity vi/en).

`locales/vi.json` + `locales/en.json`: add keys `nav.practiceExercises`, `nav.practice`, groups `practice.*`, `assignment.purpose*`, `assignment.topic*` (keep vi/en parity).

---

## 6. Test / Tests

Backend:
- `AssignmentServiceTest`: cập nhật tên method repo mới; thêm case tạo PRACTICE (classId null, topic), chặn PRACTICE có classId, chặn trùng title giữa GRADED/PRACTICE cùng owner, cho phép trùng title giữa 2 owner khác nhau.
- `StudentAssignmentServiceTest`: practice published visible dù không enrollment; GRADED vẫn 404 khi không enrolled; list mặc định GRADED.
- `AssignmentGradingServiceTest`: assignment `classId = null` không NPE, không synthesize roster.
- `ScoreServiceTest`: verify chỉ GRADED được truyền sang result-service (`findAllByClassIdAndPurpose(classId, GRADED)`).
- Chạy `./mvnw test` (course-service).

Backend:
- `AssignmentServiceTest`: update repo method names; add cases: create PRACTICE (classId null + topic), reject PRACTICE with classId, reject duplicate title between GRADED/PRACTICE same owner, allow duplicate title across different owners.
- `StudentAssignmentServiceTest`: practice published visible without enrollment; GRADED still 404 when not enrolled; list defaults GRADED.
- `AssignmentGradingServiceTest`: `classId = null` no NPE, no roster synthesis.
- `ScoreServiceTest`: verify only GRADED passed to result-service (`findAllByClassIdAndPurpose(classId, GRADED)`).
- Run `./mvnw test` (course-service).

Frontend:
- `npx tsc -b`, `npm run lint`, `npm run build`.

---

## 7. Docs / Docs

- `docs/design/usecase-flows.md`: cập nhật UC-02 (create/list có `purpose`/`topic`) + thêm UC "Giảng viên tạo bài luyện tập theo chủ đề" và "Sinh viên làm bài luyện tập" (bước, request/response mẫu).
- `src-services/README.md`: mô tả `purpose`/`topic`, lưu ý practice không vào `EXERCISE`.
- Postman collections: thêm field/query param mới, kèm response thật (theo skill §12.5).

- `docs/design/usecase-flows.md`: update UC-02 (create/list with `purpose`/`topic`) + add UC "Lecturer creates practice exercise by topic" and "Student does practice exercise" (steps, request/response samples).
- `src-services/README.md`: describe `purpose`/`topic`, note practice excluded from `EXERCISE`.
- Postman collections: add new fields/query params with real responses (skill §12.5).

---

## 8. Rủi ro & rollback / Risks & rollback

| Rủi ro | Giảm thiểu | Risk | Mitigation |
|---|---|---|---|
| Practice lọt vào điểm EXERCISE | Filter tường minh ở `ScoreService` + test riêng | Practice leaks into EXERCISE score | Explicit filter at `ScoreService` + dedicated test |
| `class_id` nullable làm vỡ code giả định non-null | Xử lý null ở `AssignmentGradingService`, `StudentAssignmentService.requireVisible` | Null `class_id` breaks non-null assumptions | Null handling in `AssignmentGradingService` and `requireVisible` |
| Trùng title do check cũ theo class | Đổi sang check theo owner toàn bộ | Duplicate title due to old per-class check | Change to per-owner global check |
| Practice results không có tên sinh viên | Enrich qua `class_students` theo `student_user_id` | Practice results missing student names | Enrich via `class_students` by `student_user_id` |
| Sửa migration cũ | Chỉ thêm V7 | Editing old migration | Only add V7 |
| Rollback | Revert code; cột mới vô hại (default GRADED) | Rollback | Revert code; new columns harmless (default GRADED) |

---

## 9. Thứ tự thực thi / Execution order

1. Tạo branch `feat/practice-exercises` từ branch hiện tại (không push `main` theo quy tắc repo).
2. Hoàn thiện `V7__...sql`: thêm backfill `'Chung'` + `SET NOT NULL` (file đã có, chưa commit).
3. Backend course-service: Entity/DTO/Repository/Service/Controller theo mục 4.
4. Test backend: cập nhật 4 file test + chạy `./mvnw test`.
5. Frontend: types/endpoints/hooks; modal topic bắt buộc; PracticePage/StudentPracticePage; optional classId cho results/submissions; router, nav, i18n.
6. Verify FE: `npx tsc -b`, `npm run lint`, `npm run build`.
7. Docs: usecase-flows.md, README.md, Postman.
8. Commit → PR → review → merge (không push trực tiếp `main`).

1. Create branch `feat/practice-exercises` from current branch (no direct push to `main` per repo rules).
2. Finalize `V7__...sql`: add backfill `'Chung'` + `SET NOT NULL` (file exists, uncommitted).
3. Backend course-service: Entity/DTO/Repository/Service/Controller per section 4.
4. Backend tests: update 4 test files + run `./mvnw test`.
5. Frontend: types/endpoints/hooks; required topic modal; PracticePage/StudentPracticePage; optional classId for results/submissions; router, nav, i18n.
6. Verify FE: `npx tsc -b`, `npm run lint`, `npm run build`.
7. Docs: usecase-flows.md, README.md, Postman.
8. Commit → PR → review → merge (no direct push to `main`).

---

Lưu ý: 2 file `V7__...sql` và `entity/AssignmentPurpose.java` đã được tạo trước khi chuyển sang build mode, nhưng chưa commit. Trong build mode sẽ hoàn thiện V7 (thêm backfill + NOT NULL) rồi mới commit.

Note: 2 files `V7__...sql` and `entity/AssignmentPurpose.java` were created before entering build mode, but not yet committed. In build mode we will finalize V7 (add backfill + NOT NULL) before committing.
