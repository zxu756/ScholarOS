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
    public let allowsManuscriptInsertion: Bool
    public let confidenceScore: Double
    public let findings: [FirewallFinding]
    public let auditNote: String
    public let auditedEntry: BibliographyEntry

    public init(
        citeKey: String,
        firewallClass: CitationFirewallClass,
        allowsManuscriptInsertion: Bool,
        confidenceScore: Double,
        findings: [FirewallFinding],
        auditNote: String,
        auditedEntry: BibliographyEntry
    ) {
        self.citeKey = citeKey
        self.firewallClass = firewallClass
        self.allowsManuscriptInsertion = allowsManuscriptInsertion
        self.confidenceScore = confidenceScore
        self.findings = findings
        self.auditNote = auditNote
        self.auditedEntry = auditedEntry
    }
}

public struct CitationFirewallAuditReport: Sendable, Codable, Hashable {
    public let generatedAtISO8601: String
    public let totalEvaluated: Int
    public let verifiedCount: Int
    public let driftCount: Int
    public let notFoundCount: Int
    public let retractedCount: Int
    public let unverifiedCount: Int
    public let manuscriptInsertionAllowedCount: Int
    public let insertionPassRate: Double
    public let verdicts: [CitationFirewallEntryVerdict]
    public let auditedEntries: [BibliographyEntry]
    public let blockedCiteKeys: [String]
    public let unverifiedCiteKeys: [String]

    public init(
        generatedAtISO8601: String,
        totalEvaluated: Int,
        verifiedCount: Int,
        driftCount: Int,
        notFoundCount: Int,
        retractedCount: Int,
        unverifiedCount: Int,
        manuscriptInsertionAllowedCount: Int,
        insertionPassRate: Double,
        verdicts: [CitationFirewallEntryVerdict],
        auditedEntries: [BibliographyEntry],
        blockedCiteKeys: [String],
        unverifiedCiteKeys: [String]
    ) {
        self.generatedAtISO8601 = generatedAtISO8601
        self.totalEvaluated = totalEvaluated
        self.verifiedCount = verifiedCount
        self.driftCount = driftCount
        self.notFoundCount = notFoundCount
        self.retractedCount = retractedCount
        self.unverifiedCount = unverifiedCount
        self.manuscriptInsertionAllowedCount = manuscriptInsertionAllowedCount
        self.insertionPassRate = insertionPassRate
        self.verdicts = verdicts
        self.auditedEntries = auditedEntries
        self.blockedCiteKeys = blockedCiteKeys
        self.unverifiedCiteKeys = unverifiedCiteKeys
    }
}

// MARK: - Protocol-Injected Public Registry HTTP Session

public struct RegistryHTTPResponse: Sendable, Codable, Hashable {
    public let statusCode: Int
    public let body: Data
    public let headers: [String: String]

    public init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    public static func json(statusCode: Int = 200, _ jsonString: String) -> RegistryHTTPResponse {
        RegistryHTTPResponse(
            statusCode: statusCode,
            body: Data(jsonString.utf8),
            headers: ["Content-Type": "application/json"]
        )
    }

    public static func xml(statusCode: Int = 200, _ xmlString: String) -> RegistryHTTPResponse {
        RegistryHTTPResponse(
            statusCode: statusCode,
            body: Data(xmlString.utf8),
            headers: ["Content-Type": "application/atom+xml"]
        )
    }
}

public protocol CitationRegistrySession: Sendable {
    func send(_ request: URLRequest) async throws -> RegistryHTTPResponse
}

public struct LiveURLSessionRegistryClient: CitationRegistrySession, Sendable {
    public let timeoutInterval: TimeInterval
    public let politeMailto: String?

    public init(timeoutInterval: TimeInterval = 10.0, politeMailto: String? = nil) {
        self.timeoutInterval = timeoutInterval
        self.politeMailto = politeMailto
    }

