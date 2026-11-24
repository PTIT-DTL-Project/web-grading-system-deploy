# 05 — Ingress, Traefik và Cloudflare

> Phần này trả lời: **một request từ trình duyệt vào tới pod đi qua những gì**, vì
> sao không có TLS trong cụm, vì sao Keycloak phải khai đúng hostname, và vì sao
> upload ZIP lại cần CORS.

---

## 1. 12 hostname public và đích đến thật

| Hostname | Ingress | Service đích (namespace) | Port | Mục đích |
|---|---|---|---|---|
| `web-dev1-api.vucongtuanduong.dpdns.org` | `deploy/ingress/api-gateway.yaml` | `grading-api-gateway` (web-grading) | 8080 | Cửa duy nhất cho FE gọi nghiệp vụ |
| `web-dev1-course...` | `course-service.yaml` | `grading-course-service` | 8081 | Gọi trực tiếp course-service (test/debug) |
| `web-dev1-submission...` | `submission-service.yaml` | `grading-submission-service` | 8082 | Gọi trực tiếp submission-service |
| `web-dev1-result...` | `result-service.yaml` | `grading-result-service` | 8084 | Gọi trực tiếp result-service |
| `web-dev1-grading...` | `grading-service.yaml` | `grading-executor-service` | 8083 | Gọi trực tiếp executor (tên host là "grading" vì đây là dịch vụ chấm) |
| `web-dev1-ai...` | `ai-assistant-service.yaml` | `grading-ai-assistant-service` | 8086 | Gọi trực tiếp AI assistant |
| `web-dev1-keycloak...` | `keycloak.yaml` | `keycloak` | 8080 | OIDC: `/realms/ptit-wgs/...` |
| `web-dev1-rustfs...` | `rustfs.yaml` | `rustfs` | 9001 | Console quản trị RustFS |
| `web-dev1-rustfs-api...` | `rustfs.yaml` | `rustfs` | 9000 | **S3 API** — presigned `PUT` của FE đi vào đây |
| `web-dev1-kafka-ui...` | `kafka-ui/ingress.yaml` | `kafka-ui` | 8080 | Xem topic/message |
| `web-dev1-grafana...` | `observability/manifests/ingress/grafana.yaml` | `monitoring-grafana` (**observability**) | 80 | Dashboard metric + trace |
| `web-dev1-argocd...` | `deploy/argocd-ingress.yaml` | `argocd-server` (**argocd**) | 80 | UI triển khai |

Mọi host dùng tiền tố `web-dev1-` (biến `global.prefix` trong values) và domain
`vucongtuanduong.dpdns.org` (biến `global.domain`).

---

## 2. Traefik: ingress controller của k3s

k3s cài sẵn Traefik trong namespace `kube-system`. Trong đồ án, mỗi Ingress chỉ
khai 3 thứ:

```yaml
spec:
  ingressClassName: traefik      # dùng Traefik, không phải nginx
  rules:
    - host: web-dev1-api.vucongtuanduong.dpdns.org
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: grading-api-gateway, port: { number: 8080 } } }
```

Traefik làm 3 việc:

1. **Host-based routing**: đọc header `Host`, chọn rule khớp ⇒ chuyển tới Service.
2. **Load balancing**: Service có nhiều Endpoint (nhiều pod Ready) ⇒ round-robin.
   Với executor 2 replica, đây là nơi traffic chấm bài được chia.
3. **Entrypoint**: Traefik có `web` (HTTP 80) và `websecure` (HTTPS 443). Đồ án chỉ
   dùng `web`.

Lấy NodePort thật của Traefik (Cloudflare tunnel trỏ vào đây):

```bash
kubectl get svc -n kube-system traefik \
  -o jsonpath='{.spec.ports[?(@.name=="web")].nodePort}'    # ví dụ 31242
```

`GATEWAY_PORT=31242` trong `.env.example` chính là giá trị này — nó khác nhau trên
mỗi máy nên **không hardcode** ở đâu khác.

### 2.1 Traefik là reverse proxy hay ingress controller?

**Cả hai, trong cùng một process.** "Reverse proxy" là *bản chất* kỹ thuật (nó đứng
thay mặt server, nhận kết nối từ client rồi mở kết nối mới tới backend).
"Ingress controller" là *vai trò* của nó trong Kubernetes: một controller watch các
object `Ingress` rồi **cấu hình động** cho phần proxy đang chạy.

