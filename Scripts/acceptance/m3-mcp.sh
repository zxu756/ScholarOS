#!/usr/bin/env bash
#
# M3 acceptance verification script (`Scripts/acceptance/m3-mcp.sh`).
#
# Stage 01–05 scope (active rows):
#   - Row 1:  `tools/list` — default server exposes `verify_citation`, `add_verified_bibtex`, `check_manuscript`, `scholar_verify_bibliography`
#             (0 tools expose `registryReplayPath`/`demo`/`projectPath`); `--experimental-tools` adds the 5 frozen tools;
#             deleted (`scholar_cite_key`, `scholar_lsp_diagnostics`) & unenabled tools return JSON-RPC `-32602`
#   - Rows 2–9: `add_verified_bibtex` firewall rejection (`NOT_FOUND`, `DRIFT`, `UNVERIFIED`, `RETRACTED`, `year_mismatch`),
#             verified O_APPEND writes + read-back parity, registry-authoritative fields & `changed_fields`, exact 4-case deduplication,
#             offline rejection (`--offline` & `offline: true`), and network-denied cache-read bypass
#   - Row 10: Caller fake replay (`S74`) — all active tools reject `registryReplayPath` with structured `ERR_INVALID_ARGUMENT`,
#             deleted tools return `-32602`, `invented_2026` is never `VERIFIED`, and `.bib` is unchanged
#   - Row 11: `verify_citation` 480-entry per-entry `{cite_key, verdict, reasons, fields, insertable}` parity vs CLI `verify-citations --json`
#   - Row 12: Replay markers (`S75`) — `--registry-replay` server prints `[REPLAY]` on stderr, every tool result JSON has top-level
#             `"mode": "REPLAY"`, and `sources[].fetchedAt` / `firewallVerifiedAtUTC` carry the recording date `2026-11-16`
#   - Row 13: Write safety — 8 targets via MCP `add_verified_bibtex` (read-only, directory, missing parent, non-.bib, symlink, Latin-1, BIB001, CRLF)
#   - Row 14: Concurrency — 2 concurrent MCP server processes each appending 20 distinct `VERIFIED` entries (40 total, 0 errors)
#   - Row 15: `check_manuscript` (`offline: true`) across all 11 benchmark manuscripts — default summary `counts` match CLI `--offline --json`,
#             `detail: "full"` matches CLI `--json` byte-for-byte, and summary byte sizes are recorded
#   - Row 16: Legacy tools (Settled #1c) — deleted tools absent & return `-32602`; `scholar_verify_bibliography` trimmed to batch read-only
#             (`bibtex`, `offline`, `lang`) and verified to share firewall, replay, and SQLite cache with `verify_citation` (catches mutation h)
#   - Row 17: Protocol (`S78`) — `ping` returns `{}`, `serverInfo.version` dynamically matches `scholaros version`,
#             malformed JSON returns `-32700`, unknown method returns `-32601`
#   - Row 19: Unit tests (`S79`) — `swift test --no-parallel` passes (>= 289 tests) both without and with `SCHOLAR_CACHE_DIR`
#   - Row 20: Non-regression (`S77` / `S81`) — `m1-citation-bench.py --replay`, 480-entry per-entry & 12-group exit parity vs baseline,
#             206/206 `VERIFIED` carrying `record`, updated M1 Row 18/20, and M2 acceptance (`m2-acceptance.sh` + `hard-inputs.sh`)
#
# Remaining rows (Row 18 in Stage 06, Rows 21–23 in Stage 07) print `没跑`.
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
    # Row 1: tools/list — final tool table (default 4 tools, --experimental-tools +5 frozen tools, deleted tools -> -32602)
    # ==================================================================
    if should_run_row 1; then
        echo "== [Row 1] tools/list: default 4 tools, --experimental-tools +5 frozen tools, 0 registryReplayPath, deleted tools -> -32602 =="
        set +e
        R1_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" <<'PY'
import json, os, subprocess, sys

repo_root, cli_bin, sbox_home = sys.argv[1], sys.argv[2], sys.argv[3]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")

env = dict(os.environ)
env["HOME"] = sbox_home
env["CFFIXED_USER_HOME"] = sbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

expected_default = {
    "verify_citation": (["bibtex", "lang", "offline"], ["bibtex"]),
    "add_verified_bibtex": (["bib_file", "bibtex", "lang", "offline"], ["bib_file", "bibtex"]),
    "check_manuscript": (["bib_file", "detail", "lang", "no_verify", "offline", "path"], ["path"]),
    "scholar_verify_bibliography": (["bibtex", "lang", "offline"], ["bibtex"]),
}
frozen_tools = {
    "scholar_search_provenance",
    "scholar_prisma_agreement",
    "scholar_editorial_audit",
    "scholar_track_changes_diff",
    "scholar_citation_gaps",
}
deleted_tools = ["scholar_cite_key", "scholar_lsp_diagnostics"]

# 1. Default server: exactly 4 tools, clean snake_case schemas, 0 registryReplayPath/demo/projectPath,
#    and deleted + frozen + unknown tools all return JSON-RPC -32602
default_reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "m3-mcp", "version": "1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
]
rejected_on_default = deleted_tools + sorted(frozen_tools) + ["scholar_nonexistent_tool"]
for idx, tname in enumerate(rejected_on_default, start=10):
    default_reqs.append({"jsonrpc": "2.0", "id": idx, "method": "tools/call", "params": {"name": tname, "arguments": {}}})

proc = subprocess.run(
    [cli_bin, "mcp", "--registry-replay", rec_dir],
    input="\n".join(json.dumps(r) for r in default_reqs) + "\n",
    env=env,
    capture_output=True,
    text=True,
)
if proc.returncode != 0:
    print(f"  FAIL [Row 1]: mcp exited {proc.returncode}: {proc.stderr}")
    sys.exit(1)

resps = {obj.get("id"): obj for obj in (json.loads(ln) for ln in proc.stdout.splitlines() if ln.strip())}
tools = ((resps.get(2) or {}).get("result") or {}).get("tools") or []
names = [t.get("name", "<unnamed>") for t in tools]
if len(tools) != 4 or set(names) != set(expected_default):
    print(f"  FAIL [Row 1]: expected 4 default tools {sorted(expected_default)}, got {len(tools)}: {names}")
    sys.exit(1)

by_name = {t["name"]: t for t in tools}
for tname, (want_props, want_req) in expected_default.items():
    tdef = by_name[tname]
    blob = json.dumps(tdef, ensure_ascii=False)
    if "registryReplayPath" in blob:
        print(f"  FAIL [Row 1]: {tname} exposes registryReplayPath: {tdef}")
        sys.exit(1)
    schema = tdef.get("inputSchema") or {}
    props = schema.get("properties") or {}
    for forbidden in ("registryReplayPath", "demo", "projectPath"):
        if forbidden in props:
            print(f"  FAIL [Row 1]: {tname} exposes forbidden property {forbidden!r}: {props}")
            sys.exit(1)
    if sorted(props.keys()) != want_props:
        print(f"  FAIL [Row 1]: {tname} properties={sorted(props.keys())} != expected {want_props}")
        sys.exit(1)
    if sorted(schema.get("required") or []) != want_req:
        print(f"  FAIL [Row 1]: {tname} required={schema.get('required')} != expected {want_req}")
        sys.exit(1)

for idx, tname in enumerate(rejected_on_default, start=10):
    err = (resps.get(idx) or {}).get("error") or {}
    if err.get("code") != -32602:
        print(f"  FAIL [Row 1]: calling {tname!r} on default server expected JSON-RPC -32602, got {resps.get(idx)}")
        sys.exit(1)

print(f"  [Row 1a] PASS: default tools/list has exact 4 tools {names}; deleted & frozen tools return -32602")

# 2. --experimental-tools server: 4 default + 5 frozen = 9 tools, 0 registryReplayPath, deleted tools still -32602
exp_reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "scholar_track_changes_diff", "arguments": {"original": "Old.", "revised": "New."}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "scholar_cite_key", "arguments": {"citeKey": "x"}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "scholar_lsp_diagnostics", "arguments": {"path": "x.tex"}}},
]
proc_exp = subprocess.run(
    [cli_bin, "mcp", "--registry-replay", rec_dir, "--experimental-tools"],
    input="\n".join(json.dumps(r) for r in exp_reqs) + "\n",
    env=env,
    capture_output=True,
    text=True,
)
if proc_exp.returncode != 0:
    print(f"  FAIL [Row 1]: mcp --experimental-tools exited {proc_exp.returncode}: {proc_exp.stderr}")
    sys.exit(1)

exp_resps = {obj.get("id"): obj for obj in (json.loads(ln) for ln in proc_exp.stdout.splitlines() if ln.strip())}
exp_tools = ((exp_resps.get(1) or {}).get("result") or {}).get("tools") or []
exp_names = [t.get("name", "<unnamed>") for t in exp_tools]
want_exp_set = set(expected_default) | frozen_tools
if len(exp_tools) != 9 or set(exp_names) != want_exp_set:
    print(f"  FAIL [Row 1]: expected 9 tools with --experimental-tools, got {len(exp_tools)}: {exp_names}")
    sys.exit(1)
for t in exp_tools:
    if "registryReplayPath" in json.dumps(t, ensure_ascii=False):
        print(f"  FAIL [Row 1]: experimental tool {t.get('name')} exposes registryReplayPath")
        sys.exit(1)
if ((exp_resps.get(2) or {}).get("result") or {}).get("isError") is not False:
    print(f"  FAIL [Row 1]: scholar_track_changes_diff failed under --experimental-tools: {exp_resps.get(2)}")
    sys.exit(1)
for rid, dname in [(3, "scholar_cite_key"), (4, "scholar_lsp_diagnostics")]:
    if ((exp_resps.get(rid) or {}).get("error") or {}).get("code") != -32602:
        print(f"  FAIL [Row 1]: deleted {dname} did not return -32602 under --experimental-tools: {exp_resps.get(rid)}")
        sys.exit(1)

for lang in ("en", "zh"):
    p_help = subprocess.run([cli_bin, "--help", "--lang", lang], env=env, capture_output=True, text=True)
    if p_help.returncode != 0 or "--experimental-tools" not in p_help.stdout:
        print(f"  FAIL [Row 1]: --help --lang {lang} missing --experimental-tools")
        sys.exit(1)

print(f"  [Row 1b] PASS: --experimental-tools adds 5 frozen tools (total 9={exp_names}), --help EN/ZH documented, deleted tools still -32602")
sys.exit(0)
PY
)"
        R1_RC=$?
        set -e
        echo "$R1_OUT"
        if [[ "$R1_RC" -eq 0 ]]; then
            record_pass 1 "tools/list exposes exact 4 default tools (+5 frozen under --experimental-tools), 0 tools carry registryReplayPath, and deleted tools return -32602"
        else
            record_fail 1 "Row 1 tools/list, --experimental-tools, or deleted-tool -32602 check failed"
        fi
    fi

    # ==================================================================
    # Row 2: add_verified_bibtex with fab_codex_003 (fabricated, unregistered DOI)
    # ==================================================================
    if should_run_row 2; then
        echo "== [Row 2] add_verified_bibtex on fab_codex_003: isError=true, ERR_UNVERIFIED_CITATION, NOT_FOUND, doi_not_registered, file unchanged =="
        set +e
        R2_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import hashlib, json, os, re, subprocess, sys

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
env = dict(os.environ, HOME=sbox_home, CFFIXED_USER_HOME=sbox_home)
env.pop("SCHOLAR_CACHE_DIR", None)

def extract_entry(group: str, key: str) -> str:
    p = os.path.join(repo_root, "Benchmarks", "citations", "entries", f"{group}.bib")
    m = re.search(rf"(@\w+\{{{re.escape(key)},.*?\n\}})", open(p, encoding="utf-8").read(), flags=re.S)
    if not m:
        raise RuntimeError(f"Missing {group}/{key}")
    return m.group(1) + "\n"

def file_sig(path: str):
    raw = open(path, "rb").read()
    st = os.stat(path)
    return (hashlib.sha256(raw).hexdigest(), st.st_size, st.st_mtime_ns)

target_bib = os.path.join(scratch, "row2-refs.bib")
open(target_bib, "wb").write(b"% row2 sentinel\n")
sig_before = file_sig(target_bib)

fab_003 = extract_entry("fabricated_model", "fab_codex_003")
reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": fab_003}}},
]
p = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input="\n".join(json.dumps(r) for r in reqs) + "\n", env=env, capture_output=True, text=True)
if p.returncode != 0:
    print(f"  FAIL [Row 2]: mcp exited {p.returncode}: {p.stderr}")
    sys.exit(1)

resp = json.loads(p.stdout.strip())["result"]
if resp.get("isError") is not True:
    print(f"  FAIL [Row 2]: expected isError=True, got {resp}")
    sys.exit(1)
