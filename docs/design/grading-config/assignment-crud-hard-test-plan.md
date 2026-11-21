# Test plan: đề CRUD 3 câu (một thực thể → quan hệ FK → giao dịch nhiều bảng)

Tài liệu này chứa **request body đã soạn sẵn** để tạo một assignment khó, đủ để chạy hết
các nhánh của grading engine: HTTP CRUD, kiểm tra schema, kiểm tra FK/ràng buộc, kiểm tra
tính nguyên tử của giao dịch và đối soát dữ liệu bằng SQL.

- Đối tượng dùng: giảng viên (tạo đề) và người kiểm thử hệ thống (chạy full luồng nộp → chấm → xem điểm).
- Phạm vi: 3 câu = 3 plan; câu 1 CRUD một bảng, câu 2 hai bảng có FK, câu 3 bốn bảng có bảng nối,
  composite PK, cascade/restrict và rollback.
- Nguồn tham chiếu: `docs/design/grading-config-reference.md`, `docs/design/usecase-flows.md`
  (UC-03, UC-04, UC-05), `docs/api/docs/course-service/test-plan-controller.md`.

---

## 0. Tóm tắt nhanh

| Câu | Plan (sequenceOrder) | Nội dung | Số bước | Plan weight |
|-----|----------------------|----------|---------|-------------|
| Câu 1 | `Câu 1 - CRUD sách` (1) | 1 bảng `books`, CRUD + validate + unique + lọc tiêu đề | 17 | 30 |
| Câu 2 | `Câu 2 - Tác giả và sách` (2) | 2 bảng `authors` 1-N `books`, FK RESTRICT, lọc + sắp xếp | 19 | 35 |
| Câu 3 | `Câu 3 - Đơn hàng và tồn kho` (3) | 4 bảng, composite PK, cascade, tìm kiếm sản phẩm, rollback | 25 | 35 |

Thứ tự thực hiện: tạo lớp → import sinh viên → tạo assignment → tạo 3 plan kèm steps →
publish → sinh viên nộp ZIP → poll kết quả.

> **Điểm quan trọng nhất trước khi chạy:** executor **reset DB sau mỗi plan** (drop + create
> database, xem `GradingOrchestrator` phase 5 và `DbSandboxService`). App đang chạy không tự
> tạo lại schema sau khi DB bị drop. Vì vậy với đề nhiều plan, hãy **nộp từng câu một**
> (`planId` trên presigned URL) thay vì nộp một ZIP chấm cả 3 plan. Chi tiết ở mục 9.

---

## 1. Hợp đồng API mà sinh viên phải cài đặt

Không dùng xác thực trong bài này (giảng viên chấm trực tiếp trên app của sinh viên), nên
không cần bước login. Mọi response là JSON thuần, **không bọc envelope**.

### 1.1 Câu 1 — `books`

| Method | Path | Body / Query | Thành công | Lỗi bắt buộc |
|--------|------|--------------|------------|--------------|
| `POST` | `/api/v1/books` | `{isbn,title,author,price,publishedYear}` | `201` + object có `id` | `400` giá trị không hợp lệ, `409` trùng `isbn` |
| `GET` | `/api/v1/books` | `?title=` (lọc chứa, không phân biệt hoa thường), sắp theo `id` tăng dần | `200` + **mảng** | — |
| `GET` | `/api/v1/books/{id}` | — | `200` + object | `404` |
| `PUT` | `/api/v1/books/{id}` | đủ 5 trường | `200` | `404` |
| `PATCH` | `/api/v1/books/{id}` | một phần trường | `200` | `404` |
| `DELETE` | `/api/v1/books/{id}` | — | `204` | `404` |

### 1.2 Câu 2 — `authors` 1-N `books`

| Method | Path | Ghi chú | Thành công | Lỗi bắt buộc |
|--------|------|---------|------------|--------------|
| `POST` | `/api/v1/authors` | `{name,country}`; `name` unique | `201` | `409` trùng tên |
| `GET` | `/api/v1/authors/{id}/books` | mảng sách của tác giả | `200` | `404` |
| `POST` | `/api/v1/books` | thêm `authorId` (bắt buộc) | `201` | `404` `authorId` không tồn tại |
| `GET` | `/api/v1/books/{id}` | trả `authorId` (số) và object lồng `author` | `200` | `404` |
| `PUT` | `/api/v1/books/{id}` | đổi được `authorId` | `200` | `404` |
| `GET` | `/api/v1/books` | `?authorId=&page=&size=&sort=title,asc` | `200` + mảng | — |
| `DELETE` | `/api/v1/authors/{id}` | chỉ xoá được khi không còn sách | `204` | `409` còn sách tham chiếu |

### 1.3 Câu 3 — `customers`, `products`, `orders`, `order_items`

| Method | Path | Ghi chú | Thành công | Lỗi bắt buộc |
|--------|------|---------|------------|--------------|
| `POST` | `/api/v1/customers` | `{email,fullName}`; `email` unique | `201` | `409` |
| `POST` | `/api/v1/products` | `{sku,name,price,stock}`; `sku` unique | `201` | `409` |
| `POST` | `/api/v1/orders` | `{code,customerId,items:[{productId,quantity}]}` | `201` + `status=CREATED`, `totalAmount` | `404` khách/sản phẩm, `409` trùng `code`, `409` thiếu tồn kho |
| `GET` | `/api/v1/orders/{id}` | trả kèm `items` | `200` | `404` |
| `DELETE` | `/api/v1/orders/{id}` | xoá luôn `order_items` | `204` | `404` |
| `DELETE` | `/api/v1/products/{id}` | chỉ xoá được khi không còn trong đơn | `204` | `409` |
| `GET` | `/api/v1/products/{id}` | để đọc `stock` sau khi đặt hàng | `200` | `404` |
| `GET` | `/api/v1/products` | `?search=&page=&size=` lọc chứa trên `name` hoặc `sku`, không phân biệt hoa thường, sắp theo `id` | `200` + **mảng** | — |
| `GET` | `/api/v1/reports/revenue` | `?from=&to=` tuỳ chọn; chỉ SKU đã bán, sắp theo `sku`; mảng `{sku,revenue}` | `200` | — |

Validate bắt buộc ở câu 1: `isbn` và `title` không rỗng, `price >= 0`,
`publishedYear` trong khoảng 1000–2100; vi phạm trả `400`. Schema bảng phải được tạo ngay khi
app khởi động (Flyway hoặc `ddl-auto=update`) vì bước 1 của mỗi plan kiểm tra schema trước khi
gọi HTTP.

Thứ tự trả về là một phần của hợp đồng, để assertion không phụ thuộc thứ tự ngẫu nhiên:
mảng sách của tác giả, `GET /api/v1/books` và `GET /api/v1/products` sắp theo `id` tăng dần; `items` trong đơn hàng
sắp theo `productId` tăng dần; báo cáo doanh thu sắp theo `sku` tăng dần.

Quy ước nghiệp vụ bắt buộc (dùng để chấm):

1. Tạo đơn hàng là **một giao dịch**: trừ tồn kho, ghi `orders` và `order_items` hoặc không ghi gì cả.
2. `totalAmount` = tổng `quantity × unitPrice`, `unitPrice` chốt tại thời điểm đặt.
3. Không cho tồn kho âm (`stock >= 0`).
4. `order_items` có PK ghép `(order_id, product_id)`; xoá đơn thì item bị xoá theo (cascade);
   xoá sản phẩm đang nằm trong đơn thì bị chặn (restrict).

### 1.4 Schema DB kỳ vọng (PostgreSQL)

