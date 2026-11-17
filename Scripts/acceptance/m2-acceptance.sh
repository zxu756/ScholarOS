#!/usr/bin/env bash
#
# M2 acceptance verification script (`Scripts/acceptance/m2-acceptance.sh`).
#
# Stage 01–03 scope:
#   - Row 1: 11 arXiv CC BY 4.0 manuscripts — `citations[].key` and `labels[].key` sets vs `expected.json`
#   - Row 2: 11 manuscripts — `category == "structure"` ERROR diagnostics vs `expected.json` LaTeX/BibTeX logs
#   - Row 3 (determinism part): 11 manuscripts run twice (`--offline --json` and `--offline` text) — byte-for-byte identical
#   - Row 7: Hard inputs (`hard-inputs/hard.tex` vs `expected/hard-inputs.json` + all per-syntax `verbatim-skip` fixtures)
#   - Row 8: Multi-file include graph (`\include`, `\input`, unbraced `\input`, `\InputIfFileExists`, `\subfile`, `\import`, `\subimport`, child `\bibliography`, commented/verbatim skip)
#   - Row 9: Missing include/bib (`INC002` with file & line) and `<main>.bbl` fallback (`BIB_FROM_BBL`, `.bbl` entry parsing deferred to Stage 06)
#   - Row 12 (encoding part): Latin-1 / Windows-1252 root and child files (`ENC001`, content extracted, exit != 2; command/parser checks deferred to Stage 04)
#   - Remaining rows: marked `SKIP (没跑)` for subsequent M2 stages
#
# All runs are strictly `--offline` under an isolated `HOME` / `CFFIXED_USER_HOME` (`lib-cli-guard.sh`).
# Tectonic and `m2-regen-expected.sh` are never invoked here.
#
# Usage:
#   Scripts/acceptance/m2-acceptance.sh [--record] [--row <1..20>]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

RECORD=0
ONLY_ROW=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --record)
            RECORD=1
            shift
            ;;
        --row)
            if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ || "$2" -lt 1 || "$2" -gt 20 ]]; then
                echo "Usage: Scripts/acceptance/m2-acceptance.sh [--record] [--row <1..20>]" >&2
                exit 2
            fi
            ONLY_ROW="$2"
            shift 2
            ;;
        --row=*)
            val="${1#--row=}"
            if [[ ! "$val" =~ ^[0-9]+$ || "$val" -lt 1 || "$val" -gt 20 ]]; then
                echo "Usage: Scripts/acceptance/m2-acceptance.sh [--record] [--row <1..20>]" >&2
                exit 2
            fi
            ONLY_ROW="$val"
            shift
            ;;
        *)
            echo "Usage: Scripts/acceptance/m2-acceptance.sh [--record] [--row <1..20>]" >&2
            exit 2
            ;;
    esac
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m2-work.XXXXXX")"
WORK_SCRATCH="$WORK/scratch"
mkdir -p "$WORK_SCRATCH"
CREATED_TEMP_REPORT_DIR=""

cleanup() {
    rm -rf "$WORK"
    if [[ -n "$CREATED_TEMP_REPORT_DIR" && -d "$CREATED_TEMP_REPORT_DIR" ]]; then
        rm -rf "$CREATED_TEMP_REPORT_DIR"
    fi
}
trap cleanup EXIT

if [[ -n "${SCHOLAR_REPORT_DIR:-}" ]]; then
    REPORT_DIR="$SCHOLAR_REPORT_DIR"
elif [[ "$RECORD" -eq 1 ]]; then
    REPORT_DIR="$REPO_ROOT/reports"
else
    CREATED_TEMP_REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m2-report.XXXXXX")"
    REPORT_DIR="$CREATED_TEMP_REPORT_DIR"
fi
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/m2-acceptance.txt"

export SCHOLAR_SANDBOX_HOME="$WORK/home"
mkdir -p "$SCHOLAR_SANDBOX_HOME"
unset SCHOLAR_CACHE_DIR

# shellcheck source=Scripts/acceptance/lib-cli-guard.sh
source "$REPO_ROOT/Scripts/acceptance/lib-cli-guard.sh"

if [[ -z "${SCHOLAR_CLI_BIN:-}" ]]; then
    export SCHOLAR_CLI_BIN="$REPO_ROOT/.build/debug/ScholarOS"
    swift build >/dev/null
elif [[ ! -x "$SCHOLAR_CLI_BIN" ]]; then
    echo "FAIL: SCHOLAR_CLI_BIN is not an executable file: $SCHOLAR_CLI_BIN" >&2
    exit 2
fi

should_run_row() {
    local r="$1"
    if [[ -z "$ONLY_ROW" || "$ONLY_ROW" == "$r" ]]; then
        return 0
    fi
    return 1
}

SUMMARY_FILE="$WORK/row-summary.txt"
: > "$SUMMARY_FILE"
PASSED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0

record_pass() {
    local row="$1"
    local desc="$2"
    PASSED_COUNT=$((PASSED_COUNT + 1))
    printf 'Row %2d | PASS       | %s\n' "$row" "$desc" >> "$SUMMARY_FILE"
    echo "RESULT [Row $row]: PASS — $desc"
    echo ""
}

record_fail() {
    local row="$1"
    local desc="$2"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    printf 'Row %2d | FAIL       | %s\n' "$row" "$desc" >> "$SUMMARY_FILE"
    echo "RESULT [Row $row]: FAIL — $desc"
    echo ""
}

record_skip() {
    local row="$1"
    local desc="$2"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    printf 'Row %2d | SKIP(没跑) | %s\n' "$row" "$desc" >> "$SUMMARY_FILE"
    echo "RESULT [Row $row]: SKIP (没跑) — $desc"
    echo ""
}

RUN1_DIR="$WORK_SCRATCH/run1"
mkdir -p "$RUN1_DIR"

need_run1=0
for r in 1 2 3; do
    if should_run_row "$r"; then
        need_run1=1
    fi
done

