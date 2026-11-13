import Foundation
import ScholarModels

// MARK: - Psychometric Agreement Benchmarks & Statistical Primitives

/// Standard psychometric interpretation bands following Landis & Koch (1977) and McHugh (2012).
public enum AgreementBenchmarkBand: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case poor = "Poor (< 0.00)"
    case slight = "Slight (0.00–0.20)"
    case fair = "Fair (0.21–0.40)"
    case moderate = "Moderate (0.41–0.60)"
    case substantial = "Substantial (0.61–0.80)"
    case almostPerfect = "Almost Perfect (0.81–1.00)"

    private var rankOrder: Int {
        switch self {
        case .poor: return 0
        case .slight: return 1
        case .fair: return 2
        case .moderate: return 3
        case .substantial: return 4
        case .almostPerfect: return 5
        }
    }

    public static func < (lhs: AgreementBenchmarkBand, rhs: AgreementBenchmarkBand) -> Bool {
        lhs.rankOrder < rhs.rankOrder
    }

    public static func classify(_ score: Double) -> AgreementBenchmarkBand {
        if score < 0.0 { return .poor }
        if score <= 0.20 { return .slight }
        if score <= 0.40 { return .fair }
        if score <= 0.60 { return .moderate }
        if score <= 0.80 { return .substantial }
        return .almostPerfect
    }

    /// Strict systematic-review gate following McHugh (2012) healthcare/clinical screening recommendations.
    public var meetsPRISMACalibrationGate: Bool {
        self >= .substantial
    }
}

/// Weighting scheme for ordinal or multi-category inter-rater agreement indices.
public enum KappaWeightingScheme: String, Sendable, Codable, Hashable, CaseIterable {
    case unweighted = "Unweighted Nominal"
    case linearCicchettiAllison = "Linear (Cicchetti-Allison)"
    case quadraticFleissCohen = "Quadratic (Fleiss-Cohen)"

    public func agreementWeight(categoryIndexA i: Int, categoryIndexB j: Int, categoryCount k: Int) -> Double {
        if i == j { return 1.0 }
        guard k > 1 else { return 1.0 }
        let span = Double(k - 1)
        let diff = Double(abs(i - j))
        switch self {
        case .unweighted:
            return 0.0
        case .linearCicchettiAllison:
            return max(0.0, 1.0 - (diff / span))
        case .quadraticFleissCohen:
            let ratio = diff / span
            return max(0.0, 1.0 - (ratio * ratio))
        }
    }
}

/// Asymptotic point estimate, standard error, Wald confidence interval, and null-hypothesis significance test.
public struct PsychometricStatisticEstimate: Sendable, Codable, Hashable {
    public let metricName: String
    public let pointEstimate: Double
    public let standardError: Double
    public let nullStandardError: Double
    public let confidenceLevel: Double
    public let lowerCI: Double
    public let upperCI: Double
    public let zStatistic: Double
    public let twoSidedPValue: Double
    public let benchmarkBand: AgreementBenchmarkBand

    public init(
        metricName: String,
        pointEstimate: Double,
        standardError: Double,
        nullStandardError: Double,
        confidenceLevel: Double = 0.95,
        lowerBoundary: Double = -1.0,
        upperBoundary: Double = 1.0
    ) {
        self.metricName = metricName
        self.pointEstimate = pointEstimate
        let clampedSE = max(0.0, standardError)
        let clampedNullSE = max(0.0, nullStandardError)
        self.standardError = clampedSE
        self.nullStandardError = clampedNullSE
        self.confidenceLevel = min(0.999, max(0.50, confidenceLevel))

        let alpha = 1.0 - self.confidenceLevel
        let zCrit = PsychometricNormalMath.inverseStandardNormalCDF(1.0 - alpha * 0.5)
        self.lowerCI = max(lowerBoundary, min(upperBoundary, pointEstimate - zCrit * clampedSE))
        self.upperCI = max(lowerBoundary, min(upperBoundary, pointEstimate + zCrit * clampedSE))

        let effectiveNullSE = clampedNullSE > 1e-12 ? clampedNullSE : clampedSE
        if effectiveNullSE > 1e-12 {
            let z = pointEstimate / effectiveNullSE
            self.zStatistic = z
            self.twoSidedPValue = PsychometricNormalMath.twoSidedNormalPValue(zScore: z)
        } else {
            self.zStatistic = pointEstimate >= 1.0 - 1e-9 ? 99.0 : 0.0
            self.twoSidedPValue = pointEstimate >= 1.0 - 1e-9 ? 0.0 : 1.0
        }
        self.benchmarkBand = AgreementBenchmarkBand.classify(pointEstimate)
    }
}

/// Pure-Swift high-precision normal, chi-square, and binomial interval routines for psychometric inference.
public enum PsychometricNormalMath: Sendable {
    /// Complementary error function approximation (Abramowitz & Stegun 7.1.26, max error < 1.5e-7).
    public static func erfcApprox(_ x: Double) -> Double {
        let z = abs(x)
        let t = 1.0 / (1.0 + 0.3275911 * z)
        let a1 = 0.254829592
        let a2 = -0.284496736
        let a3 = 1.421413741
        let a4 = -1.453152027
        let a5 = 1.061405429
        let poly = (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t
        let val = poly * Foundation.exp(-z * z)
        return x >= 0.0 ? val : (2.0 - val)
    }

    /// Standard normal cumulative distribution function $\Phi(z)$.
    public static func standardNormalCDF(_ z: Double) -> Double {
        0.5 * erfcApprox(-z / 2.0.squareRoot())
    }

    /// Two-sided asymptotic normal p-value $2(1 - \Phi(|z|))$.
    public static func twoSidedNormalPValue(zScore: Double) -> Double {
        guard zScore.isFinite else { return 0.0 }
        let p = erfcApprox(abs(zScore) / 2.0.squareRoot())
        return min(1.0, max(0.0, p))
    }

    /// Acklam's rational approximation to the standard normal quantile function $\Phi^{-1}(p)$ (relative error < 1.15e-9).
    public static func inverseStandardNormalCDF(_ pRaw: Double) -> Double {
        let p = min(1.0 - 1e-12, max(1e-12, pRaw))

        let a1 = -3.969683028665376e+01
        let a2 = 2.209460984245205e+02
        let a3 = -2.759285104469687e+02
        let a4 = 1.383577518672690e+02
        let a5 = -3.066479806614716e+01
        let a6 = 2.506628277459239e+00

        let b1 = -5.447609879822406e+01
        let b2 = 1.615858368580409e+02
        let b3 = -1.556989798598866e+02
        let b4 = 6.680131188771972e+01
        let b5 = -1.328068155288572e+01

        let c1 = -7.784894002430293e-03
        let c2 = -3.223964580411365e-01
        let c3 = -2.400758277161838e+00
        let c4 = -2.549732539343734e+00
        let c5 = 4.374664141464968e+00
        let c6 = 2.938163982698783e+00

        let d1 = 7.784695709041462e-03
        let d2 = 3.224671290700398e-01
        let d3 = 2.445134137142996e+00
        let d4 = 3.754408661907416e+00

        let pLow = 0.02425
        let pHigh = 1.0 - pLow

        if p < pLow {
            let q = (-2.0 * Foundation.log(p)).squareRoot()
            let num = (((((c1 * q + c2) * q + c3) * q + c4) * q + c5) * q) + c6
            let den = ((((d1 * q + d2) * q + d3) * q + d4) * q) + 1.0
            return num / den
        } else if p <= pHigh {
            let q = p - 0.5
            let r = q * q
            let num = (((((a1 * r + a2) * r + a3) * r + a4) * r + a5) * r + a6) * q
            let den = (((((b1 * r + b2) * r + b3) * r + b4) * r + b5) * r) + 1.0
            return num / den
        } else {
            let q = (-2.0 * Foundation.log(1.0 - p)).squareRoot()
            let num = (((((c1 * q + c2) * q + c3) * q + c4) * q + c5) * q) + c6
            let den = ((((d1 * q + d2) * q + d3) * q + d4) * q) + 1.0
            return -(num / den)
        }
    }

    /// Wilson-Hilferty upper-tail approximation for the $\chi^2_\nu$ survival function $P(\chi^2_\nu \ge x)$.
    public static func chiSquareUpperTailPValue(chiSquare x: Double, degreesOfFreedom df: Int) -> Double {
        guard df > 0, x > 0.0 else { return x <= 0.0 ? 1.0 : 0.0 }
        if df == 1 {
            return twoSidedNormalPValue(zScore: x.squareRoot())
        }
        if df == 2 {
            return min(1.0, max(0.0, Foundation.exp(-0.5 * x)))
        }
        let nu = Double(df)
        let term = 2.0 / (9.0 * nu)
        let cubeRoot = Foundation.pow(x / nu, 1.0 / 3.0)
        let z = (cubeRoot - (1.0 - term)) / term.squareRoot()
        return min(1.0, max(0.0, 1.0 - standardNormalCDF(z)))
    }

    /// Wilson score binomial proportion confidence interval $[L, U]$ for $k$ successes out of $n$ trials.
    public static func wilsonScoreInterval(
        successes k: Int,
        trials n: Int,
        confidenceLevel: Double = 0.95
    ) -> (lower: Double, upper: Double) {
        guard n > 0 else { return (0.0, 1.0) }
        let clampedK = min(n, max(0, k))
        let alpha = 1.0 - min(0.999, max(0.50, confidenceLevel))
        let z = inverseStandardNormalCDF(1.0 - alpha * 0.5)
        let z2 = z * z
        let nf = Double(n)
        let phat = Double(clampedK) / nf

        let denom = 1.0 + z2 / nf
        let center = (phat + z2 / (2.0 * nf)) / denom
        let halfWidth = (z / denom) * ((phat * (1.0 - phat) / nf) + (z2 / (4.0 * nf * nf))).squareRoot()
        return (
            lower: max(0.0, min(1.0, center - halfWidth)),
            upper: max(0.0, min(1.0, center + halfWidth))
        )
    }
}

// MARK: - Dual-Blind Psychometric Agreement & Paradox Diagnostics

/// Comprehensive 2x2 binary dual-reviewer agreement summary with Cohen's Kappa, Byrt's PABAK, and Gwet's AC1.
public struct DualRaterAgreementReport: Sendable, Codable, Hashable {
    public let evaluatedStudyCount: Int
    public let bothPositiveCount: Int
    public let raterAPositiveRaterBNegativeCount: Int
    public let raterANegativeRaterBPositiveCount: Int
    public let bothNegativeCount: Int
    public let observedProportionAgreement: Double
    public let expectedChanceAgreementCohen: Double
    public let expectedChanceAgreementGwet: Double
    public let specificPositiveAgreement: Double
    public let specificNegativeAgreement: Double
    public let prevalenceIndex: Double
    public let biasIndex: Double
    public let mcnemarChiSquare: Double
    public let mcnemarPValue: Double
    public let cohensKappa: PsychometricStatisticEstimate
    public let byrtsPABAK: PsychometricStatisticEstimate
    public let gwetsAC1: PsychometricStatisticEstimate
    public let weightedMulticlassKappa: PsychometricStatisticEstimate
    public let feinsteinCicchettiParadoxDetected: Bool
    public let diagnosticNarrative: String

