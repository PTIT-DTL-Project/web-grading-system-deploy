# Kiểm thử hiệu năng và độ tin cậy

Thư mục này chứa bộ kiểm thử chạy riêng trên staging. `api-read-load.js` đo tải API đọc mà không tạo bài nộp; `grading-flow.js` chạy một luồng chấm thật cho smoke. Script đối soát chỉ đọc ba cơ sở dữ liệu. Runbook sự cố cụm là thao tác riêng có xác nhận kép.

> Cảnh báo: `grading-flow.js` tạo một bài nộp thật và khởi chạy chấm trong executor. Không chạy trên production hoặc với dữ liệu người dùng thật. Profile stress/spike chỉ áp dụng cho API đọc.

## 1. Thành phần

- `k6/api-read-load.js`: các profile `smoke`, `load`, `stress`, `spike` cho API đọc danh sách assignment, chi tiết assignment và kết quả cá nhân; tạo nhiều request đọc để đo latency/RPS mà không sinh bài nộp hay job chấm.
- `k6/grading-flow.js`: chỉ profile smoke; thực hiện một lượt nộp/chấm thật, đo HTTP cùng thời gian từ lúc bắt đầu PUT lên RustFS đến lúc submission/result xuất hiện.
- `scripts/reconcile.sh`: chỉ đọc các hàng của một `SUBMISSION_ID` từ `submission_db`, `executor_db`, `result_db`, để đối chiếu submission, job và kết quả.
- `sql/reconcile-submission.sql`: phiên bản truy vấn tổng hợp; thay UUID mẫu trước khi dùng. Kết nối bằng user PostgreSQL chỉ có quyền `SELECT`.
- `scripts/guarded-fault-test.sh`: xóa Pod executor, tạm giảm result-service về 0 replica hoặc giảm executor từ 2 xuống 1 để quan sát ArgoCD self-heal. Có xác nhận đôi và kiểm tra context/namespace; không tự chạy rollback image.
- `results/`: nơi lưu kết quả đã chạy; mặc định nội dung bị gitignore vì có thể chứa ID dữ liệu kiểm thử.

## 2. Điều kiện cần chuẩn bị

1. Một staging tách biệt, xác nhận đúng `BASE_URL`, `KUBE_CONTEXT`, namespace, tenant/database và không có người dùng thật.
2. k6, `psql`, `kubectl`; tài khoản chỉ đọc cho ba database nếu cần đối soát. `kubectl` chỉ cần khi chạy fault test.
3. Sinh viên test đã được ghi danh vào lớp của một assignment đã publish, assignment có test plan hoạt động và không dùng dữ liệu production.
4. ZIP nhỏ, hợp lệ, có thể chấm lặp lại; tải bài được xử lý trực tiếp qua RustFS nên máy chạy k6 cần truy cập được hostname trong `uploadUrl`. Chuẩn bị thư mục và file ZIP do bạn tự tạo; không có fixture mẫu trong repo.
5. Bearer access token còn hạn của sinh viên test. Repo dùng OIDC Authorization Code + PKCE; không bật Direct Access Grants cho FE. Đăng nhập bằng FE/luồng staging được phê duyệt rồi cấp token cho k6. Không lưu mật khẩu hoặc token vào Git. Nếu chưa có staging hoặc chưa có cách cấp token thử nghiệm, chỉ có thể kiểm tra cú pháp script, chưa thể chạy luồng end-to-end.
6. Với profile `load`/`stress`/`spike` của `api-read-load.js`, cần một token cho mỗi VU, mỗi token thuộc một sinh viên test khác nhau.

## 3. Cấu hình cục bộ

Từ thư mục này:

```bash
cp .env.example .env
chmod 600 .env
# Sửa BASE_URL, ASSIGNMENT_ID, DB URLs; đặt ACCESS_TOKEN hoặc TOKENS_FILE.
```

Tạo `tokens.json` riêng trong thư mục này, không commit, dạng:

```json
[
  "<bearer-access-token-cua-sinh-vien-test-1>",
  "<bearer-access-token-cua-sinh-vien-test-2>",
  "<bearer-access-token-cua-sinh-vien-test-3>",
  "<bearer-access-token-cua-sinh-vien-test-4>",
  "<bearer-access-token-cua-sinh-vien-test-5>"
]
```

