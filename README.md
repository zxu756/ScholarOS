# ScholarOS

**English** | **[简体中文](README.zh-CN.md)**

macOS Swift package (`1.4.0`) and bilingual (`--lang en|zh`) command-line tool (`scholaros`) for online citation verification against public scholarly registries, LaTeX/BibTeX parsing, APA 7th / IEEE reference formatting, statistical agreement/meta-analysis library routines, and a stdio JSON-RPC 2.0 MCP server.

> **Fabricated references do not enter your `.bib`.** On a 480-entry mixed benchmark of real, fabricated, mutated, and retracted references, **0** fabricated entries are judged verified (`0/80` in `fabricated_model`; `0/86` across all `truth=fabricated` entries; `0/254` across all non-insertable entries), and the rate at which genuine references in the three real groups are falsely judged non-existent or retracted (`NOT_FOUND` or `RETRACTED`) is **0% (`0/215`)** (`0/220` across all 220 entries of the three real groups; `0/225` across all `truth=real` entries in the benchmark).

> **Current Status (M0, M1 & M2 acceptance passed):** M0, M1, and M2 acceptance checks pass as verified by [`Scripts/acceptance/m0-acceptance.sh`](Scripts/acceptance/m0-acceptance.sh), [`Scripts/acceptance/m1-acceptance.sh`](Scripts/acceptance/m1-acceptance.sh), [`Scripts/acceptance/m2-acceptance.sh`](Scripts/acceptance/m2-acceptance.sh), and [`Scripts/acceptance/hard-inputs.sh`](Scripts/acceptance/hard-inputs.sh) (`Scripts/test.sh milestone 2`; live registry rows M1 Row 19 & Row 23 require `SCHOLAR_ONLINE=1`, M2 Row 17 source-mutation cloning runs via [`Scripts/acceptance/m2-mutations.sh`](Scripts/acceptance/m2-mutations.sh), and M2 Row 19 Tectonic regeneration runs via [`Scripts/acceptance/m2-regen-expected.sh`](Scripts/acceptance/m2-regen-expected.sh) `--check` — otherwise those rows print `SKIP (没跑)`). `scholaros verify-citations`, MCP `scholar_verify_bibliography`, `scholaros diagnostics`, MCP `scholar_lsp_diagnostics` (`path`), `scholaros cite`, and MCP `scholar_cite_key` share the same citation verification pipeline against public registries online by default with SQLite caching, rate limiting, and retry backoff; `--offline` sends zero network requests, `--registry-replay <dir>` replays SHA-256-verified recorded fixtures offline (`REPLAY`), `--no-verify` runs structure/lint diagnostics without citation verification, `.bib` `x-firewall-class`/`x-firewall-note` declarations are ignored, and cached/stored verdicts expire after 30 days (1 day for `NOT_FOUND`). On the 11 CC BY 4.0 arXiv manuscripts in [`Benchmarks/manuscripts/`](Benchmarks/manuscripts/), static multi-file loading, verbatim/URL/conditional skipping, BibTeX error recovery, and `thebibliography`/`.bbl` extraction match the committed Tectonic 0.17 `.aux`/`.blg` expectations without performing TeX macro expansion. The macOS desktop window starts empty and **only displays sample data** when `--demo` or **Load Demo** is explicitly selected (`DEMO` banner).

---

## Citation Verification Benchmark (`2026-11-16`)

