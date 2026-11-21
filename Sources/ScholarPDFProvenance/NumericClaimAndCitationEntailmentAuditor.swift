import Foundation
import ScholarModels

// MARK: - Manuscript-Wide Cited Evidence Localization & Quantitative Checking
// Replaces the legacy `NumericClaimAndCitationEntailmentAuditor`: routes every cited sentence through
// `EvidenceLocatorAndNumericChecker` and outputs only `FOUND` / `NUMERIC_MISMATCH` / `NOT_FOUND`.

public struct ManuscriptCitedClaimSentence: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(filePath):\(startLine):\(citeKeysInSentence.joined(separator: ","))" }
    public let filePath: String
    public let startLine: Int
    public let endLine: Int
    public let span: TextSpan
    public let rawSentence: String
    public let citeKeysInSentence: [String]
    public let clauseByCiteKey: [String: String]

    public init(
        filePath: String,
        startLine: Int,
        endLine: Int,
        span: TextSpan,
        rawSentence: String,
        citeKeysInSentence: [String],
        clauseByCiteKey: [String: String]
    ) {
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.span = span
        self.rawSentence = rawSentence
        self.citeKeysInSentence = citeKeysInSentence
        self.clauseByCiteKey = clauseByCiteKey
    }
}

public struct CitedClaimEvidenceCheck: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let filePath: String
    public let startLine: Int
    public let span: TextSpan
    public let citeKey: String
    public let result: EvidenceLocalizationResult

    public init(
        id: UUID = UUID(),
        filePath: String,
        startLine: Int,
        span: TextSpan,
        citeKey: String,
        result: EvidenceLocalizationResult
    ) {
        self.id = id
        self.filePath = filePath
        self.startLine = startLine
        self.span = span
        self.citeKey = citeKey
        self.result = result
    }
}

public struct ManuscriptEvidenceAuditReport: Sendable, Codable, Hashable {
    public let manuscriptFile: String
    public let totalCitedClaimsChecked: Int
    public let foundCount: Int
    public let numericMismatchCount: Int
    public let notFoundCount: Int
    public let claimChecks: [CitedClaimEvidenceCheck]
    public let lspDiagnostics: [LSPDiagnostic]
    public let editorialFindings: [EditorialAuditFinding]

    public init(
        manuscriptFile: String,
        totalCitedClaimsChecked: Int,
        foundCount: Int,
        numericMismatchCount: Int,
        notFoundCount: Int,
        claimChecks: [CitedClaimEvidenceCheck],
        lspDiagnostics: [LSPDiagnostic],
        editorialFindings: [EditorialAuditFinding]
    ) {
        self.manuscriptFile = manuscriptFile
        self.totalCitedClaimsChecked = totalCitedClaimsChecked
        self.foundCount = foundCount
        self.numericMismatchCount = numericMismatchCount
        self.notFoundCount = notFoundCount
        self.claimChecks = claimChecks
        self.lspDiagnostics = lspDiagnostics
        self.editorialFindings = editorialFindings
    }
}

extension EvidenceLocatorAndNumericChecker {

    /// Segments a manuscript (`LaTeX`, `Typst`, or `Markdown`) into line-tracked cited sentences.
    public func extractCitedClaimSentences(
        manuscriptSource: String,
        filePath: String = "main.tex"
    ) -> [ManuscriptCitedClaimSentence] {
        let rawSegments = Self.splitIntoSentenceSpans(source: manuscriptSource, filePath: filePath)
        var results: [ManuscriptCitedClaimSentence] = []

        for seg in rawSegments {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("%") else { continue }

            let citeOccurrences = Self.locateCitationOccurrences(in: seg.text)
            guard !citeOccurrences.isEmpty else { continue }

            var orderedUniqueKeys: [String] = []
            var seenKeys = Set<String>()
            for occ in citeOccurrences {
                for k in occ.citeKeys where seenKeys.insert(k).inserted {
                    orderedUniqueKeys.append(k)
                }
            }

            var clauseByKey: [String: String] = [:]
            if orderedUniqueKeys.count == 1 {
                clauseByKey[orderedUniqueKeys[0]] = trimmed
            } else {
                // Split multi-citation contrast clauses (`;`, `, whereas`, `, while`) when possible
                let clauses = Self.splitMultiCitationClauses(in: trimmed)
                for key in orderedUniqueKeys {
                    if let matchingClause = clauses.first(where: { $0.contains(key) }) {
                        clauseByKey[key] = matchingClause
                    } else {
                        clauseByKey[key] = trimmed
                    }
                }
            }

            results.append(
                ManuscriptCitedClaimSentence(
                    filePath: filePath,
                    startLine: seg.span.start.line,
                    endLine: seg.span.end.line,
                    span: seg.span,
                    rawSentence: trimmed,
                    citeKeysInSentence: orderedUniqueKeys,
                    clauseByCiteKey: clauseByKey
                )
            )
        }

        return results
    }

