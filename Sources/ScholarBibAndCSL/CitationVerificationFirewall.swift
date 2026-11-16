import Foundation
import ScholarModels

// MARK: - Firewall Diagnostic Codes, Entry Verdicts & Library Audit Reports

public enum FirewallFindingCode: String, Sendable, Codable, Hashable, CaseIterable {
    case validCanonicalDOI = "FW_VALID_DOI"
    case validArXivIdentifier = "FW_VALID_ARXIV"
    case validPubMedIdentifier = "FW_VALID_PMID"
    case validORCIDChecksum = "FW_VALID_ORCID"
    case validISSNChecksum = "FW_VALID_ISSN"
    case invalidDOISyntax = "FW_INVALID_DOI_SYNTAX"
    case invalidArXivCalendarBounds = "FW_INVALID_ARXIV_CALENDAR"
    case invalidPMIDBounds = "FW_INVALID_PMID"
    case invalidORCIDChecksum = "FW_INVALID_ORCID_CHECKSUM"
    case invalidISSNChecksum = "FW_INVALID_ISSN_CHECKSUM"
    case blockedPlaceholderSentinel = "FW_BLOCKED_SENTINEL"
    case blockedRetractedWork = "FW_BLOCKED_RETRACTED"
    case blockedHallucinatedMetadata = "FW_BLOCKED_HALLUCINATED"
    case metadataDriftDetected = "FW_METADATA_DRIFT"
    case missingPersistentIdentifier = "FW_MISSING_PID"
    case implausiblePublicationYear = "FW_IMPLAUSIBLE_YEAR"
    case suspiciousAuthorList = "FW_SUSPICIOUS_AUTHORS"
    case registryVerifiedMatch = "FW_REGISTRY_VERIFIED"
    case registryLookupNotFound = "FW_REGISTRY_NOT_FOUND"
    case registryTransportUnavailable = "FW_REGISTRY_OFFLINE"
    case untrustedEmbeddedFirewallTag = "FW_UNTRUSTED_FILE_TAG"
    case ignoredNonArXivEprint = "FW_IGNORED_EPRINT"
}

/// Closed set of allowed `UNVERIFIED` reason codes defined in M1 item 1.
public enum CitationUnverifiedReasonCode: String, Sendable, Codable, Hashable, CaseIterable {
    case offline = "offline"
    case transportError = "transport_error"
    case timeout = "timeout"
    case rateLimited = "rate_limited"
    case serverError = "server_error"
    case budgetExhausted = "budget_exhausted"
    case unparseable = "unparseable"
    case ambiguous = "ambiguous"
    case registeredNoMetadata = "registered_no_metadata"
    case noMatchInSearch = "no_match_in_search"
}

/// Per-request provenance record stored in `CitationFirewallEntryVerdict.sources`.
public struct CitationVerdictSourceRecord: Sendable, Codable, Hashable {
    public let source: String
    public let url: String
    public let status: Int?
    public let fetchedAt: String
    public let origin: CitationVerdictSourceOrigin

    public init(
        source: String,
        url: String,
        status: Int?,
        fetchedAt: String,
        origin: CitationVerdictSourceOrigin
    ) {
        self.source = source
        self.url = url
        self.status = status
        self.fetchedAt = fetchedAt
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case url
        case status
        case fetchedAt
        case origin
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(url, forKey: .url)
        if let status {
            try container.encode(status, forKey: .status)
        } else {
            try container.encodeNil(forKey: .status)
        }
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(origin, forKey: .origin)
    }
}

/// Per-field discrepancy between local bibliography entry and retrieved registry metadata.
public struct CitationFieldDiscrepancy: Sendable, Codable, Hashable {
    public let field: String
    public let localValue: String
    public let remoteValue: String
    public let source: String
    public let severity: String
    public let note: String?

    public init(
        field: String,
        localValue: String,
        remoteValue: String,
        source: String,
        severity: String = "error",
        note: String? = nil
    ) {
        self.field = field
        self.localValue = localValue
        self.remoteValue = remoteValue
        self.source = source
        self.severity = severity
        self.note = note
    }
}

public struct FirewallFinding: Sendable, Codable, Hashable {
    public enum Severity: String, Sendable, Codable, Hashable {
        case pass
        case advisory
        case warning
        case criticalBlock
    }

    public let code: FirewallFindingCode
    public let severity: Severity
    public let field: String
    public let detail: String

    public init(
        code: FirewallFindingCode,
        severity: Severity,
        field: String,
        detail: String
    ) {
        self.code = code
        self.severity = severity
        self.field = field
        self.detail = detail
    }
}

public struct CitationFirewallEntryVerdict: Sendable, Codable, Hashable, Identifiable {
    public var id: String { citeKey }
    public let citeKey: String
    public let firewallClass: CitationFirewallClass
    public let insertable: Bool
    public let reasons: [String]
    public let sources: [CitationVerdictSourceRecord]
    public let fields: [CitationFieldDiscrepancy]
    public let findings: [FirewallFinding]
    public let auditNote: String
    public let auditedEntry: BibliographyEntry

    /// Convenience alias matching `insertable` (not encoded separately in JSON).
    public var allowsManuscriptInsertion: Bool { insertable }

    private enum CodingKeys: String, CodingKey {
        case citeKey
        case firewallClass
        case insertable
        case reasons
        case sources
        case fields
        case findings
        case auditNote
        case auditedEntry
    }

    public init(
        citeKey: String,
        firewallClass: CitationFirewallClass,
        insertable: Bool,
        reasons: [String] = [],
        sources: [CitationVerdictSourceRecord] = [],
        fields: [CitationFieldDiscrepancy] = [],
        findings: [FirewallFinding],
        auditNote: String,
        auditedEntry: BibliographyEntry
    ) {
        self.citeKey = citeKey
        self.firewallClass = firewallClass
        self.insertable = insertable
        self.reasons = reasons
        self.sources = sources
        self.fields = fields
        self.findings = findings
        self.auditNote = auditNote
        self.auditedEntry = auditedEntry
    }
}

public struct CitationFirewallAuditReport: Sendable, Codable, Hashable {
    public let generatedAtISO8601: String
    public let complete: Bool
    public let totalEvaluated: Int
    public let verifiedCount: Int
    public let driftCount: Int
    public let notFoundCount: Int
    public let retractedCount: Int
    public let unverifiedCount: Int
    public let unverifiedByReason: [String: Int]
    public let manuscriptInsertionAllowedCount: Int
    public let insertionPassRate: Double
    public let verdicts: [CitationFirewallEntryVerdict]
    public let auditedEntries: [BibliographyEntry]
    public let blockedCiteKeys: [String]
    public let unverifiedCiteKeys: [String]

    public init(
        generatedAtISO8601: String,
        complete: Bool? = nil,
        totalEvaluated: Int,
        verifiedCount: Int,
        driftCount: Int,
        notFoundCount: Int,
        retractedCount: Int,
        unverifiedCount: Int,
        unverifiedByReason: [String: Int] = [:],
        manuscriptInsertionAllowedCount: Int,
        insertionPassRate: Double,
        verdicts: [CitationFirewallEntryVerdict],
        auditedEntries: [BibliographyEntry],
        blockedCiteKeys: [String],
        unverifiedCiteKeys: [String]
    ) {
        self.generatedAtISO8601 = generatedAtISO8601
        self.complete = complete ?? (unverifiedCount == 0)
        self.totalEvaluated = totalEvaluated
        self.verifiedCount = verifiedCount
        self.driftCount = driftCount
        self.notFoundCount = notFoundCount
        self.retractedCount = retractedCount
        self.unverifiedCount = unverifiedCount
        self.unverifiedByReason = unverifiedByReason
        self.manuscriptInsertionAllowedCount = manuscriptInsertionAllowedCount
        self.insertionPassRate = insertionPassRate
        self.verdicts = verdicts
        self.auditedEntries = auditedEntries
        self.blockedCiteKeys = blockedKeys(from: blockedCiteKeys)
        self.unverifiedCiteKeys = unverifiedCiteKeys
    }
}

public struct ReplayAuditReportEnvelope: Encodable {
    public let mode: String = "REPLAY"
    public let replay: Bool = true
    public let report: CitationFirewallAuditReport

    public init(report: CitationFirewallAuditReport) {
        self.report = report
    }

    private enum ReplayKeys: String, CodingKey {
        case mode
        case replay
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ReplayKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(replay, forKey: .replay)
        try report.encode(to: encoder)
    }
}

public enum BibliographyVerificationMode: Sendable {
    case offline
    case online(transport: any CitationRegistrySession)
    case replay(snapshot: RegistryReplaySnapshot)
    case record(directoryURL: URL, transport: any CitationRegistrySession)
}

public struct BibliographyVerificationResult: Sendable {
    public let report: CitationFirewallAuditReport
    public let isReplay: Bool
    public let replayUsesCache: Bool
    public let performedRegistryLookup: Bool

    public init(
        report: CitationFirewallAuditReport,
        isReplay: Bool,
        replayUsesCache: Bool,
        performedRegistryLookup: Bool
    ) {
        self.report = report
        self.isReplay = isReplay
        self.replayUsesCache = replayUsesCache
        self.performedRegistryLookup = performedRegistryLookup
    }

    public func encodeAuditJSONData(sortedKeys: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if sortedKeys {
            encoder.outputFormatting = [.sortedKeys]
        }
        if isReplay {
            return try encoder.encode(ReplayAuditReportEnvelope(report: report))
        } else {
            return try encoder.encode(report)
        }
    }
}

private func blockedKeys(from keys: [String]) -> [String] { keys }

// MARK: - Cryptographic & Structural Identifier Checksum Validators (ISO DOI, arXiv, PMID, ORCID, ISSN)

public enum ScholarlyIdentifierValidator: Sendable {

    private static let legacyArXivArchives: Set<String> = [
        "acc-phys", "adap-org", "alg-geom", "ao-sci", "astro-ph", "atom-ph",
        "bayes-an", "chao-dyn", "chem-ph", "cmp-lg", "comp-gas", "cond-mat",
        "cs", "dg-ga", "funct-an", "gr-qc", "hep-ex", "hep-lat", "hep-ph",
        "hep-th", "math", "math-ph", "mtrl-th", "nlin", "nucl-ex", "nucl-th",
        "patt-sol", "physics", "plasm-ph", "q-alg", "q-bio", "quant-ph",
        "solv-int", "supr-con"
    ]

    public struct ArXivValidationResult: Sendable, Equatable {
        public let isValid: Bool
        public let canonicalBaseID: String
        public let inferredSubmissionYear: Int?
        public let inferredSubmissionMonth: Int?
        public let failureReason: String?
    }

    /// Validates ISO 26324 DOI syntax (`10.\d{4,9}/...`).
    public static func validateDOISyntax(_ rawDOI: String) -> (isValid: Bool, normalized: String, reason: String?) {
        guard let normalized = ReferenceIdentifierNormalizer.normalizeDOI(rawDOI), !normalized.isEmpty else {
            return (false, "", "Empty DOI string.")
        }

        if normalized.contains(where: \.isWhitespace) {
            return (false, normalized, "DOI must not contain whitespace characters.")
        }

        guard normalized.hasPrefix("10."),
              let slashIndex = normalized.firstIndex(of: "/") else {
            return (false, normalized, "DOI must start with ISO directory indicator '10.<registrant>/'.")
        }

        let prefixBody = String(normalized[normalized.index(normalized.startIndex, offsetBy: 3)..<slashIndex])
        let suffixBody = String(normalized[normalized.index(after: slashIndex)...])

        guard !suffixBody.isEmpty else {
            return (false, normalized, "DOI suffix after '/' is empty.")
        }

        // Support standard 4-9 digit registrant or sub-registrant `10.1002.12/...`
        let subPrefixes = prefixBody.split(separator: ".", omittingEmptySubsequences: false)
        guard let rootRegistrant = subPrefixes.first,
              rootRegistrant.count >= 4 && rootRegistrant.count <= 9,
              rootRegistrant.allSatisfy(\.isNumber),
              subPrefixes.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return (false, normalized, "DOI registrant code '\(prefixBody)' violates ISO 26324 '10.\\d{4,9}' bounds.")
        }

        // Verify suffix contains printable visible ASCII/URI characters
        let validSuffixChars = suffixBody.allSatisfy { ch in
            ch.isASCII && !ch.isNewline && ch != "\"" && ch != "{" && ch != "}" && ch != "\\"
        }
        guard validSuffixChars else {
            return (false, normalized, "DOI suffix '\(suffixBody)' contains illegal control or brace characters.")
        }

        return (true, normalized, nil)
    }

    /// Validates modern (`YYMM.NNNN` / `YYMM.NNNNN[vK]`) and legacy (`archive/YYMMNNN[vK]`) arXiv IDs with strict calendar bounds.
    public static func validateArXivID(_ rawArXiv: String, maxYear: Int = 2035) -> ArXivValidationResult {
        guard let cleanedWithVer = ReferenceIdentifierNormalizer.normalizeArXivID(rawArXiv, stripVersion: false),
              !cleanedWithVer.isEmpty else {
            return ArXivValidationResult(
                isValid: false,
                canonicalBaseID: "",
                inferredSubmissionYear: nil,
                inferredSubmissionMonth: nil,
                failureReason: "Empty arXiv identifier."
            )
        }

        let baseID = ReferenceIdentifierNormalizer.normalizeArXivID(cleanedWithVer, stripVersion: true) ?? cleanedWithVer

        // Check version suffix if present (`v1`, `v2`, ...; `v0` is invalid!)
        if cleanedWithVer != baseID {
            guard let ver = ReferenceIdentifierNormalizer.extractArXivVersion(cleanedWithVer), ver >= 1, ver <= 99 else {
                return ArXivValidationResult(
                    isValid: false,
                    canonicalBaseID: baseID,
                    inferredSubmissionYear: nil,
                    inferredSubmissionMonth: nil,
                    failureReason: "Malformed arXiv version suffix in '\(cleanedWithVer)'."
                )
            }
        }

        // Case 1: Legacy pre-April-2007 format `hep-th/9901001` or `math.GT/0309136`
        if baseID.contains("/") {
            let slashParts = baseID.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard slashParts.count == 2 else {
                return ArXivValidationResult(
                    isValid: false,
                    canonicalBaseID: baseID,
                    inferredSubmissionYear: nil,
                    inferredSubmissionMonth: nil,
                    failureReason: "Legacy arXiv ID '\(baseID)' must have single 'archive/YYMMNNN' slash."
                )
            }
            let archiveRoot = slashParts[0].split(separator: ".").first.map(String.init) ?? slashParts[0]
            guard legacyArXivArchives.contains(archiveRoot) else {
                return ArXivValidationResult(
                    isValid: false,
                    canonicalBaseID: baseID,
                    inferredSubmissionYear: nil,
                    inferredSubmissionMonth: nil,
                    failureReason: "Unrecognized legacy arXiv archive category '\(slashParts[0])'."
                )
            }
            let code = slashParts[1]
            guard code.count == 7, code.allSatisfy(\.isNumber) else {
                return ArXivValidationResult(
                    isValid: false,
                    canonicalBaseID: baseID,
                    inferredSubmissionYear: nil,
                    inferredSubmissionMonth: nil,
                    failureReason: "Legacy arXiv numeric code '\(code)' must be exactly 7 digits (YYMMNNN)."
                )
            }
            let yy = Int(code.prefix(2)) ?? -1
            let mm = Int(code.dropFirst(2).prefix(2)) ?? -1
            let seq = Int(code.suffix(3)) ?? 0
            guard (1...12).contains(mm), seq >= 1 else {
                return ArXivValidationResult(
                    isValid: false,
                    canonicalBaseID: baseID,
                    inferredSubmissionYear: nil,
                    inferredSubmissionMonth: nil,
                    failureReason: "Impossible calendar month \(mm) or zero sequence in legacy arXiv ID '\(baseID)'."
                )
            }
            let fullYear = (yy >= 91) ? (1900 + yy) : (2000 + yy)
            let yymmCombined = fullYear * 100 + mm
            // Legacy arXiv operated from 1991-08 through 2007-03
            guard yymmCombined >= 199108 && yymmCombined <= 200703 else {
                return ArXivValidationResult(
                    isValid: false,
                    canonicalBaseID: baseID,
                    inferredSubmissionYear: fullYear,
                    inferredSubmissionMonth: mm,
                    failureReason: "Legacy arXiv ID '\(baseID)' date \(fullYear)-\(String(format: "%02d", mm)) falls outside 1991-08..2007-03."
                )
            }
            return ArXivValidationResult(
                isValid: true,
                canonicalBaseID: baseID,
                inferredSubmissionYear: fullYear,
                inferredSubmissionMonth: mm,
                failureReason: nil
            )
        }

        // Case 2: Modern post-April-2007 format `YYMM.NNNN` (0704..1412) or `YYMM.NNNNN` (1501+)
        let dotParts = baseID.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard dotParts.count == 2 else {
            return ArXivValidationResult(
                isValid: false,
                canonicalBaseID: baseID,
                inferredSubmissionYear: nil,
                inferredSubmissionMonth: nil,
                failureReason: "Modern arXiv ID '\(baseID)' must match 'YYMM.NNNN(N)'."
            )
        }

        let yymmPart = dotParts[0]
        let seqPart = dotParts[1]

        guard yymmPart.count == 4, yymmPart.allSatisfy(\.isNumber),
              (seqPart.count == 4 || seqPart.count == 5), seqPart.allSatisfy(\.isNumber) else {
            return ArXivValidationResult(
                isValid: false,
                canonicalBaseID: baseID,
                inferredSubmissionYear: nil,
                inferredSubmissionMonth: nil,
                failureReason: "arXiv ID '\(baseID)' has invalid digit widths in YYMM or sequence number."
            )
        }

        let yy = Int(yymmPart.prefix(2)) ?? -1
        let mm = Int(yymmPart.suffix(2)) ?? -1
        let seqNumber = Int(seqPart) ?? 0

        guard (1...12).contains(mm) else {
            return ArXivValidationResult(
                isValid: false,
                canonicalBaseID: baseID,
                inferredSubmissionYear: 2000 + max(0, yy),
                inferredSubmissionMonth: mm,
                failureReason: "Impossible calendar month '\(String(format: "%02d", mm))' in arXiv:\(baseID) (must be 01..12)."
            )
        }

        guard seqNumber >= 1 else {
            return ArXivValidationResult(
                isValid: false,
                canonicalBaseID: baseID,
                inferredSubmissionYear: 2000 + yy,
                inferredSubmissionMonth: mm,
                failureReason: "Zero sequence number '\(seqPart)' in arXiv:\(baseID) is a placeholder sentinel."
            )
        }

        let fullYear = 2000 + yy
        let yymmOrdinal = fullYear * 100 + mm

        // Modern YYMM.NNNN began in April 2007 (0704)
        guard yymmOrdinal >= 200704 else {
            return ArXivValidationResult(
                isValid: false,
                canonicalBaseID: baseID,
                inferredSubmissionYear: fullYear,
                inferredSubmissionMonth: mm,
                failureReason: "Modern arXiv format did not exist prior to April 2007 (got \(yymmPart))."
            )
        }

        guard fullYear <= maxYear else {
            return ArXivValidationResult(
                isValid: false,
                canonicalBaseID: baseID,
                inferredSubmissionYear: fullYear,
                inferredSubmissionMonth: mm,
                failureReason: "arXiv year \(fullYear) in arXiv:\(baseID) exceeds maximum plausible year \(maxYear)."
            )
        }

        // Between 2007-04 and 2014-12 arXiv used 4-digit sequence numbers; from 2015-01 onward 5-digit sequence numbers
        if yymmOrdinal <= 201412 && seqPart.count != 4 {
            return ArXivValidationResult(
                isValid: false,
                canonicalBaseID: baseID,
                inferredSubmissionYear: fullYear,
                inferredSubmissionMonth: mm,
                failureReason: "Pre-2015 arXiv ID '\(baseID)' must have a 4-digit sequence number (got \(seqPart.count) digits)."
            )
        }
        if yymmOrdinal >= 201501 && seqPart.count != 5 {
            return ArXivValidationResult(
                isValid: false,
                canonicalBaseID: baseID,
                inferredSubmissionYear: fullYear,
                inferredSubmissionMonth: mm,
                failureReason: "Post-2015 arXiv ID '\(baseID)' must have a 5-digit sequence number (got \(seqPart.count) digits)."
            )
        }

        return ArXivValidationResult(
            isValid: true,
            canonicalBaseID: baseID,
            inferredSubmissionYear: fullYear,
            inferredSubmissionMonth: mm,
            failureReason: nil
        )
    }

    /// Validates NCBI PubMed numeric PMID bounds (`1 ... 99_999_999`, 1-8 digits, no leading zero padding).
    public static func validatePMID(_ rawPMID: String) -> (isValid: Bool, normalized: String, reason: String?) {
        var trimmed = rawPMID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("pmid:") {
            trimmed = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else {
            return (false, "", "Empty PMID.")
        }
        guard trimmed.allSatisfy(\.isNumber) else {
            return (false, trimmed, "PMID '\(trimmed)' contains non-numeric characters.")
        }
        guard !trimmed.hasPrefix("0") else {
            return (false, trimmed, "PMID '\(trimmed)' has invalid leading zero(s).")
        }
        guard let numeric = Int(trimmed), (1...99_999_999).contains(numeric) else {
            return (false, trimmed, "PMID '\(trimmed)' falls outside valid NLM numeric range 1..99,999,999.")
        }
        return (true, trimmed, nil)
    }

    /// Verifies ORCID identifier checksum per ISO/IEC 7064:2003, MOD 11-2.
    public static func validateORCID(_ rawORCID: String) -> (isValid: Bool, formatted: String, reason: String?) {
        let stripped = rawORCID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://orcid.org/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "http://orcid.org/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "orcid:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        let compact = stripped.filter { $0 != "-" }
        guard compact.count == 16 else {
            return (false, stripped, "ORCID '\(rawORCID)' must contain 16 characters (15 digits + Mod 11-2 check character).")
        }

        let chars = Array(compact)
        var runningTotal = 0
        for i in 0..<15 {
            guard let digit = chars[i].wholeNumberValue else {
                return (false, stripped, "ORCID base position \(i + 1) ('\(chars[i])') is not a decimal digit.")
            }
            runningTotal = (runningTotal + digit) * 2
        }

        let remainder = runningTotal % 11
        let checkValue = (12 - remainder) % 11
        let expectedCheckChar: Character = (checkValue == 10) ? "X" : Character(String(checkValue))
        let actualCheckChar = chars[15]

        let formatted = "\(String(chars[0..<4]))-\(String(chars[4..<8]))-\(String(chars[8..<12]))-\(String(chars[12..<16]))"
        guard actualCheckChar == expectedCheckChar else {
            return (
                false,
                formatted,
                "ORCID '\(formatted)' failed ISO 7064 Mod 11-2 checksum (expected '\(expectedCheckChar)', got '\(actualCheckChar)')."
            )
        }
        return (true, formatted, nil)
    }

    /// Verifies 8-character ISSN checksum per ISO 3297 Mod 11 (`XXXX-XXXX`).
    public static func validateISSN(_ rawISSN: String) -> (isValid: Bool, formatted: String, reason: String?) {
        let compact = rawISSN
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ISSN", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { $0 != "-" && $0 != " " }

        guard compact.count == 8 else {
            return (false, rawISSN, "ISSN '\(rawISSN)' must contain exactly 8 characters.")
        }

        let chars = Array(compact)
        var weightedSum = 0
        for i in 0..<7 {
            guard let digit = chars[i].wholeNumberValue else {
                return (false, rawISSN, "ISSN digit \(i + 1) ('\(chars[i])') is non-numeric.")
            }
            weightedSum += digit * (8 - i)
        }

        let remainder = weightedSum % 11
        let checkVal = (11 - remainder) % 11
        let expected: Character = (checkVal == 10) ? "X" : Character(String(checkVal))
        let formatted = "\(String(chars[0..<4]))-\(String(chars[4..<8]))"

        guard chars[7] == expected else {
            return (
                false,
                formatted,
                "ISSN '\(formatted)' failed ISO 3297 Mod 11 checksum (expected '\(expected)', got '\(chars[7])')."
            )
        }
        return (true, formatted, nil)
    }
}

