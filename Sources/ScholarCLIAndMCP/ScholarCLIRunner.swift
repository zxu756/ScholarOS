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

// MARK: - 15-Subcommand Headless Academic CLI Runner

public struct ScholarCLIRunner: Sendable {
    public init() {}

    public func execute(arguments: [String]) async throws -> String {
        guard let subcommand = arguments.first else {
            return Self.helpBanner
        }
        let rest = Array(arguments.dropFirst())

        switch subcommand {
        case "help", "--help", "-h":
            return Self.helpBanner

        case "version", "--version":
            return "ScholarOS 1.0.0 (macOS arm64 · LaTeX/Typst Incremental LSP + Citation Firewall + PRISMA 2020)"

        case "init":
            let bundlePath = optionValue("--project", in: rest) ?? "ResearchStudy.scholarproj"
            let seed = rest.contains("--seed-demo")
            let db = try ScholarProjectDatabase(
                bundleURL: URL(fileURLWithPath: bundlePath),
                seedDemoIfEmpty: seed
            )
            defer { db.close() }
            if seed, (try? db.listBibliographyEntries().isEmpty) == true {
                try db.seedDeterministicResearchProject()
            }
            let stats = try db.computeProjectStats()
            return "Initialized \(bundlePath) (words=\(stats.manuscriptWordCount), bib=\(stats.bibliographyCount), verified=\(stats.verifiedCitationCount), kappa=\(String(format: "%.3f", stats.cohensKappa)))"

        case "status":
            let db = try openDatabase(in: rest)
            defer { db.close() }
            let stats = try db.computeProjectStats()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(stats)
            return String(decoding: data, as: UTF8.self)

        case "outline":
            let db = try openDatabase(in: rest)
            defer { db.close() }
            let lsp = try makeLSPService(from: db)
            return lsp.documentOutline.map { entry in
                let indent = String(repeating: "  ", count: max(0, entry.level - 1))
                return "\(indent)\(entry.numberPrefix) \(entry.title) [\(entry.filePath):\(entry.line) · \(entry.wordCountInSection) words]"
            }.joined(separator: "\n")

        case "diagnostics":
            let db = try openDatabase(in: rest)
            defer { db.close() }
            let lsp = try makeLSPService(from: db)
            let report = lsp.diagnosticsReport()
            if report.diagnostics.isEmpty {
                return "0 diagnostics (all syntax, cross-reference, and firewall checks clean)"
            }
            return report.diagnostics.map { diag in
                "[\(diag.severity.rawValue)] \(diag.code) \(diag.span.filePath):\(diag.span.start.line):\(diag.span.start.column) - \(diag.message)"
            }.joined(separator: "\n")

        case "verify-citations":
            let db = try openDatabase(in: rest)
            defer { db.close() }
            let entries = try db.listBibliographyEntries()
            let firewall = CitationVerificationFirewall()
            if rest.contains("--strict") {
                let lsp = try makeLSPService(from: db)
                try lsp.assertAllCitedEntriesPassFirewall()
            }
            let audit = firewall.auditLibrary(entries)
            return "Evaluated=\(audit.totalEvaluated) VerifiedDOI=\(audit.verifiedDOICount) VerifiedPreprint=\(audit.verifiedPreprintCount) Drift=\(audit.metadataDriftCount) Unverified=\(audit.unverifiedOfflineCount) Blocked=\(entries.filter { $0.firewallClass == .blockedHallucinatedOrRetracted }.count)"

        case "cite":
            guard let citeKey = rest.first(where: { !$0.hasPrefix("--") }) else {
                throw ScholarOSError.invalidCLIArguments("Usage: ScholarOS cite <citeKey> [--project <path.scholarproj>]")
            }
            let db = try openDatabase(in: rest)
            defer { db.close() }
            let verified = try db.validateCitationKeyForInsertion(citeKey)
            let formatted = CSLCitationFormatterEngine().formatEntry(verified, style: .apa7)
            return "\\cite{\(verified.citeKey)} -> \(formatted.bibliographyPlainText)"

        case "format-bib":
            let db = try openDatabase(in: rest)
            defer { db.close() }
            let rawStyle = (optionValue("--style", in: rest) ?? "apa7").lowercased()
            let style: CitationFormatStyle
            switch rawStyle {
            case "ieee": style = .ieee
            case "acm": style = .acm
            case "nature": style = .nature
            case "vancouver": style = .vancouver
            default: style = .apa7
            }
            let entries = try db.listBibliographyEntries().filter { $0.firewallClass.allowsManuscriptInsertion }
            return CSLCitationFormatterEngine().formatBibliography(entries: entries, style: style).plainText

        case "prisma-stats":
            let db = try openDatabase(in: rest)
            defer { db.close() }
            let metrics = try db.computePRISMAMetrics()
            let data = try JSONEncoder().encode(metrics)
            return String(decoding: data, as: UTF8.self)

        case "prisma-svg":
            let outPath = optionValue("--output", in: rest) ?? (rest.first { !$0.hasPrefix("--") } ?? "prisma-flow.svg")
            let db = try openDatabase(in: rest)
            defer { db.close() }
            let metrics = try db.computePRISMAMetrics()
            let svg = PRISMA2020DiagramExporter().exportVectorSVG(metrics: metrics)
            try svg.write(toFile: outPath, atomically: true, encoding: .utf8)
            return "Exported PRISMA 2020 vector SVG to \(outPath)"

        case "citation-graph":
            let db = try openDatabase(in: rest)
            defer { db.close() }
            let entries = try db.listBibliographyEntries()
            let snapshot = CitationGraphBuilder().buildKnowledgeGraph(from: entries)
            return "Nodes=\(snapshot.nodes.count) Edges=\(snapshot.edges.count) Clusters=\(snapshot.clusterLabels.count) Bridges=\(snapshot.bridgeCiteKeys.joined(separator: ","))"

        case "track-changes":
            let db = try openDatabase(in: rest)
            defer { db.close() }
            let snapshots = try db.listSnapshots()
            guard snapshots.count >= 2 else {
                return "Need at least 2 snapshots to diff (found \(snapshots.count))."
            }
            let engine = MyersWordLevelTrackChangesEngine()
            let diff = engine.diffSnapshots(baseline: snapshots[0], revised: snapshots[snapshots.count - 1])
            return "Diff '\(diff.baselineLabel)' -> '\(diff.revisedLabel)': +\(diff.insertedWordCount) / -\(diff.deletedWordCount) words (similarity=\(String(format: "%.1f%%", diff.similarityRatio * 100.0)))"

        case "audit-editorial":
            let db = try openDatabase(in: rest)
            defer { db.close() }
            var files: [String: String] = [:]
            for rec in try db.listManuscriptFiles() {
                files[rec.path] = rec.content
            }
            let entries = try db.listBibliographyEntries()
            let summary = try EditorialPluginAuditRunner().run(
                files: files,
                primaryFilePath: (try? db.primaryManuscriptFile()) ?? "main.tex",
                bibliography: entries
            )
            return summary.findings.map { f in
                "[\(f.severity.rawValue)] \(f.filePath):\(f.line) (\(f.pluginID)): \(f.explanation)"
            }.joined(separator: "\n")

        case "export-bundle":
            let outDir = optionValue("--output", in: rest) ?? (rest.first { !$0.hasPrefix("--") } ?? "arxiv-bundle")
            let db = try openDatabase(in: rest)
            defer { db.close() }
            var opts = SubmissionArchiveOptions.arxivDefault
            opts.allowUnverifiedCitationsOverride = rest.contains("--allow-unverified")
            let manifest = try AcademicArchiveBundleCodec().exportSubmissionBundle(
                from: db,
                to: URL(fileURLWithPath: outDir),
                options: opts
            )
            return "Exported flattened submission bundle to \(outDir) (sha256=\(manifest.bundleRootSHA256), cited=\(manifest.citedKeysInAppearanceOrder.count))"

        case "export-html":
            let outPath = optionValue("--output", in: rest) ?? (rest.first { !$0.hasPrefix("--") } ?? "scholar-dossier.html")
            let db = try openDatabase(in: rest)
            defer { db.close() }
            let html = try CambridgeLinenHTMLReportExporter().exportHTMLDossier(database: db)
            try html.write(toFile: outPath, atomically: true, encoding: .utf8)
            return "Exported Cambridge Linen HTML dossier to \(outPath)"

        case "mcp":
            let projectPath = optionValue("--project", in: rest)
            let server = ScholarHardwareGatedMCPServer(defaultProjectBundlePath: projectPath)
            await server.serveStdio()
            return ""

        default:
            throw ScholarOSError.invalidCLIArguments("Unknown subcommand '\(subcommand)'. Run 'ScholarOS --help'.")
        }
    }

