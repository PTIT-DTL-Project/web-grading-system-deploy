# Plan: Sửa lỗi HTTP 500 ClassCastException (ByteArrayHttpMessageConverter) trên course/result/submission service

## 1. Lỗi đang gặp

Stacktrace từ course-service (`2026-11-08T10:05:25Z`):

```
java.lang.ClassCastException: class vn.edu.ptit.web_grading_system.course_service.dto.response.ApiResponse cannot be cast to class [B
at org.springframework.http.converter.ByteArrayHttpMessageConverter.getContentLength(ByteArrayHttpMessageConverter.java:38)
```

- 3 service **bị lỗi**: `course-service`, `result-service`, `submission-service` (cùng cấu trúc `FormatRestResponse`).
- 3 service **bình thường**: `api-gateway`, `ai-assistant-service`, `executor-service` (không có `FormatRestResponse`).

Lỗi **không liên quan** đến observability stack (Prometheus/Grafana/Tempo) mà nhóm vừa sửa.

## 2. Nguyên nhân gốc

Mỗi service bị lỗi có lớp `@ControllerAdvice implements ResponseBodyAdvice<Object>`:

- `course-service/.../util/FormatRestResponse.java`
- `result-service/.../util/FormatRestResponse.java`
- `submission-service/.../util/FormatRestResponse.java`

`supports()` trả về `true` cho **tất cả** `HttpMessageConverter`, kể cả `ByteArrayHttpMessageConverter`.

Khi client gửi `Accept: application/octet-stream` (hoặc content negotiation rơi về converter byte array), Spring:
1. Gọi `beforeBodyWrite()` → `FormatRestResponse` wrap body thành `ApiResponse` và trả về object.
2. Sau đó dùng `ByteArrayHttpMessageConverter.write()` để ghi object đó → converter chỉ nhận `byte[]`, ép kiểu `ApiResponse` sang `byte[]` → `ClassCastException` → HTTP 500.

`course-service/FormatRestResponse.java` đã có comment nhận ra vấn đề này (dòng 37-41) nhưng chỉ xử lý **sau khi** `beforeBodyWrite` đã chạy, chưa ngăn `supports()` trả về `true` cho `ByteArrayHttpMessageConverter`.

## 3. Cách sửa

Sửa `supports()` trong cả 3 file để **từ chối** `ByteArrayHttpMessageConverter`,Spring sẽ không gọi `beforeBodyWrite` cho converter đó và sẽ ghi thẳng `byte[]` nếu thực sự cần.

### file cần sửa

| Service | File |
|---|---|
| course-service | `src-services/course-service/src/main/java/vn/edu/ptit/web_grading_system/course_service/util/FormatRestResponse.java` |
| result-service | `src-services/result-service/src/main/java/vn/edu/ptit/web_grading_system/result_service/util/FormatRestResponse.java` |
| submission-service | `src-services/submission-service/src/main/java/vn/edu/ptit/web_grading_system/submission_service/util/FormatRestResponse.java` |

### Thay đổi code

Trong `supports()`, thêm kiểm tra loại converter:

```java
import org.springframework.http.converter.ByteArrayHttpMessageConverter;

@Override
public boolean supports(MethodParameter returnType,
        Class<? extends HttpMessageConverter<?>> converterType) {
    // Không wrap khi Spring chọn ByteArrayHttpMessageConverter (ví dụ client
    // gửi Accept: application/octet-stream). Converter này chỉ ghi byte[],
    // ép ApiResponse sang byte[] sẽ ném ClassCastException -> HTTP 500.
    return converterType != ByteArrayHttpMessageConverter.class;
}
```

Lưu ý: `course-service` đã import `HttpMessageConverter` và `MediaType` nhưng chưa import `ByteArrayHttpMessageConverter`.

Sau khi sửa, phần set content type trong `beforeBodyWrite` (dòng 37-41 course-service) có thể giữ lại làm phòng thủ, nhưng lỗi gốc đã được ngăn ở `supports()`.

## 4. Kiểm chứng

- Build từng service: `./mvnw -q compile -pl <service>`.
- Chạy unit test `FormatRestResponseTest` (đã bổ sung cho cả 3 service):

```bash
./mvnw -q test -Dtest=FormatRestResponseTest
```

Test mới khóa lại hành vi `supports()`:
- `supports_rejectsByteArrayConverter`: `ByteArrayHttpMessageConverter` → `false`.
- `supports_acceptsOtherConverters`: `MappingJackson2HttpMessageConverter` → `true`.

File test:
- `course-service/src/test/.../course_service/util/FormatRestResponseTest.java` (đã có sẵn, bổ sung 2 test mới)
- `result-service/src/test/.../result_service/util/FormatRestResponseTest.java` (mới tạo)
- `submission-service/src/test/.../submission_service/util/FormatRestResponseTest.java` (mới tạo)

- Gửi request với header `Accept: application/octet-stream` đến endpoint của course-service (ví dụ `GET /api/v1/assignments/{id}`) và xác nhận trả về 200 JSON thay vì 500.
- Truy Prometheus (`monitoring-kube-prometheus-prometheus.observability.svc.cluster.local:9090`) và chạy:

```promql
sum by (service) (rate(http_server_requests_seconds_count{status="500"}[5m]))
```

Tỷ lệ 500 của course/result/submission cần giảm về gần 0.

## 5. Ghi nhớ

- Không sửa observability stack cho lỗi này.
- Không commit/push lên `main`; tạo branch `fix/http-500-bytearray-converter` rồi PR.
- Cập nhật `docs/design/usecase-flows.md` nếu có luồng gọi API liên quan đến backend metric.
