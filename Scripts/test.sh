#!/usr/bin/env bash
#
# Single test entry point.
#
#   Scripts/test.sh scope <ModuleOrFilter...>     unit tests of the named modules only
#   Scripts/test.sh milestone <N> [--record]      scoped unit tests + the milestone's acceptance scripts
#   Scripts/test.sh release [--record]            everything (only before a release)
#
# `milestone` and `release` write their acceptance reports to a temporary directory and leave the
# working tree untouched. Pass --record to overwrite the committed files under reports/ instead
# (do this only when the README numbers that cite those files are being regenerated).
#
# Nothing here starts the graphical interface, and nothing here may leave files in
# ~/Library/Preferences or ~/Library/Caches/ScholarOS: `milestone` and `release` fail if either
# the working tree or the real account's ScholarOS preference/cache state changed while they ran.
#
# Environment:
#   SCHOLAR_BUILD_JOBS=<n>        caps build parallelism (`swift build -j n`, `swift test -j n`)
#   SCHOLAR_ONLINE=1              enables live network checks in `release` and `m1-acceptance.sh`
#   SCHOLAR_OUTER_NO_NETWORK=1    signals that the caller already wrapped this invocation inside
#                                 `sandbox-exec -p '(version 1)(allow default)(deny network*)'`:
#                                 verifies loopback connect fails with EPERM/EACCES (exiting 2
#                                 immediately if not!), passes `--disable-sandbox` to `swift`,
#                                 and instructs child scripts not to spawn nested sandboxes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

usage() {
    cat >&2 <<'EOF'
Usage:
  Scripts/test.sh scope <ModuleOrFilter...>
  Scripts/test.sh milestone <N> [--record]
  Scripts/test.sh release [--record]
EOF
    exit 2
}

verify_outer_no_network_sandbox() {
    python3 -I -c '
import errno, socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(0.5)
try:
    rc = s.connect_ex(("127.0.0.1", 9))
except PermissionError:
    rc = errno.EPERM
except OSError as exc:
    rc = exc.errno or 0
finally:
    s.close()
sys.exit(0 if rc in (errno.EPERM, errno.EACCES) else 1)
'
}

DISABLE_SWIFTPM_SANDBOX=0
if [[ "${SCHOLAR_OUTER_NO_NETWORK:-0}" == "1" ]]; then
    if ! verify_outer_no_network_sandbox; then
        echo "ERROR: SCHOLAR_OUTER_NO_NETWORK=1 requires an active network-denying sandbox (loopback connect was not blocked with EPERM/EACCES)." >&2
        exit 2
    fi
    DISABLE_SWIFTPM_SANDBOX=1
    export SCHOLAR_OUTER_NO_NETWORK=1
fi

REAL_USER_HOME="$(python3 -I -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"

map_module_to_filter() {
    case "$1" in
        ScholarModels)
            echo "BibCSLAndFirewallTests|MarkupASTAndMacroTests"
            ;;
        ScholarMarkupAST)
            echo "MarkupASTAndMacroTests"
            ;;
        ScholarBibAndCSL)
            echo "BibCSLAndFirewallTests"
            ;;
        ScholarLSPEngine)
            echo "LSPEngineAndSyncTeXTests"
            ;;
        ScholarPDFProvenance|ScholarCitationGraph)
            echo "PDFProvenanceAndCitationGraphTests"
            ;;
        ScholarPRISMAEngine)
            echo "PRISMAAndPsychometricsTests"
            ;;
        ScholarProjectStore)
            echo "ProjectStoreAndTrackChangesTests"
            ;;
        ScholarPluginSDK|ScholarCLIAndMCP|ScholarWorkbenchShell)
            echo "PluginSDKMCPAndShellTests"
            ;;
        ScholarStudioViews)
            echo "ScholarStudioViewsTests"
            ;;
        *)
            echo "$1"
            ;;
    esac
}

# `swift test` with optional `--disable-sandbox` (under verified outer sandbox) and parallelism cap.
swift_test() {
    local extra=()
    if [[ "$DISABLE_SWIFTPM_SANDBOX" -eq 1 ]]; then
        extra+=("--disable-sandbox")
    fi
    if [[ -n "${SCHOLAR_BUILD_JOBS:-}" ]]; then
        extra+=("-j" "$SCHOLAR_BUILD_JOBS")
    fi
    if [[ "${#extra[@]}" -gt 0 ]]; then
        swift test "${extra[@]}" "$@"
    else
        swift test "$@"
    fi
}

