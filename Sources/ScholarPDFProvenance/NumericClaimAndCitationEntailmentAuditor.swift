import Foundation
import ScholarModels

// MARK: - Quantitative Claim Taxonomy & Unit-Canonicalized Extraction Models

/// Semantic family of a quantitative expression extracted from academic prose or PDF evidence chunks.
public enum QuantitativeQuantityKind: String, Sendable, Codable, Hashable, CaseIterable {
    case percentage = "Percentage"
    case speedupOrMultiplier = "Speedup / Fold Multiplier"
    case latencyOrDuration = "Latency / Duration"
    case memoryOrStorage = "Memory / Storage Footprint"
    case throughputRate = "Throughput / Bandwidth"
    case pValueSignificance = "Statistical p-Value"
    case sampleSize = "Sample Size (N / n)"
    case namedMetricScore = "Evaluation Metric Score"
    case confidenceIntervalBound = "Confidence Interval"
    case dimensionlessScalar = "Scalar Quantity"
}

/// Relational operator attached to a quantitative claim (e.g. `p < 0.001`, `N = 1,240`, `>= 95%`).
public enum QuantitativeRelationOperator: String, Sendable, Codable, Hashable, CaseIterable {
    case equal = "="
    case approximatelyEqual = "≈"
    case lessThan = "<"
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
}

/// Structured representation of a numeric claim token with SI/canonical unit normalization and rounding precision metadata.
public struct ExtractedQuantitativeToken: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(kind.rawValue):\(rawSurfaceText)@\(characterOffset)" }
    public let kind: QuantitativeQuantityKind
    public let rawSurfaceText: String
    public let metricIdentifier: String?
    public let relation: QuantitativeRelationOperator
    public let rawNumericValue: Double
    /// Value normalized to canonical base unit (`seconds` for latency, `bytes` for memory, `[0, 100]` for percentages, raw scale otherwise).
    public let canonicalValue: Double
    public let canonicalUnit: String
    /// Optional upper bound when token represents a range or confidence interval `[low, high]`.
    public let secondaryUpperValue: Double?
    /// Half-ULP of the printed decimal places (e.g. `94.2%` -> `0.05`, `88.74` -> `0.005`) for legitimate rounding verification.
    public let halfLastDecimalPlaceTolerance: Double
    public let characterOffset: Int

    public init(
        kind: QuantitativeQuantityKind,
        rawSurfaceText: String,
        metricIdentifier: String? = nil,
        relation: QuantitativeRelationOperator = .equal,
        rawNumericValue: Double,
        canonicalValue: Double,
        canonicalUnit: String,
        secondaryUpperValue: Double? = nil,
        halfLastDecimalPlaceTolerance: Double = 0.05,
        characterOffset: Int = 0
    ) {
        self.kind = kind
        self.rawSurfaceText = rawSurfaceText
        self.metricIdentifier = metricIdentifier
        self.relation = relation
        self.rawNumericValue = rawNumericValue
        self.canonicalValue = canonicalValue
        self.canonicalUnit = canonicalUnit
        self.secondaryUpperValue = secondaryUpperValue
        self.halfLastDecimalPlaceTolerance = max(1e-8, halfLastDecimalPlaceTolerance)
        self.characterOffset = characterOffset
    }
}

/// Sentence extracted from a LaTeX, Typst, or Markdown manuscript containing one or more citation keys.
public struct ManuscriptCitedSentence: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(filePath):\(startLine):\(citeKeysInSentence.joined(separator: ","))" }
    public let filePath: String
    public let startLine: Int
    public let endLine: Int
    public let span: TextSpan
    public let rawSentence: String
    public let plainNormalizedSentence: String
    public let citeKeysInSentence: [String]
    /// Clause-attributed quantitative claims mapped to each cited key in this sentence.
    public let attributedQuantitiesByCiteKey: [String: [ExtractedQuantitativeToken]]
    public let hasNegationCue: Bool

    public init(
        filePath: String,
        startLine: Int,
        endLine: Int,
        span: TextSpan,
        rawSentence: String,
        plainNormalizedSentence: String,
        citeKeysInSentence: [String],
        attributedQuantitiesByCiteKey: [String: [ExtractedQuantitativeToken]],
        hasNegationCue: Bool
    ) {
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.span = span
        self.rawSentence = rawSentence
        self.plainNormalizedSentence = plainNormalizedSentence
        self.citeKeysInSentence = citeKeysInSentence
        self.attributedQuantitiesByCiteKey = attributedQuantitiesByCiteKey
        self.hasNegationCue = hasNegationCue
    }
}

// MARK: - Quantitative Alignment & Discrepancy Explanation Models

public enum NumericAlignmentClassification: String, Sendable, Codable, Hashable, CaseIterable {
    case exactCanonicalMatch = "EXACT_MATCH"
    case unitConvertedEquivalent = "UNIT_CONVERTED_MATCH"
    case withinRoundingTolerance = "ROUNDING_COMPATIBLE"
    case pValueInequalityEntailed = "P_VALUE_ENTAILED"
    case valueMismatchDistortion = "VALUE_DISTORTION"
    case pValueSignificanceInflation = "SIGNIFICANCE_INFLATION"
    case missingQuantityInPDF = "QUANTITY_NOT_IN_EXCERPT"
}

/// Surgical diagnostic explaining why each extracted number in a manuscript claim matched or conflicted with the source PDF.
public struct NumericTokenComparisonDetail: Sendable, Codable, Hashable, Identifiable {
    public var id: String { claimToken.id }
    public let claimToken: ExtractedQuantitativeToken
    public let closestPDFToken: ExtractedQuantitativeToken?
    public let classification: NumericAlignmentClassification
    public let relativeErrorPercent: Double?
    public let explanation: String

    public init(
        claimToken: ExtractedQuantitativeToken,
        closestPDFToken: ExtractedQuantitativeToken?,
        classification: NumericAlignmentClassification,
        relativeErrorPercent: Double?,
        explanation: String
    ) {
        self.claimToken = claimToken
        self.closestPDFToken = closestPDFToken
        self.classification = classification
        self.relativeErrorPercent = relativeErrorPercent
        self.explanation = explanation
    }

    public var isCompatible: Bool {
        switch classification {
        case .exactCanonicalMatch, .unitConvertedEquivalent, .withinRoundingTolerance, .pValueInequalityEntailed:
            return true
        case .valueMismatchDistortion, .pValueSignificanceInflation, .missingQuantityInPDF:
            return false
        }
    }
}

/// Rich entailment audit record pairing `ClaimEvidenceProvenance` with granular numeric-mismatch diagnostics and polarity checks.
public struct DetailedClaimEntailmentAudit: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID { provenance.id }
    public let provenance: ClaimEvidenceProvenance
    public let span: TextSpan
    public let lexicalTermCoverage: Double
    public let polarityContradictionDetected: Bool
    public let numericComparisons: [NumericTokenComparisonDetail]
    public let auditExplanationSummary: String
    public let suggestedCorrectionHint: String?

    public init(
        provenance: ClaimEvidenceProvenance,
        span: TextSpan,
        lexicalTermCoverage: Double,
        polarityContradictionDetected: Bool,
        numericComparisons: [NumericTokenComparisonDetail],
        auditExplanationSummary: String,
        suggestedCorrectionHint: String?
    ) {
        self.provenance = provenance
        self.span = span
        self.lexicalTermCoverage = lexicalTermCoverage
        self.polarityContradictionDetected = polarityContradictionDetected
        self.numericComparisons = numericComparisons
        self.auditExplanationSummary = auditExplanationSummary
        self.suggestedCorrectionHint = suggestedCorrectionHint
    }
}

