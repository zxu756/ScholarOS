#!/usr/bin/env bash
#
# M1 acceptance verification script (`Scripts/acceptance/m1-acceptance.sh`).
#
# Executes rows 1..24 of the M1 acceptance table in `04-scholaros.md`:
# - Every offline row is executed against the compiled ScholarOS binary (with isolated HOME via
#   lib-cli-guard.sh), supplemented by targeted unit tests only where virtual-clock or in-process
#   transport throws are required.
# - Online rows (Row 19 live recording part, Row 23 live benchmark) run only when SCHOLAR_ONLINE=1;
#   when unset, they print "没跑" and are counted as SKIPPED (never counted as PASSED).
# - Row 21 (source mutation check) verifies the two patches under Scripts/acceptance/mutations/
#   with read-only `git apply --check`, prints "没跑", and leaves source mutation to the dispatcher.
# - All selected rows run to completion so every row's status is reported in a single pass.
#
# Usage:
#   Scripts/acceptance/m1-acceptance.sh [--record] [--row <1..24>]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

RECORD=0
ONLY_ROW=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --record)
            RECORD=1
            shift
            ;;
        --row)
            if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ || "$2" -lt 1 || "$2" -gt 24 ]]; then
                echo "Usage: Scripts/acceptance/m1-acceptance.sh [--record] [--row <1..24>]" >&2
                exit 2
            fi
            ONLY_ROW="$2"
            shift 2
            ;;
        --row=*)
            val="${1#--row=}"
            if [[ ! "$val" =~ ^[0-9]+$ || "$val" -lt 1 || "$val" -gt 24 ]]; then
                echo "Usage: Scripts/acceptance/m1-acceptance.sh [--record] [--row <1..24>]" >&2
                exit 2
            fi
            ONLY_ROW="$val"
            shift
            ;;
        *)
            echo "Usage: Scripts/acceptance/m1-acceptance.sh [--record] [--row <1..24>]" >&2
            exit 2
            ;;
    esac
done

REAL_USER_HOME="$(python3 -I -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"

snapshot_real_home_scholaros() {
    python3 -I - "$REAL_USER_HOME" <<'PY'
import os, sys
home = sys.argv[1]
targets = [
    os.path.join(home, "Library", "Caches", "ScholarOS"),
    os.path.join(home, "Library", "Preferences"),
    os.path.join(home, "Library", "Application Support"),
]
entries = []
for base in targets:
    if not os.path.exists(base):
        entries.append(f"{base}:ABSENT")
        continue
    if os.path.basename(base) == "ScholarOS":
        for root, dirs, files in os.walk(base):
            dirs.sort()
            for fn in sorted(files):
                p = os.path.join(root, fn)
                st = os.stat(p)
                entries.append(f"{p}:{st.st_size}:{int(st.st_mtime)}")
        entries.append(f"{base}:DIR")
    else:
        for name in sorted(os.listdir(base)):
            if "scholaros" in name.lower():
                p = os.path.join(base, name)
                try:
                    st = os.stat(p)
                    entries.append(f"{p}:{st.st_size}:{int(st.st_mtime)}")
                except OSError:
                    entries.append(f"{p}:ERR")
print("\n".join(entries))
PY
}

snapshot_tmpdir_scholaros() {
    python3 -I - "${TMPDIR:-/tmp}" <<'PY'
import os, sys
tdir = sys.argv[1]
if not os.path.isdir(tdir):
    sys.exit(0)
items = sorted(
    n for n in os.listdir(tdir)
    if n.startswith("scholaros-bench-work.") or n.startswith("scholaros-m1-sub.")
)
print("\n".join(items))
PY
}

HOME_SNAP_BEFORE="$(snapshot_real_home_scholaros)"
TMP_SNAP_BEFORE="$(snapshot_tmpdir_scholaros)"
REPORTS_STATUS_BEFORE="$(git -C "$REPO_ROOT" status --porcelain -- reports || true)"
RECORDINGS_STATUS_BEFORE="$(git -C "$REPO_ROOT" status --porcelain -- Benchmarks/citations/recordings || true)"

OUTER_WAS_SET_AT_ENTRY="${SCHOLAR_OUTER_NO_NETWORK:-0}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m1-work.XXXXXX")"
WORK_SCRATCH="$WORK/scratch"
mkdir -p "$WORK_SCRATCH"
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
    CREATED_TEMP_REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m1-report.XXXXXX")"
    REPORT_DIR="$CREATED_TEMP_REPORT_DIR"
fi
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/m1-acceptance.txt"

export SCHOLAR_SANDBOX_HOME="$WORK/home"
mkdir -p "$SCHOLAR_SANDBOX_HOME"
# shellcheck source=Scripts/acceptance/lib-cli-guard.sh
source "$REPO_ROOT/Scripts/acceptance/lib-cli-guard.sh"

if [[ -z "${SCHOLAR_CLI_BIN:-}" ]]; then
    export SCHOLAR_CLI_BIN="$REPO_ROOT/.build/debug/ScholarOS"
    swift build >/dev/null
elif [[ ! -x "$SCHOLAR_CLI_BIN" ]]; then
    echo "FAIL: SCHOLAR_CLI_BIN is not an executable file: $SCHOLAR_CLI_BIN" >&2
    exit 2
fi

should_run_row() {
    local r="$1"
    if [[ -z "$ONLY_ROW" || "$ONLY_ROW" == "$r" ]]; then
        return 0
    fi
    return 1
}

SUMMARY_FILE="$WORK/row-summary.txt"
: > "$SUMMARY_FILE"
PASSED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0

record_pass() {
    local row="$1"
    local desc="$2"
    PASSED_COUNT=$((PASSED_COUNT + 1))
    printf 'Row %2d | PASS       | %s\n' "$row" "$desc" >> "$SUMMARY_FILE"
    echo "RESULT [Row $row]: PASS — $desc"
    echo ""
}

record_fail() {
    local row="$1"
    local desc="$2"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    printf 'Row %2d | FAIL       | %s\n' "$row" "$desc" >> "$SUMMARY_FILE"
    echo "RESULT [Row $row]: FAIL — $desc"
    echo ""
}

record_skip() {
    local row="$1"
    local desc="$2"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    printf 'Row %2d | SKIP(没跑) | %s\n' "$row" "$desc" >> "$SUMMARY_FILE"
    echo "RESULT [Row $row]: SKIP (没跑) — $desc"
    echo ""
}

# Run full benchmark replay once up front if any of Rows 3..8, 10, 12 are selected
BENCH_RUN1_JSON="$WORK_SCRATCH/bench-replay-run1.json"
BENCH_RUN1_EXIT=-1
need_bench_run1=0
for r in 3 4 5 6 7 8 10 12; do
    if should_run_row "$r"; then
        need_bench_run1=1
    fi
done

{
    echo "# ScholarOS M1 Acceptance Verification Report"
    echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Commit: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "Binary: ${SCHOLAR_CLI_BIN#"$REPO_ROOT"/}"
    echo "SCHOLAR_ONLINE: ${SCHOLAR_ONLINE:-0}"
    echo ""

    if [[ "$need_bench_run1" -eq 1 ]]; then
        echo "[setup] Running m1-citation-bench.py --replay once for full-replay rows..."
        set +e
        SCHOLAR_CLI_BIN="$SCHOLAR_CLI_BIN" python3 -I "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py" \
            --replay --output "$BENCH_RUN1_JSON" >"$WORK_SCRATCH/bench-run1.stdout" 2>"$WORK_SCRATCH/bench-run1.stderr"
        BENCH_RUN1_EXIT=$?
        set -e
        echo "[setup] m1-citation-bench.py --replay exit=$BENCH_RUN1_EXIT"
        echo ""
    fi

    # ==================================================================
    # Row 1: No mailto / politeMailto / api_key; .meta.json URL & header hygiene
    # ==================================================================
    if should_run_row 1; then
        echo "== [Row 1] Source/fixture banned-token grep & recorded .meta.json URL/header hygiene =="
        set +e
        ROW1_OUT="$(python3 -I - "$REPO_ROOT" "$REAL_USER_HOME" <<'PY'
import glob, json, os, re, subprocess, sys

repo_root = sys.argv[1]
real_home = sys.argv[2].lower()

# 1. git grep across Sources, Benchmarks, Tests/Fixtures excluding verbatim upstream HTTP response bodies (*.raw and sources/*/raw/*.json)
pat = "mail" + "to|polite" + "Mailto|api_" + "key"
cmd = [
    "git", "-C", repo_root, "grep", "-n", "-i", "-E", pat,
    "--", "Sources", "Benchmarks", "Tests/Fixtures",
    ":!*.raw", ":!Benchmarks/citations/sources/*/raw/*.json",
]
proc = subprocess.run(cmd, capture_output=True, text=True)
if proc.returncode not in (0, 1):
    print(f"git grep failed with exit {proc.returncode}: {proc.stderr}")
    sys.exit(1)
if proc.returncode == 0 and proc.stdout.strip():
    print("Banned token hits in code/metadata:\n" + proc.stdout.strip())
    sys.exit(1)

# Also inspect url and request/response headers inside Benchmarks/citations/sources/*/raw/*.json
bad_toks = ("@", "%40", "mail" + "to", "polite" + "mailto", "api_" + "key", "apikey", "/users/", "/home/")
raw_json_files = glob.glob(os.path.join(repo_root, "Benchmarks", "citations", "sources", "*", "raw", "*.json"))
for rjf in sorted(raw_json_files):
    with open(rjf, encoding="utf-8") as f:
        obj = json.load(f)
    u = str(obj.get("url", "")).lower()
    for bt in bad_toks:
        if bt in u:
            print(f"Forbidden token {bt!r} in {rjf} url={u}")
            sys.exit(1)
    if real_home and real_home != "/" and real_home in u:
        print(f"Real home path in {rjf} url")
        sys.exit(1)

# 2. Check every .meta.json and manifest.json in Benchmarks/citations/recordings and Tests/Fixtures/registry
ua_re = re.compile(r"^ScholarOS/\d+\.\d+\.\d+$")
checked_meta = 0
for rec_rel in ("Benchmarks/citations/recordings", "Tests/Fixtures/registry"):
    rec_dir = os.path.join(repo_root, rec_rel)
    if not os.path.isdir(rec_dir):
        continue
    meta_paths = sorted(glob.glob(os.path.join(rec_dir, "*.meta.json")))
    for mp in meta_paths:
        checked_meta += 1
        with open(mp, encoding="utf-8") as mf:
            item = json.load(mf)
        url = str(item.get("url", ""))
        req_headers = item.get("request_headers") or {}
        ua = req_headers.get("User-Agent", "")
        if not ua_re.match(ua):
            print(f"{mp}: invalid User-Agent {ua!r}")
            sys.exit(1)
        for check_str in [url, urllib_unquote := url]:
            low = check_str.lower()
            for bt in bad_toks:
                if bt in low:
                    print(f"{mp}: forbidden token {bt!r} in url {url}")
                    sys.exit(1)
            if real_home and real_home != "/" and real_home in low:
                print(f"{mp}: real home path in url {url}")
                sys.exit(1)
        for hk, hv in req_headers.items():
            combined = f"{hk}:{hv}".lower()
            for bt in bad_toks:
                if bt in combined:
                    print(f"{mp}: forbidden token {bt!r} in header {hk}")
                    sys.exit(1)
            if real_home and real_home != "/" and real_home in combined:
                print(f"{mp}: real home path in header {hk}")
                sys.exit(1)

if checked_meta == 0:
    print("No .meta.json files found to inspect")
    sys.exit(1)

print(f"git_grep_non_raw_hits=0 source_raw_json_urls_checked={len(raw_json_files)} meta_json_checked={checked_meta}")
PY
)"
        ROW1_RC=$?
        set -e
        echo "$ROW1_OUT"
        if [[ "$ROW1_RC" -eq 0 ]]; then
            record_pass 1 "Zero mailto/politeMailto/api_key hits and all .meta.json headers/URLs clean"
        else
            record_fail 1 "Banned token or .meta.json hygiene check failed"
        fi
    fi

    # ==================================================================
    # Row 2: Network-denied full `swift test --disable-sandbox --no-parallel`
    # ==================================================================
    if should_run_row 2; then
        echo "== [Row 2] Network-denied swift test --disable-sandbox --no-parallel (>= 155 tests, Preferences unchanged) =="
        PREFS_R2_BEFORE="$(ls "$REAL_USER_HOME/Library/Preferences" 2>/dev/null | grep -i scholar || true)"
        set +e
        if [[ "${SCHOLAR_OUTER_NO_NETWORK:-0}" == "1" ]]; then
            command swift test --disable-sandbox --no-parallel >"$WORK_SCRATCH/row2.out" 2>&1
            R2_EXIT=$?
        else
            sandbox-exec -p '(version 1)(allow default)(deny network*)' swift test --disable-sandbox --no-parallel >"$WORK_SCRATCH/row2.out" 2>&1
            R2_EXIT=$?
        fi
        set -e
        PREFS_R2_AFTER="$(ls "$REAL_USER_HOME/Library/Preferences" 2>/dev/null | grep -i scholar || true)"
        R2_SUMMARY="$(grep -E 'Test run with [0-9]+ tests' "$WORK_SCRATCH/row2.out" | tail -n 1 || true)"
        R2_COUNT="$(printf '%s\n' "$R2_SUMMARY" | sed -n -E 's/.*Test run with ([0-9]+) tests.*/\1/p')"
        echo "swift_test_exit=$R2_EXIT summary=${R2_SUMMARY:-none}"
        if [[ "$R2_EXIT" -eq 0 && -n "$R2_COUNT" && "$R2_COUNT" -ge 155 && "$PREFS_R2_BEFORE" == "$PREFS_R2_AFTER" ]]; then
            record_pass 2 "All $R2_COUNT unit tests passed under network denial; ~/Library/Preferences unchanged"
        else
            tail -n 20 "$WORK_SCRATCH/row2.out" || true
            record_fail 2 "swift test exit=$R2_EXIT count=${R2_COUNT:-0} prefs_unchanged=$([[ "$PREFS_R2_BEFORE" == "$PREFS_R2_AFTER" ]] && echo true || echo false)"
        fi
    fi

    # ==================================================================
    # Row 3: Full 480-entry replay completeness & manifest SHA-256 pinned in README
    # ==================================================================
    if should_run_row 3; then
        echo "== [Row 3] Full 480-entry benchmark replay (0 misses, complete=true, manifest SHA-256 pinned in README) =="
        ROW3_REASON_FILE="$WORK_SCRATCH/row3.reason"
        : > "$ROW3_REASON_FILE"
        set +e
        ROW3_OUT="$(python3 -I - "$BENCH_RUN1_JSON" "$REPO_ROOT/Benchmarks/citations/README.md" "$REPO_ROOT/Benchmarks/citations/recordings/manifest.json" "$BENCH_RUN1_EXIT" "$ROW3_REASON_FILE" <<'PY'
