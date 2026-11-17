import Foundation
import ScholarModels

// MARK: - Academic Venue Presets & Page/Word Budget Models

/// Calibrated academic conference and journal layout specifications for manuscript budget estimation.
public enum AcademicVenuePreset: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case neurips9Page = "NeurIPS (9p Main Body)"
    case acl8Page = "ACL / EMNLP (8p Long Paper)"
    case acl4PageShort = "ACL / EMNLP (4p Short Paper)"
    case chiConference = "ACM CHI (7,000–8,500 Words / ~10p)"
    case natureArticle = "Nature Article (3,000 Words, ≤6 Display Items)"
    case icml8Page = "ICML (8p Double-Column)"
    case iclr10Page = "ICLR (10p Main Body)"
    case ieeeTransactions = "IEEE Transactions (10p Double-Column)"
    case scienceResearchArticle = "Science Research Article (4,500 Words)"

    public var id: String { rawValue }

    /// Maximum main-body page limit (excluding references and appendices).
    public var targetPageLimit: Double {
        switch self {
        case .neurips9Page: return 9.0
        case .acl8Page: return 8.0
        case .acl4PageShort: return 4.0
        case .chiConference: return 10.0
        case .natureArticle: return 6.0
        case .icml8Page: return 8.0
        case .iclr10Page: return 10.0
        case .ieeeTransactions: return 10.0
        case .scienceResearchArticle: return 6.5
        }
    }

    /// Calibrated prose words per dense typeset page (excluding floats and display equations).
    public var proseWordsPerFullPage: Double {
        switch self {
        case .neurips9Page:
            // NeurIPS 9-page submission template (~600–650 prose words/page at 10pt, or 2-col workshop ~680)
            return 630.0
        case .acl8Page, .acl4PageShort:
            // ACL 2-column 11pt Times (`acl.sty`) averages ~680–720 prose words per full text page
            return 700.0
        case .chiConference:
            // ACM `acmart` sigconf double-column averages ~750–800 prose words per full text page
            return 760.0
        case .natureArticle:
            // Nature print layout averages ~550–600 words per full text page
            return 560.0
        case .icml8Page:
            // ICML 2-column 10pt averages ~720 prose words per full text page
            return 720.0
        case .iclr10Page:
            // ICLR 10pt single-column averages ~580 prose words per full text page
            return 580.0
        case .ieeeTransactions:
            // IEEEtran 10pt 2-column journal layout averages ~820 prose words per full text page
            return 820.0
        case .scienceResearchArticle:
            return 700.0
        }
    }

    /// Explicit prose word cap when enforced directly by editorial policy (e.g. Nature, Science, CHI).
    public var explicitWordCap: Int? {
        switch self {
        case .neurips9Page: return nil
        case .acl8Page: return nil
        case .acl4PageShort: return nil
        case .chiConference: return 8_500
        case .natureArticle: return 3_500
        case .icml8Page: return nil
        case .iclr10Page: return nil
        case .ieeeTransactions: return nil
        case .scienceResearchArticle: return 4_500
        }
    }

    /// Maximum abstract word count enforced by the venue, if applicable.
    public var maxAbstractWords: Int? {
        switch self {
        case .neurips9Page: return 250
        case .acl8Page, .acl4PageShort: return 200
        case .chiConference: return 150
        case .natureArticle: return 200
        case .icml8Page: return 250
        case .iclr10Page: return 250
        case .ieeeTransactions: return 250
        case .scienceResearchArticle: return 125
        }
    }

    /// Maximum total display items (figures + tables) permitted in main body, if capped.
    public var maxDisplayItems: Int? {
        switch self {
        case .natureArticle: return 6
        case .scienceResearchArticle: return 6
        default: return nil
        }
    }

    /// Fractional page footprint occupied by a standard single-column figure vs two-column `figure*`.
    public var singleColumnFigurePageFootprint: Double {
        switch self {
        case .neurips9Page, .iclr10Page: return 0.34
        default: return 0.24
        }
    }

    public var wideFigurePageFootprint: Double {
        0.44
    }

    public var singleColumnTablePageFootprint: Double {
        switch self {
        case .neurips9Page, .iclr10Page: return 0.28
        default: return 0.20
        }
    }

    public var wideTablePageFootprint: Double {
        0.38
    }

    public var algorithmPageFootprint: Double {
        0.26
    }

    public var displayEquationPageFootprint: Double {
        0.042
    }
}

/// Compliance status of a manuscript against a target academic venue's page/word limits.
public enum VenueBudgetComplianceStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case withinBudget = "WITHIN_BUDGET"
    case nearLimitAdvisory = "NEAR_LIMIT"
    case overBudget = "OVER_BUDGET"
}

/// Estimated page & word budget utilization for a specific academic conference or journal.
public struct VenueBudgetEstimate: Sendable, Codable, Hashable, Identifiable {
    public var id: String { venue.rawValue }
    public let venue: AcademicVenuePreset
    public let estimatedMainBodyPages: Double
    public let targetPageLimit: Double
    public let pageUtilizationRatio: Double
    public let effectiveWordLimit: Int
    /// Positive when words remain before hitting the venue budget; negative when over budget.
    public let remainingOrExcessWords: Int
    public let abstractLimitExceeded: Bool
    public let displayItemLimitExceeded: Bool
    public let status: VenueBudgetComplianceStatus
    public let advisoryNotes: [String]

    public init(
        venue: AcademicVenuePreset,
        estimatedMainBodyPages: Double,
        targetPageLimit: Double,
        pageUtilizationRatio: Double,
        effectiveWordLimit: Int,
        remainingOrExcessWords: Int,
        abstractLimitExceeded: Bool,
        displayItemLimitExceeded: Bool,
        status: VenueBudgetComplianceStatus,
        advisoryNotes: [String]
    ) {
        self.venue = venue
        self.estimatedMainBodyPages = estimatedMainBodyPages
        self.targetPageLimit = targetPageLimit
        self.pageUtilizationRatio = pageUtilizationRatio
        self.effectiveWordLimit = effectiveWordLimit
        self.remainingOrExcessWords = remainingOrExcessWords
        self.abstractLimitExceeded = abstractLimitExceeded
        self.displayItemLimitExceeded = displayItemLimitExceeded
        self.status = status
        self.advisoryNotes = advisoryNotes
    }
}

// MARK: - Readability & Per-Section Telemetry Models

/// Academic prose readability telemetry including Flesch-Kincaid Grade Level, Flesch Reading Ease,
/// Gunning Fog Index, Coleman-Liau Index, and lexical diversity.
public struct ReadabilityTelemetry: Sendable, Codable, Hashable {
    public let sentenceCount: Int
    public let wordCountAnalyzed: Int
    public let syllableCount: Int
    public let complexPolysyllabicWordCount: Int
    public let averageWordsPerSentence: Double
    public let averageSyllablesPerWord: Double
    public let fleschReadingEase: Double
    public let fleschKincaidGradeLevel: Double
    public let gunningFogIndex: Double
    public let colemanLiauIndex: Double
    public let lexicalTypeTokenRatio: Double
    public let academicRegisterInterpretation: String

    public init(
        sentenceCount: Int,
        wordCountAnalyzed: Int,
        syllableCount: Int,
        complexPolysyllabicWordCount: Int,
        averageWordsPerSentence: Double,
        averageSyllablesPerWord: Double,
        fleschReadingEase: Double,
        fleschKincaidGradeLevel: Double,
        gunningFogIndex: Double,
        colemanLiauIndex: Double,
        lexicalTypeTokenRatio: Double,
        academicRegisterInterpretation: String
    ) {
        self.sentenceCount = sentenceCount
        self.wordCountAnalyzed = wordCountAnalyzed
        self.syllableCount = syllableCount
        self.complexPolysyllabicWordCount = complexPolysyllabicWordCount
        self.averageWordsPerSentence = averageWordsPerSentence
        self.averageSyllablesPerWord = averageSyllablesPerWord
        self.fleschReadingEase = fleschReadingEase
        self.fleschKincaidGradeLevel = fleschKincaidGradeLevel
        self.gunningFogIndex = gunningFogIndex
        self.colemanLiauIndex = colemanLiauIndex
        self.lexicalTypeTokenRatio = lexicalTypeTokenRatio
        self.academicRegisterInterpretation = academicRegisterInterpretation
    }

    public static let empty = ReadabilityTelemetry(
        sentenceCount: 0,
        wordCountAnalyzed: 0,
        syllableCount: 0,
        complexPolysyllabicWordCount: 0,
        averageWordsPerSentence: 0.0,
        averageSyllablesPerWord: 0.0,
        fleschReadingEase: 0.0,
        fleschKincaidGradeLevel: 0.0,
        gunningFogIndex: 0.0,
        colemanLiauIndex: 0.0,
        lexicalTypeTokenRatio: 0.0,
        academicRegisterInterpretation: "Insufficient prose for readability scoring"
    )
}

/// Per-section word, citation, equation, and float distribution metrics.
public struct SectionMetricsBreakdown: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(filePath):\(line):\(title)" }
    public let numberPrefix: String
    public let title: String
    public let level: Int
    public let isAppendix: Bool
    public let filePath: String
    public let line: Int
    public let directBodyWordCount: Int
    public let subtreeBodyWordCount: Int
    public let citationOccurrencesInSubtree: Int
    public let equationsInSubtree: Int
    public let floatsInSubtree: Int

    public init(
        numberPrefix: String,
        title: String,
        level: Int,
        isAppendix: Bool,
        filePath: String,
        line: Int,
        directBodyWordCount: Int,
        subtreeBodyWordCount: Int,
        citationOccurrencesInSubtree: Int,
        equationsInSubtree: Int,
        floatsInSubtree: Int
    ) {
        self.numberPrefix = numberPrefix
        self.title = title
        self.level = level
        self.isAppendix = isAppendix
        self.filePath = filePath
        self.line = line
        self.directBodyWordCount = directBodyWordCount
        self.subtreeBodyWordCount = subtreeBodyWordCount
        self.citationOccurrencesInSubtree = citationOccurrencesInSubtree
        self.equationsInSubtree = equationsInSubtree
        self.floatsInSubtree = floatsInSubtree
    }
}

