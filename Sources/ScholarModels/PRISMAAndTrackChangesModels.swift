import Foundation

// MARK: - PRISMA 2020 Systematic Review Protocol & Dual-Blind Screening

public struct ExclusionReasonRule: Sendable, Codable, Hashable, Identifiable {
    public var id: String { code }
    public let priorityOrder: Int
    public let code: String
    public let label: String

    public init(priorityOrder: Int, code: String, label: String) {
        self.priorityOrder = priorityOrder
        self.code = code
        self.label = label
    }
}

public struct PICOProtocolSpec: Sendable, Codable, Hashable {
    public var reviewTitle: String
    public var population: String
    public var intervention: String
    public var comparator: String
    public var outcomes: String
    public var inclusionCriteria: [String]
    public var exclusionRules: [ExclusionReasonRule]

    public init(
        reviewTitle: String,
        population: String,
        intervention: String,
        comparator: String,
        outcomes: String,
        inclusionCriteria: [String],
        exclusionRules: [ExclusionReasonRule]
    ) {
        self.reviewTitle = reviewTitle
        self.population = population
        self.intervention = intervention
        self.comparator = comparator
        self.outcomes = outcomes
        self.inclusionCriteria = inclusionCriteria
        self.exclusionRules = exclusionRules
    }
}

public enum ScreeningStage: String, Sendable, Codable, Hashable, CaseIterable {
    case titleAbstract = "Title & Abstract"
    case fullText = "Full-Text Eligibility"
}

public enum ScreeningDecision: Sendable, Codable, Hashable, Equatable {
    case include
    case maybe
    case exclude(reasonCode: String)

    public var isIncluded: Bool {
        if case .include = self { return true }
        return false
    }

    public var summaryLabel: String {
        switch self {
        case .include: return "INCLUDE"
        case .maybe: return "MAYBE"
        case .exclude(let code): return "EXCLUDE (\(code))"
        }
    }
}

public struct ScreeningStudyRecord: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let citeKey: String
    public let title: String
    public let authorsLine: String
    public let year: Int
    public let venue: String
    public let doi: String?
    public let abstractText: String
    public var stage: ScreeningStage
    public var reviewerADecision: ScreeningDecision?
    public var reviewerBDecision: ScreeningDecision?
    public var adjudicatedDecision: ScreeningDecision?
    public var adjudicationRationale: String?

    public init(
        id: String,
        citeKey: String,
        title: String,
        authorsLine: String,
        year: Int,
        venue: String,
        doi: String? = nil,
        abstractText: String,
        stage: ScreeningStage = .titleAbstract,
        reviewerADecision: ScreeningDecision? = nil,
        reviewerBDecision: ScreeningDecision? = nil,
        adjudicatedDecision: ScreeningDecision? = nil,
        adjudicationRationale: String? = nil
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authorsLine = authorsLine
        self.year = year
        self.venue = venue
        self.doi = doi
        self.abstractText = abstractText
        self.stage = stage
        self.reviewerADecision = reviewerADecision
        self.reviewerBDecision = reviewerBDecision
        self.adjudicatedDecision = adjudicatedDecision
        self.adjudicationRationale = adjudicationRationale
    }

    public var hasReviewerConflict: Bool {
        guard let a = reviewerADecision, let b = reviewerBDecision else { return false }
        return a != b && adjudicatedDecision == nil
    }
}

// MARK: - Nominal Dual-Rater Agreement (the one implementation)

/// Observed agreement, nominal (unweighted) Cohen's kappa, and Brennan-Prediger PABAK for two raters
/// voting over arbitrary categories.
///
/// This is the only implementation of these three statistics for screening votes.
/// `ScholarProjectDatabase.computeInterRaterAgreement` (read by `prisma-stats` and the MCP tool) and
/// `PRISMAScreeningEngine.computePRISMA2020Metrics` both call it, so the two cannot disagree.
///
///     Po    = agreements / n
///     Pe    = sum over categories of (count by rater A * count by rater B) / n^2
///     kappa = (Po - Pe) / (1 - Pe)            (1 when Pe is 1)
///     PABAK = (k * Po - 1) / (k - 1)          with k = max(2, number of categories that were used)
public struct NominalDualRaterAgreement: Sendable, Hashable {
    /// Number of records that carry a vote from both raters.
    public let pairedCount: Int
    public let observedAgreement: Double
    public let chanceAgreement: Double
    public let cohensKappa: Double
    public let pabak: Double

    public init(
        pairedCount: Int,
        observedAgreement: Double,
        chanceAgreement: Double,
        cohensKappa: Double,
        pabak: Double
    ) {
        self.pairedCount = pairedCount
        self.observedAgreement = observedAgreement
        self.chanceAgreement = chanceAgreement
        self.cohensKappa = cohensKappa
        self.pabak = pabak
    }

