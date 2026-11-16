#!/usr/bin/env python3
"""Offline unit tests for Scripts/acceptance/m1-citation-bench.py."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from typing import Any, Dict, List

TOOLS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(TOOLS_DIR)))
BENCH_SCRIPT = os.path.join(REPO_ROOT, "Scripts", "acceptance", "m1-citation-bench.py")

if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)

from _common import GROUP_SPECS, expected_keys_for_group  # noqa: E402


def _load_bench_module():
    if not os.path.isfile(BENCH_SCRIPT):
        raise FileNotFoundError(f"Missing benchmark script: {BENCH_SCRIPT}")
    spec = importlib.util.spec_from_file_location("m1_citation_bench", BENCH_SCRIPT)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CitationBenchScriptUnitTests(unittest.TestCase):
    def test_live_without_scholar_online_prints_meipao_and_exits_2(self) -> None:
        self.assertTrue(os.path.isfile(BENCH_SCRIPT), "m1-citation-bench.py must exist")
        env = dict(os.environ)
        env.pop("SCHOLAR_ONLINE", None)
        proc = subprocess.run(
            [sys.executable, "-I", BENCH_SCRIPT, "--live"],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2)
        combined = proc.stdout + proc.stderr
        self.assertIn("没跑", combined)

    def test_partial_record_rejected_with_exit_2(self) -> None:
        self.assertTrue(os.path.isfile(BENCH_SCRIPT), "m1-citation-bench.py must exist")
        proc = subprocess.run(
            [
                sys.executable,
                "-I",
                BENCH_SCRIPT,
                "--replay",
                "--groups",
                "audit_manual",
                "--record",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2)

    def test_missing_group_or_gold_mismatch_sets_complete_false_and_exits_nonzero(self) -> None:
        mod = _load_bench_module()
        temp_dir = tempfile.mkdtemp(prefix="bench-unit-incomplete-")
        try:
            entries_dir = os.path.join(temp_dir, "entries")
            rec_dir = os.path.join(temp_dir, "recordings")
            os.makedirs(entries_dir)
            os.makedirs(rec_dir)
            with open(os.path.join(temp_dir, "README.md"), "w", encoding="utf-8") as rf:
                rf.write("# Temp Benchmark\n")

            # Only write audit_manual (30 entries), omitting the other 11 groups
            bib_lines: List[str] = []
            gold_rows: List[Dict[str, Any]] = []
            for key in expected_keys_for_group("audit_manual", 30):
                bib_lines.append(
                    f"@article{{{key}, author={{Doe, Jane}}, title={{Paper {key}}}, journal={{J}}, year={{2024}}, doi={{10.1038/{key}}}}}"
                )
                gold_rows.append(
                    {
                        "key": key,
                        "group": "audit_manual",
                        "truth": "real",
                        "expected": ["VERIFIED"],
                        "insertable": True,
                        "provenance": {"source": "unit-test"},
                        "note": "",
                    }
                )
            with open(os.path.join(entries_dir, "audit_manual.bib"), "w", encoding="utf-8") as bf:
                bf.write("\n\n".join(bib_lines) + "\n")
            with open(os.path.join(temp_dir, "gold.jsonl"), "w", encoding="utf-8") as gf:
                for row in gold_rows:
                    gf.write(json.dumps(row) + "\n")

            out_json = os.path.join(temp_dir, "report.json")
            rc = mod.main(["--replay", "--bench-dir", temp_dir, "--output", out_json])
            self.assertNotEqual(rc, 0, "Missing 11 groups must exit non-zero")
            with open(out_json, encoding="utf-8") as f:
                report = json.load(f)
            self.assertFalse(report["complete"])
            self.assertIsNone(
                report.get("overall_metrics"),
                "Incomplete benchmark must not emit complete-looking overall metrics",
            )
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    def test_replay_strips_scholar_cache_dir_isolates_home_and_computes_metrics_and_unexpected(self) -> None:
        mod = _load_bench_module()
        temp_dir = tempfile.mkdtemp(prefix="bench-unit-stub-")
        try:
            entries_dir = os.path.join(temp_dir, "entries")
            rec_dir = os.path.join(temp_dir, "recordings")
            os.makedirs(entries_dir)
            os.makedirs(rec_dir)
            with open(os.path.join(temp_dir, "README.md"), "w", encoding="utf-8") as rf:
                rf.write("# Stub Benchmark\n")

            manifest_bytes = json.dumps({"count": 1, "items": []}, sort_keys=True).encode("utf-8")
            with open(os.path.join(rec_dir, "manifest.json"), "wb") as mf:
                mf.write(manifest_bytes)
            expected_sha = hashlib.sha256(manifest_bytes).hexdigest()

            # Build full 12-group benchmark with deterministic entries
            gold_rows: List[Dict[str, Any]] = []
            verdict_plan: Dict[str, Dict[str, Any]] = {}

            for group, count in GROUP_SPECS:
                keys = expected_keys_for_group(group, count)
                bib_chunks: List[str] = []
                for idx, key in enumerate(keys):
                    has_doi = not (group == "fabricated_model" and idx >= count - 10)
                    if has_doi:
                        bib_chunks.append(
                            f"@article{{{key}, author={{Author, A.}}, title={{Title {key}}}, journal={{J}}, year={{2024}}, doi={{10.1000/{key}}}}}"
                        )
                    else:
                        bib_chunks.append(
                            f"@article{{{key}, author={{Author, A.}}, title={{Title {key}}}, journal={{J}}, year={{2024}}}}"
                        )

                    if group in ("real_clean", "real_human"):
                        truth = "real"
                        insertable = True
                        expected = ["VERIFIED"] if group == "real_clean" else ["VERIFIED", "DRIFT"]
                        planned_class = "VERIFIED"
                        reasons = []
                        fields = []
                    elif group == "real_typo":
                        if idx < 5:
                            truth = "mutated"
                            insertable = False
                            expected = ["DRIFT"]
                            planned_class = "DRIFT"
                            reasons = ["title_mismatch"]
                            fields = [{"field": "title", "localValue": "bad", "remoteValue": "good", "source": "Crossref", "severity": "error"}]
                        else:
                            truth = "real"
                            insertable = True
                            expected = ["VERIFIED"]
                            planned_class = "VERIFIED"
                            reasons = []
                            fields = []
                    elif group == "retracted":
                        truth = "retracted"
                        insertable = False
                        expected = ["RETRACTED"]
                        planned_class = "RETRACTED"
                        reasons = ["retracted_crossref"]
                        fields = []
                    elif group == "fabricated_model":
                        truth = "fabricated"
                        insertable = False
                        expected = ["NOT_FOUND", "DRIFT"] if has_doi else ["NOT_FOUND", "DRIFT", "UNVERIFIED"]
                        planned_class = "NOT_FOUND" if has_doi else "UNVERIFIED"
                        reasons = ["doi_not_registered"] if has_doi else ["no_match_in_search"]
                        fields = []
                    elif group == "mut_doi_missing":
                        truth = "mutated"
                        insertable = False
                        expected = ["DRIFT", "NOT_FOUND"]
                        planned_class = "DRIFT"
                        reasons = ["doi_mismatch"]
                        fields = [
                            {
                                "field": "doi",
                                "localValue": f"10.1000/missing.{idx}",
                                "remoteValue": f"10.1000/true.{idx}",
                                "source": "Crossref",
                                "severity": "error",
                            }
                        ]
                    elif group == "mut_year1":
                        truth = "mutated"
                        insertable = False
                        expected = ["DRIFT"]
                        planned_class = "DRIFT"
                        reasons = ["year_mismatch"]
                        fields = [
                            {
                                "field": "year",
                                "localValue": "2023",
                                "remoteValue": "2024",
                                "source": "Crossref",
                                "severity": "warning",
                                "note": "may reflect online-first vs. print-issue publication dates",
                            }
                        ]
                    else:
                        truth = "mutated" if group != "audit_manual" else "real"
                        insertable = (group == "audit_manual")
                        expected = ["VERIFIED"] if group == "audit_manual" else ["DRIFT"]
                        planned_class = "VERIFIED" if group == "audit_manual" else "DRIFT"
                        reasons = [] if planned_class == "VERIFIED" else ["title_mismatch"]
                        fields = [] if planned_class == "VERIFIED" else [
                            {"field": "title", "localValue": "a", "remoteValue": "b", "source": "Crossref", "severity": "error"}
                        ]

                    prov: Dict[str, Any] = {"source": "stub"}
                    if group == "mut_doi_missing":
                        prov["true_doi"] = f"10.1000/true.{idx}"

                    gold_rows.append(
                        {
                            "key": key,
                            "group": group,
                            "truth": truth,
                            "expected": expected,
                            "insertable": insertable,
                            "provenance": prov,
                            "note": "",
                        }
                    )
                    verdict_plan[key] = {
                        "citeKey": key,
                        "firewallClass": planned_class,
                        "insertable": planned_class == "VERIFIED",
                        "reasons": reasons,
                        "sources": [
                            {
                                "source": "Crossref",
                                "url": f"https://api.crossref.org/works/10.1000/{key}",
                                "status": 200,
                                "fetchedAt": "2026-11-16T00:00:00Z",
                                "origin": "replay",
                            }
                        ],
                        "fields": fields,
                        "findings": [
                            {
                                "code": "FW_BLOCKED_RETRACTED",
                                "severity": "criticalBlock",
                                "field": "updated-by",
                                "detail": "Crossref updated-by retraction",
                            }
                        ]
                        if planned_class == "RETRACTED"
                        else [],
                        "auditNote": "Crossref updated-by retraction" if planned_class == "RETRACTED" else "stub",
                    }

                with open(os.path.join(entries_dir, f"{group}.bib"), "w", encoding="utf-8") as bf:
                    bf.write("\n\n".join(bib_chunks) + "\n")

            with open(os.path.join(temp_dir, "gold.jsonl"), "w", encoding="utf-8") as gf:
                for row in gold_rows:
                    gf.write(json.dumps(row) + "\n")

            plan_path = os.path.join(temp_dir, "plan.json")
            env_log_path = os.path.join(temp_dir, "seen_env.jsonl")
            with open(plan_path, "w", encoding="utf-8") as pf:
                json.dump(verdict_plan, pf)

            # Fake CLI binary that asserts SCHOLAR_CACHE_DIR is NOT set on replay and HOME is isolated
            fake_cli = os.path.join(temp_dir, "fake-scholaros")
            with open(fake_cli, "w", encoding="utf-8") as cf:
                cf.write(
                    f"""#!{sys.executable}
