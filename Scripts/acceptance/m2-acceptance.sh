#!/usr/bin/env bash
#
# M2 acceptance verification script (`Scripts/acceptance/m2-acceptance.sh`).
#
# Stage 01–07 scope:
#   - Row 1: 11 arXiv CC BY 4.0 manuscripts — `citations[].key` and `labels[].key` sets vs `expected.json`
#   - Row 2: 11 manuscripts — `category == "structure"` ERROR diagnostics vs `expected.json` LaTeX/BibTeX logs
#   - Row 3: 11 manuscripts exit codes (`2503.18124v1` -> `1`, remaining 10 -> `3`) and repeated runs (`--offline --json` and `--offline` text) — byte-for-byte identical
#   - Row 4: `2506.06594v1` (`thebibliography`, 32 `\bibitem` entries) vs `bibitems.gold.tsv`, DOI extraction, and M1 `UNVERIFIED` (`offline`) verdicts
#   - Row 5: `2405.13682v5` (`\input{main.bbl}`, 46 entries, `kind == "bbl"`, `0` `CITE404`, `0` `INC002`)
#   - Row 6: 9 `.bib` manuscripts unique entry counts vs `bibtex-entry-counts.tsv` (0 `BIB001`) + `2410.04196v2` `\citep{bayestune}` `CITE_KEY_CASE`
#   - Row 7: Hard inputs (`hard-inputs/hard.tex` vs `expected/hard-inputs.json` + all per-syntax `verbatim-skip` fixtures)
#   - Row 8: Multi-file include graph (`\include`, `\input`, unbraced `\input`, `\InputIfFileExists`, `\subfile`, `\import`, `\subimport`, child `\bibliography`, commented/verbatim skip)
#   - Row 9: Missing include/bib (`INC002` with file & line) and `<main>.bbl` fallback (`BIB_FROM_BBL`, `0` `INC002`, and `.bbl` entries marked `defined == true` with `0` `CITE404`)
#   - Row 10: Broken `.bib` single-entry error recovery (`bib-recovery/ten.bib`: `e3`, startLine 15, line 22, remaining 9 entries vs `.bbl`, exit codes per Settled #3)
#   - Row 11: BibTeX field normalization & inheritance (`bib-fields/refs.bib`: `and others` / `authorsTruncated`, `crossref` inheritance & parent uncited suppression, `howpublished` `\url`/`\href`, `BIB003`)
#   - Row 12: S64 citation/cross-ref command tables, S65 optional arguments, S66 normalized keys & `CITE_KEY_CASE`, S67 parser constructs (`parser-commands`), and Latin-1 / Windows-1252 root/child files (`ENC001`)
#   - Row 13: Unique-key `ERR_UNVERIFIED_CITATION` (`3` keys cited twice each under `--offline` -> `3` diagnostics, `category == "citation"`, `0` structure ERRORs, exit `3`)
#   - Row 14: Fabricated DOI with `x-firewall-class = {VERIFIED}` under `diagnostics --registry-replay` (`ERR_UNVERIFIED_CITATION`, `未采信` / `not trusted` in `findings`, exit `1`, and `m1-acceptance.sh --row 18` passes)
#   - Row 15: MCP `scholar_lsp_diagnostics` with `path` across all 11 benchmark manuscripts — byte-for-byte identical JSON to CLI `--json`
#   - Rows 16–20: marked `SKIP (没跑)` for Stage 08 / dispatcher
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
for r in 1 2 3 15; do
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
    # Row 3: 11 manuscripts exit codes (2503.18124 -> 1, remaining 10 -> 3) & repeated runs byte-for-byte identical
    # ==================================================================
    if should_run_row 3; then
        echo "== [Row 3] 11 篇退出码（2503.18124 为 1，其余 10 篇为 3）与重复运行（JSON 及文本各两次）逐字节相同 =="
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
    exp_rc = 1 if pid.startswith("2503.18124") else 3
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
    json_same = (run1_bytes == p_json2.stdout) and (not has_random_id)
    txt_same = (p_txt1.stdout == p_txt2.stdout)
    rc_ok = (
        run1_rc == exp_rc
        and p_json2.returncode == exp_rc
        and p_txt1.returncode == exp_rc
        and p_txt2.returncode == exp_rc
    )

    if json_same and txt_same and rc_ok:
        ok_count += 1
        print(
            f"  [{pid}] 两次相同且退出码符合期望 (exit={run1_rc}=={exp_rc}, "
            f"json_bytes={len(run1_bytes)}, text_bytes={len(p_txt1.stdout)})"
        )
    else:
        print(
            f"  [{pid}] 差异 (expected_exit={exp_rc}, exits={run1_rc}/{p_json2.returncode}/{p_txt1.returncode}/{p_txt2.returncode}, "
            f"json_same={json_same} [{len(run1_bytes)} vs {len(p_json2.stdout)}], "
            f"text_same={txt_same} [{len(p_txt1.stdout)} vs {len(p_txt2.stdout)}], has_id={has_random_id})"
        )

print(f"row3_passed_papers={ok_count}/11 (2503.18124v1 exit=1, remaining 10 exit=3)")
sys.exit(0 if ok_count == 11 else 1)
PY
)"
        ROW3_RC=$?
        set -e
        echo "$ROW3_OUT"
        if [[ "$ROW3_RC" -eq 0 ]]; then
            record_pass 3 "All 11 manuscripts exit with expected code (2503.18124v1 -> 1, remaining 10 -> 3) and produce byte-identical JSON and text stdout across repeated --offline runs"
        else
            record_fail 3 "Exit code mismatch or non-deterministic output detected across the 11 manuscripts"
        fi
    fi

    # ==================================================================
    # Row 4: 2506.06594v1 (`thebibliography`, 32 `\bibitem`) vs `bibitems.gold.tsv`
    # ==================================================================
    if should_run_row 4; then
        echo "== [Row 4] 2506.06594v1 (thebibliography, 32 \\bibitem) 解析、bibitems.gold.tsv 对照与 M1 UNVERIFIED (offline) 核验 =="
        set +e
        ROW4_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$RUN1_DIR" <<'PY'
import csv, json, os, subprocess, sys, unicodedata

repo_root, cli_bin, sandbox_home, run1_dir = sys.argv[1:5]
env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

def normalize_for_comparison(raw: str) -> str:
    if not raw:
        return ""
    expanded = (
        raw.replace("ß", "ss")
        .replace("ẞ", "ss")
        .replace("æ", "ae")
        .replace("Æ", "ae")
        .replace("œ", "oe")
        .replace("Œ", "oe")
        .replace("ø", "o")
        .replace("Ø", "o")
        .replace("ł", "l")
        .replace("Ł", "l")
        .replace("đ", "d")
        .replace("Đ", "d")
        .replace("ı", "i")
    )
    decomposed = unicodedata.normalize("NFKD", expanded)
    stripped = "".join(ch for ch in decomposed if not unicodedata.combining(ch)).lower()
    words = []
    current = []
    for ch in stripped:
        if ch.isalnum():
            current.append(ch)
        elif current:
            words.append("".join(current))
            current = []
    if current:
        words.append("".join(current))
    return " ".join(words)

pid = "2506.06594v1"
main_rel = "From_Adaptive_Control_Evolving_Control.tex"
cached = os.path.join(run1_dir, f"{pid}.json")
if os.path.isfile(cached):
    obj = json.load(open(cached, encoding="utf-8"))
else:
    main_tex = os.path.join(repo_root, "Benchmarks", "manuscripts", pid, "src", main_rel)
    proc = subprocess.run([cli_bin, "diagnostics", main_tex, "--offline", "--json", "--lang", "en"], env=env, capture_output=True)
    if proc.returncode == 2:
        print(f"  FAIL [Row 4]: CLI exited 2 on {pid}: {proc.stderr.decode('utf-8', 'replace')}")
        sys.exit(1)
    obj = json.loads(proc.stdout.decode("utf-8"))

failures = []

bib_srcs = obj.get("bibliographySources", [])
if len(bib_srcs) != 1:
    failures.append(f"expected 1 bibliographySources entry, got {bib_srcs}")
else:
    src0 = bib_srcs[0]
    if (
        src0.get("kind") != "thebibliography"
        or src0.get("path") != main_rel
        or src0.get("entries") != 32
        or (src0.get("errors") or []) != []
    ):
        failures.append(f"unexpected bibliographySources[0]: {src0}")

diags = obj.get("diagnostics", [])
cite404 = [d for d in diags if d.get("code") == "CITE404"]
if cite404:
    failures.append(f"expected 0 CITE404 on {pid}, got {len(cite404)}")

citations = obj.get("citations", [])
cites_by_key = {c["key"]: c for c in citations}
if len(citations) != 32:
    failures.append(f"expected 32 citations on {pid}, got {len(citations)}")

gold_tsv = os.path.join(repo_root, "Benchmarks", "manuscripts", pid, "bibitems.gold.tsv")
with open(gold_tsv, encoding="utf-8") as gf:
    gold_rows = list(csv.DictReader(gf, delimiter="\t"))

if len(gold_rows) != 32:
    failures.append(f"expected 32 gold rows in bibitems.gold.tsv, found {len(gold_rows)}")

