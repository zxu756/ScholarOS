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

CREATED_REPORT_TMPDIR=""
M3_STEP_TMP=""
cleanup_test_sh() {
    if [[ -n "$M3_STEP_TMP" && -d "$M3_STEP_TMP" ]]; then
        rm -rf "$M3_STEP_TMP"
    fi
    if [[ -n "$CREATED_REPORT_TMPDIR" && -d "$CREATED_REPORT_TMPDIR" ]]; then
        rm -rf "$CREATED_REPORT_TMPDIR"
    fi
}
trap cleanup_test_sh EXIT

# Picks the report directory: reports/ with --record, a fresh temporary directory otherwise.
select_report_dir() {
    local record="$1"
    if [[ "$record" -eq 1 ]]; then
        echo "$REPO_ROOT/reports"
    else
        mktemp -d "${TMPDIR:-/tmp}/scholaros-reports.XXXXXX"
    fi
}

snapshot_real_home_full_hygiene() {
    python3 -I - "$REAL_USER_HOME" <<'PY'
import glob, hashlib, os, sys

home = sys.argv[1]
lib_entries = []
for sub in ("Caches", "Preferences", "Application Support"):
    base = os.path.join(home, "Library", sub)
    if not os.path.isdir(base):
        lib_entries.append(f"{base}:ABSENT")
        continue
    for name in sorted(os.listdir(base)):
        if "scholaros" in name.lower():
            p = os.path.join(base, name)
            if os.path.isdir(p) and not os.path.islink(p):
                lib_entries.append(f"{p}:DIR")
                for root, dirs, files in os.walk(p):
                    dirs.sort()
                    for fn in sorted(files):
                        fp = os.path.join(root, fn)
                        try:
                            st = os.lstat(fp)
                            lib_entries.append(f"{fp}:{st.st_size}:{st.st_mtime_ns}")
                        except OSError:
                            lib_entries.append(f"{fp}:ERR")
            else:
                try:
                    st = os.lstat(p)
                    lib_entries.append(f"{p}:{st.st_size}:{st.st_mtime_ns}")
                except OSError:
                    lib_entries.append(f"{p}:ERR")

VOLATILE_SUBDIRS = {
    ".claude": {"projects", "todos", "statsig", "debug", "shell-snapshots", "session-env", "ide", "telemetry", "file-history", "logs", "cache", "backups"},
    ".codex": {"sessions", "archived_sessions", "log", "logs", "tmp", "shell_snapshots", "sqlite"},
}
VOLATILE_FILENAMES = {"history.jsonl", ".claude.json.lock"}

client_targets = sorted(set(glob.glob(os.path.join(home, ".claude*")))) + [
    os.path.join(home, ".codex"),
    os.path.join(home, ".config", "opencode"),
]
h = hashlib.sha256()
for t in client_targets:
    rel_t = os.path.relpath(t, home)
    base_t = os.path.basename(t)
    if base_t in VOLATILE_FILENAMES or base_t.startswith(".claude.json.backup") or base_t.startswith(".claude.json.tmp"):
        continue
    if not os.path.lexists(t):
        h.update(f"{rel_t}:ABSENT\n".encode("utf-8"))
        continue
    st0 = os.lstat(t)
    if os.path.isfile(t) and not os.path.islink(t):
        h.update(f"{rel_t}:FILE:{st0.st_size}:".encode("utf-8"))
        if st0.st_size <= 8 * 1024 * 1024:
            try:
                h.update(hashlib.sha256(open(t, "rb").read()).hexdigest().encode("utf-8"))
            except OSError:
                h.update(b"UNREADABLE")
        h.update(b"\n")
    elif os.path.isdir(t) and not os.path.islink(t):
        skip_top = VOLATILE_SUBDIRS.get(rel_t, set())
        h.update(f"{rel_t}:DIR\n".encode("utf-8"))
        for root, dirs, files in os.walk(t):
            rel_r = os.path.relpath(root, home)
            if rel_r == rel_t:
                dirs[:] = sorted(d for d in dirs if d not in skip_top)
            else:
                dirs.sort()
            h.update(f"D:{rel_r}\n".encode("utf-8"))
            for fn in sorted(files):
                if fn in VOLATILE_FILENAMES or fn.endswith((".sqlite", ".sqlite-wal", ".sqlite-shm", ".lock")):
                    continue
                fp = os.path.join(root, fn)
                rel_f = os.path.relpath(fp, home)
                try:
                    st = os.lstat(fp)
                    h.update(f"F:{rel_f}:{st.st_mode}:{st.st_size}".encode("utf-8"))
                    if st.st_size <= 8 * 1024 * 1024 and not os.path.islink(fp):
                        h.update(b":" + hashlib.sha256(open(fp, "rb").read()).hexdigest().encode("utf-8"))
                    h.update(b"\n")
                except OSError:
                    h.update(f"F:{rel_f}:ERR\n".encode("utf-8"))
    else:
        h.update(f"{rel_t}:OTHER:{st0.st_mode}\n".encode("utf-8"))

lib_hash = hashlib.sha256("\n".join(lib_entries).encode("utf-8")).hexdigest()
print(f"lib={lib_hash}|clients={h.hexdigest()}")
PY
}

