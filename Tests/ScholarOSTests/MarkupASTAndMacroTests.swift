import Foundation
import Testing
import ScholarModels
import ScholarMarkupAST

@Suite("Markup AST, Incremental Lexer, Macro Engine & Readability Metrics")
struct MarkupASTAndMacroTests {

    @Test("Manuscript format detection and TextPosition comparable ordering")
    func manuscriptFormatDetectionAndTextSpanOrdering() {
        #expect(ManuscriptFormat.detect(fromPath: "chapters/intro.tex") == .latex)
        #expect(ManuscriptFormat.detect(fromPath: "paper/main.typ") == .typst)
        #expect(ManuscriptFormat.detect(fromPath: "notes/review.md") == .markdown)
        #expect(ManuscriptFormat.detect(fromPath: "notes/README.markdown") == .markdown)

        let start = TextPosition.startOfFile
        let sameLineLater = TextPosition(line: 1, column: 14, utf8Offset: 13)
        let nextLine = TextPosition(line: 2, column: 1, utf8Offset: 28)

        #expect(start < sameLineLater)
        #expect(sameLineLater < nextLine)
        let span = TextSpan(filePath: "main.tex", start: start, end: nextLine)
        #expect(span.filePath == "main.tex")
        #expect(span.start.line == 1)
        #expect(span.end.line == 2)
    }

    @Test("LineByteIndex multibyte UTF-8 offset, line, and column round-trips")
    func lineByteIndexMultibyteUTF8RoundTrip() {
        let source = """
        \\section{Gradients ∇f and α-Bounds}
        Schrödinger & Gödel studied $\\ell_2$ norms.
        Final line.
        """
        let index = LineByteIndex(source: source)
        #expect(index.lineCount == 3)
        #expect(index.totalUTF8Bytes == source.utf8.count)

        let line2Start = index.startUTF8Offset(ofLine: 2)
        let posAtLine2Start = index.position(forUTF8Offset: line2Start, in: source)
        #expect(posAtLine2Start.line == 2)
        #expect(posAtLine2Start.column == 1)

        // Verify round-trip at column after multibyte characters ("Schrödinger ")
        let computedOffset = index.utf8Offset(forLine: 2, column: 13, in: source)
        let roundTripPos = index.position(forUTF8Offset: computedOffset, in: source)
        #expect(roundTripPos.line == 2)
        #expect(roundTripPos.column == 13)

        let spannedLines = index.lineRange(forUTF8Range: line2Start..<(index.startUTF8Offset(ofLine: 3) + 5))
        #expect(spannedLines == 2...3)
    }

    @Test("Lossless LaTeX CST tokenization reconstructs original source byte-for-byte")
    func latexLosslessTokenizationPreservesExactSource() {
        let source = """
        \\documentclass[11pt]{article}
        % Header comment with 100\\% precision
        \\begin{document}
        \\section{Introduction}\\label{sec:intro}
        We cite \\citet[p.~12]{vaswani2017} for $d_{\\text{model}} = 512$ and $$E = mc^2$$.
        \\end{document}
        """
        let lexer = IncrementalMarkupLexer(configuration: .losslessCST)
        let tokens = lexer.tokenize(source: source, format: .latex, filePath: "main.tex")

        #expect(tokens.last?.kind == .eof)
        let reconstructed = tokens.filter { $0.kind != .eof }.map(\.lexeme).joined()
        #expect(reconstructed == source)

        #expect(LaTeXCommandRole.classify("\\documentclass") == .documentClass)
        #expect(LaTeXCommandRole.classify("\\section") == .sectioning)
        #expect(LaTeXCommandRole.classify("\\appendix") == .appendixSwitch)
        #expect(LaTeXCommandRole.classify("\\citet") == .citation)
        #expect(LaTeXCommandRole.classify("\\eqref") == .crossReference)
        #expect(LaTeXCommandRole.classify("\\newcommand") == .macroDefinition)
    }