- **Date & source report:** `2026-11-16` (commit `5c63fc4`), from [`reports/citation-bench-2026-11-16-live.json`](reports/citation-bench-2026-11-16-live.json).
- **Public registries queried:** Crossref, OpenAlex, `doi.org` Handle API, arXiv Atom API, and PubMed `esummary` — queried **without API keys, email addresses, or account credentials** (`User-Agent: ScholarOS/1.2.0`).
- **Benchmark composition (`12` groups, `480` entries total; full provenance and per-entry analysis in [`Benchmarks/citations/README.md`](Benchmarks/citations/README.md)):** `audit_manual` (`30` handwritten edge cases), `real_clean` (`100` stratified OpenAlex-sampled / Crossref-converted journal articles), `real_human` (`100` byte-exact entries from 24 CC BY 4.0 arXiv `.bib` files, 65 with DOI and 35 without), `real_typo` (`20` deterministic edits on `real_clean`: 15 harmless format variants and 5 single-letter title typos), `fabricated_model` (`80` offline model-invented entries: 40 Codex + 40 Mistral Vibe, 56 with identifiers and 24 without), 6 deterministic mutation groups of `20` each on `real_clean` (`mut_year1`, `mut_year3`, `mut_author`, `mut_title`, `mut_doi_swap`, `mut_doi_missing`), and `retracted` (`30` non-built-in retracted works from Crossref/OpenAlex).
- **Live vs. replay parity & measurement scope:** The live run (`1015` HTTP requests, `390` OpenAlex credits, `631.202` s, max `1` Crossref request in flight) produced **identical verdicts on all `480/480` entries** (`live_vs_replay_diff = []`) to offline replay of [`Benchmarks/citations/recordings/`](Benchmarks/citations/recordings) (`748` items, `manifest.json` SHA-256 `81fd7b8e8a20c106fb186c170dedeb42541dc3b1f7d870e2afcd55fb333bbb7b`). **The live benchmark has been run once on a single machine (macOS arm64, 2026-11-16).**

### Summary Metrics & Hard Requirements

| Metric / Gate | Result (with denominator) | Notes |
|---|---|---|
| **Allow (`VERIFIED`) precision** (`insertable=true` among `VERIFIED`) | **`100.00%` (`206/206`)** | **Hard requirement (`100%`): Passed.** Includes `5/206` `VERIFIED` entries carrying an advisory venue wording hint. |
| **Allow (`VERIFIED`) recall** (`VERIFIED` among `insertable=true`) | **`91.15%` (`206/226`)** | With identifier: `96.89%` (`187/193`); without identifier: `57.58%` (`19/33`). Real three groups (`truth=real`): `91.63%` (`197/215`); `real_clean`: `100.00%` (`100/100`). |
| **Block (`DRIFT` / `NOT_FOUND` / `RETRACTED`) precision** (`truth!=real` among blocked) | **`96.62%` (`229/237`)** | Remaining `8/237` are `real_human` entries flagged `DRIFT` for actual metadata discrepancies against registries. With identifier: `98.28%` (`229/233`). |
| **Block (`DRIFT` / `NOT_FOUND` / `RETRACTED`) recall** (blocked among `truth!=real`) | **`89.80%` (`229/255`)** | Against `insertable=false`: `90.16%` (`229/254`); the other `25/254` are identifierless fabricated entries judged `UNVERIFIED` (`no_match_in_search`, still not insertable), plus `1` `truth=mutated` entry (`audit_020`, `insertable=true`, venue-only change) judged `VERIFIED` with venue hint. With identifier: `99.57%` (`229/230`), `100.00%` (`229/229`) on `insertable=false`. |
| **`UNVERIFIED` rate & reasons** | **`7.71%` (`37/480`)** | `no_match_in_search`: `7.29%` (`35/480`; `35/58` of identifierless entries); `registered_no_metadata`: `0.42%` (`2/480`; `2/422` of entries with an identifier); transient/network/parse errors & `ambiguous`: `0.00%` (`0/480`). |
| **Hard requirement: non-insertable (`insertable=false`) judged `VERIFIED`** | **`0.00%` (`0/254`)** | **Passed** (`0` across fabricated, unregistered-DOI, mutated, and retracted entries). |
| **Hard requirement: `mut_doi_missing` (real metadata + unregistered DOI)** | **`0/20` `VERIFIED`, `19/19` true DOI recovered** | **Passed.** `DRIFT`: `19/20` (`95.00%`, all `19/19` reporting the gold `true_doi`); `NOT_FOUND`: `1/20` (`5.00%`). |
| **Hard requirement: full 480-entry completion & replay parity** | **`complete=true`, `0/480` misses** | **Passed.** Live vs. replay verdict differences: `0/480`. |

