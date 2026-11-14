#!/usr/bin/env bash
#
# M0 acceptance: replays the ten rows of the M0 acceptance table plus the supplementary rows
# added by the 2026-11-14 review, in --lang en and --lang zh where output text is involved.
#
# This script never starts the graphical interface. Every product invocation goes through the
# `scholaros` shell function from lib-cli-guard.sh, which refuses argument lists that would open
# a window and runs the binary with a throwaway home directory. The default state of the
# interface (row 9) is checked through a windowless ViewModel unit test.
#
# Usage:
#   Scripts/acceptance/m0-acceptance.sh            report goes to a temporary directory
#   Scripts/acceptance/m0-acceptance.sh --record   report overwrites reports/m0-acceptance.txt
#
# Environment:
#   SCHOLAR_REPORT_DIR   directory for the report (set by Scripts/test.sh); overrides the default
#   SCHOLAR_BUILD_JOBS   optional cap for `swift build` / `swift test` parallelism (e.g. 3)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

RECORD=0
for arg in "$@"; do
    case "$arg" in
        --record) RECORD=1 ;;
        *)
            echo "Usage: Scripts/acceptance/m0-acceptance.sh [--record]" >&2
            exit 2
            ;;
    esac
done

WORK="$(mktemp -d)"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

if [[ -n "${SCHOLAR_REPORT_DIR:-}" ]]; then
    REPORT_DIR="$SCHOLAR_REPORT_DIR"
elif [[ "$RECORD" -eq 1 ]]; then
    REPORT_DIR="$REPO_ROOT/reports"
else
    REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m0-report.XXXXXX")"
fi
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/m0-acceptance.txt"

export SCHOLAR_SANDBOX_HOME="$WORK/home"
mkdir -p "$SCHOLAR_SANDBOX_HOME"
export SCHOLAR_CLI_BIN="$REPO_ROOT/.build/debug/ScholarOS"
# shellcheck source=Scripts/acceptance/lib-cli-guard.sh
source "$REPO_ROOT/Scripts/acceptance/lib-cli-guard.sh"

swift build >/dev/null

# Fictional IEEEtran-style sample manuscript that lives in this repository (see its header comment).
FIXTURE_REL="Fixtures/sample-ieeetran-manuscript.tex"
FIXTURE_TEX="$REPO_ROOT/$FIXTURE_REL"

# The 12-entry recheck bibliography (3 real, 2 fabricated DOIs, 3 real DOIs with a wrong title or year,
# 2 without DOI, 2 retracted). It is a copy of the acceptance harness file and lives in Fixtures/.
BIB_FIXTURE_REL="Fixtures/citations-m0-recheck.bib"
if [[ ! -f "$REPO_ROOT/$BIB_FIXTURE_REL" ]]; then
    echo "FAIL: bibliography fixture not found at $BIB_FIXTURE_REL" >&2
    exit 1
fi
cp "$REPO_ROOT/$BIB_FIXTURE_REL" "$WORK/refs.bib"

# Runs one named unit test and prints its real exit status; fails unless the test ran and passed.
run_named_unit_test() {
    local label="$1"
    local filter="$2"
    local expected_name_prefix="$3"
    local out
    local status
    set +e
    out="$(swift test --no-parallel --filter "$filter" 2>&1)"
    status=$?
    set -e
    echo "${label}_test_exit=$status"
    printf '%s\n' "$out" | grep -E "Test \"${expected_name_prefix}.*\" (passed|failed)|Test run with" || true
    if [[ "$status" -ne 0 ]]; then
        printf '%s\n' "$out" | tail -n 40
        echo "FAIL: unit test '$filter' failed"
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -q -E "Test \"${expected_name_prefix}.*\" passed"; then
        echo "FAIL: unit test '$filter' did not run (filter matched nothing)"
        exit 1
    fi
}

