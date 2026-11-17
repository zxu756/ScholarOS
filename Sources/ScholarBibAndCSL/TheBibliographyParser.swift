import Foundation
import ScholarModels

// MARK: - Canonical Normalization for `\bibitem` Title & Surname Comparison

/// Canonical text normalizer for comparing bibliography titles and author family names:
/// 1. Expands non-NFKD Latin ligatures/letters (`ß`, `æ`, `œ`, `ø`, `ł`, `đ`, `ı`);
/// 2. Applies Unicode diacritic-, case-, and width-insensitive folding (`en_US_POSIX`) and lowercases;
/// 3. Splits on all non-alphanumeric characters and joins `[a-z0-9]+` words with a single ASCII space.
public enum TheBibliographyComparisonNormalizer: Sendable {
    public static func normalize(_ raw: String) -> String {
        if raw.isEmpty { return "" }
        let expanded = raw
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

        let folded = expanded.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()

        var words: [String] = []
        var current = ""
        for ch in folded {
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
        return words.joined(separator: " ")
    }
}

// MARK: - Best-Effort `\bibitem` Metadata & Persistent Identifier Parser

/// Parses a single `\bibitem[optionalLabel]{citeKey}` body from a `thebibliography` environment or `.bbl` file
/// into a `BibliographyEntry` ready for M1 `CitationVerificationFirewall` evaluation.
/// Uses `\newblock` as a structural segment boundary when present; leaves unparseable fields empty without guessing.
public struct TheBibliographyEntryParser: Sendable {
    private let latexCodec = LaTeXTextCodec()

    private static let lowercaseNameParticles: Set<String> = [
        "von", "van", "de", "del", "della", "der", "di", "du", "la", "le", "ten", "ter", "zu", "da", "al", "el"
    ]

    private static let fullNameDisallowedWords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "for", "with", "to", "from", "by", "at", "into",
        "towards", "toward", "via", "using", "between", "over", "under", "through", "about",
        "survey", "review", "introduction", "proceedings", "international", "conference",
        "symposium", "journal", "transactions", "report", "technical", "working", "note",
        "notes", "manual", "guide", "tutorial", "handbook", "theory", "systems", "control",
        "learning", "analysis", "methods", "models", "standard"
    ]

    private static let nonSentenceEndingAbbreviations: Set<String> = [
        "vol", "vols", "no", "nos", "pp", "p", "ed", "eds", "ch", "chap", "sec", "fig", "eq",
        "tech", "rep", "proc", "trans", "j", "rev", "mod", "phys", "lett", "sci", "int", "intl",
        "conf", "symp", "dept", "univ", "inst", "jr", "sr", "st", "dr", "prof", "mr", "ms",
        "al", "vs", "cf", "etc", "approx", "inc", "ltd", "co"
    ]

    public init() {}

    public func parseEntry(
        citeKey: String,
        optionalLabel: String? = nil,
        rawBody: String
    ) -> BibliographyEntry {
        let commentFreeBody = Self.stripLineCommentsOutsideVerbatimMacros(rawBody)

        // 1. Extract persistent identifiers (DOI, arXiv ID, PMID, URL) before macro unwrapping.
        let identifiers = Self.extractIdentifiers(from: commentFreeBody)

        // 2. Split on `\newblock` and clean `.bbl` / LaTeX formatting macros into prose blocks.
        let rawBlocks = Self.splitOnNewblock(commentFreeBody)
        var proseBlocks: [(raw: String, decoded: String)] = []
        for rawBlock in rawBlocks {
            let prepped = Self.prepareRawBlockForProseDecoding(rawBlock)
            let decoded = Self.cleanDecodedProseSegment(latexCodec.decode(prepped))
            if Self.containsAlphabeticWord(decoded) {
                proseBlocks.append((raw: rawBlock.trimmingCharacters(in: .whitespacesAndNewlines), decoded: decoded))
            }
        }

        // 3. Extract 4-digit publication year (body first, optional `[label]` fallback; never from citeKey).
        let fullProseForYear = rawBlocks
            .map { Self.cleanTextForYearScan(latexCodec.decode(Self.prepareRawBlockForProseDecoding($0))) }
            .joined(separator: " ")
        let parsedYear: Int? = Self.extractPublicationYear(from: fullProseForYear)
            ?? optionalLabel.flatMap { Self.extractYearFromOptionalLabel(latexCodec.decode(Self.stripNatexlabAndPenalties($0))) }

        // 4. Extract authors and title using `\newblock` blocks when available, or single-block structure.
        let authorsAndTitle = extractAuthorsAndTitle(from: proseBlocks)

        return BibliographyEntry(
            citeKey: citeKey,
            kind: .article,
            title: authorsAndTitle.title,
            authors: authorsAndTitle.authors,
            authorsTruncated: authorsAndTitle.authorsTruncated,
            year: parsedYear,
            venue: "",
            doi: identifiers.doi,
            arxivID: identifiers.arxivID,
            pmid: identifiers.pmid,
            url: identifiers.url
        )
    }

    // MARK: - Author & Title Extraction