year_ok = 0
surname_ok = 0
title_ok = 0
verified_offline_ok = 0

for row in gold_rows:
    key = row["key"]
    exp_fam = row["first_author_family"]
    exp_year = int(row["year"])
    exp_title = row["title"]
    exp_id = row.get("identifier", "") or ""

    c_rec = cites_by_key.get(key)
    if not c_rec:
        failures.append(f"missing key '{key}' in citations[]")
        continue
    if c_rec.get("defined") is not True or c_rec.get("source") != main_rel:
        failures.append(f"key '{key}' expected defined=True, source='{main_rel}', got defined={c_rec.get('defined')}, source={c_rec.get('source')}")

    ver = c_rec.get("verification")
    if isinstance(ver, dict) and ver.get("verdict") == "UNVERIFIED" and ver.get("reasons") == ["offline"]:
        verified_offline_ok += 1
    else:
        failures.append(f"key '{key}' expected verification UNVERIFIED/['offline'], got {ver}")

    ent = c_rec.get("entry") or {}
    authors = ent.get("authors") or []
    act_fam = authors[0].get("familyName", "") if authors else ""
    act_year = ent.get("year")
    act_title = ent.get("title") or ""
    act_doi = ent.get("doi")

    if act_year == exp_year:
        year_ok += 1
    if act_fam and normalize_for_comparison(act_fam) == normalize_for_comparison(exp_fam):
        surname_ok += 1
    if act_title and normalize_for_comparison(act_title) == normalize_for_comparison(exp_title):
        title_ok += 1

    if key == "annaswamy2022" or exp_id == "doi:10.48550/arXiv.2108.11336":
        if act_doi != "10.48550/arXiv.2108.11336":
            failures.append(f"annaswamy2022 expected doi='10.48550/arXiv.2108.11336', got {act_doi!r}")

if year_ok != 32:
    failures.append(f"year matches {year_ok}/32 != 32/32")
if surname_ok < 30:
    failures.append(f"first-author surname matches {surname_ok}/32 < 30/32")
if title_ok < 26:
    failures.append(f"title matches {title_ok}/32 < 26/32")

annaswamy_doi = ((cites_by_key.get("annaswamy2022") or {}).get("entry") or {}).get("doi")
print(
    f"  [2506.06594v1] bibliographySources={bib_srcs} | CITE404={len(cite404)} | "
    f"UNVERIFIED(offline)={verified_offline_ok}/32 | year={year_ok}/32 | "
    f"first_author_family={surname_ok}/32 (>=30) | title={title_ok}/32 (>=26) | "
    f"annaswamy2022_doi={annaswamy_doi}"
)

if failures:
    for f in failures:
        print(f"  FAIL [Row 4]: {f}")
    sys.exit(1)
sys.exit(0)
PY
)"
        ROW4_RC=$?
        set -e
        echo "$ROW4_OUT"
        if [[ "$ROW4_RC" -eq 0 ]]; then
            record_pass 4 "2506.06594v1 parses 1 thebibliography source (32 entries), 0 CITE404, 32/32 UNVERIFIED (offline), matches bibitems.gold.tsv (year 32/32, surname >=30/32, title >=26/32), and extracts annaswamy2022 DOI"
        else
            record_fail 4 "Row 4 2506.06594v1 thebibliography parsing, gold comparison, or M1 offline verification failed"
        fi
    fi

    # ==================================================================
    # Row 5: 2405.13682v5 (`\input{main.bbl}`, 46 entries)
    # ==================================================================
    if should_run_row 5; then
        echo "== [Row 5] 2405.13682v5 (\\input{main.bbl}, 46 条) 解析、files 包含 main.bbl、0 条 CITE404 与 0 条 INC002 =="
        set +e
        ROW5_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$RUN1_DIR" <<'PY'
import json, os, subprocess, sys

repo_root, cli_bin, sandbox_home, run1_dir = sys.argv[1:5]
env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

pid = "2405.13682v5"
cached = os.path.join(run1_dir, f"{pid}.json")
if os.path.isfile(cached):
    obj = json.load(open(cached, encoding="utf-8"))
else:
    main_tex = os.path.join(repo_root, "Benchmarks", "manuscripts", pid, "src", "main.tex")
    proc = subprocess.run([cli_bin, "diagnostics", main_tex, "--offline", "--json", "--lang", "en"], env=env, capture_output=True)
    if proc.returncode == 2:
        print(f"  FAIL [Row 5]: CLI exited 2 on {pid}: {proc.stderr.decode('utf-8', 'replace')}")
        sys.exit(1)
    obj = json.loads(proc.stdout.decode("utf-8"))

failures = []

file_paths = [f.get("path") for f in obj.get("files", [])]
if "main.bbl" not in file_paths:
    failures.append(f"expected 'main.bbl' in files[], got {file_paths}")

bib_srcs = obj.get("bibliographySources", [])
if len(bib_srcs) != 1:
    failures.append(f"expected 1 bibliographySources entry on {pid}, got {bib_srcs}")
else:
    src0 = bib_srcs[0]
    if (
        src0.get("kind") != "bbl"
        or src0.get("path") != "main.bbl"
        or src0.get("entries") != 46
        or (src0.get("errors") or []) != []
    ):
        failures.append(f"unexpected bibliographySources[0] on {pid}: {src0}")

citations = obj.get("citations", [])
if len(citations) != 46:
    failures.append(f"expected 46 citations on {pid}, got {len(citations)}")

defined_count = 0
verified_offline_count = 0
for c in citations:
    if c.get("defined") is True and c.get("source") == "main.bbl":
        defined_count += 1
    else:
        failures.append(f"citation '{c.get('key')}' expected defined=True and source='main.bbl', got {c}")
    ver = c.get("verification")
    if isinstance(ver, dict) and ver.get("verdict") == "UNVERIFIED" and ver.get("reasons") == ["offline"]:
        verified_offline_count += 1
    else:
        failures.append(f"citation '{c.get('key')}' expected UNVERIFIED/['offline'], got {ver}")

diags = obj.get("diagnostics", [])
cite404 = [d for d in diags if d.get("code") == "CITE404"]
inc002 = [d for d in diags if d.get("code") == "INC002"]
if cite404:
    failures.append(f"expected 0 CITE404 on {pid}, got {len(cite404)}")
if inc002:
    failures.append(f"expected 0 INC002 on {pid}, got {len(inc002)}")

print(
    f"  [2405.13682v5] main.bbl_in_files={'main.bbl' in file_paths} (total_files={len(file_paths)}) | "
    f"bibliographySources={bib_srcs} | defined={defined_count}/46 | "
    f"UNVERIFIED(offline)={verified_offline_count}/46 | CITE404={len(cite404)} | INC002={len(inc002)}"
)

if failures:
    for f in failures:
        print(f"  FAIL [Row 5]: {f}")
    sys.exit(1)
sys.exit(0)
PY
)"
        ROW5_RC=$?
        set -e
        echo "$ROW5_OUT"
        if [[ "$ROW5_RC" -eq 0 ]]; then
            record_pass 5 "2405.13682v5 includes main.bbl in files, parses 1 bbl source (46 entries), marks all 46 keys defined & UNVERIFIED (offline), with 0 CITE404 and 0 INC002"
        else
            record_fail 5 "Row 5 2405.13682v5 \\input{main.bbl} check failed"
        fi
    fi

    if should_run_row 6; then
        echo "== [Row 6] 9 篇 .bib 条目数对照 bibtex-entry-counts.tsv（0 条 BIB001）与 2410.04196v2 \\citep{bayestune} CITE_KEY_CASE =="
        set +e
        ROW6_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$RUN1_DIR" <<'PY'
import csv, json, os, subprocess, sys

repo_root, cli_bin, sandbox_home, run1_dir = sys.argv[1:5]
env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

papers_tsv = os.path.join(repo_root, "Benchmarks", "manuscripts", "papers.tsv")
counts_tsv = os.path.join(repo_root, "Benchmarks", "manuscripts", "bibtex-entry-counts.tsv")

main_by_paper = {}
with open(papers_tsv, encoding="utf-8") as pf:
    for r in csv.DictReader(pf, delimiter="\t"):
        main_by_paper[f"{r['arxiv_id']}{r['version']}"] = r["main_file"]

def load_paper_diag(pid: str):
    cached = os.path.join(run1_dir, f"{pid}.json")
    if os.path.isfile(cached):
        return json.load(open(cached, encoding="utf-8"))
    main_rel = main_by_paper[pid]
    main_tex = os.path.join(repo_root, "Benchmarks", "manuscripts", pid, "src", main_rel)
    proc = subprocess.run([cli_bin, "diagnostics", main_tex, "--offline", "--json", "--lang", "en"], env=env, capture_output=True)
    if proc.returncode == 2:
        raise RuntimeError(f"CLI exited 2 on {pid}: {proc.stderr.decode('utf-8', 'replace')}")
    return json.loads(proc.stdout.decode("utf-8"))

failures = []
matched_bibs = 0
total_bibs = 0