/// Manuscript-wide summary report aggregating entailment verdicts and LSP/Editorial diagnostics.
public struct ManuscriptProvenanceAuditReport: Sendable, Codable, Hashable {
    public let manuscriptFile: String
    public let totalCitedClaimsAudited: Int
    public let groundedEntailmentCount: Int
    public let partialEvidenceCount: Int
    public let numericDiscrepancyCount: Int
    public let unsupportedClaimCount: Int
    public let quantitativeClaimAccuracyRate: Double
    public let claimAudits: [DetailedClaimEntailmentAudit]
    public let lspDiagnostics: [LSPDiagnostic]
    public let editorialFindings: [EditorialAuditFinding]

    public init(
        manuscriptFile: String,
        totalCitedClaimsAudited: Int,
        groundedEntailmentCount: Int,
        partialEvidenceCount: Int,
        numericDiscrepancyCount: Int,
        unsupportedClaimCount: Int,
        quantitativeClaimAccuracyRate: Double,
        claimAudits: [DetailedClaimEntailmentAudit],
        lspDiagnostics: [LSPDiagnostic],
        editorialFindings: [EditorialAuditFinding]
    ) {
        self.manuscriptFile = manuscriptFile
        self.totalCitedClaimsAudited = totalCitedClaimsAudited
        self.groundedEntailmentCount = groundedEntailmentCount
        self.partialEvidenceCount = partialEvidenceCount
        self.numericDiscrepancyCount = numericDiscrepancyCount
        self.unsupportedClaimCount = unsupportedClaimCount
        self.quantitativeClaimAccuracyRate = quantitativeClaimAccuracyRate
        self.claimAudits = claimAudits
        self.lspDiagnostics = lspDiagnostics
        self.editorialFindings = editorialFindings
    }
}

// MARK: - Numeric Claim Extractor & Citation Entailment Auditor Engine

/// Extracts quantitative claims near `\cite{key}` / `@key` and cross-verifies them against `PDFPassageChunk` evidence with unit canonicalization, rounding tolerance, p-value inequality logic, and negation-inversion detection.
public struct NumericClaimAndCitationEntailmentAuditor: Sendable {
    public let relativeRoundingFallbackTolerance: Double
    public let minimumGroundedLexicalCoverage: Double

    public init(
        relativeRoundingFallbackTolerance: Double = 0.012,
        minimumGroundedLexicalCoverage: Double = 0.34
    ) {
        self.relativeRoundingFallbackTolerance = max(0.0, relativeRoundingFallbackTolerance)
        self.minimumGroundedLexicalCoverage = min(1.0, max(0.05, minimumGroundedLexicalCoverage))
    }

    // MARK: 1. Quantitative Claim Extraction from Academic Prose & PDF Passages

