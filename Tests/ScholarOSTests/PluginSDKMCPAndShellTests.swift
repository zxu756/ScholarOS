import Foundation
import Testing
import ScholarModels
import ScholarProjectStore
import ScholarPluginSDK
import ScholarCLIAndMCP
import ScholarWorkbenchShell

@Suite("Editorial Plugin SDK, Statistical Numerics, CLI/MCP Firewall & Workbench Shell")
struct PluginSDKMCPAndShellTests {

    // MARK: - Helpers

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
                firewallClass: .blockedHallucinatedOrRetracted
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

    // MARK: - 3. ScholarCLIRunner Subcommands & Hardware-Gated Citation Enforcement

    @Test("ScholarCLIRunner executes version, help, init --seed-demo, status, outline, and diagnostics on temp .scholarproj")
    func cliRunnerLifecycleStatusOutlineAndDiagnostics() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-cli-proj")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundlePath = tempDir.appendingPathComponent("CLIStudy.scholarproj").path
        let cli = ScholarCLIRunner()

        let versionOut = try await cli.execute(arguments: ["version"])
        #expect(versionOut.contains("ScholarOS 1.1.0"))

        let versionWithLangOut = try await cli.execute(arguments: ["--lang", "zh", "version"])
        #expect(versionWithLangOut.contains("ScholarOS 1.1.0"))

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

