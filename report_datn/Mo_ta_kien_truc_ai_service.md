# Mô tả sơ đồ kiến trúc dịch vụ Trợ lý AI

## Mục đích

Tài liệu này mô tả sơ đồ kiến trúc mức dịch vụ của **ai-assistant-service**. Sơ đồ cần thể hiện các lớp/thành phần chính, hệ thống bên ngoài, hướng giao tiếp và hai luồng nghiệp vụ: trò chuyện với trợ lý AI và giải thích kết quả chấm. Có thể dùng nội dung này làm đầu vào để dựng sơ đồ kiến trúc cho dịch vụ khác bằng cùng phong cách.

## Phạm vi sơ đồ

Sơ đồ tập trung vào ranh giới bên trong `ai-assistant-service` và các kết nối đi qua ranh giới đó. Không đưa toàn bộ thuộc tính của từng bảng vào hình; các thực thể dữ liệu được gom theo nhóm để sơ đồ dễ đọc. Phân biệt rõ giao tiếp đồng bộ, sự kiện bất đồng bộ và luồng dữ liệu lưu trữ.

## Các thành phần cần vẽ

### Tác nhân và hệ thống bên ngoài

- **Giảng viên / Sinh viên**: sử dụng giao diện web để trò chuyện, xem tiến độ xử lý và nhận giải thích kết quả.
- **Web client**: gửi yêu cầu HTTPS đến API Gateway; nhận cập nhật tiến độ trò chuyện qua Server-Sent Events (SSE).
- **API Gateway**: xác thực JWT, kiểm tra vai trò và chuyển tiếp yêu cầu tới dịch vụ Trợ lý AI. Dịch vụ chỉ nhận yêu cầu nội bộ qua Gateway.
- **LLM provider**: nhà cung cấp mô hình ngôn ngữ lớn, được gọi qua API tương thích OpenAI. Địa chỉ, khóa truy cập và tên mô hình lấy từ cấu hình môi trường; cấu hình hiện dùng mặc định `deepseek-v4-flash`.
- **Course Service**: cung cấp dữ liệu lớp học, sinh viên, bài tập và cấu hình liên quan cho các công cụ nghiệp vụ của agent.
- **Submission Service**: cung cấp thông tin bài nộp của sinh viên.
- **Result Service**: cung cấp kết quả chấm và kết quả từng bước để tạo lời giải thích.

Các lời gọi tới Course Service, Submission Service và Result Service là REST đồng bộ qua các client nội bộ của dịch vụ Trợ lý AI.

### Bên trong ai-assistant-service

Vẽ một khung biên có tiêu đề **ai-assistant-service (Spring Boot)**, bên trong chia thành các lớp sau:

1. **Security và API**
   - Bộ lọc xác thực header nội bộ và thông tin người dùng do Gateway chuyển tiếp.
   - Các controller: `ChatController`, `RunController`, `OperationController`, `PendingActionController`, `AiExplanationController`.
   - Nhận yêu cầu chat/giải thích, truy vấn trạng thái phiên chạy, xác nhận hành động đang chờ và trả kết quả cho client.

2. **Nghiệp vụ hội thoại và giải thích**
   - `ConversationService`: tạo/quản lý hội thoại, lưu tin nhắn và khởi tạo phiên xử lý.
   - `AgentOrchestrator` và `AgentRuntime`: điều phối vòng suy luận, chọn/gọi công cụ và cập nhật trạng thái.
   - `ContextBuilder`, `ContextPreflight`, `GuardChecker`: chuẩn bị ngữ cảnh, kiểm tra dữ liệu/quyền/phạm vi trước khi chạy agent.
   - `AiExplanationService` và `PromptBuilder`: lấy dữ liệu bài nộp/kết quả, tạo prompt và yêu cầu mô hình sinh giải thích có cấu trúc.
   - `ConversationSummarizer`: rút gọn lịch sử hội thoại để quản lý giới hạn ngữ cảnh.