obj = json.loads(resp["content"][0]["text"])
if (
    obj.get("error_code") != "ERR_UNVERIFIED_CITATION"
    or obj.get("verdict") != "NOT_FOUND"
    or "doi_not_registered" not in (obj.get("reasons") or [])
    or obj.get("cite_key") != "fab_codex_003"
    or obj.get("action") != f"未改动 {os.path.basename(target_bib)}"
):
    print(f"  FAIL [Row 2]: unexpected error payload: {obj}")
    sys.exit(1)

sig_after = file_sig(target_bib)
if sig_before != sig_after:
    print(f"  FAIL [Row 2]: target .bib changed (before={sig_before}, after={sig_after})")
    sys.exit(1)

print(f"  [Row 2] PASS: fab_codex_003 rejected with ERR_UNVERIFIED_CITATION (verdict=NOT_FOUND, reasons={obj.get('reasons')}), action={obj.get('action')!r}, file unchanged")
PY
)"
        R2_RC=$?
        set -e
        echo "$R2_OUT"
        if [[ "$R2_RC" -eq 0 ]]; then
            record_pass 2 "add_verified_bibtex rejects fab_codex_003 with ERR_UNVERIFIED_CITATION (NOT_FOUND, doi_not_registered) and leaves .bib unchanged"
        else
            record_fail 2 "Row 2 fab_codex_003 rejection check failed"
        fi
    fi

    # ==================================================================
    # Row 3: add_verified_bibtex on fab_codex_001 (DRIFT), fab_codex_002 (UNVERIFIED), retracted_001 (RETRACTED)
    # ==================================================================
    if should_run_row 3; then
        echo "== [Row 3] add_verified_bibtex on fab_codex_001 (DRIFT), fab_codex_002 (UNVERIFIED), retracted_001 (RETRACTED) =="
        set +e
        R3_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import hashlib, json, os, re, subprocess, sys

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
env = dict(os.environ, HOME=sbox_home, CFFIXED_USER_HOME=sbox_home)
env.pop("SCHOLAR_CACHE_DIR", None)

def extract_entry(group: str, key: str) -> str:
    p = os.path.join(repo_root, "Benchmarks", "citations", "entries", f"{group}.bib")
    m = re.search(rf"(@\w+\{{{re.escape(key)},.*?\n\}})", open(p, encoding="utf-8").read(), flags=re.S)
    if not m:
        raise RuntimeError(f"Missing {group}/{key}")
    return m.group(1) + "\n"

def file_sig(path: str):
    raw = open(path, "rb").read()
    st = os.stat(path)
    return (hashlib.sha256(raw).hexdigest(), st.st_size, st.st_mtime_ns)

target_bib = os.path.join(scratch, "row3-refs.bib")
open(target_bib, "wb").write(b"% row3 sentinel\n")
sig_before = file_sig(target_bib)

fab_001 = extract_entry("fabricated_model", "fab_codex_001")
fab_002 = extract_entry("fabricated_model", "fab_codex_002")
ret_001 = extract_entry("retracted", "retracted_001")

reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": fab_001}}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": fab_002}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": ret_001}}},
]
p = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input="\n".join(json.dumps(r) for r in reqs) + "\n", env=env, capture_output=True, text=True)
if p.returncode != 0:
    print(f"  FAIL [Row 3]: mcp exited {p.returncode}: {p.stderr}")
    sys.exit(1)

resps = {obj["id"]: obj["result"] for obj in (json.loads(ln) for ln in p.stdout.splitlines() if ln.strip())}
for rid in (1, 2, 3):
    if resps[rid].get("isError") is not True:
        print(f"  FAIL [Row 3]: call {rid} expected isError=True, got {resps[rid]}")
        sys.exit(1)

o1 = json.loads(resps[1]["content"][0]["text"])
fields1 = {f.get("field"): f for f in (o1.get("fields") or [])}
if (
    o1.get("error_code") != "ERR_UNVERIFIED_CITATION"
    or o1.get("verdict") != "DRIFT"
    or not (fields1.get("title") or {}).get("remoteValue")
    or not (fields1.get("firstAuthor") or {}).get("remoteValue")
    or o1.get("action") != f"未改动 {os.path.basename(target_bib)}"
):
    print(f"  FAIL [Row 3]: fab_codex_001 unexpected payload: {o1}")
    sys.exit(1)

o2 = json.loads(resps[2]["content"][0]["text"])
if (
    o2.get("error_code") != "ERR_UNVERIFIED_CITATION"
    or o2.get("verdict") != "UNVERIFIED"
    or "no_match_in_search" not in (o2.get("reasons") or [])
    or o2.get("action") != f"未改动 {os.path.basename(target_bib)}"
):
    print(f"  FAIL [Row 3]: fab_codex_002 unexpected payload: {o2}")
    sys.exit(1)

o3 = json.loads(resps[3]["content"][0]["text"])
if (
    o3.get("error_code") != "ERR_UNVERIFIED_CITATION"
    or o3.get("verdict") != "RETRACTED"
    or o3.get("action") != f"未改动 {os.path.basename(target_bib)}"
):
    print(f"  FAIL [Row 3]: retracted_001 unexpected payload: {o3}")
    sys.exit(1)

if file_sig(target_bib) != sig_before:
    print("  FAIL [Row 3]: target .bib modified after rejected writes")
    sys.exit(1)

print("  [Row 3] PASS: fab_codex_001 (DRIFT w/ remote title & firstAuthor), fab_codex_002 (UNVERIFIED no_match_in_search), retracted_001 (RETRACTED) all rejected; file unchanged")
PY
)"
        R3_RC=$?
        set -e
        echo "$R3_OUT"
        if [[ "$R3_RC" -eq 0 ]]; then
            record_pass 3 "add_verified_bibtex rejects DRIFT (fab_codex_001), UNVERIFIED (fab_codex_002), and RETRACTED (retracted_001) without modifying .bib"
        else
            record_fail 3 "Row 3 DRIFT / UNVERIFIED / RETRACTED rejection check failed"
        fi
    fi

    # ==================================================================
    # Row 4: mut_year3_001 (local 2019, Crossref 2022)
    # ==================================================================
    if should_run_row 4; then
        echo "== [Row 4] add_verified_bibtex on mut_year3_001 (local 2019 vs Crossref 2022) =="
        set +e
        R4_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import hashlib, json, os, re, subprocess, sys

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
env = dict(os.environ, HOME=sbox_home, CFFIXED_USER_HOME=sbox_home)
env.pop("SCHOLAR_CACHE_DIR", None)

p_bib = os.path.join(repo_root, "Benchmarks", "citations", "entries", "mut_year3.bib")
m = re.search(r"(@\w+\{mut_year3_001,.*?\n\})", open(p_bib, encoding="utf-8").read(), flags=re.S)
mut_bib = m.group(1) + "\n"

def file_sig(path: str):
    raw = open(path, "rb").read()
    st = os.stat(path)
    return (hashlib.sha256(raw).hexdigest(), st.st_size, st.st_mtime_ns)

target_bib = os.path.join(scratch, "row4-refs.bib")
open(target_bib, "wb").write(b"% row4 sentinel\n")
sig_before = file_sig(target_bib)

req = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": mut_bib}}}
p = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input=json.dumps(req) + "\n", env=env, capture_output=True, text=True)
if p.returncode != 0:
    print(f"  FAIL [Row 4]: mcp exited {p.returncode}: {p.stderr}")
    sys.exit(1)

res = json.loads(p.stdout.strip())["result"]
if res.get("isError") is not True:
    print(f"  FAIL [Row 4]: expected isError=True, got {res}")
    sys.exit(1)

obj = json.loads(res["content"][0]["text"])
year_fields = [f for f in (obj.get("fields") or []) if f.get("field") == "year"]
if (
    obj.get("error_code") != "ERR_UNVERIFIED_CITATION"
    or obj.get("verdict") != "DRIFT"
    or not year_fields
    or year_fields[0].get("remoteValue") != "2022"
    or year_fields[0].get("source") != "Crossref"
    or "2022" not in (obj.get("reason") or "")
    or obj.get("action") != f"未改动 {os.path.basename(target_bib)}"
):
    print(f"  FAIL [Row 4]: unexpected payload: {obj}")
    sys.exit(1)

if file_sig(target_bib) != sig_before:
    print("  FAIL [Row 4]: target .bib modified")
    sys.exit(1)

print("  [Row 4] PASS: mut_year3_001 rejected with DRIFT, fields[year]={remoteValue:'2022', source:'Crossref'}, reason mentions 2022, file unchanged")
PY
)"
        R4_RC=$?
        set -e
        echo "$R4_OUT"
        if [[ "$R4_RC" -eq 0 ]]; then
            record_pass 4 "add_verified_bibtex rejects mut_year3_001 with Crossref remoteValue='2022' in fields and reason, leaving .bib unchanged"
        else
            record_fail 4 "Row 4 mut_year3_001 year mismatch check failed"
        fi
    fi

    # ==================================================================
    # Row 5: Append real_clean_001 & audit_001 into empty .bib and CRLF copy of real_human.bib; read back via ScholarOS
    # ==================================================================
    if should_run_row 5; then
        echo "== [Row 5] Append real_clean_001 & audit_001 into empty .bib and CRLF real_human.bib copy; verify prefix, CRLF, and read-back parity =="
        set +e
        R5_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import json, os, re, subprocess, sys

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
env = dict(os.environ, HOME=sbox_home, CFFIXED_USER_HOME=sbox_home)
env.pop("SCHOLAR_CACHE_DIR", None)

def extract_entry(group: str, key: str) -> str:
    p = os.path.join(repo_root, "Benchmarks", "citations", "entries", f"{group}.bib")
    m = re.search(rf"(@\w+\{{{re.escape(key)},.*?\n\}})", open(p, encoding="utf-8").read(), flags=re.S)
    if not m:
        raise RuntimeError(f"Missing {group}/{key}")
    return m.group(1) + "\n"

rc001 = extract_entry("real_clean", "real_clean_001")
au001 = extract_entry("audit_manual", "audit_001")

empty_bib = os.path.join(scratch, "row5-empty.bib")
open(empty_bib, "wb").write(b"")

rh_src = open(os.path.join(repo_root, "Benchmarks", "citations", "entries", "real_human.bib"), "rb").read()
rh_crlf_bytes = rh_src.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
rh_copy = os.path.join(scratch, "row5-real_human-crlf.bib")
open(rh_copy, "wb").write(rh_crlf_bytes)

