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

// MARK: - Hardware-Gated JSON-RPC 2.0 MCP Server (Enforces ERR_UNVERIFIED_CITATION)

public struct ScholarHardwareGatedMCPServer: Sendable {
    public let defaultProjectBundlePath: String?

    public init(defaultProjectBundlePath: String? = nil) {
        self.defaultProjectBundlePath = defaultProjectBundlePath
    }

    public func handleJSONRPCLine(_ rawLine: String) -> String? {
        guard let data = rawLine.data(using: .utf8),
              let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = req["method"] as? String else {
            return nil
        }
        let idVal = req["id"]

        let resultPayload: Any
        switch method {
        case "initialize":
            resultPayload = [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": [
                    "name": "scholaros-mcp",
                    "version": "1.0.0"
                ]
            ]

        case "tools/list":
            resultPayload = ["tools": Self.toolDefinitions]

        case "tools/call":
            let params = req["params"] as? [String: Any] ?? [:]
            let toolName = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            resultPayload = executeToolCall(name: toolName, arguments: arguments)

        default:
            if idVal == nil { return nil }
            resultPayload = [String: Any]()
        }

        guard let idVal else { return nil }
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": idVal,
            "result": resultPayload
        ]
        guard let outData = try? JSONSerialization.data(withJSONObject: envelope) else {
            return nil
        }
        return String(decoding: outData, as: UTF8.self)
    }

    public func serveStdio() async {
        while let line = readLine() {
            if let response = handleJSONRPCLine(line) {
                print(response)
                fflush(stdout)
            }
        }
    }

    // MARK: - Tool Execution Router

    public func executeToolCall(name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "scholar_cite_key":
                let citeKey = (arguments["citeKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let styleRaw = (arguments["style"] as? String ?? "apa7").lowercased()
                let formatRaw = (arguments["manuscriptFormat"] as? String ?? "latex").lowercased()
                let db = try openDatabase(from: arguments)
                defer { db.close() }

                let entries = try db.listBibliographyEntries()
                var byKey: [String: BibliographyEntry] = [:]
                for entry in entries {
                    byKey[entry.citeKey] = entry
                }

                // Hardware-gated Citation Verification Firewall: throws ERR_UNVERIFIED_CITATION if missing, unverified, or hallucinated!
                let verifiedEntry = try CitationVerificationFirewall().assertCitationAllowed(
                    citeKey: citeKey,
                    in: byKey
                )
                let style: CitationFormatStyle
                switch styleRaw {
                case "ieee": style = .ieee
                case "acm": style = .acm
                case "nature": style = .nature
                case "vancouver": style = .vancouver
                default: style = .apa7
                }
                let formatted = CSLCitationFormatterEngine().formatEntry(verifiedEntry, style: style)
                let snippet = formatRaw == "typst" ? formatted.inTextTypst : formatted.inTextLaTeX
                let payloadText = """
                [FIREWALL_CLEARED:\(verifiedEntry.firewallClass.rawValue)]
                Snippet: \(snippet)
                Reference (\(style.rawValue)): \(formatted.bibliographyPlainText)
                """
                return textResult(payloadText, isError: false)

            case "scholar_verify_bibliography":
                let db = try openDatabase(from: arguments)
                defer { db.close() }
                let entries: [BibliographyEntry]
                if let rawBib = arguments["bibtex"] as? String, !rawBib.isEmpty {
                    entries = try BibTeXCodec().parse(rawBib)
                } else {
                    entries = try db.listBibliographyEntries()
                }
                let report = CitationVerificationFirewall().auditLibrary(entries)
                let data = try JSONEncoder().encode(report)
                return textResult(String(decoding: data, as: UTF8.self), isError: false)

            case "scholar_lsp_diagnostics":
                let db = try openDatabase(from: arguments)
                defer { db.close() }
                let entries = try db.listBibliographyEntries()
                var files: [String: String] = [:]
                if let inlineSource = arguments["source"] as? String {
                    let path = arguments["filePath"] as? String ?? "main.tex"
                    files[path] = inlineSource
                } else {
                    for rec in try db.listManuscriptFiles() {
                        files[rec.path] = rec.content
                    }
                }
                let primary = arguments["filePath"] as? String ?? ((try? db.primaryManuscriptFile()) ?? "main.tex")
                let lsp = ScholarLSPWorkspaceService(
                    rootFilePath: primary,
                    files: files,
                    bibliography: entries
                )
                let diagReport = lsp.diagnosticsReport()
                let data = try JSONEncoder().encode(diagReport.diagnostics)
                return textResult(
                    String(decoding: data, as: UTF8.self),
                    isError: diagReport.firewallViolationCount > 0
                )

            case "scholar_search_provenance":
                let claim = arguments["claim"] as? String ?? ""
                let db = try openDatabase(from: arguments)
                defer { db.close() }
                let passages = try db.listPDFPassages()
                let fts = try FTS5ProvenanceIndex()
                try fts.indexPassages(passages)
                let hits = try fts.searchPassages(
                    query: claim,
                    citeKeyFilter: arguments["citeKey"] as? String,
                    limit: arguments["topK"] as? Int ?? 5
                ).map(\.chunk)
                let data = try JSONEncoder().encode(hits)
                return textResult(String(decoding: data, as: UTF8.self), isError: false)

            case "scholar_prisma_agreement":
                let db = try openDatabase(from: arguments)
                defer { db.close() }
                let studies = try db.listScreeningStudies()
                let spec = try db.loadPRISMAProtocol() ?? PICOProtocolSpec(
                    reviewTitle: "Systematic Review",
                    population: "Agent benchmarks",
                    intervention: "Sandboxed tool verification",
                    comparator: "Unverified baseline",
                    outcomes: "Citation precision",
                    inclusionCriteria: ["Empirical benchmark evaluation"],
                    exclusionRules: []
                )
                let qc = InterRaterReliabilityAndSeedQCEngine().evaluateDualRaterAgreement(
                    studies: studies,
                    protocolSpec: spec
                )
                let summary = try db.computePRISMAMetrics()
                let text = String(
                    format: "Studies=%d | Included=%d | Kappa=%.4f | PABAK=%.4f | GwetAC1=%.4f",
                    studies.count,
                    summary.finalIncludedStudies,
                    qc.cohensKappa.pointEstimate,
                    qc.byrtsPABAK.pointEstimate,
                    qc.gwetsAC1.pointEstimate
                )
                return textResult(text, isError: false)

            case "scholar_editorial_audit":
                let db = try openDatabase(from: arguments)
                defer { db.close() }
                let entries = try db.listBibliographyEntries()
                var files: [String: String] = [:]
                if let inlineSource = arguments["source"] as? String {
                    files["main.tex"] = inlineSource
                } else {
                    for rec in try db.listManuscriptFiles() {
                        files[rec.path] = rec.content
                    }
                }
                let runSummary = try EditorialPluginAuditRunner().run(
                    files: files,
                    primaryFilePath: (try? db.primaryManuscriptFile()) ?? "main.tex",
                    bibliography: entries
                )
                let data = try JSONEncoder().encode(runSummary.findings)
                return textResult(String(decoding: data, as: UTF8.self), isError: false)

            case "scholar_track_changes_diff":
                let original = arguments["original"] as? String ?? ""
                let revised = arguments["revised"] as? String ?? ""
                let engine = MyersWordLevelTrackChangesEngine()
                let report = engine.diff(original: original, revised: revised)
                let latexdiff = engine.renderLatexdiffMarkup(from: report)
                return textResult(latexdiff, isError: false)

            case "scholar_citation_gaps":
                let db = try openDatabase(from: arguments)
                defer { db.close() }
                let entries = try db.listBibliographyEntries()
                let primary = (try? db.primaryManuscriptFile()) ?? "main.tex"
                let manuscript = (try? db.manuscriptContent(path: primary)) ?? ""
                let gaps = MainPathAndLiteratureGapAnalyzer().recommendMissingCitationsForManuscript(
                    manuscriptSource: manuscript,
                    corpus: entries,
                    maxRecommendations: 5
                )
                let data = try JSONEncoder().encode(gaps)
                return textResult(String(decoding: data, as: UTF8.self), isError: false)

            default:
                return textResult("[ERR_SCHOLAROS] Unknown MCP tool '\(name)'", isError: true)
            }
        } catch let scholarErr as ScholarOSError {
            let prefix = "[\(scholarErr.errorCodeIdentifier)] "
            let body = scholarErr.errorDescription ?? String(describing: scholarErr)
            let formatted = body.hasPrefix("[") ? body : (prefix + body)
            return textResult(formatted, isError: true)
        } catch {
            return textResult("[ERR_SCHOLAROS] \(error.localizedDescription)", isError: true)
        }
    }

    private func openDatabase(from arguments: [String: Any]) throws -> ScholarProjectDatabase {
        if let projectPath = arguments["projectPath"] as? String, !projectPath.isEmpty {
            return try ScholarProjectDatabase(
                bundleURL: URL(fileURLWithPath: projectPath),
                seedDemoIfEmpty: false
            )
        }
        if let defaultProjectBundlePath, !defaultProjectBundlePath.isEmpty {
            return try ScholarProjectDatabase(
                bundleURL: URL(fileURLWithPath: defaultProjectBundlePath),
                seedDemoIfEmpty: true
            )
        }
        return try ScholarProjectDatabase.inMemory(seedDemo: true)
    }

    private func textResult(_ text: String, isError: Bool) -> [String: Any] {
        [
            "content": [
                ["type": "text", "text": text]
            ],
            "isError": isError
        ]
    }

    public static var toolDefinitions: [[String: Any]] {
        [
        [
            "name": "scholar_cite_key",
            "description": "Hardware-gated citation insertion check. Returns formatted \\cite{key} or #cite(<key>) ONLY if the Citation Verification Firewall clears the entry; otherwise returns ERR_UNVERIFIED_CITATION.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "citeKey": ["type": "string"],
                    "style": ["type": "string"],
                    "manuscriptFormat": ["type": "string"],
                    "projectPath": ["type": "string"]
                ],
                "required": ["citeKey"]
            ]
        ],
        [
            "name": "scholar_verify_bibliography",
            "description": "Audit a BibTeX string or .scholarproj bibliography through the 5-class Citation Verification Firewall.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bibtex": ["type": "string"],
                    "projectPath": ["type": "string"]
                ]
            ]
        ],
        [
            "name": "scholar_lsp_diagnostics",
            "description": "Run the built-in LaTeX/Typst CST, cross-reference, float-label, and Citation Firewall LSP diagnostics engine.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "source": ["type": "string"],
                    "filePath": ["type": "string"],
                    "projectPath": ["type": "string"]
                ]
            ]
        ],
        [
            "name": "scholar_search_provenance",
            "description": "Search indexed PDF passages via SQLite FTS5 BM25 to verify manuscript claims against bounding-box evidence.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "claim": ["type": "string"],
                    "filePath": ["type": "string"],
                    "line": ["type": "integer"],
                    "topK": ["type": "integer"],
                    "projectPath": ["type": "string"]
                ],
                "required": ["claim"]
            ]
        ],
        [
            "name": "scholar_prisma_agreement",
            "description": "Compute PRISMA 2020 flow counts and dual-rater Cohen's kappa, Byrt's PABAK, and Gwet's AC1.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "projectPath": ["type": "string"]
                ]
            ]
        ],
        [
            "name": "scholar_editorial_audit",
            "description": "Run the 4 sandboxed JavaScriptCore editorial plugins (overclaiming, anti-AI prose, APA statistics, venue gate).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "source": ["type": "string"],
                    "projectPath": ["type": "string"]
                ]
            ]
        ],
        [
            "name": "scholar_track_changes_diff",
            "description": "Compute Myers O(ND) word-level LaTeX/Typst track-changes diff and emit compilable latexdiff markup.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "original": ["type": "string"],
                    "revised": ["type": "string"]
                ],
                "required": ["original", "revised"]
            ]
        ],
        [
            "name": "scholar_citation_gaps",
            "description": "Analyze citation network main paths and structural bridges to recommend missing verified foundational papers.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "projectPath": ["type": "string"]
                ]
            ]
        ]
        ]
    }
}