    public init(
        evaluatedStudyCount: Int,
        bothPositiveCount: Int,
        raterAPositiveRaterBNegativeCount: Int,
        raterANegativeRaterBPositiveCount: Int,
        bothNegativeCount: Int,
        observedProportionAgreement: Double,
        expectedChanceAgreementCohen: Double,
        expectedChanceAgreementGwet: Double,
        specificPositiveAgreement: Double,
        specificNegativeAgreement: Double,
        prevalenceIndex: Double,
        biasIndex: Double,
        mcnemarChiSquare: Double,
        mcnemarPValue: Double,
        cohensKappa: PsychometricStatisticEstimate,
        byrtsPABAK: PsychometricStatisticEstimate,
        gwetsAC1: PsychometricStatisticEstimate,
        weightedMulticlassKappa: PsychometricStatisticEstimate,
        feinsteinCicchettiParadoxDetected: Bool,
        diagnosticNarrative: String
    ) {
        self.evaluatedStudyCount = evaluatedStudyCount
        self.bothPositiveCount = bothPositiveCount
        self.raterAPositiveRaterBNegativeCount = raterAPositiveRaterBNegativeCount
        self.raterANegativeRaterBPositiveCount = raterANegativeRaterBPositiveCount
        self.bothNegativeCount = bothNegativeCount
        self.observedProportionAgreement = observedProportionAgreement
        self.expectedChanceAgreementCohen = expectedChanceAgreementCohen
        self.expectedChanceAgreementGwet = expectedChanceAgreementGwet
        self.specificPositiveAgreement = specificPositiveAgreement
        self.specificNegativeAgreement = specificNegativeAgreement
        self.prevalenceIndex = prevalenceIndex
        self.biasIndex = biasIndex
        self.mcnemarChiSquare = mcnemarChiSquare
        self.mcnemarPValue = mcnemarPValue
        self.cohensKappa = cohensKappa
        self.byrtsPABAK = byrtsPABAK
        self.gwetsAC1 = gwetsAC1
        self.weightedMulticlassKappa = weightedMulticlassKappa
        self.feinsteinCicchettiParadoxDetected = feinsteinCicchettiParadoxDetected
        self.diagnosticNarrative = diagnosticNarrative
    }
}

// MARK: - Multi-Rater (M >= 3) Fleiss' Kappa, Gwet's AC1 & Krippendorff's Alpha

/// Multi-reviewer ballot for a single study supporting $M \ge 2$ blinded reviewers (fixed or unbalanced panels).
public struct MultiRaterScreeningBallot: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let citeKey: String
    public let stage: ScreeningStage
    /// Reviewer identifier -> ScreeningDecision (e.g. `["R1": .include, "R2": .include, "R3": .exclude(reasonCode: "E1_OFF_TOPIC")]`).
    public var votesByReviewerID: [String: ScreeningDecision]

    public init(
        id: String,
        citeKey: String,
        stage: ScreeningStage = .titleAbstract,
        votesByReviewerID: [String: ScreeningDecision]
    ) {
        self.id = id
        self.citeKey = citeKey
        self.stage = stage
        self.votesByReviewerID = votesByReviewerID
    }

    /// Convenience adapter converting a dual-screened (+ optional adjudicator) `ScreeningStudyRecord` into a multi-rater ballot.
    public init(from study: ScreeningStudyRecord, includeAdjudicatorAsThirdRater: Bool = false) {
        var votes: [String: ScreeningDecision] = [:]
        if let a = study.reviewerADecision {
            votes["ReviewerA"] = a
        }
        if let b = study.reviewerBDecision {
            votes["ReviewerB"] = b
        }
        if includeAdjudicatorAsThirdRater, let adj = study.adjudicatedDecision {
            votes["Adjudicator"] = adj
        }
        self.id = study.id
        self.citeKey = study.citeKey
        self.stage = study.stage
        self.votesByReviewerID = votes
    }
}

/// Category-specific Fleiss $\kappa_j$ diagnostic for pinpointing noisy decision classes or ambiguous exclusion codes.
public struct FleissCategoryKappaDetail: Sendable, Codable, Hashable, Identifiable {
    public var id: String { categoryLabel }
    public let categoryLabel: String
    public let marginalPrevalence: Double
    public let categoryKappa: Double
    public let standardError: Double
    public let zStatistic: Double
    public let twoSidedPValue: Double
    public let lower95CI: Double
    public let upper95CI: Double

    public init(
        categoryLabel: String,
        marginalPrevalence: Double,
        categoryKappa: Double,
        standardError: Double,
        zStatistic: Double,
        twoSidedPValue: Double,
        lower95CI: Double,
        upper95CI: Double
    ) {
        self.categoryLabel = categoryLabel
        self.marginalPrevalence = marginalPrevalence
        self.categoryKappa = categoryKappa
        self.standardError = standardError
        self.zStatistic = zStatistic
        self.twoSidedPValue = twoSidedPValue
        self.lower95CI = lower95CI
        self.upper95CI = upper95CI
    }
}

/// Complete multi-rater agreement report for $M \ge 3$ (or unbalanced $M_i \ge 2$) reviewers.
public struct MultiRaterPanelAgreementReport: Sendable, Codable, Hashable {
    public let studyCount: Int
    public let distinctReviewerIDs: [String]
    public let modalRatersPerStudy: Int
    public let categoryLabels: [String]
    public let overallObservedAgreement: Double
    public let fleissExpectedAgreement: Double
    public let unanimousStudyCount: Int
    public let unanimousRate: Double
    public let fleissKappa: PsychometricStatisticEstimate
    public let multiRaterGwetAC1: PsychometricStatisticEstimate
    public let multiRaterPABAK: PsychometricStatisticEstimate
    public let krippendorffsAlphaNominal: Double
    public let categoryBreakdown: [FleissCategoryKappaDetail]

    public init(
        studyCount: Int,
        distinctReviewerIDs: [String],
        modalRatersPerStudy: Int,
        categoryLabels: [String],
        overallObservedAgreement: Double,
        fleissExpectedAgreement: Double,
        unanimousStudyCount: Int,
        unanimousRate: Double,
        fleissKappa: PsychometricStatisticEstimate,
        multiRaterGwetAC1: PsychometricStatisticEstimate,
        multiRaterPABAK: PsychometricStatisticEstimate,
        krippendorffsAlphaNominal: Double,
        categoryBreakdown: [FleissCategoryKappaDetail]
    ) {
        self.studyCount = studyCount
        self.distinctReviewerIDs = distinctReviewerIDs
        self.modalRatersPerStudy = modalRatersPerStudy
        self.categoryLabels = categoryLabels
        self.overallObservedAgreement = overallObservedAgreement
        self.fleissExpectedAgreement = fleissExpectedAgreement
        self.unanimousStudyCount = unanimousStudyCount
        self.unanimousRate = unanimousRate
        self.fleissKappa = fleissKappa
        self.multiRaterGwetAC1 = multiRaterGwetAC1
        self.multiRaterPABAK = multiRaterPABAK
        self.krippendorffsAlphaNominal = krippendorffsAlphaNominal
        self.categoryBreakdown = categoryBreakdown
    }
}

// MARK: - Per-Exclusion-Code Confusion Matrix & Priority-Order Drift Models

public struct ExclusionCategoryMetrics: Sendable, Codable, Hashable, Identifiable {
    public var id: String { categoryCode }
    public let categoryCode: String
    public let displayLabel: String
    public let priorityOrder: Int?
    public let raterACount: Int
    public let raterBCount: Int
    public let exactMatchCount: Int
    public let precisionAtoB: Double
    public let recallBfromA: Double
    public let f1AgreementScore: Double
    public let specificAgreement: Double

    public init(
        categoryCode: String,
        displayLabel: String,
        priorityOrder: Int?,
        raterACount: Int,
        raterBCount: Int,
        exactMatchCount: Int,
        precisionAtoB: Double,
        recallBfromA: Double,
        f1AgreementScore: Double,
        specificAgreement: Double
    ) {
        self.categoryCode = categoryCode
        self.displayLabel = displayLabel
        self.priorityOrder = priorityOrder
        self.raterACount = raterACount
        self.raterBCount = raterBCount
        self.exactMatchCount = exactMatchCount
        self.precisionAtoB = precisionAtoB
        self.recallBfromA = recallBfromA
        self.f1AgreementScore = f1AgreementScore
        self.specificAgreement = specificAgreement
    }
}

/// Captures pairs where both reviewers excluded a record but disagreed on the ordered PRISMA exclusion reason.
public struct ExclusionPriorityDriftCase: Sendable, Codable, Hashable, Identifiable {
    public var id: String { studyID }
    public let studyID: String
    public let citeKey: String
    public let raterACode: String
    public let raterAPriority: Int
    public let raterBCode: String
    public let raterBPriority: Int
    public let priorityStepDistance: Int
    public let recommendedCanonicalCode: String

    public init(
        studyID: String,
        citeKey: String,
        raterACode: String,
        raterAPriority: Int,
        raterBCode: String,
        raterBPriority: Int,
        priorityStepDistance: Int,
        recommendedCanonicalCode: String
    ) {
        self.studyID = studyID
        self.citeKey = citeKey
        self.raterACode = raterACode
        self.raterAPriority = raterAPriority
        self.raterBCode = raterBCode
        self.raterBPriority = raterBPriority
        self.priorityStepDistance = priorityStepDistance
        self.recommendedCanonicalCode = recommendedCanonicalCode
    }
}

/// Complete $K \times K$ confusion matrix over `INCLUDE`, `MAYBE`, and ordered `ExclusionReasonRule` codes.
public struct ExclusionCodeConfusionMatrix: Sendable, Codable, Hashable {
    public let orderedCategoryCodes: [String]
    public let categoryLabelsByCode: [String: String]
    /// Row = Reviewer A category index, Column = Reviewer B category index.
    public let countsMatrix: [[Int]]
    public let totalPairedStudies: Int
    public let overallExactCategoryAccuracy: Double
    public let nominalMulticlassKappa: PsychometricStatisticEstimate
    public let perCategoryMetrics: [ExclusionCategoryMetrics]
    public let dualExcludedCodeMismatchCount: Int
    public let priorityDriftCases: [ExclusionPriorityDriftCase]
    public let stuartMaxwellChiSquare: Double
    public let stuartMaxwellDegreesOfFreedom: Int
    public let stuartMaxwellPValue: Double

    public init(
        orderedCategoryCodes: [String],
        categoryLabelsByCode: [String: String],
        countsMatrix: [[Int]],
        totalPairedStudies: Int,
        overallExactCategoryAccuracy: Double,
        nominalMulticlassKappa: PsychometricStatisticEstimate,
        perCategoryMetrics: [ExclusionCategoryMetrics],
        dualExcludedCodeMismatchCount: Int,
        priorityDriftCases: [ExclusionPriorityDriftCase],
        stuartMaxwellChiSquare: Double,
        stuartMaxwellDegreesOfFreedom: Int,
        stuartMaxwellPValue: Double
    ) {
        self.orderedCategoryCodes = orderedCategoryCodes
        self.categoryLabelsByCode = categoryLabelsByCode
        self.countsMatrix = countsMatrix
        self.totalPairedStudies = totalPairedStudies
        self.overallExactCategoryAccuracy = overallExactCategoryAccuracy
        self.nominalMulticlassKappa = nominalMulticlassKappa
        self.perCategoryMetrics = perCategoryMetrics
        self.dualExcludedCodeMismatchCount = dualExcludedCodeMismatchCount
        self.priorityDriftCases = priorityDriftCases
        self.stuartMaxwellChiSquare = stuartMaxwellChiSquare
        self.stuartMaxwellDegreesOfFreedom = stuartMaxwellDegreesOfFreedom
        self.stuartMaxwellPValue = stuartMaxwellPValue
    }

    public func count(raterACode: String, raterBCode: String) -> Int {
        guard let r = orderedCategoryCodes.firstIndex(of: raterACode),
              let c = orderedCategoryCodes.firstIndex(of: raterBCode),
              r < countsMatrix.count,
              c < countsMatrix[r].count else {
            return 0
        }
        return countsMatrix[r][c]
    }
}

// MARK: - Gold-Standard Seed Study Recall Validation Models

/// Known eligible benchmark ("sentinel") study used to audit search strategy coverage and reviewer sensitivity.
public struct GoldStandardSeedStudy: Sendable, Codable, Hashable, Identifiable {
    public var id: String { seedID }
    public let seedID: String
    public let expectedCiteKey: String?
    public let expectedDOI: String?
    public let canonicalTitle: String
    public let publicationYear: Int
    public let inclusionRationale: String

    public init(
        seedID: String,
        expectedCiteKey: String? = nil,
        expectedDOI: String? = nil,
        canonicalTitle: String,
        publicationYear: Int,
        inclusionRationale: String
    ) {
        self.seedID = seedID
        self.expectedCiteKey = expectedCiteKey
        self.expectedDOI = expectedDOI
        self.canonicalTitle = canonicalTitle
        self.publicationYear = publicationYear
        self.inclusionRationale = inclusionRationale
    }
}

