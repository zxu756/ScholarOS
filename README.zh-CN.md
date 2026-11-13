# ScholarOS

**[English](README.md)** | **简体中文**

面向 macOS 的 Swift 包与中英双语（`--lang zh|en`）命令行工具（`scholaros`），提供 LaTeX/BibTeX 解析、APA 7th / IEEE 参考文献排版、离线引文结构检查、信度与 Meta 分析统计计算库，以及基于标准输入输出的 JSON-RPC 2.0 MCP 服务端。

> **当前状态说明（M0，2026-11-14）：** 外部文献注册库联网查询（Crossref、OpenAlex、arXiv、PubMed）**尚未接入**命令行与 MCP 入口（计划在 M1 接入）。在 M0 阶段，`scholaros verify-citations` 仅执行离线标识符语法校验与 8 条内置撤稿 DOI 提示名单比对；对未向外部注册库核实的条目**绝不**标为 `VERIFIED`，且只要存在任一条目非 `VERIFIED` 即以退出码 `1` 退出。macOS 桌面窗口启动默认为空，当前**仅在显式传入 `--demo` 或点击“载入演示数据”时展示内置未核查示例数据**。

---

## 已验证能力（2026-11-14）

以下全部数值均来自 [`reports/m0-acceptance.txt`](reports/m0-acceptance.txt) 与 [`reports/readme-commands.txt`](reports/readme-commands.txt)（2026-11-14 于 macOS arm64 执行 `Scripts/test.sh milestone 0` 实测记录）：

- **LaTeX 章节大纲与静态诊断（`scholaros outline`、`scholaros diagnostics`）**：支持直接读取 `.tex` 源文件而无需先创建工程包。在一份 759 行的 IEEEtran 真实手稿上，`scholaros outline` 在 `--lang en` 与 `--lang zh` 下均准确提取全部 `40` 个 `\section` / `\subsection` 标题，与 `grep -c -E '\\(section|subsection)\*?\{'`（`40`；2026-11-14 实测）完全一致。
- **BibTeX 解析与 APA 7th / IEEE 参考文献格式化（`scholaros format-bib`）**：直接解析 `.bib` 文件并输出 APA 7th（`--style apa`）与 IEEE（`--style ieee`）格式参考文献列表，支持常见 LaTeX 重音转义与花括号大小写保护。
- **离线引文语法与撤稿提示检查（`scholaros verify-citations`）**：使用五类状态（`VERIFIED`、`DRIFT`、`NOT_FOUND`、`RETRACTED`、`UNVERIFIED`），支持 `--lang en` 与 `--lang zh` 输出：
  - 离线检查（`verify-citations <refs.bib> [--offline]`）将语法合法的 DOI、arXiv ID 与 PMID 标为 `UNVERIFIED`（说明尚未向外部注册库核查）。
  - 格式损坏或占位测试前缀（`10.0000/`、`10.1000/`、`10.1234/`、`10.9999/`）标为 `NOT_FOUND`。
  - 命中 8 条内置撤稿 DOI 名单的条目返回 `RETRACTED`，并在中英文输出中均显式注明 `内置名单，不完整`。
  - 只要任意一条文献不是 `VERIFIED`，命令退出码即为 `1`。
- **评分者间一致性信度与统计计算库（`ScholarPRISMAEngine`、`ScholarPluginSDK`）**：包含多分类名义变量 Cohen's $\kappa$、Brennan-Prediger PABAK、Gwet's $AC_1$、Fleiss' $\kappa$、DerSimonian-Laird 随机效应合成及 Lanczos/Lentz $t$/$F$/$\chi^2$ 分布计算。在 12 项研究、5 分类双人盲筛数据集上，`scholaros prisma-stats` 与 MCP `scholar_prisma_agreement` 均算得 $\kappa = 0.7757$，与闭式手算精确值 $83/107 \approx 0.775701$ 一致（[`reports/m0-acceptance.txt`](reports/m0-acceptance.txt)，2026-11-14）。
- **JSON-RPC 2.0 MCP 服务端（`scholaros mcp`）**：基于 stdio 的 JSON-RPC 2.0 服务端，对非法 JSON 返回标准 `-32700`（`Parse error`），对未知方法名返回 `-32601`（`Method not found`）。
- **中英双语切换（`--lang zh|en`）**：命令行诊断、引文核查说明、参数用法错误提示、桌面界面（`⇧⌘L`）及独立 HTML 审计简报（[`docs/demo-scholar-dossier.html`](docs/demo-scholar-dossier.html)，顶部显式标注 `[DEMO / 演示数据]`）均支持简体中文与英文切换。

