# DbStepResults — executor-service

Nơi lưu: `docs/api/docs/executor-service/db-step-results.md`

Mục đích: giải thích factory dùng chung cho kết quả ba bước DB, quy tắc gắn nhãn
`SQLException`, và vì sao lớp này là package-private.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.step.impl` |
| Khai báo | `final class DbStepResults` — package-private, constructor private |
| Ai dùng | `DbQueryExecutor`, `DbSchemaCheckExecutor`, `DbMigrationExecutor` |

Lớp chỉ có static method, không phải bean. Nó gom phần tạo `GradingStepResult` và phần
dịch message `SQLException` để ba executor không lặp code.

## 2. `buildResult(...)`

Chữ ký:

```java
static GradingStepResult buildResult(ObjectMapper mapper, StepContext ctx, String stepType,
        StepResultStatus status, List<AssertionDetail> details, String err, long startedMs)
```

| Tham số | Ý nghĩa |
|---|---|
| `mapper` | Jackson `ObjectMapper` để serialize danh sách assertion |
| `ctx` | Nguồn `jobId`, `planId`, `stepId`, `stepOrder`, `stepName` |
| `stepType` | `DB_QUERY` / `DB_SCHEMA_CHECK` / `DB_MIGRATION` |
| `status` | `PASSED` / `FAILED` / `SKIPPED` / `ERROR` |
| `details` | Danh sách `AssertionDetail`; rỗng → cột JSON null |
| `err` | Thông điệp lỗi (null nếu đạt) |
| `startedMs` | Mốc `System.currentTimeMillis()` đầu bước |

Xử lý:

1. Serialize `details`; nếu lỗi serialize thì log warn và để `assertionResult = null`
   thay vì nuốt lặng (review 2026-09-26, Pullfrog round 4).
2. `durationMs = now - startedMs`.
3. `startedAt` dựng từ `startedMs` theo zone hệ thống; `completedAt = now`.
4. Build `GradingStepResult` với đủ job/plan/step/stepType/status/error/duration.

## 3. `message(SQLException e)` — quy tắc gắn nhãn

```text
e instanceof DbConnectionException   → giữ nguyên message (đã có gợi ý dialect)
e instanceof DbStepTimeoutException → giữ nguyên message (SQL_TIMEOUT_ERROR)
còn lại                              → SQL_EXECUTION_ERROR + e.getMessage()
```

Lý do tách: hai exception đầu do `DbConnectionHelper` ném và đã được viết cho người đọc
(gợi ý kiểm tra cổng/credential, hoặc timeout); các `SQLException` còn lại là lỗi câu lệnh
thật sự nên cần tiền tố để phân biệt trong log.

## 4. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| `details` rỗng | `assertionResult = null` |
| `mapper.writeValueAsString` lỗi | Warn + null, không ném |
| `startedMs` ở tương lai | `durationMs` âm — không kiểm tra, caller truyền đúng |

## 5. Liên kết

- Được gọi ở cuối mỗi executor DB, kể cả nhánh lỗi.
- Ba executor: `db-query-executor.md`, `db-schema-check-executor.md`, `db-migration-executor.md`.
- `DbConnectionHelper` ném hai exception đặc biệt — xem `db-connection-helper.md`.