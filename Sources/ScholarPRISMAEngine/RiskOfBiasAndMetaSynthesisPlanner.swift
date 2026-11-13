import Foundation
import ScholarModels

// MARK: - Cochrane RoB 2.0 Domain Signaling & Traffic-Light Appraisal Models

/// Standardized signaling-question response vocabulary from the Cochrane RoB 2.0 guidance (Sterne et al., BMJ 2019).
public enum SignalingResponse: String, Sendable, Codable, Hashable, CaseIterable {
    case yes = "Y"
    case probablyYes = "PY"
    case probablyNo = "PN"
    case no = "N"
    case noInformation = "NI"

    public var isAffirmative: Bool {
        self == .yes || self == .probablyYes
    }

    public var isNegative: Bool {
        self == .no || self == .probablyNo
    }
}

/// The five canonical bias domains of the revised Cochrane Risk-of-Bias tool for randomized trials (RoB 2.0).
public enum RoB2Domain: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case randomizationProcess = "D1: Randomization Process"
    case deviationsFromIntendedInterventions = "D2: Deviations from Intended Interventions"
    case missingOutcomeData = "D3: Missing Outcome Data"
    case outcomeMeasurement = "D4: Measurement of the Outcome"
    case selectiveReporting = "D5: Selection of the Reported Result"

    public var id: String { rawValue }

    public var shortCode: String {
        switch self {
        case .randomizationProcess: return "D1"
        case .deviationsFromIntendedInterventions: return "D2"
        case .missingOutcomeData: return "D3"
        case .outcomeMeasurement: return "D4"
        case .selectiveReporting: return "D5"
        }
    }

    public var compactHeaderTitle: String {
        switch self {
        case .randomizationProcess: return "Randomization"
        case .deviationsFromIntendedInterventions: return "Deviations"
        case .missingOutcomeData: return "Missing Data"
        case .outcomeMeasurement: return "Measurement"
        case .selectiveReporting: return "Reporting"
        }
    }
}

/// Cochrane RoB 2.0 domain and overall risk-of-bias judgment tiers.
public enum RoB2Judgment: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case lowRisk = "Low"
    case someConcerns = "Some Concerns"
    case highRisk = "High"

    private var severityRank: Int {
        switch self {
        case .lowRisk: return 0
        case .someConcerns: return 1
        case .highRisk: return 2
        }
    }

    public static func < (lhs: RoB2Judgment, rhs: RoB2Judgment) -> Bool {
        lhs.severityRank < rhs.severityRank
    }

    public var trafficLightHexFill: String {
        switch self {
        case .lowRisk: return "#2E8555"
        case .someConcerns: return "#D99B26"
        case .highRisk: return "#C43B3B"
        }
    }

    public var trafficLightSymbol: String {
        switch self {
        case .lowRisk: return "+"
        case .someConcerns: return "!"
        case .highRisk: return "×"
        }
    }

    public var latexCellTag: String {
        switch self {
        case .lowRisk: return "Low ($+$)"
        case .someConcerns: return "Some Concerns ($!$)"
        case .highRisk: return "High ($\\times$)"
        }
    }
}

/// Structured signaling inputs for automated Cochrane RoB 2.0 domain algorithm evaluation.
public struct RoB2SignalingChecklist: Sendable, Codable, Hashable {
    // Domain 1: Randomization
    public var allocationSequenceRandom: SignalingResponse
    public var allocationConcealedUntilEnrolment: SignalingResponse
    public var baselineImbalanceSuggestsProblem: SignalingResponse

    // Domain 2: Deviations from intended interventions
    public var participantsOrCarersAwareOfIntervention: SignalingResponse
    public var nonProtocolDeviationsAroseFromContext: SignalingResponse
    public var appropriateIntentionToTreatAnalysisUsed: SignalingResponse

    // Domain 3: Missing outcome data
    public var outcomeDataAvailableForNearlyAllParticipants: SignalingResponse
    public var evidenceResultNotBiasedByMissingData: SignalingResponse
    public var missingnessCouldDependOnTrueOutcomeValue: SignalingResponse

    // Domain 4: Measurement of the outcome
    public var outcomeMeasurementMethodInappropriate: SignalingResponse
    public var measurementDifferedBetweenGroups: SignalingResponse
    public var outcomeAssessorsAwareOfIntervention: SignalingResponse
    public var assessmentLikelyInfluencedByKnowledge: SignalingResponse

    // Domain 5: Selection of the reported result
    public var analyzedAccordingToPrespecifiedPlan: SignalingResponse
    public var resultLikelySelectedFromMultipleOutcomesOrAnalyses: SignalingResponse

    public init(
        allocationSequenceRandom: SignalingResponse = .yes,
        allocationConcealedUntilEnrolment: SignalingResponse = .yes,
        baselineImbalanceSuggestsProblem: SignalingResponse = .no,
        participantsOrCarersAwareOfIntervention: SignalingResponse = .no,
        nonProtocolDeviationsAroseFromContext: SignalingResponse = .no,
        appropriateIntentionToTreatAnalysisUsed: SignalingResponse = .yes,
        outcomeDataAvailableForNearlyAllParticipants: SignalingResponse = .yes,
        evidenceResultNotBiasedByMissingData: SignalingResponse = .yes,
        missingnessCouldDependOnTrueOutcomeValue: SignalingResponse = .no,
        outcomeMeasurementMethodInappropriate: SignalingResponse = .no,
        measurementDifferedBetweenGroups: SignalingResponse = .no,
        outcomeAssessorsAwareOfIntervention: SignalingResponse = .no,
        assessmentLikelyInfluencedByKnowledge: SignalingResponse = .no,
        analyzedAccordingToPrespecifiedPlan: SignalingResponse = .yes,
        resultLikelySelectedFromMultipleOutcomesOrAnalyses: SignalingResponse = .no
    ) {
        self.allocationSequenceRandom = allocationSequenceRandom
        self.allocationConcealedUntilEnrolment = allocationConcealedUntilEnrolment
        self.baselineImbalanceSuggestsProblem = baselineImbalanceSuggestsProblem
        self.participantsOrCarersAwareOfIntervention = participantsOrCarersAwareOfIntervention
        self.nonProtocolDeviationsAroseFromContext = nonProtocolDeviationsAroseFromContext
        self.appropriateIntentionToTreatAnalysisUsed = appropriateIntentionToTreatAnalysisUsed
        self.outcomeDataAvailableForNearlyAllParticipants = outcomeDataAvailableForNearlyAllParticipants
        self.evidenceResultNotBiasedByMissingData = evidenceResultNotBiasedByMissingData
        self.missingnessCouldDependOnTrueOutcomeValue = missingnessCouldDependOnTrueOutcomeValue
        self.outcomeMeasurementMethodInappropriate = outcomeMeasurementMethodInappropriate
        self.measurementDifferedBetweenGroups = measurementDifferedBetweenGroups
        self.outcomeAssessorsAwareOfIntervention = outcomeAssessorsAwareOfIntervention
        self.assessmentLikelyInfluencedByKnowledge = assessmentLikelyInfluencedByKnowledge
        self.analyzedAccordingToPrespecifiedPlan = analyzedAccordingToPrespecifiedPlan
        self.resultLikelySelectedFromMultipleOutcomesOrAnalyses = resultLikelySelectedFromMultipleOutcomesOrAnalyses
    }
}

/// Appraised RoB 2.0 record for a single randomized trial or controlled experiment.
public struct RoB2StudyAssessment: Sendable, Codable, Hashable, Identifiable {
    public var id: String { citeKey }
    public let citeKey: String
    public let studyLabel: String
    public let outcomeAssessed: String
    public let domainJudgments: [RoB2Domain: RoB2Judgment]
    public let domainRationales: [RoB2Domain: String]
    public let overallJudgment: RoB2Judgment
    public let overallRationale: String
    public let relativeWeightPercent: Double

    public init(
        citeKey: String,
        studyLabel: String,
        outcomeAssessed: String,
        domainJudgments: [RoB2Domain: RoB2Judgment],
        domainRationales: [RoB2Domain: String] = [:],
        overallJudgment: RoB2Judgment? = nil,
        overallRationale: String = "",
        relativeWeightPercent: Double = 1.0
    ) {
        self.citeKey = citeKey
        self.studyLabel = studyLabel
        self.outcomeAssessed = outcomeAssessed
        var filled: [RoB2Domain: RoB2Judgment] = [:]
        for domain in RoB2Domain.allCases {
            filled[domain] = domainJudgments[domain] ?? .someConcerns
        }
        self.domainJudgments = filled
        self.domainRationales = domainRationales
        let computedOverall = overallJudgment ?? Self.deriveOverallJudgment(from: filled)
        self.overallJudgment = computedOverall
        if overallRationale.isEmpty {
            self.overallRationale = Self.defaultOverallRationale(from: filled, overall: computedOverall)
        } else {
            self.overallRationale = overallRationale
        }
        self.relativeWeightPercent = max(0.01, relativeWeightPercent)
    }

