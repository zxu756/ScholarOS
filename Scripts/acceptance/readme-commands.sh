#!/usr/bin/env bash
#
# README command replay.
#
# The commands are NOT copied into this script. They are extracted from the ```bash fenced code
# blocks of README.md and README.zh-CN.md and executed from the repository root. Editing a command
# in either README therefore changes what runs here.
#
#   1. Both READMEs must carry the same commands. Comment lines and blank lines may differ (the
#      comments are translated); every other line of the code blocks must be identical, otherwise
#      this script fails before running anything.
#   2. Each README's blocks are then replayed with `set -eo pipefail` (including under
#      `sandbox-exec -p '(version 1)(allow default)(deny network*)'`, per M1 Acceptance Row 22):
#      - Top-level milestone/release drivers (`Scripts/test.sh milestone ...` / `release`) that
#        themselves invoke `readme-commands.sh` are checked for existence/executability without
#        recursive re-entry.
#      - Explicit live-network commands (`SCHOLAR_ONLINE=1 ...`) verify the `--live` offline guard
#        (prints `没跑` and exits `2` when `SCHOLAR_ONLINE` is unset) and are logged as skipped in
#        offline/sandboxed replay.
#      - All other commands — including `python3 Scripts/acceptance/m1-citation-bench.py --replay`,
#        `swift build`, every `ScholarOS` CLI/MCP invocation, and `Scripts/test.sh scope ...` — run
#        verbatim, and the replay benchmark numbers are checked against the README tables.
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
#   SCHOLAR_REPORT_DIR          directory for the report (set by Scripts/test.sh); overrides default
#   SCHOLAR_BUILD_JOBS          optional cap for `swift build` / `swift test` parallelism (e.g. 3)
#   SCHOLAR_OUTER_NO_NETWORK=1  validates outer deny-network sandbox and passes --disable-sandbox
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
mkdir -p "$SCHOLAR_SANDBOX_HOME" "$WORK/tmp"
# README replay looks the executable up on PATH (after `swift build`) or lets m1-citation-bench.py
# resolve `.build/debug/ScholarOS`, exactly as the README tells the reader.
unset SCHOLAR_CLI_BIN
GUARD_LIB="$REPO_ROOT/Scripts/acceptance/lib-cli-guard.sh"
# Validate SCHOLAR_OUTER_NO_NETWORK=1 (exits 2 if not actually inside a network-denying sandbox)
# and detect outer sandbox so child swift / test.sh invocations pass --disable-sandbox.
# shellcheck source=Scripts/acceptance/lib-cli-guard.sh
source "$GUARD_LIB"

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

# Transforms a README blocks file so recursive top-level suite drivers and live-online commands
# are validated offline without recursion or network access, while all other lines run verbatim.
prepare_replay_body() {
    python3 -I - "$1" <<'PY'
import re, shlex, sys

src_path = sys.argv[1]
with open(src_path, encoding="utf-8") as f:
    lines = f.readlines()

re_recursive_driver = re.compile(r"^\s*Scripts/test\.sh\s+(milestone\s+\d+|release)(?:\s|$)")
re_online_cmd = re.compile(r"^\s*SCHOLAR_ONLINE=1\s+(.+)$")
re_client_reg = re.compile(r"^\s*(claude|codex|opencode)\s+mcp\s+")

for raw in lines:
    stripped = raw.rstrip("\n")
    if re_recursive_driver.match(stripped):
        msg = shlex.quote(f"[SKIP-RECURSIVE] verified top-level suite driver: {stripped.strip()}")
        print(f"test -x Scripts/test.sh && echo {msg}")
    elif re_client_reg.match(stripped):
        msg = shlex.quote(f"[SKIP-CLIENT] client registration command verified by m3-clients.sh: {stripped.strip()}")
        print(f"echo {msg}")
    elif re_online_cmd.match(stripped):
        msg = shlex.quote(f"[SKIP-ONLINE] 没跑 — online command skipped in offline/sandboxed README replay: {stripped.strip()}")
        print(
            "test -f Scripts/acceptance/m1-citation-bench.py && "
            "{ set +e; _guard_out=\"$(env -u SCHOLAR_ONLINE python3 -I Scripts/acceptance/m1-citation-bench.py --live 2>&1)\"; _guard_rc=$?; set -e; "
            "test \"$_guard_rc\" -eq 2 && printf '%s\\n' \"$_guard_out\" | grep -q '没跑'; } && "
            f"echo {msg}"
        )
    else:
        print(stripped)
PY
}

