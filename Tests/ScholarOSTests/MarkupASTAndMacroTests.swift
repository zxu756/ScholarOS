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

    // MARK: - M2 Stage 03: Verbatim & Opaque Lexer Skipping + Lossless Round-Trips

    private var repositoryRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func assertOpaqueLosslessRoundTrip(
        _ source: String,
        filePath: String = "test.tex",
        expectOpaqueToken: Bool = true
    ) -> [MarkupToken] {
        let lexer = IncrementalMarkupLexer(configuration: .losslessCST)
        let tokens = lexer.tokenize(source: source, format: .latex, filePath: filePath)
        #expect(tokens.last?.kind == .eof)

        let coreTokens = tokens.filter { $0.kind != .eof }
        let reconstructed = coreTokens.map(\.lexeme).joined()
        #expect(Data(reconstructed.utf8) == Data(source.utf8), "Token concatenation must match original bytes")

        // Verify contiguous byte/position spans from 0 to source.utf8.count
        var expectedPos = TextPosition.startOfFile
        for tok in coreTokens {
            #expect(!tok.lexeme.isEmpty, "Non-EOF token must not have empty lexeme")
            #expect(tok.span.start == expectedPos, "Token span must be contiguous at \(tok)")
            expectedPos = tok.span.end
        }
        #expect(expectedPos.utf8Offset == source.utf8.count)
        #expect(tokens.last?.span.start == expectedPos)

        let hasOpaque = coreTokens.contains { $0.kind == .verbatim }
        if expectOpaqueToken {
            #expect(hasOpaque, "Expected opaque verbatim token for: \(source)")
        } else {
            #expect(!hasOpaque, "Did not expect opaque verbatim token for: \(source)")
        }
        return tokens
    }

    @Test("M2 Stage 03 item 1 (S7, S8, S73): lexer skips all 18 verbatim/comment/iffalse/url constructs as opaque tokens without extracting commands, comments, or braces, while keeping alltt normal")
    func m2Stage03Item1LexerOpaqueVerbatimSkippingAcrossAllConstructsAndAllttExclusion() {
        let skippedConstructs: [(label: String, snippet: String, expectedTrailingCite: String)] = [
            ("\\verb<c>...<c>", "Text \\verb+\\cite{fake} { %+ \\cite{k1}", "k1"),
            ("\\verb*<c>...<c>", "Text \\verb*|\\cite{fake} } %| \\cite{k1}", "k1"),
            ("\\lstinline<c>...<c>", "Text \\lstinline[language=C]|\\cite{fake} { %| \\cite{k1}", "k1"),
            ("\\lstinline{...}", "Text \\lstinline{if (a) { % \\cite{fake} \\cite{k1}", "k1"),
            ("\\mintinline{lang}{...}", "Text \\mintinline[breaklines]{python}{d = {\"k\": 1} # \\cite{fake} %} \\cite{k1}", "k1"),
            ("\\mintinline{lang}<c>...<c>", "Text \\mintinline{c}|\\cite{fake} { %| \\cite{k1}", "k1"),
            ("verbatim env", "\\begin{verbatim}\n\\cite{fake} { %\n\\end{verbatim}\n\\cite{k1}", "k1"),
            ("verbatim* env", "\\begin{verbatim*}\n\\cite{fake} } %\n\\end{verbatim*}\n\\cite{k1}", "k1"),
            ("Verbatim env", "\\begin{Verbatim}[numbers=left]\n\\cite{fake} { %\n\\end{Verbatim}\n\\cite{k1}", "k1"),
            ("BVerbatim env", "\\begin{BVerbatim}\n\\cite{fake} } %\n\\end{BVerbatim}\n\\cite{k1}", "k1"),
            ("lstlisting env", "\\begin{lstlisting}[language=Python]\n\\cite{fake} { %\n\\end{lstlisting}\n\\cite{k1}", "k1"),
            ("minted env", "\\begin{minted}[linenos]{python}\n\\cite{fake} { %\n\\end{minted}\n\\cite{k1}", "k1"),
            ("comment env", "\\begin{comment}\n\\cite{fake} { %\n\\end{comment}\n\\cite{k1}", "k1"),
            ("\\iffalse...\\fi nested", "\\iffalse \\cite{fake1} % \\fi\n \\iftrue \\cite{fake2} \\else \\cite{fake3} \\fi { \\fi \\cite{k1}", "k1"),
            ("\\url{...}", "See \\url{https://a.com/x%20y/{z}/\\cite{fake}%} \\cite{k1}", "k1"),
            ("\\path{...}", "See \\path{/a/%b/{c}/\\cite{fake}} \\cite{k1}", "k1"),
            ("\\nolinkurl{...}", "See \\nolinkurl{http://a.com/%7E/{x}/\\cite{fake}} \\cite{k1}", "k1"),
            ("\\href{...}{...}", "See \\href{http://a.com/%7E/{x}/\\cite{fake}%}{\\cite{k_anchor}} \\cite{k1}", "k1")
        ]

        let lexer = IncrementalMarkupLexer(configuration: .losslessCST)
        for item in skippedConstructs {
            let tokens = lexer.tokenize(source: item.snippet, format: .latex, filePath: "case.tex")
            let hasOpaque = tokens.contains { $0.kind == .verbatim }
            #expect(hasOpaque, "[\(item.label)] must emit opaque verbatim token")
            #expect(!tokens.contains { $0.kind == .comment }, "[\(item.label)] '%' inside opaque region must not emit .comment")
            #expect(!tokens.contains { $0.lexeme.contains("fake") && $0.kind != .eof && $0.kind != .verbatim }, "[\(item.label)] fake content must remain inside opaque token")
            let citeCmdCount = tokens.filter { $0.kind == .command && $0.lexeme == "\\cite" }.count
            let expectedCiteCmds = item.label == "\\href{...}{...}" ? 2 : 1
            #expect(citeCmdCount == expectedCiteCmds, "[\(item.label)] expected \(expectedCiteCmds) active \\cite command(s), got \(citeCmdCount)")
        }

        // `alltt` is explicitly NOT skipped: commands inside `alltt` take effect normally.
        let allttSource = "\\begin{alltt}\n\\cite{k_alltt} \\label{sec:alltt}\n\\end{alltt}"
        let allttTokens = assertOpaqueLosslessRoundTrip(allttSource, expectOpaqueToken: false)
        #expect(allttTokens.contains { $0.kind == .command && $0.lexeme == "\\cite" })
        #expect(allttTokens.contains { $0.kind == .command && $0.lexeme == "\\label" })

        // Macro definitions/aliases of `\url` or `\iffalse` (such as `.bbl` `\providecommand{\url}[1]{#1}`) must not misfire.
        let macroDefUrl = "\\providecommand{\\url}[1]{\\texttt{#1}}\n\\let\\myfalse\\iffalse\n\\cite{k_after_def}"
        let defTokens = assertOpaqueLosslessRoundTrip(macroDefUrl, expectOpaqueToken: false)
        #expect(defTokens.contains { $0.kind == .command && $0.lexeme == "\\cite" })
    }

    @Test("M2 Stage 03 item 2a: lossless byte-for-byte round-trip for \\verb<c>...<c>")
    func m2Stage03Item2LosslessRoundTripVerb() {
        _ = assertOpaqueLosslessRoundTrip("A \\verb+\\cite{fake} { % $ }+ B \\cite{k1}\n")
    }

    @Test("M2 Stage 03 item 2b: lossless byte-for-byte round-trip for \\verb*<c>...<c>")
    func m2Stage03Item2LosslessRoundTripVerbStar() {
        _ = assertOpaqueLosslessRoundTrip("A \\verb*|a b \\label{fake} { %| B\n")
    }

    @Test("M2 Stage 03 item 2c: lossless byte-for-byte round-trip for \\lstinline<c>...<c>")
    func m2Stage03Item2LosslessRoundTripLstinlineDelimited() {
        _ = assertOpaqueLosslessRoundTrip("Code \\lstinline[language=Python]!x = {1: '%'} \\cite{fake}! end.\n")
    }

    @Test("M2 Stage 03 item 2d: lossless byte-for-byte round-trip for \\lstinline{...}")
    func m2Stage03Item2LosslessRoundTripLstinlineBraced() {
        _ = assertOpaqueLosslessRoundTrip("Code \\lstinline[basicstyle=\\ttfamily]{for (i=0;i<n;i++) { /* % \\cite{fake} */ }} end.\n")
    }

    @Test("M2 Stage 03 item 2e: lossless byte-for-byte round-trip for \\mintinline{lang}{...}")
    func m2Stage03Item2LosslessRoundTripMintinlineBraced() {
        _ = assertOpaqueLosslessRoundTrip("Py \\mintinline[linenos]{python}{x = {'a': '%'} # \\cite{fake}} end.\n")
    }

    @Test("M2 Stage 03 item 2f: lossless byte-for-byte round-trip for \\mintinline{lang}<c>...<c>")
    func m2Stage03Item2LosslessRoundTripMintinlineDelimited() {
        _ = assertOpaqueLosslessRoundTrip("Rust \\mintinline{rust}|let s = \"{\"; // % \\cite{fake}| end.\n")
    }

    @Test("M2 Stage 03 item 2g: lossless byte-for-byte round-trip for verbatim environment")
    func m2Stage03Item2LosslessRoundTripEnvVerbatim() {
        _ = assertOpaqueLosslessRoundTrip("\\begin{verbatim}\r\n\\cite{fake} { % $\r\n\\end{verbatim}\r\n")
    }

    @Test("M2 Stage 03 item 2h: lossless byte-for-byte round-trip for verbatim* environment")
    func m2Stage03Item2LosslessRoundTripEnvVerbatimStar() {
        _ = assertOpaqueLosslessRoundTrip("\\begin{verbatim*}\nspaces   and { \\label{fake} %\n\\end{verbatim*}\n")
    }

    @Test("M2 Stage 03 item 2i: lossless byte-for-byte round-trip for Verbatim environment")
    func m2Stage03Item2LosslessRoundTripEnvFancyvrbVerbatim() {
        _ = assertOpaqueLosslessRoundTrip("\\begin{Verbatim}[fontsize=\\small]\n\\cite{fake} } %\n\\end{Verbatim}\n")
    }

    @Test("M2 Stage 03 item 2j: lossless byte-for-byte round-trip for BVerbatim environment")
    func m2Stage03Item2LosslessRoundTripEnvFancyvrbBVerbatim() {
        _ = assertOpaqueLosslessRoundTrip("\\begin{BVerbatim}[baseline=t]\n\\cite{fake} { %\n\\end{BVerbatim}\n")
    }

    @Test("M2 Stage 03 item 2k: lossless byte-for-byte round-trip for lstlisting environment")
    func m2Stage03Item2LosslessRoundTripEnvLstlisting() {
        _ = assertOpaqueLosslessRoundTrip("\\begin{lstlisting}[language=C]\nint main() { /* \\cite{fake} % */ return 0;\n\\end{lstlisting}\n")
    }

    @Test("M2 Stage 03 item 2l: lossless byte-for-byte round-trip for minted environment")
    func m2Stage03Item2LosslessRoundTripEnvMinted() {
        _ = assertOpaqueLosslessRoundTrip("\\begin{minted}[linenos]{python}\ndef g(): # \\cite{fake} { %\n    pass\n\\end{minted}\n")
    }

    @Test("M2 Stage 03 item 2m: lossless byte-for-byte round-trip for comment environment")
    func m2Stage03Item2LosslessRoundTripEnvComment() {
        _ = assertOpaqueLosslessRoundTrip("\\begin{comment}\nHidden \\section{Fake} { \\cite{fake} %\n\\end{comment}\n")
    }

    @Test("M2 Stage 03 item 2n: lossless byte-for-byte round-trip for \\iffalse...\\fi with nested \\if.../\\fi")
    func m2Stage03Item2LosslessRoundTripIffalse() {
        _ = assertOpaqueLosslessRoundTrip("\\iffalse\n\\ifnum1=1 \\cite{fake} \\else { \\fi\n% \\fi\n\\fi\nAfter.\n")
    }

    @Test("M2 Stage 03 item 2o: lossless byte-for-byte round-trip for \\url{...}")
    func m2Stage03Item2LosslessRoundTripUrl() {
        _ = assertOpaqueLosslessRoundTrip("URL \\url{https://example.com/a%20b/{x,y}/%} tail.\n")
    }

    @Test("M2 Stage 03 item 2p: lossless byte-for-byte round-trip for \\path{...}")
    func m2Stage03Item2LosslessRoundTripPath() {
        _ = assertOpaqueLosslessRoundTrip("Path \\path{/opt/%local/{bin}/a_b} tail.\n")
    }

    @Test("M2 Stage 03 item 2q: lossless byte-for-byte round-trip for \\nolinkurl{...}")
    func m2Stage03Item2LosslessRoundTripNolinkurl() {
        _ = assertOpaqueLosslessRoundTrip("Nolink \\nolinkurl{http://host/%7Euser/{v1}%} tail.\n")
    }

    @Test("M2 Stage 03 item 2r: lossless byte-for-byte round-trip for \\href{...}{...}")
    func m2Stage03Item2LosslessRoundTripHref() {
        _ = assertOpaqueLosslessRoundTrip("Href \\href{https://host/%7E/{id}%}{anchor \\textbf{text} \\cite{k1}} tail.\n")
    }

    @Test("M2 Stage 03 item 2s: lossless byte-for-byte round-trip on entire hard-inputs/hard.tex fixture")
    func m2Stage03Item2LosslessRoundTripHardTexFullFile() throws {
        let hardTexURL = repositoryRootURL.appendingPathComponent("Tests/Fixtures/manuscripts/hard-inputs/hard.tex")
        let rawData = try Data(contentsOf: hardTexURL)
        let source = try #require(String(data: rawData, encoding: .utf8))

        let tokens = assertOpaqueLosslessRoundTrip(source, filePath: "hard.tex", expectOpaqueToken: true)
        let reconstructedData = Data(tokens.filter { $0.kind != .eof }.map(\.lexeme).joined().utf8)
        #expect(reconstructedData == rawData)
    }

    @Test("M2 Stage 03 item 3: parser, symbol extractor, and LexerIncludeDirectiveScanner rely on opaque verbatim token")
    func m2Stage03Item3ParserSymbolExtractorAndIncludeScannerConsumeOpaqueToken() throws {
        // 3a. Parse `hard.tex` directly: exact citations {k1, k2, k3}, labels {sec:after, sec:url, sec:verb}, 0 fake*, 0 AST issues
        let hardTexURL = repositoryRootURL.appendingPathComponent("Tests/Fixtures/manuscripts/hard-inputs/hard.tex")
        let hardSource = try String(contentsOf: hardTexURL, encoding: .utf8)
        let parser = HandwrittenMarkupCSTParser()
        let parseResult = parser.parse(source: hardSource, filePath: "hard.tex", format: .latex)
        let symbolTable = MacroExpansionEngine().buildSymbolTable(from: parseResult)

        let citeKeys = Set(symbolTable.citationsByKey.keys)
        let labelKeys = Set(symbolTable.labelsByKey.keys)
        #expect(citeKeys == ["k1", "k2", "k3"], "got citeKeys=\(citeKeys)")
        #expect(labelKeys == ["sec:after", "sec:url", "sec:verb"], "got labelKeys=\(labelKeys)")
        #expect(citeKeys.filter { $0.hasPrefix("fake") }.isEmpty)
        #expect(labelKeys.filter { $0.hasPrefix("fake") }.isEmpty)
        #expect(parseResult.issues.isEmpty, "Expected 0 AST syntax issues on hard.tex, got \(parseResult.issues)")

        // 3b. Include & bibliography scanner ignores fake directives inside \iffalse, \lstinline{...}, \mintinline{...}{...}, \url, and \href URL arg, while still reading directives after '%' on the same line or in \href's second arg
        let files: [String: String] = [
            "main.tex": """
            \\documentclass{article}
            \\begin{document}
            \\iffalse
            \\input{ghost_iffalse}
            \\bibliography{ghost_bib_iffalse}
            \\fi
            \\lstinline{% \\input{ghost_lstbrace} \\input{real_one}
            \\mintinline{python}{\\input{ghost_mintbrace} %}
            \\url{https://example.org/\\input{ghost_url}%} \\input{real_two}
            \\href{https://example.org/\\bibliography{ghost_href}%}{See \\input{real_three}}
            \\end{document}
            """,
            "real_one.tex": "\\section{One}\\label{sec:one}",
            "real_two.tex": "\\section{Two}\\label{sec:two}",
            "real_three.tex": "\\section{Three}\\label{sec:three}"
        ]
        let resolver = MultiFileIncludeGraphResolver()
        let ws = resolver.resolveWorkspace(rootFilePath: "main.tex", files: files)
        #expect(ws.includeGraph.documentReadingOrder == ["main.tex", "real_one.tex", "real_two.tex", "real_three.tex"])
        #expect(ws.includeGraph.missingFiles.isEmpty, "Unexpected missing files: \(ws.includeGraph.missingFiles)")
        #expect(ws.diagnostics.filter { $0.code == "INC002" }.isEmpty, "Unexpected INC002: \(ws.diagnostics)")
    }

    @Test("M2 Stage 03: incremental re-lexing across multi-line verbatim and \\iffalse...\\fi edits matches full tokenization")
    func m2Stage03IncrementalRelexAcrossVerbatimAndConditionalBlocksEqualsFullLex() throws {
        let original = """
        \\documentclass{article}
        \\begin{document}
        \\section{Intro}\\label{sec:intro}
        \\begin{verbatim}
        \\cite{fake_v1} { %
        \\end{verbatim}
        \\iffalse
        \\cite{fake_if}
        \\fi
        Normal prose \\cite{k1}.
        \\end{document}
        """
        let lexer = IncrementalMarkupLexer(configuration: .losslessCST)
        let prevTokens = lexer.tokenize(source: original, format: .latex, filePath: "doc.tex")

        let needle = "\\cite{fake_v1} { %"
        let range = try #require(original.range(of: needle))
        let startByte = original.utf8.distance(from: original.utf8.startIndex, to: range.lowerBound.samePosition(in: original.utf8)!)
        let endByte = original.utf8.distance(from: original.utf8.startIndex, to: range.upperBound.samePosition(in: original.utf8)!)

        var updated = original
        updated.replaceSubrange(range, with: "\\cite{fake_v2}\nsecond line } %")

        let relexed = lexer.relexEditDetailed(
            previousTokens: prevTokens,
            previousSourceLengthUTF8: original.utf8.count,
            updatedSource: updated,
            editByteRange: startByte..<endByte,
            filePath: "doc.tex",
            format: .latex
        )
        let full = lexer.tokenize(source: updated, format: .latex, filePath: "doc.tex")
        #expect(relexed.tokens == full)
    }

    @Test("M2 Stage 03b: \\lstinline{...} stops at first '}' without brace nesting while keeping '%' literal, lossless round-trip, \\lstinline<c>...<c> and \\mintinline{lang}{...} unchanged")
    func m2Stage03bLstinlineBracedStopsAtFirstClosingBraceWithoutNesting() {
        // 1. Exact prompt case: `\lstinline{a{b}c} \cite{k}`
        //    Opaque braced construct is `\lstinline{a{b}` (`.verbatim` payload `"a{b"`),
        //    followed by `c}` entering normal prose and `\cite{k}` extracted; lossless holds.
        let src1 = "\\lstinline{a{b}c} \\cite{k}"
        let tokens1 = assertOpaqueLosslessRoundTrip(src1, filePath: "lstbrace1.tex", expectOpaqueToken: true)
        let core1 = tokens1.filter { $0.kind != .eof }

        #expect(core1.count >= 6, "Expected separate tokens after first '}', got \(core1)")
        if core1.count >= 6 {
            #expect(core1[0].kind == .command && core1[0].lexeme == "\\lstinline")
            #expect(core1[1].kind == .leftBrace && core1[1].lexeme == "{")
            #expect(core1[2].kind == .verbatim && core1[2].lexeme == "a{b")
            #expect(core1[3].kind == .rightBrace && core1[3].lexeme == "}")
            #expect(core1[0...3].map(\.lexeme).joined() == "\\lstinline{a{b}")
            #expect(core1[4].kind == .textWord && core1[4].lexeme == "c")
            #expect(core1[5].kind == .rightBrace && core1[5].lexeme == "}")
        }

        let parser = HandwrittenMarkupCSTParser()
        let parsed1 = parser.parse(source: src1, filePath: "lstbrace1.tex", format: .latex)
        let sym1 = MacroExpansionEngine().buildSymbolTable(from: parsed1)
        #expect(Set(sym1.citationsByKey.keys) == ["k"])
        #expect(parsed1.issues.contains { $0.code == .unexpectedClosingBrace }, "Trailing '}' in 'c}' must enter normal prose and report unexpectedClosingBrace")

        // 2. Valid LaTeX `\lstinline[language=C]{if (ok) { % \cite{fake_lst} \cite{k1}`:
        //    `{` and `%` and unclosed `\cite{fake_lst` inside stop at the first `}`,
        //    0 comment tokens, 0 AST issues, and `\cite{k1}` after the first `}` is extracted.
        let src2 = "Code \\lstinline[language=C]{if (ok) { % \\cite{fake_lst} \\cite{k1}."
        let tokens2 = assertOpaqueLosslessRoundTrip(src2, filePath: "lstbrace2.tex", expectOpaqueToken: true)
        #expect(!tokens2.contains { $0.kind == .comment })
        let verbatimTok2 = tokens2.first { $0.kind == .verbatim }
        #expect(verbatimTok2?.lexeme == "if (ok) { % \\cite{fake_lst")
        let parsed2 = parser.parse(source: src2, filePath: "lstbrace2.tex", format: .latex)
        let sym2 = MacroExpansionEngine().buildSymbolTable(from: parsed2)
        #expect(Set(sym2.citationsByKey.keys) == ["k1"])
        #expect(parsed2.issues.isEmpty, "Expected 0 AST issues on valid LaTeX \\lstinline{...}, got \(parsed2.issues)")

        // 3. `\lstinline<c>...<c>` and `\mintinline{lang}{...}` remain unchanged.
        let srcDelim = "\\lstinline|a{b}c % \\cite{fake}| \\cite{k}"
        let tokDelim = assertOpaqueLosslessRoundTrip(srcDelim, filePath: "lstdelim.tex", expectOpaqueToken: true)
        #expect(tokDelim.first { $0.kind == .verbatim }?.lexeme == "|a{b}c % \\cite{fake}|")

        let srcMint = "\\mintinline{python}{d = {\"a\": 1} # % \\cite{fake}} \\cite{k}"
        let tokMint = assertOpaqueLosslessRoundTrip(srcMint, filePath: "mintbrace.tex", expectOpaqueToken: true)
        #expect(tokMint.first { $0.kind == .verbatim }?.lexeme == "d = {\"a\": 1} # % \\cite{fake}")
        let parsedMint = parser.parse(source: srcMint, filePath: "mintbrace.tex", format: .latex)
        let symMint = MacroExpansionEngine().buildSymbolTable(from: parsedMint)
        #expect(Set(symMint.citationsByKey.keys) == ["k"])
        #expect(parsedMint.issues.isEmpty)
    }

    // MARK: - M2 Stage 04: Citation & Cross-Ref Command Tables, Optional Args, Key Normalization, and S67 Fixes

    @Test("M2 Stage 04 item 1 (S64): citation command table extracts single-key, multi-key, 1 and 2 optional arguments, starred forms, and chained multicites")
    func m2Stage04Item1CitationCommandTableExtraction() {
        let table = LaTeXCommandRole.citationCommandTable
        let expectedBaseCommands: Set<String> = [
            "\\cite", "\\citep", "\\citet", "\\citealt", "\\citealp", "\\citeauthor", "\\citeyear", "\\citeyearpar",
            "\\citenum", "\\Citet", "\\Citep", "\\Citealt", "\\Citealp", "\\Citeauthor", "\\Cite",
            "\\parencite", "\\Parencite", "\\textcite", "\\Textcite", "\\autocite", "\\Autocite",
            "\\citetitle", "\\footcite", "\\footfullcite", "\\fullcite", "\\supercite", "\\smartcite",
            "\\cites", "\\parencites", "\\textcites", "\\autocites",
            "\\citeA", "\\citeN", "\\shortcite", "\\nocite"
        ]
        #expect(Set(table.map(\.baseCommand)) == expectedBaseCommands)
        #expect(table.count == expectedBaseCommands.count)

        let parser = HandwrittenMarkupCSTParser()
        let macroEngine = MacroExpansionEngine()

        for spec in table {
            let cmd = spec.baseCommand
            var fragments: [String] = [
                "\(cmd){k_single}",
                "\(cmd){k_multi_1, k_multi_2}"
            ]
            var expectedKeys: Set<String> = ["k_single", "k_multi_1", "k_multi_2"]

            if spec.maxOptionalArguments >= 1 {
                fragments.append("\(cmd)[p.~4]{k_opt1}")
                expectedKeys.insert("k_opt1")
            }
            if spec.maxOptionalArguments >= 2 {
                fragments.append("\(cmd)[see][p.~5]{k_opt2_a, k_opt2_b}")
                expectedKeys.formUnion(["k_opt2_a", "k_opt2_b"])
            }
            if spec.supportsStarred {
                fragments.append("\(cmd)*{k_star_1}")
                fragments.append("\(cmd)*[p.~8]{k_star_opt1}")
                fragments.append("\(cmd)*[cf.][p.~9]{k_star_m1, k_star_m2}")
                expectedKeys.formUnion(["k_star_1", "k_star_opt1", "k_star_m1", "k_star_m2"])
            }
            if spec.isMulticite {
                fragments.append("\(cmd)[see][p.~2]{k_mc1}[cf.]{k_mc2, k_mc3}{k_mc4}")
                expectedKeys.formUnion(["k_mc1", "k_mc2", "k_mc3", "k_mc4"])
            }

            let doc = """
            \\documentclass{article}
            \\begin{document}
            \(fragments.joined(separator: " and ")).
            \\end{document}
            """
            let parsed = parser.parse(source: doc, filePath: "cite_\(cmd.dropFirst()).tex", format: .latex)
            let sym = macroEngine.buildSymbolTable(from: parsed)
            let actualKeys = Set(sym.citationsByKey.keys)
            #expect(actualKeys == expectedKeys, "[\(cmd)] expected \(expectedKeys), got \(actualKeys)")
            #expect(parsed.issues.isEmpty, "[\(cmd)] expected 0 AST issues, got \(parsed.issues)")
        }
    }

    @Test("M2 Stage 04 item 2 (S64): cross-reference command table extracts targets, multi-key cref/Cref, and starred forms without AST012")
    func m2Stage04Item2CrossReferenceCommandTableAndStarredForms() {
        let table = LaTeXCommandRole.crossReferenceCommandTable
        let expectedBaseCommands: Set<String> = [
            "\\ref", "\\eqref", "\\pageref", "\\nameref", "\\autoref", "\\Autoref",
            "\\cref", "\\Cref", "\\cpageref", "\\Cpageref", "\\labelcref", "\\namecref", "\\nameCref",
            "\\subref", "\\hyperref", "\\vref", "\\Vref", "\\fref", "\\Fref", "\\sref"
        ]
        #expect(Set(table.map(\.baseCommand)) == expectedBaseCommands)
        #expect(table.count == expectedBaseCommands.count)

        let parser = HandwrittenMarkupCSTParser()
        let macroEngine = MacroExpansionEngine()

        for spec in table {
            let cmd = spec.baseCommand
            var fragments: [String] = []
            var expectedTargets: Set<String> = ["sec:a"]

            if spec.targetInBracket {
                fragments.append("\(cmd)[sec:a]{target text}")
            } else {
                fragments.append("\(cmd){sec:a}")
            }

            if spec.supportsStarred {
                fragments.append("\(cmd)*{sec:star}")
                expectedTargets.insert("sec:star")
            }

            if spec.supportsMultiKey {
                fragments.append("\(cmd){eq:m1, eq:m2,sec:m3}")
                expectedTargets.formUnion(["eq:m1", "eq:m2", "sec:m3"])
                if spec.supportsStarred {
                    fragments.append("\(cmd)*{eq:sm1, eq:sm2}")
                    expectedTargets.formUnion(["eq:sm1", "eq:sm2"])
                }
            }

            let doc = """
            \\documentclass{article}
            \\begin{document}
            \(fragments.joined(separator: " and ")).
            \\end{document}
            """
            let parsed = parser.parse(source: doc, filePath: "xref_\(cmd.dropFirst()).tex", format: .latex)
            let sym = macroEngine.buildSymbolTable(from: parsed)
            let actualTargets = Set(sym.crossReferences.map(\.targetKey))
            #expect(actualTargets == expectedTargets, "[\(cmd)] expected \(expectedTargets), got \(actualTargets)")
            #expect(!parsed.issues.contains { $0.code == .malformedCrossReference }, "[\(cmd)] unexpected AST012: \(parsed.issues)")
            #expect(parsed.issues.isEmpty, "[\(cmd)] expected 0 AST issues, got \(parsed.issues)")
        }
    }

    @Test("M2 Stage 04 item 3 (S65): optional [...] arguments of theorem environments, \\section, and \\caption extract \\cite and \\ref")
    func m2Stage04Item3OptionalArgumentCiteAndRefExtraction() {
        let source = """
        \\documentclass{article}
        \\begin{document}
        \\section{Setup}\\label{sec:setup}
        \\begin{equation}\\label{eq:base} x = 1 \\end{equation}
        \\begin{lemma}[Uniform bound~\\citep{k_thm1}, cf.~\\ref{sec:setup} and {\\citet[Lemma~2]{k_thm2}}]\\label{lem:bound}
        Proof uses \\citep[see~\\eqref{eq:base}]{k_prenote}.
        \\end{lemma}
        \\section[Short title~\\cite{k_sec_opt} (\\ref{sec:setup})]{Full title~\\cite{k_sec_body}}\\label{sec:two}
        \\begin{figure}[t]
        \\caption[Short caption~\\cite{k_cap_opt} (\\ref{lem:bound})]{Full caption~\\cite{k_cap_body}.}\\label{fig:one}
        \\end{figure}
        \\end{document}
        """
        let parser = HandwrittenMarkupCSTParser()
        let parsed = parser.parse(source: source, filePath: "optarg.tex", format: .latex)
        let sym = MacroExpansionEngine().buildSymbolTable(from: parsed)

        let expectedCites: Set<String> = [
            "k_thm1", "k_thm2", "k_prenote", "k_sec_opt", "k_sec_body", "k_cap_opt", "k_cap_body"
        ]
        let expectedRefs: Set<String> = ["sec:setup", "eq:base", "lem:bound"]
        let expectedLabels: Set<String> = ["sec:setup", "eq:base", "lem:bound", "sec:two", "fig:one"]

        #expect(Set(sym.citationsByKey.keys) == expectedCites)
        #expect(Set(sym.crossReferences.map(\.targetKey)) == expectedRefs)
        #expect(Set(sym.labelsByKey.keys) == expectedLabels)
        #expect(parsed.issues.isEmpty, "Expected 0 AST issues, got \(parsed.issues)")
    }

    @Test("M2 Stage 04 item 4a (S66): label, cross-reference, and citation keys trim outer whitespace and collapse internal consecutive whitespace")
    func m2Stage04Item4aKeyWhitespaceNormalizationInParserAndSymbolTable() {
        let source = """
        \\documentclass{article}
        \\begin{document}
        \\begin{corollary}\\label{  Cor: tilted   Gibbs |gen|  }
        \\end{corollary}
        \\begin{equation}\\label{eq: multi
           line}
        x = y
        \\end{equation}
        See \\ref{Cor: tilted  Gibbs |gen|} and \\cref{  Cor: tilted    Gibbs |gen| , eq: multi   line  }.
        Cite \\citep{  k_alpha ,
           k_beta  ,  multi   word\t key  }.
        \\end{document}
        """
        let parser = HandwrittenMarkupCSTParser()
        let parsed = parser.parse(source: source, filePath: "norm.tex", format: .latex)
        let sym = MacroExpansionEngine().buildSymbolTable(from: parsed)

        #expect(Set(sym.labelsByKey.keys) == ["Cor: tilted Gibbs |gen|", "eq: multi line"])
        #expect(Set(sym.crossReferences.map(\.targetKey)) == ["Cor: tilted Gibbs |gen|", "eq: multi line"])
        #expect(Set(sym.citationsByKey.keys) == ["k_alpha", "k_beta", "multi word key"])
        #expect(parsed.issues.isEmpty, "Expected 0 AST issues, got \(parsed.issues)")
    }

    @Test("M2 Stage 04 item 5 (S67): valid TeX brace-group environments, nested subsidiary math environments, and comment-line optional arguments emit 0 AST* while real syntax errors still emit AST*")
    func m2Stage04Item5S67ValidConstructsZeroASTErrorsAndRealErrorsPreserved() throws {
        let validSource = """
        \\documentclass{article}
        \\usepackage[colorinlistoftodos, color=blue!30!white %   ,shadow
        \t% ,disable
        ]{todonotes}
        \\author{Alice
        %\\thanks{Grant 1}
        %\\thanks{Grant 2}
        }
        \\begin{document}
        {\\begin{center}Centered~\\cite{k1}\\end{center}}
        {\\small\\begin{tabular}{ll}A & B \\\\ C & D\\end{tabular}}
        \\resizebox{\\columnwidth}{!}{%
        \\begin{tabular}{ll}X & Y\\end{tabular}%
        }
        {\\color{blue}

        First paragraph inside group.

        Second paragraph inside group.
        }
        \\begin{equation}\\label{eq:s1}
        \\begin{split} a &= b \\\\ &= c \\end{split}
        \\end{equation}
        \\begin{equation*}
        \\begin{split}
        f(x) &= \\begin{cases} 1, & x > 0 \\\\ 0, & x \\le 0 \\end{cases}
        \\end{split}
        \\end{equation*}
        \\begin{align}
        \\begin{aligned} u &= 1 \\\\ v &= 2 \\end{aligned}
        \\quad
        \\begin{gathered} p \\\\ q \\end{gathered}
        \\quad
        \\begin{alignedat}{2} a &= 1 & b &= 2 \\end{alignedat}
        \\end{align}
        \\begin{gather}
        M = \\left(\\begin{array}{cc} 1 & 0 \\\\ 0 & 1 \\end{array}\\right)
        + \\begin{pmatrix} 1 & 2 \\end{pmatrix}
        + \\begin{bmatrix} 3 \\end{bmatrix}
        + \\begin{Bmatrix} 4 \\end{Bmatrix}
        + \\begin{vmatrix} 5 \\end{vmatrix}
        + \\begin{Vmatrix} 6 \\end{Vmatrix}
        + \\begin{dcases} \\begin{smallmatrix} 1 & 0 \\end{smallmatrix}, & t > 0 \\end{dcases}
        \\end{gather}
        Inline $\\begin{psmallmatrix} 1 & 0 \\\\ 0 & 1 \\end{psmallmatrix}$ and \\[ \\begin{rcases} x = 1 \\end{rcases} \\].
        \\end{document}
        """
        let parser = HandwrittenMarkupCSTParser()
        let parsedValid = parser.parse(source: validSource, filePath: "s67_valid.tex", format: .latex)
        #expect(parsedValid.issues.isEmpty, "Valid S67 LaTeX must emit 0 AST issues, got \(parsedValid.issues)")

        // Real benchmark manuscript 2409.19431v3 (previously 274 AST* issues, missing 2 optarg cites, 1 double-space label)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let p2409URL = repoRoot.appendingPathComponent("Benchmarks/manuscripts/2409.19431v3/src/ICML_Camera_Ready_GE_tilted.tex")
        let src2409 = try String(contentsOf: p2409URL, encoding: .utf8)
        let parsed2409 = parser.parse(source: src2409, filePath: "ICML_Camera_Ready_GE_tilted.tex", format: .latex)
        #expect(parsed2409.issues.isEmpty, "2409.19431v3 must emit 0 AST issues, got \(parsed2409.issues.count): \(parsed2409.issues.prefix(5))")
        let sym2409 = MacroExpansionEngine().buildSymbolTable(from: parsed2409)
        #expect(sym2409.citationsByKey.count == 79)
        #expect(sym2409.citationsByKey["mohri2018foundations"] != nil)
        #expect(sym2409.citationsByKey["polyanskiy2022information"] != nil)
        #expect(sym2409.labelsByKey.count == 167)
        #expect(sym2409.labelsByKey["Cor: tilted Gibbs |gen|"] != nil)

        // Positive error checks: genuinely broken LaTeX syntax must STILL emit AST* errors!
        let unclosedBraceInEnv = "\\begin{document}\\begin{figure}{ unclosed \\end{figure}\\end{document}"
        let r1 = parser.parse(source: unclosedBraceInEnv, filePath: "err1.tex", format: .latex)
        #expect(r1.issues.contains { $0.code == .unclosedBrace && $0.severity == .error })

        let strayCloseBrace = "\\begin{document} text } more \\end{document}"
        let r2 = parser.parse(source: strayCloseBrace, filePath: "err2.tex", format: .latex)
        #expect(r2.issues.contains { $0.code == .unexpectedClosingBrace && $0.severity == .error })

        let unclosedSplitInEq = "\\begin{document}\\begin{equation}\\begin{split} a = b \\end{equation}\\end{document}"
        let r3 = parser.parse(source: unclosedSplitInEq, filePath: "err3.tex", format: .latex)
        #expect(!r3.issues.filter { $0.severity == .error }.isEmpty, "Unclosed split inside equation must still report an AST error")

        let mismatchedDisplayMath = "\\begin{document}\\begin{align} x = 1 \\end{itemize}\\end{document}"
        let r4 = parser.parse(source: mismatchedDisplayMath, filePath: "err4.tex", format: .latex)
        #expect(r4.issues.contains { $0.code == .mismatchedEnvironmentEnd && $0.severity == .error })

        let unclosedBracketBlankLine = "\\usepackage[a, b\n\n\\begin{document}x\\end{document}"
        let r5 = parser.parse(source: unclosedBracketBlankLine, filePath: "err5.tex", format: .latex)
        #expect(r5.issues.contains { $0.code == .unclosedBracket && $0.severity == .error })
    }
}