### Per-Group Verdict Distribution & Agreement with `gold.jsonl` (`expected`)

| Group (`entries/<group>.bib`) | Entries | `VERIFIED` (venue hint) | `DRIFT` | `NOT_FOUND` | `RETRACTED` | `UNVERIFIED` | In `expected` |
|---|---:|---:|---:|---:|---:|---:|---:|
| `audit_manual` | 30 | 9 (1) | 11 | 5 | 2 | 3 | **`30/30` (`100.0%`)** |
| `real_clean` | 100 | 100 (0) | 0 | 0 | 0 | 0 | **`100/100` (`100.0%`)** |
| `real_human` | 100 | 82 (4) | 8 | 0 | 0 | 10 | **`90/100` (`90.0%`)** |
| `real_typo` | 20 | 15 (0) | 5 | 0 | 0 | 0 | **`20/20` (`100.0%`)** |
| `fabricated_model` (56 w/ ID, 24 w/o ID) | 80 | 0 (0) | 41 | 15 | 0 | 24 | **`80/80` (`100.0%`)** (`56/56` w/ ID, `24/24` w/o ID) |
| `mut_year1` | 20 | 0 (0) | 20 | 0 | 0 | 0 | **`20/20` (`100.0%`)** |
| `mut_year3` | 20 | 0 (0) | 20 | 0 | 0 | 0 | **`20/20` (`100.0%`)** |
| `mut_author` | 20 | 0 (0) | 20 | 0 | 0 | 0 | **`20/20` (`100.0%`)** |
| `mut_title` | 20 | 0 (0) | 20 | 0 | 0 | 0 | **`20/20` (`100.0%`)** |
| `mut_doi_swap` | 20 | 0 (0) | 20 | 0 | 0 | 0 | **`20/20` (`100.0%`)** |
| `mut_doi_missing` | 20 | 0 (0) | 19 | 1 | 0 | 0 | **`20/20` (`100.0%`)** |
| `retracted` | 30 | 0 (0) | 0 | 0 | 30 | 0 | **`30/30` (`100.0%`)** |
| **Total** | **480** | **206 (5)** | **184** | **21** | **32** | **37** | **`470/480` (`97.92%`)** |

### Verification Boundaries

- **Confirms existence and bibliographic metadata only:** Citation verification checks that a cited work exists in public scholarly registries and that its identifier, title, publication year, first author, and author count match the registry record (and that the record is not flagged retracted).
- **Does NOT verify claim support:** It **cannot** judge whether the cited work actually supports the claim or sentence you wrote in your manuscript.
- **Identifierless works absent from search are `UNVERIFIED`, never `NOT_FOUND`:** Entries without a DOI, arXiv ID, or PMID that yield no matching candidate in both Crossref and OpenAlex searches are reported only as `UNVERIFIED` (`no_match_in_search`, non-insertable) — never as "non-existent" (`NOT_FOUND`), because real books, book chapters, and unindexed conference papers are absent from both search APIs.
- **Genuine works with venue-only wording differences pass with an advisory hint:** When identifier, title, year, first author, and author count all match a real registry record and only the journal/conference wording differs (beyond three deterministic same-venue checks), the entry is cleared as `VERIFIED` (`insertable: true`) with an advisory `venue` hint (`5/206` `VERIFIED` entries in the benchmark).

### How to Reproduce

