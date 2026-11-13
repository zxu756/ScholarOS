import Foundation
import ScholarModels

// MARK: - Latexdiff Preamble Styles & Review Hunks

public enum LatexdiffColorScheme: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case cambridgeAcademic = "Cambridge Linen"
    case classicBlueRed = "Classic Latexdiff (Blue/Red)"
    case monochromePrint = "Monochrome Camera-Print"
    case highContrastAccessible = "High-Contrast Accessible"

    public var id: String { rawValue }

    public var additionRGB: (r: Double, g: Double, b: Double) {
        switch self {
        case .cambridgeAcademic:
            return (0.09, 0.42, 0.31)
        case .classicBlueRed:
            return (0.00, 0.18, 0.72)
        case .monochromePrint:
            return (0.10, 0.10, 0.10)
        case .highContrastAccessible:
            return (0.00, 0.36, 0.58)
        }
    }

    public var deletionRGB: (r: Double, g: Double, b: Double) {
        switch self {
        case .cambridgeAcademic:
            return (0.64, 0.16, 0.18)
        case .classicBlueRed:
            return (0.78, 0.08, 0.12)
        case .monochromePrint:
            return (0.42, 0.42, 0.42)
        case .highContrastAccessible:
            return (0.72, 0.22, 0.00)
        }
    }
}

public struct TrackChangeHunk: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let spanIDs: [UUID]
    public let approximateLine: Int
    public let deletedText: String
    public let insertedText: String
    public let leadingContext: String
    public let trailingContext: String

    public init(
        id: UUID = UUID(),
        spanIDs: [UUID],
        approximateLine: Int,
        deletedText: String,
        insertedText: String,
        leadingContext: String,
        trailingContext: String
    ) {
        self.id = id
        self.spanIDs = spanIDs
        self.approximateLine = approximateLine
        self.deletedText = deletedText
        self.insertedText = insertedText
        self.leadingContext = leadingContext
        self.trailingContext = trailingContext
    }

    public var isReplacement: Bool {
        !deletedText.isEmpty && !insertedText.isEmpty
    }
}

// MARK: - TrackChangesDiffReport

public struct TrackChangesDiffReport: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let filePath: String
    public let baselineLabel: String
    public let revisedLabel: String
    public let spans: [TrackChangeWordSpan]
    public let insertedWordCount: Int
    public let deletedWordCount: Int
    public let unchangedWordCount: Int
    public let insertionSpanCount: Int
    public let deletionSpanCount: Int
    public let editDistance: Int
    public let similarityRatio: Double
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        filePath: String = "main.tex",
        baselineLabel: String = "Baseline",
        revisedLabel: String = "Revised",
        spans: [TrackChangeWordSpan],
        insertedWordCount: Int,
        deletedWordCount: Int,
        unchangedWordCount: Int,
        insertionSpanCount: Int,
        deletionSpanCount: Int,
        editDistance: Int,
        similarityRatio: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.filePath = filePath
        self.baselineLabel = baselineLabel
        self.revisedLabel = revisedLabel
        self.spans = spans
        self.insertedWordCount = insertedWordCount
        self.deletedWordCount = deletedWordCount
        self.unchangedWordCount = unchangedWordCount
        self.insertionSpanCount = insertionSpanCount
        self.deletionSpanCount = deletionSpanCount
        self.editDistance = editDistance
        self.similarityRatio = similarityRatio
        self.createdAt = createdAt
    }

    public var unresolvedChangeCount: Int {
        insertionSpanCount + deletionSpanCount
    }

    public var hasUnresolvedChanges: Bool {
        unresolvedChangeCount > 0
    }

    public var netWordDelta: Int {
        insertedWordCount - deletedWordCount
    }

    /// Reconstructs the exact baseline (pre-edit / rejected) text from `.equal` and `.deletion` spans.
    public func reconstructBaselineText() -> String {
        var out = ""
        for span in spans where span.kind == .equal || span.kind == .deletion {
            out.append(span.text)
        }
        return out
    }

    /// Reconstructs the current target (accepted) text from `.equal` and `.insertion` spans.
    public func reconstructRevisedText() -> String {
        var out = ""
        for span in spans where span.kind == .equal || span.kind == .insertion {
            out.append(span.text)
        }
        return out
    }

    /// Resolves a single change span by accepting it (insertions become `.equal`, deletions are removed).
    public func acceptChange(spanID: UUID) -> TrackChangesDiffReport {
        MyersWordLevelTrackChangesEngine().acceptChange(spanID: spanID, in: self)
    }

    /// Resolves a single change span by rejecting it (insertions are removed, deletions become `.equal`).
    public func rejectChange(spanID: UUID) -> TrackChangesDiffReport {
        MyersWordLevelTrackChangesEngine().rejectChange(spanID: spanID, in: self)
    }

    /// Resolves an entire contiguous replacement/edit hunk containing `spanID` by accepting all spans in that hunk.
    public func acceptHunk(containingSpanID spanID: UUID) -> TrackChangesDiffReport {
        MyersWordLevelTrackChangesEngine().acceptAdjacentHunk(containingSpanID: spanID, in: self)
    }

    /// Resolves an entire contiguous replacement/edit hunk containing `spanID` by rejecting all spans in that hunk.
    public func rejectHunk(containingSpanID spanID: UUID) -> TrackChangesDiffReport {
        MyersWordLevelTrackChangesEngine().rejectAdjacentHunk(containingSpanID: spanID, in: self)
    }

    public func acceptAllChanges() -> TrackChangesDiffReport {
        MyersWordLevelTrackChangesEngine().acceptAllChanges(in: self)
    }

    public func rejectAllChanges() -> TrackChangesDiffReport {
        MyersWordLevelTrackChangesEngine().rejectAllChanges(in: self)
    }

    public func extractHunks(contextCharacterLimit: Int = 48) -> [TrackChangeHunk] {
        MyersWordLevelTrackChangesEngine().extractHunks(
            from: self,
            contextCharacterLimit: contextCharacterLimit
        )
    }

    public func renderLatexdiffMarkup(includeBeginEndHooks: Bool = false) -> String {
        MyersWordLevelTrackChangesEngine().renderLatexdiffMarkup(
            from: self,
            includeBeginEndHooks: includeBeginEndHooks
        )
    }
}

