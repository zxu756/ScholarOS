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

// MARK: - Headless Academic CLI Runner (`ScholarCLIRunner`)

public struct CLIExecutionOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public struct CLIProcessResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

private final class VerboseTelemetryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func record(_ event: RegistryRequestTelemetryEvent) {
        let statusLabel = event.statusCode.map(String.init) ?? "ERROR"
        let elapsedMs = String(format: "%.1fms", event.elapsedSeconds * 1000.0)
        let startStr = String(format: "%.6f", event.startedAtUptime)
        let endStr = String(format: "%.6f", event.completedAtUptime)
        var line = "[HTTP] source=\(event.source) url=\(event.url) status=\(statusLabel) elapsed=\(elapsedMs) origin=\(event.origin.rawValue) start=\(startStr) end=\(endStr)"
        if let err = event.errorDescription, !err.isEmpty {
            let singleLine = err
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            line += " error=\(singleLine)"
        }
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func joinedStderr() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

private final class CacheWarningCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    init() {}

    func record(_ message: String) {
        let singleLine = message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else { return }
        lock.lock()
        lines.append(singleLine)
        lock.unlock()
    }

    func allLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

public struct ScholarCLIRunner: Sendable {
    public let registryTransport: any CitationRegistrySession
    public let registryClock: any RegistryClock
    public let environment: [String: String]?
    public let mcpInputLines: [String]?

    private var effectiveEnvironment: [String: String] {
        environment ?? ProcessInfo.processInfo.environment
    }

    public init(
        registryTransport: any CitationRegistrySession = LiveURLSessionRegistryClient(
            capturedHeaderNames: LiveURLSessionRegistryClient.recordingCapturedHeaderNames
        ),
        registryClock: any RegistryClock = SystemRegistryClock(),
        environment: [String: String]? = nil,
        mcpInputLines: [String]? = nil
    ) {
        self.registryTransport = registryTransport
        self.registryClock = registryClock
        self.environment = environment
        self.mcpInputLines = mcpInputLines
    }

    public func execute(arguments: [String]) async throws -> String {
        try await run(arguments: arguments).stdout
    }

    public func runWithExitStatus(arguments: [String]) async -> CLIProcessResult {
        let cliLang = (try? resolveCLILanguage(arguments: arguments))
            ?? effectiveEnvironment["SCHOLAROS_LANG"].flatMap(ScholarLanguage.parse)
            ?? .en
        do {
            let output = try await run(arguments: arguments)
            return CLIProcessResult(stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode)
        } catch let error as ScholarOSError {
            let desc: String
            switch error {
            case .invalidCLIArguments(let detail) where cliLang == .zhHans:
                desc = "命令行参数错误：\(detail)"
            case .fileNotFound(let path) where cliLang == .zhHans:
                desc = "未找到文件或工程路径：\(path)"
            case .unverifiedCitationBlocked(let key, let status, let reason):
                if cliLang == .zhHans {
                    desc = "引文键 '\(key)'（\(status)）未通过引用核查：\(reason)"
                } else {
                    desc = "Key '\(key)' (\(status)) rejected by Citation Firewall: \(reason)"
                }
            default:
                desc = error.localizedDescription
            }
            let prefix = "[\(error.errorCodeIdentifier)] "
            return CLIProcessResult(
                stdout: "",
                stderr: desc.hasPrefix("[") ? desc : (prefix + desc),
                exitCode: 2
            )
        } catch let error as RegistryReplayError {
            return CLIProcessResult(
                stdout: "",
                stderr: "[ERR_REGISTRY_REPLAY] \(error.localizedDescription)",
                exitCode: 2
            )
        } catch let error as RegistryRecordingError {
            return CLIProcessResult(
                stdout: "",
                stderr: "[ERR_REGISTRY_RECORD] \(error.localizedDescription)",
                exitCode: 2
            )
        } catch {
            return CLIProcessResult(
                stdout: "",
                stderr: "[ERR_RUNTIME] \(error.localizedDescription)",
                exitCode: 2
            )
        }
    }

    public func run(arguments: [String]) async throws -> CLIExecutionOutput {
        let lang = try resolveCLILanguage(arguments: arguments)
        let cleanedArgs = ScholarLocalizer.strippingLanguageArguments(arguments)
        guard let subcommand = cleanedArgs.first else {
            return CLIExecutionOutput(stdout: Self.localizedHelpBanner(lang), exitCode: 0)
        }
        let rest = Array(cleanedArgs.dropFirst())

        switch subcommand {
        case "help", "--help", "-h":
            return CLIExecutionOutput(stdout: Self.localizedHelpBanner(lang), exitCode: 0)

        case "version", "--version":
            return CLIExecutionOutput(
                stdout: lang.L(
                    "ScholarOS 1.3.0 (macOS arm64 · LaTeX/BibTeX Parser, CSL Formatter & Citation Audit · 中文/EN)",
                    "ScholarOS 1.3.0 (macOS arm64 · LaTeX/BibTeX 解析、CSL 引文排版与引文核查 · 中文/EN)"
                ),
                exitCode: 0
            )

        case "init":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project"],
                boolFlags: ["--seed-demo"],
                maxPositionals: 0
            )
            let bundlePath = parsed.values["--project"] ?? "ResearchStudy.scholarproj"
            let seed = parsed.bools.contains("--seed-demo")
            let db = try ScholarProjectDatabase(
                bundleURL: URL(fileURLWithPath: bundlePath),
                seedDemoIfEmpty: seed
            )
            defer { db.close() }
            if seed, (try? db.listBibliographyEntries().isEmpty) == true {
                try db.seedDeterministicResearchProject()
            }
            let stats = try db.computeProjectStats()
            let demoNote = seed ? "[DEMO] " : ""
            return CLIExecutionOutput(
                stdout: "\(demoNote)Initialized \(bundlePath) (words=\(stats.manuscriptWordCount), bib=\(stats.bibliographyCount), verified=\(stats.verifiedCitationCount), kappa=\(String(format: "%.3f", stats.cohensKappa)))",
                exitCode: 0
            )

        case "status":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project"],
                boolFlags: ["--demo"],
                maxPositionals: 0
            )
            let opened = try openReadDatabase(
                parsed: parsed,
                usage: lang.L(
                    "Usage: scholaros status --project <dir.scholarproj> | --demo",
                    "用法：scholaros status --project <dir.scholarproj> | --demo"
                ),
                lang: lang
            )
            defer { opened.db.close() }
            let stats = try opened.db.computeProjectStats()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(stats)
            return CLIExecutionOutput(stdout: String(decoding: data, as: UTF8.self), exitCode: 0)

        case "outline":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project"],
                boolFlags: ["--demo", "--json"],
                maxPositionals: 1,
                lang: lang
            )
            let emitJSON = parsed.bools.contains("--json")
            if let fileArg = parsed.positionals.first {
                if parsed.values["--project"] != nil || parsed.bools.contains("--demo") {
                    throw ScholarOSError.invalidCLIArguments(
                        lang.L(
                            "Cannot combine direct file '\(fileArg)' with --project or --demo.",
                            "不能将直接文件参数 '\(fileArg)' 与 --project 或 --demo 同时使用。"
                        )
                    )
                }
                let lsp = try ScholarLSPWorkspaceService.loadManuscript(
                    atPath: fileArg,
                    explicitBibPath: nil,
                    clock: registryClock
                )
                return CLIExecutionOutput(
                    stdout: try formatOutline(lsp.documentOutline, asJSON: emitJSON, isDemo: false, lang: lang),
                    exitCode: 0
                )
            }
            let opened = try openReadDatabase(
                parsed: parsed,
                usage: lang.L(
                    "Usage: scholaros outline <paper.tex> [--json] | --project <dir.scholarproj> | --demo",
                    "用法：scholaros outline <paper.tex> [--json] | --project <dir.scholarproj> | --demo"
                ),
                lang: lang
            )
            defer { opened.db.close() }
            let lsp = try makeLSPService(from: opened.db)
            return CLIExecutionOutput(
                stdout: try formatOutline(lsp.documentOutline, asJSON: emitJSON, isDemo: opened.isDemo, lang: lang),
                exitCode: 0
            )