with open(counts_tsv, encoding="utf-8") as cf:
    for raw_line in cf:
        line = raw_line.strip()
        if not line:
            continue
        total_bibs += 1
        parts = line.split("\t")
        pid, bib_file = parts[0], parts[1]
        kv = dict(item.split("=", 1) for item in parts[2:])
        expected_entries = int(kv["bibtex_entries"])
        expected_repeated = int(kv["repeated"])

        try:
            obj_p = load_paper_diag(pid)
        except Exception as exc:
            failures.append(str(exc))
            continue

        bib_sources = obj_p.get("bibliographySources", [])
        matching_srcs = [
            s for s in bib_sources
            if s.get("kind") == "bib" and os.path.basename(s.get("path", "")) == bib_file
        ]
        diags_p = obj_p.get("diagnostics", [])
        bib001_p = [d for d in diags_p if d.get("code") == "BIB001"]
        bib002_p = [d for d in diags_p if d.get("code") == "BIB002"]

        if len(matching_srcs) != 1:
            failures.append(f"[{pid}] expected 1 bib source matching {bib_file}, got {bib_sources}")
            continue

        src_rec = matching_srcs[0]
        actual_entries = src_rec.get("entries")
        src_errs = src_rec.get("errors") or []

        # Also cross-check direct `verify-citations <bib> --offline --json` unique citeKey count & 0 parse_error
        bib_abs = os.path.join(repo_root, "Benchmarks", "manuscripts", pid, "src", src_rec["path"])
        p_vc = subprocess.run([cli_bin, "verify-citations", bib_abs, "--offline", "--json", "--lang", "en"], env=env, capture_output=True)
        vc_ok = (p_vc.returncode != 2)
        vc_unique = -1
        vc_parse_err = -1
        if vc_ok:
            vc_obj = json.loads(p_vc.stdout.decode("utf-8"))
            vc_unique = len({v["citeKey"].lower() for v in vc_obj.get("verdicts", [])})
            vc_parse_err = (vc_obj.get("unverifiedByReason") or {}).get("parse_error", 0)

        paper_ok = (
            actual_entries == expected_entries
            and len(src_errs) == 0
            and len(bib001_p) == 0
            and vc_ok
            and vc_unique == expected_entries
            and vc_parse_err == 0
            and len(bib002_p) == expected_repeated
        )
        status_str = "PASS" if paper_ok else "FAIL"
        print(
            f"  [{pid} {bib_file}] {status_str}: entries={actual_entries}/{expected_entries}, "
            f"verify_unique={vc_unique}/{expected_entries}, BIB001={len(bib001_p)}, BIB002={len(bib002_p)}/{expected_repeated}"
        )
        if paper_ok:
            matched_bibs += 1
        else:
            failures.append(
                f"[{pid} {bib_file}] entries={actual_entries}/{expected_entries}, vc_unique={vc_unique}, "
                f"src_errors={src_errs}, BIB001={bib001_p}, vc_parse_err={vc_parse_err}, BIB002={len(bib002_p)}/{expected_repeated}"
            )

if total_bibs != 9:
    failures.append(f"Expected 9 rows in bibtex-entry-counts.tsv, found {total_bibs}")

obj = load_paper_diag("2410.04196v2")
cites = {c["key"]: c for c in obj.get("citations", [])}
bt = cites.get("bayestune")
if not bt:
    failures.append("missing 'bayestune' in 2410.04196v2 citations")
else:
    if bt.get("defined") is not True:
        failures.append(f"expected bayestune.defined == True, got {bt.get('defined')}")
    if bt.get("source") != "fhbi.bib":
        failures.append(f"expected bayestune.source == 'fhbi.bib', got {bt.get('source')}")
    if not isinstance(bt.get("verification"), dict):
        failures.append(f"expected bayestune.verification dict, got {bt.get('verification')}")

uncited = set(obj.get("uncitedEntries", []))
if "Bayestune" in uncited:
    failures.append("'Bayestune' should not appear in uncitedEntries when cited as 'bayestune'")

diags = obj.get("diagnostics", [])
cite404 = [d for d in diags if d.get("code") == "CITE404"]
case_warns = [d for d in diags if d.get("code") == "CITE_KEY_CASE"]
if cite404:
    failures.append(f"expected 0 CITE404 on 2410.04196v2, got {cite404}")
if len(case_warns) != 1:
    failures.append(f"expected 1 CITE_KEY_CASE warning on 2410.04196v2, got {case_warns}")
else:
    w = case_warns[0]
    msg = w.get("message", "")
    if w.get("severity") != "WARNING" or w.get("category") != "structure":
        failures.append(f"expected WARNING/structure on CITE_KEY_CASE, got {w}")
    if "bayestune" not in msg or "Bayestune" not in msg:
        failures.append(f"CITE_KEY_CASE message must name both 'bayestune' and 'Bayestune': {msg}")

print(f"row6_matching_bibs={matched_bibs}/{total_bibs}")
if bt and len(case_warns) == 1 and not cite404:
    print(
        f"  [2410.04196v2 CITE_KEY_CASE] PASS: bayestune defined={bt.get('defined')}, "
        f"source={bt.get('source')}, CITE404=0, CITE_KEY_CASE=1 ({case_warns[0].get('severity')}: {case_warns[0].get('message')})"
    )

if failures:
    for f in failures:
        print(f"  FAIL [Row 6]: {f}")
    sys.exit(1)
sys.exit(0)
PY
)"
        ROW6_RC=$?
        set -e
        echo "$ROW6_OUT"
        if [[ "$ROW6_RC" -eq 0 ]]; then
            record_pass 6 "All 9 manuscript .bib files match bibtex-entry-counts.tsv unique entry counts with 0 BIB001, and 2410.04196v2 \\citep{bayestune} emits CITE_KEY_CASE with 0 CITE404"
        else
            record_fail 6 "Row 6 .bib entry counts, BIB001, or 2410.04196v2 CITE_KEY_CASE check failed"
        fi
    fi

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
    # Row 9: Missing file / missing .bib INC002 & main .bbl fallback (BIB_FROM_BBL + defined entries)
    # ==================================================================
    if should_run_row 9; then
        echo "== [Row 9] 缺失文件与缺失 .bib (INC002 带文件与行号) 及同名 .bbl 回退 (BIB_FROM_BBL 且 .bbl 条目均算已定义、0 条 CITE404) =="
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

# 9D. Missing `\bibliography{custom}` with matching `acl_latex.bbl` -> 0 INC002, 1 INFO BIB_FROM_BBL, bbl entries=2, all defined=True, 0 CITE404
obj_bbl = run_diag(os.path.join(base, "bbl-fallback", "acl_latex.tex"))
inc_bbl = [d for d in obj_bbl.get("diagnostics", []) if d.get("code") == "INC002"]
info_bbl = [d for d in obj_bbl.get("diagnostics", []) if d.get("code") == "BIB_FROM_BBL"]
cite404_bbl = [d for d in obj_bbl.get("diagnostics", []) if d.get("code") == "CITE404"]
bib_srcs = obj_bbl.get("bibliographySources", [])
cites_bbl = obj_bbl.get("citations", [])
defined_keys_bbl = [c["key"] for c in cites_bbl if c.get("defined") is True and c.get("source") == "acl_latex.bbl"]
print(
    f"  [bbl-fallback acl_latex] INC002={len(inc_bbl)} BIB_FROM_BBL={[(d['severity'], d['file'], d['line']) for d in info_bbl]} "
    f"bibliographySources={bib_srcs} defined_keys={defined_keys_bbl} CITE404={len(cite404_bbl)}"
)
if inc_bbl:
    failures.append(f"bbl-fallback emitted unexpected INC002: {inc_bbl}")
if cite404_bbl:
    failures.append(f"bbl-fallback emitted unexpected CITE404: {cite404_bbl}")
if len(info_bbl) != 1 or info_bbl[0].get("severity") != "INFO" or info_bbl[0].get("file") != "acl_latex.tex" or info_bbl[0].get("line") != 6:
    failures.append(f"bbl-fallback expected 1 INFO BIB_FROM_BBL at acl_latex.tex:6, got {info_bbl}")
if (
    len(bib_srcs) != 1
    or bib_srcs[0].get("kind") != "bbl"
    or bib_srcs[0].get("path") != "acl_latex.bbl"
    or bib_srcs[0].get("entries") != 2
    or (bib_srcs[0].get("errors") or []) != []
):
    failures.append(f"bbl-fallback expected bibliographySources=[{{kind:'bbl', path:'acl_latex.bbl', entries:2, errors:[]}}], got {bib_srcs}")
if sorted(defined_keys_bbl) != ["lecun2015", "vaswani2017"] or len(cites_bbl) != 2:
    failures.append(f"bbl-fallback expected ['lecun2015', 'vaswani2017'] defined from acl_latex.bbl, got {cites_bbl}")
for c in cites_bbl:
    ver = c.get("verification")
    if not (isinstance(ver, dict) and ver.get("verdict") == "UNVERIFIED" and ver.get("reasons") == ["offline"]):
        failures.append(f"bbl-fallback key '{c.get('key')}' expected UNVERIFIED/['offline'], got {ver}")