// MARK: - Handwritten Eugene Myers O(ND) Word & LaTeX-Token Diff Engine

public struct MyersWordLevelTrackChangesEngine: Sendable {
    private enum DiffTokenCategory: Equatable, Sendable {
        case proseWord
        case atomicLatexCitationOrRef
        case atomicInlineMath
        case latexCommand
        case punctuationOrBrace
        case horizontalWhitespace
        case lineBreakWhitespace
    }

    private struct AcademicDiffToken: Equatable, Sendable {
        let rawText: String
        let category: DiffTokenCategory
        let wordContribution: Int

        static func == (lhs: AcademicDiffToken, rhs: AcademicDiffToken) -> Bool {
            lhs.rawText == rhs.rawText
        }

        var isPureHorizontalWhitespace: Bool {
            category == .horizontalWhitespace
        }
    }

    private enum RawTokenEdit: Sendable {
        case equal(AcademicDiffToken)
        case insertion(AcademicDiffToken)
        case deletion(AcademicDiffToken)

        var kind: TrackChangeSpanKind {
            switch self {
            case .equal: return .equal
            case .insertion: return .insertion
            case .deletion: return .deletion
            }
        }

        var token: AcademicDiffToken {
            switch self {
            case .equal(let t), .insertion(let t), .deletion(let t):
                return t
            }
        }
    }

    private static let atomicStructuredCommands: Set<String> = [
        "cite", "citep", "citet", "citealt", "citealp", "citeauthor", "citeyear",
        "parencite", "textcite", "autocite", "nocite",
        "ref", "eqref", "pageref", "autoref", "cref", "Cref", "label", "input", "include"
    ]

    public var coalesceInterWordWhitespaceInPhrases: Bool

    public init(coalesceInterWordWhitespaceInPhrases: Bool = true) {
        self.coalesceInterWordWhitespaceInPhrases = coalesceInterWordWhitespaceInPhrases
    }

    // MARK: - Public Diff Entry Points

    public func diff(
        original: String,
        revised: String,
        filePath: String = "main.tex",
        baselineLabel: String = "Baseline",
        revisedLabel: String = "Revised"
    ) -> TrackChangesDiffReport {
        let origTokens = Self.tokenizeLosslessly(original)
        let revTokens = Self.tokenizeLosslessly(revised)

        let rawEdits = Self.computeShortestEditScript(original: origTokens, revised: revTokens)
        let spans = coalesceTokenEdits(rawEdits)
        return Self.buildReport(
            spans: spans,
            filePath: filePath,
            baselineLabel: baselineLabel,
            revisedLabel: revisedLabel,
            explicitEditDistance: rawEdits.reduce(into: 0) { acc, op in
                if op.kind != .equal { acc += 1 }
            }
        )
    }

    public func diffSnapshots(
        baseline: ManuscriptSnapshot,
        revised: ManuscriptSnapshot
    ) -> TrackChangesDiffReport {
        diff(
            original: baseline.sourceContent,
            revised: revised.sourceContent,
            filePath: revised.filePath,
            baselineLabel: baseline.label,
            revisedLabel: revised.label
        )
    }

    // MARK: - Inline Single-Span & Hunk Resolution

    public func acceptChange(
        spanID: UUID,
        in report: TrackChangesDiffReport
    ) -> TrackChangesDiffReport {
        var updatedSpans: [TrackChangeWordSpan] = []
        updatedSpans.reserveCapacity(report.spans.count)

        for span in report.spans {
            if span.id == spanID {
                switch span.kind {
                case .insertion:
                    updatedSpans.append(TrackChangeWordSpan(id: span.id, kind: .equal, text: span.text))
                case .deletion:
                    // Accepting a deletion permanently removes the deleted span.
                    continue
                case .equal:
                    updatedSpans.append(span)
                }
            } else {
                updatedSpans.append(span)
            }
        }

        let normalized = Self.mergeAdjacentIdenticalSpans(updatedSpans)
        return Self.buildReport(
            id: report.id,
            spans: normalized,
            filePath: report.filePath,
            baselineLabel: report.baselineLabel,
            revisedLabel: report.revisedLabel,
            explicitEditDistance: nil,
            createdAt: report.createdAt
        )
    }

