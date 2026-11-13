import Foundation

// MARK: - Bibliography, CSL Styles & 5-Class Citation Verification Firewall

public enum BibEntryKind: String, Sendable, Codable, Hashable, CaseIterable {
    case article
    case inproceedings
    case book
    case incollection
    case phdthesis
    case techreport
    case preprint
    case misc
}

public struct BibAuthor: Sendable, Codable, Hashable, CustomStringConvertible {
    public let givenName: String
    public let familyName: String
    public let orcid: String?

    public init(givenName: String, familyName: String, orcid: String? = nil) {
        self.givenName = givenName
        self.familyName = familyName
        self.orcid = orcid
    }

    public var apaShortForm: String {
        let initials = givenName
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .compactMap(\.first)
            .map { "\($0)." }
            .joined(separator: " ")
        return initials.isEmpty ? familyName : "\(familyName), \(initials)"
    }

    public var ieeeForm: String {
        let initials = givenName
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .compactMap(\.first)
            .map { "\($0)." }
            .joined(separator: " ")
        return initials.isEmpty ? familyName : "\(initials) \(familyName)"
    }

    public var description: String {
        givenName.isEmpty ? familyName : "\(givenName) \(familyName)"
    }
}

/// 5-Class Citation Verification Firewall Status
public enum CitationFirewallClass: String, Sendable, Codable, Hashable, CaseIterable {
    case verified = "VERIFIED"
    case drift = "DRIFT"
    case notFound = "NOT_FOUND"
    case retracted = "RETRACTED"
    case unverified = "UNVERIFIED"

    public var allowsManuscriptInsertion: Bool {
        switch self {
        case .verified:
            return true
        case .drift, .notFound, .retracted, .unverified:
            return false
        }
    }

    public var badgeTitle: String {
        switch self {
        case .verified: return "Verified"
        case .drift: return "Metadata Drift"
        case .notFound: return "Not Found"
        case .retracted: return "Retracted"
        case .unverified: return "Unverified"
        }
    }
}

public struct BibliographyEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: String { citeKey }
    public let citeKey: String
    public var kind: BibEntryKind
    public var title: String
    public var authors: [BibAuthor]
    public var year: Int?
    public var venue: String
    public var publisher: String?
    public var volume: String?
    public var issue: String?
    public var pages: String?
    public var doi: String?
    public var arxivID: String?
    public var pmid: String?
    public var url: String?
    public var abstractText: String?
    public var firewallClass: CitationFirewallClass
    public var firewallAuditNote: String
    public var attachedPDFPath: String?
    public var citedByKeys: [String]
    public var referencesKeys: [String]

    public init(
        citeKey: String,
        kind: BibEntryKind = .article,
        title: String,
        authors: [BibAuthor],
        year: Int? = nil,
        venue: String = "",
        publisher: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        pages: String? = nil,
        doi: String? = nil,
        arxivID: String? = nil,
        pmid: String? = nil,
        url: String? = nil,
        abstractText: String? = nil,
        firewallClass: CitationFirewallClass = .unverified,
        firewallAuditNote: String = "",
        attachedPDFPath: String? = nil,
        citedByKeys: [String] = [],
        referencesKeys: [String] = []
    ) {
        self.citeKey = citeKey
        self.kind = kind
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.publisher = publisher
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.doi = doi
        self.arxivID = arxivID
        self.pmid = pmid
        self.url = url
        self.abstractText = abstractText
        self.firewallClass = firewallClass
        self.firewallAuditNote = firewallAuditNote
        self.attachedPDFPath = attachedPDFPath
        self.citedByKeys = citedByKeys
        self.referencesKeys = referencesKeys
    }

    public var firstAuthorFamily: String {
        authors.first?.familyName ?? "Unknown"
    }
}

public enum CitationFormatStyle: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case apa7 = "APA 7th"
    case ieee = "IEEE"
    case acm = "ACM"
    case nature = "Nature"
    case vancouver = "Vancouver"

    public var id: String { rawValue }
}

public struct DuplicateReferenceCandidate: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(primaryCiteKey)<->\(duplicateCiteKey)" }
    public let primaryCiteKey: String
    public let duplicateCiteKey: String
    public let titleJaroWinkler: Double
    public let exactDOIMatch: Bool
    public let reason: String

    public init(
        primaryCiteKey: String,
        duplicateCiteKey: String,
        titleJaroWinkler: Double,
        exactDOIMatch: Bool,
        reason: String
    ) {
        self.primaryCiteKey = primaryCiteKey
        self.duplicateCiteKey = duplicateCiteKey
        self.titleJaroWinkler = titleJaroWinkler
        self.exactDOIMatch = exactDOIMatch
        self.reason = reason
    }
}
