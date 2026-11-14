#!/usr/bin/env bash
#
# README command replay.
#
# The commands are NOT copied into this script. They are extracted from the ```bash fenced code
# blocks of README.md and README.zh-CN.md and executed verbatim, in order, from the repository
# root. Editing a command in either README therefore changes what runs here.
#
#   1. Both READMEs must carry the same commands. Comment lines and blank lines may differ (the
#      comments are translated); every other line of the code blocks must be identical, otherwise
#      this script fails before running anything.
#   2. Each README's blocks are then replayed with `set -e`, so a failing command fails the replay.
#
# The replay never starts the graphical interface: `ScholarOS` is wrapped by the shell function
# from lib-cli-guard.sh, which refuses argument lists that would open a window and gives the
# binary a throwaway home directory.
#
# Usage:
#   Scripts/acceptance/readme-commands.sh            report goes to a temporary directory
#   Scripts/acceptance/readme-commands.sh --record   report overwrites reports/readme-commands.txt
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
            echo "Usage: Scripts/acceptance/readme-commands.sh [--record]" >&2
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
    REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-readme-report.XXXXXX")"
fi
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/readme-commands.txt"

export SCHOLAR_SANDBOX_HOME="$WORK/home"
mkdir -p "$SCHOLAR_SANDBOX_HOME"
# README replay looks the executable up on PATH exactly as the README tells the reader to.
unset SCHOLAR_CLI_BIN
GUARD_LIB="$REPO_ROOT/Scripts/acceptance/lib-cli-guard.sh"

README_FILES=("README.md" "README.zh-CN.md")

# Prints the body of every ```bash fenced block of the given Markdown file, in order.
extract_bash_blocks() {
    awk '
        /^```bash[[:space:]]*$/ { in_block = 1; next }
        /^```[[:space:]]*$/ { if (in_block) { in_block = 0; print "" } ; next }
        in_block { print }
    ' "$1"
}

# Drops comment-only and blank lines, leaving the lines that are executed or fed to a heredoc.
command_lines_only() {
    grep -v -E '^[[:space:]]*(#.*)?$' "$1" || true
}

{
    echo "# ScholarOS README.md & README.zh-CN.md Command Replay"
    echo "Date: $(date +%Y-%m-%d)"
    echo "Commands are extracted from the bash code blocks of both READMEs and executed verbatim."
    echo ""

    for README_FILE in "${README_FILES[@]}"; do
        if [[ ! -f "$REPO_ROOT/$README_FILE" ]]; then
            echo "FAIL: $README_FILE not found"
            exit 1
        fi
        extract_bash_blocks "$REPO_ROOT/$README_FILE" > "$WORK/$README_FILE.blocks.sh"
        command_lines_only "$WORK/$README_FILE.blocks.sh" > "$WORK/$README_FILE.commands.txt"
        COMMAND_LINE_COUNT="$(wc -l < "$WORK/$README_FILE.commands.txt" | tr -d ' ')"
        INVOCATION_COUNT="$(grep -c -E '(^|[|;&[:space:]])ScholarOS[[:space:]]' "$WORK/$README_FILE.commands.txt" || true)"
        echo "$README_FILE: extracted_command_lines=$COMMAND_LINE_COUNT ScholarOS_invocations=$INVOCATION_COUNT"
        if [[ "$COMMAND_LINE_COUNT" -lt 5 || "$INVOCATION_COUNT" -lt 1 ]]; then
            echo "FAIL: $README_FILE has no usable bash code blocks to replay"
            exit 1
        fi
    done

    echo ""
    echo "== Consistency: README.md and README.zh-CN.md must carry the same commands =="
    if ! diff -u "$WORK/README.md.commands.txt" "$WORK/README.zh-CN.md.commands.txt" > "$WORK/readme-commands.diff"; then
        echo "FAIL: the bash code blocks of README.md and README.zh-CN.md differ (comments and blank lines ignored):"
        cat "$WORK/readme-commands.diff"
        exit 1
    fi
    echo "command_lines_identical=true"
    echo ""

    for README_FILE in "${README_FILES[@]}"; do
        echo "== Replay: bash code blocks of $README_FILE =="
        {
            printf 'source %q\n' "$GUARD_LIB"
            echo "set -eo pipefail"
            # From here on bash echoes every input line before running it, so the report shows
            # the README text itself next to the output it produced.
            echo "set -v"
            cat "$WORK/$README_FILE.blocks.sh"
        } > "$WORK/replay.sh"
        set +e
        bash "$WORK/replay.sh" 2>&1
        REPLAY_EXIT=$?
        set -e
        echo ""
        echo "replay_exit[$README_FILE]=$REPLAY_EXIT"
        if [[ "$REPLAY_EXIT" -ne 0 ]]; then
            echo "FAIL: replaying the code blocks of $README_FILE exited with $REPLAY_EXIT"
            exit 1
        fi
        echo ""
    done

    echo "README.md & README.zh-CN.md COMMAND REPLAY PASSED."
} | tee "$REPORT_FILE"

echo "[readme-commands] report written to $REPORT_FILE" >&2
