#!/usr/bin/env python3
"""Unit tests for Scripts/acceptance/m4_word_overlap.py (Python stdlib only)."""

from __future__ import annotations

import io
import json
import pathlib
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import m4_word_overlap as m4wo  # noqa: E402


def _make_tsv_rows(pages_spec: list) -> str:
    """Build synthetic Poppler `pdftotext -tsv` content from [(page_height, [(top, height, text), ...]), ...]."""
    out = ["level\tpage_num\tpar_num\tblock_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext"]
    for p_idx, (page_h, lines) in enumerate(pages_spec, start=1):
        out.append(f"1\t{p_idx}\t0\t0\t0\t0\t0.0\t0.0\t612.0\t{page_h:.1f}\t-1\t###PAGE###")
        for l_idx, (top, h, text) in enumerate(lines):
            out.append(f"4\t{p_idx}\t{l_idx}\t0\t0\t0\t54.0\t{top:.2f}\t240.0\t{h:.2f}\t-1\t###LINE###")
            for w_idx, word in enumerate(text.split()):
                out.append(f"5\t{p_idx}\t{l_idx}\t0\t0\t{w_idx}\t54.0\t{top:.2f}\t30.0\t{h:.2f}\t100\t{word}")
    return "\n".join(out) + "\n"


class M4WordOverlapUnitTests(unittest.TestCase):
    def test_dehyphenation_restores_linebreak_words(self) -> None:
        raw = "We study evaluat-\ning 368 tests and ex-\nplicit numbers in two-column papers."
        tokens = m4wo.tokenize_words(raw, dehyphenate=True)
        self.assertIn("evaluating", tokens)
        self.assertIn("explicit", tokens)
        # In-line compound hyphen ("two-column") splits into ["two", "column"] consistently
        self.assertIn("two", tokens)
        self.assertIn("column", tokens)

    def test_margin_repetition_stripped_while_preserving_body_occurrences(self) -> None:
        # 2-page PDF: "Journal Vol 14 November 2026" repeats at top (y=36), "Page 1/2" repeats at bottom (y=748),
        # while "November 2026" ALSO appears once in Page 1 interior body (y=175).
        tsv = _make_tsv_rows([
            (792.0, [
                (36.0, 9.0, "Journal Vol 14 November 2026"),
                (175.0, 11.0, "Published November 2026"),
                (220.0, 10.0, "Deterministic verifier checks 368 tests."),
                (748.0, 9.0, "Preprint Footer Page 1"),
            ]),
            (792.0, [
                (36.0, 9.0, "Journal Vol 14 November 2026"),
                (220.0, 10.0, "Across 1240 queries latency remained 14.5 ms."),
                (748.0, 9.0, "Preprint Footer Page 2"),
            ]),
        ])
        raw = (
            "Journal Vol 14 November 2026\n"
            "Published November 2026\n"
            "Deterministic verifier checks 368 tests.\n"
            "Preprint Footer Page 1\n\f"
            "Journal Vol 14 November 2026\n"
            "Across 1240 queries latency remained 14.5 ms.\n"
            "Preprint Footer Page 2\n"
        )
        chunks = [
            {"kind": "header", "passageText": "Journal Vol 14 November 2026"},
            {"kind": "body", "passageText": "Published November 2026"},
            {"kind": "body", "passageText": "Deterministic verifier checks 368 tests."},
            {"kind": "footer", "passageText": "Preprint Footer Page 1"},
            {"kind": "header", "passageText": "Journal Vol 14 November 2026"},
            {"kind": "table_or_figure", "passageText": "Across 1240 queries latency remained 14.5 ms."},
            {"kind": "footer", "passageText": "Preprint Footer Page 2"},
        ]

        metrics = m4wo.compute_word_overlap_metrics(raw, tsv, chunks)
        self.assertEqual(metrics["kept_chunk_count"], 3)
        self.assertGreater(metrics["excluded_margin_words"], 0)
        self.assertAlmostEqual(metrics["multiset_recall"], 1.0, places=6)

    def test_low_recall_detected_when_body_chunk_missing(self) -> None:
        tsv = _make_tsv_rows([
            (792.0, [(200.0, 10.0, "alpha beta gamma delta epsilon zeta eta theta iota kappa")])
        ])
        raw = "alpha beta gamma delta epsilon zeta eta theta iota kappa\n"
        chunks = [{"kind": "body", "passageText": "alpha beta gamma"}]

        metrics = m4wo.compute_word_overlap_metrics(raw, tsv, chunks)
        self.assertAlmostEqual(metrics["multiset_recall"], 0.30, places=6)

    def test_single_page_non_repeating_title_kept_while_isolated_page_number_excluded(self) -> None:
        tsv = _make_tsv_rows([
            (792.0, [
                (45.0, 14.0, "Roman Numeral Section Heading Probe"),
                (210.0, 10.0, "I. Introduction"),
                (225.0, 10.0, "Pipeline evaluates 368 regression tests in 14.5 ms."),
                (752.0, 9.0, "1"),
            ])
        ])
        raw = (
            "Roman Numeral Section Heading Probe\n"
            "I. Introduction\n"
            "Pipeline evaluates 368 regression tests in 14.5 ms.\n"
            "1\n"
        )
        wrapped_payload = {
            "chunks": [
                {"kind": "body", "passage_text": "Roman Numeral Section Heading Probe"},
                {"kind": "section_heading", "passage_text": "I. Introduction"},
                {"kind": "body", "passage_text": "Pipeline evaluates 368 regression tests in 14.5 ms."},
                {"kind": "footer", "passage_text": "1"},
            ]
        }
        metrics = m4wo.compute_word_overlap_metrics(raw, tsv, wrapped_payload)
        self.assertEqual(metrics["excluded_margin_words"], 1)
        self.assertAlmostEqual(metrics["multiset_recall"], 1.0, places=6)

    def test_missing_pdftotext_reports_not_run_and_exits_nonzero(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            pdf_file = pathlib.Path(tmp) / "dummy.pdf"
            chunks_file = pathlib.Path(tmp) / "chunks.json"
            pdf_file.write_bytes(b"%PDF-1.4\n")
            chunks_file.write_text("[]", encoding="utf-8")

            err_buf = io.StringIO()
            with redirect_stderr(err_buf):
                rc = m4wo.main([
                    "--pdf", str(pdf_file),
                    "--chunks", str(chunks_file),
                    "--pdftotext", "/nonexistent/path/to/pdftotext",
                ])
            self.assertEqual(rc, 2)
            self.assertIn("没跑", err_buf.getvalue())

            out_buf = io.StringIO()
            with redirect_stdout(out_buf):
                rc_json = m4wo.main([
                    "--pdf", str(pdf_file),
                    "--chunks", str(chunks_file),
                    "--pdftotext", "/nonexistent/path/to/pdftotext",
                    "--json",
                ])
            self.assertEqual(rc_json, 2)
            payload = json.loads(out_buf.getvalue())
            self.assertEqual(payload["status"], "NOT_RUN")
            self.assertFalse(payload["passed"])
            self.assertIn("没跑", payload["message"])


if __name__ == "__main__":
    unittest.main()