# 9E. Tectonic-verified fallback `.bbl` fixture `thebibliography-bbl/03-fallback-bbl/paper.tex`
paper_tex = os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "thebibliography-bbl", "03-fallback-bbl", "paper.tex")
obj_p = run_diag(paper_tex)
inc_p = [d for d in obj_p.get("diagnostics", []) if d.get("code") == "INC002"]
info_p = [d for d in obj_p.get("diagnostics", []) if d.get("code") == "BIB_FROM_BBL"]
cite404_p = [d for d in obj_p.get("diagnostics", []) if d.get("code") == "CITE404"]
srcs_p = obj_p.get("bibliographySources", [])
cites_p = obj_p.get("citations", [])
defined_keys_p = [c["key"] for c in cites_p if c.get("defined") is True and c.get("source") == "paper.bbl"]
print(
    f"  [03-fallback-bbl paper] INC002={len(inc_p)} BIB_FROM_BBL={[(d['severity'], d['file'], d['line']) for d in info_p]} "
    f"bibliographySources={srcs_p} defined_keys={defined_keys_p} CITE404={len(cite404_p)}"
)
if inc_p or cite404_p:
    failures.append(f"03-fallback-bbl unexpected INC002={inc_p} CITE404={cite404_p}")
if len(info_p) != 1 or info_p[0].get("severity") != "INFO":
    failures.append(f"03-fallback-bbl expected 1 INFO BIB_FROM_BBL, got {info_p}")
if len(srcs_p) != 1 or srcs_p[0].get("kind") != "bbl" or srcs_p[0].get("path") != "paper.bbl" or srcs_p[0].get("entries") != 3:
    failures.append(f"03-fallback-bbl unexpected bibliographySources: {srcs_p}")
if sorted(defined_keys_p) != ["hochreiter1997", "lecun2015", "who2021"] or len(cites_p) != 3:
    failures.append(f"03-fallback-bbl expected all 3 keys defined from paper.bbl, got {cites_p}")

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
            record_pass 9 "Missing include/bib emit exact ERROR INC002 (file & line), and matching <main>.bbl emits INFO BIB_FROM_BBL with 0 INC002 and all .bbl entries marked defined (0 CITE404)"
        else
            record_fail 9 "Missing-file INC002 or BIB_FROM_BBL fallback (.bbl defined entries) check failed"
        fi
    fi

    # ==================================================================
    # Row 10: Single-entry BibTeX recovery (`Tests/Fixtures/manuscripts/bib-recovery/ten.bib`)
    # ==================================================================
    if should_run_row 10; then
        echo "== [Row 10] 坏 .bib 恢复 (bib-recovery/ten.bib: e3 开始行 15、出错行 22，其余 9 条对照 .bbl，退出码按已定第 3 条) =="
        set +e
        ROW10_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import json, os, re, subprocess, sys

repo_root, cli_bin, sandbox_home, work_scratch = sys.argv[1:5]
env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

failures = []

rec_dir = os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "bib-recovery")
ten_bib = os.path.join(rec_dir, "ten.bib")
main_tex = os.path.join(rec_dir, "main.tex")
bbl_path = os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "expected", "bib-recovery.bibtex.bbl")

# Parse expected 9 clean items from BibTeX-generated bib-recovery.bibtex.bbl
bbl_text = open(bbl_path, encoding="utf-8").read()
bbl_blocks = re.split(r"\\bibitem\{([^}]+)\}", bbl_text)[1:]
expected_clean = {}
for idx in range(0, len(bbl_blocks), 2):
    k = bbl_blocks[idx].strip()
    body = bbl_blocks[idx + 1].strip()
    if k == "e3":
        continue
    parts = [p.strip() for p in body.split("\\newblock")]
    author_line = parts[0].rstrip(".").replace("~", " ").strip()
    title_line = parts[1].rstrip(".").strip()
    m_vj = re.search(r"\{\\em\s+([^}]+)\},\s*(\d{4})", parts[2])
    expected_clean[k] = {
        "author": author_line,
        "title": title_line,
        "venue": m_vj.group(1) if m_vj else "",
        "year": int(m_vj.group(2)) if m_vj else None,
    }

if len(expected_clean) != 9:
    failures.append(f"Expected 9 clean entries in bib-recovery.bibtex.bbl, parsed {len(expected_clean)}")

# 10A. verify-citations ten.bib --offline --json
p_vc = subprocess.run([cli_bin, "verify-citations", ten_bib, "--offline", "--json", "--lang", "en"], env=env, capture_output=True, text=True)
if p_vc.returncode != 1:
    failures.append(f"verify-citations ten.bib expected exit 1 (Settled #3), got {p_vc.returncode}; stderr={p_vc.stderr}")
else:
    vc_obj = json.loads(p_vc.stdout)
    verdicts_by_key = {v["citeKey"]: v for v in vc_obj.get("verdicts", [])}
    unv_reasons = vc_obj.get("unverifiedByReason", {})
    if vc_obj.get("complete") is not False:
        failures.append(f"verify-citations complete expected False, got {vc_obj.get('complete')}")
    if unv_reasons != {"offline": 9, "parse_error": 1}:
        failures.append(f"verify-citations unverifiedByReason expected {{'offline':9,'parse_error':1}}, got {unv_reasons}")
    if not all(tok in p_vc.stderr for tok in ("e3", "15", "22")):
        failures.append(f"verify-citations stderr must report e3, startLine 15, line 22; got: {p_vc.stderr}")
    v_e3 = verdicts_by_key.get("e3")
    if not v_e3:
        failures.append("verify-citations missing e3 verdict")
    else:
        pe_info = (v_e3.get("auditedEntry") or {}).get("parseErrorInfo") or {}
        if (
            v_e3.get("firewallClass") != "UNVERIFIED"
            or v_e3.get("reasons") != ["parse_error"]
            or v_e3.get("insertable") is not False
            or (v_e3.get("auditedEntry") or {}).get("parseError") is not True
            or pe_info.get("startLine") != 15
            or pe_info.get("line") != 22
        ):
            failures.append(f"verify-citations e3 verdict mismatch: {v_e3}")
    for k, exp in sorted(expected_clean.items()):
        v = verdicts_by_key.get(k)
        if not v:
            failures.append(f"verify-citations missing recovered clean entry {k}")
            continue
        ae = v.get("auditedEntry") or {}
        authors = ae.get("authors") or []
        full_author = f"{authors[0].get('givenName', '')} {authors[0].get('familyName', '')}".strip() if len(authors) == 1 else ""
        if (
            ae.get("parseError") is not False
            or full_author != exp["author"]
            or ae.get("title") != exp["title"]
            or ae.get("venue") != exp["venue"]
            or ae.get("year") != exp["year"]
        ):
            failures.append(f"verify-citations {k} mismatch vs .bbl: actual={ae} vs expected={exp}")
    print(f"  [verify-citations] exit={p_vc.returncode}, unverifiedByReason={unv_reasons}, e3=(UNVERIFIED, parse_error, startLine=15, line=22), clean_matched=9/9")

# 10B. format-bib ten.bib (text & --json)
p_fb = subprocess.run([cli_bin, "format-bib", ten_bib, "--style", "ieee", "--lang", "en"], env=env, capture_output=True, text=True)
p_fb_json = subprocess.run([cli_bin, "format-bib", ten_bib, "--style", "ieee", "--json", "--lang", "en"], env=env, capture_output=True, text=True)
if p_fb.returncode != 1 or p_fb_json.returncode != 1:
    failures.append(f"format-bib ten.bib expected exit 1 (Settled #3), got text={p_fb.returncode}, json={p_fb_json.returncode}")
else:
    if not all(tok in p_fb.stderr for tok in ("e3", "15", "22")):
        failures.append(f"format-bib stderr must report e3, startLine 15, line 22; got: {p_fb.stderr}")
    fb_obj = json.loads(p_fb_json.stdout)
    fb_items = {it["citeKeys"][0]: it["bibliographyPlainText"] for it in fb_obj.get("items", []) if it.get("citeKeys")}
    for k, exp in sorted(expected_clean.items()):
        txt = fb_items.get(k, "")
        fam = exp["author"].split()[-1]
        if fam not in txt or exp["title"] not in txt or str(exp["year"]) not in txt:
            failures.append(f"format-bib missing/mismatched recovered item {k}: '{txt}' vs {exp}")
    print(f"  [format-bib] exit={p_fb.returncode}, stderr_has_e3_15_22=True, formatted_clean_items={len(fb_items)}/9")

# 10C. diagnostics main.tex --bib ten.bib --offline --json
p_dg = subprocess.run([cli_bin, "diagnostics", main_tex, "--bib", ten_bib, "--offline", "--json", "--lang", "en"], env=env, capture_output=True, text=True)
if p_dg.returncode == 2:
    failures.append(f"diagnostics --bib ten.bib exited 2: {p_dg.stderr}")
