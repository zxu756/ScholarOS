#!/usr/bin/env bash
#
# M2 Acceptance Row 17 source mutation verification (`Scripts/acceptance/m2-mutations.sh`).
#
# Clones the current HEAD into a temporary directory, applies each of the 5 M2 mutation patches
# (`Scripts/acceptance/mutations/m2-*.patch`) one at a time, builds the mutated binary, runs
# `Scripts/acceptance/m2-acceptance.sh`, verifies that the expected row(s) fail:
#   (a) m2-01-disable-verbatim-skip.patch        -> Row 7 fails
#   (b) m2-02-bibtex-abort-on-error.patch        -> Row 10 fails
#   (c) m2-03-bibtex-strict-field-chars.patch    -> Row 6 fails on 2503.18124
#   (d) m2-04-drop-thebibliography-and-bbl.patch -> Rows 4 and 5 fail
#   (e) m2-05-suppress-sym003.patch              -> Row 2 fails on 2503.18124
# Reverts each patch cleanly after running, re-runs `m2-acceptance.sh` once after all patches are
# reverted to verify 0 failures, and confirms both the clone and original repository have a clean
# `git status`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if [[ $# -gt 0 ]]; then
    echo "Usage: Scripts/acceptance/m2-mutations.sh" >&2
    exit 2
fi

ORIG_STATUS_BEFORE="$(git -C "$REPO_ROOT" status --porcelain)"
if [[ -n "$ORIG_STATUS_BEFORE" ]]; then
    echo "FAIL: Original repository working tree is not clean before running m2-mutations.sh:" >&2
    echo "$ORIG_STATUS_BEFORE" >&2
    exit 2
fi

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m2-mutations.XXXXXX")"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

export SCHOLAR_SANDBOX_HOME="$WORK/home"
mkdir -p "$SCHOLAR_SANDBOX_HOME"
unset SCHOLAR_CACHE_DIR

# shellcheck source=Scripts/acceptance/lib-cli-guard.sh
source "$REPO_ROOT/Scripts/acceptance/lib-cli-guard.sh"

CLONE_DIR="$WORK/clone"
LOGS_DIR="$WORK/logs"
mkdir -p "$LOGS_DIR"

echo "== [M2 Row 17] Cloning HEAD ($HEAD_SHA) into isolated temp workspace =="
git clone --quiet --no-hardlinks "$REPO_ROOT" "$CLONE_DIR"
git -C "$CLONE_DIR" checkout --quiet --detach "$HEAD_SHA"

declare -a MUTATION_SPECS=(
    "a|m2-01-disable-verbatim-skip.patch|7|-|Disable Stage 03 opaque verbatim skipping"
    "b|m2-02-bibtex-abort-on-error.patch|10|-|Abort BibTeX parsing on first entry error"
    "c|m2-03-bibtex-strict-field-chars.patch|6|6:2503.18124|Restrict BibTeX field names to [A-Za-z0-9_:-]"
    "d|m2-04-drop-thebibliography-and-bbl.patch|4,5|-|Drop thebibliography and .bbl bibliography sources"
    "e|m2-05-suppress-sym003.patch|2|2:2503.18124|Suppress SYM003 duplicate label diagnostics"
)

OVERALL_OK=1

for spec in "${MUTATION_SPECS[@]}"; do
    IFS='|' read -r label patch_name expected_rows paper_anchor desc <<< "$spec"
    patch_path="$CLONE_DIR/Scripts/acceptance/mutations/$patch_name"
    log_file="$LOGS_DIR/mutation-${label}.log"

    echo ""
    echo "-- Mutation ($label): $patch_name ($desc) --"
    if [[ ! -f "$patch_path" ]]; then
        echo "  FAIL: Missing patch file $patch_path"
        OVERALL_OK=0
        continue
    fi

    git -C "$CLONE_DIR" apply "$patch_path"
    (cd "$CLONE_DIR" && swift build >/dev/null)

    set +e
    env -u SCHOLAR_REPORT_DIR \
        SCHOLAR_M2_MUTATION_ACTIVE="$patch_name" \
        SCHOLAR_CLI_BIN="$CLONE_DIR/.build/debug/ScholarOS" \
        "$CLONE_DIR/Scripts/acceptance/m2-acceptance.sh" >"$log_file" 2>&1
    ACC_RC=$?
    set -e

    set +e
    python3 -I - "$log_file" "$ACC_RC" "$expected_rows" "$paper_anchor" >"$WORK/check-${label}.out" <<'PY'
