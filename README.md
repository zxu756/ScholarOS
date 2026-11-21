# ScholarOS

**English** | **[简体中文](README.zh-CN.md)**

macOS Swift package (`1.4.0`) and bilingual (`--lang en|zh`) command-line tool (`scholaros`) for online citation verification against public scholarly registries, local two-column PDF passage localization and explicit number checking, LaTeX/BibTeX parsing, APA 7th / IEEE reference formatting, statistical agreement/meta-analysis library routines, and a stdio JSON-RPC 2.0 MCP server.

> **Fabricated references do not enter your `.bib`.** On a 480-entry mixed benchmark of real, fabricated, mutated, and retracted references, **0** fabricated entries are judged verified (`0/80` in `fabricated_model`; `0/86` across all `truth=fabricated` entries; `0/254` across all non-insertable entries), and the rate at which genuine references in the three real groups are falsely judged non-existent or retracted (`NOT_FOUND` or `RETRACTED`) is **0% (`0/215`)** (`0/220` across all 220 entries of the three real groups; `0/225` across all `truth=real` entries in the benchmark).

> **Current Status (M0, M1, M2, M3 MCP write gate & M4 PDF evidence localization verified):** M0, M1, M2, M3, and M4 checks pass as verified by [`Scripts/acceptance/m0-acceptance.sh`](Scripts/acceptance/m0-acceptance.sh), [`Scripts/acceptance/m1-acceptance.sh`](Scripts/acceptance/m1-acceptance.sh), [`Scripts/acceptance/m2-acceptance.sh`](Scripts/acceptance/m2-acceptance.sh), [`Scripts/acceptance/hard-inputs.sh`](Scripts/acceptance/hard-inputs.sh), [`Scripts/acceptance/m3-mcp.sh`](Scripts/acceptance/m3-mcp.sh) (Rows 1–17, 19, 20), [`Scripts/acceptance/m3-clients.sh`](Scripts/acceptance/m3-clients.sh) (Row 18 isolated client registration), and [`Scripts/acceptance/m4-acceptance.sh`](Scripts/acceptance/m4-acceptance.sh) (Rows 1–9, 11; live registry rows M1 Row 19 & Row 23 require `SCHOLAR_ONLINE=1`, M2 Row 17 / M3 Row 21 / M4 Row 10 source-mutation cloning runs via [`Scripts/acceptance/m2-mutations.sh`](Scripts/acceptance/m2-mutations.sh), [`Scripts/acceptance/m3-mutations.sh`](Scripts/acceptance/m3-mutations.sh), and [`Scripts/acceptance/m4-mutations.sh`](Scripts/acceptance/m4-mutations.sh), and M2 Row 19 Tectonic regeneration runs via [`Scripts/acceptance/m2-regen-expected.sh`](Scripts/acceptance/m2-regen-expected.sh) `--check` — otherwise those rows print `SKIP (没跑)`). `scholaros verify-citations`, MCP `verify_citation`, MCP `add_verified_bibtex`, MCP `scholar_verify_bibliography`, `scholaros diagnostics`, MCP `check_manuscript`, and `scholaros cite` share the same citation verification pipeline against public registries online by default with SQLite caching, rate limiting, and retry backoff (`add_verified_bibtex` bypasses cache reads on write so unverified or offline entries never enter `.bib`); `--offline` sends zero network requests, `--registry-replay <dir>` replays SHA-256-verified recorded fixtures offline (`REPLAY`, startup flag only), `--no-verify` runs structure/lint diagnostics without citation verification, `.bib` `x-firewall-class`/`x-firewall-note` declarations are ignored, and cached/stored verdicts expire after 30 days (1 day for `NOT_FOUND`). `scholaros locate-evidence`, `scholaros segment-pdf`, and MCP `locate_evidence` segment local two-column PDFs via `PDFKit` and check explicit numbers and units offline without network access. On the 11 CC BY 4.0 arXiv manuscripts in [`Benchmarks/manuscripts/`](Benchmarks/manuscripts/), static multi-file loading, verbatim/URL/conditional skipping, BibTeX error recovery, and `thebibliography`/`.bbl` extraction match the committed Tectonic 0.17 `.aux`/`.blg` expectations without performing TeX macro expansion. The macOS desktop window starts empty and **only displays sample data** when `--demo` or **Load Demo** is explicitly selected (`DEMO` banner).

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

## Evidence Localization (`2026-11-21`)

Given a local PDF and a claim sentence, ScholarOS segments two-column layouts, retrieves lexically matching passages with page coordinates, and compares explicit numbers and units:

- **Commands & MCP tool:**
  - `scholaros locate-evidence <pdf> --claim <text> --json` (also supports `--top-k <N>`, `--offline`, and `--lang en|zh`)
  - `scholaros segment-pdf <pdf> --json` (also supports `--offline` and `--lang en|zh`; emits `schema: "scholaros.pdf_segments/1"` chunks)
  - MCP tool `locate_evidence` (`pdf_file`, `claim`, optional `top_k`), sharing the exact same retrieval and number-checking implementation and returning byte-for-byte identical `scholaros.evidence/1` JSON.
- **Verdicts & exit codes:**
  - `FOUND` (exit code `0`): Lexically matching passage found above the keyword-coverage threshold with no conflicting explicit numbers or units.
  - `NUMERIC_MISMATCH` (exit code `1`): Lexically matching passage found, but explicit numbers or units in the claim conflict with those in the PDF passage (`discrepancies` lists `claim_text`, `pdf_text`, and `reason`).
  - `NOT_FOUND` (exit code `3`): No passage meets the keyword-coverage threshold (`matches` is empty).
  - Error (exit code `2`): Missing file, non-PDF bytes, unreadable/textless PDF, empty claim, or invalid arguments (`stdout` is empty under `--json`, and `stderr` explains the error; `segment-pdf` exits `0` on success and `2` on error).
- **Output fields (`scholaros.evidence/1`):** When a passage is located (`FOUND` or `NUMERIC_MISMATCH`), the top-level JSON and each entry in `matches` include 1-based physical `page`, 0-based `page_index`, `bounding_box` (`{x, y, width, height}` in PDF `mediaBox` points with origin at bottom-left), `column_index` (`1` left column, `2` right column, `0` full-width spanning block), `section_title`, and `excerpt`.

### Evidence Localization Boundaries

- **Only locates lexically similar passages and checks explicit numbers; it does not judge whether the source text supports your conclusion.** Statements without conflicting explicit numbers (for example, adding or removing a negation when no numbers are present) are not semantically adjudicated.
- **Same-language only:** Retrieval matches content words in the same language; querying an English PDF with a Chinese claim returns `NOT_FOUND` (exit code `3`).
- **Text comes from macOS `PDFKit`:** Scanned PDFs and PDFs without an embedded text layer are not supported (they exit with code `2` and an error message; no OCR is performed).
- **Spacing artifacts near certain LaTeX fonts and inline math:** Near certain LaTeX fonts and inline mathematical expressions, extraction occasionally splits one word into two fragments or glues two adjacent words together (tight justified word-space recovery and Latin Modern math-italic spacing were addressed in M4 stages 4b and 4c, with isolated residual cases remaining).

### Benchmark Metrics (`reports/m4-acceptance.txt`)

- **Date & commit:** `2026-11-21T14:18:20Z`, commit `1c7203d`, all numbers below taken from [`reports/m4-acceptance.txt`](reports/m4-acceptance.txt) (`--offline`, isolated `HOME`, `SCHOLAR_CACHE_DIR` unset).
- **Method:** `5` official two-column CC BY 4.0 arXiv PDFs (`2506.06524v1`, `2409.19431v3`, `2410.04196v2`, `2611.15445v1`, `2610.15486v1`; per-paper licence and SHA-256 attributions in [`Benchmarks/evidence/`](Benchmarks/evidence/)), evaluated on `30` claims (`10` grounded, `10` numeric-mismatch, `10` not-mentioned) plus `15` English/Chinese sentinel rows (`45` rows total in [`Benchmarks/evidence/claims.jsonl`](Benchmarks/evidence/claims.jsonl)) written by the conductor, spot-checked and frozen by the user, and never modified by the implementer.

