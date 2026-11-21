#!/usr/bin/env bash
#
# M4 Acceptance Row 10 source mutation verification (`Scripts/acceptance/m4-mutations.sh`).
#
# Copies the repository into an isolated temporary directory (never modifying source files in the
# working tree), applies each of the 5 M4 mutation patches (`Scripts/acceptance/mutations/m4-*.patch`)
# one at a time, compiles the mutated binary, runs `Scripts/acceptance/m4-acceptance.sh` on the targeted
# row, and verifies that each mutation fails on its expected row with a non-zero exit code:
#   (a) m4-01-disable-header-footer-strip.patch -> Row 6 fails (repeating headers/footers leak into body)
#   (b) m4-02-lower-keyword-threshold-005.patch -> Row 4 fails (unrelated/sentinel claims no longer NOT_FOUND)
#   (c) m4-03-disable-same-noun-agreement.patch -> Row 3 fails (same-noun value swaps/counts fall below 8/10)
#   (d) m4-04-mcp-skip-numeric-check.patch      -> Row 8 fails (MCP locate_evidence diverges from CLI --json)
#   (e) m4-05-full-page-bounding-box.patch      -> Row 5 fails (full-page mediaBox rejected by geometry check)
# Reverts each patch cleanly after running, rebuilds the reverted copy and runs the full `m4-acceptance.sh`
# suite to confirm 0 failures, and verifies `git status` / working tree state is untouched.
#
# Usage:
#   Scripts/acceptance/m4-mutations.sh [--record]
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
            echo "Usage: Scripts/acceptance/m4-mutations.sh [--record]" >&2
            exit 2
            ;;
    esac
done

if [[ "$RECORD" -eq 1 ]]; then
    if [[ -z "${SCHOLAR_REPORT_DIR:-}" || "${SCHOLAR_REPORT_DIR:-}" == "$REPO_ROOT/reports" ]]; then
        DIRTY_FOR_RECORD="$(git -C "$REPO_ROOT" status --porcelain)"
        if [[ -n "$DIRTY_FOR_RECORD" ]]; then
            echo "ERROR: --record requires a clean working tree before writing reports/m4-mutations.txt:" >&2
            echo "$DIRTY_FOR_RECORD" >&2
            exit 2
        fi
    fi
fi

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

REAL_USER_HOME="$(python3 -I -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
ORIG_STATUS_BEFORE="$(git -C "$REPO_ROOT" status --porcelain)"
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m4-mutations.XXXXXX")"
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
    CREATED_TEMP_REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m4-mut-report.XXXXXX")"
    REPORT_DIR="$CREATED_TEMP_REPORT_DIR"
fi
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/m4-mutations.txt"

export SCHOLAR_SANDBOX_HOME="$WORK/home"
mkdir -p "$SCHOLAR_SANDBOX_HOME/Library/Preferences" "$SCHOLAR_SANDBOX_HOME/Library/Caches"
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
    echo "== [M4 Row 10] Preparing isolated repository copy from HEAD ($HEAD_SHA) =="
    python3 -I - "$REPO_ROOT" "$COPY_DIR" <<'PY'
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
def ignore_fn(directory, contents):
    rel = os.path.relpath(directory, src)
    ignored = {".DS_Store", "__pycache__"}
    if rel == ".":
        ignored.update({".build", ".agy-coder", ".swiftpm"})
    return ignored & set(contents)
shutil.copytree(src, dst, symlinks=True, ignore=ignore_fn)
PY

    COPY_STATUS_BEFORE="$(git -C "$COPY_DIR" status --porcelain)"
    COPY_DIGEST_BEFORE="$(tree_digest "$COPY_DIR")"

    # Format: label|patch_name|run_rows|expected_rows|anchor_substr|where_changed|desc
    declare -a MUTATION_SPECS=(
        "a|m4-01-disable-header-footer-strip.patch|6|6|FAIL [Row 6] fixture s12_paper|Sources/ScholarPDFProvenance/PDFMultiColumnSegmenter.swift :: partitionMarginLines|Disable repeating margin header/footer stripping"
        "b|m4-02-lower-keyword-threshold-005.patch|4|4|RESULT [Row 4]: FAIL|Sources/ScholarPDFProvenance/EvidenceLocatorAndNumericChecker.swift :: defaultMinimumKeywordCoverage (0.60 -> 0.05)|Lower keyword coverage threshold to 0.05"
        "c|m4-03-disable-same-noun-agreement.patch|3|3|RESULT [Row 3]: FAIL|Sources/ScholarPDFProvenance/EvidenceLocatorAndNumericChecker.swift :: defaultRequireSameNounValueAgreement (true -> false)|Disable same-noun different-value check"
        "d|m4-04-mcp-skip-numeric-check.patch|8|8|RESULT [Row 8]: FAIL|Sources/ScholarCLIAndMCP/ScholarMCPServer.swift :: executeLocateEvidence|Skip numeric checking in MCP locate_evidence"
        "e|m4-05-full-page-bounding-box.patch|5|5|degenerate full-page bounding_box|Sources/ScholarPDFProvenance/PDFMultiColumnSegmenter.swift :: appendChunk|Replace passage bounding_box with full-page mediaBox"
    )

    OVERALL_OK=1

    for spec in "${MUTATION_SPECS[@]}"; do
        IFS='|' read -r label patch_name run_rows exp_rows anchor_sub where_changed desc <<< "$spec"
        patch_path="$COPY_DIR/Scripts/acceptance/mutations/$patch_name"
        log_file="$LOGS_DIR/mutation-${label}.log"

        echo ""
        echo "-- Mutation ($label): $patch_name ($desc) --"
        if [[ ! -f "$patch_path" ]]; then
            echo "  FAIL: Missing patch file Scripts/acceptance/mutations/$patch_name"
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
            SCHOLAR_M4_MUTATION_ACTIVE="$patch_name" \
            SCHOLAR_CLI_BIN="$COPY_DIR/.build/debug/ScholarOS" \
            "$COPY_DIR/Scripts/acceptance/m4-acceptance.sh" "${ROW_ARGS[@]}" >"$log_file" 2>&1
        ACC_RC=$?
        set -e

        set +e
        python3 -I - "$log_file" "$ACC_RC" "$exp_rows" "$anchor_sub" >"$WORK/check-${label}.out" <<'PY'
