# ScholarOS

**[English](README.md)** | **简体中文**

面向 macOS 的 Swift 包（`1.4.0`）与中英双语（`--lang zh|en`）命令行工具（`scholaros`），提供公开学术注册库引文联网核查、LaTeX/BibTeX 解析、APA 7th / IEEE 参考文献排版、信度与 Meta 分析统计计算库，以及基于标准输入输出的 JSON-RPC 2.0 MCP 服务端。

> **编造的参考文献进不了你的 `.bib`。** 在一份 480 条真假混合的文献集上，没有一条编造的文献被判为已验证（`fabricated_model` 组 `0/80`；全集 `truth=fabricated` 条目 `0/86`；全部不可写入条目 `0/254`）；真实三组中的真实文献被误判为不存在或已撤稿（`NOT_FOUND` 或 `RETRACTED`）的比例是 **0%（`0/215`）**（真实三组合计 220 条亦为 `0/220`；全集 `truth=real` 条目为 `0/225`）。

> **当前状态说明（M0、M1、M2 与 M3 MCP 写入关口已验证）：** M0、M1、M2 及 M3 MCP 各检查项已通过，以 [`Scripts/acceptance/m0-acceptance.sh`](Scripts/acceptance/m0-acceptance.sh)、[`Scripts/acceptance/m1-acceptance.sh`](Scripts/acceptance/m1-acceptance.sh)、[`Scripts/acceptance/m2-acceptance.sh`](Scripts/acceptance/m2-acceptance.sh)、[`Scripts/acceptance/hard-inputs.sh`](Scripts/acceptance/hard-inputs.sh)、[`Scripts/acceptance/m3-mcp.sh`](Scripts/acceptance/m3-mcp.sh)（第 1–17、19、20 行）与 [`Scripts/acceptance/m3-clients.sh`](Scripts/acceptance/m3-clients.sh)（第 18 行三家客户端隔离注册连通）为准（需真实联网请求的行——M1 第 19 行与第 23 行——需设 `SCHOLAR_ONLINE=1`；M2 第 17 行独立克隆变异核查由 [`Scripts/acceptance/m2-mutations.sh`](Scripts/acceptance/m2-mutations.sh) 运行，M2 第 19 行 Tectonic 重生成核对由 [`Scripts/acceptance/m2-regen-expected.sh`](Scripts/acceptance/m2-regen-expected.sh) `--check` 运行——未单独执行时输出 `SKIP (没跑)`）。`scholaros verify-citations`、MCP `verify_citation`、MCP `add_verified_bibtex`、MCP `scholar_verify_bibliography`、`scholaros diagnostics`、MCP `check_manuscript` 与 `scholaros cite` 共用同一引文核查流程，默认联网查询公开学术注册库，带本地 SQLite 响应缓存、限速与退避重试（`add_verified_bibtex` 写入时绕开缓存读取，确保离线或未验证文献绝不写入 `.bib`）；`--offline` 不发任何网络请求，`--registry-replay <目录>` 从 SHA-256 校验通过的录制目录离线回放（仅认启动参数，输出带 `REPLAY` 标记），`--no-verify` 仅做结构与写作检查、不核查引用，忽略 `.bib` 中的 `x-firewall-class`/`x-firewall-note` 标记，缓存与写回结论按 30 天（`NOT_FOUND` 为 1 天）过期。在 [`Benchmarks/manuscripts/`](Benchmarks/manuscripts/) 的 11 篇 CC BY 4.0 arXiv 真实论文上，静态多文件加载、原样跳过、BibTeX 单条错误恢复与 `thebibliography`/`.bbl` 提取与仓库提交的 Tectonic 0.17 `.aux`/`.blg` 期望一致（不做 TeX 宏展开）。macOS 桌面窗口启动默认为空，**仅在显式传入 `--demo` 或点击“载入演示数据”时展示内置未核查示例数据**（带 `DEMO` 横幅）。

---

## 引文核查评测指标（`2026-11-16`）