    @Test("Typst tokenization and directive role classification")
    func typstTokenizationAndDirectiveClassification() {
        let typstSource = """
        #set page(paper: "us-letter")
        #let kl(p, q) = $D_("KL")(#p || #q)$
        = Methodology <sec:method>
        // Line comment in Typst
        We build on @vaswani2017 and #cite(<dao2022>) via #include "appendix.typ".
        """
        let lexer = IncrementalMarkupLexer(configuration: .losslessCST)
        let tokens = lexer.tokenize(source: typstSource, format: .typst, filePath: "paper.typ")

        let reconstructed = tokens.filter { $0.kind != .eof }.map(\.lexeme).joined()
        #expect(reconstructed == typstSource)
        #expect(tokens.contains { $0.kind == .typstHashKeyword && $0.lexeme == "#set" })
        #expect(tokens.contains { $0.kind == .typstHashKeyword && $0.lexeme == "#let" })
        #expect(tokens.contains { $0.kind == .headingMarker })
        #expect(tokens.contains { $0.kind == .comment && $0.lexeme.contains("Line comment") })

        #expect(TypstDirectiveRole.classify("#set") == .setRule)
        #expect(TypstDirectiveRole.classify("#let") == .letBinding)
        #expect(TypstDirectiveRole.classify("#include") == .includeFile)
        #expect(TypstDirectiveRole.classify("#cite") == .citeCall)
        #expect(TypstDirectiveRole.classify("@vaswani2017") == .shorthandReference)
    }

    @Test("Compact semantic lexer omits whitespace and custom config omits comments while preserving token spans")
    func compactSemanticLexerStripsCommentsAndWhitespace() {
        let source = """
        % Leading comment
        \\section{Method}   % Trailing comment
        \\cite{dao2022}
        """
        let compactLexer = IncrementalMarkupLexer(configuration: .compactSemantic)
        let compactTokens = compactLexer.tokenize(source: source, format: .latex, filePath: "method.tex")
        #expect(!compactTokens.contains { $0.kind == .whitespace })

        let strippedLexer = IncrementalMarkupLexer(
            configuration: LexerConfiguration(includeWhitespaceTokens: false, includeCommentTokens: false)
        )
        let tokens = strippedLexer.tokenize(source: source, format: .latex, filePath: "method.tex")

        #expect(!tokens.contains { $0.kind == .whitespace })
        #expect(!tokens.contains { $0.kind == .comment })
        let secToken = tokens.first { $0.kind == .command && $0.lexeme == "\\section" }
        #expect(secToken?.span.start.line == 2)
        #expect(secToken?.span.start.column == 1)
    }

    @Test("Incremental line-dirty re-lexing reuses prefix/suffix tokens and equals full lex")
    func incrementalRelexSingleLineEditMatchesFullLexAndReusesPrefixSuffix() throws {
        var lines: [String] = ["\\documentclass{article}", "\\begin{document}"]
        for idx in 1...18 {
            lines.append("\\section{Section \(idx)}\\label{sec:s\(idx)}")
            lines.append("Paragraph \(idx) discusses convergence bounds \\cite{ref\(idx)} with $\\alpha_{\(idx)} > 0$.")
        }
        lines.append("\\end{document}")
        let original = lines.joined(separator: "\n")

        let lexer = IncrementalMarkupLexer(configuration: .losslessCST)
        let previousTokens = lexer.tokenize(source: original, format: .latex, filePath: "main.tex")

        let needle = "convergence bounds \\cite{ref9}"
        let rangeInString = try #require(original.range(of: needle))
        let startByte = original.utf8.distance(from: original.utf8.startIndex, to: rangeInString.lowerBound.samePosition(in: original.utf8)!)
        let endByte = original.utf8.distance(from: original.utf8.startIndex, to: rangeInString.upperBound.samePosition(in: original.utf8)!)

        let replacement = "tight minimax rates \\citep{ref9,vaswani2017}"
        var updated = original
        updated.replaceSubrange(rangeInString, with: replacement)

        let relexResult = lexer.relexEditDetailed(
            previousTokens: previousTokens,
            previousSourceLengthUTF8: original.utf8.count,
            updatedSource: updated,
            editByteRange: startByte..<endByte,
            filePath: "main.tex",
            format: .latex
        )
        let fullTokens = lexer.tokenize(source: updated, format: .latex, filePath: "main.tex")

        #expect(!relexResult.metrics.fellBackToFullLex)
        #expect(relexResult.metrics.reusedPrefixTokenCount > 20)
        #expect(relexResult.metrics.reusedSuffixTokenCount > 20)
        #expect(relexResult.metrics.lineDelta == 0)
        #expect(relexResult.tokens == fullTokens)
    }

