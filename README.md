# ScholarOS

**English** | **[简体中文](README.zh-CN.md)**

macOS Swift package and bilingual (`--lang en|zh`) command-line tool (`scholaros`) for LaTeX/BibTeX parsing, APA 7th / IEEE reference formatting, citation verification against public scholarly registries, statistical agreement/meta-analysis library routines, and a stdio JSON-RPC 2.0 MCP server.

> **Status (M1 in progress):** `scholaros verify-citations`, MCP `scholar_verify_bibliography`, `scholaros diagnostics`, `scholaros cite`, and MCP `scholar_cite_key` share the same citation verification pipeline against public registries online by default (Crossref, OpenAlex, `doi.org`, arXiv, PubMed) with SQLite response caching, rate limiting, and retry backoff; `--offline` sends zero network requests, `--registry-replay <dir>` replays SHA-256-verified recorded fixtures offline (`REPLAY`), `--registry-record <dir>` (`--registry-record-limit <N>`) records live responses, `--no-cache` skips reading/writing the cache, `.bib` `x-firewall-class`/`x-firewall-note` declarations are ignored, and written-back verdicts expire after 30 days (1 day for `NOT_FOUND`). Full recording of the 480-entry benchmark (`Benchmarks/citations/`) and live benchmark metric generation remain in progress for M1. The macOS desktop window starts empty and currently **only displays sample data** when `--demo` or **Load Demo** is explicitly selected.

---

## Verified Capabilities (2026-11-14)

All numbers below come from [`reports/m0-acceptance.txt`](reports/m0-acceptance.txt) and [`reports/readme-commands.txt`](reports/readme-commands.txt), measured on 2026-11-14 on macOS arm64 (`Scripts/test.sh milestone 0 --record`; without `--record` the same checks run and the reports go to a temporary directory).

- **LaTeX Outline & Workspace Diagnostics (`scholaros outline`, `scholaros diagnostics`)**: Lexes and parses LaTeX manuscripts directly from `.tex` files without creating a project bundle. On the 449-line IEEEtran-style sample manuscript [`Fixtures/sample-ieeetran-manuscript.tex`](Fixtures/sample-ieeetran-manuscript.tex) (fictional content written for this repository, so anyone can rerun the check), `scholaros outline` extracts all `46` `\section`/`\subsection` headings, numbered and starred, in both `--lang en` and `--lang zh`, matching `grep -c -E '\\(section|subsection)\*?\{'` (measured 2026-11-14).
- **BibTeX Parsing & APA 7th / IEEE Formatting (`scholaros format-bib`)**: Parses `.bib` files directly and renders formatted reference lists in APA 7th (`--style apa`) and IEEE (`--style ieee`) styles, handling LaTeX diacritics and case-protected braces.
- **Citation Verification (`scholaros verify-citations`, `scholaros cache clear`)**: Classifies entries into 5 states (`VERIFIED`, `DRIFT`, `NOT_FOUND`, `RETRACTED`, `UNVERIFIED`) with `--lang en`, `--lang zh`, and `--json` output:
  - Queries Crossref, OpenAlex, `doi.org`, arXiv, and PubMed online by default and caches valid responses in SQLite (`~/Library/Caches/ScholarOS/registry.sqlite`, or `$SCHOLAR_CACHE_DIR/registry.sqlite`); `--no-cache` skips reading and writing the cache for one run, `scholaros cache clear` removes `registry.sqlite` (`-wal`/`-shm`), and `--verbose` logs one line per lookup to `stderr` (source, URL, status, elapsed time, and origin).
  - `--offline` sends zero network requests and neither reads nor writes the cache, checking identifier syntax and the incomplete 8-DOI built-in retraction hint list only (`built-in list, incomplete`; `内置名单，不完整` under `--lang zh`); unqueried valid identifiers are reported as `UNVERIFIED`.
  - `--registry-record <dir>` queries live registries (using the cache unless `--no-cache` is passed) and writes raw response bytes, per-item metadata, and a SHA-256 `manifest.json` into `<dir>`, reusing URLs already recorded in `<dir>`; `--registry-record-limit <N>` (positive integer, default `80`, valid only with `--registry-record`) caps the number of new HTTP requests sent in that run.
  - `--registry-replay <dir>` replays SHA-256-verified recorded responses without network access (reading/writing the cache only when `SCHOLAR_CACHE_DIR` is explicitly set, never the default cache directory) and marks output with `REPLAY`.
  - Syntactically malformed identifiers are reported as `NOT_FOUND` (`invalid_identifier`); sentinel prefixes (`10.0000/`, `10.1234/`, `10.9999/`, etc.) have valid ISO 26324 syntax and require registry lookup rather than offline rejection.
  - Exit codes: `0` when all entries are `VERIFIED`; `1` when any entry is `DRIFT`, `NOT_FOUND`, or `RETRACTED`; `3` when none of those three occur and at least one entry is `UNVERIFIED`; `2` on usage, missing-file, BibTeX parse, or replay errors.
