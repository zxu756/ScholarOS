# shellcheck shell=bash
#
# Sourced by the acceptance scripts (and by the script that replays the README code blocks).
# Defines the shell functions `ScholarOS` and `scholaros`, which wrap the real executable so that
#
#   1. no acceptance step can open the desktop window. The executable starts the SwiftUI
#      workstation when it gets no subcommand (only `--lang ...`), when its only argument is
#      `--demo`, and it creates an offscreen AppKit window for `--export-screenshots`.
#      All three shapes are refused here with exit code 97 before the binary is started;
#   2. the binary runs with a throwaway home directory (HOME and CFFIXED_USER_HOME), so it
#      cannot read or write the caller's ~/Library.
#
# Inputs (environment):
#   SCHOLAR_SANDBOX_HOME  required; an existing empty directory used as the fake home
#   SCHOLAR_CLI_BIN       optional; absolute path of the executable. When unset, the
#                         executable named `ScholarOS` is looked up on PATH (README replay).

: "${SCHOLAR_SANDBOX_HOME:?SCHOLAR_SANDBOX_HOME must point at a throwaway directory}"

# Returns 0 when the given argument list would start the graphical interface: nothing is left once
# `--lang <x>` / `--lang=<x>` are removed, the only thing left is `--demo`, or `--export-screenshots`
# is present. (Written without command substitution so that a `set -v` transcript stays clean.)
scholar_cli_would_open_gui() {
    local skip_next=0
    local remaining_count=0
    local first_remaining=""
    local arg
    for arg in "$@"; do
        if [[ "$arg" == "--export-screenshots" ]]; then
            return 0
        fi
        if [[ "$skip_next" -eq 1 ]]; then
            skip_next=0
            continue
        fi
        case "$arg" in
            --lang) skip_next=1 ;;
            --lang=*) ;;
            *)
                remaining_count=$((remaining_count + 1))
                if [[ "$remaining_count" -eq 1 ]]; then
                    first_remaining="$arg"
                fi
                ;;
        esac
    done
    if [[ "$remaining_count" -eq 0 ]]; then
        return 0
    fi
    if [[ "$remaining_count" -eq 1 && "$first_remaining" == "--demo" ]]; then
        return 0
    fi
    return 1
}

ScholarOS() {
    if scholar_cli_would_open_gui "$@"; then
        echo "REFUSED by lib-cli-guard.sh: 'ScholarOS $*' would start the graphical interface; acceptance scripts never launch it." >&2
        return 97
    fi
    if [[ -n "${SCHOLAR_CLI_BIN:-}" ]]; then
        HOME="$SCHOLAR_SANDBOX_HOME" CFFIXED_USER_HOME="$SCHOLAR_SANDBOX_HOME" "$SCHOLAR_CLI_BIN" "$@"
    else
        HOME="$SCHOLAR_SANDBOX_HOME" CFFIXED_USER_HOME="$SCHOLAR_SANDBOX_HOME" command ScholarOS "$@"
    fi
}

scholaros() {
    ScholarOS "$@"
}

# Optional build parallelism cap: SCHOLAR_BUILD_JOBS=3 turns `swift build` / `swift test`
# into `swift build -j 3` / `swift test -j 3`. Unset means SwiftPM's default.
swift() {
    if [[ -n "${SCHOLAR_BUILD_JOBS:-}" && $# -ge 1 && ( "$1" == "build" || "$1" == "test" ) ]]; then
        command swift "$@" -j "$SCHOLAR_BUILD_JOBS"
    else
        command swift "$@"
    fi
}
