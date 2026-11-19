import Foundation
import ScholarModels

// MARK: - Public Registry Work Record (M3 S77)

public struct RegistryWorkAuthor: Sendable, Codable, Hashable {
    public let givenName: String?
    public let familyName: String?
    public let name: String?
    public let isCorporate: Bool

    public init(
        givenName: String? = nil,
        familyName: String? = nil,
        name: String? = nil,
        isCorporate: Bool = false
    ) {
        self.givenName = givenName
        self.familyName = familyName
        self.name = name
        self.isCorporate = isCorporate
    }

    public var displayName: String {
        if isCorporate {
            return name ?? familyName ?? ""
        }
        let fam = familyName ?? ""
        if let giv = givenName, !giv.isEmpty {
            return fam.isEmpty ? giv : "\(giv) \(fam)"
        }
        return fam.isEmpty ? (name ?? "") : fam
    }

    private enum CodingKeys: String, CodingKey {
        case givenName
        case familyName
        case name
        case isCorporate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.givenName = try c.decodeIfPresent(String.self, forKey: .givenName)
        self.familyName = try c.decodeIfPresent(String.self, forKey: .familyName)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.isCorporate = try c.decodeIfPresent(Bool.self, forKey: .isCorporate) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(givenName, forKey: .givenName)
        try c.encodeIfPresent(familyName, forKey: .familyName)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(isCorporate, forKey: .isCorporate)
    }
}

public struct RegistryPublicationDate: Sendable, Codable, Hashable {
    public let year: Int
    public let month: Int?
    public let day: Int?
    public let raw: String?

    public init(
        year: Int,
        month: Int? = nil,
        day: Int? = nil,
        raw: String? = nil
    ) {
        self.year = year
        self.month = month
        self.day = day
        self.raw = raw
    }

    public var isoDateString: String {
        if let month, (1...12).contains(month) {
            if let day, (1...31).contains(day) {
                return String(format: "%04d-%02d-%02d", year, month, day)
            }
            return String(format: "%04d-%02d", year, month)
        }
        return String(format: "%04d", year)
    }

    private enum CodingKeys: String, CodingKey {
        case year
        case month
        case day
        case raw
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.year = try c.decode(Int.self, forKey: .year)
        self.month = try c.decodeIfPresent(Int.self, forKey: .month)
        self.day = try c.decodeIfPresent(Int.self, forKey: .day)
        self.raw = try c.decodeIfPresent(String.self, forKey: .raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(year, forKey: .year)
        try c.encodeIfPresent(month, forKey: .month)
        try c.encodeIfPresent(day, forKey: .day)
        try c.encodeIfPresent(raw, forKey: .raw)
    }
}

public struct RegistryPublicationDates: Sendable, Codable, Hashable {
    public let publishedPrint: RegistryPublicationDate?
    public let publishedOnline: RegistryPublicationDate?
    public let issued: RegistryPublicationDate?

    public init(
        publishedPrint: RegistryPublicationDate? = nil,
        publishedOnline: RegistryPublicationDate? = nil,
        issued: RegistryPublicationDate? = nil
    ) {
        self.publishedPrint = publishedPrint
        self.publishedOnline = publishedOnline
        self.issued = issued
    }

    public var allYears: [Int] {
        var years: [Int] = []
        for candidate in [publishedPrint?.year, publishedOnline?.year, issued?.year] {
            if let yr = candidate, !years.contains(yr) {
                years.append(yr)
            }
        }
        return years
    }

    private enum CodingKeys: String, CodingKey {
        case publishedPrint = "published-print"
        case publishedOnline = "published-online"
        case issued = "issued"
    }

    private enum AlternateKeys: String, CodingKey {
        case publishedPrint
        case publishedOnline
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let alt = try decoder.container(keyedBy: AlternateKeys.self)
        self.publishedPrint = try c.decodeIfPresent(RegistryPublicationDate.self, forKey: .publishedPrint)
            ?? (try alt.decodeIfPresent(RegistryPublicationDate.self, forKey: .publishedPrint))
        self.publishedOnline = try c.decodeIfPresent(RegistryPublicationDate.self, forKey: .publishedOnline)
            ?? (try alt.decodeIfPresent(RegistryPublicationDate.self, forKey: .publishedOnline))
        self.issued = try c.decodeIfPresent(RegistryPublicationDate.self, forKey: .issued)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let publishedPrint {
            try c.encode(publishedPrint, forKey: .publishedPrint)
        } else {
            try c.encodeNil(forKey: .publishedPrint)
        }
        if let publishedOnline {
            try c.encode(publishedOnline, forKey: .publishedOnline)
        } else {
            try c.encodeNil(forKey: .publishedOnline)
        }
        if let issued {
            try c.encode(issued, forKey: .issued)
        } else {
            try c.encodeNil(forKey: .issued)
        }
    }
}

public struct RegistryWorkRecord: Sendable, Codable, Hashable {
    public let source: String
    public let requestURL: String
    public let fetchedAt: String
    public let origin: CitationVerdictSourceOrigin
    public let workType: String?
    public let title: String
    public let subtitle: String?
    public let authors: [RegistryWorkAuthor]
    public let publicationDates: RegistryPublicationDates
    public let containerTitle: String?
    public let shortContainerTitle: String?
    public let volume: String?
    public let issue: String?
    public let pages: String?
    public let publisher: String?
    public let doi: String?
    public let arxivID: String?
    public let pmid: String?
    public let primaryCategory: String?

