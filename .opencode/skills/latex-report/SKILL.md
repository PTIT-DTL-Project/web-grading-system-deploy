---
name: latex-report
description: LaTeX thesis report formatting conventions for report_datn/ - no bold in body text, enumerate/itemize for all listings, underscore escaping in text, glossary longtable column widths, figure naming, table captions below tables, Vietnamese use-case names and business-level scenarios in chapter 2. Use when writing or reviewing any .tex chapter, glossary entries, or report figures.
---

# LaTeX report conventions (`report_datn/`)

Base: `report` class, a4paper, 13pt, Times (`\usepackage{times}`),
margins top=2cm bottom=2cm left=3.5cm right=2.5cm → **textwidth = 15cm**.
Chapters are subfiles under `report_datn/Chuong/`, included from `BTL.tex`.

## No bold in body text (mandatory)

Never use `\textbf` (or `\bfseries`, `\boldsymbol`, `\mathbf`) inside
chapter content. `\section`/`\subsection` headings are already bold by
default, so manual bold is visual noise. Emphasis, when truly needed,
uses `\textit`. Term introductions (`X là...`), `\item` lead-ins and
table header cells are all plain text.

## All listings use enumerate/itemize (mandatory)

Every listing must be a real `enumerate` (ordered) or `itemize`
(unordered) environment — never inline markers like `(i)/(ii)/(iii)`
or prose sequences like `Thứ nhất / Thứ hai / Thứ ba` inside a
paragraph. Split the lead-in sentence from the items; strip the markers
and joining words (`và`, `Thứ nhất,`), end each `\item` with a period.

## URLs and long host names use `\url{}`, never `\texttt{}`

`BTL.tex` loads `xurl`, so `\url{...}` may break the string at any
character and stay inside `\textwidth`. `\texttt{...}` typesets the
text as one unbreakable box: a long host name such as
`web-dev1-grafana.vucongtuanduong.dpdns.org` overflows the right
margin (measured 93pt overfull). Rule: any URL/host name longer than
~30 characters goes in `\url{}` (no `_` escaping needed inside it);
reserve `\texttt{}` for short technical tokens, file names, and
endpoint paths.

## Use monospace sparingly and semantically

Use `\texttt{}` only when monospace marks an exact technical literal, such as
an identifier, configuration key/value, status, command, endpoint, or short
code fragment. Do not use it to emphasize technology names, borrowed English
terms, or ordinary prose; those stay in the report's normal text face. When a
technical name follows its Vietnamese meaning in parentheses (for example,
`một phiên chấm (grading_sagas)`), keep both in the normal text face; reserve
monospace for places where the exact syntax itself matters. In reference tables
and syntax examples, retain monospace for literal keys and values when it helps
distinguish them from descriptions.

## Escape underscores in text, never in code (mandatory)

LaTeX treats a bare `_` in running text as math subscript and fails
to render it — write `code\_verifier`, `code\_challenge`. This applies
inside `\texttt{...}` too (still text mode). Never escape `_` where it
is not typeset: `\label`, `\ref`, `\cite`, file paths
(`\includegraphics{Hinhve/Hinh2_5_lua_ng_pkce}`), `\url`,
`\addbibresource`, command names, math mode (`$...$`).

## Glossary longtable must fit textwidth (gotcha)

`Chuong/0_5_Danh_muc_viet_tat.tex` uses `longtable`. Column widths must
sum to ≤ 15cm including `~0.4cm` inter-column gaps (`@{}` only trims the
outer edges), otherwise the last column is clipped at the right margin.
`X` (tabularx) does not size reliably inside `longtable` here — use
fixed `p{}` columns that wrap, e.g. `@{}p{2.6cm} p{2.6cm} p{9.2cm}@{}`.
Keep the Vietnamese description column widest. A `p{}` column must be
wider than its longest unbreakable word (no spaces to wrap at, e.g.
13-char `Microservices` ≈ 3cm bold 13pt Times overflows `p{1.8cm}`
into the next column); either widen the column or insert `\-`
discretionary hyphens (`Micro\-services`, invisible unless TeX breaks
there, works regardless of hyphenation patterns). The glossary table
uses a full grid: outer border plus rules between all columns
(`{|p{2.6cm}|p{2.6cm}|p{9.2cm}|}`) and `\hline` at the end of every
data row (`...\\ \hline`).

## Table captions sit below the table (mandatory)

Every `table` float writes `\caption{...}` and `\label{...}` AFTER the
tabular content (after `\end{tabularx}`), so the caption prints under the
table, aligned with figure captions below their figures. Do NOT add
`\captionsetup[table]{position=below}` to `BTL.tex` expecting it to
relocate captions: measured with the bundled `caption` package, the
option does not move a `\caption` written above the content (it is a
no-op there; spacing is identical either way). The only deterministic
way is the manual order — caption after content. Tables already
following this: Bảng 1.1 (`1_Co_so_ly_thuyet.tex`) and Bảng 2.1-2.9
(`2_Phan_tich_thiet_ke.tex`). `\listoftables` and `\ref` numbering are
unaffected (the `report` class numbers tables `chapter.number` by
default). Caption-to-table gap equals the figure caption gap
(`\abovecaptionskip`, ~10pt); no preamble change needed.

## Figures

PNGs live in `report_datn/Hinhve/`, named `Hinh2_<n>_<slug>.png`
(e.g. `Hinh2_5_lua_ng_pkce.png`), included at `width=\textwidth` with
`\label{fig:<slug>}`. Graphviz `dot` is available for regenerating
flowcharts; keep node font sizes so text stays legible at text width.
Before diagnosing page whitespace, inspect the source image dimensions and
content bounds: internal white margins can make a centered figure look
undersized or low on the page. When updating a diagram, inspect the latest
MR/branch commit for revised phase-specific source images first; update both
the report asset and its figure reference instead of merely enlarging an
obsolete diagram. When confirmed, crop only at inclusion with
`trim=<left> <bottom> <right> <top>,clip` (do not alter the source asset),
or set a deliberate width for a small diagram so labels remain readable.
Never rotate a page (`pdflscape`, `landscape`, `\captionof`): the report
stays portrait throughout. For wide diagrams that are illegible at
`\textwidth`, rotate only the image inside a normal portrait figure:

```latex
\begin{figure}[H]
\centering
\rotatebox{90}{\includegraphics[width=0.92\textheight,height=0.95\textwidth,keepaspectratio]{...}}
\caption{...}
\label{...}
\end{figure}
```

Sizes are measured before rotation, so the width limit comes from
`\textheight` and the height limit from `\textwidth`; keep both plus
`keepaspectratio` so tall or wide source images both fit. The caption stays
horizontal. Leave near-square images unrotated at `width=\textwidth` (an ERD
at 1.23:1 is larger upright). Delete `pdflscape`/`capt-of` imports once no
landscape page remains. Always render the affected pages and check the
caption falls inside the text block.

Screenshots of the running system go in an own section, one figure per
screen, with a caption naming that screen (`Hinh 3.11: Trang đăng nhập
Keycloak của hệ thống.`). Name the asset after the screen, not after the
figure counter (`ui-01-dang-nhap-keycloak.png`,
`argocd-danh-sach-ung-dung.png`): inserting a later screenshot shifts every
figure number, so `Hinh3_<n>_...` names go stale within one edit. Group the
screens by role/flow in `\subsubsection` blocks and place the figure right
after the sentence that cites it (`Hình~\ref{...} là ...`) instead of a bare
list of images. Admin screens belong with the section they document
(ArgoCD with GitOps, Kafka UI/RustFS with shared infrastructure, Grafana
with observability), not in the UI section.

A subsection made only of `figure[H]` blocks stretches inter-paragraph glue
and opens large gaps mid-page. Wrap such a block in `\raggedbottom` ...
`\afterpage{\flushbottom}` (both already imported) so slack collects at the
page bottom, then render two or three consecutive pages to confirm the gaps
are gone.
For long glossary `longtable`s that spill only a few rows onto a final page,
use `\singlespacing` locally before the table and restore `\onehalfspacing`
after `\end{longtable}`; verify it still fits the text block.

## Use-case diagrams and descriptions (Chapter 2)

Chapter 2 section 2.1 holds the use-case analysis: 2.1.1 lists the four
actors (User parent, Admin/Lecturer/Student inheriting from it) as an
`itemize`; 2.1.2 shows the overview diagram plus the full use-case list
(one sentence per use case, Vietnamese name only: `Tên usecase: Usecase
này cho phép <tác nhân> ...`). 2.1.3 `Kịch bản các chức năng` carries
the detail material, grouped by actor in `\subsubsection`s: (a) chung
(Đăng nhập, Đổi mật khẩu), (b) quản trị viên (Nhập danh sách tài
khoản), (c) giảng viên (Quản lý lớp học, Quản lý bài tập, Xem kết quả
chấm của cả lớp, Giảng viên trò chuyện với trợ lý AI), (d) sinh viên
(Nộp bài tập, Xem điểm và kết quả cá nhân, Xem kết quả chấm bài tập
của bản thân, Sinh viên trò chuyện với trợ lý AI). Keep actor-specific
AI chat scenarios in their matching actor subsection. Inside a group
each function starts directly with its lead sentence (`Bảng … mô tả
kịch bản …` / `Hình … mô tả chi tiết …`), then its detail figure where
a diagram exists, then the scenario table. Never mark a function with a
`\paragraph{Chức năng <Tên>.}` run-in heading (removed on request).
Never list sub-usecases as text bullets: the decomposition lives only
in the detail diagram. `Xem chi tiết kết quả chấm một bài tập` gets no
table of its own: it is a shared step already covered by the lecturer
and student scenario tables.

Use-case names are Vietnamese in every text element — prose,
`\paragraph`, `Tên kịch bản` row, figure and table captions; the
exported diagram images keep the English names drawn inside them. When
a name itself contains `của` (`Xem kết quả chấm của cả lớp`), qualify
the actor with `dành cho <tác nhân>` in the lead sentence and caption —
a second `của` reads badly. Say `kịch bản`, never `kịch bản chuẩn`:
every table carries an exception-flow row, so it is not the happy path
only.

Scenario tables (Bảng 2.x, `\label{tab:uc-<slug>}`): `table` float
placed `[!ht]`, `\begin{tabularx}{\textwidth}{|p{3.2cm}|X|}` full grid;
rows `Tên mục & Nội dung mô tả`, `Tên kịch bản`, `Tác nhân`,
`Tiền điều kiện`, `Hậu điều kiện`, `Kịch bản chính`
(`enumerate[leftmargin=*, nosep]`), `Kịch bản ngoại lệ` (`itemize`,
same options); long cells end with `\end{enumerate} \\ \hline`; caption
`Kịch bản chức năng <Tên>.` + `\label` written after `\end{tabularx}`
(see the table-caption section above), so it prints below the grid (the
front-matter `\listoftables` picks them up).

Main-flow steps: exactly one actor action per `\item` — either the
`Tác nhân` row's actor or `Hệ thống`, never both in one item
(`Giảng viên ...; hệ thống ...` must be split). Two consecutive items
must not share the same subject; alternate actor → system → actor.
Exception-flow bullets are exception statements, not numbered steps, so
several may sit in one list.