{
    echo "# ScholarOS M2 Acceptance Verification Report"
    echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Commit: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "Binary: ${SCHOLAR_CLI_BIN#"$REPO_ROOT"/}"
    echo "Mode: --offline (isolated HOME)"
    echo ""

    if [[ "$need_run1" -eq 1 ]]; then
        echo "[setup] Running scholaros diagnostics <main_file> --offline --json across the 11 benchmark manuscripts (pass 1)..."
        python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$RUN1_DIR" <<'PY'
import csv, json, os, subprocess, sys, time

repo_root, cli_bin, sandbox_home, out_dir = sys.argv[1:5]
papers_tsv = os.path.join(repo_root, "Benchmarks", "manuscripts", "papers.tsv")

env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

with open(papers_tsv, encoding="utf-8") as f:
    rows = list(csv.DictReader(f, delimiter="\t"))

if len(rows) != 11:
    raise SystemExit(f"Expected 11 rows in papers.tsv, found {len(rows)}")

meta = []
t_start = time.monotonic()
for row in rows:
    pid = f"{row['arxiv_id']}{row['version']}"
    main_rel = row["main_file"]
    main_tex = os.path.join(repo_root, "Benchmarks", "manuscripts", pid, "src", main_rel)
    exp_json = os.path.join(repo_root, "Benchmarks", "manuscripts", pid, "expected.json")
    if not os.path.isfile(main_tex):
        raise SystemExit(f"Missing manuscript file: {main_tex}")
    if not os.path.isfile(exp_json):
        raise SystemExit(f"Missing expected.json: {exp_json}")

    t0 = time.monotonic()
    proc = subprocess.run(
        [cli_bin, "diagnostics", main_tex, "--offline", "--json", "--lang", "en"],
        env=env,
        capture_output=True,
    )
    dt = time.monotonic() - t0
    raw_path = os.path.join(out_dir, f"{pid}.json")
    err_path = os.path.join(out_dir, f"{pid}.stderr")
    with open(raw_path, "wb") as wf:
        wf.write(proc.stdout)
    with open(err_path, "wb") as ef:
        ef.write(proc.stderr)
    meta.append({
        "paper": pid,
        "main_file": main_rel,
        "template": row["template"],
        "bibliography": row["bibliography"],
        "exit_code": proc.returncode,
        "stdout_bytes": len(proc.stdout),
        "elapsed_seconds": round(dt, 4),
    })

total_s = time.monotonic() - t_start
with open(os.path.join(out_dir, "index.json"), "w", encoding="utf-8") as mf:
    json.dump({"papers": meta, "total_elapsed_seconds": round(total_s, 4)}, mf, indent=2)
print(f"[setup] Completed 11/11 manuscripts in {total_s:.3f}s")
PY
        echo ""
    fi

    # ==================================================================
    # Row 1: 11 manuscripts — citations[].key and labels[].key sets vs expected.json
    # ==================================================================
    if should_run_row 1; then
        echo "== [Row 1] 11 篇：JSON citations[].key 与 labels[].key 集合对照 expected.json =="
        set +e
        ROW1_OUT="$(python3 -I - "$REPO_ROOT" "$RUN1_DIR" <<'PY'
import json, os, sys

repo_root, run1_dir = sys.argv[1:3]
with open(os.path.join(run1_dir, "index.json"), encoding="utf-8") as f:
    papers = json.load(f)["papers"]

matched_papers = 0
for item in papers:
    pid = item["paper"]
    raw_path = os.path.join(run1_dir, f"{pid}.json")
    exp_path = os.path.join(repo_root, "Benchmarks", "manuscripts", pid, "expected.json")

    if item["exit_code"] == 2:
        print(f"  [{pid}] FAIL: CLI exited 2")
        continue

    actual = json.loads(open(raw_path, encoding="utf-8").read())
    expected = json.load(open(exp_path, encoding="utf-8"))

    act_cites = set(c["key"] for c in actual.get("citations", []))
    exp_cites = set(expected.get("cite_keys", []))

    act_labels = set(l["key"] for l in actual.get("labels", []))
    exp_labels = set(expected.get("labels", []))

    cite_ok = (act_cites == exp_cites)
    label_ok = (act_labels == exp_labels)

    if cite_ok:
        cite_msg = f"相同 ({len(act_cites)}/{len(exp_cites)})"
    else:
        only_act = sorted(act_cites - exp_cites)
        only_exp = sorted(exp_cites - act_cites)
        cite_msg = (
            f"差异 (expected={len(exp_cites)}, actual={len(act_cites)}; "
            f"only_in_scholaros={only_act}; only_in_expected={only_exp})"
        )

    if label_ok:
        label_msg = f"相同 ({len(act_labels)}/{len(exp_labels)})"
    else:
        only_act = sorted(act_labels - exp_labels)
        only_exp = sorted(exp_labels - act_labels)
        label_msg = (
            f"差异 (expected={len(exp_labels)}, actual={len(act_labels)}; "
            f"only_in_scholaros={only_act}; only_in_expected={only_exp})"
        )

    if cite_ok and label_ok:
        matched_papers += 1
    print(f"  [{pid}] cite_keys: {cite_msg} | labels: {label_msg}")

print(f"row1_exact_match_papers={matched_papers}/11")
sys.exit(0 if matched_papers == 11 else 1)
PY
)"
        ROW1_RC=$?
        set -e
        echo "$ROW1_OUT"
        if [[ "$ROW1_RC" -eq 0 ]]; then
            record_pass 1 "All 11 manuscripts match expected.json cite_keys and labels sets"
        else
            record_fail 1 "Set differences found against expected.json across the 11 manuscripts"
        fi
    fi

    # ==================================================================
    # Row 2: 11 manuscripts — structure ERROR diagnostics vs expected.json LaTeX/BibTeX logs
    # ==================================================================
    if should_run_row 2; then
        echo "== [Row 2] 11 篇：category=structure 级别=ERROR 诊断对照 expected.json (LaTeX/BibTeX 日志) =="
        set +e
        ROW2_OUT="$(python3 -I - "$REPO_ROOT" "$RUN1_DIR" <<'PY'