/// Comprehensive `texcount`-grade manuscript metrics, citation density, readability, and venue budget report.
public struct ManuscriptMetricsReport: Sendable, Codable, Hashable {
    /// Main-body prose words (excluding preamble, abstract, headers, captions, math formulas, citations, and code/tikz environments).
    public let bodyProseWordCount: Int
    /// Prose words occurring inside appendices (after `\appendix`), tracked separately for conference main-body page limits!
    public let appendixProseWordCount: Int
    /// Words inside `\begin{abstract}...\end{abstract}` (or Abstract section).
    public let abstractWordCount: Int
    /// Words inside `\caption{...}`, `\subcaption{...}`, or Typst figure/table captions.
    public let captionWordCount: Int
    /// Words inside `\title{...}` and section/subsection headings.
    public let headerWordCount: Int
    /// Words inside `\footnote{...}` and `\marginpar{...}`.
    public let footnoteWordCount: Int
    /// Total counted manuscript words (`bodyProseWordCount + appendixProseWordCount + abstractWordCount + captionWordCount + headerWordCount + footnoteWordCount`).
    public let totalCountedWords: Int

    /// Clean prose character count including single inter-word spaces.
    public let characterCountWithSpaces: Int
    /// Clean prose character count excluding all whitespace.
    public let characterCountWithoutSpaces: Int
    public let paragraphCount: Int

    /// Inline math expressions (`$...$`, `\(...\)`, Typst `$x$`).
    public let inlineEquationCount: Int
    /// Display math expressions (`$$...$$`, `\[...\]`, `equation`, `align`, `gather`, `multline`, Typst `$ x $`).
    public let displayEquationCount: Int
    public var totalEquationCount: Int { inlineEquationCount + displayEquationCount }

    public let figureCount: Int
    public let wideFigureCount: Int
    public let tableCount: Int
    public let wideTableCount: Int
    public let algorithmCount: Int
    public let theoremAndLemmaCount: Int

    /// Total citation key appearances across the manuscript (counting repeated citations and multi-key lists).
    public let totalCitationOccurrences: Int
    /// Distinct bibliography cite keys referenced in the manuscript.
    public let uniqueCitedKeysCount: Int
    public let uniqueCitedKeys: [String]
    public let citationFrequencyByKey: [String: Int]
    public let citationDensityPerThousandWords: Double

    /// Deep-reading academic reading time in minutes (~200 wpm prose + equation & figure inspection overhead).
    public let estimatedReadingTimeMinutes: Double
    /// Conference talk / oral reading pace (~130 wpm).
    public let estimatedSpeakingTimeMinutes: Double

    public let readability: ReadabilityTelemetry
    public let sectionBreakdowns: [SectionMetricsBreakdown]
    public let venueEstimates: [VenueBudgetEstimate]

    public init(
        bodyProseWordCount: Int,
        appendixProseWordCount: Int,
        abstractWordCount: Int,
        captionWordCount: Int,
        headerWordCount: Int,
        footnoteWordCount: Int,
        totalCountedWords: Int,
        characterCountWithSpaces: Int,
        characterCountWithoutSpaces: Int,
        paragraphCount: Int,
        inlineEquationCount: Int,
        displayEquationCount: Int,
        figureCount: Int,
        wideFigureCount: Int,
        tableCount: Int,
        wideTableCount: Int,
        algorithmCount: Int,
        theoremAndLemmaCount: Int,
        totalCitationOccurrences: Int,
        uniqueCitedKeysCount: Int,
        uniqueCitedKeys: [String],
        citationFrequencyByKey: [String: Int],
        citationDensityPerThousandWords: Double,
        estimatedReadingTimeMinutes: Double,
        estimatedSpeakingTimeMinutes: Double,
        readability: ReadabilityTelemetry,
        sectionBreakdowns: [SectionMetricsBreakdown],
        venueEstimates: [VenueBudgetEstimate]
    ) {
        self.bodyProseWordCount = bodyProseWordCount
        self.appendixProseWordCount = appendixProseWordCount
        self.abstractWordCount = abstractWordCount
        self.captionWordCount = captionWordCount
        self.headerWordCount = headerWordCount
        self.footnoteWordCount = footnoteWordCount
        self.totalCountedWords = totalCountedWords
        self.characterCountWithSpaces = characterCountWithSpaces
        self.characterCountWithoutSpaces = characterCountWithoutSpaces
        self.paragraphCount = paragraphCount
        self.inlineEquationCount = inlineEquationCount
        self.displayEquationCount = displayEquationCount
        self.figureCount = figureCount
        self.wideFigureCount = wideFigureCount
        self.tableCount = tableCount
        self.wideTableCount = wideTableCount
        self.algorithmCount = algorithmCount
        self.theoremAndLemmaCount = theoremAndLemmaCount
        self.totalCitationOccurrences = totalCitationOccurrences
        self.uniqueCitedKeysCount = uniqueCitedKeysCount
        self.uniqueCitedKeys = uniqueCitedKeys
        self.citationFrequencyByKey = citationFrequencyByKey
        self.citationDensityPerThousandWords = citationDensityPerThousandWords
        self.estimatedReadingTimeMinutes = estimatedReadingTimeMinutes
        self.estimatedSpeakingTimeMinutes = estimatedSpeakingTimeMinutes
        self.readability = readability
        self.sectionBreakdowns = sectionBreakdowns
        self.venueEstimates = venueEstimates
    }

    /// Looks up the computed budget estimate for a specific `AcademicVenuePreset`.
    public func estimate(for venue: AcademicVenuePreset) -> VenueBudgetEstimate? {
        venueEstimates.first { $0.venue == venue }
    }
}

// MARK: - Pure-Swift `texcount` & Academic Readability Engine

/// Computes `texcount`-accurate word/character telemetry, equation/figure/table/citation statistics,
/// Flesch-Kincaid academic readability grade, and venue page/word budget compliance in pure Swift 6.
public struct AcademicManuscriptMetricsAnalyzer: Sendable {
    private let lexer: IncrementalMarkupLexer
    private let parser: HandwrittenMarkupCSTParser
    private let includeResolver: MultiFileIncludeGraphResolver

    public init(
        lexer: IncrementalMarkupLexer = IncrementalMarkupLexer(configuration: .losslessCST),
        parser: HandwrittenMarkupCSTParser? = nil,
        includeResolver: MultiFileIncludeGraphResolver? = nil
    ) {
        self.lexer = lexer
        let resolvedParser = parser ?? HandwrittenMarkupCSTParser(lexer: lexer)
        self.parser = resolvedParser
        self.includeResolver = includeResolver ?? MultiFileIncludeGraphResolver(lexer: lexer, parser: resolvedParser)
    }

    // MARK: Public Analysis Entry Points

    /// Analyzes a single raw manuscript string in LaTeX, Typst, or Markdown format.
    public func analyze(
        source: String,
        filePath: String = "main.tex",
        format: ManuscriptFormat? = nil,
        venues: [AcademicVenuePreset] = AcademicVenuePreset.allCases
    ) -> ManuscriptMetricsReport {
        let resolvedFormat = format ?? ManuscriptFormat.detect(fromPath: filePath)
        let parseResult = parser.parse(source: source, filePath: filePath, format: resolvedFormat)
        return analyze(parseResult: parseResult, venues: venues)
    }

    /// Analyzes an already-parsed `MarkupParseResult`.
    public func analyze(
        parseResult: MarkupParseResult,
        venues: [AcademicVenuePreset] = AcademicVenuePreset.allCases
    ) -> ManuscriptMetricsReport {
        let outline = includeResolver.buildOutline(from: parseResult.root, parseResult: parseResult)
        return computeMetrics(
            orderedParseResults: [parseResult],
            mergedRootAST: parseResult.root,
            outline: outline,
            venues: venues
        )
    }

    /// Analyzes a multi-file `MergedManuscriptWorkspaceAST` across all reachable included files.
    public func analyze(
        workspace: MergedManuscriptWorkspaceAST,
        venues: [AcademicVenuePreset] = AcademicVenuePreset.allCases
    ) -> ManuscriptMetricsReport {
        let splicedSegments = buildSplicedTokenSegments(from: workspace)
        return computeMetrics(
            orderedParseResults: splicedSegments,
            mergedRootAST: workspace.mergedRootAST,
            outline: workspace.outline,
            venues: venues
        )
    }

    private func buildSplicedTokenSegments(from workspace: MergedManuscriptWorkspaceAST) -> [MarkupParseResult] {
        var edgesBySource: [String: [IncludeGraphEdge]] = [:]
        for edge in workspace.includeGraph.edges where !edge.isBibliographyResource && edge.targetExists {
            edgesBySource[edge.sourceFile, default: []].append(edge)
        }
        var segments: [MarkupParseResult] = []
        var activeStack: Set<String> = []

        func appendSegments(for filePath: String) {
            guard !activeStack.contains(filePath),
                  let pr = workspace.perFileParseResults[filePath] else { return }
            activeStack.insert(filePath)
            defer { activeStack.remove(filePath) }

            let fileEdges = (edgesBySource[filePath] ?? []).sorted {
                $0.directiveSpan.start.utf8Offset < $1.directiveSpan.start.utf8Offset
            }
            guard !fileEdges.isEmpty else {
                segments.append(pr)
                return
            }

            let allTokens = pr.tokens
            var tokenCursor = 0
            for edge in fileEdges {
                var sliceBefore: [MarkupToken] = []
                while tokenCursor < allTokens.count && allTokens[tokenCursor].kind != .eof {
                    if allTokens[tokenCursor].span.start.utf8Offset >= edge.directiveSpan.start.utf8Offset {
                        break
                    }
                    sliceBefore.append(allTokens[tokenCursor])
                    tokenCursor += 1
                }
                // Advance past the include directive tokens themselves
                while tokenCursor < allTokens.count && allTokens[tokenCursor].kind != .eof {
                    if allTokens[tokenCursor].span.start.utf8Offset >= edge.directiveSpan.end.utf8Offset {
                        break
                    }
                    tokenCursor += 1
                }
                if !sliceBefore.isEmpty {
                    segments.append(
                        MarkupParseResult(
                            root: pr.root,
                            issues: [],
                            tokens: sliceBefore,
                            format: pr.format,
                            filePath: pr.filePath
                        )
                    )
                }
                appendSegments(for: edge.resolvedTargetFile)
            }

            if tokenCursor < allTokens.count {
                let tailSlice = Array(allTokens[tokenCursor..<allTokens.count])
                if !tailSlice.isEmpty {
                    segments.append(
                        MarkupParseResult(
                            root: pr.root,
                            issues: [],
                            tokens: tailSlice,
                            format: pr.format,
                            filePath: pr.filePath
                        )
                    )
                }
            }
        }

        appendSegments(for: workspace.includeGraph.rootFilePath)
        return segments
    }

