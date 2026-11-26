# StepContext — executor-service

Nơi lưu: `docs/api/docs/executor-service/step-context.md`

Mục đích: giải thích cấu trúc tham số mà mỗi bước chấm nhận, vì sao nó là class thường
thay vì record, và cách dùng `withConfig` cho vòng lặp `data[]`.

---

## 1. Tổng quan

`StepContext` là túi tham số bất biến (immutable) đi kèm mọi lần gọi `StepExecutor.execute`.

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.step` |
| Loại | `public class` (không phải record) |
| Ai tạo | `GradingOrchestrator` |
| Ai dùng | `HttpStepExecutor`, `DbQueryExecutor`, `DbSchemaCheckExecutor`, `DbMigrationExecutor` |

## 2. Các trường

| Trường | Kiểu | Ý nghĩa |
|---|---|---|
| `jobId` | `UUID` | Job chấm đang chạy — dùng để ghi log/saga |
| `planId` | `UUID` | Plan (câu/bài) chứa bước; null khi plan là toàn bài |
| `stepId` | `UUID` | Định danh bước trong config |
| `stepOrder` | `Integer` | Thứ tự bước, dùng cho log và thông điệp lỗi |
| `stepName` | `String` | Tên hiển thị của bước |
| `config` | `JsonNode` | Toàn bộ cấu hình bước (`request`, `assertions`, `connection`, `data[]`, …) |
| `variableContext` | `VariableContext` | Biến thay thế `${...}` dùng chung cả plan |
| `timeoutMs` | `Integer` | Trần thời gian cho bước (nếu cấu hình có) |

## 3. Vì sao không dùng `record`

Javadoc của lớp nêu lý do: record sẽ sinh `equals`, `hashCode`, `toString` theo identity
mà không consumer nào dùng, còn việc khởi tạo thì vẫn là constructor 8 tham số. Dùng class
thường giữ được constructor tường minh và getter rõ ràng, tránh thêm ngữ nghĩa không cần.

## 4. `withConfig(JsonNode config)`

Trả về **bản sao** của context với `config` mới, giữ nguyên job/plan/step/variable/timeout.

Dùng trong vòng lặp `data[]` của bước HTTP: mỗi dòng dữ liệu được thay vào một config mới,
nhưng cả vòng lặp vẫn chia sẻ cùng `VariableContext` (biến do các dòng trước sinh ra có thể
được dòng sau đọc).

```text
ctx (config gốc)
  ├── withConfig(row0) → execute → biến mới ghi vào variableContext
  ├── withConfig(row1) → execute (đọc được biến của row0)
  └── ...
```

## 5. Bất biến & an toàn thread

Mọi trường `final`, không có setter; `config` là `JsonNode` chỉ đọc; `variableContext` là
object chia sẻ có thể thay đổi bên trong (xem tài liệu `variable-context.md`) nên bản thân
`StepContext` an toàn khi truyền qua lại, còn tính nhất quán biến phụ thuộc `VariableContext`.

## 6. Liên kết

- Tạo: `GradingOrchestrator` (khi lặp bước).
- Dùng: các executor trong `step/impl/`.
- Liên quan: `variable-context.md`, `step-executor.md`, `step-registry.md`.