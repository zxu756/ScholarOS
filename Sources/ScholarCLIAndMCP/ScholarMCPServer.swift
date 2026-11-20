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
            resultPayload = ["tools": Self.toolDefinitions]

        case "tools/call":
            let params = req["params"] as? [String: Any] ?? [:]
            let toolName = params["name"] as? String ?? ""
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
            let toolName = params["name"] as? String ?? ""
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

    private static var allowedArgumentsByTool: [String: [String]] {
        var map: [String: [String]] = [:]
        for def in toolDefinitions {
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
        let allowed = Self.allowedArgumentsByTool[toolName] ?? []
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
        guard let allowed = Self.allowedArgumentsByTool[toolName] else {
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
        if let argErr = validateToolArguments(toolName: name, arguments: arguments) {
            return argErr
        }
        do {
            switch name {
            case "verify_citation":
                return await executeVerifyCitation(arguments: arguments)

            case "add_verified_bibtex":
                return await executeAddVerifiedBibTeX(arguments: arguments)

            case "scholar_cite_key":
                let citeKey = (arguments["citeKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let styleRaw = (arguments["style"] as? String ?? "apa7").lowercased()
                let formatRaw = (arguments["manuscriptFormat"] as? String ?? "latex").lowercased()
                let callOffline = (arguments["offline"] as? Bool == true)
                let lang = resolvedLanguage(arguments: arguments)

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

                let mode = try resolveVerificationMode(arguments: arguments, isDemo: isDemo)
                var byKey: [String: BibliographyEntry] = [:]
                for entry in entries {
                    byKey[entry.citeKey] = entry
                }

                let firewall = CitationVerificationFirewall(clock: registryClock)
                let citeModeLabel: String
                switch mode {
                case .replay:
                    citeModeLabel = "REPLAY"
                case .offline:
                    citeModeLabel = isDemo ? "DEMO" : (isReplayServer && !callOffline ? "REPLAY" : "offline")
                case .online, .record:
                    citeModeLabel = "online"
                }

                guard let targetEntry = byKey[citeKey] else {
                    do {
                        let verifiedEntry = try firewall.assertCitationAllowed(
                            citeKey: citeKey,
                            in: byKey,
                            verifiedVerdicts: [:],
                            language: lang
                        )
                        return formatCiteKeyResult(
                            verifiedEntry: verifiedEntry,
                            verdict: nil,
                            styleRaw: styleRaw,
                            formatRaw: formatRaw,
                            modeLabel: citeModeLabel,
                            isDemo: isDemo
                        )
                    } catch let ScholarOSError.unverifiedCitationBlocked(key, status, reason) {
                        return formatUnverifiedCitationErrorResult(
                            citeKey: key,
                            verdictCode: status,
                            verdict: nil,
                            missingFromBibliography: true,
                            reason: reason,
                            modeLabel: citeModeLabel
                        )
                    }
                }

                let verificationResult = try await CitationVerificationFirewall.verifyBibliography(
                    entries: [targetEntry],
                    mode: mode,
                    noCache: noCache || isOffline || callOffline || isDemo,
                    environment: effectiveEnvironment,
                    clock: registryClock,
                    sharedRateLimiter: sharedRateLimiter,
                    sharedStandardCache: sharedStandardCache,
                    sharedReplayExplicitCache: sharedReplayExplicitCache,
                    language: lang
                )
                var verdicts = inRunVerdictsByKey
                for verdict in verificationResult.report.verdicts {
                    verdicts[verdict.citeKey] = verdict
                }
                let matchedVerdict = verdicts[citeKey]
                do {
                    let verifiedEntry = try firewall.assertCitationAllowed(
                        citeKey: citeKey,
                        in: byKey,
                        verifiedVerdicts: verdicts,
                        language: lang
                    )
                    return formatCiteKeyResult(
                        verifiedEntry: verifiedEntry,
                        verdict: matchedVerdict,
                        styleRaw: styleRaw,
                        formatRaw: formatRaw,
                        modeLabel: citeModeLabel,
                        isDemo: isDemo
                    )
                } catch let ScholarOSError.unverifiedCitationBlocked(key, status, reason) {
                    return formatUnverifiedCitationErrorResult(
                        citeKey: key,
                        verdictCode: status,
                        verdict: matchedVerdict,
                        missingFromBibliography: false,
                        reason: reason,
                        modeLabel: citeModeLabel
                    )
                }

            case "scholar_verify_bibliography":
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

                let callOffline = (arguments["offline"] as? Bool == true)
                let mode = try resolveVerificationMode(arguments: arguments, isDemo: isDemo)
                let verificationResult = try await CitationVerificationFirewall.verifyBibliography(
                    entries: entries,
                    mode: mode,
                    noCache: noCache || isOffline || callOffline,
                    environment: effectiveEnvironment,
                    clock: registryClock,
                    sharedRateLimiter: sharedRateLimiter,
                    sharedStandardCache: sharedStandardCache,
                    sharedReplayExplicitCache: sharedReplayExplicitCache,
                    language: resolvedLanguage(arguments: arguments)
                )
                let data = try verificationResult.encodeAuditJSONData(sortedKeys: true)
                return textResult(String(decoding: data, as: UTF8.self), isError: false)

            case "scholar_lsp_diagnostics":
                let callOffline = (arguments["offline"] as? Bool == true)
                if let rawPathValue = arguments["path"], !(rawPathValue is NSNull) {
                    guard let manuscriptPath = rawPathValue as? String else {
                        throw ScholarOSError.invalidCLIArguments(
                            "Argument 'path' for scholar_lsp_diagnostics must be a string."
                        )
                    }
                    guard !manuscriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ScholarOSError.invalidCLIArguments(
                            "Argument 'path' for scholar_lsp_diagnostics must not be empty."
                        )
                    }
                    if arguments["source"] != nil && !(arguments["source"] is NSNull) {
                        throw ScholarOSError.invalidCLIArguments(
                            "Cannot combine 'path' with inline 'source' in scholar_lsp_diagnostics."
                        )
                    }
                    if let proj = arguments["projectPath"] as? String, !proj.isEmpty {
                        throw ScholarOSError.invalidCLIArguments(
                            "Cannot combine 'path' with 'projectPath' in scholar_lsp_diagnostics."
                        )
                    }
                    if arguments["demo"] as? Bool == true {
                        throw ScholarOSError.invalidCLIArguments(
                            "Cannot combine 'path' with 'demo: true' in scholar_lsp_diagnostics."
                        )
                    }
                    let callNoVerify = (arguments["noVerify"] as? Bool == true)
                    if callNoVerify && callOffline {
                        throw ScholarOSError.invalidCLIArguments(
                            "Cannot combine 'noVerify' with 'offline' in scholar_lsp_diagnostics."
                        )
                    }

                    let rawBibPath = (arguments["bibPath"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let explicitBibPath = (rawBibPath?.isEmpty == false) ? rawBibPath : nil

                    let lsp = try ScholarLSPWorkspaceService.loadManuscript(
                        atPath: manuscriptPath,
                        explicitBibPath: explicitBibPath,
                        clock: registryClock
                    )

                    if callNoVerify {
                        lsp.setSkipCitationVerification(true)
                        let jsonReport = lsp.buildDiagnosticsJSONReport(mode: "no-verify", verificationReport: nil)
                        let data = try jsonReport.encodeJSONData(sortedKeys: true)
                        return textResult(String(decoding: data, as: UTF8.self), isError: false)
                    }

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
                        environment: effectiveEnvironment,
                        clock: registryClock,
                        sharedRateLimiter: sharedRateLimiter,
                        sharedStandardCache: sharedStandardCache,
                        sharedReplayExplicitCache: sharedReplayExplicitCache,
                        language: resolvedLanguage(arguments: arguments)
                    )
                    lsp.applyVerificationReport(verificationResult.report)
                    let jsonReport = lsp.buildDiagnosticsJSONReport(
                        mode: jsonModeLabel,
                        verificationReport: verificationResult.report
                    )
                    let data = try jsonReport.encodeJSONData(sortedKeys: true)
                    return textResult(String(decoding: data, as: UTF8.self), isError: false)
                }

                if let inlineSource = arguments["source"] as? String {
                    let path = arguments["filePath"] as? String ?? "main.tex"
                    var entries: [BibliographyEntry] = []
                    var isDemo = (arguments["demo"] as? Bool == true)
                    if let rawBib = arguments["bibtex"] as? String, !rawBib.isEmpty {
                        entries = try BibTeXCodec().parse(rawBib)
                        isDemo = false
                    } else if hasExplicitDatabaseTarget(in: arguments) {
                        let opened = try openDatabase(from: arguments)
                        defer { opened.db.close() }
                        entries = try opened.db.listBibliographyEntries()
                        isDemo = opened.isDemo
                    }
                    let lsp = ScholarLSPWorkspaceService(
                        rootFilePath: path,
                        files: [path: inlineSource],
                        bibliography: entries,
                        clock: registryClock
                    )
                    let mode = try resolveVerificationMode(arguments: arguments, isDemo: isDemo)
                    let verificationResult = try await CitationVerificationFirewall.verifyBibliography(
                        entries: lsp.citedBibliographyEntries,
                        mode: mode,
                        noCache: noCache || isOffline || callOffline,
                        environment: effectiveEnvironment,
                        clock: registryClock,
                        sharedRateLimiter: sharedRateLimiter,
                        sharedStandardCache: sharedStandardCache,
                        sharedReplayExplicitCache: sharedReplayExplicitCache,
                        language: resolvedLanguage(arguments: arguments)
                    )
                    lsp.applyVerificationReport(verificationResult.report)
                    let diagReport = lsp.diagnosticsReport()
                    let isErr = diagReport.firewallViolationCount > 0 || diagReport.errorCount > 0
                    if case .replay = mode {
                        let diagData = try JSONEncoder().encode(diagReport.diagnostics)
                        let diagArr = (try? JSONSerialization.jsonObject(with: diagData)) ?? []
                        let replayObj: [String: Any] = ["mode": "REPLAY", "diagnostics": diagArr]
                        let outData = try JSONSerialization.data(withJSONObject: replayObj, options: [.sortedKeys, .withoutEscapingSlashes])
                        return textResult(String(decoding: outData, as: UTF8.self), isError: isErr)
                    }
                    let data = try JSONEncoder().encode(diagReport.diagnostics)
                    return textResult(
                        String(decoding: data, as: UTF8.self),
                        isError: isErr
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
                    bibliography: entries,
                    clock: registryClock
                )
                let mode = try resolveVerificationMode(arguments: arguments, isDemo: opened.isDemo)
                let verificationResult = try await CitationVerificationFirewall.verifyBibliography(
                    entries: lsp.citedBibliographyEntries,
                    mode: mode,
                    noCache: noCache || isOffline || callOffline,
                    environment: effectiveEnvironment,
                    clock: registryClock,
                    sharedRateLimiter: sharedRateLimiter,
                    sharedStandardCache: sharedStandardCache,
                    sharedReplayExplicitCache: sharedReplayExplicitCache,
                    language: resolvedLanguage(arguments: arguments)
                )
                lsp.applyVerificationReport(verificationResult.report)
                let diagReport = lsp.diagnosticsReport()
                let isProjErr = diagReport.firewallViolationCount > 0
                if case .replay = mode {
                    let diagData = try JSONEncoder().encode(diagReport.diagnostics)
                    let diagArr = (try? JSONSerialization.jsonObject(with: diagData)) ?? []
                    let replayObj: [String: Any] = ["mode": "REPLAY", "diagnostics": diagArr]
                    let outData = try JSONSerialization.data(withJSONObject: replayObj, options: [.sortedKeys, .withoutEscapingSlashes])
                    return textResult(String(decoding: outData, as: UTF8.self), isError: isProjErr)
                }
                let data = try JSONEncoder().encode(diagReport.diagnostics)
                return textResult(
                    String(decoding: data, as: UTF8.self),
                    isError: isProjErr
                )

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
        if let argErr = validateToolArguments(toolName: name, arguments: arguments) {
            return argErr
        }
        if name == "scholar_verify_bibliography"
            || name == "scholar_lsp_diagnostics"
            || name == "scholar_cite_key"
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

    private func formatUnverifiedCitationErrorResult(
        citeKey: String,
        verdictCode: String,
        verdict: CitationFirewallEntryVerdict?,
        missingFromBibliography: Bool,
        reason: String,
        modeLabel: String
    ) -> [String: Any] {
        let reasons: [String]
        if let v = verdict, !v.reasons.isEmpty {
            reasons = v.reasons
        } else if missingFromBibliography {
            reasons = ["cite_key_not_in_bibliography"]
        } else {
            reasons = []
        }
        let fieldsArr: Any
        let findingsArr: Any
        let sourcesArr: Any
        let recordVal: Any
        if let v = verdict {
            let encoder = JSONEncoder()
            fieldsArr = (try? JSONSerialization.jsonObject(with: encoder.encode(v.fields))) ?? []
            findingsArr = (try? JSONSerialization.jsonObject(with: encoder.encode(v.findings))) ?? []
            sourcesArr = (try? JSONSerialization.jsonObject(with: encoder.encode(v.sources))) ?? []
            if let rec = v.record, let recObj = try? JSONSerialization.jsonObject(with: encoder.encode(rec)) {
                recordVal = recObj
            } else {
                recordVal = NSNull()
            }
        } else {
            fieldsArr = [Any]()
            findingsArr = [Any]()
            sourcesArr = [Any]()
            recordVal = NSNull()
        }

        var payload: [String: Any] = [
            "error_code": "ERR_UNVERIFIED_CITATION",
            "category": "unverified_citation",
            "cite_key": citeKey,
            "verdict": verdictCode,
            "reasons": reasons,
            "fields": fieldsArr,
            "findings": findingsArr,
            "sources": sourcesArr,
            "record": recordVal,
            "reason": reason
        ]
        if modeLabel == "REPLAY" || isReplayServer {
            payload["mode"] = "REPLAY"
        } else {
            payload["mode"] = modeLabel
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return textResult(String(decoding: data, as: UTF8.self), isError: true)
        }
        return textResult("[ERR_UNVERIFIED_CITATION] Key '\(citeKey)' (\(verdictCode)) rejected by Citation Firewall: \(reason)", isError: true)
    }

    private func formatCiteKeyResult(
        verifiedEntry: BibliographyEntry,
        verdict: CitationFirewallEntryVerdict?,
        styleRaw: String,
        formatRaw: String,
        modeLabel: String,
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
        let formatNormalized = formatRaw == "typst" ? "typst" : "latex"
        let snippet = formatNormalized == "typst" ? formatted.inTextTypst : formatted.inTextLaTeX
        let effectiveMode = isDemo ? "DEMO" : modeLabel

        var payload: [String: Any] = [
            "mode": effectiveMode,
            "status": "CITATION_STATUS:\(verifiedEntry.firewallClass.rawValue)",
            "cite_key": verifiedEntry.citeKey,
            "verdict": verifiedEntry.firewallClass.rawValue,
            "format": formatNormalized,
            "style": style.rawValue,
            "snippet": snippet,
            "reference": formatted.bibliographyPlainText
        ]
        if effectiveMode == "REPLAY" {
            payload["replay"] = true
        }
        if let v = verdict {
            let encoder = JSONEncoder()
            if let srcObj = try? JSONSerialization.jsonObject(with: encoder.encode(v.sources)) {
                payload["sources"] = srcObj
            }
            if let findingsObj = try? JSONSerialization.jsonObject(with: encoder.encode(v.findings)) {
                payload["findings"] = findingsObj
            }
            if let rec = v.record, let recObj = try? JSONSerialization.jsonObject(with: encoder.encode(rec)) {
                payload["record"] = recObj
            }
        }
        if let verifiedAt = verifiedEntry.firewallVerifiedAtUTC {
            payload["verified_at_utc"] = verifiedAt
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return textResult(String(decoding: data, as: UTF8.self), isError: false)
        }
        let demoPrefix = isDemo ? "[DEMO]\n" : ""
        let payloadText = """
        \(demoPrefix)[CITATION_STATUS:\(verifiedEntry.firewallClass.rawValue)]
        Snippet: \(snippet)
        Reference (\(style.rawValue)): \(formatted.bibliographyPlainText)
        """
        return textResult(payloadText, isError: false)
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
            "name": "scholar_cite_key",
            "description": "Citation insertion check. Verifies the target entry through the shared Citation Verification Firewall (online by default unless offline: true is passed or server started with --offline / --registry-replay) and returns formatted \\cite{key} or #cite(<key>) ONLY if VERIFIED; otherwise returns ERR_UNVERIFIED_CITATION.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "citeKey": ["type": "string"],
                    "style": ["type": "string"],
                    "manuscriptFormat": ["type": "string"],
                    "bibtex": ["type": "string"],
                    "projectPath": ["type": "string"],
                    "offline": ["type": "boolean"],
                    "lang": ["type": "string"],
                    "demo": ["type": "boolean"]
                ],
                "required": ["citeKey"]
            ]
        ],
        [
            "name": "scholar_verify_bibliography",
            "description": "Verify a BibTeX string or .scholarproj bibliography through the 5-class Citation Verification Firewall (queries public registries online by default; pass offline: true to skip network and cache for one call).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bibtex": ["type": "string"],
                    "projectPath": ["type": "string"],
                    "offline": ["type": "boolean"],
                    "lang": ["type": "string"],
                    "demo": ["type": "boolean"]
                ]
            ]
        ],
        [
            "name": "scholar_lsp_diagnostics",
            "description": "Run the built-in LaTeX/Typst CST, cross-reference, float-label, and Citation Firewall LSP diagnostics engine. Pass 'path' (manuscript main .tex file) to load multi-file manuscripts via the unified loader and return the scholaros.diagnostics/1 JSON object identical to CLI 'diagnostics <path> --json', or pass inline 'source'.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "bibPath": ["type": "string"],
                    "noVerify": ["type": "boolean"],
                    "lang": ["type": "string"],
                    "source": ["type": "string"],
                    "bibtex": ["type": "string"],
                    "filePath": ["type": "string"],
                    "projectPath": ["type": "string"],
                    "offline": ["type": "boolean"],
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