import json, os, re, sys
args = sys.argv[1:]
bib_path = [a for a in args if not a.startswith("-") and a != "verify-citations"][0]
with open({env_log_path!r}, "a", encoding="utf-8") as ef:
    ef.write(json.dumps({{
        "has_cache_dir": "SCHOLAR_CACHE_DIR" in os.environ,
        "home": os.environ.get("HOME", ""),
        "args": args,
    }}) + "\\n")
if "--registry-replay" in args and "SCHOLAR_CACHE_DIR" in os.environ:
    sys.stderr.write("ERROR: SCHOLAR_CACHE_DIR leaked into replay!\\n")
    sys.exit(2)
with open({plan_path!r}, encoding="utf-8") as pf:
    plan = json.load(pf)
with open(bib_path, encoding="utf-8") as bf:
    keys = re.findall(r"@\\w+\\{{\\s*([^,\\s]+)\\s*,", bf.read())
verdicts = [plan[k] for k in keys]
counts = {{c: sum(1 for v in verdicts if v["firewallClass"] == c) for c in ("VERIFIED", "DRIFT", "NOT_FOUND", "RETRACTED", "UNVERIFIED")}}
out = {{
    "mode": "REPLAY",
    "replay": True,
    "generatedAtISO8601": "2026-11-16T00:00:00Z",
    "complete": counts["UNVERIFIED"] == 0,
    "totalEvaluated": len(verdicts),
    "verifiedCount": counts["VERIFIED"],
    "driftCount": counts["DRIFT"],
    "notFoundCount": counts["NOT_FOUND"],
    "retractedCount": counts["RETRACTED"],
    "unverifiedCount": counts["UNVERIFIED"],
    "unverifiedByReason": {{"no_match_in_search": counts["UNVERIFIED"]}} if counts["UNVERIFIED"] else {{}},
    "verdicts": verdicts,
}}
sys.stdout.write(json.dumps(out))
if counts["DRIFT"] or counts["NOT_FOUND"] or counts["RETRACTED"]:
    sys.exit(1)
