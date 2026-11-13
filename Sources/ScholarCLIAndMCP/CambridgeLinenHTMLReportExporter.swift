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

// MARK: - Hallmark-Clean Cambridge Linen Academic Audit HTML Dossier Exporter

public struct CambridgeLinenHTMLReportExporter: Sendable {
    public init() {}

    public func exportHTMLDossier(database: ScholarProjectDatabase) throws -> String {
        let stats = try database.computeProjectStats()
        let title = sanitizeNoEmDash(stats.projectTitle)
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
        let auditRunner = EditorialPluginAuditRunner()
        let editorialSummary = try auditRunner.run(
            files: filesMap,
            primaryFilePath: stats.primaryManuscriptFile,
            bibliography: entries
        )

        let cslFormatter = CSLCitationFormatterEngine()
        let formattedBib = cslFormatter.formatBibliography(
            entries: entries.filter { $0.firewallClass.allowsManuscriptInsertion },
            style: .apa7
        )
        let prismaSVG = PRISMA2020DiagramExporter().exportVectorSVG(metrics: prismaMetrics)

        let outlineRows = outline.map { item in
            let indentPx = max(0, (item.level - 1) * 16)
            return """
            <tr>
              <td class="mono">\(escapeHTML(item.numberPrefix))</td>
              <td style="padding-left:\(12 + indentPx)px">\(escapeHTML(sanitizeNoEmDash(item.title)))</td>
              <td class="mono">\(escapeHTML(item.filePath)):\(item.line)</td>
              <td class="mono num">\(item.wordCountInSection)</td>
            </tr>
            """
        }.joined(separator: "\n")

        let bibRows = entries.map { entry in
            let badgeClass: String
            switch entry.firewallClass {
            case .verifiedCanonicalDOI, .verifiedPreprintRegistry:
                badgeClass = "pill-ok"
            case .metadataDriftAdvisory:
                badgeClass = "pill-warn"
            case .unverifiedPendingCheck, .blockedHallucinatedOrRetracted:
                badgeClass = "pill-block"
            }
            let pidText: String
            if let doi = entry.doi, !doi.isEmpty {
                pidText = "doi:\(doi)"
            } else if let arxiv = entry.arxivID, !arxiv.isEmpty {
                pidText = "arXiv:\(arxiv)"
            } else if let pmid = entry.pmid, !pmid.isEmpty {
                pidText = "PMID:\(pmid)"
            } else {
                pidText = "none"
            }
            let apaLine = cslFormatter.formatEntry(entry, style: .apa7).bibliographyUnnumberedPlainText
            return """
            <tr>
              <td class="mono">\(escapeHTML(entry.citeKey))</td>
              <td><span class="pill \(badgeClass)">\(escapeHTML(entry.firewallClass.badgeTitle))</span></td>
              <td class="mono">\(escapeHTML(sanitizeNoEmDash(pidText)))</td>
              <td>\(escapeHTML(sanitizeNoEmDash(apaLine)))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let provenanceRows = provenanceLinks.prefix(12).map { link in
            let verdictClass: String
            switch link.verdict {
            case .groundedEntailment:
                verdictClass = "pill-ok"
            case .partialEvidence:
                verdictClass = "pill-warn"
            case .numericDiscrepancy, .unsupportedClaim:
                verdictClass = "pill-block"
            }
            return """
            <tr>
              <td class="mono">\(escapeHTML(link.manuscriptFile)):\(link.manuscriptLine)</td>
              <td class="mono">\(escapeHTML(link.citeKey)) · p.\(link.boundingBox.pageIndex + 1)</td>
              <td><span class="pill \(verdictClass)">\(escapeHTML(link.verdict.rawValue))</span></td>
              <td class="mono num">\(String(format: "%.2f", link.bm25Score))</td>
              <td>\(escapeHTML(sanitizeNoEmDash(link.manuscriptClaim)))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let editorialRows = editorialSummary.findings.prefix(12).map { finding in
            let sevClass: String
            switch finding.severity {
            case .submissionBlocker:
                sevClass = "pill-block"
            case .rigorWarning:
                sevClass = "pill-warn"
            case .styleSuggestion, .note:
                sevClass = "pill-neutral"
            }
            return """
            <tr>
              <td><span class="pill \(sevClass)">\(escapeHTML(finding.severity.rawValue))</span></td>
              <td class="mono">\(escapeHTML(finding.filePath)):\(finding.line)</td>
              <td>\(escapeHTML(sanitizeNoEmDash(finding.pluginName)))</td>
              <td>\(escapeHTML(sanitizeNoEmDash(finding.explanation)))</td>
            </tr>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="description" content="ScholarOS reproducible academic manuscript, Citation Verification Firewall, PDF provenance, and PRISMA 2020 screening audit dossier.">
          <title>ScholarOS Audit Dossier: \(escapeHTML(title))</title>
          <style>
          /* Hallmark · v2.0.0 · scope: app · genre: editorial-archival · posture: restrained · shape: app screen · surface: absolute */
          :root {
            --bg-linen: #F8F6F0;
            --bg-paper: #FFFFFF;
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
          body {
            margin: 0;
            padding: 32px 24px 56px;
            background: var(--bg-linen);
            color: var(--ink-primary);
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
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
          .eyebrow {
            font-size: 11px;
            font-weight: 700;
            letter-spacing: 0.08em;
            text-transform: uppercase;
            color: var(--accent-forest);
            margin: 0 0 6px;
          }
          h1, h2, h3 {
            font-family: Georgia, "Times New Roman", serif;
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
            padding: 14px 16px;
          }
          .kpi-label {
            font-size: 11px;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: var(--ink-secondary);
            margin-bottom: 4px;
          }
          .kpi-value {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-variant-numeric: tabular-nums;
            font-size: 22px;
            font-weight: 700;
            color: var(--accent-forest);
          }
          .kpi-note {
            font-size: 12px;
            color: var(--ink-muted);
            margin-top: 2px;
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
            padding: 9px 12px;
            background: var(--bg-vellum);
            border-bottom: 1px solid var(--border-stone);
            font-size: 11px;
            text-transform: uppercase;
            letter-spacing: 0.04em;
            color: var(--ink-secondary);
          }
          td {
            padding: 9px 12px;
            border-bottom: 1px solid var(--border-stone);
            vertical-align: top;
          }
          tr:last-child td {
            border-bottom: none;
          }
          .mono {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-variant-numeric: tabular-nums;
            font-size: 12px;
          }
          .num {
            text-align: right;
          }
          .pill {
            display: inline-block;
            padding: 2px 8px;
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
            padding: 12px 14px;
            margin-top: 14px;
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
              <p class="eyebrow">ScholarOS v1.0.0 · Reproducible Academic Audit Dossier</p>
              <h1>\(escapeHTML(title))</h1>
              <p class="subtitle">Primary Manuscript: <span class="mono">\(escapeHTML(stats.primaryManuscriptFile))</span> · Schema v\(stats.schemaVersion) · LSP Errors: \(diagReport.errorCount) · Firewall Violations: \(diagReport.firewallViolationCount)</p>
            </header>

            <div class="kpi-strip">
              <div class="kpi-card">
                <div class="kpi-label">Manuscript Words</div>
                <div class="kpi-value">\(stats.manuscriptWordCount)</div>
                <div class="kpi-note">\(manuscriptFiles.count) source file(s)</div>
              </div>
              <div class="kpi-card">
                <div class="kpi-label">Verified References</div>
                <div class="kpi-value">\(stats.verifiedCitationCount) / \(stats.bibliographyCount)</div>
                <div class="kpi-note">\(stats.blockedCitationCount) blocked by firewall</div>
              </div>
              <div class="kpi-card">
                <div class="kpi-label">PRISMA Cohen Kappa</div>
                <div class="kpi-value">\(String(format: "%.3f", stats.cohensKappa))</div>
                <div class="kpi-note">\(studies.count) dual-blind studies</div>
              </div>
              <div class="kpi-card">
                <div class="kpi-label">PDF Provenance</div>
                <div class="kpi-value">\(stats.indexedPDFPassageCount)</div>
                <div class="kpi-note">\(provenanceLinks.count) linked claims</div>
              </div>
              <div class="kpi-card">
                <div class="kpi-label">Editorial JS Audit</div>
                <div class="kpi-value">\(editorialSummary.findings.count)</div>
                <div class="kpi-note">\(editorialSummary.blockerCount) submission blocker(s)</div>
              </div>
            </div>

            <section class="panel">
              <h2>1. Numbered Manuscript Outline &amp; Section Telemetry</h2>
              <table>
                <thead>
                  <tr>
                    <th>Section</th>
                    <th>Heading Title</th>
                    <th>Source Span</th>
                    <th class="num">Words</th>
                  </tr>
                </thead>
                <tbody>
                  \(outlineRows)
                </tbody>
              </table>
            </section>

            <section class="panel">
              <h2>2. 5-Class Citation Verification Firewall Ledger</h2>
              <table>
                <thead>
                  <tr>
                    <th>Cite Key</th>
                    <th>Firewall Class</th>
                    <th>Persistent ID</th>
                    <th>Formatted APA 7th Entry</th>
                  </tr>
                </thead>
                <tbody>
                  \(bibRows)
                </tbody>
              </table>
              <div class="bib-preview">\(escapeHTML(sanitizeNoEmDash(formattedBib.plainText)))</div>
            </section>

            <section class="panel">
              <h2>3. Claim-to-PDF Bounding-Box Provenance &amp; Entailment</h2>
              <table>
                <thead>
                  <tr>
                    <th>Manuscript Line</th>
                    <th>Source Passage</th>
                    <th>Entailment Verdict</th>
                    <th class="num">BM25</th>
                    <th>Claim Excerpt</th>
                  </tr>
                </thead>
                <tbody>
                  \(provenanceRows)
                </tbody>
              </table>
            </section>

            <section class="panel">
              <h2>4. PRISMA 2020 Dual-Blind Screening Flow</h2>
              <div class="svg-frame">
                \(sanitizeNoEmDash(prismaSVG))
              </div>
            </section>

            <section class="panel">
              <h2>5. JavaScriptCore Editorial Plugin Findings</h2>
              <table>
                <thead>
                  <tr>
                    <th>Severity</th>
                    <th>Location</th>
                    <th>Plugin</th>
                    <th>Editorial Explanation</th>
                  </tr>
                </thead>
                <tbody>
                  \(editorialRows)
                </tbody>
              </table>
            </section>

            <footer>
              Generated locally by ScholarOS 1.0.0 · Cambridge Linen Archival Engine · Hardware-Gated Citation Verification Firewall
            </footer>
          </div>
        </body>
        </html>
        """
    }

    private func sanitizeNoEmDash(_ input: String) -> String {
        input.replacingOccurrences(of: "—", with: " - ")
    }

    private func escapeHTML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
