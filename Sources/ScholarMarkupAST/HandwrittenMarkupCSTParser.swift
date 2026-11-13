import Foundation
import ScholarModels

// MARK: - Parse Diagnostics & Configuration

/// Structured diagnostic codes produced during error-recovering CST/AST parsing.
public enum MarkupParseIssueCode: String, Sendable, Codable, Hashable, CaseIterable {
    case unclosedBrace = "AST001"
    case unexpectedClosingBrace = "AST002"
    case unclosedBracket = "AST003"
    case missingEnvironmentEnd = "AST004"
    case mismatchedEnvironmentEnd = "AST005"
    case orphanEnvironmentEnd = "AST006"
    case unclosedInlineMath = "AST007"
    case unclosedDisplayMath = "AST008"
    case malformedMacroDefinition = "AST009"
    case malformedCitationCommand = "AST010"
    case malformedSectionCommand = "AST011"
    case malformedCrossReference = "AST012"
    case malformedFileInclude = "AST013"
    case emptyLabelKey = "AST014"
    case unclosedTypstConstruct = "AST015"
    case missingEndDocument = "AST016"
}

/// Structured syntax recovery diagnostic convertible to `LSPDiagnostic`.
public struct MarkupParseIssue: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let code: MarkupParseIssueCode
    public let severity: LSPDiagnosticSeverity
    public let message: String
    public let span: TextSpan
    public let suggestedFix: String?
    public let recoveredConstruct: String?

    public init(
        id: UUID = UUID(),
        code: MarkupParseIssueCode,
        severity: LSPDiagnosticSeverity = .error,
        message: String,
        span: TextSpan,
        suggestedFix: String? = nil,
        recoveredConstruct: String? = nil
    ) {
        self.id = id
        self.code = code
        self.severity = severity
        self.message = message
        self.span = span
        self.suggestedFix = suggestedFix
        self.recoveredConstruct = recoveredConstruct
    }

    /// Converts this parse recovery issue directly into a `ScholarModels.LSPDiagnostic`.
    public func toLSPDiagnostic() -> LSPDiagnostic {
        LSPDiagnostic(
            id: id,
            code: code.rawValue,
            severity: severity,
            message: message,
            span: span,
            suggestedFix: suggestedFix
        )
    }
}

/// Controls CST/AST tree-building bounds and paragraph preview summarization.
public struct ParserConfiguration: Sendable, Codable, Hashable {
    public var maxNestingDepth: Int
    public var paragraphPreviewMaxCharacters: Int
    public var nestContentUnderSections: Bool

    public init(
        maxNestingDepth: Int = 128,
        paragraphPreviewMaxCharacters: Int = 240,
        nestContentUnderSections: Bool = true
    ) {
        self.maxNestingDepth = max(8, maxNestingDepth)
        self.paragraphPreviewMaxCharacters = max(32, paragraphPreviewMaxCharacters)
        self.nestContentUnderSections = nestContentUnderSections
    }

    public static let standard = ParserConfiguration()
}

/// Complete parse output combining the `.document(format:)` root AST, recovery diagnostics, and lexical stream.
public struct MarkupParseResult: Sendable, Codable, Hashable {
    public let root: MarkupASTNode
    public let issues: [MarkupParseIssue]
    public let tokens: [MarkupToken]
    public let format: ManuscriptFormat
    public let filePath: String

    public init(
        root: MarkupASTNode,
        issues: [MarkupParseIssue],
        tokens: [MarkupToken],
        format: ManuscriptFormat,
        filePath: String
    ) {
        self.root = root
        self.issues = issues
        self.tokens = tokens
        self.format = format
        self.filePath = filePath
    }

    /// Converts all parse recovery issues into `LSPDiagnostic` items.
    public var lspDiagnostics: [LSPDiagnostic] {
        issues.map { $0.toLSPDiagnostic() }
    }

    /// True if any `.error` severity diagnostic was emitted during parsing.
    public var hasSyntaxErrors: Bool {
        issues.contains { $0.severity == .error }
    }
}

// MARK: - MarkupASTNode Query & Spatial Lookup Extensions

extension MarkupASTNode {
    /// Returns all nodes in the AST subtree in pre-order depth-first sequence.
    public func flattenedNodes() -> [MarkupASTNode] {
        var result: [MarkupASTNode] = []
        result.reserveCapacity(32)
        collectDFS(into: &result)
        return result
    }

    private func collectDFS(into buffer: inout [MarkupASTNode]) {
        buffer.append(self)
        for child in children {
            child.collectDFS(into: &buffer)
        }
    }

    /// Filters all nodes in the subtree matching `predicate` in document order.
    public func nodes(matching predicate: (MarkupASTNode) -> Bool) -> [MarkupASTNode] {
        var matches: [MarkupASTNode] = []
        collectMatching(predicate: predicate, into: &matches)
        return matches
    }

    private func collectMatching(predicate: (MarkupASTNode) -> Bool, into buffer: inout [MarkupASTNode]) {
        if predicate(self) {
            buffer.append(self)
        }
        for child in children {
            child.collectMatching(predicate: predicate, into: &buffer)
        }
    }

    /// Finds the deepest AST node enclosing `position` (`start <= position && position <= end`).
    public func innermostNode(at position: TextPosition) -> MarkupASTNode? {
        guard spanContains(position) else { return nil }
        for child in children {
            if let deeper = child.innermostNode(at: position) {
                return deeper
            }
        }
        return self
    }

    /// Finds the deepest AST node enclosing 1-based `(line, column)`.
    public func innermostNode(atLine line: Int, column: Int) -> MarkupASTNode? {
        let probe = TextPosition(line: line, column: column, utf8Offset: 0)
        return innermostNode(at: probe)
    }

    private func spanContains(_ pos: TextPosition) -> Bool {
        if pos < span.start { return false }
        if span.end < pos { return false }
        return true
    }

    public var allSections: [MarkupASTNode] {
        nodes {
            if case .section = $0.kind { return true }
            return false
        }
    }

    public var allEnvironments: [MarkupASTNode] {
        nodes {
            if case .environment = $0.kind { return true }
            return false
        }
    }

    public var allCitations: [MarkupASTNode] {
        nodes {
            if case .citation = $0.kind { return true }
            return false
        }
    }

    public var allLabels: [MarkupASTNode] {
        nodes {
            if case .labelDeclaration = $0.kind { return true }
            return false
        }
    }

    public var allCrossReferences: [MarkupASTNode] {
        nodes {
            if case .crossReference = $0.kind { return true }
            return false
        }
    }

    public var allFileIncludes: [MarkupASTNode] {
        nodes {
            if case .fileInclude = $0.kind { return true }
            return false
        }
    }

    public var allMacroDefinitions: [MarkupASTNode] {
        nodes {
            if case .macroDefinition = $0.kind { return true }
            return false
        }
    }

    public var allMathExpressions: [MarkupASTNode] {
        nodes {
            if case .mathExpression = $0.kind { return true }
            return false
        }
    }

    public var allParagraphs: [MarkupASTNode] {
        nodes {
            if case .paragraph = $0.kind { return true }
            return false
        }
    }

    public var allSyntaxErrors: [MarkupASTNode] {
        nodes {
            if case .syntaxErrorRecovery = $0.kind { return true }
            return false
        }
    }
}

// MARK: - Handwritten Error-Recovering Recursive-Descent CST/AST Parser

/// Error-recovering recursive-descent CST/AST parser for LaTeX, Typst, and Academic Markdown.
public struct HandwrittenMarkupCSTParser: Sendable {
    public let configuration: ParserConfiguration
    public let lexer: IncrementalMarkupLexer

    public init(
        configuration: ParserConfiguration = .standard,
        lexer: IncrementalMarkupLexer = IncrementalMarkupLexer(configuration: .losslessCST)
    ) {
        self.configuration = configuration
        self.lexer = lexer
    }

    /// Tokenizes `source` and parses it into a hierarchical `MarkupParseResult`.
    public func parse(
        source: String,
        filePath: String = "main.tex",
        format: ManuscriptFormat? = nil
    ) -> MarkupParseResult {
        let resolvedFormat = format ?? ManuscriptFormat.detect(fromPath: filePath)
        let tokens = lexer.tokenize(source: source, format: resolvedFormat, filePath: filePath)
        return parse(tokens: tokens, format: resolvedFormat, filePath: filePath)
    }

    /// Parses an existing `[MarkupToken]` stream (e.g., from `IncrementalMarkupLexer.relexEdit`) into `MarkupParseResult`.
    public func parse(
        tokens: [MarkupToken],
        format: ManuscriptFormat,
        filePath: String = "main.tex"
    ) -> MarkupParseResult {
        var worker = ParseStreamWorker(
            tokens: tokens,
            format: format,
            filePath: filePath,
            configuration: configuration
        )
        let root = worker.parseDocument()
        return MarkupParseResult(
            root: root,
            issues: worker.issues,
            tokens: tokens,
            format: format,
            filePath: filePath
        )
    }
}

// MARK: - Internal Recursive-Descent Worker

private struct OpenSectionFrame {
    let level: Int
    var title: String
    var label: String?
    let startPos: TextPosition
    var children: [MarkupASTNode]
}

private struct ParagraphAccumulator {
    var startPos: TextPosition?
    var endPos: TextPosition?
    var proseWords: [String] = []
    var inlineNodes: [MarkupASTNode] = []

    var isEmpty: Bool {
        proseWords.isEmpty && inlineNodes.isEmpty
    }

    mutating func recordProseFragment(_ fragment: String, span: TextSpan) {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if startPos == nil {
            startPos = span.start
        }
        endPos = span.end
        proseWords.append(trimmed)
    }

    mutating func recordInlineSemanticNode(_ node: MarkupASTNode, inlineSummary: String? = nil) {
        if startPos == nil {
            startPos = node.span.start
        }
        endPos = node.span.end
        inlineNodes.append(node)
        if let summary = inlineSummary, !summary.isEmpty {
            proseWords.append(summary)
        }
    }

    mutating func reset() {
        startPos = nil
        endPos = nil
        proseWords.removeAll(keepingCapacity: true)
        inlineNodes.removeAll(keepingCapacity: true)
    }
}

private struct ParseStreamWorker {
    let tokens: [MarkupToken]
    let format: ManuscriptFormat
    let filePath: String
    let configuration: ParserConfiguration

    var index: Int = 0
    var issues: [MarkupParseIssue] = []
    var activeEnvironmentStack: [String] = []
    var declaredTypstLabels: Set<String> = []
    var sawBeginDocument: Bool = false
    var sawEndDocument: Bool = false

    private static let displayMathEnvironments: Set<String> = [
        "equation", "equation*", "align", "align*", "gather", "gather*",
        "multline", "multline*", "flalign", "flalign*", "eqnarray", "eqnarray*",
        "math", "displaymath"
    ]

    private static let typstCrossRefPrefixes: [String] = [
        "sec:", "subsec:", "chap:", "ch:", "part:", "app:", "appendix:",
        "fig:", "subfig:", "tab:", "tbl:", "eq:", "eqn:",
        "thm:", "lem:", "prop:", "cor:", "def:", "alg:", "algo:", "lst:"
    ]

    init(
        tokens: [MarkupToken],
        format: ManuscriptFormat,
        filePath: String,
        configuration: ParserConfiguration
    ) {
        self.tokens = tokens
        self.format = format
        self.filePath = filePath
        self.configuration = configuration
    }

    // MARK: Token Cursor Primitives

    @inline(__always)
    var isAtEnd: Bool {
        index >= tokens.count || tokens[index].kind == .eof
    }

    @inline(__always)
    func peek(_ offset: Int = 0) -> MarkupToken {
        let target = index + offset
        if target >= 0 && target < tokens.count {
            return tokens[target]
        }
        if let last = tokens.last {
            return last
        }
        let pos = TextPosition.startOfFile
        return MarkupToken(kind: .eof, lexeme: "", span: TextSpan(filePath: filePath, start: pos, end: pos))
    }

    @discardableResult
    @inline(__always)
    mutating func advance() -> MarkupToken {
        let tok = peek(0)
        if index < tokens.count && tok.kind != .eof {
            index += 1
        }
        return tok
    }

    mutating func skipHorizontalWhitespaceAndComments() {
        while !isAtEnd {
            let tok = peek()
            if tok.kind == .comment {
                advance()
            } else if tok.kind == .whitespace && !tok.lexeme.contains("\n") && !tok.lexeme.contains("\r") {
                advance()
            } else {
                break
            }
        }
    }

    mutating func skipSameLineOrSingleNewlineWhitespace() {
        var newlinesSeen = 0
        while !isAtEnd {
            let tok = peek()
            if tok.kind == .comment {
                advance()
            } else if tok.kind == .whitespace {
                if tok.lexeme.contains("\n") || tok.lexeme.contains("\r") {
                    if newlinesSeen >= 1 {
                        break
                    }
                    newlinesSeen += 1
                }
                advance()
            } else {
                break
            }
        }
    }

