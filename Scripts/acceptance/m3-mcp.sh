#!/usr/bin/env bash
#
# M3 acceptance verification script (`Scripts/acceptance/m3-mcp.sh`).
#
# Stage 01–02 scope (active rows):
#   - Row 1:  `tools/list` — Stage 01 verifies 0 tools expose `registryReplayPath` in `inputSchema` or `description`;
#             new tools (`verify_citation`, `add_verified_bibtex`, `check_manuscript`) & frozen-tool gating deferred to Stages 04–05 (`没跑`)
#   - Row 10: Caller fake replay (`S74`) — builds a self-consistent fake replay directory on the fly in scratch and verifies
#             existing MCP tools (`scholar_cite_key`, `scholar_verify_bibliography`, `scholar_lsp_diagnostics`) reject `registryReplayPath`
#             (and unknown argument names) with structured `ERR_INVALID_ARGUMENT`, never grant `VERIFIED` to `invented_2026`, and leave
#             target `.bib` byte/size/mtime unchanged; new tools deferred to Stage 04 (`没跑`)
#   - Row 12: Replay markers (`S75`) — `--registry-replay` server prints `[REPLAY]` on stderr, every tool result JSON has top-level
#             `"mode": "REPLAY"`, and `sources[].fetchedAt` / `firewallVerifiedAtUTC` carry the recording date `2026-11-16`
#   - Row 17: Protocol (`S78`) — `ping` returns `{}`, `serverInfo.version` dynamically matches `scholaros version`,
#             malformed JSON returns `-32700`, unknown method returns `-32601`
#   - Row 19: Unit tests (`S79`) — `swift test --no-parallel` passes (>= 289 tests) both without and with `SCHOLAR_CACHE_DIR`
#   - Row 20: Non-regression (`S77` / `S81`) — Stage 02 verifies `m1-citation-bench.py --replay`, 480-entry per-entry `{verdict, reasons, insertable}`
#             & 12-group exit codes vs baseline (plus 206/206 `VERIFIED` carrying `record`), and `m1-acceptance.sh --row 18`;
#             `Scripts/test.sh milestone 2` & Stage 05 new-tool M1 Row 18/20 updates deferred to Stage 05 (`没跑`)
#
# Remaining rows print `没跑` in Stage 02.
# Exit code: 0 only when all executed rows PASS and 0 rows are `没跑`; 1 on any FAIL; 2 when 0 FAIL and >= 1 `没跑`.
#
# Usage:
#   Scripts/acceptance/m3-mcp.sh [--record] [--row <1..23>]
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
            if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ || "$2" -lt 1 || "$2" -gt 23 ]]; then
                echo "Usage: Scripts/acceptance/m3-mcp.sh [--record] [--row <1..23>]" >&2
                exit 2
            fi
            ONLY_ROW="$2"
            shift 2
            ;;
        --row=*)
            val="${1#--row=}"
            if [[ ! "$val" =~ ^[0-9]+$ || "$val" -lt 1 || "$val" -gt 23 ]]; then
                echo "Usage: Scripts/acceptance/m3-mcp.sh [--record] [--row <1..23>]" >&2
                exit 2
            fi
            ONLY_ROW="$val"
            shift
            ;;
        *)
            echo "Usage: Scripts/acceptance/m3-mcp.sh [--record] [--row <1..23>]" >&2
            exit 2
            ;;
    esac
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m3-work.XXXXXX")"
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
    CREATED_TEMP_REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-m3-report.XXXXXX")"
    REPORT_DIR="$CREATED_TEMP_REPORT_DIR"
fi
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/m3-mcp.txt"

export SCHOLAR_SANDBOX_HOME="$WORK/home"
mkdir -p "$SCHOLAR_SANDBOX_HOME"
unset SCHOLAR_CACHE_DIR

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

{
    echo "# ScholarOS M3 MCP Acceptance Verification Report"
    echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Commit: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "Binary: ${SCHOLAR_CLI_BIN#"$REPO_ROOT"/}"
    echo "Mode: --registry-replay Benchmarks/citations/recordings (isolated HOME, SCHOLAR_CACHE_DIR unset)"
    echo ""

    # ==================================================================
    # Row 1: tools/list — Stage 01 checks 0 tools expose registryReplayPath; new tools in Stages 04–05
    # ==================================================================
    if should_run_row 1; then
        echo "== [Row 1] tools/list: S74 check (no tool exposes registryReplayPath); new tools check =="
        set +e
        R1_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" <<'PY'
import json, os, subprocess, sys

repo_root, cli_bin, sbox_home = sys.argv[1], sys.argv[2], sys.argv[3]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")

env = dict(os.environ)
env["HOME"] = sbox_home
env["CFFIXED_USER_HOME"] = sbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "m3-mcp", "version": "1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
]
raw_in = "\n".join(json.dumps(r) for r in reqs) + "\n"
proc = subprocess.run(
    [cli_bin, "mcp", "--registry-replay", rec_dir],
    input=raw_in,
    env=env,
    capture_output=True,
    text=True,
)
if proc.returncode != 0:
    print(f"  FAIL [Row 1]: mcp exited {proc.returncode}: {proc.stderr}")
    sys.exit(1)