- **日期与报告来源：** `2026-11-16`（提交 `5c63fc4`），全部数字取自 [`reports/citation-bench-2026-11-16-live.json`](reports/citation-bench-2026-11-16-live.json)。
- **查询数据源：** Crossref、OpenAlex、`doi.org` 句柄接口、arXiv Atom 接口、PubMed `esummary`——**全程不带任何 API key、邮箱地址或账号凭据**（`User-Agent: ScholarOS/1.2.0`）。
- **评测集构成（共 `12` 组 `480` 条；每组来源与逐条解释详见 [`Benchmarks/citations/README.md`](Benchmarks/citations/README.md)）：** `audit_manual`（`30` 条手工边界审计用例）、`real_clean`（`100` 条 OpenAlex 分层固定种子抽样并由 Crossref 转换的期刊论文）、`real_human`（`100` 条逐字节摘自 24 篇 CC BY 4.0 arXiv 论文源码包 `.bib` 的真人条目，65 条带 DOI、35 条无 DOI）、`real_typo`（`20` 条对 `real_clean` 的确定性小改：15 条仅改格式、5 条标题错一字母）、`fabricated_model`（`80` 条由 Codex 与 Mistral Vibe 离线凭空生成的编造条目，56 条带标识符、24 条无标识符）、6 个各 `20` 条由 `real_clean` 派生的确定性变异组（`mut_year1`、`mut_year3`、`mut_author`、`mut_title`、`mut_doi_swap`、`mut_doi_missing`），以及 `retracted`（`30` 条来自 Crossref/OpenAlex 且不在内置名单中的已撤稿论文）。
- **联网与回放一致性及运行范围说明：** 联网全量运行（`1015` 个 HTTP 请求、消耗 OpenAlex `390` 点、耗时 `631.202` 秒、Crossref 同时在途请求最多 `1` 个）与 [`Benchmarks/citations/recordings/`](Benchmarks/citations/recordings)（`748` 项，`manifest.json` SHA-256 `81fd7b8e8a20c106fb186c170dedeb42541dc3b1f7d870e2afcd55fb333bbb7b`）离线回放的结果**在全部 `480/480` 条上逐条一致**（`live_vs_replay_diff = []`）。**联网全量评测目前只在一台机器（macOS arm64，2026-11-16）上跑过一次。**

### 核心指标与硬要求结果

| 指标 / 硬要求 | 结果（均带分母） | 说明 |
|---|---|---|
| **放行（`VERIFIED`）精确率**（`VERIFIED` 中 `insertable=true` 的比例） | **`100.00%`（`206/206`）** | **硬要求（必须 `100%`）：通过。** 含 `5/206` 条带刊名写法提示放行的真实文献。 |
| **放行（`VERIFIED`）召回率**（`insertable=true` 中被判 `VERIFIED` 的比例） | **`91.15%`（`206/226`）** | 带标识符：`96.89%`（`187/193`）；无标识符：`57.58%`（`19/33`）。真实三组（`truth=real`）：`91.63%`（`197/215`）；`real_clean` 组：`100.00%`（`100/100`）。 |
| **拦下（`DRIFT` / `NOT_FOUND` / `RETRACTED`）精确率**（被拦下中 `truth!=real` 的比例） | **`96.62%`（`229/237`）** | 其余 `8/237` 条为 `real_human` 组中与注册库记录确实存在年份、作者或标题差异而判 `DRIFT` 的真人条目。带标识符：`98.28%`（`229/233`）。 |
| **拦下（`DRIFT` / `NOT_FOUND` / `RETRACTED`）召回率**（`truth!=real` 中被拦下的比例） | **`89.80%`（`229/255`）** | 按 `insertable=false` 计为 `90.16%`（`229/254`）；其余 `25/254` 条为无标识符编造条目判 `UNVERIFIED`（`no_match_in_search`，同样禁止写入），另 `1` 条 `truth=mutated` 条目（`audit_020`，`insertable=true`，仅刊名不同）带提示判 `VERIFIED`。带标识符：`99.57%`（`229/230`），按 `insertable=false` 为 `100.00%`（`229/229`）。 |
| **`UNVERIFIED`（没查成）比例与原因** | **`7.71%`（`37/480`）** | `no_match_in_search`：`7.29%`（`35/480`；占无标识符条目的 `35/58`）；`registered_no_metadata`：`0.42%`（`2/480`；占带标识符条目的 `2/422`）；断网/超时/限流/解析错误及 `ambiguous`：`0.00%`（`0/480`）。 |
| **硬要求：不可写入条目（`insertable=false`）被判 `VERIFIED`** | **`0.00%`（`0/254`）** | **通过**（编造组、不存在 DOI 组、全部变异组、已撤稿组合计 `0` 条）。 |
| **硬要求：`mut_doi_missing`（真实元数据配未注册 DOI）** | **`0/20` `VERIFIED`，`19/19` 找回真 DOI** | **通过。** `DRIFT`：`19/20`（`95.00%`，全部 `19/19` 条给出标准答案中的真 DOI）；`NOT_FOUND`：`1/20`（`5.00%`）。 |
| **硬要求：480 条全集完成与回放一致性** | **`complete=true`，回放未命中 `0/480`** | **通过。** 联网与离线回放结论差异：`0/480`。 |