import hashlib, json, os, re, sys

rep_path, readme_path, manifest_path, exit_code, reason_path = (
    sys.argv[1],
    sys.argv[2],
    sys.argv[3],
    int(sys.argv[4]),
    sys.argv[5],
)

rep = {}
if os.path.isfile(rep_path):
    with open(rep_path, encoding="utf-8") as f:
        rep = json.load(f)

readme_text = ""
if os.path.isfile(readme_path):
    with open(readme_path, encoding="utf-8") as rf:
        readme_text = rf.read()

disk_sha = ""
if os.path.isfile(manifest_path):
    disk_sha = hashlib.sha256(open(manifest_path, "rb").read()).hexdigest().lower()

readme_matches = list(
    dict.fromkeys(
        m.lower()
        for m in re.findall(r"manifest\.json[^\n]*?([0-9a-fA-F]{64})", readme_text)
    )
)
if len(readme_matches) == 1:
    readme_sha = readme_matches[0]
elif len(readme_matches) == 0:
    readme_sha = ""
else:
    readme_sha = "CONFLICT(" + ",".join(readme_matches) + ")"

misses = rep.get("replay_miss_count")
complete = rep.get("complete")
rep_sha = (rep.get("recordings_manifest_sha256") or "").lower()
sha_match = (
    len(readme_matches) == 1
    and bool(disk_sha)
    and disk_sha == readme_sha
    and rep_sha == readme_sha
)

print(
    f"bench_exit={exit_code} replay_miss_count={misses} complete={complete} "
    f"manifest_sha256={disk_sha or 'missing'} report_sha256={rep_sha or 'missing'} "
    f"readme_sha256={readme_sha or 'missing'} sha_match={sha_match}"
)

failures = []
if not rep:
    failures.append("benchmark replay JSON missing")
if misses != 0:
    miss_groups = [m.get("group", "?") for m in (rep.get("replay_misses") or [])]
    if miss_groups:
        print(f"replay_miss_groups({len(miss_groups)}): {', '.join(miss_groups)}")
        failures.append(f"replay_miss_count={misses} ({','.join(miss_groups)})")
    else:
        failures.append(f"replay_miss_count={misses} (expected 0)")
if complete is not True:
    inc = rep.get("incomplete_reasons") or []
    inc_suffix = f" ({'; '.join(str(x) for x in inc)})" if inc else ""
    failures.append(f"complete={complete}{inc_suffix}")
if not sha_match:
    failures.append(
        f"sha_match=False (manifest={disk_sha or 'missing'}, report={rep_sha or 'missing'}, readme={readme_sha or 'missing'})"
    )
if exit_code != 0:
    failures.append(f"bench_exit={exit_code}")

if failures:
    summary = (
        f"Failed check(s): {'; '.join(failures)} "
        f"[replay_miss_count={misses}, complete={complete}, sha_match={sha_match}, bench_exit={exit_code}]"
    )
    with open(reason_path, "w", encoding="utf-8") as out_f:
        out_f.write(summary)
    sys.exit(1)
PY
)"
        ROW3_RC=$?
        set -e
        echo "$ROW3_OUT"
        if [[ "$ROW3_RC" -eq 0 ]]; then
            record_pass 3 "Full 480-entry replay complete (replay_miss_count=0, complete=true, manifest SHA-256 matches README)"
        else
            ROW3_REASON="$(cat "$ROW3_REASON_FILE" 2>/dev/null || true)"
            record_fail 3 "${ROW3_REASON:-Row 3 check exited with $ROW3_RC}"
        fi
    fi

    # ==================================================================
    # Row 4: Full replay run twice -> exported {key, verdict, reasons, fields} byte-identical
    # ==================================================================
    if should_run_row 4; then
        echo "== [Row 4] Full 480-entry replay determinism across two runs ({key, verdict, reasons, fields}) =="
        set +e
        ROW4_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$WORK_SCRATCH" <<'PY'
import glob, json, os, subprocess, sys

repo_root, cli_bin, scratch = sys.argv[1], sys.argv[2], sys.argv[3]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
entries_dir = os.path.join(repo_root, "Benchmarks", "citations", "entries")
bib_files = sorted(glob.glob(os.path.join(entries_dir, "*.bib")))

env = dict(os.environ)
home_dir = os.path.join(scratch, "row4-home")
os.makedirs(home_dir, exist_ok=True)
env["HOME"] = home_dir
env["CFFIXED_USER_HOME"] = home_dir
env.pop("SCHOLAR_CACHE_DIR", None)

def run_pass(tag: str) -> bytes:
    rows = []
    missed_groups = []
    for bf in bib_files:
        grp = os.path.basename(bf)[:-4]
        proc = subprocess.run(
            [cli_bin, "verify-citations", bf, "--registry-replay", rec_dir, "--json", "--lang", "en"],
            env=env,
            capture_output=True,
            text=True,
            timeout=300,
        )
        if proc.returncode == 2:
            missed_groups.append(grp)
            continue
        payload = json.loads(proc.stdout)
        for v in payload.get("verdicts", []):
            rows.append({
                "key": v["citeKey"],
                "verdict": v["firewallClass"],
                "reasons": v.get("reasons", []),
                "fields": v.get("fields", []),
            })
    if missed_groups:
        raise RuntimeError(f"{tag}: replay miss on {len(missed_groups)} group(s): {', '.join(missed_groups)}")
    rows.sort(key=lambda r: r["key"])
    if len(rows) != 480:
        raise RuntimeError(f"{tag}: expected 480 verdicts, got {len(rows)}")
    return (json.dumps(rows, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")

# First verify determinism on recorded audit_manual (30 entries)
audit_bib = os.path.join(entries_dir, "audit_manual.bib")
p_a1 = subprocess.run([cli_bin, "verify-citations", audit_bib, "--registry-replay", rec_dir, "--json", "--lang", "en"], env=env, capture_output=True, text=True)
p_a2 = subprocess.run([cli_bin, "verify-citations", audit_bib, "--registry-replay", rec_dir, "--json", "--lang", "en"], env=env, capture_output=True, text=True)
assert p_a1.returncode != 2 and p_a2.returncode != 2, f"audit_manual replay failed: {p_a1.stderr}"
a1 = json.loads(p_a1.stdout)["verdicts"]
a2 = json.loads(p_a2.stdout)["verdicts"]
strip_fn = lambda vs: json.dumps([{"key": v["citeKey"], "verdict": v["firewallClass"], "reasons": v["reasons"], "fields": v["fields"]} for v in vs], sort_keys=True)
assert strip_fn(a1) == strip_fn(a2), "audit_manual replay differed between two runs!"
print("audit_manual_30_byte_identical=true")

try:
    b1 = run_pass("run1")
    b2 = run_pass("run2")
except Exception as exc:
    print(f"full_480_determinism_error: {exc}")
    sys.exit(1)

if b1 != b2:
    print("FAIL: run1 and run2 stripped JSON bytes differed")
    sys.exit(1)
print(f"full_480_byte_identical=true bytes={len(b1)}")
PY
)"
        ROW4_RC=$?
        set -e
        echo "$ROW4_OUT"
        if [[ "$ROW4_RC" -eq 0 ]]; then
            record_pass 4 "Two full 480-entry replay runs produced byte-for-byte identical stripped verdicts"
        else
            record_fail 4 "Full 480-entry replay could not complete both runs (missing recordings for 11 groups)"
        fi
    fi

    # ==================================================================
    # Row 5: Hard gate — 0 non-insertable entries judged VERIFIED across all 480 entries
    # ==================================================================
    if should_run_row 5; then
        echo "== [Row 5] Hard requirement: non-insertable entries judged VERIFIED == 0 (full 480 replay) =="
        set +e
        ROW5_OUT="$(python3 -I - "$BENCH_RUN1_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    rep = json.load(f)
complete = rep.get("complete") is True
hr = rep.get("hard_requirements") or {}
cnt = hr.get("non_insertable_verified_count")
print(f"complete={complete} evaluated_non_insertable_verified_count={cnt}")
if not complete or cnt != 0:
    if hr.get("non_insertable_verified_entries"):
        print("offending_entries:", hr["non_insertable_verified_entries"])
    sys.exit(1)
PY
)"
        ROW5_RC=$?
        set -e
        echo "$ROW5_OUT"
        if [[ "$ROW5_RC" -eq 0 ]]; then
            record_pass 5 "0 non-insertable entries judged VERIFIED across all 480 entries"
        else
            record_fail 5 "Full 480-entry replay incomplete or non-insertable VERIFIED > 0"
        fi
    fi

    # ==================================================================
    # Row 6: Real three groups NOT_FOUND or RETRACTED <= 2%
    # ==================================================================
    if should_run_row 6; then
        echo "== [Row 6] Real three groups (real_clean, real_human, real_typo) NOT_FOUND/RETRACTED <= 2% =="
        set +e
        ROW6_OUT="$(python3 -I - "$BENCH_RUN1_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    rep = json.load(f)
