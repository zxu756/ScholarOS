#!/usr/bin/env bash
#
# Fast M2 hard-inputs fixture check (`Scripts/acceptance/hard-inputs.sh`, target < 1 s).
#
# Runs `scholaros diagnostics Tests/Fixtures/manuscripts/hard-inputs/hard.tex --offline --json`
# under an isolated HOME (via `lib-cli-guard.sh`) and compares extracted citation keys, labels,
# `fake*` leakage, and structure-category ERROR diagnostics against
# `Tests/Fixtures/manuscripts/expected/hard-inputs.json`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if [[ $# -gt 0 ]]; then
    echo "Usage: Scripts/acceptance/hard-inputs.sh" >&2
    exit 2
fi

HARD_TEX="$REPO_ROOT/Tests/Fixtures/manuscripts/hard-inputs/hard.tex"
EXPECTED_JSON="$REPO_ROOT/Tests/Fixtures/manuscripts/expected/hard-inputs.json"

if [[ ! -f "$HARD_TEX" ]]; then
    echo "FAIL: Missing fixture $HARD_TEX" >&2
    exit 2
fi
if [[ ! -f "$EXPECTED_JSON" ]]; then
    echo "FAIL: Missing expected file $EXPECTED_JSON" >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scholaros-hard-inputs.XXXXXX")"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

export SCHOLAR_SANDBOX_HOME="$WORK/home"
mkdir -p "$SCHOLAR_SANDBOX_HOME"
unset SCHOLAR_CACHE_DIR

# shellcheck source=Scripts/acceptance/lib-cli-guard.sh
source "$REPO_ROOT/Scripts/acceptance/lib-cli-guard.sh"

if [[ -z "${SCHOLAR_CLI_BIN:-}" ]]; then
    export SCHOLAR_CLI_BIN="$REPO_ROOT/.build/debug/ScholarOS"
    if [[ ! -x "$SCHOLAR_CLI_BIN" ]]; then
        swift build >/dev/null
    fi
elif [[ ! -x "$SCHOLAR_CLI_BIN" ]]; then
    echo "FAIL: SCHOLAR_CLI_BIN is not an executable file: $SCHOLAR_CLI_BIN" >&2
    exit 2
fi

OUT_JSON="$WORK/hard.diagnostics.json"
OUT_ERR="$WORK/hard.diagnostics.stderr"

python3 -I - "$SCHOLAR_CLI_BIN" "$SCHOLAR_SANDBOX_HOME" "$HARD_TEX" "$EXPECTED_JSON" "$OUT_JSON" "$OUT_ERR" <<'PY'
import collections, json, os, subprocess, sys, time

cli_bin, sandbox_home, hard_tex, expected_path, out_json_path, out_err_path = sys.argv[1:7]

env = dict(os.environ)
env["HOME"] = sandbox_home
env["CFFIXED_USER_HOME"] = sandbox_home
env.pop("SCHOLAR_CACHE_DIR", None)

t0 = time.monotonic()
proc = subprocess.run(
    [cli_bin, "diagnostics", hard_tex, "--offline", "--json", "--lang", "en"],
    env=env,
    capture_output=True,
    text=True,
)
elapsed = time.monotonic() - t0

with open(out_json_path, "w", encoding="utf-8") as f:
    f.write(proc.stdout)
with open(out_err_path, "w", encoding="utf-8") as f:
    f.write(proc.stderr)

if proc.returncode == 2:
    print(f"FAIL [hard-inputs]: CLI returned usage/runtime error (exit=2): {proc.stderr.strip()}")
    sys.exit(1)

try:
    actual = json.loads(proc.stdout)
except Exception as exc:
    print(f"FAIL [hard-inputs]: stdout is not valid JSON ({exc}): {proc.stdout[:200]!r}")
    sys.exit(1)

if not isinstance(actual, dict) or actual.get("schema") != "scholaros.diagnostics/1":
    print(f"FAIL [hard-inputs]: expected scholaros.diagnostics/1 object, got {type(actual).__name__}")
    sys.exit(1)

with open(expected_path, encoding="utf-8") as ef:
    expected = json.load(ef)

actual_cites = set(c["key"] for c in actual.get("citations", []))
expected_cites = set(expected.get("cite_keys", []))

actual_labels = set(l["key"] for l in actual.get("labels", []))
expected_labels = set(expected.get("labels", []))

fake_cites = sorted(k for k in actual_cites if k.startswith("fake"))
fake_labels = sorted(k for k in actual_labels if k.startswith("fake"))

diags = actual.get("diagnostics", [])
structure_errors = [
    d for d in diags
    if d.get("category") == "structure" and d.get("severity") == "ERROR"
]
by_code = collections.Counter(d["code"] for d in structure_errors)

ok = True

if actual_cites == expected_cites:
    print(f"[hard-inputs] cite_keys: 相同 ({len(actual_cites)}/{len(expected_cites)}: {sorted(actual_cites)})")
else:
    ok = False
    extra_c = sorted(actual_cites - expected_cites)
    miss_c = sorted(expected_cites - actual_cites)
    print(
        f"[hard-inputs] cite_keys: 差异 (expected={len(expected_cites)}, actual={len(actual_cites)}; "
        f"only_in_scholaros={extra_c}; only_in_expected={miss_c})"
    )

if actual_labels == expected_labels:
    print(f"[hard-inputs] labels: 相同 ({len(actual_labels)}/{len(expected_labels)}: {sorted(actual_labels)})")
else:
    ok = False
    extra_l = sorted(actual_labels - expected_labels)
    miss_l = sorted(expected_labels - actual_labels)
    print(
        f"[hard-inputs] labels: 差异 (expected={len(expected_labels)}, actual={len(actual_labels)}; "
        f"only_in_scholaros={extra_l}; only_in_expected={miss_l})"
    )

if fake_cites or fake_labels:
    ok = False
    print(f"[hard-inputs] fake* 泄漏: cite_keys={fake_cites}, labels={fake_labels}")
else:
    print("[hard-inputs] fake* 泄漏: 无")

if not structure_errors:
    print("[hard-inputs] structure ERROR: 相同 (0 条)")
else:
    ok = False
    breakdown = ", ".join(f"{k}={by_code[k]}" for k in sorted(by_code))
    print(f"[hard-inputs] structure ERROR: 差异 (expected=0, actual={len(structure_errors)}: {breakdown})")

print(f"[hard-inputs] exit={proc.returncode} elapsed={elapsed:.3f}s")
if elapsed > 1.0:
    ok = False
    print(f"FAIL [hard-inputs]: exceeded 1.0s wall-clock budget ({elapsed:.3f}s)")

if ok:
    print("PASS: hard-inputs")
    sys.exit(0)
else:
    print("FAIL: hard-inputs")
    sys.exit(1)
PY