### 各组结论分布与落在标准答案（`expected`）中的比例

| 组名（`entries/<组>.bib`） | 条数 | `VERIFIED`（含刊名提示） | `DRIFT` | `NOT_FOUND` | `RETRACTED` | `UNVERIFIED` | 落在 `expected` 的比例 |
|---|---:|---:|---:|---:|---:|---:|---:|
| `audit_manual` | 30 | 9 (1) | 11 | 5 | 2 | 3 | **`30/30`（`100.0%`）** |
| `real_clean` | 100 | 100 (0) | 0 | 0 | 0 | 0 | **`100/100`（`100.0%`）** |
| `real_human` | 100 | 82 (4) | 8 | 0 | 0 | 10 | **`90/100`（`90.0%`）** |
| `real_typo` | 20 | 15 (0) | 5 | 0 | 0 | 0 | **`20/20`（`100.0%`）** |
| `fabricated_model`（有标识 56，无标识 24） | 80 | 0 (0) | 41 | 15 | 0 | 24 | **`80/80`（`100.0%`）**（有标识 `56/56`，无标识 `24/24`） |
| `mut_year1` | 20 | 0 (0) | 20 | 0 | 0 | 0 | **`20/20`（`100.0%`）** |
| `mut_year3` | 20 | 0 (0) | 20 | 0 | 0 | 0 | **`20/20`（`100.0%`）** |
| `mut_author` | 20 | 0 (0) | 20 | 0 | 0 | 0 | **`20/20`（`100.0%`）** |
| `mut_title` | 20 | 0 (0) | 20 | 0 | 0 | 0 | **`20/20`（`100.0%`）** |
| `mut_doi_swap` | 20 | 0 (0) | 20 | 0 | 0 | 0 | **`20/20`（`100.0%`）** |
| `mut_doi_missing` | 20 | 0 (0) | 19 | 1 | 0 | 0 | **`20/20`（`100.0%`）** |
| `retracted` | 30 | 0 (0) | 0 | 0 | 30 | 0 | **`30/30`（`100.0%`）** |
| **合计** | **480** | **206 (5)** | **184** | **21** | **32** | **37** | **`470/480`（`97.92%`）** |

### 核查的边界

- **只核查文献存在性与题录元数据：** 引文核查能够确认一条文献在公开学术注册库中真实存在、其元数据（标识符、标题、发表年、第一作者、作者数）与数据源记录对得上，并检查数据源撤稿标记。
- **不判断正文论断支撑关系：** 它**不能**判断这篇文献的内容是否支持你在论文正文里写的那句话。
- **无标识符且两处检索不到的条目只判“没查成”，不判“不存在”：** 没有 DOI、arXiv 编号或 PMID，且在 Crossref 与 OpenAlex 两处检索均无匹配候选的条目，结论只会是 `UNVERIFIED`（`no_match_in_search`，不可写入），不会被判为 `NOT_FOUND`（“不存在”），因为专著、书章及未收录会议论文在两个数据源中也常检索不到。
- **只有刊名写法不同的真实文献带提示放行：** 当标识符、标题、年份、第一作者与作者数均与真实记录一致，仅期刊或会议名称在三种确定性同刊对照之外仍有差异时，条目按 `VERIFIED` 带提示放行（`insertable: true`；评测集中占 `5/206` 条 `VERIFIED`）。

### 如何复现

```bash
# 1. 不联网运行 M2 + M1 + M0 验收套件与录制回放评测（不发任何网络请求）
Scripts/test.sh milestone 2
Scripts/test.sh milestone 1

# 2. 不联网从 Benchmarks/citations/recordings/ 回放全部 480 条引文基准评测
python3 Scripts/acceptance/m1-citation-bench.py --replay

# 3. 联网向公开注册库实跑 480 条基准评测（2026-11-16 实测耗时 631.202 秒，共 1015 个请求，消耗 OpenAlex 390 点）
SCHOLAR_ONLINE=1 python3 Scripts/acceptance/m1-citation-bench.py --live
```

---

## 已验证能力（`2026-11-14` M0、`2026-11-16` M1、`2026-11-17` M2 与 `2026-11-21` M3）