// MARK: - 5-Class Citation Verification Firewall Engine

public struct CitationVerificationFirewall: Sendable {

    /// Built-in hint list of retracted DOIs (built-in list, incomplete; it does NOT substitute for an online retraction check).
    public static let defaultRetractedDOIs: Set<String> = [
        "10.1016/s0140-6736(97)11096-0", // Wakefield et al. 1998 (Lancet retracted)
        "10.1016/s0140-6736(20)31180-6", // Mehra et al. 2020 Surgisphere Lancet (retracted)
        "10.1056/nejmoa2007621",         // Mehra et al. 2020 Surgisphere NEJM (retracted)
        "10.1038/nature12968",           // Obokata et al. 2014 STAP Nature (retracted)
        "10.1038/nature12969",           // Obokata et al. 2014 STAP Nature (retracted)
        "10.1126/science.287.5455.1022", // Schon et al. 2000 Science (retracted)
        "10.1038/s41586-020-2801-z",     // Snider et al. 2020 CSH superconductor Nature (retracted)
        "10.1038/s41586-023-05742-0"     // Dasenbrock-Gammon et al. 2023 LuH superconductor (retracted)
    ]

    /// Known LLM hallucination / documentation placeholder DOIs that must always be blocked.
    public static let defaultSentinelDOIs: Set<String> = [
        "10.1000/xyz123",
        "10.1000/182",
        "10.1000/123456",
        "10.1000/test",
        "10.5555/fake",
        "10.5555/placeholder",
        "10.5555/12345678",
        "10.5555/00000000",
        "10.1234/5678",
        "10.1234/example",
        "10.1234/fake",
        "10.9999/fake",
        "10.0000/0000"
    ]

    private static let sentinelDOIRegistrantPrefixes: Set<String> = [
        "10.0000/",
        "10.1000/",
        "10.1234/",
        "10.9999/"
    ]

    private static let sentinelTitlePhrases: [String] = [
        "lorem ipsum",
        "dolor sit amet",
        "insert title here",
        "placeholder title",
        "placeholder paper",
        "placeholder citation",
        "hallucinated paper",
        "hallucinated reference",
        "fake citation",
        "citation needed",
        "example article title",
        "sample paper title"
    ]

    private static let suspiciousFakeAuthorFullNames: Set<String> = [
        "john doe",
        "jane doe",
        "first last",
        "author one",
        "author two",
        "test author",
        "placeholder author",
        "fake author"
    ]

    public let retractedDOIs: Set<String>
    public let sentinelDOIs: Set<String>
    public let maxAllowedPublicationYear: Int
    public let minAllowedPublicationYear: Int
    public let rateLimiter: RegistryRateLimiter?
    public let openAlexBudgetScope: OpenAlexSearchBudgetScope?
    public let cache: RegistryResponseCache?
    public let requestObserver: RegistryRequestObserver?
    public let clock: any RegistryClock

    public init(
        includeBuiltInRetractedDOIs: Bool = true,
        additionalRetractedDOIs: Set<String> = [],
        additionalSentinelDOIs: Set<String> = [],
        minAllowedPublicationYear: Int = 1450,
        maxAllowedPublicationYear: Int = 2030,
        rateLimiter: RegistryRateLimiter? = nil,
        openAlexBudgetScope: OpenAlexSearchBudgetScope? = nil,
        cache: RegistryResponseCache? = nil,
        requestObserver: RegistryRequestObserver? = nil,
        clock: any RegistryClock = SystemRegistryClock()
    ) {
        let baseRetracted = includeBuiltInRetractedDOIs ? Self.defaultRetractedDOIs : []
        self.retractedDOIs = baseRetracted.union(additionalRetractedDOIs.map { $0.lowercased() })
        self.sentinelDOIs = Self.defaultSentinelDOIs.union(additionalSentinelDOIs.map { $0.lowercased() })
        self.minAllowedPublicationYear = minAllowedPublicationYear
        self.maxAllowedPublicationYear = maxAllowedPublicationYear
        self.rateLimiter = rateLimiter
        self.openAlexBudgetScope = openAlexBudgetScope
        self.cache = cache
        self.requestObserver = requestObserver
        self.clock = clock
    }

    // MARK: - Offline Deterministic Structural & Built-in Retraction Hint Evaluation

    /// Evaluates `entry` offline without querying external registries.
    /// Per M1 item 4 (S41), offline evaluation ONLY returns `.notFound` (`invalid_identifier`),
    /// `.retracted` (`retracted_builtin_list`), or `.unverified` (`offline`).
    /// Sentinel prefixes, placeholder authors, ORCID checksum failures, and year bounds emit `findings` only.
    public func evaluate(_ entry: BibliographyEntry) -> CitationFirewallEntryVerdict {
        var findings: [FirewallFinding] = []
        var hasBuiltInRetractedDOI = false
        var hasInvalidIdentifierSyntax = false
        var hasSyntacticallyValidPID = false
        var hasSyntacticallyValidDOI = false

        // 0. Record untrusted embedded x-firewall-class / x-firewall-note from .bib if present (M1 item 8 / S42)
        if let declared = nonEmpty(entry.untrustedDeclaredFirewallClass) {
            findings.append(
                FirewallFinding(
                    code: .untrustedEmbeddedFirewallTag,
                    severity: .warning,
                    field: "x-firewall-class",
                    detail: "File declared x-firewall-class '\(declared)', \(CitationAuditWording.untrustedFileClassMarker)."
                )
            )
        }
        if let declaredNote = nonEmpty(entry.untrustedDeclaredFirewallNote) {
            findings.append(
                FirewallFinding(
                    code: .untrustedEmbeddedFirewallTag,
                    severity: .warning,
                    field: "x-firewall-note",
                    detail: "File declared x-firewall-note '\(declaredNote)', \(CitationAuditWording.untrustedFileClassMarker)."
                )
            )
        }

        // 0b. Record non-arXiv eprint field ignored as identifier (S52 Rule 1)
        if let ignoredEprint = nonEmpty(entry.ignoredNonArXivEprint) {
            findings.append(
                FirewallFinding(
                    code: .ignoredNonArXivEprint,
                    severity: .advisory,
                    field: "eprint",
                    detail: "eprint field '\(ignoredEprint)' is not an arXiv identifier; not treated as an identifier."
                )
            )
        }

        // 1. Title sentinel & explicit retraction prefix hint (findings only in offline mode)
        let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTitle = trimmedTitle.lowercased()

        if trimmedTitle.isEmpty || lowerTitle == "untitled" || lowerTitle == "tbd" || lowerTitle == "todo" {
            findings.append(
                FirewallFinding(
                    code: .blockedPlaceholderSentinel,
                    severity: .warning,
                    field: "title",
                    detail: "Title '\(trimmedTitle)' is empty or an unverified placeholder."
                )
            )
        } else if Self.sentinelTitlePhrases.contains(where: { lowerTitle.contains($0) }) {
            findings.append(
                FirewallFinding(
                    code: .blockedPlaceholderSentinel,
                    severity: .warning,
                    field: "title",
                    detail: "Title '\(trimmedTitle)' matches placeholder sentinel text."
                )
            )
        } else if lowerTitle.hasPrefix("retracted:") || lowerTitle.contains("[retracted]") || lowerTitle.hasPrefix("retraction:") {
            findings.append(
                FirewallFinding(
                    code: .blockedRetractedWork,
                    severity: .warning,
                    field: "title",
                    detail: "Title carries a retraction marker ('\(trimmedTitle)') (\(CitationAuditWording.titleRetractionMarkerNotice))."
                )
            )
        }

        // 2. Author plausibility & ORCID ISO 7064 Mod 11-2 check-digit validation (findings only)
        if entry.authors.isEmpty {
            findings.append(
                FirewallFinding(
                    code: .suspiciousAuthorList,
                    severity: .advisory,
                    field: "authors",
                    detail: "Bibliography entry has an empty author list."
                )
            )
        } else {
            for author in entry.authors {
                let fullName = "\(author.givenName) \(author.familyName)"
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if Self.suspiciousFakeAuthorFullNames.contains(fullName) {
                    findings.append(
                        FirewallFinding(
                            code: .blockedPlaceholderSentinel,
                            severity: .warning,
                            field: "authors",
                            detail: "Author '\(author.description)' matches placeholder sentinel identity."
                        )
                    )
                }
                if let orcid = author.orcid, !orcid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let orcidCheck = ScholarlyIdentifierValidator.validateORCID(orcid)
                    if orcidCheck.isValid {
                        findings.append(
                            FirewallFinding(
                                code: .validORCIDChecksum,
                                severity: .pass,
                                field: "authors.orcid",
                                detail: "ORCID ISO 7064 Mod 11-2 checksum valid (\(orcidCheck.formatted))."
                            )
                        )
                    } else {
                        findings.append(
                            FirewallFinding(
                                code: .invalidORCIDChecksum,
                                severity: .warning,
                                field: "authors.orcid",
                                detail: orcidCheck.reason ?? "Invalid ORCID checksum."
                            )
                        )
                    }
                }
            }
        }

        // 3. Publication year plausibility check (findings only)
        if let year = entry.year {
            if year < minAllowedPublicationYear || year > maxAllowedPublicationYear {
                findings.append(
                    FirewallFinding(
                        code: .implausiblePublicationYear,
                        severity: .warning,
                        field: "year",
                        detail: "Publication year \(year) falls outside plausible scholarly bounds (\(minAllowedPublicationYear)..\(maxAllowedPublicationYear))."
                    )
                )
            }
        } else {
            findings.append(
                FirewallFinding(
                    code: .metadataDriftDetected,
                    severity: .advisory,
                    field: "year",
                    detail: "Missing publication year."
                )
            )
        }

        // 4. DOI syntax validation, sentinel hint & built-in offline retraction hint list lookup
        if let rawDOI = nonEmpty(entry.doi) {
            let doiCheck = ScholarlyIdentifierValidator.validateDOISyntax(rawDOI)
            if !doiCheck.isValid {
                hasInvalidIdentifierSyntax = true
                findings.append(
                    FirewallFinding(
                        code: .invalidDOISyntax,
                        severity: .criticalBlock,
                        field: "doi",
                        detail: doiCheck.reason ?? "Invalid DOI syntax."
                    )
                )
            } else {
                let normDOI = doiCheck.normalized
                if retractedDOIs.contains(normDOI) {
                    hasBuiltInRetractedDOI = true
                    hasSyntacticallyValidDOI = true
                    hasSyntacticallyValidPID = true
                    findings.append(
                        FirewallFinding(
                            code: .blockedRetractedWork,
                            severity: .criticalBlock,
                            field: "doi",
                            detail: "DOI '\(normDOI)' matched the built-in retraction hint list (\(CitationAuditWording.builtInRetractionListNotice))."
                        )
                    )
                } else if normDOI.hasPrefix("10.48550/arxiv.") {
                    let embeddedArXiv = String(normDOI.dropFirst("10.48550/arxiv.".count))
                    let arxivCheck = ScholarlyIdentifierValidator.validateArXivID(
                        embeddedArXiv,
                        maxYear: maxAllowedPublicationYear
                    )
                    if arxivCheck.isValid {
                        hasSyntacticallyValidDOI = true
                        hasSyntacticallyValidPID = true
                        findings.append(
                            FirewallFinding(
                                code: .validArXivIdentifier,
                                severity: .pass,
                                field: "doi",
                                detail: "DataCite arXiv DOI '\(normDOI)' has valid syntax."
                            )
                        )
                    } else {
                        hasInvalidIdentifierSyntax = true
                        findings.append(
                            FirewallFinding(
                                code: .invalidArXivCalendarBounds,
                                severity: .criticalBlock,
                                field: "doi",
                                detail: arxivCheck.failureReason ?? "Invalid embedded arXiv ID in DataCite DOI."
                            )
                        )
                    }
                } else {
                    hasSyntacticallyValidDOI = true
                    hasSyntacticallyValidPID = true
                    if isPlaceholderSentinelDOI(normDOI) {
                        findings.append(
                            FirewallFinding(
                                code: .blockedPlaceholderSentinel,
                                severity: .warning,
                                field: "doi",
                                detail: "DOI '\(normDOI)' uses a test/dummy/placeholder sentinel pattern."
                            )
                        )
                    } else if normDOI.hasPrefix("10.5555/") {
                        findings.append(
                            FirewallFinding(
                                code: .validCanonicalDOI,
                                severity: .warning,
                                field: "doi",
                                detail: "DOI '\(normDOI)' uses the Crossref test prefix '10.5555/', which does not resolve."
                            )
                        )
                    } else {
                        findings.append(
                            FirewallFinding(
                                code: .validCanonicalDOI,
                                severity: .pass,
                                field: "doi",
                                detail: "DOI '\(normDOI)' has valid ISO 26324 syntax."
                            )
                        )
                    }
                }
            }
        }

        // 5. arXiv identifier calendar & sequence bounds check (`2319.99999` month 19 -> NOT_FOUND `invalid_identifier` when no valid DOI)
        if let rawArXiv = nonEmpty(entry.arxivID) {
            let arxivCheck = ScholarlyIdentifierValidator.validateArXivID(
                rawArXiv,
                maxYear: maxAllowedPublicationYear
            )
            if !arxivCheck.isValid {
                if hasSyntacticallyValidDOI && !hasInvalidIdentifierSyntax {
                    findings.append(
                        FirewallFinding(
                            code: .invalidArXivCalendarBounds,
                            severity: .warning,
                            field: "arxivID",
                            detail: arxivCheck.failureReason ?? "Invalid arXiv identifier '\(rawArXiv)'."
                        )
                    )
                } else {
                    hasInvalidIdentifierSyntax = true
                    findings.append(
                        FirewallFinding(
                            code: .invalidArXivCalendarBounds,
                            severity: .criticalBlock,
                            field: "arxivID",
                            detail: arxivCheck.failureReason ?? "Invalid arXiv identifier '\(rawArXiv)'."
                        )
                    )
                }
            } else {
                hasSyntacticallyValidPID = true
                findings.append(
                    FirewallFinding(
                        code: .validArXivIdentifier,
                        severity: .pass,
                        field: "arxivID",
                        detail: "arXiv:\(arxivCheck.canonicalBaseID) has valid calendar/sequence syntax."
                    )
                )

                if let inferredYear = arxivCheck.inferredSubmissionYear, let entryYear = entry.year {
                    if entryYear < inferredYear - 1 || entryYear > inferredYear + 5 {
                        findings.append(
                            FirewallFinding(
                                code: .metadataDriftDetected,
                                severity: .warning,
                                field: "year",
                                detail: "Entry year (\(entryYear)) differs from arXiv:\(arxivCheck.canonicalBaseID) prefix year (\(inferredYear))."
                            )
                        )
                    }
                }
            }
        }

        // 6. PubMed PMID numeric bounds check
        if let rawPMID = nonEmpty(entry.pmid) {
            let pmidCheck = ScholarlyIdentifierValidator.validatePMID(rawPMID)
            if !pmidCheck.isValid {
                hasInvalidIdentifierSyntax = true
                findings.append(
                    FirewallFinding(
                        code: .invalidPMIDBounds,
                        severity: .criticalBlock,
                        field: "pmid",
                        detail: pmidCheck.reason ?? "Invalid PubMed PMID '\(rawPMID)'."
                    )
                )
            } else {
                hasSyntacticallyValidPID = true
                findings.append(
                    FirewallFinding(
                        code: .validPubMedIdentifier,
                        severity: .pass,
                        field: "pmid",
                        detail: "PMID:\(pmidCheck.normalized) has valid numeric bounds."
                    )
                )
            }
        }

