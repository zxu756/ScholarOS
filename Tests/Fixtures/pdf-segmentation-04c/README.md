# PDF Multi-Column Segmentation Fixture — M4 Stage 4c (Latin Modern Math & Kerning)

Synthetic two-column justified academic PDF fixture compiled offline with Tectonic using default Latin Modern and Computer Modern math fonts to verify `PDFMultiColumnSegmenter` does not insert spurious intra-word spaces across inline math, italic corrections, kerning pairs, ligatures, or period-adjacent words.

## File & Checksum

| File | Source | Pages | Size (bytes) | SHA-256 |
|---|---|---:|---:|---|
| `s12_lm_math_kerning.pdf` | `s12_lm_math_kerning.tex` | 2 | 43,117 | `05e5a03abea4eb4ee811a755eadedf3487e6211f8f08e10c97a6076734d4e030` |

## Layout & Typography Coverage

- **Pages 1–2**: Two-column justified layout (`\documentclass[10pt,twocolumn]{article}`) in default Latin Modern Roman with repeating top running header (`Statistical Risk and Variance Bounds ... Vol. 14, No. 2, 2026`) and repeating bottom page footer (`Page 1 of 2`, `Page 2 of 2`).
- **Inline Math & Operators**: Upright operators (`\log`, `\operatorname{Var}`, `\exp`), subscripted symbols (`Z_i`, `X_k`, `n_{\mathrm{eff}}`, `N_k`, `V_d`, `M_d`, `H_k`, `U_k`), italic variables (`f(x)`, `f(z)`), multi-letter math-italic products and identifiers (`Mt`, `Nd`, `Nab`, `Mto`, `following(x)`, `affine(z)`, `effective(w)`), and display fractions.
- **Kerning, Ligatures, Italics & Period Transitions**: Positive/negative kerning pairs (`To`, `Va`, `AV`, `Ta`, `We`, `Yo`), `ff`/`fi`/`fl`/`ffi`/`ffl` ligatures, slanted/italicized phrases, and period-adjacent capital words (`bounded. Following`, `holds. To`, `valid. Va`, `period. That`).

## Offline Regeneration

Generated with **Tectonic 0.17.0** using `--only-cached --untrusted` against an isolated temporary copy of the local Tectonic cache directory in an isolated `HOME` (no network access, `$HOME/Library` untouched):

```bash
WORK="$(mktemp -d "${TMPDIR:-/tmp}/s12-04c-fixtures.XXXXXX")"
mkdir -p "$WORK/home/Library/Preferences" "$WORK/cache"
cp -c -R "$HOME/Library/Caches/TectonicProject.Tectonic/." "$WORK/cache/" 2>/dev/null \
  || cp -R "$HOME/Library/Caches/TectonicProject.Tectonic/." "$WORK/cache/"

env -i PATH=/opt/homebrew/bin:/usr/bin:/bin \
  HOME="$WORK/home" \
  TECTONIC_CACHE_DIR="$WORK/cache" \
  tectonic --only-cached --untrusted --color never \
  -o Tests/Fixtures/pdf-segmentation-04c \
  Tests/Fixtures/pdf-segmentation-04c/s12_lm_math_kerning.tex

rm -rf "$WORK"
```
