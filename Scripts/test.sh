#!/usr/bin/env bash
#
# Single test entry point.
#
#   Scripts/test.sh scope <ModuleOrFilter...>     unit tests of the named modules only
#   Scripts/test.sh milestone <N> [--record]      scoped unit tests + the milestone's acceptance scripts
#   Scripts/test.sh release                       everything (only before a release)
#
# `milestone` and `release` write their acceptance reports to a temporary directory and leave the
# working tree untouched. Pass --record to overwrite the committed files under reports/ instead
# (do this only when the README numbers that cite those files are being regenerated).
#
# Nothing here starts the graphical interface, and nothing here may leave files in
# ~/Library/Preferences: `milestone` fails if either the working tree or the set of
# io.github.zxu756.ScholarOS.* preference files changed while it ran.
#
# SCHOLAR_BUILD_JOBS=<n> caps build parallelism (`swift build -j n`, `swift test -j n`).
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

# `swift test` with the optional parallelism cap.
swift_test() {
    if [[ -n "${SCHOLAR_BUILD_JOBS:-}" ]]; then
        swift test -j "$SCHOLAR_BUILD_JOBS" "$@"
    else
        swift test "$@"
    fi
}

# Number of ScholarOS preference files in the caller's real ~/Library/Preferences (names only are read).
count_scholaros_preference_files() {
    local prefs_dir="$HOME/Library/Preferences"
    if [[ ! -d "$prefs_dir" ]]; then
        echo 0
        return
    fi
    find "$prefs_dir" -maxdepth 1 -name 'io.github.zxu756.ScholarOS.*' | wc -l | tr -d ' '
}

# State of ~/Library/Caches/ScholarOS in the caller's real HOME (tests and scripts must isolate HOME / SCHOLAR_CACHE_DIR).
scholaros_cache_dir_state() {
    local cache_dir="$HOME/Library/Caches/ScholarOS"
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
    "$REPO_ROOT/Scripts/acceptance/m0-acceptance.sh"
    echo "[test.sh] Running README command replay..."
    "$REPO_ROOT/Scripts/acceptance/readme-commands.sh"
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
                run_m0_acceptance_scripts

                PREFS_AFTER="$(count_scholaros_preference_files)"
                echo "[test.sh] ScholarOS preference files in ~/Library/Preferences: before=$PREFS_BEFORE after=$PREFS_AFTER"
                if [[ "$PREFS_BEFORE" != "$PREFS_AFTER" ]]; then
                    echo "ERROR: the run changed the number of io.github.zxu756.ScholarOS.* files in ~/Library/Preferences ($PREFS_BEFORE -> $PREFS_AFTER)." >&2
                    exit 1
                fi
                assert_real_home_cache_untouched "$CACHE_BEFORE"
                echo "[test.sh] Real ~/Library/Caches/ScholarOS untouched ($CACHE_BEFORE)."
                if [[ "$RECORD" -eq 1 ]]; then
                    echo "[test.sh] --record: reports/ was updated; review and commit the change."
                else
                    TREE_AFTER="$(working_tree_state)"
                    if [[ "$TREE_BEFORE" != "$TREE_AFTER" ]]; then
                        echo "ERROR: the run modified the working tree (git status --short before/after differ):" >&2
                        echo "$TREE_AFTER" >&2
                        exit 1
                    fi
                    echo "[test.sh] Working tree unchanged by the run."
                fi
                echo "[test.sh] Reports: $SCHOLAR_REPORT_DIR"
                echo "[test.sh] MILESTONE 0 PASSED."
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
        CACHE_BEFORE="$(scholaros_cache_dir_state)"
        SCHOLAR_REPORT_DIR="$(select_report_dir "$RECORD")"
        export SCHOLAR_REPORT_DIR

        echo "[test.sh] Running full unit test suite (--no-parallel)..."
        swift_test --no-parallel

        run_m0_acceptance_scripts
        assert_real_home_cache_untouched "$CACHE_BEFORE"

        if [[ "${SCHOLAR_ONLINE:-0}" == "1" ]]; then
            if [[ -f "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py" ]]; then
                python3 "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py"
            else
                echo "SKIPPED: Online benchmark (Scripts/acceptance/m1-citation-bench.py is scheduled for M1)"
            fi
        else
            echo "SKIPPED (SCHOLAR_ONLINE!=1)"
        fi
        echo "[test.sh] Reports: $SCHOLAR_REPORT_DIR"
        ;;

    *)
        usage
        ;;
esac
