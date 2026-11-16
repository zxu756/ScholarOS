# ScholarOS Citation Verification Benchmark (`Benchmarks/citations/`)

**中文摘要：** 本目录存放 ScholarOS 引用核查基准评测集（建立日期：2026-11-16），设计总规模为 12 组共 480 条真假与变异混合的 BibTeX 文献条目，用于对照公开书目注册库（Crossref、OpenAlex、`doi.org`、arXiv、PubMed）检验引用防火墙能否拦下模型凭空编造、元数据篡改及已撤稿的文献，同时避免误伤真实文献。当前已入库 `audit_manual`（30 条）、`real_human`（100 条，取自 24 篇 CC BY 4.0 许可的 arXiv 论文源码包 `.bib` 原文）与 `fabricated_model`（80 条，由两家模型离线凭空编写并经独立检索、复核及人工抽查确认）；其余 9 组（`real_clean`、`retracted`、`real_typo` 及 6 个 `mut_*` 变异组）的确定性生成脚本位于 `tools/` 下，连同 `recordings/` 回放录制将由调度方联网执行生成。本说明文件不包含任何评测指标结果数字。

---

## 1. Purpose

This benchmark evaluates ScholarOS's 5-class citation verification firewall (`VERIFIED`, `DRIFT`, `NOT_FOUND`, `RETRACTED`, `UNVERIFIED`) on realistic scholarly inputs rather than synthetic toy strings:

1. **Blocking non-insertable references:** Fabricated entries invented by language models (including entries whose invented identifiers happen to collide with unrelated real publications), real entries with corrupted metadata (wrong year, swapped first author, rewritten title, swapped DOI, or unregistered DOI), and retracted publications must not be cleared as `VERIFIED`.
2. **Preserving genuine references:** Clean journal articles from Crossref/OpenAlex, unaltered BibTeX entries written by human authors in real LaTeX manuscripts (including abbreviated journal names, LaTeX diacritics, missing DOIs, and CRLF line endings), and harmless formatting variations (`https://doi.org/` prefix, uppercase DOI, stripped surname accents, surrounding DOI whitespace) should be handled accurately without falsely reporting them as non-existent or retracted.
3. **Deterministic offline replay:** Once recorded into `recordings/`, the entire 480-entry corpus can be replayed offline with SHA-256 integrity checks (`--registry-replay Benchmarks/citations/recordings`) and re-verified live on demand.

Created: **2026-11-16**.

---

## 2. Directory Layout

```text
Benchmarks/citations/
  README.md                 Dataset documentation, provenance, attribution, rebuild & recording guide
  entries/<group>.bib       One BibTeX file per group (keys prefixed by group)
  gold.jsonl                One JSON object per entry: key, group, truth, expected, insertable, provenance, note
  sources/<group>/          Sampling manifests, raw registry responses (raw/<sha1>.json), logs, and review records
  recordings/               Recorded HTTP fixtures for ScholarOS --registry-replay (populated after generation)
  tools/                    Stdlib-only Python 3 build scripts, structural checker, and offline unit tests
```

---

## 3. Benchmark Groups (12 Groups, 480 Entries Total)