    public func locateManuscriptClaims(
        manuscriptSource: String,
        filePath: String = "main.tex",
        provenanceIndex: FTS5ProvenanceIndex
    ) throws -> ManuscriptEvidenceAuditReport {
        let citedSentences = extractCitedClaimSentences(manuscriptSource: manuscriptSource, filePath: filePath)
        var checks: [CitedClaimEvidenceCheck] = []

        for sent in citedSentences {
            for citeKey in sent.citeKeysInSentence {
                let claimText = sent.clauseByCiteKey[citeKey] ?? sent.rawSentence
                let result = try locateEvidence(
                    claim: claimText,
                    in: provenanceIndex,
                    citeKeyFilter: citeKey,
                    topK: 3
                )
                checks.append(
                    CitedClaimEvidenceCheck(
                        filePath: filePath,
                        startLine: sent.startLine,
                        span: sent.span,
                        citeKey: citeKey,
                        result: result
                    )
                )
            }
        }

        return Self.summarizeManuscriptChecks(manuscriptFile: filePath, checks: checks)
    }

    public func locateManuscriptClaims(
        manuscriptSource: String,
        filePath: String = "main.tex",
        passages: [PDFPassageChunk]
    ) -> ManuscriptEvidenceAuditReport {
        let citedSentences = extractCitedClaimSentences(manuscriptSource: manuscriptSource, filePath: filePath)
        var checks: [CitedClaimEvidenceCheck] = []

        for sent in citedSentences {
            for citeKey in sent.citeKeysInSentence {
                let claimText = sent.clauseByCiteKey[citeKey] ?? sent.rawSentence
                let result = locateEvidence(
                    claim: claimText,
                    passages: passages,
                    citeKeyFilter: citeKey,
                    topK: 3
                )
                checks.append(
                    CitedClaimEvidenceCheck(
                        filePath: filePath,
                        startLine: sent.startLine,
                        span: sent.span,
                        citeKey: citeKey,
                        result: result
                    )
                )
            }
        }

        return Self.summarizeManuscriptChecks(manuscriptFile: filePath, checks: checks)
    }

    private static func summarizeManuscriptChecks(
        manuscriptFile: String,
        checks: [CitedClaimEvidenceCheck]
    ) -> ManuscriptEvidenceAuditReport {
        var found = 0
        var mismatch = 0
        var notFound = 0
        var lspList: [LSPDiagnostic] = []
        var findings: [EditorialAuditFinding] = []

        for item in checks {
            switch item.result.verdict {
            case .found:
                found += 1
            case .numericMismatch:
                mismatch += 1
                let reasons = item.result.discrepancies.map(\.reason).joined(separator: " ")
                let firstHint: String?
                if let first = item.result.discrepancies.first, let pdfTxt = first.pdfText {
                    firstHint = "Update '\(first.claimText)' to match source PDF value '\(pdfTxt)'."
                } else {
                    firstHint = nil
                }
                lspList.append(
                    LSPDiagnostic(
                        code: "ERR_NUMERIC_DISCREPANCY",
                        severity: .error,
                        message: reasons,
                        span: item.span,
                        suggestedFix: firstHint
                    )
                )
                findings.append(
                    EditorialAuditFinding(
                        pluginID: "builtin.provenance.evidence-locator",
                        pluginName: "Evidence Locator & Numeric Checker",
                        severity: .submissionBlocker,
                        category: "Numeric Citation Discrepancy",
                        filePath: manuscriptFile,
                        line: item.startLine,
                        matchedExcerpt: item.result.claim,
                        explanation: reasons,
                        suggestedRewrite: firstHint
                    )
                )
            case .notFound:
                notFound += 1
                let msg = "No passage in attached PDF for '\(item.citeKey)' met the keyword coverage threshold."
                lspList.append(
                    LSPDiagnostic(
                        code: "WARN_EVIDENCE_NOT_FOUND",
                        severity: .warning,
                        message: msg,
                        span: item.span,
                        suggestedFix: "Verify whether '\\cite{\(item.citeKey)}' discusses this topic."
                    )
                )
                findings.append(
                    EditorialAuditFinding(
                        pluginID: "builtin.provenance.evidence-locator",
                        pluginName: "Evidence Locator & Numeric Checker",
                        severity: .rigorWarning,
                        category: "Unlocated Cited Passage",
                        filePath: manuscriptFile,
                        line: item.startLine,
                        matchedExcerpt: item.result.claim,
                        explanation: msg,
                        suggestedRewrite: nil
                    )
                )
            }
        }

        return ManuscriptEvidenceAuditReport(
            manuscriptFile: manuscriptFile,
            totalCitedClaimsChecked: checks.count,
            foundCount: found,
            numericMismatchCount: mismatch,
            notFoundCount: notFound,
            claimChecks: checks,
            lspDiagnostics: lspList,
            editorialFindings: findings
        )
    }

    // MARK: - Citation Span & Sentence Splitting Helpers

    private struct CitationOccurrenceSpan {
        let offset: Int
        let citeKeys: [String]
    }

