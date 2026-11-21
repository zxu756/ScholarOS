#!/usr/bin/env bash
#
# M4 acceptance verification script (`Scripts/acceptance/m4-acceptance.sh`).
#
# Verifies all 11 rows of the M4 acceptance table in `04-scholaros.md` solely via the CLI
# subcommands (`locate-evidence`, `segment-pdf`) and MCP (`scholaros mcp --offline` -> `locate_evidence`)
# under an isolated `HOME` (`lib-cli-guard.sh`) with `--offline`:
#   - Row 1:  Naming & contract (`scholaros.evidence/1`, 3 verdicts, 1-based `page`, 0-based `page_index`,
#             `bounding_box`, `column_index`, `section_title`, `excerpt`, exit codes 0/1/3, 0 entailment terms)
#   - Row 2:  `claims.jsonl` `grounded` (10 claims) — >= 8/10 FOUND with `page` in `expected_pages`
#   - Row 3:  `claims.jsonl` `numeric_mismatch` (10 claims) — >= 8/10 NUMERIC_MISMATCH, `page` in
#             `expected_pages`, `discrepancies[].pdf_text` containing one of `ground_truth_numbers`
#             (ignoring whitespace and thousands-separator commas)
#   - Row 4:  `claims.jsonl` `not_mentioned` (10) + `sentinel` (15) — 25/25 NOT_FOUND, `matches == []`
#   - Row 5:  Bounding-box geometry against `expected_pdftotext/*.tsv.gz` (and live `pdftotext -tsv`
#             comparison when installed): width/height > 0, inside page `mediaBox`, non-full-page, and
#             >= 80% word coverage after +4pt expansion (PDF bottom-left -> TSV top-left transform)
#   - Row 6:  `segment-pdf --offline --json` on the 5 benchmark papers + 7 synthetic fixtures:
#             0 header/footer leaks in `body` chunks, Introduction + References headings recognized,
#             and left-before-right reading order below spanning tables/figures
#   - Row 7:  Word multiset overlap against `pdftotext` >= 95% on each of the 5 benchmark papers + timing
#   - Row 8:  MCP `tools/list` (5 default tools, `locate_evidence` present, `scholar_search_provenance`
#             absent & returns -32602), unknown arguments -> `ERR_INVALID_ARGUMENT`, and 0/45 diffs vs CLI `--json`
#   - Row 9:  Error handling (missing file, non-PDF bytes, corrupt PDF, blank PDF, empty claim -> exit 2,
#             empty stdout with `--json`, clear reason on stderr)
#   - Row 10: Read-only `git apply --check` across all 5 `m4-*.patch` files (`SKIP / 没跑`; full isolated
#             copy/apply/build/revert run via `Scripts/acceptance/m4-mutations.sh`)
#   - Row 11: Post-run hygiene (temp dirs cleaned, real `~/Library` free of new ScholarOS/Tectonic items,
#             `git diff --exit-code Benchmarks/`, and report free of host home paths and email addresses)
#
# Usage:
#   Scripts/acceptance/m4-acceptance.sh [--record] [--row <1..11>] [--rows <r1,r2,...>]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

M4_START_EPOCH="$(python3 -I -c 'import time; print(f"{time.time():.6f}")')"