    /// Strips markup commands, preamble, comments, non-prose environments (`tikzpicture`, `lstlisting`, `tabular`),
    /// math formulas, and citations from `source`, returning clean prose text suitable for readability & NLP auditing.
    public func stripToCleanProse(
        source: String,
        format: ManuscriptFormat
    ) -> String {
        let tokens = lexer.tokenize(source: source, format: format, filePath: "<prose-strip>")
        var bucket = TeXCountTokenAccumulator()
        switch format {
        case .latex:
            accumulateLaTeXTokenBuckets(tokens: tokens, isRootDocument: true, inAppendixInitially: false, into: &bucket)
        case .typst:
            accumulateTypstTokenBuckets(tokens: tokens, inAppendixInitially: false, into: &bucket)
        case .markdown:
            accumulateMarkdownTokenBuckets(tokens: tokens, inAppendixInitially: false, into: &bucket)
        }
        let allProse = (bucket.bodyProseFragments + bucket.appendixProseFragments).joined(separator: " ")
        return Self.collapseSpaces(allProse)
    }

    // MARK: - Core Multi-Pass Telemetry Pipeline

    private func computeMetrics(
        orderedParseResults: [MarkupParseResult],
        mergedRootAST: MarkupASTNode,
        outline: [DocumentOutlineEntry],
        venues: [AcademicVenuePreset]
    ) -> ManuscriptMetricsReport {
        // 1. Run token-level `texcount` state machine across all files in reading order
        //    so preamble, `\textbf{...}`, `\textcolor{red}{prose}`, `\caption{...}`, `\footnote{...}`,
        //    `tikzpicture`, `lstlisting`, `tabular`, math, and `\appendix` transitions are exact!
        var bucket = TeXCountTokenAccumulator()
        for (idx, pr) in orderedParseResults.enumerated() {
            let isRoot = (idx == 0)
            switch pr.format {
            case .latex:
                accumulateLaTeXTokenBuckets(
                    tokens: pr.tokens,
                    isRootDocument: isRoot,
                    inAppendixInitially: bucket.enteredAppendix,
                    into: &bucket
                )
            case .typst:
                accumulateTypstTokenBuckets(
                    tokens: pr.tokens,
                    inAppendixInitially: bucket.enteredAppendix,
                    into: &bucket
                )
            case .markdown:
                accumulateMarkdownTokenBuckets(
                    tokens: pr.tokens,
                    inAppendixInitially: bucket.enteredAppendix,
                    into: &bucket
                )
            }
        }

        let cleanBodyProse = Self.collapseSpaces(bucket.bodyProseFragments.joined(separator: " "))
        let cleanAppendixProse = Self.collapseSpaces(bucket.appendixProseFragments.joined(separator: " "))
        let cleanAbstractProse = Self.collapseSpaces(bucket.abstractFragments.joined(separator: " "))
        let cleanCaptionProse = Self.collapseSpaces(bucket.captionFragments.joined(separator: " "))
        let cleanHeaderProse = Self.collapseSpaces(bucket.headerFragments.joined(separator: " "))
        let cleanFootnoteProse = Self.collapseSpaces(bucket.footnoteFragments.joined(separator: " "))

        var bodyWords = Self.extractLexicalWords(from: cleanBodyProse)
        var abstractWords = Self.extractLexicalWords(from: cleanAbstractProse)

        // Fallback for Typst / Markdown where Abstract is written as a level-1/2 section `# Abstract` or `= Abstract`:
        if abstractWords.isEmpty {
            if let abstractSec = mergedRootAST.allSections.first(where: {
                if case .section(_, let title, _) = $0.kind {
                    return title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "abstract"
                }
                return false
            }) {
                let secProse = collectParagraphText(in: abstractSec)
                let extractedAbs = Self.extractLexicalWords(from: secProse)
                if !extractedAbs.isEmpty {
                    abstractWords = extractedAbs
                    if bodyWords.count >= extractedAbs.count {
                        bodyWords.removeFirst(min(bodyWords.count, extractedAbs.count))
                    }
                }
            }
        }

        let appendixWords = Self.extractLexicalWords(from: cleanAppendixProse)
        let captionWords = Self.extractLexicalWords(from: cleanCaptionProse)
        let headerWords = Self.extractLexicalWords(from: cleanHeaderProse)
        let footnoteWords = Self.extractLexicalWords(from: cleanFootnoteProse)

        let bodyWordCount = bodyWords.count
        let appendixWordCount = appendixWords.count
        let abstractWordCount = abstractWords.count
        let captionWordCount = captionWords.count
        let headerWordCount = headerWords.count
        let footnoteWordCount = footnoteWords.count
        let totalWords = bodyWordCount + appendixWordCount + abstractWordCount + captionWordCount + headerWordCount + footnoteWordCount

        // Character counts over clean manuscript prose (body + abstract + appendix).
        let combinedProseForChars = [cleanAbstractProse, cleanBodyProse, cleanAppendixProse]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let charWithSpaces = combinedProseForChars.count
        let charWithoutSpaces = combinedProseForChars.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count

        // 2. AST structural inventory (floats, equations, algorithms, theorems, paragraphs, citations)
        var astCounts = ASTStructuralInventory()
        walkASTInventory(node: mergedRootAST, insideDisplayMathEnv: false, inventory: &astCounts)

        let uniqueSortedKeys = astCounts.citationFrequency.keys.sorted()
        let proseDenominator = max(1, bodyWordCount + abstractWordCount + appendixWordCount)
        let citationDensity = (Double(astCounts.totalCitationOccurrences) / Double(proseDenominator)) * 1000.0

        // 3. Academic reading & speaking time estimation
        //    200 WPM deep academic prose + 0.35 min per display equation + 0.60 min per figure/table/algorithm
        let proseMinutes = Double(totalWords) / 200.0
        let equationMinutes = Double(astCounts.displayEquations) * 0.35 + Double(astCounts.inlineEquations) * 0.04
        let floatMinutes = Double(astCounts.figureCount + astCounts.tableCount + astCounts.algorithmCount) * 0.60
        let readingTimeMinutes = ((proseMinutes + equationMinutes + floatMinutes) * 100.0).rounded() / 100.0
        let speakingTimeMinutes = ((Double(bodyWordCount + abstractWordCount) / 130.0) * 100.0).rounded() / 100.0

        // 4. Flesch-Kincaid & academic readability over main prose (abstract + body + appendix)
        let readabilityCorpus = [cleanAbstractProse, cleanBodyProse, cleanAppendixProse]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let readability = computeReadability(fromCleanProse: readabilityCorpus)

        // 5. Per-section breakdowns aligned with `outline`
        let sectionBreakdowns = buildSectionBreakdowns(mergedRootAST: mergedRootAST, outline: outline)

        // 6. Calibrated venue budget estimation (using main-body words, captions, headers, equations, and main-body floats!)
        let venueEstimates = venues.map { venue in
            estimateVenueBudget(
                venue: venue,
                mainBodyProseWords: bodyWordCount,
                abstractWords: abstractWordCount,
                captionWords: captionWordCount,
                headerWords: headerWordCount,
                footnoteWords: footnoteWordCount,
                figureCount: astCounts.mainBodyFigures,
                wideFigureCount: astCounts.mainBodyWideFigures,
                tableCount: astCounts.mainBodyTables,
                wideTableCount: astCounts.mainBodyWideTables,
                algorithmCount: astCounts.mainBodyAlgorithms,
                displayEquationCount: astCounts.mainBodyDisplayEquations
            )
        }

        return ManuscriptMetricsReport(
            bodyProseWordCount: bodyWordCount,
            appendixProseWordCount: appendixWordCount,
            abstractWordCount: abstractWordCount,
            captionWordCount: captionWordCount,
            headerWordCount: headerWordCount,
            footnoteWordCount: footnoteWordCount,
            totalCountedWords: totalWords,
            characterCountWithSpaces: charWithSpaces,
            characterCountWithoutSpaces: charWithoutSpaces,
            paragraphCount: astCounts.paragraphCount,
            inlineEquationCount: astCounts.inlineEquations,
            displayEquationCount: astCounts.displayEquations,
            figureCount: astCounts.figureCount,
            wideFigureCount: astCounts.wideFigureCount,
            tableCount: astCounts.tableCount,
            wideTableCount: astCounts.wideTableCount,
            algorithmCount: astCounts.algorithmCount,
            theoremAndLemmaCount: astCounts.theoremAndLemmaCount,
            totalCitationOccurrences: astCounts.totalCitationOccurrences,
            uniqueCitedKeysCount: uniqueSortedKeys.count,
            uniqueCitedKeys: uniqueSortedKeys,
            citationFrequencyByKey: astCounts.citationFrequency,
            citationDensityPerThousandWords: (citationDensity * 100.0).rounded() / 100.0,
            estimatedReadingTimeMinutes: readingTimeMinutes,
            estimatedSpeakingTimeMinutes: speakingTimeMinutes,
            readability: readability,
            sectionBreakdowns: sectionBreakdowns,
            venueEstimates: venueEstimates
        )
    }

    private func collectParagraphText(in subtree: MarkupASTNode) -> String {
        var pieces: [String] = []
        for p in subtree.allParagraphs {
            if case .paragraph(let preview) = p.kind {
                pieces.append(preview)
            }
        }
        return pieces.joined(separator: " ")
    }