Overflow gotcha: at 13pt with `\onehalfspacing` (BTL.tex) the usable
page height is ≈22.5 cm, so a scenario table over ~30 cm cannot fit one
page and runs into the page number (`Quản lý lớp học` measured ≈41 cm).
Split it into two `table` floats at a business boundary (e.g. create
class | operate class) instead of switching to `longtable`/`xltabular`,
which breaks the `[!ht]` + caption-after-content convention. The second
float repeats the header row, labels its row `Kịch bản chính (tiếp)`
with `start=<n>` on the `enumerate`, keeps the exception row, gets its
own number and `\label{tab:uc-<slug>-2}`, and its caption ends with
`(tiếp)`. Do NOT use `\ContinuedFloat`: the `caption` package appends an
English "(continued)" to the Vietnamese caption. Update the lead-in
sentence to cite both labels.

For a page with a fixed `[H]` figure that leaves a large vertical gap because of `\flushbottom`, use `\raggedbottom` locally before the lead-in and schedule `\afterpage{\flushbottom}` after the figure; inspect the rendered page to ensure the setting is restored and subsequent pages are unaffected. Do not use a fixed negative `\vspace` to pull the image upward.

Content must be grounded in `docs/design/usecase-flows.md`
(real preconditions, statuses, error cases) — never invented. Float
placement measured on the scenario-table section: `[ht]` defers every table
to end-of-chapter float pages (7-9 page drift); `[!ht]` keeps drift at
0-3 pages with no stretching; `[H]` places each table exactly at its
reference but `\flushbottom` stretches the preceding page (large
mid-page gap). Keep `[!ht]`; switch individual tables to `[H]` only on
request.

Scenario tables and use-case prose stay business-level (chapter 2 is an
analysis phase, not implementation documentation): never leak
implementation details — no Keycloak/authorization code/PKCE/token or
browser storage, no HTTP/container/Docker/presigned URL/object storage,
no CPU/memory/service-port config, no "DB connection info". Use
system-level wording instead: `hệ thống kiểm tra thông tin đăng nhập`,
`môi trường cách ly`, `gửi yêu cầu kiểm thử`, `kiểm tra dữ liệu`,
`đường dẫn tải lên an toàn`, `giới hạn tài nguyên khi chấm`, `bộ nhớ
trình duyệt` → `phiên làm việc`. Concrete tech lives in
`docs/design/usecase-flows.md` (dev doc — keep it technical). Business
facts stay: temp password + forced change on first login, lockout after
repeated failures, grading plan/steps, submission statuses, grading
logs, role-based access; `tệp CSV` is kept as the input artifact the
admin/lecturer prepares.

## Phần thiết kế trong Chương 2 (bổ sung)

Cuối Chương 2 có `\section{Thiết kế hệ thống}` ngang hàng với
`\section{Phân tích hệ thống}`, gồm:

- `\subsection{Thiết kế cơ sở dữ liệu theo dịch vụ}`: `itemize`, mỗi
  dịch vụ một bullet theo mẫu: `Dịch vụ <Tên>: bao gồm các bảng
  \texttt{<tên_bang>}, … để quản lý …`. Tên bảng lấy từ entity JPA /
  migration SQL thực tế (ví dụ `classes`, `class_students`,
  `score_components`, `student_scores`, `submissions`, `manual_scores`,
  `grading_jobs`, `grading_logs`, `grading_sagas`, `grading_saga_steps`,
  `grading_step_results`, `results`, `step_results`,
  `ai_conversation`, `ai_message`, `ai_explanations`, …). Dịch vụ xác
  thực và phân quyền viết chung (quản lý tài khoản, đăng nhập, đổi
  mật khẩu, cấp và kiểm tra vai trò) nếu không có bảng SQL riêng trong
  kho source.
- `\subsection{Sơ đồ tuần tự các chức năng}`: mỗi chức năng là một
  `\subsubsection{<Tên>}`, có 1–2 câu mô tả luồng rồi chèn hình:
  `\begin{figure}[ht] … \includegraphics[width=\textwidth]{Hinhve/Hinh2_XX_seq_<slug>}
  … \caption{Sơ đồ tuần tự chức năng <Tên>.} … \label{fig:seq-<slug>}
  … \end{figure}`. Số thứ tự hình tăng tự động (`Hình 2.20`, `2.21`, …);
  caption nằm dưới hình, label không trùng. Tên file ảnh dùng slug
  tiếng Việt không dấu (`seq_dang_nhap`, `seq_quan_ly_lop`,
  `seq_quan_ly_lop_chitiet`, `seq_quan_ly_bai_tap`,
  `seq_xem_ket_qua_lop`, `seq_nop_bai`,
  `seq_xem_ket_qua_cua_than`, `seq_xem_diem_ca_nhan`).
- `\subsection{Kiến trúc hệ thống}`: đặt ngay sau sơ đồ tuần tự, là
  mục cuối Chương 2, tổng hợp kiến trúc logic (Client - Server, 5 dịch
  vụ nghiệp vụ + API Gateway + Keycloak, DB-per-service, REST/OpenFeign,
  Kafka topic `wgs-events`, RustFS presigned URL + webhook, LLM qua API
  tương thích OpenAI, `grading_jobs`/`grading_sagas`). Hình
  `Hinhve/Hinh2_31_kien_truc_tong_the`, caption
  `Kiến trúc tổng thể của hệ thống.`, label `fig:architecture`, đặt
  ngay sau đoạn dẫn nhập đầu tiên (ảnh có thể chưa vẽ: comment dòng
  `\includegraphics`, giữ figure + caption để `\ref` vẫn phân giải). Không bê các khẳng định của báo cáo mẫu vào:
  hệ thống này không dùng Gemini/vector store, gRPC, Redis Pub/Sub hay
  Transactional Outbox.