# Number of ScholarOS preference files in the caller's real ~/Library/Preferences (names only are read).
count_scholaros_preference_files() {
    local prefs_dir="$REAL_USER_HOME/Library/Preferences"
    if [[ ! -d "$prefs_dir" ]]; then
        echo 0
        return
    fi
    find "$prefs_dir" -maxdepth 1 -name 'io.github.zxu756.ScholarOS.*' | wc -l | tr -d ' '
}

# State of ~/Library/Caches/ScholarOS in the caller's real HOME (tests and scripts must isolate HOME / SCHOLAR_CACHE_DIR).
scholaros_cache_dir_state() {
    local cache_dir="$REAL_USER_HOME/Library/Caches/ScholarOS"
    if [[ ! -e "$cache_dir" ]]; then
        echo "absent"
        return
    fi
    local db_file="$cache_dir/registry.sqlite"
    if [[ -e "$db_file" ]]; then
        stat -f "present:%m:%z" "$db_file"
    else
        echo "present:no-db"
    fi
}

assert_real_home_cache_untouched() {
    local before="$1"
    local after
    after="$(scholaros_cache_dir_state)"
    if [[ "$before" != "$after" ]]; then
        echo "ERROR: tests or scripts touched real ~/Library/Caches/ScholarOS (before=$before after=$after). Always isolate HOME or SCHOLAR_CACHE_DIR." >&2
        exit 1
    fi
}

working_tree_state() {
    if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$REPO_ROOT" status --short
    fi
}

# Picks the report directory: reports/ with --record, a fresh temporary directory otherwise.
select_report_dir() {
    local record="$1"
    if [[ "$record" -eq 1 ]]; then
        echo "$REPO_ROOT/reports"
    else
        mktemp -d "${TMPDIR:-/tmp}/scholaros-reports.XXXXXX"
    fi
}

require_executable() {
    if [[ ! -x "$1" ]]; then
        echo "ERROR: Missing executable ${1#"$REPO_ROOT"/}" >&2
        exit 1
    fi
}

run_m0_acceptance_scripts() {
    require_executable "$REPO_ROOT/Scripts/acceptance/m0-acceptance.sh"
    require_executable "$REPO_ROOT/Scripts/acceptance/readme-commands.sh"
    echo "[test.sh] Running M0 acceptance script..."
    if [[ "${1:-0}" -eq 1 ]]; then
        "$REPO_ROOT/Scripts/acceptance/m0-acceptance.sh" --record
        echo "[test.sh] Running README command replay..."
        "$REPO_ROOT/Scripts/acceptance/readme-commands.sh" --record
    else
        "$REPO_ROOT/Scripts/acceptance/m0-acceptance.sh"
        echo "[test.sh] Running README command replay..."
        "$REPO_ROOT/Scripts/acceptance/readme-commands.sh"
    fi
}

assert_post_run_hygiene() {
    local record="$1"
    local prefs_before="$2"
    local cache_before="$3"
    local tree_before="$4"

    local prefs_after
    prefs_after="$(count_scholaros_preference_files)"
    echo "[test.sh] ScholarOS preference files in ~/Library/Preferences: before=$prefs_before after=$prefs_after"
    if [[ "$prefs_before" != "$prefs_after" ]]; then
        echo "ERROR: the run changed the number of io.github.zxu756.ScholarOS.* files in ~/Library/Preferences ($prefs_before -> $prefs_after)." >&2
        exit 1
    fi
    assert_real_home_cache_untouched "$cache_before"
    echo "[test.sh] Real ~/Library/Caches/ScholarOS untouched ($cache_before)."
    if [[ "$record" -eq 1 ]]; then
        echo "[test.sh] --record: reports/ was updated; review and commit the change."
    else
        local tree_after
        tree_after="$(working_tree_state)"
        if [[ "$tree_before" != "$tree_after" ]]; then
            echo "ERROR: the run modified the working tree (git status --short before/after differ):" >&2
            echo "$tree_after" >&2
            exit 1
        fi
        echo "[test.sh] Working tree unchanged by the run."
    fi
}

