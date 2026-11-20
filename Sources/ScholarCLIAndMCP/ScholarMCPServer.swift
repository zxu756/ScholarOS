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
    public let defaultRegistryReplaySnapshot: RegistryReplaySnapshot?
    public let isOffline: Bool
    public let noCache: Bool
    public let enableExperimentalTools: Bool
    public let defaultLanguage: ScholarLanguage?
    public let inRunVerdictsByKey: [String: CitationFirewallEntryVerdict]
    public let registryTransport: any CitationRegistrySession
    public let registryClock: any RegistryClock
    public let environment: [String: String]?

    private let sharedRateLimiter: RegistryRateLimiter
    private let sharedStandardCache: RegistryResponseCache?
    private let sharedReplayExplicitCache: RegistryResponseCache?

    private var effectiveEnvironment: [String: String] {
        environment ?? ProcessInfo.processInfo.environment
    }

    public init(
        defaultProjectBundlePath: String? = nil,
        allowDemoMode: Bool = false,
        defaultRegistryReplayPath: String? = nil,
        defaultRegistryReplaySnapshot: RegistryReplaySnapshot? = nil,
        isOffline: Bool = false,
        noCache: Bool = false,
        enableExperimentalTools: Bool = false,
        defaultLanguage: ScholarLanguage? = nil,
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict] = [:],
        registryTransport: any CitationRegistrySession = LiveURLSessionRegistryClient(
            capturedHeaderNames: LiveURLSessionRegistryClient.recordingCapturedHeaderNames
        ),
        registryClock: any RegistryClock = SystemRegistryClock(),
        environment: [String: String]? = nil
    ) {
        self.defaultProjectBundlePath = defaultProjectBundlePath
        self.allowDemoMode = allowDemoMode
        self.defaultRegistryReplayPath = defaultRegistryReplayPath
        self.defaultRegistryReplaySnapshot = defaultRegistryReplaySnapshot
        self.isOffline = isOffline
        self.noCache = noCache
        self.enableExperimentalTools = enableExperimentalTools
        self.defaultLanguage = defaultLanguage
        self.inRunVerdictsByKey = inRunVerdictsByKey
        self.registryTransport = registryTransport
        self.registryClock = registryClock
        self.environment = environment

        let env = environment ?? ProcessInfo.processInfo.environment
        let defaultLang = defaultLanguage ?? env["SCHOLAROS_LANG"].flatMap(ScholarLanguage.parse) ?? .en
        self.sharedRateLimiter = RegistryRateLimiter(clock: registryClock)

        if isOffline || noCache {
            self.sharedStandardCache = nil
            self.sharedReplayExplicitCache = nil
        } else {
            self.sharedStandardCache = RegistryResponseCache(
                fileURL: RegistryResponseCache.resolveDatabaseURL(environment: env),
                clock: registryClock,
                language: defaultLang,
                warningHandler: { message in
                    fputs("\(message)\n", stderr)
                }
            )
            if let rawExplicit = env["SCHOLAR_CACHE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawExplicit.isEmpty {
                let explicitSQLiteURL = URL(fileURLWithPath: rawExplicit, isDirectory: true)
                    .appendingPathComponent("registry.sqlite", isDirectory: false)
                self.sharedReplayExplicitCache = RegistryResponseCache(
                    fileURL: explicitSQLiteURL,
                    clock: registryClock,
                    language: defaultLang,
                    warningHandler: { message in
                        fputs("\(message)\n", stderr)
                    }
                )
            } else {
                self.sharedReplayExplicitCache = nil
            }
        }
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
                    "version": ScholarOSVersion.current
                ]
            ]

        case "ping":
            resultPayload = [String: Any]()

        case "tools/list":
            resultPayload = ["tools": activeToolDefinitions]

        case "tools/call":
            let params = req["params"] as? [String: Any] ?? [:]
            guard let toolName = params["name"] as? String, !toolName.isEmpty else {
                return errorEnvelope(id: idVal ?? NSNull(), code: -32602, message: "Invalid params: missing tool name")
            }
            guard isToolEnabled(toolName) else {
                return errorEnvelope(id: idVal ?? NSNull(), code: -32602, message: "Unknown tool: \(toolName)")
            }
            if let rawArgs = params["arguments"], !(rawArgs is NSNull) {
                guard let arguments = rawArgs as? [String: Any] else {
                    let lang = resolvedLanguage(arguments: [:])
                    resultPayload = invalidArgumentResult(
                        toolName: toolName,
                        invalidArguments: [],
                        reasons: ["arguments_must_be_object"],
                        customReason: lang.L(
                            "Parameter 'arguments' for tool '\(toolName)' must be a JSON object.",
                            "工具 '\(toolName)' 的 'arguments' 字段必须是 JSON 对象。"
                        ),
                        language: lang
                    )
                    break
                }
                resultPayload = executeToolCall(name: toolName, arguments: arguments)
            } else {
                resultPayload = executeToolCall(name: toolName, arguments: [:])
            }

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
        case "initialize", "tools/list", "ping":
            return handleJSONRPCLine(rawLine)

        case "tools/call":
            let params = req["params"] as? [String: Any] ?? [:]
            guard let toolName = params["name"] as? String, !toolName.isEmpty else {
                return errorEnvelope(id: idVal ?? NSNull(), code: -32602, message: "Invalid params: missing tool name")
            }
            guard isToolEnabled(toolName) else {
                return errorEnvelope(id: idVal ?? NSNull(), code: -32602, message: "Unknown tool: \(toolName)")
            }
            if let rawArgs = params["arguments"], !(rawArgs is NSNull) {
                guard let arguments = rawArgs as? [String: Any] else {
                    let lang = resolvedLanguage(arguments: [:])
                    resultPayload = invalidArgumentResult(
                        toolName: toolName,
                        invalidArguments: [],
                        reasons: ["arguments_must_be_object"],
                        customReason: lang.L(
                            "Parameter 'arguments' for tool '\(toolName)' must be a JSON object.",
                            "工具 '\(toolName)' 的 'arguments' 字段必须是 JSON 对象。"
                        ),
                        language: lang
                    )
                    break
                }
                resultPayload = await executeToolCallAsync(name: toolName, arguments: arguments)
            } else {
                resultPayload = await executeToolCallAsync(name: toolName, arguments: [:])
            }

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

    public var isReplayServer: Bool {
        if isOffline { return false }
        if defaultRegistryReplaySnapshot != nil { return true }
        if let defaultPath = defaultRegistryReplayPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !defaultPath.isEmpty {
            return true
        }
        return false
    }

    private func resolveReplaySnapshotIfActive(arguments: [String: Any]) throws -> RegistryReplaySnapshot? {
        if (arguments["offline"] as? Bool == true) || isOffline {
            return nil
        }
        if let prevalidated = defaultRegistryReplaySnapshot {
            return prevalidated
        }
        if let defaultPath = defaultRegistryReplayPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !defaultPath.isEmpty {
            return try RegistryReplaySnapshot(directoryURL: URL(fileURLWithPath: defaultPath))
        }
        return nil
    }

    public var activeToolDefinitions: [[String: Any]] {
        if enableExperimentalTools {
            return Self.defaultToolDefinitions + Self.experimentalToolDefinitions
        }
        return Self.defaultToolDefinitions
    }

    public func isToolEnabled(_ toolName: String) -> Bool {
        activeToolDefinitions.contains { ($0["name"] as? String) == toolName }
    }

    private var allowedArgumentsByTool: [String: [String]] {
        var map: [String: [String]] = [:]
        for def in activeToolDefinitions {
            guard let name = def["name"] as? String else { continue }
            let props = (def["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            map[name] = props.keys.sorted()
        }
        return map
    }

    private func invalidArgumentResult(
        toolName: String,
        invalidArguments: [String],
        reasons: [String],
        customReason: String? = nil,
        language: ScholarLanguage
    ) -> [String: Any] {
        let allowed = allowedArgumentsByTool[toolName] ?? []
        let allowedListText = allowed.isEmpty ? "(none)" : allowed.joined(separator: ", ")
        let reasonText: String
        if let customReason {
            reasonText = customReason
        } else if invalidArguments.contains("registryReplayPath") {
            let joinedInvalid = invalidArguments.joined(separator: ", ")
            reasonText = language.L(
                "Argument 'registryReplayPath' is not accepted in MCP tool calls; replay mode can only be enabled at server startup via 'scholaros mcp --registry-replay <dir>'. Unrecognized argument(s) for '\(toolName)': \(joinedInvalid). Allowed arguments: \(allowedListText).",
                "MCP 工具调用不接受 'registryReplayPath' 参数；录制回放只能在启动服务器时通过 'scholaros mcp --registry-replay <目录>' 指定。工具 '\(toolName)' 不认识的参数：\(joinedInvalid)。允许的参数：\(allowedListText)。"
            )
        } else {
            let joinedInvalid = invalidArguments.joined(separator: ", ")
            reasonText = language.L(
                "Unrecognized argument(s) for '\(toolName)': \(joinedInvalid). Allowed arguments: \(allowedListText).",
                "工具 '\(toolName)' 不认识的参数：\(joinedInvalid)。允许的参数：\(allowedListText)。"
            )
        }
        let actionText = language.L(
            "No verification or file modification performed. Remove unsupported arguments and retry.",
            "未执行文献核查，也未改动任何文件。请去掉不支持的参数后重试。"
        )

        var payload: [String: Any] = [
            "error_code": "ERR_INVALID_ARGUMENT",
            "category": "invalid_argument",
            "tool": toolName,
            "invalid_arguments": invalidArguments,
            "allowed_arguments": allowed,
            "reasons": reasons,
            "reason": reasonText,
            "action": actionText
        ]
        if isReplayServer {
            payload["mode"] = "REPLAY"
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return textResult(String(decoding: data, as: UTF8.self), isError: true)
        }
        return textResult("{\"error_code\":\"ERR_INVALID_ARGUMENT\",\"category\":\"invalid_argument\"}", isError: true)
    }

    private func validateToolArguments(toolName: String, arguments: [String: Any]) -> [String: Any]? {
        guard let allowed = allowedArgumentsByTool[toolName] else {
            return nil
        }
        let allowedSet = Set(allowed)
        let unknown = arguments.keys.filter { !allowedSet.contains($0) }.sorted()
        guard !unknown.isEmpty else {
            return nil
        }
        var reasons: [String] = []
        if unknown.contains("registryReplayPath") {
            reasons.append("replay_path_not_allowed_in_tool_arguments")
            if unknown.count > 1 {
                reasons.append("unknown_argument")
            }
        } else {
            reasons.append("unknown_argument")
        }
        return invalidArgumentResult(
            toolName: toolName,
            invalidArguments: unknown,
            reasons: reasons,
            language: resolvedLanguage(arguments: arguments)
        )
    }

    private func resolveVerificationMode(
        arguments: [String: Any],
        isDemo: Bool
    ) throws -> BibliographyVerificationMode {
        if (arguments["offline"] as? Bool == true) || isOffline || isDemo {
            return .offline
        }
        if let snapshot = try resolveReplaySnapshotIfActive(arguments: arguments) {
            return .replay(snapshot: snapshot)
        }
        return .online(transport: registryTransport)
    }

    private func resolvedLanguage(arguments: [String: Any]) -> ScholarLanguage {
        if let rawLang = arguments["lang"] as? String,
           let parsed = ScholarLanguage.parse(rawLang) {
            return parsed
        }
        if let defaultLanguage {
            return defaultLanguage
        }
        if let envLang = effectiveEnvironment["SCHOLAROS_LANG"].flatMap(ScholarLanguage.parse) {
            return envLang
        }
        return .en
    }

    public func executeToolCallAsync(name: String, arguments: [String: Any]) async -> [String: Any] {
        guard isToolEnabled(name) else {
            let msg = "[ERR_SCHOLAROS] Unknown MCP tool '\(name)'"
            return wrapErrorTextIfReplay(code: "ERR_SCHOLAROS", message: msg)
        }
        if let argErr = validateToolArguments(toolName: name, arguments: arguments) {
            return argErr
        }
        do {
            switch name {
            case "verify_citation":
                return await executeVerifyCitation(arguments: arguments)

            case "add_verified_bibtex":
                return await executeAddVerifiedBibTeX(arguments: arguments)

            case "check_manuscript":
                return await executeCheckManuscript(arguments: arguments)

            case "scholar_verify_bibliography":
                return try await executeScholarVerifyBibliography(arguments: arguments)

            default:
                return executeToolCall(name: name, arguments: arguments)
            }
        } catch let scholarErr as ScholarOSError {
            if case .invalidCLIArguments(let detail) = scholarErr {
                return invalidArgumentResult(
                    toolName: name,
                    invalidArguments: [],
                    reasons: ["invalid_argument_value"],
                    customReason: detail,
                    language: resolvedLanguage(arguments: arguments)
                )
            }
            let prefix = "[\(scholarErr.errorCodeIdentifier)] "
            let body = scholarErr.errorDescription ?? String(describing: scholarErr)
            let formatted = body.hasPrefix("[") ? body : (prefix + body)
            return wrapErrorTextIfReplay(code: scholarErr.errorCodeIdentifier, message: formatted)
        } catch let replayErr as RegistryReplayError {
            let msg = "[ERR_REGISTRY_REPLAY] \(replayErr.localizedDescription)"
            return wrapErrorTextIfReplay(code: "ERR_REGISTRY_REPLAY", message: msg)
        } catch {
            let msg = "[ERR_SCHOLAROS] \(error.localizedDescription)"
            return wrapErrorTextIfReplay(code: "ERR_SCHOLAROS", message: msg)
        }
    }

    public func executeToolCall(name: String, arguments: [String: Any]) -> [String: Any] {
        guard isToolEnabled(name) else {
            let msg = "[ERR_SCHOLAROS] Unknown MCP tool '\(name)'"
            return wrapErrorTextIfReplay(code: "ERR_SCHOLAROS", message: msg)
        }
        if let argErr = validateToolArguments(toolName: name, arguments: arguments) {
            return argErr
        }
        if name == "scholar_verify_bibliography"
            || name == "check_manuscript"
            || name == "verify_citation"
            || name == "add_verified_bibtex" {
            final class Box: @unchecked Sendable {
                var value: [String: Any] = [:]
            }
            let box = Box()
            let sem = DispatchSemaphore(value: 0)
            let serverCopy = self
            nonisolated(unsafe) let unsafeArgs = arguments
            Task.detached {
                box.value = await serverCopy.executeToolCallAsync(name: name, arguments: unsafeArgs)
                sem.signal()
            }
            sem.wait()
            return box.value
        }

        do {
            switch name {
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
                if isReplayServer {
                    let arr = (try? JSONSerialization.jsonObject(with: data)) ?? []
                    let obj: [String: Any] = ["mode": "REPLAY", "passages": arr]
                    let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
                    return textResult(String(decoding: out, as: UTF8.self), isError: false)
                }
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
                if isReplayServer {
                    let obj: [String: Any] = ["mode": "REPLAY", "summary": text]
                    let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
                    return textResult(String(decoding: out, as: UTF8.self), isError: false)
                }
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
                    if isReplayServer {
                        let arr = (try? JSONSerialization.jsonObject(with: data)) ?? []
                        let obj: [String: Any] = ["mode": "REPLAY", "findings": arr]
                        let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
                        return textResult(String(decoding: out, as: UTF8.self), isError: false)
                    }
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
                if isReplayServer {
                    let arr = (try? JSONSerialization.jsonObject(with: data)) ?? []
                    let obj: [String: Any] = ["mode": "REPLAY", "findings": arr]
                    let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
                    return textResult(String(decoding: out, as: UTF8.self), isError: false)
                }
                return textResult(String(decoding: data, as: UTF8.self), isError: false)

            case "scholar_track_changes_diff":
                let original = arguments["original"] as? String ?? ""
                let revised = arguments["revised"] as? String ?? ""
                let engine = MyersWordLevelTrackChangesEngine()
                let report = engine.diff(original: original, revised: revised)
                let latexdiff = engine.renderLatexdiffMarkup(from: report)
                if isReplayServer {
                    let obj: [String: Any] = ["mode": "REPLAY", "latexdiff": latexdiff]
                    let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
                    return textResult(String(decoding: out, as: UTF8.self), isError: false)
                }
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
                if isReplayServer {
                    let arr = (try? JSONSerialization.jsonObject(with: data)) ?? []
                    let obj: [String: Any] = ["mode": "REPLAY", "recommendations": arr]
                    let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
                    return textResult(String(decoding: out, as: UTF8.self), isError: false)
                }
                return textResult(String(decoding: data, as: UTF8.self), isError: false)

            default:
                let msg = "[ERR_SCHOLAROS] Unknown MCP tool '\(name)'"
                return wrapErrorTextIfReplay(code: "ERR_SCHOLAROS", message: msg)
            }
        } catch let scholarErr as ScholarOSError {
            if case .invalidCLIArguments(let detail) = scholarErr {
                return invalidArgumentResult(
                    toolName: name,
                    invalidArguments: [],
                    reasons: ["invalid_argument_value"],
                    customReason: detail,
                    language: resolvedLanguage(arguments: arguments)
                )
            }
            let prefix = "[\(scholarErr.errorCodeIdentifier)] "
            let body = scholarErr.errorDescription ?? String(describing: scholarErr)
            let formatted = body.hasPrefix("[") ? body : (prefix + body)
            return wrapErrorTextIfReplay(code: scholarErr.errorCodeIdentifier, message: formatted)
        } catch {
            let msg = "[ERR_SCHOLAROS] \(error.localizedDescription)"
            return wrapErrorTextIfReplay(code: "ERR_SCHOLAROS", message: msg)
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
                seedDemoIfEmpty: false,
                clock: registryClock
            )
            return (db, false)
        }
        if let defaultProjectBundlePath, !defaultProjectBundlePath.isEmpty {
            guard FileManager.default.fileExists(atPath: defaultProjectBundlePath) else {
                throw ScholarOSError.fileNotFound(defaultProjectBundlePath)
            }
            let db = try ScholarProjectDatabase(
                bundleURL: URL(fileURLWithPath: defaultProjectBundlePath),
                seedDemoIfEmpty: false,
                clock: registryClock
            )
            return (db, false)
        }
        if (arguments["demo"] as? Bool == true) || allowDemoMode {
            let db = try ScholarProjectDatabase.inMemory(seedDemo: true, clock: registryClock)
            return (db, true)
        }
        throw ScholarOSError.invalidCLIArguments(
            "Missing required 'projectPath' argument (or pass 'demo: true' / start server with 'scholaros mcp --demo')."
        )
    }

    private func wrapErrorTextIfReplay(code: String, message: String) -> [String: Any] {
        guard isReplayServer else {
            return textResult(message, isError: true)
        }
        let obj: [String: Any] = [
            "mode": "REPLAY",
            "error_code": code,
            "reason": message
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return textResult(String(decoding: data, as: UTF8.self), isError: true)
        }
        return textResult(message, isError: true)
    }

    // MARK: - M3 Stage 05: `scholar_verify_bibliography` (Batch) & `check_manuscript`

    private struct ManuscriptNonVerifiedCitationSummary: Sendable, Codable, Hashable {
        let cite_key: String
        let verdict: String
        let reasons: [String]
        let fields: [CitationFieldDiscrepancy]
    }

    private struct ManuscriptCheckSummaryReport: Sendable, Codable, Hashable {
        let mode: String
        let root: String
        let complete: Bool
        let counts: DiagnosticsCountsSummary
        let structure_errors: [DiagnosticsItemRecord]
        let non_verified_citations: [ManuscriptNonVerifiedCitationSummary]
    }

    private func executeScholarVerifyBibliography(arguments: [String: Any]) async throws -> [String: Any] {
        let lang = resolvedLanguage(arguments: arguments)
        guard let rawBibAny = arguments["bibtex"], !(rawBibAny is NSNull) else {
            return invalidArgumentResult(
                toolName: "scholar_verify_bibliography",
                invalidArguments: ["bibtex"],
                reasons: ["missing_required_argument"],
                customReason: lang.L(
                    "Missing required string argument 'bibtex' for 'scholar_verify_bibliography'.",
                    "工具 'scholar_verify_bibliography' 缺少必填字符串参数 'bibtex'。"
                ),
                language: lang
            )
        }
        guard let rawBib = rawBibAny as? String else {
            return invalidArgumentResult(
                toolName: "scholar_verify_bibliography",
                invalidArguments: ["bibtex"],
                reasons: ["invalid_argument_type"],
                customReason: lang.L(
                    "Argument 'bibtex' for 'scholar_verify_bibliography' must be a string.",
                    "工具 'scholar_verify_bibliography' 的参数 'bibtex' 必须是字符串。"
                ),
                language: lang
            )
        }
        if let optErr = validateOptionalCommonArguments(
            toolName: "scholar_verify_bibliography",
            arguments: arguments,
            bibFileForAction: nil
        ) {
            return optErr
        }

        let entries = try BibTeXCodec().parse(rawBib)
        let callOffline = (arguments["offline"] as? Bool == true)
        let mode = try resolveVerificationMode(arguments: arguments, isDemo: false)
        let verificationResult = try await CitationVerificationFirewall.verifyBibliography(
            entries: entries,
            mode: mode,
            noCache: noCache || isOffline || callOffline,
            skipCacheRead: false,
            environment: effectiveEnvironment,
            clock: registryClock,
            sharedRateLimiter: sharedRateLimiter,
            sharedStandardCache: sharedStandardCache,
            sharedReplayExplicitCache: sharedReplayExplicitCache,
            language: lang
        )
        let data = try verificationResult.encodeAuditJSONData(sortedKeys: true)
        return textResult(String(decoding: data, as: UTF8.self), isError: false)
    }

    private func executeCheckManuscript(arguments: [String: Any]) async -> [String: Any] {
        let lang = resolvedLanguage(arguments: arguments)
        guard let rawPathAny = arguments["path"], !(rawPathAny is NSNull) else {
            return invalidArgumentResult(
                toolName: "check_manuscript",
                invalidArguments: ["path"],
                reasons: ["missing_required_argument"],
                customReason: lang.L(
                    "Missing required string argument 'path' for 'check_manuscript'.",
                    "工具 'check_manuscript' 缺少必填字符串参数 'path'。"
                ),
                language: lang
            )
        }
        guard let manuscriptPath = rawPathAny as? String else {
            return invalidArgumentResult(
                toolName: "check_manuscript",
                invalidArguments: ["path"],
                reasons: ["invalid_argument_type"],
                customReason: lang.L(
                    "Argument 'path' for 'check_manuscript' must be a string.",
                    "工具 'check_manuscript' 的参数 'path' 必须是字符串。"
                ),
                language: lang
            )
        }
        if manuscriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return invalidArgumentResult(
                toolName: "check_manuscript",
                invalidArguments: ["path"],
                reasons: ["invalid_argument_value"],
                customReason: lang.L(
                    "Argument 'path' for 'check_manuscript' must not be empty.",
                    "工具 'check_manuscript' 的参数 'path' 不能为空。"
                ),
                language: lang
            )
        }

        var explicitBibPath: String? = nil
        if let rawBibFileAny = arguments["bib_file"], !(rawBibFileAny is NSNull) {
            guard let bibFileStr = rawBibFileAny as? String else {
                return invalidArgumentResult(
                    toolName: "check_manuscript",
                    invalidArguments: ["bib_file"],
                    reasons: ["invalid_argument_type"],
                    customReason: lang.L(
                        "Argument 'bib_file' for 'check_manuscript' must be a string.",
                        "工具 'check_manuscript' 的参数 'bib_file' 必须是字符串。"
                    ),
                    language: lang
                )
            }
            if bibFileStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return invalidArgumentResult(
                    toolName: "check_manuscript",
                    invalidArguments: ["bib_file"],
                    reasons: ["invalid_argument_value"],
                    customReason: lang.L(
                        "Argument 'bib_file' for 'check_manuscript' must not be empty.",
                        "工具 'check_manuscript' 的参数 'bib_file' 不能为空。"
                    ),
                    language: lang
                )
            }
            explicitBibPath = bibFileStr
        }

        if let rawNoVerify = arguments["no_verify"], !(rawNoVerify is NSNull) {
            if !(rawNoVerify is Bool) || CFGetTypeID(rawNoVerify as CFTypeRef) != CFBooleanGetTypeID() {
                return invalidArgumentResult(
                    toolName: "check_manuscript",
                    invalidArguments: ["no_verify"],
                    reasons: ["invalid_argument_type"],
                    customReason: lang.L(
                        "Argument 'no_verify' for 'check_manuscript' must be a boolean.",
                        "工具 'check_manuscript' 的参数 'no_verify' 必须是布尔值。"
                    ),
                    language: lang
                )
            }
        }

        if let optErr = validateOptionalCommonArguments(
            toolName: "check_manuscript",
            arguments: arguments,
            bibFileForAction: nil
        ) {
            return optErr
        }

        var emitFull = false
        if let rawDetailAny = arguments["detail"], !(rawDetailAny is NSNull) {
            guard let detailStr = rawDetailAny as? String else {
                return invalidArgumentResult(
                    toolName: "check_manuscript",
                    invalidArguments: ["detail"],
                    reasons: ["invalid_argument_type"],
                    customReason: lang.L(
                        "Argument 'detail' for 'check_manuscript' must be 'summary' or 'full'.",
                        "工具 'check_manuscript' 的参数 'detail' 必须是字符串 'summary' 或 'full'。"
                    ),
                    language: lang
                )
            }
            switch detailStr {
            case "summary":
                emitFull = false
            case "full":
                emitFull = true
            default:
                return invalidArgumentResult(
                    toolName: "check_manuscript",
                    invalidArguments: ["detail"],
                    reasons: ["invalid_argument_value"],
                    customReason: lang.L(
                        "Unsupported value '\(detailStr)' for 'detail' in 'check_manuscript'. Allowed values: 'summary', 'full'.",
                        "工具 'check_manuscript' 的参数 'detail' 取值 '\(detailStr)' 不受支持。允许的取值：'summary'、'full'。"
                    ),
                    language: lang
                )
            }
        }

        let callNoVerify = (arguments["no_verify"] as? Bool == true)
        let callOffline = (arguments["offline"] as? Bool == true)
        if callNoVerify && callOffline {
            return invalidArgumentResult(
                toolName: "check_manuscript",
                invalidArguments: ["no_verify", "offline"],
                reasons: ["invalid_argument_combination"],
                customReason: lang.L(
                    "Cannot combine 'no_verify: true' with 'offline: true' in 'check_manuscript'.",
                    "工具 'check_manuscript' 不能同时指定 'no_verify: true' 与 'offline: true'。"
                ),
                language: lang
            )
        }

        do {
            let lsp = try ScholarLSPWorkspaceService.loadManuscript(
                atPath: manuscriptPath,
                explicitBibPath: explicitBibPath,
                clock: registryClock
            )

            let jsonReport: ScholarDiagnosticsJSONReport
            if callNoVerify {
                lsp.setSkipCitationVerification(true)
                jsonReport = lsp.buildDiagnosticsJSONReport(mode: "no-verify", verificationReport: nil)
            } else {
                let mode = try resolveVerificationMode(arguments: arguments, isDemo: false)
                let jsonModeLabel: String
                switch mode {
                case .offline:
                    jsonModeLabel = "offline"
                case .replay:
                    jsonModeLabel = "REPLAY"
                case .online, .record:
                    jsonModeLabel = "online"
                }

                let verificationResult = try await CitationVerificationFirewall.verifyBibliography(
                    entries: lsp.citedBibliographyEntries,
                    mode: mode,
                    noCache: noCache || isOffline || callOffline,
                    skipCacheRead: false,
                    environment: effectiveEnvironment,
                    clock: registryClock,
                    sharedRateLimiter: sharedRateLimiter,
                    sharedStandardCache: sharedStandardCache,
                    sharedReplayExplicitCache: sharedReplayExplicitCache,
                    language: lang
                )
                lsp.applyVerificationReport(verificationResult.report)
                jsonReport = lsp.buildDiagnosticsJSONReport(
                    mode: jsonModeLabel,
                    verificationReport: verificationResult.report
                )
            }

            if emitFull {
                let fullData = try jsonReport.encodeJSONData(sortedKeys: true)
                return textResult(String(decoding: fullData, as: UTF8.self), isError: false)
            }

            let structureErrors = jsonReport.diagnostics.filter {
                $0.category == .structure && $0.severity == .error
            }
            let nonVerifiedCitations = jsonReport.citations.compactMap { item -> ManuscriptNonVerifiedCitationSummary? in
                guard let verif = item.verification,
                      verif.verdict != CitationFirewallClass.verified.rawValue else {
                    return nil
                }
                return ManuscriptNonVerifiedCitationSummary(
                    cite_key: item.key,
                    verdict: verif.verdict,
                    reasons: verif.reasons,
                    fields: verif.fields
                )
            }
            let summaryReport = ManuscriptCheckSummaryReport(
                mode: jsonReport.mode,
                root: jsonReport.root,
                complete: jsonReport.complete,
                counts: jsonReport.counts,
                structure_errors: structureErrors,
                non_verified_citations: nonVerifiedCitations
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let summaryData = try encoder.encode(summaryReport)
            return textResult(String(decoding: summaryData, as: UTF8.self), isError: false)
        } catch let scholarErr as ScholarOSError {
            let code = scholarErr.errorCodeIdentifier
            let body = scholarErr.errorDescription ?? String(describing: scholarErr)
            var payload: [String: Any] = [
                "error_code": code,
                "category": "manuscript_io",
                "reasons": ["manuscript_load_failed"],
                "reason": body
            ]
            if isReplayServer {
                payload["mode"] = "REPLAY"
            }
            return jsonTextResult(payload, isError: true, fallback: "{\"error_code\":\"\(code)\"}")
        } catch let replayErr as RegistryReplayError {
            var payload: [String: Any] = [
                "error_code": "ERR_REGISTRY_REPLAY",
                "category": "registry_replay",
                "reasons": ["replay_recording_missing_or_corrupt"],
                "reason": "[ERR_REGISTRY_REPLAY] \(replayErr.localizedDescription)"
            ]
            if isReplayServer {
                payload["mode"] = "REPLAY"
            }
            return jsonTextResult(payload, isError: true, fallback: "[ERR_REGISTRY_REPLAY] \(replayErr.localizedDescription)")
        } catch {
            var payload: [String: Any] = [
                "error_code": "ERR_IO",
                "category": "manuscript_io",
                "reasons": ["manuscript_load_failed"],
                "reason": error.localizedDescription
            ]
            if isReplayServer {
                payload["mode"] = "REPLAY"
            }
            return jsonTextResult(payload, isError: true, fallback: "{\"error_code\":\"ERR_IO\"}")
        }
    }

    // MARK: - M3 Stage 04: `verify_citation` & `add_verified_bibtex`

    private func bibFileDisplayName(_ bibFilePath: String) -> String {
        let trimmed = bibFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "<bib_file>" }
        let last = (trimmed as NSString).lastPathComponent
        if last.isEmpty || last == "/" {
            return trimmed
        }
        return last
    }

    private func untouchedFileAction(for bibFilePath: String) -> String {
        "未改动 \(bibFileDisplayName(bibFilePath))"
    }

    private func jsonTextResult(_ payload: [String: Any], isError: Bool, fallback: String) -> [String: Any] {
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return textResult(String(decoding: data, as: UTF8.self), isError: isError)
        }
        return textResult(fallback, isError: isError)
    }

    private func validateOptionalCommonArguments(
        toolName: String,
        arguments: [String: Any],
        bibFileForAction: String?
    ) -> [String: Any]? {
        let lang = resolvedLanguage(arguments: arguments)
        if let rawOffline = arguments["offline"], !(rawOffline is NSNull) {
            if !(rawOffline is Bool) || CFGetTypeID(rawOffline as CFTypeRef) != CFBooleanGetTypeID() {
                var res = invalidArgumentResult(
                    toolName: toolName,
                    invalidArguments: ["offline"],
                    reasons: ["invalid_argument_type"],
                    customReason: lang.L(
                        "Argument 'offline' for '\(toolName)' must be a boolean.",
                        "工具 '\(toolName)' 的参数 'offline' 必须是布尔值。"
                    ),
                    language: lang
                )
                if let bibFileForAction {
                    res = patchActionInErrorResult(res, action: untouchedFileAction(for: bibFileForAction))
                }
                return res
            }
        }
        if let rawLang = arguments["lang"], !(rawLang is NSNull) {
            if !(rawLang is String) {
                var res = invalidArgumentResult(
                    toolName: toolName,
                    invalidArguments: ["lang"],
                    reasons: ["invalid_argument_type"],
                    customReason: lang.L(
                        "Argument 'lang' for '\(toolName)' must be a string.",
                        "工具 '\(toolName)' 的参数 'lang' 必须是字符串。"
                    ),
                    language: lang
                )
                if let bibFileForAction {
                    res = patchActionInErrorResult(res, action: untouchedFileAction(for: bibFileForAction))
                }
                return res
            }
        }
        return nil
    }

    private func patchActionInErrorResult(_ result: [String: Any], action: String) -> [String: Any] {
        guard let txt = ((result["content"] as? [[String: Any]])?.first)?["text"] as? String,
              let data = txt.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return result
        }
        obj["action"] = action
        return jsonTextResult(obj, isError: true, fallback: txt)
    }

    private func invalidBibTeXResult(
        reasons: [String],
        reason: String,
        bibFilePath: String?,
        language: ScholarLanguage
    ) -> [String: Any] {
        let action: String
        if let bibFilePath {
            action = untouchedFileAction(for: bibFilePath)
        } else {
            action = language.L(
                "No verification performed. Pass a BibTeX string containing exactly 1 valid entry.",
                "未执行文献核查。请传入恰好包含 1 条合法条目的 BibTeX 字符串。"
            )
        }
        var payload: [String: Any] = [
            "error_code": "ERR_INVALID_BIBTEX",
            "category": "invalid_bibtex",
            "reasons": reasons,
            "reason": reason,
            "action": action
        ]
        if isReplayServer {
            payload["mode"] = "REPLAY"
        }
        return jsonTextResult(
            payload,
            isError: true,
            fallback: "{\"error_code\":\"ERR_INVALID_BIBTEX\"}"
        )
    }

    private enum SingleBibTeXParseOutcome {
        case valid(entry: BibliographyEntry, unmappedFields: [String: String])
        case invalid(errorResult: [String: Any])
    }

    private func parseExactSingleBibTeXEntry(
        rawBib: String,
        bibFilePath: String?,
        language: ScholarLanguage
    ) -> SingleBibTeXParseOutcome {
        if rawBib.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalid(
                errorResult: invalidBibTeXResult(
                    reasons: ["empty_bibtex"],
                    reason: language.L(
                        "Expected exactly 1 BibTeX entry, but 'bibtex' is empty (0 entries).",
                        "参数 'bibtex' 必须恰好包含 1 条 BibTeX 条目，当前为空（0 条）。"
                    ),
                    bibFilePath: bibFilePath,
                    language: language
                )
            )
        }

        let doc = BibTeXCodec().parseDocumentRecovering(rawBib)
        if let firstErr = doc.errors.first {
            return .invalid(
                errorResult: invalidBibTeXResult(
                    reasons: ["bibtex_syntax_error"],
                    reason: language.L(
                        "BibTeX syntax error at line \(firstErr.line): \(firstErr.message)",
                        "BibTeX 第 \(firstErr.line) 行语法错误：\(firstErr.message)"
                    ),
                    bibFilePath: bibFilePath,
                    language: language
                )
            )
        }

        if doc.diagnostics.contains(where: { $0.code == "BIB002" }) {
            return .invalid(
                errorResult: invalidBibTeXResult(
                    reasons: ["multiple_entries"],
                    reason: language.L(
                        "Expected exactly 1 BibTeX entry, but multiple entries (duplicate cite key) were provided.",
                        "参数 'bibtex' 必须恰好包含 1 条 BibTeX 条目，但传入了多条条目（含重复引用键）。"
                    ),
                    bibFilePath: bibFilePath,
                    language: language
                )
            )
        }

        if doc.entries.isEmpty {
            let reasonCode: String
            let reasonMsg: String
            if (try? BibTeXCodec().parseDocument(rawBib)) == nil {
                reasonCode = "bibtex_syntax_error"
                reasonMsg = language.L(
                    "Input is not valid BibTeX (0 valid entries found).",
                    "传入文本不是合法的 BibTeX（共解析出 0 条有效条目）。"
                )
            } else {
                reasonCode = "empty_bibtex"
                reasonMsg = language.L(
                    "Expected exactly 1 BibTeX entry, got 0 entries.",
                    "参数 'bibtex' 必须恰好包含 1 条 BibTeX 条目，实际为 0 条。"
                )
            }
            return .invalid(
                errorResult: invalidBibTeXResult(
                    reasons: [reasonCode],
                    reason: reasonMsg,
                    bibFilePath: bibFilePath,
                    language: language
                )
            )
        }

        if doc.entries.count > 1 {
            return .invalid(
                errorResult: invalidBibTeXResult(
                    reasons: ["multiple_entries"],
                    reason: language.L(
                        "Expected exactly 1 BibTeX entry, got \(doc.entries.count) entries.",
                        "参数 'bibtex' 必须恰好包含 1 条 BibTeX 条目，实际收到 \(doc.entries.count) 条。"
                    ),
                    bibFilePath: bibFilePath,
                    language: language
                )
            )
        }

        let entry = doc.entries[0]
        if entry.parseError || entry.citeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalid(
                errorResult: invalidBibTeXResult(
                    reasons: ["bibtex_syntax_error"],
                    reason: language.L(
                        "BibTeX entry has missing citation key or syntax error.",
                        "BibTeX 条目缺少引用键或存在语法错误。"
                    ),
                    bibFilePath: bibFilePath,
                    language: language
                )
            )
        }

        let unmapped = doc.unmappedFieldsByCiteKey[entry.citeKey]
            ?? doc.unmappedFieldsByCiteKey[entry.citeKey.lowercased()]
            ?? [:]
        return .valid(entry: entry, unmappedFields: unmapped)
    }

    private func executeVerifyCitation(arguments: [String: Any]) async -> [String: Any] {
        let lang = resolvedLanguage(arguments: arguments)
        guard let rawBibAny = arguments["bibtex"], !(rawBibAny is NSNull) else {
            return invalidArgumentResult(
                toolName: "verify_citation",
                invalidArguments: ["bibtex"],
                reasons: ["missing_required_argument"],
                customReason: lang.L(
                    "Missing required string argument 'bibtex' for 'verify_citation'.",
                    "工具 'verify_citation' 缺少必填字符串参数 'bibtex'。"
                ),
                language: lang
            )
        }
        guard let rawBib = rawBibAny as? String else {
            return invalidArgumentResult(
                toolName: "verify_citation",
                invalidArguments: ["bibtex"],
                reasons: ["invalid_argument_type"],
                customReason: lang.L(
                    "Argument 'bibtex' for 'verify_citation' must be a string.",
                    "工具 'verify_citation' 的参数 'bibtex' 必须是字符串。"
                ),
                language: lang
            )
        }
        if let optErr = validateOptionalCommonArguments(
            toolName: "verify_citation",
            arguments: arguments,
            bibFileForAction: nil
        ) {
            return optErr
        }

        let entry: BibliographyEntry
        switch parseExactSingleBibTeXEntry(rawBib: rawBib, bibFilePath: nil, language: lang) {
        case .invalid(let errRes):
            return errRes
        case .valid(let parsedEntry, _):
            entry = parsedEntry
        }

        let callOffline = (arguments["offline"] as? Bool == true)
        do {
            let mode = try resolveVerificationMode(arguments: arguments, isDemo: false)
            let modeLabel: String
            if isReplayServer {
                modeLabel = "REPLAY"
            } else if case .offline = mode {
                modeLabel = "offline"
            } else {
                modeLabel = "online"
            }

            let verificationResult = try await CitationVerificationFirewall.verifyBibliography(
                entries: [entry],
                mode: mode,
                noCache: noCache || isOffline || callOffline,
                skipCacheRead: false,
                environment: effectiveEnvironment,
                clock: registryClock,
                sharedRateLimiter: sharedRateLimiter,
                sharedStandardCache: sharedStandardCache,
                sharedReplayExplicitCache: sharedReplayExplicitCache,
                language: lang
            )
            guard let verdict = verificationResult.report.verdicts.first else {
                var errPayload: [String: Any] = [
                    "error_code": "ERR_SCHOLAROS",
                    "category": "internal_error",
                    "reason": "Citation verification produced no verdict."
                ]
                if isReplayServer { errPayload["mode"] = "REPLAY" }
                return jsonTextResult(errPayload, isError: true, fallback: "{\"error_code\":\"ERR_SCHOLAROS\"}")
            }

            let encoder = JSONEncoder()
            let sourcesObj = (try? JSONSerialization.jsonObject(with: encoder.encode(verdict.sources))) ?? []
            let fieldsObj = (try? JSONSerialization.jsonObject(with: encoder.encode(verdict.fields))) ?? []
            let findingsObj = (try? JSONSerialization.jsonObject(with: encoder.encode(verdict.findings))) ?? []
            let recordObj: Any
            if let rec = verdict.record, let obj = try? JSONSerialization.jsonObject(with: encoder.encode(rec)) {
                recordObj = obj
            } else {
                recordObj = NSNull()
            }

            let payload: [String: Any] = [
                "mode": modeLabel,
                "cite_key": verdict.citeKey,
                "verdict": verdict.firewallClass.rawValue,
                "reasons": verdict.reasons,
                "sources": sourcesObj,
                "fields": fieldsObj,
                "insertable": verdict.insertable,
                "record": recordObj,
                "findings": findingsObj
            ]
            return jsonTextResult(
                payload,
                isError: false,
                fallback: "{\"cite_key\":\"\(verdict.citeKey)\",\"verdict\":\"\(verdict.firewallClass.rawValue)\"}"
            )
        } catch let replayErr as RegistryReplayError {
            var payload: [String: Any] = [
                "error_code": "ERR_REGISTRY_REPLAY",
                "category": "registry_replay",
                "reasons": ["replay_recording_missing_or_corrupt"],
                "reason": "[ERR_REGISTRY_REPLAY] \(replayErr.localizedDescription)"
            ]
            if isReplayServer {
                payload["mode"] = "REPLAY"
            }
            return jsonTextResult(payload, isError: true, fallback: "[ERR_REGISTRY_REPLAY] \(replayErr.localizedDescription)")
        } catch {
            var payload: [String: Any] = [
                "error_code": "ERR_SCHOLAROS",
                "category": "execution_error",
                "reason": error.localizedDescription
            ]
            if isReplayServer {
                payload["mode"] = "REPLAY"
            }
            return jsonTextResult(payload, isError: true, fallback: "[ERR_SCHOLAROS] \(error.localizedDescription)")
        }
    }

    private func executeAddVerifiedBibTeX(arguments: [String: Any]) async -> [String: Any] {
        let lang = resolvedLanguage(arguments: arguments)
        let candidateBibFileString = arguments["bib_file"] as? String

        guard let rawBibFileAny = arguments["bib_file"], !(rawBibFileAny is NSNull) else {
            return invalidArgumentResult(
                toolName: "add_verified_bibtex",
                invalidArguments: ["bib_file"],
                reasons: ["missing_required_argument"],
                customReason: lang.L(
                    "Missing required string argument 'bib_file' for 'add_verified_bibtex'.",
                    "工具 'add_verified_bibtex' 缺少必填字符串参数 'bib_file'。"
                ),
                language: lang
            )
        }
        guard let bibFilePath = rawBibFileAny as? String else {
            return invalidArgumentResult(
                toolName: "add_verified_bibtex",
                invalidArguments: ["bib_file"],
                reasons: ["invalid_argument_type"],
                customReason: lang.L(
                    "Argument 'bib_file' for 'add_verified_bibtex' must be a string.",
                    "工具 'add_verified_bibtex' 的参数 'bib_file' 必须是字符串。"
                ),
                language: lang
            )
        }

        guard let rawBibAny = arguments["bibtex"], !(rawBibAny is NSNull) else {
            let base = invalidArgumentResult(
                toolName: "add_verified_bibtex",
                invalidArguments: ["bibtex"],
                reasons: ["missing_required_argument"],
                customReason: lang.L(
                    "Missing required string argument 'bibtex' for 'add_verified_bibtex'.",
                    "工具 'add_verified_bibtex' 缺少必填字符串参数 'bibtex'。"
                ),
                language: lang
            )
            return patchActionInErrorResult(base, action: untouchedFileAction(for: bibFilePath))
        }
        guard let rawBib = rawBibAny as? String else {
            let base = invalidArgumentResult(
                toolName: "add_verified_bibtex",
                invalidArguments: ["bibtex"],
                reasons: ["invalid_argument_type"],
                customReason: lang.L(
                    "Argument 'bibtex' for 'add_verified_bibtex' must be a string.",
                    "工具 'add_verified_bibtex' 的参数 'bibtex' 必须是字符串。"
                ),
                language: lang
            )
            return patchActionInErrorResult(base, action: untouchedFileAction(for: bibFilePath))
        }

        if let optErr = validateOptionalCommonArguments(
            toolName: "add_verified_bibtex",
            arguments: arguments,
            bibFileForAction: candidateBibFileString
        ) {
            return optErr
        }

        let entry: BibliographyEntry
        let unmappedFields: [String: String]
        switch parseExactSingleBibTeXEntry(rawBib: rawBib, bibFilePath: bibFilePath, language: lang) {
        case .invalid(let errRes):
            return errRes
        case .valid(let parsedEntry, let parsedUnmapped):
            entry = parsedEntry
            unmappedFields = parsedUnmapped
        }

        let actionText = untouchedFileAction(for: bibFilePath)
        let callOffline = (arguments["offline"] as? Bool == true)

        // Settled #6 & Row 8: server started with --offline OR single call passing offline: true is rejected immediately.
        if isOffline || callOffline {
            var payload: [String: Any] = [
                "error_code": "ERR_UNVERIFIED_CITATION",
                "category": "unverified_citation",
                "mode": isReplayServer ? "REPLAY" : "offline",
                "cite_key": entry.citeKey,
                "verdict": CitationFirewallClass.unverified.rawValue,
                "reasons": [CitationUnverifiedReasonCode.offline.rawValue],
                "fields": [Any](),
                "findings": [Any](),
                "sources": [Any](),
                "record": NSNull(),
                "reason": lang.L(
                    "Lookup not performed [UNVERIFIED, reason: offline]: online registry verification is required before writing to .bib, and offline mode was requested.",
                    "尚未完成外部核查 [UNVERIFIED，原因码：offline]：写入 .bib 前必须向外部注册库核查，离线模式下拒绝写入。"
                ),
                "action": actionText
            ]
            if isReplayServer {
                payload["mode"] = "REPLAY"
            }
            return jsonTextResult(payload, isError: true, fallback: "{\"error_code\":\"ERR_UNVERIFIED_CITATION\"}")
        }

        do {
            let mode = try resolveVerificationMode(arguments: arguments, isDemo: false)
            let modeLabel = isReplayServer ? "REPLAY" : "online"

            // Settled #6: bypass reading from cache on write (`skipCacheRead: true`), while still storing freshly fetched responses into cache (`noCache: noCache`).
            let verificationResult = try await CitationVerificationFirewall.verifyBibliography(
                entries: [entry],
                mode: mode,
                noCache: noCache,
                skipCacheRead: true,
                environment: effectiveEnvironment,
                clock: registryClock,
                sharedRateLimiter: sharedRateLimiter,
                sharedStandardCache: sharedStandardCache,
                sharedReplayExplicitCache: sharedReplayExplicitCache,
                language: lang
            )

            guard let verdict = verificationResult.report.verdicts.first else {
                var errPayload: [String: Any] = [
                    "error_code": "ERR_IO",
                    "category": "internal_error",
                    "reason": "Citation verification produced no verdict.",
                    "action": actionText
                ]
                if isReplayServer { errPayload["mode"] = "REPLAY" }
                return jsonTextResult(errPayload, isError: true, fallback: "{\"error_code\":\"ERR_IO\"}")
            }

            let encoder = JSONEncoder()
            let sourcesObj = (try? JSONSerialization.jsonObject(with: encoder.encode(verdict.sources))) ?? []
            let fieldsObj = (try? JSONSerialization.jsonObject(with: encoder.encode(verdict.fields))) ?? []
            let findingsObj = (try? JSONSerialization.jsonObject(with: encoder.encode(verdict.findings))) ?? []
            let recordObj: Any
            if let rec = verdict.record, let obj = try? JSONSerialization.jsonObject(with: encoder.encode(rec)) {
                recordObj = obj
            } else {
                recordObj = NSNull()
            }

            guard verdict.firewallClass == .verified,
                  verdict.insertable,
                  !verdict.sources.isEmpty,
                  let verifiedRecord = verdict.record else {
                let firewall = CitationVerificationFirewall(clock: registryClock)
                let rejectionReason = firewall.formatInRunRejectionReason(for: verdict, language: lang)
                let payload: [String: Any] = [
                    "error_code": "ERR_UNVERIFIED_CITATION",
                    "category": "unverified_citation",
                    "mode": modeLabel,
                    "cite_key": verdict.citeKey,
                    "verdict": verdict.firewallClass.rawValue,
                    "reasons": verdict.reasons,
                    "fields": fieldsObj,
                    "findings": findingsObj,
                    "sources": sourcesObj,
                    "record": recordObj,
                    "reason": rejectionReason,
                    "action": actionText
                ]
                return jsonTextResult(payload, isError: true, fallback: "{\"error_code\":\"ERR_UNVERIFIED_CITATION\"}")
            }

            do {
                let outcome = try VerifiedBibTeXWriter.appendVerifiedEntry(
                    toBibFileAtPath: bibFilePath,
                    citeKey: entry.citeKey,
                    record: verifiedRecord,
                    localEntry: entry,
                    localUnmappedFields: unmappedFields
                )
                switch outcome {
                case .appendedVerified(let generated):
                    let changedFieldsObj = (try? JSONSerialization.jsonObject(with: encoder.encode(generated.changedFields))) ?? []
                    let okPayload: [String: Any] = [
                        "status": "APPENDED_VERIFIED",
                        "cite_key": generated.citeKey,
                        "verdict": CitationFirewallClass.verified.rawValue,
                        "mode": modeLabel,
                        "written_bibtex": generated.bibtex,
                        "changed_fields": changedFieldsObj,
                        "sources": sourcesObj,
                        "record": recordObj
                    ]
                    return jsonTextResult(okPayload, isError: false, fallback: "{\"status\":\"APPENDED_VERIFIED\"}")

                case .skippedDuplicate(let existingKey, let matchedOn):
                    let dupPayload: [String: Any] = [
                        "status": "SKIPPED_DUPLICATE",
                        "mode": modeLabel,
                        "cite_key": entry.citeKey,
                        "verdict": CitationFirewallClass.verified.rawValue,
                        "existing_key": existingKey,
                        "matched_on": matchedOn.rawValue,
                        "sources": sourcesObj
                    ]
                    return jsonTextResult(dupPayload, isError: false, fallback: "{\"status\":\"SKIPPED_DUPLICATE\"}")
                }
            } catch let writeErr as VerifiedBibTeXWriteError {
                return formatVerifiedBibTeXWriteError(writeErr, bibFilePath: bibFilePath, modeLabel: modeLabel)
            }
        } catch let replayErr as RegistryReplayError {
            var payload: [String: Any] = [
                "error_code": "ERR_REGISTRY_REPLAY",
                "category": "registry_replay",
                "reasons": ["replay_recording_missing_or_corrupt"],
                "reason": "[ERR_REGISTRY_REPLAY] \(replayErr.localizedDescription)",
                "action": actionText
            ]
            if isReplayServer {
                payload["mode"] = "REPLAY"
            }
            return jsonTextResult(payload, isError: true, fallback: "[ERR_REGISTRY_REPLAY] \(replayErr.localizedDescription)")
        } catch {
            var payload: [String: Any] = [
                "error_code": "ERR_IO",
                "category": "io_error",
                "reason": error.localizedDescription,
                "action": actionText
            ]
            if isReplayServer {
                payload["mode"] = "REPLAY"
            }
            return jsonTextResult(payload, isError: true, fallback: "{\"error_code\":\"ERR_IO\"}")
        }
    }

    private func formatVerifiedBibTeXWriteError(
        _ err: VerifiedBibTeXWriteError,
        bibFilePath: String,
        modeLabel: String
    ) -> [String: Any] {
        let code = err.errorCode
        let actionText = untouchedFileAction(for: bibFilePath)
        var payload: [String: Any] = [
            "error_code": code,
            "bib_file": bibFilePath,
            "reason": err.errorDescription ?? String(describing: err),
            "action": actionText
        ]
        if isReplayServer || modeLabel == "REPLAY" {
            payload["mode"] = "REPLAY"
        } else {
            payload["mode"] = modeLabel
        }
        switch err {
        case .invalidPath:
            payload["category"] = "bib_path"
            payload["reasons"] = ["invalid_bib_path"]
        case .encodingError:
            payload["category"] = "bib_encoding"
            payload["reasons"] = ["invalid_utf8_encoding"]
        case .syntaxError(_, let line, let startLine, let citeKey, _):
            payload["category"] = "bib_syntax"
            payload["reasons"] = ["bibtex_syntax_error"]
            payload["line"] = line
            payload["start_line"] = startLine
            payload["cite_key"] = citeKey ?? NSNull()
        case .citeKeyConflict(let citeKey, let existingKey, _):
            payload["category"] = "cite_key_conflict"
            payload["reasons"] = ["cite_key_conflict"]
            payload["cite_key"] = citeKey
            payload["existing_key"] = existingKey
        case .ioError:
            payload["category"] = "io_error"
            payload["reasons"] = ["io_error"]
        }
        return jsonTextResult(payload, isError: true, fallback: "{\"error_code\":\"\(code)\"}")
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
        defaultToolDefinitions
    }

    public static var defaultToolDefinitions: [[String: Any]] {
        [
        [
            "name": "verify_citation",
            "description": "Verify a single BibTeX entry through the shared 5-class Citation Verification Firewall. Requires exactly one BibTeX entry; returns structured JSON with mode, cite_key, verdict, reasons, sources, fields, insertable, record, and findings.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bibtex": ["type": "string"],
                    "offline": ["type": "boolean"],
                    "lang": ["type": "string"]
                ],
                "required": ["bibtex"]
            ]
        ],
        [
            "name": "add_verified_bibtex",
            "description": "Verify a single BibTeX entry in-process (bypassing cache read) and append canonical registry-backed BibTeX to a .bib file under exclusive flock + O_APPEND only when verdict is VERIFIED and insertable is true.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bib_file": ["type": "string"],
                    "bibtex": ["type": "string"],
                    "offline": ["type": "boolean"],
                    "lang": ["type": "string"]
                ],
                "required": ["bib_file", "bibtex"]
            ]
        ],
        [
            "name": "check_manuscript",
            "description": "Load a LaTeX/Typst manuscript from disk via the unified multi-file loader, run structure and cross-reference checks, and verify cited bibliography entries through the shared Citation Verification Firewall (online with SQLite cache by default; pass no_verify: true for structure-only checks or offline: true to skip network and cache). Returns a compact summary by default, or the full scholaros.diagnostics/1 JSON object byte-for-byte identical to CLI 'diagnostics <path> --json' when detail is 'full'.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "bib_file": ["type": "string"],
                    "no_verify": ["type": "boolean"],
                    "offline": ["type": "boolean"],
                    "detail": ["type": "string", "enum": ["summary", "full"]],
                    "lang": ["type": "string"]
                ],
                "required": ["path"]
            ]
        ],
        [
            "name": "scholar_verify_bibliography",
            "description": "Batch-verify a BibTeX string (zero, one, or multiple entries) through the shared 5-class Citation Verification Firewall (queries public registries online with SQLite cache by default; pass offline: true to skip network and cache for one call). Read-only batch verification: never writes or modifies any .bib file.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bibtex": ["type": "string"],
                    "offline": ["type": "boolean"],
                    "lang": ["type": "string"]
                ],
                "required": ["bibtex"]
            ]
        ]
        ]
    }

    public static var experimentalToolDefinitions: [[String: Any]] {
        [
        [
            "name": "scholar_search_provenance",
            "description": "Search indexed PDF passages via SQLite FTS5 BM25 to compare manuscript claims against bounding-box passages.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "claim": ["type": "string"],
                    "citeKey": ["type": "string"],
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