    /// Cochrane RoB 2.0 overall judgment rule:
    /// - `lowRisk` iff all 5 domains are `lowRisk`.
    /// - `highRisk` if >= 1 domain is `highRisk`, OR >= 3 domains have `someConcerns` (substantially lowering confidence).
    /// - `someConcerns` otherwise.
    public static func deriveOverallJudgment(from domainMap: [RoB2Domain: RoB2Judgment]) -> RoB2Judgment {
        var highCount = 0
        var concernCount = 0
        for domain in RoB2Domain.allCases {
            switch domainMap[domain] ?? .someConcerns {
            case .highRisk: highCount += 1
            case .someConcerns: concernCount += 1
            case .lowRisk: break
            }
        }
        if highCount >= 1 || concernCount >= 3 {
            return .highRisk
        }
        if concernCount >= 1 {
            return .someConcerns
        }
        return .lowRisk
    }

    private static func defaultOverallRationale(from domainMap: [RoB2Domain: RoB2Judgment], overall: RoB2Judgment) -> String {
        let highDomains = RoB2Domain.allCases.filter { domainMap[$0] == .highRisk }.map(\.shortCode)
        let concernDomains = RoB2Domain.allCases.filter { domainMap[$0] == .someConcerns }.map(\.shortCode)
        switch overall {
        case .lowRisk:
            return "Low risk of bias across all five Cochrane RoB 2.0 domains."
        case .someConcerns:
            return "Some concerns arising in \(concernDomains.joined(separator: ", ")), without high-risk flaws."
        case .highRisk:
            if !highDomains.isEmpty {
                return "High risk of bias driven by \(highDomains.joined(separator: ", "))."
            }
            return "High risk of bias due to cumulative concerns across \(concernDomains.count) domains (\(concernDomains.joined(separator: ", ")))."
        }
    }
}

/// Aggregated traffic-light summary percentages across studies (both unweighted study count and inverse-variance weighted).
public struct RoB2DomainDistribution: Sendable, Codable, Hashable, Identifiable {
    public var id: String { label }
    public let label: String
    public let lowRiskShare: Double
    public let someConcernsShare: Double
    public let highRiskShare: Double

    public init(label: String, lowRiskShare: Double, someConcernsShare: Double, highRiskShare: Double) {
        self.label = label
        self.lowRiskShare = lowRiskShare
        self.someConcernsShare = someConcernsShare
        self.highRiskShare = highRiskShare
    }
}

public struct RoB2TrafficLightMatrix: Sendable, Codable, Hashable {
    public let assessments: [RoB2StudyAssessment]
    public let unweightedDistributions: [RoB2DomainDistribution]
    public let weightedDistributions: [RoB2DomainDistribution]
    public let highRiskStudyProportion: Double
    public let someConcernsStudyProportion: Double
    public let lowRiskStudyProportion: Double
    public let recommendedGRADERiskOfBiasDowngrade: GRADEDowngradeSeverity

    public init(
        assessments: [RoB2StudyAssessment],
        unweightedDistributions: [RoB2DomainDistribution],
        weightedDistributions: [RoB2DomainDistribution],
        highRiskStudyProportion: Double,
        someConcernsStudyProportion: Double,
        lowRiskStudyProportion: Double,
        recommendedGRADERiskOfBiasDowngrade: GRADEDowngradeSeverity
    ) {
        self.assessments = assessments
        self.unweightedDistributions = unweightedDistributions
        self.weightedDistributions = weightedDistributions
        self.highRiskStudyProportion = highRiskStudyProportion
        self.someConcernsStudyProportion = someConcernsStudyProportion
        self.lowRiskStudyProportion = lowRiskStudyProportion
        self.recommendedGRADERiskOfBiasDowngrade = recommendedGRADERiskOfBiasDowngrade
    }
}

// MARK: - ROBINS-I & Newcastle-Ottawa Scale (Observational / Non-Randomized Appraisal)

/// Seven bias domains of ROBINS-I for non-randomized studies of interventions (Sterne et al., BMJ 2016).
public enum ROBINSIDomain: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case confounding = "I1: Bias due to Confounding"
    case participantSelection = "I2: Selection of Participants"
    case interventionClassification = "I3: Classification of Interventions"
    case intendedInterventionDeviations = "I4: Deviations from Intended Interventions"
    case missingData = "I5: Bias due to Missing Data"
    case outcomeMeasurement = "I6: Measurement of Outcomes"
    case reportedResultSelection = "I7: Selection of Reported Result"

    public var id: String { rawValue }
}

public enum ROBINSIJudgment: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case low = "Low"
    case moderate = "Moderate"
    case serious = "Serious"
    case critical = "Critical"
    case noInformation = "No Information"

    private var severityOrder: Int {
        switch self {
        case .low: return 0
        case .moderate: return 1
        case .noInformation: return 2
        case .serious: return 3
        case .critical: return 4
        }
    }

    public static func < (lhs: ROBINSIJudgment, rhs: ROBINSIJudgment) -> Bool {
        lhs.severityOrder < rhs.severityOrder
    }
}

public struct ROBINSIStudyAssessment: Sendable, Codable, Hashable, Identifiable {
    public var id: String { citeKey }
    public let citeKey: String
    public let studyLabel: String
    public let targetTrialAnalogy: String
    public let domainJudgments: [ROBINSIDomain: ROBINSIJudgment]
    public let overallJudgment: ROBINSIJudgment
    public let eligibleForPrimarySynthesis: Bool

    public init(
        citeKey: String,
        studyLabel: String,
        targetTrialAnalogy: String,
        domainJudgments: [ROBINSIDomain: ROBINSIJudgment]
    ) {
        self.citeKey = citeKey
        self.studyLabel = studyLabel
        self.targetTrialAnalogy = targetTrialAnalogy
        var normalized: [ROBINSIDomain: ROBINSIJudgment] = [:]
        for d in ROBINSIDomain.allCases {
            normalized[d] = domainJudgments[d] ?? .noInformation
        }
        self.domainJudgments = normalized
        // ROBINS-I overall rule: overall risk equals the most severe domain judgment;
        // studies judged at Critical risk are typically excluded from primary quantitative synthesis.
        let worst = normalized.values.max() ?? .noInformation
        self.overallJudgment = worst
        self.eligibleForPrimarySynthesis = (worst != .critical)
    }
}

public enum NOSStudyDesignVariant: String, Sendable, Codable, Hashable, CaseIterable {
    case cohort = "Prospective / Retrospective Cohort"
    case caseControl = "Case-Control"
}

public enum AHRQQualityTier: String, Sendable, Codable, Hashable, CaseIterable {
    case good = "Good Quality (AHRQ)"
    case fair = "Fair Quality (AHRQ)"
    case poor = "Poor Quality (AHRQ)"
}

/// Newcastle-Ottawa Scale (0–9 stars) appraisal with Agency for Healthcare Research and Quality (AHRQ) conversion.
public struct NewcastleOttawaAssessment: Sendable, Codable, Hashable, Identifiable {
    public var id: String { citeKey }
    public let citeKey: String
    public let studyLabel: String
    public let designVariant: NOSStudyDesignVariant
    /// Selection domain: 0...4 stars
    public let selectionStars: Int
    /// Comparability of cohorts/cases & controls on key confounders: 0...2 stars
    public let comparabilityStars: Int
    /// Outcome (cohort) or Exposure (case-control) ascertainment & follow-up: 0...3 stars
    public let outcomeOrExposureStars: Int
    public let totalStars: Int
    public let ahrqQualityTier: AHRQQualityTier
    public let methodologicalNotes: String

    public init(
        citeKey: String,
        studyLabel: String,
        designVariant: NOSStudyDesignVariant = .cohort,
        selectionStars: Int,
        comparabilityStars: Int,
        outcomeOrExposureStars: Int,
        methodologicalNotes: String = ""
    ) {
        self.citeKey = citeKey
        self.studyLabel = studyLabel
        self.designVariant = designVariant
        let s = min(4, max(0, selectionStars))
        let c = min(2, max(0, comparabilityStars))
        let o = min(3, max(0, outcomeOrExposureStars))
        self.selectionStars = s
        self.comparabilityStars = c
        self.outcomeOrExposureStars = o
        self.totalStars = s + c + o
        self.methodologicalNotes = methodologicalNotes

        // Standard AHRQ conversion thresholds:
        // Good: 3-4 Selection AND 1-2 Comparability AND 2-3 Outcome/Exposure
        // Fair: 2 Selection AND 1-2 Comparability AND 2-3 Outcome/Exposure
        // Poor: 0-1 Selection OR 0 Comparability OR 0-1 Outcome/Exposure
        if s >= 3 && c >= 1 && o >= 2 {
            self.ahrqQualityTier = .good
        } else if s == 2 && c >= 1 && o >= 2 {
            self.ahrqQualityTier = .fair
        } else {
            self.ahrqQualityTier = .poor
        }
    }

    public var starBarGlyph: String {
        String(repeating: "★", count: totalStars) + String(repeating: "☆", count: max(0, 9 - totalStars))
    }
}

// MARK: - GRADE Certainty-of-Evidence & Meta-Synthesis Models

public enum GRADEDowngradeSeverity: Int, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case none = 0
    case serious = -1
    case verySerious = -2

    public static func < (lhs: GRADEDowngradeSeverity, rhs: GRADEDowngradeSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .none: return "Not serious"
        case .serious: return "Serious (-1)"
        case .verySerious: return "Very serious (-2)"
        }
    }
}