for label, target_path, expected_initial_count, is_crlf in [
    ("empty", empty_bib, 0, False),
    ("real_human_crlf", rh_copy, 100, True),
]:
    orig_bytes = open(target_path, "rb").read()
    orig_ino = os.stat(target_path).st_ino

    reqs = [
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_path, "bibtex": rc001}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_path, "bibtex": au001}}},
    ]
    p = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input="\n".join(json.dumps(r) for r in reqs) + "\n", env=env, capture_output=True, text=True)
    if p.returncode != 0:
        print(f"  FAIL [Row 5/{label}]: mcp exited {p.returncode}: {p.stderr}")
        sys.exit(1)

    resps = {obj["id"]: obj["result"] for obj in (json.loads(ln) for ln in p.stdout.splitlines() if ln.strip())}
    records_by_key = {}
    for rid, exp_key in [(1, "real_clean_001"), (2, "audit_001")]:
        res = resps[rid]
        if res.get("isError") is not False:
            print(f"  FAIL [Row 5/{label}]: expected isError=False on {exp_key}, got {res}")
            sys.exit(1)
        obj = json.loads(res["content"][0]["text"])
        if obj.get("status") != "APPENDED_VERIFIED" or obj.get("cite_key") != exp_key or obj.get("mode") != "REPLAY":
            print(f"  FAIL [Row 5/{label}]: unexpected APPENDED_VERIFIED payload on {exp_key}: {obj}")
            sys.exit(1)
        rec = obj.get("record")
        if not isinstance(rec, dict):
            print(f"  FAIL [Row 5/{label}]: missing record in APPENDED_VERIFIED response on {exp_key}: {obj}")
            sys.exit(1)
        records_by_key[exp_key] = rec

    after_bytes = open(target_path, "rb").read()
    after_ino = os.stat(target_path).st_ino
    if after_ino != orig_ino:
        print(f"  FAIL [Row 5/{label}]: inode changed ({orig_ino} -> {after_ino})")
        sys.exit(1)
    if not after_bytes.startswith(orig_bytes) or len(after_bytes) <= len(orig_bytes):
        print(f"  FAIL [Row 5/{label}]: original bytes are not a strict prefix of updated file")
        sys.exit(1)

    if is_crlf:
        appended_slice = after_bytes[len(orig_bytes):]
        lf_indices = [i for i, b in enumerate(appended_slice) if b == 0x0A]
        if not lf_indices or any(i == 0 or appended_slice[i - 1] != 0x0D for i in lf_indices):
            print(f"  FAIL [Row 5/{label}]: appended slice in CRLF file contains bare LF")
            sys.exit(1)

    # Read back via ScholarOS BibTeX reader (verify-citations --offline --json)
    p_rb = subprocess.run([cli_bin, "verify-citations", target_path, "--offline", "--json", "--lang", "en"], env=env, capture_output=True, text=True)
    if p_rb.returncode not in (0, 1, 3):
        print(f"  FAIL [Row 5/{label}]: verify-citations read-back exited {p_rb.returncode}: {p_rb.stderr}")
        sys.exit(1)
    rb_obj = json.loads(p_rb.stdout)
    if (rb_obj.get("unverifiedByReason") or {}).get("parse_error", 0) != 0 or "[BIB001]" in p_rb.stderr:
        print(f"  FAIL [Row 5/{label}]: BibTeX parse errors after append: stderr={p_rb.stderr}")
        sys.exit(1)
    verdicts = rb_obj.get("verdicts") or []
    if len(verdicts) != expected_initial_count + 2:
        print(f"  FAIL [Row 5/{label}]: expected {expected_initial_count + 2} entries, got {len(verdicts)}")
        sys.exit(1)

    by_key = {v["citeKey"]: v["auditedEntry"] for v in verdicts}
    for key in ("real_clean_001", "audit_001"):
        if key not in by_key:
            print(f"  FAIL [Row 5/{label}]: missing {key} in read-back entries")
            sys.exit(1)
        ae = by_key[key]
        rec = records_by_key[key]
        rec_years = {
            d["year"]
            for k in ("published-print", "published-online", "issued")
            for d in [rec.get("publicationDates", {}).get(k)]
            if isinstance(d, dict) and "year" in d
        }
        rec_authors = [(a.get("givenName") or "", a.get("familyName") or a.get("name") or "") for a in (rec.get("authors") or [])]
        ae_authors = [(a.get("givenName") or "", a.get("familyName") or "") for a in (ae.get("authors") or [])]
        norm_pages = lambda s: (s or "").replace("--", "-")
        if (
            ae.get("title") != rec.get("title")
            or ae.get("year") not in rec_years
            or ae_authors != rec_authors
            or ae.get("venue") != (rec.get("containerTitle") or "")
            or ae.get("volume") != rec.get("volume")
            or ae.get("issue") != rec.get("issue")
            or norm_pages(ae.get("pages")) != norm_pages(rec.get("pages"))
            or (ae.get("doi") or "").lower() != (rec.get("doi") or "").lower()
        ):
            print(f"  FAIL [Row 5/{label}]: read-back mismatch on {key}:\n    auditedEntry={ae}\n    record={rec}")
            sys.exit(1)

print("  [Row 5] PASS: empty.bib (2 entries) & CRLF real_human.bib (102 entries) appended via O_APPEND; prefix, inode, CRLF, and read-back fields match record")
PY
)"
        R5_RC=$?
        set -e
        echo "$R5_OUT"
        if [[ "$R5_RC" -eq 0 ]]; then
            record_pass 5 "real_clean_001 and audit_001 appended to empty .bib and CRLF real_human.bib copy with exact prefix, CRLF, and read-back parity"
        else
            record_fail 5 "Row 5 verified append and read-back check failed"
        fi
    fi

    # ==================================================================
    # Row 6: Written fields come from registry record (audit_020, real_human_012, real_typo_017, real_human_049)
    # ==================================================================
    if should_run_row 6; then
        echo "== [Row 6] Registry-authoritative fields & changed_fields on audit_020, real_human_012, real_typo_017, real_human_049 =="
        set +e
        R6_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import json, os, re, subprocess, sys

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
env = dict(os.environ, HOME=sbox_home, CFFIXED_USER_HOME=sbox_home)
env.pop("SCHOLAR_CACHE_DIR", None)

def extract_entry(group: str, key: str) -> str:
    p = os.path.join(repo_root, "Benchmarks", "citations", "entries", f"{group}.bib")
    m = re.search(rf"(@\w+\{{{re.escape(key)},.*?\n\}})", open(p, encoding="utf-8").read(), flags=re.S)
    if not m:
        raise RuntimeError(f"Missing {group}/{key}")
    return m.group(1) + "\n"

au020 = extract_entry("audit_manual", "audit_020")
rh012 = extract_entry("real_human", "real_human_012")
rt017 = extract_entry("real_typo", "real_typo_017")
rh049 = extract_entry("real_human", "real_human_049")

target_bib = os.path.join(scratch, "row6.bib")
reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": au020}}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rh012}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rt017}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rh049}}},
]
p = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input="\n".join(json.dumps(r) for r in reqs) + "\n", env=env, capture_output=True, text=True)
if p.returncode != 0:
    print(f"  FAIL [Row 6]: mcp exited {p.returncode}: {p.stderr}")
    sys.exit(1)

objs = {}
for ln in p.stdout.splitlines():
    if not ln.strip():
        continue
    env_obj = json.loads(ln)
    res = env_obj["result"]
    if res.get("isError") is not False:
        print(f"  FAIL [Row 6]: id={env_obj['id']} failed: {res}")
        sys.exit(1)
    objs[env_obj["id"]] = json.loads(res["content"][0]["text"])

# 1. audit_020: Science -> Nature
o1 = objs[1]
cf1 = {c["field"]: c for c in o1.get("changed_fields") or []}
if "{Nature}" not in o1["written_bibtex"] or "{Science}" in o1["written_bibtex"] or cf1.get("journal", {}).get("written") != "Nature":
    print(f"  FAIL [Row 6]: audit_020 unexpected output: {o1}")
    sys.exit(1)

# 2. real_human_012: Ind. Eng. Chem. -> Industrial \& Engineering Chemistry Research
o2 = objs[2]
cf2 = {c["field"]: c for c in o2.get("changed_fields") or []}
if r"Industrial \& Engineering Chemistry Research" not in o2["written_bibtex"] or cf2.get("journal", {}).get("written") != "Industrial & Engineering Chemistry Research":
    print(f"  FAIL [Row 6]: real_human_012 unexpected output: {o2}")
    sys.exit(1)

# 3. real_typo_017: uppercase DOI -> canonical DOI from record
o3 = objs[3]
cf3 = {c["field"]: c for c in o3.get("changed_fields") or []}
rec_doi = o3["record"]["doi"]
if f"{{{rec_doi}}}" not in o3["written_bibtex"] or cf3.get("doi", {}).get("written") != rec_doi or cf3.get("doi", {}).get("given") == rec_doi:
    print(f"  FAIL [Row 6]: real_typo_017 unexpected output: {o3}")
    sys.exit(1)

# 4. real_human_049: OpenAlex arXiv preprint -> @misc with eprint & archivePrefix, NO journal/booktitle, NO "Cornell"
o4 = objs[4]
wb4 = o4["written_bibtex"]
cf4 = {c["field"]: c for c in o4.get("changed_fields") or []}
if (
    not wb4.startswith("@misc{real_human_049,")
    or "eprint" not in wb4
    or "archivePrefix" not in wb4
    or "journal" in wb4
    or "booktitle" in wb4
    or "cornell" in wb4.lower()
    or not o4.get("changed_fields")
):
    print(f"  FAIL [Row 6]: real_human_049 unexpected output: {o4}")
    sys.exit(1)

# Verify BibTeX read-back has 0 parse errors and unescapes \& cleanly
p_rb = subprocess.run([cli_bin, "verify-citations", target_bib, "--offline", "--json", "--lang", "en"], env=env, capture_output=True, text=True)
rb = json.loads(p_rb.stdout)
if (rb.get("unverifiedByReason") or {}).get("parse_error", 0) != 0 or len(rb.get("verdicts") or []) != 4:
    print(f"  FAIL [Row 6]: read-back parse error or wrong count: {p_rb.stderr}")
    sys.exit(1)
by_k = {v["citeKey"]: v["auditedEntry"] for v in rb["verdicts"]}
if (
    by_k["audit_020"]["venue"] != "Nature"
    or by_k["real_human_012"]["venue"] != "Industrial & Engineering Chemistry Research"
    or by_k["real_typo_017"]["doi"] != rec_doi
    or by_k["real_human_049"]["venue"] != ""
):
    print(f"  FAIL [Row 6]: read-back entries unexpected: {by_k}")
    sys.exit(1)

print("  [Row 6] PASS: audit_020 (Nature), real_human_012 (Industrial \\& Engineering Chemistry Research), real_typo_017 (canonical DOI), real_human_049 (@misc arXiv, no journal) all verified with changed_fields")
PY
)"
        R6_RC=$?
        set -e
        echo "$R6_OUT"
        if [[ "$R6_RC" -eq 0 ]]; then
            record_pass 6 "Written BibTeX fields come from registry record with HTML decoding, BibTeX escaping, and changed_fields"
        else
            record_fail 6 "Row 6 registry-authoritative fields check failed"
        fi
    fi

    # ==================================================================
    # Row 7: Deduplication — 4 cases (same entry, different key on same paper, existing key on different paper, case-only key difference)
    # ==================================================================
    if should_run_row 7; then
        echo "== [Row 7] Deduplication (4 cases): SKIPPED_DUPLICATE (isError=false), ERR_CITE_KEY_CONFLICT (isError=true), case-insensitive key =="
        set +e
        R7_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import hashlib, json, os, re, subprocess, sys

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
env = dict(os.environ, HOME=sbox_home, CFFIXED_USER_HOME=sbox_home)
env.pop("SCHOLAR_CACHE_DIR", None)

def extract_entry(group: str, key: str) -> str:
    p = os.path.join(repo_root, "Benchmarks", "citations", "entries", f"{group}.bib")
    m = re.search(rf"(@\w+\{{{re.escape(key)},.*?\n\}})", open(p, encoding="utf-8").read(), flags=re.S)
    if not m:
        raise RuntimeError(f"Missing {group}/{key}")
    return m.group(1) + "\n"

def rename_key(bib: str, old_key: str, new_key: str) -> str:
    return re.sub(rf"^(@\w+\{{){re.escape(old_key)},", rf"\g<1>{new_key},", bib, count=1)

def file_sig(path: str):
    raw = open(path, "rb").read()
    st = os.stat(path)
    return (hashlib.sha256(raw).hexdigest(), st.st_size, st.st_mtime_ns)

rc001 = extract_entry("real_clean", "real_clean_001")
au001 = extract_entry("audit_manual", "audit_001")
au024 = extract_entry("audit_manual", "audit_024")
au026 = extract_entry("audit_manual", "audit_026")
rh007 = extract_entry("real_human", "real_human_007")

target_bib = os.path.join(scratch, "row7.bib")
# Seed an identifierless copy of real_clean_001 title+year+firstAuthor in tya_bib and a PMID-only entry in pmid_bib
# (since add_verified_bibtex enriches audit_026 with PubMed DOI on write, seeding raw audit_026 tests pure PMID matching)
tya_bib = os.path.join(scratch, "row7-tya.bib")
open(tya_bib, "w", encoding="utf-8").write(
    "@article{seeded_tya,\n  author = {Yu, J. and Ferguson, F.J.},\n  title = {Maximum likelihood estimation for failure analysis [IC yield]},\n  year = {1998}\n}\n"
)
tya_before = file_sig(tya_bib)

pmid_bib = os.path.join(scratch, "row7-pmid.bib")
open(pmid_bib, "w", encoding="utf-8").write(au026)
pmid_before = file_sig(pmid_bib)

# First append real_clean_001 and audit_024 (arXiv-only) into target_bib
seed_reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rc001}}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": au024}}},
]
p_seed = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input="\n".join(json.dumps(r) for r in seed_reqs) + "\n", env=env, capture_output=True, text=True)
if p_seed.returncode != 0:
    print(f"  FAIL [Row 7]: seed mcp exited {p_seed.returncode}: {p_seed.stderr}")
    sys.exit(1)

sig_seeded = file_sig(target_bib)

allowed_matched_on = {"cite_key", "doi", "arxiv", "pmid", "title_year_first_author"}