M3 MCP 写入关口、工具表与三家客户端隔离注册连通检查来自 [`Scripts/acceptance/m3-mcp.sh`](Scripts/acceptance/m3-mcp.sh) 与 [`Scripts/acceptance/m3-clients.sh`](Scripts/acceptance/m3-clients.sh)（`2026-11-21`，macOS arm64，基于 [`Benchmarks/citations/recordings/`](Benchmarks/citations/recordings) 离线回放）；M2 稿件级检查来自 [`Scripts/acceptance/m2-acceptance.sh`](Scripts/acceptance/m2-acceptance.sh) 与 [`Benchmarks/manuscripts/`](Benchmarks/manuscripts/)（`2026-11-17`）；M1 引文核查指标与验收检查来自 [`reports/citation-bench-2026-11-16-live.json`](reports/citation-bench-2026-11-16-live.json)（`2026-11-16`）与 [`Scripts/acceptance/m1-acceptance.sh`](Scripts/acceptance/m1-acceptance.sh)；M0 解析、格式化、统计函数、MCP 协议与命令行基线数值来自 [`reports/m0-acceptance.txt`](reports/m0-acceptance.txt) 与 [`reports/readme-commands.txt`](reports/readme-commands.txt)（`2026-11-14` 于 macOS arm64 执行 `Scripts/test.sh milestone 0` 实测；不带 `--record` 时报告写到临时目录，不改动 `reports/`）：

- **引文核查（`scholaros verify-citations`、`scholaros cite`、`scholaros cache clear`、MCP `verify_citation`、MCP `add_verified_bibtex`、MCP `scholar_verify_bibliography`）**（[`reports/citation-bench-2026-11-16-live.json`](reports/citation-bench-2026-11-16-live.json)，`2026-11-16`）：使用五类状态（`VERIFIED`、`DRIFT`、`NOT_FOUND`、`RETRACTED`、`UNVERIFIED`），支持 `--lang en`、`--lang zh` 与 `--json` 输出：
  - 默认联网查询 Crossref、OpenAlex、`doi.org`、arXiv 与 PubMed，并将可缓存响应写入本地 SQLite（默认 `~/Library/Caches/ScholarOS/registry.sqlite`，或 `$SCHOLAR_CACHE_DIR/registry.sqlite`；有效 `200` 记录有效期 30 天，有依据的不存在记录有效期 1 天）；`--no-cache` 本次运行不读写缓存，`scholaros cache clear` 删除当前生效位置的 `registry.sqlite`（含 `-wal`/`-shm`），`--verbose` 每查一次向标准错误输出一行（数据源、地址、状态码、耗时与来源）。
  - `--offline` 不发任何网络请求且不读写缓存，仅检查标识符格式与不完整的 8 条内置撤稿 DOI 名单（`--lang zh` 下注明 `内置名单，不完整`，`--lang en` 下为 `built-in list, incomplete`）；未联网查询的合法标识符标为 `UNVERIFIED`。
  - `--registry-record <目录>` 联网查询公开注册库（默认读写缓存，加 `--no-cache` 跳过缓存），将原始响应字节、元数据与 SHA-256 `manifest.json` 写入 `<目录>`，已录过的地址直接复用；`--registry-record-limit <N>`（正整数，默认 `80`，只能与 `--registry-record` 一起使用）限制本次运行最多新发出的请求数。
  - `--registry-replay <目录>` 从 SHA-256 校验通过的本地录制目录离线回放（不发网络请求；默认不读写缓存，仅在显式设置 `SCHOLAR_CACHE_DIR` 时读写该目录缓存，绝不触碰默认缓存目录），输出带 `REPLAY` 标记。
  - 语法格式损坏的标识符标为 `NOT_FOUND`（`invalid_identifier`）；`10.0000/`、`10.1234/`、`10.9999/` 等前缀在 ISO 26324 语法上合法，不在离线阶段直接判为不存在。忽略 `.bib` 文件内嵌的 `x-firewall-class` / `x-firewall-note` 字段且导出时不再写出。
  - 退出码：全部 `VERIFIED` 返回 `0`；存在 `DRIFT`、`NOT_FOUND`、`RETRACTED` 或单条 BibTeX 解析失败（`parse_error`）返回 `1`；无上述情况但存在 `UNVERIFIED` 返回 `3`；参数、文件不存在、0 条可读条目的 BibTeX 失败或回放错误返回 `2`。
