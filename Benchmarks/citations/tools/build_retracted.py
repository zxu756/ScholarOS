#!/usr/bin/env python3
"""Build the 'retracted' benchmark group (30 retracted publications).

Usage:
  python3 -I Benchmarks/citations/tools/build_retracted.py [--seed 20261116] [--offline]
  python3 -I Benchmarks/citations/tools/build_retracted.py --bench-dir <dir> [--seed 20261116] [--offline]

Discovers retraction notices via Crossref /works?filter=update-type:retraction, extracts the
target DOI from update-to, and fetches both the target work's Crossref record (/works/<DOI>)
and OpenAlex record (/works/https://doi.org/<DOI>).

Acceptance rules:
- Excluded if target DOI is in ScholarOS's built-in defaultRetractedDOIs list.
- At most 3 entries per DOI registrant prefix (e.g. 10.1016).
- Target work must have a Crossref record with title (no HTML/MathML tags), author, and year.
- Target work's own Crossref record must carry an updated-by retraction item OR OpenAlex
  must report is_retracted == true.
- Entry metadata (including exact Crossref title) is serialized from the target work's Crossref record.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
import urllib.parse
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    BenchmarkHTTPClient,
    BenchmarkToolError,
    crossref_has_updated_by_retraction,
    crossref_message_to_bibtex,
    crossref_work_url,
    default_bench_dir,
    doi_prefix,
    extract_all_crossref_years,
    extract_crossref_date_str,
    has_balanced_braces,
    has_html_or_mathml_tags,
    normalize_doi,
    openalex_work_url,
    order_crossref_authors,
    update_gold_jsonl,
)

# Exact copy of CitationVerificationFirewall.defaultRetractedDOIs in
# Sources/ScholarBibAndCSL/CitationVerificationFirewall.swift (verified by tools/tests/).
PRODUCT_BUILTIN_RETRACTED_DOIS = frozenset({
    "10.1016/s0140-6736(97)11096-0",
    "10.1016/s0140-6736(20)31180-6",
    "10.1056/nejmoa2007621",
    "10.1038/nature12968",
    "10.1038/nature12969",
    "10.1126/science.287.5455.1022",
    "10.1038/s41586-020-2801-z",
    "10.1038/s41586-023-05742-0",
})

CROSSREF_WORKS_URL = "https://api.crossref.org/works"
TARGET_COUNT = 30
MAX_PER_DOI_PREFIX = 3
PAGE_ROWS = 100
MAX_PAGES = 25
DEFAULT_SEED = 20261116


def build_retraction_notices_url(rows: int, offset: int) -> str:
    params = [
        ("filter", "update-type:retraction"),
        ("offset", str(offset)),
        ("order", "desc"),
        ("rows", str(rows)),
        ("sort", "published"),
    ]
    return CROSSREF_WORKS_URL + "?" + urllib.parse.urlencode(params)


def extract_retracted_target_dois(notice_item: Dict[str, Any]) -> List[Tuple[str, str]]:
    """Return [(notice_doi, target_doi)] from a Crossref retraction notice item."""
    notice_doi = str(notice_item.get("DOI") or "").strip()
    if not notice_doi:
        return []
    updates = notice_item.get("update-to")
    if not isinstance(updates, list):
        return []
    pairs: List[Tuple[str, str]] = []
    for u in updates:
        if not isinstance(u, dict):
            continue
        utype = str(u.get("type") or "").strip().lower()
        target_doi = str(u.get("DOI") or "").strip()
        if "retraction" in utype and target_doi:
            pairs.append((notice_doi, target_doi))
    return pairs


def validate_retracted_work_metadata(msg: Any) -> Tuple[bool, str]:
    """Validate that a retracted work's Crossref record can be serialized cleanly to BibTeX."""
    if not isinstance(msg, dict):
        return False, "not a Crossref message dict"
    c_type = str(msg.get("type") or "").lower()
    if c_type not in ("journal-article", "proceedings-article"):
        return False, "unsupported Crossref type %r" % (c_type,)
    raw_doi = str(msg.get("DOI") or "").strip()
    if not raw_doi:
        return False, "missing DOI"

    titles = msg.get("title")
    if not isinstance(titles, list) or not titles or not str(titles[0] or "").strip():
        return False, "missing title"
    title = re.sub(r"\s+", " ", str(titles[0])).strip()
    if has_html_or_mathml_tags(title):
        return False, "title contains HTML or MathML tags"
    if not has_balanced_braces(title):
        return False, "title has unbalanced braces"

    containers = msg.get("container-title")
    if isinstance(containers, list) and containers:
        venue = re.sub(r"\s+", " ", str(containers[0] or "")).strip()
        if has_html_or_mathml_tags(venue) or not has_balanced_braces(venue):
            return False, "container-title has HTML tags or unbalanced braces"

    raw_authors = msg.get("author")
    if not isinstance(raw_authors, list) or not raw_authors:
        return False, "missing author"
    ordered = order_crossref_authors([a for a in raw_authors if isinstance(a, dict)])
    if not ordered:
        return False, "empty author list"
    first = ordered[0]
    if not (str(first.get("family") or "").strip() or str(first.get("name") or "").strip()):
        return False, "first author missing family/name"
    for au in ordered:
        fam = str(au.get("family") or "").strip()
        giv = str(au.get("given") or "").strip()
        corp = str(au.get("name") or "").strip()
        if not (fam or corp):
            return False, "author missing family and name"
        for field_txt in (fam, giv, corp):
            if has_html_or_mathml_tags(field_txt) or not has_balanced_braces(field_txt):
                return False, "author contains tags or unbalanced braces"
        if re.search(r"\band\b", fam, re.I) or re.search(r"\band\b", giv, re.I):
            return False, "author contains literal 'and' separator"

    if not extract_all_crossref_years(msg):
        return False, "missing publication year"

    return True, "ok"


