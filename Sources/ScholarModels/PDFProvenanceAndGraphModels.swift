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

public struct PDFPassageChunk: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let citeKey: String
    public let pdfFileName: String
    public let sectionTitle: String
    public let columnIndex: Int
    public let readingSequence: Int
    public let boundingBox: PDFPageRegionBox
    public let passageText: String

    public init(
        id: String,
        citeKey: String,
        pdfFileName: String,
        sectionTitle: String,
        columnIndex: Int,
        readingSequence: Int,
        boundingBox: PDFPageRegionBox,
        passageText: String
    ) {
        self.id = id
        self.citeKey = citeKey
        self.pdfFileName = pdfFileName
        self.sectionTitle = sectionTitle
        self.columnIndex = columnIndex
        self.readingSequence = readingSequence
        self.boundingBox = boundingBox
        self.passageText = passageText
    }
}

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