| Check / Metric | Result | Requirement / Notes |
|---|---|---|
| **Grounded claims (`FOUND` on `expected_pages`)** | **`10/10`** | Hard requirement `>= 8/10`: Passed (Row 2). |
| **Numeric-mismatch claims (`NUMERIC_MISMATCH` on `expected_pages` with ground-truth number in `pdf_text`)** | **`9/10`** | Hard requirement `>= 8/10`: Passed (Row 3; `ev_004` returned `NUMERIC_MISMATCH` on page `2` instead of expected page `3`). |
| **Not-mentioned (`10`) + sentinel (`15`) rows returning `NOT_FOUND` (`matches == []`)** | **`25/25`** | Hard requirement `25/25` (`0` tolerance): Passed (`10/10` not-mentioned, `15/15` sentinels; Row 4). |
| **Bounding-box geometric verification (`+4.0pt` expansion vs. `pdftotext -tsv`)** | **`19/19` boxes verified** | Hard requirement `>= 80.0%` word coverage: Passed (`min_word_coverage = 100.0%`, Poppler `pdftotext` `26.10.0`, `0/5` stored-vs-live diffs; Row 5). |
| **Two-column PDF segmentation (0 header/footer body leaks, Intro + Refs recognized, `col1 < col2`)** | **`5/5` benchmark papers, `7/7` synthetic fixtures** | Hard requirement: Passed (`5/5` benchmark papers and `7/7` synthetic fixtures; Row 6). |
| **Word overlap vs. `pdftotext` across 5 benchmark papers** | **Min `96.87%` (`5/5` passed)** | Hard requirement `>= 95.00%` per paper: Passed (Row 7; per-paper breakdown below). |
| **CLI `locate-evidence --json` vs. MCP `locate_evidence` parity across 45 rows** | **`0/45` differences** | Hard requirement `0` differences: Passed (`default_tools = 5`, `ERR_INVALID_ARGUMENT` verified; Row 8). |
| **Error handling (missing file, non-PDF bytes, blank PDF, empty claim)** | **`9/9` passed** | All exit `2` with empty `--json` `stdout` and non-empty `stderr` (Row 9). |