- **MCP 写入关口（`add_verified_bibtex`、`verify_citation`、`check_manuscript`、`scholar_verify_bibliography`）**（[`Scripts/acceptance/m3-mcp.sh`](Scripts/acceptance/m3-mcp.sh) 与 [`Scripts/acceptance/m3-clients.sh`](Scripts/acceptance/m3-clients.sh)，`2026-11-21`）：在 MCP 层强制执行写入前引文核查，确保智能体只能把经公开注册库核实为 `VERIFIED` 的文献追加进 `.bib`：
  - 在基于 [`Benchmarks/citations/recordings/`](Benchmarks/citations/recordings) 回放的全部 `480/480` 条评测集上，`verify_citation` 与命令行 `scholaros verify-citations --registry-replay --json` 对比 **`0` 处差异**（`m3-mcp.sh` 第 11 行）。
  - `add_verified_bibtex` 在本进程内重新核查单条 BibTeX 且**写入时绕开 SQLite 缓存读取**（`--offline`、`offline: true` 或禁网环境下即使有有效热缓存也一律拒绝写入），对 `NOT_FOUND`、`DRIFT`、`UNVERIFIED`、`RETRACTED` 一律返回 `isError: true`（`ERR_UNVERIFIED_CITATION`）且保持 `.bib` 字节不变，执行 `4` 类规则精确查重（`SKIPPED_DUPLICATE` 与 `ERR_CITE_KEY_CONFLICT`）和 `8` 类路径/编码/语法安全拦截（`ERR_BIB_PATH`、`ERR_BIB_ENCODING`、`ERR_BIB_SYNTAX` 及 CRLF 保留），并在独占锁 `flock` + `O_APPEND` + `fsync` 下写入数据源权威字段；**`2` 个并发 MCP 服务进程**同时往同一 `.bib` 各写 **`20` 条不同 `VERIFIED` 文献**时，**`40/40` 条唯一文献全部在列，`0` 处解析或重复错误**（`m3-mcp.sh` 第 2–10、13、14 行）。
  - 在全部 `11/11` 篇基准论文（`offline: true`）上，`check_manuscript` 默认返回精简摘要（`1,794`–`8,704` 字节），其 `counts` 在 `11/11` 篇上与命令行 `diagnostics <path> --offline --json` 一致；传入 `detail: "full"` 时（`33,929`–`296,414` 字节）在 `11/11` 篇上与命令行 `--json` **逐字节相同**（`m3-mcp.sh` 第 15 行）。
- **LaTeX 章节大纲与稿件级静态诊断（`scholaros outline`、`scholaros diagnostics`、MCP `check_manuscript`）**（[`reports/m0-acceptance.txt`](reports/m0-acceptance.txt)，`2026-11-14` 与 [`Scripts/acceptance/m2-acceptance.sh`](Scripts/acceptance/m2-acceptance.sh)，`2026-11-17`）：支持直接读取 `.tex` 源文件而无需先创建工程包。在仓库自带的 449 行 IEEEtran 风格样稿 [`Fixtures/sample-ieeetran-manuscript.tex`](Fixtures/sample-ieeetran-manuscript.tex)（内容是为本仓库虚构的，任何人都能重跑这项检查）上，`scholaros outline` 在 `--lang en` 与 `--lang zh` 下均提取出全部 `46` 个 `\section` / `\subsection` 标题（带星号和不带星号的都有），与 `grep -c -E '\\(section|subsection)\*?\{'` 的计数一致（2026-11-14 实测）。
  - 递归解析多文件包含图（`\input`、无花括号 `\input`、`\include`、`\InputIfFileExists`、`\subfile`、`\import`、`\subimport`）并支持 Windows-1252 编码回退（`ENC001`），无损跳过原样内容、代码块、条件块与 URL 参数（`\verb`、`verbatim`、`lstlisting`、`\lstinline`、`minted`、`\mintinline`、`comment`、`\iffalse...\fi`、`\url`、`\path`、`\nolinkurl`、`\href`），并支持从 `.bib`、`thebibliography`、`\input{*.bbl}` 与 `<主文件>.bbl` 回退（`BIB_FROM_BBL`）提取文献。
  - 诊断分为 `structure`（`SYM003`、`SYM004`、`CITE404`、`INC002`、`BIB001`、`CITE_KEY_CASE` 等）、`citation`（每个唯一引用键最多 1 条 `ERR_UNVERIFIED_CITATION`：`DRIFT`/`NOT_FOUND`/`RETRACTED` 为 `ERROR`，`UNVERIFIED` 为带原因码的 `WARNING`）与 `lint`（`LINT_LABEL_BEFORE_CAPTION` 为 `WARNING`，`LINT_UNCITED_BIB_ENTRY` 等为 `INFO`/`HINT`，在 `\nocite{*}` 下与 `crossref` 父条目上抑制未使用提示）。
  - 文本输出先列出非引文类诊断，再输出一行引用核查汇总（`引用核查：N 个键，VERIFIED ...，UNVERIFIED ...` / `Citation verification: N key(s), ...`），随后逐条列出非 `VERIFIED` 的唯一引用键诊断；`--json` 输出确定性 `scholaros.diagnostics/1` 对象（不含当次时间戳与随机 ID）。
  - `--no-verify` 只做结构与写作规则检查，不调用引文核查（输出写明 `引用核查：未核查引用...` / `Citation verification: skipped (--no-verify; citations not verified, ...)`，退出码仅取 `0`/`1`/`2`）。常规 `diagnostics` 退出码与 `verify-citations` 对齐：`0` = 无结构类 `ERROR` 且被引条目全部 `VERIFIED`；`1` = 存在结构类 `ERROR` 或存在 `DRIFT`/`NOT_FOUND`/`RETRACTED` 被引条目；`3` = 无上述两类但存在 `UNVERIFIED` 被引条目；`2` = 参数用法错误或文件不存在。
