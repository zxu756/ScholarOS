#!/usr/bin/env python3
"""M4 Acceptance Harness & Judgment Logic (`Scripts/acceptance/m4_harness.py`).

Implements the independent verification, coordinate conversion, and acceptance table
judgments for ScholarOS M4 (`04-scholaros.md`, Rows 1-9):
  - Row 1: Naming, schema (`scholaros.evidence/1`), verdicts, required fields, exit codes,
           and absence of entailment/GROUNDED claims in CLI `--help`, CLI output, and MCP `tools/list`.
  - Row 2: 10 `grounded` claims (`>= 8/10` FOUND and `page` in `expected_pages`).
  - Row 3: 10 `numeric_mismatch` claims (`>= 8/10` NUMERIC_MISMATCH, `page` in `expected_pages`,
           and `discrepancies[].pdf_text` containing one of `ground_truth_numbers` after stripping
           whitespace and thousands-separator commas).
  - Row 4: 10 `not_mentioned` claims + 15 `sentinel` rows (`25/25` NOT_FOUND, `matches == []`).
  - Row 5: Bounding-box geometric check against `expected_pdftotext/<id>.tsv.gz` (and live `pdftotext -tsv`
           comparison when installed): positive size, inside page `mediaBox`, non-full-page (`area < 90%`
           of `mediaBox`), and `>= 80%` passage word coverage after +4pt expansion, with explicit
           PDF bottom-left <-> `pdftotext -tsv` top-left coordinate conversion.
  - Row 6: PDF segmentation (`segment-pdf --offline --json`) across the 5 benchmark papers and
           5 synthetic fixtures: 0 repeating margin header/footer leaks in `body` chunks, Introduction +
           References headings recognized, and left-before-right reading order below spanning floats.
  - Row 7: Word multiset recall (`>= 95%` per paper) via `m4_word_overlap` + per-paper segmentation timing.
  - Row 8: MCP `scholaros mcp --offline` (`tools/list` 5 default tools, `locate_evidence` present,
           `scholar_search_provenance` deleted -> `-32602`, unknown args -> `ERR_INVALID_ARGUMENT`,
           and 0 differences across all 45 rows vs CLI `--json`).
  - Row 9: Error handling (missing PDF, non-PDF bytes, blank textless PDF, empty/whitespace claim ->
           exit code 2, empty stdout under `--json`, clear reason on stderr).

Uses only the Python standard library; safe under `python3 -I`.
"""

from __future__ import annotations

import argparse
from collections import Counter
import csv
from dataclasses import dataclass, field
import gzip
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import zlib
from typing import Dict, List, Optional, Sequence, Set, Tuple

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import m4_word_overlap as m4wo  # noqa: E402

EVIDENCE_SCHEMA = "scholaros.evidence/1"
SEGMENTS_SCHEMA = "scholaros.pdf_segments/1"
ALLOWED_VERDICTS = {"FOUND", "NUMERIC_MISMATCH", "NOT_FOUND"}
VERDICT_EXIT_CODES = {
    "FOUND": 0,
    "NUMERIC_MISMATCH": 1,
    "NOT_FOUND": 3,
}

FORBIDDEN_ENTAILMENT_PATTERNS = [
    re.compile(r"\bentailment\b", re.IGNORECASE),
    re.compile(r"\bentails\b", re.IGNORECASE),
    re.compile(r"\bGROUNDED\b"),
    re.compile(r"蕴含"),
    re.compile(r"支持你的结论"),
    re.compile(r"支持这个结论"),
]


# ============================================================================
# 1. Pure Judgment & Coordinate Conversion Functions (Unit-Tested)
# ============================================================================


def strip_spaces_and_thousands_commas(text: str) -> str:
    """Normalize a numeric phrase by removing all whitespace and thousands-separator commas.

    Examples:
      '1,000 training samples' -> '1000trainingsamples'
      '1, 006 iterations'      -> '1006iterations'
      '13.92%'                 -> '13.92%'
    """
    no_space = re.sub(r"\s+", "", text)
    no_thousands = re.sub(r"(?<=\d),(?=\d)", "", no_space)
    return no_thousands.lower()


def discrepancies_match_ground_truth(
    discrepancies: Sequence[dict],
    ground_truth_numbers: Sequence[str],
) -> Tuple[bool, Optional[str]]:
    """Return (matched, matched_pair_desc) if any `discrepancies[].pdf_text` contains one of `ground_truth_numbers`.

    Comparison strips whitespace and thousands commas per the M4 acceptance specification.
    """
    if not discrepancies or not ground_truth_numbers:
        return False, None

    norm_targets = [
        (gt, strip_spaces_and_thousands_commas(gt))
        for gt in ground_truth_numbers
        if str(gt).strip()
    ]
    if not norm_targets:
        return False, None

    for disc in discrepancies:
        if not isinstance(disc, dict):
            continue
        pdf_text = disc.get("pdf_text")
        if not isinstance(pdf_text, str) or not pdf_text.strip():
            continue
        norm_pdf = strip_spaces_and_thousands_commas(pdf_text)
        for raw_gt, norm_gt in norm_targets:
            if norm_gt and norm_gt in norm_pdf:
                return True, f"pdf_text={pdf_text!r} contains gt={raw_gt!r}"
    return False, None


def validate_evidence_json_contract(payload: dict) -> List[str]:
    """Validate `scholaros.evidence/1` structural contract on a parsed CLI/MCP JSON object."""
    errors: List[str] = []
    if not isinstance(payload, dict):
        return ["top-level JSON is not an object"]
    if payload.get("schema") != EVIDENCE_SCHEMA:
        errors.append(f"expected schema={EVIDENCE_SCHEMA!r}, got {payload.get('schema')!r}")
    verdict = payload.get("verdict")
    if verdict not in ALLOWED_VERDICTS:
        errors.append(f"invalid verdict={verdict!r} (allowed: {sorted(ALLOWED_VERDICTS)})")
        return errors

    matches = payload.get("matches")
    if not isinstance(matches, list):
        errors.append("matches is not a list")
        return errors

    if verdict == "NOT_FOUND":
        if len(matches) != 0:
            errors.append(f"NOT_FOUND must have empty matches, got {len(matches)}")
        for forbidden_present in ("page", "page_index", "bounding_box", "excerpt"):
            if payload.get(forbidden_present) is not None:
                errors.append(f"NOT_FOUND must not populate {forbidden_present}")
    else:
        if len(matches) == 0:
            errors.append(f"{verdict} must have non-empty matches")
        page = payload.get("page")
        page_index = payload.get("page_index")
        bbox = payload.get("bounding_box")
        col = payload.get("column_index")
        sec = payload.get("section_title")
        exc = payload.get("excerpt")
        if not isinstance(page, int) or page < 1:
            errors.append(f"invalid 1-based page={page!r}")
        if not isinstance(page_index, int) or page_index < 0:
            errors.append(f"invalid 0-based page_index={page_index!r}")
        if isinstance(page, int) and isinstance(page_index, int) and page != page_index + 1:
            errors.append(f"page ({page}) != page_index + 1 ({page_index + 1})")
        if not isinstance(bbox, dict) or not all(isinstance(bbox.get(k), (int, float)) for k in ("x", "y", "width", "height")):
            errors.append(f"invalid bounding_box={bbox!r}")
        if not isinstance(col, int):
            errors.append(f"invalid column_index={col!r}")
        if not isinstance(sec, str) or not sec.strip():
            errors.append(f"invalid section_title={sec!r}")
        if not isinstance(exc, str) or not exc.strip():
            errors.append(f"invalid excerpt={exc!r}")

    return errors


