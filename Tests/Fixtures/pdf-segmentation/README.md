# PDF Multi-Column Segmentation Fixtures (M4 / S12)

Synthetic two-column academic PDF fixtures compiled offline from LaTeX sources to verify `PDFMultiColumnSegmenter` against S12 regressions (repeating margin headers/footers, section heading formats, paragraph hyphenation/length boundaries, cross-column spanning tables with narrow cells, and two-column reading order when only 1–2 body lines remain below a wide float).

## Files & Checksums

| File | Source | Pages | Size (bytes) | SHA-256 |
|---|---|---:|---:|---|
| `s12_paper.pdf` | `s12_paper.tex` | 3 | 32,502 | `e676f9ad0105598b02aa827278ce2b61f6959c85a57d6cf358d035fc9d90214b` |
| `s12_ieeetran.pdf` | `s12_ieeetran.tex` | 1 | 24,082 | `213a865a0accfd944e159ea211181f3e56cea34c138fb160ecd178b19919652a` |

### Coverage Summary

- **`s12_paper.pdf`** (`\documentclass[10pt,twocolumn]{article}`, US Letter `612 x 792 pt`):
  - Odd/even running headers (`Journal of Reproducible Systems, Vol. 14, No. 2, November 2026` / `Lexical Grounding Study`) and page-numbered running footers (`Preprint Under Review — Do Not Distribute — Page 1/2/3`).
  - Seven section headings across mixed conventions: `Abstract`, `1 Introduction`, `2 Related Work`, `3. Methodology` (dotted Arabic, `< 18` chars), `4 Experimental Evaluation` (composite multi-word heading), `5 Conclusion` (`< 18` chars), and `References`.
  - Multi-paragraph section (`1 Introduction`) exceeding 520 characters with line-break hyphenation at the tail (`checks ex-\nplicit numbers.`).
  - Page 2: Cross-column `table*` (`Table 1`) with a narrow first-column header cell (`Engine Variant`) that does not cross the page centerline, followed by two-column body notes.
  - Page 3: Cross-column `table*` (`Table 2`) dominating the upper page, with 2 body lines in the left column (`PAGE3_LEFT_1`, `PAGE3_LEFT_2`) and 1 body line in the right column (`PAGE3_RIGHT_1`) at the same vertical position.
- **`s12_ieeetran.pdf`** (`\documentclass[conference]{IEEEtran}`, US Letter `612 x 792 pt`):
  - Two-column IEEE conference layout with Roman numeral section headings `I. Introduction`, `II. Related Work`, `III. Methodology`, `IV. Experiments`, `V. Conclusion`, plus unnumbered `References`.

## Offline Regeneration

Generated with **Tectonic 0.17.0** (`Tectonic 0.17.0`) using `--only-cached --untrusted` against an isolated temporary copy of the local Tectonic cache directory (never modifying `$HOME/Library` or requiring network access):

```bash
WORK="$(mktemp -d "${TMPDIR:-/tmp}/s12-fixtures.XXXXXX")"
mkdir -p "$WORK/home/Library/Preferences" "$WORK/cache"
cp -c -R "$HOME/Library/Caches/TectonicProject.Tectonic/." "$WORK/cache/" 2>/dev/null \
  || cp -R "$HOME/Library/Caches/TectonicProject.Tectonic/." "$WORK/cache/"

env -i PATH=/opt/homebrew/bin:/usr/bin:/bin \
  HOME="$WORK/home" \
  TECTONIC_CACHE_DIR="$WORK/cache" \
  tectonic --only-cached --untrusted --color never \
  -o Tests/Fixtures/pdf-segmentation \
  Tests/Fixtures/pdf-segmentation/s12_paper.tex

env -i PATH=/opt/homebrew/bin:/usr/bin:/bin \
  HOME="$WORK/home" \
  TECTONIC_CACHE_DIR="$WORK/cache" \
  tectonic --only-cached --untrusted --color never \
  -o Tests/Fixtures/pdf-segmentation \
  Tests/Fixtures/pdf-segmentation/s12_ieeetran.tex

rm -rf "$WORK"
```
