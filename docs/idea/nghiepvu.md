# 1. Giang vien


## 1.1: Quan ly lop
- 1 giảng viên sẽ có nhiều lớp của từng kỳ, kết thúc mỗi kỳ thì lớp đó sẽ được đưa vào trạng thái archived
- Sinh viên sẽ có tài khoản mặc định do giảng viên cấp, trong mỗi lớp sẽ có sinh viên thuộc lớp đó
- Username mặc định là mã sinh viên, mật khẩu mặc định cũng là mã sinh viên, sinh viên sẽ phải đổi mật khẩu trong lần đầu tiên đăng nhập
- Trong 1 lớp, các sinh viên sẽ được import vào trong lớp đó bởi giảng viên bằng 1 file csv hoặc excel
- 1 sinh viên có thể tham gia nhiều lớp, một giảng viên có thể dạy nhiều lớp
- Trong 1 lớp sẽ có phần quản lý điểm của mỗi sinh viên, có thể nhập tay các điểm ví dụ như điểm chuyên cần. Điểm bài tập do hệ thống chấm


## 1.2 Quan ly danh sach bai tap

### 1.2.1: tao bai tap

Buoc 1: Khai bao docker image duoc dung trong bai

Buoc 2: tao cac buoc de kiem tra


Moi buoc: \
    1. endpoint api (vi du: GET /api/v1/books)
\
    2. request body (neu co)
\
    3. response body (neu co)

- Ngoai ra co the tao series cac buoc de kiem tra xem du lieu co hard code khong?
- vi du: tao 3 record roi thuc hien GET list va filter de kiem tra??


buoc 3: co the tao san docker-compose.yml theo yeu cau de bai hoac yeu cau sinh vien tu viet


### 1.2.2: Luu y ve cac ràng buộc trong khi tạo một bài kiểm tra: 
- 1 bai tap se co nhieu bai tap con de kiem tra (co the hieu la 1 cau)
- trong 1 câu thì sẽ bao gồm nhiều bước. Với mỗi bước sẽ có nhiều kiểu test:

#### 1. Kiểu test endpoint
- Test đúng HTTP Method (GET/POST/PUT/DELETE,...)
- Test đúng Header (nếu có)
- Test đúng URL (path + query params/ path variable)
- Test đúng cấu trúc Request Body truyền vào có nhận không
- Test đúng cấu trúc Response Body trả về
- 

#### 2. Kiểu test database
- Test đúng cấu trúc bảng, cột, khóa chính, khóa ngoại...
- Test đúng dữ liệu được thêm, sửa, xóa, truy vấn...
- Test đúng connection to DB

Tôi đang nghĩ đến có một file kiểu config.yml để liệt kê tất cả các bảng, giảng viên sẽ đưa ra định nghĩa, cấu trúc để sinh viên viết theo file .yaml, ví dụ như:
```yml
database:
    name: Users
    columns:
        - name: id
            type: int
            primary_key: true
        - name: name
            type: string
        - name: email
            type: string
        - name: password
            type: string
exercise-mapping-table:
    ex1: users
    ex2: books
    
```

Tức là để máy chấm có thể biết tìm ở bảng nào, cấu trúc như nào để chấm bài

Phần chấm bài khả năng sẽ là phần khó nhất trong việc thiết kế DB làm sao để scalable và cover được nhiều kiểu test nhất có thể. Có thể define một mẫu yaml mà có thể cover hết các trường hợp, lưu vào trong DB để persist và load lên để chấm bài dựa theo thông tin có được

#### 3. Cũng là kiểu test endpoint nhưng cụ thể hơn, test kiểu auth token 
Tức là đăng nhập, đăng ký nhưng test token trong đó, test phân quyền, ....


### 1.2.3: Luu lai bai tap
Sau khi luu, co mot service quet xem docker image ton tai chua, neu chua thi pull san ve


## 1.3: Chấm bài khi sinh viên nộp
Việc chấm sẽ do hệ thống thực hiện dựa vào config yaml và DB đã được tạo từ trước cũng như kịch bản test mà giảng viên đã tạo

Sinh viên sẽ nộp file zip, trong đó chứa docker compose.yml , Dockerfile, nếu Java thì phải build thành file jar để tăng tốc độ bootup container,.. 

Sau đó file zip sẽ được lưu trong object storage server, và một message sẽ được gửi qua Kafka message đến với executor service, service này sẽ thực hiện chính các async task, task bất đồng bộ. Ví dụ như chấm bài, pull image

executor service sau đó sẽ tải file zip từ object storage server về, giải nén và chạy docker-compose.yml để bootup services, có các thông số về port, api docs như nào từ cấu hình test và tiến hành chạy các bước test


Sau khi chấm bài xong, gửi kết quả đến service nhận kết quả , lưu vào DB và có thể sẽ có service thực hiện phân tích dữ liệu, kết quả nhận được

# 2. Sinh viên

## 2.1: Các usecase cơ bản

- Sinh viên có thể xem danh sách, chi tiết các lớp của mình, danh sách sinh viên lớp đó
- Điểm bài tập của cả lớp
- Xem chi tiết bài tập, các yêu cầu
- Xem điểm của mình
- Xem thống kê
- Làm bài và nộp bài, kiểm tra trạng thái, kết quả của bài nộp


# 3. Hệ thống

_ Đây là phần khó nhất, cách lưu trữ, thiết kế DB để cover hết các trường hợp muốn kiểm tra, mà vẫn có thể scalable trong các trường hợp trong tương lai muốn bổ sung, chỉnh sửa cách test

- Phần khó tiếp theo là làm thế nào để executor service có thể chạy docker services lên (tôi đang cân nhắc dùng testcontainers cho compile scope and runtime scope chứ không phải như test scope thường dùng) và test như nào, http client test như nào??


- Sau này không biết có thể có (hoặc không) notification services để thông báo cho người dùng ???? Cái này cần cân nhắc vì giới hạn phần cứng, RAM, cluster không đủ

