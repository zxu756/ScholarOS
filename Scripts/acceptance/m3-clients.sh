#!/usr/bin/env bash
#
# M3 Acceptance Row 18: Isolated MCP Client Registration & Handshake Verification
# (`Scripts/acceptance/m3-clients.sh`).
#
# Verifies that the MCP registration snippets in README.md and README.zh-CN.md register and connect
# cleanly against real local client CLIs (Claude Code, Codex, OpenCode) without sending any prompt
# to any model and without touching the user's real home configuration:
#
#   1. Parses README.md and README.zh-CN.md to confirm both carry identical registration snippets
#      for Claude Code, Codex, and OpenCode, and zero references to removed tools.
#   2. Snapshots file manifests + SHA-256 digests of the real user account's client config paths
#      (`.claude`, `.claude.json`, `.codex`, `.config/opencode`,
#      `Library/Application Support/ai.opencode.desktop`) plus ScholarOS preference/cache hygiene
#      before and after running; fails immediately if anything changed.
#   3. Wraps every client invocation in `env -i` (isolated HOME and client config directories in
#      /tmp) and `/usr/bin/sandbox-exec` (denying external network via directional localhost rules
#      `network-bind`/`network-inbound`/`network-outbound` + unix sockets, self-checked upfront with
#      `/usr/bin/python3` against `1.1.1.1:80` -> `PermissionError` and a `127.0.0.1` self-listener,
#      and denying all file writes to the real user home directory and client configs).
#   4. Wraps the built `ScholarOS` binary with a stdio tee logger (`--registry-replay
#      Benchmarks/citations/recordings`) to verify each client sends `tools/list` and receives
#      `verify_citation`, `add_verified_bibtex`, `check_manuscript` (and `scholar_verify_bibliography`).
#   5. Never invokes `claude -p`, `codex exec`, `opencode run`, or any prompt-sending subcommand.
#      Shuts down the isolated `opencode serve` process group before exiting.
#
# Not included in `Scripts/test.sh milestone 3` default runs (depends on locally installed CLIs).
#
# Usage:
#   Scripts/acceptance/m3-clients.sh            report goes to a temporary directory
#   Scripts/acceptance/m3-clients.sh --record   report overwrites reports/m3-clients.txt
#
# Exit codes:
#   0  all 3 clients passed and real config fingerprints are unchanged
#   1  any client failed or any real config fingerprint changed
#   2  0 failures, >= 1 client not installed (`没跑`), and real config fingerprints are unchanged
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

RECORD=0
for arg in "$@"; do
    case "$arg" in
        --record) RECORD=1 ;;
        *)
            echo "Usage: Scripts/acceptance/m3-clients.sh [--record]" >&2
            exit 2
            ;;
    esac
done

# Always place WORK under /tmp (/private/tmp) so it is outside the real user's home directory,
# allowing sandbox-exec to deny file-write* across the entire real home directory cleanly.
WORK="$(mktemp -d /tmp/scholaros-m3-clients.XXXXXX)"
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
    CREATED_TEMP_REPORT_DIR="$(mktemp -d /tmp/scholaros-m3-clients-report.XXXXXX)"
    REPORT_DIR="$CREATED_TEMP_REPORT_DIR"
fi
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/m3-clients.txt"

export SCHOLAR_SANDBOX_HOME="$WORK/scholar-build-home"
mkdir -p "$SCHOLAR_SANDBOX_HOME"
unset SCHOLAR_CACHE_DIR

# shellcheck source=Scripts/acceptance/lib-cli-guard.sh
source "$REPO_ROOT/Scripts/acceptance/lib-cli-guard.sh"

if [[ -z "${SCHOLAR_CLI_BIN:-}" ]]; then
    export SCHOLAR_CLI_BIN="$REPO_ROOT/.build/debug/ScholarOS"
    swift build >/dev/null
elif [[ ! -x "$SCHOLAR_CLI_BIN" ]]; then
    echo "FAIL: SCHOLAR_CLI_BIN is not an executable file: $SCHOLAR_CLI_BIN" >&2
    exit 1
fi

REC_DIR="$REPO_ROOT/Benchmarks/citations/recordings"
if [[ ! -f "$REC_DIR/manifest.json" ]]; then
    echo "FAIL: Missing replay recordings directory: $REC_DIR" >&2
    exit 1
fi

set +e
python3 -I - "$REPO_ROOT" "$SCHOLAR_CLI_BIN" "$REC_DIR" "$WORK" "$REPORT_FILE" <<'PY'
from __future__ import annotations

import difflib
import glob
import hashlib
import json
import os
import pwd
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time

repo_root, cli_bin, rec_dir, work_dir, report_file = sys.argv[1:6]
work_dir = os.path.realpath(work_dir)
cli_bin = os.path.realpath(cli_bin)
rec_dir = os.path.realpath(rec_dir)
real_home = pwd.getpwuid(os.getuid()).pw_dir
real_home_resolved = os.path.realpath(real_home)

lines_out = []


def mask_home(text: str) -> str:
    res = text.replace(real_home_resolved, "~")
    if real_home != real_home_resolved:
        res = res.replace(real_home, "~")
    return res