    private func extractAuthorsAndTitle(
        from proseBlocks: [(raw: String, decoded: String)]
    ) -> (authors: [BibAuthor], authorsTruncated: Bool, title: String) {
        guard !proseBlocks.isEmpty else {
            return ([], false, "")
        }

        // Case A: Multi-block `.bbl` entry divided by `\newblock`
        if proseBlocks.count >= 2 {
            let block0 = proseBlocks[0]
            let parsedAuthors = parseAuthorBlock(rawBlock: block0.raw, decodedBlock: block0.decoded)

            let block1 = proseBlocks[1]
            let rawTitleCandidate: String
            if proseBlocks.count >= 3 {
                rawTitleCandidate = block1.decoded
            } else {
                // With exactly 2 prose blocks, block 1 may be `Title.` or `Title. Publisher, 2020.`
                rawTitleCandidate = Self.extractTitleFromTwoBlockSecondSegment(block1.decoded)
            }
            let cleanedTitle = Self.cleanExtractedTitle(rawTitleCandidate)
            return (parsedAuthors.authors, parsedAuthors.truncated, cleanedTitle)
        }

        // Case B: Single prose block (handwritten `thebibliography`, `IEEEtran.bst`, `elsarticle-num.bst`, etc.)
        let single = proseBlocks[0]
        let text = single.decoded

        // Subcase B1: Explicit quoted title (`“Title”` or `"Title"`)
        if let quotedSplit = Self.splitOnQuotedTitle(text) {
            let authorPart = Self.stripTrailingAuthorPunctuationAndYear(quotedSplit.beforeQuote)
            let parsedAuthors = authorPart.isEmpty
                ? (authors: [BibAuthor](), truncated: false)
                : parseAuthorSegmentString(authorPart, rawHint: single.raw)
            let cleanedTitle = Self.cleanExtractedTitle(quotedSplit.quotedTitle)
            return (parsedAuthors.authors, parsedAuthors.truncated, cleanedTitle)
        }

        // Subcase B2: APA-style parenthesized year right after author list (`Authors (1965). Title. ...`)
        if let apaSplit = Self.splitOnEarlyParenthesizedYear(text) {
            let parsedAuthors = parseAuthorSegmentString(apaSplit.beforeYear, rawHint: single.raw)
            if !parsedAuthors.authors.isEmpty {
                let titleCandidate = Self.extractLeadingTitleFromRemainder(apaSplit.afterYear)
                return (parsedAuthors.authors, parsedAuthors.truncated, Self.cleanExtractedTitle(titleCandidate))
            }
        }

        // Subcase B3: Peel leading Initial-First, Surname-Initials, or sentence-terminated Full-Name author list
        if let peeled = peelLeadingAuthorList(from: text) {
            let titleCandidate = Self.extractLeadingTitleFromRemainder(peeled.remainder)
            return (peeled.authors, peeled.truncated, Self.cleanExtractedTitle(titleCandidate))
        }

        // Subcase B4: Unparseable author — do NOT guess an author; extract title only if multi-segment with venue/year
        if let fallbackTitle = Self.extractAuthorlessTitleIfStructured(text) {
            return ([], false, Self.cleanExtractedTitle(fallbackTitle))
        }
        return ([], false, "")
    }

