# ScholarOS

**English** | **[简体中文](README.zh-CN.md)**

macOS Swift package and bilingual (`--lang en|zh`) command-line tool (`scholaros`) for LaTeX/BibTeX parsing, APA 7th / IEEE reference formatting, offline citation structural checks, statistical agreement/meta-analysis library routines, and a stdio JSON-RPC 2.0 MCP server.

> **Status (M0, 2026-11-14):** Online registry lookup (Crossref, OpenAlex, arXiv, PubMed) is **not yet wired** to the CLI or MCP entry points (scheduled for M1). In M0, `scholaros verify-citations` performs offline identifier syntax validation and checks an incomplete 8-DOI built-in retraction hint list; it **never** marks unqueried entries `VERIFIED` and exits with code `1` whenever any entry is not `VERIFIED`. The macOS desktop window starts empty and currently **only displays sample data** when `--demo` or **Load Demo** is explicitly selected.

---

## Verified Capabilities (2026-11-14)

All numbers below come from [`reports/m0-acceptance.txt`](reports/m0-acceptance.txt) and [`reports/readme-commands.txt`](reports/readme-commands.txt), measured on 2026-11-14 on macOS arm64 (`Scripts/test.sh milestone 0`).

- **LaTeX Outline & Workspace Diagnostics (`scholaros outline`, `scholaros diagnostics`)**: Lexes and parses LaTeX manuscripts directly from `.tex` files without creating a project bundle. On a 759-line IEEEtran manuscript, `scholaros outline` extracts all `40` `\section`/`\subsection` headings in both `--lang en` and `--lang zh`, matching `grep -c -E '\\(section|subsection)\*?\{'` (`40`; measured 2026-11-14).
- **BibTeX Parsing & APA 7th / IEEE Formatting (`scholaros format-bib`)**: Parses `.bib` files directly and renders formatted reference lists in APA 7th (`--style apa`) and IEEE (`--style ieee`) styles, handling LaTeX diacritics and case-protected braces.
- **Offline Citation Syntax & Retraction Hint Check (`scholaros verify-citations`)**: Classifies entries into 5 states (`VERIFIED`, `DRIFT`, `NOT_FOUND`, `RETRACTED`, `UNVERIFIED`) with `--lang en` and `--lang zh` output:
  - Offline checks (`verify-citations <refs.bib> [--offline]`) report syntactically valid DOIs, arXiv IDs, and PMIDs as `UNVERIFIED` (not checked against external registries).
  - Malformed identifiers or placeholder prefixes (`10.0000/`, `10.1000/`, `10.1234/`, `10.9999/`) are reported as `NOT_FOUND`.
  - Entries matching the 8-DOI built-in retraction list are reported as `RETRACTED` with an explicit incomplete-list notice (`内置名单，不完整`).
  - Exits with code `1` whenever any entry is not `VERIFIED`.
- **Inter-Rater Reliability & Statistical Library (`ScholarPRISMAEngine`, `ScholarPluginSDK`)**: Library routines for nominal multiclass Cohen's $\kappa$, Brennan-Prediger PABAK, Gwet's $AC_1$, Fleiss' $\kappa$, DerSimonian-Laird random-effects synthesis, and Lanczos/Lentz $t$/$F$/$\chi^2$ distributions. On a 12-study 5-category dual-rater dataset, both `scholaros prisma-stats` and MCP `scholar_prisma_agreement` compute $\kappa = 0.7757$, matching exact closed-form hand calculation $83/107 \approx 0.775701$ ([`reports/m0-acceptance.txt`](reports/m0-acceptance.txt), 2026-11-14).
- **JSON-RPC 2.0 MCP Server (`scholaros mcp`)**: Stdio JSON-RPC 2.0 server returning `-32700` (`Parse error`) on malformed JSON and `-32601` (`Method not found`) on unknown methods.
- **Bilingual Output (`--lang en|zh`)**: CLI diagnostics, citation audit notes, usage errors, desktop UI (`⇧⌘L`), and exported HTML reports ([`docs/demo-scholar-dossier.html`](docs/demo-scholar-dossier.html), explicitly labeled `[DEMO / 演示数据]`) support English and Simplified Chinese.

---

## Build & Run Verified Examples

Every command below is replayed verbatim by [`Scripts/acceptance/readme-commands.sh`](Scripts/acceptance/readme-commands.sh), with output recorded in [`reports/readme-commands.txt`](reports/readme-commands.txt).

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

# 1. Extract LaTeX section outline (English & Chinese)
ScholarOS outline "$WORK/paper.tex" --lang en
ScholarOS outline "$WORK/paper.tex" --lang zh

# 2. Format BibTeX entries in APA 7th and IEEE styles
ScholarOS format-bib "$WORK/refs.bib" --style apa
ScholarOS format-bib "$WORK/refs.bib" --style ieee

# 3. Run diagnostics on paper.tex paired with refs.bib
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --lang en

# 4. Offline citation check (exits 1 because unqueried/retracted entries are not VERIFIED)
ScholarOS verify-citations "$WORK/refs.bib" --offline --lang en || echo "expected_exit=$?"
ScholarOS verify-citations "$WORK/refs.bib" --offline --lang zh || echo "expected_exit=$?"

# 5. JSON-RPC 2.0 MCP initialize handshake over stdio
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ScholarOS mcp

rm -rf "$WORK"
```

### Scoped Module Tests

To run the full M0 acceptance suite (scoped unit tests + `Scripts/acceptance/m0-acceptance.sh` + `Scripts/acceptance/readme-commands.sh`), run `Scripts/test.sh milestone 0`. For a single module:

```bash
Scripts/test.sh scope ScholarBibAndCSL
```

---

## Current Limitations & Planned Work

- **Desktop GUI (`ScholarOS` with no subcommand)**: Launches an empty window (`0` manuscripts, `0` bibliography entries). It cannot yet open user `.tex`, `.bib`, or `.pdf` files and **only views built-in unverified sample data** when launched with `--demo` or when **Load Demo** is clicked (marked with a window-wide `DEMO` banner).
- **Planned for M1 (Online Citation Verification)**: Wire Crossref, OpenAlex, arXiv, and PubMed queries into CLI and MCP; add title + first-author lookup for entries without DOIs; block metadata drift on title/year mismatches; add SQLite response caching and retry backoff; evaluate precision and false-rejection rates on a 460-entry labeled benchmark (`Benchmarks/citations/`).
- **Planned for M2 (Parser, PDF & CiteStudio Alignment)**: Handle `\verb`, `verbatim`, `lstlisting`, `\url{%}`, and `\bibitem` in LaTeX; recover past malformed BibTeX entries; fix APA sentence-case and IEEE book formatting; improve two-column PDF section heading and cross-column table segmentation; expose CiteStudio-compatible MCP tool names.
- **Frozen (unverified, paused until after M3)**: Citation graph analytics (force layout, PageRank, Louvain, Kleinberg bursts, main-path analysis), PRISMA screening UI, risk-of-bias and meta-analysis UI, Myers track-changes UI, submission archive bundler, Zotero SQLite bridge, Typst support, `JavaScriptCore` editorial plugins, persistent undo/redo, and test-only synthetic PDF generation.

---

## License

MIT License. Copyright (c) 2026 Xu (`zxu756`).
