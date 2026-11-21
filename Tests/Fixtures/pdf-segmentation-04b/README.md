# PDF Multi-Column Segmentation Fixture — M4 Stage 4b (Tight Justified Word Spacing)

Synthetic two-column justified academic PDF fixture compiled offline with Tectonic to verify `PDFMultiColumnSegmenter` word-space recovery when PDFKit's `PDFSelection.string` swallows narrow (`2.1–2.4 pt`) justified inter-word gaps.

## File & Checksum

| File | Source | Pages | Size (bytes) | SHA-256 |
|---|---|---:|---:|---|
| `s12_tight_word_spacing.pdf` | `s12_tight_word_spacing.tex` | 2 | 21,558 | `6af877b09083e53d1a5fd26f883e90032a4d1782f89619d4a9985ce2f478e109` |

## Layout Coverage

- **Pages 1–2**: Two-column justified layout with compressed inter-word spacing (`\spaceskip=2.18pt`, producing `2.1–2.4 pt` horizontal word gaps), repeating top running header (`Autonomous Planetary Robotics Review ... Vol. 12, No. 4, 2026`), and repeating bottom page footer (`Page 1 of 2`, `Page 2 of 2`).
- **Typography & Quantitative Spans**: Numbered section headings (`1 Introduction` through `5 Conclusion`) plus unnumbered `References`, SI quantities (`2.5 m`, `40 ms`, `3.4%`, `1,200 simulated episodes`), inline math (`S ⊂ R`, `ϵ ∈ (0, 1]`, `γ = 0.99`), and hyphenated compound terms (`whole-body`, `safety-constrained`, `low-level`, `joint-limit`, `multi-step`).

## Offline Regeneration

Generated with **Tectonic 0.17.0** using `--only-cached --untrusted` against an isolated temporary copy of the local Tectonic cache directory in an isolated `HOME` (no network access, `$HOME/Library` untouched):

```bash
WORK="$(mktemp -d "${TMPDIR:-/tmp}/s12-04b-fixtures.XXXXXX")"
mkdir -p "$WORK/home/Library/Preferences" "$WORK/cache"
cp -c -R "$HOME/Library/Caches/TectonicProject.Tectonic/." "$WORK/cache/" 2>/dev/null \
  || cp -R "$HOME/Library/Caches/TectonicProject.Tectonic/." "$WORK/cache/"

env -i PATH=/opt/homebrew/bin:/usr/bin:/bin \
  HOME="$WORK/home" \
  TECTONIC_CACHE_DIR="$WORK/cache" \
  tectonic --only-cached --untrusted --color never \
  -o Tests/Fixtures/pdf-segmentation-04b \
  Tests/Fixtures/pdf-segmentation-04b/s12_tight_word_spacing.tex

rm -rf "$WORK"
```