Đặt ZIP test tại `fixtures/student-sample.zip` trong thư mục này (tự chuẩn bị tệp hợp lệ; k6 phân giải `ZIP_PATH` tương đối từ thư mục `k6/`). Source `.env` vào shell hiện tại nhưng tuyệt đối không `set -x`:

```bash
set -a
source .env
set +a
```

`grading-flow.js` chỉ chạy profile `smoke` và dùng một token. `api-read-load.js` cần `TOKENS_FILE` chứa số token khác nhau ít nhất bằng số VU tối đa của profile; với `tokens.json` nằm trong thư mục gốc của gói, đặt `TOKENS_FILE=../tokens.json`. Đường dẫn token và ZIP tính từ thư mục `k6/` vì k6 phân giải `open()` theo vị trí script. Kịch bản không refresh token: token hết hạn thì lần gọi trả `401`, VU dừng phát thêm request và được tính là lỗi.

## 4. Chạy k6

Luôn chạy smoke trước, quan sát log/Prometheus/Grafana rồi mới tăng tải:

```bash
cd performance-reliability-tests
set -a && source .env && set +a
mkdir -p results
PROFILE=smoke k6 run --out json=results/grading-smoke.json k6/grading-flow.js
PROFILE=smoke k6 run --out json=results/api-smoke.json k6/api-read-load.js
PROFILE=load  k6 run --out json=results/api-load.json  k6/api-read-load.js
PROFILE=stress k6 run --out json=results/api-stress.json k6/api-read-load.js
PROFILE=spike k6 run --out json=results/api-spike.json k6/api-read-load.js
```

Mức tải API đọc là cấu hình ban đầu có giới hạn: load tối đa 3 VU, stress/spike tối đa 5 VU. Đây là mức thử thấp để xác minh công cụ và quan sát cụm, không đại diện tải tối đa hoặc chỉ tiêu năng lực. `grading-flow.js` chỉ chạy smoke với một bài chấm thật; không chạy stress/spike grading. Executor staging hiện có hai replica, mỗi Pod một worker chấm; chỉ chạy grading smoke khi staging sẵn sàng. Chỉ tăng tải đọc sau khi xác nhận staging đủ tài nguyên.

Các metric quan trọng: `http_req_duration` và `http_reqs` do k6 tạo; `submission_to_terminal_seconds`, `submission_to_result_seconds`, `grading_flow_success`, lỗi upload/polling/timeout. Đo đầu-cuối bắt đầu ngay trước PUT lên RustFS, bao gồm thời gian webhook/Kafka/queue/chấm; đây là latency của luồng nộp-đến-kết-quả, **không phải** latency chính xác riêng từ Kafka publish đến job terminal.

Nếu token hết hạn hoặc dịch vụ trả 401/403, dừng và cấp token mới qua luồng đăng nhập staging. Không tăng timeout để che lỗi xác thực.

## 5. Đối soát trạng thái và job trùng

Sau smoke, lấy `submissionId` từ log của k6, đặt biến rồi chạy truy vấn chỉ đọc:

```bash
export SUBMISSION_ID=<uuid-tu-k6>
./scripts/reconcile.sh
```

Tiêu chí cơ bản: đúng 1 submission, đúng 1 hàng `grading_jobs` cho `submission_id`, có ít nhất một result row; trạng thái cuối của submission, job và result phải được kiểm tra cùng nhau. Script trả `RECONCILIATION=PASS` nếu tồn tại hàng đúng số lượng, nhưng người vận hành vẫn phải xem các trạng thái và cột thời gian in ra - thông báo PASS không có nghĩa tự động xác nhận mọi trạng thái khớp.

Để đo khoảng `GRADE_SUBMISSION` publish đến `DONE`/`FAILED` chính xác, phiên bản hiện tại chưa lưu event timestamp trong `grading_jobs`. Cần ghép log producer/submission-service với log consumer/executor bằng `traceId` và submission ID, hoặc bổ sung metric/timestamp correlation trước khi đưa ra số liệu chính thức. Không dùng `created_at` của submission làm thời điểm Kafka publish.

Prometheus scrape mỗi 30 giây, phù hợp theo dõi xu hướng tải và tài nguyên, không phải đồng hồ độ chính xác cao cho một job ngắn. Dùng Grafana/Tempo để lưu biểu đồ, traces và định vị service chậm; xuất dữ liệu k6 JSON để tính p50/p95/p99, RPS, lỗi và thời gian đầu-cuối.

