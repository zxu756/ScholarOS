import Foundation
import PDFKit
import ScholarModels

// MARK: - Quantitative Binding Taxonomy & Models

public enum QuantitativeFamily: String, Sendable, Codable, Hashable, CaseIterable {
    case duration = "duration"
    case memory = "memory"
    case percent = "percent"
    case multiplier = "multiplier"
    case rate = "rate"
    case pValue = "pvalue"
    case confidenceInterval = "confidence_interval"
    case sampleSize = "sample_size"
    case metricScore = "metric_score"
    case count = "count"
}

public enum QuantitativeComparisonOperator: String, Sendable, Codable, Hashable, CaseIterable {
    case equal = "="
    case approximatelyEqual = "≈"
    case lessThan = "<"
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
}

public struct ExtractedQuantitativeBinding: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(family.rawValue):\(rawSurfaceText)@\(characterOffset)" }
    public let family: QuantitativeFamily
    public let rawSurfaceText: String
    public let relation: QuantitativeComparisonOperator
    public let rawNumericValue: Double
    public let canonicalValue: Double
    public let canonicalUnit: String
    public let secondaryUpperValue: Double?
    public let headNoun: String?
    public let modifiers: Set<String>
    public let halfULPTolerance: Double
    public let characterOffset: Int

    public init(
        family: QuantitativeFamily,
        rawSurfaceText: String,
        relation: QuantitativeComparisonOperator = .equal,
        rawNumericValue: Double,
        canonicalValue: Double,
        canonicalUnit: String,
        secondaryUpperValue: Double? = nil,
        headNoun: String? = nil,
        modifiers: Set<String> = [],
        halfULPTolerance: Double = 0.0,
        characterOffset: Int = 0
    ) {
        self.family = family
        self.rawSurfaceText = rawSurfaceText
        self.relation = relation
        self.rawNumericValue = rawNumericValue
        self.canonicalValue = canonicalValue
        self.canonicalUnit = canonicalUnit
        self.secondaryUpperValue = secondaryUpperValue
        self.headNoun = headNoun
        self.modifiers = modifiers
        self.halfULPTolerance = max(0.0, halfULPTolerance)
        self.characterOffset = characterOffset
    }
}

// MARK: - Evidence Locator & Numeric Checker Engine (M4 Core Library, Fixes S13)

/// Locates lexically matching passages in local PDFs under a strict majority keyword coverage threshold
/// and verifies explicit `<number + unit/classifier/noun>` pairs with SI/binary unit conversion, p-value inequality logic,
/// and confidence interval checks. Deliberately makes NO claim about semantic entailment or logical support.
public struct EvidenceLocatorAndNumericChecker: Sendable {
    public static let defaultMinimumKeywordCoverage: Double = 0.60
    public static let defaultEnableBareNumberNounExtraction: Bool = true
    public static let defaultPreferCandidatesWithAlignedNumbers: Bool = true
    public static let defaultRequireSameNounValueAgreement: Bool = true

    public let minimumKeywordCoverage: Double
    public let relativeRoundingTolerance: Double
    public let enableBareNumberNounExtraction: Bool
    public let preferCandidatesWithAlignedNumbers: Bool
    public let requireSameNounValueAgreement: Bool

    public init(
        minimumKeywordCoverage: Double = Self.defaultMinimumKeywordCoverage,
        relativeRoundingTolerance: Double = 0.012,
        enableBareNumberNounExtraction: Bool = Self.defaultEnableBareNumberNounExtraction,
        preferCandidatesWithAlignedNumbers: Bool = Self.defaultPreferCandidatesWithAlignedNumbers,
        requireSameNounValueAgreement: Bool = Self.defaultRequireSameNounValueAgreement
    ) {
        self.minimumKeywordCoverage = min(1.0, max(0.01, minimumKeywordCoverage))
        self.relativeRoundingTolerance = max(0.0, relativeRoundingTolerance)
        self.enableBareNumberNounExtraction = enableBareNumberNounExtraction
        self.preferCandidatesWithAlignedNumbers = preferCandidatesWithAlignedNumbers
        self.requireSameNounValueAgreement = requireSameNounValueAgreement
    }

    // MARK: 1. Public Localization Entry Points

    public func locateEvidence(
        claim: String,
        inPDFAt pdfURL: URL,
        citeKey: String? = nil,
        topK: Int = 3
    ) throws -> EvidenceLocalizationResult {
        let effectiveCiteKey = citeKey ?? pdfURL.deletingPathExtension().lastPathComponent
        let chunks = try PDFMultiColumnSegmenter().segmentPDF(at: pdfURL, citeKey: effectiveCiteKey)
        return locateEvidence(
            claim: claim,
            passages: chunks,
            pdfFileName: pdfURL.lastPathComponent,
            citeKeyFilter: citeKey,
            topK: topK
        )
    }

    public func locateEvidence(
        claim: String,
        in index: FTS5ProvenanceIndex,
        citeKeyFilter: String? = nil,
        pdfFileName: String? = nil,
        topK: Int = 3
    ) throws -> EvidenceLocalizationResult {
        let queryKeywords = Self.extractQueryKeywords(from: claim)
        guard !queryKeywords.isEmpty else {
            return EvidenceLocalizationResult(
                claim: claim,
                pdfFile: pdfFileName,
                verdict: .notFound,
                queryKeywords: []
            )
        }

        let ftsHits = try index.searchPassages(query: claim, citeKeyFilter: citeKeyFilter, limit: 32)
        var bm25ByID: [String: Double] = [:]
        for hit in ftsHits {
            bm25ByID[hit.chunk.id] = hit.bm25Magnitude
        }

        // Combine FTS5 recalled chunks with searchable corpus when citeKey-scoped (enabling adjacent 2-chunk fallback if split)
        let candidatePool: [PDFPassageChunk]
        if citeKeyFilter != nil || ftsHits.isEmpty {
            let full = try index.loadSearchablePassages(citeKeyFilter: citeKeyFilter)
            candidatePool = full.isEmpty ? ftsHits.map(\.chunk) : full
        } else {
            candidatePool = ftsHits.map(\.chunk)
        }

        return evaluateCandidates(
            claim: claim,
            queryKeywords: queryKeywords,
            passages: candidatePool,
            precomputedBM25: bm25ByID,
            pdfFileName: pdfFileName,
            citeKeyFilter: citeKeyFilter,
            topK: topK
        )
    }

    public func locateEvidence(
        claim: String,
        passages: [PDFPassageChunk],
        pdfFileName: String? = nil,
        citeKeyFilter: String? = nil,
        topK: Int = 3
    ) -> EvidenceLocalizationResult {
        let queryKeywords = Self.extractQueryKeywords(from: claim)
        guard !queryKeywords.isEmpty else {
            return EvidenceLocalizationResult(
                claim: claim,
                pdfFile: pdfFileName,
                verdict: .notFound,
                queryKeywords: []
            )
        }

        let filtered = passages.filter { chunk in
            guard !chunk.kind.isHeaderOrFooter else { return false }
            if let citeKeyFilter, chunk.citeKey != citeKeyFilter {
                return false
            }
            return true
        }

        let bm25Map = Self.computeInMemoryBM25(queryKeywords: queryKeywords, passages: filtered)
        return evaluateCandidates(
            claim: claim,
            queryKeywords: queryKeywords,
            passages: filtered,
            precomputedBM25: bm25Map,
            pdfFileName: pdfFileName,
            citeKeyFilter: citeKeyFilter,
            topK: topK
        )
    }

    // MARK: 2. Rule 1 (Majority Keyword Threshold) & Rule 2 (Numeric Checking) Pipeline

    private struct ScoredCandidate {
        let chunk: PDFPassageChunk
        let coverage: Double
        let matchedKeywords: [String]
        let bm25Score: Double
        let contentPriorityTier: Int
    }