public enum GRADEUpgradeFactor: String, Sendable, Codable, Hashable, CaseIterable {
    case largeMagnitudeOfEffect = "Large magnitude of effect (+1)"
    case veryLargeMagnitudeOfEffect = "Very large magnitude of effect (+2)"
    case doseResponseGradient = "Dose-response gradient (+1)"
    case plausibleResidualConfoundingWouldReduceEffect = "Plausible confounding opposes observed effect (+1)"

    public var pointBoost: Int {
        switch self {
        case .veryLargeMagnitudeOfEffect: return 2
        default: return 1
        }
    }
}

public enum GRADECertaintyLevel: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case veryLow = "Very Low"
    case low = "Low"
    case moderate = "Moderate"
    case high = "High"

    private var numericScore: Int {
        switch self {
        case .veryLow: return 1
        case .low: return 2
        case .moderate: return 3
        case .high: return 4
        }
    }

    public static func < (lhs: GRADECertaintyLevel, rhs: GRADECertaintyLevel) -> Bool {
        lhs.numericScore < rhs.numericScore
    }

    public static func fromScore(_ rawScore: Int) -> GRADECertaintyLevel {
        switch min(4, max(1, rawScore)) {
        case 4: return .high
        case 3: return .moderate
        case 2: return .low
        default: return .veryLow
        }
    }

    public var unicodeSymbols: String {
        switch self {
        case .high: return "⊕⊕⊕⊕"
        case .moderate: return "⊕⊕⊕◯"
        case .low: return "⊕⊕◯◯"
        case .veryLow: return "⊕◯◯◯"
        }
    }

    public var latexSymbols: String {
        switch self {
        case .high: return "$\\oplus\\oplus\\oplus\\oplus$ High"
        case .moderate: return "$\\oplus\\oplus\\oplus\\circ$ Moderate"
        case .low: return "$\\oplus\\oplus\\circ\\circ$ Low"
        case .veryLow: return "$\\oplus\\circ\\circ\\circ$ Very Low"
        }
    }
}

public enum EvidenceStudyDesignClass: String, Sendable, Codable, Hashable, CaseIterable {
    case randomizedControlledTrials = "Randomized Trials / Controlled Benchmarks"
    case nonRandomizedWithROBINSI = "Non-Randomized Studies (ROBINS-I Target-Trial)"
    case observationalCohorts = "Observational Cohorts / Case Series"

    public var startingGRADEScore: Int {
        switch self {
        case .randomizedControlledTrials, .nonRandomizedWithROBINSI:
            return 4 // High starting certainty (ROBINS-I starts at High then downgrades via confounding/selection)
        case .observationalCohorts:
            return 2 // Classical GRADE starts observational studies at Low (2)
        }
    }
}

/// Study-level effect estimate input for random-effects / fixed-effect meta-synthesis planning & heterogeneity diagnostics.
public struct StudyEffectEstimateRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String { citeKey }
    public let citeKey: String
    public let studyLabel: String
    public let publicationYear: Int
    public let sampleSizeN: Int
    /// Point estimate on analysis scale (e.g., standardized mean difference Hedges' g, mean latency reduction, or log risk ratio).
    public let effectEstimate: Double
    /// Standard error of `effectEstimate` (> 0).
    public let standardError: Double
    public let subgroupLabel: String

    public init(
        citeKey: String,
        studyLabel: String,
        publicationYear: Int,
        sampleSizeN: Int,
        effectEstimate: Double,
        standardError: Double,
        subgroupLabel: String = "Overall"
    ) {
        self.citeKey = citeKey
        self.studyLabel = studyLabel
        self.publicationYear = publicationYear
        self.sampleSizeN = max(1, sampleSizeN)
        self.effectEstimate = effectEstimate
        self.standardError = max(1e-6, standardError)
        self.subgroupLabel = subgroupLabel
    }
}

public enum SynthesisRecommendationMode: String, Sendable, Codable, Hashable {
    case fixedEffectInverseVariance = "Fixed-Effect Inverse-Variance Meta-Analysis"
    case randomEffectsDerSimonianLaird = "Random-Effects Meta-Analysis (DerSimonian-Laird + Hartung-Knapp Advisory)"
    case subgroupStratifiedMetaAnalysis = "Subgroup-Stratified Random-Effects Meta-Analysis"
    case synthesisWithoutMetaAnalysisSWiM = "Synthesis Without Meta-Analysis (SWiM Guideline — Excessive Heterogeneity / Sparse k)"
}

/// Complete DerSimonian-Laird random-effects & fixed-effect heterogeneity and small-study bias plan.
public struct MetaSynthesisHeterogeneityPlan: Sendable, Codable, Hashable {
    public let outcomeName: String
    public let effectMeasureLabel: String
    public let kStudies: Int
    public let totalSampleSize: Int
    public let fixedEffectEstimate: Double
    public let fixedEffectSE: Double
    public let fixedEffect95CILower: Double
    public let fixedEffect95CIUpper: Double
    public let randomEffectsEstimate: Double
    public let randomEffectsSE: Double
    public let randomEffects95CILower: Double
    public let randomEffects95CIUpper: Double
    public let predictionInterval95Lower: Double?
    public let predictionInterval95Upper: Double?
    public let cochransQ: Double
    public let degreesOfFreedom: Int
    public let heterogeneityPValue: Double
    public let higginsISquaredPercent: Double
    public let tauSquaredDL: Double
    public let tauBetweenStudySD: Double
    public let eggerIntercept: Double?
    public let eggerTwoSidedPValue: Double?
    public let normalizedRandomWeightsByCiteKey: [String: Double]
    public let recommendedSynthesisMode: SynthesisRecommendationMode
    public let planningRationale: String

    public init(
        outcomeName: String,
        effectMeasureLabel: String,
        kStudies: Int,
        totalSampleSize: Int,
        fixedEffectEstimate: Double,
        fixedEffectSE: Double,
        fixedEffect95CILower: Double,
        fixedEffect95CIUpper: Double,
        randomEffectsEstimate: Double,
        randomEffectsSE: Double,
        randomEffects95CILower: Double,
        randomEffects95CIUpper: Double,
        predictionInterval95Lower: Double?,
        predictionInterval95Upper: Double?,
        cochransQ: Double,
        degreesOfFreedom: Int,
        heterogeneityPValue: Double,
        higginsISquaredPercent: Double,
        tauSquaredDL: Double,
        tauBetweenStudySD: Double,
        eggerIntercept: Double?,
        eggerTwoSidedPValue: Double?,
        normalizedRandomWeightsByCiteKey: [String: Double],
        recommendedSynthesisMode: SynthesisRecommendationMode,
        planningRationale: String
    ) {
        self.outcomeName = outcomeName
        self.effectMeasureLabel = effectMeasureLabel
        self.kStudies = kStudies
        self.totalSampleSize = totalSampleSize
        self.fixedEffectEstimate = fixedEffectEstimate
        self.fixedEffectSE = fixedEffectSE
        self.fixedEffect95CILower = fixedEffect95CILower
        self.fixedEffect95CIUpper = fixedEffect95CIUpper
        self.randomEffectsEstimate = randomEffectsEstimate
        self.randomEffectsSE = randomEffectsSE
        self.randomEffects95CILower = randomEffects95CILower
        self.randomEffects95CIUpper = randomEffects95CIUpper
        self.predictionInterval95Lower = predictionInterval95Lower
        self.predictionInterval95Upper = predictionInterval95Upper
        self.cochransQ = cochransQ
        self.degreesOfFreedom = degreesOfFreedom
        self.heterogeneityPValue = heterogeneityPValue
        self.higginsISquaredPercent = higginsISquaredPercent
        self.tauSquaredDL = tauSquaredDL
        self.tauBetweenStudySD = tauBetweenStudySD
        self.eggerIntercept = eggerIntercept
        self.eggerTwoSidedPValue = eggerTwoSidedPValue
        self.normalizedRandomWeightsByCiteKey = normalizedRandomWeightsByCiteKey
        self.recommendedSynthesisMode = recommendedSynthesisMode
        self.planningRationale = planningRationale
    }
}

/// Single row of a GRADE Summary-of-Findings (SoF) table.
public struct GRADEOutcomeEvidenceRow: Sendable, Codable, Hashable, Identifiable {
    public var id: String { outcomeName }
    public let outcomeName: String
    public let numberOfStudies: Int
    public let totalParticipantsOrRuns: Int
    public let designClass: EvidenceStudyDesignClass
    public let riskOfBiasDowngrade: GRADEDowngradeSeverity
    public let inconsistencyDowngrade: GRADEDowngradeSeverity
    public let indirectnessDowngrade: GRADEDowngradeSeverity
    public let imprecisionDowngrade: GRADEDowngradeSeverity
    public let publicationBiasDowngrade: GRADEDowngradeSeverity
    public let upgradeFactors: [GRADEUpgradeFactor]
    public let pooledEffectFormatted: String
    public let certaintyLevel: GRADECertaintyLevel
    public let explanatoryFootnotes: [String]