if counts["UNVERIFIED"]:
    sys.exit(3)
sys.exit(0)
"""
                )
            os.chmod(fake_cli, os.stat(fake_cli).st_mode | stat.S_IXUSR)

            out_json = os.path.join(temp_dir, "full_report.json")
            old_bin = os.environ.get("SCHOLAR_CLI_BIN")
            old_cache = os.environ.get("SCHOLAR_CACHE_DIR")
            real_home = os.path.expanduser("~")
            try:
                os.environ["SCHOLAR_CLI_BIN"] = fake_cli
                os.environ["SCHOLAR_CACHE_DIR"] = "/tmp/should-be-stripped-in-replay"
                rc = mod.main(["--replay", "--bench-dir", temp_dir, "--output", out_json])
            finally:
                if old_bin is None:
                    os.environ.pop("SCHOLAR_CLI_BIN", None)
                else:
                    os.environ["SCHOLAR_CLI_BIN"] = old_bin
                if old_cache is None:
                    os.environ.pop("SCHOLAR_CACHE_DIR", None)
                else:
                    os.environ["SCHOLAR_CACHE_DIR"] = old_cache

            self.assertEqual(rc, 0)
            with open(out_json, encoding="utf-8") as rf:
                report = json.load(rf)
            self.assertTrue(report["complete"])
            self.assertEqual(report["recordings_manifest_sha256"], expected_sha)
            self.assertEqual(report["replay_miss_count"], 0)
            self.assertEqual(report["overall_metrics"]["allow_precision"]["rate"], 1.0)
            self.assertEqual(report["hard_requirements"]["non_insertable_verified_count"], 0)
            self.assertIn("without_identifier", report["identifier_breakdown"])

            with open(env_log_path, encoding="utf-8") as ef:
                seen_envs = [json.loads(line) for line in ef if line.strip()]
            self.assertEqual(len(seen_envs), 12)
            for seen in seen_envs:
                self.assertFalse(seen["has_cache_dir"])
                self.assertNotEqual(seen["home"], real_home)

            # Now flip 1 non-insertable entry to VERIFIED -> Row 5 hard gate must fail (exit 1)!
            verdict_plan["fab_codex_001"]["firewallClass"] = "VERIFIED"
            verdict_plan["fab_codex_001"]["insertable"] = True
            with open(plan_path, "w", encoding="utf-8") as pf:
                json.dump(verdict_plan, pf)

            bad_json = os.path.join(temp_dir, "bad_report.json")
            old_bin = os.environ.get("SCHOLAR_CLI_BIN")
            try:
                os.environ["SCHOLAR_CLI_BIN"] = fake_cli
                rc_bad = mod.main(["--replay", "--bench-dir", temp_dir, "--output", bad_json])
            finally:
                if old_bin is None:
                    os.environ.pop("SCHOLAR_CLI_BIN", None)
                else:
                    os.environ["SCHOLAR_CLI_BIN"] = old_bin
            self.assertEqual(rc_bad, 1, "False VERIFIED on non-insertable entry must fail hard gate")
            with open(bad_json, encoding="utf-8") as rf:
                bad_rep = json.load(rf)
            self.assertEqual(bad_rep["hard_requirements"]["non_insertable_verified_count"], 1)
            fab_unexpected = bad_rep["per_group"]["fabricated_model"]["unexpected_entries"]
            self.assertEqual(len(fab_unexpected), 1)
            self.assertEqual(fab_unexpected[0]["key"], "fab_codex_001")
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    def test_venue_hint_counts_and_real_three_non_verified_entries_in_report_and_stdout(self) -> None:
        mod = _load_bench_module()
        temp_dir = tempfile.mkdtemp(prefix="bench-unit-stage12-")
        try:
            entries_dir = os.path.join(temp_dir, "entries")
            rec_dir = os.path.join(temp_dir, "recordings")
            os.makedirs(entries_dir)
            os.makedirs(rec_dir)
            with open(os.path.join(temp_dir, "README.md"), "w", encoding="utf-8") as rf:
                rf.write("# Stage 12 Stub Benchmark\n")
            with open(os.path.join(rec_dir, "manifest.json"), "wb") as mf:
                mf.write(json.dumps({"count": 1, "items": []}, sort_keys=True).encode("utf-8"))

            gold_rows: List[Dict[str, Any]] = []
            verdict_plan: Dict[str, Dict[str, Any]] = {}

            for group, count in GROUP_SPECS:
                keys = expected_keys_for_group(group, count)
                bib_chunks: List[str] = []
                for idx, key in enumerate(keys):
                    bib_chunks.append(
                        f"@article{{{key}, author={{Author, A.}}, title={{Title {key}}}, journal={{J}}, year={{2024}}, doi={{10.1000/{key}}}}}"
                    )
                    if group == "real_clean":
                        truth = "real"
                        insertable = True
                        expected = ["VERIFIED"]
                        planned_class = "VERIFIED"
                        reasons = ["verified_match"]
                        fields: List[Dict[str, Any]] = []
                    elif group == "real_human":
                        truth = "real"
                        insertable = True
                        expected = ["VERIFIED", "DRIFT"]
                        if idx == 0:
                            planned_class = "DRIFT"
                            reasons = ["year_diff_1", "venue_mismatch"]
                            fields = [{"field": "year", "localValue": "2023", "remoteValue": "2024", "source": "Crossref", "severity": "warning"}]
                        elif idx == 1:
                            planned_class = "UNVERIFIED"
                            reasons = ["no_match_in_search"]
                            fields = []
                        elif idx in (2, 3, 4):
                            planned_class = "VERIFIED"
                            reasons = ["verified_match"]
                            fields = [
                                {
                                    "field": "venue",
                                    "localValue": "Ind. Eng. Chem.",
                                    "remoteValue": "Industrial & Engineering Chemistry Research",
                                    "source": "Crossref",
                                    "severity": "advisory",
                                    "note": "venue wording differs; not treated as a discrepancy",
                                }
                            ]
                        else:
                            planned_class = "VERIFIED"
                            reasons = ["verified_match"]
                            fields = []
                    elif group == "real_typo":
                        if idx < 5:
                            truth = "mutated"
                            insertable = False
                            expected = ["DRIFT"]
                            planned_class = "DRIFT"
                            reasons = ["title_mismatch"]
                            fields = [{"field": "title", "localValue": "bad", "remoteValue": "good", "source": "Crossref", "severity": "error"}]
                        elif idx == 5:
                            # Format-only real_typo entry (truth='real') that happened not to be VERIFIED
                            truth = "real"
                            insertable = True
                            expected = ["VERIFIED"]
                            planned_class = "DRIFT"
                            reasons = ["year_diff_1"]
                            fields = [{"field": "year", "localValue": "2023", "remoteValue": "2024", "source": "Crossref", "severity": "warning"}]
                        else:
                            truth = "real"
                            insertable = True
                            expected = ["VERIFIED"]
                            planned_class = "VERIFIED"
                            reasons = ["verified_match"]
                            fields = []
                    elif group == "audit_manual":
                        truth = "mutated" if idx == 19 else "real"
                        insertable = True
                        expected = ["VERIFIED", "DRIFT"] if idx == 19 else ["VERIFIED"]
                        planned_class = "VERIFIED"
                        reasons = ["verified_match"]
                        fields = (
                            [
                                {
                                    "field": "venue",
                                    "localValue": "Science",
                                    "remoteValue": "Nature",
                                    "source": "Crossref",
                                    "severity": "advisory",
                                }
                            ]
                            if idx == 19
                            else []
                        )
                    elif group == "retracted":
                        truth = "retracted"
                        insertable = False
                        expected = ["RETRACTED"]
                        planned_class = "RETRACTED"
                        reasons = ["retracted_crossref"]
                        fields = []
                    elif group == "mut_doi_missing":
                        truth = "mutated"
                        insertable = False
                        expected = ["DRIFT", "NOT_FOUND"]
                        planned_class = "DRIFT"
                        reasons = ["doi_mismatch"]
                        fields = [{"field": "doi", "localValue": "10.1/bad", "remoteValue": "10.1/true", "source": "Crossref", "severity": "error"}]
                    elif group == "mut_year1":
                        truth = "mutated"
                        insertable = False
                        expected = ["DRIFT"]
                        planned_class = "DRIFT"
                        reasons = ["year_diff_1"]
                        fields = [{"field": "year", "localValue": "2023", "remoteValue": "2024", "source": "Crossref", "severity": "warning", "note": "may reflect online-first vs. print-issue publication dates"}]
                    else:
                        truth = "mutated" if group != "fabricated_model" else "fabricated"
                        insertable = False
                        expected = ["DRIFT"]
                        planned_class = "DRIFT"
                        reasons = ["title_mismatch"]
                        fields = [{"field": "title", "localValue": "a", "remoteValue": "b", "source": "Crossref", "severity": "error"}]

                    prov: Dict[str, Any] = {"source": "stub"}
                    if group == "mut_doi_missing":
                        prov["true_doi"] = "10.1/true"
                    gold_rows.append(
                        {
                            "key": key,
                            "group": group,
                            "truth": truth,
                            "expected": expected,
                            "insertable": insertable,
                            "provenance": prov,
                            "note": "",
                        }
                    )
                    verdict_plan[key] = {
                        "citeKey": key,
                        "firewallClass": planned_class,
                        "insertable": planned_class == "VERIFIED",
                        "reasons": reasons,
                        "sources": [{"source": "Crossref", "url": f"https://api.crossref.org/works/10.1000/{key}", "status": 200, "fetchedAt": "2026-11-16T00:00:00Z", "origin": "replay"}],
                        "fields": fields,
                        "findings": [{"code": "FW_BLOCKED_RETRACTED", "severity": "criticalBlock", "field": "updated-by", "detail": "Crossref updated-by retraction"}] if planned_class == "RETRACTED" else [],
                        "auditNote": "Crossref updated-by retraction" if planned_class == "RETRACTED" else "stub",
                    }

                with open(os.path.join(entries_dir, f"{group}.bib"), "w", encoding="utf-8") as bf:
                    bf.write("\n\n".join(bib_chunks) + "\n")

            with open(os.path.join(temp_dir, "gold.jsonl"), "w", encoding="utf-8") as gf:
                for row in gold_rows:
                    gf.write(json.dumps(row) + "\n")

            plan_path = os.path.join(temp_dir, "plan.json")
            with open(plan_path, "w", encoding="utf-8") as pf:
                json.dump(verdict_plan, pf)

            fake_cli = os.path.join(temp_dir, "fake-scholaros")
            with open(fake_cli, "w", encoding="utf-8") as cf:
                cf.write(
                    f"""#!{sys.executable}