```sql
CREATE TABLE books (
    id             BIGSERIAL PRIMARY KEY,
    isbn           VARCHAR(20)  NOT NULL UNIQUE,
    title          VARCHAR(200) NOT NULL,
    author         VARCHAR(150),
    price          NUMERIC(12,2) NOT NULL,
    published_year INTEGER,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE authors (
    id         BIGSERIAL PRIMARY KEY,
    name       VARCHAR(150) NOT NULL UNIQUE,
    country    VARCHAR(100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- câu 2: books có thêm cột author_id, FK RESTRICT, index đặt tên cố định
ALTER TABLE books ADD COLUMN author_id BIGINT NOT NULL
    REFERENCES authors(id) ON DELETE RESTRICT;
CREATE INDEX idx_books_author_id ON books(author_id);

CREATE TABLE customers (
    id         BIGSERIAL PRIMARY KEY,
    email      VARCHAR(150) NOT NULL UNIQUE,
    full_name  VARCHAR(150) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE products (
    id    BIGSERIAL PRIMARY KEY,
    sku   VARCHAR(40) NOT NULL UNIQUE,
    name  VARCHAR(200) NOT NULL,
    price NUMERIC(12,2) NOT NULL,
    stock INTEGER NOT NULL CHECK (stock >= 0)
);

CREATE TABLE orders (
    id           BIGSERIAL PRIMARY KEY,
    code         VARCHAR(40) NOT NULL UNIQUE,
    customer_id  BIGINT NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
    status       VARCHAR(20) NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_orders_customer_id ON orders(customer_id);

CREATE TABLE order_items (
    order_id   BIGINT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    quantity   INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(12,2) NOT NULL,
    PRIMARY KEY (order_id, product_id)
);
```

Kiểu dữ liệu trong `DB_SCHEMA_CHECK` phải viết theo alias PostgreSQL mà dialect chuẩn hoá được:
`bigint`, `varchar`, `numeric`, `integer`, `timestamptz`, `boolean`.
Tên index `idx_books_author_id` và `idx_orders_customer_id` là **một phần của đề bài**, vì
`INDEX_EXISTS` so khớp đúng tên.

---

## 2. Chuẩn bị biến và tài khoản

```bash
export GATEWAY=https://web-dev1-api.vucongtuanduong.dpdns.org
export LECTURER_TOKEN='<access_token của giảng viên>'
export STUDENT_TOKEN='<access_token của sinh viên đã ghi danh>'
export CLASS_ID='<classId tạo ở bước 2.1>'
export ASSIGNMENT_ID='<assignmentId tạo ở bước 3>'
```

Mọi lệnh dưới đây đi qua API Gateway nên chỉ cần `Authorization: Bearer`. Gateway tự tiêm
`X-User-Id`, `X-User-Roles`, `X-Gateway-Secret`. Nếu gọi trực tiếp course-service
(`localhost:8081`), phải tự gửi ba header đó, nếu không sẽ `401`/`403`.

### 2.1 Tạo lớp

```json
{
  "name": "PTIT CNTT-K68 - Grading Test Class",
  "semester": "20261"
}
```

```bash
curl -sS -X POST "$GATEWAY/api/v1/classes" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d @class.json | jq -r '.data.id'
```

### 2.2 Import sinh viên

Chuẩn bị `students-import.csv` (mẫu: `docs/samples/students-import.csv`), cột
`studentCode,studentName,email,studentUserId`. Email phải trùng email tài khoản Keycloak của
sinh viên test, nếu không lượt nộp sẽ không gắn được vào roster.

```bash
curl -sS -X POST "$GATEWAY/api/v1/classes/$CLASS_ID/students/import" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -F 'file=@students-import.csv'
```

### 2.3 Thành phần điểm của lớp (để chạy được transcript)

```json
[
  { "type": "ATTENDANCE", "weight": 0.10 },
  { "type": "EXERCISE", "weight": 0.20 },
  { "type": "FINAL_EXAM", "weight": 0.70 }
]
```

```bash
curl -sS -X PUT "$GATEWAY/api/v1/classes/$CLASS_ID/score-components" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d @score-components.json
```

---

## 3. Tạo assignment

### 3.1 Biến thể A — giảng viên cung cấp compose (khuyến nghị để test engine)

Dùng khi bạn có sẵn một app tham chiếu đã cài đúng hợp đồng ở mục 1 và push lên registry.
`dockerComposeTemplate` là **chuỗi** chứa YAML nên phải escape `\n`.

```json
{
  "title": "CRUD Test: Books, Authors and Orders",
  "description": "Đề gồm 3 câu. Câu 1: CRUD một thực thể Book. Câu 2: thêm Author và quan hệ 1-N với Book, ràng buộc khoá ngoại RESTRICT. Câu 3: Customer, Product, Order, OrderItem với PK ghép, cascade khi xoá đơn, restrict khi xoá sản phẩm và rollback khi thiếu tồn kho. Sinh viên cài REST API theo hợp đồng trong đề, dùng PostgreSQL.",
  "classId": "00000000-0000-0000-0000-000000000000",
  "purpose": "GRADED",
  "topic": "CRUD, foreign keys and transactions",
  "gradingStrategy": "LECTURER_DOCKER_COMPOSE",
  "dockerComposeTemplate": "services:\n  db:\n    image: postgres:16\n    environment:\n      POSTGRES_DB: bookstore\n      POSTGRES_USER: postgres\n      POSTGRES_PASSWORD: postgres\n  app:\n    image: <REF_IMAGE>\n    depends_on:\n      - db\n    environment:\n      SPRING_DATASOURCE_URL: jdbc:postgresql://db:5432/bookstore\n      SPRING_DATASOURCE_USERNAME: postgres\n      SPRING_DATASOURCE_PASSWORD: postgres\n      SPRING_JPA_HIBERNATE_DDL_AUTO: update\n    ports:\n      - \"8080:8080\"\n",
  "dockerComposePort": 8080,
  "startupTimeoutMs": 120000,
  "executionTimeoutMs": 600000,
  "maxMemoryMb": 768,
  "maxCpu": 1.0
}
```

Thay `classId` bằng `$CLASS_ID` và `<REF_IMAGE>` bằng image thật (ví dụ `ghcr.io/<org>/bookstore-ref:1.0`).
`maxMemoryMb` 768 và `maxCpu` 1.0 vì compose có thêm container Postgres bên cạnh app.

```bash
curl -sS -X POST "$GATEWAY/api/v1/assignments" \
  -H "Authorization: Bearer $LECTURER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d @assignment.json | jq -r '.data.id'
```

### 3.2 Biến thể B — sinh viên nộp kèm docker-compose

Giữ nguyên body trên nhưng đổi hai trường:

```json
{
  "gradingStrategy": "STUDENT_DOCKER_COMPOSE",
  "dockerComposeTemplate": null
}
```

Khi đó ZIP của sinh viên phải có `docker-compose.yml` ở thư mục gốc, với service `app`
(mở cổng 8080) và service `db` (Postgres, `POSTGRES_DB=bookstore`). Tên service DB phải là
`db` vì các bước `DB_*` dùng `connection.db_service = "db"`.

Mẫu `docker-compose.yml` cho sinh viên:

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: bookstore
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
  app:
    image: <STUDENT_IMAGE>
    depends_on:
      - db
    environment:
      SPRING_DATASOURCE_URL: jdbc:postgresql://db:5432/bookstore
      SPRING_DATASOURCE_USERNAME: postgres
      SPRING_DATASOURCE_PASSWORD: postgres
      SPRING_JPA_HIBERNATE_DDL_AUTO: update
    ports:
      - "8080:8080"
