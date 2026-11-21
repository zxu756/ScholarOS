import Foundation

// MARK: - PDF Bounding-Box Provenance & Barnes-Hut Citation Knowledge Graph

public struct PDFPageRegionBox: Sendable, Codable, Hashable {
    public let pageIndex: Int
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(pageIndex: Int, x: Double, y: Double, width: Double, height: Double) {
        self.pageIndex = pageIndex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum PDFPassageChunkKind: String, Sendable, Codable, Hashable, CaseIterable {
    case body = "body"
    case sectionHeading = "section_heading"
    case tableOrFigure = "table_or_figure"
    case header = "header"
    case footer = "footer"

    public var isHeaderOrFooter: Bool {
        self == .header || self == .footer
    }
}

public struct PDFPassageChunk: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let citeKey: String
    public let pdfFileName: String
    public let sectionTitle: String
    public let columnIndex: Int
    public let readingSequence: Int
    public let boundingBox: PDFPageRegionBox
    public let passageText: String
    public let kind: PDFPassageChunkKind

    public var pageNumber: Int {
        boundingBox.pageIndex + 1
    }

    public init(
        id: String,
        citeKey: String,
        pdfFileName: String,
        sectionTitle: String,
        columnIndex: Int,
        readingSequence: Int,
        boundingBox: PDFPageRegionBox,
        passageText: String,
        kind: PDFPassageChunkKind = .body
    ) {
        self.id = id
        self.citeKey = citeKey
        self.pdfFileName = pdfFileName
        self.sectionTitle = sectionTitle
        self.columnIndex = columnIndex
        self.readingSequence = readingSequence
        self.boundingBox = boundingBox
        self.passageText = passageText
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case citeKey
        case pdfFileName
        case sectionTitle
        case columnIndex
        case readingSequence
        case boundingBox
        case passageText
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.citeKey = try container.decode(String.self, forKey: .citeKey)
        self.pdfFileName = try container.decode(String.self, forKey: .pdfFileName)
        self.sectionTitle = try container.decode(String.self, forKey: .sectionTitle)
        self.columnIndex = try container.decode(Int.self, forKey: .columnIndex)
        self.readingSequence = try container.decode(Int.self, forKey: .readingSequence)
        self.boundingBox = try container.decode(PDFPageRegionBox.self, forKey: .boundingBox)
        self.passageText = try container.decode(String.self, forKey: .passageText)
        self.kind = try container.decodeIfPresent(PDFPassageChunkKind.self, forKey: .kind) ?? .body
    }
}

// MARK: - Evidence Localization & Quantitative Checking Models (M4, schema "scholaros.evidence/1")

/// Three-way outcome for local PDF passage localization and explicit number/unit verification.
/// Does NOT claim semantic entailment or logical support.
public enum EvidenceLocalizationVerdict: String, Sendable, Codable, Hashable, CaseIterable {
    case found = "FOUND"
    case numericMismatch = "NUMERIC_MISMATCH"
    case notFound = "NOT_FOUND"

    /// Standard CLI exit code: 0 FOUND, 1 NUMERIC_MISMATCH, 3 NOT_FOUND (2 reserved for errors).
    public var cliExitCode: Int32 {
        switch self {
        case .found:
            return 0
        case .numericMismatch:
            return 1
        case .notFound:
            return 3
        }
    }
}

/// Page-local geometric rectangle in PDF mediaBox coordinates (origin at bottom-left, points).
public struct EvidenceBoundingBox: Sendable, Codable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(regionBox: PDFPageRegionBox) {
        self.x = regionBox.x
        self.y = regionBox.y
        self.width = regionBox.width
        self.height = regionBox.height
    }
}

/// Quantitative discrepancy between a number+unit/noun phrase in a claim and the corresponding PDF passage.
public struct EvidenceNumericDiscrepancy: Sendable, Codable, Hashable {
    public let claimText: String
    public let pdfText: String?
    public let reason: String

    public init(claimText: String, pdfText: String?, reason: String) {
        self.claimText = claimText
        self.pdfText = pdfText
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case claimText = "claim_text"
        case pdfText = "pdf_text"
        case reason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(claimText, forKey: .claimText)
        if let pdfText {
            try container.encode(pdfText, forKey: .pdfText)
        } else {
            try container.encodeNil(forKey: .pdfText)
        }
        try container.encode(reason, forKey: .reason)
    }
}