3. **Công cụ agent và tích hợp dịch vụ**
   - `ToolRegistry` / `ToolSelector` / `ToolExecutor`: đăng ký, lựa chọn và thực thi các công cụ.
   - Công cụ đọc dữ liệu phục vụ cả hai vai trò; công cụ riêng cho giảng viên và sinh viên chỉ được cấp theo vai trò/quyền phù hợp.
   - Công cụ nghiệp vụ gọi Course Service, Submission Service hoặc Result Service qua REST client.
   - Các thao tác ghi hoặc nhạy cảm đi qua cơ chế `Operation` và `PendingAction`; yêu cầu cần xác nhận được tạm dừng cho tới khi người dùng xác nhận.
   - `LlmClient` gọi LLM provider; kết quả công cụ và dữ liệu nhạy cảm được kiểm tra/làm sạch trước khi đưa vào prompt hoặc lưu trữ.

4. **Điều phối bất đồng bộ và truyền tiến độ**
   - `RunWorker` xử lý phiên chạy agent ngoài luồng yêu cầu HTTP ban đầu.
   - `SseBroadcaster` phát các sự kiện tiến độ từ dịch vụ tới Web client.
   - Các trạng thái chính của `Run`: `QUEUED`, `RUNNING`, `REQUIRES_ACTION`, `SUCCEEDED`, `FAILED`.

5. **Tầng lưu trữ**
   - **PostgreSQL riêng của dịch vụ**, truy cập qua Spring Data JPA/repository.
   - Nhóm hội thoại: `Conversation`, `Message`, `ConversationSummary`.
   - Nhóm thực thi agent: `Task`, `Run`, `RunEvent`.
   - Nhóm công cụ và hành động: `ToolExecution`, `StoredToolResult`, `Operation`, `PendingAction`.
   - Nhóm giải thích: `AiExplanation`, lưu giải thích theo bài nộp/danh mục để có thể tái sử dụng.
   - Các thực thể hội thoại và dấu vết chạy thuộc cơ sở dữ liệu riêng của dịch vụ; không vẽ kết nối SQL trực tiếp từ dịch vụ này tới cơ sở dữ liệu của dịch vụ khác.

## Các mũi tên và nhãn kết nối

- `Giảng viên / Sinh viên → Web client`: thao tác trên giao diện.
- `Web client → API Gateway → ai-assistant-service`: HTTPS/REST; JWT và vai trò được Gateway xác thực rồi chuyển tiếp qua header tin cậy nội bộ.
- `ai-assistant-service → Web client`: phản hồi REST và SSE cho tiến độ phiên chạy; client có thể truy vấn lại trạng thái phiên.
- `Agent/Tools → Course Service`: REST lấy lớp, bài tập, sinh viên hoặc dữ liệu cấu hình được phép truy cập.
- `Agent/Tools → Submission Service`: REST lấy thông tin bài nộp theo quyền người dùng.
- `Agent/Tools → Result Service`: REST lấy điểm và kết quả từng bước.
- `AiExplanationService → Submission/Result Services`: REST lấy ngữ cảnh bài nộp và dữ liệu chấm cần giải thích.
- `AgentRuntime ↔ LLM provider`: API tương thích OpenAI gửi prompt/ngữ cảnh và nhận phản hồi, có thể gồm yêu cầu gọi công cụ.
- `Các service/controller → PostgreSQL`: đọc/ghi hội thoại, tin nhắn, task, run, event, trạng thái thao tác, kết quả công cụ và lời giải thích.
- `RunWorker → SseBroadcaster → Web client`: sự kiện tiến độ được phát theo thứ tự; dùng nét hoặc màu khác với lời gọi REST.
- `PendingAction → Web client → PendingActionController`: thông báo yêu cầu xác nhận, người dùng xác nhận/từ chối, sau đó agent tiếp tục hoặc kết thúc luồng.

## Luồng chính cần thể hiện

### Trò chuyện với trợ lý AI