```bash
# 1. Offline M2 + M1 + M0 acceptance suites + recorded benchmark replay (no network requests)
Scripts/test.sh milestone 2
Scripts/test.sh milestone 1

# 2. Offline replay of the 480-entry citation benchmark against Benchmarks/citations/recordings/
python3 Scripts/acceptance/m1-citation-bench.py --replay

# 3. Live 480-entry benchmark against public registries (2026-11-16 run: 631.202 s, 1015 HTTP requests, 390 OpenAlex credits)
SCHOLAR_ONLINE=1 python3 Scripts/acceptance/m1-citation-bench.py --live
```

---

## Verified Capabilities (`2026-11-14` M0, `2026-11-16` M1 & `2026-11-17` M2)

M2 manuscript-level checks come from [`Scripts/acceptance/m2-acceptance.sh`](Scripts/acceptance/m2-acceptance.sh) and [`Benchmarks/manuscripts/`](Benchmarks/manuscripts/); M1 citation verification metrics and acceptance checks come from [`reports/citation-bench-2026-11-16-live.json`](reports/citation-bench-2026-11-16-live.json) (`2026-11-16`) and [`Scripts/acceptance/m1-acceptance.sh`](Scripts/acceptance/m1-acceptance.sh); M0 parsing, formatting, statistical, MCP protocol, and CLI baseline numbers come from [`reports/m0-acceptance.txt`](reports/m0-acceptance.txt) and [`reports/readme-commands.txt`](reports/readme-commands.txt) (`2026-11-14`, macOS arm64, `Scripts/test.sh milestone 0`; without `--record`, reports go to a temporary directory and leave `reports/` untouched).

- **Citation Verification (`scholaros verify-citations`, `scholaros cite`, `scholaros cache clear`, MCP `scholar_verify_bibliography`, MCP `scholar_cite_key`)** ([`reports/citation-bench-2026-11-16-live.json`](reports/citation-bench-2026-11-16-live.json), `2026-11-16`): Classifies entries into 5 states (`VERIFIED`, `DRIFT`, `NOT_FOUND`, `RETRACTED`, `UNVERIFIED`) with `--lang en`, `--lang zh`, and `--json` output:
  - Queries Crossref, OpenAlex, `doi.org`, arXiv, and PubMed online by default and caches valid responses in SQLite (`~/Library/Caches/ScholarOS/registry.sqlite`, or `$SCHOLAR_CACHE_DIR/registry.sqlite`; 30-day TTL for valid `200` records, 1-day TTL for confirmed non-existence); `--no-cache` skips reading and writing the cache for one run, `scholaros cache clear` removes `registry.sqlite` (`-wal`/`-shm`), and `--verbose` logs one line per lookup to `stderr` (source, URL, status, elapsed time, and origin).
  - `--offline` sends zero network requests and neither reads nor writes the cache, checking identifier syntax and the incomplete 8-DOI built-in retraction hint list only (`built-in list, incomplete`; `内置名单，不完整` under `--lang zh`); unqueried valid identifiers are reported as `UNVERIFIED`.
  - `--registry-record <dir>` queries live registries (using the cache unless `--no-cache` is passed) and writes raw response bytes, per-item metadata, and a SHA-256 `manifest.json` into `<dir>`, reusing URLs already recorded in `<dir>`; `--registry-record-limit <N>` (positive integer, default `80`, valid only with `--registry-record`) caps the number of new HTTP requests sent in that run.
  - `--registry-replay <dir>` replays SHA-256-verified recorded responses without network access (reading/writing the cache only when `SCHOLAR_CACHE_DIR` is explicitly set, never the default cache directory) and marks output with `REPLAY`.
  - Syntactically malformed identifiers are reported as `NOT_FOUND` (`invalid_identifier`); sentinel prefixes (`10.0000/`, `10.1234/`, `10.9999/`, etc.) have valid ISO 26324 syntax and require registry lookup rather than offline rejection. Embedded `.bib` `x-firewall-class` / `x-firewall-note` fields are ignored and omitted on export.
  - Exit codes: `0` when all entries are `VERIFIED`; `1` when any entry is `DRIFT`, `NOT_FOUND`, `RETRACTED`, or a partial BibTeX `parse_error`; `3` when none of those occur and at least one entry is `UNVERIFIED`; `2` on usage, missing-file, zero-valid-entry BibTeX parse, or replay errors.
