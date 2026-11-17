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

public enum StoredFirewallVerdictFreshness: Sendable, Equatable {
    case valid(firewallClass: CitationFirewallClass, source: String, fetchedAtUTC: String)
    case expired(previousClass: CitationFirewallClass, source: String, fetchedAtUTC: String)
    case missingProvenance
}

public struct BibEntryParseError: Sendable, Codable, Hashable, Equatable {
    public let startLine: Int
    public let line: Int
    public let message: String

    public init(startLine: Int, line: Int, message: String) {
        self.startLine = startLine
        self.line = line
        self.message = message
    }
}

public struct BibliographyEntry: Sendable, Codable, Hashable, Identifiable {
    public static let validVerdictTTLSeconds: TimeInterval = 30 * 86_400
    public static let notFoundVerdictTTLSeconds: TimeInterval = 86_400

    public var id: String { citeKey }
    public let citeKey: String
    public var kind: BibEntryKind
    public var title: String
    public var authors: [BibAuthor]
    public var authorsTruncated: Bool
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
    public var crossref: String?
    public var parseError: Bool
    public var parseErrorInfo: BibEntryParseError?
    public var firewallClass: CitationFirewallClass
    public var firewallAuditNote: String
    public var firewallVerifiedSource: String?
    public var firewallVerifiedAtUTC: String?
    public var untrustedDeclaredFirewallClass: String?
    public var untrustedDeclaredFirewallNote: String?
    public var ignoredNonArXivEprint: String?
    public var attachedPDFPath: String?
    public var citedByKeys: [String]
    public var referencesKeys: [String]

    public init(
        citeKey: String,
        kind: BibEntryKind = .article,
        title: String,
        authors: [BibAuthor],
        authorsTruncated: Bool = false,
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
        crossref: String? = nil,
        parseError: Bool = false,
        parseErrorInfo: BibEntryParseError? = nil,
        firewallClass: CitationFirewallClass = .unverified,
        firewallAuditNote: String = "",
        firewallVerifiedSource: String? = nil,
        firewallVerifiedAtUTC: String? = nil,
        untrustedDeclaredFirewallClass: String? = nil,
        untrustedDeclaredFirewallNote: String? = nil,
        ignoredNonArXivEprint: String? = nil,
        attachedPDFPath: String? = nil,
        citedByKeys: [String] = [],
        referencesKeys: [String] = []
    ) {
        self.citeKey = citeKey
        self.kind = kind
        self.title = title
        self.authors = authors
        self.authorsTruncated = authorsTruncated
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
        self.crossref = crossref
        self.parseError = parseError
        self.parseErrorInfo = parseErrorInfo
        self.firewallClass = firewallClass
        self.firewallAuditNote = firewallAuditNote
        self.firewallVerifiedSource = firewallVerifiedSource
        self.firewallVerifiedAtUTC = firewallVerifiedAtUTC
        self.untrustedDeclaredFirewallClass = untrustedDeclaredFirewallClass
        self.untrustedDeclaredFirewallNote = untrustedDeclaredFirewallNote
        self.ignoredNonArXivEprint = ignoredNonArXivEprint
        self.attachedPDFPath = attachedPDFPath
        self.citedByKeys = citedByKeys
        self.referencesKeys = referencesKeys
    }

    public var firstAuthorFamily: String {
        authors.first?.familyName ?? "Unknown"
    }

    public static func formatUTCDay(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            c.year ?? 1970,
            c.month ?? 1,
            c.day ?? 1
        )
    }

    public static func parseUTCDayStart(_ rawDay: String) -> Date? {
        let trimmed = rawDay.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(trimmed)
        guard chars.count == 10,
              chars[4] == "-",
              chars[7] == "-",
              chars[0...3].allSatisfy(\.isNumber),
              chars[5...6].allSatisfy(\.isNumber),
              chars[8...9].allSatisfy(\.isNumber),
              let year = Int(String(chars[0...3])),
              let month = Int(String(chars[5...6])),
              let day = Int(String(chars[8...9]))
        else {
            return nil
        }
        let utc = TimeZone(secondsFromGMT: 0)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let comps = DateComponents(
            calendar: cal,
            timeZone: utc,
            year: year,
            month: month,
            day: day,
            hour: 0,
            minute: 0,
            second: 0
        )
        guard comps.isValidDate(in: cal) else { return nil }
        return cal.date(from: comps)
    }

    public static func expiredVerdictNotice(fetchedAtUTC: String, language: ScholarLanguage) -> String {
        switch language {
        case .en:
            return "Verdict was fetched on \(fetchedAtUTC) and has expired; re-verification is required."
        case .zhHans:
            return "结论是 \(fetchedAtUTC) 取得的，已过期，需要重新核查。"
        }
    }

    public func evaluateFirewallFreshness(at referenceDate: Date) -> StoredFirewallVerdictFreshness {
        guard firewallClass != .unverified else {
            return .missingProvenance
        }
        guard let source = firewallVerifiedSource?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty,
              let dayStr = firewallVerifiedAtUTC?.trimmingCharacters(in: .whitespacesAndNewlines),
              let dayStart = Self.parseUTCDayStart(dayStr)
        else {
            return .missingProvenance
        }
        let ttl = (firewallClass == .notFound) ? Self.notFoundVerdictTTLSeconds : Self.validVerdictTTLSeconds
        let age = referenceDate.timeIntervalSince(dayStart)
        if age > ttl {
            return .expired(previousClass: firewallClass, source: source, fetchedAtUTC: dayStr)
        }
        return .valid(firewallClass: firewallClass, source: source, fetchedAtUTC: dayStr)
    }

    /// Returns a display/UI firewall class that never treats expired or sourceless `VERIFIED` (or expired verdicts) as verified/current.
    public func trustedFirewallClass(at referenceDate: Date = Date()) -> CitationFirewallClass {
        switch evaluateFirewallFreshness(at: referenceDate) {
        case .valid(let cls, _, _):
            return cls
        case .expired:
            return .unverified
        case .missingProvenance:
            if firewallClass == .verified {
                return .unverified
            }
            return firewallClass
        }
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