    public init(
        outcomeName: String,
        numberOfStudies: Int,
        totalParticipantsOrRuns: Int,
        designClass: EvidenceStudyDesignClass,
        riskOfBiasDowngrade: GRADEDowngradeSeverity,
        inconsistencyDowngrade: GRADEDowngradeSeverity,
        indirectnessDowngrade: GRADEDowngradeSeverity,
        imprecisionDowngrade: GRADEDowngradeSeverity,
        publicationBiasDowngrade: GRADEDowngradeSeverity,
        upgradeFactors: [GRADEUpgradeFactor] = [],
        pooledEffectFormatted: String,
        explanatoryFootnotes: [String] = []
    ) {
        self.outcomeName = outcomeName
        self.numberOfStudies = numberOfStudies
        self.totalParticipantsOrRuns = totalParticipantsOrRuns
        self.designClass = designClass
        self.riskOfBiasDowngrade = riskOfBiasDowngrade
        self.inconsistencyDowngrade = inconsistencyDowngrade
        self.indirectnessDowngrade = indirectnessDowngrade
        self.imprecisionDowngrade = imprecisionDowngrade
        self.publicationBiasDowngrade = publicationBiasDowngrade
        self.upgradeFactors = upgradeFactors
        self.pooledEffectFormatted = pooledEffectFormatted

        let totalPenalty = riskOfBiasDowngrade.rawValue
            + inconsistencyDowngrade.rawValue
            + indirectnessDowngrade.rawValue
            + imprecisionDowngrade.rawValue
            + publicationBiasDowngrade.rawValue
        // GRADE rule: upgrading applies primarily when no downgrades are triggered on observational evidence
        let upgradeBoost = (totalPenalty == 0 && designClass == .observationalCohorts)
            ? upgradeFactors.reduce(0) { $0 + $1.pointBoost }
            : 0
        let finalScore = designClass.startingGRADEScore + totalPenalty + upgradeBoost
        self.certaintyLevel = GRADECertaintyLevel.fromScore(finalScore)
        self.explanatoryFootnotes = explanatoryFootnotes
    }
}

/// Structured study-characteristics descriptor for LaTeX `booktabs` evidence synthesis tables.
public struct StudyCharacteristicsRow: Sendable, Codable, Hashable, Identifiable {
    public var id: String { citeKey }
    public let citeKey: String
    public let authorYearDisplay: String
    public let studyDesign: String
    public let populationOrBenchmark: String
    public let sampleSizeDescription: String
    public let interventionMechanism: String
    public let comparatorBaseline: String
    public let primaryOutcomeSummary: String
    public let overallRiskOfBiasSummary: String

    public init(
        citeKey: String,
        authorYearDisplay: String,
        studyDesign: String,
        populationOrBenchmark: String,
        sampleSizeDescription: String,
        interventionMechanism: String,
        comparatorBaseline: String,
        primaryOutcomeSummary: String,
        overallRiskOfBiasSummary: String
    ) {
        self.citeKey = citeKey
        self.authorYearDisplay = authorYearDisplay
        self.studyDesign = studyDesign
        self.populationOrBenchmark = populationOrBenchmark
        self.sampleSizeDescription = sampleSizeDescription
        self.interventionMechanism = interventionMechanism
        self.comparatorBaseline = comparatorBaseline
        self.primaryOutcomeSummary = primaryOutcomeSummary
        self.overallRiskOfBiasSummary = overallRiskOfBiasSummary
    }
}

// MARK: - Risk of Bias, GRADE & Meta-Synthesis Planner Engine

/// Industrial systematic-review appraisal and meta-synthesis planning engine supporting Cochrane RoB 2.0, ROBINS-I, NOS, DerSimonian-Laird heterogeneity, GRADE SoF, SVG traffic-light plots, and LaTeX `booktabs` tables.
public struct RiskOfBiasAndMetaSynthesisPlanner: Sendable {
    public init() {}

    // MARK: 1. Deterministic Cochrane RoB 2.0 Decision-Tree Evaluator

    /// Executes the official 5-domain Cochrane RoB 2.0 signaling-question decision trees to produce a traceable `RoB2StudyAssessment`.
    public func evaluateCochraneRoB2Checklist(
        citeKey: String,
        studyLabel: String,
        outcomeAssessed: String,
        checklist: RoB2SignalingChecklist,
        relativeWeightPercent: Double = 1.0
    ) -> RoB2StudyAssessment {
        var judgments: [RoB2Domain: RoB2Judgment] = [:]
        var rationales: [RoB2Domain: String] = [:]

        // Domain 1: Bias arising from the randomization process
        if checklist.allocationConcealedUntilEnrolment.isNegative {
            judgments[.randomizationProcess] = .highRisk
            rationales[.randomizationProcess] = "Allocation sequence was not concealed until enrollment (Q1.2 = \(checklist.allocationConcealedUntilEnrolment.rawValue))."
        } else if checklist.baselineImbalanceSuggestsProblem.isAffirmative {
            judgments[.randomizationProcess] = .highRisk
            rationales[.randomizationProcess] = "Baseline group differences suggest a flaw in randomization (Q1.3 = \(checklist.baselineImbalanceSuggestsProblem.rawValue))."
        } else if checklist.allocationSequenceRandom.isAffirmative && checklist.allocationConcealedUntilEnrolment.isAffirmative {
            judgments[.randomizationProcess] = .lowRisk
            rationales[.randomizationProcess] = "Random sequence generation and concealed allocation verified without baseline imbalance."
        } else {
            judgments[.randomizationProcess] = .someConcerns
            rationales[.randomizationProcess] = "Incomplete reporting of sequence generation or allocation concealment."
        }

        // Domain 2: Bias due to deviations from intended interventions
        let blindedParticipants = checklist.participantsOrCarersAwareOfIntervention.isNegative
        let appropriateITT = checklist.appropriateIntentionToTreatAnalysisUsed.isAffirmative
        if !appropriateITT {
            judgments[.deviationsFromIntendedInterventions] = .highRisk
            rationales[.deviationsFromIntendedInterventions] = "Per-protocol / as-treated exclusion without appropriate intention-to-treat adjustment."
        } else if !blindedParticipants && checklist.nonProtocolDeviationsAroseFromContext.isAffirmative {
            judgments[.deviationsFromIntendedInterventions] = .highRisk
            rationales[.deviationsFromIntendedInterventions] = "Unblinded delivery introduced trial-context deviations affecting outcomes."
        } else if blindedParticipants || checklist.nonProtocolDeviationsAroseFromContext.isNegative {
            judgments[.deviationsFromIntendedInterventions] = .lowRisk
            rationales[.deviationsFromIntendedInterventions] = "No trial-context protocol deviations and valid intention-to-treat analysis."
        } else {
            judgments[.deviationsFromIntendedInterventions] = .someConcerns
            rationales[.deviationsFromIntendedInterventions] = "Unblinded assignment with uncertain non-protocol co-interventions."
        }

        // Domain 3: Bias due to missing outcome data
        if checklist.outcomeDataAvailableForNearlyAllParticipants.isAffirmative
            || checklist.evidenceResultNotBiasedByMissingData.isAffirmative {
            judgments[.missingOutcomeData] = .lowRisk
            rationales[.missingOutcomeData] = "Near-complete outcome capture or sensitivity evidence of robustness to attrition."
        } else if checklist.missingnessCouldDependOnTrueOutcomeValue.isAffirmative {
            judgments[.missingOutcomeData] = .highRisk
            rationales[.missingOutcomeData] = "Substantial attrition likely dependent on true outcome value."
        } else {
            judgments[.missingOutcomeData] = .someConcerns
            rationales[.missingOutcomeData] = "Moderate missing outcome data where dependence on true value is implausible or uncertain."
        }

        // Domain 4: Bias in measurement of the outcome
        if checklist.outcomeMeasurementMethodInappropriate.isAffirmative
            || checklist.measurementDifferedBetweenGroups.isAffirmative {
            judgments[.outcomeMeasurement] = .highRisk
            rationales[.outcomeMeasurement] = "Inappropriate or differential outcome ascertainment across study arms."
        } else if checklist.outcomeAssessorsAwareOfIntervention.isNegative {
            judgments[.outcomeMeasurement] = .lowRisk
            rationales[.outcomeMeasurement] = "Blinded or objective automated outcome ascertainment consistent across arms."
        } else if checklist.assessmentLikelyInfluencedByKnowledge.isAffirmative {
            judgments[.outcomeMeasurement] = .highRisk
            rationales[.outcomeMeasurement] = "Unblinded assessors evaluating judgment-sensitive outcome likely influenced by arm knowledge."
        } else {
            judgments[.outcomeMeasurement] = .someConcerns
            rationales[.outcomeMeasurement] = "Unblinded outcome assessors, though direct influence on outcome is unlikely."
        }

        // Domain 5: Bias in selection of the reported result
        if checklist.resultLikelySelectedFromMultipleOutcomesOrAnalyses.isAffirmative {
            judgments[.selectiveReporting] = .highRisk
            rationales[.selectiveReporting] = "Evidence of selective reporting across multiple outcome scales or analytic specifications."
        } else if checklist.analyzedAccordingToPrespecifiedPlan.isAffirmative {
            judgments[.selectiveReporting] = .lowRisk
            rationales[.selectiveReporting] = "Analysis aligned with pre-specified protocol or registered statistical plan."
        } else {
            judgments[.selectiveReporting] = .someConcerns
            rationales[.selectiveReporting] = "No pre-registered statistical analysis plan available to verify absence of selective reporting."
        }

        return RoB2StudyAssessment(
            citeKey: citeKey,
            studyLabel: studyLabel,
            outcomeAssessed: outcomeAssessed,
            domainJudgments: judgments,
            domainRationales: rationales,
            relativeWeightPercent: relativeWeightPercent
        )
    }

