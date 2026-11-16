#!/usr/bin/env bash
#
# M2 acceptance verification script (`Scripts/acceptance/m2-acceptance.sh`).
#
# Stage 01 scope:
#   - Row 1: 11 arXiv CC BY 4.0 manuscripts — `citations[].key` and `labels[].key` sets vs `expected.json`
#   - Row 2: 11 manuscripts — `category == "structure"` ERROR diagnostics vs `expected.json` LaTeX/BibTeX logs
#   - Row 3 (determinism part): 11 manuscripts run twice (`--offline --json` and `--offline` text) — byte-for-byte identical
#   - Rows 4..20: marked `SKIP (没跑)` for subsequent M2 stages
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
    # Rows 4..20: Deferred to subsequent M2 stages (marked 没跑 / SKIPPED)
    # ==================================================================
    declare -a DEFERRED_ROWS=(
        "4:2506.06594v1 (thebibliography, 32 \\bibitem) 解析与 gold 对照 — 留给第 6 段"
        "5:2405.13682v5 (\\input{main.bbl}, 46 条) — 留给第 2、6 段"
        "6:9 篇 .bib 条目数对照 bibtex-entry-counts.tsv 与 CITE_KEY_CASE — 留给第 4、5 段"
        "7:难例 hard-inputs/hard.tex 与逐写法无损用例 — 留给第 3 段"
        "8:多文件包含图 (\\include/\\input/\\subfile/\\import/子文件 \\bibliography) — 留给第 2 段"
        "9:缺失文件、缺失 .bib 与同名 .bbl 回退 (BIB_FROM_BBL) — 留给第 2、6 段"
        "10:坏 .bib 恢复 (bib-recovery/ten.bib, BIB001) — 留给第 5 段"
        "11:BibTeX 字段继承与规范化 (and others, crossref, howpublished) — 留给第 5 段"
        "12:引用/交叉引用命令表、可选参数、双空格标签、AST 假错误与 Latin-1 — 留给第 2、4 段"
        "13:引用核查按唯一键汇总 (ERR_UNVERIFIED_CITATION) 与结构诊断分离 — 留给第 7 段"
        "14:带 x-firewall-class={VERIFIED} 的编造 DOI 在 diagnostics --registry-replay 下拦截与新退出码 — 留给第 7 段"
        "15:MCP scholar_lsp_diagnostics 支持 path 参数并与 CLI --json 逐字节相同 — 留给第 7 段"
        "16:M1 全量回放不退步、禁网单元测试与 milestone 1 — 留给第 5、8 段"
        "17:源码变异检查 (a)-(e) — 留给第 8 段"
        "18:禁网沙箱 milestone 2 与 m2-acceptance.sh / hard-inputs.sh 耗时 — 留给第 8 段"
        "19:调度方 Tectonic m2-regen-expected.sh --check — 调度方专用，测试不调用"
        "20:跑后环境与工作区洁净检查 — 留给第 8 段"
    )

    for entry in "${DEFERRED_ROWS[@]}"; do
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