import collections, json, os, re, sys

repo_root, run1_dir = sys.argv[1:3]
with open(os.path.join(run1_dir, "index.json"), encoding="utf-8") as f:
    papers = json.load(f)["papers"]

re_sym003 = re.compile(r"Duplicate label '([^']*)'")
re_cite404 = re.compile(r"Cited key '([^']*)'")
re_sym004 = re.compile(r"Unresolved cross-reference '([^']*)'")

matched_papers = 0
for item in papers:
    pid = item["paper"]
    raw_path = os.path.join(run1_dir, f"{pid}.json")
    exp_path = os.path.join(repo_root, "Benchmarks", "manuscripts", pid, "expected.json")

    if item["exit_code"] == 2:
        print(f"  [{pid}] FAIL: CLI exited 2")
        continue

    actual = json.loads(open(raw_path, encoding="utf-8").read())
    expected = json.load(open(exp_path, encoding="utf-8"))

    all_diags = actual.get("diagnostics", [])
    err_diags = [d for d in all_diags if d.get("severity") == "ERROR"]
    struct_errs = [d for d in err_diags if d.get("category") == "structure"]
    cite_errs = [d for d in err_diags if d.get("category") == "citation"]
    lint_errs = [d for d in err_diags if d.get("category") == "lint"]

    sym003_keys = []
    cite404_keys = []
    sym004_keys = []
    other_struct_errs = []

    for d in struct_errs:
        code = d.get("code", "")
        msg = d.get("message", "")
        if code == "SYM003":
            m = re_sym003.search(msg)
            if m:
                sym003_keys.append(m.group(1))
            else:
                other_struct_errs.append(d)
        elif code == "CITE404":
            m = re_cite404.search(msg)
            if m:
                cite404_keys.append(m.group(1))
            else:
                other_struct_errs.append(d)
        elif code == "SYM004":
            m = re_sym004.search(msg)
            if m:
                sym004_keys.append(m.group(1))
            else:
                other_struct_errs.append(d)
        else:
            other_struct_errs.append(d)

    latex_log = expected.get("latex_log", {})
    bibtex_log = expected.get("bibtex_log", {})

    exp_dup = set(latex_log.get("multiply_defined_labels", []))
    exp_undef_cite = set(latex_log.get("undefined_citations", [])) | set(bibtex_log.get("missing_entries", []))
    exp_undef_ref = set(latex_log.get("undefined_references", []))
    exp_bib_err_cnt = int(bibtex_log.get("error_messages", 0))

    act_dup_set = set(sym003_keys)
    act_cite_set = set(cite404_keys)
    act_ref_set = set(sym004_keys)

    dup_ok = (act_dup_set == exp_dup and len(sym003_keys) == len(exp_dup))
    cite_ok = (act_cite_set == exp_undef_cite and (len(cite404_keys) == 0 if not exp_undef_cite else True))
    ref_ok = (act_ref_set == exp_undef_ref and (len(sym004_keys) == 0 if not exp_undef_ref else True))
    other_ok = (len(other_struct_errs) == 0 and exp_bib_err_cnt == 0)

    struct_by_code = collections.Counter(d["code"] for d in struct_errs)
    lint_by_code = collections.Counter(d["code"] for d in lint_errs)
    cite_by_code = collections.Counter(d["code"] for d in cite_errs)

    cat_summary = (
        f"ERROR总计={len(err_diags)} "
        f"[structure={len(struct_errs)}"
        + (f" ({', '.join(f'{k}:{struct_by_code[k]}' for k in sorted(struct_by_code))})" if struct_by_code else "")
        + f", citation={len(cite_errs)}"
        + (f" ({', '.join(f'{k}:{cite_by_code[k]}' for k in sorted(cite_by_code))})" if cite_by_code else "")
        + f", lint={len(lint_errs)}"
        + (f" ({', '.join(f'{k}:{lint_by_code[k]}' for k in sorted(lint_by_code))})" if lint_by_code else "")
        + "]"
    )

    if dup_ok and cite_ok and ref_ok and other_ok:
        matched_papers += 1
        exp_desc = f"SYM003={sorted(exp_dup)}" if exp_dup else "0 条结构类 ERROR"
        print(f"  [{pid}] 相同 ({exp_desc}) | {cat_summary}")
    else:
        diffs = []
        if not dup_ok:
            diffs.append(f"SYM003 actual={sorted(sym003_keys)} vs expected={sorted(exp_dup)}")
        if not cite_ok:
            diffs.append(f"CITE404 count={len(cite404_keys)} unique={len(act_cite_set)} vs expected={sorted(exp_undef_cite)}")
        if not ref_ok:
            diffs.append(f"SYM004 count={len(sym004_keys)} unique={len(act_ref_set)} vs expected={sorted(exp_undef_ref)}")
        if other_struct_errs:
            other_counts = collections.Counter(d["code"] for d in other_struct_errs)
            diffs.append("extra structure ERRORs: " + ", ".join(f"{k}={other_counts[k]}" for k in sorted(other_counts)))
        print(f"  [{pid}] 差异 ({'; '.join(diffs)}) | {cat_summary}")

print(f"row2_matching_papers={matched_papers}/11")
sys.exit(0 if matched_papers == 11 else 1)
PY
)"
        ROW2_RC=$?
        set -e
        echo "$ROW2_OUT"
        if [[ "$ROW2_RC" -eq 0 ]]; then
            record_pass 2 "All 11 manuscripts match expected.json LaTeX/BibTeX log errors with zero false structure ERRORs"
        else
            record_fail 2 "Structure ERROR diagnostics diverge from expected.json LaTeX/BibTeX logs"
        fi
    fi

    # ==================================================================
    # Row 3 (Stage 01 determinism part): Run all 11 twice (JSON & text) — byte-for-byte identical
    # ==================================================================
    if should_run_row 3; then
        echo "== [Row 3] 11 篇重复运行（JSON 与文本各两次）：标准输出逐字节相同（退出码规则留给第 7 段） =="
        set +e
        ROW3_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$RUN1_DIR" <<'PY'