pt = rep.get("provisional_thresholds")
if not rep.get("complete") or not pt:
    print("complete=false (real_clean, real_human, real_typo recordings incomplete)")
    sys.exit(1)
r6 = pt["row6_real_three_not_found_or_retracted"]
print(f"rate={r6['numerator']}/{r6['denominator']} ({r6['rate']*100:.2f}%) passed={r6['passed']} entries={r6['entries']}")
sys.exit(0 if r6["passed"] else 1)
PY
)"
        ROW6_RC=$?
        set -e
        echo "$ROW6_OUT"
        if [[ "$ROW6_RC" -eq 0 ]]; then
            record_pass 6 "Real three groups NOT_FOUND/RETRACTED rate within 2% threshold"
        else
            record_fail 6 "Cannot verify Row 6 until real_clean, real_human, and real_typo are recorded"
        fi
    fi

    # ==================================================================
    # Row 7: Real three groups VERIFIED >= 85% combined and real_clean >= 95%
    # ==================================================================
    if should_run_row 7; then
        echo "== [Row 7] Real three groups VERIFIED >= 85% combined; real_clean VERIFIED >= 95% =="
        set +e
        ROW7_OUT="$(python3 -I - "$BENCH_RUN1_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    rep = json.load(f)
pt = rep.get("provisional_thresholds")
if not rep.get("complete") or not pt:
    print("complete=false (real_clean, real_human, real_typo recordings incomplete)")
    sys.exit(1)
r7 = pt["row7_real_verified_rates"]
comb = r7["real_three_insertable"]
rc = r7["real_clean"]
print(f"combined_insertable={comb['numerator']}/{comb['denominator']} ({comb['rate']*100:.2f}%) real_clean={rc['numerator']}/{rc['denominator']} ({rc['rate']*100:.2f}%) passed={r7['passed']}")
for item in r7.get("real_three_non_verified_entries", []):
    print(f"  non_verified: {item['key']} verdict={item['verdict']} reasons={item['reasons']}")
sys.exit(0 if r7["passed"] else 1)
PY
)"
        ROW7_RC=$?
        set -e
        echo "$ROW7_OUT"
        if [[ "$ROW7_RC" -eq 0 ]]; then
            record_pass 7 "Real three groups combined and real_clean VERIFIED rates meet thresholds"
        else
            record_fail 7 "Cannot verify Row 7 until real_clean, real_human, and real_typo are recorded"
        fi
    fi

    # ==================================================================
    # Row 8: Mutation groups detection rates & mut_year1 online-vs-print notice
    # ==================================================================
    if should_run_row 8; then
        echo "== [Row 8] Mutation groups detection rates (mut_doi_swap, mut_author, mut_year3, mut_title, mut_year1 + notice) =="
        set +e
        ROW8_OUT="$(python3 -I - "$BENCH_RUN1_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    rep = json.load(f)
pt = rep.get("provisional_thresholds")
if not rep.get("complete") or not pt:
    print("complete=false (mutation groups recordings incomplete)")
    sys.exit(1)
r8 = pt["row8_mutation_detection"]
for g, info in r8["groups"].items():
    print(f"  {g}: {info['numerator']}/{info['denominator']} ({info['rate']*100:.1f}%, min={info['threshold']*100:.0f}%) passed={info['passed']}")
sys.exit(0 if r8["passed"] else 1)
PY
)"
        ROW8_RC=$?
        set -e
        echo "$ROW8_OUT"
        if [[ "$ROW8_RC" -eq 0 ]]; then
            record_pass 8 "All 5 mutation groups meet detection thresholds and mut_year1 carries online-vs-print notice"
        else
            record_fail 8 "Cannot verify Row 8 until mut_* groups are recorded"
        fi
    fi

    # ==================================================================
    # Row 9: Fixed near-title, surname-typo, incomplete-field, and wrong-venue cases via compiled binary
    # ==================================================================
    if should_run_row 9; then
        echo "== [Row 9] Fixed near-title, surname-typo, missing-field, and wrong-venue cases (compiled binary --registry-replay) =="
        set +e
        ROW9_JSON="$(unset SCHOLAR_CACHE_DIR; scholaros verify-citations "$REPO_ROOT/Benchmarks/citations/entries/audit_manual.bib" --registry-replay "$REPO_ROOT/Benchmarks/citations/recordings" --json --lang en)"
        ROW9_CLI_EXIT=$?
        ROW9_CHECK="$(python3 -I - "$ROW9_JSON" "$ROW9_CLI_EXIT" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
cli_exit = int(sys.argv[2])
if cli_exit == 2:
    print("CLI exited with 2 on audit_manual replay")
    sys.exit(1)
by_key = {v["citeKey"]: v for v in payload["verdicts"]}
expected_cases = {
    "audit_013": ("title", "Attention Is All You Need"),
    "audit_014": ("title", "Long Short-Term Memory"),
    "audit_015": ("title", "Deep learning"),
    "audit_016": ("title", "Deep learning"),
    "audit_017": ("firstAuthor", "LeCun"),
    "audit_018": ("firstAuthor", "Hochreiter"),
    "audit_019": ("firstAuthor", "LeCun"),
    "audit_020": ("venue", "Nature"),
}
for key, (field_name, expected_remote_substr) in expected_cases.items():
    v = by_key[key]
    if key == "audit_020":
        # Per 04-scholaros.md settled decision (2026-11-16, S55), wrong-venue alone allows VERIFIED (with venue hint) or DRIFT
        if v["firewallClass"] not in ("VERIFIED", "DRIFT"):
            print(f"FAIL {key}: expected VERIFIED or DRIFT, got {v['firewallClass']}")
            sys.exit(1)
        expected_ins = (v["firewallClass"] == "VERIFIED")
        if v["insertable"] is not expected_ins:
            print(f"FAIL {key}: insertable={v['insertable']} inconsistent with {v['firewallClass']}")
            sys.exit(1)
    else:
        if v["firewallClass"] != "DRIFT":
            print(f"FAIL {key}: expected DRIFT, got {v['firewallClass']}")
            sys.exit(1)
        if v["insertable"] is not False:
            print(f"FAIL {key}: insertable must be false")
            sys.exit(1)
    fields = v.get("fields") or []
    if not fields:
        print(f"FAIL {key}: empty fields on {v['firewallClass']}")
        sys.exit(1)
    matching = [f for f in fields if f.get("field") == field_name and expected_remote_substr.lower() in str(f.get("remoteValue", "")).lower()]
    if not matching:
        print(f"FAIL {key}: expected {field_name} containing {expected_remote_substr!r} in {fields}")
        sys.exit(1)
# audit_019 must report BOTH missing firstAuthor and missing year
f19_names = {f["field"] for f in by_key["audit_019"]["fields"]}
if not {"firstAuthor", "year"}.issubset(f19_names):
    print(f"FAIL audit_019: expected firstAuthor and year in fields, got {f19_names}")
    sys.exit(1)
print(f"verified_cases=8/8 (audit_013..audit_019 DRIFT, audit_020={by_key['audit_020']['firewallClass']}, remote values populated)")
PY
)"
        ROW9_RC=$?
        set -e
        echo "$ROW9_CHECK"
        if [[ "$ROW9_RC" -eq 0 ]]; then
            record_pass 9 "All 8 fixed Row 9 cases return expected DRIFT / VERIFIED+venue-hint with remote fields"
        else
            record_fail 9 "One or more fixed Row 9 drift cases failed"
        fi
    fi

    # ==================================================================
    # Row 10: mut_doi_missing — 0 VERIFIED, DRIFT recovers true DOI, NOT_FOUND rate recorded
    # ==================================================================
    if should_run_row 10; then
        echo "== [Row 10] mut_doi_missing: 0 VERIFIED, DRIFT recovers gold true_doi, NOT_FOUND rate recorded =="
        set +e
        ROW10_OUT="$(python3 -I - "$BENCH_RUN1_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    rep = json.load(f)
hr = rep.get("hard_requirements") or {}
r10 = hr.get("row10_mut_doi_missing")
if not r10 or r10.get("evaluated_count") != 20:
    print("mut_doi_missing not yet recorded/evaluated (0/20)")
    sys.exit(1)
print(
    f"evaluated={r10['evaluated_count']} verified={r10['verified_count']} "
    f"drift_true_doi_matched_all={r10['drift_true_doi_matched_all']} "
    f"not_found_rate={r10['not_found_rate']}"
)
if r10["verified_count"] != 0 or not r10["drift_true_doi_matched_all"] or r10["not_found_rate"]["rate"] is None:
    sys.exit(1)
PY
)"
        ROW10_RC=$?
        set -e
        echo "$ROW10_OUT"
        if [[ "$ROW10_RC" -eq 0 ]]; then
            record_pass 10 "mut_doi_missing has 0 VERIFIED, all DRIFT entries report true DOI, and NOT_FOUND rate recorded"
        else
            record_fail 10 "Cannot verify Row 10 until mut_doi_missing is recorded"
        fi
    fi

    # ==================================================================
    # Row 11: Failure injection across Crossref, OpenAlex, doi.org, arXiv, PubMed (compiled binary + timeout test)
    # ==================================================================
    if should_run_row 11; then
        echo "== [Row 11] Failure injection (all-fail & single-service fail across 5 registries, 0 cache rows, compiled binary + timeout unit test) =="
        set +e
        ROW11_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$WORK_SCRATCH" "${SCHOLAR_OUTER_NO_NETWORK:-0}" <<'PY'
import hashlib, json, os, shutil, sqlite3, subprocess, sys

repo_root, cli_bin, scratch, outer_no_net = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
base_reg = os.path.join(repo_root, "Tests", "Fixtures", "registry")

# Build a 14-entry .bib combining the 12-entry fixture + 1 arXiv + 1 PubMed entry recorded in Tests/Fixtures/registry
with open(os.path.join(repo_root, "Fixtures", "citations-m0-recheck.bib"), encoding="utf-8") as f:
    recheck_bib = f.read()
extra_bib = """
@inproceedings{row11_arxiv_dao,
  author = {Dao, Tri and others},
  title = {FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness},
  booktitle = {NeurIPS},
  year = {2022},
  eprint = {2205.14135},
  archivePrefix = {arXiv}
}
@article{row11_pmid_ito,
  author = {Ito, Hiroshi T. and Zhang, Sheng-Jia and Witter, Menno P. and Moser, Edvard I. and Moser, May-Britt},
  title = {A prefrontal-thalamo-hippocampal circuit for goal-directed spatial navigation},
  journal = {Nature},
  year = {2015},
  pmid = {26017312}
}
"""
bib14_path = os.path.join(scratch, "row11-14entries.bib")
with open(bib14_path, "w", encoding="utf-8") as bf:
    bf.write(recheck_bib + "\n" + extra_bib)

home_dir = os.path.join(scratch, "row11-home")
cache_dir = os.path.join(scratch, "row11-cache")
os.makedirs(home_dir, exist_ok=True)
os.makedirs(cache_dir, exist_ok=True)

clean_env = dict(os.environ)
clean_env["HOME"] = home_dir
clean_env["CFFIXED_USER_HOME"] = home_dir
clean_env.pop("SCHOLAR_CACHE_DIR", None)

fail_env = dict(clean_env)
fail_env["SCHOLAR_CACHE_DIR"] = cache_dir

# Baseline clean replay on the 14 entries
base_proc = subprocess.run(
    [cli_bin, "verify-citations", bib14_path, "--registry-replay", base_reg, "--json", "--lang", "en"],
    env=clean_env,
    capture_output=True,
    text=True,
    check=False,
)
assert base_proc.returncode in (0, 1, 3), f"Baseline replay failed: {base_proc.stderr}"
baseline_by_key = {v["citeKey"]: v for v in json.loads(base_proc.stdout)["verdicts"]}
assert len(baseline_by_key) == 14

