# Plan: Xóa phần observability và tài liệu tham khảo khỏi báo cáo LaTeX

## Mục tiêu
- Xóa toàn bộ nội dung về observability (quan trắc) khỏi Chương 1 (`report_datn/Chuong/1_Co_so_ly_thuyet.tex`) vì phần này chưa triển khai thực tế, chỉ nằm trong code cũ.
- Xóa phần tài liệu tham khảo (bibliography) khỏi báo cáo (`report_datn/BTL.tex`).
- Lưu lại toàn bộ nội dung bị xóa vào plan file này để có thể viết lại sau khi cần.
- Sau khi xóa, báo cáo phải build được không lỗi, mục lục phải chính xác, không còn tham chiếu vỡ (`??`).

## Lưu ý quan trọng
- Người dùng muốn **ghi lại nội dung bị xóa vào đây** để sau này có thể lấy ra viết thêm.
- Plan file này nằm tại: `.opencode/plan/report-observe/` (thư mục đã tồn tại, đang trống).
- Khi thực thi, chuyển sang agent **Build** trước khi sửa file.

---

## 1. Nội dung cần xóa trong `report_datn/Chuong/1_Co_so_ly_thuyet.tex`

### 1.1. Giới thiệu (dòng 7)
Thay dòng:
```
...cơ chế xác thực và phân quyền chặt chẽ, cũng như khả năng quan trắc để đánh giá hiệu năng hệ thống.
```
Thành:
```
...cơ chế xác thực và phân quyền chặt chẽ.
```
(Lỗi bỏ cụm "cũng như khả năng quan trắc để đánh giá hiệu năng hệ thống")

### 1.2. Xóa toàn bộ section 1.9 "Quan trắc hệ thống" (dòng 256–289)
Bao gồm:
- `\section{Quan trắc hệ thống}` (dòng 256)
- `\subsection{Ba trụ cột của quan trắc}` (dòng 259)
- Nội dung ba trụ cột: Metrics, Logs, Traces (dòng 262–267)
- `\subsection{Các thành phần quan trắc cụ thể}` (dòng 269)
- Danh sách thành phần: Prometheus, Grafana, Loki, Tempo/Alloy, Pyroscope, k6 (dòng 272–280)
- Tham chiếu hình: `Hình \ref{fig:observability} vẽ lại...` (dòng 282)
- Figure environment: `\begin{figure}[ht] ... \caption{Ba trụ cột quan trắc và các thành phần cụ thể.} ... \label{fig:observability} ... \end{figure}` (dòng 284–289)

Sau khi xóa, cần kiểm tra xem section kế tiếp là `1.10 Giao diện người dùng phía trước` (dòng 291) có cần điều chỉnh đánh số không. Vì LaTeX đánh số tự động dựa trên thứ tự `\section`, không cần thay đổi thủ công.

### 1.3. Kết luận chương (dòng 314)
Thay dòng:
```
Chương này đã trình bày các cơ sở lý thuyết và công nghệ được lựa chọn: kiến trúc vi dịch vụ với mẫu DB-per-service; nền tảng Java cùng Spring Boot; lưu trữ quan hệ với ORM; trao đổi tin nhắn bất đồng bộ qua Kafka; lưu trữ đối tượng tương thích S3; đóng gói và điều phối bằng Docker và Kubernetes; quản lý danh tính với OAuth 2.0, OIDC và PKCE; quan trắc ba trụ cột; và giao diện React.
```
Thành:
```
Chương này đã trình bày các cơ sở lý thuyết và công nghệ được lựa chọn: kiến trúc vi dịch vụ với mẫu DB-per-service; nền tảng Java cùng Spring Boot; lưu trữ quan hệ với ORM; trao đổi tin nhắn bất đồng bộ qua Kafka; lưu trữ đối tượng tương thích S3; đóng gói và điều phối bằng Docker và Kubernetes; quản lý danh tính với OAuth 2.0, OIDC và PKCE; và giao diện React.
```
(Lỗi bỏ cụm "; quan trắc ba trụ cột")