import json, os, subprocess, sys

repo_root, cli_bin, sandbox_home, run1_dir = sys.argv[1:5]
with open(os.path.join(run1_dir, "index.json"), encoding="utf-8") as f:
    papers = json.load(f)["papers"]

env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

ok_count = 0
for item in papers:
    pid = item["paper"]
    main_tex = os.path.join(repo_root, "Benchmarks", "manuscripts", pid, "src", item["main_file"])
    run1_bytes = open(os.path.join(run1_dir, f"{pid}.json"), "rb").read()
    run1_rc = item["exit_code"]

    p_json2 = subprocess.run(
        [cli_bin, "diagnostics", main_tex, "--offline", "--json", "--lang", "en"],
        env=env,
        capture_output=True,
    )
    p_txt1 = subprocess.run(
        [cli_bin, "diagnostics", main_tex, "--offline", "--lang", "en"],
        env=env,
        capture_output=True,
    )
    p_txt2 = subprocess.run(
        [cli_bin, "diagnostics", main_tex, "--offline", "--lang", "en"],
        env=env,
        capture_output=True,
    )

    json_obj = json.loads(run1_bytes.decode("utf-8"))
    has_random_id = any("id" in d for d in json_obj.get("diagnostics", []))
    json_same = (run1_bytes == p_json2.stdout) and (run1_rc == p_json2.returncode) and (run1_rc != 2) and (not has_random_id)
    txt_same = (p_txt1.stdout == p_txt2.stdout) and (p_txt1.returncode == p_txt2.returncode) and (p_txt1.returncode != 2)

    if json_same and txt_same:
        ok_count += 1
        print(
            f"  [{pid}] 两次相同 (json_bytes={len(run1_bytes)}, text_bytes={len(p_txt1.stdout)}, "
            f"observed_exit={run1_rc})"
        )
    else:
        print(
            f"  [{pid}] 差异 (json_same={json_same} [{len(run1_bytes)} vs {len(p_json2.stdout)}], "
            f"text_same={txt_same} [{len(p_txt1.stdout)} vs {len(p_txt2.stdout)}], "
            f"has_id={has_random_id}, exits={run1_rc}/{p_json2.returncode}/{p_txt1.returncode}/{p_txt2.returncode})"
        )

print(f"row3_deterministic_papers={ok_count}/11 (note: exit code 0/1/3/2 assertion deferred to Stage 07)")
sys.exit(0 if ok_count == 11 else 1)
PY
)"
        ROW3_RC=$?
        set -e
        echo "$ROW3_OUT"
        if [[ "$ROW3_RC" -eq 0 ]]; then
            record_pass 3 "All 11 manuscripts produce byte-identical JSON and text stdout across repeated --offline runs"
        else
            record_fail 3 "Non-deterministic output or CLI error detected across repeated runs"
        fi
    fi

    # ==================================================================
    # Rows 4..6: Deferred to subsequent M2 stages
    # ==================================================================
    declare -a DEFERRED_ROWS_4_6=(
        "4:2506.06594v1 (thebibliography, 32 \\bibitem) 解析与 gold 对照 — 留给第 6 段"
        "5:2405.13682v5 (\\input{main.bbl}, 46 条) — 留给第 6 段"
        "6:9 篇 .bib 条目数对照 bibtex-entry-counts.tsv 与 CITE_KEY_CASE — 留给第 4、5 段"
    )
    for entry in "${DEFERRED_ROWS_4_6[@]}"; do
        r_num="${entry%%:*}"
        r_desc="${entry#*:}"
        if should_run_row "$r_num"; then
            echo "== [Row $r_num] $r_desc =="
            echo "没跑 — $r_desc"
            record_skip "$r_num" "$r_desc"
        fi
    done

    # ==================================================================
    # Row 7: Hard inputs (`hard-inputs/hard.tex`) & all per-syntax `verbatim-skip` fixtures
    # ==================================================================
    if should_run_row 7; then
        echo "== [Row 7] 难例 hard-inputs/hard.tex 对照 expected/hard-inputs.json 及逐写法小用例 (verbatim-skip) =="
        set +e
        ROW7_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" <<'PY'
import collections, glob, json, os, subprocess, sys

repo_root, cli_bin, sandbox_home = sys.argv[1:4]
env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

failures = []

def run_diag(tex_path):
    proc = subprocess.run([cli_bin, "diagnostics", tex_path, "--offline", "--json", "--lang", "en"], env=env, capture_output=True)
    if proc.returncode == 2:
        raise RuntimeError(f"CLI exited 2 on {tex_path}: {proc.stderr.decode('utf-8', 'replace')}")
    return json.loads(proc.stdout.decode("utf-8"))

# 7A. Tectonic-verified hard-inputs/hard.tex vs expected/hard-inputs.json
hard_tex = os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "hard-inputs", "hard.tex")
hard_exp = json.load(open(os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "expected", "hard-inputs.json"), encoding="utf-8"))