{
    echo "# ScholarOS M0 Acceptance Verification Report (Bilingual: --lang en & --lang zh)"
    echo "Date: $(date +%Y-%m-%d)"
    echo "Platform: $(uname -s) $(uname -m)"
    echo ""

    # ------------------------------------------------------------------
    # Row 1: scholaros --help & scholaros outline <.tex fixture> (--lang en & --lang zh)
    # ------------------------------------------------------------------
    echo "== [Row 1] scholaros --help & scholaros outline $FIXTURE_REL (--lang en & --lang zh) =="
    if [[ ! -f "$FIXTURE_TEX" ]]; then
        echo "FAIL: TeX fixture not found at $FIXTURE_REL"
        exit 1
    fi
    HELP_EN_OUT="$(scholaros --help --lang en)"
    HELP_EN_EXIT=$?
    HELP_ZH_OUT="$(scholaros --help --lang zh)"
    HELP_ZH_EXIT=$?
    OUTLINE_EN_OUT="$(scholaros outline "$FIXTURE_TEX" --lang en)"
    OUTLINE_EN_EXIT=$?
    OUTLINE_ZH_OUT="$(scholaros outline "$FIXTURE_TEX" --lang zh)"
    OUTLINE_ZH_EXIT=$?
    OUTLINE_EN_COUNT="$(printf '%s\n' "$OUTLINE_EN_OUT" | sed '/^$/d' | wc -l | tr -d ' ')"
    OUTLINE_ZH_COUNT="$(printf '%s\n' "$OUTLINE_ZH_OUT" | sed '/^$/d' | wc -l | tr -d ' ')"
    GREP_COUNT="$(grep -c -E '\\(section|subsection)\*?\{' "$FIXTURE_TEX" | tr -d ' ')"
    FIXTURE_LINES="$(wc -l < "$FIXTURE_TEX" | tr -d ' ')"
    echo "help_en_exit=$HELP_EN_EXIT help_zh_exit=$HELP_ZH_EXIT"
    echo "outline_en_exit=$OUTLINE_EN_EXIT outline_zh_exit=$OUTLINE_ZH_EXIT"
    echo "fixture=$FIXTURE_REL fixture_line_count=$FIXTURE_LINES"
    echo "outline_en_heading_count=$OUTLINE_EN_COUNT outline_zh_heading_count=$OUTLINE_ZH_COUNT"
    echo "grep_section_subsection_count=$GREP_COUNT"
    if [[ "$HELP_EN_EXIT" -ne 0 || "$HELP_ZH_EXIT" -ne 0 || "$OUTLINE_EN_EXIT" -ne 0 || "$OUTLINE_ZH_EXIT" -ne 0 || "$OUTLINE_EN_COUNT" != "$GREP_COUNT" || "$OUTLINE_ZH_COUNT" != "$GREP_COUNT" ]]; then
        echo "FAIL: Row 1 mismatch"
        exit 1
    fi
    if [[ "$GREP_COUNT" -lt 10 ]]; then
        echo "FAIL: Row 1 fixture has too few headings to be a meaningful check"
        exit 1
    fi
    if ! printf '%s\n' "$HELP_ZH_OUT" | grep -q "单文件直读命令"; then
        echo "FAIL: Row 1 expected localized Chinese help banner"
        exit 1
    fi
    # The numbers both READMEs quote for this fixture must be the ones measured above.
    for README_FILE in README.md README.zh-CN.md; do
        README_SENTENCE="$(grep -F "$FIXTURE_REL" "$REPO_ROOT/$README_FILE" || true)"
        if ! printf '%s\n' "$README_SENTENCE" | grep -q -F "$FIXTURE_LINES" || ! printf '%s\n' "$README_SENTENCE" | grep -q -F "\`$GREP_COUNT\`"; then
            echo "FAIL: Row 1 $README_FILE does not quote fixture_line_count=$FIXTURE_LINES and heading count $GREP_COUNT next to $FIXTURE_REL"
            exit 1
        fi
    done
    echo "readme_numbers_match_fixture=true"
    echo "PASS: Row 1"
    echo ""

    # ------------------------------------------------------------------
    # Row 2: Missing input -> exit code 2, zero demo output on stdout (--lang en & --lang zh)
    # ------------------------------------------------------------------
    echo "== [Row 2] scholaros outline & scholaros verify-citations (missing input, --lang en & --lang zh) =="
    set +e
    OUTLINE_EN_NOARG_STDOUT="$(scholaros outline --lang en 2>"$WORK/outline_en_noarg.stderr")"
    OUTLINE_EN_NOARG_EXIT=$?
    OUTLINE_ZH_NOARG_STDOUT="$(scholaros outline --lang zh 2>"$WORK/outline_zh_noarg.stderr")"
    OUTLINE_ZH_NOARG_EXIT=$?
    VERIFY_EN_NOARG_STDOUT="$(scholaros verify-citations --lang en 2>"$WORK/verify_en_noarg.stderr")"
    VERIFY_EN_NOARG_EXIT=$?
    VERIFY_ZH_NOARG_STDOUT="$(scholaros verify-citations --lang zh 2>"$WORK/verify_zh_noarg.stderr")"
    VERIFY_ZH_NOARG_EXIT=$?
    set -e
    echo "outline_en_noarg_exit=$OUTLINE_EN_NOARG_EXIT stdout_bytes=${#OUTLINE_EN_NOARG_STDOUT} stderr=$(tr '\n' ' ' < "$WORK/outline_en_noarg.stderr")"
    echo "outline_zh_noarg_exit=$OUTLINE_ZH_NOARG_EXIT stdout_bytes=${#OUTLINE_ZH_NOARG_STDOUT} stderr=$(tr '\n' ' ' < "$WORK/outline_zh_noarg.stderr")"
    echo "verify_en_noarg_exit=$VERIFY_EN_NOARG_EXIT stdout_bytes=${#VERIFY_EN_NOARG_STDOUT} stderr=$(tr '\n' ' ' < "$WORK/verify_en_noarg.stderr")"
    echo "verify_zh_noarg_exit=$VERIFY_ZH_NOARG_EXIT stdout_bytes=${#VERIFY_ZH_NOARG_STDOUT} stderr=$(tr '\n' ' ' < "$WORK/verify_zh_noarg.stderr")"
    if [[ "$OUTLINE_EN_NOARG_EXIT" -ne 2 || -n "$OUTLINE_EN_NOARG_STDOUT" || "$OUTLINE_ZH_NOARG_EXIT" -ne 2 || -n "$OUTLINE_ZH_NOARG_STDOUT" || "$VERIFY_EN_NOARG_EXIT" -ne 2 || -n "$VERIFY_EN_NOARG_STDOUT" || "$VERIFY_ZH_NOARG_EXIT" -ne 2 || -n "$VERIFY_ZH_NOARG_STDOUT" ]]; then
        echo "FAIL: Row 2 expected exit 2 and empty stdout across --lang en and --lang zh"
        exit 1
    fi
    if ! grep -q "Usage:" "$WORK/verify_en_noarg.stderr" || ! grep -q "用法：" "$WORK/verify_zh_noarg.stderr"; then
        echo "FAIL: Row 2 expected localized Usage / 用法 on stderr"
        exit 1
    fi
    echo "PASS: Row 2"
    echo ""

    # ------------------------------------------------------------------
    # Row 3: scholaros verify-citations refs.bib --offline (--lang en & --lang zh)
    # ------------------------------------------------------------------
    echo "== [Row 3] scholaros verify-citations $BIB_FIXTURE_REL --offline (--lang en & --lang zh) =="
    set +e
    OFFLINE_EN_OUT="$(scholaros verify-citations "$WORK/refs.bib" --offline --lang en 2>&1)"
    OFFLINE_EN_EXIT=$?
    OFFLINE_ZH_OUT="$(scholaros verify-citations "$WORK/refs.bib" --offline --lang zh 2>&1)"
    OFFLINE_ZH_EXIT=$?
    set -e
    echo "offline_en_exit=$OFFLINE_EN_EXIT"
    echo "$OFFLINE_EN_OUT"
    echo "--- (--lang zh) ---"
    echo "offline_zh_exit=$OFFLINE_ZH_EXIT"
    echo "$OFFLINE_ZH_OUT"
    if [[ "$OFFLINE_EN_EXIT" -eq 0 || "$OFFLINE_ZH_EXIT" -eq 0 ]]; then
        echo "FAIL: Row 3 expected non-zero exit code in both languages"
        exit 1
    fi
    for OUT_BLOB in "$OFFLINE_EN_OUT" "$OFFLINE_ZH_OUT"; do
        if ! printf '%s\n' "$OUT_BLOB" | grep -q "Verified=0"; then
            echo "FAIL: Row 3 expected Verified=0"
            exit 1
        fi
        if printf '%s\n' "$OUT_BLOB" | grep -q "\[VERIFIED\]"; then
            echo "FAIL: Row 3 found unexpected [VERIFIED] entry"
            exit 1
        fi
    done
    if ! printf '%s\n' "$OFFLINE_ZH_OUT" | grep -q "尚未向外部注册库核查"; then
        echo "FAIL: Row 3 expected honest Chinese not-checked notice"
        exit 1
    fi
    if ! printf '%s\n' "$OFFLINE_EN_OUT" | grep -q "Not checked against any external registry"; then
        echo "FAIL: Row 3 expected honest English not-checked notice"
        exit 1
    fi
    echo "PASS: Row 3"
    echo ""

    # ------------------------------------------------------------------
    # Row 4: sandbox-exec network denial without --offline (--lang en & --lang zh)
    # ------------------------------------------------------------------
    echo "== [Row 4] sandbox-exec deny network* scholaros verify-citations $BIB_FIXTURE_REL, no --offline (--lang en & --lang zh) =="
    set +e
    SANDBOX_EN_OUT="$(HOME="$SCHOLAR_SANDBOX_HOME" CFFIXED_USER_HOME="$SCHOLAR_SANDBOX_HOME" sandbox-exec -p '(version 1)(allow default)(deny network*)' "$SCHOLAR_CLI_BIN" verify-citations "$WORK/refs.bib" --lang en 2>&1)"
    SANDBOX_EN_EXIT=$?
    SANDBOX_ZH_OUT="$(HOME="$SCHOLAR_SANDBOX_HOME" CFFIXED_USER_HOME="$SCHOLAR_SANDBOX_HOME" sandbox-exec -p '(version 1)(allow default)(deny network*)' "$SCHOLAR_CLI_BIN" verify-citations "$WORK/refs.bib" --lang zh 2>&1)"
    SANDBOX_ZH_EXIT=$?
    NOFLAG_EN_OUT="$(scholaros verify-citations "$WORK/refs.bib" --lang en 2>&1)"
    NOFLAG_EN_EXIT=$?
    NOFLAG_ZH_OUT="$(scholaros verify-citations "$WORK/refs.bib" --lang zh 2>&1)"
    NOFLAG_ZH_EXIT=$?
    set -e
    echo "sandbox_en_exit=$SANDBOX_EN_EXIT sandbox_zh_exit=$SANDBOX_ZH_EXIT"
    echo "$SANDBOX_EN_OUT"
    if [[ "$SANDBOX_EN_EXIT" -eq 0 || "$SANDBOX_ZH_EXIT" -eq 0 ]]; then
        echo "FAIL: Row 4 expected non-zero exit code"
        exit 1
    fi
    for OUT_BLOB in "$SANDBOX_EN_OUT" "$SANDBOX_ZH_OUT"; do
        if ! printf '%s\n' "$OUT_BLOB" | grep -q "Verified=0"; then
            echo "FAIL: Row 4 expected Verified=0"
            exit 1
        fi
        if printf '%s\n' "$OUT_BLOB" | grep -q "\[VERIFIED\]"; then
            echo "FAIL: Row 4 found unexpected [VERIFIED] entry"
            exit 1
        fi
    done
    if [[ "$SANDBOX_EN_OUT" != "$NOFLAG_EN_OUT" || "$SANDBOX_ZH_OUT" != "$NOFLAG_ZH_OUT" || "$NOFLAG_EN_EXIT" -ne "$SANDBOX_EN_EXIT" || "$NOFLAG_ZH_EXIT" -ne "$SANDBOX_ZH_EXIT" ]]; then
        echo "FAIL: Row 4 output with the network denied differs from output with the network allowed"
        exit 1
    fi
    echo "network_denied_output_identical_to_network_allowed=true"
    echo "PASS: Row 4"
    echo ""

    # ------------------------------------------------------------------
    # Row 5: Unit test injecting transport error, HTTP 429, HTTP 500 -> UNVERIFIED
    # ------------------------------------------------------------------
    echo "== [Row 5] Injected transport error, HTTP 429, HTTP 500 -> UNVERIFIED =="
    run_named_unit_test "row5" "BibCSLAndFirewallTests/firewallOnlineRegistryTransport429And500FailuresReturnUnverified" "S19 regression"
    echo "PASS: Row 5"
    echo ""

    # ------------------------------------------------------------------
    # Row 6: Built-in retracted paper -> RETRACTED + built-in-list notice (--lang en & --lang zh)
    # ------------------------------------------------------------------
    echo "== [Row 6] Built-in retracted paper -> RETRACTED + built-in list notice (--lang en & --lang zh) =="
    WAKEFIELD_EN_LINE="$(printf '%s\n' "$OFFLINE_EN_OUT" | grep "retracted_wakefield" || true)"
    WAKEFIELD_ZH_LINE="$(printf '%s\n' "$OFFLINE_ZH_OUT" | grep "retracted_wakefield" || true)"
    echo "en: $WAKEFIELD_EN_LINE"
    echo "zh: $WAKEFIELD_ZH_LINE"
    for W_LINE in "$WAKEFIELD_EN_LINE" "$WAKEFIELD_ZH_LINE"; do
        if ! printf '%s\n' "$W_LINE" | grep -q "\[RETRACTED\]"; then
            echo "FAIL: Row 6 expected [RETRACTED]"
            exit 1
        fi
    done
    if ! printf '%s\n' "$WAKEFIELD_EN_LINE" | grep -q "built-in list, incomplete"; then
        echo "FAIL: Row 6 expected 'built-in list, incomplete' in the English line"
        exit 1
    fi
    if ! printf '%s\n' "$WAKEFIELD_ZH_LINE" | grep -q "内置名单，不完整"; then
        echo "FAIL: Row 6 expected '内置名单，不完整' in the Chinese line"
        exit 1
    fi
    echo "PASS: Row 6"
    echo ""

    # ------------------------------------------------------------------
    # Row 7: prisma-stats kappa == MCP scholar_prisma_agreement kappa == hand calculation (83/107)
    # ------------------------------------------------------------------
    echo "== [Row 7] prisma-stats kappa == MCP scholar_prisma_agreement kappa == 83/107 =="
    KAPPA_PROJ="$WORK/kappa-check.scholarproj"
    scholaros init --project "$KAPPA_PROJ" --seed-demo >/dev/null
    PRISMA_JSON="$(scholaros prisma-stats --project "$KAPPA_PROJ")"
    MCP_KAPPA_REQ="$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"scholar_prisma_agreement","arguments":{"projectPath":"%s"}}}\n' "$KAPPA_PROJ")"
    MCP_KAPPA_RAW="$(printf '%s\n' "$MCP_KAPPA_REQ" | scholaros mcp --project "$KAPPA_PROJ")"
    KAPPA_CHECK="$(python3 - "$PRISMA_JSON" "$MCP_KAPPA_RAW" <<'PY'
import json, re, sys
prisma = json.loads(sys.argv[1])
mcp_env = json.loads(sys.argv[2])
mcp_text = mcp_env["result"]["content"][0]["text"]
m = re.search(r"Kappa=([0-9.]+)", mcp_text)
assert m, f"Missing Kappa= in {mcp_text}"
cli_k = float(prisma["cohensKappa"])
mcp_k = float(m.group(1))
hand_k = 83.0 / 107.0
print(f"hand_kappa_83_over_107={hand_k:.6f} cli_kappa={cli_k:.6f} mcp_kappa={mcp_k:.4f}")
assert abs(cli_k - hand_k) < 1e-6, (cli_k, hand_k)
assert abs(mcp_k - round(hand_k, 4)) < 1e-9, (mcp_k, round(hand_k, 4))
PY
)"
    echo "$KAPPA_CHECK"
    echo "PASS: Row 7"
    echo ""

    # ------------------------------------------------------------------
    # Row 8: MCP invalid JSON -> -32700 and unknown method -> -32601
    # ------------------------------------------------------------------
    echo "== [Row 8] MCP invalid JSON (-32700) & unknown method (-32601) =="
    MCP_ERR_OUT="$(printf '%s\n%s\n' '{invalid_json' '{"jsonrpc":"2.0","id":99,"method":"scholar/nonexistent_method","params":{}}' | scholaros mcp)"
    echo "$MCP_ERR_OUT"
    python3 - "$MCP_ERR_OUT" <<'PY'
