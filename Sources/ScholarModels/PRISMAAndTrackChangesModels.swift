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