    private func evaluateCandidates(
        claim: String,
        queryKeywords: [String],
        passages: [PDFPassageChunk],
        precomputedBM25: [String: Double],
        pdfFileName: String?,
        citeKeyFilter: String?,
        topK: Int
    ) -> EvidenceLocalizationResult {
        let strippedClaim = Self.stripCitationsAndMarkup(claim)
        let claimCJKCount = Self.countCJKIdeographs(in: strippedClaim)

        let searchable = passages.filter { chunk in
            guard !chunk.kind.isHeaderOrFooter else { return false }
            if let citeKeyFilter, chunk.citeKey != citeKeyFilter {
                return false
            }
            return true
        }

        guard !searchable.isEmpty else {
            return EvidenceLocalizationResult(
                claim: claim,
                pdfFile: pdfFileName,
                verdict: .notFound,
                queryKeywords: queryKeywords
            )
        }

        func scoreChunk(_ chunk: PDFPassageChunk, bm25: Double) -> ScoredCandidate? {
            let combinedText = chunk.passageText
            // Same-language rule (User decision #5): Chinese claim against English PDF (or vice versa) returns NOT_FOUND
            if Self.isCrossLanguageMismatch(claimCJKCount: claimCJKCount, passageText: combinedText) {
                return nil
            }
            let passageKeywordSet = Set(Self.extractQueryKeywords(from: combinedText))
            let matched = queryKeywords.filter { passageKeywordSet.contains($0) }
            let qCount = queryKeywords.count
            let cov = Double(matched.count) / Double(qCount)

            if qCount <= 2 {
                guard matched.count == qCount else { return nil }
            } else {
                let requiredHits = max(1, Int(Foundation.ceil(minimumKeywordCoverage * Double(qCount) - 1e-9)))
                guard matched.count >= requiredHits, (cov + 1e-9) >= minimumKeywordCoverage else {
                    return nil
                }
            }

            return ScoredCandidate(
                chunk: chunk,
                coverage: cov,
                matchedKeywords: matched,
                bm25Score: bm25,
                contentPriorityTier: Self.contentPriorityTier(for: chunk)
            )
        }

        var passing: [ScoredCandidate] = []
        for chunk in searchable {
            let bm25 = precomputedBM25[chunk.id] ?? 0.0
            if let cand = scoreChunk(chunk, bm25: bm25) {
                passing.append(cand)
            }
        }

        // Fallback: if no single chunk passed, inspect adjacent same-page, same-column, same-section body pairs
        // (protects sentences split across a paragraph break without polluting single-paragraph hits)
        if passing.isEmpty && searchable.count >= 2 {
            let ordered = searchable.sorted { $0.readingSequence < $1.readingSequence }
            for idx in 0..<(ordered.count - 1) {
                let a = ordered[idx]
                let b = ordered[idx + 1]
                guard a.kind == .body,
                      b.kind == .body,
                      a.boundingBox.pageIndex == b.boundingBox.pageIndex,
                      a.columnIndex == b.columnIndex,
                      a.sectionTitle == b.sectionTitle else {
                    continue
                }
                let minX = min(a.boundingBox.x, b.boundingBox.x)
                let minY = min(a.boundingBox.y, b.boundingBox.y)
                let maxX = max(a.boundingBox.x + a.boundingBox.width, b.boundingBox.x + b.boundingBox.width)
                let maxY = max(a.boundingBox.y + a.boundingBox.height, b.boundingBox.y + b.boundingBox.height)
                let mergedChunk = PDFPassageChunk(
                    id: "\(a.id)+\(b.id)",
                    citeKey: a.citeKey,
                    pdfFileName: a.pdfFileName,
                    sectionTitle: a.sectionTitle,
                    columnIndex: a.columnIndex,
                    readingSequence: a.readingSequence,
                    boundingBox: PDFPageRegionBox(
                        pageIndex: a.boundingBox.pageIndex,
                        x: minX,
                        y: minY,
                        width: maxX - minX,
                        height: maxY - minY
                    ),
                    passageText: a.passageText + " " + b.passageText,
                    kind: .body
                )
                let mergedBM25 = max(precomputedBM25[a.id] ?? 0.0, precomputedBM25[b.id] ?? 0.0)
                if let cand = scoreChunk(mergedChunk, bm25: mergedBM25) {
                    passing.append(cand)
                }
            }
        }

        // Never fall back to low-score passages when nothing meets the threshold
        guard !passing.isEmpty else {
            return EvidenceLocalizationResult(
                claim: claim,
                pdfFile: pdfFileName,
                verdict: .notFound,
                queryKeywords: queryKeywords
            )
        }

        passing.sort { a, b in
            if abs(a.coverage - b.coverage) > 1e-6 {
                return a.coverage > b.coverage
            }
            if a.contentPriorityTier != b.contentPriorityTier {
                return a.contentPriorityTier > b.contentPriorityTier
            }
            if abs(a.bm25Score - b.bm25Score) > 1e-6 {
                return a.bm25Score > b.bm25Score
            }
            return a.chunk.readingSequence < b.chunk.readingSequence
        }

        let claimBindings = extractQuantitativeBindings(from: claim)
        let maxReturned = max(1, topK)

        // Qualitative claim (no explicit quantitative numbers in claim): top passing candidate is FOUND
        if claimBindings.isEmpty {
            let matches = passing.prefix(maxReturned).map {
                EvidencePassageMatch(
                    chunk: $0.chunk,
                    coverage: $0.coverage,
                    matchedKeywords: $0.matchedKeywords,
                    bm25Score: $0.bm25Score,
                    discrepancies: []
                )
            }
            return EvidenceLocalizationResult(
                claim: claim,
                pdfFile: pdfFileName ?? matches.first?.pdfFile,
                verdict: .found,
                queryKeywords: queryKeywords,
                matches: matches
            )
        }

        // Quantitative claim: evaluate explicit number+unit/classifier/noun bindings on ALL passing candidates
        struct EvaluatedCandidate {
            let candidate: ScoredCandidate
            let discrepancies: [EvidenceNumericDiscrepancy]
            let alignedCounterpartCount: Int
            let sameNounAlignedCount: Int
        }

        let allClaimHeadNouns = Set(claimBindings.compactMap(\.headNoun))

        let evaluated: [EvaluatedCandidate] = passing.map { cand in
            let pdfBindings = extractQuantitativeBindings(from: cand.chunk.passageText)
            var discrepancies: [EvidenceNumericDiscrepancy] = []
            var alignedCount = 0
            var sameNounCount = 0
            for cb in claimBindings {
                let outcome = compareBinding(cb, against: pdfBindings, allClaimHeadNouns: allClaimHeadNouns)
                if outcome.hadAlignedCounterpart {
                    alignedCount += 1
                }
                if outcome.hadSameNounCounterpart {
                    sameNounCount += 1
                }
                if let disc = outcome.discrepancy {
                    discrepancies.append(disc)
                }
            }
            return EvaluatedCandidate(
                candidate: cand,
                discrepancies: discrepancies,
                alignedCounterpartCount: alignedCount,
                sameNounAlignedCount: sameNounCount
            )
        }

        // Rank passing candidates: when `preferCandidatesWithAlignedNumbers` is enabled, passages containing
        // numbers with the same noun or same dimension as the claim's numbers take precedence over numberless
        // summary passages; only when no passing passage has any aligned number do we fall back to coverage order.
        let orderedCandidates: [EvaluatedCandidate]
        if preferCandidatesWithAlignedNumbers {
            orderedCandidates = evaluated.sorted { a, b in
                let aHasAligned = a.alignedCounterpartCount > 0
                let bHasAligned = b.alignedCounterpartCount > 0
                if aHasAligned != bHasAligned {
                    return aHasAligned
                }
                if a.alignedCounterpartCount != b.alignedCounterpartCount {
                    return a.alignedCounterpartCount > b.alignedCounterpartCount
                }
                if a.sameNounAlignedCount != b.sameNounAlignedCount {
                    return a.sameNounAlignedCount > b.sameNounAlignedCount
                }
                if abs(a.candidate.coverage - b.candidate.coverage) > 1e-6 {
                    return a.candidate.coverage > b.candidate.coverage
                }
                if a.candidate.contentPriorityTier != b.candidate.contentPriorityTier {
                    return a.candidate.contentPriorityTier > b.candidate.contentPriorityTier
                }
                if abs(a.candidate.bm25Score - b.candidate.bm25Score) > 1e-6 {
                    return a.candidate.bm25Score > b.candidate.bm25Score
                }
                return a.candidate.chunk.readingSequence < b.candidate.chunk.readingSequence
            }
        } else {
            orderedCandidates = evaluated
        }

        // If a top-ranked candidate (within 0.15 coverage of the leading candidate in its alignment tier)
        // satisfies ALL quantitative bindings, return FOUND.
        let referenceCoverage = orderedCandidates[0].candidate.coverage
        let referenceAlignedCount = orderedCandidates[0].alignedCounterpartCount
        if let cleanIdx = orderedCandidates.firstIndex(where: {
            $0.discrepancies.isEmpty
                && (!preferCandidatesWithAlignedNumbers || $0.alignedCounterpartCount == referenceAlignedCount)
                && ($0.candidate.coverage + 1e-6 >= referenceCoverage - 0.15)
        }) {
            var reordered = orderedCandidates
            let winner = reordered.remove(at: cleanIdx)
            reordered.insert(winner, at: 0)
            let matches = reordered.prefix(maxReturned).map {
                EvidencePassageMatch(
                    chunk: $0.candidate.chunk,
                    coverage: $0.candidate.coverage,
                    matchedKeywords: $0.candidate.matchedKeywords,
                    bm25Score: $0.candidate.bm25Score,
                    discrepancies: $0.discrepancies
                )
            }
            return EvidenceLocalizationResult(
                claim: claim,
                pdfFile: pdfFileName ?? matches.first?.pdfFile,
                verdict: .found,
                queryKeywords: queryKeywords,
                matches: matches
            )
        }

        // Otherwise all passing candidates have >= 1 numeric discrepancy; `orderedCandidates` already places
        // the passage containing the aligned source PDF numbers first (or falls back to coverage order if none do).
        let matches = orderedCandidates.prefix(maxReturned).map {
            EvidencePassageMatch(
                chunk: $0.candidate.chunk,
                coverage: $0.candidate.coverage,
                matchedKeywords: $0.candidate.matchedKeywords,
                bm25Score: $0.candidate.bm25Score,
                discrepancies: $0.discrepancies
            )
        }
        let primaryDiscrepancies = matches.first?.discrepancies ?? []

        return EvidenceLocalizationResult(
            claim: claim,
            pdfFile: pdfFileName ?? matches.first?.pdfFile,
            verdict: .numericMismatch,
            queryKeywords: queryKeywords,
            matches: matches,
            discrepancies: primaryDiscrepancies
        )
    }

    private static func contentPriorityTier(for chunk: PDFPassageChunk) -> Int {
        let isBibSection = isBibliographySectionTitle(chunk.sectionTitle)
        switch chunk.kind {
        case .header, .footer:
            return -1
        case .sectionHeading:
            return 0
        case .body:
            return isBibSection ? 1 : 3
        case .tableOrFigure:
            return isBibSection ? 1 : 2
        }
    }

