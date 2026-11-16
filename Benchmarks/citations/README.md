# ScholarOS Citation Verification Benchmark (`Benchmarks/citations/`)

**中文摘要：** 本目录存放 ScholarOS 引用核查基准评测集（建立日期：2026-11-16），包含全部 **12 组共 480 条**真假与变异混合的 BibTeX 文献条目（`entries/*.bib` 与标准答案 `gold.jsonl`），以及于 **2026-11-16** 完整录制的公开书目注册库真实 HTTP 响应（`recordings/`，共 `748` 项，`recordings/manifest.json` 的 SHA-256 为 `81fd7b8e8a20c106fb186c170dedeb42541dc3b1f7d870e2afcd55fb333bbb7b`），用于对照 Crossref、OpenAlex、`doi.org`、arXiv 与 PubMed 检验引用核查能否拦下编造、元数据篡改及已撤稿的文献，同时避免将真实文献误判为不存在或已撤稿。完整评测结果见第 8 节与 [`reports/citation-bench-2026-11-16-live.json`](../../reports/citation-bench-2026-11-16-live.json)。

---

## 1. Purpose

This benchmark evaluates ScholarOS's 5-class citation verification pipeline (`VERIFIED`, `DRIFT`, `NOT_FOUND`, `RETRACTED`, `UNVERIFIED`) on realistic scholarly inputs rather than synthetic toy strings:

1. **Blocking non-insertable references:** Fabricated entries invented by language models (including entries whose invented identifiers happen to collide with unrelated real publications), real entries with corrupted metadata (wrong year, swapped first author, rewritten title, single-letter title typo, swapped DOI, or unregistered DOI), and retracted publications must not be cleared as `VERIFIED`.
2. **Preserving genuine references:** Clean journal articles from Crossref/OpenAlex, unaltered BibTeX entries written by human authors in real LaTeX manuscripts (including abbreviated journal names, LaTeX diacritics, missing DOIs, and CRLF line endings), and harmless formatting variations (`https://doi.org/` prefix, uppercase DOI, stripped surname accents, surrounding DOI whitespace) should be handled accurately without falsely reporting them as non-existent or retracted.
3. **Deterministic offline replay:** All 480 entries are recorded into `recordings/` (`748` unique canonical requests) so the entire corpus can be replayed offline with SHA-256 integrity checks (`--registry-replay Benchmarks/citations/recordings`) and re-verified live on demand.

- **Dataset created:** `2026-11-16`
- **Registry fixtures recorded:** `2026-11-16` (`748` items in `recordings/manifest.json`)
- **`recordings/manifest.json` SHA-256:** `81fd7b8e8a20c106fb186c170dedeb42541dc3b1f7d870e2afcd55fb333bbb7b`

---

## 2. Directory Layout

```text
Benchmarks/citations/
  README.md                 Dataset documentation, provenance, attribution, rebuild/recording guide, and results
  entries/<group>.bib       One BibTeX file per group (12 files, 480 entries total; keys prefixed by group)
  gold.jsonl                One JSON object per entry (480 lines): key, group, truth, expected, insertable, provenance, note
  sources/<group>/          Sampling manifests, raw registry responses (raw/<sha1>.json), logs, and review records
  recordings/               Recorded HTTP fixtures for ScholarOS --registry-replay (748 items + manifest.json)
  tools/                    Stdlib-only Python 3 build scripts, structural checker, and offline unit tests
```

---

## 3. Benchmark Groups (12 Groups, 480 Entries Total)

All 12 groups (480 entries) and their HTTP replay fixtures in `recordings/` are generated, checked in, and recorded as of **2026-11-16**.

| Group | Key Pattern | Count | `truth` | `expected` | `insertable` | Source & Builder | Status |
|---|---|---:|---|---|---|---|---|
| `audit_manual` | `audit_001`..`audit_030` | 30 | per entry (`10 real`, `6 fabricated`, `12 mutated`, `2 retracted`) | per entry | `true` (11) / `false` (19) | Handwritten edge-case audit suite (`Fixtures/citations-m0-recheck.bib` + near-title / surname-typo / wrong-venue / DataCite / untrusted-tag / arXiv / PubMed / CNKI cases); written 2026-11-16 | Checked in & recorded (2026-11-16) |
| `real_clean` | `real_clean_001`..`real_clean_100` | 100 | `real` | `["VERIFIED"]` | `true` | Stratified OpenAlex `sample` + `seed` (`20261116`) across 5 fields and 4 publication-year bands (`type:article,has_doi:true`), converted from Crossref `/works/<DOI>`; built by `tools/build_real_clean.py` | Checked in & recorded (2026-11-16) |
| `real_human` | `real_human_001`..`real_human_100` | 100 | `real` | `["VERIFIED", "DRIFT"]` | `true` | Byte-exact BibTeX entries (only citation key renamed) extracted from 24 CC BY 4.0 arXiv e-print source packages across 8 disciplines (65 with DOI, 35 without; 8 CRLF entries preserved); prepared via `sources/real_human/fetch_human_bib.py` (2026-11-15..16) | Checked in & recorded (2026-11-16) |
| `real_typo` | `real_typo_001`..`real_typo_020` | 20 | `mutated` (5) / `real` (15) | 5 `["DRIFT"]`, 15 `["VERIFIED"]` | `false` (5) / `true` (15) | Deterministic edits on `real_clean`: 5 single-letter title typos (`truth: "mutated"`, `DRIFT`), 3 stripped first-author surname accents + 2 surrounding-DOI-whitespace fallbacks, 5 `https://doi.org/` prefixes, 5 uppercase DOIs (`truth: "real"`, `VERIFIED`); built by `tools/build_mutations.py` | Checked in & recorded (2026-11-16) |
| `fabricated_model` | `fab_codex_001`..`040`, `fab_vibe_001`..`040` | 80 | `fabricated` | `["NOT_FOUND", "DRIFT"]` (with ID, 56) / `["NOT_FOUND", "DRIFT", "UNVERIFIED"]` (no ID, 24) | `false` | 40 entries from Codex (`gpt-6-sol`) + 40 from Mistral Vibe (`deepseek-v4-1-flash-1017`), written from imagination offline via `agent-relay`, verified by registry search script, second-agent review, and owner 10-entry spot-check (2026-11-15..16) | Checked in & recorded (2026-11-16) |
| `mut_year1` | `mut_year1_001`..`mut_year1_020` | 20 | `mutated` | `["DRIFT"]` | `false` | Deterministic `+1` or `-1` year shift on `real_clean`, guaranteed distinct from `published-print`, `published-online`, and `issued`; built by `tools/build_mutations.py` | Checked in & recorded (2026-11-16) |
| `mut_year3` | `mut_year3_001`..`mut_year3_020` | 20 | `mutated` | `["DRIFT"]` | `false` | Deterministic 3-to-5-year shift on `real_clean`; built by `tools/build_mutations.py` | Checked in & recorded (2026-11-16) |
| `mut_author` | `mut_author_001`..`mut_author_020` | 20 | `mutated` | `["DRIFT"]` | `false` | First author replaced with the first author of another `real_clean` entry from the same academic field; built by `tools/build_mutations.py` | Checked in & recorded (2026-11-16) |
| `mut_title` | `mut_title_001`..`mut_title_020` | 20 | `mutated` | `["DRIFT"]` | `false` | 10 entries retain the opening 3–4 words and splice the second half of another same-field title; 10 entries swap word order or insert `"not"`; built by `tools/build_mutations.py` | Checked in & recorded (2026-11-16) |
| `mut_doi_swap` | `mut_doi_swap_001`..`mut_doi_swap_020` | 20 | `mutated` | `["DRIFT"]` | `false` | DOI replaced with the DOI of another `real_clean` entry from a different field/decade stratum; built by `tools/build_mutations.py` | Checked in & recorded (2026-11-16) |
| `mut_doi_missing` | `mut_doi_missing_001`..`mut_doi_missing_020` | 20 | `mutated` | `["DRIFT", "NOT_FOUND"]` | `false` | Real metadata from `real_clean` paired with same-prefix seeded random DOI suffix confirmed unregistered (`responseCode: 100`) via `doi.org` Handle API; built by `tools/build_mutations.py --confirm-missing` | Checked in & recorded (2026-11-16) |
| `retracted` | `retracted_001`..`retracted_030` | 30 | `retracted` | `["RETRACTED"]` | `false` | Retracted works discovered via Crossref `filter=update-type:retraction` (`update-to`), restricted to works whose own Crossref record carries an `updated-by` retraction item or OpenAlex `is_retracted: true`, max 3 per DOI prefix, excluding all built-in retracted DOIs; built by `tools/build_retracted.py` | Checked in & recorded (2026-11-16) |