RECORD=0
ONLY_ROW=""
SELECTED_ROWS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --record)
            RECORD=1
            shift
            ;;
        --row)
            if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ || "$2" -lt 1 || "$2" -gt 11 ]]; then
                echo "Usage: Scripts/acceptance/m4-acceptance.sh [--record] [--row <1..11>] [--rows <r1,r2,...>]" >&2
                exit 2
            fi
            ONLY_ROW="$2"
            shift 2
            ;;
        --row=*)
            val="${1#--row=}"
            if [[ ! "$val" =~ ^[0-9]+$ || "$val" -lt 1 || "$val" -gt 11 ]]; then
                echo "Usage: Scripts/acceptance/m4-acceptance.sh [--record] [--row <1..11>] [--rows <r1,r2,...>]" >&2
                exit 2
            fi
            ONLY_ROW="$val"
            shift
            ;;
        --rows)
            if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                echo "Usage: Scripts/acceptance/m4-acceptance.sh [--record] [--row <1..11>] [--rows <r1,r2,...>]" >&2
                exit 2
            fi
            SELECTED_ROWS="$2"
            shift 2
            ;;
        --rows=*)
            val="${1#--rows=}"
            if [[ ! "$val" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                echo "Usage: Scripts/acceptance/m4-acceptance.sh [--record] [--row <1..11>] [--rows <r1,r2,...>]" >&2
                exit 2
            fi
            SELECTED_ROWS="$val"
            shift
            ;;
        *)
            echo "Usage: Scripts/acceptance/m4-acceptance.sh [--record] [--row <1..11>] [--rows <r1,r2,...>]" >&2
            exit 2
            ;;
    esac
done

if [[ "$RECORD" -eq 1 ]]; then
    if [[ -n "$ONLY_ROW" || -n "$SELECTED_ROWS" ]]; then
        echo "ERROR: --record cannot be combined with --row or --rows." >&2
        exit 2
    fi
    if [[ -z "${SCHOLAR_REPORT_DIR:-}" || "${SCHOLAR_REPORT_DIR:-}" == "$REPO_ROOT/reports" ]]; then
        DIRTY_FOR_RECORD="$(git -C "$REPO_ROOT" status --porcelain)"
        if [[ -n "$DIRTY_FOR_RECORD" ]]; then
            echo "ERROR: --record requires a clean working tree before writing reports/m4-acceptance.txt:" >&2
            echo "$DIRTY_FOR_RECORD" >&2
            exit 2
        fi
    fi
fi

REAL_USER_HOME="$(python3 -I -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"

snapshot_real_home_library_scholaros() {
    python3 -I - "$REAL_USER_HOME" <<'PY'
import hashlib, os, sys

home = sys.argv[1]
entries = []
for sub in ("Caches", "Preferences", "Application Support"):
    base = os.path.join(home, "Library", sub)
    if not os.path.isdir(base):
        entries.append(f"{sub}:ABSENT")
        continue
    for name in sorted(os.listdir(base)):
        low = name.lower()
        if "scholaros" in low or "tectonic" in low:
            p = os.path.join(base, name)
            if os.path.isdir(p) and not os.path.islink(p):
                entries.append(f"{sub}/{name}:DIR")
                for root, dirs, files in os.walk(p):
                    dirs.sort()
                    for fn in sorted(files):
                        fp = os.path.join(root, fn)
                        rel = os.path.relpath(fp, base)
                        try:
                            st = os.lstat(fp)
                            entries.append(f"{sub}/{rel}:{st.st_size}:{st.st_mtime_ns}")
                        except OSError:
                            entries.append(f"{sub}/{rel}:ERR")
            else:
                try:
                    st = os.lstat(p)
                    entries.append(f"{sub}/{name}:{st.st_size}:{st.st_mtime_ns}")
                except OSError:
                    entries.append(f"{sub}/{name}:ERR")
print(hashlib.sha256("\n".join(entries).encode("utf-8")).hexdigest())
PY
}

snapshot_tmpdir_m4() {
    local exclude1="${1:-}"
    local exclude2="${2:-}"
    python3 -I - "${TMPDIR:-/tmp}" "$exclude1" "$exclude2" <<'PY'
import os, sys

tdir, ex1, ex2 = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.isdir(tdir):
    sys.exit(0)
prefixes = (
    "scholaros-m4-work.",
    "scholaros-m4-report.",
    "scholaros-m4-sub.",
    "m4-row9-",
)
excluded = {x for x in (ex1, ex2) if x}
items = sorted(n for n in os.listdir(tdir) if n.startswith(prefixes) and n not in excluded)
print("\n".join(items))
PY
}

HOME_LIB_SNAP_BEFORE="$(snapshot_real_home_library_scholaros)"
TMP_SNAP_BEFORE="$(snapshot_tmpdir_m4)"
BENCH_STATUS_BEFORE="$(git -C "$REPO_ROOT" status --porcelain -- Benchmarks || true)"
REPORTS_STATUS_BEFORE="$(git -C "$REPO_ROOT" status --porcelain -- reports || true)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m4-work.XXXXXX")"
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
PARENT_EXIT_TRAP="$(trap -p EXIT)"

if [[ -n "${SCHOLAR_REPORT_DIR:-}" ]]; then
    REPORT_DIR="$SCHOLAR_REPORT_DIR"
elif [[ "$RECORD" -eq 1 ]]; then
    REPORT_DIR="$REPO_ROOT/reports"