reqs = [
    # Case 1: exact same entry again
    {"jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rc001}}},
    # Case 2: same paper with different key (DOI, arXiv, PMID, and title+year+firstAuthor)
    {"jsonrpc": "2.0", "id": 11, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rename_key(rc001, "real_clean_001", "alt_doi_key")}}},
    {"jsonrpc": "2.0", "id": 12, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rename_key(au024, "audit_024", "alt_arxiv_key")}}},
    {"jsonrpc": "2.0", "id": 13, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": pmid_bib, "bibtex": rename_key(au026, "audit_026", "alt_pmid_key")}}},
    {"jsonrpc": "2.0", "id": 14, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": tya_bib, "bibtex": rename_key(rc001, "real_clean_001", "alt_tya_key")}}},
    # Case 3: existing key used on a DIFFERENT real paper -> ERR_CITE_KEY_CONFLICT
    {"jsonrpc": "2.0", "id": 15, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rename_key(au001, "audit_001", "real_clean_001")}}},
    # Case 4a: key differing only in case on SAME paper -> SKIPPED_DUPLICATE (cite_key)
    {"jsonrpc": "2.0", "id": 16, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rename_key(rc001, "real_clean_001", "REAL_CLEAN_001")}}},
    # Case 4b: key differing only in case on DIFFERENT paper -> ERR_CITE_KEY_CONFLICT
    {"jsonrpc": "2.0", "id": 17, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rename_key(au001, "audit_001", "REAL_CLEAN_001")}}},
]
p = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input="\n".join(json.dumps(r) for r in reqs) + "\n", env=env, capture_output=True, text=True)
if p.returncode != 0:
    print(f"  FAIL [Row 7]: mcp exited {p.returncode}: {p.stderr}")
    sys.exit(1)

resps = {obj["id"]: obj["result"] for obj in (json.loads(ln) for ln in p.stdout.splitlines() if ln.strip())}

for rid, exp_existing, exp_kind in [
    (10, "real_clean_001", "cite_key"),
    (11, "real_clean_001", "doi"),
    (12, "audit_024", "arxiv"),
    (13, "audit_026", "pmid"),
    (14, "seeded_tya", "title_year_first_author"),
    (16, "real_clean_001", "cite_key"),
]:
    r = resps[rid]
    if r.get("isError") is not False:
        print(f"  FAIL [Row 7]: id={rid} expected isError=False on SKIPPED_DUPLICATE, got {r}")
        sys.exit(1)
    o = json.loads(r["content"][0]["text"])
    if (
        o.get("status") != "SKIPPED_DUPLICATE"
        or o.get("existing_key") != exp_existing
        or o.get("matched_on") not in allowed_matched_on
        or o.get("matched_on") != exp_kind
    ):
        print(f"  FAIL [Row 7]: id={rid} unexpected SKIPPED_DUPLICATE payload: {o} (expected existing={exp_existing}, matched_on={exp_kind})")
        sys.exit(1)

for rid in (15, 17):
    r = resps[rid]
    if r.get("isError") is not True:
        print(f"  FAIL [Row 7]: id={rid} expected isError=True on ERR_CITE_KEY_CONFLICT, got {r}")
        sys.exit(1)
    o = json.loads(r["content"][0]["text"])
    if o.get("error_code") != "ERR_CITE_KEY_CONFLICT":
        print(f"  FAIL [Row 7]: id={rid} expected ERR_CITE_KEY_CONFLICT, got {o}")
        sys.exit(1)

if file_sig(target_bib) != sig_seeded:
    print("  FAIL [Row 7]: target_bib changed during duplicate/conflict checks")
    sys.exit(1)
if file_sig(tya_bib) != tya_before:
    print("  FAIL [Row 7]: tya_bib changed during duplicate check")
    sys.exit(1)
if file_sig(pmid_bib) != pmid_before:
    print("  FAIL [Row 7]: pmid_bib changed during duplicate check")
    sys.exit(1)

print("  [Row 7] PASS: all 4 dedup cases & all 5 matched_on kinds (cite_key, doi, arxiv, pmid, title_year_first_author) + ERR_CITE_KEY_CONFLICT + case-insensitive keys verified; files unchanged")
PY
)"
        R7_RC=$?
        set -e
        echo "$R7_OUT"
        if [[ "$R7_RC" -eq 0 ]]; then
            record_pass 7 "All 4 deduplication cases (SKIPPED_DUPLICATE, ERR_CITE_KEY_CONFLICT, case-insensitive keys) verified without modifying .bib"
        else
            record_fail 7 "Row 7 deduplication check failed"
        fi
    fi

    # ==================================================================
    # Row 8: Offline rejection (--offline server AND per-call offline: true on replay server)
    # ==================================================================
    if should_run_row 8; then
        echo "== [Row 8] Offline rejection: --offline server & per-call offline=true on replay server =="
        set +e
        R8_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import hashlib, json, os, re, subprocess, sys

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
env = dict(os.environ, HOME=sbox_home, CFFIXED_USER_HOME=sbox_home)
env.pop("SCHOLAR_CACHE_DIR", None)

def extract_entry(group: str, key: str) -> str:
    p = os.path.join(repo_root, "Benchmarks", "citations", "entries", f"{group}.bib")
    m = re.search(rf"(@\w+\{{{re.escape(key)},.*?\n\}})", open(p, encoding="utf-8").read(), flags=re.S)
    return m.group(1) + "\n"

def file_sig(path: str):
    raw = open(path, "rb").read()
    st = os.stat(path)
    return (hashlib.sha256(raw).hexdigest(), st.st_size, st.st_mtime_ns)

rc001 = extract_entry("real_clean", "real_clean_001")
au001 = extract_entry("audit_manual", "audit_001")
ret001 = extract_entry("retracted", "retracted_001")

target_bib = os.path.join(scratch, "row8.bib")
open(target_bib, "wb").write(b"% row8 sentinel\n")
sig_before = file_sig(target_bib)

# 1. Server started with --offline
reqs_srv_offline = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rc001}}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": au001}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": ret001}}},
]
p1 = subprocess.run([cli_bin, "mcp", "--offline"], input="\n".join(json.dumps(r) for r in reqs_srv_offline) + "\n", env=env, capture_output=True, text=True)
if p1.returncode != 0:
    print(f"  FAIL [Row 8]: mcp --offline exited {p1.returncode}: {p1.stderr}")
    sys.exit(1)

for ln in p1.stdout.splitlines():
    if not ln.strip():
        continue
    res = json.loads(ln)["result"]
    if res.get("isError") is not True:
        print(f"  FAIL [Row 8]: --offline server did not set isError=True: {res}")
        sys.exit(1)
    obj = json.loads(res["content"][0]["text"])
    if obj.get("error_code") != "ERR_UNVERIFIED_CITATION" or obj.get("verdict") != "UNVERIFIED" or obj.get("reasons") != ["offline"]:
        print(f"  FAIL [Row 8]: --offline server unexpected payload: {obj}")
        sys.exit(1)

# 2. Replay server with per-call offline: true
reqs_call_offline = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rc001, "offline": True}}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": au001, "offline": True}}},
]
p2 = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input="\n".join(json.dumps(r) for r in reqs_call_offline) + "\n", env=env, capture_output=True, text=True)
if p2.returncode != 0:
    print(f"  FAIL [Row 8]: mcp --registry-replay exited {p2.returncode}: {p2.stderr}")
    sys.exit(1)

for ln in p2.stdout.splitlines():
    if not ln.strip():
        continue
    res = json.loads(ln)["result"]
    if res.get("isError") is not True:
        print(f"  FAIL [Row 8]: per-call offline=True did not set isError=True: {res}")
        sys.exit(1)
    obj = json.loads(res["content"][0]["text"])
    if obj.get("error_code") != "ERR_UNVERIFIED_CITATION" or obj.get("verdict") != "UNVERIFIED" or obj.get("reasons") != ["offline"] or obj.get("mode") != "REPLAY":
        print(f"  FAIL [Row 8]: per-call offline=True unexpected payload: {obj}")
        sys.exit(1)

if file_sig(target_bib) != sig_before:
    print("  FAIL [Row 8]: target .bib modified")
    sys.exit(1)

print("  [Row 8] PASS: both --offline server and per-call offline=true reject all entries with UNVERIFIED [offline]; file unchanged")
PY
)"
        R8_RC=$?
        set -e
        echo "$R8_OUT"
        if [[ "$R8_RC" -eq 0 ]]; then
            record_pass 8 "Offline mode (--offline server and per-call offline=true) rejects all writes with UNVERIFIED [offline]"
        else
            record_fail 8 "Row 8 offline rejection check failed"
        fi
    fi

    # ==================================================================
    # Row 9: Network-denied sandbox without replay — both empty SCHOLAR_CACHE_DIR and warm VERIFIED SCHOLAR_CACHE_DIR rejected
    # ==================================================================
    if should_run_row 9; then
        echo "== [Row 9] Network-denied sandbox (no replay): add_verified_bibtex rejects with transport_error on both empty and warm VERIFIED cache =="
        set +e
        R9_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" "${SCHOLAR_OUTER_NO_NETWORK:-0}" <<'PY'
import hashlib, json, os, re, subprocess, sys

repo_root, cli_bin, sbox_home, scratch, outer_no_net = sys.argv[1:6]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")

p_bib = os.path.join(repo_root, "Benchmarks", "citations", "entries", "real_clean.bib")
rc001 = re.search(r"(@\w+\{real_clean_001,.*?\n\})", open(p_bib, encoding="utf-8").read(), flags=re.S).group(1) + "\n"

def file_sig(path: str):
    raw = open(path, "rb").read()
    st = os.stat(path)
    return (hashlib.sha256(raw).hexdigest(), st.st_size, st.st_mtime_ns)

target_bib = os.path.join(scratch, "row9.bib")
open(target_bib, "wb").write(b"% row9 sentinel\n")
sig_before = file_sig(target_bib)

mcp_net_denied_cmd = (
    [cli_bin, "mcp"]
    if outer_no_net == "1"
    else ["sandbox-exec", "-p", "(version 1)(allow default)(deny network*)", cli_bin, "mcp"]
)

# 1. Empty SCHOLAR_CACHE_DIR in network-denying sandbox
empty_cache = os.path.join(scratch, "row9-cache-empty")
os.makedirs(empty_cache, exist_ok=True)
env_empty = dict(os.environ, HOME=sbox_home, CFFIXED_USER_HOME=sbox_home, SCHOLAR_CACHE_DIR=empty_cache)

req_write = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rc001}}}
p1 = subprocess.run(mcp_net_denied_cmd, input=json.dumps(req_write) + "\n", env=env_empty, capture_output=True, text=True, timeout=60)
if p1.returncode != 0:
    print(f"  FAIL [Row 9/empty]: mcp exited {p1.returncode}: {p1.stderr}")
    sys.exit(1)
res1 = json.loads(p1.stdout.strip())["result"]
obj1 = json.loads(res1["content"][0]["text"])
if res1.get("isError") is not True or obj1.get("error_code") != "ERR_UNVERIFIED_CITATION" or obj1.get("verdict") != "UNVERIFIED" or "transport_error" not in (obj1.get("reasons") or []):
    print(f"  FAIL [Row 9/empty]: expected transport_error rejection, got {res1}")
    sys.exit(1)
if file_sig(target_bib) != sig_before:
    print("  FAIL [Row 9/empty]: target .bib modified")
    sys.exit(1)

# 2. Warm SCHOLAR_CACHE_DIR containing valid VERIFIED cache for real_clean_001
warm_cache = os.path.join(scratch, "row9-cache-warm")
os.makedirs(warm_cache, exist_ok=True)
env_warm = dict(os.environ, HOME=sbox_home, CFFIXED_USER_HOME=sbox_home, SCHOLAR_CACHE_DIR=warm_cache)

req_warm = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "verify_citation", "arguments": {"bibtex": rc001}}}
p_warm = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input=json.dumps(req_warm) + "\n", env=env_warm, capture_output=True, text=True, timeout=30)
if p_warm.returncode != 0 or not os.path.isfile(os.path.join(warm_cache, "registry.sqlite")):
    print(f"  FAIL [Row 9/warm]: failed to populate warm cache: rc={p_warm.returncode}, stderr={p_warm.stderr}")
    sys.exit(1)

# Inside network-denying sandbox without replay:
#   id=1 verify_citation hits cache -> VERIFIED (proving cache is valid!)
#   id=2 add_verified_bibtex skips cache read -> rejected with transport_error!
reqs_warm_check = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "verify_citation", "arguments": {"bibtex": rc001}}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": rc001}}},
]
p2 = subprocess.run(mcp_net_denied_cmd, input="\n".join(json.dumps(r) for r in reqs_warm_check) + "\n", env=env_warm, capture_output=True, text=True, timeout=60)
if p2.returncode != 0:
    print(f"  FAIL [Row 9/warm]: mcp exited {p2.returncode}: {p2.stderr}")
    sys.exit(1)

resps2 = {obj["id"]: obj["result"] for obj in (json.loads(ln) for ln in p2.stdout.splitlines() if ln.strip())}
vc_warm = json.loads(resps2[1]["content"][0]["text"])
if resps2[1].get("isError") is not False or vc_warm.get("verdict") != "VERIFIED" or not any(s.get("origin") == "cache" for s in (vc_warm.get("sources") or [])):
    print(f"  FAIL [Row 9/warm]: warm cache did not yield cached VERIFIED on verify_citation: {vc_warm}")
    sys.exit(1)