| Phần | Việc làm |
|---|---|
| Controller | Watch `Ingress` ở cả 3 namespace, build bảng router (Host + path → Service:port) |
| Proxy (data plane) | Nghe entrypoint `web`/`websecure`, route, LB tới các Endpoint Ready, thêm `X-Forwarded-*` |

Ba reverse proxy trong đồ án, ba tầng khác nhau:

| Tầng | Thành phần | Quyết định điều gì |
|---|---|---|
| Edge (ngoài cụm) | Cloudflare | TLS, DDoS/WAF, hostname → tunnel |
| Trong cụm (L7) | **Traefik** | `Host` + path → Service → Endpoint (không biết user là ai) |
| Ứng dụng | api-gateway | Path → service, verify JWT, đóng dấu `X-User-*`/`X-Gateway-Secret` |

Traefik **không phải** forward proxy, cũng **không phải** service mesh: nó không có
sidecar, không mTLS tự động, không retry/circuit-break ở tầng proxy.

---

## 3. TLS kết thúc ở đâu (và hệ quả)

```
Browser ──HTTPS (TLS 1.2/1.3)──► Cloudflare edge ──tunnel (ra ngoài)──► cloudflared
                                                                          │ http://localhost:<NodePort>
                                                                          ▼
                                                                  Traefik ──HTTP──► Service ──HTTP──► Pod
```

| Hệ quả | Chi tiết |
|---|---|
| Không có `tls:` trong Ingress | Đúng thiết kế: Traefik không giữ cert, không cần cert-manager |
| `argocd-server` chạy `--insecure` | ArgoCD không tự redirect HTTPS, tránh vòng lặp redirect sau proxy |
| Keycloak `KC_PROXY=edge` | Keycloak tin header `X-Forwarded-*` từ proxy để sinh URL tuyệt đối đúng scheme/host |
| Keycloak `KC_HOSTNAME_STRICT=true` | Issuer trong token **luôn** là `https://web-dev1-keycloak.../realms/ptit-wgs` |
| Gateway verify `iss` | Nếu `KC_HOSTNAME` và `KEYCLOAK_ISSUER_URI` lệch nhau ⇒ **mọi token bị 401** dù đăng nhập thành công |
| Cookie/redirect | `grafana.ini server.domain` + `root_url` phải khớp host public, nếu không login Grafana bị redirect sai |

Đây là lỗi cấu hình phổ biến nhất khi đổi domain: đổi Ingress host nhưng quên
`KC_HOSTNAME` hoặc `GRAFANA_DOMAIN`. Triệu chứng: đăng nhập xong vẫn 401, hoặc
Grafana login xong quay về trang trắng.

---

## 4. Cloudflare Zero Trust Tunnel

### 4.1 Cách hoạt động

`cloudflared` chạy **trên máy host** (không phải pod) và **mở kết nối ra ngoài**
tới Cloudflare. Cloudflare đẩy request vào qua kết nối đó ⇒ **không cần mở port
nào trên router/firewall**, không cần IP public tĩnh.

```
cloudflared (host)  ──outbound 443──►  Cloudflare edge  ◄──HTTPS──  Browser
        │
        └──► http://localhost:<Traefik NodePort>   (theo Host của request)
```

Public hostname được khai trong dashboard Cloudflare Zero Trust: mỗi hostname
(`web-dev1-api...`, `web-dev1-keycloak...`…) trỏ tới một service nội bộ
`http://localhost:<NodePort>`. Traefik nhận request **kèm nguyên header `Host`**,
nên vẫn route đúng Ingress.

### 4.1b Cơ chế ở mức gói tin: "request đi vào tunnel" nghĩa là gì

Điểm dễ hiểu sai: **tunnel không phải một cổng mà Cloudflare kết nối vào**. Nó là
**một kết nối do cloudflared tự mở ra ngoài** và giữ mở liên tục; Cloudflare ghi
bytes của request vào kết nối đã có sẵn đó. Không có inbound TCP nào vào máy chạy cụm.

#### Pha 1 — Đăng ký (chỉ một lần, lúc `cloudflared tunnel run`)

```
cloudflared ──outbound QUIC/UDP 7844 (fallback HTTP/2 over TCP 443)──► Cloudflare edge
             "tôi là tunnel <UUID>, đây là secret"        (4 kết nối tới 2 data center khác nhau)
Cloudflare   lưu: tunnel <UUID> ⇄ các kết nối đang sống ở các PoP
DNS          web-dev1-api... → CNAME <UUID>.cfargotunnel.com  (bản ghi proxied)
Cấu hình     Public hostname (Zero Trust dashboard): web-dev1-api... → http://localhost:<NodePort>
```