    public func send(_ request: URLRequest) async throws -> RegistryHTTPResponse {
        var configured = request
        configured.timeoutInterval = timeoutInterval
        let ua: String
        if let mailto = politeMailto, !mailto.isEmpty {
            ua = "ScholarOS/1.0 (CitationVerificationFirewall; mailto:\(mailto))"
        } else {
            ua = "ScholarOS/1.0 (CitationVerificationFirewall)"
        }
        configured.setValue(ua, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: configured)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return RegistryHTTPResponse(statusCode: status, body: data)
    }
}

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

    /// Validates NCBI PubMed numeric PMID bounds (`1 ... 49_999_999`, no leading zero padding).
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
        guard let numeric = Int(trimmed), (1...49_999_999).contains(numeric) else {
            return (false, trimmed, "PMID '\(trimmed)' falls outside valid NLM numeric range 1..49,999,999.")
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

    /// Built-in offline hint list of retracted DOIs (内置名单，不完整 — does NOT substitute for online retraction checks).
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

    public init(
        additionalRetractedDOIs: Set<String> = [],
        additionalSentinelDOIs: Set<String> = [],
        minAllowedPublicationYear: Int = 1450,
        maxAllowedPublicationYear: Int = 2030
    ) {
        self.retractedDOIs = Self.defaultRetractedDOIs.union(additionalRetractedDOIs.map { $0.lowercased() })
        self.sentinelDOIs = Self.defaultSentinelDOIs.union(additionalSentinelDOIs.map { $0.lowercased() })
        self.minAllowedPublicationYear = minAllowedPublicationYear
        self.maxAllowedPublicationYear = maxAllowedPublicationYear
    }

    // MARK: - Offline Deterministic Structural & Built-in Retraction Hint Evaluation

    /// Evaluates `entry` offline without querying external registries.
    /// Offline evaluation NEVER returns `.verified`; syntactically valid identifiers receive `.unverified`.
    public func evaluate(_ entry: BibliographyEntry) -> CitationFirewallEntryVerdict {
        var findings: [FirewallFinding] = []
        var hasRetractedMatch = false
        var hasStructuralOrSentinelBlock = false
        var hasSyntacticallyValidPID = false

        // 1. Title sentinel & explicit retraction prefix check
        let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTitle = trimmedTitle.lowercased()

        if trimmedTitle.isEmpty || lowerTitle == "untitled" || lowerTitle == "tbd" || lowerTitle == "todo" {
            hasStructuralOrSentinelBlock = true
            findings.append(
                FirewallFinding(
                    code: .blockedPlaceholderSentinel,
                    severity: .criticalBlock,
                    field: "title",
                    detail: "Title '\(trimmedTitle)' is empty or an unverified placeholder."
                )
            )
        } else if Self.sentinelTitlePhrases.contains(where: { lowerTitle.contains($0) }) {
            hasStructuralOrSentinelBlock = true
            findings.append(
                FirewallFinding(
                    code: .blockedPlaceholderSentinel,
                    severity: .criticalBlock,
                    field: "title",
                    detail: "Title '\(trimmedTitle)' matches known placeholder/LLM sentinel text."
                )
            )
        } else if lowerTitle.hasPrefix("retracted:") || lowerTitle.contains("[retracted]") || lowerTitle.hasPrefix("retraction:") {
            hasRetractedMatch = true
            findings.append(
                FirewallFinding(
                    code: .blockedRetractedWork,
                    severity: .criticalBlock,
                    field: "title",
                    detail: "Title indicates a retracted publication ('\(trimmedTitle)') (内置名单，不完整)."
                )
            )
        }

        // 2. Author plausibility & ORCID ISO 7064 Mod 11-2 check-digit validation
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
                    hasStructuralOrSentinelBlock = true
                    findings.append(
                        FirewallFinding(
                            code: .blockedPlaceholderSentinel,
                            severity: .criticalBlock,
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
                        hasStructuralOrSentinelBlock = true
                        findings.append(
                            FirewallFinding(
                                code: .invalidORCIDChecksum,
                                severity: .criticalBlock,
                                field: "authors.orcid",
                                detail: orcidCheck.reason ?? "Invalid ORCID checksum."
                            )
                        )
                    }
                }
            }
        }

        // 3. Publication year plausibility check
        if let year = entry.year {
            if year < minAllowedPublicationYear || year > maxAllowedPublicationYear {
                hasStructuralOrSentinelBlock = true
                findings.append(
                    FirewallFinding(
                        code: .implausiblePublicationYear,
                        severity: .criticalBlock,
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

        // 4. DOI validation, sentinel check & built-in offline retraction hint list lookup
        if let rawDOI = nonEmpty(entry.doi) {
            let doiCheck = ScholarlyIdentifierValidator.validateDOISyntax(rawDOI)
            if !doiCheck.isValid {
                hasStructuralOrSentinelBlock = true
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
                    hasRetractedMatch = true
                    findings.append(
                        FirewallFinding(
                            code: .blockedRetractedWork,
                            severity: .criticalBlock,
                            field: "doi",
                            detail: "DOI '\(normDOI)' matched built-in offline retracted list (内置名单，不完整)."
                        )
                    )
                } else if isPlaceholderSentinelDOI(normDOI) {
                    hasStructuralOrSentinelBlock = true
                    findings.append(
                        FirewallFinding(
                            code: .blockedPlaceholderSentinel,
                            severity: .criticalBlock,
                            field: "doi",
                            detail: "DOI '\(normDOI)' is a known test/dummy/LLM placeholder sentinel."
                        )
                    )
                } else if normDOI.hasPrefix("10.48550/arxiv.") {
                    let embeddedArXiv = String(normDOI.dropFirst("10.48550/arxiv.".count))
                    let arxivCheck = ScholarlyIdentifierValidator.validateArXivID(
                        embeddedArXiv,
                        maxYear: maxAllowedPublicationYear
                    )
                    if arxivCheck.isValid {
                        hasSyntacticallyValidPID = true
                        findings.append(
                            FirewallFinding(
                                code: .validArXivIdentifier,
                                severity: .pass,
                                field: "doi",
                                detail: "DataCite arXiv DOI '\(normDOI)' has valid syntax; not checked against external registry (offline)."
                            )
                        )
                    } else {
                        hasStructuralOrSentinelBlock = true
                        findings.append(
                            FirewallFinding(
                                code: .invalidArXivCalendarBounds,
                                severity: .criticalBlock,
                                field: "doi",
                                detail: arxivCheck.failureReason ?? "Invalid embedded arXiv ID in DataCite DOI."
                            )
                        )
                    }
                } else if normDOI.hasPrefix("10.5555/") {
                    findings.append(
                        FirewallFinding(
                            code: .validCanonicalDOI,
                            severity: .warning,
                            field: "doi",
                            detail: "DOI '\(normDOI)' uses Crossref test/non-resolvable prefix '10.5555/'; unverified offline."
                        )
                    )
                } else {
                    hasSyntacticallyValidPID = true
                    findings.append(
                        FirewallFinding(
                            code: .validCanonicalDOI,
                            severity: .pass,
                            field: "doi",
                            detail: "DOI '\(normDOI)' has valid ISO 26324 syntax; not checked against external registry (offline)."
                        )
                    )
                }
            }
        }

        // 5. arXiv identifier calendar & sequence bounds check (`2319.99999` month 19 -> NOT_FOUND!)
        if let rawArXiv = nonEmpty(entry.arxivID) {
            let arxivCheck = ScholarlyIdentifierValidator.validateArXivID(
                rawArXiv,
                maxYear: maxAllowedPublicationYear
            )
            if !arxivCheck.isValid {
                hasStructuralOrSentinelBlock = true
                findings.append(
                    FirewallFinding(
                        code: .invalidArXivCalendarBounds,
                        severity: .criticalBlock,
                        field: "arxivID",
                        detail: arxivCheck.failureReason ?? "Invalid arXiv identifier '\(rawArXiv)'."
                    )
                )
            } else {
                hasSyntacticallyValidPID = true
                findings.append(
                    FirewallFinding(
                        code: .validArXivIdentifier,
                        severity: .pass,
                        field: "arxivID",
                        detail: "arXiv:\(arxivCheck.canonicalBaseID) has valid calendar/sequence syntax; not checked against external registry (offline)."
                    )
                )

                if let inferredYear = arxivCheck.inferredSubmissionYear, let entryYear = entry.year {
                    if entryYear < inferredYear - 1 || entryYear > inferredYear + 5 {
                        findings.append(
                            FirewallFinding(
                                code: .metadataDriftDetected,
                                severity: .warning,
                                field: "year",
                                detail: "Entry year (\(entryYear)) differs from arXiv:\(arxivCheck.canonicalBaseID) prefix year (\(inferredYear)); unverified offline."
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
                hasStructuralOrSentinelBlock = true
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
                        detail: "PMID:\(pmidCheck.normalized) has valid numeric bounds; not checked against external registry (offline)."
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

        // 8. Determine Offline Verdict (NEVER `.verified` or `.drift`)
        let finalClass: CitationFirewallClass
        let confidence: Double

        if hasRetractedMatch {
            finalClass = .retracted
            confidence = 0.95
        } else if hasStructuralOrSentinelBlock {
            finalClass = .notFound
            confidence = 0.98
        } else {
            finalClass = .unverified
            confidence = hasSyntacticallyValidPID ? 0.40 : 0.25
            if !hasSyntacticallyValidPID && nonEmpty(entry.doi) == nil {
                findings.append(
                    FirewallFinding(
                        code: .missingPersistentIdentifier,
                        severity: .warning,
                        field: "doi/arxivID/pmid",
                        detail: "No persistent identifier (DOI, arXiv ID, or PubMed PMID); not checked against external registry."
                    )
                )
            }
        }

        let summaryNote = summarizeFindings(findings, assignedClass: finalClass)
        var updatedEntry = entry
        updatedEntry.firewallClass = finalClass
        updatedEntry.firewallAuditNote = summaryNote

        return CitationFirewallEntryVerdict(
            citeKey: entry.citeKey,
            firewallClass: finalClass,
            allowsManuscriptInsertion: finalClass.allowsManuscriptInsertion,
            confidenceScore: confidence,
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
        var allowedCount = 0
        var blockedKeys: [String] = []
        var unverifiedKeys: [String] = []

        for v in verdicts {
            if v.allowsManuscriptInsertion {
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
            }
        }

        let passRate = verdicts.isEmpty ? 0.0 : Double(allowedCount) / Double(verdicts.count)
        let timestamp = ISO8601DateFormatter().string(from: Date())

        return CitationFirewallAuditReport(
            generatedAtISO8601: timestamp,
            totalEvaluated: verdicts.count,
            verifiedCount: verifiedCount,
            driftCount: driftCount,
            notFoundCount: notFoundCount,
            retractedCount: retractedCount,
            unverifiedCount: unverifiedCount,
            manuscriptInsertionAllowedCount: allowedCount,
            insertionPassRate: passRate,
            verdicts: verdicts,
            auditedEntries: auditedEntries,
            blockedCiteKeys: blockedKeys,
            unverifiedCiteKeys: unverifiedKeys
        )
    }

    // MARK: - Citation Insertion Assertion (`ERR_UNVERIFIED_CITATION`)

    /// Enforces ScholarOS's citation firewall policy for CLI, MCP, and manuscript exporters.
    /// Throws `ScholarOSError.unverifiedCitationBlocked` (`ERR_UNVERIFIED_CITATION`) whenever `citeKey` is missing or not `.verified`.
    @discardableResult
    public func assertCitationAllowed(
        citeKey: String,
        in library: [String: BibliographyEntry]
    ) throws -> BibliographyEntry {
        let trimmedKey = citeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry = library[trimmedKey] else {
            throw ScholarOSError.unverifiedCitationBlocked(
                citeKey: trimmedKey,
                statusCode: CitationFirewallClass.unverified.rawValue,
                reason: "Citation key '\(trimmedKey)' is missing from the project bibliography."
            )
        }

        // Gate 1: Stored firewall classification must permit manuscript insertion (`.verified` only)
        guard entry.firewallClass.allowsManuscriptInsertion else {
            let reasonDetail: String
            if !entry.firewallAuditNote.isEmpty {
                reasonDetail = entry.firewallAuditNote
            } else {
                reasonDetail = "Entry status is \(entry.firewallClass.rawValue) and has not been verified against external registries."
            }
            throw ScholarOSError.unverifiedCitationBlocked(
                citeKey: entry.citeKey,
                statusCode: entry.firewallClass.rawValue,
                reason: reasonDetail
            )
        }

        // Gate 2: Re-verify deterministic structural & retraction invariants so tampered `x-firewall-class` tags cannot smuggle invalid/retracted IDs
        let liveVerdict = evaluate(entry)
        if liveVerdict.firewallClass == .notFound || liveVerdict.firewallClass == .retracted {
            throw ScholarOSError.unverifiedCitationBlocked(
                citeKey: entry.citeKey,
                statusCode: liveVerdict.firewallClass.rawValue,
                reason: liveVerdict.auditNote
            )
        }

        return entry
    }

    /// Validates a list of cited keys in manuscript order, throwing `ERR_UNVERIFIED_CITATION` on the first disallowed key.
    public func assertAllCitationsAllowed(
        citeKeys: [String],
        in library: [String: BibliographyEntry]
    ) throws -> [BibliographyEntry] {
        try citeKeys.map { key in
            try assertCitationAllowed(citeKey: key, in: library)
        }
    }

    // MARK: - Async Live Public Registry Verification (Crossref / OpenAlex / arXiv)

    /// Resolves `entry` against Crossref, OpenAlex, or arXiv APIs via an injectable `CitationRegistrySession`.
    /// Transport errors, rate limits (429), and server errors (5xx) ALWAYS yield `.unverified` — NEVER `.verified`.
    public func verifyAgainstPublicRegistries(
        entry: BibliographyEntry,
        session: any CitationRegistrySession = LiveURLSessionRegistryClient()
    ) async -> CitationFirewallEntryVerdict {
        let offlineVerdict = evaluate(entry)
        if offlineVerdict.firewallClass == .retracted || offlineVerdict.firewallClass == .notFound {
            return offlineVerdict
        }

        var findings = offlineVerdict.findings

        // Path A: Resolve DOI via Crossref -> fallback to OpenAlex
        if let normDOI = ReferenceIdentifierNormalizer.normalizeDOI(entry.doi),
           !normDOI.hasPrefix("10.48550/arxiv.") {
            var crossrefReturned404 = false
            var openAlexReturned404 = false

            if let encodedDOI = normDOI.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let crossrefURL = URL(string: "https://api.crossref.org/works/\(encodedDOI)") {
                do {
                    let response = try await session.send(URLRequest(url: crossrefURL))
                    if response.statusCode == 404 {
                        crossrefReturned404 = true
                        findings.append(
                            FirewallFinding(
                                code: .registryLookupNotFound,
                                severity: .warning,
                                field: "doi",
                                detail: "Crossref returned 404 for DOI '\(normDOI)'; checking OpenAlex."
                            )
                        )
                    } else if response.statusCode == 200,
                              let remote = parseCrossrefWorkPayload(response.body) {
                        return reconcileRemoteRegistryMetadata(
                            entry: entry,
                            remote: remote,
                            baseClass: .verified,
                            existingFindings: findings
                        )
                    } else {
                        findings.append(
                            FirewallFinding(
                                code: .registryTransportUnavailable,
                                severity: .warning,
                                field: "network",
                                detail: "Crossref returned HTTP \(response.statusCode) or unparseable body for DOI '\(normDOI)'."
                            )
                        )
                    }
                } catch {
                    findings.append(
                        FirewallFinding(
                            code: .registryTransportUnavailable,
                            severity: .warning,
                            field: "network",
                            detail: "Crossref unreachable (\(error.localizedDescription)); attempting OpenAlex fallback."
                        )
                    )
                }
            }

            if let openAlexURL = URL(string: "https://api.openalex.org/works/https://doi.org/\(normDOI)") {
                do {
                    let response = try await session.send(URLRequest(url: openAlexURL))
                    if response.statusCode == 404 {
                        openAlexReturned404 = true
                        findings.append(
                            FirewallFinding(
                                code: .registryLookupNotFound,
                                severity: .criticalBlock,
                                field: "doi",
                                detail: "OpenAlex confirmed 404 not found for DOI '\(normDOI)'."
                            )
                        )
                    } else if response.statusCode == 200,
                              let remote = parseOpenAlexWorkPayload(response.body) {
                        return reconcileRemoteRegistryMetadata(
                            entry: entry,
                            remote: remote,
                            baseClass: .verified,
                            existingFindings: findings
                        )
                    } else {
                        findings.append(
                            FirewallFinding(
                                code: .registryTransportUnavailable,
                                severity: .warning,
                                field: "network",
                                detail: "OpenAlex returned HTTP \(response.statusCode) or unparseable body for DOI '\(normDOI)'."
                            )
                        )
                    }
                } catch {
                    findings.append(
                        FirewallFinding(
                            code: .registryTransportUnavailable,
                            severity: .warning,
                            field: "network",
                            detail: "OpenAlex unreachable (\(error.localizedDescription)); marking UNVERIFIED."
                        )
                    )
                }
            }

            if crossrefReturned404 && openAlexReturned404 {
                return buildUpdatedVerdict(
                    for: entry,
                    assignedClass: .notFound,
                    confidence: 0.98,
                    findings: findings
                )
            }

            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .unverified,
                confidence: 0.25,
                findings: findings
            )
        }

        // Path B: Resolve arXiv preprint via arXiv Atom API
        let candidateArXiv: String? = {
            if let a = ReferenceIdentifierNormalizer.normalizeArXivID(entry.arxivID, stripVersion: true) {
                return a
            }
            if let d = ReferenceIdentifierNormalizer.normalizeDOI(entry.doi), d.hasPrefix("10.48550/arxiv.") {
                return String(d.dropFirst("10.48550/arxiv.".count))
            }
            return nil
        }()

        if let arxivID = candidateArXiv,
           let arxivURL = URL(string: "https://export.arxiv.org/api/query?id_list=\(arxivID)") {
            do {
                let response = try await session.send(URLRequest(url: arxivURL))
                if response.statusCode == 200 {
                    if let remote = parseArXivAtomPayload(response.body) {
                        return reconcileRemoteRegistryMetadata(
                            entry: entry,
                            remote: remote,
                            baseClass: .verified,
                            existingFindings: findings
                        )
                    } else if let xml = String(data: response.body, encoding: .utf8), xml.contains("<feed") {
                        findings.append(
                            FirewallFinding(
                                code: .registryLookupNotFound,
                                severity: .criticalBlock,
                                field: "arxivID",
                                detail: "arXiv API returned no matching preprint entry for 'arXiv:\(arxivID)'."
                            )
                        )
                        return buildUpdatedVerdict(
                            for: entry,
                            assignedClass: .notFound,
                            confidence: 0.96,
                            findings: findings
                        )
                    } else {
                        findings.append(
                            FirewallFinding(
                                code: .registryTransportUnavailable,
                                severity: .warning,
                                field: "network",
                                detail: "arXiv API returned unparseable HTTP 200 payload for 'arXiv:\(arxivID)'."
                            )
                        )
                    }
                } else if response.statusCode == 404 {
                    findings.append(
                        FirewallFinding(
                            code: .registryLookupNotFound,
                            severity: .criticalBlock,
                            field: "arxivID",
                            detail: "arXiv API returned 404 for 'arXiv:\(arxivID)'."
                        )
                    )
                    return buildUpdatedVerdict(
                        for: entry,
                        assignedClass: .notFound,
                        confidence: 0.96,
                        findings: findings
                    )
                } else {
                    findings.append(
                        FirewallFinding(
                            code: .registryTransportUnavailable,
                            severity: .warning,
                            field: "network",
                            detail: "arXiv API returned HTTP \(response.statusCode) for 'arXiv:\(arxivID)'."
                        )
                    )
                }
            } catch {
                findings.append(
                    FirewallFinding(
                        code: .registryTransportUnavailable,
                        severity: .warning,
                        field: "network",
                        detail: "arXiv API unreachable (\(error.localizedDescription)); marking UNVERIFIED."
                    )
                )
            }
        }

        return buildUpdatedVerdict(
            for: entry,
            assignedClass: .unverified,
            confidence: 0.25,
            findings: findings
        )
    }

    // MARK: - Private Registry Parsers & Metadata Drift Reconciliation

    private struct RemoteWorkRecord {
        let sourceName: String
        let title: String
        let firstAuthorSurname: String?
        let year: Int?
        let isRetracted: Bool
    }

    private func reconcileRemoteRegistryMetadata(
        entry: BibliographyEntry,
        remote: RemoteWorkRecord,
        baseClass: CitationFirewallClass,
        existingFindings: [FirewallFinding]
    ) -> CitationFirewallEntryVerdict {
        var findings = existingFindings

        if remote.isRetracted {
            findings.append(
                FirewallFinding(
                    code: .blockedRetractedWork,
                    severity: .criticalBlock,
                    field: "doi",
                    detail: "\(remote.sourceName) marks this work as RETRACTED ('\(remote.title)')."
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .retracted,
                confidence: 0.99,
                findings: findings
            )
        }

        let localNormTitle = ReferenceIdentifierNormalizer.normalizeTitle(entry.title)
        let remoteNormTitle = ReferenceIdentifierNormalizer.normalizeTitle(remote.title)
        let titleSimilarity = ReferenceDeduplicator.jaroWinklerSimilarity(localNormTitle, remoteNormTitle)

        var driftReasons: [String] = []
        if !localNormTitle.isEmpty && !remoteNormTitle.isEmpty && titleSimilarity < 0.86 {
            driftReasons.append("title '\(entry.title)' differs from \(remote.sourceName) '\(remote.title)' (similarity \(String(format: "%.2f", titleSimilarity)))")
        }
        if let localFirst = entry.authors.first.map({ ReferenceIdentifierNormalizer.normalizeSurname($0.familyName) }),
           let remoteFirst = remote.firstAuthorSurname.map({ ReferenceIdentifierNormalizer.normalizeSurname($0) }),
           !localFirst.isEmpty, !remoteFirst.isEmpty,
           ReferenceDeduplicator.jaroWinklerSimilarity(localFirst, remoteFirst) < 0.80 {
            driftReasons.append("first author '\(entry.firstAuthorFamily)' differs from \(remote.sourceName) '\(remote.firstAuthorSurname ?? "")'")
        }
        if let localYear = entry.year, let remoteYear = remote.year, abs(localYear - remoteYear) > 0 {
            driftReasons.append("year \(localYear) differs from \(remote.sourceName) year \(remoteYear)")
        }

        if !driftReasons.isEmpty {
            findings.append(
                FirewallFinding(
                    code: .metadataDriftDetected,
                    severity: .warning,
                    field: "metadata",
                    detail: "\(remote.sourceName) metadata drift: \(driftReasons.joined(separator: "; "))."
                )
            )
            return buildUpdatedVerdict(
                for: entry,
                assignedClass: .drift,
                confidence: 0.85,
                findings: findings
            )
        }

        findings.append(
            FirewallFinding(
                code: .registryVerifiedMatch,
                severity: .pass,
                field: "registry",
                detail: "Verified live metadata match against \(remote.sourceName) (title Jaro-Winkler \(String(format: "%.3f", titleSimilarity)))."
            )
        )
        return buildUpdatedVerdict(
            for: entry,
            assignedClass: baseClass,
            confidence: 0.99,
            findings: findings
        )
    }

    private func parseCrossrefWorkPayload(_ data: Data) -> RemoteWorkRecord? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let message = (root["message"] as? [String: Any]) ?? root

        let title: String = {
            if let titles = message["title"] as? [String], let first = titles.first {
                return first
            }
            if let single = message["title"] as? String {
                return single
            }
            return ""
        }()
        guard !title.isEmpty else { return nil }

        var firstSurname: String?
        if let authors = message["author"] as? [[String: Any]], let first = authors.first {
            firstSurname = (first["family"] as? String) ?? (first["name"] as? String)
        }

        var pubYear: Int?
        for dateKey in ["published-print", "published-online", "issued", "created"] {
            if let dateObj = message[dateKey] as? [String: Any],
               let parts = dateObj["date-parts"] as? [[Int]],
               let firstRow = parts.first,
               let yr = firstRow.first {
                pubYear = yr
                break
            }
        }

        var isRetracted = false
        if let updates = message["update-to"] as? [[String: Any]] {
            isRetracted = updates.contains {
                let t = ($0["type"] as? String)?.lowercased() ?? ""
                return t.contains("retraction")
            }
        }
        if let relation = message["relation"] as? [String: Any],
           relation["is-retracted-by"] != nil {
            isRetracted = true
        }

        return RemoteWorkRecord(
            sourceName: "Crossref",
            title: title,
            firstAuthorSurname: firstSurname,
            year: pubYear,
            isRetracted: isRetracted
        )
    }

    private func parseOpenAlexWorkPayload(_ data: Data) -> RemoteWorkRecord? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = (root["title"] as? String) ?? (root["display_name"] as? String) ?? ""
        guard !title.isEmpty else { return nil }

        let year = root["publication_year"] as? Int
        let isRetracted = (root["is_retracted"] as? Bool) ?? false

        var firstSurname: String?
        if let authorships = root["authorships"] as? [[String: Any]],
           let first = authorships.first,
           let authorObj = first["author"] as? [String: Any],
           let displayName = authorObj["display_name"] as? String {
            firstSurname = displayName.split(whereSeparator: \.isWhitespace).last.map(String.init)
        }

        return RemoteWorkRecord(
            sourceName: "OpenAlex",
            title: title,
            firstAuthorSurname: firstSurname,
            year: year,
            isRetracted: isRetracted
        )
    }

    private func parseArXivAtomPayload(_ data: Data) -> RemoteWorkRecord? {
        guard let xml = String(data: data, encoding: .utf8),
              let entryRange = xml.range(of: "<entry>"),
              let entryClose = xml.range(of: "</entry>", range: entryRange.upperBound..<xml.endIndex) else {
            return nil
        }
        let entrySlice = String(xml[entryRange.upperBound..<entryClose.lowerBound])

        guard let rawTitle = extractXMLTagValue("title", in: entrySlice),
              !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let cleanTitle = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        var firstSurname: String?
        if let authorBlock = extractXMLTagValue("author", in: entrySlice),
           let authorName = extractXMLTagValue("name", in: authorBlock) {
            firstSurname = authorName.split(whereSeparator: \.isWhitespace).last.map(String.init)
        }

        var pubYear: Int?
        if let published = extractXMLTagValue("published", in: entrySlice),
           published.count >= 4,
           let yr = Int(published.prefix(4)) {
            pubYear = yr
        }

        let lowerTitle = cleanTitle.lowercased()
        let withdrawn = lowerTitle.contains("withdrawn") || lowerTitle.contains("retracted")

        return RemoteWorkRecord(
            sourceName: "arXiv",
            title: cleanTitle,
            firstAuthorSurname: firstSurname,
            year: pubYear,
            isRetracted: withdrawn
        )
    }

    private func extractXMLTagValue(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    private func isPlaceholderSentinelDOI(_ normalizedDOI: String) -> Bool {
        if sentinelDOIs.contains(normalizedDOI) {
            return true
        }
        for prefix in Self.sentinelDOIRegistrantPrefixes where normalizedDOI.hasPrefix(prefix) {
            return true
        }
        // Distinguish real ACM DL non-DOI Guide identifiers (`10.5555/3295222.3295349`) from fake `10.5555/fake`
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
        confidence: Double,
        findings: [FirewallFinding]
    ) -> CitationFirewallEntryVerdict {
        let summary = summarizeFindings(findings, assignedClass: assignedClass)
        var updated = entry
        updated.firewallClass = assignedClass
        updated.firewallAuditNote = summary
        return CitationFirewallEntryVerdict(
            citeKey: entry.citeKey,
            firewallClass: assignedClass,
            allowsManuscriptInsertion: assignedClass.allowsManuscriptInsertion,
            confidenceScore: confidence,
            findings: findings,
            auditNote: summary,
            auditedEntry: updated
        )
    }

    private func summarizeFindings(
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
}
