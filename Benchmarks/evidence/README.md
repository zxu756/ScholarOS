# Evidence-location benchmark (M4)

Fixed material for `scholaros locate-evidence` and the M4 acceptance script. Do not edit these files while working on the implementation; the acceptance script checks `git diff --exit-code Benchmarks/`.

## Papers

Five open-access two-column papers, one PDF each, downloaded on 2026-11-21 from `https://arxiv.org/pdf/<id>` and kept unmodified. Every paper is licensed CC BY 4.0 according to the licence field of its arXiv metadata record (checked in M2, see `Benchmarks/manuscripts/papers.tsv`); `pdfs/<id>.ATTRIBUTION.md` gives the title, authors, links, licence, SHA-256 and size.

| Paper | Template | Pages |
|---|---|---:|
| 2506.06524v1 ScriptDoctor | IEEEtran conference | 5 |
| 2409.19431v3 Tilted Empirical Risk | ICML 2025 | 43 |
| 2410.04196v2 Flat Hilbert Bayesian Inference | ICML 2025 | 20 |
| 2611.15445v1 ReAlign | acmart sigconf | 9 |
| 2610.15486v1 Lunar loco-manipulation | Elsevier cas-dc | 24 |

Selection: two-column layout, CC BY 4.0, experiments with numbers in running text, five different templates or venues where possible. 2212.14225v5 was considered and dropped because its source uses `onecolumn`.

## Claims (`claims.jsonl`)

Written by the conductor (not by the implementer) from `pdftotext` output of each page, spot-checked by the user and frozen on 2026-11-21. The implementer must not edit them. One JSON object per line:

| Field | Meaning |
|---|---|
| `id` | `ev_001` … `ev_045` |
| `paper_id` | arXiv id with version |
| `group` | `grounded`, `numeric_mismatch`, `not_mentioned` or `sentinel` |
| `claim` | the claim, in English except the Chinese sentinel |
| `expected_verdict` | `FOUND`, `NUMERIC_MISMATCH` or `NOT_FOUND` |
| `expected_pages` | 1-based physical PDF pages where the supporting passage is |
| `ground_truth_excerpt` | the passage, copied from `pdftotext` output of that page |
| `ground_truth_numbers` | the numbers as the paper writes them |
| `mutated_numbers` | for `numeric_mismatch`, the numbers as the claim writes them |
| `mismatch_subtype` | `a_count` (integer with noun changed), `b_unit` (unit changed), `c_percent` (percentage inflated), `d_cross_noun` (number moved to another noun) |
| `note` | why the claim is built this way |

Per paper: 2 grounded, 2 numeric_mismatch, 2 not_mentioned (one from the same field, one unrelated), 30 in all. Grounded claims are paraphrased, never copied whole; one uses a unit conversion (0.04 s for 40 ms), one rounds (13.9% for 13.92%), two change only digit grouping (10,000 for 10000). Mismatch subtypes: 5 `a_count`, 2 `b_unit`, 1 `c_percent`, 2 `d_cross_noun`. Not-mentioned claims were checked to share less than 60% of their content words with any single page of their paper. Three sentinels run against every paper (15 rows): "The moon is made of green cheese.", the same with "in our analysis", and the Chinese "月亮是绿奶酪做的。" (also covers the same-language rule: a Chinese claim against an English PDF is NOT_FOUND).

## `pdftotext` reference (`expected_pdftotext/`)

`<id>.tsv.gz` is `pdftotext -tsv <pdf> -` (Poppler, version in `VERSION.txt`), gzip-compressed. The acceptance script uses it for the word-overlap and bounding-box rows on machines without Poppler, and regenerates and compares it when `pdftotext` is installed.

To regenerate: `pdftotext -tsv pdfs/<id>.pdf - | gzip -9 > expected_pdftotext/<id>.tsv.gz`.