Sơ đồ tuần tự (2.2.4) đi theo đúng thứ tự subsubsection: Đăng nhập,
Quản lý lớp học (xem lớp, xem chi tiết lớp), Quản lý bài tập, Xem kết quả
chấm của cả lớp, Nộp bài tập, Xem kết quả chấm bài tập của bản thân, Xem
điểm và kết quả cá nhân, Trò chuyện với trợ lý AI. Sơ đồ nào có nhiều
lifeline và trải dài theo chiều dọc (ví dụ 13 lifeline, hơn 70 message)
thì để khổ dọc `[H]` với `max width=\textwidth` - hình cao khoảng 18-19cm,
vẫn vừa một trang cùng tiêu đề và caption; đừng ép sang trang ngang vì
khung ngang chỉ cho bề rộng ~14cm, chữ còn nhỏ hơn. Không dùng trang ngang nữa: sơ đồ rộng thì xoay ảnh 90 độ trong
trang dọc (xem mục Figures), caption vẫn nằm ngang. Giữ bản xuất Visual Paradigm (`.jpg`) ở
`visual-paradigm/figures/sequence/` và bản dùng trong báo cáo ở
`report_datn/Hinhve/` dạng `.png` (`magick <src>.jpg <dst>.png`).

Use-case figures continue the `Hinh2_<n>_<slug>` series
(`Hinh2_6_usecase_tong_quan` = overview, `Hinh2_7..Hinh2_12` = detail
diagrams), labels `fig:usecase-tong-quan` and `fig:uc-<slug>`; the
architecture figure keeps `fig:architecture` (never reuse a label).
Visual Paradigm exports stay in `visual-paradigm/figures/usecase/*.jpg`
and are duplicated into `report_datn/Hinhve/` as PNG via
`magick <src>.jpg <dst>.png` (verify the PNG keeps the source
dimensions). Never type `<<include>>`/`<<extend>>` in the `.tex`: OT1
renders `<<` as "¡¡" (in text write `bao gồm (quan hệ include)`).
Chapter 2 keeps include/extend/generalization out of prose — the
relations live inside the exported diagram images.

Class diagram design: `Biểu đồ lớp thiết kế chi tiết toàn hệ thống` is
placed immediately before `\subsection{Biểu đồ lớp chi tiết từng dịch vụ}`
in chapter 2. Caption: `Biểu đồ lớp thiết kế toàn hệ thống.`, label
`fig:class-system`, image `Hinhve/Hinh2_29_class_diagram_system.png`
with `\includegraphics[width=\textwidth]`. Each service-specific class
diagram follows with its own `\subsubsection{Biểu đồ lớp chi tiết dịch
vụ <Tên>}`, `\includegraphics[width=<width>\textwidth]{Hinhve/Hinh2_XX_...}`,
caption `Biểu đồ lớp thiết kế dịch vụ <Tên>.`, and label
`fig:class-<slug>`.
Subsubsection note: `BTL.tex` redefines `\thesubsubsection` to `\alph`
(the heading label is bare), so the actor groups print as `a,`/`b,` with
no parent number - that matches the thesis sample, keep it. Text tone
placement in this report follows the traditional style (`hoà`, `xoá`),
match it.

## Dấu gạch ngang (hyphen) thay vì gạch ngang đôi (em-dash)

Trong văn bản LaTeX của báo cáo, dùng dấu gạch ngang đơn `-` (hyphen,
U+002D), **không dùng** dấu gạch ngang đôi `—` (em-dash, U+2014) hay
`---` (em-dash LaTeX). Lý do: OT1 font rendering của `---` và `—` trong
văn bản tiếng Việt không mong muốn; dấu gạch ngang đơn an toàn, hiển thị
đúng trên mọi trình duyệt PDF.

Áp dụng cho mọi văn bản trong các file `.tex` của `report_datn/`,
bao gồm tiêu đề section/subsection, caption, itemize, enumerate, và
chú thích.

Ví dụ đúng:
- `\subsection{OAuth 2.0 - Khái niệm chung về ủy quyền}`
- `không khả thi - hệ thống bắt buộc phải dựng và chạy được server`

Ví dụ sai (đã sửa):
- `—` (em-dash) → `-` (hyphen)
- `---` (LaTeX em-dash) → `-` (hyphen)

## Dịch từ tiếng Anh sang tiếng Việt trong văn bản báo cáo

Trong văn bản LaTeX của báo cáo, dịch các từ tiếng Anh có đương equivalents tiếng Việt phổ biến sang tiếng Việt. Giữ nguyên tên công nghệ, tên công ty, tên dự án, tên tài nguyên Kubernetes (ví dụ `Service`, `Deployment`, `Ingress`, `ConfigMap`, `Secret`, `Pod`, `Namespace`), tên biến môi trường, tên file, và các lệnh kỹ thuật.

| Từ tiếng Anh | Tiếng Việt | Ghi chú |
|---|---|---|
| `deploy` | `triển khai` | Chỉ khi dùng làm động từ trong văn bản, không phải tên label/ref |
| `config` | `cấu hình` | Chỉ khi dùng làm từ độc lập, không phải phần của tên biến/env |
| `endpoint` | `điểm cuối` | Chỉ khi dùng làm từ độc lập, không phải URL path |
| `service` | `dịch vụ` | Chỉ khi dùng nghĩa chung; K8s `Service` resource giữ nguyên |
| `build` | `xây dựng` | Chỉ khi dùng ngữ nghĩa chung; `docker build` giữ nguyên |
| `config map` | `bản đồ cấu hình` | |
| `cluster` | `cụm` | Chỉ khi dùng nghĩa chung, không phải tên tài nguyên K8s |
| `license`/`licence` | `giấy phép` | |
| `interception attack` | `tấn công chặn bắt` | |
| `attacker` | `kẻ tấn công` | |

## Viết phần Observability vào Chương 3 (Triển khai hệ thống)

Khi viết phần quan sát hệ thống trong Chương 3, viết đúng những thành phần đã triển khai thực tế trong `deploy/observability/`:
- **Prometheus**: thu thập metrics từ `/actuator/prometheus` của các dịch vụ Spring Boot, lưu giữ 3 ngày.
- **Grafana**: trực quan hóa, datasource Prometheus + Tempo.
- **Tempo**: lưu trữ traces qua OTLP port 4318, retention 24 giờ, sinh RED metrics về Prometheus.

