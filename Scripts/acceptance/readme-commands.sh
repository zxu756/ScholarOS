#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

mkdir -p "$REPO_ROOT/reports"
REPORT_FILE="$REPO_ROOT/reports/readme-commands.txt"

{
    echo "# ScholarOS README & README.zh-CN Command Replay"
    echo "Date: 2026-11-14"
    echo ""

    echo "$ swift build"
    swift build
    export PATH="$PWD/.build/debug:$PATH"

    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT

    cat > "$WORK/paper.tex" <<'EOF'
\documentclass{article}
\begin{document}
\section{Introduction}
\subsection{Problem Statement}
Prior work \cite{lecun2015deep} motivates this study.
\end{document}
EOF

    cat > "$WORK/refs.bib" <<'EOF'
@article{lecun2015deep,
  author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
  title   = {Deep learning},
  journal = {Nature},
  year    = {2015},
  volume  = {521},
  pages   = {436--444},
  doi     = {10.1038/nature14539}
}
@article{wakefield1998retracted,
  author  = {Wakefield, A. J.},
  title   = {Ileal-lymphoid-nodular hyperplasia},
  journal = {The Lancet},
  year    = {1998},
  doi     = {10.1016/S0140-6736(97)11096-0}
}
EOF

    echo ""
    echo "$ ScholarOS outline \"\$WORK/paper.tex\" --lang en"
    ScholarOS outline "$WORK/paper.tex" --lang en

    echo ""
    echo "$ ScholarOS outline \"\$WORK/paper.tex\" --lang zh"
    ScholarOS outline "$WORK/paper.tex" --lang zh

    echo ""
    echo "$ ScholarOS format-bib \"\$WORK/refs.bib\" --style apa"
    ScholarOS format-bib "$WORK/refs.bib" --style apa

    echo ""
    echo "$ ScholarOS format-bib \"\$WORK/refs.bib\" --style ieee"
    ScholarOS format-bib "$WORK/refs.bib" --style ieee

    echo ""
    echo "$ ScholarOS diagnostics \"\$WORK/paper.tex\" --bib \"\$WORK/refs.bib\" --lang en"
    ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --lang en

    echo ""
    echo "$ ScholarOS diagnostics \"\$WORK/paper.tex\" --bib \"\$WORK/refs.bib\" --lang zh"
    ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --lang zh

    echo ""
    echo "$ ScholarOS verify-citations \"\$WORK/refs.bib\" --offline --lang en || echo \"expected_exit=\$?\""
    ScholarOS verify-citations "$WORK/refs.bib" --offline --lang en || echo "expected_exit=$?"

    echo ""
    echo "$ ScholarOS verify-citations \"\$WORK/refs.bib\" --offline --lang zh || echo \"expected_exit=\$?\""
    ScholarOS verify-citations "$WORK/refs.bib" --offline --lang zh || echo "expected_exit=$?"

    echo ""
    echo "$ printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}' | ScholarOS mcp"
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ScholarOS mcp

    echo ""
    echo "$ Scripts/test.sh scope ScholarBibAndCSL"
    Scripts/test.sh scope ScholarBibAndCSL

    echo ""
    echo "README & README.zh-CN COMMAND REPLAY PASSED."
} | tee "$REPORT_FILE"
