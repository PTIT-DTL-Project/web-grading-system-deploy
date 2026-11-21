---
name: grading-test-plan-authoring
description: Soạn test plan JSON cho grading engine (assignment + plans + steps) trong docs/design/grading-config — cấu trúc đề nhiều câu, bẫy DB sandbox và assertion.
---

# Soạn test plan JSON cho grading engine

Áp dụng khi viết/sửa request body để tạo assignment, plan, step cho hệ thống chấm bài
(course-service + executor-service).

## Vị trí và định dạng

- Tài liệu kế hoạch kiểm thử đặt trong `docs/design/grading-config/`.
- Mọi config step phải là **JSON hợp lệ** (người dùng copy sang `curl` hoặc Postman).
  Sau khi viết, kiểm tra bằng cách trích các block ```json và `json.loads` từng block.
- Tham chiếu chuẩn: `docs/design/grading-config-reference.md`; luồng chấm: `docs/design/usecase-flows.md`
  (UC-03, UC-04, UC-05).

## Cấu trúc đề nhiều câu (pattern đã dùng)

Một assignment = nhiều plan, mỗi plan = một câu, tăng dần độ khó:

1. Câu 1 — một thực thể: CRUD + unique + validate + schema/PK.
2. Câu 2 — hai thực thể: khoá ngoại RESTRICT, index đặt tên cố định, response lồng, đổi FK.
3. Câu 3 — ba/bốn thực thể: PK ghép, cascade/restrict, giao dịch trừ tồn kho, rollback,
   báo cáo tổng hợp.

## Bẫy bắt buộc nhớ

- **DB reset sau mỗi plan** (`GradingOrchestrator` phase 5 + `DbSandboxService`): database bị
  drop/create, app đang chạy không tạo lại schema. Với đề nhiều plan, nộp từng câu kèm
  `planId`, hoặc cho mỗi plan tự tạo schema bằng `DB_MIGRATION` ở bước 1. Nộp một ZIP chấm cả
  đề chỉ an toàn khi app tự provision lại schema.
- **`contains_item` so `String.valueOf`**: `120000.00` → `"120000.0"`, không khớp `"120000"`.
  Với số dùng `json_path_equals` (so `BigDecimal`) hoặc đẩy điều kiện vào `WHERE`.
- **`DB_QUERY` chỉ so `row_count` và `columns`**, không so giá trị. Muốn khẳng định giá trị:
  `SELECT id FROM t WHERE id = ${id} AND stock = 3` với `expected.row_count = 1`.
- **`body_structure` đòi đúng key set**: app trả thêm `createdAt` là FAIL oan. Dùng
  `json_path exists` cho từng trường thay vì `body_structure` khi không kiểm soát response.
- **`kind` của assertion viết thường** (`status`, `json_path`, `json_path_equals`,
  `array_length`, `contains_item`, `greater_than`, `matches_regex`, `any_of`).
- **`connection`** bắt buộc `database`, `username`, `password`. `db_service` là **key service
  DB trong `docker-compose.yml`** (ví dụ `db`), không phải loại engine và **không có mặc
  định**: executor chỉ publish cổng của service này ra host để bước DB kết nối, nên sai/thiếu
  tên là mọi bước `DB_*` lỗi kết nối. `database` phải trùng `POSTGRES_DB` thì reset DB mới đúng.
- **`INDEX_EXISTS` so đúng tên index** → tên index phải là một phần của đề bài, không dựa vào
  tên Hibernate tự sinh.
- **Kiểu dữ liệu** trong `DB_SCHEMA_CHECK` viết theo alias PostgreSQL (`varchar`, `numeric`,
  `bigint`, `integer`, `timestamptz`); `varchar(50)` được chấp nhận.
- **`required: true` dừng cả plan** (các bước sau SKIPPED, không tính `ranWeight`). Chỉ đặt cho
  bước chuẩn bị; bước kiểm tra để `required: false`.
- **Không viết placeholder không ngoặc kép** (`"year": ${year}`) trong JSON gửi bằng `curl`;
  tách thành nhiều step hoặc dùng `"${field}"` dạng chuỗi.
- **MySQL/MariaDB**: DDL implicit commit, `DB_MIGRATION` không rollback được DDL → tách DDL/DML.

## Dữ liệu mẫu: dùng tiếng Anh, seed 3 bản ghi rồi mới test filter

- Mọi giá trị dữ liệu trong request body (`title`, `name`, `author`, `email`, `sku`, `code`,
  `topic`, tên lớp) viết **tiếng Anh, không dấu**. Query param và path lấy từ dữ liệu này,
  nên dữ liệu có dấu sẽ bị percent-encode và khó đọc trên URL/log.
- Tên bước (`stepOrder`/`name`) và mô tả đề vẫn có thể viết tiếng Việt; chỉ **giá trị dữ liệu**
  phải là ASCII.
- Trước khi test filter, tạo **3 bản ghi** rồi mới GET, và khẳng định cả số lượng lẫn nội dung:
  - lọc chứa trả nhiều kết quả (`title=java` → 2: `Effective Java`, `JavaScript: The Good Parts`)
  - không phân biệt hoa thường (`title=CLEAN` → 1)
  - không khớp trả mảng rỗng, không trả 404 (`title=python` → 0)
  - sắp xếp theo trường có thứ tự xác định (`sort=title,asc` → `$[0]`, `$[1]`)
- Quy định thứ tự trả về trong hợp đồng (sắp theo `id`/`sku` tăng dần) để assert theo vị trí
  không bị flaky.

## Thứ tự trả về là một phần của hợp đồng

Khi assert theo vị trí (`$[0]`, `$.items[1]`), đề bài phải quy định thứ tự (ví dụ sắp theo
`productId`, `sku`, `id` tăng dần). Nếu không, assertion sẽ fail ngẫu nhiên.