Không viết về thành phần chưa triển khai thực tế (Loki, Node Exporter, kube-state-metrics, Alertmanager, Alloy...).

## Viết phần Hướng phát triển (Chương 3)

Khi viết phần Hướng phát triển (Chương 3), chỉ ghi những gì cần cải thiện, bổ sung. Không ghi lại những gì đã triển khai trong các mục trước (ví dụ: đã triển khai Prometheus, Grafana, Tempo thì không viết "cần bổ sung hệ thống giám sát tập trung").

Ví dụ đúng:
- Về khả năng quan sát, hệ thống đã triển khai Prometheus, Grafana và Tempo (xem mục \ref{section:3.1.6}). Hiện tại hệ thống chưa có hệ thống cảnh báo tự động và lưu trữ nhật ký tập trung, cần bổ sung Alertmanager và hệ thống thu thập nhật ký tập trung trong tương lai.

Ví dụ sai (đã sửa):
- Về khả năng quan sát, cần bổ sung hệ thống giám sát tập trung gồm Prometheus và Grafana cho số liệu, Loki cho nhật ký, Tempo cho trace và Pyroscope cho profiling. Các thành phần này sẽ giúp theo dõi độ trễ, tỷ lệ lỗi, mức sử dụng tài nguyên và hành vi của từng job chấm; trên cơ sở đó đặt ra chỉ tiêu dịch vụ và cảnh báo khi có bất thường. Đây là phần chưa được trình bày trong phạm vi báo cáo.

## Usecase kế thừa từ usecase trừu tượng

Khi một usecase kế thừa từ một usecase trừu tượng (ví dụ: "Giảng viên trò chuyện với trợ lý AI" kế thừa từ "Trò chuyện với trợ lý AI"), cần ghi rõ trong mô tả: "Usecase này kế thừa từ usecase trừu tượng <Tên usecase cha>." Điều này giúp độc lập rõ ràng quan hệ giữa các usecase trong phần mô tả văn bản, bên cạnh quan hệ được vẽ trong biểu đồ usecase chi tiết.

Ví dụ đúng:
- `Usecase này kế thừa từ usecase trừu tượng Trò chuyện với trợ lý AI.`

Ví dụ đúng:
- `Build và triển khai toàn bộ cùng lúc`
- `mỗi dịch vụ có thể được build, triển khai và cập nhật`
- `giảm thiểu sai sót khi triển khai`
- `các điểm cuối cần gọi`
- `một điểm cuối server`

Ví dụ sai (đã sửa):
- `deploy` → `triển khai`
- `endpoint` → `điểm cuối`

## Chương 3 (triển khai và đánh giá)

Khi viết phần đánh giá, chỉ trình bày như kết quả những kiểm thử đã chạy và có bằng chứng. Không đưa kịch bản chức năng hoặc thử nghiệm rủi ro cao chưa thực hiện vào danh sách kết quả; nếu cần nhắc đến, chuyển ngắn gọn sang Hướng phát triển và ghi rõ chưa thực hiện. Thu hẹp phạm vi đánh giá theo yêu cầu dự án, không cần liệt kê mọi loại kiểm thử có thể có.

Kết quả đo đạc trình bày bằng bảng (caption dưới bảng, đầy đủ đường kẻ) thay vì liệt kê số liệu dài trong văn xuôi: mỗi bảng gồm kịch bản, mức tải, số yêu cầu, p50/p95/p99, tỷ lệ lỗi, kết quả; các chỉ số thời gian đầu-cuối và đối soát dữ liệu tách bảng riêng. Không kể lại các lần chạy thất bại do xác thực, token hay cấu hình môi trường trong phần kết quả — đó là lỗi vận hành khi chuẩn bị, không phải kết quả đánh giá; chỉ giữ câu giới hạn phạm vi (số người dùng ảo, số lượt) để người đọc không suy rộng.

Phần kết quả chỉ gồm ba thành phần: kịch bản đã chạy, bảng số liệu, một đoạn nhận xét ngắn. Không mô tả công cụ kiểm thử, cách runner lưu kết quả, đường dẫn thư mục `results/`, profile hay metadata lần chạy — người đọc báo cáo không cần biết quy trình vận hành harness. Những gì chưa đo được (CPU, bộ nhớ, phiên bản image, điểm bão hoà, kịch bản sự cố) đưa vào Hướng phát triển dưới dạng việc cần làm, không kể như hạn chế của kết quả vừa trình bày. Gom mọi phần kiểm thử chưa thực hiện thành một danh sách `itemize` duy nhất ở Hướng phát triển, mỗi mục là một nhóm việc (chức năng đầu-cuối, tải cao và điểm bão hoà, phục hồi khi sự cố, nhất quán dữ liệu quy mô lớn, bảo mật, sao lưu) kèm điều kiện cần (staging cô lập), thay vì rải câu "chưa thực hiện" trong phần đánh giá. Khi đã có số liệu thì không giữ câu "số liệu sẽ được bổ sung sau" ở Kết luận chương — phải viết đúng kết quả đã đo.

Bảng nhiều cột phải tính cả `\tabcolsep`: tổng bề rộng các cột cộng `2*\tabcolsep*số_cột` không vượt `\textwidth`, nếu không cột cuối tràn ra ngoài khung kẻ. Với bảng 6–8 cột, đặt `\setlength{\tabcolsep}{4pt}`, gộp mức tải vào cột kịch bản, bỏ cột "Kết quả" khi mọi dòng đều đạt (nêu trong câu nhận xét), và dùng `>{\raggedright\arraybackslash}p{...}` cho các cột hẹp để tiêu đề ngắn không bị kéo giãn chữ. Hai bảng liên tiếp trong cùng tiểu mục nên đặt cạnh nhau và tham chiếu chung một câu, tránh câu "Bảng X trình bày…" mồ côi ở cuối trang.