import json, re, sys
args = sys.argv[1:]
bib_path = [a for a in args if not a.startswith("-") and a != "verify-citations"][0]
with open({plan_path!r}, encoding="utf-8") as pf:
    plan = json.load(pf)
with open(bib_path, encoding="utf-8") as bf:
    keys = re.findall(r"@\\w+\\{{\\s*([^,\\s]+)\\s*,", bf.read())
verdicts = [plan[k] for k in keys]
counts = {{c: sum(1 for v in verdicts if v["firewallClass"] == c) for c in ("VERIFIED", "DRIFT", "NOT_FOUND", "RETRACTED", "UNVERIFIED")}}
sys.stdout.write(json.dumps({{
    "mode": "REPLAY",
    "replay": True,
    "generatedAtISO8601": "2026-11-16T00:00:00Z",
    "complete": counts["UNVERIFIED"] == 0,
    "totalEvaluated": len(verdicts),
    "verifiedCount": counts["VERIFIED"],
    "driftCount": counts["DRIFT"],
    "notFoundCount": counts["NOT_FOUND"],
    "retractedCount": counts["RETRACTED"],
    "unverifiedCount": counts["UNVERIFIED"],
    "unverifiedByReason": {{"no_match_in_search": counts["UNVERIFIED"]}} if counts["UNVERIFIED"] else {{}},
    "verdicts": verdicts,
}}))
sys.exit(0)
"""
                )
            os.chmod(fake_cli, os.stat(fake_cli).st_mode | stat.S_IXUSR)

            out_json = os.path.join(temp_dir, "stage12_report.json")
            stdout_buf = io.StringIO()
            old_bin = os.environ.get("SCHOLAR_CLI_BIN")
            try:
                os.environ["SCHOLAR_CLI_BIN"] = fake_cli
                with contextlib.redirect_stdout(stdout_buf):
                    rc = mod.main(["--replay", "--bench-dir", temp_dir, "--output", out_json])
            finally:
                if old_bin is None:
                    os.environ.pop("SCHOLAR_CLI_BIN", None)
                else:
                    os.environ["SCHOLAR_CLI_BIN"] = old_bin

            self.assertEqual(rc, 0)
            stdout_text = stdout_buf.getvalue()
            with open(out_json, encoding="utf-8") as rf:
                rep = json.load(rf)

            # 1. Per-group count of VERIFIED with venue hint
            self.assertEqual(rep["per_group"]["real_human"]["verified_with_venue_hint_count"], 3)
            self.assertEqual(rep["per_group"]["audit_manual"]["verified_with_venue_hint_count"], 1)
            self.assertEqual(rep["per_group"]["real_clean"]["verified_with_venue_hint_count"], 0)
            self.assertEqual(rep["overall_metrics"]["verified_with_venue_hint_count"], 4)

            # 2. Entry-by-entry non-VERIFIED list among truth == 'real' in (real_clean, real_human, real_typo):
            # Must contain ONLY real_human_001, real_human_002, and real_typo_006 (NOT the 5 mutated real_typo_001..005!)
            non_ver = rep["real_three_non_verified_entries"]
            self.assertEqual(
                [(item["key"], item["verdict"], item["reasons"]) for item in non_ver],
                [
                    ("real_human_001", "DRIFT", ["year_diff_1", "venue_mismatch"]),
                    ("real_human_002", "UNVERIFIED", ["no_match_in_search"]),
                    ("real_typo_006", "DRIFT", ["year_diff_1"]),
                ],
            )
            row7_non_ver = rep["provisional_thresholds"]["row7_real_verified_rates"]["real_three_non_verified_entries"]
            self.assertEqual(row7_non_ver, non_ver)

            # Both additions must also appear in human-readable stdout
            self.assertIn("real_human_001", stdout_text)
            self.assertIn("real_human_002", stdout_text)
            self.assertIn("real_typo_006", stdout_text)
            self.assertNotIn("real_typo_001", stdout_text)
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