        // 7. Missing venue note for journal/conference papers with a DOI
        if hasSyntacticallyValidPID
            && (entry.kind == .article || entry.kind == .inproceedings)
            && entry.venue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(
                FirewallFinding(
                    code: .metadataDriftDetected,
                    severity: .advisory,
                    field: "venue",
                    detail: "Peer-reviewed \(entry.kind.rawValue) has an identifier but is missing journal/proceedings venue."
                )
            )
        }

        // 8. Determine Offline Verdict (ONLY `.retracted`, `.notFound` on invalid syntax, or `.unverified`)
        let finalClass: CitationFirewallClass
        let reasons: [String]

        if hasBuiltInRetractedDOI {
            finalClass = .retracted
            reasons = ["retracted_builtin_list"]
        } else if hasInvalidIdentifierSyntax {
            finalClass = .notFound
            reasons = ["invalid_identifier"]
        } else {
            finalClass = .unverified
            reasons = [CitationUnverifiedReasonCode.offline.rawValue]
            if !hasSyntacticallyValidPID && nonEmpty(entry.doi) == nil {
                findings.append(
                    FirewallFinding(
                        code: .missingPersistentIdentifier,
                        severity: .warning,
                        field: "doi/arxivID/pmid",
                        detail: "No persistent identifier (DOI, arXiv ID, or PubMed PMID)."
                    )
                )
            }
        }

        var summaryNote = summarizeFindings(findings, assignedClass: finalClass)
        if finalClass == .unverified {
            summaryNote += " " + CitationAuditWording.notCheckedAgainstRegistry
        }
        var updatedEntry = entry
        updatedEntry.firewallClass = finalClass
        updatedEntry.firewallAuditNote = summaryNote
        updatedEntry.firewallVerifiedSource = nil
        updatedEntry.firewallVerifiedAtUTC = nil

        return CitationFirewallEntryVerdict(
            citeKey: entry.citeKey,
            firewallClass: finalClass,
            insertable: false,
            reasons: reasons,
            sources: [],
            fields: [],
            findings: findings,
            auditNote: summaryNote,
            auditedEntry: updatedEntry
        )
    }

    // MARK: - Batch Library Audit

    public func auditLibrary(_ entries: [BibliographyEntry]) -> CitationFirewallAuditReport {
        summarizeVerdicts(entries.map { evaluate($0) })
    }

    public func summarizeVerdicts(_ verdicts: [CitationFirewallEntryVerdict]) -> CitationFirewallAuditReport {
        let auditedEntries = verdicts.map(\.auditedEntry)

        var verifiedCount = 0
        var driftCount = 0
        var notFoundCount = 0
        var retractedCount = 0
        var unverifiedCount = 0
        var unverifiedByReason: [String: Int] = [:]
        var allowedCount = 0
        var blockedKeys: [String] = []
        var unverifiedKeys: [String] = []

        for v in verdicts {
            if v.insertable && v.firewallClass == .verified {
                allowedCount += 1
            }
            switch v.firewallClass {
            case .verified:
                verifiedCount += 1
            case .drift:
                driftCount += 1
                blockedKeys.append(v.citeKey)
            case .notFound:
                notFoundCount += 1
                blockedKeys.append(v.citeKey)
            case .retracted:
                retractedCount += 1
                blockedKeys.append(v.citeKey)
            case .unverified:
                unverifiedCount += 1
                unverifiedKeys.append(v.citeKey)
                let effectiveReasons = v.reasons.isEmpty ? [CitationUnverifiedReasonCode.offline.rawValue] : v.reasons
                for code in effectiveReasons {
                    unverifiedByReason[code, default: 0] += 1
                }
            }
        }

        let passRate = verdicts.isEmpty ? 0.0 : Double(allowedCount) / Double(verdicts.count)
        let timestamp = ISO8601DateFormatter().string(from: Date())

        return CitationFirewallAuditReport(
            generatedAtISO8601: timestamp,
            complete: unverifiedCount == 0,
            totalEvaluated: verdicts.count,
            verifiedCount: verifiedCount,
            driftCount: driftCount,
            notFoundCount: notFoundCount,
            retractedCount: retractedCount,
            unverifiedCount: unverifiedCount,
            unverifiedByReason: unverifiedByReason,
            manuscriptInsertionAllowedCount: allowedCount,
            insertionPassRate: passRate,
            verdicts: verdicts,
            auditedEntries: auditedEntries,
            blockedCiteKeys: blockedKeys,
            unverifiedCiteKeys: unverifiedKeys
        )
    }

    // MARK: - Unified Bibliography Verification Entry Point (`verify-citations`, MCP `scholar_verify_bibliography`, `diagnostics`)

    /// Single shared entry function used by CLI `verify-citations`, MCP `scholar_verify_bibliography`,
    /// CLI `diagnostics`, and MCP `scholar_lsp_diagnostics` (M1 item 8).
    public static func verifyBibliography(
        entries: [BibliographyEntry],
        mode: BibliographyVerificationMode,
        noCache: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clock: any RegistryClock = SystemRegistryClock(),
        sharedRateLimiter: RegistryRateLimiter? = nil,
        sharedStandardCache: RegistryResponseCache? = nil,
        sharedReplayExplicitCache: RegistryResponseCache? = nil,
        language: ScholarLanguage = .en,
        cacheWarningHandler: (@Sendable (String) -> Void)? = nil,
        requestObserver: RegistryRequestObserver? = nil
    ) async throws -> BibliographyVerificationResult {
        switch mode {
        case .offline:
            let firewall = CitationVerificationFirewall(clock: clock)
            let rawReport = firewall.auditLibrary(entries)
            let localized = localizingUntrustedFileTagFindings(in: rawReport, firewall: firewall, language: language)
            return BibliographyVerificationResult(
                report: localized,
                isReplay: false,
                replayUsesCache: false,
                performedRegistryLookup: false
            )

        case .online(let transport):
            let effectiveClock: any RegistryClock = (transport is RegistryReplaySession)
                ? ClosureRegistryClock.immediate
                : clock
            let limiter = sharedRateLimiter ?? RegistryRateLimiter(clock: effectiveClock)
            let budgetScope = OpenAlexSearchBudgetScope()
            let cache: RegistryResponseCache?
            if noCache || (transport is RegistryReplaySession) {
                cache = nil
            } else if let sharedStandardCache {
                cache = sharedStandardCache
            } else {
                cache = RegistryResponseCache(
                    fileURL: RegistryResponseCache.resolveDatabaseURL(environment: environment),
                    clock: clock,
                    language: language,
                    warningHandler: cacheWarningHandler
                )
            }
            let firewall = CitationVerificationFirewall(
                rateLimiter: limiter,
                openAlexBudgetScope: budgetScope,
                cache: cache,
                requestObserver: requestObserver,
                clock: clock
            )
            var verdicts: [CitationFirewallEntryVerdict] = []
            verdicts.reserveCapacity(entries.count)
            for entry in entries {
                let verdict = await firewall.verifyAgainstPublicRegistries(entry: entry, session: transport)
                verdicts.append(verdict)
            }
            let rawReport = firewall.summarizeVerdicts(verdicts)
            let localized = localizingUntrustedFileTagFindings(in: rawReport, firewall: firewall, language: language)
            return BibliographyVerificationResult(
                report: localized,
                isReplay: false,
                replayUsesCache: false,
                performedRegistryLookup: true
            )

        case .replay(let snapshot):
            let explicitCacheDir = environment["SCHOLAR_CACHE_DIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let replayCache: RegistryResponseCache?
            let replayUsesCache: Bool
            if !noCache, let explicitCacheDir, !explicitCacheDir.isEmpty {
                if let sharedReplayExplicitCache {
                    replayCache = sharedReplayExplicitCache
                } else {
                    let explicitSQLiteURL = URL(fileURLWithPath: explicitCacheDir, isDirectory: true)
                        .appendingPathComponent("registry.sqlite", isDirectory: false)
                    replayCache = RegistryResponseCache(
                        fileURL: explicitSQLiteURL,
                        clock: clock,
                        language: language,
                        warningHandler: cacheWarningHandler
                    )
                }
                replayUsesCache = true
            } else {
                replayCache = nil
                replayUsesCache = false
            }

            let replayLimiterClock = ClosureRegistryClock(
                now: { clock.now() },
                currentDate: { clock.currentDate() },
                sleep: { _ in }
            )
            let firewall = CitationVerificationFirewall(
                rateLimiter: RegistryRateLimiter(clock: replayLimiterClock),
                openAlexBudgetScope: OpenAlexSearchBudgetScope(),
                cache: replayCache,
                requestObserver: requestObserver,
                clock: clock
            )
            let replaySession = snapshot.makeSession()
            var verdicts: [CitationFirewallEntryVerdict] = []
            verdicts.reserveCapacity(entries.count)
            for entry in entries {
                let verdict = await firewall.verifyAgainstPublicRegistries(entry: entry, session: replaySession)
                try await replaySession.throwIfFailed()
                verdicts.append(verdict)
            }
            let rawReport = firewall.summarizeVerdicts(verdicts)
            let localized = localizingUntrustedFileTagFindings(in: rawReport, firewall: firewall, language: language)
            return BibliographyVerificationResult(
                report: localized,
                isReplay: true,
                replayUsesCache: replayUsesCache,
                performedRegistryLookup: true
            )

        case .record(let directoryURL, let transport):
            let limiter = sharedRateLimiter ?? RegistryRateLimiter(clock: clock)
            let budgetScope = OpenAlexSearchBudgetScope()
            let cache: RegistryResponseCache?
            if noCache {
                cache = nil
            } else if let sharedStandardCache {
                cache = sharedStandardCache
            } else {
                cache = RegistryResponseCache(
                    fileURL: RegistryResponseCache.resolveDatabaseURL(environment: environment),
                    clock: clock,
                    language: language,
                    warningHandler: cacheWarningHandler
                )
            }
            let firewall = CitationVerificationFirewall(
                rateLimiter: limiter,
                openAlexBudgetScope: budgetScope,
                cache: cache,
                requestObserver: requestObserver,
                clock: clock
            )
            let recordingSession = try RegistryRecordingSession(
                directoryURL: directoryURL,
                transport: transport
            )
            var verdicts: [CitationFirewallEntryVerdict] = []
            verdicts.reserveCapacity(entries.count)
            for entry in entries {
                let verdict = await firewall.verifyAgainstPublicRegistries(entry: entry, session: recordingSession)
                try await recordingSession.throwIfFailed()
                verdicts.append(verdict)
            }
            _ = try await recordingSession.finalize()
            let rawReport = firewall.summarizeVerdicts(verdicts)
            let localized = localizingUntrustedFileTagFindings(in: rawReport, firewall: firewall, language: language)
            return BibliographyVerificationResult(
                report: localized,
                isReplay: false,
                replayUsesCache: false,
                performedRegistryLookup: true
            )
        }
    }

    public static func localizingUntrustedFileTagFindings(
        in report: CitationFirewallAuditReport,
        firewall: CitationVerificationFirewall,
        language: ScholarLanguage
    ) -> CitationFirewallAuditReport {
        guard language == .zhHans else { return report }
        var changed = false
        let updatedVerdicts = report.verdicts.map { verdict -> CitationFirewallEntryVerdict in
            let declared = firewall.nonEmpty(verdict.auditedEntry.untrustedDeclaredFirewallClass)
            let declaredNote = firewall.nonEmpty(verdict.auditedEntry.untrustedDeclaredFirewallNote)
            let ignoredEprint = firewall.nonEmpty(verdict.auditedEntry.ignoredNonArXivEprint)
            let hasInvalidArXivDiscrepancy = verdict.fields.contains {
                $0.field == "arxivID" && $0.remoteValue == "invalid format"
            }
            guard declared != nil || declaredNote != nil || ignoredEprint != nil || hasInvalidArXivDiscrepancy else {
                return verdict
            }
            changed = true
            let updatedFindings = verdict.findings.map { finding -> FirewallFinding in
                switch finding.code {
                case .untrustedEmbeddedFirewallTag:
                    if finding.field == "x-firewall-note", let declaredNote {
                        return FirewallFinding(
                            code: finding.code,
                            severity: finding.severity,
                            field: finding.field,
                            detail: "文件里写着 \(declaredNote)，未采信。"
                        )
                    }
                    if let declared {
                        return FirewallFinding(
                            code: finding.code,
                            severity: finding.severity,
                            field: finding.field,
                            detail: "文件里写着 \(declared)，未采信。"
                        )
                    }
                    return finding
                case .ignoredNonArXivEprint:
                    if let ignoredEprint {
                        return FirewallFinding(
                            code: finding.code,
                            severity: finding.severity,
                            field: finding.field,
                            detail: "eprint 字段不是 arXiv 编号，未当作标识符（\(ignoredEprint)）。"
                        )
                    }
                    return finding
                default:
                    return finding
                }
            }
            let updatedFields = verdict.fields.map { discrepancy -> CitationFieldDiscrepancy in
                if discrepancy.field == "arxivID" && discrepancy.remoteValue == "invalid format" {
                    return CitationFieldDiscrepancy(
                        field: discrepancy.field,
                        localValue: discrepancy.localValue,
                        remoteValue: "格式不合法",
                        source: discrepancy.source,
                        severity: discrepancy.severity,
                        note: "arXiv 编号 '\(discrepancy.localValue)' 格式不合法。"
                    )
                }
                return discrepancy
            }
            return CitationFirewallEntryVerdict(
                citeKey: verdict.citeKey,
                firewallClass: verdict.firewallClass,
                insertable: verdict.insertable,
                reasons: verdict.reasons,
                sources: verdict.sources,
                fields: updatedFields,
                findings: updatedFindings,
                auditNote: verdict.auditNote,
                auditedEntry: verdict.auditedEntry
            )
        }
        return changed ? firewall.summarizeVerdicts(updatedVerdicts) : report
    }

    // MARK: - Stored Provenance & Effective Firewall Status Resolution (S42 / S48)

    /// Resolves effective firewall class and audit note for completion, hover, and diagnostics.
    /// Treats expired stored verdicts (>30d for VERIFIED/DRIFT/RETRACTED, >1d for NOT_FOUND)
    /// and legacy/bare stored verdicts lacking source or UTC date as unchecked (`UNVERIFIED`).
    public func resolveEffectiveStatus(
        for entry: BibliographyEntry,
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict] = [:],
        language: ScholarLanguage = .en
    ) -> (firewallClass: CitationFirewallClass, auditNote: String) {
        let now = clock.currentDate()
        let offline = evaluate(entry)

        if let inRun = inRunVerdictsByKey[entry.citeKey] {
            if case .expired(_, _, let dayStr) = inRun.auditedEntry.evaluateFirewallFreshness(at: now) {
                if offline.firewallClass == .notFound || offline.firewallClass == .retracted {
                    return (offline.firewallClass, offline.auditNote)
                }
                return (.unverified, BibliographyEntry.expiredVerdictNotice(fetchedAtUTC: dayStr, language: language))
            }
            if offline.firewallClass == .retracted || offline.firewallClass == .notFound {
                if !inRun.sources.isEmpty {
                    return (inRun.firewallClass, inRun.auditNote)
                }
                return (offline.firewallClass, offline.auditNote)
            }
            if inRun.firewallClass == .verified {
                if inRun.insertable && !inRun.sources.isEmpty {
                    return (.verified, inRun.auditNote)
                }
                return (offline.firewallClass, offline.auditNote)
            }
            return (inRun.firewallClass, inRun.auditNote)
        }

        switch entry.evaluateFirewallFreshness(at: now) {
        case .valid(let storedClass, let source, let dayStr):
            if offline.firewallClass == .notFound || offline.firewallClass == .retracted {
                return (offline.firewallClass, offline.auditNote)
            }
            let note = nonEmpty(entry.firewallAuditNote) ?? "[\(storedClass.rawValue)] Verified via \(source) on \(dayStr)."
            return (storedClass, note)

        case .expired(_, _, let dayStr):
            if offline.firewallClass == .notFound || offline.firewallClass == .retracted {
                return (offline.firewallClass, offline.auditNote)
            }
            return (.unverified, BibliographyEntry.expiredVerdictNotice(fetchedAtUTC: dayStr, language: language))

        case .missingProvenance:
            return (offline.firewallClass, offline.auditNote)
        }
    }

    // MARK: - Citation Insertion Assertion (`ERR_UNVERIFIED_CITATION`)

    /// Enforces ScholarOS's citation firewall policy for CLI, MCP, and project insertion checks.
    /// Per M1 item 8 (S42, S48), ONLY two grounds allow manuscript insertion:
    ///   1. A `VERIFIED` verdict computed in the current run (`insertable == true`, non-empty `sources`, unexpired);
    ///   2. A stored `VERIFIED` verdict on `entry` carrying non-empty source + UTC date within its 30-day TTL.
    /// Bare `firewallClass` values (from `.bib`, legacy DBs, or in-memory mutation) are never trusted.
    @discardableResult
    public func assertCitationAllowed(
        citeKey: String,
        in library: [String: BibliographyEntry],
        verifiedVerdicts: [String: CitationFirewallEntryVerdict] = [:],
        language: ScholarLanguage = .en
    ) throws -> BibliographyEntry {
        let trimmedKey = citeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry = library[trimmedKey] else {
            throw ScholarOSError.unverifiedCitationBlocked(
                citeKey: trimmedKey,
                statusCode: CitationFirewallClass.unverified.rawValue,
                reason: language.L(
                    "Citation key '\(trimmedKey)' is missing from the bibliography.",
                    "参考文献库中不存在引文键 '\(trimmedKey)'。"
                )
            )
        }

        let now = clock.currentDate()
        let offlineCheck = evaluate(entry)

        // 1. Verdict computed in the current run (e.g. `cite`, `scholar_cite_key`, or `verifyCitationsOnline`)
        if let inRunVerdict = verifiedVerdicts[trimmedKey] {
            if case .expired(_, _, let fetchedAtUTC) = inRunVerdict.auditedEntry.evaluateFirewallFreshness(at: now) {
                if offlineCheck.firewallClass == .notFound || offlineCheck.firewallClass == .retracted {
                    throw ScholarOSError.unverifiedCitationBlocked(
                        citeKey: entry.citeKey,
                        statusCode: offlineCheck.firewallClass.rawValue,
                        reason: formatInRunRejectionReason(for: offlineCheck, language: language)
                    )
                }
                throw ScholarOSError.unverifiedCitationBlocked(
                    citeKey: entry.citeKey,
                    statusCode: CitationFirewallClass.unverified.rawValue,
                    reason: BibliographyEntry.expiredVerdictNotice(fetchedAtUTC: fetchedAtUTC, language: language)
                )
            }

            if inRunVerdict.citeKey == entry.citeKey,
               inRunVerdict.firewallClass == .verified,
               inRunVerdict.insertable,
               !inRunVerdict.sources.isEmpty
            {
                return inRunVerdict.auditedEntry
            }

            throw ScholarOSError.unverifiedCitationBlocked(
                citeKey: entry.citeKey,
                statusCode: inRunVerdict.firewallClass.rawValue,
                reason: formatInRunRejectionReason(for: inRunVerdict, language: language)
            )
        }

        // 2. Deterministic offline structural / built-in retraction failure always blocks
        if offlineCheck.firewallClass == .notFound || offlineCheck.firewallClass == .retracted {
            throw ScholarOSError.unverifiedCitationBlocked(
                citeKey: entry.citeKey,
                statusCode: offlineCheck.firewallClass.rawValue,
                reason: formatInRunRejectionReason(for: offlineCheck, language: language)
            )
        }

        // 3. Stored verdict on `entry` with provenance & clock TTL check (S48)
        switch entry.evaluateFirewallFreshness(at: now) {
        case .valid(let storedClass, let source, let dayStr):
            if storedClass == .verified {
                return entry
            }
            let detail = nonEmpty(entry.firewallAuditNote).map(CitationAuditWording.strippingLeadingClassTag)
                ?? "\(storedClass.rawValue) recorded from \(source) on \(dayStr)."
            throw ScholarOSError.unverifiedCitationBlocked(
                citeKey: entry.citeKey,
                statusCode: storedClass.rawValue,
                reason: language.L(
                    "Verification failed [\(storedClass.rawValue), source: \(source), fetched: \(dayStr)]: \(detail)",
                    "已完成核查但发现问题 [\(storedClass.rawValue)，数据源：\(source)，取得日期：\(dayStr)]：\(detail)"
                )
            )

        case .expired(_, _, let fetchedAtUTC):
            throw ScholarOSError.unverifiedCitationBlocked(
                citeKey: entry.citeKey,
                statusCode: CitationFirewallClass.unverified.rawValue,
                reason: BibliographyEntry.expiredVerdictNotice(fetchedAtUTC: fetchedAtUTC, language: language)
            )

        case .missingProvenance:
            throw ScholarOSError.unverifiedCitationBlocked(
                citeKey: entry.citeKey,
                statusCode: CitationFirewallClass.unverified.rawValue,
                reason: language.L(
                    "Lookup not performed [UNVERIFIED]: entry '\(entry.citeKey)' has no verified conclusion with source and date (bare stored status is ignored); re-verification is required.",
                    "尚未完成外部核查 [UNVERIFIED]：条目 '\(entry.citeKey)' 没有带数据源与取得日期的有效核查结论（不采信裸存的状态），需要重新核查。"
                )
            )
        }
    }

    private func formatInRunRejectionReason(
        for verdict: CitationFirewallEntryVerdict,
        language: ScholarLanguage
    ) -> String {
        switch verdict.firewallClass {
        case .unverified:
            let codes = verdict.reasons.isEmpty
                ? [CitationUnverifiedReasonCode.offline.rawValue]
                : verdict.reasons
            let codeText = codes.joined(separator: ", ")
            if codes.contains(CitationUnverifiedReasonCode.offline.rawValue) {
                return language.L(
                    "Lookup not performed [UNVERIFIED, reason: \(codeText)]: online registry verification was skipped because --offline was requested, not because any problem was found with this reference.",
                    "尚未完成外部核查 [UNVERIFIED，原因码：\(codeText)]：因指定离线而未向外部注册库核查，并非该文献本身有问题。"
                )
            }
            let cleanNote = CitationAuditWording.strippingLeadingClassTag(verdict.auditNote)
            return language.L(
                "Lookup could not complete [UNVERIFIED, reason: \(codeText)]: \(cleanNote)",
                "尚未完成外部核查 [UNVERIFIED，原因码：\(codeText)]：未能完成外部注册库查询，并非已证实该文献有问题。"
            )

        case .notFound, .drift, .retracted:
            let fallbackCode: String
            switch verdict.firewallClass {
            case .notFound: fallbackCode = "not_found"
            case .drift: fallbackCode = "metadata_drift"
            case .retracted: fallbackCode = "retracted"
            case .verified, .unverified: fallbackCode = "rejected"
            }
            let codes = verdict.reasons.isEmpty ? [fallbackCode] : verdict.reasons
            let codeText = codes.joined(separator: ", ")
            let cleanNote = CitationAuditWording.strippingLeadingClassTag(verdict.auditNote)
            return language.L(
                "Checked and rejected [\(verdict.firewallClass.rawValue), reason: \(codeText)]: \(cleanNote)",
                "已核查并发现问题 [\(verdict.firewallClass.rawValue)，原因码：\(codeText)]：\(cleanNote)"
            )

        case .verified:
            return CitationAuditWording.strippingLeadingClassTag(verdict.auditNote)
        }
    }

    /// Validates a list of cited keys in manuscript order, throwing `ERR_UNVERIFIED_CITATION` on the first disallowed key.
    public func assertAllCitationsAllowed(
        citeKeys: [String],
        in library: [String: BibliographyEntry],
        verifiedVerdicts: [String: CitationFirewallEntryVerdict] = [:],
        language: ScholarLanguage = .en
    ) throws -> [BibliographyEntry] {
        try citeKeys.map { key in
            try assertCitationAllowed(
                citeKey: key,
                in: library,
                verifiedVerdicts: verifiedVerdicts,
                language: language
            )
        }
    }

    // MARK: - Async Live Public Registry Verification (Crossref / OpenAlex / doi.org / arXiv / PubMed)

    /// Resolves `entry` against Crossref, OpenAlex, doi.org, arXiv, or PubMed APIs via an injectable `CitationRegistrySession`.
    /// Transport errors, timeouts, rate limits (429), server errors (5xx), and unparseable responses
    /// ALWAYS yield `.unverified` with the corresponding reason code — NEVER `.verified` or `.notFound`.
    public func verifyAgainstPublicRegistries(
        entry: BibliographyEntry,
        session: any CitationRegistrySession = LiveURLSessionRegistryClient()
    ) async -> CitationFirewallEntryVerdict {
        let offlineVerdict = evaluate(entry)
        if offlineVerdict.firewallClass == .notFound {
            return offlineVerdict
        }

        let isBuiltInRetracted = (offlineVerdict.firewallClass == .retracted)
        let findings = offlineVerdict.findings

        // Path A: Resolve non-arXiv DOI via Crossref -> OpenAlex -> doi.org handle -> Crossref bibliographic search,
        // and when an arXiv ID is also present on the entry, query arXiv as well for cross-checking (DOI remains authoritative).
        if let normDOI = ReferenceIdentifierNormalizer.normalizeDOI(entry.doi),
           !normDOI.hasPrefix("10.48550/arxiv.") {
            let doiVerdict = await verifyNonArXivDOIEntry(
                entry: entry,
                normalizedDOI: normDOI,
                offlineVerdict: offlineVerdict,
                initialFindings: findings,
                isBuiltInRetracted: isBuiltInRetracted,
                session: session
            )
            if let rawArXiv = nonEmpty(entry.arxivID) {
                let arxivCheck = ScholarlyIdentifierValidator.validateArXivID(
                    rawArXiv,
                    maxYear: maxAllowedPublicationYear
                )
                if arxivCheck.isValid {
                    return await crossCheckArXivAlongsideDOIVerdict(
                        entry: entry,
                        normalizedDOI: normDOI,
                        arxivID: arxivCheck.canonicalBaseID,
                        doiVerdict: doiVerdict,
                        offlineVerdict: offlineVerdict,
                        isBuiltInRetracted: isBuiltInRetracted,
                        session: session
                    )
                } else {
                    return applyMalformedExplicitArXivToDOIVerdict(
                        entry: entry,
                        rawArXiv: rawArXiv,
                        doiVerdict: doiVerdict,
                        offlineVerdict: offlineVerdict
                    )
                }
            }
            return doiVerdict
        }

        // Path B: Resolve arXiv preprint (including `10.48550/arXiv.*` DataCite DOIs) via arXiv Atom API
        let rawExplicitArXiv = nonEmpty(entry.arxivID)
        let explicitArXivValidation = rawExplicitArXiv.map {
            ScholarlyIdentifierValidator.validateArXivID($0, maxYear: maxAllowedPublicationYear)
        }
        let doiEmbeddedArXiv: String? = {
            if let d = ReferenceIdentifierNormalizer.normalizeDOI(entry.doi), d.hasPrefix("10.48550/arxiv.") {
                return String(d.dropFirst("10.48550/arxiv.".count))
            }
            return nil
        }()

        if let explicitCheck = explicitArXivValidation, explicitCheck.isValid {
            return await verifyArXivEntry(
                entry: entry,
                arxivID: explicitCheck.canonicalBaseID,
                offlineVerdict: offlineVerdict,
                initialFindings: findings,
                isBuiltInRetracted: isBuiltInRetracted,
                session: session
            )
        } else if let doiArXiv = doiEmbeddedArXiv {
            let doiArXivVerdict = await verifyArXivEntry(
                entry: entry,
                arxivID: doiArXiv,
                offlineVerdict: offlineVerdict,
                initialFindings: findings,
                isBuiltInRetracted: isBuiltInRetracted,
                session: session
            )
            if let rawArXiv = rawExplicitArXiv, explicitArXivValidation?.isValid == false {
                return applyMalformedExplicitArXivToDOIVerdict(
                    entry: entry,
                    rawArXiv: rawArXiv,
                    doiVerdict: doiArXivVerdict,
                    offlineVerdict: offlineVerdict
                )
            }
            return doiArXivVerdict
        }

        // Path C: Resolve PubMed PMID via E-utilities `esummary`
        if let rawPMID = nonEmpty(entry.pmid) {
            let pmidCheck = ScholarlyIdentifierValidator.validatePMID(rawPMID)
            if pmidCheck.isValid {
                return await verifyPubMedEntry(
                    entry: entry,
                    normalizedPMID: pmidCheck.normalized,
                    offlineVerdict: offlineVerdict,
                    initialFindings: findings,
                    isBuiltInRetracted: isBuiltInRetracted,
                    session: session
                )
            }
        }

        // Path D: No persistent identifier — search Crossref `query.bibliographic` (title + surname + year, rows=5),
        // falling back to OpenAlex title search (`per-page=5`) only when Crossref returns 0 matching candidates.
        return await verifyIdentifierlessEntry(
            entry: entry,
            offlineVerdict: offlineVerdict,
            initialFindings: findings,
            isBuiltInRetracted: isBuiltInRetracted,
            session: session
        )
    }

    private func lookupCachedResponse(
        for url: URL,
        source: String
    ) -> RegistryHTTPResponse? {
        guard let cache else { return nil }
        let t0 = cache.clock.now()
        guard let hit = cache.lookup(for: url) else { return nil }
        let t1 = cache.clock.now()
        requestObserver?(
            RegistryRequestTelemetryEvent(
                source: source,
                url: url.absoluteString,
                statusCode: hit.statusCode,
                errorDescription: nil,
                elapsedSeconds: max(0.0, t1 - t0),
                origin: .cache,
                startedAtUptime: t0,
                completedAtUptime: max(t0, t1)
            )
        )
        return hit
    }

    private func sendRegistryRequest(
        _ request: URLRequest,
        source: String,
        session: any CitationRegistrySession
    ) async throws -> RegistryHTTPResponse {
        if let reqURL = request.url,
           let cached = lookupCachedResponse(for: reqURL, source: source) {
            return cached
        }
        if let customLimiter = rateLimiter {
            return try await customLimiter.send(
                request,
                source: source,
                using: session,
                openAlexBudgetScope: openAlexBudgetScope,
                observer: requestObserver
            )
        }
        if session is RegistryReplaySession {
            return try await RegistryRateLimiter(clock: .immediate).send(
                request,
                source: source,
                using: session,
                openAlexBudgetScope: openAlexBudgetScope,
                observer: requestObserver
            )
        }
        return try await RegistryRateLimiter.shared.send(
            request,
            source: source,
            using: session,
            openAlexBudgetScope: openAlexBudgetScope,
            observer: requestObserver
        )
    }

    // MARK: - arXiv Primary Lookup & Dual-Identifier Cross-Check (M1 Item 3)

    private func verifyArXivEntry(
        entry: BibliographyEntry,
        arxivID: String,
        offlineVerdict: CitationFirewallEntryVerdict,
        initialFindings: [FirewallFinding],
        isBuiltInRetracted: Bool,
        session: any CitationRegistrySession
    ) async -> CitationFirewallEntryVerdict {
        var findings = initialFindings
        var sources: [CitationVerdictSourceRecord] = []

        guard let arxivURL = RegistryURLBuilder.arXivQueryURL(arXivID: arxivID) else {
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [CitationUnverifiedReasonCode.transportError.rawValue],
                sources: sources,
                fields: [],
                findings: findings
            )
        }

        do {
            let response = try await sendRegistryRequest(URLRequest(url: arxivURL), source: "arXiv", session: session)
            let fetchedAt = resolvedFetchedAt(from: response)
            let sourceRecord = CitationVerdictSourceRecord(
                source: "arXiv",
                url: arxivURL.absoluteString,
                status: response.statusCode,
                fetchedAt: fetchedAt,
                origin: response.origin
            )
            sources.append(sourceRecord)

            // Rate-limit (429), timeout (408), and server errors (5xx) always yield UNVERIFIED.
            if response.statusCode == 429 || response.statusCode == 408 || (500...599).contains(response.statusCode) {
                let code = classifyHTTPFailureStatus(response.statusCode, response: response, host: "export.arxiv.org")
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .warning,
                        field: "network",
                        detail: describeHTTPFailure(source: "arXiv", statusCode: response.statusCode, identifier: "arXiv:\(arxivID)")
                    )
                )
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .unverified,
                    reasons: [code.rawValue],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }

            // Decide strictly from Atom `totalResults` and `<entry>` rather than HTTP status code.
            switch parseArXivAtomPayload(response.body) {
            case .parsed(let remote):
                if response.origin != .cache, response.statusCode == 200 {
                    cache?.store(url: arxivURL, statusCode: response.statusCode, body: response.body)
                }
                return reconcileRemoteRegistryMetadata(
                    entry: entry,
                    remote: remote,
                    primarySource: sourceRecord,
                    allSources: sources,
                    existingFindings: findings,
                    isBuiltInRetracted: isBuiltInRetracted
                )
            case .notFound:
                if response.origin != .cache, response.statusCode == 200 {
                    cache?.store(url: arxivURL, statusCode: response.statusCode, body: response.body)
                }
                let detail = "arXiv reported that identifier 'arXiv:\(arxivID)' does not exist."
                findings.append(
                    FirewallFinding(
                        code: .registryLookupNotFound,
                        severity: .criticalBlock,
                        field: "arxivID",
                        detail: detail
                    )
                )
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .notFound,
                    reasons: ["arxiv_not_found"],
                    sources: sources,
                    fields: [],
                    findings: findings,
                    overrideNote: "[NOT_FOUND] \(detail)"
                )
            case .unparseable:
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .warning,
                        field: "network",
                        detail: "arXiv payload for 'arXiv:\(arxivID)' could not be parsed."
                    )
                )
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .unverified,
                    reasons: [CitationUnverifiedReasonCode.unparseable.rawValue],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }
        } catch is any FatalRegistrySessionError {
            return offlineVerdict
        } catch {
            let code = classifyThrownTransportError(error)
            sources.append(
                CitationVerdictSourceRecord(
                    source: "arXiv",
                    url: arxivURL.absoluteString,
                    status: nil,
                    fetchedAt: currentISO8601Timestamp(),
                    origin: .network
                )
            )
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .warning,
                    field: "network",
                    detail: describeTransportError(source: "arXiv", code: code, error: error)
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [code.rawValue],
                sources: sources,
                fields: [],
                findings: findings
            )
        }
    }

    /// Queries arXiv when an entry carries BOTH a non-arXiv DOI and an `arxivID`.
    /// The DOI verdict remains authoritative for metadata comparison, while arXiv cross-checks
    /// withdrawal/retraction and `arxivID` existence/identity.
    private func crossCheckArXivAlongsideDOIVerdict(
        entry: BibliographyEntry,
        normalizedDOI: String,
        arxivID: String,
        doiVerdict: CitationFirewallEntryVerdict,
        offlineVerdict: CitationFirewallEntryVerdict,
        isBuiltInRetracted: Bool,
        session: any CitationRegistrySession
    ) async -> CitationFirewallEntryVerdict {
        guard let arxivURL = RegistryURLBuilder.arXivQueryURL(arXivID: arxivID) else {
            return doiVerdict
        }
        // If `verifyNonArXivDOIEntry` already aborted on a FatalRegistrySessionError, preserve `offlineVerdict`.
        if doiVerdict == offlineVerdict && doiVerdict.sources.isEmpty {
            return offlineVerdict
        }

        var sources = doiVerdict.sources
        var findings = doiVerdict.findings

        let response: RegistryHTTPResponse
        do {
            response = try await sendRegistryRequest(URLRequest(url: arxivURL), source: "arXiv", session: session)
        } catch is any FatalRegistrySessionError {
            return offlineVerdict
        } catch {
            let code = classifyThrownTransportError(error)
            sources.append(
                CitationVerdictSourceRecord(
                    source: "arXiv",
                    url: arxivURL.absoluteString,
                    status: nil,
                    fetchedAt: currentISO8601Timestamp(),
                    origin: .network
                )
            )
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .advisory,
                    field: "network",
                    detail: describeTransportError(source: "arXiv", code: code, error: error)
                )
            )
            if doiVerdict.firewallClass == .notFound {
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .unverified,
                    reasons: [code.rawValue],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: doiVerdict.firewallClass,
                reasons: doiVerdict.reasons,
                sources: sources,
                fields: doiVerdict.fields,
                findings: findings,
                overrideNote: doiVerdict.auditNote
            )
        }

        let sourceRecord = CitationVerdictSourceRecord(
            source: "arXiv",
            url: arxivURL.absoluteString,
            status: response.statusCode,
            fetchedAt: resolvedFetchedAt(from: response),
            origin: response.origin
        )
        sources.append(sourceRecord)

        if response.statusCode == 429 || response.statusCode == 408 || (500...599).contains(response.statusCode) {
            let code = classifyHTTPFailureStatus(response.statusCode, response: response, host: "export.arxiv.org")
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .advisory,
                    field: "network",
                    detail: describeHTTPFailure(source: "arXiv", statusCode: response.statusCode, identifier: "arXiv:\(arxivID)")
                )
            )
            if doiVerdict.firewallClass == .notFound {
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .unverified,
                    reasons: [code.rawValue],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: doiVerdict.firewallClass,
                reasons: doiVerdict.reasons,
                sources: sources,
                fields: doiVerdict.fields,
                findings: findings,
                overrideNote: doiVerdict.auditNote
            )
        }

        switch parseArXivAtomPayload(response.body) {
        case .parsed(let arxivRemote):
            if response.origin != .cache, response.statusCode == 200 {
                cache?.store(url: arxivURL, statusCode: response.statusCode, body: response.body)
            }
            if let arxivRetField = arxivRemote.retractionField {
                findings.removeAll {
                    $0.code == .blockedRetractedWork && $0.detail.contains(CitationAuditWording.builtInRetractionListNotice)
                }
                let arxivDetail = "arXiv marks this publication as retracted (field: \(arxivRetField))."
                findings.append(
                    FirewallFinding(
                        code: .blockedRetractedWork,
                        severity: .criticalBlock,
                        field: arxivRetField,
                        detail: arxivDetail
                    )
                )
                var mergedReasons = doiVerdict.firewallClass == .retracted
                    ? doiVerdict.reasons.filter { $0 != "retracted_builtin_list" }
                    : []
                if !mergedReasons.contains("retracted_arxiv") {
                    mergedReasons.append("retracted_arxiv")
                }
                let note = doiVerdict.firewallClass == .retracted
                    ? "\(doiVerdict.auditNote) \(arxivDetail)"
                    : "[RETRACTED] \(arxivDetail)"
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .retracted,
                    reasons: mergedReasons,
                    sources: sources,
                    fields: [],
                    findings: findings,
                    overrideNote: note
                )
            }

            if doiVerdict.firewallClass == .verified || doiVerdict.firewallClass == .drift {
                let doiLinked = (arxivRemote.doi == normalizedDOI)
                let authorAligned = (compareFirstAuthor(localAuthors: entry.authors, remote: arxivRemote).discrepancy == nil)
                let titleAligned = (compareTitle(localTitle: entry.title, remoteTitle: arxivRemote.title, sourceName: "arXiv").discrepancy == nil)

                if !doiLinked && !authorAligned && !titleAligned {
                    var discrepancies = doiVerdict.fields
                    discrepancies.append(
                        CitationFieldDiscrepancy(
                            field: "arxivID",
                            localValue: arxivID,
                            remoteValue: arxivRemote.title,
                            source: "arXiv",
                            severity: "error",
                            note: "arXiv:\(arxivID) points to a different work ('\(arxivRemote.title)') than the DOI record."
                        )
                    )
                    var reasons = doiVerdict.firewallClass == .drift ? doiVerdict.reasons : []
                    if !reasons.contains("arxiv_mismatch") {
                        reasons.append("arxiv_mismatch")
                    }
                    let driftSummary = formatEnglishDriftSummary(discrepancies: discrepancies, sourceName: "arXiv")
                    findings.append(
                        FirewallFinding(
                            code: .metadataDriftDetected,
                            severity: .warning,
                            field: "arxivID",
                            detail: driftSummary
                        )
                    )
                    return buildUpdatedVerdict(
                        for: entry,
                        assignedClass: .drift,
                        reasons: reasons,
                        sources: sources,
                        fields: discrepancies,
                        findings: findings,
                        overrideNote: "[DRIFT] \(driftSummary)"
                    )
                }

                findings.append(
                    FirewallFinding(
                        code: .validArXivIdentifier,
                        severity: .pass,
                        field: "arxivID",
                        detail: "Cross-checked arXiv:\(arxivID) alongside authoritative DOI '\(normalizedDOI)'."
                    )
                )
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: doiVerdict.firewallClass,
                    reasons: doiVerdict.reasons,
                    sources: sources,
                    fields: doiVerdict.fields,
                    findings: findings,
                    overrideNote: doiVerdict.auditNote
                )
            }

            return buildUpdatedVerdict(
                for: entry,
                assignedClass: doiVerdict.firewallClass,
                reasons: doiVerdict.reasons,
                sources: sources,
                fields: doiVerdict.fields,
                findings: findings,
                overrideNote: doiVerdict.auditNote
            )

        case .notFound:
            if response.origin != .cache, response.statusCode == 200 {
                cache?.store(url: arxivURL, statusCode: response.statusCode, body: response.body)
            }
            if doiVerdict.firewallClass == .verified || doiVerdict.firewallClass == .drift {
                var discrepancies = doiVerdict.fields
                discrepancies.append(
                    CitationFieldDiscrepancy(
                        field: "arxivID",
                        localValue: arxivID,
                        remoteValue: "",
                        source: "arXiv",
                        severity: "error",
                        note: "arXiv reported that identifier 'arXiv:\(arxivID)' does not exist."
                    )
                )
                var reasons = doiVerdict.firewallClass == .drift ? doiVerdict.reasons : []
                if !reasons.contains("arxiv_not_found") {
                    reasons.append("arxiv_not_found")
                }
                let driftSummary = formatEnglishDriftSummary(discrepancies: discrepancies, sourceName: "arXiv")
                findings.append(
                    FirewallFinding(
                        code: .registryLookupNotFound,
                        severity: .warning,
                        field: "arxivID",
                        detail: "arXiv reported that identifier 'arXiv:\(arxivID)' does not exist."
                    )
                )
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .drift,
                    reasons: reasons,
                    sources: sources,
                    fields: discrepancies,
                    findings: findings,
                    overrideNote: "[DRIFT] \(driftSummary)"
                )
            }
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: doiVerdict.firewallClass,
                reasons: doiVerdict.reasons,
                sources: sources,
                fields: doiVerdict.fields,
                findings: findings,
                overrideNote: doiVerdict.auditNote
            )

        case .unparseable:
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .advisory,
                    field: "network",
                    detail: "arXiv cross-check payload for 'arXiv:\(arxivID)' could not be parsed."
                )
            )
            if doiVerdict.firewallClass == .notFound {
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .unverified,
                    reasons: [CitationUnverifiedReasonCode.unparseable.rawValue],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: doiVerdict.firewallClass,
                reasons: doiVerdict.reasons,
                sources: sources,
                fields: doiVerdict.fields,
                findings: findings,
                overrideNote: doiVerdict.auditNote
            )
        }
    }

    /// Applies S52 Rule 3 when an entry has a syntactically valid DOI AND an explicit `arXiv`
    /// identifier whose format is invalid: the DOI lookup verdict governs, the malformed arXiv ID
    /// is recorded in `fields`, and a found DOI record (`.verified` / `.drift`) becomes `.drift`.
    private func applyMalformedExplicitArXivToDOIVerdict(
        entry: BibliographyEntry,
        rawArXiv: String,
        doiVerdict: CitationFirewallEntryVerdict,
        offlineVerdict: CitationFirewallEntryVerdict
    ) -> CitationFirewallEntryVerdict {
        if doiVerdict == offlineVerdict && doiVerdict.sources.isEmpty {
            return offlineVerdict
        }
        let invalidDiscrepancy = CitationFieldDiscrepancy(
            field: "arxivID",
            localValue: rawArXiv,
            remoteValue: "invalid format",
            source: "arXiv",
            severity: "error",
            note: "arXiv identifier '\(rawArXiv)' has invalid format."
        )
        var discrepancies = doiVerdict.fields
        discrepancies.append(invalidDiscrepancy)
        var findings = doiVerdict.findings

        if doiVerdict.firewallClass == .verified || doiVerdict.firewallClass == .drift {
            var reasons = doiVerdict.firewallClass == .drift ? doiVerdict.reasons : []
            if !reasons.contains("arxiv_mismatch") {
                reasons.append("arxiv_mismatch")
            }
            let driftSummary = formatEnglishDriftSummary(discrepancies: discrepancies, sourceName: "arXiv")
            findings.append(
                FirewallFinding(
                    code: .metadataDriftDetected,
                    severity: .warning,
                    field: "arxivID",
                    detail: driftSummary
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .drift,
                reasons: reasons,
                sources: doiVerdict.sources,
                fields: discrepancies,
                findings: findings,
                overrideNote: "[DRIFT] \(driftSummary)"
            )
        }

        return buildUpdatedVerdict(
            for: entry,
            assignedClass: doiVerdict.firewallClass,
            reasons: doiVerdict.reasons,
            sources: doiVerdict.sources,
            fields: discrepancies,
            findings: findings,
            overrideNote: doiVerdict.auditNote
        )
    }

    // MARK: - PubMed PMID Lookup via E-utilities `esummary` (M1 Item 3)

    private func verifyPubMedEntry(
        entry: BibliographyEntry,
        normalizedPMID: String,
        offlineVerdict: CitationFirewallEntryVerdict,
        initialFindings: [FirewallFinding],
        isBuiltInRetracted: Bool,
        session: any CitationRegistrySession
    ) async -> CitationFirewallEntryVerdict {
        var findings = initialFindings
        var sources: [CitationVerdictSourceRecord] = []

        guard let pubmedURL = RegistryURLBuilder.pubMedSummaryURL(pmid: normalizedPMID) else {
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [CitationUnverifiedReasonCode.transportError.rawValue],
                sources: sources,
                fields: [],
                findings: findings
            )
        }

        do {
            let response = try await sendRegistryRequest(URLRequest(url: pubmedURL), source: "PubMed", session: session)
            let fetchedAt = resolvedFetchedAt(from: response)
            let sourceRecord = CitationVerdictSourceRecord(
                source: "PubMed",
                url: pubmedURL.absoluteString,
                status: response.statusCode,
                fetchedAt: fetchedAt,
                origin: response.origin
            )
            sources.append(sourceRecord)

            guard response.statusCode == 200 else {
                let code = classifyHTTPFailureStatus(response.statusCode, response: response, host: "eutils.ncbi.nlm.nih.gov")
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .warning,
                        field: "network",
                        detail: describeHTTPFailure(source: "PubMed", statusCode: response.statusCode, identifier: "PMID:\(normalizedPMID)")
                    )
                )
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .unverified,
                    reasons: [code.rawValue],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }

            switch parsePubMedSummaryPayload(response.body, requestedPMID: normalizedPMID) {
            case .parsed(let remote):
                if response.origin != .cache {
                    cache?.store(url: pubmedURL, statusCode: response.statusCode, body: response.body)
                }
                return reconcileRemoteRegistryMetadata(
                    entry: entry,
                    remote: remote,
                    primarySource: sourceRecord,
                    allSources: sources,
                    existingFindings: findings,
                    isBuiltInRetracted: isBuiltInRetracted
                )
            case .notFound(let errDetail):
                if response.origin != .cache {
                    cache?.store(url: pubmedURL, statusCode: response.statusCode, body: response.body)
                }
                let detail = "PubMed reported that identifier 'PMID:\(normalizedPMID)' does not exist (\(errDetail))."
                findings.append(
                    FirewallFinding(
                        code: .registryLookupNotFound,
                        severity: .criticalBlock,
                        field: "pmid",
                        detail: detail
                    )
                )
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .notFound,
                    reasons: ["pmid_not_found"],
                    sources: sources,
                    fields: [],
                    findings: findings,
                    overrideNote: "[NOT_FOUND] \(detail)"
                )
            case .registeredNoMetadata:
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .warning,
                        field: "pmid",
                        detail: "PubMed record 'PMID:\(normalizedPMID)' returned empty title metadata."
                    )
                )
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .unverified,
                    reasons: [CitationUnverifiedReasonCode.registeredNoMetadata.rawValue],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            case .rateLimited:
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .warning,
                        field: "network",
                        detail: "PubMed reported rate limiting for 'PMID:\(normalizedPMID)'."
                    )
                )
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .unverified,
                    reasons: [CitationUnverifiedReasonCode.rateLimited.rawValue],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            case .unparseable:
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .warning,
                        field: "network",
                        detail: "PubMed esummary payload for 'PMID:\(normalizedPMID)' could not be parsed."
                    )
                )
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .unverified,
                    reasons: [CitationUnverifiedReasonCode.unparseable.rawValue],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }
        } catch is any FatalRegistrySessionError {
            return offlineVerdict
        } catch {
            let code = classifyThrownTransportError(error)
            sources.append(
                CitationVerdictSourceRecord(
                    source: "PubMed",
                    url: pubmedURL.absoluteString,
                    status: nil,
                    fetchedAt: currentISO8601Timestamp(),
                    origin: .network
                )
            )
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .warning,
                    field: "network",
                    detail: describeTransportError(source: "PubMed", code: code, error: error)
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [code.rawValue],
                sources: sources,
                fields: [],
                findings: findings
            )
        }
    }

    // MARK: - Identifierless Bibliographic Search (Crossref -> OpenAlex, M1 Item 3)

    private func verifyIdentifierlessEntry(
        entry: BibliographyEntry,
        offlineVerdict: CitationFirewallEntryVerdict,
        initialFindings: [FirewallFinding],
        isBuiltInRetracted: Bool,
        session: any CitationRegistrySession
    ) async -> CitationFirewallEntryVerdict {
        var findings = initialFindings
        var sources: [CitationVerdictSourceRecord] = []
        var failureReasons: [CitationUnverifiedReasonCode] = []

        guard let crossrefQuery = buildIdentifierlessCrossrefQuery(for: entry),
              let openAlexQuery = buildOpenAlexTitleSearchQuery(for: entry) else {
            let detail = CitationAuditWording.noMatchInSearchNotice
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .warning,
                    field: "doi/arxivID/pmid",
                    detail: detail
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [CitationUnverifiedReasonCode.noMatchInSearch.rawValue],
                sources: sources,
                fields: [],
                findings: findings,
                overrideNote: "[UNVERIFIED] \(detail)"
            )
        }

        // 1. Crossref `query.bibliographic` (title + first author surname + year, rows=5)
        if let crossrefURL = RegistryURLBuilder.crossrefBibliographicSearchURL(query: crossrefQuery, rows: 5) {
            do {
                let response = try await sendRegistryRequest(URLRequest(url: crossrefURL), source: "Crossref", session: session)
                let sourceRecord = CitationVerdictSourceRecord(
                    source: "Crossref",
                    url: crossrefURL.absoluteString,
                    status: response.statusCode,
                    fetchedAt: resolvedFetchedAt(from: response),
                    origin: response.origin
                )
                sources.append(sourceRecord)

                if response.statusCode == 200 {
                    switch parseCrossrefSearchPayload(response.body) {
                    case .parsed(let candidates):
                        switch selectMatchingSearchCandidate(entry: entry, candidates: candidates, sourceName: "Crossref") {
                        case .single(let matched):
                            if response.origin != .cache {
                                cache?.store(url: crossrefURL, statusCode: response.statusCode, body: response.body)
                            }
                            return reconcileIdentifierlessMatchedCandidate(
                                entry: entry,
                                remote: matched,
                                primarySource: sourceRecord,
                                allSources: sources,
                                existingFindings: findings,
                                isBuiltInRetracted: isBuiltInRetracted
                            )
                        case .ambiguous(let count):
                            let detail = "Crossref bibliographic search returned \(count) equally matching records for '\(entry.title)'."
                            findings.append(
                                FirewallFinding(
                                    code: .registryTransportUnavailable,
                                    severity: .warning,
                                    field: "doi/arxivID/pmid",
                                    detail: detail
                                )
                            )
                            return buildUpdatedVerdict(
                                for: entry,
                                assignedClass: .unverified,
                                reasons: [CitationUnverifiedReasonCode.ambiguous.rawValue],
                                sources: sources,
                                fields: [],
                                findings: findings,
                                overrideNote: "[UNVERIFIED] \(detail)"
                            )
                        case .none:
                            break
                        }
                    case .unparseable:
                        failureReasons.append(.unparseable)
                        findings.append(
                            FirewallFinding(
                                code: .registryTransportUnavailable,
                                severity: .warning,
                                field: "network",
                                detail: "Crossref bibliographic search payload for '\(crossrefQuery)' could not be parsed."
                            )
                        )
                    }
                } else {
                    let code = classifyHTTPFailureStatus(response.statusCode, response: response, host: "api.crossref.org")
                    failureReasons.append(code)
                    findings.append(
                        FirewallFinding(
                            code: .registryTransportUnavailable,
                            severity: .warning,
                            field: "network",
                            detail: describeHTTPFailure(source: "Crossref", statusCode: response.statusCode, identifier: crossrefQuery)
                        )
                    )
                }
            } catch is any FatalRegistrySessionError {
                return offlineVerdict
            } catch {
                let code = classifyThrownTransportError(error)
                failureReasons.append(code)
                sources.append(
                    CitationVerdictSourceRecord(
                        source: "Crossref",
                        url: crossrefURL.absoluteString,
                        status: nil,
                        fetchedAt: currentISO8601Timestamp(),
                        origin: .network
                    )
                )
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .warning,
                        field: "network",
                        detail: describeTransportError(source: "Crossref", code: code, error: error)
                    )
                )
            }
        }

        // 2. OpenAlex title search (`per-page=5`) only when Crossref did not yield a match
        if let openAlexURL = RegistryURLBuilder.openAlexSearchURL(query: openAlexQuery, perPage: 5) {
            do {
                let response = try await sendRegistryRequest(URLRequest(url: openAlexURL), source: "OpenAlex", session: session)
                let sourceRecord = CitationVerdictSourceRecord(
                    source: "OpenAlex",
                    url: openAlexURL.absoluteString,
                    status: response.statusCode,
                    fetchedAt: resolvedFetchedAt(from: response),
                    origin: response.origin
                )
                sources.append(sourceRecord)

                if response.statusCode == 200 {
                    switch parseOpenAlexSearchPayload(response.body) {
                    case .parsed(let candidates):
                        switch selectMatchingSearchCandidate(entry: entry, candidates: candidates, sourceName: "OpenAlex") {
                        case .single(let matched):
                            if response.origin != .cache {
                                cache?.store(url: openAlexURL, statusCode: response.statusCode, body: response.body)
                            }
                            return reconcileIdentifierlessMatchedCandidate(
                                entry: entry,
                                remote: matched,
                                primarySource: sourceRecord,
                                allSources: sources,
                                existingFindings: findings,
                                isBuiltInRetracted: isBuiltInRetracted
                            )
                        case .ambiguous(let count):
                            let detail = "OpenAlex title search returned \(count) equally matching records for '\(entry.title)'."
                            findings.append(
                                FirewallFinding(
                                    code: .registryTransportUnavailable,
                                    severity: .warning,
                                    field: "doi/arxivID/pmid",
                                    detail: detail
                                )
                            )
                            return buildUpdatedVerdict(
                                for: entry,
                                assignedClass: .unverified,
                                reasons: [CitationUnverifiedReasonCode.ambiguous.rawValue],
                                sources: sources,
                                fields: [],
                                findings: findings,
                                overrideNote: "[UNVERIFIED] \(detail)"
                            )
                        case .none:
                            break
                        }
                    case .unparseable:
                        failureReasons.append(.unparseable)
                        findings.append(
                            FirewallFinding(
                                code: .registryTransportUnavailable,
                                severity: .warning,
                                field: "network",
                                detail: "OpenAlex search payload for '\(openAlexQuery)' could not be parsed."
                            )
                        )
                    }
                } else {
                    let code = classifyHTTPFailureStatus(response.statusCode, response: response, host: "api.openalex.org")
                    failureReasons.append(code)
                    findings.append(
                        FirewallFinding(
                            code: .registryTransportUnavailable,
                            severity: .warning,
                            field: "network",
                            detail: describeHTTPFailure(source: "OpenAlex", statusCode: response.statusCode, identifier: openAlexQuery, code: code)
                        )
                    )
                }
            } catch is any FatalRegistrySessionError {
                return offlineVerdict
            } catch let budgetError as RegistryBudgetExhaustedError {
                failureReasons.append(.budgetExhausted)
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .warning,
                        field: "network",
                        detail: describeTransportError(source: "OpenAlex", code: .budgetExhausted, error: budgetError)
                    )
                )
            } catch {
                let code = classifyThrownTransportError(error)
                failureReasons.append(code)
                sources.append(
                    CitationVerdictSourceRecord(
                        source: "OpenAlex",
                        url: openAlexURL.absoluteString,
                        status: nil,
                        fetchedAt: currentISO8601Timestamp(),
                        origin: .network
                    )
                )
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .warning,
                        field: "network",
                        detail: describeTransportError(source: "OpenAlex", code: code, error: error)
                    )
                )
            }
        }

        if !failureReasons.isEmpty {
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: deduplicatedReasons(failureReasons),
                sources: sources,
                fields: [],
                findings: findings
            )
        }

        let noMatchDetail = CitationAuditWording.noMatchInSearchNotice
        findings.append(
            FirewallFinding(
                code: .registryTransportUnavailable,
                severity: .warning,
                field: "doi/arxivID/pmid",
                detail: noMatchDetail
            )
        )
        return buildUpdatedVerdict(
            for: entry,
            assignedClass: .unverified,
            reasons: [CitationUnverifiedReasonCode.noMatchInSearch.rawValue],
            sources: sources,
            fields: [],
            findings: findings,
            overrideNote: "[UNVERIFIED] \(noMatchDetail)"
        )
    }

    private enum SearchCandidateSelection {
        case none
        case single(RemoteWorkRecord)
        case ambiguous(Int)
    }

    /// Filters search candidates strictly by:
    /// 1. Normalized word-for-word title equality (`compareTitle == nil`)
    /// 2. Publication year difference `<= 1`
    /// 3. Normalized first-author surname equality (`compareFirstAuthor == nil`)
    /// Book reviews are excluded solely by these three criteria, NEVER by Crossref's `type` field.
    private func selectMatchingSearchCandidate(
        entry: BibliographyEntry,
        candidates: [RemoteWorkRecord],
        sourceName: String
    ) -> SearchCandidateSelection {
        guard let localYear = entry.year else {
            return .none
        }

        var uniqueMatches: [RemoteWorkRecord] = []
        var seenDOIs: Set<String> = []

        for candidate in candidates {
            if let candDOI = candidate.doi, !candDOI.isEmpty {
                if seenDOIs.contains(candDOI) {
                    continue
                }
            }
            guard compareTitle(localTitle: entry.title, remoteTitle: candidate.title, sourceName: sourceName).discrepancy == nil else {
                continue
            }
            guard compareFirstAuthor(localAuthors: entry.authors, remote: candidate).discrepancy == nil else {
                continue
            }
            guard let minYearDiff = candidate.publicationYears.map({ abs($0 - localYear) }).min(),
                  minYearDiff <= 1 else {
                continue
            }
            if let candDOI = candidate.doi, !candDOI.isEmpty {
                seenDOIs.insert(candDOI)
            }
            uniqueMatches.append(candidate)
        }

        if uniqueMatches.isEmpty {
            return .none
        }
        if uniqueMatches.count == 1 {
            return .single(uniqueMatches[0])
        }

        let scored: [(record: RemoteWorkRecord, secondaryMismatches: Int)] = uniqueMatches.map { cand in
            var mismatches = 0
            if compareAuthorCount(localAuthors: entry.authors, remote: cand).discrepancy != nil {
                mismatches += 1
            }
            if comparePublicationYear(localYear: entry.year, remoteYears: cand.publicationYears, sourceName: sourceName).discrepancy != nil {
                mismatches += 1
            }
            if compareVenue(localVenue: entry.venue, remoteVenues: cand.venues, sourceName: sourceName).discrepancy != nil {
                mismatches += 1
            }
            return (cand, mismatches)
        }
        let minMismatches = scored.map(\.secondaryMismatches).min() ?? 0
        let best = scored.filter { $0.secondaryMismatches == minMismatches }
        if best.count == 1 {
            return .single(best[0].record)
        }
        return .ambiguous(best.count)
    }

    private func reconcileIdentifierlessMatchedCandidate(
        entry: BibliographyEntry,
        remote: RemoteWorkRecord,
        primarySource: CitationVerdictSourceRecord,
        allSources: [CitationVerdictSourceRecord],
        existingFindings: [FirewallFinding],
        isBuiltInRetracted: Bool
    ) -> CitationFirewallEntryVerdict {
        let matchedBuiltInRetracted = isBuiltInRetracted || (remote.doi.map { retractedDOIs.contains($0) } ?? false)
        let baseVerdict = reconcileRemoteRegistryMetadata(
            entry: entry,
            remote: remote,
            primarySource: primarySource,
            allSources: allSources,
            existingFindings: existingFindings,
            isBuiltInRetracted: matchedBuiltInRetracted
        )

        guard let remoteDOI = nonEmpty(remote.doi),
              baseVerdict.firewallClass == .verified || baseVerdict.firewallClass == .drift else {
            return baseVerdict
        }

        var updatedFields = baseVerdict.fields
        if !updatedFields.contains(where: { $0.field == "doi" }) {
            updatedFields.append(
                CitationFieldDiscrepancy(
                    field: "doi",
                    localValue: "",
                    remoteValue: remoteDOI,
                    source: remote.sourceName,
                    severity: "advisory",
                    note: "Matched via \(remote.sourceName) bibliographic search; remote record provides DOI '\(remoteDOI)'."
                )
            )
        }

        let updatedNote: String
        if baseVerdict.firewallClass == .verified {
            let dateLabel = Self.shortDateLabel(from: primarySource.fetchedAt)
            updatedNote = "[VERIFIED] Matched in \(remote.sourceName), fetched \(dateLabel) (\(primarySource.origin.rawValue)); DOI: \(remoteDOI)."
        } else {
            updatedNote = "\(baseVerdict.auditNote) Matched DOI: \(remoteDOI)."
        }

        return buildUpdatedVerdict(
            for: entry,
            assignedClass: baseVerdict.firewallClass,
            reasons: baseVerdict.reasons,
            sources: baseVerdict.sources,
            fields: updatedFields,
            findings: baseVerdict.findings,
            overrideNote: updatedNote
        )
    }

    private func buildIdentifierlessCrossrefQuery(for entry: BibliographyEntry) -> String? {
        guard !Self.normalizeTitleTokensForComparison(entry.title).isEmpty else {
            return nil
        }
        let cleanTitle = Self.stripOuterRetractionMarkers(
            LaTeXTextCodec().decode(Self.stripHTMLTagsAndEntities(entry.title))
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }

        var parts: [String] = [cleanTitle]
        let namedAuthors = entry.authors.filter { !Self.isEtAlTruncationAuthor($0) }
        if let firstAuthor = namedAuthors.first {
            let cleanSurname = LaTeXTextCodec().decode(Self.stripHTMLTagsAndEntities(firstAuthor.familyName))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanSurname.isEmpty {
                parts.append(cleanSurname)
            }
        }
        if let yr = entry.year {
            parts.append(String(yr))
        }
        let combined = parts
            .joined(separator: " ")
            .replacingOccurrences(of: "@", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return combined.isEmpty ? nil : combined
    }

    private func buildOpenAlexTitleSearchQuery(for entry: BibliographyEntry) -> String? {
        let decoded = Self.stripOuterRetractionMarkers(
            LaTeXTextCodec().decode(Self.stripHTMLTagsAndEntities(entry.title))
        )
        var cleaned = ""
        cleaned.reserveCapacity(decoded.count)
        for ch in decoded {
            if ch.isLetter || ch.isNumber || ch == "-" {
                cleaned.append(ch)
            } else {
                cleaned.append(" ")
            }
        }
        let collapsed = cleaned
            .replacingOccurrences(of: "@", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    // MARK: - Non-arXiv DOI Lookup Order, Retraction Cross-Check & Handle Resolution (M1 Item 3)

    private func verifyNonArXivDOIEntry(
        entry: BibliographyEntry,
        normalizedDOI: String,
        offlineVerdict: CitationFirewallEntryVerdict,
        initialFindings: [FirewallFinding],
        isBuiltInRetracted: Bool,
        session: any CitationRegistrySession
    ) async -> CitationFirewallEntryVerdict {
        var findings = initialFindings
        var sources: [CitationVerdictSourceRecord] = []
        var crossrefReturned404 = false
        var openAlexReturned404 = false
        var failureReasons: [CitationUnverifiedReasonCode] = []

        // Pre-flight cache check so cached OpenAlex fallback or cached doi.org responseCode=100
        // resolves with 0 transport requests without re-fetching uncached 404 upstream steps.
        if cache != nil {
            if let crossrefURL = RegistryURLBuilder.crossrefWorkURL(doi: normalizedDOI),
               let cachedCrossref = lookupCachedResponse(for: crossrefURL, source: "Crossref"),
               cachedCrossref.statusCode == 200,
               case .parsed(let crossrefRemote) = parseCrossrefWorkPayload(cachedCrossref.body) {
                let sourceRecord = CitationVerdictSourceRecord(
                    source: "Crossref",
                    url: crossrefURL.absoluteString,
                    status: cachedCrossref.statusCode,
                    fetchedAt: resolvedFetchedAt(from: cachedCrossref),
                    origin: cachedCrossref.origin
                )
                sources.append(sourceRecord)
                return await crossCheckOpenAlexRetractionAndReconcile(
                    entry: entry,
                    normalizedDOI: normalizedDOI,
                    crossrefRemote: crossrefRemote,
                    crossrefSource: sourceRecord,
                    existingSources: sources,
                    existingFindings: findings,
                    offlineVerdict: offlineVerdict,
                    isBuiltInRetracted: isBuiltInRetracted,
                    session: session
                )
            }
            if let openAlexURL = RegistryURLBuilder.openAlexWorkURL(doi: normalizedDOI),
               let cachedOA = lookupCachedResponse(for: openAlexURL, source: "OpenAlex"),
               cachedOA.statusCode == 200,
               case .parsed(let oaRemote) = parseOpenAlexWorkPayload(cachedOA.body) {
                let sourceRecord = CitationVerdictSourceRecord(
                    source: "OpenAlex",
                    url: openAlexURL.absoluteString,
                    status: cachedOA.statusCode,
                    fetchedAt: resolvedFetchedAt(from: cachedOA),
                    origin: cachedOA.origin
                )
                sources.append(sourceRecord)
                return reconcileRemoteRegistryMetadata(
                    entry: entry,
                    remote: oaRemote,
                    primarySource: sourceRecord,
                    allSources: sources,
                    existingFindings: findings,
                    isBuiltInRetracted: isBuiltInRetracted
                )
            }
            if let handleURL = RegistryURLBuilder.doiHandleURL(doi: normalizedDOI),
               let cachedHandle = lookupCachedResponse(for: handleURL, source: "doi.org"),
               (cachedHandle.statusCode == 200 || cachedHandle.statusCode == 404),
               case .notRegistered = parseDOIHandlePayload(cachedHandle.body) {
                sources.append(
                    CitationVerdictSourceRecord(
                        source: "doi.org",
                        url: handleURL.absoluteString,
                        status: cachedHandle.statusCode,
                        fetchedAt: resolvedFetchedAt(from: cachedHandle),
                        origin: cachedHandle.origin
                    )
                )
                return await searchCrossrefForTypoDOICandidate(
                    entry: entry,
                    normalizedDOI: normalizedDOI,
                    existingSources: sources,
                    existingFindings: findings,
                    offlineVerdict: offlineVerdict,
                    isBuiltInRetracted: isBuiltInRetracted,
                    pendingHandleResponse: nil,
                    session: session
                )
            }
        }

        // 1. Crossref single-work lookup (`/works/<DOI>`)
        if let crossrefURL = RegistryURLBuilder.crossrefWorkURL(doi: normalizedDOI) {
            do {
                let response = try await sendRegistryRequest(URLRequest(url: crossrefURL), source: "Crossref", session: session)
                let fetchedAt = resolvedFetchedAt(from: response)
                let sourceRecord = CitationVerdictSourceRecord(
                    source: "Crossref",
                    url: crossrefURL.absoluteString,
                    status: response.statusCode,
                    fetchedAt: fetchedAt,
                    origin: response.origin
                )
                sources.append(sourceRecord)

                if response.statusCode == 200 {
                    switch parseCrossrefWorkPayload(response.body) {
                    case .parsed(let crossrefRemote):
                        if response.origin != .cache {
                            cache?.store(url: crossrefURL, statusCode: response.statusCode, body: response.body)
                        }
                        return await crossCheckOpenAlexRetractionAndReconcile(
                            entry: entry,
                            normalizedDOI: normalizedDOI,
                            crossrefRemote: crossrefRemote,
                            crossrefSource: sourceRecord,
                            existingSources: sources,
                            existingFindings: findings,
                            offlineVerdict: offlineVerdict,
                            isBuiltInRetracted: isBuiltInRetracted,
                            session: session
                        )
                    case .registeredNoMetadata:
                        failureReasons.append(.registeredNoMetadata)
                        findings.append(
                            FirewallFinding(
                                code: .registryTransportUnavailable,
                                severity: .warning,
                                field: "doi",
                                detail: "Crossref registered DOI '\(normalizedDOI)' without title metadata."
                            )
                        )
                    case .unparseable:
                        failureReasons.append(.unparseable)
                        findings.append(
                            FirewallFinding(
                                code: .registryTransportUnavailable,
                                severity: .warning,
                                field: "network",
                                detail: "Crossref payload for DOI '\(normalizedDOI)' could not be parsed."
                            )
                        )
                    }
                } else if response.statusCode == 404 {
                    crossrefReturned404 = true
                    findings.append(
                        FirewallFinding(
                            code: .registryLookupNotFound,
                            severity: .warning,
                            field: "doi",
                            detail: "Crossref reported DOI '\(normalizedDOI)' not found (status 404); checking OpenAlex."
                        )
                    )
                } else {
                    let code = classifyHTTPFailureStatus(response.statusCode, response: response, host: "api.crossref.org")
                    failureReasons.append(code)
                    findings.append(
                        FirewallFinding(
                            code: .registryTransportUnavailable,
                            severity: .warning,
                            field: "network",
                            detail: describeHTTPFailure(source: "Crossref", statusCode: response.statusCode, identifier: normalizedDOI, code: code)
                        )
                    )
                }
            } catch is any FatalRegistrySessionError {
                return offlineVerdict
            } catch {
                let code = classifyThrownTransportError(error)
                failureReasons.append(code)
                sources.append(
                    CitationVerdictSourceRecord(
                        source: "Crossref",
                        url: crossrefURL.absoluteString,
                        status: nil,
                        fetchedAt: currentISO8601Timestamp(),
                        origin: .network
                    )
                )
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .warning,
                        field: "network",
                        detail: describeTransportError(source: "Crossref", code: code, error: error) + " Attempting OpenAlex fallback."
                    )
                )
            }
        }

        // 2. OpenAlex single-work lookup (`/works/https://doi.org/<DOI>`) when Crossref did not return a valid 200 record
        if let openAlexURL = RegistryURLBuilder.openAlexWorkURL(doi: normalizedDOI) {
            do {
                let response = try await sendRegistryRequest(URLRequest(url: openAlexURL), source: "OpenAlex", session: session)
                let fetchedAt = resolvedFetchedAt(from: response)
                let sourceRecord = CitationVerdictSourceRecord(
                    source: "OpenAlex",
                    url: openAlexURL.absoluteString,
                    status: response.statusCode,
                    fetchedAt: fetchedAt,
                    origin: response.origin
                )
                sources.append(sourceRecord)

                if response.statusCode == 200 {
                    switch parseOpenAlexWorkPayload(response.body) {
                    case .parsed(let oaRemote):
                        if response.origin != .cache {
                            cache?.store(url: openAlexURL, statusCode: response.statusCode, body: response.body)
                        }
                        return reconcileRemoteRegistryMetadata(
                            entry: entry,
                            remote: oaRemote,
                            primarySource: sourceRecord,
                            allSources: sources,
                            existingFindings: findings,
                            isBuiltInRetracted: isBuiltInRetracted
                        )
                    case .registeredNoMetadata:
                        failureReasons.append(.registeredNoMetadata)
                        findings.append(
                            FirewallFinding(
                                code: .registryTransportUnavailable,
                                severity: .warning,
                                field: "doi",
                                detail: "OpenAlex registered DOI '\(normalizedDOI)' without title metadata."
                            )
                        )
                    case .unparseable:
                        failureReasons.append(.unparseable)
                        findings.append(
                            FirewallFinding(
                                code: .registryTransportUnavailable,
                                severity: .warning,
                                field: "network",
                                detail: "OpenAlex payload for DOI '\(normalizedDOI)' could not be parsed."
                            )
                        )
                    }
                } else if response.statusCode == 404 {
                    openAlexReturned404 = true
                    findings.append(
                        FirewallFinding(
                            code: .registryLookupNotFound,
                            severity: .warning,
                            field: "doi",
                            detail: "OpenAlex reported DOI '\(normalizedDOI)' not found (status 404); checking doi.org handle."
                        )
                    )
                } else {
                    let code = classifyHTTPFailureStatus(response.statusCode, response: response, host: "api.openalex.org")
                    failureReasons.append(code)
                    findings.append(
                        FirewallFinding(
                            code: .registryTransportUnavailable,
                            severity: .warning,
                            field: "network",
                            detail: describeHTTPFailure(source: "OpenAlex", statusCode: response.statusCode, identifier: normalizedDOI, code: code)
                        )
                    )
                }
            } catch is any FatalRegistrySessionError {
                return offlineVerdict
            } catch {
                let code = classifyThrownTransportError(error)
                failureReasons.append(code)
                sources.append(
                    CitationVerdictSourceRecord(
                        source: "OpenAlex",
                        url: openAlexURL.absoluteString,
                        status: nil,
                        fetchedAt: currentISO8601Timestamp(),
                        origin: .network
                    )
                )
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .warning,
                        field: "network",
                        detail: describeTransportError(source: "OpenAlex", code: code, error: error)
                    )
                )
            }
        }

        // Hard rule (M1 item 1): ANY failure prevents returning NOT_FOUND or VERIFIED.
        if !failureReasons.isEmpty {
            if isBuiltInRetracted {
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .retracted,
                    reasons: ["retracted_builtin_list"],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: deduplicatedReasons(failureReasons),
                sources: sources,
                fields: [],
                findings: findings
            )
        }

        // 3. Both Crossref and OpenAlex returned 404: ask doi.org Handle API (`/api/handles/<DOI>`)
        if crossrefReturned404 && openAlexReturned404 {
            return await resolveUnmatchedDOIViaHandleAndBibliographicSearch(
                entry: entry,
                normalizedDOI: normalizedDOI,
                existingSources: sources,
                existingFindings: findings,
                offlineVerdict: offlineVerdict,
                isBuiltInRetracted: isBuiltInRetracted,
                session: session
            )
        }

        if isBuiltInRetracted {
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .retracted,
                reasons: ["retracted_builtin_list"],
                sources: sources,
                fields: [],
                findings: findings
            )
        }

        return buildUpdatedVerdict(
            for: entry,
            assignedClass: .unverified,
            reasons: [CitationUnverifiedReasonCode.transportError.rawValue],
            sources: sources,
            fields: [],
            findings: findings
        )
    }

    /// After obtaining a Crossref 200 record by DOI, always query OpenAlex single-work (0 credits)
    /// to cross-check `is_retracted` before finalizing the verdict.
    private func crossCheckOpenAlexRetractionAndReconcile(
        entry: BibliographyEntry,
        normalizedDOI: String,
        crossrefRemote: RemoteWorkRecord,
        crossrefSource: CitationVerdictSourceRecord,
        existingSources: [CitationVerdictSourceRecord],
        existingFindings: [FirewallFinding],
        offlineVerdict: CitationFirewallEntryVerdict,
        isBuiltInRetracted: Bool,
        session: any CitationRegistrySession
    ) async -> CitationFirewallEntryVerdict {
        var sources = existingSources
        var findings = existingFindings
        var openAlexRetractionField: String?

        if let openAlexURL = RegistryURLBuilder.openAlexWorkURL(doi: normalizedDOI) {
            do {
                let oaResponse = try await sendRegistryRequest(URLRequest(url: openAlexURL), source: "OpenAlex", session: session)
                let oaFetchedAt = resolvedFetchedAt(from: oaResponse)
                sources.append(
                    CitationVerdictSourceRecord(
                        source: "OpenAlex",
                        url: openAlexURL.absoluteString,
                        status: oaResponse.statusCode,
                        fetchedAt: oaFetchedAt,
                        origin: oaResponse.origin
                    )
                )
                if oaResponse.statusCode == 200 {
                    if oaResponse.origin != .cache,
                       case .parsed = parseOpenAlexWorkPayload(oaResponse.body) {
                        cache?.store(url: openAlexURL, statusCode: oaResponse.statusCode, body: oaResponse.body)
                    }
                    openAlexRetractionField = extractOpenAlexRetractionField(oaResponse.body)
                } else if oaResponse.statusCode != 404 {
                    let oaCode = classifyHTTPFailureStatus(oaResponse.statusCode, response: oaResponse, host: "api.openalex.org")
                    findings.append(
                        FirewallFinding(
                            code: .registryTransportUnavailable,
                            severity: .advisory,
                            field: "network",
                            detail: describeHTTPFailure(source: "OpenAlex", statusCode: oaResponse.statusCode, identifier: normalizedDOI, code: oaCode)
                        )
                    )
                }
            } catch is any FatalRegistrySessionError {
                return offlineVerdict
            } catch {
                let code = classifyThrownTransportError(error)
                sources.append(
                    CitationVerdictSourceRecord(
                        source: "OpenAlex",
                        url: openAlexURL.absoluteString,
                        status: nil,
                        fetchedAt: currentISO8601Timestamp(),
                        origin: .network
                    )
                )
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .advisory,
                        field: "network",
                        detail: describeTransportError(source: "OpenAlex", code: code, error: error)
                    )
                )
            }
        }

        var retractionSignals: [(sourceName: String, field: String)] = []
        if let cfField = crossrefRemote.retractionField {
            retractionSignals.append(("Crossref", cfField))
        }
        if let oaField = openAlexRetractionField {
            retractionSignals.append(("OpenAlex", oaField))
        }

        if !retractionSignals.isEmpty {
            findings.removeAll { $0.code == .blockedRetractedWork }
            for signal in retractionSignals {
                findings.append(
                    FirewallFinding(
                        code: .blockedRetractedWork,
                        severity: .criticalBlock,
                        field: signal.field,
                        detail: "\(signal.sourceName) marks this publication as retracted (field: \(signal.field))."
                    )
                )
            }
            let reasons = retractionSignals.map { "retracted_\($0.sourceName.lowercased())" }
            let detailSummary = retractionSignals
                .map { "\($0.sourceName) marks this publication as retracted (field: \($0.field))." }
                .joined(separator: " ")
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .retracted,
                reasons: reasons,
                sources: sources,
                fields: [],
                findings: findings,
                overrideNote: "[RETRACTED] \(detailSummary)"
            )
        }

        return reconcileRemoteRegistryMetadata(
            entry: entry,
            remote: crossrefRemote,
            primarySource: crossrefSource,
            allSources: sources,
            existingFindings: findings,
            isBuiltInRetracted: isBuiltInRetracted
        )
    }

    private func resolveUnmatchedDOIViaHandleAndBibliographicSearch(
        entry: BibliographyEntry,
        normalizedDOI: String,
        existingSources: [CitationVerdictSourceRecord],
        existingFindings: [FirewallFinding],
        offlineVerdict: CitationFirewallEntryVerdict,
        isBuiltInRetracted: Bool,
        session: any CitationRegistrySession
    ) async -> CitationFirewallEntryVerdict {
        var sources = existingSources
        var findings = existingFindings

        guard let handleURL = RegistryURLBuilder.doiHandleURL(doi: normalizedDOI) else {
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [CitationUnverifiedReasonCode.transportError.rawValue],
                sources: sources,
                fields: [],
                findings: findings
            )
        }

        let handleResponse: RegistryHTTPResponse
        do {
            handleResponse = try await sendRegistryRequest(URLRequest(url: handleURL), source: "doi.org", session: session)
        } catch is any FatalRegistrySessionError {
            return offlineVerdict
        } catch {
            let code = classifyThrownTransportError(error)
            sources.append(
                CitationVerdictSourceRecord(
                    source: "doi.org",
                    url: handleURL.absoluteString,
                    status: nil,
                    fetchedAt: currentISO8601Timestamp(),
                    origin: .network
                )
            )
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .warning,
                    field: "network",
                    detail: describeTransportError(source: "doi.org", code: code, error: error)
                )
            )
            if isBuiltInRetracted {
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .retracted,
                    reasons: ["retracted_builtin_list"],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [code.rawValue],
                sources: sources,
                fields: [],
                findings: findings
            )
        }

        sources.append(
            CitationVerdictSourceRecord(
                source: "doi.org",
                url: handleURL.absoluteString,
                status: handleResponse.statusCode,
                fetchedAt: resolvedFetchedAt(from: handleResponse),
                origin: handleResponse.origin
            )
        )

        guard handleResponse.statusCode == 200 || handleResponse.statusCode == 404 else {
            let code = classifyHTTPFailureStatus(handleResponse.statusCode, response: handleResponse, host: "doi.org")
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .warning,
                    field: "network",
                    detail: describeHTTPFailure(source: "doi.org", statusCode: handleResponse.statusCode, identifier: normalizedDOI, code: code)
                )
            )
            if isBuiltInRetracted {
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .retracted,
                    reasons: ["retracted_builtin_list"],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [code.rawValue],
                sources: sources,
                fields: [],
                findings: findings
            )
        }

        switch parseDOIHandlePayload(handleResponse.body) {
        case .registered:
            if isBuiltInRetracted {
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .retracted,
                    reasons: ["retracted_builtin_list"],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }
            let detail = "doi.org reported DOI '\(normalizedDOI)' is registered (responseCode 1), but neither Crossref nor OpenAlex has bibliographic metadata."
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .warning,
                    field: "doi",
                    detail: detail
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [CitationUnverifiedReasonCode.registeredNoMetadata.rawValue],
                sources: sources,
                fields: [],
                findings: findings,
                overrideNote: "[UNVERIFIED] \(detail)"
            )

        case .serverError:
            if isBuiltInRetracted {
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .retracted,
                    reasons: ["retracted_builtin_list"],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .warning,
                    field: "network",
                    detail: "doi.org returned an internal handle error for DOI '\(normalizedDOI)'."
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [CitationUnverifiedReasonCode.serverError.rawValue],
                sources: sources,
                fields: [],
                findings: findings
            )

        case .unparseable:
            if isBuiltInRetracted {
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .retracted,
                    reasons: ["retracted_builtin_list"],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .warning,
                    field: "network",
                    detail: "doi.org handle payload for DOI '\(normalizedDOI)' could not be parsed."
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [CitationUnverifiedReasonCode.unparseable.rawValue],
                sources: sources,
                fields: [],
                findings: findings
            )

        case .notRegistered:
            let pendingHandle: (url: URL, response: RegistryHTTPResponse)? =
                (handleResponse.origin != .cache) ? (handleURL, handleResponse) : nil
            return await searchCrossrefForTypoDOICandidate(
                entry: entry,
                normalizedDOI: normalizedDOI,
                existingSources: sources,
                existingFindings: findings,
                offlineVerdict: offlineVerdict,
                isBuiltInRetracted: isBuiltInRetracted,
                pendingHandleResponse: pendingHandle,
                session: session
            )
        }
    }

    private func searchCrossrefForTypoDOICandidate(
        entry: BibliographyEntry,
        normalizedDOI: String,
        existingSources: [CitationVerdictSourceRecord],
        existingFindings: [FirewallFinding],
        offlineVerdict: CitationFirewallEntryVerdict,
        isBuiltInRetracted: Bool,
        pendingHandleResponse: (url: URL, response: RegistryHTTPResponse)?,
        session: any CitationRegistrySession
    ) async -> CitationFirewallEntryVerdict {
        var sources = existingSources
        var findings = existingFindings

        func commitHandleToCache() {
            if let pending = pendingHandleResponse, pending.response.origin != .cache {
                cache?.store(
                    url: pending.url,
                    statusCode: pending.response.statusCode,
                    body: pending.response.body
                )
            }
        }

        func makeDOINotRegisteredVerdict() -> CitationFirewallEntryVerdict {
            if isBuiltInRetracted {
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .retracted,
                    reasons: ["retracted_builtin_list"],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }
            let detail = "doi.org reported that DOI '\(normalizedDOI)' is not registered."
            findings.append(
                FirewallFinding(
                    code: .registryLookupNotFound,
                    severity: .criticalBlock,
                    field: "doi",
                    detail: detail
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .notFound,
                reasons: ["doi_not_registered"],
                sources: sources,
                fields: [],
                findings: findings,
                overrideNote: "[NOT_FOUND] \(detail)"
            )
        }

        guard let searchQuery = buildBibliographicSearchQuery(for: entry),
              let searchURL = RegistryURLBuilder.crossrefBibliographicSearchURL(query: searchQuery, rows: 5) else {
            commitHandleToCache()
            return makeDOINotRegisteredVerdict()
        }

        let searchResponse: RegistryHTTPResponse
        do {
            searchResponse = try await sendRegistryRequest(URLRequest(url: searchURL), source: "Crossref", session: session)
        } catch is any FatalRegistrySessionError {
            return offlineVerdict
        } catch {
            let code = classifyThrownTransportError(error)
            sources.append(
                CitationVerdictSourceRecord(
                    source: "Crossref",
                    url: searchURL.absoluteString,
                    status: nil,
                    fetchedAt: currentISO8601Timestamp(),
                    origin: .network
                )
            )
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .warning,
                    field: "network",
                    detail: describeTransportError(source: "Crossref", code: code, error: error)
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [code.rawValue],
                sources: sources,
                fields: [],
                findings: findings
            )
        }

        sources.append(
            CitationVerdictSourceRecord(
                source: "Crossref",
                url: searchURL.absoluteString,
                status: searchResponse.statusCode,
                fetchedAt: resolvedFetchedAt(from: searchResponse),
                origin: searchResponse.origin
            )
        )

        guard searchResponse.statusCode == 200 else {
            let code = classifyHTTPFailureStatus(searchResponse.statusCode, response: searchResponse, host: "api.crossref.org")
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .warning,
                    field: "network",
                    detail: describeHTTPFailure(source: "Crossref", statusCode: searchResponse.statusCode, identifier: searchQuery, code: code)
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [code.rawValue],
                sources: sources,
                fields: [],
                findings: findings
            )
        }

        let candidates: [RemoteWorkRecord]
        switch parseCrossrefSearchPayload(searchResponse.body) {
        case .parsed(let parsed):
            candidates = parsed
        case .unparseable:
            findings.append(
                FirewallFinding(
                    code: .registryTransportUnavailable,
                    severity: .warning,
                    field: "network",
                    detail: "Crossref bibliographic search payload for '\(searchQuery)' could not be parsed."
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                reasons: [CitationUnverifiedReasonCode.unparseable.rawValue],
                sources: sources,
                fields: [],
                findings: findings
            )
        }

        var uniqueMatches: [RemoteWorkRecord] = []
        var seenDOIs: Set<String> = []
        for candidate in candidates {
            guard let candDOI = candidate.doi, !candDOI.isEmpty, !seenDOIs.contains(candDOI) else {
                continue
            }
            guard compareTitle(localTitle: entry.title, remoteTitle: candidate.title, sourceName: "Crossref").discrepancy == nil else {
                continue
            }
            guard compareFirstAuthor(localAuthors: entry.authors, remote: candidate).discrepancy == nil else {
                continue
            }
            guard let localYear = entry.year,
                  let minYearDiff = candidate.publicationYears.map({ abs($0 - localYear) }).min(),
                  minYearDiff <= 1 else {
                continue
            }
            seenDOIs.insert(candDOI)
            uniqueMatches.append(candidate)
        }

        guard !uniqueMatches.isEmpty else {
            commitHandleToCache()
            return makeDOINotRegisteredVerdict()
        }

        let matchedCandidate: RemoteWorkRecord
        if uniqueMatches.count == 1 {
            matchedCandidate = uniqueMatches[0]
        } else {
            // Disambiguate using remaining local fields (authorCount, exact year, venue); if tied, report `ambiguous`.
            let scored: [(record: RemoteWorkRecord, secondaryMismatches: Int)] = uniqueMatches.map { cand in
                var mismatches = 0
                if compareAuthorCount(localAuthors: entry.authors, remote: cand).discrepancy != nil {
                    mismatches += 1
                }
                if comparePublicationYear(localYear: entry.year, remoteYears: cand.publicationYears, sourceName: "Crossref").discrepancy != nil {
                    mismatches += 1
                }
                if compareVenue(localVenue: entry.venue, remoteVenues: cand.venues, sourceName: "Crossref").discrepancy != nil {
                    mismatches += 1
                }
                return (cand, mismatches)
            }
            let minMismatches = scored.map(\.secondaryMismatches).min() ?? 0
            let best = scored.filter { $0.secondaryMismatches == minMismatches }
            guard best.count == 1 else {
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .warning,
                        field: "doi",
                        detail: "Crossref bibliographic search returned \(best.count) equally matching works for '\(entry.title)'."
                    )
                )
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .unverified,
                    reasons: [CitationUnverifiedReasonCode.ambiguous.rawValue],
                    sources: sources,
                    fields: [],
                    findings: findings
                )
            }
            matchedCandidate = best[0].record
        }

        commitHandleToCache()
        if searchResponse.origin != .cache {
            cache?.store(url: searchURL, statusCode: searchResponse.statusCode, body: searchResponse.body)
        }

        let matchedDOI = matchedCandidate.doi ?? ""
        if let retField = matchedCandidate.retractionField {
            findings.removeAll { $0.code == .blockedRetractedWork }
            let detail = "Crossref marks this publication as retracted (field: \(retField))."
            findings.append(
                FirewallFinding(
                    code: .blockedRetractedWork,
                    severity: .criticalBlock,
                    field: retField,
                    detail: detail
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .retracted,
                reasons: ["retracted_crossref"],
                sources: sources,
                fields: [],
                findings: findings,
                overrideNote: "[RETRACTED] \(detail)"
            )
        }
        if retractedDOIs.contains(matchedDOI) {
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .retracted,
                reasons: ["retracted_builtin_list"],
                sources: sources,
                fields: [],
                findings: findings
            )
        }

        let localDOIDisplay = nonEmpty(entry.doi) ?? normalizedDOI
        var discrepancies: [CitationFieldDiscrepancy] = [
            CitationFieldDiscrepancy(
                field: "doi",
                localValue: localDOIDisplay,
                remoteValue: matchedDOI,
                source: "Crossref",
                severity: "error",
                note: "doi.org reported local DOI '\(normalizedDOI)' is not registered; Crossref bibliographic search matched DOI '\(matchedDOI)'."
            )
        ]
        var driftReasons: [String] = ["doi_mismatch"]

        let secondaryChecks: [(CitationFieldDiscrepancy?, String?)] = [
            compareAuthorCount(localAuthors: entry.authors, remote: matchedCandidate),
            comparePublicationYear(localYear: entry.year, remoteYears: matchedCandidate.publicationYears, sourceName: "Crossref"),
            compareVenue(localVenue: entry.venue, remoteVenues: matchedCandidate.venues, sourceName: "Crossref")
        ]
        for (disc, reason) in secondaryChecks {
            if let disc {
                discrepancies.append(disc)
            }
            if let reason, !driftReasons.contains(reason) {
                driftReasons.append(reason)
            }
        }

        let driftSummary = formatEnglishDriftSummary(discrepancies: discrepancies, sourceName: "Crossref")
        findings.append(
            FirewallFinding(
                code: .metadataDriftDetected,
                severity: .warning,
                field: "doi",
                detail: driftSummary
            )
        )
        return buildUpdatedVerdict(
            for: entry,
            assignedClass: .drift,
            reasons: driftReasons,
            sources: sources,
            fields: discrepancies,
            findings: findings,
            overrideNote: "[DRIFT] \(driftSummary)"
        )
    }

    private func buildBibliographicSearchQuery(for entry: BibliographyEntry) -> String? {
        guard !Self.normalizeTitleTokensForComparison(entry.title).isEmpty else {
            return nil
        }
        let namedAuthors = entry.authors.filter { !Self.isEtAlTruncationAuthor($0) }
        guard let firstAuthor = namedAuthors.first else {
            return nil
        }
        let cleanTitle = Self.stripOuterRetractionMarkers(
            LaTeXTextCodec().decode(Self.stripHTMLTagsAndEntities(entry.title))
        )
        let cleanSurname = LaTeXTextCodec().decode(Self.stripHTMLTagsAndEntities(firstAuthor.familyName))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanSurname.isEmpty else {
            return nil
        }
        let combined = "\(cleanTitle) \(cleanSurname)"
            .replacingOccurrences(of: "@", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return combined.isEmpty ? nil : combined
    }

    // MARK: - Deterministic Field Comparison Rules (M1 Item 2: S36, S37, S38, S50)

    struct RemoteWorkRecord: Sendable {
        let sourceName: String
        let doi: String?
        let title: String
        let firstAuthorDisplay: String?
        let firstAuthorSurname: String?
        let firstAuthorFullName: String?
        let firstAuthorHasExplicitFamilyField: Bool
        let firstAuthorIsCorporate: Bool
        let authorSurnames: [String]
        let publicationYears: [Int]
        let venues: [String]
        let retractionField: String?
    }

    private enum RegistryPayloadParseOutcome {
        case parsed(RemoteWorkRecord)
        case registeredNoMetadata
        case unparseable
    }

    private enum DOIHandleParseOutcome {
        case registered
        case notRegistered
        case serverError
        case unparseable
    }

    private enum CrossrefSearchParseOutcome {
        case parsed([RemoteWorkRecord])
        case unparseable
    }

    private enum ArXivPayloadParseOutcome {
        case parsed(RemoteWorkRecord)
        case notFound
        case unparseable
    }

    private enum PubMedPayloadParseOutcome {
        case parsed(RemoteWorkRecord)
        case notFound(String)
        case registeredNoMetadata
        case rateLimited
        case unparseable
    }

    private static let leadingRetractionPrefixes: [String] = [
        "retracted article:",
        "retracted paper:",
        "retraction notice:",
        "retraction of:",
        "retracted:",
        "retraction:",
        "withdrawn:",
        "[retracted article]",
        "[retracted]",
        "(retracted)",
        "[withdrawn]",
        "(withdrawn)"
    ]

    private static let trailingRetractionSuffixes: [String] = [
        "[retracted article]",
        "[retracted]",
        "(retracted)",
        "- retracted",
        "[withdrawn]",
        "(withdrawn)",
        "- withdrawn"
    ]

    private static let venueStopwords: Set<String> = [
        "the", "of", "on", "in", "for", "and", "to", "a", "an", "at", "by", "from", "with"
    ]

    private static let knownVenueAcronymExpansions: [String: String] = [
        "pnas": "proceedings of the national academy of sciences",
        "jmlr": "journal of machine learning research",
        "neurips": "advances in neural information processing systems",
        "nips": "advances in neural information processing systems",
        "icml": "international conference on machine learning",
        "iclr": "international conference on learning representations",
        "cvpr": "conference on computer vision and pattern recognition",
        "iccv": "international conference on computer vision",
        "eccv": "european conference on computer vision",
        "acl": "annual meeting of the association for computational linguistics",
        "emnlp": "conference on empirical methods in natural language processing",
        "naacl": "conference of the north american chapter of the association for computational linguistics",
        "aaai": "aaai conference on artificial intelligence",
        "ijcai": "international joint conference on artificial intelligence",
        "cacm": "communications of the acm",
        "jacm": "journal of the acm",
        "tpami": "ieee transactions on pattern analysis and machine intelligence",
        "pami": "ieee transactions on pattern analysis and machine intelligence",
        "ijcv": "international journal of computer vision",
        "tacl": "transactions of the association for computational linguistics",
        "vldb": "proceedings of the vldb endowment",
        "nejm": "new england journal of medicine",
        "jama": "journal of the american medical association",
        "bmj": "british medical journal"
    ]

    private static let knownISO4AbbreviationStems: Set<String> = [
        "proc", "j", "trans", "comput", "comp", "natl", "nat", "acad", "sci",
        "int", "intl", "conf", "symp", "annu", "ann", "rev", "lett", "commun",
        "bull", "soc", "amer", "am", "eur", "phys", "chem", "biol", "biomed",
        "med", "eng", "math", "stat", "appl", "res", "syst", "netw", "inf",
        "inform", "mach", "learn", "intell", "artif", "anal", "patt", "recog",
        "softw", "lang", "prog", "oper", "mag", "univ", "clin", "exp", "mol",
        "cell", "genet", "psychol", "philos", "econ", "mgmt", "manag", "tech",
        "technol", "elektron", "opt", "quant", "theor", "astron", "astrophys",
        "geophys", "ecol", "evol", "neurosci", "pharmacol", "toxicol"
    ]

    /// Normalizes a scholarly title into lowercase alphanumeric words after stripping HTML tags,
    /// LaTeX formatting/diacritics/braces/math, and leading/trailing retraction markers.
    public static func normalizeTitleTokensForComparison(_ rawTitle: String) -> [String] {
        if rawTitle.isEmpty { return [] }
        let htmlStripped = stripHTMLTagsAndEntities(rawTitle)
        let latexDecoded = LaTeXTextCodec().decode(htmlStripped)
        let retractionStripped = stripOuterRetractionMarkers(latexDecoded)
        let folded = foldLigaturesAndDiacritics(retractionStripped)
        return splitAlphanumericWords(folded)
    }

    /// Word-by-word title comparison (no Jaro-Winkler). Missing local title or any word difference yields `DRIFT`.
    func compareTitle(
        localTitle: String,
        remoteTitle: String,
        sourceName: String
    ) -> (discrepancy: CitationFieldDiscrepancy?, reason: String?) {
        let trimmedLocal = localTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLocal.isEmpty {
            return (
                CitationFieldDiscrepancy(
                    field: "title",
                    localValue: "",
                    remoteValue: remoteTitle,
                    source: sourceName,
                    severity: "error",
                    note: "Missing local title."
                ),
                "missing_title"
            )
        }

        let localWords = Self.normalizeTitleTokensForComparison(trimmedLocal)
        let remoteWords = Self.normalizeTitleTokensForComparison(remoteTitle)

        if localWords.isEmpty {
            return (
                CitationFieldDiscrepancy(
                    field: "title",
                    localValue: trimmedLocal,
                    remoteValue: remoteTitle,
                    source: sourceName,
                    severity: "error",
                    note: "Missing local title."
                ),
                "missing_title"
            )
        }

        guard localWords == remoteWords else {
            return (
                CitationFieldDiscrepancy(
                    field: "title",
                    localValue: trimmedLocal,
                    remoteValue: remoteTitle,
                    source: sourceName,
                    severity: "error",
                    note: "Title differs word-for-word from \(sourceName) record."
                ),
                "title_mismatch"
            )
        }
        return (nil, nil)
    }

    /// Exact normalized first-author surname (or full corporate name) equality check (no Jaro-Winkler).
    func compareFirstAuthor(
        localAuthors: [BibAuthor],
        remote: RemoteWorkRecord
    ) -> (discrepancy: CitationFieldDiscrepancy?, reason: String?) {
        let namedLocalAuthors = localAuthors.filter { !Self.isEtAlTruncationAuthor($0) }
        let remoteDisplay = remote.firstAuthorDisplay ?? remote.firstAuthorSurname ?? ""

        guard let localFirst = namedLocalAuthors.first,
              !localFirst.familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (
                CitationFieldDiscrepancy(
                    field: "firstAuthor",
                    localValue: "",
                    remoteValue: remoteDisplay,
                    source: remote.sourceName,
                    severity: "error",
                    note: "Missing local first author."
                ),
                "missing_first_author"
            )
        }

        guard !remoteDisplay.isEmpty else {
            return (nil, nil)
        }

        let localIsCorporate = localFirst.givenName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && localFirst.familyName.trimmingCharacters(in: .whitespacesAndNewlines).contains(" ")

        if remote.firstAuthorIsCorporate || localIsCorporate {
            let remoteCorpCandidate = remote.firstAuthorIsCorporate
                ? remoteDisplay
                : (remote.firstAuthorFullName ?? remoteDisplay)
            let localFull = Self.normalizeCorporateOrAuthorToken(localFirst.description)
            let remoteFull = Self.normalizeCorporateOrAuthorToken(remoteCorpCandidate)
            guard !localFull.isEmpty, localFull == remoteFull else {
                return (
                    CitationFieldDiscrepancy(
                        field: "firstAuthor",
                        localValue: localFirst.description,
                        remoteValue: remoteCorpCandidate,
                        source: remote.sourceName,
                        severity: "error",
                        note: "Corporate/institutional first author differs from \(remote.sourceName)."
                    ),
                    "first_author_mismatch"
                )
            }
            return (nil, nil)
        }

        let localNormSurname = Self.normalizeCorporateOrAuthorToken(localFirst.familyName)
        let remoteSurnameRaw = remote.firstAuthorSurname ?? remoteDisplay
        let remoteNormSurname = Self.normalizeCorporateOrAuthorToken(remoteSurnameRaw)

        if !localNormSurname.isEmpty && localNormSurname == remoteNormSurname {
            return (nil, nil)
        }

        // Compound surname check (S37, e.g. "García Márquez") when remote source (OpenAlex/arXiv)
        // only exposes an uncomma'd full name string ("Gabriel García Márquez") without separate family field.
        if !remote.firstAuthorHasExplicitFamilyField,
           let rawFull = remote.firstAuthorFullName,
           !rawFull.contains(",") {
            let localSurnameWords = Self.splitAlphanumericWords(
                Self.foldLigaturesAndDiacritics(LaTeXTextCodec().decode(localFirst.familyName))
            )
            let remoteFullWords = Self.splitAlphanumericWords(
                Self.foldLigaturesAndDiacritics(LaTeXTextCodec().decode(rawFull))
            )
            if localSurnameWords.count >= 2,
               remoteFullWords.count > localSurnameWords.count,
               Array(remoteFullWords.suffix(localSurnameWords.count)) == localSurnameWords {
                return (nil, nil)
            }
        }

        return (
            CitationFieldDiscrepancy(
                field: "firstAuthor",
                localValue: localFirst.familyName,
                remoteValue: remoteSurnameRaw,
                source: remote.sourceName,
                severity: "error",
                note: "First author surname '\(localFirst.familyName)' differs from \(remote.sourceName) '\(remoteSurnameRaw)'."
            ),
            "first_author_mismatch"
        )
    }

    /// Author count and `and others` (`et al.`) prefix check.
    func compareAuthorCount(
        localAuthors: [BibAuthor],
        remote: RemoteWorkRecord
    ) -> (discrepancy: CitationFieldDiscrepancy?, reason: String?) {
        let namedLocalAuthors = localAuthors.filter { !Self.isEtAlTruncationAuthor($0) }
        let hasEtAlTruncation = localAuthors.contains(where: Self.isEtAlTruncationAuthor)

        // Missing local author list is already reported by `compareFirstAuthor`.
        guard !namedLocalAuthors.isEmpty, !remote.authorSurnames.isEmpty else {
            return (nil, nil)
        }

        if hasEtAlTruncation {
            if namedLocalAuthors.count > remote.authorSurnames.count {
                return (
                    CitationFieldDiscrepancy(
                        field: "authorCount",
                        localValue: "\(namedLocalAuthors.count)+",
                        remoteValue: "\(remote.authorSurnames.count)",
                        source: remote.sourceName,
                        severity: "error",
                        note: "Listed author prefix count (\(namedLocalAuthors.count)) exceeds \(remote.sourceName) total authors (\(remote.authorSurnames.count))."
                    ),
                    "author_count_mismatch"
                )
            }
            // Index 0 was already checked by `compareFirstAuthor`; check remaining prefix authors.
            if namedLocalAuthors.count > 1 {
                for idx in 1..<namedLocalAuthors.count {
                    let localSur = Self.normalizeCorporateOrAuthorToken(namedLocalAuthors[idx].familyName)
                    let remoteSur = Self.normalizeCorporateOrAuthorToken(remote.authorSurnames[idx])
                    if localSur != remoteSur {
                        return (
                            CitationFieldDiscrepancy(
                                field: "authors",
                                localValue: namedLocalAuthors[idx].familyName,
                                remoteValue: remote.authorSurnames[idx],
                                source: remote.sourceName,
                                severity: "error",
                                note: "Author #\(idx + 1) in 'and others' prefix differs from \(remote.sourceName)."
                            ),
                            "author_prefix_mismatch"
                        )
                    }
                }
            }
            return (nil, nil)
        }

        if namedLocalAuthors.count != remote.authorSurnames.count {
            return (
                CitationFieldDiscrepancy(
                    field: "authorCount",
                    localValue: "\(namedLocalAuthors.count)",
                    remoteValue: "\(remote.authorSurnames.count)",
                    source: remote.sourceName,
                    severity: "error",
                    note: "Local author count (\(namedLocalAuthors.count)) differs from \(remote.sourceName) (\(remote.authorSurnames.count))."
                ),
                "author_count_mismatch"
            )
        }
        return (nil, nil)
    }

    /// Multi-date publication year comparison (`published-print`, `published-online`, `issued`).
    /// Diff == 1 carries the online-first vs. print-issue explanation; diff >= 2 is marked as error.
    func comparePublicationYear(
        localYear: Int?,
        remoteYears: [Int],
        sourceName: String
    ) -> (discrepancy: CitationFieldDiscrepancy?, reason: String?) {
        guard let localYear else {
            let remoteStr = remoteYears.first.map(String.init) ?? ""
            return (
                CitationFieldDiscrepancy(
                    field: "year",
                    localValue: "",
                    remoteValue: remoteStr,
                    source: sourceName,
                    severity: "error",
                    note: "Missing local publication year."
                ),
                "missing_year"
            )
        }

        guard !remoteYears.isEmpty else {
            return (nil, nil)
        }

        if remoteYears.contains(localYear) {
            return (nil, nil)
        }

        let closestYear = remoteYears.min(by: { abs($0 - localYear) < abs($1 - localYear) }) ?? remoteYears[0]
        let diff = abs(localYear - closestYear)
        let allRemoteDatesLabel = remoteYears.map(String.init).joined(separator: "/")

        if diff == 1 {
            return (
                CitationFieldDiscrepancy(
                    field: "year",
                    localValue: "\(localYear)",
                    remoteValue: "\(closestYear)",
                    source: sourceName,
                    severity: "warning",
                    note: "Local year \(localYear) differs by 1 year from \(sourceName) (\(allRemoteDatesLabel)); \(CitationAuditWording.yearOnlineVsPrintNotice)."
                ),
                "year_diff_1"
            )
        }

        return (
            CitationFieldDiscrepancy(
                field: "year",
                localValue: "\(localYear)",
                remoteValue: "\(closestYear)",
                source: sourceName,
                severity: "error",
                note: "Local year \(localYear) differs by \(diff) years from \(sourceName) (\(allRemoteDatesLabel)) (error)."
            ),
            "year_mismatch"
        )
    }

    /// Venue / journal / conference comparison supporting ISO-4 abbreviations and standard acronyms.
    /// Skipped when either local or remote has no venue (e.g., arXiv preprints without `journal_ref`).
    func compareVenue(
        localVenue: String,
        remoteVenues: [String],
        sourceName: String
    ) -> (discrepancy: CitationFieldDiscrepancy?, reason: String?) {
        let trimmedLocal = localVenue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLocal.isEmpty, !remoteVenues.isEmpty else {
            return (nil, nil)
        }
        let lowerLocal = trimmedLocal.lowercased()
        if sourceName == "arXiv" && (lowerLocal == "arxiv" || lowerLocal.hasPrefix("arxiv:") || lowerLocal == "corr") {
            return (nil, nil)
        }

        if venuesMatch(trimmedLocal, remoteVenues) {
            return (nil, nil)
        }

        return (
            CitationFieldDiscrepancy(
                field: "venue",
                localValue: trimmedLocal,
                remoteValue: remoteVenues[0],
                source: sourceName,
                severity: "error",
                note: "Local venue '\(trimmedLocal)' differs from \(sourceName) '\(remoteVenues[0])'."
            ),
            "venue_mismatch"
        )
    }

    /// Checks whether `localVenue` matches any candidate in `remoteVenues` under normalized full name,
    /// acronym expansion, or ISO-4 token abbreviation alignment.
    func venuesMatch(_ localVenue: String, _ remoteVenues: [String]) -> Bool {
        let localCandidates = Self.venueTokenCandidates(for: localVenue)
        if localCandidates.isEmpty { return true }

        for remoteRaw in remoteVenues {
            let remoteCandidates = Self.venueTokenCandidates(for: remoteRaw)
            for lTokens in localCandidates {
                for rTokens in remoteCandidates {
                    if Self.venueTokenSequenceMatches(lTokens, rTokens) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func reconcileRemoteRegistryMetadata(
        entry: BibliographyEntry,
        remote: RemoteWorkRecord,
        primarySource: CitationVerdictSourceRecord,
        allSources: [CitationVerdictSourceRecord],
        existingFindings: [FirewallFinding],
        isBuiltInRetracted: Bool
    ) -> CitationFirewallEntryVerdict {
        var findings = existingFindings

        if let retractionField = remote.retractionField {
            // Remove offline built-in retraction hint if the live registry record itself carries retraction metadata.
            findings.removeAll {
                $0.code == .blockedRetractedWork && $0.detail.contains(CitationAuditWording.builtInRetractionListNotice)
            }
            let detail = "\(remote.sourceName) marks this publication as retracted (field: \(retractionField))."
            findings.append(
                FirewallFinding(
                    code: .blockedRetractedWork,
                    severity: .criticalBlock,
                    field: retractionField,
                    detail: detail
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .retracted,
                reasons: ["retracted_\(remote.sourceName.lowercased())"],
                sources: allSources,
                fields: [],
                findings: findings,
                overrideNote: "[RETRACTED] \(detail)"
            )
        }

        if isBuiltInRetracted {
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .retracted,
                reasons: ["retracted_builtin_list"],
                sources: allSources,
                fields: [],
                findings: findings
            )
        }

        var discrepancies: [CitationFieldDiscrepancy] = []
        var driftReasons: [String] = []

        let checks: [(CitationFieldDiscrepancy?, String?)] = [
            compareTitle(localTitle: entry.title, remoteTitle: remote.title, sourceName: remote.sourceName),
            compareFirstAuthor(localAuthors: entry.authors, remote: remote),
            compareAuthorCount(localAuthors: entry.authors, remote: remote),
            comparePublicationYear(localYear: entry.year, remoteYears: remote.publicationYears, sourceName: remote.sourceName),
            compareVenue(localVenue: entry.venue, remoteVenues: remote.venues, sourceName: remote.sourceName)
        ]

        for (disc, reason) in checks {
            if let disc {
                discrepancies.append(disc)
            }
            if let reason, !driftReasons.contains(reason) {
                driftReasons.append(reason)
            }
        }

        if !discrepancies.isEmpty {
            let driftSummary = formatEnglishDriftSummary(discrepancies: discrepancies, sourceName: remote.sourceName)
            findings.append(
                FirewallFinding(
                    code: .metadataDriftDetected,
                    severity: .warning,
                    field: "metadata",
                    detail: driftSummary
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .drift,
                reasons: driftReasons,
                sources: allSources,
                fields: discrepancies,
                findings: findings,
                overrideNote: "[DRIFT] \(driftSummary)"
            )
        }

        let dateLabel = Self.shortDateLabel(from: primarySource.fetchedAt)
        let verifiedDetail = "Matched in \(remote.sourceName), fetched \(dateLabel) (\(primarySource.origin.rawValue))."
        findings.append(
            FirewallFinding(
                code: .registryVerifiedMatch,
                severity: .pass,
                field: "registry",
                detail: verifiedDetail
            )
        )
        return buildUpdatedVerdict(
            for: entry,
            assignedClass: .verified,
            reasons: ["verified_match"],
            sources: allSources,
            fields: [],
            findings: findings,
            overrideNote: "[VERIFIED] \(verifiedDetail)"
        )
    }

    // MARK: - Private Registry Payload Parsers (Crossref, OpenAlex, doi.org, arXiv)

    private func parseCrossrefWorkPayload(_ data: Data) -> RegistryPayloadParseOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unparseable
        }
        let message: [String: Any]
        if let msg = root["message"] as? [String: Any] {
            message = msg
        } else if root["DOI"] != nil || root["title"] != nil {
            message = root
        } else {
            return .unparseable
        }
        return parseCrossrefWorkObject(message)
    }

    private func parseCrossrefSearchPayload(_ data: Data) -> CrossrefSearchParseOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]] else {
            return .unparseable
        }
        var records: [RemoteWorkRecord] = []
        records.reserveCapacity(items.count)
        for item in items {
            if case .parsed(let record) = parseCrossrefWorkObject(item) {
                records.append(record)
            }
        }
        return .parsed(records)
    }

    private func parseCrossrefWorkObject(_ message: [String: Any]) -> RegistryPayloadParseOutcome {
        let title: String = {
            if let titles = message["title"] as? [String], let first = titles.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return first.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let single = message["title"] as? String {
                return single.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }()
        guard !title.isEmpty else {
            return .registeredNoMetadata
        }

        let normalizedDOI = ReferenceIdentifierNormalizer.normalizeDOI(message["DOI"] as? String)

        var firstAuthorDisplay: String?
        var firstAuthorSurname: String?
        var firstAuthorFullName: String?
        var firstAuthorHasExplicitFamilyField = false
        var firstAuthorIsCorporate = false
        var authorSurnames: [String] = []

        if let authors = message["author"] as? [[String: Any]], !authors.isEmpty {
            let firstIdx = authors.firstIndex {
                (($0["sequence"] as? String)?.lowercased() == "first")
            } ?? 0
            let firstObj = authors[firstIdx]
            if let fam = nonEmpty(firstObj["family"] as? String) {
                firstAuthorDisplay = fam
                firstAuthorSurname = fam
                if let giv = nonEmpty(firstObj["given"] as? String) {
                    firstAuthorFullName = "\(giv) \(fam)"
                } else {
                    firstAuthorFullName = fam
                }
                firstAuthorHasExplicitFamilyField = true
                firstAuthorIsCorporate = false
            } else if let corpName = nonEmpty(firstObj["name"] as? String) {
                firstAuthorDisplay = corpName
                firstAuthorSurname = corpName
                firstAuthorFullName = corpName
                firstAuthorHasExplicitFamilyField = false
                firstAuthorIsCorporate = true
            }

            // Order `sequence == "first"` at index 0, followed by remaining authors in array order.
            var orderedIndices = [firstIdx]
            for idx in authors.indices where idx != firstIdx {
                orderedIndices.append(idx)
            }
            for idx in orderedIndices {
                let item = authors[idx]
                if let fam = nonEmpty(item["family"] as? String) {
                    authorSurnames.append(fam)
                } else if let name = nonEmpty(item["name"] as? String) {
                    authorSurnames.append(name)
                }
            }
        }

        // Collect all publication dates (`published-print`, `published-online`, `issued`), fallback `published`.
        // Never treat Crossref deposit date `created` as publication year.
        var publicationYears: [Int] = []
        for dateKey in ["published-print", "published-online", "issued"] {
            if let yr = extractCrossrefDateYear(message[dateKey]), !publicationYears.contains(yr) {
                publicationYears.append(yr)
            }
        }
        if publicationYears.isEmpty, let yr = extractCrossrefDateYear(message["published"]) {
            publicationYears.append(yr)
        }

        var venues: [String] = []
        for venueKey in ["container-title", "short-container-title"] {
            if let arr = message[venueKey] as? [String] {
                for item in arr {
                    if let v = nonEmpty(item), !venues.contains(v) {
                        venues.append(v)
                    }
                }
            } else if let single = nonEmpty(message[venueKey] as? String), !venues.contains(single) {
                venues.append(single)
            }
        }

        var retractionField: String?
        if let updates = message["update-to"] as? [[String: Any]],
           updates.contains(where: { (($0["type"] as? String)?.lowercased() ?? "").contains("retraction") }) {
            retractionField = "update-to"
        } else if let updatedBy = message["updated-by"] as? [[String: Any]],
                  updatedBy.contains(where: { (($0["type"] as? String)?.lowercased() ?? "").contains("retraction") }) {
            retractionField = "updated-by"
        } else if let relation = message["relation"] as? [String: Any],
                  let retractedBy = relation["is-retracted-by"] {
            if let arr = retractedBy as? [Any], !arr.isEmpty {
                retractionField = "relation.is-retracted-by"
            } else if let dict = retractedBy as? [String: Any], !dict.isEmpty {
                retractionField = "relation.is-retracted-by"
            } else if nonEmpty(retractedBy as? String) != nil {
                retractionField = "relation.is-retracted-by"
            }
        }

        return .parsed(
            RemoteWorkRecord(
                sourceName: "Crossref",
                doi: normalizedDOI,
                title: title,
                firstAuthorDisplay: firstAuthorDisplay,
                firstAuthorSurname: firstAuthorSurname,
                firstAuthorFullName: firstAuthorFullName,
                firstAuthorHasExplicitFamilyField: firstAuthorHasExplicitFamilyField,
                firstAuthorIsCorporate: firstAuthorIsCorporate,
                authorSurnames: authorSurnames,
                publicationYears: publicationYears,
                venues: venues,
                retractionField: retractionField
            )
        )
    }

    private func parseDOIHandlePayload(_ data: Data) -> DOIHandleParseOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unparseable
        }
        let code: Int? = {
            if let intVal = root["responseCode"] as? Int {
                return intVal
            }
            if let numVal = root["responseCode"] as? NSNumber {
                return numVal.intValue
            }
            return nil
        }()
        guard let code else {
            return .unparseable
        }
        switch code {
        case 100:
            return .notRegistered
        case 1, 200:
            return .registered
        case 2, 300, 301:
            return .serverError
        default:
            return .unparseable
        }
    }

    private func extractOpenAlexRetractionField(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if (root["is_retracted"] as? Bool) == true {
            return "is_retracted"
        }
        if let num = root["is_retracted"] as? NSNumber, num.boolValue {
            return "is_retracted"
        }
        return nil
    }

    private func parseOpenAlexWorkPayload(_ data: Data) -> RegistryPayloadParseOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unparseable
        }
        return parseOpenAlexWorkObject(root)
    }

    private func parseOpenAlexSearchPayload(_ data: Data) -> CrossrefSearchParseOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            return .unparseable
        }
        var records: [RemoteWorkRecord] = []
        records.reserveCapacity(results.count)
        for item in results {
            if case .parsed(let record) = parseOpenAlexWorkObject(item) {
                records.append(record)
            }
        }
        return .parsed(records)
    }

    private func parseOpenAlexWorkObject(_ root: [String: Any]) -> RegistryPayloadParseOutcome {
        guard root["id"] != nil || root["title"] != nil || root["display_name"] != nil else {
            return .unparseable
        }
        let title = nonEmpty(root["title"] as? String) ?? nonEmpty(root["display_name"] as? String) ?? ""
        guard !title.isEmpty else {
            return .registeredNoMetadata
        }

        let normalizedDOI = ReferenceIdentifierNormalizer.normalizeDOI(root["doi"] as? String)

        var publicationYears: [Int] = []
        if let yr = root["publication_year"] as? Int {
            publicationYears.append(yr)
        } else if let pubDate = nonEmpty(root["publication_date"] as? String),
                  pubDate.count >= 4,
                  let yr = Int(pubDate.prefix(4)) {
            publicationYears.append(yr)
        }

        let isRetracted = (root["is_retracted"] as? Bool) ?? false

        var firstAuthorDisplay: String?
        var firstAuthorSurname: String?
        var firstAuthorFullName: String?
        var authorSurnames: [String] = []

        if let authorships = root["authorships"] as? [[String: Any]], !authorships.isEmpty {
            for (idx, item) in authorships.enumerated() {
                // M1 item 2 (S50): prefer `raw_author_name`, falling back to `author.display_name`.
                let rawName = nonEmpty(item["raw_author_name"] as? String)
                let displayName = nonEmpty((item["author"] as? [String: Any])?["display_name"] as? String)
                let chosen = rawName ?? displayName
                if let chosen, let extracted = Self.extractSurnameFromAuthorString(chosen) {
                    authorSurnames.append(extracted)
                    if idx == 0 {
                        firstAuthorDisplay = extracted
                        firstAuthorSurname = extracted
                        firstAuthorFullName = chosen
                    }
                } else if let fallback = displayName, let extracted = Self.extractSurnameFromAuthorString(fallback) {
                    authorSurnames.append(extracted)
                    if idx == 0 {
                        firstAuthorDisplay = extracted
                        firstAuthorSurname = extracted
                        firstAuthorFullName = fallback
                    }
                }
            }
        }

        var venues: [String] = []
        if let primaryLoc = root["primary_location"] as? [String: Any],
           let sourceObj = primaryLoc["source"] as? [String: Any] {
            if let disp = nonEmpty(sourceObj["display_name"] as? String) {
                venues.append(disp)
            }
            if let abbr = nonEmpty(sourceObj["abbreviated_title"] as? String), !venues.contains(abbr) {
                venues.append(abbr)
            }
            if let alts = sourceObj["alternate_titles"] as? [String] {
                for alt in alts {
                    if let cleanAlt = nonEmpty(alt), !venues.contains(cleanAlt) {
                        venues.append(cleanAlt)
                    }
                }
            }
        }
        if let hostVenue = root["host_venue"] as? [String: Any],
           let disp = nonEmpty(hostVenue["display_name"] as? String),
           !venues.contains(disp) {
            venues.append(disp)
        }

        return .parsed(
            RemoteWorkRecord(
                sourceName: "OpenAlex",
                doi: normalizedDOI,
                title: title,
                firstAuthorDisplay: firstAuthorDisplay,
                firstAuthorSurname: firstAuthorSurname,
                firstAuthorFullName: firstAuthorFullName,
                firstAuthorHasExplicitFamilyField: false,
                firstAuthorIsCorporate: false,
                authorSurnames: authorSurnames,
                publicationYears: publicationYears,
                venues: venues,
                retractionField: isRetracted ? "is_retracted" : nil
            )
        )
    }

    private func parseArXivAtomPayload(_ data: Data) -> ArXivPayloadParseOutcome {
        guard let xml = String(data: data, encoding: .utf8),
              xml.contains("<feed"),
              xml.contains("</feed>") else {
            return .unparseable
        }

        let totalResultsRaw = extractXMLTagValue("opensearch:totalResults", in: xml)
            ?? extractXMLTagValue("totalResults", in: xml)
        if let totalStr = totalResultsRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           let totalInt = Int(totalStr),
           totalInt == 0 {
            return .notFound
        }

        guard let entryRange = xml.range(of: "<entry>"),
              let entryClose = xml.range(of: "</entry>", range: entryRange.upperBound..<xml.endIndex) else {
            return .notFound
        }
        let entrySlice = String(xml[entryRange.upperBound..<entryClose.lowerBound])

        if let entryID = extractXMLTagValue("id", in: entrySlice),
           entryID.lowercased().contains("arxiv.org/api/errors") {
            return .notFound
        }

        guard let rawTitle = extractXMLTagValue("title", in: entrySlice) else {
            return .notFound
        }
        let cleanTitle = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !cleanTitle.isEmpty, cleanTitle.lowercased() != "error" else {
            return .notFound
        }

        let authorBlocks = extractAllXMLTagValues("author", in: entrySlice)
        var authorSurnames: [String] = []
        var firstAuthorRawName: String?
        for block in authorBlocks {
            if let name = nonEmpty(extractXMLTagValue("name", in: block)),
               let sur = Self.extractSurnameFromAuthorString(name) {
                if firstAuthorRawName == nil {
                    firstAuthorRawName = name
                }
                authorSurnames.append(sur)
            }
        }
        let firstSurname = authorSurnames.first

        var publicationYears: [Int] = []
        if let published = extractXMLTagValue("published", in: entrySlice),
           published.count >= 4,
           let yr = Int(published.prefix(4)) {
            publicationYears.append(yr)
        }

        var venues: [String] = []
        if let journalRef = extractXMLTagValue("arxiv:journal_ref", in: entrySlice) {
            let cleanedRef = journalRef
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            if !cleanedRef.isEmpty {
                venues.append(cleanedRef)
            }
        }

        var retractionField: String?
        let lowerTitle = cleanTitle.lowercased()
        let commentText = (extractXMLTagValue("arxiv:comment", in: entrySlice) ?? "").lowercased()
        let summaryText = (extractXMLTagValue("summary", in: entrySlice) ?? "").lowercased()
        if commentText.contains("withdrawn") || commentText.contains("retracted") {
            retractionField = "arxiv:comment"
        } else if lowerTitle.contains("withdrawn") || lowerTitle.contains("retracted") {
            retractionField = "title"
        } else if summaryText.contains("this paper has been withdrawn") || summaryText.contains("this paper has been retracted") {
            retractionField = "summary"
        }

        let arxivDOI = ReferenceIdentifierNormalizer.normalizeDOI(extractXMLTagValue("arxiv:doi", in: entrySlice))

        return .parsed(
            RemoteWorkRecord(
                sourceName: "arXiv",
                doi: arxivDOI,
                title: cleanTitle,
                firstAuthorDisplay: firstSurname,
                firstAuthorSurname: firstSurname,
                firstAuthorFullName: firstAuthorRawName,
                firstAuthorHasExplicitFamilyField: false,
                firstAuthorIsCorporate: false,
                authorSurnames: authorSurnames,
                publicationYears: publicationYears,
                venues: venues,
                retractionField: retractionField
            )
        )
    }

    private func parsePubMedSummaryPayload(_ data: Data, requestedPMID: String) -> PubMedPayloadParseOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unparseable
        }

        if let topError = nonEmpty(root["error"] as? String) {
            if topError.lowercased().contains("rate limit") {
                return .rateLimited
            }
            return .unparseable
        }

        guard let resultObj = root["result"] as? [String: Any] else {
            return .unparseable
        }

        guard let doc = resultObj[requestedPMID] as? [String: Any] else {
            if let uids = resultObj["uids"] as? [String], uids.isEmpty {
                return .notFound("empty uids")
            }
            return .unparseable
        }

        if let docError = nonEmpty(doc["error"] as? String) {
            return .notFound(docError)
        }

        var title = (doc["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasSuffix(".") && !title.hasSuffix("..") {
            title.removeLast()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !title.isEmpty else {
            return .registeredNoMetadata
        }

        var normalizedDOI: String?
        if let articleIDs = doc["articleids"] as? [[String: Any]] {
            for item in articleIDs {
                if (item["idtype"] as? String)?.lowercased() == "doi",
                   let doiVal = ReferenceIdentifierNormalizer.normalizeDOI(item["value"] as? String) {
                    normalizedDOI = doiVal
                    break
                }
            }
        }

        var retractionField: String?
        if let pubTypes = doc["pubtype"] as? [String],
           pubTypes.contains(where: { $0.lowercased().contains("retracted publication") }) {
            retractionField = "pubtype (Retracted Publication)"
        }

        var firstAuthorDisplay: String?
        var firstAuthorSurname: String?
        var firstAuthorFullName: String?
        var firstAuthorHasExplicitFamilyField = false
        var firstAuthorIsCorporate = false
        var authorSurnames: [String] = []

        if let rawAuthors = doc["authors"] as? [[String: Any]], !rawAuthors.isEmpty {
            let primaryAuthors: [[String: Any]] = {
                let filtered = rawAuthors.filter {
                    let t = (($0["authtype"] as? String) ?? "author").lowercased()
                    return t == "author" || t == "collectivename"
                }
                return filtered.isEmpty ? rawAuthors : filtered
            }()

            for (idx, item) in primaryAuthors.enumerated() {
                guard let name = nonEmpty(item["name"] as? String) else { continue }
                let authtype = ((item["authtype"] as? String) ?? "Author").lowercased()
                if authtype == "collectivename" {
                    authorSurnames.append(name)
                    if idx == 0 {
                        firstAuthorDisplay = name
                        firstAuthorSurname = name
                        firstAuthorFullName = name
                        firstAuthorHasExplicitFamilyField = false
                        firstAuthorIsCorporate = true
                    }
                } else {
                    let parsed = Self.extractPubMedAuthorSurname(from: name)
                    authorSurnames.append(parsed.surname)
                    if idx == 0 {
                        firstAuthorDisplay = parsed.surname
                        firstAuthorSurname = parsed.surname
                        firstAuthorFullName = name
                        firstAuthorHasExplicitFamilyField = parsed.hasExplicitFamily
                        firstAuthorIsCorporate = false
                    }
                }
            }
        }

        var publicationYears: [Int] = []
        for dateKey in ["pubdate", "epubdate", "sortpubdate"] {
            if let dateStr = nonEmpty(doc[dateKey] as? String),
               let yr = Self.extractFourDigitYear(from: dateStr),
               !publicationYears.contains(yr) {
                publicationYears.append(yr)
            }
        }

        var venues: [String] = []
        for venueKey in ["fulljournalname", "source", "booktitle"] {
            if let v = nonEmpty(doc[venueKey] as? String), !venues.contains(v) {
                venues.append(v)
            }
        }

        return .parsed(
            RemoteWorkRecord(
                sourceName: "PubMed",
                doi: normalizedDOI,
                title: title,
                firstAuthorDisplay: firstAuthorDisplay,
                firstAuthorSurname: firstAuthorSurname,
                firstAuthorFullName: firstAuthorFullName,
                firstAuthorHasExplicitFamilyField: firstAuthorHasExplicitFamilyField,
                firstAuthorIsCorporate: firstAuthorIsCorporate,
                authorSurnames: authorSurnames,
                publicationYears: publicationYears,
                venues: venues,
                retractionField: retractionField
            )
        )
    }

    private static func extractPubMedAuthorSurname(from rawName: String) -> (surname: String, hasExplicitFamily: Bool) {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(",") {
            let beforeComma = trimmed.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? trimmed
            return (beforeComma.isEmpty ? trimmed : beforeComma, true)
        }

        var tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count <= 1 {
            return (trimmed, false)
        }

        let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "2nd", "3rd", "4th", "ii", "iii", "iv"]
        if tokens.count >= 3, let last = tokens.last?.lowercased(), suffixes.contains(last) {
            tokens.removeLast()
        }

        if tokens.count >= 2, let lastToken = tokens.last, isPubMedInitialsToken(lastToken) {
            tokens.removeLast()
            return (tokens.joined(separator: " "), true)
        }

        return (extractSurnameFromAuthorString(trimmed) ?? trimmed, false)
    }

    private static func isPubMedInitialsToken(_ token: String) -> Bool {
        guard (1...5).contains(token.count) else { return false }
        var hasUppercase = false
        for ch in token {
            if ch.isUppercase {
                hasUppercase = true
            } else if ch == "-" || ch == "." {
                continue
            } else {
                return false
            }
        }
        return hasUppercase
    }

    private static func extractFourDigitYear(from text: String) -> Int? {
        var digits = ""
        for ch in text {
            if ch.isNumber {
                digits.append(ch)
                if digits.count == 4, let yr = Int(digits), (1450...2100).contains(yr) {
                    return yr
                }
            } else {
                digits.removeAll(keepingCapacity: true)
            }
        }
        return nil
    }

    // MARK: - Normalization, Parsing & Verdict Formatting Helpers

    private func extractCrossrefDateYear(_ rawDateObj: Any?) -> Int? {
        guard let dateObj = rawDateObj as? [String: Any],
              let parts = dateObj["date-parts"] as? [[Any]],
              let firstRow = parts.first,
              let firstElem = firstRow.first else {
            return nil
        }
        if let yr = firstElem as? Int {
            return yr
        }
        if let num = firstElem as? NSNumber {
            return num.intValue
        }
        return nil
    }

    private func extractXMLTagValue(_ tag: String, in xml: String) -> String? {
        guard let open = findXMLOpeningTag(tag, in: xml, from: xml.startIndex),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else {
            return nil
        }
        return Self.decodeXMLEntities(String(xml[open.upperBound..<close.lowerBound]))
    }

    private func extractAllXMLTagValues(_ tag: String, in xml: String) -> [String] {
        var results: [String] = []
        var cursor = xml.startIndex
        while let open = findXMLOpeningTag(tag, in: xml, from: cursor),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) {
            results.append(Self.decodeXMLEntities(String(xml[open.upperBound..<close.lowerBound])))
            cursor = close.upperBound
        }
        return results
    }

    private func findXMLOpeningTag(_ tag: String, in xml: String, from start: String.Index) -> Range<String.Index>? {
        if let exact = xml.range(of: "<\(tag)>", range: start..<xml.endIndex) {
            if let attrOpen = xml.range(of: "<\(tag) ", range: start..<xml.endIndex),
               attrOpen.lowerBound < exact.lowerBound,
               let gt = xml.range(of: ">", range: attrOpen.upperBound..<xml.endIndex) {
                return attrOpen.lowerBound..<gt.upperBound
            }
            return exact
        }
        if let attrOpen = xml.range(of: "<\(tag) ", range: start..<xml.endIndex),
           let gt = xml.range(of: ">", range: attrOpen.upperBound..<xml.endIndex) {
            return attrOpen.lowerBound..<gt.upperBound
        }
        return nil
    }

    private static func decodeXMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&mdash;", with: "—")
    }

    private static func stripHTMLTagsAndEntities(_ text: String) -> String {
        var stripped = ""
        stripped.reserveCapacity(text.count)
        var insideTag = false
        for ch in text {
            if ch == "<" {
                insideTag = true
                stripped.append(" ")
            } else if ch == ">" && insideTag {
                insideTag = false
                stripped.append(" ")
            } else if !insideTag {
                stripped.append(ch)
            }
        }
        return decodeXMLEntities(stripped)
    }

    private static func stripOuterRetractionMarkers(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed && !s.isEmpty {
            changed = false
            let lower = s.lowercased()
            for prefix in leadingRetractionPrefixes where lower.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n:-–—"))
                changed = true
                break
            }
            let lowerAfterPrefix = s.lowercased()
            for suffix in trailingRetractionSuffixes where lowerAfterPrefix.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n:-–—"))
                changed = true
                break
            }
        }
        return s
    }

    private static func foldLigaturesAndDiacritics(_ text: String) -> String {
        let ligatureExpanded = text
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "ẞ", with: "ss")
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "Æ", with: "ae")
            .replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "Œ", with: "oe")
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "Ø", with: "o")
            .replacingOccurrences(of: "ł", with: "l")
            .replacingOccurrences(of: "Ł", with: "l")
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "d")
            .replacingOccurrences(of: "ı", with: "i")

        return ligatureExpanded.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private static func splitAlphanumericWords(_ foldedLowercase: String) -> [String] {
        var words: [String] = []
        var current = ""
        for ch in foldedLowercase {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    private static func normalizeCorporateOrAuthorToken(_ raw: String) -> String {
        let decoded = LaTeXTextCodec().decode(raw)
        let folded = foldLigaturesAndDiacritics(decoded)
        return splitAlphanumericWords(folded).joined()
    }

    private static func isEtAlTruncationAuthor(_ author: BibAuthor) -> Bool {
        guard author.givenName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let fam = author.familyName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return fam == "et al." || fam == "et al" || fam == "others"
    }

    static func extractSurnameFromAuthorString(_ raw: String) -> String? {
        let decoded = LaTeXTextCodec().decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }

        if decoded.contains(",") {
            let parts = decoded.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let firstPart = parts.first, !firstPart.isEmpty {
                return firstPart
            }
        }

        var words = decoded.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty { return nil }

        let generationalSuffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"]
        if words.count >= 3, let last = words.last?.lowercased(), generationalSuffixes.contains(last) {
            words.removeLast()
        }

        if words.count == 1 {
            return words[0]
        }

        let particles: Set<String> = ["von", "van", "de", "del", "della", "der", "di", "du", "la", "le", "ten", "ter", "zu"]
        var surnameStart = words.count - 1
        while surnameStart > 1 {
            let candidate = words[surnameStart - 1].lowercased()
            if particles.contains(candidate) {
                surnameStart -= 1
            } else {
                break
            }
        }
        return words[surnameStart..<words.count].joined(separator: " ")
    }

    private struct VenueToken: Equatable {
        let stem: String
        let isAbbreviated: Bool
    }

    private static func venueTokenCandidates(for rawVenue: String) -> [[VenueToken]] {
        let decoded = LaTeXTextCodec().decode(stripHTMLTagsAndEntities(rawVenue))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if decoded.isEmpty { return [] }

        // Strip trailing parenthetical acronym if preceded by full title, e.g. "Advances in ... (NeurIPS)"
        var variants: [String] = [decoded]
        if let openParen = decoded.lastIndex(of: "("),
           let closeParen = decoded.lastIndex(of: ")"),
           openParen > decoded.startIndex,
           openParen < closeParen {
            let beforeParen = String(decoded[..<openParen]).trimmingCharacters(in: .whitespacesAndNewlines)
            let insideParen = String(decoded[decoded.index(after: openParen)..<closeParen]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !beforeParen.isEmpty {
                variants.append(beforeParen)
            }
            if !insideParen.isEmpty {
                variants.append(insideParen)
            }
        }

        var candidateTokenLists: [[VenueToken]] = []
        for variant in variants {
            let tokens = tokenizeVenueString(variant)
            if !tokens.isEmpty && !candidateTokenLists.contains(tokens) {
                candidateTokenLists.append(tokens)
            }
            // Check single-token or acronym expansion (`PNAS`, `JMLR`, `NeurIPS`, etc.)
            if tokens.count == 1, let expanded = knownVenueAcronymExpansions[tokens[0].stem] {
                let expTokens = tokenizeVenueString(expanded)
                if !expTokens.isEmpty && !candidateTokenLists.contains(expTokens) {
                    candidateTokenLists.append(expTokens)
                }
            }
            // Strip trailing geographic suffix "USA" / "United States of America" (e.g. Proc. Natl. Acad. Sci. USA)
            if tokens.count >= 4 && tokens.last?.stem == "usa" {
                let droppedUSA = Array(tokens.dropLast())
                if !candidateTokenLists.contains(droppedUSA) {
                    candidateTokenLists.append(droppedUSA)
                }
            }
        }
        return candidateTokenLists
    }

    private static func tokenizeVenueString(_ text: String) -> [VenueToken] {
        let rawChunks = text.split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == ":" || $0 == "," || $0 == ";" || $0 == "–" || $0 == "—" || $0 == "-" })
        var out: [VenueToken] = []
        for chunk in rawChunks {
            let rawStr = String(chunk)
            if rawStr == "&" { continue }
            let hadDot = rawStr.hasSuffix(".")
            let folded = foldLigaturesAndDiacritics(rawStr)
            let words = splitAlphanumericWords(folded)
            for (idx, word) in words.enumerated() {
                if venueStopwords.contains(word) { continue }
                // Skip ordinal conference numbers like "27th", "31st", "2017" only when >1 token? Keep words unless pure stopword.
                let isAbbr = (hadDot && idx == words.count - 1) || knownISO4AbbreviationStems.contains(word)
                out.append(VenueToken(stem: word, isAbbreviated: isAbbr))
            }
        }
        return out
    }

    private static func venueTokenSequenceMatches(_ lhs: [VenueToken], _ rhs: [VenueToken]) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return false
        }
        for (a, b) in zip(lhs, rhs) {
            if a.stem == b.stem {
                continue
            }
            if a.isAbbreviated && Self.abbreviationMatchesFullWord(abbr: a.stem, full: b.stem) {
                continue
            }
            if b.isAbbreviated && Self.abbreviationMatchesFullWord(abbr: b.stem, full: a.stem) {
                continue
            }
            return false
        }
        return true
    }

    private static func abbreviationMatchesFullWord(abbr: String, full: String) -> Bool {
        if abbr == "j" {
            return full == "journal"
        }
        if abbr == "int" || abbr == "intl" {
            return full == "international"
        }
        guard abbr.count >= 2, full.count > abbr.count else {
            return false
        }
        return full.hasPrefix(abbr)
    }

    private func formatEnglishDriftSummary(
        discrepancies: [CitationFieldDiscrepancy],
        sourceName: String
    ) -> String {
        let items = discrepancies.map { d -> String in
            if d.localValue.isEmpty {
                return "missing \(d.field) (\(sourceName): '\(d.remoteValue)')"
            }
            if d.field == "year" {
                if let note = d.note, note.contains(CitationAuditWording.yearOnlineVsPrintNotice) {
                    return "year local '\(d.localValue)' vs \(sourceName) '\(d.remoteValue)' (\(CitationAuditWording.yearOnlineVsPrintNotice))"
                }
                return "year error: local '\(d.localValue)' vs \(sourceName) '\(d.remoteValue)'"
            }
            return "\(d.field) local '\(d.localValue)' vs \(sourceName) '\(d.remoteValue)'"
        }
        return "Metadata drift against \(sourceName): \(items.joined(separator: "; "))."
    }

    private func classifyHTTPFailureStatus(
        _ statusCode: Int,
        response: RegistryHTTPResponse? = nil,
        host: String? = nil
    ) -> CitationUnverifiedReasonCode {
        if host == "api.openalex.org",
           let response,
           let remaining = RegistryRateLimiter.parseOpenAlexRemainingHeader(from: response),
           remaining < RegistryRateLimiter.openAlexMinimumSearchCredits {
            return .budgetExhausted
        }
        if statusCode == 429 || statusCode == 503 {
            return .rateLimited
        }
        if (500...599).contains(statusCode) {
            return .serverError
        }
        if statusCode == 408 {
            return .timeout
        }
        return .transportError
    }

    private func classifyThrownTransportError(_ error: Error) -> CitationUnverifiedReasonCode {
        if error is RegistryBudgetExhaustedError {
            return .budgetExhausted
        }
        if let transportErr = error as? RegistryTransportError {
            return transportErr.kind == .timeout ? .timeout : .transportError
        }
        if let urlErr = error as? URLError, urlErr.code == .timedOut {
            return .timeout
        }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorTimedOut {
            return .timeout
        }
        return .transportError
    }

    private func describeHTTPFailure(
        source: String,
        statusCode: Int,
        identifier: String,
        code: CitationUnverifiedReasonCode? = nil
    ) -> String {
        if code == .budgetExhausted {
            return "\(source) budget exhausted while querying '\(identifier)' (status \(statusCode))."
        }
        if statusCode == 429 || statusCode == 503 {
            return "\(source) rate-limited or unavailable for '\(identifier)' (status \(statusCode))."
        }
        if (500...599).contains(statusCode) {
            return "\(source) server error for '\(identifier)' (status \(statusCode))."
        }
        return "\(source) lookup failed for '\(identifier)' (status \(statusCode))."
    }

    private func describeTransportError(
        source: String,
        code: CitationUnverifiedReasonCode,
        error: Error
    ) -> String {
        if code == .budgetExhausted {
            return "\(source) search skipped due to exhausted credit budget (\(error.localizedDescription))."
        }
        if code == .timeout {
            return "\(source) request timed out (\(error.localizedDescription))."
        }
        return "\(source) unreachable (\(error.localizedDescription))."
    }

    private func deduplicatedReasons(_ codes: [CitationUnverifiedReasonCode]) -> [String] {
        var result: [String] = []
        for code in codes where !result.contains(code.rawValue) {
            result.append(code.rawValue)
        }
        return result.isEmpty ? [CitationUnverifiedReasonCode.transportError.rawValue] : result
    }

    private func resolvedFetchedAt(from response: RegistryHTTPResponse) -> String {
        if let explicit = nonEmpty(response.fetchedAt) {
            return explicit
        }
        if let dateHeader = nonEmpty(response.headerValue(for: "Date")) {
            return dateHeader
        }
        return currentISO8601Timestamp()
    }

    private func currentISO8601Timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    public static func shortDateLabel(from rawTimestamp: String) -> String {
        let trimmed = rawTimestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 10 {
            let prefix10 = String(trimmed.prefix(10))
            let chars = Array(prefix10)
            if chars.count == 10,
               chars[4] == "-",
               chars[7] == "-",
               chars[0...3].allSatisfy(\.isNumber),
               chars[5...6].allSatisfy(\.isNumber),
               chars[8...9].allSatisfy(\.isNumber) {
                return prefix10
            }
        }
        return trimmed.isEmpty ? "current-run" : trimmed
    }

    private func isPlaceholderSentinelDOI(_ normalizedDOI: String) -> Bool {
        if sentinelDOIs.contains(normalizedDOI) {
            return true
        }
        for prefix in Self.sentinelDOIRegistrantPrefixes where normalizedDOI.hasPrefix(prefix) {
            return true
        }
        if normalizedDOI.hasPrefix("10.5555/") {
            let suffix = String(normalizedDOI.dropFirst("10.5555/".count))
            let lowerSuffix = suffix.lowercased()
            let fakeTokens = ["fake", "test", "xyz", "dummy", "placeholder", "example", "sample", "hallucinat"]
            if fakeTokens.contains(where: { lowerSuffix.contains($0) }) {
                return true
            }
            if suffix.allSatisfy({ $0 == "0" }) {
                return true
            }
        }
        return false
    }

    private func buildUpdatedVerdict(
        for entry: BibliographyEntry,
        assignedClass: CitationFirewallClass,
        reasons: [String],
        sources: [CitationVerdictSourceRecord],
        fields: [CitationFieldDiscrepancy],
        findings: [FirewallFinding],
        overrideNote: String? = nil
    ) -> CitationFirewallEntryVerdict {
        let baseSummary = overrideNote ?? summarizeFindings(findings, assignedClass: assignedClass)
        let summary: String
        if let declared = nonEmpty(entry.untrustedDeclaredFirewallClass),
           !baseSummary.contains("x-firewall-class") {
            summary = "\(baseSummary) File declared x-firewall-class '\(declared)', \(CitationAuditWording.untrustedFileClassMarker)."
        } else {
            summary = baseSummary
        }
        var updated = entry
        updated.firewallClass = assignedClass
        updated.firewallAuditNote = summary
        let respondedSources = sources.filter { $0.status != nil }
        if assignedClass != .unverified && !respondedSources.isEmpty {
            var uniqueNames: [String] = []
            for rec in respondedSources {
                let name = rec.source.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && !uniqueNames.contains(name) {
                    uniqueNames.append(name)
                }
            }
            updated.firewallVerifiedSource = uniqueNames.joined(separator: ", ")
            if let cacheRec = respondedSources.first(where: { $0.origin == .cache }),
               let cachedDay = Optional(Self.shortDateLabel(from: cacheRec.fetchedAt)),
               BibliographyEntry.parseUTCDayStart(cachedDay) != nil
            {
                updated.firewallVerifiedAtUTC = cachedDay
            } else {
                updated.firewallVerifiedAtUTC = BibliographyEntry.formatUTCDay(clock.currentDate())
            }
        } else {
            updated.firewallVerifiedSource = nil
            updated.firewallVerifiedAtUTC = nil
        }
        let canInsert = (assignedClass == .verified)
        return CitationFirewallEntryVerdict(
            citeKey: entry.citeKey,
            firewallClass: assignedClass,
            insertable: canInsert,
            reasons: reasons,
            sources: sources,
            fields: fields,
            findings: findings,
            auditNote: summary,
            auditedEntry: updated
        )
    }

    /// Composes the one-line audit note for a verdict from its findings.
    /// Internal (not private) so that the wording rules can be unit-tested directly.
    func summarizeFindings(
        _ findings: [FirewallFinding],
        assignedClass: CitationFirewallClass
    ) -> String {
        let criticals = findings.filter { $0.severity == .criticalBlock }.map(\.detail)
        if !criticals.isEmpty {
            return "[\(assignedClass.rawValue)] \(criticals.joined(separator: " "))"
        }
        let warnings = findings.filter { $0.severity == .warning }.map(\.detail)
        if !warnings.isEmpty && assignedClass != .verified {
            return "[\(assignedClass.rawValue)] \(warnings.joined(separator: " "))"
        }
        let passes = findings.filter { $0.severity == .pass }.map(\.detail)
        if !passes.isEmpty {
            return "[\(assignedClass.rawValue)] \(passes.joined(separator: " "))"
        }
        let advisories = findings.filter { $0.severity == .advisory }.map(\.detail)
        if !advisories.isEmpty {
            return "[\(assignedClass.rawValue)] \(advisories.joined(separator: " "))"
        }
        return "[\(assignedClass.rawValue)] Evaluated by ScholarOS Citation Firewall."
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let t = value?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return nil
        }
        return t
    }

    internal static func isSubstantiatedArXivNotFoundPayload(_ data: Data) -> Bool {
        if case .notFound = CitationVerificationFirewall(includeBuiltInRetractedDOIs: false).parseArXivAtomPayload(data) {
            return true
        }
        return false
    }

    internal static func isSubstantiatedPubMedNotFoundPayload(_ data: Data, requestURL: URL) -> Bool {
        guard let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let pmid = components.queryItems?.first(where: { $0.name == "id" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pmid.isEmpty else {
            return false
        }
        if case .notFound = CitationVerificationFirewall(includeBuiltInRetractedDOIs: false).parsePubMedSummaryPayload(data, requestedPMID: pmid) {
            return true
        }
        return false
    }
}
