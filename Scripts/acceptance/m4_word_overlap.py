#!/usr/bin/env python3
"""Measure word multiset recall of segmented PDF chunks against Poppler pdftotext.

Implements M4 Acceptance Table Row 7:
  - Takes non-header/footer segmented chunks (body, section_heading, table_or_figure).
  - Runs `pdftotext -raw` (restoring end-of-line hyphenations) and `pdftotext -tsv`
    (identifying cross-page repeating headers/footers and isolated page numbers in
    the top/bottom 10% margin bands, then subtracting their word multiset).
  - Computes word multiset recall = sum(min(ext[w], ref[w])) / sum(ref.values()).
  - If `pdftotext` is unavailable on the host, prints an explicit "没跑" message
    and exits with code 2 (never treated as passing).

Uses only the Python standard library; safe to invoke with `python3 -I`.
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
from typing import Dict, Iterable, List, Optional, Set, Tuple

MARGIN_BAND_RATIO = 0.10
STANDALONE_PAGENUM_BAND_RATIO = 0.085
STANDALONE_PAGENUM_MIN_GAP_PT = 10.0

EXCLUDED_CHUNK_KINDS = {"header", "footer", "header_footer"}


def dehyphenate_text(text: str) -> str:
    """Restore line-break hyphenations such as 'evaluat-\\ning' -> 'evaluating'."""
    return re.sub(r"([A-Za-z])-[ \t]*\r?\n[ \t]*([a-z])", r"\1\2", text)


def tokenize_words(text: str, dehyphenate: bool = True) -> List[str]:
    """Extract lowercase alphanumeric/decimal word tokens."""
    if dehyphenate:
        text = dehyphenate_text(text)
    return [m.group(0).lower() for m in re.finditer(r"[A-Za-z0-9]+(?:\.[0-9]+)?", text)]


def normalize_margin_template(raw: str) -> Optional[str]:
    collapsed = " ".join(raw.lower().split())
    if not collapsed:
        return None
    digit_norm = re.sub(r"\d+", "#", collapsed)
    stripped_edge = re.sub(r"^#\s+|\s+#$", "", digit_norm)
    alpha_stripped = sum(1 for ch in stripped_edge if ch.isalpha())
    if alpha_stripped >= 6:
        digit_norm = stripped_edge
    total_alpha = sum(1 for ch in digit_norm if ch.isalpha())
    if total_alpha < 3 and "page #" not in digit_norm:
        return None
    return digit_norm


def is_standalone_page_number(raw: str) -> bool:
    s = raw.strip().lower()
    if not s or len(s) > 24:
        return False
    if re.fullmatch(r"\d{1,4}", s):
        return True
    if re.fullmatch(r"[-–—]\s*\d{1,4}\s*[-–—]", s):
        return True
    if re.fullmatch(r"page\s+\d{1,4}(?:\s*(?:of|/)\s*\d{1,4})?", s):
        return True
    if re.fullmatch(r"[ivxlcdm]{1,6}", s):
        return True
    return False


def parse_pdftotext_tsv_margin_words(tsv_text: str) -> Tuple[Counter, List[str]]:
    """Parse `pdftotext -tsv` output and return the word Counter of repeating/page-number margin lines."""
    page_heights: Dict[int, float] = {}
    # Key: (page_num, par_num, block_num, line_num) -> dict with geometry and words
    lines_by_key: Dict[Tuple[int, int, int, int], dict] = {}
    line_order: List[Tuple[int, int, int, int]] = []

    for idx, raw_line in enumerate(tsv_text.splitlines()):
        if idx == 0 and raw_line.startswith("level\t"):
            continue
        cols = raw_line.split("\t")
        if len(cols) < 12:
            continue
        try:
            level = int(cols[0])
            page_num = int(cols[1])
            par_num = int(cols[2])
            block_num = int(cols[3])
            line_num = int(cols[4])
            top = float(cols[7])
            height = float(cols[9])
        except ValueError:
            continue
        text_col = cols[11]

        if level == 1:
            page_heights[page_num] = max(1.0, height)
        elif level == 4:
            key = (page_num, par_num, block_num, line_num)
            if key not in lines_by_key:
                lines_by_key[key] = {
                    "page": page_num,
                    "top": top,
                    "bottom": top + height,
                    "words": [],
                }
                line_order.append(key)
        elif level == 5:
            if text_col and text_col not in {"###PAGE###", "###FLOW###", "###LINE###"}:
                key = (page_num, par_num, block_num, line_num)
                if key not in lines_by_key:
                    lines_by_key[key] = {
                        "page": page_num,
                        "top": top,
                        "bottom": top + height,
                        "words": [],
                    }
                    line_order.append(key)
                lines_by_key[key]["words"].append(text_col)

    total_pages = max(page_heights.keys(), default=0)
    lines_per_page: Dict[int, List[dict]] = {}
    for key in line_order:
        rec = lines_by_key[key]
        if not rec["words"]:
            continue
        rec["text"] = " ".join(rec["words"])
        lines_per_page.setdefault(rec["page"], []).append(rec)

    # Note: In Poppler -tsv coordinates, origin (0, 0) is top-left:
    #   top band:    line.bottom <= MARGIN_BAND_RATIO * page_height
    #   bottom band: line.top    >= (1.0 - MARGIN_BAND_RATIO) * page_height
    top_tpl_pages: Dict[str, Set[int]] = {}
    bot_tpl_pages: Dict[str, Set[int]] = {}

    for page_num, plines in lines_per_page.items():
        ph = page_heights.get(page_num, 792.0)
        top_cut = MARGIN_BAND_RATIO * ph
        bot_cut = (1.0 - MARGIN_BAND_RATIO) * ph
        for ln in plines:
            if ln["bottom"] <= top_cut:
                tpl = normalize_margin_template(ln["text"])
                if tpl:
                    top_tpl_pages.setdefault(tpl, set()).add(page_num)
            if ln["top"] >= bot_cut:
                tpl = normalize_margin_template(ln["text"])
                if tpl:
                    bot_tpl_pages.setdefault(tpl, set()).add(page_num)

    excluded_counter: Counter = Counter()
    excluded_lines: List[str] = []

    for page_num, plines in sorted(lines_per_page.items()):
        ph = page_heights.get(page_num, 792.0)
        top_cut = MARGIN_BAND_RATIO * ph
        bot_cut = (1.0 - MARGIN_BAND_RATIO) * ph
        top_pg_cut = STANDALONE_PAGENUM_BAND_RATIO * ph
        bot_pg_cut = (1.0 - STANDALONE_PAGENUM_BAND_RATIO) * ph

        interior = [ln for ln in plines if ln["bottom"] > top_cut and ln["top"] < bot_cut]
        interior_min_top = min((ln["top"] for ln in interior), default=None)
        interior_max_bot = max((ln["bottom"] for ln in interior), default=None)

        for ln in plines:
            is_hf = False
            if ln["bottom"] <= top_cut:
                tpl = normalize_margin_template(ln["text"])
                repeats = total_pages >= 2 and tpl is not None and len(top_tpl_pages.get(tpl, set())) >= 2
                isolated_pg = (
                    ln["bottom"] <= top_pg_cut
                    and is_standalone_page_number(ln["text"])
                    and (interior_min_top is None or (interior_min_top - ln["bottom"]) >= STANDALONE_PAGENUM_MIN_GAP_PT)
                )
                if repeats or isolated_pg:
                    is_hf = True

            if not is_hf and ln["top"] >= bot_cut:
                tpl = normalize_margin_template(ln["text"])
                repeats = total_pages >= 2 and tpl is not None and len(bot_tpl_pages.get(tpl, set())) >= 2
                isolated_pg = (
                    ln["top"] >= bot_pg_cut
                    and is_standalone_page_number(ln["text"])
                    and (interior_max_bot is None or (ln["top"] - interior_max_bot) >= STANDALONE_PAGENUM_MIN_GAP_PT)
                )
                if repeats or isolated_pg:
                    is_hf = True

            if is_hf:
                excluded_lines.append(ln["text"])
                excluded_counter.update(tokenize_words(ln["text"], dehyphenate=False))

    return excluded_counter, excluded_lines


def extract_non_header_footer_tokens(chunks_payload: object) -> Tuple[Counter, int]:
    """Extract word multiset from non-header/footer chunks in JSON payload."""
    if isinstance(chunks_payload, list):
        items = chunks_payload
    elif isinstance(chunks_payload, dict):
        if isinstance(chunks_payload.get("chunks"), list):
            items = chunks_payload["chunks"]
        elif isinstance(chunks_payload.get("passages"), list):
            items = chunks_payload["passages"]
        else:
            raise ValueError("JSON object must contain a 'chunks' or 'passages' list")
    else:
        raise ValueError("Unsupported chunks JSON top-level type")

    kept_texts: List[str] = []
    kept_chunk_count = 0
    for item in items:
        if not isinstance(item, dict):
            continue
        kind = str(item.get("kind", "body")).strip().lower()
        if kind in EXCLUDED_CHUNK_KINDS:
            continue
        text = item.get("passageText")
        if text is None:
            text = item.get("passage_text")
        if text is None:
            text = item.get("text", "")
        kept_texts.append(str(text))
        kept_chunk_count += 1

    combined = "\n".join(kept_texts)
    tokens = tokenize_words(combined, dehyphenate=True)
    return Counter(tokens), kept_chunk_count


def compute_word_overlap_metrics(
    raw_text: str,
    tsv_text: str,
    chunks_payload: object,
) -> dict:
    """Compute multiset word recall between non-header/footer chunks and margin-trimmed pdftotext -raw."""
    raw_counter = Counter(tokenize_words(raw_text, dehyphenate=True))
    margin_hf_counter, excluded_lines = parse_pdftotext_tsv_margin_words(tsv_text)
    ref_counter = raw_counter - margin_hf_counter

    ext_counter, kept_chunks = extract_non_header_footer_tokens(chunks_payload)

    ref_total = sum(ref_counter.values())
    ext_total = sum(ext_counter.values())
    if ref_total == 0:
        matched = 0
        recall = 1.0
    else:
        matched = sum(min(ext_counter[w], cnt) for w, cnt in ref_counter.items())
        recall = matched / ref_total

    missing_counter = ref_counter - ext_counter
    missing_sample = [f"{w}({c})" for w, c in missing_counter.most_common(10)]

    return {
        "kept_chunk_count": kept_chunks,
        "pdftotext_raw_words": sum(raw_counter.values()),
        "excluded_margin_words": sum(raw_counter.values()) - ref_total,
        "excluded_margin_line_count": len(excluded_lines),
        "reference_words": ref_total,
        "extracted_words": ext_total,
        "matched_words": matched,
        "multiset_recall": recall,
        "multiset_recall_percent": round(recall * 100.0, 2),
        "missing_words_top10": missing_sample,
    }


def resolve_pdftotext_binary(explicit_path: Optional[str]) -> Optional[str]:
    if explicit_path is not None:
        return explicit_path if (os.path.isfile(explicit_path) and os.access(explicit_path, os.X_OK)) else None
    found = shutil.which("pdftotext")
    if found and os.access(found, os.X_OK):
        return found
    hb = "/opt/homebrew/bin/pdftotext"
    if os.path.isfile(hb) and os.access(hb, os.X_OK):
        return hb
    return None


def query_pdftotext_version(binary: str) -> str:
    proc = subprocess.run([binary, "-v"], capture_output=True, text=True, check=False)
    combined = (proc.stderr or proc.stdout or "").splitlines()
    return combined[0].strip() if combined else "pdftotext"


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Compare segmented PDF non-header/footer chunks against Poppler pdftotext (-raw + -tsv)."
    )
    parser.add_argument("--pdf", required=True, help="Path to source PDF file.")
    parser.add_argument("--chunks", required=True, help="Path to segmented chunks JSON file.")
    parser.add_argument(
        "--min-recall",
        type=float,
        default=0.95,
        help="Minimum required word multiset recall in [0, 1] (default: 0.95).",
    )
    parser.add_argument(
        "--pdftotext",
        default=None,
        help="Explicit path to pdftotext binary (optional).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable JSON result.",
    )
    args = parser.parse_args(argv)

    binary = resolve_pdftotext_binary(args.pdftotext)
    if binary is None:
        msg = "没跑: pdftotext not found; word overlap check was not executed."
        if args.json:
            print(json.dumps({"status": "NOT_RUN", "message": msg, "passed": False}, ensure_ascii=False))
        else:
            print(msg, file=sys.stderr)
        return 2

    pdf_path = pathlib.Path(args.pdf)
    chunks_path = pathlib.Path(args.chunks)
    if not pdf_path.is_file():
        print(f"ERROR: PDF file not found: {pdf_path}", file=sys.stderr)
        return 2
    if not chunks_path.is_file():
        print(f"ERROR: Chunks JSON file not found: {chunks_path}", file=sys.stderr)
        return 2

    try:
        chunks_payload = json.loads(chunks_path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"ERROR: Failed to parse chunks JSON '{chunks_path}': {exc}", file=sys.stderr)
        return 2

    raw_proc = subprocess.run([binary, "-raw", str(pdf_path), "-"], capture_output=True, text=True, check=False)
    if raw_proc.returncode != 0:
        print(f"ERROR: pdftotext -raw failed (exit {raw_proc.returncode}): {raw_proc.stderr.strip()}", file=sys.stderr)
        return 2

    tsv_proc = subprocess.run([binary, "-tsv", str(pdf_path), "-"], capture_output=True, text=True, check=False)
    if tsv_proc.returncode != 0:
        print(f"ERROR: pdftotext -tsv failed (exit {tsv_proc.returncode}): {tsv_proc.stderr.strip()}", file=sys.stderr)
        return 2

    try:
        metrics = compute_word_overlap_metrics(raw_proc.stdout, tsv_proc.stdout, chunks_payload)
    except Exception as exc:
        print(f"ERROR: Failed to compute word overlap metrics: {exc}", file=sys.stderr)
        return 2

    passed = metrics["multiset_recall"] + 1e-12 >= args.min_recall
    result = {
        "status": "PASS" if passed else "FAIL",
        "passed": passed,
        "pdf": pdf_path.name,
        "pdftotext_version": query_pdftotext_version(binary),
        "min_recall_required": args.min_recall,
        **metrics,
    }

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(
            f"[{result['status']}] {pdf_path.name}: "
            f"multiset_recall={metrics['multiset_recall_percent']:.2f}% "
            f"({metrics['matched_words']}/{metrics['reference_words']} words; "
            f"extracted={metrics['extracted_words']}, "
            f"excluded_margin_words={metrics['excluded_margin_words']}, "
            f"required>={args.min_recall * 100.0:.2f}%)"
        )
        if metrics["missing_words_top10"]:
            print(f"  missing_top10: {', '.join(metrics['missing_words_top10'])}")

    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
