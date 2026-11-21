#!/usr/bin/env bash
#
# M3 Acceptance Row 21 source mutation verification (`Scripts/acceptance/m3-mutations.sh`).
#
# Copies the repository into an isolated temporary directory (never modifying source files in the
# working tree), applies each of the 8 M3 mutation patches (`Scripts/acceptance/mutations/m3-*.patch`)
# one at a time, compiles the mutated binary, runs `Scripts/acceptance/m3-mcp.sh` on the targeted
# row(s), and verifies that each mutation fails on its expected row with a non-zero exit code:
#   (a) m3-01-allow-not-found.patch          -> Row 2 fails
#   (b) m3-02-offline-skip-verify-write.patch -> Row 8 fails
#   (c) m3-03-disable-deduplication.patch    -> Row 7 fails
#   (d) m3-04-write-caller-fields.patch      -> Row 6 fails
#   (e) m3-05-restore-replay-path-arg.patch  -> Row 10 fails
#   (f) m3-06-rewrite-whole-bib-file.patch   -> Row 5 or Row 13 fails (original bytes no longer prefix)
#   (g) m3-07-read-cache-on-write.patch      -> Row 9 fails
#   (h) m3-08-legacy-batch-offline.patch     -> Row 16 fails
# Reverts each patch cleanly after running, rebuilds the reverted copy and runs the full `m3-mcp.sh`
# suite to confirm 0 failures, and verifies `git status` / working tree state is untouched.
#
# Usage:
#   Scripts/acceptance/m3-mutations.sh [--record]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

RECORD=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --record)
            RECORD=1
            shift
            ;;
        *)
            echo "Usage: Scripts/acceptance/m3-mutations.sh [--record]" >&2
            exit 2
            ;;
    esac
done

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
        echo "ERROR: SCHOLAR_OUTER_NO_NETWORK=1 requires an active network-denying sandbox." >&2
        exit 2
    fi
    DISABLE_SWIFTPM_SANDBOX=1
    export SCHOLAR_OUTER_NO_NETWORK=1
fi

swift_build_in() {
    local dir="$1"
    shift
    local extra=()
    if [[ "$DISABLE_SWIFTPM_SANDBOX" -eq 1 ]]; then
        extra+=("--disable-sandbox")
    fi
    if [[ -n "${SCHOLAR_BUILD_JOBS:-}" ]]; then
        extra+=("-j" "$SCHOLAR_BUILD_JOBS")
    fi
    if [[ "${#extra[@]}" -gt 0 ]]; then
        (cd "$dir" && swift build "${extra[@]}" "$@" >/dev/null)
    else
        (cd "$dir" && swift build "$@" >/dev/null)
    fi
}

ORIG_STATUS_BEFORE="$(git -C "$REPO_ROOT" status --porcelain)"
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m3-mutations.XXXXXX")"
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
    CREATED_TEMP_REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m3-mut-report.XXXXXX")"
    REPORT_DIR="$CREATED_TEMP_REPORT_DIR"
fi
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/m3-mutations.txt"

export SCHOLAR_SANDBOX_HOME="$WORK/home"
mkdir -p "$SCHOLAR_SANDBOX_HOME"
unset SCHOLAR_CACHE_DIR

# shellcheck source=Scripts/acceptance/lib-cli-guard.sh
source "$REPO_ROOT/Scripts/acceptance/lib-cli-guard.sh"

COPY_DIR="$WORK/copy"
LOGS_DIR="$WORK/logs"
mkdir -p "$LOGS_DIR"

tree_digest() {
    python3 -I - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
h = hashlib.sha256()
for sub in ("Sources", "Tests", "Scripts", "Benchmarks", "Package.swift"):
    p = os.path.join(root, sub)
    if os.path.isfile(p):
        h.update(sub.encode("utf-8") + b"\0" + hashlib.sha256(open(p, "rb").read()).digest() + b"\n")
    elif os.path.isdir(p):
        for dirpath, dirnames, filenames in os.walk(p):
            dirnames[:] = sorted(d for d in dirnames if d not in (".build", "__pycache__"))
            for fn in sorted(filenames):
                fp = os.path.join(dirpath, fn)
                if os.path.islink(fp):
                    h.update(os.path.relpath(fp, root).encode("utf-8") + b"->" + os.readlink(fp).encode("utf-8") + b"\n")
                elif os.path.isfile(fp):
                    h.update(os.path.relpath(fp, root).encode("utf-8") + b"\0" + hashlib.sha256(open(fp, "rb").read()).digest() + b"\n")
print(h.hexdigest())
PY
}