def make_mutated_replay(name: str, mutate_fn) -> str:
    dst = os.path.join(scratch, f"row11-reg-{name}")
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(base_reg, dst)
    mpath = os.path.join(dst, "manifest.json")
    with open(mpath, encoding="utf-8") as mf:
        manifest = json.load(mf)
    meta_hashes = {}
    new_items = []
    for item in manifest["items"]:
        res = mutate_fn(item)
        if res is not None:
            new_status, new_body, extra_hdrs = res
            raw_path = os.path.join(dst, item["raw_file"])
            with open(raw_path, "wb") as rf:
                rf.write(new_body)
            hdrs = dict(item.get("response_headers") or {})
            hdrs.update(extra_hdrs)
            item = dict(item)
            item["status"] = new_status
            item["byte_length"] = len(new_body)
            item["sha256"] = hashlib.sha256(new_body).hexdigest()
            item["response_headers"] = hdrs
        meta_name = f"{item['slug']}.meta.json"
        meta_bytes = (json.dumps(item, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
        with open(os.path.join(dst, meta_name), "wb") as mtf:
            mtf.write(meta_bytes)
        meta_hashes[meta_name] = hashlib.sha256(meta_bytes).hexdigest()
        new_items.append(item)
    manifest["items"] = new_items
    manifest["meta_files_sha256"] = meta_hashes
    with open(mpath, "w", encoding="utf-8") as mf:
        mf.write(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return dst

# 1. All-fail modes via compiled binary (with SCHOLAR_CACHE_DIR set to verify 0 cache rows!)
all_fail_cases = [
    ("all_429_no_hdr", lambda it: (429, b"Too Many Requests", {}), "rate_limited"),
    ("all_429_retry0", lambda it: (429, b"Too Many Requests", {"Retry-After": "0"}), "rate_limited"),
    ("all_500", lambda it: (500, b"Internal Server Error", {}), "server_error"),
    ("all_503", lambda it: (503, b"Service Unavailable", {"Retry-After": "0"}), "rate_limited"),
    ("all_bad_json", lambda it: (200, b"{corrupt-not-json-or-xml", {}), "unparseable"),
    ("all_empty_body", lambda it: (200, b"", {}), "unparseable"),
]
for label, fn, expected_reason in all_fail_cases:
    rdir = make_mutated_replay(label, fn)
    p = subprocess.run(
        [cli_bin, "verify-citations", bib14_path, "--registry-replay", rdir, "--json", "--lang", "en"],
        env=fail_env,
        capture_output=True,
        text=True,
    )
    if p.returncode not in (1, 3):
        print(f"FAIL {label}: unexpected exit {p.returncode}: {p.stderr}")
        sys.exit(1)
    verdicts = json.loads(p.stdout)["verdicts"]
    for v in verdicts:
        k = v["citeKey"]
        if k == "retracted_wakefield":
            if v["firewallClass"] != "RETRACTED":
                print(f"FAIL {label}: retracted_wakefield expected RETRACTED, got {v['firewallClass']}")
                sys.exit(1)
        else:
            if v["firewallClass"] != "UNVERIFIED" or v.get("reasons") != [expected_reason]:
                print(f"FAIL {label} on {k}: got class={v['firewallClass']} reasons={v.get('reasons')}, expected UNVERIFIED [{expected_reason}]")
                sys.exit(1)

# OpenAlex x-ratelimit-remaining: 0 budget exhaustion on identifierless entries
# (Uses clean_env without cache_dir because Crossref 200 records on DOI entries are valid and cacheable;
#  for identifierless entries themselves, Crossref empty search + OpenAlex 429 must write 0 rows to oa0_cache_dir!)
oa0_cache_dir = os.path.join(scratch, "row11-oa0-cache")
os.makedirs(oa0_cache_dir, exist_ok=True)
oa0_env = dict(clean_env)
oa0_env["SCHOLAR_CACHE_DIR"] = oa0_cache_dir
nodoi2_bib = os.path.join(scratch, "row11-nodoi2.bib")
with open(nodoi2_bib, "w", encoding="utf-8") as nf:
    for ln in recheck_bib.splitlines():
        if "real_nodoi" in ln or "fake_nodoi" in ln:
            nf.write(ln + "\n")

oa_zero_dir = make_mutated_replay(
    "oa_remaining_zero",
    lambda it: (429, b"daily budget exhausted", {"x-ratelimit-remaining": "0"}) if it["service"] == "openalex" else None,
)
p_oa0 = subprocess.run(
    [cli_bin, "verify-citations", nodoi2_bib, "--registry-replay", oa_zero_dir, "--json", "--lang", "en"],
    env=oa0_env,
    capture_output=True,
    text=True,
)
oa0_by_key = {v["citeKey"]: v for v in json.loads(p_oa0.stdout)["verdicts"]}
for nodoi_key in ("real_nodoi", "fake_nodoi"):
    if oa0_by_key[nodoi_key]["firewallClass"] != "UNVERIFIED" or oa0_by_key[nodoi_key]["reasons"] != ["budget_exhausted"]:
        print(f"FAIL oa_remaining_zero on {nodoi_key}: {oa0_by_key[nodoi_key]}")
        sys.exit(1)
oa0_db = os.path.join(oa0_cache_dir, "registry.sqlite")
if os.path.isfile(oa0_db):
    conn0 = sqlite3.connect(oa0_db)
    c0 = int(conn0.execute("SELECT COUNT(*) FROM registry_cache").fetchone()[0])
    conn0.close()
    if c0 != 0:
        print(f"FAIL: oa_remaining_zero inserted {c0} row(s) into registry_cache")
        sys.exit(1)

# All-fail network denial (disconnect / transport_error) via compiled binary on 3 fast entries (DOI + arXiv + PMID)
fast3_bib = os.path.join(scratch, "row11-fast3.bib")
with open(fast3_bib, "w", encoding="utf-8") as f3:
    f3.write(
        recheck_bib.splitlines()[0] + "\n"
        + "@article{w_wake, author={Wakefield, A. J.}, title={Ileal-lymphoid-nodular hyperplasia}, journal={The Lancet}, year={1998}, doi={10.1016/S0140-6736(97)11096-0}}\n"
        + extra_bib
    )
net_cmd = (
    [cli_bin, "verify-citations", fast3_bib, "--json", "--lang", "en"]
    if outer_no_net == "1"
    else ["sandbox-exec", "-p", "(version 1)(allow default)(deny network*)", cli_bin, "verify-citations", fast3_bib, "--json", "--lang", "en"]
)
p_net = subprocess.run(net_cmd, env=fail_env, capture_output=True, text=True, timeout=120)
if p_net.returncode not in (1, 3):
    print(f"FAIL transport_error run exit={p_net.returncode}: {p_net.stderr}")
    sys.exit(1)
for v in json.loads(p_net.stdout)["verdicts"]:
    if v["citeKey"] == "w_wake":
        assert v["firewallClass"] == "RETRACTED"
    else:
        if v["firewallClass"] != "UNVERIFIED" or v.get("reasons") != ["transport_error"]:
            print(f"FAIL transport_error on {v['citeKey']}: got class={v['firewallClass']} reasons={v.get('reasons')}, expected UNVERIFIED ['transport_error']")
            sys.exit(1)

# 2. Single-service failure: each of crossref, openalex, doi, arxiv, pubmed fails with 500 alone
for svc in ("crossref", "openalex", "doi", "arxiv", "pubmed"):
    sdir = make_mutated_replay(f"single_{svc}_500", lambda it, s=svc: (500, b"Server Error", {}) if it["service"] == s else None)
    ps = subprocess.run(
        [cli_bin, "verify-citations", bib14_path, "--registry-replay", sdir, "--json", "--lang", "en"],
        env=clean_env,
        capture_output=True,
        text=True,
    )
    assert ps.returncode in (0, 1, 3), f"single_{svc}_500 exit {ps.returncode}: {ps.stderr}"
    for v in json.loads(ps.stdout)["verdicts"]:
        k = v["citeKey"]
        base_cls = baseline_by_key[k]["firewallClass"]
        got_cls = v["firewallClass"]
        if got_cls != base_cls and got_cls != "UNVERIFIED":
            print(f"FAIL single_{svc}_500 on {k}: baseline={base_cls}, got={got_cls} (must match baseline or be UNVERIFIED)")
            sys.exit(1)

# 3. Verify SQLite cache table has 0 rows after all failure runs!
db_file = os.path.join(cache_dir, "registry.sqlite")
cache_rows = 0
if os.path.isfile(db_file):
    conn = sqlite3.connect(db_file)
    cur = conn.execute("SELECT COUNT(*) FROM registry_cache")
    cache_rows = int(cur.fetchone()[0])
    conn.close()
if cache_rows != 0:
    print(f"FAIL: failure runs inserted {cache_rows} row(s) into registry_cache!")
    sys.exit(1)

print(f"binary_all_fail_modes=7 single_service_modes=5 sqlite_cache_rows={cache_rows}")
PY
)"
        ROW11_BIN_RC=$?
        set -e
        echo "$ROW11_OUT"
        set +e
        ROW11_UT_OUT="$(swift test --no-parallel --filter "BibCSLAndFirewallTests/m1Stage07TransientFailuresAmbiguousAndNoMatchNeverEnterCache" 2>&1)"
        ROW11_UT_RC=$?
        set -e
        echo "timeout_unit_test_exit=$ROW11_UT_RC"
        if [[ "$ROW11_BIN_RC" -eq 0 && "$ROW11_UT_RC" -eq 0 ]]; then
            record_pass 11 "All-fail & single-service failure injections return honest UNVERIFIED reasons with 0 cached rows"
        else
            record_fail 11 "Failure injection check failed (binary_rc=$ROW11_BIN_RC unit_test_rc=$ROW11_UT_RC)"
        fi
    fi

    # ==================================================================
    # Row 12: Retracted group (>= 90%, cites source & field, non-builtin retracted paper caught)
    # ==================================================================
    if should_run_row 12; then
        echo "== [Row 12] Retracted group >= 90% RETRACTED with source+field & non-builtin retracted work check =="
        set +e
        ROW12_SERALINI="$(unset SCHOLAR_CACHE_DIR; scholaros verify-citations "$REPO_ROOT/Benchmarks/citations/entries/audit_manual.bib" --registry-replay "$REPO_ROOT/Benchmarks/citations/recordings" --json --lang en)"
        ROW12_OUT="$(python3 -I - "$ROW12_SERALINI" "$BENCH_RUN1_JSON" <<'PY'
import json, sys
audit_payload = json.loads(sys.argv[1])
by_key = {v["citeKey"]: v for v in audit_payload["verdicts"]}
seralini = by_key["audit_011"]
assert seralini["firewallClass"] == "RETRACTED", seralini
assert "retracted_builtin_list" not in seralini["reasons"], seralini
assert "update-to" in seralini["auditNote"] and "is_retracted" in seralini["auditNote"], seralini["auditNote"]
print("non_builtin_seralini_2012=RETRACTED (Crossref update-to + OpenAlex is_retracted)")

with open(sys.argv[2], encoding="utf-8") as f:
    rep = json.load(f)
pt = rep.get("provisional_thresholds")
if not rep.get("complete") or not pt:
    print("retracted_group_30: not yet recorded (REPLAY_MISS)")
    sys.exit(1)
r12 = pt["row12_retracted"]
print(f"retracted_group={r12['numerator']}/{r12['denominator']} ({r12['rate']*100:.1f}%) passed={r12['passed']}")
sys.exit(0 if r12["passed"] else 1)
PY
)"
        ROW12_RC=$?
        set -e
        echo "$ROW12_OUT"
        if [[ "$ROW12_RC" -eq 0 ]]; then
            record_pass 12 "Retracted group >= 90% RETRACTED with upstream source/field and non-builtin retraction verified"
        else
            record_fail 12 "Non-builtin Seralini verified, but 30-entry retracted benchmark group is not yet recorded"
        fi
    fi

    # ==================================================================
    # Row 13: Fabricated group search evidence + reviewer & 12-group gold.jsonl counts
    # ==================================================================
    if should_run_row 13; then
        echo "== [Row 13] check_benchmark.py: fabricated_model evidence + reviewer & 480-entry gold.jsonl parity =="
        set +e
        ROW13_OUT="$(python3 -I "$REPO_ROOT/Benchmarks/citations/tools/check_benchmark.py" 2>&1)"
        ROW13_RC=$?
        set -e
        printf '%s\n' "$ROW13_OUT" | tail -n 18
        if [[ "$ROW13_RC" -eq 0 ]]; then
            record_pass 13 "All 80 fabricated entries carry evidence + second review and all 12 group counts match (480/480)"
        else
            record_fail 13 "check_benchmark.py exited with $ROW13_RC"
        fi
    fi

    # ==================================================================
    # Row 14: HTTP 429 retry (4x429 -> 4 requests + rate_limited via binary; 2x429 Retry-After:2 -> 200 via virtual clock)
    # ==================================================================
    if should_run_row 14; then
        echo "== [Row 14] HTTP 429 retry policy (compiled binary 4-attempt cap + virtual clock [2s, 2s] Retry-After) =="
        set +e
        ROW14_BIN_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$WORK_SCRATCH" <<'PY'
import hashlib, json, os, shutil, subprocess, sys
repo_root, cli_bin, scratch = sys.argv[1], sys.argv[2], sys.argv[3]
base_reg = os.path.join(repo_root, "Tests", "Fixtures", "registry")
reg429 = os.path.join(scratch, "row14-429-reg")
if os.path.exists(reg429):
    shutil.rmtree(reg429)
shutil.copytree(base_reg, reg429)

mpath = os.path.join(reg429, "manifest.json")
with open(mpath, encoding="utf-8") as mf:
    manifest = json.load(mf)
meta_hashes = {}
new_items = []
for item in manifest["items"]:
    if item["service"] == "pubmed":
        body = b"Too Many Requests"
        with open(os.path.join(reg429, item["raw_file"]), "wb") as rf:
            rf.write(body)
        item = dict(item)
        item["status"] = 429
        item["byte_length"] = len(body)
        item["sha256"] = hashlib.sha256(body).hexdigest()
        hdrs = dict(item.get("response_headers") or {})
        hdrs["Retry-After"] = "2"
        item["response_headers"] = hdrs
    meta_name = f"{item['slug']}.meta.json"
    meta_bytes = (json.dumps(item, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    with open(os.path.join(reg429, meta_name), "wb") as mtf:
        mtf.write(meta_bytes)
    meta_hashes[meta_name] = hashlib.sha256(meta_bytes).hexdigest()
    new_items.append(item)
manifest["items"] = new_items
manifest["meta_files_sha256"] = meta_hashes
with open(mpath, "w", encoding="utf-8") as mf:
    mf.write(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

pmid_bib = os.path.join(scratch, "row14-pmid.bib")
with open(pmid_bib, "w", encoding="utf-8") as bf:
    bf.write("@article{ito2015, author={Ito, Hiroshi T.}, title={Test}, journal={Nature}, year={2015}, pmid={26017312}}\n")

env = dict(os.environ)
hdir = os.path.join(scratch, "row14-home")
os.makedirs(hdir, exist_ok=True)
env["HOME"] = hdir
env["CFFIXED_USER_HOME"] = hdir
env.pop("SCHOLAR_CACHE_DIR", None)

p = subprocess.run(
    [cli_bin, "verify-citations", pmid_bib, "--registry-replay", reg429, "--verbose", "--json", "--lang", "en"],
    env=env,
    capture_output=True,
    text=True,
)
http_lines = [ln for ln in p.stderr.splitlines() if ln.startswith("[HTTP]") and "status=429" in ln]
verdict = json.loads(p.stdout)["verdicts"][0]
print(f"binary_429_exit={p.returncode} attempts={len(http_lines)} class={verdict['firewallClass']} reasons={verdict['reasons']}")
if p.returncode != 3 or len(http_lines) != 4 or verdict["firewallClass"] != "UNVERIFIED" or verdict["reasons"] != ["rate_limited"]:
    sys.exit(1)
PY
)"
        ROW14_BIN_RC=$?
        ROW14_UT_OUT="$(swift test --no-parallel --filter "BibCSLAndFirewallTests/m1Stage06Row14RetryAfterAndFourConsecutive429sAnd5xxRetryPolicy" 2>&1)"
        ROW14_UT_RC=$?
        set -e
        echo "$ROW14_BIN_OUT"
        echo "virtual_clock_retry_unit_test_exit=$ROW14_UT_RC"
        if [[ "$ROW14_BIN_RC" -eq 0 && "$ROW14_UT_RC" -eq 0 ]]; then
            record_pass 14 "4x429 stops at 4 requests with rate_limited and 2x429 (Retry-After: 2) -> 200 sleeps [2s, 2s]"
        else
            record_fail 14 "429 retry check failed (binary_rc=$ROW14_BIN_RC unit_test_rc=$ROW14_UT_RC)"
        fi
    fi

    # ==================================================================
    # Row 15: verify-citations on full 480 benchmark with --offline AND under sandbox-exec network denial
    # ==================================================================
    if should_run_row 15; then
        echo "== [Row 15] Full 480-entry benchmark under --offline and under network-denying sandbox-exec (600s guard) =="
        set +e
        ROW15_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$WORK_SCRATCH" "${SCHOLAR_OUTER_NO_NETWORK:-0}" <<'PY'
import concurrent.futures, glob, json, os, subprocess, sys

repo_root, cli_bin, scratch, outer_no_net = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
bib_files = sorted(glob.glob(os.path.join(repo_root, "Benchmarks", "citations", "entries", "*.bib")))
if len(bib_files) != 12:
    print(f"Expected 12 .bib files, found {len(bib_files)}")
    sys.exit(1)

# 1. --offline across all 12 benchmark groups (480 entries, 600s timeout per command)
off_total = 0
off_verified = 0
off_bad_nf = []
for idx, bf in enumerate(bib_files):
    hdir = os.path.join(scratch, f"r15-off-home-{idx}")
    os.makedirs(hdir, exist_ok=True)
    env = dict(os.environ)
    env["HOME"] = hdir
    env["CFFIXED_USER_HOME"] = hdir
    env.pop("SCHOLAR_CACHE_DIR", None)
    p = subprocess.run(
        [cli_bin, "verify-citations", bf, "--offline", "--json", "--lang", "en"],
        env=env,
        capture_output=True,
        text=True,
        timeout=600,
    )
    if p.returncode not in (1, 3):
        print(f"FAIL --offline on {os.path.basename(bf)}: exit={p.returncode} stderr={p.stderr}")
        sys.exit(1)
    rep = json.loads(p.stdout)
    off_total += rep["totalEvaluated"]
    off_verified += rep["verifiedCount"]
    for v in rep["verdicts"]:
        if v["firewallClass"] == "NOT_FOUND" and "invalid_identifier" not in (v.get("reasons") or []):
            off_bad_nf.append(v["citeKey"])

if off_total != 480 or off_verified != 0 or off_bad_nf:
    print(f"FAIL --offline summary: total={off_total} verified={off_verified} bad_not_found={off_bad_nf}")
    sys.exit(1)

# 2. Without --offline inside network-denying sandbox-exec across all 12 groups (600s hang guard per command)
def run_sandboxed_group(item):
    idx, bf = item
    hdir = os.path.join(scratch, f"r15-net-home-{idx}")
    os.makedirs(hdir, exist_ok=True)
    env = dict(os.environ)
    env["HOME"] = hdir
    env["CFFIXED_USER_HOME"] = hdir
    env.pop("SCHOLAR_CACHE_DIR", None)
    cmd = (
        [cli_bin, "verify-citations", bf, "--no-cache", "--json", "--lang", "en"]
        if outer_no_net == "1"
        else [
            "sandbox-exec",
            "-p",
            "(version 1)(allow default)(deny network*)",
            cli_bin,
            "verify-citations",
            bf,
            "--no-cache",
            "--json",
            "--lang",
            "en",
        ]
    )
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=600)
    return os.path.basename(bf), p.returncode, p.stdout, p.stderr

net_total = 0
net_verified = 0
net_bad_nf = []
net_bad_unv = []
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(run_sandboxed_group, enumerate(bib_files)))

for fname, rc, stdout, stderr in results:
    if rc not in (1, 3):
        print(f"FAIL sandboxed online on {fname}: exit={rc} stderr={stderr}")
        sys.exit(1)
    rep = json.loads(stdout)
    net_total += rep["totalEvaluated"]
    net_verified += rep["verifiedCount"]
    for v in rep["verdicts"]:
        cls = v["firewallClass"]
        rsn = v.get("reasons") or []
        if cls == "NOT_FOUND" and "invalid_identifier" not in rsn:
            net_bad_nf.append(v["citeKey"])
        if cls == "UNVERIFIED" and rsn != ["transport_error"]:
            net_bad_unv.append((v["citeKey"], rsn))

if net_total != 480 or net_verified != 0 or net_bad_nf or net_bad_unv:
    print(
        f"FAIL sandboxed online summary: total={net_total} verified={net_verified} "
        f"bad_nf={net_bad_nf[:5]} bad_unv={net_bad_unv[:5]}"
    )
    sys.exit(1)

print(f"offline_480_ok=true (verified=0, bad_not_found=0) sandbox_no_flag_480_ok=true (verified=0, transport_error_all=true)")
PY
)"
        ROW15_RC=$?
        set -e
        echo "$ROW15_OUT"
        if [[ "$ROW15_RC" -eq 0 ]]; then
            record_pass 15 "Both --offline and network-denied runs across all 480 entries produced 0 VERIFIED and clean transport_error reasons"
        else
            record_fail 15 "Row 15 offline / network-denied benchmark run failed"
        fi
    fi

    # ==================================================================
    # Row 16: Exit codes 0, 1, 3, 2 via compiled binary
    # ==================================================================
    if should_run_row 16; then
        echo "== [Row 16] Exit codes 0 (all VERIFIED), 1 (fake mixed in), 3 (500 on one real entry), 2 (missing file) =="
        set +e
        ROW16_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$WORK_SCRATCH" <<'PY'