    public func rejectChange(
        spanID: UUID,
        in report: TrackChangesDiffReport
    ) -> TrackChangesDiffReport {
        var updatedSpans: [TrackChangeWordSpan] = []
        updatedSpans.reserveCapacity(report.spans.count)

        for span in report.spans {
            if span.id == spanID {
                switch span.kind {
                case .insertion:
                    // Rejecting an insertion discards the newly inserted text.
                    continue
                case .deletion:
                    // Rejecting a deletion restores the deleted text as unchanged manuscript prose.
                    updatedSpans.append(TrackChangeWordSpan(id: span.id, kind: .equal, text: span.text))
                case .equal:
                    updatedSpans.append(span)
                }
            } else {
                updatedSpans.append(span)
            }
        }

        let normalized = Self.mergeAdjacentIdenticalSpans(updatedSpans)
        return Self.buildReport(
            id: report.id,
            spans: normalized,
            filePath: report.filePath,
            baselineLabel: report.baselineLabel,
            revisedLabel: report.revisedLabel,
            explicitEditDistance: nil,
            createdAt: report.createdAt
        )
    }

    public func acceptAdjacentHunk(
        containingSpanID spanID: UUID,
        in report: TrackChangesDiffReport
    ) -> TrackChangesDiffReport {
        let targetIDs = Self.contiguousNonEqualSpanIDs(containing: spanID, in: report.spans)
        guard !targetIDs.isEmpty else { return report }

        var current = report
        for id in targetIDs {
            current = acceptChange(spanID: id, in: current)
        }
        return current
    }

    public func rejectAdjacentHunk(
        containingSpanID spanID: UUID,
        in report: TrackChangesDiffReport
    ) -> TrackChangesDiffReport {
        let targetIDs = Self.contiguousNonEqualSpanIDs(containing: spanID, in: report.spans)
        guard !targetIDs.isEmpty else { return report }

        var current = report
        for id in targetIDs {
            current = rejectChange(spanID: id, in: current)
        }
        return current
    }

    public func acceptAllChanges(in report: TrackChangesDiffReport) -> TrackChangesDiffReport {
        let resolvedText = report.reconstructRevisedText()
        let singleSpan = resolvedText.isEmpty
            ? []
            : [TrackChangeWordSpan(kind: .equal, text: resolvedText)]
        return Self.buildReport(
            id: report.id,
            spans: singleSpan,
            filePath: report.filePath,
            baselineLabel: report.baselineLabel,
            revisedLabel: report.revisedLabel,
            explicitEditDistance: 0,
            createdAt: report.createdAt
        )
    }

    public func rejectAllChanges(in report: TrackChangesDiffReport) -> TrackChangesDiffReport {
        let baselineText = report.reconstructBaselineText()
        let singleSpan = baselineText.isEmpty
            ? []
            : [TrackChangeWordSpan(kind: .equal, text: baselineText)]
        return Self.buildReport(
            id: report.id,
            spans: singleSpan,
            filePath: report.filePath,
            baselineLabel: report.baselineLabel,
            revisedLabel: report.revisedLabel,
            explicitEditDistance: 0,
            createdAt: report.createdAt
        )
    }

    public func extractHunks(
        from report: TrackChangesDiffReport,
        contextCharacterLimit: Int = 48
    ) -> [TrackChangeHunk] {
        let spans = report.spans
        var hunks: [TrackChangeHunk] = []
        var idx = 0
        var currentRevisedLine = 1

        while idx < spans.count {
            let span = spans[idx]
            if span.kind == .equal {
                currentRevisedLine += span.text.reduce(into: 0) { count, ch in
                    if ch == "\n" { count += 1 }
                }
                idx += 1
                continue
            }

            let hunkLine = currentRevisedLine
            let leadingContext: String
            if idx > 0 && spans[idx - 1].kind == .equal {
                leadingContext = String(spans[idx - 1].text.suffix(max(8, contextCharacterLimit)))
            } else {
                leadingContext = ""
            }

            var ids: [UUID] = []
            var deletedBuf = ""
            var insertedBuf = ""

            while idx < spans.count && spans[idx].kind != .equal {
                let editSpan = spans[idx]
                ids.append(editSpan.id)
                if editSpan.kind == .deletion {
                    deletedBuf.append(editSpan.text)
                } else if editSpan.kind == .insertion {
                    insertedBuf.append(editSpan.text)
                    currentRevisedLine += editSpan.text.reduce(into: 0) { count, ch in
                        if ch == "\n" { count += 1 }
                    }
                }
                idx += 1
            }

            let trailingContext: String
            if idx < spans.count && spans[idx].kind == .equal {
                trailingContext = String(spans[idx].text.prefix(max(8, contextCharacterLimit)))
            } else {
                trailingContext = ""
            }

            hunks.append(
                TrackChangeHunk(
                    spanIDs: ids,
                    approximateLine: hunkLine,
                    deletedText: deletedBuf,
                    insertedText: insertedBuf,
                    leadingContext: leadingContext,
                    trailingContext: trailingContext
                )
            )
        }

        return hunks
    }

    // MARK: - Latexdiff-Compatible Markup & Preamble Generator