        case "diagnostics":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project", "--bib", "--registry-replay"],
                boolFlags: ["--demo", "--offline", "--no-verify", "--no-cache", "--json"],
                maxPositionals: 1,
                lang: lang
            )
            let emitJSON = parsed.bools.contains("--json")
            let isOffline = parsed.bools.contains("--offline")
            let noVerify = parsed.bools.contains("--no-verify")
            let noCache = parsed.bools.contains("--no-cache")
            let replayDir = parsed.values["--registry-replay"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let replayDir, replayDir.isEmpty {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Option '--registry-replay' requires a non-empty directory path.",
                        "选项 '--registry-replay' 需要提供非空目录路径。"
                    )
                )
            }
            if isOffline && replayDir != nil {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Cannot combine --offline with --registry-replay.",
                        "不能将 --offline 与 --registry-replay 同时使用。"
                    )
                )
            }
            if noVerify && (isOffline || replayDir != nil) {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Cannot combine --no-verify with --offline or --registry-replay.",
                        "不能将 --no-verify 与 --offline 或 --registry-replay 同时使用。"
                    )
                )
            }
            if parsed.bools.contains("--demo") && replayDir != nil {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Cannot combine --demo with --registry-replay.",
                        "不能将 --demo 与 --registry-replay 同时使用。"
                    )
                )
            }

            let lsp: ScholarLSPWorkspaceService
            let isDemo: Bool
            if let fileArg = parsed.positionals.first {
                if parsed.values["--project"] != nil || parsed.bools.contains("--demo") {
                    throw ScholarOSError.invalidCLIArguments(
                        lang.L(
                            "Cannot combine direct file '\(fileArg)' with --project or --demo.",
                            "不能将直接文件参数 '\(fileArg)' 与 --project 或 --demo 同时使用。"
                        )
                    )
                }
                lsp = try ScholarLSPWorkspaceService.loadManuscript(
                    atPath: fileArg,
                    explicitBibPath: parsed.values["--bib"],
                    clock: registryClock
                )
                isDemo = false
            } else {
                if let bibArg = parsed.values["--bib"] {
                    throw ScholarOSError.invalidCLIArguments(
                        lang.L(
                            "Option '--bib' (\(bibArg)) requires a direct <paper.tex> file argument.",
                            "选项 '--bib'（\(bibArg)）必须搭配直接文件参数 <paper.tex> 使用。"
                        )
                    )
                }
                let opened = try openReadDatabase(
                    parsed: parsed,
                    usage: lang.L(
                        "Usage: scholaros diagnostics <paper.tex> [--bib <refs.bib>] [--offline | --registry-replay <dir> | --no-verify] [--no-cache] [--json] | --project <dir.scholarproj> | --demo",
                        "用法：scholaros diagnostics <paper.tex> [--bib <refs.bib>] [--offline | --registry-replay <目录> | --no-verify] [--no-cache] [--json] | --project <dir.scholarproj> | --demo"
                    ),
                    lang: lang
                )
                defer { opened.db.close() }
                let sourceLabel = opened.isDemo
                    ? "demo"
                    : URL(fileURLWithPath: parsed.values["--project"] ?? "project.scholarproj").lastPathComponent
                lsp = try makeLSPService(from: opened.db, bibliographySourcePath: sourceLabel)
                isDemo = opened.isDemo
            }

            if noVerify {
                lsp.setSkipCitationVerification(true)
                let diagReport = lsp.diagnosticsReport()
                let hasStructureError = diagReport.diagnostics.contains {
                    $0.category == .structure && $0.severity == .error
                }
                let exitCode: Int32 = hasStructureError ? 1 : 0
                if emitJSON {
                    if isDemo {
                        fputs(
                            lang.L(
                                "[DEMO] Using built-in sample unverified dataset\n",
                                "[DEMO / 演示数据] 当前使用内置未核查示例数据集\n"
                            ),
                            stderr
                        )
                    }
                    let jsonReport = lsp.buildDiagnosticsJSONReport(mode: "no-verify", verificationReport: nil)
                    let data = try jsonReport.encodeJSONData(sortedKeys: true)
                    return CLIExecutionOutput(
                        stdout: String(decoding: data, as: UTF8.self),
                        stderr: "",
                        exitCode: exitCode
                    )
                }
                let citedCount = lsp.symbolTable.citationsByKey.count
                return CLIExecutionOutput(
                    stdout: try formatDiagnostics(
                        diagReport,
                        asJSON: false,
                        isDemo: isDemo,
                        noVerify: true,
                        noVerifyCitedKeyCount: citedCount,
                        lang: lang
                    ),
                    stderr: "",
                    exitCode: exitCode
                )
            }

            let cacheWarningCollector = CacheWarningCollector()
            let mode: BibliographyVerificationMode
            let jsonModeLabel: String
            if let replayDir {
                let snapshot = try RegistryReplaySnapshot(directoryURL: URL(fileURLWithPath: replayDir))
                mode = .replay(snapshot: snapshot)
                jsonModeLabel = "REPLAY"
            } else if isOffline || isDemo {
                mode = .offline
                jsonModeLabel = "offline"
            } else {
                mode = .online(transport: registryTransport)
                jsonModeLabel = "online"
            }

            let verificationResult = try await CitationVerificationFirewall.verifyBibliography(
                entries: lsp.citedBibliographyEntries,
                mode: mode,
                noCache: noCache || isOffline,
                environment: effectiveEnvironment,
                clock: registryClock,
                language: lang,
                cacheWarningHandler: { message in
                    cacheWarningCollector.record(message)
                }
            )
            lsp.applyVerificationReport(verificationResult.report)
            let diagReport = lsp.diagnosticsReport()
            let audit = verificationResult.report
            let hasStructureError = diagReport.diagnostics.contains {
                $0.category == .structure && $0.severity == .error
            }
            let exitCode: Int32
            if hasStructureError || audit.driftCount > 0 || audit.notFoundCount > 0 || audit.retractedCount > 0 {
                exitCode = 1
            } else if audit.unverifiedCount > 0 {
                exitCode = 3
            } else {
                exitCode = 0
            }

            var stderrLines = cacheWarningCollector.allLines()
            if emitJSON && verificationResult.isReplay {
                stderrLines.append(
                    Self.replayBannerLine(usesCache: verificationResult.replayUsesCache, lang: lang)
                )
            }
            if emitJSON {
                if isDemo {
                    fputs(
                        lang.L(
                            "[DEMO] Using built-in sample unverified dataset\n",
                            "[DEMO / 演示数据] 当前使用内置未核查示例数据集\n"
                        ),
                        stderr
                    )
                }
                let jsonReport = lsp.buildDiagnosticsJSONReport(
                    mode: jsonModeLabel,
                    verificationReport: verificationResult.report
                )
                let data = try jsonReport.encodeJSONData(sortedKeys: true)
                return CLIExecutionOutput(
                    stdout: String(decoding: data, as: UTF8.self),
                    stderr: stderrLines.joined(separator: "\n"),
                    exitCode: exitCode
                )
            }
            return CLIExecutionOutput(
                stdout: try formatDiagnostics(
                    diagReport,
                    asJSON: false,
                    isDemo: isDemo,
                    isReplay: verificationResult.isReplay,
                    replayUsesCache: verificationResult.replayUsesCache,
                    lang: lang
                ),
                stderr: stderrLines.joined(separator: "\n"),
                exitCode: exitCode
            )

        case "verify-citations":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project", "--registry-record", "--registry-record-limit", "--registry-replay"],
                boolFlags: ["--demo", "--offline", "--no-cache", "--json", "--strict", "--verbose"],
                maxPositionals: 1,
                lang: lang
            )
            let emitJSON = parsed.bools.contains("--json")
            let isOffline = parsed.bools.contains("--offline")
            let noCache = parsed.bools.contains("--no-cache")
            let verbose = parsed.bools.contains("--verbose")
            let recordDir = parsed.values["--registry-record"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawRecordLimit = parsed.values["--registry-record-limit"]
            let replayDir = parsed.values["--registry-replay"]?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let recordDir, recordDir.isEmpty {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Option '--registry-record' requires a non-empty directory path.",
                        "选项 '--registry-record' 需要提供非空目录路径。"
                    )
                )
            }
            if let replayDir, replayDir.isEmpty {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Option '--registry-replay' requires a non-empty directory path.",
                        "选项 '--registry-replay' 需要提供非空目录路径。"
                    )
                )
            }
            if recordDir != nil && replayDir != nil {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Cannot specify both --registry-record and --registry-replay.",
                        "不能同时指定 --registry-record 与 --registry-replay。"
                    )
                )
            }
            if isOffline && (recordDir != nil || replayDir != nil) {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Cannot combine --offline with --registry-record or --registry-replay.",
                        "不能将 --offline 与 --registry-record 或 --registry-replay 同时使用。"
                    )
                )
            }
            if parsed.bools.contains("--demo") && (recordDir != nil || replayDir != nil) {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Cannot combine --demo with --registry-record or --registry-replay.",
                        "不能将 --demo 与 --registry-record 或 --registry-replay 同时使用。"
                    )
                )
            }
            let recordLimit: Int
            if let rawRecordLimit {
                guard recordDir != nil else {
                    throw ScholarOSError.invalidCLIArguments(
                        lang.L(
                            "Option '--registry-record-limit' can only be used with '--registry-record <dir>'.",
                            "选项 '--registry-record-limit' 只能与 '--registry-record <目录>' 一起使用。"
                        )
                    )
                }
                guard !rawRecordLimit.isEmpty,
                      rawRecordLimit.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                      let parsedLimit = Int(rawRecordLimit),
                      parsedLimit > 0
                else {
                    throw ScholarOSError.invalidCLIArguments(
                        lang.L(
                            "Option '--registry-record-limit' requires a positive integer (got '\(rawRecordLimit)').",
                            "选项 '--registry-record-limit' 需要正整数（收到 '\(rawRecordLimit)'）。"
                        )
                    )
                }
                recordLimit = parsedLimit
            } else {
                recordLimit = 80
            }

            let entries: [BibliographyEntry]
            let isDemo: Bool
            var bibParseErrorLines: [String] = []

            if let bibPath = parsed.positionals.first {
                if parsed.values["--project"] != nil || parsed.bools.contains("--demo") {
                    throw ScholarOSError.invalidCLIArguments(
                        lang.L(
                            "Cannot combine direct file '\(bibPath)' with --project or --demo.",
                            "不能将直接文件参数 '\(bibPath)' 与 --project 或 --demo 同时使用。"
                        )
                    )
                }
                let rawBib = try readRequiredRegularFile(atPath: bibPath)
                let bibDoc = try BibTeXCodec().parseDocument(rawBib)
                let validEntryCount = bibDoc.entries.filter { !$0.parseError }.count
                if validEntryCount == 0 {
                    throw ScholarOSError.bibliographyParseFailure(
                        format: "BibTeX",
                        line: bibDoc.errors.first?.line ?? 1,
                        detail: bibDoc.errors.first?.message ?? "No valid BibTeX entries found in '\(bibPath)'."
                    )
                }
                for err in bibDoc.errors {
                    let keyLabel = err.key ?? "<unknown>"
                    bibParseErrorLines.append(
                        lang.L(
                            "[BIB001] \(bibPath):\(err.line): BibTeX parse error in entry '\(keyLabel)' (started at line \(err.startLine), error at line \(err.line)): \(err.message)",
                            "[BIB001] \(bibPath):\(err.line): BibTeX 条目 '\(keyLabel)' 解析错误（始于第 \(err.startLine) 行，出错于第 \(err.line) 行）：\(err.message)"
                        )
                    )
                }
                entries = bibDoc.entries
                isDemo = false
            } else {
                let opened = try openReadDatabase(
                    parsed: parsed,
                    usage: lang.L(
                        "Usage: scholaros verify-citations <refs.bib> [--offline | --registry-record <dir> [--registry-record-limit <N>] | --registry-replay <dir>] [--no-cache] [--verbose] [--json] | --project <dir.scholarproj> | --demo",
                        "用法：scholaros verify-citations <refs.bib> [--offline | --registry-record <目录> [--registry-record-limit <N>] | --registry-replay <目录>] [--no-cache] [--verbose] [--json] | --project <dir.scholarproj> | --demo"
                    ),
                    lang: lang
                )
                defer { opened.db.close() }
                entries = try opened.db.listBibliographyEntries()
                isDemo = opened.isDemo
            }

            let cacheWarningCollector = CacheWarningCollector()
            let verboseCollector: VerboseTelemetryCollector? = verbose ? VerboseTelemetryCollector() : nil
            let observer: RegistryRequestObserver?
            if let collector = verboseCollector {
                observer = { @Sendable event in
                    collector.record(event)
                }
            } else {
                observer = nil
            }

            let mode: BibliographyVerificationMode
            if let recordDir {
                mode = .record(
                    directoryURL: URL(fileURLWithPath: recordDir),
                    transport: registryTransport,
                    maxRequests: recordLimit
                )
            } else if let replayDir {
                let snapshot = try RegistryReplaySnapshot(directoryURL: URL(fileURLWithPath: replayDir))
                mode = .replay(snapshot: snapshot)
            } else if isOffline || isDemo {
                mode = .offline
            } else {
                mode = .online(transport: registryTransport)
            }

            let verificationResult = try await CitationVerificationFirewall.verifyBibliography(
                entries: entries,
                mode: mode,
                noCache: noCache || isOffline,
                environment: effectiveEnvironment,
                clock: registryClock,
                language: lang,
                cacheWarningHandler: { message in
                    cacheWarningCollector.record(message)
                },
                requestObserver: observer
            )
            let audit = verificationResult.report
            let isReplayMode = verificationResult.isReplay
            let replayUsesCache = verificationResult.replayUsesCache
            let performedRegistryLookup = verificationResult.performedRegistryLookup

            let hasParseErrorEntries = !bibParseErrorLines.isEmpty
                || (audit.unverifiedByReason[CitationUnverifiedReasonCode.parseError.rawValue] ?? 0) > 0
            let exitCode: Int32
            if audit.driftCount > 0 || audit.notFoundCount > 0 || audit.retractedCount > 0 || hasParseErrorEntries {
                exitCode = 1
            } else if audit.unverifiedCount > 0 {
                exitCode = 3
            } else {
                exitCode = 0
            }

            var stderrParts = bibParseErrorLines + cacheWarningCollector.allLines()
            if let verboseText = verboseCollector?.joinedStderr(), !verboseText.isEmpty {
                stderrParts.append(verboseText)
            }
            let collectedStderr = stderrParts.joined(separator: "\n")

            if emitJSON {
                if isDemo {
                    fputs(
                        lang.L(
                            "[DEMO] Using built-in sample unverified dataset\n",
                            "[DEMO / 演示数据] 当前使用内置未核查示例数据集\n"
                        ),
                        stderr
                    )
                }
                let data = try verificationResult.encodeAuditJSONData(sortedKeys: true)
                return CLIExecutionOutput(
                    stdout: String(decoding: data, as: UTF8.self),
                    stderr: collectedStderr,
                    exitCode: exitCode
                )
            }

            var lines: [String] = []
            if isDemo {
                lines.append(lang.L("[DEMO] Sample unverified dataset", "[DEMO / 演示数据] 示例未核查数据集"))
            }
            if isReplayMode {
                lines.append(Self.replayBannerLine(usesCache: replayUsesCache, lang: lang))
            }
            lines.append(
                "Evaluated=\(audit.totalEvaluated) Verified=\(audit.verifiedCount) Drift=\(audit.driftCount) NotFound=\(audit.notFoundCount) Retracted=\(audit.retractedCount) Unverified=\(audit.unverifiedCount)"
            )
            if audit.unverifiedCount > 0 {
                lines.append(Self.incompleteUnverifiedSummaryLine(audit: audit, lang: lang))
            }
            if !performedRegistryLookup {
                lines.append(Self.noOnlineLookupNotice(lang, isDemo: isDemo))
            }
            for verdict in audit.verdicts {
                // The class is printed once, here; the note's own leading "[CLASS] " tag is dropped.
                let note = CitationAuditWording.strippingLeadingClassTag(
                    Self.localizedVerdictAuditNote(verdict, lang: lang)
                )
                lines.append("[\(verdict.firewallClass.rawValue)] \(verdict.citeKey): \(note)")
            }
            return CLIExecutionOutput(
                stdout: lines.joined(separator: "\n"),
                stderr: collectedStderr,
                exitCode: exitCode
            )

        case "cache":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: [],
                boolFlags: [],
                maxPositionals: 1,
                lang: lang
            )
            guard parsed.positionals.first == "clear" else {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Usage: scholaros cache clear",
                        "用法：scholaros cache clear"
                    )
                )
            }
            let dbURL = RegistryResponseCache.resolveDatabaseURL(environment: effectiveEnvironment)
            let removed = try RegistryResponseCache.clearCacheFiles(at: dbURL)
            if removed.isEmpty {
                return CLIExecutionOutput(
                    stdout: lang.L(
                        "No cache file to remove (\(dbURL.path)).",
                        "缓存文件不存在，无需删除（\(dbURL.path)）。"
                    ),
                    exitCode: 0
                )
            } else {
                let outLines = removed.map { url in
                    lang.L(
                        "Removed cache file: \(url.path)",
                        "已删除缓存文件：\(url.path)"
                    )
                }
                return CLIExecutionOutput(
                    stdout: outLines.joined(separator: "\n"),
                    exitCode: 0
                )
            }

        case "cite":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project", "--bib", "--registry-replay"],
                boolFlags: ["--demo", "--offline", "--no-cache"],
                maxPositionals: 1,
                lang: lang
            )
            let citeUsage = lang.L(
                "Usage: scholaros cite <citeKey> [--bib <refs.bib> | --project <dir.scholarproj> | --demo] [--offline | --registry-replay <dir>] [--no-cache]",
                "用法：scholaros cite <citeKey> [--bib <refs.bib> | --project <dir.scholarproj> | --demo] [--offline | --registry-replay <目录>] [--no-cache]"
            )
            guard let citeKey = parsed.positionals.first else {
                throw ScholarOSError.invalidCLIArguments(citeUsage)
            }
            let isOffline = parsed.bools.contains("--offline")
            let noCache = parsed.bools.contains("--no-cache")
            let replayDir = parsed.values["--registry-replay"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let replayDir, replayDir.isEmpty {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Option '--registry-replay' requires a non-empty directory path.",
                        "选项 '--registry-replay' 需要提供非空目录路径。"
                    )
                )
            }
            if isOffline && replayDir != nil {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Cannot combine --offline with --registry-replay.",
                        "不能将 --offline 与 --registry-replay 同时使用。"
                    )
                )
            }
            if parsed.bools.contains("--demo") && replayDir != nil {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Cannot combine --demo with --registry-replay.",
                        "不能将 --demo 与 --registry-replay 同时使用。"
                    )
                )
            }

            let entries: [BibliographyEntry]
            let isDemo: Bool
            var openedDB: ScholarProjectDatabase? = nil
            defer { openedDB?.close() }

            if let bibPath = parsed.values["--bib"] {
                if parsed.values["--project"] != nil || parsed.bools.contains("--demo") {
                    throw ScholarOSError.invalidCLIArguments(
                        lang.L(
                            "Cannot combine --bib '\(bibPath)' with --project or --demo.",
                            "不能将 --bib '\(bibPath)' 与 --project 或 --demo 同时使用。"
                        )
                    )
                }
                let rawBib = try readRequiredRegularFile(atPath: bibPath)
                entries = try BibTeXCodec().parse(rawBib)
                isDemo = false
            } else {
                let opened = try openReadDatabase(
                    parsed: parsed,
                    usage: citeUsage,
                    lang: lang
                )
                openedDB = opened.db
                entries = try opened.db.listBibliographyEntries()
                isDemo = opened.isDemo
            }

            var byKey: [String: BibliographyEntry] = [:]
            for entry in entries {
                byKey[entry.citeKey] = entry
            }

            let mode: BibliographyVerificationMode
            if let replayDir {
                let snapshot = try RegistryReplaySnapshot(directoryURL: URL(fileURLWithPath: replayDir))
                mode = .replay(snapshot: snapshot)
            } else if isOffline || isDemo {
                mode = .offline
            } else {
                mode = .online(transport: registryTransport)
            }

            let firewall = CitationVerificationFirewall(clock: registryClock)
            guard let targetEntry = byKey[citeKey] else {
                _ = try firewall.assertCitationAllowed(
                    citeKey: citeKey,
                    in: byKey,
                    verifiedVerdicts: [:],
                    language: lang
                )
                return CLIExecutionOutput(stdout: "", exitCode: 2)
            }

            let cacheWarnings = CacheWarningCollector()
            let verificationResult = try await CitationVerificationFirewall.verifyBibliography(
                entries: [targetEntry],
                mode: mode,
                noCache: noCache || isOffline || isDemo,
                environment: effectiveEnvironment,
                clock: registryClock,
                language: lang,
                cacheWarningHandler: { msg in
                    cacheWarnings.record(msg)
                }
            )
            var inRunVerdicts: [String: CitationFirewallEntryVerdict] = [:]
            for verdict in verificationResult.report.verdicts {
                inRunVerdicts[verdict.citeKey] = verdict
                openedDB?.recordInRunVerdict(verdict)
            }

            let verified = try firewall.assertCitationAllowed(
                citeKey: citeKey,
                in: byKey,
                verifiedVerdicts: inRunVerdicts,
                language: lang
            )
            let formatted = CSLCitationFormatterEngine().formatEntry(verified, style: .apa7)
            let prefix = isDemo ? "[DEMO] " : ""
            return CLIExecutionOutput(
                stdout: "\(prefix)\\cite{\(verified.citeKey)} -> \(formatted.bibliographyPlainText)",
                stderr: cacheWarnings.allLines().joined(separator: "\n"),
                exitCode: 0
            )

        case "format-bib":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project", "--style"],
                boolFlags: ["--demo", "--json"],
                maxPositionals: 1
            )
            let rawStyle = (parsed.values["--style"] ?? "apa7").lowercased()
            let style: CitationFormatStyle
            switch rawStyle {
            case "apa", "apa7": style = .apa7
            case "ieee": style = .ieee
            case "acm": style = .acm
            case "nature": style = .nature
            case "vancouver": style = .vancouver
            default:
                throw ScholarOSError.invalidCLIArguments(
                    "Unsupported --style '\(rawStyle)'. Supported styles: apa, ieee."
                )
            }

            let entries: [BibliographyEntry]
            let isDemo: Bool
            var formatExitCode: Int32 = 0
            var formatStderrLines: [String] = []
            if let bibPath = parsed.positionals.first {
                if parsed.values["--project"] != nil || parsed.bools.contains("--demo") {
                    throw ScholarOSError.invalidCLIArguments(
                        "Cannot combine direct file '\(bibPath)' with --project or --demo."
                    )
                }
                let rawBib = try readRequiredRegularFile(atPath: bibPath)
                let bibDoc = try BibTeXCodec().parseDocument(rawBib)
                let cleanEntries = bibDoc.entries.filter { !$0.parseError }
                if cleanEntries.isEmpty {
                    throw ScholarOSError.bibliographyParseFailure(
                        format: "BibTeX",
                        line: bibDoc.errors.first?.line ?? 1,
                        detail: bibDoc.errors.first?.message ?? "No valid BibTeX entries found in '\(bibPath)'."
                    )
                }
                if !bibDoc.errors.isEmpty {
                    formatExitCode = 1
                    for err in bibDoc.errors {
                        let keyLabel = err.key ?? "<unknown>"
                        formatStderrLines.append(
                            lang.L(
                                "[BIB001] \(bibPath):\(err.line): BibTeX parse error in entry '\(keyLabel)' (started at line \(err.startLine), error at line \(err.line)): \(err.message)",
                                "[BIB001] \(bibPath):\(err.line): BibTeX 条目 '\(keyLabel)' 解析错误（始于第 \(err.startLine) 行，出错于第 \(err.line) 行）：\(err.message)"
                            )
                        )
                    }
                }
                entries = cleanEntries
                isDemo = false
            } else {
            let opened = try openReadDatabase(
                parsed: parsed,
                usage: lang.L(
                    "Usage: scholaros format-bib <refs.bib> [--style apa|ieee] [--json] | --project <dir.scholarproj> | --demo",
                    "用法：scholaros format-bib <refs.bib> [--style apa|ieee] [--json] | --project <dir.scholarproj> | --demo"
                ),
                lang: lang
            )
            defer { opened.db.close() }
            entries = try opened.db.listBibliographyEntries().filter {
                $0.firewallClass != .notFound && $0.firewallClass != .retracted
            }
            isDemo = opened.isDemo
            }

            let formatted = CSLCitationFormatterEngine().formatBibliography(entries: entries, style: style)
            let formatStderr = formatStderrLines.joined(separator: "\n")
            if parsed.bools.contains("--json") {
                if isDemo {
                    fputs(
                        lang.L(
                            "[DEMO] Using built-in sample unverified dataset\n",
                            "[DEMO / 演示数据] 当前使用内置未核查示例数据集\n"
                        ),
                        stderr
                    )
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(formatted)
                return CLIExecutionOutput(
                    stdout: String(decoding: data, as: UTF8.self),
                    stderr: formatStderr,
                    exitCode: formatExitCode
                )
            }

            let header = isDemo ? lang.L("[DEMO] Sample unverified dataset\n", "[DEMO / 演示数据] 示例未核查数据集\n") : ""
            return CLIExecutionOutput(
                stdout: header + formatted.plainText,
                stderr: formatStderr,
                exitCode: formatExitCode
            )

        case "prisma-stats":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project"],
                boolFlags: ["--demo"],
                maxPositionals: 0
            )
            let opened = try openReadDatabase(
                parsed: parsed,
                usage: "Usage: scholaros prisma-stats --project <dir.scholarproj> | --demo"
            )
            defer { opened.db.close() }
            if opened.isDemo {
                fputs("[DEMO] Using built-in sample unverified dataset\n", stderr)
            }
            let metrics = try opened.db.computePRISMAMetrics()
            let data = try JSONEncoder().encode(metrics)
            return CLIExecutionOutput(stdout: String(decoding: data, as: UTF8.self), exitCode: 0)

        case "prisma-svg":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project", "--output"],
                boolFlags: ["--demo"],
                maxPositionals: 1
            )
            let outPath = parsed.values["--output"] ?? parsed.positionals.first ?? "prisma-flow.svg"
            let opened = try openReadDatabase(
                parsed: parsed,
                usage: "Usage: scholaros prisma-svg [<out.svg>] [--output <out.svg>] --project <dir.scholarproj> | --demo"
            )
            defer { opened.db.close() }
            let metrics = try opened.db.computePRISMAMetrics()
            let svg = PRISMA2020DiagramExporter().exportVectorSVG(metrics: metrics)
            try svg.write(toFile: outPath, atomically: true, encoding: .utf8)
            let prefix = opened.isDemo ? "[DEMO] " : ""
            return CLIExecutionOutput(stdout: "\(prefix)Exported PRISMA 2020 vector SVG to \(outPath)", exitCode: 0)

        case "citation-graph":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project"],
                boolFlags: ["--demo"],
                maxPositionals: 0
            )
            let opened = try openReadDatabase(
                parsed: parsed,
                usage: "Usage: scholaros citation-graph --project <dir.scholarproj> | --demo"
            )
            defer { opened.db.close() }
            let entries = try opened.db.listBibliographyEntries()
            let snapshot = CitationGraphBuilder().buildKnowledgeGraph(from: entries)
            let prefix = opened.isDemo ? "[DEMO] " : ""
            return CLIExecutionOutput(
                stdout: "\(prefix)Nodes=\(snapshot.nodes.count) Edges=\(snapshot.edges.count) Clusters=\(snapshot.clusterLabels.count) Bridges=\(snapshot.bridgeCiteKeys.joined(separator: ","))",
                exitCode: 0
            )

        case "track-changes":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project"],
                boolFlags: ["--demo"],
                maxPositionals: 0
            )
            let opened = try openReadDatabase(
                parsed: parsed,
                usage: "Usage: scholaros track-changes --project <dir.scholarproj> | --demo"
            )
            defer { opened.db.close() }
            let snapshots = try opened.db.listSnapshots()
            guard snapshots.count >= 2 else {
                return CLIExecutionOutput(
                    stdout: "Need at least 2 snapshots to diff (found \(snapshots.count)).",
                    exitCode: 0
                )
            }
            let engine = MyersWordLevelTrackChangesEngine()
            let diff = engine.diffSnapshots(baseline: snapshots[0], revised: snapshots[snapshots.count - 1])
            let prefix = opened.isDemo ? "[DEMO] " : ""
            return CLIExecutionOutput(
                stdout: "\(prefix)Diff '\(diff.baselineLabel)' -> '\(diff.revisedLabel)': +\(diff.insertedWordCount) / -\(diff.deletedWordCount) words (similarity=\(String(format: "%.1f%%", diff.similarityRatio * 100.0)))",
                exitCode: 0
            )

        case "audit-editorial":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project"],
                boolFlags: ["--demo"],
                maxPositionals: 0
            )
            let opened = try openReadDatabase(
                parsed: parsed,
                usage: "Usage: scholaros audit-editorial --project <dir.scholarproj> | --demo"
            )
            defer { opened.db.close() }
            var files: [String: String] = [:]
            for rec in try opened.db.listManuscriptFiles() {
                files[rec.path] = rec.content
            }
            let entries = try opened.db.listBibliographyEntries()
            let summary = try EditorialPluginAuditRunner().run(
                files: files,
                primaryFilePath: (try? opened.db.primaryManuscriptFile()) ?? "main.tex",
                bibliography: entries
            )
            let body = summary.findings.map { f in
                "[\(f.severity.rawValue)] \(f.filePath):\(f.line) (\(f.pluginID)): \(f.localizedExplanation(lang))"
            }.joined(separator: "\n")
            let prefix = opened.isDemo ? lang.L("[DEMO] Sample unverified dataset\n", "[DEMO / 演示数据] 示例未核查数据集\n") : ""
            return CLIExecutionOutput(stdout: prefix + body, exitCode: 0)

        case "export-bundle":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project", "--output"],
                boolFlags: ["--demo", "--allow-unverified"],
                maxPositionals: 1
            )
            let outDir = parsed.values["--output"] ?? parsed.positionals.first ?? "arxiv-bundle"
            let opened = try openReadDatabase(
                parsed: parsed,
                usage: "Usage: scholaros export-bundle [<dir>] [--output <dir>] [--allow-unverified] --project <dir.scholarproj> | --demo"
            )
            defer { opened.db.close() }
            var opts = SubmissionArchiveOptions.arxivDefault
            opts.allowUnverifiedCitationsOverride = parsed.bools.contains("--allow-unverified")
            let manifest = try AcademicArchiveBundleCodec().exportSubmissionBundle(
                from: opened.db,
                to: URL(fileURLWithPath: outDir),
                options: opts
            )
            let prefix = opened.isDemo ? "[DEMO] " : ""
            return CLIExecutionOutput(
                stdout: "\(prefix)Exported flattened submission bundle to \(outDir) (sha256=\(manifest.bundleRootSHA256), cited=\(manifest.citedKeysInAppearanceOrder.count))",
                exitCode: 0
            )

        case "export-html":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project", "--output"],
                boolFlags: ["--demo"],
                maxPositionals: 1
            )
            let outPath = parsed.values["--output"] ?? parsed.positionals.first ?? "scholar-dossier.html"
            let opened = try openReadDatabase(
                parsed: parsed,
                usage: "Usage: scholaros export-html [<out.html>] [--output <out.html>] --project <dir.scholarproj> | --demo"
            )
            defer { opened.db.close() }
            let html = try CambridgeLinenHTMLReportExporter().exportHTMLDossier(
                database: opened.db,
                isDemo: opened.isDemo
            )
            try html.write(toFile: outPath, atomically: true, encoding: .utf8)
            let prefix = opened.isDemo ? "[DEMO] " : ""
            return CLIExecutionOutput(
                stdout: "\(prefix)Exported Cambridge Linen HTML dossier to \(outPath)",
                exitCode: 0
            )

        case "mcp":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project", "--registry-replay"],
                boolFlags: ["--demo", "--offline", "--no-cache"],
                maxPositionals: 0,
                lang: lang
            )
            let projectPath = parsed.values["--project"]
            if let projectPath, !FileManager.default.fileExists(atPath: projectPath) {
                throw ScholarOSError.fileNotFound(projectPath)
            }
            let allowDemo = parsed.bools.contains("--demo")
            let isOffline = parsed.bools.contains("--offline")
            let noCache = parsed.bools.contains("--no-cache")
            let replayPath = parsed.values["--registry-replay"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let replayPath, replayPath.isEmpty {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Option '--registry-replay' requires a non-empty directory path.",
                        "选项 '--registry-replay' 需要提供非空目录路径。"
                    )
                )
            }
            if isOffline && replayPath != nil {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Cannot combine --offline with --registry-replay.",
                        "不能将 --offline 与 --registry-replay 同时使用。"
                    )
                )
            }
            if allowDemo && replayPath != nil {
                throw ScholarOSError.invalidCLIArguments(
                    lang.L(
                        "Cannot combine --demo with --registry-replay.",
                        "不能将 --demo 与 --registry-replay 同时使用。"
                    )
                )
            }

            // Validate `--registry-replay` directory at MCP startup (exiting 2 on missing/corrupt manifest or SHA-256 mismatch).
            let validatedReplaySnapshot: RegistryReplaySnapshot?
            if let replayPath {
                validatedReplaySnapshot = try RegistryReplaySnapshot(directoryURL: URL(fileURLWithPath: replayPath))
            } else {
                validatedReplaySnapshot = nil
            }

            let server = ScholarMCPServer(
                defaultProjectBundlePath: projectPath,
                allowDemoMode: allowDemo,
                defaultRegistryReplayPath: replayPath,
                defaultRegistryReplaySnapshot: validatedReplaySnapshot,
                isOffline: isOffline,
                noCache: noCache,
                registryTransport: registryTransport,
                registryClock: registryClock,
                environment: effectiveEnvironment
            )
            if let mcpInputLines {
                var outLines: [String] = []
                for line in mcpInputLines {
                    if let resp = await server.handleJSONRPCLineAsync(line) {
                        outLines.append(resp)
                    }
                }
                return CLIExecutionOutput(stdout: outLines.joined(separator: "\n"), exitCode: 0)
            }
            await server.serveStdio()
            return CLIExecutionOutput(stdout: "", exitCode: 0)

        default:
            throw ScholarOSError.invalidCLIArguments(
                lang.L(
                    "Unknown subcommand '\(subcommand)'. Run 'scholaros --help'.",
                    "未知子命令 '\(subcommand)'。请运行 'scholaros --help' 查看用法。"
                )
            )
        }
    }

    // MARK: - Argument Parsing & Input Validation

    private func resolveCLILanguage(arguments: [String]) throws -> ScholarLanguage {
        var idx = 0
        while idx < arguments.count {
            let arg = arguments[idx]
            if arg == "--lang" {
                guard idx + 1 < arguments.count, !arguments[idx + 1].hasPrefix("-") else {
                    throw ScholarOSError.invalidCLIArguments("Missing value for '--lang'. Expected 'en' or 'zh'.")
                }
                guard let parsed = ScholarLanguage.parse(arguments[idx + 1]) else {
                    throw ScholarOSError.invalidCLIArguments(
                        "Unsupported --lang '\(arguments[idx + 1])'. Supported languages: en, zh."
                    )
                }
                return parsed
            }
            if arg.hasPrefix("--lang=") {
                let raw = String(arg.dropFirst("--lang=".count))
                guard let parsed = ScholarLanguage.parse(raw) else {
                    throw ScholarOSError.invalidCLIArguments(
                        "Unsupported --lang '\(raw)'. Supported languages: en, zh."
                    )
                }
                return parsed
            }
            idx += 1
        }
        if let envRaw = effectiveEnvironment["SCHOLAROS_LANG"],
           let envLang = ScholarLanguage.parse(envRaw)
        {
            return envLang
        }
        return .en
    }

    private struct ParsedCLIArgs {
        let values: [String: String]
        let bools: Set<String>
        let positionals: [String]
    }

    private func parseArgs(
        _ args: [String],
        subcommand: String,
        valueFlags: Set<String>,
        boolFlags: Set<String>,
        maxPositionals: Int,
        lang: ScholarLanguage = .en
    ) throws -> ParsedCLIArgs {
        var values: [String: String] = [:]
        var bools = Set<String>()
        var positionals: [String] = []

        var i = 0
        while i < args.count {
            let tok = args[i]
            if tok.hasPrefix("-") {
                if let eqIdx = tok.firstIndex(of: "=") {
                    let flagName = String(tok[..<eqIdx])
                    let flagVal = String(tok[tok.index(after: eqIdx)...])
                    if valueFlags.contains(flagName) {
                        guard !flagVal.isEmpty else {
                            throw ScholarOSError.invalidCLIArguments(
                                lang.L(
                                    "Missing value for option '\(flagName)' in '\(subcommand)'.",
                                    "子命令 '\(subcommand)' 的选项 '\(flagName)' 缺少参数值。"
                                )
                            )
                        }
                        values[flagName] = flagVal
                        i += 1
                        continue
                    }
                }
                if valueFlags.contains(tok) {
                    guard i + 1 < args.count else {
                        throw ScholarOSError.invalidCLIArguments(
                            lang.L(
                                "Missing value for option '\(tok)' in '\(subcommand)'.",
                                "子命令 '\(subcommand)' 的选项 '\(tok)' 缺少参数值。"
                            )
                        )
                    }
                    let nextTok = args[i + 1]
                    if nextTok.hasPrefix("--") || nextTok == "-h" || valueFlags.contains(nextTok) || boolFlags.contains(nextTok) {
                        throw ScholarOSError.invalidCLIArguments(
                            lang.L(
                                "Missing value for option '\(tok)' in '\(subcommand)'.",
                                "子命令 '\(subcommand)' 的选项 '\(tok)' 缺少参数值。"
                            )
                        )
                    }
                    values[tok] = nextTok
                    i += 2
                } else if boolFlags.contains(tok) {
                    bools.insert(tok)
                    i += 1
                } else {
                    throw ScholarOSError.invalidCLIArguments(
                        lang.L(
                            "Unknown option '\(tok)' for subcommand '\(subcommand)'. Run 'scholaros --help'.",
                            "子命令 '\(subcommand)' 不支持选项 '\(tok)'。请运行 'scholaros --help'。"
                        )
                    )
                }
            } else {
                positionals.append(tok)
                i += 1
            }
        }

        if positionals.count > maxPositionals {
            throw ScholarOSError.invalidCLIArguments(
                lang.L(
                    "Unexpected argument '\(positionals[maxPositionals])' for subcommand '\(subcommand)'. Run 'scholaros --help'.",
                    "子命令 '\(subcommand)' 收到多余参数 '\(positionals[maxPositionals])'。请运行 'scholaros --help'。"
                )
            )
        }

        return ParsedCLIArgs(values: values, bools: bools, positionals: positionals)
    }

    private func openReadDatabase(
        parsed: ParsedCLIArgs,
        usage: String,
        lang: ScholarLanguage = .en
    ) throws -> (db: ScholarProjectDatabase, isDemo: Bool) {
        let projectPath = parsed.values["--project"]
        let useDemo = parsed.bools.contains("--demo")

        if projectPath != nil && useDemo {
            throw ScholarOSError.invalidCLIArguments(
                lang.L(
                    "Cannot specify both --project and --demo.",
                    "不能同时指定 --project 与 --demo。"
                )
            )
        }

        if let projectPath {
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

        if useDemo {
            let db = try ScholarProjectDatabase.inMemory(seedDemo: true, clock: registryClock)
            if let currentTitle = try? db.projectTitle(), !currentTitle.hasPrefix("[DEMO]") {
                try? db.setProjectTitle("[DEMO] \(currentTitle)")
            }
            return (db, true)
        }

        throw ScholarOSError.invalidCLIArguments(usage)
    }

    private func readRequiredRegularFile(atPath path: String) throws -> String {
        try ScholarTextFileReader.readRegularFile(atPath: path).text
    }

    private static func hasNonCommentContent(_ source: String) -> Bool {
        let normalizedSource = source.utf8.contains(0x0D)
            ? source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            : source
        for rawLine in normalizedSource.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineChars = Array(rawLine)
            var idx = 0
            var codeSlice = ""
            while idx < lineChars.count {
                let ch = lineChars[idx]
                if ch == "\\" && idx + 1 < lineChars.count {
                    codeSlice.append(ch)
                    codeSlice.append(lineChars[idx + 1])
                    idx += 2
                    continue
                }
                if ch == "%" {
                    break
                }
                codeSlice.append(ch)
                idx += 1
            }
            if !codeSlice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    /// One-line notice printed by `verify-citations` when `--offline` or `--demo` skips online lookups.
    public static func noOnlineLookupNotice(_ lang: ScholarLanguage, isDemo: Bool = false) -> String {
        if isDemo {
            return lang.L(
                "Note: --demo uses built-in sample data and skips online registry lookups; identifiers are checked for syntax and the incomplete built-in retraction hint list only.",
                "说明：--demo 使用内置示例数据且不向外部注册库发网络请求，仅检查标识符格式与不完整的内置撤稿名单。"
            )
        }
        return lang.L(
            "Note: --offline skips online registry lookups; identifiers are checked for syntax and the incomplete built-in retraction hint list only.",
            "说明：已指定 --offline，本次不向外部注册库发网络请求，仅检查标识符格式与不完整的内置撤稿名单。"
        )
    }

    private static func incompleteUnverifiedSummaryLine(
        audit: CitationFirewallAuditReport,
        lang: ScholarLanguage
    ) -> String {
        let sortedPairs = audit.unverifiedByReason.keys.sorted().map { key in
            "\(key)=\(audit.unverifiedByReason[key] ?? 0)"
        }
        let reasonSummary = sortedPairs.isEmpty
            ? "offline=\(audit.unverifiedCount)"
            : sortedPairs.joined(separator: ", ")
        let entryNoun = audit.unverifiedCount == 1 ? "entry" : "entries"
        return lang.L(
            "\(audit.unverifiedCount) \(entryNoun) could not be verified, reasons: \(reasonSummary); results are incomplete.",
            "\(audit.unverifiedCount) 条没查成，原因：\(reasonSummary)；结果不完整。"
        )
    }

    private static func localizedVerdictAuditNote(
        _ verdict: CitationFirewallEntryVerdict,
        lang: ScholarLanguage
    ) -> String {
        guard lang == .zhHans else { return verdict.auditNote }

        let untrustedSuffix: String = {
            if let declared = verdict.auditedEntry.untrustedDeclaredFirewallClass, !declared.isEmpty {
                return " 文件里写着 \(declared)，未采信。"
            }
            return ""
        }()

        switch verdict.firewallClass {
        case .verified:
            if let primary = verdict.sources.first(where: { $0.status == 200 }) ?? verdict.sources.first {
                let dateStr = CitationVerificationFirewall.shortDateLabel(from: primary.fetchedAt)
                let originZH: String
                switch primary.origin {
                case .network: originZH = "网络"
                case .replay: originZH = "回放"
                case .cache: originZH = "缓存"
                }
                var base: String
                if let discoveredDOI = verdict.fields.first(where: {
                    $0.field == "doi" && $0.localValue.isEmpty && !$0.remoteValue.isEmpty
                })?.remoteValue {
                    base = "在 \(primary.source) 查到，\(dateStr) 取得（\(originZH)）；DOI：\(discoveredDOI)。"
                } else {
                    base = "在 \(primary.source) 查到，\(dateStr) 取得（\(originZH)）。"
                }
                if let venueHint = verdict.fields.first(where: {
                    $0.field == "venue" && $0.severity == "advisory"
                }) {
                    base += " 刊名提示：本地 '\(venueHint.localValue)'，\(venueHint.source) '\(venueHint.remoteValue)'（\(CitationAuditWording.venueWordingNotDiscrepancyChineseNotice)）。"
                }
                return base + untrustedSuffix
            }
            return verdict.auditedEntry.localizedFirewallAuditNote(lang)

        case .drift:
            guard !verdict.fields.isEmpty else {
                return verdict.auditedEntry.localizedFirewallAuditNote(lang)
            }
            let parts = verdict.fields.map { f -> String in
                if f.field == "doi", f.localValue.isEmpty, !f.remoteValue.isEmpty, f.severity == "advisory" {
                    return "数据源 \(f.source) 提供 DOI：\(f.remoteValue)"
                }
                let fieldZH: String
                switch f.field {
                case "doi": fieldZH = "DOI"
                case "arxivID": fieldZH = "arXiv编号"
                case "pmid": fieldZH = "PMID"
                case "title": fieldZH = "标题"
                case "firstAuthor": fieldZH = "第一作者"
                case "authorCount": fieldZH = "作者数"
                case "year": fieldZH = "年份"
                case "venue": fieldZH = "刊名"
                default: fieldZH = f.field
                }
                let localLabel = f.localValue.isEmpty ? "缺失" : f.localValue
                let remoteLabel = f.remoteValue.isEmpty ? "无" : f.remoteValue
                if f.field == "year", (f.note ?? "").contains(CitationAuditWording.yearOnlineVsPrintNotice) {
                    return "年份不符（本地：\(localLabel)，\(f.source)：\(remoteLabel)；可能是在线发表年和刊期年的差别）"
                }
                if f.severity == "error" {
                    return "\(fieldZH)错误（本地：\(localLabel)，\(f.source)：\(remoteLabel)）"
                }
                return "\(fieldZH)不符（本地：\(localLabel)，\(f.source)：\(remoteLabel)）"
            }
            return parts.joined(separator: "；") + "。" + untrustedSuffix

        case .notFound:
            let idLabel = verdict.auditedEntry.doi
                ?? verdict.auditedEntry.arxivID
                ?? verdict.auditedEntry.pmid
                ?? verdict.citeKey
            if verdict.reasons.contains("doi_not_registered") {
                return "doi.org 说这个 DOI 没有注册（\(idLabel)）。" + untrustedSuffix
            }
            if verdict.reasons.contains("arxiv_not_found") {
                return "arXiv 说没有这个编号（arXiv:\(idLabel)）。" + untrustedSuffix
            }
            if verdict.reasons.contains("pmid_not_found") {
                return "PubMed 说没有这个编号（PMID:\(idLabel)）。" + untrustedSuffix
            }
            if !verdict.sources.isEmpty {
                let sourceNames = verdict.sources.map(\.source).joined(separator: "、")
                return "\(sourceNames) 报告标识符 '\(idLabel)' 不存在。" + untrustedSuffix
            }
            return verdict.auditedEntry.localizedFirewallAuditNote(lang)

        case .retracted:
            if verdict.reasons.contains("retracted_builtin_list") {
                return verdict.auditedEntry.localizedFirewallAuditNote(lang)
            }
            let upstreamRetractionFindings = verdict.findings.filter {
                $0.code == .blockedRetractedWork
                    && $0.severity == .criticalBlock
                    && !$0.detail.contains(CitationAuditWording.builtInRetractionListNotice)
            }
            if !upstreamRetractionFindings.isEmpty {
                let clauses = upstreamRetractionFindings.map { finding -> String in
                    let src: String
                    if finding.detail.hasPrefix("Crossref") {
                        src = "Crossref"
                    } else if finding.detail.hasPrefix("OpenAlex") {
                        src = "OpenAlex"
                    } else if finding.detail.hasPrefix("arXiv") {
                        src = "arXiv"
                    } else if finding.detail.hasPrefix("PubMed") {
                        src = "PubMed"
                    } else {
                        src = verdict.sources.first(where: { $0.status == 200 })?.source ?? "注册库"
                    }
                    let fld = finding.field.isEmpty ? "retraction" : finding.field
                    return "\(src) 标明该文献已撤稿（撤稿字段：\(fld)）"
                }
                return clauses.joined(separator: "；") + "。" + untrustedSuffix
            }
            let primarySource = verdict.sources.first(where: { $0.status == 200 })?.source
                ?? verdict.sources.first?.source
                ?? "注册库"
            let fieldDetail: String = {
                if verdict.auditNote.contains("update-to") { return "update-to" }
                if verdict.auditNote.contains("updated-by") { return "updated-by" }
                if verdict.auditNote.contains("relation.is-retracted-by") { return "relation.is-retracted-by" }
                if verdict.auditNote.contains("is_retracted") { return "is_retracted" }
                if verdict.auditNote.contains("pubtype") { return "pubtype (Retracted Publication)" }
                if verdict.auditNote.lowercased().contains("withdrawn") { return "arXiv withdrawn/retracted" }
                return "retraction"
            }()
            return "\(primarySource) 标明该文献已撤稿（撤稿字段：\(fieldDetail)）。" + untrustedSuffix

        case .unverified:
            if verdict.reasons.isEmpty || verdict.reasons == [CitationUnverifiedReasonCode.offline.rawValue] {
                return verdict.auditedEntry.localizedFirewallAuditNote(lang)
            }
            if verdict.reasons == [CitationUnverifiedReasonCode.noMatchInSearch.rawValue] {
                return CitationAuditWording.noMatchInSearchChineseNotice + untrustedSuffix
            }
            let reasonLabels = verdict.reasons.map { code -> String in
                switch code {
                case CitationUnverifiedReasonCode.transportError.rawValue: return "网络连接失败"
                case CitationUnverifiedReasonCode.timeout.rawValue: return "请求超时"
                case CitationUnverifiedReasonCode.rateLimited.rawValue: return "触发限速 (HTTP 429)"
                case CitationUnverifiedReasonCode.serverError.rawValue: return "服务端错误 (HTTP 5xx)"
                case CitationUnverifiedReasonCode.budgetExhausted.rawValue: return "请求配额已用尽"
                case CitationUnverifiedReasonCode.unparseable.rawValue: return "响应解析失败"
                case CitationUnverifiedReasonCode.ambiguous.rawValue: return "检索结果存在歧义"
                case CitationUnverifiedReasonCode.registeredNoMetadata.rawValue: return "doi.org 表明该 DOI 已注册，但两个元数据源里都没有"
                case CitationUnverifiedReasonCode.noMatchInSearch.rawValue: return "两个数据源均未找到匹配记录"
                case CitationUnverifiedReasonCode.parseError.rawValue:
                    if let info = verdict.auditedEntry.parseErrorInfo {
                        return "BibTeX 条目解析失败（始于第 \(info.startLine) 行，出错于第 \(info.line) 行）"
                    }
                    return "BibTeX 条目解析失败"
                default: return code
                }
            }
            return "核查未完成（原因：\(reasonLabels.joined(separator: "、"))）。" + untrustedSuffix
        }
    }

    private func formatOutline(
        _ outline: [DocumentOutlineEntry],
        asJSON: Bool,
        isDemo: Bool,
        lang: ScholarLanguage = .en
    ) throws -> String {
        if asJSON {
            if isDemo {
                fputs(
                    lang.L(
                        "[DEMO] Using built-in sample unverified dataset\n",
                        "[DEMO / 演示数据] 当前使用内置未核查示例数据集\n"
                    ),
                    stderr
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(outline)
            return String(decoding: data, as: UTF8.self)
        }
        let body = outline.map { entry in
            let indent = String(repeating: "  ", count: max(0, entry.level - 1))
            let unit = lang.L("words", "词")
            return "\(indent)\(entry.numberPrefix) \(entry.title) [\(entry.filePath):\(entry.line) · \(entry.wordCountInSection) \(unit)]"
        }.joined(separator: "\n")
        let header = isDemo ? lang.L("[DEMO] Sample unverified dataset\n", "[DEMO / 演示数据] 示例未核查数据集\n") : ""
        return header + body
    }

    private static func replayBannerLine(usesCache: Bool, lang: ScholarLanguage) -> String {
        if usesCache {
            return lang.L(
                "[REPLAY] Recorded registry replay (no live network requests; reading/writing SCHOLAR_CACHE_DIR cache)",
                "[REPLAY / 录制回放] 使用本地录制响应回放（不发网络请求，读写 SCHOLAR_CACHE_DIR 缓存）"
            )
        }
        return lang.L(
            "[REPLAY] Recorded registry replay (no live network requests, no cache)",
            "[REPLAY / 录制回放] 使用本地录制响应回放（不发网络请求、不读写缓存）"
        )
    }

    private func formatDiagnostics(
        _ report: WorkspaceDiagnosticsReport,
        asJSON: Bool,
        isDemo: Bool,
        isReplay: Bool = false,
        replayUsesCache: Bool = false,
        noVerify: Bool = false,
        noVerifyCitedKeyCount: Int = 0,
        lang: ScholarLanguage = .en
    ) throws -> String {
        if asJSON {
            if isDemo {
                fputs(
                    lang.L(
                        "[DEMO] Using built-in sample unverified dataset\n",
                        "[DEMO / 演示数据] 当前使用内置未核查示例数据集\n"
                    ),
                    stderr
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(report.diagnostics)
            return String(decoding: data, as: UTF8.self)
        }
        var headerLines: [String] = []
        if isDemo {
            headerLines.append(lang.L("[DEMO] Sample unverified dataset", "[DEMO / 演示数据] 示例未核查数据集"))
        }
        if isReplay {
            headerLines.append(Self.replayBannerLine(usesCache: replayUsesCache, lang: lang))
        }
        let body: String
        if report.diagnostics.isEmpty {
            body = lang.L("0 diagnostics", "0 条诊断")
        } else {
            body = report.diagnostics.map { diag in
                "[\(diag.severity.rawValue)] \(diag.code) \(diag.span.filePath):\(diag.span.start.line):\(diag.span.start.column) - \(diag.localizedMessage(lang))"
            }.joined(separator: "\n")
        }
        var outLines = headerLines + [body]
        if noVerify {
            let keyNoun = noVerifyCitedKeyCount == 1 ? "key" : "keys"
            outLines.append(
                lang.L(
                    "Citation verification: skipped (--no-verify; citations not verified, \(noVerifyCitedKeyCount) cited \(keyNoun))",
                    "引用核查：未核查引用（已指定 --no-verify，共 \(noVerifyCitedKeyCount) 个引用键）"
                )
            )
        }
        return outLines.joined(separator: "\n")
    }

    private func makeLSPService(
        from db: ScholarProjectDatabase,
        bibliographySourcePath: String = "project.scholarproj"
    ) throws -> ScholarLSPWorkspaceService {
        var files: [String: String] = [:]
        for rec in try db.listManuscriptFiles() {
            files[rec.path] = rec.content
        }
        let entries = try db.listBibliographyEntries()
        let primary = (try? db.primaryManuscriptFile()) ?? "main.tex"
        let lsp = ScholarLSPWorkspaceService(
            rootFilePath: primary,
            files: files,
            bibliography: entries,
            clock: registryClock
        )
        let bibSources: [DiagnosticsBibliographySource]
        var entrySourceByKey: [String: String] = [:]
        if entries.isEmpty {
            bibSources = []
        } else {
            bibSources = [
                DiagnosticsBibliographySource(
                    kind: "bib",
                    path: bibliographySourcePath,
                    entries: Set(entries.map(\.citeKey)).count
                )
            ]
            for entry in entries {
                entrySourceByKey[entry.citeKey] = bibliographySourcePath
            }
        }
        lsp.configureSourceMetadata(
            bibliographySources: bibSources,
            entrySourceByKey: entrySourceByKey
        )
        return lsp
    }

    public static let helpBanner = localizedHelpBanner(.en)

    public static func localizedHelpBanner(_ lang: ScholarLanguage) -> String {
        switch lang {
        case .en:
            return """
            ScholarOS 1.3.0 - Bilingual (中文/EN) LaTeX/BibTeX Analysis, CSL Formatting & Citation Audit CLI
            Global Options:
              --lang zh|en                                           Select output / UI language (or set SCHOLAROS_LANG=zh|en)

            Direct File Commands:
              outline <paper.tex> [--json]                           Print numbered section/subsection outline
              diagnostics <paper.tex> [--bib <refs.bib>] [--offline | --registry-replay <dir> | --no-verify] [--no-cache] [--json]
                                                                     Run LaTeX CST, cross-reference & online cited-entry checks (exit 0/1/3/2; --no-verify structure only, exit 0/1/2)
              verify-citations <refs.bib> [options]                  Verify citations online (exit 0 all VERIFIED, 1 DRIFT/NOT_FOUND/RETRACTED, 3 UNVERIFIED, 2 error)
                --offline                                            Check identifier syntax & built-in retraction hints without network or cache access
                --no-cache                                           Skip reading and writing the SQLite response cache for this run
                --registry-record <dir>                              Query live registries (using cache unless --no-cache) and record network responses + SHA-256 manifest into <dir>
                --registry-record-limit <N>                          Max new HTTP requests to send in this --registry-record run (positive integer, default: 80)
                --registry-replay <dir>                              Replay recorded responses from <dir> (no network; uses cache only when SCHOLAR_CACHE_DIR is set)
                --verbose                                            Log one telemetry line per lookup to stderr (source, URL, status, elapsed, origin)
                --json                                               Emit structured JSON audit report
              cache clear                                            Remove registry.sqlite (-wal/-shm) in SCHOLAR_CACHE_DIR or ~/Library/Caches/ScholarOS
              format-bib <refs.bib> [--style apa|ieee] [--json]      Format BibTeX entries in APA 7th or IEEE style

            Project Bundle & Demo Commands (require --project <dir.scholarproj> or explicit --demo):
              init [--project <dir.scholarproj>] [--seed-demo]       Initialize .scholarproj SQLite WAL bundle
              status --project <dir.scholarproj> | --demo            Print JSON project statistics
              cite <citeKey> [--bib <refs.bib> | --project <dir.scholarproj> | --demo] [--offline | --registry-replay <dir>] [--no-cache]
                                                                     Verify single citation online/replay & format APA 7th snippet if VERIFIED
              prisma-stats --project <dir.scholarproj> | --demo      Print PRISMA 2020 & nominal Cohen's kappa JSON
              prisma-svg [<out.svg>] --project <dir> | --demo        Export PRISMA 2020 flow diagram SVG
              citation-graph --project <dir.scholarproj> | --demo    Build citation network summary
              track-changes --project <dir.scholarproj> | --demo     Diff manuscript snapshots with Myers O(ND) engine
              audit-editorial --project <dir.scholarproj> | --demo   Run JavaScriptCore editorial plugins
              export-bundle [<dir>] --project <dir> | --demo         Export flattened submission bundle
              export-html [<out.html>] --project <dir> | --demo      Export bilingual HTML audit dossier
              mcp [--project <dir.scholarproj>] [--demo] [--offline | --registry-replay <dir>] [--no-cache]
                                                                     Start JSON-RPC 2.0 MCP server on stdio
              --demo                                                 Launch macOS GUI in explicit DEMO mode
              --export-screenshots <output-dir> [--lang zh|en]       Render 2x Retina screenshots & demo HTML dossier
            """
        case .zhHans:
            return """
            ScholarOS 1.3.0 - 中英双语 (中文/EN) LaTeX/BibTeX 语法分析、CSL 引文格式化与引文核查命令行工具
            全局选项：
              --lang zh|en                                           指定命令行 / 界面语言（或设置环境变量 SCHOLAROS_LANG=zh|en）

            单文件直读命令：
              outline <paper.tex> [--json]                           提取 LaTeX 章节与子章节编号大纲
              diagnostics <paper.tex> [--bib <refs.bib>] [--offline | --registry-replay <目录> | --no-verify] [--no-cache] [--json]
                                                                     执行 LaTeX 语法树、交叉引用与被引用条目核查诊断（退出码 0/1/3/2；--no-verify 仅做结构检查，退出码 0/1/2）
              verify-citations <refs.bib> [选项]                     默认联网核查参考文献（退出码：全 VERIFIED 为 0，含 DRIFT/NOT_FOUND/RETRACTED 为 1，仅余 UNVERIFIED 为 3，错误为 2）
                --offline                                            仅检查标识符语法与内置撤稿名单，不发任何网络请求且不读写缓存
                --no-cache                                           本次运行不读取也不写入 SQLite 响应缓存
                --registry-record <目录>                             联网查询公开注册库（默认读写缓存）并将发出的响应与 SHA-256 清单录制到 <目录>
                --registry-record-limit <N>                          本次 --registry-record 运行最多新发出的请求数（正整数，默认 80）
                --registry-replay <目录>                             从 <目录> 离线回放录制响应（不发网络请求；仅显式设置 SCHOLAR_CACHE_DIR 时读写该缓存）
                --verbose                                            每查一次往标准错误输出一行（数据源、地址、状态码、耗时、来源）
                --json                                               输出结构化 JSON 核查报告
              cache clear                                            删除当前生效缓存目录（SCHOLAR_CACHE_DIR 或 ~/Library/Caches/ScholarOS）下的 registry.sqlite
              format-bib <refs.bib> [--style apa|ieee] [--json]      按 APA 7th 或 IEEE 格式输出参考文献列表

            工程包与演示命令（必须显式指定 --project <dir.scholarproj> 或 --demo）：
              init [--project <dir.scholarproj>] [--seed-demo]       初始化 .scholarproj SQLite WAL 工程包
              status --project <dir.scholarproj> | --demo            输出工程统计 JSON
              cite <citeKey> [--bib <refs.bib> | --project <dir.scholarproj> | --demo] [--offline | --registry-replay <目录>] [--no-cache]
                                                                     核查单条引文（默认联网），仅在 VERIFIED 时输出 APA 7th 片段
              prisma-stats --project <dir.scholarproj> | --demo      输出 PRISMA 2020 与多分类 Cohen's kappa JSON
              prisma-svg [<out.svg>] --project <dir> | --demo        导出 PRISMA 2020 矢量流程图 SVG
              citation-graph --project <dir.scholarproj> | --demo    输出引文网络摘要
              track-changes --project <dir.scholarproj> | --demo     运行 Myers 词级快照差异对比
              audit-editorial --project <dir.scholarproj> | --demo   运行 JavaScriptCore 审稿插件
              export-bundle [<dir>] --project <dir> | --demo         导出展平的投稿归档目录
              export-html [<out.html>] --project <dir> | --demo      导出中英双语 HTML 审计简报
              mcp [--project <dir.scholarproj>] [--demo] [--offline | --registry-replay <目录>] [--no-cache]
                                                                     在标准输入输出启动 JSON-RPC 2.0 MCP 服务端
              --demo                                                 以显式演示模式 (DEMO) 启动 macOS 桌面窗口
              --export-screenshots <output-dir> [--lang zh|en]       渲染 2x Retina 演示截图与双语演示 HTML 简报
            """
        }
    }
}
