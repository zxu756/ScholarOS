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

// MARK: - JSON-RPC 2.0 MCP Server (`ScholarMCPServer`)

public struct ScholarMCPServer: Sendable {
    public let defaultProjectBundlePath: String?
    public let allowDemoMode: Bool
    public let defaultRegistryReplayPath: String?
    public let inRunVerdictsByKey: [String: CitationFirewallEntryVerdict]

    public init(
        defaultProjectBundlePath: String? = nil,
        allowDemoMode: Bool = false,
        defaultRegistryReplayPath: String? = nil,
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict] = [:]
    ) {
        self.defaultProjectBundlePath = defaultProjectBundlePath
        self.allowDemoMode = allowDemoMode
        self.defaultRegistryReplayPath = defaultRegistryReplayPath
        self.inRunVerdictsByKey = inRunVerdictsByKey
    }

    public func handleJSONRPCLine(_ rawLine: String) -> String? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8),
              let rawObj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return errorEnvelope(id: NSNull(), code: -32700, message: "Parse error")
        }
        guard let req = rawObj as? [String: Any] else {
            return errorEnvelope(id: NSNull(), code: -32600, message: "Invalid Request")
        }

        let idVal = req["id"]
        guard let method = req["method"] as? String, !method.isEmpty else {
            return errorEnvelope(id: idVal ?? NSNull(), code: -32600, message: "Invalid Request")
        }

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
            // JSON-RPC 2.0 notifications omit `id` and expect no response.
            if idVal == nil && method.hasPrefix("notifications/") {
                return nil
            }
            return errorEnvelope(id: idVal ?? NSNull(), code: -32601, message: "Method not found: \(method)")
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

    public func handleJSONRPCLineAsync(_ rawLine: String) async -> String? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8),
              let rawObj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return errorEnvelope(id: NSNull(), code: -32700, message: "Parse error")
        }
        guard let req = rawObj as? [String: Any] else {
            return errorEnvelope(id: NSNull(), code: -32600, message: "Invalid Request")
        }

        let idVal = req["id"]
        guard let method = req["method"] as? String, !method.isEmpty else {
            return errorEnvelope(id: idVal ?? NSNull(), code: -32600, message: "Invalid Request")
        }

        let resultPayload: Any
        switch method {
        case "initialize", "tools/list":
            return handleJSONRPCLine(rawLine)

        case "tools/call":
            let params = req["params"] as? [String: Any] ?? [:]
            let toolName = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            resultPayload = await executeToolCallAsync(name: toolName, arguments: arguments)

        default:
            if idVal == nil && method.hasPrefix("notifications/") {
                return nil
            }
            return errorEnvelope(id: idVal ?? NSNull(), code: -32601, message: "Method not found: \(method)")
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

    private func errorEnvelope(id: Any, code: Int, message: String) -> String? {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ]
        guard let outData = try? JSONSerialization.data(withJSONObject: envelope) else {
            return nil
        }
        return String(decoding: outData, as: UTF8.self)
    }

    public func serveStdio() async {
        while let line = readLine() {
            if let response = await handleJSONRPCLineAsync(line) {
                print(response)
                fflush(stdout)
            }
        }
    }

    // MARK: - Tool Execution Router

    public func executeToolCallAsync(name: String, arguments: [String: Any]) async -> [String: Any] {
        let replayPath = (arguments["registryReplayPath"] as? String ?? defaultRegistryReplayPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let replayPath, !replayPath.isEmpty else {
            return executeToolCall(name: name, arguments: arguments)
        }

        do {
            let replaySession = try RegistryReplaySession(directoryURL: URL(fileURLWithPath: replayPath))
            let firewall = CitationVerificationFirewall()

            switch name {
            case "scholar_cite_key":
                let citeKey = (arguments["citeKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let styleRaw = (arguments["style"] as? String ?? "apa7").lowercased()
                let formatRaw = (arguments["manuscriptFormat"] as? String ?? "latex").lowercased()

                let entries: [BibliographyEntry]
                let isDemo: Bool
                if let rawBib = arguments["bibtex"] as? String, !rawBib.isEmpty {
                    entries = try BibTeXCodec().parse(rawBib)
                    isDemo = false
                } else {
                    let opened = try openDatabase(from: arguments)
                    defer { opened.db.close() }
                    entries = try opened.db.listBibliographyEntries()
                    isDemo = opened.isDemo
                }

                var byKey: [String: BibliographyEntry] = [:]
                for entry in entries {
                    byKey[entry.citeKey] = entry
                }
                var verdicts = inRunVerdictsByKey
                if let targetEntry = byKey[citeKey] {
                    let verdict = await firewall.verifyAgainstPublicRegistries(entry: targetEntry, session: replaySession)
                    try await replaySession.throwIfFailed()
                    verdicts[citeKey] = verdict
                }
                let verifiedEntry = try firewall.assertCitationAllowed(
                    citeKey: citeKey,
                    in: byKey,
                    verifiedVerdicts: verdicts
                )
                return formatCiteKeyResult(verifiedEntry: verifiedEntry, styleRaw: styleRaw, formatRaw: formatRaw, isDemo: isDemo)

            case "scholar_verify_bibliography":
                let entries: [BibliographyEntry]
                if let rawBib = arguments["bibtex"] as? String, !rawBib.isEmpty {
                    entries = try BibTeXCodec().parse(rawBib)
                } else {
                    let opened = try openDatabase(from: arguments)
                    defer { opened.db.close() }
                    entries = try opened.db.listBibliographyEntries()
                }
                var verdicts: [CitationFirewallEntryVerdict] = []
                verdicts.reserveCapacity(entries.count)
                for entry in entries {
                    let v = await firewall.verifyAgainstPublicRegistries(entry: entry, session: replaySession)
                    try await replaySession.throwIfFailed()
                    verdicts.append(v)
                }
                let report = firewall.summarizeVerdicts(verdicts)
                let data = try JSONEncoder().encode(report)
                return textResult(String(decoding: data, as: UTF8.self), isError: false)

            case "scholar_lsp_diagnostics":
                if let inlineSource = arguments["source"] as? String {
                    let path = arguments["filePath"] as? String ?? "main.tex"
                    var entries: [BibliographyEntry] = []
                    if let rawBib = arguments["bibtex"] as? String, !rawBib.isEmpty {
                        entries = try BibTeXCodec().parse(rawBib)
                    } else if hasExplicitDatabaseTarget(in: arguments) {
                        let opened = try openDatabase(from: arguments)
                        defer { opened.db.close() }
                        entries = try opened.db.listBibliographyEntries()
                    }
                    let lsp = ScholarLSPWorkspaceService(
                        rootFilePath: path,
                        files: [path: inlineSource],
                        bibliography: entries
                    )
                    _ = await lsp.verifyCitationsOnline(using: replaySession)
                    try await replaySession.throwIfFailed()
                    let diagReport = lsp.diagnosticsReport()
                    let data = try JSONEncoder().encode(diagReport.diagnostics)
                    return textResult(
                        String(decoding: data, as: UTF8.self),
                        isError: diagReport.firewallViolationCount > 0 || diagReport.errorCount > 0
                    )
                }
                let opened = try openDatabase(from: arguments)
                defer { opened.db.close() }
                let entries = try opened.db.listBibliographyEntries()
                var files: [String: String] = [:]
                for rec in try opened.db.listManuscriptFiles() {
                    files[rec.path] = rec.content
                }
                let primary = arguments["filePath"] as? String ?? ((try? opened.db.primaryManuscriptFile()) ?? "main.tex")
                let lsp = ScholarLSPWorkspaceService(
                    rootFilePath: primary,
                    files: files,
                    bibliography: entries
                )
                _ = await lsp.verifyCitationsOnline(using: replaySession)
                try await replaySession.throwIfFailed()
                let diagReport = lsp.diagnosticsReport()
                let data = try JSONEncoder().encode(diagReport.diagnostics)
                return textResult(
                    String(decoding: data, as: UTF8.self),
                    isError: diagReport.firewallViolationCount > 0
                )

            default:
                return executeToolCall(name: name, arguments: arguments)
            }
        } catch let scholarErr as ScholarOSError {
            let prefix = "[\(scholarErr.errorCodeIdentifier)] "
            let body = scholarErr.errorDescription ?? String(describing: scholarErr)
            let formatted = body.hasPrefix("[") ? body : (prefix + body)
            return textResult(formatted, isError: true)
        } catch let replayErr as RegistryReplayError {
            return textResult("[ERR_REGISTRY_REPLAY] \(replayErr.localizedDescription)", isError: true)
        } catch {
            return textResult("[ERR_SCHOLAROS] \(error.localizedDescription)", isError: true)
        }
    }

    public func executeToolCall(name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "scholar_cite_key":
                let citeKey = (arguments["citeKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let styleRaw = (arguments["style"] as? String ?? "apa7").lowercased()
                let formatRaw = (arguments["manuscriptFormat"] as? String ?? "latex").lowercased()

                let entries: [BibliographyEntry]
                let isDemo: Bool
                var effectiveVerdicts = inRunVerdictsByKey

                if let rawBib = arguments["bibtex"] as? String, !rawBib.isEmpty {
                    entries = try BibTeXCodec().parse(rawBib)
                    isDemo = false
                } else {
                    let opened = try openDatabase(from: arguments)
                    defer { opened.db.close() }
                    entries = try opened.db.listBibliographyEntries()
                    isDemo = opened.isDemo
                    for (k, v) in opened.db.inRunVerdicts() where effectiveVerdicts[k] == nil {
                        effectiveVerdicts[k] = v
                    }
                }

                var byKey: [String: BibliographyEntry] = [:]
                for entry in entries {
                    byKey[entry.citeKey] = entry
                }

                let verifiedEntry = try CitationVerificationFirewall().assertCitationAllowed(
                    citeKey: citeKey,
                    in: byKey,
                    verifiedVerdicts: effectiveVerdicts
                )
                return formatCiteKeyResult(verifiedEntry: verifiedEntry, styleRaw: styleRaw, formatRaw: formatRaw, isDemo: isDemo)

            case "scholar_verify_bibliography":
                if let rawBib = arguments["bibtex"] as? String, !rawBib.isEmpty {
                    let entries = try BibTeXCodec().parse(rawBib)
                    let report = CitationVerificationFirewall().auditLibrary(entries)
                    let data = try JSONEncoder().encode(report)
                    return textResult(String(decoding: data, as: UTF8.self), isError: false)
                }
                let opened = try openDatabase(from: arguments)
                defer { opened.db.close() }
                let entries = try opened.db.listBibliographyEntries()
                let report = CitationVerificationFirewall().auditLibrary(entries)
                let data = try JSONEncoder().encode(report)
                return textResult(String(decoding: data, as: UTF8.self), isError: false)

            case "scholar_lsp_diagnostics":
                if let inlineSource = arguments["source"] as? String {
                    let path = arguments["filePath"] as? String ?? "main.tex"
                    var entries: [BibliographyEntry] = []
                    if let rawBib = arguments["bibtex"] as? String, !rawBib.isEmpty {
                        entries = try BibTeXCodec().parse(rawBib)
                    } else if hasExplicitDatabaseTarget(in: arguments) {
                        let opened = try openDatabase(from: arguments)
                        defer { opened.db.close() }
                        entries = try opened.db.listBibliographyEntries()
                    }
                    let lsp = ScholarLSPWorkspaceService(
                        rootFilePath: path,
                        files: [path: inlineSource],
                        bibliography: entries
                    )
                    let diagReport = lsp.diagnosticsReport()
                    let data = try JSONEncoder().encode(diagReport.diagnostics)
                    return textResult(
                        String(decoding: data, as: UTF8.self),
                        isError: diagReport.firewallViolationCount > 0 || diagReport.errorCount > 0
                    )
                }
                let opened = try openDatabase(from: arguments)
                defer { opened.db.close() }
                let entries = try opened.db.listBibliographyEntries()
                var files: [String: String] = [:]
                for rec in try opened.db.listManuscriptFiles() {
                    files[rec.path] = rec.content
                }
                let primary = arguments["filePath"] as? String ?? ((try? opened.db.primaryManuscriptFile()) ?? "main.tex")
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
                let opened = try openDatabase(from: arguments)
                defer { opened.db.close() }
                let passages = try opened.db.listPDFPassages()
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
                let opened = try openDatabase(from: arguments)
                defer { opened.db.close() }
                let studies = try opened.db.listScreeningStudies()
                let spec = try opened.db.loadPRISMAProtocol() ?? PICOProtocolSpec(
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
                let confusion = InterRaterReliabilityAndSeedQCEngine().buildExclusionConfusionMatrix(
                    studies: studies,
                    protocolSpec: spec
                )
                let summary = try opened.db.computePRISMAMetrics()
                let demoPrefix = opened.isDemo ? "[DEMO] " : ""
                let text = String(
                    format: "%@Studies=%d | Included=%d | Kappa=%.4f | PABAK=%.4f | GwetAC1=%.4f",
                    demoPrefix,
                    studies.count,
                    summary.finalIncludedStudies,
                    confusion.nominalMulticlassKappa.pointEstimate,
                    summary.pabakScore,
                    qc.gwetsAC1.pointEstimate
                )
                return textResult(text, isError: false)

            case "scholar_editorial_audit":
                if let inlineSource = arguments["source"] as? String {
                    var entries: [BibliographyEntry] = []
                    if hasExplicitDatabaseTarget(in: arguments) {
                        let opened = try openDatabase(from: arguments)
                        defer { opened.db.close() }
                        entries = try opened.db.listBibliographyEntries()
                    }
                    let runSummary = try EditorialPluginAuditRunner().run(
                        files: ["main.tex": inlineSource],
                        primaryFilePath: "main.tex",
                        bibliography: entries
                    )
                    let data = try JSONEncoder().encode(runSummary.findings)
                    return textResult(String(decoding: data, as: UTF8.self), isError: false)
                }
                let opened = try openDatabase(from: arguments)
                defer { opened.db.close() }
                let entries = try opened.db.listBibliographyEntries()
                var files: [String: String] = [:]
                for rec in try opened.db.listManuscriptFiles() {
                    files[rec.path] = rec.content
                }
                let runSummary = try EditorialPluginAuditRunner().run(
                    files: files,
                    primaryFilePath: (try? opened.db.primaryManuscriptFile()) ?? "main.tex",
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
                let opened = try openDatabase(from: arguments)
                defer { opened.db.close() }
                let entries = try opened.db.listBibliographyEntries()
                let primary = (try? opened.db.primaryManuscriptFile()) ?? "main.tex"
                let manuscript = (try? opened.db.manuscriptContent(path: primary)) ?? ""
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

    private func hasExplicitDatabaseTarget(in arguments: [String: Any]) -> Bool {
        if let projectPath = arguments["projectPath"] as? String, !projectPath.isEmpty {
            return true
        }
        if let defaultProjectBundlePath, !defaultProjectBundlePath.isEmpty {
            return true
        }
        if (arguments["demo"] as? Bool == true) || allowDemoMode {
            return true
        }
        return false
    }

    private func openDatabase(from arguments: [String: Any]) throws -> (db: ScholarProjectDatabase, isDemo: Bool) {
        if let projectPath = arguments["projectPath"] as? String, !projectPath.isEmpty {
            guard FileManager.default.fileExists(atPath: projectPath) else {
                throw ScholarOSError.fileNotFound(projectPath)
            }
            let db = try ScholarProjectDatabase(
                bundleURL: URL(fileURLWithPath: projectPath),
                seedDemoIfEmpty: false
            )
            return (db, false)
        }
        if let defaultProjectBundlePath, !defaultProjectBundlePath.isEmpty {
            guard FileManager.default.fileExists(atPath: defaultProjectBundlePath) else {
                throw ScholarOSError.fileNotFound(defaultProjectBundlePath)
            }
            let db = try ScholarProjectDatabase(
                bundleURL: URL(fileURLWithPath: defaultProjectBundlePath),
                seedDemoIfEmpty: false
            )
            return (db, false)
        }
        if (arguments["demo"] as? Bool == true) || allowDemoMode {
            let db = try ScholarProjectDatabase.inMemory(seedDemo: true)
            return (db, true)
        }
        throw ScholarOSError.invalidCLIArguments(
            "Missing required 'projectPath' argument (or pass 'demo: true' / start server with 'scholaros mcp --demo')."
        )
    }

    private func formatCiteKeyResult(
        verifiedEntry: BibliographyEntry,
        styleRaw: String,
        formatRaw: String,
        isDemo: Bool
    ) -> [String: Any] {
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
        let demoPrefix = isDemo ? "[DEMO]\n" : ""
        let payloadText = """
        \(demoPrefix)[CITATION_STATUS:\(verifiedEntry.firewallClass.rawValue)]
        Snippet: \(snippet)
        Reference (\(style.rawValue)): \(formatted.bibliographyPlainText)
        """
        return textResult(payloadText, isError: false)
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
            "description": "Citation insertion check. Returns formatted \\cite{key} or #cite(<key>) ONLY if the entry is VERIFIED in the current run; otherwise returns ERR_UNVERIFIED_CITATION.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "citeKey": ["type": "string"],
                    "style": ["type": "string"],
                    "manuscriptFormat": ["type": "string"],
                    "bibtex": ["type": "string"],
                    "projectPath": ["type": "string"],
                    "registryReplayPath": ["type": "string"],
                    "demo": ["type": "boolean"]
                ],
                "required": ["citeKey"]
            ]
        ],
        [
            "name": "scholar_verify_bibliography",
            "description": "Audit a BibTeX string or .scholarproj bibliography through the 5-class Citation Verification Firewall (offline syntax/hint check unless registryReplayPath is provided).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bibtex": ["type": "string"],
                    "projectPath": ["type": "string"],
                    "registryReplayPath": ["type": "string"],
                    "demo": ["type": "boolean"]
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
                    "bibtex": ["type": "string"],
                    "filePath": ["type": "string"],
                    "projectPath": ["type": "string"],
                    "registryReplayPath": ["type": "string"],
                    "demo": ["type": "boolean"]
                ]
            ]
        ],
        [
            "name": "scholar_search_provenance",
            "description": "Search indexed PDF passages via SQLite FTS5 BM25 to compare manuscript claims against bounding-box passages.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "claim": ["type": "string"],
                    "filePath": ["type": "string"],
                    "line": ["type": "integer"],
                    "topK": ["type": "integer"],
                    "projectPath": ["type": "string"],
                    "demo": ["type": "boolean"]
                ],
                "required": ["claim"]
            ]
        ],
        [
            "name": "scholar_prisma_agreement",
            "description": "Compute PRISMA 2020 flow counts and nominal Cohen's kappa, PABAK, and Gwet's AC1.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "projectPath": ["type": "string"],
                    "demo": ["type": "boolean"]
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
                    "projectPath": ["type": "string"],
                    "demo": ["type": "boolean"]
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
            "description": "Analyze citation network main paths and structural bridges on a .scholarproj bibliography.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "projectPath": ["type": "string"],
                    "demo": ["type": "boolean"]
                ]
            ]
        ]
        ]
    }
}