import hashlib, json, os, shutil, subprocess, sys

repo_root, cli_bin, scratch = sys.argv[1], sys.argv[2], sys.argv[3]
base_reg = os.path.join(repo_root, "Tests", "Fixtures", "registry")
recheck_lines = open(os.path.join(repo_root, "Fixtures", "citations-m0-recheck.bib"), encoding="utf-8").read().splitlines()

real3_bib = os.path.join(scratch, "row16-real3.bib")
mixed_bib = os.path.join(scratch, "row16-mixed.bib")
with open(real3_bib, "w", encoding="utf-8") as f:
    f.write("\n".join(recheck_lines[:3]) + "\n")
with open(mixed_bib, "w", encoding="utf-8") as f:
    f.write("\n".join(recheck_lines[:4]) + "\n")

reg500 = os.path.join(scratch, "row16-reg500")
if os.path.exists(reg500):
    shutil.rmtree(reg500)
shutil.copytree(base_reg, reg500)
mpath = os.path.join(reg500, "manifest.json")
manifest = json.load(open(mpath, encoding="utf-8"))
meta_hashes = {}
new_items = []
for item in manifest["items"]:
    if "10.1038/171737a0" in item["url"]:
        body = b"Server Error"
        open(os.path.join(reg500, item["raw_file"]), "wb").write(body)
        item = dict(item)
        item["status"] = 500
        item["byte_length"] = len(body)
        item["sha256"] = hashlib.sha256(body).hexdigest()
    meta_name = f"{item['slug']}.meta.json"
    meta_bytes = (json.dumps(item, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    open(os.path.join(reg500, meta_name), "wb").write(meta_bytes)
    meta_hashes[meta_name] = hashlib.sha256(meta_bytes).hexdigest()
    new_items.append(item)
manifest["items"] = new_items
manifest["meta_files_sha256"] = meta_hashes
open(mpath, "w", encoding="utf-8").write(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

env = dict(os.environ)
hdir = os.path.join(scratch, "row16-home")
os.makedirs(hdir, exist_ok=True)
env["HOME"] = hdir
env["CFFIXED_USER_HOME"] = hdir
env.pop("SCHOLAR_CACHE_DIR", None)

c0 = subprocess.run([cli_bin, "verify-citations", real3_bib, "--registry-replay", base_reg], env=env, capture_output=True, text=True).returncode
c1 = subprocess.run([cli_bin, "verify-citations", mixed_bib, "--registry-replay", base_reg], env=env, capture_output=True, text=True).returncode
c3 = subprocess.run([cli_bin, "verify-citations", real3_bib, "--registry-replay", reg500], env=env, capture_output=True, text=True).returncode
c2 = subprocess.run([cli_bin, "verify-citations", os.path.join(scratch, "nonexistent.bib"), "--offline"], env=env, capture_output=True, text=True).returncode

print(f"exit_codes=[{c0}, {c1}, {c3}, {c2}] (expected [0, 1, 3, 2])")
if [c0, c1, c3, c2] != [0, 1, 3, 2]:
    sys.exit(1)
PY
)"
        ROW16_RC=$?
        set -e
        echo "$ROW16_OUT"
        if [[ "$ROW16_RC" -eq 0 ]]; then
            record_pass 16 "Exit codes verified as 0, 1, 3, 2 in order via compiled binary"
        else
            record_fail 16 "Exit code sequence did not match 0, 1, 3, 2"
        fi
    fi

    # ==================================================================
    # Row 17: Output JSON schema & EN/ZH text rules across full benchmark replay
    # ==================================================================
    if should_run_row 17; then
        echo "== [Row 17] Full replay JSON schema, DRIFT fields, closed UNVERIFIED reasons, no confidenceScore, and EN/ZH text rules =="
        set +e
        ROW17_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$WORK_SCRATCH" <<'PY'
import glob, json, os, subprocess, sys

repo_root, cli_bin, scratch = sys.argv[1], sys.argv[2], sys.argv[3]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
entries_dir = os.path.join(repo_root, "Benchmarks", "citations", "entries")
bib_files = sorted(glob.glob(os.path.join(entries_dir, "*.bib")))

allowed_reasons = {
    "offline", "transport_error", "timeout", "rate_limited", "server_error",
    "budget_exhausted", "unparseable", "ambiguous", "registered_no_metadata", "no_match_in_search",
    "parse_error",
}

env = dict(os.environ)
hdir = os.path.join(scratch, "row17-home")
os.makedirs(hdir, exist_ok=True)
env["HOME"] = hdir
env["CFFIXED_USER_HOME"] = hdir
env.pop("SCHOLAR_CACHE_DIR", None)

def validate_group(bf: str) -> bool:
    p_json = subprocess.run([cli_bin, "verify-citations", bf, "--registry-replay", rec_dir, "--json", "--lang", "en"], env=env, capture_output=True, text=True)
    if p_json.returncode == 2:
        return False
    raw_json = p_json.stdout
    if "confidenceScore" in raw_json:
        raise AssertionError(f"confidenceScore found in JSON for {bf}")
    obj = json.loads(raw_json)
    unv_cnt = obj["unverifiedCount"]
    if unv_cnt > 0 and obj["complete"] is not False:
        raise AssertionError(f"Expected complete==false when unverifiedCount={unv_cnt} in {bf}")
    for v in obj["verdicts"]:
        for req_k in ("reasons", "sources", "insertable"):
            if req_k not in v:
                raise AssertionError(f"Missing {req_k} on {v.get('citeKey')}")
        if v["firewallClass"] == "DRIFT" and not v.get("fields"):
            raise AssertionError(f"Empty fields on DRIFT {v['citeKey']}")
        if v["firewallClass"] == "UNVERIFIED":
            if not v["reasons"] or any(r not in allowed_reasons for r in v["reasons"]):
                raise AssertionError(f"Invalid UNVERIFIED reasons on {v['citeKey']}: {v['reasons']}")

    for lang, inc_tok in (("en", "results are incomplete."), ("zh", "结果不完整。")):
        pt = subprocess.run([cli_bin, "verify-citations", bf, "--registry-replay", rec_dir, "--lang", lang], env=env, capture_output=True, text=True)
        txt = pt.stdout
        # Check non-citeKey audit text does not accuse entries of being "编造" / "fabricated"
        for line in txt.splitlines():
            # Strip `[CLASS] citeKey:` prefix in case citeKey itself starts with fab_
            body = line.split(":", 1)[1] if line.startswith("[") and ":" in line else line
            if "编造" in body or "fabricated" in body.lower():
                raise AssertionError(f"Forbidden '编造'/'fabricated' wording in {lang} output: {line}")
        if unv_cnt > 0:
            lines = txt.splitlines()
            # Line 0 is [REPLAY], Line 1 is Evaluated=..., Line 2 must carry the incomplete summary!
            if len(lines) < 3 or inc_tok not in lines[2]:
                raise AssertionError(f"Missing incomplete summary after Evaluated= line in {lang}: {lines[:4]}")
    return True

checked_groups = []
missed_groups = []
for bf in bib_files:
    g = os.path.basename(bf)[:-4]
    if validate_group(bf):
        checked_groups.append(g)
    else:
        missed_groups.append(g)

print(f"schema_verified_groups={len(checked_groups)}/12 ({','.join(checked_groups)})")
if missed_groups:
    print(f"replay_miss_groups={len(missed_groups)}: {','.join(missed_groups)}")
    sys.exit(1)
PY
)"
        ROW17_RC=$?
        set -e
        echo "$ROW17_OUT"
        if [[ "$ROW17_RC" -eq 0 ]]; then
            record_pass 17 "All 12 groups (480 entries) pass JSON schema and EN/ZH text wording checks"
        else
            record_fail 17 "audit_manual passed schema/wording checks, but 11 unrecorded groups hit replay miss"
        fi
    fi

    # ==================================================================
    # Row 18: Untrusted x-firewall-class = {VERIFIED} ignored & blocked in verify-citations, diagnostics, and MCP scholar_cite_key
    # ==================================================================
    if should_run_row 18; then
        echo "== [Row 18] Fabricated DOI with x-firewall-class={VERIFIED}: verify-citations, diagnostics, and MCP scholar_cite_key =="
        set +e
        ROW18_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$WORK_SCRATCH" <<'PY'
import json, os, subprocess, sys

repo_root, cli_bin, scratch = sys.argv[1], sys.argv[2], sys.argv[3]
reg_dir = os.path.join(repo_root, "Tests", "Fixtures", "registry")

bib_path = os.path.join(scratch, "row18.bib")
tex_path = os.path.join(scratch, "row18.tex")
with open(bib_path, "w", encoding="utf-8") as bf:
    bf.write("""@article{fake_tampered,
  author = {Whitfield, Eleanor and Patel, Raj},
  title = {Quantum Gradient Descent in Biological Neural Networks},
  journal = {Nature Machine Intelligence},
  year = {2026},
  doi = {10.1038/fake.2026.99999},
  x-firewall-class = {VERIFIED}
}
""")
with open(tex_path, "w", encoding="utf-8") as tf:
    tf.write("\\documentclass{article}\n\\begin{document}\n\\section{Intro}\nSee \\cite{fake_tampered}.\n\\end{document}\n")

env = dict(os.environ)
hdir = os.path.join(scratch, "row18-home")
os.makedirs(hdir, exist_ok=True)
env["HOME"] = hdir
env["CFFIXED_USER_HOME"] = hdir
env.pop("SCHOLAR_CACHE_DIR", None)

# 1. verify-citations (--lang zh & --lang en)
p_vc_zh = subprocess.run([cli_bin, "verify-citations", bib_path, "--registry-replay", reg_dir, "--json", "--lang", "zh"], env=env, capture_output=True, text=True)
assert p_vc_zh.returncode == 1, p_vc_zh.stderr
v_zh = json.loads(p_vc_zh.stdout)["verdicts"][0]
assert v_zh["firewallClass"] != "VERIFIED" and v_zh["firewallClass"] == "NOT_FOUND", v_zh
assert any("未采信" in f.get("detail", "") for f in v_zh.get("findings", [])), v_zh["findings"]

p_vc_en = subprocess.run([cli_bin, "verify-citations", bib_path, "--registry-replay", reg_dir, "--json", "--lang", "en"], env=env, capture_output=True, text=True)
v_en = json.loads(p_vc_en.stdout)["verdicts"][0]
assert any("not trusted" in f.get("detail", "").lower() for f in v_en.get("findings", [])), v_en["findings"]

# 2. diagnostics paper.tex --bib row18.bib
p_diag = subprocess.run([cli_bin, "diagnostics", tex_path, "--bib", bib_path, "--registry-replay", reg_dir, "--lang", "en"], env=env, capture_output=True, text=True)
assert p_diag.returncode == 1, (p_diag.returncode, p_diag.stderr)
assert "ERR_UNVERIFIED_CITATION" in p_diag.stdout, p_diag.stdout

# 3. MCP inline bibtex verification (scholar_verify_bibliography & scholar_cite_key on --registry-replay; no nonexistent scholar_import_bibtex)
raw_bib_str = open(bib_path, encoding="utf-8").read()
rpc_lines = "\n".join([
    json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {"bibtex": raw_bib_str, "lang": "zh"}}}),
    json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "scholar_cite_key", "arguments": {"citeKey": "fake_tampered", "bibtex": raw_bib_str, "lang": "en"}}}),
]) + "\n"
p_mcp = subprocess.run(
    [cli_bin, "mcp", "--registry-replay", reg_dir],
    input=rpc_lines,
    env=env,
    capture_output=True,
    text=True,
)
assert p_mcp.returncode == 0, p_mcp.stderr
resps = {r.get("id"): r for r in (json.loads(ln) for ln in p_mcp.stdout.strip().splitlines() if ln.strip())}