    func countConsecutiveNewlines(startingAt startIdx: Int) -> (newlineCount: Int, nextIndex: Int) {
        var idx = startIdx
        var newlines = 0
        while idx < tokens.count {
            let tok = tokens[idx]
            if tok.kind == .whitespace {
                if tok.lexeme.contains("\n") || tok.lexeme.contains("\r") {
                    newlines += 1
                }
                idx += 1
            } else if tok.kind == .comment {
                idx += 1
            } else {
                break
            }
        }
        return (newlines, idx)
    }

    mutating func emitIssue(
        code: MarkupParseIssueCode,
        severity: LSPDiagnosticSeverity = .error,
        message: String,
        span: TextSpan,
        suggestedFix: String? = nil,
        recoveredConstruct: String? = nil
    ) -> MarkupASTNode {
        let issue = MarkupParseIssue(
            code: code,
            severity: severity,
            message: message,
            span: span,
            suggestedFix: suggestedFix,
            recoveredConstruct: recoveredConstruct
        )
        issues.append(issue)
        return MarkupASTNode(kind: .syntaxErrorRecovery(message: message), span: span)
    }

    // MARK: Document Entry

    mutating func parseDocument() -> MarkupASTNode {
        // Pre-scan `<label>` declarations in Typst so `@label` disambiguates cross-refs from bibliography citekeys.
        if format == .typst {
            prescanTypstLabels()
        }

        let docStart = peek().span.start
        var topLevelNodes: [MarkupASTNode] = []
        var sectionStack: [OpenSectionFrame] = []
        var paragraph = ParagraphAccumulator()

        while !isAtEnd {
            // Blank line (`>= 2` newlines) flushes active paragraph cleanly.
            if peek().kind == .whitespace {
                let (newlines, nextIdx) = countConsecutiveNewlines(startingAt: index)
                if newlines >= 2 {
                    flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                    index = nextIdx
                    continue
                }
                advance()
                continue
            }

            if peek().kind == .comment {
                advance()
                continue
            }

            switch format {
            case .latex:
                parseNextLaTeXItem(
                    paragraph: &paragraph,
                    sectionStack: &sectionStack,
                    topLevelNodes: &topLevelNodes
                )
            case .typst:
                parseNextTypstItem(
                    paragraph: &paragraph,
                    sectionStack: &sectionStack,
                    topLevelNodes: &topLevelNodes
                )
            case .markdown:
                parseNextMarkdownItem(
                    paragraph: &paragraph,
                    sectionStack: &sectionStack,
                    topLevelNodes: &topLevelNodes
                )
            }
        }

        flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)

        let docEnd = peek().span.end

        // Check if `\begin{document}` was opened without `\end{document}` in LaTeX.
        if format == .latex && sawBeginDocument && !sawEndDocument {
            let eofSpan = TextSpan(filePath: filePath, start: docEnd, end: docEnd)
            let errNode = emitIssue(
                code: .missingEndDocument,
                severity: .warning,
                message: "Missing '\\end{document}' before end of file.",
                span: eofSpan,
                suggestedFix: "\\end{document}",
                recoveredConstruct: "document"
            )
            appendNode(errNode, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
        }

        closeSections(downToOrEqualLevel: Int.min, endPos: docEnd, sectionStack: &sectionStack, topLevelNodes: &topLevelNodes)

        return MarkupASTNode(
            kind: .document(format: format),
            span: TextSpan(filePath: filePath, start: docStart, end: docEnd),
            children: topLevelNodes
        )
    }

    private mutating func prescanTypstLabels() {
        for tok in tokens where tok.kind == .identifier && tok.lexeme.hasPrefix("<") && tok.lexeme.hasSuffix(">") {
            let inner = String(tok.lexeme.dropFirst().dropLast())
            if !inner.isEmpty {
                declaredTypstLabels.insert(inner)
            }
        }
    }

    // MARK: Section Tree Management