    /// Aggregates study-level `RoB2StudyAssessment` records into unweighted and inverse-variance-weighted domain distributions + GRADE RoB guidance.
    public func buildRoB2TrafficLightMatrix(assessments: [RoB2StudyAssessment]) -> RoB2TrafficLightMatrix {
        guard !assessments.isEmpty else {
            return RoB2TrafficLightMatrix(
                assessments: [],
                unweightedDistributions: [],
                weightedDistributions: [],
                highRiskStudyProportion: 0.0,
                someConcernsStudyProportion: 0.0,
                lowRiskStudyProportion: 1.0,
                recommendedGRADERiskOfBiasDowngrade: .none
            )
        }

        let n = Double(assessments.count)
        let totalWeight = max(1e-9, assessments.reduce(0.0) { $0 + max(0.01, $1.relativeWeightPercent) })

        var unweighted: [RoB2DomainDistribution] = []
        var weighted: [RoB2DomainDistribution] = []

        for domain in RoB2Domain.allCases {
            var lowC = 0.0, someC = 0.0, highC = 0.0
            var lowW = 0.0, someW = 0.0, highW = 0.0

            for study in assessments {
                let w = max(0.01, study.relativeWeightPercent)
                switch study.domainJudgments[domain] ?? .someConcerns {
                case .lowRisk:
                    lowC += 1.0
                    lowW += w
                case .someConcerns:
                    someC += 1.0
                    someW += w
                case .highRisk:
                    highC += 1.0
                    highW += w
                }
            }
            unweighted.append(
                RoB2DomainDistribution(
                    label: domain.rawValue,
                    lowRiskShare: lowC / n,
                    someConcernsShare: someC / n,
                    highRiskShare: highC / n
                )
            )
            weighted.append(
                RoB2DomainDistribution(
                    label: domain.rawValue,
                    lowRiskShare: lowW / totalWeight,
                    someConcernsShare: someW / totalWeight,
                    highRiskShare: highW / totalWeight
                )
            )
        }

        // Overall row
        var ovLowC = 0.0, ovSomeC = 0.0, ovHighC = 0.0
        var ovLowW = 0.0, ovSomeW = 0.0, ovHighW = 0.0
        for study in assessments {
            let w = max(0.01, study.relativeWeightPercent)
            switch study.overallJudgment {
            case .lowRisk:
                ovLowC += 1.0
                ovLowW += w
            case .someConcerns:
                ovSomeC += 1.0
                ovSomeW += w
            case .highRisk:
                ovHighC += 1.0
                ovHighW += w
            }
        }

        let lowProp = ovLowC / n
        let someProp = ovSomeC / n
        let highProp = ovHighC / n

        unweighted.append(
            RoB2DomainDistribution(
                label: "Overall Risk of Bias",
                lowRiskShare: lowProp,
                someConcernsShare: someProp,
                highRiskShare: highProp
            )
        )
        weighted.append(
            RoB2DomainDistribution(
                label: "Overall Risk of Bias",
                lowRiskShare: ovLowW / totalWeight,
                someConcernsShare: ovSomeW / totalWeight,
                highRiskShare: ovHighW / totalWeight
            )
        )

        let weightedHighOverall = ovHighW / totalWeight
        let weightedSomeOverall = ovSomeW / totalWeight
        let downgrade: GRADEDowngradeSeverity
        if weightedHighOverall >= 0.45 {
            downgrade = .verySerious
        } else if weightedHighOverall >= 0.15 || (weightedHighOverall + weightedSomeOverall) >= 0.50 {
            downgrade = .serious
        } else {
            downgrade = .none
        }

        return RoB2TrafficLightMatrix(
            assessments: assessments,
            unweightedDistributions: unweighted,
            weightedDistributions: weighted,
            highRiskStudyProportion: highProp,
            someConcernsStudyProportion: someProp,
            lowRiskStudyProportion: lowProp,
            recommendedGRADERiskOfBiasDowngrade: downgrade
        )
    }

    // MARK: 2. Vector SVG Exporters (Cochrane RoB 2.0 Traffic-Light Matrix & Stacked Summary Plot)

    /// Exports a publication-grade Cochrane RoB 2.0 `robvis`-style traffic-light matrix + bottom stacked bar summary plot in standalone vector SVG.
    public func exportRoB2TrafficLightAndSummarySVG(
        matrix: RoB2TrafficLightMatrix,
        title: String = "Cochrane RoB 2.0 Risk-of-Bias Traffic-Light & Domain Summary"
    ) -> String {
        let studies = matrix.assessments
        let rowHeight = 34
        let headerTop = 84
        let gridBottom = headerTop + max(1, studies.count) * rowHeight
        let summaryTop = gridBottom + 44
        let barRowHeight = 28
        let distributions = matrix.weightedDistributions
        let totalHeight = summaryTop + distributions.count * barRowHeight + 56
        let width = 880

        var svg: [String] = []
        svg.append("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(width) \(totalHeight)\" width=\"\(width)\" height=\"\(totalHeight)\" font-family=\"ui-sans-serif, -apple-system, BlinkMacSystemFont, sans-serif\">")
        svg.append("  <rect width=\"\(width)\" height=\"\(totalHeight)\" fill=\"#FBF9F5\" rx=\"8\"/>")
        svg.append("  <text x=\"32\" y=\"34\" font-size=\"15\" font-weight=\"700\" fill=\"#1B3B30\">\(Self.escapeXML(title))</text>")

        // Legend badges
        svg.append("  <circle cx=\"540\" cy=\"29\" r=\"7\" fill=\"#2E8555\"/><text x=\"552\" y=\"33\" font-size=\"11\" fill=\"#2D312E\">Low (+)</text>")
        svg.append("  <circle cx=\"622\" cy=\"29\" r=\"7\" fill=\"#D99B26\"/><text x=\"634\" y=\"33\" font-size=\"11\" fill=\"#2D312E\">Some Concerns (!)</text>")
        svg.append("  <circle cx=\"756\" cy=\"29\" r=\"7\" fill=\"#C43B3B\"/><text x=\"768\" y=\"33\" font-size=\"11\" fill=\"#2D312E\">High (×)</text>")

        // Column X positions for D1..D5 + Overall
        let colCenters = [340, 428, 516, 604, 692, 796]
        let colHeaders = RoB2Domain.allCases.map(\.compactHeaderTitle) + ["Overall"]
        for (idx, hdr) in colHeaders.enumerated() {
            let cx = colCenters[idx]
            svg.append("  <text x=\"\(cx)\" y=\"68\" text-anchor=\"middle\" font-size=\"11\" font-weight=\"600\" fill=\"#3A3F3B\">\(Self.escapeXML(hdr))</text>")
        }
        svg.append("  <line x1=\"32\" y1=\"76\" x2=\"848\" y2=\"76\" stroke=\"#C9C3B6\" stroke-width=\"1.2\"/>")

        if studies.isEmpty {
            svg.append("  <text x=\"32\" y=\"106\" font-size=\"12\" fill=\"#6B665C\">No appraised randomized trials registered.</text>")
        } else {
            for (rIdx, study) in studies.enumerated() {
                let yRow = headerTop + rIdx * rowHeight
                if rIdx % 2 == 1 {
                    svg.append("  <rect x=\"32\" y=\"\(yRow)\" width=\"816\" height=\"\(rowHeight)\" fill=\"#F3EFE6\" rx=\"3\"/>")
                }
                let cy = yRow + rowHeight / 2
                svg.append("  <text x=\"42\" y=\"\(cy + 4)\" font-size=\"12\" font-weight=\"500\" fill=\"#1F2421\">\(Self.escapeXML(study.studyLabel))</text>")

                let judgmentsInRow = RoB2Domain.allCases.map { study.domainJudgments[$0] ?? .someConcerns } + [study.overallJudgment]
                for (cIdx, jdg) in judgmentsInRow.enumerated() {
                    let cx = colCenters[cIdx]
                    let r = cIdx == 5 ? 12 : 11
                    svg.append("  <circle cx=\"\(cx)\" cy=\"\(cy)\" r=\"\(r)\" fill=\"\(jdg.trafficLightHexFill)\"/>")
                    svg.append("  <text x=\"\(cx)\" y=\"\(cy + 4)\" text-anchor=\"middle\" font-size=\"12\" font-weight=\"700\" fill=\"#FFFFFF\">\(jdg.trafficLightSymbol)</text>")
                }
            }
        }

        // Stacked Horizontal Percentage Summary Bars (Weighted)
        svg.append("  <text x=\"32\" y=\"\(summaryTop - 14)\" font-size=\"13\" font-weight=\"700\" fill=\"#1B3B30\">Weighted Risk-of-Bias Distribution Across Domains (%)</text>")
        let barLeft = 286.0
        let barTotalWidth = 540.0

        for (dIdx, dist) in distributions.enumerated() {
            let yTop = summaryTop + dIdx * barRowHeight
            let barH = 18
            svg.append("  <text x=\"32\" y=\"\(yTop + 13)\" font-size=\"11\" fill=\"#2B302C\">\(Self.escapeXML(dist.label))</text>")

            let wLow = max(0.0, dist.lowRiskShare) * barTotalWidth
            let wSome = max(0.0, dist.someConcernsShare) * barTotalWidth
            let wHigh = max(0.0, dist.highRiskShare) * barTotalWidth

            var cursorX = barLeft
            if wLow > 0.4 {
                svg.append(String(format: "  <rect x=\"%.1f\" y=\"%d\" width=\"%.1f\" height=\"%d\" fill=\"#2E8555\"/>", cursorX, yTop, wLow, barH))
                cursorX += wLow
            }
            if wSome > 0.4 {
                svg.append(String(format: "  <rect x=\"%.1f\" y=\"%d\" width=\"%.1f\" height=\"%d\" fill=\"#D99B26\"/>", cursorX, yTop, wSome, barH))
                cursorX += wSome
            }
            if wHigh > 0.4 {
                svg.append(String(format: "  <rect x=\"%.1f\" y=\"%d\" width=\"%.1f\" height=\"%d\" fill=\"#C43B3B\"/>", cursorX, yTop, wHigh, barH))
            }
            svg.append(String(format: "  <rect x=\"%.1f\" y=\"%d\" width=\"%.1f\" height=\"%d\" fill=\"none\" stroke=\"#59544B\" stroke-width=\"0.8\"/>", barLeft, yTop, barTotalWidth, barH))
        }

        // 0% / 25% / 50% / 75% / 100% axis ticks
        let axisY = summaryTop + distributions.count * barRowHeight + 14
        for pct in [0, 25, 50, 75, 100] {
            let tx = barLeft + (Double(pct) / 100.0) * barTotalWidth
            svg.append(String(format: "  <text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\" font-size=\"10\" fill=\"#5C574F\">%d%%</text>", tx, axisY, pct))
        }

        svg.append("</svg>")
        return svg.joined(separator: "\n")
    }