public enum SeedValidationOutcomeKind: String, Sendable, Codable, Hashable {
    case retainedIncluded = "RETAINED_INCLUDED"
    case pendingScreeningOrAdjudication = "PENDING_DECISION"
    case erroneouslyExcludedAtTitleAbstract = "FALSE_NEGATIVE_TA"
    case erroneouslyExcludedAtFullText = "FALSE_NEGATIVE_FT"
    case missingFromRetrievedCorpus = "MISSING_FROM_SEARCH"
}

public struct SeedStudyAuditOutcome: Sendable, Codable, Hashable, Identifiable {
    public var id: String { seed.seedID }
    public let seed: GoldStandardSeedStudy
    public let matchedStudyID: String?
    public let matchedCiteKey: String?
    public let matchMethod: String
    public let raterADecision: ScreeningDecision?
    public let raterBDecision: ScreeningDecision?
    public let finalEffectiveDecision: ScreeningDecision?
    public let outcomeKind: SeedValidationOutcomeKind
    public let remediationAdvice: String

    public init(
        seed: GoldStandardSeedStudy,
        matchedStudyID: String?,
        matchedCiteKey: String?,
        matchMethod: String,
        raterADecision: ScreeningDecision?,
        raterBDecision: ScreeningDecision?,
        finalEffectiveDecision: ScreeningDecision?,
        outcomeKind: SeedValidationOutcomeKind,
        remediationAdvice: String
    ) {
        self.seed = seed
        self.matchedStudyID = matchedStudyID
        self.matchedCiteKey = matchedCiteKey
        self.matchMethod = matchMethod
        self.raterADecision = raterADecision
        self.raterBDecision = raterBDecision
        self.finalEffectiveDecision = finalEffectiveDecision
        self.outcomeKind = outcomeKind
        self.remediationAdvice = remediationAdvice
    }
}

public struct SeedRecallValidationReport: Sendable, Codable, Hashable {
    public let totalSeedCount: Int
    public let retrievedInCorpusCount: Int
    public let searchStrategyRecall: Double
    public let searchRecall95CILower: Double
    public let searchRecall95CIUpper: Double
    public let retainedInSynthesisCount: Int
    public let screeningSensitivityAmongRetrieved: Double
    public let endToEndSeedRecall: Double
    public let endToEndRecall95CILower: Double
    public let endToEndRecall95CIUpper: Double
    public let raterASeedSensitivity: Double
    public let raterBSeedSensitivity: Double
    public let passesStrictPRISMASeedGate: Bool
    public let perSeedOutcomes: [SeedStudyAuditOutcome]

    public init(
        totalSeedCount: Int,
        retrievedInCorpusCount: Int,
        searchStrategyRecall: Double,
        searchRecall95CILower: Double,
        searchRecall95CIUpper: Double,
        retainedInSynthesisCount: Int,
        screeningSensitivityAmongRetrieved: Double,
        endToEndSeedRecall: Double,
        endToEndRecall95CILower: Double,
        endToEndRecall95CIUpper: Double,
        raterASeedSensitivity: Double,
        raterBSeedSensitivity: Double,
        passesStrictPRISMASeedGate: Bool,
        perSeedOutcomes: [SeedStudyAuditOutcome]
    ) {
        self.totalSeedCount = totalSeedCount
        self.retrievedInCorpusCount = retrievedInCorpusCount
        self.searchStrategyRecall = searchStrategyRecall
        self.searchRecall95CILower = searchRecall95CILower
        self.searchRecall95CIUpper = searchRecall95CIUpper
        self.retainedInSynthesisCount = retainedInSynthesisCount
        self.screeningSensitivityAmongRetrieved = screeningSensitivityAmongRetrieved
        self.endToEndSeedRecall = endToEndSeedRecall
        self.endToEndRecall95CILower = endToEndRecall95CILower
        self.endToEndRecall95CIUpper = endToEndRecall95CIUpper
        self.raterASeedSensitivity = raterASeedSensitivity
        self.raterBSeedSensitivity = raterBSeedSensitivity
        self.passesStrictPRISMASeedGate = passesStrictPRISMASeedGate
        self.perSeedOutcomes = perSeedOutcomes
    }
}

// MARK: - Near-Miss Recheck Sampler Models

public enum NearMissRiskStratum: String, Sendable, Codable, Hashable, CaseIterable {
    case splitVoteAdjudicatedExclude = "Split Vote Adjudicated to Exclude"
    case maybeBorderlineExclude = "Borderline Maybe / Exclude Split"
    case latePriorityExclusionWithHighPICOMatch = "Late-Priority Exclusion + High PICO Overlap"
    case consensusExcludeLexicalNeighbor = "Consensus Exclude Lexical Neighbor"
    case randomControlAudit = "Random Baseline Control Sample"
}

public struct NearMissRecheckCandidate: Sendable, Codable, Hashable, Identifiable {
    public var id: String { studyID }
    public let studyID: String
    public let citeKey: String
    public let title: String
    public let stage: ScreeningStage
    public let assignedExclusionCode: String
    public let riskStratum: NearMissRiskStratum
    public let picoLexicalAffinity: Double
    public let includedCentroidCosineSimilarity: Double
    public let falseNegativeRiskScore: Double
    public let matchedPICOTerms: [String]
    public let recheckPrompt: String

    public init(
        studyID: String,
        citeKey: String,
        title: String,
        stage: ScreeningStage,
        assignedExclusionCode: String,
        riskStratum: NearMissRiskStratum,
        picoLexicalAffinity: Double,
        includedCentroidCosineSimilarity: Double,
        falseNegativeRiskScore: Double,
        matchedPICOTerms: [String],
        recheckPrompt: String
    ) {
        self.studyID = studyID
        self.citeKey = citeKey
        self.title = title
        self.stage = stage
        self.assignedExclusionCode = assignedExclusionCode
        self.riskStratum = riskStratum
        self.picoLexicalAffinity = picoLexicalAffinity
        self.includedCentroidCosineSimilarity = includedCentroidCosineSimilarity
        self.falseNegativeRiskScore = falseNegativeRiskScore
        self.matchedPICOTerms = matchedPICOTerms
        self.recheckPrompt = recheckPrompt
    }
}

public struct NearMissRecheckSamplingConfig: Sendable, Codable, Hashable {
    public var targetSampleFraction: Double
    public var minimumSampleSize: Int
    public var maximumSampleSize: Int
    public var highRiskQuotaProportion: Double
    public var randomSeed: UInt64

    public init(
        targetSampleFraction: Double = 0.15,
        minimumSampleSize: Int = 5,
        maximumSampleSize: Int = 50,
        highRiskQuotaProportion: Double = 0.75,
        randomSeed: UInt64 = 0x5343_484F_4C41_5236
    ) {
        self.targetSampleFraction = min(1.0, max(0.01, targetSampleFraction))
        self.minimumSampleSize = max(1, minimumSampleSize)
        self.maximumSampleSize = max(self.minimumSampleSize, maximumSampleSize)
        self.highRiskQuotaProportion = min(1.0, max(0.0, highRiskQuotaProportion))
        self.randomSeed = randomSeed
    }
}

public struct NearMissRecheckPlan: Sendable, Codable, Hashable {
    public let totalExcludedPoolCount: Int
    public let selectedSampleCount: Int
    public let randomSeedUsed: UInt64
    public let highRiskSelectedCount: Int
    public let randomControlSelectedCount: Int
    public let zeroDefectUpper95FalseOmissionBound: Double
    public let candidates: [NearMissRecheckCandidate]

    public init(
        totalExcludedPoolCount: Int,
        selectedSampleCount: Int,
        randomSeedUsed: UInt64,
        highRiskSelectedCount: Int,
        randomControlSelectedCount: Int,
        zeroDefectUpper95FalseOmissionBound: Double,
        candidates: [NearMissRecheckCandidate]
    ) {
        self.totalExcludedPoolCount = totalExcludedPoolCount
        self.selectedSampleCount = selectedSampleCount
        self.randomSeedUsed = randomSeedUsed
        self.highRiskSelectedCount = highRiskSelectedCount
        self.randomControlSelectedCount = randomControlSelectedCount
        self.zeroDefectUpper95FalseOmissionBound = zeroDefectUpper95FalseOmissionBound
        self.candidates = candidates
    }
}

///Deterministic SplitMix64 generator for 100% reproducible stratified QC sampling without global mutable state.
private struct DeterministicSplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func shuffle<T>(_ elements: inout [T]) {
        guard elements.count > 1 else { return }
        for i in stride(from: elements.count - 1, through: 1, by: -1) {
            let j = Int(nextUInt64() % UInt64(i + 1))
            if i != j {
                elements.swapAt(i, j)
            }
        }
    }
}

// MARK: - Inter-Rater Reliability, Seed Recall & Near-Miss QC Engine

/// Industrial psychometric quality-control engine for PRISMA 2020 systematic, scoping, and rapid reviews.
public struct InterRaterReliabilityAndSeedQCEngine: Sendable {
    public let confidenceLevel: Double

    public init(confidenceLevel: Double = 0.95) {
        self.confidenceLevel = min(0.999, max(0.50, confidenceLevel))
    }

    // MARK: 1. Dual-Blind Cohen's Kappa, Byrt's PABAK & Gwet's AC1