else:
    dg_obj = json.loads(p_dg.stdout)
    bsrcs = dg_obj.get("bibliographySources", [])
    berrs = (bsrcs[0].get("errors") if bsrcs else None) or []
    diags = dg_obj.get("diagnostics", [])
    bib001 = [d for d in diags if d.get("code") == "BIB001"]
    cite404 = [d for d in diags if d.get("code") == "CITE404"]
    cites_by_key = {c["key"]: c for c in dg_obj.get("citations", [])}
    c_e3_ver = (cites_by_key.get("e3") or {}).get("verification") or {}
    if len(berrs) != 1 or berrs[0].get("key") != "e3" or berrs[0].get("startLine") != 15 or berrs[0].get("line") != 22:
        failures.append(f"diagnostics bibliographySources.errors mismatch: {berrs}")
    if len(bib001) != 1 or bib001[0].get("severity") != "ERROR" or bib001[0].get("category") != "structure" or bib001[0].get("line") != 22:
        failures.append(f"diagnostics BIB001 mismatch: {bib001}")
    if cite404:
        failures.append(f"diagnostics unexpected CITE404 on ten.bib: {cite404}")
    if c_e3_ver.get("verdict") != "UNVERIFIED" or c_e3_ver.get("reasons") != ["parse_error"] or c_e3_ver.get("insertable") is not False:
        failures.append(f"diagnostics citations[e3].verification mismatch: {c_e3_ver}")
    print(f"  [diagnostics --bib] exit={p_dg.returncode}, BIB001=1 (line=22, startLine=15, key=e3), CITE404=0")

# 10D. Zero clean entries -> exit 2 on both verify-citations and format-bib
zero_bib = os.path.join(work_scratch, "row10-zero-clean.bib")
with open(zero_bib, "w", encoding="utf-8") as zf:
    zf.write("@article{broken_only,\n  title = {Unclosed\n")
rc_vc_zero = subprocess.run([cli_bin, "verify-citations", zero_bib, "--offline"], env=env, capture_output=True).returncode
rc_fb_zero = subprocess.run([cli_bin, "format-bib", zero_bib], env=env, capture_output=True).returncode
if rc_vc_zero != 2 or rc_fb_zero != 2:
    failures.append(f"zero-clean-entry .bib expected exit 2, got verify-citations={rc_vc_zero}, format-bib={rc_fb_zero}")
else:
    print(f"  [zero-clean-entry check] verify-citations exit={rc_vc_zero}, format-bib exit={rc_fb_zero}")

if failures:
    for f in failures:
        print(f"  FAIL [Row 10]: {f}")
    sys.exit(1)
sys.exit(0)
PY
)"
        ROW10_RC=$?
        set -e
        echo "$ROW10_OUT"
        if [[ "$ROW10_RC" -eq 0 ]]; then
            record_pass 10 "ten.bib reports e3 (startLine 15, line 22, UNVERIFIED parse_error), recovers all 9 clean entries matching BibTeX .bbl, and exits 1 (2 when 0 clean entries)"
        else
            record_fail 10 "Broken .bib recovery, BIB001 reporting, or Settled #3 exit codes failed on bib-recovery/ten.bib"
        fi
    fi

    # ==================================================================
    # Row 11: BibTeX field normalization & crossref inheritance (`Tests/Fixtures/manuscripts/bib-fields/refs.bib`)
    # ==================================================================
    if should_run_row 11; then
        echo "== [Row 11] BibTeX 字段继承与规范化 (bib-fields/refs.bib: and others、crossref、howpublished \\url/\\href、父条目不报未使用、BIB003) =="
        set +e
        ROW11_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import json, os, subprocess, sys

repo_root, cli_bin, sandbox_home, work_scratch = sys.argv[1:5]
env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

failures = []
bf_dir = os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "bib-fields")
refs_bib = os.path.join(bf_dir, "refs.bib")
main_tex = os.path.join(bf_dir, "main.tex")

# 11A. Parsed entries via verify-citations --offline --json
p_vc = subprocess.run([cli_bin, "verify-citations", refs_bib, "--offline", "--json", "--lang", "en"], env=env, capture_output=True, text=True)
if p_vc.returncode == 2:
    failures.append(f"verify-citations refs.bib exited 2: {p_vc.stderr}")
else:
    vc_obj = json.loads(p_vc.stdout)
    by_key = {e["citeKey"]: e for e in vc_obj.get("auditedEntries", [])}

    p1 = by_key.get("paper1") or {}
    p1_surnames = [a.get("familyName") for a in p1.get("authors", [])]
    if p1_surnames != ["Smith", "Jones"] or p1.get("authorsTruncated") is not True:
        failures.append(f"paper1 expected authors=['Smith','Jones'] & authorsTruncated=True, got surnames={p1_surnames}, truncated={p1.get('authorsTruncated')}")
    if p1.get("venue") != "Child Booktitle Wins" or p1.get("year") != 2020 or p1.get("publisher") != "ACM":
        failures.append(f"paper1 crossref inheritance mismatch: venue={p1.get('venue')!r}, year={p1.get('year')}, publisher={p1.get('publisher')!r}")

    p2 = by_key.get("paper2") or {}
    if p2.get("venue") != "Proceedings of the 10th Conference on Things" or p2.get("year") != 2020 or p2.get("publisher") != "ACM":
        failures.append(f"paper2 crossref inheritance mismatch: venue={p2.get('venue')!r}, year={p2.get('year')}, publisher={p2.get('publisher')!r}")

    w1 = by_key.get("web1") or {}
    w2 = by_key.get("web2") or {}
    if w1.get("url") != "https://www.who.int/report%20one" or w1.get("venue", "") != "" or "http" in w1.get("venue", "") or "who.int" in w1.get("venue", ""):
        failures.append(f"web1 URL/venue mismatch: url={w1.get('url')!r}, venue={w1.get('venue')!r}")
    if w2.get("url") != "https://example.org/x" or w2.get("venue", "") != "" or "http" in w2.get("venue", "") or "example.org" in w2.get("venue", ""):
        failures.append(f"web2 URL/venue mismatch: url={w2.get('url')!r}, venue={w2.get('venue')!r}")

    print(
        f"  [entries] paper1=(authors={p1_surnames}, authorsTruncated={p1.get('authorsTruncated')}, venue={p1.get('venue')!r}, year={p1.get('year')}, publisher={p1.get('publisher')!r}) | "
        f"paper2=(venue={p2.get('venue')!r}, year={p2.get('year')}) | "
        f"web1.url={w1.get('url')!r} (venue={w1.get('venue')!r}) | web2.url={w2.get('url')!r} (venue={w2.get('venue')!r})"
    )

# 11B. format-bib --style ieee must not emit "and et al."
p_fb = subprocess.run([cli_bin, "format-bib", refs_bib, "--style", "ieee", "--lang", "en"], env=env, capture_output=True, text=True)
if p_fb.returncode != 0:
    failures.append(f"format-bib refs.bib --style ieee exited {p_fb.returncode}: {p_fb.stderr}")
else:
    if "A. Smith, B. Jones, et al." not in p_fb.stdout or "and et al." in p_fb.stdout or "& et al." in p_fb.stdout:
        failures.append(f"format-bib --style ieee invalid et al. rendering: {p_fb.stdout}")
    else:
        print("  [format-bib --style ieee] PASS: 'A. Smith, B. Jones, et al.' rendered with no 'and et al.'")

# 11C. diagnostics main.tex -> conf2020 not reported uncited; missing parent -> WARNING BIB003
p_dg = subprocess.run([cli_bin, "diagnostics", main_tex, "--offline", "--json", "--lang", "en"], env=env, capture_output=True, text=True)
if p_dg.returncode == 2:
    failures.append(f"diagnostics bib-fields/main.tex exited 2: {p_dg.stderr}")
else:
    dg_obj = json.loads(p_dg.stdout)
    uncited = dg_obj.get("uncitedEntries", [])
    lint_uncited = [d for d in dg_obj.get("diagnostics", []) if d.get("code") == "LINT_UNCITED_BIB_ENTRY"]
    if "conf2020" in uncited or uncited or lint_uncited:
        failures.append(f"conf2020 must not be reported uncited; uncitedEntries={uncited}, LINT_UNCITED_BIB_ENTRY={lint_uncited}")
    else:
        print(f"  [uncited suppression] PASS: uncitedEntries={uncited}, LINT_UNCITED_BIB_ENTRY=0")

miss_dir = os.path.join(work_scratch, "row11-missing-parent")
os.makedirs(miss_dir, exist_ok=True)
miss_tex = os.path.join(miss_dir, "main.tex")
miss_bib = os.path.join(miss_dir, "refs.bib")
with open(miss_tex, "w", encoding="utf-8") as tf:
    tf.write("\\documentclass{article}\\begin{document}\\cite{c1}\\bibliography{refs}\\end{document}\n")
with open(miss_bib, "w", encoding="utf-8") as bf:
    bf.write("@inproceedings{c1,\n  author = {Ada Lovelace},\n  title = {Note G},\n  crossref = {no_such_proc}\n}\n")
p_miss = subprocess.run([cli_bin, "diagnostics", miss_tex, "--offline", "--json", "--lang", "en"], env=env, capture_output=True, text=True)
if p_miss.returncode == 2:
    failures.append(f"diagnostics missing-crossref exited 2: {p_miss.stderr}")
else:
    miss_diags = json.loads(p_miss.stdout).get("diagnostics", [])
    bib003 = [d for d in miss_diags if d.get("code") == "BIB003" and d.get("severity") == "WARNING"]
    if len(bib003) != 1:
        failures.append(f"expected 1 WARNING BIB003 for missing crossref parent, got {miss_diags}")
    else:
        print(f"  [missing crossref parent] PASS: WARNING BIB003 emitted ({bib003[0].get('message')})")