    // MARK: - Token-Level `texcount` State Machine (LaTeX, Typst, Markdown)

    private struct TeXCountTokenAccumulator {
        var bodyProseFragments: [String] = []
        var appendixProseFragments: [String] = []
        var abstractFragments: [String] = []
        var captionFragments: [String] = []
        var headerFragments: [String] = []
        var footnoteFragments: [String] = []
        var enteredAppendix: Bool = false
    }

    /// Environments whose body contents are excluded from prose word count (matching Perl `texcount` rules).
    private static let excludedLaTeXEnvironments: Set<String> = [
        "tikzpicture", "pgfpicture", "axis", "semilogyaxis", "loglogaxis",
        "lstlisting", "minted", "verbatim", "verbatim*", "Verbatim", "BVerbatim", "alltt",
        "comment", "filecontents", "filecontents*",
        "tabular", "tabular*", "tabularx", "tabulary", "longtable", "supertabular", "array",
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix", "cases",
        "equation", "equation*", "align", "align*", "gather", "gather*",
        "multline", "multline*", "flalign", "flalign*", "eqnarray", "eqnarray*",
        "math", "displaymath",
        "thebibliography", "algorithmic"
    ]

    /// Commands whose mandatory `{...}` arguments are metadata/keys/lengths (NOT prose words).
    private static let singleArgNonProseCommands: Set<String> = [
        "\\documentclass", "\\usepackage", "\\RequirePackage", "\\bibliographystyle",
        "\\bibliography", "\\addbibresource", "\\nobibliography",
        "\\input", "\\include", "\\includeonly", "\\subfile",
        "\\label", "\\linelabel",
        "\\ref", "\\eqref", "\\autoref", "\\cref", "\\Cref", "\\pageref", "\\nameref", "\\vref",
        "\\includegraphics", "\\graphicspath", "\\url", "\\nolinkurl", "\\path", "\\mintinline",
        "\\vspace", "\\vspace*", "\\hspace", "\\hspace*", "\\vskip", "\\hskip",
        "\\pagenumbering", "\\pagestyle", "\\thispagestyle", "\\color", "\\pagecolor",
        "\\counterwithin", "\\counterwithout", "\\usetikzlibrary", "\\tikzset", "\\hypersetup",
        "\\author", "\\affil", "\\affiliation", "\\email", "\\orcid", "\\date", "\\keywords"
    ]

    private static let twoArgNonProseCommands: Set<String> = [
        "\\setlength", "\\addtolength", "\\setcounter", "\\addtocounter",
        "\\definecolor", "\\import", "\\subimport"
    ]

    /// Commands where `{arg1}` is non-prose metadata (like URL or color) and `{arg2}` IS prose text!
    private static let skipFirstKeepSecondCommands: Set<String> = [
        "\\href", "\\textcolor", "\\colorbox", "\\foreignlanguage"
    ]

    private func accumulateLaTeXTokenBuckets(
        tokens: [MarkupToken],
        isRootDocument: Bool,
        inAppendixInitially: Bool,
        into acc: inout TeXCountTokenAccumulator
    ) {
        acc.enteredAppendix = inAppendixInitially

        // Check if `\begin{document}` exists in this file; if so, skip preamble before `\begin{document}`
        // (while still harvesting `\title{...}` into `headerFragments`!).
        let hasBeginDocument = isRootDocument && tokensContainBeginDocument(tokens)
        var inPreamble = hasBeginDocument

        var envStack: [String] = []
        var idx = 0
        let coreCount = (tokens.last?.kind == .eof) ? (tokens.count - 1) : tokens.count

        while idx < coreCount {
            let tok = tokens[idx]

            if tok.kind == .comment || tok.kind == .verbatim {
                idx += 1
                continue
            }

            if inPreamble {
                if tok.kind == .command && tok.lexeme == "\\title" {
                    idx += 1
                    skipOptionalBracketsAndSpaces(tokens: tokens, index: &idx, coreCount: coreCount)
                    if idx < coreCount && tokens[idx].kind == .leftBrace {
                        let headerText = extractCleanProseFromBraceGroup(tokens: tokens, index: &idx, coreCount: coreCount)
                        if !headerText.isEmpty {
                            acc.headerFragments.append(headerText)
                        }
                        continue
                    }
                }
                if tok.kind == .command && tok.lexeme == "\\begin" {
                    let nextIdx = idx + 1
                    if let (envName, afterBraceIdx) = readEnvironmentNameArg(tokens: tokens, fromIndex: nextIdx, coreCount: coreCount),
                       envName == "document" {
                        inPreamble = false
                        idx = afterBraceIdx
                        continue
                    }
                }
                idx += 1
                continue
            }

            // Inside excluded environment (`tikzpicture`, `lstlisting`, `tabular`, `equation`, etc.):
            // fast-forward until the matching `\end{...}`!
            if let activeExcluded = envStack.last, Self.excludedLaTeXEnvironments.contains(activeExcluded) {
                if tok.kind == .command && tok.lexeme == "\\begin" {
                    if let (nestedName, afterIdx) = readEnvironmentNameArg(tokens: tokens, fromIndex: idx + 1, coreCount: coreCount) {
                        envStack.append(nestedName)
                        idx = afterIdx
                        continue
                    }
                } else if tok.kind == .command && tok.lexeme == "\\end" {
                    if let (closingName, afterIdx) = readEnvironmentNameArg(tokens: tokens, fromIndex: idx + 1, coreCount: coreCount) {
                        if envStack.last == closingName {
                            _ = envStack.popLast()
                        } else if let pos = envStack.lastIndex(of: closingName) {
                            envStack.removeSubrange(pos..<envStack.count)
                        }
                        idx = afterIdx
                        continue
                    }
                }
                idx += 1
                continue
            }

            // Inline & display math delimiters (`$...$`, `$$...$$`, `\(...\)`, `\[...\]`) are skipped for prose words
            // (or optionally replaced by a single space so surrounding words don't fuse).
            if tok.kind == .mathInline || tok.kind == .mathDisplay {
                skipMathFormulaTokens(tokens: tokens, index: &idx, coreCount: coreCount)
                appendFragment(" ", envStack: envStack, into: &acc)
                continue
            }

            if tok.kind == .command {
                let cmd = tok.lexeme
                let role = LaTeXCommandRole.classify(cmd)

                if role == .appendixSwitch {
                    acc.enteredAppendix = true
                    idx += 1
                    continue
                }

                if cmd == "\\title" || role == .sectioning {
                    idx += 1
                    skipOptionalBracketsAndSpaces(tokens: tokens, index: &idx, coreCount: coreCount)
                    if idx < coreCount && tokens[idx].kind == .leftBrace {
                        let titleText = extractCleanProseFromBraceGroup(tokens: tokens, index: &idx, coreCount: coreCount)
                        if !titleText.isEmpty {
                            acc.headerFragments.append(titleText)
                        }
                        if titleText.lowercased().hasPrefix("appendix") {
                            acc.enteredAppendix = true
                        }
                    }
                    continue
                }

                if role == .captionCommand {
                    idx += 1
                    if cmd == "\\captionof" {
                        skipHorizontalSpaces(tokens: tokens, index: &idx, coreCount: coreCount)
                        if idx < coreCount && tokens[idx].kind == .leftBrace {
                            skipBalancedGroup(tokens: tokens, index: &idx, coreCount: coreCount, open: .leftBrace, close: .rightBrace)
                        }
                    }
                    skipOptionalBracketsAndSpaces(tokens: tokens, index: &idx, coreCount: coreCount)
                    if idx < coreCount && tokens[idx].kind == .leftBrace {
                        let capText = extractCleanProseFromBraceGroup(tokens: tokens, index: &idx, coreCount: coreCount)
                        if !capText.isEmpty {
                            acc.captionFragments.append(capText)
                        }
                    }
                    continue
                }

                if role == .footnoteCommand {
                    idx += 1
                    skipOptionalBracketsAndSpaces(tokens: tokens, index: &idx, coreCount: coreCount)
                    if idx < coreCount && tokens[idx].kind == .leftBrace {
                        let fnText = extractCleanProseFromBraceGroup(tokens: tokens, index: &idx, coreCount: coreCount)
                        if !fnText.isEmpty {
                            acc.footnoteFragments.append(fnText)
                        }
                    }
                    continue
                }

                if role == .environmentBegin {
                    if let (envName, afterIdx) = readEnvironmentNameArg(tokens: tokens, fromIndex: idx + 1, coreCount: coreCount) {
                        idx = afterIdx
                        if envName == "document" {
                            continue
                        }
                        if envName == "appendices" || envName == "appendix" {
                            acc.enteredAppendix = true
                        }
                        envStack.append(envName)
                        // Skip optional `[htbp]` placement argument on `figure`, `table`, `algorithm`, `theorem`
                        skipHorizontalSpaces(tokens: tokens, index: &idx, coreCount: coreCount)
                        if idx < coreCount && tokens[idx].kind == .leftBracket && envName != "theorem" && envName != "lemma" && envName != "definition" {
                            skipBalancedGroup(tokens: tokens, index: &idx, coreCount: coreCount, open: .leftBracket, close: .rightBracket)
                        }
                        continue
                    }
                }

                if role == .environmentEnd {
                    if let (closingName, afterIdx) = readEnvironmentNameArg(tokens: tokens, fromIndex: idx + 1, coreCount: coreCount) {
                        idx = afterIdx
                        if closingName == "document" {
                            break
                        }
                        if envStack.last == closingName {
                            _ = envStack.popLast()
                        } else if let pos = envStack.lastIndex(of: closingName) {
                            envStack.removeSubrange(pos..<envStack.count)
                        }
                        continue
                    }
                }

                if role == .citation || role == .crossReference || role == .labelDeclaration
                    || role == .fileInclude || role == .bibliographyResource {
                    idx += 1
                    // Consume all `[...]` and `{...}` arguments attached to the citation/ref/include!
                    while idx < coreCount {
                        let saved = idx
                        skipHorizontalSpaces(tokens: tokens, index: &idx, coreCount: coreCount)
                        if idx < coreCount && tokens[idx].kind == .leftBracket {
                            skipBalancedGroup(tokens: tokens, index: &idx, coreCount: coreCount, open: .leftBracket, close: .rightBracket)
                        } else if idx < coreCount && tokens[idx].kind == .leftBrace {
                            skipBalancedGroup(tokens: tokens, index: &idx, coreCount: coreCount, open: .leftBrace, close: .rightBrace)
                            if !cmd.hasSuffix("s") {
                                break
                            }
                        } else {
                            idx = saved
                            break
                        }
                    }
                    continue
                }

                if role == .macroDefinition {
                    idx += 1
                    skipMacroDefinitionTokens(cmd: cmd, tokens: tokens, index: &idx, coreCount: coreCount)
                    continue
                }

                if Self.singleArgNonProseCommands.contains(cmd) {
                    idx += 1
                    skipOptionalBracketsAndSpaces(tokens: tokens, index: &idx, coreCount: coreCount)
                    if idx < coreCount && tokens[idx].kind == .leftBrace {
                        skipBalancedGroup(tokens: tokens, index: &idx, coreCount: coreCount, open: .leftBrace, close: .rightBrace)
                    }
                    continue
                }

                if Self.twoArgNonProseCommands.contains(cmd) {
                    idx += 1
                    for _ in 0..<2 {
                        skipOptionalBracketsAndSpaces(tokens: tokens, index: &idx, coreCount: coreCount)
                        if idx < coreCount && tokens[idx].kind == .leftBrace {
                            skipBalancedGroup(tokens: tokens, index: &idx, coreCount: coreCount, open: .leftBrace, close: .rightBrace)
                        }
                    }
                    continue
                }

                if Self.skipFirstKeepSecondCommands.contains(cmd) {
                    idx += 1
                    skipOptionalBracketsAndSpaces(tokens: tokens, index: &idx, coreCount: coreCount)
                    if idx < coreCount && tokens[idx].kind == .leftBrace {
                        skipBalancedGroup(tokens: tokens, index: &idx, coreCount: coreCount, open: .leftBrace, close: .rightBrace)
                    }
                    // Leave the second `{anchor prose}` group on the stream so its inner prose words ARE counted!
                    continue
                }

                // Control symbols (`\%`, `\&`, `\$`) or formatting commands (`\textbf`, `\emph`, `\item`):
                // skip the command token itself while keeping any prose inside `{...}`!
                idx += 1
                continue
            }

            if tok.kind == .leftBrace || tok.kind == .rightBrace {
                idx += 1
                continue
            }

            if tok.kind == .whitespace {
                appendFragment(" ", envStack: envStack, into: &acc)
                idx += 1
                continue
            }

            if tok.lexeme == "~" {
                appendFragment(" ", envStack: envStack, into: &acc)
                idx += 1
                continue
            }

            appendFragment(tok.lexeme, envStack: envStack, into: &acc)
            idx += 1
        }
    }

