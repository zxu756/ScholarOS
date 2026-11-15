# ScholarOS

**[English](README.md)** | **简体中文**

面向 macOS 的 Swift 包与中英双语（`--lang zh|en`）命令行工具（`scholaros`），提供 LaTeX/BibTeX 解析、APA 7th / IEEE 参考文献排版、公开学术注册库引文核查、信度与 Meta 分析统计计算库，以及基于标准输入输出的 JSON-RPC 2.0 MCP 服务端。

> **当前状态说明（M1 进行中）：** `scholaros verify-citations`、MCP `scholar_verify_bibliography` 与 `scholaros diagnostics` 共用同一引文核查函数，默认联网查询公开学术注册库（Crossref、OpenAlex、`doi.org`、arXiv、PubMed），带本地 SQLite 响应缓存、限速与退避重试；`--offline` 不发任何网络请求，`--registry-replay <目录>` 从 SHA-256 校验通过的录制目录离线回放（输出带 `REPLAY` 标记），`--no-cache` 跳过缓存读写。插入前核查与结论写回/有效期（`cite`、`scholar_cite_key`、`.bib` `x-firewall-class`）及 480 条基准集（`Benchmarks/citations/`）评测仍在 M1 后续阶段推进中。macOS 桌面窗口启动默认为空，当前**仅在显式传入 `--demo` 或点击“载入演示数据”时展示内置未核查示例数据**。

---

## 已验证能力（2026-11-14）

以下全部数值均来自 [`reports/m0-acceptance.txt`](reports/m0-acceptance.txt) 与 [`reports/readme-commands.txt`](reports/readme-commands.txt)（2026-11-14 于 macOS arm64 执行 `Scripts/test.sh milestone 0 --record` 实测记录；不带 `--record` 时跑同样的检查，报告写到临时目录）：

- **LaTeX 章节大纲与静态诊断（`scholaros outline`、`scholaros diagnostics`）**：支持直接读取 `.tex` 源文件而无需先创建工程包。在仓库自带的 449 行 IEEEtran 风格样稿 [`Fixtures/sample-ieeetran-manuscript.tex`](Fixtures/sample-ieeetran-manuscript.tex)（内容是为本仓库虚构的，任何人都能重跑这项检查）上，`scholaros outline` 在 `--lang en` 与 `--lang zh` 下均提取出全部 `46` 个 `\section` / `\subsection` 标题（带星号和不带星号的都有），与 `grep -c -E '\\(section|subsection)\*?\{'` 的计数一致（2026-11-14 实测）。
- **BibTeX 解析与 APA 7th / IEEE 参考文献格式化（`scholaros format-bib`）**：直接解析 `.bib` 文件并输出 APA 7th（`--style apa`）与 IEEE（`--style ieee`）格式参考文献列表，支持常见 LaTeX 重音转义与花括号大小写保护。
- **引文核查（`scholaros verify-citations`、`scholaros cache clear`）**：使用五类状态（`VERIFIED`、`DRIFT`、`NOT_FOUND`、`RETRACTED`、`UNVERIFIED`），支持 `--lang en`、`--lang zh` 与 `--json` 输出：
  - 默认联网查询 Crossref、OpenAlex、`doi.org`、arXiv 与 PubMed，并将可缓存响应写入本地 SQLite（默认 `~/Library/Caches/ScholarOS/registry.sqlite`，或 `$SCHOLAR_CACHE_DIR/registry.sqlite`）；`--no-cache` 本次运行不读写缓存，`scholaros cache clear` 删除当前生效位置的 `registry.sqlite`（含 `-wal`/`-shm`），`--verbose` 每查一次向标准错误输出一行（数据源、地址、状态码、耗时与来源）。
  - `--offline` 不发任何网络请求且不读写缓存，仅检查标识符格式与不完整的 8 条内置撤稿 DOI 名单（`--lang zh` 下注明 `内置名单，不完整`，`--lang en` 下为 `built-in list, incomplete`）；未联网查询的合法标识符标为 `UNVERIFIED`。
  - `--registry-replay <目录>` 从 SHA-256 校验通过的本地录制目录离线回放（不发网络请求；默认不读写缓存，仅在显式设置 `SCHOLAR_CACHE_DIR` 时读写该目录缓存，绝不触碰默认缓存目录），输出带 `REPLAY` 标记。
  - 语法格式损坏的标识符标为 `NOT_FOUND`（`invalid_identifier`）；`10.0000/`、`10.1234/`、`10.9999/` 等前缀在 ISO 26324 语法上合法，不在离线阶段直接判为不存在。
  - 退出码：全部 `VERIFIED` 返回 `0`；存在 `DRIFT`、`NOT_FOUND` 或 `RETRACTED` 返回 `1`；无上述三类但存在 `UNVERIFIED` 返回 `3`；参数、文件不存在、BibTeX 解析失败或回放错误返回 `2`。