import json, sys
lines = [json.loads(line) for line in sys.argv[1].strip().splitlines()]
assert len(lines) == 2, lines
assert lines[0]["error"]["code"] == -32700, lines[0]
assert lines[1]["id"] == 99 and lines[1]["error"]["code"] == -32601, lines[1]
PY
    echo "PASS: Row 8"
    echo ""

    # ------------------------------------------------------------------
    # Row 9: Interface default state is empty. Checked WITHOUT opening a window: a default
    # ScholarStudioViewModel must have no manuscripts, no bibliography, no screening records and
    # no block alert, and its empty-state texts must not claim that anything was verified.
    # ------------------------------------------------------------------
    echo "== [Row 9] Interface default state is empty (windowless ViewModel tests; no GUI process is started) =="
    run_named_unit_test "row9_default_state" "ScholarStudioViewsTests/s21AndS22StudioViewModelStartsEmptyWithoutDemoDataOrFakeAlert" "S21/S22 regression"
    run_named_unit_test "row9_empty_state_texts" "ScholarStudioViewsTests/s30EmptyWorkspaceShowsNoDataInsteadOfVerifiedOrPassedConclusions" "S30 regression"
    if ! grep -q "\[DEMO\] Sample Unverified Dataset" "$REPO_ROOT/docs/demo-scholar-dossier.html" || ! grep -q "\[DEMO / 演示数据\]" "$REPO_ROOT/docs/demo-scholar-dossier.html"; then
        echo "FAIL: Row 9 expected bilingual [DEMO / 演示数据] marker in docs/demo-scholar-dossier.html"
        exit 1
    fi
    echo "demo_html_bilingual_marker=present"
    echo "gui_processes_started_by_this_script=0"
    echo "PASS: Row 9"
    echo ""

    # ------------------------------------------------------------------
    # Row 10: Banned EN/ZH claims search across Sources/, README.md, README.zh-CN.md, docs/
    # ------------------------------------------------------------------
    echo "== [Row 10] Search banned EN/ZH strings in Sources/, README.md, README.zh-CN.md, docs/ =="
    set +e
    BANNED_HITS="$(grep -r -i -n -I -E "VERIFIED_DOI|FIREWALL_CLEARED|Hardware-Gated|HardwareGated|Zero-Hallucination|returned HTTP 404|零幻觉|硬件门禁|硬件级门禁|硬件级|已验证 DOI" "$REPO_ROOT/Sources" "$REPO_ROOT/README.md" "$REPO_ROOT/README.zh-CN.md" "$REPO_ROOT/docs")"
    BANNED_EXIT=$?
    set -e
    if [[ "$BANNED_EXIT" -ne 1 || -n "$BANNED_HITS" ]]; then
        echo "FAIL: Row 10 found banned terms (or the search itself failed, grep exit $BANNED_EXIT):"
        echo "$BANNED_HITS"
        exit 1
    fi
    echo "matches_in_sources_readmes_and_docs=0"
    echo "PASS: Row 10"
    echo ""

    # ------------------------------------------------------------------
    # Row 11 (S32): English verify-citations output has exactly one class tag per entry line
    # and contains no Chinese characters.
    # ------------------------------------------------------------------
    echo "== [Row 11] verify-citations --lang en: one class tag per entry line, no Chinese in English output =="
    python3 - "$NOFLAG_EN_OUT" "$OFFLINE_EN_OUT" <<'PY'