Vì cấu hình nằm ở dashboard (token-managed tunnel), `cloudflared` **không cần file
`config.yaml`** cục bộ; đổi public hostname chỉ cần sửa trên dashboard.

#### Pha 2 — Request đi vào

```
1. Browser ──TLS (SNI = web-dev1-api...)──► PoP gần nhất (anycast)
2. Edge: TLS termination, parse HTTP, WAF/rate-limit/DDoS, đọc Host
3. Edge tra bảng: Host → tunnel <UUID> → chọn 1 kết nối đang sống của tunnel
4. Edge đóng gói request thành stream trong kết nối đó
      HTTP/2: HEADERS (:method, :path, :authority) + DATA
      QUIC  : stream riêng cho từng request (multiplexing)
5. cloudflared nhận stream, mở/giữ TCP keep-alive tới http://localhost:<NodePort>
   và gửi HTTP/1.1 request bình thường, kèm:
      Host: web-dev1-api.vucongtuanduong.dpdns.org      ← giữ nguyên
      X-Forwarded-Proto: https, X-Forwarded-For, CF-Connecting-IP, CF-Ray, ...
6. Traefik đọc Host → khớp Ingress → Service grading-api-gateway:8080 → pod
7. Response chảy ngược đúng đường đó, streaming từng chunk
```

Hai hệ quả trực tiếp:

- **Host được giữ nguyên** ⇒ Traefik vẫn route theo `rules[].host` như bình thường,
  và Keycloak vẫn thấy đúng host để sinh `iss` = `https://web-dev1-keycloak...`.
- **`X-Forwarded-Proto: https`** là lý do Keycloak khai `KC_PROXY=edge`: nó tin
  header này để sinh URL tuyệt đối `https://` dù bên trong cụm chỉ có HTTP.

#### Pha 3 — Vì sao không cần mở port

| Cách truyền thống | Tunnel |
|---|---|
| Mở 443 trên router → NAT/port-forward → node | Không mở port nào; chỉ cần outbound UDP 7844 hoặc TCP 443 |
| Cần IP public tĩnh | Chạy được sau NAT, CGNAT, IP động |
| Tự quản cert, TLS, OCSP | Cert + TLS do Cloudflare lo |
| Origin lộ IP, bị scan/brute-force trực tiếp | Origin không có địa chỉ public để tấn công |

#### 4.1c Giới hạn cần biết (nói thật khi bảo vệ)

| Giới hạn | Ảnh hưởng tới đồ án |
|---|---|
| Cloudflare nằm trong **trust boundary** (TLS kết thúc ở edge) | Edge có thể đọc traffic; đây là đánh đổi của reverse proxy managed, không phải E2E tới origin |
| Response từ origin quá lâu ⇒ lỗi **524** (ngưỡng mặc định ~100s) | AI chạy lâu phải stream (SSE) + heartbeat; đồ án còn poll trạng thái 1s làm lưới an toàn |
| Giới hạn dung lượng upload theo gói Cloudflare | ZIP bài nộp lớn phải kiểm tra hạn mức gói đang dùng (đồ án chưa đặt giới hạn trong code) |
| Tunnel là **single point of failure** | `status.sh` kiểm tra tiến trình; tunnel chết ⇒ mọi hostname trả lỗi 1033 dù cụm khoẻ |
| Debug nhiều tầng | Phải phân biệt: 1033 (tunnel chưa kết nối), 502 (cloudflared không tới được Traefik), 503 (Traefik không có Endpoint), 524 (origin chậm) |

### 4.2 File liên quan

| File | Vai trò | Ghi chú |
|---|---|---|
| `cloudflare_tunnel_run.sh` | `cloudflared tunnel run --token <TOKEN>` | **Gitignored** vì chứa token. Token = quyền đẩy traffic vào cụm ⇒ không commit, không dán vào báo cáo |
| `status.sh` | `pgrep -f "cloudflared tunnel"` | Kiểm tra tunnel còn chạy |
| `stop.sh` / `start.sh` | in hướng dẫn, **không** tự start/stop tunnel | Tunnel chạy foreground, do người vận hành quản lý |

### 4.3 Ưu / nhược (câu hỏi hay gặp)