**Per-paper word overlap and segmentation time** (timings in milliseconds from [`reports/m4-acceptance.txt`](reports/m4-acceptance.txt), measured on the conductor's machine while other builds were running concurrently):

| Paper (`Benchmarks/evidence/pdfs/`) | Template | Chunks / Headings | Word Overlap vs. `pdftotext` | Segmentation Time (`ms`) |
|---|---|---:|---:|---:|
| `2506.06524v1` | IEEEtran conference | `68` / `8` | **`99.91%`** (`3293/3296`) | **`333.3ms`** |
| `2409.19431v3` | ICML 2025 | `938` / `18` | **`97.69%`** (`20279/20759`) | **`2137.8ms`** |
| `2410.04196v2` | ICML 2025 | `337` / `11` | **`96.87%`** (`10333/10667`) | **`1083.7ms`** |
| `2611.15445v1` | acmart sigconf | `202` / `18` | **`98.67%`** (`6814/6906`) | **`822.0ms`** |
| `2610.15486v1` | Elsevier cas-dc | `366` / `36` | **`98.55%`** (`15163/15386`) | **`2030.8ms`** |
| **Minimum / Summary** | **`5` two-column papers** | — | **Min `96.87%` (`5/5 >= 95.00%`)** | — |

### How to Reproduce Evidence Localization Metrics

Run the offline M4 acceptance script on a clean clone to reproduce all numbers above:

```bash
Scripts/acceptance/m4-acceptance.sh
```

---

## Verified Capabilities (`2026-11-14` M0, `2026-11-16` M1, `2026-11-17` M2, `2026-11-21` M3 & `2026-11-21` M4)

M4 PDF evidence localization and two-column segmentation checks come from [`reports/m4-acceptance.txt`](reports/m4-acceptance.txt) and [`Scripts/acceptance/m4-acceptance.sh`](Scripts/acceptance/m4-acceptance.sh) (`2026-11-21`, commit `1c7203d`, `--offline`); M3 MCP write gate, tool surface, and isolated client registration checks come from [`Scripts/acceptance/m3-mcp.sh`](Scripts/acceptance/m3-mcp.sh) and [`Scripts/acceptance/m3-clients.sh`](Scripts/acceptance/m3-clients.sh) (`2026-11-21`, macOS arm64, replayed against [`Benchmarks/citations/recordings/`](Benchmarks/citations/recordings)); M2 manuscript-level checks come from [`Scripts/acceptance/m2-acceptance.sh`](Scripts/acceptance/m2-acceptance.sh) and [`Benchmarks/manuscripts/`](Benchmarks/manuscripts/) (`2026-11-17`); M1 citation verification metrics and acceptance checks come from [`reports/citation-bench-2026-11-16-live.json`](reports/citation-bench-2026-11-16-live.json) (`2026-11-16`) and [`Scripts/acceptance/m1-acceptance.sh`](Scripts/acceptance/m1-acceptance.sh); M0 parsing, formatting, statistical, MCP protocol, and CLI baseline numbers come from [`reports/m0-acceptance.txt`](reports/m0-acceptance.txt) and [`reports/readme-commands.txt`](reports/readme-commands.txt) (`2026-11-14`, macOS arm64, `Scripts/test.sh milestone 0`; without `--record`, reports go to a temporary directory and leave `reports/` untouched).

- **Citation Verification (`scholaros verify-citations`, `scholaros cite`, `scholaros cache clear`, MCP `verify_citation`, MCP `add_verified_bibtex`, MCP `scholar_verify_bibliography`)** ([`reports/citation-bench-2026-11-16-live.json`](reports/citation-bench-2026-11-16-live.json), `2026-11-16`): Classifies entries into 5 states (`VERIFIED`, `DRIFT`, `NOT_FOUND`, `RETRACTED`, `UNVERIFIED`) with `--lang en`, `--lang zh`, and `--json` output:
  - Queries Crossref, OpenAlex, `doi.org`, arXiv, and PubMed online by default and caches valid responses in SQLite (`~/Library/Caches/ScholarOS/registry.sqlite`, or `$SCHOLAR_CACHE_DIR/registry.sqlite`; 30-day TTL for valid `200` records, 1-day TTL for confirmed non-existence); `--no-cache` skips reading and writing the cache for one run, `scholaros cache clear` removes `registry.sqlite` (`-wal`/`-shm`), and `--verbose` logs one line per lookup to `stderr` (source, URL, status, elapsed time, and origin).
  - `--offline` sends zero network requests and neither reads nor writes the cache, checking identifier syntax and the incomplete 8-DOI built-in retraction hint list only (`built-in list, incomplete`; `内置名单，不完整` under `--lang zh`); unqueried valid identifiers are reported as `UNVERIFIED`.
  - `--registry-record <dir>` queries live registries (using the cache unless `--no-cache` is passed) and writes raw response bytes, per-item metadata, and a SHA-256 `manifest.json` into `<dir>`, reusing URLs already recorded in `<dir>`; `--registry-record-limit <N>` (positive integer, default `80`, valid only with `--registry-record`) caps the number of new HTTP requests sent in that run.
  - `--registry-replay <dir>` replays SHA-256-verified recorded responses without network access (reading/writing the cache only when `SCHOLAR_CACHE_DIR` is explicitly set, never the default cache directory) and marks output with `REPLAY`.
  - Syntactically malformed identifiers are reported as `NOT_FOUND` (`invalid_identifier`); sentinel prefixes (`10.0000/`, `10.1234/`, `10.9999/`, etc.) have valid ISO 26324 syntax and require registry lookup rather than offline rejection. Embedded `.bib` `x-firewall-class` / `x-firewall-note` fields are ignored and omitted on export.
  - Exit codes: `0` when all entries are `VERIFIED`; `1` when any entry is `DRIFT`, `NOT_FOUND`, `RETRACTED`, or a partial BibTeX `parse_error`; `3` when none of those occur and at least one entry is `UNVERIFIED`; `2` on usage, missing-file, zero-valid-entry BibTeX parse, or replay errors.
- **MCP Write Gate (`add_verified_bibtex`, `verify_citation`, `check_manuscript`, `scholar_verify_bibliography`)** ([`Scripts/acceptance/m3-mcp.sh`](Scripts/acceptance/m3-mcp.sh) & [`Scripts/acceptance/m3-clients.sh`](Scripts/acceptance/m3-clients.sh), `2026-11-21`): Enforces pre-write verification at the MCP layer so agents can append only registry-verified entries to `.bib` files:
  - Across all `480/480` benchmark entries replayed against [`Benchmarks/citations/recordings/`](Benchmarks/citations/recordings), `verify_citation` matches CLI `scholaros verify-citations --registry-replay --json` with **`0` differences** (`m3-mcp.sh` Row 11).
  - `add_verified_bibtex` re-verifies each single BibTeX entry in-process **without reading the SQLite cache** (rejecting writes under `--offline`, `offline: true`, or network denial even when a warm cache exists), rejects `NOT_FOUND`, `DRIFT`, `UNVERIFIED`, and `RETRACTED` with `isError: true` (`ERR_UNVERIFIED_CITATION`) without modifying the `.bib` file, enforces `4`-rule deduplication (`SKIPPED_DUPLICATE` vs. `ERR_CITE_KEY_CONFLICT`) and `8` path/encoding/syntax safety checks (`ERR_BIB_PATH`, `ERR_BIB_ENCODING`, `ERR_BIB_SYNTAX`, CRLF preservation), and writes registry-authoritative fields under exclusive `flock` + `O_APPEND` + `fsync`; when **`2` simultaneous MCP server processes** each append **`20` distinct `VERIFIED` entries** to the same `.bib` file, all **`40/40` unique entries** are preserved with **`0` parse or duplicate errors** (`m3-mcp.sh` Rows 2–10, 13, 14).
  - Across all `11/11` benchmark manuscripts (`offline: true`), `check_manuscript` returns a compact summary (`1,794`–`8,704` bytes) matching CLI `diagnostics <path> --offline --json` `counts` on `11/11` manuscripts by default, and matches CLI `--json` (`33,929`–`296,414` bytes) **byte for byte** on `11/11` manuscripts when `detail: "full"` is passed (`m3-mcp.sh` Row 15).
- **PDF Evidence Localization & Two-Column Segmentation (`scholaros locate-evidence`, `scholaros segment-pdf`, MCP `locate_evidence`)** ([`reports/m4-acceptance.txt`](reports/m4-acceptance.txt), `2026-11-21`): Strips repeating margin headers/footers, detects section headings and spanning floats, orders two-column prose left-before-right (`96.87%`–`99.91%` word overlap vs. `pdftotext` across `5` benchmark papers), and checks explicit numbers and units (`10/10` grounded `FOUND` on `expected_pages`, `9/10` numeric-mismatch `NUMERIC_MISMATCH`, `25/25` not-mentioned + sentinels `NOT_FOUND`, `19/19` bounding boxes verified, `0/45` CLI vs. MCP JSON differences).
- **LaTeX Outline & Manuscript Diagnostics (`scholaros outline`, `scholaros diagnostics`, MCP `check_manuscript`)** ([`reports/m0-acceptance.txt`](reports/m0-acceptance.txt), `2026-11-14` & [`Scripts/acceptance/m2-acceptance.sh`](Scripts/acceptance/m2-acceptance.sh), `2026-11-17`): Lexes and parses LaTeX manuscripts directly from `.tex` files without creating a project bundle. On the 449-line IEEEtran-style sample manuscript [`Fixtures/sample-ieeetran-manuscript.tex`](Fixtures/sample-ieeetran-manuscript.tex) (fictional content written for this repository, so anyone can rerun the check), `scholaros outline` extracts all `46` `\section`/`\subsection` headings, numbered and starred, in both `--lang en` and `--lang zh`, matching `grep -c -E '\\(section|subsection)\*?\{'` (measured 2026-11-14).
  - Resolves multi-file graphs (`\input`, unbraced `\input`, `\include`, `\InputIfFileExists`, `\subfile`, `\import`, `\subimport`) with Windows-1252 fallback (`ENC001`), skips verbatim/code/URL/conditional spans losslessly (`\verb`, `verbatim`, `lstlisting`, `\lstinline`, `minted`, `\mintinline`, `comment`, `\iffalse...\fi`, `\url`, `\path`, `\nolinkurl`, `\href`), and extracts bibliography entries from `.bib`, `thebibliography`, `\input{*.bbl}`, and `<main>.bbl` fallback (`BIB_FROM_BBL`).
  - Separates diagnostics into `structure` (`SYM003`, `SYM004`, `CITE404`, `INC002`, `BIB001`, `CITE_KEY_CASE`, etc.), `citation` (at most one `ERR_UNVERIFIED_CITATION` per unique cited key: `ERROR` on `DRIFT`/`NOT_FOUND`/`RETRACTED`, `WARNING` with reason code on `UNVERIFIED`), and `lint` (`LINT_LABEL_BEFORE_CAPTION` `WARNING`; `LINT_UNCITED_BIB_ENTRY` and float hints `INFO`/`HINT`, suppressed under `\nocite{*}` and for `crossref` parents).
  - Text output prints non-citation diagnostics first, then a single-line citation verification summary (`Citation verification: N key(s), VERIFIED ..., UNVERIFIED ...` / `引用核查：N 个键，...`), followed by per-key `ERR_UNVERIFIED_CITATION` lines for non-`VERIFIED` keys; `--json` emits a deterministic `scholaros.diagnostics/1` object without timestamps or random IDs.
  - `--no-verify` runs structure and lint checks without invoking citation verification (printing `Citation verification: skipped (--no-verify; citations not verified, ...)` / `引用核查：未核查引用...`, exit codes `0`/`1`/`2` only). Standard `diagnostics` exit codes match `verify-citations`: `0` when `structure` `ERROR` count is `0` and all cited keys are `VERIFIED`; `1` on any `structure` `ERROR` or any `DRIFT`/`NOT_FOUND`/`RETRACTED` cited key; `3` when neither occurs and at least one cited key is `UNVERIFIED`; `2` on usage or missing-file errors.
- **BibTeX Parsing & APA 7th / IEEE Formatting (`scholaros format-bib`)** ([`reports/m0-acceptance.txt`](reports/m0-acceptance.txt), `2026-11-14`; CRLF support added in M1; recovery & field rules added in M2): Parses `.bib` files directly (LF, CRLF, or mixed line endings) with BibTeX 0.99d identifier character rules, single-entry error recovery (`BIB001`; exits `1` when remaining entries format cleanly, `2` when zero valid entries exist), `and others` author truncation (`authorsTruncated` without producing `"and et al."`), two-pass `crossref` inheritance (`BIB003`), and `\url`/`\href` extraction from `howpublished`/`note`, rendering APA 7th (`--style apa`) and IEEE (`--style ieee`) reference lists.
- **Inter-Rater Reliability & Statistical Library (`ScholarPRISMAEngine`, `ScholarPluginSDK`)** ([`reports/m0-acceptance.txt`](reports/m0-acceptance.txt), `2026-11-14`): Library routines for nominal multiclass Cohen's $\kappa$, Brennan-Prediger PABAK, Gwet's $AC_1$, Fleiss' $\kappa$, DerSimonian-Laird random-effects synthesis, and Lanczos/Lentz $t$/$F$/$\chi^2$ distributions. On a 12-study 5-category dual-rater dataset, both `scholaros prisma-stats` and MCP `scholar_prisma_agreement` (`--experimental-tools`) compute $\kappa = 0.7757$, matching exact closed-form hand calculation $83/107 \approx 0.775701$.
- **JSON-RPC 2.0 MCP Server (`scholaros mcp`)** ([`reports/m0-acceptance.txt`](reports/m0-acceptance.txt), `2026-11-14` & [`Scripts/acceptance/m3-mcp.sh`](Scripts/acceptance/m3-mcp.sh), `2026-11-21`): Stdio JSON-RPC 2.0 server (`protocolVersion: "2024-11-05"`, `ping` returning `{}`, `serverInfo.version` matching `scholaros version`) returning `-32700` (`Parse error`) on malformed JSON, `-32601` (`Method not found`) on unknown methods, and `-32602` (`Invalid params`) on unknown or unenabled tools; supports `--offline`, `--registry-replay <dir>`, `--no-cache`, `--experimental-tools`, and `--lang en|zh` with shared process-wide rate limiting.
- **Bilingual Output (`--lang en|zh`)** ([`reports/m0-acceptance.txt`](reports/m0-acceptance.txt), `2026-11-14`): CLI diagnostics, citation audit notes, usage errors, desktop UI (`⇧⌘L`), and exported HTML reports ([`docs/demo-scholar-dossier.html`](docs/demo-scholar-dossier.html), explicitly labeled `[DEMO / 演示数据]`) support English and Simplified Chinese.

---

## MCP Server & Client Registration

### Default Tools (`scholaros mcp`)

By default, `scholaros mcp` exposes **5** citation, manuscript, and PDF evidence tools (`verify_citation`, `add_verified_bibtex`, `check_manuscript`, `scholar_verify_bibliography`, `locate_evidence`; `snake_case` parameters; none accept `registryReplayPath`, `demo`, or `projectPath`, and any unknown or mistyped argument returns `isError: true` with `ERR_INVALID_ARGUMENT`; replay mode can only be enabled at server startup via `scholaros mcp --registry-replay <dir>`):

| Tool | Parameters (`*` = required) | Writes `.bib`? | Behavior |
|---|---|---|---|
| `verify_citation` | `bibtex*` (`string`), `offline` (`boolean`), `lang` (`string`) | No | Verifies **exactly 1** BibTeX entry online with SQLite caching by default (`0` or multiple entries return `ERR_INVALID_BIBTEX`); returns `{mode, cite_key, verdict, reasons, sources, fields, insertable, record, findings}` (`isError: false` for all 5 verdicts when lookup completes). |
| `add_verified_bibtex` | `bib_file*` (`string`), `bibtex*` (`string`), `offline` (`boolean`), `lang` (`string`) | Yes (`VERIFIED` only) | Re-verifies 1 BibTeX entry in-process **without reading the cache** and appends canonical registry-backed BibTeX to `bib_file` under `flock` + `O_APPEND` + `fsync` only when `verdict == "VERIFIED"` and `insertable == true`. Returns `APPENDED_VERIFIED` or `SKIPPED_DUPLICATE` (`isError: false`), or `isError: true` (`ERR_UNVERIFIED_CITATION`, `ERR_CITE_KEY_CONFLICT`, `ERR_BIB_PATH`, `ERR_BIB_ENCODING`, `ERR_BIB_SYNTAX`, `ERR_INVALID_BIBTEX`, `ERR_INVALID_ARGUMENT`, `ERR_IO`) leaving `bib_file` untouched. |
| `check_manuscript` | `path*` (`string`), `bib_file` (`string`), `no_verify` (`boolean`), `offline` (`boolean`), `detail` (`"summary"` \| `"full"`), `lang` (`string`) | No | Loads multi-file manuscripts from `path`, runs structure/cross-reference diagnostics, and **verifies cited bibliography entries online by default** (using the SQLite cache; pass `no_verify: true` for structure-only checks or `offline: true` for zero-network offline checks). Returns `isError: false` when diagnostics finish, or `isError: true` (`ERR_FILE_NOT_FOUND` when `path` or `bib_file` does not exist, `ERR_IO` when a directory or unreadable, `ERR_INVALID_ARGUMENT` on invalid arguments). |
| `scholar_verify_bibliography` | `bibtex*` (`string`), `offline` (`boolean`), `lang` (`string`) | No | Batch read-only verification of a BibTeX string (`0`, `1`, or multiple entries) sharing the same firewall, rate limiter, SQLite cache, and replay rules as `verify_citation`. |
| `locate_evidence` | `pdf_file*` (`string`), `claim*` (`string`), `top_k` (`integer`, default `3`, `>= 1`) | No | Segments local `pdf_file`, retrieves lexically similar passages, and checks explicit numbers and units offline; returns `scholaros.evidence/1` JSON (`FOUND`, `NUMERIC_MISMATCH`, or `NOT_FOUND`, `isError: false`) byte-for-byte identical to `scholaros locate-evidence <pdf> --claim <claim> --json`, or `isError: true` (`ERR_INVALID_ARGUMENT`, `ERR_FILE_NOT_FOUND`, `ERR_PDF_EXTRACTION`). |

- **`check_manuscript` output granularity & timeout:** By default (`detail` omitted or `"summary"`), `check_manuscript` returns a compact 6-field JSON object (`mode`, `root`, `complete`, `counts`, `structure_errors`, `non_verified_citations`) sized for MCP client token budgets; passing `detail: "full"` returns the full `scholaros.diagnostics/1` JSON object byte-for-byte identical to `scholaros diagnostics <path> --json`. Because `check_manuscript` queries public registries over the network by default (roughly 1–2 minutes on an uncached manuscript with dozens of cited keys), **Codex users may need to increase `tool_timeout_sec`** under `[mcp_servers.scholaros]`.
- **Experimental frozen tools (`--experimental-tools`):** Starting the server as `scholaros mcp --experimental-tools` additionally exposes 4 frozen domain tools (`scholar_prisma_agreement`, `scholar_editorial_audit`, `scholar_track_changes_diff`, `scholar_citation_gaps`). Without `--experimental-tools`, they are omitted from `tools/list` and return JSON-RPC `-32602` if called.

### Registering in MCP Clients

If a client cannot find `scholaros` on `PATH` (common in desktop GUI apps whose `PATH` omits Homebrew), replace `scholaros` with its absolute path — for example `/opt/homebrew/bin/scholaros` for Homebrew installs.

**Claude Code:**

```sh
claude mcp add --scope user scholaros -- scholaros mcp
```

**Codex (`~/.codex/config.toml`; increase `tool_timeout_sec` if running online `check_manuscript` on large uncached manuscripts):**

```toml
# ~/.codex/config.toml
[mcp_servers.scholaros]
command = "scholaros"
args = ["mcp"]
```

**OpenCode (project `opencode.json` or global `~/.config/opencode/opencode.json`):**

```json
{"mcp": {"servers": {"scholaros": {"type": "local", "command": ["scholaros", "mcp"]}}}}
```

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

# 5. JSON-RPC 2.0 MCP server over stdio: tools/list (--offline) and write gate + check_manuscript (--registry-replay)
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | scholaros mcp --offline
: > "$WORK/mcp-target.bib"
python3 -I - "$WORK/mcp-target.bib" "$WORK/paper.tex" > "$WORK/mcp-requests.jsonl" <<'PY'
import json, sys
bib_target, paper_tex = sys.argv[1], sys.argv[2]
retracted_bib = "@article{wakefield1998retracted, author={Wakefield, A. J.}, title={Ileal-lymphoid-nodular hyperplasia}, journal={The Lancet}, year={1998}, doi={10.1016/S0140-6736(97)11096-0}}"
verified_bib = "@article{lecun2015deep, author={LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey}, title={Deep learning}, journal={Nature}, year={2015}, volume={521}, pages={436--444}, doi={10.1038/nature14539}}"
for req in [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "verify_citation", "arguments": {"bibtex": verified_bib}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": bib_target, "bibtex": retracted_bib}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": bib_target, "bibtex": verified_bib}}},
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "check_manuscript", "arguments": {"path": paper_tex, "bib_file": bib_target}}},
]:
    print(json.dumps(req))