def log(msg: str = "") -> None:
    masked = mask_home(msg)
    print(masked, flush=True)
    lines_out.append(masked)


MONITORED_REL_PATHS = [
    ".claude",
    ".claude.json",
    ".codex",
    ".config/opencode",
    "Library/Application Support/ai.opencode.desktop",
]


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def snapshot_real_configs() -> tuple[dict[str, dict], list[str], str]:
    manifest_lines: list[str] = []
    per_target: dict[str, dict] = {}

    for rel in MONITORED_REL_PATHS:
        target = os.path.join(real_home, rel)
        target_lines: list[str] = []
        file_count = 0
        try:
            st = os.lstat(target)
        except FileNotFoundError:
            entry = f"ABSENT {rel}"
            target_lines.append(entry)
            manifest_lines.append(entry)
            th = hashlib.sha256("\n".join(target_lines).encode("utf-8")).hexdigest()
            per_target[rel] = {"state": "absent", "files": 0, "sha256": th}
            continue

        mode = st.st_mode
        if stat.S_ISLNK(mode):
            entry = f"SYMLINK {rel} -> {os.readlink(target)}"
            target_lines.append(entry)
        elif stat.S_ISREG(mode):
            file_count = 1
            entry = f"FILE {rel} size={st.st_size} sha256={sha256_file(target)}"
            target_lines.append(entry)
        elif stat.S_ISDIR(mode):
            target_lines.append(f"DIR {rel}")
            for cur_root, dirnames, filenames in os.walk(target, topdown=True, followlinks=False):
                dirnames.sort()
                filenames.sort()
                rel_root = os.path.relpath(cur_root, real_home)
                if rel_root != rel:
                    target_lines.append(f"DIR {rel_root}")
                for dname in dirnames:
                    full_d = os.path.join(cur_root, dname)
                    rel_d = os.path.relpath(full_d, real_home)
                    try:
                        dst = os.lstat(full_d)
                        if stat.S_ISLNK(dst.st_mode):
                            target_lines.append(f"SYMLINK {rel_d} -> {os.readlink(full_d)}")
                    except FileNotFoundError:
                        target_lines.append(f"VANISHED {rel_d}")
                for fname in filenames:
                    full_f = os.path.join(cur_root, fname)
                    rel_f = os.path.relpath(full_f, real_home)
                    try:
                        fst = os.lstat(full_f)
                    except FileNotFoundError:
                        target_lines.append(f"VANISHED {rel_f}")
                        continue
                    fmode = fst.st_mode
                    if stat.S_ISLNK(fmode):
                        target_lines.append(f"SYMLINK {rel_f} -> {os.readlink(full_f)}")
                    elif stat.S_ISREG(fmode):
                        file_count += 1
                        target_lines.append(
                            f"FILE {rel_f} size={fst.st_size} sha256={sha256_file(full_f)}"
                        )
                    else:
                        target_lines.append(f"SPECIAL {rel_f} mode={oct(stat.S_IFMT(fmode))}")
        else:
            target_lines.append(f"SPECIAL {rel} mode={oct(stat.S_IFMT(mode))}")

        manifest_lines.extend(target_lines)
        th = hashlib.sha256("\n".join(target_lines).encode("utf-8")).hexdigest()
        per_target[rel] = {"state": "present", "files": file_count, "sha256": th}

    # Also record ScholarOS real-home preference & cache state (Row 23 hygiene)
    prefs_dir = os.path.join(real_home, "Library", "Preferences")
    scholar_prefs = []
    if os.path.isdir(prefs_dir):
        scholar_prefs = sorted(
            fn for fn in os.listdir(prefs_dir) if fn.startswith("io.github.zxu756.ScholarOS.")
        )
    manifest_lines.append(f"SCHOLAR_PREFS count={len(scholar_prefs)} items={scholar_prefs}")

    cache_dir = os.path.join(real_home, "Library", "Caches", "ScholarOS")
    if not os.path.exists(cache_dir):
        manifest_lines.append("SCHOLAR_CACHE absent")
    else:
        db_path = os.path.join(cache_dir, "registry.sqlite")
        if os.path.exists(db_path):
            cst = os.stat(db_path)
            manifest_lines.append(f"SCHOLAR_CACHE present mtime_ns={cst.st_mtime_ns} size={cst.st_size}")
        else:
            manifest_lines.append("SCHOLAR_CACHE present:no-db")

    overall = hashlib.sha256("\n".join(manifest_lines).encode("utf-8")).hexdigest()
    return per_target, manifest_lines, overall


def sbpl_quote(p: str) -> str:
    return '"' + p.replace("\\", "\\\\").replace('"', '\\"') + '"'