Mục 3.1 trình bày môi trường và kiến trúc triển khai, đóng gói Docker/Helm,
GitHub Actions, ArgoCD GitOps, hạ tầng PostgreSQL/Kafka, RustFS, Keycloak
và các thành phần observability đã triển khai thực tế. Với observability,
chỉ nêu vai trò từng thành phần: Prometheus thu số liệu định kỳ, Grafana
hiển thị số liệu từ Prometheus và truy vết từ Tempo, Tempo nhận truy vết
qua OTLP rồi đẩy RED metrics về Prometheus. Mục triển khai chỉ mô tả thành
phần đã có; không liệt kê thành phần chưa triển khai nếu đã nêu ở Hướng
phát triển. Hình kiến trúc triển khai dùng `fig:deployment` và CI/CD dùng
`fig:cicd`.

Cụm có ba namespace: `web-grading` (ứng dụng), `observability` (Prometheus +
Grafana + Tempo, cài bằng kube-prometheus-stack và Tempo chart) và `argocd`.
Chỉ Grafana mở Ingress qua Traefik; Prometheus và Tempo phục vụ trong cụm.
Mục "Tổng hợp kết quả triển khai" (3.1.7) phải liệt kê cả bộ thành phần quan
sát, không chỉ dịch vụ nghiệp vụ, và mô tả kết quả (số liệu, truy vết, dashboard)
chứ không chỉ nêu tên thành phần.

Thiết kế quy trình chấm, Grading Saga, chống trùng và phục hồi trạng thái
thuộc Chương 2 (`sec:grading-saga`). Mục 3.1 không lặp lại cơ chế này;
Mục 3.2 có thể nêu kịch bản đánh giá và hạn chế vận hành, nhưng không
khẳng định kịch bản đã chạy hoặc bịa kết quả khi chưa có số liệu thực tế.

Khi viết hạn chế và rủi ro, tách rõ hiện trạng, đường khai thác hoặc ảnh hưởng cụ thể, rồi đến khuyến nghị khắc phục. Tránh gộp nhiều luận điểm vào một câu hoặc trình bày khuyến nghị như thể đó là hiện trạng đã triển khai.

## Chương 3: mô tả vai trò, không đọc tên tham số cấu hình (mandatory)

Văn xuôi Chương 3 không nêu tên trường cấu hình, biến môi trường, tên image,
tên lớp kiểm thử hay giá trị tham số chi tiết: `ingressClassName`,
`DOCKER_HOST`, `tcp://...`, `maxSurge`, `emptyDir`, `ReadWriteOnce`,
`SASL_SSL`/`SCRAM-*`, `proxy edge`, `hostname strict`, `mvn ... -DskipTests`,
`ApplicationTests`, `/actuator/health*`, cổng cụ thể, URL miền cụ thể.
Thay bằng vai trò và hệ quả: "Traefik làm bộ điều khiển Ingress", "chiến lược
cập nhật không cho phép tạo thêm Pod khi thay image", "ổ đĩa ảo chỉ cho phép
một Pod ghi tại một thời điểm", "kết nối Kafka xác thực bằng tài khoản và
chứng chỉ CA". Vẫn giữ: số liệu có ý nghĩa đánh giá (thời gian chờ probe, mức
tài nguyên, số bản sao, dung lượng ổ đĩa), tên công nghệ, tên bảng/cơ sở dữ
liệu trong bảng tổng hợp, và tên lớp miền (`TestPlan`, `TestStep`) khi bàn về
mô hình. Khi bỏ một thuật ngữ khỏi văn xuôi, xóa luôn dòng tương ứng trong
`0_5_Danh_muc_viet_tat.tex` để danh mục không còn mục chết.

## Unnumbered preface in TOC before Chapter 1

`Chuong/0_Loi_mo_dau.tex` is included via `\chapter*{LỜI MỞ ĐẦU}`
plus `\phantomsection\addcontentsline{toc}{chapter}{LỜI MỞ ĐẦU}` and
`\markboth{LỜI MỞ ĐẦU}{LỜI MỞ ĐẦU}` (starred chapters don't update
`\leftmark`, so the running header would otherwise show stale text).
The `\titlecontents{chapter}` unnumbered `{}` format renders the entry
without a number, ahead of Chapter 1. Preface subsections are plain
numbered `\section` (manual `\addcontentsline` would duplicate them);
they print as 1, 2, 3 via `\renewcommand{\thesection}{\arabic{section}}`
scoped inside a group in the preface file, so Chapter 1 numbering is
unaffected and no `0.x` numbers appear.

## Citations complete and correctly formed (mandatory)

Every theory/technology claim cites its source with `~\cite{key}`
(IEEE numeric style, `backend=bibtex`). Prefer verified primaries:
IETF RFCs (`@techreport`), books/papers with confirmed
author/title/year/venue, and official vendor docs (`@online` with
stable landing URLs). Never invent bibliographic details — verify each
entry (web search) before adding. Bib entries stay ASCII-only (bibtex
backend breaks on UTF-8); Vietnamese stays in `.tex` body only. Author
rationale sentences ("Lý do chọn") take no citation. Before finishing,
script-check: every cited key exists in the `.bib`, braces balance per
entry, and no stale entries break the build.

## Theory chapters name no project services

Chapter 1 (theory/technology) explains methods and technologies only:
no service proper nouns (`course-service`, `submission-service`,
`executor-service`, `result-service`), no per-system wiring
(who-publishes-what, DinD pods, password-reset flows). Such details
belong to Chapter 2 (analysis/design). Generic pattern terms
(`producer`/`consumer`, `gateway`, `IdP`) and technology examples
(`ví dụ Keycloak`) are allowed; domain scenario words
(sinh viên/bài nộp) may stay in rationale sentences. Figures showing
project actors move with their paragraphs to Chapter 2.

