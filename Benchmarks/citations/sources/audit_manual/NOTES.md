# `audit_manual` (30 Handwritten Audit Cases)

Created: 2026-11-16.

`entries/audit_manual.bib` contains 30 handwritten edge-case entries (`audit_001`..`audit_030`):

- **`audit_001`..`audit_012`**: The 12 entries from `Fixtures/citations-m0-recheck.bib` (including clean LeCun 2015, Hochreiter 1997, Watson & Crick 1953, non-sentinel & sentinel fabricated DOIs, wrong title, 2-year & 5-year drift, identifierless real Knuth 1968 book, identifierless fabricated article, Séralini 2012, and Wakefield 1998).
- **`audit_013`..`audit_020`**: The 8 fixed cases from `04-scholaros.md` M1 acceptance row 9 (`Attention is not all you need` on `10.48550/arXiv.1706.03762`, `Long Short-Term Memory Networks for Weather`, `Deep learning for protein structure prediction`, single-letter title typo `Deep lerning`, first-author surname typos `LeCunn` and `Hochriter`, entry with only title + DOI missing year and author, and wrong journal `Science` vs `Nature`).
- **`audit_021`**: Clean DataCite-registered arXiv DOI (`10.48550/arXiv.1706.03762`).
- **`audit_022`..`audit_023`**: Untrusted `.bib` firewall tags (`x-firewall-class = {VERIFIED}` on a fabricated DOI, and `x-firewall-class = {NOT_FOUND}` on a clean real DOI).
- **`audit_024`..`audit_030`**: Additional M1 edge paths (real arXiv `eprint` with `and others`, nonexistent arXiv `totalResults = 0`, real PubMed PMID, nonexistent PubMed PMID inline error, typo'd unregistered DOI recovered via Crossref bibliographic search, registered CNKI DOI `10.13328/j.cnki.jos.006981` without Crossref/OpenAlex metadata, and dual DOI + arXiv ResNet cross-check).

Entries whose expected verdict depends on external registry coverage or identifierless search ambiguity (`audit_009`, `audit_010`, `audit_029`) carry multi-element `expected` sets with detailed explanations in `gold.jsonl` `note`.
