#!/usr/bin/env python3
"""Unit tests for M4 acceptance parsing & judgment logic (`Scripts/acceptance/test_m4_harnesses.py`).

Covers small synthetic fixtures for:
  1. Page judgment (`expected_pages` membership, 1-based `page` == `page_index + 1`, exit codes).
  2. Numeric substring judgment (`discrepancies[].pdf_text` vs `ground_truth_numbers` with spaces
     and thousands-separator commas stripped).
  3. Coordinate system conversion between PDF `mediaBox` (origin at bottom-left) and Poppler
     `pdftotext -tsv` (origin at top-left), plus +4pt expansion.
  4. Bounding-box word coverage (`>= 80%` threshold, out-of-page rejection, non-positive size rejection,
     and full-page `mediaBox` rejection for M4 mutation 5).
  5. Segmentation quality judgment (repeating header/footer leak detection, Introduction/References
     heading detection, and left-before-right reading order below spanning floats) & path/email scrubbing.
"""

from __future__ import annotations

import unittest
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import m4_harness as m4h  # noqa: E402


def _build_synthetic_tsv(page_width: float, page_height: float, lines: list) -> str:
    """Build Poppler `pdftotext -tsv` content from `[(left, top, word_w, h, 'word1 word2 ...'), ...]`."""
    rows = ["level\tpage_num\tpar_num\tblock_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext"]
    rows.append(f"1\t1\t0\t0\t0\t0\t0.0\t0.0\t{page_width:.2f}\t{page_height:.2f}\t-1\t###PAGE###")
    for l_idx, (x0, top, word_w, h, line_text) in enumerate(lines):
        words = line_text.split()
        total_w = max(word_w, len(words) * (word_w + 4.0))
        rows.append(f"4\t1\t0\t0\t{l_idx}\t0\t{x0:.2f}\t{top:.2f}\t{total_w:.2f}\t{h:.2f}\t-1\t###LINE###")
        cur_x = x0
        for w_idx, w in enumerate(words):
            rows.append(f"5\t1\t0\t0\t{l_idx}\t{w_idx}\t{cur_x:.2f}\t{top:.2f}\t{word_w:.2f}\t{h:.2f}\t100\t{w}")
            cur_x += word_w + 4.0
    return "\n".join(rows) + "\n"