- **LaTeX Outline & Manuscript Diagnostics (`scholaros outline`, `scholaros diagnostics`, MCP `scholar_lsp_diagnostics`)** ([`reports/m0-acceptance.txt`](reports/m0-acceptance.txt), `2026-11-14` & [`Scripts/acceptance/m2-acceptance.sh`](Scripts/acceptance/m2-acceptance.sh), `2026-11-17`): Lexes and parses LaTeX manuscripts directly from `.tex` files without creating a project bundle. On the 449-line IEEEtran-style sample manuscript [`Fixtures/sample-ieeetran-manuscript.tex`](Fixtures/sample-ieeetran-manuscript.tex) (fictional content written for this repository, so anyone can rerun the check), `scholaros outline` extracts all `46` `\section`/`\subsection` headings, numbered and starred, in both `--lang en` and `--lang zh`, matching `grep -c -E '\\(section|subsection)\*?\{'` (measured 2026-11-14).
  - Resolves multi-file graphs (`\input`, unbraced `\input`, `\include`, `\InputIfFileExists`, `\subfile`, `\import`, `\subimport`) with Windows-1252 fallback (`ENC001`), skips verbatim/code/URL/conditional spans losslessly (`\verb`, `verbatim`, `lstlisting`, `\lstinline`, `minted`, `\mintinline`, `comment`, `\iffalse...\fi`, `\url`, `\path`, `\nolinkurl`, `\href`), and extracts bibliography entries from `.bib`, `thebibliography`, `\input{*.bbl}`, and `<main>.bbl` fallback (`BIB_FROM_BBL`).
  - Separates diagnostics into `structure` (`SYM003`, `SYM004`, `CITE404`, `INC002`, `BIB001`, `CITE_KEY_CASE`, etc.), `citation` (at most one `ERR_UNVERIFIED_CITATION` per unique cited key: `ERROR` on `DRIFT`/`NOT_FOUND`/`RETRACTED`, `WARNING` with reason code on `UNVERIFIED`), and `lint` (`LINT_LABEL_BEFORE_CAPTION` `WARNING`; `LINT_UNCITED_BIB_ENTRY` and float hints `INFO`/`HINT`, suppressed under `\nocite{*}` and for `crossref` parents).
  - Text output prints non-citation diagnostics first, then a single-line citation verification summary (`Citation verification: N key(s), VERIFIED ..., UNVERIFIED ...` / `引用核查：N 个键，...`), followed by per-key `ERR_UNVERIFIED_CITATION` lines for non-`VERIFIED` keys; `--json` emits a deterministic `scholaros.diagnostics/1` object without timestamps or random IDs.
  - `--no-verify` runs structure and lint checks without invoking citation verification (printing `Citation verification: skipped (--no-verify; citations not verified, ...)` / `引用核查：未核查引用...`, exit codes `0`/`1`/`2` only). Standard `diagnostics` exit codes match `verify-citations`: `0` when `structure` `ERROR` count is `0` and all cited keys are `VERIFIED`; `1` on any `structure` `ERROR` or any `DRIFT`/`NOT_FOUND`/`RETRACTED` cited key; `3` when neither occurs and at least one cited key is `UNVERIFIED`; `2` on usage or missing-file errors.