/// A candidate PDF passage that passed the keyword coverage threshold, with page/box coordinates and numeric check details.
public struct EvidencePassageMatch: Sendable, Codable, Hashable, Identifiable {
    public var id: String { passageID }
    public let passageID: String
    public let citeKey: String?
    public let pdfFile: String
    /// 1-based physical page number (`pageIndex + 1`).
    public let page: Int
    /// 0-based page index.
    public let pageIndex: Int
    public let boundingBox: EvidenceBoundingBox
    public let columnIndex: Int
    public let sectionTitle: String
    public let kind: PDFPassageChunkKind
    public let excerpt: String
    public let coverage: Double
    public let matchedKeywords: [String]
    public let bm25Score: Double
    public let discrepancies: [EvidenceNumericDiscrepancy]

    public init(
        passageID: String,
        citeKey: String?,
        pdfFile: String,
        page: Int,
        pageIndex: Int,
        boundingBox: EvidenceBoundingBox,
        columnIndex: Int,
        sectionTitle: String,
        kind: PDFPassageChunkKind = .body,
        excerpt: String,
        coverage: Double,
        matchedKeywords: [String] = [],
        bm25Score: Double = 0.0,
        discrepancies: [EvidenceNumericDiscrepancy] = []
    ) {
        self.passageID = passageID
        self.citeKey = citeKey
        self.pdfFile = pdfFile
        self.page = page
        self.pageIndex = pageIndex
        self.boundingBox = boundingBox
        self.columnIndex = columnIndex
        self.sectionTitle = sectionTitle
        self.kind = kind
        self.excerpt = excerpt
        self.coverage = coverage
        self.matchedKeywords = matchedKeywords
        self.bm25Score = bm25Score
        self.discrepancies = discrepancies
    }

    public init(
        chunk: PDFPassageChunk,
        coverage: Double,
        matchedKeywords: [String] = [],
        bm25Score: Double = 0.0,
        discrepancies: [EvidenceNumericDiscrepancy] = []
    ) {
        self.init(
            passageID: chunk.id,
            citeKey: chunk.citeKey.isEmpty ? nil : chunk.citeKey,
            pdfFile: chunk.pdfFileName,
            page: chunk.boundingBox.pageIndex + 1,
            pageIndex: chunk.boundingBox.pageIndex,
            boundingBox: EvidenceBoundingBox(regionBox: chunk.boundingBox),
            columnIndex: chunk.columnIndex,
            sectionTitle: chunk.sectionTitle,
            kind: chunk.kind,
            excerpt: chunk.passageText,
            coverage: coverage,
            matchedKeywords: matchedKeywords,
            bm25Score: bm25Score,
            discrepancies: discrepancies
        )
    }

    private enum CodingKeys: String, CodingKey {
        case passageID = "passage_id"
        case citeKey = "cite_key"
        case pdfFile = "pdf_file"
        case page
        case pageIndex = "page_index"
        case boundingBox = "bounding_box"
        case columnIndex = "column_index"
        case sectionTitle = "section_title"
        case kind
        case excerpt
        case coverage
        case matchedKeywords = "matched_keywords"
        case bm25Score = "bm25_score"
        case discrepancies
    }
}

/// Top-level JSON-serializable result for M4 evidence localization (`schema: "scholaros.evidence/1"`).
public struct EvidenceLocalizationResult: Sendable, Codable, Hashable {
    public static let currentSchema = "scholaros.evidence/1"

    public let schema: String
    public let claim: String
    public let pdfFile: String?
    public let verdict: EvidenceLocalizationVerdict
    public let queryKeywords: [String]
    public let page: Int?
    public let pageIndex: Int?
    public let boundingBox: EvidenceBoundingBox?
    public let columnIndex: Int?
    public let sectionTitle: String?
    public let excerpt: String?
    public let coverage: Double?
    public let discrepancies: [EvidenceNumericDiscrepancy]
    public let matches: [EvidencePassageMatch]