- **评分者间一致性信度与统计计算库（`ScholarPRISMAEngine`、`ScholarPluginSDK`）**：包含多分类名义变量 Cohen's $\kappa$、Brennan-Prediger PABAK、Gwet's $AC_1$、Fleiss' $\kappa$、DerSimonian-Laird 随机效应合成及 Lanczos/Lentz $t$/$F$/$\chi^2$ 分布计算。在 12 项研究、5 分类双人盲筛数据集上，`scholaros prisma-stats` 与 MCP `scholar_prisma_agreement` 均算得 $\kappa = 0.7757$，与闭式手算精确值 $83/107 \approx 0.775701$ 一致（[`reports/m0-acceptance.txt`](reports/m0-acceptance.txt)，2026-11-14）。
- **JSON-RPC 2.0 MCP 服务端（`scholaros mcp`）**：基于 stdio 的 JSON-RPC 2.0 服务端，对非法 JSON 返回标准 `-32700`（`Parse error`），对未知方法名返回 `-32601`（`Method not found`）；支持 `--offline`、`--registry-replay <目录>` 与 `--no-cache`，并在同一进程的多次调用间共用限速器。
- **中英双语切换（`--lang zh|en`）**：命令行诊断、引文核查说明、参数用法错误提示、桌面界面（`⇧⌘L`）及独立 HTML 审计简报（[`docs/demo-scholar-dossier.html`](docs/demo-scholar-dossier.html)，顶部显式标注 `[DEMO / 演示数据]`）均支持简体中文与英文切换。

---

## 编译与可复现命令示例

[`Scripts/acceptance/readme-commands.sh`](Scripts/acceptance/readme-commands.sh) 直接从本文件（以及 [`README.md`](README.md) 的同一段）的代码块里取出命令，在仓库根目录原样执行；两份文件的命令不一致时脚本报错。完整输出保存在 [`reports/readme-commands.txt`](reports/readme-commands.txt) 中。

```bash
swift build
export PATH="$PWD/.build/debug:$PATH"

WORK="$(mktemp -d)"
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

# 1. 提取 LaTeX 章节大纲（先英文输出，再中文输出）
ScholarOS outline "$WORK/paper.tex" --lang en
ScholarOS outline "$WORK/paper.tex" --lang zh

# 2. 按 APA 7th 与 IEEE 样式格式化 BibTeX 文献
ScholarOS format-bib "$WORK/refs.bib" --style apa
ScholarOS format-bib "$WORK/refs.bib" --style ieee

# 3. 结合 refs.bib 对 paper.tex 运行录制回放诊断（先英文输出，再中文输出）
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --registry-replay Tests/Fixtures/registry --lang en
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --registry-replay Tests/Fixtures/registry --lang zh

# 4. 引文核查：离线（--offline）与录制回放（--registry-replay，输出带 REPLAY 标记）
ScholarOS verify-citations "$WORK/refs.bib" --offline --lang en || echo "expected_exit=$?"
ScholarOS verify-citations "$WORK/refs.bib" --registry-replay Tests/Fixtures/registry --lang en || echo "expected_exit=$?"

# 5. 通过标准输入输出验证 JSON-RPC 2.0 MCP 握手（--offline）
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ScholarOS mcp --offline

# 6. 在 Fixtures/ 自带的样稿上复现上文引用的标题数
ScholarOS outline Fixtures/sample-ieeetran-manuscript.tex | grep -c .
grep -c -E '\\(section|subsection)\*?\{' Fixtures/sample-ieeetran-manuscript.tex

rm -rf "$WORK"
```

### 按模块运行单测

运行完整 M0 验收（涉及模块单测 + `Scripts/acceptance/m0-acceptance.sh` + `Scripts/acceptance/readme-commands.sh`）可执行 `Scripts/test.sh milestone 0`。它不打开任何窗口，不改动工作区，报告写到临时目录；加 `--record` 才会更新 `reports/`。单独运行某一模块单测：

```bash
Scripts/test.sh scope ScholarBibAndCSL
```

---

## 当前边界与后续计划

- **桌面端界面（不带子命令运行 `ScholarOS`）**：默认打开空白窗口（`0` 份手稿、`0` 条文献），当前尚不能直接打开用户本地 `.tex`、`.bib` 或 `.pdf` 文件，**仅在传入 `--demo` 或点击“载入演示数据”时查看内置未核查示例数据**（顶部带有 `DEMO / 演示数据` 横幅）。
- **M1 剩余项（联网引文核验）**：接入 `cite`、`scholar_cite_key` 插入前核查及 `.bib` `x-firewall-class` / 工程库结论有效期规则；并在 480 条标注基准集（`Benchmarks/citations/`）上评测准确率与误拒率。
- **M2 计划（解析器、PDF 切分与 CiteStudio 对齐）**：完善 LaTeX `\verb`、`verbatim`、`lstlisting`、`\url{%}` 与 `\bibitem` 解析；支持 BibTeX 单条语法错误后的恢复解析；修复 APA 标题大小写与 IEEE 专著格式；改进双栏 PDF 章节标题与跨栏表格切分；暴露与 CiteStudio 对齐的 MCP 工具名称。
- **冻结模块（尚未完成端到端验收，M3 之后再议）**：引文图谱分析（力导向布局、PageRank、Louvain 聚类、Kleinberg 突现检测、主路径分析）、PRISMA 筛查界面、偏倚风险与 Meta 分析界面、Myers 修订追踪界面、投稿归档打包器、Zotero SQLite 桥接、Typst 支持、`JavaScriptCore` 审稿插件、持久化撤销/重做以及仅用于测试的合成 PDF 生成器。

---

## 开源许可

MIT License. Copyright (c) 2026 Xu (`zxu756`).
