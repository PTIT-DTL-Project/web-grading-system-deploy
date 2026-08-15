# Hệ thống chấm bài môn Lập trình web (chấm bài kiểu test API Backend)

## Actor
- Giảng viên
- Sinh viên

### Giảng viên
- Tạo yêu cầu (hay còn gọi là các kịch bản test), ví dụ:
    * GET /api/v1/users (query params nếu có, ví dụ page=0&pageSize=10&search...). Response trả về có dạng:\
    {
        "data": ...
    }
Tức là giảng viên có thể tạo ra yêu cầu về http method, endpoint và cả request body, response body và sinh viên phải làm theo yêu cầu đó. Tuy nhiên khi tạo ra các yêu cầu thì request body và response body lại lưu dưới dạng string và sau kiểm tra thì phải kiểm tra theo cấu trúc cú pháp của body, tức là string có thể khác nhau nhưng các key rồi cấu trúc phải giống nhau. Dự tính dùng gson để parse và so sánh, phân tích
- Ngoài ra, để kiểm tra kỹ hơn về mặt dữ liệu, tránh trường hợp sinh viên hard code để nộp, có thể thực hiện tuần tự các hành động, ví dụ: 2 lần POST rồi GET (list) để check xem có tìm kiếm đúng hơn
- Ngoài ra, có thể check được cấu trúc bảng trong DB,...
- Chấm điểm
- Xem điểm
- Xem thống kê điểm

### Sinh viên
- Yêu cầu: Biết sử dụng Docker, biết viết file docker-compose.yml (hoặc nếu không biết viết thì dùng file cho sẵn nhưng hiểu được yêu cầu), đóng gói bài tập
- Code theo yêu cầu giảng viên và viết file Dockerfile(nếu cần), docker-compose.yml để đóng gói
- Xem điểm
- Xem nhận xét

## Ý tưởng kiến trúc hệ thống
Hệ thống xây dựng với kiến trúc microservices, tách biệt làm các service khác nhau, trong đó có 2 service quan trọng:
- Submission service: Service chuyên thực hiện việc nộp bài từ sinh viên, chủ yếu làm việc với object storage (RustFS) để expose các endpoint API làm việc với file (download file, upload file,...)
- Executor service: Service thực hiện nhiệm vụ giải nén file zip mà sinh viên đã nộp và chạy file docker compose để tạo các docker container và sau đó chấm bài theo đúng yêu cầu từ giảng viên (Service quan trọng nhất vì thực hiện nhiệm vụ chính của hệ thống). Service này sẽ xử lý bất đồng bộ, giao tiếp với các service khác qua message queue (kafka) (ví dụ sau khi upload file thành công thì sẽ gửi message qua kafka topic để executor service biết và thực hiện)

## Luồng hoạt động chính: nộp bài
Khi sinh viên nộp bài, service API kiểm tra hợp lệ, lưu file zip lại và lưu vào file server, sau đó gửi message đến executor thực hiện(bất đồng bộ) và trả ra response là đã nộp, sẽ chấm bài sau

Sinh viên có thể nộp bài file zip ở bất kỳ ngôn ngữ nào giảng viên cho phép (python/java spring boot/go/nodejs,...) và server sẽ handle nó. Dựa vào kịch bản giảng viên chọn, tạo một client để call API và test xem đúng format yêu cầu không. Do phải call api nên bài tập sinh viên nộp phải được chạy lên, ở đây dùng docker-compose để chạy, mỗi bài tập của mỗi sinh viên là một container, và client sẽ call vào đó để kiểm tra. Do đó sẽ có vấn đề về scale up với số lượng sinh viên nộp bài lớn

## Module AI

Khi chấm bài sẽ lưu lại các log chi tiết từng yêu cầu một để dễ đọc lại và so sánh sự khác nhau, và có thể làm input cho AI chatbot để nhận xét bài sau này(?)

Nếu thêm module AI nữa khả năng sẽ dùng AI Agent cho giảng viên - giảng viên mô tả chi tiết yêu cầu bằng text cho AI Agent -> hiểu được mong muốn giảng viên -> AI Agent tạo ra được bài tập theo yêu cầu của giảng viên bằng việc dựa vào API docs để gọi API các endpoint phù hợp để tạo được bài tập. Giảng viên chỉ cần chat.

## Tech stack dự kiến
- Backend: Spring Boot
- Message Queue: Kafka
- Frontend: react typescript
- Fileserver, object storage: MiniO/RustFS
- Deployment: Docker, K8s
- Ci/CD qua Github actions, dockerhub và ArgoCD

## Vấn đề có thể gặp phải - cần nghiên cứu giải quyết
Vấn đề số bài cùng chấm trong một thời điểm, vấn đề scale up khi nhiều bài nộp cùng lúc ???