    /// Computes exact dual-blind psychometric reliability across `studies` with Fleiss-Cohen-Everitt asymptotic SE & 95% CIs.
    public func evaluateDualRaterAgreement(
        studies: [ScreeningStudyRecord],
        protocolSpec: PICOProtocolSpec,
        treatMaybeAsPositive: Bool = true,
        multiclassWeighting: KappaWeightingScheme = .linearCicchettiAllison
    ) -> DualRaterAgreementReport {
        var aCount = 0 // Rater A +, Rater B +
        var bCount = 0 // Rater A +, Rater B -
        var cCount = 0 // Rater A -, Rater B +
        var dCount = 0 // Rater A -, Rater B -

        // 3-tier ordinal matrix for Include (2) > Maybe (1) > Exclude (0)
        var ordinalMatrix = Array(repeating: Array(repeating: 0, count: 3), count: 3)

        for study in studies {
            guard let voteA = study.reviewerADecision,
                  let voteB = study.reviewerBDecision else {
                continue
            }
            let posA = Self.isBinaryPositive(voteA, treatMaybeAsPositive: treatMaybeAsPositive)
            let posB = Self.isBinaryPositive(voteB, treatMaybeAsPositive: treatMaybeAsPositive)
            switch (posA, posB) {
            case (true, true): aCount += 1
            case (true, false): bCount += 1
            case (false, true): cCount += 1
            case (false, false): dCount += 1
            }

            let ordA = Self.ordinalTier(voteA)
            let ordB = Self.ordinalTier(voteB)
            ordinalMatrix[ordA][ordB] += 1
        }

        let total = aCount + bCount + cCount + dCount
        guard total > 0 else {
            let emptyStat = PsychometricStatisticEstimate(
                metricName: "Empty Cohort",
                pointEstimate: 1.0,
                standardError: 0.0,
                nullStandardError: 0.0,
                confidenceLevel: confidenceLevel
            )
            return DualRaterAgreementReport(
                evaluatedStudyCount: 0,
                bothPositiveCount: 0,
                raterAPositiveRaterBNegativeCount: 0,
                raterANegativeRaterBPositiveCount: 0,
                bothNegativeCount: 0,
                observedProportionAgreement: 1.0,
                expectedChanceAgreementCohen: 0.5,
                expectedChanceAgreementGwet: 0.5,
                specificPositiveAgreement: 1.0,
                specificNegativeAgreement: 1.0,
                prevalenceIndex: 0.0,
                biasIndex: 0.0,
                mcnemarChiSquare: 0.0,
                mcnemarPValue: 1.0,
                cohensKappa: emptyStat,
                byrtsPABAK: emptyStat,
                gwetsAC1: emptyStat,
                weightedMulticlassKappa: emptyStat,
                feinsteinCicchettiParadoxDetected: false,
                diagnosticNarrative: "No dual-screened records available yet."
            )
        }

        let n = Double(total)
        let p11 = Double(aCount) / n
        let p12 = Double(bCount) / n
        let p21 = Double(cCount) / n
        let p22 = Double(dCount) / n

        let rowPos = p11 + p12
        let rowNeg = p21 + p22
        let colPos = p11 + p21
        let colNeg = p12 + p22

        let po = p11 + p22
        let peCohen = rowPos * colPos + rowNeg * colNeg

        // Fleiss, Cohen & Everitt (1969) exact non-null & null asymptotic standard errors for 2x2 kappa
        let kappaValue: Double
        let kappaSE: Double
        let kappaNullSE: Double
        if abs(1.0 - peCohen) < 1e-12 {
            kappaValue = 1.0
            kappaSE = 0.0
            kappaNullSE = 0.0
        } else {
            kappaValue = (po - peCohen) / (1.0 - peCohen)
            let oneMinusPe = 1.0 - peCohen

            // Diagonal term A: sum_i p_ii * [1 - (p_{i.} + p_{.i})(1 - kappa)]^2
            let termDiagPos = p11 * Foundation.pow(1.0 - (rowPos + colPos) * (1.0 - kappaValue), 2.0)
            let termDiagNeg = p22 * Foundation.pow(1.0 - (rowNeg + colNeg) * (1.0 - kappaValue), 2.0)
            let bigA = termDiagPos + termDiagNeg

            // Off-diagonal term B: (1 - kappa)^2 * sum_{i != j} p_ij * (p_{.i} + p_{j.})^2
            let termOff12 = p12 * Foundation.pow(colPos + rowNeg, 2.0)
            let termOff21 = p21 * Foundation.pow(colNeg + rowPos, 2.0)
            let bigB = Foundation.pow(1.0 - kappaValue, 2.0) * (termOff12 + termOff21)

            // Term C: [kappa - pe * (1 - kappa)]^2
            let bigC = Foundation.pow(kappaValue - peCohen * (1.0 - kappaValue), 2.0)
            let variance = max(0.0, (bigA + bigB - bigC) / (n * oneMinusPe * oneMinusPe))
            kappaSE = variance.squareRoot()

            // Null variance under H0: kappa = 0
            let nullSumSq = (rowPos * colPos) * Foundation.pow(rowPos + colPos, 2.0)
                + (rowNeg * colNeg) * Foundation.pow(rowNeg + colNeg, 2.0)
            let nullVar = max(0.0, (peCohen + peCohen * peCohen - nullSumSq) / (n * oneMinusPe * oneMinusPe))
            kappaNullSE = nullVar.squareRoot()
        }

        let cohenEstimate = PsychometricStatisticEstimate(
            metricName: "Cohen's Kappa",
            pointEstimate: kappaValue,
            standardError: kappaSE,
            nullStandardError: kappaNullSE,
            confidenceLevel: confidenceLevel
        )

        // Byrt's PABAK = 2 * po - 1, Var(PABAK) = 4 * po * (1 - po) / n, Var_0(PABAK) = 1 / n
        let pabakValue = 2.0 * po - 1.0
        let pabakSE = (4.0 * max(0.0, po * (1.0 - po)) / n).squareRoot()
        let pabakNullSE = (1.0 / n).squareRoot()
        let pabakEstimate = PsychometricStatisticEstimate(
            metricName: "Byrt's PABAK",
            pointEstimate: pabakValue,
            standardError: pabakSE,
            nullStandardError: pabakNullSE,
            confidenceLevel: confidenceLevel
        )

        // Gwet's AC1 (2008) for binary classification: pi_pos = (rowPos + colPos)/2, e_gamma = 2 * pi_pos * (1 - pi_pos)
        let piPos = 0.5 * (rowPos + colPos)
        let piNeg = 1.0 - piPos
        let peGwet = 2.0 * piPos * piNeg
        let ac1Value: Double
        let ac1SE: Double
        let ac1NullSE: Double
        if abs(1.0 - peGwet) < 1e-12 {
            ac1Value = po >= 1.0 - 1e-9 ? 1.0 : (2.0 * po - 1.0)
            ac1SE = pabakSE
            ac1NullSE = pabakNullSE
        } else {
            ac1Value = (po - peGwet) / (1.0 - peGwet)
            // Gwet (2008) unconditional subject-level variance estimator across the 4 cell profiles:
            // For subject k: r_k in {(+,+), (+,-), (-,+), (-,-)}
            let oneMinusEg = 1.0 - peGwet
            func subjectScore(agree: Double, posCountInPair: Double) -> Double {
                // Local e_gamma linearization: derivative contribution per subject
                let piSubjPos = 0.5 * posCountInPair
                let egSubj = 2.0 * (piPos * (1.0 - piSubjPos) + piNeg * piSubjPos) - peGwet
                return (agree - ac1Value * (1.0 - egSubj) - egSubj) / oneMinusEg
            }
            // Direct Gwet (2008) closed-form variance for 2 raters, 2 categories:
            let s11 = subjectScore(agree: 1.0, posCountInPair: 2.0)
            let s12 = subjectScore(agree: 0.0, posCountInPair: 1.0)
            let s21 = subjectScore(agree: 0.0, posCountInPair: 1.0)
            let s22 = subjectScore(agree: 1.0, posCountInPair: 0.0)
            let meanS = p11 * s11 + p12 * s12 + p21 * s21 + p22 * s22
            let sumSqDev = Double(aCount) * Foundation.pow(s11 - meanS, 2.0)
                + Double(bCount) * Foundation.pow(s12 - meanS, 2.0)
                + Double(cCount) * Foundation.pow(s21 - meanS, 2.0)
                + Double(dCount) * Foundation.pow(s22 - meanS, 2.0)
            let denomSubjects = max(1.0, n * (n - 1.0))
            ac1SE = max(0.0, sumSqDev / denomSubjects).squareRoot()
            ac1NullSE = (peGwet * (1.0 - peGwet) / (n * oneMinusEg * oneMinusEg)).squareRoot()
        }

        let ac1Estimate = PsychometricStatisticEstimate(
            metricName: "Gwet's AC1",
            pointEstimate: ac1Value,
            standardError: ac1SE,
            nullStandardError: ac1NullSE,
            confidenceLevel: confidenceLevel
        )

        // Weighted 3-tier (Exclude / Maybe / Include) Cohen's Kappa
        let weightedEstimate = computeWeightedKappaFromMatrix(
            countsMatrix: ordinalMatrix,
            scheme: multiclassWeighting,
            metricName: "Weighted 3-Tier Kappa (\(multiclassWeighting.rawValue))"
        )

        // Specific positive & negative agreement (Cicchetti & Feinstein 1990)
        let posDenom = 2 * aCount + bCount + cCount
        let negDenom = 2 * dCount + bCount + cCount
        let pPos = posDenom > 0 ? (2.0 * Double(aCount) / Double(posDenom)) : 1.0
        let pNeg = negDenom > 0 ? (2.0 * Double(dCount) / Double(negDenom)) : 1.0

        // Prevalence Index (PI) & Bias Index (BI)
        let prevalenceIdx = Double(abs(aCount - dCount)) / n
        let biasIdx = Double(abs(bCount - cCount)) / n

        // McNemar exact continuity-corrected test of rater directional bias
        let discordant = bCount + cCount
        let mcnemarChi2: Double
        let mcnemarP: Double
        if discordant > 0 {
            let diff = max(0.0, Double(abs(bCount - cCount)) - 1.0)
            mcnemarChi2 = (diff * diff) / Double(discordant)
            mcnemarP = PsychometricNormalMath.chiSquareUpperTailPValue(chiSquare: mcnemarChi2, degreesOfFreedom: 1)
        } else {
            mcnemarChi2 = 0.0
            mcnemarP = 1.0
        }

        let paradox = (po >= 0.80) && (kappaValue < 0.45) && (prevalenceIdx >= 0.60) && ((ac1Value - kappaValue) >= 0.25)

        // Check exclusion-code mismatches briefly for diagnostic narrative
        let codeMismatchCount = studies.reduce(into: 0) { acc, s in
            if case .exclude(let ca) = s.reviewerADecision,
               case .exclude(let cb) = s.reviewerBDecision,
               ca != cb {
                acc += 1
            }
        }
        let validRuleCount = protocolSpec.exclusionRules.count

        let narrative: String
        if paradox {
            narrative = String(
                format: "Feinstein-Cicchetti prevalence paradox detected: observed agreement is high (p_o = %.1f%%, PI = %.2f), depressing Cohen's κ to %.3f while Gwet's AC1 = %.3f and PABAK = %.3f confirm %@ calibration (%d exclusion-code disagreements across %d protocol rules).",
                po * 100.0,
                prevalenceIdx,
                kappaValue,
                ac1Value,
                pabakValue,
                ac1Estimate.benchmarkBand.rawValue,
                codeMismatchCount,
                validRuleCount
            )
        } else {
            narrative = String(
                format: "Dual-blind calibration across n = %d records: p_o = %.1f%%, Cohen's κ = %.3f (95%% CI [%.3f, %.3f]), PABAK = %.3f, Gwet's AC1 = %.3f, McNemar p = %.3f (%d exclusion-code disagreements across %d protocol rules).",
                total,
                po * 100.0,
                kappaValue,
                cohenEstimate.lowerCI,
                cohenEstimate.upperCI,
                pabakValue,
                ac1Value,
                mcnemarP,
                codeMismatchCount,
                validRuleCount
            )
        }

        return DualRaterAgreementReport(
            evaluatedStudyCount: total,
            bothPositiveCount: aCount,
            raterAPositiveRaterBNegativeCount: bCount,
            raterANegativeRaterBPositiveCount: cCount,
            bothNegativeCount: dCount,
            observedProportionAgreement: po,
            expectedChanceAgreementCohen: peCohen,
            expectedChanceAgreementGwet: peGwet,
            specificPositiveAgreement: pPos,
            specificNegativeAgreement: pNeg,
            prevalenceIndex: prevalenceIdx,
            biasIndex: biasIdx,
            mcnemarChiSquare: mcnemarChi2,
            mcnemarPValue: mcnemarP,
            cohensKappa: cohenEstimate,
            byrtsPABAK: pabakEstimate,
            gwetsAC1: ac1Estimate,
            weightedMulticlassKappa: weightedEstimate,
            feinsteinCicchettiParadoxDetected: paradox,
            diagnosticNarrative: narrative
        )
    }

    // MARK: 2. Fleiss' Kappa, Multi-Rater Gwet's AC1 & Krippendorff's Alpha (M >= 3 Reviewers)