- **BibTeX 解析与 APA 7th / IEEE 参考文献格式化（`scholaros format-bib`）**（[`reports/m0-acceptance.txt`](reports/m0-acceptance.txt)，`2026-11-14`；M1 补齐 CRLF 换行支持；M2 补齐错误恢复与字段规则）：直接解析 `.bib` 文件（支持 LF、CRLF 及混合换行），按 BibTeX 0.99d 标识符字符规则读取字段名，支持单条语法错误恢复（`BIB001`；其余条目正常输出时返回 `1`，0 条有效条目时返回 `2`）、`and others` 截断标记（`authorsTruncated`，不产生 `"and et al."`）、两遍扫描 `crossref` 继承（`BIB003`）及 `howpublished`/`note` 中的 `\url`/`\href` 提取，并输出 APA 7th（`--style apa`）与 IEEE（`--style ieee`）参考文献列表。
- **评分者间一致性信度与统计计算库（`ScholarPRISMAEngine`、`ScholarPluginSDK`）**（[`reports/m0-acceptance.txt`](reports/m0-acceptance.txt)，`2026-11-14`）：包含多分类名义变量 Cohen's $\kappa$、Brennan-Prediger PABAK、Gwet's $AC_1$, Fleiss' $\kappa$、DerSimonian-Laird 随机效应合成及 Lanczos/Lentz $t$/$F$/$\chi^2$ 分布计算。在 12 项研究、5 分类双人盲筛数据集上，`scholaros prisma-stats` 与 MCP `scholar_prisma_agreement`（需 `--experimental-tools`）均算得 $\kappa = 0.7757$，与闭式手算精确值 $83/107 \approx 0.775701$ 一致。
- **JSON-RPC 2.0 MCP 服务端（`scholaros mcp`）**（[`reports/m0-acceptance.txt`](reports/m0-acceptance.txt)，`2026-11-14` 与 [`Scripts/acceptance/m3-mcp.sh`](Scripts/acceptance/m3-mcp.sh)，`2026-11-21`）：基于 stdio 的 JSON-RPC 2.0 服务端（`protocolVersion: "2024-11-05"`，`ping` 返回 `{}`，`serverInfo.version` 与 `scholaros version` 一致），对非法 JSON 返回标准 `-32700`（`Parse error`），对未知方法名返回 `-32601`（`Method not found`），对未知或未启用工具返回 `-32602`（`Invalid params`）；支持 `--offline`、`--registry-replay <目录>`、`--no-cache`、`--experimental-tools` 与 `--lang zh|en`，在同一进程的多次调用间共用限速器。
- **中英双语切换（`--lang zh|en`）**（[`reports/m0-acceptance.txt`](reports/m0-acceptance.txt)，`2026-11-14`）：命令行诊断、引文核查说明、参数用法错误提示、桌面界面（`⇧⌘L`）及独立 HTML 审计简报（[`docs/demo-scholar-dossier.html`](docs/demo-scholar-dossier.html)，顶部显式标注 `[DEMO / 演示数据]`）均支持简体中文与英文切换。

---

## MCP 服务端与客户端注册

### 默认工具表（`scholaros mcp`）

`scholaros mcp` 默认只列出 **4** 个引文与稿件工具（参数统一为 `snake_case`；所有工具均不接受 `registryReplayPath`、`demo` 或 `projectPath`，传入任何未知或类型错误参数均返回 `isError: true` 与 `ERR_INVALID_ARGUMENT`；回放模式只能通过服务端启动参数 `scholaros mcp --registry-replay <目录>` 开启）：