---

## 4. Provenance of `fabricated_model` (80 Entries)

The `fabricated_model` group tests whether ScholarOS blocks plausible-looking hallucinated references produced directly by language models:

- **Two non-implementing models, offline from imagination:** Orchestrated by the dispatcher via `agent-relay` (not generated by the Gemini model implementing ScholarOS), 40 entries (`fab_codex_001`..`fab_codex_040`) were written by `gpt-6-sol` (Codex CLI 0.169) and 40 entries (`fab_vibe_001`..`fab_vibe_040`) were written by `deepseek-v4-1-flash-1017` (Mistral Vibe 3.1.0) across 40 specialized topics (2 entries per topic), with zero network or search access. Each 40-entry batch has 22 DOIs, 4 arXiv IDs, 2 PMIDs, and 12 entries without identifiers (`56` with an identifier, `24` without an identifier overall).
- **Invented author names only (discarded first draft):** Every author name in this group is invented. An earlier first draft of the `vibe` batch attributed fabricated titles to real living scholars; that draft was rejected and discarded in full and was never committed to the repository. In the accepted retry batch, one entry (`fab_vibe_026`) had an invented name whose surname and initial coincided with a real Swahili-coast archaeologist and was replaced in relay step 08 (`sources/fabricated_model/replacements.tsv`).
- **41 accidental identifier collisions intentionally retained:** When models invent DOIs, arXiv IDs, or PMIDs following real publisher numbering patterns (e.g., `10.1016/...`, `1809.06421`, `27182904`), many of those identifiers turn out to be registered to completely unrelated real papers. Independent registry checks confirmed **39** entries have no matching work or registered identifier (`no_such_work`) and **41** entries carry identifiers belonging to unrelated real publications (`identifier_belongs_to_other_work`), while **0** entries match a real work. All 41 identifier collisions are **intentionally retained**: resolving a cited identifier to an unrelated paper and flagging metadata `DRIFT` rather than clearing it is a primary real-world failure mode that a citation firewall must catch.
- **Verification, second review, and human spot-check artifacts:**
  - Prompts given to the models: `sources/fabricated_model/prompts/` and topic lists `codex.topics.tsv`, `vibe.topics.tsv`
  - Format checker: `sources/fabricated_model/check_batch.py`
  - Independent public-registry check (Crossref, OpenAlex, `doi.org`, arXiv, PubMed, without invoking ScholarOS): `sources/fabricated_model/search_check.py`, per-entry JSON evidence in `sources/fabricated_model/evidence/fab_*.json`, and summary table `sources/fabricated_model/search-summary.tsv`
  - Independent second-agent review (Claude Sonnet subagent + 25 exact-title web checks): `sources/fabricated_model/review.tsv` and `sources/fabricated_model/review-notes.md`
  - Repository owner spot-check (10 entries sampled with fixed seed `20261116`, all confirmed fabricated on 2026-11-15): `sources/fabricated_model/spot-check.md` and `sources/fabricated_model/spot-check-result.tsv`

---

## 5. Provenance and Attribution of `real_human` (100 Entries, CC BY 4.0)

The `real_human` group consists of 100 genuine BibTeX entries written by human authors in real LaTeX paper submissions on arXiv (`sources/real_human/NOTES.md`, `fetch_human_bib.py`, `candidates.tsv`, `selection.tsv`, `requests.log`):

- **Selection:** Using arXiv OAI-PMH (`oaipmh.arxiv.org/oai`), papers carrying the exact Creative Commons Attribution 4.0 International licence (`http://creativecommons.org/licenses/by/4.0/`) were sampled with fixed seed `20261116` across 8 arXiv subject sets (`cs`, `math`, `physics:astro-ph`, `physics:cond-mat`, `q-bio`, `stat`, `econ`, `eess`), accepting 3 papers per field (24 papers total; publisher template sample `.bib` files such as `IEEEexample.bib` were excluded).
- **Byte-exact preservation:** Round-robin selection across the 24 papers drew 65 entries with a `doi` field and 35 entries without a `doi` field. Every entry in `entries/real_human.bib` is copied **byte-for-byte** from the authors' `.bib` file except that the citation key was renamed to `real_human_001`..`real_human_100` (see `sources/real_human/selection.tsv` for each entry's `arxiv_id`, `bib_file`, and `original_key`). Eight entries originate from Windows CRLF `.bib` files (`2202.11758v6` `TSPT.bib` and `2401.12885v2` `Bib_up2date.bib`); their `\r\n` bytes are preserved via `.gitattributes` (`-text`).

### Attribution Table (CC BY 4.0)

The `.bib` entries in `entries/real_human.bib` are adapted (citation keys renamed to `real_human_001`..`real_human_100`) from the following 24 arXiv e-print source packages, each licensed under [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) (full metadata and source tarball SHA-256 checksums in `sources/real_human/papers.tsv`):