class M4HarnessUnitTests(unittest.TestCase):
    # ------------------------------------------------------------------
    # 1. Page Judgment & Three-Verdict Contract
    # ------------------------------------------------------------------
    def test_page_judgment_for_grounded_and_not_found_rows(self) -> None:
        claim_spec = {
            "id": "ev_test_01",
            "paper_id": "2410.04196v2",
            "group": "grounded",
            "expected_pages": [7, 2],
            "ground_truth_numbers": ["19 datasets"],
        }
        good_payload = {
            "schema": "scholaros.evidence/1",
            "claim": "VTAB-1K contains 19 datasets.",
            "pdf_file": "2410.04196v2.pdf",
            "verdict": "FOUND",
            "page": 2,
            "page_index": 1,
            "bounding_box": {"x": 54.0, "y": 420.0, "width": 230.0, "height": 48.0},
            "column_index": 1,
            "section_title": "1 Introduction",
            "excerpt": "VTAB-1K benchmark consisting of 19 datasets from various domains.",
            "discrepancies": [],
            "matches": [{"page": 2, "page_index": 1}],
        }
        res_ok = m4h.evaluate_claim_row(claim_spec, cli_exit=0, payload=good_payload)
        self.assertTrue(res_ok["passed"])
        self.assertTrue(res_ok["page_ok"])

        # Wrong page (page 5 not in [7, 2]) must fail
        wrong_page = dict(good_payload, page=5, page_index=4)
        res_bad_page = m4h.evaluate_claim_row(claim_spec, cli_exit=0, payload=wrong_page)
        self.assertFalse(res_bad_page["passed"])
        self.assertFalse(res_bad_page["page_ok"])

        # Wrong CLI exit code (e.g. exit 1 for FOUND) must fail
        res_bad_exit = m4h.evaluate_claim_row(claim_spec, cli_exit=1, payload=good_payload)
        self.assertFalse(res_bad_exit["passed"])

        # Sentinel / not_mentioned must be NOT_FOUND with empty matches and exit 3
        sentinel_spec = {
            "id": "ev_test_sentinel",
            "paper_id": "2506.06524v1",
            "group": "sentinel",
            "expected_pages": [],
            "ground_truth_numbers": [],
        }
        nf_payload = {
            "schema": "scholaros.evidence/1",
            "claim": "The moon is made of green cheese.",
            "pdf_file": "2506.06524v1.pdf",
            "verdict": "NOT_FOUND",
            "discrepancies": [],
            "matches": [],
        }
        self.assertTrue(m4h.evaluate_claim_row(sentinel_spec, cli_exit=3, payload=nf_payload)["passed"])
        leaked_matches = dict(nf_payload, matches=[{"page": 1}])
        self.assertFalse(m4h.evaluate_claim_row(sentinel_spec, cli_exit=3, payload=leaked_matches)["passed"])

    # ------------------------------------------------------------------
    # 2. Numeric Substring Judgment (Spaces & Thousands Commas Stripped)
    # ------------------------------------------------------------------
    def test_numeric_substring_judgment_strips_spaces_and_thousands_commas(self) -> None:
        self.assertEqual(m4h.strip_spaces_and_thousands_commas("1,000 training samples"), "1000trainingsamples")
        self.assertEqual(m4h.strip_spaces_and_thousands_commas("1, 006 iterations"), "1006iterations")
        # Decimal point must be preserved (13.92% != 1392%)
        self.assertEqual(m4h.strip_spaces_and_thousands_commas("13.92 %"), "13.92%")

        matched, _ = m4h.discrepancies_match_ground_truth(
            [{"claim_text": "10,000 training samples", "pdf_text": "1, 000 training samples", "reason": "mismatch"}],
            ["1,000 training samples"],
        )
        self.assertTrue(matched)

        matched_paren, _ = m4h.discrepancies_match_ground_truth(
            [{"claim_text": "6,100 PuzzleScript games", "pdf_text": "(610) of PuzzleScript games", "reason": "mismatch"}],
            ["610"],
        )
        self.assertTrue(matched_paren)

        unmatched, _ = m4h.discrepancies_match_ground_truth(
            [{"claim_text": "20 games", "pdf_text": "10k tokens", "reason": "wrong quantity"}],
            ["10 games"],
        )
        self.assertFalse(unmatched)

        # Spec Row 3: numeric core extracted from ground_truth_numbers (noun need not appear in pdf_text)
        matched_short_noun, _ = m4h.discrepancies_match_ground_truth(
            [{"claim_text": "10,000 training samples", "pdf_text": "1,000 training", "reason": "mismatch"}],
            ["1,000 training samples"],
        )
        self.assertTrue(matched_short_noun)

        # Wrong magnitude ("500 samples" vs "5,000 samples", and reverse) must NOT match
        unmatched_500_vs_5000, _ = m4h.discrepancies_match_ground_truth(
            [{"claim_text": "50,000 samples", "pdf_text": "500 samples", "reason": "mismatch"}],
            ["5,000 samples"],
        )
        self.assertFalse(unmatched_500_vs_5000)

        unmatched_5000_vs_500, _ = m4h.discrepancies_match_ground_truth(
            [{"claim_text": "5,000 samples", "pdf_text": "5,000 samples", "reason": "mismatch"}],
            ["500 samples"],
        )
        self.assertFalse(unmatched_5000_vs_500)

        # Decimal & percent sign must both match (13.2% != 3.2%, and 3.2 != 3.2%)
        unmatched_pct_prefix, _ = m4h.discrepancies_match_ground_truth(
            [{"claim_text": "13.2%", "pdf_text": "13.2%", "reason": "mismatch"}],
            ["3.2%"],
        )
        self.assertFalse(unmatched_pct_prefix)

        unmatched_missing_pct, _ = m4h.discrepancies_match_ground_truth(
            [{"claim_text": "13.2%", "pdf_text": "3.2 points", "reason": "mismatch"}],
            ["3.2%"],
        )
        self.assertFalse(unmatched_missing_pct)

        mm_spec = {
            "id": "ev_test_mm",
            "paper_id": "2409.19431v3",
            "group": "numeric_mismatch",
            "expected_pages": [31],
            "ground_truth_numbers": ["1,000 training samples"],
        }
        mm_payload = {
            "schema": "scholaros.evidence/1",
            "claim": "Run with 10,000 training samples.",
            "pdf_file": "2409.19431v3.pdf",
            "verdict": "NUMERIC_MISMATCH",
            "page": 31,
            "page_index": 30,
            "bounding_box": {"x": 310.0, "y": 200.0, "width": 235.0, "height": 42.0},
            "column_index": 2,
            "section_title": "Experiments",
            "excerpt": "The experiment was conducted with 1000 training samples.",
            "discrepancies": [
                {"claim_text": "10,000 training samples", "pdf_text": "1000 training samples", "reason": "diff"}
            ],
            "matches": [{"page": 31, "page_index": 30}],
        }
        self.assertTrue(m4h.evaluate_claim_row(mm_spec, cli_exit=1, payload=mm_payload)["passed"])

    # ------------------------------------------------------------------
    # 3. PDF Bottom-Left <-> pdftotext -tsv Top-Left Coordinate Conversion
    # ------------------------------------------------------------------
    def test_coordinate_conversion_pdf_bottom_left_and_tsv_top_left(self) -> None:
        # On a 792pt-tall US Letter page:
        # PDF box at x=54, y=682, width=240, height=50 occupies PDF Y [682, 732],
        # which in top-left coordinates is top = 792 - 732 = 60, bottom = 792 - 682 = 110.
        pdf_box = {"x": 54.0, "y": 682.0, "width": 240.0, "height": 50.0}
        left, top, right, bottom = m4h.pdf_box_to_tsv_rect(pdf_box, page_height=792.0)
        self.assertAlmostEqual(left, 54.0)
        self.assertAlmostEqual(top, 60.0)
        self.assertAlmostEqual(right, 294.0)
        self.assertAlmostEqual(bottom, 110.0)

        roundtrip = m4h.tsv_rect_to_pdf_box((left, top, right, bottom), page_height=792.0)
        for k in ("x", "y", "width", "height"):
            self.assertAlmostEqual(roundtrip[k], pdf_box[k])

        exp_l, exp_t, exp_r, exp_b = m4h.expand_tsv_rect((left, top, right, bottom), pad_pt=4.0)
        self.assertEqual((exp_l, exp_t, exp_r, exp_b), (50.0, 56.0, 298.0, 114.0))

    # ------------------------------------------------------------------
    # 4. Bounding-Box Word Coverage & Full-Page mediaBox Rejection
    # ------------------------------------------------------------------
    def test_bounding_box_word_coverage_and_full_page_rejection(self) -> None:
        # Target paragraph in left column at TSV top=200..235 => PDF y = 792 - 235 = 557, height = 35
        tsv_text = _build_synthetic_tsv(
            612.0,
            792.0,
            [
                (54.0, 90.0, 28.0, 10.0, "Unrelated opening paragraph above target section with other words"),
                (54.0, 202.0, 26.0, 10.0, "Deterministic verifier completes static analysis"),
                (54.0, 218.0, 26.0, 10.0, "across 368 regression tests quickly"),
                (320.0, 410.0, 28.0, 10.0, "Right column discussion of completely separate experiments"),
            ],
        )
        page_data = m4h.parse_pdftotext_tsv_pages(tsv_text)[1]
        excerpt = "Deterministic verifier completes static analysis across 368 regression tests quickly"

        # Tight box around TSV [54..234] x [203..227] -> PDF y = 792 - 227 = 565, height = 24
        # Note top=202 is 1pt outside [203..227], so +4pt tolerance covers 10/10 = 100% of words!
        good_box = {"x": 54.0, "y": 565.0, "width": 180.0, "height": 24.0}
        res_good = m4h.evaluate_bounding_box_on_tsv_page(good_box, page_data, excerpt, pad_pt=4.0)
        self.assertTrue(res_good["passed"], msg=str(res_good))
        self.assertEqual(res_good["passage_word_count"], 10)
        self.assertGreaterEqual(res_good["word_coverage"], 0.80)

        # Box pointing to the wrong column (right column x=320, y=370) covers 0% < 80% -> FAIL
        wrong_col_box = {"x": 320.0, "y": 370.0, "width": 200.0, "height": 30.0}
        res_wrong = m4h.evaluate_bounding_box_on_tsv_page(wrong_col_box, page_data, excerpt, pad_pt=4.0)
        self.assertFalse(res_wrong["passed"])
        self.assertLess(res_wrong["word_coverage"], 0.80)

        # Full-page mediaBox (0, 0, 612, 792) covers 100% of words BUT must FAIL Row 5 (Mutation 5)!
        full_page_box = {"x": 0.0, "y": 0.0, "width": 612.0, "height": 792.0}
        res_full = m4h.evaluate_bounding_box_on_tsv_page(full_page_box, page_data, excerpt, pad_pt=4.0)
        self.assertFalse(res_full["passed"])
        self.assertFalse(res_full["not_full_page"])

        # Out-of-page box must FAIL
        out_of_page = {"x": 500.0, "y": 565.0, "width": 200.0, "height": 24.0}
        self.assertFalse(m4h.evaluate_bounding_box_on_tsv_page(out_of_page, page_data, excerpt)["passed"])

    # ------------------------------------------------------------------
    # 5. Row 6 Segmentation Checks & Sensitive Path/Email Scrubbing
    # ------------------------------------------------------------------
    def test_segmentation_header_leak_headings_and_column_order(self) -> None:
        clean_report = {
            "schema": "scholaros.pdf_segments/1",
            "pdf_file": "probe.pdf",
            "page_count": 2,
            "chunk_count": 6,
            "chunks": [
                {"id": "c1", "reading_sequence": 1, "kind": "header", "page": 1, "page_index": 0, "column_index": 0, "section_title": "Front", "bounding_box": {"x": 54, "y": 750, "width": 500, "height": 10}, "text": "Running Conf Header"},
                {"id": "c2", "reading_sequence": 2, "kind": "section_heading", "page": 1, "page_index": 0, "column_index": 1, "section_title": "1 Introduction", "bounding_box": {"x": 54, "y": 650, "width": 120, "height": 14}, "text": "1 Introduction"},
                {"id": "c3", "reading_sequence": 3, "kind": "table_or_figure", "page": 2, "page_index": 1, "column_index": 0, "section_title": "1 Introduction", "bounding_box": {"x": 54, "y": 500, "width": 504, "height": 180}, "text": "Table 1 Wide Float"},
                {"id": "c4", "reading_sequence": 4, "kind": "body", "page": 2, "page_index": 1, "column_index": 1, "section_title": "1 Introduction", "bounding_box": {"x": 54, "y": 300, "width": 230, "height": 40}, "text": "Left column body below wide table."},
                {"id": "c5", "reading_sequence": 5, "kind": "body", "page": 2, "page_index": 1, "column_index": 2, "section_title": "1 Introduction", "bounding_box": {"x": 320, "y": 300, "width": 230, "height": 40}, "text": "Right column body below wide table."},
                {"id": "c6", "reading_sequence": 6, "kind": "section_heading", "page": 2, "page_index": 1, "column_index": 2, "section_title": "References", "bounding_box": {"x": 320, "y": 220, "width": 100, "height": 14}, "text": "References"},
            ],
        }
        ev_ok = m4h.evaluate_segmentation_report(
            clean_report,
            known_forbidden_body_substrings=["Running Conf Header"],
        )
        self.assertTrue(ev_ok["passed"], msg=str(ev_ok))

        # Leak header into body -> FAIL
        leaked = dict(clean_report, chunks=[dict(clean_report["chunks"][0], kind="body")] + clean_report["chunks"][1:])
        self.assertFalse(
            m4h.evaluate_segmentation_report(leaked, known_forbidden_body_substrings=["Running Conf Header"])["passed"]
        )

        # Interleaved column order (col 2 -> col 1 below spanning float) -> FAIL
        bad_order = dict(
            clean_report,
            chunks=[
                clean_report["chunks"][0],
                clean_report["chunks"][1],
                clean_report["chunks"][2],
                dict(clean_report["chunks"][4], reading_sequence=4),  # col 2 first!
                dict(clean_report["chunks"][3], reading_sequence=5),  # col 1 after col 2!
                dict(clean_report["chunks"][5], reading_sequence=6),
            ],
        )
        self.assertFalse(m4h.evaluate_segmentation_report(bad_order)["passed"])

        fake_users_prefix = "/Use" + "rs/"
        fake_home = fake_users_prefix + "alice"
        fake_repo = fake_home + "/Projects/repo"
        scrubbed = m4h.scrub_sensitive_paths_and_emails(
            f"Ran in {fake_repo}/foo with author alice@example.org",
            real_home=fake_home,
            repo_root=fake_repo,
        )
        self.assertNotIn(fake_users_prefix, scrubbed)
        self.assertNotIn("alice@example.org", scrubbed)

    def test_tsv_margin_leak_ignores_interior_digits_and_catches_glued_footer(self) -> None:
        # 2-page TSV with isolated footer '1' on p.1 at top=745 (PDF y=37..47) and 'Page 2 of 2' on p.2 at top=756
        tsv = (
            "level\tpage_num\tpar_num\tblock_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n"
            "1\t1\t0\t0\t0\t0\t0.0\t0.0\t612.0\t792.0\t-1\t###PAGE###\n"
            "4\t1\t0\t0\t0\t0\t54.0\t200.0\t230.0\t12.0\t-1\t###LINE###\n"
            "5\t1\t0\t0\t0\t0\t54.0\t200.0\t40.0\t12.0\t100\tSection\n"
            "5\t1\t0\t0\t0\t1\t98.0\t200.0\t10.0\t12.0\t100\t1\n"
            "4\t1\t1\t0\t0\t0\t300.0\t745.0\t8.0\t10.0\t-1\t###LINE###\n"
            "5\t1\t1\t0\t0\t0\t300.0\t745.0\t8.0\t10.0\t100\t1\n"
            "1\t2\t0\t0\t0\t0\t0.0\t0.0\t612.0\t792.0\t-1\t###PAGE###\n"
            "4\t2\t0\t0\t0\t0\t54.0\t200.0\t230.0\t12.0\t-1\t###LINE###\n"
            "5\t2\t0\t0\t0\t0\t54.0\t200.0\t60.0\t12.0\t100\tReferences\n"
            "4\t2\t1\t0\t0\t0\t490.0\t756.0\t50.0\t12.0\t-1\t###LINE###\n"
            "5\t2\t1\t0\t0\t0\t490.0\t756.0\t20.0\t12.0\t100\tPage\n"
            "5\t2\t1\t0\t0\t1\t512.0\t756.0\t6.0\t12.0\t100\t2\n"
            "5\t2\t1\t0\t0\t2\t520.0\t756.0\t8.0\t12.0\t100\tof\n"
            "5\t2\t1\t0\t0\t3\t530.0\t756.0\t6.0\t12.0\t100\t2\n"
        )
        # Body paragraph at PDF y=75..140 (TSV bottom=717, well above top=745) mentioning '1' must NOT be flagged
        ok_rep = {
            "schema": "scholaros.pdf_segments/1",
            "pdf_file": "two.pdf",
            "page_count": 2,
            "chunk_count": 4,
            "chunks": [
                {"id": "h1", "reading_sequence": 1, "kind": "section_heading", "page": 1, "page_index": 0, "column_index": 1, "section_title": "1 Introduction", "bounding_box": {"x": 54, "y": 580, "width": 120, "height": 14}, "text": "1 Introduction"},
                {"id": "b1", "reading_sequence": 2, "kind": "body", "page": 1, "page_index": 0, "column_index": 1, "section_title": "1 Introduction", "bounding_box": {"x": 54, "y": 75, "width": 230, "height": 65}, "text": "In Section 1 we evaluate the model."},
                {"id": "f1", "reading_sequence": 3, "kind": "footer", "page": 1, "page_index": 0, "column_index": 0, "section_title": "1 Introduction", "bounding_box": {"x": 300, "y": 37, "width": 8, "height": 10}, "text": "1"},
                {"id": "h2", "reading_sequence": 4, "kind": "section_heading", "page": 2, "page_index": 1, "column_index": 1, "section_title": "References", "bounding_box": {"x": 54, "y": 580, "width": 100, "height": 14}, "text": "References"},
            ],
        }
        self.assertTrue(m4h.evaluate_segmentation_report(ok_rep, tsv_text=tsv)["passed"])

        # Space-glued 'Page2of2' classified as body right at PDF y=24..36 (TSV top=756..768) MUST be caught
        glued_leak_rep = dict(
            ok_rep,
            chunks=ok_rep["chunks"] + [
                {"id": "leak2", "reading_sequence": 5, "kind": "body", "page": 2, "page_index": 1, "column_index": 2, "section_title": "References", "bounding_box": {"x": 490, "y": 24, "width": 50, "height": 12}, "text": "Page2of2"},
            ],
        )
        ev_leak = m4h.evaluate_segmentation_report(glued_leak_rep, tsv_text=tsv)
        self.assertFalse(ev_leak["passed"])
        self.assertEqual(ev_leak["header_footer_leak_count"], 1)


if __name__ == "__main__":
    unittest.main()