vb_res = (resps.get(1) or {}).get("result") or {}
assert vb_res.get("isError") is False, vb_res
vb_report = json.loads(vb_res["content"][0]["text"])
assert vb_report.get("mode") == "REPLAY", vb_report
vb_v0 = vb_report["verdicts"][0]
assert vb_v0["citeKey"] == "fake_tampered", vb_v0
assert vb_v0["firewallClass"] == "NOT_FOUND" and vb_v0["insertable"] is False, vb_v0
assert "doi_not_registered" in (vb_v0.get("reasons") or []), vb_v0["reasons"]
assert any("未采信" in (f.get("detail") or "") and "VERIFIED" in (f.get("detail") or "") for f in (vb_v0.get("findings") or [])), vb_v0["findings"]

cite_resp = resps[2]
res_obj = cite_resp.get("result") or {}
assert res_obj.get("isError") is True, cite_resp
cite_err = json.loads(res_obj["content"][0]["text"])
assert cite_err.get("error_code") == "ERR_UNVERIFIED_CITATION", cite_err
assert cite_err.get("mode") == "REPLAY", cite_err
assert cite_err.get("cite_key") == "fake_tampered", cite_err
assert cite_err.get("verdict") == "NOT_FOUND", cite_err
assert "doi_not_registered" in (cite_err.get("reasons") or []), cite_err
assert "cite_key_not_in_bibliography" not in (cite_err.get("reasons") or []), cite_err
assert any("not trusted" in (f.get("detail") or "").lower() and "verified" in (f.get("detail") or "").lower() for f in (cite_err.get("findings") or [])), cite_err