    private func appendFragment(
        _ fragment: String,
        envStack: [String],
        into acc: inout TeXCountTokenAccumulator
    ) {
        if envStack.contains("abstract") {
            acc.abstractFragments.append(fragment)
        } else if acc.enteredAppendix {
            acc.appendixProseFragments.append(fragment)
        } else {
            acc.bodyProseFragments.append(fragment)
        }
    }

    private func tokensContainBeginDocument(_ tokens: [MarkupToken]) -> Bool {
        var idx = 0
        let count = tokens.count
        while idx < count {
            if tokens[idx].kind == .command && tokens[idx].lexeme == "\\begin" {
                if let (name, _) = readEnvironmentNameArg(tokens: tokens, fromIndex: idx + 1, coreCount: count),
                   name == "document" {
                    return true
                }
            }
            idx += 1
        }
        return false
    }

    private func readEnvironmentNameArg(
        tokens: [MarkupToken],
        fromIndex startIdx: Int,
        coreCount: Int
    ) -> (name: String, nextIndex: Int)? {
        var idx = startIdx
        skipHorizontalSpaces(tokens: tokens, index: &idx, coreCount: coreCount)
        guard idx < coreCount, tokens[idx].kind == .leftBrace else { return nil }
        idx += 1
        var name = ""
        while idx < coreCount && tokens[idx].kind != .rightBrace {
            if tokens[idx].kind == .whitespace && (tokens[idx].lexeme.contains("\n") || tokens[idx].lexeme.contains("\r")) {
                return nil
            }
            name.append(tokens[idx].lexeme)
            idx += 1
        }
        guard idx < coreCount, tokens[idx].kind == .rightBrace else { return nil }
        idx += 1
        return (name.trimmingCharacters(in: .whitespaces), idx)
    }

    private func skipHorizontalSpaces(tokens: [MarkupToken], index: inout Int, coreCount: Int) {
        while index < coreCount {
            let t = tokens[index]
            if t.kind == .comment {
                index += 1
            } else if t.kind == .whitespace && !t.lexeme.contains("\n") && !t.lexeme.contains("\r") {
                index += 1
            } else {
                break
            }
        }
    }

    private func skipOptionalBracketsAndSpaces(tokens: [MarkupToken], index: inout Int, coreCount: Int) {
        skipHorizontalSpaces(tokens: tokens, index: &index, coreCount: coreCount)
        while index < coreCount && tokens[index].kind == .leftBracket {
            skipBalancedGroup(tokens: tokens, index: &index, coreCount: coreCount, open: .leftBracket, close: .rightBracket)
            skipHorizontalSpaces(tokens: tokens, index: &index, coreCount: coreCount)
        }
    }

    private func skipBalancedGroup(
        tokens: [MarkupToken],
        index: inout Int,
        coreCount: Int,
        open: MarkupTokenKind,
        close: MarkupTokenKind
    ) {
        guard index < coreCount && tokens[index].kind == open else { return }
        index += 1
        var depth = 1
        while index < coreCount && depth > 0 {
            let k = tokens[index].kind
            if k == open { depth += 1 }
            else if k == close { depth -= 1 }
            index += 1
        }
    }

    private func extractCleanProseFromBraceGroup(
        tokens: [MarkupToken],
        index: inout Int,
        coreCount: Int
    ) -> String {
        guard index < coreCount && tokens[index].kind == .leftBrace else { return "" }
        index += 1
        var depth = 1
        var parts: [String] = []

        while index < coreCount && depth > 0 {
            let t = tokens[index]
            if t.kind == .leftBrace {
                depth += 1
                index += 1
                continue
            }
            if t.kind == .rightBrace {
                depth -= 1
                index += 1
                continue
            }
            if t.kind == .comment || t.kind == .verbatim {
                index += 1
                continue
            }
            if t.kind == .mathInline || t.kind == .mathDisplay {
                skipMathFormulaTokens(tokens: tokens, index: &index, coreCount: coreCount)
                parts.append(" ")
                continue
            }
            if t.kind == .command {
                let role = LaTeXCommandRole.classify(t.lexeme)
                if role == .citation || role == .crossReference || role == .labelDeclaration {
                    index += 1
                    skipOptionalBracketsAndSpaces(tokens: tokens, index: &index, coreCount: coreCount)
                    if index < coreCount && tokens[index].kind == .leftBrace {
                        skipBalancedGroup(tokens: tokens, index: &index, coreCount: coreCount, open: .leftBrace, close: .rightBrace)
                    }
                    continue
                }
                index += 1
                continue
            }
            parts.append(t.lexeme == "~" ? " " : t.lexeme)
            index += 1
        }
        return Self.collapseSpaces(parts.joined())
    }

    private func skipMathFormulaTokens(
        tokens: [MarkupToken],
        index: inout Int,
        coreCount: Int
    ) {
        let openTok = tokens[index]
        index += 1
        let expectedClose: String
        switch openTok.lexeme {
        case "\\[": expectedClose = "\\]"
        case "\\(": expectedClose = "\\)"
        case "$$": expectedClose = "$$"
        default: expectedClose = "$"
        }
        let isInline = (openTok.kind == .mathInline)
        while index < coreCount {
            let t = tokens[index]
            if (t.kind == .mathInline || t.kind == .mathDisplay) && t.lexeme == expectedClose {
                index += 1
                break
            }
            if isInline && t.kind == .whitespace && (t.lexeme.contains("\n\n") || (index + 1 < coreCount && tokens[index + 1].kind == .whitespace && tokens[index + 1].lexeme.contains("\n") && t.lexeme.contains("\n"))) {
                break
            }
            if t.kind == .command && LaTeXCommandRole.classify(t.lexeme) == .sectioning {
                break
            }
            index += 1
        }
    }

    private func skipMacroDefinitionTokens(
        cmd: String,
        tokens: [MarkupToken],
        index: inout Int,
        coreCount: Int
    ) {
        if cmd == "\\def" || cmd == "\\gdef" || cmd == "\\edef" || cmd == "\\xdef" {
            while index < coreCount && tokens[index].kind != .leftBrace {
                if tokens[index].kind == .whitespace && (tokens[index].lexeme.contains("\n") || tokens[index].lexeme.contains("\r")) {
                    return
                }
                index += 1
            }
            if index < coreCount && tokens[index].kind == .leftBrace {
                skipBalancedGroup(tokens: tokens, index: &index, coreCount: coreCount, open: .leftBrace, close: .rightBrace)
            }
            return
        }
        skipHorizontalSpaces(tokens: tokens, index: &index, coreCount: coreCount)
        if index < coreCount && tokens[index].kind == .leftBrace {
            skipBalancedGroup(tokens: tokens, index: &index, coreCount: coreCount, open: .leftBrace, close: .rightBrace)
        } else if index < coreCount && tokens[index].kind == .command {
            index += 1
        }
        skipOptionalBracketsAndSpaces(tokens: tokens, index: &index, coreCount: coreCount)
        if index < coreCount && tokens[index].kind == .leftBrace {
            skipBalancedGroup(tokens: tokens, index: &index, coreCount: coreCount, open: .leftBrace, close: .rightBrace)
        }
        skipHorizontalSpaces(tokens: tokens, index: &index, coreCount: coreCount)
        if index < coreCount && tokens[index].kind == .leftBrace {
            skipBalancedGroup(tokens: tokens, index: &index, coreCount: coreCount, open: .leftBrace, close: .rightBrace)
        }
    }

