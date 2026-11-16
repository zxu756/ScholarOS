import Foundation
import ScholarModels
import ScholarMarkupAST
import ScholarBibAndCSL

// MARK: - Academic Cursor Completion Trigger & Context Models

public enum AcademicCompletionTriggerKind: String, Sendable, Codable, Hashable, CaseIterable {
    case citation = "citation"
    case crossReference = "cross_reference"
    case environment = "environment"
    case environmentClose = "environment_close"
    case commandOrMacro = "command_or_macro"
    case mathSymbolOrCommand = "math_symbol_or_command"
    case typstDirective = "typst_directive"
    case fileInclude = "file_include"
    case comment = "comment"
    case prose = "prose"
}

public struct AcademicCompletionContext: Sendable, Codable, Hashable {
    public let filePath: String
    public let format: ManuscriptFormat
    public let cursorPosition: TextPosition
    public let triggerKind: AcademicCompletionTriggerKind
    public let activeCommand: String?
    public let queryPrefix: String
    public let replacementSpan: TextSpan
    public let isInsideMathMode: Bool
    public let alreadyCitedKeysInCluster: [String]
    public let expectedLabelCategory: LabelCategory?
    public let unclosedEnvironmentStack: [String]

    public init(
        filePath: String,
        format: ManuscriptFormat,
        cursorPosition: TextPosition,
        triggerKind: AcademicCompletionTriggerKind,
        activeCommand: String? = nil,
        queryPrefix: String = "",
        replacementSpan: TextSpan,
        isInsideMathMode: Bool = false,
        alreadyCitedKeysInCluster: [String] = [],
        expectedLabelCategory: LabelCategory? = nil,
        unclosedEnvironmentStack: [String] = []
    ) {
        self.filePath = filePath
        self.format = format
        self.cursorPosition = cursorPosition
        self.triggerKind = triggerKind
        self.activeCommand = activeCommand
        self.queryPrefix = queryPrefix
        self.replacementSpan = replacementSpan
        self.isInsideMathMode = isInsideMathMode
        self.alreadyCitedKeysInCluster = alreadyCitedKeysInCluster
        self.expectedLabelCategory = expectedLabelCategory
        self.unclosedEnvironmentStack = unclosedEnvironmentStack
    }
}

public struct LatexEnvironmentTemplate: Sendable, Codable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let displayTitle: String
    public let groupCategory: String
    public let summary: String
    public let packageRequirement: String?
    public let snippetBody: String
    public let autoLabelPrefix: String?
    public let isMathEnvironment: Bool
    public let isFloatEnvironment: Bool

    public init(
        name: String,
        displayTitle: String? = nil,
        groupCategory: String,
        summary: String,
        packageRequirement: String? = nil,
        snippetBody: String,
        autoLabelPrefix: String? = nil,
        isMathEnvironment: Bool = false,
        isFloatEnvironment: Bool = false
    ) {
        self.name = name
        self.displayTitle = displayTitle ?? name
        self.groupCategory = groupCategory
        self.summary = summary
        self.packageRequirement = packageRequirement
        self.snippetBody = snippetBody
        self.autoLabelPrefix = autoLabelPrefix
        self.isMathEnvironment = isMathEnvironment
        self.isFloatEnvironment = isFloatEnvironment
    }

    /// Full `\begin{...} ... \end{...}` expansion used when completing after `\begin{`.
    public func fullEnvironmentInsertion(includeBeginCommand: Bool = false) -> String {
        let envTag = realLatexEnvironmentTag
        let header = includeBeginCommand ? "\\begin{\(envTag)}" : "\(envTag)}"
        return "\(header)\n\(snippetBody)\n\\end{\(envTag)}"
    }

    public var realLatexEnvironmentTag: String {
        if name == "booktabs" {
            return "table"
        }
        return name
    }
}

public struct BuiltinCommandAndMathEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(format.rawValue):\(trigger)" }
    public let trigger: String
    public let insertText: String
    public let unicodePreview: String?
    public let summary: String
    public let packageHint: String?
    public let category: LSPCompletionCategory
    public let format: ManuscriptFormat
    public let mathOnly: Bool

    public init(
        trigger: String,
        insertText: String,
        unicodePreview: String? = nil,
        summary: String,
        packageHint: String? = nil,
        category: LSPCompletionCategory,
        format: ManuscriptFormat = .latex,
        mathOnly: Bool = false
    ) {
        self.trigger = trigger
        self.insertText = insertText
        self.unicodePreview = unicodePreview
        self.summary = summary
        self.packageHint = packageHint
        self.category = category
        self.format = format
        self.mathOnly = mathOnly
    }
}

// MARK: - Academic Completion Engine

public struct AcademicCompletionEngine: Sendable {
    public let cslFormatter: CSLCitationFormatterEngine
    public let firewall: CitationVerificationFirewall

    public init(
        cslFormatter: CSLCitationFormatterEngine = CSLCitationFormatterEngine(),
        firewall: CitationVerificationFirewall = CitationVerificationFirewall()
    ) {
        self.cslFormatter = cslFormatter
        self.firewall = firewall
    }

    // MARK: - Cursor Position Normalization

    public static func normalizeCursorPosition(
        _ position: TextPosition,
        in source: String,
        lineIndex: LineByteIndex? = nil
    ) -> TextPosition {
        let idx = lineIndex ?? LineByteIndex(source: source)
        let utf8Count = source.utf8.count
        if position.utf8Offset > 0 || (position.line <= 1 && position.column <= 1) {
            let clamped = max(0, min(utf8Count, position.utf8Offset))
            if clamped == position.utf8Offset && position.line >= 1 && position.column >= 1 {
                return position
            }
            return idx.position(forUTF8Offset: clamped, in: source)
        }
        let computedOffset = idx.utf8Offset(forLine: max(1, position.line), column: max(1, position.column), in: source)
        return idx.position(forUTF8Offset: computedOffset, in: source)
    }

    // MARK: - Backwards Trigger Context Detector

    public func detectContext(
        in source: String,
        filePath: String = "main.tex",
        at position: TextPosition,
        lineIndex: LineByteIndex? = nil
    ) -> AcademicCompletionContext {
        let format = ManuscriptFormat.detect(fromPath: filePath)
        let idx = lineIndex ?? LineByteIndex(source: source)
        let cursor = Self.normalizeCursorPosition(position, in: source, lineIndex: idx)
        let bytes = Array(source.utf8)
        let cursorByte = max(0, min(bytes.count, cursor.utf8Offset))

        let lineStartByte = idx.startUTF8Offset(ofLine: cursor.line)
        let linePrefixBytes = Array(bytes[lineStartByte..<cursorByte])
        let linePrefix = String(decoding: linePrefixBytes, as: UTF8.self)

        // 1. Check if cursor is inside a line comment (`%` in LaTeX, `//` in Typst)
        if isInsideComment(linePrefix: linePrefix, format: format) {
            let emptySpan = TextSpan(filePath: filePath, start: cursor, end: cursor)
            return AcademicCompletionContext(
                filePath: filePath,
                format: format,
                cursorPosition: cursor,
                triggerKind: .comment,
                replacementSpan: emptySpan
            )
        }

        // 2. Scan structural state (math mode + open environment stack) up to `cursorByte`
        let scanState = scanDocumentStateUpToCursor(bytes: bytes, cursorByte: cursorByte, format: format)

        // Look back up to ~512 bytes (multi-line `\cite{\n  key1,\n  key2` is common in scholarly LaTeX!)
        let windowStartByte = max(0, cursorByte - 768)
        let windowText = String(decoding: bytes[windowStartByte..<cursorByte], as: UTF8.self)

        switch format {
        case .latex:
            if let latexBraceCtx = detectLatexBracedOrBracketedContext(
                windowText: windowText,
                windowStartByte: windowStartByte,
                cursor: cursor,
                filePath: filePath,
                source: source,
                lineIndex: idx,
                scanState: scanState
            ) {
                return latexBraceCtx
            }

            if let latexCmdCtx = detectLatexSlashCommandContext(
                linePrefix: linePrefix,
                lineStartByte: lineStartByte,
                cursor: cursor,
                filePath: filePath,
                source: source,
                lineIndex: idx,
                scanState: scanState
            ) {
                return latexCmdCtx
            }

        case .typst:
            if let typstCtx = detectTypstContext(
                windowText: windowText,
                windowStartByte: windowStartByte,
                linePrefix: linePrefix,
                lineStartByte: lineStartByte,
                cursor: cursor,
                filePath: filePath,
                source: source,
                lineIndex: idx,
                scanState: scanState
            ) {
                return typstCtx
            }

        case .markdown:
            if let mdCtx = detectMarkdownCitationContext(
                linePrefix: linePrefix,
                lineStartByte: lineStartByte,
                cursor: cursor,
                filePath: filePath,
                source: source,
                lineIndex: idx,
                scanState: scanState
            ) {
                return mdCtx
            }
        }

        let emptySpan = TextSpan(filePath: filePath, start: cursor, end: cursor)
        return AcademicCompletionContext(
            filePath: filePath,
            format: format,
            cursorPosition: cursor,
            triggerKind: scanState.inMathMode ? .mathSymbolOrCommand : .prose,
            replacementSpan: emptySpan,
            isInsideMathMode: scanState.inMathMode,
            unclosedEnvironmentStack: scanState.openEnvironments
        )
    }

    // MARK: - Unified Completion Entry Points