{
    echo "== [M3 Row 21] Preparing isolated repository copy from HEAD ($HEAD_SHA) =="
    python3 -I - "$REPO_ROOT" "$COPY_DIR" <<'PY'
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
def ignore_fn(directory, contents):
    rel = os.path.relpath(directory, src)
    ignored = {".DS_Store"}
    if rel == ".":
        ignored.update({".build", ".agy-coder", ".swiftpm"})
    return ignored & set(contents)
shutil.copytree(src, dst, symlinks=True, ignore=ignore_fn)
PY

    COPY_STATUS_BEFORE="$(git -C "$COPY_DIR" status --porcelain)"
    COPY_DIGEST_BEFORE="$(tree_digest "$COPY_DIR")"

    # Format: label|patch_name|run_rows|require_mode(all|any)|expected_rows|anchor_substr|where_changed|desc
    declare -a MUTATION_SPECS=(
        "a|m3-01-allow-not-found.patch|2|all|2|-|Sources/ScholarCLIAndMCP/ScholarMCPServer.swift :: executeAddVerifiedBibTeX (guard allows .notFound)|Allow NOT_FOUND verdicts through add_verified_bibtex"
        "b|m3-02-offline-skip-verify-write.patch|8|all|8|-|Sources/ScholarCLIAndMCP/ScholarMCPServer.swift :: executeAddVerifiedBibTeX (if isOffline or callOffline writes directly)|Skip verification when offline and write directly"
        "c|m3-03-disable-deduplication.patch|7|all|7|-|Sources/ScholarBibAndCSL/VerifiedBibTeXWriter.swift :: checkDuplicate(candidate:existingEntries:) (returns .allowAppend)|Disable bibliography deduplication and key-conflict checks"
        "d|m3-04-write-caller-fields.patch|6|all|6|-|Sources/ScholarBibAndCSL/VerifiedBibTeXWriter.swift :: generateEntry (serializes caller localEntry fields)|Write caller-supplied fields instead of registry record fields"
        "e|m3-05-restore-replay-path-arg.patch|10|all|10|-|Sources/ScholarCLIAndMCP/ScholarMCPServer.swift :: defaultToolDefinitions & resolveVerificationMode (restores registryReplayPath)|Restore caller registryReplayPath tool parameter"
        "f|m3-06-rewrite-whole-bib-file.patch|5,13|any|5,13|prefix|Sources/ScholarBibAndCSL/VerifiedBibTeXWriter.swift :: appendVerifiedEntryInternal (ftruncate + whole-file serialize)|Read whole .bib and rewrite instead of O_APPEND"
        "g|m3-07-read-cache-on-write.patch|9|all|9|-|Sources/ScholarCLIAndMCP/ScholarMCPServer.swift :: executeAddVerifiedBibTeX (skipCacheRead: true -> false)|Read SQLite cache during add_verified_bibtex write"
        "h|m3-08-legacy-batch-offline.patch|16|all|16|-|Sources/ScholarCLIAndMCP/ScholarMCPServer.swift :: executeScholarVerifyBibliography (forces mode = .offline)|Switch retained legacy batch tool scholar_verify_bibliography to offline mode"
    )

    OVERALL_OK=1

    for spec in "${MUTATION_SPECS[@]}"; do
        IFS='|' read -r label patch_name run_rows req_mode exp_rows anchor_sub where_changed desc <<< "$spec"
        patch_path="$COPY_DIR/Scripts/acceptance/mutations/$patch_name"
        log_file="$LOGS_DIR/mutation-${label}.log"

        echo ""
        echo "-- Mutation ($label): $patch_name ($desc) --"
        if [[ ! -f "$patch_path" ]]; then
            echo "  FAIL: Missing patch file $patch_path"
            OVERALL_OK=0
            continue
        fi

        PATCH_LOC="$(python3 -I - "$patch_path" <<'PY'
import re, sys
txt = open(sys.argv[1], encoding="utf-8").read()
files = re.findall(r"^\+\+\+ b/(.+)$", txt, flags=re.M)
hunks = re.findall(r"^@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@", txt, flags=re.M)
f_str = ", ".join(sorted(set(files))) if files else "unknown"
h_str = ", ".join(f"L{ln}" for ln in hunks) if hunks else "L?"
print(f"{f_str} ({h_str})")
PY
)"
        echo "  modified: $where_changed [$PATCH_LOC]"

        git -C "$COPY_DIR" apply "$patch_path"
        swift_build_in "$COPY_DIR"

        ROW_ARGS=()
        if [[ "$run_rows" == *","* ]]; then
            ROW_ARGS=("--rows" "$run_rows")
        else
            ROW_ARGS=("--row" "$run_rows")
        fi

        set +e
        env -u SCHOLAR_REPORT_DIR \
            -u SCHOLAR_CACHE_DIR \
            HOME="$SCHOLAR_SANDBOX_HOME" \
            CFFIXED_USER_HOME="$SCHOLAR_SANDBOX_HOME" \
            SCHOLAR_M3_MUTATION_ACTIVE="$patch_name" \
            SCHOLAR_CLI_BIN="$COPY_DIR/.build/debug/ScholarOS" \
            "$COPY_DIR/Scripts/acceptance/m3-mcp.sh" "${ROW_ARGS[@]}" >"$log_file" 2>&1
        ACC_RC=$?
        set -e

        set +e
        python3 -I - "$log_file" "$ACC_RC" "$req_mode" "$exp_rows" "$anchor_sub" >"$WORK/check-${label}.out" <<'PY'