| Ưu điểm | Nhược điểm |
|---|---|
| Không mở inbound port, không cần IP tĩnh | Tunnel là **single point of failure**: tắt terminal là mất toàn bộ truy cập |
| TLS + chống DDoS ở edge | Không kiểm soát được cipher/TLS version từ phía cụm |
| DNS + cert tự động theo domain | Debug khó hơn: lỗi 502 có thể do Cloudflare, tunnel, Traefik hoặc pod |
| Có thể dựng lại cụm ở máy khác, DNS không đổi | Token tunnel phải giữ bí mật tuyệt đối |

---

## 5. Định tuyến path: Ingress thô, gateway tinh

Ingress chỉ có **một** path `/` cho mỗi host ⇒ mọi phân chia path nằm ở gateway:

| Prefix path | Service đích | Ghi chú |
|---|---|---|
| `/api/v1/classes/**`, `/api/v1/assignments/**`, `/api/v1/student/**` | `COURSE_SERVICE_URI` | Lớp, bài tập, sinh viên |
| `/api/v1/submissions/**` | `SUBMISSION_SERVICE_URI` | Nộp bài, presign, lịch sử |
| `/api/v1/results/**` | `RESULT_SERVICE_URI` | Kết quả chấm |
| `/api/v1/ai/**` | `AI_ASSISTANT_SERVICE_URI` | Trợ lý AI |

`/api/v1/internal/**` **không** có route ở gateway — đúng thiết kế: đây là API nội
bộ, chỉ gọi trực tiếp trong cụm (executor → result-service, result-service →
course-service). Vì vậy nó không đi qua gateway, không có `X-Gateway-Secret`, và
được các service khai trong `PUBLIC_PATHS` (xem mục 7 — kèm cảnh báo).

Ngoài 4 prefix trên, gateway còn có các endpoint tự thân: `/api/v1/account/**`
(đổi mật khẩu), `/actuator/health`, `/actuator/prometheus`.

---

## 6. CORS — chỗ dễ mất điểm nhất khi demo

### 6.1 Vì sao cần

FE upload ZIP **trực tiếp** lên RustFS bằng presigned URL:

```js
await fetch(uploadUrl, { method: 'PUT', body: file })   // uploadUrl = https://web-dev1-rustfs-api...
```

Đây là request **cross-origin** (origin FE ≠ origin RustFS) ⇒ trình duyệt gửi
`OPTIONS` preflight trước. RustFS chỉ trả `Access-Control-Allow-Origin` nếu origin
nằm trong `RUSTFS_CORS_ALLOWED_ORIGINS`.

Giá trị hiện tại trong `deploy/rustfs/deployment.yaml`:

```
RUSTFS_CORS_ALLOWED_ORIGINS=http://localhost:5173,https://web-dev1-fe.vucongtuanduong.dpdns.org,http://localhost:5174
```

Quy tắc (ghi trong `deploy/rustfs/README.md`):

- Danh sách **origin chính xác**: scheme + host, **không** space, **không** dấu `/`
  cuối.
- **Không bao giờ dùng `*`**: wildcard tắt credentialed request và bị advisory
  reflective-CORS của RustFS cảnh báo.
- `RUSTFS_CONSOLE_CORS_ALLOWED_ORIGINS` là biến **khác** cho console (9001) —
  upload không đi qua đó, đừng sửa.

### 6.2 Kiểm tra preflight (lệnh thật)

```bash
curl -i -X OPTIONS \
  'https://web-dev1-rustfs-api.vucongtuanduong.dpdns.org/submission-files/test.zip' \
  -H 'Origin: https://web-dev1-fe.vucongtuanduong.dpdns.org' \
  -H 'Access-Control-Request-Method: PUT'
# Kỳ vọng: Access-Control-Allow-Origin: https://web-dev1-fe.vucongtuanduong.dpdns.org
```

Lặp lại với một origin **không** nằm trong danh sách ⇒ phải **không** được allow.

### 6.3 Bẫy liên quan: `RUSTFS_PUBLIC_ENDPOINT`

Presigned URL được ký bằng endpoint nội bộ nhưng **host trong URL phải là host
public** (`RUSTFS_PUBLIC_ENDPOINT`). Nếu để `http://rustfs:9000`, FE sẽ cố upload
tới `rustfs:9000` — tên này chỉ phân giải **trong cụm** ⇒ trình duyệt báo lỗi
mạng, backend không có log gì. Đây là lỗi "im lặng" điển hình.