    public init(
        source: String,
        requestURL: String,
        fetchedAt: String,
        origin: CitationVerdictSourceOrigin,
        workType: String? = nil,
        title: String,
        subtitle: String? = nil,
        authors: [RegistryWorkAuthor] = [],
        publicationDates: RegistryPublicationDates = RegistryPublicationDates(),
        containerTitle: String? = nil,
        shortContainerTitle: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        pages: String? = nil,
        publisher: String? = nil,
        doi: String? = nil,
        arxivID: String? = nil,
        pmid: String? = nil,
        primaryCategory: String? = nil
    ) {
        self.source = source
        self.requestURL = requestURL
        self.fetchedAt = fetchedAt
        self.origin = origin
        self.workType = workType
        self.title = title
        self.subtitle = subtitle
        self.authors = authors
        self.publicationDates = publicationDates
        self.containerTitle = containerTitle
        self.shortContainerTitle = shortContainerTitle
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.publisher = publisher
        self.doi = doi
        self.arxivID = arxivID
        self.pmid = pmid
        self.primaryCategory = primaryCategory
    }

    public var publicationYears: [Int] {
        publicationDates.allYears
    }

    public var fullTitle: String {
        guard let sub = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sub.isEmpty
        else {
            return title
        }
        let normTitle = title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let normSub = sub.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if normTitle.contains(normSub) {
            return title
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmedTitle.last, [":", "?", "!", "—", "–"].contains(last) {
            return "\(trimmedTitle) \(sub)"
        }
        return "\(trimmedTitle): \(sub)"
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case requestURL
        case fetchedAt
        case origin
        case workType
        case title
        case subtitle
        case authors
        case publicationDates
        case containerTitle
        case shortContainerTitle
        case volume
        case issue
        case pages
        case publisher
        case doi
        case arxivID
        case pmid
        case primaryCategory
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        self.requestURL = try c.decodeIfPresent(String.self, forKey: .requestURL) ?? ""
        self.fetchedAt = try c.decodeIfPresent(String.self, forKey: .fetchedAt) ?? ""
        self.origin = try c.decodeIfPresent(CitationVerdictSourceOrigin.self, forKey: .origin) ?? .network
        self.workType = try c.decodeIfPresent(String.self, forKey: .workType)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        self.authors = try c.decodeIfPresent([RegistryWorkAuthor].self, forKey: .authors) ?? []
        self.publicationDates = try c.decodeIfPresent(RegistryPublicationDates.self, forKey: .publicationDates)
            ?? RegistryPublicationDates()
        self.containerTitle = try c.decodeIfPresent(String.self, forKey: .containerTitle)
        self.shortContainerTitle = try c.decodeIfPresent(String.self, forKey: .shortContainerTitle)
        self.volume = try c.decodeIfPresent(String.self, forKey: .volume)
        self.issue = try c.decodeIfPresent(String.self, forKey: .issue)
        self.pages = try c.decodeIfPresent(String.self, forKey: .pages)
        self.publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        self.doi = try c.decodeIfPresent(String.self, forKey: .doi)
        self.arxivID = try c.decodeIfPresent(String.self, forKey: .arxivID)
        self.pmid = try c.decodeIfPresent(String.self, forKey: .pmid)
        self.primaryCategory = try c.decodeIfPresent(String.self, forKey: .primaryCategory)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(requestURL, forKey: .requestURL)
        try c.encode(fetchedAt, forKey: .fetchedAt)
        try c.encode(origin, forKey: .origin)
        try Self.encodeOrNil(workType, forKey: .workType, in: &c)
        try c.encode(title, forKey: .title)
        try Self.encodeOrNil(subtitle, forKey: .subtitle, in: &c)
        try c.encode(authors, forKey: .authors)
        try c.encode(publicationDates, forKey: .publicationDates)
        try Self.encodeOrNil(containerTitle, forKey: .containerTitle, in: &c)
        try Self.encodeOrNil(shortContainerTitle, forKey: .shortContainerTitle, in: &c)
        try Self.encodeOrNil(volume, forKey: .volume, in: &c)
        try Self.encodeOrNil(issue, forKey: .issue, in: &c)
        try Self.encodeOrNil(pages, forKey: .pages, in: &c)
        try Self.encodeOrNil(publisher, forKey: .publisher, in: &c)
        try Self.encodeOrNil(doi, forKey: .doi, in: &c)
        try Self.encodeOrNil(arxivID, forKey: .arxivID, in: &c)
        try Self.encodeOrNil(pmid, forKey: .pmid, in: &c)
        try c.encodeIfPresent(primaryCategory, forKey: .primaryCategory)
    }

    private static func encodeOrNil<T: Encodable>(
        _ value: T?,
        forKey key: CodingKeys,
        in container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}