| Group | Key Pattern | Count | `truth` | `expected` | `insertable` | Source & Builder | Status |
|---|---|---:|---|---|---|---|---|
| `audit_manual` | `audit_001`..`audit_030` | 30 | per entry | per entry | per entry | Handwritten edge-case audit suite (`Fixtures/citations-m0-recheck.bib` + near-title / surname-typo / DataCite / untrusted-tag / arXiv / PubMed / CNKI cases); written by implementation worker (2026-11-16) | Checked in |
| `real_clean` | `real_clean_001`..`real_clean_100` | 100 | `real` | `["VERIFIED"]` | `true` | Stratified OpenAlex `sample` + `seed` across 5 fields and 4 publication-year bands (`type:article,has_doi:true`), converted from Crossref `/works/<DOI>`; built by `tools/build_real_clean.py` | Not generated yet (awaiting live run) |
| `real_human` | `real_human_001`..`real_human_100` | 100 | `real` | `["VERIFIED", "DRIFT"]` | `true` | Byte-exact BibTeX entries (only citation key renamed) extracted from 24 CC BY 4.0 arXiv e-print source packages across 8 disciplines (65 with DOI, 35 without; 8 CRLF entries preserved); prepared by dispatcher via `sources/real_human/fetch_human_bib.py` (2026-11-15..16) | Checked in |
| `real_typo` | `real_typo_001`..`real_typo_020` | 20 | `mutated` | 5 `["DRIFT"]`, 15 `["VERIFIED"]` | `false` (5) / `true` (15) | Deterministic edits on `real_clean`: 5 single-letter title typos (`DRIFT`), 5 stripped first-author surname accents (with DOI-whitespace fallback if fewer than 5 accented surnames exist), 5 `https://doi.org/` prefixes, 5 uppercase DOIs (`VERIFIED`); built by `tools/build_mutations.py` | Not generated yet (depends on `real_clean`) |
| `fabricated_model` | `fab_codex_001`..`040`, `fab_vibe_001`..`040` | 80 | `fabricated` | `["NOT_FOUND", "DRIFT"]` (with ID) / `["NOT_FOUND", "DRIFT", "UNVERIFIED"]` (no ID) | `false` | 40 entries from Codex (`gpt-6-sol`) + 40 from Mistral Vibe (`deepseek-v4-1-flash-1017`), written from imagination offline via `agent-relay`, verified by registry search script, second-agent review, and owner 10-entry spot-check (2026-11-15..16) | Checked in |
| `mut_year1` | `mut_year1_001`..`mut_year1_020` | 20 | `mutated` | `["DRIFT"]` | `false` | Deterministic `+1` or `-1` year shift on `real_clean`, guaranteed distinct from `published-print`, `published-online`, and `issued`; built by `tools/build_mutations.py` | Not generated yet (depends on `real_clean`) |
| `mut_year3` | `mut_year3_001`..`mut_year3_020` | 20 | `mutated` | `["DRIFT"]` | `false` | Deterministic 3-to-5-year shift on `real_clean`; built by `tools/build_mutations.py` | Not generated yet (depends on `real_clean`) |
| `mut_author` | `mut_author_001`..`mut_author_020` | 20 | `mutated` | `["DRIFT"]` | `false` | First author replaced with the first author of another `real_clean` entry from the same academic field; built by `tools/build_mutations.py` | Not generated yet (depends on `real_clean`) |
| `mut_title` | `mut_title_001`..`mut_title_020` | 20 | `mutated` | `["DRIFT"]` | `false` | 10 entries retain the opening 3–4 words and splice the second half of another same-field title; 10 entries swap word order or insert `"not"`; built by `tools/build_mutations.py` | Not generated yet (depends on `real_clean`) |
| `mut_doi_swap` | `mut_doi_swap_001`..`mut_doi_swap_020` | 20 | `mutated` | `["DRIFT"]` | `false` | DOI replaced with the DOI of another `real_clean` entry from a different field/decade stratum; built by `tools/build_mutations.py` | Not generated yet (depends on `real_clean`) |
| `mut_doi_missing` | `mut_doi_missing_001`..`mut_doi_missing_020` | 20 | `mutated` | `["DRIFT", "NOT_FOUND"]` | `false` | Real metadata from `real_clean` paired with same-prefix seeded random DOI suffix confirmed unregistered (`responseCode: 100`) via `doi.org` Handle API; built by `tools/build_mutations.py --confirm-missing` | Not generated yet (depends on `real_clean` + live handle check) |
| `retracted` | `retracted_001`..`retracted_030` | 30 | `retracted` | `["RETRACTED"]` | `false` | Retracted works discovered via Crossref `filter=update-type:retraction` (`update-to`), restricted to works whose own Crossref record carries an `updated-by` retraction item or OpenAlex `is_retracted: true`, max 3 per DOI prefix, excluding all built-in retracted DOIs; built by `tools/build_retracted.py` | Not generated yet (awaiting live run) |

### Groups Not Yet Generated

At the current skeleton stage, 3 groups (`audit_manual`, `real_human`, `fabricated_model`) are checked into `entries/` and `gold.jsonl`. The remaining 9 groups (`real_clean`, `retracted`, `real_typo`, `mut_year1`, `mut_year3`, `mut_author`, `mut_title`, `mut_doi_swap`, `mut_doi_missing`) and `recordings/` have not been generated yet and will be populated by running the commands in Section 6 and Section 7.

---

## 4. Provenance of `fabricated_model` (80 Entries)

The `fabricated_model` group tests whether ScholarOS blocks plausible-looking hallucinated references produced directly by language models:

- **Two non-implementing models, offline from imagination:** Orchestrated by the dispatcher via `agent-relay` (not generated by the Gemini model implementing ScholarOS), 40 entries (`fab_codex_001`..`fab_codex_040`) were written by `gpt-6-sol` (Codex CLI 0.169) and 40 entries (`fab_vibe_001`..`fab_vibe_040`) were written by `deepseek-v4-1-flash-1017` (Mistral Vibe 3.1.0) across 40 specialized topics (2 entries per topic), with zero network or search access. Each 40-entry batch has 22 DOIs, 4 arXiv IDs, 2 PMIDs, and 12 entries without identifiers.
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

After all 12 `.bib` files exist under `Benchmarks/citations/entries/`, record real registry responses using the built `ScholarOS` CLI in an isolated `HOME` (via `Scripts/acceptance/lib-cli-guard.sh`) with `--no-cache` so every unique canonical URL is recorded into `Benchmarks/citations/recordings/`:

```bash
swift build
SCHOLAR_SANDBOX_HOME="$(mktemp -d)"
export SCHOLAR_SANDBOX_HOME
export SCHOLAR_CLI_BIN="$PWD/.build/debug/ScholarOS"
source Scripts/acceptance/lib-cli-guard.sh

for bib in Benchmarks/citations/entries/*.bib; do
  ScholarOS verify-citations "$bib" --registry-record Benchmarks/citations/recordings --no-cache --verbose --lang en
done
rm -rf "$SCHOLAR_SANDBOX_HOME"
```

Notes for recording:
- `RegistryRecordingSession` reuses URLs already present in `Benchmarks/citations/recordings/manifest.json` after verifying all `.raw` and `.meta.json` SHA-256 digests, so recording can be resumed incrementally across multiple runs or days if OpenAlex's unauthenticated daily search credit budget (`x-ratelimit-remaining`) is reached.
- For a clean re-record from scratch, delete the existing `.raw`, `.meta.json`, and `manifest.json` files inside `Benchmarks/citations/recordings/` (keeping `.gitkeep`) before running the loop above.
- Once recording completes, compute `shasum -a 256 Benchmarks/citations/recordings/manifest.json` and record the resulting SHA-256 digest here and in `Scripts/acceptance/m1-acceptance.sh`.