if failures:
    for f in failures:
        print(f"  FAIL [Row 11]: {f}")
    sys.exit(1)
sys.exit(0)
PY
)"
        ROW11_RC=$?
        set -e
        echo "$ROW11_OUT"
        if [[ "$ROW11_RC" -eq 0 ]]; then
            record_pass 11 "bib-fields/refs.bib sets authorsTruncated without 'and et al.', inherits crossref fields, extracts howpublished URLs without venue pollution, suppresses uncited on conf2020, and warns BIB003 on missing parent"
        else
            record_fail 11 "Row 11 BibTeX field normalization, crossref inheritance, or uncited suppression check failed"
        fi
    fi

    # ==================================================================
    # Row 12: S64–S67 command tables & parser constructs + Latin-1 / Windows-1252 encoding fallback
    # ==================================================================
    if should_run_row 12; then
        echo "== [Row 12] S64 引用与交叉引用命令表、S65 可选参数、S66 键规范化与 CITE_KEY_CASE、S67 三类解析写法及 Latin-1/Windows-1252 文件读取 (ENC001) =="
        set +e
        ROW12_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" <<'PY'
import glob, json, os, subprocess, sys

repo_root, cli_bin, sandbox_home = sys.argv[1:4]
env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

failures = []

# 12A. S64–S67 per-command and per-construct fixtures (`Tests/Fixtures/manuscripts/parser-commands`)
cmd_dir = os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "parser-commands")
exp_files = sorted(glob.glob(os.path.join(cmd_dir, "*.expected.json")))
if len(exp_files) < 63:
    failures.append(f"Expected at least 63 expected files in {cmd_dir}, found {len(exp_files)}")

passed_cmd_cases = 0
for exp_path in exp_files:
    spec = json.load(open(exp_path, encoding="utf-8"))
    slug = spec["case"]
    tex_path = os.path.join(cmd_dir, f"{slug}.tex")
    exp_cites = set(spec["cite_keys"])
    exp_labels = set(spec["labels"])
    exp_refs = set(spec.get("references", []))
    exp_struct_errs = int(spec["structure_errors"])
    exp_warns = set(spec.get("expected_warnings", []))

    p = subprocess.run([cli_bin, "diagnostics", tex_path, "--offline", "--json", "--lang", "en"], env=env, capture_output=True)
    if p.returncode == 2:
        failures.append(f"[{slug}] CLI exited 2: {p.stderr.decode('utf-8', 'replace')}")
        continue
    obj = json.loads(p.stdout.decode("utf-8"))
    act_cites = set(c["key"] for c in obj.get("citations", []))
    act_labels = set(l["key"] for l in obj.get("labels", []))
    act_refs = set(r["key"] for r in obj.get("references", []))
    diags = obj.get("diagnostics", [])
    struct_errs = [d for d in diags if d.get("category") == "structure" and d.get("severity") == "ERROR"]
    ast_diags = [d for d in diags if d.get("code", "").startswith("AST")]
    inc002_diags = [d for d in diags if d.get("code") == "INC002"]
    warn_codes = set(d.get("code", "") for d in diags if d.get("severity") == "WARNING")

    case_ok = (
        act_cites == exp_cites
        and act_labels == exp_labels
        and act_refs == exp_refs
        and len(struct_errs) == exp_struct_errs
        and not ast_diags
        and not inc002_diags
        and exp_warns.issubset(warn_codes)
    )
    if slug == "s66-cite-key-case":
        ck_diags = [d for d in diags if d.get("code") == "CITE_KEY_CASE"]
        if len(ck_diags) != 1 or "bayestune" not in ck_diags[0].get("message", "") or "Bayestune" not in ck_diags[0].get("message", ""):
            case_ok = False
            failures.append(f"[{slug}] CITE_KEY_CASE must name both bayestune and Bayestune: {ck_diags}")

    if case_ok:
        passed_cmd_cases += 1
    else:
        failures.append(
            f"[{slug}] mismatch: cites={sorted(act_cites)}/{sorted(exp_cites)}, "
            f"labels={sorted(act_labels)}/{sorted(exp_labels)}, refs={sorted(act_refs)}/{sorted(exp_refs)}, "
            f"struct_ERR={len(struct_errs)}/{exp_struct_errs}, AST={len(ast_diags)}, INC002={len(inc002_diags)}, warns={sorted(warn_codes)}"
        )

print(f"  [parser-commands (S64/S65/S66/S67)] passed={passed_cmd_cases}/{len(exp_files)} (0 AST*, 0 INC002)")

# 12B. Latin-1 / Windows-1252 root and child files (`Tests/Fixtures/manuscripts/loader-encoding`)
enc_dir = os.path.join(repo_root, "Tests", "Fixtures", "manuscripts", "loader-encoding")
main_tex = os.path.join(enc_dir, "main.tex")
sub_tex = os.path.join(enc_dir, "sub.tex")

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
    exp_files_enc = [("main.tex", "windows-1252", None), ("sub.tex", "windows-1252", "main.tex:5")]
    labels = sorted(l.get("key") for l in obj.get("labels", []))
    cites = sorted(c.get("key") for c in obj.get("citations", []))
    enc001 = [d for d in obj.get("diagnostics", []) if d.get("code") == "ENC001"]
    inc002 = [d for d in obj.get("diagnostics", []) if d.get("code") == "INC002"]
    ast_enc = [d for d in obj.get("diagnostics", []) if d.get("code", "").startswith("AST")]
    titles = [e.get("title", "") for e in outline]

    print(
        f"  [loader-encoding] exit={p_diag.returncode} files={files} labels={labels} cites={cites} "
        f"ENC001={[(d['severity'], d['file']) for d in enc001]} titles={titles}"
    )
    if files != exp_files_enc:
        failures.append(f"files mismatch: {files} != {exp_files_enc}")
    if labels != ["sec:gauss", "sec:poincare"]:
        failures.append(f"labels mismatch: {labels}")
    if cites != ["knuth1968", "lecun2015"]:
        failures.append(f"citations mismatch: {cites}")
    if inc002 or ast_enc:
        failures.append(f"unexpected INC002={inc002} AST={ast_enc}")
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
            record_pass 12 "All 63 S64-S67 command/parser fixtures extract expected keys/labels/refs with 0 AST*/INC002, and Windows-1252 root/child files emit ENC001 without exiting 2"
        else
            record_fail 12 "S64-S67 command/parser check or Windows-1252 encoding fallback check failed"
        fi
    fi

    # ==================================================================
    # Row 13: Citation verification separated from structure — 3 keys cited twice each (--offline) -> 3 ERR_UNVERIFIED_CITATION (not 6), category=citation, 0 structure ERRORs
    # ==================================================================
    if should_run_row 13; then
        echo "== [Row 13] 引用核查与结构分离：3 个键各引用 2 次（--offline）-> 3 条 ERR_UNVERIFIED_CITATION（非 6 条），category=citation，结构类 ERROR=0 =="
        set +e
        ROW13_OUT="$(python3 -I - "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import json, os, subprocess, sys

cli_bin, sandbox_home, scratch = sys.argv[1:4]
env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

r13_dir = os.path.join(scratch, "row13")
os.makedirs(r13_dir, exist_ok=True)

bib_path = os.path.join(r13_dir, "refs.bib")
tex_path = os.path.join(r13_dir, "main.tex")

with open(bib_path, "w", encoding="utf-8") as bf:
    bf.write("""@article{key_alpha,
  author  = {Alpha, Alice and Beta, Bob},
  title   = {First Study on Modular Parsing},
  journal = {Journal of Symbolic Systems},
  year    = {2021},
  doi     = {10.1145/3442188.3445922}
}
@inproceedings{key_beta,
  author    = {Gamma, Grace},
  title     = {Second Study on Cross References},
  booktitle = {Proceedings of Formal Verification},
  year      = {2022},
  doi       = {10.1109/ICSE43902.2021.00042}
}
@book{key_gamma,
  author    = {Delta, Donald},
  title     = {Third Monograph on Structured Documents},
  publisher = {Academic Press},
  year      = {2020}
}
""")

with open(tex_path, "w", encoding="utf-8") as tf:
    tf.write("""\\documentclass{article}
\\begin{document}
\\section{Introduction}\\label{sec:intro}
First citations~\\cite{key_alpha, key_beta, key_gamma}.
\\section{Follow-up}
As shown in Section~\\ref{sec:intro}, we revisit~\\cite{key_alpha}, ~\\cite{key_beta}, and~\\cite{key_gamma}.
\\bibliography{refs}
\\end{document}
""")

p_json = subprocess.run(
    [cli_bin, "diagnostics", tex_path, "--offline", "--json", "--lang", "en"],
    env=env,
    capture_output=True,
    text=True,
)
p_zh = subprocess.run(
    [cli_bin, "diagnostics", tex_path, "--offline", "--lang", "zh"],
    env=env,
    capture_output=True,
    text=True,
)

failures = []

if p_json.returncode != 3:
    failures.append(f"expected JSON exit code 3 under --offline (0 structure ERRORs, 3 UNVERIFIED), got {p_json.returncode} (stderr={p_json.stderr!r})")