try:
    hard_obj = run_diag(hard_tex)
    act_cites = set(c["key"] for c in hard_obj.get("citations", []))
    exp_cites = set(hard_exp.get("cite_keys", []))
    act_labels = set(l["key"] for l in hard_obj.get("labels", []))
    exp_labels = set(hard_exp.get("labels", []))
    fake_cites = sorted(k for k in act_cites if k.startswith("fake"))
    fake_labels = sorted(k for k in act_labels if k.startswith("fake"))
    struct_errs = [
        d for d in hard_obj.get("diagnostics", [])
        if d.get("category") == "structure" and d.get("severity") == "ERROR"
    ]
    by_code = collections.Counter(d["code"] for d in struct_errs)
    code_desc = ", ".join(f"{k}={by_code[k]}" for k in sorted(by_code)) if by_code else "0"
    print(
        f"  [hard.tex] cite_keys={sorted(act_cites)} (expected={sorted(exp_cites)}) | "
        f"labels={sorted(act_labels)} (expected={sorted(exp_labels)}) | "
        f"fake*={(fake_cites + fake_labels) or '无'} | structure_ERROR={len(struct_errs)} ({code_desc})"
    )
    if act_cites != exp_cites:
        failures.append(f"hard.tex cite_keys mismatch: actual={sorted(act_cites)} vs expected={sorted(exp_cites)}")
    if act_labels != exp_labels:
        failures.append(f"hard.tex labels mismatch: actual={sorted(act_labels)} vs expected={sorted(exp_labels)}")
    if fake_cites or fake_labels:
        failures.append(f"hard.tex leaked fake* keys: cites={fake_cites}, labels={fake_labels}")
    if len(struct_errs) != 0:
        failures.append(f"hard.tex expected 0 structure ERRORs, got {len(struct_errs)} ({code_desc})")
except Exception as exc:
    failures.append(str(exc))

# 7B. All per-syntax small fixtures in Tests/Fixtures/manuscripts/verbatim-skip/*.expected.json
skip_dir = os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "verbatim-skip")
exp_files = sorted(glob.glob(os.path.join(skip_dir, "*.expected.json")))
if len(exp_files) < 19:
    failures.append(f"Expected at least 19 per-syntax expected files in {skip_dir}, found {len(exp_files)}")

passed_small = 0
for exp_path in exp_files:
    spec = json.load(open(exp_path, encoding="utf-8"))
    slug = spec["case"]
    tex_path = os.path.join(skip_dir, f"{slug}.tex")
    exp_c = set(spec["cite_keys"])
    exp_l = set(spec["labels"])
    exp_se = int(spec["structure_errors"])
    try:
        obj = run_diag(tex_path)
        act_c = set(c["key"] for c in obj.get("citations", []))
        act_l = set(l["key"] for l in obj.get("labels", []))
        fakes = sorted([k for k in act_c if k.startswith("fake")] + [k for k in act_l if k.startswith("fake")])
        se = [
            d for d in obj.get("diagnostics", [])
            if d.get("category") == "structure" and d.get("severity") == "ERROR"
        ]
        case_ok = (act_c == exp_c) and (act_l == exp_l) and (not fakes) and (len(se) == exp_se)
        if case_ok:
            passed_small += 1
            print(f"  [{slug}] PASS (cites={sorted(act_c)}, labels={sorted(act_l)}, structure_ERROR={len(se)})")
        else:
            failures.append(
                f"{slug} mismatch: cites={sorted(act_c)}/{sorted(exp_c)}, "
                f"labels={sorted(act_l)}/{sorted(exp_l)}, fakes={fakes}, structure_ERROR={len(se)}/{exp_se}"
            )
            print(f"  [{slug}] FAIL (cites={sorted(act_c)}, labels={sorted(act_l)}, fakes={fakes}, structure_ERROR={len(se)})")
    except Exception as exc:
        failures.append(f"{slug}: {exc}")

print(f"row7_per_syntax_fixtures={passed_small}/{len(exp_files)}")
if failures:
    for msg in failures:
        print(f"  FAIL: {msg}")
    sys.exit(1)
sys.exit(0)
PY
)"
        ROW7_RC=$?
        set -e
        echo "$ROW7_OUT"
        if [[ "$ROW7_RC" -eq 0 ]]; then
            record_pass 7 "hard-inputs/hard.tex and all per-syntax verbatim-skip fixtures match expected sets with 0 fake* leaks and 0 structure ERRORs"
        else
            record_fail 7 "hard-inputs/hard.tex or per-syntax verbatim-skip fixtures diverged from expected sets or structure ERROR count"
        fi
    fi

    # ==================================================================
    # Row 8: Multi-file include graph & child bibliography discovery
    # ==================================================================
    if should_run_row 8; then
        echo "== [Row 8] 多文件包含图：\\include、\\input、不带花括号 \\input、\\InputIfFileExists、\\subfile、\\import、\\subimport、子文件 \\bibliography、注释与逐字环境跳过 =="
        set +e
        ROW8_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" <<'PY'
import json, os, subprocess, sys

repo_root, cli_bin, sandbox_home = sys.argv[1:4]
env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

failures = []

# 8A. Tectonic-verified include-multi fixture (`Tests/Fixtures/manuscripts/include-multi/main.tex`)
inc_tex = os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "include-multi", "main.tex")
inc_exp = json.load(open(os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "expected", "include-multi.json"), encoding="utf-8"))

p_inc = subprocess.run([cli_bin, "diagnostics", inc_tex, "--offline", "--json", "--lang", "en"], env=env, capture_output=True)
if p_inc.returncode == 2:
    failures.append(f"include-multi exited 2: {p_inc.stderr.decode('utf-8', 'replace')}")
else:
    obj_inc = json.loads(p_inc.stdout.decode("utf-8"))
    files_inc = [f["path"] for f in obj_inc.get("files", [])]
    exp_files_inc = ["main.tex", "chapters/one.tex", "chapters/two.tex", "chapters/shared.tex"]
    cites_inc = sorted(c["key"] for c in obj_inc.get("citations", []))
    labels_inc = sorted(l["key"] for l in obj_inc.get("labels", []))
    inc002_inc = [d for d in obj_inc.get("diagnostics", []) if d.get("code") == "INC002"]
    cite404_inc = [d for d in obj_inc.get("diagnostics", []) if d.get("code") == "CITE404"]
    bib_inc = [b["path"] for b in obj_inc.get("bibliographySources", [])]
    print(f"  [include-multi] files={files_inc} bib={bib_inc} cites={cites_inc} labels={labels_inc} INC002={len(inc002_inc)} CITE404={len(cite404_inc)}")
    if files_inc != exp_files_inc:
        failures.append(f"include-multi files mismatch: {files_inc} != {exp_files_inc}")
    if bib_inc != ["refs.bib"]:
        failures.append(f"include-multi bib mismatch: {bib_inc}")
    if set(cites_inc) != set(inc_exp["cite_keys"]):
        failures.append(f"include-multi cite_keys mismatch: {cites_inc} vs {inc_exp['cite_keys']}")
    if set(labels_inc) != set(inc_exp["labels"]):
        failures.append(f"include-multi labels mismatch: {labels_inc} vs {inc_exp['labels']}")
    if inc002_inc or cite404_inc:
        failures.append(f"include-multi unexpected INC002={inc002_inc} CITE404={cite404_inc}")