    private func flushParagraph(
        _ paragraph: inout ParagraphAccumulator,
        intoSections sectionStack: inout [OpenSectionFrame],
        orTopLevel topLevelNodes: inout [MarkupASTNode]
    ) {
        guard !paragraph.isEmpty,
              let start = paragraph.startPos,
              let end = paragraph.endPos else {
            paragraph.reset()
            return
        }

        // If the paragraph consists purely of semantic nodes without prose words (e.g., standalone `\label{...}` or display math),
        // attach those nodes directly instead of wrapping them in an empty-preview paragraph.
        let joinedProse = normalizeWhitespace(paragraph.proseWords.joined(separator: " "))
        if joinedProse.isEmpty {
            for node in paragraph.inlineNodes {
                appendNode(node, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
            }
            paragraph.reset()
            return
        }

        let preview: String
        if joinedProse.count > configuration.paragraphPreviewMaxCharacters {
            let cutIdx = joinedProse.index(joinedProse.startIndex, offsetBy: configuration.paragraphPreviewMaxCharacters)
            preview = String(joinedProse[..<cutIdx]) + "…"
        } else {
            preview = joinedProse
        }

        let paraNode = MarkupASTNode(
            kind: .paragraph(plainPreview: preview),
            span: TextSpan(filePath: filePath, start: start, end: end),
            children: paragraph.inlineNodes
        )
        appendNode(paraNode, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
        paragraph.reset()
    }

    private func appendNode(
        _ node: MarkupASTNode,
        intoSections sectionStack: inout [OpenSectionFrame],
        orTopLevel topLevelNodes: inout [MarkupASTNode]
    ) {
        if configuration.nestContentUnderSections, !sectionStack.isEmpty {
            sectionStack[sectionStack.count - 1].children.append(node)
        } else {
            topLevelNodes.append(node)
        }
    }

    private func openSection(
        level: Int,
        title: String,
        label: String?,
        startPos: TextPosition,
        endOfHeaderPos: TextPosition,
        initialChildren: [MarkupASTNode],
        sectionStack: inout [OpenSectionFrame],
        topLevelNodes: inout [MarkupASTNode]
    ) {
        if !configuration.nestContentUnderSections {
            let flatSection = MarkupASTNode(
                kind: .section(level: level, title: title, label: label),
                span: TextSpan(filePath: filePath, start: startPos, end: endOfHeaderPos),
                children: initialChildren
            )
            topLevelNodes.append(flatSection)
            return
        }

        closeSections(
            downToOrEqualLevel: level,
            endPos: startPos,
            sectionStack: &sectionStack,
            topLevelNodes: &topLevelNodes
        )
        sectionStack.append(
            OpenSectionFrame(
                level: level,
                title: title,
                label: label,
                startPos: startPos,
                children: initialChildren
            )
        )
    }

    private func closeSections(
        downToOrEqualLevel targetLevel: Int,
        endPos: TextPosition,
        sectionStack: inout [OpenSectionFrame],
        topLevelNodes: inout [MarkupASTNode]
    ) {
        while let last = sectionStack.last, last.level >= targetLevel {
            let finished = sectionStack.removeLast()
            let computedEnd = finished.children.last?.span.end ?? endPos
            let finalEnd = computedEnd < finished.startPos ? finished.startPos : computedEnd
            let sectionNode = MarkupASTNode(
                kind: .section(level: finished.level, title: finished.title, label: finished.label),
                span: TextSpan(filePath: filePath, start: finished.startPos, end: finalEnd),
                children: finished.children
            )
            if !sectionStack.isEmpty {
                sectionStack[sectionStack.count - 1].children.append(sectionNode)
            } else {
                topLevelNodes.append(sectionNode)
            }
        }
    }

    // MARK: - 1. LaTeX Top-Level & Block Item Dispatch

    private mutating func parseNextLaTeXItem(
        paragraph: inout ParagraphAccumulator,
        sectionStack: inout [OpenSectionFrame],
        topLevelNodes: inout [MarkupASTNode]
    ) {
        let tok = peek()

        switch tok.kind {
        case .command:
            let role = LaTeXCommandRole.classify(tok.lexeme)
            switch role {
            case .sectioning:
                flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                parseLaTeXSection(sectionStack: &sectionStack, topLevelNodes: &topLevelNodes)

            case .appendixSwitch:
                flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                let appTok = advance()
                // Represent `\appendix` as a level-0 marker section or special command marker?
                // Wait: keeping a zero-children `.labelDeclaration`? No! How should MultiFileIncludeGraphResolver detect `\appendix`?
                // Let's check! MultiFileIncludeGraphResolver has access to `perFileParseResults` (including `tokens`!) AND `mergedRootAST`.
                // Even better: if `\appendix` is followed by `\section{Proofs}`, `tokens` has `\\appendix` at exact `TextPosition`,
                // OR we can also attach no spurious section node so `allSections` stays 100% pure real sections!
                _ = appTok

            case .environmentBegin:
                let envPeekName = peekLaTeXEnvironmentName(atCommandIndex: index)
                if envPeekName == "document" {
                    flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                    consumeLaTeXBeginOrEndDocument(isBegin: true)
                    return
                }
                flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                let envNode = parseLaTeXEnvironment()
                appendNode(envNode, intoSections: &sectionStack, orTopLevel: &topLevelNodes)

            case .environmentEnd:
                let envPeekName = peekLaTeXEnvironmentName(atCommandIndex: index)
                if envPeekName == "document" {
                    flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                    closeSections(
                        downToOrEqualLevel: Int.min,
                        endPos: tok.span.start,
                        sectionStack: &sectionStack,
                        topLevelNodes: &topLevelNodes
                    )
                    consumeLaTeXBeginOrEndDocument(isBegin: false)
                    return
                }
                flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                let orphanNode = parseOrphanEndEnvironment()
                appendNode(orphanNode, intoSections: &sectionStack, orTopLevel: &topLevelNodes)

            case .macroDefinition:
                flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                let macroNodes = parseLaTeXMacroDefinition()
                for m in macroNodes {
                    appendNode(m, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                }

            case .fileInclude, .bibliographyResource:
                flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                let includeNodes = parseLaTeXFileInclude()
                for inc in includeNodes {
                    appendNode(inc, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                }

            case .documentClass, .packageImport:
                flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                consumePreambleMetadataCommand()

            case .citation:
                let citeNodes = parseLaTeXCitation()
                for node in citeNodes {
                    paragraph.recordInlineSemanticNode(node)
                }

            case .crossReference:
                let refNodes = parseLaTeXCrossReference()
                for node in refNodes {
                    paragraph.recordInlineSemanticNode(node)
                }

            case .labelDeclaration:
                let labelNode = parseLaTeXLabelDeclaration()
                // If we are right after a section header and paragraph is empty, attach label to enclosing section too!
                if paragraph.isEmpty,
                   !sectionStack.isEmpty,
                   sectionStack[sectionStack.count - 1].label == nil,
                   case .labelDeclaration(let key) = labelNode.kind {
                    sectionStack[sectionStack.count - 1].label = key
                    appendNode(labelNode, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                } else {
                    paragraph.recordInlineSemanticNode(labelNode)
                }

            case .proseFormatting:
                parseInlineFormattingCommand(into: &paragraph)

            case .controlSymbol:
                let sym = advance()
                if let rendered = renderLaTeXControlSymbol(sym.lexeme) {
                    paragraph.recordProseFragment(rendered, span: sym.span)
                }

            case .captionCommand, .footnoteCommand, .mathDelimiter, .generalCommand:
                // Skip non-prose preamble-like setup commands (`\title`, `\author`, `\maketitle`, `\centering`, `\vspace`, etc.)
                if Self.standaloneSetupCommands.contains(tok.lexeme) {
                    consumeStandaloneSetupCommand(into: &paragraph, sectionStack: &sectionStack, topLevelNodes: &topLevelNodes)
                } else {
                    advance()
                }
            }

        case .mathDisplay:
            flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
            let mathNodes = parseLaTeXMath(isDisplay: true)
            for node in mathNodes {
                appendNode(node, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
            }

        case .mathInline:
            let mathNodes = parseLaTeXMath(isDisplay: false)
            for node in mathNodes {
                paragraph.recordInlineSemanticNode(node)
            }

        case .leftBrace:
            parseInlineBracedGroup(into: &paragraph)

        case .rightBrace:
            let stray = advance()
            let errNode = emitIssue(
                code: .unexpectedClosingBrace,
                severity: .error,
                message: "Unexpected closing brace '}' with no matching '{'.",
                span: stray.span,
                suggestedFix: "Remove stray '}' or insert matching '{'."
            )
            paragraph.recordInlineSemanticNode(errNode)

        case .textWord, .numeric, .identifier:
            let wordTok = advance()
            paragraph.recordProseFragment(wordTok.lexeme, span: wordTok.span)

        case .punctuation, .leftBracket, .rightBracket, .typstHashKeyword, .headingMarker:
            let punctTok = advance()
            if punctTok.lexeme != "~" {
                paragraph.recordProseFragment(punctTok.lexeme, span: punctTok.span)
            }

        case .whitespace, .comment, .eof:
            advance()
        }
    }

    private static let standaloneSetupCommands: Set<String> = [
        "\\maketitle", "\\tableofcontents", "\\listoffigures", "\\listoftables",
        "\\newpage", "\\clearpage", "\\cleardoublepage", "\\pagebreak",
        "\\centering", "\\raggedright", "\\raggedleft", "\\noindent",
        "\\bibliographystyle", "\\vspace", "\\vspace*", "\\hspace", "\\hspace*",
        "\\setlength", "\\addtolength", "\\setcounter", "\\pagenumbering",
        "\\thispagestyle", "\\pagestyle", "\\hypersetup", "\\graphicspath"
    ]

    private mutating func consumePreambleMetadataCommand() {
        advance() // `\documentclass` or `\usepackage`
        skipHorizontalWhitespaceAndComments()
        if peek().kind == .leftBracket {
            _ = consumeBracketGroup(allowMultiline: true)
        }
        skipHorizontalWhitespaceAndComments()
        if peek().kind == .leftBrace {
            _ = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: "preamble package/class")
        }
    }

    private mutating func consumeStandaloneSetupCommand(
        into paragraph: inout ParagraphAccumulator,
        sectionStack: inout [OpenSectionFrame],
        topLevelNodes: inout [MarkupASTNode]
    ) {
        let cmd = advance()
        let takesBracedArg: Set<String> = [
            "\\bibliographystyle", "\\vspace", "\\vspace*", "\\hspace", "\\hspace*",
            "\\pagenumbering", "\\thispagestyle", "\\pagestyle", "\\hypersetup", "\\graphicspath"
        ]
        let takesTwoBracedArgs: Set<String> = [
            "\\setlength", "\\addtolength", "\\setcounter"
        ]
        if takesBracedArg.contains(cmd.lexeme) {
            skipHorizontalWhitespaceAndComments()
            if peek().kind == .leftBrace {
                _ = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: cmd.lexeme)
            }
        } else if takesTwoBracedArgs.contains(cmd.lexeme) {
            for _ in 0..<2 {
                skipHorizontalWhitespaceAndComments()
                if peek().kind == .leftBrace {
                    _ = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: cmd.lexeme)
                }
            }
        } else if cmd.lexeme == "\\newpage" || cmd.lexeme == "\\clearpage" {
            flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
        }
    }

    // MARK: LaTeX Sections

    private mutating func parseLaTeXSection(
        sectionStack: inout [OpenSectionFrame],
        topLevelNodes: inout [MarkupASTNode]
    ) {
        let cmdTok = advance()
        let startPos = cmdTok.span.start
        let baseLevel = Self.latexSectionLevel(for: cmdTok.lexeme)
        let isStarred = cmdTok.lexeme.hasSuffix("*")

        skipSameLineOrSingleNewlineWhitespace()
        // Optional short title `\section[Short]{Full Title}`
        if peek().kind == .leftBracket {
            _ = consumeBracketGroup(allowMultiline: false)
            skipSameLineOrSingleNewlineWhitespace()
        }

        var sectionChildren: [MarkupASTNode] = []
        var extractedLabel: String? = nil
        let rawTitle: String
        var headerEndPos = cmdTok.span.end

        if peek().kind == .leftBrace {
            let group = consumeStructuredProseBraceGroup(constructName: cmdTok.lexeme)
            rawTitle = group.cleanText
            headerEndPos = group.endPos
            for child in group.semanticNodes {
                if case .labelDeclaration(let key) = child.kind, extractedLabel == nil {
                    extractedLabel = key
                }
                sectionChildren.append(child)
            }
            if let recoveryNode = group.recoveryNode {
                sectionChildren.append(recoveryNode)
            }
        } else {
            let errSpan = cmdTok.span
            let errNode = emitIssue(
                code: .malformedSectionCommand,
                severity: .error,
                message: "Expected '{title}' after '\(cmdTok.lexeme)'.",
                span: errSpan,
                suggestedFix: "\(cmdTok.lexeme){Section Title}",
                recoveredConstruct: cmdTok.lexeme
            )
            rawTitle = "Untitled Section"
            sectionChildren.append(errNode)
        }

        // Look ahead for an immediately attached `\label{sec:...}` right after the section title!
        let savedIndex = index
        skipSameLineOrSingleNewlineWhitespace()
        if peek().kind == .command && LaTeXCommandRole.classify(peek().lexeme) == .labelDeclaration {
            let lblNode = parseLaTeXLabelDeclaration()
            if case .labelDeclaration(let key) = lblNode.kind, extractedLabel == nil {
                extractedLabel = key
            }
            headerEndPos = lblNode.span.end
            sectionChildren.append(lblNode)
        } else {
            index = savedIndex
        }

        // Preserve starred state subtly via standard convention: if starred and no explicit prefix marker,
        // `MultiFileIncludeGraphResolver` checks raw command token at `sectionNode.span.start` (or title).
        _ = isStarred

        openSection(
            level: baseLevel,
            title: rawTitle.isEmpty ? "Untitled" : rawTitle,
            label: extractedLabel,
            startPos: startPos,
            endOfHeaderPos: headerEndPos,
            initialChildren: sectionChildren,
            sectionStack: &sectionStack,
            topLevelNodes: &topLevelNodes
        )
    }

    private static func latexSectionLevel(for command: String) -> Int {
        let stripped = command.hasSuffix("*") ? String(command.dropLast()) : command
        switch stripped {
        case "\\part": return 0
        case "\\chapter": return 1
        case "\\section": return 1
        case "\\subsection": return 2
        case "\\subsubsection": return 3
        case "\\paragraph": return 4
        case "\\subparagraph": return 5
        default: return 1
        }
    }

    // MARK: LaTeX Environments (with Mismatched & Missing `\end` Stack Recovery)

    private func peekLaTeXEnvironmentName(atCommandIndex cmdIdx: Int) -> String? {
        var cursor = cmdIdx + 1
        while cursor < tokens.count {
            let k = tokens[cursor].kind
            if k == .whitespace || k == .comment {
                cursor += 1
            } else {
                break
            }
        }
        guard cursor < tokens.count, tokens[cursor].kind == .leftBrace else { return nil }
        cursor += 1
        var nameParts = ""
        while cursor < tokens.count && tokens[cursor].kind != .rightBrace && tokens[cursor].kind != .eof {
            if tokens[cursor].kind == .whitespace && (tokens[cursor].lexeme.contains("\n") || tokens[cursor].lexeme.contains("\r")) {
                return nil
            }
            nameParts.append(tokens[cursor].lexeme)
            cursor += 1
        }
        guard cursor < tokens.count, tokens[cursor].kind == .rightBrace else { return nil }
        let trimmed = nameParts.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private mutating func consumeLaTeXBeginOrEndDocument(isBegin: Bool) {
        advance() // `\begin` or `\end`
        skipHorizontalWhitespaceAndComments()
        if peek().kind == .leftBrace {
            _ = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: isBegin ? "\\begin{document}" : "\\end{document}")
        }
        if isBegin {
            sawBeginDocument = true
        } else {
            sawEndDocument = true
        }
    }

    private mutating func parseOrphanEndEnvironment() -> MarkupASTNode {
        let endCmd = advance() // `\end`
        var endPos = endCmd.span.end
        var envName = "unknown"
        skipHorizontalWhitespaceAndComments()
        if peek().kind == .leftBrace {
            let grp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: "\\end")
            envName = grp.rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            endPos = grp.endPos
        }
        let span = TextSpan(filePath: filePath, start: endCmd.span.start, end: endPos)
        return emitIssue(
            code: .orphanEnvironmentEnd,
            severity: .error,
            message: "Orphan '\\end{\(envName)}' has no matching '\\begin{\(envName)}'.",
            span: span,
            suggestedFix: "Remove '\\end{\(envName)}' or add '\\begin{\(envName)}' above.",
            recoveredConstruct: envName
        )
    }

    private mutating func parseLaTeXEnvironment() -> MarkupASTNode {
        let beginCmd = advance() // `\begin`
        let startPos = beginCmd.span.start
        skipHorizontalWhitespaceAndComments()

        var envName = "environment"
        var headerEndPos = beginCmd.span.end
        var envChildren: [MarkupASTNode] = []

        if peek().kind == .leftBrace {
            let nameGroup = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: "\\begin")
            let parsedName = nameGroup.rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !parsedName.isEmpty {
                envName = parsedName
            }
            headerEndPos = nameGroup.endPos
            if let rec = nameGroup.recoveryNode {
                envChildren.append(rec)
            }
        } else {
            let errNode = emitIssue(
                code: .missingEnvironmentEnd,
                severity: .error,
                message: "Expected '{environment}' name after '\\begin'.",
                span: beginCmd.span,
                suggestedFix: "\\begin{environment}",
                recoveredConstruct: "\\begin"
            )
            envChildren.append(errNode)
            return MarkupASTNode(
                kind: .environment(name: envName, label: nil, caption: nil),
                span: beginCmd.span,
                children: envChildren
            )
        }

        // Optional placement/parameter brackets (`\begin{figure}[htbp]`, `\begin{tabular}{lcc}`).
        skipHorizontalWhitespaceAndComments()
        if peek().kind == .leftBracket {
            let opt = consumeBracketGroup(allowMultiline: false)
            headerEndPos = opt.endPos
            if let rec = opt.recoveryNode {
                envChildren.append(rec)
            }
        }
        if envName == "tabular" || envName == "tabular*" || envName == "tabularx" || envName == "array" || envName == "minipage" || envName == "subfigure" {
            skipHorizontalWhitespaceAndComments()
            while peek().kind == .leftBrace {
                let colSpec = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: envName)
                headerEndPos = colSpec.endPos
                if let rec = colSpec.recoveryNode {
                    envChildren.append(rec)
                }
                skipHorizontalWhitespaceAndComments()
            }
        }

        // Display math environments (`equation`, `align`, `gather`, `multline`, etc.) capture formula source + labels!
        if Self.displayMathEnvironments.contains(envName) {
            return parseDisplayMathEnvironmentBody(
                envName: envName,
                startPos: startPos,
                bodyStartPos: headerEndPos,
                initialChildren: envChildren
            )
        }

        // Push environment onto active stack (bounded by `maxNestingDepth`).
        if activeEnvironmentStack.count >= configuration.maxNestingDepth {
            let span = TextSpan(filePath: filePath, start: startPos, end: headerEndPos)
            let errNode = emitIssue(
                code: .missingEnvironmentEnd,
                severity: .error,
                message: "Maximum environment nesting depth (\(configuration.maxNestingDepth)) exceeded in '\(envName)'.",
                span: span,
                recoveredConstruct: envName
            )
            envChildren.append(errNode)
            return MarkupASTNode(
                kind: .environment(name: envName, label: nil, caption: nil),
                span: span,
                children: envChildren
            )
        }

        activeEnvironmentStack.append(envName)
        defer { _ = activeEnvironmentStack.popLast() }

        var detectedLabel: String? = nil
        var detectedCaption: String? = nil
        var paragraph = ParagraphAccumulator()
        var envEndPos = headerEndPos
        var closedCleanly = false

        while !isAtEnd {
            let tok = peek()

            // Blank line inside `abstract`, `theorem`, `proof`, etc. flushes paragraph.
            if tok.kind == .whitespace {
                let (newlines, nextIdx) = countConsecutiveNewlines(startingAt: index)
                if newlines >= 2 {
                    flushEnvironmentParagraph(&paragraph, into: &envChildren)
                    index = nextIdx
                    continue
                }
                advance()
                continue
            }

            if tok.kind == .comment {
                advance()
                continue
            }

            // Structural boundary recovery: if a top-level `\section` or `\chapter` or `\end{document}` appears while
            // inside `figure`, `table`, `abstract`, `theorem`, etc., do NOT swallow the rest of the manuscript!
            if tok.kind == .command {
                let role = LaTeXCommandRole.classify(tok.lexeme)

                if role == .sectioning {
                    let lvl = Self.latexSectionLevel(for: tok.lexeme)
                    if lvl <= 3 {
                        flushEnvironmentParagraph(&paragraph, into: &envChildren)
                        let missingSpan = TextSpan(filePath: filePath, start: startPos, end: tok.span.start)
                        let errNode = emitIssue(
                            code: .missingEnvironmentEnd,
                            severity: .error,
                            message: "Unclosed '\\begin{\(envName)}' recovered before '\(tok.lexeme)'.",
                            span: missingSpan,
                            suggestedFix: "\\end{\(envName)}",
                            recoveredConstruct: envName
                        )
                        envChildren.append(errNode)
                        envEndPos = tok.span.start
                        closedCleanly = true
                        break
                    }
                }

                if role == .environmentEnd {
                    flushEnvironmentParagraph(&paragraph, into: &envChildren)
                    let closingName = peekLaTeXEnvironmentName(atCommandIndex: index) ?? ""

                    if closingName == envName {
                        // Exact match! Consume `\end{envName}`.
                        let endCmdTok = advance()
                        envEndPos = endCmdTok.span.end
                        skipHorizontalWhitespaceAndComments()
                        if peek().kind == .leftBrace {
                            let endGrp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: "\\end")
                            envEndPos = endGrp.endPos
                        }
                        closedCleanly = true
                        break
                    } else if closingName == "document" || activeEnvironmentStack.dropLast().contains(closingName) {
                        // An outer enclosing environment (or `\end{document}`) is closing!
                        // Do NOT consume `\end{closingName}` — leave it on the stream for the outer frame,
                        // and recover the current unclosed inner environment here!
                        let missingSpan = TextSpan(filePath: filePath, start: startPos, end: tok.span.start)
                        let errNode = emitIssue(
                            code: .missingEnvironmentEnd,
                            severity: .error,
                            message: "Missing '\\end{\(envName)}' before outer '\\end{\(closingName)}'.",
                            span: missingSpan,
                            suggestedFix: "\\end{\(envName)}",
                            recoveredConstruct: envName
                        )
                        envChildren.append(errNode)
                        envEndPos = tok.span.start
                        closedCleanly = true
                        break
                    } else {
                        // Direct mismatch (e.g., `\begin{figure} ... \end{table}` where `table` is NOT open anywhere outer):
                        // Consume the mismatched `\end{closingName}`, emit `.mismatchedEnvironmentEnd`, and close `envName`!
                        let mismatchStart = tok.span.start
                        advance() // `\end`
                        var mismatchEnd = tok.span.end
                        skipHorizontalWhitespaceAndComments()
                        if peek().kind == .leftBrace {
                            let grp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: "\\end")
                            mismatchEnd = grp.endPos
                        }
                        let mismatchSpan = TextSpan(filePath: filePath, start: mismatchStart, end: mismatchEnd)
                        let errNode = emitIssue(
                            code: .mismatchedEnvironmentEnd,
                            severity: .error,
                            message: "Mismatched environment delimiter: opened '\\begin{\(envName)}' but encountered '\\end{\(closingName)}'.",
                            span: mismatchSpan,
                            suggestedFix: "\\end{\(envName)}",
                            recoveredConstruct: envName
                        )
                        envChildren.append(errNode)
                        envEndPos = mismatchEnd
                        closedCleanly = true
                        break
                    }
                }

                // Caption inside `figure`, `table`, `algorithm`, etc.
                if role == .captionCommand {
                    flushEnvironmentParagraph(&paragraph, into: &envChildren)
                    let capResult = parseLaTeXCaptionCommand()
                    if !capResult.captionText.isEmpty && detectedCaption == nil {
                        detectedCaption = capResult.captionText
                    }
                    for node in capResult.semanticNodes {
                        if case .labelDeclaration(let key) = node.kind, detectedLabel == nil {
                            detectedLabel = key
                        }
                        envChildren.append(node)
                    }
                    continue
                }

                // Label inside environment (`\label{fig:arch}`).
                if role == .labelDeclaration {
                    let lblNode = parseLaTeXLabelDeclaration()
                    if case .labelDeclaration(let key) = lblNode.kind, detectedLabel == nil {
                        detectedLabel = key
                    }
                    paragraph.recordInlineSemanticNode(lblNode)
                    continue
                }

                // Nested environment (`subfigure`, `tabular` inside `table`, `itemize` inside `theorem`).
                if role == .environmentBegin {
                    flushEnvironmentParagraph(&paragraph, into: &envChildren)
                    let nestedEnv = parseLaTeXEnvironment()
                    // Propagate label upward only if nested env is `tabular` without outer label? Keep outer independent;
                    // outer `table` usually has its own `\label`, or if `detectedLabel == nil` and nested has one? Keep separate unless `subfigure`? Actually keeping outer `detectedLabel` from direct `\label` is cleanest!
                    envChildren.append(nestedEnv)
                    continue
                }
            }