- **BibTeX Parsing & APA 7th / IEEE Formatting (`scholaros format-bib`)** ([`reports/m0-acceptance.txt`](reports/m0-acceptance.txt), `2026-11-14`; CRLF support added in M1; recovery & field rules added in M2): Parses `.bib` files directly (LF, CRLF, or mixed line endings) with BibTeX 0.99d identifier character rules, single-entry error recovery (`BIB001`; exits `1` when remaining entries format cleanly, `2` when zero valid entries exist), `and others` author truncation (`authorsTruncated` without producing `"and et al."`), two-pass `crossref` inheritance (`BIB003`), and `\url`/`\href` extraction from `howpublished`/`note`, rendering APA 7th (`--style apa`) and IEEE (`--style ieee`) reference lists.
- **Inter-Rater Reliability & Statistical Library (`ScholarPRISMAEngine`, `ScholarPluginSDK`)** ([`reports/m0-acceptance.txt`](reports/m0-acceptance.txt), `2026-11-14`): Library routines for nominal multiclass Cohen's $\kappa$, Brennan-Prediger PABAK, Gwet's $AC_1$, Fleiss' $\kappa$, DerSimonian-Laird random-effects synthesis, and Lanczos/Lentz $t$/$F$/$\chi^2$ distributions. On a 12-study 5-category dual-rater dataset, both `scholaros prisma-stats` and MCP `scholar_prisma_agreement` compute $\kappa = 0.7757$, matching exact closed-form hand calculation $83/107 \approx 0.775701$.
- **JSON-RPC 2.0 MCP Server (`scholaros mcp`)** ([`reports/m0-acceptance.txt`](reports/m0-acceptance.txt), `2026-11-14`, [`Scripts/acceptance/m1-acceptance.sh`](Scripts/acceptance/m1-acceptance.sh), `2026-11-16` & [`Scripts/acceptance/m2-acceptance.sh`](Scripts/acceptance/m2-acceptance.sh), `2026-11-17`): Stdio JSON-RPC 2.0 server returning `-32700` (`Parse error`) on malformed JSON and `-32601` (`Method not found`) on unknown methods; supports `--offline`, `--registry-replay <dir>`, `--no-cache`, and `--lang en|zh` across tool calls with shared process-wide rate limiting, matching CLI `verify-citations` entry for entry on all 480 benchmark entries and matching CLI `diagnostics <path> --json` byte for byte via `scholar_lsp_diagnostics` (`path`) across all 11 M2 benchmark manuscripts.
- **Bilingual Output (`--lang en|zh`)** ([`reports/m0-acceptance.txt`](reports/m0-acceptance.txt), `2026-11-14`): CLI diagnostics, citation audit notes, usage errors, desktop UI (`⇧⌘L`), and exported HTML reports ([`docs/demo-scholar-dossier.html`](docs/demo-scholar-dossier.html), explicitly labeled `[DEMO / 演示数据]`) support English and Simplified Chinese.

---

## Build & Run Verified Examples

[`Scripts/acceptance/readme-commands.sh`](Scripts/acceptance/readme-commands.sh) extracts the `bash` code blocks from this file and [`README.zh-CN.md`](README.zh-CN.md), fails if the two files carry different commands, and runs all offline/replay commands verbatim (including under `sandbox-exec` network denial). Baseline output is recorded in [`reports/readme-commands.txt`](reports/readme-commands.txt).