resps = {obj.get("id"): obj for obj in (json.loads(ln) for ln in proc.stdout.splitlines() if ln.strip())}
tools = ((resps.get(2) or {}).get("result") or {}).get("tools") or []
if not tools:
    print("  FAIL [Row 1]: tools/list returned 0 tools")
    sys.exit(1)

bad = []
names = []
for t in tools:
    tname = t.get("name", "<unnamed>")
    names.append(tname)
    props = ((t.get("inputSchema") or {}).get("properties") or {})
    desc = t.get("description") or ""
    blob = json.dumps(t, ensure_ascii=False)
    if "registryReplayPath" in props or "registryReplayPath" in desc or "registryReplayPath" in blob:
        bad.append(tname)

if bad:
    print(f"  FAIL [Row 1]: tools still expose registryReplayPath: {bad}")
    sys.exit(1)

print(f"  [Row 1a] PASS: 0/{len(tools)} tools expose registryReplayPath in inputSchema or description (tools={names})")
want_new = {"verify_citation", "add_verified_bibtex", "check_manuscript"}
missing_new = sorted(want_new - set(names))
if missing_new:
    print(f"  [Row 1b] 没跑: new M3 tools not yet implemented in Stage 01 (missing={missing_new})")
    sys.exit(2)

sys.exit(0)
PY
)"
        R1_RC=$?
        set -e
        echo "$R1_OUT"
        if [[ "$R1_RC" -eq 0 ]]; then
            record_pass 1 "tools/list exposes required M3 tools and 0 tools carry registryReplayPath"
        elif [[ "$R1_RC" -eq 2 ]]; then
            record_skip 1 "S74 half passed (0 tools have registryReplayPath); new tools verify_citation/add_verified_bibtex/check_manuscript deferred to Stages 04-05 (没跑)"
        else
            record_fail 1 "Row 1 tools/list registryReplayPath check failed"
        fi
    fi

    # ==================================================================
    # Rows 2–9: Deferred to Stage 04 (add_verified_bibtex / verify_citation)
    # ==================================================================
    for r in 2 3 4 5 6 7 8 9; do
        if should_run_row "$r"; then
            echo "== [Row $r] 没跑 — Scheduled for Stage 04 (add_verified_bibtex / verify_citation) =="
            record_skip "$r" "Scheduled for Stage 04 (add_verified_bibtex / verify_citation) — 没跑"
        fi
    done

    # ==================================================================
    # Row 10: Caller fake replay (S74) — generated on the fly, never committed
    # ==================================================================
    if should_run_row 10; then
        echo "== [Row 10] Caller fake replay (S74): registryReplayPath rejected with ERR_INVALID_ARGUMENT, invented_2026 never VERIFIED, file unchanged =="
        set +e
        R10_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import hashlib, json, os, subprocess, sys

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
real_rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
fake_rec_dir = os.path.join(scratch, "fake-replay")
os.makedirs(fake_rec_dir, exist_ok=True)

# 1. Build self-consistent fake replay directory on the fly (same construction as make_fake_replay.py)
manifest = json.load(open(os.path.join(real_rec_dir, "manifest.json"), encoding="utf-8"))
want = {"crossref_doi_10.1109_66.728565_22703beb17", "openalex_doi_10.1109_66.728565_c9f0c4accb"}
fake_title = "A completely invented paper about quantum lichen yield"
items, meta_hashes = [], {}
for it in manifest["items"]:
    if it["slug"] not in want:
        continue
    d = json.loads(open(os.path.join(real_rec_dir, it["raw_file"]), "rb").read().decode("utf-8"))
    if it["service"] == "crossref":
        d["message"]["title"] = [fake_title]
        d["message"]["author"][0]["family"] = "Inventa"
    else:
        d["title"] = fake_title
        d["display_name"] = fake_title
    body = json.dumps(d).encode("utf-8")
    open(os.path.join(fake_rec_dir, it["raw_file"]), "wb").write(body)
    it2 = dict(it, sha256=hashlib.sha256(body).hexdigest(), byte_length=len(body))
    meta_name = it2["slug"] + ".meta.json"
    meta_bytes = json.dumps(it2, indent=2, sort_keys=True).encode("utf-8")
    open(os.path.join(fake_rec_dir, meta_name), "wb").write(meta_bytes)
    meta_hashes[meta_name] = hashlib.sha256(meta_bytes).hexdigest()
    items.append(it2)

if len(items) != 2:
    print(f"  FAIL [Row 10]: expected 2 fake replay items, built {len(items)}")
    sys.exit(1)

m2 = dict(manifest, items=items, count=len(items), total_http_requests_sent=len(items), meta_files_sha256=meta_hashes)
json.dump(m2, open(os.path.join(fake_rec_dir, "manifest.json"), "w", encoding="utf-8"), indent=2)