    /// Evaluates multi-rater agreement ($M \ge 2$, designed for $M \ge 3$ panels) using Fleiss (1971), Fleiss-Nee-Landis (1979) asymptotic SE, Gwet's multi-rater $AC_1$, and Krippendorff's nominal $\alpha$.
    public func evaluateMultiRaterPanel(
        ballots: [MultiRaterScreeningBallot],
        collapseExclusionsIntoSingleCategory: Bool = false
    ) -> MultiRaterPanelAgreementReport {
        let validBallots = ballots.filter { $0.votesByReviewerID.count >= 2 }
        var reviewerSet = Set<String>()
        var categorySet = Set<String>()
        var raterCountHistogram: [Int: Int] = [:]

        for ballot in validBallots {
            let m = ballot.votesByReviewerID.count
            raterCountHistogram[m, default: 0] += 1
            for (revID, vote) in ballot.votesByReviewerID {
                reviewerSet.insert(revID)
                categorySet.insert(Self.canonicalCategoryKey(for: vote, collapseExclusions: collapseExclusionsIntoSingleCategory))
            }
        }

        let sortedReviewers = reviewerSet.sorted()
        let orderedCategories = Self.sortCanonicalCategories(Array(categorySet))
        let nSubjects = validBallots.count
        let kCategories = max(2, orderedCategories.count)

        guard nSubjects > 0 else {
            let emptyEst = PsychometricStatisticEstimate(
                metricName: "Empty Multi-Rater Panel",
                pointEstimate: 1.0,
                standardError: 0.0,
                nullStandardError: 0.0,
                confidenceLevel: confidenceLevel
            )
            return MultiRaterPanelAgreementReport(
                studyCount: 0,
                distinctReviewerIDs: sortedReviewers,
                modalRatersPerStudy: 0,
                categoryLabels: orderedCategories,
                overallObservedAgreement: 1.0,
                fleissExpectedAgreement: 0.5,
                unanimousStudyCount: 0,
                unanimousRate: 1.0,
                fleissKappa: emptyEst,
                multiRaterGwetAC1: emptyEst,
                multiRaterPABAK: emptyEst,
                krippendorffsAlphaNominal: 1.0,
                categoryBreakdown: []
            )
        }

        // Pad to at least 2 categories so single-class unanimity still yields well-defined AC1 / PABAK
        var categories = orderedCategories
        if categories.count == 1 {
            categories.append(categories[0] == "INCLUDE" ? "EXCLUDE" : "INCLUDE")
        }
        var catIndex: [String: Int] = [:]
        for (idx, c) in categories.enumerated() {
            catIndex[c] = idx
        }
        let k = categories.count

        let modalM = raterCountHistogram.max { a, b in
            if a.value != b.value { return a.value < b.value }
            return a.key < b.key
        }?.key ?? 2

        // Build n_ij matrix (subject i, category j) and m_i vector
        var nij = Array(repeating: Array(repeating: 0, count: k), count: nSubjects)
        var mi = Array(repeating: 0, count: nSubjects)
        var totalVotesCast = 0
        var unanimousCount = 0
        var pSubject = Array(repeating: 0.0, count: nSubjects)

        for (i, ballot) in validBallots.enumerated() {
            let m = ballot.votesByReviewerID.count
            mi[i] = m
            totalVotesCast += m
            for (_, vote) in ballot.votesByReviewerID {
                let key = Self.canonicalCategoryKey(for: vote, collapseExclusions: collapseExclusionsIntoSingleCategory)
                if let j = catIndex[key] {
                    nij[i][j] += 1
                }
            }
            var pairMatches = 0
            var maxCell = 0
            for j in 0..<k {
                let c = nij[i][j]
                pairMatches += c * (c - 1)
                if c > maxCell { maxCell = c }
            }
            if maxCell == m {
                unanimousCount += 1
            }
            pSubject[i] = Double(pairMatches) / Double(m * (m - 1))
        }

        let nf = Double(nSubjects)
        let pBar = pSubject.reduce(0.0, +) / nf

        // Marginal category proportions p_j across all cast votes
        var pj = Array(repeating: 0.0, count: k)
        for j in 0..<k {
            var colSum = 0
            for i in 0..<nSubjects {
                colSum += nij[i][j]
            }
            pj[j] = totalVotesCast > 0 ? Double(colSum) / Double(totalVotesCast) : (1.0 / Double(k))
        }

        let peFleiss = pj.reduce(0.0) { $0 + $1 * $1 }
        let sumPjCubed = pj.reduce(0.0) { $0 + $1 * $1 * $1 }

        // Harmonic mean of m_i(m_i - 1) for Fleiss-Nee-Landis (1979) asymptotic SE under null
        let meanPairCount = mi.reduce(0.0) { $0 + Double($1 * ($1 - 1)) } / nf
        let fleissVal: Double
        let fleissNullSE: Double
        let fleissEmpiricalSE: Double

        if abs(1.0 - peFleiss) < 1e-12 {
            fleissVal = 1.0
            fleissNullSE = 0.0
            fleissEmpiricalSE = 0.0
        } else {
            fleissVal = (pBar - peFleiss) / (1.0 - peFleiss)
            let oneMinusPe = 1.0 - peFleiss
            // Fleiss, Nee & Landis (1979) corrected variance under H0:
            // Var(kappa) = [2 / (N * m * (m - 1))] * [pe - (2m - 3) pe^2 + 2(m - 2) sum(p_j^3)] / (1 - pe)^2
            let mEff = Double(modalM)
            let numerator = max(0.0, peFleiss - (2.0 * mEff - 3.0) * peFleiss * peFleiss + 2.0 * (mEff - 2.0) * sumPjCubed)
            let denom = max(1.0, nf * meanPairCount * oneMinusPe * oneMinusPe)
            fleissNullSE = (2.0 * numerator / denom).squareRoot()

            // Subject-level jackknife / Gwet-style empirical variance of P_i around pBar
            var subjectVarAccum = 0.0
            for i in 0..<nSubjects {
                let subjKappaProxy = (pSubject[i] - peFleiss) / oneMinusPe
                subjectVarAccum += Foundation.pow(subjKappaProxy - fleissVal, 2.0)
            }
            let empVar = nSubjects > 1 ? (subjectVarAccum / (nf * (nf - 1.0))) : (fleissNullSE * fleissNullSE)
            fleissEmpiricalSE = max(fleissNullSE * 0.5, empVar.squareRoot())
        }

        let fleissEstimate = PsychometricStatisticEstimate(
            metricName: "Fleiss' Kappa (M = \(modalM))",
            pointEstimate: fleissVal,
            standardError: fleissEmpiricalSE,
            nullStandardError: fleissNullSE,
            confidenceLevel: confidenceLevel
        )

        // Multi-rater Gwet's AC1: e_gamma = (1 / (K - 1)) * sum_{j=1}^K pi_j * (1 - pi_j)
        var piGwet = Array(repeating: 0.0, count: k)
        for j in 0..<k {
            var avgShare = 0.0
            for i in 0..<nSubjects {
                avgShare += Double(nij[i][j]) / Double(mi[i])
            }
            piGwet[j] = avgShare / nf
        }
        let sumPiOneMinusPi = piGwet.reduce(0.0) { $0 + $1 * (1.0 - $1) }
        let eGamma = sumPiOneMinusPi / Double(max(1, k - 1))
        let ac1MultiVal: Double
        let ac1MultiSE: Double
        let ac1MultiNullSE: Double
        if abs(1.0 - eGamma) < 1e-12 {
            ac1MultiVal = 1.0
            ac1MultiSE = 0.0
            ac1MultiNullSE = 0.0
        } else {
            ac1MultiVal = (pBar - eGamma) / (1.0 - eGamma)
            let oneMinusEg = 1.0 - eGamma
            var gwetSq = 0.0
            for i in 0..<nSubjects {
                var eGammaSubj = 0.0
                for j in 0..<k {
                    let pij = Double(nij[i][j]) / Double(mi[i])
                    eGammaSubj += pij * (1.0 - piGwet[j]) + (1.0 - pij) * piGwet[j]
                }
                eGammaSubj = (eGammaSubj / Double(max(1, k - 1))) - eGamma
                let gwetPointI = (pSubject[i] - ac1MultiVal * (1.0 - eGammaSubj) - eGammaSubj) / oneMinusEg
                gwetSq += gwetPointI * gwetPointI
            }
            ac1MultiSE = nSubjects > 1 ? (gwetSq / (nf * (nf - 1.0))).squareRoot() : 0.0
            ac1MultiNullSE = (2.0 * eGamma * (1.0 - eGamma) / max(1.0, nf * meanPairCount * oneMinusEg * oneMinusEg)).squareRoot()
        }

        let ac1MultiEstimate = PsychometricStatisticEstimate(
            metricName: "Multi-Rater Gwet's AC1",
            pointEstimate: ac1MultiVal,
            standardError: ac1MultiSE,
            nullStandardError: ac1MultiNullSE,
            confidenceLevel: confidenceLevel
        )

        // Generalized multi-category PABAK = (K * pBar - 1) / (K - 1)
        let kf = Double(max(2, kCategories))
        let multiPabakVal = (kf * pBar - 1.0) / (kf - 1.0)
        var pSubjVar = 0.0
        for i in 0..<nSubjects {
            pSubjVar += Foundation.pow(pSubject[i] - pBar, 2.0)
        }
        let pBarSE = nSubjects > 1 ? (pSubjVar / (nf * (nf - 1.0))).squareRoot() : 0.0
        let multiPabakSE = (kf / (kf - 1.0)) * pBarSE
        let multiPabakNullSE = (2.0 / max(1.0, nf * meanPairCount * (kf - 1.0))).squareRoot()
        let multiPabakEstimate = PsychometricStatisticEstimate(
            metricName: "Multi-Category PABAK",
            pointEstimate: multiPabakVal,
            standardError: multiPabakSE,
            nullStandardError: multiPabakNullSE,
            confidenceLevel: confidenceLevel
        )

        // Krippendorff's Alpha (nominal) handling arbitrary m_i >= 2 per unit i
        let krippendorffAlpha = computeNominalKrippendorffAlpha(nij: nij, mi: mi, categoryCount: k)

        // Per-category Fleiss kappa_j (Fleiss 1971 Eq. 14 & SE = sqrt(2 / (N * m * (m - 1))))
        let alphaTail = 1.0 - confidenceLevel
        let zCrit = PsychometricNormalMath.inverseStandardNormalCDF(1.0 - alphaTail * 0.5)
        let catSE = (2.0 / max(1.0, nf * meanPairCount)).squareRoot()
        var breakdown: [FleissCategoryKappaDetail] = []
        for j in 0..<orderedCategories.count {
            let pCat = pj[j]
            let qCat = 1.0 - pCat
            let catKappa: Double
            if pCat <= 1e-12 || qCat <= 1e-12 {
                catKappa = 1.0
            } else {
                var numerSum = 0.0
                for i in 0..<nSubjects {
                    let c = Double(nij[i][j])
                    let m = Double(mi[i])
                    numerSum += (c * (c - 1.0)) / (m * (m - 1.0))
                }
                let pAgreeJ = numerSum / nf
                catKappa = (pAgreeJ - pCat * pCat) / (pCat * qCat)
            }
            let zVal = catSE > 1e-12 ? (catKappa / catSE) : 0.0
            let pVal = PsychometricNormalMath.twoSidedNormalPValue(zScore: zVal)
            breakdown.append(
                FleissCategoryKappaDetail(
                    categoryLabel: orderedCategories[j],
                    marginalPrevalence: pCat,
                    categoryKappa: catKappa,
                    standardError: catSE,
                    zStatistic: zVal,
                    twoSidedPValue: pVal,
                    lower95CI: max(-1.0, min(1.0, catKappa - zCrit * catSE)),
                    upper95CI: max(-1.0, min(1.0, catKappa + zCrit * catSE))
                )
            )
        }

        return MultiRaterPanelAgreementReport(
            studyCount: nSubjects,
            distinctReviewerIDs: sortedReviewers,
            modalRatersPerStudy: modalM,
            categoryLabels: orderedCategories,
            overallObservedAgreement: pBar,
            fleissExpectedAgreement: peFleiss,
            unanimousStudyCount: unanimousCount,
            unanimousRate: Double(unanimousCount) / nf,
            fleissKappa: fleissEstimate,
            multiRaterGwetAC1: ac1MultiEstimate,
            multiRaterPABAK: multiPabakEstimate,
            krippendorffsAlphaNominal: krippendorffAlpha,
            categoryBreakdown: breakdown
        )
    }

    // MARK: 3. Per-Exclusion-Code Confusion Matrix & Priority Drift Diagnostics