add_warm_res = resps2[2]
add_warm_obj = json.loads(add_warm_res["content"][0]["text"])
if (
    add_warm_res.get("isError") is not True
    or add_warm_obj.get("error_code") != "ERR_UNVERIFIED_CITATION"
    or add_warm_obj.get("verdict") != "UNVERIFIED"
    or "transport_error" not in (add_warm_obj.get("reasons") or [])
):
    print(f"  FAIL [Row 9/warm]: add_verified_bibtex did not reject with transport_error when warm cache was present: {add_warm_res}")
    sys.exit(1)

if file_sig(target_bib) != sig_before:
    print("  FAIL [Row 9/warm]: target .bib modified")
    sys.exit(1)

print("  [Row 9] PASS: network-denied server rejected add_verified_bibtex with transport_error on both empty cache and verified-hit warm cache; file unchanged")
PY
)"
        R9_RC=$?
        set -e
        echo "$R9_OUT"
        if [[ "$R9_RC" -eq 0 ]]; then
            record_pass 9 "Network-denied server rejects add_verified_bibtex (transport_error) with both empty and warm VERIFIED cache"
        else
            record_fail 9 "Row 9 network-denied cache-bypass check failed"
        fi
    fi

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
fake_bib_file = os.path.join(scratch, "row10-invented.bib")
open(fake_bib_file, "w", encoding="utf-8").write(fake_bib)
for mode_label, srv_args in [("offline", ["--offline"]), ("replay", ["--registry-replay", real_rec_dir])]:
    reqs = [
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "scholar_cite_key", "arguments": {"citeKey": "invented_2026", "bibtex": fake_bib, "registryReplayPath": fake_rec_dir}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {"bibtex": fake_bib, "registryReplayPath": fake_rec_dir}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "check_manuscript", "arguments": {"path": tex_path, "registryReplayPath": fake_rec_dir}}},
        {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "scholar_lsp_diagnostics", "arguments": {"path": tex_path, "registryReplayPath": fake_rec_dir}}},
        {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {"bibtex": fake_bib}}},
        {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {"bibtex": fake_bib, "bogusUnknownArg": "x"}}},
        {"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "verify_citation", "arguments": {"bibtex": fake_bib, "registryReplayPath": fake_rec_dir}}},
        {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": fake_bib, "registryReplayPath": fake_rec_dir}}},
        {"jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": {"name": "verify_citation", "arguments": {"bibtex": fake_bib}}},
        {"jsonrpc": "2.0", "id": 11, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": fake_bib}}},
        {"jsonrpc": "2.0", "id": 12, "method": "tools/call", "params": {"name": "check_manuscript", "arguments": {"path": tex_path, "bib_file": fake_bib_file}}},
    ]
    resps = call_mcp(srv_args, reqs)

    for rid, dname in [(2, "scholar_cite_key"), (5, "scholar_lsp_diagnostics")]:
        if ((resps.get(rid) or {}).get("error") or {}).get("code") != -32602:
            print(f"  FAIL [Row 10/{mode_label}]: deleted {dname} did not return JSON-RPC -32602: {resps.get(rid)}")
            sys.exit(1)

    for rid, tname in [
        (3, "scholar_verify_bibliography"),
        (4, "check_manuscript"),
        (7, "scholar_verify_bibliography(unknownArg)"),
        (8, "verify_citation"),
        (9, "add_verified_bibtex"),
    ]:
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

    # Without registryReplayPath, invented_2026 must NEVER be VERIFIED or written
    vb_clean = json.loads(((resps[6]["result"]["content"])[0])["text"])
    if vb_clean.get("verifiedCount") != 0 or vb_clean["verdicts"][0]["firewallClass"] == "VERIFIED":
        print(f"  FAIL [Row 10/{mode_label}]: scholar_verify_bibliography granted VERIFIED to invented_2026: {vb_clean}")
        sys.exit(1)
    vc_clean = json.loads(((resps[10]["result"]["content"])[0])["text"])
    if vc_clean.get("verdict") == "VERIFIED" or vc_clean.get("insertable") is True:
        print(f"  FAIL [Row 10/{mode_label}]: verify_citation granted VERIFIED to invented_2026: {vc_clean}")
        sys.exit(1)
    add_clean = (resps.get(11) or {}).get("result") or {}
    if add_clean.get("isError") is not True:
        print(f"  FAIL [Row 10/{mode_label}]: add_verified_bibtex on invented_2026 succeeded unexpectedly: {add_clean}")
        sys.exit(1)
    cm_clean = json.loads(((resps[12]["result"]["content"])[0])["text"])
    if ((cm_clean.get("counts") or {}).get("verdicts") or {}).get("VERIFIED") != 0:
        print(f"  FAIL [Row 10/{mode_label}]: check_manuscript granted VERIFIED to invented_2026: {cm_clean}")
        sys.exit(1)

sig_after = file_sig(target_bib)
if sig_before != sig_after:
    print(f"  FAIL [Row 10]: target.bib changed (before={sig_before}, after={sig_after})")
    sys.exit(1)

print("  [Row 10] PASS: all active tools reject fake replay with ERR_INVALID_ARGUMENT, deleted tools return -32602, invented_2026 never VERIFIED, file unchanged")
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
    # Row 11: verify_citation on all 480 benchmark entries vs CLI verify-citations --registry-replay --json
    # ==================================================================
    if should_run_row 11; then
        echo "== [Row 11] verify_citation on 480 benchmark entries vs CLI verify-citations --registry-replay --json (0 diffs) =="
        set +e
        R11_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" <<'PY'
import glob, json, os, re, subprocess, sys, time

repo_root, cli_bin, sbox_home = sys.argv[1:4]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
entries_dir = os.path.join(repo_root, "Benchmarks", "citations", "entries")
env = dict(os.environ, HOME=sbox_home, CFFIXED_USER_HOME=sbox_home)
env.pop("SCHOLAR_CACHE_DIR", None)

def split_bib_entries(text: str):
    out = []
    i, n = 0, len(text)
    while i < n:
        at = text.find("@", i)
        if at == -1:
            break
        line_start = text.rfind("\n", 0, at) + 1
        if "%" in text[line_start:at]:
            eol = text.find("\n", at)
            i = n if eol == -1 else eol + 1
            continue
        m = re.match(r"@([A-Za-z]+)\s*([{(])", text[at:])
        if not m:
            i = at + 1
            continue
        etype = m.group(1).lower()
        open_ch = m.group(2)
        close_ch = "}" if open_ch == "{" else ")"
        pos = at + m.end()
        depth = 1
        in_quotes = False
        while pos < n and depth > 0:
            ch = text[pos]
            if ch == "\\" and pos + 1 < n:
                pos += 2
                continue
            if ch == '"' and depth == 1:
                in_quotes = not in_quotes
            elif not in_quotes:
                if ch == open_ch:
                    depth += 1
                elif ch == close_ch:
                    depth -= 1
            pos += 1
        raw_entry = text[at:pos]
        if etype not in ("comment", "preamble", "string"):
            km = re.match(r"@\w+\s*[{(]\s*([^,\s]+)\s*,", raw_entry)
            key = km.group(1) if km else ""
            out.append((key, raw_entry))
        i = pos
    return out

bib_files = sorted(glob.glob(os.path.join(entries_dir, "*.bib")))
if len(bib_files) != 12:
    print(f"  FAIL [Row 11]: expected 12 benchmark .bib files, got {len(bib_files)}")
    sys.exit(1)

cli_by_id = {}
mcp_reqs = []
req_id_to_item = {}
next_id = 1

for bib_path in bib_files:
    grp = os.path.basename(bib_path)[:-4]
    p_cli = subprocess.run(
        [cli_bin, "verify-citations", bib_path, "--registry-replay", rec_dir, "--json", "--lang", "en"],
        env=env,
        capture_output=True,
        text=True,
    )
    if p_cli.returncode == 2:
        print(f"  FAIL [Row 11]: CLI verify-citations exited 2 on {grp}: {p_cli.stderr}")
        sys.exit(1)
    cli_obj = json.loads(p_cli.stdout)
    for v in cli_obj.get("verdicts") or []:
        cli_by_id[f"{grp}/{v['citeKey']}"] = {
            "cite_key": v["citeKey"],
            "verdict": v["firewallClass"],
            "reasons": v["reasons"],
            "fields": v["fields"],
            "insertable": v["insertable"],
        }

    for key, raw_entry in split_bib_entries(open(bib_path, encoding="utf-8").read()):
        mcp_reqs.append({
            "jsonrpc": "2.0",
            "id": next_id,
            "method": "tools/call",
            "params": {"name": "verify_citation", "arguments": {"bibtex": raw_entry, "lang": "en"}},
        })
        req_id_to_item[next_id] = f"{grp}/{key}"
        next_id += 1

if len(cli_by_id) != 480 or len(mcp_reqs) != 480:
    print(f"  FAIL [Row 11]: expected 480 items (cli={len(cli_by_id)}, mcp={len(mcp_reqs)})")
    sys.exit(1)

raw_in = "\n".join(json.dumps(r) for r in mcp_reqs) + "\n"
t0 = time.monotonic()
p_mcp = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input=raw_in, env=env, capture_output=True, text=True)
elapsed_s = time.monotonic() - t0
if p_mcp.returncode != 0:
    print(f"  FAIL [Row 11]: mcp exited {p_mcp.returncode}: {p_mcp.stderr}")
    sys.exit(1)

mcp_by_id = {}
for ln in p_mcp.stdout.splitlines():
    if not ln.strip():
        continue
    env_obj = json.loads(ln)
    rid = env_obj["id"]
    res = env_obj["result"]
    if res.get("isError") is not False:
        print(f"  FAIL [Row 11]: verify_citation set isError!=False on {req_id_to_item[rid]}: {res}")
        sys.exit(1)
    payload = json.loads(res["content"][0]["text"])
    if payload.get("mode") != "REPLAY":
        print(f"  FAIL [Row 11]: missing mode='REPLAY' on {req_id_to_item[rid]}")
        sys.exit(1)
    mcp_by_id[req_id_to_item[rid]] = {
        "cite_key": payload.get("cite_key"),
        "verdict": payload.get("verdict"),
        "reasons": payload.get("reasons"),
        "fields": payload.get("fields"),
        "insertable": payload.get("insertable"),
    }

if len(mcp_by_id) != 480:
    print(f"  FAIL [Row 11]: expected 480 MCP responses, got {len(mcp_by_id)}")
    sys.exit(1)

diffs = []
for k in sorted(cli_by_id):
    if cli_by_id[k] != mcp_by_id.get(k):
        diffs.append((k, cli_by_id[k], mcp_by_id.get(k)))

if diffs:
    for k, a, b in diffs[:10]:
        print(f"  FAIL [Row 11]: diff on {k}:\n    CLI={a}\n    MCP={b}")
    sys.exit(1)

print(f"  [Row 11] PASS: 480/480 verify_citation calls match CLI verify-citations --json with 0 differences (elapsed={elapsed_s:.3f}s)")
PY
)"
        R11_RC=$?
        set -e
        echo "$R11_OUT"
        if [[ "$R11_RC" -eq 0 ]]; then
            record_pass 11 "verify_citation matches CLI verify-citations --json across all 480 benchmark entries with 0 differences"
        else
            record_fail 11 "Row 11 verify_citation 480-entry parity check failed"
        fi
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

r12_write_bib = os.path.join(scratch, "r12-write.bib")
reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "verify_citation", "arguments": {"bibtex": real_clean_001}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "verify_citation", "arguments": {"bibtex": fab_codex_003}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {"bibtex": real_clean_001}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "check_manuscript", "arguments": {"path": tex_path, "bib_file": bib_path}}},
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "check_manuscript", "arguments": {"path": tex_path, "bib_file": bib_path, "detail": "full"}}},
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": r12_write_bib, "bibtex": real_clean_001}}},
    {"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": r12_write_bib, "bibtex": fab_codex_003}}},
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

for rid in range(2, 9):
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

vc_ok = json.loads(resps[2]["result"]["content"][0]["text"])
if vc_ok.get("verdict") != "VERIFIED" or not (vc_ok.get("sources") or []):
    print(f"  FAIL [Row 12]: verify_citation real_clean_001 unexpected payload: {vc_ok}")
    sys.exit(1)
for s in vc_ok.get("sources") or []:
    if not (s.get("fetchedAt") or "").startswith("2026-11-16") or s.get("origin") != "replay":
        print(f"  FAIL [Row 12]: verify_citation source fetchedAt != 2026-11-16: {s}")
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