fake_bib = """@article{invented_2026,
  author = {Inventa, J. and Ferguson, F.J.},
  title = {A completely invented paper about quantum lichen yield},
  journal = {IEEE Transactions on Semiconductor Manufacturing},
  year = {1998},
  doi = {10.1109/66.728565}
}
"""

target_bib = os.path.join(scratch, "row10-target.bib")
with open(target_bib, "wb") as fh:
    fh.write(b"% sentinel target bib\n")

def file_sig(path: str):
    raw = open(path, "rb").read()
    st = os.stat(path)
    return (hashlib.sha256(raw).hexdigest(), st.st_size, st.st_mtime_ns)

sig_before = file_sig(target_bib)

tex_path = os.path.join(scratch, "row10.tex")
open(tex_path, "w", encoding="utf-8").write("\\documentclass{article}\\begin{document}Cite \\cite{invented_2026}.\\end{document}\n")

env = dict(os.environ)
env["HOME"] = sbox_home
env["CFFIXED_USER_HOME"] = sbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

def call_mcp(server_args, reqs):
    raw_in = "\n".join(json.dumps(r) for r in reqs) + "\n"
    p = subprocess.run([cli_bin, "mcp", *server_args], input=raw_in, env=env, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"mcp {server_args} exited {p.returncode}: {p.stderr}")
    return {obj.get("id"): obj for obj in (json.loads(ln) for ln in p.stdout.splitlines() if ln.strip())}

# Test on both --offline server and --registry-replay <real_rec_dir> server
for mode_label, srv_args in [("offline", ["--offline"]), ("replay", ["--registry-replay", real_rec_dir])]:
    reqs = [
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "scholar_cite_key", "arguments": {"citeKey": "invented_2026", "bibtex": fake_bib, "registryReplayPath": fake_rec_dir}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {"bibtex": fake_bib, "registryReplayPath": fake_rec_dir}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "scholar_lsp_diagnostics", "arguments": {"path": tex_path, "registryReplayPath": fake_rec_dir}}},
        {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "scholar_cite_key", "arguments": {"citeKey": "invented_2026", "bibtex": fake_bib}}},
        {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {"bibtex": fake_bib}}},
        {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {"bibtex": fake_bib, "bogusUnknownArg": "x"}}},
    ]
    resps = call_mcp(srv_args, reqs)

    for rid, tname in [(2, "scholar_cite_key"), (3, "scholar_verify_bibliography"), (4, "scholar_lsp_diagnostics"), (7, "scholar_verify_bibliography(unknownArg)")]:
        res = (resps.get(rid) or {}).get("result") or {}
        if res.get("isError") is not True:
            print(f"  FAIL [Row 10/{mode_label}]: {tname} did not set isError=True: {res}")
            sys.exit(1)
        txt = ((res.get("content") or [{}])[0]).get("text") or ""
        if "CITATION_STATUS:VERIFIED" in txt:
            print(f"  FAIL [Row 10/{mode_label}]: {tname} returned CITATION_STATUS:VERIFIED!")
            sys.exit(1)
        try:
            err_obj = json.loads(txt)
        except Exception as exc:
            print(f"  FAIL [Row 10/{mode_label}]: {tname} error is not structured JSON ({exc}): {txt}")
            sys.exit(1)
        if err_obj.get("error_code") != "ERR_INVALID_ARGUMENT":
            print(f"  FAIL [Row 10/{mode_label}]: {tname} expected ERR_INVALID_ARGUMENT, got {err_obj}")
            sys.exit(1)
        if not err_obj.get("category") or not err_obj.get("reason") or not err_obj.get("reasons"):
            print(f"  FAIL [Row 10/{mode_label}]: {tname} missing category/reason/reasons: {err_obj}")
            sys.exit(1)

    # Without registryReplayPath, invented_2026 must NEVER be VERIFIED
    cite_clean = (resps.get(5) or {}).get("result") or {}
    if cite_clean.get("isError") is not True:
        print(f"  FAIL [Row 10/{mode_label}]: scholar_cite_key on invented_2026 succeeded unexpectedly: {cite_clean}")
        sys.exit(1)
    vb_clean = json.loads(((resps[6]["result"]["content"])[0])["text"])
    if vb_clean.get("verifiedCount") != 0 or vb_clean["verdicts"][0]["firewallClass"] == "VERIFIED":
        print(f"  FAIL [Row 10/{mode_label}]: scholar_verify_bibliography granted VERIFIED to invented_2026: {vb_clean}")
        sys.exit(1)

sig_after = file_sig(target_bib)
if sig_before != sig_after:
    print(f"  FAIL [Row 10]: target.bib changed (before={sig_before}, after={sig_after})")
    sys.exit(1)

