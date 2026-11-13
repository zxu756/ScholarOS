import Foundation
import ScholarModels

// MARK: - Deduplication Thresholds, Identifier Normalization & Cluster Output

public struct DeduplicationConfiguration: Sendable, Codable, Hashable {
    public var strictTitleJaroWinklerThreshold: Double
    public var authorConfirmedTitleThreshold: Double
    public var tokenJaccardBlockingThreshold: Double
    public var tfIdfCosineBlockingThreshold: Double
    public var winklerPrefixScale: Double
    public var winklerBoostThreshold: Double
    public var maxPublicationYearGap: Int
    public var maxPreprintToVenueYearGap: Int

    public init(
        strictTitleJaroWinklerThreshold: Double = 0.92,
        authorConfirmedTitleThreshold: Double = 0.85,
        tokenJaccardBlockingThreshold: Double = 0.30,
        tfIdfCosineBlockingThreshold: Double = 0.26,
        winklerPrefixScale: Double = 0.10,
        winklerBoostThreshold: Double = 0.70,
        maxPublicationYearGap: Int = 1,
        maxPreprintToVenueYearGap: Int = 3
    ) {
        self.strictTitleJaroWinklerThreshold = min(max(strictTitleJaroWinklerThreshold, 0.50), 1.0)
        self.authorConfirmedTitleThreshold = min(max(authorConfirmedTitleThreshold, 0.50), 1.0)
        self.tokenJaccardBlockingThreshold = min(max(tokenJaccardBlockingThreshold, 0.05), 1.0)
        self.tfIdfCosineBlockingThreshold = min(max(tfIdfCosineBlockingThreshold, 0.05), 1.0)
        self.winklerPrefixScale = min(max(winklerPrefixScale, 0.0), 0.25)
        self.winklerBoostThreshold = min(max(winklerBoostThreshold, 0.0), 1.0)
        self.maxPublicationYearGap = max(0, maxPublicationYearGap)
        self.maxPreprintToVenueYearGap = max(0, maxPreprintToVenueYearGap)
    }

    public static let standard = DeduplicationConfiguration()
}

public struct DeduplicationCluster: Sendable, Codable, Hashable, Identifiable {
    public var id: String { mergedEntry.citeKey }
    public let mergedEntry: BibliographyEntry
    public let memberCiteKeys: [String]
    public let duplicateCiteKeys: [String]

    public init(
        mergedEntry: BibliographyEntry,
        memberCiteKeys: [String],
        duplicateCiteKeys: [String]
    ) {
        self.mergedEntry = mergedEntry
        self.memberCiteKeys = memberCiteKeys
        self.duplicateCiteKeys = duplicateCiteKeys
    }
}

public struct DeduplicatedLibraryResult: Sendable, Codable, Hashable {
    public let canonicalEntries: [BibliographyEntry]
    public let candidates: [DuplicateReferenceCandidate]
    public let clusters: [DeduplicationCluster]
    public let citeKeyRedirectMap: [String: String]

    public init(
        canonicalEntries: [BibliographyEntry],
        candidates: [DuplicateReferenceCandidate],
        clusters: [DeduplicationCluster],
        citeKeyRedirectMap: [String: String]
    ) {
        self.canonicalEntries = canonicalEntries
        self.candidates = candidates
        self.clusters = clusters
        self.citeKeyRedirectMap = citeKeyRedirectMap
    }
}

// MARK: - Canonical DOI, arXiv, PMID & Title Normalizer

public enum ReferenceIdentifierNormalizer: Sendable {