- **Inter-Rater Reliability & Statistical Library (`ScholarPRISMAEngine`, `ScholarPluginSDK`)**: Library routines for nominal multiclass Cohen's $\kappa$, Brennan-Prediger PABAK, Gwet's $AC_1$, Fleiss' $\kappa$, DerSimonian-Laird random-effects synthesis, and Lanczos/Lentz $t$/$F$/$\chi^2$ distributions. On a 12-study 5-category dual-rater dataset, both `scholaros prisma-stats` and MCP `scholar_prisma_agreement` compute $\kappa = 0.7757$, matching exact closed-form hand calculation $83/107 \approx 0.775701$ ([`reports/m0-acceptance.txt`](reports/m0-acceptance.txt), 2026-11-14).
- **JSON-RPC 2.0 MCP Server (`scholaros mcp`)**: Stdio JSON-RPC 2.0 server returning `-32700` (`Parse error`) on malformed JSON and `-32601` (`Method not found`) on unknown methods; supports `--offline`, `--registry-replay <dir>`, and `--no-cache` across tool calls with shared process-wide rate limiting.
- **Bilingual Output (`--lang en|zh`)**: CLI diagnostics, citation audit notes, usage errors, desktop UI (`⇧⌘L`), and exported HTML reports ([`docs/demo-scholar-dossier.html`](docs/demo-scholar-dossier.html), explicitly labeled `[DEMO / 演示数据]`) support English and Simplified Chinese.

---

## Build & Run Verified Examples

[`Scripts/acceptance/readme-commands.sh`](Scripts/acceptance/readme-commands.sh) extracts the code blocks below from this file (and the same blocks from [`README.zh-CN.md`](README.zh-CN.md)) and runs them verbatim from the repository root; it fails if the two files carry different commands. Output is recorded in [`reports/readme-commands.txt`](reports/readme-commands.txt).

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

# 3. Run diagnostics on paper.tex paired with refs.bib using recorded replay (English, then Chinese)
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --registry-replay Tests/Fixtures/registry --lang en
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --registry-replay Tests/Fixtures/registry --lang zh

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

To run the full M0 acceptance suite (scoped unit tests + `Scripts/acceptance/m0-acceptance.sh` + `Scripts/acceptance/readme-commands.sh`), run `Scripts/test.sh milestone 0`. It opens no window, leaves the working tree unchanged, and writes its reports to a temporary directory; add `--record` to refresh `reports/`. For a single module:

```bash
Scripts/test.sh scope ScholarBibAndCSL
```

---

## Current Limitations & Planned Work

- **Desktop GUI (`ScholarOS` with no subcommand)**: Launches an empty window (`0` manuscripts, `0` bibliography entries). It cannot yet open user `.tex`, `.bib`, or `.pdf` files and **only views built-in unverified sample data** when launched with `--demo` or when **Load Demo** is clicked (marked with a window-wide `DEMO` banner).
- **Remaining in M1 (Online Citation Verification)**: Finish recording registry fixtures across all 12 groups of the 480-entry labeled benchmark (`Benchmarks/citations/`) and run the live benchmark evaluation (`Scripts/acceptance/m1-citation-bench.py --live`) to populate headline metrics.
- **Planned for M2 (Parser, PDF & CiteStudio Alignment)**: Handle `\verb`, `verbatim`, `lstlisting`, `\url{%}`, and `\bibitem` in LaTeX; recover past malformed BibTeX entries; fix APA sentence-case and IEEE book formatting; improve two-column PDF section heading and cross-column table segmentation; expose CiteStudio-compatible MCP tool names.
- **Frozen (unverified, paused until after M3)**: Citation graph analytics (force layout, PageRank, Louvain, Kleinberg bursts, main-path analysis), PRISMA screening UI, risk-of-bias and meta-analysis UI, Myers track-changes UI, submission archive bundler, Zotero SQLite bridge, Typst support, `JavaScriptCore` editorial plugins, persistent undo/redo, and test-only synthetic PDF generation.

---

## License

MIT License. Copyright (c) 2026 Xu (`zxu756`).