    public func complete(
        in workspace: MergedManuscriptWorkspaceAST,
        filePath: String? = nil,
        sourceOverride: String? = nil,
        at position: TextPosition,
        bibliography: [BibliographyEntry] = [],
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict] = [:],
        maxItems: Int = 50
    ) -> [LSPCompletionItem] {
        let targetFile = filePath ?? workspace.includeGraph.rootFilePath
        let source: String
        if let override = sourceOverride {
            source = override
        } else if let pr = workspace.perFileParseResults[targetFile] {
            source = pr.tokens.map(\.lexeme).joined()
        } else {
            source = ""
        }
        let knownFiles = Array(workspace.perFileParseResults.keys) + workspace.includeGraph.bibliographyFiles
        return complete(
            in: source,
            filePath: targetFile,
            at: position,
            symbolTable: workspace.symbolTable,
            bibliography: bibliography,
            inRunVerdictsByKey: inRunVerdictsByKey,
            workspaceFiles: knownFiles,
            maxItems: maxItems
        )
    }

    public func complete(
        in source: String,
        filePath: String = "main.tex",
        at position: TextPosition,
        symbolTable: ManuscriptSymbolTable = .empty,
        bibliography: [BibliographyEntry] = [],
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict] = [:],
        workspaceFiles: [String] = [],
        maxItems: Int = 50
    ) -> [LSPCompletionItem] {
        let idx = LineByteIndex(source: source)
        let context = detectContext(in: source, filePath: filePath, at: position, lineIndex: idx)
        return complete(
            for: context,
            in: source,
            symbolTable: symbolTable,
            bibliography: bibliography,
            inRunVerdictsByKey: inRunVerdictsByKey,
            workspaceFiles: workspaceFiles,
            maxItems: maxItems
        )
    }

    public func complete(
        for context: AcademicCompletionContext,
        in source: String = "",
        symbolTable: ManuscriptSymbolTable = .empty,
        bibliography: [BibliographyEntry] = [],
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict] = [:],
        workspaceFiles: [String] = [],
        maxItems: Int = 50
    ) -> [LSPCompletionItem] {
        let limit = max(1, maxItems)
        var results: [LSPCompletionItem] = []

        switch context.triggerKind {
        case .comment, .prose:
            return []

        case .citation:
            results = rankCitationCompletions(
                context: context,
                bibliography: bibliography,
                inRunVerdictsByKey: inRunVerdictsByKey,
                symbolTable: symbolTable
            )
            // In Typst `@...` shorthand, `@` also addresses `<label>` anchors (`@fig:...`, `@sec:...`)!
            if context.format == .typst && context.activeCommand == "@" {
                let labelItems = rankCrossReferenceCompletions(
                    context: context,
                    symbolTable: symbolTable
                )
                results.append(contentsOf: labelItems)
            }

        case .crossReference:
            results = rankCrossReferenceCompletions(
                context: context,
                symbolTable: symbolTable
            )
            // If Typst `@` started with a prefix that could also match a citeKey, include high-scoring citations
            if context.format == .typst && context.activeCommand == "@" {
                let citeItems = rankCitationCompletions(
                    context: context,
                    bibliography: bibliography,
                    inRunVerdictsByKey: inRunVerdictsByKey,
                    symbolTable: symbolTable
                ).filter { $0.relevanceScore >= 0.45 }
                results.append(contentsOf: citeItems)
            }

        case .environment:
            results = rankEnvironmentCompletions(
                context: context,
                in: source
            )

        case .environmentClose:
            results = rankEnvironmentCloseCompletions(context: context)

        case .fileInclude:
            results = rankFileIncludeCompletions(
                context: context,
                workspaceFiles: workspaceFiles
            )

        case .commandOrMacro, .mathSymbolOrCommand, .typstDirective:
            results = rankCommandMathAndMacroCompletions(
                context: context,
                symbolTable: symbolTable
            )
        }

        // Deduplicate by `id` keeping highest relevanceScore, sort deterministically, and cap to `limit`.
        var bestByID: [String: LSPCompletionItem] = [:]
        bestByID.reserveCapacity(results.count)
        for item in results {
            if let existing = bestByID[item.id] {
                if item.relevanceScore > existing.relevanceScore {
                    bestByID[item.id] = item
                }
            } else {
                bestByID[item.id] = item
            }
        }

        let sorted = bestByID.values.sorted { lhs, rhs in
            if abs(lhs.relevanceScore - rhs.relevanceScore) > 1e-6 {
                return lhs.relevanceScore > rhs.relevanceScore
            }
            return lhs.title < rhs.title
        }
        return Array(sorted.prefix(limit))
    }

    // MARK: - Citation Fuzzy Ranking & Firewall Status Decoration

    private func rankCitationCompletions(
        context: AcademicCompletionContext,
        bibliography: [BibliographyEntry],
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict],
        symbolTable: ManuscriptSymbolTable
    ) -> [LSPCompletionItem] {
        let query = context.queryPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let alreadyCited = Set(context.alreadyCitedKeysInCluster)
        var items: [LSPCompletionItem] = []
        items.reserveCapacity(bibliography.count)

        for entry in bibliography {
            if alreadyCited.contains(entry.citeKey) {
                continue
            }

            let (effectiveFirewallClass, effectiveAuditNote) = resolveEffectiveFirewallClass(
                for: entry,
                inRunVerdictsByKey: inRunVerdictsByKey
            )
            let baseMatchScore = scoreBibliographyMatch(entry: entry, query: query)
            guard baseMatchScore > 0.0 else { continue }

            // Apply Citation Firewall boost / demotion
            let firewallDelta: Double
            let statusPrefix: String
            let firewallWarningMarkdown: String

            switch effectiveFirewallClass {
            case .verified:
                firewallDelta = 0.20
                statusPrefix = "[✓ Verified]"
                firewallWarningMarkdown = "**Firewall Status:** `VERIFIED` — \(effectiveAuditNote)"
            case .drift:
                firewallDelta = -0.15
                statusPrefix = "[⚠ Metadata Drift]"
                let note = effectiveAuditNote.isEmpty ? "Metadata discrepancy vs external registry." : effectiveAuditNote
                firewallWarningMarkdown = "**Firewall Status:** `DRIFT` — \(note)"
            case .unverified:
                firewallDelta = -0.25
                statusPrefix = "[⚠ UNVERIFIED]"
                let note = effectiveAuditNote.isEmpty ? "Entry has not been verified against external registries." : effectiveAuditNote
                firewallWarningMarkdown = "> **WARNING (`ERR_UNVERIFIED_CITATION`):** Unverified reference (`UNVERIFIED`). \(note)"
            case .notFound:
                firewallDelta = -0.55
                statusPrefix = "[⛔ NOT FOUND]"
                let note = effectiveAuditNote.isEmpty ? "Identifier not found or failed structural check." : effectiveAuditNote
                firewallWarningMarkdown = "> **BLOCKED (`ERR_UNVERIFIED_CITATION`):** Citation Firewall marks this entry `NOT_FOUND`. \(note)"
            case .retracted:
                firewallDelta = -0.60
                statusPrefix = "[⛔ RETRACTED]"
                let note = effectiveAuditNote.isEmpty ? "Marked as retracted work." : effectiveAuditNote
                firewallWarningMarkdown = "> **BLOCKED (`ERR_UNVERIFIED_CITATION`):** Citation Firewall marks this entry `RETRACTED`. \(note)"
            }

            // Slight popularity boost if already cited elsewhere in the manuscript
            let manuscriptCitationCount = symbolTable.citationsByKey[entry.citeKey]?.count ?? 0
            let usageBoost = min(0.06, Double(manuscriptCitationCount) * 0.015)
            let finalScore = max(0.01, min(1.50, baseMatchScore + firewallDelta + usageBoost))

            let apaFormatted = cslFormatter.formatEntry(entry, style: .apa7)
            let yearText = entry.year.map(String.init) ?? "n.d."
            let authorShort = formatShortAuthorHeader(entry.authors)
            let subtitle = "\(statusPrefix) \(authorShort) (\(yearText)) · \(truncateText(entry.title, maxChars: 64))"

            var detailLines: [String] = []
            detailLines.append(firewallWarningMarkdown)
            detailLines.append("")
            detailLines.append("**APA 7th Preview:**")
            detailLines.append(apaFormatted.bibliographyMarkdown)
            var idBadges: [String] = []
            if let doi = entry.doi, !doi.isEmpty { idBadges.append("DOI: `\(doi)`") }
            if let arxiv = entry.arxivID, !arxiv.isEmpty { idBadges.append("arXiv: `\(arxiv)`") }
            if let pmid = entry.pmid, !pmid.isEmpty { idBadges.append("PMID: `\(pmid)`") }
            if !idBadges.isEmpty {
                detailLines.append("")
                detailLines.append(idBadges.joined(separator: " · "))
            }
            if manuscriptCitationCount > 0 {
                detailLines.append("")
                detailLines.append("_Cited \(manuscriptCitationCount) time\(manuscriptCitationCount == 1 ? "" : "s") in workspace._")
            }

            let insertion: String
            if context.format == .typst && context.activeCommand == "#cite" {
                insertion = entry.citeKey
            } else {
                insertion = entry.citeKey
            }

            items.append(
                LSPCompletionItem(
                    id: "cite:\(entry.citeKey)",
                    insertText: insertion,
                    title: entry.citeKey,
                    subtitle: subtitle,
                    detailMarkdown: detailLines.joined(separator: "\n"),
                    category: .citation,
                    relevanceScore: finalScore
                )
            )
        }

        return items
    }

    private func resolveEffectiveFirewallClass(
        for entry: BibliographyEntry,
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict]
    ) -> (CitationFirewallClass, String) {
        firewall.resolveEffectiveStatus(for: entry, inRunVerdictsByKey: inRunVerdictsByKey)
    }

    private func scoreBibliographyMatch(entry: BibliographyEntry, query: String) -> Double {
        if query.isEmpty {
            return 0.80
        }
        let q = query.lowercased()
        let keyLower = entry.citeKey.lowercased()

        var best = 0.0
        // 1. CiteKey match
        if keyLower == q {
            best = max(best, 1.00)
        } else if keyLower.hasPrefix(q) {
            best = max(best, 0.96)
        } else if let subseq = fuzzySubsequenceScore(query: q, candidate: keyLower) {
            best = max(best, 0.62 + 0.30 * subseq)
        }

        // 2. Author surname match
        for (idx, author) in entry.authors.enumerated() {
            let fam = author.familyName.lowercased()
            let authorWeight = (idx == 0) ? 1.0 : 0.90
            if fam == q {
                best = max(best, 0.92 * authorWeight)
            } else if fam.hasPrefix(q) {
                best = max(best, 0.88 * authorWeight)
            } else if fam.contains(q) {
                best = max(best, 0.74 * authorWeight)
            }
        }

        // 3. Year match (standalone or combined like "vaswani 2017" / "2017")
        if let yr = entry.year {
            let yrStr = String(yr)
            if yrStr == q {
                best = max(best, 0.86)
            } else if yrStr.hasPrefix(q) && q.count >= 2 {
                best = max(best, 0.76)
            }
        }

        // 4. Title & venue keyword / multi-token query match
        let titleLower = entry.title.lowercased()
        let venueLower = entry.venue.lowercased()
        if titleLower.hasPrefix(q) {
            best = max(best, 0.85)
        } else if titleLower.contains(q) {
            best = max(best, 0.78)
        } else if !venueLower.isEmpty && venueLower.contains(q) {
            best = max(best, 0.68)
        }

        // Multi-term split query (e.g. "vaswani attention 2017" or "smithtransformer")
        let tokens = q.split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" || $0 == ":" }).map(String.init)
        if tokens.count > 1 {
            let searchableBlob = "\(keyLower) \(entry.authors.map { $0.familyName.lowercased() }.joined(separator: " ")) \(entry.year.map(String.init) ?? "") \(titleLower) \(venueLower)"
            let matchedCount = tokens.filter { searchableBlob.contains($0) }.count
            if matchedCount == tokens.count {
                best = max(best, 0.91)
            } else if matchedCount > 0 {
                best = max(best, 0.55 * (Double(matchedCount) / Double(tokens.count)))
            }
        } else if best == 0.0, let titleSub = fuzzySubsequenceScore(query: q, candidate: titleLower), titleSub > 0.65 {
            best = max(best, 0.52 * titleSub)
        }

        return best
    }

    // MARK: - Cross-Reference Ranking (`\ref`, `\eqref`, `\cref`, `@fig:...`)

    private func rankCrossReferenceCompletions(
        context: AcademicCompletionContext,
        symbolTable: ManuscriptSymbolTable
    ) -> [LSPCompletionItem] {
        let query = context.queryPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let qLower = query.lowercased()
        let isEqref = (context.activeCommand == "\\eqref")
        let alreadyListed = Set(context.alreadyCitedKeysInCluster)
        var items: [LSPCompletionItem] = []
        items.reserveCapacity(symbolTable.labelsByKey.count)

        for (_, record) in symbolTable.labelsByKey {
            if alreadyListed.contains(record.key) {
                continue
            }
            let keyLower = record.key.lowercased()
            let captionLower = (record.enclosingTitleOrCaption ?? "").lowercased()

            var score: Double = 0.0
            if qLower.isEmpty {
                score = 0.80
            } else if keyLower == qLower {
                score = 1.00
            } else if keyLower.hasPrefix(qLower) {
                score = 0.96
            } else if keyLower.contains(qLower) {
                score = 0.84
            } else if !captionLower.isEmpty && captionLower.contains(qLower) {
                score = 0.76
            } else if let subseq = fuzzySubsequenceScore(query: qLower, candidate: keyLower) {
                score = 0.58 + 0.30 * subseq
            }

            guard score > 0.0 else { continue }

            // Boost matching semantic label category (`equation` inside `\eqref`, or `fig:`/`tab:`/`sec:` prefix)
            if isEqref {
                if record.category == .equation {
                    score += 0.26
                } else if record.category == .general {
                    score += 0.02
                } else {
                    score -= 0.30
                }
            } else if let expected = context.expectedLabelCategory {
                if record.category == expected {
                    score += 0.22
                }
            }

            let contextDesc = record.enclosingTitleOrCaption
                ?? record.enclosingEnvironment.map { "\\begin{\($0)}" }
                ?? record.category.rawValue
            let subtitle = "[\(record.category.rawValue)] \(truncateText(contextDesc, maxChars: 60)) (\(record.filePath):\(record.span.start.line))"

            var md: [String] = []
            md.append("**Label:** `\(record.key)` (`\(record.category.rawValue)`)")
            md.append("**Declared at:** `\(record.filePath):\(record.span.start.line)`")
            if let env = record.enclosingEnvironment {
                md.append("**Environment:** `\(env)`")
            }
            if let cap = record.enclosingTitleOrCaption, !cap.isEmpty {
                md.append("")
                md.append("> \(cap)")
            }

            items.append(
                LSPCompletionItem(
                    id: "label:\(record.key)",
                    insertText: record.key,
                    title: record.key,
                    subtitle: subtitle,
                    detailMarkdown: md.joined(separator: "\n"),
                    category: .labelRef,
                    relevanceScore: max(0.05, min(1.45, score))
                )
            )
        }

        return items
    }

    // MARK: - Scholarly LaTeX Environments Ranking (48+ Environments)

    private func rankEnvironmentCompletions(
        context: AcademicCompletionContext,
        in source: String
    ) -> [LSPCompletionItem] {
        let query = context.queryPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lineHasClosingBrace = doesCurrentLineAlreadyCloseBrace(source: source, afterUTF8Offset: context.cursorPosition.utf8Offset)

        var items: [LSPCompletionItem] = []
        items.reserveCapacity(Self.builtinEnvironments.count)

        for env in Self.builtinEnvironments {
            let nameLower = env.name.lowercased()
            let titleLower = env.displayTitle.lowercased()
            var score: Double = 0.0
            if query.isEmpty {
                score = 0.82
            } else if nameLower == query {
                score = 1.00
            } else if nameLower.hasPrefix(query) || titleLower.hasPrefix(query) {
                score = 0.95
            } else if nameLower.contains(query) || titleLower.contains(query) {
                score = 0.82
            } else if let sub = fuzzySubsequenceScore(query: query, candidate: nameLower) {
                score = 0.55 + 0.30 * sub
            }
            guard score > 0.0 else { continue }

            if context.isInsideMathMode && env.isMathEnvironment {
                score += 0.12
            }

            let insertion: String
            if lineHasClosingBrace {
                // User already has `\begin{}` with closing brace; insert just the environment tag if editing inside `{...}`
                insertion = env.realLatexEnvironmentTag
            } else {
                insertion = env.fullEnvironmentInsertion(includeBeginCommand: false)
            }

            let pkgSuffix = env.packageRequirement.map { " · pkg: \($0)" } ?? ""
            let subtitle = "[\(env.groupCategory)] \(env.summary)\(pkgSuffix)"

            var md: [String] = []
            md.append("**Environment:** `\\begin{\(env.realLatexEnvironmentTag)} ... \\end{\(env.realLatexEnvironmentTag)}`")
            if let pkg = env.packageRequirement {
                md.append("**Required Package:** `\\usepackage{\(pkg)}`")
            }
            md.append("")
            md.append("```latex")
            md.append("\\begin{\(env.realLatexEnvironmentTag)}")
            md.append(env.snippetBody)
            md.append("\\end{\(env.realLatexEnvironmentTag)}")
            md.append("```")

            items.append(
                LSPCompletionItem(
                    id: "env:\(env.name)",
                    insertText: insertion,
                    title: env.displayTitle,
                    subtitle: subtitle,
                    detailMarkdown: md.joined(separator: "\n"),
                    category: .environment,
                    relevanceScore: min(1.35, score)
                )
            )
        }
        return items
    }

    private func rankEnvironmentCloseCompletions(context: AcademicCompletionContext) -> [LSPCompletionItem] {
        let query = context.queryPrefix.lowercased()
        var items: [LSPCompletionItem] = []

        // Prioritize the innermost unclosed environment on the stack!
        for (revIdx, openEnv) in context.unclosedEnvironmentStack.reversed().enumerated() {
            if !query.isEmpty && !openEnv.lowercased().hasPrefix(query) {
                continue
            }
            let score = 1.20 - Double(revIdx) * 0.05
            items.append(
                LSPCompletionItem(
                    id: "envclose:\(openEnv)",
                    insertText: "\(openEnv)}",
                    title: openEnv,
                    subtitle: revIdx == 0 ? "Close innermost open \\begin{\(openEnv)}" : "Close enclosing \\begin{\(openEnv)}",
                    detailMarkdown: "Closes matching `\\begin{\(openEnv)}`.",
                    category: .environment,
                    relevanceScore: max(0.80, score)
                )
            )
        }

        for env in Self.builtinEnvironments {
            let tag = env.realLatexEnvironmentTag
            if !query.isEmpty && !tag.lowercased().hasPrefix(query) {
                continue
            }
            items.append(
                LSPCompletionItem(
                    id: "envclose:\(tag)",
                    insertText: "\(tag)}",
                    title: tag,
                    subtitle: "Close \\end{\(tag)}",
                    detailMarkdown: "Closes `\\end{\(tag)}`.",
                    category: .environment,
                    relevanceScore: 0.70
                )
            )
        }
        return items
    }

    // MARK: - File Include Ranking

    private func rankFileIncludeCompletions(
        context: AcademicCompletionContext,
        workspaceFiles: [String]
    ) -> [LSPCompletionItem] {
        let query = context.queryPrefix.lowercased()
        let cmd = context.activeCommand ?? ""
        let expectsBib = cmd.contains("bib")

        var items: [LSPCompletionItem] = []
        for path in Set(workspaceFiles).sorted() {
            if path == context.filePath { continue }
            let lower = path.lowercased()
            let isBibFile = lower.hasSuffix(".bib") || lower.hasSuffix(".yml") || lower.hasSuffix(".yaml")
            if expectsBib && !isBibFile { continue }
            if !expectsBib && isBibFile { continue }

            if !query.isEmpty && !lower.contains(query) {
                continue
            }
            let score = lower.hasPrefix(query) ? 0.98 : 0.84
            let insertPath: String
            if context.format == .latex && (cmd == "\\input" || cmd == "\\include") && lower.hasSuffix(".tex") {
                insertPath = String(path.dropLast(4))
            } else {
                insertPath = path
            }
            items.append(
                LSPCompletionItem(
                    id: "file:\(path)",
                    insertText: insertPath,
                    title: path,
                    subtitle: expectsBib ? "Bibliography Database" : "Workspace Manuscript File",
                    detailMarkdown: "Include workspace file `\(path)`.",
                    category: .command,
                    relevanceScore: score
                )
            )
        }
        return items
    }

    // MARK: - Commands, Math Symbols & Project User Macros Ranking (200+ Built-ins + Symbol Table)

    private func rankCommandMathAndMacroCompletions(
        context: AcademicCompletionContext,
        symbolTable: ManuscriptSymbolTable
    ) -> [LSPCompletionItem] {
        let rawQuery = context.queryPrefix
        let normalizedQuery: String
        if rawQuery.hasPrefix("\\") || rawQuery.hasPrefix("#") {
            normalizedQuery = String(rawQuery.dropFirst()).lowercased()
        } else {
            normalizedQuery = rawQuery.lowercased()
        }

        var items: [LSPCompletionItem] = []

        // 1. Project-defined user macros (`\newcommand`, `\DeclareMathOperator`, `#let`)
        for (_, macro) in symbolTable.macrosByName {
            let bareMacroName: String
            if macro.name.hasPrefix("\\") || macro.name.hasPrefix("#") {
                bareMacroName = String(macro.name.dropFirst())
            } else {
                bareMacroName = macro.name
            }
            let bareLower = bareMacroName.lowercased()

            var score: Double = 0.0
            if normalizedQuery.isEmpty {
                score = 0.92
            } else if bareLower == normalizedQuery {
                score = 1.08
            } else if bareLower.hasPrefix(normalizedQuery) {
                score = 1.02
            } else if let sub = fuzzySubsequenceScore(query: normalizedQuery, candidate: bareLower) {
                score = 0.68 + 0.28 * sub
            }
            guard score > 0.0 else { continue }

            let insertText: String
            if context.format == .typst {
                let prefixHash = rawQuery.hasPrefix("#") ? "#" : ""
                let argSuffix = macro.parameterCount > 0 ? "()" : ""
                insertText = "\(prefixHash)\(bareMacroName)\(argSuffix)"
            } else {
                var latexCall = macro.name.hasPrefix("\\") ? macro.name : "\\\(macro.name)"
                if macro.defaultOptionalArgument != nil {
                    // Optional first parameter available; mandatory parameters follow
                    for _ in 0..<macro.mandatoryParameterCount {
                        latexCall += "{}"
                    }
                } else if macro.parameterCount > 0 {
                    for _ in 0..<macro.parameterCount {
                        latexCall += "{}"
                    }
                }
                insertText = latexCall
            }

            let docLine = macro.documentationComment.map { "\n\n_\($0)_" } ?? ""
            let subtitle = "User Macro · \(macro.replacementBody) (\(macro.filePath):\(macro.span.start.line))"
            let detail = "**Signature:** `\(macro.signatureDisplay)`\n**Expands to:** `\(macro.replacementBody)`\n**Defined in:** `\(macro.filePath):\(macro.span.start.line)`\(docLine)"

            items.append(
                LSPCompletionItem(
                    id: "macro:\(macro.name)",
                    insertText: insertText,
                    title: macro.signatureDisplay,
                    subtitle: subtitle,
                    detailMarkdown: detail,
                    category: .userMacro,
                    relevanceScore: score
                )
            )
        }

        // 2. Built-in 200+ LaTeX / Typst commands, Greek letters, operators, relations, arrows & delimiters
        for entry in Self.builtinCommandsAndSymbols where entry.format == context.format {
            let bareTrigger: String
            if entry.trigger.hasPrefix("\\") || entry.trigger.hasPrefix("#") {
                bareTrigger = String(entry.trigger.dropFirst())
            } else {
                bareTrigger = entry.trigger
            }
            let trigLower = bareTrigger.lowercased()

            // In Typst, bare math symbols (`alpha`, `arrow.r`) trigger inside `$ ... $` whereas `#` directives trigger on `#`
            if context.format == .typst {
                let isHashDirective = entry.trigger.hasPrefix("#")
                if context.triggerKind == .typstDirective && !isHashDirective {
                    continue
                }
                if context.triggerKind == .mathSymbolOrCommand && isHashDirective && !rawQuery.hasPrefix("#") {
                    continue
                }
            }

            var score: Double = 0.0
            if normalizedQuery.isEmpty {
                score = entry.mathOnly ? (context.isInsideMathMode ? 0.85 : 0.45) : 0.82
            } else if trigLower == normalizedQuery {
                score = 1.00
            } else if trigLower.hasPrefix(normalizedQuery) {
                // Exact case boost so `\Delta` beats `\delta` when user typed `\Del`!
                let rawTrimmed = (rawQuery.hasPrefix("\\") || rawQuery.hasPrefix("#")) ? String(rawQuery.dropFirst()) : rawQuery
                let caseBonus = bareTrigger.hasPrefix(rawTrimmed) ? 0.04 : 0.0
                score = 0.93 + caseBonus
            } else if entry.summary.lowercased().contains(normalizedQuery) {
                score = 0.74
            } else if let sub = fuzzySubsequenceScore(query: normalizedQuery, candidate: trigLower) {
                score = 0.56 + 0.30 * sub
            }
            guard score > 0.0 else { continue }

            if entry.mathOnly {
                if context.isInsideMathMode {
                    score += 0.10
                } else {
                    score -= 0.18
                }
            }

            // Also include `\begin{...}` environment snippet shortcuts when user types `\beg`!
            let unicodeBadge = entry.unicodePreview.map { "(\($0)) " } ?? ""
            let pkgNote = entry.packageHint.map { " · \($0)" } ?? ""
            let subtitle = "\(unicodeBadge)\(entry.summary)\(pkgNote)"

            var detailParts: [String] = ["**Command:** `\(entry.trigger)`"]
            if let uni = entry.unicodePreview {
                detailParts.append("**Symbol:** \(uni)")
            }
            detailParts.append(entry.summary)
            if let pkg = entry.packageHint {
                detailParts.append("**Package:** `\(pkg)`")
            }

            items.append(
                LSPCompletionItem(
                    id: "builtin:\(entry.format.rawValue):\(entry.trigger)",
                    insertText: entry.insertText,
                    title: entry.trigger,
                    subtitle: subtitle,
                    detailMarkdown: detailParts.joined(separator: "\n\n"),
                    category: entry.category,
                    relevanceScore: max(0.05, min(1.30, score))
                )
            )
        }

        // 3. If LaTeX `\begin` matches prefix, surface `\begin{...}` snippet completions too
        if context.format == .latex && "begin".hasPrefix(normalizedQuery) && !normalizedQuery.isEmpty {
            for env in Self.builtinEnvironments.prefix(12) {
                items.append(
                    LSPCompletionItem(
                        id: "begin-env:\(env.name)",
                        insertText: "\\begin{\(env.realLatexEnvironmentTag)}\n\(env.snippetBody)\n\\end{\(env.realLatexEnvironmentTag)}",
                        title: "\\begin{\(env.displayTitle)}",
                        subtitle: "[\(env.groupCategory)] \(env.summary)",
                        detailMarkdown: "Auto-closing `\(env.realLatexEnvironmentTag)` environment snippet.",
                        category: .environment,
                        relevanceScore: 0.86
                    )
                )
            }
        }

        return items
    }

    // MARK: - Internal Context Scanning Helpers

    private struct DocumentCursorState {
        let inMathMode: Bool
        let openEnvironments: [String]
    }

    private func isInsideComment(linePrefix: String, format: ManuscriptFormat) -> Bool {
        let chars = Array(linePrefix)
        switch format {
        case .latex:
            var i = 0
            while i < chars.count {
                if chars[i] == "\\" {
                    i += 2
                    continue
                }
                if chars[i] == "%" {
                    return true
                }
                i += 1
            }
            return false
        case .typst:
            var inQuotes = false
            var i = 0
            while i < chars.count {
                if chars[i] == "\\" {
                    i += 2
                    continue
                }
                if chars[i] == "\"" {
                    inQuotes.toggle()
                } else if !inQuotes && chars[i] == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                    return true
                }
                i += 1
            }
            return false
        case .markdown:
            return false
        }
    }

    private func scanDocumentStateUpToCursor(
        bytes: [UInt8],
        cursorByte: Int,
        format: ManuscriptFormat
    ) -> DocumentCursorState {
        var inlineDollarOpen = false
        var displayDollarOpen = false
        var bracketDisplayMathOpen = false
        var parenInlineMathOpen = false
        var envStack: [String] = []

        var i = 0
        while i < cursorByte {
            let b = bytes[i]
            // Skip line comments!
            if format == .latex && b == 0x25 { // '%'
                while i < cursorByte && bytes[i] != 0x0A { i += 1 }
                continue
            }
            if format == .typst && b == 0x2F && i + 1 < cursorByte && bytes[i + 1] == 0x2F { // '//'
                while i < cursorByte && bytes[i] != 0x0A { i += 1 }
                continue
            }
            if b == 0x5C { // '\'
                if i + 1 < cursorByte {
                    let next = bytes[i + 1]
                    if format == .latex && next == 0x5B { // '\['
                        bracketDisplayMathOpen = true
                        i += 2
                        continue
                    } else if format == .latex && next == 0x5D { // '\]'
                        bracketDisplayMathOpen = false
                        i += 2
                        continue
                    } else if format == .latex && next == 0x28 { // '\('
                        parenInlineMathOpen = true
                        i += 2
                        continue
                    } else if format == .latex && next == 0x29 { // '\)'
                        parenInlineMathOpen = false
                        i += 2
                        continue
                    } else if format == .latex, let (directive, envName, nextIdx) = matchBeginOrEndAt(bytes: bytes, offset: i, limit: cursorByte) {
                        if directive == "begin" {
                            envStack.append(envName)
                        } else if directive == "end" {
                            if let lastIdx = envStack.lastIndex(of: envName) {
                                envStack.remove(at: lastIdx)
                            }
                        }
                        i = nextIdx
                        continue
                    } else if !next.isASCIILetterByte {
                        // Escaped punctuation like `\$` or `\%`
                        i += 2
                        continue
                    }
                }
                i += 1
                continue
            }

            if b == 0x24 { // '$'
                if format == .latex && i + 1 < cursorByte && bytes[i + 1] == 0x24 {
                    displayDollarOpen.toggle()
                    i += 2
                    continue
                } else {
                    inlineDollarOpen.toggle()
                    i += 1
                    continue
                }
            }
            i += 1
        }

        let mathEnvNames: Set<String> = [
            "equation", "equation*", "align", "align*", "aligned",
            "gather", "gather*", "multline", "multline*", "split",
            "math", "displaymath", "cases", "dcases",
            "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix"
        ]
        let inMathEnv = envStack.contains { mathEnvNames.contains($0) }
        let inMath = inlineDollarOpen || displayDollarOpen || bracketDisplayMathOpen || parenInlineMathOpen || inMathEnv
        return DocumentCursorState(inMathMode: inMath, openEnvironments: envStack)
    }

    private func matchBeginOrEndAt(bytes: [UInt8], offset: Int, limit: Int) -> (String, String, Int)? {
        // Expect `\begin{...}` or `\end{...}` completely closed BEFORE `limit`
        let beginBytes = Array("\\begin{".utf8)
        let endBytes = Array("\\end{".utf8)
        let directive: String
        var pos: Int
        if offset + beginBytes.count < limit && Array(bytes[offset..<(offset + beginBytes.count)]) == beginBytes {
            directive = "begin"
            pos = offset + beginBytes.count
        } else if offset + endBytes.count < limit && Array(bytes[offset..<(offset + endBytes.count)]) == endBytes {
            directive = "end"
            pos = offset + endBytes.count
        } else {
            return nil
        }
        let nameStart = pos
        while pos < limit && bytes[pos] != 0x7D && bytes[pos] != 0x0A && bytes[pos] != 0x7B {
            pos += 1
        }
        guard pos < limit && bytes[pos] == 0x7D else { return nil } // '}'
        let envName = String(decoding: bytes[nameStart..<pos], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard !envName.isEmpty else { return nil }
        return (directive, envName, pos + 1)
    }

    private static let latexCiteCommands: Set<String> = [
        "\\cite", "\\cite*", "\\citep", "\\citep*", "\\citet", "\\citet*",
        "\\citealp", "\\citealt", "\\citeauthor", "\\citeyear", "\\citeyearpar",
        "\\parencite", "\\parencite*", "\\textcite", "\\autocite", "\\autocite*",
        "\\footcite", "\\supercite", "\\smartcite", "\\nocite", "\\fullcite", "\\cites"
    ]

    private static let latexRefCommands: Set<String> = [
        "\\ref", "\\eqref", "\\pageref", "\\autoref", "\\cref", "\\Cref",
        "\\cpageref", "\\Cpageref", "\\namecref", "\\nameCref", "\\vref", "\\Vref",
        "\\fref", "\\Fref", "\\labelcref"
    ]

    private static let latexIncludeCommands: Set<String> = [
        "\\input", "\\include", "\\subfile", "\\import", "\\subimport",
        "\\bibliography", "\\nobibliography", "\\addbibresource", "\\addglobalbib"
    ]

    private func detectLatexBracedOrBracketedContext(
        windowText: String,
        windowStartByte: Int,
        cursor: TextPosition,
        filePath: String,
        source: String,
        lineIndex: LineByteIndex,
        scanState: DocumentCursorState
    ) -> AcademicCompletionContext? {
        // Walk backwards in `windowText` to find the nearest unmatched `{` or `[` before the cursor.
        let scalars = Array(windowText)
        var braceDepth = 0
        var bracketDepth = 0
        var openDelimiterChar: Character? = nil
        var openDelimiterIndex: Int? = nil

        var idx = scalars.count - 1
        while idx >= 0 {
            let ch = scalars[idx]
            let isEscaped = (idx > 0 && scalars[idx - 1] == "\\")
            if !isEscaped {
                if ch == "}" {
                    braceDepth += 1
                } else if ch == "{" {
                    if braceDepth > 0 {
                        braceDepth -= 1
                    } else {
                        openDelimiterChar = "{"
                        openDelimiterIndex = idx
                        break
                    }
                } else if ch == "]" {
                    bracketDepth += 1
                } else if ch == "[" {
                    if bracketDepth > 0 {
                        bracketDepth -= 1
                    } else if braceDepth == 0 {
                        openDelimiterChar = "["
                        openDelimiterIndex = idx
                        break
                    }
                }
            }
            idx -= 1
        }

        guard let delim = openDelimiterChar, let delimIdx = openDelimiterIndex else {
            return nil
        }

        let insideContent = String(scalars[(delimIdx + 1)...])
        // Do not span across blank paragraph breaks inside `{...}`
        if insideContent.contains("\n\n") {
            return nil
        }

        // Scan backwards before `delimIdx` skipping whitespace and closed `[...]` optional arguments (e.g. `\citet[see][p.~4]{...`)
        var cmdEndIdx = delimIdx - 1
        if delim == "{" {
            while cmdEndIdx >= 0 {
                while cmdEndIdx >= 0 && scalars[cmdEndIdx].isWhitespace {
                    cmdEndIdx -= 1
                }
                if cmdEndIdx >= 0 && scalars[cmdEndIdx] == "]" {
                    var bDepth = 1
                    cmdEndIdx -= 1
                    while cmdEndIdx >= 0 && bDepth > 0 {
                        if scalars[cmdEndIdx] == "]" { bDepth += 1 }
                        else if scalars[cmdEndIdx] == "[" { bDepth -= 1 }
                        cmdEndIdx -= 1
                    }
                } else {
                    break
                }
            }
        } else {
            while cmdEndIdx >= 0 && scalars[cmdEndIdx].isWhitespace {
                cmdEndIdx -= 1
            }
        }

        guard cmdEndIdx >= 0 else { return nil }

        // Extract `\command*` ending at `cmdEndIdx`
        var cmdStartIdx = cmdEndIdx
        if scalars[cmdStartIdx] == "*" && cmdStartIdx > 0 {
            cmdStartIdx -= 1
        }
        while cmdStartIdx >= 0 && scalars[cmdStartIdx].isLetter {
            cmdStartIdx -= 1
        }
        guard cmdStartIdx >= 0 && scalars[cmdStartIdx] == "\\" else {
            return nil
        }
        let command = String(scalars[cmdStartIdx...cmdEndIdx])

        // Case A: `\hyperref[prefix`
        if delim == "[" && command == "\\hyperref" {
            let trimmedPrefix = insideContent.trimmingCharacters(in: .whitespaces)
            let prefixStartByte = cursor.utf8Offset - trimmedPrefix.utf8.count
            let startPos = lineIndex.position(forUTF8Offset: max(0, prefixStartByte), in: source)
            return AcademicCompletionContext(
                filePath: filePath,
                format: .latex,
                cursorPosition: cursor,
                triggerKind: .crossReference,
                activeCommand: command,
                queryPrefix: trimmedPrefix,
                replacementSpan: TextSpan(filePath: filePath, start: startPos, end: cursor),
                isInsideMathMode: scanState.inMathMode,
                expectedLabelCategory: inferExpectedLabelCategory(command: command, queryPrefix: trimmedPrefix),
                unclosedEnvironmentStack: scanState.openEnvironments
            )
        }

        guard delim == "{" else { return nil }

        // Compute multi-item comma split inside `{item1, item2, currentPrefix`
        let parts = insideContent.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let priorKeys = parts.dropLast().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let rawLastSegment = parts.last ?? ""
        let leadingSpacesCount = rawLastSegment.prefix(while: { $0.isWhitespace }).utf8.count
        let cleanPrefix = String(rawLastSegment.drop(while: { $0.isWhitespace }))

        let contentStartUTF8 = windowStartByte + String(scalars[0...delimIdx]).utf8.count
        let lastSegmentStartUTF8: Int
        if parts.count <= 1 {
            lastSegmentStartUTF8 = contentStartUTF8 + leadingSpacesCount
        } else {
            let beforeLastCommaCount = insideContent.utf8.count - rawLastSegment.utf8.count
            lastSegmentStartUTF8 = contentStartUTF8 + beforeLastCommaCount + leadingSpacesCount
        }
        let repStartPos = lineIndex.position(forUTF8Offset: max(0, min(cursor.utf8Offset, lastSegmentStartUTF8)), in: source)
        let repSpan = TextSpan(filePath: filePath, start: repStartPos, end: cursor)

        if Self.latexCiteCommands.contains(command) {
            return AcademicCompletionContext(
                filePath: filePath,
                format: .latex,
                cursorPosition: cursor,
                triggerKind: .citation,
                activeCommand: command,
                queryPrefix: cleanPrefix,
                replacementSpan: repSpan,
                isInsideMathMode: scanState.inMathMode,
                alreadyCitedKeysInCluster: priorKeys,
                unclosedEnvironmentStack: scanState.openEnvironments
            )
        }

        if Self.latexRefCommands.contains(command) {
            return AcademicCompletionContext(
                filePath: filePath,
                format: .latex,
                cursorPosition: cursor,
                triggerKind: .crossReference,
                activeCommand: command,
                queryPrefix: cleanPrefix,
                replacementSpan: repSpan,
                isInsideMathMode: scanState.inMathMode,
                alreadyCitedKeysInCluster: priorKeys,
                expectedLabelCategory: inferExpectedLabelCategory(command: command, queryPrefix: cleanPrefix),
                unclosedEnvironmentStack: scanState.openEnvironments
            )
        }

        if command == "\\begin" {
            return AcademicCompletionContext(
                filePath: filePath,
                format: .latex,
                cursorPosition: cursor,
                triggerKind: .environment,
                activeCommand: command,
                queryPrefix: cleanPrefix,
                replacementSpan: repSpan,
                isInsideMathMode: scanState.inMathMode,
                unclosedEnvironmentStack: scanState.openEnvironments
            )
        }

        if command == "\\end" {
            return AcademicCompletionContext(
                filePath: filePath,
                format: .latex,
                cursorPosition: cursor,
                triggerKind: .environmentClose,
                activeCommand: command,
                queryPrefix: cleanPrefix,
                replacementSpan: repSpan,
                isInsideMathMode: scanState.inMathMode,
                unclosedEnvironmentStack: scanState.openEnvironments
            )
        }

        if Self.latexIncludeCommands.contains(command) {
            return AcademicCompletionContext(
                filePath: filePath,
                format: .latex,
                cursorPosition: cursor,
                triggerKind: .fileInclude,
                activeCommand: command,
                queryPrefix: cleanPrefix,
                replacementSpan: repSpan,
                isInsideMathMode: scanState.inMathMode,
                unclosedEnvironmentStack: scanState.openEnvironments
            )
        }

        return nil
    }

    private func detectLatexSlashCommandContext(
        linePrefix: String,
        lineStartByte: Int,
        cursor: TextPosition,
        filePath: String,
        source: String,
        lineIndex: LineByteIndex,
        scanState: DocumentCursorState
    ) -> AcademicCompletionContext? {
        let chars = Array(linePrefix)
        guard !chars.isEmpty else { return nil }
        var i = chars.count - 1
        if chars[i] == "*" && i > 0 {
            i -= 1
        }
        while i >= 0 && chars[i].isLetter {
            i -= 1
        }
        guard i >= 0 && chars[i] == "\\" else { return nil }
        // Make sure it's not an escaped backslash `\\`
        if i > 0 && chars[i - 1] == "\\" {
            return nil
        }

        let cmdPrefix = String(chars[i...])
        let prefixByteOffset = lineStartByte + String(chars[..<i]).utf8.count
        let startPos = lineIndex.position(forUTF8Offset: prefixByteOffset, in: source)

        return AcademicCompletionContext(
            filePath: filePath,
            format: .latex,
            cursorPosition: cursor,
            triggerKind: scanState.inMathMode ? .mathSymbolOrCommand : .commandOrMacro,
            activeCommand: cmdPrefix,
            queryPrefix: cmdPrefix,
            replacementSpan: TextSpan(filePath: filePath, start: startPos, end: cursor),
            isInsideMathMode: scanState.inMathMode,
            unclosedEnvironmentStack: scanState.openEnvironments
        )
    }

    private func detectTypstContext(
        windowText: String,
        windowStartByte: Int,
        linePrefix: String,
        lineStartByte: Int,
        cursor: TextPosition,
        filePath: String,
        source: String,
        lineIndex: LineByteIndex,
        scanState: DocumentCursorState
    ) -> AcademicCompletionContext? {
        // 1. Typst `#cite(<prefix` or `#cite(label("prefix`
        if let citeMatch = matchTrailingTypstCallPrefix(in: windowText, functionName: "#cite") {
            let startOffset = cursor.utf8Offset - citeMatch.utf8.count
            let startPos = lineIndex.position(forUTF8Offset: max(0, startOffset), in: source)
            return AcademicCompletionContext(
                filePath: filePath,
                format: .typst,
                cursorPosition: cursor,
                triggerKind: .citation,
                activeCommand: "#cite",
                queryPrefix: citeMatch,
                replacementSpan: TextSpan(filePath: filePath, start: startPos, end: cursor),
                isInsideMathMode: scanState.inMathMode
            )
        }

        // 2. Typst `#ref(<prefix`
        if let refMatch = matchTrailingTypstCallPrefix(in: windowText, functionName: "#ref") {
            let startOffset = cursor.utf8Offset - refMatch.utf8.count
            let startPos = lineIndex.position(forUTF8Offset: max(0, startOffset), in: source)
            return AcademicCompletionContext(
                filePath: filePath,
                format: .typst,
                cursorPosition: cursor,
                triggerKind: .crossReference,
                activeCommand: "#ref",
                queryPrefix: refMatch,
                replacementSpan: TextSpan(filePath: filePath, start: startPos, end: cursor),
                isInsideMathMode: scanState.inMathMode,
                expectedLabelCategory: inferExpectedLabelCategory(command: "#ref", queryPrefix: refMatch)
            )
        }

        // 3. Typst `#include "prefix`, `#import "prefix`, `#bibliography("prefix`
        if let (incCmd, incPrefix) = matchTrailingTypstInclude(in: linePrefix) {
            let startOffset = cursor.utf8Offset - incPrefix.utf8.count
            let startPos = lineIndex.position(forUTF8Offset: max(0, startOffset), in: source)
            return AcademicCompletionContext(
                filePath: filePath,
                format: .typst,
                cursorPosition: cursor,
                triggerKind: .fileInclude,
                activeCommand: incCmd,
                queryPrefix: incPrefix,
                replacementSpan: TextSpan(filePath: filePath, start: startPos, end: cursor),
                isInsideMathMode: scanState.inMathMode
            )
        }

        // 4. Typst `@key` / `@fig:arch` shorthand
        let chars = Array(linePrefix)
        if !chars.isEmpty {
            var idx = chars.count - 1
            while idx >= 0 && isCiteOrLabelChar(chars[idx]) {
                idx -= 1
            }
            if idx >= 0 && chars[idx] == "@" {
                let precededByAlpha = (idx > 0) && (chars[idx - 1].isLetter || chars[idx - 1].isNumber)
                if !precededByAlpha {
                    let keyPrefix = String(chars[(idx + 1)...])
                    let replaceStartUTF8 = lineStartByte + String(chars[0...idx]).utf8.count
                    let startPos = lineIndex.position(forUTF8Offset: replaceStartUTF8, in: source)
                    let inferredCat = inferExpectedLabelCategory(command: "@", queryPrefix: keyPrefix)
                    let isExplicitLabelNamespace = (inferredCat != nil)
                    return AcademicCompletionContext(
                        filePath: filePath,
                        format: .typst,
                        cursorPosition: cursor,
                        triggerKind: isExplicitLabelNamespace ? .crossReference : .citation,
                        activeCommand: "@",
                        queryPrefix: keyPrefix,
                        replacementSpan: TextSpan(filePath: filePath, start: startPos, end: cursor),
                        isInsideMathMode: scanState.inMathMode,
                        expectedLabelCategory: inferredCat
                    )
                }
            }

            // 5. Typst `#directive`
            var hashIdx = chars.count - 1
            while hashIdx >= 0 && (chars[hashIdx].isLetter || chars[hashIdx].isNumber || chars[hashIdx] == "-" || chars[hashIdx] == "_") {
                hashIdx -= 1
            }
            if hashIdx >= 0 && chars[hashIdx] == "#" {
                let hashToken = String(chars[hashIdx...])
                let startUTF8 = lineStartByte + String(chars[..<hashIdx]).utf8.count
                let startPos = lineIndex.position(forUTF8Offset: startUTF8, in: source)
                return AcademicCompletionContext(
                    filePath: filePath,
                    format: .typst,
                    cursorPosition: cursor,
                    triggerKind: .typstDirective,
                    activeCommand: hashToken,
                    queryPrefix: hashToken,
                    replacementSpan: TextSpan(filePath: filePath, start: startPos, end: cursor),
                    isInsideMathMode: scanState.inMathMode
                )
            }

            // 6. Typst math mode symbol identifier (`$ alpha`, `$ arrow.r`)
            if scanState.inMathMode {
                var mIdx = chars.count - 1
                while mIdx >= 0 && (chars[mIdx].isLetter || chars[mIdx] == ".") {
                    mIdx -= 1
                }
                let symToken = String(chars[(mIdx + 1)...])
                if !symToken.isEmpty {
                    let startUTF8 = cursor.utf8Offset - symToken.utf8.count
                    let startPos = lineIndex.position(forUTF8Offset: max(0, startUTF8), in: source)
                    return AcademicCompletionContext(
                        filePath: filePath,
                        format: .typst,
                        cursorPosition: cursor,
                        triggerKind: .mathSymbolOrCommand,
                        activeCommand: symToken,
                        queryPrefix: symToken,
                        replacementSpan: TextSpan(filePath: filePath, start: startPos, end: cursor),
                        isInsideMathMode: true
                    )
                }
            }
        }

        return nil
    }

    private func detectMarkdownCitationContext(
        linePrefix: String,
        lineStartByte: Int,
        cursor: TextPosition,
        filePath: String,
        source: String,
        lineIndex: LineByteIndex,
        scanState: DocumentCursorState
    ) -> AcademicCompletionContext? {
        // Pandoc / Academic Markdown `[@key1; @prefix` or `@prefix`
        let chars = Array(linePrefix)
        guard !chars.isEmpty else { return nil }
        var idx = chars.count - 1
        while idx >= 0 && isCiteOrLabelChar(chars[idx]) {
            idx -= 1
        }
        guard idx >= 0 && chars[idx] == "@" else { return nil }
        let precededByAlpha = (idx > 0) && (chars[idx - 1].isLetter || chars[idx - 1].isNumber)
        guard !precededByAlpha else { return nil }

        let keyPrefix = String(chars[(idx + 1)...])
        let replaceStartUTF8 = lineStartByte + String(chars[0...idx]).utf8.count
        let startPos = lineIndex.position(forUTF8Offset: replaceStartUTF8, in: source)
        return AcademicCompletionContext(
            filePath: filePath,
            format: .markdown,
            cursorPosition: cursor,
            triggerKind: .citation,
            activeCommand: "@",
            queryPrefix: keyPrefix,
            replacementSpan: TextSpan(filePath: filePath, start: startPos, end: cursor),
            isInsideMathMode: scanState.inMathMode
        )
    }

    private func matchTrailingTypstCallPrefix(in windowText: String, functionName: String) -> String? {
        guard let fnRange = windowText.range(of: functionName, options: .backwards) else {
            return nil
        }
        let tail = String(windowText[fnRange.upperBound...])
        // Must start with `(` and not have closed `)` yet
        let trimmed = tail.drop(while: { $0.isWhitespace })
        guard trimmed.first == "(" else { return nil }
        let insideParens = String(trimmed.dropFirst())
        if insideParens.contains(")") { return nil }

        if let angleIdx = insideParens.lastIndex(of: "<") {
            let afterAngle = String(insideParens[insideParens.index(after: angleIdx)...])
            if !afterAngle.contains(">") {
                return afterAngle.trimmingCharacters(in: .whitespaces)
            }
        }
        if let labelRange = insideParens.range(of: "label(\"", options: .backwards) {
            let afterQuote = String(insideParens[labelRange.upperBound...])
            if !afterQuote.contains("\"") {
                return afterQuote
            }
        }
        return nil
    }

    private func matchTrailingTypstInclude(in linePrefix: String) -> (String, String)? {
        for directive in ["#include", "#import", "#bibliography"] {
            guard let r = linePrefix.range(of: directive, options: .backwards) else { continue }
            let after = String(linePrefix[r.upperBound...])
            guard let firstQuote = after.firstIndex(of: "\"") else { continue }
            let afterQuote = String(after[after.index(after: firstQuote)...])
            if !afterQuote.contains("\"") {
                return (directive, afterQuote)
            }
        }
        return nil
    }

    private func inferExpectedLabelCategory(command: String, queryPrefix: String) -> LabelCategory? {
        if command == "\\eqref" {
            return .equation
        }
        let lower = queryPrefix.lowercased()
        if lower.hasPrefix("fig:") || lower.hasPrefix("subfig:") { return .figure }
        if lower.hasPrefix("tab:") || lower.hasPrefix("tbl:") { return .table }
        if lower.hasPrefix("sec:") || lower.hasPrefix("subsec:") || lower.hasPrefix("chap:") || lower.hasPrefix("ch:") { return .section }
        if lower.hasPrefix("app:") || lower.hasPrefix("appendix:") { return .appendix }
        if lower.hasPrefix("eq:") || lower.hasPrefix("eqn:") { return .equation }
        if lower.hasPrefix("thm:") || lower.hasPrefix("lem:") || lower.hasPrefix("prop:") || lower.hasPrefix("cor:") || lower.hasPrefix("def:") { return .theorem }
        if lower.hasPrefix("alg:") || lower.hasPrefix("algo:") { return .algorithm }
        if lower.hasPrefix("lst:") || lower.hasPrefix("code:") { return .listing }
        return nil
    }

    private func doesCurrentLineAlreadyCloseBrace(source: String, afterUTF8Offset: Int) -> Bool {
        let bytes = Array(source.utf8)
        var i = max(0, min(bytes.count, afterUTF8Offset))
        while i < bytes.count && bytes[i] != 0x0A && bytes[i] != 0x0D {
            if bytes[i] == 0x7D { return true } // '}'
            if bytes[i] == 0x7B || bytes[i] == 0x25 { return false } // '{' or '%'
            i += 1
        }
        return false
    }

    private func isCiteOrLabelChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == ":" || ch == "_" || ch == "-" || ch == "."
    }

    private func fuzzySubsequenceScore(query: String, candidate: String) -> Double? {
        guard !query.isEmpty, !candidate.isEmpty else { return nil }
        let qChars = Array(query)
        let cChars = Array(candidate)
        guard qChars.count <= cChars.count else { return nil }

        var qIdx = 0
        var consecutiveRuns = 0
        var boundaryBonus = 0
        var firstMatchPos: Int? = nil
        var prevMatched = false

        for (cIdx, ch) in cChars.enumerated() {
            if qIdx < qChars.count && ch == qChars[qIdx] {
                if firstMatchPos == nil { firstMatchPos = cIdx }
                if prevMatched { consecutiveRuns += 1 }
                if cIdx == 0 || cChars[cIdx - 1] == ":" || cChars[cIdx - 1] == "_" || cChars[cIdx - 1] == "-" || cChars[cIdx - 1].isNumber != ch.isNumber {
                    boundaryBonus += 1
                }
                qIdx += 1
                prevMatched = true
            } else {
                prevMatched = false
            }
        }

        guard qIdx == qChars.count else { return nil }
        let density = Double(qChars.count) / Double(max(1, cChars.count))
        let runRatio = Double(consecutiveRuns) / Double(max(1, qChars.count - 1))
        let boundRatio = Double(boundaryBonus) / Double(max(1, qChars.count))
        let startPenalty = Double(firstMatchPos ?? 0) * 0.02
        return max(0.10, min(1.0, 0.45 * density + 0.35 * runRatio + 0.25 * boundRatio - startPenalty))
    }

    private func formatShortAuthorHeader(_ authors: [BibAuthor]) -> String {
        guard let first = authors.first else { return "Unknown" }
        switch authors.count {
        case 1:
            return first.familyName
        case 2:
            return "\(first.familyName) & \(authors[1].familyName)"
        default:
            return "\(first.familyName) et al."
        }
    }

    private func truncateText(_ text: String, maxChars: Int) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > maxChars else { return clean }
        return String(clean.prefix(maxChars - 1)) + "…"
    }
}