def build_sandbox_profile(dst_path: str) -> None:
    homes = [real_home]
    if real_home_resolved not in homes:
        homes.append(real_home_resolved)

    deny_clauses = []
    for h in homes:
        deny_clauses.extend(
            [
                f"    (subpath {sbpl_quote(os.path.join(h, '.claude'))})",
                f"    (literal {sbpl_quote(os.path.join(h, '.claude.json'))})",
                f"    (subpath {sbpl_quote(os.path.join(h, '.codex'))})",
                f"    (subpath {sbpl_quote(os.path.join(h, '.config/opencode'))})",
                f"    (subpath {sbpl_quote(os.path.join(h, 'Library/Application Support/ai.opencode.desktop'))})",
                f"    (subpath {sbpl_quote(h)})",
            ]
        )

    profile = "\n".join(
        [
            "(version 1)",
            "(allow default)",
            "(deny network*)",
            "(allow network* (local unix))",
            "(allow network* (remote unix))",
            '(allow network-bind (local ip "localhost:*"))',
            '(allow network-inbound (local ip "localhost:*"))',
            '(allow network-outbound (remote ip "localhost:*"))',
            "(deny file-write*",
            *deny_clauses,
            ")",
            "",
        ]
    )
    with open(dst_path, "w", encoding="utf-8") as fh:
        fh.write(profile)


def selfcheck_sandbox_profile(sb_path: str, base_dir: str) -> tuple[bool, list[str], str]:
    sc_dir = os.path.join(base_dir, "sb-selfcheck")
    os.makedirs(sc_dir, exist_ok=True)
    sc_env, sc_dirs = make_isolated_env(sc_dir, {})
    probe_code = """
import socket
import sys

ext = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
ext.settimeout(3.0)
try:
    ext.connect(("1.1.1.1", 80))
    print("FAIL_EXTERNAL: outbound connect to 1.1.1.1:80 succeeded (sandbox leaked external network)")
    sys.exit(11)
except PermissionError as exc:
    print(f"OK_EXTERNAL_BLOCKED: 1.1.1.1:80 raised {type(exc).__name__}(errno={exc.errno}): {exc}")
except BaseException as exc:
    print(
        f"FAIL_EXTERNAL: expected PermissionError connecting to 1.1.1.1:80, "
        f"got {type(exc).__name__}(errno={getattr(exc, 'errno', None)}): {exc}"
    )
    sys.exit(12)
finally:
    ext.close()

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.settimeout(3.0)
cli = None
conn = None
try:
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]
    cli = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    cli.settimeout(3.0)
    cli.connect(("127.0.0.1", port))
    conn, _ = srv.accept()
    conn.settimeout(3.0)
    cli.sendall(b"scholaros-sb-selfcheck")
    got = conn.recv(64)
    if got != b"scholaros-sb-selfcheck":
        print(f"FAIL_LOCALHOST: unexpected loopback payload {got!r}")
        sys.exit(13)
    conn.sendall(b"ack")
    ack = cli.recv(16)
    if ack != b"ack":
        print(f"FAIL_LOCALHOST: unexpected loopback ack {ack!r}")
        sys.exit(13)
    print(f"OK_LOCALHOST_CONNECTED: 127.0.0.1:{port} bind/connect/accept roundtrip ok")
except BaseException as exc:
    print(
        f"FAIL_LOCALHOST: 127.0.0.1 self-listener check failed with "
        f"{type(exc).__name__}(errno={getattr(exc, 'errno', None)}): {exc}"
    )
    sys.exit(14)
finally:
    for sock in (conn, cli, srv):
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass

print("SELFCHECK_OK")
"""
    try:
        proc = subprocess.run(
            ["/usr/bin/sandbox-exec", "-f", sb_path, "/usr/bin/python3", "-I", "-c", probe_code],
            cwd=sc_dirs["tmp"],
            env=sc_env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=15.0,
        )
    except Exception as exc:
        return False, [], f"/usr/bin/sandbox-exec self-check execution error: {exc}"

    out_lines = [ln.strip() for ln in (proc.stdout or "").splitlines() if ln.strip()]
    err_lines = [ln.strip() for ln in (proc.stderr or "").splitlines() if ln.strip()]
    has_ext_ok = any(ln.startswith("OK_EXTERNAL_BLOCKED:") for ln in out_lines)
    has_loc_ok = any(ln.startswith("OK_LOCALHOST_CONNECTED:") for ln in out_lines)
    has_done = "SELFCHECK_OK" in out_lines

    if proc.returncode == 0 and has_ext_ok and has_loc_ok and has_done:
        details = [ln for ln in out_lines if ln != "SELFCHECK_OK"]
        return True, details, "ok"

    combined = "; ".join(out_lines + err_lines) or f"exit code {proc.returncode}"
    return False, out_lines, f"sandbox network self-check failed (rc={proc.returncode}): {combined}"


