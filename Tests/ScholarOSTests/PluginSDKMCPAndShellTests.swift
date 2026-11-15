import Foundation
import Testing
import ScholarBibAndCSL
import ScholarModels
import ScholarProjectStore
import ScholarPluginSDK
import ScholarCLIAndMCP
import ScholarWorkbenchShell

/// In-memory stand-in for `UserDefaults`, so that tests of language persistence never create a
/// preferences domain on disk. (A temporary `UserDefaults(suiteName:)` followed by
/// `removePersistentDomain(forName:)` still leaves one `<suite>.plist` per run in
/// `~/Library/Preferences`; that is how the earlier version of these tests leaked files.)
/// Only the calls `ScholarLocalizer` makes are overridden; nothing is forwarded to `super`.
private final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    init() {
        // The designated initializer needs a suite name; nothing is ever written to that suite
        // because every accessor used by the code under test is overridden below.
        super.init(suiteName: "io.github.zxu756.ScholarOS.tests.in-memory-never-written")!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return storage[defaultName]
    }

    override func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[defaultName] = nil
    }
}

@Suite("Editorial Plugin SDK, Statistical Numerics, CLI/MCP Firewall & Workbench Shell")
struct PluginSDKMCPAndShellTests {

    // MARK: - Helpers

    /// Repository root, derived from this source file's location (Tests/ScholarOSTests/<file>).
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// True when `text` contains CJK ideographs, CJK punctuation, or full-width forms.
    private func containsChineseCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x3000...0x303F).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x4E00...0x9FFF).contains(v)
                || (0xFF00...0xFFEF).contains(v)
        }
    }

    private func makeTempDirectory(prefix: String = "scholaros-cli") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 1. Lanczos lgamma & Lentz Incomplete Beta Exact p-Value Verification

    @Test("ScholarStatisticalDistributions verifies Lanczos lnGamma, lnBeta, and incomplete beta/gamma identities")
    func lanczosLnGammaAndLentzIncompleteBetaIdentities() {
        // Gamma(5) = 4! = 24 -> lnGamma(5) = ln(24)
        #expect(abs(ScholarStatisticalDistributions.lnGamma(5.0) - log(24.0)) < 1e-11)
        // Gamma(0.5) = sqrt(pi) -> lnGamma(0.5) = 0.5 * ln(pi)
        #expect(abs(ScholarStatisticalDistributions.lnGamma(0.5) - (0.5 * log(Double.pi))) < 1e-11)
        // Beta(2, 3) = Gamma(2)Gamma(3)/Gamma(5) = 1 * 2 / 24 = 1/12
        #expect(abs(ScholarStatisticalDistributions.lnBeta(2.0, 3.0) - log(1.0 / 12.0)) < 1e-11)

        // Symmetric incomplete beta: I_{0.5}(a, a) == 0.5 for any a > 0
        #expect(abs(ScholarStatisticalDistributions.regularizedIncompleteBeta(x: 0.5, a: 3.5, b: 3.5) - 0.5) < 1e-11)
        // Uniform Beta(1, 1): I_x(1, 1) == x
        #expect(abs(ScholarStatisticalDistributions.regularizedIncompleteBeta(x: 0.37, a: 1.0, b: 1.0) - 0.37) < 1e-11)

        // Complementary incomplete gamma: P(a, x) + Q(a, x) == 1
        let lowerG = ScholarStatisticalDistributions.regularizedLowerIncompleteGamma(a: 2.5, x: 1.8)
        let upperG = ScholarStatisticalDistributions.regularizedUpperIncompleteGamma(a: 2.5, x: 1.8)
        #expect(abs((lowerG + upperG) - 1.0) < 1e-11)
    }

    @Test("Exact two-tailed Student's t, Snedecor's F, Pearson's chi-square, r, and z p-values match critical tables")
    func exactStudentTFChiSquarePearsonRAndZPValues() {
        // Student's t critical value at alpha = 0.05 (two-tailed) for df = 20 is t = 2.085963447
        let pT20 = ScholarStatisticalDistributions.computeTwoTailedTPValue(tStat: 2.085963447, df: 20.0)
        #expect(abs(pT20 - 0.05) < 1e-6)

        // Exact identity: F(1, df) == t(df)^2 must give identical p-value to machine precision!
        let tVal = 2.423
        let pFromT = ScholarStatisticalDistributions.computeTwoTailedTPValue(tStat: tVal, df: 18.0)
        let pFromF = ScholarStatisticalDistributions.computeFPValue(fStat: tVal * tVal, df1: 1.0, df2: 18.0)
        #expect(abs(pFromT - pFromF) < 1e-10)

        // F(2, 27) critical value for p = 0.05 is 3.3541308
        let pF = ScholarStatisticalDistributions.computeFPValue(fStat: 3.3541308, df1: 2.0, df2: 27.0)
        #expect(abs(pF - 0.05) < 1e-5)

        // Chi-square critical values: chi^2(1) = 3.8414588 -> p = 0.05; chi^2(2) = 5.9914645 -> p = 0.05
        let pChi1 = ScholarStatisticalDistributions.computeChiSquarePValue(chiSq: 3.8414588, df: 1.0)
        let pChi2 = ScholarStatisticalDistributions.computeChiSquarePValue(chiSq: 5.9914645, df: 2.0)
        #expect(abs(pChi1 - 0.05) < 1e-5)
        #expect(abs(pChi2 - 0.05) < 1e-5)

        // Pearson r = 0.0 -> p = 1.0; two-tailed z = 1.959964 -> p = 0.05
        #expect(abs(ScholarStatisticalDistributions.computePearsonRPValue(r: 0.0, df: 30.0) - 1.0) < 1e-9)
        #expect(abs(ScholarStatisticalDistributions.computeTwoTailedZPValue(zStat: 1.95996398) - 0.05) < 1e-6)
    }

    // MARK: - 2. Built-In JavaScriptCore Editorial Plugins & Watchdog Safety Guards

    @Test("Overclaiming Rhetoric Detector flags universal absolutes while sparing theorem proofs and % comments")
    func overclaimingRhetoricPluginFlagsAbsolutesAndSparesComments() throws {
        let manuscript = #"""
        \section{Introduction}
        % Internal note: this comment proves universally nothing and must be ignored.
        \begin{theorem}
        Lemma 1 proves universally that every finite DAG admits a topological order.
        \end{theorem}
        In empirical evaluation, our framework eliminates all hallucinations and is 100% immune to drift.
        """#

        let sandbox = EditorialJavaScriptSandbox()
        let result = try sandbox.executePlugin(
            BuiltInEditorialPluginCatalog.overclaimingRhetoricDetector,
            manuscriptSource: manuscript
        )

        #expect(!result.findings.isEmpty)
        // Line 2 (% comment) and Line 4 (inside \begin{theorem}) are spared; Line 6 is flagged!
        #expect(result.findings.allSatisfy { $0.line == 6 })
        #expect(result.findings.contains { $0.suggestedRewrite != nil })
    }

    @Test("Anti-AI Prose Sanitizer flags LLM cliches, negative parallelisms, and provides suggested rewrites")
    func antiAIProseSanitizerFlagsLLMClichesAndProvidesRewrites() throws {
        let manuscript = """
        \\section{Background}
        In this study, we delve into the rich tapestry of autonomous systems that stands as a testament to scaling.
        Our verification kernel is not merely a parser, but rather a foundational paradigm shift.
        """

        let sandbox = EditorialJavaScriptSandbox()
        let result = try sandbox.executePlugin(
            BuiltInEditorialPluginCatalog.antiAIProseSanitizer,
            manuscriptSource: manuscript
        )

        #expect(result.findings.count >= 3)
        #expect(result.findings.contains { $0.matchedExcerpt.lowercased().contains("delve into") })
        #expect(result.findings.contains { $0.matchedExcerpt.lowercased().contains("tapestry") || $0.matchedExcerpt.lowercased().contains("testament") })

        // Verify deterministic rewrite application
        let rewritable = try #require(result.findings.first { $0.suggestedRewrite != nil })
        let rewritten = try #require(EditorialPluginAuditRunner.applySuggestedRewrite(rewritable, to: manuscript))
        #expect(rewritten != manuscript)
    }

    @Test("APA 7th StatCheck plugin catches p-value decision-boundary contradictions, p = 0.000, and |r| > 1")
    func apaStatConsistencyCheckerDetectsStatCheckErrors() throws {
        let manuscript = """
        \\section{Results}
        Group A showed a contradictory effect, t(24) = 0.45, p = .002, alongside exact zero p = 0.000.
        Correlation exceeded mathematical bounds at r(30) = 1.42, p = .01.
        Consistent control comparison was significant, t(20) = 2.09, p = .049.
        """

        let sandbox = EditorialJavaScriptSandbox()
        let result = try sandbox.executePlugin(
            BuiltInEditorialPluginCatalog.apaStatConsistencyChecker,
            manuscriptSource: manuscript
        )

        // Decision-boundary contradiction (t(24)=0.45 has true p ≈ 0.657, reported p=.002) -> SUBMISSION_BLOCKER!
        #expect(result.findings.contains { $0.severity == .submissionBlocker && $0.line == 2 })
        // p = 0.000 -> flagged to report p < .001
        #expect(result.findings.contains { $0.explanation.contains(".001") || $0.matchedExcerpt.contains("0.000") })
        // |r| > 1.0 -> impossible correlation blocker
        #expect(result.findings.contains { $0.line == 3 && $0.severity == .submissionBlocker })
        // Consistent line 4 should NOT trigger a blocker
        #expect(!result.findings.contains { $0.line == 4 && $0.severity == .submissionBlocker })
    }

    @Test("Double-Blind Venue Submission Gate flags author leaks, GitHub identity URLs, unverified citations, and unlabeled floats")
    func doubleBlindVenueSubmissionGateEnforcesAnonymityAndFirewall() throws {
        let manuscript = #"""
        \title{Anonymous Submission Draft}
        \author{Elena Rostova \and Kenji Takahashi}
        \thanks{Supported by NSF Grant CNS-998877.}
        \begin{document}
        \begin{abstract}
        Concise abstract within word budget.
        \end{abstract}
        \section{Experiments}
        Code is released at https://github.com/elenarostova/scholaros and cites \cite{smith2025hallucinated}.
        \begin{figure}[t]
        \caption{System throughput diagram without a label.}
        \end{figure}
        \end{document}
        """#

        let bib = [
            BibliographyEntry(
                citeKey: "smith2025hallucinated",
                title: "Fabricated Paper",
                authors: [BibAuthor(givenName: "J.", familyName: "Smith")],
                year: 2025,
                doi: "10.5555/fake-llm-cite.9999",
                firewallClass: .notFound
            )
        ]

        // 1. Double-blind mode flags \author, \thanks, non-anonymous GitHub URL, blocked citation, and unlabeled figure
        let blindSandbox = EditorialJavaScriptSandbox(
            configuration: EditorialSandboxConfiguration(venueMode: .doubleBlindSubmission)
        )
        let blindResult = try blindSandbox.executePlugin(
            BuiltInEditorialPluginCatalog.venueSubmissionGate,
            manuscriptSource: manuscript,
            bibliography: bib
        )
        #expect(blindResult.findings.contains { $0.category.contains("Double-Blind") || $0.explanation.contains("anonym") })
        #expect(blindResult.findings.contains { $0.matchedExcerpt.contains("github.com") })
        #expect(blindResult.findings.contains { $0.matchedExcerpt.contains("smith2025hallucinated") || $0.explanation.contains("smith2025hallucinated") })
        #expect(blindResult.findings.contains { $0.line >= 10 })

        // 2. Camera-ready mode permits \author disclosure while STILL blocking smith2025hallucinated!
        let cameraSandbox = EditorialJavaScriptSandbox(
            configuration: EditorialSandboxConfiguration(venueMode: .cameraReady)
        )
        let cameraResult = try cameraSandbox.executePlugin(
            BuiltInEditorialPluginCatalog.venueSubmissionGate,
            manuscriptSource: manuscript,
            bibliography: bib
        )
        #expect(!cameraResult.findings.contains { $0.line == 2 && $0.severity == .submissionBlocker })
        #expect(cameraResult.findings.contains { $0.explanation.contains("smith2025hallucinated") || $0.matchedExcerpt.contains("smith2025hallucinated") })
    }

    @Test("JavaScriptCore sandbox catches runaway recursion stack overflow, caps finding floods, bounds console ring, and enforces capabilities")
    func javascriptSandboxWatchdogRecursionFloodAndCapabilitySafety() throws {
        // 1. Runaway unbounded recursion is caught cleanly by JSC stack guard as ScholarOSError.pluginError
        let runawayRecursionPlugin = ScholarPluginManifest(
            id: "runaway-recursion-test",
            name: "Runaway Recursion Test",
            summary: "Triggers unbounded call stack recursion",
            capabilities: [.readManuscriptAST, .emitEditorialFindings],
            isBuiltIn: false,
            scriptSource: """
            function runEditorialPlugin(scholar) {
                function infiniteRecurse(n) { return infiniteRecurse(n + 1); }
                infiniteRecurse(0);
            }
            """
        )
        let sandbox = EditorialJavaScriptSandbox(
            configuration: EditorialSandboxConfiguration(
                consoleRingBufferCapacity: 16,
                maxFindingsPerPlugin: 12,
                strictCapabilityEnforcement: true
            )
        )
        #expect(throws: ScholarOSError.self) {
            _ = try sandbox.executePlugin(runawayRecursionPlugin, manuscriptSource: "\\section{Intro}\nTest.")
        }

        // 2. Runaway finding-emission loop & console spam are strictly bounded by maxFindingsPerPlugin & ring capacity
        let floodPlugin = ScholarPluginManifest(
            id: "bounded-flood-test",
            name: "Bounded Flood Test",
            summary: "Emits 500 findings and 200 console logs",
            capabilities: [.readManuscriptAST, .emitEditorialFindings],
            isBuiltIn: false,
            scriptSource: """
            function runEditorialPlugin(scholar) {
                for (let i = 0; i < 200; i++) {
                    console.log("log-line-" + i);
                }
                for (let j = 0; j < 500; j++) {
                    scholar.emitFinding({
                        severity: "NOTE",
                        category: "Flood",
                        line: 1,
                        matchedExcerpt: "item-" + j,
                        explanation: "Flood test " + j
                    });
                }
            }
            """
        )
        let floodResult = try sandbox.executePlugin(floodPlugin, manuscriptSource: "\\section{Intro}\nTest.")
        #expect(floodResult.findings.count == 12)
        #expect(floodResult.logs.count == 16)
        #expect(floodResult.evictedLogCount == 200 - 16)

        // 3. Unauthorized capability access (calling scholar.getBibliography without .readBibliography) throws pluginError
        let unauthorizedPlugin = ScholarPluginManifest(
            id: "unauthorized-bib-reader",
            name: "Unauthorized Bib Reader",
            summary: "Attempts to read bibliography without declaring capability",
            capabilities: [.readManuscriptAST],
            isBuiltIn: false,
            scriptSource: """
            function runEditorialPlugin(scholar) {
                const bib = scholar.getBibliography();
            }
            """
        )
        #expect(throws: ScholarOSError.self) {
            _ = try sandbox.executePlugin(unauthorizedPlugin, manuscriptSource: "\\section{Intro}\nTest.")
        }
    }

    @Test("EditorialPluginSyntaxValidator and EditorialPluginAuditRunner run all 4 built-in plugins end-to-end")
    func editorialPluginValidatorAndFullRunnerSuite() throws {
        for plugin in BuiltInEditorialPluginCatalog.allPlugins {
            let validation = EditorialPluginSyntaxValidator.validate(plugin)
            #expect(validation.isSyntaxValid)
            #expect(validation.undeclaredCapabilitiesUsed.isEmpty)
            #expect(validation.isReadyToExecute)
        }

        let brokenPlugin = ScholarPluginManifest(
            id: "broken-syntax",
            name: "Broken Syntax",
            summary: "Malformed JS",
            capabilities: [.readManuscriptAST],
            isBuiltIn: false,
            scriptSource: "function runAudit(ctx { return ;;; {{"
        )
        let invalidReport = EditorialPluginSyntaxValidator.validate(brokenPlugin)
        #expect(!invalidReport.isSyntaxValid)
        #expect(!invalidReport.isReadyToExecute)

        let runner = EditorialPluginAuditRunner()
        let summary = try runner.run(
            manuscriptSource: "\\section{Intro}\nWe delve into an approach that eliminates all hallucinations, t(20) = 0.20, p = .001.\n"
        )
        #expect(summary.executedPluginIDs.count == 4)
        #expect(summary.blockerCount >= 1)
        #expect(!summary.canSubmitCameraReady)

        let md = EditorialAuditReportFormatter.renderMarkdown(summary, projectTitle: "Audit Benchmark")
        #expect(md.contains("Audit Benchmark"))
    }

    // MARK: - 3. ScholarCLIRunner Subcommands & Citation Firewall Enforcement

    @Test("ScholarCLIRunner executes version, help, init --seed-demo, status, outline, and diagnostics on temp .scholarproj")
    func cliRunnerLifecycleStatusOutlineAndDiagnostics() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-cli-proj")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundlePath = tempDir.appendingPathComponent("CLIStudy.scholarproj").path
        let cli = ScholarCLIRunner()

        let versionOut = try await cli.execute(arguments: ["version"])
        #expect(versionOut.contains("ScholarOS 1.2.0"))

        let versionWithLangOut = try await cli.execute(arguments: ["--lang", "zh", "version"])
        #expect(versionWithLangOut.contains("ScholarOS 1.2.0"))

        let helpOut = try await cli.execute(arguments: ["--help"])
        #expect(helpOut.contains("verify-citations"))
        #expect(helpOut.contains("--lang zh|en"))

        let initOut = try await cli.execute(arguments: ["init", "--project", bundlePath, "--seed-demo"])
        #expect(initOut.contains("Initialized"))
        #expect(initOut.contains("bib=10"))

        let statusJSON = try await cli.execute(arguments: ["status", "--project", bundlePath])
        let stats = try JSONDecoder().decode(ScholarProjectStats.self, from: Data(statusJSON.utf8))
        #expect(stats.bibliographyCount == 10)
        #expect(stats.schemaVersion == 4)

        let outlineOut = try await cli.execute(arguments: ["outline", "--project", bundlePath])
        #expect(outlineOut.contains("Introduction"))
        #expect(outlineOut.contains("Methodology"))

        let diagOut = try await cli.execute(arguments: ["diagnostics", "--project", bundlePath])
        #expect(!diagOut.isEmpty)
    }

    @Test("ScholarCLIRunner cite subcommand permits explicitly verified records and blocks unverified demo and hallucinated keys with ERR_UNVERIFIED_CITATION")
    func cliRunnerCiteEnforcesVerifiedStatusAndBlocksHallucinations() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-cli-cite")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("CiteStudy.scholarproj")
        let db = try ScholarProjectDatabase(bundleURL: bundleURL, seedDemoIfEmpty: true)
        try db.updateCitationFirewallStatus(
            citeKey: "vaswani2017attention",
            firewallClass: .verified,
            auditNote: "Verified against registry"
        )
        db.close()

        let cli = ScholarCLIRunner()

        // 1. Verified record in project succeeds and formats APA 7th reference
        let allowedOut = try await cli.execute(arguments: ["cite", "vaswani2017attention", "--project", bundleURL.path])
        #expect(allowedOut.contains("\\cite{vaswani2017attention}"))
        #expect(allowedOut.contains("Attention Is All You Need"))

        // 2. Unverified demo entry MUST throw ERR_UNVERIFIED_CITATION
        do {
            _ = try await cli.execute(arguments: ["cite", "vaswani2017attention", "--demo"])
            Issue.record("Expected unverified demo entry to throw ERR_UNVERIFIED_CITATION")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }

        // 3. Blocked hallucinated key MUST throw ScholarOSError with ERR_UNVERIFIED_CITATION
        do {
            _ = try await cli.execute(arguments: ["cite", "smith2025hallucinated", "--project", bundleURL.path])
            Issue.record("Expected CLI cite smith2025hallucinated to throw ERR_UNVERIFIED_CITATION")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }

        // 4. Unknown subcommand throws invalidCLIArguments
        await #expect(throws: ScholarOSError.self) {
            _ = try await cli.execute(arguments: ["nonexistent-subcommand"])
        }
    }

    @Test("ScholarCLIRunner executes explicit --demo verify-citations, format-bib, prisma-stats, citation-graph, track-changes, audit-editorial, export-bundle, and export-html")
    func cliRunnerAnalyticsAndExportSubcommands() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-cli-exports")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cli = ScholarCLIRunner()

        let verifyRun = try await cli.run(arguments: ["verify-citations", "--demo"])
        #expect(verifyRun.exitCode == 1)
        #expect(verifyRun.stdout.contains("[DEMO]"))
        #expect(verifyRun.stdout.contains("Evaluated=10"))
        #expect(verifyRun.stdout.contains("Verified=0"))
        #expect(verifyRun.stdout.contains("NotFound=1"))

        let ieeeBib = try await cli.execute(arguments: ["format-bib", "--demo", "--style", "ieee"])
        #expect(ieeeBib.contains("[DEMO]"))
        #expect(ieeeBib.contains("[1]"))

        let prismaJSON = try await cli.execute(arguments: ["prisma-stats", "--demo"])
        let prismaMetrics = try JSONDecoder().decode(PRISMA2020SummaryMetrics.self, from: Data(prismaJSON.utf8))
        #expect(prismaMetrics.recordsScreenedTitleAbstract == 12)

        let svgPath = tempDir.appendingPathComponent("prisma.svg").path
        let svgMsg = try await cli.execute(arguments: ["prisma-svg", "--demo", "--output", svgPath])
        #expect(svgMsg.contains("[DEMO]"))
        let svgDisk = try String(contentsOfFile: svgPath, encoding: .utf8)
        #expect(svgDisk.contains("<svg"))

        let graphOut = try await cli.execute(arguments: ["citation-graph", "--demo"])
        #expect(graphOut.contains("[DEMO]"))
        #expect(graphOut.contains("Nodes=10"))

        let diffOut = try await cli.execute(arguments: ["track-changes", "--demo"])
        #expect(diffOut.contains("[DEMO]"))
        #expect(diffOut.contains("Diff"))

        let editorialOut = try await cli.execute(arguments: ["audit-editorial", "--demo"])
        #expect(editorialOut.contains("[DEMO]"))
        #expect(editorialOut.contains("overclaiming-rhetoric-detector"))

        let bundleOutDir = tempDir.appendingPathComponent("arxiv-export").path
        let bundleMsg = try await cli.execute(arguments: ["export-bundle", "--demo", "--allow-unverified", "--output", bundleOutDir])
        #expect(bundleMsg.contains("[DEMO]"))
        #expect(bundleMsg.contains("sha256="))

        let htmlPath = tempDir.appendingPathComponent("dossier.html").path
        let htmlMsg = try await cli.execute(arguments: ["export-html", "--demo", "--output", htmlPath])
        #expect(htmlMsg.contains("[DEMO]"))
        let htmlDisk = try String(contentsOfFile: htmlPath, encoding: .utf8)
        #expect(htmlDisk.contains("<!DOCTYPE html>"))
        #expect(htmlDisk.contains("DEMO"))
        #expect(!htmlDisk.contains("—"))
    }

    // MARK: - 4. ScholarMCPServer JSON-RPC 2.0 Protocol & Firewall Enforcement

    @Test("ScholarMCPServer handles JSON-RPC 2.0 initialize and tools/list with 8 academic tools")
    func mcpServerInitializeAndToolsListJSONRPC() throws {
        let server = ScholarMCPServer()

        // 1. initialize handshake
        let initReq = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let initRaw = try #require(server.handleJSONRPCLine(initReq))
        let initJSON = try #require(JSONSerialization.jsonObject(with: Data(initRaw.utf8)) as? [String: Any])
        #expect(initJSON["jsonrpc"] as? String == "2.0")
        #expect(initJSON["id"] as? Int == 1)
        let initResult = try #require(initJSON["result"] as? [String: Any])
        #expect(initResult["protocolVersion"] as? String == "2024-11-05")

        // 2. tools/list exposes all 8 academic tools
        let listReq = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let listRaw = try #require(server.handleJSONRPCLine(listReq))
        let listJSON = try #require(JSONSerialization.jsonObject(with: Data(listRaw.utf8)) as? [String: Any])
        let listResult = try #require(listJSON["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        #expect(tools.count == 8)
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.contains("scholar_cite_key"))
        #expect(names.contains("scholar_verify_bibliography"))
        #expect(names.contains("scholar_prisma_agreement"))

        // Notifications without id return nil per JSON-RPC 2.0
        #expect(server.handleJSONRPCLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test("MCP scholar_cite_key returns isError: true + ERR_UNVERIFIED_CITATION on missing project or hallucinated key and succeeds on verified record")
    func mcpServerCiteKeyBlocksHallucinationAndAllowsVerifiedRecord() throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-mcp-cite")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("MCPCite.scholarproj")
        let db = try ScholarProjectDatabase(bundleURL: bundleURL, seedDemoIfEmpty: true)
        try db.updateCitationFirewallStatus(
            citeKey: "vaswani2017attention",
            firewallClass: .verified,
            auditNote: "Verified against registry"
        )
        db.close()

        let server = ScholarMCPServer(defaultProjectBundlePath: bundleURL.path)

        // 1. Hallucinated key via full JSON-RPC tools/call envelope -> isError: true + ERR_UNVERIFIED_CITATION
        let blockedReq = #"""
        {"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"scholar_cite_key","arguments":{"citeKey":"smith2025hallucinated","style":"apa7"}}}
        """#
        let blockedRaw = try #require(server.handleJSONRPCLine(blockedReq))
        let blockedEnv = try #require(JSONSerialization.jsonObject(with: Data(blockedRaw.utf8)) as? [String: Any])
        let blockedResult = try #require(blockedEnv["result"] as? [String: Any])
        #expect(blockedResult["isError"] as? Bool == true)
        let blockedContent = try #require((blockedResult["content"] as? [[String: Any]])?.first)
        let blockedText = try #require(blockedContent["text"] as? String)
        #expect(blockedText.contains("ERR_UNVERIFIED_CITATION"))
        #expect(blockedText.contains("smith2025hallucinated"))

        // 2. Verified record via JSON-RPC tools/call -> isError: false + CITATION_STATUS:VERIFIED
        let okReq = #"""
        {"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"scholar_cite_key","arguments":{"citeKey":"vaswani2017attention","style":"ieee"}}}
        """#
        let okRaw = try #require(server.handleJSONRPCLine(okReq))
        let okEnv = try #require(JSONSerialization.jsonObject(with: Data(okRaw.utf8)) as? [String: Any])
        let okResult = try #require(okEnv["result"] as? [String: Any])
        #expect(okResult["isError"] as? Bool == false)
        let okContent = try #require((okResult["content"] as? [[String: Any]])?.first)
        let okText = try #require(okContent["text"] as? String)
        #expect(okText.contains("CITATION_STATUS:VERIFIED"))
        #expect(okText.contains("Attention Is All You Need"))
    }

    @Test("MCP server requires explicit project/demo target and executes provenance search, PRISMA agreement, LSP diagnostics, diff, and citation gaps")
    func mcpServerExecutesRemainingDomainTools() {
        // Without default project or allowDemoMode, omitting projectPath fails rather than silently loading demo data
        let strictServer = ScholarMCPServer()
        let missingTarget = strictServer.executeToolCall(name: "scholar_prisma_agreement", arguments: [:])
        #expect(missingTarget["isError"] as? Bool == true)

        let server = ScholarMCPServer(allowDemoMode: true)

        let prov = server.executeToolCall(name: "scholar_search_provenance", arguments: ["claim": "FlashAttention speedup", "demo": true])
        #expect(prov["isError"] as? Bool == false)

        let prisma = server.executeToolCall(name: "scholar_prisma_agreement", arguments: ["demo": true])
        #expect(prisma["isError"] as? Bool == false)
        let prismaText = ((prisma["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(prismaText.contains("[DEMO]"))
        #expect(prismaText.contains("Kappa="))

        let diff = server.executeToolCall(
            name: "scholar_track_changes_diff",
            arguments: ["original": "Baseline latency 20 ms.", "revised": "Optimized latency 4 ms."]
        )
        #expect(diff["isError"] as? Bool == false)
        let diffText = ((diff["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(diffText.contains("\\DIFadd{"))

        let gaps = server.executeToolCall(name: "scholar_citation_gaps", arguments: ["demo": true])
        #expect(gaps["isError"] as? Bool == false)

        // LSP diagnostics marks isError: true when inline source cites smith2025hallucinated against demo bib
        let badLSP = server.executeToolCall(
            name: "scholar_lsp_diagnostics",
            arguments: ["source": "\\section{Test}\nBad \\cite{smith2025hallucinated}.\n", "demo": true]
        )
        #expect(badLSP["isError"] as? Bool == true)

        // Unknown tool returns isError: true
        let unknown = server.executeToolCall(name: "scholar_nonexistent_tool", arguments: [:])
        #expect(unknown["isError"] as? Bool == true)
    }

    @Test("S20/S23 regression: CLI requires explicit file or --project/--demo, accepts direct .tex/.bib files, and fails non-zero on unverified citations")
    func s20AndS23CLIDirectFileInputsMissingInputErrorsAndNonZeroVerifyExit() async throws {
        let cli = ScholarCLIRunner()

        // 1. Missing input (no file, no --project, no --demo) MUST throw invalidCLIArguments (exit 2), NEVER return demo data
        await #expect(throws: ScholarOSError.self) {
            _ = try await cli.execute(arguments: ["outline"])
        }
        await #expect(throws: ScholarOSError.self) {
            _ = try await cli.execute(arguments: ["verify-citations"])
        }
        // Unknown flag MUST throw invalidCLIArguments (exit 2)
        await #expect(throws: ScholarOSError.self) {
            _ = try await cli.execute(arguments: ["outline", "--bogus-flag"])
        }
        // Nonexistent --project MUST throw fileNotFound, never create empty project or fall back to demo
        await #expect(throws: ScholarOSError.self) {
            _ = try await cli.execute(arguments: ["outline", "--project", "/nonexistent/path/missing.scholarproj"])
        }

        // 2. Direct .tex and .bib inputs operate on user files and exit 1 on unverified citations
        let tempDir = try makeTempDirectory(prefix: "scholaros-s20-direct")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let texFile = tempDir.appendingPathComponent("paper.tex")
        try """
        \\documentclass{article}
        \\begin{document}
        \\section{Real User Section Alpha}
        \\subsection{Real User Subsection Beta}
        We cite \\cite{lecun2015deep}.
        \\end{document}
        """.write(to: texFile, atomically: true, encoding: .utf8)

        let bibFile = tempDir.appendingPathComponent("refs.bib")
        try """
        @article{lecun2015deep,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          volume  = {521},
          pages   = {436--444},
          doi     = {10.1038/nature14539}
        }
        @article{fake2026nature,
          author  = {Doe, Alex},
          title   = {Plausible Fabricated Nature Paper},
          journal = {Nature},
          year    = {2026},
          doi     = {10.1038/fake.2026.99999}
        }
        """.write(to: bibFile, atomically: true, encoding: .utf8)

        let outlineOut = try await cli.execute(arguments: ["outline", texFile.path])
        #expect(outlineOut.contains("Real User Section Alpha"))
        #expect(outlineOut.contains("Real User Subsection Beta"))
        #expect(!outlineOut.contains("Methodology and Verification Semantics"))

        let verifyRun = try await cli.run(arguments: ["verify-citations", bibFile.path, "--offline"])
        #expect(verifyRun.exitCode == 1)
        #expect(verifyRun.stdout.contains("Verified=0"))
        #expect(!verifyRun.stdout.contains("VERIFIED_DOI"))

        let formatOut = try await cli.execute(arguments: ["format-bib", bibFile.path, "--style", "ieee"])
        #expect(formatOut.contains("[1]"))
        #expect(formatOut.contains("Deep learning"))

        let diagOut = try await cli.execute(arguments: ["diagnostics", texFile.path, "--bib", bibFile.path])
        #expect(diagOut.contains("lecun2015deep"))
    }

    @Test("S25 regression: prisma-stats and MCP scholar_prisma_agreement report identical nominal Cohen's kappa matching hand calculation")
    func s25PrismaStatsAndMCPKappaMatchExactHandCalculation() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-s25-kappa")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("KappaStudy.scholarproj")
        let db = try ScholarProjectDatabase(bundleURL: bundleURL, seedDemoIfEmpty: true)
        defer { db.close() }

        // Hand calculation on the 12 dual-screened studies over the 5 nominal ScreeningDecision categories
        // (include, maybe, exclude(E1), exclude(E2), exclude(E3)):
        // Po = 10 / 12 = 0.8333333333
        // Pe = (5*5 + 1*2 + 2*2 + 2*2 + 2*1) / 144 = 37 / 144 = 0.2569444444
        // Cohen's kappa = (10/12 - 37/144) / (1 - 37/144) = 83 / 107 = 0.7757009345794393
        let expectedKappa = 83.0 / 107.0

        let dbMetrics = try db.computePRISMAMetrics()
        #expect(abs(dbMetrics.cohensKappa - expectedKappa) < 1e-6)

        let server = ScholarMCPServer(defaultProjectBundlePath: bundleURL.path)
        let mcpResp = server.executeToolCall(
            name: "scholar_prisma_agreement",
            arguments: ["projectPath": bundleURL.path]
        )
        let mcpText = ((mcpResp["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        // Extract Kappa=<num> from MCP output
        let kappaToken = mcpText
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("Kappa=") }
        let mcpKappa = kappaToken.flatMap { Double($0.replacingOccurrences(of: "Kappa=", with: "")) } ?? -1.0
        #expect(abs(mcpKappa - expectedKappa) < 1e-4)
        #expect(abs(mcpKappa - dbMetrics.cohensKappa) < 1e-4)
    }

    @Test("S27 regression: MCP server returns -32700 Parse error on invalid JSON and -32601 Method not found on unknown method")
    func s27MCPServerInvalidJSONReturns32700AndUnknownMethodReturns32601() throws {
        let server = ScholarMCPServer()

        // 1. Invalid JSON -> JSON-RPC 2.0 Parse error (-32700)
        let parseErrRaw = try #require(server.handleJSONRPCLine("{not valid json"))
        let parseErrJSON = try #require(JSONSerialization.jsonObject(with: Data(parseErrRaw.utf8)) as? [String: Any])
        let parseErrObj = try #require(parseErrJSON["error"] as? [String: Any])
        #expect(parseErrObj["code"] as? Int == -32700)

        // 2. Unknown method -> JSON-RPC 2.0 Method not found (-32601)
        let methodErrRaw = try #require(server.handleJSONRPCLine(#"{"jsonrpc":"2.0","id":77,"method":"nonexistent/method","params":{}}"#))
        let methodErrJSON = try #require(JSONSerialization.jsonObject(with: Data(methodErrRaw.utf8)) as? [String: Any])
        #expect(methodErrJSON["id"] as? Int == 77)
        let methodErrObj = try #require(methodErrJSON["error"] as? [String: Any])
        #expect(methodErrObj["code"] as? Int == -32601)
    }

    // MARK: - 5. CambridgeLinenHTMLReportExporter Hallmark & Zero Em-Dash Verification

    @Test("CambridgeLinenHTMLReportExporter embeds Hallmark v2.0.0 stamp, PRISMA SVG, and enforces zero em-dashes")
    func cambridgeLinenHTMLReportExporterHallmarkStampAndZeroEmDash() throws {
        let db = try ScholarProjectDatabase.inMemory(seedDemo: true)
        defer { db.close() }

        // Deliberately inject em-dashes into project title and manuscript section heading to verify sanitization!
        try db.setProjectTitle("ScholarOS Benchmark — Deterministic Firewall — Full Audit")
        _ = try db.upsertManuscriptFile(
            path: "sections/emdash.tex",
            content: "\\section{Ablation — Study}\nProse with em—dash test.\n",
            format: .latex,
            mirrorToBundleDisk: false
        )

        let html = try CambridgeLinenHTMLReportExporter().exportHTMLDossier(database: db)

        #expect(html.contains("/* Hallmark · v2.0.0"))
        #expect(html.contains("--bg-linen: #F8F6F0;"))
        #expect(html.contains("--accent-forest: #1D4D3E;"))
        #expect(html.contains(#"id="btn-lang-zh""#))
        #expect(html.contains(#"id="btn-lang-en""#))
        #expect(html.contains(#"data-en=""#))
        #expect(html.contains(#"data-zh=""#))
        #expect(html.contains("io.github.zxu756.ScholarOS.language"))
        #expect(html.contains("navigator.language"))
        #expect(html.contains("<svg"))
        #expect(html.contains("</svg>"))
        // Strict zero em-dash guarantee across the entire exported HTML document!
        #expect(!html.contains("—"))
    }

    // MARK: - 6. ScholarWorkbenchShell (Palette, Docking Controller & Fuzzy Command Palette)

    @Test("CambridgeLinenPalette maps all 5 CitationFirewallClasses, EditorialSeverities, and LSPDiagnosticSeverities")
    func cambridgeLinenPaletteSemanticBadgeMapping() {
        for fw in CitationFirewallClass.allCases {
            let style = CambridgeLinenPalette.style(for: fw)
            #expect(!style.sfSymbol.isEmpty)
        }
        for sev in EditorialSeverity.allCases {
            let style = CambridgeLinenPalette.style(for: sev)
            #expect(!style.sfSymbol.isEmpty)
        }
        for diag in [LSPDiagnosticSeverity.hint, .info, .warning, .error] {
            let style = CambridgeLinenPalette.style(for: diag)
            #expect(!style.sfSymbol.isEmpty)
        }
        #expect(!CambridgeLinenPalette.resolvedSymbolName(for: "lock.shield").isEmpty)
    }

    @Test("ScholarSubsequenceFuzzyScorer ranks prefix/word-boundary matches above scattered matches and filters categories")
    func subsequenceFuzzyScorerPrefixBonusAndCategoryFiltering() throws {
        let scorer = ScholarSubsequenceFuzzyScorer()

        let prefixHit = try #require(scorer.scoreSubsequence(query: "cite", target: "Citation Firewall"))
        let scatteredHit = try #require(scorer.scoreSubsequence(query: "cite", target: "archivalxcyiztxeworkbench"))
        #expect(prefixHit.score > scatteredHit.score)
        #expect(scorer.scoreSubsequence(query: "xyz", target: "Citation Firewall") == nil)

        let bib = [
            BibliographyEntry(
                citeKey: "vaswani2017attention",
                title: "Attention Is All You Need",
                authors: [BibAuthor(givenName: "Ashish", familyName: "Vaswani")],
                year: 2017,
                doi: "10.1145/3295222.3295349",
                firewallClass: .verified
            ),
            BibliographyEntry(
                citeKey: "smith2025hallucinated",
                title: "Attention Hallucinations",
                authors: [BibAuthor(givenName: "J.", familyName: "Smith")],
                year: 2025,
                firewallClass: .notFound
            )
        ]
        let items = ScholarCommandPaletteCatalog.buildItems(
            manuscriptFiles: [
                ManuscriptFileRecord(path: "main.tex", format: .latex, content: "", wordCount: 420, sha256: "abc", updatedAt: Date())
            ],
            outlineEntries: [
                DocumentOutlineEntry(level: 1, numberPrefix: "1", title: "Introduction", label: "sec:intro", filePath: "main.tex", line: 10, wordCountInSection: 120)
            ],
            bibliographyEntries: bib,
            canUndo: true,
            topUndoTitle: "Edit Intro"
        )
        #expect(items.count >= 8)

        let citationOnly = scorer.rank(items: items, query: "attention", categoryFilter: .citations)
        #expect(citationOnly.allSatisfy { $0.item.category == .citations })
        // Verified citation carries higher baseWeight than blocked hallucination!
        #expect(citationOnly.first?.item.monospacedTag?.contains("vaswani2017attention") == true)
    }

    @Test("ScholarDockingController manages multi-tab pinning/closing, split-pane clamping, zoom bounds, and layout snapshots")
    @MainActor
    func dockingControllerTabsClampingZoomAndSnapshotRoundTrip() {
        let controller = ScholarDockingController()

        // Open 2 additional tabs; pinned "main.tex" refuses close while unpinned tab closes cleanly
        controller.openManuscript(filePath: "sections/method.tex", line: 24, column: 3, wordCount: 310)
        controller.openManuscript(filePath: "sections/eval.tex", line: 8, column: 1, wordCount: 190)
        #expect(controller.openManuscriptTabs.count == 3)
        #expect(controller.activeManuscriptFilePath == "sections/eval.tex")

        controller.closeManuscriptTab("main.tex") // Pinned -> stays open!
        #expect(controller.openManuscriptTabs.contains { $0.filePath == "main.tex" })

        controller.closeManuscriptTab("sections/eval.tex") // Unpinned -> closes!
        #expect(!controller.openManuscriptTabs.contains { $0.filePath == "sections/eval.tex" })

        // Split-pane width & height clamping invariants
        controller.resizeLeftSidebar(to: 50)
        #expect(controller.leftSidebarWidth == ScholarDockingController.minSidebarWidth)
        controller.resizeLeftSidebar(to: 999)
        #expect(controller.leftSidebarWidth == ScholarDockingController.maxSidebarWidth)

        controller.resizeRightInspector(to: 100)
        #expect(controller.rightInspectorWidth == ScholarDockingController.minRightInspectorWidth)
        controller.resizeRightInspector(to: 999)
        #expect(controller.rightInspectorWidth == ScholarDockingController.maxRightInspectorWidth)

        controller.resizeBottomDrawer(to: 40)
        #expect(controller.bottomDrawerHeight == ScholarDockingController.minDrawerHeight)
        controller.resizeBottomDrawer(to: 999)
        #expect(controller.bottomDrawerHeight == ScholarDockingController.maxDrawerHeight)

        // Zoom scale clamping [0.75, 1.75]
        controller.zoomIn(step: 5.0)
        #expect(controller.zoomScale == ScholarDockingController.maxZoomScale)
        controller.zoomOut(step: 5.0)
        #expect(controller.zoomScale == ScholarDockingController.minZoomScale)
        controller.resetZoom()
        #expect(controller.zoomScale == 1.0)

        // Snapshot export & apply round-trip
        controller.focusCitation("vaswani2017attention", openRightInspector: true, switchToFirewallStudio: false)
        let snapshot = controller.exportLayoutSnapshot()
        let restoredController = ScholarDockingController()
        restoredController.applyLayoutSnapshot(snapshot)
        #expect(restoredController.selectedCiteKey == "vaswani2017attention")
        #expect(restoredController.rightInspectorMode == .citationInspector)
        #expect(Double(restoredController.leftSidebarWidth) == snapshot.leftSidebarWidth)
    }

    @Test("ScholarDockingController diagnostic, editorial finding, and SyncTeX navigation synchronize cursor & drawers")
    @MainActor
    func dockingControllerCrossPaneNavigationSynchronizesCursor() {
        let controller = ScholarDockingController()

        let diag = LSPDiagnostic(
            code: "BIB001",
            severity: .error,
            message: "Blocked citation",
            span: TextSpan(
                filePath: "sections/intro.tex",
                start: TextPosition(line: 42, column: 9),
                end: TextPosition(line: 42, column: 30)
            )
        )
        controller.navigateToDiagnostic(diag)
        #expect(controller.activeManuscriptFilePath == "sections/intro.tex")
        #expect(controller.synchronizedCursor.line == 42)
        #expect(controller.synchronizedCursor.column == 9)

        let anchor = SyncTeXAnchor(
            sourceFile: "main.tex",
            line: 88,
            column: 4,
            pdfPageIndex: 2,
            xPt: 72,
            yPt: 340,
            widthPt: 210,
            heightPt: 12
        )
        controller.navigateToSyncTeXAnchor(anchor)
        #expect(controller.activeSyncTeXAnchor == anchor)
        #expect(controller.rightInspectorMode == .pdfPreview)
    }

    @Test("ScholarWorkbenchPreferences and ScholarToastCenter manage plugin toggles and bounded toast queue")
    @MainActor
    func workbenchPreferencesAndToastCenterQueueManagement() {
        let prefs = ScholarWorkbenchPreferences()
        #expect(prefs.pluginManifests.count == 4)
        prefs.togglePluginEnabled(id: BuiltInEditorialPluginCatalog.antiAIProseSanitizerID)
        let toggled = prefs.pluginManifests.first { $0.id == BuiltInEditorialPluginCatalog.antiAIProseSanitizerID }
        #expect(toggled?.isEnabled == false)
        prefs.restoreDefaults()
        #expect(prefs.pluginManifests.allSatisfy { $0.isEnabled })

        let toastCenter = ScholarToastCenter(maxVisibleBanners: 2)
        var actionFired = false
        toastCenter.enqueue(tone: .verified, title: "Verified 1", autoDismissSeconds: nil)
        toastCenter.enqueue(tone: .advisory, title: "Advisory 2", autoDismissSeconds: nil)
        toastCenter.enqueue(tone: .blocker, title: "Blocker 3", actionTitle: "Fix", autoDismissSeconds: nil) {
            actionFired = true
        }
        toastCenter.dismissAll()
        #expect(!actionFired)
    }

    // MARK: - 7. Bilingual Localization Engine (中文 / EN)

    @Test("ScholarLocalizer toggles zh-Hans <-> en live and persists to UserDefaults (io.github.zxu756.ScholarOS.language)")
    @MainActor
    func scholarLocalizerLiveToggleAndUserDefaultsPersistence() throws {
        let defaults = InMemoryUserDefaults()

        let localizer = ScholarLocalizer(
            arguments: ["ScholarOS"],
            environment: [:],
            userDefaults: defaults,
            preferredLanguages: ["en-US"],
            persistToUserDefaults: true
        )
        #expect(localizer.language == .en)
        #expect(localizer.language.badge == "EN")
        #expect(localizer.L("Citation Firewall", "引文防火墙") == "Citation Firewall")

        localizer.toggleLanguage()
        #expect(localizer.language == .zhHans)
        #expect(localizer.language.rawValue == "zh-Hans")
        #expect(localizer.language.badge == "中文")
        #expect(localizer.L("Citation Firewall", "引文防火墙") == "引文防火墙")
        #expect(defaults.string(forKey: ScholarLocalizer.userDefaultsKey) == "zh-Hans")

        localizer.toggleLanguage()
        #expect(localizer.language == .en)
        #expect(defaults.string(forKey: ScholarLocalizer.userDefaultsKey) == "en")
    }

    @Test("ScholarLocalizer resolves --lang CLI > SCHOLAROS_LANG > UserDefaults > Chinese Locale auto-detection")
    func scholarLocalizerResolutionOrderAndCLIArgumentStripping() throws {
        let defaults = InMemoryUserDefaults()

        // 1. Locale auto-detection: preferredLanguages starting with "zh" defaults to .zhHans; English defaults to .en
        #expect(
            ScholarLocalizer.resolveLanguage(
                arguments: ["ScholarOS"],
                environment: [:],
                userDefaults: defaults,
                preferredLanguages: ["zh-Hans-CN", "en-US"]
            ) == .zhHans
        )
        #expect(
            ScholarLocalizer.resolveLanguage(
                arguments: ["ScholarOS"],
                environment: [:],
                userDefaults: defaults,
                preferredLanguages: ["zh-Hant-HK", "en-US"]
            ) == .zhHans
        )
        #expect(
            ScholarLocalizer.resolveLanguage(
                arguments: ["ScholarOS"],
                environment: [:],
                userDefaults: defaults,
                preferredLanguages: ["en-GB"]
            ) == .en
        )

        // 2. UserDefaults overrides system locale
        defaults.set("en", forKey: ScholarLocalizer.userDefaultsKey)
        #expect(
            ScholarLocalizer.resolveLanguage(
                arguments: ["ScholarOS"],
                environment: [:],
                userDefaults: defaults,
                preferredLanguages: ["zh-Hans-CN"]
            ) == .en
        )

        // 3. SCHOLAROS_LANG overrides UserDefaults
        #expect(
            ScholarLocalizer.resolveLanguage(
                arguments: ["ScholarOS"],
                environment: ["SCHOLAROS_LANG": "zh"],
                userDefaults: defaults,
                preferredLanguages: ["en-US"]
            ) == .zhHans
        )

        // 4. CLI --lang / --lang= overrides SCHOLAROS_LANG & UserDefaults
        #expect(
            ScholarLocalizer.resolveLanguage(
                arguments: ["ScholarOS", "--lang", "en"],
                environment: ["SCHOLAROS_LANG": "zh"],
                userDefaults: defaults,
                preferredLanguages: ["zh-Hans-CN"]
            ) == .en
        )
        #expect(
            ScholarLocalizer.resolveLanguage(
                arguments: ["ScholarOS", "--lang=zh"],
                environment: ["SCHOLAROS_LANG": "en"],
                userDefaults: defaults,
                preferredLanguages: ["en-US"]
            ) == .zhHans
        )

        // 5. CLI stripping keeps subcommand positional arguments intact
        let stripped = ScholarLocalizer.strippingLanguageArguments([
            "--lang", "zh", "export-html", "--output", "/tmp/dossier.html", "--lang=en"
        ])
        #expect(stripped == ["export-html", "--output", "/tmp/dossier.html"])
    }

    @Test("Bilingual domain labels and Command Palette items localize cleanly across zh-Hans and en")
    func bilingualDomainLabelsAndCommandPaletteLocalization() async throws {
        #expect(ScholarStudioTab.manuscriptEditor.localizedTitle(.zhHans).contains("手稿"))
        #expect(ScholarStudioTab.citationGraph.localizedTitle(.zhHans) == "引文知识图谱")
        #expect(ScholarStudioTab.prismaScreening.localizedTitle(.zhHans) == "PRISMA 2020 双盲筛查")
        #expect(CitationFirewallClass.verified.localizedBadgeTitle(.zhHans) == "已验证")
        #expect(CitationFirewallClass.verified.localizedBadgeTitle(.en) == "Verified")
        #expect(CitationFirewallClass.retracted.localizedFilterChip(.zhHans) == "已撤稿")
        #expect(CitationFirewallClass.unverified.localizedBadgeTitle(.zhHans) == "未核查")

        let zhItems = ScholarCommandPaletteCatalog.buildItems(
            manuscriptFiles: [],
            outlineEntries: [],
            bibliographyEntries: [],
            canUndo: false,
            topUndoTitle: nil,
            language: .zhHans
        )
        #expect(zhItems.contains { $0.action == .toggleLanguage && $0.shortcutHint == "⇧⌘L" })
        #expect(zhItems.contains { $0.title.contains("引文知识图谱") })
        #expect(!zhItems.contains { $0.subtitle.contains("已验证 DOI") })

        // Bilingual CLI --lang en vs --lang zh honesty checks
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("scholar-bilingual-m0-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let bibURL = tmpDir.appendingPathComponent("refs.bib")
        try """
        @article{lecun2015,
          author = {LeCun, Yann},
          title = {Deep learning},
          journal = {Nature},
          year = {2015},
          doi = {10.1038/nature14539}
        }
        @article{wakefield1998,
          author = {Wakefield, A. J.},
          title = {Retracted paper},
          journal = {The Lancet},
          year = {1998},
          doi = {10.1016/S0140-6736(97)11096-0}
        }
        """.write(to: bibURL, atomically: true, encoding: .utf8)

        let runner = ScholarCLIRunner()
        let enOut = try await runner.run(arguments: ["verify-citations", bibURL.path, "--offline", "--lang", "en"])
        let zhOut = try await runner.run(arguments: ["verify-citations", bibURL.path, "--offline", "--lang", "zh"])
        #expect(enOut.exitCode == 1)
        #expect(zhOut.exitCode == 1)
        #expect(enOut.stdout.contains("Verified=0"))
        #expect(zhOut.stdout.contains("Verified=0"))
        // S32: the English output states the incomplete built-in list in English; Chinese only under --lang zh.
        #expect(enOut.stdout.contains("built-in list, incomplete"))
        #expect(!containsChineseCharacters(enOut.stdout))
        #expect(zhOut.stdout.contains("内置名单，不完整"))
        #expect(zhOut.stdout.contains("尚未向外部注册库核查"))
        #expect(!zhOut.stdout.contains("已通过 Crossref"))

        // Bilingual HTML demo dossier contains explicit [DEMO / 演示数据] marker
        let demoDB = try ScholarProjectDatabase.inMemory(seedDemo: true)
        defer { demoDB.close() }
        let html = try CambridgeLinenHTMLReportExporter().exportHTMLDossier(database: demoDB, isDemo: true)
        #expect(html.contains("[DEMO] Sample Unverified Dataset"))
        #expect(html.contains("[DEMO / 演示数据]"))
        #expect(!html.contains("Hardware-Gated"))
        #expect(!html.contains("硬件级"))
        #expect(!html.contains("Verified DOI"))
        #expect(!html.contains("已验证 DOI"))
        #expect(!html.contains("\u{2014}"))
    }

    @Test("S32/S33 regression: verify-citations prints one class tag per entry, no Chinese in English output, and states that this version performs no online lookups")
    func s32AndS33VerifyCitationsOutputHasSingleTagNoChineseInEnglishAndHonestNoLookupNotice() async throws {
        // 12-entry recheck bibliography (3 real, 2 fabricated DOIs, 3 real DOIs with wrong title/year,
        // 2 without DOI, 2 retracted), copied into the repository from the acceptance harness.
        let bibPath = repositoryRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib").path
        #expect(FileManager.default.fileExists(atPath: bibPath))

        let runner = ScholarCLIRunner()
        let enPlain = try await runner.run(arguments: ["verify-citations", bibPath, "--lang", "en"])
        let enOffline = try await runner.run(arguments: ["verify-citations", bibPath, "--offline", "--lang", "en"])
        let zhPlain = try await runner.run(arguments: ["verify-citations", bibPath, "--lang", "zh"])
        let zhOffline = try await runner.run(arguments: ["verify-citations", bibPath, "--offline", "--lang", "zh"])

        // The original M0 rows still hold: nothing is VERIFIED and the exit code is non-zero.
        for out in [enPlain, enOffline, zhPlain, zhOffline] {
            #expect(out.exitCode == 1)
            #expect(out.stdout.contains("Evaluated=12 Verified=0 Drift=0 NotFound=1 Retracted=1 Unverified=10"))
            #expect(!out.stdout.contains("[VERIFIED]"))
        }

        // S33: --offline changes nothing, and the output says why instead of labelling entries "(offline)".
        #expect(enPlain.stdout == enOffline.stdout)
        #expect(zhPlain.stdout == zhOffline.stdout)
        #expect(enPlain.stdout.contains("this version performs no online registry lookups (online verification is planned for M1)"))
        #expect(zhPlain.stdout.contains("本版本不联网核查（联网核查排在 M1）"))
        #expect(!enPlain.stdout.lowercased().contains("(offline)"))
        #expect(!enPlain.stdout.lowercased().contains("unverified offline"))
        #expect(!zhPlain.stdout.contains("离线模式"))

        // S32: exactly one class tag per entry line, at the start of the line, in both languages.
        let classTags = CitationFirewallClass.allCases.map { "[\($0.rawValue)]" }
        for out in [enPlain, zhPlain] {
            let entryLines = out.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { line in classTags.contains { line.contains($0) } }
            #expect(entryLines.count == 12)
            for line in entryLines {
                let tagOccurrences = classTags.reduce(0) { $0 + line.components(separatedBy: $1).count - 1 }
                #expect(tagOccurrences == 1, "duplicate class tag: \(line)")
                #expect(classTags.contains { line.hasPrefix($0 + " ") }, "class tag not at line start: \(line)")
            }
        }
        // S32: no Chinese anywhere in the English output.
        #expect(!containsChineseCharacters(enPlain.stdout), "\(enPlain.stdout)")

        // Expected lines for three representative entries, in both languages.
        #expect(enPlain.stdout.contains("[UNVERIFIED] real_lecun: DOI '10.1038/nature14539' has valid ISO 26324 syntax. Not checked against any external registry."))
        #expect(enPlain.stdout.contains("[UNVERIFIED] fake_nonsentinel: DOI '10.1038/fake.2026.99999' has valid ISO 26324 syntax. Not checked against any external registry."))
        #expect(enPlain.stdout.contains("[RETRACTED] retracted_wakefield: DOI '10.1016/s0140-6736(97)11096-0' matched the built-in retraction hint list (built-in list, incomplete)."))
        #expect(zhPlain.stdout.contains("[UNVERIFIED] real_lecun: DOI '10.1038/nature14539' 语法格式合法；尚未向外部注册库核查。"))
        #expect(zhPlain.stdout.contains("[RETRACTED] retracted_wakefield: 撤稿提示：DOI '10.1016/S0140-6736(97)11096-0' 命中内置撤稿名单（内置名单，不完整）。"))

        // The MCP tool returns the same library notes: no "(offline)" label and no Chinese in them either.
        let rawBib = try String(contentsOfFile: bibPath, encoding: .utf8)
        let mcpResult = ScholarMCPServer().executeToolCall(name: "scholar_verify_bibliography", arguments: ["bibtex": rawBib])
        let mcpContent = try #require(mcpResult["content"] as? [[String: Any]])
        let mcpText = try #require(mcpContent.first?["text"] as? String)
        #expect(mcpText.contains("Not checked against any external registry."))
        #expect(!mcpText.lowercased().contains("(offline)"))
        #expect(!mcpText.lowercased().contains("unverified offline"))
        #expect(!containsChineseCharacters(mcpText))
    }

    // MARK: - 8. M1 Item 9 CLI `--registry-record` and `--registry-replay` Tests

    @Test("M1 item 9: --help documents --registry-record and --registry-replay in EN/ZH, and invalid flag combinations or missing dirs exit 2")
    func m1Item9CLIHelpDocumentsRecordAndReplayAndRejectsInvalidFlagCombinationsWithExit2() async throws {
        let runner = ScholarCLIRunner()
        let helpEN = try await runner.execute(arguments: ["--help", "--lang", "en"])
        let helpZH = try await runner.execute(arguments: ["--help", "--lang", "zh"])

        #expect(helpEN.contains("--registry-record"))
        #expect(helpEN.contains("--registry-replay"))
        #expect(helpZH.contains("--registry-record"))
        #expect(helpZH.contains("--registry-replay"))

        let bibPath = repositoryRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib").path
        let tempDir = try makeTempDirectory(prefix: "scholaros-cli-flags")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let invalidRuns: [[String]] = [
            ["verify-citations", bibPath, "--registry-record", tempDir.path, "--registry-replay", tempDir.path],
            ["verify-citations", bibPath, "--offline", "--registry-replay", tempDir.path],
            ["verify-citations", bibPath, "--offline", "--registry-record", tempDir.path],
            ["verify-citations", "--demo", "--registry-replay", tempDir.path],
            ["verify-citations", "--demo", "--registry-record", tempDir.path],
            ["verify-citations", bibPath, "--registry-replay"],
            ["verify-citations", bibPath, "--registry-record"],
            ["verify-citations", bibPath, "--registry-replay", tempDir.appendingPathComponent("does-not-exist").path]
        ]

        for args in invalidRuns {
            let result = await runner.runWithExitStatus(arguments: args)
            #expect(result.exitCode == 2, "Expected exit code 2 for args \(args), got \(result.exitCode)")
            #expect(!result.stderr.isEmpty)
        }
    }

    @Test("M1 item 9: CLI --registry-replay emits REPLAY in text and JSON top-level, sends 0 transport calls, and exits 2 on miss or tampered manifest")
    func m1Item9CLIReplayEmitsReplayMarkersExits2OnCorruptManifestOrMissAndNeverCallsTransport() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-cli-rec-replay")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakeBibURL = tempDir.appendingPathComponent("fake-only.bib")
        try """
        @article{fake_nonsentinel,
          author  = {Whitfield, Eleanor and Patel, Raj},
          title   = {Quantum Gradient Descent in Biological Neural Networks},
          journal = {Nature Machine Intelligence},
          year    = {2025},
          doi     = {10.1038/fake.2026.99999}
        }
        """.write(to: fakeBibURL, atomically: true, encoding: .utf8)

        let recDir = tempDir.appendingPathComponent("recorded-404", isDirectory: true)
        let stub404Transport = ClosureRegistrySession { _ in
            RegistryHTTPResponse(
                statusCode: 404,
                body: Data("Resource not found.".utf8),
                headers: [
                    "Content-Type": "text/plain",
                    "Date": "Sun, 15 Nov 2026 11:30:00 GMT"
                ]
            )
        }

        let recordRunner = ScholarCLIRunner(registryTransport: stub404Transport)
        let recResult = await recordRunner.runWithExitStatus(
            arguments: ["verify-citations", fakeBibURL.path, "--registry-record", recDir.path, "--lang", "en"]
        )
        #expect(recResult.exitCode == 1)
        #expect(recResult.stdout.contains("NotFound=1"))
        #expect(!recResult.stdout.contains("this version performs no online registry lookups"))
        let recordedManifest = try JSONDecoder().decode(
            RegistryRecordingManifest.self,
            from: Data(contentsOf: recDir.appendingPathComponent("manifest.json"))
        )
        #expect(recordedManifest.count == 2)

        actor SpyCounter {
            var calls = 0
            func recordCall() { calls += 1 }
        }
        let spyCounter = SpyCounter()
        let spyTransport = ClosureRegistrySession { req in
            await spyCounter.recordCall()
            throw RegistryTransportError(kind: .transportError, detail: "Replay must never invoke live transport", url: req.url)
        }
        let replayRunner = ScholarCLIRunner(registryTransport: spyTransport)

        // 1. Text replay carries prominent [REPLAY] marker and makes 0 transport calls
        let textReplay = await replayRunner.runWithExitStatus(
            arguments: ["verify-citations", fakeBibURL.path, "--registry-replay", recDir.path, "--lang", "en"]
        )
        #expect(textReplay.exitCode == 1)
        #expect(textReplay.stdout.hasPrefix("[REPLAY]"))
        #expect(textReplay.stdout.contains("NotFound=1"))
        #expect(!containsChineseCharacters(textReplay.stdout))
        #expect(await spyCounter.calls == 0)

        // 2. JSON replay carries top-level REPLAY markers ("mode": "REPLAY", "replay": true) and makes 0 transport calls
        let jsonReplay = await replayRunner.runWithExitStatus(
            arguments: ["verify-citations", fakeBibURL.path, "--registry-replay", recDir.path, "--json", "--lang", "en"]
        )
        #expect(jsonReplay.exitCode == 1)
        let parsedJSON = try JSONSerialization.jsonObject(with: Data(jsonReplay.stdout.utf8))
        let topObj = try #require(parsedJSON as? [String: Any])
        #expect(topObj["mode"] as? String == "REPLAY")
        #expect(topObj["replay"] as? Bool == true)
        #expect(topObj["notFoundCount"] as? Int == 1)
        #expect(await spyCounter.calls == 0)

        // 3. Unrecorded URL during replay exits 2, reports exact missing URL on stderr, and NEVER outputs UNVERIFIED
        let missBibURL = tempDir.appendingPathComponent("miss.bib")
        try """
        @article{unrecorded_paper,
          author  = {Kowalski, Marek},
          title   = {Unrecorded Paper},
          journal = {Nature},
          year    = {2024},
          doi     = {10.1038/unrecorded.2026.77777}
        }
        """.write(to: missBibURL, atomically: true, encoding: .utf8)

        let missResult = await replayRunner.runWithExitStatus(
            arguments: ["verify-citations", missBibURL.path, "--registry-replay", recDir.path, "--lang", "en"]
        )
        #expect(missResult.exitCode == 2)
        #expect(missResult.stderr.contains("https://api.crossref.org/works/10.1038/unrecorded.2026.77777"))
        #expect(!missResult.stdout.contains("UNVERIFIED"))
        #expect(await spyCounter.calls == 0)

        // 4. Corrupting manifest.json SHA-256 exits 2
        let manifestPath = recDir.appendingPathComponent("manifest.json")
        let origManifest = try String(contentsOf: manifestPath, encoding: .utf8)
        let tamperedManifest = origManifest.replacingOccurrences(
            of: "\"sha256\" : \"",
            with: "\"sha256\" : \"0000"
        )
        let altTampered = (tamperedManifest == origManifest)
            ? origManifest.replacingOccurrences(of: "\"sha256\": \"", with: "\"sha256\": \"0000")
            : tamperedManifest
        try altTampered.write(to: manifestPath, atomically: true, encoding: .utf8)

        let corruptResult = await replayRunner.runWithExitStatus(
            arguments: ["verify-citations", fakeBibURL.path, "--registry-replay", recDir.path, "--lang", "en"]
        )
        #expect(corruptResult.exitCode == 2)
        #expect(!corruptResult.stderr.isEmpty)
        #expect(await spyCounter.calls == 0)
    }

    @Test("M1 item 9: real recorded fixtures in Tests/Fixtures/registry replay identically twice, pass URL/header hygiene, send 0 live requests, and exit 2 on byte corruption or missing recording")
    func m1Item9RealRecordedRegistryFixturesReplayDeterministicallyEnforceIntegrityAndPassHygiene() async throws {
        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let manifestURL = registryDir.appendingPathComponent("manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path), "Missing recorded manifest at \(manifestURL.path)")

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(RegistryRecordingManifest.self, from: manifestData)
        #expect(manifest.count > 0)
        #expect(manifest.count == manifest.items.count)
        #expect(manifest.totalHTTPRequestsSent <= 80)
        #expect(manifest.userAgent == "ScholarOS/1.2.0")

        // 1. Verify request URL and request headers in manifest.json and every .meta.json have no @, mailto, api_key, or local path
        let forbiddenTokens = ["@", "%40", "mailto", "api_key", "apikey", "/users/", NSHomeDirectory().lowercased()]
        for item in manifest.items {
            let metaURL = registryDir.appendingPathComponent("\(item.slug).meta.json")
            let metaItem = try JSONDecoder().decode(RegistryRecordedItem.self, from: Data(contentsOf: metaURL))
            #expect(metaItem == item)
            #expect(item.requestHeaders["User-Agent"] == "ScholarOS/1.2.0")

            let lowerURL = item.url.lowercased()
            let decodedLowerURL = (item.url.removingPercentEncoding ?? item.url).lowercased()
            for token in forbiddenTokens where !token.isEmpty && token != "/" {
                #expect(!lowerURL.contains(token), "Forbidden token '\(token)' in recorded URL \(item.url)")
                #expect(!decodedLowerURL.contains(token), "Forbidden token '\(token)' in decoded URL \(item.url)")
            }
            for (hKey, hVal) in item.requestHeaders {
                let lowerHKey = hKey.lowercased()
                let lowerHVal = hVal.lowercased()
                for token in forbiddenTokens where !token.isEmpty && token != "/" {
                    #expect(!lowerHKey.contains(token), "Forbidden token '\(token)' in request header name \(hKey)")
                    #expect(!lowerHVal.contains(token), "Forbidden token '\(token)' in request header value \(hVal)")
                }
            }

            let rawBytes = try Data(contentsOf: registryDir.appendingPathComponent(item.rawFile))
            #expect(rawBytes.count == item.byteLength)
            #expect(RegistryCanonicalURL.sha256Hex(of: rawBytes) == item.sha256)
        }

        // 2. Replay twice with an injected spy transport that fails if ever called
        actor SpyCounter {
            var count = 0
            func increment() { count += 1 }
        }
        let spyCounter = SpyCounter()
        let spyTransport = ClosureRegistrySession { req in
            await spyCounter.increment()
            throw RegistryTransportError(kind: .transportError, detail: "Replay must not touch network transport", url: req.url)
        }
        let replayRunner = ScholarCLIRunner(registryTransport: spyTransport)
        let bibPath = repositoryRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib").path

        let textRun1 = await replayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibPath, "--registry-replay", registryDir.path, "--lang", "en"]
        )
        let textRun2 = await replayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibPath, "--registry-replay", registryDir.path, "--lang", "en"]
        )
        #expect(textRun1.exitCode == 1)
        #expect(textRun1 == textRun2)
        #expect(textRun1.stdout.hasPrefix("[REPLAY]"))
        #expect(!containsChineseCharacters(textRun1.stdout))

        let jsonRun1 = await replayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibPath, "--registry-replay", registryDir.path, "--json", "--lang", "en"]
        )
        let jsonRun2 = await replayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibPath, "--registry-replay", registryDir.path, "--json", "--lang", "en"]
        )
        #expect(jsonRun1.exitCode == 1)
        #expect(jsonRun2.exitCode == 1)

        let top1 = try #require(try JSONSerialization.jsonObject(with: Data(jsonRun1.stdout.utf8)) as? [String: Any])
        let top2 = try #require(try JSONSerialization.jsonObject(with: Data(jsonRun2.stdout.utf8)) as? [String: Any])
        #expect(top1["mode"] as? String == "REPLAY")
        #expect(top1["replay"] as? Bool == true)
        #expect(top2["mode"] as? String == "REPLAY")
        #expect(top2["replay"] as? Bool == true)

        let report1 = try JSONDecoder().decode(CitationFirewallAuditReport.self, from: Data(jsonRun1.stdout.utf8))
        let report2 = try JSONDecoder().decode(CitationFirewallAuditReport.self, from: Data(jsonRun2.stdout.utf8))
        #expect(report1.verdicts.count == 12)
        #expect(report2.verdicts.count == 12)
        for (v1, v2) in zip(report1.verdicts, report2.verdicts) {
            #expect(v1.citeKey == v2.citeKey)
            #expect(v1.firewallClass == v2.firewallClass)
            #expect(v1.allowsManuscriptInsertion == v2.allowsManuscriptInsertion)
            #expect(v1.auditNote == v2.auditNote)
            #expect(v1.findings == v2.findings)
        }

        let byKey = Dictionary(uniqueKeysWithValues: report1.verdicts.map { ($0.citeKey, $0) })
        #expect(byKey["real_lecun"]?.firewallClass == .verified)
        #expect(byKey["real_lstm"]?.firewallClass == .verified)
        #expect(byKey["real_watson"]?.firewallClass == .verified)
        #expect(byKey["fake_nonsentinel"]?.firewallClass == .notFound)
        #expect(byKey["fake_sentinel"]?.firewallClass == .notFound)
        #expect(byKey["wrongtitle"]?.firewallClass == .drift)
        #expect(byKey["wrongyear"]?.firewallClass == .drift)
        #expect(byKey["wrongyear5"]?.firewallClass == .drift)
        #expect(byKey["retracted_wakefield"]?.firewallClass == .retracted)

        // Subset of the 3 real recorded entries exits 0 with Verified=3
        let tempRoot = try makeTempDirectory(prefix: "scholaros-real-fixture-checks")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let verifiedSubsetBib = tempRoot.appendingPathComponent("real3.bib")
        let allBibLines = try String(contentsOfFile: bibPath, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        let firstThreeLines = allBibLines.prefix(3).joined(separator: "\n") + "\n"
        try firstThreeLines.write(to: verifiedSubsetBib, atomically: true, encoding: .utf8)
        let subsetRes = await replayRunner.runWithExitStatus(
            arguments: ["verify-citations", verifiedSubsetBib.path, "--registry-replay", registryDir.path, "--lang", "en"]
        )
        #expect(subsetRes.exitCode == 0)
        #expect(subsetRes.stdout.contains("Evaluated=3 Verified=3"))

        // 3. Corrupting 1 byte in a .raw file exits 2
        let corruptDir = tempRoot.appendingPathComponent("corrupt-raw", isDirectory: true)
        try FileManager.default.copyItem(at: registryDir, to: corruptDir)
        let firstItem = try #require(manifest.items.first)
        let targetRawURL = corruptDir.appendingPathComponent(firstItem.rawFile)
        var corruptedBytes = try Data(contentsOf: targetRawURL)
        corruptedBytes[corruptedBytes.count / 2] ^= 0xFF
        try corruptedBytes.write(to: targetRawURL)

        let corruptRes = await replayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibPath, "--registry-replay", corruptDir.path, "--lang", "en"]
        )
        #expect(corruptRes.exitCode == 2)
        #expect(!corruptRes.stderr.isEmpty)
        #expect(corruptRes.stdout.isEmpty)

        // 4a. Deleting one recording (unrecorded miss at runtime) exits 2 and reports its exact URL
        let missDir = tempRoot.appendingPathComponent("missing-entry-miss", isDirectory: true)
        try FileManager.default.copyItem(at: registryDir, to: missDir)
        let removedItem = try #require(manifest.items.first { $0.url.contains("10.1038/171737a0") } ?? manifest.items.first)
        try FileManager.default.removeItem(at: missDir.appendingPathComponent(removedItem.rawFile))
        try FileManager.default.removeItem(at: missDir.appendingPathComponent("\(removedItem.slug).meta.json"))
        let remainingItems = manifest.items.filter { $0.slug != removedItem.slug }
        var remainingMetaHashes = manifest.metaFilesSHA256
        remainingMetaHashes?.removeValue(forKey: "\(removedItem.slug).meta.json")
        let prunedManifest = RegistryRecordingManifest(
            startedAt: manifest.startedAt,
            completedAt: manifest.completedAt,
            userAgent: manifest.userAgent,
            count: remainingItems.count,
            totalHTTPRequestsSent: remainingItems.count,
            items: remainingItems,
            metaFilesSHA256: remainingMetaHashes
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try manifestEncoder.encode(prunedManifest).write(to: missDir.appendingPathComponent("manifest.json"))

        let missRes = await replayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibPath, "--registry-replay", missDir.path, "--lang", "en"]
        )
        #expect(missRes.exitCode == 2)
        #expect(missRes.stderr.contains(removedItem.url))
        #expect(missRes.stdout.isEmpty)
        #expect(!missRes.stdout.contains("UNVERIFIED"))

        // 4b. Deleting the .raw file directly without updating manifest.json also exits 2 and reports the URL
        let deletedRawDir = tempRoot.appendingPathComponent("deleted-raw-file", isDirectory: true)
        try FileManager.default.copyItem(at: registryDir, to: deletedRawDir)
        try FileManager.default.removeItem(at: deletedRawDir.appendingPathComponent(removedItem.rawFile))

        let deletedRawRes = await replayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibPath, "--registry-replay", deletedRawDir.path, "--lang", "en"]
        )
        #expect(deletedRawRes.exitCode == 2)
        #expect(deletedRawRes.stderr.contains(removedItem.url))
        #expect(deletedRawRes.stdout.isEmpty)

        // 5. Confirm zero live transport requests were ever issued across all replay checks
        #expect(await spyCounter.count == 0)
    }
}