| # | arXiv ID | Title | Authors | `.bib` File | Licence |
|---:|---|---|---|---|---|
| 1 | [2403.01342v1](https://arxiv.org/abs/2403.01342v1) | LM4OPT: Unveiling the Potential of Large Language Models in Formulating Mathematical Optimization Problems | Tasnim Ahmed; Salimur Choudhury | `aaai24.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 2 | [2402.17846v2](https://arxiv.org/abs/2402.17846v2) | On the Parameterized Complexity of Motion Planning for Rectangular Robots | Iyad Kanj; Salman Parsa | `ref.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 3 | [2310.15516v4](https://arxiv.org/abs/2310.15516v4) | Graph Attention-based Deep Reinforcement Learning for solving the Chinese Postman Problem with Load-dependent costs | Truong Son Hy; Cong Dao Tran | `paper.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 4 | [2211.08582v2](https://arxiv.org/abs/2211.08582v2) | Error bounds for Lie Group representations in quantum mechanics | Lauritz van Luijk; Niklas Galke; Alexander Hahn; Daniel Burgarth | `LieErrorBounds_JPhysA.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 5 | [2201.02191v2](https://arxiv.org/abs/2201.02191v2) | Probabilistic bounds on best rank-one approximation ratio | Khazhgali Kozhasov; Josué Tonelli-Cueto | `biblio.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 6 | [2403.00320v1](https://arxiv.org/abs/2403.00320v1) | Diffusion limits in the quarter plane and non-semimartingale reflected Brownian motion | Rami Atar; Amarjit Budhiraja | `version-subm.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 7 | [2403.00181v1](https://arxiv.org/abs/2403.00181v1) | Gas-dynamical Mass Measurements of the Supermassive Black Holes in the Early-Type Galaxies NGC 4786 and NGC 5193 from ALMA and HST Observations | Kyle M. Kabasares; Jonathan H. Cohn; Aaron J. Barth; Benjamin D. Boizelle; Jared Davidson; Janelle M. Sy; Jeysen Flores-Velázquez; Silvana C. Delgado Andrade; David A. Buote; Jonelle L. Walsh; Andrew J. Baker; Jeremy Darling; Luis C. Ho | `paperbibliography.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 8 | [2401.12885v2](https://arxiv.org/abs/2401.12885v2) | Damped kink motions in a system of two solar coronal tubes with elliptic cross-sections | Mijie Shi; Bo Li; Shaoxia Chen; Hui Yu; Mingzhe Guo | `Bib_up2date.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 9 | [2401.01888v1](https://arxiv.org/abs/2401.01888v1) | NIRDust: Probing Hot Dust Emission Around Type 2 AGN Using K-band Spectra | Gaia Gaspar; Martín Chalela; Juan Cabral; José Alacoria; Damián Mast; Rubén J. Díaz | `main.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 10 | [2202.11758v6](https://arxiv.org/abs/2202.11758v6) | SPT indices emerging from translation invariance in two dimensional quantum spin systems | Tijl Jappens | `TSPT.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 11 | [2403.00377v1](https://arxiv.org/abs/2403.00377v1) | Emergence of Accurate Atomic Energies from Machine Learned Noble Gas Potentials | Frank Uhlig; Samuel Tovey; Christian Holm | `references.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 12 | [2403.00256v1](https://arxiv.org/abs/2403.00256v1) | Critical scaling for dense granular flow between parallel plates near jamming | Michio Otsuki; Kenta Hayashi; Kiwamu Yoshii | `export.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 13 | [2310.13666v3](https://arxiv.org/abs/2310.13666v3) | Minimal Mechanisms of Microtubule Length Regulation in Living Cells | Anna C Nelson; Melissa M Rolls; Maria-Veronica Ciocanel; Scott A McKinley | `MTRef.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 14 | [2302.12542v3](https://arxiv.org/abs/2302.12542v3) | Tutorial on survival modeling with applications to omics data | Zhi Zhao; John Zobolas; Manuela Zucknick; Tero Aittokallio | `reference.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 15 | [2403.02765v1](https://arxiv.org/abs/2403.02765v1) | G4-Attention: Deep Learning Model with Attention for predicting DNA G-Quadruplexes | Shrimon Mukherjee; Pulakesh Pramanik; Partha Basuchowdhuri; Santanu Bhattacharya | `ref.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 16 | [2301.12357v3](https://arxiv.org/abs/2301.12357v3) | SPEED: Experimental Design for Policy Evaluation in Linear Heteroscedastic Bandits | Subhojyoti Mukherjee; Qiaomin Xie; Josiah Hanna; Robert Nowak | `biblio.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 17 | [2307.10052v2](https://arxiv.org/abs/2307.10052v2) | FaIRGP: A Bayesian Energy Balance Model for Surface Temperatures Emulation | Shahine Bouabid; Dino Sejdinovic; Duncan Watson-Parris | `references.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 18 | [2403.01948v1](https://arxiv.org/abs/2403.01948v1) | On Fractional Moment Estimation from Polynomial Chaos Expansion | Lukáš Novák; Marcos Valdebenito; Matthias Faes | `literatura.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 19 | [2403.08846v1](https://arxiv.org/abs/2403.08846v1) | Valuation of Power Purchase Agreements for Corporate Renewable Energy Procurement | Roozbeh Qorbanian; Nils Löhndorf; David Wozabal | `arXive_submission.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 20 | [2403.07177v1](https://arxiv.org/abs/2403.07177v1) | Collusive Outcomes Without Collusion | Inkoo Cho; Noah Williams | `adaboost.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 21 | [2308.07172v2](https://arxiv.org/abs/2308.07172v2) | Economic complexity and the sustainability transition: A review of data, methods, and literature | Bernardo Caldarola; Dario Mazzilli; Lorenzo Napolitano; Aurelio Patelli; Angelica Sbardella | `review-green.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 22 | [2403.01072v1](https://arxiv.org/abs/2403.01072v1) | Distribution-Free Guarantees for Systems with Decision-Dependent Noise | Heling Zhang; Lillian J. Ratliff; Roy Dong | `uni.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 23 | [2305.17519v3](https://arxiv.org/abs/2305.17519v3) | Closure Certificates | Vishnu Murali; Ashutosh Trivedi; Majid Zamani | `bibliography.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |
| 24 | [2311.15453v2](https://arxiv.org/abs/2311.15453v2) | DISYRE: Diffusion-Inspired SYnthetic REstoration for Unsupervised Anomaly Detection | Sergio Naval Marimont; Matthew Baugh; Vasilis Siomos; Christos Tzelepis; Bernhard Kainz; Giacomo Tarroni | `YADUMAS.bib` | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) |

---

## 6. How to Build or Rebuild Each Group

All tools under `Benchmarks/citations/tools/` use the Python 3 standard library only and are invoked with `python3 -I`. Networked build scripts contact only `api.openalex.org`, `api.crossref.org`, and `doi.org` with `User-Agent: ScholarOS-benchmark/1.0` (no email address, no API key, single-threaded, rate-spaced, saving every HTTP response to `sources/<group>/raw/<sha1>.json` and logging live requests to `sources/<group>/requests.log`). Passing `--offline` rebuilds byte-identically from saved `raw/` files without making any network requests.

1. **`real_clean` (100 entries):**
   ```bash
   python3 -I Benchmarks/citations/tools/build_real_clean.py --seed 20261116
   # Deterministic offline rebuild from saved raw responses:
   python3 -I Benchmarks/citations/tools/build_real_clean.py --seed 20261116 --offline
   ```
2. **`retracted` (30 entries):**
   ```bash
   python3 -I Benchmarks/citations/tools/build_retracted.py --seed 20261116
   # Deterministic offline rebuild from saved raw responses:
   python3 -I Benchmarks/citations/tools/build_retracted.py --seed 20261116 --offline
   ```
3. **`real_typo` and `mut_*` (7 groups, 140 entries):**
   ```bash
   # Offline deterministic build for real_typo, mut_year1, mut_year3, mut_author, mut_title, mut_doi_swap:
   python3 -I Benchmarks/citations/tools/build_mutations.py --seed 20261116

   # Full build including doi.org handle confirmation (responseCode == 100) for mut_doi_missing:
   python3 -I Benchmarks/citations/tools/build_mutations.py --seed 20261116 --confirm-missing

   # Deterministic offline rebuild of all 7 groups once doi.org responses are saved:
   python3 -I Benchmarks/citations/tools/build_mutations.py --seed 20261116 --confirm-missing --offline
   ```
4. **`real_human` (100 entries) and `fabricated_model` (80 entries):**
   - `entries/real_human.bib` and `entries/fabricated_model.bib` are checked in directly from the audited raw materials (`sources/real_human/fetch_human_bib.py`, `sources/fabricated_model/check_batch.py`, `sources/fabricated_model/search_check.py`).
5. **`audit_manual` (30 entries):**
   - Maintained directly in `entries/audit_manual.bib` and its corresponding `audit_manual` rows in `gold.jsonl`.
6. **Verify dataset structure, counts, keys, and `gold.jsonl` parity (offline):**
   ```bash
   python3 -I Benchmarks/citations/tools/check_benchmark.py
   ```
7. **Run offline unit tests for the benchmark tooling:**
   ```bash
   python3 -I -m unittest discover -s Benchmarks/citations/tools/tests -t Benchmarks/citations/tools -v
   ```

---

## 7. How to Record or Re-Record Registry Fixtures (`recordings/`)

All 12 `.bib` files under `Benchmarks/citations/entries/` were recorded on **2026-11-16** into `Benchmarks/citations/recordings/` (`748` unique canonical HTTP requests):

- **Pinned `recordings/manifest.json` SHA-256:** `81fd7b8e8a20c106fb186c170dedeb42541dc3b1f7d870e2afcd55fb333bbb7b`

To re-record or incrementally resume recording using the built `ScholarOS` CLI in an isolated `HOME` (via `Scripts/acceptance/lib-cli-guard.sh`) with `--no-cache`:

```bash
swift build
SCHOLAR_SANDBOX_HOME="$(mktemp -d)"
export SCHOLAR_SANDBOX_HOME
export SCHOLAR_CLI_BIN="$PWD/.build/debug/ScholarOS"
unset SCHOLAR_CACHE_DIR
source Scripts/acceptance/lib-cli-guard.sh

for bib in Benchmarks/citations/entries/*.bib; do
  ScholarOS verify-citations "$bib" --registry-record Benchmarks/citations/recordings --registry-record-limit 400 --no-cache --verbose --lang en || echo "$bib -> exit $?"
done
rm -rf "$SCHOLAR_SANDBOX_HOME"
```

Notes for recording:
- `RegistryRecordingSession` reuses URLs already present in `Benchmarks/citations/recordings/manifest.json` after verifying all `.raw` and `.meta.json` SHA-256 digests, and `--registry-record-limit <N>` counts only new HTTP requests sent in that run, so recording can be resumed incrementally across multiple runs or days if OpenAlex's unauthenticated daily search credit budget (`x-ratelimit-remaining`) is reached.
- For a clean re-record from scratch, delete the existing `.raw`, `.meta.json`, and `manifest.json` files inside `Benchmarks/citations/recordings/` (keeping `.gitkeep`) before running the loop above.
- `Scripts/acceptance/m1-acceptance.sh` (Row 3) reads the SHA-256 digest of `recordings/manifest.json` directly from this README and verifies that replay completes with `0` misses and `complete: true`.

---

## 8. Results (`2026-11-16`)

Full machine-readable evaluation output is checked into [`reports/citation-bench-2026-11-16-live.json`](../../reports/citation-bench-2026-11-16-live.json):

- **Date & commit:** `2026-11-16` (evaluated at commit `5c63fc4`, `complete: true`, `replay_miss_count: 0`)
- **Live run telemetry:** `1015` HTTP requests, `390` OpenAlex credits used (no API key, no email), `631.202` seconds elapsed, max concurrent Crossref requests in flight = `1`
- **Live vs. offline replay parity:** `live_vs_replay_diff: []` (`0/480` differences — every verdict, reason list, and field discrepancy in the live run equals the offline replay of `Benchmarks/citations/recordings/`)

### 8.1 Per-Group Verdict Distribution

| Group | Total | `VERIFIED` | (`VERIFIED` w/ venue hint) | `DRIFT` | `NOT_FOUND` | `RETRACTED` | `UNVERIFIED` | In `gold.jsonl` `expected` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `audit_manual` | 30 | 9 | (1) | 11 | 5 | 2 | 3 | `30/30` (100.0%) |
| `real_clean` | 100 | 100 | (0) | 0 | 0 | 0 | 0 | `100/100` (100.0%) |
| `real_human` | 100 | 82 | (4) | 8 | 0 | 0 | 10 | `90/100` (90.0%) |
| `real_typo` | 20 | 15 | (0) | 5 | 0 | 0 | 0 | `20/20` (100.0%) |
| `fabricated_model` | 80 | 0 | (0) | 41 | 15 | 0 | 24 | `80/80` (100.0%) |
| ↳ *with identifier* | *56* | *0* | *(0)* | *41* | *15* | *0* | *0* | *`56/56` (100.0%)* |
| ↳ *without identifier* | *24* | *0* | *(0)* | *0* | *0* | *0* | *24* | *`24/24` (100.0%)* |
| `mut_year1` | 20 | 0 | (0) | 20 | 0 | 0 | 0 | `20/20` (100.0%) |
| `mut_year3` | 20 | 0 | (0) | 20 | 0 | 0 | 0 | `20/20` (100.0%) |
| `mut_author` | 20 | 0 | (0) | 20 | 0 | 0 | 0 | `20/20` (100.0%) |
| `mut_title` | 20 | 0 | (0) | 20 | 0 | 0 | 0 | `20/20` (100.0%) |
| `mut_doi_swap` | 20 | 0 | (0) | 20 | 0 | 0 | 0 | `20/20` (100.0%) |
| `mut_doi_missing` | 20 | 0 | (0) | 19 | 1 | 0 | 0 | `20/20` (100.0%) |
| `retracted` | 30 | 0 | (0) | 0 | 0 | 30 | 0 | `30/30` (100.0%) |
| **Total** | **480** | **206** | **(5)** | **184** | **21** | **32** | **37** | **`470/480` (97.92%)** |

Summary ratios from `overall_metrics`, `hard_requirements`, and `provisional_thresholds`:
- **Hard requirement (`insertable == false` judged `VERIFIED`):** `0/254` (`0.00%`)
- **Allow (`VERIFIED`) precision / recall:** `206/206` (`100.00%`) / `206/226` (`91.15%`)
- **Block (`DRIFT` + `NOT_FOUND` + `RETRACTED`) precision / recall against `truth != "real"`:** `229/237` (`96.62%`) / `229/255` (`89.80%`; `229/254` = `90.16%` against `insertable == false`)
- **Real three groups (`real_clean`, `real_human`, and the 15 `truth == "real"` entries of `real_typo`, `215` entries total):** `197/215` (`91.63%`) `VERIFIED`, `0/215` (`0.00%`) `NOT_FOUND` or `RETRACTED` (`0/220` including the 5 title-typo entries in `real_typo`)
- **`UNVERIFIED` breakdown (`37/480`, `7.71%`):** `no_match_in_search = 35/480` (`7.29%`: `24` `fabricated_model`, `9` `real_human`, `2` `audit_manual`), `registered_no_metadata = 2/480` (`0.42%`: `1` `audit_manual`, `1` `real_human`), transient errors = `0/480`

### 8.2 Why `audit_020`'s Gold Answer Changed (Venue-Only Differences, S55)

`audit_020` cites the real paper *Deep learning* by Yann LeCun, Yoshua Bengio, and Geoffrey Hinton (`2015`, DOI `10.1038/nature14539`), with `journal = {Science}` substituted for `Nature`. Initially its `gold.jsonl` row required `expected: ["DRIFT"]` and `insertable: false`.

During the first full-corpus recording on `2026-11-16`, `11` of `81` resolved entries in `real_human` were flagged `DRIFT` solely because human authors wrote venue names in forms that cannot be deterministically equated to a single registry string without false matches (e.g., partial abbreviations, conference name vs. book-series/proceedings title, publisher brand short name `WIREs Climate Change` vs. full name, or OpenAlex indexing an ICLR paper under `arXiv (Cornell University)`). Per the settled rule recorded in `04-scholaros.md` ("已定和待定", `2026-11-16` venue item), ScholarOS first applies three deterministic "same-venue" checks:
1. Normalized word equality with `short-container-title` (or `container-title`);
2. Ordered per-word prefix abbreviation (dropping periods, skipping stopwords and `&`);
3. Contiguous normalized word-sequence containment (`>= 2` words) in either direction.

When title, publication year, first author, and author count all match the registry record and only the venue still differs after those three checks, ScholarOS no longer downgrades the entry to `DRIFT`; instead, it returns `VERIFIED` with an advisory `venue` entry in `fields` (and a venue note in `auditNote`). When another discrepancy is also present (e.g., `year_diff_1`), the venue mismatch is still reported alongside it as `DRIFT`.

Accordingly, `audit_020`'s gold row was updated to `expected: ["VERIFIED", "DRIFT"]` and `insertable: true`. **Implication:** a genuine work whose *only* error in `.bib` is a wrong or unrecognized journal/venue name (while its identifier, title, year, first author, and author count all match the real publication) is now cleared as `VERIFIED` with an advisory venue hint rather than blocked as `DRIFT`.

### 8.3 `VERIFIED` Entries Carrying an Advisory Venue Hint (`5` Entries Total)

Across all `480` entries (`206` `VERIFIED`), **`5` entries** (`1` in `audit_manual`, `4` in `real_human`) were cleared as `VERIFIED` with an advisory `venue` hint (`severity: "advisory"`):

1. **`audit_020`** (`audit_manual`) — `LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey`, *"Deep learning"* (`2015`, DOI `10.1038/nature14539`): local `journal = "Science"` vs. Crossref `"Nature"`.
2. **`real_human_012`** (`real_human`) — `Qijun Zheng and Liang Bai and Liuyimei Yang and Aibing Yu`, *"110th anniversary: continuum modeling of granular mixing in a rotating drum"* (`2019`, DOI `10.1021/acs.iecr.9b03642`): local `journal = "Ind. Eng. Chem."` (omits the fourth content word *Research*) vs. Crossref `"Industrial & Engineering Chemistry Research"`.
3. **`real_human_017`** (`real_human`) — `Stott, Peter A and Gillett, Nathan P and Hegerl, Gabriele C and Karoly, David J and Stone, D{\'a}ith{\'\i} A and Zhang, Xuebin and Zwiers, Francis`, *"Detection and attribution of climate change: a regional perspective"* (`2010`, no DOI, matched via Crossref bibliographic search to DOI `10.1002/wcc.34`): local `journal = "Wiley interdisciplinary reviews: climate change"` vs. Crossref `"WIREs Climate Change"` (Crossref `short-container-title` is empty).
4. **`real_human_049`** (`real_human`) — `Ilya Loshchilov and Frank Hutter`, *"Decoupled Weight Decay Regularization"* (`2017`, no DOI, matched via OpenAlex title search to DOI `10.48550/arxiv.1711.05101`): local `booktitle = "International Conference on Learning Representations"` vs. OpenAlex `"arXiv (Cornell University)"`.
5. **`real_human_084`** (`real_human`) — `Meinshausen, Nicolai and Bühlmann, Peter`, *"Stability selection"* (`2010`, DOI `10.1111/j.1467-9868.2010.00740.x`): local `journal = "J. Roy. Stat. Soc. B Met."` (omits `Series` and `Statistical`, leaving 6 content words vs. 7) vs. Crossref `"Journal of the Royal Statistical Society Series B: Statistical Methodology"` (Crossref `short-container-title` is `"J. R. Stat. Soc. B"`).

### 8.4 All `18` Non-`VERIFIED` Entries in the Three Real Groups

Among the `215` `truth == "real"` entries across `real_clean` (`100/100` `VERIFIED`), `real_typo` format-only (`15/15` `VERIFIED`), and `real_human` (`82/100` `VERIFIED`), all **`18` non-`VERIFIED` entries** belong to `real_human` (`8` `DRIFT` + `10` `UNVERIFIED`; `0` `NOT_FOUND`, `0` `RETRACTED`). Every cause below is verified directly against `entries/real_human.bib` and the recorded raw responses in `Benchmarks/citations/recordings/`:

1. **`real_human_002`** — Author: `Kramer, Mark`; Title: `The complexity of wire-routing and finding minimum area layouts for arbitrary {VLSI} circuits` (`Advances in Computing Research`, `1984`, no DOI).
   - **Verdict & reasons:** `UNVERIFIED` (`["no_match_in_search"]`).
   - **Why (from recordings):** Has no identifier. Crossref `query.bibliographic` (`rows=5`) returned 5 other works: (1) Sengupta et al. (`issued: [null]`, `created: 2002-11-13`), *"Minimizing area and maximizing porosity for cell layouts using innovative routing strategies"*; (2) Bhatt et al. (`1987`), *"The complexity of minimizing wire lengths in VLSI layouts"*; (3) Kozminski & Kinnen (`1984`), *"An Algorithm for Finding a Rectangular Dual of a Planar Graph for Use in Area Planning for VLSI Integrated Circuits"*; (4) M. R. Kramer & van Leeuwen (`1984`), *"The VLSI complexity of Boolean functions"*; (5) Sherlekar & JáJá (`issued: [null]`, `created: 2006-08-02`), *"Input sensitive VLSI layouts for graphs of arbitrary degree"*. OpenAlex `search` (`per-page=5`) returned 5 other works: (1) Chuang (`1994`), *"Timing and Area Optimization for VLSI Circuit and Layout"*; (2) Cai (`1989`), *"Routing channels in VLSI layout"*; (3) Hartmann et al. (`1998`), *"Switchbox routing in VLSI design: Closing the complexity gap"*; (4) Etawil (`1999`), *"Convex optimization and utility theory, new trends in VLSI circuit layout"*; (5) Sarrafzadeh & Preparata (`1986`), *"A New Methodology for VLSI Layout"*. Neither registry returned this 1984 serial article in its top 5 results (none of the 10 candidates matched the title).

2. **`real_human_004`** — Author: `L. Boutet de Monvel, V. Guillemin`; Title: `The spectral theory of Toeplitz operators` (`1981`, DOI `10.1515/9781400881444`).
   - **Verdict & reasons:** `DRIFT` (`["title_mismatch", "first_author_mismatch", "author_count_mismatch"]`).
   - **Why (from recordings):** Both Crossref (`/works/10.1515/9781400881444`) and OpenAlex store the book's `title` as `"The Spectral Theory of Toeplitz Operators. (AM-99)"` (with empty `subtitle`), appending the *Annals of Mathematics Studies* volume tag `(AM-99)` directly into the title string (`title_mismatch`). In addition, the human `.bib` separated the two authors with a comma (`L. Boutet de Monvel, V. Guillemin`) instead of BibTeX `and`, so BibTeX `"Last, First"` parsing yielded `1` local author with surname `"L. Boutet de Monvel"` and given name `"V. Guillemin"`, whereas Crossref lists `2` authors (`given: "L.", family: "Boutet de Monvel"` and `given: "Victor", family: "Guillemin"`), producing `first_author_mismatch` (local `"L. Boutet de Monvel"` vs. Crossref `"Boutet de Monvel"`) and `author_count_mismatch` (local `1` vs. Crossref `2`).

3. **`real_human_005`** — Author: `Stein, E.M. and Weiss, G.`; Title: `Introduction to Fourier Analysis on Euclidean Spaces` (`Princeton University Press`, `1971`, no DOI).
   - **Verdict & reasons:** `UNVERIFIED` (`["no_match_in_search"]`).
   - **Why (from recordings):** Has no DOI/arXiv/PMID (`url` is a Google Books URL). Crossref `query.bibliographic` (`rows=5`) returned: (1) Elias M. Stein & Guido Weiss (`1972`, DOI `10.1515/9781400883899`), *"Introduction to Fourier Analysis on Euclidean Spaces (PMS-32)"*, followed by (2)–(5) four `1972` chapters/front-matter records from the same volume (*"I. The Fourier Transform"*, *"VII. Multiple Fourier Series"*, *"Contents"*, *"Index"*). OpenAlex `search` (`per-page=5`) returned: (1) Elias M. Stein & Guido Weiss (`1972`, DOI `10.1515/9781400883899`), *"Introduction to Fourier Analysis on Euclidean Spaces (PMS-32)"*; (2) Taibleson (`2016`), *"Fourier Analysis on Local Fields."*; (3) Pinsky (`2009`), *"Introduction to Fourier Analysis and Wavelets"*; (4) unauthored book review (`1993`), *"Lebesgue integration on Euclidean space"*; (5) Roberts (`2015`), *"Aspects of Fourier Analysis on Euclidean Space"*. In both Crossref (#1) and OpenAlex (#1), the publisher record embeds the *Princeton Mathematical Series* number `(PMS-32)` inside `title` (with no separate `subtitle`), so word-by-word title comparison against local `"Introduction to Fourier Analysis on Euclidean Spaces"` did not match.

4. **`real_human_006`** — Author: `Shah, Devavrat and Prabhakar, Balaji`; Title: `The use of memory in randomized load balancing` (`Proceedings IEEE International Symposium on Information Theory,`, `2002`, no DOI).
   - **Verdict & reasons:** `DRIFT` (`["year_diff_1", "venue_mismatch"]`).
   - **Why (from recordings):** Has no DOI. Crossref `query.bibliographic` (#1) returned the paper (`10.1109/isit.2002.1023397`, *"The use of memory in randomized load balancing"*, first author `D. Shah`), but Crossref's record has `issued: [[null]]` and neither `published-print` nor `published-online` (only deposit `created: [2003, 6, 25]`), leaving no publication year on Crossref to confirm the ±1-year search bound. Fallback OpenAlex `search` (#1) matched `https://openalex.org/W2148426943` (DOI `10.1109/isit.2002.1023397`), where OpenAlex records `publication_year = 2003` and `publication_date = "2003-06-25"` (`created_date = "2016-06-24"`) against local `year = 2002` (`year_diff_1`). Because `year_diff_1` already placed the entry in `DRIFT`, the venue difference between local `"Proceedings IEEE International Symposium on Information Theory,"` and OpenAlex `"IEEE International Symposium on Information Theory (ISIT)"` was also reported (`venue_mismatch`).

5. **`real_human_009`** — Author: `{Astropy Collaboration} and {Robitaille}, Thomas P. and ...` (`45` authors); Title: `{Astropy: A community Python package for astronomy}` (`2013`, DOI `10.1051/0004-6361/201322068`, `eprint = 1307.6212`).
   - **Verdict & reasons:** `DRIFT` (`["first_author_mismatch"]`).
   - **Why (from recordings):** Local first author is the institutional/corporate name `"Astropy Collaboration"`, whereas Crossref (`/works/10.1051/0004-6361/201322068`) records the first author (`sequence: "first"`) with corporate `name = "The Astropy Collaboration"` (and arXiv `1307.6212v1` likewise lists `" The Astropy Collaboration"`). Exact normalized corporate-author comparison differs because of the leading `"The"` (`"astropycollaboration"` vs. `"theastropycollaboration"`).

6. **`real_human_011`** — Author: `Ilyes Batatia and Philipp Benner and ... and Gábor Csányi` (`68` authors); Title: `A foundation model for atomistic materials chemistry` (`2023`, `eprint = 2401.00096`, `archiveprefix = arXiv`, no DOI).
   - **Verdict & reasons:** `DRIFT` (`["author_count_mismatch"]`).
   - **Why (from recordings):** Local `.bib` lists `68` authors explicitly (without `and others`) from an earlier revision of the preprint (`published = 2023-12-29T23:08:59Z`), whereas the recorded arXiv Atom response for `id_list=2401.00096` returns `2401.00096v3` (`updated = 2025-09-04T13:50:21Z`), which lists `88` `<author>` entries (`Ilyes Batatia` through `Gábor Csányi`), causing `author_count_mismatch` (`68` vs. `88`).

7. **`real_human_013`** — Author: `Youngmin Park and Prashant Singh and Thomas G. Fai`; Title: `Coarse-grained Stochastic Model of Myosin-Driven Vesicles into Dendritic Spines` (`2021`, DOI `10.1137/21M1434180`, `url` includes `http://arxiv.org/abs/2107.07597`).
   - **Verdict & reasons:** `DRIFT` (`["year_diff_1"]`).
   - **Why (from recordings):** Local `year` is `2021` (matching the arXiv preprint submission date in recorded `2107.07597v2`: `published = 2021-07-15T20:18:17Z`, `updated = 2022-04-08T17:12:57Z`, `journal_ref = "SIAM J. Appl. Mat., 82(3), 793-820, 2022"`), whereas on the cited journal DOI `10.1137/21M1434180` all Crossref dates are in `2022`: `published-print = [2022, 6]`, `published-online = [2022, 5, 12]`, `published = [2022, 5, 12]`, `issued = [2022, 5, 12]`, and `created = [2022, 5, 12]` (OpenAlex likewise has `publication_year = 2022`, `publication_date = "2022-05-12"`). Local `2021` vs. Crossref `2022` triggers `year_diff_1`.

8. **`real_human_016`** — Author: `Fontaine, Xavier and Perrault, Pierre and Valko, Michal and Perchet, Vianney`; Title: `Online a-optimal design and active linear regression` (`International Conference on Machine Learning`, PMLR, `2021`, no DOI).
   - **Verdict & reasons:** `UNVERIFIED` (`["no_match_in_search"]`).
   - **Why (from recordings):** Has no identifier (PMLR proceedings do not assign Crossref DOIs). Crossref `query.bibliographic` (`rows=5`) returned 5 unrelated items: (1) Silvey (`1980`), *"Approximate Theory for Linear Regression Design"*; (2) Brooks (`1977`), *"Optimal Regression Design for Control in Linear Regression"*; (3) unauthored chapter (`2022`), *"2 Optimal experiment design for linear regression models – a primer"*; (4) Brooks (`1977`), *"Optimal regression design for control in linear regression"*; (5) Gelman & Hill (`2017`), *"Linear regression and correlation"*. OpenAlex `search` (`per-page=5`) returned: (1) Xavier Fontaine et al. (`2019`, DOI `10.48550/arxiv.1906.08509`, `publication_date = "2019-06-20"`), *"Online A-Optimal Design and Active Linear Regression"*; (2) Riquelme et al. (`2017`), *"Online Active Linear Regression via Thresholding"*; (3) Yuan et al. (`2020`), *"Distributed Online Linear Regressions"*; (4) Khamaru et al. (`2025`), *"Near-optimal inference in adaptive linear regression"*; (5) Seeger (`2008`), *"Bayesian Inference and Optimal Design for the Sparse Linear Model"*. OpenAlex #1 is the `2019` arXiv preprint of the paper, whose year (`2019`) differs by `2` years from local ICML year `2021` (exceeding the ±1-year candidate filter).

9. **`real_human_018`** — Author: `Edoardo Patelli and Silvia Tolo and Hindolo George-Williams and Jonathan Sadeghi and Roberto Rocchetta and {de Angelis}, Marco and Matteo Broggi`; Title: `OpenCossan 2.0: an efficient computational toolbox for risk, reliability and resilience analysis` (`Proceedings of the joint ICVRAM ISUMA UNCERTAINTIES conference`, `2018`, no DOI).
   - **Verdict & reasons:** `UNVERIFIED` (`["no_match_in_search"]`).
   - **Why (from recordings):** Has no DOI/arXiv/PMID (`url` points to a conference PDF). Crossref `query.bibliographic` (`rows=5`) returned: (1) Patelli et al. (`2014`), *"OpenCossan: An Efficient Open Tool for Dealing with Epistemic and Aleatory Uncertainties"*; (2) Behrensdorf et al. (`2018`), *"Efficient Reliability and Risk Analysis of Complex Interconnected Systems"*; (3) Santhosh & Gopika (`2021`), *"Resilience Engineering"*; (4) Ohiani & Patelli (`2023`), *"The Information Propagation Method for Efficient Network Reliability Analysis"*; (5) Patelli & Rocchetta (`2018`), *"An efficient computational strategy for robust maintenance scheduling: Application to corroded pipelines"*. OpenAlex `search` (`per-page=5`) returned: (1) Patelli & Rocchetta (`2018`), *"An efficient computational strategy for robust maintenance scheduling: Application to corroded pipelines"*; (2) Morais et al. (`2021`), *"Robust data-driven human reliability analysis using credal networks"*; (3) Johnson et al. (`2023`), *"AI TOOLS FOR HUMAN RELIABILITY ANALYSIS"*; (4) Celorrio Barragué & Patelli (`2018`), *"Multi-objective reliability based design of complex engineering structures using response surface methods"*; (5) Hulse et al. (`2021`), *"Fmdtools: A Fault Propagation Toolkit for Resilience Assessment in Early Design"*. Neither registry returned this standalone conference paper in its top 5 results.

10. **`real_human_021`** — Author: `Albert O Hirschman`; Title: `The {Strategy} of {Economic} {Development}` (`Yale University Press`, `1958`, no DOI).
    - **Verdict & reasons:** `UNVERIFIED` (`["no_match_in_search"]`).
    - **Why (from recordings):** Has no DOI/arXiv/PMID (`url` is a Google Books URL). Crossref `query.bibliographic` (`rows=5`) returned 5 journal book reviews: (1) Lewis E. Hill (`1959`), *"The Strategy of Economic Development"*; (2) Andrew Gunder Frank (`1960`), *"Built in Destabilization: A. O. Hirschman's Strategy of Economic Development..."*; (3) B. S. Yamey (`1960`), *"The Strategy of Economic Development."*; (4) Emile James (`1961`), *"The Strategy of Economic Development"*; (5) Staffan Burenstam Linder (`1959`), *"The Strategy of Economic Development"*. OpenAlex `search` (`per-page=5`) likewise returned 5 journal book reviews sharing the book's title: (1) Staffan Burenstam Linder (`1959`), (2) Bernard Goodman (`1959`), (3) John H. Adler (`1959`), (4) Melville H. Watkins (`1961`), and (5) Lewis E. Hill (`1959`). All `1959` candidates failed the first-author surname check (`Hill`, `Linder`, `Goodman`, `Adler` != `Hirschman`), excluding the book reviews rather than mis-matching them as the 1958 monograph.

11. **`real_human_023`** — Author: `Jagtap, Pushpak and Soudjani, Sadegh and Zamani, Majid`; Title: `Formal synthesis of stochastic systems via control barrier certificates` (`IEEE Transactions on Automatic Control`, `2020`, no DOI).
    - **Verdict & reasons:** `DRIFT` (`["year_diff_1"]`).
    - **Why (from recordings):** Has no DOI; matched Crossref `query.bibliographic` candidate #1 (DOI `10.1109/tac.2020.3013916`, *"Formal Synthesis of Stochastic Systems via Control Barrier Certificates"*, first author `Pushpak Jagtap`). Local `year` is `2020` (matching Crossref's metadata deposit date `created = [2020, 8, 4]`), whereas all publication date fields on Crossref #1 are `2021` (`published-print = [2021, 7]`, `published = [2021, 7]`, `issued = [2021, 7]`, with no `published-online` field). Local `2020` vs. Crossref `2021` triggers `year_diff_1`.

12. **`real_human_026`** — Author: `Reinhard Diestel`; Title: `Graph Theory, 4th Edition` (`Springer`, *Graduate texts in mathematics* vol. 173, `2012`, no DOI).
    - **Verdict & reasons:** `UNVERIFIED` (`["no_match_in_search"]`).
    - **Why (from recordings):** Has no identifier. Crossref `query.bibliographic` (`rows=5`) returned 4 items from Diestel's `1990` Oxford book (*"Graph Decotnpositions"*, *"Epigraph"*, *"Preface"*, *"Dedication"*) plus `1` `2005` book chapter by Diestel (*"Extremal Graph Theory"*). OpenAlex `search` (`per-page=5`) returned: (1) Man-Keung Siu (`1998`), *"Introduction to graph theory (4th edition), by Robin J. Wilson..."*; (2) Lun Li et al. (`2005`), *"Towards a Theory of Scale-Free Graphs: Definition, Properties, and Implications"*; (3) Yuzhuo Li et al. (`2023`), *"From Graph Theory to Graph Neural Networks (GNNs)..."*; (4) Rie Aihara (`2002`), *"Textbook of critical care, 4th edition"*; (5) I. E. Idelchik (`2008`), *"Handbook of Hydraulic Resistance, 4th Edition Revised and Augmented"*. Neither source returned Diestel's 2012 4th-edition textbook in its top 5 results.

13. **`real_human_027`** — Author: `Khalil, Elias and Dai, Hanjun and Zhang, Yuyu and Dilkina, Bistra and Song, Le`; Title: `Learning combinatorial optimization algorithms over graphs` (`Advances in neural information processing systems`, vol. 30, `2017`, no DOI).
    - **Verdict & reasons:** `UNVERIFIED` (`["no_match_in_search"]`).
    - **Why (from recordings):** Has no identifier (NeurIPS 2017 proceedings do not carry Crossref DOIs). Crossref `query.bibliographic` (`rows=5`) returned 5 unrelated book chapters: *"Graphs"* (`issued: [null]`, `created: 2007-11-02`), *"Graphs"* (`issued: [null]`, `created: 2005-12-25`), Hirai (`2017`) *"Discrete Convex Functions on Graphs and Their Algorithmic Applications"*, *"- Cayley Graphs"* (`2016`), and *"- Program Graphs"* (`2016`). OpenAlex `search` (`per-page=5`) returned: (1) **Hanjun Dai** et al. (`2017`, DOI `10.48550/arxiv.1704.01665`), *"Learning Combinatorial Optimization Algorithms over Graphs"*; (2) Zhang et al. (`2026`), *"Hyperbolic Give You More: Learning Combinatorial Optimization Algorithm over Graph in Hyperbolic Space"*; (3) Drori et al. (`2020`), *"Learning to Solve Combinatorial Optimization Problems on Real-World Graphs in Linear Time"*; (4) Vesselinova et al. (`2020`), *"Learning Combinatorial Optimization on Graphs: A Survey With Applications to Networking"*; (5) Wang et al. (`2021`), *"A Bi-Level Framework for Learning to Solve Combinatorial Optimization on Graphs"*. OpenAlex #1 is the arXiv preprint (`1704.01665`) of the same work, on which the first author is `Dai, Hanjun` (`Hanjun Dai`), whereas in the NeurIPS 2017 citation (`real_human_027`) the first author is `Khalil, Elias` (with `Dai, Hanjun` second), so OpenAlex #1 did not pass the first-author surname check (`Khalil` != `Dai`).

14. **`real_human_030`** — Author: `Sucha, Premysl and Hanz{\'a}lek, Zdenek`; Title: `Scheduling with start time related deadlines` (`2004 IEEE International Conference on Robotics and Automation (IEEE Cat. No. 04CH37508)`, `2004`, no DOI).
    - **Verdict & reasons:** `DRIFT` (`["year_diff_1", "venue_mismatch"]`).
    - **Why (from recordings):** Has no DOI. Crossref `query.bibliographic` (#1) returned DOI `10.1109/cacsd.2004.1393887` (*"Scheduling with start time related deadlines"*, first author `P. Sucha`), but Crossref's record has `issued: [[null]]` and neither `published-print` nor `published-online` (only deposit `created: [2005, 3, 21]`), so Crossref had no publication year to confirm ±1-year alignment. Fallback OpenAlex `search` (#1) matched `https://openalex.org/W2548799923` (DOI `10.1109/cacsd.2004.1393887`), where OpenAlex records `publication_year = 2005` and `publication_date = "2005-03-21"` (`created_date = "2016-11-11"`) against local `year = 2004` (`year_diff_1`). Because `year_diff_1` produced `DRIFT`, the venue difference between local `"2004 IEEE International Conference on Robotics and Automation (IEEE Cat. No. 04CH37508)"` and OpenAlex `"Proceedings - IEEE International Conference on Robotics and Automation/Proceedings"` was also reported (`venue_mismatch`).

15. **`real_human_041`** — Author: `Hunter, John D`; Title: `{Matplotlib: A 2D graphics environment [Software]}` (`Computing in science \& engineering`, `2007`, no DOI).
    - **Verdict & reasons:** `UNVERIFIED` (`["no_match_in_search"]`).
    - **Why (from recordings):** Has no DOI/arXiv/PMID (`url` is `https://github.com/matplotlib/matplotlib`). Crossref `query.bibliographic` (`rows=5`) returned: (1) John D. Hunter (`2007`, DOI `10.1109/mcse.2007.55`), *"Matplotlib: A 2D Graphics Environment"*; (2) unauthored (`2020`), *"Gary White Explains How to Create and Set Options for 2D Histograms in Matplotlib"*; (3) Federl (`1999`), *"Virtual laboratory: an interactive software environment for computer graphics"*; (4) Andujar et al. (`2007`), *"Anisomorphic ray-casting manipulation for interacting with 2D GUIs"*; (5) unauthored (`issued: [null]`, `created: 2007-08-22`), *"Web3D Tools and Networked Environment"*. OpenAlex `search` (`per-page=5`) returned 5 later software papers from `2015`–`2024` (Nagesh et al. `2015`, Hempel et al. `2024`, Arce-Orozco et al. `2019`, Roubeyrie `2018`, Hunt-Isaak et al. `2024`). Crossref #1 is the exact 2007 paper, but the citing author appended the APA bracketed medium tag `[Software]` inside the local BibTeX `title` field, introducing the extra word `software` absent from Crossref's title `"Matplotlib: A 2D Graphics Environment"`.

16. **`real_human_044`** — Author: `Scarf, H. E.`; Title: `A survey of analytic techniques in inventory theory` (*Multistage Inventory Models and Techniques*, Stanford Univ. Press, `1963`, no DOI).
    - **Verdict & reasons:** `UNVERIFIED` (`["no_match_in_search"]`).
    - **Why (from recordings):** Has no identifier. Crossref `query.bibliographic` (`rows=5`) returned: (1) Herbert E. Scarf (`2005`, DOI `10.1057/9781137024381_9`), *"A Survey of Analytic Techniques in Inventory Theory"* (in *Herbert Scarf's Contributions to Economics, Game Theory and Operations Research*); (2) Scarf (`2002`), *"Inventory Theory"*; (3) Mitchell (`1964`), *"A review of: “Multistage Inventory Models and Techniques”..."*; (4) Jackson et al. (`1965`), *"Multistage Inventory Models and Techniques"*; (5) unauthored (`2013`), *"Analytic Survey of Interview Techniques"*. OpenAlex `search` (`per-page=5`) returned: (1) Herbert E. Scarf (`2005`, DOI `10.1057/9781137024381_9`), *"A Survey of Analytic Techniques in Inventory Theory"*; (2) Hamilton (`1962`), *"ANALYTIC SOLUTIONS OF THE ARROW, HARRIS, AND MARSCHAK DYNAMIC INVENTORY MODEL."*; (3) Jalali & Van Nieuwenhuyse (`2014`), *"Simulation Optimization in Inventory Management..."*; (4) Salini et al. (`2023`), *"Queueing-inventory Systems: A Survey"*; (5) Banerjee et al. (`2025`), *"People Analytics: Theory, Tools and Techniques"*. Both Crossref (#1) and OpenAlex (#1) index only the `2005` Palgrave Macmillan reprint rather than the original `1963` book chapter (`2005` vs. `1963` exceeds the ±1-year search filter).

17. **`real_human_046`** — Author: `Lars Lindemann and Xin Qin and Jyotirmoy V. Deshmukh and George J. Pappas`; Title: `Conformal Prediction for STL Runtime Verification` (`2023 59th Annual Allerton Conference on Communication, Control, and Computing (Allerton)`, `year = 2022`, no DOI).
    - **Verdict & reasons:** `DRIFT` (`["year_diff_1"]`).
    - **Why (from recordings):** Has no DOI. Crossref `query.bibliographic` (`rows=5`) returned #1 DOI `10.1109/allerton58177.2023.10313399` (Allerton `2023`) and #3 DOI `10.1145/3576841.3585927` (ICCPS `2023`), both by Lars Lindemann et al. with identical title; secondary tie-breaking selected #1 because its `container-title` exactly matched local `journal` (`2023 59th Annual Allerton Conference on Communication, Control, and Computing (Allerton)`). Local `.bib` sets `year = {2022}`, whereas all dates on Crossref #1 are `2023` (`published-print = [2023, 9, 26]`, `published = [2023, 9, 26]`, `issued = [2023, 9, 26]`, `created = [2023, 11, 14]`), producing `year_diff_1` (`2022` vs. `2023`).

18. **`real_human_067`** — Author: `Julian Somers`; Title: `Technologies to decarbonise the EU steel industry` (`Publications Office of the European Union`, Technical Report EUR 30982 EN, `2022`, DOI `10.2760/069150`).
    - **Verdict & reasons:** `UNVERIFIED` (`["registered_no_metadata"]`).
    - **Why (from recordings):** Crossref `/works/10.2760/069150` returned HTTP `404` (`Resource not found.`) and OpenAlex `/works/https://doi.org/10.2760/069150` returned HTTP `404`, while `doi.org/api/handles/10.2760/069150` returned HTTP `200` with `responseCode: 1` (confirming `10.2760/069150` is registered under prefix `0.NA/10.2760` and resolves to `https://op.europa.eu/publication/manifestation_identifier/PUB_KJNA30982ENN`, an EU Publications Office registration agency not indexed by Crossref or OpenAlex).