def evaluate_claim_row(claim_spec: dict, cli_exit: int, payload: dict) -> dict:
    """Evaluate a single `claims.jsonl` row against its group's M4 acceptance rule."""
    cid = str(claim_spec["id"])
    group = str(claim_spec["group"])
    expected_pages = list(claim_spec.get("expected_pages") or [])
    gt_numbers = list(claim_spec.get("ground_truth_numbers") or [])

    contract_errors = validate_evidence_json_contract(payload)
    verdict = payload.get("verdict") if isinstance(payload, dict) else None
    page = payload.get("page") if isinstance(payload, dict) else None
    matches = payload.get("matches") if isinstance(payload, dict) else None
    discrepancies = payload.get("discrepancies") if isinstance(payload, dict) else []

    expected_exit = VERDICT_EXIT_CODES.get(str(verdict), -999)
    exit_matches_verdict = (cli_exit == expected_exit)

    reasons: List[str] = list(contract_errors)
    if not exit_matches_verdict:
        reasons.append(f"cli_exit={cli_exit} does not match verdict={verdict!r} (expected {expected_exit})")

    page_ok = False
    gt_num_ok = False
    gt_num_detail: Optional[str] = None

    if group == "grounded":
        if verdict != "FOUND":
            reasons.append(f"expected verdict='FOUND', got {verdict!r}")
        page_ok = isinstance(page, int) and page in expected_pages
        if not page_ok:
            reasons.append(f"page={page!r} not in expected_pages={expected_pages}")
        passed = (len(reasons) == 0)

    elif group == "numeric_mismatch":
        if verdict != "NUMERIC_MISMATCH":
            reasons.append(f"expected verdict='NUMERIC_MISMATCH', got {verdict!r}")
        page_ok = isinstance(page, int) and page in expected_pages
        if not page_ok:
            reasons.append(f"page={page!r} not in expected_pages={expected_pages}")
        gt_num_ok, gt_num_detail = discrepancies_match_ground_truth(
            discrepancies if isinstance(discrepancies, list) else [],
            gt_numbers,
        )
        if not gt_num_ok:
            pdf_texts = [d.get("pdf_text") for d in (discrepancies or []) if isinstance(d, dict)]
            reasons.append(
                f"discrepancies[].pdf_text={pdf_texts!r} did not contain any ground_truth_numbers={gt_numbers!r}"
            )
        passed = (len(reasons) == 0)

    elif group in {"not_mentioned", "sentinel"}:
        if verdict != "NOT_FOUND":
            reasons.append(f"expected verdict='NOT_FOUND', got {verdict!r}")
        if not isinstance(matches, list) or len(matches) != 0:
            reasons.append(f"expected matches=[], got count={len(matches) if isinstance(matches, list) else 'non-list'}")
        passed = (len(reasons) == 0)

    else:
        reasons.append(f"unknown claim group={group!r}")
        passed = False

    return {
        "id": cid,
        "paper_id": claim_spec.get("paper_id"),
        "group": group,
        "passed": passed,
        "verdict": verdict,
        "cli_exit": cli_exit,
        "page": page,
        "expected_pages": expected_pages,
        "page_ok": page_ok,
        "gt_num_ok": gt_num_ok,
        "gt_num_detail": gt_num_detail,
        "reasons": reasons,
    }


def pdf_box_to_tsv_rect(
    pdf_box: dict,
    page_height: float,
    page_min_x: float = 0.0,
    page_min_y: float = 0.0,
) -> Tuple[float, float, float, float]:
    """Convert PDF `mediaBox` coordinates (bottom-left origin) to `pdftotext -tsv` coordinates (top-left origin).

    Coordinate systems:
      - PDF `mediaBox`: origin at bottom-left `(page_min_x, page_min_y)`, X rightward, Y upward (in points).
        Rectangle `{x, y, width, height}` spans `[x, x + width] x [y, y + height]`.
      - Poppler `pdftotext -tsv`: origin at top-left `(0, 0)`, X rightward, Y downward (in points),
        page size `(page_width, page_height)`.
        Conversion:
          tsv_left   = x - page_min_x
          tsv_right  = (x + width) - page_min_x
          tsv_top    = page_height - ((y + height) - page_min_y)
          tsv_bottom = page_height - (y - page_min_y)
    """
    x = float(pdf_box["x"])
    y = float(pdf_box["y"])
    w = float(pdf_box["width"])
    h = float(pdf_box["height"])
    left = x - page_min_x
    right = (x + w) - page_min_x
    top = page_height - ((y + h) - page_min_y)
    bottom = page_height - (y - page_min_y)
    return (left, top, right, bottom)


def tsv_rect_to_pdf_box(
    tsv_rect: Tuple[float, float, float, float],
    page_height: float,
    page_min_x: float = 0.0,
    page_min_y: float = 0.0,
) -> dict:
    """Inverse conversion: `pdftotext -tsv` `(left, top, right, bottom)` -> PDF bottom-left `{x, y, width, height}`."""
    left, top, right, bottom = tsv_rect
    width = right - left
    height = bottom - top
    x = left + page_min_x
    y = (page_height - bottom) + page_min_y
    return {"x": x, "y": y, "width": width, "height": height}


def expand_tsv_rect(
    rect: Tuple[float, float, float, float],
    pad_pt: float = 4.0,
) -> Tuple[float, float, float, float]:
    """Expand `(left, top, right, bottom)` outward by `pad_pt` points on all four sides."""
    left, top, right, bottom = rect
    return (left - pad_pt, top - pad_pt, right + pad_pt, bottom + pad_pt)


@dataclass
class TSVWord:
    index: int
    par_num: int
    block_num: int
    line_num: int
    word_num: int
    left: float
    top: float
    width: float
    height: float
    text: str
    tokens: List[str] = field(default_factory=list)

    @property
    def right(self) -> float:
        return self.left + self.width

    @property
    def bottom(self) -> float:
        return self.top + self.height

    @property
    def center_x(self) -> float:
        return self.left + 0.5 * self.width

    @property
    def center_y(self) -> float:
        return self.top + 0.5 * self.height


@dataclass
class TSVPageData:
    page_num: int
    left: float
    top: float
    width: float
    height: float
    words: List[TSVWord] = field(default_factory=list)


def _alnum_tokens(raw: str) -> List[str]:
    return [m.group(0).lower() for m in re.finditer(r"[A-Za-z0-9]+", raw)]


def parse_pdftotext_tsv_pages(tsv_text: str) -> Dict[int, TSVPageData]:
    """Parse `pdftotext -tsv` content into per-page dimensions and ordered word boxes."""
    pages: Dict[int, TSVPageData] = {}
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
            word_num = int(cols[5])
            left = float(cols[6])
            top = float(cols[7])
            width = float(cols[8])
            height = float(cols[9])
        except ValueError:
            continue
        text_col = cols[11]

        if level == 1:
            pages[page_num] = TSVPageData(
                page_num=page_num,
                left=left,
                top=top,
                width=max(1.0, width),
                height=max(1.0, height),
                words=[],
            )
        elif level == 5:
            if not text_col or text_col in {"###PAGE###", "###FLOW###", "###LINE###"}:
                continue
            pdata = pages.setdefault(
                page_num,
                TSVPageData(page_num=page_num, left=0.0, top=0.0, width=612.0, height=792.0, words=[]),
            )
            toks = _alnum_tokens(text_col)
            pdata.words.append(
                TSVWord(
                    index=len(pdata.words),
                    par_num=par_num,
                    block_num=block_num,
                    line_num=line_num,
                    word_num=word_num,
                    left=left,
                    top=top,
                    width=width,
                    height=height,
                    text=text_col,
                    tokens=toks,
                )
            )

    # Attach dehyphenated joined token when a line ends with a hyphenated word and next word starts lowercase
    for pdata in pages.values():
        wlist = pdata.words
        for i in range(len(wlist) - 1):
            cur_w = wlist[i]
            nxt_w = wlist[i + 1]
            same_line = (
                cur_w.par_num == nxt_w.par_num
                and cur_w.block_num == nxt_w.block_num
                and cur_w.line_num == nxt_w.line_num
            )
            if not same_line and cur_w.text.endswith("-") and len(cur_w.text) >= 2:
                stem_match = re.search(r"([A-Za-z]+)-$", cur_w.text)
                tail_match = re.match(r"^([a-z][A-Za-z0-9]*)", nxt_w.text)
                if stem_match and tail_match:
                    joined = (stem_match.group(1) + tail_match.group(1)).lower()
                    if joined not in cur_w.tokens:
                        cur_w.tokens.append(joined)
                    if joined not in nxt_w.tokens:
                        nxt_w.tokens.append(joined)

    return pages


def find_best_passage_words(page_data: TSVPageData, excerpt: str) -> Tuple[List[TSVWord], float]:
    """Locate the contiguous word span on `page_data` matching `excerpt` purely from lexical tokens.

    Does NOT inspect `bounding_box`, keeping the target word selection independent of the box under test.
    """
    words = page_data.words
    if not words:
        return [], 0.0

    exc_tokens = _alnum_tokens(m4wo.dehyphenate_text(excerpt))
    if not exc_tokens:
        return [], 0.0

    exc_counter = Counter(exc_tokens)
    exc_total = len(exc_tokens)
    exc_vocab = set(exc_counter.keys())

    # Estimate number of TSV words corresponding to `excerpt`
    approx_words = max(1, len(excerpt.split()))
    min_len = max(1, int(approx_words * 0.45))
    max_len = min(len(words), max(approx_words + 16, int(approx_words * 1.75)))
    if min_len > len(words):
        min_len = 1
        max_len = len(words)

    best_f1 = -1.0
    best_span = (0, min(len(words), approx_words))

    candidate_starts = [
        i for i, w in enumerate(words)
        if any(t in exc_vocab for t in w.tokens)
    ]
    if not candidate_starts:
        return [], 0.0

    for s in candidate_starts:
        upper_e = min(len(words), s + max_len)
        lower_e = min(upper_e, s + min_len)
        if lower_e <= s:
            continue

        win_counter: Counter = Counter()
        win_tok_total = 0
        matched = 0

        for idx in range(s, upper_e):
            # Primary token(s) of word `idx`: count each token up to once per word occurrence
            wtoks = words[idx].tokens
            for t in wtoks:
                prev = win_counter[t]
                win_counter[t] = prev + 1
                win_tok_total += 1
                if prev < exc_counter[t]:
                    matched += 1

            cur_e = idx + 1
            if cur_e >= lower_e and win_tok_total > 0:
                f1 = (2.0 * matched) / (win_tok_total + exc_total)
                if f1 > best_f1:
                    best_f1 = f1
                    best_span = (s, cur_e)

    # Trim leading/trailing TSV words that share zero tokens with `excerpt`
    b_start, b_end = best_span
    while b_start < b_end and not any(t in exc_vocab for t in words[b_start].tokens):
        b_start += 1
    while b_end > b_start and not any(t in exc_vocab for t in words[b_end - 1].tokens):
        b_end -= 1

    return words[b_start:b_end], max(0.0, best_f1)