    public func generateLatexdiffPreamble(
        colorScheme: LatexdiffColorScheme = .cambridgeAcademic,
        authorName: String = "ScholarOS Track Changes"
    ) -> String {
        let add = colorScheme.additionRGB
        let del = colorScheme.deletionRGB
        let addSpec = String(format: "%.3f,%.3f,%.3f", add.r, add.g, add.b)
        let delSpec = String(format: "%.3f,%.3f,%.3f", del.r, del.g, del.b)

        return """
        %DIF LATEXDIFF DIFFERENCE FILE
        %DIF PREAMBLE EXTENSION ADDED BY SCHOLAROS (\(authorName) - \(colorScheme.rawValue))
        \\RequirePackage[normalem]{ulem}
        \\RequirePackage{xcolor}
        \\definecolor{scholarosdifadd}{rgb}{\(addSpec)}
        \\definecolor{scholarosdifdel}{rgb}{\(delSpec)}
        \\providecommand{\\DIFaddtex}[1]{{\\protect\\color{scholarosdifadd}\\uwave{#1}}}
        \\providecommand{\\DIFdeltex}[1]{{\\protect\\color{scholarosdifdel}\\sout{#1}}}
        \\providecommand{\\DIFaddbegin}{}
        \\providecommand{\\DIFaddend}{}
        \\providecommand{\\DIFdelbegin}{}
        \\providecommand{\\DIFdelend}{}
        \\providecommand{\\DIFmodbegin}{}
        \\providecommand{\\DIFmodend}{}
        %DIF FLOATSAFE PREAMBLE
        \\providecommand{\\DIFaddFL}[1]{\\DIFadd{#1}}
        \\providecommand{\\DIFdelFL}[1]{\\DIFdel{#1}}
        \\providecommand{\\DIFaddbeginFL}{}
        \\providecommand{\\DIFaddendFL}{}
        \\providecommand{\\DIFdelbeginFL}{}
        \\providecommand{\\DIFdelendFL}{}
        \\providecommand{\\DIFadd}[1]{\\DIFaddtex{#1}}
        \\providecommand{\\DIFdel}[1]{\\DIFdeltex{#1}}
        %DIF END PREAMBLE EXTENSION ADDED BY SCHOLAROS
        """
    }

    public func renderLatexdiffMarkup(
        from report: TrackChangesDiffReport,
        includeBeginEndHooks: Bool = false
    ) -> String {
        var out = ""
        for span in report.spans {
            switch span.kind {
            case .equal:
                out.append(span.text)
            case .insertion:
                out.append(
                    Self.wrapDiffMacro(
                        text: span.text,
                        macroName: "DIFadd",
                        beginHook: includeBeginEndHooks ? "\\DIFaddbegin " : "",
                        endHook: includeBeginEndHooks ? "\\DIFaddend " : ""
                    )
                )
            case .deletion:
                out.append(
                    Self.wrapDiffMacro(
                        text: span.text,
                        macroName: "DIFdel",
                        beginHook: includeBeginEndHooks ? "\\DIFdelbegin " : "",
                        endHook: includeBeginEndHooks ? "\\DIFdelend " : ""
                    )
                )
            }
        }
        return out
    }

    /// Generates a complete standalone compilable `.tex` file with `%DIF PREAMBLE` injected
    /// right before `\begin{document}`, diffing only the manuscript body when full documents are given.
    public func renderCompilableLatexdiffDocument(
        originalDocument: String,
        revisedDocument: String,
        colorScheme: LatexdiffColorScheme = .cambridgeAcademic,
        includeBeginEndHooks: Bool = true
    ) -> String {
        let preambleBlock = generateLatexdiffPreamble(colorScheme: colorScheme)

        if let origSplit = Self.splitLatexPreambleAndBody(originalDocument),
           let revSplit = Self.splitLatexPreambleAndBody(revisedDocument)
        {
            let bodyDiff = diff(
                original: origSplit.body,
                revised: revSplit.body,
                filePath: "latexdiff.tex"
            )
            let renderedBody = renderLatexdiffMarkup(
                from: bodyDiff,
                includeBeginEndHooks: includeBeginEndHooks
            )
            return """
            \(revSplit.preamble)
            \(preambleBlock)
            \\begin{document}
            \(renderedBody)
            \\end{document}
            """
        }

        let report = diff(original: originalDocument, revised: revisedDocument, filePath: "latexdiff.tex")
        return renderCompilableLatexdiffDocument(
            from: report,
            colorScheme: colorScheme,
            includeBeginEndHooks: includeBeginEndHooks
        )
    }

    public func renderCompilableLatexdiffDocument(
        from report: TrackChangesDiffReport,
        colorScheme: LatexdiffColorScheme = .cambridgeAcademic,
        includeBeginEndHooks: Bool = true
    ) -> String {
        let preambleBlock = generateLatexdiffPreamble(colorScheme: colorScheme)
        let markup = renderLatexdiffMarkup(from: report, includeBeginEndHooks: includeBeginEndHooks)

        if let beginRange = markup.range(of: "\\begin{document}") {
            let head = markup[..<beginRange.lowerBound]
            let tail = markup[beginRange.lowerBound...]
            return "\(head)\n\(preambleBlock)\n\(tail)"
        }

        return """
        \\documentclass[11pt]{article}
        \(preambleBlock)
        \\begin{document}
        \(markup)
        \\end{document}
        """
    }

