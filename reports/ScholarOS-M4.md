## ScholarOS M4 报告

- **做了什么：** 在本地分支 `m4/evidence` 上完成 M4“证据定位”全部实现、评测验收与文档收口（第 1、1b、2、2b、2c、3、4、4b、4c、5 段）。把旧的“蕴含核查”全面改名为“证据检索与显式数字核对”，不再声称能够判断原文是否支持结论：
  1. **双栏 PDF 分段（`PDFMultiColumnSegmenter`）**：基于 `PDFKit` 行选区几何坐标剥离重复页眉页脚，识别编号与未编号章节标题（含引言与参考文献），将跨栏表格与图（`table_or_figure`）单独切为通栏块并保证其上下方双栏正文严格按“先左栏、后右栏”排序；结合 `CGPDFScanner` 主导基线聚类隔离与双峰词距自适应门槛，恢复窄字距两端对齐行（如 Elsevier `cas-dc`）被 `PDFSelection.string` 吞没的词间空格，同时避免在 Latin Modern / Computer Modern 行内数学公式与斜体修正处多插词内空格（第 4b、4c 段）。
  2. **证据检索与显式数字核对（`EvidenceLocatorAndNumericChecker`）**：将检索门槛收紧为实词大部分命中（默认关键词覆盖率 `>= 0.60`）加 BM25 排序，使无关论断、中英文哨兵与跨语种查询稳定返回 `NOT_FOUND`；抽取“数字 + 单位或名词”组合，支持千分位逗号/空格归一、四舍五入容差、常见量纲换算（如 `ms` 与 `s`）、括号数量写法、同名词不同值核对以及靠限定语区分的同名词数值互换检测；输出 `scholaros.evidence/1` JSON（三种结论 `FOUND`、`NUMERIC_MISMATCH`、`NOT_FOUND`，对应退出码 `0`、`1`、`3`，错误退出码 `2`；含 1 起算 `page`、0 起算 `page_index`、`bounding_box`、`column_index`、`section_title`、`excerpt`、`discrepancies`、`matches`）。
  3. **命令行与 MCP 入口（`ScholarCLIAndMCP`）**：新增 `scholaros locate-evidence <pdf> --claim <文字> [--top-k <N>] [--json] [--offline] [--lang zh|en]` 与 `scholaros segment-pdf <pdf> [--json] [--offline] [--lang zh|en]`；在 `scholaros mcp` 默认工具表中新增第 5 个工具 `locate_evidence`（与 CLI `locate-evidence --json` 共用同一实现、输出逐字节相同），并彻底删除旧的 `scholar_search_provenance`（默认与 `--experimental-tools` 下调用均返回 JSON-RPC `-32602`）。
  4. **验收脚本、源码变异与双语文档**：落地离线验收套件 `Scripts/acceptance/m4-acceptance.sh`（第 1–11 行，其中第 6 行在第 5 段补齐全部 7 份合成夹具）、五条源码变异验证脚本 `Scripts/acceptance/m4-mutations.sh`、`Scripts/test.sh milestone 4`，以及中英双语 `README.md` / `README.zh-CN.md` 指标表、边界说明与 `Scripts/acceptance/readme-commands.sh` 离线命令回放。