---

## 编译与可复现命令示例

下列命令由 [`Scripts/acceptance/readme-commands.sh`](Scripts/acceptance/readme-commands.sh) 逐条执行校验，完整输出保存在 [`reports/readme-commands.txt`](reports/readme-commands.txt) 中。

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

# 1. 提取 LaTeX 章节大纲（中文输出）
ScholarOS outline "$WORK/paper.tex" --lang zh

# 2. 按 APA 7th 与 IEEE 样式格式化 BibTeX 文献
ScholarOS format-bib "$WORK/refs.bib" --style apa
ScholarOS format-bib "$WORK/refs.bib" --style ieee

# 3. 结合 refs.bib 对 paper.tex 运行静态诊断（中文输出）
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --lang zh

# 4. 离线引文结构与内置撤稿名单检查（存在未核查/撤稿条目时退出码为 1）
ScholarOS verify-citations "$WORK/refs.bib" --offline --lang zh || echo "expected_exit=$?"

# 5. 通过标准输入输出验证 JSON-RPC 2.0 MCP 握手
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ScholarOS mcp

rm -rf "$WORK"
```

### 按模块运行单测

运行完整 M0 验收（涉及模块单测 + `Scripts/acceptance/m0-acceptance.sh` + `Scripts/acceptance/readme-commands.sh`）可执行 `Scripts/test.sh milestone 0`。单独运行某一模块单测：

```bash
Scripts/test.sh scope ScholarBibAndCSL
```

---

## 当前边界与后续计划

- **桌面端界面（不带子命令运行 `ScholarOS`）**：默认打开空白窗口（`0` 份手稿、`0` 条文献），当前尚不能直接打开用户本地 `.tex`、`.bib` 或 `.pdf` 文件，**仅在传入 `--demo` 或点击“载入演示数据”时查看内置未核查示例数据**（顶部带有 `DEMO / 演示数据` 横幅）。
- **M1 计划（联网引文核验）**：将 Crossref、OpenAlex、arXiv 与 PubMed 在线查询接入 CLI 与 MCP；补齐无 DOI 条目的标题 + 第一作者检索；对标题或年份不一致的元数据漂移进行拦截；加入本地 SQLite 响应缓存与限流退避重试；并在 460 条人工标注基准集（`Benchmarks/citations/`）上评测准确率与误拒率。
- **M2 计划（解析器、PDF 切分与 CiteStudio 对齐）**：完善 LaTeX `\verb`、`verbatim`、`lstlisting`、`\url{%}` 与 `\bibitem` 解析；支持 BibTeX 单条语法错误后的恢复解析；修复 APA 标题大小写与 IEEE 专著格式；改进双栏 PDF 章节标题与跨栏表格切分；暴露与 CiteStudio 对齐的 MCP 工具名称。
- **冻结模块（尚未完成端到端验收，M3 之后再议）**：引文图谱分析（力导向布局、PageRank、Louvain 聚类、Kleinberg 突现检测、主路径分析）、PRISMA 筛查界面、偏倚风险与 Meta 分析界面、Myers 修订追踪界面、投稿归档打包器、Zotero SQLite 桥接、Typst 支持、`JavaScriptCore` 审稿插件、持久化撤销/重做以及仅用于测试的合成 PDF 生成器。

---

## 开源许可

MIT License. Copyright (c) 2026 Xu (`zxu756`).