    /// Builds a complete $K \times K$ confusion matrix over `INCLUDE`, `MAYBE`, and ordered `ExclusionReasonRule` codes.
    public func buildExclusionConfusionMatrix(
        studies: [ScreeningStudyRecord],
        protocolSpec: PICOProtocolSpec
    ) -> ExclusionCodeConfusionMatrix {
        let sortedRules = protocolSpec.exclusionRules.sorted { a, b in
            if a.priorityOrder != b.priorityOrder { return a.priorityOrder < b.priorityOrder }
            return a.code < b.code
        }

        var orderedCodes: [String] = ["INCLUDE", "MAYBE"]
        var labelsByCode: [String: String] = [
            "INCLUDE": "Include / Promote",
            "MAYBE": "Maybe / Needs Full-Text Check"
        ]
        var priorityByCode: [String: Int] = [:]

        for rule in sortedRules {
            orderedCodes.append(rule.code)
            labelsByCode[rule.code] = rule.label
            priorityByCode[rule.code] = rule.priorityOrder
        }

        // Also capture any ad-hoc exclusion codes present in studies so no data is dropped
        for study in studies {
            for vote in [study.reviewerADecision, study.reviewerBDecision].compactMap({ $0 }) {
                if case .exclude(let code) = vote, labelsByCode[code] == nil {
                    orderedCodes.append(code)
                    labelsByCode[code] = "Unregistered Exclusion (\(code))"
                    priorityByCode[code] = 999
                }
            }
        }

        let k = orderedCodes.count
        var codeToIdx: [String: Int] = [:]
        for (i, code) in orderedCodes.enumerated() {
            codeToIdx[code] = i
        }

        var matrix = Array(repeating: Array(repeating: 0, count: k), count: k)
        var pairedTotal = 0
        var dualExcludeMismatch = 0
        var driftCases: [ExclusionPriorityDriftCase] = []

        for study in studies {
            guard let voteA = study.reviewerADecision,
                  let voteB = study.reviewerBDecision else {
                continue
            }
            let codeA = Self.canonicalCategoryKey(for: voteA, collapseExclusions: false)
            let codeB = Self.canonicalCategoryKey(for: voteB, collapseExclusions: false)
            guard let r = codeToIdx[codeA], let c = codeToIdx[codeB] else { continue }
            matrix[r][c] += 1
            pairedTotal += 1

            if case .exclude(let exA) = voteA, case .exclude(let exB) = voteB, exA != exB {
                dualExcludeMismatch += 1
                let prioA = priorityByCode[exA] ?? 999
                let prioB = priorityByCode[exB] ?? 999
                let canonical = prioA <= prioB ? exA : exB
                driftCases.append(
                    ExclusionPriorityDriftCase(
                        studyID: study.id,
                        citeKey: study.citeKey,
                        raterACode: exA,
                        raterAPriority: prioA,
                        raterBCode: exB,
                        raterBPriority: prioB,
                        priorityStepDistance: abs(prioA - prioB),
                        recommendedCanonicalCode: canonical
                    )
                )
            }
        }

        var rowTotals = Array(repeating: 0, count: k)
        var colTotals = Array(repeating: 0, count: k)
        var diagSum = 0
        for r in 0..<k {
            diagSum += matrix[r][r]
            for c in 0..<k {
                rowTotals[r] += matrix[r][c]
                colTotals[c] += matrix[r][c]
            }
        }

        let exactAcc = pairedTotal > 0 ? Double(diagSum) / Double(pairedTotal) : 1.0
        let nominalKappa = computeWeightedKappaFromMatrix(
            countsMatrix: matrix,
            scheme: .unweighted,
            metricName: "Multiclass Exclusion-Code Kappa"
        )

        var categoryMetrics: [ExclusionCategoryMetrics] = []
        for idx in 0..<k {
            let code = orderedCodes[idx]
            let rCount = rowTotals[idx]
            let cCount = colTotals[idx]
            let tp = matrix[idx][idx]
            let prec = rCount > 0 ? Double(tp) / Double(rCount) : 1.0
            let rec = cCount > 0 ? Double(tp) / Double(cCount) : 1.0
            let denom = rCount + cCount
            let f1 = denom > 0 ? (2.0 * Double(tp) / Double(denom)) : 1.0
            categoryMetrics.append(
                ExclusionCategoryMetrics(
                    categoryCode: code,
                    displayLabel: labelsByCode[code] ?? code,
                    priorityOrder: priorityByCode[code],
                    raterACount: rCount,
                    raterBCount: cCount,
                    exactMatchCount: tp,
                    precisionAtoB: prec,
                    recallBfromA: rec,
                    f1AgreementScore: f1,
                    specificAgreement: f1
                )
            )
        }

        // Stuart-Maxwell / Bhapkar-diagonal marginal homogeneity statistic across active categories
        let (smChi2, smDF, smP) = computeMarginalHomogeneityTest(matrix: matrix, rowTotals: rowTotals, colTotals: colTotals)

        return ExclusionCodeConfusionMatrix(
            orderedCategoryCodes: orderedCodes,
            categoryLabelsByCode: labelsByCode,
            countsMatrix: matrix,
            totalPairedStudies: pairedTotal,
            overallExactCategoryAccuracy: exactAcc,
            nominalMulticlassKappa: nominalKappa,
            perCategoryMetrics: categoryMetrics,
            dualExcludedCodeMismatchCount: dualExcludeMismatch,
            priorityDriftCases: driftCases,
            stuartMaxwellChiSquare: smChi2,
            stuartMaxwellDegreesOfFreedom: smDF,
            stuartMaxwellPValue: smP
        )
    }

    // MARK: 4. Gold-Standard Seed Study Recall Validator

    /// Audits whether all gold-standard sentinel studies were (a) retrieved by the search strategy and (b) retained during screening.
    public func validateGoldStandardSeedRecall(
        seeds: [GoldStandardSeedStudy],
        screenedCorpus: [ScreeningStudyRecord]
    ) -> SeedRecallValidationReport {
        guard !seeds.isEmpty else {
            return SeedRecallValidationReport(
                totalSeedCount: 0,
                retrievedInCorpusCount: 0,
                searchStrategyRecall: 1.0,
                searchRecall95CILower: 1.0,
                searchRecall95CIUpper: 1.0,
                retainedInSynthesisCount: 0,
                screeningSensitivityAmongRetrieved: 1.0,
                endToEndSeedRecall: 1.0,
                endToEndRecall95CILower: 1.0,
                endToEndRecall95CIUpper: 1.0,
                raterASeedSensitivity: 1.0,
                raterBSeedSensitivity: 1.0,
                passesStrictPRISMASeedGate: true,
                perSeedOutcomes: []
            )
        }

        var outcomes: [SeedStudyAuditOutcome] = []
        var retrievedCount = 0
        var retainedCount = 0
        var raterAScreenedSeeds = 0
        var raterAPositiveSeeds = 0
        var raterBScreenedSeeds = 0
        var raterBPositiveSeeds = 0

        for seed in seeds {
            if let (matched, method) = matchSeedInCorpus(seed: seed, corpus: screenedCorpus) {
                retrievedCount += 1
                if let voteA = matched.reviewerADecision {
                    raterAScreenedSeeds += 1
                    if voteA == .include || voteA == .maybe {
                        raterAPositiveSeeds += 1
                    }
                }
                if let voteB = matched.reviewerBDecision {
                    raterBScreenedSeeds += 1
                    if voteB == .include || voteB == .maybe {
                        raterBPositiveSeeds += 1
                    }
                }

                let effective = Self.effectiveDecision(for: matched)
                let outcomeKind: SeedValidationOutcomeKind
                let advice: String

                switch effective {
                case .include:
                    retainedCount += 1
                    outcomeKind = .retainedIncluded
                    advice = "Seed study properly retrieved and retained in synthesis."
                case .maybe, nil:
                    outcomeKind = .pendingScreeningOrAdjudication
                    advice = "Seed study retrieved (\(method)) but awaits consensus or third-reviewer adjudication."
                case .exclude(let reasonCode):
                    if matched.stage == .titleAbstract {
                        outcomeKind = .erroneouslyExcludedAtTitleAbstract
                        advice = "CRITICAL FALSE NEGATIVE: Sentinel seed excluded at Title/Abstract with code '\(reasonCode)'. Refine eligibility guidance before continuing batch screening."
                    } else {
                        outcomeKind = .erroneouslyExcludedAtFullText
                        advice = "CRITICAL FALSE NEGATIVE: Sentinel seed excluded at Full-Text with code '\(reasonCode)'. Audit exclusion rule '\(reasonCode)'."
                    }
                }

                outcomes.append(
                    SeedStudyAuditOutcome(
                        seed: seed,
                        matchedStudyID: matched.id,
                        matchedCiteKey: matched.citeKey,
                        matchMethod: method,
                        raterADecision: matched.reviewerADecision,
                        raterBDecision: matched.reviewerBDecision,
                        finalEffectiveDecision: effective,
                        outcomeKind: outcomeKind,
                        remediationAdvice: advice
                    )
                )
            } else {
                outcomes.append(
                    SeedStudyAuditOutcome(
                        seed: seed,
                        matchedStudyID: nil,
                        matchedCiteKey: nil,
                        matchMethod: "Unmatched",
                        raterADecision: nil,
                        raterBDecision: nil,
                        finalEffectiveDecision: nil,
                        outcomeKind: .missingFromRetrievedCorpus,
                        remediationAdvice: "MISSING SENTINEL: Expand Boolean search query synonyms or database coverage to capture '\(seed.canonicalTitle)' (\(seed.publicationYear))."
                    )
                )
            }
        }

        let total = seeds.count
        let searchRecall = Double(retrievedCount) / Double(total)
        let searchCI = PsychometricNormalMath.wilsonScoreInterval(
            successes: retrievedCount,
            trials: total,
            confidenceLevel: confidenceLevel
        )
        let screenSens = retrievedCount > 0 ? Double(retainedCount) / Double(retrievedCount) : 0.0
        let e2eRecall = Double(retainedCount) / Double(total)
        let e2eCI = PsychometricNormalMath.wilsonScoreInterval(
            successes: retainedCount,
            trials: total,
            confidenceLevel: confidenceLevel
        )
        let sensA = raterAScreenedSeeds > 0 ? Double(raterAPositiveSeeds) / Double(raterAScreenedSeeds) : 1.0
        let sensB = raterBScreenedSeeds > 0 ? Double(raterBPositiveSeeds) / Double(raterBScreenedSeeds) : 1.0

        let anyFalseNegative = outcomes.contains {
            $0.outcomeKind == .erroneouslyExcludedAtTitleAbstract
                || $0.outcomeKind == .erroneouslyExcludedAtFullText
                || $0.outcomeKind == .missingFromRetrievedCorpus
        }

        return SeedRecallValidationReport(
            totalSeedCount: total,
            retrievedInCorpusCount: retrievedCount,
            searchStrategyRecall: searchRecall,
            searchRecall95CILower: searchCI.lower,
            searchRecall95CIUpper: searchCI.upper,
            retainedInSynthesisCount: retainedCount,
            screeningSensitivityAmongRetrieved: screenSens,
            endToEndSeedRecall: e2eRecall,
            endToEndRecall95CILower: e2eCI.lower,
            endToEndRecall95CIUpper: e2eCI.upper,
            raterASeedSensitivity: sensA,
            raterBSeedSensitivity: sensB,
            passesStrictPRISMASeedGate: !anyFalseNegative && retainedCount == total,
            perSeedOutcomes: outcomes
        )
    }

    // MARK: 5. Near-Miss Recheck Sampler & False-Omission Audit Planner

