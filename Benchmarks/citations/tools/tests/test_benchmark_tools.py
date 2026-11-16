#!/usr/bin/env python3
"""Offline unittest suite for Benchmarks/citations/tools/.

Run with:
  python3 -I -m unittest discover -s Benchmarks/citations/tools/tests -t Benchmarks/citations/tools -v
"""
from __future__ import annotations

import contextlib
import email.message
import io
import json
import os
import pathlib
import random
import re
import shutil
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Tuple
from unittest import mock

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
TOOLS_DIR = os.path.dirname(TESTS_DIR)
BENCH_DIR = os.path.dirname(TOOLS_DIR)
REPO_ROOT = os.path.dirname(os.path.dirname(BENCH_DIR))
SAMPLES_PATH = os.path.join(TESTS_DIR, "samples", "handwritten_registry_samples.json")

if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)

import _common  # noqa: E402
import build_mutations  # noqa: E402
import build_real_clean  # noqa: E402
import build_retracted  # noqa: E402
import check_benchmark  # noqa: E402


def _save_raw_response(
    raw_dir: str,
    url: str,
    body_obj: Any,
    status: int = 200,
    headers: Optional[Dict[str, str]] = None,
) -> str:
    os.makedirs(raw_dir, exist_ok=True)
    body_str = body_obj if isinstance(body_obj, str) else json.dumps(body_obj, ensure_ascii=False)
    envelope = {
        "url": url,
        "status": status,
        "fetched_at": "2026-11-16T00:00:00Z",
        "headers": headers or {"content-type": "application/json"},
        "body": body_str,
    }
    out_path = os.path.join(raw_dir, _common.url_sha1_filename(url))
    with open(out_path, "w", encoding="utf-8", newline="\n") as out:
        json.dump(envelope, out, ensure_ascii=False, sort_keys=True)
        out.write("\n")
    return out_path


class _MockHTTPResponse:
    def __init__(self, status: int, body: bytes, headers: Dict[str, str]) -> None:
        self.status = status
        self._body = body
        self.headers = headers

    def getcode(self) -> int:
        return self.status

    def read(self) -> bytes:
        return self._body

    def __enter__(self) -> "_MockHTTPResponse":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        return False


class _ScriptedOpener:
    """In-memory opener double for testing BenchmarkHTTPClient without sockets."""

    def __init__(self, scripted: List[Tuple[int, str, Dict[str, str]]]) -> None:
        self.scripted = list(scripted)
        self.seen_requests: List[Tuple[str, Dict[str, str]]] = []

    def open(self, req: urllib.request.Request, timeout: float = 30.0) -> _MockHTTPResponse:
        hdrs = {k.lower(): v for k, v in req.header_items()}
        self.seen_requests.append((req.full_url, hdrs))
        if not self.scripted:
            raise AssertionError("Unexpected extra HTTP request: %s" % req.full_url)
        status, body_text, resp_headers = self.scripted.pop(0)
        body_bytes = body_text.encode("utf-8")
        if status >= 400:
            msg = email.message.Message()
            for hk, hv in resp_headers.items():
                msg[hk] = hv
            raise urllib.error.HTTPError(
                req.full_url, status, "HTTP %d" % status, msg, io.BytesIO(body_bytes)
            )
        return _MockHTTPResponse(status, body_bytes, resp_headers)


class BenchmarkToolsUnitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        with open(SAMPLES_PATH, encoding="utf-8") as f:
            cls.samples = json.load(f)

    def _populate_synthetic_real_clean_cache(
        self,
        bench_dir: str,
        seed: int,
        strata: List[Dict[str, Any]],
        per_stratum: int,
        sample_size: int = 12,
        accented_count: int = 6,
        include_three_year_blocked_record: bool = False,
    ) -> None:
        """Populate handwritten raw OpenAlex + Crossref responses in sources/real_clean/raw/."""
        raw_dir = os.path.join(bench_dir, "sources", "real_clean", "raw")
        skip_map = self.samples["skipped_crossref_examples"]
        accented_surnames = [
            "Sánchez",
            "Müller",
            "Łukasiewicz",
            "Ørsted",
            "Kovács",
            "Gérard",
            "Bélanger",
        ]
        plain_surnames = [
            "Anderson", "Bennett", "Carter", "Dawson", "Edwards", "Fletcher",
            "Gibson", "Harrison", "Ingram", "Jenkins", "Keller", "Lawson",
            "Morrison", "Newman", "Owens", "Palmer", "Quincy", "Reynolds",
            "Stevens", "Turner", "Underwood", "Vaughn", "Wallace", "Young",
        ]
        topics = [
            "Adaptive Graph Partitioning Under Dynamic Edge Weights",
            "Stochastic Gradient Convergence on Nonconvex Manifolds",
            "Bayesian Hierarchical Survival Modeling in Clinical Cohorts",
            "Magnetohydrodynamic Wave Damping in Coronal Loops",
            "Transcriptional Regulation of Ribosomal Biogenesis Pathways",
            "Household Saving Elasticity Across Regional Labor Markets",
            "Finite Element Preconditioning for Saddle Point Systems",
            "Cryogenic Bolometer Calibration for Submillimeter Surveys",
        ]

        global_idx = 0
        for s_idx, stratum in enumerate(strata):
            stratum_seed = seed + s_idx * 100 + 0
            sample_url = build_real_clean.build_openalex_sample_url(
                stratum, sample_size, stratum_seed
            )
            oa_results: List[Dict[str, Any]] = []

            if s_idx == 0:
                # Inject invalid candidates ahead of valid ones to verify filtering
                for bad_name, bad_payload in skip_map.items():
                    bad_doi = bad_payload["message"]["DOI"]
                    oa_results.append({
                        "id": "https://openalex.org/Wbad_%s" % bad_name,
                        "doi": "https://doi.org/" + bad_doi,
                        "is_retracted": False,
                    })
                    _save_raw_response(
                        raw_dir,
                        _common.crossref_work_url(bad_doi),
                        bad_payload,
                        status=200,
                    )
                # Inject an OpenAlex is_retracted=true item and a built-in retracted DOI
                oa_results.append({
                    "id": "https://openalex.org/Wbad_oaretracted",
                    "doi": "https://doi.org/10.1000/skip.oaretracted",
                    "is_retracted": True,
                })
                oa_results.append({
                    "id": "https://openalex.org/Wbad_builtin",
                    "doi": "https://doi.org/10.1038/nature12968",
                    "is_retracted": False,
                })

            for item_i in range(per_stratum):
                global_idx += 1
                doi_str = "10.550%d/clean.%s.%03d" % (
                    (s_idx % 5) + 1,
                    stratum["field_slug"][:4],
                    global_idx,
                )
                if global_idx <= accented_count:
                    fam = accented_surnames[(global_idx - 1) % len(accented_surnames)]
                else:
                    fam = plain_surnames[(global_idx - 1) % len(plain_surnames)]

                base_year = stratum["year_start"] + (item_i % 3) + 1
                base_title = "%s in Case %03d" % (
                    topics[(global_idx - 1) % len(topics)],
                    global_idx,
                )

                if include_three_year_blocked_record and global_idx == 1:
                    # Record whose print/online/issued span [base_year-1, base_year, base_year+1],
                    # so neither base_year-1 nor base_year+1 is distinct from all 3 dates!
                    pub_online = {"date-parts": [[base_year - 1, 12, 15]]}
                    issued = {"date-parts": [[base_year, 1, 10]]}
                    pub_print = {"date-parts": [[base_year + 1, 2, 1]]}
                else:
                    pub_online = {"date-parts": [[base_year, 5, 10]]}
                    issued = {"date-parts": [[base_year, 5, 10]]}
                    pub_print = {"date-parts": [[base_year + 1, 1, 15]]}

                cr_work = {
                    "status": "ok",
                    "message": {
                        "DOI": doi_str,
                        "type": "journal-article",
                        "title": [base_title],
                        "container-title": ["Synthetic Journal of %s" % stratum["field_name"]],
                        "author": [
                            {"given": "Alice", "family": fam, "sequence": "first"},
                            {"given": "Robert", "family": " Cole", "sequence": "additional"},
                        ],
                        "published-online": pub_online,
                        "published-print": pub_print,
                        "issued": issued,
                        "volume": str(10 + item_i),
                        "issue": str(1 + (item_i % 4)),
                        "page": "%d-%d" % (100 + item_i * 10, 108 + item_i * 10),
                    },
                }
                oa_results.append({
                    "id": "https://openalex.org/Wclean_%03d" % global_idx,
                    "doi": "https://doi.org/" + doi_str,
                    "is_retracted": False,
                })
                _save_raw_response(
                    raw_dir,
                    _common.crossref_work_url(doi_str),
                    cr_work,
                    status=200,
                )

            _save_raw_response(
                raw_dir,
                sample_url,
                {"meta": {"count": len(oa_results)}, "results": oa_results},
                status=200,
            )

    def _populate_missing_doi_handles_cache(
        self,
        bench_dir: str,
        sources_count_to_seed: int,
        seed: int,
        force_first_collision: bool = False,
    ) -> Optional[str]:
        """Pre-populate doi.org handle responses for build_mutations --confirm-missing --offline."""
        clean_sources = build_mutations.load_real_clean_sources(bench_dir)
        rng = random.Random(seed + 707)
        pool = list(clean_sources)
        rng.shuffle(pool)

        raw_dir = os.path.join(bench_dir, "sources", "mut_doi_missing", "raw")
        used: set = set()
        collided_doi: Optional[str] = None

        for idx, src in enumerate(pool[:sources_count_to_seed]):
            orig_prefix_exact = src.doi.split("/", 1)[0]
            for attempt in range(1, 10):
                rand_tok = "".join(
                    rng.choice(build_mutations._SUFFIX_ALPHABET) for _ in range(10)
                )
                cand_doi = "%s/m1missing.%s" % (orig_prefix_exact, rand_tok)
                norm_cand = _common.normalize_doi(cand_doi)
                if norm_cand == _common.normalize_doi(src.doi) or norm_cand in used:
                    continue
                h_url = _common.doi_handle_url(cand_doi)
                if force_first_collision and idx == 0 and attempt == 1:
                    collided_doi = cand_doi
                    _save_raw_response(
                        raw_dir,
                        h_url,
                        {"responseCode": 1, "handle": cand_doi},
                        status=200,
                    )
                    continue
                _save_raw_response(
                    raw_dir,
                    h_url,
                    {"responseCode": 100, "handle": cand_doi},
                    status=404,
                )
                used.add(norm_cand)
                break
        return collided_doi

    # ------------------------------------------------------------------
    # 1. Crossref record -> BibTeX conversion
    # ------------------------------------------------------------------
    def test_crossref_record_to_bibtex_conversion(self) -> None:
        msg = dict(self.samples["clean_crossref_example"]["message"])
        # Also verify sequence=='first' is placed first even if listed second in Crossref JSON
        reordered_msg = dict(msg)
        reordered_msg["author"] = list(reversed(msg["author"]))

        bib = _common.crossref_message_to_bibtex("real_clean_001", reordered_msg)
        parsed = _common.parse_bibtex_entries(bib)
        self.assertEqual(len(parsed), 1)
        entry = parsed[0]
        self.assertEqual(entry.entry_type, "article")
        self.assertEqual(entry.key, "real_clean_001")
        self.assertEqual(
            entry.fields["author"],
            "Sánchez, Elena and Lindholm, Marcus",
        )
        self.assertEqual(
            entry.fields["title"],
            "Adaptive Graph Partitioning Under Dynamic Edge Weights",
        )
        self.assertEqual(entry.fields["journal"], "Journal of Graph Algorithms")
        # Year comes from Crossref 'issued' (2018), even though published-print is 2019
        self.assertEqual(entry.fields["year"], "2018")
        self.assertEqual(entry.fields["volume"], "24")
        self.assertEqual(entry.fields["number"], "2")
        self.assertEqual(entry.fields["pages"], "105-128")
        self.assertEqual(entry.fields["doi"], "10.1000/sample.clean.01")

    # ------------------------------------------------------------------
    # 2. Filtering conditions in build_real_clean.py
    # ------------------------------------------------------------------
    def test_filter_skips_missing_author_html_mathml_and_non_journal_article(self) -> None:
        mini_strata = build_real_clean.STRATA[:2]
        with tempfile.TemporaryDirectory() as td:
            self._populate_synthetic_real_clean_cache(
                td, seed=20261116, strata=mini_strata, per_stratum=2, sample_size=12
            )
            summary = build_real_clean.build_real_clean(
                bench_dir=td,
                seed=20261116,
                offline=True,
                per_stratum=2,
                sample_size=12,
                strata=mini_strata,
            )
            self.assertEqual(summary["entries_written"], 4)
            self.assertEqual(summary["network_requests"], 0)

            bib_text = pathlib.Path(td, "entries", "real_clean.bib").read_text(encoding="utf-8")
            entries = _common.parse_bibtex_entries(bib_text)
            self.assertEqual([e.key for e in entries], [
                "real_clean_001", "real_clean_002", "real_clean_003", "real_clean_004"
            ])
            dois = {e.fields["doi"] for e in entries}
            for skipped_doi in (
                "10.1000/skip.noauthor",
                "10.1000/skip.nofamily",
                "10.1000/skip.html",
                "10.1000/skip.mathml",
                "10.1000/skip.chapter",
                "10.1000/skip.noyear",
                "10.1000/skip.oaretracted",
                "10.1038/nature12968",
            ):
                self.assertNotIn(skipped_doi, dois)

            gold_rows = [
                json.loads(line)
                for line in pathlib.Path(td, "gold.jsonl").read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            self.assertEqual(len(gold_rows), 4)
            for grow in gold_rows:
                self.assertEqual(grow["truth"], "real")
                self.assertEqual(grow["expected"], ["VERIFIED"])
                self.assertTrue(grow["insertable"])
                prov = grow["provenance"]
                self.assertIn("published-print", prov)
                self.assertIn("published-online", prov)
                self.assertIn("issued", prov)

    # ------------------------------------------------------------------
    # 3. Built-in retracted list matches Swift product source
    # ------------------------------------------------------------------
    def test_builtin_retracted_dois_match_swift_product_source(self) -> None:
        swift_path = os.path.join(
            REPO_ROOT,
            "Sources",
            "ScholarBibAndCSL",
            "CitationVerificationFirewall.swift",
        )
        self.assertTrue(os.path.isfile(swift_path), "Missing %s" % swift_path)
        swift_src = pathlib.Path(swift_path).read_text(encoding="utf-8")
        block_match = re.search(
            r"defaultRetractedDOIs\s*:\s*Set<String>\s*=\s*\[(.*?)\]",
            swift_src,
            re.S,
        )
        self.assertIsNotNone(block_match, "Could not locate defaultRetractedDOIs in Swift source")
        swift_dois = {
            m.group(1).strip().lower()
            for m in re.finditer(r'"(10\.[^"]+)"', block_match.group(1))
        }
        self.assertEqual(len(swift_dois), 8)
        self.assertEqual(swift_dois, set(_common.BUILTIN_RETRACTED_DOIS))
        self.assertEqual(swift_dois, set(build_retracted.PRODUCT_BUILTIN_RETRACTED_DOIS))

    # ------------------------------------------------------------------
    # 4. Retracted group builder rules (basis, prefix cap <= 3, built-in exclusion)
    # ------------------------------------------------------------------
    def test_build_retracted_filters_prefix_cap_builtin_and_basis(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            raw_dir = os.path.join(td, "sources", "retracted", "raw")
            notices: List[Dict[str, Any]] = []

            def add_candidate(
                notice_doi: str,
                target_doi: str,
                title: str,
                cr_updated_by: bool,
                oa_retracted: bool,
            ) -> None:
                notices.append({
                    "DOI": notice_doi,
                    "update-to": [{"DOI": target_doi, "type": "retraction"}],
                })
                cr_msg: Dict[str, Any] = {
                    "DOI": target_doi,
                    "type": "journal-article",
                    "title": [title],
                    "container-title": ["Journal of Retraction Testing"],
                    "author": [{"given": "Dana", "family": "Kerr", "sequence": "first"}],
                    "issued": {"date-parts": [[2020, 6, 1]]},
                }
                if cr_updated_by:
                    cr_msg["updated-by"] = [{"DOI": notice_doi, "type": "retraction"}]
                _save_raw_response(
                    raw_dir,
                    _common.crossref_work_url(target_doi),
                    {"status": "ok", "message": cr_msg},
                    status=200,
                )
                _save_raw_response(
                    raw_dir,
                    _common.openalex_work_url(target_doi),
                    {"id": "https://openalex.org/W1", "doi": "https://doi.org/" + target_doi, "is_retracted": oa_retracted},
                    status=200,
                )

            # 1) Built-in retracted DOI -> must be skipped without even needing single-work lookup
            notices.append({
                "DOI": "10.1038/notice.builtin",
                "update-to": [{"DOI": "10.1038/nature12968", "type": "retraction"}],
            })
            # 2) Neither Crossref updated-by nor OpenAlex is_retracted -> must be skipped
            add_candidate(
                "10.7700/notice.neither",
                "10.7700/work.neither",
                "Work Without Confirmed Retraction Flag",
                cr_updated_by=False,
                oa_retracted=False,
            )
            # 3) Five candidates under prefix 10.7701 -> at most 3 may be accepted!
            for idx in range(1, 6):
                add_candidate(
                    "10.7701/notice.%02d" % idx,
                    "10.7701/work.%02d" % idx,
                    "RETRACTED: Prefix Cap Study %02d" % idx,
                    cr_updated_by=True,
                    oa_retracted=(idx == 1),
                )
            # 4) Candidate accepted via OpenAlex is_retracted only
            add_candidate(
                "10.7702/notice.oaonly",
                "10.7702/work.oaonly",
                "OpenAlex Only Retracted Work",
                cr_updated_by=False,
                oa_retracted=True,
            )

            search_url = build_retracted.build_retraction_notices_url(page_rows := 20, offset=0)
            _save_raw_response(
                raw_dir,
                search_url,
                {"status": "ok", "message": {"items": notices}},
                status=200,
            )

            summary = build_retracted.build_retracted(
                bench_dir=td,
                seed=20261116,
                offline=True,
                target_count=4,
                max_per_prefix=3,
                page_rows=page_rows,
                max_pages=1,
            )
            self.assertEqual(summary["entries_written"], 4)
            self.assertEqual(summary["prefix_counts"]["10.7701"], 3)
            self.assertEqual(summary["prefix_counts"]["10.7702"], 1)

            entries = _common.parse_bibtex_entries(
                pathlib.Path(td, "entries", "retracted.bib").read_text(encoding="utf-8")
            )
            self.assertEqual(len(entries), 4)
            retracted_titles = [e.fields["title"] for e in entries]
            self.assertTrue(any(t.startswith("RETRACTED: Prefix Cap Study") for t in retracted_titles))

            gold_rows = [
                json.loads(line)
                for line in pathlib.Path(td, "gold.jsonl").read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            bases = {r["provenance"]["retraction_basis"] for r in gold_rows}
            self.assertIn("openalex_is_retracted", bases)
            self.assertTrue(bases & {"crossref_updated_by", "both"})
            for r in gold_rows:
                self.assertEqual(r["truth"], "retracted")
                self.assertEqual(r["expected"], ["RETRACTED"])
                self.assertFalse(r["insertable"])
                self.assertNotIn(
                    _common.normalize_doi(r["provenance"]["doi"]),
                    _common.BUILTIN_RETRACTED_DOIS,
                )

    # ------------------------------------------------------------------
    # 5. All 7 mutation rules + accent-shortage whitespace fallback
    # ------------------------------------------------------------------
    def test_all_mutation_rules_and_accent_fallback(self) -> None:
        # Subtest A: 24 clean entries across 6 strata (3 fields x 2 bands), 6 accented surnames,
        # entry #1 has [year-1, year, year+1] all occupied so mut_year1 must skip it,
        # and mut_doi_missing encounters responseCode=1 on attempt #1 and switches to attempt #2.
        strata_6 = [
            s
            for s in build_real_clean.STRATA
            if s["field_slug"] in ("cs", "medicine", "social_sciences")
            and s["year_start"] in (2000, 2010)
        ]
        self.assertEqual(len(strata_6), 6)

        with tempfile.TemporaryDirectory() as td:
            self._populate_synthetic_real_clean_cache(
                td,
                seed=20261116,
                strata=strata_6,
                per_stratum=4,
                sample_size=12,
                accented_count=6,
                include_three_year_blocked_record=True,
            )
            build_real_clean.build_real_clean(
                bench_dir=td,
                seed=20261116,
                offline=True,
                per_stratum=4,
                sample_size=12,
                strata=strata_6,
            )
            collided_doi = self._populate_missing_doi_handles_cache(
                td,
                sources_count_to_seed=20,
                seed=20261116,
                force_first_collision=True,
            )
            self.assertIsNotNone(collided_doi)

            summary = build_mutations.build_mutations(
                bench_dir=td,
                seed=20261116,
                confirm_missing=True,
                offline=True,
                per_group=20,
            )
            self.assertEqual(summary["entries_written"], 140)
            self.assertEqual(summary["network_requests"], 0)

            clean_by_key = {
                r.key: r for r in build_mutations.load_real_clean_sources(td)
            }
            gold_by_group: Dict[str, List[Dict[str, Any]]] = {}
            for line in pathlib.Path(td, "gold.jsonl").read_text(encoding="utf-8").splitlines():
                if line.strip():
                    obj = json.loads(line)
                    gold_by_group.setdefault(obj["group"], []).append(obj)

            # Check distinct 20 source_keys per group and seed in provenance
            for grp in (
                "real_typo",
                "mut_year1",
                "mut_year3",
                "mut_author",
                "mut_title",
                "mut_doi_swap",
                "mut_doi_missing",
            ):
                rows = gold_by_group[grp]
                self.assertEqual(len(rows), 20)
                src_keys = [r["provenance"]["source_key"] for r in rows]
                self.assertEqual(len(set(src_keys)), 20, "Duplicate source_key in %s" % grp)
                for r in rows:
                    self.assertEqual(r["truth"], "mutated")
                    self.assertEqual(r["provenance"]["seed"], 20261116)

            # Verify real_typo breakdown (5 typo DRIFT + 5 accent VERIFIED + 5 https + 5 uppercase)
            typo_rows = gold_by_group["real_typo"]
            by_mut = {}
            for r in typo_rows:
                m = r["provenance"]["mutation"]
                by_mut[m] = by_mut.get(m, 0) + 1
                if m == "title_single_letter_typo":
                    self.assertEqual(r["expected"], ["DRIFT"])
                    self.assertFalse(r["insertable"])
                else:
                    self.assertEqual(r["expected"], ["VERIFIED"])
                    self.assertTrue(r["insertable"])
            self.assertEqual(by_mut, {
                "title_single_letter_typo": 5,
                "strip_first_author_surname_accents": 5,
                "doi_https_prefix": 5,
                "doi_uppercase": 5,
            })

            # Verify mut_year1 skipped real_clean_001 (whose 3 dates span [year-1, year, year+1])
            y1_src_keys = {r["provenance"]["source_key"] for r in gold_by_group["mut_year1"]}
            self.assertNotIn("real_clean_001", y1_src_keys)
            for r in gold_by_group["mut_year1"]:
                mut_y = r["provenance"]["mutated_year"]
                orig_y = r["provenance"]["original_year"]
                all_y = r["provenance"]["all_record_years"]
                self.assertEqual(abs(mut_y - orig_y), 1)
                self.assertNotIn(mut_y, all_y)

            # Verify mut_year3 differs by 3..5 from all dates
            for r in gold_by_group["mut_year3"]:
                mut_y = r["provenance"]["mutated_year"]
                all_y = r["provenance"]["all_record_years"]
                for y in all_y:
                    self.assertGreaterEqual(abs(mut_y - y), 3)

            # Verify mut_author swaps from same field
            for r in gold_by_group["mut_author"]:
                s_rec = clean_by_key[r["provenance"]["source_key"]]
                d_rec = clean_by_key[r["provenance"]["donor_key"]]
                self.assertEqual(s_rec.field_slug, d_rec.field_slug)
                self.assertNotEqual(s_rec.first_surname, d_rec.first_surname)

            # Verify mut_title has 10 spliced + 10 (insert_not / word_order_swap)
            title_muts = [r["provenance"]["mutation"] for r in gold_by_group["mut_title"]]
            self.assertEqual(title_muts.count("title_prefix_plus_same_field_tail"), 10)
            self.assertEqual(
                title_muts.count("title_insert_not") + title_muts.count("title_word_order_swap"),
                10,
            )

            # Verify mut_doi_swap swaps from a DIFFERENT stratum
            for r in gold_by_group["mut_doi_swap"]:
                self.assertNotEqual(
                    r["provenance"]["source_stratum"],
                    r["provenance"]["donor_stratum"],
                )

            # Verify mut_doi_missing skipped collided_doi (responseCode=1) and kept responseCode=100
            miss_dois = {r["provenance"]["mutated_doi"] for r in gold_by_group["mut_doi_missing"]}
            self.assertNotIn(collided_doi, miss_dois)
            self.assertTrue(
                any(r["provenance"]["attempts"] == 2 for r in gold_by_group["mut_doi_missing"])
            )
            for r in gold_by_group["mut_doi_missing"]:
                self.assertEqual(r["expected"], ["DRIFT", "NOT_FOUND"])
                self.assertFalse(r["insertable"])
                self.assertEqual(
                    _common.doi_prefix(r["provenance"]["mutated_doi"]),
                    _common.doi_prefix(r["provenance"]["true_doi"]),
                )

        # Subtest B: Only 2 accented surnames in real_clean -> 2 accent-stripped + 3 DOI whitespace
        with tempfile.TemporaryDirectory() as td2:
            self._populate_synthetic_real_clean_cache(
                td2,
                seed=20261116,
                strata=strata_6,
                per_stratum=4,
                sample_size=12,
                accented_count=2,
            )
            build_real_clean.build_real_clean(
                bench_dir=td2,
                seed=20261116,
                offline=True,
                per_stratum=4,
                sample_size=12,
                strata=strata_6,
            )
            build_mutations.build_mutations(
                bench_dir=td2,
                seed=20261116,
                confirm_missing=False,
                offline=True,
                per_group=20,
            )
            typo_bib_raw = pathlib.Path(td2, "entries", "real_typo.bib").read_text(
                encoding="utf-8"
            )
            # Exactly 3 entries must have leading and trailing spaces inside doi = {  10....  }
            padded_matches = re.findall(r"doi = \{  10\.[^}]+  \}", typo_bib_raw)
            self.assertEqual(len(padded_matches), 3)

    # ------------------------------------------------------------------
    # 6. Byte-for-byte determinism with identical saved responses + seed
    # ------------------------------------------------------------------
    def test_byte_for_byte_determinism_same_inputs_and_seed(self) -> None:
        mini_strata = [
            s
            for s in build_real_clean.STRATA
            if s["field_slug"] in ("cs", "medicine") and s["year_start"] in (2000, 2010)
        ]
        with tempfile.TemporaryDirectory() as run_a, tempfile.TemporaryDirectory() as run_b:
            for root in (run_a, run_b):
                self._populate_synthetic_real_clean_cache(
                    root, seed=99, strata=mini_strata, per_stratum=2, sample_size=10
                )
                build_real_clean.build_real_clean(
                    bench_dir=root,
                    seed=99,
                    offline=True,
                    per_stratum=2,
                    sample_size=10,
                    strata=mini_strata,
                )
                self._populate_missing_doi_handles_cache(
                    root, sources_count_to_seed=4, seed=99
                )
                build_mutations.build_mutations(
                    bench_dir=root,
                    seed=99,
                    confirm_missing=True,
                    offline=True,
                    per_group=4,
                )

            rel_files = [
                os.path.join("gold.jsonl"),
                os.path.join("entries", "real_clean.bib"),
                os.path.join("entries", "real_typo.bib"),
                os.path.join("entries", "mut_year1.bib"),
                os.path.join("entries", "mut_year3.bib"),
                os.path.join("entries", "mut_author.bib"),
                os.path.join("entries", "mut_title.bib"),
                os.path.join("entries", "mut_doi_swap.bib"),
                os.path.join("entries", "mut_doi_missing.bib"),
                os.path.join("sources", "real_clean", "dois.tsv"),
            ]
            for rel in rel_files:
                bytes_a = pathlib.Path(run_a, rel).read_bytes()
                bytes_b = pathlib.Path(run_b, rel).read_bytes()
                self.assertEqual(bytes_a, bytes_b, "Byte mismatch on rerun for %s" % rel)

    # ------------------------------------------------------------------
    # 7. --offline missing raw response fails cleanly with ZERO network calls
    # ------------------------------------------------------------------
    def test_offline_flag_errors_without_network_on_cache_miss(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            err_buf = io.StringIO()
            with mock.patch.object(
                urllib.request.OpenerDirector,
                "open",
                side_effect=AssertionError("Network must NEVER be called under --offline"),
            ), contextlib.redirect_stderr(err_buf):
                # 1. build_real_clean --offline on empty raw/
                rc_code = build_real_clean.main([
                    "--bench-dir", td, "--seed", "20261116", "--offline"
                ])
                self.assertNotEqual(rc_code, 0)

                # 2. build_retracted --offline on empty raw/
                ret_code = build_retracted.main([
                    "--bench-dir", td, "--seed", "20261116", "--offline"
                ])
                self.assertNotEqual(ret_code, 0)

                # 3. build_mutations --confirm-missing --offline with missing doi.org raw file
                mini_strata = build_real_clean.STRATA[:2]
                self._populate_synthetic_real_clean_cache(
                    td, seed=20261116, strata=mini_strata, per_stratum=2, sample_size=10
                )
                build_real_clean.build_real_clean(
                    bench_dir=td,
                    seed=20261116,
                    offline=True,
                    per_stratum=2,
                    sample_size=10,
                    strata=mini_strata,
                )
                mut_code = build_mutations.main([
                    "--bench-dir",
                    td,
                    "--seed",
                    "20261116",
                    "--per-group",
                    "4",
                    "--confirm-missing",
                    "--offline",
                ])
                self.assertNotEqual(mut_code, 0)
            self.assertEqual(err_buf.getvalue().count("Offline mode cache miss"), 3)

    # ------------------------------------------------------------------
    # 8. HTTP client User-Agent, host guard, spacing, 429 Retry-After, OpenAlex < 50 stop
    # ------------------------------------------------------------------
    def test_http_client_headers_spacing_retry_and_openalex_budget_guard(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            raw_dir = os.path.join(td, "raw")
            log_path = os.path.join(td, "requests.log")
            now_val = [100.0]
            sleeps: List[float] = []

            def fake_clock() -> float:
                return now_val[0]

            def fake_sleep(dt: float) -> None:
                sleeps.append(round(dt, 4))
                now_val[0] += dt

            opener = _ScriptedOpener([
                # 1st call: Crossref search -> 429 with Retry-After: 3, then 200
                (429, "rate limited", {"Retry-After": "3"}),
                (200, '{"message":{"items":[]}}', {"Content-Type": "application/json"}),
                # 2nd call: Crossref single-work -> spacing >= 0.25s
                (200, '{"message":{"DOI":"10.1000/a"}}', {"Content-Type": "application/json"}),
                # 3rd call: another Crossref search immediately -> must wait so search-to-search >= 1.1s
                (200, '{"message":{"items":[]}}', {"Content-Type": "application/json"}),
                # 4th call: OpenAlex with x-ratelimit-remaining=49 -> saves raw and stops!
                (
                    200,
                    '{"results":[]}',
                    {"Content-Type": "application/json", "x-ratelimit-remaining": "49", "x-ratelimit-reset": "1200"},
                ),
            ])

            client = _common.BenchmarkHTTPClient(
                raw_dir=raw_dir,
                requests_log_path=log_path,
                offline=False,
                sleep_fn=fake_sleep,
                clock_fn=fake_clock,
                utc_now_fn=lambda: "2026-11-16T12:00:00Z",
                opener=opener,
            )

            # Disallowed host rejected before opener
            with self.assertRaises(_common.BenchmarkToolError):
                client.get("https://example.com/works")

            # 1) Crossref search with 429 retry
            u_search1 = "https://api.crossref.org/works?rows=1"
            r1 = client.get(u_search1)
            self.assertEqual(r1["status"], 200)
            self.assertIn(3.0, sleeps)

            # Re-requesting same URL reuses raw/<sha1>.json with 0 new opener calls
            before_calls = len(opener.seen_requests)
            r1_cached = client.get(u_search1)
            self.assertEqual(r1_cached["status"], 200)
            self.assertEqual(len(opener.seen_requests), before_calls)
            self.assertEqual(client.reused_responses, 1)

            # 2) Crossref single-work (0.1s later -> sleeps 0.15s to hit 0.25s)
            now_val[0] += 0.10
            client.get("https://api.crossref.org/works/10.1000/a")
            self.assertIn(0.15, sleeps)

            # 3) Second Crossref search (0.1s later -> only 0.35s since 1st search, sleeps 1.1s from last Crossref call)
            now_val[0] += 0.10
            client.get("https://api.crossref.org/works?rows=2")

            # Verify User-Agent header on every outgoing request
            for _, req_headers in opener.seen_requests:
                self.assertEqual(req_headers.get("user-agent"), "ScholarOS-benchmark/1.0")

            # 4) OpenAlex x-ratelimit-remaining < 50 raises OpenAlexBudgetLowError AFTER saving raw file
            oa_url = "https://api.openalex.org/works?sample=1&seed=1"
            with self.assertRaises(_common.OpenAlexBudgetLowError):
                client.get(oa_url)
            self.assertTrue(os.path.isfile(client.raw_path_for(oa_url)))

            log_lines = pathlib.Path(log_path).read_text(encoding="utf-8").strip().splitlines()
            self.assertEqual(len(log_lines), 5)

    # ------------------------------------------------------------------
    # 9. check_benchmark.py on current repo skeleton AND complete 480-entry synthetic corpus
    # ------------------------------------------------------------------
    def test_check_benchmark_on_repo_and_complete_synthetic_corpus(self) -> None:
        # Part A: Actual repository Benchmarks/citations/ state (all 12 groups, 480 entries generated)
        ok_repo, rep_repo = check_benchmark.check_benchmark(BENCH_DIR)
        self.assertTrue(ok_repo)
        self.assertEqual(rep_repo["errors"], [])
        self.assertEqual(rep_repo["entries_total"], 480)
        self.assertEqual(rep_repo["gold_total"], 480)
        self.assertEqual(rep_repo["missing_or_incomplete_groups"], [])

        # Part B: Assemble a complete 480-entry benchmark directory in temp dir and verify exit 0
        with tempfile.TemporaryDirectory() as td:
            for sub in ("entries", "sources/fabricated_model/evidence", "recordings", "tools"):
                os.makedirs(os.path.join(td, sub), exist_ok=True)
            with open(os.path.join(td, "README.md"), "w", encoding="utf-8") as f:
                f.write("# Synthetic Complete Benchmark\n")

            gold_rows: List[str] = []
            rev_rows: List[str] = ["key\tverdict\tmatched_work\treviewer\treviewed_at\tnote"]

            for grp, count in _common.GROUP_SPECS:
                keys = _common.expected_keys_for_group(grp, count)
                bib_entries: List[str] = []
                for k in keys:
                    bib_entries.append(
                        _common.serialize_bibtex_entry(
                            "article",
                            k,
                            [
                                ("author", "Tester, Alex"),
                                ("title", "Synthetic Entry %s" % k),
                                ("journal", "Journal of Tests"),
                                ("year", "2020"),
                            ],
                        ).rstrip("\n")
                    )
                    gold_rows.append(
                        json.dumps(
                            {
                                "key": k,
                                "group": grp,
                                "truth": "fabricated" if grp == "fabricated_model" else "real",
                                "expected": ["NOT_FOUND"] if grp == "fabricated_model" else ["VERIFIED"],
                                "insertable": grp != "fabricated_model",
                                "provenance": {"synthetic": True},
                                "note": "",
                            },
                            sort_keys=True,
                        )
                    )
                    if grp == "fabricated_model":
                        ev_path = os.path.join(
                            td, "sources", "fabricated_model", "evidence", "%s.json" % k
                        )
                        with open(ev_path, "w", encoding="utf-8") as ef:
                            json.dump({"key": k, "flag": "clean"}, ef)
                        rev_rows.append("%s\tno_such_work\t\tUnitTestReviewer\t2026-11-16\tok" % k)

                with open(os.path.join(td, "entries", "%s.bib" % grp), "w", encoding="utf-8") as bf:
                    bf.write("\n\n".join(bib_entries) + "\n")

            with open(os.path.join(td, "gold.jsonl"), "w", encoding="utf-8") as gf:
                gf.write("\n".join(gold_rows) + "\n")
            with open(
                os.path.join(td, "sources", "fabricated_model", "review.tsv"),
                "w",
                encoding="utf-8",
            ) as rf:
                rf.write("\n".join(rev_rows) + "\n")

            ok_full, rep_full = check_benchmark.check_benchmark(td)
            self.assertTrue(ok_full, "Expected full synthetic corpus to pass: %s" % rep_full)
            self.assertEqual(rep_full["entries_total"], 480)
            self.assertEqual(rep_full["gold_total"], 480)

            # Corrupt one expected verdict -> must fail
            bad_line = json.loads(gold_rows[0])
            bad_line["expected"] = ["BOGUS_CLASS"]
            with open(os.path.join(td, "gold.jsonl"), "w", encoding="utf-8") as gf:
                gf.write("\n".join([json.dumps(bad_line)] + gold_rows[1:]) + "\n")
            ok_bad, rep_bad = check_benchmark.check_benchmark(td)
            self.assertFalse(ok_bad)
            self.assertTrue(any("BOGUS_CLASS" in e for e in rep_bad["errors"]))


if __name__ == "__main__":
    unittest.main()