def is_tsv_word_covered_by_rect(word: TSVWord, exp_rect: Tuple[float, float, float, float]) -> bool:
    """Check whether `word` falls inside the +4pt expanded TSV rectangle `(left, top, right, bottom)`.

    A word is covered when its bounding box lies inside `exp_rect` (or its center lies inside `exp_rect`
    when Poppler reports an oversized ligature/math glyph box while >= 50% of its horizontal span is inside).
    """
    exp_left, exp_top, exp_right, exp_bottom = exp_rect
    eps = 1e-6
    if (
        word.left >= exp_left - eps
        and word.right <= exp_right + eps
        and word.top >= exp_top - eps
        and word.bottom <= exp_bottom + eps
    ):
        return True
    # Also accept word coordinate center inside `exp_rect` ("覆盖该段落至少 80% 的词坐标点")
    if (
        exp_left - eps <= word.center_x <= exp_right + eps
        and exp_top - eps <= word.center_y <= exp_bottom + eps
    ):
        return True
    return False


def evaluate_bounding_box_on_tsv_page(
    pdf_box: dict,
    page_data: TSVPageData,
    excerpt: str,
    pad_pt: float = 4.0,
    min_word_coverage: float = 0.80,
    max_page_area_ratio: float = 0.90,
) -> dict:
    """Evaluate Row 5 geometric truth of `pdf_box` against `page_data` (`pdftotext -tsv`)."""
    reasons: List[str] = []
    bx = float(pdf_box.get("x", 0.0))
    by = float(pdf_box.get("y", 0.0))
    bw = float(pdf_box.get("width", 0.0))
    bh = float(pdf_box.get("height", 0.0))

    pw = page_data.width
    ph = page_data.height
    p_min_x = page_data.left
    p_min_y = page_data.top

    positive_size = (bw > 0.0 and bh > 0.0)
    if not positive_size:
        reasons.append(f"non-positive box dimensions width={bw}, height={bh}")

    bounds_eps = 1.0
    inside_page = (
        bx >= p_min_x - bounds_eps
        and by >= p_min_y - bounds_eps
        and (bx + bw) <= (p_min_x + pw + bounds_eps)
        and (by + bh) <= (p_min_y + ph + bounds_eps)
    )
    if not inside_page:
        reasons.append(
            f"box ({bx:.2f}, {by:.2f}, {bw:.2f}x{bh:.2f}) falls outside page mediaBox "
            f"({p_min_x:.2f}, {p_min_y:.2f}, {pw:.2f}x{ph:.2f})"
        )

    page_area = max(1.0, pw * ph)
    area_ratio = (max(0.0, bw) * max(0.0, bh)) / page_area
    not_full_page = (area_ratio < max_page_area_ratio)
    if not not_full_page:
        reasons.append(
            f"degenerate full-page bounding_box: area_ratio={area_ratio:.4f} >= {max_page_area_ratio:.2f}"
        )

    tsv_rect = pdf_box_to_tsv_rect(pdf_box, page_height=ph, page_min_x=p_min_x, page_min_y=p_min_y)
    exp_rect = expand_tsv_rect(tsv_rect, pad_pt=pad_pt)

    passage_words, align_f1 = find_best_passage_words(page_data, excerpt)
    if not passage_words:
        reasons.append("could not align excerpt words on expected_pdftotext page")
        word_cov = 0.0
        covered_count = 0
    else:
        covered_count = sum(1 for w in passage_words if is_tsv_word_covered_by_rect(w, exp_rect))
        word_cov = covered_count / len(passage_words)
        if word_cov + 1e-12 < min_word_coverage:
            reasons.append(
                f"word_coverage={word_cov * 100.0:.2f}% ({covered_count}/{len(passage_words)}) "
                f"< required {min_word_coverage * 100.0:.1f}%"
            )

    return {
        "passed": len(reasons) == 0,
        "positive_size": positive_size,
        "inside_page": inside_page,
        "not_full_page": not_full_page,
        "area_ratio": area_ratio,
        "tsv_rect": tsv_rect,
        "expanded_tsv_rect": exp_rect,
        "passage_word_count": len(passage_words),
        "covered_word_count": covered_count,
        "word_coverage": word_cov,
        "alignment_f1": align_f1,
        "reasons": reasons,
    }


# ============================================================================
# 2. Row 6 Segmentation Quality Verification
# ============================================================================


def extract_tsv_margin_header_footer_records(tsv_text: str) -> Tuple[Dict[int, float], List[dict]]:
    """Identify per-page repeating headers/footers and standalone margin page numbers from `pdftotext -tsv`."""
    page_heights: Dict[int, float] = {}
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
        elif level in (4, 5):
            key = (page_num, par_num, block_num, line_num)
            if key not in lines_by_key:
                lines_by_key[key] = {"page": page_num, "top": top, "bottom": top + height, "words": []}
                line_order.append(key)
            if level == 5 and text_col and text_col not in {"###PAGE###", "###FLOW###", "###LINE###"}:
                lines_by_key[key]["words"].append(text_col)

    total_pages = max(page_heights.keys(), default=0)
    lines_per_page: Dict[int, List[dict]] = {}
    for key in line_order:
        rec = lines_by_key[key]
        if rec["words"]:
            rec["text"] = " ".join(rec["words"])
            lines_per_page.setdefault(rec["page"], []).append(rec)

    top_tpl_pages: Dict[str, Set[int]] = {}
    bot_tpl_pages: Dict[str, Set[int]] = {}
    for pnum, plines in lines_per_page.items():
        ph = page_heights.get(pnum, 792.0)
        top_cut = m4wo.MARGIN_BAND_RATIO * ph
        bot_cut = (1.0 - m4wo.MARGIN_BAND_RATIO) * ph
        for ln in plines:
            if ln["bottom"] <= top_cut:
                tpl = m4wo.normalize_margin_template(ln["text"])
                if tpl:
                    top_tpl_pages.setdefault(tpl, set()).add(pnum)
            if ln["top"] >= bot_cut:
                tpl = m4wo.normalize_margin_template(ln["text"])
                if tpl:
                    bot_tpl_pages.setdefault(tpl, set()).add(pnum)

    records: List[dict] = []
    for pnum, plines in sorted(lines_per_page.items()):
        ph = page_heights.get(pnum, 792.0)
        top_cut = m4wo.MARGIN_BAND_RATIO * ph
        bot_cut = (1.0 - m4wo.MARGIN_BAND_RATIO) * ph
        top_pg_cut = m4wo.STANDALONE_PAGENUM_BAND_RATIO * ph
        bot_pg_cut = (1.0 - m4wo.STANDALONE_PAGENUM_BAND_RATIO) * ph

        interior = [ln for ln in plines if ln["bottom"] > top_cut and ln["top"] < bot_cut]
        interior_min_top = min((ln["top"] for ln in interior), default=None)
        interior_max_bot = max((ln["bottom"] for ln in interior), default=None)

        for ln in plines:
            if ln["bottom"] <= top_cut:
                tpl = m4wo.normalize_margin_template(ln["text"])
                repeats = total_pages >= 2 and tpl is not None and len(top_tpl_pages.get(tpl, set())) >= 2
                isolated_pg = (
                    ln["bottom"] <= top_pg_cut
                    and m4wo.is_standalone_page_number(ln["text"])
                    and (interior_min_top is None or (interior_min_top - ln["bottom"]) >= m4wo.STANDALONE_PAGENUM_MIN_GAP_PT)
                )
                if repeats or isolated_pg:
                    records.append({"page": pnum, "band": "top", "text": ln["text"], "top": ln["top"], "bottom": ln["bottom"]})
                    continue

            if ln["top"] >= bot_cut:
                tpl = m4wo.normalize_margin_template(ln["text"])
                repeats = total_pages >= 2 and tpl is not None and len(bot_tpl_pages.get(tpl, set())) >= 2
                isolated_pg = (
                    ln["top"] >= bot_pg_cut
                    and m4wo.is_standalone_page_number(ln["text"])
                    and (interior_max_bot is None or (ln["top"] - interior_max_bot) >= m4wo.STANDALONE_PAGENUM_MIN_GAP_PT)
                )
                if repeats or isolated_pg:
                    records.append({"page": pnum, "band": "bottom", "text": ln["text"], "top": ln["top"], "bottom": ln["bottom"]})
    return page_heights, records


