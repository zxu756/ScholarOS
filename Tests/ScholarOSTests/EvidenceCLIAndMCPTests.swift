import CoreGraphics
import Foundation
import Testing
import ScholarCLIAndMCP
import ScholarModels

extension PluginSDKMCPAndShellTests {

    // MARK: - M4 Stage 03: CLI `locate-evidence`, `segment-pdf`, and MCP `locate_evidence`

    private var m4Stage03RepoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeM4Stage03TempDir(prefix: String = "scholaros-m4-s03") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("home/Library/Preferences", isDirectory: true),
            withIntermediateDirectories: true
        )
        return dir
    }

    private func m4Stage03IsolatedEnv(in tempDir: URL) -> [String: String] {
        let home = tempDir.appendingPathComponent("home", isDirectory: true).path
        return [
            "HOME": home,
            "CFFIXED_USER_HOME": home
        ]
    }

    private func m4Stage03ContainsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x3000...0x303F).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x4E00...0x9FFF).contains(v)
                || (0xFF00...0xFFEF).contains(v)
        }
    }

    private func writeBlankZeroTextPDF(to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            struct BlankPDFCreationError: Error {}
            throw BlankPDFCreationError()
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
        ctx.fill(CGRect(x: 72, y: 72, width: 200, height: 100))
        ctx.endPDFPage()
        ctx.closePDF()
    }

    @Test("M4 Stage 03: CLI locate-evidence returns exit codes 0 (FOUND), 1 (NUMERIC_MISMATCH), and 3 (NOT_FOUND) with scholaros.evidence/1 JSON and bilingual human summaries")
    func m4Stage03CLILocateEvidenceThreeVerdictsExitCodesJSONAndBilingualSummary() async throws {
        let tempDir = try makeM4Stage03TempDir(prefix: "scholaros-m4-cli-verdicts")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cli = ScholarCLIRunner(environment: m4Stage03IsolatedEnv(in: tempDir))

        let s12Paper = m4Stage03RepoRoot.appendingPathComponent("Tests/Fixtures/pdf-segmentation/s12_paper.pdf")

        // 1. FOUND -> exit 0
        let foundClaim = "Our deterministic verifier completes static analysis across 368 regression tests in 14.5 ms on a single CPU core."
        let foundJSONOut = await cli.runWithExitStatus(
            arguments: ["locate-evidence", s12Paper.path, "--claim", foundClaim, "--top-k", "2", "--json"]
        )
        #expect(foundJSONOut.exitCode == 0, "Expected exit 0 for FOUND, got \(foundJSONOut.exitCode): \(foundJSONOut.stderr)")
        #expect(foundJSONOut.stderr.isEmpty)
        let foundObj = try #require(
            try? JSONSerialization.jsonObject(with: Data(foundJSONOut.stdout.utf8)) as? [String: Any],
            "Expected JSON object on stdout for FOUND, got: \(foundJSONOut.stdout)"
        )
        #expect(foundObj["schema"] as? String == "scholaros.evidence/1")
        #expect(foundObj["verdict"] as? String == "FOUND")
        #expect(foundObj["pdf_file"] as? String == "s12_paper.pdf")
        #expect(foundObj["page"] as? Int == 1)
        #expect(foundObj["page_index"] as? Int == 0)
        #expect(foundObj["column_index"] as? Int == 1)
        #expect(foundObj["section_title"] as? String == "1 Introduction")
        #expect((foundObj["excerpt"] as? String)?.contains("368 regression tests") == true)
        #expect((foundObj["discrepancies"] as? [Any])?.isEmpty == true)
        let foundBox = try #require(foundObj["bounding_box"] as? [String: Double])
        #expect((foundBox["width"] ?? 0) > 0)
        #expect((foundBox["height"] ?? 0) > 0)
        #expect((foundBox["x"] ?? -1) >= 0 && (foundBox["x"] ?? 9999) < 612)
        #expect((foundBox["y"] ?? -1) >= 0 && (foundBox["y"] ?? 9999) < 792)
        let foundMatches = try #require(foundObj["matches"] as? [[String: Any]])
        #expect(!foundMatches.isEmpty && foundMatches.count <= 2)

        // Human-readable bilingual FOUND summaries (--lang en & --lang zh)
        let foundEN = await cli.runWithExitStatus(
            arguments: ["locate-evidence", s12Paper.path, "--claim", foundClaim, "--lang", "en"]
        )
        #expect(foundEN.exitCode == 0)
        #expect(foundEN.stdout.contains("FOUND"))
        #expect(foundEN.stdout.contains("s12_paper.pdf"))
        #expect(!m4Stage03ContainsCJK(foundEN.stdout), "English summary must not contain CJK characters: \(foundEN.stdout)")
        #expect(!foundEN.stdout.lowercased().contains("entailment"))
        #expect(!foundEN.stdout.contains("GROUNDED"))

        let foundZH = await cli.runWithExitStatus(
            arguments: ["locate-evidence", s12Paper.path, "--claim", foundClaim, "--lang", "zh"]
        )
        #expect(foundZH.exitCode == 0)
        #expect(foundZH.stdout.contains("FOUND"))
        #expect(m4Stage03ContainsCJK(foundZH.stdout))
        #expect(!foundZH.stdout.contains("支持你的结论"))
        #expect(!foundZH.stdout.contains("GROUNDED"))

        // 2. NUMERIC_MISMATCH -> exit 1
        let mismatchClaim = "Our deterministic verifier completes static analysis across 9999 regression tests in 14.5 ms on a single CPU core."
        let mmJSONOut = await cli.runWithExitStatus(
            arguments: ["locate-evidence", s12Paper.path, "--claim", mismatchClaim, "--json"]
        )
        #expect(mmJSONOut.exitCode == 1, "Expected exit 1 for NUMERIC_MISMATCH, got \(mmJSONOut.exitCode): \(mmJSONOut.stderr)")
        let mmObj = try #require(
            try? JSONSerialization.jsonObject(with: Data(mmJSONOut.stdout.utf8)) as? [String: Any],
            "Expected JSON object on stdout for NUMERIC_MISMATCH, got: \(mmJSONOut.stdout)"
        )
        #expect(mmObj["schema"] as? String == "scholaros.evidence/1")
        #expect(mmObj["verdict"] as? String == "NUMERIC_MISMATCH")
        #expect(mmObj["page"] as? Int == 1)
        #expect(mmObj["page_index"] as? Int == 0)
        #expect(mmObj["bounding_box"] as? [String: Double] != nil)
        let discrepancies = try #require(mmObj["discrepancies"] as? [[String: Any]])
        #expect(!discrepancies.isEmpty)
        #expect(discrepancies.contains {
            (($0["claim_text"] as? String)?.contains("9999") == true)
                && (($0["pdf_text"] as? String)?.contains("368") == true)
        }, "Expected discrepancy pointing from 9999 to 368, got: \(discrepancies)")

        let mmEN = await cli.runWithExitStatus(
            arguments: ["locate-evidence", s12Paper.path, "--claim", mismatchClaim, "--lang", "en"]
        )
        #expect(mmEN.exitCode == 1)
        #expect(mmEN.stdout.contains("NUMERIC_MISMATCH"))
        #expect(mmEN.stdout.contains("9999") && mmEN.stdout.contains("368"))
        #expect(!m4Stage03ContainsCJK(mmEN.stdout))

        let mmZH = await cli.runWithExitStatus(
            arguments: ["locate-evidence", s12Paper.path, "--claim", mismatchClaim, "--lang", "zh"]
        )
        #expect(mmZH.exitCode == 1)
        #expect(mmZH.stdout.contains("NUMERIC_MISMATCH"))
        #expect(m4Stage03ContainsCJK(mmZH.stdout))

        // 3. NOT_FOUND -> exit 3 (unrelated English with 1 common word, Chinese sentinel, and cross-language claim)
        let notFoundClaims = [
            "The moon is made of green cheese in our analysis.",
            "月亮是绿奶酪做的。",
            "在单个 CPU 核心上完成了 368 个回归测试。"
        ]
        for nfClaim in notFoundClaims {
            let nfJSONOut = await cli.runWithExitStatus(
                arguments: ["locate-evidence", s12Paper.path, "--claim", nfClaim, "--json"]
            )
            #expect(nfJSONOut.exitCode == 3, "Expected exit 3 for NOT_FOUND claim '\(nfClaim)', got \(nfJSONOut.exitCode): \(nfJSONOut.stderr)")
            let nfObj = try #require(
                try? JSONSerialization.jsonObject(with: Data(nfJSONOut.stdout.utf8)) as? [String: Any],
                "Expected JSON object on stdout for NOT_FOUND, got: \(nfJSONOut.stdout)"
            )
            #expect(nfObj["schema"] as? String == "scholaros.evidence/1")
            #expect(nfObj["verdict"] as? String == "NOT_FOUND")
            #expect((nfObj["matches"] as? [Any])?.isEmpty == true)
            #expect((nfObj["discrepancies"] as? [Any])?.isEmpty == true)
            #expect(nfObj["page"] == nil)
            #expect(nfObj["page_index"] == nil)
            #expect(nfObj["bounding_box"] == nil)
            #expect(nfObj["excerpt"] == nil)
        }

        let nfEN = await cli.runWithExitStatus(
            arguments: ["locate-evidence", s12Paper.path, "--claim", "The moon is made of green cheese.", "--lang", "en"]
        )
        #expect(nfEN.exitCode == 3)
        #expect(nfEN.stdout.contains("NOT_FOUND"))
        #expect(!m4Stage03ContainsCJK(nfEN.stdout))

        let nfZH = await cli.runWithExitStatus(
            arguments: ["locate-evidence", s12Paper.path, "--claim", "月亮是绿奶酪做的。", "--lang", "zh"]
        )
        #expect(nfZH.exitCode == 3)
        #expect(nfZH.stdout.contains("NOT_FOUND"))
        #expect(m4Stage03ContainsCJK(nfZH.stdout))
    }

    @Test("M4 Stage 03: CLI locate-evidence returns exit 2 with empty stdout and clear stderr on bad arguments, empty claim, missing file, non-PDF bytes, or blank zero-text PDF")
    func m4Stage03CLILocateEvidenceErrorsReturnExitCode2AndEmptyStdout() async throws {
        let tempDir = try makeM4Stage03TempDir(prefix: "scholaros-m4-cli-errors")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cli = ScholarCLIRunner(environment: m4Stage03IsolatedEnv(in: tempDir))

        let s12Paper = m4Stage03RepoRoot.appendingPathComponent("Tests/Fixtures/pdf-segmentation/s12_paper.pdf")
        let missingPDF = tempDir.appendingPathComponent("does_not_exist.pdf")
        let nonPDFFile = tempDir.appendingPathComponent("not_a_pdf.pdf")
        try Data("NOT A PDF DOCUMENT\u{00}\u{01}\u{02}\n".utf8).write(to: nonPDFFile)
        let blankPDF = tempDir.appendingPathComponent("blank_zero_text.pdf")
        try writeBlankZeroTextPDF(to: blankPDF)
        let subDir = tempDir.appendingPathComponent("subdir_as_pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let errorInvocations: [[String]] = [
            ["locate-evidence", "--claim", "Valid claim", "--json"],
            ["locate-evidence", s12Paper.path, "--json"],
            ["locate-evidence", s12Paper.path, "--claim", "", "--json"],
            ["locate-evidence", s12Paper.path, "--claim", "   \t\n  ", "--json"],
            ["locate-evidence", s12Paper.path, "--claim", "   "],
            ["locate-evidence", s12Paper.path, "--claim", "Valid claim", "--top-k", "0", "--json"],
            ["locate-evidence", s12Paper.path, "--claim", "Valid claim", "--top-k", "-2", "--json"],
            ["locate-evidence", s12Paper.path, "--claim", "Valid claim", "--top-k", "abc", "--json"],
            ["locate-evidence", s12Paper.path, "--claim", "Valid claim", "--unknown-flag", "--json"],
            ["locate-evidence", missingPDF.path, "--claim", "Valid claim", "--json"],
            ["locate-evidence", nonPDFFile.path, "--claim", "Valid claim", "--json"],
            ["locate-evidence", blankPDF.path, "--claim", "Valid claim", "--json"],
            ["locate-evidence", subDir.path, "--claim", "Valid claim", "--json"],
            ["locate-evidence", missingPDF.path, "--claim", "Valid claim", "--lang", "zh"],
            ["locate-evidence", nonPDFFile.path, "--claim", "Valid claim", "--lang", "zh"],
            ["locate-evidence", blankPDF.path, "--claim", "Valid claim", "--lang", "zh"]
        ]

        for args in errorInvocations {
            let res = await cli.runWithExitStatus(arguments: args)
            #expect(res.exitCode == 2, "Expected exit 2 for \(args), got \(res.exitCode) (stdout=\(res.stdout), stderr=\(res.stderr))")
            #expect(res.stdout.isEmpty, "Expected empty stdout on error for \(args), got: \(res.stdout)")
            #expect(!res.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Expected non-empty stderr reason for \(args)")
        }
    }

    @Test("M4 Stage 03: CLI segment-pdf outputs kind, page, page_index, bounding_box, column_index, section_title, and text per chunk, and exits 2 on invalid inputs")
    func m4Stage03CLISegmentPDFChunkFieldsAndErrorExitCodes() async throws {
        let tempDir = try makeM4Stage03TempDir(prefix: "scholaros-m4-seg-pdf")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cli = ScholarCLIRunner(environment: m4Stage03IsolatedEnv(in: tempDir))

        let s12Paper = m4Stage03RepoRoot.appendingPathComponent("Tests/Fixtures/pdf-segmentation/s12_paper.pdf")
        let segJSONOut = await cli.runWithExitStatus(arguments: ["segment-pdf", s12Paper.path, "--json"])
        #expect(segJSONOut.exitCode == 0, "Expected exit 0 for segment-pdf, got \(segJSONOut.exitCode): \(segJSONOut.stderr)")
        #expect(segJSONOut.stderr.isEmpty)

        let rawParsed = try #require(
            try? JSONSerialization.jsonObject(with: Data(segJSONOut.stdout.utf8)),
            "Expected valid JSON from segment-pdf --json, got: \(segJSONOut.stdout)"
        )
        let chunks: [[String: Any]]
        if let dict = rawParsed as? [String: Any], let arr = dict["chunks"] as? [[String: Any]] {
            chunks = arr
        } else if let arr = rawParsed as? [[String: Any]] {
            chunks = arr
        } else {
            Issue.record("Expected JSON object with 'chunks' array or top-level array from segment-pdf --json")
            chunks = []
        }
        #expect(!chunks.isEmpty)

        let validKinds: Set<String> = ["body", "section_heading", "table_or_figure", "header", "footer"]
        for chunk in chunks {
            let kind = try #require(chunk["kind"] as? String)
            #expect(validKinds.contains(kind), "Unexpected chunk kind: \(kind)")
            let page = try #require(chunk["page"] as? Int)
            let pageIdx = try #require(chunk["page_index"] as? Int)
            #expect(page >= 1 && page == pageIdx + 1)
            let col = try #require(chunk["column_index"] as? Int)
            #expect((0...2).contains(col))
            let sec = try #require(chunk["section_title"] as? String)
            #expect(!sec.isEmpty)
            let txt = try #require(chunk["text"] as? String)
            #expect(!txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let bbox = try #require(chunk["bounding_box"] as? [String: Double])
            #expect((bbox["width"] ?? 0) > 0)
            #expect((bbox["height"] ?? 0) > 0)
            #expect(bbox["x"] != nil && bbox["y"] != nil)
        }

        let headingTexts = chunks.filter { ($0["kind"] as? String) == "section_heading" }.compactMap { $0["text"] as? String }
        #expect(headingTexts.contains { $0.contains("Introduction") })
        #expect(headingTexts.contains { $0.contains("References") })
        let bodyTexts = chunks.filter { ($0["kind"] as? String) == "body" }.compactMap { $0["text"] as? String }
        #expect(!bodyTexts.contains { $0.contains("Journal of Reproducible Systems") }, "Repeating header must not leak into body chunks")
        #expect(!bodyTexts.contains { $0.contains("Do Not Distribute") }, "Repeating footer must not leak into body chunks")

        // Human-readable output without --json
        let segEN = await cli.runWithExitStatus(arguments: ["segment-pdf", s12Paper.path, "--lang", "en"])
        #expect(segEN.exitCode == 0)
        #expect(!segEN.stdout.isEmpty)
        #expect(!m4Stage03ContainsCJK(segEN.stdout))

        let segZH = await cli.runWithExitStatus(arguments: ["segment-pdf", s12Paper.path, "--lang", "zh"])
        #expect(segZH.exitCode == 0)
        #expect(m4Stage03ContainsCJK(segZH.stdout))

        // Error cases for segment-pdf -> exit 2 and empty stdout
        let nonPDF = tempDir.appendingPathComponent("garbage.pdf")
        try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF]).write(to: nonPDF)
        let blankPDF = tempDir.appendingPathComponent("blank.pdf")
        try writeBlankZeroTextPDF(to: blankPDF)

        for badArgs in [
            ["segment-pdf", "--json"],
            ["segment-pdf", tempDir.appendingPathComponent("missing.pdf").path, "--json"],
            ["segment-pdf", nonPDF.path, "--json"],
            ["segment-pdf", blankPDF.path, "--json"],
            ["segment-pdf", s12Paper.path, "--unknown", "--json"]
        ] {
            let errRes = await cli.runWithExitStatus(arguments: badArgs)
            #expect(errRes.exitCode == 2, "Expected exit 2 for \(badArgs), got \(errRes.exitCode)")
            #expect(errRes.stdout.isEmpty)
            #expect(!errRes.stderr.isEmpty)
        }
    }

    @Test("M4 Stage 03: CLI --help documents locate-evidence, segment-pdf, and exit codes in both EN and ZH without entailment claims")
    func m4Stage03HelpBannersDocumentLocateEvidenceAndSegmentPDFInBothLanguages() async throws {
        let tempDir = try makeM4Stage03TempDir(prefix: "scholaros-m4-help")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cli = ScholarCLIRunner(environment: m4Stage03IsolatedEnv(in: tempDir))

        let helpEN = try await cli.execute(arguments: ["--help", "--lang", "en"])
        let helpZH = try await cli.execute(arguments: ["--help", "--lang", "zh"])

        #expect(helpEN.contains("locate-evidence"))
        #expect(helpEN.contains("segment-pdf"))
        #expect(helpEN.contains("FOUND") && helpEN.contains("NUMERIC_MISMATCH") && helpEN.contains("NOT_FOUND"))
        #expect(!m4Stage03ContainsCJK(helpEN.replacingOccurrences(of: "中文/EN", with: "ZH/EN")))
        #expect(!helpEN.lowercased().contains("entailment"))
        #expect(!helpEN.contains("GROUNDED"))

        #expect(helpZH.contains("locate-evidence"))
        #expect(helpZH.contains("segment-pdf"))
        #expect(helpZH.contains("0") && helpZH.contains("1") && helpZH.contains("3") && helpZH.contains("2"))
        #expect(!helpZH.lowercased().contains("entailment"))
        #expect(!helpZH.contains("GROUNDED"))
        #expect(!helpZH.contains("支持你的结论"))
    }

    @Test("M4 Stage 03: MCP tools/list exposes 5 default tools including locate_evidence and removes scholar_search_provenance from both default and --experimental-tools")
    func m4Stage03MCPToolsListExposes5DefaultToolsIncludingLocateEvidenceAndDeletesScholarSearchProvenance() async throws {
        let tempDir = try makeM4Stage03TempDir(prefix: "scholaros-m4-mcp-list")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let env = m4Stage03IsolatedEnv(in: tempDir)

        let defaultServer = ScholarMCPServer(isOffline: true, environment: env)
        let listRaw = try #require(await defaultServer.handleJSONRPCLineAsync(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let listEnv = try #require(JSONSerialization.jsonObject(with: Data(listRaw.utf8)) as? [String: Any])
        let defaultTools = try #require((listEnv["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let defaultNames = Set(defaultTools.compactMap { $0["name"] as? String })

        #expect(defaultTools.count == 5, "Expected 5 default MCP tools, got \(defaultTools.count): \(defaultNames.sorted())")
        #expect(defaultNames == [
            "verify_citation",
            "add_verified_bibtex",
            "check_manuscript",
            "scholar_verify_bibliography",
            "locate_evidence"
        ])
        #expect(!defaultNames.contains("scholar_search_provenance"))

        let locateDef = try #require(defaultTools.first { ($0["name"] as? String) == "locate_evidence" })
        let locateDesc = try #require(locateDef["description"] as? String)
        #expect(!locateDesc.lowercased().contains("entailment"), "locate_evidence description must not mention entailment: \(locateDesc)")
        #expect(!locateDesc.contains("GROUNDED"), "locate_evidence description must not mention GROUNDED: \(locateDesc)")
        #expect(!locateDesc.lowercased().contains("supports your conclusion"))
        #expect(!locateDesc.contains("支持你的结论"))
        let locateSchema = try #require(locateDef["inputSchema"] as? [String: Any])
        let locateProps = try #require(locateSchema["properties"] as? [String: Any])
        #expect(Set(locateProps.keys) == ["pdf_file", "claim", "top_k"])
        let locateReq = try #require(locateSchema["required"] as? [String])
        #expect(Set(locateReq) == ["pdf_file", "claim"])

        // Even under --experimental-tools, scholar_search_provenance is completely removed and returns -32602
        let expServer = ScholarMCPServer(allowDemoMode: true, isOffline: true, enableExperimentalTools: true, environment: env)
        let expListRaw = try #require(await expServer.handleJSONRPCLineAsync(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let expListEnv = try #require(JSONSerialization.jsonObject(with: Data(expListRaw.utf8)) as? [String: Any])
        let expTools = try #require((expListEnv["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let expNames = Set(expTools.compactMap { $0["name"] as? String })
        #expect(expTools.count == 9)
        #expect(!expNames.contains("scholar_search_provenance"))
        #expect(expNames.contains("locate_evidence"))

        let callRemovedReq = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"scholar_search_provenance","arguments":{"claim":"attention","demo":true}}}"#
        for srv in [defaultServer, expServer] {
            let syncReply = try #require(srv.handleJSONRPCLine(callRemovedReq))
            let syncJSON = try #require(JSONSerialization.jsonObject(with: Data(syncReply.utf8)) as? [String: Any])
            #expect((syncJSON["error"] as? [String: Any])?["code"] as? Int == -32602)

            let asyncReply = try #require(await srv.handleJSONRPCLineAsync(callRemovedReq))
            let asyncJSON = try #require(JSONSerialization.jsonObject(with: Data(asyncReply.utf8)) as? [String: Any])
            #expect((asyncJSON["error"] as? [String: Any])?["code"] as? Int == -32602)
        }
    }

    @Test("M4 Stage 03: MCP locate_evidence detects NUMERIC_MISMATCH and reports PDF ground-truth numbers")
    func m4Stage03MCPLocateEvidenceDetectsNumericMismatch() async throws {
        let tempDir = try makeM4Stage03TempDir(prefix: "scholaros-m4-mcp-mm")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let server = ScholarMCPServer(isOffline: true, environment: m4Stage03IsolatedEnv(in: tempDir))

        let s12Paper = m4Stage03RepoRoot.appendingPathComponent("Tests/Fixtures/pdf-segmentation/s12_paper.pdf")
        let wideFixture = m4Stage03RepoRoot.appendingPathComponent("Tests/Fixtures/pdf-segmentation-02b/s12_wide_table_fig_cols.pdf")

        let mismatchCases: [(URL, String, String, String)] = [
            (
                s12Paper,
                "Our deterministic verifier completes static analysis across 9999 regression tests in 14.5 ms on a single CPU core.",
                "9999",
                "368"
            ),
            (
                s12Paper,
                "Dataset preparation required 2.5 days across 18 distinct conference templates.",
                "2.5 days",
                "2.5 hours"
            ),
            (
                wideFixture,
                "The encoder uses 4 layers and 3 attention heads across 19 datasets.",
                "4",
                "3"
            )
        ]

        for (pdfURL, claim, expectedClaimSub, expectedPDFSub) in mismatchCases {
            let res = await server.executeToolCallAsync(
                name: "locate_evidence",
                arguments: ["pdf_file": pdfURL.path, "claim": claim]
            )
            #expect(res["isError"] as? Bool == false, "Expected isError=false for valid PDF call, got \(res)")
            let text = try #require(((res["content"] as? [[String: Any]])?.first)?["text"] as? String)
            let obj = try #require(try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(obj["schema"] as? String == "scholaros.evidence/1")
            #expect(
                obj["verdict"] as? String == "NUMERIC_MISMATCH",
                "Expected NUMERIC_MISMATCH on '\(claim)', got verdict=\(obj["verdict"] ?? "nil")"
            )
            let discrepancies = try #require(obj["discrepancies"] as? [[String: Any]])
            #expect(!discrepancies.isEmpty, "Expected non-empty discrepancies on NUMERIC_MISMATCH")
            #expect(discrepancies.contains {
                (($0["claim_text"] as? String)?.contains(expectedClaimSub) == true)
                    && (($0["pdf_text"] as? String)?.contains(expectedPDFSub) == true)
            }, "Expected discrepancy (\(expectedClaimSub) vs \(expectedPDFSub)), got \(discrepancies)")
        }
    }

    @Test("M4 Stage 03: MCP locate_evidence returns JSON byte-for-byte identical to CLI locate-evidence --json across FOUND, NUMERIC_MISMATCH, and NOT_FOUND, and rejects invalid/unknown arguments with ERR_INVALID_ARGUMENT")
    func m4Stage03MCPLocateEvidenceMatchesCLIJSONByteForByteAndRejectsInvalidArguments() async throws {
        let tempDir = try makeM4Stage03TempDir(prefix: "scholaros-m4-mcp-parity")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let env = m4Stage03IsolatedEnv(in: tempDir)
        let cli = ScholarCLIRunner(environment: env)
        let server = ScholarMCPServer(isOffline: true, environment: env)

        let s12Paper = m4Stage03RepoRoot.appendingPathComponent("Tests/Fixtures/pdf-segmentation/s12_paper.pdf")
        let wideFixture = m4Stage03RepoRoot.appendingPathComponent("Tests/Fixtures/pdf-segmentation-02b/s12_wide_table_fig_cols.pdf")

        let parityProbes: [(URL, String, Int?, Int32, String)] = [
            (
                s12Paper,
                "Our deterministic verifier completes static analysis across 368 regression tests in 14.5 ms on a single CPU core.",
                nil,
                0,
                "FOUND"
            ),
            (
                s12Paper,
                "Our deterministic verifier completes static analysis across 9999 regression tests in 14.5 ms on a single CPU core.",
                2,
                1,
                "NUMERIC_MISMATCH"
            ),
            (
                s12Paper,
                "The moon is made of green cheese in our analysis.",
                nil,
                3,
                "NOT_FOUND"
            ),
            (
                wideFixture,
                "The encoder uses 3 layers and 4 attention heads across 19 datasets grouped into 4 task families.",
                1,
                0,
                "FOUND"
            ),
            (
                wideFixture,
                "The encoder uses 4 layers and 3 attention heads across 19 datasets grouped into 4 task families.",
                1,
                1,
                "NUMERIC_MISMATCH"
            )
        ]

        for (idx, (pdfURL, claim, optTopK, expectedCLIExit, expectedVerdict)) in parityProbes.enumerated() {
            var cliArgs = ["locate-evidence", pdfURL.path, "--claim", claim, "--json"]
            var mcpArgs: [String: Any] = ["pdf_file": pdfURL.path, "claim": claim]
            if let topK = optTopK {
                cliArgs += ["--top-k", String(topK)]
                mcpArgs["top_k"] = topK
            }

            let cliRes = await cli.runWithExitStatus(arguments: cliArgs)
            #expect(cliRes.exitCode == expectedCLIExit)

            let reqObj: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 200 + idx,
                "method": "tools/call",
                "params": ["name": "locate_evidence", "arguments": mcpArgs]
            ]
            let reqLine = String(decoding: try JSONSerialization.data(withJSONObject: reqObj), as: UTF8.self)
            let mcpRunner = ScholarCLIRunner(environment: env, mcpInputLines: [reqLine])
            let mcpOut = await mcpRunner.runWithExitStatus(arguments: ["mcp", "--offline"])
            #expect(mcpOut.exitCode == 0)

            let mcpEnv = try #require(JSONSerialization.jsonObject(with: Data(mcpOut.stdout.utf8)) as? [String: Any])
            let mcpRes = try #require(mcpEnv["result"] as? [String: Any])
            #expect(mcpRes["isError"] as? Bool == false)
            let mcpText = try #require(((mcpRes["content"] as? [[String: Any]])?.first)?["text"] as? String)

            let parsedCLI = try #require(JSONSerialization.jsonObject(with: Data(cliRes.stdout.utf8)) as? [String: Any])
            #expect(parsedCLI["verdict"] as? String == expectedVerdict)
            #expect(
                mcpText == cliRes.stdout,
                "MCP locate_evidence JSON diverged from CLI locate-evidence --json for probe \(idx):\nMCP: \(mcpText)\nCLI: \(cliRes.stdout)"
            )

            // Sync executeToolCall path must also match byte-for-byte
            let syncRes = server.executeToolCall(name: "locate_evidence", arguments: mcpArgs)
            #expect(syncRes["isError"] as? Bool == false)
            let syncText = try #require(((syncRes["content"] as? [[String: Any]])?.first)?["text"] as? String)
            #expect(syncText == cliRes.stdout)
        }

        // Unknown, missing, empty, or wrong-type arguments -> isError: true + ERR_INVALID_ARGUMENT
        let badArgPayloads: [[String: Any]] = [
            [:],
            ["pdf_file": s12Paper.path],
            ["claim": "Some claim"],
            ["pdf_file": "", "claim": "Some claim"],
            ["pdf_file": "   ", "claim": "Some claim"],
            ["pdf_file": s12Paper.path, "claim": ""],
            ["pdf_file": s12Paper.path, "claim": "   \t\n  "],
            ["pdf_file": 42, "claim": "Some claim"],
            ["pdf_file": s12Paper.path, "claim": false],
            ["pdf_file": s12Paper.path, "claim": "Some claim", "top_k": true],
            ["pdf_file": s12Paper.path, "claim": "Some claim", "top_k": "3"],
            ["pdf_file": s12Paper.path, "claim": "Some claim", "top_k": 0],
            ["pdf_file": s12Paper.path, "claim": "Some claim", "top_k": -5],
            ["pdf_file": s12Paper.path, "claim": "Some claim", "top_k": 2.5],
            ["pdf_file": s12Paper.path, "claim": "Some claim", "unknown_param": "x"],
            ["pdf_file": s12Paper.path, "claim": "Some claim", "citeKey": "rivera2026"],
            ["pdf_file": s12Paper.path, "claim": "Some claim", "demo": true],
            ["pdf_file": s12Paper.path, "claim": "Some claim", "projectPath": tempDir.path],
            ["pdf_file": s12Paper.path, "claim": "Some claim", "registryReplayPath": tempDir.path]
        ]
        for badArgs in badArgPayloads {
            let errRes = await server.executeToolCallAsync(name: "locate_evidence", arguments: badArgs)
            #expect(errRes["isError"] as? Bool == true, "Expected isError=true for \(badArgs), got \(errRes)")
            let errText = try #require(((errRes["content"] as? [[String: Any]])?.first)?["text"] as? String)
            let errObj = try #require(
                try? JSONSerialization.jsonObject(with: Data(errText.utf8)) as? [String: Any],
                "Expected structured JSON error for \(badArgs), got \(errText)"
            )
            #expect(
                errObj["error_code"] as? String == "ERR_INVALID_ARGUMENT",
                "Expected ERR_INVALID_ARGUMENT for \(badArgs), got \(errObj)"
            )
        }

        // Missing file, non-PDF file, and blank zero-text PDF -> isError: true
        let nonPDF = tempDir.appendingPathComponent("corrupt.pdf")
        try Data("not a pdf".utf8).write(to: nonPDF)
        let blankPDF = tempDir.appendingPathComponent("blank.pdf")
        try writeBlankZeroTextPDF(to: blankPDF)
        for badPath in [tempDir.appendingPathComponent("no_such.pdf").path, nonPDF.path, blankPDF.path] {
            let ioErr = await server.executeToolCallAsync(
                name: "locate_evidence",
                arguments: ["pdf_file": badPath, "claim": "Valid claim text"]
            )
            #expect(ioErr["isError"] as? Bool == true, "Expected isError=true on bad PDF \(badPath), got \(ioErr)")
        }
    }
}