else
    CREATED_TEMP_REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m4-report.XXXXXX")"
    REPORT_DIR="$CREATED_TEMP_REPORT_DIR"
fi
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/m4-acceptance.txt"

export SCHOLAR_SANDBOX_HOME="$WORK/home"
mkdir -p "$SCHOLAR_SANDBOX_HOME/Library/Preferences" "$SCHOLAR_SANDBOX_HOME/Library/Caches"
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
    if [[ -n "$ONLY_ROW" ]]; then
        [[ "$ONLY_ROW" == "$r" ]]
        return
    fi
    if [[ -n "$SELECTED_ROWS" ]]; then
        [[ ",$SELECTED_ROWS," == *",$r,"* ]]
        return
    fi
    return 0
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

HARNESS_PY="$REPO_ROOT/Scripts/acceptance/m4_harness.py"
BIN_LABEL=".build/debug/ScholarOS"
if [[ "$SCHOLAR_CLI_BIN" == "$REPO_ROOT/"* ]]; then
    BIN_LABEL="${SCHOLAR_CLI_BIN#"$REPO_ROOT"/}"
fi

{
    echo "# ScholarOS M4 Acceptance Verification Report"
    echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Commit: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "Binary: $BIN_LABEL"
    echo "Mode: --offline (isolated HOME, SCHOLAR_CACHE_DIR unset)"
    echo ""

    # ==================================================================
    # Row 1: Naming & output contract (scholaros.evidence/1, 3 verdicts, exit codes, 0 entailment terms)
    # ==================================================================
    if should_run_row 1; then
        echo "== [Row 1] 命名和输出契约 (locate-evidence --json, --help 中英, MCP locate_evidence, 退出码 0/1/3) =="
        set +e
        python3 -I "$HARNESS_PY" row1 \
            --repo-root "$REPO_ROOT" \
            --cli-bin "$SCHOLAR_CLI_BIN" \
            --sandbox-home "$SCHOLAR_SANDBOX_HOME" \
            --cache-dir "$WORK_SCRATCH" >"$WORK/row1.out" 2>&1
        R1_RC=$?
        set -e
        cat "$WORK/row1.out"
        if [[ "$R1_RC" -eq 0 ]]; then
            record_pass 1 "schema=scholaros.evidence/1, verdicts={FOUND(0),NUMERIC_MISMATCH(1),NOT_FOUND(3)}, 0 entailment/GROUNDED terms"
        else
            record_fail 1 "Row 1 naming, schema, fields, or exit-code check failed"
        fi
    fi

    # ==================================================================
    # Row 2: 10 grounded claims (>= 8/10 FOUND & page in expected_pages)
    # ==================================================================
    if should_run_row 2; then
        echo "== [Row 2] Benchmarks/evidence/claims.jsonl 10 句有依据的论断 (要求 >= 8/10 FOUND 且页码命中 expected_pages) =="
        set +e
        python3 -I "$HARNESS_PY" row2 \
            --repo-root "$REPO_ROOT" \
            --cli-bin "$SCHOLAR_CLI_BIN" \
            --sandbox-home "$SCHOLAR_SANDBOX_HOME" \
            --cache-dir "$WORK_SCRATCH" >"$WORK/row2.out" 2>&1
        R2_RC=$?
        set -e
        cat "$WORK/row2.out"
        R2_SCORE="$(grep -Eo 'score=[0-9]+/[0-9]+' "$WORK/row2.out" | tail -n 1 | cut -d= -f2 || echo '0/10')"
        if [[ "$R2_RC" -eq 0 ]]; then
            record_pass 2 "Grounded claims: $R2_SCORE FOUND on expected_pages (threshold >= 8/10)"
        else
            record_fail 2 "Grounded claims: $R2_SCORE FOUND on expected_pages (threshold >= 8/10)"
        fi
    fi

    # ==================================================================
    # Row 3: 10 numeric_mismatch claims (>= 8/10 NUMERIC_MISMATCH, page ok, pdf_text contains ground_truth_numbers)
    # ==================================================================
    if should_run_row 3; then
        echo "== [Row 3] Benchmarks/evidence/claims.jsonl 10 句数字不同的论断 (要求 >= 8/10 NUMERIC_MISMATCH、页码对、pdf_text 含原文数字) =="
        set +e
        python3 -I "$HARNESS_PY" row3 \
            --repo-root "$REPO_ROOT" \
            --cli-bin "$SCHOLAR_CLI_BIN" \
            --sandbox-home "$SCHOLAR_SANDBOX_HOME" \
            --cache-dir "$WORK_SCRATCH" >"$WORK/row3.out" 2>&1
        R3_RC=$?
        set -e
        cat "$WORK/row3.out"
        R3_SCORE="$(grep -Eo 'score=[0-9]+/[0-9]+' "$WORK/row3.out" | tail -n 1 | cut -d= -f2 || echo '0/10')"
        if [[ "$R3_RC" -eq 0 ]]; then
            record_pass 3 "Numeric-mismatch claims: $R3_SCORE NUMERIC_MISMATCH with expected_pages & ground_truth_numbers (threshold >= 8/10)"
        else
            record_fail 3 "Numeric-mismatch claims: $R3_SCORE NUMERIC_MISMATCH with expected_pages & ground_truth_numbers (threshold >= 8/10)"
        fi
    fi

    # ==================================================================
    # Row 4: 10 not_mentioned + 15 sentinel claims (25/25 NOT_FOUND, matches == [])
    # ==================================================================
    if should_run_row 4; then
        echo "== [Row 4] 10 句未提及论断 + 15 行中英文哨兵 (要求 25/25 NOT_FOUND 且 matches 为空) =="
        set +e
        python3 -I "$HARNESS_PY" row4 \
            --repo-root "$REPO_ROOT" \
            --cli-bin "$SCHOLAR_CLI_BIN" \
            --sandbox-home "$SCHOLAR_SANDBOX_HOME" \
            --cache-dir "$WORK_SCRATCH" >"$WORK/row4.out" 2>&1
        R4_RC=$?
        set -e
        cat "$WORK/row4.out"
        R4_SCORE="$(grep -Eo 'total=[0-9]+/[0-9]+' "$WORK/row4.out" | tail -n 1 | cut -d= -f2 || echo '0/25')"
        if [[ "$R4_RC" -eq 0 ]]; then
            record_pass 4 "Not-mentioned & sentinels: $R4_SCORE NOT_FOUND with empty matches (0 tolerance)"
        else
            record_fail 4 "Not-mentioned & sentinels: $R4_SCORE NOT_FOUND with empty matches (required 25/25)"
        fi
    fi

    # ==================================================================
    # Row 5: Bounding-box geometry vs expected_pdftotext/*.tsv.gz (+4pt -> >= 80% words)
    # ==================================================================
    if should_run_row 5; then
        echo "== [Row 5] 位置框几何真实性 (对照 expected_pdftotext/*.tsv.gz，外扩 4pt 覆盖段落 >= 80% 词) =="
        set +e
        python3 -I "$HARNESS_PY" row5 \
            --repo-root "$REPO_ROOT" \
            --cli-bin "$SCHOLAR_CLI_BIN" \
            --sandbox-home "$SCHOLAR_SANDBOX_HOME" \
            --cache-dir "$WORK_SCRATCH" >"$WORK/row5.out" 2>&1
        R5_RC=$?
        set -e
        cat "$WORK/row5.out"
        R5_SUMMARY="$(grep -Eo 'boxes_verified=[0-9]+/[0-9]+ \(min_word_coverage=[0-9.]+%' "$WORK/row5.out" | tail -n 1 || echo 'boxes_verified=0/0')"
        if [[ "$R5_RC" -eq 0 ]]; then
            record_pass 5 "Bounding boxes verified: $R5_SUMMARY, required >= 80.0%)"
        else
            record_fail 5 "Bounding boxes failed: $R5_SUMMARY, required >= 80.0%)"
        fi
    fi

    # ==================================================================
    # Row 6: PDF segmentation on 5 benchmark papers + 7 synthetic fixtures
    # ==================================================================
    if should_run_row 6; then
        echo "== [Row 6] 5 份评测论文与 7 份合成夹具分段 (页眉页脚不进正文、引言与参考文献识别、通栏表下先左后右) =="
        set +e
        python3 -I "$HARNESS_PY" row6 \
            --repo-root "$REPO_ROOT" \
            --cli-bin "$SCHOLAR_CLI_BIN" \
            --sandbox-home "$SCHOLAR_SANDBOX_HOME" \
            --cache-dir "$WORK_SCRATCH" >"$WORK/row6.out" 2>&1
        R6_RC=$?
        set -e
        cat "$WORK/row6.out"
        R6_SUMMARY="$(grep -Eo 'benchmark_papers=[0-9]+/5 synthetic_fixtures=[0-9]+/7' "$WORK/row6.out" | tail -n 1 || echo 'benchmark_papers=0/5 synthetic_fixtures=0/7')"
        if [[ "$R6_RC" -eq 0 ]]; then
            record_pass 6 "Segmentation verified ($R6_SUMMARY; 0 header/footer body leaks, Intro+Refs recognized, col1<col2)"
        else
            record_fail 6 "Segmentation check failed ($R6_SUMMARY)"
        fi
    fi

    # ==================================================================
    # Row 7: Word multiset overlap vs pdftotext (>= 95% on all 5 benchmark papers)
    # ==================================================================
    if should_run_row 7; then
        echo "== [Row 7] 提取文字与 pdftotext 词重合率 (5 份评测论文每份 >= 95%，记录百分比与耗时) =="
        set +e
        python3 -I "$HARNESS_PY" row7 \
            --repo-root "$REPO_ROOT" \
            --cli-bin "$SCHOLAR_CLI_BIN" \
            --sandbox-home "$SCHOLAR_SANDBOX_HOME" \
            --cache-dir "$WORK_SCRATCH" >"$WORK/row7.out" 2>&1
        R7_RC=$?
        set -e
        cat "$WORK/row7.out"
        R7_SUMMARY="$(grep -Eo 'papers_passed=[0-9]+/5 min_word_overlap=[0-9.]+%' "$WORK/row7.out" | tail -n 1 || echo 'papers_passed=0/5')"
        if [[ "$R7_RC" -eq 0 ]]; then
            record_pass 7 "Word overlap verified ($R7_SUMMARY, required >= 95.00%)"
        else
            record_fail 7 "Word overlap check failed ($R7_SUMMARY, required >= 95.00%)"
        fi
    fi

    # ==================================================================
    # Row 8: MCP tools/list & 45-claim parity vs CLI --json
    # ==================================================================
    if should_run_row 8; then
        echo "== [Row 8] MCP tools/list 与全部 45 行逐条调用对照 CLI --json =="
        set +e
        python3 -I "$HARNESS_PY" row8 \
            --repo-root "$REPO_ROOT" \
            --cli-bin "$SCHOLAR_CLI_BIN" \
            --sandbox-home "$SCHOLAR_SANDBOX_HOME" \
            --cache-dir "$WORK_SCRATCH" >"$WORK/row8.out" 2>&1
        R8_RC=$?
        set -e
        cat "$WORK/row8.out"
        R8_DIFFS="$(grep -Eo 'cli_vs_mcp_diffs=[0-9]+/45' "$WORK/row8.out" | tail -n 1 || echo 'cli_vs_mcp_diffs=?/45')"
        if [[ "$R8_RC" -eq 0 ]]; then
            record_pass 8 "MCP default_tools=5, locate_evidence present, scholar_search_provenance removed, $R8_DIFFS, ERR_INVALID_ARGUMENT verified"
        else
            record_fail 8 "MCP tools/list or 45-claim parity check failed ($R8_DIFFS)"
        fi
    fi

    # ==================================================================
    # Row 9: Error handling (missing file, non-PDF bytes, blank PDF, empty claim -> exit 2)
    # ==================================================================
    if should_run_row 9; then
        echo "== [Row 9] 错误处理 (文件不存在、非 PDF 字节、空白 PDF、空论断 -> 退出码 2、--json stdout 为空、stderr 写明原因) =="
        set +e
        python3 -I "$HARNESS_PY" row9 \
            --repo-root "$REPO_ROOT" \
            --cli-bin "$SCHOLAR_CLI_BIN" \
            --sandbox-home "$SCHOLAR_SANDBOX_HOME" \
            --cache-dir "$WORK_SCRATCH" >"$WORK/row9.out" 2>&1
        R9_RC=$?
        set -e
        cat "$WORK/row9.out"
        R9_SCORE="$(grep -Eo 'error_cases_passed=[0-9]+/[0-9]+' "$WORK/row9.out" | tail -n 1 || echo 'error_cases_passed=0/9')"
        if [[ "$R9_RC" -eq 0 ]]; then
            record_pass 9 "Error handling verified ($R9_SCORE, exit=2, --json stdout empty, stderr non-empty)"
        else
            record_fail 9 "Error handling check failed ($R9_SCORE)"
        fi
    fi

    # ==================================================================
    # Row 10: Read-only check of 5 M4 mutation patches (full run via Scripts/acceptance/m4-mutations.sh)
    # ==================================================================
    if should_run_row 10; then
        echo "== [Row 10] 变异补丁静态核验 (5 个 m4-*.patch git apply --check；完整副本编译重跑由 Scripts/acceptance/m4-mutations.sh 执行) =="
        R10_OK=1
        MUT_SCRIPT="$REPO_ROOT/Scripts/acceptance/m4-mutations.sh"
        declare -a M4_PATCHES=(
            "m4-01-disable-header-footer-strip.patch"
            "m4-02-lower-keyword-threshold-005.patch"
            "m4-03-disable-same-noun-agreement.patch"
            "m4-04-mcp-skip-numeric-check.patch"
            "m4-05-full-page-bounding-box.patch"
        )
        if [[ ! -x "$MUT_SCRIPT" ]]; then
            echo "  FAIL [Row 10]: Missing or non-executable Scripts/acceptance/m4-mutations.sh"
            R10_OK=0
        elif ! bash -n "$MUT_SCRIPT"; then
            echo "  FAIL [Row 10]: bash -n syntax check failed on Scripts/acceptance/m4-mutations.sh"
            R10_OK=0
        fi
        for p_name in "${M4_PATCHES[@]}"; do
            p_path="$REPO_ROOT/Scripts/acceptance/mutations/$p_name"
            if [[ ! -f "$p_path" ]]; then
                echo "  FAIL [Row 10]: Missing mutation patch Scripts/acceptance/mutations/$p_name"
                R10_OK=0
            elif ! git -C "$REPO_ROOT" apply --check "$p_path" >"$WORK/r10-${p_name}.err" 2>&1; then
                echo "  FAIL [Row 10]: git apply --check failed for $p_name:"
                cat "$WORK/r10-${p_name}.err" || true
                R10_OK=0
            else
                echo "  [OK] Scripts/acceptance/mutations/$p_name passed git apply --check"
            fi
        done

        if [[ "$R10_OK" -ne 1 ]]; then
            record_fail 10 "M4 mutation patches or m4-mutations.sh failed git apply --check / syntax check"
        else
            echo "SKIP: 没跑 — 5 个 m4-*.patch 补丁已通过 git apply --check 校验；临时副本打补丁、编译与逐行验红由 Scripts/acceptance/m4-mutations.sh 单独运行"
            record_skip 10 "All 5 m4-*.patch files verified clean with git apply --check; run Scripts/acceptance/m4-mutations.sh standalone"
        fi
    fi

    # ==================================================================
    # Row 11: Post-run hygiene (real ~/Library ScholarOS entries, temp dirs, Benchmarks/ git diff)
    # ==================================================================
    if should_run_row 11; then
        echo "== [Row 11] 卫生检查 (真实 ~/Library 无新增 ScholarOS 条目、临时目录清理、git diff --exit-code Benchmarks/) =="
        rm -rf "$WORK_SCRATCH"
        HOME_LIB_SNAP_AFTER="$(snapshot_real_home_library_scholaros)"
        OWN_WORK_BASE="$(basename "$WORK")"
        OWN_REPORT_BASE=""
        if [[ -n "$CREATED_TEMP_REPORT_DIR" ]]; then
            OWN_REPORT_BASE="$(basename "$CREATED_TEMP_REPORT_DIR")"
        fi
        TMP_SNAP_AFTER="$(snapshot_tmpdir_m4 "$OWN_WORK_BASE" "$OWN_REPORT_BASE")"
        BENCH_STATUS_AFTER="$(git -C "$REPO_ROOT" status --porcelain -- Benchmarks || true)"
        REPORTS_STATUS_AFTER="$(git -C "$REPO_ROOT" status --porcelain -- reports || true)"
        set +e
        git -C "$REPO_ROOT" diff --exit-code -- Benchmarks >/dev/null 2>&1
        BENCH_DIFF_EXIT=$?
        set -e

        R11_OK=1
        if [[ -e "$WORK_SCRATCH" || -z "$PARENT_EXIT_TRAP" ]]; then
            echo "  FAIL [Row 11]: WORK_SCRATCH was not removed or EXIT cleanup trap is missing"
            R11_OK=0
        fi
        if [[ "$TMP_SNAP_BEFORE" != "$TMP_SNAP_AFTER" ]]; then
            echo "  FAIL [Row 11]: stray temporary directories left in TMPDIR (before='$TMP_SNAP_BEFORE' after='$TMP_SNAP_AFTER')"
            R11_OK=0
        fi
        if [[ "$HOME_LIB_SNAP_BEFORE" != "$HOME_LIB_SNAP_AFTER" ]]; then
            echo "  FAIL [Row 11]: real ~/Library (Caches / Preferences / Application Support) ScholarOS/Tectonic entries changed"
            R11_OK=0
        fi
        if [[ "$BENCH_DIFF_EXIT" -ne 0 || "$BENCH_STATUS_BEFORE" != "$BENCH_STATUS_AFTER" ]]; then
            echo "  FAIL [Row 11]: Benchmarks/ was modified during the run (diff_exit=$BENCH_DIFF_EXIT)"
            R11_OK=0
        fi
        if [[ "$RECORD" -eq 0 && "$REPORTS_STATUS_BEFORE" != "$REPORTS_STATUS_AFTER" ]]; then
            echo "  FAIL [Row 11]: reports/ was modified without --record"
            R11_OK=0
        fi

        M4_ELAPSED="$(python3 -I -c 'import sys, time; print(f"{time.time() - float(sys.argv[1]):.2f}")' "$M4_START_EPOCH")"
        echo "  scratch_cleaned=$([[ ! -e "$WORK_SCRATCH" ]] && echo true || echo false) tmp_clean=$([[ "$TMP_SNAP_BEFORE" == "$TMP_SNAP_AFTER" ]] && echo true || echo false) real_library_scholaros_untouched=$([[ "$HOME_LIB_SNAP_BEFORE" == "$HOME_LIB_SNAP_AFTER" ]] && echo true || echo false) benchmarks_diff_exit=$BENCH_DIFF_EXIT reports_untouched=$([[ "$RECORD" -eq 1 || "$REPORTS_STATUS_BEFORE" == "$REPORTS_STATUS_AFTER" ]] && echo true || echo false) elapsed=${M4_ELAPSED}s"
        if [[ "$R11_OK" -eq 1 ]]; then
            record_pass 11 "Temporary directories cleaned, real ~/Library free of new ScholarOS items, and git diff --exit-code Benchmarks/ passed (elapsed=${M4_ELAPSED}s)"
        else
            record_fail 11 "Row 11 post-run hygiene check failed"
        fi
    fi

    echo "========================================================================"
    echo "M4 Acceptance Summary:"
    sed 's/^/  /' "$SUMMARY_FILE"
    echo "------------------------------------------------------------------------"
    echo "Passed: $PASSED_COUNT | Failed: $FAILED_COUNT | Skipped (没跑): $SKIPPED_COUNT"
    echo "========================================================================"
    echo "$PASSED_COUNT" > "$WORK/passed-count.txt"
    echo "$FAILED_COUNT" > "$WORK/failed-count.txt"
    echo "$SKIPPED_COUNT" > "$WORK/skipped-count.txt"
} | tee "$REPORT_FILE"

python3 -I "$HARNESS_PY" scrub-file \
    --file "$REPORT_FILE" \
    --real-home "$REAL_USER_HOME" \
    --repo-root "$REPO_ROOT"

HOME_DIR_PREFIX="/Use""rs/"
if grep -Eq "${HOME_DIR_PREFIX}[A-Za-z0-9._-]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}" "$REPORT_FILE"; then
    echo "FAIL: $REPORT_FILE still contains a local home path or email address after scrubbing" >&2
    exit 1
fi

if [[ -z "$CREATED_TEMP_REPORT_DIR" ]]; then
    echo "[m4-acceptance] report written to reports/m4-acceptance.txt" >&2
fi

FINAL_PASSED="$(cat "$WORK/passed-count.txt")"
FINAL_FAILED="$(cat "$WORK/failed-count.txt")"
FINAL_SKIPPED="$(cat "$WORK/skipped-count.txt")"
if [[ "$FINAL_FAILED" -gt 0 ]]; then
    exit 1
fi
if [[ "$FINAL_PASSED" -eq 0 && "$FINAL_SKIPPED" -gt 0 ]]; then
    exit 2
fi
exit 0