| 工具名 | 参数（`*` 为必填） | 写 `.bib`？ | 作用与行为 |
|---|---|---|---|
| `verify_citation` | `bibtex*`（`string`）、`offline`（`boolean`）、`lang`（`string`） | 否 | 单条 BibTeX 核查（`bibtex` 必须恰好包含 `1` 条，0 条或多条返回 `ERR_INVALID_BIBTEX`）；默认联网并读写 SQLite 缓存，返回 `{mode, cite_key, verdict, reasons, sources, fields, insertable, record, findings}`（只要核查正常跑完，五类结论均 `isError: false`）。 |
| `add_verified_bibtex` | `bib_file*`（`string`）、`bibtex*`（`string`）、`offline`（`boolean`）、`lang`（`string`） | 是（仅 `VERIFIED`） | 进程内重新核查单条 BibTeX（**写入时绕开缓存读取**），仅当 `verdict == "VERIFIED"` 且 `insertable == true` 时在独占锁 `flock` + `O_APPEND` + `fsync` 下将数据源权威字段追加到 `bib_file`。返回 `APPENDED_VERIFIED` 或 `SKIPPED_DUPLICATE`（`isError: false`），否则返回 `isError: true`（`ERR_UNVERIFIED_CITATION`、`ERR_CITE_KEY_CONFLICT`、`ERR_BIB_PATH`、`ERR_BIB_ENCODING`、`ERR_BIB_SYNTAX`、`ERR_INVALID_BIBTEX`、`ERR_INVALID_ARGUMENT`、`ERR_IO`）且不改动文件。 |
| `check_manuscript` | `path*`（`string`）、`bib_file`（`string`）、`no_verify`（`boolean`）、`offline`（`boolean`）、`detail`（`"summary"` \| `"full"`）、`lang`（`string`） | 否 | 从 `path` 加载多文件稿件、运行结构与交叉引用检查，并**默认联网核查被引文献**（可使用 SQLite 缓存；传 `no_verify: true` 只查结构，传 `offline: true` 走零网络离线检查）。 |
| `scholar_verify_bibliography` | `bibtex*`（`string`）、`offline`（`boolean`）、`lang`（`string`） | 否 | 批量只读核查一段 BibTeX 字符串（`0`、`1` 或多条），与 `verify_citation` 共用同一防火墙、限速器、SQLite 缓存与回放规则。 |

- **`check_manuscript` 输出粒度与超时说明：** 默认（省略 `detail` 或传 `"summary"`）返回精简摘要对象（`mode`、`root`、`complete`、`counts`、`structure_errors`、`non_verified_citations` 六个字段），控制 MCP 客户端上下文体积；传 `detail: "full"` 时返回与命令行 `scholaros diagnostics <path> --json` 逐字节相同的完整 `scholaros.diagnostics/1` 对象。由于 `check_manuscript` 默认会联网核查被引条目（未命中缓存且含几十个引用键的稿件约需 1–2 分钟），**在 Codex 中使用时可能需要在 `[mcp_servers.scholaros]` 下调大 `tool_timeout_sec`**。
- **实验与冻结工具（`--experimental-tools`）：** 以 `scholaros mcp --experimental-tools` 启动时，额外列出 5 个冻结功能工具（`scholar_search_provenance`、`scholar_prisma_agreement`、`scholar_editorial_audit`、`scholar_track_changes_diff`、`scholar_citation_gaps`）；默认启动时这些工具不出现在 `tools/list`，调用返回 JSON-RPC `-32602`。

### 在三家客户端中注册

如果客户端找不到 `scholaros` 命令（图形界面客户端的 `PATH` 常不含 Homebrew 目录），请将命令改成绝对路径，例如 Homebrew 安装的位于 `/opt/homebrew/bin/scholaros`。

**Claude Code：**

```sh
claude mcp add --scope user scholaros -- scholaros mcp
```

**Codex（`~/.codex/config.toml`；对未缓存大稿件运行联网 `check_manuscript` 时建议调大 `tool_timeout_sec`）：**

```toml
# ~/.codex/config.toml
[mcp_servers.scholaros]
command = "scholaros"
args = ["mcp"]
```

**OpenCode（项目根目录 `opencode.json` 或全局 `~/.config/opencode/opencode.json`）：**

```json
{"mcp": {"servers": {"scholaros": {"type": "local", "command": ["scholaros", "mcp"]}}}}
```

---

## 编译与可复现命令示例

[`Scripts/acceptance/readme-commands.sh`](Scripts/acceptance/readme-commands.sh) 从本文件与 [`README.md`](README.md) 的 `bash` 代码块中提取命令，两份文件的命令不一致时报错，并在离线（含 `sandbox-exec` 禁网沙箱）环境下原样执行全部离线与回放命令。基线输出记录在 [`reports/readme-commands.txt`](reports/readme-commands.txt) 中。

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