# 8B. All 7 include syntaxes + child \bibliography/\addbibresource + commented existing file + verbatim skip (`loader-multi`)
multi_dir = os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "loader-multi")
multi_tex = os.path.join(multi_dir, "main.tex")
commented_file = os.path.join(multi_dir, "sections", "commented_out.tex")
if not os.path.isfile(commented_file):
    failures.append(f"Expected commented target file to exist on disk: {commented_file}")

p_multi = subprocess.run([cli_bin, "diagnostics", multi_tex, "--offline", "--json", "--lang", "en"], env=env, capture_output=True)
p_outline = subprocess.run([cli_bin, "outline", multi_tex, "--json", "--lang", "en"], env=env, capture_output=True)

if p_multi.returncode == 2 or p_outline.returncode != 0:
    failures.append(f"loader-multi CLI error: diag_rc={p_multi.returncode}, outline_rc={p_outline.returncode}")
else:
    obj_m = json.loads(p_multi.stdout.decode("utf-8"))
    outline_m = json.loads(p_outline.stdout.decode("utf-8"))
    files_m = [f["path"] for f in obj_m.get("files", [])]
    exp_files_m = [
        "main.tex",
        "chapters/ch_one.tex",
        "chapters/ch_two.tex",
        "sections/braced_input.tex",
        "sections/unbraced_input.tex",
        "sections/if_exists.tex",
        "sections/sub_doc.tex",
        "modules/mod_a/entry.tex",
        "modules/mod_a/nested/leaf.tex",
        "snippets/exact_name.inc",
    ]
    bib_m = [b["path"] for b in obj_m.get("bibliographySources", [])]
    exp_bib_m = ["refs_main.bib", "refs_extra.bib", "refs_biblatex.bib"]
    cites_m = sorted(c["key"] for c in obj_m.get("citations", []))
    exp_cites_m = ["k_biblatex", "k_extra", "k_leaf", "k_one", "k_sub", "k_two"]
    all_defined_m = all(c.get("defined") is True for c in obj_m.get("citations", []))
    labels_m = sorted(l["key"] for l in obj_m.get("labels", []))
    exp_labels_m = [
        "ch:m_one", "ch:m_two", "sec:braced", "sec:exact",
        "sec:ifexists", "sec:imported", "sec:subfile", "sec:subimported", "sec:unbraced"
    ]
    inc002_m = [d for d in obj_m.get("diagnostics", []) if d.get("code") == "INC002"]
    cite404_m = [d for d in obj_m.get("diagnostics", []) if d.get("code") == "CITE404"]
    outline_titles = [e.get("title") for e in outline_m]

    print(f"  [loader-multi] files={len(files_m)}/10 (commented_out excluded={'sections/commented_out.tex' not in files_m}) bib={bib_m} cites={cites_m} labels={len(labels_m)}/9 INC002={len(inc002_m)} outline_entries={len(outline_titles)}")
    if files_m != exp_files_m:
        failures.append(f"loader-multi files mismatch: {files_m} != {exp_files_m}")
    if bib_m != exp_bib_m:
        failures.append(f"loader-multi bibliographySources mismatch: {bib_m} != {exp_bib_m}")
    if cites_m != exp_cites_m or not all_defined_m:
        failures.append(f"loader-multi citations mismatch: {cites_m} defined={all_defined_m}")
    if labels_m != exp_labels_m:
        failures.append(f"loader-multi labels mismatch: {labels_m} != {exp_labels_m}")
    if inc002_m or cite404_m:
        failures.append(f"loader-multi unexpected INC002={inc002_m} CITE404={cite404_m}")
    for required_title in ["Unbraced Input", "IfExists Input", "Subfile Section", "Imported Entry", "Subimported Leaf", "Exact Extension Snippet"]:
        if required_title not in outline_titles:
            failures.append(f"loader-multi outline missing section '{required_title}': {outline_titles}")
    if "Commented Out" in outline_titles:
        failures.append("loader-multi outline unexpectedly included commented-out file")

if failures:
    for msg in failures:
        print(f"  FAIL: {msg}")
    sys.exit(1)
sys.exit(0)
PY
)"
        ROW8_RC=$?
        set -e
        echo "$ROW8_OUT"
        if [[ "$ROW8_RC" -eq 0 ]]; then
            record_pass 8 "Multi-file include syntaxes, child bibliography discovery, commented/verbatim skip, and Tectonic .aux comparison match with 0 INC002"
        else
            record_fail 8 "Multi-file include resolution or bibliography discovery diverged from expected sets"
        fi
    fi

    # ==================================================================
    # Row 9: Missing file / missing .bib INC002 & main .bbl fallback (BIB_FROM_BBL)
    # ==================================================================
    if should_run_row 9; then
        echo "== [Row 9] 缺失文件与缺失 .bib (INC002 带文件与行号) 及同名 .bbl 回退 (BIB_FROM_BBL；.bbl 条目解析留给第 6 段) =="
        set +e
        ROW9_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" <<'PY'
import json, os, subprocess, sys

repo_root, cli_bin, sandbox_home = sys.argv[1:4]
env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

base = os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "loader-missing")
failures = []