snapshot_scholaros_tmpdir() {
    local exclude1="${1:-}"
    python3 -I - "${TMPDIR:-/tmp}" "$exclude1" <<'PY'
import os, sys

tdir, ex1 = sys.argv[1], sys.argv[2]
if not os.path.isdir(tdir):
    sys.exit(0)
prefixes = (
    "scholaros-reports.",
    "scholaros-m3-",
    "scholaros-m2-",
    "scholaros-m1-",
    "scholaros-hard-inputs.",
    "scholaros-bench-work.",
    "m2-regen.",
)
items = sorted(n for n in os.listdir(tdir) if n.startswith(prefixes) and n != ex1)
print("\n".join(items))
PY
}

swift_test_no_network() {
    if [[ "$DISABLE_SWIFTPM_SANDBOX" -eq 1 ]]; then
        swift_test "$@"
    elif /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' /usr/bin/true >/dev/null 2>&1; then
        local extra=("--disable-sandbox")
        if [[ -n "${SCHOLAR_BUILD_JOBS:-}" ]]; then
            extra+=("-j" "$SCHOLAR_BUILD_JOBS")
        fi
        /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' swift test "${extra[@]}" "$@"
    else
        swift_test "$@"
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
                if [[ "$RECORD" -eq 0 ]]; then
                    CREATED_REPORT_TMPDIR="$SCHOLAR_REPORT_DIR"
                fi
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
                if [[ "$RECORD" -eq 0 ]]; then
                    CREATED_REPORT_TMPDIR="$SCHOLAR_REPORT_DIR"
                fi
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

            2)
                TREE_BEFORE="$(working_tree_state)"
                PREFS_BEFORE="$(count_scholaros_preference_files)"
                CACHE_BEFORE="$(scholaros_cache_dir_state)"
                SCHOLAR_REPORT_DIR="$(select_report_dir "$RECORD")"
                if [[ "$RECORD" -eq 0 ]]; then
                    CREATED_REPORT_TMPDIR="$SCHOLAR_REPORT_DIR"
                fi
                export SCHOLAR_REPORT_DIR

                echo "[test.sh] Running M2 + M1 scoped unit tests..."
                swift_test --no-parallel --filter "(MarkupASTAndMacroTests|BibCSLAndFirewallTests|LSPEngineAndSyncTeXTests|ProjectStoreAndTrackChangesTests|PluginSDKMCPAndShellTests|ScholarStudioViewsTests|ZZZCacheHomeIsolationGuardTests)"
                echo "[test.sh] Running M1 benchmark Python tooling unit tests..."
                python3 -I -m unittest discover -s "$REPO_ROOT/Benchmarks/citations/tools/tests" -t "$REPO_ROOT/Benchmarks/citations/tools"

                run_m0_acceptance_scripts "$RECORD"

                require_executable "$REPO_ROOT/Scripts/acceptance/m1-acceptance.sh"
                require_executable "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py"
                require_executable "$REPO_ROOT/Scripts/acceptance/m2-acceptance.sh"
                require_executable "$REPO_ROOT/Scripts/acceptance/hard-inputs.sh"

                M2_FAILED=0
                echo "[test.sh] Running M1 acceptance script (regression check)..."
                set +e
                if [[ "$RECORD" -eq 1 ]]; then
                    "$REPO_ROOT/Scripts/acceptance/m1-acceptance.sh" --record
                else
                    "$REPO_ROOT/Scripts/acceptance/m1-acceptance.sh"
                fi
                M2_M1_ACC_EXIT=$?
                set -e
                if [[ "$M2_M1_ACC_EXIT" -ne 0 ]]; then
                    M2_FAILED=1
                fi

                echo "[test.sh] Running M1 citation benchmark (--replay)..."
                set +e
                if [[ "$RECORD" -eq 1 ]]; then
                    python3 -I "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py" --replay --record
                else
                    python3 -I "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py" --replay
                fi
                M2_M1_BENCH_EXIT=$?
                set -e
                if [[ "$M2_M1_BENCH_EXIT" -ne 0 ]]; then
                    M2_FAILED=1
                fi

                echo "[test.sh] Running M2 acceptance script..."
                set +e
                if [[ "$RECORD" -eq 1 ]]; then
                    "$REPO_ROOT/Scripts/acceptance/m2-acceptance.sh" --record
                else
                    "$REPO_ROOT/Scripts/acceptance/m2-acceptance.sh"
                fi
                M2_ACC_EXIT=$?
                set -e
                if [[ "$M2_ACC_EXIT" -ne 0 ]]; then
                    M2_FAILED=1
                fi

                echo "[test.sh] Running M2 hard-inputs fast check..."
                set +e
                "$REPO_ROOT/Scripts/acceptance/hard-inputs.sh"
                M2_HARD_EXIT=$?
                set -e
                if [[ "$M2_HARD_EXIT" -ne 0 ]]; then
                    M2_FAILED=1
                fi

                assert_post_run_hygiene "$RECORD" "$PREFS_BEFORE" "$CACHE_BEFORE" "$TREE_BEFORE"
                echo "[test.sh] Reports: $SCHOLAR_REPORT_DIR"
                if [[ "$M2_FAILED" -ne 0 ]]; then
                    echo "[test.sh] MILESTONE 2 FAILED (m1-acceptance exit=$M2_M1_ACC_EXIT, m1-citation-bench exit=$M2_M1_BENCH_EXIT, m2-acceptance exit=$M2_ACC_EXIT, hard-inputs exit=$M2_HARD_EXIT)." >&2
                    exit 1
                fi
                echo "[test.sh] MILESTONE 2 PASSED."
                ;;

            3)
                TREE_BEFORE="$(working_tree_state)"
                PREFS_BEFORE="$(count_scholaros_preference_files)"
                CACHE_BEFORE="$(scholaros_cache_dir_state)"
                FULL_HOME_BEFORE="$(snapshot_real_home_full_hygiene)"
                TMP_BEFORE="$(snapshot_scholaros_tmpdir)"
                BENCH_STATUS_BEFORE="$(git -C "$REPO_ROOT" status --porcelain -- Benchmarks || true)"

                SCHOLAR_REPORT_DIR="$(select_report_dir "$RECORD")"
                if [[ "$RECORD" -eq 0 ]]; then
                    CREATED_REPORT_TMPDIR="$SCHOLAR_REPORT_DIR"
                fi
                export SCHOLAR_REPORT_DIR

                M3_STEP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m3-step.XXXXXX")"
                mkdir -p "$M3_STEP_TMP/h-scope" "$M3_STEP_TMP/h-ut1" "$M3_STEP_TMP/h-ut2" "$M3_STEP_TMP/ut-cache" "$M3_STEP_TMP/h-m3"

                echo "[test.sh] Running M3 changed-module scoped unit tests..."
                (
                    unset SCHOLAR_CACHE_DIR
                    HOME="$M3_STEP_TMP/h-scope" CFFIXED_USER_HOME="$M3_STEP_TMP/h-scope" \
                        swift_test --no-parallel --filter "(BibCSLAndFirewallTests|LSPEngineAndSyncTeXTests|PluginSDKMCPAndShellTests|ZZZCacheHomeIsolationGuardTests)"
                )

                echo "[test.sh] Running network-denied full unit tests (without SCHOLAR_CACHE_DIR)..."
                (
                    unset SCHOLAR_CACHE_DIR
                    HOME="$M3_STEP_TMP/h-ut1" CFFIXED_USER_HOME="$M3_STEP_TMP/h-ut1" \
                        swift_test_no_network --no-parallel
                )

                echo "[test.sh] Running network-denied full unit tests (with SCHOLAR_CACHE_DIR)..."
                (
                    HOME="$M3_STEP_TMP/h-ut2" CFFIXED_USER_HOME="$M3_STEP_TMP/h-ut2" SCHOLAR_CACHE_DIR="$M3_STEP_TMP/ut-cache" \
                        swift_test_no_network --no-parallel
                )

                require_executable "$REPO_ROOT/Scripts/acceptance/m3-mcp.sh"

                M3_FAILED=0
                echo "[test.sh] Running milestone 2 regression suite..."
                set +e
                if [[ "$RECORD" -eq 1 ]]; then
                    "$REPO_ROOT/Scripts/test.sh" milestone 2 --record
                else
                    "$REPO_ROOT/Scripts/test.sh" milestone 2
                fi
                M3_M2_EXIT=$?
                set -e
                if [[ "$M3_M2_EXIT" -ne 0 ]]; then
                    M3_FAILED=1
                fi

                echo "[test.sh] Running M3 MCP acceptance script (m3-mcp.sh)..."
                M3_MCP_T0="$(python3 -I -c 'import time; print(f"{time.time():.6f}")')"
                set +e
                (
                    unset SCHOLAR_CACHE_DIR
                    HOME="$M3_STEP_TMP/h-m3" CFFIXED_USER_HOME="$M3_STEP_TMP/h-m3" \
                        "$REPO_ROOT/Scripts/acceptance/m3-mcp.sh" $([[ "$RECORD" -eq 1 ]] && echo "--record")
                )
                M3_ACC_EXIT=$?
                set -e
                M3_MCP_T1="$(python3 -I -c 'import time; print(f"{time.time():.6f}")')"
                M3_MCP_ELAPSED="$(python3 -I -c 'import sys; print(f"{float(sys.argv[2]) - float(sys.argv[1]):.2f}")' "$M3_MCP_T0" "$M3_MCP_T1")"
                echo "[test.sh] m3-mcp.sh exit=$M3_ACC_EXIT elapsed=${M3_MCP_ELAPSED}s"
                if [[ "$M3_ACC_EXIT" -ne 0 ]]; then
                    M3_FAILED=1
                fi

                rm -rf "$M3_STEP_TMP"
                M3_STEP_TMP=""
                if [[ "$RECORD" -eq 0 && -n "$CREATED_REPORT_TMPDIR" && -d "$CREATED_REPORT_TMPDIR" ]]; then
                    rm -rf "$CREATED_REPORT_TMPDIR"
                    CREATED_REPORT_TMPDIR=""
                fi

                assert_post_run_hygiene "$RECORD" "$PREFS_BEFORE" "$CACHE_BEFORE" "$TREE_BEFORE"

                FULL_HOME_AFTER="$(snapshot_real_home_full_hygiene)"
                TMP_AFTER="$(snapshot_scholaros_tmpdir)"
                BENCH_STATUS_AFTER="$(git -C "$REPO_ROOT" status --porcelain -- Benchmarks || true)"
                set +e
                git -C "$REPO_ROOT" diff --exit-code -- Benchmarks >/dev/null 2>&1
                BENCH_DIFF_EXIT=$?
                set -e

                if [[ "$TMP_BEFORE" != "$TMP_AFTER" ]]; then
                    echo "ERROR: temporary directories left behind in TMPDIR (before='$TMP_BEFORE' after='$TMP_AFTER')." >&2
                    exit 1
                fi
                if [[ "$FULL_HOME_BEFORE" != "$FULL_HOME_AFTER" ]]; then
                    echo "ERROR: real ~/Library ScholarOS entries or ~/.claude* / ~/.codex / ~/.config/opencode changed during milestone 3." >&2
                    exit 1
                fi
                if [[ "$BENCH_DIFF_EXIT" -ne 0 || "$BENCH_STATUS_BEFORE" != "$BENCH_STATUS_AFTER" ]]; then
                    echo "ERROR: Benchmarks/ changed during milestone 3 (git diff exit=$BENCH_DIFF_EXIT)." >&2
                    exit 1
                fi
                echo "[test.sh] Row 23 hygiene verified: temp dirs cleaned, real ~/Library & client configs untouched, Benchmarks/ clean."
                echo "[test.sh] Reports: $SCHOLAR_REPORT_DIR"
                if [[ "$M3_FAILED" -ne 0 ]]; then
                    echo "[test.sh] MILESTONE 3 FAILED (milestone2 exit=$M3_M2_EXIT, m3-mcp exit=$M3_ACC_EXIT)." >&2
                    exit 1
                fi
                echo "[test.sh] MILESTONE 3 PASSED (m3-mcp.sh elapsed=${M3_MCP_ELAPSED}s)."
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
        require_executable "$REPO_ROOT/Scripts/acceptance/m2-acceptance.sh"
        require_executable "$REPO_ROOT/Scripts/acceptance/hard-inputs.sh"

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

        echo "[test.sh] Running M2 acceptance script..."
        set +e
        if [[ "$RECORD" -eq 1 ]]; then
            "$REPO_ROOT/Scripts/acceptance/m2-acceptance.sh" --record
        else
            "$REPO_ROOT/Scripts/acceptance/m2-acceptance.sh"
        fi
        REL_M2_EXIT=$?
        set -e
        if [[ "$REL_M2_EXIT" -ne 0 ]]; then
            REL_FAILED=1
        fi

        echo "[test.sh] Running M2 hard-inputs fast check..."
        set +e
        "$REPO_ROOT/Scripts/acceptance/hard-inputs.sh"
        REL_HARD_EXIT=$?
        set -e
        if [[ "$REL_HARD_EXIT" -ne 0 ]]; then
            REL_FAILED=1
        fi

        require_executable "$REPO_ROOT/Scripts/acceptance/m3-mcp.sh"
        echo "[test.sh] Running M3 MCP acceptance script..."
        set +e
        if [[ "$RECORD" -eq 1 ]]; then
            "$REPO_ROOT/Scripts/acceptance/m3-mcp.sh" --record
        else
            "$REPO_ROOT/Scripts/acceptance/m3-mcp.sh"
        fi
        REL_M3_EXIT=$?
        set -e
        if [[ "$REL_M3_EXIT" -ne 0 ]]; then
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