    @Test("Incremental re-lexing across multi-line insertion and multi-line deletion matches full lex")
    func incrementalRelexMultiLineInsertionAndDeletionEquivalence() throws {
        let baseLines = (1...14).map { i in
            "Line \(i): Theorem \(i) establishes $\\beta_{\(i)} \\le 1/\\sqrt{n}$ in \\ref{thm:\(i)}."
        }
        let original = baseLines.joined(separator: "\n")
        let lexer = IncrementalMarkupLexer(configuration: .losslessCST)
        let tokens0 = lexer.tokenize(source: original, format: .latex, filePath: "proofs.tex")

        // 1. Multi-line insertion (+3 lines)
        let targetLine = "Line 7: Theorem 7 establishes $\\beta_{7} \\le 1/\\sqrt{n}$ in \\ref{thm:7}."
        let insRange = try #require(original.range(of: targetLine))
        let insStart = original.utf8.distance(from: original.utf8.startIndex, to: insRange.lowerBound.samePosition(in: original.utf8)!)
        let insEnd = original.utf8.distance(from: original.utf8.startIndex, to: insRange.upperBound.samePosition(in: original.utf8)!)

        let insertedBlock = """
        Line 7a: Begin multi-line proof block.
        \\begin{equation}\\label{eq:inserted}
        \\mathcal{L}(\\theta) = \\sum_{i=1}^{N} \\ell_i(\\theta)
        \\end{equation}
        """
        var afterInsert = original
        afterInsert.replaceSubrange(insRange, with: insertedBlock)

        let relexInsert = lexer.relexEditDetailed(
            previousTokens: tokens0,
            previousSourceLengthUTF8: original.utf8.count,
            updatedSource: afterInsert,
            editByteRange: insStart..<insEnd,
            filePath: "proofs.tex",
            format: .latex
        )
        let expectedAfterInsert = lexer.tokenize(source: afterInsert, format: .latex, filePath: "proofs.tex")
        #expect(relexInsert.metrics.lineDelta == 3)
        #expect(relexInsert.tokens == expectedAfterInsert)

        // 2. Multi-line deletion (-3 lines)
        let delRange = try #require(afterInsert.range(of: insertedBlock))
        let delStart = afterInsert.utf8.distance(from: afterInsert.utf8.startIndex, to: delRange.lowerBound.samePosition(in: afterInsert.utf8)!)
        let delEnd = afterInsert.utf8.distance(from: afterInsert.utf8.startIndex, to: delRange.upperBound.samePosition(in: afterInsert.utf8)!)

        var afterDelete = afterInsert
        afterDelete.replaceSubrange(delRange, with: targetLine)

        let relexDelete = lexer.relexEditDetailed(
            previousTokens: relexInsert.tokens,
            previousSourceLengthUTF8: afterInsert.utf8.count,
            updatedSource: afterDelete,
            editByteRange: delStart..<delEnd,
            filePath: "proofs.tex",
            format: .latex
        )
        #expect(relexDelete.metrics.lineDelta == -3)
        #expect(relexDelete.tokens == tokens0)
    }

