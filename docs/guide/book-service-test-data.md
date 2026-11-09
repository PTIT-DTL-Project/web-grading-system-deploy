# Lab 01 Book Service — lecturer test data

> **Purpose:** Ready-to-load test plans + steps that grade a student's Book CRUD exercise service.
> Load top-to-bottom: create the plans first, then each plan's steps in `stepOrder` sequence.
> Every `config` below passes `StepConfigValidator` and every assertion is evaluable by `AssertionEngine`
> (`status`, `contains`, `json_path`, `body_equals`, `body_structure` only).
> Related: `docs/design/http-test-plan-config.md` (config schema + executor behavior).

## Student API contract under test

| Endpoint | Expected behavior |
|---|---|
| `POST /api/v1/books` `{title, author, year}` | New title → **201** + body contains `id`; duplicate title → **409** with `already exists` in body |
| `GET /api/v1/books/{id}` | Known id → **200**; unknown id → **404** |
| `PUT /api/v1/books/{id}` | Known id → **200** |
| `DELETE /api/v1/books/{id}` | Known id → **200**; afterwards `GET` → **404** |
| `GET /api/v1/books?author=X` / `?title=Y` | **200** filtered array; non-matching filter → **200** `[]` |
| `POST /api/v1/books` missing `title` | **400** mentioning `title` |

Assumption: the list endpoint returns a JSON **array**. If your spec wraps it (`{data, meta}`),
move the list assertions to `json_path` on `$.data`.

If your spec returns duplicate-create as **400** instead of 409, change only `expected_status` in Plan 1 S2.

## Plan 1 — CRUD Basic (`sequenceOrder: 1`, `weight: 10`)

### S1 — Create a book (`stepOrder: 1`, `HTTP_REQUEST`, weight 2, required)
Description: `Create POST /api/v1/books. Send title, author, year; expect 201 and save id as bookId.`
```json
{"stepOrder": 1, "name": "Create a book",
 "description": "Create POST /api/v1/books. Send title, author, year; expect 201 and save id as bookId.",
 "stepType": "HTTP_REQUEST", "weight": 2, "required": true,
 "config": {"method": "POST", "path": "/api/v1/books",
            "headers": {"Content-Type": "application/json"},
            "body": {"title": "Dế Mèn Phiêu Lưu Ký", "author": "Tô Hoài", "year": 1941},
            "expected_status": 201,
            "assertions": [{"kind": "json_path", "path": "$.id"}],
            "extract": [{"name": "bookId", "from": "response_body", "expression": "$.id"}]}}
```

### S2 — Create the same book again → already exists (`stepOrder: 2`, `HTTP_REQUEST`, weight 2, required)
Same body as S1. Description: `Post the identical book again; a correct service rejects the duplicate.`
```json
{"stepOrder": 2, "name": "Duplicate book is rejected",
 "description": "Post the identical book again; a correct service rejects the duplicate.",
 "stepType": "HTTP_REQUEST", "weight": 2, "required": true,
 "config": {"method": "POST", "path": "/api/v1/books",
            "headers": {"Content-Type": "application/json"},
            "body": {"title": "Dế Mèn Phiêu Lưu Ký", "author": "Tô Hoài", "year": 1941},
            "expected_status": 409,
            "assertions": [{"kind": "contains", "text": "already exists"}]}}
```

### S3 — Read it back (`stepOrder: 3`, `HTTP_REQUEST`, weight 2, required)
Description: `GET the book created in step 1 using the extracted bookId.`
```json
{"stepOrder": 3, "name": "Read the book",
 "description": "GET the book created in step 1 using the extracted bookId.",
 "stepType": "HTTP_REQUEST", "weight": 2, "required": true,
 "config": {"method": "GET", "path": "/api/v1/books/${bookId}",
            "expected_status": 200,
            "assertions": [{"kind": "contains", "text": "Dế Mèn Phiêu Lưu Ký"},
                           {"kind": "json_path", "path": "$.author"}]}}
```

### S4 — Read a missing book → 404 (`stepOrder: 4`, `HTTP_REQUEST`, weight 1, required)
Description: `GET a random id; a correct service answers 404, not 200 with null.`
```json
{"stepOrder": 4, "name": "Missing book is 404",
 "description": "GET a random id; a correct service answers 404, not 200 with null.",
 "stepType": "HTTP_REQUEST", "weight": 1, "required": true,
 "config": {"method": "GET", "path": "/api/v1/books/00000000-0000-0000-0000-000000000000",
            "expected_status": 404}}
```

