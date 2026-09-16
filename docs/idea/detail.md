

## Mô tả về đề tài
Với giảng viên:

quản lý các lớp học của môn Lập trình Web , quản lý danh sách sinh viên

Quản lý điểm thành phần môn học của sinh viên

Quản lý các bài tập, bài kiểm tra môn học cho sinh viên - giao bài tập, khi sinh viên nộp bài, hệ thống sẽ tự động chấm bài và chấm điểm cho bài làm sinh viên, cập nhật lại điểm bài tập cho sinh viên

Với sinh viên:

Xem danh sách lớp, danh sách thành viên của lớp, điểm thành phần môn học

Xem các bài tập của mình, làm bài và nộp bài, thấy được kết quả, log và nhận xét về bài

Đồ án sẽ tập trung vào việc chấm phần lập trình phía máy chủ (backend) và kiểm tra các điều kiện của CSDL được dùng trong các bài tập, mà muốn chấm được ở phía máy chủ, thì việc chấm tĩnh (chấm chỉ dựa vào mã nguồn) là không khả thi, do đó cần phải chạy được server backend từ mã nguồn bài sinh viên nộp lên để thực hiện các việc kiểm tra API. Mà muốn chạy được server lên cần có cách để tách biệt phần server bài làm của sinh viên, và để làm được điều này cũng như kiểm soát được server thì phương án là sử dụng Docker, các server sẽ được chạy trên các container và phía server hệ thống sẽ có các HTTP client để thực hiện việc kiểm tra theo đúng yêu cầu. Đây chính là phần chính của hệ thống

Về kiến trúc hệ thống, hệ thống sẽ được xây dựng trên kiến trúc Microservices, với một service có nhiệm vụ xác thực, phân quyền, một service đóng vai trò là cổng (API Gateway), trung gian giữa client và các service nội bộ (người dùng không thấy được). Các service nội bộ sẽ tách biệt với nhau bởi vai trò, nghiệp vụ. Các file liên quan (các file sinh viên nộp bài,..) sẽ được quản lý trên một Object Storage Server. Việc giao tiếp giữa các service nội bộ sẽ theo 2 hướng chính: qua API (RESTful API) hoặc theo hướng sự kiện (Event-driven). Các công nghệ được lựa chọn sẽ chủ yếu là mã nguồn mở (open source).

Thách thức lớn nhất của đề tài là việc mở rộng lên, có chấm được nhiều bài sinh viên cùng 1 lúc không ? Kiểm soát như nào ? Ngoài ra, một thách thử không nhỏ khác là cấu hình làm sao để cho giảng viên có thể có càng nhiều lựa chọn, càng nhiều kịch bản để kiểm tra bài tập của sinh viên - không chỉ mỗi API thuần, kiểm tra DB, kiểm tra tính toàn vẹn dữ liệu, tính chính xác, ...

Cơ sở dữ liệu ban đầu:
Mô tả luồng nộp bài cơ bản cho sinh viên: Sinh viên sau khi đọc đề bài và làm bài theo yêu cầu sẽ phải đóng gói tất cả các file liên quan (trong đó có cả Dockerfile, docker-compose.yml và mã nguồn) thành 1 file zip và nộp qua giao diện. Thực chất UI sẽ phải làm 2 nhiệm vụ, một là lấy presigned url cho file đó để sau đó upload trực tiếp đến Object Storage server. Khi object storage server nhận được file, sẽ bắn webhook đến một service chịu trách nhiệm quản lý việc nộp bài, thông báo rằng bài này đã được nộp, service này sẽ thông báo cho service thực hiện việc chấm bài thông qua một Message Queue(theo hướng sự kiện) là Kafka. Service thực hiện việc chấm bài sẽ lắng nghe, nhận tin nhắn và thực hiện việc chấm bài. Khi chấm xong sẽ thông báo kết quả cho các service liên quan.

Ngoài ra, cần phải cấu hình làm sao để cho giảng viên có thể có càng nhiều lựa chọn, càng nhiều kịch bản để kiểm tra bài tập của sinh viên. Ví dụ, không chỉ kiểm tra những HTTP method cơ bản là GET, POST, mà còn cụ thể hơn, ví dụ lọc khi lấy danh sách ra, kiểm tra xem đúng thông tin đã tạo không?; header có đúng yêu cầu không; cấu trúc bảng có đúng không, ràng buộc có bị phá vỡ không, khi gặp các exception thì xử lý như nào?,...