    // MARK: 3. DerSimonian-Laird Meta-Synthesis & Heterogeneity Planner

    /// Computes inverse-variance fixed-effect and DerSimonian-Laird random-effects estimates, Cochran's $Q$, $I^2$, $\tau^2_{DL}$, 95% prediction interval, Egger's regression asymmetry test, and recommends quantitative pooling vs SWiM narrative synthesis.
    public func planMetaSynthesis(
        outcomeName: String,
        effectMeasureLabel: String = "Standardized Mean Difference (g)",
        studies: [StudyEffectEstimateRecord]
    ) -> MetaSynthesisHeterogeneityPlan {
        let k = studies.count
        let totalN = studies.reduce(0) { $0 + $1.sampleSizeN }

        guard k > 0 else {
            return MetaSynthesisHeterogeneityPlan(
                outcomeName: outcomeName,
                effectMeasureLabel: effectMeasureLabel,
                kStudies: 0,
                totalSampleSize: 0,
                fixedEffectEstimate: 0.0,
                fixedEffectSE: 0.0,
                fixedEffect95CILower: 0.0,
                fixedEffect95CIUpper: 0.0,
                randomEffectsEstimate: 0.0,
                randomEffectsSE: 0.0,
                randomEffects95CILower: 0.0,
                randomEffects95CIUpper: 0.0,
                predictionInterval95Lower: nil,
                predictionInterval95Upper: nil,
                cochransQ: 0.0,
                degreesOfFreedom: 0,
                heterogeneityPValue: 1.0,
                higginsISquaredPercent: 0.0,
                tauSquaredDL: 0.0,
                tauBetweenStudySD: 0.0,
                eggerIntercept: nil,
                eggerTwoSidedPValue: nil,
                normalizedRandomWeightsByCiteKey: [:],
                recommendedSynthesisMode: .synthesisWithoutMetaAnalysisSWiM,
                planningRationale: "No quantitative study effect estimates available; use SWiM structured narrative synthesis."
            )
        }

        let z95 = 1.959963984540054
        // Fixed-effect inverse-variance weights w_i = 1 / SE_i^2
        let wi = studies.map { 1.0 / ($0.standardError * $0.standardError) }
        let sumW = wi.reduce(0.0, +)
        let sumWY = zip(wi, studies).reduce(0.0) { $0 + $1.0 * $1.1.effectEstimate }
        let muFE = sumWY / sumW
        let seFE = (1.0 / sumW).squareRoot()

        if k == 1 {
            let singleKey = studies[0].citeKey
            return MetaSynthesisHeterogeneityPlan(
                outcomeName: outcomeName,
                effectMeasureLabel: effectMeasureLabel,
                kStudies: 1,
                totalSampleSize: totalN,
                fixedEffectEstimate: muFE,
                fixedEffectSE: seFE,
                fixedEffect95CILower: muFE - z95 * seFE,
                fixedEffect95CIUpper: muFE + z95 * seFE,
                randomEffectsEstimate: muFE,
                randomEffectsSE: seFE,
                randomEffects95CILower: muFE - z95 * seFE,
                randomEffects95CIUpper: muFE + z95 * seFE,
                predictionInterval95Lower: nil,
                predictionInterval95Upper: nil,
                cochransQ: 0.0,
                degreesOfFreedom: 0,
                heterogeneityPValue: 1.0,
                higginsISquaredPercent: 0.0,
                tauSquaredDL: 0.0,
                tauBetweenStudySD: 0.0,
                eggerIntercept: nil,
                eggerTwoSidedPValue: nil,
                normalizedRandomWeightsByCiteKey: [singleKey: 100.0],
                recommendedSynthesisMode: .synthesisWithoutMetaAnalysisSWiM,
                planningRationale: "Single eligible study (k = 1); report point estimate & 95% CI without meta-analytic pooling."
            )
        }

        // Cochran's Q = sum w_i (y_i - mu_FE)^2
        var qStat = 0.0
        var sumWSquared = 0.0
        for (idx, s) in studies.enumerated() {
            let diff = s.effectEstimate - muFE
            qStat += wi[idx] * diff * diff
            sumWSquared += wi[idx] * wi[idx]
        }
        let df = k - 1
        let qPVal = PsychometricNormalMath.chiSquareUpperTailPValue(chiSquare: qStat, degreesOfFreedom: df)
        let iSquared = qStat > Double(df) ? min(100.0, max(0.0, ((qStat - Double(df)) / qStat) * 100.0)) : 0.0

        // DerSimonian & Laird (1986) scaling constant C = sum(w_i) - sum(w_i^2)/sum(w_i)
        let cConst = max(1e-9, sumW - (sumWSquared / sumW))
        let tauSq = max(0.0, (qStat - Double(df)) / cConst)
        let tau = tauSq.squareRoot()

        // Random-effects weights w*_i = 1 / (SE_i^2 + tau^2)
        let wiStar = studies.map { 1.0 / ($0.standardError * $0.standardError + tauSq) }
        let sumWStar = wiStar.reduce(0.0, +)
        let muRE = zip(wiStar, studies).reduce(0.0) { $0 + $1.0 * $1.1.effectEstimate } / sumWStar
        let seRE = (1.0 / sumWStar).squareRoot()

        var weightsMap: [String: Double] = [:]
        for (idx, s) in studies.enumerated() {
            weightsMap[s.citeKey] = (wiStar[idx] / sumWStar) * 100.0
        }

        // 95% Prediction Interval for k >= 3 (Riley, Higgins & Deeks 2011; t_{k-2, 0.975} approximation)
        let predLower: Double?
        let predUpper: Double?
        if k >= 3 {
            let tCrit = Self.studentTCritical975(degreesOfFreedom: max(1, k - 2))
            let predSD = (tauSq + seRE * seRE).squareRoot()
            predLower = muRE - tCrit * predSD
            predUpper = muRE + tCrit * predSD
        } else {
            predLower = nil
            predUpper = nil
        }

        // Egger's linear regression test of funnel-plot asymmetry (for k >= 3, normative power when k >= 10):
        // Regress standardized effect SND_i = y_i / SE_i on precision P_i = 1 / SE_i; intercept beta_0 tests asymmetry
        let eggerResult = k >= 3 ? Self.computeEggerAsymmetryTest(studies: studies) : nil

        // Synthesis mode recommendation rule
        let distinctSubgroups = Set(studies.map(\.subgroupLabel)).count
        let mode: SynthesisRecommendationMode
        let rationale: String
        if iSquared >= 85.0 {
            if distinctSubgroups >= 2 {
                mode = .subgroupStratifiedMetaAnalysis
                rationale = String(
                    format: "Considerable heterogeneity (I² = %.1f%%, Q(%d) = %.2f, p = %.4f, τ² = %.4f); stratify random-effects synthesis across the %d pre-specified subgroups before overall pooling.",
                    iSquared, df, qStat, qPVal, tauSq, distinctSubgroups
                )
            } else {
                mode = .synthesisWithoutMetaAnalysisSWiM
                rationale = String(
                    format: "Extreme unstratified heterogeneity (I² = %.1f%% >= 85%%, τ = %.3f); unadjusted grand-mean pooling risks misleading inference — apply Campbell/Cochrane SWiM reporting.",
                    iSquared, tau
                )
            }
        } else if iSquared <= 20.0 && tauSq < 1e-6 && k <= 5 {
            mode = .fixedEffectInverseVariance
            rationale = String(
                format: "Negligible statistical heterogeneity (I² = %.1f%%, Q(%d) = %.2f, p = %.3f); fixed-effect and DerSimonian-Laird estimates coincide.",
                iSquared, df, qStat, qPVal
            )
        } else {
            mode = .randomEffectsDerSimonianLaird
            rationale = String(
                format: "Moderate/manageable heterogeneity (I² = %.1f%%, τ² = %.4f); random-effects pooling recommended with 95%% prediction interval reporting.",
                iSquared, tauSq
            )
        }

        return MetaSynthesisHeterogeneityPlan(
            outcomeName: outcomeName,
            effectMeasureLabel: effectMeasureLabel,
            kStudies: k,
            totalSampleSize: totalN,
            fixedEffectEstimate: muFE,
            fixedEffectSE: seFE,
            fixedEffect95CILower: muFE - z95 * seFE,
            fixedEffect95CIUpper: muFE + z95 * seFE,
            randomEffectsEstimate: muRE,
            randomEffectsSE: seRE,
            randomEffects95CILower: muRE - z95 * seRE,
            randomEffects95CIUpper: muRE + z95 * seRE,
            predictionInterval95Lower: predLower,
            predictionInterval95Upper: predUpper,
            cochransQ: qStat,
            degreesOfFreedom: df,
            heterogeneityPValue: qPVal,
            higginsISquaredPercent: iSquared,
            tauSquaredDL: tauSq,
            tauBetweenStudySD: tau,
            eggerIntercept: eggerResult?.intercept,
            eggerTwoSidedPValue: eggerResult?.pValue,
            normalizedRandomWeightsByCiteKey: weightsMap,
            recommendedSynthesisMode: mode,
            planningRationale: rationale
        )
    }