def extract_readme_registration_snippets(readme_path: str) -> dict:
    with open(readme_path, encoding="utf-8") as fh:
        text = fh.read()

    for forbidden in ("scholar_cite_key", "scholar_lsp_diagnostics"):
        if forbidden in text:
            raise ValueError(f"{os.path.basename(readme_path)} still mentions removed tool '{forbidden}'")

    for required_note in ("/opt/homebrew/bin/scholaros", "tool_timeout_sec"):
        if required_note not in text:
            raise ValueError(f"{os.path.basename(readme_path)} is missing required note '{required_note}'")

    fenced = re.findall(r"```([a-zA-Z0-9_-]*)\n(.*?)```", text, flags=re.DOTALL)
    claude_cmd = None
    codex_toml = None
    opencode_json = None

    for lang, body in fenced:
        stripped_lines = [
            ln.strip()
            for ln in body.splitlines()
            if ln.strip() and not ln.strip().startswith("#")
        ]
        for ln in stripped_lines:
            if ln.startswith("claude mcp add "):
                claude_cmd = ln
        if lang == "toml" and "[mcp_servers.scholaros]" in body:
            codex_toml = "\n".join(
                ln.strip() for ln in body.splitlines() if ln.strip() and not ln.strip().startswith("#")
            )
        if lang == "json" and '"scholaros"' in body and '"mcp"' in body:
            parsed = json.loads(body.strip())
            if (
                isinstance(parsed, dict)
                and parsed.get("mcp", {}).get("servers", {}).get("scholaros", {}).get("command")
                == ["scholaros", "mcp"]
            ):
                opencode_json = parsed

    if claude_cmd != "claude mcp add --scope user scholaros -- scholaros mcp":
        raise ValueError(
            f"{os.path.basename(readme_path)} missing expected Claude registration command; got: {claude_cmd!r}"
        )
    expected_toml = '\n'.join(
        [
            "[mcp_servers.scholaros]",
            'command = "scholaros"',
            'args = ["mcp"]',
        ]
    )
    if codex_toml != expected_toml:
        raise ValueError(
            f"{os.path.basename(readme_path)} Codex TOML snippet mismatch; got:\n{codex_toml!r}"
        )
    if opencode_json is None:
        raise ValueError(f"{os.path.basename(readme_path)} missing expected OpenCode JSON registration snippet")

    return {
        "claude_cmd": claude_cmd,
        "codex_toml": codex_toml,
        "opencode_json": opencode_json,
    }


def make_wrapper(client_dir: str, client_home: str) -> tuple[str, str, str]:
    wrapper_path = os.path.join(client_dir, "scholaros-logged.sh")
    traffic_in = os.path.join(client_dir, "traffic.in")
    traffic_out = os.path.join(client_dir, "traffic.out")
    open(traffic_in, "wb").close()
    open(traffic_out, "wb").close()

    script = (
        "#!/bin/sh\n"
        "unset SCHOLAR_CACHE_DIR\n"
        f'export HOME="{client_home}"\n'
        f'export CFFIXED_USER_HOME="{client_home}"\n'
        f'/usr/bin/tee -a "{traffic_in}" | "{cli_bin}" "$@" | /usr/bin/tee -a "{traffic_out}"\n'
    )
    with open(wrapper_path, "w", encoding="utf-8") as fh:
        fh.write(script)
    os.chmod(wrapper_path, 0o755)
    return wrapper_path, traffic_in, traffic_out