- **跑的命令和结果：**
  - 总调度在干净工作树（提交 `1c7203d`，`2026-11-21T14:18:20Z`）录制的基线报告 `reports/m4-acceptance.txt`：`Scripts/acceptance/m4-acceptance.sh --record` -> 退出码 `0`（耗时 `167.71s`，`Passed: 10 | Failed: 0 | Skipped (没跑): 1`；第 1–9、11 行全过，第 10 行静态校验 5 个补丁干净并提示单独运行 `m4-mutations.sh`）。
  - 第 5 段（M4-05，补入第 4b 段 `s12_tight_word_spacing.pdf` 与第 4c 段 `s12_lm_math_kerning.pdf` 后）实测结果：
    - `Scripts/acceptance/m4-acceptance.sh --row 6` -> 退出码 `0`（耗时 `11s`；`benchmark_papers=5/5 synthetic_fixtures=7/7`，5 份评测论文与全部 7 份合成夹具均 `hf_leaks=0`、识别出引言与参考文献、通栏图表下双栏先左后右）。
    - `python3 -I Scripts/acceptance/test_m4_harnesses.py -v` -> 退出码 `0`（`7/7` 通过，含新增 7 份夹具配置与页眉页脚禁止子串核验）。
    - `Scripts/acceptance/readme-commands.sh` -> 退出码 `0`（首次运行耗时 `160s`，双语各提取 `84` 行命令、`16` 次 `ScholarOS` 调用，一致执行通过）；随后将第 7 步 `NUMERIC_MISMATCH` 示例的期望退出码临时改坏（`test "$rc" -eq 1` -> `test "$rc" -eq 0`）重跑以退出码 `1` 变红（耗时 `9s`，`replay_exit[README.md]=1`），还原后再跑以退出码 `0` 通过（耗时 `26s`）。
    - `Scripts/acceptance/m4-acceptance.sh`（整份，含第 6 行 7 份合成夹具） -> 退出码 `0`（外层耗时 `224s` / 脚本内 `223.50s`，`Passed: 10 | Failed: 0 | Skipped (没跑): 1`）。
    - `Scripts/acceptance/m4-mutations.sh` -> 退出码 `0`（耗时 `766s`；5 条源码变异 `(a)`–`(e)` 依次让第 `6`、`4`、`3`、`8`、`5` 行以退出码 `1` 变红，还原后整份 `m4-acceptance.sh` 以退出码 `0` 通过，`copy_tree_restored=true`、`origin_working_tree_unchanged=true`）。
    - `Scripts/test.sh milestone 0` / `Scripts/test.sh milestone 4` -> 退出码均为 `0`（耗时分别为 `63s` 与 `179s`，含 M0 第 1–14 行、`readme-commands.sh`、M4 相关模块单测、Python 夹具单测与整份 `m4-acceptance.sh` `152.01s`，工作树、`Benchmarks/` 与真实 `~/Library` 均未产生副作用）。
- **删掉或改名的代码：**
  - 从 `ScholarMCPServer`（含 `--experimental-tools`）彻底删除旧工具 `scholar_search_provenance`（调用返回 JSON-RPC `-32602`），由默认工具 `locate_evidence` 取代；默认 MCP 工具变为 `5` 个（`verify_citation`、`add_verified_bibtex`、`check_manuscript`、`scholar_verify_bibliography`、`locate_evidence`），`--experimental-tools` 下的冻结工具减为 `4` 个。
  - 将原先自称做语义蕴含判定的检索逻辑收口至统一的 `EvidenceLocatorAndNumericChecker`，CLI `--help`、CLI 输出与 MCP 工具描述中 `0` 处出现“蕴含”或 `GROUNDED` 等表述。

---

### M4 验收表（第 1–11 行）逐行实测结果

第 1–9、11 行的基线实测数字取自 `reports/m4-acceptance.txt`（录制时间 `2026-11-21T14:18:20Z`，提交 `1c7203d`，`--offline`，隔离 `HOME` 且未设 `SCHOLAR_CACHE_DIR`）；第 10 行给出第 5 段运行 `Scripts/acceptance/m4-mutations.sh` 的独立副本编译验红实测结果。

