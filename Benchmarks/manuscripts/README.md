# Manuscript benchmark (M2)

**中文摘要。** 这里是 M2「稿件级检查」的验收材料：11 篇 arXiv 论文（CC BY 4.0）的 `.tex`、`.bib`、`.bbl` 源文件，目录结构不变，图片、类文件、宏包一律没有放进来。每篇有 `expected.json`：用 Tectonic 0.17 编译出的 `.aux` 里的引用键和标签集合，加 LaTeX 日志、BibTeX 日志里记下的问题。`.aux` 里宏包内部的标签（含 `@` 的键等）单独列在 `excluded_internal_labels`，不进 `labels`。`papers.tsv` 记录每个源码包的 SHA-256；`bibtex-entry-counts.tsv` 是 BibTeX 自己读出的每份 `.bib` 的条数。重新生成只有调度方用 `Scripts/acceptance/m2-regen-expected.sh`（需要 Tectonic），测试和验收脚本不调用它，也不联网。

## Contents

| Path | What |
|---|---|
| `<arXiv id><version>/src/` | `.tex`, `.bib`, `.bbl` files of the source package, directory structure unchanged, files unmodified |
| `<arXiv id><version>/expected.json` | expected sets and log findings (see below) |
| `<arXiv id><version>/ATTRIBUTION.md` | title, authors, arXiv URL, licence |
| `2506.06594v1/bibitems.gold.tsv` | 32 `\bibitem` entries annotated by hand from the manuscript text: first-author family name, year, title, identifier. It records what the manuscript says, not facts about the cited works |
| `papers.tsv` | the 11 chosen rows, with the SHA-256 of each source package |
| `bibtex-entry-counts.tsv` | number of entries BibTeX itself reads from each `.bib` (and how many were repeated or erroneous) |

The 11 papers cover IEEEtran (journal and conference), ICML 2025, NeurIPS 2024 workshop and 2026, Elsevier elsarticle and cas-dc, and acmart. They use `.bib` plus `.bbl`, `.bib` only, `.bbl` only (`2405.13682`, `\input{main.bbl}`), and a hand-written `thebibliography` (`2506.06594`).

## How the papers were chosen

From arXiv metadata (OAI-PMH records and API queries, polite single-threaded access with the User-Agent `ScholarOS-benchmark/1.0`, at least 3 s between requests), candidates were taken from OAI-PMH listings whose record datestamps fall in 2025–2026 and whose licence field is `http://creativecommons.org/licenses/by/4.0/`. A datestamp changes when a new version is posted, so some papers first submitted earlier (for example `2212.14225`, version 5) are included; the version used is the one in `papers.tsv`. Source packages were inspected without extraction, then extracted only into dedicated directories and compiled in a sandbox without network. Candidates were kept when they come from different templates, compile with Tectonic 0.17, and together exercise different bibliography set-ups, multi-file sources (`2405.13682` has 17 `.tex` files, `2410.04196` 12, `2610.15486` 9) and large `.bib` files (`2503.18124`: 289 entries; `2409.19431`: 488 entries read by BibTeX, 181 repeated). Candidates that Tectonic cannot compile were rejected (reasons are in the `status` column of the full list kept by the dispatcher; the reserve papers are not in this repository). `2506.06594` was added on purpose because it has no `.bib` and no `.bbl`: 32 `\bibitem` entries written in the `.tex`.

## Licence

All 11 papers are CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/); the licence is taken from the arXiv metadata record (the `licence_source` column of `papers.tsv` names the record file used). Title, authors and the arXiv address of each paper are in its `ATTRIBUTION.md`. Only `.tex`, `.bib` and `.bbl` files were kept; figures and all other files were removed. The kept files are not modified. The `expected.json` files, `papers.tsv` and the gold file are our own annotations.

## How the expected sets were generated

Each package was extracted and compiled once with Tectonic 0.17.0 (bundle `https://relay.fullyjustified.net/default_bundle_v33.tar`) as `tectonic --untrusted --keep-intermediates --keep-logs <main file>`, inside `sandbox-exec` with network denied and a prepared offline cache. From the output directory:

- `cite_keys`: every key in `\citation{...}` of the main `.aux` and of every `.aux` it reaches through `\@input{...}` (this is how `\include` shows up). `\citation{*}` sets `nocite_star` and adds no key.
- `bibcite_keys`: keys in `\bibcite{...}`.
- `labels`: keys in `\newlabel{...}`, minus the package-internal ones below.
- `latex_log`: keys from the LaTeX log lines "Citation `k' undefined" (`undefined_citations`), "Reference `k' on page N undefined" (`undefined_references`) and "Label `k' multiply defined" (`multiply_defined_labels`).
- `bibtex_log`: keys from "I didn't find a database entry for ..." (`missing_entries`), the BibTeX error-message count and whether BibTeX ran at all.
- `generated_utc` and `generator` record when and with what; `generated_utc` is ignored when comparing.

`bibtex-entry-counts.tsv` was made separately: a tiny document writes `\citation{*}` and the `.bib` file's name into its `.aux`, Tectonic runs BibTeX over it, and the `\bibitem` lines of the resulting `.bbl` are counted (BibTeX decides what counts as an entry, and which are repeated or erroneous).

### Package-internal labels removed from the `.aux` sets

These keys are written by packages (`hyperref`, `cleveref`, `subcaption`/`subfig`, `tocloft`, `lastpage`, ...), not by the author, and are listed in `excluded_internal_labels` instead of `labels`. A key is internal when it matches one of (from `Scripts/acceptance/m2_expected.py`, `INTERNAL`):

| Pattern | Examples seen |
|---|---|
| `...@cref` (ends in `@cref`) | `fig:joint@cref`, `lem:bct@cref` |
| `sub@...` (starts with `sub@`) | `sub@fig:modes-a` |
| `tocindent-<n>` / `tocindent<n>` | |
| `LastPage`, `LastPages`, `TotPages` | |
| any key containing `@` | everything above, and other package-internal keys |

Because the last pattern catches every key containing `@`, a label an author writes with `@` inside would also be excluded (none of the 11 papers does). The numbers per paper (labels / internal) are visible in each `expected.json`.

## Limits

The sets are what LaTeX itself produced for the main file. A static reader cannot see labels or citations created by macro expansion, so differences that come from macros are possible by nature; the expected sets contain no exception list.

## Regenerating (dispatcher only)

`Scripts/acceptance/m2-regen-expected.sh` needs Tectonic 0.17 and `sandbox-exec`. Without Tectonic it prints `没跑` and exits 2. Tests and `m2-acceptance.sh` never call it.

```sh
# compare with the committed files, from local packages and a prepared cache (no network)
Scripts/acceptance/m2-regen-expected.sh --check --packages <dir with <id><version>.pkg or raw/> --tectonic-cache <dir>

# re-download the packages from arXiv (3 s apart, User-Agent ScholarOS-benchmark/1.0), SHA-256 checked against papers.tsv
Scripts/acceptance/m2-regen-expected.sh --check --tectonic-cache <dir>

# rewrite the expected.json files (drop --check)
Scripts/acceptance/m2-regen-expected.sh --packages <dir> --tectonic-cache <dir>
```

The script verifies each package against `package_sha256` in `papers.tsv`, extracts it into a temporary directory (regular files only), compiles it inside `sandbox-exec -p '(version 1)(allow default)(deny network*)'` with a temporary `HOME` and a temporary copy of the cache (it never writes to `~/Library`), rebuilds `expected.json` with `Scripts/acceptance/m2_expected.py` (run with `python3 -I`), and prints every difference from the committed file; `--check` exits 1 on any. Without `--tectonic-cache` the cache starts empty and the offline compile cannot fetch the bundle; `--warm-cache` does one trivial compile with network access to fill it.

Fixtures for unit tests live in `Tests/Fixtures/manuscripts/` (`hard-inputs`, `include-multi`, `bib-recovery`, `bib-fields`, with their expected files in `expected/`).