1. Người dùng gửi tin nhắn qua Web client và API Gateway.
2. `ChatController`/`ConversationService` xác thực ngữ cảnh người dùng, lưu tin nhắn, tạo `Task`/`Run` ở trạng thái `QUEUED` rồi trả thông tin phiên chạy.
3. `RunWorker` chuyển phiên sang `RUNNING`; `AgentOrchestrator` dựng ngữ cảnh và gọi `AgentRuntime`.
4. Agent gọi LLM. Nếu cần dữ liệu nghiệp vụ, LLM đề xuất công cụ; `ToolExecutor` kiểm tra vai trò/phạm vi và gọi công cụ tương ứng.
5. Công cụ đọc dữ liệu từ các dịch vụ nghiệp vụ qua REST; kết quả công cụ được ghi nhận và gửi lại vào vòng suy luận.
6. Nếu hành động cần xác nhận, tạo `PendingAction`, chuyển run sang `REQUIRES_ACTION`, phát sự kiện SSE và chờ người dùng phản hồi. Sau xác nhận hợp lệ, tiếp tục thực thi; nếu từ chối thì dừng hành động đó.
7. Khi hoàn tất, lưu câu trả lời và sự kiện, chuyển run sang `SUCCEEDED` (hoặc `FAILED` nếu xử lý lỗi), phát sự kiện cuối qua SSE để client cập nhật giao diện.

### Giải thích kết quả chấm

1. Client yêu cầu giải thích cho một bài nộp qua API Gateway.
2. `AiExplanationController` chuyển yêu cầu cho `AiExplanationService`.
3. Dịch vụ truy vấn Submission Service và Result Service để lấy thông tin bài nộp, điểm và kết quả từng bước; kiểm tra quyền sở hữu/phạm vi truy cập.
4. `PromptBuilder` tạo prompt có cấu trúc; `LlmClient` gọi LLM provider và yêu cầu đầu ra JSON.
5. Dịch vụ kiểm tra/ánh xạ phản hồi thành tổng quan và phân tích từng bước, sau đó lưu kết quả hợp lệ vào `AiExplanation` để tái sử dụng.
6. Nếu provider lỗi hoặc phản hồi không hợp lệ, dịch vụ trả kết quả suy giảm phù hợp; không lưu bản thay thế lỗi vào cache.

## Gợi ý bố cục hình

- Đặt **Web client** và **API Gateway** ở phía trái; khung **ai-assistant-service** ở giữa; **LLM provider**, ba dịch vụ nghiệp vụ và **PostgreSQL** ở phía phải hoặc phía dưới.
- Bên trong khung dịch vụ, xếp các lớp theo thứ tự: API/Bảo mật → Nghiệp vụ/Agent → Công cụ/Tích hợp → Điều phối SSE và lưu trữ.
- Làm nổi bật hai luồng nghiệp vụ chat và giải thích bằng hai màu; dùng chú giải riêng cho REST đồng bộ, SSE, thao tác lưu trữ và luồng xác nhận người dùng.
- Dùng tên thành phần tiếng Việt kèm tên lớp kỹ thuật trong ngoặc khi cần. Tránh nhồi danh sách đầy đủ thuộc tính bảng; ưu tiên trách nhiệm, hướng gọi và dữ liệu trao đổi.
- Tiêu đề hình đề xuất: **Kiến trúc dịch vụ Trợ lý AI (ai-assistant-service)**.

## Tham chiếu

- Nội dung thiết kế dịch vụ Trợ lý AI: `Chuong/2_Phan_tich_thiet_ke.tex`, mục `Thiết kế dịch vụ trợ lý AI`.
- Hình 2.35 hiện có là sơ đồ lớp/thực thể giải thích `AiExplanation`, không phải sơ đồ kiến trúc dịch vụ.
- Hình kiến trúc tổng thể hiện có: `Hinhve/Hinh2_31_kien_truc_tong_the.png`.