| 行 | 命令 | 期望 | 实测 | 通过与否 |
|---:|---|---|---|---|
| 1 | `Scripts/acceptance/m4-acceptance.sh --row 1` | `locate-evidence <pdf> --claim <文字> --json` 与 MCP `locate_evidence`：`schema == "scholaros.evidence/1"`；`verdict` 只有 `FOUND`、`NUMERIC_MISMATCH`、`NOT_FOUND`；找到时含 1 起算 `page`、0 起算 `page_index`、`bounding_box`、`column_index`、`section_title`、`excerpt`；`--help` 与工具描述无“蕴含”/`GROUNDED` 一类说法；退出码 `0` 找到、`1` 数字不一致、`3` 没找到 | `schema=scholaros.evidence/1`，三种结论与退出码 `FOUND(exit=0)`、`NUMERIC_MISMATCH(exit=1)`、`NOT_FOUND(exit=3)` 全部对齐，`entailment_terms_found=0`，`cli_mcp_probe_parity=3/3`（`reports/m4-acceptance.txt` 第 7–9 行） | **通过** |
| 2 | `Scripts/acceptance/m4-acceptance.sh --row 2` | `Benchmarks/evidence/claims.jsonl` 里 10 句有依据的论断：至少 `8/10` 句 `FOUND` 且页码在 `expected_pages` 里 | **`10/10`** 句均为 `FOUND` 且页码命中 `expected_pages`（`ev_001` p.2、`ev_002` p.4、`ev_007` p.30、`ev_008` p.31、`ev_013` p.7、`ev_014` p.7、`ev_019` p.7、`ev_020` p.7、`ev_025` p.15、`ev_026` p.19；硬门槛 `>= 8/10`；`reports/m4-acceptance.txt` 第 11–23 行） | **通过** |
| 3 | `Scripts/acceptance/m4-acceptance.sh --row 3` | 10 句数字不同的论断：至少 `8/10` 句 `NUMERIC_MISMATCH`、页码对、`discrepancies` 里的 `pdf_text` 含原文的数字 | **`9/10`** 句满足 `NUMERIC_MISMATCH`、页码命中 `expected_pages` 且 `pdf_text` 含原文数字（硬门槛 `>= 8/10`）；唯一未命中的 `ev_004`（`2506.06524v1`）返回 `NUMERIC_MISMATCH`（`exit=1`），但落在了第 `2` 页（期望 `expected_pages=[3]`），`pdf_text` 报 `'(610) of PuzzleScript games'` 而未含原文第 3 页的 `'10 games'`（`reports/m4-acceptance.txt` 第 25–37 行） | **通过** |
| 4 | `Scripts/acceptance/m4-acceptance.sh --row 4` | 10 句没提及的论断和 15 行中英文哨兵（“月亮是绿奶酪做的”及带常见词变体，对 5 份论文各跑一遍）：全部 `NOT_FOUND`，`matches` 为空（0 容忍） | **`25/25`** 全部返回 `NOT_FOUND` 且 `matches == []`（`not_mentioned=10/10`，`sentinel=15/15`，0 容忍；`reports/m4-acceptance.txt` 第 39–41 行） | **通过** |
| 5 | `Scripts/acceptance/m4-acceptance.sh --row 5` | 第 2、3 行定位到正确页的结果：框宽高 `> 0`、在页面内、非整页，PDF 左下角坐标换算到 `pdftotext -tsv` 左上角坐标并四边外扩 `4pt` 后覆盖对应段落至少 `80%` 的词（本机有 `pdftotext` 时现场重跑比对） | 本机 Poppler `pdftotext 26.10.0` 现场重跑与存储的 `expected_pdftotext/*.tsv.gz` 比对 `diffs_vs_stored=0/5`；全部 **`19/19`** 个正确页结果的位置框通过校验，**最低词覆盖率 `100.0%`**（硬门槛 `>= 80.0%`，框面积占比 `3.9%`–`13.2%`；`reports/m4-acceptance.txt` 第 43–66 行） | **通过** |
| 6 | `Scripts/acceptance/m4-acceptance.sh --row 6` | 5 份评测论文和仓库里的合成夹具的分段（`segment-pdf --offline --json`）：页眉页脚不在正文块里；每份认出引言和参考文献标题（无参考文献节的夹具除外）；通栏表格下的两栏正文先左后右 | **`benchmark_papers=5/5 synthetic_fixtures=7/7`** 全部通过（评测论文：`2506.06524v1` 68 块/8 标题、`2409.19431v3` 938 块/18 标题、`2410.04196v2` 337 块/11 标题、`2611.15445v1` 202 块/18 标题、`2610.15486v1` 366 块/36 标题；合成夹具：`s12_paper` 32/7、`s12_ieeetran` 15/6、`s12_acm_refs` 28/6、`s12_math_columns` 30/8、`s12_wide_table_fig_cols` 18/4 `refs=False`、`s12_tight_word_spacing` 19/6 `refs=True`、`s12_lm_math_kerning` 22/6 `refs=True`；全部 `hf_leaks=0`、`col_order_ok=True`；`reports/m4-acceptance.txt` 第 68–82 行） | **通过** |
| 7 | `Scripts/acceptance/m4-acceptance.sh --row 7` | 提取的正文文字和 `pdftotext` 的词重合率：5 份每份不低于 `95%`，记下百分比和分段耗时 | **`5/5` 篇全部通过，最低词重合率 `96.87%`**（硬门槛 `>= 95.00%`；耗时在总调度的机器上、同时有别的构建在跑时录得）：`2506.06524v1` **`99.91%`**（`3293/3296`，`333.3ms`）、`2409.19431v3` **`97.69%`**（`20279/20759`，`2137.8ms`）、`2410.04196v2` **`96.87%`**（`10333/10667`，`1083.7ms`）、`2611.15445v1` **`98.67%`**（`6814/6906`，`822.0ms`）、`2610.15486v1` **`98.55%`**（`15163/15386`，`2030.8ms`）（`reports/m4-acceptance.txt` 第 84–91 行） | **通过** |
| 8 | `Scripts/acceptance/m4-acceptance.sh --row 8` | MCP `tools/list` 与逐条调用：默认 `5` 个工具、有 `locate_evidence`、没有 `scholar_search_provenance`（调用返回 `-32602`）；全部 45 行结果与命令行 `--json` `0` 处差异；未知参数返回 `ERR_INVALID_ARGUMENT` | `default_tools=5`、`has_locate_evidence=True`、`has_scholar_search_provenance=False`（调用返回 `-32602`）、`unknown_arg=ERR_INVALID_ARGUMENT`、**`cli_vs_mcp_diffs=0/45`**（`reports/m4-acceptance.txt` 第 93–95 行） | **通过** |
| 9 | `Scripts/acceptance/m4-acceptance.sh --row 9` | 错误处理：文件不存在、不是 PDF 的字节、空白无文字 PDF、空论断 -> 退出码 `2`、`--json` 时 `stdout` 为空、`stderr` 写清原因 | **`error_cases_passed=9/9`**，全部返回退出码 `2`、`--json` 下 `stdout_bytes=0`、`stderr` 非空并写明原因（`reports/m4-acceptance.txt` 第 97–99 行） | **通过** |
| 10 | `Scripts/acceptance/m4-mutations.sh` | 临时副本里逐条打上 5 个变异补丁、编译并重跑对应验收行：去掉页眉页脚剥离、关键词门槛改成 `0.05`、去掉同名词不同值、MCP 跳过数字核对、位置框换成整页均须让对应行失败；还原后整份验收通过、`git status` 干净 | 退出码 `0`（耗时 `766s`）：**(a)** `m4-01-disable-header-footer-strip.patch`（去掉页眉页脚剥离）-> **第 `6` 行变红**（`benchmark_papers=1/5 synthetic_fixtures=1/7`，`exit=1`）；**(b)** `m4-02-lower-keyword-threshold-005.patch`（关键词门槛改成 `0.05`）-> **第 `4` 行变红**（`8/25 NOT_FOUND`，`exit=1`）；**(c)** `m4-03-disable-same-noun-agreement.patch`（去掉同名词不同值核对）-> **第 `3` 行变红**（`3/10 NUMERIC_MISMATCH`，`exit=1`）；**(d)** `m4-04-mcp-skip-numeric-check.patch`（MCP 跳过数字核对）-> **第 `8` 行变红**（`cli_vs_mcp_diffs=10/45`，`exit=1`）；**(e)** `m4-05-full-page-bounding-box.patch`（位置框换成整页）-> **第 `5` 行变红**（`boxes_verified=0/19`，`exit=1`）。全部还原后重跑整份 `m4-acceptance.sh` 退出码 `0`（`Passed: 10 \| Failed: 0 \| Skipped: 1`，耗时 `155.02s`），`copy_tree_restored=true`、`origin_working_tree_unchanged=true` | **通过** |
| 11 | `Scripts/acceptance/m4-acceptance.sh --row 11` 及 `Scripts/test.sh milestone 0` / `milestone 4` | 断网/离线跑单测与 `milestone 0`、`milestone 4` 通过；`Benchmarks/` 没改；真实 `~/Library` 下无新增 ScholarOS 条目；临时目录清理干净；报告不含本机家目录与邮箱 | `reports/m4-acceptance.txt`（第 110–112 行）：`scratch_cleaned=true`、`tmp_clean=true`、`real_library_scholaros_untouched=true`、`benchmarks_diff_exit=0`、`reports_untouched=true`（总耗时 `167.71s`）；第 5 段复跑 `Scripts/test.sh milestone 0`（退出码 `0`，`63s`）与 `Scripts/test.sh milestone 4`（退出码 `0`，`179s`，内含 `m4-acceptance.sh` `152.01s`）全部通过，临时目录已清理、真实 `~/Library` 与 `Benchmarks/` 零变化、提交文件不含本机路径与邮箱 | **通过** |