    @Test("ScholarCLIRunner cite subcommand permits verified DOI keys and hard-blocks smith2025hallucinated with ERR_UNVERIFIED_CITATION")
    func cliRunnerHardwareGatedCiteBlocksHallucinations() async throws {
        let cli = ScholarCLIRunner()

        // Verified DOI key succeeds and formats APA 7th reference
        let allowedOut = try await cli.execute(arguments: ["cite", "vaswani2017attention"])
        #expect(allowedOut.contains("\\cite{vaswani2017attention}"))
        #expect(allowedOut.contains("Attention Is All You Need"))

        // Blocked hallucinated key MUST throw ScholarOSError with ERR_UNVERIFIED_CITATION
        do {
            _ = try await cli.execute(arguments: ["cite", "smith2025hallucinated"])
            Issue.record("Expected CLI cite smith2025hallucinated to throw ERR_UNVERIFIED_CITATION")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }

        // Unknown subcommand throws invalidCLIArguments
        await #expect(throws: ScholarOSError.self) {
            _ = try await cli.execute(arguments: ["nonexistent-subcommand"])
        }
    }

    @Test("ScholarCLIRunner executes verify-citations, format-bib, prisma-stats, citation-graph, track-changes, audit-editorial, export-bundle, and export-html")
    func cliRunnerAnalyticsAndExportSubcommands() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-cli-exports")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cli = ScholarCLIRunner()

        let verifyOut = try await cli.execute(arguments: ["verify-citations"])
        #expect(verifyOut.contains("Evaluated=10"))
        #expect(verifyOut.contains("Blocked=1"))

        let ieeeBib = try await cli.execute(arguments: ["format-bib", "--style", "ieee"])
        #expect(ieeeBib.contains("[1]"))

        let prismaJSON = try await cli.execute(arguments: ["prisma-stats"])
        let prismaMetrics = try JSONDecoder().decode(PRISMA2020SummaryMetrics.self, from: Data(prismaJSON.utf8))
        #expect(prismaMetrics.recordsScreenedTitleAbstract == 12)

        let svgPath = tempDir.appendingPathComponent("prisma.svg").path
        _ = try await cli.execute(arguments: ["prisma-svg", "--output", svgPath])
        let svgDisk = try String(contentsOfFile: svgPath, encoding: .utf8)
        #expect(svgDisk.contains("<svg"))

        let graphOut = try await cli.execute(arguments: ["citation-graph"])
        #expect(graphOut.contains("Nodes=10"))

        let diffOut = try await cli.execute(arguments: ["track-changes"])
        #expect(diffOut.contains("Diff"))

        let editorialOut = try await cli.execute(arguments: ["audit-editorial"])
        #expect(editorialOut.contains("overclaiming-rhetoric-detector"))

        let bundleOutDir = tempDir.appendingPathComponent("arxiv-export").path
        let bundleMsg = try await cli.execute(arguments: ["export-bundle", "--output", bundleOutDir])
        #expect(bundleMsg.contains("sha256="))

        let htmlPath = tempDir.appendingPathComponent("dossier.html").path
        _ = try await cli.execute(arguments: ["export-html", "--output", htmlPath])
        let htmlDisk = try String(contentsOfFile: htmlPath, encoding: .utf8)
        #expect(htmlDisk.contains("<!DOCTYPE html>"))
        #expect(!htmlDisk.contains("—"))
    }

    // MARK: - 4. ScholarHardwareGatedMCPServer JSON-RPC 2.0 Protocol & Firewall Enforcement

    @Test("ScholarHardwareGatedMCPServer handles JSON-RPC 2.0 initialize and tools/list with 8 academic tools")
    func mcpServerInitializeAndToolsListJSONRPC() throws {
        let server = ScholarHardwareGatedMCPServer()

        // 1. initialize handshake
        let initReq = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let initRaw = try #require(server.handleJSONRPCLine(initReq))
        let initJSON = try #require(JSONSerialization.jsonObject(with: Data(initRaw.utf8)) as? [String: Any])
        #expect(initJSON["jsonrpc"] as? String == "2.0")
        #expect(initJSON["id"] as? Int == 1)
        let initResult = try #require(initJSON["result"] as? [String: Any])
        #expect(initResult["protocolVersion"] as? String == "2024-11-05")

        // 2. tools/list exposes all 8 hardware-gated tools
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

    @Test("MCP scholar_cite_key returns isError: true + ERR_UNVERIFIED_CITATION on smith2025hallucinated and succeeds on verified DOI")
    func mcpServerCiteKeyBlocksHallucinationAndAllowsVerifiedDOI() throws {
        let server = ScholarHardwareGatedMCPServer()

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

        // 2. Verified canonical DOI key via JSON-RPC tools/call -> isError: false + FIREWALL_CLEARED:VERIFIED_DOI
        let okReq = #"""
        {"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"scholar_cite_key","arguments":{"citeKey":"vaswani2017attention","style":"ieee"}}}
        """#
        let okRaw = try #require(server.handleJSONRPCLine(okReq))
        let okEnv = try #require(JSONSerialization.jsonObject(with: Data(okRaw.utf8)) as? [String: Any])
        let okResult = try #require(okEnv["result"] as? [String: Any])
        #expect(okResult["isError"] as? Bool == false)
        let okContent = try #require((okResult["content"] as? [[String: Any]])?.first)
        let okText = try #require(okContent["text"] as? String)
        #expect(okText.contains("FIREWALL_CLEARED:VERIFIED_DOI"))
        #expect(okText.contains("Attention Is All You Need"))
    }

    @Test("MCP server executes provenance search, PRISMA agreement, LSP diagnostics, editorial audit, diff, and citation gaps")
    func mcpServerExecutesRemainingDomainTools() {
        let server = ScholarHardwareGatedMCPServer()

        let prov = server.executeToolCall(name: "scholar_search_provenance", arguments: ["claim": "FlashAttention speedup"])
        #expect(prov["isError"] as? Bool == false)

        let prisma = server.executeToolCall(name: "scholar_prisma_agreement", arguments: [:])
        #expect(prisma["isError"] as? Bool == false)
        let prismaText = ((prisma["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(prismaText.contains("Kappa="))

        let diff = server.executeToolCall(
            name: "scholar_track_changes_diff",
            arguments: ["original": "Baseline latency 20 ms.", "revised": "Optimized latency 4 ms."]
        )
        #expect(diff["isError"] as? Bool == false)
        let diffText = ((diff["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(diffText.contains("\\DIFadd{"))

        let gaps = server.executeToolCall(name: "scholar_citation_gaps", arguments: [:])
        #expect(gaps["isError"] as? Bool == false)

        // LSP diagnostics marks isError: true when inline source cites smith2025hallucinated
        let badLSP = server.executeToolCall(
            name: "scholar_lsp_diagnostics",
            arguments: ["source": "\\section{Test}\nBad \\cite{smith2025hallucinated}.\n"]
        )
        #expect(badLSP["isError"] as? Bool == true)

        // Unknown tool returns isError: true
        let unknown = server.executeToolCall(name: "scholar_nonexistent_tool", arguments: [:])
        #expect(unknown["isError"] as? Bool == true)
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
                firewallClass: .verifiedCanonicalDOI
            ),
            BibliographyEntry(
                citeKey: "smith2025hallucinated",
                title: "Attention Hallucinations",
                authors: [BibAuthor(givenName: "J.", familyName: "Smith")],
                year: 2025,
                firewallClass: .blockedHallucinatedOrRetracted
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
        let suiteName = "io.github.zxu756.ScholarOS.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

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
        let suiteName = "io.github.zxu756.ScholarOS.resolve.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

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
    func bilingualDomainLabelsAndCommandPaletteLocalization() {
        #expect(ScholarStudioTab.manuscriptEditor.localizedTitle(.zhHans).contains("手稿"))
        #expect(ScholarStudioTab.citationGraph.localizedTitle(.zhHans) == "引文知识图谱")
        #expect(ScholarStudioTab.prismaScreening.localizedTitle(.zhHans) == "PRISMA 2020 双盲筛查")
        #expect(CitationFirewallClass.verifiedCanonicalDOI.localizedBadgeTitle(.zhHans) == "已验证 DOI")
        #expect(CitationFirewallClass.blockedHallucinatedOrRetracted.localizedFilterChip(.zhHans) == "已拦截")

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
    }
}
