#!/usr/bin/env python3
"""Build the 'real_clean' benchmark group (100 clean real journal articles).

Usage:
  python3 -I Benchmarks/citations/tools/build_real_clean.py [--seed 20261116] [--offline]
  python3 -I Benchmarks/citations/tools/build_real_clean.py --bench-dir <dir> [--seed 20261116] [--offline]

Stratified sampling via OpenAlex /works (sample + seed, type:article, has_doi:true) across
5 primary_topic.field strata x 4 publication-year bands (20 strata x 5 entries = 100 entries).
Candidates in each stratum are checked in returned order against Crossref /works/<DOI> until
5 eligible journal-article records are collected.

Every raw HTTP response is saved under sources/real_clean/raw/<sha1>.json and reused on reruns.
With --offline, only saved responses in sources/real_clean/raw/ are read (zero network calls).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    BUILTIN_RETRACTED_DOIS,
    BenchmarkHTTPClient,
    BenchmarkToolError,
    crossref_message_to_bibtex,
    crossref_work_url,
    default_bench_dir,
    extract_crossref_date_str,
    extract_crossref_year,
    normalize_doi,
    update_gold_jsonl,
    validate_clean_crossref_article,
)

# ---------------------------------------------------------------------------
# Configurable Sampling & Stratification Constants (edit here if OpenAlex changes parameter names)
# ---------------------------------------------------------------------------

OPENALEX_WORKS_URL = "https://api.openalex.org/works"
OPENALEX_BASE_FILTER = "type:article,has_doi:true"
OPENALEX_FIELD_FILTER_KEY = "primary_topic.field.id"
OPENALEX_YEAR_FILTER_TEMPLATE = "publication_year:{start}-{end}"

# OpenAlex ASJC-derived field IDs: short form "fields/<id>" avoids extra ':' inside filter=key:value
# (equivalent full IDs: https://openalex.org/fields/17, /27, /31, /13, /33; numeric: 17, 27, 31, 13, 33).
FIELDS: Tuple[Tuple[str, str, str], ...] = (
    ("cs", "Computer Science", "fields/17"),
    ("medicine", "Medicine", "fields/27"),
    ("physics_astronomy", "Physics and Astronomy", "fields/31"),
    ("biochem_genetics_molbio", "Biochemistry, Genetics and Molecular Biology", "fields/13"),
    ("social_sciences", "Social Sciences", "fields/33"),
)

YEAR_BANDS: Tuple[Tuple[str, int, int], ...] = (
    ("1980_1999", 1980, 1999),
    ("2000_2009", 2000, 2009),
    ("2010_2019", 2010, 2019),
    ("2020_2024", 2020, 2024),
)

STRATA: List[Dict[str, Any]] = [
    {
        "stratum_id": "%s_%s" % (field_slug, band_slug),
        "field_slug": field_slug,
        "field_name": field_name,
        "field_filter_value": field_filter_val,
        "year_band_label": "%d-%d" % (year_start, year_end),
        "year_start": year_start,
        "year_end": year_end,
    }
    for field_slug, field_name, field_filter_val in FIELDS
    for band_slug, year_start, year_end in YEAR_BANDS
]

TARGET_PER_STRATUM = 5
CANDIDATE_SAMPLE_SIZE = 25
MAX_SAMPLE_ROUNDS = 4
DEFAULT_SEED = 20261116


def build_openalex_sample_url(
    stratum: Dict[str, Any],
    sample_size: int,
    stratum_seed: int,
) -> str:
    year_clause = OPENALEX_YEAR_FILTER_TEMPLATE.format(
        start=stratum["year_start"],
        end=stratum["year_end"],
    )
    field_clause = "%s:%s" % (
        OPENALEX_FIELD_FILTER_KEY,
        stratum["field_filter_value"],
    )
    filter_expr = ",".join([OPENALEX_BASE_FILTER, field_clause, year_clause])
    params = [
        ("filter", filter_expr),
        ("per-page", str(sample_size)),
        ("sample", str(sample_size)),
        ("seed", str(stratum_seed)),
    ]
    return OPENALEX_WORKS_URL + "?" + urllib.parse.urlencode(params)


def build_real_clean(
    bench_dir: str,
    seed: int = DEFAULT_SEED,
    offline: bool = False,
    per_stratum: int = TARGET_PER_STRATUM,
    sample_size: int = CANDIDATE_SAMPLE_SIZE,
    strata: Optional[Sequence[Dict[str, Any]]] = None,
    http_client: Optional[BenchmarkHTTPClient] = None,
) -> Dict[str, Any]:
    active_strata = list(strata) if strata is not None else list(STRATA)
    src_dir = os.path.join(bench_dir, "sources", "real_clean")
    raw_dir = os.path.join(src_dir, "raw")
    req_log = os.path.join(src_dir, "requests.log")
    os.makedirs(src_dir, exist_ok=True)

    client = http_client or BenchmarkHTTPClient(
        raw_dir=raw_dir,
        requests_log_path=req_log,
        offline=offline,
    )

    seen_candidate_dois: Set[str] = set()
    accepted_dois: Set[str] = set()
    bib_blocks: List[str] = []
    gold_rows: List[Dict[str, Any]] = []
    sampling_tsv_rows: List[List[str]] = []
    doi_tsv_rows: List[List[str]] = []
    entry_seq = 0

    for s_idx, stratum in enumerate(active_strata):
        stratum_collected = 0
        for round_idx in range(MAX_SAMPLE_ROUNDS):
            if stratum_collected >= per_stratum:
                break
            stratum_seed = seed + s_idx * 100 + round_idx
            sample_url = build_openalex_sample_url(stratum, sample_size, stratum_seed)
            oa_resp = client.get(sample_url)
            if oa_resp["status"] != 200:
                raise BenchmarkToolError(
                    "OpenAlex sample failed with status %s for %s"
                    % (oa_resp["status"], sample_url)
                )
            try:
                oa_payload = json.loads(oa_resp["body"])
            except Exception as err:
                raise BenchmarkToolError(
                    "Invalid JSON from OpenAlex %s: %s" % (sample_url, err)
                ) from err

            results = oa_payload.get("results")
            if not isinstance(results, list):
                raise BenchmarkToolError(
                    "OpenAlex response missing 'results' list for %s" % sample_url
                )

            accepted_in_call = 0
            for item in results:
                if stratum_collected >= per_stratum:
                    break
                if not isinstance(item, dict):
                    continue
                if item.get("is_retracted") is True:
                    continue
                norm_doi = normalize_doi(item.get("doi"))
                if (
                    not norm_doi
                    or norm_doi in seen_candidate_dois
                    or norm_doi in BUILTIN_RETRACTED_DOIS
                ):
                    continue
                seen_candidate_dois.add(norm_doi)

                cr_url = crossref_work_url(norm_doi)
                cr_resp = client.get(cr_url)
                if cr_resp["status"] != 200:
                    continue
                try:
                    cr_payload = json.loads(cr_resp["body"])
                except Exception:
                    continue
                msg = cr_payload.get("message") if isinstance(cr_payload, dict) else None
                ok, _ = validate_clean_crossref_article(msg)
                if not ok or not isinstance(msg, dict):
                    continue

                cr_norm_doi = normalize_doi(msg.get("DOI"))
                if not cr_norm_doi or cr_norm_doi in accepted_dois:
                    continue
                accepted_dois.add(cr_norm_doi)

                entry_seq += 1
                cite_key = "real_clean_%03d" % entry_seq
                bib_text = crossref_message_to_bibtex(
                    cite_key, msg, require_issued_year=True
                )
                bib_blocks.append(bib_text.rstrip("\n"))

                pub_print = extract_crossref_date_str(msg.get("published-print"))
                pub_online = extract_crossref_date_str(msg.get("published-online"))
                issued_str = extract_crossref_date_str(msg.get("issued"))
                issued_year = extract_crossref_year(msg.get("issued"))
                exact_doi = str(msg.get("DOI")).strip()

                gold_rows.append(
                    {
                        "key": cite_key,
                        "group": "real_clean",
                        "truth": "real",
                        "expected": ["VERIFIED"],
                        "insertable": True,
                        "provenance": {
                            "crossref_url": cr_url,
                            "doi": exact_doi,
                            "field": stratum["field_name"],
                            "field_slug": stratum["field_slug"],
                            "issued": issued_str,
                            "openalex_sample_seed": stratum_seed,
                            "openalex_sample_url": sample_url,
                            "published-online": pub_online,
                            "published-print": pub_print,
                            "seed": seed,
                            "stratum": stratum["stratum_id"],
                            "year_band": stratum["year_band_label"],
                        },
                        "note": "",
                    }
                )
                doi_tsv_rows.append(
                    [
                        cite_key,
                        stratum["stratum_id"],
                        stratum["field_name"],
                        stratum["year_band_label"],
                        exact_doi,
                        str(issued_year or ""),
                        pub_print or "",
                        pub_online or "",
                        issued_str or "",
                        cr_url,
                    ]
                )
                stratum_collected += 1
                accepted_in_call += 1

            sampling_tsv_rows.append(
                [
                    stratum["stratum_id"],
                    stratum["field_name"],
                    stratum["year_band_label"],
                    str(stratum_seed),
                    str(round_idx + 1),
                    str(len(results)),
                    str(accepted_in_call),
                    sample_url,
                ]
            )

        if stratum_collected < per_stratum:
            raise BenchmarkToolError(
                "Stratum '%s' collected only %d/%d eligible articles after %d rounds"
                % (
                    stratum["stratum_id"],
                    stratum_collected,
                    per_stratum,
                    MAX_SAMPLE_ROUNDS,
                )
            )

    entries_dir = os.path.join(bench_dir, "entries")
    os.makedirs(entries_dir, exist_ok=True)
    bib_out_path = os.path.join(entries_dir, "real_clean.bib")
    with open(bib_out_path, "w", encoding="utf-8", newline="\n") as out:
        out.write("\n\n".join(bib_blocks) + "\n")

    sampling_tsv_path = os.path.join(src_dir, "sampling-requests.tsv")
    with open(sampling_tsv_path, "w", encoding="utf-8", newline="\n") as out:
        out.write(
            "\t".join(
                [
                    "stratum_id",
                    "field_name",
                    "year_band",
                    "stratum_seed",
                    "round",
                    "candidates_returned",
                    "accepted_count",
                    "openalex_url",
                ]
            )
            + "\n"
        )
        for row in sampling_tsv_rows:
            out.write("\t".join(row) + "\n")

    doi_tsv_path = os.path.join(src_dir, "dois.tsv")
    with open(doi_tsv_path, "w", encoding="utf-8", newline="\n") as out:
        out.write(
            "\t".join(
                [
                    "key",
                    "stratum_id",
                    "field_name",
                    "year_band",
                    "doi",
                    "issued_year",
                    "published_print",
                    "published_online",
                    "issued",
                    "crossref_url",
                ]
            )
            + "\n"
        )
        for row in doi_tsv_rows:
            out.write("\t".join(row) + "\n")

    gold_path = os.path.join(bench_dir, "gold.jsonl")
    update_gold_jsonl(gold_path, {"real_clean": gold_rows})

    return {
        "entries_written": len(gold_rows),
        "network_requests": client.network_requests,
        "reused_responses": client.reused_responses,
        "last_openalex_remaining": client.last_openalex_remaining,
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Build the real_clean (100 entries) citation benchmark group."
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
        help="Base random seed for OpenAlex sample queries (default: %(default)s)",
    )
    parser.add_argument(
        "--offline",
        action="store_true",
        help="Read only saved responses in sources/real_clean/raw/; never access network",
    )
    parser.add_argument(
        "--per-stratum",
        type=int,
        default=TARGET_PER_STRATUM,
        help="Entries per field-x-decade stratum (default: %(default)s)",
    )
    args = parser.parse_args(argv)

    try:
        summary = build_real_clean(
            bench_dir=args.bench_dir,
            seed=args.seed,
            offline=args.offline,
            per_stratum=args.per_stratum,
        )
    except BenchmarkToolError as err:
        sys.stderr.write("ERROR: %s\n" % err)
        return 2

    print(
        "real_clean complete: %d entries written (live requests=%d, reused=%d, OpenAlex remaining=%s)"
        % (
            summary["entries_written"],
            summary["network_requests"],
            summary["reused_responses"],
            summary["last_openalex_remaining"],
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