from __future__ import annotations
import re, sys

log_path, rc_str, exp_rows_str, anchor_sub = sys.argv[1:5]
rc = int(rc_str)
exp_rows = [int(x) for x in exp_rows_str.split(",") if x]

text = open(log_path, encoding="utf-8", errors="replace").read()
failed_rows = [int(m.group(1)) for m in re.finditer(r"^RESULT \[Row (\d+)\]: FAIL", text, flags=re.M)]

result_lines = [
    ln.strip()
    for ln in text.splitlines()
    if ln.strip().startswith("RESULT [Row ")
]
summary_one_line = result_lines[0] if result_lines else "(no RESULT line emitted)"
if len(summary_one_line) > 220:
    summary_one_line = summary_one_line[:217] + "..."

ok = True
reasons = []
if rc == 0:
    ok = False
    reasons.append("m4-acceptance.sh unexpectedly exited 0")

missing = [r for r in exp_rows if r not in failed_rows]
if missing:
    ok = False
    reasons.append(f"expected row(s) {exp_rows} to FAIL, missing={missing}, actual_failed={failed_rows}")

if anchor_sub != "-" and anchor_sub not in text:
    ok = False
    reasons.append(f"expected anchor {anchor_sub!r} not found in row output")

status = "PASS" if ok else "FAIL"
print(f"  failed_rows: {failed_rows} (expected {exp_rows}), m4-acceptance.sh exit={rc}")
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
    echo "-- Post-revert verification: rebuild reverted copy and run full m4-acceptance.sh --"
    swift_build_in "$COPY_DIR"
    REVERT_LOG="$LOGS_DIR/post-revert.log"
    set +e
    env -u SCHOLAR_REPORT_DIR \
        -u SCHOLAR_CACHE_DIR \
        HOME="$SCHOLAR_SANDBOX_HOME" \
        CFFIXED_USER_HOME="$SCHOLAR_SANDBOX_HOME" \
        SCHOLAR_CLI_BIN="$COPY_DIR/.build/debug/ScholarOS" \
        "$COPY_DIR/Scripts/acceptance/m4-acceptance.sh" >"$REVERT_LOG" 2>&1
    REVERT_RC=$?
    set -e
    if [[ "$REVERT_RC" -ne 0 ]]; then
        grep -E "FAIL" "$REVERT_LOG" | head -n 20 | sed 's/^/  /' || true
    fi
    tail -n 16 "$REVERT_LOG" | sed 's/^/  /'
    if [[ "$REVERT_RC" -ne 0 ]]; then
        echo "  FAIL: m4-acceptance.sh exited $REVERT_RC after reverting all patches"
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
        echo "PASS: M4 Row 10 mutations (a)-(e) verified and reverted cleanly."
    else
        echo "FAIL: M4 Row 10 mutation verification failed."
    fi
} | tee "$REPORT_FILE"

python3 -I "$REPO_ROOT/Scripts/acceptance/m4_harness.py" scrub-file \
    --file "$REPORT_FILE" \
    --real-home "$REAL_USER_HOME" \
    --repo-root "$REPO_ROOT"

if [[ -z "$CREATED_TEMP_REPORT_DIR" ]]; then
    echo "[m4-mutations] report written to reports/m4-mutations.txt" >&2
fi

if [[ "$(cat "$WORK/overall-ok.txt")" -eq 1 ]]; then
    exit 0
else
    exit 1
fi