    /// - Parameter votes: one element per record rated by both raters.
    /// - Returns: with no such record, all three statistics are reported as 1.0 (the convention both
    ///   former implementations used).
    public static func compute<Category: Hashable>(
        votes: [(raterA: Category, raterB: Category)]
    ) -> NominalDualRaterAgreement {
        let n = votes.count
        guard n > 0 else {
            return NominalDualRaterAgreement(
                pairedCount: 0,
                observedAgreement: 1.0,
                chanceAgreement: 1.0,
                cohensKappa: 1.0,
                pabak: 1.0
            )
        }

        var agreements = 0
        var countsA: [Category: Int] = [:]
        var countsB: [Category: Int] = [:]
        var categories = Set<Category>()
        for vote in votes {
            if vote.raterA == vote.raterB {
                agreements += 1
            }
            countsA[vote.raterA, default: 0] += 1
            countsB[vote.raterB, default: 0] += 1
            categories.insert(vote.raterA)
            categories.insert(vote.raterB)
        }

        let nDouble = Double(n)
        let po = Double(agreements) / nDouble
        var peNumerator = 0.0
        for category in categories {
            peNumerator += Double(countsA[category] ?? 0) * Double(countsB[category] ?? 0)
        }
        let pe = peNumerator / (nDouble * nDouble)
        let kappa: Double
        if abs(1.0 - pe) < 1e-12 {
            kappa = 1.0
        } else {
            kappa = (po - pe) / (1.0 - pe)
        }
        let k = max(2, categories.count)
        let pabak = (Double(k) * po - 1.0) / Double(k - 1)
        return NominalDualRaterAgreement(
            pairedCount: n,
            observedAgreement: po,
            chanceAgreement: pe,
            cohensKappa: kappa,
            pabak: pabak
        )
    }
}

public struct PRISMA2020SummaryMetrics: Sendable, Codable, Hashable {
    public let databaseRecordsIdentified: Int
    public let registerRecordsIdentified: Int
    public let duplicateRecordsRemoved: Int
    public let recordsScreenedTitleAbstract: Int
    public let recordsExcludedTitleAbstract: Int
    public let reportsSoughtForRetrieval: Int
    public let reportsNotRetrieved: Int
    public let fullTextAssessed: Int
    public let fullTextExcludedByReason: [String: Int]
    public let finalIncludedStudies: Int
    public let observedAgreementRate: Double
    public let cohensKappa: Double
    public let pabakScore: Double

    public init(
        databaseRecordsIdentified: Int,
        registerRecordsIdentified: Int = 0,
        duplicateRecordsRemoved: Int,
        recordsScreenedTitleAbstract: Int,
        recordsExcludedTitleAbstract: Int,
        reportsSoughtForRetrieval: Int,
        reportsNotRetrieved: Int = 0,
        fullTextAssessed: Int,
        fullTextExcludedByReason: [String: Int],
        finalIncludedStudies: Int,
        observedAgreementRate: Double,
        cohensKappa: Double,
        pabakScore: Double
    ) {
        self.databaseRecordsIdentified = databaseRecordsIdentified
        self.registerRecordsIdentified = registerRecordsIdentified
        self.duplicateRecordsRemoved = duplicateRecordsRemoved
        self.recordsScreenedTitleAbstract = recordsScreenedTitleAbstract
        self.recordsExcludedTitleAbstract = recordsExcludedTitleAbstract
        self.reportsSoughtForRetrieval = reportsSoughtForRetrieval
        self.reportsNotRetrieved = reportsNotRetrieved
        self.fullTextAssessed = fullTextAssessed
        self.fullTextExcludedByReason = fullTextExcludedByReason
        self.finalIncludedStudies = finalIncludedStudies
        self.observedAgreementRate = observedAgreementRate
        self.cohensKappa = cohensKappa
        self.pabakScore = pabakScore
    }
}

// MARK: - Word-Level Track Changes & Revision Snapshots

public enum TrackChangeSpanKind: String, Sendable, Codable, Hashable {
    case equal
    case insertion
    case deletion
}

public struct TrackChangeWordSpan: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let kind: TrackChangeSpanKind
    public let text: String

    public init(id: UUID = UUID(), kind: TrackChangeSpanKind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

public struct ManuscriptSnapshot: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let label: String
    public let authorName: String
    public let filePath: String
    public let sourceContent: String
    public let wordCount: Int
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        label: String,
        authorName: String = "Lead Author",
        filePath: String,
        sourceContent: String,
        wordCount: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.authorName = authorName
        self.filePath = filePath
        self.sourceContent = sourceContent
        self.wordCount = wordCount
        self.createdAt = createdAt
    }
}