---

## 2. Nội dung cần xóa trong `report_datn/BTL.tex`

### 2.1. Tài liệu tham khảo (dòng 335, 342–344)
Hiện đang bị comment, nhưng vẫn cần xóa hoàn toàn hoặc giữ comment:
- Dòng 335: `% \chapter*{TÀI LIỆU THAM KẢO}`
- Dòng 342: `\renewcommand\bibname{TÀI LIỆU THAM KẢO}`
- Dòng 343: `\printbibliography`
- Dòng 344: `\phantomsection\addcontentsline{toc}{chapter}{TÀI LIỆU THAM KẢO}`

Quyết định: **Giữ nguyên đã comment** (không sửa thêm), vì người dùng chỉ muốn xóa phần hiển thị, không xóa file `.bib`.

### 2.2. File `.bib`
File `report_datn/Danh_sach_tai_lieu_tham_khao.bib` chứa các entry observability (`majors2022observability`, `prometheusdocs`, `grafanadocs`, `lokidocs`, `tempodocs`, `pyroscopedocs`, `k6docs`...).
Quyết định: **Không xóa file `.bib`**, chỉ ghi danh sách các key bị loại bỏ vào plan file này để có thể tham khảo sau.

---

## 3. Nội dung lưu lại để viết lại sau (backup nội dung)

### 3.1. Section 1.9 toàn bộ (đã xóa khỏi file)
Nội dung chuẩn bị viết lại khi cần:
```latex
\section{Quan trắc hệ thống}
\label{section:1.9}

\subsection{Ba trụ cột của quan trắc}
\label{section:1.9.1}

Observability (quan trắc) là khả năng hiểu được trạng thái nội bộ của một hệ thống thông qua việc quan sát các đầu ra bên ngoài của nó. Trong phát triển phần mềm hiện đại, observability được xây dựng trên ba trụ cột:~\cite{majors2022observability}
\begin{itemize}
    \item Metrics (số liệu): các giá trị định lượng về hiệu năng hệ thống theo thời gian (tỷ lệ request thành công, độ trễ, tài nguyên sử dụng).
    \item Logs (nhật ký): các bản ghi sự kiện do ứng dụng và hệ thống ghi lại theo thời gian thực.
    \item Traces (theo dõi): hồ sơ ghi lại đường đi của một request xuyên qua các dịch vụ, giúp xác định nút thắt cổ chai và lỗi.
\end{itemize}

\subsection{Các thành phần quan trắc cụ thể}
\label{section:1.9.2}

Hệ thống sử dụng bộ công cụ quan trắc toàn diện:
\begin{itemize}
    \item Prometheus thu thập metrics từ endpoint `/actuator/prometheus` của các dịch vụ Spring Boot, cùng các exporter để thu thập số liệu về host và về trạng thái Kubernetes~\cite{prometheusdocs}.
    \item Grafana là nền tảng trực quan hóa, cung cấp dashboard cho metrics, logs và traces~\cite{grafanadocs}.
    \item Loki tập hợp logs từ các container (thông qua promtail) và cho phép truy vấn theo nhãn~\cite{lokidocs}.
    \item Tempo (cùng Alloy - bộ thu thập telemetry OTLP) lưu trữ và cho phép truy vấn traces, giúp theo dõi request xuyên microservices~\cite{tempodocs}.
    \item Pyroscope cung cấp profiling liên tục, ghi nhận cách các thread của ứng dụng sử dụng CPU theo thời gian thực, giúp phát hiện các đoạn code kém hiệu quả~\cite{pyroscopedocs}.
    \item k6 là công cụ kiểm tra hiệu năng (load testing), mô phỏng nhiều user truy cập đồng thời~\cite{k6docs} để đánh giá khả năng mở rộng của hệ thống khi có nhiều sinh viên nộp bài cùng lúc - một trong những thách thức chính của đề tài.
\end{itemize}

Hình \ref{fig:observability} vẽ lại ba trụ cột quan trắc và các thành phần cụ thể.

\begin{figure}[ht]
\centering
\includegraphics[width=\textwidth]{Hinhve/Hinh2_4_lua_ng_cham_bai}
\caption{Ba trụ cột quan trắc và các thành phần cụ thể.}
\label{fig:observability}
\end{figure}
```