## 6. Runbook độ tin cậy (chỉ staging)

### 6.1 Kiểm tra trước khi tác động

```bash
kubectl config current-context
kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" get deploy,pods
kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" get applications.argoproj.io -n argocd
```

Xác nhận rằng context/namespace là staging, không có bài nộp người dùng thật, có quyền khôi phục dịch vụ và đã lưu `submissionId` của test. Đặt hai xác nhận:

```bash
export FAULT_TEST_CONFIRM=I_UNDERSTAND_THIS_BREAKS_STAGING
export KUBE_CONTEXT=<context-staging-chinh-xac>
export KUBE_NAMESPACE=web-grading
```

Script hỏi nhập lại `<context>/<namespace>` trước mỗi tác động:

```bash
./scripts/guarded-fault-test.sh test-selfheal-replicas
./scripts/guarded-fault-test.sh delete-executor-pod
./scripts/guarded-fault-test.sh scale-result-service-zero
```

`test-selfheal-replicas` thay đổi số replica thực tế từ hai xuống một; ArgoCD được kỳ vọng khôi phục về hai. Pod deletion xóa Pod đầu tiên được chọn - chạy ngay sau khi quan sát job ở `BUILDING` hoặc `RUNNING`, rồi đối soát job. `scale-result-service-zero` gây gián đoạn đọc/ghi kết quả; phải tự khôi phục ngay sau cửa sổ quan sát:

```bash
kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" scale deployment/grading-result-service --replicas=1
kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" rollout status deployment/grading-result-service --timeout=5m
```

Trước khi chạy, xác minh tên Deployment thực tế bằng `kubectl get deploy` và đối chiếu tên release trong ArgoCD. Script kiểm tra Deployment theo tên staging hiện được khai báo trong runbook; nếu release dùng tên khác thì phải cập nhật cấu hình/đường dẫn có kiểm soát trước khi fault test, không đoán tên tài nguyên trong lúc tác động.

Script cố ý không triển khai thay đổi cấu hình qua Git và không revert image. Test GitOps selfHeal đúng cách nên thực hiện trong nhánh/PR staging: đổi tạm một giá trị Git-managed đã chọn, quan sát ArgoCD đồng bộ về trạng thái Git; sau đó revert bằng commit/PR. Rollback image cũng đổi tag qua quy trình Git/PR, xác nhận rollout và smoke lại; không `kubectl edit` hoặc push trực tiếp `main`.

### 6.2 Kiểm tra giao sự kiện trùng

Chưa có script phát lại Kafka an toàn trong gói này. Không gửi sự kiện trùng vào topic `wgs-events-deploy` đang được executor staging dùng chung: handler hiện tại có thể reset và chạy lại job `FAILED`, do đó đây không chỉ là phép thử chống tạo job trùng. Kịch bản này cần topic staging cô lập, tài khoản broker có quyền hạn chế và một luồng kiểm thử chuyên dụng được rà soát trước khi bổ sung. Khi được phê duyệt, quan sát log consumer và đối soát `grading_jobs` theo `submissionId`; unique constraint bảo đảm không tạo hàng job thứ hai, nhưng duplicate event có thể kích hoạt retry nếu job cũ đang `FAILED`.

## 7. Tiêu chí ghi nhận

- Hiệu năng: profile đọc hoặc grading smoke, thời gian, commit/image, assignment/ZIP, số VU, `http_req_duration` p50/p95/p99, RPS, tỷ lệ lỗi, thời gian `submission_to_terminal_seconds` và `submission_to_result_seconds`.
- Độ tin cậy: fault/timestamp, trạng thái trước và sau, số hàng submission/job/result, `retry_count`, kết quả ArgoCD sync/health, thời gian phục hồi. Các thao tác xóa Pod hoặc scale dịch vụ có thể quan sát bằng runbook; gửi duplicate event chưa được tự động hóa.
- Không kết luận không có job trùng chỉ từ số lượng job hiện tại nếu dữ liệu bị soft-delete; đối soát thêm `deleted_at`, logs và retries khi cần. Script hiện chỉ truy vấn các hàng chưa soft-delete.
- Báo cáo học thuật chỉ ghi kết quả sau khi chạy thật, kèm cấu hình và môi trường; file trong `results/` là đầu vào để tổng hợp, không tự điền số dự kiến.