    private static func isBibliographySectionTitle(_ title: String) -> Bool {
        let trimmed = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if trimmed.isEmpty { return false }
        return trimmed.range(
            of: #"^(?:(?:\d{1,2}\.?|[ivxlcdm]{1,6}\.)\s+)?(?:references|bibliography|works cited|literature cited|references and notes|参考文献)$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isCrossLanguageMismatch(claimCJKCount: Int, passageText: String) -> Bool {
        let passageCJKCount = countCJKIdeographs(in: passageText)
        if claimCJKCount >= 2 && passageCJKCount == 0 {
            return true
        }
        if claimCJKCount == 0 && passageCJKCount >= 4 {
            let latinWordCount = passageText.range(of: #"[A-Za-z]{3,}"#, options: .regularExpression) != nil
            if !latinWordCount {
                return true
            }
        }
        return false
    }

    // MARK: 3. Quantitative Extraction (Dimensional Units, p-Values, CIs, Classifiers & Nouns)

    public func extractQuantitativeBindings(from rawText: String) -> [ExtractedQuantitativeBinding] {
        let cleaned = Self.stripCitationsAndMarkup(rawText)
        let ns = cleaned as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        var occupied: [NSRange] = []
        var bindings: [ExtractedQuantitativeBinding] = []

        func claimRangeIfFree(_ range: NSRange) -> Bool {
            guard range.location != NSNotFound, range.length > 0 else { return false }
            for existing in occupied {
                if NSIntersectionRange(existing, range).length > 0 {
                    return false
                }
            }
            occupied.append(range)
            return true
        }

        // 1. Statistical p-values: `p < 0.001`, `p = 0.008`, `p <= 0.05`, `p > 0.10`
        if let pRegex = try? NSRegularExpression(
            pattern: #"\bp(?:-value)?\s*(<=|>=|<|>|=|≈)\s*(0?\.\d+|1(?:\.0+)?|\d+(?:\.\d+)?e-\d+)\b"#,
            options: [.caseInsensitive]
        ) {
            for m in pRegex.matches(in: cleaned, range: fullRange) where claimRangeIfFree(m.range) {
                let opStr = ns.substring(with: m.range(at: 1))
                let valStr = ns.substring(with: m.range(at: 2))
                if let val = Self.parseCleanDouble(valStr) {
                    bindings.append(
                        ExtractedQuantitativeBinding(
                            family: .pValue,
                            rawSurfaceText: ns.substring(with: m.range).trimmingCharacters(in: .whitespaces),
                            relation: Self.parseOperator(opStr),
                            rawNumericValue: val,
                            canonicalValue: val,
                            canonicalUnit: "p",
                            headNoun: "pvalue",
                            halfULPTolerance: Self.halfULPTolerance(forLiteral: valStr),
                            characterOffset: m.range.location
                        )
                    )
                }
            }
        }

        // 2. Confidence Intervals: `95% CI [87.4, 90.0]`, `CI: 1.12 to 1.84`, `CI [0.74, 0.89]`
        if let ciRegex = try? NSRegularExpression(
            pattern: #"(?:\b\d{2}%\s*)?\bCI\s*[:=]?\s*[\[\(]?\s*(-?\d+(?:\.\d+)?)\s*(?:,|to|–|—|-)\s*(-?\d+(?:\.\d+)?)\s*[\]\)]?"#,
            options: [.caseInsensitive]
        ) {
            for m in ciRegex.matches(in: cleaned, range: fullRange) where claimRangeIfFree(m.range) {
                let loStr = ns.substring(with: m.range(at: 1))
                let hiStr = ns.substring(with: m.range(at: 2))
                if let lo = Self.parseCleanDouble(loStr), let hi = Self.parseCleanDouble(hiStr) {
                    bindings.append(
                        ExtractedQuantitativeBinding(
                            family: .confidenceInterval,
                            rawSurfaceText: ns.substring(with: m.range).trimmingCharacters(in: .whitespaces),
                            relation: .equal,
                            rawNumericValue: lo,
                            canonicalValue: lo,
                            canonicalUnit: "interval",
                            secondaryUpperValue: hi,
                            headNoun: "ci",
                            halfULPTolerance: max(
                                Self.halfULPTolerance(forLiteral: loStr),
                                Self.halfULPTolerance(forLiteral: hiStr)
                            ),
                            characterOffset: m.range.location
                        )
                    )
                }
            }
        }

        // Mask bracketed numeric citations `[1]`, `[33]`, `[12, 15]`, `[3–6]` so reference indices are never extracted
        if let bracketCiteRegex = try? NSRegularExpression(
            pattern: #"\[\s*\d{1,4}(?:\s*[,;–—-]\s*\d{1,4})*\s*\]"#
        ) {
            for m in bracketCiteRegex.matches(in: cleaned, range: fullRange) {
                _ = claimRangeIfFree(m.range)
            }
        }

        // 3. Sample sizes `N = 1,240`, `n = 1, 000 samples`, `n = 48`, `N >= 500`
        if let nRegex = try? NSRegularExpression(
            pattern: #"\b([Nn])\s*(<=|>=|<|>|=|≈)\s*([1-9]\d{0,2}(?:, ?\d{3})+(?!\d)|\d+)\b"#
        ) {
            for m in nRegex.matches(in: cleaned, range: fullRange) {
                let opStr = ns.substring(with: m.range(at: 2))
                let valStr = ns.substring(with: m.range(at: 3))
                if let val = Self.parseCleanDouble(valStr) {
                    let afterText = ns.substring(from: m.range.location + m.range.length)
                    let (directHead, directMods, directLen) = Self.scanTrailingEnglishNounPhrase(in: afterText)
                    let (parenHead, parenMods, parenLen) = Self.scanParenOfEnglishNounPhrase(in: afterText)
                    let trailingHead = directHead ?? parenHead
                    let trailingMods = directHead != nil ? directMods : parenMods
                    let extraLen = directHead != nil ? directLen : parenLen
                    let spanRange = NSRange(location: m.range.location, length: m.range.length + extraLen)
                    guard claimRangeIfFree(spanRange) else { continue }

                    bindings.append(
                        ExtractedQuantitativeBinding(
                            family: .sampleSize,
                            rawSurfaceText: ns.substring(with: spanRange).trimmingCharacters(in: .whitespaces),
                            relation: Self.parseOperator(opStr),
                            rawNumericValue: val,
                            canonicalValue: val,
                            canonicalUnit: "count",
                            headNoun: trailingHead ?? "sample_n",
                            modifiers: trailingMods.union(["sample_n"]),
                            halfULPTolerance: Self.halfULPTolerance(forLiteral: valStr),
                            characterOffset: m.range.location
                        )
                    )
                }
            }
        }

        // 4. Named prefix metric scores (`F1 = 92.6`, `AUC = 0.964`, `BLEU = 34.8`, `accuracy = 94.2%`, `kappa = 0.84`)
        if let metricRegex = try? NSRegularExpression(
            pattern: #"\b(F1(?:-score)?|AUROC|AUC|BLEU|ROUGE(?:-[12L])?|MMLU|pass@\d+|accuracy|precision|recall|perplexity|PPL|kappa|κ|PABAK|RMSE|MAE|IoU|mAP)\s*(?:score\s*)?(?:of\s*|is\s*|<=|>=|<|>|=|≈)\s*(\d+(?:\.\d+)?)(%?)"#,
            options: [.caseInsensitive]
        ) {
            for m in metricRegex.matches(in: cleaned, range: fullRange) where claimRangeIfFree(m.range) {
                let rawMetric = ns.substring(with: m.range(at: 1))
                let valStr = ns.substring(with: m.range(at: 2))
                let pctSuffix = ns.substring(with: m.range(at: 3))
                if let val = Self.parseCleanDouble(valStr) {
                    let canonMetric = Self.canonicalizeMetricName(rawMetric)
                    let isPct = !pctSuffix.isEmpty
                    let isUnitInterval = Self.isUnitIntervalMetric(canonMetric)
                    let canonVal = (!isPct && val <= 1.0 && isUnitInterval) ? (val * 100.0) : val
                    let tol = (!isPct && val <= 1.0 && isUnitInterval)
                        ? (Self.halfULPTolerance(forLiteral: valStr) * 100.0)
                        : Self.halfULPTolerance(forLiteral: valStr)

                    bindings.append(
                        ExtractedQuantitativeBinding(
                            family: isPct ? .percent : .metricScore,
                            rawSurfaceText: ns.substring(with: m.range).trimmingCharacters(in: .whitespaces),
                            relation: .equal,
                            rawNumericValue: val,
                            canonicalValue: canonVal,
                            canonicalUnit: (isPct || isUnitInterval) ? "%" : "score",
                            headNoun: canonMetric.lowercased(),
                            halfULPTolerance: tol,
                            characterOffset: m.range.location
                        )
                    )
                }
            }
        }

        // 5. General number + dimensional/statistical unit OR `[classifier] + noun phrase` (English & Chinese)
        // Supports PDF-extracted spaced thousands (`30, 000`, `1, 000`) when comma + single space + exactly 3 digits
        // are not followed by another digit, while never merging `(1, 2)`, `(10, 20)`, `(0, 100)`, or `1, 2000`.
        guard let numRegex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])([+-]?(?:[1-9]\d{0,2}(?:, ?\d{3})+(?!\d)|\d+)(?:\.\d+)?)"#
        ) else {
            return bindings.sorted { $0.characterOffset < $1.characterOffset }
        }