import re, sys

log_path, rc_str, exp_rows_str, paper_anchor = sys.argv[1:5]
rc = int(rc_str)
exp_rows = [int(x) for x in exp_rows_str.split(",") if x]

text = open(log_path, encoding="utf-8", errors="replace").read()

failed_rows = [int(m.group(1)) for m in re.finditer(r"^RESULT \[Row (\d+)\]: FAIL", text, flags=re.M)]

# Extract section blocks per row: `== [Row N] ...` up to `RESULT [Row N]: ...`
row_blocks = {}
for m in re.finditer(r"^== \[Row (\d+)\][^\n]*\n(.*?)^RESULT \[Row \1\]:[^\n]*$", text, flags=re.M | re.S):
    row_blocks[int(m.group(1))] = m.group(2)

ok = True
reasons = []

if rc == 0:
    ok = False
    reasons.append("m2-acceptance.sh unexpectedly exited 0")

missing_exp = [r for r in exp_rows if r not in failed_rows]
if missing_exp:
    ok = False
    reasons.append(f"expected row(s) {exp_rows} to FAIL, missing={missing_exp}, actual_failed={failed_rows}")

anchor_note = ""
if paper_anchor != "-":
    row_s, substr = paper_anchor.split(":", 1)
    anchor_row = int(row_s)
    blk = row_blocks.get(anchor_row, "")
    matching_lines = [
        ln.strip()
        for ln in blk.splitlines()
        if substr in ln and ("FAIL" in ln or "差异" in ln)
    ]
    if not matching_lines:
        ok = False
        reasons.append(f"Row {anchor_row} output did not show {substr} failing")
    else:
        anchor_note = f", anchor({anchor_row}:{substr})={matching_lines[0]!r}"

status = "PASS" if ok else "FAIL"
print(f"  [{status}] exit={rc}, failed_rows={failed_rows}, expected_failed_rows={exp_rows}{anchor_note}")
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

    # Revert mutation and verify clone working tree is clean before next mutation
    git -C "$CLONE_DIR" apply -R "$patch_path"
    CLONE_DIRTY="$(git -C "$CLONE_DIR" status --porcelain)"
    if [[ -n "$CLONE_DIRTY" ]]; then
        echo "  FAIL: Clone working tree dirty after reverting $patch_name:"
        echo "$CLONE_DIRTY"
        git -C "$CLONE_DIR" checkout -- .
        git -C "$CLONE_DIR" clean -fd
        OVERALL_OK=0
    fi
done

echo ""
echo "-- Post-revert verification: rebuild reverted clone and run m2-acceptance.sh --"
(cd "$CLONE_DIR" && swift build >/dev/null)
REVERT_LOG="$LOGS_DIR/post-revert.log"
set +e
env -u SCHOLAR_REPORT_DIR \
    SCHOLAR_CLI_BIN="$CLONE_DIR/.build/debug/ScholarOS" \
    "$CLONE_DIR/Scripts/acceptance/m2-acceptance.sh" >"$REVERT_LOG" 2>&1
REVERT_RC=$?
set -e
tail -n 6 "$REVERT_LOG" | sed 's/^/  /'
if [[ "$REVERT_RC" -ne 0 ]]; then
    echo "  FAIL: m2-acceptance.sh exited $REVERT_RC after reverting all patches"
    OVERALL_OK=0
fi

CLONE_STATUS_AFTER="$(git -C "$CLONE_DIR" status --porcelain)"
ORIG_STATUS_AFTER="$(git -C "$REPO_ROOT" status --porcelain)"
echo ""
echo "== Git status hygiene =="
echo "  clone_git_status_clean=$([[ -z "$CLONE_STATUS_AFTER" ]] && echo true || echo false)"
echo "  origin_repo_git_status_clean=$([[ -z "$ORIG_STATUS_AFTER" ]] && echo true || echo false)"
if [[ -n "$CLONE_STATUS_AFTER" || -n "$ORIG_STATUS_AFTER" ]]; then
    OVERALL_OK=0
fi

if [[ "$OVERALL_OK" -eq 1 ]]; then
    echo "PASS: M2 Row 17 mutations (a)-(e) verified and reverted cleanly."
    exit 0
else
    echo "FAIL: M2 Row 17 mutation verification failed." >&2
    exit 1
fi