### S5 — Update the year (`stepOrder: 5`, `HTTP_REQUEST`, weight 2, required)
Description: `Change only the year, then check the year field in the response.`
```json
{"stepOrder": 5, "name": "Update the year",
 "description": "Change only the year, then check the year field in the response.",
 "stepType": "HTTP_REQUEST", "weight": 2, "required": true,
 "config": {"method": "PUT", "path": "/api/v1/books/${bookId}",
            "headers": {"Content-Type": "application/json"},
            "body": {"year": 1942},
            "expected_status": 200,
            "assertions": [{"kind": "json_path", "path": "$.year"}]}}
```

### S6 — Delete it (`stepOrder: 6`, `HTTP_REQUEST`, weight 1, not required)
Description: `Delete the book; grading continues even if this step fails.`
```json
{"stepOrder": 6, "name": "Delete the book",
 "description": "Delete the book; grading continues even if this step fails.",
 "stepType": "HTTP_REQUEST", "weight": 1, "required": false,
 "config": {"method": "DELETE", "path": "/api/v1/books/${bookId}",
            "expected_status": 200}}
```

### S7 — Prove it is gone (`stepOrder: 7`, `HTTP_REQUEST`, weight 1, required)
One step asserts one response, so the post-delete read is its own step.
Description: `The deleted book must now answer 404.`
```json
{"stepOrder": 7, "name": "Deleted book is gone",
 "description": "The deleted book must now answer 404.",
 "stepType": "HTTP_REQUEST", "weight": 1, "required": true,
 "config": {"method": "GET", "path": "/api/v1/books/${bookId}",
            "expected_status": 404}}
```

### S8 — Schema exists (`stepOrder: 8`, `DB_SCHEMA_CHECK`, weight 2, required)
Description: `The books table, title column and primary key must exist.`
```json
{"stepOrder": 8, "name": "Check DB schema",
 "description": "The books table, title column and primary key must exist.",
 "stepType": "DB_SCHEMA_CHECK", "weight": 2, "required": true,
 "config": {"checks": [{"kind": "TABLE_EXISTS", "table_name": "books"},
                       {"kind": "COLUMN_EXISTS", "table_name": "books", "column_name": "title"},
                       {"kind": "PRIMARY_KEY", "table_name": "books", "column": "id"}]}}
```

## Plan 2 — Validation & Search (`sequenceOrder: 2`, `weight: 5`)

### S1 — Missing title → 400 (`stepOrder: 1`, `HTTP_REQUEST`, weight 2, required)
Description: `A book without a title must be rejected with 400.`
```json
{"stepOrder": 1, "name": "Missing title is 400",
 "description": "A book without a title must be rejected with 400.",
 "stepType": "HTTP_REQUEST", "weight": 2, "required": true,
 "config": {"method": "POST", "path": "/api/v1/books",
            "headers": {"Content-Type": "application/json"},
            "body": {"author": "No Title"},
            "expected_status": 400,
            "assertions": [{"kind": "contains", "text": "title"}]}}
```

### S2 — Search by title (`stepOrder: 2`, `HTTP_REQUEST`, weight 2, required)
Requires a `Dế Mèn` book in the student DB (seed via `DB_MIGRATION` or a prior POST step).
Description: `Search must return the matching book.`
```json
{"stepOrder": 2, "name": "Search by title",
 "description": "Search must return the matching book.",
 "stepType": "HTTP_REQUEST", "weight": 2, "required": true,
 "config": {"method": "GET", "path": "/api/v1/books",
            "query_params": {"title": "Dế Mèn"},
            "expected_status": 200,
            "assertions": [{"kind": "contains", "text": "Dế Mèn"}]}}
```

### S3 — Data actually persisted (`stepOrder: 3`, `DB_QUERY`, weight 2, required)
Description: `The searched book must really be stored in the database.`
```json
{"stepOrder": 3, "name": "Verify data in DB",
 "description": "The searched book must really be stored in the database.",
 "stepType": "DB_QUERY", "weight": 2, "required": true,
 "config": {"query": "SELECT title, author, year FROM books WHERE title = 'Dế Mèn Phiêu Lưu Ký'",
            "expected": {"row_count": 1, "columns": ["title", "author", "year"]}}}
```