if p_zh.returncode != 3:
    failures.append(f"expected ZH text exit code 3 under --offline, got {p_zh.returncode} (stderr={p_zh.stderr!r})")

try:
    obj = json.loads(p_json.stdout)
except Exception as exc:
    print(f"  FAIL [Row 13]: invalid JSON ({exc}): {p_json.stdout[:200]!r}")
    sys.exit(1)

if obj.get("mode") != "offline" or obj.get("complete") is not False:
    failures.append(f"expected mode='offline' and complete=False, got mode={obj.get('mode')!r}, complete={obj.get('complete')!r}")

citations = obj.get("citations", [])
if [c.get("key") for c in citations] != ["key_alpha", "key_beta", "key_gamma"]:
    failures.append(f"expected 3 citations [key_alpha, key_beta, key_gamma], got {[c.get('key') for c in citations]}")
for c in citations:
    occs = c.get("occurrences", [])
    ver = c.get("verification") or {}
    if len(occs) != 2:
        failures.append(f"key {c.get('key')!r} expected 2 occurrences, got {len(occs)}")
    if ver.get("verdict") != "UNVERIFIED" or ver.get("reasons") != ["offline"]:
        failures.append(f"key {c.get('key')!r} expected UNVERIFIED/['offline'], got {ver}")

diags = obj.get("diagnostics", [])
cite_diags = [d for d in diags if d.get("code") == "ERR_UNVERIFIED_CITATION"]
struct_errs = [d for d in diags if d.get("category") == "structure" and d.get("severity") == "ERROR"]
any_errs = [d for d in diags if d.get("severity") == "ERROR"]

if len(cite_diags) != 3:
    failures.append(f"expected 3 ERR_UNVERIFIED_CITATION (1 per unique key, not 6), got {len(cite_diags)}: {cite_diags}")
for d in cite_diags:
    if d.get("category") != "citation":
        failures.append(f"expected category='citation', got {d}")
    if d.get("severity") != "WARNING":
        failures.append(f"expected severity='WARNING' for offline UNVERIFIED, got {d}")
    if "offline" not in d.get("message", ""):
        failures.append(f"expected reason 'offline' in message, got {d}")
for key in ("key_alpha", "key_beta", "key_gamma"):
    hits = [d for d in cite_diags if f"'{key}'" in d.get("message", "")]
    if len(hits) != 1:
        failures.append(f"expected 1 ERR_UNVERIFIED_CITATION for {key}, got {len(hits)}")

if len(struct_errs) != 0:
    failures.append(f"expected 0 structure ERROR diagnostics, got {struct_errs}")
if len(any_errs) != 0:
    failures.append(f"expected 0 ERROR diagnostics overall under offline UNVERIFIED, got {any_errs}")

exp_zh_summary = "引用核查：3 个键，VERIFIED 0，DRIFT 0，NOT_FOUND 0，RETRACTED 0，UNVERIFIED 3（原因：offline 3）；结果不完整"
if exp_zh_summary not in p_zh.stdout.splitlines():
    failures.append(f"missing expected ZH summary line {exp_zh_summary!r} in:\n{p_zh.stdout}")
zh_cite_lines = [ln for ln in p_zh.stdout.splitlines() if "ERR_UNVERIFIED_CITATION" in ln]
if len(zh_cite_lines) != 3:
    failures.append(f"expected 3 ERR_UNVERIFIED_CITATION lines in ZH text output, got {len(zh_cite_lines)}")

print(
    f"  [Row 13] exit={p_json.returncode} | cited_keys=3 (occurrences=2 each, total=6) | "
    f"ERR_UNVERIFIED_CITATION={len(cite_diags)} (all category=citation, severity=WARNING) | "
    f"structure_ERROR={len(struct_errs)}"
)

if failures:
    for msg in failures:
        print(f"  FAIL [Row 13]: {msg}")
    sys.exit(1)
sys.exit(0)
PY
)"
        ROW13_RC=$?
        set -e
        echo "$ROW13_OUT"
        if [[ "$ROW13_RC" -eq 0 ]]; then
            record_pass 13 "3 keys cited twice each under --offline emit 3 unique-key ERR_UNVERIFIED_CITATION diagnostics (category=citation, WARNING), 0 structure ERRORs, and exit code 3"
        else
            record_fail 13 "Row 13 unique-key ERR_UNVERIFIED_CITATION or structure ERROR separation check failed"
        fi
    fi

    # ==================================================================
    # Row 14: Fabricated DOI with x-firewall-class={VERIFIED} under diagnostics --registry-replay + m1-acceptance.sh Row 18
    # ==================================================================
    if should_run_row 14; then
        echo "== [Row 14] 带 x-firewall-class={VERIFIED} 的编造 DOI：diagnostics --registry-replay 拦截、findings 含“未采信”、退出码为 1 且 m1-acceptance.sh 第 18 行通过 =="
        set +e
        ROW14_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import json, os, subprocess, sys

repo_root, cli_bin, sandbox_home, scratch = sys.argv[1:5]
reg_dir = os.path.join(repo_root, "Tests", "Fixtures", "registry")

env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

r14_dir = os.path.join(scratch, "row14")
os.makedirs(r14_dir, exist_ok=True)
bib_path = os.path.join(r14_dir, "row14.bib")
tex_path = os.path.join(r14_dir, "row14.tex")

with open(bib_path, "w", encoding="utf-8") as bf:
    bf.write("""@article{fake_tampered,
  author           = {Whitfield, Eleanor and Patel, Raj},
  title            = {Quantum Gradient Descent in Biological Neural Networks},
  journal          = {Nature Machine Intelligence},
  year             = {2026},
  doi              = {10.1038/fake.2026.99999},
  x-firewall-class = {VERIFIED}
}
""")

with open(tex_path, "w", encoding="utf-8") as tf:
    tf.write("\\documentclass{article}\n\\begin{document}\n\\section{Intro}\nSee~\\cite{fake_tampered}.\n\\end{document}\n")

failures = []

p_zh = subprocess.run(
    [cli_bin, "diagnostics", tex_path, "--bib", bib_path, "--registry-replay", reg_dir, "--json", "--lang", "zh"],
    env=env,
    capture_output=True,
    text=True,
)
p_en = subprocess.run(
    [cli_bin, "diagnostics", tex_path, "--bib", bib_path, "--registry-replay", reg_dir, "--json", "--lang", "en"],
    env=env,
    capture_output=True,
    text=True,
)
p_txt_zh = subprocess.run(
    [cli_bin, "diagnostics", tex_path, "--bib", bib_path, "--registry-replay", reg_dir, "--lang", "zh"],
    env=env,
    capture_output=True,
    text=True,
)

if p_zh.returncode != 1:
    failures.append(f"expected ZH JSON exit code 1 on NOT_FOUND cited DOI, got {p_zh.returncode} (stderr={p_zh.stderr!r})")
if p_en.returncode != 1:
    failures.append(f"expected EN JSON exit code 1 on NOT_FOUND cited DOI, got {p_en.returncode} (stderr={p_en.stderr!r})")
if p_txt_zh.returncode != 1:
    failures.append(f"expected ZH text exit code 1 on NOT_FOUND cited DOI, got {p_txt_zh.returncode}")
if "ERR_UNVERIFIED_CITATION" not in p_txt_zh.stdout:
    failures.append(f"expected ERR_UNVERIFIED_CITATION in ZH text stdout: {p_txt_zh.stdout}")

zh_obj = json.loads(p_zh.stdout)
en_obj = json.loads(p_en.stdout)

if zh_obj.get("mode") != "REPLAY" or zh_obj.get("complete") is not True:
    failures.append(f"expected mode='REPLAY' and complete=True, got mode={zh_obj.get('mode')!r}, complete={zh_obj.get('complete')!r}")

zh_cite_diags = [d for d in zh_obj.get("diagnostics", []) if d.get("code") == "ERR_UNVERIFIED_CITATION"]
if len(zh_cite_diags) != 1 or zh_cite_diags[0].get("category") != "citation" or zh_cite_diags[0].get("severity") != "ERROR":
    failures.append(f"expected 1 ERROR ERR_UNVERIFIED_CITATION (category=citation), got {zh_cite_diags}")

zh_ver = ((zh_obj.get("citations") or [{}])[0]).get("verification") or {}
en_ver = ((en_obj.get("citations") or [{}])[0]).get("verification") or {}
zh_findings = zh_ver.get("findings") or []
en_findings = en_ver.get("findings") or []

if zh_ver.get("verdict") != "NOT_FOUND" or zh_ver.get("insertable") is not False:
    failures.append(f"expected verdict='NOT_FOUND' and insertable=False, got {zh_ver}")
if not any("未采信" in (f.get("detail") or "") for f in zh_findings):
    failures.append(f"expected '未采信' in ZH findings, got {zh_findings}")
if not any("not trusted" in (f.get("detail") or "").lower() for f in en_findings):
    failures.append(f"expected 'not trusted' in EN findings, got {en_findings}")

