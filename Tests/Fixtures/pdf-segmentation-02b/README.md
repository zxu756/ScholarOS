# PDF Multi-Column Segmentation Fixture — M4 Stage 2b

Synthetic two-column academic PDF fixture compiled offline with Tectonic to verify `PDFMultiColumnSegmenter` and `EvidenceLocatorAndNumericChecker` on pages combining a full-width spanning table at the top, a full-width multi-panel figure with scattered axis ticks/labels (`Score (%)`, legend items, subplot labels) in the middle, and two-column body prose at the bottom.

## File & Checksum

| File | Source | Pages | Size (bytes) | SHA-256 |
|---|---|---:|---:|---|
| `s12_wide_table_fig_cols.pdf` | `s12_wide_table_fig_cols.tex` | 2 | 23,004 | `ceb2b2918f76979c3527b0ece65395ae47b194e1de6c0299843bcbaf3a970f15` |

## Layout Coverage

- **Page 1**: Running header/footer, two-column prose across `1 Introduction`, `2 Methodology` (including `3 layers, 4 attention heads`, `19 datasets grouped into 4 task families`, `(610) of PuzzleScript games`, and `n = 1, 000 samples`), and `3 Dataset Construction`.
- **Page 2**:
  - Upper band: Full-width `table*` (`Table 1`) with multi-column group headers (`In-Domain Suites`, `Out-of-Domain Suites`) and short numeric cells across six columns.
  - Middle band: Full-width `figure*` (`Figure 1`) with legend box (`FHBI`, `Baseline`, `Oracle`), two side-by-side bar-chart subplots whose right Y-axis label (`Score (%)`) and ticks (`100`, `60`, `20`) sit near the page centerline, X-axis ticks (`10k`, `50k`), subplot labels (`(a) In-Domain`, `(b) Out-of-Domain`), and spanning caption.
  - Lower band: Normal two-column body prose (`4 Experimental Results`) in left and right columns (including spaced thousands `30, 000 evaluation queries`).

## Offline Regeneration

Generated with **Tectonic 0.17.0** using `--only-cached --untrusted` against a temporary copy of the local Tectonic cache directory in an isolated `HOME` (no network access, `$HOME/Library` untouched):

```bash
WORK="$(mktemp -d "${TMPDIR:-/tmp}/s12-02b-fixtures.XXXXXX")"
mkdir -p "$WORK/home/Library/Preferences" "$WORK/cache"
cp -c -R "$HOME/Library/Caches/TectonicProject.Tectonic/." "$WORK/cache/" 2>/dev/null \
  || cp -R "$HOME/Library/Caches/TectonicProject.Tectonic/." "$WORK/cache/"

env -i PATH=/opt/homebrew/bin:/usr/bin:/bin \
  HOME="$WORK/home" \
  TECTONIC_CACHE_DIR="$WORK/cache" \
  tectonic --only-cached --untrusted --color never \
  -o Tests/Fixtures/pdf-segmentation-02b \
  Tests/Fixtures/pdf-segmentation-02b/s12_wide_table_fig_cols.tex

rm -rf "$WORK"
```