tool_names = {t.get("name") for t in ((resps.get(1) or {}).get("result") or {}).get("tools") or []}
print("  [Row 10a] PASS: existing tools reject fake replay & unknown args with structured ERR_INVALID_ARGUMENT, invented_2026 gets 0 VERIFIED, file unchanged")
if not {"verify_citation", "add_verified_bibtex"}.issubset(tool_names):
    print("  [Row 10b] 没跑: verify_citation & add_verified_bibtex deferred to Stage 04")
    sys.exit(2)

sys.exit(0)
PY
)"
        R10_RC=$?
        set -e
        echo "$R10_OUT"
        if [[ "$R10_RC" -eq 0 ]]; then
            record_pass 10 "All tools reject registryReplayPath with ERR_INVALID_ARGUMENT; invented_2026 never VERIFIED; file unchanged"
        elif [[ "$R10_RC" -eq 2 ]]; then
            record_skip 10 "S74 existing tools passed ERR_INVALID_ARGUMENT & 0 VERIFIED on fake replay; verify_citation & add_verified_bibtex deferred to Stage 04 (没跑)"
        else
            record_fail 10 "Row 10 caller fake replay check failed"
        fi
    fi

    # ==================================================================
    # Row 11: Deferred to Stage 04 (verify_citation 480-entry parity)
    # ==================================================================
    if should_run_row 11; then
        echo "== [Row 11] 没跑 — Scheduled for Stage 04 (verify_citation 480-entry parity) =="
        record_skip 11 "Scheduled for Stage 04 (verify_citation 480-entry parity) — 没跑"
    fi

    # ==================================================================
    # Row 12: Replay markers & recorded date 2026-11-16 (S75)
    # ==================================================================
    if should_run_row 12; then
        echo "== [Row 12] Replay markers (S75): all tools return mode='REPLAY', stderr emits [REPLAY], fetchedAt/firewallVerifiedAtUTC == 2026-11-16 =="
        set +e
        R12_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import json, os, re, subprocess, sys

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")

env = dict(os.environ)
env["HOME"] = sbox_home
env["CFFIXED_USER_HOME"] = sbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

# Extract real_clean_001 and fab_codex_003 from Benchmarks/citations/entries/
def extract_entry(bib_file: str, key: str) -> str:
    text = open(bib_file, encoding="utf-8").read()
    m = re.search(rf"(@\w+\{{{re.escape(key)},.*?\n\}})", text, flags=re.S)
    if not m:
        raise RuntimeError(f"Could not find {key} in {bib_file}")
    return m.group(1) + "\n"

real_clean_001 = extract_entry(os.path.join(repo_root, "Benchmarks", "citations", "entries", "real_clean.bib"), "real_clean_001")
fab_codex_003 = extract_entry(os.path.join(repo_root, "Benchmarks", "citations", "entries", "fabricated_model.bib"), "fab_codex_003")

bib_path = os.path.join(scratch, "r12.bib")
tex_path = os.path.join(scratch, "r12.tex")
proj_path = os.path.join(scratch, "r12.scholarproj")
open(bib_path, "w", encoding="utf-8").write(real_clean_001)
open(tex_path, "w", encoding="utf-8").write("\\documentclass{article}\\begin{document}\\section{Intro}Cite \\cite{real_clean_001}.\\end{document}\n")
subprocess.run([cli_bin, "init", "--project", proj_path, "--seed-demo"], env=env, capture_output=True, text=True, check=True)

reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "scholar_cite_key", "arguments": {"citeKey": "real_clean_001", "bibtex": real_clean_001}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "scholar_cite_key", "arguments": {"citeKey": "fab_codex_003", "bibtex": fab_codex_003}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {"bibtex": real_clean_001}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "scholar_lsp_diagnostics", "arguments": {"path": tex_path, "bibPath": bib_path}}},
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "scholar_search_provenance", "arguments": {"claim": "attention", "projectPath": proj_path}}},
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "scholar_prisma_agreement", "arguments": {"projectPath": proj_path}}},
    {"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "scholar_editorial_audit", "arguments": {"source": "\\section{Intro}\nPlain text.\n"}}},
    {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "scholar_track_changes_diff", "arguments": {"original": "Old.", "revised": "New."}}},
    {"jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": {"name": "scholar_citation_gaps", "arguments": {"projectPath": proj_path}}},
]
raw_in = "\n".join(json.dumps(r) for r in reqs) + "\n"
proc = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input=raw_in, env=env, capture_output=True, text=True)
if proc.returncode != 0:
    print(f"  FAIL [Row 12]: mcp exited {proc.returncode}: {proc.stderr}")
    sys.exit(1)

if "[REPLAY]" not in proc.stderr:
    print(f"  FAIL [Row 12]: mcp --registry-replay did not print [REPLAY] notice on stderr: {proc.stderr!r}")
    sys.exit(1)

resps = {obj.get("id"): obj for obj in (json.loads(ln) for ln in proc.stdout.splitlines() if ln.strip())}