    /// Extracts percentages (`94.2%`), speedups (`3.4x`), latencies (`6.4 ms`), memory (`48 GB`), throughputs (`1,420 req/s`), $p$-values (`p < 0.001`), sample sizes (`N = 1,240`), CIs, and metric scores (`F1 = 88.7`) from text.
    public func extractQuantitativeTokens(from rawText: String) -> [ExtractedQuantitativeToken] {
        let normalized = Self.normalizeMarkupNumericSyntax(rawText)
        let ns = normalized as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        var occupiedRanges: [NSRange] = []
        var extracted: [ExtractedQuantitativeToken] = []

        func claimRangeIfFree(_ range: NSRange) -> Bool {
            guard range.location != NSNotFound, range.length > 0 else { return false }
            for existing in occupiedRanges {
                if NSIntersectionRange(existing, range).length > 0 {
                    return false
                }
            }
            occupiedRanges.append(range)
            return true
        }

        // Pattern 1: Statistical p-values (e.g. `p < 0.001`, `p = 0.042`, `p <= 0.05`, `p > 0.10`)
        if let pRegex = try? NSRegularExpression(
            pattern: #"\bp(?:-value)?\s*(<=|>=|<|>|=|≈)\s*(0?\.\d+|1(?:\.0+)?|\d+(?:\.\d+)?e-\d+)\b"#,
            options: [.caseInsensitive]
        ) {
            for m in pRegex.matches(in: normalized, range: fullRange) where claimRangeIfFree(m.range) {
                let opStr = ns.substring(with: m.range(at: 1))
                let valStr = ns.substring(with: m.range(at: 2))
                if let val = Self.parseCleanDouble(valStr) {
                    extracted.append(
                        ExtractedQuantitativeToken(
                            kind: .pValueSignificance,
                            rawSurfaceText: ns.substring(with: m.range),
                            metricIdentifier: "p-value",
                            relation: Self.parseOperator(opStr),
                            rawNumericValue: val,
                            canonicalValue: val,
                            canonicalUnit: "p",
                            halfLastDecimalPlaceTolerance: Self.halfULPTolerance(forLiteral: valStr),
                            characterOffset: m.range.location
                        )
                    )
                }
            }
        }

        // Pattern 2: Confidence Intervals (e.g. `95% CI [0.74, 0.89]` or `95% CI: 1.12 to 1.84` or `CI [81.2, 86.4]`)
        if let ciRegex = try? NSRegularExpression(
            pattern: #"(?:\b\d{2}%\s*)?\bCI\s*[:=]?\s*[\[\(]?\s*(-?\d+(?:\.\d+)?)\s*(?:,|to|–|—|-)\s*(-?\d+(?:\.\d+)?)\s*[\]\)]?"#,
            options: [.caseInsensitive]
        ) {
            for m in ciRegex.matches(in: normalized, range: fullRange) where claimRangeIfFree(m.range) {
                let loStr = ns.substring(with: m.range(at: 1))
                let hiStr = ns.substring(with: m.range(at: 2))
                if let lo = Self.parseCleanDouble(loStr), let hi = Self.parseCleanDouble(hiStr) {
                    extracted.append(
                        ExtractedQuantitativeToken(
                            kind: .confidenceIntervalBound,
                            rawSurfaceText: ns.substring(with: m.range),
                            metricIdentifier: "CI",
                            relation: .equal,
                            rawNumericValue: lo,
                            canonicalValue: lo,
                            canonicalUnit: "interval",
                            secondaryUpperValue: hi,
                            halfLastDecimalPlaceTolerance: max(
                                Self.halfULPTolerance(forLiteral: loStr),
                                Self.halfULPTolerance(forLiteral: hiStr)
                            ),
                            characterOffset: m.range.location
                        )
                    )
                }
            }
        }

        // Pattern 3: Sample sizes (e.g. `N = 1,240`, `n = 48`, `N >= 500`)
        if let nRegex = try? NSRegularExpression(
            pattern: #"\b([Nn])\s*(<=|>=|<|>|=|≈)\s*(\d{1,3}(?:,\d{3})+|\d+)\b"#
        ) {
            for m in nRegex.matches(in: normalized, range: fullRange) where claimRangeIfFree(m.range) {
                let sym = ns.substring(with: m.range(at: 1))
                let opStr = ns.substring(with: m.range(at: 2))
                let valStr = ns.substring(with: m.range(at: 3))
                if let val = Self.parseCleanDouble(valStr) {
                    extracted.append(
                        ExtractedQuantitativeToken(
                            kind: .sampleSize,
                            rawSurfaceText: ns.substring(with: m.range),
                            metricIdentifier: sym.uppercased(),
                            relation: Self.parseOperator(opStr),
                            rawNumericValue: val,
                            canonicalValue: val,
                            canonicalUnit: "subjects",
                            halfLastDecimalPlaceTolerance: 0.5,
                            characterOffset: m.range.location
                        )
                    )
                }
            }
        }

        // Pattern 4: Named Benchmark & Psychometric Metric Scores (e.g. `F1 = 88.7`, `F1-score of 91.4%`, `AUC = 0.942`, `BLEU = 34.8`, `ROUGE-L = 41.2`, `pass@1 = 76.4%`, `accuracy = 94.2%`)
        if let metricRegex = try? NSRegularExpression(
            pattern: #"\b(F1(?:-score)?|AUROC|AUC|BLEU|ROUGE(?:-[12L])?|MMLU|pass@\d+|accuracy|precision|recall|perplexity|PPL|kappa|κ|PABAK|RMSE|MAE|IoU|mAP)\s*(?:score\s*)?(?:of\s*|is\s*|<=|>=|<|>|=|≈)\s*(\d+(?:\.\d+)?)(%?)"#,
            options: [.caseInsensitive]
        ) {
            for m in metricRegex.matches(in: normalized, range: fullRange) where claimRangeIfFree(m.range) {
                let rawMetric = ns.substring(with: m.range(at: 1))
                let valStr = ns.substring(with: m.range(at: 2))
                let pctSuffix = ns.substring(with: m.range(at: 3))
                if let val = Self.parseCleanDouble(valStr) {
                    let canonMetric = Self.canonicalizeMetricName(rawMetric)
                    let isPct = !pctSuffix.isEmpty
                    // Normalize 0.887 vs 88.7 for bounded [0,1]/[0,100] metrics such as F1, AUC, accuracy, precision, recall
                    let canonVal: Double
                    if !isPct && val <= 1.0 && Self.isUnitIntervalMetric(canonMetric) {
                        canonVal = val * 100.0
                    } else {
                        canonVal = val
                    }
                    let tol = !isPct && val <= 1.0 && Self.isUnitIntervalMetric(canonMetric)
                        ? Self.halfULPTolerance(forLiteral: valStr) * 100.0
                        : Self.halfULPTolerance(forLiteral: valStr)

                    extracted.append(
                        ExtractedQuantitativeToken(
                            kind: isPct ? .percentage : .namedMetricScore,
                            rawSurfaceText: ns.substring(with: m.range),
                            metricIdentifier: canonMetric,
                            relation: .equal,
                            rawNumericValue: val,
                            canonicalValue: canonVal,
                            canonicalUnit: isPct || Self.isUnitIntervalMetric(canonMetric) ? "pts_100" : "score",
                            halfLastDecimalPlaceTolerance: tol,
                            characterOffset: m.range.location
                        )
                    )
                }
            }
        }

        // Pattern 5: Speedups & Multipliers (`3.4x`, `3.4×`, `12.5-fold`)
        if let speedupRegex = try? NSRegularExpression(
            pattern: #"\b(\d+(?:\.\d+)?)\s*(?:x|×|-fold)\b"#,
            options: [.caseInsensitive]
        ) {
            for m in speedupRegex.matches(in: normalized, range: fullRange) where claimRangeIfFree(m.range) {
                let valStr = ns.substring(with: m.range(at: 1))
                if let val = Self.parseCleanDouble(valStr) {
                    extracted.append(
                        ExtractedQuantitativeToken(
                            kind: .speedupOrMultiplier,
                            rawSurfaceText: ns.substring(with: m.range),
                            metricIdentifier: "multiplier",
                            relation: .equal,
                            rawNumericValue: val,
                            canonicalValue: val,
                            canonicalUnit: "x",
                            halfLastDecimalPlaceTolerance: Self.halfULPTolerance(forLiteral: valStr),
                            characterOffset: m.range.location
                        )
                    )
                }
            }
        }

        // Pattern 6: Latency / Duration (`6.4 ms`, `180 us`, `180 μs`, `42 ns`, `2.4 s`, `12.5 min`)
        if let latencyRegex = try? NSRegularExpression(
            pattern: #"\b(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)\s*(ns|us|μs|µs|microseconds?|ms|milliseconds?|s|sec|seconds?|min|minutes?)\b"#,
            options: [.caseInsensitive]
        ) {
            for m in latencyRegex.matches(in: normalized, range: fullRange) where claimRangeIfFree(m.range) {
                let valStr = ns.substring(with: m.range(at: 1))
                let unitStr = ns.substring(with: m.range(at: 2))
                if let val = Self.parseCleanDouble(valStr) {
                    let scale = Self.durationToSecondsMultiplier(unitStr)
                    extracted.append(
                        ExtractedQuantitativeToken(
                            kind: .latencyOrDuration,
                            rawSurfaceText: ns.substring(with: m.range),
                            metricIdentifier: "duration",
                            relation: .equal,
                            rawNumericValue: val,
                            canonicalValue: val * scale,
                            canonicalUnit: "s",
                            halfLastDecimalPlaceTolerance: Self.halfULPTolerance(forLiteral: valStr) * scale,
                            characterOffset: m.range.location
                        )
                    )
                }
            }
        }

        // Pattern 7: Throughput & Memory (`1,240 req/s`, `480 tok/s`, `48 GB`, `512 MB`, `64 KiB`, `24.6 TFLOPS`)
        if let sysUnitRegex = try? NSRegularExpression(
            pattern: #"\b(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)\s*(KiB|KB|MiB|MB|GiB|GB|TiB|TB|req/s|ops/s|tok/s|tokens/s|RPS|QPS|GFLOPS|TFLOPS)\b"#,
            options: [.caseInsensitive]
        ) {
            for m in sysUnitRegex.matches(in: normalized, range: fullRange) where claimRangeIfFree(m.range) {
                let valStr = ns.substring(with: m.range(at: 1))
                let unitStr = ns.substring(with: m.range(at: 2))
                if let val = Self.parseCleanDouble(valStr) {
                    let (kind, mult, canonUnit) = Self.systemUnitCanonicalizer(unitStr)
                    extracted.append(
                        ExtractedQuantitativeToken(
                            kind: kind,
                            rawSurfaceText: ns.substring(with: m.range),
                            metricIdentifier: canonUnit,
                            relation: .equal,
                            rawNumericValue: val,
                            canonicalValue: val * mult,
                            canonicalUnit: canonUnit,
                            halfLastDecimalPlaceTolerance: Self.halfULPTolerance(forLiteral: valStr) * mult,
                            characterOffset: m.range.location
                        )
                    )
                }
            }
        }

        // Pattern 8: Standalone Percentages (`94.2%`, `+12.4%`, `18.5 percentage points`)
        if let pctRegex = try? NSRegularExpression(
            pattern: #"([+-]?\d+(?:\.\d+)?)\s*(?:%|percentage\s+points?\b|pp\b)"#,
            options: [.caseInsensitive]
        ) {
            for m in pctRegex.matches(in: normalized, range: fullRange) where claimRangeIfFree(m.range) {
                let valStr = ns.substring(with: m.range(at: 1))
                if let val = Self.parseCleanDouble(valStr) {
                    let absVal = abs(val)
                    extracted.append(
                        ExtractedQuantitativeToken(
                            kind: .percentage,
                            rawSurfaceText: ns.substring(with: m.range),
                            metricIdentifier: nil,
                            relation: .equal,
                            rawNumericValue: absVal,
                            canonicalValue: absVal,
                            canonicalUnit: "%",
                            halfLastDecimalPlaceTolerance: Self.halfULPTolerance(forLiteral: valStr),
                            characterOffset: m.range.location
                        )
                    )
                }
            }
        }

        return extracted.sorted { $0.characterOffset < $1.characterOffset }
    }

    // MARK: 2. Citation-Scoped Sentence Segmenter & Clause Attribution