def evaluate_segmentation_report(
    report: dict,
    tsv_text: Optional[str] = None,
    require_references_heading: bool = True,
    known_forbidden_body_substrings: Sequence[str] = (),
) -> dict:
    """Evaluate `segment-pdf --json` output for Row 6."""
    reasons: List[str] = []
    if report.get("schema") != SEGMENTS_SCHEMA:
        reasons.append(f"expected schema={SEGMENTS_SCHEMA!r}, got {report.get('schema')!r}")

    chunks = report.get("chunks")
    if not isinstance(chunks, list) or not chunks:
        return {
            "passed": False,
            "header_footer_leaks": [],
            "has_intro": False,
            "has_references": False,
            "column_order_ok": False,
            "reasons": ["chunks list is missing or empty"],
        }

    # 1. Check no repeating header/footer leaks into `body` chunks
    leaks: List[str] = []
    body_chunks = [c for c in chunks if isinstance(c, dict) and c.get("kind") == "body"]
    for c in body_chunks:
        txt = str(c.get("text", ""))
        low_txt = " ".join(txt.lower().split())
        for sub in known_forbidden_body_substrings:
            if sub.lower() in low_txt:
                leaks.append(f"p.{c.get('page')} body contains {sub!r}")

    if tsv_text is not None:
        page_heights, margin_recs = extract_tsv_margin_header_footer_records(tsv_text)
        recs_by_page: Dict[int, List[dict]] = {}
        for r in margin_recs:
            recs_by_page.setdefault(r["page"], []).append(r)

        for c in body_chunks:
            pnum = int(c.get("page", 0))
            if pnum not in recs_by_page:
                continue
            ph = page_heights.get(pnum, 792.0)
            bbox = c.get("bounding_box") or {}
            c_left, c_top, c_right, c_bot = pdf_box_to_tsv_rect(bbox, page_height=ph)
            c_norm = " ".join(str(c.get("text", "")).lower().split())
            c_nospace = re.sub(r"\s+", "", c_norm)

            for mr in recs_by_page[pnum]:
                # Require vertical overlap with the actual margin line [mr['top'], mr['bottom']] (+4pt tolerance)
                if not (c_top <= mr["bottom"] + 4.0 and c_bot >= mr["top"] - 4.0):
                    continue
                mr_norm = " ".join(mr["text"].lower().split())
                mr_nospace = re.sub(r"\s+", "", mr_norm)
                if not mr_nospace:
                    continue

                matched_leak = False
                if len(mr_nospace) <= 4:
                    # Short standalone page number (e.g. '1', '12', 'iv'): match exact chunk or leading/trailing edge token
                    if (
                        c_norm == mr_norm
                        or (mr["band"] == "top" and c_norm.startswith(mr_norm + " "))
                        or (mr["band"] == "bottom" and c_norm.endswith(" " + mr_norm))
                    ):
                        matched_leak = True
                else:
                    if mr_norm in c_norm or mr_nospace in c_nospace:
                        matched_leak = True

                if matched_leak:
                    leaks.append(f"p.{pnum} ({mr['band']} margin) leaked {mr['text']!r} into body chunk {c.get('id')}")

    if leaks:
        reasons.append(f"{len(leaks)} header/footer leak(s) into body chunks (e.g. {leaks[0]})")

    # 2. Check Introduction and References headings
    heading_texts = [
        str(c.get("text", ""))
        for c in chunks
        if isinstance(c, dict) and c.get("kind") == "section_heading"
    ]
    has_intro = any(re.search(r"\bintroduction\b", h, re.IGNORECASE) for h in heading_texts)
    has_refs = any(
        re.search(r"\b(references|bibliography|literature\s+cited)\b", h, re.IGNORECASE)
        for h in heading_texts
    )
    if not has_intro:
        reasons.append(f"Introduction heading not recognized (headings={heading_texts[:8]})")
    if require_references_heading and not has_refs:
        reasons.append(f"References/Bibliography heading not recognized (headings={heading_texts[-8:]})")

    # 3. Check two-column reading order below spanning floats (within every two-column band, col 1 precedes col 2)
    column_order_ok = True
    chunks_by_page: Dict[int, List[dict]] = {}
    for c in sorted(chunks, key=lambda x: int(x.get("reading_sequence", 0))):
        if c.get("kind") in {"header", "footer"}:
            continue
        chunks_by_page.setdefault(int(c.get("page", 0)), []).append(c)

    for pnum, pchunks in sorted(chunks_by_page.items()):
        # Split page chunks by spanning (column_index == 0) chunks into vertical prose bands
        current_band: List[dict] = []
        bands: List[List[dict]] = []
        has_spanning_float = False
        for c in pchunks:
            if int(c.get("column_index", 0)) == 0:
                if c.get("kind") == "table_or_figure":
                    has_spanning_float = True
                if current_band:
                    bands.append(current_band)
                    current_band = []
            else:
                current_band.append(c)
        if current_band:
            bands.append(current_band)

        if has_spanning_float:
            for band in bands:
                col1_seqs = [int(c["reading_sequence"]) for c in band if int(c.get("column_index", 0)) == 1]
                col2_seqs = [int(c["reading_sequence"]) for c in band if int(c.get("column_index", 0)) == 2]
                if col1_seqs and col2_seqs and max(col1_seqs) > min(col2_seqs):
                    column_order_ok = False
                    reasons.append(
                        f"p.{pnum} column order interleaved below/around spanning float: "
                        f"col1={col1_seqs} vs col2={col2_seqs}"
                    )

    # Explicit fixture anchor checks when running on `s12_paper.pdf` or `s12_wide_table_fig_cols.pdf`
    pdf_name = str(report.get("pdf_file", ""))
    if pdf_name == "s12_paper.pdf":
        p3_body = [c for c in body_chunks if int(c.get("page", 0)) == 3]
        left_seqs = [int(c["reading_sequence"]) for c in p3_body if "PAGE3_LEFT_1" in str(c.get("text", ""))]
        right_seqs = [int(c["reading_sequence"]) for c in p3_body if "PAGE3_RIGHT_1" in str(c.get("text", ""))]
        mixed = any("PAGE3_LEFT_1" in str(c.get("text", "")) and "PAGE3_RIGHT_1" in str(c.get("text", "")) for c in p3_body)
        if not left_seqs or not right_seqs or mixed or max(left_seqs) >= min(right_seqs):
            column_order_ok = False
            reasons.append(f"s12_paper.pdf Page 3 left/right order failed (left={left_seqs}, right={right_seqs}, mixed={mixed})")
    elif pdf_name == "s12_wide_table_fig_cols.pdf":
        p2_non_hf = [c for c in chunks if int(c.get("page", 0)) == 2 and c.get("kind") not in {"header", "footer"}]
        p2_floats = [c for c in p2_non_hf if c.get("kind") == "table_or_figure"]
        p2_col1 = [int(c["reading_sequence"]) for c in p2_non_hf if int(c.get("column_index", 0)) == 1]
        p2_col2 = [int(c["reading_sequence"]) for c in p2_non_hf if int(c.get("column_index", 0)) == 2]
        if len(p2_floats) < 2 or not p2_col1 or not p2_col2 or max(p2_col1) >= min(p2_col2):
            column_order_ok = False
            reasons.append(
                f"s12_wide_table_fig_cols.pdf Page 2 lower two-column order failed "
                f"(floats={len(p2_floats)}, col1={p2_col1}, col2={p2_col2})"
            )

    return {
        "passed": len(reasons) == 0,
        "pdf_file": pdf_name,
        "chunk_count": len(chunks),
        "heading_count": len(heading_texts),
        "header_footer_leak_count": len(leaks),
        "header_footer_leaks": leaks,
        "has_intro": has_intro,
        "has_references": has_refs,
        "column_order_ok": column_order_ok,
        "reasons": reasons,
    }


# ============================================================================
# 3. CLI / MCP Execution Helpers for `m4-acceptance.sh`
# ============================================================================


def _isolated_env(sandbox_home: str) -> Dict[str, str]:
    env = dict(os.environ)
    env["HOME"] = sandbox_home
    env["CFFIXED_USER_HOME"] = sandbox_home
    env.pop("SCHOLAR_CACHE_DIR", None)
    pathlib.Path(sandbox_home, "Library", "Preferences").mkdir(parents=True, exist_ok=True)
    return env


def run_cli(cli_bin: str, args: Sequence[str], sandbox_home: str) -> Tuple[int, str, str, float]:
    t0 = time.perf_counter()
    proc = subprocess.run(
        [cli_bin, *args],
        env=_isolated_env(sandbox_home),
        capture_output=True,
        text=True,
        check=False,
    )
    elapsed = time.perf_counter() - t0
    return proc.returncode, proc.stdout, proc.stderr, elapsed


def load_claims_jsonl(repo_root: pathlib.Path) -> List[dict]:
    claims_path = repo_root / "Benchmarks" / "evidence" / "claims.jsonl"
    rows: List[dict] = []
    with claims_path.open(encoding="utf-8") as f:
        for ln in f:
            ln = ln.strip()
            if ln:
                rows.append(json.loads(ln))
    return rows