private extension UInt8 {
    var isASCIILetterByte: Bool {
        (self >= 0x41 && self <= 0x5A) || (self >= 0x61 && self <= 0x7A)
    }
}

// MARK: - 48+ Built-in Scholarly LaTeX Environments Catalog

extension AcademicCompletionEngine {
    public static let builtinEnvironments: [LatexEnvironmentTemplate] = [
        // Figures & Visual Floats
        LatexEnvironmentTemplate(
            name: "figure",
            groupCategory: "Floats & Figures",
            summary: "Single-column figure float with centered graphics, caption, and label",
            packageRequirement: "graphicx",
            snippetBody: "    \\centering\n    \\includegraphics[width=0.9\\linewidth]{figures/diagram.pdf}\n    \\caption{Overview of the proposed architecture.}\n    \\label{fig:architecture}",
            autoLabelPrefix: "fig:",
            isFloatEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "figure*",
            groupCategory: "Floats & Figures",
            summary: "Two-column spanning wide figure float with caption and label",
            packageRequirement: "graphicx",
            snippetBody: "    \\centering\n    \\includegraphics[width=\\textwidth]{figures/pipeline.pdf}\n    \\caption{End-to-end experimental pipeline across benchmarks.}\n    \\label{fig:pipeline}",
            autoLabelPrefix: "fig:",
            isFloatEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "subfigure",
            groupCategory: "Floats & Figures",
            summary: "Sub-panel inside a figure environment (subcaption)",
            packageRequirement: "subcaption",
            snippetBody: "    \\centering\n    \\includegraphics[width=\\linewidth]{figures/panel_a.pdf}\n    \\caption{Panel description.}\n    \\label{fig:sub_a}",
            autoLabelPrefix: "fig:",
            isFloatEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "wrapfigure",
            groupCategory: "Floats & Figures",
            summary: "Inline text-wrapped figure float",
            packageRequirement: "wrapfig",
            snippetBody: "    \\centering\n    \\includegraphics[width=0.42\\textwidth]{figures/inset.pdf}\n    \\caption{Inset comparison.}\n    \\label{fig:inset}",
            autoLabelPrefix: "fig:",
            isFloatEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "sidewaysfigure",
            groupCategory: "Floats & Figures",
            summary: "Landscape-rotated full-page figure float",
            packageRequirement: "rotating",
            snippetBody: "    \\centering\n    \\includegraphics[width=0.9\\textheight]{figures/landscape.pdf}\n    \\caption{Full landscape diagram.}\n    \\label{fig:landscape}",
            autoLabelPrefix: "fig:",
            isFloatEnvironment: true
        ),

        // Tables & Booktabs
        LatexEnvironmentTemplate(
            name: "booktabs",
            displayTitle: "booktabs (Publication Table)",
            groupCategory: "Tables",
            summary: "Publication-grade Booktabs table with toprule, midrule, bottomrule, caption, and label",
            packageRequirement: "booktabs",
            snippetBody: "    \\centering\n    \\caption{Quantitative comparison across benchmark datasets.}\n    \\label{tab:results}\n    \\begin{tabular}{lccc}\n        \\toprule\n        Method & Accuracy (\\%) & F1 Score & Latency (ms) \\\\\n        \\midrule\n        Baseline & 84.2 & 0.831 & 14.2 \\\\\n        Ours     & \\textbf{91.7} & \\textbf{0.908} & \\textbf{9.4} \\\\\n        \\bottomrule\n    \\end{tabular}",
            autoLabelPrefix: "tab:",
            isFloatEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "table",
            groupCategory: "Tables",
            summary: "Single-column table float with Booktabs tabular, caption, and label",
            packageRequirement: "booktabs",
            snippetBody: "    \\centering\n    \\caption{Summary of experimental results.}\n    \\label{tab:summary}\n    \\begin{tabular}{lcc}\n        \\toprule\n        Model & Metric A & Metric B \\\\\n        \\midrule\n        Method 1 & 0.00 & 0.00 \\\\\n        \\bottomrule\n    \\end{tabular}",
            autoLabelPrefix: "tab:",
            isFloatEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "table*",
            groupCategory: "Tables",
            summary: "Two-column spanning wide table float with Booktabs layout",
            packageRequirement: "booktabs",
            snippetBody: "    \\centering\n    \\caption{Ablation study across all evaluation splits.}\n    \\label{tab:ablation}\n    \\begin{tabular}{lcccc}\n        \\toprule\n        Variant & Split A & Split B & Split C & Mean \\\\\n        \\midrule\n        Full Model & 92.4 & 89.1 & 90.8 & 90.8 \\\\\n        \\bottomrule\n    \\end{tabular}",
            autoLabelPrefix: "tab:",
            isFloatEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "tabular",
            groupCategory: "Tables",
            summary: "Standard column-aligned tabular grid with Booktabs rules",
            packageRequirement: "booktabs",
            snippetBody: "    \\toprule\n    Column 1 & Column 2 & Column 3 \\\\\n    \\midrule\n    Value 1  & Value 2  & Value 3  \\\\\n    \\bottomrule"
        ),
        LatexEnvironmentTemplate(
            name: "tabular*",
            groupCategory: "Tables",
            summary: "Fixed-width tabular grid with stretchable inter-column fill",
            packageRequirement: "booktabs",
            snippetBody: "    \\toprule\n    Item & Value \\\\\n    \\midrule\n    Alpha & 1.00 \\\\\n    \\bottomrule"
        ),
        LatexEnvironmentTemplate(
            name: "tabularx",
            groupCategory: "Tables",
            summary: "Auto-wrapping paragraph-column table environment",
            packageRequirement: "tabularx",
            snippetBody: "    \\toprule\n    Component & Description \\\\\n    \\midrule\n    Module A & Detailed description text. \\\\\n    \\bottomrule"
        ),
        LatexEnvironmentTemplate(
            name: "longtable",
            groupCategory: "Tables",
            summary: "Multi-page spanning table with repeating headers",
            packageRequirement: "longtable",
            snippetBody: "    \\caption{Extended dataset summary.} \\label{tab:long} \\\\\n    \\toprule\n    Item & Details \\\\\n    \\midrule\n    \\endfirsthead\n    \\bottomrule",
            autoLabelPrefix: "tab:",
            isFloatEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "threeparttable",
            groupCategory: "Tables",
            summary: "Table container supporting structured table notes (tablenotes)",
            packageRequirement: "threeparttable",
            snippetBody: "    \\caption{Results with statistical significance footnotes.}\n    \\label{tab:notes}\n    \\begin{tabular}{lcc}\n        \\toprule\n        Cohort & N & Effect \\\\\n        \\midrule\n        Control & 120 & 1.00 \\\\\n        \\bottomrule\n    \\end{tabular}\n    \\begin{tablenotes}[flushleft]\n        \\small \\item[*] $p < 0.01$ under paired Wilcoxon test.\n    \\end{tablenotes}",
            autoLabelPrefix: "tab:"
        ),
        LatexEnvironmentTemplate(
            name: "sidewaystable",
            groupCategory: "Tables",
            summary: "Landscape-rotated full-page table float",
            packageRequirement: "rotating",
            snippetBody: "    \\centering\n    \\caption{Landscape parameter matrix.}\n    \\label{tab:landscape}\n    \\begin{tabular}{lccc}\n        \\toprule\n        Factor & Low & Medium & High \\\\\n        \\midrule\n        Setting & 0.1 & 0.5 & 1.0 \\\\\n        \\bottomrule\n    \\end{tabular}",
            autoLabelPrefix: "tab:",
            isFloatEnvironment: true
        ),

        // Display Equations & Matrices
        LatexEnvironmentTemplate(
            name: "equation",
            groupCategory: "Equations & Math",
            summary: "Numbered single-line display equation with label",
            packageRequirement: "amsmath",
            snippetBody: "    \\mathcal{L}(\\theta) = \\mathbb{E}_{x \\sim \\mathcal{D}}\\left[ -\\log p_\\theta(x) \\right]\n    \\label{eq:objective}",
            autoLabelPrefix: "eq:",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "equation*",
            groupCategory: "Equations & Math",
            summary: "Unnumbered single-line display equation",
            packageRequirement: "amsmath",
            snippetBody: "    f(x) = \\sum_{i=1}^{n} w_i \\phi_i(x)",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "align",
            groupCategory: "Equations & Math",
            summary: "Numbered multi-line aligned equations",
            packageRequirement: "amsmath",
            snippetBody: "    z_t &= W_z x_t + U_z h_{t-1} + b_z, \\label{eq:align_a} \\\\\n    h_t &= (1 - z_t) \\odot h_{t-1} + z_t \\odot \\tilde{h}_t. \\label{eq:align_b}",
            autoLabelPrefix: "eq:",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "align*",
            groupCategory: "Equations & Math",
            summary: "Unnumbered multi-line aligned equations",
            packageRequirement: "amsmath",
            snippetBody: "    \\nabla_\\theta J(\\theta) &= \\mathbb{E}\\left[ \\nabla_\\theta \\log \\pi_\\theta(a \\mid s) Q^\\pi(s, a) \\right] \\\\\n    &= \\frac{1}{N} \\sum_{i=1}^{N} g_i.",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "aligned",
            groupCategory: "Equations & Math",
            summary: "Inner aligned math block for sharing a single equation number",
            packageRequirement: "amsmath",
            snippetBody: "    a &= b + c \\\\\n    d &= e + f",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "gather",
            groupCategory: "Equations & Math",
            summary: "Centered multi-line numbered equations without alignment points",
            packageRequirement: "amsmath",
            snippetBody: "    x_1 + x_2 = 1 \\label{eq:gather_1} \\\\\n    x_1^2 + x_2^2 = \\tau \\label{eq:gather_2}",
            autoLabelPrefix: "eq:",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "gather*",
            groupCategory: "Equations & Math",
            summary: "Centered multi-line unnumbered equations",
            packageRequirement: "amsmath",
            snippetBody: "    \\alpha + \\beta = \\gamma \\\\\n    \\alpha \\beta = \\delta",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "multline",
            groupCategory: "Equations & Math",
            summary: "Long multi-line numbered equation (left-aligned start, right-aligned end)",
            packageRequirement: "amsmath",
            snippetBody: "    p(y \\mid x) = \\int_{\\Omega} p(y \\mid z, x) \\\\\n    \\times p(z \\mid x)\\,\\mathrm{d}z \\label{eq:multline}",
            autoLabelPrefix: "eq:",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "multline*",
            groupCategory: "Equations & Math",
            summary: "Long multi-line unnumbered equation",
            packageRequirement: "amsmath",
            snippetBody: "    A(x) = f_1(x) + f_2(x) \\\\\n    + f_3(x) + f_4(x)",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "split",
            groupCategory: "Equations & Math",
            summary: "Split single-numbered equation across lines inside equation",
            packageRequirement: "amsmath",
            snippetBody: "    H(p, q) &= -\\sum_{x} p(x) \\log q(x) \\\\\n    &= H(p) + D_{\\mathrm{KL}}(p \\parallel q)",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "cases",
            groupCategory: "Equations & Math",
            summary: "Piecewise function definition with left curly brace",
            packageRequirement: "amsmath",
            snippetBody: "    1, & \\text{if } x \\geq 0, \\\\\n    0, & \\text{otherwise.}",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "dcases",
            groupCategory: "Equations & Math",
            summary: "Display-style piecewise cases environment (mathtools)",
            packageRequirement: "mathtools",
            snippetBody: "    \\frac{x^2}{2}, & \\text{if } |x| \\leq \\delta, \\\\\n    \\delta\\left(|x| - \\frac{\\delta}{2}\\right), & \\text{otherwise.}",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "pmatrix",
            groupCategory: "Equations & Math",
            summary: "Parenthesized matrix ( ... )",
            packageRequirement: "amsmath",
            snippetBody: "    a_{11} & a_{12} \\\\\n    a_{21} & a_{22}",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "bmatrix",
            groupCategory: "Equations & Math",
            summary: "Square-bracketed matrix [ ... ]",
            packageRequirement: "amsmath",
            snippetBody: "    1 & 0 \\\\\n    0 & 1",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "Bmatrix",
            groupCategory: "Equations & Math",
            summary: "Curly-braced matrix { ... }",
            packageRequirement: "amsmath",
            snippetBody: "    u_1 & u_2 \\\\\n    v_1 & v_2",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "vmatrix",
            groupCategory: "Equations & Math",
            summary: "Determinant vertical-bar matrix | ... |",
            packageRequirement: "amsmath",
            snippetBody: "    \\lambda - a & -b \\\\\n    -c & \\lambda - d",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "Vmatrix",
            groupCategory: "Equations & Math",
            summary: "Double-bar matrix || ... ||",
            packageRequirement: "amsmath",
            snippetBody: "    x_1 & x_2 \\\\\n    y_1 & y_2",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "matrix",
            groupCategory: "Equations & Math",
            summary: "Unbracketed matrix array",
            packageRequirement: "amsmath",
            snippetBody: "    a & b \\\\\n    c & d",
            isMathEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "smallmatrix",
            groupCategory: "Equations & Math",
            summary: "Compact inline matrix for running prose",
            packageRequirement: "amsmath",
            snippetBody: "a & b \\\\ c & d",
            isMathEnvironment: true
        ),

        // Theorems, Proofs & Formal Statements
        LatexEnvironmentTemplate(
            name: "theorem",
            groupCategory: "Theorems & Proofs",
            summary: "Numbered formal theorem statement with label",
            packageRequirement: "amsthm",
            snippetBody: "    \\label{thm:main}\n    Let $\\mathcal{F}$ be a compact hypothesis class. With probability at least $1 - \\delta$, ...",
            autoLabelPrefix: "thm:"
        ),
        LatexEnvironmentTemplate(
            name: "lemma",
            groupCategory: "Theorems & Proofs",
            summary: "Numbered auxiliary lemma statement with label",
            packageRequirement: "amsthm",
            snippetBody: "    \\label{lem:bound}\n    For every $\\eta \\in (0, 1)$, the sequence satisfies ...",
            autoLabelPrefix: "lem:"
        ),
        LatexEnvironmentTemplate(
            name: "proposition",
            groupCategory: "Theorems & Proofs",
            summary: "Numbered proposition environment with label",
            packageRequirement: "amsthm",
            snippetBody: "    \\label{prop:convergence}\n    Under regularity conditions, the estimator converges in distribution.",
            autoLabelPrefix: "prop:"
        ),
        LatexEnvironmentTemplate(
            name: "corollary",
            groupCategory: "Theorems & Proofs",
            summary: "Numbered corollary statement with label",
            packageRequirement: "amsthm",
            snippetBody: "    \\label{cor:rate}\n    As an immediate consequence, the sample complexity is $\\mathcal{O}(\\varepsilon^{-2})$.",
            autoLabelPrefix: "cor:"
        ),
        LatexEnvironmentTemplate(
            name: "definition",
            groupCategory: "Theorems & Proofs",
            summary: "Formal mathematical definition environment",
            packageRequirement: "amsthm",
            snippetBody: "    \\label{def:metric}\n    A mapping $d: X \\times X \\to \\mathbb{R}_{\\geq 0}$ is called ...",
            autoLabelPrefix: "def:"
        ),
        LatexEnvironmentTemplate(
            name: "assumption",
            groupCategory: "Theorems & Proofs",
            summary: "Numbered modeling or theoretical assumption",
            packageRequirement: "amsthm",
            snippetBody: "    \\label{assump:lipschitz}\n    The objective gradient $\\nabla f$ is $L$-Lipschitz continuous on $\\mathbb{R}^d$.",
            autoLabelPrefix: "assump:"
        ),
        LatexEnvironmentTemplate(
            name: "remark",
            groupCategory: "Theorems & Proofs",
            summary: "Technical remark or observation block",
            packageRequirement: "amsthm",
            snippetBody: "    \\label{rem:tightness}\n    The upper bound matches the minimax lower bound up to logarithmic factors.",
            autoLabelPrefix: "rem:"
        ),
        LatexEnvironmentTemplate(
            name: "example",
            groupCategory: "Theorems & Proofs",
            summary: "Illustrative worked example block",
            packageRequirement: "amsthm",
            snippetBody: "    \\label{ex:gaussian}\n    Consider the isotropic Gaussian case $x \\sim \\mathcal{N}(0, I_d)$."
        ),
        LatexEnvironmentTemplate(
            name: "conjecture",
            groupCategory: "Theorems & Proofs",
            summary: "Formal conjecture environment",
            packageRequirement: "amsthm",
            snippetBody: "    \\label{conj:spectral}\n    For all regular graphs of degree $d \\geq 3$, the spectral gap satisfies ..."
        ),
        LatexEnvironmentTemplate(
            name: "proof",
            groupCategory: "Theorems & Proofs",
            summary: "Mathematical proof block ending with QED square",
            packageRequirement: "amsthm",
            snippetBody: "    By applying Jensen's inequality to the convex functional, we obtain ..."
        ),

        // Algorithms & Code Listings
        LatexEnvironmentTemplate(
            name: "algorithm",
            groupCategory: "Algorithms & Listings",
            summary: "Floating numbered algorithm box with caption, label, and algorithmic body",
            packageRequirement: "algorithm, algpseudocode",
            snippetBody: "    \\caption{Iterative Optimization Procedure}\n    \\label{alg:main}\n    \\begin{algorithmic}[1]\n        \\Require Dataset $\\mathcal{D}$, step size $\\eta > 0$\n        \\Ensure Converged parameters $\\theta^*$\n        \\For{$t = 1, \\dots, T$}\n            \\State $\\theta_{t} \\gets \\theta_{t-1} - \\eta \\nabla \\mathcal{L}(\\theta_{t-1})$\n        \\EndFor\n        \\State \\Return $\\theta_T$\n    \\end{algorithmic}",
            autoLabelPrefix: "alg:",
            isFloatEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "algorithm*",
            groupCategory: "Algorithms & Listings",
            summary: "Two-column spanning wide algorithm float",
            packageRequirement: "algorithm, algpseudocode",
            snippetBody: "    \\caption{Distributed Consensus Protocol}\n    \\label{alg:distributed}\n    \\begin{algorithmic}[1]\n        \\State Initialize worker states\n    \\end{algorithmic}",
            autoLabelPrefix: "alg:",
            isFloatEnvironment: true
        ),
        LatexEnvironmentTemplate(
            name: "algorithmic",
            groupCategory: "Algorithms & Listings",
            summary: "Pseudocode step list inside an algorithm float",
            packageRequirement: "algpseudocode",
            snippetBody: "    \\State Initialize $x_0$\n    \\While{not converged}\n        \\State Update $x_{k+1}$\n    \\EndWhile"
        ),
        LatexEnvironmentTemplate(
            name: "lstlisting",
            groupCategory: "Algorithms & Listings",
            summary: "Syntax-highlighted source code listing with caption and label",
            packageRequirement: "listings",
            snippetBody: "% [language=Python, caption={Reference implementation.}, label={lst:impl}]\ndef compute(x):\n    return x",
            autoLabelPrefix: "lst:"
        ),
        LatexEnvironmentTemplate(
            name: "minted",
            groupCategory: "Algorithms & Listings",
            summary: "Pygments-highlighted code block",
            packageRequirement: "minted",
            snippetBody: "func solve(matrix: [[Double]]) -> [Double] {\n    return []\n}"
        ),
        LatexEnvironmentTemplate(
            name: "verbatim",
            groupCategory: "Algorithms & Listings",
            summary: "Monospace literal verbatim block",
            snippetBody: "Raw literal output"
        ),

        // Document Structure, Lists & Diagrams
        LatexEnvironmentTemplate(
            name: "abstract",
            groupCategory: "Document Structure",
            summary: "Manuscript abstract block",
            snippetBody: "    We investigate the fundamental trade-offs of ... and demonstrate significant improvements across benchmarks."
        ),
        LatexEnvironmentTemplate(
            name: "itemize",
            groupCategory: "Lists & Structure",
            summary: "Bulleted unordered list",
            snippetBody: "    \\item First key contribution.\n    \\item Second key contribution."
        ),
        LatexEnvironmentTemplate(
            name: "enumerate",
            groupCategory: "Lists & Structure",
            summary: "Numbered ordered list",
            snippetBody: "    \\item First step.\n    \\item Second step."
        ),
        LatexEnvironmentTemplate(
            name: "description",
            groupCategory: "Lists & Structure",
            summary: "Bold-term definition list",
            snippetBody: "    \\item[Soundness] Every accepted certificate corresponds to a valid proof.\n    \\item[Completeness] Every valid statement admits a verifiable certificate."
        ),
        LatexEnvironmentTemplate(
            name: "quote",
            groupCategory: "Lists & Structure",
            summary: "Indented short block quotation",
            snippetBody: "    Quoted excerpt from primary source."
        ),
        LatexEnvironmentTemplate(
            name: "minipage",
            groupCategory: "Lists & Structure",
            summary: "Side-by-side bounded width sub-box",
            snippetBody: "    Sub-panel content."
        ),
        LatexEnvironmentTemplate(
            name: "center",
            groupCategory: "Lists & Structure",
            summary: "Horizontally centered block",
            snippetBody: "    Centered display content."
        ),
        LatexEnvironmentTemplate(
            name: "tikzpicture",
            groupCategory: "Diagrams & Plots",
            summary: "Vector scientific figure drawn with TikZ",
            packageRequirement: "tikz",
            snippetBody: "    \\node[draw, rounded corners, minimum width=2.2cm, minimum height=0.8cm] (enc) at (0,0) {Encoder};\n    \\node[draw, rounded corners, minimum width=2.2cm, minimum height=0.8cm] (dec) at (3.6,0) {Decoder};\n    \\draw[->, thick] (enc) -- (dec);"
        ),
        LatexEnvironmentTemplate(
            name: "axis",
            groupCategory: "Diagrams & Plots",
            summary: "Publication-grade coordinate plot inside tikzpicture (pgfplots)",
            packageRequirement: "pgfplots",
            snippetBody: "    \\addplot+[mark=*, smooth] coordinates {(1, 0.72) (2, 0.84) (4, 0.91) (8, 0.94)};\n    \\addlegendentry{Proposed}"
        ),
        LatexEnvironmentTemplate(
            name: "thebibliography",
            groupCategory: "Document Structure",
            summary: "Manual LaTeX bibliography environment",
            snippetBody: "    \\bibitem{example2025} Author, A. (2025). Title. \\emph{Journal}, 1(1), 1--10."
        )
    ]