def run_diag(tex_path):
    proc = subprocess.run([cli_bin, "diagnostics", tex_path, "--offline", "--json", "--lang", "en"], env=env, capture_output=True)
    if proc.returncode == 2:
        raise RuntimeError(f"CLI exited 2 on {tex_path}: {proc.stderr.decode('utf-8', 'replace')}")
    return json.loads(proc.stdout.decode("utf-8"))

# 9A. Root `\input{nothere}` at main.tex:4
obj_root_in = run_diag(os.path.join(base, "missing-input-root", "main.tex"))
inc_root = [d for d in obj_root_in.get("diagnostics", []) if d.get("code") == "INC002"]
print(f"  [missing-input-root] INC002={[(d['severity'], d['file'], d['line']) for d in inc_root]}")
if len(inc_root) != 1 or inc_root[0].get("severity") != "ERROR" or inc_root[0].get("file") != "main.tex" or inc_root[0].get("line") != 4:
    failures.append(f"missing-input-root expected 1 ERROR INC002 at main.tex:4, got {inc_root}")

# 9B. Child `\input{nothere}` at sections/intro.tex:3
obj_child_in = run_diag(os.path.join(base, "missing-input", "main.tex"))
inc_child = [d for d in obj_child_in.get("diagnostics", []) if d.get("code") == "INC002"]
print(f"  [missing-input-child] INC002={[(d['severity'], d['file'], d['line']) for d in inc_child]}")
if len(inc_child) != 1 or inc_child[0].get("severity") != "ERROR" or inc_child[0].get("file") != "sections/intro.tex" or inc_child[0].get("line") != 3:
    failures.append(f"missing-input-child expected 1 ERROR INC002 at sections/intro.tex:3, got {inc_child}")

# 9C. Missing `\bibliography{nothere}` without `.bbl` at main.tex:5
obj_miss_bib = run_diag(os.path.join(base, "missing-bib", "main.tex"))
inc_bib = [d for d in obj_miss_bib.get("diagnostics", []) if d.get("code") == "INC002"]
print(f"  [missing-bib-no-bbl] INC002={[(d['severity'], d['file'], d['line']) for d in inc_bib]}")
if len(inc_bib) != 1 or inc_bib[0].get("severity") != "ERROR" or inc_bib[0].get("file") != "main.tex" or inc_bib[0].get("line") != 5:
    failures.append(f"missing-bib expected 1 ERROR INC002 at main.tex:5, got {inc_bib}")

# 9D. Missing `\bibliography{custom}` with matching `acl_latex.bbl` -> 0 INC002, 1 INFO BIB_FROM_BBL, bibliographySources has bbl
obj_bbl = run_diag(os.path.join(base, "bbl-fallback", "acl_latex.tex"))
inc_bbl = [d for d in obj_bbl.get("diagnostics", []) if d.get("code") == "INC002"]
info_bbl = [d for d in obj_bbl.get("diagnostics", []) if d.get("code") == "BIB_FROM_BBL"]
bib_srcs = obj_bbl.get("bibliographySources", [])
print(
    f"  [bbl-fallback] INC002={len(inc_bbl)} BIB_FROM_BBL={[(d['severity'], d['file'], d['line']) for d in info_bbl]} "
    f"bibliographySources={[(s['kind'], s['path']) for s in bib_srcs]} "
    "(note: .bbl \\bibitem entry definition check deferred to Stage 06)"
)
if inc_bbl:
    failures.append(f"bbl-fallback emitted unexpected INC002: {inc_bbl}")
if len(info_bbl) != 1 or info_bbl[0].get("severity") != "INFO" or info_bbl[0].get("file") != "acl_latex.tex" or info_bbl[0].get("line") != 6:
    failures.append(f"bbl-fallback expected 1 INFO BIB_FROM_BBL at acl_latex.tex:6, got {info_bbl}")
if len(bib_srcs) != 1 or bib_srcs[0].get("kind") != "bbl" or bib_srcs[0].get("path") != "acl_latex.bbl":
    failures.append(f"bbl-fallback expected bibliographySources=[{{kind:'bbl', path:'acl_latex.bbl'}}], got {bib_srcs}")

if failures:
    for msg in failures:
        print(f"  FAIL: {msg}")
    sys.exit(1)
sys.exit(0)
PY
)"
        ROW9_RC=$?
        set -e
        echo "$ROW9_OUT"
        if [[ "$ROW9_RC" -eq 0 ]]; then
            record_pass 9 "Missing include/bib emit exact ERROR INC002 (file & line), and matching <main>.bbl emits INFO BIB_FROM_BBL with 0 INC002"
        else
            record_fail 9 "Missing-file INC002 or BIB_FROM_BBL fallback check failed"
        fi
    fi

    # ==================================================================
    # Rows 10..11: Deferred to Stage 05
    # ==================================================================
    declare -a DEFERRED_ROWS_10_11=(
        "10:坏 .bib 恢复 (bib-recovery/ten.bib, BIB001) — 留给第 5 段"
        "11:BibTeX 字段继承与规范化 (and others, crossref, howpublished) — 留给第 5 段"
    )
    for entry in "${DEFERRED_ROWS_10_11[@]}"; do
        r_num="${entry%%:*}"
        r_desc="${entry#*:}"
        if should_run_row "$r_num"; then
            echo "== [Row $r_num] $r_desc =="
            echo "没跑 — $r_desc"
            record_skip "$r_num" "$r_desc"
        fi
    done

    # ==================================================================
    # Row 12 (Stage 02 encoding part): Latin-1 / Windows-1252 root & child files (ENC001)
    # ==================================================================
    if should_run_row 12; then
        echo "== [Row 12] Latin-1 / Windows-1252 主文件与子文件读取及 ENC001 警告（S64/S65/S66/S67 命令表与解析器部分留给第 4 段） =="
        set +e
        ROW12_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" <<'PY'
import json, os, subprocess, sys

repo_root, cli_bin, sandbox_home = sys.argv[1:4]
env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

enc_dir = os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "loader-encoding")
main_tex = os.path.join(enc_dir, "main.tex")
sub_tex = os.path.join(enc_dir, "sub.tex")
failures = []

