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
#   SCHOLAR_SANDBOX_HOME       required; an existing empty directory used as the fake home
#   SCHOLAR_CLI_BIN            optional; absolute path of the executable. When unset, the
#                              executable named `ScholarOS` is looked up on PATH (README replay).
#   SCHOLAR_OUTER_NO_NETWORK   optional; when "1", verifies an outer network-denying sandbox is
#                              active (exiting 2 otherwise) and passes --disable-sandbox to swift.

: "${SCHOLAR_SANDBOX_HOME:?SCHOLAR_SANDBOX_HOME must point at a throwaway directory}"

scholar_is_network_sandboxed() {
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

SCHOLAR_DISABLE_SWIFTPM_SANDBOX=0
if [[ "${SCHOLAR_OUTER_NO_NETWORK:-0}" == "1" ]]; then
    if ! scholar_is_network_sandboxed; then
        echo "ERROR: SCHOLAR_OUTER_NO_NETWORK=1 is set, but network loopback was not blocked with EPERM/EACCES (not inside a deny-network sandbox)." >&2
        exit 2
    fi
    SCHOLAR_DISABLE_SWIFTPM_SANDBOX=1
elif scholar_is_network_sandboxed; then
    SCHOLAR_DISABLE_SWIFTPM_SANDBOX=1
    export SCHOLAR_OUTER_NO_NETWORK=1
fi

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

# Optional build parallelism cap (`SCHOLAR_BUILD_JOBS=3`) and `--disable-sandbox` forwarding when
# already running inside an outer `sandbox-exec` network-denial wrapper (`SCHOLAR_OUTER_NO_NETWORK=1`).
swift() {
    if [[ $# -ge 1 && ( "$1" == "build" || "$1" == "test" ) ]]; then
        local extra_flags=()
        local has_disable=0
        local a
        for a in "$@"; do
            if [[ "$a" == "--disable-sandbox" ]]; then
                has_disable=1
            fi
        done
        if [[ "${SCHOLAR_DISABLE_SWIFTPM_SANDBOX:-0}" -eq 1 && "$has_disable" -eq 0 ]]; then
            extra_flags+=("--disable-sandbox")
        fi
        if [[ -n "${SCHOLAR_BUILD_JOBS:-}" ]]; then
            extra_flags+=("-j" "$SCHOLAR_BUILD_JOBS")
        fi
        if [[ "${#extra_flags[@]}" -gt 0 ]]; then
            command swift "$@" "${extra_flags[@]}"
        else
            command swift "$@"
        fi
    else
        command swift "$@"
    fi
}