## Whole-system analysis model matches the exported diagram

Chapter 2's whole-system class diagram (2.1.4) uses one class per
concept. Records that represent the same concept at different stages
(`GradingStepResult` in executor-service and `StepResult` in
result-service) merge into one class there. Per-service diagrams
(2.1.6) may show the separate records and must state the projection
mapping back to the merged class.

Present 2.1.4 as `Bước 4: Xét quan hệ số lượng giữa các lớp` then
`Bước 5: Bổ sung quan hệ đối tượng giữa các lớp`. Write each relation
as a full sentence with the multiplicity rationale, not a bare
`A 1 - n B` list. Bước 4 lists 1 - n relations, then n - n relations,
then resolves each n - n through an intermediate class. Bước 5 groups
the result into composition, aggregation, association, and association
classes.

The current whole-system model has 18 classes and exactly two
association classes: `UserRole` and `StudentScore`. `ClassStudent` is a
normal class with its own identity and `studentCode`, `studentName`,
`email`. `Submission` is also a normal class, not an association class:
one Assignment-ClassStudent pair can have many submissions (`latest`
marks the current one), so the pair is not unique. Draw `Submission` as
the normal intermediate class between `Assignment` and `ClassStudent`,
with `Assignment - Submission` as composition. Do not model
`ManualScore`; manual scores are represented through `StudentScore` and
`ScoreComponent`.

Only write relations present in the exported whole-system diagram. Do
not add derived or copied links there: `User - Assignment`,
`ClassStudent - User`, `User - Submission`, `TestPlan - Submission`,
`GradingJob - StepResult`, `TestPlan - Result`, `Assignment - Result`,
`User - Result`, `User - AiExplanation`, or the copied
`TestPlan`/`TestStep` to `GradingSagaStep`/`StepResult` links. Keep
`User - Submission` only in the 2.1.6 service-boundary note, because
submission-service knows only `studentId`.

Two whole-system exports exist and must not be swapped:

| Phase | Source (Visual Paradigm) | Report asset | Label |
|---|---|---|---|
| Analysis (2.1.4d) | `class-diagram/ptich/class-diagram-ptich.jpg` | `Hinhve/Hinh2_13_bieu_do_lop.png` | `fig:class-diagram` |
| Design (2.2.1) | `class-diagram/design/design-system-class-diagram.jpg` | `Hinhve/Hinh2_29_class_diagram_system.png` | `fig:he-thong-toan-bo` |

Tell them apart by content, not by filename: the analysis export has no
type annotations and no `id` attributes, the design export writes
`-name : string`, `-id : UUID`, ... and carries `«enumeration»` boxes for
statuses (`SubmissionStatus`, `GradingJobStatus`, `RunStatus`, ...).
Duplicate with `magick <src>.jpg <dst>.png` (2024-11: 1997x1018 and
2402x1093) and verify the PNG keeps the source dimensions.

Both are wider than 2:1, so an upright `width=\textwidth` shrinks the class
text to unreadable size; rotate them like the sequence diagrams with
`width=<f>\textheight,height=0.95\textwidth,keepaspectratio` and keep the
caption horizontal. The design figure shares its page with the 2.2/2.2.1
headings and two short paragraphs, so it needs `f=0.70` (`0.76` already
pushes it to the next page and leaves that page two-thirds empty); the
analysis figure stands alone under its own heading and takes `f=0.88`.
Keep the Visual Paradigm Community watermark: it sits in empty canvas at the
bottom right, so there is nothing to crop and no scope to overlap a class box.

## Per-service class diagrams (2.1.6)

Six service diagrams live in
`visual-paradigm/figures/class-diagram/ptich/` and are duplicated to
`report_datn/Hinhve/` with `magick <src>.jpg <dst>.png`:

- `ptich-auth-service.jpg` -> `Hinh2_14_class_auth.png`,
  `fig:class-auth`
- `ptich-course-service.jpg` -> `Hinh2_15_class_course.png`,
  `fig:class-course`
- `ptich-submission-service.jpg` -> `Hinh2_16_class_submission.png`,
  `fig:class-submission`
- `ptich-executor-service.jpg` -> `Hinh2_17_class_executor.png`,
  `fig:class-executor`
- `ptich-result-service.jpg` -> `Hinh2_18_class_result.png`,
  `fig:class-result`
- `ptich-ai-assistance-service.jpg` -> `Hinh2_19_class_ai.png`,
  `fig:class-ai`

Do not upscale these exports. They are small (86x72 to 394x261), so use
reduced widths to avoid blur at A4: auth 0.75, course 0.55, submission
0.35, executor 0.75, result 0.70, AI 0.30 of `\textwidth`. Keep the
Visual Paradigm Community watermark: it is acceptable evidence that
the diagrams were drawn by the author. Do not crop or cover it here,
because it overlaps class attributes in several exports.

## Technology version appendix

When documenting technology versions in appendices, derive versions from
project manifests, lockfiles, Maven BOMs, and deployment image tags. Distinguish
application image release tags from framework versions; do not infer patch
versions from floating tags (`latest`, major-only tags) or report an environment
version unless the repository records it.

Tools installed from OS packages (Arch Linux `pacman`/AUR via `yay`) have no
pinned version in the repository. Document them in a two-column table only:
tool and the version installed on the machine at the time of writing
(`Node.js & 26.13.1`). Do not add a "how to verify" column with shell commands,
a source/packaging column, or a closing paragraph explaining that the numbers
describe the machine and how to re-pin them — the user rejected all three;
keep at most one intro sentence saying the tools are not version-pinned in the
repository and that the table records the machine at the time of writing. Use
`\textnormal` for any literal inside Appendix B, not `\texttt` — the user
rejected monospace in the version appendix.

## Appendix configuration references stay concise

