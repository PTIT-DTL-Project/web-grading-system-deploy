# DbQueryExecutor — executor-service

Nơi lưu: `docs/api/docs/executor-service/db-query-executor.md`

Mục đích: giải thích bước `DB_QUERY`: chạy câu SQL của giảng viên, so khớp `row_count` và
danh sách cột, sinh `AssertionDetail`, và các giới hạn timeout.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.step.impl` |
| Annotation | `@Component`, `@RequiredArgsConstructor` |
| `type()` | `Constant.DbStep.TYPE_QUERY` (`DB_QUERY`) |
| Phụ thuộc | `DbConnectionHelper`, Jackson `ObjectMapper` |

## 2. Cấu hình bước (`config`)

| Trường | Ý nghĩa |
|---|---|
| `query` | Câu SQL, có thể chứa `${var}` |
| `timeout_ms` | Timeout riêng; thiếu thì dùng `ctx.timeoutMs`, cuối cùng mặc định 30.000 ms |
| `expected.row_count` | Số dòng kỳ vọng (tuỳ chọn) |
| `expected.columns` | Danh sách tên cột kỳ vọng, so khớp **theo thứ tự**, không phân biệt hoa thường (tuỳ chọn) |
| `connection.*` | `db_type`, `database`, `username`, `password` |

Cổng DB lấy từ `VariableContext` với key `Constant.VariableContext.DB_PORT` — do
orchestrator đặt sau khi boot container.

## 3. Luồng `execute(ctx)`

1. `substitute(query)` để thay biến `${...}`.
2. Lấy `hostPort`, tính `timeoutMs`, `timeoutSeconds = ceil(ms/1000)`.
3. `db.withConnection(config, hostPort, timeoutMs, ...)`:
   - Tạo `Statement`, `setQueryTimeout(timeoutSeconds)`.
   - `executeQuery`, đọc `ResultSetMetaData.getColumnLabel(i)` cho từng cột (giữ alias
     `AS`), rồi đếm dòng bằng `while (rs.next())`.
4. Nếu `expected` là object:
   - Có `row_count` → thêm assertion `ASSERT_ROW_COUNT` với message
     `row_count expected %d, actual %d`.
   - Có `columns` → so khớp số lượng và từng vị trí (lowercase hai phía); thêm assertion
     `ASSERT_COLUMNS`, message `columns matched` hoặc `columns mismatch: expected ..., actual ...`.
5. `SQLException` → `buildResult(ERROR, details, DbStepResults.message(e), started)`.
6. Không lỗi: `passed = mọi AssertionDetail.passed`; trả `PASSED`/`FAILED`.

## 4. Điểm thiết kế đáng chú ý

- **Không có assertion nào** (không khai `expected`) → `details` rỗng, `allMatch` trên
  danh sách rỗng là `true` → bước `PASSED` miễn câu SQL chạy được. Đây là hành vi có chủ
  đích: bước chỉ kiểm tra "query không lỗi".
- **Cột so theo thứ tự**: `SELECT *` khác thứ tự cột sẽ fail; giảng viên nên viết `SELECT`
  tường minh hoặc dùng alias.
- **Kết nối lỗi** → `ERROR` kèm gợi ý dialect (`CONNECTION_DIALECT_PREFIX`), khác với lỗi
  câu lệnh có tiền tố `SQL_EXECUTION_ERROR`.
- **Ghi chú bảo mật trong Javadoc**: biến thay thế có thể đến từ response của app sinh viên
  (`extract[]`), nên khuyến nghị chỉ dùng biến hệ thống như `${submission_id}`; DB chấm là
  DB dùng một lần của chính sinh viên nên phạm vi ảnh hưởng hẹp.

## 5. Trường hợp biên

| Tình huống | Kết quả |
|---|---|
| `query` rỗng | `executeQuery("")` → `SQLException` → `ERROR` |
| `expected.columns` rỗng | So khớp 0 cột với số cột thực → fail nếu query trả cột |
| Query trả cột trùng tên | `columns` chứa cả hai, so khớp vị trí vẫn đúng |
| Timeout DB | Driver ném `SQLException` → `ERROR` (message có tiền tố SQL_EXECUTION_ERROR) |
| `hostPort` null | `DbConnectionException` → `ERROR` |

Xem thêm: `db-connection-helper.md`, `db-step-results.md`, `assertion-engine.md`.