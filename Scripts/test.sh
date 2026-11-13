#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

usage() {
    cat >&2 <<'EOF'
Usage:
  Scripts/test.sh scope <ModuleOrFilter...>
  Scripts/test.sh milestone <N>
  Scripts/test.sh release
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
        FILTERS=()
        for target in "$@"; do
            mapped="$(map_module_to_filter "$target")"
            FILTERS+=("$mapped")
        done
        JOINED="$(IFS='|'; echo "${FILTERS[*]}")"
        echo "[test.sh] Running scoped tests: --filter ($JOINED)"
        swift test --no-parallel --filter "($JOINED)"
        ;;

    milestone)
        if [[ $# -ne 1 ]]; then
            usage
        fi
        MS="$1"
        case "$MS" in
            0)
                echo "[test.sh] Running M0 scoped unit tests..."
                swift test --no-parallel --filter "(BibCSLAndFirewallTests|LSPEngineAndSyncTeXTests|PRISMAAndPsychometricsTests|ProjectStoreAndTrackChangesTests|PluginSDKMCPAndShellTests|ScholarStudioViewsTests)"
                if [[ ! -x "$REPO_ROOT/Scripts/acceptance/m0-acceptance.sh" ]]; then
                    echo "ERROR: Missing executable Scripts/acceptance/m0-acceptance.sh" >&2
                    exit 1
                fi
                if [[ ! -x "$REPO_ROOT/Scripts/acceptance/readme-commands.sh" ]]; then
                    echo "ERROR: Missing executable Scripts/acceptance/readme-commands.sh" >&2
                    exit 1
                fi
                echo "[test.sh] Running M0 acceptance script..."
                "$REPO_ROOT/Scripts/acceptance/m0-acceptance.sh"
                echo "[test.sh] Running README command replay..."
                "$REPO_ROOT/Scripts/acceptance/readme-commands.sh"
                ;;
            *)
                echo "ERROR: Milestone M${MS} acceptance script is not implemented yet." >&2
                exit 1
                ;;
        esac
        ;;

    release)
        echo "[test.sh] Running full unit test suite (--no-parallel)..."
        swift test --no-parallel

        if [[ -x "$REPO_ROOT/Scripts/acceptance/m0-acceptance.sh" ]]; then
            echo "[test.sh] Running M0 acceptance script..."
            "$REPO_ROOT/Scripts/acceptance/m0-acceptance.sh"
        else
            echo "ERROR: Missing executable Scripts/acceptance/m0-acceptance.sh" >&2
            exit 1
        fi

        if [[ -x "$REPO_ROOT/Scripts/acceptance/readme-commands.sh" ]]; then
            echo "[test.sh] Running README command replay..."
            "$REPO_ROOT/Scripts/acceptance/readme-commands.sh"
        else
            echo "ERROR: Missing executable Scripts/acceptance/readme-commands.sh" >&2
            exit 1
        fi

        if [[ "${SCHOLAR_ONLINE:-0}" == "1" ]]; then
            if [[ -f "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py" ]]; then
                python3 "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py"
            else
                echo "SKIPPED: Online benchmark (Scripts/acceptance/m1-citation-bench.py is scheduled for M1)"
            fi
        else
            echo "SKIPPED (SCHOLAR_ONLINE!=1)"
        fi
        ;;

    *)
        usage
        ;;
esac