from __future__ import annotations
import re, sys

log_path, rc_str, req_mode, exp_rows_str, anchor_sub = sys.argv[1:6]
rc = int(rc_str)
exp_rows = [int(x) for x in exp_rows_str.split(",") if x]

text = open(log_path, encoding="utf-8", errors="replace").read()
failed_rows = [int(m.group(1)) for m in re.finditer(r"^RESULT \[Row (\d+)\]: FAIL", text, flags=re.M)]

fail_lines = [
    ln.strip()
    for ln in text.splitlines()
    if ln.strip().startswith("FAIL [Row ")
]
summary_one_line = fail_lines[0] if fail_lines else "(no FAIL detail line emitted)"
if len(summary_one_line) > 200:
    summary_one_line = summary_one_line[:197] + "..."

ok = True
reasons = []

if rc == 0:
    ok = False
    reasons.append("m3-mcp.sh unexpectedly exited 0")

if req_mode == "any":
    hit = [r for r in exp_rows if r in failed_rows]
    if not hit:
        ok = False
        reasons.append(f"expected at least one of row(s) {exp_rows} to FAIL, actual_failed={failed_rows}")
else:
    missing = [r for r in exp_rows if r not in failed_rows]
    if missing:
        ok = False
        reasons.append(f"expected row(s) {exp_rows} to FAIL, missing={missing}, actual_failed={failed_rows}")

if anchor_sub != "-":
    if not any(anchor_sub.lower() in ln.lower() for ln in fail_lines):
        ok = False
        reasons.append(f"expected failure detail containing {anchor_sub!r}, got {fail_lines!r}")

status = "PASS" if ok else "FAIL"
print(f"  failed_rows: {failed_rows} (expected {req_mode} of {exp_rows}), m3-mcp.sh exit={rc}")
print(f"  summary: {summary_one_line}")
print(f"  [{status}] mutation caught as expected")
if not ok:
    for r in reasons:
        print(f"    reason: {r}")
    sys.exit(1)