    private static func splitMultiCitationClauses(in sentence: String) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: #"(?:;\s*|,\s*(?:whereas|while)\s+)"#, options: [.caseInsensitive]) else {
            return [sentence]
        }
        let ns = sentence as NSString
        var parts: [String] = []
        var last = 0
        for m in rx.matches(in: sentence, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            }
            last = m.range.location + m.range.length
        }
        if last < ns.length {
            parts.append(ns.substring(from: last))
        }
        return parts.isEmpty ? [sentence] : parts
    }

    private static func locateCitationOccurrences(in sentence: String) -> [CitationOccurrenceSpan] {
        let ns = sentence as NSString
        let full = NSRange(location: 0, length: ns.length)
        var occurrences: [CitationOccurrenceSpan] = []

        if let texRegex = try? NSRegularExpression(
            pattern: #"\\(?:cite[a-zA-Z]*|parencite|textcite|autocite|footcite)\*?(?:\[[^\]]*\])*\{([^}]+)\}"#
        ) {
            for m in texRegex.matches(in: sentence, range: full) {
                let keys = ns.substring(with: m.range(at: 1))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !keys.isEmpty {
                    occurrences.append(CitationOccurrenceSpan(offset: m.range.location, citeKeys: keys))
                }
            }
        }

        if let typstRegex = try? NSRegularExpression(pattern: #"#cite\(\s*<([A-Za-z0-9_:-]+)>\s*\)"#) {
            for m in typstRegex.matches(in: sentence, range: full) {
                let k = ns.substring(with: m.range(at: 1))
                occurrences.append(CitationOccurrenceSpan(offset: m.range.location, citeKeys: [k]))
            }
        }

        if let mdRegex = try? NSRegularExpression(pattern: #"(?:^|[\s\[\(;])@([A-Za-z][A-Za-z0-9_:-]{2,})"#) {
            for m in mdRegex.matches(in: sentence, range: full) {
                let k = ns.substring(with: m.range(at: 1))
                occurrences.append(CitationOccurrenceSpan(offset: m.range.location, citeKeys: [k]))
            }
        }

        return occurrences.sorted { $0.offset < $1.offset }
    }

    private static func splitIntoSentenceSpans(
        source: String,
        filePath: String
    ) -> [(text: String, span: TextSpan)] {
        var segments: [(String, TextSpan)] = []
        let lines = source.components(separatedBy: "\n")

        var buffer = ""
        var startLine = 1
        var startCol = 1
        var startOffset = 0
        var runningOffset = 0

        let abbreviations = ["et al.", "e.g.", "i.e.", "Fig.", "Figs.", "Eq.", "Sec.", "cf.", "vs.", "Dr.", "Prof."]

        for (lineIdx, rawLine) in lines.enumerated() {
            let lineNum = lineIdx + 1
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmedLine.isEmpty
                || trimmedLine.hasPrefix("\\section")
                || trimmedLine.hasPrefix("\\subsection")
                || trimmedLine.hasPrefix("\\begin{")
                || trimmedLine.hasPrefix("\\end{")
                || trimmedLine.hasPrefix("# ")
                || trimmedLine.hasPrefix("## ")
                || trimmedLine.hasPrefix("= ") {
                if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let span = TextSpan(
                        filePath: filePath,
                        start: TextPosition(line: startLine, column: startCol, utf8Offset: startOffset),
                        end: TextPosition(line: max(1, lineNum - 1), column: 1, utf8Offset: runningOffset)
                    )
                    segments.append((buffer, span))
                    buffer = ""
                }
                runningOffset += rawLine.utf8.count + 1
                startLine = lineNum + 1
                startCol = 1
                startOffset = runningOffset
                continue
            }

            if trimmedLine.hasPrefix("%") {
                runningOffset += rawLine.utf8.count + 1
                continue
            }

            if buffer.isEmpty {
                startLine = lineNum
                startCol = 1
                startOffset = runningOffset
            } else {
                buffer.append(" ")
            }

            var colCursor = 1
            for ch in rawLine {
                buffer.append(ch)
                if ch == "." || ch == "!" || ch == "?" || ch == "。" || ch == "！" || ch == "？" {
                    let isAbbrev = abbreviations.contains { buffer.hasSuffix($0) }
                    let isDecimal = buffer.count >= 2 && buffer.dropLast().last?.isNumber == true
                    if !isAbbrev && !isDecimal {
                        let span = TextSpan(
                            filePath: filePath,
                            start: TextPosition(line: startLine, column: startCol, utf8Offset: startOffset),
                            end: TextPosition(line: lineNum, column: colCursor + 1, utf8Offset: runningOffset + colCursor)
                        )
                        segments.append((buffer, span))
                        buffer = ""
                        startLine = lineNum
                        startCol = colCursor + 1
                        startOffset = runningOffset + colCursor
                    }
                }
                colCursor += 1
            }

            runningOffset += rawLine.utf8.count + 1
        }

        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let span = TextSpan(
                filePath: filePath,
                start: TextPosition(line: startLine, column: startCol, utf8Offset: startOffset),
                end: TextPosition(line: max(1, lines.count), column: 1, utf8Offset: runningOffset)
            )
            segments.append((buffer, span))
        }

        return segments
    }
}