    /// Constructs a deterministic, stratified recheck sample of excluded records most at risk of false omission.
    public func sampleNearMissExclusions(
        studies: [ScreeningStudyRecord],
        protocolSpec: PICOProtocolSpec,
        config: NearMissRecheckSamplingConfig = NearMissRecheckSamplingConfig()
    ) -> NearMissRecheckPlan {
        var includedRecords: [ScreeningStudyRecord] = []
        var excludedRecords: [(study: ScreeningStudyRecord, code: String)] = []

        for study in studies {
            guard let effective = Self.effectiveDecision(for: study) else { continue }
            switch effective {
            case .include:
                includedRecords.append(study)
            case .exclude(let code):
                excludedRecords.append((study, code))
            case .maybe:
                break
            }
        }

        let totalExcluded = excludedRecords.count
        guard totalExcluded > 0 else {
            return NearMissRecheckPlan(
                totalExcludedPoolCount: 0,
                selectedSampleCount: 0,
                randomSeedUsed: config.randomSeed,
                highRiskSelectedCount: 0,
                randomControlSelectedCount: 0,
                zeroDefectUpper95FalseOmissionBound: 0.0,
                candidates: []
            )
        }

        // Build PICO term set + TF centroid vector of included studies
        let picoTokens = Self.extractMeaningfulTokens(
            [
                protocolSpec.population,
                protocolSpec.intervention,
                protocolSpec.comparator,
                protocolSpec.outcomes,
                protocolSpec.inclusionCriteria.joined(separator: " ")
            ].joined(separator: " ")
        )
        let picoTokenSet = Set(picoTokens)

        var includedCentroid: [String: Double] = [:]
        for inc in includedRecords {
            let toks = Self.extractMeaningfulTokens(inc.title + " " + inc.abstractText)
            for t in toks {
                includedCentroid[t, default: 0.0] += 1.0
            }
        }
        let centroidNorm = includedCentroid.values.reduce(0.0) { $0 + $1 * $1 }.squareRoot()

        let maxRulePriority = max(1, protocolSpec.exclusionRules.map(\.priorityOrder).max() ?? 4)
        var priorityByCode: [String: Int] = [:]
        for rule in protocolSpec.exclusionRules {
            priorityByCode[rule.code] = rule.priorityOrder
        }

        // Score every excluded study for false-negative risk
        var scoredPool: [NearMissRecheckCandidate] = []
        scoredPool.reserveCapacity(totalExcluded)

        for (study, exCode) in excludedRecords {
            let docTokens = Self.extractMeaningfulTokens(study.title + " " + study.abstractText)
            let docSet = Set(docTokens)
            let matchedPICO = docSet.intersection(picoTokenSet).sorted()
            let picoAffinity = picoTokenSet.isEmpty
                ? 0.0
                : min(1.0, Double(matchedPICO.count) / Double(min(10, max(1, picoTokenSet.count))))

            // Cosine similarity to included study centroid
            var tfMap: [String: Double] = [:]
            for t in docTokens {
                tfMap[t, default: 0.0] += 1.0
            }
            let docNorm = tfMap.values.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
            var dotProd = 0.0
            if centroidNorm > 0.0 && docNorm > 0.0 {
                for (tok, weight) in tfMap {
                    if let cWeight = includedCentroid[tok] {
                        dotProd += weight * cWeight
                    }
                }
            }
            let cosineSim = (centroidNorm > 0.0 && docNorm > 0.0) ? (dotProd / (docNorm * centroidNorm)) : 0.0

            // Vote disagreement history prior to adjudication
            let hadIncludeSplit: Bool
            let hadMaybeSplit: Bool
            if let a = study.reviewerADecision, let b = study.reviewerBDecision {
                hadIncludeSplit = (a == .include || b == .include)
                hadMaybeSplit = !hadIncludeSplit && (a == .maybe || b == .maybe)
            } else {
                hadIncludeSplit = false
                hadMaybeSplit = false
            }

            let rulePrio = priorityByCode[exCode] ?? maxRulePriority
            let latePriorityBonus = maxRulePriority > 1
                ? Double(rulePrio - 1) / Double(maxRulePriority - 1)
                : 0.5
            let fullTextBonus = (study.stage == .fullText) ? 0.12 : 0.0

            let stratum: NearMissRiskStratum
            let conflictBonus: Double
            if hadIncludeSplit {
                stratum = .splitVoteAdjudicatedExclude
                conflictBonus = 0.42
            } else if hadMaybeSplit {
                stratum = .maybeBorderlineExclude
                conflictBonus = 0.28
            } else if rulePrio >= 2 && (picoAffinity >= 0.35 || cosineSim >= 0.28) {
                stratum = .latePriorityExclusionWithHighPICOMatch
                conflictBonus = 0.14 * latePriorityBonus
            } else {
                stratum = .consensusExcludeLexicalNeighbor
                conflictBonus = 0.04 * latePriorityBonus
            }

            let compositeRisk = min(
                1.0,
                conflictBonus + 0.30 * picoAffinity + 0.25 * cosineSim + fullTextBonus
            )

            let topTermsPreview = matchedPICO.prefix(5).joined(separator: ", ")
            let prompt = "Verify exclusion '\(exCode)' (\(stratum.rawValue)); PICO overlap = \(String(format: "%.0f%%", picoAffinity * 100.0))"
                + (topTermsPreview.isEmpty ? "." : " [terms: \(topTermsPreview)].")

            scoredPool.append(
                NearMissRecheckCandidate(
                    studyID: study.id,
                    citeKey: study.citeKey,
                    title: study.title,
                    stage: study.stage,
                    assignedExclusionCode: exCode,
                    riskStratum: stratum,
                    picoLexicalAffinity: picoAffinity,
                    includedCentroidCosineSimilarity: cosineSim,
                    falseNegativeRiskScore: compositeRisk,
                    matchedPICOTerms: Array(matchedPICO.prefix(8)),
                    recheckPrompt: prompt
                )
            )
        }

        // Rank descending by risk score (deterministic tie-break by studyID)
        scoredPool.sort { lhs, rhs in
            if abs(lhs.falseNegativeRiskScore - rhs.falseNegativeRiskScore) > 1e-9 {
                return lhs.falseNegativeRiskScore > rhs.falseNegativeRiskScore
            }
            return lhs.studyID < rhs.studyID
        }

        let desiredRaw = Int((Double(totalExcluded) * config.targetSampleFraction).rounded(.up))
        let targetCount = min(totalExcluded, min(config.maximumSampleSize, max(config.minimumSampleSize, desiredRaw)))
        let highRiskQuota = min(targetCount, Int((Double(targetCount) * config.highRiskQuotaProportion).rounded()))

        let highRiskSlice = Array(scoredPool.prefix(highRiskQuota))
        var remainder = Array(scoredPool.dropFirst(highRiskQuota))
        var prng = DeterministicSplitMix64(seed: config.randomSeed)
        prng.shuffle(&remainder)

        let controlNeeded = max(0, targetCount - highRiskSlice.count)
        let randomControls = remainder.prefix(controlNeeded).map { item in
            NearMissRecheckCandidate(
                studyID: item.studyID,
                citeKey: item.citeKey,
                title: item.title,
                stage: item.stage,
                assignedExclusionCode: item.assignedExclusionCode,
                riskStratum: .randomControlAudit,
                picoLexicalAffinity: item.picoLexicalAffinity,
                includedCentroidCosineSimilarity: item.includedCentroidCosineSimilarity,
                falseNegativeRiskScore: item.falseNegativeRiskScore,
                matchedPICOTerms: item.matchedPICOTerms,
                recheckPrompt: "Random baseline control recheck for exclusion '\(item.assignedExclusionCode)'."
            )
        }

        let combined = highRiskSlice + randomControls
        // Finite-population-adjusted Wilson 95% upper bound if 0 false negatives are found in `selectedSampleCount`
        let rawWilsonZero = PsychometricNormalMath.wilsonScoreInterval(
            successes: 0,
            trials: combined.count,
            confidenceLevel: confidenceLevel
        ).upper
        let fpcFactor = totalExcluded > combined.count
            ? (Double(totalExcluded - combined.count) / Double(max(1, totalExcluded - 1))).squareRoot()
            : 0.0
        let zeroDefectBound = rawWilsonZero * (combined.count == totalExcluded ? 0.0 : max(0.20, fpcFactor))

        return NearMissRecheckPlan(
            totalExcludedPoolCount: totalExcluded,
            selectedSampleCount: combined.count,
            randomSeedUsed: config.randomSeed,
            highRiskSelectedCount: highRiskSlice.count,
            randomControlSelectedCount: randomControls.count,
            zeroDefectUpper95FalseOmissionBound: zeroDefectBound,
            candidates: combined
        )
    }

    // MARK: 6. Markdown & LaTeX Psychometric QC Audit Report Formatter

    /// Renders a publication-ready Markdown quality-control audit dossier combining reliability, confusion matrix, seed recall, and near-miss plan.
    public func exportMarkdownQCAuditReport(
        reviewTitle: String,
        dualReport: DualRaterAgreementReport,
        confusionMatrix: ExclusionCodeConfusionMatrix,
        seedReport: SeedRecallValidationReport,
        nearMissPlan: NearMissRecheckPlan
    ) -> String {
        var lines: [String] = []
        lines.append("# PRISMA 2020 Psychometric & Quality-Control Audit Report")
        lines.append("")
        lines.append("**Review Protocol:** \(reviewTitle)")
        lines.append("")
        lines.append("## 1. Dual-Blind Inter-Rater Reliability (\(dualReport.evaluatedStudyCount) Paired Records)")
        lines.append("")
        lines.append("| Statistic | Estimate | SE | 95% CI | z | p-value | Benchmark |")
        lines.append("|---|---:|---:|---|---:|---:|---|")
        for stat in [dualReport.cohensKappa, dualReport.byrtsPABAK, dualReport.gwetsAC1, dualReport.weightedMulticlassKappa] {
            lines.append(
                String(
                    format: "| %@ | %.3f | %.3f | [%.3f, %.3f] | %.2f | %.4f | %@ |",
                    stat.metricName,
                    stat.pointEstimate,
                    stat.standardError,
                    stat.lowerCI,
                    stat.upperCI,
                    stat.zStatistic,
                    stat.twoSidedPValue,
                    stat.benchmarkBand.rawValue
                )
            )
        }
        lines.append("")
        lines.append("- **Observed Agreement ($p_o$):** \(String(format: "%.1f%%", dualReport.observedProportionAgreement * 100.0))")
        lines.append("- **Prevalence Index ($PI$) / Bias Index ($BI$):** \(String(format: "%.3f", dualReport.prevalenceIndex)) / \(String(format: "%.3f", dualReport.biasIndex))")
        lines.append("- **Diagnostic Summary:** \(dualReport.diagnosticNarrative)")
        lines.append("")
        lines.append("## 2. Per-Exclusion-Code Agreement & Priority Drift")
        lines.append("")
        lines.append("- **Exact Multiclass Accuracy:** \(String(format: "%.1f%%", confusionMatrix.overallExactCategoryAccuracy * 100.0))")
        lines.append("- **Dual-Excluded Reason Code Disagreements:** \(confusionMatrix.dualExcludedCodeMismatchCount)")
        lines.append("- **Stuart-Maxwell Marginal Symmetry:** $\\chi^2(\(confusionMatrix.stuartMaxwellDegreesOfFreedom)) = \(String(format: "%.2f", confusionMatrix.stuartMaxwellChiSquare))$, $p = \(String(format: "%.4f", confusionMatrix.stuartMaxwellPValue))$")
        lines.append("")
        lines.append("## 3. Gold-Standard Sentinel Seed Recall (\(seedReport.retainedInSynthesisCount)/\(seedReport.totalSeedCount))")
        lines.append("")
        lines.append("- **Search Strategy Recall:** \(String(format: "%.1f%%", seedReport.searchStrategyRecall * 100.0)) (95% CI [\(String(format: "%.1f%%", seedReport.searchRecall95CILower * 100.0)), \(String(format: "%.1f%%", seedReport.searchRecall95CIUpper * 100.0))])")
        lines.append("- **End-to-End Retention Recall:** \(String(format: "%.1f%%", seedReport.endToEndSeedRecall * 100.0)) — Gate Status: **\(seedReport.passesStrictPRISMASeedGate ? "PASS" : "FAIL")**")
        lines.append("")
        lines.append("## 4. Stratified Near-Miss Recheck Sample (\(nearMissPlan.selectedSampleCount)/\(nearMissPlan.totalExcludedPoolCount))")
        lines.append("")
        lines.append("- **High-Risk Borderline Quota:** \(nearMissPlan.highRiskSelectedCount) · **Random Control Quota:** \(nearMissPlan.randomControlSelectedCount)")
        lines.append("- **Zero-Defect 95% Upper False-Omission Bound:** \(String(format: "%.2f%%", nearMissPlan.zeroDefectUpper95FalseOmissionBound * 100.0))")
        return lines.joined(separator: "\n")
    }

    // MARK: - Internal Psychometric Helpers