---

### 总调度另测的

- 保留论断 A（25 句，4 篇 worker 没见过的论文）：有依据 6/6、没提及 8/8、数字不同 7/7、哨兵 4/4；第 2c 段的提示词描述过其中四类错型（没引原句），所以只算半独立。保留论断 B（15 句，一篇总调度合成的论文）：有依据 5/5、没提及 2/2、数字不同 6/7、哨兵 1/1。这两组论断不在仓库里。
- 分段对照（23 份 PDF，其中 10 份 worker 没见过）：两份从 LaTeX 源码编译的盲测论文，词内切开在第 4b 段一度升到 106 处和 26 处，第 4c 段后回到 11 处和 18 处（第 3 段时是 11 和 13）；2610.15486v1 的粘连长词从 385 个降到 3 个。
- 第 3 行唯一没判对的 ev_004：结论是 NUMERIC_MISMATCH，但指到了第 2 页（期望第 3 页），对照的数字也不是原文那个。

---

### 没做或没验证的

- **跨语种：** 只做同语种词项匹配；用中文论断查英文 PDF（或反之）一律返回 `NOT_FOUND`（退出码 `3`），不做跨语言检索或翻译对齐。
- **扫描件：** 文字提取来自 macOS 的 `PDFKit`，扫描件和没有内嵌文字层的 PDF 不支持（不做 OCR，返回退出码 `2` 并在 `stderr` 写清原因）。
- **数字以外的事实核对：** 产品只定位相近段落并核对显式数字，不判断原文是否支持结论（例如“用了神经网络”和“没用神经网络”这类否定，只要没有数字，产品不判）。
- **第 3 行 `ev_004`：** `2506.06524v1` 的 `ev_004` 结论为 `NUMERIC_MISMATCH`，但首位段落指到了第 `2` 页（期望第 `3` 页），`discrepancies` 对照的数字是第 2 页正文里的 `"(610) of PuzzleScript games"` 而不是第 3 页表格标题里的原文数字 `"10 games"`（第 3 行总分 `9/10`，已过 `>= 8/10` 硬门槛，本项未修）。
- **分段的零星残留：** 第 4b、4c 段修过窄字距吞空格与 Latin Modern 行内公式多插空格后，某些 LaTeX 字体和行内公式附近偶尔仍会把一个词切成两段或把两个词粘在一起（例如 `2610.15486v1` 残留 `3` 个粘连长词与一处 `"wher e"`，盲测编译论文中偶有个别专名切开）。
- **真实联网向公开注册库发起实时请求（`SCHOLAR_ONLINE=1`）：没跑。** M4 全程在 `--offline` 与隔离 `HOME` 下运行，不联网。
