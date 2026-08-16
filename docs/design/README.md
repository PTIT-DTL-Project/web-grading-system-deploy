# Design Documents — Web Grading System

Bộ tài liệu thiết kế versioned của hệ thống. Mỗi thay đổi lớn về bài toán/thiết kế sẽ viết file mới, không sửa file cũ.

## Quy ước version

- Tên file: `<chu-de>-v<major>.<minor>.md`
- Khi thay đổi thiết kế/bài toán → viết file mới với version tăng dần (`v1.0` → `v1.1`), để file cũ làm lịch sử.
- Header trong file phải ghi đúng version khớp tên file, kèm ngày và phần thay đổi so với version trước (mục `Changelog`).

## Index

| File | Version | Trạng thái | Ngày | Mô tả |
|---|---|---|---|---|
| [system-design-v1.0.md](system-design-v1.0.md) | v1.0 | Current | 2026-08-16 | Tách service theo use case, giao tiếp giữa services |
| [design-db-v1.0.md](design-db-v1.0.md) | v1.0 | Current | 2026-08-16 | Schema DB cho từng service |
| [execute-plan-v1.0.md](execute-plan-v1.0.md) | v1.0 | Current | 2026-08-16 | Cách thực thi grading thật từ nộp bài đến ra điểm |

## Mối quan hệ

```
system-design-v1.0.md  (service nào, giao tiếp gì)
        │
        ├── design-db-v1.0.md      (DB của từng service)
        └── execute-plan-v1.0.md   (luồng chấm bài chi tiết)
```