```

Không dùng `privileged: true` và không mount `/var/run/docker.sock`: patcher sẽ từ chối compose.
Không dùng named volume cho Postgres, vì mỗi lượt chấm phải bắt đầu với DB trống.

---

## 4. Câu 1 — plan + steps

`POST $GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/plans/with-steps`

```json
{
  "plan": {
    "name": "Câu 1 - CRUD sách",
    "description": "CRUD một thực thể Book trên dữ liệu tiếng Anh, kiểm tra unique ISBN, validate, lọc theo tiêu đề và schema bảng.",
    "sequenceOrder": 1,
    "weight": 30
  },
  "steps": [
    {
      "stepOrder": 1,
      "name": "Schema bảng books",
      "description": "Bảng books tồn tại, đủ cột, đúng kiểu dữ liệu, có khoá chính.",
      "stepType": "DB_SCHEMA_CHECK",
      "weight": 3,
      "required": true,
      "timeoutMs": 15000,
      "config": {
        "connection": {
          "db_type": "postgres",
          "db_service": "db",
          "db_port": 5432,
          "database": "bookstore",
          "username": "postgres",
          "password": "postgres"
        },
        "checks": [
          {
            "kind": "TABLE_EXISTS",
            "table_name": "books"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "books",
            "column_name": "id",
            "data_type": "bigint"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "books",
            "column_name": "isbn",
            "data_type": "varchar"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "books",
            "column_name": "title",
            "data_type": "varchar"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "books",
            "column_name": "author",
            "data_type": "varchar"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "books",
            "column_name": "price",
            "data_type": "numeric"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "books",
            "column_name": "published_year",
            "data_type": "integer"
          },
          {
            "kind": "PRIMARY_KEY",
            "table_name": "books",
            "column": "id"
          }
        ]
      }
    },
    {
      "stepOrder": 2,
      "name": "Tạo sách thứ nhất",
      "description": "POST /api/v1/books với dữ liệu tiếng Anh, trả 201.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": true,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/books",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "isbn": "978-0-13-468599-1",
          "title": "Effective Java",
          "author": "Joshua Bloch",
          "price": 450000.0,
          "publishedYear": 2018
        },
        "expected_status": 201,
        "extract": [
          {
            "name": "book1Id",
            "from": "response_body",
            "expression": "$.id",
            "as": "scalar",
            "fallback": ""
          }
        ],
        "assertions": [
          {
            "kind": "status",
            "equals": 201
          },
          {
            "kind": "json_path",
            "path": "$.id",
            "exists": true
          },
          {
            "kind": "json_path_equals",
            "path": "$.isbn",
            "equals": "978-0-13-468599-1"
          },
          {
            "kind": "json_path_equals",
            "path": "$.price",
            "equals": "450000"
          }
        ]
      }
    },
    {
      "stepOrder": 3,
      "name": "Tạo sách thứ hai",
      "description": "POST sách thứ hai để kiểm tra danh sách nhiều phần tử.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/books",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "isbn": "978-0-13-235088-4",
          "title": "Clean Code",
          "author": "Robert C. Martin",
          "price": 380000.0,
          "publishedYear": 2008
        },
        "expected_status": 201,
        "extract": [
          {
            "name": "book2Id",
            "from": "response_body",
            "expression": "$.id",
            "as": "scalar",
            "fallback": ""
          }
        ],
        "assertions": [
          {
            "kind": "status",
            "equals": 201
          }
        ]
      }
    },
    {
      "stepOrder": 4,
      "name": "Tạo sách thứ ba",
      "description": "POST sách thứ ba, tiêu đề chứa chuỗi 'Java' để thử tìm kiếm.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/books",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "isbn": "978-0-596-51774-8",
          "title": "JavaScript: The Good Parts",
          "author": "Douglas Crockford",
          "price": 320000.0,
          "publishedYear": 2008
        },
        "expected_status": 201,
        "extract": [
          {
            "name": "book3Id",
            "from": "response_body",
            "expression": "$.id",
            "as": "scalar",
            "fallback": ""
          }
        ],
        "assertions": [
          {
            "kind": "status",
            "equals": 201
          }
        ]
      }
    },
    {
      "stepOrder": 5,
      "name": "Từ chối ISBN trùng",
      "description": "Tạo lại ISBN của sách thứ nhất phải trả 409.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/books",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "isbn": "978-0-13-468599-1",
          "title": "Duplicate",
          "author": "Joshua Bloch",
          "price": 1000,
          "publishedYear": 2018
        },
        "expected_status": 409,
        "assertions": [
          {
            "kind": "status",
            "equals": 409
          }
        ]
      }
    },
    {
      "stepOrder": 6,
      "name": "Từ chối giá âm",
      "description": "price < 0 phải trả 400.",
      "stepType": "HTTP_REQUEST",
      "weight": 1,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/books",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "isbn": "978-0-00-000000-0",
          "title": "Invalid Price",
          "author": "Nobody",
          "price": -1,
          "publishedYear": 2024
        },
        "expected_status": 400,
        "assertions": [
          {
            "kind": "status",
            "equals": 400
          }
        ]
      }
    },
    {
      "stepOrder": 7,
      "name": "Danh sách có ba sách",
      "description": "GET /api/v1/books trả đúng ba phần tử, sắp theo id tăng dần.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/books",
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 3
          },
          {
            "kind": "contains_item",
            "path": "$[*].title",
            "equals": "Clean Code"
          },
          {
            "kind": "json_path_equals",
            "path": "$[0].isbn",
            "equals": "978-0-13-468599-1"
          }
        ]
      }
    },
    {
      "stepOrder": 8,
      "name": "Lọc theo tiêu đề chứa 'java'",
      "description": "Hai sách khớp: Effective Java và JavaScript: The Good Parts.",
      "stepType": "HTTP_REQUEST",
      "weight": 3,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/books",
        "query_params": {
          "title": "java"
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 2
          },
          {
            "kind": "contains_item",
            "path": "$[*].title",
            "equals": "Effective Java"
          },
          {
            "kind": "contains_item",
            "path": "$[*].title",
            "equals": "JavaScript: The Good Parts"
          }
        ]
      }
    },
    {
      "stepOrder": 9,
      "name": "Lọc không phân biệt hoa thường",
      "description": "title=CLEAN vẫn trả Clean Code.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/books",
        "query_params": {
          "title": "CLEAN"
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 1
          },
          {
            "kind": "json_path_equals",
            "path": "$[0].title",
            "equals": "Clean Code"
          }
        ]
      }
    },
    {
      "stepOrder": 10,
      "name": "Lọc không có kết quả",
      "description": "title=python trả mảng rỗng, không trả 404.",
      "stepType": "HTTP_REQUEST",
      "weight": 1,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/books",
        "query_params": {
          "title": "python"
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 0
          }
        ]
      }
    },
    {
      "stepOrder": 11,
      "name": "Đọc theo id",
      "description": "GET /api/v1/books/{id} trả đúng bản ghi.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/books/${book1Id}",
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "json_path",
            "path": "$.id",
            "exists": true
          },
          {
            "kind": "json_path",
            "path": "$.title",
            "exists": true
          },
          {
            "kind": "json_path",
            "path": "$.price",
            "exists": true
          },
          {
            "kind": "json_path_equals",
            "path": "$.isbn",
            "equals": "978-0-13-468599-1"
          }
        ]
      }
    },
    {
      "stepOrder": 12,
      "name": "Cập nhật toàn bộ bằng PUT",
      "description": "PUT đổi title và price, giữ nguyên id.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "PUT",
        "path": "/api/v1/books/${book1Id}",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "isbn": "978-0-13-468599-1",
          "title": "Effective Java, 3rd Edition",
          "author": "Joshua Bloch",
          "price": 520000.0,
          "publishedYear": 2025
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "json_path_equals",
            "path": "$.title",
            "equals": "Effective Java, 3rd Edition"
          },
          {
            "kind": "json_path_equals",
            "path": "$.publishedYear",
            "equals": "2025"
          }
        ]
      }
    },
    {
      "stepOrder": 13,
      "name": "Cập nhật một phần bằng PATCH",
      "description": "PATCH chỉ đổi price, title giữ nguyên.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "PATCH",
        "path": "/api/v1/books/${book1Id}",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "price": 499000.0
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "json_path_equals",
            "path": "$.price",
            "equals": "499000"
          },
          {
            "kind": "json_path_equals",
            "path": "$.title",
            "equals": "Effective Java, 3rd Edition"
          }
        ]
      }
    },
    {
      "stepOrder": 14,
      "name": "Đọc id không tồn tại",
      "description": "GET id 999999 phải trả 404, không trả 500.",
      "stepType": "HTTP_REQUEST",
      "weight": 1,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/books/999999",
        "expected_status": 404,
        "assertions": [
          {
            "kind": "status",
            "equals": 404
          }
        ]
      }
    },
    {
      "stepOrder": 15,
      "name": "Xoá sách",
      "description": "DELETE trả 204.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "DELETE",
        "path": "/api/v1/books/${book1Id}",
        "expected_status": 204,
        "assertions": [
          {
            "kind": "status",
            "equals": 204
          }
        ]
      }
    },
    {
      "stepOrder": 16,
      "name": "Xoá đã ghi vào DB",
      "description": "SQL xác nhận bản ghi đã bị xoá.",
      "stepType": "DB_QUERY",
      "weight": 2,
      "required": false,
      "timeoutMs": 10000,
      "config": {
        "connection": {
          "db_type": "postgres",
          "db_service": "db",
          "db_port": 5432,
          "database": "bookstore",
          "username": "postgres",
          "password": "postgres"
        },
        "query": "SELECT id FROM books WHERE isbn = '978-0-13-468599-1'",
        "expected": {
          "row_count": 0
        }
      }
    },
    {
      "stepOrder": 17,
      "name": "Danh sách còn hai sách",
      "description": "Sau khi xoá, GET /api/v1/books còn hai phần tử.",
      "stepType": "HTTP_REQUEST",
      "weight": 1,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/books",
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 2
          }
        ]
      }
    }
  ]
}
```

Tổng weight câu 1: 3+2+2+2+2+1+2+3+2+1+2+2+2+1+2+2+1 = **32**.

---

## 5. Câu 2 — plan + steps

`POST $GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/plans/with-steps`

```json
{
  "plan": {
    "name": "Câu 2 - Tác giả và sách",
    "description": "Quan hệ 1-N, khoá ngoại RESTRICT, lọc theo tác giả và sắp xếp, trả về object lồng.",
    "sequenceOrder": 2,
    "weight": 35
  },
  "steps": [
    {
      "stepOrder": 1,
      "name": "Schema authors và cột author_id",
      "description": "Bảng authors đúng cột; books có author_id bigint và index idx_books_author_id.",
      "stepType": "DB_SCHEMA_CHECK",
      "weight": 3,
      "required": true,
      "timeoutMs": 15000,
      "config": {
        "connection": {
          "db_type": "postgres",
          "db_service": "db",
          "db_port": 5432,
          "database": "bookstore",
          "username": "postgres",
          "password": "postgres"
        },
        "checks": [
          {
            "kind": "TABLE_EXISTS",
            "table_name": "authors"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "authors",
            "column_name": "id",
            "data_type": "bigint"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "authors",
            "column_name": "name",
            "data_type": "varchar"
          },
          {
            "kind": "PRIMARY_KEY",
            "table_name": "authors",
            "column": "id"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "books",
            "column_name": "author_id",
            "data_type": "bigint"
          },
          {
            "kind": "INDEX_EXISTS",
            "table_name": "books",
            "index_name": "idx_books_author_id"
          }
        ]
      }
    },
    {
      "stepOrder": 2,
      "name": "Có ràng buộc khoá ngoại trên books",
      "description": "FK books.author_id tham chiếu authors.id.",
      "stepType": "DB_QUERY",
      "weight": 3,
      "required": true,
      "timeoutMs": 10000,
      "config": {
        "connection": {
          "db_type": "postgres",
          "db_service": "db",
          "db_port": 5432,
          "database": "bookstore",
          "username": "postgres",
          "password": "postgres"
        },
        "query": "SELECT kcu.column_name FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema JOIN information_schema.constraint_column_usage ccu ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_name = 'books' AND ccu.table_name = 'authors' AND kcu.column_name = 'author_id'",
        "expected": {
          "row_count": 1
        }
      }
    },
    {
      "stepOrder": 3,
      "name": "Tạo tác giả thứ nhất",
      "description": "POST /api/v1/authors trả 201 và id.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": true,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/authors",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "name": "Joshua Bloch",
          "country": "United States"
        },
        "expected_status": 201,
        "extract": [
          {
            "name": "authorId",
            "from": "response_body",
            "expression": "$.id",
            "as": "scalar",
            "fallback": ""
          }
        ],
        "assertions": [
          {
            "kind": "status",
            "equals": 201
          },
          {
            "kind": "json_path",
            "path": "$.id",
            "exists": true
          }
        ]
      }
    },
    {
      "stepOrder": 4,
      "name": "Tạo tác giả thứ hai",
      "description": "Chuẩn bị cho bước đổi tác giả của sách.",
      "stepType": "HTTP_REQUEST",
      "weight": 1,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/authors",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "name": "Robert C. Martin",
          "country": "United States"
        },
        "expected_status": 201,
        "extract": [
          {
            "name": "authorId2",
            "from": "response_body",
            "expression": "$.id",
            "as": "scalar",
            "fallback": ""
          }
        ],
        "assertions": [
          {
            "kind": "status",
            "equals": 201
          }
        ]
      }
    },
    {
      "stepOrder": 5,
      "name": "Từ chối tên tác giả trùng",
      "description": "Unique trên authors.name, trả 409.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/authors",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "name": "Joshua Bloch",
          "country": "United States"
        },
        "expected_status": 409,
        "assertions": [
          {
            "kind": "status",
            "equals": 409
          }
        ]
      }
    },
    {
      "stepOrder": 6,
      "name": "Tạo sách thứ nhất của tác giả",
      "description": "POST book với authorId hợp lệ.",
      "stepType": "HTTP_REQUEST",
      "weight": 3,
      "required": true,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/books",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "isbn": "978-0-13-468599-1",
          "title": "Effective Java",
          "author": "Joshua Bloch",
          "authorId": "${authorId}",
          "price": 450000.0,
          "publishedYear": 2018
        },
        "expected_status": 201,
        "extract": [
          {
            "name": "book1Id",
            "from": "response_body",
            "expression": "$.id",
            "as": "scalar",
            "fallback": ""
          }
        ],
        "assertions": [
          {
            "kind": "status",
            "equals": 201
          },
          {
            "kind": "json_path_equals",
            "path": "$.authorId",
            "equals": "${authorId}"
          }
        ]
      }
    },
    {
      "stepOrder": 7,
      "name": "Tạo sách thứ hai của tác giả",
      "description": "Sách thứ hai để thử lọc và sắp xếp theo title.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/books",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "isbn": "978-0-321-34960-6",
          "title": "Java Concurrency in Practice",
          "author": "Joshua Bloch",
          "authorId": "${authorId}",
          "price": 410000.0,
          "publishedYear": 2006
        },
        "expected_status": 201,
        "extract": [
          {
            "name": "book2Id",
            "from": "response_body",
            "expression": "$.id",
            "as": "scalar",
            "fallback": ""
          }
        ],
        "assertions": [
          {
            "kind": "status",
            "equals": 201
          }
        ]
      }
    },
    {
      "stepOrder": 8,
      "name": "Từ chối authorId không tồn tại",
      "description": "Tạo sách với authorId 999999 phải trả 404.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/books",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "isbn": "978-0-00-000000-1",
          "title": "Orphan Book",
          "author": "Unknown",
          "authorId": "999999",
          "price": 10000,
          "publishedYear": 2023
        },
        "expected_status": 404,
        "assertions": [
          {
            "kind": "status",
            "equals": 404
          }
        ]
      }
    },
    {
      "stepOrder": 9,
      "name": "Danh sách sách của tác giả",
      "description": "GET /api/v1/authors/{id}/books trả đúng hai sách.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/authors/${authorId}/books",
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 2
          },
          {
            "kind": "contains_item",
            "path": "$[*].title",
            "equals": "Effective Java"
          },
          {
            "kind": "contains_item",
            "path": "$[*].title",
            "equals": "Java Concurrency in Practice"
          }
        ]
      }
    },
    {
      "stepOrder": 10,
      "name": "Lọc theo tác giả và sắp xếp",
      "description": "GET /api/v1/books?authorId=...&sort=title,asc trả hai sách đúng thứ tự.",
      "stepType": "HTTP_REQUEST",
      "weight": 3,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/books",
        "query_params": {
          "authorId": "${authorId}",
          "page": "0",
          "size": "2",
          "sort": "title,asc"
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 2
          },
          {
            "kind": "json_path_equals",
            "path": "$[0].title",
            "equals": "Effective Java"
          },
          {
            "kind": "json_path_equals",
            "path": "$[1].title",
            "equals": "Java Concurrency in Practice"
          }
        ]
      }
    },
    {
      "stepOrder": 11,
      "name": "Lọc theo tác giả không có sách",
      "description": "authorId2 chưa có sách, trả mảng rỗng.",
      "stepType": "HTTP_REQUEST",
      "weight": 1,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/books",
        "query_params": {
          "authorId": "${authorId2}"
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 0
          }
        ]
      }
    },
    {
      "stepOrder": 12,
      "name": "Sách trả về object lồng author",
      "description": "GET /api/v1/books/{id} có $.author.name.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/books/${book1Id}",
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "json_path",
            "path": "$.author.name",
            "exists": true
          },
          {
            "kind": "json_path_equals",
            "path": "$.author.name",
            "equals": "Joshua Bloch"
          }
        ]
      }
    },
    {
      "stepOrder": 13,
      "name": "Không xoá được tác giả còn sách",
      "description": "DELETE author còn sách phải trả 409 do FK RESTRICT.",
      "stepType": "HTTP_REQUEST",
      "weight": 3,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "DELETE",
        "path": "/api/v1/authors/${authorId}",
        "expected_status": 409,
        "assertions": [
          {
            "kind": "status",
            "equals": 409
          }
        ]
      }
    },
    {
      "stepOrder": 14,
      "name": "Đổi sách thứ nhất sang tác giả khác",
      "description": "PUT đổi authorId sang authorId2.",
      "stepType": "HTTP_REQUEST",
      "weight": 3,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "PUT",
        "path": "/api/v1/books/${book1Id}",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "isbn": "978-0-13-468599-1",
          "title": "Effective Java",
          "author": "Robert C. Martin",
          "authorId": "${authorId2}",
          "price": 450000.0,
          "publishedYear": 2018
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "json_path_equals",
            "path": "$.authorId",
            "equals": "${authorId2}"
          }
        ]
      }
    },
    {
      "stepOrder": 15,
      "name": "Tác giả cũ còn một sách",
      "description": "Sau khi đổi, tác giả cũ chỉ còn Java Concurrency in Practice.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/authors/${authorId}/books",
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 1
          },
          {
            "kind": "json_path_equals",
            "path": "$[0].title",
            "equals": "Java Concurrency in Practice"
          }
        ]
      }
    },
    {
      "stepOrder": 16,
      "name": "JOIN đối soát quan hệ",
      "description": "SQL join xác nhận sách thứ nhất đã thuộc tác giả mới.",
      "stepType": "DB_QUERY",
      "weight": 2,
      "required": false,
      "timeoutMs": 10000,
      "config": {
        "connection": {
          "db_type": "postgres",
          "db_service": "db",
          "db_port": 5432,
          "database": "bookstore",
          "username": "postgres",
          "password": "postgres"
        },
        "query": "SELECT b.title, a.name FROM books b JOIN authors a ON a.id = b.author_id WHERE b.isbn = '978-0-13-468599-1' AND a.name = 'Robert C. Martin'",
        "expected": {
          "row_count": 1,
          "columns": [
            "title",
            "name"
          ]
        }
      }
    },
    {
      "stepOrder": 17,
      "name": "Đổi nốt sách thứ hai",
      "description": "PUT đổi authorId của sách còn lại sang authorId2.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "PUT",
        "path": "/api/v1/books/${book2Id}",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "isbn": "978-0-321-34960-6",
          "title": "Java Concurrency in Practice",
          "author": "Robert C. Martin",
          "authorId": "${authorId2}",
          "price": 410000.0,
          "publishedYear": 2006
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          }
        ]
      }
    },
    {
      "stepOrder": 18,
      "name": "Xoá tác giả đã hết sách",
      "description": "Sau khi chuyển hết sách, DELETE author phải trả 204.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "DELETE",
        "path": "/api/v1/authors/${authorId}",
        "expected_status": 204,
        "assertions": [
          {
            "kind": "status",
            "equals": 204
          }
        ]
      }
    },
    {
      "stepOrder": 19,
      "name": "Chỉ còn một tác giả",
      "description": "SQL xác nhận bảng authors còn đúng một dòng.",
      "stepType": "DB_QUERY",
      "weight": 1,
      "required": false,
      "timeoutMs": 10000,
      "config": {
        "connection": {
          "db_type": "postgres",
          "db_service": "db",
          "db_port": 5432,
          "database": "bookstore",
          "username": "postgres",
          "password": "postgres"
        },
        "query": "SELECT id FROM authors",
        "expected": {
          "row_count": 1
        }
      }
    }
  ]
}
```

Tổng weight câu 2: 3+3+2+1+2+3+2+2+2+3+1+2+3+3+2+2+2+2+1 = **41**.

---

## 6. Câu 3 — plan + steps

`POST $GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/plans/with-steps`

```json
{
  "plan": {
    "name": "Câu 3 - Đơn hàng và tồn kho",
    "description": "Bốn bảng, PK ghép, cascade/restrict, tìm kiếm sản phẩm, giao dịch trừ tồn kho và rollback.",
    "sequenceOrder": 3,
    "weight": 35
  },
  "steps": [
    {
      "stepOrder": 1,
      "name": "Schema bốn bảng",
      "description": "customers, products, orders, order_items tồn tại với cột và PK ghép đúng.",
      "stepType": "DB_SCHEMA_CHECK",
      "weight": 4,
      "required": true,
      "timeoutMs": 20000,
      "config": {
        "connection": {
          "db_type": "postgres",
          "db_service": "db",
          "db_port": 5432,
          "database": "bookstore",
          "username": "postgres",
          "password": "postgres"
        },
        "checks": [
          {
            "kind": "TABLE_EXISTS",
            "table_name": "customers"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "customers",
            "column_name": "email",
            "data_type": "varchar"
          },
          {
            "kind": "TABLE_EXISTS",
            "table_name": "products"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "products",
            "column_name": "stock",
            "data_type": "integer"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "products",
            "column_name": "price",
            "data_type": "numeric"
          },
          {
            "kind": "TABLE_EXISTS",
            "table_name": "orders"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "orders",
            "column_name": "total_amount",
            "data_type": "numeric"
          },
          {
            "kind": "TABLE_EXISTS",
            "table_name": "order_items"
          },
          {
            "kind": "COLUMN_EXISTS",
            "table_name": "order_items",
            "column_name": "unit_price",
            "data_type": "numeric"
          },
          {
            "kind": "PRIMARY_KEY",
            "table_name": "order_items",
            "column": "order_id"
          },
          {
            "kind": "INDEX_EXISTS",
            "table_name": "orders",
            "index_name": "idx_orders_customer_id"
          }
        ]
      }
    },
    {
      "stepOrder": 2,
      "name": "Hai khoá ngoại trên order_items",
      "description": "order_items phải có FK tới orders và tới products.",
      "stepType": "DB_QUERY",
      "weight": 3,
      "required": true,
      "timeoutMs": 10000,
      "config": {
        "connection": {
          "db_type": "postgres",
          "db_service": "db",
          "db_port": 5432,
          "database": "bookstore",
          "username": "postgres",
          "password": "postgres"
        },
        "query": "SELECT ccu.table_name FROM information_schema.table_constraints tc JOIN information_schema.constraint_column_usage ccu ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_name = 'order_items'",
        "expected": {
          "row_count": 2
        }
      }
    },
    {
      "stepOrder": 3,
      "name": "Tạo khách hàng",
      "description": "POST /api/v1/customers trả 201.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": true,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/customers",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "email": "alice.nguyen@example.com",
          "fullName": "Alice Nguyen"
        },
        "expected_status": 201,
        "extract": [
          {
            "name": "customerId",
            "from": "response_body",
            "expression": "$.id",
            "as": "scalar",
            "fallback": ""
          }
        ],
        "assertions": [
          {
            "kind": "status",
            "equals": 201
          },
          {
            "kind": "json_path",
            "path": "$.id",
            "exists": true
          }
        ]
      }
    },
    {
      "stepOrder": 4,
      "name": "Từ chối email trùng",
      "description": "Unique trên customers.email, trả 409.",
      "stepType": "HTTP_REQUEST",
      "weight": 1,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/customers",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "email": "alice.nguyen@example.com",
          "fullName": "Duplicate User"
        },
        "expected_status": 409,
        "assertions": [
          {
            "kind": "status",
            "equals": 409
          }
        ]
      }
    },
    {
      "stepOrder": 5,
      "name": "Tạo sản phẩm thứ nhất",
      "description": "Mechanical Keyboard, giá 120000, tồn 5.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": true,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/products",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "sku": "SKU-001",
          "name": "Mechanical Keyboard",
          "price": 120000.0,
          "stock": 5
        },
        "expected_status": 201,
        "extract": [
          {
            "name": "productId1",
            "from": "response_body",
            "expression": "$.id",
            "as": "scalar",
            "fallback": ""
          }
        ],
        "assertions": [
          {
            "kind": "status",
            "equals": 201
          }
        ]
      }
    },
    {
      "stepOrder": 6,
      "name": "Tạo sản phẩm thứ hai",
      "description": "Wireless Mouse, giá 80000, tồn 100.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/products",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "sku": "SKU-002",
          "name": "Wireless Mouse",
          "price": 80000.0,
          "stock": 100
        },
        "expected_status": 201,
        "extract": [
          {
            "name": "productId2",
            "from": "response_body",
            "expression": "$.id",
            "as": "scalar",
            "fallback": ""
          }
        ],
        "assertions": [
          {
            "kind": "status",
            "equals": 201
          }
        ]
      }
    },
    {
      "stepOrder": 7,
      "name": "Tạo sản phẩm thứ ba",
      "description": "USB-C Hub, giá 250000, tồn 20.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/products",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "sku": "SKU-003",
          "name": "USB-C Hub",
          "price": 250000.0,
          "stock": 20
        },
        "expected_status": 201,
        "extract": [
          {
            "name": "productId3",
            "from": "response_body",
            "expression": "$.id",
            "as": "scalar",
            "fallback": ""
          }
        ],
        "assertions": [
          {
            "kind": "status",
            "equals": 201
          }
        ]
      }
    },
    {
      "stepOrder": 8,
      "name": "Từ chối SKU trùng",
      "description": "Unique trên products.sku, trả 409.",
      "stepType": "HTTP_REQUEST",
      "weight": 1,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/products",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "sku": "SKU-001",
          "name": "Duplicate SKU",
          "price": 1,
          "stock": 1
        },
        "expected_status": 409,
        "assertions": [
          {
            "kind": "status",
            "equals": 409
          }
        ]
      }
    },
    {
      "stepOrder": 9,
      "name": "Tìm sản phẩm theo tên",
      "description": "GET /api/v1/products?search=keyboard trả đúng một sản phẩm.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/products",
        "query_params": {
          "search": "keyboard"
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 1
          },
          {
            "kind": "json_path_equals",
            "path": "$[0].sku",
            "equals": "SKU-001"
          }
        ]
      }
    },
    {
      "stepOrder": 10,
      "name": "Tìm không phân biệt hoa thường",
      "description": "search=MOUSE vẫn trả Wireless Mouse.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/products",
        "query_params": {
          "search": "MOUSE"
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 1
          },
          {
            "kind": "json_path_equals",
            "path": "$[0].sku",
            "equals": "SKU-002"
          }
        ]
      }
    },
    {
      "stepOrder": 11,
      "name": "Tìm theo một phần tên",
      "description": "search=hub trả USB-C Hub.",
      "stepType": "HTTP_REQUEST",
      "weight": 1,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/products",
        "query_params": {
          "search": "hub"
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 1
          },
          {
            "kind": "json_path_equals",
            "path": "$[0].sku",
            "equals": "SKU-003"
          }
        ]
      }
    },
    {
      "stepOrder": 12,
      "name": "Tìm không có kết quả",
      "description": "search=printer trả mảng rỗng.",
      "stepType": "HTTP_REQUEST",
      "weight": 1,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/products",
        "query_params": {
          "search": "printer"
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 0
          }
        ]
      }
    },
    {
      "stepOrder": 13,
      "name": "Tạo đơn hàng hai dòng",
      "description": "2 bàn phím + 1 chuột, tổng 320000, trạng thái CREATED.",
      "stepType": "HTTP_REQUEST",
      "weight": 4,
      "required": true,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/orders",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "code": "ORD-TEST-001",
          "customerId": "${customerId}",
          "items": [
            {
              "productId": "${productId1}",
              "quantity": 2
            },
            {
              "productId": "${productId2}",
              "quantity": 1
            }
          ]
        },
        "expected_status": 201,
        "extract": [
          {
            "name": "orderId",
            "from": "response_body",
            "expression": "$.id",
            "as": "scalar",
            "fallback": ""
          }
        ],
        "assertions": [
          {
            "kind": "status",
            "equals": 201
          },
          {
            "kind": "json_path_equals",
            "path": "$.status",
            "equals": "CREATED"
          },
          {
            "kind": "json_path_equals",
            "path": "$.totalAmount",
            "equals": "320000"
          },
          {
            "kind": "array_length",
            "path": "$.items",
            "equals": 2
          }
        ]
      }
    },
    {
      "stepOrder": 14,
      "name": "Đọc lại đơn hàng",
      "description": "GET đơn trả đủ items với unitPrice đã chốt, sắp theo productId.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/orders/${orderId}",
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$.items",
            "equals": 2
          },
          {
            "kind": "json_path_equals",
            "path": "$.items[0].unitPrice",
            "equals": "120000"
          },
          {
            "kind": "json_path_equals",
            "path": "$.items[1].unitPrice",
            "equals": "80000"
          }
        ]
      }
    },
    {
      "stepOrder": 15,
      "name": "Tồn kho đã bị trừ",
      "description": "Sản phẩm 1 còn 3 sau khi bán 2.",
      "stepType": "HTTP_REQUEST",
      "weight": 3,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/products/${productId1}",
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "json_path_equals",
            "path": "$.stock",
            "equals": "3"
          }
        ]
      }
    },
    {
      "stepOrder": 16,
      "name": "Từ chối đơn vượt tồn kho",
      "description": "Đặt 99 bàn phím khi chỉ còn 3 phải trả 409.",
      "stepType": "HTTP_REQUEST",
      "weight": 4,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/orders",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "code": "ORD-TEST-002",
          "customerId": "${customerId}",
          "items": [
            {
              "productId": "${productId1}",
              "quantity": 99
            }
          ]
        },
        "expected_status": 409,
        "assertions": [
          {
            "kind": "status",
            "equals": 409
          }
        ]
      }
    },
    {
      "stepOrder": 17,
      "name": "Đơn lỗi không được ghi",
      "description": "Rollback: không có order nào mang code ORD-TEST-002.",
      "stepType": "DB_QUERY",
      "weight": 4,
      "required": false,
      "timeoutMs": 10000,
      "config": {
        "connection": {
          "db_type": "postgres",
          "db_service": "db",
          "db_port": 5432,
          "database": "bookstore",
          "username": "postgres",
          "password": "postgres"
        },
        "query": "SELECT id FROM orders WHERE code = 'ORD-TEST-002'",
        "expected": {
          "row_count": 0
        }
      }
    },
    {
      "stepOrder": 18,
      "name": "Tồn kho không bị trừ khi rollback",
      "description": "Sản phẩm 1 vẫn còn đúng 3 sau đơn thất bại.",
      "stepType": "DB_QUERY",
      "weight": 4,
      "required": false,
      "timeoutMs": 10000,
      "config": {
        "connection": {
          "db_type": "postgres",
          "db_service": "db",
          "db_port": 5432,
          "database": "bookstore",
          "username": "postgres",
          "password": "postgres"
        },
        "query": "SELECT id FROM products WHERE sku = 'SKU-001' AND stock = 3",
        "expected": {
          "row_count": 1
        }
      }
    },
    {
      "stepOrder": 19,
      "name": "Từ chối sản phẩm không tồn tại",
      "description": "Đặt hàng với productId 999999 phải trả 404.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "POST",
        "path": "/api/v1/orders",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "code": "ORD-TEST-003",
          "customerId": "${customerId}",
          "items": [
            {
              "productId": "999999",
              "quantity": 1
            }
          ]
        },
        "expected_status": 404,
        "assertions": [
          {
            "kind": "status",
            "equals": 404
          }
        ]
      }
    },
    {
      "stepOrder": 20,
      "name": "Báo cáo doanh thu",
      "description": "GET /api/v1/reports/revenue trả doanh thu từng SKU đã bán, sắp theo sku.",
      "stepType": "HTTP_REQUEST",
      "weight": 3,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/reports/revenue",
        "query_params": {
          "from": "2020-01-01",
          "to": "2030-12-31"
        },
        "expected_status": 200,
        "assertions": [
          {
            "kind": "status",
            "equals": 200
          },
          {
            "kind": "array_length",
            "path": "$",
            "equals": 2
          },
          {
            "kind": "json_path_equals",
            "path": "$[0].sku",
            "equals": "SKU-001"
          },
          {
            "kind": "json_path_equals",
            "path": "$[0].revenue",
            "equals": "240000"
          },
          {
            "kind": "json_path_equals",
            "path": "$[1].revenue",
            "equals": "80000"
          }
        ]
      }
    },
    {
      "stepOrder": 21,
      "name": "Không xoá được sản phẩm đang trong đơn",
      "description": "FK RESTRICT trên order_items.product_id, trả 409.",
      "stepType": "HTTP_REQUEST",
      "weight": 3,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "DELETE",
        "path": "/api/v1/products/${productId1}",
        "expected_status": 409,
        "assertions": [
          {
            "kind": "status",
            "equals": 409
          }
        ]
      }
    },
    {
      "stepOrder": 22,
      "name": "Xoá đơn hàng",
      "description": "DELETE đơn trả 204.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "DELETE",
        "path": "/api/v1/orders/${orderId}",
        "expected_status": 204,
        "assertions": [
          {
            "kind": "status",
            "equals": 204
          }
        ]
      }
    },
    {
      "stepOrder": 23,
      "name": "Cascade xoá order_items",
      "description": "SQL xác nhận không còn dòng item mồ côi.",
      "stepType": "DB_QUERY",
      "weight": 3,
      "required": false,
      "timeoutMs": 10000,
      "config": {
        "connection": {
          "db_type": "postgres",
          "db_service": "db",
          "db_port": 5432,
          "database": "bookstore",
          "username": "postgres",
          "password": "postgres"
        },
        "query": "SELECT order_id FROM order_items WHERE order_id NOT IN (SELECT id FROM orders)",
        "expected": {
          "row_count": 0
        }
      }
    },
    {
      "stepOrder": 24,
      "name": "Đơn đã bị xoá",
      "description": "GET lại đơn phải trả 404.",
      "stepType": "HTTP_REQUEST",
      "weight": 1,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "GET",
        "path": "/api/v1/orders/${orderId}",
        "expected_status": 404,
        "assertions": [
          {
            "kind": "status",
            "equals": 404
          }
        ]
      }
    },
    {
      "stepOrder": 25,
      "name": "Xoá sản phẩm sau khi hết tham chiếu",
      "description": "Sau khi xoá đơn, xoá sản phẩm phải thành công.",
      "stepType": "HTTP_REQUEST",
      "weight": 2,
      "required": false,
      "timeoutMs": 5000,
      "config": {
        "method": "DELETE",
        "path": "/api/v1/products/${productId1}",
        "expected_status": 204,
        "assertions": [
          {
            "kind": "status",
            "equals": 204
          }
        ]
      }
    }
  ]
}
```

Tổng weight câu 3: 4+3+2+1+2+2+2+1+2+2+1+1+4+2+3+4+4+4+2+3+3+2+3+1+2 = **60**.

---

## 7. Publish và nộp bài

### 7.1 Publish assignment

```bash
curl -sS -X POST "$GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/publish" \
  -H "Authorization: Bearer $LECTURER_TOKEN"
