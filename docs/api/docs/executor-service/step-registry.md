# StepRegistry — executor-service

Nơi lưu: `docs/api/docs/executor-service/step-registry.md`

Mục đích: giải thích cách `StepRegistry` gom tất cả `StepExecutor` bean thành bảng tra
cứu theo `step_type`, cách phát hiện trùng khoá, và cách orchestrator tra cứu executor.

---

## 1. Tổng quan

`StepRegistry` là `@Component` không giữ trạng thái nghiệp vụ, chỉ giữ một `Map` bất biến
từ `step_type` → `StepExecutor`.

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.step` |
| Annotation | `@Component` |
| Constructor | `StepRegistry(List<StepExecutor>)` — Spring inject toàn bộ bean implements interface |
| Ai gọi | `GradingOrchestrator` (khi chạy từng bước), test tích hợp |

## 2. Cơ chế đăng ký

1. Spring quét `step/impl/` và tạo bean cho mọi class implements `StepExecutor`.
2. Constructor nhận `List<StepExecutor>` (toàn bộ bean), dựng map bằng
   `Collectors.toUnmodifiableMap(StepExecutor::type, identity)`.
3. Hàm merge của collector **cố tình ném** `IllegalStateException` khi hai executor khai
   báo cùng `type()`; message nêu tên hai class để sửa ngay. Nhờ vậy lỗi trùng khoá lộ ra
   lúc khởi động, không phải lúc chấm bài.
4. Map là `toUnmodifiableMap` — không thể thêm/bớt executor lúc runtime.

## 3. API

### 3.1 `StepExecutor of(String type)`

| Khía cạnh | Nội dung |
|---|---|
| Input | `type` — giá trị `step_type` từ grading config |
| Output | implementation tương ứng |
| Lỗi | `IllegalArgumentException(Constant.Message.UNKNOWN_STEP_TYPE + type)` khi không tìm thấy |

Đây là điểm duy nhất ánh xạ chuỗi cấu hình sang code chạy thật. Orchestrator gọi
`stepRegistry.of(step.getStepType())` rồi mới dựng `StepContext`.

## 4. Thêm loại bước mới

Không sửa `StepRegistry`. Chỉ cần thêm một `@Component` implements `StepExecutor` với
`type()` mới; Spring tự inject vào danh sách. Nếu quên `@Component`, executor không được
đăng ký và mọi bước loại đó sẽ nhận `UNKNOWN_STEP_TYPE`.

## 5. Sơ đồ

```text
Spring context
   │ List<StepExecutor> = [HttpStepExecutor, DbQueryExecutor, DbSchemaCheckExecutor, DbMigrationExecutor]
   ▼
StepRegistry(Map<type, executor>)
   │ of("HTTP")
   ▼
HttpStepExecutor
```

## 6. Ghi chú thiết kế

- Cùng pattern với `DbDialectRegistry`: registry tự gom bean, thêm biến thể = thêm class,
  không sửa registry.
- Map bất biến nên an toàn khi nhiều thread chấm song song (thực tế pool chấm là 1 thread,
  nhưng registry vẫn không phải điểm tranh chấp).

---

## Chi tiết từng hàm

### `StepRegistry(List<StepExecutor> executors)` (constructor)

| Khía cạnh | Nội dung |
|---|---|
| Input | Spring inject toàn bộ bean `StepExecutor` (kể cả `@Component` của module khác) |
| Output | map `type → executor`, không cho null |

Thu `Collectors.toUnmodifiableMap(StepExecutor::type, identity, merge)`; hàm merge chỉ
chạy khi trùng khoá và ném `IllegalStateException` nêu **cả hai tên lớp** — fail-fast lúc
khởi động, thay vì để plan chọn nhầm executor lúc chấm. Map bất biến nên không ai thêm/bớt
executor sau khi khởi động.

### `StepExecutor of(String type)`

| Khía cạnh | Nội dung |
|---|---|
| Input | `type` lấy từ `plan.steps[].type` trong DB |
| Output | executor tương ứng |
| Lỗi | `IllegalArgumentException` = `Constant.Message.UNKNOWN_STEP_TYPE` + type |

Tra cứu O(1), không cache cục bộ. Thông điệp lỗi chỉ nêu type sai (không liệt kê danh sách
hợp lệ) — khi cần, xem log khởi động hoặc `StepExecutor` implementations trong mã nguồn.
