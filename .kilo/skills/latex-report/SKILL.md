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
there, works regardless of hyphenation patterns).

## Figures

PNGs live in `report_datn/Hinhve/`, named `Hinh2_<n>_<slug>.png`
(e.g. `Hinh2_5_lua_ng_pkce.png`), included at `width=\textwidth` with
`\label{fig:<slug>}`. Graphviz `dot` is available for regenerating
flowcharts; keep node font sizes so text stays legible at text width.