Appendices that document test/grading configuration are quick references for
instructors: list supported assertion and step kinds, show short examples,
and briefly describe the fields needed to use them. Avoid reproducing long
implementation flows, executor internals, deployment settings, or operational
configuration unless explicitly requested.

## One hyphen in prose; `--` only where syntax requires (mandatory)

Normal text, table cells, captions, and list items use exactly one
hyphen `-` for parenthetical breaks, ranges, and multiplicities
(`1 - n`, `n - n`, `0..1 - n`). Never write `--` or `---` as
punctuation in prose.

Keep `--` only where a tool or language requires it: BibTeX page
ranges in `.bib`, CLI flags (`--include`, `--fill`), YAML front
matter, code blocks, and command examples.

## Proofread technical Vietnamese prose

Before finalizing technical prose, read the rendered PDF for accidental
foreign-language words, missing spaces around punctuation, and joined
tokens (especially around colons and inline code). Keep literal syntax
unchanged, but separate explanatory placeholders clearly from adjacent
text; verify sentences describing implementation behavior against the
source rather than relying on outdated prose. Avoid introducing technical
labels or architecture jargon (for example, `monorepo`) when they add no
useful information; if a term is necessary, explain it at first use.

For hand-authored report diagrams requested in Mermaid, keep the `.mmd`
source in `report_datn/Hinhve/` beside the corresponding PNG path, using
the same filename stem. If the user will export the PNG, do not generate a
placeholder image; keep the figure caption/label and a commented
`\\includegraphics` line with the intended output path.

## Mọi thuật ngữ tiếng Anh phải có trong danh mục thuật ngữ (mandatory)

Danh mục in ra là `Chuong/0_5_Danh_muc_viet_tat.tex` (front matter, trước
Chương 1), nên thuật ngữ được khai báo ở đó là "khai báo trước khi dùng".
`Tu_viet_tat.tex` không in ra (`\printnoidxglossaries` bị comment) nên
đừng thêm entry vào đó rồi tưởng là đã khai báo.

- Mỗi từ tiếng Anh dùng như thuật ngữ trong văn bản (ví dụ `staging`,
  `job`, `image`, `tag`, `webhook`, `traceId`, `pull request`, `path`,
  `assertion`) cần một dòng trong longtable: cột 1 là từ, cột 2 tên
  tiếng Anh đầy đủ, cột 3 nghĩa tiếng Việt ngắn.
- Khi khái niệm đã có dòng trong danh mục thì dùng thẳng thuật ngữ đó
  trong văn xuôi, đừng dịch thành cụm tiếng Việt khó hiểu. Các cặp đã
  sửa trong báo cáo: "luồng ảo" -> `virtual thread`, "nhóm tiêu thụ
  riêng" -> `consumer group`, "điểm cuối" -> `endpoint`, "bảng điều
  khiển" -> `dashboard`, "ngân sách gián đoạn" -> `PodDisruptionBudget`,
  "cấu hình sẵn sàng cao" -> `high availability`, "bảng ghi sự kiện cần
  gửi" -> `outbox`, "thuê quyền xử lý có thời hạn" -> `lease`. Chỉ dịch
  khi đã có từ tiếng Việt phổ biến và ngắn (hàng đợi, cổng, cơ sở dữ
  liệu, nhật ký, số liệu).
- Nếu đã có tương đương tiếng Việt phổ biến, dịch theo bảng
  "Dịch từ tiếng Anh sang tiếng Việt" thay vì thêm dòng mới; chỉ khai
  báo những từ buộc phải giữ tiếng Anh (tên công nghệ, trạng thái,
  khái niệm không có từ Việt tương đương rõ).
- Trước khi thêm, kiểm tra trùng: cùng một khái niệm chỉ một dòng.
  Không thêm `Token` khi đã có `Access Token`/`ID Token`/`Refresh Token`,
  không thêm `Docker Image` khi đã có `Image`, không thêm
  `Readiness`/`Liveness` riêng khi đã có `Readiness probe`/
  `Liveness probe`. Script kiểm tra nhanh:

```bash
grep -v 'Tên tiếng Anh' Chuong/0_5_Danh_muc_viet_tat.tex \
  | grep -o 'textbf{[^}]*}' | sed 's/textbf{//;s/}//' \
  | tr 'A-Z' 'a-z' | sort | uniq -d
```

  Kết quả rỗng là không trùng. Luôn lọc dòng header
  (`Viết tắt & Tên tiếng Anh & Tên tiếng Việt`) vì header xuất hiện hai
  lần trong `\endfirsthead` và `\endhead` và cũng dùng `\textbf{}`.
- Cột 1 rộng 3.2cm, cột 2 rộng 3.5cm: cụm hai từ như `Readiness probe`
  vừa khít cột 2, đừng thu cột 2 xuống 3.0cm (sẽ chạm cột 3). Từ dài
  không có chỗ ngắt phải chèn `\-` hoặc nới cột.
- Bổ sung hàng loạt entry thì thêm thành một khối ở cuối bảng, giữ
  nguyên thứ tự các entry cũ, và build lại để kiểm tra longtable vẫn
  sang trang đúng (`\singlespacing` trước bảng, `\onehalfspacing` sau
  `\end{longtable}`).

## Concurrent builds corrupt `build/` (gotcha)

An editor watcher (TeXstudio, VS Code LaTeX Workshop) may run `latexmk` on the
same `build/` directory at the same time as the shell. Two writers produce a
truncated `.aux`/`.toc` and a broken PDF: symptoms are `File ended while
scanning use of \@writefile`, `Illegal character <..> in hex string`, or
`Couldn't find trailer dictionary`. Check `pgrep -a latexmk` before building;
if a watcher build is running, wait for it to finish instead of racing. After a
race, delete `build/BTL.aux .toc .lof .lot .out` and rebuild once (a second
immediate run is needed because latexmk schedules bibtex against the empty
aux).