{
    echo "# ScholarOS README.md & README.zh-CN.md Command Replay"
    echo "Date: $(date +%Y-%m-%d)"
    echo "Commands are extracted from the bash code blocks of both READMEs and executed."
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
    if ! grep -q -E 'ScholarOS[[:space:]]+verify-citations[[:space:]].*--offline' "$WORK/README.md.commands.txt"; then
        echo "FAIL: README bash blocks must include a 'ScholarOS verify-citations ... --offline' example"
        exit 1
    fi
    if ! grep -q -E 'ScholarOS[[:space:]]+verify-citations[[:space:]].*--registry-replay[[:space:]]+Tests/Fixtures/registry' "$WORK/README.md.commands.txt"; then
        echo "FAIL: README bash blocks must include a 'ScholarOS verify-citations ... --registry-replay Tests/Fixtures/registry' example"
        exit 1
    fi
    if grep -E 'ScholarOS[[:space:]]+verify-citations[[:space:]]' "$WORK/README.md.commands.txt" | grep -v -E -- '(--offline|--registry-replay)'; then
        echo "FAIL: every 'ScholarOS verify-citations' command in README must pass --offline or --registry-replay so replay never touches the network"
        exit 1
    fi
    if grep -E 'ScholarOS[[:space:]]+diagnostics[[:space:]]' "$WORK/README.md.commands.txt" | grep -v -E -- '(--offline|--registry-replay|--no-verify)'; then
        echo "FAIL: every 'ScholarOS diagnostics' command in README must pass --offline, --registry-replay, or --no-verify so replay never touches the network"
        exit 1
    fi
    if ! grep -q -E 'ScholarOS[[:space:]]+diagnostics[[:space:]].*--offline' "$WORK/README.md.commands.txt"; then
        echo "FAIL: README bash blocks must include a 'ScholarOS diagnostics ... --offline' example"
        exit 1
    fi
    if ! grep -q -E 'ScholarOS[[:space:]]+diagnostics[[:space:]].*--no-verify' "$WORK/README.md.commands.txt"; then
        echo "FAIL: README bash blocks must include a 'ScholarOS diagnostics ... --no-verify' example"
        exit 1
    fi
    if ! grep -q -F 'Scripts/test.sh milestone 2' "$WORK/README.md.commands.txt"; then
        echo "FAIL: README bash blocks must include 'Scripts/test.sh milestone 2'"
        exit 1
    fi
    if ! grep -q -F 'Scripts/test.sh milestone 1' "$WORK/README.md.commands.txt"; then
        echo "FAIL: README bash blocks must include 'Scripts/test.sh milestone 1'"
        exit 1
    fi
    if ! grep -q -F 'python3 Scripts/acceptance/m1-citation-bench.py --replay' "$WORK/README.md.commands.txt"; then
        echo "FAIL: README bash blocks must include 'python3 Scripts/acceptance/m1-citation-bench.py --replay'"
        exit 1
    fi
    if ! grep -q -F 'SCHOLAR_ONLINE=1 python3 Scripts/acceptance/m1-citation-bench.py --live' "$WORK/README.md.commands.txt"; then
        echo "FAIL: README bash blocks must include 'SCHOLAR_ONLINE=1 python3 Scripts/acceptance/m1-citation-bench.py --live'"
        exit 1
    fi
    if grep -E '(^|[|;&[:space:]])(ScholarOS|scholaros)[[:space:]]+mcp([[:space:]]|$)' "$WORK/README.md.commands.txt" | grep -v -E '^[[:space:]]*(claude|codex|opencode)[[:space:]]+mcp[[:space:]]' | grep -v -E -- '(--offline|--registry-replay)'; then
        echo "FAIL: every direct 'scholaros mcp' / 'ScholarOS mcp' command in README bash blocks must pass --offline or --registry-replay"
        exit 1
    fi
    if ! grep -q -E 'tools/list.*scholaros[[:space:]]+mcp[[:space:]]+--offline' "$WORK/README.md.commands.txt"; then
        echo "FAIL: README bash blocks must include a piped 'tools/list' replay against 'scholaros mcp --offline'"
        exit 1
    fi
    if ! grep -q -E 'scholaros[[:space:]]+mcp[[:space:]]+--registry-replay[[:space:]]+Tests/Fixtures/registry' "$WORK/README.md.commands.txt"; then
        echo "FAIL: README bash blocks must include a 'scholaros mcp --registry-replay Tests/Fixtures/registry' example"
        exit 1
    fi
    python3 -I - "$REPO_ROOT/README.md" "$REPO_ROOT/README.zh-CN.md" <<'PY'
import json, re, sys

def check_doc(path):
    txt = open(path, encoding="utf-8").read()
    for removed in ("scholar_cite_key", "scholar_lsp_diagnostics"):
        if removed in txt:
            raise SystemExit(f"FAIL: {path} still mentions removed MCP tool {removed}")
    for note in ("/opt/homebrew/bin/scholaros", "tool_timeout_sec"):
        if note not in txt:
            raise SystemExit(f"FAIL: {path} missing required client note {note}")
    blocks = re.findall(r"```([a-zA-Z0-9_-]*)\n(.*?)```", txt, flags=re.DOTALL)
    sh_cmds = [
        ln.strip()
        for lang, b in blocks if lang in ("sh", "bash", "")
        for ln in b.splitlines()
        if ln.strip().startswith("claude mcp add ")
    ]
    toml_blocks = [
        "\n".join(ln.strip() for ln in b.splitlines() if ln.strip() and not ln.strip().startswith("#"))
        for lang, b in blocks if lang == "toml" and "[mcp_servers.scholaros]" in b
    ]
    json_blocks = [
        json.loads(b.strip())
        for lang, b in blocks if lang == "json" and '"scholaros"' in b and '"mcp"' in b
    ]
    if sh_cmds != ["claude mcp add --scope user scholaros -- scholaros mcp"]:
        raise SystemExit(f"FAIL: {path} Claude registration snippet mismatch: {sh_cmds!r}")
    if toml_blocks != ['[mcp_servers.scholaros]\ncommand = "scholaros"\nargs = ["mcp"]']:
        raise SystemExit(f"FAIL: {path} Codex TOML registration snippet mismatch: {toml_blocks!r}")
    if json_blocks != [{"mcp": {"servers": {"scholaros": {"type": "local", "command": ["scholaros", "mcp"]}}}}]:
        raise SystemExit(f"FAIL: {path} OpenCode JSON registration snippet mismatch: {json_blocks!r}")
    return (sh_cmds, toml_blocks, json_blocks)

en_reg = check_doc(sys.argv[1])
zh_reg = check_doc(sys.argv[2])
if en_reg != zh_reg:
    raise SystemExit("FAIL: README.md and README.zh-CN.md MCP client registration snippets differ")
print("mcp_client_registration_snippets_consistent=true")
PY
    echo "verify_citations_and_m1_repro_examples_present=true"
    echo ""

    for README_FILE in "${README_FILES[@]}"; do
        echo "== Replay: bash code blocks of $README_FILE =="
        prepare_replay_body "$WORK/$README_FILE.blocks.sh" > "$WORK/$README_FILE.prepared.sh"
        {
            printf 'export TMPDIR=%q\n' "$WORK/tmp"
            echo "unset SCHOLAR_REPORT_DIR"
            printf 'source %q\n' "$GUARD_LIB"
            echo "set -eo pipefail"
            # From here on bash echoes every input line before running it, so the report shows
            # the README text itself next to the output it produced.
            echo "set -v"
            cat "$WORK/$README_FILE.prepared.sh"
        } > "$WORK/replay.sh"
        set +e
        bash "$WORK/replay.sh" > "$WORK/$README_FILE.replay.out" 2>&1
        REPLAY_EXIT=$?
        set -e
        cat "$WORK/$README_FILE.replay.out"
        echo ""
        echo "replay_exit[$README_FILE]=$REPLAY_EXIT"
        if [[ "$REPLAY_EXIT" -ne 0 ]]; then
            echo "FAIL: replaying the code blocks of $README_FILE exited with $REPLAY_EXIT"
            exit 1
        fi
        if ! grep -q '^\[REPLAY' "$WORK/$README_FILE.replay.out"; then
            echo "FAIL: replaying $README_FILE did not emit [REPLAY] banner from verify-citations --registry-replay"
            exit 1
        fi
        if ! grep -q -F 'Allow (VERIFIED): precision=206/206 (100.00%), recall=206/226 (91.15%)' "$WORK/$README_FILE.replay.out"; then
            echo "FAIL: replaying $README_FILE did not reproduce expected M1 Allow precision/recall from m1-citation-bench.py --replay"
            exit 1
        fi
        if ! grep -q -F 'Hard gate (non-insertable VERIFIED == 0): count=0 passed=True' "$WORK/$README_FILE.replay.out"; then
            echo "FAIL: replaying $README_FILE did not confirm hard gate count=0 passed=True"
            exit 1
        fi
        if ! grep -q -F 'Citation verification: 1 key, VERIFIED 1, DRIFT 0, NOT_FOUND 0, RETRACTED 0, UNVERIFIED 0' "$WORK/$README_FILE.replay.out"; then
            echo "FAIL: replaying $README_FILE did not emit expected English citation verification summary line from diagnostics --registry-replay"
            exit 1
        fi
        if ! grep -q -F '引用核查：1 个键，VERIFIED 1，DRIFT 0，NOT_FOUND 0，RETRACTED 0，UNVERIFIED 0' "$WORK/$README_FILE.replay.out"; then
            echo "FAIL: replaying $README_FILE did not emit expected Chinese citation verification summary line from diagnostics --registry-replay"
            exit 1
        fi
        if ! grep -q -F 'Citation verification: 1 key, VERIFIED 0, DRIFT 0, NOT_FOUND 0, RETRACTED 0, UNVERIFIED 1 (reasons: offline 1); results incomplete' "$WORK/$README_FILE.replay.out"; then
            echo "FAIL: replaying $README_FILE did not emit expected incomplete summary line from diagnostics --offline"
            exit 1
        fi
        if ! grep -q -F 'expected_exit=3' "$WORK/$README_FILE.replay.out"; then
            echo "FAIL: replaying $README_FILE did not capture expected_exit=3 from offline diagnostics/verify-citations"
            exit 1
        fi
        if ! grep -q -F '引用核查：未核查引用（已指定 --no-verify，共 1 个引用键）' "$WORK/$README_FILE.replay.out"; then
            echo "FAIL: replaying $README_FILE did not emit expected --no-verify notice from diagnostics --no-verify"
            exit 1
        fi
        for REQUIRED_TOOL in verify_citation add_verified_bibtex check_manuscript scholar_verify_bibliography; do
            if ! grep -q -F "\"name\":\"$REQUIRED_TOOL\"" "$WORK/$README_FILE.replay.out"; then
                echo "FAIL: replaying $README_FILE did not emit MCP tool '$REQUIRED_TOOL' in tools/list output"
                exit 1
            fi
        done
        for REMOVED_TOOL in scholar_cite_key scholar_lsp_diagnostics; do
            if grep -q -F "$REMOVED_TOOL" "$WORK/$README_FILE.replay.out"; then
                echo "FAIL: replaying $README_FILE unexpectedly emitted removed MCP tool '$REMOVED_TOOL'"
                exit 1
            fi
        done
        for EXPECTED_MCP_MARKER in ERR_UNVERIFIED_CITATION APPENDED_VERIFIED non_verified_citations; do
            if ! grep -q -F "$EXPECTED_MCP_MARKER" "$WORK/$README_FILE.replay.out"; then
                echo "FAIL: replaying $README_FILE did not emit expected MCP write-gate/check_manuscript marker '$EXPECTED_MCP_MARKER'"
                exit 1
            fi
        done
        echo ""
    done

    echo "README.md & README.zh-CN.md COMMAND REPLAY PASSED."
} | tee "$REPORT_FILE"

echo "[readme-commands] report written to $REPORT_FILE" >&2