sys.exit(0)
PY
        CHECK_RC=$?
        set -e
        cat "$WORK/check-${label}.out"
        if [[ "$CHECK_RC" -ne 0 ]]; then
            OVERALL_OK=0
        fi

        # Revert mutation in temporary copy and verify byte-identical restoration
        git -C "$COPY_DIR" apply -R "$patch_path"
        COPY_STATUS_NOW="$(git -C "$COPY_DIR" status --porcelain)"
        COPY_DIGEST_NOW="$(tree_digest "$COPY_DIR")"
        if [[ "$COPY_STATUS_NOW" != "$COPY_STATUS_BEFORE" || "$COPY_DIGEST_NOW" != "$COPY_DIGEST_BEFORE" ]]; then
            echo "  FAIL: Temporary copy did not revert cleanly after $patch_name"
            OVERALL_OK=0
        fi
    done

    echo ""
    echo "-- Post-revert verification: rebuild reverted copy (CLI + tests) and run m3-mcp.sh --"
    swift_build_in "$COPY_DIR"
    swift_build_in "$COPY_DIR" --build-tests
    REVERT_LOG="$LOGS_DIR/post-revert.log"
    set +e
    env -u SCHOLAR_REPORT_DIR \
        -u SCHOLAR_CACHE_DIR \
        HOME="$SCHOLAR_SANDBOX_HOME" \
        CFFIXED_USER_HOME="$SCHOLAR_SANDBOX_HOME" \
        SCHOLAR_CLI_BIN="$COPY_DIR/.build/debug/ScholarOS" \
        "$COPY_DIR/Scripts/acceptance/m3-mcp.sh" >"$REVERT_LOG" 2>&1
    REVERT_RC=$?
    set -e
    if [[ "$REVERT_RC" -ne 0 ]]; then
        grep -E "FAIL|m3_mcp_elapsed" "$REVERT_LOG" | head -n 20 | sed 's/^/  /' || true
    fi
    tail -n 6 "$REVERT_LOG" | sed 's/^/  /'
    if [[ "$REVERT_RC" -ne 0 ]]; then
        echo "  FAIL: m3-mcp.sh exited $REVERT_RC after reverting all patches"
        OVERALL_OK=0
    fi

    COPY_STATUS_AFTER="$(git -C "$COPY_DIR" status --porcelain)"
    COPY_DIGEST_AFTER="$(tree_digest "$COPY_DIR")"
    ORIG_STATUS_AFTER="$(git -C "$REPO_ROOT" status --porcelain)"

    echo ""
    echo "== Git status & working tree hygiene =="
    echo "  copy_tree_restored=$([[ "$COPY_STATUS_AFTER" == "$COPY_STATUS_BEFORE" && "$COPY_DIGEST_AFTER" == "$COPY_DIGEST_BEFORE" ]] && echo true || echo false)"
    echo "  origin_working_tree_unchanged=$([[ "$ORIG_STATUS_AFTER" == "$ORIG_STATUS_BEFORE" ]] && echo true || echo false)"
    echo "  origin_git_status_clean=$([[ -z "$ORIG_STATUS_AFTER" ]] && echo true || echo "unchanged")"
    if [[ "$COPY_STATUS_AFTER" != "$COPY_STATUS_BEFORE" || "$COPY_DIGEST_AFTER" != "$COPY_DIGEST_BEFORE" || "$ORIG_STATUS_AFTER" != "$ORIG_STATUS_BEFORE" ]]; then
        OVERALL_OK=0
    fi

    echo "$OVERALL_OK" > "$WORK/overall-ok.txt"
    if [[ "$OVERALL_OK" -eq 1 ]]; then
        echo "PASS: M3 Row 21 mutations (a)-(h) verified and reverted cleanly."
    else
        echo "FAIL: M3 Row 21 mutation verification failed."
    fi
} | tee "$REPORT_FILE"

if [[ -z "$CREATED_TEMP_REPORT_DIR" ]]; then
    echo "[m3-mutations] report written to $REPORT_FILE" >&2
fi

if [[ "$(cat "$WORK/overall-ok.txt")" -eq 1 ]]; then
    exit 0
else
    exit 1
fi
