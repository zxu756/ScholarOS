import Foundation
import ScholarBibAndCSL
import ScholarCitationGraph
import ScholarLSPEngine
import ScholarMarkupAST
import ScholarModels
import ScholarPDFProvenance
import ScholarPluginSDK
import ScholarPRISMAEngine
import ScholarProjectStore

// MARK: - Hallmark-Clean Bilingual (中文 / EN) Cambridge Linen Academic Audit HTML Dossier Exporter

public struct CambridgeLinenHTMLReportExporter: Sendable {
    public init() {}

    public func exportHTMLDossier(database: ScholarProjectDatabase, isDemo: Bool = false) throws -> String {
        let stats = try database.computeProjectStats()
        let rawTitle = isDemo && !stats.projectTitle.hasPrefix("[DEMO]")
            ? "[DEMO] \(stats.projectTitle)"
            : stats.projectTitle
        let title = sanitizeCopy(rawTitle)
        let titleZh = localizedProjectTitleZh(rawTitle, isDemo: isDemo)
        let entries = try database.listBibliographyEntries()
        let prismaMetrics = try database.computePRISMAMetrics()
        let studies = try database.listScreeningStudies()
        let provenanceLinks = try database.listClaimProvenanceLinks()
        let manuscriptFiles = try database.listManuscriptFiles()

        var filesMap: [String: String] = [:]
        for record in manuscriptFiles {
            filesMap[record.path] = record.content
        }
        if filesMap.isEmpty {
            filesMap["main.tex"] = "\\section{Introduction}\nEmpty manuscript.\n"
        }

        let lspService = ScholarLSPWorkspaceService(
            rootFilePath: stats.primaryManuscriptFile,
            files: filesMap,
            bibliography: entries,
            citationStyle: (try? database.preferredCitationStyle()) ?? .apa7
        )
        let outline = lspService.documentOutline
        let diagReport = lspService.diagnosticsReport()

        var safeEditorialFiles: [String: String] = [:]
        for (path, content) in filesMap {
            if ManuscriptFormat.detect(fromPath: path) == .typst {
                safeEditorialFiles[path] = content
                    .components(separatedBy: "\n")
                    .map { $0.count < 2 ? ($0 + "  ") : $0 }
                    .joined(separator: "\n")
            } else {
                safeEditorialFiles[path] = content
            }
        }

        let auditRunner = EditorialPluginAuditRunner()
        let editorialSummary = try auditRunner.run(
            files: safeEditorialFiles,
            primaryFilePath: stats.primaryManuscriptFile,
            bibliography: entries,
            plugins: BuiltInEditorialPluginCatalog.allPlugins
        )

        let cslFormatter = CSLCitationFormatterEngine()
        let formattedBib = cslFormatter.formatBibliography(
            entries: entries.filter { $0.trustedFirewallClass().allowsManuscriptInsertion },
            style: .apa7
        )
        let rawPrismaSVG = PRISMA2020DiagramExporter().exportVectorSVG(metrics: prismaMetrics)
        let prismaSVG = bilingualizePrismaSVG(sanitizeCopy(rawPrismaSVG), metrics: prismaMetrics)

        let outlineRows = outline.map { item in
            let indentPx = max(0, (item.level - 1) * 16)
            let enHeading = sanitizeCopy(item.title)
            let zhHeading = localizedOutlineHeadingZh(enHeading)
            return """
            <tr>
              <td class="mono">\(escapeHTML(item.numberPrefix))</td>
              <td style="padding-left:\(12 + indentPx)px"><span data-en="\(escapeAttr(enHeading))" data-zh="\(escapeAttr(zhHeading))">\(escapeHTML(enHeading))</span></td>
              <td class="mono">\(escapeHTML(item.filePath)):\(item.line)</td>
              <td class="mono num">\(item.wordCountInSection)</td>
            </tr>
            """
        }.joined(separator: "\n")

        let bibRows = entries.map { entry in
            let effectiveClass = entry.trustedFirewallClass()
            let badgeClass: String
            switch effectiveClass {
            case .verified:
                badgeClass = "pill-ok"
            case .drift, .unverified:
                badgeClass = "pill-warn"
            case .notFound, .retracted:
                badgeClass = "pill-block"
            }
            let pidText: String
            let pidZh: String
            if let doi = entry.doi, !doi.isEmpty {
                pidText = "doi:\(doi)"
                pidZh = "doi:\(doi)"
            } else if let arxiv = entry.arxivID, !arxiv.isEmpty {
                pidText = "arXiv:\(arxiv)"
                pidZh = "arXiv:\(arxiv)"
            } else if let pmid = entry.pmid, !pmid.isEmpty {
                pidText = "PMID:\(pmid)"
                pidZh = "PMID:\(pmid)"
            } else {
                pidText = "none"
                pidZh = "无标识符"
            }
            let badgeEn = effectiveClass.localizedBadgeTitle(.en)
            let badgeZh = effectiveClass.localizedBadgeTitle(.zhHans)
            let apaLine = sanitizeCopy(cslFormatter.formatEntry(entry, style: .apa7).bibliographyUnnumberedPlainText)
            return """
            <tr>
              <td class="mono">\(escapeHTML(entry.citeKey))</td>
              <td><span class="pill \(badgeClass)" data-en="\(escapeAttr(badgeEn))" data-zh="\(escapeAttr(badgeZh))">\(escapeHTML(badgeEn))</span></td>
              <td class="mono"><span data-en="\(escapeAttr(sanitizeCopy(pidText)))" data-zh="\(escapeAttr(sanitizeCopy(pidZh)))">\(escapeHTML(sanitizeCopy(pidText)))</span></td>
              <td>\(escapeHTML(apaLine))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let provenanceRows = provenanceLinks.prefix(12).map { link in
            let verdictClass: String
            let verdictEn: String
            switch link.verdict {
            case .groundedEntailment:
                verdictClass = "pill-ok"
                verdictEn = "Grounded"
            case .partialEvidence:
                verdictClass = "pill-warn"
                verdictEn = "Partial"
            case .numericDiscrepancy:
                verdictClass = "pill-block"
                verdictEn = "Numeric mismatch"
            case .unsupportedClaim:
                verdictClass = "pill-block"
                verdictEn = "Unsupported"
            }
            let verdictZh = link.verdict.localizedLabel(.zhHans)
            let sourceEn = "\(link.citeKey), p.\(link.boundingBox.pageIndex + 1)"
            let sourceZh = "\(link.citeKey)，第\(link.boundingBox.pageIndex + 1)页"
            let claimClean = sanitizeCopy(link.manuscriptClaim)
            return """
            <tr>
              <td class="mono">\(escapeHTML(link.manuscriptFile)):\(link.manuscriptLine)</td>
              <td class="mono"><span data-en="\(escapeAttr(sourceEn))" data-zh="\(escapeAttr(sourceZh))">\(escapeHTML(sourceEn))</span></td>
              <td><span class="pill \(verdictClass)" data-en="\(escapeAttr(verdictEn))" data-zh="\(escapeAttr(verdictZh))">\(escapeHTML(verdictEn))</span></td>
              <td class="mono num">\(String(format: "%.2f", link.bm25Score))</td>
              <td>\(escapeHTML(claimClean))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let editorialRows = editorialSummary.findings.prefix(12).map { finding in
            let sevClass: String
            let sevEn: String
            switch finding.severity {
            case .submissionBlocker:
                sevClass = "pill-block"
                sevEn = "Submission blocker"
            case .rigorWarning:
                sevClass = "pill-warn"
                sevEn = "Rigor warning"
            case .styleSuggestion:
                sevClass = "pill-neutral"
                sevEn = "Style suggestion"
            case .note:
                sevClass = "pill-neutral"
                sevEn = "Editorial note"
            }
            let sevZh = finding.severity.localizedLabel(.zhHans)
            let pluginEn = sanitizeCopy(finding.pluginName)
            let pluginZh = sanitizeCopy(finding.localizedPluginName(.zhHans))
            let expEn = sanitizeCopy(finding.explanation)
            let expZh = sanitizeCopy(finding.localizedExplanation(.zhHans))
            return """
            <tr>
              <td><span class="pill \(sevClass)" data-en="\(escapeAttr(sevEn))" data-zh="\(escapeAttr(sevZh))">\(escapeHTML(sevEn))</span></td>
              <td class="mono">\(escapeHTML(finding.filePath)):\(finding.line)</td>
              <td><span data-en="\(escapeAttr(pluginEn))" data-zh="\(escapeAttr(pluginZh))">\(escapeHTML(pluginEn))</span></td>
              <td><span data-en="\(escapeAttr(expEn))" data-zh="\(escapeAttr(expZh))">\(escapeHTML(expEn))</span></td>
            </tr>
            """
        }.joined(separator: "\n")

        let subtitleEn = "Primary Manuscript: \(stats.primaryManuscriptFile), Schema v\(stats.schemaVersion), LSP Errors: \(diagReport.errorCount), Firewall Violations: \(diagReport.firewallViolationCount)"
        let subtitleZh = "主手稿文件：\(stats.primaryManuscriptFile)，数据库架构 v\(stats.schemaVersion)，LSP 错误：\(diagReport.errorCount)，防火墙拦截违规：\(diagReport.firewallViolationCount)"

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="description" content="ScholarOS bilingual reproducible academic manuscript, Citation Verification Firewall, PDF provenance, and PRISMA 2020 screening audit dossier.">
          <title>ScholarOS Audit Dossier: \(escapeHTML(title))</title>
          <style>
          /* Hallmark · v2.0.0 · scope: app · genre: editorial-archival · posture: restrained · shape: app screen · surface: absolute */
          :root {
            --bg-linen: #F8F6F0;
            --bg-paper: #FDFCF8;
            --font-sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", "PingFang SC", "Hiragino Sans GB", sans-serif;
            --font-serif: Georgia, "Times New Roman", "Songti SC", serif;
            --font-mono: ui-monospace, SFMono-Regular, Menlo, monospace;
            --bg-vellum: #F1EEE6;
            --border-stone: #DEDAD0;
            --ink-primary: #191B1A;
            --ink-secondary: #5A605D;
            --ink-muted: #727874;
            --accent-forest: #1D4D3E;
            --status-ok-fg: #1F6E4A;
            --status-ok-bg: #E8F5EE;
            --status-warn-fg: #9A6700;
            --status-warn-bg: #FEF6E4;
            --status-block-fg: #B42318;
            --status-block-bg: #FEECEB;
          }
          * { box-sizing: border-box; }
          html, body { overflow-x: clip; }
          body {
            margin: 0;
            padding: 32px 24px 56px;
            background: var(--bg-linen);
            color: var(--ink-primary);
            font-family: var(--font-sans);
            line-height: 1.55;
            font-size: 14px;
          }
          .container {
            max-width: 1160px;
            margin: 0 auto;
          }
          header.masthead {
            background: var(--bg-paper);
            border: 1px solid var(--border-stone);
            border-top: 4px solid var(--accent-forest);
            border-radius: 6px;
            padding: 24px 28px;
            margin-bottom: 20px;
          }
          .masthead-row {
            display: flex;
            justify-content: space-between;
            align-items: flex-start;
            gap: 16px;
            flex-wrap: wrap;
          }
          .lang-toggle {
            display: inline-flex;
            align-items: center;
            gap: 4px;
            padding: 4px;
            background: var(--bg-linen);
            border: 1px solid var(--accent-forest);
            border-radius: 999px;
          }
          .lang-btn {
            appearance: none;
            border: none;
            background: transparent;
            color: var(--accent-forest);
            font-family: var(--font-sans);
            font-size: 12px;
            font-weight: 600;
            line-height: 1.2;
            padding: 4px 12px;
            border-radius: 999px;
            cursor: pointer;
          }
          .lang-btn.is-active {
            background: var(--accent-forest);
            color: var(--bg-paper);
          }
          .lang-btn:hover:not(.is-active):not(:disabled) {
            background: var(--bg-vellum);
          }
          .lang-btn:active:not(:disabled) {
            background: var(--accent-forest);
            color: var(--bg-paper);
          }
          .lang-btn:disabled {
            color: var(--ink-muted);
            cursor: not-allowed;
          }
          .lang-btn:focus-visible {
            outline: 2px solid var(--accent-forest);
            outline-offset: 2px;
          }
          .eyebrow {
            font-size: 12px;
            font-weight: 600;
            color: var(--accent-forest);
            margin: 0 0 8px;
          }
          h1, h2, h3 {
            font-family: var(--font-serif);
            text-wrap: balance;
            color: var(--ink-primary);
            margin: 0;
          }
          h1 {
            font-size: 26px;
            line-height: 1.25;
            margin-bottom: 8px;
          }
          h2 {
            font-size: 18px;
            line-height: 1.3;
            margin-bottom: 12px;
          }
          .subtitle {
            margin: 0;
            color: var(--ink-secondary);
            font-size: 13px;
          }
          .kpi-strip {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(175px, 1fr));
            gap: 12px;
            margin-bottom: 20px;
          }
          .kpi-card {
            background: var(--bg-paper);
            border: 1px solid var(--border-stone);
            border-radius: 6px;
            padding: 12px 16px;
          }
          .kpi-label {
            font-size: 12px;
            font-weight: 500;
            color: var(--ink-secondary);
            margin-bottom: 4px;
          }
          .kpi-value {
            font-family: var(--font-mono);
            font-variant-numeric: tabular-nums;
            font-size: 22px;
            font-weight: 700;
            color: var(--accent-forest);
          }
          .kpi-note {
            font-size: 12px;
            color: var(--ink-muted);
            margin-top: 4px;
          }
          section.panel {
            background: var(--bg-paper);
            border: 1px solid var(--border-stone);
            border-radius: 6px;
            padding: 20px 24px;
            margin-bottom: 20px;
          }
          table {
            width: 100%;
            border-collapse: collapse;
            font-size: 13px;
          }
          th {
            text-align: left;
            padding: 8px 12px;
            background: var(--bg-vellum);
            border-bottom: 1px solid var(--border-stone);
            font-size: 12px;
            font-weight: 600;
            color: var(--ink-secondary);
          }
          td {
            padding: 8px 12px;
            border-bottom: 1px solid var(--border-stone);
            vertical-align: top;
          }
          tr:last-child td {
            border-bottom: none;
          }
          .mono {
            font-family: var(--font-mono);
            font-variant-numeric: tabular-nums;
            font-size: 12px;
          }
          .num {
            text-align: right;
          }
          .pill {
            display: inline-block;
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 11px;
            font-weight: 600;
            white-space: nowrap;
          }
          .pill-ok {
            background: var(--status-ok-bg);
            color: var(--status-ok-fg);
          }
          .pill-warn {
            background: var(--status-warn-bg);
            color: var(--status-warn-fg);
          }
          .pill-block {
            background: var(--status-block-bg);
            color: var(--status-block-fg);
          }
          .pill-neutral {
            background: var(--bg-vellum);
            color: var(--ink-secondary);
          }
          .svg-frame {
            overflow-x: auto;
            padding: 8px 0;
          }
          .bib-preview {
            background: var(--bg-vellum);
            border: 1px solid var(--border-stone);
            border-radius: 4px;
            padding: 12px 16px;
            margin-top: 16px;
            font-size: 12.5px;
            white-space: pre-wrap;
          }
          footer {
            text-align: center;
            color: var(--ink-muted);
            font-size: 12px;
            margin-top: 28px;
          }
          </style>
        </head>
        <body>
          <div class="container">
            <header class="masthead">
              \(isDemo ? "<p><span class=\"pill pill-warn\" data-en=\"[DEMO] Sample Unverified Dataset\" data-zh=\"[DEMO / 演示数据] 示例未核查数据集\">[DEMO] Sample Unverified Dataset</span></p>" : "")
              <div class="masthead-row">
                <div>
                  <p class="eyebrow" data-en="ScholarOS v1.3.0, Reproducible Academic Audit Dossier" data-zh="ScholarOS v1.3.0，可复现学术手稿与引文核验档案">ScholarOS v1.3.0, Reproducible Academic Audit Dossier</p>
                  <h1 data-en="\(escapeAttr(title))" data-zh="\(escapeAttr(titleZh))">\(escapeHTML(title))</h1>
                  <p class="subtitle" data-en="\(escapeAttr(subtitleEn))" data-zh="\(escapeAttr(subtitleZh))">\(escapeHTML(subtitleEn))</p>
                </div>
                <div class="lang-toggle" role="group" aria-label="Language switcher">
                  <button type="button" class="lang-btn" id="btn-lang-zh" data-lang-choice="zh" aria-pressed="false">中文</button>
                  <button type="button" class="lang-btn is-active" id="btn-lang-en" data-lang-choice="en" aria-pressed="true">EN</button>
                </div>
              </div>
            </header>

            <div class="kpi-strip">
              <div class="kpi-card">
                <div class="kpi-label" data-en="Manuscript Words" data-zh="手稿总词数">Manuscript Words</div>
                <div class="kpi-value">\(stats.manuscriptWordCount)</div>
                <div class="kpi-note" data-en="\(manuscriptFiles.count) source file(s)" data-zh="共 \(manuscriptFiles.count) 份源码文件">\(manuscriptFiles.count) source file(s)</div>
              </div>
              <div class="kpi-card">
                <div class="kpi-label" data-en="Verified References" data-zh="已核验参考文献">Verified References</div>
                <div class="kpi-value">\(stats.verifiedCitationCount) / \(stats.bibliographyCount)</div>
                <div class="kpi-note" data-en="\(stats.blockedCitationCount) blocked by firewall" data-zh="防火墙已拦截 \(stats.blockedCitationCount) 篇">\(stats.blockedCitationCount) blocked by firewall</div>
              </div>
              <div class="kpi-card">
                <div class="kpi-label" data-en="PRISMA Cohen Kappa" data-zh="PRISMA 双盲一致性 Kappa">PRISMA Cohen Kappa</div>
                <div class="kpi-value">\(String(format: "%.3f", stats.cohensKappa))</div>
                <div class="kpi-note" data-en="\(studies.count) dual-blind studies" data-zh="共 \(studies.count) 篇双盲筛查研究">\(studies.count) dual-blind studies</div>
              </div>
              <div class="kpi-card">
                <div class="kpi-label" data-en="PDF Provenance" data-zh="PDF 证据溯源段落">PDF Provenance</div>
                <div class="kpi-value">\(stats.indexedPDFPassageCount)</div>
                <div class="kpi-note" data-en="\(provenanceLinks.count) linked claims" data-zh="已对齐 \(provenanceLinks.count) 条正文断言">\(provenanceLinks.count) linked claims</div>
              </div>
              <div class="kpi-card">
                <div class="kpi-label" data-en="Editorial JS Audit" data-zh="顶会审稿插件发现">Editorial JS Audit</div>
                <div class="kpi-value">\(editorialSummary.findings.count)</div>
                <div class="kpi-note" data-en="\(editorialSummary.blockerCount) submission blocker(s)" data-zh="含 \(editorialSummary.blockerCount) 项投稿阻断问题">\(editorialSummary.blockerCount) submission blocker(s)</div>
              </div>
            </div>

            <section class="panel">
              <h2 data-en="1. Numbered Manuscript Outline &amp; Section Telemetry" data-zh="1. 手稿章节大纲与字数统计">1. Numbered Manuscript Outline &amp; Section Telemetry</h2>
              <table>
                <thead>
                  <tr>
                    <th data-en="Section" data-zh="章节号">Section</th>
                    <th data-en="Heading Title" data-zh="章节标题">Heading Title</th>
                    <th data-en="Source Span" data-zh="源码定位">Source Span</th>
                    <th class="num" data-en="Words" data-zh="词数">Words</th>
                  </tr>
                </thead>
                <tbody>
                  \(outlineRows)
                </tbody>
              </table>
            </section>

            <section class="panel">
              <h2 data-en="2. 5-Class Citation Verification Firewall Ledger" data-zh="2. 五级引文真实性核验防火墙台账">2. 5-Class Citation Verification Firewall Ledger</h2>
              <table>
                <thead>
                  <tr>
                    <th data-en="Cite Key" data-zh="引文键">Cite Key</th>
                    <th data-en="Firewall Class" data-zh="防火墙分级">Firewall Class</th>
                    <th data-en="Persistent ID" data-zh="权威标识符">Persistent ID</th>
                    <th data-en="Formatted APA 7th Entry" data-zh="APA 7th 标准引文格式">Formatted APA 7th Entry</th>
                  </tr>
                </thead>
                <tbody>
                  \(bibRows)
                </tbody>
              </table>
              <div class="bib-preview">\(escapeHTML(sanitizeCopy(formattedBib.plainText)))</div>
            </section>

            <section class="panel">
              <h2 data-en="3. Claim-to-PDF Bounding-Box Provenance &amp; Entailment" data-zh="3. 手稿断言至 PDF 边界框证据溯源矩阵">3. Claim-to-PDF Bounding-Box Provenance &amp; Entailment</h2>
              <table>
                <thead>
                  <tr>
                    <th data-en="Manuscript Line" data-zh="手稿行号">Manuscript Line</th>
                    <th data-en="Source Passage" data-zh="原文献段落">Source Passage</th>
                    <th data-en="Entailment Verdict" data-zh="证据核验结论">Entailment Verdict</th>
                    <th class="num" data-en="BM25" data-zh="BM25 分值">BM25</th>
                    <th data-en="Claim Excerpt" data-zh="手稿断言摘录">Claim Excerpt</th>
                  </tr>
                </thead>
                <tbody>
                  \(provenanceRows)
                </tbody>
              </table>
            </section>

            <section class="panel">
              <h2 data-en="4. PRISMA 2020 Dual-Blind Screening Flow" data-zh="4. PRISMA 2020 双盲系统综述文献筛选流图">4. PRISMA 2020 Dual-Blind Screening Flow</h2>
              <div class="svg-frame">
                \(prismaSVG)
              </div>
            </section>

            <section class="panel">
              <h2 data-en="5. JavaScriptCore Editorial Plugin Findings" data-zh="5. JavaScriptCore 隔离沙盒顶会审稿插件报告">5. JavaScriptCore Editorial Plugin Findings</h2>
              <table>
                <thead>
                  <tr>
                    <th data-en="Severity" data-zh="严重级别">Severity</th>
                    <th data-en="Location" data-zh="源码位置">Location</th>
                    <th data-en="Plugin" data-zh="审稿插件">Plugin</th>
                    <th data-en="Editorial Explanation" data-zh="学术审计说明">Editorial Explanation</th>
                  </tr>
                </thead>
                <tbody>
                  \(editorialRows)
                </tbody>
              </table>
            </section>

            <footer data-en="Generated locally by ScholarOS 1.3.0, Cambridge Linen Archival Engine, Citation Verification Firewall" data-zh="由 ScholarOS 1.3.0 本地离线生成，剑桥亚麻学术排版引擎与五级引文真实性防火墙">
              Generated locally by ScholarOS 1.3.0, Cambridge Linen Archival Engine, Citation Verification Firewall
            </footer>
          </div>
          <script>
          (function () {
            var STORAGE_KEY = "io.github.zxu756.ScholarOS.language";
            var btnZh = document.getElementById("btn-lang-zh");
            var btnEn = document.getElementById("btn-lang-en");

            function applyLanguage(lang) {
              var resolved = (lang === "zh" || lang === "zh-Hans") ? "zh" : "en";
              document.documentElement.lang = resolved === "zh" ? "zh-CN" : "en";
              var nodes = document.querySelectorAll("[data-en][data-zh]");
              for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                var nextText = resolved === "zh" ? el.getAttribute("data-zh") : el.getAttribute("data-en");
                if (nextText !== null) {
                  el.textContent = nextText;
                }
              }
              if (btnZh && btnEn) {
                var zhActive = resolved === "zh";
                btnZh.classList.toggle("is-active", zhActive);
                btnZh.setAttribute("aria-pressed", zhActive ? "true" : "false");
                btnEn.classList.toggle("is-active", !zhActive);
                btnEn.setAttribute("aria-pressed", !zhActive ? "true" : "false");
              }
              try {
                window.localStorage.setItem(STORAGE_KEY, resolved === "zh" ? "zh-Hans" : "en");
              } catch (_) {}
            }

            function detectInitialLanguage() {
              try {
                var saved = window.localStorage.getItem(STORAGE_KEY);
                if (saved && saved.toLowerCase().indexOf("zh") === 0) return "zh";
                if (saved && saved.toLowerCase().indexOf("en") === 0) return "en";
              } catch (_) {}
              var nav = (window.navigator && window.navigator.language) ? window.navigator.language.toLowerCase() : "en";
              return nav.indexOf("zh") === 0 ? "zh" : "en";
            }

            if (btnZh) {
              btnZh.addEventListener("click", function () { applyLanguage("zh"); });
            }
            if (btnEn) {
              btnEn.addEventListener("click", function () { applyLanguage("en"); });
            }
            applyLanguage(detectInitialLanguage());
          })();
          </script>
        </body>
        </html>
        """
    }

    private func bilingualizePrismaSVG(_ rawSVG: String, metrics: PRISMA2020SummaryMetrics) -> String {
        var svg = rawSVG
        if !svg.contains("aria-label=") {
            svg = svg.replacingOccurrences(
                of: "<svg ",
                with: #"<svg aria-label="PRISMA 2020 systematic review flow diagram" "#
            )
        }
        let pairs: [(en: String, zh: String)] = [
            ("1. Identification", "1. 文献检索识别"),
            ("2. Dual-Blind Screening", "2. 双盲题摘初筛"),
            ("3. Report Retrieval", "3. 全文报告调取"),
            ("4. Full-Text Eligibility", "4. 全文合格性评估"),
            ("5. Included Cohort", "5. 最终纳入队列"),
            ("Pre-Screening Deduplication", "初筛前重复剔除"),
            ("Title &amp; Abstract Exclusions", "标题与摘要排除"),
            ("Unretrieved Reports", "未获取全文报告"),
            ("Duplicates removed: n = \(metrics.duplicateRecordsRemoved)", "去重剔除记录：n = \(metrics.duplicateRecordsRemoved)"),
            ("Excluded records: n = \(metrics.recordsExcludedTitleAbstract)", "初筛排除记录：n = \(metrics.recordsExcludedTitleAbstract)"),
            ("Reports not retrieved: n = \(metrics.reportsNotRetrieved)", "未能获取全文：n = \(metrics.reportsNotRetrieved)"),
            ("Reports sought for retrieval: n = \(metrics.reportsSoughtForRetrieval)", "拟调取全文报告：n = \(metrics.reportsSoughtForRetrieval)"),
            ("Full-text reports assessed: n = \(metrics.fullTextAssessed)", "完成全文评估：n = \(metrics.fullTextAssessed)"),
            ("Studies included in synthesis: n = \(metrics.finalIncludedStudies)", "最终纳入综合分析：n = \(metrics.finalIncludedStudies)"),
            (">None<", #" data-en="None" data-zh="无">None<"#)
        ]
        for pair in pairs {
            if pair.en == ">None<" {
                svg = svg.replacingOccurrences(of: pair.en, with: pair.zh)
            } else {
                svg = svg.replacingOccurrences(
                    of: ">\(pair.en)<",
                    with: #" data-en="\#(pair.en)" data-zh="\#(pair.zh)">\#(pair.en)<"#
                )
            }
        }
        return svg
    }

    private func localizedProjectTitleZh(_ enTitle: String, isDemo: Bool) -> String {
        let stripped: String
        let hasDemoPrefix: Bool
        if enTitle.hasPrefix("[DEMO] ") {
            stripped = String(enTitle.dropFirst("[DEMO] ".count))
            hasDemoPrefix = true
        } else {
            stripped = enTitle
            hasDemoPrefix = isDemo
        }
        let baseZh: String
        if stripped == "Verifiable Citation Firewalls & Sandboxes" {
            baseZh = "可验证引文真实性防火墙与隔离审稿沙盒"
        } else if stripped == "Citation Audit & Academic Sample" {
            baseZh = "引文核查与学术手稿示例"
        } else {
            baseZh = sanitizeCopy(stripped)
        }
        return hasDemoPrefix ? "[DEMO / 演示数据] \(baseZh)" : baseZh
    }

    private func localizedOutlineHeadingZh(_ enHeading: String) -> String {
        switch enHeading {
        case "Introduction": return "引言"
        case "Citation Verification Firewall", "Citation Verification Rules": return "引文真实性核验规则"
        case "Provenance & Psychometrics": return "PDF 证据溯源与心理测量信度"
        case "Methodology": return "研究方法"
        default: return enHeading
        }
    }

    private func sanitizeCopy(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\u{2014}", with: ", ")
            .replacingOccurrences(of: "\u{2013}", with: " to ")
            .replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: "Cohen's", with: "Cohen\u{2019}s")
            .replacingOccurrences(of: "Byrt's", with: "Byrt\u{2019}s")
            .replacingOccurrences(of: "Gwet's", with: "Gwet\u{2019}s")
            .replacingOccurrences(of: "Student's", with: "Student\u{2019}s")
            .replacingOccurrences(of: "Fisher's", with: "Fisher\u{2019}s")
            .replacingOccurrences(of: "Hedges'", with: "Hedges\u{2019}")
    }

    private func escapeHTML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func escapeAttr(_ raw: String) -> String {
        escapeHTML(raw)
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