def verify_traffic_logs(traffic_in: str, traffic_out: str) -> tuple[bool, list[str], str]:
    saw_tools_list_req = False
    with open(traffic_in, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and obj.get("method") == "tools/list":
                saw_tools_list_req = True

    if not saw_tools_list_req:
        return False, [], "client never sent JSON-RPC method 'tools/list'"

    captured_tools: list[str] = []
    with open(traffic_out, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if not isinstance(obj, dict):
                continue
            res = obj.get("result")
            if isinstance(res, dict) and isinstance(res.get("tools"), list):
                captured_tools = [
                    t.get("name", "") for t in res["tools"] if isinstance(t, dict) and "name" in t
                ]

    required = {"verify_citation", "add_verified_bibtex", "check_manuscript"}
    deleted = {"scholar_cite_key", "scholar_lsp_diagnostics"}
    if not captured_tools:
        return False, [], "no JSON-RPC tools/list response captured from ScholarOS"
    missing = sorted(required - set(captured_tools))
    if missing:
        return False, captured_tools, f"tools/list response missing required tools: {missing}"
    present_deleted = sorted(deleted & set(captured_tools))
    if present_deleted:
        return False, captured_tools, f"tools/list response exposed deleted tools: {present_deleted}"

    return True, captured_tools, "ok"


def find_executable(candidates: list[str]) -> str | None:
    for cand in candidates:
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return os.path.realpath(cand)
    return None


def find_claude() -> str | None:
    w = shutil.which("claude")
    return find_executable(
        [
            w or "",
            os.path.join(real_home, ".local", "bin", "claude"),
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    )


def find_codex() -> str | None:
    w = shutil.which("codex")
    return find_executable(
        [
            w or "",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
    )


def find_opencode() -> str | None:
    w = shutil.which("opencode")
    direct = find_executable(
        [
            w or "",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            os.path.join(real_home, ".opencode", "bin", "opencode"),
        ]
    )
    if direct:
        return direct
    desktop_glob = sorted(
        glob.glob(
            os.path.join(
                real_home,
                "Library",
                "Application Support",
                "ai.opencode.desktop",
                "cli",
                "*",
                "opencode-cli",
            )
        ),
        reverse=True,
    )
    return find_executable(desktop_glob)


FORBIDDEN_SUBCOMMANDS = {"-p", "--print", "exec", "run", "prompt"}


def run_sandboxed(
    sb_file: str,
    binary: str,
    args: list[str],
    env: dict[str, str],
    cwd: str,
    timeout_sec: float = 90.0,
) -> subprocess.CompletedProcess:
    # Hard safety guard: never send a prompt to any model.
    if args and args[0] in FORBIDDEN_SUBCOMMANDS:
        raise RuntimeError(f"Refused forbidden model-invoking argument: {args[0]}")
    cmd = ["/usr/bin/sandbox-exec", "-f", sb_file, binary, *args]
    return subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=timeout_sec,
    )


def make_isolated_env(base_dir: str, extra: dict[str, str]) -> tuple[dict[str, str], dict[str, str]]:
    dirs = {}
    for sub in ("home", "tmp", "proj", "xdg-config", "xdg-data", "xdg-cache", "xdg-state", "cfg"):
        p = os.path.join(base_dir, sub)
        os.makedirs(p, exist_ok=True)
        dirs[sub] = p
    env = {
        "PATH": "/usr/bin:/bin:/usr/sbin",
        "HOME": dirs["home"],
        "CFFIXED_USER_HOME": dirs["home"],
        "XDG_CONFIG_HOME": dirs["xdg-config"],
        "XDG_DATA_HOME": dirs["xdg-data"],
        "XDG_CACHE_HOME": dirs["xdg-cache"],
        "XDG_STATE_HOME": dirs["xdg-state"],
        "TMPDIR": dirs["tmp"],
        "LANG": "en_US.UTF-8",
        "NO_COLOR": "1",
    }
    env.update(extra)
    return env, dirs


def pick_free_local_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


log("# ScholarOS M3 Acceptance Row 18 — Isolated MCP Client Registration Report")
log(f"Date: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}")
try:
    commit_sha = subprocess.check_output(
        ["git", "-C", repo_root, "rev-parse", "--short", "HEAD"], text=True
    ).strip()
except Exception:
    commit_sha = "unknown"
log(f"Commit: {commit_sha}")
log(f"Binary: {os.path.relpath(cli_bin, repo_root)}")
log("Replay: Benchmarks/citations/recordings (network denied except localhost/unix; real home writes denied)")
log("")

# 0. Build and self-check sandbox-exec network isolation profile upfront before touching clients
log("== [Step 0] Self-check sandbox-exec network isolation profile ==")
sb_file = os.path.join(work_dir, "client-iso.sb")
build_sandbox_profile(sb_file)
sb_ok, sb_details, sb_reason = selfcheck_sandbox_profile(sb_file, work_dir)
if not sb_ok:
    log(f"  FAIL: {sb_reason}")
    with open(report_file, "w", encoding="utf-8") as rfh:
        rfh.write("\n".join(lines_out) + "\n")
    sys.exit(1)
for d_line in sb_details:
    log(f"  {d_line}")
log("  PASS: external TCP (1.1.1.1:80) raised PermissionError and local 127.0.0.1 listener connected")
log("")

# 1. Verify README.md & README.zh-CN.md snippets match before touching any client
log("== [Step 1] Verify README.md and README.zh-CN.md MCP registration snippets ==")
try:
    en_snippets = extract_readme_registration_snippets(os.path.join(repo_root, "README.md"))
    zh_snippets = extract_readme_registration_snippets(os.path.join(repo_root, "README.zh-CN.md"))
    if en_snippets != zh_snippets:
        log("FAIL: README.md and README.zh-CN.md client registration snippets differ")
        sys.exit(1)
    log("  PASS: README.md and README.zh-CN.md carry identical Claude Code, Codex, and OpenCode snippets (0 deleted tool refs)")
except Exception as exc:
    log(f"  FAIL: {exc}")
    with open(report_file, "w", encoding="utf-8") as rfh:
        rfh.write("\n".join(lines_out) + "\n")
    sys.exit(1)
log("")

# 2. Pre-run real home fingerprint
log("== [Step 2] Pre-run real home client config fingerprints ==")
before_targets, before_manifest, before_overall = snapshot_real_configs()
for rel in MONITORED_REL_PATHS:
    info = before_targets[rel]
    log(f"  [BEFORE] ~/{rel}: state={info['state']} files={info['files']} sha256={info['sha256']}")
log(f"  [BEFORE] overall_manifest_sha256={before_overall}")
log("")

passed_count = 0
failed_count = 0
skipped_count = 0
summary_rows: list[str] = []

# ==============================================================================
# Client 1: Claude Code (`claude`)
# ==============================================================================
log("== [Client 1/3] Claude Code ==")
claude_bin = find_claude()
if not claude_bin:
    log("  RESULT [claude]: SKIP (没跑) — claude CLI not found")
    skipped_count += 1
    summary_rows.append("claude    | SKIP(没跑) | CLI not found — 没跑")
else:
    t0 = time.monotonic()
    c_dir = os.path.join(work_dir, "claude")
    os.makedirs(c_dir, exist_ok=True)
    c_env, c_dirs = make_isolated_env(c_dir, {})
    c_env["CLAUDE_CONFIG_DIR"] = c_dirs["cfg"]
    wrapper, t_in, t_out = make_wrapper(c_dir, c_dirs["home"])

    try:
        ver_p = run_sandboxed(sb_file, claude_bin, ["--version"], c_env, c_dirs["proj"], timeout_sec=30.0)
        ver_str = (ver_p.stdout.strip() or ver_p.stderr.strip() or "unknown").splitlines()[0]

        # Transform README snippet `claude mcp add --scope user scholaros -- scholaros mcp`
        reg_tokens = en_snippets["claude_cmd"].split()
        # Replace `claude` -> binary, `scholaros` -> wrapper, append `--registry-replay <rec_dir>`
        sep_idx = reg_tokens.index("--")
        add_args = reg_tokens[1 : sep_idx + 1] + [wrapper, "mcp", "--registry-replay", rec_dir]
        add_p = run_sandboxed(sb_file, claude_bin, add_args, c_env, c_dirs["proj"], timeout_sec=45.0)
        cfg_file = os.path.join(c_dirs["cfg"], ".claude.json")

        get_p = run_sandboxed(
            sb_file, claude_bin, ["mcp", "get", "scholaros"], c_env, c_dirs["proj"], timeout_sec=60.0
        )
        combined_get = (get_p.stdout or "") + "\n" + (get_p.stderr or "")
        if "Connected" not in combined_get:
            list_p = run_sandboxed(
                sb_file, claude_bin, ["mcp", "list"], c_env, c_dirs["proj"], timeout_sec=60.0
            )
            combined_get += "\n" + (list_p.stdout or "") + "\n" + (list_p.stderr or "")

        elapsed = time.monotonic() - t0
        ok_traffic, tools_seen, traffic_msg = verify_traffic_logs(t_in, t_out)

        if (
            add_p.returncode == 0
            and os.path.isfile(cfg_file)
            and get_p.returncode == 0
            and "Connected" in combined_get
            and ok_traffic
        ):
            log(f"  binary={claude_bin} | version={ver_str} | elapsed={elapsed:.2f}s")
            log("  connectivity=Connected (claude mcp get scholaros)")
            log(f"  tools/list={tools_seen}")
            log("  RESULT [claude]: PASS")
            passed_count += 1
            summary_rows.append(
                f"claude    | PASS       | version={ver_str}, elapsed={elapsed:.2f}s, tools={tools_seen}"
            )
        else:
            log(f"  binary={claude_bin} | version={ver_str} | elapsed={elapsed:.2f}s")
            log(
                f"  FAIL details: add_rc={add_p.returncode} get_rc={get_p.returncode} "
                f"cfg_exists={os.path.isfile(cfg_file)} traffic={traffic_msg}"
            )
            log(f"  output tail: {combined_get.strip()[-300:]}")
            log("  RESULT [claude]: FAIL")
            failed_count += 1
            summary_rows.append(f"claude    | FAIL       | {traffic_msg}")
    except Exception as exc:
        elapsed = time.monotonic() - t0
        log(f"  RESULT [claude]: FAIL ({elapsed:.2f}s) — {exc}")
        failed_count += 1
        summary_rows.append(f"claude    | FAIL       | {exc}")
log("")

# ==============================================================================
# Client 2: Codex (`codex`)
# ==============================================================================
log("== [Client 2/3] Codex ==")
codex_bin = find_codex()
if not codex_bin:
    log("  RESULT [codex]: SKIP (没跑) — codex CLI not found")
    skipped_count += 1
    summary_rows.append("codex     | SKIP(没跑) | CLI not found — 没跑")
else:
    t0 = time.monotonic()
    x_dir = os.path.join(work_dir, "codex")
    os.makedirs(x_dir, exist_ok=True)
    x_env, x_dirs = make_isolated_env(x_dir, {})
    x_env["CODEX_HOME"] = x_dirs["cfg"]
    wrapper, t_in, t_out = make_wrapper(x_dir, x_dirs["home"])

    try:
        ver_p = run_sandboxed(sb_file, codex_bin, ["--version"], x_env, x_dirs["proj"], timeout_sec=30.0)
        ver_str = (ver_p.stdout.strip() or ver_p.stderr.strip() or "unknown").splitlines()[0]

        # Materialize README TOML snippet into $CODEX_HOME/config.toml with built wrapper + --registry-replay
        toml_text = (
            en_snippets["codex_toml"]
            .replace('command = "scholaros"', f"command = {json.dumps(wrapper)}")
            .replace(
                'args = ["mcp"]',
                f'args = ["mcp", "--registry-replay", {json.dumps(rec_dir)}]',
            )
            + "\n"
        )
        cfg_toml_path = os.path.join(x_dirs["cfg"], "config.toml")
        with open(cfg_toml_path, "w", encoding="utf-8") as fh:
            fh.write(toml_text)

        get_p = run_sandboxed(
            sb_file, codex_bin, ["mcp", "get", "scholaros"], x_env, x_dirs["proj"], timeout_sec=30.0
        )
        # Non-prompt connectivity & tool-table fetch via `codex debug prompt-input`
        dbg_p = run_sandboxed(
            sb_file, codex_bin, ["debug", "prompt-input"], x_env, x_dirs["proj"], timeout_sec=60.0
        )
        elapsed = time.monotonic() - t0
        ok_traffic, tools_seen, traffic_msg = verify_traffic_logs(t_in, t_out)
        has_ns = "mcp__scholaros" in (dbg_p.stdout or "")

        if get_p.returncode == 0 and dbg_p.returncode == 0 and has_ns and ok_traffic:
            log(f"  binary={codex_bin} | version={ver_str} | elapsed={elapsed:.2f}s")
            log("  connectivity=Connected (codex debug prompt-input -> Deferred tool namespaces: mcp__scholaros)")
            log(f"  tools/list={tools_seen}")
            log("  RESULT [codex]: PASS")
            passed_count += 1
            summary_rows.append(
                f"codex     | PASS       | version={ver_str}, elapsed={elapsed:.2f}s, tools={tools_seen}"
            )
        else:
            log(f"  binary={codex_bin} | version={ver_str} | elapsed={elapsed:.2f}s")
            log(
                f"  FAIL details: mcp_get_rc={get_p.returncode} debug_rc={dbg_p.returncode} "
                f"has_mcp__scholaros={has_ns} traffic={traffic_msg}"
            )
            log(f"  stderr tail: {(dbg_p.stderr or '').strip()[-300:]}")
            log("  RESULT [codex]: FAIL")
            failed_count += 1
            summary_rows.append(f"codex     | FAIL       | {traffic_msg}")
    except Exception as exc:
        elapsed = time.monotonic() - t0
        log(f"  RESULT [codex]: FAIL ({elapsed:.2f}s) — {exc}")
        failed_count += 1
        summary_rows.append(f"codex     | FAIL       | {exc}")
log("")

# ==============================================================================
# Client 3: OpenCode (`opencode` / Desktop `opencode-cli`)
# ==============================================================================
log("== [Client 3/3] OpenCode ==")
opencode_bin = find_opencode()
if not opencode_bin:
    log("  RESULT [opencode]: SKIP (没跑) — opencode CLI not found")
    skipped_count += 1
    summary_rows.append("opencode  | SKIP(没跑) | CLI not found — 没跑")
else:
    t0 = time.monotonic()
    o_dir = os.path.join(work_dir, "opencode")
    os.makedirs(o_dir, exist_ok=True)
    o_env, o_dirs = make_isolated_env(o_dir, {})
    oc_global_dir = os.path.join(o_dirs["xdg-config"], "opencode")
    os.makedirs(oc_global_dir, exist_ok=True)
    oc_cfg_path = os.path.join(oc_global_dir, "opencode.json")
    o_env["OPENCODE_CONFIG"] = oc_cfg_path
    wrapper, t_in, t_out = make_wrapper(o_dir, o_dirs["home"])

    serve_proc = None
    serve_log_fh = None
    serve_shutdown_clean = False
    try:
        ver_p = run_sandboxed(
            sb_file, opencode_bin, ["--version"], o_env, o_dirs["proj"], timeout_sec=30.0
        )
        ver_str = (ver_p.stdout.strip() or ver_p.stderr.strip() or "unknown").splitlines()[0]

        # Materialize README JSON snippet with built wrapper + --registry-replay
        oc_cfg_obj = json.loads(json.dumps(en_snippets["opencode_json"]))
        oc_cfg_obj["mcp"]["servers"]["scholaros"]["command"] = [
            wrapper,
            "mcp",
            "--registry-replay",
            rec_dir,
        ]
        with open(oc_cfg_path, "w", encoding="utf-8") as fh:
            json.dump(oc_cfg_obj, fh, indent=2)
        with open(os.path.join(o_dirs["proj"], "opencode.json"), "w", encoding="utf-8") as fh:
            json.dump(oc_cfg_obj, fh, indent=2)

        port = pick_free_local_port()
        serve_log_path = os.path.join(o_dir, "serve.log")
        serve_log_fh = open(serve_log_path, "wb", buffering=0)
        serve_proc = subprocess.Popen(
            [
                "/usr/bin/sandbox-exec",
                "-f",
                sb_file,
                opencode_bin,
                "serve",
                "--hostname",
                "127.0.0.1",
                "--port",
                str(port),
            ],
            cwd=o_dirs["proj"],
            env=o_env,
            stdin=subprocess.DEVNULL,
            stdout=serve_log_fh,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

        server_url = None
        server_pw = None
        listen_deadline = time.monotonic() + 15.0
        while time.monotonic() < listen_deadline:
            if serve_proc.poll() is not None:
                break
            with open(serve_log_path, encoding="utf-8", errors="replace") as rfh:
                s_txt = rfh.read()
            m_url = re.search(r"server listening on (http://127\.0\.0\.1:\d+)", s_txt)
            m_pw = re.search(r"server password (\S+)", s_txt)
            if m_url:
                server_url = m_url.group(1)
                if m_pw:
                    server_pw = m_pw.group(1)
                    break
                time.sleep(0.25)
                with open(serve_log_path, encoding="utf-8", errors="replace") as rfh2:
                    m_pw2 = re.search(r"server password (\S+)", rfh2.read())
                    if m_pw2:
                        server_pw = m_pw2.group(1)
                break
            time.sleep(0.2)

        connected = False
        last_poll_out = ""
        if server_url:
            poll_env = dict(o_env)
            if server_pw:
                poll_env["OPENCODE_PASSWORD"] = server_pw
            poll_deadline = time.monotonic() + 30.0
            while time.monotonic() < poll_deadline:
                poll_p = run_sandboxed(
                    sb_file,
                    opencode_bin,
                    ["mcp", "list", "--server", server_url],
                    poll_env,
                    o_dirs["proj"],
                    timeout_sec=15.0,
                )
                last_poll_out = ((poll_p.stdout or "") + "\n" + (poll_p.stderr or "")).strip()
                low = last_poll_out.lower()
                ok_traffic_now, _, _ = verify_traffic_logs(t_in, t_out)
                if poll_p.returncode == 0 and "scholaros" in low and "connected" in low and ok_traffic_now:
                    connected = True
                    break
                time.sleep(1.0)

        # Shut down isolated `opencode serve` process group before verifying final state
        if serve_proc is not None:
            pgid = serve_proc.pid
            try:
                os.killpg(pgid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                serve_proc.wait(timeout=3.0)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(pgid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                serve_proc.wait(timeout=3.0)
            try:
                os.killpg(pgid, 0)
                serve_shutdown_clean = False
            except ProcessLookupError:
                serve_shutdown_clean = True
            serve_proc = None

        elapsed = time.monotonic() - t0
        ok_traffic, tools_seen, traffic_msg = verify_traffic_logs(t_in, t_out)

        if server_url and connected and ok_traffic and serve_shutdown_clean:
            log(f"  binary={opencode_bin} | version={ver_str} | elapsed={elapsed:.2f}s")
            log(f"  connectivity=Connected (opencode serve {server_url} + opencode mcp list; serve process group stopped)")
            log(f"  tools/list={tools_seen}")
            log("  RESULT [opencode]: PASS")
            passed_count += 1
            summary_rows.append(
                f"opencode  | PASS       | version={ver_str}, elapsed={elapsed:.2f}s, tools={tools_seen}"
            )
        else:
            log(f"  binary={opencode_bin} | version={ver_str} | elapsed={elapsed:.2f}s")
            log(
                f"  FAIL details: server_url={server_url} connected={connected} "
                f"serve_stopped={serve_shutdown_clean} traffic={traffic_msg}"
            )
            log(f"  last_poll_out: {last_poll_out[-300:]}")
            try:
                with open(serve_log_path, encoding="utf-8", errors="replace") as sfh:
                    serve_tail = sfh.read().strip()[-400:]
            except Exception:
                serve_tail = ""
            if serve_tail:
                log(f"  serve_log tail: {serve_tail}")
            log("  RESULT [opencode]: FAIL")
            failed_count += 1
            summary_rows.append(f"opencode  | FAIL       | {traffic_msg}")
    except Exception as exc:
        elapsed = time.monotonic() - t0
        log(f"  RESULT [opencode]: FAIL ({elapsed:.2f}s) — {exc}")
        failed_count += 1
        summary_rows.append(f"opencode  | FAIL       | {exc}")
    finally:
        if serve_proc is not None:
            try:
                os.killpg(serve_proc.pid, signal.SIGTERM)
                serve_proc.wait(timeout=2.0)
            except Exception:
                try:
                    os.killpg(serve_proc.pid, signal.SIGKILL)
                except Exception:
                    pass
                try:
                    serve_proc.wait(timeout=2.0)
                except Exception:
                    pass
        if serve_log_fh is not None:
            serve_log_fh.close()
log("")

# 4. Post-run real home fingerprint comparison
log("== [Step 4] Post-run real home client config fingerprints ==")
after_targets, after_manifest, after_overall = snapshot_real_configs()
for rel in MONITORED_REL_PATHS:
    info = after_targets[rel]
    same = info["sha256"] == before_targets[rel]["sha256"]
    log(
        f"  [AFTER]  ~/{rel}: state={info['state']} files={info['files']} "
        f"sha256={info['sha256']} unchanged={same}"
    )
log(f"  [AFTER]  overall_manifest_sha256={after_overall} (matches_before={after_overall == before_overall})")

if after_manifest != before_manifest:
    log("FAIL: Real home client configuration or ScholarOS state changed during m3-clients.sh!")
    for diff_line in difflib.unified_diff(
        before_manifest, after_manifest, fromfile="before", tofile="after", lineterm=""
    ):
        log("  " + diff_line)
    failed_count += 1
    summary_rows.append("hygiene   | FAIL       | real home config fingerprint changed")
else:
    summary_rows.append(f"hygiene   | PASS       | real home fingerprints unchanged ({after_overall[:16]}...)")
log("")

log("========================================================================")
log("M3 Row 18 Client Registration Summary:")
for row in summary_rows:
    log(f"  {row}")
log("------------------------------------------------------------------------")
log(f"Passed: {passed_count} | Failed: {failed_count} | Skipped (没跑): {skipped_count}")
log("========================================================================")

with open(report_file, "w", encoding="utf-8") as rfh:
    rfh.write("\n".join(lines_out) + "\n")

if failed_count > 0:
    sys.exit(1)
if skipped_count > 0:
    sys.exit(2)
sys.exit(0)
PY
RC=$?
set -e

if [[ -z "$CREATED_TEMP_REPORT_DIR" ]]; then
    echo "[m3-clients] report written to $REPORT_FILE" >&2
fi

exit "$RC"