def build_retracted(
    bench_dir: str,
    seed: int = DEFAULT_SEED,
    offline: bool = False,
    target_count: int = TARGET_COUNT,
    max_per_prefix: int = MAX_PER_DOI_PREFIX,
    page_rows: int = PAGE_ROWS,
    max_pages: int = MAX_PAGES,
    http_client: Optional[BenchmarkHTTPClient] = None,
) -> Dict[str, Any]:
    src_dir = os.path.join(bench_dir, "sources", "retracted")
    raw_dir = os.path.join(src_dir, "raw")
    req_log = os.path.join(src_dir, "requests.log")
    os.makedirs(src_dir, exist_ok=True)

    client = http_client or BenchmarkHTTPClient(
        raw_dir=raw_dir,
        requests_log_path=req_log,
        offline=offline,
    )

    seen_targets: Set[str] = set()
    prefix_counts: Dict[str, int] = {}
    bib_blocks: List[str] = []
    gold_rows: List[Dict[str, Any]] = []
    sampling_tsv_rows: List[List[str]] = []
    retracted_tsv_rows: List[List[str]] = []

    for page_idx in range(max_pages):
        if len(gold_rows) >= target_count:
            break
        offset = page_idx * page_rows
        notices_url = build_retraction_notices_url(page_rows, offset)
        resp = client.get(notices_url)
        if resp["status"] != 200:
            raise BenchmarkToolError(
                "Crossref retraction notice search returned status %s for %s"
                % (resp["status"], notices_url)
            )
        try:
            payload = json.loads(resp["body"])
            items = payload["message"]["items"]
        except Exception as err:
            raise BenchmarkToolError(
                "Invalid Crossref search JSON for %s: %s" % (notices_url, err)
            ) from err

        if not items:
            break

        candidates: List[Tuple[str, str]] = []
        for notice in items:
            if isinstance(notice, dict):
                candidates.extend(extract_retracted_target_dois(notice))

        rng = random.Random(seed + page_idx)
        rng.shuffle(candidates)

        accepted_on_page = 0
        for notice_doi, raw_target_doi in candidates:
            if len(gold_rows) >= target_count:
                break
            norm_target = normalize_doi(raw_target_doi)
            if not norm_target or "/" not in norm_target:
                continue
            if norm_target in seen_targets:
                continue
            if norm_target in PRODUCT_BUILTIN_RETRACTED_DOIS:
                continue
            pref = doi_prefix(norm_target)
            if prefix_counts.get(pref, 0) >= max_per_prefix:
                continue

            seen_targets.add(norm_target)

            cr_url = crossref_work_url(norm_target)
            cr_resp = client.get(cr_url)
            if cr_resp["status"] != 200:
                continue
            try:
                cr_msg = json.loads(cr_resp["body"]).get("message")
            except Exception:
                continue

            ok, _ = validate_retracted_work_metadata(cr_msg)
            if not ok or not isinstance(cr_msg, dict):
                continue

            oa_url = openalex_work_url(norm_target)
            oa_resp = client.get(oa_url)
            oa_is_retracted = False
            if oa_resp["status"] == 200:
                try:
                    oa_obj = json.loads(oa_resp["body"])
                    oa_is_retracted = bool(
                        isinstance(oa_obj, dict) and oa_obj.get("is_retracted") is True
                    )
                except Exception:
                    oa_is_retracted = False

            cr_updated_by = crossref_has_updated_by_retraction(cr_msg)
            if not (cr_updated_by or oa_is_retracted):
                continue

            if cr_updated_by and oa_is_retracted:
                basis = "both"
            elif cr_updated_by:
                basis = "crossref_updated_by"
            else:
                basis = "openalex_is_retracted"

            canonical_msg_doi = normalize_doi(cr_msg.get("DOI")) or norm_target
            if canonical_msg_doi in PRODUCT_BUILTIN_RETRACTED_DOIS:
                continue
            canonical_pref = doi_prefix(canonical_msg_doi)
            if prefix_counts.get(canonical_pref, 0) >= max_per_prefix:
                continue

            prefix_counts[canonical_pref] = prefix_counts.get(canonical_pref, 0) + 1
            cite_key = "retracted_%03d" % (len(gold_rows) + 1)
            bib_text = crossref_message_to_bibtex(
                cite_key, cr_msg, require_issued_year=False
            )
            bib_blocks.append(bib_text.rstrip("\n"))

            exact_doi = str(cr_msg.get("DOI") or raw_target_doi).strip()
            gold_rows.append(
                {
                    "key": cite_key,
                    "group": "retracted",
                    "truth": "retracted",
                    "expected": ["RETRACTED"],
                    "insertable": False,
                    "provenance": {
                        "crossref_updated_by": cr_updated_by,
                        "crossref_url": cr_url,
                        "doi": exact_doi,
                        "doi_prefix": canonical_pref,
                        "issued": extract_crossref_date_str(cr_msg.get("issued")),
                        "openalex_is_retracted": oa_is_retracted,
                        "openalex_url": oa_url,
                        "published-online": extract_crossref_date_str(
                            cr_msg.get("published-online")
                        ),
                        "published-print": extract_crossref_date_str(
                            cr_msg.get("published-print")
                        ),
                        "retraction_basis": basis,
                        "retraction_notice_doi": notice_doi,
                        "seed": seed,
                    },
                    "note": "",
                }
            )
            retracted_tsv_rows.append(
                [
                    cite_key,
                    exact_doi,
                    canonical_pref,
                    notice_doi,
                    basis,
                    "yes" if cr_updated_by else "no",
                    "yes" if oa_is_retracted else "no",
                ]
            )
            accepted_on_page += 1

        sampling_tsv_rows.append(
            [
                str(page_idx + 1),
                str(offset),
                str(len(items)),
                str(len(candidates)),
                str(accepted_on_page),
                notices_url,
            ]
        )

    if len(gold_rows) < target_count:
        raise BenchmarkToolError(
            "Collected only %d/%d retracted entries after %d pages"
            % (len(gold_rows), target_count, max_pages)
        )

    entries_dir = os.path.join(bench_dir, "entries")
    os.makedirs(entries_dir, exist_ok=True)
    bib_path = os.path.join(entries_dir, "retracted.bib")
    with open(bib_path, "w", encoding="utf-8", newline="\n") as out:
        out.write("\n\n".join(bib_blocks) + "\n")

    with open(
        os.path.join(src_dir, "sampling-requests.tsv"),
        "w",
        encoding="utf-8",
        newline="\n",
    ) as out:
        out.write(
            "\t".join(
                [
                    "page",
                    "offset",
                    "notices_returned",
                    "candidate_targets",
                    "accepted_count",
                    "crossref_search_url",
                ]
            )
            + "\n"
        )
        for row in sampling_tsv_rows:
            out.write("\t".join(row) + "\n")

    with open(
        os.path.join(src_dir, "retracted-dois.tsv"),
        "w",
        encoding="utf-8",
        newline="\n",
    ) as out:
        out.write(
            "\t".join(
                [
                    "key",
                    "doi",
                    "doi_prefix",
                    "retraction_notice_doi",
                    "retraction_basis",
                    "crossref_updated_by",
                    "openalex_is_retracted",
                ]
            )
            + "\n"
        )
        for row in retracted_tsv_rows:
            out.write("\t".join(row) + "\n")

    gold_path = os.path.join(bench_dir, "gold.jsonl")
    update_gold_jsonl(gold_path, {"retracted": gold_rows})

    return {
        "entries_written": len(gold_rows),
        "prefix_counts": prefix_counts,
        "network_requests": client.network_requests,
        "reused_responses": client.reused_responses,
        "last_openalex_remaining": client.last_openalex_remaining,
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Build the retracted (30 entries) citation benchmark group."
    )
    parser.add_argument(
        "--bench-dir",
        default=default_bench_dir(),
        help="Path to Benchmarks/citations directory (default: %(default)s)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=DEFAULT_SEED,
        help="Random seed for candidate ordering within pages (default: %(default)s)",
    )
    parser.add_argument(
        "--offline",
        action="store_true",
        help="Read only saved responses in sources/retracted/raw/; never access network",
    )
    parser.add_argument(
        "--target-count",
        type=int,
        default=TARGET_COUNT,
        help="Number of retracted entries to collect (default: %(default)s)",
    )
    args = parser.parse_args(argv)

    try:
        summary = build_retracted(
            bench_dir=args.bench_dir,
            seed=args.seed,
            offline=args.offline,
            target_count=args.target_count,
        )
    except BenchmarkToolError as err:
        sys.stderr.write("ERROR: %s\n" % err)
        return 2

    print(
        "retracted complete: %d entries across %d DOI prefixes (live requests=%d, reused=%d, OpenAlex remaining=%s)"
        % (
            summary["entries_written"],
            len(summary["prefix_counts"]),
            summary["network_requests"],
            summary["reused_responses"],
            summary["last_openalex_remaining"],
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