```

### 7.2 Xin presigned URL để nộp (từng câu)

`planId` lấy từ response tạo plan. Nộp riêng từng câu để tránh DB bị reset giữa các plan:

```bash
# zip chứa app của sinh viên + docker-compose.yml ở thư mục gốc
curl -sS -X POST "$GATEWAY/api/v1/submissions/presigned-url?assignmentId=$ASSIGNMENT_ID&zipFileName=bookstore.zip&planId=$PLAN1_ID" \
  -H "Authorization: Bearer $STUDENT_TOKEN" | tee presign.json
```

Response:

```json
{
  "submissionId": "0f2b2f5e-6d1a-4f0f-9f0e-2a8e6c1b9d10",
  "uploadUrl": "https://web-dev1-rustfs-api.vucongtuanduong.dpdns.org/...",
  "objectName": "submissions/0f2b2f5e-....zip",
  "expiresInMinutes": 15
}
```

### 7.3 PUT file lên RustFS

```bash
UPLOAD_URL=$(jq -r '.uploadUrl' presign.json)
curl -sS -X PUT "$UPLOAD_URL" --upload-file bookstore.zip
```

Không có bước confirm: webhook `ObjectCreated:Put` của RustFS tự đẩy sự kiện sang
submission-service → Kafka → executor.

### 7.4 Theo dõi tiến trình và điểm

```bash
SUBMISSION_ID=$(jq -r '.submissionId' presign.json)