    /// Segments a manuscript (`LaTeX`, `Typst`, or `Markdown`) into line-tracked cited sentences and maps each quantitative token to its nearest governing citation key(s).
    public func extractCitedClaimSentences(
        manuscriptSource: String,
        filePath: String = "main.tex"
    ) -> [ManuscriptCitedSentence] {
        let rawSegments = Self.splitIntoSentenceSpans(source: manuscriptSource, filePath: filePath)
        var results: [ManuscriptCitedSentence] = []

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

            let allQuantities = extractQuantitativeTokens(from: seg.text)
            var attributed: [String: [ExtractedQuantitativeToken]] = [:]
            for k in orderedUniqueKeys {
                attributed[k] = []
            }

            if orderedUniqueKeys.count == 1 {
                attributed[orderedUniqueKeys[0]] = allQuantities
            } else if !allQuantities.isEmpty {
                // Multi-citation sentence: map each quantity to the citation group in the same semicolon/contrast clause,
                // preferring the closest subsequent citation (`3.4x \cite{a}, whereas 6.4 ms \cite{b}`)!
                let normText = Self.normalizeMarkupNumericSyntax(seg.text)
                let normOccs = Self.locateCitationOccurrences(in: normText)
                let effectiveOccs = normOccs.isEmpty ? citeOccurrences : normOccs

                for qToken in allQuantities {
                    let qPos = qToken.characterOffset
                    // Prefer earliest citation occurring at or after `qPos` before a contrast boundary (`, whereas`, `;`, `, while`),
                    // falling back to minimum absolute character distance.
                    let forwardCandidates = effectiveOccs.filter { $0.offset >= qPos }
                    let chosenOcc: CitationOccurrenceSpan?
                    if let fwd = forwardCandidates.min(by: { $0.offset < $1.offset }) {
                        chosenOcc = fwd
                    } else {
                        chosenOcc = effectiveOccs.min(by: { abs($0.offset - qPos) < abs($1.offset - qPos) })
                    }
                    if let chosenOcc {
                        for k in chosenOcc.citeKeys {
                            attributed[k, default: []].append(qToken)
                        }
                    }
                }
            }

            let plainSent = Self.stripMarkupCommandsToPlain(seg.text)
            let negCue = Self.containsNegationPolarity(plainSent)

            results.append(
                ManuscriptCitedSentence(
                    filePath: filePath,
                    startLine: seg.span.start.line,
                    endLine: seg.span.end.line,
                    span: seg.span,
                    rawSentence: trimmed,
                    plainNormalizedSentence: plainSent,
                    citeKeysInSentence: orderedUniqueKeys,
                    attributedQuantitiesByCiteKey: attributed,
                    hasNegationCue: negCue
                )
            )
        }