            // Delegate inline & nested items inside the environment body.
            var dummySections: [OpenSectionFrame] = []
            parseNextLaTeXItem(
                paragraph: &paragraph,
                sectionStack: &dummySections,
                topLevelNodes: &envChildren
            )
            // Also capture any `\label` that was appended to `envChildren`.
            if detectedLabel == nil {
                for node in paragraph.inlineNodes {
                    if case .labelDeclaration(let key) = node.kind {
                        detectedLabel = key
                        break
                    }
                }
            }
        }

        flushEnvironmentParagraph(&paragraph, into: &envChildren)

        if !closedCleanly {
            envEndPos = peek().span.end
            let missingSpan = TextSpan(filePath: filePath, start: startPos, end: envEndPos)
            let errNode = emitIssue(
                code: .missingEnvironmentEnd,
                severity: .error,
                message: "Unclosed '\\begin{\(envName)}' reached end of file without '\\end{\(envName)}'.",
                span: missingSpan,
                suggestedFix: "\\end{\(envName)}",
                recoveredConstruct: envName
            )
            envChildren.append(errNode)
        }

        // Final scan of direct children for `.labelDeclaration` if `detectedLabel` is still nil.
        if detectedLabel == nil {
            for child in envChildren {
                if case .labelDeclaration(let key) = child.kind {
                    detectedLabel = key
                    break
                }
            }
        }

        return MarkupASTNode(
            kind: .environment(name: envName, label: detectedLabel, caption: detectedCaption),
            span: TextSpan(filePath: filePath, start: startPos, end: envEndPos),
            children: envChildren
        )
    }

    private func flushEnvironmentParagraph(_ paragraph: inout ParagraphAccumulator, into children: inout [MarkupASTNode]) {
        var emptySections: [OpenSectionFrame] = []
        flushParagraph(&paragraph, intoSections: &emptySections, orTopLevel: &children)
    }

    private mutating func parseDisplayMathEnvironmentBody(
        envName: String,
        startPos: TextPosition,
        bodyStartPos: TextPosition,
        initialChildren: [MarkupASTNode]
    ) -> MarkupASTNode {
        var children = initialChildren
        var formulaTokens: [String] = []
        var detectedLabel: String? = nil
        var endPos = bodyStartPos
        var closedCleanly = false

        while !isAtEnd {
            let tok = peek()
            if tok.kind == .command {
                let role = LaTeXCommandRole.classify(tok.lexeme)
                if role == .environmentEnd {
                    let closingName = peekLaTeXEnvironmentName(atCommandIndex: index) ?? ""
                    if closingName == envName {
                        let endCmd = advance()
                        endPos = endCmd.span.end
                        skipHorizontalWhitespaceAndComments()
                        if peek().kind == .leftBrace {
                            let grp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: "\\end")
                            endPos = grp.endPos
                        }
                        closedCleanly = true
                        break
                    } else if closingName == "document" || activeEnvironmentStack.contains(closingName) {
                        let missingSpan = TextSpan(filePath: filePath, start: startPos, end: tok.span.start)
                        children.append(
                            emitIssue(
                                code: .missingEnvironmentEnd,
                                severity: .error,
                                message: "Missing '\\end{\(envName)}' before '\\end{\(closingName)}'.",
                                span: missingSpan,
                                suggestedFix: "\\end{\(envName)}",
                                recoveredConstruct: envName
                            )
                        )
                        endPos = tok.span.start
                        closedCleanly = true
                        break
                    } else {
                        let mismatchStart = tok.span.start
                        advance()
                        var mismatchEnd = tok.span.end
                        skipHorizontalWhitespaceAndComments()
                        if peek().kind == .leftBrace {
                            let grp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: "\\end")
                            mismatchEnd = grp.endPos
                        }
                        children.append(
                            emitIssue(
                                code: .mismatchedEnvironmentEnd,
                                severity: .error,
                                message: "Mismatched math environment: opened '\\begin{\(envName)}' but encountered '\\end{\(closingName)}'.",
                                span: TextSpan(filePath: filePath, start: mismatchStart, end: mismatchEnd),
                                suggestedFix: "\\end{\(envName)}",
                                recoveredConstruct: envName
                            )
                        )
                        endPos = mismatchEnd
                        closedCleanly = true
                        break
                    }
                } else if role == .sectioning {
                    let missingSpan = TextSpan(filePath: filePath, start: startPos, end: tok.span.start)
                    children.append(
                        emitIssue(
                            code: .missingEnvironmentEnd,
                            severity: .error,
                            message: "Unclosed math environment '\\begin{\(envName)}' recovered before '\(tok.lexeme)'.",
                            span: missingSpan,
                            suggestedFix: "\\end{\(envName)}",
                            recoveredConstruct: envName
                        )
                    )
                    endPos = tok.span.start
                    closedCleanly = true
                    break
                } else if role == .labelDeclaration {
                    let lblNode = parseLaTeXLabelDeclaration()
                    if case .labelDeclaration(let key) = lblNode.kind, detectedLabel == nil {
                        detectedLabel = key
                    }
                    children.append(lblNode)
                    continue
                } else if role == .citation {
                    let cites = parseLaTeXCitation()
                    children.append(contentsOf: cites)
                    continue
                } else if role == .crossReference {
                    let refs = parseLaTeXCrossReference()
                    children.append(contentsOf: refs)
                    continue
                }
            }
            if tok.kind != .comment {
                formulaTokens.append(tok.lexeme)
            }
            endPos = tok.span.end
            advance()
        }

        if !closedCleanly {
            endPos = peek().span.end
            children.append(
                emitIssue(
                    code: .missingEnvironmentEnd,
                    severity: .error,
                    message: "Unclosed math environment '\\begin{\(envName)}' at end of file.",
                    span: TextSpan(filePath: filePath, start: startPos, end: endPos),
                    suggestedFix: "\\end{\(envName)}",
                    recoveredConstruct: envName
                )
            )
        }

        let formulaSource = formulaTokens.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let mathNode = MarkupASTNode(
            kind: .mathExpression(isDisplayMode: true, formulaSource: formulaSource, label: detectedLabel),
            span: TextSpan(filePath: filePath, start: startPos, end: endPos)
        )
        children.insert(mathNode, at: 0)

        return MarkupASTNode(
            kind: .environment(name: envName, label: detectedLabel, caption: nil),
            span: TextSpan(filePath: filePath, start: startPos, end: endPos),
            children: children
        )
    }

    private mutating func parseLaTeXCaptionCommand() -> (captionText: String, semanticNodes: [MarkupASTNode]) {
        let cmdTok = advance() // `\caption`, `\captionof`, `\subcaption`
        var nodes: [MarkupASTNode] = []

        // `\captionof{figure}[short]{Long caption}` takes an extra `{type}` first argument.
        if cmdTok.lexeme == "\\captionof" {
            skipHorizontalWhitespaceAndComments()
            if peek().kind == .leftBrace {
                _ = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: "\\captionof")
            }
        }

        skipHorizontalWhitespaceAndComments()
        if peek().kind == .leftBracket {
            let opt = consumeBracketGroup(allowMultiline: true)
            if let rec = opt.recoveryNode {
                nodes.append(rec)
            }
            skipHorizontalWhitespaceAndComments()
        }

        guard peek().kind == .leftBrace else {
            return ("", nodes)
        }
        let body = consumeStructuredProseBraceGroup(constructName: cmdTok.lexeme)
        nodes.append(contentsOf: body.semanticNodes)
        if let rec = body.recoveryNode {
            nodes.append(rec)
        }
        return (body.cleanText, nodes)
    }

    // MARK: LaTeX Citations, Labels, Cross-References & Includes

    private mutating func parseLaTeXCitation() -> [MarkupASTNode] {
        let cmdTok = advance()
        let startPos = cmdTok.span.start
        var endPos = cmdTok.span.end
        var results: [MarkupASTNode] = []

        let isMultiCiteVariant = cmdTok.lexeme.hasSuffix("s") && (
            cmdTok.lexeme == "\\cites" || cmdTok.lexeme == "\\parencites"
            || cmdTok.lexeme == "\\textcites" || cmdTok.lexeme == "\\autocites"
        )

        repeat {
            let groupStart = results.isEmpty ? startPos : peek().span.start
            skipSameLineOrSingleNewlineWhitespace()

            // Collect 0, 1, or 2 optional `[...]` prenote/postnote arguments.
            var optArgs: [String] = []
            while optArgs.count < 2 && peek().kind == .leftBracket {
                let opt = consumeBracketGroup(allowMultiline: false)
                optArgs.append(opt.content.trimmingCharacters(in: .whitespacesAndNewlines))
                endPos = opt.endPos
                if let rec = opt.recoveryNode {
                    results.append(rec)
                }
                skipSameLineOrSingleNewlineWhitespace()
            }

            let prenote: String?
            let postnote: String?
            if optArgs.count == 1 {
                prenote = nil
                postnote = optArgs[0].isEmpty ? nil : optArgs[0]
            } else if optArgs.count >= 2 {
                prenote = optArgs[0].isEmpty ? nil : optArgs[0]
                postnote = optArgs[1].isEmpty ? nil : optArgs[1]
            } else {
                prenote = nil
                postnote = nil
            }

            guard peek().kind == .leftBrace else {
                if results.isEmpty {
                    let errNode = emitIssue(
                        code: .malformedCitationCommand,
                        severity: .error,
                        message: "Expected '{citekey}' argument after '\(cmdTok.lexeme)'.",
                        span: TextSpan(filePath: filePath, start: startPos, end: endPos),
                        suggestedFix: "\(cmdTok.lexeme){author2024}",
                        recoveredConstruct: cmdTok.lexeme
                    )
                    results.append(errNode)
                }
                break
            }

            let keyGroup = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: cmdTok.lexeme)
            endPos = keyGroup.endPos
            if let rec = keyGroup.recoveryNode {
                results.append(rec)
            }

            let keys = keyGroup.rawContent
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let citeSpan = TextSpan(filePath: filePath, start: groupStart, end: endPos)
            if keys.isEmpty && keyGroup.rawContent.trimmingCharacters(in: .whitespacesAndNewlines) != "*" {
                let errNode = emitIssue(
                    code: .malformedCitationCommand,
                    severity: .warning,
                    message: "Empty citation key list in '\(cmdTok.lexeme){}'.",
                    span: citeSpan,
                    recoveredConstruct: cmdTok.lexeme
                )
                results.append(errNode)
            } else {
                let finalKeys = keys.isEmpty ? ["*"] : keys
                results.append(
                    MarkupASTNode(
                        kind: .citation(
                            command: cmdTok.lexeme,
                            citeKeys: finalKeys,
                            prenote: prenote,
                            postnote: postnote
                        ),
                        span: citeSpan
                    )
                )
            }

            if !isMultiCiteVariant {
                break
            }
            skipHorizontalWhitespaceAndComments()
        } while peek().kind == .leftBracket || peek().kind == .leftBrace

        return results
    }

    private mutating func parseLaTeXLabelDeclaration() -> MarkupASTNode {
        let cmdTok = advance()
        let startPos = cmdTok.span.start
        skipHorizontalWhitespaceAndComments()

        guard peek().kind == .leftBrace else {
            return emitIssue(
                code: .emptyLabelKey,
                severity: .error,
                message: "Expected '{key}' after '\(cmdTok.lexeme)'.",
                span: cmdTok.span,
                suggestedFix: "\\label{sec:name}",
                recoveredConstruct: cmdTok.lexeme
            )
        }

        let grp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: cmdTok.lexeme)
        let key = grp.rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let span = TextSpan(filePath: filePath, start: startPos, end: grp.endPos)
        var children: [MarkupASTNode] = []
        if let rec = grp.recoveryNode {
            children.append(rec)
        }

        if key.isEmpty {
            let emptyIssue = emitIssue(
                code: .emptyLabelKey,
                severity: .warning,
                message: "Empty '\\label{}' key declaration.",
                span: span,
                recoveredConstruct: cmdTok.lexeme
            )
            children.append(emptyIssue)
        }

        return MarkupASTNode(
            kind: .labelDeclaration(key: key),
            span: span,
            children: children
        )
    }

    private mutating func parseLaTeXCrossReference() -> [MarkupASTNode] {
        let cmdTok = advance()
        let startPos = cmdTok.span.start
        skipHorizontalWhitespaceAndComments()

        // `\hyperref[sec:intro]{Section 1}` places the target label inside `[...]`!
        if cmdTok.lexeme == "\\hyperref" && peek().kind == .leftBracket {
            let targetBracket = consumeBracketGroup(allowMultiline: false)
            var endPos = targetBracket.endPos
            skipHorizontalWhitespaceAndComments()
            if peek().kind == .leftBrace {
                let anchor = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: "\\hyperref")
                endPos = anchor.endPos
            }
            let key = targetBracket.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                MarkupASTNode(
                    kind: .crossReference(command: cmdTok.lexeme, targetKey: key),
                    span: TextSpan(filePath: filePath, start: startPos, end: endPos)
                )
            ]
        }

        guard peek().kind == .leftBrace else {
            return [
                emitIssue(
                    code: .malformedCrossReference,
                    severity: .error,
                    message: "Expected '{label}' target after '\(cmdTok.lexeme)'.",
                    span: cmdTok.span,
                    suggestedFix: "\(cmdTok.lexeme){sec:intro}",
                    recoveredConstruct: cmdTok.lexeme
                )
            ]
        }

        let grp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: cmdTok.lexeme)
        let span = TextSpan(filePath: filePath, start: startPos, end: grp.endPos)
        let keys = grp.rawContent
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if keys.isEmpty {
            return [
                emitIssue(
                    code: .malformedCrossReference,
                    severity: .warning,
                    message: "Empty cross-reference target in '\(cmdTok.lexeme){}'.",
                    span: span,
                    recoveredConstruct: cmdTok.lexeme
                )
            ]
        }

        var nodes: [MarkupASTNode] = keys.map { key in
            MarkupASTNode(
                kind: .crossReference(command: cmdTok.lexeme, targetKey: key),
                span: span
            )
        }
        if let rec = grp.recoveryNode {
            nodes.append(rec)
        }
        return nodes
    }

    private mutating func parseLaTeXFileInclude() -> [MarkupASTNode] {
        let cmdTok = advance()
        let startPos = cmdTok.span.start
        skipHorizontalWhitespaceAndComments()

        // `\addbibresource[type=file]{library.bib}` may carry an optional `[...]` first.
        if peek().kind == .leftBracket {
            _ = consumeBracketGroup(allowMultiline: false)
            skipHorizontalWhitespaceAndComments()
        }

        // `\import{sections/}{intro.tex}` or `\subimport{sections/}{intro.tex}` takes TWO brace groups!
        if cmdTok.lexeme == "\\import" || cmdTok.lexeme == "\\subimport" {
            guard peek().kind == .leftBrace else {
                return [
                    emitIssue(
                        code: .malformedFileInclude,
                        severity: .error,
                        message: "Expected '{directory}{filename}' after '\(cmdTok.lexeme)'.",
                        span: cmdTok.span,
                        recoveredConstruct: cmdTok.lexeme
                    )
                ]
            }
            let dirGrp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: cmdTok.lexeme)
            skipHorizontalWhitespaceAndComments()
            var fileStr = ""
            var endPos = dirGrp.endPos
            if peek().kind == .leftBrace {
                let fileGrp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: cmdTok.lexeme)
                fileStr = fileGrp.rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
                endPos = fileGrp.endPos
            }
            let dirStr = dirGrp.rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let combined: String
            if dirStr.isEmpty {
                combined = fileStr
            } else if dirStr.hasSuffix("/") {
                combined = dirStr + fileStr
            } else {
                combined = dirStr + "/" + fileStr
            }
            return [
                MarkupASTNode(
                    kind: .fileInclude(command: cmdTok.lexeme, targetPath: combined),
                    span: TextSpan(filePath: filePath, start: startPos, end: endPos)
                )
            ]
        }

        guard peek().kind == .leftBrace else {
            // Plain TeX `\input sections/intro.tex` unbraced syntax fallback!
            var pathChars = ""
            var endPos = cmdTok.span.end
            while !isAtEnd {
                let t = peek()
                if t.kind == .whitespace || t.kind == .comment || t.kind == .leftBrace || t.kind == .rightBrace {
                    break
                }
                pathChars.append(t.lexeme)
                endPos = t.span.end
                advance()
            }
            let cleaned = pathChars.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return [
                    MarkupASTNode(
                        kind: .fileInclude(command: cmdTok.lexeme, targetPath: cleaned),
                        span: TextSpan(filePath: filePath, start: startPos, end: endPos)
                    )
                ]
            }
            return [
                emitIssue(
                    code: .malformedFileInclude,
                    severity: .error,
                    message: "Expected '{filepath}' after '\(cmdTok.lexeme)'.",
                    span: cmdTok.span,
                    recoveredConstruct: cmdTok.lexeme
                )
            ]
        }

        let grp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: cmdTok.lexeme)
        let span = TextSpan(filePath: filePath, start: startPos, end: grp.endPos)
        let rawTarget = grp.rawContent.trimmingCharacters(in: .whitespacesAndNewlines)

        // `\bibliography{refs,methods_bib}` supports comma-separated `.bib` files.
        let targets: [String]
        if cmdTok.lexeme == "\\bibliography" || cmdTok.lexeme == "\\nobibliography" || cmdTok.lexeme == "\\includeonly" {
            targets = rawTarget
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            targets = rawTarget.isEmpty ? [] : [rawTarget]
        }

        var nodes: [MarkupASTNode] = targets.map { path in
            MarkupASTNode(kind: .fileInclude(command: cmdTok.lexeme, targetPath: path), span: span)
        }
        if nodes.isEmpty {
            nodes.append(
                emitIssue(
                    code: .malformedFileInclude,
                    severity: .warning,
                    message: "Empty file path in '\(cmdTok.lexeme){}'.",
                    span: span,
                    recoveredConstruct: cmdTok.lexeme
                )
            )
        }
        if let rec = grp.recoveryNode {
            nodes.append(rec)
        }
        return nodes
    }

    // MARK: LaTeX Macro Definitions (`\newcommand`, `\renewcommand`, `\DeclareMathOperator`, `\def`)

    private mutating func parseLaTeXMacroDefinition() -> [MarkupASTNode] {
        let cmdTok = advance()
        let startPos = cmdTok.span.start
        var endPos = cmdTok.span.end
        var recoveryNodes: [MarkupASTNode] = []

        skipHorizontalWhitespaceAndComments()

        // TeX primitive `\def\foo#1#2{body}`
        if cmdTok.lexeme == "\\def" || cmdTok.lexeme == "\\gdef" || cmdTok.lexeme == "\\edef" || cmdTok.lexeme == "\\xdef" {
            guard peek().kind == .command else {
                let err = emitIssue(
                    code: .malformedMacroDefinition,
                    severity: .error,
                    message: "Expected macro control sequence after '\(cmdTok.lexeme)'.",
                    span: cmdTok.span,
                    suggestedFix: "\\def\\mycmd{replacement}",
                    recoveredConstruct: cmdTok.lexeme
                )
                synchronizeToEndOfLine()
                return [err]
            }
            let nameTok = advance()
            let macroName = nameTok.lexeme
            endPos = nameTok.span.end

            // Scan `#1#2...` parameter template up to `{`.
            var highestParam = 0
            while !isAtEnd && peek().kind != .leftBrace {
                let t = peek()
                if t.kind == .whitespace && (t.lexeme.contains("\n") || t.lexeme.contains("\r")) {
                    break
                }
                if t.kind == .identifier && t.lexeme.count == 2 && t.lexeme.hasPrefix("#") {
                    if let digit = Int(t.lexeme.dropFirst()), digit > highestParam {
                        highestParam = digit
                    }
                }
                endPos = t.span.end
                advance()
            }

            guard peek().kind == .leftBrace else {
                let err = emitIssue(
                    code: .malformedMacroDefinition,
                    severity: .error,
                    message: "Missing '{replacement}' body for '\(cmdTok.lexeme)\(macroName)'.",
                    span: TextSpan(filePath: filePath, start: startPos, end: endPos),
                    recoveredConstruct: macroName
                )
                return [err]
            }
            let bodyGrp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: macroName)
            endPos = bodyGrp.endPos
            if let rec = bodyGrp.recoveryNode {
                recoveryNodes.append(rec)
            }
            let node = MarkupASTNode(
                kind: .macroDefinition(
                    name: macroName,
                    parameterCount: highestParam,
                    replacementBody: bodyGrp.rawContent
                ),
                span: TextSpan(filePath: filePath, start: startPos, end: endPos),
                children: recoveryNodes
            )
            return [node]
        }

        // Standard LaTeX `\newcommand{\R}[1][\mathbb{R}]{#1^n}` or `\newcommand\R[1]{#1}` or `\DeclareMathOperator{\argmin}{arg\,min}`
        var macroName = ""
        if peek().kind == .leftBrace {
            let nameGrp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: cmdTok.lexeme)
            macroName = nameGrp.rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            endPos = nameGrp.endPos
            if let rec = nameGrp.recoveryNode {
                recoveryNodes.append(rec)
            }
        } else if peek().kind == .command {
            let nameTok = advance()
            macroName = nameTok.lexeme
            endPos = nameTok.span.end
        } else {
            let err = emitIssue(
                code: .malformedMacroDefinition,
                severity: .error,
                message: "Expected '{\\name}' after '\(cmdTok.lexeme)'.",
                span: cmdTok.span,
                suggestedFix: "\(cmdTok.lexeme){\\macroName}{body}",
                recoveredConstruct: cmdTok.lexeme
            )
            synchronizeToEndOfLine()
            return [err]
        }

        skipSameLineOrSingleNewlineWhitespace()

        var paramCount = 0
        // xparse `\NewDocumentCommand{\foo}{m o}{...}` argument specification `{...}` vs `[n][default]`
        if cmdTok.lexeme.hasSuffix("DocumentCommand") && peek().kind == .leftBrace {
            let argSpecGrp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: cmdTok.lexeme)
            endPos = argSpecGrp.endPos
            paramCount = argSpecGrp.rawContent.filter { $0 == "m" || $0 == "o" || $0 == "O" }.count
            if let rec = argSpecGrp.recoveryNode {
                recoveryNodes.append(rec)
            }
            skipSameLineOrSingleNewlineWhitespace()
        } else if !cmdTok.lexeme.hasPrefix("\\DeclareMathOperator") {
            if peek().kind == .leftBracket {
                let countBracket = consumeBracketGroup(allowMultiline: false)
                endPos = countBracket.endPos
                if let parsedCount = Int(countBracket.content.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    paramCount = max(0, min(9, parsedCount))
                }
                if let rec = countBracket.recoveryNode {
                    recoveryNodes.append(rec)
                }
                skipSameLineOrSingleNewlineWhitespace()
            }
            // Optional default value for `#1`: `[default]`
            if peek().kind == .leftBracket {
                let defaultBracket = consumeBracketGroup(allowMultiline: true)
                endPos = defaultBracket.endPos
                if let rec = defaultBracket.recoveryNode {
                    recoveryNodes.append(rec)
                }
                skipSameLineOrSingleNewlineWhitespace()
            }
        }

        guard peek().kind == .leftBrace else {
            let err = emitIssue(
                code: .malformedMacroDefinition,
                severity: .error,
                message: "Missing '{replacement}' body in '\(cmdTok.lexeme)' for '\(macroName)'.",
                span: TextSpan(filePath: filePath, start: startPos, end: endPos),
                suggestedFix: "\(cmdTok.lexeme){\(macroName)}{...}",
                recoveredConstruct: macroName
            )
            return [err]
        }

        let bodyGrp = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: macroName)
        endPos = bodyGrp.endPos
        if let rec = bodyGrp.recoveryNode {
            recoveryNodes.append(rec)
        }

        let replacementBody: String
        if cmdTok.lexeme == "\\DeclareMathOperator*" {
            replacementBody = "\\operatorname*{\(bodyGrp.rawContent)}"
        } else if cmdTok.lexeme == "\\DeclareMathOperator" {
            replacementBody = "\\operatorname{\(bodyGrp.rawContent)}"
        } else {
            replacementBody = bodyGrp.rawContent
        }

        let macroNode = MarkupASTNode(
            kind: .macroDefinition(
                name: macroName,
                parameterCount: paramCount,
                replacementBody: replacementBody
            ),
            span: TextSpan(filePath: filePath, start: startPos, end: endPos),
            children: recoveryNodes
        )
        return [macroNode]
    }

    private mutating func synchronizeToEndOfLine() {
        while !isAtEnd {
            let t = peek()
            if t.kind == .whitespace && (t.lexeme.contains("\n") || t.lexeme.contains("\r")) {
                break
            }
            if t.kind == .command {
                let role = LaTeXCommandRole.classify(t.lexeme)
                if role == .sectioning || role == .environmentBegin || role == .environmentEnd {
                    break
                }
            }
            advance()
        }
    }

    // MARK: LaTeX Math Delimiters (`$...$`, `$$...$$`, `\(...\)`, `\[...\]`)

    private mutating func parseLaTeXMath(isDisplay: Bool) -> [MarkupASTNode] {
        let openTok = advance()
        let startPos = openTok.span.start

        // Stray closing delimiter `\)` or `\]` with no open delimiter:
        if openTok.lexeme == "\\)" || openTok.lexeme == "\\]" {
            let err = emitIssue(
                code: isDisplay ? .unclosedDisplayMath : .unclosedInlineMath,
                severity: .error,
                message: "Unexpected closing math delimiter '\(openTok.lexeme)' without matching opener.",
                span: openTok.span,
                recoveredConstruct: openTok.lexeme
            )
            return [err]
        }

        let expectedCloseLexeme: String
        switch openTok.lexeme {
        case "\\[": expectedCloseLexeme = "\\]"
        case "\\(": expectedCloseLexeme = "\\)"
        case "$$": expectedCloseLexeme = "$$"
        default: expectedCloseLexeme = "$"
        }

        var formulaParts: [String] = []
        var detectedLabel: String? = nil
        var childNodes: [MarkupASTNode] = []
        var endPos = openTok.span.end
        var closed = false

        while !isAtEnd {
            let tok = peek()

            // Matching closing delimiter!
            if (tok.kind == .mathDisplay || tok.kind == .mathInline) && tok.lexeme == expectedCloseLexeme {
                endPos = tok.span.end
                advance()
                closed = true
                break
            }

            // Recovery boundary 1: inline `$` or `\(` never spans across a blank paragraph break (`\n\n`) in valid TeX!
            if !isDisplay && tok.kind == .whitespace {
                let (newlines, _) = countConsecutiveNewlines(startingAt: index)
                if newlines >= 2 {
                    break
                }
            }

            // Recovery boundary 2: encountering `\section`, `\subsection`, or an outer `\end{...}` / `\begin{figure}`
            // while inside unclosed math must recover immediately so downstream manuscript structure stays intact!
            if tok.kind == .command {
                let role = LaTeXCommandRole.classify(tok.lexeme)
                if role == .sectioning || role == .appendixSwitch {
                    break
                }
                if role == .environmentEnd {
                    let closingEnv = peekLaTeXEnvironmentName(atCommandIndex: index) ?? ""
                    if closingEnv == "document" || activeEnvironmentStack.contains(closingEnv) {
                        break
                    }
                }
                if !isDisplay && role == .environmentBegin {
                    let openingEnv = peekLaTeXEnvironmentName(atCommandIndex: index) ?? ""
                    if !Self.inlineMathAllowedSubEnvironments.contains(openingEnv) {
                        break
                    }
                }
                if role == .labelDeclaration {
                    let lblNode = parseLaTeXLabelDeclaration()
                    if case .labelDeclaration(let key) = lblNode.kind, detectedLabel == nil {
                        detectedLabel = key
                    }
                    childNodes.append(lblNode)
                    endPos = lblNode.span.end
                    continue
                }
            }

            if tok.kind != .comment {
                formulaParts.append(tok.lexeme)
            }
            endPos = tok.span.end
            advance()
        }

        if !closed {
            let span = TextSpan(filePath: filePath, start: startPos, end: endPos)
            let errNode = emitIssue(
                code: isDisplay ? .unclosedDisplayMath : .unclosedInlineMath,
                severity: .error,
                message: "Unclosed math delimiter '\(openTok.lexeme)'; expected matching '\(expectedCloseLexeme)'.",
                span: span,
                suggestedFix: expectedCloseLexeme,
                recoveredConstruct: openTok.lexeme
            )
            childNodes.append(errNode)
        }

        let formula = formulaParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let mathNode = MarkupASTNode(
            kind: .mathExpression(isDisplayMode: isDisplay, formulaSource: formula, label: detectedLabel),
            span: TextSpan(filePath: filePath, start: startPos, end: endPos),
            children: childNodes
        )
        return [mathNode]
    }

    private static let inlineMathAllowedSubEnvironments: Set<String> = [
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix",
        "smallmatrix", "cases", "aligned", "array", "split"
    ]

    // MARK: LaTeX Inline Braced & Formatting Helpers

    private mutating func parseInlineFormattingCommand(into paragraph: inout ParagraphAccumulator) {
        let cmd = advance()
        skipHorizontalWhitespaceAndComments()
        guard peek().kind == .leftBrace else { return }
        let grp = consumeStructuredProseBraceGroup(constructName: cmd.lexeme)
        if !grp.cleanText.isEmpty {
            paragraph.recordProseFragment(
                grp.cleanText,
                span: TextSpan(filePath: filePath, start: cmd.span.start, end: grp.endPos)
            )
        }
        for sem in grp.semanticNodes {
            paragraph.recordInlineSemanticNode(sem)
        }
        if let rec = grp.recoveryNode {
            paragraph.recordInlineSemanticNode(rec)
        }
    }

    private mutating func parseInlineBracedGroup(into paragraph: inout ParagraphAccumulator) {
        let start = peek().span.start
        let grp = consumeStructuredProseBraceGroup(constructName: "{...}")
        if !grp.cleanText.isEmpty {
            paragraph.recordProseFragment(
                grp.cleanText,
                span: TextSpan(filePath: filePath, start: start, end: grp.endPos)
            )
        }
        for sem in grp.semanticNodes {
            paragraph.recordInlineSemanticNode(sem)
        }
        if let rec = grp.recoveryNode {
            paragraph.recordInlineSemanticNode(rec)
        }
    }

    private func renderLaTeXControlSymbol(_ lexeme: String) -> String? {
        switch lexeme {
        case "\\%": return "%"
        case "\\$": return "$"
        case "\\&": return "&"
        case "\\_": return "_"
        case "\\#": return "#"
        case "\\{": return "{"
        case "\\}": return "}"
        case "\\ ": return " "
        default: return nil
        }
    }

    // MARK: Balanced `{...}` and `[...]` Group Consumers with Error Recovery

    private mutating func consumeBraceGroupRaw(
        recoverAtStructuralBoundary: Bool,
        constructName: String
    ) -> (rawContent: String, endPos: TextPosition, recoveryNode: MarkupASTNode?) {
        let openTok = advance() // `{`
        let startPos = openTok.span.start
        var endPos = openTok.span.end
        var depth = 1
        var pieces: [String] = []

        while !isAtEnd && depth > 0 {
            let tok = peek()

            if tok.kind == .leftBrace {
                depth += 1
                pieces.append(tok.lexeme)
                endPos = tok.span.end
                advance()
                continue
            }
            if tok.kind == .rightBrace {
                depth -= 1
                endPos = tok.span.end
                advance()
                if depth > 0 {
                    pieces.append(tok.lexeme)
                }
                continue
            }

            if recoverAtStructuralBoundary && tok.kind == .command {
                let role = LaTeXCommandRole.classify(tok.lexeme)
                if role == .sectioning || role == .appendixSwitch {
                    break
                }
                if role == .environmentEnd {
                    let closingEnv = peekLaTeXEnvironmentName(atCommandIndex: index) ?? ""
                    if closingEnv == "document" || activeEnvironmentStack.contains(closingEnv) {
                        break
                    }
                }
            }

            if recoverAtStructuralBoundary && tok.kind == .whitespace {
                let (newlines, _) = countConsecutiveNewlines(startingAt: index)
                if newlines >= 2 && constructName != "\\newcommand" && constructName != "\\renewcommand" && constructName != "\\providecommand" {
                    break
                }
            }

            if tok.kind != .comment {
                pieces.append(tok.lexeme)
            }
            endPos = tok.span.end
            advance()
        }

        var recoveryNode: MarkupASTNode? = nil
        if depth > 0 {
            let span = TextSpan(filePath: filePath, start: startPos, end: endPos)
            recoveryNode = emitIssue(
                code: .unclosedBrace,
                severity: .error,
                message: "Unclosed '{' in '\(constructName)'; recovered before structural boundary.",
                span: span,
                suggestedFix: "}",
                recoveredConstruct: constructName
            )
        }

        return (pieces.joined(), endPos, recoveryNode)
    }

    private mutating func consumeStructuredProseBraceGroup(
        constructName: String
    ) -> (cleanText: String, endPos: TextPosition, semanticNodes: [MarkupASTNode], recoveryNode: MarkupASTNode?) {
        let openTok = advance() // `{`
        let startPos = openTok.span.start
        var endPos = openTok.span.end
        var depth = 1
        var textFragments: [String] = []
        var semanticNodes: [MarkupASTNode] = []

        while !isAtEnd && depth > 0 {
            let tok = peek()

            if tok.kind == .leftBrace {
                depth += 1
                endPos = tok.span.end
                advance()
                continue
            }
            if tok.kind == .rightBrace {
                depth -= 1
                endPos = tok.span.end
                advance()
                continue
            }

            // Recover cleanly if someone forgot `}` at the end of `\section{Introduction\n\nWe propose...`
            if tok.kind == .whitespace {
                let (newlines, _) = countConsecutiveNewlines(startingAt: index)
                if newlines >= 2 {
                    break
                }
                textFragments.append(" ")
                endPos = tok.span.end
                advance()
                continue
            }

            if tok.kind == .command {
                let role = LaTeXCommandRole.classify(tok.lexeme)
                if role == .sectioning || role == .environmentBegin || role == .environmentEnd {
                    break
                }
                if role == .citation {
                    let cites = parseLaTeXCitation()
                    semanticNodes.append(contentsOf: cites)
                    if let last = cites.last { endPos = last.span.end }
                    continue
                }
                if role == .crossReference {
                    let refs = parseLaTeXCrossReference()
                    semanticNodes.append(contentsOf: refs)
                    if let last = refs.last { endPos = last.span.end }
                    continue
                }
                if role == .labelDeclaration {
                    let lbl = parseLaTeXLabelDeclaration()
                    semanticNodes.append(lbl)
                    endPos = lbl.span.end
                    continue
                }
                if role == .controlSymbol {
                    if let rendered = renderLaTeXControlSymbol(tok.lexeme) {
                        textFragments.append(rendered)
                    }
                    endPos = tok.span.end
                    advance()
                    continue
                }
                // Formatting or inline command inside title/caption: skip command token, keep inner prose!
                endPos = tok.span.end
                advance()
                continue
            }

            if tok.kind == .mathInline || tok.kind == .mathDisplay {
                let mathNodes = parseLaTeXMath(isDisplay: tok.kind == .mathDisplay)
                semanticNodes.append(contentsOf: mathNodes)
                for m in mathNodes {
                    if case .mathExpression(_, let formula, _) = m.kind {
                        textFragments.append("$\(formula)$")
                    }
                    endPos = m.span.end
                }
                continue
            }

            if tok.kind != .comment {
                textFragments.append(tok.lexeme == "~" ? " " : tok.lexeme)
            }
            endPos = tok.span.end
            advance()
        }

        var recoveryNode: MarkupASTNode? = nil
        if depth > 0 {
            let span = TextSpan(filePath: filePath, start: startPos, end: endPos)
            recoveryNode = emitIssue(
                code: .unclosedBrace,
                severity: .error,
                message: "Unclosed '{' in '\(constructName)'; recovered cleanly.",
                span: span,
                suggestedFix: "}",
                recoveredConstruct: constructName
            )
        }

        let clean = normalizeWhitespace(textFragments.joined())
        return (clean, endPos, semanticNodes, recoveryNode)
    }

    private mutating func consumeBracketGroup(
        allowMultiline: Bool
    ) -> (content: String, endPos: TextPosition, recoveryNode: MarkupASTNode?) {
        let openTok = advance() // `[`
        let startPos = openTok.span.start
        var endPos = openTok.span.end
        var bracketDepth = 1
        var braceDepth = 0
        var parts: [String] = []

        while !isAtEnd && bracketDepth > 0 {
            let tok = peek()

            if tok.kind == .leftBrace {
                braceDepth += 1
                parts.append(tok.lexeme)
                endPos = tok.span.end
                advance()
                continue
            }
            if tok.kind == .rightBrace {
                if braceDepth > 0 {
                    braceDepth -= 1
                    parts.append(tok.lexeme)
                    endPos = tok.span.end
                    advance()
                    continue
                } else {
                    break
                }
            }
            if tok.kind == .leftBracket && braceDepth == 0 {
                bracketDepth += 1
                parts.append(tok.lexeme)
                endPos = tok.span.end
                advance()
                continue
            }
            if tok.kind == .rightBracket && braceDepth == 0 {
                bracketDepth -= 1
                endPos = tok.span.end
                advance()
                if bracketDepth > 0 {
                    parts.append(tok.lexeme)
                }
                continue
            }

            if !allowMultiline && tok.kind == .whitespace && (tok.lexeme.contains("\n") || tok.lexeme.contains("\r")) {
                break
            }
            if allowMultiline && tok.kind == .whitespace {
                let (newlines, _) = countConsecutiveNewlines(startingAt: index)
                if newlines >= 2 {
                    break
                }
            }

            if tok.kind != .comment {
                parts.append(tok.lexeme)
            }
            endPos = tok.span.end
            advance()
        }

        var recoveryNode: MarkupASTNode? = nil
        if bracketDepth > 0 {
            let span = TextSpan(filePath: filePath, start: startPos, end: endPos)
            recoveryNode = emitIssue(
                code: .unclosedBracket,
                severity: .error,
                message: "Unclosed '[' optional argument group.",
                span: span,
                suggestedFix: "]"
            )
        }
        return (parts.joined(), endPos, recoveryNode)
    }

    // MARK: - 2. Typst Top-Level & Block Item Dispatch

    private mutating func parseNextTypstItem(
        paragraph: inout ParagraphAccumulator,
        sectionStack: inout [OpenSectionFrame],
        topLevelNodes: inout [MarkupASTNode]
    ) {
        let tok = peek()

        switch tok.kind {
        case .headingMarker:
            flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
            parseTypstHeading(sectionStack: &sectionStack, topLevelNodes: &topLevelNodes)

        case .typstHashKeyword:
            let role = TypstDirectiveRole.classify(tok.lexeme)
            switch role {
            case .shorthandReference:
                let node = parseTypstShorthandAtReference()
                paragraph.recordInlineSemanticNode(node)

            case .citeCall:
                let node = parseTypstCiteCall()
                paragraph.recordInlineSemanticNode(node)

            case .refCall:
                let node = parseTypstRefCall()
                paragraph.recordInlineSemanticNode(node)

            case .letBinding:
                flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                let macroNode = parseTypstLetMacro()
                appendNode(macroNode, intoSections: &sectionStack, orTopLevel: &topLevelNodes)

            case .includeFile, .importModule, .bibliographyCall:
                flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                if let incNode = parseTypstFileIncludeOrBib() {
                    appendNode(incNode, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                }

            case .figureCall, .tableCall:
                flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                let envNode = parseTypstFigureOrTable()
                appendNode(envNode, intoSections: &sectionStack, orTopLevel: &topLevelNodes)

            case .setRule, .showRule:
                flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                consumeTypstStatementLine()

            case .headingCall, .mathEquationCall, .generalHashDirective:
                advance()
            }

        case .identifier where tok.lexeme.hasPrefix("<") && tok.lexeme.hasSuffix(">"):
            let lblTok = advance()
            let key = String(lblTok.lexeme.dropFirst().dropLast())
            let lblNode = MarkupASTNode(kind: .labelDeclaration(key: key), span: lblTok.span)
            paragraph.recordInlineSemanticNode(lblNode)

        case .mathInline:
            let mathResult = parseTypstMath()
            if mathResult.isDisplay {
                flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
                appendNode(mathResult.node, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
            } else {
                paragraph.recordInlineSemanticNode(mathResult.node)
            }

        case .textWord, .numeric, .identifier, .punctuation, .leftBracket, .rightBracket, .leftBrace, .rightBrace, .command, .mathDisplay:
            let t = advance()
            paragraph.recordProseFragment(t.lexeme, span: t.span)

        case .whitespace, .comment, .eof:
            advance()
        }
    }

    private mutating func parseTypstHeading(
        sectionStack: inout [OpenSectionFrame],
        topLevelNodes: inout [MarkupASTNode]
    ) {
        let marker = advance()
        let level = max(1, marker.lexeme.count)
        let startPos = marker.span.start
        var endPos = marker.span.end
        var titleTokens: [String] = []
        var sectionLabel: String? = nil
        var children: [MarkupASTNode] = []

        skipHorizontalWhitespaceAndComments()

        while !isAtEnd {
            let t = peek()
            if t.kind == .whitespace && (t.lexeme.contains("\n") || t.lexeme.contains("\r")) {
                break
            }
            if t.kind == .identifier && t.lexeme.hasPrefix("<") && t.lexeme.hasSuffix(">") {
                let key = String(t.lexeme.dropFirst().dropLast())
                sectionLabel = key
                children.append(MarkupASTNode(kind: .labelDeclaration(key: key), span: t.span))
                endPos = t.span.end
                advance()
                continue
            }
            if t.kind != .comment {
                titleTokens.append(t.lexeme)
            }
            endPos = t.span.end
            advance()
        }

        let cleanTitle = normalizeWhitespace(titleTokens.joined())
        openSection(
            level: level,
            title: cleanTitle.isEmpty ? "Untitled" : cleanTitle,
            label: sectionLabel,
            startPos: startPos,
            endOfHeaderPos: endPos,
            initialChildren: children,
            sectionStack: &sectionStack,
            topLevelNodes: &topLevelNodes
        )
    }

    private mutating func parseTypstShorthandAtReference() -> MarkupASTNode {
        let tok = advance() // `@key`
        let key = String(tok.lexeme.dropFirst())
        var endPos = tok.span.end
        var supplement: String? = nil

        // Optional Typst supplement `@vaswani2017[p. 42]`
        if peek().kind == .leftBracket {
            let brk = consumeBracketGroup(allowMultiline: false)
            let trimmed = brk.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                supplement = trimmed
            }
            endPos = brk.endPos
        }

        let span = TextSpan(filePath: filePath, start: tok.span.start, end: endPos)
        let isKnownLabel = declaredTypstLabels.contains(key)
            || Self.typstCrossRefPrefixes.contains(where: { key.hasPrefix($0) })

        if isKnownLabel {
            return MarkupASTNode(kind: .crossReference(command: "@", targetKey: key), span: span)
        } else {
            return MarkupASTNode(
                kind: .citation(command: "@", citeKeys: [key], prenote: nil, postnote: supplement),
                span: span
            )
        }
    }

    private mutating func parseTypstCiteCall() -> MarkupASTNode {
        let cmdTok = advance() // `#cite`
        let startPos = cmdTok.span.start
        var endPos = cmdTok.span.end
        var keys: [String] = []
        var supplement: String? = nil

        if peek().kind == .punctuation && peek().lexeme == "(" {
            let args = consumeParenthesizedTypstArgs()
            endPos = args.endPos
            for token in args.innerTokens {
                if token.kind == .identifier && token.lexeme.hasPrefix("<") && token.lexeme.hasSuffix(">") {
                    keys.append(String(token.lexeme.dropFirst().dropLast()))
                } else if token.kind == .identifier && token.lexeme.hasPrefix("\"") && token.lexeme.hasSuffix("\"") && token.lexeme.count >= 2 {
                    keys.append(String(token.lexeme.dropFirst().dropLast()))
                }
            }
            // Extract `supplement: [...]` if present
            if let suppRange = args.rawText.range(of: "supplement:") {
                let after = args.rawText[suppRange.upperBound...].trimmingCharacters(in: .whitespaces)
                if after.hasPrefix("["), let closeIdx = after.firstIndex(of: "]") {
                    let inner = String(after[after.index(after: after.startIndex)..<closeIdx])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !inner.isEmpty {
                        supplement = inner
                    }
                }
            }
        }

        return MarkupASTNode(
            kind: .citation(command: "#cite", citeKeys: keys, prenote: nil, postnote: supplement),
            span: TextSpan(filePath: filePath, start: startPos, end: endPos)
        )
    }

    private mutating func parseTypstRefCall() -> MarkupASTNode {
        let cmdTok = advance() // `#ref`
        let startPos = cmdTok.span.start
        var endPos = cmdTok.span.end
        var target = ""

        if peek().kind == .punctuation && peek().lexeme == "(" {
            let args = consumeParenthesizedTypstArgs()
            endPos = args.endPos
            for token in args.innerTokens {
                if token.kind == .identifier && token.lexeme.hasPrefix("<") && token.lexeme.hasSuffix(">") {
                    target = String(token.lexeme.dropFirst().dropLast())
                    break
                }
            }
        }
        return MarkupASTNode(
            kind: .crossReference(command: "#ref", targetKey: target),
            span: TextSpan(filePath: filePath, start: startPos, end: endPos)
        )
    }

    private mutating func parseTypstLetMacro() -> MarkupASTNode {
        let letTok = advance() // `#let`
        let startPos = letTok.span.start
        var endPos = letTok.span.end
        skipHorizontalWhitespaceAndComments()

        var name = "unnamed"
        if peek().kind == .textWord || peek().kind == .identifier {
            let nameTok = advance()
            name = nameTok.lexeme
            endPos = nameTok.span.end
        }

        var paramCount = 0
        if peek().kind == .punctuation && peek().lexeme == "(" {
            let params = consumeParenthesizedTypstArgs()
            endPos = params.endPos
            let trimmed = params.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                paramCount = trimmed.split(separator: ",").count
            }
        }

        skipHorizontalWhitespaceAndComments()
        if peek().kind == .punctuation && peek().lexeme == "=" {
            endPos = advance().span.end
        }
        skipHorizontalWhitespaceAndComments()

        // Collect RHS expression until newline (respecting nested `(...)`, `{...}`, `[...]`).
        var bodyParts: [String] = []
        var parenDepth = 0
        var braceDepth = 0
        var bracketDepth = 0

        while !isAtEnd {
            let t = peek()
            if parenDepth == 0 && braceDepth == 0 && bracketDepth == 0 {
                if t.kind == .whitespace && (t.lexeme.contains("\n") || t.lexeme.contains("\r")) {
                    break
                }
            }
            if t.kind == .punctuation && t.lexeme == "(" { parenDepth += 1 }
            else if t.kind == .punctuation && t.lexeme == ")" && parenDepth > 0 { parenDepth -= 1 }
            else if t.kind == .leftBrace { braceDepth += 1 }
            else if t.kind == .rightBrace && braceDepth > 0 { braceDepth -= 1 }
            else if t.kind == .leftBracket { bracketDepth += 1 }
            else if t.kind == .rightBracket && bracketDepth > 0 { bracketDepth -= 1 }

            if t.kind != .comment {
                bodyParts.append(t.lexeme)
            }
            endPos = t.span.end
            advance()
        }

        let body = bodyParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return MarkupASTNode(
            kind: .macroDefinition(name: name, parameterCount: paramCount, replacementBody: body),
            span: TextSpan(filePath: filePath, start: startPos, end: endPos)
        )
    }

    private mutating func parseTypstFileIncludeOrBib() -> MarkupASTNode? {
        let dirTok = advance() // `#include`, `#import`, `#bibliography`
        let startPos = dirTok.span.start
        var endPos = dirTok.span.end
        var extractedPath: String? = nil

        skipHorizontalWhitespaceAndComments()
        if peek().kind == .punctuation && peek().lexeme == "(" {
            let args = consumeParenthesizedTypstArgs()
            endPos = args.endPos
            for token in args.innerTokens {
                if token.kind == .identifier && token.lexeme.hasPrefix("\"") && token.lexeme.hasSuffix("\"") && token.lexeme.count >= 2 {
                    extractedPath = String(token.lexeme.dropFirst().dropLast())
                    break
                }
            }
        } else {
            while !isAtEnd {
                let t = peek()
                if t.kind == .whitespace && (t.lexeme.contains("\n") || t.lexeme.contains("\r")) {
                    break
                }
                if t.kind == .identifier && t.lexeme.hasPrefix("\"") && t.lexeme.hasSuffix("\"") && t.lexeme.count >= 2 && extractedPath == nil {
                    extractedPath = String(t.lexeme.dropFirst().dropLast())
                }
                endPos = t.span.end
                advance()
            }
        }

        // Ignore Typst package imports like `@preview/charged-ieee:0.1.0` in `#import "@preview/..."`
        if let path = extractedPath, !path.hasPrefix("@") {
            return MarkupASTNode(
                kind: .fileInclude(command: dirTok.lexeme, targetPath: path),
                span: TextSpan(filePath: filePath, start: startPos, end: endPos)
            )
        }
        return nil
    }

    private mutating func parseTypstFigureOrTable() -> MarkupASTNode {
        let dirTok = advance() // `#figure` or `#table`
        let envName = dirTok.lexeme == "#table" ? "table" : "figure"
        let startPos = dirTok.span.start
        var endPos = dirTok.span.end
        var caption: String? = nil
        var label: String? = nil
        var children: [MarkupASTNode] = []

        skipHorizontalWhitespaceAndComments()
        if peek().kind == .punctuation && peek().lexeme == "(" {
            let args = consumeParenthesizedTypstArgs()
            endPos = args.endPos
            if let capRange = args.rawText.range(of: "caption:") {
                let after = args.rawText[capRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if after.hasPrefix("["), let close = after.lastIndex(of: "]") {
                    caption = normalizeWhitespace(String(after[after.index(after: after.startIndex)..<close]))
                } else if after.hasPrefix("\""), let close = after.dropFirst().firstIndex(of: "\"") {
                    caption = String(after[after.index(after: after.startIndex)..<close])
                }
            }
            if args.rawText.contains("table(") && envName == "figure" {
                // In Typst `#figure(table(...), caption: [...])` is a table float!
            }
        }

        skipHorizontalWhitespaceAndComments()
        if peek().kind == .identifier && peek().lexeme.hasPrefix("<") && peek().lexeme.hasSuffix(">") {
            let lblTok = advance()
            let key = String(lblTok.lexeme.dropFirst().dropLast())
            label = key
            endPos = lblTok.span.end
            children.append(MarkupASTNode(kind: .labelDeclaration(key: key), span: lblTok.span))
        }

        return MarkupASTNode(
            kind: .environment(name: envName, label: label, caption: caption),
            span: TextSpan(filePath: filePath, start: startPos, end: endPos),
            children: children
        )
    }

    private mutating func parseTypstMath() -> (node: MarkupASTNode, isDisplay: Bool) {
        let openTok = advance() // `$`
        let startPos = openTok.span.start
        var endPos = openTok.span.end
        var rawPieces: [String] = []
        var closed = false

        while !isAtEnd {
            let t = peek()
            if t.kind == .mathInline {
                endPos = t.span.end
                advance()
                closed = true
                break
            }
            if t.kind == .headingMarker {
                break
            }
            if t.kind == .whitespace {
                let (newlines, _) = countConsecutiveNewlines(startingAt: index)
                if newlines >= 2 {
                    break
                }
            }
            if t.kind != .comment {
                rawPieces.append(t.lexeme)
            }
            endPos = t.span.end
            advance()
        }

        let fullRaw = rawPieces.joined()
        // In Typst, `$ x = 1 $` (leading AND trailing whitespace inside `$...$`) is display/block math,
        // whereas `$x = 1$` (no leading/trailing space) is inline math!
        let hasLeadingSpace = fullRaw.first?.isWhitespace == true
        let hasTrailingSpace = fullRaw.last?.isWhitespace == true
        let isDisplay = fullRaw.count >= 2 && hasLeadingSpace && hasTrailingSpace

        var label: String? = nil
        var children: [MarkupASTNode] = []
        if isDisplay {
            let saved = index
            skipHorizontalWhitespaceAndComments()
            if peek().kind == .identifier && peek().lexeme.hasPrefix("<") && peek().lexeme.hasSuffix(">") {
                let lblTok = advance()
                let key = String(lblTok.lexeme.dropFirst().dropLast())
                label = key
                endPos = lblTok.span.end
                children.append(MarkupASTNode(kind: .labelDeclaration(key: key), span: lblTok.span))
            } else {
                index = saved
            }
        }

        if !closed {
            let span = TextSpan(filePath: filePath, start: startPos, end: endPos)
            children.append(
                emitIssue(
                    code: isDisplay ? .unclosedDisplayMath : .unclosedInlineMath,
                    severity: .error,
                    message: "Unclosed Typst '$' math delimiter.",
                    span: span,
                    suggestedFix: "$",
                    recoveredConstruct: "$"
                )
            )
        }

        let node = MarkupASTNode(
            kind: .mathExpression(
                isDisplayMode: isDisplay,
                formulaSource: fullRaw.trimmingCharacters(in: .whitespacesAndNewlines),
                label: label
            ),
            span: TextSpan(filePath: filePath, start: startPos, end: endPos),
            children: children
        )
        return (node, isDisplay)
    }

    private mutating func consumeParenthesizedTypstArgs() -> (rawText: String, innerTokens: [MarkupToken], endPos: TextPosition) {
        let open = advance() // `(`
        var endPos = open.span.end
        var depth = 1
        var innerTokens: [MarkupToken] = []
        var pieces: [String] = []

        while !isAtEnd && depth > 0 {
            let t = peek()
            if t.kind == .punctuation && t.lexeme == "(" {
                depth += 1
                pieces.append(t.lexeme)
                innerTokens.append(t)
                endPos = t.span.end
                advance()
            } else if t.kind == .punctuation && t.lexeme == ")" {
                depth -= 1
                endPos = t.span.end
                advance()
                if depth > 0 {
                    pieces.append(t.lexeme)
                    innerTokens.append(t)
                }
            } else {
                if t.kind != .comment {
                    pieces.append(t.lexeme)
                    innerTokens.append(t)
                }
                endPos = t.span.end
                advance()
            }
        }
        return (pieces.joined(), innerTokens, endPos)
    }

    private mutating func consumeTypstStatementLine() {
        var parenDepth = 0
        var braceDepth = 0
        var bracketDepth = 0
        while !isAtEnd {
            let t = peek()
            if parenDepth == 0 && braceDepth == 0 && bracketDepth == 0 {
                if t.kind == .whitespace && (t.lexeme.contains("\n") || t.lexeme.contains("\r")) {
                    break
                }
            }
            if t.kind == .punctuation && t.lexeme == "(" { parenDepth += 1 }
            else if t.kind == .punctuation && t.lexeme == ")" && parenDepth > 0 { parenDepth -= 1 }
            else if t.kind == .leftBrace { braceDepth += 1 }
            else if t.kind == .rightBrace && braceDepth > 0 { braceDepth -= 1 }
            else if t.kind == .leftBracket { bracketDepth += 1 }
            else if t.kind == .rightBracket && bracketDepth > 0 { bracketDepth -= 1 }
            advance()
        }
    }

    // MARK: - 3. Academic Markdown (Pandoc / Quarto / Embedded LaTeX) Dispatch

    private mutating func parseNextMarkdownItem(
        paragraph: inout ParagraphAccumulator,
        sectionStack: inout [OpenSectionFrame],
        topLevelNodes: inout [MarkupASTNode]
    ) {
        let tok = peek()

        switch tok.kind {
        case .headingMarker:
            flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
            parseMarkdownHeading(sectionStack: &sectionStack, topLevelNodes: &topLevelNodes)

        case .leftBracket:
            if let citeNode = tryParsePandocBracketCitation() {
                paragraph.recordInlineSemanticNode(citeNode)
            } else {
                let b = advance()
                paragraph.recordProseFragment(b.lexeme, span: b.span)
            }

        case .typstHashKeyword where tok.lexeme.hasPrefix("@"):
            let refTok = advance()
            let key = String(refTok.lexeme.dropFirst())
            let isCrossRef = Self.typstCrossRefPrefixes.contains { key.hasPrefix($0) }
            if isCrossRef {
                paragraph.recordInlineSemanticNode(
                    MarkupASTNode(kind: .crossReference(command: "@", targetKey: key), span: refTok.span)
                )
            } else {
                paragraph.recordInlineSemanticNode(
                    MarkupASTNode(kind: .citation(command: "@", citeKeys: [key], prenote: nil, postnote: nil), span: refTok.span)
                )
            }

        case .mathDisplay:
            flushParagraph(&paragraph, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
            let nodes = parseLaTeXMath(isDisplay: true)
            for n in nodes {
                appendNode(n, intoSections: &sectionStack, orTopLevel: &topLevelNodes)
            }

        case .mathInline:
            let nodes = parseLaTeXMath(isDisplay: false)
            for n in nodes {
                paragraph.recordInlineSemanticNode(n)
            }

        case .command:
            parseNextLaTeXItem(paragraph: &paragraph, sectionStack: &sectionStack, topLevelNodes: &topLevelNodes)

        default:
            let t = advance()
            paragraph.recordProseFragment(t.lexeme, span: t.span)
        }
    }

    private mutating func parseMarkdownHeading(
        sectionStack: inout [OpenSectionFrame],
        topLevelNodes: inout [MarkupASTNode]
    ) {
        let marker = advance()
        let level = max(1, min(6, marker.lexeme.count))
        let startPos = marker.span.start
        var endPos = marker.span.end
        var titleParts: [String] = []
        var label: String? = nil
        var children: [MarkupASTNode] = []

        skipHorizontalWhitespaceAndComments()

        while !isAtEnd {
            let t = peek()
            if t.kind == .whitespace && (t.lexeme.contains("\n") || t.lexeme.contains("\r")) {
                break
            }
            // Quarto / Pandoc heading attribute `{#sec:intro}`
            if t.kind == .leftBrace {
                let attr = consumeBraceGroupRaw(recoverAtStructuralBoundary: true, constructName: "heading attribute")
                endPos = attr.endPos
                for token in attr.rawContent.split(whereSeparator: \.isWhitespace) {
                    if token.hasPrefix("#") && token.count > 1 {
                        let key = String(token.dropFirst())
                        label = key
                        children.append(
                            MarkupASTNode(
                                kind: .labelDeclaration(key: key),
                                span: TextSpan(filePath: filePath, start: t.span.start, end: attr.endPos)
                            )
                        )
                    }
                }
                continue
            }
            if t.kind != .comment {
                titleParts.append(t.lexeme)
            }
            endPos = t.span.end
            advance()
        }

        let cleanTitle = normalizeWhitespace(titleParts.joined())
        openSection(
            level: level,
            title: cleanTitle.isEmpty ? "Untitled" : cleanTitle,
            label: label,
            startPos: startPos,
            endOfHeaderPos: endPos,
            initialChildren: children,
            sectionStack: &sectionStack,
            topLevelNodes: &topLevelNodes
        )
    }

    /// Parses Pandoc bracketed citations like `[@vaswani2017; see @dao2022, pp. 42-45]` without consuming regular `[links]`.
    private mutating func tryParsePandocBracketCitation() -> MarkupASTNode? {
        let saved = index
        let openTok = advance() // `[`
        var citeKeys: [String] = []
        var prenoteParts: [String] = []
        var postnoteParts: [String] = []
        var seenAtKey = false
        var endPos = openTok.span.end
        var closed = false

        while !isAtEnd {
            let t = peek()
            if t.kind == .rightBracket {
                endPos = t.span.end
                advance()
                closed = true
                break
            }
            if t.kind == .whitespace && (t.lexeme.contains("\n") || t.lexeme.contains("\r")) {
                break
            }
            if t.kind == .typstHashKeyword && t.lexeme.hasPrefix("@") {
                let key = String(t.lexeme.dropFirst())
                if !Self.typstCrossRefPrefixes.contains(where: { key.hasPrefix($0) }) {
                    citeKeys.append(key)
                    seenAtKey = true
                }
            } else if !seenAtKey {
                prenoteParts.append(t.lexeme)
            } else if t.lexeme != ";" {
                postnoteParts.append(t.lexeme)
            }
            endPos = t.span.end
            advance()
        }

        guard closed, !citeKeys.isEmpty else {
            index = saved
            return nil
        }

        let pre = prenoteParts.joined().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-")))
        let post = postnoteParts.joined().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
        return MarkupASTNode(
            kind: .citation(
                command: "[@]",
                citeKeys: citeKeys,
                prenote: pre.isEmpty ? nil : pre,
                postnote: post.isEmpty ? nil : post
            ),
            span: TextSpan(filePath: filePath, start: openTok.span.start, end: endPos)
        )
    }

    // MARK: Whitespace Normalization

    private func normalizeWhitespace(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var lastWasSpace = true
        for ch in text {
            if ch.isWhitespace {
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        if out.last == " " {
            out.removeLast()
        }
        return out
    }
}