for rid in range(2, 11):
    res = (resps.get(rid) or {}).get("result") or {}
    txt = ((res.get("content") or [{}])[0]).get("text") or ""
    try:
        payload = json.loads(txt)
    except Exception as exc:
        print(f"  FAIL [Row 12]: request id={rid} did not return JSON object ({exc}): {txt!r}")
        sys.exit(1)
    if not isinstance(payload, dict) or payload.get("mode") != "REPLAY":
        print(f"  FAIL [Row 12]: request id={rid} missing top-level mode='REPLAY': {payload}")
        sys.exit(1)

cite_ok = json.loads(resps[2]["result"]["content"][0]["text"])
if cite_ok.get("verdict") != "VERIFIED" or cite_ok.get("verified_at_utc") != "2026-11-16":
    print(f"  FAIL [Row 12]: scholar_cite_key real_clean_001 unexpected payload: {cite_ok}")
    sys.exit(1)
for s in cite_ok.get("sources") or []:
    if not (s.get("fetchedAt") or "").startswith("2026-11-16"):
        print(f"  FAIL [Row 12]: scholar_cite_key source fetchedAt != 2026-11-16: {s}")
        sys.exit(1)

vb_ok = json.loads(resps[4]["result"]["content"][0]["text"])
v0 = vb_ok["verdicts"][0]
audited_at = (v0.get("auditedEntry") or {}).get("firewallVerifiedAtUTC")
if audited_at != "2026-11-16":
    print(f"  FAIL [Row 12]: firewallVerifiedAtUTC expected '2026-11-16', got {audited_at!r}")
    sys.exit(1)
for s in v0.get("sources") or []:
    if not (s.get("fetchedAt") or "").startswith("2026-11-16") or s.get("origin") != "replay":
        print(f"  FAIL [Row 12]: unexpected source provenance on real_clean_001: {s}")
        sys.exit(1)

print("  [Row 12] PASS: stderr=[REPLAY], all 8 tools carry mode='REPLAY', sources.fetchedAt & firewallVerifiedAtUTC == 2026-11-16")
PY
)"
        R12_RC=$?
        set -e
        echo "$R12_OUT"
        if [[ "$R12_RC" -eq 0 ]]; then
            record_pass 12 "All tools on --registry-replay server emit mode='REPLAY' and recorded date 2026-11-16"
        else
            record_fail 12 "Row 12 replay markers or recorded date check failed"
        fi
    fi

    # ==================================================================
    # Rows 13–16: Deferred to Stages 03–05
    # ==================================================================
    for r in 13 14 15 16; do
        if should_run_row "$r"; then
            echo "== [Row $r] 没跑 — Scheduled for Stages 03–05 =="
            record_skip "$r" "Scheduled for Stages 03–05 — 没跑"
        fi
    done

    # ==================================================================
    # Row 17: Protocol (S78) — ping {}, serverInfo.version == scholaros version, -32700, -32601
    # ==================================================================
    if should_run_row 17; then
        echo "== [Row 17] Protocol (S78): ping -> {}, serverInfo.version == scholaros version, invalid JSON -> -32700, unknown method -> -32601 =="
        set +e
        R17_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" <<'PY'
import json, os, re, subprocess, sys

repo_root, cli_bin, sbox_home = sys.argv[1:4]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")

env = dict(os.environ)
env["HOME"] = sbox_home
env["CFFIXED_USER_HOME"] = sbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

p_ver = subprocess.run([cli_bin, "version"], env=env, capture_output=True, text=True)
if p_ver.returncode != 0:
    print(f"  FAIL [Row 17]: scholaros version exited {p_ver.returncode}: {p_ver.stderr}")
    sys.exit(1)
m = re.match(r"^ScholarOS\s+(\S+)", p_ver.stdout.strip())
if not m:
    print(f"  FAIL [Row 17]: could not parse version from 'scholaros version': {p_ver.stdout!r}")
    sys.exit(1)
cli_version = m.group(1)

lines = [
    json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "m3-mcp", "version": "0"}}}),
    json.dumps({"jsonrpc": "2.0", "id": 2, "method": "ping"}),
    json.dumps({"jsonrpc": "2.0", "id": "p-obj", "method": "ping", "params": {}}),
    "{not valid json",
    json.dumps({"jsonrpc": "2.0", "id": 4, "method": "scholar/unknown_method", "params": {}}),
]
p_mcp = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input="\n".join(lines) + "\n", env=env, capture_output=True, text=True)
if p_mcp.returncode != 0:
    print(f"  FAIL [Row 17]: mcp exited {p_mcp.returncode}: {p_mcp.stderr}")
    sys.exit(1)

out_objs = [json.loads(ln) for ln in p_mcp.stdout.splitlines() if ln.strip()]
if len(out_objs) != 5:
    print(f"  FAIL [Row 17]: expected 5 JSON-RPC responses, got {len(out_objs)}: {out_objs}")
    sys.exit(1)