    private func parseAuthorBlock(rawBlock: String, decodedBlock: String) -> (authors: [BibAuthor], truncated: Bool) {
        let trimmedRaw = rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        // Braced institutional/corporate author in `.bbl`, e.g. `{World Health Organization}. 2021.`
        if trimmedRaw.hasPrefix("{"),
           let (innerCorp, afterIdx) = Self.readBalancedBraceGroup(Array(trimmedRaw), from: 0) {
            let tail = String(Array(trimmedRaw)[afterIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let innerDecoded = latexCodec.decode(innerCorp).trimmingCharacters(in: .whitespacesAndNewlines)
            if !innerDecoded.contains("\\"),
               innerDecoded.contains(" "),
               (tail.isEmpty || tail == "." || tail.first == "." || tail.first == "(") {
                return ([BibAuthor(givenName: "", familyName: innerDecoded)], false)
            }
        }
        let cleaned = Self.stripTrailingAuthorPunctuationAndYear(decodedBlock)
        guard !cleaned.isEmpty else { return ([], false) }
        return parseAuthorSegmentString(cleaned, rawHint: rawBlock)
    }

    private func parseAuthorSegmentString(_ segment: String, rawHint: String) -> (authors: [BibAuthor], truncated: Bool) {
        var s = Self.stripEditorAnnotations(segment).trimmingCharacters(in: .whitespacesAndNewlines)
        var truncated = false

        // Strip trailing `et al.` / `and others`
        if let etAlRange = s.range(
            of: #"(?:,?\s+(?:and\s+)?et\s+al\.?|,?\s+and\s+others)\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            truncated = true
            s = String(s[..<etAlRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        s = Self.trimPunctuation(s)
        guard !s.isEmpty else { return ([], truncated) }

        // Check Surname-First pair list: `Barron, A. R.` or `Bronstein, M. M., Bruna, J., and Veličković, P.`
        // or `Carroll, S. M. and Dickinson, B. W.`
        if let surnameFirstAuthors = Self.tryParseSurnameFirstAuthorPairs(s) {
            return (surnameFirstAuthors, truncated)
        }

        // Given-First author list separated by `, and `, ` and `, `, & `, ` & `, `, `
        let normalizedSeps = s
            .replacingOccurrences(of: #"\s*,\s*(?:and|&)\s+"#, with: " | ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:and|&)\s+"#, with: " | ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*,\s*"#, with: " | ", options: .regularExpression)

        let chunks = normalizedSeps
            .split(separator: "|", omittingEmptySubsequences: true)
            .map { Self.stripEditorAnnotations(String($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var authors: [BibAuthor] = []
        for chunk in chunks {
            let lower = chunk.lowercased()
            if lower == "et al." || lower == "et al" || lower == "others" {
                truncated = true
                continue
            }
            if let author = Self.parseSingleGivenFirstName(chunk) {
                authors.append(author)
            }
        }
        _ = rawHint
        return (authors, truncated)
    }

    private static func tryParseSurnameFirstAuthorPairs(_ input: String) -> [BibAuthor]? {
        // Normalize ` and ` / ` & ` between `Initials` and next `Surname, Initials` into `, `
        let normalized = input
            .replacingOccurrences(of: #"\s*,\s*(?:and|&)\s+"#, with: ", ", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\.)\s+(?:and|&)\s+"#, with: ", ", options: .regularExpression)

        let parts = normalized
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard parts.count >= 2, parts.count % 2 == 0 else {
            return nil
        }

        var result: [BibAuthor] = []
        for idx in stride(from: 0, to: parts.count, by: 2) {
            let surnameCand = parts[idx]
            let givenCand = parts[idx + 1]
            guard isPlausibleSurnameTokenSequence(surnameCand),
                  isInitialsSequence(givenCand)
            else {
                return nil
            }
            result.append(BibAuthor(givenName: givenCand, familyName: surnameCand))
        }
        return result.isEmpty ? nil : result
    }

    private static func parseSingleGivenFirstName(_ raw: String) -> BibAuthor? {
        let cleaned = trimPunctuation(stripEditorAnnotations(raw))
        guard !cleaned.isEmpty else { return nil }
        var words = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }

        let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"]
        if words.count >= 3, let last = words.last?.lowercased(), suffixes.contains(last) {
            words.removeLast()
        }

        if words.count == 1 {
            return isPlausibleSurnameWord(words[0]) ? BibAuthor(givenName: "", familyName: words[0]) : nil
        }

        var surnameStart = words.count - 1
        while surnameStart > 1 {
            let prevLower = words[surnameStart - 1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if lowercaseNameParticles.contains(prevLower) {
                surnameStart -= 1
            } else {
                break
            }
        }

        let given = words[0..<surnameStart].joined(separator: " ")
        let family = words[surnameStart..<words.count].joined(separator: " ")
        guard !family.isEmpty else { return nil }
        return BibAuthor(givenName: given, familyName: family)
    }

    // MARK: - Single-Block Leading Author List Peeler

    private func peelLeadingAuthorList(
        from text: String
    ) -> (authors: [BibAuthor], truncated: Bool, remainder: String)? {
        // 1. Try Initial-First author list (`L. A. Zadeh.`, `R. Belohlavek, J. Dauben, J. Klir, ...`, `T. Dao et al. ...`)
        if let initMatch = Self.matchLeadingInitialFirstAuthors(in: text) {
            return initMatch
        }

        // 2. Try Surname-First with Initials (`Barron, A. R. Universal...` or `Barron, A. R., & Cover, T. M., Bounds...`)
        if let surMatch = Self.matchLeadingSurnameInitialAuthors(in: text) {
            return surMatch
        }

        // 3. Try sentence-terminated Full-Name author list before first `. ` (`Yann LeCun, Yoshua Bengio, and Geoffrey Hinton. Deep learning.`)
        if let dotRange = Self.findFirstSentencePeriod(in: text) {
            let beforeDot = String(text[..<dotRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let afterDot = String(text[dotRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !afterDot.isEmpty, let fullAuthors = Self.tryMatchFullNameAuthorSentence(beforeDot) {
                return (fullAuthors.authors, fullAuthors.truncated, afterDot)
            }
        }

        return nil
    }

    private static func matchLeadingInitialFirstAuthors(
        in text: String
    ) -> (authors: [BibAuthor], truncated: Bool, remainder: String)? {
        // Pattern for one Initial-First author:
        // One or more dotted initials (`L.`, `J.A.`, `K.-I.`), optional particles (`del`, `van`), surname word(s), optional `(Ed.)`/`(Eds.)`
        let initialTok = #"(?:[A-ZÀ-ÖØ-ÞŠŽČĆĐŁ][\p{L}]?\.(?:-[A-ZÀ-ÖØ-ÞŠŽČĆĐŁ][\p{L}]?\.)*)"#
        let particleTok = #"(?:(?:von|van|de|del|della|der|di|du|la|le|ten|ter|zu|da)\s+)"#
        let surnameWord = #"(?:[A-ZÀ-ÖØ-ÞŠŽČĆĐŁ][\p{L}'’`\-]+)"#
        let editorOpt = #"(?:\s*\((?:Ed|Eds|ed|eds)\.?\))?"#
        let singleAuthorPattern = #"^\s*(?:(?:and|&)\s+)?"#
            + "(?<given>(?:\(initialTok)\\s*)+)"
            + "(?<family>\(particleTok)*\(surnameWord)(?:\\s+\(surnameWord))?)"
            + editorOpt

        guard let authorRegex = try? NSRegularExpression(pattern: singleAuthorPattern) else {
            return nil
        }

        var cursor = text.startIndex
        var authors: [BibAuthor] = []
        var truncated = false

        while cursor < text.endIndex {
            let slice = String(text[cursor...])
            let nsSlice = slice as NSString
            guard let m = authorRegex.firstMatch(in: slice, range: NSRange(location: 0, length: nsSlice.length)),
                  m.range.location == 0
            else {
                break
            }

            let givenRaw = nsSlice.substring(with: m.range(withName: "given")).trimmingCharacters(in: .whitespacesAndNewlines)
            let familyRaw = nsSlice.substring(with: m.range(withName: "family")).trimmingCharacters(in: .whitespacesAndNewlines)
            authors.append(BibAuthor(givenName: givenRaw, familyName: familyRaw))

            let matchedEndOffset = m.range.length
            let afterAuthorSlice = nsSlice.substring(from: matchedEndOffset)
            let consumedChars = slice.prefix(slice.count - afterAuthorSlice.count).count
            cursor = text.index(cursor, offsetBy: consumedChars)

            let tail = String(text[cursor...])

            // Check immediate `et al.` (`T. Dao et al. Title` or `, et al., Title`)
            if let etAlMatch = tail.range(
                of: #"^(?:\s*,\s*|\s+)(?:and\s+)?et\s+al\.?(?:\s*[.,]\s*|\s+)"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                truncated = true
                cursor = text.index(cursor, offsetBy: tail[..<etAlMatch.upperBound].count)
                let rem = String(text[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return rem.isEmpty ? nil : (authors, truncated, rem)
            }

            // Check `. ` sentence boundary right after surname / `(Eds.)` (`L. A. Zadeh. Fuzzy sets.`)
            if let dotMatch = tail.range(of: #"^\s*\.\s+"#, options: .regularExpression) {
                cursor = text.index(cursor, offsetBy: tail[..<dotMatch.upperBound].count)
                let rem = String(text[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return rem.isEmpty ? nil : (authors, truncated, rem)
            }

            // Check `, ` separator: either another Initial-First author follows, or author list ends here!
            if let commaMatch = tail.range(of: #"^\s*,\s+"#, options: .regularExpression) {
                let nextCursor = text.index(cursor, offsetBy: tail[..<commaMatch.upperBound].count)
                let afterComma = String(text[nextCursor...])
                let nsAfter = afterComma as NSString
                if authorRegex.firstMatch(in: afterComma, range: NSRange(location: 0, length: nsAfter.length)) != nil {
                    cursor = nextCursor
                    continue
                } else {
                    let rem = afterComma.trimmingCharacters(in: .whitespacesAndNewlines)
                    return rem.isEmpty ? nil : (authors, truncated, rem)
                }
            }

            // Check ` and ` / ` & ` without comma before next Initial-First author (`E. Whitfield and R. Patel, ...`)
            if let andMatch = tail.range(of: #"^\s+(?:and|&)\s+"#, options: .regularExpression) {
                let nextAfterAnd = String(tail[andMatch.lowerBound...])
                let nsAfter = nextAfterAnd as NSString
                if authorRegex.firstMatch(in: nextAfterAnd, range: NSRange(location: 0, length: nsAfter.length)) != nil {
                    // Leave ` and ` at start of slice so `singleAuthorPattern` consumes it
                    continue
                }
            }

            break
        }

        return nil
    }

    private static func matchLeadingSurnameInitialAuthors(
        in text: String
    ) -> (authors: [BibAuthor], truncated: Bool, remainder: String)? {
        let initialTok = #"(?:[A-ZÀ-ÖØ-ÞŠŽČĆĐŁ][\p{L}]?\.(?:-[A-ZÀ-ÖØ-ÞŠŽČĆĐŁ][\p{L}]?\.)*)"#
        let surnameTok = #"(?:[A-ZÀ-ÖØ-ÞŠŽČĆĐŁ][\p{L}'’`\-]*)"#
        let pairPattern = #"^\s*(?:(?:and|&)\s+)?"#
            + "(?<family>\(surnameTok)),\\s*(?<given>(?:\(initialTok)\\s*)+)"

        guard let pairRegex = try? NSRegularExpression(pattern: pairPattern) else {
            return nil
        }

        var cursor = text.startIndex
        var authors: [BibAuthor] = []
        var truncated = false

        while cursor < text.endIndex {
            let slice = String(text[cursor...])
            let nsSlice = slice as NSString
            guard let m = pairRegex.firstMatch(in: slice, range: NSRange(location: 0, length: nsSlice.length)),
                  m.range.location == 0
            else {
                break
            }
            let familyRaw = nsSlice.substring(with: m.range(withName: "family")).trimmingCharacters(in: .whitespacesAndNewlines)
            let givenRaw = nsSlice.substring(with: m.range(withName: "given")).trimmingCharacters(in: .whitespacesAndNewlines)
            authors.append(BibAuthor(givenName: givenRaw, familyName: familyRaw))

            let afterSlice = nsSlice.substring(from: m.range.length)
            let consumedChars = slice.prefix(slice.count - afterSlice.count).count
            cursor = text.index(cursor, offsetBy: consumedChars)
            let tail = String(text[cursor...])

            if let etAl = tail.range(
                of: #"^(?:,\s*)?(?:and\s+)?et\s+al\.?(?:\s*[.,]\s*|\s+)"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                truncated = true
                cursor = text.index(cursor, offsetBy: tail[..<etAl.upperBound].count)
                break
            }
            if let nextSep = tail.range(of: #"^(?:,\s*|\s+(?:and|&)\s+)"#, options: .regularExpression) {
                let probeIdx = text.index(cursor, offsetBy: tail[..<nextSep.upperBound].count)
                let probeStr = String(text[probeIdx...])
                if pairRegex.firstMatch(in: probeStr, range: NSRange(location: 0, length: (probeStr as NSString).length)) != nil {
                    cursor = probeIdx
                    continue
                }
            }
            // End of `Surname, A. B.` (already ended with `.` of initials!)
            if let ws = tail.range(of: #"^(?:,\s*|\s+)"#, options: .regularExpression) {
                cursor = text.index(cursor, offsetBy: tail[..<ws.upperBound].count)
            }
            break
        }

        guard !authors.isEmpty else { return nil }
        let rem = String(text[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return rem.isEmpty ? nil : (authors, truncated, rem)
    }

    private static func tryMatchFullNameAuthorSentence(
        _ sentence: String
    ) -> (authors: [BibAuthor], truncated: Bool)? {
        var s = stripEditorAnnotations(sentence).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(":"), !s.contains(";") else { return nil }

        var truncated = false
        if let etAl = s.range(
            of: #"(?:,?\s+(?:and\s+)?et\s+al\.?|,?\s+and\s+others)\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            truncated = true
            s = String(s[..<etAl.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let sepNormalized = s
            .replacingOccurrences(of: #"\s*,\s*(?:and|&)\s+"#, with: " | ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:and|&)\s+"#, with: " | ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*,\s*"#, with: " | ", options: .regularExpression)

        let chunks = sepNormalized
            .split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !chunks.isEmpty else { return nil }

        var parsed: [BibAuthor] = []
        for chunk in chunks {
            let words = chunk.split(whereSeparator: \.isWhitespace).map(String.init)
            // A full person name without comma has 2..3 tokens (`Yann LeCun`, `Aidan N. Gomez`, `Tomas Bueno Momčilović`)
            guard (2...4).contains(words.count) else { return nil }
            for (idx, w) in words.enumerated() {
                let bare = w.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
                let lower = bare.lowercased()
                if fullNameDisallowedWords.contains(lower) {
                    return nil
                }
                if lowercaseNameParticles.contains(lower) && idx > 0 && idx < words.count - 1 {
                    continue
                }
                guard let firstChar = bare.first, firstChar.isUppercase else {
                    return nil
                }
            }
            guard let author = parseSingleGivenFirstName(chunk) else { return nil }
            parsed.append(author)
        }
        return parsed.isEmpty ? nil : (parsed, truncated)
    }

    // MARK: - Title Boundary Helpers

    private static func extractTitleFromTwoBlockSecondSegment(_ block1: String) -> String {
        if let dotRange = findFirstSentencePeriod(in: block1) {
            let candidate = String(block1[..<dotRange.lowerBound])
            let after = String(block1[dotRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty {
                return candidate
            }
        }
        // Strip trailing `, YYYY.` if attached directly
        return block1.replacingOccurrences(
            of: #",\s*(?:1[4-9]\d{2}|20\d{2})[a-z]?\s*\.?\s*$"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func extractLeadingTitleFromRemainder(_ remainder: String) -> String {
        let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Handle `., ` (`Chaos at fifty., Phys. Today ...`)
        if let dotComma = trimmed.range(of: "., ") {
            return String(trimmed[..<dotComma.lowerBound])
        }

        // 1. If a genuine sentence-ending `. ` occurs (not an abbreviation like `J.` or `Atmos.`), take up to `. `
        if let dotRange = findFirstSentencePeriod(in: trimmed) {
            let beforeDot = String(trimmed[..<dotRange.lowerBound])
            // Ensure there isn't an earlier `, in:` or `, Proc.` or `, J.` venue start before a late period
            if let earlyCommaVenue = findEarlierCommaVenueBoundary(in: beforeDot) {
                return earlyCommaVenue
            }
            return beforeDot
        }

        // 2. No internal sentence period (comma-delimited style, e.g. `Fuzzy Logic: ..., Englewood Cliffs, NJ: Prentice-Hall, 1992.`)
        if let commaIdx = trimmed.firstIndex(of: ",") {
            return String(trimmed[..<commaIdx])
        }

        return trimmed
    }

    private static func findEarlierCommaVenueBoundary(in segmentBeforePeriod: String) -> String? {
        if let m = segmentBeforePeriod.range(
            of: #",\s+(?:in\s*:|In\s*:|vol\.?\s+\d|pp\.?\s+\d|(?:1[4-9]\d{2}|20\d{2})\b)"#,
            options: .regularExpression
        ) {
            return String(segmentBeforePeriod[..<m.lowerBound])
        }
        return nil
    }

    private static func extractAuthorlessTitleIfStructured(_ text: String) -> String? {
        // Only extract a title without author if there is a clear publication tail (e.g. `, 2019.` or `. Springer, 2020.`),
        // NOT a bare unstructured phrase with no year/venue!
        guard extractPublicationYear(from: text) != nil else {
            return nil
        }
        if let dotRange = findFirstSentencePeriod(in: text) {
            return String(text[..<dotRange.lowerBound])
        }
        if let commaIdx = text.firstIndex(of: ",") {
            return String(text[..<commaIdx])
        }
        return nil
    }

    private static func findFirstSentencePeriod(in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let dotIdx = text[searchStart...].firstIndex(of: ".") {
            let afterDot = text.index(after: dotIdx)
            guard afterDot < text.endIndex else { return nil }

            let nextCh = text[afterDot]
            guard nextCh.isWhitespace else {
                searchStart = afterDot
                continue
            }

            // Extract word immediately preceding `.`
            var wordStart = dotIdx
            while wordStart > text.startIndex {
                let prev = text.index(before: wordStart)
                if text[prev].isLetter || text[prev].isNumber || text[prev] == "-" {
                    wordStart = prev
                } else {
                    break
                }
            }
            let prevWord = String(text[wordStart..<dotIdx])
            let prevLower = prevWord.lowercased()

            // Skip single-letter initials (`J.`, `A.`) and standard bibliographic abbreviations (`Tech.`, `Vol.`, `Phys.`, `Atmos.`, `et al.`)
            if prevWord.count == 1 && prevWord.first?.isUppercase == true {
                searchStart = afterDot
                continue
            }
            if nonSentenceEndingAbbreviations.contains(prevLower) {
                searchStart = afterDot
                continue
            }

            var wsEnd = afterDot
            while wsEnd < text.endIndex && text[wsEnd].isWhitespace {
                wsEnd = text.index(after: wsEnd)
            }
            return dotIdx..<wsEnd
        }
        return nil
    }

    private static func splitOnQuotedTitle(_ text: String) -> (beforeQuote: String, quotedTitle: String)? {
        // 1. Typographic quotes `“...”` (produced by `LaTeXTextCodec` from `` ``...'' ``)
        if let openIdx = text.firstIndex(of: "“"),
           let closeIdx = text[text.index(after: openIdx)...].firstIndex(of: "”") {
            let before = String(text[..<openIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let inside = String(text[text.index(after: openIdx)..<closeIdx])
            if containsAlphabeticWord(inside) {
                return (before, inside)
            }
        }
        // 2. Straight ASCII quotes `"..."`
        if let openIdx = text.firstIndex(of: "\"") {
            let restStart = text.index(after: openIdx)
            if restStart < text.endIndex, let closeIdx = text[restStart...].firstIndex(of: "\"") {
                let before = String(text[..<openIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                let inside = String(text[restStart..<closeIdx])
                if containsAlphabeticWord(inside) {
                    return (before, inside)
                }
            }
        }
        return nil
    }

    private static func splitOnEarlyParenthesizedYear(_ text: String) -> (beforeYear: String, afterYear: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^(.{3,160}?)\s*\((1[4-9]\d{2}|20\d{2})[a-z]?\)\s*[.,:]?\s+(.+)$"#) else {
            return nil
        }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let before = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !before.isEmpty, !after.isEmpty else { return nil }
        return (before, after)
    }

    // MARK: - Persistent Identifier Extraction

    private struct ExtractedIdentifiers {
        var doi: String?
        var arxivID: String?
        var pmid: String?
        var url: String?
    }

    private static func extractIdentifiers(from rawBody: String) -> ExtractedIdentifiers {
        var result = ExtractedIdentifiers()
        var candidateURLs: [String] = []
        var candidateDOIs: [String] = []
        var candidateArXivs: [String] = []
        var candidatePMIDs: [String] = []

        let chars = Array(rawBody)
        var proseWithoutMacroURLs = ""
        proseWithoutMacroURLs.reserveCapacity(chars.count)

        var i = 0
        while i < chars.count {
            if chars[i] == "\\" {
                var cmdEnd = i + 1
                while cmdEnd < chars.count && chars[cmdEnd].isLetter {
                    cmdEnd += 1
                }
                let cmd = String(chars[(i + 1)..<cmdEnd])
                var cursor = cmdEnd
                skipSpacesAndNewlines(chars, index: &cursor)

                if cmd == "url" || cmd == "nolinkurl" || cmd == "path" {
                    if let (inner, nextIdx) = readBalancedBraceGroup(chars, from: cursor) {
                        let cleaned = cleanMacroURLString(inner)
                        if cleaned.lowercased().hasPrefix("doi:") {
                            candidateDOIs.append(cleaned)
                        } else if cleaned.lowercased().hasPrefix("http://") || cleaned.lowercased().hasPrefix("https://") {
                            candidateURLs.append(cleaned)
                        } else if let doi = cleanCandidateDOI(cleaned) {
                            candidateDOIs.append(doi)
                        }
                        proseWithoutMacroURLs.append(" ")
                        i = nextIdx
                        continue
                    }
                } else if cmd == "doi" {
                    if let (inner, nextIdx) = readBalancedBraceGroup(chars, from: cursor) {
                        candidateDOIs.append(cleanMacroURLString(inner))
                        proseWithoutMacroURLs.append(" ")
                        i = nextIdx
                        continue
                    }
                } else if cmd == "href" {
                    skipOptionalBracketGroup(chars, index: &cursor)
                    skipSpacesAndNewlines(chars, index: &cursor)
                    if let (rawU, afterU) = readBalancedBraceGroup(chars, from: cursor) {
                        let cleanedU = cleanMacroURLString(rawU)
                        if !cleanedU.isEmpty {
                            candidateURLs.append(cleanedU)
                        }
                        var afterLabel = afterU
                        skipSpacesAndNewlines(chars, index: &afterLabel)
                        if let (labelInner, nextIdx) = readBalancedBraceGroup(chars, from: afterLabel) {
                            proseWithoutMacroURLs.append(labelInner)
                            i = nextIdx
                            continue
                        }
                        proseWithoutMacroURLs.append(" ")
                        i = afterU
                        continue
                    }
                } else if cmd == "eprint" {
                    skipOptionalBracketGroup(chars, index: &cursor)
                    skipSpacesAndNewlines(chars, index: &cursor)
                    if let (inner, nextIdx) = readBalancedBraceGroup(chars, from: cursor) {
                        candidateArXivs.append(cleanMacroURLString(inner))
                        proseWithoutMacroURLs.append(" ")
                        i = nextIdx
                        continue
                    }
                }
            }
            proseWithoutMacroURLs.append(chars[i])
            i += 1
        }

        // Scan remaining text for bare URLs `https?://...`
        var textAfterURLs = proseWithoutMacroURLs
        if let urlRegex = try? NSRegularExpression(pattern: #"https?://[^\s{}<>"]+"#, options: .caseInsensitive) {
            let ns = proseWithoutMacroURLs as NSString
            let matches = urlRegex.matches(in: proseWithoutMacroURLs, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let rawMatch = ns.substring(with: m.range)
                let trimmedU = trimTrailingURLPunctuation(rawMatch)
                if !trimmedU.isEmpty {
                    candidateURLs.insert(trimmedU, at: 0)
                }
                textAfterURLs = (textAfterURLs as NSString).replacingCharacters(in: m.range, with: " ")
            }
        }

        // Inspect all collected URLs for embedded DOI, arXiv ID, or PubMed PMID
        for u in candidateURLs {
            if result.url == nil && (u.lowercased().hasPrefix("http://") || u.lowercased().hasPrefix("https://")) {
                result.url = u
            }
            if let urlDOI = extractDOIFromURLString(u) {
                candidateDOIs.append(urlDOI)
            }
            if let urlArXiv = extractArXivFromURLString(u) {
                candidateArXivs.append(urlArXiv)
            }
            if let urlPMID = extractPMIDFromURLString(u) {
                candidatePMIDs.append(urlPMID)
            }
        }

        // Scan bare text (with URLs removed) for `doi:...`, `arXiv:...` / `arXiv preprint: ...`, `PMID: ...`
        var textAfterDOIs = textAfterURLs
        if let doiRegex = try? NSRegularExpression(pattern: #"(?i)\bdoi\s*:\s*([^\s,;{}]+)"#) {
            let ns = textAfterURLs as NSString
            let matches = doiRegex.matches(in: textAfterURLs, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                candidateDOIs.append(ns.substring(with: m.range(at: 1)))
            }
            textAfterDOIs = doiRegex.stringByReplacingMatches(
                in: textAfterURLs,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: " "
            )
        }

        if let arxivRegex = try? NSRegularExpression(
            pattern: #"(?i)\barxiv(?:\s+preprint)?\s*:?\s*(?:arxiv\s*:\s*)?((?:[a-z\-]+(?:\.[a-z]{2})?/\d{7}|\d{4}\.\d{4,5})(?:v\d+)?)\b"#
        ) {
            let ns = textAfterDOIs as NSString
            for m in arxivRegex.matches(in: textAfterDOIs, range: NSRange(location: 0, length: ns.length)) {
                candidateArXivs.append(ns.substring(with: m.range(at: 1)))
            }
        }

        if let pmidRegex = try? NSRegularExpression(pattern: #"(?i)\bpmid\s*:?\s*(\d{1,8})\b"#) {
            let ns = textAfterDOIs as NSString
            for m in pmidRegex.matches(in: textAfterDOIs, range: NSRange(location: 0, length: ns.length)) {
                candidatePMIDs.append(ns.substring(with: m.range(at: 1)))
            }
        }

        for cand in candidateDOIs {
            if let validDOI = cleanCandidateDOI(cand) {
                result.doi = validDOI
                break
            }
        }
        for cand in candidateArXivs {
            let trimmed = cand.trimmingCharacters(in: .whitespacesAndNewlines)
            if ScholarlyIdentifierValidator.validateArXivID(trimmed).isValid {
                result.arxivID = trimmed
                break
            }
        }
        for cand in candidatePMIDs {
            let pmidCheck = ScholarlyIdentifierValidator.validatePMID(cand)
            if pmidCheck.isValid {
                result.pmid = pmidCheck.normalized
                break
            }
        }

        return result
    }

    private static func cleanCandidateDOI(_ raw: String) -> String? {
        var s = cleanMacroURLString(raw)
        if let pctDecoded = s.removingPercentEncoding {
            s = pctDecoded
        }
        // Repeatedly strip resolver URL prefixes (`http://doi.org/https://doi.org/10....`, `doi:...`) while preserving suffix case
        let prefixes = [
            "https://doi.org/", "http://doi.org/",
            "https://dx.doi.org/", "http://dx.doi.org/",
            "https://www.doi.org/", "http://www.doi.org/",
            "doi.org/", "dx.doi.org/", "www.doi.org/",
            "doi:"
        ]
        var strippedAny = true
        while strippedAny && !s.isEmpty {
            strippedAny = false
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = s.lowercased()
            for p in prefixes where lower.hasPrefix(p) {
                s = String(s.dropFirst(p.count))
                strippedAny = true
                break
            }
        }
        s = trimTrailingURLPunctuation(s)
        guard s.hasPrefix("10."), ScholarlyIdentifierValidator.validateDOISyntax(s).isValid else {
            return nil
        }
        return s
    }

    private static func extractDOIFromURLString(_ urlString: String) -> String? {
        let lower = urlString.lowercased()
        guard lower.contains("doi.org/") else { return nil }
        return cleanCandidateDOI(urlString)
    }

    private static func extractArXivFromURLString(_ urlString: String) -> String? {
        guard let comps = URLComponents(string: urlString),
              let host = comps.host?.lowercased(),
              (host == "arxiv.org" || host.hasSuffix(".arxiv.org"))
        else {
            return nil
        }
        let path = comps.path
        let lowerPath = path.lowercased()
        let rawID: String
        if lowerPath.hasPrefix("/abs/") {
            rawID = String(path.dropFirst(5))
        } else if lowerPath.hasPrefix("/pdf/") {
            rawID = String(path.dropFirst(5))
        } else {
            return nil
        }
        var cleaned = rawID.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\r\n"))
        if cleaned.lowercased().hasSuffix(".pdf") {
            cleaned = String(cleaned.dropLast(4))
        }
        return ScholarlyIdentifierValidator.validateArXivID(cleaned).isValid ? cleaned : nil
    }

    private static func extractPMIDFromURLString(_ urlString: String) -> String? {
        let lower = urlString.lowercased()
        guard let range = lower.range(of: "pubmed.ncbi.nlm.nih.gov/") else { return nil }
        let rest = urlString[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let digits = String(rest.prefix(while: \.isNumber))
        let check = ScholarlyIdentifierValidator.validatePMID(digits)
        return check.isValid ? check.normalized : nil
    }

    private static func trimTrailingURLPunctuation(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last {
            if last == "." || last == "," || last == ";" || last == ":" || last == "]" {
                s.removeLast()
            } else if last == ")" {
                let openCount = s.filter { $0 == "(" }.count
                let closeCount = s.filter { $0 == ")" }.count
                if closeCount > openCount {
                    s.removeLast()
                } else {
                    break
                }
            } else {
                break
            }
        }
        return s
    }

    // MARK: - Year Extraction

    private static func cleanTextForYearScan(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?i)\bdoi\s*:\s*\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\barxiv(?:\s+preprint)?\s*:?\s*\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bpmid\s*:?\s*\d+"#, with: " ", options: .regularExpression)
    }

    private static func extractPublicationYear(from cleanedProse: String) -> Int? {
        // 1. Check whitespace-preceded or start-of-string parenthesized year `(2013)` / `(2017a)`
        if let parenRegex = try? NSRegularExpression(pattern: #"(?:^|\s)\((1[4-9]\d{2}|20[0-3]\d)[a-z]?\)"#) {
            let ns = cleanedProse as NSString
            let matches = parenRegex.matches(in: cleanedProse, range: NSRange(location: 0, length: ns.length))
            if let lastMatch = matches.last, let yr = Int(ns.substring(with: lastMatch.range(at: 1))) {
                return yr
            }
        }

        // 2. Remove page/numeric ranges (`1441–1460`, `1474-1484`) and pagination/volume/issue numbers (`no. 1954`, `pp. 1995`)
        let withoutRangesAndPagination = cleanedProse
            .replacingOccurrences(of: #"\b\d+\s*[-–—]\s*\d+\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?i)\b(?:pp?|pages?|no|num|number|vol|volume|issue|art|id|grant)\.?\s*~?\s*\d+\b"#,
                with: " ",
                options: .regularExpression
            )

        guard let yearRegex = try? NSRegularExpression(pattern: #"(?<![\d\-–—/.])(1[4-9]\d{2}|20[0-3]\d)[a-z]?(?![\d\-–—])"#) else {
            return nil
        }
        let ns = withoutRangesAndPagination as NSString
        let matches = yearRegex.matches(in: withoutRangesAndPagination, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return nil }
        return Int(ns.substring(with: last.range(at: 1)))
    }

    private static func extractYearFromOptionalLabel(_ decodedLabel: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(1[4-9]\d{2}|20[0-3]\d)[a-z]?\b"#) else {
            return nil
        }
        let ns = decodedLabel as NSString
        guard let last = regex.matches(in: decodedLabel, range: NSRange(location: 0, length: ns.length)).last else {
            return nil
        }
        return Int(ns.substring(with: last.range(at: 1)))
    }

    // MARK: - Raw LaTeX Block Preprocessing

    private static func stripLineCommentsOutsideVerbatimMacros(_ input: String) -> String {
        let chars = Array(input)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                if i + 1 < chars.count && !chars[i + 1].isLetter {
                    out.append(c)
                    out.append(chars[i + 1])
                    i += 2
                    continue
                }
                var cmdEnd = i + 1
                while cmdEnd < chars.count && chars[cmdEnd].isLetter {
                    cmdEnd += 1
                }
                let cmd = String(chars[(i + 1)..<cmdEnd])
                if cmd == "url" || cmd == "nolinkurl" || cmd == "path" || cmd == "href" {
                    out.append("\\")
                    out.append(cmd)
                    var cursor = cmdEnd
                    while cursor < chars.count && (chars[cursor] == " " || chars[cursor] == "\t") {
                        out.append(chars[cursor])
                        cursor += 1
                    }
                    if cmd == "href", cursor < chars.count, chars[cursor] == "[" {
                        let startBr = cursor
                        skipOptionalBracketGroup(chars, index: &cursor)
                        out.append(String(chars[startBr..<cursor]))
                        while cursor < chars.count && (chars[cursor] == " " || chars[cursor] == "\t") {
                            out.append(chars[cursor])
                            cursor += 1
                        }
                    }
                    if let (rawArg, nextIdx) = readBalancedBraceGroup(chars, from: cursor) {
                        out.append("{")
                        out.append(rawArg)
                        out.append("}")
                        i = nextIdx
                        continue
                    }
                }
            }
            if c == "%" {
                while i < chars.count && chars[i] != "\n" {
                    i += 1
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private static func splitOnNewblock(_ body: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\\newblock(?![A-Za-z])"#) else {
            return [body]
        }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty {
            return [body]
        }
        var segments: [String] = []
        var lastEnd = 0
        for m in matches {
            segments.append(ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd)))
            lastEnd = m.range.location + m.range.length
        }
        segments.append(ns.substring(from: lastEnd))
        return segments
    }

    private static func stripNatexlabAndPenalties(_ raw: String) -> String {
        let chars = Array(raw)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" {
                var cmdEnd = i + 1
                while cmdEnd < chars.count && chars[cmdEnd].isLetter {
                    cmdEnd += 1
                }
                let cmd = String(chars[(i + 1)..<cmdEnd])
                if cmd == "natexlab" {
                    var cursor = cmdEnd
                    skipSpacesAndNewlines(chars, index: &cursor)
                    if let (_, nextIdx) = readBalancedBraceGroup(chars, from: cursor) {
                        i = nextIdx
                        continue
                    }
                } else if cmd == "penalty" {
                    var cursor = cmdEnd
                    if cursor < chars.count && chars[cursor] == "-" { cursor += 1 }
                    while cursor < chars.count && chars[cursor].isNumber { cursor += 1 }
                    i = cursor
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private static func prepareRawBlockForProseDecoding(_ rawBlock: String) -> String {
        let chars = Array(stripNatexlabAndPenalties(rawBlock))
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0

        let droppedNoArgCommands: Set<String> = [
            "BIBentrySTDinterwordspacing", "BIBentryALTinterwordspacing", "BIBdecl",
            "relax", "allowbreak", "urlprefix", "em", "it", "bf", "sc", "rm", "tt", "sl", "upshape"
        ]

        while i < chars.count {
            if chars[i] == "\\" {
                var cmdEnd = i + 1
                while cmdEnd < chars.count && chars[cmdEnd].isLetter {
                    cmdEnd += 1
                }
                let cmd = String(chars[(i + 1)..<cmdEnd])
                var cursor = cmdEnd

                if cmd == "url" || cmd == "nolinkurl" || cmd == "path" || cmd == "doi" {
                    skipSpacesAndNewlines(chars, index: &cursor)
                    if let (_, nextIdx) = readBalancedBraceGroup(chars, from: cursor) {
                        out.append(" ")
                        i = nextIdx
                        continue
                    }
                } else if cmd == "href" {
                    skipSpacesAndNewlines(chars, index: &cursor)
                    skipOptionalBracketGroup(chars, index: &cursor)
                    skipSpacesAndNewlines(chars, index: &cursor)
                    if let (_, afterU) = readBalancedBraceGroup(chars, from: cursor) {
                        var lblCursor = afterU
                        skipSpacesAndNewlines(chars, index: &lblCursor)
                        if let (lblInner, nextIdx) = readBalancedBraceGroup(chars, from: lblCursor) {
                            let trimmedLbl = lblInner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            let labelIsURLOrDOI = trimmedLbl.hasPrefix("http://")
                                || trimmedLbl.hasPrefix("https://")
                                || trimmedLbl.hasPrefix("doi:")
                                || trimmedLbl.hasPrefix("\\path{")
                                || trimmedLbl.hasPrefix("\\url{")
                            if labelIsURLOrDOI {
                                out.append(" ")
                            } else {
                                out.append("{")
                                out.append(prepareRawBlockForProseDecoding(lblInner))
                                out.append("}")
                            }
                            i = nextIdx
                            continue
                        }
                        out.append(" ")
                        i = afterU
                        continue
                    }
                } else if cmd == "bibinfo" || cmd == "BIBforeignlanguage" {
                    skipSpacesAndNewlines(chars, index: &cursor)
                    if let (_, afterFirst) = readBalancedBraceGroup(chars, from: cursor) {
                        var valCursor = afterFirst
                        skipSpacesAndNewlines(chars, index: &valCursor)
                        if let (valInner, nextIdx) = readBalancedBraceGroup(chars, from: valCursor) {
                            out.append("{")
                            out.append(prepareRawBlockForProseDecoding(valInner))
                            out.append("}")
                            i = nextIdx
                            continue
                        }
                    }
                } else if droppedNoArgCommands.contains(cmd) {
                    if cursor < chars.count && chars[cursor] == " " {
                        cursor += 1
                    }
                    out.append(" ")
                    i = cursor
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private static func cleanDecodedProseSegment(_ decoded: String) -> String {
        let stripped = decoded
            .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?i)\bdoi\s*:\s*\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bpmid\s*:?\s*\d+\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{2009}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([.,;:])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([.,])\s*,+"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped
    }

    // MARK: - Low-Level String Utilities

    private static func cleanExtractedTitle(_ rawTitle: String) -> String {
        var s = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip outer quotes if still wrapped
        if (s.hasPrefix("“") && s.hasSuffix("”")) || (s.hasPrefix("\"") && s.hasSuffix("\"")) {
            if s.count >= 2 {
                s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        while let last = s.last, (last == "." || last == "," || last == ";") {
            s.removeLast()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTrailingAuthorPunctuationAndYear(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip trailing `. 2015.` or `(2015).` (`acl_natbib` / `apalike` author block)
        s = s.replacingOccurrences(
            of: #"(?:[.,]?\s*\((?:1[4-9]\d{2}|20\d{2})[a-z]?\)\.?|\.\s*(?:1[4-9]\d{2}|20\d{2})[a-z]?\.?)\s*$"#,
            with: "",
            options: .regularExpression
        )
        s = stripEditorAnnotations(s)
        return trimPunctuation(s)
    }

    private static func stripEditorAnnotations(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\s*\((?:Ed|Eds|ed|eds|Editor|Editors)\.?\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #",\s*(?:editors?|eds?\.?)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static func trimPunctuation(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = s.first, (first == "," || first == ";" || first == ":") {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let last = s.last, (last == "," || last == ";") {
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.hasSuffix(".") && !isInitialsSequence(s) {
            s.removeLast()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isInitialsSequence(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...4).contains(tokens.count) else { return false }
        for tok in tokens {
            guard tok.range(
                of: #"^[A-ZÀ-ÖØ-ÞŠŽČĆĐŁ][\p{L}]?\.(?:-[A-ZÀ-ÖØ-ÞŠŽČĆĐŁ][\p{L}]?\.?)*$"#,
                options: .regularExpression
            ) != nil else {
                return false
            }
        }
        return true
    }

    private static func isPlausibleSurnameTokenSequence(_ candidate: String) -> Bool {
        let words = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...3).contains(words.count) else { return false }
        guard let last = words.last, isPlausibleSurnameWord(last) else { return false }
        for w in words.dropLast() {
            let lower = w.lowercased()
            if lowercaseNameParticles.contains(lower) || isPlausibleSurnameWord(w) {
                continue
            }
            return false
        }
        return true
    }

    private static func isPlausibleSurnameWord(_ word: String) -> Bool {
        guard !word.isEmpty, let first = word.first, first.isUppercase else { return false }
        if word.hasSuffix(".") { return false }
        return word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }
    }

    private static func containsAlphabeticWord(_ s: String) -> Bool {
        s.contains(where: \.isLetter)
    }

    private static func cleanMacroURLString(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\%", with: "%")
            .replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\#", with: "#")
            .replacingOccurrences(of: "\\&", with: "&")
            .replacingOccurrences(of: "\\~", with: "~")
    }

    private static func skipSpacesAndNewlines(_ chars: [Character], index: inout Int) {
        while index < chars.count && (chars[index] == " " || chars[index] == "\t" || chars[index] == "\r" || chars[index] == "\n") {
            index += 1
        }
    }

    private static func skipOptionalBracketGroup(_ chars: [Character], index: inout Int) {
        guard index < chars.count, chars[index] == "[" else { return }
        var bracketDepth = 1
        var braceDepth = 0
        var cursor = index + 1
        while cursor < chars.count {
            let c = chars[cursor]
            if c == "\\" {
                cursor += 2
                continue
            }
            if c == "{" {
                braceDepth += 1
            } else if c == "}" && braceDepth > 0 {
                braceDepth -= 1
            } else if braceDepth == 0 {
                if c == "[" {
                    bracketDepth += 1
                } else if c == "]" {
                    bracketDepth -= 1
                    if bracketDepth == 0 {
                        index = cursor + 1
                        return
                    }
                }
            }
            cursor += 1
        }
    }

    private static func readBalancedBraceGroup(_ chars: [Character], from start: Int) -> (String, Int)? {
        guard start < chars.count, chars[start] == "{" else { return nil }
        var depth = 1
        var cursor = start + 1
        while cursor < chars.count {
            let c = chars[cursor]
            if c == "\\" {
                cursor += 2
                continue
            }
            if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    return (String(chars[(start + 1)..<cursor]), cursor + 1)
                }
            }
            cursor += 1
        }
        return nil
    }
}