PY
scholaros mcp --registry-replay Tests/Fixtures/registry < "$WORK/mcp-requests.jsonl"

# 6. Reproduce the heading count quoted above on the sample manuscript shipped in Fixtures/
ScholarOS outline Fixtures/sample-ieeetran-manuscript.tex | grep -c .
grep -c -E '\\(section|subsection)\*?\{' Fixtures/sample-ieeetran-manuscript.tex

# 7. PDF evidence localization & two-column segmentation (--offline): FOUND (exit 0), NUMERIC_MISMATCH (exit 1), NOT_FOUND (exit 3), segment-pdf (exit 0), and MCP locate_evidence
ScholarOS locate-evidence Benchmarks/evidence/pdfs/2506.06524v1.pdf --claim "The language model in ScriptDoctor gets 10 total chances to output functional PuzzleScript code." --offline --json > "$WORK/ev-found.json"
rc=0; ScholarOS locate-evidence Benchmarks/evidence/pdfs/2506.06524v1.pdf --claim "For few-shot prompting, human-made games were sampled from a small dataset of 6,100 PuzzleScript games." --offline --json > "$WORK/ev-mismatch.json" || rc=$?; test "$rc" -eq 1
rc=0; ScholarOS locate-evidence Benchmarks/evidence/pdfs/2506.06524v1.pdf --claim "月亮是绿奶酪做的。" --offline --json > "$WORK/ev-notfound.json" || rc=$?; test "$rc" -eq 3
ScholarOS segment-pdf Benchmarks/evidence/pdfs/2506.06524v1.pdf --offline --json > "$WORK/segments.json"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"locate_evidence","arguments":{"pdf_file":"Benchmarks/evidence/pdfs/2506.06524v1.pdf","claim":"The language model in ScriptDoctor gets 10 total chances to output functional PuzzleScript code."}}}' | scholaros mcp --offline > "$WORK/ev-mcp.jsonl"
python3 -I - "$WORK/ev-found.json" "$WORK/ev-mismatch.json" "$WORK/ev-notfound.json" "$WORK/segments.json" "$WORK/ev-mcp.jsonl" <<'PY'
import json, sys
found, mm, nf, seg = [json.load(open(p, encoding="utf-8")) for p in sys.argv[1:5]]
mcp_lines = [json.loads(ln) for ln in open(sys.argv[5], encoding="utf-8") if ln.strip()]
mcp_ev = json.loads(mcp_lines[-1]["result"]["content"][0]["text"])
assert found["verdict"] == "FOUND" and found["page"] == 2 and found["page_index"] == 1
assert mm["verdict"] == "NUMERIC_MISMATCH" and mm["page"] == 2 and "610" in mm["discrepancies"][0]["pdf_text"]
assert nf["verdict"] == "NOT_FOUND" and nf["matches"] == []
assert seg["schema"] == "scholaros.pdf_segments/1" and seg["chunk_count"] == 68
assert mcp_ev == found
print("evidence_examples_verified=true")
PY