init_ver = ((out_objs[0].get("result") or {}).get("serverInfo") or {}).get("version")
if init_ver != cli_version:
    print(f"  FAIL [Row 17]: serverInfo.version={init_ver!r} != scholaros version={cli_version!r}")
    sys.exit(1)

for idx in (1, 2):
    if "error" in out_objs[idx] or out_objs[idx].get("result") != {}:
        print(f"  FAIL [Row 17]: ping response #{idx} expected result={{}}, got {out_objs[idx]}")
        sys.exit(1)

if (out_objs[3].get("error") or {}).get("code") != -32700:
    print(f"  FAIL [Row 17]: invalid JSON expected -32700, got {out_objs[3]}")
    sys.exit(1)

if (out_objs[4].get("error") or {}).get("code") != -32601:
    print(f"  FAIL [Row 17]: unknown method expected -32601, got {out_objs[4]}")
    sys.exit(1)

print(f"  [Row 17] PASS: serverInfo.version={init_ver} (matches CLI), ping={{}}, invalid_json=-32700, unknown_method=-32601")
PY
)"
        R17_RC=$?
        set -e
        echo "$R17_OUT"
        if [[ "$R17_RC" -eq 0 ]]; then
            record_pass 17 "ping returns {}, serverInfo.version matches scholaros version, -32700 and -32601 preserved"
        else
            record_fail 17 "Row 17 MCP JSON-RPC protocol check failed"
        fi
    fi

    # ==================================================================
    # Row 18: Handled by m3-clients.sh in Stage 06
    # ==================================================================
    if should_run_row 18; then
        echo "== [Row 18] 没跑 — Handled by m3-clients.sh in Stage 06 =="
        record_skip 18 "Handled by m3-clients.sh in Stage 06 — 没跑"
    fi

    # ==================================================================
    # Row 19: Unit tests with and without SCHOLAR_CACHE_DIR (S79)
    # ==================================================================
    if should_run_row 19; then
        echo "== [Row 19] Unit tests (S79): swift test --no-parallel without and with SCHOLAR_CACHE_DIR (>= 289 tests each) =="
        R19_HOME1="$WORK_SCRATCH/r19-home1"
        R19_HOME2="$WORK_SCRATCH/r19-home2"
        R19_CACHE="$WORK_SCRATCH/r19-cache"
        mkdir -p "$R19_HOME1" "$R19_HOME2" "$R19_CACHE"

        set +e
        (
            unset SCHOLAR_CACHE_DIR
            HOME="$R19_HOME1" CFFIXED_USER_HOME="$R19_HOME1" swift test --no-parallel
        ) >"$WORK_SCRATCH/r19-nocache.log" 2>&1
        R19_RC1=$?

        (
            HOME="$R19_HOME2" CFFIXED_USER_HOME="$R19_HOME2" SCHOLAR_CACHE_DIR="$R19_CACHE" swift test --no-parallel
        ) >"$WORK_SCRATCH/r19-withcache.log" 2>&1
        R19_RC2=$?

        R19_PARSE="$(python3 -I - "$WORK_SCRATCH/r19-nocache.log" "$R19_RC1" "$WORK_SCRATCH/r19-withcache.log" "$R19_RC2" "$R19_CACHE" <<'PY'
import os, re, sys

log1, rc1, log2, rc2, cache_dir = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5]

def extract_count(path: str):
    txt = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r"Test run with (\d+) tests", txt)
    return int(m.group(1)) if m else 0, txt

c1, t1 = extract_count(log1)
c2, t2 = extract_count(log2)
leaked_db = os.path.exists(os.path.join(cache_dir, "registry.sqlite"))
print(f"  [Row 19] without_SCHOLAR_CACHE_DIR: exit={rc1} tests={c1} | with_SCHOLAR_CACHE_DIR: exit={rc2} tests={c2} caller_cache_untouched={not leaked_db}")
if rc1 != 0 or c1 < 289:
    print("  --- tail of without_SCHOLAR_CACHE_DIR ---")
    print("\n".join(t1.splitlines()[-20:]))
    sys.exit(1)
if rc2 != 0 or c2 < 289 or leaked_db:
    print("  --- tail of with_SCHOLAR_CACHE_DIR ---")
    print("\n".join(t2.splitlines()[-20:]))
    sys.exit(1)
sys.exit(0)
PY
)"
        R19_PARSE_RC=$?
        set -e
        echo "$R19_PARSE"
        if [[ "$R19_PARSE_RC" -eq 0 ]]; then
            record_pass 19 "Both unit test runs (without and with SCHOLAR_CACHE_DIR) passed with >= 289 tests"
        else
            record_fail 19 "Row 19 unit tests failed or ran fewer than 289 tests"
        fi
    fi

    # ==================================================================
    # Row 20: Non-regression — Stage 02 runs 480-entry replay parity + m1-citation-bench --replay + M1 Row 18;
    #         milestone 2 & post-tool-rename M1 Row 18/20 checks deferred to Stage 05
    # ==================================================================
    if should_run_row 20; then
        echo "== [Row 20] Non-regression: m1-citation-bench.py --replay + 480-entry per-entry & 12-group exit parity vs baseline + M1 Row 18 =="
        set +e
        R20_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import glob, json, os, subprocess, sys

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
baseline_path = os.path.join(repo_root, "Scripts", "acceptance", "baselines", "m1-per-entry-v1.3.0.json")
bench_script = os.path.join(repo_root, "Scripts", "acceptance", "m1-citation-bench.py")
m1_acc_script = os.path.join(repo_root, "Scripts", "acceptance", "m1-acceptance.sh")
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
entries_dir = os.path.join(repo_root, "Benchmarks", "citations", "entries")

