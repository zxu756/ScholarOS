#!/usr/bin/env python3
"""M1 Citation Verification Benchmark Runner (Scripts/acceptance/m1-citation-bench.py).

Implements M1 item 11 of 04-scholaros.md using Python 3 standard library only
(compatible with `python3 -I`).

Modes:
  --replay (default)   Offline replay against Benchmarks/citations/recordings.
                       Uses isolated temporary HOME and strips SCHOLAR_CACHE_DIR.
  --live               Online verification against public registries.
                       Requires SCHOLAR_ONLINE=1; otherwise prints '没跑' and exits 2.
  --live --record      Online re-recording into Benchmarks/citations/recordings and
                       writes report JSON into reports/.

Options:
  --subset <N>         Deterministic fixed-seed stratified sample across target groups.
  --groups <a,b>       Comma-separated subset of canonical benchmark groups.
  --record             Write report JSON to reports/citation-bench-<YYYY-MM-DD>-<mode>.json
                       instead of a temporary directory (full 480-entry runs only).
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
BENCH_TOOLS_DIR = os.path.join(REPO_ROOT, "Benchmarks", "citations", "tools")

if BENCH_TOOLS_DIR not in sys.path:
    sys.path.insert(0, BENCH_TOOLS_DIR)

from _common import (  # noqa: E402
    BibTeXSyntaxError,
    GROUP_COUNTS,
    GROUP_ORDER,
    GROUP_SPECS,
    ParsedBibEntry,
    REQUIRED_GOLD_FIELDS,
    TOTAL_BENCHMARK_COUNT,
    VALID_TRUTHS,
    VALID_VERDICTS,
    expected_keys_for_group,
    parse_bibtex_entries,
)
from check_benchmark import check_benchmark  # noqa: E402

VERDICT_COLUMNS: Tuple[str, ...] = (
    "VERIFIED",
    "DRIFT",
    "NOT_FOUND",
    "RETRACTED",
    "UNVERIFIED",
)
TRUTH_ROWS: Tuple[str, ...] = (
    "real",
    "fabricated",
    "mutated",
    "retracted",
    "TOTAL",
)
TRANSIENT_UNVERIFIED_REASONS = frozenset({
    "offline",
    "transport_error",
    "timeout",
    "rate_limited",
    "server_error",
    "budget_exhausted",
    "unparseable",
})
REAL_THREE_GROUPS: Tuple[str, ...] = ("real_clean", "real_human", "real_typo")
YEAR_ONLINE_VS_PRINT_SUBSTRING = "online-first vs. print"
HTTP_LINE_RE = re.compile(
    r"^\[HTTP\]\s+source=(?P<source>\S+)\s+url=(?P<url>\S+)\s+status=(?P<status>\S+)"
    r"\s+elapsed=(?P<elapsed>\S+)\s+origin=(?P<origin>\S+)"
    r"(?:\s+start=(?P<start>[0-9.]+)\s+end=(?P<end>[0-9.]+))?"
    r"(?P<rest>.*)$"
)
UNRECORDED_URL_RE = re.compile(r"unrecorded request URL:\s*(\S+)")


def _sha256_file(path: str) -> Optional[str]:
    if not os.path.isfile(path):
        return None
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def _git_info(repo_root: str) -> Dict[str, Any]:
    commit_short = "unknown"
    commit_full = "unknown"
    dirty = False
    try:
        p_short = subprocess.run(
            ["git", "-C", repo_root, "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if p_short.returncode == 0 and p_short.stdout.strip():
            commit_short = p_short.stdout.strip()
        p_full = subprocess.run(
            ["git", "-C", repo_root, "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if p_full.returncode == 0 and p_full.stdout.strip():
            commit_full = p_full.stdout.strip()
        p_status = subprocess.run(
            ["git", "-C", repo_root, "status", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if p_status.returncode == 0:
            dirty = bool(p_status.stdout.strip())
    except Exception:
        pass
    return {
        "commit": commit_short,
        "commit_full": commit_full,
        "dirty": dirty,
    }


def _resolve_cli_bin(repo_root: str) -> Tuple[Optional[str], Optional[str]]:
    env_bin = os.environ.get("SCHOLAR_CLI_BIN", "").strip()
    if env_bin:
        if not (os.path.isfile(env_bin) and os.access(env_bin, os.X_OK)):
            return None, f"SCHOLAR_CLI_BIN is not an executable file: {env_bin}"
        return os.path.abspath(env_bin), None

    default_bin = os.path.join(repo_root, ".build", "debug", "ScholarOS")
    if os.path.isfile(default_bin) and os.access(default_bin, os.X_OK):
        return default_bin, None

    build_cmd = ["swift", "build"]
    if os.environ.get("SCHOLAR_OUTER_NO_NETWORK") == "1":
        build_cmd.append("--disable-sandbox")
    jobs = os.environ.get("SCHOLAR_BUILD_JOBS", "").strip()
    if jobs:
        build_cmd.extend(["-j", jobs])

    proc = subprocess.run(build_cmd, cwd=repo_root, capture_output=True, text=True)
    if proc.returncode != 0:
        return None, f"swift build failed (exit {proc.returncode}): {proc.stderr.strip()}"
    if not (os.path.isfile(default_bin) and os.access(default_bin, os.X_OK)):
        return None, f"Built executable missing after swift build: {default_bin}"
    return default_bin, None


def _entry_has_identifier(entry: ParsedBibEntry) -> bool:
    fields_lc = {k.lower(): v.strip() for k, v in entry.fields.items()}
    for id_key in ("doi", "pmid"):
        if fields_lc.get(id_key):
            return True
    eprint = fields_lc.get("eprint", "")
    archive_prefix = (
        fields_lc.get("archiveprefix", "") or fields_lc.get("eprinttype", "")
    ).lower()
    if eprint and (
        archive_prefix == "arxiv"
        or re.match(r"^(?:arxiv:)?(?:\d{4}\.\d{4,5}|[a-z-]+(?:\.[a-z-]+)?/\d{7})(?:v\d+)?$", eprint, re.I)
    ):
        return True
    url_val = fields_lc.get("url", "")
    if "doi.org/" in url_val.lower() or "arxiv.org/abs/" in url_val.lower() or "arxiv.org/pdf/" in url_val.lower():
        return True
    return False


def _extract_raw_bib_blocks(raw_bytes: bytes) -> Dict[str, bytes]:
    """Extract raw byte slices per BibTeX entry key so CRLF bytes stay untouched."""
    text = raw_bytes.decode("utf-8")
    parsed = parse_bibtex_entries(text)
    if not parsed:
        return {}
    # Locate `@type{key,` byte offsets in raw_bytes in order
    blocks: Dict[str, bytes] = {}
    search_pos = 0
    for idx, entry in enumerate(parsed):
        pattern = re.compile(
            r"@[A-Za-z]+\s*[\{\(]\s*" + re.escape(entry.key) + r"\s*,",
            re.MULTILINE,
        )
        m = pattern.search(text, search_pos)
        if not m:
            # Fallback to normalized serialization only if regex couldn't locate header
            blocks[entry.key] = text.encode("utf-8")
            continue
        start_char = m.start()
        # Scan balanced braces/parens from opening delimiter
        open_delim_pos = m.end() - 1
        while open_delim_pos > start_char and text[open_delim_pos] not in "{(":
            open_delim_pos -= 1
        close_delim = "}" if text[open_delim_pos] == "{" else ")"
        depth = 0
        pos = open_delim_pos
        in_quotes = False
        while pos < len(text):
            ch = text[pos]
            if ch == "\\" and pos + 1 < len(text):
                pos += 2
                continue
            if ch == '"' and depth == 1:
                in_quotes = not in_quotes
            elif not in_quotes:
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0 and close_delim == "}":
                        pos += 1
                        break
                elif close_delim == ")" and depth == 1 and ch == ")":
                    pos += 1
                    break
            pos += 1
        # Include trailing CR/LF
        while pos < len(text) and text[pos] in "\r\n":
            pos += 1
        slice_bytes = text[start_char:pos].encode("utf-8")
        blocks[entry.key] = slice_bytes
        search_pos = pos
    return blocks


def _allocate_subset_counts(
    target_groups: Sequence[str],
    group_sizes: Dict[str, int],
    subset_n: int,
) -> Dict[str, int]:
    total_avail = sum(group_sizes[g] for g in target_groups)
    if subset_n >= total_avail:
        return {g: group_sizes[g] for g in target_groups}

    num_groups = len(target_groups)
    if subset_n < num_groups:
        # Fewer than 1 per group requested: interpret as per-group cap min(N, size)
        return {g: min(subset_n, group_sizes[g]) for g in target_groups}

    # Stratified proportional allocation with minimum 1 per group summing to subset_n
    alloc = {g: 1 for g in target_groups}
    remaining = subset_n - num_groups
    capacities = {g: group_sizes[g] - 1 for g in target_groups}
    total_cap = sum(capacities.values())
    if remaining > 0 and total_cap > 0:
        exact_shares = {
            g: (remaining * capacities[g]) / float(total_cap) for g in target_groups
        }
        floors = {
            g: min(capacities[g], int(exact_shares[g])) for g in target_groups
        }
        for g in target_groups:
            alloc[g] += floors[g]
        leftover = subset_n - sum(alloc.values())
        ranked = sorted(
            target_groups,
            key=lambda g: (-(exact_shares[g] - floors[g]), GROUP_ORDER.index(g)),
        )
        for g in ranked:
            if leftover <= 0:
                break
            if alloc[g] < group_sizes[g]:
                alloc[g] += 1
                leftover -= 1
    return alloc


def _empty_confusion_matrix() -> Dict[str, Dict[str, int]]:
    return {t: {v: 0 for v in VERDICT_COLUMNS} for t in TRUTH_ROWS}


def _rate_obj(numerator: int, denominator: int) -> Dict[str, Any]:
    return {
        "numerator": numerator,
        "denominator": denominator,
        "rate": (numerator / float(denominator)) if denominator > 0 else None,
    }


def _is_verified_with_venue_hint(rec: Dict[str, Any]) -> bool:
    if rec.get("verdict") != "VERIFIED":
        return False
    return any(
        f.get("field") == "venue" and f.get("severity", "advisory") != "error"
        for f in (rec.get("fields") or [])
    )


def _collect_real_three_non_verified_entries(
    records_by_group: Dict[str, List[Dict[str, Any]]],
) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for g in REAL_THREE_GROUPS:
        for r in records_by_group.get(g, []):
            if r.get("truth") == "real" and r.get("verdict") != "VERIFIED":
                out.append(
                    {
                        "key": r["key"],
                        "group": r["group"],
                        "verdict": r["verdict"],
                        "reasons": list(r["reasons"]),
                    }
                )
    return out


def _compute_metrics_bundle(records: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    cm = _empty_confusion_matrix()
    verdict_counts = {v: 0 for v in VERDICT_COLUMNS}
    unverified_by_reason: Dict[str, int] = {}

    allow_total = 0
    allow_insertable_true = 0
    verified_with_venue_hint_count = 0
    insertable_true_total = 0
    insertable_false_total = 0

    block_total = 0
    block_truth_non_real = 0
    truth_non_real_total = 0
    block_non_insertable = 0

    in_expected_count = 0

    for rec in records:
        truth = rec["truth"]
        verdict = rec["verdict"]
        insertable = bool(rec["insertable"])
        reasons = rec["reasons"]
        expected = rec["expected"]

        verdict_counts[verdict] = verdict_counts.get(verdict, 0) + 1
        if truth in cm:
            cm[truth][verdict] = cm[truth].get(verdict, 0) + 1
        cm["TOTAL"][verdict] = cm["TOTAL"].get(verdict, 0) + 1

        if verdict in expected:
            in_expected_count += 1

        if insertable:
            insertable_true_total += 1
        else:
            insertable_false_total += 1

        if truth != "real":
            truth_non_real_total += 1

        if verdict == "VERIFIED":
            allow_total += 1
            if insertable:
                allow_insertable_true += 1
            if _is_verified_with_venue_hint(rec):
                verified_with_venue_hint_count += 1
        elif verdict in ("DRIFT", "NOT_FOUND", "RETRACTED"):
            block_total += 1
            if truth != "real":
                block_truth_non_real += 1
            if not insertable:
                block_non_insertable += 1
        elif verdict == "UNVERIFIED":
            if reasons:
                for r in reasons:
                    unverified_by_reason[r] = unverified_by_reason.get(r, 0) + 1
            else:
                unverified_by_reason["unspecified"] = (
                    unverified_by_reason.get("unspecified", 0) + 1
                )

    total = len(records)
    unverified_count = verdict_counts["UNVERIFIED"]
    return {
        "total_entries": total,
        "verdict_counts": verdict_counts,
        "verified_with_venue_hint_count": verified_with_venue_hint_count,
        "confusion_matrix": cm,
        "allow_precision": _rate_obj(allow_insertable_true, allow_total),
        "allow_recall": _rate_obj(allow_insertable_true, insertable_true_total),
        "block_precision": _rate_obj(block_truth_non_real, block_total),
        "block_recall": _rate_obj(block_truth_non_real, truth_non_real_total),
        "block_by_non_insertable": {
            "precision": _rate_obj(block_non_insertable, block_total),
            "recall": _rate_obj(block_non_insertable, insertable_false_total),
        },
        "unverified": {
            "count": unverified_count,
            "rate": (unverified_count / float(total)) if total > 0 else None,
            "by_reason": dict(sorted(unverified_by_reason.items())),
        },
        "in_expected": _rate_obj(in_expected_count, total),
    }


def _parse_telemetry(stderr_blobs: Sequence[str]) -> Dict[str, Any]:
    network_requests = 0
    replay_lookups = 0
    cache_hits = 0
    openalex_credits = 0
    crossref_intervals: List[Tuple[float, float]] = []

    for blob in stderr_blobs:
        for raw_line in blob.splitlines():
            line = raw_line.strip()
            m = HTTP_LINE_RE.match(line)
            if not m:
                continue
            source = m.group("source")
            url = m.group("url")
            origin = m.group("origin")
            start_s = m.group("start")
            end_s = m.group("end")
            rest = m.group("rest") or ""

            if origin == "network":
                network_requests += 1
                if source.lower() == "openalex" or "api.openalex.org" in url.lower():
                    cm = re.search(r"\bcredits=(\d+)", rest)
                    if cm:
                        openalex_credits += int(cm.group(1))
                    elif "search=" in url:
                        openalex_credits += 10
                if (
                    source.lower() == "crossref" or "api.crossref.org" in url.lower()
                ) and start_s and end_s:
                    try:
                        t0 = float(start_s)
                        t1 = float(end_s)
                        if t1 >= t0:
                            crossref_intervals.append((t0, t1))
                    except ValueError:
                        pass
            elif origin == "replay":
                replay_lookups += 1
            elif origin == "cache":
                cache_hits += 1

    # Compute maximum concurrent in-flight Crossref requests via sweep-line
    events: List[Tuple[float, int]] = []
    for t0, t1 in crossref_intervals:
        events.append((t0, 1))
        # End event processed before start event at identical timestamp (serial back-to-back)
        events.append((t1, -1))
    events.sort(key=lambda item: (item[0], item[1]))
    cur = 0
    max_in_flight = 0
    for _, delta in events:
        cur += delta
        if cur > max_in_flight:
            max_in_flight = cur

    return {
        "http_request_count": network_requests,
        "replay_lookup_count": replay_lookups,
        "cache_hit_count": cache_hits,
        "openalex_credits_used": openalex_credits,
        "crossref_max_in_flight": max_in_flight,
    }


def _normalize_doi_compare(raw_doi: str) -> str:
    s = raw_doi.strip().lower()
    for prefix in ("https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:"):
        if s.startswith(prefix):
            s = s[len(prefix):].strip()
    return s


def _load_gold_and_entries(
    bench_dir: str,
    target_groups: Sequence[str],
    is_full_groups: bool,
) -> Tuple[bool, List[str], Dict[str, List[Dict[str, Any]]], Dict[str, List[ParsedBibEntry]], Dict[str, Dict[str, bytes]]]:
    errors: List[str] = []
    gold_by_group: Dict[str, List[Dict[str, Any]]] = {g: [] for g in GROUP_ORDER}
    entries_by_group: Dict[str, List[ParsedBibEntry]] = {}
    raw_blocks_by_group: Dict[str, Dict[str, bytes]] = {}

    if is_full_groups and os.path.isdir(os.path.join(bench_dir, "sources", "fabricated_model")):
        ok_struct, struct_rep = check_benchmark(bench_dir)
        if not ok_struct:
            if struct_rep["missing_or_incomplete_groups"]:
                errors.append(
                    "Missing or incomplete benchmark groups: "
                    + ", ".join(struct_rep["missing_or_incomplete_groups"])
                )
            errors.extend(struct_rep["errors"])

    gold_path = os.path.join(bench_dir, "gold.jsonl")
    seen_keys: Set[str] = set()
    if not os.path.isfile(gold_path):
        errors.append("Missing gold.jsonl")
    else:
        with open(gold_path, encoding="utf-8") as gf:
            for lineno, line in enumerate(gf, 1):
                stripped = line.strip()
                if not stripped:
                    continue
                try:
                    obj = json.loads(stripped)
                except Exception as exc:
                    errors.append(f"gold.jsonl:{lineno}: invalid JSON ({exc})")
                    continue
                if not isinstance(obj, dict):
                    errors.append(f"gold.jsonl:{lineno}: row is not an object")
                    continue
                missing_req = [f for f in REQUIRED_GOLD_FIELDS if f not in obj]
                if missing_req:
                    errors.append(f"gold.jsonl:{lineno}: missing fields {missing_req}")
                    continue
                key = obj["key"]
                grp = obj["group"]
                if key in seen_keys:
                    errors.append(f"gold.jsonl:{lineno}: duplicate key {key}")
                seen_keys.add(key)
                if grp not in GROUP_COUNTS:
                    errors.append(f"gold.jsonl:{lineno}: unknown group {grp!r}")
                    continue
                if obj["truth"] not in VALID_TRUTHS:
                    errors.append(f"gold.jsonl:{lineno}: invalid truth {obj['truth']!r}")
                if not isinstance(obj["expected"], list) or not obj["expected"] or any(
                    v not in VALID_VERDICTS for v in obj["expected"]
                ):
                    errors.append(f"gold.jsonl:{lineno}: invalid expected {obj['expected']!r}")
                gold_by_group[grp].append(obj)

    groups_to_verify = GROUP_ORDER if is_full_groups else tuple(target_groups)
    entries_dir = os.path.join(bench_dir, "entries")
    for grp in groups_to_verify:
        expected_n = GROUP_COUNTS[grp]
        bib_path = os.path.join(entries_dir, f"{grp}.bib")
        g_rows = gold_by_group.get(grp, [])
        if not os.path.isfile(bib_path):
            errors.append(f"Missing entries/{grp}.bib (expected {expected_n} entries)")
            continue
        try:
            with open(bib_path, "rb") as bf:
                raw_bytes = bf.read()
            parsed = parse_bibtex_entries(raw_bytes.decode("utf-8"))
            entries_by_group[grp] = parsed
            raw_blocks_by_group[grp] = _extract_raw_bib_blocks(raw_bytes)
        except (UnicodeDecodeError, BibTeXSyntaxError) as exc:
            errors.append(f"entries/{grp}.bib parse error: {exc}")
            continue

        bib_keys = [e.key for e in parsed]
        gold_keys = [r["key"] for r in g_rows]
        if len(bib_keys) != expected_n or len(gold_keys) != expected_n:
            errors.append(
                f"Group '{grp}' count mismatch: expected={expected_n}, entries={len(bib_keys)}, gold={len(gold_keys)}"
            )
        if set(bib_keys) != set(gold_keys):
            errors.append(
                f"Group '{grp}' key mismatch between entries/{grp}.bib and gold.jsonl"
            )
        want_keys = expected_keys_for_group(grp, expected_n)
        if len(bib_keys) == expected_n and bib_keys != want_keys:
            errors.append(f"Group '{grp}' keys do not match canonical sequence")

    return (len(errors) == 0), errors, gold_by_group, entries_by_group, raw_blocks_by_group


def _select_report_path(
    repo_root: str,
    mode: str,
    date_str: str,
    record: bool,
    explicit_output: Optional[str],
) -> str:
    if explicit_output:
        parent = os.path.dirname(os.path.abspath(explicit_output))
        if parent:
            os.makedirs(parent, exist_ok=True)
        return os.path.abspath(explicit_output)

    filename = f"citation-bench-{date_str}-{mode}.json"
    env_report_dir = os.environ.get("SCHOLAR_REPORT_DIR", "").strip()
    if record:
        report_dir = os.path.join(repo_root, "reports")
    elif env_report_dir:
        report_dir = env_report_dir
    else:
        report_dir = tempfile.mkdtemp(prefix="scholaros-bench-report.")
    os.makedirs(report_dir, exist_ok=True)
    return os.path.join(report_dir, filename)


def _evaluate_gates(
    all_records: Sequence[Dict[str, Any]],
    records_by_group: Dict[str, List[Dict[str, Any]]],
    is_full_benchmark: bool,
    complete: bool,
) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]], Dict[str, Any]]:
    # Hard requirements (Row 3, Row 5, Row 10)
    non_insertable_verified = [
        {
            "key": r["key"],
            "group": r["group"],
            "truth": r["truth"],
            "verdict": r["verdict"],
            "reasons": r["reasons"],
        }
        for r in all_records
        if (not r["insertable"]) and r["verdict"] == "VERIFIED"
    ]

    mut_missing_recs = records_by_group.get("mut_doi_missing", [])
    mut_missing_verified = [r["key"] for r in mut_missing_recs if r["verdict"] == "VERIFIED"]
    mut_missing_bad_drift: List[Dict[str, Any]] = []
    mut_missing_not_found = 0
    for r in mut_missing_recs:
        if r["verdict"] == "NOT_FOUND":
            mut_missing_not_found += 1
        elif r["verdict"] == "DRIFT":
            true_doi = _normalize_doi_compare(str(r["provenance"].get("true_doi", "")))
            doi_fields = [
                f for f in r["fields"] if f.get("field") == "doi"
            ]
            matched = any(
                _normalize_doi_compare(str(f.get("remoteValue", ""))) == true_doi and bool(true_doi)
                for f in doi_fields
            )
            if not matched:
                mut_missing_bad_drift.append(
                    {
                        "key": r["key"],
                        "expected_true_doi": true_doi,
                        "fields": doi_fields,
                    }
                )

    hard_passed = (
        len(non_insertable_verified) == 0
        and len(mut_missing_verified) == 0
        and len(mut_missing_bad_drift) == 0
    )
    if is_full_benchmark and not complete:
        hard_passed = False

    hard_requirements: Dict[str, Any] = {
        "row3_complete": complete if is_full_benchmark else None,
        "non_insertable_verified_count": len(non_insertable_verified),
        "non_insertable_verified_entries": non_insertable_verified,
        "row10_mut_doi_missing": {
            "evaluated_count": len(mut_missing_recs),
            "verified_count": len(mut_missing_verified),
            "drift_true_doi_matched_all": len(mut_missing_bad_drift) == 0,
            "bad_drift_entries": mut_missing_bad_drift,
            "not_found_rate": _rate_obj(mut_missing_not_found, len(mut_missing_recs)),
        }
        if mut_missing_recs
        else None,
        "passed": hard_passed,
    }

    # Hypothesis / diagnostic measurements (recorded_only)
    rc_recs = records_by_group.get("real_clean", [])
    rc_online_vs_print_diff = 0
    for r in rc_recs:
        prov = r["provenance"]
        p_print = str(prov.get("published-print") or "")[:4]
        p_online = str(prov.get("published-online") or "")[:4]
        if len(p_print) == 4 and len(p_online) == 4 and p_print.isdigit() and p_online.isdigit():
            if p_print != p_online:
                rc_online_vs_print_diff += 1

    ret_recs = records_by_group.get("retracted", [])
    ret_coverage = {
        "crossref_updated_by": 0,
        "crossref_update_to": 0,
        "crossref_relation": 0,
        "openalex_is_retracted": 0,
    }
    for r in ret_recs:
        details = " ".join(str(f.get("detail", "")) + " " + str(f.get("field", "")) for f in r["findings"])
        note_blob = details + " " + str(r.get("audit_note", ""))
        if "updated-by" in note_blob:
            ret_coverage["crossref_updated_by"] += 1
        if "update-to" in note_blob:
            ret_coverage["crossref_update_to"] += 1
        if "is-retracted-by" in note_blob:
            ret_coverage["crossref_relation"] += 1
        if "is_retracted" in note_blob:
            ret_coverage["openalex_is_retracted"] += 1

    rh_recs = records_by_group.get("real_human", [])
    rh_venue_only_drift = [
        r["key"]
        for r in rh_recs
        if r["verdict"] == "DRIFT"
        and r["fields"]
        and all(f.get("field") == "venue" for f in r["fields"])
    ]
    hypothesis_measurements = {
        "real_clean_online_vs_print_year_diff": _rate_obj(rc_online_vs_print_diff, len(rc_recs)),
        "retracted_source_field_hits": ret_coverage,
        "real_human_venue_only_drift": {
            "count": len(rh_venue_only_drift),
            "keys": rh_venue_only_drift,
        },
    }

    if not (is_full_benchmark and complete):
        return hard_requirements, None, hypothesis_measurements

    # Provisional thresholds (Rows 6, 7, 8, 12) for complete full-benchmark runs
    real3_recs: List[Dict[str, Any]] = []
    for g in REAL_THREE_GROUPS:
        real3_recs.extend(records_by_group.get(g, []))

    row6_false_nf_ret = [
        {
            "key": r["key"],
            "group": r["group"],
            "verdict": r["verdict"],
            "reasons": r["reasons"],
        }
        for r in real3_recs
        if r["verdict"] in ("NOT_FOUND", "RETRACTED")
    ]
    row6_rate_obj = _rate_obj(len(row6_false_nf_ret), len(real3_recs))
    row6_pass = (row6_rate_obj["rate"] is not None) and (row6_rate_obj["rate"] <= 0.02)

    # Row 7: real three groups VERIFIED rate (truth=='real' entries across real_clean, real_human, real_typo; plus raw 220 count)
    real3_truth_real = [r for r in real3_recs if r["truth"] == "real"]
    real3_verified_ins = sum(1 for r in real3_truth_real if r["verdict"] == "VERIFIED")
    real3_verified_all = sum(1 for r in real3_recs if r["verdict"] == "VERIFIED")
    real3_non_verified = _collect_real_three_non_verified_entries(records_by_group)
    row7_combined_rate = _rate_obj(real3_verified_ins, len(real3_truth_real))
    row7_combined_all220_rate = _rate_obj(real3_verified_all, len(real3_recs))

    rc_verified = sum(1 for r in rc_recs if r["verdict"] == "VERIFIED")
    rc_non_verified = [
        {"key": r["key"], "verdict": r["verdict"], "reasons": r["reasons"]}
        for r in rc_recs
        if r["verdict"] != "VERIFIED"
    ]
    row7_clean_rate = _rate_obj(rc_verified, len(rc_recs))
    row7_pass = (
        row7_combined_rate["rate"] is not None
        and row7_combined_rate["rate"] >= 0.85
        and row7_clean_rate["rate"] is not None
        and row7_clean_rate["rate"] >= 0.95
    )

    # Row 8: mutation groups detection rates
    mut_thresholds = (
        ("mut_doi_swap", 0.95),
        ("mut_author", 0.90),
        ("mut_year3", 0.95),
        ("mut_title", 0.80),
        ("mut_year1", 0.90),
    )
    row8_groups: Dict[str, Any] = {}
    row8_pass = True
    for grp, min_rate in mut_thresholds:
        g_recs = records_by_group.get(grp, [])
        matched = sum(1 for r in g_recs if r["verdict"] in r["expected"])
        r_obj = _rate_obj(matched, len(g_recs))
        g_ok = r_obj["rate"] is not None and r_obj["rate"] >= min_rate
        extra: Dict[str, Any] = {}
        if grp == "mut_year1":
            missing_notice_keys: List[str] = []
            for r in g_recs:
                if r["verdict"] == "DRIFT":
                    has_notice = any(
                        YEAR_ONLINE_VS_PRINT_SUBSTRING in str(f.get("note") or "")
                        for f in r["fields"]
                        if f.get("field") == "year"
                    ) or (YEAR_ONLINE_VS_PRINT_SUBSTRING in str(r.get("audit_note") or ""))
                    if not has_notice:
                        missing_notice_keys.append(r["key"])
            notice_ok = len(missing_notice_keys) == 0
            extra["all_drift_have_online_vs_print_notice"] = notice_ok
            extra["missing_notice_keys"] = missing_notice_keys
            g_ok = g_ok and notice_ok
        row8_groups[grp] = {
            "threshold": min_rate,
            **r_obj,
            **extra,
            "passed": g_ok,
        }
        if not g_ok:
            row8_pass = False

    # Row 12: retracted group >= 90% and upstream source+field cited
    ret_matched = sum(1 for r in ret_recs if r["verdict"] == "RETRACTED")
    ret_rate_obj = _rate_obj(ret_matched, len(ret_recs))
    ret_missing_prov: List[str] = []
    for r in ret_recs:
        if r["verdict"] == "RETRACTED":
            has_upstream = (
                any(
                    rc in ("retracted_crossref", "retracted_openalex", "retracted_pubmed", "retracted_arxiv")
                    for rc in r["reasons"]
                )
                and "retracted_builtin_list" not in r["reasons"]
            )
            note_text = str(r.get("audit_note") or "") + " " + " ".join(
                str(f.get("detail") or "") + " " + str(f.get("field") or "")
                for f in r["findings"]
            )
            has_field = any(
                tok in note_text
                for tok in ("updated-by", "update-to", "is-retracted-by", "is_retracted", "pubtype", "withdrawn")
            )
            if not (has_upstream and has_field):
                ret_missing_prov.append(r["key"])
    row12_pass = (
        ret_rate_obj["rate"] is not None
        and ret_rate_obj["rate"] >= 0.90
        and len(ret_missing_prov) == 0
    )

    provisional_passed = row6_pass and row7_pass and row8_pass and row12_pass
    provisional_thresholds: Dict[str, Any] = {
        "row6_real_three_not_found_or_retracted": {
            "max_threshold": 0.02,
            **row6_rate_obj,
            "entries": row6_false_nf_ret,
            "passed": row6_pass,
        },
        "row7_real_verified_rates": {
            "real_three_insertable": {
                "min_threshold": 0.85,
                **row7_combined_rate,
            },
            "real_three_all_220": row7_combined_all220_rate,
            "real_clean": {
                "min_threshold": 0.95,
                **row7_clean_rate,
                "non_verified_entries": rc_non_verified,
            },
            "real_three_non_verified_entries": real3_non_verified,
            "passed": row7_pass,
        },
        "row8_mutation_detection": {
            "groups": row8_groups,
            "passed": row8_pass,
        },
        "row12_retracted": {
            "min_threshold": 0.90,
            **ret_rate_obj,
            "missing_source_or_field_keys": ret_missing_prov,
            "passed": row12_pass,
        },
        "passed": provisional_passed,
    }
    return hard_requirements, provisional_thresholds, hypothesis_measurements


def _run_cli_verify(
    cli_bin: str,
    bib_path: str,
    extra_args: Sequence[str],
    env: Dict[str, str],
    timeout_sec: int = 1800,
) -> subprocess.CompletedProcess[str]:
    cmd = [cli_bin, "verify-citations", bib_path, *extra_args, "--verbose", "--json", "--lang", "en"]
    return subprocess.run(
        cmd,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout_sec,
    )


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run the ScholarOS M1 480-entry citation verification benchmark."
    )
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--replay",
        action="store_true",
        help="Replay recorded registry responses from Benchmarks/citations/recordings (default).",
    )
    mode_group.add_argument(
        "--live",
        action="store_true",
        help="Query live public registries (requires SCHOLAR_ONLINE=1).",
    )
    parser.add_argument(
        "--record",
        action="store_true",
        help="Write report JSON to reports/ (and with --live, re-record Benchmarks/citations/recordings).",
    )
    parser.add_argument(
        "--record-limit",
        type=int,
        default=600,
        help="Per-group --registry-record-limit when running --live --record (default: %(default)s).",
    )
    parser.add_argument(
        "--subset",
        type=int,
        default=None,
        help="Stratified sample size drawn with fixed --seed across selected groups.",
    )
    parser.add_argument(
        "--groups",
        default=None,
        help="Comma-separated list of benchmark groups to run (e.g. audit_manual,real_clean).",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=20261116,
        help="Fixed PRNG seed for --subset sampling (default: %(default)s).",
    )
    parser.add_argument(
        "--bench-dir",
        default=os.path.join(REPO_ROOT, "Benchmarks", "citations"),
        help="Path to Benchmarks/citations directory.",
    )
    parser.add_argument(
        "--recordings-dir",
        default=None,
        help="Path to recordings directory (default: <bench-dir>/recordings).",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Explicit output path for the generated JSON report.",
    )

    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return int(exc.code) if isinstance(exc.code, int) else 2

    is_live = bool(args.live)
    mode_name = "live" if is_live else "replay"

    if is_live and os.environ.get("SCHOLAR_ONLINE") != "1":
        print("SKIPPED: 没跑 (--live requires SCHOLAR_ONLINE=1)")
        return 2

    if args.subset is not None and args.subset <= 0:
        print("ERROR: --subset requires a positive integer.", file=sys.stderr)
        return 2

    if args.record_limit <= 0:
        print("ERROR: --record-limit requires a positive integer.", file=sys.stderr)
        return 2

    if args.groups is not None:
        raw_groups = [g.strip() for g in args.groups.split(",") if g.strip()]
        if not raw_groups:
            print("ERROR: --groups requires at least one group name.", file=sys.stderr)
            return 2
        unknown = [g for g in raw_groups if g not in GROUP_COUNTS]
        if unknown:
            print(
                f"ERROR: Unknown benchmark group(s): {', '.join(unknown)}. "
                f"Valid groups: {', '.join(GROUP_ORDER)}",
                file=sys.stderr,
            )
            return 2
        # Deduplicate while preserving canonical order
        seen_g: Set[str] = set()
        target_groups: List[str] = []
        for g in raw_groups:
            if g not in seen_g:
                seen_g.add(g)
                target_groups.append(g)
        is_full_groups = len(target_groups) == len(GROUP_ORDER)
    else:
        target_groups = list(GROUP_ORDER)
        is_full_groups = True

    is_partial_selection = (not is_full_groups) or (args.subset is not None)
    if args.record and is_partial_selection:
        print(
            "ERROR: --record cannot be combined with --groups or --subset; "
            "committed reports under reports/ must represent the complete 480-entry benchmark.",
            file=sys.stderr,
        )
        return 2

    bench_dir = os.path.abspath(args.bench_dir)
    recordings_dir = (
        os.path.abspath(args.recordings_dir)
        if args.recordings_dir
        else os.path.join(bench_dir, "recordings")
    )
    manifest_path = os.path.join(recordings_dir, "manifest.json")

    now_utc = datetime.datetime.now(datetime.timezone.utc)
    date_str = now_utc.strftime("%Y-%m-%d")
    iso_now = now_utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    git_meta = _git_info(REPO_ROOT)

    # 1. Structural & parity check on gold.jsonl and entries/*.bib
    (
        structural_ok,
        structural_errors,
        gold_by_group,
        entries_by_group,
        raw_blocks_by_group,
    ) = _load_gold_and_entries(bench_dir, target_groups, is_full_groups)

    incomplete_reasons: List[str] = []
    if not is_full_groups:
        incomplete_reasons.append("partial_selection_groups")
    if args.subset is not None:
        incomplete_reasons.append(f"partial_selection_subset_{args.subset}")
    if not structural_ok:
        incomplete_reasons.append("structural_or_gold_parity_failure")

    manifest_sha256 = _sha256_file(manifest_path)
    manifest_count: Optional[int] = None
    manifest_openalex_credits: Optional[int] = None
    if os.path.isfile(manifest_path):
        try:
            with open(manifest_path, encoding="utf-8") as mf:
                m_obj = json.load(mf)
            manifest_count = int(m_obj.get("count", 0))
            credits_acc = 0
            for item in m_obj.get("items", []):
                if item.get("service") == "openalex":
                    hdrs = item.get("response_headers") or {}
                    c_raw = hdrs.get("x-ratelimit-credits-used")
                    if c_raw is not None:
                        try:
                            credits_acc += int(float(str(c_raw)))
                        except ValueError:
                            pass
            manifest_openalex_credits = credits_acc
        except Exception:
            pass

    if not structural_ok:
        report_path = _select_report_path(
            REPO_ROOT, mode_name, date_str, args.record, args.output
        )
        failed_report = {
            "date": date_str,
            "generated_at": iso_now,
            "git_commit": git_meta["commit"],
            "git_commit_full": git_meta["commit_full"],
            "git_dirty": git_meta["dirty"],
            "mode": mode_name,
            "selection": {
                "full_benchmark": not is_partial_selection,
                "groups": target_groups,
                "subset": args.subset,
                "seed": args.seed,
            },
            "complete": False,
            "incomplete_reasons": incomplete_reasons,
            "structural_ok": False,
            "structural_errors": structural_errors,
            "recordings_manifest_sha256": manifest_sha256,
            "recordings_manifest_count": manifest_count,
            "replay_miss_count": 0,
            "replay_misses": [],
            "overall_metrics": None,
            "selected_metrics": None,
            "real_three_non_verified_entries": [],
            "per_group": {},
        }
        with open(report_path, "w", encoding="utf-8", newline="\n") as out_f:
            json.dump(failed_report, out_f, ensure_ascii=False, indent=2, sort_keys=True)
            out_f.write("\n")
        print(f"BENCHMARK INCOMPLETE: structural/parity errors ({len(structural_errors)}):")
        for err in structural_errors:
            print(f"  - {err}")
        print(f"[m1-citation-bench] report written to {report_path}")
        return 1

    # 2. Resolve CLI binary
    cli_bin, bin_err = _resolve_cli_bin(REPO_ROOT)
    if not cli_bin:
        print(f"ERROR: {bin_err}", file=sys.stderr)
        return 2

    # 3. Select entries (full or fixed-seed stratified --subset)
    selected_keys_by_group: Dict[str, List[str]] = {}
    if args.subset is not None:
        group_sizes = {g: len(entries_by_group[g]) for g in target_groups}
        alloc = _allocate_subset_counts(target_groups, group_sizes, args.subset)
        for g in target_groups:
            all_keys = [e.key for e in entries_by_group[g]]
            k_take = alloc[g]
            if k_take >= len(all_keys):
                selected_keys_by_group[g] = all_keys
            else:
                rng = random.Random(f"{args.seed}:{g}")
                chosen = set(rng.sample(all_keys, k_take))
                selected_keys_by_group[g] = [k for k in all_keys if k in chosen]
    else:
        for g in target_groups:
            selected_keys_by_group[g] = [e.key for e in entries_by_group[g]]

    gold_lookup: Dict[str, Dict[str, Any]] = {}
    entry_has_id_lookup: Dict[str, bool] = {}
    for g in target_groups:
        for row in gold_by_group[g]:
            gold_lookup[row["key"]] = row
        for ent in entries_by_group[g]:
            entry_has_id_lookup[ent.key] = _entry_has_identifier(ent)

    work_dir = tempfile.mkdtemp(prefix="scholaros-bench-work.")
    start_monotonic = time.monotonic()
    stderr_blobs: List[str] = []
    replay_misses: List[Dict[str, Any]] = []
    cli_errors: List[Dict[str, Any]] = []
    verdicts_by_key: Dict[str, Dict[str, Any]] = {}
    group_run_status: Dict[str, str] = {}
    live_vs_replay_diff: Optional[List[Dict[str, Any]]] = None

    try:
        sandbox_home = os.path.join(work_dir, "home")
        os.makedirs(sandbox_home, exist_ok=True)
        sub_env = dict(os.environ)
        sub_env["HOME"] = sandbox_home
        sub_env["CFFIXED_USER_HOME"] = sandbox_home

        if not is_live:
            # M1 'settled decisions' rule: benchmark replay NEVER uses cache
            sub_env.pop("SCHOLAR_CACHE_DIR", None)
        else:
            live_cache_dir = os.path.join(work_dir, "cache")
            os.makedirs(live_cache_dir, exist_ok=True)
            sub_env["SCHOLAR_CACHE_DIR"] = live_cache_dir

        # Prepare per-group .bib paths (exact original file when full group, raw-slice temp file on --subset)
        group_bib_paths: Dict[str, str] = {}
        for g in target_groups:
            sel_keys = selected_keys_by_group[g]
            if len(sel_keys) == len(entries_by_group[g]):
                group_bib_paths[g] = os.path.join(bench_dir, "entries", f"{g}.bib")
            else:
                sub_bib = os.path.join(work_dir, f"{g}.subset.bib")
                blocks = [raw_blocks_by_group[g][k] for k in sel_keys]
                with open(sub_bib, "wb") as sbf:
                    sbf.write(b"\n".join(blocks) + b"\n")
                group_bib_paths[g] = sub_bib

        if not is_live:
            # Replay mode: run group by group so partial recordings clearly report which groups hit/missed
            for g in target_groups:
                proc = _run_cli_verify(
                    cli_bin=cli_bin,
                    bib_path=group_bib_paths[g],
                    extra_args=["--registry-replay", recordings_dir],
                    env=sub_env,
                    timeout_sec=600,
                )
                stderr_blobs.append(proc.stderr)
                if proc.returncode == 2:
                    m_url = UNRECORDED_URL_RE.search(proc.stderr)
                    missing_url = m_url.group(1) if m_url else None
                    if missing_url or "ERR_REGISTRY_REPLAY" in proc.stderr:
                        group_run_status[g] = "REPLAY_MISS"
                        replay_misses.append(
                            {
                                "group": g,
                                "exit_code": proc.returncode,
                                "missing_url": missing_url,
                                "stderr": proc.stderr.strip(),
                            }
                        )
                    else:
                        group_run_status[g] = "CLI_ERROR"
                        cli_errors.append(
                            {
                                "group": g,
                                "exit_code": proc.returncode,
                                "stderr": proc.stderr.strip(),
                            }
                        )
                    continue

                try:
                    payload = json.loads(proc.stdout)
                    for v in payload.get("verdicts", []):
                        verdicts_by_key[v["citeKey"]] = v
                    group_run_status[g] = "OK"
                except Exception as exc:
                    group_run_status[g] = "CLI_ERROR"
                    cli_errors.append(
                        {
                            "group": g,
                            "exit_code": proc.returncode,
                            "stderr": f"Invalid JSON output ({exc}): {proc.stderr.strip()}",
                        }
                    )
        elif args.record:
            # --live --record: run group by group with --registry-record so recordings/ updates incrementally
            for g in target_groups:
                proc = _run_cli_verify(
                    cli_bin=cli_bin,
                    bib_path=group_bib_paths[g],
                    extra_args=[
                        "--registry-record",
                        recordings_dir,
                        "--registry-record-limit",
                        str(args.record_limit),
                        "--no-cache",
                    ],
                    env=sub_env,
                    timeout_sec=3600,
                )
                stderr_blobs.append(proc.stderr)
                if proc.returncode == 2:
                    group_run_status[g] = "CLI_ERROR"
                    cli_errors.append(
                        {
                            "group": g,
                            "exit_code": proc.returncode,
                            "stderr": proc.stderr.strip(),
                        }
                    )
                    continue
                try:
                    payload = json.loads(proc.stdout)
                    for v in payload.get("verdicts", []):
                        verdicts_by_key[v["citeKey"]] = v
                    group_run_status[g] = "OK"
                except Exception as exc:
                    group_run_status[g] = "CLI_ERROR"
                    cli_errors.append(
                        {
                            "group": g,
                            "exit_code": proc.returncode,
                            "stderr": f"Invalid JSON output ({exc})",
                        }
                    )
        else:
            # --live (without --record): run a single combined invocation so one RegistryRateLimiter
            # and one OpenAlexSearchBudgetScope govern the entire live run (Row 23).
            if len(target_groups) == 1:
                combined_bib = group_bib_paths[target_groups[0]]
            else:
                combined_bib = os.path.join(work_dir, "combined_live.bib")
                chunks: List[bytes] = []
                for g in target_groups:
                    with open(group_bib_paths[g], "rb") as gbf:
                        chunks.append(gbf.read())
                with open(combined_bib, "wb") as cbf:
                    cbf.write(b"\n\n".join(chunks))

            proc = _run_cli_verify(
                cli_bin=cli_bin,
                bib_path=combined_bib,
                extra_args=["--no-cache"],
                env=sub_env,
                timeout_sec=7200,
            )
            stderr_blobs.append(proc.stderr)
            if proc.returncode == 2:
                for g in target_groups:
                    group_run_status[g] = "CLI_ERROR"
                cli_errors.append(
                    {
                        "group": "ALL",
                        "exit_code": proc.returncode,
                        "stderr": proc.stderr.strip(),
                    }
                )
            else:
                try:
                    payload = json.loads(proc.stdout)
                    for v in payload.get("verdicts", []):
                        verdicts_by_key[v["citeKey"]] = v
                    for g in target_groups:
                        group_run_status[g] = "OK"
                except Exception as exc:
                    for g in target_groups:
                        group_run_status[g] = "CLI_ERROR"
                    cli_errors.append(
                        {
                            "group": "ALL",
                            "exit_code": proc.returncode,
                            "stderr": f"Invalid JSON output ({exc})",
                        }
                    )

            # Row 23: compare --live verdicts against --registry-replay when recordings exist
            if os.path.isfile(manifest_path) and not cli_errors:
                replay_env = dict(sub_env)
                replay_env.pop("SCHOLAR_CACHE_DIR", None)
                live_vs_replay_diff = []
                for g in target_groups:
                    r_proc = _run_cli_verify(
                        cli_bin=cli_bin,
                        bib_path=group_bib_paths[g],
                        extra_args=["--registry-replay", recordings_dir],
                        env=replay_env,
                        timeout_sec=600,
                    )
                    if r_proc.returncode == 2:
                        continue
                    try:
                        r_payload = json.loads(r_proc.stdout)
                        for rv in r_payload.get("verdicts", []):
                            k = rv["citeKey"]
                            lv = verdicts_by_key.get(k)
                            if lv is None:
                                continue
                            l_cls = lv.get("firewallClass")
                            r_cls = rv.get("firewallClass")
                            l_rsn = sorted(lv.get("reasons") or [])
                            r_rsn = sorted(rv.get("reasons") or [])
                            if l_cls != r_cls or l_rsn != r_rsn:
                                live_vs_replay_diff.append(
                                    {
                                        "key": k,
                                        "group": g,
                                        "live_verdict": l_cls,
                                        "live_reasons": l_rsn,
                                        "replay_verdict": r_cls,
                                        "replay_reasons": r_rsn,
                                    }
                                )
                    except Exception:
                        pass
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

    elapsed_seconds = round(time.monotonic() - start_monotonic, 3)

    # Refresh manifest SHA-256 if --live --record updated recordings/
    if is_live and args.record:
        manifest_sha256 = _sha256_file(manifest_path)
        if os.path.isfile(manifest_path):
            try:
                with open(manifest_path, encoding="utf-8") as mf:
                    manifest_count = int(json.load(mf).get("count", 0))
            except Exception:
                pass

    telemetry = _parse_telemetry(stderr_blobs)

    # 4. Assemble per-group records & detect incomplete / transient failures
    records_by_group: Dict[str, List[Dict[str, Any]]] = {}
    all_evaluated_records: List[Dict[str, Any]] = []
    per_group_report: Dict[str, Any] = {}
    transient_failure_entries: List[Dict[str, Any]] = []

    all_selected_succeeded = (len(replay_misses) == 0) and (len(cli_errors) == 0)

    for g in target_groups:
        sel_keys = selected_keys_by_group[g]
        status = group_run_status.get(g, "NOT_RUN")
        if status != "OK":
            all_selected_succeeded = False
            per_group_report[g] = {
                "group": g,
                "status": status,
                "expected_group_count": GROUP_COUNTS[g],
                "selected_count": len(sel_keys),
                "evaluated_count": 0,
                "verified_with_venue_hint_count": None,
                "metrics": None,
                "unexpected_entries": [],
            }
            continue

        g_records: List[Dict[str, Any]] = []
        unexpected_entries: List[Dict[str, Any]] = []
        for k in sel_keys:
            v_obj = verdicts_by_key.get(k)
            if v_obj is None:
                all_selected_succeeded = False
                continue
            gold_row = gold_lookup[k]
            v_class = str(v_obj.get("firewallClass", ""))
            v_reasons = list(v_obj.get("reasons") or [])
            v_fields = list(v_obj.get("fields") or [])
            v_findings = list(v_obj.get("findings") or [])
            v_sources = list(v_obj.get("sources") or [])
            audit_note = str(v_obj.get("auditNote") or "")

            if v_class == "UNVERIFIED" and any(r in TRANSIENT_UNVERIFIED_REASONS for r in v_reasons):
                transient_failure_entries.append(
                    {"key": k, "group": g, "reasons": v_reasons}
                )

            rec = {
                "key": k,
                "group": g,
                "truth": gold_row["truth"],
                "expected": gold_row["expected"],
                "insertable": bool(gold_row["insertable"]),
                "provenance": gold_row["provenance"],
                "has_identifier": entry_has_id_lookup[k],
                "verdict": v_class,
                "reasons": v_reasons,
                "fields": v_fields,
                "findings": v_findings,
                "sources": v_sources,
                "audit_note": audit_note,
            }
            g_records.append(rec)
            all_evaluated_records.append(rec)

            if v_class not in gold_row["expected"]:
                unexpected_entries.append(
                    {
                        "key": k,
                        "verdict": v_class,
                        "reasons": v_reasons,
                        "expected": gold_row["expected"],
                        "truth": gold_row["truth"],
                        "insertable": bool(gold_row["insertable"]),
                    }
                )

        if len(g_records) != len(sel_keys):
            all_selected_succeeded = False

        records_by_group[g] = g_records
        g_metrics = _compute_metrics_bundle(g_records)
        per_group_report[g] = {
            "group": g,
            "status": "OK",
            "expected_group_count": GROUP_COUNTS[g],
            "selected_count": len(sel_keys),
            "evaluated_count": len(g_records),
            "verdict_counts": g_metrics["verdict_counts"],
            "verified_with_venue_hint_count": g_metrics["verified_with_venue_hint_count"],
            "confusion_matrix": g_metrics["confusion_matrix"],
            "in_expected": g_metrics["in_expected"],
            "unverified": g_metrics["unverified"],
            "allow_precision": g_metrics["allow_precision"],
            "allow_recall": g_metrics["allow_recall"],
            "unexpected_entries": unexpected_entries,
        }

    if replay_misses:
        incomplete_reasons.append("replay_miss")
    if cli_errors:
        incomplete_reasons.append("cli_execution_error")
    if transient_failure_entries:
        incomplete_reasons.append("transient_unverified_errors")

    complete = (
        (not is_partial_selection)
        and structural_ok
        and all_selected_succeeded
        and (len(all_evaluated_records) == TOTAL_BENCHMARK_COUNT)
        and (len(transient_failure_entries) == 0)
    )

    # Never emit fake overall metrics when any target group missed or failed!
    overall_metrics: Optional[Dict[str, Any]] = None
    selected_metrics: Optional[Dict[str, Any]] = None
    identifier_breakdown: Optional[Dict[str, Any]] = None

    if all_selected_succeeded and all_evaluated_records:
        computed = _compute_metrics_bundle(all_evaluated_records)
        if complete:
            overall_metrics = computed
        else:
            selected_metrics = computed

        with_id_recs = [r for r in all_evaluated_records if r["has_identifier"]]
        without_id_recs = [r for r in all_evaluated_records if not r["has_identifier"]]
        identifier_breakdown = {
            "with_identifier": _compute_metrics_bundle(with_id_recs),
            "without_identifier": _compute_metrics_bundle(without_id_recs),
        }
        if "fabricated_model" in records_by_group:
            fab_recs = records_by_group["fabricated_model"]
            identifier_breakdown["fabricated_model_by_identifier"] = {
                "with_identifier": _compute_metrics_bundle(
                    [r for r in fab_recs if r["has_identifier"]]
                ),
                "without_identifier": _compute_metrics_bundle(
                    [r for r in fab_recs if not r["has_identifier"]]
                ),
            }

    hard_requirements, provisional_thresholds, hypothesis_measurements = _evaluate_gates(
        all_records=all_evaluated_records,
        records_by_group=records_by_group,
        is_full_benchmark=(not is_partial_selection),
        complete=complete,
    )

    recorded_only: Dict[str, Any] = {
        "elapsed_seconds": elapsed_seconds,
        "http_request_count": telemetry["http_request_count"],
        "replay_lookup_count": telemetry["replay_lookup_count"],
        "cache_hit_count": telemetry["cache_hit_count"],
        "openalex_credits_used": (
            telemetry["openalex_credits_used"]
            if is_live
            else manifest_openalex_credits
        ),
        "crossref_max_in_flight": telemetry["crossref_max_in_flight"],
        "live_vs_replay_diff": live_vs_replay_diff,
        "hypothesis_measurements": hypothesis_measurements,
    }
    if overall_metrics is not None:
        recorded_only["unverified"] = overall_metrics["unverified"]
    elif selected_metrics is not None:
        recorded_only["unverified"] = selected_metrics["unverified"]

    real_three_non_verified_entries = _collect_real_three_non_verified_entries(
        records_by_group
    )

    report_obj: Dict[str, Any] = {
        "date": date_str,
        "generated_at": iso_now,
        "git_commit": git_meta["commit"],
        "git_commit_full": git_meta["commit_full"],
        "git_dirty": git_meta["dirty"],
        "mode": mode_name,
        "selection": {
            "full_benchmark": not is_partial_selection,
            "groups": target_groups,
            "subset": args.subset,
            "seed": args.seed,
        },
        "complete": complete,
        "incomplete_reasons": incomplete_reasons,
        "structural_ok": structural_ok,
        "recordings_manifest_sha256": manifest_sha256,
        "recordings_manifest_count": manifest_count,
        "replay_miss_count": len(replay_misses),
        "replay_misses": replay_misses,
        "cli_errors": cli_errors,
        "transient_failure_entries": transient_failure_entries,
        "overall_metrics": overall_metrics,
        "selected_metrics": selected_metrics,
        "identifier_breakdown": identifier_breakdown,
        "hard_requirements": hard_requirements,
        "provisional_thresholds": provisional_thresholds,
        "real_three_non_verified_entries": real_three_non_verified_entries,
        "recorded_only": recorded_only,
        "per_group": per_group_report,
    }

    report_path = _select_report_path(
        REPO_ROOT, mode_name, date_str, args.record, args.output
    )
    with open(report_path, "w", encoding="utf-8", newline="\n") as out_f:
        json.dump(report_obj, out_f, ensure_ascii=False, indent=2, sort_keys=True)
        out_f.write("\n")

    # 5. Print concise human-readable summary & out-of-expected entries
    scope_label = "FULL (480)" if not is_partial_selection else f"PARTIAL (groups={','.join(target_groups)}, subset={args.subset})"
    print(
        f"ScholarOS M1 Citation Benchmark | mode={mode_name} | scope={scope_label} "
        f"| commit={git_meta['commit']} | complete={str(complete).lower()} | elapsed={elapsed_seconds:.2f}s"
    )
    if manifest_sha256:
        print(f"recordings/manifest.json sha256={manifest_sha256} (items={manifest_count})")
    print("-" * 100)
    print(
        "%-18s %6s %5s %6s %5s %5s %5s %5s %10s  %s"
        % ("group", "eval", "VER", "v_hint", "DRF", "NF", "RET", "UNV", "in_expect", "status")
    )
    print("-" * 100)
    for g in target_groups:
        gp = per_group_report[g]
        if gp["status"] != "OK":
            print(
                "%-18s %6s %5s %6s %5s %5s %5s %5s %10s  %s"
                % (g, f"0/{gp['selected_count']}", "-", "-", "-", "-", "-", "-", "-", gp["status"])
            )
            continue
        vc = gp["verdict_counts"]
        ie = gp["in_expected"]
        ie_pct = f"{ie['rate'] * 100:.1f}%" if ie["rate"] is not None else "n/a"
        print(
            "%-18s %6d %5d %6d %5d %5d %5d %5d %10s  %s"
            % (
                g,
                gp["evaluated_count"],
                vc["VERIFIED"],
                gp["verified_with_venue_hint_count"],
                vc["DRIFT"],
                vc["NOT_FOUND"],
                vc["RETRACTED"],
                vc["UNVERIFIED"],
                f"{ie['numerator']}/{ie['denominator']} ({ie_pct})",
                gp["status"],
            )
        )
    print("-" * 100)

    if replay_misses:
        print(f"\nReplay misses ({len(replay_misses)} group(s)):")
        for rm in replay_misses:
            print(f"  - {rm['group']}: missing_url={rm['missing_url'] or rm['stderr']}")

    if cli_errors:
        print(f"\nCLI errors ({len(cli_errors)}):")
        for ce in cli_errors:
            print(f"  - {ce['group']} (exit {ce['exit_code']}): {ce['stderr']}")

    active_metrics = overall_metrics or selected_metrics
    if active_metrics is not None:
        ap = active_metrics["allow_precision"]
        ar = active_metrics["allow_recall"]
        bp = active_metrics["block_precision"]
        br = active_metrics["block_recall"]
        unv = active_metrics["unverified"]
        vh_cnt = active_metrics["verified_with_venue_hint_count"]
        ap_s = f"{ap['rate'] * 100:.2f}%" if ap["rate"] is not None else "n/a (0 VERIFIED)"
        ar_s = f"{ar['rate'] * 100:.2f}%" if ar["rate"] is not None else "n/a"
        bp_s = f"{bp['rate'] * 100:.2f}%" if bp["rate"] is not None else "n/a"
        br_s = f"{br['rate'] * 100:.2f}%" if br["rate"] is not None else "n/a"
        unv_s = f"{unv['rate'] * 100:.2f}%" if unv["rate"] is not None else "n/a"
        metrics_heading = "Overall Metrics (480/480)" if complete else "Selected Slice Metrics (partial, complete=false)"
        print(f"\n{metrics_heading}:")
        print(f"  Allow (VERIFIED): precision={ap['numerator']}/{ap['denominator']} ({ap_s}), recall={ar['numerator']}/{ar['denominator']} ({ar_s}), verified_with_venue_hint={vh_cnt}")
        print(f"  Block (DRIFT/NOT_FOUND/RETRACTED vs truth!=real): precision={bp['numerator']}/{bp['denominator']} ({bp_s}), recall={br['numerator']}/{br['denominator']} ({br_s})")
        print(f"  Unverified: {unv['count']}/{active_metrics['total_entries']} ({unv_s}) by_reason={unv['by_reason']}")
        print(f"  Hard gate (non-insertable VERIFIED == 0): count={hard_requirements['non_insertable_verified_count']} passed={hard_requirements['passed']}")
        if identifier_breakdown is not None:
            no_id = identifier_breakdown["without_identifier"]
            print(
                f"  Identifierless entries: total={no_id['total_entries']} verdicts={no_id['verdict_counts']} "
                f"in_expected={no_id['in_expected']['numerator']}/{no_id['in_expected']['denominator']}"
            )

    # Row 7 helper: list non-VERIFIED entries among truth == 'real' in (real_clean, real_human, real_typo)
    evaluated_real_three_truth_real = sum(
        1
        for g in REAL_THREE_GROUPS
        for r in records_by_group.get(g, [])
        if r.get("truth") == "real"
    )
    if any(g in records_by_group for g in REAL_THREE_GROUPS):
        if real_three_non_verified_entries:
            print(
                f"\nReal three groups (truth=real) non-VERIFIED entries ({len(real_three_non_verified_entries)}/{evaluated_real_three_truth_real}):"
            )
            for item in real_three_non_verified_entries:
                print(
                    f"  - [{item['group']}] {item['key']}: verdict={item['verdict']} reasons={item['reasons']}"
                )
        else:
            print(
                f"\nReal three groups (truth=real) non-VERIFIED entries: 0/{evaluated_real_three_truth_real}"
            )

    # Print all entries outside gold.jsonl `expected`
    any_unexpected = False
    for g in target_groups:
        gp = per_group_report[g]
        for ue in gp.get("unexpected_entries", []):
            if not any_unexpected:
                print("\nEntries outside gold.jsonl expected:")
                any_unexpected = True
            print(
                f"  - [{g}] {ue['key']}: verdict={ue['verdict']} reasons={ue['reasons']} (expected={ue['expected']})"
            )
    if all_selected_succeeded and not any_unexpected:
        print("\nEntries outside gold.jsonl expected: 0")

    print(f"[m1-citation-bench] report written to {report_path}")

    # Exit code determination:
    # - Full benchmark run: must have complete == True AND hard_requirements.passed AND provisional_thresholds.passed
    # - Partial selection (--groups / --subset): report has complete == False, exits 0 iff all selected groups ran
    #   cleanly with 0 misses/transient errors AND passed hard safety gates.
    if not all_selected_succeeded or len(transient_failure_entries) > 0:
        return 1
    if not hard_requirements["passed"]:
        return 1
    if not is_partial_selection:
        if not complete:
            return 1
        if provisional_thresholds is not None and not provisional_thresholds["passed"]:
            return 1
        if is_live and telemetry["crossref_max_in_flight"] > 1:
            print(
                f"FAIL: Crossref max concurrent in-flight requests was {telemetry['crossref_max_in_flight']} (> 1)",
                file=sys.stderr,
            )
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