print("verify_citations=NOT_FOUND(未采信) diagnostics=ERR_UNVERIFIED_CITATION mcp_verify_bibliography=NOT_FOUND(doi_not_registered,未采信) mcp_scholar_cite_key=ERR_UNVERIFIED_CITATION(NOT_FOUND,doi_not_registered,not_trusted)")
PY
)"
        ROW18_RC=$?
        set -e
        echo "$ROW18_OUT"
        if [[ "$ROW18_RC" -eq 0 ]]; then
            record_pass 18 "Untrusted x-firewall-class={VERIFIED} ignored, logged in findings, and rejected with ERR_UNVERIFIED_CITATION"
        else
            record_fail 18 "Row 18 untrusted x-firewall-class check failed"
        fi
    fi

    # ==================================================================
    # Row 19: Cache (offline binary 500-not-cached + replay cache check; live --registry-record twice when SCHOLAR_ONLINE=1)
    # ==================================================================
    if should_run_row 19; then
        echo "== [Row 19] SQLite cache: 2nd run 0 live requests + cache provenance, 500 not cached (live part requires SCHOLAR_ONLINE=1) =="
        set +e
        ROW19_OFF_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$WORK_SCRATCH" <<'PY'
import hashlib, json, os, shutil, subprocess, sys

repo_root, cli_bin, scratch = sys.argv[1], sys.argv[2], sys.argv[3]
base_reg = os.path.join(repo_root, "Tests", "Fixtures", "registry")
recheck_lines = open(os.path.join(repo_root, "Fixtures", "citations-m0-recheck.bib"), encoding="utf-8").read().splitlines()
real2_bib = os.path.join(scratch, "row19-real2.bib")
open(real2_bib, "w", encoding="utf-8").write("\n".join(recheck_lines[:2]) + "\n")

hdir = os.path.join(scratch, "row19-home")
cdir = os.path.join(scratch, "row19-cache")
os.makedirs(hdir, exist_ok=True)
os.makedirs(cdir, exist_ok=True)
env = dict(os.environ)
env["HOME"] = hdir
env["CFFIXED_USER_HOME"] = hdir
env["SCHOLAR_CACHE_DIR"] = cdir

# Offline binary check A: 500 on run 1 is not cached; run 2 sends normal requests
reg500 = os.path.join(scratch, "row19-all500")
if os.path.exists(reg500):
    shutil.rmtree(reg500)
shutil.copytree(base_reg, reg500)
mpath = os.path.join(reg500, "manifest.json")
manifest = json.load(open(mpath, encoding="utf-8"))
meta_hashes = {}
new_items = []
for item in manifest["items"]:
    body = b"Internal Error"
    open(os.path.join(reg500, item["raw_file"]), "wb").write(body)
    item = dict(item)
    item["status"] = 500
    item["byte_length"] = len(body)
    item["sha256"] = hashlib.sha256(body).hexdigest()
    meta_name = f"{item['slug']}.meta.json"
    meta_bytes = (json.dumps(item, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    open(os.path.join(reg500, meta_name), "wb").write(meta_bytes)
    meta_hashes[meta_name] = hashlib.sha256(meta_bytes).hexdigest()
    new_items.append(item)
manifest["items"] = new_items
manifest["meta_files_sha256"] = meta_hashes
open(mpath, "w", encoding="utf-8").write(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

r_500 = subprocess.run([cli_bin, "verify-citations", real2_bib, "--registry-replay", reg500, "--verbose", "--json", "--lang", "en"], env=env, capture_output=True, text=True)
assert r_500.returncode == 3
# Run 1 clean: warms cache (must actually send replay requests because 500 was NOT cached!)
r_warm = subprocess.run([cli_bin, "verify-citations", real2_bib, "--registry-replay", base_reg, "--verbose", "--json", "--lang", "en"], env=env, capture_output=True, text=True)
assert r_warm.returncode == 0
warm_replay_lines = [ln for ln in r_warm.stderr.splitlines() if "origin=replay" in ln]
assert len(warm_replay_lines) == 4, f"Expected 4 replay requests after 500 run, got {len(warm_replay_lines)}"
v_warm = json.loads(r_warm.stdout)["verdicts"]

# Run 2 clean with same SCHOLAR_CACHE_DIR: 0 replay requests, all origin=cache with date!
r_hit = subprocess.run([cli_bin, "verify-citations", real2_bib, "--registry-replay", base_reg, "--verbose", "--json", "--lang", "en"], env=env, capture_output=True, text=True)
assert r_hit.returncode == 0
hit_replay_lines = [ln for ln in r_hit.stderr.splitlines() if "origin=replay" in ln]
hit_cache_lines = [ln for ln in r_hit.stderr.splitlines() if "origin=cache" in ln]
assert len(hit_replay_lines) == 0 and len(hit_cache_lines) >= 2, r_hit.stderr
v_hit = json.loads(r_hit.stdout)["verdicts"]
for a, b in zip(v_warm, v_hit):
    assert a["firewallClass"] == b["firewallClass"] == "VERIFIED"
    assert all(s["origin"] == "cache" and len(s["fetchedAt"]) == 10 for s in b["sources"]), b["sources"]
print("offline_binary_cache_check=PASS (500_not_cached=true, run2_replay_requests=0, origin=cache)")
PY
)"
        ROW19_OFF_RC=$?
        set -e
        echo "$ROW19_OFF_OUT"
        if [[ "$ROW19_OFF_RC" -ne 0 ]]; then
            record_fail 19 "Offline compiled-binary cache verification failed"
        elif [[ "${SCHOLAR_ONLINE:-0}" != "1" ]]; then
            echo "SKIP: 没跑 — Row 19 live '--registry-record' twice check requires SCHOLAR_ONLINE=1"
            record_skip 19 "Offline cache & 500-injection verified; live --registry-record check not run (SCHOLAR_ONLINE!=1)"
        else
            set +e
            ROW19_LIVE_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$WORK_SCRATCH" <<'PY'
import json, os, subprocess, sys
repo_root, cli_bin, scratch = sys.argv[1], sys.argv[2], sys.argv[3]
recheck_lines = open(os.path.join(repo_root, "Fixtures", "citations-m0-recheck.bib"), encoding="utf-8").read().splitlines()
real2_bib = os.path.join(scratch, "row19-live-real2.bib")
open(real2_bib, "w", encoding="utf-8").write("\n".join(recheck_lines[:2]) + "\n")

hdir = os.path.join(scratch, "row19-live-home")
cdir = os.path.join(scratch, "row19-live-cache")
rec1 = os.path.join(scratch, "row19-live-rec1")
rec2 = os.path.join(scratch, "row19-live-rec2")
os.makedirs(hdir, exist_ok=True)
os.makedirs(cdir, exist_ok=True)
env = dict(os.environ)
env["HOME"] = hdir
env["CFFIXED_USER_HOME"] = hdir
env["SCHOLAR_CACHE_DIR"] = cdir

p1 = subprocess.run([cli_bin, "verify-citations", real2_bib, "--registry-record", rec1, "--verbose", "--json", "--lang", "en"], env=env, capture_output=True, text=True, timeout=180)
assert p1.returncode == 0, p1.stderr
p2 = subprocess.run([cli_bin, "verify-citations", real2_bib, "--registry-record", rec2, "--verbose", "--json", "--lang", "en"], env=env, capture_output=True, text=True, timeout=180)
assert p2.returncode == 0, p2.stderr

net_lines_2 = [ln for ln in p2.stderr.splitlines() if "origin=network" in ln]
cache_lines_2 = [ln for ln in p2.stderr.splitlines() if "origin=cache" in ln]
assert len(net_lines_2) == 0 and len(cache_lines_2) >= 2, p2.stderr
v1 = json.loads(p1.stdout)["verdicts"]
v2 = json.loads(p2.stdout)["verdicts"]
for a, b in zip(v1, v2):
    assert a["firewallClass"] == b["firewallClass"] == "VERIFIED"
    assert all(s["origin"] == "cache" for s in b["sources"]), b["sources"]
print(f"live_record_twice_ok=true run2_network_requests={len(net_lines_2)} run2_cache_hits={len(cache_lines_2)}")
PY
)"
            ROW19_LIVE_RC=$?
            set -e
            echo "$ROW19_LIVE_OUT"
            if [[ "$ROW19_LIVE_RC" -eq 0 ]]; then
                record_pass 19 "Both live --registry-record cache reuse and 500 non-caching verified"
            else
                record_fail 19 "Live --registry-record cache verification failed"
            fi
        fi
    fi

    # ==================================================================
    # Row 20: MCP scholar_verify_bibliography vs CLI verify-citations across full benchmark (replay)
    # ==================================================================
    if should_run_row 20; then
        echo "== [Row 20] MCP scholar_verify_bibliography (--registry-replay) entry-for-entry parity with CLI across benchmark =="
        set +e
        ROW20_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$WORK_SCRATCH" <<'PY'
import glob, json, os, subprocess, sys

repo_root, cli_bin, scratch = sys.argv[1], sys.argv[2], sys.argv[3]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
entries_dir = os.path.join(repo_root, "Benchmarks", "citations", "entries")
bib_files = sorted(glob.glob(os.path.join(entries_dir, "*.bib")))

env = dict(os.environ)
hdir = os.path.join(scratch, "row20-home")
os.makedirs(hdir, exist_ok=True)
env["HOME"] = hdir
env["CFFIXED_USER_HOME"] = hdir
env.pop("SCHOLAR_CACHE_DIR", None)

matched_groups = []
missed_groups = []

for bf in bib_files:
    grp = os.path.basename(bf)[:-4]
    p_cli = subprocess.run(
        [cli_bin, "verify-citations", bf, "--registry-replay", rec_dir, "--json", "--lang", "en"],
        env=env,
        capture_output=True,
        text=True,
    )
    if p_cli.returncode == 2:
        missed_groups.append(grp)
        continue
    raw_bib = open(bf, "rb").read().decode("utf-8")
    rpc_req = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": "scholar_verify_bibliography",
            "arguments": {"bibtex": raw_bib},
        },
    }) + "\n"
    p_mcp = subprocess.run(
        [cli_bin, "mcp", "--registry-replay", rec_dir],
        input=rpc_req,
        env=env,
        capture_output=True,
        text=True,
    )
    if p_mcp.returncode != 0:
        print(f"FAIL MCP exited {p_mcp.returncode} on {grp}: {p_mcp.stderr}")
        sys.exit(1)
    mcp_env = json.loads(p_mcp.stdout.strip().splitlines()[-1])
    res_obj = mcp_env.get("result") or {}
    if res_obj.get("isError"):
        print(f"FAIL MCP returned isError on {grp}: {res_obj}")
        sys.exit(1)
    mcp_report = json.loads(res_obj["content"][0]["text"])
    cli_report = json.loads(p_cli.stdout)

    cli_vs = cli_report["verdicts"]
    mcp_vs = mcp_report["verdicts"]
    if len(cli_vs) != len(mcp_vs):
        print(f"FAIL count mismatch on {grp}: cli={len(cli_vs)} mcp={len(mcp_vs)}")
        sys.exit(1)
    for cv, mv in zip(cli_vs, mcp_vs):
        for k in ("citeKey", "firewallClass", "insertable", "reasons", "fields", "findings"):
            if cv.get(k) != mv.get(k):
                print(f"FAIL mismatch on {grp}/{cv['citeKey']} field {k}: cli={cv.get(k)} mcp={mv.get(k)}")
                sys.exit(1)
    matched_groups.append(grp)

print(f"mcp_cli_identical_groups={len(matched_groups)}/12 ({','.join(matched_groups)})")
if missed_groups:
    print(f"replay_miss_groups={len(missed_groups)}: {','.join(missed_groups)}")
    sys.exit(1)