for label, fpath in [("main.tex", main_tex), ("sub.tex", sub_tex)]:
    raw = open(fpath, "rb").read()
    try:
        raw.decode("utf-8")
        failures.append(f"{label} unexpectedly valid UTF-8 on disk")
    except UnicodeDecodeError:
        pass

p_diag = subprocess.run([cli_bin, "diagnostics", main_tex, "--offline", "--json", "--lang", "en"], env=env, capture_output=True)
p_out = subprocess.run([cli_bin, "outline", main_tex, "--json", "--lang", "en"], env=env, capture_output=True)

if p_diag.returncode == 2:
    failures.append(f"diagnostics exited 2 on Windows-1252 manuscript: {p_diag.stderr.decode('utf-8', 'replace')}")
elif p_out.returncode != 0:
    failures.append(f"outline exited {p_out.returncode} on Windows-1252 manuscript: {p_out.stderr.decode('utf-8', 'replace')}")
else:
    obj = json.loads(p_diag.stdout.decode("utf-8"))
    outline = json.loads(p_out.stdout.decode("utf-8"))
    files = [(f.get("path"), f.get("encoding"), f.get("includedFrom")) for f in obj.get("files", [])]
    exp_files = [("main.tex", "windows-1252", None), ("sub.tex", "windows-1252", "main.tex:5")]
    labels = sorted(l.get("key") for l in obj.get("labels", []))
    cites = sorted(c.get("key") for c in obj.get("citations", []))
    enc001 = [d for d in obj.get("diagnostics", []) if d.get("code") == "ENC001"]
    inc002 = [d for d in obj.get("diagnostics", []) if d.get("code") == "INC002"]
    titles = [e.get("title", "") for e in outline]

    print(
        f"  [loader-encoding] exit={p_diag.returncode} files={files} labels={labels} cites={cites} "
        f"ENC001={[(d['severity'], d['file']) for d in enc001]} titles={titles} "
        "(note: S64/S65/S66/S67 command & parser checks deferred to Stage 04)"
    )
    if files != exp_files:
        failures.append(f"files mismatch: {files} != {exp_files}")
    if labels != ["sec:gauss", "sec:poincare"]:
        failures.append(f"labels mismatch: {labels}")
    if cites != ["knuth1968", "lecun2015"]:
        failures.append(f"citations mismatch: {cites}")
    if inc002:
        failures.append(f"unexpected INC002: {inc002}")
    if len(enc001) != 2 or {d.get("file") for d in enc001} != {"main.tex", "sub.tex"}:
        failures.append(f"expected 2 ENC001 warnings for main.tex & sub.tex, got {enc001}")
    for d in enc001:
        if d.get("severity") != "WARNING" or d.get("category") != "structure" or d.get("file", "") not in d.get("message", ""):
            failures.append(f"malformed ENC001 diagnostic: {d}")
    if not any("Poincaré" in t for t in titles) or not any("Gauß" in t and "Müller" in t for t in titles):
        failures.append(f"decoded outline titles missing Latin-1 characters: {titles}")

if failures:
    for msg in failures:
        print(f"  FAIL: {msg}")
    sys.exit(1)
sys.exit(0)
PY
)"
        ROW12_RC=$?
        set -e
        echo "$ROW12_OUT"
        if [[ "$ROW12_RC" -eq 0 ]]; then
            record_pass 12 "Latin-1 / Windows-1252 root and child files decode cleanly, extract symbols/outline, emit WARNING ENC001, and do not exit 2 (S64-S67 deferred to Stage 04)"
        else
            record_fail 12 "Latin-1 / Windows-1252 encoding fallback or ENC001 check failed"
        fi
    fi

    # ==================================================================
    # Rows 13..20: Deferred to subsequent M2 stages (marked 没跑 / SKIPPED)
    # ==================================================================
    declare -a DEFERRED_ROWS_13_20=(
        "13:引用核查按唯一键汇总 (ERR_UNVERIFIED_CITATION) 与结构诊断分离 — 留给第 7 段"
        "14:带 x-firewall-class={VERIFIED} 的编造 DOI 在 diagnostics --registry-replay 下拦截与新退出码 — 留给第 7 段"
        "15:MCP scholar_lsp_diagnostics 支持 path 参数并与 CLI --json 逐字节相同 — 留给第 7 段"
        "16:M1 全量回放不退步、禁网单元测试与 milestone 1 — 留给第 5、8 段"
        "17:源码变异检查 (a)-(e) — 留给第 8 段"
        "18:禁网沙箱 milestone 2 与 m2-acceptance.sh / hard-inputs.sh 耗时 — 留给第 8 段"
        "19:调度方 Tectonic m2-regen-expected.sh --check — 调度方专用，测试不调用"
        "20:跑后环境与工作区洁净检查 — 留给第 8 段"
    )

    for entry in "${DEFERRED_ROWS_13_20[@]}"; do
        r_num="${entry%%:*}"
        r_desc="${entry#*:}"
        if should_run_row "$r_num"; then
            echo "== [Row $r_num] $r_desc =="
            echo "没跑 — $r_desc"
            record_skip "$r_num" "$r_desc"
        fi
    done

    echo "========================================================================"
    echo "M2 Acceptance Summary:"
    sed 's/^/  /' "$SUMMARY_FILE"
    echo "------------------------------------------------------------------------"
    echo "Passed: $PASSED_COUNT | Failed: $FAILED_COUNT | Skipped (没跑): $SKIPPED_COUNT"
    echo "========================================================================"
    echo "$FAILED_COUNT" > "$WORK/failed-count.txt"
} | tee "$REPORT_FILE"

if [[ -z "$CREATED_TEMP_REPORT_DIR" ]]; then
    echo "[m2-acceptance] report written to $REPORT_FILE" >&2
fi

FINAL_FAILED="$(cat "$WORK/failed-count.txt")"
if [[ "$FINAL_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