# trạng thái bài nộp
curl -sS "$GATEWAY/api/v1/submissions/$SUBMISSION_ID" \
  -H "Authorization: Bearer $STUDENT_TOKEN" | jq '.data.status'

# điểm của lượt nộp (mỗi plan một dòng result)
curl -sS "$GATEWAY/api/v1/results/$SUBMISSION_ID" \
  -H "Authorization: Bearer $STUDENT_TOKEN" | jq '.data[] | {planId, score, status, isLatest: .latest}'
```

Nếu nộp không kèm `planId`, executor chấm cả 3 plan trong một job — chỉ dùng cách này khi
app tự tạo lại schema sau khi DB bị drop (xem mục 9).

### 7.5 Giảng viên xem kết quả cả lớp

```bash
curl -sS "$GATEWAY/api/v1/assignments/$ASSIGNMENT_ID/results?includeSteps=true" \
  -H "Authorization: Bearer $LECTURER_TOKEN" | jq
```

---

## 8. Trọng số và điểm kỳ vọng

| Plan | Tổng weight các bước | Plan weight | Nếu pass hết | Nếu pass 70% bước |
|------|----------------------|-------------|--------------|-------------------|
| Câu 1 | 32 | 30 | 10.00 | ~7.00 |
| Câu 2 | 41 | 35 | 10.00 | ~7.00 |
| Câu 3 | 60 | 35 | 10.00 | ~7.00 |

Điểm từng plan = `passedWeight / ranWeight × 10` (SKIPPED không tính vào `ranWeight`).
Điểm bài tập = trung bình có trọng số theo `plan.weight` của điểm tốt nhất mỗi plan.
Pass hết cả ba → **10.00**.

Muốn thấy cơ chế SKIPPED: đặt một bước `required: true` ở giữa plan rồi cố tình làm sai
(ví dụ xoá một cột trong app tham chiếu). Các bước sau bị SKIPPED và không kéo `ranWeight`.

---

## 9. Những điểm dễ làm hỏng lượt chấm

1. **DB reset giữa các plan.** Sau mỗi plan, executor drop và create lại database để plan
   sau sạch dữ liệu. App đang chạy không tự tạo lại bảng, nên plan 2 và 3 sẽ `500` nếu chấm
   chung một job. Cách đúng: nộp từng câu với `planId`, hoặc thiết kế mỗi plan tự tạo schema
   bằng `DB_MIGRATION` ở bước 1.
2. **`connection.db_service` là tên service DB trong `docker-compose.yml`.** Executor dùng
   đúng tên này để publish cổng DB ra host cho các bước `DB_*` kết nối; **không có giá trị
   mặc định**. Đề này dùng `db`; nếu compose đặt `postgres` hoặc bỏ trống trường này, cổng
   DB không được publish và các bước DB báo lỗi kết nối kèm gợi ý dialect.
3. **`connection.database` phải trùng `POSTGRES_DB`.** Drop/create database dùng chính tên
   này; sai tên thì reset im lặng không có tác dụng.
4. **`contains_item` so sánh chuỗi thô.** `String.valueOf(120000.00)` là `"120000.0"`, nên
   đừng dùng `contains_item` cho mảng số. Dùng `json_path_equals` (so số bằng `BigDecimal`)
   hoặc đưa điều kiện vào `WHERE` của `DB_QUERY`.
5. **`DB_QUERY` chỉ so `row_count` và `columns`, không so giá trị.** Muốn khẳng định một giá
   trị, đưa điều kiện vào `WHERE` và kỳ vọng `row_count: 1` (xem bước 13 của câu 3), hoặc
   kiểm tra qua HTTP.
6. **Kiểu dữ liệu trong `DB_SCHEMA_CHECK`.** Viết alias PostgreSQL (`varchar`, `numeric`,
   `bigint`, `timestamptz`); `varchar(50)` được chấp nhận vì dialect bỏ phần độ dài.
7. **`INDEX_EXISTS` so đúng tên index**, nên tên index phải nằm trong đề bài. Đừng dựa vào
   tên do Hibernate tự sinh.
8. **`required: true` dừng cả plan.** Chỉ đặt cho bước chuẩn bị dữ liệu; các bước kiểm tra
   nên để `required: false` để vẫn chấm được phần còn lại.
9. **Assertion `kind` viết thường.** `STATUS` hay `JSON_PATH` sẽ bị từ chối lúc lưu step;
   dùng `status`, `json_path`, `json_path_equals`, `array_length`, `contains_item`,
   `body_structure`, `greater_than`, `matches_regex`, `any_of`.
10. **Không dùng `data[]` với placeholder không có ngoặc kép.** Body phải là JSON hợp lệ khi
   gửi bằng `curl`; muốn lặp dữ liệu thì dùng `data[]` với `"${field}"` dạng chuỗi, hoặc
   tách thành nhiều step như tài liệu này.
11. **MySQL/MariaDB:** DDL gây implicit commit, nên `DB_MIGRATION` không rollback được
    `CREATE/ALTER/DROP`. Nếu đổi `db_type`, tách DDL và DML thành hai bước.
12. **Memory/CPU:** giới hạn được áp cho **từng service** trong compose, nên đặt
    `maxMemoryMb >= 768` để app và Postgres đều đủ RAM; để mặc định 256 MB app dễ bị OOM kill
    khi khởi động.
13. **Image phải pull được trong cụm.** Nếu dùng image private, cấu hình registry credential
    cho DinD trước, nếu không bước boot compose sẽ timeout.

---

## 10. Checklist chạy full

- [ ] Tạo lớp, import CSV, cấu hình `score-components`
- [ ] Tạo assignment, lưu `assignmentId`
- [ ] Tạo 3 plan + steps, lưu `planId` từng câu
- [ ] Publish assignment
- [ ] Chuẩn bị 3 file ZIP (một file có thể dùng cho cả 3 câu)
- [ ] Nộp câu 1 với `planId`, chờ `DONE`, xem điểm và `step_results`
- [ ] Xác nhận các bước lọc trả đúng số lượng: `title=java` → 2, `title=CLEAN` → 1,
      `title=python` → 0; `search=MOUSE` → 1; `search=printer` → 0
- [ ] Lặp lại cho câu 2, câu 3
- [ ] Kiểm tra `GET /assignments/{id}/results?includeSteps=true` thấy đủ 3 plan
- [ ] Kiểm tra transcript lớp: điểm EXERCISE lấy từ kết quả tự động
- [ ] Chạy lại một lần cố tình sai (ví dụ bỏ `UNIQUE` trên `products.sku`) để xác nhận
      bước tương ứng FAIL thay vì ERROR