    private static let englishAcademicStopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
        "has", "in", "into", "is", "it", "its", "of", "on", "or", "that",
        "the", "their", "this", "to", "towards", "toward", "under", "up",
        "upon", "using", "via", "was", "were", "will", "with", "within", "without"
    ]

    /// Strips resolver URLs (`https://doi.org/`, `http://dx.doi.org/`, `doi:`), URL-decodes percent escapes, trims punctuation, and ASCII-lowercases.
    public static func normalizeDOI(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }

        if let decoded = s.removingPercentEncoding {
            s = decoded
        }

        let lowerCheck = s.lowercased()
        let knownPrefixes = [
            "https://doi.org/",
            "http://doi.org/",
            "https://dx.doi.org/",
            "http://dx.doi.org/",
            "https://www.doi.org/",
            "doi.org/",
            "dx.doi.org/",
            "doi:"
        ]

        for prefix in knownPrefixes {
            if lowerCheck.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // Strip trailing sentence punctuation accidentally captured from prose
        while let last = s.last, (last == "." || last == "," || last == ";" || last == " ") {
            s.removeLast()
        }

        let folded = s.lowercased()
        guard folded.hasPrefix("10."), folded.contains("/") else {
            return folded.isEmpty ? nil : folded
        }
        return folded
    }

    /// Strips `arXiv:`, `https://arxiv.org/abs/`, `.pdf`, case-folds, and removes version suffix `v\d+` (`2305.14314v2` -> `2305.14314`).
    public static func normalizeArXivID(_ raw: String?, stripVersion: Bool = true) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }

        let lower = s.lowercased()
        for urlMarker in ["arxiv.org/abs/", "arxiv.org/pdf/", "arxiv.org/html/"] {
            if let range = lower.range(of: urlMarker) {
                s = String(s[range.upperBound...])
                break
            }
        }

        if s.lowercased().hasPrefix("arxiv:") {
            s = String(s.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.lowercased().hasSuffix(".pdf") {
            s = String(s.dropLast(4))
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\r\n")).lowercased()
        guard !s.isEmpty else { return nil }

        if stripVersion, let (base, _) = splitArXivVersion(s) {
            return base
        }
        return s
    }

    /// Extracts explicit integer version (`2305.14314v2` -> `2`, `2305.14314` -> `nil`).
    public static func extractArXivVersion(_ raw: String?) -> Int? {
        guard let normalizedKeepVer = normalizeArXivID(raw, stripVersion: false) else { return nil }
        return splitArXivVersion(normalizedKeepVer)?.1
    }

    /// Strips `PMID:` or PubMed URLs and leading zeros.
    public static func normalizePMID(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        let lower = s.lowercased()
        if let range = lower.range(of: "pubmed.ncbi.nlm.nih.gov/") {
            s = String(s[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        } else if lower.hasPrefix("pmid:") {
            s = String(s.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !s.isEmpty, s.allSatisfy(\.isNumber) else { return nil }
        let trimmedZeros = String(s.drop(while: { $0 == "0" }))
        return trimmedZeros.isEmpty ? nil : trimmedZeros
    }

    /// Produces a diacritic-insensitive, punctuation-free, whitespace-normalized lowercase title suitable for Jaro-Winkler comparison.
    public static func normalizeTitle(_ rawTitle: String) -> String {
        let latexStripped = rawTitle
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "\\", with: "")

        let folded = latexStripped.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()

        var out = ""
        out.reserveCapacity(folded.count)
        var prevSpace = true

        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                prevSpace = false
            } else {
                if !prevSpace {
                    out.append(" ")
                    prevSpace = true
                }
            }
        }
        if out.last == " " {
            out.removeLast()
        }
        return out
    }

    /// Extracts informative content tokens from a scholarly title for Jaccard and TF-IDF blocking.
    public static func tokenizeTitle(_ rawTitle: String) -> [String] {
        let normalized = normalizeTitle(rawTitle)
        if normalized.isEmpty { return [] }
        let allTokens = normalized.split(separator: " ").map(String.init)
        let filtered = allTokens.filter { token in
            token.count >= 2 && !englishAcademicStopwords.contains(token)
        }
        return filtered.isEmpty ? allTokens : filtered
    }

    public static func normalizeSurname(_ rawSurname: String) -> String {
        rawSurname
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func splitArXivVersion(_ lowerID: String) -> (String, Int)? {
        guard let lastV = lowerID.lastIndex(of: "v"), lastV > lowerID.startIndex else {
            return nil
        }
        let versionDigits = String(lowerID[lowerID.index(after: lastV)...])
        guard !versionDigits.isEmpty, versionDigits.allSatisfy(\.isNumber), let version = Int(versionDigits) else {
            return nil
        }
        let base = String(lowerID[..<lastV])
        let prevChar = base.last
        guard prevChar?.isNumber == true else { return nil }
        return (base, version)
    }
}

// MARK: - Pure-Swift Jaro-Winkler, TF-IDF Blocking & Reference Deduplicator

public struct ReferenceDeduplicator: Sendable {

    public let configuration: DeduplicationConfiguration

    public init(configuration: DeduplicationConfiguration = .standard) {
        self.configuration = configuration
    }

    // MARK: - Pure-Swift Jaro & Jaro-Winkler String Metrics

    public func jaroSimilarity(_ a: String, _ b: String) -> Double {
        Self.jaroSimilarity(a, b)
    }

    public func jaroWinklerSimilarity(_ a: String, _ b: String) -> Double {
        Self.jaroWinklerSimilarity(
            a,
            b,
            prefixScale: configuration.winklerPrefixScale,
            boostThreshold: configuration.winklerBoostThreshold
        )
    }

    public static func jaroSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        let s1 = Array(a)
        let s2 = Array(b)
        let len1 = s1.count
        let len2 = s2.count
        if len1 == 0 || len2 == 0 { return 0.0 }

        let maxLen = max(len1, len2)
        let matchDistance = max((maxLen / 2) - 1, 0)

        var s1Matches = Array(repeating: false, count: len1)
        var s2Matches = Array(repeating: false, count: len2)

        var matches = 0
        for i in 0..<len1 {
            let start = max(0, i - matchDistance)
            let end = min(i + matchDistance + 1, len2)
            if start >= end { continue }
            for j in start..<end {
                if s2Matches[j] { continue }
                if s1[i] != s2[j] { continue }
                s1Matches[i] = true
                s2Matches[j] = true
                matches += 1
                break
            }
        }

        if matches == 0 { return 0.0 }

        var doubleTranspositions = 0
        var k = 0
        for i in 0..<len1 where s1Matches[i] {
            while k < len2 && !s2Matches[k] {
                k += 1
            }
            if k < len2 && s1[i] != s2[k] {
                doubleTranspositions += 1
            }
            k += 1
        }

        let m = Double(matches)
        let transpositions = Double(doubleTranspositions) / 2.0
        return ((m / Double(len1)) + (m / Double(len2)) + ((m - transpositions) / m)) / 3.0
    }

    public static func jaroWinklerSimilarity(
        _ a: String,
        _ b: String,
        prefixScale: Double = 0.10,
        boostThreshold: Double = 0.70
    ) -> Double {
        let jaro = jaroSimilarity(a, b)
        guard jaro >= boostThreshold else { return jaro }

        let s1 = Array(a)
        let s2 = Array(b)
        let maxPrefix = min(4, min(s1.count, s2.count))
        var commonPrefix = 0
        for i in 0..<maxPrefix {
            if s1[i] == s2[i] {
                commonPrefix += 1
            } else {
                break
            }
        }

        let clampedScale = min(max(prefixScale, 0.0), 0.25)
        let boosted = jaro + (Double(commonPrefix) * clampedScale * (1.0 - jaro))
        return min(boosted, 1.0)
    }

    public func tokenJaccardSimilarity(_ tokensA: Set<String>, _ tokensB: Set<String>) -> Double {
        if tokensA.isEmpty && tokensB.isEmpty { return 1.0 }
        if tokensA.isEmpty || tokensB.isEmpty { return 0.0 }
        let intersectionCount = tokensA.intersection(tokensB).count
        let unionCount = tokensA.union(tokensB).count
        return unionCount == 0 ? 0.0 : Double(intersectionCount) / Double(unionCount)
    }

    // MARK: - Author Surname & Publication Year Compatibility

    public func areAuthorsAndYearsCompatible(
        _ lhs: BibliographyEntry,
        _ rhs: BibliographyEntry
    ) -> Bool {
        // Year check: allow larger gap when one entry is a preprint and the other is published
        if let y1 = lhs.year, let y2 = rhs.year {
            let delta = abs(y1 - y2)
            let involvesPreprint = (lhs.kind == .preprint || rhs.kind == .preprint)
                || (lhs.arxivID != nil && lhs.doi == nil)
                || (rhs.arxivID != nil && rhs.doi == nil)
            let allowedGap = involvesPreprint
                ? configuration.maxPreprintToVenueYearGap
                : configuration.maxPublicationYearGap
            if delta > allowedGap {
                return false
            }
        }

        let surnamesA = lhs.authors
            .map { ReferenceIdentifierNormalizer.normalizeSurname($0.familyName) }
            .filter { !$0.isEmpty && $0 != "etal" }
        let surnamesB = rhs.authors
            .map { ReferenceIdentifierNormalizer.normalizeSurname($0.familyName) }
            .filter { !$0.isEmpty && $0 != "etal" }

        // If one side has missing authors, allow fallback to high title threshold
        if surnamesA.isEmpty || surnamesB.isEmpty {
            return true
        }

        // First author exact or high Jaro-Winkler surname match (handles transliteration variants e.g. Muller / Mueller)
        if let firstA = surnamesA.first, let firstB = surnamesB.first {
            if firstA == firstB || jaroWinklerSimilarity(firstA, firstB) >= 0.90 {
                return true
            }
        }

        // Co-author set overlap >= 50% of smaller author list
        let setA = Set(surnamesA)
        let setB = Set(surnamesB)
        let overlap = setA.intersection(setB).count
        let minAuthorCount = min(setA.count, setB.count)
        return minAuthorCount > 0 && (Double(overlap) / Double(minAuthorCount) >= 0.50)
    }

    // MARK: - Duplicate Detection with Multi-Channel Blocking

    public func findDuplicates(in entries: [BibliographyEntry]) -> [DuplicateReferenceCandidate] {
        guard entries.count >= 2 else { return [] }

        let features = entries.enumerated().map { idx, entry in
            IndexedEntryFeatures(index: idx, entry: entry)
        }
        let tfIdfVectors = computeNormalizedTFIDFVectors(for: features)

        // Build blocking inverted indices
        var doiBuckets: [String: [Int]] = [:]
        var arxivBuckets: [String: [Int]] = [:]
        var pmidBuckets: [String: [Int]] = [:]
        var surnameTokenBuckets: [String: [Int]] = [:]
        var rareTokenBuckets: [String: [Int]] = [:]

        var documentFrequency: [String: Int] = [:]
        for f in features {
            for tok in f.uniqueTitleTokens {
                documentFrequency[tok, default: 0] += 1
            }
        }

        let maxBucketDF = max(8, entries.count / 3)

        for f in features {
            if let doi = f.normalizedDOI {
                doiBuckets[doi, default: []].append(f.index)
            }
            if let arxiv = f.normalizedArXiv {
                arxivBuckets[arxiv, default: []].append(f.index)
            }
            if let pmid = f.normalizedPMID {
                pmidBuckets[pmid, default: []].append(f.index)
            }
            if !f.firstAuthorSurname.isEmpty {
                let prefix = String(f.firstAuthorSurname.prefix(4))
                surnameTokenBuckets[prefix, default: []].append(f.index)
            }
            for tok in f.uniqueTitleTokens where tok.count >= 4 {
                if (documentFrequency[tok] ?? 0) <= maxBucketDF {
                    rareTokenBuckets[tok, default: []].append(f.index)
                }
            }
        }

        var candidatePairs = Set<IndexPair>()
        func registerBucketPairs(_ buckets: [String: [Int]]) {
            for indices in buckets.values where indices.count >= 2 {
                for aPos in 0..<(indices.count - 1) {
                    for bPos in (aPos + 1)..<indices.count {
                        candidatePairs.insert(IndexPair(indices[aPos], indices[bPos]))
                    }
                }
            }
        }

        registerBucketPairs(doiBuckets)
        registerBucketPairs(arxivBuckets)
        registerBucketPairs(pmidBuckets)
        registerBucketPairs(surnameTokenBuckets)
        registerBucketPairs(rareTokenBuckets)

        var detectedCandidates: [DuplicateReferenceCandidate] = []

        for pair in candidatePairs.sorted() {
            let fA = features[pair.low]
            let fB = features[pair.high]
            if fA.entry.citeKey == fB.entry.citeKey { continue }

            let titleJW = jaroWinklerSimilarity(fA.normalizedTitle, fB.normalizedTitle)
            let exactDOI = (fA.normalizedDOI != nil && fA.normalizedDOI == fB.normalizedDOI)
            let exactArXiv = (fA.normalizedArXiv != nil && fA.normalizedArXiv == fB.normalizedArXiv)
            let exactPMID = (fA.normalizedPMID != nil && fA.normalizedPMID == fB.normalizedPMID)

            var matchReason: String?

            if exactDOI, let doi = fA.normalizedDOI {
                matchReason = "Exact canonical DOI match (\(doi))"
            } else if exactArXiv, let arxiv = fA.normalizedArXiv {
                matchReason = "Exact version-normalized arXiv ID match (arXiv:\(arxiv))"
            } else if exactPMID, let pmid = fA.normalizedPMID {
                matchReason = "Exact PubMed PMID match (PMID:\(pmid))"
            } else {
                // Conflicting explicit DOIs on two published non-preprint articles should not be merged as fuzzy title duplicates
                if let doiA = fA.normalizedDOI,
                   let doiB = fB.normalizedDOI,
                   doiA != doiB,
                   !isArXivDataCiteDOI(doiA),
                   !isArXivDataCiteDOI(doiB) {
                    continue
                }

                let jaccard = tokenJaccardSimilarity(fA.uniqueTitleTokens, fB.uniqueTitleTokens)
                let cosine = sparseDotProduct(tfIdfVectors[pair.low], tfIdfVectors[pair.high])
                let passesBlocking = jaccard >= configuration.tokenJaccardBlockingThreshold
                    || cosine >= configuration.tfIdfCosineBlockingThreshold

                guard passesBlocking else { continue }
                guard areAuthorsAndYearsCompatible(fA.entry, fB.entry) else { continue }

                let bothHaveMatchingAuthors = !fA.firstAuthorSurname.isEmpty
                    && !fB.firstAuthorSurname.isEmpty
                    && (fA.firstAuthorSurname == fB.firstAuthorSurname
                        || jaroWinklerSimilarity(fA.firstAuthorSurname, fB.firstAuthorSurname) >= 0.90)

                let activeTitleThreshold = bothHaveMatchingAuthors
                    ? configuration.authorConfirmedTitleThreshold
                    : configuration.strictTitleJaroWinklerThreshold

                if titleJW >= activeTitleThreshold && !fA.normalizedTitle.isEmpty && !fB.normalizedTitle.isEmpty {
                    let formattedJW = String(format: "%.3f", titleJW)
                    let formattedCos = String(format: "%.2f", cosine)
                    matchReason = "Fuzzy title Jaro-Winkler \(formattedJW) (TF-IDF cosine \(formattedCos)) with compatible author/year"
                }
            }

            if let reason = matchReason {
                let (primaryEntry, duplicateEntry) = choosePrimaryAndDuplicate(fA.entry, fB.entry)
                detectedCandidates.append(
                    DuplicateReferenceCandidate(
                        primaryCiteKey: primaryEntry.citeKey,
                        duplicateCiteKey: duplicateEntry.citeKey,
                        titleJaroWinkler: titleJW,
                        exactDOIMatch: exactDOI,
                        reason: reason
                    )
                )
            }
        }

        return detectedCandidates.sorted { lhs, rhs in
            if lhs.exactDOIMatch != rhs.exactDOIMatch {
                return lhs.exactDOIMatch && !rhs.exactDOIMatch
            }
            if abs(lhs.titleJaroWinkler - rhs.titleJaroWinkler) > 1e-6 {
                return lhs.titleJaroWinkler > rhs.titleJaroWinkler
            }
            if lhs.primaryCiteKey != rhs.primaryCiteKey {
                return lhs.primaryCiteKey < rhs.primaryCiteKey
            }
            return lhs.duplicateCiteKey < rhs.duplicateCiteKey
        }
    }

    // MARK: - Automatic Metadata Field Merging & Library Clustering

    /// Merges two duplicate entries into a single enriched `BibliographyEntry`, preserving `primary.citeKey` while upgrading preprint venues, DOIs, ORCIDs, abstracts, and firewall trust levels.
    public func mergePair(
        primary: BibliographyEntry,
        duplicate: BibliographyEntry
    ) -> BibliographyEntry {
        let mergedKind = selectPreferredEntryKind(primary: primary.kind, secondary: duplicate.kind)

        let mergedTitle: String = {
            if primary.title.isEmpty || primary.title == "Untitled" {
                return duplicate.title
            }
            // Prefer subtitle-complete title when one is a prefix of the other
            if duplicate.title.count > primary.title.count + 6,
               ReferenceIdentifierNormalizer.normalizeTitle(duplicate.title)
                .hasPrefix(ReferenceIdentifierNormalizer.normalizeTitle(primary.title)) {
                return duplicate.title
            }
            return primary.title
        }()

        let mergedAuthors = mergeAuthorLists(primary: primary.authors, duplicate: duplicate.authors)

        // If upgrading a preprint to a peer-reviewed venue, prefer the peer-reviewed publication year & venue
        let duplicateIsPublishedUpgrade = (primary.kind == .preprint && duplicate.kind != .preprint && duplicate.kind != .misc)
        let mergedYear: Int? = {
            if duplicateIsPublishedUpgrade, let pubYear = duplicate.year {
                return pubYear
            }
            return primary.year ?? duplicate.year
        }()

        let mergedVenue: String = {
            let pVenue = primary.venue.trimmingCharacters(in: .whitespacesAndNewlines)
            let dVenue = duplicate.venue.trimmingCharacters(in: .whitespacesAndNewlines)
            if duplicateIsPublishedUpgrade && !dVenue.isEmpty && !dVenue.lowercased().contains("arxiv") {
                return dVenue
            }
            if pVenue.isEmpty || (pVenue.lowercased().contains("arxiv") && !dVenue.isEmpty && !dVenue.lowercased().contains("arxiv")) {
                return dVenue
            }
            return pVenue
        }()

        let mergedDOI: String? = {
            if let pDOI = nonEmpty(primary.doi), let normP = ReferenceIdentifierNormalizer.normalizeDOI(pDOI), !isArXivDataCiteDOI(normP) {
                return pDOI
            }
            if let dDOI = nonEmpty(duplicate.doi), let normD = ReferenceIdentifierNormalizer.normalizeDOI(dDOI), !isArXivDataCiteDOI(normD) {
                return dDOI
            }
            return nonEmpty(primary.doi) ?? nonEmpty(duplicate.doi)
        }()

        let mergedArXiv = selectPreferredArXivID(primary.arxivID, duplicate.arxivID)
        let mergedPMID = nonEmpty(primary.pmid) ?? nonEmpty(duplicate.pmid)
        let mergedPublisher = nonEmpty(primary.publisher) ?? nonEmpty(duplicate.publisher)
        let mergedVolume = nonEmpty(primary.volume) ?? nonEmpty(duplicate.volume)
        let mergedIssue = nonEmpty(primary.issue) ?? nonEmpty(duplicate.issue)
        let mergedPages = nonEmpty(primary.pages) ?? nonEmpty(duplicate.pages)
        let mergedURL = nonEmpty(primary.url) ?? nonEmpty(duplicate.url)
        let mergedPDF = nonEmpty(primary.attachedPDFPath) ?? nonEmpty(duplicate.attachedPDFPath)

        let mergedAbstract: String? = {
            let a1 = nonEmpty(primary.abstractText)
            let a2 = nonEmpty(duplicate.abstractText)
            if let a1, let a2 {
                return a2.count > a1.count ? a2 : a1
            }
            return a1 ?? a2
        }()

        let (mergedFirewallClass, mergedFirewallNote) = mergeFirewallStatus(
            primaryClass: primary.firewallClass,
            primaryNote: primary.firewallAuditNote,
            duplicateClass: duplicate.firewallClass,
            duplicateNote: duplicate.firewallAuditNote,
            duplicateKey: duplicate.citeKey
        )

        let mergedCitedBy = stableUnion(primary.citedByKeys, duplicate.citedByKeys)
            .filter { $0 != primary.citeKey && $0 != duplicate.citeKey }
        let mergedReferences = stableUnion(primary.referencesKeys, duplicate.referencesKeys)
            .filter { $0 != primary.citeKey && $0 != duplicate.citeKey }

        return BibliographyEntry(
            citeKey: primary.citeKey,
            kind: mergedKind,
            title: mergedTitle,
            authors: mergedAuthors,
            year: mergedYear,
            venue: mergedVenue,
            publisher: mergedPublisher,
            volume: mergedVolume,
            issue: mergedIssue,
            pages: mergedPages,
            doi: mergedDOI,
            arxivID: mergedArXiv,
            pmid: mergedPMID,
            url: mergedURL,
            abstractText: mergedAbstract,
            firewallClass: mergedFirewallClass,
            firewallAuditNote: mergedFirewallNote,
            attachedPDFPath: mergedPDF,
            citedByKeys: mergedCitedBy,
            referencesKeys: mergedReferences
        )
    }

    /// Clusters transitive duplicates via Union-Find and produces a deduplicated library plus a citeKey redirect table.
    public func deduplicateLibrary(_ entries: [BibliographyEntry]) -> DeduplicatedLibraryResult {
        let candidates = findDuplicates(in: entries)
        if candidates.isEmpty {
            let singletons = entries.map {
                DeduplicationCluster(mergedEntry: $0, memberCiteKeys: [$0.citeKey], duplicateCiteKeys: [])
            }
            let identityMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.citeKey, $0.citeKey) })
            return DeduplicatedLibraryResult(
                canonicalEntries: entries,
                candidates: [],
                clusters: singletons,
                citeKeyRedirectMap: identityMap
            )
        }

        var indexByKey: [String: Int] = [:]
        for (idx, e) in entries.enumerated() where indexByKey[e.citeKey] == nil {
            indexByKey[e.citeKey] = idx
        }

        var parent = Array(0..<entries.count)
        func findRoot(_ x: Int) -> Int {
            var cur = x
            while parent[cur] != cur {
                parent[cur] = parent[parent[cur]]
                cur = parent[cur]
            }
            return cur
        }
        func unite(_ a: Int, _ b: Int) {
            let rA = findRoot(a)
            let rB = findRoot(b)
            if rA != rB {
                parent[rB] = rA
            }
        }

        for cand in candidates {
            if let iP = indexByKey[cand.primaryCiteKey], let iD = indexByKey[cand.duplicateCiteKey] {
                unite(iP, iD)
            }
        }

        var membersByRoot: [Int: [Int]] = [:]
        var rootOrder: [Int] = []
        for idx in 0..<entries.count {
            let r = findRoot(idx)
            if membersByRoot[r] == nil {
                rootOrder.append(r)
            }
            membersByRoot[r, default: []].append(idx)
        }

        var canonicalEntries: [BibliographyEntry] = []
        var clusters: [DeduplicationCluster] = []
        var redirectMap: [String: String] = [:]

        for root in rootOrder {
            guard let memberIndices = membersByRoot[root], !memberIndices.isEmpty else { continue }
            let sortedMembers = memberIndices.map { entries[$0] }.sorted { lhs, rhs in
                completenessScore(for: lhs) > completenessScore(for: rhs)
            }

            var accumulated = sortedMembers[0]
            for dup in sortedMembers.dropFirst() {
                accumulated = mergePair(primary: accumulated, duplicate: dup)
            }

            let allKeys = sortedMembers.map(\.citeKey)
            let dupKeys = Array(allKeys.dropFirst())
            for k in allKeys {
                redirectMap[k] = accumulated.citeKey
            }

            canonicalEntries.append(accumulated)
            clusters.append(
                DeduplicationCluster(
                    mergedEntry: accumulated,
                    memberCiteKeys: allKeys,
                    duplicateCiteKeys: dupKeys
                )
            )
        }

        return DeduplicatedLibraryResult(
            canonicalEntries: canonicalEntries,
            candidates: candidates,
            clusters: clusters,
            citeKeyRedirectMap: redirectMap
        )
    }

    // MARK: - Private Scoring, TF-IDF & Merging Helpers

    private struct IndexedEntryFeatures {
        let index: Int
        let entry: BibliographyEntry
        let normalizedDOI: String?
        let normalizedArXiv: String?
        let normalizedPMID: String?
        let normalizedTitle: String
        let titleTokens: [String]
        let uniqueTitleTokens: Set<String>
        let firstAuthorSurname: String

        init(index: Int, entry: BibliographyEntry) {
            self.index = index
            self.entry = entry
            self.normalizedDOI = ReferenceIdentifierNormalizer.normalizeDOI(entry.doi)
            self.normalizedArXiv = ReferenceIdentifierNormalizer.normalizeArXivID(entry.arxivID, stripVersion: true)
            self.normalizedPMID = ReferenceIdentifierNormalizer.normalizePMID(entry.pmid)
            self.normalizedTitle = ReferenceIdentifierNormalizer.normalizeTitle(entry.title)
            let toks = ReferenceIdentifierNormalizer.tokenizeTitle(entry.title)
            self.titleTokens = toks
            self.uniqueTitleTokens = Set(toks)
            self.firstAuthorSurname = entry.authors.first
                .map { ReferenceIdentifierNormalizer.normalizeSurname($0.familyName) } ?? ""
        }
    }

    private struct IndexPair: Hashable, Comparable {
        let low: Int
        let high: Int

        init(_ a: Int, _ b: Int) {
            if a <= b {
                self.low = a
                self.high = b
            } else {
                self.low = b
                self.high = a
            }
        }

        static func < (lhs: IndexPair, rhs: IndexPair) -> Bool {
            if lhs.low != rhs.low { return lhs.low < rhs.low }
            return lhs.high < rhs.high
        }
    }

    private func computeNormalizedTFIDFVectors(for features: [IndexedEntryFeatures]) -> [[String: Double]] {
        let docCount = Double(max(features.count, 1))
        var df: [String: Int] = [:]
        for f in features {
            for tok in f.uniqueTitleTokens {
                df[tok, default: 0] += 1
            }
        }

        return features.map { f in
            if f.titleTokens.isEmpty { return [:] }
            var tf: [String: Int] = [:]
            for tok in f.titleTokens {
                tf[tok, default: 0] += 1
            }
            var weights: [String: Double] = [:]
            var normSquared = 0.0
            for (tok, count) in tf {
                let termFreq = 1.0 + log(Double(count))
                let docFreq = Double(df[tok] ?? 1)
                let idf = log((docCount + 1.0) / (docFreq + 1.0)) + 1.0
                let w = termFreq * idf
                weights[tok] = w
                normSquared += w * w
            }
            let norm = sqrt(normSquared)
            guard norm > 0 else { return [:] }
            for k in weights.keys {
                weights[k, default: 0.0] /= norm
            }
            return weights
        }
    }

    private func sparseDotProduct(_ vecA: [String: Double], _ vecB: [String: Double]) -> Double {
        if vecA.isEmpty || vecB.isEmpty { return 0.0 }
        let (smaller, larger) = vecA.count <= vecB.count ? (vecA, vecB) : (vecB, vecA)
        var sum = 0.0
        for (term, weightA) in smaller {
            if let weightB = larger[term] {
                sum += weightA * weightB
            }
        }
        return sum
    }

    private func choosePrimaryAndDuplicate(
        _ a: BibliographyEntry,
        _ b: BibliographyEntry
    ) -> (BibliographyEntry, BibliographyEntry) {
        let scoreA = completenessScore(for: a)
        let scoreB = completenessScore(for: b)
        if scoreA != scoreB {
            return scoreA > scoreB ? (a, b) : (b, a)
        }
        return a.citeKey <= b.citeKey ? (a, b) : (b, a)
    }

    private func completenessScore(for entry: BibliographyEntry) -> Int {
        var score = 0
        switch entry.firewallClass {
        case .verifiedCanonicalDOI: score += 50
        case .verifiedPreprintRegistry: score += 35
        case .metadataDriftAdvisory: score += 20
        case .unverifiedPendingCheck: score += 5
        case .blockedHallucinatedOrRetracted: score -= 100
        }
        switch entry.kind {
        case .article, .inproceedings, .book, .incollection:
            score += 25
        case .phdthesis, .techreport:
            score += 15
        case .preprint:
            score += 8
        case .misc:
            score += 2
        }
        if let doi = ReferenceIdentifierNormalizer.normalizeDOI(entry.doi), !isArXivDataCiteDOI(doi) {
            score += 30
        }
        if nonEmpty(entry.arxivID) != nil { score += 10 }
        if nonEmpty(entry.pmid) != nil { score += 12 }
        if entry.year != nil { score += 6 }
        if !entry.venue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 8 }
        if nonEmpty(entry.volume) != nil { score += 4 }
        if nonEmpty(entry.issue) != nil { score += 3 }
        if nonEmpty(entry.pages) != nil { score += 5 }
        if nonEmpty(entry.abstractText) != nil { score += 6 }
        if nonEmpty(entry.attachedPDFPath) != nil { score += 10 }
        score += min(entry.authors.count * 2, 16)
        score += entry.authors.compactMap(\.orcid).count * 3
        return score
    }

    private func selectPreferredEntryKind(primary: BibEntryKind, secondary: BibEntryKind) -> BibEntryKind {
        func rank(_ k: BibEntryKind) -> Int {
            switch k {
            case .article, .inproceedings, .book, .incollection: return 4
            case .phdthesis, .techreport: return 3
            case .preprint: return 2
            case .misc: return 1
            }
        }
        return rank(secondary) > rank(primary) ? secondary : primary
    }

    private func mergeAuthorLists(primary: [BibAuthor], duplicate: [BibAuthor]) -> [BibAuthor] {
        if primary.isEmpty { return duplicate }
        if duplicate.isEmpty { return primary }

        let primaryHasEllipsis = primary.contains { $0.familyName.lowercased() == "et al." }
        let duplicateHasEllipsis = duplicate.contains { $0.familyName.lowercased() == "et al." }

        let baseList: [BibAuthor]
        let donorList: [BibAuthor]
        if primaryHasEllipsis && !duplicateHasEllipsis {
            baseList = duplicate
            donorList = primary
        } else if duplicate.count > primary.count && !duplicateHasEllipsis {
            baseList = duplicate
            donorList = primary
        } else {
            baseList = primary
            donorList = duplicate
        }

        return baseList.map { baseAuthor in
            let baseNormSurname = ReferenceIdentifierNormalizer.normalizeSurname(baseAuthor.familyName)
            let matchingDonor = donorList.first {
                ReferenceIdentifierNormalizer.normalizeSurname($0.familyName) == baseNormSurname
            }
            let bestGiven: String = {
                guard let donorGiven = matchingDonor?.givenName else { return baseAuthor.givenName }
                return donorGiven.count > baseAuthor.givenName.count ? donorGiven : baseAuthor.givenName
            }()
            let bestORCID = nonEmpty(baseAuthor.orcid) ?? nonEmpty(matchingDonor?.orcid)
            return BibAuthor(givenName: bestGiven, familyName: baseAuthor.familyName, orcid: bestORCID)
        }
    }

    private func selectPreferredArXivID(_ a: String?, _ b: String?) -> String? {
        guard let cleanA = nonEmpty(a) else { return nonEmpty(b) }
        guard let cleanB = nonEmpty(b) else { return cleanA }
        let verA = ReferenceIdentifierNormalizer.extractArXivVersion(cleanA) ?? 0
        let verB = ReferenceIdentifierNormalizer.extractArXivVersion(cleanB) ?? 0
        return verB > verA ? cleanB : cleanA
    }

    private func mergeFirewallStatus(
        primaryClass: CitationFirewallClass,
        primaryNote: String,
        duplicateClass: CitationFirewallClass,
        duplicateNote: String,
        duplicateKey: String
    ) -> (CitationFirewallClass, String) {
        if primaryClass == .blockedHallucinatedOrRetracted || duplicateClass == .blockedHallucinatedOrRetracted {
            let combined = [primaryNote, duplicateNote]
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            return (.blockedHallucinatedOrRetracted, combined)
        }

        func trustRank(_ cls: CitationFirewallClass) -> Int {
            switch cls {
            case .verifiedCanonicalDOI: return 4
            case .verifiedPreprintRegistry: return 3
            case .metadataDriftAdvisory: return 2
            case .unverifiedPendingCheck: return 1
            case .blockedHallucinatedOrRetracted: return 0
            }
        }

        let chosen = trustRank(duplicateClass) > trustRank(primaryClass) ? duplicateClass : primaryClass
        let baseNote = !primaryNote.isEmpty ? primaryNote : duplicateNote
        let mergeTag = "Merged duplicate '\(duplicateKey)'"
        let finalNote = baseNote.isEmpty ? mergeTag : "\(baseNote); \(mergeTag)"
        return (chosen, finalNote)
    }

    private func isArXivDataCiteDOI(_ normalizedDOI: String) -> Bool {
        normalizedDOI.hasPrefix("10.48550/arxiv.")
    }

    private func stableUnion(_ first: [String], _ second: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in first + second where !item.isEmpty {
            if seen.insert(item).inserted {
                result.append(item)
            }
        }
        return result
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let t = value?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return nil
        }
        return t
    }
}