```bash
swift build
export PATH="$PWD/.build/debug:$PATH"

WORK="$(mktemp -d)"
cat > "$WORK/paper.tex" <<'EOF'
\documentclass{article}
\begin{document}
\section{Introduction}
\subsection{Problem Statement}
Prior work \cite{lecun2015deep} motivates this study.
\end{document}
EOF

cat > "$WORK/refs.bib" <<'EOF'
@article{lecun2015deep,
  author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
  title   = {Deep learning},
  journal = {Nature},
  year    = {2015},
  volume  = {521},
  pages   = {436--444},
  doi     = {10.1038/nature14539}
}
@article{wakefield1998retracted,
  author  = {Wakefield, A. J.},
  title   = {Ileal-lymphoid-nodular hyperplasia},
  journal = {The Lancet},
  year    = {1998},
  doi     = {10.1016/S0140-6736(97)11096-0}
}
EOF

# 1. Extract LaTeX section outline (English, then Chinese)
ScholarOS outline "$WORK/paper.tex" --lang en
ScholarOS outline "$WORK/paper.tex" --lang zh

# 2. Format BibTeX entries in APA 7th and IEEE styles
ScholarOS format-bib "$WORK/refs.bib" --style apa
ScholarOS format-bib "$WORK/refs.bib" --style ieee

# 3. Run diagnostics on paper.tex + refs.bib: recorded replay (exit 0), --offline (exit 3), and --no-verify (exit 0)
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --registry-replay Tests/Fixtures/registry --lang en
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --registry-replay Tests/Fixtures/registry --lang zh
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --offline --lang en || echo "expected_exit=$?"
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --no-verify --lang zh

# 4. Citation check & pre-insertion verification: --offline and recorded fixture replay (--registry-replay)
ScholarOS verify-citations "$WORK/refs.bib" --offline --lang en || echo "expected_exit=$?"
ScholarOS verify-citations "$WORK/refs.bib" --registry-replay Tests/Fixtures/registry --lang en || echo "expected_exit=$?"
ScholarOS cite lecun2015deep --bib "$WORK/refs.bib" --registry-replay Tests/Fixtures/registry

# 5. JSON-RPC 2.0 MCP initialize handshake over stdio (--offline)
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ScholarOS mcp --offline

# 6. Reproduce the heading count quoted above on the sample manuscript shipped in Fixtures/
ScholarOS outline Fixtures/sample-ieeetran-manuscript.tex | grep -c .
grep -c -E '\\(section|subsection)\*?\{' Fixtures/sample-ieeetran-manuscript.tex

rm -rf "$WORK"
```

### Scoped Module Tests

To run the M0, M1, or M2 acceptance suites offline (`Scripts/test.sh milestone 0`, `Scripts/test.sh milestone 1`, or `Scripts/test.sh milestone 2`), reports are written to a temporary directory and the working tree stays clean; add `--record` to refresh `reports/`. For a single module:

```bash
Scripts/test.sh scope ScholarBibAndCSL
```

---

## Current Limitations & Planned Work

- **Desktop GUI (`ScholarOS` with no subcommand)**: Launches an empty window (`0` manuscripts, `0` bibliography entries). It cannot yet open user `.tex`, `.bib`, or `.pdf` files and **only views built-in unverified sample data** when launched with `--demo` or when **Load Demo** is clicked (marked with a window-wide `DEMO` banner).
- **Static LaTeX & `\bibitem` Parsing Boundaries**: Manuscript analysis reads `.tex`, `.bib`, and `.bbl` statically without executing a TeX macro engine (citation keys or labels constructed dynamically via custom macros are not expanded), and free-text `thebibliography` / `.bbl` `\bibitem` metadata extraction is best-effort heuristic parsing.
- **Planned for M3–M5**:
  - **M3 (MCP Write Gate)**: Add CiteStudio-aligned `verify_citation`, `add_verified_bibtex`, and `check_manuscript` MCP tools enforcing pre-write verification.
  - **M4 & M5 (PDF Evidence Localization & CiteStudio Unification)**: Replace keyword/number matching with bounded passage retrieval and number-with-unit checks on two-column PDFs; expose engine libraries to CiteStudio and calibrate APA / IEEE against 15 manual examples each.
- **Frozen (unverified, paused until after M3)**: Citation graph analytics (force layout, PageRank, Louvain, Kleinberg bursts, main-path analysis), PRISMA screening UI, risk-of-bias and meta-analysis UI, Myers track-changes UI, submission archive bundler, Zotero SQLite bridge, Typst support, `JavaScriptCore` editorial plugins, persistent undo/redo, and test-only synthetic PDF generation.

---

## License

MIT License. Copyright (c) 2026 Xu (`zxu756`).
