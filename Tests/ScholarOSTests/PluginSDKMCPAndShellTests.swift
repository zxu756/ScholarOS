import CryptoKit
import Darwin
import Foundation
import SQLite3
import Testing
import ScholarBibAndCSL
import ScholarLSPEngine
import ScholarModels
import ScholarProjectStore
import ScholarPluginSDK
import ScholarCLIAndMCP
import ScholarWorkbenchShell

private enum RealHomeCacheGuard {
    static let realAccountHomePath: String? = {
        guard let pw = getpwuid(getuid()), let cDir = pw.pointee.pw_dir else {
            return nil
        }
        return String(cString: cDir)
    }()

    static let realAccountCacheExistedAtLoad: Bool = {
        guard let home = realAccountHomePath else { return false }
        let path = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Caches/ScholarOS", isDirectory: true).path
        return FileManager.default.fileExists(atPath: path)
    }()
}

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
        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let cli = ScholarCLIRunner(environment: ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path])

        let versionOut = try await cli.execute(arguments: ["version"])
        #expect(versionOut.contains("ScholarOS 1.3.0"))

        let versionWithLangOut = try await cli.execute(arguments: ["--lang", "zh", "version"])
        #expect(versionWithLangOut.contains("ScholarOS 1.3.0"))

        let helpOut = try await cli.execute(arguments: ["--help"])
        #expect(helpOut.contains("verify-citations"))
        #expect(helpOut.contains("--lang zh|en"))

        let initOut = try await cli.execute(arguments: ["init", "--project", bundlePath, "--seed-demo"])
        #expect(initOut.contains("Initialized"))
        #expect(initOut.contains("bib=10"))

        let statusJSON = try await cli.execute(arguments: ["status", "--project", bundlePath])
        let stats = try JSONDecoder().decode(ScholarProjectStats.self, from: Data(statusJSON.utf8))
        #expect(stats.bibliographyCount == 10)
        #expect(stats.schemaVersion == 5)

        let outlineOut = try await cli.execute(arguments: ["outline", "--project", bundlePath])
        #expect(outlineOut.contains("Introduction"))
        #expect(outlineOut.contains("Methodology"))

        let diagOut = try await cli.execute(arguments: ["diagnostics", "--project", bundlePath, "--offline"])
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

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let cli = ScholarCLIRunner(
            environment: ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path]
        )
        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry")

        // 1a. Stored SQLite `.verified` flag alone is NOT trusted without in-run verification (M1 item 8 / S42/S48).
        do {
            _ = try await cli.execute(arguments: ["cite", "vaswani2017attention", "--project", bundleURL.path, "--offline"])
            Issue.record("Expected cite without in-run verification to throw ERR_UNVERIFIED_CITATION")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }

        // 1b. In-run verification via recorded registry fixtures succeeds and formats APA 7th reference
        let allowedOut = try await cli.execute(
            arguments: ["cite", "vaswani2017attention", "--project", bundleURL.path, "--registry-replay", registryDir.path]
        )
        #expect(allowedOut.contains("\\cite{vaswani2017attention}"))
        #expect(allowedOut.contains("Attention Is All You Need"))

        // 2. Unverified demo entry MUST throw ERR_UNVERIFIED_CITATION
        do {
            _ = try await cli.execute(arguments: ["cite", "vaswani2017attention", "--demo"])
            Issue.record("Expected unverified demo entry to throw ERR_UNVERIFIED_CITATION")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }

        // 3. Blocked hallucinated key MUST throw ScholarOSError with ERR_UNVERIFIED_CITATION even under --registry-replay
        do {
            _ = try await cli.execute(
                arguments: ["cite", "smith2025hallucinated", "--project", bundleURL.path, "--registry-replay", registryDir.path]
            )
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
        #expect(verifyRun.exitCode == 3)
        #expect(verifyRun.stdout.contains("[DEMO]"))
        #expect(verifyRun.stdout.contains("Evaluated=10"))
        #expect(verifyRun.stdout.contains("Verified=0"))
        // M1 item 4 (S41): sentinel prefix DOI 10.9999/fake-llm-cite.9999 has valid ISO 26324 syntax, so offline it is UNVERIFIED, not NOT_FOUND.
        #expect(verifyRun.stdout.contains("NotFound=0"))
        #expect(verifyRun.stdout.contains("Unverified=10"))

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
        let tempDir = try makeTempDirectory(prefix: "scholaros-mcp-init")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let server = ScholarMCPServer(
            isOffline: true,
            environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path]
        )

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
    func mcpServerCiteKeyBlocksHallucinationAndAllowsVerifiedRecord() async throws {
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

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let isolatedEnv = ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path]

        let offlineServer = ScholarMCPServer(
            defaultProjectBundlePath: bundleURL.path,
            isOffline: true,
            environment: isolatedEnv
        )
        let okReq = #"""
        {"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"scholar_cite_key","arguments":{"citeKey":"vaswani2017attention","style":"ieee"}}}
        """#

        // 0. Stored SQLite `.verified` status alone is NOT trusted without in-run verification (M1 item 8 / S42/S48).
        let offlineRaw = try #require(offlineServer.handleJSONRPCLine(okReq))
        let offlineEnv = try #require(JSONSerialization.jsonObject(with: Data(offlineRaw.utf8)) as? [String: Any])
        let offlineResult = try #require(offlineEnv["result"] as? [String: Any])
        #expect(offlineResult["isError"] as? Bool == true)
        let offlineText = try #require(((offlineResult["content"] as? [[String: Any]])?.first)?["text"] as? String)
        #expect(offlineText.contains("ERR_UNVERIFIED_CITATION"))

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry")
        let server = ScholarMCPServer(
            defaultProjectBundlePath: bundleURL.path,
            defaultRegistryReplayPath: registryDir.path,
            environment: isolatedEnv
        )

        // 1. Hallucinated key via full JSON-RPC tools/call envelope -> isError: true + ERR_UNVERIFIED_CITATION
        let blockedReq = #"""
        {"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"scholar_cite_key","arguments":{"citeKey":"smith2025hallucinated","style":"apa7"}}}
        """#
        let blockedRaw = try #require(await server.handleJSONRPCLineAsync(blockedReq))
        let blockedEnv = try #require(JSONSerialization.jsonObject(with: Data(blockedRaw.utf8)) as? [String: Any])
        let blockedResult = try #require(blockedEnv["result"] as? [String: Any])
        #expect(blockedResult["isError"] as? Bool == true)
        let blockedContent = try #require((blockedResult["content"] as? [[String: Any]])?.first)
        let blockedText = try #require(blockedContent["text"] as? String)
        #expect(blockedText.contains("ERR_UNVERIFIED_CITATION"))
        #expect(blockedText.contains("smith2025hallucinated"))

        // 2. In-run verified record via JSON-RPC tools/call -> isError: false + CITATION_STATUS:VERIFIED
        let okRaw = try #require(await server.handleJSONRPCLineAsync(okReq))
        let okEnv = try #require(JSONSerialization.jsonObject(with: Data(okRaw.utf8)) as? [String: Any])
        let okResult = try #require(okEnv["result"] as? [String: Any])
        #expect(okResult["isError"] as? Bool == false)
        let okContent = try #require((okResult["content"] as? [[String: Any]])?.first)
        let okText = try #require(okContent["text"] as? String)
        #expect(okText.contains("CITATION_STATUS:VERIFIED"))
        #expect(okText.contains("Attention Is All You Need"))
    }

    @Test("MCP server requires explicit project/demo target and executes provenance search, PRISMA agreement, LSP diagnostics, diff, and citation gaps")
    func mcpServerExecutesRemainingDomainTools() throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-mcp-domain")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let isolatedEnv = ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path]

        // Without default project or allowDemoMode, omitting projectPath fails rather than silently loading demo data
        let strictServer = ScholarMCPServer(isOffline: true, environment: isolatedEnv)
        let missingTarget = strictServer.executeToolCall(name: "scholar_prisma_agreement", arguments: [:])
        #expect(missingTarget["isError"] as? Bool == true)

        let server = ScholarMCPServer(allowDemoMode: true, isOffline: true, environment: isolatedEnv)

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
        let tempDir = try makeTempDirectory(prefix: "scholaros-s20-direct")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let cli = ScholarCLIRunner(environment: ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path])

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
        #expect(verifyRun.exitCode == 3)
        #expect(verifyRun.stdout.contains("Verified=0"))
        #expect(!verifyRun.stdout.contains("VERIFIED_DOI"))

        let formatOut = try await cli.execute(arguments: ["format-bib", bibFile.path, "--style", "ieee"])
        #expect(formatOut.contains("[1]"))
        #expect(formatOut.contains("Deep learning"))

        let diagOut = try await cli.execute(arguments: ["diagnostics", texFile.path, "--bib", bibFile.path, "--offline"])
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

        let server = ScholarMCPServer(
            defaultProjectBundlePath: bundleURL.path,
            isOffline: true,
            environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path]
        )
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
        let tempDir = try makeTempDirectory(prefix: "scholaros-s27-mcp")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let server = ScholarMCPServer(
            isOffline: true,
            environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path]
        )

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
                firewallClass: .verified,
                firewallVerifiedSource: "Crossref",
                firewallVerifiedAtUTC: BibliographyEntry.formatUTCDay(Date())
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

    @Test("S32/S33 regression: verify-citations prints one class tag per entry, no Chinese in English output, defaults to online, and states when --offline skips online lookups")
    func s32AndS33VerifyCitationsOutputHasSingleTagNoChineseInEnglishAndHonestNoLookupNotice() async throws {
        // 12-entry recheck bibliography (3 real, 2 fabricated DOIs, 3 real DOIs with wrong title/year,
        // 2 without DOI, 2 retracted), copied into the repository from the acceptance harness.
        let bibPath = repositoryRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib").path
        #expect(FileManager.default.fileExists(atPath: bibPath))

        actor CallCounter {
            var count = 0
            func increment() { count += 1 }
        }
        let offlineCounter = CallCounter()
        let offlineSpyTransport = ClosureRegistrySession { req in
            await offlineCounter.increment()
            throw RegistryTransportError(kind: .transportError, detail: "--offline must send zero requests", url: req.url)
        }
        let offlineRunner = ScholarCLIRunner(registryTransport: offlineSpyTransport)
        let enOffline = try await offlineRunner.run(arguments: ["verify-citations", bibPath, "--offline", "--lang", "en"])
        let zhOffline = try await offlineRunner.run(arguments: ["verify-citations", bibPath, "--offline", "--lang", "zh"])
        #expect(await offlineCounter.count == 0)

        // M1 item 4 (S41): sentinel DOI `10.1234/fake.2026.99999` has valid ISO 26324 syntax, so offline it is UNVERIFIED rather than NOT_FOUND.
        for out in [enOffline, zhOffline] {
            #expect(out.exitCode == 1)
            #expect(out.stdout.contains("Evaluated=12 Verified=0 Drift=0 NotFound=0 Retracted=1 Unverified=11"))
            #expect(!out.stdout.contains("[VERIFIED]"))
            #expect(!out.stdout.contains("编造"))
            #expect(!out.stdout.lowercased().contains("fabricated"))
        }
        #expect(enOffline.stdout.contains("11 entries could not be verified, reasons: offline=11; results are incomplete."))
        #expect(zhOffline.stdout.contains("11 条没查成，原因：offline=11；结果不完整。"))
        #expect(enOffline.stdout.contains("--offline skips online registry lookups"))
        #expect(zhOffline.stdout.contains("已指定 --offline，本次不向外部注册库发网络请求"))
        #expect(!enOffline.stdout.lowercased().contains("(offline)"))
        #expect(!enOffline.stdout.lowercased().contains("unverified offline"))
        #expect(!zhOffline.stdout.contains("离线模式"))

        // S32: exactly one class tag per entry line, at the start of the line, in both languages.
        let classTags = CitationFirewallClass.allCases.map { "[\($0.rawValue)]" }
        for out in [enOffline, zhOffline] {
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
        #expect(!containsChineseCharacters(enOffline.stdout), "\(enOffline.stdout)")

        // Expected lines for three representative entries, in both languages.
        #expect(enOffline.stdout.contains("[UNVERIFIED] real_lecun: DOI '10.1038/nature14539' has valid ISO 26324 syntax. Not checked against any external registry."))
        #expect(enOffline.stdout.contains("[UNVERIFIED] fake_nonsentinel: DOI '10.1038/fake.2026.99999' has valid ISO 26324 syntax. Not checked against any external registry."))
        #expect(enOffline.stdout.contains("[RETRACTED] retracted_wakefield: DOI '10.1016/s0140-6736(97)11096-0' matched the built-in retraction hint list (built-in list, incomplete)."))
        #expect(zhOffline.stdout.contains("[UNVERIFIED] real_lecun: DOI '10.1038/nature14539' 语法格式合法；尚未向外部注册库核查。"))
        #expect(zhOffline.stdout.contains("[RETRACTED] retracted_wakefield: 撤稿提示：DOI '10.1016/S0140-6736(97)11096-0' 命中内置撤稿名单（内置名单，不完整）。"))

        // The MCP tool returns the same library notes: no "(offline)" label and no Chinese in them either.
        let mcpTempDir = try makeTempDirectory(prefix: "scholaros-s32-mcp")
        defer { try? FileManager.default.removeItem(at: mcpTempDir) }
        let rawBib = try String(contentsOfFile: bibPath, encoding: .utf8)
        let mcpResult = await ScholarMCPServer(
            isOffline: true,
            environment: ["HOME": mcpTempDir.path, "CFFIXED_USER_HOME": mcpTempDir.path]
        ).executeToolCallAsync(
            name: "scholar_verify_bibliography",
            arguments: ["bibtex": rawBib, "offline": true]
        )
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
        let fixtureReplay = try RegistryReplaySession(
            directoryURL: repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        )
        let recordedFixtureTransport = ClosureRegistrySession { req in
            let replayed = try await fixtureReplay.send(req)
            return RegistryHTTPResponse(
                statusCode: replayed.statusCode,
                body: replayed.body,
                headers: replayed.headers,
                origin: .network,
                fetchedAt: replayed.fetchedAt
            )
        }

        let recordRunner = ScholarCLIRunner(
            registryTransport: recordedFixtureTransport,
            registryClock: .immediate,
            environment: ["HOME": tempDir.appendingPathComponent("home-record", isDirectory: true).path]
        )
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
        #expect(recordedManifest.count == 4)

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
        #expect(byKey["retracted_seralini"]?.firewallClass == .retracted)
        #expect(byKey["retracted_wakefield"]?.firewallClass == .retracted)
        #expect(byKey["real_nodoi"]?.firewallClass == .unverified)
        #expect(byKey["real_nodoi"]?.reasons == [CitationUnverifiedReasonCode.noMatchInSearch.rawValue])
        #expect(byKey["fake_nodoi"]?.firewallClass == .unverified)
        #expect(byKey["fake_nodoi"]?.reasons == [CitationUnverifiedReasonCode.noMatchInSearch.rawValue])
        #expect(report1.unverifiedByReason == [CitationUnverifiedReasonCode.noMatchInSearch.rawValue: 2])

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

    @Test("M1 row 18 & item 8: fabricated DOI with x-firewall-class={VERIFIED} is ignored, noted in findings, omitted on export, and rejected by diagnostics/cite/MCP")
    func m1Stage03UntrustedBibFirewallClassIgnoredAndBlockedEverywhere() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m1-row18")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tamperedBib = """
        @article{fake_tampered,
          author           = {Whitfield, Eleanor and Patel, Raj},
          title            = {Quantum Gradient Descent in Biological Neural Networks},
          journal          = {Nature Machine Intelligence},
          year             = {2025},
          doi              = {10.1038/fake.2026.99999},
          x-firewall-class = {VERIFIED},
          x-firewall-note  = {Verified live metadata match against Crossref}
        }
        """
        let bibURL = tempDir.appendingPathComponent("tampered.bib")
        try tamperedBib.write(to: bibURL, atomically: true, encoding: .utf8)

        let texURL = tempDir.appendingPathComponent("draft.tex")
        try """
        \\documentclass{article}
        \\begin{document}
        Tampered citation \\cite{fake_tampered}.
        \\end{document}
        """.write(to: texURL, atomically: true, encoding: .utf8)

        // 1. BibTeXCodec ignores x-firewall-class/note on parse and never writes them on serialize
        let codec = BibTeXCodec()
        let parsed = try codec.parse(tamperedBib)
        let entry = try #require(parsed.first)
        #expect(entry.firewallClass == .unverified)
        #expect(entry.firewallAuditNote.isEmpty)

        let serialized = codec.serialize([entry])
        #expect(!serialized.contains("x-firewall-class"))
        #expect(!serialized.contains("x-firewall-note"))

        // 2. verify-citations (offline & replay) is NOT VERIFIED and findings note untrusted declaration
        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let isolatedEnv = ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path]
        let runner = ScholarCLIRunner(environment: isolatedEnv)
        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry")
        let replayJSONRun = try await runner.run(
            arguments: ["verify-citations", bibURL.path, "--registry-replay", registryDir.path, "--json", "--lang", "en"]
        )
        #expect(replayJSONRun.exitCode == 1)
        let reportObj = try #require(JSONSerialization.jsonObject(with: Data(replayJSONRun.stdout.utf8)) as? [String: Any])
        #expect(reportObj["complete"] as? Bool == true)
        let verdicts = try #require(reportObj["verdicts"] as? [[String: Any]])
        let firstVerdict = try #require(verdicts.first)
        #expect(firstVerdict["firewallClass"] as? String == "NOT_FOUND")
        #expect(firstVerdict["insertable"] as? Bool == false)
        #expect(firstVerdict["confidenceScore"] == nil)
        let findings = try #require(firstVerdict["findings"] as? [[String: Any]])
        #expect(findings.contains { (($0["detail"] as? String) ?? "").contains("VERIFIED") })

        let zhOfflineRun = try await runner.run(
            arguments: ["verify-citations", bibURL.path, "--offline", "--lang", "zh"]
        )
        #expect(!zhOfflineRun.stdout.contains("编造"))
        #expect(!zhOfflineRun.stdout.lowercased().contains("fabricated"))

        // 3. diagnostics emits ERR_UNVERIFIED_CITATION on draft.tex citing fake_tampered
        let diagRun = try await runner.run(
            arguments: ["diagnostics", texURL.path, "--bib", bibURL.path, "--registry-replay", registryDir.path, "--lang", "en"]
        )
        #expect(diagRun.stdout.contains("ERR_UNVERIFIED_CITATION"))

        // 4. Import into project bundle: CLI cite and MCP scholar_cite_key both reject fake_tampered
        let bundleURL = tempDir.appendingPathComponent("Tampered.scholarproj")
        let db = try ScholarProjectDatabase(bundleURL: bundleURL, seedDemoIfEmpty: false)
        try db.upsertBibliographyEntry(entry)
        db.close()

        let citeRes = await runner.runWithExitStatus(
            arguments: ["cite", "fake_tampered", "--project", bundleURL.path, "--offline"]
        )
        #expect(citeRes.exitCode != 0)
        #expect(citeRes.stderr.contains("ERR_UNVERIFIED_CITATION"))

        let mcp = ScholarMCPServer(
            defaultProjectBundlePath: bundleURL.path,
            isOffline: true,
            environment: isolatedEnv
        )
        let mcpCall = mcp.executeToolCall(
            name: "scholar_cite_key",
            arguments: ["citeKey": "fake_tampered", "style": "apa7"]
        )
        #expect(mcpCall["isError"] as? Bool == true)
        let mcpText = ((mcpCall["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(mcpText.contains("ERR_UNVERIFIED_CITATION"))
    }

    @Test("M1 item 1, 2 & 3 (Stage 04): CLI verify-citations replay formats doi.org NOT_FOUND, wrong-DOI DRIFT, CNKI registered_no_metadata, and Crossref+OpenAlex RETRACTED in en and zh")
    func m1Stage04CLIVerifyCitationsLocalizationAndLookupOrderReplay() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m1-stage04-cli")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stage04BibURL = tempDir.appendingPathComponent("stage04.bib")
        try """
        @article{fake_nonsentinel,
          author  = {Whitfield, Eleanor and Patel, Raj},
          title   = {Quantum Gradient Descent in Biological Neural Networks},
          journal = {Nature Machine Intelligence},
          year    = {2025},
          doi     = {10.1038/fake.2026.99999}
        }
        @article{lstm_wrong_doi,
          author  = {Hochreiter, Sepp and Schmidhuber, J{\\"u}rgen},
          title   = {Long Short-Term Memory},
          journal = {Neural Computation},
          year    = {1997},
          doi     = {10.1162/neco.1997.99999}
        }
        @inproceedings{lipics_icalp_2015,
          author    = {Halld{\\'o}rsson, Magn{\\'u}s M.},
          title     = {ICALP 2015 Frontmatter},
          booktitle = {LIPIcs},
          year      = {2015},
          doi       = {10.4230/LIPIcs.ICALP.2015.1}
        }
        @article{yang2024jos,
          author  = {Yang, Zezhou and Chen, Sirong and Gao, Cuiyun and Li, Zhenhao and Li, Ge and Lyu, Michael},
          title   = {Deep Learning Based Code Generation Methods: Literature Review},
          journal = {Journal of Software},
          year    = {2024},
          doi     = {10.13328/j.cnki.jos.006981}
        }
        @article{retracted_wakefield,
          author  = {Wakefield, AJ and others},
          title   = {Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children},
          journal = {The Lancet},
          year    = {1998},
          doi     = {10.1016/S0140-6736(97)11096-0}
        }
        """.write(to: stage04BibURL, atomically: true, encoding: .utf8)

        let runner = ScholarCLIRunner()
        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry")

        let zhRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", stage04BibURL.path, "--registry-replay", registryDir.path, "--lang", "zh"]
        )
        #expect(zhRun.exitCode == 1)
        #expect(zhRun.stdout.contains("Evaluated=5 Verified=0 Drift=1 NotFound=2 Retracted=1 Unverified=1"))
        #expect(zhRun.stdout.contains("1 条没查成，原因：registered_no_metadata=1；结果不完整。"))
        #expect(zhRun.stdout.contains("doi.org 说这个 DOI 没有注册（10.1038/fake.2026.99999）"))
        #expect(zhRun.stdout.contains("doi.org 说这个 DOI 没有注册（10.4230/LIPIcs.ICALP.2015.1）"))
        #expect(zhRun.stdout.contains("DOI错误（本地：10.1162/neco.1997.99999，Crossref：10.1162/neco.1997.9.8.1735）"))
        #expect(zhRun.stdout.contains("doi.org 表明该 DOI 已注册，但两个元数据源里都没有"))
        #expect(zhRun.stdout.contains("OpenAlex 标明该文献已撤稿（撤稿字段：is_retracted）"))
        #expect(!zhRun.stdout.contains("内置名单，不完整"))

        let enRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", stage04BibURL.path, "--registry-replay", registryDir.path, "--lang", "en"]
        )
        #expect(enRun.exitCode == 1)
        #expect(enRun.stdout.contains("Evaluated=5 Verified=0 Drift=1 NotFound=2 Retracted=1 Unverified=1"))
        #expect(enRun.stdout.contains("doi.org reported that DOI '10.1038/fake.2026.99999' is not registered"))
        #expect(enRun.stdout.contains("doi.org reported that DOI '10.4230/lipics.icalp.2015.1' is not registered"))
        #expect(enRun.stdout.contains("10.1162/neco.1997.9.8.1735"))
        #expect(enRun.stdout.contains("registered_no_metadata"))
        #expect(enRun.stdout.contains("doi.org reported DOI '10.13328/j.cnki.jos.006981' is registered"))
    }

    @Test("M1 item 3 (Stage 05): CLI verify-citations replay on stage05-arxiv-pmid-search.bib formats arXiv, PubMed, dual DOI+arXiv, and identifierless verdicts in en, zh, and json")
    func m1Stage05CLIVerifyCitationsReplayFormatsArXivPubMedDualAndIdentifierlessInEnZhAndJSON() async throws {
        let runner = ScholarCLIRunner()
        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry")
        let stage05BibURL = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry-sources/stage05-arxiv-pmid-search.bib")

        let jsonRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", stage05BibURL.path, "--registry-replay", registryDir.path, "--json", "--lang", "en"]
        )
        #expect(jsonRun.exitCode == 1)
        let report = try JSONDecoder().decode(CitationFirewallAuditReport.self, from: Data(jsonRun.stdout.utf8))
        #expect(report.totalEvaluated == 10)
        #expect(report.verifiedCount == 5)
        #expect(report.driftCount == 1)
        #expect(report.notFoundCount == 2)
        #expect(report.retractedCount == 1)
        #expect(report.unverifiedCount == 1)
        #expect(report.complete == false)
        #expect(report.unverifiedByReason == [CitationUnverifiedReasonCode.noMatchInSearch.rawValue: 1])

        let byKey = Dictionary(uniqueKeysWithValues: report.verdicts.map { ($0.citeKey, $0) })
        #expect(byKey["arxiv_real_vaswani"]?.firewallClass == .verified)
        #expect(byKey["arxiv_nonexistent"]?.firewallClass == .notFound)
        #expect(byKey["arxiv_nonexistent"]?.reasons == ["arxiv_not_found"])
        #expect(byKey["arxiv_wrong_title"]?.firewallClass == .drift)
        #expect(byKey["doi_and_arxiv_resnet"]?.firewallClass == .verified)
        #expect(byKey["doi_and_arxiv_resnet"]?.sources.map(\.source) == ["Crossref", "OpenAlex", "arXiv"])
        #expect(byKey["dao2022"]?.firewallClass == .verified)
        #expect(byKey["pmid_real_ito2015"]?.firewallClass == .verified)
        #expect(byKey["pmid_nonexistent"]?.firewallClass == .notFound)
        #expect(byKey["pmid_nonexistent"]?.reasons == ["pmid_not_found"])
        #expect(byKey["pmid_retracted_wakefield"]?.firewallClass == .retracted)
        #expect(byKey["pmid_retracted_wakefield"]?.reasons == ["retracted_pubmed"])
        #expect(byKey["nodoi_real_lecun"]?.firewallClass == .verified)
        #expect(byKey["nodoi_real_lecun"]?.fields.contains { $0.field == "doi" && $0.remoteValue == "10.1038/nature14539" } == true)
        #expect(byKey["draft2024unverified"]?.firewallClass == .unverified)
        #expect(byKey["draft2024unverified"]?.reasons == [CitationUnverifiedReasonCode.noMatchInSearch.rawValue])

        let zhRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", stage05BibURL.path, "--registry-replay", registryDir.path, "--lang", "zh"]
        )
        #expect(zhRun.exitCode == 1)
        #expect(zhRun.stdout.contains("arXiv 说没有这个编号（arXiv:2401.99999）"))
        #expect(zhRun.stdout.contains("PubMed 说没有这个编号（PMID:99999999）"))
        #expect(zhRun.stdout.contains("PubMed 标明该文献已撤稿（撤稿字段：pubtype (Retracted Publication)）"))
        #expect(zhRun.stdout.contains("DOI：10.1038/nature14539"))
        #expect(zhRun.stdout.contains("两个数据源都没有找到，可能文献并不存在，也可能是数据源没有收录"))
        #expect(!zhRun.stdout.contains("编造"))

        let enRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", stage05BibURL.path, "--registry-replay", registryDir.path, "--lang", "en"]
        )
        #expect(enRun.exitCode == 1)
        #expect(enRun.stdout.contains("arXiv reported that identifier 'arXiv:2401.99999' does not exist"))
        #expect(enRun.stdout.contains("PubMed reported that identifier 'PMID:99999999' does not exist"))
        #expect(enRun.stdout.contains("PubMed marks this publication as retracted (field: pubtype (Retracted Publication))"))
        #expect(enRun.stdout.contains("DOI: 10.1038/nature14539"))
        #expect(enRun.stdout.contains("may not exist, or it may not be indexed"))
        #expect(!enRun.stdout.lowercased().contains("fabricated"))
    }

    // MARK: - 9. M1 Item 8 (Stage 06): CLI Online-by-Default, Exit Codes (0/1/3/2), `--verbose`, and Rows 15-17

    @Test("M1 item 8 (Stage 06): verify-citations defaults to online, --offline and --registry-replay send 0 live requests, and --verbose logs one stderr line per HTTP request")
    func m1Stage06DefaultOnlineOfflineAndReplayTransportRoutingAndVerboseTelemetry() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage06-verbose")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let fixtureReplay = try RegistryReplaySession(directoryURL: registryDir)

        let singleBibURL = tempDir.appendingPathComponent("lecun.bib")
        try """
        @article{real_lecun,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          volume  = {521},
          pages   = {436--444},
          doi     = {10.1038/nature14539}
        }
        """.write(to: singleBibURL, atomically: true, encoding: .utf8)

        actor TransportTracker {
            var count = 0
            func record() -> Int {
                count += 1
                return count
            }
        }
        let onlineTracker = TransportTracker()
        let mockNetworkTransport = ClosureRegistrySession { req in
            _ = await onlineTracker.record()
            let replayed = try await fixtureReplay.send(req)
            return RegistryHTTPResponse(
                statusCode: replayed.statusCode,
                body: replayed.body,
                headers: replayed.headers,
                origin: .network,
                fetchedAt: replayed.fetchedAt
            )
        }

        let onlineRunner = ScholarCLIRunner(
            registryTransport: mockNetworkTransport,
            environment: ["HOME": tempDir.appendingPathComponent("home-online", isDirectory: true).path]
        )

        let helpEN = try await onlineRunner.execute(arguments: ["--help", "--lang", "en"])
        let helpZH = try await onlineRunner.execute(arguments: ["--help", "--lang", "zh"])
        #expect(helpEN.contains("--verbose"))
        #expect(helpZH.contains("--verbose"))

        // 1. Default without flags is online and emits per-request stderr telemetry with --verbose
        let onlineRes = await onlineRunner.runWithExitStatus(
            arguments: ["verify-citations", singleBibURL.path, "--verbose", "--lang", "en"]
        )
        #expect(onlineRes.exitCode == 0)
        #expect(onlineRes.stdout.contains("Evaluated=1 Verified=1"))
        #expect(await onlineTracker.count == 2)

        let onlineStderrLines = onlineRes.stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(onlineStderrLines.count == 2)
        #expect(onlineStderrLines.contains {
            $0.contains("source=Crossref")
                && $0.contains("url=https://api.crossref.org/works/10.1038/nature14539")
                && $0.contains("status=200")
                && $0.contains("elapsed=")
                && $0.contains("origin=network")
        })
        #expect(onlineStderrLines.contains {
            $0.contains("source=OpenAlex")
                && $0.contains("url=https://api.openalex.org/works/https://doi.org/10.1038/nature14539")
                && $0.contains("status=200")
                && $0.contains("elapsed=")
                && $0.contains("origin=network")
        })

        // 2. Without --verbose, stderr is empty on success
        let quietRes = await onlineRunner.runWithExitStatus(
            arguments: ["verify-citations", singleBibURL.path, "--lang", "en"]
        )
        #expect(quietRes.exitCode == 0)
        #expect(quietRes.stderr.isEmpty)

        // 3. --offline sends 0 requests and emits 0 HTTP lines even with --verbose
        let offlineTracker = TransportTracker()
        let failIfCalledTransport = ClosureRegistrySession { req in
            _ = await offlineTracker.record()
            throw RegistryTransportError(kind: .transportError, detail: "Must not be called", url: req.url)
        }
        let guardedRunner = ScholarCLIRunner(registryTransport: failIfCalledTransport)

        let offlineVerbose = await guardedRunner.runWithExitStatus(
            arguments: ["verify-citations", singleBibURL.path, "--offline", "--verbose", "--lang", "en"]
        )
        #expect(offlineVerbose.exitCode == 3)
        #expect(await offlineTracker.count == 0)
        #expect(offlineVerbose.stderr.isEmpty)

        // 4. --registry-replay sends 0 live requests and logs origin=replay on stderr under --verbose
        let replayVerbose = await guardedRunner.runWithExitStatus(
            arguments: ["verify-citations", singleBibURL.path, "--registry-replay", registryDir.path, "--verbose", "--lang", "en"]
        )
        #expect(replayVerbose.exitCode == 0)
        #expect(await offlineTracker.count == 0)
        #expect(replayVerbose.stdout.hasPrefix("[REPLAY]"))
        let replayStderrLines = replayVerbose.stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(replayStderrLines.count == 2)
        #expect(replayStderrLines.allSatisfy { $0.contains("origin=replay") && $0.contains("status=200") })

        // 5. Retrying 429 -> 200 logs each HTTP attempt on stderr under --verbose
        let retryTracker = TransportTracker()
        let retryTransport = ClosureRegistrySession { req in
            let attempt = await retryTracker.record()
            if req.url?.host == "api.crossref.org", attempt == 1 {
                return RegistryHTTPResponse(
                    statusCode: 429,
                    body: Data("Too Many Requests".utf8),
                    headers: ["Retry-After": "1"],
                    origin: .network,
                    fetchedAt: "2026-11-16T00:00:00Z"
                )
            }
            let replayed = try await fixtureReplay.send(req)
            return RegistryHTTPResponse(
                statusCode: replayed.statusCode,
                body: replayed.body,
                headers: replayed.headers,
                origin: .network,
                fetchedAt: replayed.fetchedAt
            )
        }
        let retryRunner = ScholarCLIRunner(
            registryTransport: retryTransport,
            registryClock: .immediate,
            environment: ["HOME": tempDir.appendingPathComponent("home-retry", isDirectory: true).path]
        )
        let retryVerbose = await retryRunner.runWithExitStatus(
            arguments: ["verify-citations", singleBibURL.path, "--verbose", "--lang", "en"]
        )
        #expect(retryVerbose.exitCode == 0)
        let retryStderrLines = retryVerbose.stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(retryStderrLines.count == 3)
        #expect(retryStderrLines.first?.contains("status=429") == true)
    }

    @Test("M1 acceptance row 15 (Stage 06): --offline and transport-denied online runs produce 0 VERIFIED, 0 NOT_FOUND except malformed DOI syntax, and transport_error reasons")
    func m1Stage06Row15OfflineAndTransportDeniedNeverVerifyAndOnlyInvalidSyntaxIsNotFound() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage06-row15")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseRecheck = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib"),
            encoding: .utf8
        )
        let row15BibURL = tempDir.appendingPathComponent("row15.bib")
        let row15Bib = baseRecheck + """

        @article{malformed_doi_syntax,
          author  = {Test, Author},
          title   = {Paper With Broken DOI Syntax},
          journal = {Journal},
          year    = {2024},
          doi     = {not-a-valid-doi}
        }
        """
        try row15Bib.write(to: row15BibURL, atomically: true, encoding: .utf8)

        let singleValidBibURL = tempDir.appendingPathComponent("single_valid.bib")
        try """
        @article{real_lecun,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          doi     = {10.1038/nature14539}
        }
        """.write(to: singleValidBibURL, atomically: true, encoding: .utf8)

        let deniedTransport = ClosureRegistrySession { req in
            throw RegistryTransportError(
                kind: .transportError,
                detail: "Simulated sandbox-exec network denial",
                url: req.url
            )
        }
        let runner = ScholarCLIRunner(
            registryTransport: deniedTransport,
            registryClock: .immediate,
            environment: ["HOME": tempDir.appendingPathComponent("home-denied", isDirectory: true).path]
        )

        // 1. --offline on the 13-entry list (12 recheck + 1 syntactically invalid DOI)
        let offlineJSONRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", row15BibURL.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(offlineJSONRun.exitCode == 1)
        let offlineReport = try JSONDecoder().decode(
            CitationFirewallAuditReport.self,
            from: Data(offlineJSONRun.stdout.utf8)
        )
        #expect(offlineReport.verifiedCount == 0)
        #expect(offlineReport.notFoundCount == 1)
        let offlineNotFoundKeys = offlineReport.verdicts.filter { $0.firewallClass == .notFound }.map(\.citeKey)
        #expect(offlineNotFoundKeys == ["malformed_doi_syntax"])

        // Valid-syntax non-retracted entry under --offline exits 3
        let offlineSingleRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", singleValidBibURL.path, "--offline", "--lang", "en"]
        )
        #expect(offlineSingleRun.exitCode == 3)

        // 2. Online (without --offline) when network is denied on all 13 entries:
        //    0 VERIFIED, only malformed_doi_syntax is NOT_FOUND, every UNVERIFIED has reason transport_error
        let deniedFullRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", row15BibURL.path, "--json", "--lang", "en"]
        )
        #expect(deniedFullRun.exitCode == 1)
        let deniedFullReport = try JSONDecoder().decode(
            CitationFirewallAuditReport.self,
            from: Data(deniedFullRun.stdout.utf8)
        )
        #expect(deniedFullReport.verifiedCount == 0)
        #expect(deniedFullReport.notFoundCount == 1)
        #expect(deniedFullReport.retractedCount == 1)
        #expect(deniedFullReport.unverifiedCount == 11)
        #expect(deniedFullReport.verdicts.filter { $0.firewallClass == .notFound }.map(\.citeKey) == ["malformed_doi_syntax"])
        #expect(deniedFullReport.unverifiedByReason == [CitationUnverifiedReasonCode.transportError.rawValue: 11])
        for v in deniedFullReport.verdicts where v.firewallClass == .unverified {
            #expect(v.reasons == [CitationUnverifiedReasonCode.transportError.rawValue])
        }

        // Valid-syntax non-retracted entry under network denial exits 3
        let deniedSingleRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", singleValidBibURL.path, "--json", "--lang", "en"]
        )
        #expect(deniedSingleRun.exitCode == 3)
        let deniedSingleReport = try JSONDecoder().decode(
            CitationFirewallAuditReport.self,
            from: Data(deniedSingleRun.stdout.utf8)
        )
        #expect(deniedSingleReport.verifiedCount == 0)
        #expect(deniedSingleReport.notFoundCount == 0)
        #expect(deniedSingleReport.unverifiedCount == 1)
        #expect(deniedSingleReport.unverifiedByReason == [CitationUnverifiedReasonCode.transportError.rawValue: 1])
    }

    @Test("M1 acceptance row 16 (Stage 06): exit codes 0 (all VERIFIED), 1 (DRIFT/NOT_FOUND/RETRACTED), 3 (only VERIFIED+UNVERIFIED via 500 replay), and 2 (missing/invalid/unparseable BibTeX)")
    func m1Stage06Row16ExitCodesZeroOneThreeTwo() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage06-row16")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let failTransport = ClosureRegistrySession { req in
            throw RegistryTransportError(kind: .transportError, detail: "Replay only", url: req.url)
        }
        let runner = ScholarCLIRunner(registryTransport: failTransport, registryClock: .immediate)

        let cleanRealEntries = """
        @article{real_lecun,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          volume  = {521},
          pages   = {436--444},
          doi     = {10.1038/nature14539}
        }
        @misc{arxiv_real_vaswani,
          author        = {Vaswani, Ashish and Shazeer, Noam and Parmar, Niki and Uszkoreit, Jakob and Jones, Llion and Gomez, Aidan N. and Kaiser, Lukasz and Polosukhin, Illia},
          title         = {Attention Is All You Need},
          year          = {2017},
          eprint        = {1706.03762},
          archiveprefix = {arXiv}
        }
        @article{pmid_real_ito2015,
          author  = {Ito, Hiroshi T. and Zhang, Sheng-Jia and Witter, Menno P. and Moser, Edvard I. and Moser, May-Britt},
          title   = {A prefrontal-thalamo-hippocampal circuit for goal-directed spatial navigation},
          journal = {Nature},
          year    = {2015},
          pmid    = {26017312}
        }
        """

        // 1. Exit code 0: all real clean entries -> VERIFIED=3
        let cleanBibURL = tempDir.appendingPathComponent("clean3.bib")
        try cleanRealEntries.write(to: cleanBibURL, atomically: true, encoding: .utf8)
        let exit0Run = await runner.runWithExitStatus(
            arguments: ["verify-citations", cleanBibURL.path, "--registry-replay", registryDir.path, "--lang", "en"]
        )
        #expect(exit0Run.exitCode == 0)
        #expect(exit0Run.stdout.contains("Evaluated=3 Verified=3 Drift=0 NotFound=0 Retracted=0 Unverified=0"))

        // 2. Exit code 1: mixing in 1 fabricated entry (NOT_FOUND), or DRIFT, or RETRACTED
        let mixedFakeBibURL = tempDir.appendingPathComponent("mixed_fake.bib")
        try (cleanRealEntries + """

        @article{fake_nonsentinel,
          author  = {Whitfield, Eleanor and Patel, Raj},
          title   = {Quantum Gradient Descent in Biological Neural Networks},
          journal = {Nature Machine Intelligence},
          year    = {2025},
          doi     = {10.1038/fake.2026.99999}
        }
        """).write(to: mixedFakeBibURL, atomically: true, encoding: .utf8)
        let exit1NotFoundRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", mixedFakeBibURL.path, "--registry-replay", registryDir.path, "--lang", "en"]
        )
        #expect(exit1NotFoundRun.exitCode == 1)

        let mixedDriftBibURL = tempDir.appendingPathComponent("mixed_drift.bib")
        try (cleanRealEntries + """

        @article{wrongtitle,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Completely Wrong Title for Deep Learning},
          journal = {Nature},
          year    = {2015},
          doi     = {10.1038/nature14539}
        }
        """).write(to: mixedDriftBibURL, atomically: true, encoding: .utf8)
        let exit1DriftRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", mixedDriftBibURL.path, "--registry-replay", registryDir.path, "--lang", "en"]
        )
        #expect(exit1DriftRun.exitCode == 1)

        // 3. Exit code 3: same 3 real clean entries, but one entry's recorded request in replay is mutated to HTTP 500
        let replay500Dir = tempDir.appendingPathComponent("replay-one-500", isDirectory: true)
        try FileManager.default.copyItem(at: registryDir, to: replay500Dir)
        let origManifest = try JSONDecoder().decode(
            RegistryRecordingManifest.self,
            from: Data(contentsOf: replay500Dir.appendingPathComponent("manifest.json"))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        func sha256Hex(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        var updatedMetaHashes = origManifest.metaFilesSHA256 ?? [:]
        let updatedItems = try origManifest.items.map { item -> RegistryRecordedItem in
            guard item.url.contains("id=26017312") else { return item }
            let raw500 = Data("Internal Server Error".utf8)
            try raw500.write(to: replay500Dir.appendingPathComponent(item.rawFile), options: .atomic)
            let mutatedItem = RegistryRecordedItem(
                slug: item.slug,
                service: item.service,
                url: item.url,
                status: 500,
                contentType: "text/plain",
                requestedAt: item.requestedAt,
                responseDateHeader: item.responseDateHeader,
                requestHeaders: item.requestHeaders,
                responseHeaders: ["Content-Type": "text/plain"],
                rawFile: item.rawFile,
                byteLength: raw500.count,
                sha256: sha256Hex(raw500),
                attempts: item.attempts
            )
            let metaFileName = "\(item.slug).meta.json"
            let metaData = try encoder.encode(mutatedItem)
            try metaData.write(to: replay500Dir.appendingPathComponent(metaFileName), options: .atomic)
            updatedMetaHashes[metaFileName] = sha256Hex(metaData)
            return mutatedItem
        }
        let mutatedManifest = RegistryRecordingManifest(
            startedAt: origManifest.startedAt,
            completedAt: origManifest.completedAt,
            userAgent: origManifest.userAgent,
            count: updatedItems.count,
            totalHTTPRequestsSent: origManifest.totalHTTPRequestsSent,
            items: updatedItems,
            metaFilesSHA256: updatedMetaHashes
        )
        try encoder.encode(mutatedManifest).write(
            to: replay500Dir.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        let exit3Run = await runner.runWithExitStatus(
            arguments: ["verify-citations", cleanBibURL.path, "--registry-replay", replay500Dir.path, "--json", "--lang", "en"]
        )
        #expect(exit3Run.exitCode == 3)
        let exit3Report = try JSONDecoder().decode(
            CitationFirewallAuditReport.self,
            from: Data(exit3Run.stdout.utf8)
        )
        #expect(exit3Report.verifiedCount == 2)
        #expect(exit3Report.driftCount == 0)
        #expect(exit3Report.notFoundCount == 0)
        #expect(exit3Report.retractedCount == 0)
        #expect(exit3Report.unverifiedCount == 1)
        #expect(exit3Report.unverifiedByReason == [CitationUnverifiedReasonCode.serverError.rawValue: 1])
        #expect(exit3Report.complete == false)

        // 4. Exit code 2: missing file, invalid flag, broken BibTeX brace, and non-BibTeX garbage file
        let missingRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", tempDir.appendingPathComponent("missing.bib").path]
        )
        #expect(missingRun.exitCode == 2)

        let badFlagRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", cleanBibURL.path, "--unknown-flag"]
        )
        #expect(badFlagRun.exitCode == 2)

        let unclosedBibURL = tempDir.appendingPathComponent("unclosed.bib")
        try "@article{broken_key,\n  title = {Unclosed brace\n".write(to: unclosedBibURL, atomically: true, encoding: .utf8)
        let unclosedRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", unclosedBibURL.path, "--offline"]
        )
        #expect(unclosedRun.exitCode == 2)

        let garbageBibURL = tempDir.appendingPathComponent("garbage.bib")
        try "{\"not\": \"bibtex\"}".write(to: garbageBibURL, atomically: true, encoding: .utf8)
        let garbageRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", garbageBibURL.path, "--offline"]
        )
        #expect(garbageRun.exitCode == 2)
    }

    @Test("M1 acceptance row 17 (Stage 06): full fixture replay JSON schema, DRIFT fields, UNVERIFIED reason set, zero confidenceScore, incomplete summary line right after first line, and no fabricated wording")
    func m1Stage06Row17JSONSchemaCompletenessSummaryLineOrderAndNoFabricatedWording() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage06-row17")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let recheckBib = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib"),
            encoding: .utf8
        )
        let stage05Bib = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Tests/Fixtures/registry-sources/stage05-arxiv-pmid-search.bib"),
            encoding: .utf8
        )
        let combinedBibURL = tempDir.appendingPathComponent("combined22.bib")
        try (recheckBib + "\n" + stage05Bib).write(to: combinedBibURL, atomically: true, encoding: .utf8)

        let failTransport = ClosureRegistrySession { req in
            throw RegistryTransportError(kind: .transportError, detail: "Replay only", url: req.url)
        }
        let runner = ScholarCLIRunner(registryTransport: failTransport)

        let jsonRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", combinedBibURL.path, "--registry-replay", registryDir.path, "--json", "--lang", "en"]
        )
        #expect(jsonRun.exitCode == 1)

        let rawObj = try JSONSerialization.jsonObject(with: Data(jsonRun.stdout.utf8))
        let topDict = try #require(rawObj as? [String: Any])
        #expect(topDict["complete"] as? Bool == false)
        let byReason = try #require(topDict["unverifiedByReason"] as? [String: Int])
        #expect(byReason == [CitationUnverifiedReasonCode.noMatchInSearch.rawValue: 3])

        let allowedUnverifiedCodes = Set(CitationUnverifiedReasonCode.allCases.map(\.rawValue))
        #expect(allowedUnverifiedCodes.count == 11)

        let verdicts = try #require(topDict["verdicts"] as? [[String: Any]])
        #expect(verdicts.count == 22)

        for v in verdicts {
            let fClass = try #require(v["firewallClass"] as? String)
            let reasons = try #require(v["reasons"] as? [String])
            let sources = try #require(v["sources"] as? [[String: Any]])
            let insertable = try #require(v["insertable"] as? Bool)
            let fields = try #require(v["fields"] as? [[String: Any]])
            _ = sources

            #expect(insertable == (fClass == "VERIFIED"))
            if fClass == "DRIFT" {
                #expect(!fields.isEmpty, "DRIFT verdict \(v["citeKey"] ?? "?") must have non-empty fields")
            }
            if fClass == "UNVERIFIED" {
                #expect(!reasons.isEmpty, "UNVERIFIED verdict \(v["citeKey"] ?? "?") must have reason codes")
                for code in reasons {
                    #expect(allowedUnverifiedCodes.contains(code), "Unexpected UNVERIFIED reason code: \(code)")
                }
            }
        }

        func containsKeyRecursively(_ value: Any, key targetKey: String) -> Bool {
            if let dict = value as? [String: Any] {
                if dict.keys.contains(targetKey) { return true }
                return dict.values.contains { containsKeyRecursively($0, key: targetKey) }
            }
            if let arr = value as? [Any] {
                return arr.contains { containsKeyRecursively($0, key: targetKey) }
            }
            return false
        }
        #expect(!containsKeyRecursively(rawObj, key: "confidenceScore"))

        // Text output checks in ZH and EN (both replay and offline): incomplete line immediately follows Evaluated=...
        let zhTextRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", combinedBibURL.path, "--registry-replay", registryDir.path, "--lang", "zh"]
        )
        let enTextRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", combinedBibURL.path, "--registry-replay", registryDir.path, "--lang", "en"]
        )
        let zhOfflineRun = await runner.runWithExitStatus(
            arguments: ["verify-citations", combinedBibURL.path, "--offline", "--lang", "zh"]
        )

        for (out, expectedSubstring) in [
            (zhTextRun.stdout, "3 条没查成，原因：no_match_in_search=3；结果不完整。"),
            (enTextRun.stdout, "3 entries could not be verified, reasons: no_match_in_search=3; results are incomplete."),
            (zhOfflineRun.stdout, "21 条没查成，原因：offline=21；结果不完整。")
        ] {
            let lines = out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let evalIdx = try #require(lines.firstIndex { $0.hasPrefix("Evaluated=") })
            #expect(evalIdx + 1 < lines.count)
            #expect(lines[evalIdx + 1] == expectedSubstring)
            #expect(!out.contains("编造"))
            #expect(!out.lowercased().contains("fabricated"))
        }
    }

    // MARK: - 10. M1 Item 7 (Stage 07): SQLite Response Cache, CLI Flags & Grammar Fixes

    @Test("M1 Stage 07: incomplete unverified summary uses singular '1 entry' when unverifiedCount == 1 and plural 'entries' otherwise")
    func m1Stage07SingularAndPluralUnverifiedEntryGrammar() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage07-singular")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let oneBibURL = tempDir.appendingPathComponent("one.bib")
        try """
        @article{real_lecun,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          doi     = {10.1038/nature14539}
        }
        """.write(to: oneBibURL, atomically: true, encoding: .utf8)

        let twoBibURL = tempDir.appendingPathComponent("two.bib")
        try """
        @article{real_lecun,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          doi     = {10.1038/nature14539}
        }
        @misc{arxiv_real_vaswani,
          author        = {Vaswani, Ashish},
          title         = {Attention Is All You Need},
          year          = {2017},
          eprint        = {1706.03762},
          archiveprefix = {arXiv}
        }
        """.write(to: twoBibURL, atomically: true, encoding: .utf8)

        let runner = ScholarCLIRunner()
        let oneOffline = await runner.runWithExitStatus(
            arguments: ["verify-citations", oneBibURL.path, "--offline", "--lang", "en"]
        )
        #expect(oneOffline.exitCode == 3)
        #expect(oneOffline.stdout.contains("1 entry could not be verified, reasons: offline=1; results are incomplete."))
        #expect(!oneOffline.stdout.contains("1 entries could not be verified"))

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry")
        let stage05BibURL = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry-sources/stage05-arxiv-pmid-search.bib")
        let oneReplay = await runner.runWithExitStatus(
            arguments: ["verify-citations", stage05BibURL.path, "--registry-replay", registryDir.path, "--lang", "en"]
        )
        #expect(oneReplay.exitCode == 1)
        #expect(oneReplay.stdout.contains("1 entry could not be verified, reasons: no_match_in_search=1; results are incomplete."))
        #expect(!oneReplay.stdout.contains("1 entries could not be verified"))

        let twoOffline = await runner.runWithExitStatus(
            arguments: ["verify-citations", twoBibURL.path, "--offline", "--lang", "en"]
        )
        #expect(twoOffline.exitCode == 3)
        #expect(twoOffline.stdout.contains("2 entries could not be verified, reasons: offline=2; results are incomplete."))
    }

    @Test("M1 item 7 (Stage 07): --registry-replay uses cache ONLY when SCHOLAR_CACHE_DIR is explicitly set, updates REPLAY banner honestly, sends 0 replay requests on run 2, and never touches default HOME cache")
    func m1Stage07CLIReplayWithScholarCacheDirBannerZeroRequestsAndDefaultReplayIsolation() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage07-replay-cache")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let isolatedHome = tempDir.appendingPathComponent("isolated-home", isDirectory: true)
        let explicitCacheDir = tempDir.appendingPathComponent("explicit-cache", isDirectory: true)

        let bibURL = tempDir.appendingPathComponent("replay_cache.bib")
        try """
        @article{real_lecun,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          volume  = {521},
          pages   = {436--444},
          doi     = {10.1038/nature14539}
        }
        @misc{arxiv_real_vaswani,
          author        = {Vaswani, Ashish and Shazeer, Noam and Parmar, Niki and Uszkoreit, Jakob and Jones, Llion and Gomez, Aidan N. and Kaiser, Lukasz and Polosukhin, Illia},
          title         = {Attention Is All You Need},
          year          = {2017},
          eprint        = {1706.03762},
          archiveprefix = {arXiv}
        }
        @article{fake_nonsentinel,
          author  = {Whitfield, Eleanor and Patel, Raj},
          title   = {Quantum Gradient Descent in Biological Neural Networks},
          journal = {Nature Machine Intelligence},
          year    = {2026},
          doi     = {10.1038/fake.2026.99999}
        }
        """.write(to: bibURL, atomically: true, encoding: .utf8)

        let fixedDate = Date(timeIntervalSince1970: 1_794_817_800) // 2026-11-16T08:30:00Z
        let clock = ClosureRegistryClock(now: { 0 }, currentDate: { fixedDate }, sleep: { _ in })

        let failTransport = ClosureRegistrySession { req in
            throw RegistryTransportError(kind: .transportError, detail: "Replay must not hit live network", url: req.url)
        }

        // 1. Default --registry-replay WITHOUT SCHOLAR_CACHE_DIR: banner says "no cache", creates zero cache files
        let defaultReplayRunner = ScholarCLIRunner(
            registryTransport: failTransport,
            registryClock: clock,
            environment: ["HOME": isolatedHome.path]
        )
        let plainEN = await defaultReplayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibURL.path, "--registry-replay", registryDir.path, "--verbose", "--lang", "en"]
        )
        let plainZH = await defaultReplayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibURL.path, "--registry-replay", registryDir.path, "--lang", "zh"]
        )
        #expect(plainEN.exitCode == 1)
        #expect(plainZH.exitCode == 1)
        #expect(plainEN.stdout.contains("no live network requests, no cache"))
        #expect(plainZH.stdout.contains("不发网络请求、不读写缓存"))
        #expect(
            !FileManager.default.fileExists(
                atPath: isolatedHome.appendingPathComponent("Library/Caches/ScholarOS").path
            ),
            "--registry-replay without SCHOLAR_CACHE_DIR must not create default HOME cache directory"
        )

        // Even if default HOME cache ALREADY has rows from an online run, --registry-replay without SCHOLAR_CACHE_DIR ignores it!
        let fixtureReplay = try RegistryReplaySession(directoryURL: registryDir)
        let mockOnlineTransport = ClosureRegistrySession { req in
            let r = try await fixtureReplay.send(req)
            return RegistryHTTPResponse(statusCode: r.statusCode, body: r.body, headers: r.headers, origin: .network, fetchedAt: r.fetchedAt)
        }
        let onlineWarmRunner = ScholarCLIRunner(
            registryTransport: mockOnlineTransport,
            registryClock: clock,
            environment: ["HOME": isolatedHome.path]
        )
        let warmDefaultRes = await onlineWarmRunner.runWithExitStatus(
            arguments: ["verify-citations", bibURL.path, "--lang", "en"]
        )
        #expect(warmDefaultRes.exitCode == 1)
        #expect(FileManager.default.fileExists(atPath: isolatedHome.appendingPathComponent("Library/Caches/ScholarOS/registry.sqlite").path))

        let replayIgnoringDefaultCache = await defaultReplayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibURL.path, "--registry-replay", registryDir.path, "--verbose", "--lang", "en"]
        )
        #expect(replayIgnoringDefaultCache.exitCode == 1)
        let ignoreLines = replayIgnoringDefaultCache.stderr.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(!ignoreLines.isEmpty)
        #expect(ignoreLines.allSatisfy { $0.contains("origin=replay") })

        // 2. --registry-replay WITH explicit SCHOLAR_CACHE_DIR: Run 1 warms cache, banner states cache is active (NOT "no cache" / "不读写缓存")
        let cachedReplayRunner = ScholarCLIRunner(
            registryTransport: failTransport,
            registryClock: clock,
            environment: [
                "HOME": tempDir.appendingPathComponent("untouched-home", isDirectory: true).path,
                "SCHOLAR_CACHE_DIR": explicitCacheDir.path
            ]
        )

        let run1BannerEN = await cachedReplayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibURL.path, "--registry-replay", registryDir.path, "--verbose", "--lang", "en"]
        )
        #expect(run1BannerEN.exitCode == 1)
        let firstLineEN = run1BannerEN.stdout.split(separator: "\n").first.map(String.init) ?? ""
        #expect(firstLineEN.hasPrefix("[REPLAY]"))
        #expect(!firstLineEN.contains("no cache"), "Cached replay banner must not claim 'no cache': \(firstLineEN)")
        #expect(firstLineEN.contains("cache"))
        let run1VerboseLines = run1BannerEN.stderr.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(run1VerboseLines.count == 7) // 2 (LeCun) + 1 (Vaswani) + 4 (fake_nonsentinel)
        #expect(run1VerboseLines.allSatisfy { $0.contains("origin=replay") })
        #expect(FileManager.default.fileExists(atPath: explicitCacheDir.appendingPathComponent("registry.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("untouched-home/Library/Caches/ScholarOS").path))

        // Run 2 on fully cacheable entries against an empty manifest proves ZERO replay lookups happen for cached entries,
        // while fake_nonsentinel's unmatched Crossref title search is NOT cached and therefore sends 1 replay lookup!
        let emptyReplayDir = tempDir.appendingPathComponent("empty-replay", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyReplayDir, withIntermediateDirectories: true)
        let emptyManifest = RegistryRecordingManifest(
            startedAt: "2026-11-16T00:00:00Z",
            completedAt: "2026-11-16T00:00:00Z",
            userAgent: "ScholarOS/1.2.0",
            count: 0,
            totalHTTPRequestsSent: 0,
            items: [],
            metaFilesSHA256: [:]
        )
        try JSONEncoder().encode(emptyManifest).write(to: emptyReplayDir.appendingPathComponent("manifest.json"))

        let cacheableOnlyBibURL = tempDir.appendingPathComponent("replay_cacheable_only.bib")
        try """
        @article{real_lecun,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          volume  = {521},
          pages   = {436--444},
          doi     = {10.1038/nature14539}
        }
        @misc{arxiv_real_vaswani,
          author        = {Vaswani, Ashish and Shazeer, Noam and Parmar, Niki and Uszkoreit, Jakob and Jones, Llion and Gomez, Aidan N. and Kaiser, Lukasz and Polosukhin, Illia},
          title         = {Attention Is All You Need},
          year          = {2017},
          eprint        = {1706.03762},
          archiveprefix = {arXiv}
        }
        """.write(to: cacheableOnlyBibURL, atomically: true, encoding: .utf8)

        let zeroReplayCheck = await cachedReplayRunner.runWithExitStatus(
            arguments: ["verify-citations", cacheableOnlyBibURL.path, "--registry-replay", emptyReplayDir.path, "--verbose", "--lang", "en"]
        )
        #expect(zeroReplayCheck.exitCode == 0)
        let zeroReplayLines = zeroReplayCheck.stderr.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(zeroReplayLines.count == 3)
        #expect(zeroReplayLines.allSatisfy { $0.contains("origin=cache") })

        let run2TextZH = await cachedReplayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibURL.path, "--registry-replay", registryDir.path, "--verbose", "--lang", "zh"]
        )
        #expect(run2TextZH.exitCode == 1)
        let firstLineZH = run2TextZH.stdout.split(separator: "\n").first.map(String.init) ?? ""
        #expect(firstLineZH.hasPrefix("[REPLAY"))
        #expect(!firstLineZH.contains("不读写缓存"), "Cached ZH replay banner must not claim '不读写缓存': \(firstLineZH)")
        #expect(firstLineZH.contains("缓存"))
        #expect(run2TextZH.stdout.contains("2026-11-16 取得（缓存）"))
        let run2VerboseLines = run2TextZH.stderr.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(run2VerboseLines.count == 5) // 2 (LeCun cache) + 1 (Vaswani cache) + 1 (fake_nonsentinel doi.org cache) + 1 (fake_nonsentinel Crossref search replay)
        #expect(run2VerboseLines.filter { $0.contains("origin=cache") }.count == 4)
        #expect(run2VerboseLines.filter { $0.contains("origin=replay") }.count == 1)

        let run2TextEN = await cachedReplayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibURL.path, "--registry-replay", registryDir.path, "--lang", "en"]
        )
        #expect(run2TextEN.exitCode == 1)
        #expect(run2TextEN.stdout.contains("fetched 2026-11-16 (cache)"))

        let run1JSON = await defaultReplayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibURL.path, "--registry-replay", registryDir.path, "--json", "--lang", "en"]
        )
        let run2JSON = await cachedReplayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibURL.path, "--registry-replay", registryDir.path, "--json", "--lang", "en"]
        )
        #expect(run1JSON.exitCode == 1)
        #expect(run2JSON.exitCode == 1)
        let report1 = try JSONDecoder().decode(CitationFirewallAuditReport.self, from: Data(run1JSON.stdout.utf8))
        let report2 = try JSONDecoder().decode(CitationFirewallAuditReport.self, from: Data(run2JSON.stdout.utf8))
        #expect(report2.verdicts.count == report1.verdicts.count)
        for (v1, v2) in zip(report1.verdicts, report2.verdicts) {
            #expect(v2.citeKey == v1.citeKey)
            #expect(v2.firewallClass == v1.firewallClass)
            #expect(v2.insertable == v1.insertable)
            #expect(v2.reasons == v1.reasons)
            #expect(v2.fields == v1.fields)
            #expect(!v2.sources.isEmpty)
            if v2.citeKey == "fake_nonsentinel" {
                #expect(v2.sources.contains { $0.source == "doi.org" && $0.origin == .cache && $0.fetchedAt == "2026-11-16" })
                #expect(v2.sources.contains { $0.source == "Crossref" && $0.origin == .replay })
            } else {
                #expect(v2.sources.allSatisfy { $0.origin == .cache && $0.fetchedAt == "2026-11-16" })
            }
        }

        // 3. --registry-replay WITH SCHOLAR_CACHE_DIR AND --no-cache: banner says "no cache" and does NOT read cache
        let noCacheReplayMiss = await cachedReplayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibURL.path, "--registry-replay", emptyReplayDir.path, "--no-cache", "--lang", "en"]
        )
        #expect(noCacheReplayMiss.exitCode == 2, "--no-cache must bypass SCHOLAR_CACHE_DIR and hit emptyReplayDir (exit 2)")
        let noCacheReplayHit = await cachedReplayRunner.runWithExitStatus(
            arguments: ["verify-citations", bibURL.path, "--registry-replay", registryDir.path, "--no-cache", "--lang", "en"]
        )
        #expect(noCacheReplayHit.exitCode == 1)
        #expect(noCacheReplayHit.stdout.contains("no live network requests, no cache"))
    }

    @Test("M1 item 7 (Stage 07): --no-cache, --offline, --registry-record cache skip, cache clear subcommand, --help entries, and corrupt SQLite stderr resilience")
    func m1Stage07CLINoCacheOfflineRecordCacheClearHelpAndCorruptCacheStderr() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage07-cli-flags")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let fixtureReplay = try RegistryReplaySession(directoryURL: registryDir)

        actor TransportCounter {
            var count = 0
            func inc() { count += 1 }
            func drain() -> Int {
                let c = count
                count = 0
                return c
            }
        }
        let counter = TransportCounter()
        let mockTransport = ClosureRegistrySession { req in
            await counter.inc()
            let r = try await fixtureReplay.send(req)
            return RegistryHTTPResponse(statusCode: r.statusCode, body: r.body, headers: r.headers, origin: .network, fetchedAt: r.fetchedAt)
        }

        let vaswaniBibURL = tempDir.appendingPathComponent("vaswani.bib")
        try """
        @misc{arxiv_real_vaswani,
          author        = {Vaswani, Ashish and Shazeer, Noam and Parmar, Niki and Uszkoreit, Jakob and Jones, Llion and Gomez, Aidan N. and Kaiser, Lukasz and Polosukhin, Illia},
          title         = {Attention Is All You Need},
          year          = {2017},
          eprint        = {1706.03762},
          archiveprefix = {arXiv}
        }
        """.write(to: vaswaniBibURL, atomically: true, encoding: .utf8)

        let itoBibURL = tempDir.appendingPathComponent("ito.bib")
        try """
        @article{pmid_real_ito2015,
          author  = {Ito, Hiroshi T. and Zhang, Sheng-Jia and Witter, Menno P. and Moser, Edvard I. and Moser, May-Britt},
          title   = {A prefrontal-thalamo-hippocampal circuit for goal-directed spatial navigation},
          journal = {Nature},
          year    = {2015},
          pmid    = {26017312}
        }
        """.write(to: itoBibURL, atomically: true, encoding: .utf8)

        let bothBibURL = tempDir.appendingPathComponent("both.bib")
        try (
            String(contentsOf: vaswaniBibURL, encoding: .utf8)
            + "\n"
            + String(contentsOf: itoBibURL, encoding: .utf8)
        ).write(to: bothBibURL, atomically: true, encoding: .utf8)

        // 1. --help documents --no-cache, cache clear, and SCHOLAR_CACHE_DIR in EN and ZH; --refresh-cache does NOT exist
        let helpRunner = ScholarCLIRunner(
            registryTransport: mockTransport,
            registryClock: .immediate,
            environment: ["HOME": tempDir.appendingPathComponent("help-home", isDirectory: true).path]
        )
        let helpEN = try await helpRunner.execute(arguments: ["--help", "--lang", "en"])
        let helpZH = try await helpRunner.execute(arguments: ["--help", "--lang", "zh"])
        for banner in [helpEN, helpZH] {
            #expect(banner.contains("--no-cache"))
            #expect(banner.contains("cache clear"))
            #expect(banner.contains("SCHOLAR_CACHE_DIR"))
            #expect(!banner.contains("--refresh-cache"))
        }
        let rejectedRefresh = await helpRunner.runWithExitStatus(
            arguments: ["verify-citations", vaswaniBibURL.path, "--refresh-cache"]
        )
        #expect(rejectedRefresh.exitCode == 2)

        // 2. --no-cache and --offline on a fresh cache dir create NO registry.sqlite
        let freshCacheDir = tempDir.appendingPathComponent("fresh-cache", isDirectory: true)
        let freshRunner = ScholarCLIRunner(
            registryTransport: mockTransport,
            registryClock: .immediate,
            environment: [
                "HOME": tempDir.appendingPathComponent("fresh-home", isDirectory: true).path,
                "SCHOLAR_CACHE_DIR": freshCacheDir.path
            ]
        )
        let offlineFresh = await freshRunner.runWithExitStatus(
            arguments: ["verify-citations", vaswaniBibURL.path, "--offline", "--lang", "en"]
        )
        #expect(offlineFresh.exitCode == 3)
        #expect(await counter.drain() == 0)
        #expect(!FileManager.default.fileExists(atPath: freshCacheDir.appendingPathComponent("registry.sqlite").path))

        let noCacheFresh = await freshRunner.runWithExitStatus(
            arguments: ["verify-citations", vaswaniBibURL.path, "--no-cache", "--verbose", "--lang", "en"]
        )
        #expect(noCacheFresh.exitCode == 0)
        #expect(await counter.drain() == 1)
        #expect(noCacheFresh.stderr.contains("origin=network"))
        #expect(!FileManager.default.fileExists(atPath: freshCacheDir.appendingPathComponent("registry.sqlite").path))

        // 3. Warm cache with Vaswani (1 row), then verify --offline returns 0 VERIFIED and --no-cache neither reads nor adds rows
        let warmRun = await freshRunner.runWithExitStatus(
            arguments: ["verify-citations", vaswaniBibURL.path, "--lang", "en"]
        )
        #expect(warmRun.exitCode == 0)
        #expect(await counter.drain() == 1)
        let sqliteURL = freshCacheDir.appendingPathComponent("registry.sqlite")
        #expect(FileManager.default.fileExists(atPath: sqliteURL.path))

        func countCachedRows(_ url: URL) -> Int {
            var db: OpaquePointer?
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_close_v2(db) }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM registry_cache;", -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
        }
        #expect(countCachedRows(sqliteURL) == 1)

        // --offline MUST NOT read cached Vaswani (must still be UNVERIFIED, Verified=0) and MUST NOT write Ito
        let offlineOnWarm = await freshRunner.runWithExitStatus(
            arguments: ["verify-citations", bothBibURL.path, "--offline", "--lang", "en"]
        )
        #expect(offlineOnWarm.exitCode == 3)
        #expect(offlineOnWarm.stdout.contains("Verified=0"))
        #expect(!offlineOnWarm.stdout.contains("[VERIFIED]"))
        #expect(await counter.drain() == 0)
        #expect(countCachedRows(sqliteURL) == 1)

        // --no-cache MUST NOT read cached Vaswani (sends 2 network requests for Vaswani + Ito) and MUST NOT add Ito to SQLite
        let noCacheOnWarm = await freshRunner.runWithExitStatus(
            arguments: ["verify-citations", bothBibURL.path, "--no-cache", "--verbose", "--lang", "en"]
        )
        #expect(noCacheOnWarm.exitCode == 0)
        #expect(await counter.drain() == 2)
        #expect(!noCacheOnWarm.stderr.contains("origin=cache"))
        #expect(countCachedRows(sqliteURL) == 1)

        // 4. --registry-record <dir>: cached Vaswani hits cache (not sent, not recorded), uncached Ito is sent + recorded + cached
        let recOutDir = tempDir.appendingPathComponent("recorded-partial", isDirectory: true)
        let recordWithCache = await freshRunner.runWithExitStatus(
            arguments: ["verify-citations", bothBibURL.path, "--registry-record", recOutDir.path, "--verbose", "--lang", "en"]
        )
        #expect(recordWithCache.exitCode == 0)
        #expect(await counter.drain() == 1, "Only uncached Ito should be sent over transport during --registry-record")
        #expect(recordWithCache.stderr.contains("source=arXiv") && recordWithCache.stderr.contains("origin=cache"))
        #expect(recordWithCache.stderr.contains("source=PubMed") && recordWithCache.stderr.contains("origin=network"))
        let recManifest = try JSONDecoder().decode(
            RegistryRecordingManifest.self,
            from: Data(contentsOf: recOutDir.appendingPathComponent("manifest.json"))
        )
        #expect(recManifest.count == 1, "Cache-hit arXiv request must not be recorded into manifest.json")
        #expect(recManifest.items.first?.service == "pubmed")
        #expect(countCachedRows(sqliteURL) == 2)

        // 5. `scholaros cache clear`: removes registry.sqlite (+ -wal, -shm), prints removed path, keeps bystander files, exits 0 when missing
        let bystanderURL = freshCacheDir.appendingPathComponent("keep-notes.txt")
        try "do not delete".write(to: bystanderURL, atomically: true, encoding: .utf8)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: sqliteURL.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: sqliteURL.path + "-shm"))

        let clearResEN = await freshRunner.runWithExitStatus(arguments: ["cache", "clear", "--lang", "en"])
        #expect(clearResEN.exitCode == 0)
        #expect(clearResEN.stdout.contains(sqliteURL.path))
        #expect(!FileManager.default.fileExists(atPath: sqliteURL.path))
        #expect(!FileManager.default.fileExists(atPath: sqliteURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: sqliteURL.path + "-shm"))
        #expect(FileManager.default.fileExists(atPath: bystanderURL.path), "cache clear must never delete other files")

        // Second `cache clear` when file does not exist also exits 0
        let clearMissingZH = await freshRunner.runWithExitStatus(arguments: ["cache", "clear", "--lang", "zh"])
        #expect(clearMissingZH.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: bystanderURL.path))

        // Invalid `cache` sub-arguments exit 2
        for badArgs in [["cache"], ["cache", "status"], ["cache", "clear", "extra"]] {
            let badRes = await freshRunner.runWithExitStatus(arguments: badArgs)
            #expect(badRes.exitCode == 2)
        }

        // 6. Corrupt registry.sqlite (garbage bytes): verification succeeds and stderr contains 1 explanation line
        try Data([0xFF, 0x00, 0xFE, 0xED, 0xBA, 0xAD, 0xF0, 0x0D]).write(to: sqliteURL)
        let corruptCLIRun = await freshRunner.runWithExitStatus(
            arguments: ["verify-citations", vaswaniBibURL.path, "--lang", "en"]
        )
        #expect(corruptCLIRun.exitCode == 0)
        #expect(corruptCLIRun.stdout.contains("Evaluated=1 Verified=1"))
        let corruptStderrLines = corruptCLIRun.stderr.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(corruptStderrLines.count == 1, "Expected exactly 1 stderr explanation line on corrupt cache, got: \(corruptCLIRun.stderr)")
    }

    @Test("M1 item 7 (Stage 08 Fix 2): cache unavailable stderr warning emits a single [CACHE] prefix and localizes the sentence under --lang zh while keeping SQLite reason")
    func m1Stage08Fix2CacheUnavailableStderrSinglePrefixAndChineseLocalization() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage08-fix2-stderr")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let fixtureReplay = try RegistryReplaySession(directoryURL: registryDir)
        let mockTransport = ClosureRegistrySession { req in
            let r = try await fixtureReplay.send(req)
            return RegistryHTTPResponse(statusCode: r.statusCode, body: r.body, headers: r.headers, origin: .network, fetchedAt: r.fetchedAt)
        }

        let vaswaniBibURL = tempDir.appendingPathComponent("vaswani.bib")
        try """
        @misc{arxiv_real_vaswani,
          author        = {Vaswani, Ashish and Shazeer, Noam and Parmar, Niki and Uszkoreit, Jakob and Jones, Llion and Gomez, Aidan N. and Kaiser, Lukasz and Polosukhin, Illia},
          title         = {Attention Is All You Need},
          year          = {2017},
          eprint        = {1706.03762},
          archiveprefix = {arXiv}
        }
        """.write(to: vaswaniBibURL, atomically: true, encoding: .utf8)

        let cacheDir = tempDir.appendingPathComponent("corrupt-cache-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let sqliteURL = cacheDir.appendingPathComponent("registry.sqlite")
        try Data([0xFF, 0x00, 0xFE, 0xED, 0xBA, 0xAD, 0xF0, 0x0D]).write(to: sqliteURL)

        let runner = ScholarCLIRunner(
            registryTransport: mockTransport,
            registryClock: .immediate,
            environment: [
                "HOME": tempDir.appendingPathComponent("isolated-home", isDirectory: true).path,
                "SCHOLAR_CACHE_DIR": cacheDir.path
            ]
        )

        let runEN = await runner.runWithExitStatus(
            arguments: ["verify-citations", vaswaniBibURL.path, "--lang", "en"]
        )
        #expect(runEN.exitCode == 0)
        let enLines = runEN.stderr.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(enLines.count == 1, "Expected 1 stderr line in EN, got: \(runEN.stderr)")
        if let enLine = enLines.first {
            #expect(enLine.hasPrefix("[CACHE] Response cache unavailable ("), "Unexpected EN stderr line: \(enLine)")
            #expect(!enLine.contains("[CACHE] [CACHE]"), "Duplicate [CACHE] prefix in EN: \(enLine)")
            #expect(!containsChineseCharacters(enLine), "Unexpected Chinese in EN stderr: \(enLine)")
        }

        let runZH = await runner.runWithExitStatus(
            arguments: ["verify-citations", vaswaniBibURL.path, "--lang", "zh"]
        )
        #expect(runZH.exitCode == 0)
        let zhLines = runZH.stderr.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(zhLines.count == 1, "Expected 1 stderr line in ZH, got: \(runZH.stderr)")
        if let zhLine = zhLines.first {
            #expect(zhLine.hasPrefix("[CACHE] 响应缓存不可用（"), "Expected localized ZH cache warning with single [CACHE] prefix, got: \(zhLine)")
            #expect(!zhLine.contains("[CACHE] [CACHE]"), "Duplicate [CACHE] prefix in ZH: \(zhLine)")
            #expect(!zhLine.contains("Response cache unavailable"), "English sentence leaked into --lang zh stderr: \(zhLine)")
            #expect(zhLine.contains("继续核查"), "Expected Chinese continuation notice in ZH stderr: \(zhLine)")
            // SQLite's diagnostic reason inside parentheses is preserved
            #expect(zhLine.contains("（") && zhLine.contains("）"), "Expected parenthesized SQLite reason in ZH stderr: \(zhLine)")
        }
    }

    @Test("M1 item 7 (Stage 07): two concurrent ScholarOS CLI OS processes sharing the same SCHOLAR_CACHE_DIR complete without SQLite lock errors")
    func m1Stage07TwoProcessesSharingSameCacheDirWithoutErrors() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage07-multiprocess")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let candidates = [
            repositoryRoot.appendingPathComponent(".build/out/Products/Debug/ScholarOS"),
            repositoryRoot.appendingPathComponent(".build/debug/ScholarOS"),
            repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/ScholarOS"),
            repositoryRoot.appendingPathComponent(".build/out/Products/Release/ScholarOS"),
            repositoryRoot.appendingPathComponent(".build/release/ScholarOS")
        ].filter { FileManager.default.isExecutableFile(atPath: $0.path) }

        let binaryURL = try #require(
            candidates.max { lhs, rhs in
                let d1 = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 < d2
            },
            "Expected compiled ScholarOS executable under .build/"
        )

        let sharedCacheDir = tempDir.appendingPathComponent("shared-cache", isDirectory: true)
        let procHome1 = tempDir.appendingPathComponent("home-p1", isDirectory: true)
        let procHome2 = tempDir.appendingPathComponent("home-p2", isDirectory: true)
        try FileManager.default.createDirectory(at: procHome1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: procHome2, withIntermediateDirectories: true)

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let bibURL = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry-sources/stage05-arxiv-pmid-search.bib")

        @Sendable func spawnCLI(isolatedHome: URL) throws -> (exitCode: Int32, stdout: String, stderr: String) {
            let proc = Process()
            proc.executableURL = binaryURL
            proc.arguments = [
                "verify-citations",
                bibURL.path,
                "--registry-replay",
                registryDir.path,
                "--json",
                "--lang",
                "en"
            ]
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = isolatedHome.path
            env["CFFIXED_USER_HOME"] = isolatedHome.path
            env["SCHOLAR_CACHE_DIR"] = sharedCacheDir.path
            proc.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (
                proc.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self)
            )
        }

        async let p1 = Task.detached { try spawnCLI(isolatedHome: procHome1) }.value
        async let p2 = Task.detached { try spawnCLI(isolatedHome: procHome2) }.value
        let (r1, r2) = try await (p1, p2)

        #expect(r1.exitCode == 1, "Process 1 failed: stderr=\(r1.stderr)")
        #expect(r2.exitCode == 1, "Process 2 failed: stderr=\(r2.stderr)")
        #expect(r1.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Unexpected Process 1 stderr: \(r1.stderr)")
        #expect(r2.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Unexpected Process 2 stderr: \(r2.stderr)")
        #expect(FileManager.default.fileExists(atPath: sharedCacheDir.appendingPathComponent("registry.sqlite").path))

        let rep1 = try JSONDecoder().decode(CitationFirewallAuditReport.self, from: Data(r1.stdout.utf8))
        let rep2 = try JSONDecoder().decode(CitationFirewallAuditReport.self, from: Data(r2.stdout.utf8))
        #expect(rep1.verifiedCount == 5)
        #expect(rep2.verifiedCount == 5)
    }

    // MARK: - 14. M1 Item 8 (Stage 08): Unified Entry Points (`verify-citations`, MCP `scholar_verify_bibliography`, `diagnostics`)

    @Test("M1 acceptance row 20 (Stage 08): MCP scholar_verify_bibliography (--registry-replay) produces entry-for-entry identical report JSON to CLI verify-citations --registry-replay --json across all fixture .bib files")
    func m1Stage08Row20MCPVerifyBibliographyMatchesCLIVerifyCitationsAcrossAllFixtures() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage08-row20")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("isolated-home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let isolatedEnv: [String: String] = [
            "HOME": isolatedHome.path,
            "CFFIXED_USER_HOME": isolatedHome.path
        ]

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let registrySourcesDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry-sources", isDirectory: true)
        let sourceBibURLs = try FileManager.default.contentsOfDirectory(
            at: registrySourcesDir,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "bib" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        #expect(sourceBibURLs.count >= 2)
        let allBibURLs = [repositoryRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib")] + sourceBibURLs

        for (idx, bibURL) in allBibURLs.enumerated() {
            let rawBib = try String(contentsOf: bibURL, encoding: .utf8)

            // 1. CLI `verify-citations <bib> --registry-replay <dir> --json --lang en`
            let cliRunner = ScholarCLIRunner(environment: isolatedEnv)
            let cliRes = await cliRunner.runWithExitStatus(
                arguments: [
                    "verify-citations",
                    bibURL.path,
                    "--registry-replay",
                    registryDir.path,
                    "--json",
                    "--lang",
                    "en"
                ]
            )
            #expect(cliRes.exitCode == 0 || cliRes.exitCode == 1 || cliRes.exitCode == 3, "Unexpected CLI exit on \(bibURL.lastPathComponent): \(cliRes.stderr)")
            let cliDict = try #require(
                JSONSerialization.jsonObject(with: Data(cliRes.stdout.utf8)) as? [String: Any],
                "CLI stdout was not JSON on \(bibURL.lastPathComponent)"
            )

            // 2. MCP `scholaros mcp --registry-replay <dir>` calling `scholar_verify_bibliography`
            let rpcReqObj: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 100 + idx,
                "method": "tools/call",
                "params": [
                    "name": "scholar_verify_bibliography",
                    "arguments": ["bibtex": rawBib]
                ]
            ]
            let rpcLine = String(decoding: try JSONSerialization.data(withJSONObject: rpcReqObj), as: UTF8.self)
            let mcpRunner = ScholarCLIRunner(
                environment: isolatedEnv,
                mcpInputLines: [rpcLine]
            )
            let mcpRes = await mcpRunner.runWithExitStatus(
                arguments: ["mcp", "--registry-replay", registryDir.path]
            )
            #expect(mcpRes.exitCode == 0, "MCP replay exited non-zero on \(bibURL.lastPathComponent): \(mcpRes.stderr)")

            let rpcEnv = try #require(
                JSONSerialization.jsonObject(with: Data(mcpRes.stdout.utf8)) as? [String: Any],
                "Invalid JSON-RPC response on \(bibURL.lastPathComponent): \(mcpRes.stdout)"
            )
            let rpcResult = try #require(rpcEnv["result"] as? [String: Any])
            #expect(rpcResult["isError"] as? Bool == false)
            let contentItems = try #require(rpcResult["content"] as? [[String: Any]])
            let mcpText = try #require(contentItems.first?["text"] as? String)
            let mcpDict = try #require(
                JSONSerialization.jsonObject(with: Data(mcpText.utf8)) as? [String: Any],
                "MCP tool text was not JSON on \(bibURL.lastPathComponent): \(mcpText)"
            )

            // Both outputs carry REPLAY markers (`mode == "REPLAY"`, `replay == true`)
            #expect(cliDict["mode"] as? String == "REPLAY")
            #expect(cliDict["replay"] as? Bool == true)
            #expect(mcpDict["mode"] as? String == "REPLAY", "MCP --registry-replay output missing mode=REPLAY on \(bibURL.lastPathComponent)")
            #expect(mcpDict["replay"] as? Bool == true, "MCP --registry-replay output missing replay=true on \(bibURL.lastPathComponent)")

            // Strip timestamp (`generatedAtISO8601`) and verify deep structural equality across complete, unverifiedByReason, and every verdict!
            var normalizedCLI = cliDict
            var normalizedMCP = mcpDict
            normalizedCLI.removeValue(forKey: "generatedAtISO8601")
            normalizedMCP.removeValue(forKey: "generatedAtISO8601")

            let eq = NSDictionary(dictionary: normalizedCLI).isEqual(to: normalizedMCP)
            #expect(
                eq,
                "MCP scholar_verify_bibliography diverged from CLI verify-citations --json on \(bibURL.lastPathComponent)"
            )
        }

        // Default ~/Library/Caches/ScholarOS inside isolatedHome must NOT be created during replay without SCHOLAR_CACHE_DIR
        let defaultIsolatedCache = isolatedHome.appendingPathComponent("Library/Caches/ScholarOS")
        #expect(!FileManager.default.fileExists(atPath: defaultIsolatedCache.path))
    }

    @Test("M1 item 8 (Stage 08): MCP offline: true argument, mcp --offline, and mcp --no-cache obey zero-request / zero-cache rules")
    func m1Stage08MCPOfflineArgumentServerOfflineFlagAndNoCacheFlag() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage08-mcp-offline")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        let emptyCacheDir = tempDir.appendingPathComponent("empty-cache", isDirectory: true)
        let warmCacheDir = tempDir.appendingPathComponent("warm-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let fixtureReplay = try RegistryReplaySession(directoryURL: registryDir)

        final class SpyCounter: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count: Int = 0
            func bump() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            func reset() {
                lock.lock()
                count = 0
                lock.unlock()
            }
        }
        let spy = SpyCounter()
        let spyTransport = ClosureRegistrySession { req in
            spy.bump()
            let r = try await fixtureReplay.send(req)
            return RegistryHTTPResponse(statusCode: r.statusCode, body: r.body, headers: r.headers, origin: .network, fetchedAt: r.fetchedAt)
        }

        let sampleBib = """
        @article{real_lecun,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          volume  = {521},
          pages   = {436--444},
          doi     = {10.1038/nature14539}
        }
        """

        // Pre-warm `warmCacheDir` once using online CLI so `10.1038/nature14539` is cached on disk
        let warmBibFile = tempDir.appendingPathComponent("warm.bib")
        try sampleBib.write(to: warmBibFile, atomically: true, encoding: .utf8)
        let warmRunner = ScholarCLIRunner(
            registryTransport: spyTransport,
            registryClock: .immediate,
            environment: ["HOME": isolatedHome.path, "SCHOLAR_CACHE_DIR": warmCacheDir.path]
        )
        let warmRun = await warmRunner.runWithExitStatus(arguments: ["verify-citations", warmBibFile.path, "--json"])
        #expect(warmRun.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: warmCacheDir.appendingPathComponent("registry.sqlite").path))
        spy.reset()

        // 1. Online MCP server with per-call `offline: true`: 0 transport requests, does NOT read warm cache or write empty cache, 0 VERIFIED, reason == "offline"
        for targetCacheDir in [emptyCacheDir, warmCacheDir] {
            let onlineServer = ScholarMCPServer(
                registryTransport: spyTransport,
                registryClock: .immediate,
                environment: ["HOME": isolatedHome.path, "SCHOLAR_CACHE_DIR": targetCacheDir.path]
            )
            let res = await onlineServer.executeToolCallAsync(
                name: "scholar_verify_bibliography",
                arguments: ["bibtex": sampleBib, "offline": true]
            )
            #expect(res["isError"] as? Bool == false)
            #expect(spy.count == 0, "offline: true must send 0 transport requests")
            let text = try #require(((res["content"] as? [[String: Any]])?.first)?["text"] as? String)
            let report = try JSONDecoder().decode(CitationFirewallAuditReport.self, from: Data(text.utf8))
            #expect(report.verifiedCount == 0)
            #expect(report.unverifiedCount == 1)
            #expect(report.unverifiedByReason == ["offline": 1])
            #expect(report.verdicts.first?.firewallClass == .unverified)
            #expect(report.verdicts.first?.reasons == ["offline"])
            #expect(report.verdicts.first?.sources.isEmpty == true)
        }
        #expect(!FileManager.default.fileExists(atPath: emptyCacheDir.appendingPathComponent("registry.sqlite").path))

        // 2. `scholaros mcp --offline` (without per-call `offline` arg): 0 transport requests, 0 cache reads/writes, 0 VERIFIED, reason == "offline"
        let callWithoutOfflineFlag: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "scholar_verify_bibliography",
                "arguments": ["bibtex": sampleBib]
            ]
        ]
        let callLine = String(decoding: try JSONSerialization.data(withJSONObject: callWithoutOfflineFlag), as: UTF8.self)
        let mcpOfflineRunner = ScholarCLIRunner(
            registryTransport: spyTransport,
            registryClock: .immediate,
            environment: ["HOME": isolatedHome.path, "SCHOLAR_CACHE_DIR": emptyCacheDir.path],
            mcpInputLines: [callLine]
        )
        let mcpOfflineOut = await mcpOfflineRunner.runWithExitStatus(arguments: ["mcp", "--offline"])
        #expect(mcpOfflineOut.exitCode == 0)
        #expect(spy.count == 0, "mcp --offline must send 0 transport requests")
        #expect(!FileManager.default.fileExists(atPath: emptyCacheDir.appendingPathComponent("registry.sqlite").path))
        let offEnv = try #require(JSONSerialization.jsonObject(with: Data(mcpOfflineOut.stdout.utf8)) as? [String: Any])
        let offRes = try #require(offEnv["result"] as? [String: Any])
        let offText = try #require(((offRes["content"] as? [[String: Any]])?.first)?["text"] as? String)
        let offReport = try JSONDecoder().decode(CitationFirewallAuditReport.self, from: Data(offText.utf8))
        #expect(offReport.verifiedCount == 0)
        #expect(offReport.unverifiedByReason == ["offline": 1])
        #expect(offReport.verdicts.first?.reasons == ["offline"])

        // 3. `scholaros mcp --no-cache`: queries online transport, neither reads warm cache nor writes empty cache
        let mcpNoCacheEmptyRunner = ScholarCLIRunner(
            registryTransport: spyTransport,
            registryClock: .immediate,
            environment: ["HOME": isolatedHome.path, "SCHOLAR_CACHE_DIR": emptyCacheDir.path],
            mcpInputLines: [callLine]
        )
        let noCacheOut1 = await mcpNoCacheEmptyRunner.runWithExitStatus(arguments: ["mcp", "--no-cache"])
        #expect(noCacheOut1.exitCode == 0)
        #expect(spy.count == 2, "mcp --no-cache should query Crossref + OpenAlex online transport")
        #expect(!FileManager.default.fileExists(atPath: emptyCacheDir.appendingPathComponent("registry.sqlite").path))

        spy.reset()
        let mcpNoCacheWarmRunner = ScholarCLIRunner(
            registryTransport: spyTransport,
            registryClock: .immediate,
            environment: ["HOME": isolatedHome.path, "SCHOLAR_CACHE_DIR": warmCacheDir.path],
            mcpInputLines: [callLine]
        )
        let noCacheOut2 = await mcpNoCacheWarmRunner.runWithExitStatus(arguments: ["mcp", "--no-cache"])
        #expect(noCacheOut2.exitCode == 0)
        #expect(spy.count == 2, "mcp --no-cache must bypass even a pre-warmed cache")
    }

    @Test("M1 item 8 (Stage 08): without any flags, both MCP scholar_verify_bibliography and CLI diagnostics use online transport by default")
    func m1Stage08DefaultOnlineModeForMCPAndDiagnosticsUsesInjectedTransport() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage08-default-online")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        let mcpCacheDir = tempDir.appendingPathComponent("mcp-cache", isDirectory: true)
        let diagCacheDir = tempDir.appendingPathComponent("diag-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let fixtureReplay = try RegistryReplaySession(directoryURL: registryDir)

        final class URLRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var urls: [String] = []
            func append(_ url: String) {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
            func drain() -> [String] {
                lock.lock()
                defer {
                    urls.removeAll()
                    lock.unlock()
                }
                return urls
            }
        }
        let recorder = URLRecorder()
        let onlineTransport = ClosureRegistrySession { req in
            recorder.append(req.url?.absoluteString ?? "")
            let r = try await fixtureReplay.send(req)
            return RegistryHTTPResponse(statusCode: r.statusCode, body: r.body, headers: r.headers, origin: .network, fetchedAt: r.fetchedAt)
        }

        let bibContent = """
        @article{real_lecun,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          volume  = {521},
          pages   = {436--444},
          doi     = {10.1038/nature14539}
        }
        """

        // 1. Default `scholaros mcp` (no --offline, no --registry-replay) uses online transport
        let callObj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "scholar_verify_bibliography",
                "arguments": ["bibtex": bibContent]
            ]
        ]
        let callLine = String(decoding: try JSONSerialization.data(withJSONObject: callObj), as: UTF8.self)
        let mcpRunner = ScholarCLIRunner(
            registryTransport: onlineTransport,
            registryClock: .immediate,
            environment: ["HOME": isolatedHome.path, "SCHOLAR_CACHE_DIR": mcpCacheDir.path],
            mcpInputLines: [callLine]
        )
        let mcpOut = await mcpRunner.runWithExitStatus(arguments: ["mcp"])
        #expect(mcpOut.exitCode == 0)
        let mcpURLs = recorder.drain()
        #expect(mcpURLs.count == 2, "Default MCP must query Crossref + OpenAlex online transport; got \(String(describing: mcpURLs))")
        #expect(mcpURLs.contains { $0.contains("api.crossref.org/works/10.1038/nature14539") })
        #expect(mcpURLs.contains { $0.contains("api.openalex.org/works/https://doi.org/10.1038/nature14539") })
        let mcpEnv = try #require((try? JSONSerialization.jsonObject(with: Data(mcpOut.stdout.utf8))) as? [String: Any])
        let mcpRes = try #require(mcpEnv["result"] as? [String: Any])
        let mcpText = try #require(((mcpRes["content"] as? [[String: Any]])?.first)?["text"] as? String)
        let mcpReport = try JSONDecoder().decode(CitationFirewallAuditReport.self, from: Data(mcpText.utf8))
        #expect(mcpReport.verifiedCount == 1)
        #expect(mcpReport.verdicts.first?.sources.first?.origin == .network)

        // 2. Default `scholaros diagnostics <paper.tex> --bib <refs.bib>` (no --offline, no --registry-replay) uses online transport
        let texURL = tempDir.appendingPathComponent("paper.tex")
        let bibURL = tempDir.appendingPathComponent("refs.bib")
        try """
        \\documentclass{article}
        \\begin{document}
        \\section{Intro}
        Foundational work \\cite{real_lecun}.
        \\end{document}
        """.write(to: texURL, atomically: true, encoding: .utf8)
        try bibContent.write(to: bibURL, atomically: true, encoding: .utf8)

        let diagRunner = ScholarCLIRunner(
            registryTransport: onlineTransport,
            registryClock: .immediate,
            environment: ["HOME": isolatedHome.path, "SCHOLAR_CACHE_DIR": diagCacheDir.path]
        )
        let diagOut = await diagRunner.runWithExitStatus(
            arguments: ["diagnostics", texURL.path, "--bib", bibURL.path, "--lang", "en"]
        )
        #expect(diagOut.exitCode == 0)
        let diagURLs = recorder.drain()
        #expect(diagURLs.count == 2, "Default diagnostics must query Crossref + OpenAlex online transport for cited entries; got \(String(describing: diagURLs))")
        #expect(diagURLs.contains { $0.contains("api.crossref.org/works/10.1038/nature14539") })
        #expect(diagURLs.contains { $0.contains("api.openalex.org/works/https://doi.org/10.1038/nature14539") })
        #expect(!diagOut.stdout.contains("ERR_UNVERIFIED_CITATION"), "Verified real_lecun must not emit ERR_UNVERIFIED_CITATION: \(diagOut.stdout)")
    }

    @Test("M1 item 8 (Stage 08): MCP replay miss returns error with missing URL and zero verdicts while next call in same process succeeds; corrupt replay dir exits 2 at startup")
    func m1Stage08MCPReplayMissPerCallResilienceCacheRuleAndCorruptStartupExit2() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage08-mcp-replay")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)

        // 1. Same MCP server process: Call 1 hits unrecorded DOI -> error with exact URL, no verdicts/UNVERIFIED; Call 2 succeeds!
        let unrecordedBib = """
        @article{missing_fixture,
          author  = {Author, Test},
          title   = {Paper Not Recorded In Fixture Directory},
          journal = {Nature},
          year    = {2025},
          doi     = {10.1038/unrecorded.2026.77777}
        }
        """
        let validBib = """
        @article{real_lecun,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          volume  = {521},
          pages   = {436--444},
          doi     = {10.1038/nature14539}
        }
        """

        let call1Obj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "scholar_verify_bibliography",
                "arguments": ["bibtex": unrecordedBib]
            ]
        ]
        let call2Obj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "scholar_verify_bibliography",
                "arguments": ["bibtex": validBib]
            ]
        ]
        let line1 = String(decoding: try JSONSerialization.data(withJSONObject: call1Obj), as: UTF8.self)
        let line2 = String(decoding: try JSONSerialization.data(withJSONObject: call2Obj), as: UTF8.self)

        let mcpRunner = ScholarCLIRunner(
            environment: ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path],
            mcpInputLines: [line1, line2]
        )
        let mcpOut = await mcpRunner.runWithExitStatus(
            arguments: ["mcp", "--registry-replay", registryDir.path]
        )
        #expect(mcpOut.exitCode == 0)
        let respLines = mcpOut.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(respLines.count == 2, "Expected 2 JSON-RPC responses from same MCP process, got: \(mcpOut.stdout)")

        if respLines.count == 2 {
            let env1 = try #require(JSONSerialization.jsonObject(with: Data(respLines[0].utf8)) as? [String: Any])
            let res1 = try #require(env1["result"] as? [String: Any])
            #expect(res1["isError"] as? Bool == true)
            let errText = try #require(((res1["content"] as? [[String: Any]])?.first)?["text"] as? String)
            #expect(errText.contains("https://api.crossref.org/works/10.1038/unrecorded.2026.77777"), "Replay miss error must name missing URL: \(errText)")
            #expect(!errText.contains("\"verdicts\""), "Replay miss must not emit verdicts: \(errText)")
            #expect(!errText.contains("UNVERIFIED"), "Replay miss must not degrade to UNVERIFIED: \(errText)")

            let env2 = try #require(JSONSerialization.jsonObject(with: Data(respLines[1].utf8)) as? [String: Any])
            let res2 = try #require(env2["result"] as? [String: Any])
            #expect(res2["isError"] as? Bool == false, "Second call in same MCP process must succeed after Call 1 miss")
            let okText = try #require(((res2["content"] as? [[String: Any]])?.first)?["text"] as? String)
            let okDict = try #require(JSONSerialization.jsonObject(with: Data(okText.utf8)) as? [String: Any])
            #expect(okDict["mode"] as? String == "REPLAY")
            #expect(okDict["verifiedCount"] as? Int == 1)
        }

        // Default HOME cache was NOT created during replay without SCHOLAR_CACHE_DIR
        #expect(!FileManager.default.fileExists(atPath: isolatedHome.appendingPathComponent("Library/Caches/ScholarOS").path))

        // Explicit SCHOLAR_CACHE_DIR during MCP replay DOES use that cache and never touches default HOME cache
        let explicitReplayCacheDir = tempDir.appendingPathComponent("explicit-replay-cache", isDirectory: true)
        let mcpCachedReplayRunner = ScholarCLIRunner(
            environment: [
                "HOME": isolatedHome.path,
                "CFFIXED_USER_HOME": isolatedHome.path,
                "SCHOLAR_CACHE_DIR": explicitReplayCacheDir.path
            ],
            mcpInputLines: [line2]
        )
        let cachedReplayOut = await mcpCachedReplayRunner.runWithExitStatus(
            arguments: ["mcp", "--registry-replay", registryDir.path]
        )
        #expect(cachedReplayOut.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: explicitReplayCacheDir.appendingPathComponent("registry.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: isolatedHome.appendingPathComponent("Library/Caches/ScholarOS").path))

        // 2. Corrupt recording directory (1 byte flipped in a .raw file): `scholaros mcp --registry-replay <corruptDir>` exits 2 AT STARTUP (even before initialize handshake!)
        let corruptDir = tempDir.appendingPathComponent("corrupt-registry", isDirectory: true)
        try FileManager.default.copyItem(at: registryDir, to: corruptDir)
        let rawFiles = try FileManager.default.contentsOfDirectory(at: corruptDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "raw" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let targetRaw = try #require(rawFiles.first)
        var rawBytes = try Data(contentsOf: targetRaw)
        if rawBytes.isEmpty {
            rawBytes = Data([0x01])
        } else {
            rawBytes[0] ^= 0xFF
        }
        try rawBytes.write(to: targetRaw)

        let initOnlyLine = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let corruptRunner = ScholarCLIRunner(
            environment: ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path],
            mcpInputLines: [initOnlyLine]
        )
        let corruptRes = await corruptRunner.runWithExitStatus(
            arguments: ["mcp", "--registry-replay", corruptDir.path]
        )
        #expect(corruptRes.exitCode == 2, "Corrupt replay dir must exit 2 at mcp startup, got exit=\(corruptRes.exitCode) stdout=\(corruptRes.stdout)")
        #expect(!corruptRes.stderr.isEmpty)

        // Also verify via spawned OS process (`ScholarOS mcp --registry-replay <corruptDir>`) that startup exits 2 immediately without hanging on stdin
        let candidates = [
            repositoryRoot.appendingPathComponent(".build/out/Products/Debug/ScholarOS"),
            repositoryRoot.appendingPathComponent(".build/debug/ScholarOS"),
            repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/ScholarOS"),
            repositoryRoot.appendingPathComponent(".build/out/Products/Release/ScholarOS"),
            repositoryRoot.appendingPathComponent(".build/release/ScholarOS")
        ].filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        if let binaryURL = candidates.max(by: { lhs, rhs in
            let d1 = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d2 = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d1 < d2
        }) {
            let proc = Process()
            proc.executableURL = binaryURL
            proc.arguments = ["mcp", "--registry-replay", corruptDir.path]
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = isolatedHome.path
            env["CFFIXED_USER_HOME"] = isolatedHome.path
            proc.environment = env
            let stdinPipe = Pipe()
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            // Intentionally keep stdin open while waiting for exit to prove startup validation happens before reading stdin!
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            try? stdinPipe.fileHandleForWriting.close()
            #expect(proc.terminationStatus == 2, "Spawned `ScholarOS mcp --registry-replay <corruptDir>` must exit 2 at startup; got \(proc.terminationStatus)")
            #expect(!String(decoding: errData, as: UTF8.self).isEmpty)
        }
    }

    @Test("M1 item 8 (Stage 08): within one MCP process, OpenAlex budget exhaustion blocks remaining searches in Call 1 but resets in Call 2 when headers show restored budget")
    func m1Stage08MCPOpenAlexBudgetExhaustionScopedToSingleCallAndResetsAcrossCalls() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage08-mcp-budget")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)

        final class OpenAlexCallTracker: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var openAlexRequests: Int = 0

            func nextIndex() -> Int {
                lock.lock()
                defer { lock.unlock() }
                openAlexRequests += 1
                return openAlexRequests
            }
        }
        let tracker = OpenAlexCallTracker()

        let emptyCrossrefSearchJSON = Data(#"{"status":"ok","message":{"items":[]}}"#.utf8)
        let emptyOpenAlexSearchJSON = Data(#"{"results":[]}"#.utf8)
        let matchingOpenAlexCall2JSON = Data(#"""
        {
          "results": [
            {
              "id": "https://openalex.org/W4200000001",
              "doi": "https://doi.org/10.1145/9999999.1111111",
              "display_name": "Deterministic Verification of Scholarly Citations in Practice",
              "publication_year": 2024,
              "is_retracted": false,
              "primary_location": {
                "source": { "display_name": "Journal of Systems Research" }
              },
              "authorships": [
                { "author": { "display_name": "Clara Lindqvist" } },
                { "author": { "display_name": "Mateo Alvarez" } }
              ]
            }
          ]
        }
        """#.utf8)

        let transport = ClosureRegistrySession { req in
            let host = req.url?.host?.lowercased() ?? ""
            if host == "api.crossref.org" {
                return RegistryHTTPResponse(
                    statusCode: 200,
                    body: emptyCrossrefSearchJSON,
                    headers: [:],
                    origin: .network,
                    fetchedAt: "2026-11-16T00:00:00Z"
                )
            }
            if host == "api.openalex.org" {
                let idx = tracker.nextIndex()
                if idx == 1 {
                    // First OpenAlex search in Call 1 drains remaining credits below 10
                    return RegistryHTTPResponse(
                        statusCode: 200,
                        body: emptyOpenAlexSearchJSON,
                        headers: ["x-ratelimit-remaining": "4"],
                        origin: .network,
                        fetchedAt: "2026-11-16T00:00:00Z"
                    )
                }
                // Call 2's OpenAlex search reports healthy remaining credits
                return RegistryHTTPResponse(
                    statusCode: 200,
                    body: matchingOpenAlexCall2JSON,
                    headers: ["x-ratelimit-remaining": "950"],
                    origin: .network,
                    fetchedAt: "2026-11-16T00:00:05Z"
                )
            }
            throw RegistryTransportError(kind: .transportError, detail: "Unexpected host \(host)")
        }

        let call1Bib = """
        @article{idless_a,
          author  = {Alpha, Alice and Beta, Bob},
          title   = {First Identifierless Entry Exhausting Daily Budget},
          journal = {Journal of Testing},
          year    = {2023}
        }
        @article{idless_b,
          author  = {Gamma, Grace and Delta, Dan},
          title   = {Second Identifierless Entry In Same Call Should Skip OpenAlex},
          journal = {Journal of Testing},
          year    = {2023}
        }
        """
        let call2Bib = """
        @article{idless_c,
          author  = {Lindqvist, Clara and Alvarez, Mateo},
          title   = {Deterministic Verification of Scholarly Citations in Practice},
          journal = {Journal of Systems Research},
          year    = {2024}
        }
        """

        let rpc1: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "scholar_verify_bibliography",
                "arguments": ["bibtex": call1Bib]
            ]
        ]
        let rpc2: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "scholar_verify_bibliography",
                "arguments": ["bibtex": call2Bib]
            ]
        ]
        let line1 = String(decoding: try JSONSerialization.data(withJSONObject: rpc1), as: UTF8.self)
        let line2 = String(decoding: try JSONSerialization.data(withJSONObject: rpc2), as: UTF8.self)

        let mcpRunner = ScholarCLIRunner(
            registryTransport: transport,
            registryClock: .immediate,
            environment: ["HOME": isolatedHome.path],
            mcpInputLines: [line1, line2]
        )
        let out = await mcpRunner.runWithExitStatus(arguments: ["mcp", "--no-cache"])
        #expect(out.exitCode == 0)

        let respLines = out.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(respLines.count == 2)
        if respLines.count == 2 {
            let env1 = try #require((try? JSONSerialization.jsonObject(with: Data(respLines[0].utf8))) as? [String: Any])
            let res1 = try #require(env1["result"] as? [String: Any])
            let text1 = try #require(((res1["content"] as? [[String: Any]])?.first)?["text"] as? String)
            let rep1 = try JSONDecoder().decode(CitationFirewallAuditReport.self, from: Data(text1.utf8))
            let verdictA = try #require(rep1.verdicts.first { $0.citeKey == "idless_a" })
            let verdictB = try #require(rep1.verdicts.first { $0.citeKey == "idless_b" })
            #expect(verdictA.reasons == ["no_match_in_search"])
            #expect(verdictB.reasons.contains("budget_exhausted"), "Second entry in Call 1 must stop OpenAlex search with budget_exhausted; got \(String(describing: verdictB.reasons))")

            let env2 = try #require((try? JSONSerialization.jsonObject(with: Data(respLines[1].utf8))) as? [String: Any])
            let res2 = try #require(env2["result"] as? [String: Any])
            let text2 = try #require(((res2["content"] as? [[String: Any]])?.first)?["text"] as? String)
            let rep2 = try JSONDecoder().decode(CitationFirewallAuditReport.self, from: Data(text2.utf8))
            #expect(rep2.verifiedCount == 1, "Call 2 must re-enable OpenAlex search and verify idless_c; got \(String(describing: rep2.verdicts))")
        }

        // Total OpenAlex requests across both calls: 1 in Call 1 (idless_b skipped!) + 1 in Call 2 = 2
        #expect(tracker.openAlexRequests == 2, "Expected 2 total OpenAlex requests (1 in Call 1 + 1 in Call 2), got \(tracker.openAlexRequests)")
    }

    @Test("M1 item 8 (Stage 08): two consecutive calls on the same MCP process share a single RegistryRateLimiter and preserve Crossref spacing")
    func m1Stage08MCPConsecutiveCallsShareRateLimiterAcrossCalls() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage08-mcp-limiter")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)

        final class SharedVirtualClockState: @unchecked Sendable {
            private let lock = NSLock()
            private var current: TimeInterval = 10.0
            private(set) var recordedSleeps: [TimeInterval] = []
            private(set) var crossrefSendTimestamps: [TimeInterval] = []

            func now() -> TimeInterval {
                lock.lock()
                defer { lock.unlock() }
                return current
            }

            func advance(_ delta: TimeInterval) {
                lock.lock()
                if delta > 0 {
                    current += delta
                }
                lock.unlock()
            }

            func recordSleep(_ seconds: TimeInterval) {
                lock.lock()
                recordedSleeps.append(seconds)
                if seconds > 0 {
                    current += seconds
                }
                lock.unlock()
            }

            func recordCrossrefSend() {
                lock.lock()
                crossrefSendTimestamps.append(current)
                lock.unlock()
            }
        }

        let clockState = SharedVirtualClockState()
        let virtualClock = ClosureRegistryClock(
            now: { clockState.now() },
            sleep: { seconds in clockState.recordSleep(seconds) }
        )

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let fixtureReplay = try RegistryReplaySession(directoryURL: registryDir)
        let transport = ClosureRegistrySession { req in
            if req.url?.host?.lowercased() == "api.crossref.org" {
                clockState.recordCrossrefSend()
            }
            let r = try await fixtureReplay.send(req)
            // Explicit Crossref header: 2 req / 1s -> 0.50s required spacing between Crossref requests
            return RegistryHTTPResponse(
                statusCode: r.statusCode,
                body: r.body,
                headers: [
                    "x-rate-limit-limit": "2",
                    "x-rate-limit-interval": "1s"
                ],
                origin: .network,
                fetchedAt: r.fetchedAt
            )
        }

        let bib1 = """
        @article{real_lecun,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          volume  = {521},
          pages   = {436--444},
          doi     = {10.1038/nature14539}
        }
        """
        let bib2 = """
        @article{real_lstm,
          author  = {Hochreiter, Sepp and Schmidhuber, J{\\"u}rgen},
          title   = {Long Short-Term Memory},
          journal = {Neural Computation},
          year    = {1997},
          volume  = {9},
          pages   = {1735--1780},
          doi     = {10.1162/neco.1997.9.8.1735}
        }
        """

        let server = ScholarMCPServer(
            noCache: true,
            registryTransport: transport,
            registryClock: virtualClock,
            environment: ["HOME": isolatedHome.path]
        )

        // Call 1 sends Crossref lookup at t = 10.00
        let res1 = await server.executeToolCallAsync(
            name: "scholar_verify_bibliography",
            arguments: ["bibtex": bib1]
        )
        #expect(res1["isError"] as? Bool == false)

        // Only 0.10s elapses before Call 2 arrives on the same server (t = 10.10); shared limiter must sleep 0.40s -> t = 10.50
        clockState.advance(0.10)
        let res2 = await server.executeToolCallAsync(
            name: "scholar_verify_bibliography",
            arguments: ["bibtex": bib2]
        )
        #expect(res2["isError"] as? Bool == false)

        #expect(clockState.crossrefSendTimestamps.count == 2)
        if clockState.crossrefSendTimestamps.count == 2 {
            let delta = clockState.crossrefSendTimestamps[1] - clockState.crossrefSendTimestamps[0]
            #expect(
                delta >= 0.50 - 1e-6,
                "Expected >= 0.50s spacing between Call 1's last Crossref request and Call 2's first Crossref request; got \(delta)s (sleeps=\(String(describing: clockState.recordedSleeps)))"
            )
        }
    }

    @Test("M1 item 8 (Stage 08): diagnostics --registry-replay verifies cited entries only (real_lecun clean, fake_nonsentinel & wrongyear emit ERR_UNVERIFIED_CITATION), --offline sends 0 requests, and --help documents new flags")
    func m1Stage08DiagnosticsReplayCitedOnlyOfflineZeroRequestsAndHelpFlags() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage08-diagnostics")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        let offlineCacheDir = tempDir.appendingPathComponent("offline-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let isolatedEnv: [String: String] = [
            "HOME": isolatedHome.path,
            "CFFIXED_USER_HOME": isolatedHome.path
        ]

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let recheckBibURL = repositoryRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib")

        // 1a. Manuscript citing `real_lecun` from `Fixtures/citations-m0-recheck.bib` under `--registry-replay`:
        //     carries REPLAY marker, exits 0, and does NOT emit ERR_UNVERIFIED_CITATION!
        let realTexURL = tempDir.appendingPathComponent("real-cited.tex")
        try """
        \\documentclass{article}
        \\begin{document}
        \\section{Introduction}
        Deep representations \\cite{real_lecun} work well.
        \\end{document}
        """.write(to: realTexURL, atomically: true, encoding: .utf8)

        let runner = ScholarCLIRunner(environment: isolatedEnv)
        let realDiag = await runner.runWithExitStatus(
            arguments: [
                "diagnostics",
                realTexURL.path,
                "--bib",
                recheckBibURL.path,
                "--registry-replay",
                registryDir.path,
                "--lang",
                "en"
            ]
        )
        #expect(realDiag.exitCode == 0, "diagnostics replay failed: \(realDiag.stderr)")
        #expect(realDiag.stdout.contains("REPLAY"), "diagnostics --registry-replay output must carry REPLAY marker: \(realDiag.stdout)")
        #expect(!realDiag.stdout.contains("ERR_UNVERIFIED_CITATION"), "Verified real_lecun must not report ERR_UNVERIFIED_CITATION: \(realDiag.stdout)")

        // 1b. Prove `diagnostics` ONLY verifies CITED entries: uncited entry with unrecorded DOI does NOT trigger a replay miss!
        let mixedBibURL = tempDir.appendingPathComponent("mixed-cited-uncited.bib")
        try """
        @article{real_lecun,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          volume  = {521},
          pages   = {436--444},
          doi     = {10.1038/nature14539}
        }
        @article{uncited_unrecorded,
          author  = {Nobody, Uncited},
          title   = {Never Cited In Manuscript},
          journal = {Journal},
          year    = {2025},
          doi     = {10.1038/uncited.never.recorded.88888}
        }
        """.write(to: mixedBibURL, atomically: true, encoding: .utf8)
        let citedOnlyDiag = await runner.runWithExitStatus(
            arguments: [
                "diagnostics",
                realTexURL.path,
                "--bib",
                mixedBibURL.path,
                "--registry-replay",
                registryDir.path,
                "--lang",
                "en"
            ]
        )
        #expect(citedOnlyDiag.exitCode == 0, "diagnostics must only verify cited entries and skip uncited_unrecorded: stderr=\(citedOnlyDiag.stderr)")
        #expect(!citedOnlyDiag.stdout.contains("ERR_UNVERIFIED_CITATION"))

        // 2. Manuscript citing `fake_nonsentinel` (NOT_FOUND) and `wrongyear5` (DRIFT) -> reports ERR_UNVERIFIED_CITATION, exitCode == 0
        let fakeTexURL = tempDir.appendingPathComponent("fake-cited.tex")
        try """
        \\documentclass{article}
        \\begin{document}
        \\section{Introduction}
        Hallucinated \\cite{fake_nonsentinel} and drifted \\cite{wrongyear5}.
        \\end{document}
        """.write(to: fakeTexURL, atomically: true, encoding: .utf8)
        let fakeDiag = await runner.runWithExitStatus(
            arguments: [
                "diagnostics",
                fakeTexURL.path,
                "--bib",
                recheckBibURL.path,
                "--registry-replay",
                registryDir.path,
                "--lang",
                "en"
            ]
        )
        #expect(fakeDiag.exitCode == 0)
        #expect(fakeDiag.stdout.contains("REPLAY"))
        #expect(fakeDiag.stdout.contains("ERR_UNVERIFIED_CITATION"))
        #expect(fakeDiag.stdout.contains("fake_nonsentinel"))
        #expect(fakeDiag.stdout.contains("wrongyear5"))

        // 3. `diagnostics --offline`: 0 transport requests, cache untouched, reports ERR_UNVERIFIED_CITATION
        final class OfflineSpy: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func bump() { lock.lock(); count += 1; lock.unlock() }
        }
        let offlineSpy = OfflineSpy()
        let failingTransport = ClosureRegistrySession { _ in
            offlineSpy.bump()
            throw RegistryTransportError(kind: .transportError, detail: "Should never be called in --offline")
        }
        let offlineRunner = ScholarCLIRunner(
            registryTransport: failingTransport,
            registryClock: .immediate,
            environment: [
                "HOME": isolatedHome.path,
                "SCHOLAR_CACHE_DIR": offlineCacheDir.path
            ]
        )
        let offlineDiag = await offlineRunner.runWithExitStatus(
            arguments: ["diagnostics", realTexURL.path, "--bib", recheckBibURL.path, "--offline", "--lang", "en"]
        )
        #expect(offlineDiag.exitCode == 0)
        #expect(offlineSpy.count == 0)
        #expect(!FileManager.default.fileExists(atPath: offlineCacheDir.appendingPathComponent("registry.sqlite").path))
        #expect(offlineDiag.stdout.contains("ERR_UNVERIFIED_CITATION"))
        #expect(offlineDiag.stdout.contains("real_lecun"))

        // 4. `--help` in EN and ZH documents `--offline`, `--registry-replay`, and `--no-cache` for both `diagnostics` and `mcp`, and invalid combinations exit 2
        let helpEN = try await runner.execute(arguments: ["--help", "--lang", "en"])
        let helpZH = try await runner.execute(arguments: ["--help", "--lang", "zh"])
        for helpText in [helpEN, helpZH] {
            let diagHelpLines = helpText.split(separator: "\n").filter { $0.contains("diagnostics ") }
            let mcpHelpLines = helpText.split(separator: "\n").filter { $0.contains("mcp ") }
            #expect(!diagHelpLines.isEmpty)
            #expect(!mcpHelpLines.isEmpty)
            let joinedDiagHelp = diagHelpLines.joined(separator: " ")
            let joinedMCPHelp = mcpHelpLines.joined(separator: " ")
            #expect(joinedDiagHelp.contains("--offline"), "diagnostics --help missing --offline: \(joinedDiagHelp)")
            #expect(joinedDiagHelp.contains("--registry-replay"), "diagnostics --help missing --registry-replay: \(joinedDiagHelp)")
            #expect(joinedDiagHelp.contains("--no-cache"), "diagnostics --help missing --no-cache: \(joinedDiagHelp)")
            #expect(joinedMCPHelp.contains("--offline"), "mcp --help missing --offline: \(joinedMCPHelp)")
            #expect(joinedMCPHelp.contains("--registry-replay"), "mcp --help missing --registry-replay: \(joinedMCPHelp)")
            #expect(joinedMCPHelp.contains("--no-cache"), "mcp --help missing --no-cache: \(joinedMCPHelp)")
        }

        for invalidArgs in [
            ["diagnostics", realTexURL.path, "--offline", "--registry-replay", registryDir.path],
            ["mcp", "--offline", "--registry-replay", registryDir.path],
            ["mcp", "--demo", "--registry-replay", registryDir.path]
        ] {
            let badRes = await runner.runWithExitStatus(arguments: invalidArgs)
            #expect(badRes.exitCode == 2, "Expected exit 2 for invalid args \(invalidArgs.joined(separator: " ")), got \(badRes.exitCode)")
        }
    }

    // MARK: - 15. M1 Stage 09: S51 CLI Offline Verification on CRLF & Mixed-Newline .bib Fixtures

    @Test("S51 regression: verify-citations --offline on CRLF and mixed-line-ending .bib fixtures exits 3 (not 2) with 0 ERR_BIB_SYNTAX")
    func s51CLIVerifyCitationsOfflineOnCRLFAndMixedFixturesExits3Not2() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage09-s51")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let runner = ScholarCLIRunner(
            environment: [
                "HOME": isolatedHome.path,
                "CFFIXED_USER_HOME": isolatedHome.path
            ]
        )

        let crlfBibURL = repositoryRoot.appendingPathComponent("Tests/Fixtures/crlf-two-entries.bib")
        let mixedBibURL = repositoryRoot.appendingPathComponent("Tests/Fixtures/mixed-line-endings.bib")

        for fixtureURL in [crlfBibURL, mixedBibURL] {
            let res = await runner.runWithExitStatus(
                arguments: ["verify-citations", fixtureURL.path, "--offline", "--lang", "en"]
            )
            #expect(res.exitCode == 3, "Expected exit 3 (UNVERIFIED) on \(fixtureURL.lastPathComponent), got \(res.exitCode), stderr=\(res.stderr)")
            #expect(!res.stderr.contains("ERR_BIB_SYNTAX"))
            #expect(res.stdout.contains("Evaluated=2 Verified=0"))
            #expect(res.stdout.contains("Unverified=2"))
        }
    }

    @Test("S52 regression: CLI verify-citations --offline on eprint-url-not-arxiv.bib yields 5 UNVERIFIED (offline), 0 NOT_FOUND, exit 3")
    func s52CLIVerifyCitationsOfflineOnEprintURLNotArXivExits3WithZeroNotFound() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage09-s52")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let runner = ScholarCLIRunner(
            environment: [
                "HOME": isolatedHome.path,
                "CFFIXED_USER_HOME": isolatedHome.path
            ]
        )

        let fixtureURL = repositoryRoot.appendingPathComponent("Tests/Fixtures/eprint-url-not-arxiv.bib")
        for lang in ["en", "zh"] {
            let res = await runner.runWithExitStatus(
                arguments: ["verify-citations", fixtureURL.path, "--offline", "--lang", lang]
            )
            #expect(res.exitCode == 3, "Expected exit 3 on eprint-url-not-arxiv.bib (--lang \(lang)), got \(res.exitCode): \(res.stdout)")
            #expect(res.stdout.contains("Evaluated=5 Verified=0 Drift=0 NotFound=0 Retracted=0 Unverified=5"))
            #expect(!res.stdout.contains("[NOT_FOUND]"))
        }
        let zhJSON = await runner.runWithExitStatus(
            arguments: ["verify-citations", fixtureURL.path, "--offline", "--json", "--lang", "zh"]
        )
        #expect(zhJSON.exitCode == 3)
        #expect(zhJSON.stdout.contains("eprint 字段不是 arXiv 编号，未当作标识符"))
    }

    // MARK: - 16. M1 Stage 09: Row 18, CLI `cite` & MCP `scholar_cite_key` Gates, Online/Offline/Cache & Rejection Reasons

    @Test("M1 acceptance row 18 & converse (Stage 09): fake_nonsentinel + x-firewall-class={VERIFIED} is NOT_FOUND and blocked across verify-citations, diagnostics, scholar_cite_key, and cite; real_lecun + x-firewall-class={NOT_FOUND} succeeds on replay")
    func m1Stage09Row18FakeNonsentinelWithUntrustedVerifiedBlockedEverywhereAndRealLecunConverse() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage09-row18")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let isolatedEnv = [
            "HOME": isolatedHome.path,
            "CFFIXED_USER_HOME": isolatedHome.path
        ]

        let recheckBibURL = repositoryRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib")
        let recheckLines = try String(contentsOf: recheckBibURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let rawFakeLine = try #require(recheckLines.first { $0.contains("{fake_nonsentinel,") })
        let rawLecunLine = try #require(recheckLines.first { $0.contains("{real_lecun,") })

        // Verbatim fake_nonsentinel from Fixtures/citations-m0-recheck.bib (title, authors, year=2026 untouched) + x-firewall-class = {VERIFIED}
        #expect(rawFakeLine.hasSuffix("}"))
        let tamperedFakeBib = String(rawFakeLine.dropLast()) + ", x-firewall-class = {VERIFIED}}\n"
        let fakeBibURL = tempDir.appendingPathComponent("row18_fake.bib")
        try tamperedFakeBib.write(to: fakeBibURL, atomically: true, encoding: .utf8)

        let fakeTexURL = tempDir.appendingPathComponent("row18_fake.tex")
        try """
        \\documentclass{article}
        \\begin{document}
        Attempted citation \\cite{fake_nonsentinel}.
        \\end{document}
        """.write(to: fakeTexURL, atomically: true, encoding: .utf8)

        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry")
        let runner = ScholarCLIRunner(environment: isolatedEnv)

        // 1. verify-citations --registry-replay: verdict is NOT VERIFIED, findings record "未采信" / "not trusted" and original value "VERIFIED"
        let verifyZH = await runner.runWithExitStatus(
            arguments: ["verify-citations", fakeBibURL.path, "--registry-replay", registryDir.path, "--json", "--lang", "zh"]
        )
        #expect(verifyZH.exitCode == 1)
        let zhObj = try #require(JSONSerialization.jsonObject(with: Data(verifyZH.stdout.utf8)) as? [String: Any])
        let zhVerdict = try #require((zhObj["verdicts"] as? [[String: Any]])?.first)
        #expect(zhVerdict["firewallClass"] as? String != "VERIFIED")
        #expect(zhVerdict["firewallClass"] as? String == "NOT_FOUND")
        let zhFindings = try #require(zhVerdict["findings"] as? [[String: Any]])
        #expect(zhFindings.contains {
            let d = ($0["detail"] as? String) ?? ""
            return d.contains("未采信") && d.contains("VERIFIED")
        })

        let verifyEN = await runner.runWithExitStatus(
            arguments: ["verify-citations", fakeBibURL.path, "--registry-replay", registryDir.path, "--json", "--lang", "en"]
        )
        #expect(verifyEN.exitCode == 1)
        let enObj = try #require(JSONSerialization.jsonObject(with: Data(verifyEN.stdout.utf8)) as? [String: Any])
        let enVerdict = try #require((enObj["verdicts"] as? [[String: Any]])?.first)
        #expect(enVerdict["firewallClass"] as? String == "NOT_FOUND")
        let enFindings = try #require(enVerdict["findings"] as? [[String: Any]])
        #expect(enFindings.contains {
            let d = ($0["detail"] as? String) ?? ""
            return d.contains("not trusted") && d.contains("VERIFIED")
        })

        // 2. diagnostics on .tex citing fake_nonsentinel: emits ERR_UNVERIFIED_CITATION
        let diagFake = await runner.runWithExitStatus(
            arguments: ["diagnostics", fakeTexURL.path, "--bib", fakeBibURL.path, "--registry-replay", registryDir.path, "--lang", "zh"]
        )
        #expect(diagFake.stdout.contains("ERR_UNVERIFIED_CITATION"))

        // 3. MCP scholar_cite_key (mcp --registry-replay): rejects with ERR_UNVERIFIED_CITATION + NOT_FOUND + doi_not_registered
        let replaySnapshot = try RegistryReplaySnapshot(directoryURL: registryDir)
        let mcpReplay = ScholarMCPServer(
            defaultRegistryReplayPath: registryDir.path,
            defaultRegistryReplaySnapshot: replaySnapshot,
            environment: isolatedEnv
        )
        let mcpFakeRes = await mcpReplay.executeToolCallAsync(
            name: "scholar_cite_key",
            arguments: [
                "citeKey": "fake_nonsentinel",
                "bibtex": tamperedFakeBib
            ]
        )
        #expect(mcpFakeRes["isError"] as? Bool == true)
        let mcpFakeText = ((mcpFakeRes["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(mcpFakeText.contains("ERR_UNVERIFIED_CITATION"))
        #expect(mcpFakeText.contains("NOT_FOUND"))
        #expect(mcpFakeText.contains("doi_not_registered"))

        // 4. CLI cite (--registry-replay): rejects with ERR_UNVERIFIED_CITATION + NOT_FOUND + doi_not_registered
        let citeFakeZH = await runner.runWithExitStatus(
            arguments: ["cite", "fake_nonsentinel", "--bib", fakeBibURL.path, "--registry-replay", registryDir.path, "--lang", "zh"]
        )
        #expect(citeFakeZH.exitCode == 2)
        #expect(citeFakeZH.stdout.isEmpty)
        #expect(citeFakeZH.stderr.contains("ERR_UNVERIFIED_CITATION"))
        #expect(citeFakeZH.stderr.contains("NOT_FOUND"))
        #expect(citeFakeZH.stderr.contains("doi_not_registered"))

        // 5. Converse: real_lecun + x-firewall-class = {NOT_FOUND} -> replay yields VERIFIED, cite & scholar_cite_key succeed, findings still note "未采信" + "NOT_FOUND"
        #expect(rawLecunLine.hasSuffix("}"))
        let tamperedLecunBib = String(rawLecunLine.dropLast()) + ", x-firewall-class = {NOT_FOUND}}\n"
        let lecunBibURL = tempDir.appendingPathComponent("row18_lecun.bib")
        try tamperedLecunBib.write(to: lecunBibURL, atomically: true, encoding: .utf8)

        let verifyLecunZH = await runner.runWithExitStatus(
            arguments: ["verify-citations", lecunBibURL.path, "--registry-replay", registryDir.path, "--json", "--lang", "zh"]
        )
        #expect(verifyLecunZH.exitCode == 0)
        let lecunObj = try #require(JSONSerialization.jsonObject(with: Data(verifyLecunZH.stdout.utf8)) as? [String: Any])
        let lecunVerdict = try #require((lecunObj["verdicts"] as? [[String: Any]])?.first)
        #expect(lecunVerdict["firewallClass"] as? String == "VERIFIED")
        let lecunFindings = try #require(lecunVerdict["findings"] as? [[String: Any]])
        #expect(lecunFindings.contains {
            let d = ($0["detail"] as? String) ?? ""
            return d.contains("未采信") && d.contains("NOT_FOUND")
        })

        let citeLecun = await runner.runWithExitStatus(
            arguments: ["cite", "real_lecun", "--bib", lecunBibURL.path, "--registry-replay", registryDir.path]
        )
        #expect(citeLecun.exitCode == 0)
        #expect(citeLecun.stdout.contains("\\cite{real_lecun}"))
        #expect(citeLecun.stdout.contains("Deep learning"))

        let mcpLecunSync = mcpReplay.executeToolCall(
            name: "scholar_cite_key",
            arguments: [
                "citeKey": "real_lecun",
                "bibtex": tamperedLecunBib
            ]
        )
        #expect(mcpLecunSync["isError"] as? Bool == false)
        let mcpLecunText = ((mcpLecunSync["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(mcpLecunText.contains("CITATION_STATUS:VERIFIED"))
    }

    @Test("M1 Stage 09 (S42 items 4-6): CLI cite and MCP scholar_cite_key enforce --offline (0 transport calls, 'offline' not-checked message), default online + cache/--no-cache, distinct UNVERIFIED vs DRIFT/RETRACTED messages, --demo block, and --help flags")
    func m1Stage09CiteAndMCPCiteKeyOfflineOnlineDefaultCacheAndRejectionDistinctions() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage09-cite-modes")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        let explicitCacheDir = tempDir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: explicitCacheDir, withIntermediateDirectories: true)
        let isolatedEnv = [
            "HOME": isolatedHome.path,
            "CFFIXED_USER_HOME": isolatedHome.path,
            "SCHOLAR_CACHE_DIR": explicitCacheDir.path
        ]

        let recheckBibURL = repositoryRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib")
        let rawRecheckBib = try String(contentsOf: recheckBibURL, encoding: .utf8)
        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry")
        let backingReplay = try RegistryReplaySnapshot(directoryURL: registryDir)

        actor SpyCounter {
            var calls = 0
            func bump() { calls += 1 }
        }
        let spy = SpyCounter()
        let spyOnlineTransport = ClosureRegistrySession { request in
            await spy.bump()
            let inner = backingReplay.makeSession()
            let resp = try await inner.send(request)
            return RegistryHTTPResponse(
                statusCode: resp.statusCode,
                body: resp.body,
                headers: resp.headers,
                origin: .network,
                fetchedAt: resp.fetchedAt
            )
        }

        let runner = ScholarCLIRunner(
            registryTransport: spyOnlineTransport,
            registryClock: ClosureRegistryClock.immediate,
            environment: isolatedEnv
        )

        // 1. Offline: CLI `cite --offline` and `mcp --offline` `scholar_cite_key` reject real_lecun with 0 transport calls and "offline" not-checked explanation
        for lang in ["en", "zh"] {
            let offCite = await runner.runWithExitStatus(
                arguments: ["cite", "real_lecun", "--bib", recheckBibURL.path, "--offline", "--lang", lang]
            )
            #expect(offCite.exitCode == 2)
            #expect(offCite.stderr.contains("ERR_UNVERIFIED_CITATION"))
            #expect(offCite.stderr.contains("UNVERIFIED"))
            #expect(offCite.stderr.contains("offline"))
            if lang == "zh" {
                #expect(offCite.stderr.contains("并非"))
            } else {
                #expect(offCite.stderr.lowercased().contains("not because"))
            }
        }

        let mcpOfflineProcess = ScholarMCPServer(
            isOffline: true,
            registryTransport: spyOnlineTransport,
            registryClock: ClosureRegistryClock.immediate,
            environment: isolatedEnv
        )
        let mcpOffRes = mcpOfflineProcess.executeToolCall(
            name: "scholar_cite_key",
            arguments: ["citeKey": "real_lecun", "bibtex": rawRecheckBib, "lang": "zh"]
        )
        #expect(mcpOffRes["isError"] as? Bool == true)
        let mcpOffText = ((mcpOffRes["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(mcpOffText.contains("ERR_UNVERIFIED_CITATION"))
        #expect(mcpOffText.contains("UNVERIFIED"))
        #expect(mcpOffText.contains("offline"))
        #expect(mcpOffText.contains("并非"))

        // Per-call `offline: true` on an online MCP server also sends 0 requests and rejects with `offline`
        let mcpOnlineProcess = ScholarMCPServer(
            registryTransport: spyOnlineTransport,
            registryClock: ClosureRegistryClock.immediate,
            environment: isolatedEnv
        )
        let mcpPerCallOff = await mcpOnlineProcess.executeToolCallAsync(
            name: "scholar_cite_key",
            arguments: ["citeKey": "real_lecun", "bibtex": rawRecheckBib, "offline": true]
        )
        #expect(mcpPerCallOff["isError"] as? Bool == true)
        let mcpPerCallOffText = ((mcpPerCallOff["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(mcpPerCallOffText.contains("offline"))
        #expect(await spy.calls == 0, "Offline cite / scholar_cite_key must send 0 transport requests")

        // 2. Default online + cache: CLI `cite` with NO flags queries injected online transport, succeeds on real_lecun, caches response, and `--no-cache` bypasses cache
        let onlineCite1 = await runner.runWithExitStatus(
            arguments: ["cite", "real_lecun", "--bib", recheckBibURL.path]
        )
        #expect(onlineCite1.exitCode == 0, "stderr=\(onlineCite1.stderr)")
        #expect(onlineCite1.stdout.contains("\\cite{real_lecun}"))
        let callsAfterFirstOnline = await spy.calls
        #expect(callsAfterFirstOnline == 2, "Expected Crossref + OpenAlex calls on uncached online cite, got \(callsAfterFirstOnline)")

        // Second default online `cite` hits cache -> 0 additional transport calls!
        let onlineCite2 = await runner.runWithExitStatus(
            arguments: ["cite", "real_lecun", "--bib", recheckBibURL.path]
        )
        #expect(onlineCite2.exitCode == 0)
        #expect(await spy.calls == callsAfterFirstOnline, "Cached second cite should send 0 new transport requests")

        // With `--no-cache`, `cite` bypasses cache and queries transport again
        let noCacheCite = await runner.runWithExitStatus(
            arguments: ["cite", "real_lecun", "--bib", recheckBibURL.path, "--no-cache"]
        )
        #expect(noCacheCite.exitCode == 0)
        #expect(await spy.calls == callsAfterFirstOnline + 2)

        // Default online MCP `scholar_cite_key` (via sync executeToolCall bridge!) also succeeds
        let mcpDefaultOnline = mcpOnlineProcess.executeToolCall(
            name: "scholar_cite_key",
            arguments: ["citeKey": "real_lecun", "bibtex": rawRecheckBib]
        )
        #expect(mcpDefaultOnline["isError"] as? Bool == false)

        // 3. Rejection message distinctions: transport_error (UNVERIFIED) vs DRIFT (year_mismatch) vs RETRACTED (retracted_crossref) vs --demo
        let failingTransport = ClosureRegistrySession { _ in
            throw RegistryTransportError(kind: .transportError, detail: "Simulated network cut")
        }
        let failingRunner = ScholarCLIRunner(
            registryTransport: failingTransport,
            registryClock: ClosureRegistryClock.immediate,
            environment: isolatedEnv
        )
        let netFailCite = await failingRunner.runWithExitStatus(
            arguments: ["cite", "real_lecun", "--bib", recheckBibURL.path, "--no-cache", "--lang", "zh"]
        )
        #expect(netFailCite.exitCode == 2)
        #expect(netFailCite.stderr.contains("UNVERIFIED"))
        #expect(netFailCite.stderr.contains("transport_error"))

        let driftCite = await runner.runWithExitStatus(
            arguments: ["cite", "wrongyear5", "--bib", recheckBibURL.path, "--registry-replay", registryDir.path, "--lang", "zh"]
        )
        #expect(driftCite.exitCode == 2)
        #expect(driftCite.stderr.contains("DRIFT"))
        #expect(driftCite.stderr.contains("year_mismatch"))

        let retractedCite = await runner.runWithExitStatus(
            arguments: ["cite", "retracted_seralini", "--bib", recheckBibURL.path, "--registry-replay", registryDir.path, "--lang", "en"]
        )
        #expect(retractedCite.exitCode == 2)
        #expect(retractedCite.stderr.contains("RETRACTED"))
        #expect(retractedCite.stderr.contains("retracted_crossref"))

        let demoCite = await runner.runWithExitStatus(
            arguments: ["cite", "vaswani2017attention", "--demo"]
        )
        #expect(demoCite.exitCode == 2)
        #expect(demoCite.stderr.contains("ERR_UNVERIFIED_CITATION"))
        #expect(await spy.calls == callsAfterFirstOnline + 2, "cite --demo must not hit network")

        // 4. Invalid flag combinations on `cite` exit 2, and `--help` documents `--offline`, `--registry-replay`, `--no-cache` for `cite`
        for badCiteArgs in [
            ["cite", "real_lecun", "--bib", recheckBibURL.path, "--offline", "--registry-replay", registryDir.path],
            ["cite", "vaswani2017attention", "--demo", "--registry-replay", registryDir.path]
        ] {
            let bad = await runner.runWithExitStatus(arguments: badCiteArgs)
            #expect(bad.exitCode == 2)
        }
        for lang in ["en", "zh"] {
            let helpRes = await runner.runWithExitStatus(arguments: ["--help", "--lang", lang])
            #expect(helpRes.exitCode == 0)
            let citeLines = helpRes.stdout.split(separator: "\n").filter { $0.contains("cite <citeKey>") }
            let joined = citeLines.joined(separator: " ")
            #expect(joined.contains("--offline"), "cite --help (\(lang)) missing --offline: \(joined)")
            #expect(joined.contains("--registry-replay"), "cite --help (\(lang)) missing --registry-replay: \(joined)")
            #expect(joined.contains("--no-cache"), "cite --help (\(lang)) missing --no-cache: \(joined)")
        }
    }

    @Test("M1 stage 11 (item 0): CLI --registry-record-limit <N> enforces per-run new-request cap, preserves first 3 recorded items on 4th-request limit error (exit 2), resumes past 80 existing items, rejects invalid values/combinations with exit 2, and documents flag in EN/ZH --help")
    func m1Stage11CLIRegistryRecordLimitPerRunBudgetReplayabilityAndValidation() async throws {
        let tempRoot = try makeTempDirectory(prefix: "scholaros-cli-rec-limit")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let sandboxHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxHome, withIntermediateDirectories: true)
        let isolatedEnv = ["HOME": sandboxHome.path, "CFFIXED_USER_HOME": sandboxHome.path]

        let fixtureRegistryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let fixtureReplay = try RegistryReplaySnapshot(directoryURL: fixtureRegistryDir)

        actor CallTracker {
            var count = 0
            func record() -> Int {
                count += 1
                return count
            }
            func reset() {
                count = 0
            }
        }
        let tracker = CallTracker()

        // Transport serves real recorded responses from Tests/Fixtures/registry when present,
        // and syntactically valid 404 responses for synthetic 10.1234/cap.* DOIs used to test the 80 cap.
        let injectedTransport = ClosureRegistrySession { req in
            _ = await tracker.record()
            let session = fixtureReplay.makeSession()
            if let recorded = try? await session.send(req) {
                return RegistryHTTPResponse(
                    statusCode: recorded.statusCode,
                    body: recorded.body,
                    headers: recorded.headers,
                    origin: .network
                )
            }
            let urlStr = req.url?.absoluteString ?? ""
            if urlStr.contains("doi.org/api/handles/") {
                return RegistryHTTPResponse(
                    statusCode: 404,
                    body: Data("{\"responseCode\":100}".utf8),
                    headers: ["Content-Type": "application/json", "Date": "Mon, 16 Nov 2026 03:00:00 GMT"]
                )
            }
            return RegistryHTTPResponse(
                statusCode: 404,
                body: Data("Not found".utf8),
                headers: ["Content-Type": "text/plain", "Date": "Mon, 16 Nov 2026 03:00:00 GMT"]
            )
        }

        let runner = ScholarCLIRunner(
            registryTransport: injectedTransport,
            registryClock: ClosureRegistryClock.immediate,
            environment: isolatedEnv
        )

        // 1. Both EN and ZH --help document --registry-record-limit
        for lang in ["en", "zh"] {
            let helpRes = await runner.runWithExitStatus(arguments: ["--help", "--lang", lang])
            #expect(helpRes.exitCode == 0)
            #expect(helpRes.stdout.contains("--registry-record-limit"), "--help (\(lang)) must document --registry-record-limit")
        }

        let twoRealBib = tempRoot.appendingPathComponent("two_real.bib")
        let oneRealBib = tempRoot.appendingPathComponent("one_real.bib")
        let recheckLines = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib"),
            encoding: .utf8
        ).split(separator: "\n", omittingEmptySubsequences: true)
        try (recheckLines.prefix(1).joined(separator: "\n") + "\n").write(to: oneRealBib, atomically: true, encoding: .utf8)
        try (recheckLines.prefix(2).joined(separator: "\n") + "\n").write(to: twoRealBib, atomically: true, encoding: .utf8)

        let dummyRecDir = tempRoot.appendingPathComponent("dummy-rec", isDirectory: true)

        // 2. Invalid values and invalid flag combinations all return exit code 2
        let invalidInvocations: [[String]] = [
            ["verify-citations", oneRealBib.path, "--registry-record-limit", "10"],
            ["verify-citations", oneRealBib.path, "--offline", "--registry-record-limit", "10"],
            ["verify-citations", oneRealBib.path, "--registry-replay", fixtureRegistryDir.path, "--registry-record-limit", "10"],
            ["verify-citations", "--demo", "--registry-record-limit", "10"],
            ["verify-citations", oneRealBib.path, "--registry-record", dummyRecDir.path, "--registry-record-limit", "0"],
            ["verify-citations", oneRealBib.path, "--registry-record", dummyRecDir.path, "--registry-record-limit=0"],
            ["verify-citations", oneRealBib.path, "--registry-record", dummyRecDir.path, "--registry-record-limit", "-1"],
            ["verify-citations", oneRealBib.path, "--registry-record", dummyRecDir.path, "--registry-record-limit=-5"],
            ["verify-citations", oneRealBib.path, "--registry-record", dummyRecDir.path, "--registry-record-limit", "abc"],
            ["verify-citations", oneRealBib.path, "--registry-record", dummyRecDir.path, "--registry-record-limit", "3.5"],
            ["verify-citations", oneRealBib.path, "--registry-record", dummyRecDir.path, "--registry-record-limit="],
            ["verify-citations", oneRealBib.path, "--registry-record", dummyRecDir.path, "--registry-record-limit"]
        ]
        for badArgs in invalidInvocations {
            let res = await runner.runWithExitStatus(arguments: badArgs)
            #expect(res.exitCode == 2, "Expected exit 2 for invalid args \(badArgs), got \(res.exitCode): stderr=\(res.stderr)")
            #expect(res.stdout.isEmpty)
        }
        #expect(await tracker.count == 0, "Invalid CLI flags must fail before sending any requests")

        // 3. --registry-record-limit 3: two_real.bib needs 4 requests (2 for real_lecun + 2 for real_lstm);
        //    4th new request fails with exit 2 reporting limit (3) and exact URL, while first 3 are saved & replayable!
        let limit3Dir = tempRoot.appendingPathComponent("rec-limit-3", isDirectory: true)
        let limit3Run = await runner.runWithExitStatus(
            arguments: [
                "verify-citations", twoRealBib.path,
                "--registry-record", limit3Dir.path,
                "--registry-record-limit", "3",
                "--no-cache",
                "--lang", "en"
            ]
        )
        #expect(limit3Run.exitCode == 2)
        #expect(limit3Run.stderr.contains("(3)"))
        #expect(limit3Run.stderr.contains("https://api.openalex.org/works/https://doi.org/10.1162/neco.1997.9.8.1735"))
        #expect(await tracker.count == 3)

        // First 3 recorded responses on disk are valid and replay one_real.bib (real_lecun, 2 requests) cleanly
        let snapshot3 = try RegistryReplaySnapshot(directoryURL: limit3Dir)
        #expect(snapshot3.manifest.count == 3)
        let replayAfterLimit3 = await runner.runWithExitStatus(
            arguments: ["verify-citations", oneRealBib.path, "--registry-replay", limit3Dir.path, "--lang", "en"]
        )
        #expect(replayAfterLimit3.exitCode == 0)
        #expect(replayAfterLimit3.stdout.contains("Evaluated=1 Verified=1"))
        #expect(await tracker.count == 3, "Replay must send 0 new transport requests")

        // 4. Pre-populate a directory with 80 recorded items, then run CLI --registry-record without --registry-record-limit:
        //    default remains 80 NEW requests, so recording two_real.bib (2+2=4 new requests) succeeds!
        let dir80 = tempRoot.appendingPathComponent("rec-existing-80", isDirectory: true)
        let prefillSession = try RegistryRecordingSession(
            directoryURL: dir80,
            transport: injectedTransport,
            maxRequests: 80,
            minimumIntervalSeconds: 0
        )
        for idx in 1...80 {
            let u = try #require(RegistryURLBuilder.doiHandleURL(doi: String(format: "10.1234/cap.%03d", idx)))
            _ = try await prefillSession.send(URLRequest(url: u))
        }
        _ = try await prefillSession.finalize()
        await tracker.reset()

        let resumePast80Run = await runner.runWithExitStatus(
            arguments: [
                "verify-citations", twoRealBib.path,
                "--registry-record", dir80.path,
                "--no-cache",
                "--lang", "en"
            ]
        )
        #expect(resumePast80Run.exitCode == 0, "Expected exit 0 when adding 4 new requests onto 80 existing, stderr=\(resumePast80Run.stderr)")
        #expect(await tracker.count == 4)
        let snapshot84 = try RegistryReplaySnapshot(directoryURL: dir80)
        #expect(snapshot84.manifest.count == 84)
        #expect(snapshot84.manifest.totalHTTPRequestsSent == 84)

        // 5. Default limit is still 80 when --registry-record-limit is omitted:
        //    a .bib needing >80 new requests fails at 80 with exit 2.
        var manyBibLines: [String] = []
        for idx in 1...30 {
            manyBibLines.append(
                "@article{cap_\(idx), author={Doe, Jane}, title={Synthetic Item \(idx)}, journal={J}, year={2024}, doi={10.1234/over80.\(idx)}}"
            )
        }
        let over80Bib = tempRoot.appendingPathComponent("over80.bib")
        try manyBibLines.joined(separator: "\n").write(to: over80Bib, atomically: true, encoding: .utf8)

        await tracker.reset()
        let defaultCapDir = tempRoot.appendingPathComponent("rec-default-cap", isDirectory: true)
        let defaultCapRun = await runner.runWithExitStatus(
            arguments: [
                "verify-citations", over80Bib.path,
                "--registry-record", defaultCapDir.path,
                "--no-cache",
                "--lang", "en"
            ]
        )
        #expect(defaultCapRun.exitCode == 2)
        #expect(defaultCapRun.stderr.contains("(80)"))
        #expect(await tracker.count == 80)
        let snapshotDefaultCap = try RegistryReplaySnapshot(directoryURL: defaultCapDir)
        #expect(snapshotDefaultCap.manifest.count == 80)
    }

    @Test("M1 stage 12 (S55): CLI verify-citations emits venue hint in fields, findings, and text output after 'Matched in / 在 <数据源> 查到' in EN and ZH")
    func m1Stage12S55CLIVerifyCitationsVenueHintTextAndJSONInENAndZH() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-stage12-s55")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let env: [String: String] = [
            "HOME": isolatedHome.path,
            "CFFIXED_USER_HOME": isolatedHome.path
        ]

        let wrongVenueBib = tempDir.appendingPathComponent("wrong_venue.bib")
        let bibContent = """
        @article{audit_020,
          author = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title = {Deep learning},
          journal = {Science},
          year = {2015},
          doi = {10.1038/nature14539}
        }
        """
        try bibContent.write(to: wrongVenueBib, atomically: true, encoding: .utf8)

        let recordingsDir = repositoryRoot.appendingPathComponent("Benchmarks/citations/recordings", isDirectory: true)
        let runner = ScholarCLIRunner(environment: env)

        // 1. Chinese JSON & text output
        let zhJSON = await runner.runWithExitStatus(
            arguments: ["verify-citations", wrongVenueBib.path, "--registry-replay", recordingsDir.path, "--json", "--lang", "zh"]
        )
        #expect(zhJSON.exitCode == 0, "stderr=\(zhJSON.stderr)")
        let zhObj = try #require(JSONSerialization.jsonObject(with: Data(zhJSON.stdout.utf8)) as? [String: Any])
        let zhVerdicts = try #require(zhObj["verdicts"] as? [[String: Any]])
        let zhV = try #require(zhVerdicts.first)
        #expect(zhV["firewallClass"] as? String == "VERIFIED")
        #expect(zhV["insertable"] as? Bool == true)
        #expect(zhV["reasons"] as? [String] == ["verified_match"])
        let zhFields = try #require(zhV["fields"] as? [[String: Any]])
        let zhVenueField = try #require(zhFields.first { ($0["field"] as? String) == "venue" })
        #expect(zhVenueField["localValue"] as? String == "Science")
        #expect(zhVenueField["remoteValue"] as? String == "Nature")
        #expect(zhVenueField["severity"] as? String == "advisory")
        #expect((zhVenueField["note"] as? String ?? "").contains("刊名写法不同，未作为不一致处理"))
        let zhFindings = try #require(zhV["findings"] as? [[String: Any]])
        #expect(zhFindings.contains {
            ($0["field"] as? String) == "venue"
                && ($0["detail"] as? String ?? "").contains("刊名写法不同，未作为不一致处理")
        })

        let zhText = await runner.runWithExitStatus(
            arguments: ["verify-citations", wrongVenueBib.path, "--registry-replay", recordingsDir.path, "--lang", "zh"]
        )
        #expect(zhText.exitCode == 0)
        let zhEntryLine = try #require(zhText.stdout.split(separator: "\n").map(String.init).first { $0.contains("audit_020:") })
        let matchedRangeZH = try #require(zhEntryLine.range(of: "在 Crossref 查到"))
        let hintRangeZH = try #require(zhEntryLine.range(of: "刊名提示"))
        #expect(matchedRangeZH.upperBound <= hintRangeZH.lowerBound)
        #expect(zhEntryLine.contains("刊名写法不同，未作为不一致处理"))

        // 2. English text output (S32: no Chinese characters)
        let enText = await runner.runWithExitStatus(
            arguments: ["verify-citations", wrongVenueBib.path, "--registry-replay", recordingsDir.path, "--lang", "en"]
        )
        #expect(enText.exitCode == 0)
        #expect(!containsChineseCharacters(enText.stdout))
        let enEntryLine = try #require(enText.stdout.split(separator: "\n").map(String.init).first { $0.contains("audit_020:") })
        let matchedRangeEN = try #require(enEntryLine.range(of: "Matched in Crossref"))
        let hintRangeEN = try #require(enEntryLine.range(of: "Venue note:"))
        #expect(matchedRangeEN.upperBound <= hintRangeEN.lowerBound)
    }

    // MARK: - 17. M2 Stage 01: `diagnostics --json` Structured Schema (`scholaros.diagnostics/1`) & Byte-Identical Determinism

    @Test("M2 item 6 (Stage 01): diagnostics --json emits scholaros.diagnostics/1 object with files, bibliographySources, citations, uncitedEntries, labels, references, categorized diagnostics, complete, and counts while keeping text output unchanged")
    func m2Stage01DiagnosticsJSONSchemaAndObjectStructure() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage01-schema")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let env: [String: String] = [
            "HOME": isolatedHome.path,
            "CFFIXED_USER_HOME": isolatedHome.path
        ]

        let sectionsDir = tempDir.appendingPathComponent("sections", isDirectory: true)
        try FileManager.default.createDirectory(at: sectionsDir, withIntermediateDirectories: true)

        let mainTexURL = tempDir.appendingPathComponent("main.tex")
        let subTexURL = sectionsDir.appendingPathComponent("sub.tex")
        let bibURL = tempDir.appendingPathComponent("refs.bib")

        try """
        \\documentclass{article}
        \\begin{document}
        \\section{Introduction}\\label{sec:intro}
        \\label{sec:dup}
        Prior work~\\cite{real_lecun} and missing~\\cite{missing_key}.
        \\input{sections/sub}
        \\bibliography{refs}
        \\end{document}
        """.write(to: mainTexURL, atomically: true, encoding: .utf8)

        try """
        \\subsection{Details}
        \\label{sec:dup}
        See Section~\\ref{sec:intro} and~\\ref{sec:missing}, plus~\\citep{real_lecun}.
        """.write(to: subTexURL, atomically: true, encoding: .utf8)

        try """
        @article{real_lecun,
          author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title   = {Deep learning},
          journal = {Nature},
          year    = {2015},
          volume  = {521},
          pages   = {436--444},
          doi     = {10.1038/nature14539}
        }
        @article{uncited_entry,
          author  = {Knuth, Donald E.},
          title   = {The Art of Computer Programming},
          publisher = {Addison-Wesley},
          year    = {1968}
        }
        """.write(to: bibURL, atomically: true, encoding: .utf8)

        let runner = ScholarCLIRunner(environment: env)

        // 1. Offline JSON output structure
        let offlineRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", mainTexURL.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(offlineRes.exitCode == 0, "stderr=\(offlineRes.stderr)")

        let topObj = try #require(
            try JSONSerialization.jsonObject(with: Data(offlineRes.stdout.utf8)) as? [String: Any],
            "diagnostics --json must be a top-level JSON object, not an array"
        )
        let expectedTopKeys: Set<String> = [
            "schema", "mode", "root", "files", "bibliographySources",
            "citations", "uncitedEntries", "labels", "references",
            "diagnostics", "complete", "counts"
        ]
        #expect(Set(topObj.keys) == expectedTopKeys)
        #expect(topObj["schema"] as? String == "scholaros.diagnostics/1")
        #expect(topObj["mode"] as? String == "offline")
        #expect(topObj["root"] as? String == "main.tex")
        #expect(topObj["complete"] as? Bool == false)

        let files = try #require(topObj["files"] as? [[String: Any]])
        #expect(files.count == 2)
        #expect(files[0]["path"] as? String == "main.tex")
        #expect(files[0]["encoding"] as? String == "utf-8")
        #expect(files[0]["includedFrom"] is NSNull)
        #expect(files[1]["path"] as? String == "sections/sub.tex")
        #expect(files[1]["encoding"] as? String == "utf-8")
        #expect(files[1]["includedFrom"] as? String == "main.tex:6")

        let bibSources = try #require(topObj["bibliographySources"] as? [[String: Any]])
        #expect(bibSources.count == 1)
        #expect(bibSources[0]["kind"] as? String == "bib")
        #expect(bibSources[0]["path"] as? String == "refs.bib")
        #expect(bibSources[0]["entries"] as? Int == 2)
        #expect((bibSources[0]["errors"] as? [Any])?.isEmpty == true)

        let citations = try #require(topObj["citations"] as? [[String: Any]])
        #expect(citations.map { $0["key"] as? String } == ["missing_key", "real_lecun"])

        let missingCite = citations[0]
        #expect(missingCite["defined"] as? Bool == false)
        #expect(missingCite["source"] is NSNull)
        #expect(missingCite["verification"] is NSNull)
        let missingOccs = try #require(missingCite["occurrences"] as? [[String: Any]])
        #expect(missingOccs.count == 1)
        #expect(missingOccs[0]["file"] as? String == "main.tex")
        #expect(missingOccs[0]["command"] as? String == "\\cite")

        let definedCite = citations[1]
        #expect(definedCite["defined"] as? Bool == true)
        #expect(definedCite["source"] as? String == "refs.bib")
        let definedOccs = try #require(definedCite["occurrences"] as? [[String: Any]])
        #expect(definedOccs.count == 2)
        let verification = try #require(definedCite["verification"] as? [String: Any])
        #expect(verification["verdict"] as? String == "UNVERIFIED")
        #expect(verification["reasons"] as? [String] == ["offline"])
        #expect(verification["insertable"] as? Bool == false)
        #expect((verification["sources"] as? [Any])?.isEmpty == true)
        #expect((verification["fields"] as? [Any])?.isEmpty == true)

        let uncited = try #require(topObj["uncitedEntries"] as? [String])
        #expect(uncited == ["uncited_entry"])

        // Labels: duplicate `sec:dup` must appear once per occurrence (2 entries) + `sec:intro` (1 entry) = 3 total
        let labels = try #require(topObj["labels"] as? [[String: Any]])
        #expect(labels.count == 3)
        let dupLabels = labels.filter { ($0["key"] as? String) == "sec:dup" }
        #expect(dupLabels.count == 2)
        #expect(Set(dupLabels.compactMap { $0["file"] as? String }) == ["main.tex", "sections/sub.tex"])

        let refs = try #require(topObj["references"] as? [[String: Any]])
        #expect(refs.count == 2)
        let introRef = try #require(refs.first { ($0["key"] as? String) == "sec:intro" })
        #expect(introRef["resolved"] as? Bool == true)
        #expect(introRef["command"] as? String == "\\ref")
        let missingRef = try #require(refs.first { ($0["key"] as? String) == "sec:missing" })
        #expect(missingRef["resolved"] as? Bool == false)

        let diags = try #require(topObj["diagnostics"] as? [[String: Any]])
        #expect(!diags.isEmpty)
        let expectedDiagKeys: Set<String> = ["code", "category", "severity", "file", "line", "column", "message"]
        for d in diags {
            #expect(Set(d.keys) == expectedDiagKeys, "Diagnostic object must not include random id or extra keys: \(d)")
        }
        #expect(diags.contains { ($0["code"] as? String) == "CITE404" && ($0["category"] as? String) == "structure" })
        #expect(diags.contains { ($0["code"] as? String) == "SYM003" && ($0["category"] as? String) == "structure" })
        #expect(diags.contains { ($0["code"] as? String) == "SYM004" && ($0["category"] as? String) == "structure" })
        #expect(diags.contains { ($0["code"] as? String) == "ERR_UNVERIFIED_CITATION" && ($0["category"] as? String) == "citation" })
        #expect(diags.contains { ($0["code"] as? String) == "LINT_UNCITED_BIB_ENTRY" && ($0["category"] as? String) == "lint" })

        let counts = try #require(topObj["counts"] as? [String: Any])
        let byCode = try #require(counts["byCode"] as? [String: Int])
        let bySeverity = try #require(counts["bySeverity"] as? [String: Int])
        let verdictCounts = try #require(counts["verdicts"] as? [String: Int])
        #expect(byCode.values.reduce(0, +) == diags.count)
        #expect(bySeverity.values.reduce(0, +) == diags.count)
        #expect(verdictCounts["UNVERIFIED"] == 1)
        #expect(verdictCounts["VERIFIED"] == 0)

        // 2. Replay mode sets top-level "mode": "REPLAY" and "complete": true when all cited defined entries resolve
        let replayTexURL = tempDir.appendingPathComponent("replay.tex")
        try """
        \\documentclass{article}
        \\begin{document}
        \\section{Intro}
        Verified~\\cite{real_lecun}.
        \\end{document}
        """.write(to: replayTexURL, atomically: true, encoding: .utf8)
        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let replayRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", replayTexURL.path, "--bib", bibURL.path, "--registry-replay", registryDir.path, "--json", "--lang", "en"]
        )
        #expect(replayRes.exitCode == 0, "stderr=\(replayRes.stderr)")
        let replayObj = try #require(try JSONSerialization.jsonObject(with: Data(replayRes.stdout.utf8)) as? [String: Any])
        #expect(replayObj["mode"] as? String == "REPLAY")
        #expect(replayObj["complete"] as? Bool == true)

        // 3. Plain-text output remains unchanged (`[SEVERITY] CODE file:line:col - message`)
        let textRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", mainTexURL.path, "--offline", "--lang", "en"]
        )
        #expect(textRes.stdout.contains("[ERROR] CITE404 main.tex:"))
    }

    @Test("M2 item 6 & S63 (Stage 01): diagnostics --json and LSPDiagnostic contain no random UUIDs and produce byte-identical output across repeated runs")
    func m2Stage01DiagnosticsJSONByteIdenticalAcrossRepeatedRunsAndNoRandomID() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage01-det")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let env: [String: String] = [
            "HOME": isolatedHome.path,
            "CFFIXED_USER_HOME": isolatedHome.path
        ]

        // 1. Two separately constructed LSPDiagnostic values with identical fields must be equal and encode identically
        let span = TextSpan(
            filePath: "main.tex",
            start: TextPosition(line: 10, column: 5),
            end: TextPosition(line: 10, column: 20)
        )
        let d1 = LSPDiagnostic(code: "SYM003", severity: .error, message: "Duplicate label 'x'.", span: span)
        let d2 = LSPDiagnostic(code: "SYM003", severity: .error, message: "Duplicate label 'x'.", span: span)
        #expect(d1 == d2, "LSPDiagnostic must not carry a random UUID per instance")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let d1Bytes = try enc.encode(d1)
        let d2Bytes = try enc.encode(d2)
        #expect(d1Bytes == d2Bytes)

        // 2. Repeated `diagnostics <paper.tex> --offline --json` runs on a real multi-diagnostic benchmark manuscript must be byte-for-byte identical
        let benchmarkTex = repositoryRoot.appendingPathComponent("Benchmarks/manuscripts/2503.18124v1/src/main.tex")
        let runner1 = ScholarCLIRunner(environment: env)
        let runner2 = ScholarCLIRunner(environment: env)

        let run1 = await runner1.runWithExitStatus(arguments: ["diagnostics", benchmarkTex.path, "--offline", "--json", "--lang", "en"])
        let run2 = await runner2.runWithExitStatus(arguments: ["diagnostics", benchmarkTex.path, "--offline", "--json", "--lang", "en"])
        #expect(run1.exitCode == 0)
        #expect(run2.exitCode == 0)
        #expect(!run1.stdout.isEmpty)
        #expect(!run1.stdout.contains("\"id\""), "diagnostics --json must not contain random id fields")
        #expect(Data(run1.stdout.utf8) == Data(run2.stdout.utf8), "Two runs of diagnostics --offline --json must be byte-for-byte identical")
    }

    // MARK: - 18. M2 Stage 02: Unified Manuscript Loader (Items 1–5)

    @Test("M2 Stage 02 item 1: unified loader resolves all 7 include syntaxes via lexer tokens (ignoring comments & verbatim), tries exact path before .tex, and drives both diagnostics and outline")
    func m2Stage02Item1SevenIncludeSyntaxesExactBeforeTexCommentsAndVerbatimIgnoredInDiagnosticsAndOutline() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage02-item1")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let runner = ScholarCLIRunner(environment: ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path])

        let mainTex = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/loader-multi/main.tex")
        let diagRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", mainTex.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(diagRes.exitCode != 2, "stderr=\(diagRes.stderr)")
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(diagRes.stdout.utf8)) as? [String: Any])

        let files = try #require(obj["files"] as? [[String: Any]])
        let filePaths = files.compactMap { $0["path"] as? String }
        #expect(filePaths == [
            "main.tex",
            "chapters/ch_one.tex",
            "chapters/ch_two.tex",
            "sections/braced_input.tex",
            "sections/unbraced_input.tex",
            "sections/if_exists.tex",
            "sections/sub_doc.tex",
            "modules/mod_a/entry.tex",
            "modules/mod_a/nested/leaf.tex",
            "snippets/exact_name.inc"
        ])
        #expect(!filePaths.contains("sections/commented_out.tex"))

        let labels = try #require(obj["labels"] as? [[String: Any]])
        let labelKeys = Set(labels.compactMap { $0["key"] as? String })
        #expect(labelKeys == [
            "ch:m_one", "ch:m_two", "sec:braced", "sec:unbraced",
            "sec:ifexists", "sec:subfile", "sec:imported", "sec:subimported", "sec:exact"
        ])
        #expect(!labelKeys.contains("sec:commented_out"))

        let diags = try #require(obj["diagnostics"] as? [[String: Any]])
        let inc002 = diags.filter { ($0["code"] as? String) == "INC002" }
        #expect(inc002.isEmpty, "Unexpected INC002: \(inc002)")

        // `outline` must also use the unified loader and include sections from unbraced \input, \InputIfFileExists, \subfile, \import, \subimport, and exact-extension files
        let outlineRes = await runner.runWithExitStatus(
            arguments: ["outline", mainTex.path, "--json", "--lang", "en"]
        )
        #expect(outlineRes.exitCode == 0, "stderr=\(outlineRes.stderr)")
        let outlineArr = try #require(try JSONSerialization.jsonObject(with: Data(outlineRes.stdout.utf8)) as? [[String: Any]])
        let outlineTitles = outlineArr.compactMap { $0["title"] as? String }
        #expect(outlineTitles.contains("Unbraced Input"))
        #expect(outlineTitles.contains("IfExists Input"))
        #expect(outlineTitles.contains("Subfile Section"))
        #expect(outlineTitles.contains("Imported Entry"))
        #expect(outlineTitles.contains("Subimported Leaf"))
        #expect(outlineTitles.contains("Exact Extension Snippet"))
        #expect(!outlineTitles.contains("Commented Out"))
    }

    @Test("M2 Stage 02 item 2 (S69): invalid UTF-8 root and child files fall back to Windows-1252, emit WARNING ENC001 per file, and never skip or exit 2")
    func m2Stage02Item2Windows1252EncodingFallbackAndENC001Warning() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage02-item2")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let runner = ScholarCLIRunner(environment: ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path])

        let mainTex = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/loader-encoding/main.tex")
        let diagRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", mainTex.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(diagRes.exitCode != 2, "Windows-1252 manuscript must not exit 2; stderr=\(diagRes.stderr)")
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(diagRes.stdout.utf8)) as? [String: Any])

        let files = try #require(obj["files"] as? [[String: Any]])
        try #require(files.count == 2)
        #expect(files[0]["path"] as? String == "main.tex")
        #expect(files[0]["encoding"] as? String == "windows-1252")
        #expect(files[1]["path"] as? String == "sub.tex")
        #expect(files[1]["encoding"] as? String == "windows-1252")
        #expect(files[1]["includedFrom"] as? String == "main.tex:5")

        let labels = try #require(obj["labels"] as? [[String: Any]])
        #expect(Set(labels.compactMap { $0["key"] as? String }) == ["sec:poincare", "sec:gauss"])
        let citations = try #require(obj["citations"] as? [[String: Any]])
        #expect(Set(citations.compactMap { $0["key"] as? String }) == ["knuth1968", "lecun2015"])

        let diags = try #require(obj["diagnostics"] as? [[String: Any]])
        let enc001 = diags.filter { ($0["code"] as? String) == "ENC001" }
        #expect(enc001.count == 2, "Expected 2 ENC001 warnings (main.tex and sub.tex), got \(enc001)")
        for d in enc001 {
            #expect(d["severity"] as? String == "WARNING")
            #expect(d["category"] as? String == "structure")
        }
        #expect(Set(enc001.compactMap { $0["file"] as? String }) == ["main.tex", "sub.tex"])
        #expect(diags.filter { ($0["code"] as? String) == "INC002" }.isEmpty)

        // Also check `outline` decodes accents/smart quotes cleanly without failing
        let outlineRes = await runner.runWithExitStatus(
            arguments: ["outline", mainTex.path, "--json", "--lang", "en"]
        )
        #expect(outlineRes.exitCode == 0)
        let outlineArr = try #require(try JSONSerialization.jsonObject(with: Data(outlineRes.stdout.utf8)) as? [[String: Any]])
        let titles = outlineArr.compactMap { $0["title"] as? String }
        #expect(titles.contains { $0.contains("Poincaré") })
        #expect(titles.contains { $0.contains("Gauß") && $0.contains("Müller") })
    }

    @Test("M2 Stage 02 item 3 (S59): existing .bib no longer triggers false INC002, and genuinely missing included file reports ERROR INC002 with exact including file and line")
    func m2Stage02Item3NoFalseINC002OnExistingBibAndExactFileLineOnMissingInclude() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage02-item3")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let runner = ScholarCLIRunner(environment: ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path])

        // 1. Existing .bib in Tests/Fixtures/manuscripts/include-multi/main.tex must have 0 INC002 and match Tectonic expected sets
        let includeMultiTex = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/include-multi/main.tex")
        let includeMultiExpURL = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/expected/include-multi.json")
        let expObj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: includeMultiExpURL)) as? [String: Any])

        let okRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", includeMultiTex.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(okRes.exitCode != 2)
        let okObj = try #require(try JSONSerialization.jsonObject(with: Data(okRes.stdout.utf8)) as? [String: Any])
        let okDiags = try #require(okObj["diagnostics"] as? [[String: Any]])
        #expect(okDiags.filter { ($0["code"] as? String) == "INC002" }.isEmpty, "Existing refs.bib must not emit INC002: \(okDiags)")

        let actualCites = Set((okObj["citations"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String })
        let expectedCites = Set(expObj["cite_keys"] as? [String] ?? [])
        #expect(actualCites == expectedCites)
        let actualLabels = Set((okObj["labels"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String })
        let expectedLabels = Set(expObj["labels"] as? [String] ?? [])
        #expect(actualLabels == expectedLabels)

        // 2. Genuinely missing included file inside child `sections/intro.tex` line 3 emits ERROR INC002 at sections/intro.tex:3
        let missingInputTex = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/loader-missing/missing-input/main.tex")
        let missRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", missingInputTex.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(missRes.exitCode != 2)
        let missObj = try #require(try JSONSerialization.jsonObject(with: Data(missRes.stdout.utf8)) as? [String: Any])
        let missDiags = try #require(missObj["diagnostics"] as? [[String: Any]])
        let inc002List = missDiags.filter { ($0["code"] as? String) == "INC002" }
        try #require(inc002List.count == 1)
        #expect(inc002List[0]["severity"] as? String == "ERROR")
        #expect(inc002List[0]["category"] as? String == "structure")
        #expect(inc002List[0]["file"] as? String == "sections/intro.tex")
        #expect(inc002List[0]["line"] as? Int == 3)
    }

    @Test("M2 Stage 02 item 4 (S61, S71): child-file \\bibliography{a,b} & \\addbibresource, optional .bib suffix, main .bbl fallback with INFO BIB_FROM_BBL, INC002 when both absent, --bib exclusive override, and no INC002 on thebibliography")
    func m2Stage02Item4BibliographyDiscoveryBblFallbackAndExplicitBibOverride() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage02-item4")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let runner = ScholarCLIRunner(environment: ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path])

        // 4a. Child-file \bibliography{refs_main, refs_extra.bib} and \addbibresource{refs_biblatex} (ignoring commented ghost_bib)
        let loaderMultiTex = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/loader-multi/main.tex")
        let multiRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", loaderMultiTex.path, "--offline", "--json", "--lang", "en"]
        )
        let multiObj = try #require(try JSONSerialization.jsonObject(with: Data(multiRes.stdout.utf8)) as? [String: Any])
        let multiCites = try #require(multiObj["citations"] as? [[String: Any]])
        #expect(multiCites.map { $0["key"] as? String } == ["k_biblatex", "k_extra", "k_leaf", "k_one", "k_sub", "k_two"])
        #expect(multiCites.allSatisfy { ($0["defined"] as? Bool) == true })
        let multiDiags = try #require(multiObj["diagnostics"] as? [[String: Any]])
        #expect(multiDiags.filter { ($0["code"] as? String) == "CITE404" }.isEmpty)
        #expect(multiDiags.filter { ($0["code"] as? String) == "INC002" }.isEmpty)

        // 4b. Missing .bib (`custom`) with matching `<main>.bbl` (`acl_latex.bbl`) reads .bbl, emits INFO BIB_FROM_BBL, and emits 0 INC002
        let bblFallbackTex = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/loader-missing/bbl-fallback/acl_latex.tex")
        let bblRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", bblFallbackTex.path, "--offline", "--json", "--lang", "en"]
        )
        let bblObj = try #require(try JSONSerialization.jsonObject(with: Data(bblRes.stdout.utf8)) as? [String: Any])
        let bblDiags = try #require(bblObj["diagnostics"] as? [[String: Any]])
        #expect(bblDiags.filter { ($0["code"] as? String) == "INC002" }.isEmpty, "Should not emit INC002 when <main>.bbl exists: \(bblDiags)")
        let bibFromBbl = bblDiags.filter { ($0["code"] as? String) == "BIB_FROM_BBL" }
        try #require(bibFromBbl.count == 1)
        #expect(bibFromBbl[0]["severity"] as? String == "INFO")
        #expect(bibFromBbl[0]["category"] as? String == "structure")
        #expect(bibFromBbl[0]["file"] as? String == "acl_latex.tex")
        #expect(bibFromBbl[0]["line"] as? Int == 6)
        let bblSources = try #require(bblObj["bibliographySources"] as? [[String: Any]])
        try #require(bblSources.count == 1)
        #expect(bblSources[0]["kind"] as? String == "bbl")
        #expect(bblSources[0]["path"] as? String == "acl_latex.bbl")

        // 4c. Missing .bib without `<main>.bbl` emits ERROR INC002 at exact line
        let missingBibTex = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/loader-missing/missing-bib/main.tex")
        let missBibRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", missingBibTex.path, "--offline", "--json", "--lang", "en"]
        )
        let missBibObj = try #require(try JSONSerialization.jsonObject(with: Data(missBibRes.stdout.utf8)) as? [String: Any])
        let missBibDiags = try #require(missBibObj["diagnostics"] as? [[String: Any]])
        let missBibInc002 = missBibDiags.filter { ($0["code"] as? String) == "INC002" }
        try #require(missBibInc002.count == 1)
        #expect(missBibInc002[0]["file"] as? String == "main.tex")
        #expect(missBibInc002[0]["line"] as? Int == 5)

        // 4d. Explicit `--bib` overrides manuscript `\bibliography{nothere}` without emitting INC002
        let overrideBib = tempDir.appendingPathComponent("override.bib")
        try """
        @article{smith2024, author={Smith, Jane}, title={Override Entry}, journal={J}, year={2024}}
        """.write(to: overrideBib, atomically: true, encoding: .utf8)
        let overrideRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", missingBibTex.path, "--bib", overrideBib.path, "--offline", "--json", "--lang", "en"]
        )
        let overrideObj = try #require(try JSONSerialization.jsonObject(with: Data(overrideRes.stdout.utf8)) as? [String: Any])
        let overrideDiags = try #require(overrideObj["diagnostics"] as? [[String: Any]])
        #expect(overrideDiags.filter { ($0["code"] as? String) == "INC002" }.isEmpty, "Explicit --bib must suppress missing implicit .bib INC002: \(overrideDiags)")
        #expect(overrideDiags.filter { ($0["code"] as? String) == "CITE404" }.isEmpty)
        let overrideSources = try #require(overrideObj["bibliographySources"] as? [[String: Any]])
        try #require(overrideSources.count == 1)
        #expect(overrideSources[0]["kind"] as? String == "bib")
        #expect(overrideSources[0]["entries"] as? Int == 1)

        // 4e. Manuscript with `thebibliography` and no `.bib` (`2506.06594v1`) emits 0 INC002
        let thebibTex = repositoryRoot.appendingPathComponent("Benchmarks/manuscripts/2506.06594v1/src/From_Adaptive_Control_Evolving_Control.tex")
        let thebibRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", thebibTex.path, "--offline", "--json", "--lang", "en"]
        )
        let thebibObj = try #require(try JSONSerialization.jsonObject(with: Data(thebibRes.stdout.utf8)) as? [String: Any])
        let thebibDiags = try #require(thebibObj["diagnostics"] as? [[String: Any]])
        #expect(thebibDiags.filter { ($0["code"] as? String) == "INC002" }.isEmpty)
    }

    @Test("M2 Stage 02 item 5 (S60, S61): JSON files and bibliographySources list exact read files and sources across 2405.13682v5 (\\input{main.bbl}), 2501.00066v2 (commented \\bibliography), and 2410.04196v2 (unused template .bib)")
    func m2Stage02Item5JSONFilesAndBibliographySourcesExactness() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage02-item5")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let runner = ScholarCLIRunner(environment: ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path])

        // 1. 2405.13682v5: `\input{main.bbl}` on line 97 must appear in `files` as `main.bbl` (not skipped as `main.bbl.tex`), 0 INC002
        let p2405 = repositoryRoot.appendingPathComponent("Benchmarks/manuscripts/2405.13682v5/src/main.tex")
        let res2405 = await runner.runWithExitStatus(
            arguments: ["diagnostics", p2405.path, "--offline", "--json", "--lang", "en"]
        )
        let obj2405 = try #require(try JSONSerialization.jsonObject(with: Data(res2405.stdout.utf8)) as? [String: Any])
        let files2405 = try #require(obj2405["files"] as? [[String: Any]])
        let paths2405 = files2405.compactMap { $0["path"] as? String }
        #expect(paths2405.contains("main.bbl"), "Expected main.bbl in files of 2405.13682v5, got \(paths2405)")
        #expect(paths2405.contains("src/supp-ridgelet-quick.tex"))
        #expect(paths2405.count == 18) // 17 .tex + 1 main.bbl
        let bblFileRec = try #require(files2405.first { ($0["path"] as? String) == "main.bbl" })
        #expect(bblFileRec["includedFrom"] as? String == "main.tex:97")
        let diags2405 = try #require(obj2405["diagnostics"] as? [[String: Any]])
        #expect(diags2405.filter { ($0["code"] as? String) == "INC002" }.isEmpty)

        // 2. 2501.00066v2: commented `% \bibliography{iclr2024_conference}` must not duplicate bibliographySources, 0 INC002
        let p2501 = repositoryRoot.appendingPathComponent("Benchmarks/manuscripts/2501.00066v2/src/main.tex")
        let res2501 = await runner.runWithExitStatus(
            arguments: ["diagnostics", p2501.path, "--offline", "--json", "--lang", "en"]
        )
        let obj2501 = try #require(try JSONSerialization.jsonObject(with: Data(res2501.stdout.utf8)) as? [String: Any])
        let bib2501 = try #require(obj2501["bibliographySources"] as? [[String: Any]])
        #expect(bib2501.count == 1, "Commented \\bibliography must not read .bib twice: \(bib2501)")
        if let firstBib2501 = bib2501.first {
            #expect(firstBib2501["path"] as? String == "iclr2024_conference.bib")
        }
        let diags2501 = try #require(obj2501["diagnostics"] as? [[String: Any]])
        #expect(diags2501.filter { ($0["code"] as? String) == "INC002" }.isEmpty)

        // 3. 2410.04196v2: 12 reachable .tex files (commented `sections/tables/runtime` excluded), only `fhbi.bib` in bibliographySources (`example_paper.bib` excluded), 0 INC002
        let p2410 = repositoryRoot.appendingPathComponent("Benchmarks/manuscripts/2410.04196v2/src/main.tex")
        let res2410 = await runner.runWithExitStatus(
            arguments: ["diagnostics", p2410.path, "--offline", "--json", "--lang", "en"]
        )
        let obj2410 = try #require(try JSONSerialization.jsonObject(with: Data(res2410.stdout.utf8)) as? [String: Any])
        let files2410 = try #require(obj2410["files"] as? [[String: Any]])
        #expect(files2410.count == 12)
        let bib2410 = try #require(obj2410["bibliographySources"] as? [[String: Any]])
        #expect(bib2410.map { $0["path"] as? String } == ["fhbi.bib"])
        let diags2410 = try #require(obj2410["diagnostics"] as? [[String: Any]])
        #expect(diags2410.filter { ($0["code"] as? String) == "INC002" }.isEmpty)
    }

    // MARK: - 19. M2 Stage 03: Per-Syntax Verbatim/Opaque Skip Fixtures

    @Test("M2 Stage 03 item 4: all 19 per-syntax fixtures in Tests/Fixtures/manuscripts/verbatim-skip match handwritten expected citation keys, labels, 0 fake* leaks, and 0 structure ERRORs")
    func m2Stage03Item4AllPerSyntaxVerbatimSkipFixturesMatchHandwrittenExpected() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage03-item4")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let runner = ScholarCLIRunner(environment: ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path])

        let fixtureDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/verbatim-skip", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(at: fixtureDir, includingPropertiesForKeys: nil)
        let expectedFiles = contents
            .filter { $0.lastPathComponent.hasSuffix(".expected.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        #expect(expectedFiles.count == 19, "Expected 19 per-syntax expected files, found \(expectedFiles.count)")

        for expURL in expectedFiles {
            let expData = try Data(contentsOf: expURL)
            let expObj = try #require(try JSONSerialization.jsonObject(with: expData) as? [String: Any])
            let caseSlug = try #require(expObj["case"] as? String)
            let expectedCites = Set(try #require(expObj["cite_keys"] as? [String]))
            let expectedLabels = Set(try #require(expObj["labels"] as? [String]))
            let expectedStructErrs = try #require(expObj["structure_errors"] as? Int)

            let texURL = fixtureDir.appendingPathComponent("\(caseSlug).tex")
            #expect(FileManager.default.fileExists(atPath: texURL.path), "Missing \(texURL.path)")

            let res = await runner.runWithExitStatus(
                arguments: ["diagnostics", texURL.path, "--offline", "--json", "--lang", "en"]
            )
            #expect(res.exitCode != 2, "[\(caseSlug)] CLI exited 2: \(res.stderr)")
            let actualObj = try #require(try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any])

            let citesArr = try #require(actualObj["citations"] as? [[String: Any]])
            let actualCites = Set(citesArr.compactMap { $0["key"] as? String })
            let labelsArr = try #require(actualObj["labels"] as? [[String: Any]])
            let actualLabels = Set(labelsArr.compactMap { $0["key"] as? String })
            let diagsArr = try #require(actualObj["diagnostics"] as? [[String: Any]])
            let structErrors = diagsArr.filter {
                ($0["category"] as? String) == "structure" && ($0["severity"] as? String) == "ERROR"
            }

            #expect(actualCites == expectedCites, "[\(caseSlug)] cite_keys mismatch: actual=\(actualCites) expected=\(expectedCites)")
            #expect(actualLabels == expectedLabels, "[\(caseSlug)] labels mismatch: actual=\(actualLabels) expected=\(expectedLabels)")
            #expect(actualCites.filter { $0.hasPrefix("fake") }.isEmpty, "[\(caseSlug)] leaked fake cite keys: \(actualCites)")
            #expect(actualLabels.filter { $0.hasPrefix("fake") }.isEmpty, "[\(caseSlug)] leaked fake labels: \(actualLabels)")
            #expect(structErrors.count == expectedStructErrs, "[\(caseSlug)] expected \(expectedStructErrs) structure ERRORs, got \(structErrors)")
        }
    }

    // MARK: - 20. M2 Stage 04: CITE_KEY_CASE, 2409/2410 Benchmarks, and Parser-Commands Fixtures

    @Test("M2 Stage 04 item 4b (S66): case-insensitive .bib fallback marks bayestune defined, emits WARNING CITE_KEY_CASE naming both spellings with 0 CITE404 on 2410.04196v2, and 2409.19431v3 matches expected sets")
    func m2Stage04Item4bCiteKeyCaseWarningAnd2410And2409EndToEnd() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage04-item4b")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let runner = ScholarCLIRunner(environment: ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path])

        // 1. 2410.04196v2: `\citep{bayestune}` vs `@inproceedings{Bayestune, ...}` in `fhbi.bib`
        let p2410 = repositoryRoot.appendingPathComponent("Benchmarks/manuscripts/2410.04196v2/src/main.tex")
        let res2410 = await runner.runWithExitStatus(
            arguments: ["diagnostics", p2410.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(res2410.exitCode != 2)
        let obj2410 = try #require(try JSONSerialization.jsonObject(with: Data(res2410.stdout.utf8)) as? [String: Any])
        let cites2410 = try #require(obj2410["citations"] as? [[String: Any]])
        let bayestuneRec = try #require(cites2410.first { ($0["key"] as? String) == "bayestune" })
        #expect(bayestuneRec["defined"] as? Bool == true, "bayestune must be marked defined via case-insensitive match to Bayestune")
        #expect(bayestuneRec["source"] as? String == "fhbi.bib")
        #expect(bayestuneRec["verification"] is [String: Any], "bayestune must receive M1 verification object from Bayestune")

        let uncited2410 = Set(try #require(obj2410["uncitedEntries"] as? [String]))
        #expect(!uncited2410.contains("Bayestune"), "Bayestune matched by bayestune must not be listed in uncitedEntries")

        let diags2410 = try #require(obj2410["diagnostics"] as? [[String: Any]])
        #expect(diags2410.filter { ($0["code"] as? String) == "CITE404" }.isEmpty, "Expected 0 CITE404 on 2410.04196v2")
        #expect(diags2410.filter { (($0["code"] as? String) ?? "").hasPrefix("AST") }.isEmpty, "Expected 0 AST* on 2410.04196v2")
        let caseWarns = diags2410.filter { ($0["code"] as? String) == "CITE_KEY_CASE" }
        try #require(caseWarns.count == 1)
        #expect(caseWarns[0]["severity"] as? String == "WARNING")
        #expect(caseWarns[0]["category"] as? String == "structure")
        let warnMsg = try #require(caseWarns[0]["message"] as? String)
        #expect(warnMsg.contains("bayestune") && warnMsg.contains("Bayestune"), "CITE_KEY_CASE message must name both spellings: \(warnMsg)")

        // 2. 2409.19431v3: Row 1 sets (79 cite_keys, 167 labels) and 0 structure ERRORs
        let p2409 = repositoryRoot.appendingPathComponent("Benchmarks/manuscripts/2409.19431v3/src/ICML_Camera_Ready_GE_tilted.tex")
        let exp2409URL = repositoryRoot.appendingPathComponent("Benchmarks/manuscripts/2409.19431v3/expected.json")
        let exp2409 = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: exp2409URL)) as? [String: Any])
        let res2409 = await runner.runWithExitStatus(
            arguments: ["diagnostics", p2409.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(res2409.exitCode != 2)
        let obj2409 = try #require(try JSONSerialization.jsonObject(with: Data(res2409.stdout.utf8)) as? [String: Any])
        let actualCites2409 = Set((obj2409["citations"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String })
        let expectedCites2409 = Set(try #require(exp2409["cite_keys"] as? [String]))
        let actualLabels2409 = Set((obj2409["labels"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String })
        let expectedLabels2409 = Set(try #require(exp2409["labels"] as? [String]))
        #expect(actualCites2409 == expectedCites2409)
        #expect(actualLabels2409 == expectedLabels2409)
        let diags2409 = try #require(obj2409["diagnostics"] as? [[String: Any]])
        let structErrs2409 = diags2409.filter {
            ($0["category"] as? String) == "structure" && ($0["severity"] as? String) == "ERROR"
        }
        #expect(structErrs2409.isEmpty, "Expected 0 structure ERRORs on 2409.19431v3, got \(structErrs2409)")
    }

    @Test("M2 Stage 04 item 6: all 63 per-command and per-construct fixtures in Tests/Fixtures/manuscripts/parser-commands match expected citations, labels, references, warnings, and 0 AST*/INC002 errors")
    func m2Stage04Item6AllParserCommandSmallFixturesMatchExpected() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage04-item6")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let isolatedHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let runner = ScholarCLIRunner(environment: ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path])

        let fixtureDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/parser-commands", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(at: fixtureDir, includingPropertiesForKeys: nil)
        let expectedFiles = contents
            .filter { $0.lastPathComponent.hasSuffix(".expected.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        #expect(expectedFiles.count == 63, "Expected 63 parser-commands expected files, found \(expectedFiles.count)")

        for expURL in expectedFiles {
            let expObj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: expURL)) as? [String: Any])
            let slug = try #require(expObj["case"] as? String)
            let expectedCites = Set(try #require(expObj["cite_keys"] as? [String]))
            let expectedLabels = Set(try #require(expObj["labels"] as? [String]))
            let expectedRefs = Set(try #require(expObj["references"] as? [String]))
            let expectedStructErrs = try #require(expObj["structure_errors"] as? Int)
            let expectedWarnings = Set(try #require(expObj["expected_warnings"] as? [String]))

            let texURL = fixtureDir.appendingPathComponent("\(slug).tex")
            #expect(FileManager.default.fileExists(atPath: texURL.path), "Missing \(texURL.path)")

            let res = await runner.runWithExitStatus(
                arguments: ["diagnostics", texURL.path, "--offline", "--json", "--lang", "en"]
            )
            #expect(res.exitCode != 2, "[\(slug)] CLI exited 2: \(res.stderr)")
            let actualObj = try #require(try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any])

            let actualCites = Set((actualObj["citations"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String })
            let actualLabels = Set((actualObj["labels"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String })
            let actualRefs = Set((actualObj["references"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String })
            let diagsArr = try #require(actualObj["diagnostics"] as? [[String: Any]])
            let structErrors = diagsArr.filter {
                ($0["category"] as? String) == "structure" && ($0["severity"] as? String) == "ERROR"
            }
            let astDiags = diagsArr.filter { (($0["code"] as? String) ?? "").hasPrefix("AST") }
            let inc002Diags = diagsArr.filter { ($0["code"] as? String) == "INC002" }
            let warningCodes = Set(
                diagsArr
                    .filter { ($0["severity"] as? String) == "WARNING" }
                    .compactMap { $0["code"] as? String }
            )

            #expect(actualCites == expectedCites, "[\(slug)] cite_keys mismatch: actual=\(actualCites) expected=\(expectedCites)")
            #expect(actualLabels == expectedLabels, "[\(slug)] labels mismatch: actual=\(actualLabels) expected=\(expectedLabels)")
            #expect(actualRefs == expectedRefs, "[\(slug)] references mismatch: actual=\(actualRefs) expected=\(expectedRefs)")
            #expect(structErrors.count == expectedStructErrs, "[\(slug)] expected \(expectedStructErrs) structure ERRORs, got \(structErrors)")
            #expect(astDiags.isEmpty, "[\(slug)] unexpected AST* diagnostics: \(astDiags)")
            #expect(inc002Diags.isEmpty, "[\(slug)] unexpected INC002 diagnostics: \(inc002Diags)")
            for reqWarn in expectedWarnings {
                #expect(warningCodes.contains(reqWarn), "[\(slug)] missing expected WARNING \(reqWarn) in \(diagsArr)")
            }
        }
    }

    @Test("M2 Stage 05 item 1 (S9, S49): BibTeX single-entry error recovery on bib-recovery/ten.bib records e3 (startLine 15, line 22), preserves partial fields with parseError=true, recovers all 9 remaining entries, and emits BIB001 in diagnostics")
    func m2Stage05Item1BibRecoveryTenBibSingleEntryErrorRecovery() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage05-item1")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let recDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/bib-recovery", isDirectory: true)
        let tenBibURL = recDir.appendingPathComponent("ten.bib")
        let mainTexURL = recDir.appendingPathComponent("main.tex")
        let tenRaw = try String(contentsOf: tenBibURL, encoding: .utf8)

        let doc = try BibTeXCodec().parseDocument(tenRaw)
        #expect(doc.errors.count == 1, "Expected 1 BibTeX entry parse error on ten.bib, got \(doc.errors)")
        if let err = doc.errors.first {
            #expect(err.key == "e3")
            #expect(err.startLine == 15)
            #expect(err.line == 22)
        }

        #expect(doc.entries.count == 10, "Expected 10 recovered entries (9 clean + partial e3), got \(doc.entries.count)")
        let byKey = Dictionary(uniqueKeysWithValues: doc.entries.map { ($0.citeKey, $0) })

        let e3 = try #require(byKey["e3"])
        #expect(e3.parseError == true)
        #expect(e3.parseErrorInfo?.startLine == 15)
        #expect(e3.parseErrorInfo?.line == 22)
        #expect(e3.authors == [BibAuthor(givenName: "C", familyName: "Three")])
        #expect(e3.title.contains("Broken title"))
        #expect(e3.year == nil)
        #expect(e3.venue.isEmpty)

        for idx in [1, 2, 4, 5, 6, 7, 8, 9, 10] {
            let key = "e\(idx)"
            let ent = try #require(byKey[key], "Missing recovered entry \(key)")
            #expect(ent.parseError == false, "Expected \(key).parseError == false")
            #expect(ent.authors == [BibAuthor(givenName: "A", familyName: "Author\(idx)")])
            #expect(ent.title == "Title \(idx)")
            #expect(ent.venue == "J")
            #expect(ent.year == 2000 + idx)
        }

        let runner = ScholarCLIRunner(
            environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path]
        )
        for args in [
            ["diagnostics", mainTexURL.path, "--offline", "--json", "--lang", "en"],
            ["diagnostics", mainTexURL.path, "--bib", tenBibURL.path, "--offline", "--json", "--lang", "en"]
        ] {
            let res = await runner.runWithExitStatus(arguments: args)
            #expect(res.exitCode != 2, "diagnostics exited 2 for \(args): \(res.stderr)")
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any])
            let bibSources = try #require(obj["bibliographySources"] as? [[String: Any]])
            #expect(bibSources.count == 1)
            if let src0 = bibSources.first {
                #expect(src0["entries"] as? Int == 10)
                let srcErrors = src0["errors"] as? [[String: Any]] ?? []
                #expect(srcErrors.count == 1)
                if let se = srcErrors.first {
                    #expect(se["key"] as? String == "e3")
                    #expect(se["startLine"] as? Int == 15)
                    #expect(se["line"] as? Int == 22)
                }
            }
            let diags = try #require(obj["diagnostics"] as? [[String: Any]])
            let bib001 = diags.filter { ($0["code"] as? String) == "BIB001" }
            let cite404 = diags.filter { ($0["code"] as? String) == "CITE404" }
            #expect(cite404.isEmpty, "Expected 0 CITE404 on bib-recovery, got \(cite404)")
            #expect(bib001.count == 1, "Expected 1 ERROR BIB001 on bib-recovery, got \(bib001)")
            if let b = bib001.first {
                #expect(b["severity"] as? String == "ERROR")
                #expect(b["category"] as? String == "structure")
                #expect(b["line"] as? Int == 22)
                let msg = b["message"] as? String ?? ""
                #expect(msg.contains("e3") && msg.contains("15") && msg.contains("22"), "BIB001 message must report key e3, startLine 15, line 22: \(msg)")
            }
        }
    }

    @Test("M2 Stage 05 item 2 (S70): BibTeX identifier character rules accept printable chars outside '\"#%'(),={}' including \\pages, and 2503.18124v1 main.bib reads 289 unique keys with 0 BIB001 and 0 CITE404")
    func m2Stage05Item2BibTeXFieldAndKeyCharacterRulesAnd2503MainBib() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage05-item2")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let syntheticBib = """
        @article{key\\slash*tilde~bang!$amp&semi;lt<gt>hat^pipe|[br],
          author = {Roberts, P. H.},
          title = {Kinematic Dynamo Models},
          journal = {Phil. Trans. R. Soc. A},
          year = {1972},
          volume = {272},
          \\pages = {663},
          opt*field~1 = {ignored unknown field}
        }
        """
        let synDoc = try BibTeXCodec().parseDocument(syntheticBib)
        #expect(synDoc.errors.isEmpty)
        #expect(synDoc.entries.count == 1)
        let synEntry = try #require(synDoc.entries.first)
        #expect(synEntry.citeKey == "key\\slash*tilde~bang!$amp&semi;lt<gt>hat^pipe|[br]")
        #expect(synEntry.year == 1972)
        #expect(synEntry.volume == "272")
        #expect(synEntry.pages == nil)
        let synInfos = synDoc.diagnostics.filter { $0.severity == .info }
        let synWarns = synDoc.diagnostics.filter { $0.severity == .warning }
        #expect(synWarns.isEmpty)
        #expect(synInfos.filter { $0.message.contains("\\pages") }.count <= 1)

        let main2503Dir = repositoryRoot.appendingPathComponent("Benchmarks/manuscripts/2503.18124v1/src", isDirectory: true)
        let main2503BibURL = main2503Dir.appendingPathComponent("main.bib")
        let main2503TexURL = main2503Dir.appendingPathComponent("main.tex")
        let main2503BibRaw = try String(contentsOf: main2503BibURL, encoding: .utf8)

        let doc2503 = try BibTeXCodec().parseDocument(main2503BibRaw)
        #expect(doc2503.errors.isEmpty, "Expected 0 parse errors on 2503.18124v1 main.bib, got \(doc2503.errors)")
        #expect(Set(doc2503.entries.map(\.citeKey)).count == 289)
        let kd2 = try #require(doc2503.entries.first { $0.citeKey == "KD_2" })
        #expect(kd2.year == 1972)
        #expect(kd2.volume == "272")

        let runner = ScholarCLIRunner(
            environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path]
        )
        let res = await runner.runWithExitStatus(
            arguments: ["diagnostics", main2503TexURL.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(res.exitCode != 2)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any])
        let bibSources = try #require(obj["bibliographySources"] as? [[String: Any]])
        #expect(bibSources.count == 1)
        #expect(bibSources.first?["entries"] as? Int == 289)
        let firstBibErrors = bibSources.first?["errors"] as? [[String: Any]] ?? []
        #expect(firstBibErrors.isEmpty)

        let diags = try #require(obj["diagnostics"] as? [[String: Any]])
        let structErrors = diags.filter {
            ($0["category"] as? String) == "structure" && ($0["severity"] as? String) == "ERROR"
        }
        let bib001 = diags.filter { ($0["code"] as? String) == "BIB001" }
        let cite404 = diags.filter { ($0["code"] as? String) == "CITE404" }
        #expect(bib001.isEmpty)
        #expect(cite404.isEmpty)
        #expect(structErrors.count == 2, "Expected only 2 SYM003 structure ERRORs on 2503.18124v1, got \(structErrors)")
        #expect(structErrors.allSatisfy { ($0["code"] as? String) == "SYM003" })
    }

    @Test("M2 Stage 05 item 3 (S10): 'and others' sets authorsTruncated=true without fake 'et al.' author, preserves M1 verification behavior, and format-bib never emits 'and et al.'")
    func m2Stage05Item3AuthorsTruncatedAndEtAlFormatting() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage05-item3")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bibFieldsDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/bib-fields", isDirectory: true)
        let refsBibURL = bibFieldsDir.appendingPathComponent("refs.bib")
        let refsRaw = try String(contentsOf: refsBibURL, encoding: .utf8)

        let doc = try BibTeXCodec().parseDocument(refsRaw)
        let byKey = Dictionary(uniqueKeysWithValues: doc.entries.map { ($0.citeKey, $0) })

        let paper1 = try #require(byKey["paper1"])
        #expect(paper1.authors == [
            BibAuthor(givenName: "Alice", familyName: "Smith"),
            BibAuthor(givenName: "Bob", familyName: "Jones")
        ])
        #expect(paper1.authorsTruncated == true)
        #expect(!paper1.authors.contains { $0.familyName.lowercased().contains("et al") })

        let paper2 = try #require(byKey["paper2"])
        #expect(paper2.authorsTruncated == false)

        // BibTeX round-trip preserves `and others`
        let serializedPaper1 = BibTeXCodec().serializeEntry(paper1)
        #expect(serializedPaper1.contains("and others"))
        let reparsedPaper1 = try #require(try BibTeXCodec().parse(serializedPaper1).first)
        #expect(reparsedPaper1.authors.count == 2)
        #expect(reparsedPaper1.authorsTruncated == true)

        // CLI format-bib in IEEE and APA styles must output "et al." without "and" / "&" before it
        let runner = ScholarCLIRunner(
            environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path]
        )
        let ieeeRun = await runner.runWithExitStatus(
            arguments: ["format-bib", refsBibURL.path, "--style", "ieee", "--lang", "en"]
        )
        #expect(ieeeRun.exitCode == 0)
        #expect(ieeeRun.stdout.contains("A. Smith, B. Jones, et al."))
        #expect(!ieeeRun.stdout.contains("and et al."))
        #expect(!ieeeRun.stdout.contains("& et al."))

        let apaRun = await runner.runWithExitStatus(
            arguments: ["format-bib", refsBibURL.path, "--style", "apa", "--lang", "en"]
        )
        #expect(apaRun.exitCode == 0)
        #expect(apaRun.stdout.contains("et al."))
        #expect(!apaRun.stdout.contains("and et al."))
        #expect(!apaRun.stdout.contains("& et al."))

        let csl = CSLCitationFormatterEngine()
        for style in CitationFormatStyle.allCases {
            let formatted = csl.formatEntry(paper1, style: style)
            #expect(!formatted.bibliographyPlainText.contains("and et al."), "Style \(style) emitted 'and et al.': \(formatted.bibliographyPlainText)")
            #expect(!formatted.bibliographyPlainText.contains("& et al."), "Style \(style) emitted '& et al.': \(formatted.bibliographyPlainText)")
            #expect(formatted.inTextParenthetical.contains("Smith et al.") || style == .ieee || style == .nature || style == .vancouver)
            #expect(formatted.inTextNarrative.contains("Smith et al."))
        }

        // M1 firewall check reads `authorsTruncated` with identical behavior
        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let replay = try RegistryReplaySession(directoryURL: registryDir)
        let firewall = CitationVerificationFirewall()
        let daoBib = """
        @inproceedings{dao2022_etal,
          author        = {Dao, Tri and others},
          title         = {FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness},
          booktitle     = {NeurIPS},
          year          = {2022},
          eprint        = {2205.14135},
          archivePrefix = {arXiv}
        }
        """
        let daoEntry = try #require(try BibTeXCodec().parse(daoBib).first)
        #expect(daoEntry.authors == [BibAuthor(givenName: "Tri", familyName: "Dao")])
        #expect(daoEntry.authorsTruncated == true)
        let vDao = await firewall.verifyAgainstPublicRegistries(entry: daoEntry, session: replay)
        #expect(vDao.firewallClass == .verified)
        #expect(vDao.insertable == true)
    }

    @Test("M2 Stage 05 item 4 (S10): crossref inherits missing parent fields without overwriting child fields, warns BIB003 when parent is missing, and suppresses uncited diagnostic on cited entry's parent")
    func m2Stage05Item4CrossrefInheritanceMissingParentWarningAndUncitedSuppression() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage05-item4")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bibFieldsDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/bib-fields", isDirectory: true)
        let refsBibURL = bibFieldsDir.appendingPathComponent("refs.bib")
        let mainTexURL = bibFieldsDir.appendingPathComponent("main.tex")
        let refsRaw = try String(contentsOf: refsBibURL, encoding: .utf8)

        let doc = try BibTeXCodec().parseDocument(refsRaw)
        let byKey = Dictionary(uniqueKeysWithValues: doc.entries.map { ($0.citeKey, $0) })

        let paper1 = try #require(byKey["paper1"])
        #expect(paper1.crossref == "conf2020")
        #expect(paper1.venue == "Child Booktitle Wins")
        #expect(paper1.year == 2020)
        #expect(paper1.publisher == "ACM")
        #expect(paper1.pages == "1–10")
        #expect(paper1.authors.map(\.familyName) == ["Smith", "Jones"])

        let paper2 = try #require(byKey["paper2"])
        #expect(paper2.crossref == "conf2020")
        #expect(paper2.venue == "Proceedings of the 10th Conference on Things")
        #expect(paper2.year == 2020)
        #expect(paper2.publisher == "ACM")
        #expect(paper2.authors == [BibAuthor(givenName: "Carol", familyName: "White")])

        let runner = ScholarCLIRunner(
            environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path]
        )
        let diagRun = await runner.runWithExitStatus(
            arguments: ["diagnostics", mainTexURL.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(diagRun.exitCode != 2)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(diagRun.stdout.utf8)) as? [String: Any])
        let uncited = try #require(obj["uncitedEntries"] as? [String])
        #expect(!uncited.contains("conf2020"), "Cited child's crossref parent conf2020 must not be reported uncited; got \(uncited)")
        #expect(uncited.isEmpty)

        let diags = try #require(obj["diagnostics"] as? [[String: Any]])
        let uncitedLint = diags.filter { ($0["code"] as? String) == "LINT_UNCITED_BIB_ENTRY" }
        let bib003OnValid = diags.filter { ($0["code"] as? String) == "BIB003" }
        #expect(uncitedLint.isEmpty)
        #expect(bib003OnValid.isEmpty)

        // Missing crossref parent emits WARNING BIB003, and uncited child's uncited parent IS still reported uncited
        let synTexURL = tempDir.appendingPathComponent("main.tex")
        let synBibURL = tempDir.appendingPathComponent("refs.bib")
        try """
        \\documentclass{article}
        \\begin{document}
        \\cite{orphan_child}
        \\bibliography{refs}
        \\end{document}
        """.write(to: synTexURL, atomically: true, encoding: .utf8)
        try """
        @inproceedings{orphan_child,
          author   = {Jane Roe},
          title    = {Orphan Paper},
          crossref = {nonexistent_parent}
        }
        @inproceedings{uncited_child,
          author   = {John Doe},
          title    = {Uncited Child},
          crossref = {uncited_parent}
        }
        @proceedings{uncited_parent,
          title     = {Unused Proceedings},
          booktitle = {Unused Proceedings},
          year      = {2021}
        }
        """.write(to: synBibURL, atomically: true, encoding: .utf8)

        let synRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", synTexURL.path, "--offline", "--json", "--lang", "en"]
        )
        let synObj = try #require(try JSONSerialization.jsonObject(with: Data(synRes.stdout.utf8)) as? [String: Any])
        let synUncited = try #require(synObj["uncitedEntries"] as? [String])
        #expect(synUncited == ["uncited_child", "uncited_parent"])
        let synDiags = try #require(synObj["diagnostics"] as? [[String: Any]])
        let bib003 = synDiags.filter { ($0["code"] as? String) == "BIB003" }
        #expect(bib003.count == 1)
        if let w = bib003.first {
            #expect(w["severity"] as? String == "WARNING")
            #expect(w["category"] as? String == "structure")
            #expect((w["message"] as? String ?? "").contains("nonexistent_parent"))
        }
    }

    @Test("M2 Stage 05 item 5 (S10): \\url{u} and \\href{u}{...} in howpublished and note populate url when absent and are stripped from venue")
    func m2Stage05Item5HowpublishedAndNoteURLExtractionAndVenueCleanup() throws {
        let refsBibURL = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/bib-fields/refs.bib")
        let refsRaw = try String(contentsOf: refsBibURL, encoding: .utf8)
        let doc = try BibTeXCodec().parseDocument(refsRaw)
        let byKey = Dictionary(uniqueKeysWithValues: doc.entries.map { ($0.citeKey, $0) })

        let web1 = try #require(byKey["web1"])
        #expect(web1.url == "https://www.who.int/report%20one")
        #expect(web1.venue.isEmpty)
        #expect(!web1.venue.contains("who.int"))

        let web2 = try #require(byKey["web2"])
        #expect(web2.url == "https://example.org/x")
        #expect(web2.venue.isEmpty)
        #expect(!web2.venue.contains("example.org"))

        let extraBib = """
        @misc{note_url,
          author = {Ada Lovelace},
          title  = {Analytical Notes},
          note   = {Available online at \\url{https://example.edu/~ada/notes%20v1.pdf}},
          year   = {2022}
        }
        @misc{note_href,
          author = {Alan Turing},
          title  = {Computing Machinery},
          note   = {See \\href{https://arxiv.org/abs/2205.14135}{preprint}},
          year   = {2022}
        }
        @misc{explicit_url_wins,
          author       = {Grace Hopper},
          title        = {Compiler Manual},
          url          = {https://canonical.example.com/manual},
          howpublished = {Technical Report, \\url{https://mirror.example.com/manual}},
          year         = {1952}
        }
        """
        let extraEntries = Dictionary(uniqueKeysWithValues: try BibTeXCodec().parse(extraBib).map { ($0.citeKey, $0) })
        let noteURL = try #require(extraEntries["note_url"])
        #expect(noteURL.url == "https://example.edu/~ada/notes%20v1.pdf")
        #expect(noteURL.venue.isEmpty)

        let noteHref = try #require(extraEntries["note_href"])
        #expect(noteHref.url == "https://arxiv.org/abs/2205.14135")
        #expect(noteHref.arxivID == "2205.14135")

        let explicitWins = try #require(extraEntries["explicit_url_wins"])
        #expect(explicitWins.url == "https://canonical.example.com/manual")
        #expect(!explicitWins.venue.contains("mirror.example.com"))
        #expect(explicitWins.venue == "Technical Report")
    }

    @Test("M2 Stage 05 item 6: duplicate keys within the same .bib keep the first entry and emit WARNING BIB002")
    func m2Stage05Item6DuplicateBibKeysKeepFirstAndEmitWarningBIB002() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage05-item6")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dupBib = """
        @article{dupKey,
          author  = {First Author},
          title   = {First Title Wins},
          journal = {First Journal},
          year    = {2020}
        }
        @article{dupKey,
          author  = {Second Author},
          title   = {Second Title Ignored},
          journal = {Second Journal},
          year    = {2024}
        }
        @article{DUPKEY,
          author  = {Third Author},
          title   = {Case Variant Duplicate Ignored},
          journal = {Third Journal},
          year    = {2025}
        }
        """
        let doc = try BibTeXCodec().parseDocument(dupBib)
        #expect(doc.entries.count == 1)
        let kept = try #require(doc.entries.first)
        #expect(kept.citeKey == "dupKey")
        #expect(kept.title == "First Title Wins")
        #expect(kept.year == 2020)
        let bib002 = doc.diagnostics.filter { $0.code == "BIB002" && $0.severity == .warning }
        #expect(bib002.count == 2)

        // Real benchmark .bib files with repeated entries match BibTeX unique entry counts
        let bib2410 = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Benchmarks/manuscripts/2410.04196v2/src/fhbi.bib"),
            encoding: .utf8
        )
        let doc2410 = try BibTeXCodec().parseDocument(bib2410)
        #expect(doc2410.entries.count == 374)
        #expect(doc2410.errors.isEmpty)
        #expect(doc2410.diagnostics.filter { $0.code == "BIB002" }.count == 67)

        let bib2409 = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Benchmarks/manuscripts/2409.19431v3/src/Refs.bib"),
            encoding: .utf8
        )
        let doc2409 = try BibTeXCodec().parseDocument(bib2409)
        #expect(doc2409.entries.count == 488)
        #expect(doc2409.errors.isEmpty)
        #expect(doc2409.diagnostics.filter { $0.code == "BIB002" }.count == 181)

        // Diagnostics CLI surfaces WARNING BIB002
        let texURL = tempDir.appendingPathComponent("main.tex")
        let bibURL = tempDir.appendingPathComponent("refs.bib")
        try "\\documentclass{article}\\begin{document}\\cite{dupKey}\\bibliography{refs}\\end{document}"
            .write(to: texURL, atomically: true, encoding: .utf8)
        try dupBib.write(to: bibURL, atomically: true, encoding: .utf8)
        let runner = ScholarCLIRunner(
            environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path]
        )
        let res = await runner.runWithExitStatus(
            arguments: ["diagnostics", texURL.path, "--offline", "--json", "--lang", "en"]
        )
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any])
        let diags = try #require(obj["diagnostics"] as? [[String: Any]])
        let diagBib002 = diags.filter { ($0["code"] as? String) == "BIB002" }
        #expect(diagBib002.count == 2)
        #expect(diagBib002.allSatisfy { ($0["severity"] as? String) == "WARNING" && ($0["category"] as? String) == "structure" })
    }

    @Test("M2 Stage 05 item 7 (Settled #3): verify-citations and format-bib exit 2 only when 0 clean entries read; partial-error .bib marks broken entry UNVERIFIED (parse_error, insertable=false) and exits >= 1")
    func m2Stage05Item7PartialBibRecoveryExitCodesAndParseErrorReason() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage05-item7")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runner = ScholarCLIRunner(
            environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path]
        )

        // 1. Zero clean entries (broken-only or non-BibTeX) -> exit 2 on both verify-citations and format-bib
        let brokenOnlyURL = tempDir.appendingPathComponent("broken_only.bib")
        try "@article{only_bad,\n  title = {Unclosed\n".write(to: brokenOnlyURL, atomically: true, encoding: .utf8)
        let vcBrokenOnly = await runner.runWithExitStatus(arguments: ["verify-citations", brokenOnlyURL.path, "--offline"])
        let fbBrokenOnly = await runner.runWithExitStatus(arguments: ["format-bib", brokenOnlyURL.path])
        #expect(vcBrokenOnly.exitCode == 2)
        #expect(fbBrokenOnly.exitCode == 2)

        let notBibURL = tempDir.appendingPathComponent("not_bib.txt")
        try "plain prose without bibtex entries\n".write(to: notBibURL, atomically: true, encoding: .utf8)
        let vcNotBib = await runner.runWithExitStatus(arguments: ["verify-citations", notBibURL.path, "--offline"])
        let fbNotBib = await runner.runWithExitStatus(arguments: ["format-bib", notBibURL.path])
        #expect(vcNotBib.exitCode == 2)
        #expect(fbNotBib.exitCode == 2)

        // 2. Partial recovery on Tests/Fixtures/manuscripts/bib-recovery/ten.bib
        let tenBibURL = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/bib-recovery/ten.bib")
        let vcTen = await runner.runWithExitStatus(
            arguments: ["verify-citations", tenBibURL.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(vcTen.exitCode == 1, "Expected exit 1 (not 2 or 3) on partial-error ten.bib, got \(vcTen.exitCode); stderr=\(vcTen.stderr)")
        #expect(vcTen.stderr.contains("e3") && vcTen.stderr.contains("15") && vcTen.stderr.contains("22"))

        let vcObj = try #require(try JSONSerialization.jsonObject(with: Data(vcTen.stdout.utf8)) as? [String: Any])
        #expect(vcObj["complete"] as? Bool == false)
        let unvByReason = try #require(vcObj["unverifiedByReason"] as? [String: Int])
        #expect(unvByReason["parse_error"] == 1)
        #expect(unvByReason["offline"] == 9)

        let verdicts = try #require(vcObj["verdicts"] as? [[String: Any]])
        #expect(verdicts.count == 10)
        let e3Verdict = try #require(verdicts.first { ($0["citeKey"] as? String) == "e3" })
        #expect(e3Verdict["firewallClass"] as? String == "UNVERIFIED")
        #expect(e3Verdict["reasons"] as? [String] == ["parse_error"])
        #expect(e3Verdict["insertable"] as? Bool == false)

        // Even when all clean entries are VERIFIED via registry replay, a parse_error entry forces exit 1 (not 3 or 0)
        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)
        let realBibLines = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib"),
            encoding: .utf8
        ).components(separatedBy: "\n")
        let verifiedPlusBrokenURL = tempDir.appendingPathComponent("verified_plus_broken.bib")
        let verifiedPlusBrokenText = realBibLines.prefix(2).joined(separator: "\n") + "\n@article{broken_tail,\n  author = {Zed Last},\n  title = {Unclosed {brace},\n  year = {2024}\n}\n"
        try verifiedPlusBrokenText.write(to: verifiedPlusBrokenURL, atomically: true, encoding: .utf8)

        let vcMixedReplay = await runner.runWithExitStatus(
            arguments: ["verify-citations", verifiedPlusBrokenURL.path, "--registry-replay", registryDir.path, "--json", "--lang", "en"]
        )
        #expect(vcMixedReplay.exitCode == 1)
        let mixedObj = try #require(try JSONSerialization.jsonObject(with: Data(vcMixedReplay.stdout.utf8)) as? [String: Any])
        #expect(mixedObj["verifiedCount"] as? Int == 2)
        #expect(mixedObj["unverifiedCount"] as? Int == 1)
        #expect((mixedObj["unverifiedByReason"] as? [String: Int]) == ["parse_error": 1])
        #expect(mixedObj["complete"] as? Bool == false)

        // 3. format-bib on ten.bib exits 1, reports e3 / startLine 15 / line 22 on stderr, and formats the 9 clean entries
        let fbTen = await runner.runWithExitStatus(
            arguments: ["format-bib", tenBibURL.path, "--style", "ieee", "--lang", "en"]
        )
        #expect(fbTen.exitCode == 1)
        #expect(fbTen.stderr.contains("e3") && fbTen.stderr.contains("15") && fbTen.stderr.contains("22"))
        for idx in [1, 2, 4, 5, 6, 7, 8, 9, 10] {
            #expect(fbTen.stdout.contains("A. Author\(idx)"), "Missing formatted author for e\(idx)")
            #expect(fbTen.stdout.contains("Title \(idx)"), "Missing formatted title for e\(idx)")
            #expect(fbTen.stdout.contains("\(2000 + idx)"), "Missing formatted year for e\(idx)")
        }
    }

    // MARK: - 22. M2 Stage 06: `thebibliography` & `.bbl` Parsing and M1 Verification Wiring

    private static func normalizeBibitemFieldForComparison(_ raw: String) -> String {
        TheBibliographyComparisonNormalizer.normalize(raw)
    }

    @Test("M2 Stage 06 item 1a (S24): inline thebibliography extracts all \\bibitem[opt]{key} keys, best-effort metadata & identifiers, leaves unparseable fields empty, skips comments/verbatim, and clears hard.tex CITE404")
    func m2Stage06Item1aInlineTheBibliographyAndHardTex() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage06-1a")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let runner = ScholarCLIRunner(environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path])

        let inlineTex = repositoryRoot.appendingPathComponent(
            "Tests/Fixtures/manuscripts/thebibliography-bbl/01-inline-thebib/main.tex"
        )
        let service = try ScholarLSPWorkspaceService.loadManuscript(atPath: inlineTex.path)
        let loadedKeys = service.bibliographyEntries.map(\.citeKey)
        #expect(loadedKeys == ["k_plain", "k_opt_doi", "k_arxiv_pmid", "k_minimal"])

        let kPlain = service.bibliographyEntry(forCiteKey: "k_plain")
        #expect(kPlain?.authors.first?.familyName == "Zadeh")
        #expect(kPlain?.year == 1965)
        #expect(Self.normalizeBibitemFieldForComparison(kPlain?.title ?? "") == Self.normalizeBibitemFieldForComparison("Fuzzy sets"))

        let kOptDOI = service.bibliographyEntry(forCiteKey: "k_opt_doi")
        #expect(kOptDOI?.authors.first?.familyName == "LeCun")
        #expect(kOptDOI?.year == 2015)
        #expect(Self.normalizeBibitemFieldForComparison(kOptDOI?.title ?? "") == Self.normalizeBibitemFieldForComparison("Deep learning"))
        #expect(kOptDOI?.doi == "10.1038/nature14539")

        let kArxivPmid = service.bibliographyEntry(forCiteKey: "k_arxiv_pmid")
        #expect(kArxivPmid?.authors.first?.familyName == "Dao")
        #expect(kArxivPmid?.year == 2022)
        #expect(
            Self.normalizeBibitemFieldForComparison(kArxivPmid?.title ?? "")
                == Self.normalizeBibitemFieldForComparison("FlashAttention: Fast and memory-efficient exact attention with IO-awareness")
        )
        #expect(kArxivPmid?.arxivID == "2205.14135")
        #expect(kArxivPmid?.pmid == "9500320")
        #expect(kArxivPmid?.url == "https://arxiv.org/abs/2205.14135")

        let kMinimal = service.bibliographyEntry(forCiteKey: "k_minimal")
        #expect(kMinimal != nil, "k_minimal key must be extracted")
        #expect(kMinimal?.authors.isEmpty == true, "Unparseable author must remain empty instead of guessing: \(String(describing: kMinimal?.authors))")
        #expect(kMinimal?.year == nil)
        #expect(kMinimal?.doi == nil)
        #expect(kMinimal?.arxivID == nil)
        #expect(kMinimal?.pmid == nil)
        #expect(kMinimal?.url == nil)

        let res = await runner.runWithExitStatus(
            arguments: ["diagnostics", inlineTex.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(res.exitCode != 2)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any])
        let bibSources = try #require(obj["bibliographySources"] as? [[String: Any]])
        #expect(bibSources.count == 1)
        if let src0 = bibSources.first {
            #expect(src0["kind"] as? String == "thebibliography")
            #expect(src0["path"] as? String == "main.tex")
            #expect(src0["entries"] as? Int == 4)
        }
        let diags = try #require(obj["diagnostics"] as? [[String: Any]])
        #expect(diags.filter { ($0["code"] as? String) == "CITE404" }.isEmpty)
        #expect(diags.filter { ($0["code"] as? String) == "INC002" }.isEmpty)

        // Check `hard.tex` now has 0 CITE404 and 0 structure ERRORs
        let hardTex = repositoryRoot.appendingPathComponent("Tests/Fixtures/manuscripts/hard-inputs/hard.tex")
        let hardRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", hardTex.path, "--offline", "--json", "--lang", "en"]
        )
        let hardObj = try #require(try JSONSerialization.jsonObject(with: Data(hardRes.stdout.utf8)) as? [String: Any])
        let hardDiags = try #require(hardObj["diagnostics"] as? [[String: Any]])
        let hardStructErrs = hardDiags.filter {
            ($0["category"] as? String) == "structure" && ($0["severity"] as? String) == "ERROR"
        }
        #expect(hardStructErrs.isEmpty, "Expected 0 structure ERRORs on hard.tex, got \(hardStructErrs.count)")
    }

    @Test("M2 Stage 06 item 1b (S24, Row 5): \\input{*.bbl} parses all \\bibitem entries with \\newblock clue, sets bibliographySources kind='bbl', and resolves all 46 citations in 2405.13682v5 with 0 CITE404")
    func m2Stage06Item1bInputBBLAnd2405Benchmark() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage06-1b")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let runner = ScholarCLIRunner(environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path])

        // 1. Small fixture `02-input-bbl`
        let smallTex = repositoryRoot.appendingPathComponent(
            "Tests/Fixtures/manuscripts/thebibliography-bbl/02-input-bbl/main.tex"
        )
        let smallSvc = try ScholarLSPWorkspaceService.loadManuscript(atPath: smallTex.path)
        #expect(smallSvc.bibliographyEntries.map(\.citeKey) == ["Barron1993", "Candes1998", "Skrjanc2019", "Sonoda2021a"])
        #expect(smallSvc.bibliographyEntry(forCiteKey: "Barron1993")?.doi == "10.1109/18.256500")
        #expect(smallSvc.bibliographyEntry(forCiteKey: "Barron1993")?.year == 1993)
        #expect(smallSvc.bibliographyEntry(forCiteKey: "Candes1998")?.authors.first?.familyName == "Candès")
        #expect(smallSvc.bibliographyEntry(forCiteKey: "Skrjanc2019")?.authors.first?.familyName == "Škrjanc")
        #expect(smallSvc.bibliographyEntry(forCiteKey: "Sonoda2021a")?.arxivID == "2106.04770")
        #expect(smallSvc.bibliographyEntry(forCiteKey: "Sonoda2021a")?.year == 2021)

        // 2. Benchmark `2405.13682v5` (`\input{main.bbl}`, 46 entries)
        let tex2405 = repositoryRoot.appendingPathComponent("Benchmarks/manuscripts/2405.13682v5/src/main.tex")
        let res2405 = await runner.runWithExitStatus(
            arguments: ["diagnostics", tex2405.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(res2405.exitCode != 2)
        let obj2405 = try #require(try JSONSerialization.jsonObject(with: Data(res2405.stdout.utf8)) as? [String: Any])

        let files2405 = try #require(obj2405["files"] as? [[String: Any]])
        #expect(files2405.contains { ($0["path"] as? String) == "main.bbl" })

        let bibSources = try #require(obj2405["bibliographySources"] as? [[String: Any]])
        #expect(bibSources.count == 1)
        if let src0 = bibSources.first {
            #expect(src0["kind"] as? String == "bbl")
            #expect(src0["path"] as? String == "main.bbl")
            #expect(src0["entries"] as? Int == 46)
        }

        let citations = try #require(obj2405["citations"] as? [[String: Any]])
        #expect(citations.count == 46)
        #expect(citations.allSatisfy { ($0["defined"] as? Bool) == true })
        #expect(citations.allSatisfy { ($0["source"] as? String) == "main.bbl" })
        for c in citations {
            let ver = c["verification"] as? [String: Any]
            let keyName = (c["key"] as? String) ?? ""
            #expect(ver?["verdict"] as? String == "UNVERIFIED", "Missing/wrong verdict on \(keyName)")
            #expect(ver?["reasons"] as? [String] == ["offline"])
        }

        let diags = try #require(obj2405["diagnostics"] as? [[String: Any]])
        #expect(diags.filter { ($0["code"] as? String) == "CITE404" }.isEmpty)
        #expect(diags.filter { ($0["code"] as? String) == "INC002" }.isEmpty)
        let structErrs = diags.filter {
            ($0["category"] as? String) == "structure" && ($0["severity"] as? String) == "ERROR"
        }
        #expect(structErrs.isEmpty, "Expected 0 structure ERRORs on 2405.13682v5, got \(structErrs.count)")
    }

    @Test("M2 Stage 06 item 1c (S71, Row 9): fallback <main>.bbl when .bib is absent sets bibliographySources entries count and marks all .bbl entries defined with 0 CITE404")
    func m2Stage06Item1cFallbackBBLDefinedEntriesAndRow9() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage06-1c")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let runner = ScholarCLIRunner(environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path])

        // 1. Tectonic-verified small fixture `03-fallback-bbl/paper.tex`
        let fallbackTex = repositoryRoot.appendingPathComponent(
            "Tests/Fixtures/manuscripts/thebibliography-bbl/03-fallback-bbl/paper.tex"
        )
        let res1 = await runner.runWithExitStatus(
            arguments: ["diagnostics", fallbackTex.path, "--offline", "--json", "--lang", "en"]
        )
        let obj1 = try #require(try JSONSerialization.jsonObject(with: Data(res1.stdout.utf8)) as? [String: Any])
        let srcs1 = try #require(obj1["bibliographySources"] as? [[String: Any]])
        #expect(srcs1.count == 1)
        #expect(srcs1.first?["kind"] as? String == "bbl")
        #expect(srcs1.first?["path"] as? String == "paper.bbl")
        #expect(srcs1.first?["entries"] as? Int == 3)
        let cites1 = try #require(obj1["citations"] as? [[String: Any]])
        #expect(cites1.count == 3)
        #expect(cites1.allSatisfy { ($0["defined"] as? Bool) == true && ($0["source"] as? String) == "paper.bbl" })
        let diags1 = try #require(obj1["diagnostics"] as? [[String: Any]])
        #expect(diags1.filter { ($0["code"] as? String) == "CITE404" }.isEmpty)
        #expect(diags1.filter { ($0["code"] as? String) == "INC002" }.isEmpty)
        #expect(diags1.filter { ($0["code"] as? String) == "BIB_FROM_BBL" }.count == 1)

        // 2. Existing Row 9 fixture `loader-missing/bbl-fallback/acl_latex.tex`
        let aclTex = repositoryRoot.appendingPathComponent(
            "Tests/Fixtures/manuscripts/loader-missing/bbl-fallback/acl_latex.tex"
        )
        let res2 = await runner.runWithExitStatus(
            arguments: ["diagnostics", aclTex.path, "--offline", "--json", "--lang", "en"]
        )
        let obj2 = try #require(try JSONSerialization.jsonObject(with: Data(res2.stdout.utf8)) as? [String: Any])
        let srcs2 = try #require(obj2["bibliographySources"] as? [[String: Any]])
        #expect(srcs2.first?["entries"] as? Int == 2)
        let cites2 = try #require(obj2["citations"] as? [[String: Any]])
        #expect(cites2.map { $0["key"] as? String } == ["lecun2015", "vaswani2017"])
        #expect(cites2.allSatisfy { ($0["defined"] as? Bool) == true && ($0["source"] as? String) == "acl_latex.bbl" })
        let diags2 = try #require(obj2["diagnostics"] as? [[String: Any]])
        #expect(diags2.filter { ($0["code"] as? String) == "CITE404" }.isEmpty)
    }

    @Test("M2 Stage 06 item 2: \\bibitem entries run through M1 CitationVerificationFirewall.verifyBibliography in both --offline and --registry-replay modes")
    func m2Stage06Item2M1VerificationOfflineAndRegistryReplay() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage06-2")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let runner = ScholarCLIRunner(environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path])

        let replayTex = repositoryRoot.appendingPathComponent(
            "Tests/Fixtures/manuscripts/thebibliography-bbl/04-replay-verify/main.tex"
        )
        let registryDir = repositoryRoot.appendingPathComponent("Tests/Fixtures/registry", isDirectory: true)

        let offlineRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", replayTex.path, "--offline", "--json", "--lang", "en"]
        )
        let offlineObj = try #require(try JSONSerialization.jsonObject(with: Data(offlineRes.stdout.utf8)) as? [String: Any])
        let offlineCites = try #require(offlineObj["citations"] as? [[String: Any]])
        #expect(offlineCites.count == 3)
        for c in offlineCites {
            #expect(c["defined"] as? Bool == true)
            let ver = c["verification"] as? [String: Any]
            #expect(ver?["verdict"] as? String == "UNVERIFIED")
            #expect(ver?["reasons"] as? [String] == ["offline"])
        }

        let replayRes = await runner.runWithExitStatus(
            arguments: ["diagnostics", replayTex.path, "--registry-replay", registryDir.path, "--json", "--lang", "en"]
        )
        #expect(replayRes.exitCode != 2, "Replay failed: \(replayRes.stderr)")
        let replayObj = try #require(try JSONSerialization.jsonObject(with: Data(replayRes.stdout.utf8)) as? [String: Any])
        #expect(replayObj["mode"] as? String == "REPLAY")
        let byKey = Dictionary(
            uniqueKeysWithValues: (replayObj["citations"] as? [[String: Any]] ?? []).compactMap { item -> (String, [String: Any])? in
                guard let k = item["key"] as? String else { return nil }
                return (k, item)
            }
        )
        let vLecun = byKey["lecun2015"]?["verification"] as? [String: Any]
        #expect(vLecun?["verdict"] as? String == "VERIFIED")
        #expect(vLecun?["insertable"] as? Bool == true)

        let vDao = byKey["dao2022"]?["verification"] as? [String: Any]
        #expect(vDao?["verdict"] as? String == "VERIFIED")
        #expect(vDao?["insertable"] as? Bool == true)

        let vFake = byKey["fake_whitfield2026"]?["verification"] as? [String: Any]
        #expect(vFake?["verdict"] as? String == "NOT_FOUND")
        #expect(vFake?["insertable"] as? Bool == false)
    }

    @Test("M2 Stage 06 item 3 & 4 (Row 4): 2506.06594v1 32 \\bibitem entries match bibitems.gold.tsv (year 32/32, surname >= 30/32, title >= 26/32), annaswamy2022 extracts DOI 10.48550/arXiv.2108.11336, and all 32 verdicts are UNVERIFIED offline")
    func m2Stage06Item3Benchmark2506GoldComparison() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m2-stage06-3")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let runner = ScholarCLIRunner(environment: ["HOME": tempDir.path, "CFFIXED_USER_HOME": tempDir.path])

        let tex2506 = repositoryRoot.appendingPathComponent(
            "Benchmarks/manuscripts/2506.06594v1/src/From_Adaptive_Control_Evolving_Control.tex"
        )
        let goldTSV = repositoryRoot.appendingPathComponent(
            "Benchmarks/manuscripts/2506.06594v1/bibitems.gold.tsv"
        )

        let res = await runner.runWithExitStatus(
            arguments: ["diagnostics", tex2506.path, "--offline", "--json", "--lang", "en"]
        )
        #expect(res.exitCode != 2)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any])

        let bibSources = try #require(obj["bibliographySources"] as? [[String: Any]])
        #expect(bibSources.count == 1)
        if let src0 = bibSources.first {
            #expect(src0["kind"] as? String == "thebibliography")
            #expect(src0["path"] as? String == "From_Adaptive_Control_Evolving_Control.tex")
            #expect(src0["entries"] as? Int == 32)
        }

        let diags = try #require(obj["diagnostics"] as? [[String: Any]])
        #expect(diags.filter { ($0["code"] as? String) == "CITE404" }.isEmpty)

        let citations = try #require(obj["citations"] as? [[String: Any]])
        #expect(citations.count == 32)
        let citesByKey = Dictionary(
            uniqueKeysWithValues: citations.compactMap { item -> (String, [String: Any])? in
                guard let k = item["key"] as? String else { return nil }
                return (k, item)
            }
        )

        for (key, c) in citesByKey {
            #expect(c["defined"] as? Bool == true, "Expected \(key).defined == true")
            let ver = c["verification"] as? [String: Any]
            #expect(ver?["verdict"] as? String == "UNVERIFIED", "Expected UNVERIFIED on \(key)")
            #expect(ver?["reasons"] as? [String] == ["offline"], "Expected offline reason on \(key)")
        }

        let goldLines = try String(contentsOf: goldTSV, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .dropFirst()
        #expect(goldLines.count == 32)

        var yearMatches = 0
        var surnameMatches = 0
        var titleMatches = 0

        for rawLine in goldLines {
            let cols = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let key = cols[0]
            let expSurname = cols[1]
            let expYear = Int(cols[2])
            let expTitle = cols[3]
            let expIdent = cols.count > 4 ? cols[4] : ""

            let citeRec = citesByKey[key]
            let entryDict = citeRec?["entry"] as? [String: Any]
            let actYear = entryDict?["year"] as? Int
            let actTitle = (entryDict?["title"] as? String) ?? ""
            let actAuthors = (entryDict?["authors"] as? [[String: Any]]) ?? []
            let actSurname = (actAuthors.first?["familyName"] as? String) ?? ""
            let actDOI = entryDict?["doi"] as? String

            if actYear != nil && actYear == expYear {
                yearMatches += 1
            }
            if !actSurname.isEmpty
                && Self.normalizeBibitemFieldForComparison(actSurname) == Self.normalizeBibitemFieldForComparison(expSurname) {
                surnameMatches += 1
            }
            if !actTitle.isEmpty
                && Self.normalizeBibitemFieldForComparison(actTitle) == Self.normalizeBibitemFieldForComparison(expTitle) {
                titleMatches += 1
            }
            if key == "annaswamy2022" || expIdent == "doi:10.48550/arXiv.2108.11336" {
                #expect(actDOI == "10.48550/arXiv.2108.11336", "annaswamy2022 must extract DOI 10.48550/arXiv.2108.11336, got \(String(describing: actDOI))")
            }
        }

        #expect(yearMatches == 32, "Expected 32/32 year matches on 2506.06594v1, got \(yearMatches)/32")
        #expect(surnameMatches >= 30, "Expected >= 30/32 first-author surname matches on 2506.06594v1, got \(surnameMatches)/32")
        #expect(titleMatches >= 26, "Expected >= 26/32 title matches on 2506.06594v1, got \(titleMatches)/32")
    }

    @Test("M2 Stage 06 item 4: TheBibliographyComparisonNormalizer and TheBibliographyEntryParser handle doubled DOI URLs, SICI parentheses DOIs, page ranges in 1450..2030, and empty/unparseable bodies without guessing")
    func m2Stage06Item4NormalizerAndDirectParserEdgeCases() throws {
        #expect(TheBibliographyComparisonNormalizer.normalize("Škrjanc") == "skrjanc")
        #expect(TheBibliographyComparisonNormalizer.normalize("Blažič") == "blazic")
        #expect(TheBibliographyComparisonNormalizer.normalize("Sayed-Mouchaweh") == "sayed mouchaweh")
        #expect(TheBibliographyComparisonNormalizer.normalize("Gauß & Łódź") == "gauss lodz")
        #expect(
            TheBibliographyComparisonNormalizer.normalize("Takagi–Sugeno fuzzy models.")
                == TheBibliographyComparisonNormalizer.normalize("Takagi-Sugeno fuzzy models")
        )

        let parser = TheBibliographyEntryParser()

        // Doubled doi.org URL (seen in real .bbl files such as 2405.13682v5 Sonoda2024fourier)
        let doubled = parser.parseEntry(
            citeKey: "Sonoda2024fourier",
            optionalLabel: "Sonoda et~al.(2024{\\natexlab{b}})",
            rawBody: """
            Sonoda, S., Ishikawa, I., and Ikeda, M.
            \\newblock \\href{http://doi.org/https://doi.org/10.1016/j.jspi.2024.106184}{{A unified Fourier slice method}}.
            \\newblock \\emph{Journal of Statistical Planning and Inference}, 233:\\penalty0 106184, 2024{\\natexlab{b}}.
            """
        )
        #expect(doubled.authors.first?.familyName == "Sonoda")
        #expect(doubled.year == 2024)
        #expect(doubled.doi == "10.1016/j.jspi.2024.106184")
        #expect(doubled.title == "A unified Fourier slice method")

        // SICI DOI with parentheses (e.g. Funahashi1989 `10.1016/0893-6080(89)90003-8`)
        let sici = parser.parseEntry(
            citeKey: "Funahashi1989",
            optionalLabel: "Funahashi(1989)",
            rawBody: """
            Funahashi, K.-I.
            \\newblock \\href{http://doi.org/10.1016/0893-6080(89)90003-8}{{On the approximate realization of continuous mappings by neural networks}}.
            \\newblock \\emph{Neural Networks}, 2(3): 183--192, 1989.
            """
        )
        #expect(sici.authors.first?.familyName == "Funahashi")
        #expect(sici.year == 1989)
        #expect(sici.doi == "10.1016/0893-6080(89)90003-8")

        // Completely empty `\bibitem{empty_key}` extracts key and leaves all fields empty without guessing from key
        let empty = parser.parseEntry(citeKey: "smith2020_key_not_guessed", optionalLabel: nil, rawBody: "   ")
        #expect(empty.citeKey == "smith2020_key_not_guessed")
        #expect(empty.authors.isEmpty)
        #expect(empty.title.isEmpty)
        #expect(empty.year == nil)
        #expect(empty.doi == nil)
        #expect(empty.arxivID == nil)
        #expect(empty.pmid == nil)
        #expect(empty.url == nil)
    }
}

@Suite("ZZZ Home Cache Directory Isolation Guard")
struct ZZZCacheHomeIsolationGuardTests {
    @Test("All unit tests isolate HOME / SCHOLAR_CACHE_DIR and never create ~/Library/Caches/ScholarOS in the real account home")
    func noScholarOSCacheCreatedOutsideIsolatedHomesDuringUnitTests() throws {
        guard let realHome = RealHomeCacheGuard.realAccountHomePath else { return }
        if !RealHomeCacheGuard.realAccountCacheExistedAtLoad {
            let realCachePath = URL(fileURLWithPath: realHome, isDirectory: true)
                .appendingPathComponent("Library/Caches/ScholarOS", isDirectory: true)
                .path
            #expect(
                !FileManager.default.fileExists(atPath: realCachePath),
                "Unit tests must never create ~/Library/Caches/ScholarOS in the real user home directory (\(realCachePath))"
            )
        }
    }
}
