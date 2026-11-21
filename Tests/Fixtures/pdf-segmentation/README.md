# PDF Multi-Column Segmentation Fixtures (M4 / S12)

Synthetic two-column academic PDF fixtures compiled offline from LaTeX sources to verify `PDFMultiColumnSegmenter` against S12 regressions (repeating margin headers/footers, section heading formats, paragraph hyphenation/length boundaries, cross-column spanning tables with narrow cells, and two-column reading order when only 1–2 body lines remain below a wide float).

## Files & Checksums

| File | Source | Pages | Size (bytes) | SHA-256 |
|---|---|---:|---:|---|
| `s12_paper.pdf` | `s12_paper.tex` | 3 | 32,502 | `e676f9ad0105598b02aa827278ce2b61f6959c85a57d6cf358d035fc9d90214b` |
| `s12_ieeetran.pdf` | `s12_ieeetran.tex` | 1 | 24,082 | `213a865a0accfd944e159ea211181f3e56cea34c138fb160ecd178b19919652a` |
| `s12_acm_refs.pdf` | `s12_acm_refs.tex` | 3 | 30,778 | `41f6098ba907a14a97418939fb24e8333217158d33a31c1d51eafd808e782f85` |
| `s12_math_columns.pdf` | `s12_math_columns.tex` | 2 | 37,209 | `938acfda9e68525263761660306f7061a09174ebe87758f59b3f98fd57adf2c5` |

### Coverage Summary

- **`s12_paper.pdf`** (`\documentclass[10pt,twocolumn]{article}`, US Letter `612 x 792 pt`):
  - Odd/even running headers (`Journal of Reproducible Systems, Vol. 14, No. 2, November 2026` / `Lexical Grounding Study`) and page-numbered running footers (`Preprint Under Review — Do Not Distribute — Page 1/2/3`).
  - Seven section headings across mixed conventions: `Abstract`, `1 Introduction`, `2 Related Work`, `3. Methodology` (dotted Arabic, `< 18` chars), `4 Experimental Evaluation` (composite multi-word heading), `5 Conclusion` (`< 18` chars), and `References`.
  - Multi-paragraph section (`1 Introduction`) exceeding 520 characters with line-break hyphenation at the tail (`checks ex-\nplicit numbers.`).
  - Page 2: Cross-column `table*` (`Table 1`) with a narrow first-column header cell (`Engine Variant`) that does not cross the page centerline, followed by two-column body notes.
  - Page 3: Cross-column `table*` (`Table 2`) dominating the upper page, with 2 body lines in the left column (`PAGE3_LEFT_1`, `PAGE3_LEFT_2`) and 1 body line in the right column (`PAGE3_RIGHT_1`) at the same vertical position.
- **`s12_ieeetran.pdf`** (`\documentclass[conference]{IEEEtran}`, US Letter `612 x 792 pt`):
  - Two-column IEEE conference layout with Roman numeral section headings `I. Introduction`, `II. Related Work`, `III. Methodology`, `IV. Experiments`, `V. Conclusion`, plus unnumbered `References`.
- **`s12_acm_refs.pdf`** (`\documentclass[10pt,twocolumn]{article}`, US Letter `612 x 792 pt`):
  - Two-column conference layout with all-caps headings (`ABSTRACT`, `1 INTRODUCTION`, `2 METHODOLOGY`, `3 EXPERIMENTS`, `4 CONCLUSION`, `REFERENCES`), prose cross-reference (`Table 1 reports...`), a genuine cross-column `table*` (`Table 1`) on Page 2, and a two-column hanging-indented `[1]`–`[10]` bibliography on Page 3 where `[1]`–`[5]` in the left column align vertically with `[6]`–`[10]` in the right column.
- **`s12_math_columns.pdf`** (`\documentclass[10pt,twocolumn]{article}` + `amsmath`, US Letter `612 x 792 pt`):
  - Two-column theoretical physics layout with dotted numbered headings (`1. Introduction` through `6. Conclusion`) plus `Abstract` and `References`, dense inline operator diacritics (`\hat`, `\bar`), and 10 numbered single-column display equations `(1)`–`(10)` aligned across left and right columns directly adjacent to `5. Generating Functional`.

## Offline Regeneration

Generated with **Tectonic 0.17.0** (`Tectonic 0.17.0`) using `--only-cached --untrusted` against an isolated temporary copy of the local Tectonic cache directory (never modifying `$HOME/Library` or requiring network access):

```bash
WORK="$(mktemp -d "${TMPDIR:-/tmp}/s12-fixtures.XXXXXX")"
mkdir -p "$WORK/home/Library/Preferences" "$WORK/cache"
cp -c -R "$HOME/Library/Caches/TectonicProject.Tectonic/." "$WORK/cache/" 2>/dev/null \
  || cp -R "$HOME/Library/Caches/TectonicProject.Tectonic/." "$WORK/cache/"

for tex in s12_paper.tex s12_ieeetran.tex s12_acm_refs.tex s12_math_columns.tex; do
  env -i PATH=/opt/homebrew/bin:/usr/bin:/bin \
    HOME="$WORK/home" \
    TECTONIC_CACHE_DIR="$WORK/cache" \
    tectonic --only-cached --untrusted --color never \
    -o Tests/Fixtures/pdf-segmentation \
    "Tests/Fixtures/pdf-segmentation/$tex"
done

rm -rf "$WORK"
```