    @Test("CST parser extracts sections, environments, pre/postnote citations, labels, and innermost cursor node")
    func cstParserBuildsStructuredLaTeXHierarchyAndCursorHitTest() {
        let latex = """
        \\documentclass{article}
        \\newcommand{\\R}{\\mathbb{R}}
        \\begin{document}
        \\section{Attention Architecture}\\label{sec:arch}
        Following \\citep[see][pp.~4--7]{vaswani2017,dao2022}, we optimize \\eqref{eq:attn}.
        \\begin{equation}\\label{eq:attn}
        \\mathrm{Attention}(Q, K, V) = \\mathrm{softmax}(QK^\\top / \\sqrt{d_k})V
        \\end{equation}
        \\begin{figure}[t]
        \\caption{Throughput scaling across sequence lengths.}
        \\label{fig:scaling}
        \\end{figure}
        \\end{document}
        """
        let parser = HandwrittenMarkupCSTParser()
        let result = parser.parse(source: latex, filePath: "main.tex", format: .latex)

        #expect(!result.hasSyntaxErrors)
        #expect(result.root.allSections.count == 1)
        #expect(result.root.allMacroDefinitions.count == 1)
        #expect(result.root.allCitations.count == 1)
        #expect(result.root.allCrossReferences.count == 1)
        #expect(result.root.allEnvironments.contains {
            if case .environment(let name, let label, let caption) = $0.kind {
                return name == "figure" && label == "fig:scaling" && (caption?.contains("Throughput scaling") == true)
            }
            return false
        })

        if let citeNode = result.root.allCitations.first,
           case .citation(let command, let keys, let prenote, let postnote) = citeNode.kind {
            #expect(command.contains("citep"))
            #expect(keys == ["vaswani2017", "dao2022"])
            #expect(prenote == "see")
            #expect(postnote?.contains("4--7") == true)
        } else {
            Issue.record("Expected parsed \\citep node with prenote and postnote")
        }

        let hitNode = result.root.innermostNode(atLine: 5, column: 22)
        #expect(hitNode != nil)
    }

    @Test("Error-recovering CST parser handles unclosed braces and missing end-document without aborting")
    func cstParserRecoversFromUnclosedBraceAndMissingEndDocument() {
        let broken = """
        \\documentclass{article}
        \\begin{document}
        \\section{Broken Header
        We still parse citations \\cite{vaswani2017} on the subsequent line with \\textbf{unclosed bold
        \\subsection{Recovered Subsection}\\label{sec:recovered}
        Valid trailing paragraph.
        """
        let parser = HandwrittenMarkupCSTParser()
        let result = parser.parse(source: broken, filePath: "broken.tex", format: .latex)

        #expect(result.hasSyntaxErrors)
        let codes = Set(result.issues.map(\.code))
        #expect(codes.contains(.unclosedBrace) || codes.contains(.malformedSectionCommand))
        #expect(codes.contains(.missingEndDocument))
        // Despite syntax errors on earlier lines, recovery must still parse the subsequent subsection and citation!
        #expect(result.root.allCitations.count == 1)
        #expect(result.root.allSections.contains {
            if case .section(_, let title, _) = $0.kind {
                return title.contains("Recovered Subsection")
            }
            return false
        })
        #expect(!result.lspDiagnostics.isEmpty)
    }

    @Test("Error-recovering CST parser diagnoses mismatched environments, orphan end tags, and unclosed inline math")
    func cstParserRecoversFromMismatchedAndOrphanEnvironments() {
        let mismatched = """
        \\begin{document}
        \\section{Mismatched Environments}
        \\begin{align}
        x + y = z
        \\end{itemize}
        \\end{figure}
        Broken math $a + b
        \\section{After Recovery}
        Still recovers \\cite{dao2022}.
        \\end{document}
        """
        let parser = HandwrittenMarkupCSTParser()
        let result = parser.parse(source: mismatched, filePath: "mismatch.tex", format: .latex)

        #expect(result.hasSyntaxErrors)
        let codes = Set(result.issues.map(\.code))
        #expect(codes.contains(.mismatchedEnvironmentEnd) || codes.contains(.missingEnvironmentEnd))
        #expect(codes.contains(.orphanEnvironmentEnd))
        #expect(codes.contains(.unclosedInlineMath))
        #expect(result.root.allCitations.count == 1)
        #expect(result.root.allSections.count == 2)
    }

    @Test("CST parser supports Typst headings, labels, citations, macros, and file includes")
    func cstParserTypstHeadingsCitationsLabelsAndIncludes() {
        let typst = """
        #let norm2(x) = $||#x||_2$
        = Introduction <sec:intro>
        Prior Transformers @vaswani2017 and IO-aware kernels #cite(<dao2022>) scale well; see @sec:intro.
        #include "experiments.typ"
        == Ablation Study <sec:ablation>
        Inline math $alpha + beta = 1$ holds.
        """
        let parser = HandwrittenMarkupCSTParser()
        let result = parser.parse(source: typst, filePath: "main.typ", format: .typst)

        #expect(result.format == .typst)
        #expect(result.root.allSections.count == 2)
        #expect(result.root.allCitations.count >= 2)
        #expect(result.root.allFileIncludes.count == 1)
        #expect(result.root.allMacroDefinitions.count == 1)
    }

    @Test("MacroExpansionEngine extracts LaTeX macro forms and expands optional + positional arguments")
    func macroExtractionAndPositionalOptionalExpansion() {
        let preamble = """
        \\newcommand{\\norm}[2][\\ell_2]{\\left\\|#2\\right\\|_{#1}}
        \\providecommand{\\kl}[2]{D_{\\mathrm{KL}}(#1 \\parallel #2)}
        \\DeclareMathOperator*{\\argmin}{arg\\,min}
        \\def\\eps{\\varepsilon}
        """
        let parser = HandwrittenMarkupCSTParser()
        let parseResult = parser.parse(source: preamble, filePath: "macros.tex", format: .latex)
        let engine = MacroExpansionEngine()

        let defs = engine.extractMacroDefinitions(from: parseResult)
        #expect(defs.count == 4)

        let table = engine.buildSymbolTable(from: parseResult)
        let defaultExpansion = engine.expand(
            text: "\\argmin_{\\theta} \\norm{W x} + \\eps \\kl{p}{q}",
            using: table,
            format: .latex
        )
        #expect(defaultExpansion.issues.isEmpty)
        #expect(defaultExpansion.expandedSource.contains("\\left\\|W x\\right\\|_{\\ell_2}"))
        #expect(defaultExpansion.expandedSource.contains("D_{\\mathrm{KL}}(p \\parallel q)"))
        #expect(defaultExpansion.expandedSource.contains("\\varepsilon"))

        let overrideExpansion = engine.expand(
            text: "\\norm[\\infty]{z_t}",
            using: table,
            format: .latex
        )
        #expect(overrideExpansion.expandedSource == "\\left\\|z_t\\right\\|_{\\infty}")
    }

    @Test("MacroExpansionEngine detects direct and mutual macro recursion cycles without hanging")
    func macroDirectAndMutualCycleGuardPreventsInfiniteLoop() {
        let cyclicSource = """
        \\newcommand{\\selfLoop}{1 + \\selfLoop}
        \\newcommand{\\ping}[1]{\\pong{#1}}
        \\newcommand{\\pong}[1]{\\ping{#1}}
        """
        let parseResult = HandwrittenMarkupCSTParser().parse(source: cyclicSource, filePath: "cycles.tex", format: .latex)
        let engine = MacroExpansionEngine()
        let symbolTable = engine.buildSymbolTable(from: parseResult)

        #expect(symbolTable.macroDependencyCycles.count >= 2)
        let diags = symbolTable.symbolDiagnostics()
        #expect(diags.contains { $0.code == "SYM001" })

        let resSelf = engine.expand(text: "$\\selfLoop$", using: symbolTable, format: .latex)
        #expect(resSelf.issues.contains { $0.kind == .recursiveMacroCycle })

        let resMutual = engine.expand(text: "$\\ping{x}$", using: symbolTable, format: .latex)
        #expect(resMutual.issues.contains { $0.kind == .recursiveMacroCycle })
    }

    @Test("MacroExpansionEngine enforces maxExpansionDepth and output byte safety limits")
    func macroDepthLimitAndOutputBudgetSafetyTruncation() {
        let chainSource = """
        \\newcommand{\\mA}{\\mB + 1}
        \\newcommand{\\mB}{\\mC + 1}
        \\newcommand{\\mC}{\\mD + 1}
        \\newcommand{\\mD}{\\mE + 1}
        \\newcommand{\\mE}{\\mF + 1}
        \\newcommand{\\mF}{x_0}
        """
        let parsed = HandwrittenMarkupCSTParser().parse(source: chainSource, filePath: "chain.tex", format: .latex)
        let tightEngine = MacroExpansionEngine(maxExpansionDepth: 3, maxExpandedOutputBytes: 1024)
        let table = tightEngine.buildSymbolTable(from: parsed)

        let depthLimited = tightEngine.expand(text: "\\mA", using: table, format: .latex)
        #expect(depthLimited.wasTruncatedBySafetyLimit)
        #expect(depthLimited.issues.contains { $0.kind == .maxExpansionDepthExceeded })
    }

    @Test("Typst #let macro expansion and Unicode math formula preview rendering")
    func typstLetFunctionExpansionAndUnicodeMathPreview() {
        let typst = """
        #let inner(u, v) = $angle.l #u, #v angle.r$
        $ inner(x_i, y_i) $
        """
        let parser = HandwrittenMarkupCSTParser()
        let engine = MacroExpansionEngine()
        let typstParsed = parser.parse(source: typst, filePath: "math.typ", format: .typst)
        let typstTable = engine.buildSymbolTable(from: typstParsed)
        let expandedTypst = engine.expand(text: "#inner(a, b)", using: typstTable, format: .typst)
        #expect(expandedTypst.expandedSource.contains("a"))
        #expect(expandedTypst.expandedSource.contains("b"))

        let latexMathDoc = """
        \\newcommand{\\expect}{\\mathbb{E}}
        \\begin{equation}\\label{eq:bound}
        \\expect[\\alpha + \\beta] \\le \\sum_{i=1}^{n} x_i \\in \\mathbb{R}
        \\end{equation}
        """
        let latexParsed = parser.parse(source: latexMathDoc, filePath: "bound.tex", format: .latex)
        let latexTable = engine.buildSymbolTable(from: latexParsed)
        let previews = engine.previewAllMathExpressions(in: latexParsed.root, using: latexTable, format: .latex)
        #expect(!previews.isEmpty)
        let firstPreview = previews[0]
        #expect(firstPreview.expandedFormula.contains("\\mathbb{E}"))
        #expect(firstPreview.unicodeApproximation.contains("∑") || firstPreview.unicodeApproximation.contains("α"))
    }

    @Test("ManuscriptSymbolTable detects duplicate labels, unresolved cross-references, and label categories")
    func symbolTableDuplicateLabelsAndUnresolvedCrossRefs() {
        let source = """
        \\section{Theory}\\label{sec:theory}
        \\begin{equation}\\label{eq:dup}
        a = b
        \\end{equation}
        \\begin{equation}\\label{eq:dup}
        c = d
        \\end{equation}
        As shown in \\ref{sec:theory}, \\eqref{eq:dup}, and \\ref{thm:nonexistent}.
        """
        let parsed = HandwrittenMarkupCSTParser().parse(source: source, filePath: "theory.tex", format: .latex)
        let table = MacroExpansionEngine().buildSymbolTable(from: parsed)

        #expect(table.duplicateLabels.count == 1)
        #expect(table.duplicateLabels.first?.key == "eq:dup")
        #expect(table.unresolvedCrossReferences.count == 1)
        #expect(table.unresolvedCrossReferences.first?.targetKey == "thm:nonexistent")

        #expect(LabelCategory.infer(fromKey: "fig:overview") == .figure)
        #expect(LabelCategory.infer(fromKey: "tab:ablation") == .table)
        #expect(LabelCategory.infer(fromKey: "eq:loss") == .equation)
        #expect(LabelCategory.infer(fromKey: "thm:main") == .theorem)

        let diags = table.symbolDiagnostics()
        #expect(diags.contains { $0.code == "SYM003" })
        #expect(diags.contains { $0.code == "SYM004" })
    }

    @Test("MultiFileIncludeGraphResolver resolves nested \\input/\\include DAG and topological compilation order")
    func multiFileIncludeDAGReadingAndTopologicalOrder() {
        let files: [String: String] = [
            "main.tex": """
            \\documentclass{article}
            \\input{macros}
            \\begin{document}
            \\input{sections/intro}
            \\include{sections/methods}
            \\addbibresource{references.bib}
            \\end{document}
            """,
            "macros.tex": "\\newcommand{\\loss}{\\mathcal{L}}",
            "sections/intro.tex": "\\section{Introduction}\\label{sec:intro}\nMotivated by \\cite{vaswani2017}.",
            "sections/methods.tex": "\\section{Methods}\\label{sec:methods}\n\\input{sections/lemma}\nUsing $\\loss$ from \\ref{sec:intro}.",
            "sections/lemma.tex": "\\subsection{Key Lemma}\\label{sec:lemma}\nProof details.",
            "references.bib": "@inproceedings{vaswani2017, title={Attention Is All You Need}, year={2017}}"
        ]

        let resolver = MultiFileIncludeGraphResolver()
        let workspace = resolver.resolveWorkspace(rootFilePath: "main.tex", files: files)

        #expect(!workspace.includeGraph.hasCycles)
        #expect(workspace.includeGraph.missingFiles.isEmpty)
        #expect(workspace.includeGraph.edges.contains { $0.isBibliographyResource && $0.resolvedTargetFile == "references.bib" })
        #expect(workspace.includeGraph.documentReadingOrder == [
            "main.tex",
            "macros.tex",
            "sections/intro.tex",
            "sections/methods.tex",
            "sections/lemma.tex"
        ])

        // Leaf dependencies must precede their parent in topological compilation order
        let topo = workspace.includeGraph.topologicalCompilationOrder
        let lemmaIdx = topo.firstIndex(of: "sections/lemma.tex") ?? -1
        let methodsIdx = topo.firstIndex(of: "sections/methods.tex") ?? -1
        let mainIdx = topo.firstIndex(of: "main.tex") ?? -1
        #expect(lemmaIdx < methodsIdx)
        #expect(methodsIdx < mainIdx)
        #expect(workspace.symbolTable.labelsByKey["sec:lemma"] != nil)
        #expect(workspace.symbolTable.unresolvedCrossReferences.isEmpty)
    }

    @Test("MultiFileIncludeGraphResolver detects circular \\input cycles via Tarjan SCC and missing files")
    func multiFileCircularIncludeTarjanSCCAndMissingFileDiagnostics() {
        let cyclicFiles: [String: String] = [
            "main.tex": "\\input{chapA}\n\\input{missing_chapter}",
            "chapA.tex": "\\section{A}\n\\input{chapB}",
            "chapB.tex": "\\section{B}\n\\input{chapC}",
            "chapC.tex": "\\section{C}\n\\input{chapA}"
        ]

        let resolver = MultiFileIncludeGraphResolver()
        let workspace = resolver.resolveWorkspace(rootFilePath: "main.tex", files: cyclicFiles)

        #expect(workspace.includeGraph.hasCycles)
        #expect(!workspace.includeGraph.stronglyConnectedCycles.isEmpty)
        #expect(workspace.includeGraph.missingFiles.contains("missing_chapter.tex"))
        #expect(workspace.diagnostics.contains { $0.code == "INC001" })
        #expect(workspace.diagnostics.contains { $0.code == "INC002" })
    }

    @Test("Multi-file outline numbering switches to Appendix A, A.1 and supports disk + unsaved buffer overlay")
    func multiFileNumberedOutlineWithAppendixLetters() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-include-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mainDisk = """
        \\begin{document}
        \\section{Introduction}
        Ten words of introductory context establish the research question clearly.
        \\subsection{Problem Formulation}
        Five words of problem setup.
        \\section{Experiments}
        Empirical benchmarks run here.
        \\appendix
        \\input{appendix_proofs}
        \\end{document}
        """
        let appendixDisk = """
        \\section{Deferred Proofs}
        Detailed derivations on disk.
        """
        try mainDisk.write(to: tempDir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try appendixDisk.write(to: tempDir.appendingPathComponent("appendix_proofs.tex"), atomically: true, encoding: .utf8)

        let unsavedOverlay: [String: String] = [
            "appendix_proofs.tex": """
            \\section{Deferred Proofs}\\label{app:proofs}
            Updated unsaved proof text with additional words for verification.
            \\subsection{Concentration Inequality}\\label{app:conc}
            Sub-Gaussian tail bound derivation.
            """
        ]

        let resolver = MultiFileIncludeGraphResolver()
        let workspace = resolver.resolveFromDisk(
            rootFilePath: "main.tex",
            projectDirectory: tempDir.path,
            unsavedBuffers: unsavedOverlay
        )

        let prefixes = workspace.outline.map(\.numberPrefix)
        #expect(prefixes.count == 5)
        #expect(prefixes[0] == "1")
        #expect(prefixes[1] == "1.1")
        #expect(prefixes[2] == "2")
        #expect(prefixes[3].contains("A"))
        #expect(prefixes[4].contains("A.1"))
        #expect(workspace.symbolTable.labelsByKey["app:conc"] != nil)
    }

    @Test("AcademicManuscriptMetricsAnalyzer buckets words, computes Flesch/Gunning Fog readability, and evaluates venue caps")
    func manuscriptMetricsWordBucketsReadabilityAndVenueBudgets() {
        let manuscript = """
        \\documentclass{article}
        \\begin{document}
        \\begin{abstract}
        We introduce a deterministic citation firewall and incremental syntax engine for reproducible scientific writing.
        Our evaluation demonstrates substantial reductions in hallucinated bibliography entries across six benchmarks.
        \\end{abstract}
        \\section{Introduction}
        Empirical reproducibility requires accurate attribution \\cite{vaswani2017,dao2022}. Dr.~Smith et al.~investigated
        syntactic verification under strict latency budgets, achieving $O(\\log n)$ query complexity\\footnote{Measured on Apple Silicon hardware.}.
        Furthermore, interdisciplinary collaboration illuminates computational tradeoffs across large corpora \\cite{vaswani2017}.
        \\begin{equation}
        \\mathcal{R}(\\theta) = \\frac{1}{n} \\sum_{i=1}^{n} (y_i - f_\\theta(x_i))^2
        \\end{equation}
        \\begin{figure}[t]
        \\caption{Latency distribution across incremental edits.}
        \\label{fig:lat}
        \\end{figure}
        \\begin{lstlisting}
        let ignoredCode = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        \\end{lstlisting}
        \\appendix
        \\section{Supplementary Details}
        Appendix prose words are tracked separately from main body conference page limits.
        \\end{document}
        """

        let analyzer = AcademicManuscriptMetricsAnalyzer()
        let report = analyzer.analyze(
            source: manuscript,
            filePath: "main.tex",
            format: .latex,
            venues: [.neurips9Page, .natureArticle, .acl4PageShort]
        )

        #expect(report.abstractWordCount >= 20)
        #expect(report.bodyProseWordCount >= 25)
        #expect(report.appendixProseWordCount >= 10)
        #expect(report.captionWordCount >= 5)
        #expect(report.footnoteWordCount >= 4)
        #expect(report.inlineEquationCount == 1)
        #expect(report.displayEquationCount == 1)
        #expect(report.totalEquationCount == 2)
        #expect(report.figureCount == 1)
        #expect(report.totalCitationOccurrences == 3)
        #expect(report.uniqueCitedKeysCount == 2)
        #expect(report.citationDensityPerThousandWords > 0.0)

        // Readability telemetry checks
        #expect(report.readability.sentenceCount >= 2)
        #expect(report.readability.syllableCount > report.readability.wordCountAnalyzed)
        #expect(report.readability.fleschReadingEase.isFinite)
        #expect(report.readability.fleschKincaidGradeLevel > 5.0)
        #expect(report.readability.gunningFogIndex > 6.0)
        #expect(report.readability.colemanLiauIndex.isFinite)

        let neurips = report.estimate(for: .neurips9Page)
        #expect(neurips?.status == .withinBudget)
    }
}
