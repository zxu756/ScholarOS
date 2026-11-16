# real_human: notes (run 2026-11-15 UTC)

## What was done
`fetch_human_bib.py` (stdlib only, `python3 -I`) did everything: OAI-PMH listing, seeded selection of candidates, download of source packages, `.bib` extraction (read in memory with `tarfile`, only members ending in `.bib`, regular files, no absolute or `..` names; nothing else extracted), entry parsing, 65/35 selection, outputs. Rerunning uses cached listing pages (`listing/`), cached outcomes (`state/outcomes.json`) and saved originals (`originals/`), so it makes no network requests (verified: 0 new requests on rerun after the tarballs were deleted).

## Listing
- `export.arxiv.org/oai2` answered 301 to `https://oaipmh.arxiv.org/oai` (logged); the script then uses `oaipmh.arxiv.org/oai` directly. `metadataPrefix=arXiv`, records carry `<license>`. `ListSets` was fetched once (`listing/ListSets.xml`); the 8 set specs (`cs`, `math`, `physics:astro-ph`, `physics:cond-mat`, `q-bio`, `stat`, `econ`, `eess`) all exist.
- Window `from=2024-03-04&until=2024-03-06` for all sets except econ: econ had 21 records / 3 CC BY 4.0, so it was widened to `2024-02-26..2024-03-15` (106 records, 29 CC BY 4.0). OAI from/until filter on the record datestamp, not the submission date, so some papers have older ids (e.g. 2201.02191); the e-print served is the latest version.
- Kept only `<license>` exactly `http://creativecommons.org/licenses/by/4.0/`.
- Cross-listed papers appear in several sets; each is assigned to one field only, in the order econ, q-bio, eess, astro-ph, cond-mat, stat, math, cs (small sets first so they are not emptied). This ordering is my choice, not in the brief.

| field | records | CC BY 4.0 | after cross-list dedupe |
|---|---|---|---|
| cs | 1466 | 543 | 391 |
| math | 715 | 238 | 207 |
| physics:astro-ph | 252 | 106 | 105 |
| physics:cond-mat | 272 | 132 | 131 |
| q-bio | 61 | 29 | 29 |
| stat | 135 | 48 | 42 |
| econ (widened) | 106 | 29 | 29 |
| eess | 197 | 73 | 72 |

## Candidates and papers
Per field: sorted by id, shuffled with `random.Random(20261116)`, walked until 3 accepted. All 8 fields reached 3 accepted papers: 24 papers, 46 candidates tried (outcomes in `candidates.tsv`: 24 accepted, 13 no .bib, 1 template files only, 4 not a tarball, 2 too few entries, 2 too large). Largest accepted `.bib` taken per paper. `index_of_paper` for the per-paper shuffle `random.Random(20261116 + index)` is the 0-based position in `papers.tsv`. Version in `papers.tsv` comes from the `Content-Disposition` filename.

## Selection (revised 2026-11-15, second pass)
Round-robin over the 24 papers in `papers.tsv` order, quotas 65 with `doi` / 35 without, at most 8 per paper (max reached: 5), duplicates by DOI or normalized title skipped (none found). No exclusion list is used by default (`--dropped <file>` is optional). Final: 100 entries, **65 with doi / 35 without**, byte-identical to the originals except the citation key (CR bytes untouched). 8 entries come from CRLF files (5 from 2202.11758 `TSPT.bib`, 3 from 2401.12885 `Bib_up2date.bib`); per-paper shuffles use the 0-based index in `papers.tsv`, which shifted because the replaced paper moved.

## Template rule
`.bib` files are ignored when their basename (case-insensitive) is IEEEexample/IEEEabrv/IEEEfull/IEEEbcpat/sample/sample-base/example/template `.bib`, or when their SHA-256 equals a `.bib` seen in an earlier candidate package. Hash dedupe only covers packages processed in this walk or recorded in `state/outcomes.json` (earlier "rejected" outcomes stored no hashes). 2403.01110 (only IEEEexample.bib usable) now reads `no usable .bib (template files only)` in `candidates.tsv`; the cs walk continued in the same seeded order and accepted 2310.15516 (`paper.bib`, 40 usable entries) as third cs paper. The other 23 accepted `.bib` files were looked at once (names, first keys, no repeated hashes): none looks like a template sample file. Caveat: 2403.00256 `export.bib` and 2403.02765 `ref.bib` are generic names but contain real citation keys of the authors' fields.

## Parse check (second pass)
`dropped.tsv` was renamed `dropped.product-crlf.tsv` (record of the first pass: the product rejects CRLF entries). The new file was checked once as before (offline, sandboxed, temp HOME): exit code 2, `[ERR_BIB_SYNTAX] BibTeX parse error at line 71: Expected field name or '}' inside @ARTICLE{real_human_008}.` Expected because of the CRLF entries; nothing dropped or edited. See `parse-check.json` / `parse-check.err`.

## Deviations / things to know
- The first pass had one unlogged `curl -I` (redirect check). The second pass added 4 logged requests (re-download of 2403.01110, download of 2310.15516, each with a 301 hop). Totals now: 106 logged requests, about 98 MB. Tarballs deleted.
- Entry parsing is my own tolerant reader; usable counts may differ from another parser. Only the paper licence was checked.
- Extra files: `state/`, `run_stats.json`, `dropped.product-crlf.tsv`.