import re, sys
tag = re.compile(r"\[(VERIFIED|DRIFT|NOT_FOUND|RETRACTED|UNVERIFIED)\]")
cjk = re.compile(r"[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uff00-\uffef]")
for label, blob in (("no_flag", sys.argv[1]), ("offline_flag", sys.argv[2])):
    entry_lines = [line for line in blob.splitlines() if tag.search(line)]
    assert len(entry_lines) == 12, (label, len(entry_lines))
    for line in entry_lines:
        assert len(tag.findall(line)) == 1, (label, "duplicate class tag", line)
        assert tag.match(line), (label, "class tag is not at the start of the line", line)
    assert not cjk.search(blob), (label, "Chinese characters in English output", cjk.findall(blob))
    print(f"{label}: entry_lines={len(entry_lines)} tags_per_line=1 cjk_characters=0")
PY
    echo "PASS: Row 11"
    echo ""

    # ------------------------------------------------------------------
    # Row 12 (S33): the output does not pretend there is an offline "mode". With or without
    # --offline it is identical and states that this version performs no online lookups.
    # ------------------------------------------------------------------
    echo "== [Row 12] verify-citations states that this version performs no online lookups (--lang en & --lang zh) =="
    if [[ "$NOFLAG_EN_OUT" != "$OFFLINE_EN_OUT" || "$NOFLAG_ZH_OUT" != "$OFFLINE_ZH_OUT" ]]; then
        echo "FAIL: Row 12 expected identical output with and without --offline"
        exit 1
    fi
    echo "output_identical_with_and_without_offline_flag=true"
    printf '%s\n' "$NOFLAG_EN_OUT" | grep "performs no online registry lookups" || { echo "FAIL: Row 12 missing English no-online-lookup notice"; exit 1; }
    printf '%s\n' "$NOFLAG_ZH_OUT" | grep "本版本不联网核查" || { echo "FAIL: Row 12 missing Chinese no-online-lookup notice"; exit 1; }
    if printf '%s\n%s\n' "$NOFLAG_EN_OUT" "$NOFLAG_ZH_OUT" | grep -n -i -E "\(offline\)|unverified offline|离线模式"; then
        echo "FAIL: Row 12 output still describes an offline mode"
        exit 1
    fi
    echo "PASS: Row 12"
    echo ""

    # ------------------------------------------------------------------
    # Row 13 (S30): no hard-coded "100%" verification conclusion in the studio views.
    # ------------------------------------------------------------------
    echo "== [Row 13] No hard-coded '100%' conclusion in Sources/ScholarStudioViews =="
    set +e
    HUNDRED_HITS="$(grep -r -n -F '100%' "$REPO_ROOT/Sources/ScholarStudioViews")"
    HUNDRED_EXIT=$?
    set -e
    if [[ "$HUNDRED_EXIT" -ne 1 || -n "$HUNDRED_HITS" ]]; then
        echo "FAIL: Row 13 found '100%' literals (or the search itself failed, grep exit $HUNDRED_EXIT):"
        echo "$HUNDRED_HITS"
        exit 1
    fi
    echo "literal_100_percent_matches_in_studio_views=0"
    echo "PASS: Row 13"
    echo ""

    # ------------------------------------------------------------------
    # Row 14 (C5): no absolute home-directory path of any machine in tracked files.
    # (The pattern is assembled from two pieces so that this script does not match itself.)
    # ------------------------------------------------------------------
    echo "== [Row 14] No absolute home-directory paths in tracked files =="
    HOME_PATH_PATTERN="/Use""rs/"
    set +e
    if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        HOME_PATH_HITS="$(git -C "$REPO_ROOT" grep -n -F "$HOME_PATH_PATTERN")"
        HOME_PATH_EXIT=$?
        echo "search=git-grep-over-tracked-files"
    else
        HOME_PATH_HITS="$(grep -r -n -I -F --exclude-dir=.build --exclude-dir=.git --exclude-dir=build "$HOME_PATH_PATTERN" "$REPO_ROOT")"
        HOME_PATH_EXIT=$?
        echo "search=grep-over-working-directory (not a git checkout)"
    fi
    set -e
    if [[ "$HOME_PATH_EXIT" -ne 1 || -n "$HOME_PATH_HITS" ]]; then
        echo "FAIL: Row 14 found absolute home-directory paths (or the search itself failed, exit $HOME_PATH_EXIT):"
        echo "$HOME_PATH_HITS"
        exit 1
    fi
    echo "absolute_home_path_matches=0"
    echo "PASS: Row 14"
    echo ""
    echo "ALL M0 ACCEPTANCE CHECKS PASSED (EN & ZH): rows 1-10 of the M0 table and supplementary rows 11-14."
} | tee "$REPORT_FILE"

echo "[m0-acceptance] report written to $REPORT_FILE" >&2