        return results
    }

    // MARK: 3. Cross-Verification Against PDFPassageChunks & FTS5ProvenanceIndex

    /// Audits an entire manuscript against an `FTS5ProvenanceIndex` and produces a full `ManuscriptProvenanceAuditReport`.
    public func auditManuscriptAgainstIndex(
        manuscriptSource: String,
        filePath: String = "main.tex",
        provenanceIndex: FTS5ProvenanceIndex
    ) throws -> ManuscriptProvenanceAuditReport {
        let citedSentences = extractCitedClaimSentences(manuscriptSource: manuscriptSource, filePath: filePath)
        var audits: [DetailedClaimEntailmentAudit] = []

        for sent in citedSentences {
            for citeKey in sent.citeKeysInSentence {
                let hits = try provenanceIndex.searchPassages(
                    query: sent.plainNormalizedSentence,
                    citeKeyFilter: citeKey,
                    limit: 5
                )
                let quantTokens = sent.attributedQuantitiesByCiteKey[citeKey] ?? []
                let audit = evaluateSingleCiteClaim(
                    sentence: sent,
                    citeKey: citeKey,
                    attributedQuantities: quantTokens,
                    candidatePassages: hits
                )
                audits.append(audit)
            }
        }

        return summarizeManuscriptAudit(manuscriptFile: filePath, audits: audits)
    }

    /// Audits an entire manuscript directly against in-memory `[PDFPassageChunk]` records (ideal for deterministic unit tests or ephemeral PDF fixtures without SQLite setup).
    public func auditManuscriptAgainstPassages(
        manuscriptSource: String,
        filePath: String = "main.tex",
        passages: [PDFPassageChunk]
    ) -> ManuscriptProvenanceAuditReport {
        var passagesByKey: [String: [PDFPassageChunk]] = [:]
        for chunk in passages {
            passagesByKey[chunk.citeKey, default: []].append(chunk)
        }

        let citedSentences = extractCitedClaimSentences(manuscriptSource: manuscriptSource, filePath: filePath)
        var audits: [DetailedClaimEntailmentAudit] = []

        for sent in citedSentences {
            for citeKey in sent.citeKeysInSentence {
                let pool = passagesByKey[citeKey] ?? []
                let ranked = rankInMemoryPassages(querySentence: sent.plainNormalizedSentence, passages: pool)
                let quantTokens = sent.attributedQuantitiesByCiteKey[citeKey] ?? []
                let audit = evaluateSingleCiteClaim(
                    sentence: sent,
                    citeKey: citeKey,
                    attributedQuantities: quantTokens,
                    candidatePassages: ranked
                )
                audits.append(audit)
            }
        }

        return summarizeManuscriptAudit(manuscriptFile: filePath, audits: audits)
    }

    /// Evaluates a single `(sentence, citeKey)` claim against ranked PDF passages, classifying `EvidenceSupportVerdict` and generating exact numeric-mismatch explanations.
    public func evaluateSingleCiteClaim(
        sentence: ManuscriptCitedSentence,
        citeKey: String,
        attributedQuantities: [ExtractedQuantitativeToken],
        candidatePassages: [(chunk: PDFPassageChunk, bm25Magnitude: Double)]
    ) -> DetailedClaimEntailmentAudit {
        guard !candidatePassages.isEmpty else {
            let unverifiedProv = ClaimEvidenceProvenance(
                manuscriptFile: sentence.filePath,
                manuscriptLine: sentence.startLine,
                manuscriptClaim: sentence.rawSentence,
                citeKey: citeKey,
                passageID: "\(citeKey)#unmatched",
                pdfExcerpt: "No indexed PDF passage matched citation '\(citeKey)'.",
                boundingBox: PDFPageRegionBox(pageIndex: 0, x: 0, y: 0, width: 0, height: 0),
                bm25Score: 0.0,
                verdict: .unsupportedClaim
            )
            return DetailedClaimEntailmentAudit(
                provenance: unverifiedProv,
                span: sentence.span,
                lexicalTermCoverage: 0.0,
                polarityContradictionDetected: false,
                numericComparisons: [],
                auditExplanationSummary: "No attached PDF passage for '\(citeKey)' shares topical vocabulary with this claim.",
                suggestedCorrectionHint: "Attach or re-index the source PDF for '\(citeKey)', or verify that '\\cite{\(citeKey)}' is the intended reference."
            )
        }

        let claimKeywords = Set(Self.extractContentKeywords(sentence.plainNormalizedSentence))

        // Evaluate top candidate passages and pick the one yielding best quantitative + lexical support
        var bestSelection: (
            chunk: PDFPassageChunk,
            bm25: Double,
            lexCov: Double,
            polarityClash: Bool,
            comparisons: [NumericTokenComparisonDetail]
        )?

        for cand in candidatePassages {
            let passageKeywords = Set(Self.extractContentKeywords(cand.chunk.passageText))
            let lexCov = claimKeywords.isEmpty
                ? 0.5
                : Double(claimKeywords.intersection(passageKeywords).count) / Double(claimKeywords.count)

            let passageHasNeg = Self.containsNegationPolarity(cand.chunk.passageText)
            let polarityClash = (sentence.hasNegationCue != passageHasNeg) && (lexCov >= 0.45) && Self.sharesDirectionalOutcomeVerb(sentence.plainNormalizedSentence, cand.chunk.passageText)

            let pdfQuantities = extractQuantitativeTokens(from: cand.chunk.passageText)
            let comparisons = attributedQuantities.map { claimTok in
                compareClaimToken(claimTok, againstPDFTokens: pdfQuantities)
            }

            if let currentBest = bestSelection {
                let candMatchedCount = comparisons.filter(\.isCompatible).count
                let bestMatchedCount = currentBest.comparisons.filter(\.isCompatible).count
                if candMatchedCount > bestMatchedCount
                    || (candMatchedCount == bestMatchedCount && (lexCov + cand.bm25Magnitude * 0.1) > (currentBest.lexCov + currentBest.bm25 * 0.1)) {
                    bestSelection = (cand.chunk, cand.bm25Magnitude, lexCov, polarityClash, comparisons)
                }
            } else {
                bestSelection = (cand.chunk, cand.bm25Magnitude, lexCov, polarityClash, comparisons)
            }
        }

        let chosen = bestSelection!
        let mismatchedDetails = chosen.comparisons.filter { !$0.isCompatible }

        let verdict: EvidenceSupportVerdict
        let summaryText: String
        let hintText: String?

        if !attributedQuantities.isEmpty && !mismatchedDetails.isEmpty {
            verdict = .numericDiscrepancy
            let reasons = mismatchedDetails.map(\.explanation).joined(separator: " ")
            summaryText = "Quantitative discrepancy against \(chosen.chunk.pdfFileName) (\(chosen.chunk.sectionTitle), p.\(chosen.chunk.boundingBox.pageIndex + 1)): \(reasons)"
            if let firstMismatch = mismatchedDetails.first, let pdfTok = firstMismatch.closestPDFToken {
                hintText = "Update '\(firstMismatch.claimToken.rawSurfaceText)' in manuscript to match source PDF value '\(pdfTok.rawSurfaceText)'."
            } else {
                hintText = "Verify all cited numbers on page \(chosen.chunk.boundingBox.pageIndex + 1) of \(chosen.chunk.pdfFileName)."
            }
        } else if chosen.polarityClash {
            verdict = .unsupportedClaim
            summaryText = "Polarity inversion detected: manuscript assertion reverses negation/significance direction reported in \(chosen.chunk.pdfFileName) (p.\(chosen.chunk.boundingBox.pageIndex + 1))."
            hintText = "Inspect source excerpt in '\(chosen.chunk.sectionTitle)' for negative/null findings."
        } else if chosen.lexCov >= minimumGroundedLexicalCoverage || chosen.bm25 >= 2.2 || (!attributedQuantities.isEmpty && mismatchedDetails.isEmpty) {
            verdict = .groundedEntailment
            if attributedQuantities.isEmpty {
                summaryText = String(
                    format: "Grounded qualitative entailment (lexical coverage = %.0f%%, BM25 = %.2f) on p.%d of %@.",
                    chosen.lexCov * 100.0,
                    chosen.bm25,
                    chosen.chunk.boundingBox.pageIndex + 1,
                    chosen.chunk.pdfFileName
                )
            } else {
                let verifiedList = chosen.comparisons.map { $0.claimToken.rawSurfaceText }.joined(separator: ", ")
                summaryText = "All \(attributedQuantities.count) quantitative claim(s) (\(verifiedList)) verified against \(chosen.chunk.pdfFileName) (p.\(chosen.chunk.boundingBox.pageIndex + 1), \(chosen.chunk.sectionTitle))."
            }
            hintText = nil
        } else if chosen.lexCov >= 0.14 || chosen.bm25 >= 0.8 {
            verdict = .partialEvidence
            summaryText = String(
                format: "Partial topical overlap (%.0f%% lexical match) in %@ (p.%d), but specific claim predicates lack direct lexical confirmation.",
                chosen.lexCov * 100.0,
                chosen.chunk.pdfFileName,
                chosen.chunk.boundingBox.pageIndex + 1
            )
            hintText = "Confirm whether another section or table in '\(citeKey)' directly states this claim."
        } else {
            verdict = .unsupportedClaim
            summaryText = "Retrieved PDF passage has insufficient semantic entailment (\(String(format: "%.0f%%", chosen.lexCov * 100.0)) overlap) for claim citing '\(citeKey)'."
            hintText = "Check citation key '\(citeKey)' for misattribution."
        }

        let prov = ClaimEvidenceProvenance(
            manuscriptFile: sentence.filePath,
            manuscriptLine: sentence.startLine,
            manuscriptClaim: sentence.rawSentence,
            citeKey: citeKey,
            passageID: chosen.chunk.id,
            pdfExcerpt: chosen.chunk.passageText,
            boundingBox: chosen.chunk.boundingBox,
            bm25Score: chosen.bm25,
            verdict: verdict
        )

        return DetailedClaimEntailmentAudit(
            provenance: prov,
            span: sentence.span,
            lexicalTermCoverage: chosen.lexCov,
            polarityContradictionDetected: chosen.polarityClash,
            numericComparisons: chosen.comparisons,
            auditExplanationSummary: summaryText,
            suggestedCorrectionHint: hintText
        )
    }

    // MARK: - Quantitative Token Matching Logic

    private func compareClaimToken(
        _ claim: ExtractedQuantitativeToken,
        againstPDFTokens pdfTokens: [ExtractedQuantitativeToken]
    ) -> NumericTokenComparisonDetail {
        // Filter compatible quantity families (e.g. percentage <-> namedMetricScore on pts_100 scale are cross-compatible!)
        let compatibleCandidates = pdfTokens.filter { cand in
            if cand.kind == claim.kind { return true }
            if (cand.kind == .percentage || cand.kind == .namedMetricScore)
                && (claim.kind == .percentage || claim.kind == .namedMetricScore)
                && cand.canonicalUnit == claim.canonicalUnit {
                return true
            }
            return false
        }

        // Prioritize candidate with matching metricIdentifier (e.g. both `F1` or both `AUC`) if available
        let filteredByMetric: [ExtractedQuantitativeToken]
        if let claimMetric = claim.metricIdentifier {
            let sameMetric = compatibleCandidates.filter { $0.metricIdentifier == claimMetric }
            filteredByMetric = sameMetric.isEmpty ? compatibleCandidates : sameMetric
        } else {
            filteredByMetric = compatibleCandidates
        }

        guard let closest = filteredByMetric.min(by: { a, b in
            abs(a.canonicalValue - claim.canonicalValue) < abs(b.canonicalValue - claim.canonicalValue)
        }) else {
            return NumericTokenComparisonDetail(
                claimToken: claim,
                closestPDFToken: nil,
                classification: .missingQuantityInPDF,
                relativeErrorPercent: nil,
                explanation: "Claimed \(claim.kind.rawValue.lowercased()) '\(claim.rawSurfaceText)' does not appear in retrieved PDF passage."
            )
        }

        // Special handling for p-value inequalities (e.g. PDF `p = 0.0004` entails manuscript `p < 0.001`!
        // Conversely, PDF `p = 0.042` VIOLATES manuscript `p < 0.01` -> significance inflation!)
        if claim.kind == .pValueSignificance {
            return evaluatePValueComparison(claim: claim, pdf: closest)
        }

        // Confidence interval comparison: verify both lower and upper bounds
        if claim.kind == .confidenceIntervalBound,
           let claimHi = claim.secondaryUpperValue,
           let pdfHi = closest.secondaryUpperValue {
            let tol = max(claim.halfLastDecimalPlaceTolerance, closest.halfLastDecimalPlaceTolerance)
            let loDiff = abs(claim.canonicalValue - closest.canonicalValue)
            let hiDiff = abs(claimHi - pdfHi)
            let maxDiff = max(loDiff, hiDiff)
            let relErr = max(1e-9, abs(closest.canonicalValue)) > 0 ? (maxDiff / max(1e-9, abs(closest.canonicalValue))) * 100.0 : 0.0
            if maxDiff <= tol + 1e-9 {
                return NumericTokenComparisonDetail(
                    claimToken: claim,
                    closestPDFToken: closest,
                    classification: .exactCanonicalMatch,
                    relativeErrorPercent: relErr,
                    explanation: "Confidence interval '\(claim.rawSurfaceText)' matches PDF '\(closest.rawSurfaceText)'."
                )
            } else {
                return NumericTokenComparisonDetail(
                    claimToken: claim,
                    closestPDFToken: closest,
                    classification: .valueMismatchDistortion,
                    relativeErrorPercent: relErr,
                    explanation: "Confidence interval mismatch: manuscript claims '\(claim.rawSurfaceText)' whereas PDF reports '\(closest.rawSurfaceText)'."
                )
            }
        }

        let absDiff = abs(claim.canonicalValue - closest.canonicalValue)
        let denom = max(1e-9, abs(closest.canonicalValue))
        let relDiff = absDiff / denom
        let relPct = relDiff * 100.0
        let combinedHalfULP = claim.halfLastDecimalPlaceTolerance + closest.halfLastDecimalPlaceTolerance

        if absDiff <= 1e-9 {
            let unitConverted = abs(claim.rawNumericValue - closest.rawNumericValue) > 1e-6
            return NumericTokenComparisonDetail(
                claimToken: claim,
                closestPDFToken: closest,
                classification: unitConverted ? .unitConvertedEquivalent : .exactCanonicalMatch,
                relativeErrorPercent: 0.0,
                explanation: unitConverted
                    ? "Unit-converted match: '\(claim.rawSurfaceText)' equals PDF '\(closest.rawSurfaceText)' (\(claim.canonicalUnit))."
                    : "Exact numeric match: '\(claim.rawSurfaceText)' confirmed in PDF."
            )
        }

        if absDiff <= combinedHalfULP + 1e-9 || relDiff <= relativeRoundingFallbackTolerance {
            return NumericTokenComparisonDetail(
                claimToken: claim,
                closestPDFToken: closest,
                classification: .withinRoundingTolerance,
                relativeErrorPercent: relPct,
                explanation: String(
                    format: "Rounding-compatible match: manuscript '%@' aligns with PDF '%@' (Δ = %.2f%%).",
                    claim.rawSurfaceText,
                    closest.rawSurfaceText,
                    relPct
                )
            )
        }

        return NumericTokenComparisonDetail(
            claimToken: claim,
            closestPDFToken: closest,
            classification: .valueMismatchDistortion,
            relativeErrorPercent: relPct,
            explanation: String(
                format: "Numeric mismatch: manuscript claims '%@', but source PDF reports '%@' (relative discrepancy = %.1f%%).",
                claim.rawSurfaceText,
                closest.rawSurfaceText,
                relPct
            )
        )
    }

    private func evaluatePValueComparison(
        claim: ExtractedQuantitativeToken,
        pdf: ExtractedQuantitativeToken
    ) -> NumericTokenComparisonDetail {
        let pClaim = claim.canonicalValue
        let pPDF = pdf.canonicalValue
        let tol = claim.halfLastDecimalPlaceTolerance + pdf.halfLastDecimalPlaceTolerance

        switch claim.relation {
        case .lessThan, .lessThanOrEqual:
            // Manuscript claims `p < alpha` (e.g. `p < 0.001`). Valid if PDF reports `p = 0.0003` or `p < 0.001`!
            let entailed: Bool
            if pdf.relation == .equal || pdf.relation == .approximatelyEqual || pdf.relation == .lessThan || pdf.relation == .lessThanOrEqual {
                entailed = (pPDF <= pClaim + 1e-9)
            } else {
                // PDF says `p > 0.05` while manuscript claims `p < 0.05`!
                entailed = false
            }
            if entailed {
                return NumericTokenComparisonDetail(
                    claimToken: claim,
                    closestPDFToken: pdf,
                    classification: abs(pPDF - pClaim) < 1e-9 ? .exactCanonicalMatch : .pValueInequalityEntailed,
                    relativeErrorPercent: 0.0,
                    explanation: "Statistical threshold '\(claim.rawSurfaceText)' is entailed by PDF '\(pdf.rawSurfaceText)'."
                )
            } else {
                return NumericTokenComparisonDetail(
                    claimToken: claim,
                    closestPDFToken: pdf,
                    classification: .pValueSignificanceInflation,
                    relativeErrorPercent: pPDF > 0 ? (abs(pClaim - pPDF) / pPDF) * 100.0 : 100.0,
                    explanation: "Significance inflation: manuscript claims '\(claim.rawSurfaceText)' whereas source PDF reports '\(pdf.rawSurfaceText)'."
                )
            }

        case .greaterThan, .greaterThanOrEqual:
            let entailed = (pdf.relation != .lessThan && pdf.relation != .lessThanOrEqual) && (pPDF + tol >= pClaim)
            return NumericTokenComparisonDetail(
                claimToken: claim,
                closestPDFToken: pdf,
                classification: entailed ? .pValueInequalityEntailed : .valueMismatchDistortion,
                relativeErrorPercent: nil,
                explanation: entailed
                    ? "Non-significance bound '\(claim.rawSurfaceText)' aligns with PDF '\(pdf.rawSurfaceText)'."
                    : "p-value bound mismatch: manuscript claims '\(claim.rawSurfaceText)' vs PDF '\(pdf.rawSurfaceText)'."
            )

        case .equal, .approximatelyEqual:
            if abs(pClaim - pPDF) <= tol + 1e-9 && (pdf.relation == .equal || pdf.relation == .approximatelyEqual) {
                return NumericTokenComparisonDetail(
                    claimToken: claim,
                    closestPDFToken: pdf,
                    classification: .exactCanonicalMatch,
                    relativeErrorPercent: 0.0,
                    explanation: "Exact p-value '\(claim.rawSurfaceText)' confirmed in PDF."
                )
            }
            return NumericTokenComparisonDetail(
                claimToken: claim,
                closestPDFToken: pdf,
                classification: .pValueSignificanceInflation,
                relativeErrorPercent: pPDF > 0 ? (abs(pClaim - pPDF) / pPDF) * 100.0 : 100.0,
                explanation: "Exact p-value mismatch: manuscript states '\(claim.rawSurfaceText)' while PDF reports '\(pdf.rawSurfaceText)'."
            )
        }
    }

    // MARK: - In-Memory BM25 Scorer & Report Aggregator

    private func rankInMemoryPassages(
        querySentence: String,
        passages: [PDFPassageChunk]
    ) -> [(chunk: PDFPassageChunk, bm25Magnitude: Double)] {
        guard !passages.isEmpty else { return [] }
        let queryTerms = Array(Set(Self.extractContentKeywords(querySentence)))
        guard !queryTerms.isEmpty else {
            return passages.prefix(3).map { ($0, 0.5) }
        }

        let nDocs = passages.count
        let tokenizedDocs = passages.map { Self.extractContentKeywords($0.passageText + " " + $0.sectionTitle) }
        let avgDocLen = max(1.0, Double(tokenizedDocs.reduce(0) { $0 + $1.count }) / Double(nDocs))

        var dfMap: [String: Int] = [:]
        for term in queryTerms {
            dfMap[term] = tokenizedDocs.filter { $0.contains(term) }.count
        }

        let k1 = 1.5
        let b = 0.75
        var scored: [(PDFPassageChunk, Double)] = []

        for (idx, chunk) in passages.enumerated() {
            let docTokens = tokenizedDocs[idx]
            let docLen = Double(docTokens.count)
            var tfByTerm: [String: Int] = [:]
            for t in docTokens {
                tfByTerm[t, default: 0] += 1
            }

            var bm25 = 0.0
            for q in queryTerms {
                let tf = Double(tfByTerm[q] ?? 0)
                guard tf > 0.0 else { continue }
                let df = Double(dfMap[q] ?? 0)
                let idf = Foundation.log(1.0 + (Double(nDocs) - df + 0.5) / (df + 0.5))
                let numer = tf * (k1 + 1.0)
                let denom = tf + k1 * (1.0 - b + b * (docLen / avgDocLen))
                bm25 += idf * (numer / denom)
            }
            if bm25 > 0.0 {
                scored.append((chunk, bm25))
            }
        }

        scored.sort { a, b in
            if abs(a.1 - b.1) > 1e-9 { return a.1 > b.1 }
            return a.0.readingSequence < b.0.readingSequence
        }
        return Array(scored.prefix(5))
    }

    private func summarizeManuscriptAudit(
        manuscriptFile: String,
        audits: [DetailedClaimEntailmentAudit]
    ) -> ManuscriptProvenanceAuditReport {
        var grounded = 0
        var partial = 0
        var discrepancy = 0
        var unsupported = 0
        var lspList: [LSPDiagnostic] = []
        var findings: [EditorialAuditFinding] = []

        var quantClaimsTotal = 0
        var quantClaimsClean = 0

        for item in audits {
            if !item.numericComparisons.isEmpty {
                quantClaimsTotal += 1
                if item.provenance.verdict != .numericDiscrepancy && item.provenance.verdict != .unsupportedClaim {
                    quantClaimsClean += 1
                }
            }

            switch item.provenance.verdict {
            case .groundedEntailment:
                grounded += 1
            case .partialEvidence:
                partial += 1
                lspList.append(
                    LSPDiagnostic(
                        code: "PROVENANCE_PARTIAL",
                        severity: .info,
                        message: item.auditExplanationSummary,
                        span: item.span,
                        suggestedFix: item.suggestedCorrectionHint
                    )
                )
            case .numericDiscrepancy:
                discrepancy += 1
                lspList.append(
                    LSPDiagnostic(
                        code: "ERR_NUMERIC_DISCREPANCY",
                        severity: .error,
                        message: item.auditExplanationSummary,
                        span: item.span,
                        suggestedFix: item.suggestedCorrectionHint
                    )
                )
                findings.append(
                    EditorialAuditFinding(
                        pluginID: "builtin.provenance.numeric-auditor",
                        pluginName: "Quantitative Citation Entailment Auditor",
                        severity: .submissionBlocker,
                        category: "Numeric Citation Discrepancy",
                        filePath: manuscriptFile,
                        line: item.provenance.manuscriptLine,
                        matchedExcerpt: item.provenance.manuscriptClaim,
                        explanation: item.auditExplanationSummary,
                        suggestedRewrite: item.suggestedCorrectionHint
                    )
                )
            case .unsupportedClaim:
                unsupported += 1
                lspList.append(
                    LSPDiagnostic(
                        code: "WARN_UNSUPPORTED_CLAIM",
                        severity: .warning,
                        message: item.auditExplanationSummary,
                        span: item.span,
                        suggestedFix: item.suggestedCorrectionHint
                    )
                )
                findings.append(
                    EditorialAuditFinding(
                        pluginID: "builtin.provenance.numeric-auditor",
                        pluginName: "Quantitative Citation Entailment Auditor",
                        severity: .rigorWarning,
                        category: "Unsupported Cited Claim",
                        filePath: manuscriptFile,
                        line: item.provenance.manuscriptLine,
                        matchedExcerpt: item.provenance.manuscriptClaim,
                        explanation: item.auditExplanationSummary,
                        suggestedRewrite: item.suggestedCorrectionHint
                    )
                )
            }
        }

        let quantAccuracy = quantClaimsTotal > 0
            ? Double(quantClaimsClean) / Double(quantClaimsTotal)
            : 1.0

        return ManuscriptProvenanceAuditReport(
            manuscriptFile: manuscriptFile,
            totalCitedClaimsAudited: audits.count,
            groundedEntailmentCount: grounded,
            partialEvidenceCount: partial,
            numericDiscrepancyCount: discrepancy,
            unsupportedClaimCount: unsupported,
            quantitativeClaimAccuracyRate: quantAccuracy,
            claimAudits: audits,
            lspDiagnostics: lspList,
            editorialFindings: findings
        )
    }

    // MARK: - Internal Lexical, Sentence-Boundary & Unit Normalization Helpers

    private struct CitationOccurrenceSpan {
        let offset: Int
        let citeKeys: [String]
    }

    private static func locateCitationOccurrences(in sentence: String) -> [CitationOccurrenceSpan] {
        var occurrences: [CitationOccurrenceSpan] = []
        let ns = sentence as NSString
        let range = NSRange(location: 0, length: ns.length)

        if let latexRegex = try? NSRegularExpression(
            pattern: #"\\(?:cite[a-zA-Z]*|parencite|textcite|autocite)\*?(?:\[[^\]]*\])*\{([^}]+)\}"#
        ) {
            for m in latexRegex.matches(in: sentence, range: range) where m.numberOfRanges > 1 {
                let keys = ns.substring(with: m.range(at: 1))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !keys.isEmpty {
                    occurrences.append(CitationOccurrenceSpan(offset: m.range.location, citeKeys: keys))
                }
            }
        }

        if let typstCall = try? NSRegularExpression(pattern: #"#cite\(\s*<([A-Za-z0-9_:\-\.]+)>"#) {
            for m in typstCall.matches(in: sentence, range: range) where m.numberOfRanges > 1 {
                occurrences.append(CitationOccurrenceSpan(offset: m.range.location, citeKeys: [ns.substring(with: m.range(at: 1))]))
            }
        }

        if let atRegex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9._%+-])@([A-Za-z][A-Za-z0-9_:\-]{2,})"#) {
            for m in atRegex.matches(in: sentence, range: range) where m.numberOfRanges > 1 {
                let key = ns.substring(with: m.range(at: 1))
                // Avoid duplicating pass@1 metric tokens (`pass@1` starts with `pass` before `@`, already blocked by lookbehind!)
                occurrences.append(CitationOccurrenceSpan(offset: m.range.location, citeKeys: [key]))
            }
        }

        return occurrences.sorted { $0.offset < $1.offset }
    }

    private static let nonBreakingAbbreviations: Set<String> = [
        "al", "eg", "ie", "fig", "figs", "eq", "eqs", "sec", "secs", "tab",
        "vs", "cf", "dr", "prof", "inc", "ltd", "pp", "vol", "no", "et"
    ]

    /// Splits academic markup into exact line/column `TextSpan` sentences without breaking on `et al.`, `e.g.`, `Fig. 2`, or decimals `94.2%`.
    private static func splitIntoSentenceSpans(
        source: String,
        filePath: String
    ) -> [(text: String, span: TextSpan)] {
        var segments: [(String, TextSpan)] = []
        let chars = Array(source)
        let total = chars.count
        guard total > 0 else { return [] }

        var curLine = 1
        var curCol = 1
        var curUTF8 = 0

        var segStartIdx = 0
        var segStartPos = TextPosition(line: 1, column: 1, utf8Offset: 0)
        var consecutiveNewlines = 0

        var idx = 0
        while idx < total {
            let ch = chars[idx]
            let chUTF8 = String(ch).utf8.count

            if ch == "\n" {
                consecutiveNewlines += 1
                curLine += 1
                curCol = 1
                curUTF8 += chUTF8

                // Paragraph blank-line break flushes active sentence
                if consecutiveNewlines >= 2 && idx > segStartIdx {
                    let slice = String(chars[segStartIdx..<idx])
                    let endPos = TextPosition(line: curLine, column: curCol, utf8Offset: curUTF8)
                    segments.append((slice, TextSpan(filePath: filePath, start: segStartPos, end: endPos)))
                    segStartIdx = idx + 1
                    segStartPos = endPos
                }
                idx += 1
                continue
            } else {
                consecutiveNewlines = 0
            }

            let isTerminator = (ch == "." || ch == "!" || ch == "?")
            if isTerminator {
                let prevIsDigit = idx > 0 && chars[idx - 1].isNumber
                let nextIsDigit = (idx + 1 < total) && chars[idx + 1].isNumber
                if !(prevIsDigit && nextIsDigit) {
                    // Check preceding word for academic abbreviation (`et al.`, `Fig.`, `e.g.`)
                    let wEnd = idx
                    var wStart = idx
                    while wStart > segStartIdx && chars[wStart - 1].isLetter {
                        wStart -= 1
                    }
                    let prevWord = wStart < wEnd ? String(chars[wStart..<wEnd]).lowercased() : ""
                    let isSingleInitial = prevWord.count == 1 && (wStart > 0 && chars[wStart - 1] != "$")
                    let nextIsSpaceOrEnd = (idx + 1 >= total) || chars[idx + 1].isWhitespace || chars[idx + 1] == "}" || chars[idx + 1] == "]"

                    if nextIsSpaceOrEnd && !nonBreakingAbbreviations.contains(prevWord) && !isSingleInitial {
                        curCol += 1
                        curUTF8 += chUTF8
                        let slice = String(chars[segStartIdx...idx])
                        let endPos = TextPosition(line: curLine, column: curCol, utf8Offset: curUTF8)
                        segments.append((slice, TextSpan(filePath: filePath, start: segStartPos, end: endPos)))
                        segStartIdx = idx + 1
                        segStartPos = endPos
                        idx += 1
                        continue
                    }
                }
            }

            curCol += 1
            curUTF8 += chUTF8
            idx += 1
        }

        if segStartIdx < total {
            let slice = String(chars[segStartIdx..<total])
            let endPos = TextPosition(line: curLine, column: curCol, utf8Offset: curUTF8)
            segments.append((slice, TextSpan(filePath: filePath, start: segStartPos, end: endPos)))
        }

        return segments
    }

    private static func normalizeMarkupNumericSyntax(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\%", with: "%")
            .replacingOccurrences(of: "{,}", with: ",")
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
    }

    private static func stripMarkupCommandsToPlain(_ raw: String) -> String {
        var s = normalizeMarkupNumericSyntax(raw)
        if let citeStrip = try? NSRegularExpression(
            pattern: #"\\(?:cite[a-zA-Z]*|parencite|textcite|autocite)\*?(?:\[[^\]]*\])*\{[^}]+\}"#
        ) {
            s = citeStrip.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        }
        if let cmdStrip = try? NSRegularExpression(pattern: #"\\[a-zA-Z]+\*?"#) {
            s = cmdStrip.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        }
        return s.replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
    }

    private static func parseCleanDouble(_ literal: String) -> Double? {
        Double(literal.replacingOccurrences(of: ",", with: ""))
    }

    private static func halfULPTolerance(forLiteral literal: String) -> Double {
        let clean = literal.replacingOccurrences(of: ",", with: "")
        guard let dotIdx = clean.firstIndex(of: ".") else {
            return 0.5
        }
        let fracPart = clean[clean.index(after: dotIdx)...]
        let digits = fracPart.prefix(while: \.isNumber).count
        guard digits > 0 else { return 0.5 }
        return 0.5 * Foundation.pow(10.0, -Double(digits))
    }

    private static func parseOperator(_ raw: String) -> QuantitativeRelationOperator {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "<": return .lessThan
        case "<=": return .lessThanOrEqual
        case ">": return .greaterThan
        case ">=": return .greaterThanOrEqual
        case "≈": return .approximatelyEqual
        default: return .equal
        }
    }

    private static func canonicalizeMetricName(_ raw: String) -> String {
        let up = raw.uppercased()
        if up.hasPrefix("F1") { return "F1" }
        if up == "AUROC" || up == "AUC" { return "AUC" }
        if up == "PPL" || up == "PERPLEXITY" { return "PPL" }
        if up == "Κ" || up == "KAPPA" { return "KAPPA" }
        return up
    }

    private static func isUnitIntervalMetric(_ canonicalName: String) -> Bool {
        switch canonicalName {
        case "F1", "AUC", "ACCURACY", "PRECISION", "RECALL", "IOU", "MAP":
            return true
        default:
            return false
        }
    }

    private static func durationToSecondsMultiplier(_ unitRaw: String) -> Double {
        let lower = unitRaw.lowercased()
        switch lower {
        case "ns": return 1e-9
        case "us", "μs", "µs", "microsecond", "microseconds": return 1e-6
        case "ms", "millisecond", "milliseconds": return 1e-3
        case "min", "minute", "minutes": return 60.0
        default: return 1.0
        }
    }

    private static func systemUnitCanonicalizer(_ unitRaw: String) -> (QuantitativeQuantityKind, Double, String) {
        let up = unitRaw.uppercased()
        switch up {
        case "KB": return (.memoryOrStorage, 1_000.0, "bytes")
        case "KIB": return (.memoryOrStorage, 1_024.0, "bytes")
        case "MB": return (.memoryOrStorage, 1_000_000.0, "bytes")
        case "MIB": return (.memoryOrStorage, 1_048_576.0, "bytes")
        case "GB": return (.memoryOrStorage, 1_000_000_000.0, "bytes")
        case "GIB": return (.memoryOrStorage, 1_073_741_824.0, "bytes")
        case "TB": return (.memoryOrStorage, 1_000_000_000_000.0, "bytes")
        case "TIB": return (.memoryOrStorage, 1_099_511_627_776.0, "bytes")
        case "GFLOPS": return (.throughputRate, 1e9, "FLOPS")
        case "TFLOPS": return (.throughputRate, 1e12, "FLOPS")
        default: return (.throughputRate, 1.0, "ops_per_s")
        }
    }

    private static func containsNegationPolarity(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        let cues = [
            " did not ", " does not ", " do not ", " failed to ", " fails to ",
            " no significant ", " no statistically significant ", " unable to ",
            " degrades ", " degraded ", " worsened ", " neither "
        ]
        return cues.contains { lower.contains($0) }
    }

    private static func sharesDirectionalOutcomeVerb(_ a: String, _ b: String) -> Bool {
        let outcomeRoots = ["improv", "outperform", "reduc", "acceler", "increas", "significan", "surpass"]
        let la = a.lowercased()
        let lb = b.lowercased()
        return outcomeRoots.contains { la.contains($0) && lb.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "were", "have", "been",
        "into", "their", "while", "where", "which", "than", "also", "over", "under",
        "using", "used", "show", "shows", "shown", "demonstrate", "paper", "study"
    ]

    private static func extractContentKeywords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopWords.contains($0) && Int($0) == nil }
    }
}