def load_papers_tsv(repo_root: pathlib.Path) -> List[dict]:
    papers_path = repo_root / "Benchmarks" / "evidence" / "papers.tsv"
    with papers_path.open(encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def ensure_cli_claims_cache(
    repo_root: pathlib.Path,
    cli_bin: str,
    sandbox_home: str,
    cache_dir: pathlib.Path,
    groups: Optional[Set[str]] = None,
) -> Dict[str, dict]:
    """Run CLI `locate-evidence --offline --json` on requested claim groups, caching per-id outputs in `cache_dir`."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    claims = load_claims_jsonl(repo_root)
    results: Dict[str, dict] = {}
    for row in claims:
        if groups is not None and row["group"] not in groups:
            continue
        cid = row["id"]
        cache_file = cache_dir / f"{cid}.json"
        if cache_file.is_file():
            rec = json.loads(cache_file.read_text(encoding="utf-8"))
        else:
            pdf_path = repo_root / "Benchmarks" / "evidence" / "pdfs" / f"{row['paper_id']}.pdf"
            rc, out, err, elapsed = run_cli(
                cli_bin,
                ["locate-evidence", str(pdf_path), "--claim", row["claim"], "--offline", "--json"],
                sandbox_home,
            )
            try:
                parsed = json.loads(out) if out.strip() else None
            except Exception as exc:
                parsed = {"_parse_error": str(exc)}
            rec = {
                "id": cid,
                "exit_code": rc,
                "stdout": out,
                "stderr": err,
                "elapsed_s": elapsed,
                "payload": parsed,
            }
            cache_file.write_text(json.dumps(rec, ensure_ascii=False), encoding="utf-8")
        results[cid] = rec
    return results


def _find_forbidden_entailment_terms(text: str) -> List[str]:
    hits: List[str] = []
    for pat in FORBIDDEN_ENTAILMENT_PATTERNS:
        m = pat.search(text)
        if m:
            hits.append(m.group(0))
    return hits


def cmd_row1(repo_root: pathlib.Path, cli_bin: str, sandbox_home: str) -> int:
    fixture_pdf = repo_root / "Tests" / "Fixtures" / "pdf-segmentation" / "s12_paper.pdf"
    probes = [
        (
            "FOUND",
            0,
            "Our deterministic verifier completes static analysis across 368 regression tests in 14.5 ms on a single CPU core.",
        ),
        (
            "NUMERIC_MISMATCH",
            1,
            "Our deterministic verifier completes static analysis across 9999 regression tests in 14.5 ms on a single CPU core.",
        ),
        (
            "NOT_FOUND",
            3,
            "The moon is made of green cheese in our analysis.",
        ),
    ]

    ok = True
    # 1. Check --help in en and zh
    for lang in ("en", "zh"):
        rc, out, err, _ = run_cli(cli_bin, ["--lang", lang, "--help"], sandbox_home)
        if rc != 0 or "locate-evidence" not in out or "segment-pdf" not in out:
            print(f"  FAIL [Row 1]: --lang {lang} --help missing subcommands or nonzero exit={rc}")
            ok = False
        forbidden = _find_forbidden_entailment_terms(out + "\n" + err)
        if forbidden:
            print(f"  FAIL [Row 1]: --lang {lang} --help contains forbidden term(s): {forbidden}")
            ok = False

    # 2. Check CLI --json & human output + MCP locate_evidence on all 3 verdict states
    mcp_reqs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "m4-row1", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    ]
    for idx, (_, _, claim) in enumerate(probes, start=10):
        mcp_reqs.append({
            "jsonrpc": "2.0",
            "id": idx,
            "method": "tools/call",
            "params": {"name": "locate_evidence", "arguments": {"pdf_file": str(fixture_pdf), "claim": claim}},
        })

    mcp_proc = subprocess.run(
        [cli_bin, "mcp", "--offline"],
        input="\n".join(json.dumps(r) for r in mcp_reqs) + "\n",
        env=_isolated_env(sandbox_home),
        capture_output=True,
        text=True,
        check=False,
    )
    if mcp_proc.returncode != 0:
        print(f"  FAIL [Row 1]: scholaros mcp --offline exited {mcp_proc.returncode}")
        return 1

    resps = {obj.get("id"): obj for obj in (json.loads(ln) for ln in mcp_proc.stdout.splitlines() if ln.strip())}
    tools = ((resps.get(2) or {}).get("result") or {}).get("tools") or []
    le_tool = next((t for t in tools if t.get("name") == "locate_evidence"), None)
    if le_tool is None:
        print("  FAIL [Row 1]: MCP tools/list missing locate_evidence")
        return 1
    mcp_desc_forbidden = _find_forbidden_entailment_terms(json.dumps(le_tool, ensure_ascii=False))
    if mcp_desc_forbidden:
        print(f"  FAIL [Row 1]: MCP locate_evidence tool definition contains forbidden term(s): {mcp_desc_forbidden}")
        ok = False

    for idx, (exp_verdict, exp_exit, claim) in enumerate(probes, start=10):
        rc, out_json, err_json, _ = run_cli(
            cli_bin,
            ["locate-evidence", str(fixture_pdf), "--claim", claim, "--offline", "--json"],
            sandbox_home,
        )
        if rc != exp_exit:
            print(f"  FAIL [Row 1]: {exp_verdict} probe exit={rc}, expected {exp_exit}")
            ok = False
        payload = json.loads(out_json)
        errs = validate_evidence_json_contract(payload)
        if errs or payload.get("verdict") != exp_verdict:
            print(f"  FAIL [Row 1]: {exp_verdict} contract errors={errs}, verdict={payload.get('verdict')}")
            ok = False

        # Human output in en & zh must also have zero entailment/GROUNDED wording
        for lang in ("en", "zh"):
            rc_h, out_h, err_h, _ = run_cli(
                cli_bin,
                ["--lang", lang, "locate-evidence", str(fixture_pdf), "--claim", claim, "--offline"],
                sandbox_home,
            )
            if rc_h != exp_exit:
                print(f"  FAIL [Row 1]: human ({lang}) {exp_verdict} exit={rc_h}, expected {exp_exit}")
                ok = False
            forb_h = _find_forbidden_entailment_terms(out_h + "\n" + err_h)
            if forb_h:
                print(f"  FAIL [Row 1]: human ({lang}) output contains forbidden term(s): {forb_h}")
                ok = False

        # MCP response parity on probe
        mcp_res = (resps.get(idx) or {}).get("result") or {}
        mcp_text = ((mcp_res.get("content") or [{}])[0]).get("text", "")
        if mcp_res.get("isError") is not False or mcp_text.strip() != out_json.strip():
            print(f"  FAIL [Row 1]: MCP locate_evidence output differed from CLI --json for {exp_verdict}")
            ok = False

    print(
        "  schema=scholaros.evidence/1 verdicts=[FOUND(exit=0), NUMERIC_MISMATCH(exit=1), NOT_FOUND(exit=3)] "
        "entailment_terms_found=0 cli_mcp_probe_parity=3/3"
    )
    return 0 if ok else 1


def cmd_rows_2_3_4(
    row_num: int,
    repo_root: pathlib.Path,
    cli_bin: str,
    sandbox_home: str,
    cache_dir: pathlib.Path,
) -> int:
    claims = load_claims_jsonl(repo_root)
    if row_num == 2:
        target_groups = {"grounded"}
        min_pass = 8
    elif row_num == 3:
        target_groups = {"numeric_mismatch"}
        min_pass = 8
    elif row_num == 4:
        target_groups = {"not_mentioned", "sentinel"}
        min_pass = 25
    else:
        raise ValueError(f"Unsupported row_num={row_num}")

    selected = [c for c in claims if c["group"] in target_groups]
    cached = ensure_cli_claims_cache(repo_root, cli_bin, sandbox_home, cache_dir, groups=target_groups)

    passed_items = 0
    sub_counts: Counter = Counter()
    sub_totals: Counter = Counter()

    for c in selected:
        rec = cached[c["id"]]
        ev = evaluate_claim_row(c, rec["exit_code"], rec["payload"] or {})
        grp = c["group"]
        sub_totals[grp] += 1
        if ev["passed"]:
            passed_items += 1
            sub_counts[grp] += 1
            if row_num in (2, 3):
                extra = f", {ev['gt_num_detail']}" if ev["gt_num_detail"] else ""
                print(
                    f"  [PASS] {c['id']} ({c['paper_id']}): verdict={ev['verdict']} "
                    f"page={ev['page']} expected_pages={ev['expected_pages']}{extra}"
                )
        else:
            print(
                f"  [MISS] {c['id']} ({c['paper_id']}): verdict={ev['verdict']} "
                f"exit={ev['cli_exit']} page={ev['page']} expected_pages={ev['expected_pages']} "
                f"reasons={'; '.join(ev['reasons'])}"
            )

    total = len(selected)
    if row_num == 4:
        print(
            f"  not_mentioned={sub_counts['not_mentioned']}/{sub_totals['not_mentioned']} "
            f"sentinel={sub_counts['sentinel']}/{sub_totals['sentinel']} "
            f"total={passed_items}/{total} (required {min_pass}/{total}, 0 tolerance)"
        )
    else:
        print(f"  score={passed_items}/{total} (required >= {min_pass}/{total})")

    return 0 if passed_items >= min_pass else 1


def cmd_row5(
    repo_root: pathlib.Path,
    cli_bin: str,
    sandbox_home: str,
    cache_dir: pathlib.Path,
) -> int:
    claims = load_claims_jsonl(repo_root)
    papers = load_papers_tsv(repo_root)
    exp_dir = repo_root / "Benchmarks" / "evidence" / "expected_pdftotext"
    pdfs_dir = repo_root / "Benchmarks" / "evidence" / "pdfs"

    # Load stored expected_pdftotext/*.tsv.gz and compare live pdftotext -tsv when installed
    pdftotext_bin = m4wo.resolve_pdftotext_binary(None)
    pages_by_paper: Dict[str, Dict[int, TSVPageData]] = {}
    live_diffs = 0

    for p in papers:
        pid = p["paper_id"]
        gz_path = exp_dir / f"{pid}.tsv.gz"
        stored_tsv = gzip.decompress(gz_path.read_bytes()).decode("utf-8", errors="replace")
        pages_by_paper[pid] = parse_pdftotext_tsv_pages(stored_tsv)

        if pdftotext_bin is not None:
            pdf_path = pdfs_dir / f"{pid}.pdf"
            proc = subprocess.run([pdftotext_bin, "-tsv", str(pdf_path), "-"], capture_output=True, text=True, check=False)
            if proc.returncode == 0:
                if proc.stdout != stored_tsv:
                    live_diffs += 1
                    print(
                        f"  NOTE [Row 5]: live pdftotext -tsv differs from stored {pid}.tsv.gz "
                        f"(live_lines={len(proc.stdout.splitlines())} vs stored_lines={len(stored_tsv.splitlines())}); "
                        f"using frozen {pid}.tsv.gz as authoritative without overwriting."
                    )
            else:
                print(f"  NOTE [Row 5]: live pdftotext -tsv exited {proc.returncode} on {pid}; using frozen {pid}.tsv.gz.")

    if pdftotext_bin is not None:
        ver = m4wo.query_pdftotext_version(pdftotext_bin)
        print(f"  pdftotext_live_check=ran ({ver}, diffs_vs_stored={live_diffs}/5, authoritative=expected_pdftotext/*.tsv.gz)")
    else:
        print("  pdftotext_live_check=not_installed (using frozen expected_pdftotext/*.tsv.gz)")
    print(
        "  coord_transform: PDF mediaBox bottom-left (x, y, w, h) -> pdftotext -tsv top-left "
        "(left=x, top=H-(y+h), right=x+w, bottom=H-y), expanded by +4.0pt on all 4 sides"
    )

    target_claims = [c for c in claims if c["group"] in {"grounded", "numeric_mismatch"}]
    cached = ensure_cli_claims_cache(repo_root, cli_bin, sandbox_home, cache_dir, groups={"grounded", "numeric_mismatch"})

    eligible = 0
    box_passed = 0
    coverages: List[float] = []

    for c in target_claims:
        rec = cached[c["id"]]
        payload = rec.get("payload") or {}
        verdict = payload.get("verdict")
        page = payload.get("page")
        expected_pages = list(c.get("expected_pages") or [])

        # Row 5 checks every Row 2 / Row 3 result whose top match landed on `expected_pages`
        expected_verdict = "FOUND" if c["group"] == "grounded" else "NUMERIC_MISMATCH"
        if verdict != expected_verdict or not (isinstance(page, int) and page in expected_pages):
            continue

        eligible += 1
        pid = c["paper_id"]
        pdata = pages_by_paper[pid].get(page)
        if pdata is None:
            print(f"  FAIL [Row 5] {c['id']}: page {page} missing in {pid}.tsv.gz")
            continue

        res = evaluate_bounding_box_on_tsv_page(
            pdf_box=payload.get("bounding_box") or {},
            page_data=pdata,
            excerpt=str(payload.get("excerpt") or ""),
            pad_pt=4.0,
            min_word_coverage=0.80,
            max_page_area_ratio=0.90,
        )
        coverages.append(res["word_coverage"])
        if res["passed"]:
            box_passed += 1
            print(
                f"  [PASS] {c['id']} ({pid} p.{page}): word_cov={res['word_coverage'] * 100.0:.1f}% "
                f"({res['covered_word_count']}/{res['passage_word_count']}), area_ratio={res['area_ratio'] * 100.0:.1f}%"
            )
        else:
            print(
                f"  FAIL [Row 5] {c['id']} ({pid} p.{page}): {'; '.join(res['reasons'])}"
            )

    min_cov_pct = min(coverages) * 100.0 if coverages else 0.0
    print(
        f"  boxes_verified={box_passed}/{eligible} (min_word_coverage={min_cov_pct:.1f}%, required >= 80.0%)"
    )
    if eligible == 0 or box_passed != eligible:
        return 1
    return 0


def ensure_segmented_pdfs_cache(
    repo_root: pathlib.Path,
    cli_bin: str,
    sandbox_home: str,
    seg_cache_dir: pathlib.Path,
) -> Dict[str, dict]:
    """Run `scholaros segment-pdf <pdf> --offline --json` on the 5 benchmark papers + 5 synthetic fixtures."""
    seg_cache_dir.mkdir(parents=True, exist_ok=True)
    papers = load_papers_tsv(repo_root)

    targets: List[Tuple[str, pathlib.Path]] = []
    for p in papers:
        pid = p["paper_id"]
        targets.append((pid, repo_root / "Benchmarks" / "evidence" / "pdfs" / f"{pid}.pdf"))

    fixture_specs = [
        ("s12_paper", repo_root / "Tests" / "Fixtures" / "pdf-segmentation" / "s12_paper.pdf"),
        ("s12_ieeetran", repo_root / "Tests" / "Fixtures" / "pdf-segmentation" / "s12_ieeetran.pdf"),
        ("s12_acm_refs", repo_root / "Tests" / "Fixtures" / "pdf-segmentation" / "s12_acm_refs.pdf"),
        ("s12_math_columns", repo_root / "Tests" / "Fixtures" / "pdf-segmentation" / "s12_math_columns.pdf"),
        ("s12_wide_table_fig_cols", repo_root / "Tests" / "Fixtures" / "pdf-segmentation-02b" / "s12_wide_table_fig_cols.pdf"),
    ]
    targets.extend(fixture_specs)

    out_map: Dict[str, dict] = {}
    for key, pdf_path in targets:
        meta_file = seg_cache_dir / f"{key}.meta.json"
        chunks_file = seg_cache_dir / f"{key}.chunks.json"
        if meta_file.is_file() and chunks_file.is_file():
            meta = json.loads(meta_file.read_text(encoding="utf-8"))
            report = json.loads(chunks_file.read_text(encoding="utf-8"))
            meta["report"] = report
            meta["chunks_file"] = str(chunks_file)
            out_map[key] = meta
            continue

        rc, stdout, stderr, elapsed = run_cli(
            cli_bin,
            ["segment-pdf", str(pdf_path), "--offline", "--json"],
            sandbox_home,
        )
        chunks_file.write_text(stdout, encoding="utf-8")
        report = json.loads(stdout) if (rc == 0 and stdout.strip()) else {}
        meta = {
            "key": key,
            "pdf_name": pdf_path.name,
            "exit_code": rc,
            "stderr": stderr,
            "elapsed_s": elapsed,
        }
        meta_file.write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")
        meta["report"] = report
        meta["chunks_file"] = str(chunks_file)
        out_map[key] = meta
    return out_map


def cmd_row6(
    repo_root: pathlib.Path,
    cli_bin: str,
    sandbox_home: str,
    seg_cache_dir: pathlib.Path,
) -> int:
    seg_map = ensure_segmented_pdfs_cache(repo_root, cli_bin, sandbox_home, seg_cache_dir)
    papers = load_papers_tsv(repo_root)
    exp_dir = repo_root / "Benchmarks" / "evidence" / "expected_pdftotext"
    pdftotext_bin = m4wo.resolve_pdftotext_binary(None)

    ok = True
    bench_pass = 0
    for p in papers:
        pid = p["paper_id"]
        entry = seg_map[pid]
        if entry["exit_code"] != 0:
            print(f"  FAIL [Row 6] {pid}: segment-pdf exited {entry['exit_code']}")
            ok = False
            continue
        tsv_text = gzip.decompress((exp_dir / f"{pid}.tsv.gz").read_bytes()).decode("utf-8", errors="replace")
        ev = evaluate_segmentation_report(entry["report"], tsv_text=tsv_text, require_references_heading=True)
        if ev["passed"]:
            bench_pass += 1
            print(
                f"  [PASS] {pid}: chunks={ev['chunk_count']} headings={ev['heading_count']} "
                f"hf_leaks=0 intro={ev['has_intro']} refs={ev['has_references']} col_order_ok={ev['column_order_ok']}"
            )
        else:
            ok = False
            print(f"  FAIL [Row 6] {pid}: {'; '.join(ev['reasons'])}")

    fixture_configs = [
        (
            "s12_paper",
            repo_root / "Tests" / "Fixtures" / "pdf-segmentation" / "s12_paper.pdf",
            True,
            ["Journal of Reproducible Systems", "Lexical Grounding Study", "Preprint Under Review"],
        ),
        ("s12_ieeetran", repo_root / "Tests" / "Fixtures" / "pdf-segmentation" / "s12_ieeetran.pdf", True, []),
        ("s12_acm_refs", repo_root / "Tests" / "Fixtures" / "pdf-segmentation" / "s12_acm_refs.pdf", True, []),
        ("s12_math_columns", repo_root / "Tests" / "Fixtures" / "pdf-segmentation" / "s12_math_columns.pdf", True, []),
        (
            "s12_wide_table_fig_cols",
            repo_root / "Tests" / "Fixtures" / "pdf-segmentation-02b" / "s12_wide_table_fig_cols.pdf",
            False,
            [],
        ),
    ]

    fix_pass = 0
    for fkey, fpath, req_refs, forb_subs in fixture_configs:
        entry = seg_map[fkey]
        if entry["exit_code"] != 0:
            print(f"  FAIL [Row 6] {fkey}: segment-pdf exited {entry['exit_code']}")
            ok = False
            continue
        fix_tsv: Optional[str] = None
        if pdftotext_bin is not None:
            proc = subprocess.run([pdftotext_bin, "-tsv", str(fpath), "-"], capture_output=True, text=True, check=False)
            if proc.returncode == 0:
                fix_tsv = proc.stdout
        ev = evaluate_segmentation_report(
            entry["report"],
            tsv_text=fix_tsv,
            require_references_heading=req_refs,
            known_forbidden_body_substrings=forb_subs,
        )
        if ev["passed"]:
            fix_pass += 1
            print(
                f"  [PASS] fixture {fkey}: chunks={ev['chunk_count']} headings={ev['heading_count']} "
                f"hf_leaks=0 intro={ev['has_intro']} refs={ev['has_references']} col_order_ok={ev['column_order_ok']}"
            )
        else:
            ok = False
            print(f"  FAIL [Row 6] fixture {fkey}: {'; '.join(ev['reasons'])}")

    print(f"  benchmark_papers={bench_pass}/5 synthetic_fixtures={fix_pass}/5")
    return 0 if ok else 1


def _reconstruct_raw_text_from_tsv(tsv_text: str) -> str:
    """Fallback reconstruction of line-by-line text from stored `pdftotext -tsv` when `pdftotext` is absent."""
    lines_words: Dict[Tuple[int, int, int, int], List[str]] = {}
    order: List[Tuple[int, int, int, int]] = []
    for idx, raw_line in enumerate(tsv_text.splitlines()):
        if idx == 0 and raw_line.startswith("level\t"):
            continue
        cols = raw_line.split("\t")
        if len(cols) < 12:
            continue
        try:
            level = int(cols[0])
            key = (int(cols[1]), int(cols[2]), int(cols[3]), int(cols[4]))
        except ValueError:
            continue
        if level == 5 and cols[11] and cols[11] not in {"###PAGE###", "###FLOW###", "###LINE###"}:
            if key not in lines_words:
                lines_words[key] = []
                order.append(key)
            lines_words[key].append(cols[11])
    return "\n".join(" ".join(lines_words[k]) for k in order) + "\n"


def cmd_row7(
    repo_root: pathlib.Path,
    cli_bin: str,
    sandbox_home: str,
    seg_cache_dir: pathlib.Path,
) -> int:
    seg_map = ensure_segmented_pdfs_cache(repo_root, cli_bin, sandbox_home, seg_cache_dir)
    papers = load_papers_tsv(repo_root)
    exp_dir = repo_root / "Benchmarks" / "evidence" / "expected_pdftotext"
    pdfs_dir = repo_root / "Benchmarks" / "evidence" / "pdfs"
    pdftotext_bin = m4wo.resolve_pdftotext_binary(None)

    ok = True
    passed_papers = 0
    recalls: List[float] = []

    for p in papers:
        pid = p["paper_id"]
        entry = seg_map[pid]
        pdf_path = pdfs_dir / f"{pid}.pdf"
        elapsed_ms = entry["elapsed_s"] * 1000.0

        if entry["exit_code"] != 0:
            print(f"  FAIL [Row 7] {pid}: segment-pdf exited {entry['exit_code']}")
            ok = False
            continue

        if pdftotext_bin is not None:
            raw_proc = subprocess.run([pdftotext_bin, "-raw", str(pdf_path), "-"], capture_output=True, text=True, check=False)
            tsv_proc = subprocess.run([pdftotext_bin, "-tsv", str(pdf_path), "-"], capture_output=True, text=True, check=False)
            if raw_proc.returncode != 0 or tsv_proc.returncode != 0:
                print(f"  FAIL [Row 7] {pid}: pdftotext failed")
                ok = False
                continue
            metrics = m4wo.compute_word_overlap_metrics(raw_proc.stdout, tsv_proc.stdout, entry["report"])
            source_label = "live_pdftotext"
        else:
            stored_tsv = gzip.decompress((exp_dir / f"{pid}.tsv.gz").read_bytes()).decode("utf-8", errors="replace")
            raw_from_tsv = _reconstruct_raw_text_from_tsv(stored_tsv)
            metrics = m4wo.compute_word_overlap_metrics(raw_from_tsv, stored_tsv, entry["report"])
            source_label = "expected_pdftotext_tsv_gz"

        rec_pct = metrics["multiset_recall"] * 100.0
        recalls.append(rec_pct)
        if metrics["multiset_recall"] + 1e-12 >= 0.95:
            passed_papers += 1
            print(
                f"  [PASS] {pid}: word_overlap={rec_pct:.2f}% "
                f"({metrics['matched_words']}/{metrics['reference_words']} words) "
                f"segment_time={elapsed_ms:.1f}ms ref={source_label}"
            )
        else:
            ok = False
            print(
                f"  FAIL [Row 7] {pid}: word_overlap={rec_pct:.2f}% < 95.00% "
                f"({metrics['matched_words']}/{metrics['reference_words']} words) "
                f"segment_time={elapsed_ms:.1f}ms"
            )

    min_rec = min(recalls) if recalls else 0.0
    print(f"  papers_passed={passed_papers}/5 min_word_overlap={min_rec:.2f}% (required >= 95.00%)")
    return 0 if ok else 1


def cmd_row8(
    repo_root: pathlib.Path,
    cli_bin: str,
    sandbox_home: str,
    cache_dir: pathlib.Path,
) -> int:
    claims = load_claims_jsonl(repo_root)
    cli_cached = ensure_cli_claims_cache(repo_root, cli_bin, sandbox_home, cache_dir, groups=None)
    pdfs_dir = repo_root / "Benchmarks" / "evidence" / "pdfs"
    sample_pdf = pdfs_dir / f"{claims[0]['paper_id']}.pdf"

    reqs: List[dict] = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "m4-acceptance", "version": "1.0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        # Deleted tool must return -32602
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "scholar_search_provenance", "arguments": {"query": "test"}}},
        # Unknown argument must return isError=true + ERR_INVALID_ARGUMENT
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "locate_evidence", "arguments": {"pdf_file": str(sample_pdf), "claim": "test claim", "unknown_flag": True}}},
        {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "locate_evidence", "arguments": {"pdf_file": str(sample_pdf), "claim": "test claim", "registryReplayPath": "/tmp/fake"}}},
    ]

    for idx, c in enumerate(claims, start=100):
        pdf_path = pdfs_dir / f"{c['paper_id']}.pdf"
        reqs.append({
            "jsonrpc": "2.0",
            "id": idx,
            "method": "tools/call",
            "params": {
                "name": "locate_evidence",
                "arguments": {"pdf_file": str(pdf_path), "claim": c["claim"]},
            },
        })

    proc = subprocess.run(
        [cli_bin, "mcp", "--offline"],
        input="\n".join(json.dumps(r, ensure_ascii=False) for r in reqs) + "\n",
        env=_isolated_env(sandbox_home),
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        print(f"  FAIL [Row 8]: scholaros mcp --offline exited {proc.returncode}")
        return 1

    resps = {obj.get("id"): obj for obj in (json.loads(ln) for ln in proc.stdout.splitlines() if ln.strip())}
    ok = True

    # 1. tools/list check
    tools = ((resps.get(2) or {}).get("result") or {}).get("tools") or []
    tool_names = [t.get("name") for t in tools]
    expected_5 = {
        "verify_citation",
        "add_verified_bibtex",
        "check_manuscript",
        "scholar_verify_bibliography",
        "locate_evidence",
    }
    if len(tools) != 5 or set(tool_names) != expected_5:
        print(f"  FAIL [Row 8]: expected 5 default tools {sorted(expected_5)}, got {tool_names}")
        ok = False
    if "scholar_search_provenance" in tool_names:
        print("  FAIL [Row 8]: scholar_search_provenance still present in tools/list")
        ok = False

    le_schema = next((t.get("inputSchema") for t in tools if t.get("name") == "locate_evidence"), {}) or {}
    props = sorted((le_schema.get("properties") or {}).keys())
    req_props = sorted(le_schema.get("required") or [])
    if props != ["claim", "pdf_file", "top_k"] or req_props != ["claim", "pdf_file"]:
        print(f"  FAIL [Row 8]: locate_evidence schema mismatch props={props} required={req_props}")
        ok = False

    # 2. Deleted scholar_search_provenance -> -32602
    del_err = (resps.get(3) or {}).get("error") or {}
    if del_err.get("code") != -32602:
        print(f"  FAIL [Row 8]: scholar_search_provenance expected -32602, got {resps.get(3)}")
        ok = False

    # 3. Unknown argument -> isError=true & ERR_INVALID_ARGUMENT
    for bad_id in (4, 5):
        r_bad = (resps.get(bad_id) or {}).get("result") or {}
        txt_bad = ((r_bad.get("content") or [{}])[0]).get("text", "")
        try:
            obj_bad = json.loads(txt_bad)
        except Exception:
            obj_bad = {}
        if r_bad.get("isError") is not True or obj_bad.get("error_code") != "ERR_INVALID_ARGUMENT":
            print(f"  FAIL [Row 8]: request id={bad_id} did not return isError=true + ERR_INVALID_ARGUMENT: {r_bad}")
            ok = False

    # 4. Compare all 45 claims MCP vs CLI --json
    diffs = 0
    for idx, c in enumerate(claims, start=100):
        cid = c["id"]
        cli_out = cli_cached[cid]["stdout"].strip()
        cli_obj = cli_cached[cid]["payload"]

        mcp_res = (resps.get(idx) or {}).get("result") or {}
        mcp_txt = (((mcp_res.get("content") or [{}])[0]).get("text") or "").strip()
        try:
            mcp_obj = json.loads(mcp_txt) if mcp_txt else None
        except Exception:
            mcp_obj = None

        if mcp_res.get("isError") is not False or mcp_obj != cli_obj or mcp_txt != cli_out:
            diffs += 1
            if diffs <= 5:
                print(
                    f"  FAIL [Row 8] diff on {cid}: cli_verdict={(cli_obj or {}).get('verdict')} "
                    f"vs mcp_verdict={(mcp_obj or {}).get('verdict')} isError={mcp_res.get('isError')}"
                )

    if diffs > 0:
        ok = False

    print(
        f"  default_tools={len(tools)} has_locate_evidence={'locate_evidence' in tool_names} "
        f"has_scholar_search_provenance={'scholar_search_provenance' in tool_names} "
        f"unknown_arg=ERR_INVALID_ARGUMENT cli_vs_mcp_diffs={diffs}/{len(claims)}"
    )
    return 0 if ok else 1


def _build_minimal_blank_pdf_bytes() -> bytes:
    """Construct a valid 1-page empty PDF (`%PDF-1.4`) with 0 text operators for blank-PDF error testing."""
    objs = [
        b"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
        b"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
        b"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>\nendobj\n",
        b"4 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n",
    ]
    header = b"%PDF-1.4\n"
    offsets: List[int] = []
    body = bytearray(header)
    for o in objs:
        offsets.append(len(body))
        body.extend(o)
    xref_pos = len(body)
    xref = [f"xref\n0 {len(objs) + 1}\n", "0000000000 65535 f \n"]
    for off in offsets:
        xref.append(f"{off:010d} 00000 n \n")
    trailer = (
        "".join(xref).encode("ascii")
        + f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref_pos}\n%%EOF\n".encode("ascii")
    )
    return bytes(body) + trailer


def cmd_row9(repo_root: pathlib.Path, cli_bin: str, sandbox_home: str) -> int:
    valid_pdf = repo_root / "Tests" / "Fixtures" / "pdf-segmentation" / "s12_paper.pdf"
    ok = True
    checks_run = 0
    checks_passed = 0

    with tempfile.TemporaryDirectory(prefix="m4-row9-") as tmp:
        tmp_dir = pathlib.Path(tmp)
        missing_pdf = tmp_dir / "does-not-exist.pdf"
        not_pdf = tmp_dir / "not-a-pdf.pdf"
        not_pdf.write_bytes(b"This is plain UTF-8 text, not a PDF file.\n")
        corrupt_pdf = tmp_dir / "corrupt-header.pdf"
        corrupt_pdf.write_bytes(b"%PDF-1.4\n\x00\xffTHIS_IS_CORRUPT_NOT_XREF\n")
        blank_pdf = tmp_dir / "blank.pdf"
        blank_pdf.write_bytes(_build_minimal_blank_pdf_bytes())

        cases = [
            ("missing_file_json", ["locate-evidence", str(missing_pdf), "--claim", "test claim", "--offline", "--json"], True),
            ("missing_file_text", ["locate-evidence", str(missing_pdf), "--claim", "test claim", "--offline"], False),
            ("non_pdf_bytes_json", ["locate-evidence", str(not_pdf), "--claim", "test claim", "--offline", "--json"], True),
            ("corrupt_pdf_bytes_json", ["locate-evidence", str(corrupt_pdf), "--claim", "test claim", "--offline", "--json"], True),
            ("blank_pdf_json", ["locate-evidence", str(blank_pdf), "--claim", "test claim", "--offline", "--json"], True),
            ("empty_claim_json", ["locate-evidence", str(valid_pdf), "--claim", "", "--offline", "--json"], True),
            ("whitespace_claim_json", ["locate-evidence", str(valid_pdf), "--claim", "   \t  ", "--offline", "--json"], True),
            ("segment_missing_json", ["segment-pdf", str(missing_pdf), "--offline", "--json"], True),
            ("segment_non_pdf_json", ["segment-pdf", str(not_pdf), "--offline", "--json"], True),
        ]

        for label, args, is_json in cases:
            checks_run += 1
            rc, out, err, _ = run_cli(cli_bin, args, sandbox_home)
            stdout_ok = (out == "") if is_json else True
            stderr_ok = bool(err.strip())
            if rc == 2 and stdout_ok and stderr_ok:
                checks_passed += 1
            else:
                ok = False
                print(
                    f"  FAIL [Row 9] {label}: exit={rc} (expected 2), "
                    f"stdout_bytes={len(out)} (expected 0 when --json), stderr_nonempty={stderr_ok}"
                )

    print(f"  error_cases_passed={checks_passed}/{checks_run} (all exit=2, --json stdout_bytes=0, stderr non-empty)")
    return 0 if ok else 1


def scrub_sensitive_paths_and_emails(text: str, real_home: str, repo_root: str) -> str:
    """Scrub host home directory paths, temporary directory paths, and email addresses from report text."""
    out = text
    if repo_root:
        out = out.replace(repo_root + "/", "")
        out = out.replace(repo_root, "<repo>")
    if real_home:
        out = out.replace(real_home, "<HOME>")
    out = re.sub(r"/Users/[A-Za-z0-9._-]+", "<HOME>", out)
    out = re.sub(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "<REDACTED_EMAIL>", out)
    return out


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="M4 acceptance row runner helper.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    for rname in ("row1", "row2", "row3", "row4", "row5", "row6", "row7", "row8", "row9"):
        p = sub.add_parser(rname)
        p.add_argument("--repo-root", required=True)
        p.add_argument("--cli-bin", required=True)
        p.add_argument("--sandbox-home", required=True)
        p.add_argument("--cache-dir", required=True)

    p_scrub = sub.add_parser("scrub-file")
    p_scrub.add_argument("--file", required=True)
    p_scrub.add_argument("--real-home", required=True)
    p_scrub.add_argument("--repo-root", required=True)

    args = parser.parse_args(argv)
    if args.cmd == "scrub-file":
        fpath = pathlib.Path(args.file)
        raw = fpath.read_text(encoding="utf-8", errors="replace")
        cleaned = scrub_sensitive_paths_and_emails(raw, args.real_home, args.repo_root)
        fpath.write_text(cleaned, encoding="utf-8")
        return 0

    repo_root = pathlib.Path(args.repo_root).resolve()
    cache_root = pathlib.Path(args.cache_dir).resolve()
    claims_cache = cache_root / "claims_cli"
    seg_cache = cache_root / "segments_cli"

    if args.cmd == "row1":
        return cmd_row1(repo_root, args.cli_bin, args.sandbox_home)
    if args.cmd == "row2":
        return cmd_rows_2_3_4(2, repo_root, args.cli_bin, args.sandbox_home, claims_cache)
    if args.cmd == "row3":
        return cmd_rows_2_3_4(3, repo_root, args.cli_bin, args.sandbox_home, claims_cache)
    if args.cmd == "row4":
        return cmd_rows_2_3_4(4, repo_root, args.cli_bin, args.sandbox_home, claims_cache)
    if args.cmd == "row5":
        return cmd_row5(repo_root, args.cli_bin, args.sandbox_home, claims_cache)
    if args.cmd == "row6":
        return cmd_row6(repo_root, args.cli_bin, args.sandbox_home, seg_cache)
    if args.cmd == "row7":
        return cmd_row7(repo_root, args.cli_bin, args.sandbox_home, seg_cache)
    if args.cmd == "row8":
        return cmd_row8(repo_root, args.cli_bin, args.sandbox_home, claims_cache)
    if args.cmd == "row9":
        return cmd_row9(repo_root, args.cli_bin, args.sandbox_home)
    return 2


if __name__ == "__main__":
    sys.exit(main())
