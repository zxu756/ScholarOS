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
    public let exitCode: Int32

    public init(stdout: String, exitCode: Int32 = 0) {
        self.stdout = stdout
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

private struct ReplayAuditReportEnvelope: Encodable {
    let mode: String = "REPLAY"
    let replay: Bool = true
    let report: CitationFirewallAuditReport

    private enum ReplayKeys: String, CodingKey {
        case mode
        case replay
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ReplayKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(replay, forKey: .replay)
        try report.encode(to: encoder)
    }
}

public struct ScholarCLIRunner: Sendable {
    public let registryTransport: any CitationRegistrySession

    public init(
        registryTransport: any CitationRegistrySession = LiveURLSessionRegistryClient(
            capturedHeaderNames: LiveURLSessionRegistryClient.recordingCapturedHeaderNames
        )
    ) {
        self.registryTransport = registryTransport
    }

    public func execute(arguments: [String]) async throws -> String {
        try await run(arguments: arguments).stdout
    }

    public func runWithExitStatus(arguments: [String]) async -> CLIProcessResult {
        let cliLang = (try? resolveCLILanguage(arguments: arguments))
            ?? ProcessInfo.processInfo.environment["SCHOLAROS_LANG"].flatMap(ScholarLanguage.parse)
            ?? .en
        do {
            let output = try await run(arguments: arguments)
            return CLIProcessResult(stdout: output.stdout, stderr: "", exitCode: output.exitCode)
        } catch let error as ScholarOSError {
            let desc: String
            switch error {
            case .invalidCLIArguments(let detail) where cliLang == .zhHans:
                desc = "命令行参数错误：\(detail)"
            case .fileNotFound(let path) where cliLang == .zhHans:
                desc = "未找到文件或工程路径：\(path)"
            default:
                desc = error.localizedDescription
            }
            return CLIProcessResult(
                stdout: "",
                stderr: "[\(error.errorCodeIdentifier)] \(desc)",
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
                    "ScholarOS 1.2.0 (macOS arm64 · LaTeX/BibTeX Parser, CSL Formatter & Citation Audit · 中文/EN)",
                    "ScholarOS 1.2.0 (macOS arm64 · LaTeX/BibTeX 解析、CSL 引文排版与离线引文核查 · 中文/EN)"
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
                let lsp = try makeLSPServiceFromDirectManuscript(path: fileArg, explicitBibPath: nil)
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
                valueFlags: ["--project", "--bib"],
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
                let lsp = try makeLSPServiceFromDirectManuscript(
                    path: fileArg,
                    explicitBibPath: parsed.values["--bib"]
                )
                return CLIExecutionOutput(
                    stdout: try formatDiagnostics(lsp.diagnosticsReport(), asJSON: emitJSON, isDemo: false, lang: lang),
                    exitCode: 0
                )
            }
            let opened = try openReadDatabase(
                parsed: parsed,
                usage: lang.L(
                    "Usage: scholaros diagnostics <paper.tex> [--bib <refs.bib>] [--json] | --project <dir.scholarproj> | --demo",
                    "用法：scholaros diagnostics <paper.tex> [--bib <refs.bib>] [--json] | --project <dir.scholarproj> | --demo"
                ),
                lang: lang
            )
            defer { opened.db.close() }
            let lsp = try makeLSPService(from: opened.db)
            return CLIExecutionOutput(
                stdout: try formatDiagnostics(lsp.diagnosticsReport(), asJSON: emitJSON, isDemo: opened.isDemo, lang: lang),
                exitCode: 0
            )

        case "verify-citations":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project", "--registry-record", "--registry-replay"],
                boolFlags: ["--demo", "--offline", "--json", "--strict"],
                maxPositionals: 1,
                lang: lang
            )
            let emitJSON = parsed.bools.contains("--json")
            let recordDir = parsed.values["--registry-record"]?.trimmingCharacters(in: .whitespacesAndNewlines)
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
            if parsed.bools.contains("--offline") && (recordDir != nil || replayDir != nil) {
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

            let entries: [BibliographyEntry]
            let isDemo: Bool

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
                entries = try BibTeXCodec().parse(rawBib)
                isDemo = false
            } else {
                let opened = try openReadDatabase(
                    parsed: parsed,
                    usage: lang.L(
                        "Usage: scholaros verify-citations <refs.bib> [--offline | --registry-record <dir> | --registry-replay <dir>] [--json] | --project <dir.scholarproj> | --demo",
                        "用法：scholaros verify-citations <refs.bib> [--offline | --registry-record <目录> | --registry-replay <目录>] [--json] | --project <dir.scholarproj> | --demo"
                    ),
                    lang: lang
                )
                defer { opened.db.close() }
                entries = try opened.db.listBibliographyEntries()
                isDemo = opened.isDemo
            }

            let firewall = CitationVerificationFirewall()
            let audit: CitationFirewallAuditReport
            let isReplayMode: Bool
            let performedRegistryLookup: Bool

            if let recordDir {
                let recordingSession = try RegistryRecordingSession(
                    directoryURL: URL(fileURLWithPath: recordDir),
                    transport: registryTransport
                )
                var verdicts: [CitationFirewallEntryVerdict] = []
                verdicts.reserveCapacity(entries.count)
                for entry in entries {
                    let verdict = await firewall.verifyAgainstPublicRegistries(
                        entry: entry,
                        session: recordingSession
                    )
                    try await recordingSession.throwIfFailed()
                    verdicts.append(verdict)
                }
                _ = try await recordingSession.finalize()
                audit = firewall.summarizeVerdicts(verdicts)
                isReplayMode = false
                performedRegistryLookup = true
            } else if let replayDir {
                let replaySession = try RegistryReplaySession(
                    directoryURL: URL(fileURLWithPath: replayDir)
                )
                var verdicts: [CitationFirewallEntryVerdict] = []
                verdicts.reserveCapacity(entries.count)
                for entry in entries {
                    let verdict = await firewall.verifyAgainstPublicRegistries(
                        entry: entry,
                        session: replaySession
                    )
                    try await replaySession.throwIfFailed()
                    verdicts.append(verdict)
                }
                audit = firewall.summarizeVerdicts(verdicts)
                isReplayMode = true
                performedRegistryLookup = true
            } else {
                audit = firewall.auditLibrary(entries)
                isReplayMode = false
                performedRegistryLookup = false
            }

            let allVerified = audit.totalEvaluated > 0 && audit.verifiedCount == audit.totalEvaluated
            let exitCode: Int32 = allVerified ? 0 : 1

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
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data: Data
                if isReplayMode {
                    data = try encoder.encode(ReplayAuditReportEnvelope(report: audit))
                } else {
                    data = try encoder.encode(audit)
                }
                return CLIExecutionOutput(stdout: String(decoding: data, as: UTF8.self), exitCode: exitCode)
            }

            var lines: [String] = []
            if isDemo {
                lines.append(lang.L("[DEMO] Sample unverified dataset", "[DEMO / 演示数据] 示例未核查数据集"))
            }
            if isReplayMode {
                lines.append(
                    lang.L(
                        "[REPLAY] Recorded registry replay (no live network requests, no cache)",
                        "[REPLAY / 录制回放] 使用本地录制响应回放（不发网络请求、不读写缓存）"
                    )
                )
            }
            lines.append(
                "Evaluated=\(audit.totalEvaluated) Verified=\(audit.verifiedCount) Drift=\(audit.driftCount) NotFound=\(audit.notFoundCount) Retracted=\(audit.retractedCount) Unverified=\(audit.unverifiedCount)"
            )
            if !performedRegistryLookup {
                // Without --registry-record or --registry-replay, this command performs no online lookups yet.
                lines.append(Self.noOnlineLookupNotice(lang))
            }
            for verdict in audit.verdicts {
                // The class is printed once, here; the note's own leading "[CLASS] " tag is dropped.
                let note = CitationAuditWording.strippingLeadingClassTag(
                    Self.localizedVerdictAuditNote(verdict, lang: lang)
                )
                lines.append("[\(verdict.firewallClass.rawValue)] \(verdict.citeKey): \(note)")
            }
            return CLIExecutionOutput(stdout: lines.joined(separator: "\n"), exitCode: exitCode)

        case "cite":
            let parsed = try parseArgs(
                rest,
                subcommand: subcommand,
                valueFlags: ["--project"],
                boolFlags: ["--demo"],
                maxPositionals: 1
            )
            guard let citeKey = parsed.positionals.first else {
                throw ScholarOSError.invalidCLIArguments(
                    "Usage: scholaros cite <citeKey> --project <dir.scholarproj> | --demo"
                )
            }
            let opened = try openReadDatabase(
                parsed: parsed,
                usage: "Usage: scholaros cite <citeKey> --project <dir.scholarproj> | --demo"
            )
            defer { opened.db.close() }
            let verified = try opened.db.validateCitationKeyForInsertion(citeKey)
            let formatted = CSLCitationFormatterEngine().formatEntry(verified, style: .apa7)
            let prefix = opened.isDemo ? "[DEMO] " : ""
            return CLIExecutionOutput(
                stdout: "\(prefix)\\cite{\(verified.citeKey)} -> \(formatted.bibliographyPlainText)",
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
            if let bibPath = parsed.positionals.first {
                if parsed.values["--project"] != nil || parsed.bools.contains("--demo") {
                    throw ScholarOSError.invalidCLIArguments(
                        "Cannot combine direct file '\(bibPath)' with --project or --demo."
                    )
                }
                let rawBib = try readRequiredRegularFile(atPath: bibPath)
                entries = try BibTeXCodec().parse(rawBib)
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
                return CLIExecutionOutput(stdout: String(decoding: data, as: UTF8.self), exitCode: 0)
            }

            let header = isDemo ? lang.L("[DEMO] Sample unverified dataset\n", "[DEMO / 演示数据] 示例未核查数据集\n") : ""
            return CLIExecutionOutput(stdout: header + formatted.plainText, exitCode: 0)

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
                valueFlags: ["--project"],
                boolFlags: ["--demo"],
                maxPositionals: 0
            )
            let projectPath = parsed.values["--project"]
            if let projectPath, !FileManager.default.fileExists(atPath: projectPath) {
                throw ScholarOSError.fileNotFound(projectPath)
            }
            let server = ScholarMCPServer(
                defaultProjectBundlePath: projectPath,
                allowDemoMode: parsed.bools.contains("--demo")
            )
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
        if let envRaw = ProcessInfo.processInfo.environment["SCHOLAROS_LANG"],
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
                    guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else {
                        throw ScholarOSError.invalidCLIArguments(
                            lang.L(
                                "Missing value for option '\(tok)' in '\(subcommand)'.",
                                "子命令 '\(subcommand)' 的选项 '\(tok)' 缺少参数值。"
                            )
                        )
                    }
                    values[tok] = args[i + 1]
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
                seedDemoIfEmpty: false
            )
            return (db, false)
        }

        if useDemo {
            let db = try ScholarProjectDatabase.inMemory(seedDemo: true)
            if let currentTitle = try? db.projectTitle(), !currentTitle.hasPrefix("[DEMO]") {
                try? db.setProjectTitle("[DEMO] \(currentTitle)")
            }
            return (db, true)
        }

        throw ScholarOSError.invalidCLIArguments(usage)
    }

    private func readRequiredRegularFile(atPath path: String) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw ScholarOSError.fileNotFound(path)
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - Direct `.tex` / `.bib` Workspace Loader

    private func makeLSPServiceFromDirectManuscript(
        path: String,
        explicitBibPath: String?
    ) throws -> ScholarLSPWorkspaceService {
        let rootContent = try readRequiredRegularFile(atPath: path)
        let rootURL = URL(fileURLWithPath: path).standardizedFileURL
        let baseDir = rootURL.deletingLastPathComponent()
        let rootKey = rootURL.lastPathComponent

        var files: [String: String] = [rootKey: rootContent]
        var visited = Set<String>([rootURL.path])
        collectRelativeIncludes(in: rootContent, baseDir: baseDir, into: &files, visited: &visited)

        var entries: [BibliographyEntry] = []
        if let explicitBibPath {
            let rawBib = try readRequiredRegularFile(atPath: explicitBibPath)
            entries = try BibTeXCodec().parse(rawBib)
        } else {
            let bibCandidates = extractBibliographyPaths(from: rootContent, baseDir: baseDir)
            for bibURL in bibCandidates {
                if let rawBib = try? String(contentsOf: bibURL, encoding: .utf8),
                   let parsed = try? BibTeXCodec().parse(rawBib)
                {
                    entries.append(contentsOf: parsed)
                }
            }
        }

        return ScholarLSPWorkspaceService(
            rootFilePath: rootKey,
            files: files,
            bibliography: entries
        )
    }

    private func collectRelativeIncludes(
        in content: String,
        baseDir: URL,
        into files: inout [String: String],
        visited: inout Set<String>
    ) {
        guard let regex = try? NSRegularExpression(pattern: #"\\(?:input|include)\{([^}]+)\}"#) else {
            return
        }
        let ns = content as NSString
        for match in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
            var rel = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rel.isEmpty else { continue }
            if !rel.lowercased().hasSuffix(".tex") {
                rel += ".tex"
            }
            let targetURL = baseDir.appendingPathComponent(rel).standardizedFileURL
            guard !visited.contains(targetURL.path),
                  let subContent = try? String(contentsOf: targetURL, encoding: .utf8)
            else { continue }
            visited.insert(targetURL.path)
            files[rel] = subContent
            collectRelativeIncludes(in: subContent, baseDir: baseDir, into: &files, visited: &visited)
        }
    }

    private func extractBibliographyPaths(from content: String, baseDir: URL) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"\\(?:bibliography|addbibresource)\{([^}]+)\}"#) else {
            return []
        }
        let ns = content as NSString
        var urls: [URL] = []
        for match in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
            let rawList = ns.substring(with: match.range(at: 1))
            for item in rawList.split(separator: ",") {
                var rel = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rel.isEmpty else { continue }
                if !rel.lowercased().hasSuffix(".bib") {
                    rel += ".bib"
                }
                let candidate = baseDir.appendingPathComponent(rel).standardizedFileURL
                if FileManager.default.fileExists(atPath: candidate.path) {
                    urls.append(candidate)
                }
            }
        }
        return urls
    }

    /// One-line statement printed by `verify-citations`: this version performs no online lookups.
    public static func noOnlineLookupNotice(_ lang: ScholarLanguage) -> String {
        lang.L(
            "Note: this version performs no online registry lookups (online verification is planned for M1); identifiers are checked for syntax only.",
            "说明：本版本不联网核查（联网核查排在 M1），仅检查标识符格式。"
        )
    }

    private static func localizedVerdictAuditNote(
        _ verdict: CitationFirewallEntryVerdict,
        lang: ScholarLanguage
    ) -> String {
        guard lang == .zhHans else { return verdict.auditNote }
        return verdict.auditedEntry.localizedFirewallAuditNote(lang)
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

    private func formatDiagnostics(
        _ report: WorkspaceDiagnosticsReport,
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
            let data = try encoder.encode(report.diagnostics)
            return String(decoding: data, as: UTF8.self)
        }
        let prefix = isDemo ? lang.L("[DEMO] Sample unverified dataset\n", "[DEMO / 演示数据] 示例未核查数据集\n") : ""
        if report.diagnostics.isEmpty {
            return prefix + lang.L("0 diagnostics", "0 条诊断")
        }
        let body = report.diagnostics.map { diag in
            "[\(diag.severity.rawValue)] \(diag.code) \(diag.span.filePath):\(diag.span.start.line):\(diag.span.start.column) - \(diag.localizedMessage(lang))"
        }.joined(separator: "\n")
        return prefix + body
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

    public static let helpBanner = localizedHelpBanner(.en)

    public static func localizedHelpBanner(_ lang: ScholarLanguage) -> String {
        switch lang {
        case .en:
            return """
            ScholarOS 1.2.0 - Bilingual (中文/EN) LaTeX/BibTeX Analysis, CSL Formatting & Citation Audit CLI
            Global Options:
              --lang zh|en                                           Select output / UI language (or set SCHOLAROS_LANG=zh|en)

            Direct File Commands:
              outline <paper.tex> [--json]                           Print numbered section/subsection outline
              diagnostics <paper.tex> [--bib <refs.bib>] [--json]    Run LaTeX CST, cross-reference & citation lints
              verify-citations <refs.bib> [options]                  Verify citations (exits 1 if any entry is not VERIFIED, 2 on error)
                --offline                                            Check identifier syntax & built-in retraction hints without network lookups
                --registry-record <dir>                              Query live registries and record raw responses + SHA-256 manifest into <dir>
                --registry-replay <dir>                              Replay recorded responses from <dir> with no network or cache access (marks REPLAY)
                --json                                               Emit structured JSON audit report
              format-bib <refs.bib> [--style apa|ieee] [--json]      Format BibTeX entries in APA 7th or IEEE style

            Project Bundle & Demo Commands (require --project <dir.scholarproj> or explicit --demo):
              init [--project <dir.scholarproj>] [--seed-demo]       Initialize .scholarproj SQLite WAL bundle
              status --project <dir.scholarproj> | --demo            Print JSON project statistics
              cite <citeKey> --project <dir.scholarproj> | --demo    Check citation status & format APA 7th snippet
              prisma-stats --project <dir.scholarproj> | --demo      Print PRISMA 2020 & nominal Cohen's kappa JSON
              prisma-svg [<out.svg>] --project <dir> | --demo        Export PRISMA 2020 flow diagram SVG
              citation-graph --project <dir.scholarproj> | --demo    Build citation network summary
              track-changes --project <dir.scholarproj> | --demo     Diff manuscript snapshots with Myers O(ND) engine
              audit-editorial --project <dir.scholarproj> | --demo   Run JavaScriptCore editorial plugins
              export-bundle [<dir>] --project <dir> | --demo         Export flattened submission bundle
              export-html [<out.html>] --project <dir> | --demo      Export bilingual HTML audit dossier
              mcp [--project <dir.scholarproj>] [--demo]             Start JSON-RPC 2.0 MCP server on stdio
              --demo                                                 Launch macOS GUI in explicit DEMO mode
              --export-screenshots <output-dir> [--lang zh|en]       Render 2x Retina screenshots & demo HTML dossier
            """
        case .zhHans:
            return """
            ScholarOS 1.2.0 - 中英双语 (中文/EN) LaTeX/BibTeX 语法分析、CSL 引文格式化与离线引文核查命令行工具
            全局选项：
              --lang zh|en                                           指定命令行 / 界面语言（或设置环境变量 SCHOLAROS_LANG=zh|en）

            单文件直读命令：
              outline <paper.tex> [--json]                           提取 LaTeX 章节与子章节编号大纲
              diagnostics <paper.tex> [--bib <refs.bib>] [--json]    执行 LaTeX 语法树、交叉引用与引文静态诊断
              verify-citations <refs.bib> [选项]                     核查参考文献（任一条目非 VERIFIED 时退出码为 1，参数或回放错误退出码为 2）
                --offline                                            仅检查标识符语法与内置撤稿名单，不联网核查
                --registry-record <目录>                             联网查询公开注册库并将原始响应与 SHA-256 清单录制到 <目录>
                --registry-replay <目录>                             从 <目录> 离线回放录制响应，不发网络请求且不读写缓存（输出带 REPLAY 标记）
                --json                                               输出结构化 JSON 核查报告
              format-bib <refs.bib> [--style apa|ieee] [--json]      按 APA 7th 或 IEEE 格式输出参考文献列表

            工程包与演示命令（必须显式指定 --project <dir.scholarproj> 或 --demo）：
              init [--project <dir.scholarproj>] [--seed-demo]       初始化 .scholarproj SQLite WAL 工程包
              status --project <dir.scholarproj> | --demo            输出工程统计 JSON
              cite <citeKey> --project <dir.scholarproj> | --demo    检查单条引文状态并输出 APA 7th 片段
              prisma-stats --project <dir.scholarproj> | --demo      输出 PRISMA 2020 与多分类 Cohen's kappa JSON
              prisma-svg [<out.svg>] --project <dir> | --demo        导出 PRISMA 2020 矢量流程图 SVG
              citation-graph --project <dir.scholarproj> | --demo    输出引文网络摘要
              track-changes --project <dir.scholarproj> | --demo     运行 Myers 词级快照差异对比
              audit-editorial --project <dir.scholarproj> | --demo   运行 JavaScriptCore 审稿插件
              export-bundle [<dir>] --project <dir> | --demo         导出展平的投稿归档目录
              export-html [<out.html>] --project <dir> | --demo      导出中英双语 HTML 审计简报
              mcp [--project <dir.scholarproj>] [--demo]             在标准输入输出启动 JSON-RPC 2.0 MCP 服务端
              --demo                                                 以显式演示模式 (DEMO) 启动 macOS 桌面窗口
              --export-screenshots <output-dir> [--lang zh|en]       渲染 2x Retina 演示截图与双语演示 HTML 简报
            """
        }
    }
}
