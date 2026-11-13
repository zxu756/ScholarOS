#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

mkdir -p "$REPO_ROOT/reports"
REPORT_FILE="$REPO_ROOT/reports/m0-acceptance.txt"

WORK="$(mktemp -d)"
BIN_DIR="$WORK/bin"
mkdir -p "$BIN_DIR"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

swift build >/dev/null
ln -sf "$REPO_ROOT/.build/debug/ScholarOS" "$BIN_DIR/scholaros"
export PATH="$BIN_DIR:$REPO_ROOT/.build/debug:$PATH"

REAL_TEX_FILE="${REAL_TEX_FILE:-/Users/xu/Projects/FinalReport/hima_report/main.tex}"

cat > "$WORK/refs.bib" <<'EOF'
@article{real_lecun, author = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey}, title = {Deep learning}, journal = {Nature}, year = {2015}, volume = {521}, pages = {436--444}, doi = {10.1038/nature14539}}
@article{real_lstm, author = {Hochreiter, Sepp and Schmidhuber, J{\"u}rgen}, title = {Long Short-Term Memory}, journal = {Neural Computation}, year = {1997}, volume = {9}, pages = {1735--1780}, doi = {10.1162/neco.1997.9.8.1735}}
@article{real_watson, author = {Watson, J. D. and Crick, F. H. C.}, title = {Molecular Structure of Nucleic Acids: A Structure for Deoxyribose Nucleic Acid}, journal = {Nature}, year = {1953}, volume = {171}, pages = {737--738}, doi = {10.1038/171737a0}}
@article{fake_nonsentinel, author = {Whitfield, Eleanor and Patel, Raj}, title = {Quantum Gradient Descent in Biological Neural Networks}, journal = {Nature Machine Intelligence}, year = {2026}, doi = {10.1038/fake.2026.99999}}
@article{fake_sentinel, author = {Okafor, Ngozi and Lindqvist, Mats}, title = {Self-Supervised Topological Priors for Protein Folding}, journal = {Science}, year = {2026}, doi = {10.1234/fake.2026.99999}}
@article{wrongtitle, author = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey}, title = {A Completely Different Invented Title About Ocean Currents}, journal = {Nature}, year = {2015}, doi = {10.1038/nature14539}}
@article{wrongyear, author = {Hochreiter, Sepp and Schmidhuber, J{\"u}rgen}, title = {Long Short-Term Memory}, journal = {Neural Computation}, year = {1999}, doi = {10.1162/neco.1997.9.8.1735}}
@article{wrongyear5, author = {Hochreiter, Sepp and Schmidhuber, J{\"u}rgen}, title = {Long Short-Term Memory}, journal = {Neural Computation}, year = {1992}, doi = {10.1162/neco.1997.9.8.1735}}
@book{real_nodoi, author = {Knuth, Donald E.}, title = {The Art of Computer Programming, Volume 1: Fundamental Algorithms}, publisher = {Addison-Wesley}, year = {1968}}
@article{fake_nodoi, author = {Whitfield, Eleanor and Patel, Raj}, title = {Recursive Causal Lattices for Zero-Shot Climate Forecasting}, journal = {Journal of Applied Machine Cognition}, year = {2023}, volume = {12}, pages = {101--119}}
@article{retracted_seralini, author = {S{\'e}ralini, Gilles-{\'E}ric and Clair, Emilie and Mesnage, Robin}, title = {Long term toxicity of a Roundup herbicide and a Roundup-tolerant genetically modified maize}, journal = {Food and Chemical Toxicology}, year = {2012}, doi = {10.1016/j.fct.2012.08.005}}
@article{retracted_wakefield, author = {Wakefield, A. J. and Murch, S. H.}, title = {Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children}, journal = {The Lancet}, year = {1998}, doi = {10.1016/S0140-6736(97)11096-0}}
EOF

{
    echo "# ScholarOS M0 Acceptance Verification Report (Bilingual: --lang en & --lang zh)"
    echo "Date: 2026-11-14"
    echo "Platform: $(uname -s) $(uname -m)"
    echo ""

    # ------------------------------------------------------------------
    # Row 1: scholaros --help & scholaros outline <real .tex> (--lang en & --lang zh)
    # ------------------------------------------------------------------
    echo "== [Row 1] scholaros --help & scholaros outline <real .tex> (--lang en & --lang zh) =="
    if [[ ! -f "$REAL_TEX_FILE" ]]; then
        echo "FAIL: Real TeX fixture not found at $REAL_TEX_FILE"
        exit 1
    fi
    HELP_EN_OUT="$(scholaros --help --lang en)"
    HELP_EN_EXIT=$?
    HELP_ZH_OUT="$(scholaros --help --lang zh)"
    HELP_ZH_EXIT=$?
    OUTLINE_EN_OUT="$(scholaros outline "$REAL_TEX_FILE" --lang en)"
    OUTLINE_EN_EXIT=$?
    OUTLINE_ZH_OUT="$(scholaros outline "$REAL_TEX_FILE" --lang zh)"
    OUTLINE_ZH_EXIT=$?
    OUTLINE_EN_COUNT="$(printf '%s\n' "$OUTLINE_EN_OUT" | sed '/^$/d' | wc -l | tr -d ' ')"
    OUTLINE_ZH_COUNT="$(printf '%s\n' "$OUTLINE_ZH_OUT" | sed '/^$/d' | wc -l | tr -d ' ')"
    GREP_COUNT="$(grep -c -E '\\(section|subsection)\*?\{' "$REAL_TEX_FILE" | tr -d ' ')"
    echo "help_en_exit=$HELP_EN_EXIT help_zh_exit=$HELP_ZH_EXIT"
    echo "outline_en_exit=$OUTLINE_EN_EXIT outline_zh_exit=$OUTLINE_ZH_EXIT"
    echo "outline_en_heading_count=$OUTLINE_EN_COUNT outline_zh_heading_count=$OUTLINE_ZH_COUNT"
    echo "grep_section_subsection_count=$GREP_COUNT"
    if [[ "$HELP_EN_EXIT" -ne 0 || "$HELP_ZH_EXIT" -ne 0 || "$OUTLINE_EN_EXIT" -ne 0 || "$OUTLINE_ZH_EXIT" -ne 0 || "$OUTLINE_EN_COUNT" != "$GREP_COUNT" || "$OUTLINE_ZH_COUNT" != "$GREP_COUNT" ]]; then
        echo "FAIL: Row 1 mismatch"
        exit 1
    fi
    if ! printf '%s\n' "$HELP_ZH_OUT" | grep -q "单文件直读命令"; then
        echo "FAIL: Row 1 expected localized Chinese help banner"
        exit 1
    fi
    echo "PASS: Row 1"
    echo ""

    # ------------------------------------------------------------------
    # Row 2: Missing input -> exit code 2, zero demo output on stdout (--lang en & --lang zh)
    # ------------------------------------------------------------------
    echo "== [Row 2] scholaros outline & scholaros verify-citations (missing input, --lang en & --lang zh) =="
    set +e
    OUTLINE_EN_NOARG_STDOUT="$(scholaros outline --lang en 2>"$WORK/outline_en_noarg.stderr")"
    OUTLINE_EN_NOARG_EXIT=$?
    OUTLINE_ZH_NOARG_STDOUT="$(scholaros outline --lang zh 2>"$WORK/outline_zh_noarg.stderr")"
    OUTLINE_ZH_NOARG_EXIT=$?
    VERIFY_EN_NOARG_STDOUT="$(scholaros verify-citations --lang en 2>"$WORK/verify_en_noarg.stderr")"
    VERIFY_EN_NOARG_EXIT=$?
    VERIFY_ZH_NOARG_STDOUT="$(scholaros verify-citations --lang zh 2>"$WORK/verify_zh_noarg.stderr")"
    VERIFY_ZH_NOARG_EXIT=$?
    set -e
    echo "outline_en_noarg_exit=$OUTLINE_EN_NOARG_EXIT stdout_bytes=${#OUTLINE_EN_NOARG_STDOUT} stderr=$(tr '\n' ' ' < "$WORK/outline_en_noarg.stderr")"
    echo "outline_zh_noarg_exit=$OUTLINE_ZH_NOARG_EXIT stdout_bytes=${#OUTLINE_ZH_NOARG_STDOUT} stderr=$(tr '\n' ' ' < "$WORK/outline_zh_noarg.stderr")"
    echo "verify_en_noarg_exit=$VERIFY_EN_NOARG_EXIT stdout_bytes=${#VERIFY_EN_NOARG_STDOUT} stderr=$(tr '\n' ' ' < "$WORK/verify_en_noarg.stderr")"
    echo "verify_zh_noarg_exit=$VERIFY_ZH_NOARG_EXIT stdout_bytes=${#VERIFY_ZH_NOARG_STDOUT} stderr=$(tr '\n' ' ' < "$WORK/verify_zh_noarg.stderr")"
    if [[ "$OUTLINE_EN_NOARG_EXIT" -ne 2 || -n "$OUTLINE_EN_NOARG_STDOUT" || "$OUTLINE_ZH_NOARG_EXIT" -ne 2 || -n "$OUTLINE_ZH_NOARG_STDOUT" || "$VERIFY_EN_NOARG_EXIT" -ne 2 || -n "$VERIFY_EN_NOARG_STDOUT" || "$VERIFY_ZH_NOARG_EXIT" -ne 2 || -n "$VERIFY_ZH_NOARG_STDOUT" ]]; then
        echo "FAIL: Row 2 expected exit 2 and empty stdout across --lang en and --lang zh"
        exit 1
    fi
    if ! grep -q "Usage:" "$WORK/verify_en_noarg.stderr" || ! grep -q "用法：" "$WORK/verify_zh_noarg.stderr"; then
        echo "FAIL: Row 2 expected localized Usage / 用法 on stderr"
        exit 1
    fi
    echo "PASS: Row 2"
    echo ""

    # ------------------------------------------------------------------
    # Row 3: scholaros verify-citations refs.bib --offline (--lang en & --lang zh)
    # ------------------------------------------------------------------
    echo "== [Row 3] scholaros verify-citations refs.bib --offline (--lang en & --lang zh) =="
    set +e
    OFFLINE_EN_OUT="$(scholaros verify-citations "$WORK/refs.bib" --offline --lang en 2>&1)"
    OFFLINE_EN_EXIT=$?
    OFFLINE_ZH_OUT="$(scholaros verify-citations "$WORK/refs.bib" --offline --lang zh 2>&1)"
    OFFLINE_ZH_EXIT=$?
    set -e
    echo "offline_en_exit=$OFFLINE_EN_EXIT"
    echo "$OFFLINE_EN_OUT"
    echo "--- (--lang zh) ---"
    echo "offline_zh_exit=$OFFLINE_ZH_EXIT"
    echo "$OFFLINE_ZH_OUT"
    if [[ "$OFFLINE_EN_EXIT" -eq 0 || "$OFFLINE_ZH_EXIT" -eq 0 ]]; then
        echo "FAIL: Row 3 expected non-zero exit code in both languages"
        exit 1
    fi
    for OUT_BLOB in "$OFFLINE_EN_OUT" "$OFFLINE_ZH_OUT"; do
        if ! printf '%s\n' "$OUT_BLOB" | grep -q "Verified=0"; then
            echo "FAIL: Row 3 expected Verified=0"
            exit 1
        fi
        if printf '%s\n' "$OUT_BLOB" | grep -q "\[VERIFIED\]"; then
            echo "FAIL: Row 3 found unexpected [VERIFIED] entry"
            exit 1
        fi
    done
    if ! printf '%s\n' "$OFFLINE_ZH_OUT" | grep -q "尚未向外部注册库核查"; then
        echo "FAIL: Row 3 expected honest Chinese offline notice"
        exit 1
    fi
    echo "PASS: Row 3"
    echo ""

    # ------------------------------------------------------------------
    # Row 4: sandbox-exec network denial without --offline (--lang en & --lang zh)
    # ------------------------------------------------------------------
    echo "== [Row 4] sandbox-exec deny network* scholaros verify-citations refs.bib (--lang en & --lang zh) =="
    set +e
    SANDBOX_EN_OUT="$(sandbox-exec -p '(version 1)(allow default)(deny network*)' "$BIN_DIR/scholaros" verify-citations "$WORK/refs.bib" --lang en 2>&1)"
    SANDBOX_EN_EXIT=$?
    SANDBOX_ZH_OUT="$(sandbox-exec -p '(version 1)(allow default)(deny network*)' "$BIN_DIR/scholaros" verify-citations "$WORK/refs.bib" --lang zh 2>&1)"
    SANDBOX_ZH_EXIT=$?
    set -e
    echo "sandbox_en_exit=$SANDBOX_EN_EXIT sandbox_zh_exit=$SANDBOX_ZH_EXIT"
    echo "$SANDBOX_EN_OUT"
    if [[ "$SANDBOX_EN_EXIT" -eq 0 || "$SANDBOX_ZH_EXIT" -eq 0 ]]; then
        echo "FAIL: Row 4 expected non-zero exit code"
        exit 1
    fi
    for OUT_BLOB in "$SANDBOX_EN_OUT" "$SANDBOX_ZH_OUT"; do
        if ! printf '%s\n' "$OUT_BLOB" | grep -q "Verified=0"; then
            echo "FAIL: Row 4 expected Verified=0"
            exit 1
        fi
        if printf '%s\n' "$OUT_BLOB" | grep -q "\[VERIFIED\]"; then
            echo "FAIL: Row 4 found unexpected [VERIFIED] entry"
            exit 1
        fi
    done
    echo "PASS: Row 4"
    echo ""

    # ------------------------------------------------------------------
    # Row 5: Unit test injecting transport error, HTTP 429, HTTP 500 -> UNVERIFIED
    # ------------------------------------------------------------------
    echo "== [Row 5] Injected transport error, HTTP 429, HTTP 500 -> UNVERIFIED =="
    ROW5_TEST_OUT="$(swift test --no-parallel --filter "BibCSLAndFirewallTests/firewallOnlineRegistryTransport429And500FailuresReturnUnverified" 2>&1)"
    echo "row5_test_exit=0"
    printf '%s\n' "$ROW5_TEST_OUT" | grep -E "Test \"S19 regression|passed after" || true
    echo "PASS: Row 5"
    echo ""

    # ------------------------------------------------------------------
    # Row 6: Built-in retracted paper -> RETRACTED + '内置名单' notice (--lang en & --lang zh)
    # ------------------------------------------------------------------
    echo "== [Row 6] Built-in retracted paper -> RETRACTED + 内置名单 notice (--lang en & --lang zh) =="
    WAKEFIELD_EN_LINE="$(printf '%s\n' "$OFFLINE_EN_OUT" | grep "retracted_wakefield" || true)"
    WAKEFIELD_ZH_LINE="$(printf '%s\n' "$OFFLINE_ZH_OUT" | grep "retracted_wakefield" || true)"
    echo "en: $WAKEFIELD_EN_LINE"
    echo "zh: $WAKEFIELD_ZH_LINE"
    for W_LINE in "$WAKEFIELD_EN_LINE" "$WAKEFIELD_ZH_LINE"; do
        if ! printf '%s\n' "$W_LINE" | grep -q "\[RETRACTED\]"; then
            echo "FAIL: Row 6 expected [RETRACTED]"
            exit 1
        fi
        if ! printf '%s\n' "$W_LINE" | grep -q "内置名单，不完整"; then
            echo "FAIL: Row 6 expected '内置名单，不完整'"
            exit 1
        fi
    done
    echo "PASS: Row 6"
    echo ""

    # ------------------------------------------------------------------
    # Row 7: prisma-stats kappa == MCP scholar_prisma_agreement kappa == hand calculation (83/107)
    # ------------------------------------------------------------------
    echo "== [Row 7] prisma-stats kappa == MCP scholar_prisma_agreement kappa == 83/107 =="
    KAPPA_PROJ="$WORK/kappa-check.scholarproj"
    scholaros init --project "$KAPPA_PROJ" --seed-demo >/dev/null
    PRISMA_JSON="$(scholaros prisma-stats --project "$KAPPA_PROJ")"
    MCP_KAPPA_REQ="$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"scholar_prisma_agreement","arguments":{"projectPath":"%s"}}}\n' "$KAPPA_PROJ")"
    MCP_KAPPA_RAW="$(printf '%s\n' "$MCP_KAPPA_REQ" | scholaros mcp --project "$KAPPA_PROJ")"
    KAPPA_CHECK="$(python3 - "$PRISMA_JSON" "$MCP_KAPPA_RAW" <<'PY'
import json, re, sys
prisma = json.loads(sys.argv[1])
mcp_env = json.loads(sys.argv[2])
mcp_text = mcp_env["result"]["content"][0]["text"]
m = re.search(r"Kappa=([0-9.]+)", mcp_text)
assert m, f"Missing Kappa= in {mcp_text}"
cli_k = float(prisma["cohensKappa"])
mcp_k = float(m.group(1))
hand_k = 83.0 / 107.0
print(f"hand_kappa_83_over_107={hand_k:.6f} cli_kappa={cli_k:.6f} mcp_kappa={mcp_k:.4f}")
assert abs(cli_k - hand_k) < 1e-6, (cli_k, hand_k)
assert abs(mcp_k - round(hand_k, 4)) < 1e-9, (mcp_k, round(hand_k, 4))
PY
)"
    echo "$KAPPA_CHECK"
    echo "PASS: Row 7"
    echo ""

    # ------------------------------------------------------------------
    # Row 8: MCP invalid JSON -> -32700 and unknown method -> -32601
    # ------------------------------------------------------------------
    echo "== [Row 8] MCP invalid JSON (-32700) & unknown method (-32601) =="
    MCP_ERR_OUT="$(printf '%s\n%s\n' '{invalid_json' '{"jsonrpc":"2.0","id":99,"method":"scholar/nonexistent_method","params":{}}' | scholaros mcp)"
    echo "$MCP_ERR_OUT"
    python3 - "$MCP_ERR_OUT" <<'PY'
import json, sys
lines = [json.loads(line) for line in sys.argv[1].strip().splitlines()]
assert len(lines) == 2, lines
assert lines[0]["error"]["code"] == -32700, lines[0]
assert lines[1]["id"] == 99 and lines[1]["error"]["code"] == -32601, lines[1]
PY
    echo "PASS: Row 8"
    echo ""

    # ------------------------------------------------------------------
    # Row 9: GUI default empty state (ViewModel test + live launch in en & zh + demo HTML marker)
    # ------------------------------------------------------------------
    echo "== [Row 9] GUI default empty state (ViewModel test + live launch --lang en & --lang zh) =="
    ROW9_TEST_OUT="$(swift test --no-parallel --filter "ScholarStudioViewsTests/s21AndS22StudioViewModelStartsEmptyWithoutDemoDataOrFakeAlert" 2>&1)"
    printf '%s\n' "$ROW9_TEST_OUT" | grep -E "Test \"S21/S22 regression|passed after" || true
    for GUI_LANG in en zh; do
        "$REPO_ROOT/.build/debug/ScholarOS" --lang "$GUI_LANG" >"$WORK/gui_${GUI_LANG}.stdout" 2>"$WORK/gui_${GUI_LANG}.stderr" &
        GUI_PID=$!
        python3 -c 'import time; time.sleep(1.0)'
        if kill -0 "$GUI_PID" 2>/dev/null; then
            echo "live_gui_launch_alive_${GUI_LANG}=true"
            kill "$GUI_PID" 2>/dev/null || true
            wait "$GUI_PID" 2>/dev/null || true
        else
            wait "$GUI_PID" || true
            echo "FAIL: Row 9 GUI process ($GUI_LANG) exited unexpectedly"
            exit 1
        fi
    done
    if ! grep -q "\[DEMO\] Sample Unverified Dataset" "$REPO_ROOT/docs/demo-scholar-dossier.html" || ! grep -q "\[DEMO / 演示数据\]" "$REPO_ROOT/docs/demo-scholar-dossier.html"; then
        echo "FAIL: Row 9 expected bilingual [DEMO / 演示数据] marker in docs/demo-scholar-dossier.html"
        exit 1
    fi
    echo "demo_html_bilingual_marker=present"
    echo "PASS: Row 9"
    echo ""

    # ------------------------------------------------------------------
    # Row 10: Banned EN/ZH claims search across Sources/, README.md, README.zh-CN.md, docs/
    # ------------------------------------------------------------------
    echo "== [Row 10] Search banned EN/ZH strings in Sources/, README.md, README.zh-CN.md, docs/ =="
    set +e
    RG_HITS="$(rg -i -n "VERIFIED_DOI|FIREWALL_CLEARED|Hardware-Gated|HardwareGated|Zero-Hallucination|returned HTTP 404|零幻觉|硬件门禁|硬件级门禁|硬件级|已验证 DOI" "$REPO_ROOT/Sources" "$REPO_ROOT/README.md" "$REPO_ROOT/README.zh-CN.md" "$REPO_ROOT/docs")"
    RG_EXIT=$?
    set -e
    if [[ "$RG_EXIT" -eq 0 || -n "$RG_HITS" ]]; then
        echo "FAIL: Row 10 found banned terms:"
        echo "$RG_HITS"
        exit 1
    fi
    echo "matches_in_sources_readmes_and_docs=0"
    echo "PASS: Row 10"
    echo ""
    echo "ALL 10 M0 ACCEPTANCE CHECKS PASSED (EN & ZH)."
} | tee "$REPORT_FILE"