    // MARK: 4. Automated GRADE Outcome Builder from RoB 2.0 + Meta-Synthesis Plan

    /// Automatically constructs a `GRADEOutcomeEvidenceRow` with transparent explanatory footnotes from a `RoB2TrafficLightMatrix` and `MetaSynthesisHeterogeneityPlan`.
    public func deriveGRADEOutcomeRow(
        plan: MetaSynthesisHeterogeneityPlan,
        robMatrix: RoB2TrafficLightMatrix?,
        designClass: EvidenceStudyDesignClass = .randomizedControlledTrials,
        indirectnessDowngrade: GRADEDowngradeSeverity = .none,
        optimalInformationSizeThreshold: Int = 400,
        nullEffectThreshold: Double = 0.0
    ) -> GRADEOutcomeEvidenceRow {
        var notes: [String] = []

        // 1. Risk of bias
        let robDown = robMatrix?.recommendedGRADERiskOfBiasDowngrade ?? .none
        if robDown != .none, let robMatrix {
            notes.append(
                String(
                    format: "Risk of bias downgraded (%@): %.0f%% high-risk and %.0f%% some-concerns studies.",
                    robDown.label,
                    robMatrix.highRiskStudyProportion * 100.0,
                    robMatrix.someConcernsStudyProportion * 100.0
                )
            )
        }

        // 2. Inconsistency (I² & prediction interval crossing null)
        let inconDown: GRADEDowngradeSeverity
        if plan.higginsISquaredPercent >= 75.0 {
            inconDown = .verySerious
            notes.append(String(format: "Very serious inconsistency: I² = %.1f%% (p = %.4f).", plan.higginsISquaredPercent, plan.heterogeneityPValue))
        } else if plan.higginsISquaredPercent >= 50.0 {
            inconDown = .serious
            notes.append(String(format: "Substantial heterogeneity: I² = %.1f%% (τ² = %.4f).", plan.higginsISquaredPercent, plan.tauSquaredDL))
        } else {
            inconDown = .none
        }

        // 3. Indirectness
        if indirectnessDowngrade != .none {
            notes.append("Indirectness downgraded (\(indirectnessDowngrade.label)): PICO population/setting surrogate differences.")
        }

        // 4. Imprecision (Optimal Information Size & 95% CI crossing null effect)
        let crossesNull = (plan.randomEffects95CILower <= nullEffectThreshold && plan.randomEffects95CIUpper >= nullEffectThreshold)
        let belowOIS = plan.totalSampleSize < optimalInformationSizeThreshold
        let impDown: GRADEDowngradeSeverity
        if crossesNull && belowOIS {
            impDown = .verySerious
            notes.append("Very serious imprecision: total N = \(plan.totalSampleSize) < OIS (\(optimalInformationSizeThreshold)) and 95% CI crosses null (\(String(format: "%.2f", nullEffectThreshold))).")
        } else if crossesNull || belowOIS {
            impDown = .serious
            notes.append("Serious imprecision: \(belowOIS ? "total sample N = \(plan.totalSampleSize) below OIS (\(optimalInformationSizeThreshold))" : "95% CI spans null threshold").")
        } else {
            impDown = .none
        }

        // 5. Publication bias (Egger test when k >= 10 or strong funnel asymmetry)
        let pubDown: GRADEDowngradeSeverity
        if plan.kStudies >= 5, let eggerP = plan.eggerTwoSidedPValue, eggerP < 0.05 {
            pubDown = .serious
            notes.append(String(format: "Small-study asymmetry suspected (Egger intercept = %.2f, p = %.3f).", plan.eggerIntercept ?? 0.0, eggerP))
        } else {
            pubDown = .none
        }

        let formattedEffect = String(
            format: "%.2f (95%% CI %.2f to %.2f; I² = %.0f%%)",
            plan.randomEffectsEstimate,
            plan.randomEffects95CILower,
            plan.randomEffects95CIUpper,
            plan.higginsISquaredPercent
        )

        return GRADEOutcomeEvidenceRow(
            outcomeName: plan.outcomeName,
            numberOfStudies: plan.kStudies,
            totalParticipantsOrRuns: plan.totalSampleSize,
            designClass: designClass,
            riskOfBiasDowngrade: robDown,
            inconsistencyDowngrade: inconDown,
            indirectnessDowngrade: indirectnessDowngrade,
            imprecisionDowngrade: impDown,
            publicationBiasDowngrade: pubDown,
            pooledEffectFormatted: formattedEffect,
            explanatoryFootnotes: notes
        )
    }

    // MARK: 5. LaTeX `booktabs` Methods, Study-Characteristics & GRADE Table Generators

    /// Generates a publication-ready LaTeX `booktabs` Study Characteristics & Risk-of-Bias Summary Table.
    public func exportLaTeXStudyCharacteristicsTable(
        rows: [StudyCharacteristicsRow],
        caption: String = "Characteristics and Methodological Appraisal of Included Studies",
        label: String = "tab:study-characteristics"
    ) -> String {
        var out: [String] = []
        out.append("% Generated by ScholarOS RiskOfBiasAndMetaSynthesisPlanner (requires \\usepackage{booktabs})")
        out.append("\\begin{table*}[t]")
        out.append("  \\centering")
        out.append("  \\caption{\(Self.escapeLaTeX(caption))}")
        out.append("  \\label{\(Self.escapeLaTeX(label))}")
        out.append("  \\small")
        out.append("  \\begin{tabular}{@{}llllll@{}}")
        out.append("    \\toprule")
        out.append("    \\textbf{Study} & \\textbf{Design} & \\textbf{Population / $N$} & \\textbf{Intervention vs.\\ Comparator} & \\textbf{Primary Outcome} & \\textbf{Risk of Bias} \\\\")
        out.append("    \\midrule")

        if rows.isEmpty {
            out.append("    \\multicolumn{6}{c}{\\emph{No included studies available.}} \\\\")
        } else {
            for r in rows {
                let citeCell = "\(Self.escapeLaTeX(r.authorYearDisplay))~\\cite{\(r.citeKey)}"
                let designCell = Self.escapeLaTeX(r.studyDesign)
                let popCell = "\(Self.escapeLaTeX(r.populationOrBenchmark)) (\(Self.escapeLaTeX(r.sampleSizeDescription)))"
                let intCompCell = "\(Self.escapeLaTeX(r.interventionMechanism)) vs.\\ \(Self.escapeLaTeX(r.comparatorBaseline))"
                let outCell = Self.escapeLaTeX(r.primaryOutcomeSummary)
                let robCell = Self.escapeLaTeX(r.overallRiskOfBiasSummary)
                out.append("    \(citeCell) & \(designCell) & \(popCell) & \(intCompCell) & \(outCell) & \(robCell) \\\\")
            }
        }

        out.append("    \\bottomrule")
        out.append("  \\end{tabular}")
        out.append("\\end{table*}")
        return out.joined(separator: "\n")
    }