    private func computeWeightedKappaFromMatrix(
        countsMatrix: [[Int]],
        scheme: KappaWeightingScheme,
        metricName: String
    ) -> PsychometricStatisticEstimate {
        let k = countsMatrix.count
        var total = 0
        var rowSums = Array(repeating: 0, count: k)
        var colSums = Array(repeating: 0, count: k)

        for i in 0..<k {
            for j in 0..<k {
                let c = countsMatrix[i][j]
                total += c
                rowSums[i] += c
                colSums[j] += c
            }
        }

        guard total > 0, k >= 2 else {
            return PsychometricStatisticEstimate(
                metricName: metricName,
                pointEstimate: 1.0,
                standardError: 0.0,
                nullStandardError: 0.0,
                confidenceLevel: confidenceLevel
            )
        }

        let n = Double(total)
        var rowP = Array(repeating: 0.0, count: k)
        var colP = Array(repeating: 0.0, count: k)
        for i in 0..<k {
            rowP[i] = Double(rowSums[i]) / n
            colP[i] = Double(colSums[i]) / n
        }

        var weights = Array(repeating: Array(repeating: 0.0, count: k), count: k)
        var po = 0.0
        var pe = 0.0
        for i in 0..<k {
            for j in 0..<k {
                let w = scheme.agreementWeight(categoryIndexA: i, categoryIndexB: j, categoryCount: k)
                weights[i][j] = w
                let pij = Double(countsMatrix[i][j]) / n
                po += w * pij
                pe += w * rowP[i] * colP[j]
            }
        }

        guard abs(1.0 - pe) >= 1e-12 else {
            return PsychometricStatisticEstimate(
                metricName: metricName,
                pointEstimate: 1.0,
                standardError: 0.0,
                nullStandardError: 0.0,
                confidenceLevel: confidenceLevel
            )
        }

        let kappa = (po - pe) / (1.0 - pe)
        let oneMinusPe = 1.0 - pe

        // Weighted marginal averages bar_w_{i.} = sum_j w_{ij} p_{.j} and bar_w_{.j} = sum_i w_{ij} p_{i.}
        var wBarRow = Array(repeating: 0.0, count: k)
        var wBarCol = Array(repeating: 0.0, count: k)
        for i in 0..<k {
            for j in 0..<k {
                wBarRow[i] += weights[i][j] * colP[j]
                wBarCol[j] += weights[i][j] * rowP[i]
            }
        }

        // Fleiss, Cohen & Everitt (1969) asymptotic variance for general weighted KxK kappa
        var sumVar = 0.0
        var sumNullVar = 0.0
        for i in 0..<k {
            for j in 0..<k {
                let pij = Double(countsMatrix[i][j]) / n
                let wij = weights[i][j]
                let bracket = wij - (wBarRow[i] + wBarCol[j]) * (1.0 - kappa)
                sumVar += pij * bracket * bracket

                let nullBracket = wij - (wBarRow[i] + wBarCol[j])
                sumNullVar += (rowP[i] * colP[j]) * nullBracket * nullBracket
            }
        }
        let subtractTerm = Foundation.pow(kappa - pe * (1.0 - kappa), 2.0)
        let variance = max(0.0, (sumVar - subtractTerm) / (n * oneMinusPe * oneMinusPe))
        let nullVariance = max(0.0, (sumNullVar - pe * pe) / (n * oneMinusPe * oneMinusPe))

        return PsychometricStatisticEstimate(
            metricName: metricName,
            pointEstimate: kappa,
            standardError: variance.squareRoot(),
            nullStandardError: nullVariance.squareRoot(),
            confidenceLevel: confidenceLevel
        )
    }

    private func computeNominalKrippendorffAlpha(nij: [[Int]], mi: [Int], categoryCount k: Int) -> Double {
        let nUnits = nij.count
        guard nUnits > 0, k >= 2 else { return 1.0 }

        var totalPairableValues = 0
        var coincidenceColSums = Array(repeating: 0.0, count: k)
        var observedDisagreementNumer = 0.0

        for u in 0..<nUnits {
            let m = mi[u]
            guard m >= 2 else { continue }
            totalPairableValues += m
            for c in 0..<k {
                let nuc = Double(nij[u][c])
                coincidenceColSums[c] += nuc
                for cOther in (c + 1)..<k {
                    let nuOther = Double(nij[u][cOther])
                    observedDisagreementNumer += (2.0 * nuc * nuOther) / Double(m - 1)
                }
            }
        }

        guard totalPairableValues > 1 else { return 1.0 }
        let nTotal = Double(totalPairableValues)
        let dObserved = observedDisagreementNumer / nTotal

        var expectedDisagreementNumer = 0.0
        for c in 0..<k {
            for cOther in (c + 1)..<k {
                expectedDisagreementNumer += 2.0 * coincidenceColSums[c] * coincidenceColSums[cOther]
            }
        }
        let dExpected = expectedDisagreementNumer / (nTotal * (nTotal - 1.0))
        guard dExpected > 1e-12 else { return dObserved <= 1e-12 ? 1.0 : 0.0 }
        return max(-1.0, min(1.0, 1.0 - (dObserved / dExpected)))
    }

    private func computeMarginalHomogeneityTest(
        matrix: [[Int]],
        rowTotals: [Int],
        colTotals: [Int]
    ) -> (chiSquare: Double, df: Int, pValue: Double) {
        let k = matrix.count
        let activeIndices = (0..<k).filter { rowTotals[$0] + colTotals[$0] > 0 }
        guard activeIndices.count >= 2 else { return (0.0, 1, 1.0) }

        if activeIndices.count == 2 {
            let i = activeIndices[0]
            let j = activeIndices[1]
            let b = matrix[i][j]
            let c = matrix[j][i]
            guard b + c > 0 else { return (0.0, 1, 1.0) }
            let diff = Double(b - c)
            let chi2 = (diff * diff) / Double(b + c)
            return (chi2, 1, PsychometricNormalMath.chiSquareUpperTailPValue(chiSquare: chi2, degreesOfFreedom: 1))
        }

        // Exact Stuart-Maxwell Q = d^T V^{-1} d on (m - 1) independent marginal differences via Gaussian elimination
        let m = activeIndices.count - 1
        var dVec = Array(repeating: 0.0, count: m)
        var cov = Array(repeating: Array(repeating: 0.0, count: m), count: m)

        for a in 0..<m {
            let i = activeIndices[a]
            dVec[a] = Double(rowTotals[i] - colTotals[i])
            let vDiag = Double(rowTotals[i] + colTotals[i] - 2 * matrix[i][i])
            cov[a][a] = vDiag
            for b in (a + 1)..<m {
                let j = activeIndices[b]
                let vOff = -Double(matrix[i][j] + matrix[j][i])
                cov[a][b] = vOff
                cov[b][a] = vOff
            }
        }

        if let solved = Self.solveSymmetricLinearSystem(matrix: cov, rhs: dVec) {
            var q = 0.0
            for idx in 0..<m {
                q += dVec[idx] * solved[idx]
            }
            let clampedQ = max(0.0, q)
            let pVal = PsychometricNormalMath.chiSquareUpperTailPValue(chiSquare: clampedQ, degreesOfFreedom: m)
            return (clampedQ, m, pVal)
        } else {
            // Diagonal regularized fallback when off-diagonal counts are collinear
            var qFallback = 0.0
            var activeDF = 0
            for a in 0..<m where cov[a][a] > 0.0 {
                qFallback += (dVec[a] * dVec[a]) / cov[a][a]
                activeDF += 1
            }
            let df = max(1, activeDF)
            return (qFallback, df, PsychometricNormalMath.chiSquareUpperTailPValue(chiSquare: qFallback, degreesOfFreedom: df))
        }
    }

    private func matchSeedInCorpus(
        seed: GoldStandardSeedStudy,
        corpus: [ScreeningStudyRecord]
    ) -> (ScreeningStudyRecord, String)? {
        if let seedKey = seed.expectedCiteKey?.trimmingCharacters(in: .whitespacesAndNewlines), !seedKey.isEmpty {
            if let exactKey = corpus.first(where: { $0.citeKey.caseInsensitiveCompare(seedKey) == .orderedSame }) {
                return (exactKey, "CiteKey Exact Match")
            }
        }

        if let seedDOI = Self.normalizeDOI(seed.expectedDOI), !seedDOI.isEmpty {
            if let exactDOI = corpus.first(where: { Self.normalizeDOI($0.doi) == seedDOI }) {
                return (exactDOI, "Canonical DOI Match")
            }
        }

        let normSeedTitle = Self.normalizeAlphaNumeric(seed.canonicalTitle)
        if !normSeedTitle.isEmpty {
            if let exactTitle = corpus.first(where: {
                Self.normalizeAlphaNumeric($0.title) == normSeedTitle && abs($0.year - seed.publicationYear) <= 1
            }) {
                return (exactTitle, "Normalized Title + Year Match")
            }

            // Token Jaccard fallback (>= 0.80) for minor punctuation/subtitle variations
            let seedTokens = Set(Self.extractMeaningfulTokens(seed.canonicalTitle))
            if seedTokens.count >= 3 {
                var bestMatch: (ScreeningStudyRecord, Double)?
                for candidate in corpus where abs(candidate.year - seed.publicationYear) <= 1 {
                    let candTokens = Set(Self.extractMeaningfulTokens(candidate.title))
                    let inter = seedTokens.intersection(candTokens).count
                    let union = seedTokens.union(candTokens).count
                    guard union > 0 else { continue }
                    let jaccard = Double(inter) / Double(union)
                    if jaccard >= 0.80, jaccard > (bestMatch?.1 ?? 0.0) {
                        bestMatch = (candidate, jaccard)
                    }
                }
                if let bestMatch {
                    return (bestMatch.0, String(format: "Fuzzy Title Jaccard (%.0f%%)", bestMatch.1 * 100.0))
                }
            }
        }

        return nil
    }

    private static func solveSymmetricLinearSystem(matrix aIn: [[Double]], rhs bIn: [Double]) -> [Double]? {
        let n = bIn.count
        guard n > 0, aIn.count == n else { return nil }
        var a = aIn
        var b = bIn

        for col in 0..<n {
            var pivotRow = col
            var pivotAbs = abs(a[col][col])
            for row in (col + 1)..<n {
                let cand = abs(a[row][col])
                if cand > pivotAbs {
                    pivotAbs = cand
                    pivotRow = row
                }
            }
            if pivotAbs < 1e-9 {
                return nil
            }
            if pivotRow != col {
                a.swapAt(col, pivotRow)
                b.swapAt(col, pivotRow)
            }
            let pivot = a[col][col]
            for row in (col + 1)..<n {
                let factor = a[row][col] / pivot
                if abs(factor) > 0.0 {
                    for k in col..<n {
                        a[row][k] -= factor * a[col][k]
                    }
                    b[row] -= factor * b[col]
                }
            }
        }

        var x = Array(repeating: 0.0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n {
                sum -= a[row][k] * x[k]
            }
            x[row] = sum / a[row][row]
        }
        return x
    }

    private static func isBinaryPositive(_ decision: ScreeningDecision, treatMaybeAsPositive: Bool) -> Bool {
        switch decision {
        case .include: return true
        case .maybe: return treatMaybeAsPositive
        case .exclude: return false
        }
    }

    private static func ordinalTier(_ decision: ScreeningDecision) -> Int {
        switch decision {
        case .exclude: return 0
        case .maybe: return 1
        case .include: return 2
        }
    }

    private static func canonicalCategoryKey(for decision: ScreeningDecision, collapseExclusions: Bool) -> String {
        switch decision {
        case .include:
            return "INCLUDE"
        case .maybe:
            return "MAYBE"
        case .exclude(let code):
            return collapseExclusions ? "EXCLUDE" : code
        }
    }

    private static func sortCanonicalCategories(_ raw: [String]) -> [String] {
        raw.sorted { lhs, rhs in
            let rankL = lhs == "INCLUDE" ? 0 : (lhs == "MAYBE" ? 1 : 2)
            let rankR = rhs == "INCLUDE" ? 0 : (rhs == "MAYBE" ? 1 : 2)
            if rankL != rankR { return rankL < rankR }
            return lhs < rhs
        }
    }

    private static func effectiveDecision(for study: ScreeningStudyRecord) -> ScreeningDecision? {
        if let adj = study.adjudicatedDecision {
            return adj
        }
        if let a = study.reviewerADecision, let b = study.reviewerBDecision, a == b {
            return a
        }
        return nil
    }

    private static func normalizeDOI(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .replacingOccurrences(of: "https://doi.org/", with: "")
            .replacingOccurrences(of: "http://doi.org/", with: "")
            .replacingOccurrences(of: "doi:", with: "")
    }

    private static func normalizeAlphaNumeric(_ raw: String) -> String {
        raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "into", "over", "under",
        "between", "among", "using", "based", "study", "studies", "paper", "evaluation",
        "review", "analysis", "results", "system", "systems", "method", "methods", "approach",
        "their", "were", "have", "been", "which", "where", "while", "when", "than", "also"
    ]

    private static func extractMeaningfulTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopWords.contains($0) }
    }
}