add_ok = json.loads(resps[7]["result"]["content"][0]["text"])
if add_ok.get("status") != "APPENDED_VERIFIED" or not (add_ok.get("sources") or []):
    print(f"  FAIL [Row 12]: add_verified_bibtex unexpected payload: {add_ok}")
    sys.exit(1)
for s in add_ok.get("sources") or []:
    if not (s.get("fetchedAt") or "").startswith("2026-11-16") or s.get("origin") != "replay":
        print(f"  FAIL [Row 12]: add_verified_bibtex source fetchedAt != 2026-11-16: {s}")
        sys.exit(1)

# Also verify all 5 frozen tools carry mode='REPLAY' when --experimental-tools is enabled
exp_reqs = [
    {"jsonrpc": "2.0", "id": 101, "method": "tools/call", "params": {"name": "scholar_search_provenance", "arguments": {"claim": "attention", "projectPath": proj_path}}},
    {"jsonrpc": "2.0", "id": 102, "method": "tools/call", "params": {"name": "scholar_prisma_agreement", "arguments": {"projectPath": proj_path}}},
    {"jsonrpc": "2.0", "id": 103, "method": "tools/call", "params": {"name": "scholar_editorial_audit", "arguments": {"source": "\\section{Intro}\nPlain text.\n"}}},
    {"jsonrpc": "2.0", "id": 104, "method": "tools/call", "params": {"name": "scholar_track_changes_diff", "arguments": {"original": "Old.", "revised": "New."}}},
    {"jsonrpc": "2.0", "id": 105, "method": "tools/call", "params": {"name": "scholar_citation_gaps", "arguments": {"projectPath": proj_path}}},
]
proc_exp = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir, "--experimental-tools"], input="\n".join(json.dumps(r) for r in exp_reqs) + "\n", env=env, capture_output=True, text=True)
if proc_exp.returncode != 0:
    print(f"  FAIL [Row 12]: mcp --experimental-tools exited {proc_exp.returncode}: {proc_exp.stderr}")
    sys.exit(1)
exp_resps = {obj.get("id"): obj for obj in (json.loads(ln) for ln in proc_exp.stdout.splitlines() if ln.strip())}
for rid in range(101, 106):
    txt = (((exp_resps.get(rid) or {}).get("result") or {}).get("content") or [{}])[0].get("text") or ""
    payload = json.loads(txt)
    if not isinstance(payload, dict) or payload.get("mode") != "REPLAY":
        print(f"  FAIL [Row 12]: experimental tool id={rid} missing mode='REPLAY': {payload}")
        sys.exit(1)

print("  [Row 12] PASS: stderr=[REPLAY], all default & experimental tools carry mode='REPLAY', sources.fetchedAt & firewallVerifiedAtUTC == 2026-11-16")
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
    # Row 13: Write safety — 8 targets via MCP add_verified_bibtex
    # ==================================================================
    if should_run_row 13; then
        echo "== [Row 13] Write safety via MCP add_verified_bibtex: 8 targets (read-only, dir, missing parent, non-.bib, symlink, Latin-1, BIB001, CRLF) =="
        set +e
        R13_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import hashlib, json, os, re, shutil, stat, subprocess, sys

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
env = dict(os.environ, HOME=sbox_home, CFFIXED_USER_HOME=sbox_home)
env.pop("SCHOLAR_CACHE_DIR", None)

p_bib = os.path.join(repo_root, "Benchmarks", "citations", "entries", "real_clean.bib")
rc001 = re.search(r"(@\w+\{real_clean_001,.*?\n\})", open(p_bib, encoding="utf-8").read(), flags=re.S).group(1) + "\n"

r13_dir = os.path.join(scratch, "r13")
os.makedirs(r13_dir, exist_ok=True)

def file_sig(path: str):
    raw = open(path, "rb").read()
    st = os.lstat(path)
    return (hashlib.sha256(raw).hexdigest(), st.st_size, st.st_mtime_ns, st.st_ino)

valid_seed = b"@article{seed2020,\n  author = {Doe, Jane},\n  title = {Seed},\n  year = 2020\n}\n"

# 1. Read-only .bib
ro_bib = os.path.join(r13_dir, "readonly.bib")
open(ro_bib, "wb").write(valid_seed)
os.chmod(ro_bib, 0o444)
ro_before = file_sig(ro_bib)

# 2. Directory named dir.bib
dir_bib = os.path.join(r13_dir, "dir.bib")
os.makedirs(dir_bib, exist_ok=True)

# 3. File in non-existent parent directory
missing_parent = os.path.join(r13_dir, "missing_parent_dir")
missing_bib = os.path.join(missing_parent, "refs.bib")

# 4. Non-.bib extension
txt_target = os.path.join(r13_dir, "refs.txt")

# 5. Symlink pointing to .bib
real_target = os.path.join(r13_dir, "real_target.bib")
open(real_target, "wb").write(valid_seed)
real_before = file_sig(real_target)
sym_bib = os.path.join(r13_dir, "symlink.bib")
os.symlink(real_target, sym_bib)

# 6. Latin-1 encoded .bib
latin1_bib = os.path.join(r13_dir, "latin1.bib")
open(latin1_bib, "wb").write("@article{s1926,\n  author = {Schr\u00f6dinger, E.},\n  title = {Q},\n  year = 1926\n}\n".encode("latin-1"))
latin1_before = file_sig(latin1_bib)

# 7. BIB001 broken syntax .bib
broken_bib = os.path.join(r13_dir, "broken.bib")
open(broken_bib, "wb").write(b"@article{ok1,\n  author = {Doe, Jane},\n  title = {OK},\n  year = 2020\n}\n\n@article{bad2,\n  title = {Unclosed\n")
broken_before = file_sig(broken_bib)

# 8. CRLF .bib copy
crlf_fixture = os.path.join(repo_root, "Tests", "Fixtures", "crlf-two-entries.bib")
crlf_bib = os.path.join(r13_dir, "crlf.bib")
shutil.copyfile(crlf_fixture, crlf_bib)
crlf_orig_bytes = open(crlf_bib, "rb").read()
crlf_before = file_sig(crlf_bib)

reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": ro_bib, "bibtex": rc001}}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": dir_bib, "bibtex": rc001}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": missing_bib, "bibtex": rc001}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": txt_target, "bibtex": rc001}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": sym_bib, "bibtex": rc001}}},
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": latin1_bib, "bibtex": rc001}}},
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": broken_bib, "bibtex": rc001}}},
    {"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": crlf_bib, "bibtex": rc001}}},
]

try:
    p = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input="\n".join(json.dumps(r) for r in reqs) + "\n", env=env, capture_output=True, text=True)
finally:
    os.chmod(ro_bib, 0o644)

if p.returncode != 0:
    print(f"  FAIL [Row 13]: mcp exited {p.returncode}: {p.stderr}")
    sys.exit(1)

resps = {obj["id"]: obj["result"] for obj in (json.loads(ln) for ln in p.stdout.splitlines() if ln.strip())}

expected_errors = [
    (1, "ERR_BIB_PATH"),
    (2, "ERR_BIB_PATH"),
    (3, "ERR_BIB_PATH"),
    (4, "ERR_BIB_PATH"),
    (5, "ERR_BIB_PATH"),
    (6, "ERR_BIB_ENCODING"),
    (7, "ERR_BIB_SYNTAX"),
]
for rid, exp_code in expected_errors:
    r = resps[rid]
    if r.get("isError") is not True:
        print(f"  FAIL [Row 13]: target #{rid} expected isError=True, got {r}")
        sys.exit(1)
    o = json.loads(r["content"][0]["text"])
    if o.get("error_code") != exp_code:
        print(f"  FAIL [Row 13]: target #{rid} expected {exp_code}, got {o}")
        sys.exit(1)

if os.path.exists(missing_parent):
    print("  FAIL [Row 13]: missing parent directory was created!")
    sys.exit(1)
if os.path.exists(txt_target):
    print("  FAIL [Row 13]: non-.bib file was created!")
    sys.exit(1)
if file_sig(ro_bib)[:2] != ro_before[:2]:
    print("  FAIL [Row 13]: read-only .bib bytes changed!")
    sys.exit(1)
for lbl, pth, bef in [("symlink_target", real_target, real_before), ("latin1", latin1_bib, latin1_before), ("bib001", broken_bib, broken_before)]:
    aft = file_sig(pth)
    if aft != bef:
        print(f"  FAIL [Row 13]: {lbl} changed (before={bef}, after={aft})")
        sys.exit(1)

# Target 8: CRLF succeeds, original bytes are exact prefix, appended bytes use CRLF, inode unchanged
r8 = resps[8]
o8 = json.loads(r8["content"][0]["text"])
if r8.get("isError") is not False or o8.get("status") != "APPENDED_VERIFIED":
    print(f"  FAIL [Row 13]: CRLF target failed: {r8}")
    sys.exit(1)
crlf_after_bytes = open(crlf_bib, "rb").read()
crlf_after = file_sig(crlf_bib)
if crlf_after[3] != crlf_before[3] or not crlf_after_bytes.startswith(crlf_orig_bytes):
    print("  FAIL [Row 13]: CRLF inode changed or original bytes not prefix")
    sys.exit(1)
appended = crlf_after_bytes[len(crlf_orig_bytes):]
lfs = [i for i, b in enumerate(appended) if b == 0x0A]
if not lfs or any(i == 0 or appended[i - 1] != 0x0D for i in lfs):
    print("  FAIL [Row 13]: CRLF appended slice contains bare LF")
    sys.exit(1)

p_rb = subprocess.run([cli_bin, "verify-citations", crlf_bib, "--offline", "--json", "--lang", "en"], env=env, capture_output=True, text=True)
rb = json.loads(p_rb.stdout)
if len(rb.get("verdicts") or []) != 3 or (rb.get("unverifiedByReason") or {}).get("parse_error", 0) != 0:
    print(f"  FAIL [Row 13]: CRLF read-back failed: {p_rb.stderr}")
    sys.exit(1)

print("  [Row 13] PASS: 5 path targets -> ERR_BIB_PATH (no dir created), Latin-1 -> ERR_BIB_ENCODING, BIB001 -> ERR_BIB_SYNTAX, CRLF -> APPENDED_VERIFIED w/ prefix & CRLF preserved")
PY
)"
        R13_RC=$?
        set -e
        echo "$R13_OUT"
        if [[ "$R13_RC" -eq 0 ]]; then
            record_pass 13 "All 8 write-safety targets enforced via MCP add_verified_bibtex with zero unintended file modification"
        else
            record_fail 13 "Row 13 MCP write-safety check failed"
        fi
    fi

    # ==================================================================
    # Row 14: Concurrency — 2 concurrent MCP server processes each appending 20 distinct VERIFIED entries
    # ==================================================================
    if should_run_row 14; then
        echo "== [Row 14] Concurrency: 2 simultaneous MCP server processes each appending 20 distinct VERIFIED entries to shared.bib =="
        set +e
        R14_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import json, os, re, subprocess, sys, threading

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")

rc_text = open(os.path.join(repo_root, "Benchmarks", "citations", "entries", "real_clean.bib"), encoding="utf-8").read()
entries_40 = []
for idx in range(1, 41):
    key = f"real_clean_{idx:03d}"
    m = re.search(rf"(@\w+\{{{re.escape(key)},.*?\n\}})", rc_text, flags=re.S)
    if not m:
        print(f"  FAIL [Row 14]: missing {key} in real_clean.bib")
        sys.exit(1)
    entries_40.append((key, m.group(1) + "\n"))

shared_bib = os.path.join(scratch, "row14-shared.bib")
open(shared_bib, "wb").write(b"")

home_a = os.path.join(scratch, "r14-home-a")
home_b = os.path.join(scratch, "r14-home-b")
os.makedirs(home_a, exist_ok=True)
os.makedirs(home_b, exist_ok=True)
env_a = dict(os.environ, HOME=home_a, CFFIXED_USER_HOME=home_a)
env_b = dict(os.environ, HOME=home_b, CFFIXED_USER_HOME=home_b)
env_a.pop("SCHOLAR_CACHE_DIR", None)
env_b.pop("SCHOLAR_CACHE_DIR", None)