if not os.path.isfile(baseline_path):
    print(f"  FAIL [Row 20]: missing baseline file {baseline_path}")
    sys.exit(1)

r20_home = os.path.join(scratch, "r20-home")
os.makedirs(r20_home, exist_ok=True)
env = dict(os.environ)
env["HOME"] = r20_home
env["CFFIXED_USER_HOME"] = r20_home
env["SCHOLAR_CLI_BIN"] = cli_bin
env.pop("SCHOLAR_CACHE_DIR", None)
env.pop("SCHOLAR_REPORT_DIR", None)

failures = []

# 20a-1. m1-citation-bench.py --replay
bench_out = os.path.join(scratch, "r20-m1-bench.json")
p_bench = subprocess.run(
    [sys.executable, "-I", bench_script, "--replay", "--output", bench_out],
    env=env,
    capture_output=True,
    text=True,
)
if p_bench.returncode != 0:
    failures.append(f"m1-citation-bench.py --replay exited {p_bench.returncode}: {p_bench.stderr.strip()}")
else:
    bench_obj = json.loads(open(bench_out, encoding="utf-8").read())
    evaluated = (bench_obj.get("overall_metrics") or {}).get("total_entries")
    non_ins_ver = (bench_obj.get("hard_requirements") or {}).get("non_insertable_verified_count")
    hr_passed = (bench_obj.get("hard_requirements") or {}).get("passed")
    miss_cnt = bench_obj.get("replay_miss_count")
    if bench_obj.get("complete") is not True or evaluated != 480 or non_ins_ver != 0 or hr_passed is not True or miss_cnt != 0:
        failures.append(
            f"m1-citation-bench.py --replay metrics unexpected: complete={bench_obj.get('complete')}, "
            f"total_entries={evaluated}, non_insertable_verified={non_ins_ver}, hr_passed={hr_passed}, replay_miss={miss_cnt}"
        )
    else:
        print(
            f"  [Row 20a-1] PASS: m1-citation-bench.py --replay exit=0, complete=True, total_entries={evaluated}, "
            f"replay_miss={miss_cnt}, non_insertable_verified={non_ins_ver}"
        )

# 20a-2. Per-entry 480-item verdicts/reasons/insertable, 12-group exit codes vs baseline, and 206/206 VERIFIED carry record
per_home = os.path.join(scratch, "r20-per-entry-home")
os.makedirs(per_home, exist_ok=True)
per_env = dict(env)
per_env["HOME"] = per_home
per_env["CFFIXED_USER_HOME"] = per_home

cur_entries = {}
cur_exits = []
verified_total = 0
verified_with_record = 0
bib_files = sorted(glob.glob(os.path.join(entries_dir, "*.bib")))
if len(bib_files) != 12:
    failures.append(f"expected 12 benchmark .bib files in {entries_dir}, found {len(bib_files)}")

for bib_path in bib_files:
    grp = os.path.basename(bib_path)[:-4]
    p_vc = subprocess.run(
        [cli_bin, "verify-citations", bib_path, "--registry-replay", rec_dir, "--verbose", "--json", "--lang", "en"],
        env=per_env,
        capture_output=True,
        text=True,
    )
    cur_exits.append(f"{grp} exit={p_vc.returncode}")
    if p_vc.returncode == 2:
        failures.append(f"verify-citations exited 2 on {grp}: {p_vc.stderr.strip()}")
        continue
    try:
        payload = json.loads(p_vc.stdout)
    except Exception as exc:
        failures.append(f"invalid JSON from verify-citations on {grp}: {exc}")
        continue
    for it in payload.get("verdicts") or []:
        key = it.get("citeKey")
        cls = it.get("firewallClass")
        cur_entries[f"{grp}/{key}"] = {
            "verdict": cls,
            "reasons": sorted(it.get("reasons") or []),
            "insertable": it.get("insertable"),
        }
        if cls == "VERIFIED":
            verified_total += 1
            rec = it.get("record")
            if isinstance(rec, dict) and rec.get("source") and rec.get("title"):
                verified_with_record += 1
                ct = (rec.get("containerTitle") or "").lower()
                if "arxiv (cornell university)" in ct:
                    failures.append(f"{grp}/{key} carried OpenAlex arXiv repository as containerTitle: {rec.get('containerTitle')!r}")
            else:
                failures.append(f"VERIFIED entry {grp}/{key} missing valid record object: {rec!r}")

