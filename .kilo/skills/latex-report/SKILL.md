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

## Use-case diagrams and descriptions (Chapter 2)

Chapter 2 section 2.1 holds the use-case analysis: 2.1.1 lists the four
actors (User parent, Admin/Lecturer/Student inheriting from it) as an
`itemize`; 2.1.2 shows the overview diagram plus the full use-case list
(one sentence per use case, Vietnamese name only: `Tên usecase: Usecase
này cho phép <tác nhân> ...`). 2.1.3 `Kịch bản các chức năng` carries
the detail material, grouped by actor in `\subsubsection`s: (a) chung
(Đăng nhập, Đổi mật khẩu), (b) quản trị viên (Nhập danh sách tài
khoản), (c) giảng viên (Quản lý lớp học, Quản lý bài tập, Xem kết quả
chấm của cả lớp), (d) sinh viên (Nộp bài tập, Xem điểm và kết quả cá
nhân, Xem kết quả chấm bài tập của bản thân). Inside a group each
function starts directly with its lead sentence (`Bảng … mô tả kịch
bản …` / `Hình … mô tả chi tiết …`), then its detail figure where a
diagram exists, then the scenario table. Never mark a function with a
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
Subsubsection note: `BTL.tex` redefines `\thesubsubsection` to `\alph`
(the heading label is bare), so the actor groups print as `a,`/`b,` with
no parent number — that matches the thesis sample, keep it. Text tone
placement in this report follows the traditional style (`hoà`, `xoá`),
match it.

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

The whole-system export lives at
`visual-paradigm/figures/class-diagram/ptich/class-diagram-ptich.jpg`
and is duplicated to
`report_datn/Hinhve/Hinh2_13_bieu_do_lop.png`. The Visual Paradigm
Community watermark sits at the bottom right; for the 834x821 export,
cover it with a white rectangle instead of cropping, because cropping
the bottom cuts the `StepResult` class box:
`magick <src>.jpg -fill white -draw "rectangle 580,785 834,821" <dst>.png`.
Verify the PNG keeps 834x821.

## One hyphen in prose; `--` only where syntax requires (mandatory)

Normal text, table cells, captions, and list items use exactly one
hyphen `-` for parenthetical breaks, ranges, and multiplicities
(`1 - n`, `n - n`, `0..1 - n`). Never write `--` or `---` as
punctuation in prose.

Keep `--` only where a tool or language requires it: BibTeX page
ranges in `.bib`, CLI flags (`--include`, `--fill`), YAML front
matter, code blocks, and command examples.