        for m in numRegex.matches(in: cleaned, range: fullRange) {
            let numRange = m.range(at: 1)
            let numStr = ns.substring(with: numRange)
            guard let rawVal = Self.parseCleanDouble(numStr) else { continue }

            // Skip numbers already inside p-value, CI, N=..., metric=..., or [citation] spans
            let alreadyOccupied = occupied.contains { NSIntersectionRange($0, numRange).length > 0 }
            if alreadyOccupied { continue }

            // Skip hyphenated technical identifiers like `GPT-2`, `ResNet-50`, `UTF-8`, `sub-10ms`, `v1.7`
            if numRange.location >= 2 {
                let twoBefore = ns.substring(with: NSRange(location: numRange.location - 2, length: 2))
                if twoBefore.range(of: #"^[A-Za-z][-.]$"#, options: .regularExpression) != nil {
                    continue
                }
            }
            if numStr.hasPrefix("-") && numRange.location >= 1 {
                let charBefore = ns.substring(with: NSRange(location: numRange.location - 1, length: 1))
                if charBefore.range(of: #"^[A-Za-z0-9]$"#, options: .regularExpression) != nil {
                    continue
                }
            }

            let afterStart = numRange.location + numRange.length
            let afterSub = ns.substring(from: afterStart)

            // Skip ordinals (`1st`, `2nd`, `3rd`, `99th`) and dimension tags (`2D`, `3D`)
            if afterSub.range(of: #"^(?:st|nd|rd|th|[dD])\b"#, options: .regularExpression) != nil {
                continue
            }
            // Skip multi-level section numbers like `3.1.2`
            if afterSub.hasPrefix(".") && afterSub.dropFirst().first?.isNumber == true {
                continue
            }

            // Skip structural references (`Section 4`, `Fig. 3`, `Table 1`, `Eq. (2)`, `Vol. 14`, `No. 2`, `pp. 41`, `第 3 节`)
            let beforeWindowStart = max(0, numRange.location - 24)
            let beforeSub = ns.substring(with: NSRange(location: beforeWindowStart, length: numRange.location - beforeWindowStart))
            if Self.isPrecededByStructuralReferenceLabel(beforeSub: beforeSub, afterSub: afterSub) {
                continue
            }

            // Skip standalone parenthesized equation/tuple labels `(1)`, `(10)`, `(1, 128)` unless followed by `of <noun>` or a unit
            if beforeSub.hasSuffix("(") && afterSub.hasPrefix(")") {
                let restAfterParen = String(afterSub.dropFirst()).trimmingCharacters(in: .whitespaces)
                if numStr.contains(", ") && !restAfterParen.lowercased().hasPrefix("of ") {
                    continue
                }
                if restAfterParen.isEmpty || ".,;:".contains(restAfterParen.first!) || restAfterParen.first?.isUppercase == true {
                    continue
                }
            }

            // 5a. Check if immediately followed by a known dimensional or statistical unit (English or Chinese)
            if let unitMatch = Self.matchLeadingUnit(in: afterSub) {
                let totalRange = NSRange(location: numRange.location, length: numRange.length + unitMatch.consumedUTF16Length)
                guard claimRangeIfFree(totalRange) else { continue }

                let surface = ns.substring(with: totalRange).trimmingCharacters(in: .whitespaces)
                let tailAfterUnit = ns.substring(from: totalRange.location + totalRange.length)
                let (enHead, enMods, _) = Self.scanTrailingEnglishNounPhrase(in: tailAfterUnit)
                let zhHead = Self.scanTrailingChineseNoun(in: tailAfterUnit)
                let effectiveVal = unitMatch.family == .percent ? abs(rawVal) : rawVal

                bindings.append(
                    ExtractedQuantitativeBinding(
                        family: unitMatch.family,
                        rawSurfaceText: surface,
                        relation: .equal,
                        rawNumericValue: effectiveVal,
                        canonicalValue: effectiveVal * unitMatch.multiplier,
                        canonicalUnit: unitMatch.canonicalUnit,
                        headNoun: enHead ?? zhHead,
                        modifiers: enMods,
                        halfULPTolerance: Self.halfULPTolerance(forLiteral: numStr) * unitMatch.multiplier,
                        characterOffset: numRange.location
                    )
                )
                continue
            }

            // 5b. Check postfix metric name (`28.4 BLEU`, `92.6 F1`)
            if let postfixMetric = Self.matchPostfixMetric(in: afterSub) {
                let totalRange = NSRange(location: numRange.location, length: numRange.length + postfixMetric.consumedUTF16Length)
                guard claimRangeIfFree(totalRange) else { continue }
                let surface = ns.substring(with: totalRange).trimmingCharacters(in: .whitespaces)
                let isUnitInterval = Self.isUnitIntervalMetric(postfixMetric.canonicalMetric)
                let canonVal = (rawVal <= 1.0 && isUnitInterval) ? (rawVal * 100.0) : rawVal
                let tol = (rawVal <= 1.0 && isUnitInterval)
                    ? (Self.halfULPTolerance(forLiteral: numStr) * 100.0)
                    : Self.halfULPTolerance(forLiteral: numStr)

                bindings.append(
                    ExtractedQuantitativeBinding(
                        family: .metricScore,
                        rawSurfaceText: surface,
                        relation: .equal,
                        rawNumericValue: rawVal,
                        canonicalValue: canonVal,
                        canonicalUnit: isUnitInterval ? "%" : "score",
                        headNoun: postfixMetric.canonicalMetric.lowercased(),
                        halfULPTolerance: tol,
                        characterOffset: numRange.location
                    )
                )
                continue
            }

            // 5c. General bare number + `[Chinese classifier] + <noun>` or `<English noun phrase>`
            // Controlled by `enableBareNumberNounExtraction` (verified by mutation M4-03)
            guard enableBareNumberNounExtraction else { continue }

            // Chinese `<number> + <classifier> + <noun>` (e.g. `368 个测试`, `9999 个测试`, `1,240 个基准查询`)
            if let zhCount = Self.matchChineseClassifierNoun(in: afterSub) {
                if Self.isLikelyIsolatedYear(value: rawVal, literal: numStr, followedByCountNoun: true, isYearSuffix: zhCount.headNoun == "年") {
                    continue
                }
                let totalRange = NSRange(location: numRange.location, length: numRange.length + zhCount.consumedUTF16Length)
                guard claimRangeIfFree(totalRange) else { continue }
                let surface = ns.substring(with: totalRange).trimmingCharacters(in: .whitespaces)

                bindings.append(
                    ExtractedQuantitativeBinding(
                        family: .count,
                        rawSurfaceText: surface,
                        relation: .equal,
                        rawNumericValue: rawVal,
                        canonicalValue: rawVal,
                        canonicalUnit: "count",
                        headNoun: zhCount.headNoun,
                        modifiers: zhCount.modifiers,
                        halfULPTolerance: Self.halfULPTolerance(forLiteral: numStr),
                        characterOffset: numRange.location
                    )
                )
                continue
            }

            // Parenthesized count followed by `of + <English noun phrase>`:
            // e.g. `a small dataset (610) of PuzzleScript games` -> binds 610 to `games` (modifier `puzzlescript`)
            if beforeSub.trimmingCharacters(in: .whitespaces).hasSuffix("(") {
                let (parenHead, parenMods, parenConsumedLen) = Self.scanParenOfEnglishNounPhrase(in: afterSub)
                if let parenHead, parenConsumedLen > 0 {
                    let openParenLoc = (cleaned as NSString).range(
                        of: "(",
                        options: .backwards,
                        range: NSRange(location: max(0, numRange.location - 4), length: min(4, numRange.location))
                    ).location
                    let startLoc = openParenLoc != NSNotFound ? openParenLoc : numRange.location
                    let endLoc = numRange.location + numRange.length + parenConsumedLen
                    let totalRange = NSRange(location: startLoc, length: endLoc - startLoc)
                    if claimRangeIfFree(totalRange) {
                        let surface = ns.substring(with: totalRange).trimmingCharacters(in: .whitespaces)
                        bindings.append(
                            ExtractedQuantitativeBinding(
                                family: .count,
                                rawSurfaceText: surface,
                                relation: .equal,
                                rawNumericValue: rawVal,
                                canonicalValue: rawVal,
                                canonicalUnit: "count",
                                headNoun: parenHead,
                                modifiers: parenMods,
                                halfULPTolerance: Self.halfULPTolerance(forLiteral: numStr),
                                characterOffset: startLoc
                            )
                        )
                        continue
                    }
                }
            }

            // English `<number> + <1..3 noun/modifier words>` (e.g. `368 regression tests`, `1,240 benchmark queries`)
            let (enHead, enMods, enConsumedLen) = Self.scanTrailingEnglishNounPhrase(in: afterSub)
            if let enHead, enConsumedLen > 0 {
                // Skip calendar/publication years `1900..2099` unless followed by a genuine lowercase plural count noun
                let firstWordIsLowerPlural = Self.startsWithLowercasePluralNoun(afterSub)
                if Self.isLikelyIsolatedYear(value: rawVal, literal: numStr, followedByCountNoun: firstWordIsLowerPlural, isYearSuffix: false) {
                    continue
                }

                let totalRange = NSRange(location: numRange.location, length: numRange.length + enConsumedLen)
                guard claimRangeIfFree(totalRange) else { continue }
                let surface = ns.substring(with: totalRange).trimmingCharacters(in: .whitespaces)

                bindings.append(
                    ExtractedQuantitativeBinding(
                        family: .count,
                        rawSurfaceText: surface,
                        relation: .equal,
                        rawNumericValue: rawVal,
                        canonicalValue: rawVal,
                        canonicalUnit: "count",
                        headNoun: enHead,
                        modifiers: enMods,
                        halfULPTolerance: Self.halfULPTolerance(forLiteral: numStr),
                        characterOffset: numRange.location
                    )
                )
            }
        }

