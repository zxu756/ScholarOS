#!/usr/bin/env python3
"""Offline structural and integrity checker for Benchmarks/citations/.

Usage:
  python3 -I Benchmarks/citations/tools/check_benchmark.py [--bench-dir <dir>]

Never accesses the network. Verifies:
1. Required directory layout (README.md, entries/, gold.jsonl, sources/, recordings/, tools/)
2. All 12 benchmark groups and their exact entry counts (480 total)
3. Exact citation keys and group prefixes
4. 1-to-1 correspondence between entries/<group>.bib and gold.jsonl
5. gold.jsonl schema, truth values, and expected verdicts (subset of the 5 firewall classes)
6. Per-entry search evidence (evidence/<key>.json) and second-review row (review.tsv) for fabricated_model
7. Every .bib file under entries/ parses cleanly with the built-in BibTeX parser

Exits 0 only when all 12 groups (480 entries) are present and pass every check; exits 1 otherwise.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    BibTeXSyntaxError,
    GROUP_COUNTS,
    GROUP_SPECS,
    REQUIRED_GOLD_FIELDS,
    TOTAL_BENCHMARK_COUNT,
    VALID_TRUTHS,
    VALID_VERDICTS,
    default_bench_dir,
    expected_keys_for_group,
    parse_bibtex_entries,
)

ALLOWED_EXTRA_GOLD_FIELDS = frozenset({"identifier_kind", "review"})


def check_benchmark(bench_dir: str) -> Tuple[bool, Dict[str, Any]]:
    errors: List[str] = []
    missing_or_incomplete_groups: List[str] = []

    # 1. Directory structure
    required_files = [
        os.path.join(bench_dir, "README.md"),
        os.path.join(bench_dir, "gold.jsonl"),
    ]
    required_dirs = [
        os.path.join(bench_dir, "entries"),
        os.path.join(bench_dir, "sources"),
        os.path.join(bench_dir, "recordings"),
        os.path.join(bench_dir, "tools"),
    ]
    for fpath in required_files:
        if not os.path.isfile(fpath):
            errors.append("Missing required file: %s" % os.path.relpath(fpath, bench_dir))
        elif os.path.getsize(fpath) == 0:
            errors.append("Empty required file: %s" % os.path.relpath(fpath, bench_dir))
    for dpath in required_dirs:
        if not os.path.isdir(dpath):
            errors.append(
                "Missing required directory: %s" % os.path.relpath(dpath, bench_dir)
            )

    # 2. Parse gold.jsonl
    gold_by_group: Dict[str, List[Dict[str, Any]]] = {g: [] for g, _ in GROUP_SPECS}
    seen_gold_keys: Set[str] = set()
    gold_path = os.path.join(bench_dir, "gold.jsonl")

    if os.path.isfile(gold_path):
        with open(gold_path, encoding="utf-8") as gf:
            for lineno, raw_line in enumerate(gf, 1):
                stripped = raw_line.strip()
                if not stripped:
                    continue
                try:
                    row = json.loads(stripped)
                except Exception as err:
                    errors.append("gold.jsonl:%d: invalid JSON (%s)" % (lineno, err))
                    continue
                if not isinstance(row, dict):
                    errors.append("gold.jsonl:%d: row is not a JSON object" % lineno)
                    continue

                for req in REQUIRED_GOLD_FIELDS:
                    if req not in row:
                        errors.append(
                            "gold.jsonl:%d: missing required field '%s'" % (lineno, req)
                        )
                unknown_fields = (
                    set(row.keys())
                    - set(REQUIRED_GOLD_FIELDS)
                    - set(ALLOWED_EXTRA_GOLD_FIELDS)
                )
                if unknown_fields:
                    errors.append(
                        "gold.jsonl:%d: unexpected field(s) %s"
                        % (lineno, sorted(unknown_fields))
                    )

                key = row.get("key")
                grp = row.get("group")
                truth = row.get("truth")
                expected = row.get("expected")
                insertable = row.get("insertable")
                prov = row.get("provenance")
                note = row.get("note")

                if not isinstance(key, str) or not key:
                    errors.append("gold.jsonl:%d: invalid 'key'" % lineno)
                    continue
                if key in seen_gold_keys:
                    errors.append("gold.jsonl:%d: duplicate key '%s'" % (lineno, key))
                seen_gold_keys.add(key)

                if grp not in GROUP_COUNTS:
                    errors.append(
                        "gold.jsonl:%d (%s): unknown group %r" % (lineno, key, grp)
                    )
                else:
                    gold_by_group[grp].append(row)

                if truth not in VALID_TRUTHS:
                    errors.append(
                        "gold.jsonl:%d (%s): invalid truth %r" % (lineno, key, truth)
                    )

                if (
                    not isinstance(expected, list)
                    or not expected
                    or not all(isinstance(v, str) for v in expected)
                ):
                    errors.append(
                        "gold.jsonl:%d (%s): 'expected' must be a non-empty list of strings"
                        % (lineno, key)
                    )
                else:
                    bad_verdicts = [v for v in expected if v not in VALID_VERDICTS]
                    if bad_verdicts:
                        errors.append(
                            "gold.jsonl:%d (%s): invalid verdict(s) in expected: %s"
                            % (lineno, key, bad_verdicts)
                        )

                if not isinstance(insertable, bool):
                    errors.append(
                        "gold.jsonl:%d (%s): 'insertable' must be a boolean"
                        % (lineno, key)
                    )
                if not isinstance(prov, dict) or not prov:
                    errors.append(
                        "gold.jsonl:%d (%s): 'provenance' must be a non-empty object"
                        % (lineno, key)
                    )
                if not isinstance(note, str):
                    errors.append(
                        "gold.jsonl:%d (%s): 'note' must be a string" % (lineno, key)
                    )

    # 3. Check unexpected .bib files in entries/
    entries_dir = os.path.join(bench_dir, "entries")
    if os.path.isdir(entries_dir):
        for fname in sorted(os.listdir(entries_dir)):
            if fname.startswith("."):
                continue
            if not fname.endswith(".bib"):
                errors.append("Unexpected non-.bib file in entries/: %s" % fname)
                continue
            stem = fname[:-4]
            if stem not in GROUP_COUNTS:
                errors.append("Unexpected group .bib file in entries/: %s" % fname)

    # 4. Per-group BibTeX parsing, key prefix check, and 1-to-1 gold correspondence
    group_rows_report: List[Dict[str, Any]] = []
    seen_bib_keys: Set[str] = set()

    for group, expected_count in GROUP_SPECS:
        bib_path = os.path.join(entries_dir, "%s.bib" % group)
        gold_rows = gold_by_group.get(group, [])
        gold_keys = [r["key"] for r in gold_rows]
        bib_keys: List[str] = []
        bib_exists = os.path.isfile(bib_path)

        if bib_exists:
            try:
                with open(bib_path, "rb") as bf:
                    raw_text = bf.read().decode("utf-8")
                parsed = parse_bibtex_entries(raw_text)
                bib_keys = [e.key for e in parsed]
                for e in parsed:
                    if not e.fields:
                        errors.append(
                            "entries/%s.bib (%s): entry has 0 fields" % (group, e.key)
                        )
                    if e.key in seen_bib_keys:
                        errors.append(
                            "entries/%s.bib: duplicate key '%s' across .bib files"
                            % (group, e.key)
                        )
                    seen_bib_keys.add(e.key)
            except (UnicodeDecodeError, BibTeXSyntaxError) as err:
                errors.append("entries/%s.bib: parse error: %s" % (group, err))

        want_keys = expected_keys_for_group(group, expected_count)

        if not bib_exists and len(gold_keys) == 0:
            status = "MISSING"
            missing_or_incomplete_groups.append(group)
        else:
            if not bib_exists:
                errors.append(
                    "Group '%s' has %d gold.jsonl rows but entries/%s.bib is missing"
                    % (group, len(gold_keys), group)
                )
            if len(bib_keys) != expected_count or len(gold_keys) != expected_count:
                status = "INCOMPLETE"
                missing_or_incomplete_groups.append(group)
            else:
                status = "OK"

            if bib_exists and set(bib_keys) != set(gold_keys):
                only_bib = sorted(set(bib_keys) - set(gold_keys))[:5]
                only_gold = sorted(set(gold_keys) - set(bib_keys))[:5]
                errors.append(
                    "Group '%s' entries/%s.bib (%d) and gold.jsonl (%d) do not match 1-to-1 "
                    "(only in bib: %s; only in gold: %s)"
                    % (group, group, len(bib_keys), len(gold_keys), only_bib, only_gold)
                )

            if bib_exists and len(bib_keys) == expected_count and bib_keys != want_keys:
                bad = [
                    (got, exp)
                    for got, exp in zip(bib_keys, want_keys)
                    if got != exp
                ][:5]
                errors.append(
                    "Group '%s' keys in entries/%s.bib do not match expected prefix/sequence: %s"
                    % (group, group, bad)
                )

            if len(gold_keys) == expected_count and set(gold_keys) != set(want_keys):
                bad_gold = sorted(set(gold_keys) - set(want_keys))[:5]
                errors.append(
                    "Group '%s' keys in gold.jsonl do not match expected prefix/sequence: %s"
                    % (group, bad_gold)
                )

        group_rows_report.append({
            "group": group,
            "expected": expected_count,
            "entries_actual": len(bib_keys),
            "gold_actual": len(gold_keys),
            "status": status,
        })

    # 5. fabricated_model evidence & review checks
    fab_gold_rows = gold_by_group.get("fabricated_model", [])
    if fab_gold_rows:
        fab_src_dir = os.path.join(bench_dir, "sources", "fabricated_model")
        ev_dir = os.path.join(fab_src_dir, "evidence")
        rev_tsv = os.path.join(fab_src_dir, "review.tsv")

        review_by_key: Dict[str, Dict[str, str]] = {}
        if not os.path.isfile(rev_tsv):
            errors.append("Missing sources/fabricated_model/review.tsv")
        else:
            with open(rev_tsv, encoding="utf-8") as rf:
                for row in csv.DictReader(rf, delimiter="\t"):
                    rk = (row.get("key") or "").strip()
                    if rk:
                        review_by_key[rk] = row

        for grow in fab_gold_rows:
            fkey = grow["key"]
            ev_path = os.path.join(ev_dir, "%s.json" % fkey)
            if not os.path.isfile(ev_path):
                errors.append(
                    "fabricated_model (%s): missing evidence file sources/fabricated_model/evidence/%s.json"
                    % (fkey, fkey)
                )
            else:
                try:
                    with open(ev_path, encoding="utf-8") as ef:
                        ev_obj = json.load(ef)
                    if not isinstance(ev_obj, dict) or ev_obj.get("key") != fkey:
                        errors.append(
                            "fabricated_model (%s): malformed evidence JSON" % fkey
                        )
                except Exception as err:
                    errors.append(
                        "fabricated_model (%s): unreadable evidence JSON (%s)"
                        % (fkey, err)
                    )

            rev_row = review_by_key.get(fkey)
            if not rev_row:
                errors.append(
                    "fabricated_model (%s): missing row in sources/fabricated_model/review.tsv"
                    % fkey
                )
            elif not (rev_row.get("verdict") or "").strip() or not (
                rev_row.get("reviewer") or ""
            ).strip():
                errors.append(
                    "fabricated_model (%s): empty verdict or reviewer in review.tsv"
                    % fkey
                )

    ok = (len(missing_or_incomplete_groups) == 0) and (len(errors) == 0)
    return ok, {
        "groups": group_rows_report,
        "missing_or_incomplete_groups": missing_or_incomplete_groups,
        "errors": errors,
        "expected_total": TOTAL_BENCHMARK_COUNT,
        "entries_total": sum(r["entries_actual"] for r in group_rows_report),
        "gold_total": sum(r["gold_actual"] for r in group_rows_report),
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check Benchmarks/citations structure, counts, keys, and gold.jsonl parity."
    )
    parser.add_argument(
        "--bench-dir",
        default=default_bench_dir(),
        help="Path to Benchmarks/citations directory (default: %(default)s)",
    )
    args = parser.parse_args(argv)

    ok, report = check_benchmark(args.bench_dir)

    print("%-18s %8s %14s %12s  %s" % ("group", "expected", "entries_actual", "gold_actual", "status"))
    print("-" * 66)
    for row in report["groups"]:
        print(
            "%-18s %8d %14d %12d  %s"
            % (
                row["group"],
                row["expected"],
                row["entries_actual"],
                row["gold_actual"],
                row["status"],
            )
        )
    print("-" * 66)
    print(
        "%-18s %8d %14d %12d  %s"
        % (
            "TOTAL",
            report["expected_total"],
            report["entries_total"],
            report["gold_total"],
            "COMPLETE" if ok else "INCOMPLETE",
        )
    )

    if report["missing_or_incomplete_groups"]:
        print(
            "\nMissing or incomplete groups (%d): %s"
            % (
                len(report["missing_or_incomplete_groups"]),
                ", ".join(report["missing_or_incomplete_groups"]),
            )
        )

    if report["errors"]:
        print("\nValidation errors (%d):" % len(report["errors"]))
        for err in report["errors"]:
            print("  - %s" % err)

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