if [[ $# -lt 1 ]]; then
    usage
fi

MODE="$1"
shift

case "$MODE" in
    scope)
        if [[ $# -lt 1 ]]; then
            usage
        fi
        CACHE_BEFORE="$(scholaros_cache_dir_state)"
        FILTERS=()
        for target in "$@"; do
            mapped="$(map_module_to_filter "$target")"
            FILTERS+=("$mapped")
        done
        JOINED="$(IFS='|'; echo "${FILTERS[*]}")"
        echo "[test.sh] Running scoped tests: --filter ($JOINED)"
        swift_test --no-parallel --filter "($JOINED)"
        assert_real_home_cache_untouched "$CACHE_BEFORE"
        ;;

    milestone)
        MS=""
        RECORD=0
        for arg in "$@"; do
            case "$arg" in
                --record) RECORD=1 ;;
                -*) usage ;;
                *)
                    if [[ -n "$MS" ]]; then
                        usage
                    fi
                    MS="$arg"
                    ;;
            esac
        done
        if [[ -z "$MS" ]]; then
            usage
        fi
        case "$MS" in
            0)
                TREE_BEFORE="$(working_tree_state)"
                PREFS_BEFORE="$(count_scholaros_preference_files)"
                CACHE_BEFORE="$(scholaros_cache_dir_state)"
                SCHOLAR_REPORT_DIR="$(select_report_dir "$RECORD")"
                export SCHOLAR_REPORT_DIR

                echo "[test.sh] Running M0 scoped unit tests..."
                swift_test --no-parallel --filter "(BibCSLAndFirewallTests|LSPEngineAndSyncTeXTests|PRISMAAndPsychometricsTests|ProjectStoreAndTrackChangesTests|PluginSDKMCPAndShellTests|ScholarStudioViewsTests)"
                run_m0_acceptance_scripts "$RECORD"

                assert_post_run_hygiene "$RECORD" "$PREFS_BEFORE" "$CACHE_BEFORE" "$TREE_BEFORE"
                echo "[test.sh] Reports: $SCHOLAR_REPORT_DIR"
                echo "[test.sh] MILESTONE 0 PASSED."
                ;;

            1)
                TREE_BEFORE="$(working_tree_state)"
                PREFS_BEFORE="$(count_scholaros_preference_files)"
                CACHE_BEFORE="$(scholaros_cache_dir_state)"
                SCHOLAR_REPORT_DIR="$(select_report_dir "$RECORD")"
                export SCHOLAR_REPORT_DIR

                echo "[test.sh] Running M1 scoped unit tests..."
                swift_test --no-parallel --filter "(BibCSLAndFirewallTests|MarkupASTAndMacroTests|LSPEngineAndSyncTeXTests|ProjectStoreAndTrackChangesTests|PluginSDKMCPAndShellTests|ScholarStudioViewsTests|ZZZCacheHomeIsolationGuardTests)"
                echo "[test.sh] Running M1 benchmark Python tooling unit tests..."
                python3 -I -m unittest discover -s "$REPO_ROOT/Benchmarks/citations/tools/tests" -t "$REPO_ROOT/Benchmarks/citations/tools"

                run_m0_acceptance_scripts "$RECORD"

                require_executable "$REPO_ROOT/Scripts/acceptance/m1-acceptance.sh"
                require_executable "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py"

                M1_FAILED=0
                echo "[test.sh] Running M1 acceptance script..."
                set +e
                if [[ "$RECORD" -eq 1 ]]; then
                    "$REPO_ROOT/Scripts/acceptance/m1-acceptance.sh" --record
                else
                    "$REPO_ROOT/Scripts/acceptance/m1-acceptance.sh"
                fi
                M1_ACC_EXIT=$?
                set -e
                if [[ "$M1_ACC_EXIT" -ne 0 ]]; then
                    M1_FAILED=1
                fi

                echo "[test.sh] Running M1 citation benchmark (--replay)..."
                set +e
                if [[ "$RECORD" -eq 1 ]]; then
                    python3 -I "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py" --replay --record
                else
                    python3 -I "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py" --replay
                fi
                M1_BENCH_EXIT=$?
                set -e
                if [[ "$M1_BENCH_EXIT" -ne 0 ]]; then
                    M1_FAILED=1
                fi

                assert_post_run_hygiene "$RECORD" "$PREFS_BEFORE" "$CACHE_BEFORE" "$TREE_BEFORE"
                echo "[test.sh] Reports: $SCHOLAR_REPORT_DIR"
                if [[ "$M1_FAILED" -ne 0 ]]; then
                    echo "[test.sh] MILESTONE 1 FAILED (m1-acceptance exit=$M1_ACC_EXIT, m1-citation-bench exit=$M1_BENCH_EXIT)." >&2
                    exit 1
                fi
                echo "[test.sh] MILESTONE 1 PASSED."
                ;;

            *)
                echo "ERROR: Milestone M${MS} acceptance script is not implemented yet." >&2
                exit 1
                ;;
        esac
        ;;

    release)
        RECORD=0
        for arg in "$@"; do
            case "$arg" in
                --record) RECORD=1 ;;
                *) usage ;;
            esac
        done
        TREE_BEFORE="$(working_tree_state)"
        PREFS_BEFORE="$(count_scholaros_preference_files)"
        CACHE_BEFORE="$(scholaros_cache_dir_state)"
        SCHOLAR_REPORT_DIR="$(select_report_dir "$RECORD")"
        export SCHOLAR_REPORT_DIR

        echo "[test.sh] Running full unit test suite (--no-parallel)..."
        swift_test --no-parallel
        echo "[test.sh] Running M1 benchmark Python tooling unit tests..."
        python3 -I -m unittest discover -s "$REPO_ROOT/Benchmarks/citations/tools/tests" -t "$REPO_ROOT/Benchmarks/citations/tools"

        run_m0_acceptance_scripts "$RECORD"

        require_executable "$REPO_ROOT/Scripts/acceptance/m1-acceptance.sh"
        require_executable "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py"

        REL_FAILED=0
        echo "[test.sh] Running M1 acceptance script..."
        set +e
        if [[ "$RECORD" -eq 1 ]]; then
            "$REPO_ROOT/Scripts/acceptance/m1-acceptance.sh" --record
        else
            "$REPO_ROOT/Scripts/acceptance/m1-acceptance.sh"
        fi
        REL_M1_EXIT=$?
        set -e
        if [[ "$REL_M1_EXIT" -ne 0 ]]; then
            REL_FAILED=1
        fi

        echo "[test.sh] Running M1 citation benchmark (--replay)..."
        set +e
        if [[ "$RECORD" -eq 1 ]]; then
            python3 -I "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py" --replay --record
        else
            python3 -I "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py" --replay
        fi
        REL_REPLAY_EXIT=$?
        set -e
        if [[ "$REL_REPLAY_EXIT" -ne 0 ]]; then
            REL_FAILED=1
        fi

        SKIPPED_COUNT=0
        if [[ "${SCHOLAR_ONLINE:-0}" == "1" ]]; then
            LIVE_DATE="$(date -u +%Y-%m-%d)"
            LIVE_OUT="$SCHOLAR_REPORT_DIR/citation-bench-${LIVE_DATE}-live.json"
            echo "[test.sh] Running M1 citation benchmark (--live)..."
            set +e
            python3 -I "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py" --live --output "$LIVE_OUT"
            REL_LIVE_EXIT=$?
            set -e
            if [[ "$REL_LIVE_EXIT" -ne 0 ]]; then
                REL_FAILED=1
            fi
        else
            echo "SKIPPED: 没跑 — Scripts/acceptance/m1-citation-bench.py --live (SCHOLAR_ONLINE!=1)"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        fi

        assert_post_run_hygiene "$RECORD" "$PREFS_BEFORE" "$CACHE_BEFORE" "$TREE_BEFORE"
        echo "[test.sh] Reports: $SCHOLAR_REPORT_DIR"

        if [[ "$REL_FAILED" -ne 0 ]]; then
            echo "[test.sh] RELEASE FAILED (${SKIPPED_COUNT} 项没跑)."
            exit 1
        fi
        if [[ "$SKIPPED_COUNT" -gt 0 ]]; then
            echo "[test.sh] RELEASE INCOMPLETE: ${SKIPPED_COUNT} 项没跑 (set SCHOLAR_ONLINE=1 to run online checks)."
            exit 1
        fi
        echo "[test.sh] RELEASE PASSED (0 项没跑)."
        ;;

    *)
        usage
        ;;
esac