        return bindings.sorted { $0.characterOffset < $1.characterOffset }
    }

    // MARK: 4. Quantitative Alignment & Discrepancy Evaluation

    private struct BindingComparisonOutcome {
        let discrepancy: EvidenceNumericDiscrepancy?
        let hadAlignedCounterpart: Bool
        let hadSameNounCounterpart: Bool
    }

    private func compareBinding(
        _ claim: ExtractedQuantitativeBinding,
        against pdfBindings: [ExtractedQuantitativeBinding],
        allClaimHeadNouns: Set<String> = []
    ) -> BindingComparisonOutcome {
        let sameNounPool: [ExtractedQuantitativeBinding]
        if requireSameNounValueAgreement {
            sameNounPool = Self.selectStratifiedSameNounPool(
                for: claim,
                in: pdfBindings,
                allClaimHeadNouns: allClaimHeadNouns
            )
        } else {
            sameNounPool = []
        }

        // Fall back to same dimensional/statistical family only when no same-noun binding appeared in the passage
        let sameFamilyPool: [ExtractedQuantitativeBinding]
        if !requireSameNounValueAgreement {
            sameFamilyPool = pdfBindings.filter { pdf in
                Self.familiesCompatibleWhenNounMatches(claim.family, pdf.family)
                    || Self.familiesCompatibleByDimension(
                        claim.family,
                        pdf.family,
                        claimUnit: claim.canonicalUnit,
                        pdfUnit: pdf.canonicalUnit
                    )
            }
        } else if claim.family == .count {
            sameFamilyPool = []
        } else {
            sameFamilyPool = pdfBindings.filter { pdf in
                guard Self.familiesCompatibleByDimension(
                    claim.family,
                    pdf.family,
                    claimUnit: claim.canonicalUnit,
                    pdfUnit: pdf.canonicalUnit
                ) else {
                    return false
                }
                // If claim specified a concrete noun and `pdf` explicitly carries a different noun mentioned in the claim, do not steal it
                if let ch = claim.headNoun,
                   ch != "sample_n",
                   let ph = pdf.headNoun,
                   ph != ch,
                   allClaimHeadNouns.contains(ph) {
                    return false
                }
                return true
            }
        }

        let matchedBySameNoun = !sameNounPool.isEmpty
        let pool = matchedBySameNoun ? sameNounPool : sameFamilyPool

        guard !pool.isEmpty else {
            // Missing in passage: if there is a count/number in the passage with no aligned noun, surface the closest passage number as context if available
            let fallbackPDF = pdfBindings.first { $0.family == claim.family }?.rawSurfaceText
            return BindingComparisonOutcome(
                discrepancy: EvidenceNumericDiscrepancy(
                    claimText: claim.rawSurfaceText,
                    pdfText: fallbackPDF,
                    reason: fallbackPDF != nil
                        ? "Claim states '\(claim.rawSurfaceText)', whereas passage reports '\(fallbackPDF!)'."
                        : "Claimed quantity '\(claim.rawSurfaceText)' was not found in the matched PDF passage."
                ),
                hadAlignedCounterpart: false,
                hadSameNounCounterpart: false
            )
        }

        // Check if any candidate in `pool` is quantitatively compatible
        for cand in pool {
            if isQuantitativelyCompatible(claim: claim, pdf: cand) {
                return BindingComparisonOutcome(
                    discrepancy: nil,
                    hadAlignedCounterpart: true,
                    hadSameNounCounterpart: matchedBySameNoun
                )
            }
        }

        // Pick closest aligned candidate to report the exact source PDF number & unit
        let closest = pool.min { a, b in
            abs(a.canonicalValue - claim.canonicalValue) < abs(b.canonicalValue - claim.canonicalValue)
        }!

        let reason: String
        if claim.family == .pValue {
            reason = "Statistical p-value mismatch: claim states '\(claim.rawSurfaceText)', whereas PDF reports '\(closest.rawSurfaceText)'."
        } else if claim.family == .confidenceInterval {
            reason = "Confidence interval mismatch: claim states '\(claim.rawSurfaceText)', whereas PDF reports '\(closest.rawSurfaceText)'."
        } else {
            reason = "Numeric mismatch: claim states '\(claim.rawSurfaceText)', whereas PDF reports '\(closest.rawSurfaceText)'."
        }

        return BindingComparisonOutcome(
            discrepancy: EvidenceNumericDiscrepancy(
                claimText: claim.rawSurfaceText,
                pdfText: closest.rawSurfaceText,
                reason: reason
            ),
            hadAlignedCounterpart: true,
            hadSameNounCounterpart: matchedBySameNoun
        )
    }

    /// Selects the highest-specificity noun match tier so that an exact noun match (`3 layers` vs `4 layers`,
    /// `3 encoder layers` vs `4 encoder layers`, `3 datasets` vs `4 datasets`) is never masked by another noun's
    /// value, modifier cross-talk (`4 per-layer attention heads`), or synonym pooling (`4 benchmarks`).
    private static func selectStratifiedSameNounPool(
        for claim: ExtractedQuantitativeBinding,
        in pdfBindings: [ExtractedQuantitativeBinding],
        allClaimHeadNouns: Set<String>
    ) -> [ExtractedQuantitativeBinding] {
        guard let ch = claim.headNoun else { return [] }
        let familyFiltered = pdfBindings.filter {
            familiesCompatibleWhenNounMatches(claim.family, $0.family)
        }

        // Tier 1A: Exact head noun stem + overlapping non-empty modifiers (`4 encoder layers` -> `3 encoder layers`)
        if !claim.modifiers.isEmpty {
            let tier1A = familyFiltered.filter { pdf in
                pdf.headNoun == ch
                    && !pdf.modifiers.isEmpty
                    && !claim.modifiers.isDisjoint(with: pdf.modifiers)
            }
            if !tier1A.isEmpty { return tier1A }
        }

        // Tier 1B: Exact head noun stem without conflicting modifiers (`4 layers` -> `3 layers` or `3 multi-head attention layers`)
        let tier1B = familyFiltered.filter { pdf in
            pdf.headNoun == ch && (claim.modifiers.isEmpty || pdf.modifiers.isEmpty)
        }
        if !tier1B.isEmpty { return tier1B }

        // Tier 1C: Exact head noun stem even when modifiers differ (excluding bindings whose modifier matches another claim binding if any)
        let tier1C = familyFiltered.filter { pdf in
            pdf.headNoun == ch
        }
        if !tier1C.isEmpty { return tier1C }

        // Tier 2: Count-noun synonym group or non-hyphenated modifier cross-match, ONLY if `pdf.headNoun`
        // is not already claimed as an exact head noun by another number in the same claim
        let tier2 = familyFiltered.filter { pdf in
            guard let ph = pdf.headNoun else { return false }
            if ph != ch && allClaimHeadNouns.contains(ph) {
                return false
            }
            return nounsMatch(claim, pdf)
        }
        return tier2
    }

    private func isQuantitativelyCompatible(
        claim: ExtractedQuantitativeBinding,
        pdf: ExtractedQuantitativeBinding
    ) -> Bool {
        if claim.family == .pValue && pdf.family == .pValue {
            return Self.evaluatePValueCompatibility(claim: claim, pdf: pdf)
        }

        if claim.family == .confidenceInterval && pdf.family == .confidenceInterval,
           let claimHi = claim.secondaryUpperValue,
           let pdfHi = pdf.secondaryUpperValue {
            let tol = claim.halfULPTolerance + pdf.halfULPTolerance
            let loDiff = abs(claim.canonicalValue - pdf.canonicalValue)
            let hiDiff = abs(claimHi - pdfHi)
            return max(loDiff, hiDiff) <= tol + 1e-9
        }

        // Handle unit-interval [0, 1] vs percentage [0, 100] when nouns match (e.g. `0.942 precision` vs `94.2% precision`)
        var claimVal = claim.canonicalValue
        var pdfVal = pdf.canonicalValue
        var combinedTol = claim.halfULPTolerance + pdf.halfULPTolerance
        if claim.family != pdf.family && (claim.family == .percent || pdf.family == .percent) {
            if claim.family != .percent && claimVal <= 1.0 && pdfVal > 1.0 {
                claimVal *= 100.0
                combinedTol = claim.halfULPTolerance * 100.0 + pdf.halfULPTolerance
            } else if pdf.family != .percent && pdfVal <= 1.0 && claimVal > 1.0 {
                pdfVal *= 100.0
                combinedTol = claim.halfULPTolerance + pdf.halfULPTolerance * 100.0
            }
        }

        let absDiff = abs(claimVal - pdfVal)
        if absDiff <= combinedTol + 1e-9 {
            return true
        }
        let denom = max(1e-9, abs(pdfVal))
        let relDiff = absDiff / denom
        return relDiff <= relativeRoundingTolerance
    }

    private static func evaluatePValueCompatibility(
        claim: ExtractedQuantitativeBinding,
        pdf: ExtractedQuantitativeBinding
    ) -> Bool {
        let pClaim = claim.canonicalValue
        let pPDF = pdf.canonicalValue
        let tol = claim.halfULPTolerance + pdf.halfULPTolerance

        switch claim.relation {
        case .lessThan, .lessThanOrEqual:
            guard pdf.relation == .equal
                    || pdf.relation == .approximatelyEqual
                    || pdf.relation == .lessThan
                    || pdf.relation == .lessThanOrEqual else {
                return false
            }
            return pPDF <= pClaim + 1e-9
        case .greaterThan, .greaterThanOrEqual:
            guard pdf.relation != .lessThan && pdf.relation != .lessThanOrEqual else {
                return false
            }
            return pPDF + tol >= pClaim - 1e-9
        case .equal, .approximatelyEqual:
            guard pdf.relation == .equal || pdf.relation == .approximatelyEqual else {
                return false
            }
            return abs(pClaim - pPDF) <= tol + 1e-9
        }
    }

    private static func familiesCompatibleWhenNounMatches(_ a: QuantitativeFamily, _ b: QuantitativeFamily) -> Bool {
        if a == b { return true }
        let countGroup: Set<QuantitativeFamily> = [.count, .sampleSize]
        if countGroup.contains(a) && countGroup.contains(b) { return true }
        let scoreGroup: Set<QuantitativeFamily> = [.percent, .metricScore]
        if scoreGroup.contains(a) && scoreGroup.contains(b) { return true }
        return false
    }

    private static func familiesCompatibleByDimension(
        _ a: QuantitativeFamily,
        _ b: QuantitativeFamily,
        claimUnit: String,
        pdfUnit: String
    ) -> Bool {
        if a == b {
            if a == .rate {
                return claimUnit == pdfUnit
            }
            return true
        }
        if (a == .percent || a == .metricScore) && (b == .percent || b == .metricScore) && claimUnit == pdfUnit {
            return true
        }
        if (a == .sampleSize && b == .count) || (a == .count && b == .sampleSize) {
            return true
        }
        return false
    }

    private static func nounsMatch(_ a: ExtractedQuantitativeBinding, _ b: ExtractedQuantitativeBinding) -> Bool {
        guard let ha = a.headNoun, let hb = b.headNoun else { return false }
        let ca = canonicalizeCountNounSynonym(ha)
        let cb = canonicalizeCountNounSynonym(hb)
        if ca == cb { return true }
        let modsA = Set(a.modifiers.map(canonicalizeCountNounSynonym))
        let modsB = Set(b.modifiers.map(canonicalizeCountNounSynonym))
        if modsB.contains(ca) || modsA.contains(cb) { return true }
        return false
    }

    private static func canonicalizeCountNounSynonym(_ noun: String) -> String {
        switch noun {
        case "test", "suit", "case": return "test"
        case "query", "request", "prompt": return "query"
        case "dataset", "benchmark", "corpus": return "dataset"
        case "paper", "articl", "studi", "manuscript", "document": return "paper"
        case "templat", "layout": return "templat"
        case "particip", "subject", "patient", "respond": return "subject"
        case "workload", "task", "trajectori": return "workload"
        default: return noun
        }
    }

    // MARK: 5. Lexical Preprocessing, CJK Bigrams & Stemming

    public static func extractQueryKeywords(from rawText: String) -> [String] {
        let stripped = stripUnitsAttachedToNumbers(in: stripCitationsAndMarkup(rawText))
        var tokens: [String] = []

        // 1. English alphabetic tokens
        if let enRegex = try? NSRegularExpression(pattern: #"[A-Za-z]{3,}"#) {
            let ns = stripped as NSString
            for m in enRegex.matches(in: stripped, range: NSRange(location: 0, length: ns.length)) {
                let word = ns.substring(with: m.range).lowercased()
                if englishStopwords.contains(word) || standaloneUnitTokens.contains(word) {
                    continue
                }
                tokens.append(stemEnglishWord(word))
            }
        }

        // 2. Chinese 2-grams (or single character when length == 1 after particle filtering)
        tokens.append(contentsOf: extractCJKTerms(from: stripped))

        var seen = Set<String>()
        return tokens.filter { seen.insert($0).inserted }
    }

    public static func extractFTS5QueryTerms(from rawText: String) -> [String] {
        let stripped = stripUnitsAttachedToNumbers(in: stripCitationsAndMarkup(rawText))
        var terms: [String] = []

        if let enRegex = try? NSRegularExpression(pattern: #"[A-Za-z]{3,}"#) {
            let ns = stripped as NSString
            for m in enRegex.matches(in: stripped, range: NSRange(location: 0, length: ns.length)) {
                let word = ns.substring(with: m.range).lowercased()
                if englishStopwords.contains(word) || standaloneUnitTokens.contains(word) {
                    continue
                }
                terms.append(word)
            }
        }

        terms.append(contentsOf: extractCJKTerms(from: stripped))

        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }

    public static func extractCJKTerms(from text: String) -> [String] {
        guard let cjkRegex = try? NSRegularExpression(pattern: #"[\u4E00-\u9FFF]+"#) else { return [] }
        let stripped = stripUnitsAttachedToNumbers(in: text)
        let ns = stripped as NSString
        var out: [String] = []

        for m in cjkRegex.matches(in: stripped, range: NSRange(location: 0, length: ns.length)) {
            let rawRun = ns.substring(with: m.range)
            // Split on high-frequency Chinese particles/classifiers so unrelated characters across particles don't form spurious bigrams
            let segments = rawRun.components(separatedBy: cjkParticleCharacterSet).filter { !$0.isEmpty }
            for seg in segments {
                let chars = Array(seg)
                if chars.count == 1 {
                    out.append(String(chars[0]))
                } else if chars.count >= 2 {
                    for i in 0..<(chars.count - 1) {
                        out.append(String([chars[i], chars[i + 1]]))
                    }
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    public static func stripCitationsAndMarkup(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "\\%", with: "%")
            .replacingOccurrences(of: "{,}", with: ",")
            .replacingOccurrences(of: "\\,", with: " ")
            .replacingOccurrences(of: "\\times", with: "×")
            .replacingOccurrences(of: "\\le", with: "<=")
            .replacingOccurrences(of: "\\leq", with: "<=")
            .replacingOccurrences(of: "\\ge", with: ">=")
            .replacingOccurrences(of: "\\geq", with: ">=")
            .replacingOccurrences(of: "\\approx", with: "≈")
            .replacingOccurrences(of: "\\mu s", with: "μs")
            .replacingOccurrences(of: "\\mu\\text{s}", with: "μs")
            .replacingOccurrences(of: "~", with: " ")
            .replacingOccurrences(of: "$", with: " ")

        let stripPatterns = [
            #"\\(?:cite[a-zA-Z]*|parencite|textcite|autocite|footcite|nocite|Cite[a-zA-Z]*)\*?(?:\[[^\]]*\])*\{[^}]*\}"#,
            #"\\(?:ref|eqref|autoref|cref|Cref|pageref|nameref|label)\*?\{[^}]*\}"#,
            #"#cite\s*\([^)]*\)"#,
            #"(?<![A-Za-z0-9])@[A-Za-z][A-Za-z0-9_.:-]*"#,
            #"\\[a-zA-Z]+\*?"#
        ]
        for pat in stripPatterns {
            if let rx = try? NSRegularExpression(pattern: pat) {
                s = rx.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
            }
        }

        return s
            .replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
    }

    private static func stripUnitsAttachedToNumbers(in text: String) -> String {
        var s = text
        let patterns = [
            #"(?<![A-Za-z0-9_])[+-]?(?:[1-9]\d{0,2}(?:, ?\d{3})+(?!\d)|\d+)(?:\.\d+)?\s*(?:percentage\s+points?|per\s+cent|req/s|ops/s|tok/s|tokens/s|samples/s|queries/s|%|pp\b|-fold\b|[x×]\b|(?:ns|nanoseconds?|us|μs|µs|microseconds?|ms|milliseconds?|s|secs?|seconds?|mins?|minutes?|h|hrs?|hours?|days?|bytes?|KiB|MiB|GiB|TiB|KB|MB|GB|TB|RPS|QPS|kHz|MHz|GHz|Hz|GFLOPS|TFLOPS|PFLOPS|FLOPS|Kbps|Mbps|Gbps|bps)\b)"#,
            #"[+-]?(?:[1-9]\d{0,2}(?:, ?\d{3})+(?!\d)|\d+)(?:\.\d+)?\s*(?:毫秒|微秒|纳秒|分钟|小时|百分点|字节|秒|天|倍)"#
        ]
        for pat in patterns {
            if let rx = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                s = rx.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
            }
        }
        return s
    }

    public static func stemEnglishWord(_ word: String) -> String {
        let w = word.lowercased()
        switch w {
        case "analyses": return "analysis"
        case "matrices": return "matrix"
        case "indices": return "index"
        case "vertices": return "vertex"
        case "corpora": return "corpus"
        case "criteria": return "criterion"
        default: break
        }

        var stem = w
        if stem.hasSuffix("ations") && stem.count > 9 {
            stem.removeLast(6)
        } else if stem.hasSuffix("ation") && stem.count > 8 {
            stem.removeLast(5)
        } else if stem.hasSuffix("ments") && stem.count > 8 {
            stem.removeLast(5)
        } else if stem.hasSuffix("ment") && stem.count > 7 {
            stem.removeLast(4)
        } else if stem.hasSuffix("ingly") && stem.count > 8 {
            stem.removeLast(5)
        } else if stem.hasSuffix("edly") && stem.count > 7 {
            stem.removeLast(4)
        } else if stem.hasSuffix("ing") && stem.count > 6 {
            stem.removeLast(3)
        } else if (stem.hasSuffix("ies") || stem.hasSuffix("ied")) && stem.count > 4 {
            stem.removeLast(3)
            stem.append("y")
        } else if (stem.hasSuffix("ses") || stem.hasSuffix("xes") || stem.hasSuffix("zes") || stem.hasSuffix("ches") || stem.hasSuffix("shes")) && stem.count > 5 {
            stem.removeLast(2)
        } else if stem.hasSuffix("ed") && stem.count > 5 {
            stem.removeLast(2)
        } else if stem.hasSuffix("s") && !stem.hasSuffix("ss") && !stem.hasSuffix("us") && !stem.hasSuffix("is") && stem.count > 3 {
            stem.removeLast(1)
        }

        if stem.count >= 5 && stem.hasSuffix("e") && !stem.hasSuffix("ee") {
            stem.removeLast(1)
        }
        return stem
    }

    // MARK: 6. Internal Unit, Structural-Label, Noun-Scanning & BM25 Helpers

    private static let cjkParticleCharacterSet = CharacterSet(
        charactersIn: "的是了着过在上下中里内外和与及或并而但因为所以把被对向从以将用由这那其各每我们你们他们她们它们个条篇次项轮层组类种名位台张批套步份处"
    )

    private static let englishStopwords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "these", "those", "were", "have", "been",
        "being", "having", "into", "onto", "upon", "their", "them", "they", "while", "where", "which",
        "when", "what", "whose", "whom", "than", "then", "thus", "therefore", "hence", "however",
        "moreover", "furthermore", "also", "over", "under", "above", "below", "between", "among",
        "through", "during", "before", "after", "around", "about", "against", "toward", "towards",
        "across", "within", "without", "via", "per", "are", "was", "has", "had", "our", "its",
        "can", "could", "may", "might", "will", "would", "shall", "should", "must", "does", "did",
        "not", "any", "all", "some", "such", "both", "each", "every", "either", "neither", "only",
        "same", "other", "another", "more", "most", "less", "least", "fewer", "very", "just",
        "according", "recent", "paper", "study", "work", "author", "authors", "using", "used", "uses",
        "use", "based", "show", "shows", "shown", "showed", "report", "reports", "reported",
        "claim", "claims", "claimed", "state", "states", "stated", "demonstrate", "demonstrates",
        "demonstrated", "reach", "reaches", "reached", "attain", "attains", "attained",
        "obtain", "obtains", "obtained", "yield", "yields", "yielded",
        "section", "sec", "table", "tab", "fig", "figure", "equation",
        "cite", "citet", "citep", "parencite", "textcite", "autocite"
    ]

    private static let standaloneUnitTokens: Set<String> = [
        "ns", "us", "ms", "sec", "secs", "min", "mins", "hr", "hrs",
        "kb", "mb", "gb", "tb", "kib", "mib", "gib", "tib",
        "rps", "qps", "hz", "khz", "mhz", "ghz", "flops", "gflops", "tflops"
    ]

    private static let nounBoundaryStopwords: Set<String> = englishStopwords.union([
        // Prepositions, conjunctions, determiners, pronouns, and clause connectors
        "in", "on", "of", "to", "by", "as", "at", "an", "be", "is", "am", "or", "nor", "but", "yet", "so",
        "we", "it", "he", "she", "you", "if", "who", "how", "why", "my", "his", "her",
        "throughout", "amongst", "including", "excluding", "regarding", "concerning", "despite", "unlike",
        "near", "beyond", "behind", "beneath", "beside", "besides", "alongside", "plus", "minus", "versus", "vs",
        "whether", "whereas", "although", "though", "because", "since", "unless", "until",
        // Unambiguous finite verbs & participial clause starters (excluding noun homographs like samples/tests/runs)
        "achieving", "achieve", "achieves", "achieved",
        "remained", "remains", "remaining", "remain",
        "required", "requires", "requiring", "require",
        "completes", "completed", "completing", "complete",
        "reduces", "reduced", "reducing", "reduce",
        "maintaining", "maintain", "maintains", "maintained",
        "outperform", "outperforms", "outperformed", "outperforming",
        "exceed", "exceeds", "exceeded", "exceeding",
        "contain", "contains", "contained", "containing",
        "consist", "consists", "consisted", "consisting",
        "comprise", "comprises", "comprised", "comprising",
        "constitute", "constitutes", "constituted", "constituting",
        "include", "includes", "included",
        "exclude", "excludes", "excluded",
        "cover", "covers", "covered", "covering",
        "span", "spans", "spanned", "spanning",
        "indicate", "indicates", "indicated", "indicating",
        "confirm", "confirms", "confirmed", "confirming",
        "reveal", "reveals", "revealed", "revealing",
        "suggest", "suggests", "suggested", "suggesting",
        "provide", "provides", "provided", "providing",
        "allow", "allows", "allowed", "allowing",
        "enable", "enables", "enabled", "enabling",
        "prevent", "prevents", "prevented", "preventing",
        "improve", "improves", "improved", "improving",
        "increase", "increases", "increased", "increasing",
        "decrease", "decreases", "decreased", "decreasing",
        "appear", "appears", "appeared", "appearing",
        "occur", "occurs", "occurred", "occurring",
        "exist", "exists", "existed", "existing",
        "differ", "differs", "differed", "differing",
        "vary", "varies", "varied",
        "correspond", "corresponds", "corresponded", "corresponding",
        "belong", "belongs", "belonged", "belonging",
        "depend", "depends", "depended", "depending",
        "represent", "represents", "represented", "representing",
        "denote", "denotes", "denoted", "denoting",
        "satisfy", "satisfies", "satisfied", "satisfying",
        "follow", "follows", "followed", "following",
        "produce", "produces", "produced", "producing",
        "evaluate", "evaluates", "evaluated", "evaluating"
    ])

    private static let postNominalIrregularParticiples: Set<String> = [
        "built", "drawn", "taken", "chosen", "written", "given", "made", "known", "shown", "seen", "found",
        "held", "kept", "driven", "proven", "broken", "spoken", "frozen", "hidden", "sent", "spent", "meant",
        "dealt", "left", "lost", "sold", "told", "stood", "bought", "brought", "caught", "fought", "sought",
        "taught", "thought"
    ]

    private static let postNominalUninflectedParticiplesAfterPlural: Set<String> = [
        "split", "set", "put", "cut", "cast", "run", "let", "read"
    ]

    private static let postNominalAdverbs: Set<String> = [
        "overall", "together", "alone", "apart", "apiece", "respectively"
    ]

    private static let leadingAdjectiveModifiers: Set<String> = [
        "distinct", "different", "separate", "individual", "unique", "single", "multiple",
        "total", "overall", "average", "median", "mean", "additional", "independent",
        "consecutive", "standard", "local", "public", "real", "synthetic"
    ]

    private static let structuralReferenceLabels: Set<String> = [
        "section", "sec", "secs", "subsection", "chapter", "chap", "appendix", "app",
        "fig", "figs", "figure", "figures", "table", "tables", "tab", "tabs",
        "eq", "eqs", "equation", "equations", "formula", "algorithm", "alg",
        "theorem", "thm", "lemma", "proposition", "prop", "corollary", "definition",
        "page", "pages", "p", "pp", "vol", "volume", "no", "issue", "ref", "refs"
    ]

    private struct MatchedUnitInfo {
        let family: QuantitativeFamily
        let multiplier: Double
        let canonicalUnit: String
        let consumedUTF16Length: Int
    }

    private static func matchLeadingUnit(in afterSub: String) -> MatchedUnitInfo? {
        let ns = afterSub as NSString
        let full = NSRange(location: 0, length: ns.length)

        // 1. Compound & multi-word units (longest first)
        let compoundPatterns: [(String, QuantitativeFamily, Double, String, Bool)] = [
            (#"^\s*(percentage\s+points?)\b"#, .percent, 1.0, "pp", true),
            (#"^\s*(per\s+cent)\b"#, .percent, 1.0, "%", true),
            (#"^\s*(req/s|ops/s|tok/s|tokens/s|samples/s|queries/s|img/s|images/s)\b"#, .rate, 1.0, "rate_per_s", true),
            (#"^\s*(%|pp\b)"#, .percent, 1.0, "%", true),
            (#"^\s*(-fold\b|[x×]\b)"#, .multiplier, 1.0, "x", true),
            (#"^\s*(毫秒|微秒|纳秒|分钟|小时|百分点|字节|秒|天|倍)"#, .duration, 1.0, "s", false)
        ]

        for (pat, defaultFam, defaultMult, defaultUnit, caseInsens) in compoundPatterns {
            let opts: NSRegularExpression.Options = caseInsens ? [.caseInsensitive] : []
            if let rx = try? NSRegularExpression(pattern: pat, options: opts),
               let m = rx.firstMatch(in: afterSub, range: full) {
                let tok = ns.substring(with: m.range(at: 1))
                let tokLow = tok.lowercased()
                if tokLow == "pp" || tokLow.hasPrefix("percentage point") || tok == "百分点" {
                    return MatchedUnitInfo(family: .percent, multiplier: 1.0, canonicalUnit: "pp", consumedUTF16Length: m.range.length)
                }
                if tok == "毫秒" { return MatchedUnitInfo(family: .duration, multiplier: 1e-3, canonicalUnit: "s", consumedUTF16Length: m.range.length) }
                if tok == "微秒" { return MatchedUnitInfo(family: .duration, multiplier: 1e-6, canonicalUnit: "s", consumedUTF16Length: m.range.length) }
                if tok == "纳秒" { return MatchedUnitInfo(family: .duration, multiplier: 1e-9, canonicalUnit: "s", consumedUTF16Length: m.range.length) }
                if tok == "秒" { return MatchedUnitInfo(family: .duration, multiplier: 1.0, canonicalUnit: "s", consumedUTF16Length: m.range.length) }
                if tok == "分钟" { return MatchedUnitInfo(family: .duration, multiplier: 60.0, canonicalUnit: "s", consumedUTF16Length: m.range.length) }
                if tok == "小时" { return MatchedUnitInfo(family: .duration, multiplier: 3600.0, canonicalUnit: "s", consumedUTF16Length: m.range.length) }
                if tok == "天" { return MatchedUnitInfo(family: .duration, multiplier: 86400.0, canonicalUnit: "s", consumedUTF16Length: m.range.length) }
                if tok == "字节" { return MatchedUnitInfo(family: .memory, multiplier: 1.0, canonicalUnit: "bytes", consumedUTF16Length: m.range.length) }
                if tok == "倍" { return MatchedUnitInfo(family: .multiplier, multiplier: 1.0, canonicalUnit: "x", consumedUTF16Length: m.range.length) }
                return MatchedUnitInfo(family: defaultFam, multiplier: defaultMult, canonicalUnit: defaultUnit, consumedUTF16Length: m.range.length)
            }
        }

        // 2. Single-token alphabetic units
        if let rx = try? NSRegularExpression(pattern: #"^\s*([A-Za-zμµ]+)\b"#),
           let m = rx.firstMatch(in: afterSub, range: full) {
            let unitTok = ns.substring(with: m.range(at: 1))
            let low = unitTok.lowercased()
            switch low {
            case "ns", "nanosecond", "nanoseconds":
                return MatchedUnitInfo(family: .duration, multiplier: 1e-9, canonicalUnit: "s", consumedUTF16Length: m.range.length)
            case "us", "μs", "µs", "microsecond", "microseconds":
                return MatchedUnitInfo(family: .duration, multiplier: 1e-6, canonicalUnit: "s", consumedUTF16Length: m.range.length)
            case "ms", "millisecond", "milliseconds":
                return MatchedUnitInfo(family: .duration, multiplier: 1e-3, canonicalUnit: "s", consumedUTF16Length: m.range.length)
            case "s", "sec", "secs", "second", "seconds":
                return MatchedUnitInfo(family: .duration, multiplier: 1.0, canonicalUnit: "s", consumedUTF16Length: m.range.length)
            case "min", "mins", "minute", "minutes":
                return MatchedUnitInfo(family: .duration, multiplier: 60.0, canonicalUnit: "s", consumedUTF16Length: m.range.length)
            case "h", "hr", "hrs", "hour", "hours":
                return MatchedUnitInfo(family: .duration, multiplier: 3600.0, canonicalUnit: "s", consumedUTF16Length: m.range.length)
            case "day", "days":
                return MatchedUnitInfo(family: .duration, multiplier: 86400.0, canonicalUnit: "s", consumedUTF16Length: m.range.length)
            case "byte", "bytes":
                return MatchedUnitInfo(family: .memory, multiplier: 1.0, canonicalUnit: "bytes", consumedUTF16Length: m.range.length)
            case "kb", "kilobyte", "kilobytes":
                return MatchedUnitInfo(family: .memory, multiplier: 1e3, canonicalUnit: "bytes", consumedUTF16Length: m.range.length)
            case "mb", "megabyte", "megabytes":
                return MatchedUnitInfo(family: .memory, multiplier: 1e6, canonicalUnit: "bytes", consumedUTF16Length: m.range.length)
            case "gb", "gigabyte", "gigabytes":
                return MatchedUnitInfo(family: .memory, multiplier: 1e9, canonicalUnit: "bytes", consumedUTF16Length: m.range.length)
            case "tb", "terabyte", "terabytes":
                return MatchedUnitInfo(family: .memory, multiplier: 1e12, canonicalUnit: "bytes", consumedUTF16Length: m.range.length)
            case "kib":
                return MatchedUnitInfo(family: .memory, multiplier: 1024.0, canonicalUnit: "bytes", consumedUTF16Length: m.range.length)
            case "mib":
                return MatchedUnitInfo(family: .memory, multiplier: 1_048_576.0, canonicalUnit: "bytes", consumedUTF16Length: m.range.length)
            case "gib":
                return MatchedUnitInfo(family: .memory, multiplier: 1_073_741_824.0, canonicalUnit: "bytes", consumedUTF16Length: m.range.length)
            case "tib":
                return MatchedUnitInfo(family: .memory, multiplier: 1_099_511_627_776.0, canonicalUnit: "bytes", consumedUTF16Length: m.range.length)
            case "percent":
                return MatchedUnitInfo(family: .percent, multiplier: 1.0, canonicalUnit: "%", consumedUTF16Length: m.range.length)
            case "rps", "qps":
                return MatchedUnitInfo(family: .rate, multiplier: 1.0, canonicalUnit: "rate_per_s", consumedUTF16Length: m.range.length)
            case "hz":
                return MatchedUnitInfo(family: .rate, multiplier: 1.0, canonicalUnit: "Hz", consumedUTF16Length: m.range.length)
            case "khz":
                return MatchedUnitInfo(family: .rate, multiplier: 1e3, canonicalUnit: "Hz", consumedUTF16Length: m.range.length)
            case "mhz":
                return MatchedUnitInfo(family: .rate, multiplier: 1e6, canonicalUnit: "Hz", consumedUTF16Length: m.range.length)
            case "ghz":
                return MatchedUnitInfo(family: .rate, multiplier: 1e9, canonicalUnit: "Hz", consumedUTF16Length: m.range.length)
            case "flops":
                return MatchedUnitInfo(family: .rate, multiplier: 1.0, canonicalUnit: "FLOPS", consumedUTF16Length: m.range.length)
            case "gflops":
                return MatchedUnitInfo(family: .rate, multiplier: 1e9, canonicalUnit: "FLOPS", consumedUTF16Length: m.range.length)
            case "tflops":
                return MatchedUnitInfo(family: .rate, multiplier: 1e12, canonicalUnit: "FLOPS", consumedUTF16Length: m.range.length)
            case "pflops":
                return MatchedUnitInfo(family: .rate, multiplier: 1e15, canonicalUnit: "FLOPS", consumedUTF16Length: m.range.length)
            case "bps":
                return MatchedUnitInfo(family: .rate, multiplier: 1.0, canonicalUnit: "bps", consumedUTF16Length: m.range.length)
            case "kbps":
                return MatchedUnitInfo(family: .rate, multiplier: 1e3, canonicalUnit: "bps", consumedUTF16Length: m.range.length)
            case "mbps":
                return MatchedUnitInfo(family: .rate, multiplier: 1e6, canonicalUnit: "bps", consumedUTF16Length: m.range.length)
            case "gbps":
                return MatchedUnitInfo(family: .rate, multiplier: 1e9, canonicalUnit: "bps", consumedUTF16Length: m.range.length)
            default:
                if unitTok == "B" {
                    return MatchedUnitInfo(family: .memory, multiplier: 1.0, canonicalUnit: "bytes", consumedUTF16Length: m.range.length)
                }
            }
        }

        return nil
    }

    private static func matchPostfixMetric(in afterSub: String) -> (canonicalMetric: String, consumedUTF16Length: Int)? {
        let ns = afterSub as NSString
        guard let rx = try? NSRegularExpression(
            pattern: #"^\s+(BLEU|ROUGE(?:-[12L])?|F1(?:-score)?|AUROC|AUC|MMLU|PPL|PABAK|RMSE|MAE|IoU|mAP)\b"#,
            options: [.caseInsensitive]
        ),
        let m = rx.firstMatch(in: afterSub, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let raw = ns.substring(with: m.range(at: 1))
        return (canonicalizeMetricName(raw), m.range.length)
    }

    private static func matchChineseClassifierNoun(
        in afterSub: String
    ) -> (headNoun: String, modifiers: Set<String>, consumedUTF16Length: Int)? {
        let ns = afterSub as NSString
        guard let rx = try? NSRegularExpression(
            pattern: #"^\s*([个条篇次项轮层组类种名位台张批套步份例段句词字])([\u4E00-\u9FFF]{1,8})"#
        ),
        let m = rx.firstMatch(in: afterSub, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let clfRange = m.range(at: 1)
        let rawTail = ns.substring(with: m.range(at: 2))
        let stopChars = CharacterSet(charactersIn: "的了着过在上下中里内外和与及或并而但是为有被把对向从以将")
        let nounSlice: String
        if let stopRange = rawTail.rangeOfCharacter(from: stopChars) {
            nounSlice = String(rawTail[..<stopRange.lowerBound])
        } else {
            nounSlice = rawTail
        }
        guard !nounSlice.isEmpty else { return nil }
        let consumed = clfRange.location + clfRange.length + (nounSlice as NSString).length

        let chars = Array(nounSlice)
        let head: String
        var mods = Set<String>()
        if chars.count >= 4 {
            head = String(chars.suffix(2))
            for i in 0..<(chars.count - 1) {
                mods.insert(String([chars[i], chars[i + 1]]))
            }
        } else {
            head = nounSlice
            if chars.count == 3 {
                mods.insert(String(chars.suffix(2)))
            }
        }
        return (head, mods, consumed)
    }

    private static func isRegularPastParticiple(_ lowerWord: String) -> Bool {
        guard lowerWord.count >= 4, lowerWord.hasSuffix("ed") else { return false }
        if lowerWord.hasSuffix("eed") || lowerWord.hasSuffix("bed") || lowerWord.hasSuffix("shed") || lowerWord.hasSuffix("sled") {
            return false
        }
        return true
    }

    private static func looksPluralCountNoun(_ lowerWord: String) -> Bool {
        guard lowerWord.count >= 4, lowerWord.hasSuffix("s") else { return false }
        for nonPluralSuffix in ["ss", "us", "is", "as", "os", "ics", "news", "means"] {
            if lowerWord.hasSuffix(nonPluralSuffix) { return false }
        }
        return true
    }

    private static func scanParenOfEnglishNounPhrase(
        in afterSub: String
    ) -> (headNoun: String?, modifiers: Set<String>, consumedUTF16Length: Int) {
        let ns = afterSub as NSString
        guard let prefixRx = try? NSRegularExpression(
            pattern: #"^\s*\)\s+of(?:\s+(?:the|these|those|our|their|its))?(?=\s+[A-Za-z])"#,
            options: [.caseInsensitive]
        ),
        let pm = prefixRx.firstMatch(in: afterSub, range: NSRange(location: 0, length: ns.length)) else {
            return (nil, [], 0)
        }
        let prefixLen = pm.range.length
        let remainder = ns.substring(from: prefixLen)
        let (head, mods, remLen) = scanTrailingEnglishNounPhrase(in: remainder)
        guard let head, remLen > 0 else {
            return (nil, [], 0)
        }
        return (head, mods, prefixLen + remLen)
    }

    private static func scanTrailingEnglishNounPhrase(
        in afterSub: String
    ) -> (headNoun: String?, modifiers: Set<String>, consumedUTF16Length: Int) {
        let ns = afterSub as NSString
        guard let firstWordRegex = try? NSRegularExpression(pattern: #"\G(?:\s+|-)([A-Za-z][A-Za-z0-9-]*)"#),
              let nextWordRegex = try? NSRegularExpression(pattern: #"\G\s+([A-Za-z][A-Za-z0-9-]*)"#) else {
            return (nil, [], 0)
        }

        var cursor = 0
        var collected: [(word: String, stem: String, modifierToken: String, endOffset: Int, isModifierOnly: Bool)] = []

        while cursor < ns.length && collected.count < 4 {
            let searchRange = NSRange(location: cursor, length: ns.length - cursor)
            let activeRegex = cursor == 0 ? firstWordRegex : nextWordRegex
            guard let m = activeRegex.firstMatch(in: afterSub, range: searchRange),
                  m.range.location == cursor else {
                break
            }
            let rawWord = ns.substring(with: m.range(at: 1))
            let low = rawWord.lowercased()
            if nounBoundaryStopwords.contains(low) {
                break
            }
            if low.count < 2 {
                break
            }

            let priorHeadCandidates = collected.filter { !$0.isModifierOnly }
            if !priorHeadCandidates.isEmpty {
                // Once at least one noun has been collected (`19 datasets ...`, `12 pretrained models ...`),
                // stop immediately at past participles (`grouped`, `trained`), post-nominal irregular participles,
                // post-nominal adverbs, or present participles following a plural noun (`tests covering ...`).
                if isRegularPastParticiple(low) || postNominalIrregularParticiples.contains(low) {
                    break
                }
                if postNominalAdverbs.contains(low) || (low.count >= 5 && low.hasSuffix("ly")) {
                    break
                }
                if let lastNoun = priorHeadCandidates.last, looksPluralCountNoun(lastNoun.word.lowercased()) {
                    if (low.count >= 5 && low.hasSuffix("ing")) || postNominalUninflectedParticiplesAfterPlural.contains(low) {
                        break
                    }
                }
            }

            let isAdjOrPreParticiple = leadingAdjectiveModifiers.contains(low)
                || isRegularPastParticiple(low)
                || (low.count >= 5 && low.hasSuffix("ly"))
            let stem = stemEnglishWord(low.components(separatedBy: "-").last ?? low)
            // Keep hyphenated compound modifiers (`multi-head`, `per-layer`) intact so they do not masquerade as bare nouns (`head`, `layer`)
            let modTok = low.contains("-") ? low : stem
            let endPos = m.range.location + m.range.length
            collected.append((rawWord, stem, modTok, endPos, isAdjOrPreParticiple))
            cursor = endPos

            let nonModCount = collected.filter { !$0.isModifierOnly }.count
            if nonModCount >= 3 {
                break
            }
        }

        // Trim trailing pure adjectives or participles if no head noun followed them
        while let last = collected.last, last.isModifierOnly {
            collected.removeLast()
        }

        guard let headItem = collected.last else {
            return (nil, [], 0)
        }
        let mods = Set(collected.dropLast().filter { !$0.isModifierOnly }.map(\.modifierToken))
            .union(collected.dropLast().filter { $0.isModifierOnly && !leadingAdjectiveModifiers.contains($0.word.lowercased()) }.map(\.modifierToken))
        return (headItem.stem, mods, headItem.endOffset)
    }

    private static func scanTrailingChineseNoun(in afterSub: String) -> String? {
        let ns = afterSub as NSString
        guard let rx = try? NSRegularExpression(pattern: #"^\s*(?:的\s*)?([\u4E00-\u9FFF]{2,6})"#),
              let m = rx.firstMatch(in: afterSub, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let raw = ns.substring(with: m.range(at: 1))
        let chars = Array(raw)
        return chars.count >= 4 ? String(chars.suffix(2)) : raw
    }

    private static func isPrecededByStructuralReferenceLabel(beforeSub: String, afterSub: String) -> Bool {
        let trimmedBefore = beforeSub.trimmingCharacters(in: .whitespaces)
        // Check English structural label immediately before number (allowing optional `.` or `(`)
        if let rx = try? NSRegularExpression(pattern: #"([A-Za-z]+)\.?\s*\(?$"#, options: [.caseInsensitive]),
           let m = rx.firstMatch(in: trimmedBefore, range: NSRange(location: 0, length: (trimmedBefore as NSString).length)) {
            let word = (trimmedBefore as NSString).substring(with: m.range(at: 1)).lowercased()
            if structuralReferenceLabels.contains(word) {
                return true
            }
        }
        // Check page range second half `pp. 41--52` or `41–52` preceded by `pp.`/`p.`
        if beforeSub.range(of: #"\bpp?\.\s*\d+\s*[–—-]+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        // Check Chinese structural label (`第 3 节`, `图 2`, `表 1`)
        if trimmedBefore.hasSuffix("第") && afterSub.range(of: #"^\s*[章节页图表式卷期部分]"#, options: .regularExpression) != nil {
            return true
        }
        if let lastChar = trimmedBefore.last, "图表式".contains(lastChar) {
            return true
        }
        return false
    }

    private static func startsWithLowercasePluralNoun(_ afterSub: String) -> Bool {
        let trimmed = afterSub.trimmingCharacters(in: .whitespaces)
        let firstToken = String(trimmed.prefix(while: { $0.isLetter || $0 == "-" }))
        guard let firstChar = firstToken.first, firstChar.isLowercase else { return false }
        return firstToken.hasSuffix("s") && !firstToken.hasSuffix("ss") && firstToken.count >= 4
    }

    private static func isLikelyIsolatedYear(
        value: Double,
        literal: String,
        followedByCountNoun: Bool,
        isYearSuffix: Bool
    ) -> Bool {
        if isYearSuffix { return true }
        guard !literal.contains(","), !literal.contains(".") else { return false }
        guard value >= 1900.0 && value <= 2099.0 else { return false }
        return !followedByCountNoun
    }

    private static func countCJKIdeographs(in text: String) -> Int {
        text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
    }

    internal static func parseCleanDouble(_ literal: String) -> Double? {
        let clean = literal
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Double(clean)
    }

    internal static func halfULPTolerance(forLiteral literal: String) -> Double {
        let clean = literal
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let dotIdx = clean.firstIndex(of: ".") else {
            return 0.0
        }
        let fracPart = clean[clean.index(after: dotIdx)...]
        let digits = fracPart.prefix(while: \.isNumber).count
        guard digits > 0 else { return 0.0 }
        return 0.5 * Foundation.pow(10.0, -Double(digits))
    }

    private static func parseOperator(_ raw: String) -> QuantitativeComparisonOperator {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "<": return .lessThan
        case "<=": return .lessThanOrEqual
        case ">": return .greaterThan
        case ">=": return .greaterThanOrEqual
        case "≈": return .approximatelyEqual
        default: return .equal
        }
    }

    internal static func canonicalizeMetricName(_ raw: String) -> String {
        let up = raw.uppercased()
        if up.hasPrefix("F1") { return "F1" }
        if up == "AUROC" || up == "AUC" { return "AUC" }
        if up == "PPL" || up == "PERPLEXITY" { return "PPL" }
        if up == "Κ" || up == "KAPPA" { return "KAPPA" }
        return up
    }

    internal static func isUnitIntervalMetric(_ canonicalName: String) -> Bool {
        switch canonicalName {
        case "F1", "AUC", "ACCURACY", "PRECISION", "RECALL", "IOU", "MAP":
            return true
        default:
            return false
        }
    }

    private static func computeInMemoryBM25(
        queryKeywords: [String],
        passages: [PDFPassageChunk]
    ) -> [String: Double] {
        guard !passages.isEmpty, !queryKeywords.isEmpty else { return [:] }
        let nDocs = passages.count
        let tokenizedDocs = passages.map { extractQueryKeywords(from: $0.sectionTitle + " " + $0.passageText) }
        let avgDocLen = max(1.0, Double(tokenizedDocs.reduce(0) { $0 + $1.count }) / Double(nDocs))

        var dfMap: [String: Int] = [:]
        for term in queryKeywords {
            dfMap[term] = tokenizedDocs.filter { $0.contains(term) }.count
        }

        let k1 = 1.5
        let b = 0.75
        var out: [String: Double] = [:]

        for (idx, chunk) in passages.enumerated() {
            let docTokens = tokenizedDocs[idx]
            let docLen = Double(max(1, docTokens.count))
            var tfByTerm: [String: Int] = [:]
            for t in docTokens {
                tfByTerm[t, default: 0] += 1
            }

            var bm25 = 0.0
            for q in queryKeywords {
                let tf = Double(tfByTerm[q] ?? 0)
                guard tf > 0.0 else { continue }
                let df = Double(dfMap[q] ?? 0)
                let idf = Foundation.log(1.0 + (Double(nDocs) - df + 0.5) / (df + 0.5))
                let numer = tf * (k1 + 1.0)
                let denom = tf + k1 * (1.0 - b + b * (docLen / avgDocLen))
                bm25 += idf * (numer / denom)
            }
            out[chunk.id] = bm25
        }
        return out
    }
}