### S4–S6 — Create three books (`stepOrder: 4,5,6`, `HTTP_REQUEST`, weight 1 each, required)
Distinct titles so the filter has something to discriminate; each extracts its id.
Descriptions: `Create book A/B/C for the filter checks below.`
```json
{"stepOrder": 4, "name": "Create book A",
 "description": "Create book A for the filter checks below.",
 "stepType": "HTTP_REQUEST", "weight": 1, "required": true,
 "config": {"method": "POST", "path": "/api/v1/books",
            "headers": {"Content-Type": "application/json"},
            "body": {"title": "Dế Mèn Phiêu Lưu Ký", "author": "Tô Hoài", "year": 1941},
            "expected_status": 201,
            "extract": [{"name": "bookA", "from": "response_body", "expression": "$.id"}]}}
```
```json
{"stepOrder": 5, "name": "Create book B",
 "description": "Create book B for the filter checks below.",
 "stepType": "HTTP_REQUEST", "weight": 1, "required": true,
 "config": {"method": "POST", "path": "/api/v1/books",
            "headers": {"Content-Type": "application/json"},
            "body": {"title": "Số Đỏ", "author": "Vũ Trọng Phụng", "year": 1936},
            "expected_status": 201,
            "extract": [{"name": "bookB", "from": "response_body", "expression": "$.id"}]}}
```
```json
{"stepOrder": 6, "name": "Create book C",
 "description": "Create book C for the filter checks below.",
 "stepType": "HTTP_REQUEST", "weight": 1, "required": true,
 "config": {"method": "POST", "path": "/api/v1/books",
            "headers": {"Content-Type": "application/json"},
            "body": {"title": "Tắt Đèn", "author": "Ngô Tất Tố", "year": 1939},
            "expected_status": 201,
            "extract": [{"name": "bookC", "from": "response_body", "expression": "$.id"}]}}
```

### S7 — Filter by author returns only his books (`stepOrder: 7`, `HTTP_REQUEST`, weight 2, required)
`contains` proves the right book is present; the 1-element `body_structure` proves the filter narrowed to exactly one item (structure-only, values don't matter).
Description: `Filtering by author must return exactly that author's books.`
```json
{"stepOrder": 7, "name": "Filter by author",
 "description": "Filtering by author must return exactly that author's books.",
 "stepType": "HTTP_REQUEST", "weight": 2, "required": true,
 "config": {"method": "GET", "path": "/api/v1/books",
            "query_params": {"author": "Tô Hoài"},
            "expected_status": 200,
            "assertions": [{"kind": "contains", "text": "Dế Mèn Phiêu Lưu Ký"},
                           {"kind": "body_structure",
                            "json": [{"id": "", "title": "", "author": "", "year": 0}]}]}}
```

### S8 — Filter by title (`stepOrder: 8`, `HTTP_REQUEST`, weight 2, required)
Description: `Filtering by title must return the matching book.`
```json
{"stepOrder": 8, "name": "Filter by title",
 "description": "Filtering by title must return the matching book.",
 "stepType": "HTTP_REQUEST", "weight": 2, "required": true,
 "config": {"method": "GET", "path": "/api/v1/books",
            "query_params": {"title": "Đỏ"},
            "expected_status": 200,
            "assertions": [{"kind": "contains", "text": "Số Đỏ"}]}}
```

### S9 — Non-matching filter returns empty, not everything (`stepOrder: 9`, `HTTP_REQUEST`, weight 1, required)
This step catches "filter ignored, return-all" implementations. The engine has no negative-contains, so exact-empty is used instead.
Description: `A filter matching nothing must return an empty list.`
```json
{"stepOrder": 9, "name": "Empty filter result",
 "description": "A filter matching nothing must return an empty list.",
 "stepType": "HTTP_REQUEST", "weight": 1, "required": true,
 "config": {"method": "GET", "path": "/api/v1/books",
            "query_params": {"author": "Nobody XYZ"},
            "expected_status": 200,
            "assertions": [{"kind": "body_equals", "json": []}]}}
```

## Load order and rules

1. Create Plan 1 (`sequenceOrder: 1`), then its steps S1–S8 in order; then Plan 2 (`sequenceOrder: 2`), then its steps S1–S9.
2. Re-posting the same `sequenceOrder` in one assignment → 400; same `stepOrder` in one plan → 400. Each step above uses a distinct order.
3. Cross-scope repeats are allowed: same `sequenceOrder` in a different assignment, or same `stepOrder` in a different plan, still returns 201.
4. Student-facing text comes from each step's `description`; raw `config` is hidden from students.
5. Verified live against course-service (Phase 2 of this task): every create above returned 201; see the Postman `create a plan` / `create a step` items for the captured `201 Lab 01 Book data` examples.