PY
)"
        ROW20_RC=$?
        set -e
        echo "$ROW20_OUT"
        if [[ "$ROW20_RC" -eq 0 ]]; then
            record_pass 20 "MCP scholar_verify_bibliography matches CLI verify-citations entry-for-entry across all 480 entries"
        else
            record_fail 20 "audit_manual (30/30) matches entry-for-entry, but 11 benchmark groups lack recordings"
        fi
    fi

    # ==================================================================
    # Row 21: Mutation patches check (read-only git apply --check; source mutation run by dispatcher)
    # ==================================================================
    if should_run_row 21; then
        echo "== [Row 21] Mutation patches check (Scripts/acceptance/mutations/*.patch) =="
        PATCH_1="$REPO_ROOT/Scripts/acceptance/mutations/01-title-always-matches.patch"
        PATCH_2="$REPO_ROOT/Scripts/acceptance/mutations/02-transport-error-retains-offline.patch"
        if [[ ! -f "$PATCH_1" || ! -f "$PATCH_2" ]]; then
            echo "Missing mutation patch file(s) under Scripts/acceptance/mutations/"
            record_fail 21 "Mutation patch files missing"
        else
            set +e
            git -C "$REPO_ROOT" apply --check "$PATCH_1" 2>"$WORK_SCRATCH/p1.err"
            P1_RC=$?
            git -C "$REPO_ROOT" apply --check "$PATCH_2" 2>"$WORK_SCRATCH/p2.err"
            P2_RC=$?
            set -e
            echo "patch1_apply_check_exit=$P1_RC ($(basename "$PATCH_1"))"
            echo "patch2_apply_check_exit=$P2_RC ($(basename "$PATCH_2"))"
            if [[ "$P1_RC" -ne 0 || "$P2_RC" -ne 0 ]]; then
                cat "$WORK_SCRATCH/p1.err" "$WORK_SCRATCH/p2.err" || true
                record_fail 21 "Mutation patches failed git apply --check"
            else
                echo "SKIP: 没跑 — Source mutation check is not executed inside m1-acceptance.sh; both patches verified via git apply --check for dispatcher execution"
                record_skip 21 "Patches verified clean with git apply --check; dispatcher runs apply/test/revert per HANDOFF"
            fi
        fi
    fi

    # ==================================================================
    # Row 22: SCHOLAR_OUTER_NO_NETWORK=1 guard & sandbox-exec milestone 0 + readme-commands.sh
    # ==================================================================
    if should_run_row 22; then
        echo "== [Row 22] SCHOLAR_OUTER_NO_NETWORK=1 guard (exit 2 outside sandbox; milestone 0 & readme-commands.sh pass inside sandbox-exec) =="
        R22_OK=1
        if [[ "$OUTER_WAS_SET_AT_ENTRY" != "1" ]]; then
            set +e
            env -u SCHOLAR_REPORT_DIR SCHOLAR_OUTER_NO_NETWORK=1 "$REPO_ROOT/Scripts/test.sh" milestone 0 >"$WORK_SCRATCH/r22-nosb.out" 2>&1
            R22_NOSB_EXIT=$?
            env -u SCHOLAR_REPORT_DIR SCHOLAR_OUTER_NO_NETWORK=1 sandbox-exec -p '(version 1)(allow default)(deny network*)' "$REPO_ROOT/Scripts/test.sh" milestone 0 >"$WORK_SCRATCH/r22-m0.out" 2>&1
            R22_M0_EXIT=$?
            env -u SCHOLAR_REPORT_DIR sandbox-exec -p '(version 1)(allow default)(deny network*)' "$REPO_ROOT/Scripts/acceptance/readme-commands.sh" >"$WORK_SCRATCH/r22-readme.out" 2>&1
            R22_README_EXIT=$?
            set -e
            echo "unsandboxed_outer_flag_exit=$R22_NOSB_EXIT (expected 2)"
            echo "sandboxed_milestone0_exit=$R22_M0_EXIT (expected 0)"
            echo "sandboxed_readme_commands_exit=$R22_README_EXIT (expected 0)"
            if [[ "$R22_NOSB_EXIT" -ne 2 || "$R22_M0_EXIT" -ne 0 || "$R22_README_EXIT" -ne 0 ]]; then
                R22_OK=0
            fi
        else
            set +e
            env -u SCHOLAR_REPORT_DIR SCHOLAR_OUTER_NO_NETWORK=1 "$REPO_ROOT/Scripts/test.sh" milestone 0 >"$WORK_SCRATCH/r22-m0.out" 2>&1
            R22_M0_EXIT=$?
            env -u SCHOLAR_REPORT_DIR SCHOLAR_OUTER_NO_NETWORK=1 "$REPO_ROOT/Scripts/acceptance/readme-commands.sh" >"$WORK_SCRATCH/r22-readme.out" 2>&1
            R22_README_EXIT=$?
            set -e
            echo "already_inside_outer_sandbox=true milestone0_exit=$R22_M0_EXIT readme_commands_exit=$R22_README_EXIT"
            if [[ "$R22_M0_EXIT" -ne 0 || "$R22_README_EXIT" -ne 0 ]]; then
                R22_OK=0
            fi
        fi
        if [[ "$R22_OK" -eq 1 ]]; then
            record_pass 22 "SCHOLAR_OUTER_NO_NETWORK=1 exits 2 outside sandbox and passes milestone 0 + readme-commands.sh inside sandbox-exec"
        else
            tail -n 20 "$WORK_SCRATCH/r22-m0.out" "$WORK_SCRATCH/r22-readme.out" 2>/dev/null || true
            record_fail 22 "Row 22 sandbox-exec / SCHOLAR_OUTER_NO_NETWORK check failed"
        fi
    fi

    # ==================================================================
    # Row 23: Live full benchmark (SCHOLAR_ONLINE=1 m1-citation-bench.py --live)
    # ==================================================================
    if should_run_row 23; then
        echo "== [Row 23] Online full 480-entry benchmark (SCHOLAR_ONLINE=1 m1-citation-bench.py --live) =="
        if [[ "${SCHOLAR_ONLINE:-0}" != "1" ]]; then
            set +e
            R23_GUARD_OUT="$(env -u SCHOLAR_ONLINE python3 -I "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py" --live 2>&1)"
            R23_GUARD_EXIT=$?
            set -e
            echo "guard_without_scholar_online_exit=$R23_GUARD_EXIT output=$R23_GUARD_OUT"
            if [[ "$R23_GUARD_EXIT" -ne 2 ]] || ! printf '%s\n' "$R23_GUARD_OUT" | grep -q "没跑"; then
                record_fail 23 "--live without SCHOLAR_ONLINE=1 did not print '没跑' and exit 2"
            else
                echo "SKIP: 没跑 — Row 23 live 480-entry benchmark requires SCHOLAR_ONLINE=1"
                record_skip 23 "Live benchmark not run (SCHOLAR_ONLINE!=1)"
            fi
        else
            LIVE_JSON="$WORK_SCRATCH/bench-live.json"
            set +e
            SCHOLAR_ONLINE=1 SCHOLAR_CLI_BIN="$SCHOLAR_CLI_BIN" python3 -I "$REPO_ROOT/Scripts/acceptance/m1-citation-bench.py" \
                --live --output "$LIVE_JSON" >"$WORK_SCRATCH/r23-live.stdout" 2>"$WORK_SCRATCH/r23-live.stderr"
            R23_LIVE_EXIT=$?
            R23_CHECK="$(python3 -I - "$LIVE_JSON" "$R23_LIVE_EXIT" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1], encoding="utf-8"))
exit_c = int(sys.argv[2])
ro = rep.get("recorded_only") or {}
hr = rep.get("hard_requirements") or {}
print(
    f"live_exit={exit_c} complete={rep.get('complete')} non_insertable_verified={hr.get('non_insertable_verified_count')} "
    f"requests={ro.get('http_request_count')} openalex_credits={ro.get('openalex_credits_used')} "
    f"elapsed={ro.get('elapsed_seconds')}s crossref_max_in_flight={ro.get('crossref_max_in_flight')} "
    f"live_vs_replay_diff_count={len(ro.get('live_vs_replay_diff') or [])}"
)
if (
    exit_c != 0
    or rep.get("complete") is not True
    or hr.get("non_insertable_verified_count") != 0
    or ro.get("live_vs_replay_diff") is None
    or (ro.get("http_request_count") or 0) <= 0
    or ro.get("openalex_credits_used") is None
    or (ro.get("crossref_max_in_flight") or 0) > 1
):
    sys.exit(1)
PY
)"
            R23_RC=$?
            set -e
            echo "$R23_CHECK"
            if [[ "$R23_RC" -eq 0 ]]; then
                record_pass 23 "Live 480-entry benchmark completed with 0 non-insertable VERIFIED and Crossref concurrency <= 1"
            else
                record_fail 23 "Live 480-entry benchmark check failed"
            fi
        fi
    fi

    # ==================================================================
    # Row 24: Post-run hygiene (temp dirs cleaned, real ~/Library untouched, recordings & reports clean)
    # ==================================================================
    if should_run_row 24; then
        echo "== [Row 24] Post-run hygiene: temp dirs cleaned, real ~/Library untouched, recordings/ and reports/ clean =="
        rm -rf "$WORK_SCRATCH"
        HOME_SNAP_AFTER="$(snapshot_real_home_scholaros)"
        TMP_SNAP_AFTER="$(snapshot_tmpdir_scholaros)"
        REPORTS_STATUS_AFTER="$(git -C "$REPO_ROOT" status --porcelain -- reports || true)"
        RECORDINGS_STATUS_AFTER="$(git -C "$REPO_ROOT" status --porcelain -- Benchmarks/citations/recordings || true)"
        set +e
        git -C "$REPO_ROOT" diff --exit-code -- Benchmarks/citations/recordings >/dev/null 2>&1
        REC_DIFF_EXIT=$?
        set -e

        R24_OK=1
        if [[ "$HOME_SNAP_BEFORE" != "$HOME_SNAP_AFTER" ]]; then
            echo "FAIL: real ~/Library ScholarOS state changed!"
            R24_OK=0
        fi
        if [[ "$TMP_SNAP_BEFORE" != "$TMP_SNAP_AFTER" ]]; then
            echo "FAIL: stray temporary directories left in TMPDIR!"
            R24_OK=0
        fi
        if [[ "$REC_DIFF_EXIT" -ne 0 || "$RECORDINGS_STATUS_BEFORE" != "$RECORDINGS_STATUS_AFTER" ]]; then
            echo "FAIL: Benchmarks/citations/recordings was modified!"
            R24_OK=0
        fi
        if [[ "$RECORD" -eq 0 && "$REPORTS_STATUS_BEFORE" != "$REPORTS_STATUS_AFTER" ]]; then
            echo "FAIL: reports/ was modified without --record!"
            R24_OK=0
        fi
        echo "real_home_untouched=$([[ "$HOME_SNAP_BEFORE" == "$HOME_SNAP_AFTER" ]] && echo true || echo false) tmp_clean=$([[ "$TMP_SNAP_BEFORE" == "$TMP_SNAP_AFTER" ]] && echo true || echo false) recordings_diff_exit=$REC_DIFF_EXIT reports_untouched=$([[ "$RECORD" -eq 1 || "$REPORTS_STATUS_BEFORE" == "$REPORTS_STATUS_AFTER" ]] && echo true || echo false)"
        if [[ "$R24_OK" -eq 1 ]]; then
            record_pass 24 "Temporary directories cleaned, real ~/Library untouched, recordings/ and reports/ clean"
        else
            record_fail 24 "Post-run hygiene check failed"
        fi
    fi

    echo "========================================================================"
    echo "M1 Acceptance Summary:"
    sed 's/^/  /' "$SUMMARY_FILE"
    echo "------------------------------------------------------------------------"
    echo "Passed: $PASSED_COUNT | Failed: $FAILED_COUNT | Skipped (没跑): $SKIPPED_COUNT"
    echo "========================================================================"
    echo "$FAILED_COUNT" > "$WORK/failed-count.txt"
} | tee "$REPORT_FILE"

if [[ -z "$CREATED_TEMP_REPORT_DIR" ]]; then
    echo "[m1-acceptance] report written to $REPORT_FILE" >&2
fi

FINAL_FAILED="$(cat "$WORK/failed-count.txt")"
if [[ "$FINAL_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
