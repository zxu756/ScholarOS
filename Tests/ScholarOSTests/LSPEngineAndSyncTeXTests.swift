import Foundation
import Testing
import ScholarModels
import ScholarMarkupAST
import ScholarBibAndCSL
import ScholarLSPEngine

@Suite("Academic LSP Completion, Hover/Definition/Rename & Bidirectional SyncTeX")
struct LSPEngineAndSyncTeXTests {

    // MARK: - Fixtures

    private static var recordedRegistryFixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/registry", isDirectory: true)
    }

    private func sampleBibliography() -> [BibliographyEntry] {
        [
            BibliographyEntry(
                citeKey: "vaswani2017",
                kind: .inproceedings,
                title: "Attention Is All You Need",
                authors: [
                    BibAuthor(givenName: "Ashish", familyName: "Vaswani"),
                    BibAuthor(givenName: "Noam", familyName: "Shazeer"),
                    BibAuthor(givenName: "Niki", familyName: "Parmar"),
                    BibAuthor(givenName: "Jakob", familyName: "Uszkoreit"),
                    BibAuthor(givenName: "Llion", familyName: "Jones"),
                    BibAuthor(givenName: "Aidan N.", familyName: "Gomez"),
                    BibAuthor(givenName: "Lukasz", familyName: "Kaiser"),
                    BibAuthor(givenName: "Illia", familyName: "Polosukhin")
                ],
                year: 2017,
                venue: "NeurIPS",
                doi: "10.48550/arXiv.1706.03762",
                firewallClass: .verified,
                firewallAuditNote: "Verified registry record"
            ),
            BibliographyEntry(
                citeKey: "dao2022",
                kind: .inproceedings,
                title: "FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness",
                authors: [
                    BibAuthor(givenName: "Tri", familyName: "Dao"),
                    BibAuthor(givenName: "", familyName: "others")
                ],
                year: 2022,
                venue: "NeurIPS",
                arxivID: "2205.14135",
                firewallClass: .verified,
                firewallAuditNote: "Verified arXiv preprint"
            ),
            BibliographyEntry(
                citeKey: "draft2024unverified",
                kind: .misc,
                title: "Unpublished Workshop Notes on Attention Kernels",
                authors: [BibAuthor(givenName: "Pat", familyName: "Taylor")],
                year: 2024,
                firewallClass: .unverified,
                firewallAuditNote: "Missing DOI/arXiv/PMID"
            ),
            BibliographyEntry(
                citeKey: "smith2025hallucinated",
                kind: .article,
                title: "Hallucinated Zero-Overhead Infinite Context Attention",
                authors: [BibAuthor(givenName: "John", familyName: "Smith")],
                year: 2025,
                venue: "Fabricated Letters",
                doi: "10.9999/fake.2025.999",
                firewallClass: .notFound,
                firewallAuditNote: "Sentinel fabricated DOI"
            )
        ]
    }

    private func inRunVerdictsForSampleBibliography() async throws -> [String: CitationFirewallEntryVerdict] {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall()
        var out: [String: CitationFirewallEntryVerdict] = [:]
        for entry in sampleBibliography() {
            let verdict = await firewall.verifyAgainstPublicRegistries(entry: entry, session: replay)
            out[entry.citeKey] = verdict
        }
        return out
    }

    // MARK: - 1. Completion Context & Firewall-Gated Completion Tests

    @Test("AcademicCompletionEngine detects LaTeX multi-key \\citep cluster and Typst @/#cite contexts")
    func completionContextDetectsLaTeXCiteMultiKeyClusterAndTypstCite() {
        let engine = AcademicCompletionEngine()
        let latex = "We compare \\citep[see][p.~5]{vaswani2017, dao"
        let pos = TextPosition(line: 1, column: latex.count + 1, utf8Offset: latex.utf8.count)

        let ctx = engine.detectContext(in: latex, filePath: "main.tex", at: pos)
        #expect(ctx.triggerKind == .citation)
        #expect(ctx.queryPrefix == "dao")
        #expect(ctx.alreadyCitedKeysInCluster == ["vaswani2017"])

        let typst = "Prior work @vasw"
        let typstPos = TextPosition(line: 1, column: typst.count + 1, utf8Offset: typst.utf8.count)
        let typstCtx = engine.detectContext(in: typst, filePath: "paper.typ", at: typstPos)
        #expect(typstCtx.triggerKind == .citation)
        #expect(typstCtx.queryPrefix == "vasw")
    }

    @Test("\\cite{ completion flags smith2025hallucinated and unverified entries with ERR_UNVERIFIED_CITATION and demotes score")
    func citationCompletionFlagsAndDemotesBlockedSmith2025AndUnverifiedEntries() async throws {
        let engine = AcademicCompletionEngine()
        let source = "Related studies \\cite{"
        let pos = TextPosition(line: 1, column: source.count + 1, utf8Offset: source.utf8.count)
        let bib = sampleBibliography()

        // Without in-run verification, stored `.verified` on `vaswani2017` is not trusted (M1 item 8 / S42/S48).
        let offlineItems = engine.complete(
            in: source,
            filePath: "main.tex",
            at: pos,
            bibliography: bib
        )
        let offlineVaswani = try #require(offlineItems.first { $0.insertText == "vaswani2017" })
        #expect(offlineVaswani.subtitle.contains("UNVERIFIED"))

        let inRunVerdicts = try await inRunVerdictsForSampleBibliography()
        let items = engine.complete(
            in: source,
            filePath: "main.tex",
            at: pos,
            bibliography: bib,
            inRunVerdictsByKey: inRunVerdicts
        )

        let vaswaniItem = try #require(items.first { $0.insertText == "vaswani2017" })
        let unverifiedItem = try #require(items.first { $0.insertText == "draft2024unverified" })
        let blockedSmithItem = try #require(items.first { $0.insertText == "smith2025hallucinated" })

        #expect(blockedSmithItem.subtitle.contains("NOT FOUND"))
        #expect(blockedSmithItem.detailMarkdown.contains("ERR_UNVERIFIED_CITATION"))
        #expect(unverifiedItem.subtitle.contains("UNVERIFIED"))
        #expect(unverifiedItem.detailMarkdown.contains("ERR_UNVERIFIED_CITATION"))

        // Verified item must strictly outrank both unverified and not-found items!
        #expect(vaswaniItem.relevanceScore > unverifiedItem.relevanceScore)
        #expect(unverifiedItem.relevanceScore > blockedSmithItem.relevanceScore)
    }

    @Test("\\eqref{ completion boosts equation labels above figure and section labels")
    func labelCompletionBoostsEquationLabelsInsideEqref() throws {
        let doc = """
        \\section{Architecture}\\label{sec:arch}
        \\begin{figure}\\caption{Diagram}\\label{fig:arch}\\end{figure}
        \\begin{equation}\\label{eq:arch} x = y \\end{equation}
        By substituting \\eqref{
        """
        let parsed = HandwrittenMarkupCSTParser().parse(source: doc, filePath: "main.tex", format: .latex)
        let symTable = MacroExpansionEngine().buildSymbolTable(from: parsed)
        let engine = AcademicCompletionEngine()

        let lines = doc.components(separatedBy: "\n")
        let line4 = lines[3]
        let pos = TextPosition(line: 4, column: line4.count + 1)

        let items = engine.complete(
            in: doc,
            filePath: "main.tex",
            at: pos,
            symbolTable: symTable
        )

        #expect(!items.isEmpty)
        let top = try #require(items.first)
        #expect(top.category == .labelRef)
        #expect(top.insertText == "eq:arch")
    }

    @Test("\\begin{ environment snippet completion and \\end{ innermost unclosed environment stack completion")
    func environmentSnippetAndClosingTagStackCompletion() throws {
        let engine = AcademicCompletionEngine()

        let beginSource = "\\begin{fig"
        let beginPos = TextPosition(line: 1, column: beginSource.count + 1, utf8Offset: beginSource.utf8.count)
        let beginItems = engine.complete(in: beginSource, filePath: "main.tex", at: beginPos)
        let figItem = try #require(beginItems.first { $0.title.contains("figure") || $0.insertText.contains("figure") })
        #expect(figItem.category == .environment)
        #expect(figItem.insertText.contains("\\caption") || figItem.insertText.contains("\\end{figure}"))

        let unclosedDoc = """
        \\begin{figure}
        \\begin{center}
        \\end{
        """
        let closePos = TextPosition(line: 3, column: 6)
        let closeItems = engine.complete(in: unclosedDoc, filePath: "main.tex", at: closePos)
        let firstClose = try #require(closeItems.first)
        #expect(firstClose.insertText.hasPrefix("center"))
    }

    @Test("User macro and inline math Greek symbol completion while suppressing completions inside % comments")
    func userMacroAndInlineMathSymbolCompletion() {
        let source = """
        \\newcommand{\\klDiv}[2]{D_{\\mathrm{KL}}(#1 \\parallel #2)}
        In math $\\alp$ and macro \\klD
        % Inside a comment \\cite{
        """
        let parsed = HandwrittenMarkupCSTParser().parse(source: source, filePath: "main.tex", format: .latex)
        let table = MacroExpansionEngine().buildSymbolTable(from: parsed)
        let engine = AcademicCompletionEngine()

        // Math symbol completion at `\alp` on line 2 (`In math $\alp` -> col 14)
        let mathItems = engine.complete(
            in: source,
            filePath: "main.tex",
            at: TextPosition(line: 2, column: 14),
            symbolTable: table
        )
        #expect(mathItems.contains { $0.insertText.contains("alpha") })

        // User macro completion at `\klD` at end of line 2
        let macroItems = engine.complete(
            in: source,
            filePath: "main.tex",
            at: TextPosition(line: 2, column: 30),
            symbolTable: table
        )
        #expect(macroItems.contains { $0.category == .userMacro && $0.title.contains("klDiv") })

        // Comment suppression on line 3
        let commentItems = engine.complete(
            in: source,
            filePath: "main.tex",
            at: TextPosition(line: 3, column: 26),
            symbolTable: table,
            bibliography: sampleBibliography()
        )
        #expect(commentItems.isEmpty)
    }

    // MARK: - 2. Hover, Go-to-Definition & Find References Tests

    @Test("HoverDefinitionAndReferencesEngine produces APA 7th citation preview and firewall status badges")
    func hoverCardRendersCitationAPA7PreviewAndFirewallBadge() async throws {
        let files = [
            "main.tex": """
            \\section{Related Work}
            Transformers \\cite{vaswani2017} contrast with \\cite{smith2025hallucinated}.
            """
        ]
        let workspace = MultiFileIncludeGraphResolver().resolveWorkspace(rootFilePath: "main.tex", files: files)
        let nav = HoverDefinitionAndReferencesEngine()
        let bib = sampleBibliography()
        let inRunVerdicts = try await inRunVerdictsForSampleBibliography()

        let verifiedHover = try #require(nav.hover(
            at: TextPosition(line: 2, column: 23),
            in: "main.tex",
            workspace: workspace,
            sourcesByFile: files,
            bibliography: bib,
            inRunVerdictsByKey: inRunVerdicts
        ))
        #expect(verifiedHover.firewallClass == .verified)
        #expect(verifiedHover.markdownBody.contains("Attention Is All You Need"))
        #expect(!verifiedHover.markdownBody.contains("Verified DOI"))

        let blockedHover = try #require(nav.hover(
            at: TextPosition(line: 2, column: 58),
            in: "main.tex",
            workspace: workspace,
            sourcesByFile: files,
            bibliography: bib,
            inRunVerdictsByKey: inRunVerdicts
        ))
        #expect(blockedHover.firewallClass == .notFound)
        #expect(blockedHover.markdownBody.contains("NOT_FOUND") || blockedHover.categoryBadge.contains("Not Found"))
    }

    @Test("Hover card previews cross-referenced equation context, user macro expansion, and math Unicode")
    func hoverCardRendersLabelEnclosureMacroSignatureAndMathUnicodePreview() throws {
        let files = [
            "main.tex": """
            \\newcommand{\\regTerm}[1]{\\lambda \\|#1\\|_2^2}
            \\begin{equation}\\label{eq:obj}
            \\mathcal{L}(w) = \\regTerm{w}
            \\end{equation}
            Minimizing \\eqref{eq:obj} uses $\\sum_{i=1}^{n} \\alpha_i$.
            """
        ]
        let workspace = MultiFileIncludeGraphResolver().resolveWorkspace(rootFilePath: "main.tex", files: files)
        let nav = HoverDefinitionAndReferencesEngine()

        let refHover = try #require(nav.hover(
            at: TextPosition(line: 5, column: 21),
            in: "main.tex",
            workspace: workspace,
            sourcesByFile: files
        ))
        #expect(refHover.title.contains("eq:obj"))

        let macroCallHover = try #require(nav.hover(
            at: TextPosition(line: 3, column: 21),
            in: "main.tex",
            workspace: workspace,
            sourcesByFile: files
        ))
        #expect(macroCallHover.markdownBody.contains("regTerm"))
    }

    @Test("Go-to-definition resolves cross-file \\label declarations, .bib entry headers, and \\input targets")
    func goToDefinitionNavigatesAcrossIncludedTeXFilesAndBibTeXEntries() throws {
        let files: [String: String] = [
            "main.tex": """
            \\input{sections/methods}
            In \\ref{eq:flash}, we extend \\cite{dao2022}.
            """,
            "sections/methods.tex": """
            \\section{IO-Aware Tiling}
            \\begin{equation}\\label{eq:flash}
            O = \\mathrm{softmax}(QK^\\top)V
            \\end{equation}
            """
        ]
        let bibFiles: [String: String] = [
            "references.bib": """
            @inproceedings{vaswani2017,
              title = {Attention Is All You Need},
              year = {2017}
            }

            @inproceedings{dao2022,
              title = {FlashAttention},
              year = {2022}
            }
            """
        ]
        let workspace = MultiFileIncludeGraphResolver().resolveWorkspace(rootFilePath: "main.tex", files: files)
        let nav = HoverDefinitionAndReferencesEngine()

        // 1. \input{sections/methods} -> sections/methods.tex line 1
        let includeDefs = nav.definition(
            at: TextPosition(line: 1, column: 12),
            in: "main.tex",
            workspace: workspace,
            sourcesByFile: files
        )
        #expect(includeDefs.first?.targetSpan.filePath == "sections/methods.tex")

        // 2. \ref{eq:flash} -> sections/methods.tex line 2
        let labelDefs = nav.definition(
            at: TextPosition(line: 2, column: 11),
            in: "main.tex",
            workspace: workspace,
            sourcesByFile: files
        )
        let labelTarget = try #require(labelDefs.first)
        #expect(labelTarget.targetSpan.filePath == "sections/methods.tex")
        #expect(labelTarget.targetSpan.start.line == 2)

        // 3. \cite{dao2022} -> references.bib line 6
        let bibDefs = nav.definition(
            at: TextPosition(line: 2, column: 38),
            in: "main.tex",
            workspace: workspace,
            sourcesByFile: files,
            bibliography: sampleBibliography(),
            bibliographyFiles: bibFiles
        )
        let bibTarget = try #require(bibDefs.first)
        #expect(bibTarget.targetSpan.filePath == "references.bib")
        #expect(bibTarget.targetSpan.start.line == 6)
    }

    @Test("Find references aggregates cross-file label declarations and \\ref/\\eqref call sites")
    func findReferencesCollectsCrossFileLabelCitationAndMacroUsages() {
        let files: [String: String] = [
            "main.tex": """
            \\input{methods}
            \\input{results}
            Summary recalls \\ref{eq:core}.
            """,
            "methods.tex": "\\begin{equation}\\label{eq:core} y = f(x) \\end{equation}",
            "results.tex": "Experiments validate \\eqref{eq:core} under noise."
        ]
        let workspace = MultiFileIncludeGraphResolver().resolveWorkspace(rootFilePath: "main.tex", files: files)
        let nav = HoverDefinitionAndReferencesEngine()

        let refsWithDecl = nav.findReferences(
            at: TextPosition(line: 3, column: 24),
            in: "main.tex",
            workspace: workspace,
            sourcesByFile: files,
            includeDeclaration: true
        )
        #expect(refsWithDecl.count == 3)

        let refsOnly = nav.findReferences(
            at: TextPosition(line: 3, column: 24),
            in: "main.tex",
            workspace: workspace,
            sourcesByFile: files,
            includeDeclaration: false
        )
        #expect(refsOnly.count == 2)
    }

    // MARK: - 3. Workspace Diagnostics, Quick-Fixes & Cross-File Rename Refactoring

    @Test("WorkspaceDiagnosticsAndQuickFixEngine emits ERR_UNVERIFIED_CITATION and CITE404 fuzzy quick-fix")
    func diagnosticsEngineEmitsFirewallBlockerAndCite404FuzzyQuickFix() throws {
        let files = [
            "main.tex": """
            \\section{Intro}
            Typo citation \\cite{vaswani201} and hallucinated \\cite{smith2025hallucinated}.
            """
        ]
        let workspace = MultiFileIncludeGraphResolver().resolveWorkspace(rootFilePath: "main.tex", files: files)
        let engine = WorkspaceDiagnosticsAndQuickFixEngine()
        let report = engine.analyze(
            workspace: workspace,
            bibliography: sampleBibliography(),
            sourcesByFile: files
        )

        #expect(report.firewallViolationCount >= 1)
        #expect(report.diagnostics.contains { $0.code == "ERR_UNVERIFIED_CITATION" })
        #expect(report.diagnostics.contains { $0.code == "CITE404" })

        // Verify fuzzy quick-fix rewrites `vaswani201` -> `vaswani2017`
        let fixAction = try #require(report.codeActions.first {
            $0.diagnosticCode == "CITE404" && $0.title.contains("vaswani2017")
        })
        let patchedFiles = fixAction.workspaceEdit.apply(toFiles: files)
        #expect(patchedFiles["main.tex"]?.contains("\\cite{vaswani2017}") == true)
    }

    @Test("Diagnostics engine emits SYM004 unresolved label quick-fix and SYM005 \\eqref category mismatch fix")
    func diagnosticsEngineEmitsUnresolvedRefAndEqrefCategoryMismatchQuickFixes() throws {
        let files = [
            "main.tex": """
            \\section{Introduction}\\label{sec:intro}
            \\begin{figure}\\caption{Overview}\\label{fig:overview}\\end{figure}
            See \\ref{sec:intr} and \\eqref{fig:overview}.
            """
        ]
        let workspace = MultiFileIncludeGraphResolver().resolveWorkspace(rootFilePath: "main.tex", files: files)
        let report = WorkspaceDiagnosticsAndQuickFixEngine().analyze(workspace: workspace, sourcesByFile: files)

        #expect(report.diagnostics.contains { $0.code == "SYM004" })
        #expect(report.diagnostics.contains { $0.code == "SYM005" })

        let labelFix = try #require(report.codeActions.first {
            $0.diagnosticCode == "SYM004" && $0.title.contains("sec:intro")
        })
        let updated = labelFix.workspaceEdit.apply(toFiles: files)
        #expect(updated["main.tex"]?.contains("\\ref{sec:intro}") == true)
    }

    @Test("ScholarRenameRefactorer renames \\label and all cross-file \\ref/\\eqref/\\cref occurrences")
    func renameRefactorerUpdatesLabelsAcrossMultipleWorkspaceFiles() {
        let files: [String: String] = [
            "main.tex": "\\input{methods}\n\\input{appendix}\nMain text cites \\eqref{eq:old-loss}.",
            "methods.tex": "\\begin{equation}\\label{eq:old-loss} L = 0 \\end{equation}",
            "appendix.tex": "Proof of \\cref{eq:old-loss} and \\ref{eq:old-loss}."
        ]
        let workspace = MultiFileIncludeGraphResolver().resolveWorkspace(rootFilePath: "main.tex", files: files)
        let refactorer = ScholarRenameRefactorer()

        let edit = refactorer.renameLabel(
            oldKey: "eq:old-loss",
            newKey: "eq:variational-elbo",
            in: workspace,
            sourcesByFile: files
        )
        #expect(edit.affectedEditCount == 4)

        let updated = edit.apply(toFiles: files)
        #expect(updated["methods.tex"]?.contains("\\label{eq:variational-elbo}") == true)
        #expect(updated["main.tex"]?.contains("\\eqref{eq:variational-elbo}") == true)
        #expect(updated["appendix.tex"]?.contains("\\cref{eq:variational-elbo}") == true)
        #expect(updated["appendix.tex"]?.contains("\\ref{eq:variational-elbo}") == true)
    }

    @Test("ScholarRenameRefactorer renames citeKey inside multi-key citation clusters and .bib entry header")
    func renameRefactorerUpdatesCiteKeyInMultiKeyClustersAndBibFile() {
        let texFiles = [
            "main.tex": "Joint citation \\citep{vaswani2017, dao2022, dao2022_extra} and solo \\citet{dao2022}."
        ]
        let bibFiles = [
            "references.bib": """
            @inproceedings{dao2022,
              title = {FlashAttention},
              year = {2022}
            }
            """
        ]
        let workspace = MultiFileIncludeGraphResolver().resolveWorkspace(rootFilePath: "main.tex", files: texFiles)
        let edit = ScholarRenameRefactorer().renameCiteKey(
            oldKey: "dao2022",
            newKey: "dao2022flashattention",
            in: workspace,
            sourcesByFile: texFiles,
            bibliographyFiles: bibFiles
        )

        var combined = texFiles
        combined["references.bib"] = bibFiles["references.bib"]
        let updated = edit.apply(toFiles: combined)

        #expect(updated["main.tex"] == "Joint citation \\citep{vaswani2017, dao2022flashattention, dao2022_extra} and solo \\citet{dao2022flashattention}.")
        #expect(updated["references.bib"]?.contains("@inproceedings{dao2022flashattention,") == true)
    }

    @Test("ScholarRenameRefactorer renames LaTeX macro while preserving prefix-sharing commands")
    func renameRefactorerUpdatesMacroRespectingExactCommandTokenBoundaries() {
        let files = [
            "main.tex": """
            \\newcommand{\\kl}[2]{D(#1\\|#2)}
            We minimize $\\kl{p}{q} + \\kleinParam$.
            """
        ]
        let workspace = MultiFileIncludeGraphResolver().resolveWorkspace(rootFilePath: "main.tex", files: files)
        let edit = ScholarRenameRefactorer().renameMacro(
            oldName: "\\kl",
            newName: "\\klDivergence",
            in: workspace,
            sourcesByFile: files
        )
        let updated = edit.apply(toFiles: files)

        #expect(updated["main.tex"]?.contains("\\newcommand{\\klDivergence}[2]") == true)
        #expect(updated["main.tex"]?.contains("\\klDivergence{p}{q}") == true)
        // Must NOT corrupt `\kleinParam`!
        #expect(updated["main.tex"]?.contains("\\kleinParam") == true)
    }

    // MARK: - 4. Bidirectional SyncTeX & Zlib/Gzip Solver Tests

    @Test("SyncTeXZlibCodec gzip compression/decompression round-trip and scaled-point coordinate conversion")
    func syncTeXZlibGzipRoundTripAndScaledPointCoordinateParsing() throws {
        let syncTeXText = """
        SyncTeX Version:1
        Input:1:./main.tex
        Input:2:./sections/methods.tex
        Output:pdf
        Magnification:1000
        Unit:1
        X Offset:0
        Y Offset:0
        Content:
        {1
        [1,1:4718592,52428800:30670848,45875200,0
        (1,12:4718592,9437184:28000000,786432,196608
        x1,12:12000000,9437184
        )
        (2,5:4718592,19660800:26000000,786432,196608
        )
        ]
        }
        Postamble:
        """

        let rawData = Data(syncTeXText.utf8)
        #expect(!SyncTeXZlibCodec.isCompressedGzipOrZlib(rawData))

        let gzipped = try SyncTeXZlibCodec.compressGzip(rawData)
        #expect(SyncTeXZlibCodec.isCompressedGzipOrZlib(gzipped))
        #expect(gzipped.count > 10)

        let decompressed = try SyncTeXZlibCodec.decompressIfNeeded(gzipped)
        #expect(decompressed == rawData)

        let solver = try SyncTeXCoordinateSolver(data: gzipped)
        #expect(solver.pageCount == 1)
        #expect(solver.preamble.inputsByTag.count == 2)
        // 4718592 / 65536 = 72.0 pt
        let anchor = try solver.resolveForwardSearch(sourceFile: "main.tex", line: 12, column: 1)
        #expect(anchor.pdfPageIndex == 0)
        #expect(abs(anchor.xPt - 72.0) < 1.0)
    }

    @Test("SyncTeXCoordinateSolver bidirectional forward interpolation and inverse leaf-enclosure + Euclidean fallback")
    func syncTeXBidirectionalForwardAndInverseSearchExactAndInterpolated() throws {
        let records: [SyncTeXGeometricRecord] = [
            SyncTeXGeometricRecord(
                kind: .vbox,
                inputTag: 1,
                sourceFile: "main.tex",
                line: 1,
                pdfPageIndex: 0,
                xPt: 72,
                yPt: 72,
                widthPt: 468,
                heightPt: 648
            ),
            SyncTeXGeometricRecord(
                kind: .hbox,
                inputTag: 1,
                sourceFile: "main.tex",
                line: 10,
                column: 1,
                pdfPageIndex: 0,
                xPt: 72,
                yPt: 120,
                widthPt: 420,
                heightPt: 14
            ),
            SyncTeXGeometricRecord(
                kind: .hbox,
                inputTag: 1,
                sourceFile: "main.tex",
                line: 20,
                column: 1,
                pdfPageIndex: 0,
                xPt: 72,
                yPt: 260,
                widthPt: 420,
                heightPt: 14
            ),
            SyncTeXGeometricRecord(
                kind: .hbox,
                inputTag: 2,
                sourceFile: "sections/results.tex",
                line: 8,
                column: 1,
                pdfPageIndex: 1,
                xPt: 72,
                yPt: 100,
                widthPt: 400,
                heightPt: 14
            )
        ]

        let solver = SyncTeXCoordinateSolver(
            preamble: SyncTeXPreamble(inputsByTag: [1: "main.tex", 2: "sections/results.tex"]),
            pageCount: 2,
            records: records
        )

        // Exact forward search on page 2 (0-indexed page 1)
        let exact = try solver.resolveForwardSearch(sourceFile: "sections/results.tex", line: 8)
        #expect(exact.pdfPageIndex == 1)
        #expect(abs(exact.yPt - 100.0) < 0.1)

        // Interpolated forward search for line 15 (midway between line 10 @ y=120 and line 20 @ y=260)
        let interp = try solver.resolveForwardSearch(sourceFile: "main.tex", line: 15)
        #expect(interp.pdfPageIndex == 0)
        #expect(interp.yPt >= 120.0 && interp.yPt <= 260.0)

        // Exact leaf enclosure inverse click inside line 20 hbox (preferring tight 14pt hbox over outer 648pt page vbox!)
        let hitInside = try solver.resolveInverseSearch(pdfPageIndex: 0, xPt: 180.0, yPt: 266.0)
        #expect(hitInside.sourceFile == "main.tex")
        #expect(hitInside.line == 20)
        #expect(hitInside.isExactEnclosure)
        #expect(hitInside.euclideanDistancePt == 0.0)

        // Margin click at x=20, y=125 falls outside hboxes -> nearest Euclidean fallback to line 10!
        let marginHit = try solver.resolveInverseSearch(pdfPageIndex: 0, xPt: 20.0, yPt: 125.0)
        #expect(marginHit.line == 10)
        #expect(marginHit.euclideanDistancePt > 0.0)
    }

    @Test("SyntheticSyncTeXBuilder writes compressed .synctex.gz to temp file and round-trips forward/inverse coordinates")
    func syntheticSyncTeXBuilderGeneratesCompressedArchiveAndLoadsFromDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-synctex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let files: [String: String] = [
            "main.tex": """
            \\section{Introduction}
            First paragraph on page one.
            \\input{methods}
            """,
            "methods.tex": """
            \\section{Methodology}
            \\begin{equation}\\label{eq:main}
            E = m c^2
            \\end{equation}
            Detailed methodological derivation follows here.
            """
        ]
        let workspace = MultiFileIncludeGraphResolver().resolveWorkspace(rootFilePath: "main.tex", files: files)
        let builder = SyntheticSyncTeXBuilder()
        let compressedData = try builder.buildSyncTeXData(from: workspace, compressed: true)

        let gzFile = tempDir.appendingPathComponent("main.synctex.gz")
        try compressedData.write(to: gzFile)

        let loadedSolver = try SyncTeXCoordinateSolver.load(fromFilePath: gzFile.path)
        #expect(loadedSolver.pageCount >= 1)

        let forward = try loadedSolver.resolveForwardSearch(sourceFile: "methods.tex", line: 2)
        let inverse = try loadedSolver.resolveInverseSearch(
            pdfPageIndex: forward.pdfPageIndex,
            xPt: forward.xPt + 12.0,
            yPt: forward.yPt + 4.0
        )
        #expect(inverse.sourceFile == "methods.tex")
    }

    // MARK: - 5. Stateful ScholarLSPWorkspaceService Integration Tests

    @Test("ScholarLSPWorkspaceService supports incremental edits, code actions, and assertAllCitedEntriesPassFirewall")
    func lspWorkspaceServiceIncrementalEditsCodeActionAndFirewallGate() async throws {
        let initialMain = """
        \\section{Introduction}\\label{sec:intro}
        We cite \\cite{smith2025hallucinated} in draft v1.
        """
        let service = ScholarLSPWorkspaceService(
            rootFilePath: "main.tex",
            files: ["main.tex": initialMain],
            bibliography: sampleBibliography()
        )

        // Firewall gate must throw ERR_UNVERIFIED_CITATION while `smith2025hallucinated` is cited
        do {
            try service.assertAllCitedEntriesPassFirewall()
            Issue.record("Expected ERR_UNVERIFIED_CITATION when citing smith2025hallucinated")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }

        // Apply range edit replacing `smith2025hallucinated` with `vaswani2017`
        let relex = try service.applyRangeEdit(
            filePath: "main.tex",
            startLine: 2,
            startColumn: 15,
            endLine: 2,
            endColumn: 36,
            replacementText: "vaswani2017"
        )
        #expect(!relex.tokens.isEmpty)
        #expect(service.sourceText(for: "main.tex")?.contains("\\cite{vaswani2017}") == true)

        // Stored `.verified` on `vaswani2017` is not trusted before in-run verification (M1 item 8 / S42/S48).
        do {
            try service.assertAllCitedEntriesPassFirewall()
            Issue.record("Expected ERR_UNVERIFIED_CITATION before verifyCitationsOnline runs")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }

        // Verify citations in this run against recorded registry fixtures; firewall gate now clears cleanly!
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        _ = await service.verifyCitationsOnline(using: replay)
        try service.assertAllCitedEntriesPassFirewall()
        #expect(service.diagnosticsReport().firewallViolationCount == 0)
    }

    @Test("ScholarLSPWorkspaceService.loadFromDirectory indexes multi-file project, .bib library, and status summary")
    func lspWorkspaceServiceLoadFromDirectoryAndStatusSummary() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-lspdir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mainTex = """
        \\newcommand{\\vecx}{\\mathbf{x}}
        \\begin{document}
        \\section{Overview}\\label{sec:ov}
        \\input{sub}
        \\bibliography{refs}
        \\end{document}
        """
        let subTex = """
        \\subsection{Details}\\label{sec:det}
        See \\ref{sec:ov} and \\cite{vaswani2017} for $\\vecx$.
        """
        let refsBib = """
        @inproceedings{vaswani2017,
          author = {Vaswani, Ashish},
          title  = {Attention Is All You Need},
          booktitle = {NeurIPS},
          year   = {2017},
          doi    = {10.5555/3295222.3295349}
        }
        """
        try mainTex.write(to: tempDir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try subTex.write(to: tempDir.appendingPathComponent("sub.tex"), atomically: true, encoding: .utf8)
        try refsBib.write(to: tempDir.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)

        let service = try ScholarLSPWorkspaceService.loadFromDirectory(
            projectDirectory: tempDir.path,
            rootFilePath: "main.tex",
            citationStyle: .ieee
        )

        let status = service.statusSummary()
        #expect(status.trackedDocumentCount == 2)
        #expect(status.bibliographyEntryCount == 1)
        #expect(status.outlineSectionCount == 2)
        #expect(status.declaredLabelCount == 2)
        #expect(status.declaredMacroCount == 1)
        // Unqueried refs.bib loaded offline is UNVERIFIED in M0 (S2 fix), producing 1 unverified citation diagnostic until verified online
        #expect(status.firewallViolationCount == 1)

        let syncData = try service.exportSyntheticSyncTeXData(compressed: true)
        #expect(SyncTeXZlibCodec.isCompressedGzipOrZlib(syncData))
    }

    // MARK: - M1 Stage 09: S48 LSP Completion, Hover & Diagnostics Provenance and TTL Expiration

    private final class LSPDialableClock: RegistryClock, @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        private var uptime: TimeInterval = 500.0

        init(initialUTCDate: Date) {
            self.date = initialUTCDate
        }

        func advance(by seconds: TimeInterval) {
            lock.lock()
            date = date.addingTimeInterval(seconds)
            uptime += seconds
            lock.unlock()
        }

        func now() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return uptime
        }

        func currentDate() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }

        func sleep(_ seconds: TimeInterval) async throws {
            advance(by: seconds)
        }
    }

    @Test("M1 Stage 09 (S48): LSP completion, hover, diagnostics, and assertAllCitedEntriesPassFirewall honor provenance and 30d/1d TTL expiration")
    func m1Stage09LSPCompletionHoverDiagnosticsRespectProvenanceAndClockExpiration() async throws {
        // Tests/Fixtures/registry was recorded on 2026-11-15 (S75 populates firewallVerifiedAtUTC from recorded fetchedAt)
        let initialUTC = try #require(BibliographyEntry.parseUTCDayStart("2026-11-15")).addingTimeInterval(9 * 3600)
        let clock = LSPDialableClock(initialUTCDate: initialUTC)
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)

        let bareLecun = BibliographyEntry(
            citeKey: "real_lecun",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539",
            firewallClass: .verified,
            firewallAuditNote: "Legacy bare verified"
        )
        let fakeEntry = BibliographyEntry(
            citeKey: "fake_nonsentinel",
            kind: .article,
            title: "Quantum Gradient Descent in Biological Neural Networks",
            authors: [
                BibAuthor(givenName: "Eleanor", familyName: "Whitfield"),
                BibAuthor(givenName: "Raj", familyName: "Patel")
            ],
            year: 2026,
            venue: "Nature Machine Intelligence",
            doi: "10.1038/fake.2026.99999"
        )

        let tex = """
        \\documentclass{article}
        \\begin{document}
        Valid cite \\cite{real_lecun} and fake \\cite{fake_nonsentinel}.
        Typing \\cite{real_l}
        \\end{document}
        """

        let service = ScholarLSPWorkspaceService(
            rootFilePath: "main.tex",
            files: ["main.tex": tex],
            bibliography: [bareLecun, fakeEntry],
            clock: clock
        )

        // 1. Before online verification: bare `firewallClass = .verified` without source/date is treated as UNVERIFIED everywhere
        let preHover = try #require(service.hover(atLine: 3, column: 20, in: "main.tex"))
        #expect(preHover.firewallClass == .unverified)
        let preCompletions = service.completions(atLine: 4, column: 18, in: "main.tex")
        let preLecunComp = try #require(preCompletions.first { $0.insertText == "real_lecun" })
        #expect(!preLecunComp.subtitle.contains("Verified"))
        let preDiags = service.diagnostics(in: "main.tex")
        #expect(preDiags.contains { $0.code == "ERR_UNVERIFIED_CITATION" && $0.message.contains("real_lecun") })

        // 2. Run verifyCitationsOnline(using: replay) -> writes source + 2026-11-15 (recorded fetchedAt) back to entries
        let onlineReport = await service.verifyCitationsOnline(using: replay)
        #expect(onlineReport.verifiedCount == 1)
        #expect(onlineReport.notFoundCount == 1)
        let storedLecun = try #require(service.bibliographyEntry(forCiteKey: "real_lecun"))
        #expect(storedLecun.firewallVerifiedSource?.isEmpty == false)
        #expect(storedLecun.firewallVerifiedAtUTC == "2026-11-15")

        // Create a fresh LSP service from the written-back entries (no inRunVerdicts, testing persisted entry provenance!)
        let persistedService = ScholarLSPWorkspaceService(
            rootFilePath: "main.tex",
            files: ["main.tex": tex],
            bibliography: service.bibliographyEntries,
            clock: clock
        )

        // At +29 days: real_lecun is still VERIFIED in hover, completion, and diagnostics!
        clock.advance(by: 29 * 86_400)
        let day29Hover = try #require(persistedService.hover(atLine: 3, column: 20, in: "main.tex"))
        #expect(day29Hover.firewallClass == .verified)
        let day29Comp = try #require(persistedService.completions(atLine: 4, column: 18, in: "main.tex").first { $0.insertText == "real_lecun" })
        #expect(day29Comp.subtitle.contains("Verified"))
        let day29Diags = persistedService.diagnostics(in: "main.tex")
        #expect(!day29Diags.contains { $0.code == "ERR_UNVERIFIED_CITATION" && $0.message.contains("real_lecun") })
        // Meanwhile fake_nonsentinel (NOT_FOUND, 1-day TTL) is already >1d old at +29d -> treated as UNVERIFIED with expired notice!
        let fakeHoverAt29d = try #require(persistedService.hover(atLine: 3, column: 48, in: "main.tex"))
        #expect(fakeHoverAt29d.firewallClass == .unverified)
        #expect(fakeHoverAt29d.markdownBody.contains("2026-11-15"))

        // Advance past 30 days (+2 more days -> +31d total): real_lecun ALSO expires on BOTH persistedService and original service!
        clock.advance(by: 2 * 86_400)
        // Force diagnostics cache refresh or re-evaluate via fresh query:
        for svc in [persistedService, service] {
            let expHover = try #require(svc.hover(atLine: 3, column: 20, in: "main.tex"))
            #expect(expHover.firewallClass == .unverified)
            #expect(expHover.markdownBody.contains("2026-11-15"))
            let expComp = try #require(svc.completions(atLine: 4, column: 18, in: "main.tex").first { $0.insertText == "real_lecun" })
            #expect(!expComp.subtitle.contains("• Verified"))
            #expect(expComp.detailMarkdown.contains("2026-11-15"))
            #expect(throws: ScholarOSError.self) {
                try svc.assertAllCitedEntriesPassFirewall()
            }
        }
        let freshExpiredDiagService = ScholarLSPWorkspaceService(
            rootFilePath: "main.tex",
            files: ["main.tex": "\\documentclass{article}\\begin{document}\\cite{real_lecun}\\end{document}"],
            bibliography: [storedLecun],
            clock: clock
        )
        let expDiags = freshExpiredDiagService.diagnostics(in: "main.tex")
        let expLecunDiag = try #require(expDiags.first { $0.code == "ERR_UNVERIFIED_CITATION" })
        #expect(expLecunDiag.message.contains("2026-11-15"))
        #expect(expLecunDiag.localizedMessage(.zhHans).contains("结论是 2026-11-15 取得的，已过期，需要重新核查"))
    }

    // MARK: - M2 Stage 02: Direct Library `ScholarLSPWorkspaceService.loadManuscript` Tests

    @Test("M2 Stage 02: ScholarLSPWorkspaceService.loadManuscript handles nested \\import vs \\subimport, braced {\\input{...}}, inline \\verb skip, and fallbackBBLFiles")
    func m2Stage02LoadManuscriptDirectLibraryEdgeCases() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-m2-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let modADir = tempDir.appendingPathComponent("modA/nested", isDirectory: true)
        let modBDir = tempDir.appendingPathComponent("modB", isDirectory: true)
        let tblDir = tempDir.appendingPathComponent("tables", isDirectory: true)
        try FileManager.default.createDirectory(at: modADir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modBDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tblDir, withIntermediateDirectories: true)

        try """
        \\documentclass{article}
        \\newcommand{\\helperinput}[1]{\\input{macro_#1}}
        \\begin{document}
        \\section{Root}\\label{sec:root}
        Inline \\verb|\\input{verb_trap}| and \\lstinline{\\bibliography{lst_trap}}.
        {\\small \\input{tables/t1}}
        \\import{modA/}{a}
        \\bibliography{missing_refs}
        \\end{document}
        """.write(to: tempDir.appendingPathComponent("paper.tex"), atomically: true, encoding: .utf8)

        try """
        \\begin{tabular}{c}x\\end{tabular}\\label{tab:t1}
        """.write(to: tblDir.appendingPathComponent("t1.tex"), atomically: true, encoding: .utf8)

        // Inside `modA/a.tex`, `\subimport{nested/}{leaf}` resolves relative to `modA/`,
        // while `\import{modB/}{b}` resets relative to root (`tempDir/modB/b.tex`).
        try """
        \\subsection{Module A}\\label{sec:modA}
        \\subimport{nested/}{leaf}
        \\import{modB/}{b}
        """.write(to: tempDir.appendingPathComponent("modA/a.tex"), atomically: true, encoding: .utf8)

        try """
        \\subsubsection{Leaf}\\label{sec:leaf}
        """.write(to: modADir.appendingPathComponent("leaf.tex"), atomically: true, encoding: .utf8)

        try """
        \\subsection{Module B}\\label{sec:modB}
        """.write(to: modBDir.appendingPathComponent("b.tex"), atomically: true, encoding: .utf8)

        try """
        \\begin{thebibliography}{1}
        \\bibitem{k1} Entry one.
        \\end{thebibliography}
        """.write(to: tempDir.appendingPathComponent("paper.bbl"), atomically: true, encoding: .utf8)

        let service = try ScholarLSPWorkspaceService.loadManuscript(
            atPath: tempDir.appendingPathComponent("paper.tex").path
        )
        let ast = service.currentWorkspaceAST
        #expect(ast.includeGraph.documentReadingOrder == [
            "paper.tex",
            "tables/t1.tex",
            "modA/a.tex",
            "modA/nested/leaf.tex",
            "modB/b.tex"
        ])
        #expect(Set(ast.symbolTable.labelsByKey.keys) == ["sec:root", "tab:t1", "sec:modA", "sec:leaf", "sec:modB"])
        #expect(service.fallbackBBLFiles["paper.bbl"]?.contains("\\bibitem{k1}") == true)

        let diags = service.diagnostics()
        #expect(diags.filter { $0.code == "INC002" }.isEmpty, "Unexpected INC002: \(diags)")
        #expect(diags.filter { $0.code == "BIB_FROM_BBL" }.count == 1)
    }
}