rm -rf "$WORK"
```

### Scoped Module Tests

To run the M0, M1, M2, M3, or M4 acceptance suites offline (`Scripts/test.sh milestone 0` through `Scripts/test.sh milestone 4`), reports are written to a temporary directory and the working tree stays clean; add `--record` to refresh `reports/`. For a single module:

```bash
Scripts/test.sh scope ScholarBibAndCSL
```

---

## Current Limitations & Planned Work

- **Desktop GUI (`ScholarOS` with no subcommand)**: Launches an empty window (`0` manuscripts, `0` bibliography entries). It cannot yet open user `.tex`, `.bib`, or `.pdf` files and **only views built-in unverified sample data** when launched with `--demo` or when **Load Demo** is clicked (marked with a window-wide `DEMO` banner).
- **Static LaTeX & `\bibitem` Parsing Boundaries**: Manuscript analysis reads `.tex`, `.bib`, and `.bbl` statically without executing a TeX macro engine (citation keys or labels constructed dynamically via custom macros are not expanded), and free-text `thebibliography` / `.bbl` `\bibitem` metadata extraction is best-effort heuristic parsing.
- **Planned for M5**:
  - **M5 (CiteStudio Unification)**: Expose `ScholarModels`, `ScholarMarkupAST`, `ScholarBibAndCSL`, and `ScholarPDFProvenance` as library products for CiteStudio, consolidate the duplicate MCP servers, and calibrate APA 7th / IEEE formatting against 15 manual examples each.
- **Frozen (unverified, gated behind `--experimental-tools` on MCP)**: Citation graph analytics (force layout, PageRank, Louvain, Kleinberg bursts, main-path analysis), PRISMA screening UI, risk-of-bias and meta-analysis UI, Myers track-changes UI, submission archive bundler, Zotero SQLite bridge, Typst support, `JavaScriptCore` editorial plugins, persistent undo/redo, and test-only synthetic PDF generation.

---

## License

MIT License. Copyright (c) 2026 Xu (`zxu756`).