baseline = json.loads(open(baseline_path, encoding="utf-8").read())
base_entries = baseline.get("entries") or {}
base_exits = [x for x in (baseline.get("exits") or []) if x]

if len(base_entries) != 480 or len(cur_entries) != 480:
    failures.append(f"expected 480 entries (baseline={len(base_entries)}, current={len(cur_entries)})")

all_keys = sorted(set(base_entries) | set(cur_entries))
entry_diffs = []
for k in all_keys:
    if base_entries.get(k) != cur_entries.get(k):
        entry_diffs.append((k, base_entries.get(k), cur_entries.get(k)))

if entry_diffs:
    for k, old_v, new_v in entry_diffs[:20]:
        failures.append(f"entry diff {k}: baseline={old_v} vs current={new_v}")

if cur_exits != base_exits:
    failures.append(f"per-group exits mismatch: baseline={base_exits} vs current={cur_exits}")

if verified_total != 206 or verified_with_record != 206:
    failures.append(f"expected 206/206 VERIFIED with record, got {verified_with_record}/{verified_total}")

matched_entries = len(all_keys) - len(entry_diffs)
matched_exits = sum(1 for a, b in zip(cur_exits, base_exits) if a == b)
if not entry_diffs and cur_exits == base_exits and verified_with_record == 206:
    print(
        f"  [Row 20a-2] PASS: entries_matched={matched_entries}/480, group_exits_matched={matched_exits}/{len(base_exits)}, "
        f"verified_with_record={verified_with_record}/{verified_total}"
    )

# 20a-3. M1 Row 18 inline MCP verification check (S81)
m1_tmp = os.path.join(scratch, "r20-m1-tmp")
os.makedirs(m1_tmp, exist_ok=True)
m1_env = dict(env)
m1_env["TMPDIR"] = m1_tmp
p_m1 = subprocess.run([m1_acc_script, "--row", "18"], env=m1_env, capture_output=True, text=True)
if p_m1.returncode != 0 or "RESULT [Row 18]: PASS" not in p_m1.stdout:
    failures.append(f"m1-acceptance.sh --row 18 failed (exit={p_m1.returncode}): {p_m1.stdout[-400:]} {p_m1.stderr[-400:]}")
else:
    print("  [Row 20a-3] PASS: m1-acceptance.sh --row 18 exited 0 (RESULT [Row 18]: PASS)")

if failures:
    for msg in failures:
        print(f"  FAIL [Row 20]: {msg}")
    sys.exit(1)

print("  [Row 20b] 没跑: Scripts/test.sh milestone 2 & Stage 05 verify_citation/add_verified_bibtex Row 18/20 switch deferred to Stage 05")
sys.exit(2)
PY
)"
        R20_RC=$?
        set -e
        echo "$R20_OUT"
        if [[ "$R20_RC" -eq 0 ]]; then
            record_pass 20 "m1-citation-bench.py --replay, 480-entry parity, milestone 2, and M1 Row 18 all passed"
        elif [[ "$R20_RC" -eq 2 ]]; then
            record_skip 20 "Replay half passed (m1-citation-bench --replay, 480/480 entries & 12/12 group exits match baseline, 206/206 VERIFIED carry record, M1 Row 18 PASS); milestone 2 & Stage 05 tool-rename updates deferred to Stage 05 (没跑)"
        else
            record_fail 20 "Row 20 480-entry replay parity, m1-citation-bench.py --replay, or M1 Row 18 check failed"
        fi
    fi

    # ==================================================================
    # Rows 21–23: Deferred to Stage 07
    # ==================================================================
    for r in 21 22 23; do
        if should_run_row "$r"; then
            echo "== [Row $r] 没跑 — Scheduled for Stage 07 =="
            record_skip "$r" "Scheduled for Stage 07 — 没跑"
        fi
    done

    echo "========================================================================"
    echo "M3 MCP Acceptance Summary:"
    sed 's/^/  /' "$SUMMARY_FILE"
    echo "------------------------------------------------------------------------"
    echo "Passed: $PASSED_COUNT | Failed: $FAILED_COUNT | Skipped (没跑): $SKIPPED_COUNT"
    echo "========================================================================"
    echo "$FAILED_COUNT" > "$WORK/failed-count.txt"
    echo "$SKIPPED_COUNT" > "$WORK/skipped-count.txt"
} | tee "$REPORT_FILE"

if [[ -z "$CREATED_TEMP_REPORT_DIR" ]]; then
    echo "[m3-mcp] report written to $REPORT_FILE" >&2
fi

FINAL_FAILED="$(cat "$WORK/failed-count.txt")"
FINAL_SKIPPED="$(cat "$WORK/skipped-count.txt")"
if [[ "$FINAL_FAILED" -gt 0 ]]; then
    exit 1
fi
if [[ "$FINAL_SKIPPED" -gt 0 ]]; then
    exit 2
fi
exit 0