    // MARK: - 210+ Built-in LaTeX & Typst Commands and Math Symbols Catalog

    public static let builtinCommandsAndSymbols: [BuiltinCommandAndMathEntry] = {
        var list: [BuiltinCommandAndMathEntry] = []

        func cmd(_ name: String, _ snippet: String, _ summary: String, pkg: String? = nil, format: ManuscriptFormat = .latex) {
            list.append(BuiltinCommandAndMathEntry(trigger: name, insertText: snippet, summary: summary, packageHint: pkg, category: .command, format: format, mathOnly: false))
        }

        func math(_ name: String, _ uni: String?, _ summary: String, snippet: String? = nil, pkg: String? = nil, format: ManuscriptFormat = .latex) {
            list.append(BuiltinCommandAndMathEntry(trigger: name, insertText: snippet ?? name, unicodePreview: uni, summary: summary, packageHint: pkg, category: .mathSymbol, format: format, mathOnly: true))
        }

        // 1. LaTeX Sectioning, Citations, Cross-Refs, Typography & Tables (44 entries)
        cmd("\\section", "\\section{}", "Top-level numbered section heading")
        cmd("\\section*", "\\section*{}", "Unnumbered top-level section heading")
        cmd("\\subsection", "\\subsection{}", "Second-level numbered subsection heading")
        cmd("\\subsubsection", "\\subsubsection{}", "Third-level numbered subsubsection heading")
        cmd("\\paragraph", "\\paragraph{}", "Run-in fourth-level paragraph heading")
        cmd("\\chapter", "\\chapter{}", "Book/thesis chapter heading")
        cmd("\\appendix", "\\appendix", "Switch subsequent sections to Appendix numbering (A, B, ...)")
        cmd("\\label", "\\label{}", "Declare cross-reference anchor key")
        cmd("\\ref", "\\ref{}", "Reference numbered section, figure, table, or theorem")
        cmd("\\eqref", "\\eqref{}", "Parenthesized equation cross-reference (amsmath)", pkg: "amsmath")
        cmd("\\autoref", "\\autoref{}", "Auto-prefixed cross-reference (hyperref)", pkg: "hyperref")
        cmd("\\cref", "\\cref{}", "Clever lowercase cross-reference (cleveref)", pkg: "cleveref")
        cmd("\\Cref", "\\Cref{}", "Clever capitalized sentence-start cross-reference (cleveref)", pkg: "cleveref")
        cmd("\\pageref", "\\pageref{}", "Page number reference for label")
        cmd("\\cite", "\\cite{}", "Standard bibliography citation")
        cmd("\\citep", "\\citep{}", "Parenthetical author-year citation (natbib)", pkg: "natbib")
        cmd("\\citet", "\\citet{}", "Narrative in-text citation (natbib)", pkg: "natbib")
        cmd("\\citeauthor", "\\citeauthor{}", "Cite author surname(s) only (natbib/biblatex)")
        cmd("\\citeyear", "\\citeyear{}", "Cite publication year only (natbib/biblatex)")
        cmd("\\parencite", "\\parencite{}", "Parenthetical citation (biblatex)", pkg: "biblatex")
        cmd("\\textcite", "\\textcite{}", "Narrative citation (biblatex)", pkg: "biblatex")
        cmd("\\autocite", "\\autocite{}", "Style-adaptive citation (biblatex)", pkg: "biblatex")
        cmd("\\footcite", "\\footcite{}", "Footnote citation (biblatex)", pkg: "biblatex")
        cmd("\\nocite", "\\nocite{}", "Include entry in bibliography without in-text marker")
        cmd("\\textbf", "\\textbf{}", "Boldface text span")
        cmd("\\textit", "\\textit{}", "Italic text span")
        cmd("\\emph", "\\emph{}", "Semantic emphasized text span")
        cmd("\\texttt", "\\texttt{}", "Monospace typewriter text span")
        cmd("\\textsc", "\\textsc{}", "Small-caps text span")
        cmd("\\underline", "\\underline{}", "Underlined text span")
        cmd("\\footnote", "\\footnote{}", "Numbered page footnote")
        cmd("\\caption", "\\caption{}", "Float figure or table caption")
        cmd("\\includegraphics", "\\includegraphics[width=0.9\\linewidth]{}", "Embed vector PDF or raster image", pkg: "graphicx")
        cmd("\\input", "\\input{}", "Transclude child LaTeX file without page break")
        cmd("\\include", "\\include{}", "Include chapter/section file with page break")
        cmd("\\bibliography", "\\bibliography{}", "Specify BibTeX .bib database file(s)")
        cmd("\\addbibresource", "\\addbibresource{}", "Register BibLaTeX .bib resource file", pkg: "biblatex")
        cmd("\\usepackage", "\\usepackage{}", "Load LaTeX macro package in preamble")
        cmd("\\newcommand", "\\newcommand{\\cmd}[1]{}", "Define new custom LaTeX macro")
        cmd("\\renewcommand", "\\renewcommand{\\cmd}[1]{}", "Redefine existing LaTeX macro")
        cmd("\\DeclareMathOperator", "\\DeclareMathOperator{\\op}{op}", "Declare upright math operator", pkg: "amsmath")
        cmd("\\DeclareMathOperator*", "\\DeclareMathOperator*{\\op}{op}", "Declare math operator with limits above/below", pkg: "amsmath")
        cmd("\\toprule", "\\toprule", "Heavy top horizontal rule for Booktabs table", pkg: "booktabs")
        cmd("\\midrule", "\\midrule", "Thin middle separator rule for Booktabs table", pkg: "booktabs")
        cmd("\\bottomrule", "\\bottomrule", "Heavy bottom rule for Booktabs table", pkg: "booktabs")
        cmd("\\cmidrule", "\\cmidrule(lr){1-2}", "Partial-span subheader rule for Booktabs table", pkg: "booktabs")
        cmd("\\multicolumn", "\\multicolumn{2}{c}{}", "Span cell across multiple table columns")
        cmd("\\multirow", "\\multirow{2}{*}{}", "Span cell across multiple table rows", pkg: "multirow")
        cmd("\\url", "\\url{}", "Typeset clickable verbatim URL", pkg: "hyperref")
        cmd("\\href", "\\href{}{}", "Hyperlink custom anchor text to URL", pkg: "hyperref")

        // 2. LaTeX Greek Letters (40 entries)
        let greekSymbols: [(String, String, String)] = [
            ("\\alpha", "α", "Greek lowercase alpha"),
            ("\\beta", "β", "Greek lowercase beta"),
            ("\\gamma", "γ", "Greek lowercase gamma"),
            ("\\delta", "δ", "Greek lowercase delta"),
            ("\\epsilon", "ϵ", "Greek lunate epsilon"),
            ("\\varepsilon", "ε", "Greek curly varepsilon"),
            ("\\zeta", "ζ", "Greek lowercase zeta"),
            ("\\eta", "η", "Greek lowercase eta"),
            ("\\theta", "θ", "Greek lowercase theta"),
            ("\\vartheta", "ϑ", "Greek curly vartheta"),
            ("\\iota", "ι", "Greek lowercase iota"),
            ("\\kappa", "κ", "Greek lowercase kappa"),
            ("\\lambda", "λ", "Greek lowercase lambda"),
            ("\\mu", "μ", "Greek lowercase mu"),
            ("\\nu", "ν", "Greek lowercase nu"),
            ("\\xi", "ξ", "Greek lowercase xi"),
            ("\\pi", "π", "Greek lowercase pi"),
            ("\\varpi", "ϖ", "Greek variant pi"),
            ("\\rho", "ρ", "Greek lowercase rho"),
            ("\\varrho", "ϱ", "Greek variant rho"),
            ("\\sigma", "σ", "Greek lowercase sigma"),
            ("\\varsigma", "ς", "Greek final sigma"),
            ("\\tau", "τ", "Greek lowercase tau"),
            ("\\upsilon", "υ", "Greek lowercase upsilon"),
            ("\\phi", "ϕ", "Greek straight phi"),
            ("\\varphi", "φ", "Greek curly varphi"),
            ("\\chi", "χ", "Greek lowercase chi"),
            ("\\psi", "ψ", "Greek lowercase psi"),
            ("\\omega", "ω", "Greek lowercase omega"),
            ("\\Gamma", "Γ", "Greek uppercase Gamma"),
            ("\\Delta", "Δ", "Greek uppercase Delta"),
            ("\\Theta", "Θ", "Greek uppercase Theta"),
            ("\\Lambda", "Λ", "Greek uppercase Lambda"),
            ("\\Xi", "Ξ", "Greek uppercase Xi"),
            ("\\Pi", "Π", "Greek uppercase Pi"),
            ("\\Sigma", "Σ", "Greek uppercase Sigma"),
            ("\\Upsilon", "Υ", "Greek uppercase Upsilon"),
            ("\\Phi", "Φ", "Greek uppercase Phi"),
            ("\\Psi", "Ψ", "Greek uppercase Psi"),
            ("\\Omega", "Ω", "Greek uppercase Omega")
        ]
        for (g, u, desc) in greekSymbols {
            math(g, u, desc)
        }

        // 3. LaTeX Calculus, Big Operators, Binary Operators, Relations, Arrows & Constructs (105 entries)
        let mathOps: [(String, String?, String, String?, String?)] = [
            ("\\sum", "∑", "Summation operator", "\\sum_{i=1}^{n}", nil),
            ("\\prod", "∏", "Product operator", "\\prod_{i=1}^{n}", nil),
            ("\\coprod", "∐", "Coproduct operator", nil, nil),
            ("\\int", "∫", "Definite or indefinite integral", "\\int_{a}^{b}", nil),
            ("\\iint", "∬", "Double integral", nil, "amsmath"),
            ("\\iiint", "∭", "Triple integral", nil, "amsmath"),
            ("\\oint", "∮", "Contour integral", nil, nil),
            ("\\bigcup", "⋃", "Indexed union", "\\bigcup_{i=1}^{n}", nil),
            ("\\bigcap", "⋂", "Indexed intersection", "\\bigcap_{i=1}^{n}", nil),
            ("\\bigoplus", "⨁", "Indexed direct sum", nil, nil),
            ("\\bigotimes", "⨂", "Indexed tensor product", nil, nil),
            ("\\bigsqcup", "⨆", "Indexed disjoint union", nil, nil),
            ("\\bigvee", "⋁", "Indexed logical disjunction", nil, nil),
            ("\\bigwedge", "⋀", "Indexed logical conjunction", nil, nil),
            ("\\lim", "lim", "Limit operator", "\\lim_{n \\to \\infty}", nil),
            ("\\limsup", "lim sup", "Limit superior", nil, nil),
            ("\\liminf", "lim inf", "Limit inferior", nil, nil),
            ("\\sup", "sup", "Supremum", nil, nil),
            ("\\inf", "inf", "Infimum", nil, nil),
            ("\\max", "max", "Maximum", nil, nil),
            ("\\min", "min", "Minimum", nil, nil),
            ("\\det", "det", "Matrix determinant", nil, nil),
            ("\\exp", "exp", "Exponential function", nil, nil),
            ("\\log", "log", "Logarithm", nil, nil),
            ("\\ln", "ln", "Natural logarithm", nil, nil),
            ("\\sin", "sin", "Sine", nil, nil),
            ("\\cos", "cos", "Cosine", nil, nil),
            ("\\tan", "tan", "Tangent", nil, nil),
            ("\\nabla", "∇", "Gradient / del differential operator", nil, nil),
            ("\\partial", "∂", "Partial derivative symbol", nil, nil),
            ("\\infty", "∞", "Infinity symbol", nil, nil),
            ("\\pm", "±", "Plus-minus operator", nil, nil),
            ("\\mp", "∓", "Minus-plus operator", nil, nil),
            ("\\times", "×", "Cartesian / cross product", nil, nil),
            ("\\div", "÷", "Division operator", nil, nil),
            ("\\cdot", "·", "Centered dot product", nil, nil),
            ("\\ast", "∗", "Centered asterisk operator", nil, nil),
            ("\\star", "⋆", "Five-pointed star operator", nil, nil),
            ("\\circ", "∘", "Function composition circle", nil, nil),
            ("\\bullet", "∙", "Bullet operator", nil, nil),
            ("\\oplus", "⊕", "Direct sum / XOR", nil, nil),
            ("\\ominus", "⊖", "Symmetric difference / circled minus", nil, nil),
            ("\\otimes", "⊗", "Kronecker / tensor product", nil, nil),
            ("\\odot", "⊙", "Hadamard / elementwise product", nil, nil),
            ("\\cap", "∩", "Set intersection", nil, nil),
            ("\\cup", "∪", "Set union", nil, nil),
            ("\\uplus", "⊎", "Multiset / disjoint union", nil, nil),
            ("\\sqcap", "⊓", "Square cap", nil, nil),
            ("\\sqcup", "⊔", "Square cup", nil, nil),
            ("\\vee", "∨", "Logical OR / join", nil, nil),
            ("\\wedge", "∧", "Logical AND / meet", nil, nil),
            ("\\setminus", "∖", "Set difference", nil, nil),
            ("\\dagger", "†", "Hermitian adjoint / dagger", nil, nil),
            ("\\ddagger", "‡", "Double dagger", nil, nil),
            ("\\leq", "≤", "Less than or equal to", nil, nil),
            ("\\geq", "≥", "Greater than or equal to", nil, nil),
            ("\\neq", "≠", "Not equal to", nil, nil),
            ("\\approx", "≈", "Approximately equal to", nil, nil),
            ("\\equiv", "≡", "Identically equal / congruent to", nil, nil),
            ("\\sim", "∼", "Distributed as / asymptotic similarity", nil, nil),
            ("\\simeq", "≃", "Asymptotically equal to", nil, nil),
            ("\\cong", "≅", "Isomorphic to", nil, nil),
            ("\\propto", "∝", "Proportional to", nil, nil),
            ("\\ll", "≪", "Much less than", nil, nil),
            ("\\gg", "≫", "Much greater than", nil, nil),
            ("\\prec", "≺", "Precedes", nil, nil),
            ("\\preceq", "⪯", "Precedes or equals", nil, nil),
            ("\\succ", "≻", "Succeeds", nil, nil),
            ("\\succeq", "⪰", "Succeeds or equals", nil, nil),
            ("\\subset", "⊂", "Proper subset", nil, nil),
            ("\\subseteq", "⊆", "Subset or equal", nil, nil),
            ("\\supset", "⊃", "Proper superset", nil, nil),
            ("\\supseteq", "⊇", "Superset or equal", nil, nil),
            ("\\in", "∈", "Element of", nil, nil),
            ("\\notin", "∉", "Not an element of", nil, nil),
            ("\\ni", "∋", "Contains as member", nil, nil),
            ("\\vdash", "⊢", "Syntactic entailment turnstile", nil, nil),
            ("\\models", "⊨", "Semantic entailment double turnstile", nil, nil),
            ("\\perp", "⊥", "Orthogonal / independent", nil, nil),
            ("\\mid", "∣", "Conditioning bar / divides", nil, nil),
            ("\\parallel", "∥", "Parallel / KL divergence separator", nil, nil),
            ("\\coloneqq", "≔", "Defined equal (:=)", nil, "mathtools"),
            ("\\triangleq", "≜", "Delta equal by definition", nil, "amssymb"),
            ("\\to", "→", "Maps / converges to right arrow", nil, nil),
            ("\\rightarrow", "→", "Rightwards arrow", nil, nil),
            ("\\leftarrow", "←", "Leftwards arrow", nil, nil),
            ("\\leftrightarrow", "↔", "Left-right arrow", nil, nil),
            ("\\Rightarrow", "⇒", "Implies double right arrow", nil, nil),
            ("\\Leftarrow", "⇐", "Implied by double left arrow", nil, nil),
            ("\\Leftrightarrow", "⇔", "If and only if double arrow", nil, nil),
            ("\\iff", "⟺", "Long if and only if arrow", nil, "amsmath"),
            ("\\implies", "⟹", "Long implies arrow", nil, "amsmath"),
            ("\\mapsto", "↦", "Elementwise function maps-to arrow", nil, nil),
            ("\\hookrightarrow", "↪", "Injective embedding hook arrow", nil, nil),
            ("\\uparrow", "↑", "Monotone increasing / higher-is-better arrow", nil, nil),
            ("\\downarrow", "↓", "Monotone decreasing / lower-is-better arrow", nil, nil),
            ("\\forall", "∀", "Universal quantifier", nil, nil),
            ("\\exists", "∃", "Existential quantifier", nil, nil),
            ("\\nexists", "∄", "Negated existential quantifier", nil, "amssymb"),
            ("\\neg", "¬", "Logical negation", nil, nil),
            ("\\emptyset", "∅", "Empty set", nil, nil),
            ("\\varnothing", "∅", "Round empty set (amssymb)", nil, "amssymb"),
            ("\\hbar", "ℏ", "Reduced Planck constant", nil, nil),
            ("\\ell", "ℓ", "Script lowercase l", nil, nil),
            ("\\top", "⊤", "Matrix transpose / top lattice element", nil, nil),
            ("\\bot", "⊥", "Bottom lattice element", nil, nil),
            ("\\dots", "…", "Context-aware ellipsis", nil, "amsmath"),
            ("\\ldots", "…", "Baseline ellipsis", nil, nil),
            ("\\cdots", "⋯", "Centered math ellipsis", nil, nil),
            ("\\vdots", "⋮", "Vertical matrix ellipsis", nil, nil),
            ("\\ddots", "⋱", "Diagonal matrix ellipsis", nil, nil),
            ("\\frac", "a/b", "Displayed or inline fraction", "\\frac{}{}", nil),
            ("\\dfrac", "a/b", "Display-size fraction", "\\dfrac{}{}", "amsmath"),
            ("\\tfrac", "a/b", "Text-size inline fraction", "\\tfrac{}{}", "amsmath"),
            ("\\binom", "(n k)", "Binomial coefficient", "\\binom{}{}", "amsmath"),
            ("\\sqrt", "√", "Square or nth root", "\\sqrt{}", nil),
            ("\\hat", "x̂", "Circumflex estimator hat accent", "\\hat{}", nil),
            ("\\widehat", "x̂", "Wide circumflex hat accent", "\\widehat{}", nil),
            ("\\tilde", "x̃", "Tilde accent", "\\tilde{}", nil),
            ("\\widetilde", "x̃", "Wide tilde accent", "\\widetilde{}", nil),
            ("\\bar", "x̄", "Sample mean bar accent", "\\bar{}", nil),
            ("\\overline", "x̅", "Wide overline bar", "\\overline{}", nil),
            ("\\vec", "x⃗", "Vector arrow accent", "\\vec{}", nil),
            ("\\dot", "ẋ", "Time derivative single dot", "\\dot{}", nil),
            ("\\ddot", "ẍ", "Second time derivative double dot", "\\ddot{}", nil),
            ("\\mathbb", "ℝ,𝔼", "Blackboard bold font (\\mathbb{R}, \\mathbb{E})", "\\mathbb{}", "amssymb"),
            ("\\mathcal", "𝒜,ℒ", "Calligraphic uppercase math font", "\\mathcal{}", nil),
            ("\\mathbf", "𝐱", "Bold upright math vector/matrix font", "\\mathbf{}", nil),
            ("\\mathrm", "d", "Upright Roman math font (e.g. \\mathrm{d}x)", "\\mathrm{}", nil),
            ("\\mathfrak", "𝔤", "Euler Fraktur math font", "\\mathfrak{}", "amssymb"),
            ("\\boldsymbol", "𝜽", "Bold italic Greek/symbol font", "\\boldsymbol{}", "amsmath"),
            ("\\operatorname", "op", "Ad-hoc upright math operator", "\\operatorname{}", "amsmath"),
            ("\\text", "abc", "Prose text inside math mode", "\\text{}", "amsmath"),
            ("\\left", "(…", "Auto-sized left delimiter", "\\left(", nil),
            ("\\right", "…)", "Auto-sized right delimiter", "\\right)", nil),
            ("\\langle", "⟨", "Left inner-product angle bracket", nil, nil),
            ("\\rangle", "⟩", "Right inner-product angle bracket", nil, nil),
            ("\\lceil", "⌈", "Left ceiling delimiter", nil, nil),
            ("\\rceil", "⌉", "Right ceiling delimiter", nil, nil),
            ("\\lfloor", "⌊", "Left floor delimiter", nil, nil),
            ("\\rfloor", "⌋", "Right floor delimiter", nil, nil)
        ]
        for (name, uni, summary, snip, pkg) in mathOps {
            math(name, uni, summary, snippet: snip, pkg: pkg)
        }

        // 4. Typst Directives & Native Typst Math Symbols (32 entries)
        cmd("#set", "#set text(size: 10pt)", "Configure Typst element styling rule", format: .typst)
        cmd("#show", "#show heading: it => it", "Transform Typst document elements", format: .typst)
        cmd("#let", "#let name(x) = []", "Bind Typst variable or macro function", format: .typst)
        cmd("#import", "#import \"template.typ\": *", "Import module bindings from Typst file", format: .typst)
        cmd("#include", "#include \"sections/intro.typ\"", "Transclude Typst content file", format: .typst)
        cmd("#cite", "#cite(<key>)", "Insert Typst citation with options", format: .typst)
        cmd("#ref", "#ref(<label>)", "Insert Typst cross-reference", format: .typst)
        cmd("#bibliography", "#bibliography(\"references.bib\", style: \"apa\")", "Render Typst bibliography section", format: .typst)
        cmd("#figure", "#figure(\n  image(\"diagram.pdf\", width: 85%),\n  caption: [Overview.],\n) <fig:overview>", "Floating Typst figure with caption and label", format: .typst)
        cmd("#table", "#table(\n  columns: 3,\n  [Method], [Acc], [F1],\n)", "Typst multi-column table layout", format: .typst)
        cmd("#grid", "#grid(columns: (1fr, 1fr), gutter: 12pt, [], [])", "Typst multi-column layout grid", format: .typst)
        cmd("#align", "#align(center)[]", "Align Typst content block", format: .typst)
        cmd("#block", "#block(breakable: false)[]", "Block-level Typst container", format: .typst)
        cmd("#footnote", "#footnote[]", "Insert Typst page footnote", format: .typst)
        cmd("#link", "#link(\"https://doi.org/\")[]", "Insert Typst hyperlink", format: .typst)
        cmd("#numbering", "#numbering(\"1.1\", 1, 2)", "Format counter numbers in Typst", format: .typst)

        let typstMath: [(String, String, String)] = [
            ("alpha", "α", "Typst Greek alpha"),
            ("beta", "β", "Typst Greek beta"),
            ("gamma", "γ", "Typst Greek gamma"),
            ("delta", "δ", "Typst Greek delta"),
            ("epsilon", "ϵ", "Typst Greek epsilon"),
            ("theta", "θ", "Typst Greek theta"),
            ("lambda", "λ", "Typst Greek lambda"),
            ("mu", "μ", "Typst Greek mu"),
            ("sigma", "σ", "Typst Greek sigma"),
            ("omega", "ω", "Typst Greek omega"),
            ("sum", "∑", "Typst summation operator"),
            ("product", "∏", "Typst product operator"),
            ("integral", "∫", "Typst integral operator"),
            ("nabla", "∇", "Typst gradient symbol"),
            ("partial", "∂", "Typst partial derivative"),
            ("infinity", "∞", "Typst infinity symbol"),
            ("approx", "≈", "Typst approximately equal"),
            ("equiv", "≡", "Typst equivalence symbol"),
            ("subset.eq", "⊆", "Typst subset or equal"),
            ("supset.eq", "⊇", "Typst superset or equal"),
            ("arrow.r", "→", "Typst right arrow"),
            ("arrow.r.double", "⇒", "Typst implies double right arrow"),
            ("RR", "ℝ", "Typst real numbers blackboard bold"),
            ("EE", "𝔼", "Typst expectation blackboard bold")
        ]
        for (sym, uni, desc) in typstMath {
            math(sym, uni, desc, format: .typst)
        }

        return list
    }()
}