def build_input(slice_items):
    reqs = [
        {"jsonrpc": "2.0", "id": i + 1, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": shared_bib, "bibtex": bib}}}
        for i, (_, bib) in enumerate(slice_items)
    ]
    return "\n".join(json.dumps(r) for r in reqs) + "\n"

in_a = build_input(entries_40[:20])
in_b = build_input(entries_40[20:])

# Start BOTH server OS processes before feeding concurrent requests
proc_a = subprocess.Popen([cli_bin, "mcp", "--registry-replay", rec_dir], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env_a)
proc_b = subprocess.Popen([cli_bin, "mcp", "--registry-replay", rec_dir], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env_b)

results = {}
def communicate_worker(tag, proc, payload):
    out, err = proc.communicate(payload, timeout=120)
    results[tag] = (proc.returncode, out, err)

t_a = threading.Thread(target=communicate_worker, args=("A", proc_a, in_a))
t_b = threading.Thread(target=communicate_worker, args=("B", proc_b, in_b))
t_a.start()
t_b.start()
t_a.join()
t_b.join()

for tag in ("A", "B"):
    rc, out, err = results[tag]
    if rc != 0:
        print(f"  FAIL [Row 14]: server {tag} exited {rc}: {err}")
        sys.exit(1)
    lines = [json.loads(ln) for ln in out.splitlines() if ln.strip()]
    if len(lines) != 20:
        print(f"  FAIL [Row 14]: server {tag} returned {len(lines)} responses, expected 20")
        sys.exit(1)
    for item in lines:
        res = item["result"]
        obj = json.loads(res["content"][0]["text"])
        if res.get("isError") is not False or obj.get("status") != "APPENDED_VERIFIED":
            print(f"  FAIL [Row 14]: server {tag} write failed: {res}")
            sys.exit(1)

# Read back shared.bib via ScholarOS CLI and diagnostics (--no-verify) to confirm 40 unique entries & 0 BIB001/BIB002
p_rb = subprocess.run([cli_bin, "verify-citations", shared_bib, "--offline", "--json", "--lang", "en"], env=env_a, capture_output=True, text=True)
rb = json.loads(p_rb.stdout)
verdicts = rb.get("verdicts") or []
keys_found = [v["citeKey"] for v in verdicts]
expected_keys = [k for k, _ in entries_40]

tex_check = os.path.join(scratch, "r14-check.tex")
open(tex_check, "w", encoding="utf-8").write("\\documentclass{article}\\begin{document}\\cite{" + ",".join(expected_keys) + "}\\end{document}\n")
p_diag = subprocess.run([cli_bin, "diagnostics", tex_check, "--bib", shared_bib, "--no-verify", "--json", "--lang", "en"], env=env_a, capture_output=True, text=True)
diag_obj = json.loads(p_diag.stdout)
bib_diags = [d for d in (diag_obj.get("diagnostics") or []) if str(d.get("code", "")).startswith("BIB")]

if (
    len(verdicts) != 40
    or sorted(keys_found) != sorted(expected_keys)
    or (rb.get("unverifiedByReason") or {}).get("parse_error", 0) != 0
    or p_diag.returncode != 0
    or bib_diags
):
    print(f"  FAIL [Row 14]: shared.bib post-check failed: count={len(verdicts)}, bib_diags={bib_diags}, stderr={p_rb.stderr}")
    sys.exit(1)

print("  [Row 14] PASS: 2 concurrent MCP servers wrote 20+20=40 distinct VERIFIED entries into shared.bib; 40 unique entries read back with 0 errors")
PY
)"
        R14_RC=$?
        set -e
        echo "$R14_OUT"
        if [[ "$R14_RC" -eq 0 ]]; then
            record_pass 14 "Two concurrent MCP server processes appended 20+20=40 distinct VERIFIED entries with 0 parse or duplicate errors"
        else
            record_fail 14 "Row 14 concurrent MCP server append check failed"
        fi
    fi

    # ==================================================================
    # ==================================================================
    # Row 15: check_manuscript across all 11 benchmark manuscripts (offline: true, summary & full vs CLI --json)
    # ==================================================================
    if should_run_row 15; then
        echo "== [Row 15] check_manuscript (offline: true) on 11 benchmark manuscripts: summary counts == CLI --json counts & detail='full' byte-identical =="
        set +e
        R15_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import csv, json, os, re, subprocess, sys

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")
papers_tsv = os.path.join(repo_root, "Benchmarks", "manuscripts", "papers.tsv")

env = dict(os.environ)
env["HOME"] = sbox_home
env["CFFIXED_USER_HOME"] = sbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

with open(papers_tsv, encoding="utf-8") as f:
    rows = list(csv.DictReader(f, delimiter="\t"))

if len(rows) != 11:
    print(f"  FAIL [Row 15]: expected 11 rows in papers.tsv, got {len(rows)}")
    sys.exit(1)

failures = []
cli_by_idx = {}
rpc_reqs = []

for idx, row in enumerate(rows, start=1):
    pid = f"{row['arxiv_id']}{row['version']}"
    main_tex = os.path.join(repo_root, "Benchmarks", "manuscripts", pid, "src", row["main_file"])
    p_cli = subprocess.run(
        [cli_bin, "diagnostics", main_tex, "--offline", "--json", "--lang", "en"],
        env=env,
        capture_output=True,
    )
    if p_cli.returncode == 2:
        failures.append(f"[{pid}] CLI diagnostics exited 2: {p_cli.stderr.decode('utf-8', 'replace')}")
        continue
    raw_cli = p_cli.stdout
    cli_bytes = raw_cli[:-1] if raw_cli.endswith(b"\n") else raw_cli
    cli_obj = json.loads(cli_bytes.decode("utf-8"))
    cli_by_idx[idx] = (pid, main_tex, cli_bytes, cli_obj)

    rpc_reqs.append({
        "jsonrpc": "2.0",
        "id": idx * 2 - 1,
        "method": "tools/call",
        "params": {"name": "check_manuscript", "arguments": {"path": main_tex, "offline": True}},
    })
    rpc_reqs.append({
        "jsonrpc": "2.0",
        "id": idx * 2,
        "method": "tools/call",
        "params": {"name": "check_manuscript", "arguments": {"path": main_tex, "offline": True, "detail": "full"}},
    })

p_mcp = subprocess.run(
    [cli_bin, "mcp", "--registry-replay", rec_dir, "--lang", "en"],
    input=("\n".join(json.dumps(r) for r in rpc_reqs) + "\n").encode("utf-8"),
    env=env,
    capture_output=True,
)
if p_mcp.returncode != 0:
    print(f"  FAIL [Row 15]: mcp server exited {p_mcp.returncode}: {p_mcp.stderr.decode('utf-8', 'replace')}")
    sys.exit(1)

resps = {}
for raw_line in p_mcp.stdout.decode("utf-8").splitlines():
    ln = raw_line.strip()
    if ln:
        obj = json.loads(ln)
        resps[obj.get("id")] = obj

matched_papers = 0
for idx in sorted(cli_by_idx):
    pid, main_tex, cli_bytes, cli_obj = cli_by_idx[idx]
    sum_env = resps.get(idx * 2 - 1) or {}
    full_env = resps.get(idx * 2) or {}
    sum_res = sum_env.get("result") or {}
    full_res = full_env.get("result") or {}

    if sum_res.get("isError") is not False:
        failures.append(f"[{pid}] summary returned isError != False: {sum_res}")
        continue
    if full_res.get("isError") is not False:
        failures.append(f"[{pid}] detail='full' returned isError != False: {full_res}")
        continue

    sum_text = ((sum_res.get("content") or [{}])[0]).get("text") or ""
    full_text = ((full_res.get("content") or [{}])[0]).get("text") or ""
    sum_bytes = sum_text.encode("utf-8")
    full_bytes = full_text.encode("utf-8")

    if full_bytes != cli_bytes:
        first_diff = next((i for i, (a, b) in enumerate(zip(cli_bytes, full_bytes)) if a != b), min(len(cli_bytes), len(full_bytes)))
        failures.append(f"[{pid}] detail='full' byte mismatch at offset {first_diff}: cli={len(cli_bytes)} vs mcp={len(full_bytes)}")
        continue

    sum_obj = json.loads(sum_text)
    want_struct_errs = [
        d for d in (cli_obj.get("diagnostics") or [])
        if d.get("category") == "structure" and d.get("severity") == "ERROR"
    ]
    want_non_ver = [
        {
            "cite_key": c["key"],
            "verdict": c["verification"]["verdict"],
            "reasons": c["verification"]["reasons"],
            "fields": c["verification"]["fields"],
        }
        for c in (cli_obj.get("citations") or [])
        if c.get("verification") and c["verification"].get("verdict") != "VERIFIED"
    ]

    if sum_obj.get("counts") != cli_obj.get("counts"):
        failures.append(f"[{pid}] summary counts != CLI counts: {sum_obj.get('counts')} vs {cli_obj.get('counts')}")
        continue
    if sum_obj.get("complete") != cli_obj.get("complete") or sum_obj.get("mode") != cli_obj.get("mode"):
        failures.append(f"[{pid}] summary mode/complete mismatch: {sum_obj}")
        continue
    if sum_obj.get("structure_errors") != want_struct_errs:
        failures.append(f"[{pid}] summary structure_errors mismatch: got {len(sum_obj.get('structure_errors') or [])} vs want {len(want_struct_errs)}")
        continue
    if sum_obj.get("non_verified_citations") != want_non_ver:
        failures.append(f"[{pid}] summary non_verified_citations mismatch: got {len(sum_obj.get('non_verified_citations') or [])} vs want {len(want_non_ver)}")
        continue

    matched_papers += 1
    print(f"  [{pid}] summary_bytes={len(sum_bytes)} full_bytes={len(full_bytes)} (counts_equal=True, full_byte_identical=True)")

# Also check replay mode (without offline: true) on a synthetic manuscript citing real_clean_001 + fab_codex_003
rc_text = open(os.path.join(repo_root, "Benchmarks", "citations", "entries", "real_clean.bib"), encoding="utf-8").read()
fc_text = open(os.path.join(repo_root, "Benchmarks", "citations", "entries", "fabricated_model.bib"), encoding="utf-8").read()
rc_entry = re.search(r"(@\w+\{real_clean_001,.*?\n\})", rc_text, flags=re.S).group(1)
fc_entry = re.search(r"(@\w+\{fab_codex_003,.*?\n\})", fc_text, flags=re.S).group(1)
r15_bib = os.path.join(scratch, "r15-replay.bib")
r15_tex = os.path.join(scratch, "r15-replay.tex")
open(r15_bib, "w", encoding="utf-8").write(rc_entry + "\n\n" + fc_entry + "\n")
open(r15_tex, "w", encoding="utf-8").write("\\documentclass{article}\\begin{document}Cite~\\cite{real_clean_001, fab_codex_003}.\\end{document}\n")

p_cli_rep = subprocess.run([cli_bin, "diagnostics", r15_tex, "--bib", r15_bib, "--registry-replay", rec_dir, "--json"], env=env, capture_output=True)
cli_rep_bytes = p_cli_rep.stdout[:-1] if p_cli_rep.stdout.endswith(b"\n") else p_cli_rep.stdout
rep_reqs = [
    {"jsonrpc": "2.0", "id": 201, "method": "tools/call", "params": {"name": "check_manuscript", "arguments": {"path": r15_tex, "bib_file": r15_bib}}},
    {"jsonrpc": "2.0", "id": 202, "method": "tools/call", "params": {"name": "check_manuscript", "arguments": {"path": r15_tex, "bib_file": r15_bib, "detail": "full"}}},
]
p_mcp_rep = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input=("\n".join(json.dumps(r) for r in rep_reqs) + "\n").encode("utf-8"), env=env, capture_output=True)
rep_resps = {json.loads(ln)["id"]: json.loads(ln) for ln in p_mcp_rep.stdout.decode("utf-8").splitlines() if ln.strip()}
rep_sum = json.loads(rep_resps[201]["result"]["content"][0]["text"])
rep_full_bytes = rep_resps[202]["result"]["content"][0]["text"].encode("utf-8")
if rep_full_bytes != cli_rep_bytes:
    failures.append("replay check_manuscript(detail='full') did not match CLI diagnostics --registry-replay --json byte-for-byte")
if rep_sum.get("mode") != "REPLAY" or rep_sum.get("complete") is not True:
    failures.append(f"replay check_manuscript summary unexpected mode/complete: {rep_sum}")
if [x["cite_key"] for x in (rep_sum.get("non_verified_citations") or [])] != ["fab_codex_003"]:
    failures.append(f"replay check_manuscript summary expected only fab_codex_003 in non_verified_citations, got {rep_sum.get('non_verified_citations')}")

print(f"  [Row 15] PASS: matched_papers={matched_papers}/11 (summary counts + structure_errors + non_verified_citations & detail='full' byte-identical, plus replay mode)")
if failures or matched_papers != 11:
    for msg in failures:
        print(f"  FAIL [Row 15]: {msg}")
    sys.exit(1)
sys.exit(0)
PY
)"
        R15_RC=$?
        set -e
        echo "$R15_OUT"
        if [[ "$R15_RC" -eq 0 ]]; then
            record_pass 15 "check_manuscript on all 11 benchmark manuscripts matches CLI --offline --json counts in summary and matches --json byte-for-byte on detail='full'"
        else
            record_fail 15 "Row 15 check_manuscript summary/full parity check across 11 benchmark manuscripts failed"
        fi
    fi

    # ==================================================================
    # Row 16: Legacy tools (Settled #1c) — deleted -> -32602; scholar_verify_bibliography shares firewall, replay & cache with verify_citation
    # ==================================================================
    if should_run_row 16; then
        echo "== [Row 16] Legacy tools (Settled #1c): deleted tools -> -32602; scholar_verify_bibliography trimmed & shares firewall/replay/cache with verify_citation =="
        set +e
        R16_OUT="$(python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$WORK_SCRATCH" <<'PY'