    /// Generates a publication-ready LaTeX `booktabs` GRADE Summary-of-Findings (SoF) table with footnote explanations.
    public func exportLaTeXGRADESummaryTable(
        outcomes: [GRADEOutcomeEvidenceRow],
        caption: String = "GRADE Summary of Findings and Certainty of Evidence",
        label: String = "tab:grade-sof"
    ) -> String {
        var out: [String] = []
        var collectedFootnotes: [String] = []

        out.append("% Generated by ScholarOS GRADE Certainty-of-Evidence Engine (requires \\usepackage{booktabs})")
        out.append("\\begin{table*}[t]")
        out.append("  \\centering")
        out.append("  \\caption{\(Self.escapeLaTeX(caption))}")
        out.append("  \\label{\(Self.escapeLaTeX(label))}")
        out.append("  \\small")
        out.append("  \\begin{tabular}{@{}lcccccll@{}}")
        out.append("    \\toprule")
        out.append("    \\textbf{Outcome} & $k$ ($N$) & \\textbf{RoB} & \\textbf{Inconsist.} & \\textbf{Indirect.} & \\textbf{Imprec.} & \\textbf{Pooled Estimate} & \\textbf{GRADE Certainty} \\\\")
        out.append("    \\midrule")

        if outcomes.isEmpty {
            out.append("    \\multicolumn{8}{c}{\\emph{No outcome syntheses evaluated.}} \\\\")
        } else {
            for row in outcomes {
                var fnRefs: [String] = []
                for note in row.explanatoryFootnotes {
                    collectedFootnotes.append(note)
                    fnRefs.append("\(collectedFootnotes.count)")
                }
                let supTag = fnRefs.isEmpty ? "" : "$^{\\text{\(fnRefs.joined(separator: ","))}}$"
                let outcomeCell = Self.escapeLaTeX(row.outcomeName) + supTag
                let knCell = "\(row.numberOfStudies) (\(row.totalParticipantsOrRuns))"
                let robTag = Self.shortDowngradeTag(row.riskOfBiasDowngrade)
                let incTag = Self.shortDowngradeTag(row.inconsistencyDowngrade)
                let indTag = Self.shortDowngradeTag(row.indirectnessDowngrade)
                let impTag = Self.shortDowngradeTag(row.imprecisionDowngrade)
                let effectCell = Self.escapeLaTeX(row.pooledEffectFormatted)
                out.append("    \(outcomeCell) & \(knCell) & \(robTag) & \(incTag) & \(indTag) & \(impTag) & \(effectCell) & \(row.certaintyLevel.latexSymbols) \\\\")
            }
        }

        out.append("    \\bottomrule")
        out.append("  \\end{tabular}")

        if !collectedFootnotes.isEmpty {
            out.append("  \\vspace{4pt}")
            out.append("  \\begin{flushleft}\\footnotesize")
            for (idx, note) in collectedFootnotes.enumerated() {
                out.append("  $^{\(idx + 1)}$\(Self.escapeLaTeX(note))\\quad")
            }
            out.append("  \\end{flushleft}")
        }

        out.append("\\end{table*}")
        return out.joined(separator: "\n")
    }

    /// Generates a PRISMA 2020-compliant LaTeX `\section{Methods}` draft covering PICO eligibility, dual-blind calibration, RoB appraisal, and meta-synthesis protocol.
    public func exportLaTeXPRISMAMethodsDraft(
        protocolSpec: PICOProtocolSpec,
        prismaMetrics: PRISMA2020SummaryMetrics,
        appraisalFrameworkSummary: String = "Cochrane RoB 2.0 for randomized controlled benchmarks and ROBINS-I / Newcastle-Ottawa Scale for non-randomized observational evaluations"
    ) -> String {
        let exclusionBullets = protocolSpec.exclusionRules
            .sorted { $0.priorityOrder < $1.priorityOrder }
            .map { "  \\item \\texttt{\(Self.escapeLaTeX($0.code))}: \(Self.escapeLaTeX($0.label))" }
            .joined(separator: "\n")

        return """
        % Generated by ScholarOS PRISMA 2020 Methods Synthesizer
        \\subsection{Eligibility Criteria and Screening Protocol}
        Following PRISMA 2020 guidelines, we formulated a pre-specified PICO protocol targeting \\emph{\(Self.escapeLaTeX(protocolSpec.population))} (Population), evaluating \\emph{\(Self.escapeLaTeX(protocolSpec.intervention))} (Intervention) against \\emph{\(Self.escapeLaTeX(protocolSpec.comparator))} (Comparator) across \\emph{\(Self.escapeLaTeX(protocolSpec.outcomes))} (Outcomes). Across database and register searches, \(prismaMetrics.databaseRecordsIdentified + prismaMetrics.registerRecordsIdentified) records were identified and \(prismaMetrics.duplicateRecordsRemoved) duplicates were removed prior to screening.

        Two blinded reviewers independently screened \(prismaMetrics.recordsScreenedTitleAbstract) records, achieving an observed agreement of \(String(format: "%.1f\\%%", prismaMetrics.observedAgreementRate * 100.0)) (Cohen's $\\kappa = \(String(format: "%.3f", prismaMetrics.cohensKappa))$, Byrt's PABAK $= \(String(format: "%.3f", prismaMetrics.pabakScore))$). Discrepancies were resolved by an independent third adjudicator using priority-ordered exclusion codes:
        \\begin{enumerate}
        \(exclusionBullets)
        \\end{enumerate}

        \\subsection{Risk of Bias and Evidence Synthesis}
        Study-level methodological quality across the \(prismaMetrics.finalIncludedStudies) included studies was appraised using \(Self.escapeLaTeX(appraisalFrameworkSummary)). Quantitative pooling employed inverse-variance fixed-effect and DerSimonian--Laird random-effects models ($\\tau^2_{\\text{DL}}$, Cochran's $Q$, and Higgins' $I^2$), with overall certainty graded via the GRADE Summary-of-Findings framework.
        """
    }

    // MARK: - Internal Statistical & Formatting Helpers

    private static func computeEggerAsymmetryTest(studies: [StudyEffectEstimateRecord]) -> (intercept: Double, pValue: Double)? {
        let k = studies.count
        guard k >= 3 else { return nil }
        let kf = Double(k)
        // Precision x_i = 1 / SE_i, standardized normal deviate y_i = effect_i / SE_i
        let xs = studies.map { 1.0 / $0.standardError }
        let ys = studies.map { $0.effectEstimate / $0.standardError }

        let meanX = xs.reduce(0.0, +) / kf
        let meanY = ys.reduce(0.0, +) / kf
        var sxx = 0.0
        var sxy = 0.0
        for i in 0..<k {
            let dx = xs[i] - meanX
            let dy = ys[i] - meanY
            sxx += dx * dx
            sxy += dx * dy
        }
        guard sxx > 1e-12 else { return nil }
        let slope = sxy / sxx
        let intercept = meanY - slope * meanX

        var rss = 0.0
        for i in 0..<k {
            let resid = ys[i] - (intercept + slope * xs[i])
            rss += resid * resid
        }
        let df = max(1, k - 2)
        let sigmaSq = rss / Double(df)
        let seIntercept = (sigmaSq * ((1.0 / kf) + (meanX * meanX) / sxx)).squareRoot()
        guard seIntercept > 1e-12 else { return (intercept, 1.0) }
        let tStat = abs(intercept / seIntercept)
        let pApprox = studentTTwoSidedPValue(tAbs: tStat, degreesOfFreedom: df)
        return (intercept, pApprox)
    }

    /// Accurate two-sided Student-$t$ critical quantile $t_{\nu, 0.975}$ via Peizer-Pratt / Cornish-Fisher expansion.
    private static func studentTCritical975(degreesOfFreedom df: Int) -> Double {
        switch df {
        case 1: return 12.7062047364
        case 2: return 4.3026527299
        case 3: return 3.1824463053
        case 4: return 2.7764451052
        case 5: return 2.5705818366
        case 6: return 2.4469118488
        case 7: return 2.3646242510
        case 8: return 2.3060041350
        case 9: return 2.2621571627
        case 10: return 2.2281388520
        default:
            let z = 1.959963984540054
            let nu = Double(df)
            let g1 = (z * z * z + z) / (4.0 * nu)
            let g2 = (5.0 * Foundation.pow(z, 5.0) + 16.0 * z * z * z + 3.0 * z) / (96.0 * nu * nu)
            return z + g1 + g2
        }
    }

    private static func studentTTwoSidedPValue(tAbs: Double, degreesOfFreedom df: Int) -> Double {
        guard tAbs > 0.0 else { return 1.0 }
        if df == 1 {
            return min(1.0, max(0.0, 1.0 - (2.0 / Double.pi) * Foundation.atan(tAbs)))
        }
        if df == 2 {
            return min(1.0, max(0.0, 1.0 - tAbs / (2.0 + tAbs * tAbs).squareRoot()))
        }
        // Wallace (1959) normal-deviate transformation for t-distribution tail:
        // z = sqrt(df * log(1 + t^2 / df)) * (1 - 1 / (4 * df))
        let nu = Double(df)
        let zEquiv = (nu * Foundation.log(1.0 + (tAbs * tAbs) / nu)).squareRoot() * (1.0 - 1.0 / (4.0 * nu))
        return PsychometricNormalMath.twoSidedNormalPValue(zScore: zEquiv)
    }

    private static func shortDowngradeTag(_ severity: GRADEDowngradeSeverity) -> String {
        switch severity {
        case .none: return "0"
        case .serious: return "$-1$"
        case .verySerious: return "$-2$"
        }
    }

    private static func escapeLaTeX(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count + 16)
        for ch in raw {
            switch ch {
            case "\\": out.append("\\textbackslash{}")
            case "&": out.append("\\&")
            case "%": out.append("\\%")
            case "$": out.append("\\$")
            case "#": out.append("\\#")
            case "_": out.append("\\_")
            case "{": out.append("\\{")
            case "}": out.append("\\}")
            case "~": out.append("\\textasciitilde{}")
            case "^": out.append("\\textasciicircum{}")
            default: out.append(ch)
            }
        }
        return out
    }

    private static func escapeXML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