    // MARK: Typst Token Bucket Accumulator

    private func accumulateTypstTokenBuckets(
        tokens: [MarkupToken],
        inAppendixInitially: Bool,
        into acc: inout TeXCountTokenAccumulator
    ) {
        acc.enteredAppendix = inAppendixInitially
        var idx = 0
        let coreCount = (tokens.last?.kind == .eof) ? (tokens.count - 1) : tokens.count

        while idx < coreCount {
            let t = tokens[idx]

            if t.kind == .comment {
                idx += 1
                continue
            }

            // Typst heading `= Section Title <sec:id>`
            if t.kind == .headingMarker {
                idx += 1
                var headingParts: [String] = []
                while idx < coreCount {
                    let ht = tokens[idx]
                    if ht.kind == .whitespace && (ht.lexeme.contains("\n") || ht.lexeme.contains("\r")) {
                        break
                    }
                    if ht.kind == .identifier && ht.lexeme.hasPrefix("<") && ht.lexeme.hasSuffix(">") {
                        idx += 1
                        continue
                    }
                    if ht.kind != .comment {
                        headingParts.append(ht.lexeme)
                    }
                    idx += 1
                }
                let heading = Self.collapseSpaces(headingParts.joined())
                if !heading.isEmpty {
                    acc.headerFragments.append(heading)
                    if heading.lowercased().hasPrefix("appendix") {
                        acc.enteredAppendix = true
                    }
                }
                continue
            }

            // Typst `<label>` declaration
            if t.kind == .identifier && t.lexeme.hasPrefix("<") && t.lexeme.hasSuffix(">") {
                idx += 1
                continue
            }

            // Typst `$...$` math
            if t.kind == .mathInline {
                idx += 1
                while idx < coreCount && tokens[idx].kind != .mathInline {
                    idx += 1
                }
                if idx < coreCount { idx += 1 }
                appendFragment(" ", envStack: [], into: &acc)
                continue
            }

            // Typst `#set`, `#show`, `#let`, `#import`, `#include`, `#cite`, `#figure`, `@cite`
            if t.kind == .typstHashKeyword {
                let role = TypstDirectiveRole.classify(t.lexeme)
                idx += 1
                switch role {
                case .shorthandReference:
                    if idx < coreCount && tokens[idx].kind == .leftBracket {
                        skipBalancedGroup(tokens: tokens, index: &idx, coreCount: coreCount, open: .leftBracket, close: .rightBracket)
                    }
                case .figureCall, .tableCall:
                    // Extract `caption: [...]` inside `#figure(...)` into `captionFragments`!
                    if idx < coreCount && tokens[idx].kind == .punctuation && tokens[idx].lexeme == "(" {
                        let rawCall = consumeParenthesizedTypstText(tokens: tokens, index: &idx, coreCount: coreCount)
                        if let capRange = rawCall.range(of: "caption:") {
                            let after = rawCall[capRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                            if after.hasPrefix("["), let close = after.lastIndex(of: "]") {
                                let capText = Self.collapseSpaces(String(after[after.index(after: after.startIndex)..<close]))
                                if !capText.isEmpty {
                                    acc.captionFragments.append(capText)
                                }
                            }
                        }
                    }
                case .footnoteCommandEquivalent:
                    break
                default:
                    if t.lexeme == "#footnote", idx < coreCount, tokens[idx].kind == .leftBracket {
                        let fn = extractTypstBracketText(tokens: tokens, index: &idx, coreCount: coreCount)
                        if !fn.isEmpty {
                            acc.footnoteFragments.append(fn)
                        }
                    } else if idx < coreCount && tokens[idx].kind == .punctuation && tokens[idx].lexeme == "(" {
                        _ = consumeParenthesizedTypstText(tokens: tokens, index: &idx, coreCount: coreCount)
                    } else if role == .setRule || role == .showRule || role == .letBinding || role == .importModule || role == .includeFile {
                        while idx < coreCount {
                            if tokens[idx].kind == .whitespace && (tokens[idx].lexeme.contains("\n") || tokens[idx].lexeme.contains("\r")) {
                                break
                            }
                            idx += 1
                        }
                    }
                }
                continue
            }

            appendFragment(t.lexeme, envStack: [], into: &acc)
            idx += 1
        }
    }

    private func consumeParenthesizedTypstText(tokens: [MarkupToken], index: inout Int, coreCount: Int) -> String {
        index += 1 // '('
        var depth = 1
        var parts: [String] = []
        while index < coreCount && depth > 0 {
            let t = tokens[index]
            if t.kind == .punctuation && t.lexeme == "(" { depth += 1 }
            else if t.kind == .punctuation && t.lexeme == ")" { depth -= 1 }
            if depth > 0 && t.kind != .comment {
                parts.append(t.lexeme)
            }
            index += 1
        }
        return parts.joined()
    }

    private func extractTypstBracketText(tokens: [MarkupToken], index: inout Int, coreCount: Int) -> String {
        index += 1 // '['
        var depth = 1
        var parts: [String] = []
        while index < coreCount && depth > 0 {
            let t = tokens[index]
            if t.kind == .leftBracket { depth += 1 }
            else if t.kind == .rightBracket { depth -= 1 }
            if depth > 0 && t.kind != .comment {
                parts.append(t.lexeme)
            }
            index += 1
        }
        return Self.collapseSpaces(parts.joined())
    }

    // MARK: Markdown Token Bucket Accumulator

    private func accumulateMarkdownTokenBuckets(
        tokens: [MarkupToken],
        inAppendixInitially: Bool,
        into acc: inout TeXCountTokenAccumulator
    ) {
        acc.enteredAppendix = inAppendixInitially
        var idx = 0
        let coreCount = (tokens.last?.kind == .eof) ? (tokens.count - 1) : tokens.count

        // Skip YAML frontmatter `---\n ... \n---` at line 1 if present.
        if coreCount >= 2 && tokens[0].span.start.line == 1 && tokens[0].lexeme == "---" {
            idx = 1
            while idx < coreCount {
                if tokens[idx].span.start.column == 1 && tokens[idx].lexeme == "---" {
                    idx += 1
                    break
                }
                idx += 1
            }
        }

        while idx < coreCount {
            let t = tokens[idx]

            if t.kind == .comment {
                idx += 1
                continue
            }

            // Skip fenced code blocks ```` ``` ````
            if t.lexeme == "`" && idx + 2 < coreCount && tokens[idx + 1].lexeme == "`" && tokens[idx + 2].lexeme == "`" {
                idx += 3
                while idx + 2 < coreCount {
                    if tokens[idx].lexeme == "`" && tokens[idx + 1].lexeme == "`" && tokens[idx + 2].lexeme == "`" {
                        idx += 3
                        break
                    }
                    idx += 1
                }
                continue
            }

            if t.kind == .headingMarker {
                idx += 1
                var headingParts: [String] = []
                while idx < coreCount {
                    let ht = tokens[idx]
                    if ht.kind == .whitespace && (ht.lexeme.contains("\n") || ht.lexeme.contains("\r")) {
                        break
                    }
                    if ht.kind == .leftBrace {
                        skipBalancedGroup(tokens: tokens, index: &idx, coreCount: coreCount, open: .leftBrace, close: .rightBrace)
                        continue
                    }
                    headingParts.append(ht.lexeme)
                    idx += 1
                }
                let heading = Self.collapseSpaces(headingParts.joined())
                if !heading.isEmpty {
                    acc.headerFragments.append(heading)
                    if heading.lowercased().hasPrefix("appendix") {
                        acc.enteredAppendix = true
                    }
                }
                continue
            }

            // Pandoc bracketed citation `[@vaswani2017; @dao2022]`
            if t.kind == .leftBracket {
                var probe = idx + 1
                var hasCite = false
                while probe < coreCount && tokens[probe].kind != .rightBracket {
                    if tokens[probe].kind == .whitespace && tokens[probe].lexeme.contains("\n") {
                        break
                    }
                    if tokens[probe].kind == .typstHashKeyword && tokens[probe].lexeme.hasPrefix("@") {
                        hasCite = true
                    }
                    probe += 1
                }
                if hasCite && probe < coreCount && tokens[probe].kind == .rightBracket {
                    idx = probe + 1
                    continue
                }
            }

            if t.kind == .typstHashKeyword && t.lexeme.hasPrefix("@") {
                idx += 1
                continue
            }

            if t.kind == .mathInline || t.kind == .mathDisplay {
                skipMathFormulaTokens(tokens: tokens, index: &idx, coreCount: coreCount)
                appendFragment(" ", envStack: [], into: &acc)
                continue
            }

            appendFragment(t.lexeme, envStack: [], into: &acc)
            idx += 1
        }
    }

    // MARK: - AST Structural Inventory Walk

    private struct ASTStructuralInventory {
        var paragraphCount = 0
        var inlineEquations = 0
        var displayEquations = 0
        var mainBodyDisplayEquations = 0

        var figureCount = 0
        var wideFigureCount = 0
        var mainBodyFigures = 0
        var mainBodyWideFigures = 0

        var tableCount = 0
        var wideTableCount = 0
        var mainBodyTables = 0
        var mainBodyWideTables = 0

        var algorithmCount = 0
        var mainBodyAlgorithms = 0
        var theoremAndLemmaCount = 0

        var totalCitationOccurrences = 0
        var citationFrequency: [String: Int] = [:]
        var inAppendixSection = false
    }

    private static let displayMathEnvSet: Set<String> = [
        "equation", "equation*", "align", "align*", "gather", "gather*",
        "multline", "multline*", "flalign", "flalign*", "eqnarray", "eqnarray*", "displaymath"
    ]

    private static let theoremEnvSet: Set<String> = [
        "theorem", "theorem*", "lemma", "lemma*", "proposition", "proposition*",
        "corollary", "corollary*", "definition", "definition*", "assumption", "remark"
    ]

    private func walkASTInventory(
        node: MarkupASTNode,
        insideDisplayMathEnv: Bool,
        inventory: inout ASTStructuralInventory
    ) {
        var nextInsideDisplayMathEnv = insideDisplayMathEnv

        switch node.kind {
        case .section(let level, let title, let label):
            if level <= 1 {
                let lower = title.lowercased()
                let lblLower = label?.lowercased() ?? ""
                if lower.hasPrefix("appendix") || lblLower.hasPrefix("app:") || lblLower.hasPrefix("appendix:") {
                    inventory.inAppendixSection = true
                }
            }

        case .paragraph:
            inventory.paragraphCount += 1

        case .environment(let name, _, _):
            switch name {
            case "figure", "wrapfigure":
                inventory.figureCount += 1
                if !inventory.inAppendixSection { inventory.mainBodyFigures += 1 }
            case "figure*":
                inventory.figureCount += 1
                inventory.wideFigureCount += 1
                if !inventory.inAppendixSection {
                    inventory.mainBodyFigures += 1
                    inventory.mainBodyWideFigures += 1
                }
            case "table", "longtable", "threeparttable":
                inventory.tableCount += 1
                if !inventory.inAppendixSection { inventory.mainBodyTables += 1 }
            case "table*":
                inventory.tableCount += 1
                inventory.wideTableCount += 1
                if !inventory.inAppendixSection {
                    inventory.mainBodyTables += 1
                    inventory.mainBodyWideTables += 1
                }
            case "algorithm", "algorithm*", "algorithm2e":
                inventory.algorithmCount += 1
                if !inventory.inAppendixSection { inventory.mainBodyAlgorithms += 1 }
            default:
                if Self.theoremEnvSet.contains(name) {
                    inventory.theoremAndLemmaCount += 1
                }
                if Self.displayMathEnvSet.contains(name) {
                    inventory.displayEquations += 1
                    if !inventory.inAppendixSection {
                        inventory.mainBodyDisplayEquations += 1
                    }
                    nextInsideDisplayMathEnv = true
                }
            }

        case .mathExpression(let isDisplay, _, _):
            if isDisplay {
                // Avoid double-counting the inner `.mathExpression` attached directly to an `equation`/`align` environment!
                if !insideDisplayMathEnv {
                    inventory.displayEquations += 1
                    if !inventory.inAppendixSection {
                        inventory.mainBodyDisplayEquations += 1
                    }
                }
            } else {
                inventory.inlineEquations += 1
            }

        case .citation(_, let citeKeys, _, _):
            for key in citeKeys where key != "*" && !key.isEmpty {
                inventory.totalCitationOccurrences += 1
                inventory.citationFrequency[key, default: 0] += 1
            }

        default:
            break
        }

        for child in node.children {
            walkASTInventory(node: child, insideDisplayMathEnv: nextInsideDisplayMathEnv, inventory: &inventory)
        }
    }

    // MARK: - Section Breakdown Aggregation

    private func buildSectionBreakdowns(
        mergedRootAST: MarkupASTNode,
        outline: [DocumentOutlineEntry]
    ) -> [SectionMetricsBreakdown] {
        // Index outline entries by `(filePath, line, title)` to pair with AST section nodes.
        var outlineLookup: [String: DocumentOutlineEntry] = [:]
        for entry in outline {
            outlineLookup["\(entry.filePath):\(entry.line):\(entry.title)"] = entry
        }

        var breakdowns: [SectionMetricsBreakdown] = []

        func visit(_ node: MarkupASTNode) {
            if case .section(let level, let title, _) = node.kind {
                let lookupKey = "\(node.span.filePath):\(node.span.start.line):\(title)"
                let matchedOutline = outlineLookup[lookupKey]
                let prefix = matchedOutline?.numberPrefix ?? ""
                let isApp = prefix.hasPrefix("Appendix") || (prefix.first?.isLetter == true && prefix.contains("."))

                var directWords = 0
                for child in node.children {
                    if case .paragraph(let preview) = child.kind {
                        directWords += MultiFileIncludeGraphResolver.countWords(in: preview)
                    } else if case .environment(let name, _, _) = child.kind, !Self.excludedLaTeXEnvironments.contains(name) {
                        for p in child.allParagraphs {
                            if case .paragraph(let preview) = p.kind {
                                directWords += MultiFileIncludeGraphResolver.countWords(in: preview)
                            }
                        }
                    }
                }

                let subtreeWords = matchedOutline?.wordCountInSection ?? directWords
                let citesInSubtree = node.allCitations.reduce(0) { acc, cNode in
                    if case .citation(_, let keys, _, _) = cNode.kind {
                        return acc + keys.filter { $0 != "*" && !$0.isEmpty }.count
                    }
                    return acc
                }

                var eqs = 0
                var floats = 0
                for env in node.allEnvironments {
                    if case .environment(let name, _, _) = env.kind {
                        if Self.displayMathEnvSet.contains(name) {
                            eqs += 1
                        } else if name.hasPrefix("figure") || name.hasPrefix("table") || name.hasPrefix("algorithm") {
                            floats += 1
                        }
                    }
                }
                for m in node.allMathExpressions {
                    if case .mathExpression(let isDisp, _, _) = m.kind, !isDisp {
                        eqs += 1
                    }
                }

                breakdowns.append(
                    SectionMetricsBreakdown(
                        numberPrefix: prefix,
                        title: title,
                        level: level,
                        isAppendix: isApp,
                        filePath: node.span.filePath,
                        line: node.span.start.line,
                        directBodyWordCount: directWords,
                        subtreeBodyWordCount: subtreeWords,
                        citationOccurrencesInSubtree: citesInSubtree,
                        equationsInSubtree: eqs,
                        floatsInSubtree: floats
                    )
                )
            }
            for child in node.children {
                visit(child)
            }
        }

        visit(mergedRootAST)
        return breakdowns
    }

    // MARK: - Academic Readability Scoring (Flesch-Kincaid, Gunning Fog, Coleman-Liau)

    private static let nonTerminalAcademicAbbreviations: Set<String> = [
        "al", "fig", "figs", "eq", "eqs", "sec", "secs", "tab", "tabs", "tbl",
        "thm", "lem", "prop", "cor", "def", "alg", "app", "ch", "chap",
        "et", "cf", "vs", "viz", "approx", "ca", "dr", "prof", "mr", "mrs", "ms",
        "no", "nos", "vol", "vols", "pp", "ed", "eds", "inc", "ltd", "univ", "dept",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "e.g", "i.e", "w.r.t", "s.t", "a.k.a"
    ]

    public func computeReadability(fromCleanProse prose: String) -> ReadabilityTelemetry {
        let words = Self.extractLexicalWords(from: prose)
        guard !words.isEmpty else {
            return .empty
        }

        let sentenceCount = max(1, Self.countAcademicSentences(in: prose))
        var totalSyllables = 0
        var complexWords = 0
        var totalLettersAndDigits = 0
        var uniqueLowercased = Set<String>()

        for word in words {
            let lower = word.lowercased()
            uniqueLowercased.insert(lower)
            totalLettersAndDigits += word.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count

            let syl = Self.countEnglishSyllables(in: lower)
            totalSyllables += syl
            // Gunning Fog defines complex words as >= 3 syllables excluding common morphological suffixes `-es`, `-ed`, `-ing` when base is 2 syllables.
            if syl >= 3 {
                complexWords += 1
            }
        }

        let wCount = Double(words.count)
        let sCount = Double(sentenceCount)
        let avgWordsPerSentence = wCount / sCount
        let avgSyllablesPerWord = Double(totalSyllables) / wCount

        let fleschEase = 206.835 - (1.015 * avgWordsPerSentence) - (84.6 * avgSyllablesPerWord)
        let fkGrade = max(0.0, (0.39 * avgWordsPerSentence) + (11.8 * avgSyllablesPerWord) - 15.59)
        let gunningFog = 0.4 * (avgWordsPerSentence + 100.0 * (Double(complexWords) / wCount))

        // Coleman-Liau: 0.0588 * L - 0.296 * S - 15.8 (L = letters per 100 words, S = sentences per 100 words)
        let lettersPer100 = (Double(totalLettersAndDigits) / wCount) * 100.0
        let sentencesPer100 = (sCount / wCount) * 100.0
        let colemanLiau = max(0.0, 0.0588 * lettersPer100 - 0.296 * sentencesPer100 - 15.8)

        let ttr = Double(uniqueLowercased.count) / wCount

        let registerDescription: String
        switch fkGrade {
        case ..<10.0:
            registerDescription = "Accessible General / Broad-Audience Register"
        case 10.0..<13.0:
            registerDescription = "Undergraduate / Interdisciplinary Science Register"
        case 13.0..<16.5:
            registerDescription = "Standard Peer-Reviewed Academic Register (Optimal Clarity)"
        case 16.5..<19.5:
            registerDescription = "Dense Graduate / Specialist Technical Monograph Register"
        default:
            registerDescription = "Highly Turgid Prose — Consider Splitting Long Multi-Clause Sentences"
        }

        return ReadabilityTelemetry(
            sentenceCount: sentenceCount,
            wordCountAnalyzed: words.count,
            syllableCount: totalSyllables,
            complexPolysyllabicWordCount: complexWords,
            averageWordsPerSentence: Self.round2(avgWordsPerSentence),
            averageSyllablesPerWord: Self.round2(avgSyllablesPerWord),
            fleschReadingEase: Self.round2(fleschEase),
            fleschKincaidGradeLevel: Self.round2(fkGrade),
            gunningFogIndex: Self.round2(gunningFog),
            colemanLiauIndex: Self.round2(colemanLiau),
            lexicalTypeTokenRatio: Self.round2(ttr),
            academicRegisterInterpretation: registerDescription
        )
    }

    // MARK: - Venue Budget Estimator

    private func estimateVenueBudget(
        venue: AcademicVenuePreset,
        mainBodyProseWords: Int,
        abstractWords: Int,
        captionWords: Int,
        headerWords: Int,
        footnoteWords: Int,
        figureCount: Int,
        wideFigureCount: Int,
        tableCount: Int,
        wideTableCount: Int,
        algorithmCount: Int,
        displayEquationCount: Int
    ) -> VenueBudgetEstimate {
        let singleColFigs = max(0, figureCount - wideFigureCount)
        let singleColTabs = max(0, tableCount - wideTableCount)

        let floatPages =
            Double(singleColFigs) * venue.singleColumnFigurePageFootprint
            + Double(wideFigureCount) * venue.wideFigurePageFootprint
            + Double(singleColTabs) * venue.singleColumnTablePageFootprint
            + Double(wideTableCount) * venue.wideTablePageFootprint
            + Double(algorithmCount) * venue.algorithmPageFootprint

        let equationPages = Double(displayEquationCount) * venue.displayEquationPageFootprint
        // Title/author banner on page 1 consumes ~0.22 pages in conference templates.
        let bannerOverheadPages = (mainBodyProseWords > 0 || abstractWords > 0) ? 0.22 : 0.0

        let textWordsInMainLayout = mainBodyProseWords + abstractWords + captionWords + headerWords + footnoteWords
        let textPages = Double(textWordsInMainLayout) / venue.proseWordsPerFullPage
        let estimatedPages = Self.round2(bannerOverheadPages + textPages + floatPages + equationPages)

        let pageRatio = Self.round2(estimatedPages / max(1.0, venue.targetPageLimit))

        // Compute effective word limit & remaining/excess words
        let effectiveWordCap: Int
        let remainingOrExcessWords: Int
        if let explicitCap = venue.explicitWordCap {
            effectiveWordCap = explicitCap
            remainingOrExcessWords = explicitCap - mainBodyProseWords
        } else {
            let availablePagesForProse = max(0.0, venue.targetPageLimit - (bannerOverheadPages + floatPages + equationPages))
            let totalProseBudget = Int((availablePagesForProse * venue.proseWordsPerFullPage).rounded())
            effectiveWordCap = max(0, totalProseBudget)
            remainingOrExcessWords = totalProseBudget - textWordsInMainLayout
        }

        let abstractExceeded: Bool
        if let maxAbs = venue.maxAbstractWords {
            abstractExceeded = abstractWords > maxAbs
        } else {
            abstractExceeded = false
        }

        let totalDisplayItems = figureCount + tableCount
        let displayItemsExceeded: Bool
        if let maxItems = venue.maxDisplayItems {
            displayItemsExceeded = totalDisplayItems > maxItems
        } else {
            displayItemsExceeded = false
        }

        var notes: [String] = []
        if abstractExceeded, let maxAbs = venue.maxAbstractWords {
            notes.append("Abstract has \(abstractWords) words (exceeds \(venue.rawValue) cap of \(maxAbs) words).")
        }
        if displayItemsExceeded, let maxItems = venue.maxDisplayItems {
            notes.append("Main body contains \(totalDisplayItems) display items (figures + tables), exceeding limit of \(maxItems); move extras to Extended Data / Appendix.")
        }
        if remainingOrExcessWords < 0 {
            notes.append("Over budget by \(-remainingOrExcessWords) words (~ \(Self.round2(max(0.0, estimatedPages - venue.targetPageLimit))) pages).")
        } else if pageRatio >= 0.90 {
            notes.append("Tight fit (\(Int((pageRatio * 100.0).rounded()))% of \(venue.targetPageLimit)-page budget); \(remainingOrExcessWords) prose words remaining.")
        } else {
            notes.append("Comfortable margin: \(remainingOrExcessWords) prose words remaining before reaching \(venue.targetPageLimit)-page limit.")
        }

        let status: VenueBudgetComplianceStatus
        if remainingOrExcessWords < 0 || estimatedPages > venue.targetPageLimit || displayItemsExceeded {
            status = .overBudget
        } else if pageRatio >= 0.90 || abstractExceeded {
            status = .nearLimitAdvisory
        } else {
            status = .withinBudget
        }

        return VenueBudgetEstimate(
            venue: venue,
            estimatedMainBodyPages: estimatedPages,
            targetPageLimit: venue.targetPageLimit,
            pageUtilizationRatio: pageRatio,
            effectiveWordLimit: effectiveWordCap,
            remainingOrExcessWords: remainingOrExcessWords,
            abstractLimitExceeded: abstractExceeded,
            displayItemLimitExceeded: displayItemsExceeded,
            status: status,
            advisoryNotes: notes
        )
    }

    // MARK: - Lexical Word, Sentence & Syllable Algorithms

    static func collapseSpaces(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var lastWasSpace = true
        for ch in raw {
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

    static func extractLexicalWords(from cleanProse: String) -> [String] {
        var words: [String] = []
        var current: String = ""

        for scalar in cleanProse.unicodeScalars {
            // Treat CJK Unified Ideographs as individual lexical word units (`texcount` CJK rule).
            if (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
                || (scalar.value >= 0x3400 && scalar.value <= 0x4DBF) {
                if !current.isEmpty {
                    words.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                words.append(String(scalar))
                continue
            }

            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if (scalar == "-" || scalar == "'" || scalar == "’") && !current.isEmpty {
                current.unicodeScalars.append(scalar)
            } else {
                // Trim any trailing hyphen/apostrophe before committing word
                while let last = current.last, last == "-" || last == "'" || last == "’" {
                    current.removeLast()
                }
                if !current.isEmpty {
                    words.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            }
        }

        while let last = current.last, last == "-" || last == "'" || last == "’" {
            current.removeLast()
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    /// Splits academic prose into sentences while ignoring periods inside abbreviations (`et al.`, `Fig.`, `e.g.`, `i.e.`)
    /// and decimal numbers (`p < 0.05`, `3.14`).
    static func countAcademicSentences(in prose: String) -> Int {
        guard !prose.isEmpty else { return 0 }
        let chars = Array(prose)
        let n = chars.count
        var sentences = 0
        var i = 0

        while i < n {
            let ch = chars[i]
            if ch == "!" || ch == "?" || ch == "。" || ch == "！" || ch == "？" {
                sentences += 1
                while i + 1 < n && (chars[i + 1] == "!" || chars[i + 1] == "?" || chars[i + 1] == ".") {
                    i += 1
                }
                i += 1
                continue
            }

            if ch == "." {
                // 1. Decimal number check (`3.14`)
                let prevIsDigit = (i > 0 && chars[i - 1].isNumber)
                let nextIsDigit = (i + 1 < n && chars[i + 1].isNumber)
                if prevIsDigit && nextIsDigit {
                    i += 1
                    continue
                }

                // 2. Ellipsis `...`
                if i + 1 < n && chars[i + 1] == "." {
                    while i + 1 < n && chars[i + 1] == "." {
                        i += 1
                    }
                    i += 1
                    continue
                }

                // 3. Extract preceding word token to check academic abbreviation (`et al.`, `Fig. 2`, `e.g.`)
                var wordStart = i
                while wordStart > 0 && (chars[wordStart - 1].isLetter || chars[wordStart - 1] == ".") {
                    wordStart -= 1
                }
                let precedingToken = String(chars[wordStart..<i]).lowercased()
                if nonTerminalAcademicAbbreviations.contains(precedingToken)
                    || (precedingToken.count == 1 && chars[wordStart].isUppercase) {
                    i += 1
                    continue
                }

                // Count as a genuine sentence boundary when followed by whitespace/quote/end-of-string.
                if i + 1 >= n || chars[i + 1].isWhitespace || chars[i + 1] == "\"" || chars[i + 1] == "”" || chars[i + 1] == ")" || chars[i + 1] == "]" {
                    sentences += 1
                }
            }
            i += 1
        }

        return max(1, sentences)
    }

    /// Morphophonemic English syllable estimator calibrated for scientific & academic vocabulary.
    static func countEnglishSyllables(in lowercasedWord: String) -> Int {
        let lettersOnly = lowercasedWord.filter { $0 >= "a" && $0 <= "z" }
        if lettersOnly.isEmpty {
            return 1
        }
        if lettersOnly.count <= 3 {
            return 1
        }

        let chars = Array(lettersOnly)
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var groups = 0
        var prevVowel = false

        for ch in chars {
            let isV = vowels.contains(ch)
            if isV && !prevVowel {
                groups += 1
            }
            prevVowel = isV
        }

        // Silent trailing `-e` (unless syllabic `-le` preceded by a consonant like `table`, `sample`, `multiple`)
        if chars.last == "e" {
            let len = chars.count
            let isSyllabicLE = len >= 3 && chars[len - 2] == "l" && !vowels.contains(chars[len - 3])
            let isDoubleEE = len >= 2 && chars[len - 2] == "e"
            if !isSyllabicLE && !isDoubleEE {
                groups -= 1
            }
        }

        // Silent `-ed` verbal suffix when not preceded by `t` or `d` (`computed` = 3, `learned` = 1, `trained` = 1)
        if lettersOnly.hasSuffix("ed") && chars.count >= 4 {
            let beforeEd = chars[chars.count - 3]
            if beforeEd != "t" && beforeEd != "d" && !vowels.contains(beforeEd) {
                groups -= 1
            }
        }

        // Silent `-es` when not preceded by sibilant (`s`, `z`, `x`, `c`, `g`, `h`)
        if lettersOnly.hasSuffix("es") && chars.count >= 4 {
            let beforeEs = chars[chars.count - 3]
            let sibilants: Set<Character> = ["s", "z", "x", "c", "g", "h"]
            if !sibilants.contains(beforeEs) && !vowels.contains(beforeEs) {
                groups -= 1
            }
        }

        // Hiatus vowel pairs that span two syllables (`-ia-` in `median`, `-io-` in `prior`, `-ua-` in `dual`, `cooperate`)
        if lettersOnly.contains("ia") && !lettersOnly.contains("cia") && !lettersOnly.contains("tia") {
            groups += 1
        }
        if lettersOnly.contains("io") && !lettersOnly.contains("tion") && !lettersOnly.contains("sion") {
            groups += 1
        }
        if lettersOnly.hasSuffix("ism") {
            groups += 1
        }

        return max(1, groups)
    }

    @inline(__always)
    private static func round2(_ value: Double) -> Double {
        (value * 100.0).rounded() / 100.0
    }
}

private extension TypstDirectiveRole {
    static var footnoteCommandEquivalent: TypstDirectiveRole {
        .generalHashDirective
    }
}
