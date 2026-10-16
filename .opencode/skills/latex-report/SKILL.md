---
name: latex-report
description: LaTeX thesis report formatting conventions for report_datn/ - no bold in body text, enumerate/itemize for all listings, underscore escaping in text, glossary longtable column widths, figure naming. Use when writing or reviewing any .tex chapter, glossary entries, or report figures.
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

## Figures

PNGs live in `report_datn/Hinhve/`, named `Hinh2_<n>_<slug>.png`
(e.g. `Hinh2_5_lua_ng_pkce.png`), included at `width=\textwidth` with
`\label{fig:<slug>}`. Graphviz `dot` is available for regenerating
flowcharts; keep node font sizes so text stays legible at text width.

## Use-case diagrams and descriptions (Chapter 2)

Chapter 2 section 2.1 holds the use-case analysis: 2.1.1 lists the four
actors (User parent, Admin/Lecturer/Student inheriting from it) as an
`itemize`; 2.1.2 shows the overview diagram plus the full use-case list;
each detailed use case then gets its own `\subsection` (2.1.3 onward,
lecturer use cases then student ones) with its figure and a
sub-use-case `itemize`. List-item pattern, one sentence naming actor
and capability then the purpose:
`Tên usecase (nghĩa tiếng Việt): Usecase này cho phép <tác nhân> ...`
ending with a period; keep the diagram's English label verbatim so the
reader can match text to figure. Use-case figures continue the
`Hinh2_<n>_<slug>` series (`Hinh2_6_usecase_tong_quan` = overview,
`Hinh2_7..Hinh2_12` = detail diagrams), labels `fig:usecase-tong-quan`
and `fig:uc-<slug>`; the architecture figure keeps `fig:architecture`
(never reuse a label). Visual Paradigm exports stay in
`visual-paradigm/figures/usecase/*.jpg` and are duplicated into
`report_datn/Hinhve/` as PNG via `magick <src>.jpg <dst>.png` (verify
the PNG keeps the source dimensions). Never type `<<include>>` or
`<<extend>>` into the `.tex`: OT1 renders `<<` as "¡¡" — write
"bao gồm (quan hệ include)", "mở rộng (quan hệ extend)",
"kế thừa (quan hệ generalization)". Subsubsection gotcha: `BTL.tex`
redefines `\thesubsubsection` to `\alph` and the heading label is bare,
so a `\subsubsection` prints as `a,` with no parent number — prefer
plain `\subsection` for numbered detail sections. Text tone placement
in this report follows the traditional style (`hoà`, `xoá`), match it.

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

## Single hyphen only, never em-dash (mandatory)

Body text uses the single hyphen `-` for parenthetical breaks — never
the LaTeX em-dash `---`. (The en-dash `--` stays reserved for numeric
ranges such as page numbers in `.bib` entries.)