    /// Splits multi-paragraph additions/deletions across `\n\n` paragraph breaks so `ulem`'s
    /// `\uwave` and `\sout` macros never fail on embedded `\par` tokens, while preserving
    /// leading and trailing whitespace outside `{...}` for clean spacing.
    private static func wrapDiffMacro(
        text: String,
        macroName: String,
        beginHook: String,
        endHook: String
    ) -> String {
        guard !text.isEmpty else { return "" }
        if text.allSatisfy(\.isWhitespace) {
            return text
        }

        // Split on paragraph boundaries (\n\n) so \DIFadd / \DIFdel never wraps \par
        let paragraphs = splitPreservingDoubleNewlines(text)
        var out = ""
        for piece in paragraphs {
            if piece.allSatisfy(\.isWhitespace) {
                out.append(piece)
                continue
            }
            let (leadingWS, core, trailingWS) = trimSurroundingWhitespace(piece)
            if core.isEmpty {
                out.append(piece)
            } else {
                out.append(leadingWS)
                out.append(beginHook)
                out.append("\\\(macroName){\(core)}")
                out.append(endHook)
                out.append(trailingWS)
            }
        }
        return out
    }

    private static func splitPreservingDoubleNewlines(_ input: String) -> [String] {
        var segments: [String] = []
        let chars = Array(input)
        var current = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\n", i + 1 < chars.count, chars[i + 1] == "\n" {
                if !current.isEmpty {
                    segments.append(current)
                    current = ""
                }
                var nlRun = ""
                while i < chars.count && chars[i] == "\n" {
                    nlRun.append(chars[i])
                    i += 1
                }
                segments.append(nlRun)
            } else {
                current.append(chars[i])
                i += 1
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    private static func trimSurroundingWhitespace(_ s: String) -> (leading: String, core: String, trailing: String) {
        let chars = Array(s)
        var start = 0
        while start < chars.count && chars[start].isWhitespace {
            start += 1
        }
        if start == chars.count {
            return (s, "", "")
        }
        var end = chars.count - 1
        while end >= start && chars[end].isWhitespace {
            end -= 1
        }
        let leading = start > 0 ? String(chars[0..<start]) : ""
        let core = String(chars[start...end])
        let trailing = end + 1 < chars.count ? String(chars[(end + 1)..<chars.count]) : ""
        return (leading, core, trailing)
    }

    private static func splitLatexPreambleAndBody(_ source: String) -> (preamble: String, body: String)? {
        guard let beginRange = source.range(of: "\\begin{document}"),
              let endRange = source.range(of: "\\end{document}", options: .backwards),
              beginRange.upperBound <= endRange.lowerBound
        else {
            return nil
        }
        let preamble = String(source[..<beginRange.lowerBound])
        let body = String(source[beginRange.upperBound..<endRange.lowerBound])
        return (preamble: preamble, body: body)
    }

    // MARK: - Lossless Word & LaTeX-Token Lexer

    private static func tokenizeLosslessly(_ source: String) -> [AcademicDiffToken] {
        guard !source.isEmpty else { return [] }
        let chars = Array(source)
        let n = chars.count
        var tokens: [AcademicDiffToken] = []
        tokens.reserveCapacity(max(16, n / 4))
        var i = 0

        while i < n {
            let ch = chars[i]

            // 1. Horizontal vs vertical whitespace runs
            if ch.isWhitespace {
                let start = i
                var sawNewline = false
                if ch == "\n" || ch == "\r" {
                    sawNewline = true
                    while i < n && (chars[i] == "\n" || chars[i] == "\r") {
                        i += 1
                    }
                } else {
                    while i < n && chars[i].isWhitespace && chars[i] != "\n" && chars[i] != "\r" {
                        i += 1
                    }
                }
                let raw = String(chars[start..<i])
                tokens.append(
                    AcademicDiffToken(
                        rawText: raw,
                        category: sawNewline ? .lineBreakWhitespace : .horizontalWhitespace,
                        wordContribution: 0
                    )
                )
                continue
            }

            // 2. Atomic single-line inline math ($...$) so \DIFadd{$...$} never produces unmatched $
            if ch == "$", (i + 1 >= n || chars[i + 1] != "$"), !isEscaped(in: chars, at: i) {
                if let mathEnd = scanBalancedInlineMath(in: chars, from: i) {
                    let raw = String(chars[i..<mathEnd])
                    tokens.append(
                        AcademicDiffToken(
                            rawText: raw,
                            category: .atomicInlineMath,
                            wordContribution: 1
                        )
                    )
                    i = mathEnd
                    continue
                }
            }

            // 3. LaTeX backslash commands (with atomic grouping for \cite{...}, \ref{...}, \label{...})
            if ch == "\\" {
                let start = i
                i += 1
                if i < n {
                    if chars[i].isLetter {
                        let nameStart = i
                        while i < n && (chars[i].isLetter || chars[i] == "*") {
                            i += 1
                        }
                        let cmdName = String(chars[nameStart..<i]).replacingOccurrences(of: "*", with: "")
                        if atomicStructuredCommands.contains(cmdName),
                           let structuredEnd = scanSingleLineStructuredCommandArguments(in: chars, from: i)
                        {
                            i = structuredEnd
                            tokens.append(
                                AcademicDiffToken(
                                    rawText: String(chars[start..<i]),
                                    category: .atomicLatexCitationOrRef,
                                    wordContribution: 0
                                )
                            )
                            continue
                        }
                    } else {
                        // Escaped symbol such as \%, \&, \_, \,
                        i += 1
                    }
                }
                tokens.append(
                    AcademicDiffToken(
                        rawText: String(chars[start..<i]),
                        category: .latexCommand,
                        wordContribution: 0
                    )
                )
                continue
            }

            // 4. Prose words & numbers (preserving internal hyphens/apostrophes/decimals)
            if ch.isLetter || ch.isNumber {
                let start = i
                i += 1
                while i < n {
                    let cur = chars[i]
                    if cur.isLetter || cur.isNumber {
                        i += 1
                    } else if (cur == "-" || cur == "'" || cur == "\u{2019}" || cur == ".")
                        && i + 1 < n
                        && (chars[i + 1].isLetter || chars[i + 1].isNumber)
                    {
                        // Keep hyphenated words ("dual-blind") and decimal numbers ("14.2") together
                        if cur == "." && !(chars[i - 1].isNumber && chars[i + 1].isNumber) {
                            break
                        }
                        i += 1
                    } else {
                        break
                    }
                }
                tokens.append(
                    AcademicDiffToken(
                        rawText: String(chars[start..<i]),
                        category: .proseWord,
                        wordContribution: 1
                    )
                )
                continue
            }

            // 5. Punctuation, braces, comments, or operators
            tokens.append(
                AcademicDiffToken(
                    rawText: String(ch),
                    category: .punctuationOrBrace,
                    wordContribution: 0
                )
            )
            i += 1
        }

        return tokens
    }

    private static func isEscaped(in chars: [Character], at index: Int) -> Bool {
        var slashes = 0
        var scan = index
        while scan > 0 && chars[scan - 1] == "\\" {
            slashes += 1
            scan -= 1
        }
        return slashes % 2 == 1
    }

    private static func scanBalancedInlineMath(in chars: [Character], from dollarIndex: Int) -> Int? {
        var idx = dollarIndex + 1
        let maxSpan = min(chars.count, dollarIndex + 240)
        while idx < maxSpan {
            let c = chars[idx]
            if c == "\n" || c == "\r" {
                return nil
            }
            if c == "$" && !isEscaped(in: chars, at: idx) {
                return idx + 1
            }
            idx += 1
        }
        return nil
    }

    private static func scanSingleLineStructuredCommandArguments(
        in chars: [Character],
        from afterNameIndex: Int
    ) -> Int? {
        var idx = afterNameIndex
        var consumedRequiredBrace = false

        while idx < chars.count {
            if chars[idx] == "[" {
                guard let nextIdx = scanSingleLineBalancedGroup(
                    in: chars,
                    from: idx,
                    open: "[",
                    close: "]"
                ) else {
                    return nil
                }
                idx = nextIdx
            } else if chars[idx] == "{" {
                guard let nextIdx = scanSingleLineBalancedGroup(
                    in: chars,
                    from: idx,
                    open: "{",
                    close: "}"
                ) else {
                    return nil
                }
                idx = nextIdx
                consumedRequiredBrace = true
            } else {
                break
            }
        }

        return consumedRequiredBrace ? idx : nil
    }

    private static func scanSingleLineBalancedGroup(
        in chars: [Character],
        from start: Int,
        open: Character,
        close: Character
    ) -> Int? {
        guard start < chars.count, chars[start] == open else { return nil }
        var depth = 0
        var idx = start
        while idx < chars.count {
            let c = chars[idx]
            if c == "\n" || c == "\r" {
                return nil
            }
            if c == open && !isEscaped(in: chars, at: idx) {
                depth += 1
            } else if c == close && !isEscaped(in: chars, at: idx) {
                depth -= 1
                if depth == 0 {
                    return idx + 1
                }
            }
            idx += 1
        }
        return nil
    }

    // MARK: - Eugene Myers O(ND) Shortest-Edit-Script Core

    private static func computeShortestEditScript(
        original aFull: [AcademicDiffToken],
        revised bFull: [AcademicDiffToken]
    ) -> [RawTokenEdit] {
        // Strip shared prefix and suffix snakes in O(N) before invoking Myers O(ND)
        var prefixCount = 0
        let minLen = min(aFull.count, bFull.count)
        while prefixCount < minLen && aFull[prefixCount] == bFull[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        let remainingMin = minLen - prefixCount
        while suffixCount < remainingMin
            && aFull[aFull.count - 1 - suffixCount] == bFull[bFull.count - 1 - suffixCount]
        {
            suffixCount += 1
        }

        var edits: [RawTokenEdit] = []
        edits.reserveCapacity(aFull.count + bFull.count)

        for i in 0..<prefixCount {
            edits.append(.equal(aFull[i]))
        }

        let aMid = Array(aFull[prefixCount..<(aFull.count - suffixCount)])
        let bMid = Array(bFull[prefixCount..<(bFull.count - suffixCount)])

        if aMid.isEmpty {
            for token in bMid {
                edits.append(.insertion(token))
            }
        } else if bMid.isEmpty {
            for token in aMid {
                edits.append(.deletion(token))
            }
        } else {
            edits.append(contentsOf: myersSESCore(a: aMid, b: bMid))
        }

        let suffixStart = aFull.count - suffixCount
        for i in suffixStart..<aFull.count {
            edits.append(.equal(aFull[i]))
        }

        return edits
    }

    private static func myersSESCore(
        a: [AcademicDiffToken],
        b: [AcademicDiffToken]
    ) -> [RawTokenEdit] {
        let n = a.count
        let m = b.count
        let maxD = n + m
        let offset = maxD

        var v = Array(repeating: 0, count: 2 * maxD + 2)
        // Compactly record only active diagonal band [-d...d] for each step d
        var traceBands: [[Int]] = []
        traceBands.reserveCapacity(min(maxD + 1, 256))

        var reachedEnd = false
        for d in 0...maxD {
            var k = -d
            while k <= d {
                let xStart: Int
                if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                    xStart = v[k + 1 + offset]
                } else {
                    xStart = v[k - 1 + offset] + 1
                }

                var x = xStart
                var y = x - k
                while x < n && y < m && a[x] == b[y] {
                    x += 1
                    y += 1
                }

                v[k + offset] = x
                if x >= n && y >= m {
                    reachedEnd = true
                }
                k += 2
            }

            let bandStart = offset - d
            let bandEnd = offset + d
            traceBands.append(Array(v[bandStart...bandEnd]))

            if reachedEnd {
                break
            }
        }

        // Backtrack from (n, m) through saved D-bands to recover canonical shortest edit script
        var backtrackEdits: [RawTokenEdit] = []
        backtrackEdits.reserveCapacity(n + m)
        var x = n
        var y = m

        let finalD = traceBands.count - 1
        if finalD > 0 {
            for d in stride(from: finalD, through: 1, by: -1) {
                let prevBand = traceBands[d - 1]
                let prevD = d - 1
                let k = x - y

                @inline(__always)
                func prevV(_ diag: Int) -> Int {
                    prevBand[diag + prevD]
                }

                let prevK: Int
                if k == -d || (k != d && prevV(k - 1) < prevV(k + 1)) {
                    prevK = k + 1
                } else {
                    prevK = k - 1
                }

                let prevX = prevV(prevK)
                let prevY = prevX - prevK

                while x > prevX && y > prevY {
                    backtrackEdits.append(.equal(a[x - 1]))
                    x -= 1
                    y -= 1
                }

                if x == prevX {
                    backtrackEdits.append(.insertion(b[y - 1]))
                    y -= 1
                } else {
                    backtrackEdits.append(.deletion(a[x - 1]))
                    x -= 1
                }
            }
        }

        while x > 0 && y > 0 {
            backtrackEdits.append(.equal(a[x - 1]))
            x -= 1
            y -= 1
        }

        backtrackEdits.reverse()
        return backtrackEdits
    }

    // MARK: - Edit Normalization, Phrase Coalescing & Span Merging

    private func coalesceTokenEdits(_ rawEdits: [RawTokenEdit]) -> [TrackChangeWordSpan] {
        guard !rawEdits.isEmpty else { return [] }

        // Step 1: Canonicalize contiguous edit blocks so deletions always precede insertions
        let ordered = Self.canonicalizeEditBlockOrder(rawEdits)

        // Step 2: Merge adjacent tokens of identical edit kind into draft spans
        var spans = Self.collapseRawEditsToSpans(ordered)

        // Step 3: Coalesce isolated horizontal inter-word spaces sandwiched between phrase edits
        // while strictly preserving both baseline (equal+del) and revised (equal+ins) invariants!
        if coalesceInterWordWhitespaceInPhrases {
            spans = Self.coalesceSandwichedPhraseSpaces(spans)
        }

        return Self.mergeAdjacentIdenticalSpans(spans)
    }

    private static func canonicalizeEditBlockOrder(_ edits: [RawTokenEdit]) -> [RawTokenEdit] {
        var result: [RawTokenEdit] = []
        result.reserveCapacity(edits.count)

        var idx = 0
        while idx < edits.count {
            if case .equal = edits[idx] {
                result.append(edits[idx])
                idx += 1
                continue
            }

            var deletions: [RawTokenEdit] = []
            var insertions: [RawTokenEdit] = []
            while idx < edits.count {
                switch edits[idx] {
                case .deletion:
                    deletions.append(edits[idx])
                    idx += 1
                case .insertion:
                    insertions.append(edits[idx])
                    idx += 1
                case .equal:
                    break
                }
                if idx < edits.count, case .equal = edits[idx] {
                    break
                }
            }
            result.append(contentsOf: deletions)
            result.append(contentsOf: insertions)
        }

        return result
    }

    private static func collapseRawEditsToSpans(_ edits: [RawTokenEdit]) -> [TrackChangeWordSpan] {
        guard let first = edits.first else { return [] }
        var spans: [TrackChangeWordSpan] = []
        var activeKind = first.kind
        var buffer = first.token.rawText

        for edit in edits.dropFirst() {
            if edit.kind == activeKind {
                buffer.append(edit.token.rawText)
            } else {
                spans.append(TrackChangeWordSpan(kind: activeKind, text: buffer))
                activeKind = edit.kind
                buffer = edit.token.rawText
            }
        }
        spans.append(TrackChangeWordSpan(kind: activeKind, text: buffer))
        return spans
    }

    /// Absorbs isolated horizontal single-space `.equal` runs sandwiched between two adjacent
    /// replacement/edit blocks so multi-word phrase replacements coalesce into clean spans
    /// (`[-preliminary 800][+benchmarked 1,420]`) while maintaining exact baseline/revised reconstruction.
    private static func coalesceSandwichedPhraseSpaces(
        _ input: [TrackChangeWordSpan]
    ) -> [TrackChangeWordSpan] {
        guard input.count >= 3 else { return input }
        var spans = input
        var changed = true

        while changed {
            changed = false
            var nextPass: [TrackChangeWordSpan] = []
            var i = 0
            while i < spans.count {
                if spans[i].kind == .equal,
                   isHorizontalSpaceOnly(spans[i].text),
                   !nextPass.isEmpty,
                   nextPass.last?.kind != .equal,
                   i + 1 < spans.count,
                   spans[i + 1].kind != .equal
                {
                    let ws = spans[i].text
                    // Extract trailing non-equal hunk from nextPass
                    var leftEdits: [TrackChangeWordSpan] = []
                    while let last = nextPass.last, last.kind != .equal {
                        leftEdits.insert(nextPass.removeLast(), at: 0)
                    }
                    // Extract upcoming non-equal hunk from spans[(i+1)...]
                    var rightEdits: [TrackChangeWordSpan] = []
                    var j = i + 1
                    while j < spans.count && spans[j].kind != .equal {
                        rightEdits.append(spans[j])
                        j += 1
                    }

                    let leftDel = leftEdits.filter { $0.kind == .deletion }.map(\.text).joined()
                    let leftIns = leftEdits.filter { $0.kind == .insertion }.map(\.text).joined()
                    let rightDel = rightEdits.filter { $0.kind == .deletion }.map(\.text).joined()
                    let rightIns = rightEdits.filter { $0.kind == .insertion }.map(\.text).joined()

                    let mergedDel = leftDel + ws + rightDel
                    let mergedIns = leftIns + ws + rightIns

                    if !mergedDel.isEmpty {
                        nextPass.append(TrackChangeWordSpan(kind: .deletion, text: mergedDel))
                    }
                    if !mergedIns.isEmpty {
                        nextPass.append(TrackChangeWordSpan(kind: .insertion, text: mergedIns))
                    }
                    i = j
                    changed = true
                } else {
                    nextPass.append(spans[i])
                    i += 1
                }
            }
            spans = mergeAdjacentIdenticalSpans(nextPass)
        }

        return spans
    }

    private static func isHorizontalSpaceOnly(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func mergeAdjacentIdenticalSpans(
        _ spans: [TrackChangeWordSpan]
    ) -> [TrackChangeWordSpan] {
        var merged: [TrackChangeWordSpan] = []
        merged.reserveCapacity(spans.count)

        for span in spans where !span.text.isEmpty {
            if let last = merged.last, last.kind == span.kind {
                merged[merged.count - 1] = TrackChangeWordSpan(
                    id: last.id,
                    kind: last.kind,
                    text: last.text + span.text
                )
            } else {
                merged.append(span)
            }
        }

        return merged
    }

    private static func contiguousNonEqualSpanIDs(
        containing targetID: UUID,
        in spans: [TrackChangeWordSpan]
    ) -> [UUID] {
        guard let center = spans.firstIndex(where: { $0.id == targetID }),
              spans[center].kind != .equal
        else {
            return []
        }
        var start = center
        while start > 0 && spans[start - 1].kind != .equal {
            start -= 1
        }
        var end = center
        while end + 1 < spans.count && spans[end + 1].kind != .equal {
            end += 1
        }
        return spans[start...end].map(\.id)
    }

    private static func buildReport(
        id: UUID = UUID(),
        spans: [TrackChangeWordSpan],
        filePath: String,
        baselineLabel: String,
        revisedLabel: String,
        explicitEditDistance: Int?,
        createdAt: Date = Date()
    ) -> TrackChangesDiffReport {
        var insWords = 0
        var delWords = 0
        var eqWords = 0
        var insSpans = 0
        var delSpans = 0

        for span in spans {
            let words = countWordsInDiffSpan(span.text)
            switch span.kind {
            case .equal:
                eqWords += words
            case .insertion:
                insWords += words
                insSpans += 1
            case .deletion:
                delWords += words
                delSpans += 1
            }
        }

        let totalWordsDenominator = 2 * eqWords + insWords + delWords
        let similarity: Double
        if totalWordsDenominator == 0 {
            similarity = (insSpans == 0 && delSpans == 0) ? 1.0 : 0.0
        } else {
            similarity = Double(2 * eqWords) / Double(totalWordsDenominator)
        }

        let editDist = explicitEditDistance ?? (insWords + delWords + max(0, insSpans + delSpans - (insWords + delWords)))

        return TrackChangesDiffReport(
            id: id,
            filePath: filePath,
            baselineLabel: baselineLabel,
            revisedLabel: revisedLabel,
            spans: spans,
            insertedWordCount: insWords,
            deletedWordCount: delWords,
            unchangedWordCount: eqWords,
            insertionSpanCount: insSpans,
            deletionSpanCount: delSpans,
            editDistance: max(0, editDist),
            similarityRatio: min(1.0, max(0.0, similarity)),
            createdAt: createdAt
        )
    }

    private static func countWordsInDiffSpan(_ text: String) -> Int {
        tokenizeLosslessly(text).reduce(into: 0) { acc, tok in
            acc += tok.wordContribution
        }
    }
}