# Verify Scripts/acceptance/m1-acceptance.sh --row 18 passes with updated exit-code assertion
m1_env = dict(env)
m1_env["SCHOLAR_CLI_BIN"] = cli_bin
m1_env.pop("SCHOLAR_REPORT_DIR", None)
m1_script = os.path.join(repo_root, "Scripts", "acceptance", "m1-acceptance.sh")
p_m1 = subprocess.run(
    [m1_script, "--row", "18"],
    env=m1_env,
    capture_output=True,
    text=True,
)
if p_m1.returncode != 0 or "RESULT [Row 18]: PASS" not in p_m1.stdout:
    failures.append(f"m1-acceptance.sh --row 18 failed (exit={p_m1.returncode}):\n{p_m1.stdout}\n{p_m1.stderr}")

untrusted_detail_zh = next((f.get("detail") for f in zh_findings if "未采信" in (f.get("detail") or "")), None)
print(
    f"  [Row 14] diagnostics_exit={p_zh.returncode} | verdict={zh_ver.get('verdict')} | "
    f"ERR_UNVERIFIED_CITATION={len(zh_cite_diags)} (ERROR) | finding_zh={untrusted_detail_zh!r} | "
    f"m1_row18_exit={p_m1.returncode} (PASS)"
)

if failures:
    for msg in failures:
        print(f"  FAIL [Row 14]: {msg}")
    sys.exit(1)
sys.exit(0)
PY
)"
        ROW14_RC=$?
        set -e
        echo "$ROW14_OUT"
        if [[ "$ROW14_RC" -eq 0 ]]; then
            record_pass 14 "x-firewall-class={VERIFIED} fabricated DOI emits ERROR ERR_UNVERIFIED_CITATION with '未采信' in findings, exits 1, and m1-acceptance.sh Row 18 passes"
        else
            record_fail 14 "Row 14 untrusted x-firewall-class={VERIFIED} diagnostics --registry-replay or m1-acceptance.sh Row 18 check failed"
        fi
    fi

    # ==================================================================
    # Row 15: MCP scholar_lsp_diagnostics(path:) across all 11 manuscripts — byte-for-byte identical to CLI --json
    # ==================================================================
    if should_run_row 15; then
        echo "== [Row 15] MCP scholar_lsp_diagnostics(path:) 对 11 篇基准论文：返回对象与 CLI --json 逐字节相同 =="
        set +e
        ROW15_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$RUN1_DIR" <<'PY'
import csv, json, os, subprocess, sys

repo_root, cli_bin, sandbox_home, run1_dir = sys.argv[1:5]
env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

papers_tsv = os.path.join(repo_root, "Benchmarks", "manuscripts", "papers.tsv")
with open(papers_tsv, encoding="utf-8") as f:
    rows = list(csv.DictReader(f, delimiter="\t"))

if len(rows) != 11:
    print(f"  FAIL [Row 15]: expected 11 rows in papers.tsv, got {len(rows)}")
    sys.exit(1)

failures = []
cli_json_by_id = {}
rpc_lines = []

for idx, row in enumerate(rows, start=1):
    pid = f"{row['arxiv_id']}{row['version']}"
    main_tex = os.path.join(repo_root, "Benchmarks", "manuscripts", pid, "src", row["main_file"])
    cached_path = os.path.join(run1_dir, f"{pid}.json")
    if os.path.isfile(cached_path):
        raw_cli = open(cached_path, "rb").read()
    else:
        p_cli = subprocess.run(
            [cli_bin, "diagnostics", main_tex, "--offline", "--json", "--lang", "en"],
            env=env,
            capture_output=True,
        )
        if p_cli.returncode == 2:
            failures.append(f"[{pid}] CLI exited 2: {p_cli.stderr.decode('utf-8', 'replace')}")
            continue
        raw_cli = p_cli.stdout

    # ScholarOSMain prints result.stdout via Swift print(), appending a single trailing LF on OS stdout.
    if not raw_cli.endswith(b"\n"):
        failures.append(f"[{pid}] expected CLI stdout to end with single trailing LF")
        cli_json_bytes = raw_cli
    else:
        cli_json_bytes = raw_cli[:-1]

    cli_json_by_id[idx] = (pid, main_tex, cli_json_bytes)
    rpc_lines.append(
        json.dumps({
            "jsonrpc": "2.0",
            "id": idx,
            "method": "tools/call",
            "params": {
                "name": "scholar_lsp_diagnostics",
                "arguments": {"path": main_tex},
            },
        })
    )

p_mcp = subprocess.run(
    [cli_bin, "mcp", "--offline", "--lang", "en"],
    input=("\n".join(rpc_lines) + "\n").encode("utf-8"),
    env=env,
    capture_output=True,
)
if p_mcp.returncode != 0:
    print(f"  FAIL [Row 15]: MCP server exited {p_mcp.returncode}: {p_mcp.stderr.decode('utf-8', 'replace')}")
    sys.exit(1)

resp_by_id = {}
for raw_line in p_mcp.stdout.decode("utf-8").splitlines():
    line = raw_line.strip()
    if not line:
        continue
    env_obj = json.loads(line)
    resp_by_id[env_obj.get("id")] = env_obj

matched = 0
for idx in sorted(cli_json_by_id):
    pid, main_tex, cli_bytes = cli_json_by_id[idx]
    env_obj = resp_by_id.get(idx)
    if not env_obj:
        failures.append(f"[{pid}] missing JSON-RPC response for id={idx}")
        continue
    res_obj = env_obj.get("result") or {}
    if res_obj.get("isError") is not False:
        failures.append(f"[{pid}] MCP returned isError != False: {res_obj}")
        continue
    content = res_obj.get("content") or []
    if not content or not isinstance(content[0].get("text"), str):
        failures.append(f"[{pid}] missing text content in MCP response: {res_obj}")
        continue
    mcp_bytes = content[0]["text"].encode("utf-8")
    if mcp_bytes == cli_bytes:
        matched += 1
        print(f"  [{pid}] 逐字节相同 (bytes={len(mcp_bytes)})")
    else:
        first_diff = next((i for i, (a, b) in enumerate(zip(cli_bytes, mcp_bytes)) if a != b), min(len(cli_bytes), len(mcp_bytes)))
        failures.append(
            f"[{pid}] byte mismatch at offset {first_diff}: cli_bytes={len(cli_bytes)} vs mcp_bytes={len(mcp_bytes)}"
        )

# Also check --lang zh byte-for-byte parity between CLI --json --lang zh and MCP mcp --lang zh
zh_pid, zh_tex, _ = cli_json_by_id[6]  # 2503.18124v1
p_cli_zh = subprocess.run(
    [cli_bin, "diagnostics", zh_tex, "--offline", "--json", "--lang", "zh"],
    env=env,
    capture_output=True,
)
cli_zh_bytes = p_cli_zh.stdout[:-1] if p_cli_zh.stdout.endswith(b"\n") else p_cli_zh.stdout
zh_req = json.dumps({
    "jsonrpc": "2.0",
    "id": 101,
    "method": "tools/call",
    "params": {"name": "scholar_lsp_diagnostics", "arguments": {"path": zh_tex}},
}) + "\n"
p_mcp_zh = subprocess.run(
    [cli_bin, "mcp", "--offline", "--lang", "zh"],
    input=zh_req.encode("utf-8"),
    env=env,
    capture_output=True,
)
mcp_zh_env = json.loads(p_mcp_zh.stdout.decode("utf-8").strip().splitlines()[-1])
mcp_zh_bytes = mcp_zh_env["result"]["content"][0]["text"].encode("utf-8")
if mcp_zh_bytes != cli_zh_bytes:
    failures.append(f"[{zh_pid} --lang zh] byte mismatch: cli_bytes={len(cli_zh_bytes)} vs mcp_bytes={len(mcp_zh_bytes)}")
else:
    print(f"  [{zh_pid} --lang zh] 逐字节相同 (bytes={len(mcp_zh_bytes)})")

print(f"row15_mcp_byte_identical_papers={matched}/11")
if failures or matched != 11:
    for msg in failures:
        print(f"  FAIL [Row 15]: {msg}")
    sys.exit(1)
sys.exit(0)
PY
)"
        ROW15_RC=$?
        set -e
        echo "$ROW15_OUT"
        if [[ "$ROW15_RC" -eq 0 ]]; then
            record_pass 15 "MCP scholar_lsp_diagnostics(path:) returns JSON byte-for-byte identical to CLI --json across all 11 benchmark manuscripts (EN & ZH)"
        else
            record_fail 15 "Row 15 MCP scholar_lsp_diagnostics(path:) vs CLI --json byte-for-byte parity check failed"
        fi
    fi

    # ==================================================================
    # Rows 16..20: Deferred to Stage 08 / dispatcher (marked 没跑 / SKIPPED)
    # ==================================================================
    declare -a DEFERRED_ROWS_16_20=(
        "16:M1 全量回放不退步、禁网单元测试与 milestone 1 — 留给第 5、8 段"
        "17:源码变异检查 (a)-(e) — 留给第 8 段"
        "18:禁网沙箱 milestone 2 与 m2-acceptance.sh / hard-inputs.sh 耗时 — 留给第 8 段"
        "19:调度方 Tectonic m2-regen-expected.sh --check — 调度方专用，测试不调用"
        "20:跑后环境与工作区洁净检查 — 留给第 8 段"
    )

    for entry in "${DEFERRED_ROWS_16_20[@]}"; do
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