---

## 7. Phân tích bảo mật của lớp Ingress (nên chủ động nêu)

### 7.1 Điều đúng đang có

- 4 service nghiệp vụ **không** tin người gọi trực tiếp: `HeaderAuthenticationFilter`
  chỉ dựng SecurityContext khi có `X-Gateway-Secret` khớp; thiếu ⇒ request bị coi
  là anonymous ⇒ `anyRequest().authenticated()` trả 401.
- Role do gateway lọc theo allowlist (`ROLE_LECTURER`, `ROLE_STUDENT`) trước khi
  forward; service không đọc role từ nguồn khác.

### 7.2 Điểm cần lưu ý (và cách khắc phục)

Ba Ingress `course-service`, `result-service`, `submission-service` mở các service
này ra Internet. Trong `SecurityConfig.PUBLIC_PATHS` của các service đó có
`/api/v1/internal/**` (và submission có thêm `/api/v1/submissions/webhook/**`)
được `permitAll` — vì chúng dành cho gọi nội bộ, không đi qua gateway. Hệ quả: ai
biết hostname có thể gọi thẳng API nội bộ mà không cần token.

Hướng khắc phục (nêu trong phần Hướng phát triển của báo cáo):

| Cách | Cách làm |
|---|---|
| Bỏ Ingress của service nội bộ | Chỉ giữ `api-gateway`; service khác truy cập qua `kubectl port-forward` khi debug |
| Giới hạn path ở Ingress | Thêm `paths` chỉ cho `/actuator/health` thay vì `/` |
| Middleware Traefik | `ipAllowList` chỉ cho dải IP của Cloudflare, hoặc basic auth |
| NetworkPolicy | Chỉ cho pod gateway gọi tới port 8081/8082/8084, chặn từ ngoài |
| Chuyển internal API sang cổng riêng | Management port riêng, không expose qua Service |

Điểm cần nhấn: **đây là ranh giới đã biết**, không phải lỗ hổng bị bỏ sót — và
cách xử lý đúng là thu hẹp phạm vi expose, không phải thêm secret vào URL.

---

## 8. Bảng chẩn đoán lỗi theo mã HTTP

| Triệu chứng | Nơi kiểm tra đầu tiên | Nguyên nhân thường gặp |
|---|---|---|
| `404` từ Cloudflare | Public hostname trong dashboard có đúng? | Chưa khai hostname, hoặc khai sai service `http://localhost:<port>` |
| `502 Bad Gateway` | `kubectl -n web-grading get pods` | Tunnel sống nhưng Traefik không tới được pod: pod chết, Service sai selector |
| `503 Service Unavailable` | `kubectl -n web-grading get endpoints <svc>` | Service không có Endpoint: pod chưa Ready (readiness fail) hoặc sai label |
| `504` | `kubectl logs deploy/grading-<svc>` | Request vượt timeout (AI gọi LLM, executor chấm bài lâu) |
| `401` dù đã đăng nhập | So `KC_HOSTNAME` với `KEYCLOAK_ISSUER_URI` | Lệch issuer ⇒ gateway từ chối token |
| `401` ở mọi API có auth | `kubectl get secret gateway-trust -o jsonpath=...` | `X-Gateway-Secret` lệch giữa gateway và service |
| `403` trên endpoint có `@PreAuthorize` | Response body / log gateway | Token không có role nằm trong `GATEWAY_ALLOWED_ROLES` |
| `CORS error` khi upload | `curl -X OPTIONS` như mục 6.2 | Origin FE chưa nằm trong `RUSTFS_CORS_ALLOWED_ORIGINS`, hoặc presigned URL trỏ host nội bộ |
| Trang trắng sau login Grafana | `kubectl logs deploy/monitoring-grafana -n observability` | `grafana.ini server.domain/root_url` không khớp host public |
| `404` ở `/api/v1/account/change-password` | `kubectl exec ... env \| grep RATE_LIMIT` | `RATE_LIMIT_ENABLED=false` ⇒ endpoint không được đăng ký (fail closed) |

---

## 9. Một câu để nhớ cả chương

> **Ingress làm đúng một việc: chọn service theo tên miền.** Mọi thứ còn lại —
> xác thực, phân quyền, chia path, tin cậy nội bộ — nằm ở gateway và ở filter
> trong từng service. TLS và DNS nằm ngoài cụm, ở Cloudflare.