    public init(
        schema: String = EvidenceLocalizationResult.currentSchema,
        claim: String,
        pdfFile: String? = nil,
        verdict: EvidenceLocalizationVerdict,
        queryKeywords: [String] = [],
        matches: [EvidencePassageMatch] = [],
        discrepancies: [EvidenceNumericDiscrepancy] = []
    ) {
        self.schema = schema
        self.claim = claim
        self.pdfFile = pdfFile ?? matches.first?.pdfFile
        self.verdict = verdict
        self.queryKeywords = queryKeywords

        if verdict == .notFound || matches.isEmpty {
            self.page = nil
            self.pageIndex = nil
            self.boundingBox = nil
            self.columnIndex = nil
            self.sectionTitle = nil
            self.excerpt = nil
            self.coverage = nil
            self.discrepancies = []
            self.matches = []
        } else {
            let primary = matches[0]
            self.page = primary.page
            self.pageIndex = primary.pageIndex
            self.boundingBox = primary.boundingBox
            self.columnIndex = primary.columnIndex
            self.sectionTitle = primary.sectionTitle
            self.excerpt = primary.excerpt
            self.coverage = primary.coverage
            self.discrepancies = verdict == .numericMismatch
                ? (discrepancies.isEmpty ? primary.discrepancies : discrepancies)
                : []
            self.matches = matches
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case claim
        case pdfFile = "pdf_file"
        case verdict
        case queryKeywords = "query_keywords"
        case page
        case pageIndex = "page_index"
        case boundingBox = "bounding_box"
        case columnIndex = "column_index"
        case sectionTitle = "section_title"
        case excerpt
        case coverage
        case discrepancies
        case matches
    }
}

// Legacy SQLite project-store / UI compatibility types (retained only for persisted project rows until M5 CiteStudio)

public enum EvidenceSupportVerdict: String, Sendable, Codable, Hashable, CaseIterable {
    case groundedEntailment = "GROUNDED"
    case partialEvidence = "PARTIAL"
    case numericDiscrepancy = "NUMERIC_MISMATCH"
    case unsupportedClaim = "UNSUPPORTED"
}

public struct ClaimEvidenceProvenance: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let manuscriptFile: String
    public let manuscriptLine: Int
    public let manuscriptClaim: String
    public let citeKey: String
    public let passageID: String
    public let pdfExcerpt: String
    public let boundingBox: PDFPageRegionBox
    public let bm25Score: Double
    public let verdict: EvidenceSupportVerdict

    public init(
        id: UUID = UUID(),
        manuscriptFile: String,
        manuscriptLine: Int,
        manuscriptClaim: String,
        citeKey: String,
        passageID: String,
        pdfExcerpt: String,
        boundingBox: PDFPageRegionBox,
        bm25Score: Double,
        verdict: EvidenceSupportVerdict
    ) {
        self.id = id
        self.manuscriptFile = manuscriptFile
        self.manuscriptLine = manuscriptLine
        self.manuscriptClaim = manuscriptClaim
        self.citeKey = citeKey
        self.passageID = passageID
        self.pdfExcerpt = pdfExcerpt
        self.boundingBox = boundingBox
        self.bm25Score = bm25Score
        self.verdict = verdict
    }
}

// MARK: - Barnes-Hut Citation Knowledge Graph

public enum CitationEdgeKind: String, Sendable, Codable, Hashable {
    case directCitation = "Direct Citation"
    case coCitation = "Co-Citation"
    case bibliographicCoupling = "Bibliographic Coupling"
}

public struct CitationGraphNode: Sendable, Codable, Hashable, Identifiable {
    public var id: String { citeKey }
    public let citeKey: String
    public let title: String
    public let authorYearLabel: String
    public let year: Int
    public let inDegree: Int
    public let outDegree: Int
    public var pageRank: Double
    public var betweennessScore: Double
    public var clusterIndex: Int
    public var isBridgePaper: Bool
    public var x: Double
    public var y: Double

    public init(
        citeKey: String,
        title: String,
        authorYearLabel: String,
        year: Int,
        inDegree: Int = 0,
        outDegree: Int = 0,
        pageRank: Double = 0.0,
        betweennessScore: Double = 0.0,
        clusterIndex: Int = 0,
        isBridgePaper: Bool = false,
        x: Double = 0.0,
        y: Double = 0.0
    ) {
        self.citeKey = citeKey
        self.title = title
        self.authorYearLabel = authorYearLabel
        self.year = year
        self.inDegree = inDegree
        self.outDegree = outDegree
        self.pageRank = pageRank
        self.betweennessScore = betweennessScore
        self.clusterIndex = clusterIndex
        self.isBridgePaper = isBridgePaper
        self.x = x
        self.y = y
    }
}

public struct CitationGraphEdge: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(sourceCiteKey)->\(targetCiteKey):\(kind.rawValue)" }
    public let sourceCiteKey: String
    public let targetCiteKey: String
    public let kind: CitationEdgeKind
    public let weight: Double

    public init(sourceCiteKey: String, targetCiteKey: String, kind: CitationEdgeKind, weight: Double = 1.0) {
        self.sourceCiteKey = sourceCiteKey
        self.targetCiteKey = targetCiteKey
        self.kind = kind
        self.weight = weight
    }
}
