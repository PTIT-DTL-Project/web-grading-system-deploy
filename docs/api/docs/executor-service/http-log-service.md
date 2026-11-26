# HttpLogService — executor-service

Nơi lưu: `docs/api/docs/executor-service/http-log-service.md`

Mục đích: giải thích cách lưu log HTTP của từng lần gọi trong bước chấm, cách che header/
query nhạy cảm, cách cắt bớt body lớn và vì sao lưu log không được làm hỏng bài chấm.

---

## 1. Tổng quan

| Thuộc tính | Giá trị |
|---|---|
| Package | `...executor_service.service.infra` |
| Annotation | `@Service`, `@Slf4j`, `@RequiredArgsConstructor` |
| Phụ thuộc | `HttpLogRepository`, `Gson` |
| Ai gọi | `HttpStepExecutor` (sau mỗi request) |

## 2. Hằng số

| Hằng | Giá trị | Ý nghĩa |
|---|---|---|
| `MAX_CAPTURE_CHARS` | `20_000` | Trần ký tự body/response lưu vào DB |
| `SENSITIVE_HEADERS` | authorization, cookie, set-cookie, proxy-authorization, x-api-key, x-gateway-secret | Header bị loại khỏi JSON |
| `SENSITIVE_QUERY_PARAM_PATTERN` | regex pre-signed URL (x-amz-*, signature) | Thay giá trị bằng `REDACTED` |

## 3. Các method

### 3.1 `save(HttpLog httpLog)`

Gọi `httpLogRepository.save` trong try/catch, chỉ log warn khi lỗi. Lý do: log HTTP là dữ
liệu phụ; mất một dòng log không được phép làm bước chấm `ERROR`.

### 3.2 `headersToJson(Map<String, ? extends Collection<String>> headers)`

- Lọc bỏ các header trong `SENSITIVE_HEADERS` (so sánh lowercase).
- Ghép nhiều giá trị bằng `", "`.
- Trả `null` khi không còn header nào — tránh lưu chuỗi `{}` vô nghĩa.

### 3.3 `sanitizeUrl(String url)`

Thay mọi query param thuộc nhóm pre-signed (`X-Amz-Signature`, `X-Amz-Credential`, …,
`signature`) bằng `REDACTED`, giữ tên param. URL null → null.

### 3.4 `isFileContentType(String contentType)`

Trả true cho `multipart/*`, `application/octet-stream`, `image/*`, `video/*`, `audio/*`,
`application/zip`, `application/pdf` (bỏ phần sau `;`). Dùng để quyết định không lưu body
nhị phân vào log.

### 3.5 `truncate(byte[] bytes)`

1. `null`/rỗng → `null`.
2. Decode UTF-8, chạy `sanitizeUrl`-pattern trên toàn chuỗi (body có thể chứa pre-signed URL).
3. Nếu dài hơn 20.000 ký tự: giữ 20.000 ký tự đầu + hậu tố
   `...(truncated 20000/<độ dài gốc>)`.

Quy ước hậu tố dùng chung với các chỗ cắt khác trong hệ thống (review 2026-10-11, phase
A3): `kept/input-chars-at-this-stage`; ở đây mẫu số là độ dài thô vì body chưa bị che header.

## 4. Trường hợp biên

| Tình huống | Hành vi |
|---|---|
| DB log lỗi/đầy | Warn, bước chấm vẫn chạy tiếp |
| Header trùng tên khác hoa thường | Bị lọc vì so sánh lowercase |
| Body nhị phân | Caller phải kiểm `isFileContentType` trước khi gọi `truncate` |
| Chuỗi UTF-8 bị cắt giữa ký tự | Cắt theo `String.length()` (ký tự Java), không theo byte |

## 5. Liên kết

- Ghi bởi `HttpStepExecutor` — xem `http-step-executor.md`.
- `EvidenceRedactor` che dữ liệu trong `GradingStepResult`; `HttpLogService` che dữ liệu
  trong bảng `http_logs`. Hai lớp bổ sung nhau, không thay thế nhau.