import json, os, re, subprocess, sys

repo_root, cli_bin, sbox_home, scratch = sys.argv[1:5]
rec_dir = os.path.join(repo_root, "Benchmarks", "citations", "recordings")

env = dict(os.environ)
env["HOME"] = sbox_home
env["CFFIXED_USER_HOME"] = sbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

def extract_entry(group: str, key: str) -> str:
    p = os.path.join(repo_root, "Benchmarks", "citations", "entries", f"{group}.bib")
    txt = open(p, encoding="utf-8").read()
    m = re.search(rf"(@\w+\{{{re.escape(key)},.*?\n\}})", txt, flags=re.S)
    if not m:
        raise RuntimeError(f"Missing {key} in {p}")
    return m.group(1)

probes = [
    ("real_clean", "real_clean_001", "VERIFIED"),
    ("mut_year3", "mut_year3_001", "DRIFT"),
    ("fabricated_model", "fab_codex_003", "NOT_FOUND"),
    ("retracted", "retracted_001", "RETRACTED"),
    ("fabricated_model", "fab_codex_002", "UNVERIFIED"),
]
probe_entries = [(key, extract_entry(grp, key), want_cls) for grp, key, want_cls in probes]
batch_bib = "\n\n".join(bib for _, bib, _ in probe_entries) + "\n"

# 1. Deleted tools absent from tools/list & return -32602; removed args on scholar_verify_bibliography return ERR_INVALID_ARGUMENT
reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "scholar_cite_key", "arguments": {"citeKey": "real_clean_001", "bibtex": probe_entries[0][1]}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "scholar_lsp_diagnostics", "arguments": {"path": "main.tex"}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {"bibtex": probe_entries[0][1], "projectPath": scratch}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {"bibtex": probe_entries[0][1], "demo": True}}},
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {"bibtex": batch_bib}}},
]
for idx, (_, bib, _) in enumerate(probe_entries, start=20):
    reqs.append({"jsonrpc": "2.0", "id": idx, "method": "tools/call", "params": {"name": "verify_citation", "arguments": {"bibtex": bib}}})

p_mcp = subprocess.run([cli_bin, "mcp", "--registry-replay", rec_dir], input="\n".join(json.dumps(r) for r in reqs) + "\n", env=env, capture_output=True, text=True)
if p_mcp.returncode != 0:
    print(f"  FAIL [Row 16]: mcp exited {p_mcp.returncode}: {p_mcp.stderr}")
    sys.exit(1)

resps = {obj.get("id"): obj for obj in (json.loads(ln) for ln in p_mcp.stdout.splitlines() if ln.strip())}
tools = ((resps.get(1) or {}).get("result") or {}).get("tools") or []
names = {t.get("name") for t in tools}
if "scholar_cite_key" in names or "scholar_lsp_diagnostics" in names:
    print(f"  FAIL [Row 16]: deleted tools still listed in tools/list: {names}")
    sys.exit(1)

for rid, dname in [(2, "scholar_cite_key"), (3, "scholar_lsp_diagnostics")]:
    if ((resps.get(rid) or {}).get("error") or {}).get("code") != -32602:
        print(f"  FAIL [Row 16]: calling deleted {dname} did not return JSON-RPC -32602: {resps.get(rid)}")
        sys.exit(1)

for rid in (4, 5, 6):
    res = (resps.get(rid) or {}).get("result") or {}
    if res.get("isError") is not True:
        print(f"  FAIL [Row 16]: scholar_verify_bibliography request id={rid} expected isError=True: {res}")
        sys.exit(1)
    err_obj = json.loads(res["content"][0]["text"])
    if err_obj.get("error_code") != "ERR_INVALID_ARGUMENT":
        print(f"  FAIL [Row 16]: scholar_verify_bibliography request id={rid} expected ERR_INVALID_ARGUMENT, got {err_obj}")
        sys.exit(1)

# 2. Batch replay verification matches verify_citation on all 5 classes (catches Row 21 mutation h: switching old tool to offline mode!)
batch_res = (resps.get(7) or {}).get("result") or {}
if batch_res.get("isError") is not False:
    print(f"  FAIL [Row 16]: scholar_verify_bibliography batch failed: {batch_res}")
    sys.exit(1)
batch_report = json.loads(batch_res["content"][0]["text"])
if batch_report.get("mode") != "REPLAY":
    print(f"  FAIL [Row 16]: scholar_verify_bibliography missing mode='REPLAY' (offline mutation?): {batch_report}")
    sys.exit(1)

batch_by_key = {v["citeKey"]: v for v in (batch_report.get("verdicts") or [])}
for idx, (key, _, want_cls) in enumerate(probe_entries, start=20):
    vc_res = (resps.get(idx) or {}).get("result") or {}
    vc_obj = json.loads(vc_res["content"][0]["text"])
    bv = batch_by_key.get(key)
    if not bv:
        print(f"  FAIL [Row 16]: batch output missing {key}")
        sys.exit(1)
    if bv.get("firewallClass") != want_cls:
        print(f"  FAIL [Row 16]: scholar_verify_bibliography verdict for {key} is {bv.get('firewallClass')!r} (reasons={bv.get('reasons')}), expected {want_cls!r}")
        sys.exit(1)
    if (
        bv.get("firewallClass") != vc_obj.get("verdict")
        or bv.get("reasons") != vc_obj.get("reasons")
        or bv.get("fields") != vc_obj.get("fields")
        or bv.get("insertable") != vc_obj.get("insertable")
        or bv.get("record") != vc_obj.get("record")
    ):
        print(f"  FAIL [Row 16]: scholar_verify_bibliography diverged from verify_citation on {key}: batch={bv} vs single={vc_obj}")
        sys.exit(1)

# 3. Shared SQLite cache parity on network-denied server (no --registry-replay)
warm_cache = os.path.join(scratch, "r16-cache")
os.makedirs(warm_cache, exist_ok=True)
env_warm = dict(env, SCHOLAR_CACHE_DIR=warm_cache)
p_warm = subprocess.run(
    [cli_bin, "mcp", "--registry-replay", rec_dir],
    input=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "verify_citation", "arguments": {"bibtex": probe_entries[0][1]}}}) + "\n",
    env=env_warm,
    capture_output=True,
    text=True,
)
if p_warm.returncode != 0:
    print(f"  FAIL [Row 16]: cache pre-warm failed: {p_warm.stderr}")
    sys.exit(1)

net_denied_cmd = (
    [cli_bin, "mcp"]
    if os.environ.get("SCHOLAR_OUTER_NO_NETWORK") == "1"
    else ["sandbox-exec", "-p", "(version 1)(allow default)(deny network*)", cli_bin, "mcp"]
)
cache_reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "verify_citation", "arguments": {"bibtex": probe_entries[0][1]}}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "scholar_verify_bibliography", "arguments": {"bibtex": probe_entries[0][1]}}},
]
p_cached = subprocess.run(net_denied_cmd, input="\n".join(json.dumps(r) for r in cache_reqs) + "\n", env=env_warm, capture_output=True, text=True, timeout=30)
if p_cached.returncode != 0:
    print(f"  FAIL [Row 16]: network-denied cached mcp exited {p_cached.returncode}: {p_cached.stderr}")
    sys.exit(1)
c_resps = {json.loads(ln)["id"]: json.loads(ln) for ln in p_cached.stdout.splitlines() if ln.strip()}
c_vc = json.loads(c_resps[1]["result"]["content"][0]["text"])
c_svb = json.loads(c_resps[2]["result"]["content"][0]["text"])["verdicts"][0]
if c_vc.get("verdict") != "VERIFIED" or c_svb.get("firewallClass") != "VERIFIED":
    print(f"  FAIL [Row 16]: warm SQLite cache not shared between verify_citation ({c_vc.get('verdict')}) and scholar_verify_bibliography ({c_svb.get('firewallClass')})")
    sys.exit(1)

print("  [Row 16] PASS: deleted tools return -32602; scholar_verify_bibliography rejects removed args and matches verify_citation on 5-class replay & warm SQLite cache")
sys.exit(0)
PY
)"
        R16_RC=$?
        set -e
        echo "$R16_OUT"
        if [[ "$R16_RC" -eq 0 ]]; then
            record_pass 16 "Deleted tools absent & return -32602; scholar_verify_bibliography trimmed and shares firewall, replay & cache with verify_citation"
        else
            record_fail 16 "Row 16 legacy tool removal/trimming or shared verification parity check failed"
        fi
    fi

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

# 20a-3. M1 Row 18 (verify_citation & add_verified_bibtex) and M1 Row 20 (scholar_verify_bibliography)
m1_tmp = os.path.join(scratch, "r20-m1-tmp")
os.makedirs(m1_tmp, exist_ok=True)
m1_env = dict(env)
m1_env["TMPDIR"] = m1_tmp
p_m1_18 = subprocess.run([m1_acc_script, "--row", "18"], env=m1_env, capture_output=True, text=True)
if (
    p_m1_18.returncode != 0
    or "RESULT [Row 18]: PASS" not in p_m1_18.stdout
    or "mcp_verify_citation=NOT_FOUND" not in p_m1_18.stdout
    or "mcp_add_verified_bibtex=ERR_UNVERIFIED_CITATION" not in p_m1_18.stdout
):
    failures.append(f"m1-acceptance.sh --row 18 failed (exit={p_m1_18.returncode}): {p_m1_18.stdout[-400:]} {p_m1_18.stderr[-400:]}")
else:
    print("  [Row 20a-3] PASS: m1-acceptance.sh --row 18 exited 0 (verify_citation + add_verified_bibtex NOT_FOUND, 未采信/not trusted, file unchanged)")

p_m1_20 = subprocess.run([m1_acc_script, "--row", "20"], env=m1_env, capture_output=True, text=True)
if p_m1_20.returncode != 0 or "RESULT [Row 20]: PASS" not in p_m1_20.stdout:
    failures.append(f"m1-acceptance.sh --row 20 failed (exit={p_m1_20.returncode}): {p_m1_20.stdout[-400:]} {p_m1_20.stderr[-400:]}")
else:
    print("  [Row 20a-4] PASS: m1-acceptance.sh --row 20 exited 0 (RESULT [Row 20]: PASS)")

# 20b. M2 acceptance (m2-acceptance.sh all rows incl. updated Row 15 check_manuscript + hard-inputs.sh)
m2_acc_script = os.path.join(repo_root, "Scripts", "acceptance", "m2-acceptance.sh")
hard_script = os.path.join(repo_root, "Scripts", "acceptance", "hard-inputs.sh")
m2_tmp = os.path.join(scratch, "r20-m2-tmp")
os.makedirs(m2_tmp, exist_ok=True)
m2_env = dict(env)
m2_env["TMPDIR"] = m2_tmp
p_m2 = subprocess.run([m2_acc_script], env=m2_env, capture_output=True, text=True)
if p_m2.returncode not in (0, 2) or "Failed: 0" not in p_m2.stdout or "RESULT [Row 15]: PASS" not in p_m2.stdout:
    failures.append(f"m2-acceptance.sh failed (exit={p_m2.returncode}): {p_m2.stdout[-600:]} {p_m2.stderr[-400:]}")
else:
    print(f"  [Row 20b-1] PASS: m2-acceptance.sh passed with 0 failures (exit={p_m2.returncode}, incl. Row 15 check_manuscript byte parity)")

p_hard = subprocess.run([hard_script], env=m2_env, capture_output=True, text=True)
if p_hard.returncode != 0 or "PASS: hard-inputs" not in p_hard.stdout:
    failures.append(f"hard-inputs.sh failed (exit={p_hard.returncode}): {p_hard.stdout[-400:]} {p_hard.stderr[-400:]}")
else:
    print("  [Row 20b-2] PASS: hard-inputs.sh exited 0 (PASS: hard-inputs)")

if failures:
    for msg in failures:
        print(f"  FAIL [Row 20]: {msg}")
    sys.exit(1)

sys.exit(0)
PY
)"
        R20_RC=$?
        set -e
        echo "$R20_OUT"
        if [[ "$R20_RC" -eq 0 ]]; then
            record_pass 20 "m1-citation-bench.py --replay, 480-entry parity, M1 Row 18/20, m2-acceptance.sh, and hard-inputs.sh all passed"
        else
            record_fail 20 "Row 20 480-entry replay parity, M1 Row 18/20, or M2 non-regression check failed"
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