### 3.2. Các câu tham chiếu observability đã xóa
- Intro (dòng 7): "cũng như khả năng quan trắc để đánh giá hiệu năng hệ thống"
- Kết luận (dòng 314): "; quan trắc ba trụ cột"

### 3.3. Các bib key liên quan observability (để tự nhận lại sau)
Từ file `report_datn/Danh_sach_tai_lieu_tham_khao.bib`, các key có liên quan observability:
- `majors2022observability`
- `prometheusdocs`
- `grafanadocs`
- `lokidocs`
- `tempodocs`
- `pyroscopedocs`
- `k6docs`

---

## 4. Các file ảnh liên quan (không xóa)
- `report_datn/Hinhve/Hinh2_4_lua_ng_cham_bai.png` — hiện đang được dùng làm hình cho `fig:observability` (tên file có vẻ không khớp nội dung, cần kiểm tra lại khi viết lại phần observability).
- Không xóa file ảnh, chỉ ngừng tham chiếu trong LaTeX.

---

## 5. Các bước thực thi (theo thứ tự)

### Bước 1: Sửa `1_Co_so_ly_thuyet.tex`
a. Xóa cụm "cũng như khả năng quan trắc để đánh giá hiệu năng hệ thống" trong dòng 7.
b. Xóa toàn bộ block section 1.9 (dòng 256–289).
c. Xóa cụm "; quan trắc ba trụ cột" trong dòng 314.

### Bước 2: Xác nhận `BTL.tex`
- Tài liệu tham khảo đã bị comment (dòng 335, 342–344), giữ nguyên.
- Không cần sửa thêm.

### Bước 3: Build kiểm chứng
- Chạy `latexmk` / `pdflatex` trên `report_datn/BTL.tex`.
- Xác nhận: 0 lỗi LaTeX, không còn tham chiếu vỡ `??` (tìm trong PDF text).
- Xác nhận mục lục: không còn mục "Quan trắc hệ thống", không còn mục "TÀI LIỆU THAM KHẢO".
- Xác nhận số trang và đánh số section tự động còn chính xác.

### Bước 4: Ghi lại plan file này (đã làm)
- Nội dung này đã được lưu vào `.opencode/plan/report-observe/` để tham khảo sau.

---

## 6. Kiểm tra sau khi build
- `pdftotext build/BTL.pdf - | grep -n "quan trắc\|Observability\|Prometheus\|Grafana\|Loki\|Tempo\|Pyroscope\|k6"` → phải không có kết quả (trừ khi có từ khác trùng).
- `pdftotext build/BTL.pdf - | grep -n "TÀI LIỆU THAM KHẢO\|DANH SÁCH TÀI LIỆU"` → phải không có kết quả trong mục lục.
- `pdftotext build/BTL.pdf - | grep -c "??"` → phải bằng 0.

---

## 7. Ghi chú
- Việc xóa phần observability và tài liệu tham khảo làm giảm số trang báo cáo (dự kiến giảm 1–2 trang).
- Các citation key observability trong `.bib` không còn được dùng, nhưng file `.bib` vẫn giữ nguyên để không làm hỏng file tham khảo lâu dài.
- Khi sau này muốn viết lại phần observability, dùng nội dung đã lưu ở mục 3.1 của plan này, cập nhật lại figure nếu cần, và uncomment phần bibliography trong `BTL.tex`.