    private func openDatabase(in args: [String]) throws -> ScholarProjectDatabase {
        if let bundlePath = optionValue("--project", in: args) {
            return try ScholarProjectDatabase(
                bundleURL: URL(fileURLWithPath: bundlePath),
                seedDemoIfEmpty: args.contains("--seed-demo")
            )
        }
        return try ScholarProjectDatabase.inMemory(seedDemo: true)
    }

    private func makeLSPService(from db: ScholarProjectDatabase) throws -> ScholarLSPWorkspaceService {
        var files: [String: String] = [:]
        for rec in try db.listManuscriptFiles() {
            files[rec.path] = rec.content
        }
        let entries = try db.listBibliographyEntries()
        let primary = (try? db.primaryManuscriptFile()) ?? "main.tex"
        return ScholarLSPWorkspaceService(
            rootFilePath: primary,
            files: files,
            bibliography: entries
        )
    }

    private func optionValue(_ flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    public static let helpBanner = """
    ScholarOS 1.0.0 - Reproducible LaTeX/Typst Academic Workstation & Citation Firewall
    Subcommands:
      init [--project <dir.scholarproj>] [--seed-demo]    Initialize .scholarproj SQLite WAL bundle
      status [--project <dir.scholarproj>]                Print JSON project & firewall statistics
      outline [--project <dir.scholarproj>]               Print numbered multi-file section outline
      diagnostics [--project <dir.scholarproj>]           Run LaTeX/Typst LSP & Citation Firewall lints
      verify-citations [--project <dir>] [--strict]       Audit bibliography; --strict enforces ERR_UNVERIFIED_CITATION
      cite <citeKey> [--project <dir.scholarproj>]        Hardware-gated single citation check & APA7 format
      format-bib [--style apa7|ieee|acm|nature|vancouver] Render verified bibliography in CSL style
      prisma-stats [--project <dir.scholarproj>]          Print PRISMA 2020 & Cohen's kappa JSON summary
      prisma-svg <out.svg> [--project <dir.scholarproj>]  Export PRISMA 2020 flow diagram SVG
      citation-graph [--project <dir.scholarproj>]        Build PageRank, Louvain & bridge-paper network
      track-changes [--project <dir.scholarproj>]         Diff manuscript snapshots with Myers O(ND) engine
      audit-editorial [--project <dir.scholarproj>]       Run JavaScriptCore editorial plugins
      export-bundle <dir> [--allow-unverified]            Export flattened arXiv/camera-ready submission bundle
      export-html <out.html> [--project <dir>]            Export Hallmark Cambridge Linen HTML audit dossier
      mcp [--project <dir.scholarproj>]                   Start hardware-gated JSON-RPC 2.0 MCP server on stdio
      --export-screenshots <output-dir>                   Render 2x Retina Cambridge Linen screenshots
    """
}