# 3. 结合 refs.bib 对 paper.tex 运行诊断：录制回放（退出码 0）、--offline（退出码 3）与 --no-verify（退出码 0）
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --registry-replay Tests/Fixtures/registry --lang en
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --registry-replay Tests/Fixtures/registry --lang zh
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --offline --lang en || echo "expected_exit=$?"
ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --no-verify --lang zh

# 4. 引文核查与插入前核查：--offline 与录制回放（--registry-replay）
ScholarOS verify-citations "$WORK/refs.bib" --offline --lang en || echo "expected_exit=$?"
ScholarOS verify-citations "$WORK/refs.bib" --registry-replay Tests/Fixtures/registry --lang en || echo "expected_exit=$?"
ScholarOS cite lecun2015deep --bib "$WORK/refs.bib" --registry-replay Tests/Fixtures/registry

# 5. 通过标准输入输出运行 JSON-RPC 2.0 MCP 服务端：tools/list（--offline）与写入关口 + check_manuscript（--registry-replay）
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | scholaros mcp --offline
: > "$WORK/mcp-target.bib"
python3 -I - "$WORK/mcp-target.bib" "$WORK/paper.tex" > "$WORK/mcp-requests.jsonl" <<'PY'
import json, sys
bib_target, paper_tex = sys.argv[1], sys.argv[2]
retracted_bib = "@article{wakefield1998retracted, author={Wakefield, A. J.}, title={Ileal-lymphoid-nodular hyperplasia}, journal={The Lancet}, year={1998}, doi={10.1016/S0140-6736(97)11096-0}}"
verified_bib = "@article{lecun2015deep, author={LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey}, title={Deep learning}, journal={Nature}, year={2015}, volume={521}, pages={436--444}, doi={10.1038/nature14539}}"
for req in [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "verify_citation", "arguments": {"bibtex": verified_bib}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": bib_target, "bibtex": retracted_bib}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": bib_target, "bibtex": verified_bib}}},
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "check_manuscript", "arguments": {"path": paper_tex, "bib_file": bib_target}}},
]:
    print(json.dumps(req))
PY
scholaros mcp --registry-replay Tests/Fixtures/registry < "$WORK/mcp-requests.jsonl"

# 6. 在 Fixtures/ 自带的样稿上复现上文引用的标题数
ScholarOS outline Fixtures/sample-ieeetran-manuscript.tex | grep -c .
grep -c -E '\\(section|subsection)\*?\{' Fixtures/sample-ieeetran-manuscript.tex

rm -rf "$WORK"
```

### 按模块运行单测

离线运行 M0、M1 或 M2 验收套件（`Scripts/test.sh milestone 0`、`Scripts/test.sh milestone 1` 或 `Scripts/test.sh milestone 2`）时，报告默认写到临时目录且工作区保持不变；加 `--record` 才会更新 `reports/`。单独运行某一模块单测：

```bash
Scripts/test.sh scope ScholarBibAndCSL
```

---

## 当前边界与后续计划

- **桌面端界面（不带子命令运行 `ScholarOS`）**：默认打开空白窗口（`0` 份手稿、`0` 条文献），当前尚不能直接打开用户本地 `.tex`、`.bib` 或 `.pdf` 文件，**仅在传入 `--demo` 或点击“载入演示数据”时查看内置未核查示例数据**（顶部带有 `DEMO / 演示数据` 横幅）。
- **静态 LaTeX 与 `\bibitem` 解析边界**：稿件分析直接静态读取 `.tex`、`.bib` 与 `.bbl` 源文件，不运行 TeX 宏展开引擎（由自定义宏动态拼出的引用键或标签不会展开）；对 `thebibliography` / `.bbl` 自由文本 `\bibitem` 的作者、标题、年份提取为尽力启发式解析。
- **后续计划（M4–M5）**：
  - **M4 与 M5（PDF 证据定位与 CiteStudio 引擎统一）**：将关键词匹配改为双栏 PDF 原文段落定位与“数字加单位”核对；对外导出核心引擎库供 CiteStudio 调用，并对照手册各校对 15 条 APA 与 IEEE 示例。
- **冻结模块（尚未完成端到端验收，MCP 层收起在 `--experimental-tools` 之后）**：引文图谱分析（力导向布局、PageRank、Louvain 聚类、Kleinberg 突现检测、主路径分析）、PRISMA 筛查界面、偏倚风险与 Meta 分析界面、Myers 修订追踪界面、投稿归档打包器、Zotero SQLite 桥接、Typst 支持、`JavaScriptCore` 审稿插件、持久化撤销/重做以及仅用于测试的合成 PDF 生成器。

---

## 开源许可

MIT License. Copyright (c) 2026 Xu (`zxu756`).
