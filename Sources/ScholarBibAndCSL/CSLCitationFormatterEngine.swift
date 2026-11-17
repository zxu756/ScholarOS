import Foundation
import ScholarModels

// MARK: - CSL In-Text Modes, Locators & Rich Formatted Output Models

public enum InTextCitationMode: String, Sendable, Codable, Hashable, CaseIterable {
    case parenthetical
    case narrative
}

public struct CitationLocator: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
        case page
        case pages
        case chapter
        case section
        case figure
        case table
        case equation

        public var apaAbbreviation: String {
            switch self {
            case .page: return "p."
            case .pages: return "pp."
            case .chapter: return "chap."
            case .section: return "sec."
            case .figure: return "fig."
            case .table: return "tbl."
            case .equation: return "eq."
            }
        }
    }

    public let kind: Kind
    public let value: String

    public init(kind: Kind = .page, value: String) {
        self.kind = kind
        self.value = value
    }
}

public struct CSLTextRun: Sendable, Codable, Hashable {
    public enum Formatting: String, Sendable, Codable, Hashable {
        case plain
        case italic
        case bold
        case superscript
        case link
    }

    public let text: String
    public let formatting: Formatting
    public let destinationURL: String?

    public init(text: String, formatting: Formatting = .plain, destinationURL: String? = nil) {
        self.text = text
        self.formatting = formatting
        self.destinationURL = destinationURL
    }
}

public struct CSLFormattedCitation: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(style.rawValue)::\(citeKeys.joined(separator: "+"))" }
    public let style: CitationFormatStyle
    public let citeKeys: [String]
    public let inTextParenthetical: String
    public let inTextNarrative: String
    public let inTextSuperscript: String
    public let inTextLaTeX: String
    public let inTextTypst: String
    public let bibliographyPlainText: String
    public let bibliographyUnnumberedPlainText: String
    public let bibliographyMarkdown: String
    public let bibliographyLaTeX: String
    public let bibliographyRuns: [CSLTextRun]
    public let citationNumber: Int?
    public let yearDisambiguationSuffix: String

    public init(
        style: CitationFormatStyle,
        citeKeys: [String],
        inTextParenthetical: String,
        inTextNarrative: String,
        inTextSuperscript: String,
        inTextLaTeX: String,
        inTextTypst: String,
        bibliographyPlainText: String,
        bibliographyUnnumberedPlainText: String,
        bibliographyMarkdown: String,
        bibliographyLaTeX: String,
        bibliographyRuns: [CSLTextRun],
        citationNumber: Int? = nil,
        yearDisambiguationSuffix: String = ""
    ) {
        self.style = style
        self.citeKeys = citeKeys
        self.inTextParenthetical = inTextParenthetical
        self.inTextNarrative = inTextNarrative
        self.inTextSuperscript = inTextSuperscript
        self.inTextLaTeX = inTextLaTeX
        self.inTextTypst = inTextTypst
        self.bibliographyPlainText = bibliographyPlainText
        self.bibliographyUnnumberedPlainText = bibliographyUnnumberedPlainText
        self.bibliographyMarkdown = bibliographyMarkdown
        self.bibliographyLaTeX = bibliographyLaTeX
        self.bibliographyRuns = bibliographyRuns
        self.citationNumber = citationNumber
        self.yearDisambiguationSuffix = yearDisambiguationSuffix
    }
}

public struct CSLFormattedBibliography: Sendable, Codable, Hashable {
    public let style: CitationFormatStyle
    public let items: [CSLFormattedCitation]
    public let plainText: String
    public let markdown: String
    public let latexEnvironment: String
    public let citationNumbersByCiteKey: [String: Int]
    public let yearSuffixesByCiteKey: [String: String]

    public init(
        style: CitationFormatStyle,
        items: [CSLFormattedCitation],
        plainText: String,
        markdown: String,
        latexEnvironment: String,
        citationNumbersByCiteKey: [String: Int],
        yearSuffixesByCiteKey: [String: String]
    ) {
        self.style = style
        self.items = items
        self.plainText = plainText
        self.markdown = markdown
        self.latexEnvironment = latexEnvironment
        self.citationNumbersByCiteKey = citationNumbersByCiteKey
        self.yearSuffixesByCiteKey = yearSuffixesByCiteKey
    }
}

// MARK: - Pure-Swift 5-Style CSL Citation & Bibliography Formatting Engine

public struct CSLCitationFormatterEngine: Sendable {

    /// ISO-4 / NLM standard journal title abbreviations used by Nature and Vancouver/ICMJE styles.
    public static let iso4JournalAbbreviations: [String: String] = [
        "advances in neural information processing systems": "Adv. Neural Inf. Process. Syst.",
        "advances in neural information processing systems (neurips)": "Adv. Neural Inf. Process. Syst.",
        "neurips": "Adv. Neural Inf. Process. Syst.",
        "nips": "Adv. Neural Inf. Process. Syst.",
        "proceedings of the national academy of sciences": "Proc. Natl. Acad. Sci. U.S.A.",
        "journal of machine learning research": "J. Mach. Learn. Res.",
        "ieee transactions on pattern analysis and machine intelligence": "IEEE Trans. Pattern Anal. Mach. Intell.",
        "international journal of computer vision": "Int. J. Comput. Vis.",
        "communications of the acm": "Commun. ACM",
        "journal of the acm": "J. ACM",
        "transactions of the association for computational linguistics": "Trans. Assoc. Comput. Linguist.",
        "nature machine intelligence": "Nat. Mach. Intell.",
        "nature communications": "Nat. Commun.",
        "nature methods": "Nat. Methods",
        "nature biotechnology": "Nat. Biotechnol.",
        "nature medicine": "Nat. Med.",
        "science": "Science",
        "nature": "Nature",
        "cell": "Cell",
        "the new england journal of medicine": "N. Engl. J. Med.",
        "new england journal of medicine": "N. Engl. J. Med.",
        "the lancet": "Lancet",
        "jama": "JAMA",
        "bmj": "BMJ",
        "nucleic acids research": "Nucleic Acids Res.",
        "bioinformatics": "Bioinformatics",
        "plos computational biology": "PLoS Comput. Biol.",
        "plos one": "PLoS ONE",
        "journal of the american medical informatics association": "J. Am. Med. Inform. Assoc.",
        "journal of the american chemical society": "J. Am. Chem. Soc.",
        "physical review letters": "Phys. Rev. Lett."
    ]

    private static let unicodeSuperscriptDigits: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "-": "⁻", "–": "⁻", ",": "˒"
    ]

    public init() {}

    // MARK: - Single Entry Formatting

    public func formatEntry(
        _ entry: BibliographyEntry,
        style: CitationFormatStyle,
        citationNumber: Int = 1,
        yearDisambiguationSuffix: String = "",
        locator: CitationLocator? = nil
    ) -> CSLFormattedCitation {
        let runs: [CSLTextRun]
        let prefixNumberPlain: String
        let prefixNumberMarkdown: String
        let prefixNumberLaTeX: String

        switch style {
        case .apa7:
            runs = buildAPA7BibliographyRuns(for: entry, yearSuffix: yearDisambiguationSuffix)
            prefixNumberPlain = ""
            prefixNumberMarkdown = ""
            prefixNumberLaTeX = ""
        case .ieee:
            runs = buildIEEEBibliographyRuns(for: entry)
            prefixNumberPlain = "[\(citationNumber)] "
            prefixNumberMarkdown = "[\(citationNumber)] "
            prefixNumberLaTeX = ""
        case .acm:
            runs = buildACMBibliographyRuns(for: entry, yearSuffix: yearDisambiguationSuffix)
            prefixNumberPlain = ""
            prefixNumberMarkdown = ""
            prefixNumberLaTeX = ""
        case .nature:
            runs = buildNatureBibliographyRuns(for: entry)
            prefixNumberPlain = "\(citationNumber). "
            prefixNumberMarkdown = "\(citationNumber). "
            prefixNumberLaTeX = ""
        case .vancouver:
            runs = buildVancouverBibliographyRuns(for: entry)
            prefixNumberPlain = "\(citationNumber). "
            prefixNumberMarkdown = "\(citationNumber). "
            prefixNumberLaTeX = ""
        }

        let unnumberedPlain = renderRunsPlainText(runs)
        let numberedPlain = prefixNumberPlain + unnumberedPlain
        let renderedMarkdown = prefixNumberMarkdown + renderRunsMarkdown(runs)
        let renderedBibItemLaTeX = "\\bibitem{\(entry.citeKey)} \(prefixNumberLaTeX)\(renderRunsLaTeX(runs))"

        let parenthetical = formatSingleInText(
            entry: entry,
            style: style,
            mode: .parenthetical,
            citationNumber: citationNumber,
            yearSuffix: yearDisambiguationSuffix,
            locator: locator
        )
        let narrative = formatSingleInText(
            entry: entry,
            style: style,
            mode: .narrative,
            citationNumber: citationNumber,
            yearSuffix: yearDisambiguationSuffix,
            locator: locator
        )
        let superscriptStr = style == .nature
            ? Self.toUnicodeSuperscript("\(citationNumber)")
            : parenthetical

        let latexCite: String = {
            switch style {
            case .apa7, .acm:
                return "\\citep{\(entry.citeKey)}"
            case .ieee, .vancouver:
                return "\\cite{\(entry.citeKey)}"
            case .nature:
                return "\\textsuperscript{\(citationNumber)}"
            }
        }()

        let typstCite = "@\(entry.citeKey)"

        return CSLFormattedCitation(
            style: style,
            citeKeys: [entry.citeKey],
            inTextParenthetical: parenthetical,
            inTextNarrative: narrative,
            inTextSuperscript: superscriptStr,
            inTextLaTeX: latexCite,
            inTextTypst: typstCite,
            bibliographyPlainText: numberedPlain,
            bibliographyUnnumberedPlainText: unnumberedPlain,
            bibliographyMarkdown: renderedMarkdown,
            bibliographyLaTeX: renderedBibItemLaTeX,
            bibliographyRuns: runs,
            citationNumber: isNumericStyle(style) ? citationNumber : nil,
            yearDisambiguationSuffix: yearDisambiguationSuffix
        )
    }

    // MARK: - Multi-Citation Cluster Formatting (`[1]–[3]`, `(Vaswani et al., 2017; Devlin et al., 2019)`)

    public func formatInTextCluster(
        citeKeys: [String],
        in library: [String: BibliographyEntry],
        style: CitationFormatStyle,
        mode: InTextCitationMode = .parenthetical,
        orderOfAppearance: [String] = [],
        locators: [String: CitationLocator] = [:]
    ) -> String {
        let validEntries = citeKeys.compactMap { library[$0] }
        guard !validEntries.isEmpty else { return "" }

        let numberMap = assignCitationNumbers(
            entries: Array(library.values),
            style: style,
            citedOrder: orderOfAppearance.isEmpty ? citeKeys : orderOfAppearance
        )
        let suffixMap = computeYearDisambiguationSuffixes(entries: Array(library.values), style: style)

        if validEntries.count == 1 {
            let e = validEntries[0]
            return formatSingleInText(
                entry: e,
                style: style,
                mode: mode,
                citationNumber: numberMap[e.citeKey] ?? 1,
                yearSuffix: suffixMap[e.citeKey] ?? "",
                locator: locators[e.citeKey]
            )
        }

        switch style {
        case .ieee:
            let nums = validEntries.compactMap { numberMap[$0.citeKey] }
            let compressed = Self.compressIEEEBracketedRanges(nums)
            if mode == .narrative {
                let lead = authorShortLabel(for: validEntries[0], style: .ieee, parenthetical: false)
                return "\(lead) \(compressed)"
            }
            return compressed

        case .nature:
            let nums = validEntries.compactMap { numberMap[$0.citeKey] }
            let compactRange = Self.compressPlainNumericRanges(nums, separator: ",")
            let sup = Self.toUnicodeSuperscript(compactRange)
            if mode == .narrative {
                let lead = authorShortLabel(for: validEntries[0], style: .nature, parenthetical: false)
                return "\(lead)\(sup)"
            }
            return sup

        case .vancouver:
            let nums = validEntries.compactMap { numberMap[$0.citeKey] }
            let compactRange = Self.compressPlainNumericRanges(nums, separator: ", ")
            if mode == .narrative {
                let lead = authorShortLabel(for: validEntries[0], style: .vancouver, parenthetical: false)
                return "\(lead) (\(compactRange))"
            }
            return "(\(compactRange))"

        case .apa7:
            // APA 7th orders multi-work parenthetical citations alphabetically by first author & chronologically
            let sorted = validEntries.sorted(by: compareAuthorYearOrder)
            if mode == .narrative {
                return sorted.map { e in
                    formatSingleInText(
                        entry: e,
                        style: .apa7,
                        mode: .narrative,
                        citationNumber: 1,
                        yearSuffix: suffixMap[e.citeKey] ?? "",
                        locator: locators[e.citeKey]
                    )
                }.joined(separator: "; ")
            }

            // Collapse consecutive same-author works: `(Vaswani et al., 2017, 2023a, 2023b; Devlin et al., 2019)`
            var groups: [(authorLabel: String, yearParts: [String])] = []
            for e in sorted {
                let authorLabel = authorShortLabel(for: e, style: .apa7, parenthetical: true)
                let yearStr = renderedYearString(for: e, suffix: suffixMap[e.citeKey] ?? "")
                let locSuffix = locators[e.citeKey].map { ", \($0.kind.apaAbbreviation) \($0.value)" } ?? ""
                let piece = yearStr + locSuffix
                if let lastIdx = groups.indices.last, groups[lastIdx].authorLabel == authorLabel && locSuffix.isEmpty {
                    groups[lastIdx].yearParts.append(piece)
                } else {
                    groups.append((authorLabel, [piece]))
                }
            }
            let inner = groups
                .map { "\($0.authorLabel), \($0.yearParts.joined(separator: ", "))" }
                .joined(separator: "; ")
            return "(\(inner))"

        case .acm:
            let sorted = validEntries.sorted(by: compareAuthorYearOrder)
            let parts = sorted.map { e -> String in
                let authorLabel = authorShortLabel(for: e, style: .acm, parenthetical: true)
                let yearStr = renderedYearString(for: e, suffix: suffixMap[e.citeKey] ?? "")
                let locSuffix = locators[e.citeKey].map { ", \($0.kind.apaAbbreviation) \($0.value)" } ?? ""
                return "\(authorLabel) \(yearStr)\(locSuffix)"
            }
            return "[\(parts.joined(separator: "; "))]"
        }
    }

    // MARK: - Full Bibliography Formatting (Ordering + Disambiguation + Numbering)

    public func formatBibliography(
        entries: [BibliographyEntry],
        style: CitationFormatStyle,
        citedOrder: [String] = []
    ) -> CSLFormattedBibliography {
        if entries.isEmpty {
            return CSLFormattedBibliography(
                style: style,
                items: [],
                plainText: "",
                markdown: "",
                latexEnvironment: "\\begin{thebibliography}{0}\n\\end{thebibliography}",
                citationNumbersByCiteKey: [:],
                yearSuffixesByCiteKey: [:]
            )
        }

        let orderedEntries = orderBibliographyEntries(entries, style: style, citedOrder: citedOrder)
        let suffixMap = computeYearDisambiguationSuffixes(entries: orderedEntries, style: style)

        var numberMap: [String: Int] = [:]
        for (idx, entry) in orderedEntries.enumerated() {
            numberMap[entry.citeKey] = idx + 1
        }

        let formattedItems = orderedEntries.enumerated().map { idx, entry in
            formatEntry(
                entry,
                style: style,
                citationNumber: idx + 1,
                yearDisambiguationSuffix: suffixMap[entry.citeKey] ?? ""
            )
        }

        let plainText = formattedItems.map(\.bibliographyPlainText).joined(separator: "\n\n")
        let markdown = formattedItems.map(\.bibliographyMarkdown).joined(separator: "\n\n")
        let widestLabel = String(repeating: "9", count: String(max(1, formattedItems.count)).count)
        let bibItemsBody = formattedItems.map(\.bibliographyLaTeX).joined(separator: "\n\n")
        let latexEnv = "\\begin{thebibliography}{\(widestLabel)}\n\(bibItemsBody)\n\\end{thebibliography}"

        return CSLFormattedBibliography(
            style: style,
            items: formattedItems,
            plainText: plainText,
            markdown: markdown,
            latexEnvironment: latexEnv,
            citationNumbersByCiteKey: numberMap,
            yearSuffixesByCiteKey: suffixMap
        )
    }

    // MARK: - Static Numeric Range Compression Utilities

    /// IEEE style numeric range compressor (`[1, 2, 3, 5, 7, 8]` -> `"[1]–[3], [5], [7], [8]"`).
    public static func compressIEEEBracketedRanges(_ numbers: [Int]) -> String {
        let sortedUnique = Array(Set(numbers)).sorted()
        guard !sortedUnique.isEmpty else { return "" }

        var segments: [String] = []
        var i = 0
        while i < sortedUnique.count {
            let start = sortedUnique[i]
            var end = start
            var j = i
            while j + 1 < sortedUnique.count && sortedUnique[j + 1] == end + 1 {
                end = sortedUnique[j + 1]
                j += 1
            }
            let runLength = j - i + 1
            if runLength >= 3 {
                segments.append("[\(start)]–[\(end)]")
            } else if runLength == 2 {
                segments.append("[\(start)], [\(end)]")
            } else {
                segments.append("[\(start)]")
            }
            i = j + 1
        }
        return segments.joined(separator: ", ")
    }

    /// Nature / Vancouver compact numeric range compressor (`[1, 2, 3, 5]` -> `"1–3, 5"`).
    public static func compressPlainNumericRanges(_ numbers: [Int], separator: String = ", ") -> String {
        let sortedUnique = Array(Set(numbers)).sorted()
        guard !sortedUnique.isEmpty else { return "" }

        var segments: [String] = []
        var i = 0
        while i < sortedUnique.count {
            let start = sortedUnique[i]
            var end = start
            var j = i
            while j + 1 < sortedUnique.count && sortedUnique[j + 1] == end + 1 {
                end = sortedUnique[j + 1]
                j += 1
            }
            let runLength = j - i + 1
            if runLength >= 3 {
                segments.append("\(start)–\(end)")
            } else if runLength == 2 {
                segments.append("\(start)\(separator)\(end)")
            } else {
                segments.append("\(start)")
            }
            i = j + 1
        }
        return segments.joined(separator: separator)
    }

    public static func toUnicodeSuperscript(_ input: String) -> String {
        var out = ""
        for ch in input {
            if let sup = unicodeSuperscriptDigits[ch] {
                out.append(sup)
            } else if ch != " " {
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - APA 7th Edition Formatter

    private func buildAPA7BibliographyRuns(for entry: BibliographyEntry, yearSuffix: String) -> [CSLTextRun] {
        var runs: [CSLTextRun] = []

        // Authors (up to 20 listed; >= 21 lists first 19 + `, ... ` + final author)
        let authorText = formatAPA7BibliographyAuthors(entry.authors, authorsTruncated: entry.authorsTruncated)
        if !authorText.isEmpty {
            runs.append(CSLTextRun(text: ensureTrailingPeriod(authorText) + " "))
        }

        // Year `(2017). ` or `(2023a). ` or `(n.d.). `
        let yearLabel = renderedYearString(for: entry, suffix: yearSuffix)
        runs.append(CSLTextRun(text: "(\(yearLabel)). "))

        // Title & container according to entry kind
        let cleanTitle = stripTrailingPeriod(entry.title)
        let cleanVenue = entry.venue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch entry.kind {
        case .article:
            runs.append(CSLTextRun(text: "\(cleanTitle). "))
            if !cleanVenue.isEmpty {
                runs.append(CSLTextRun(text: cleanVenue, formatting: .italic))
                if let vol = nonEmpty(entry.volume) {
                    runs.append(CSLTextRun(text: ", "))
                    runs.append(CSLTextRun(text: vol, formatting: .italic))
                    if let iss = nonEmpty(entry.issue) {
                        runs.append(CSLTextRun(text: "(\(iss))"))
                    }
                }
                if let pages = nonEmpty(entry.pages) {
                    runs.append(CSLTextRun(text: ", \(normalizeEnDash(pages))."))
                } else {
                    runs.append(CSLTextRun(text: "."))
                }
            }

        case .inproceedings, .incollection:
            runs.append(CSLTextRun(text: "\(cleanTitle). "))
            if !cleanVenue.isEmpty {
                runs.append(CSLTextRun(text: "In "))
                runs.append(CSLTextRun(text: cleanVenue, formatting: .italic))
                if let pages = nonEmpty(entry.pages) {
                    runs.append(CSLTextRun(text: " (pp. \(normalizeEnDash(pages)))."))
                } else {
                    runs.append(CSLTextRun(text: "."))
                }
            }
            if let pub = nonEmpty(entry.publisher) {
                runs.append(CSLTextRun(text: " \(pub)."))
            }

        case .book:
            runs.append(CSLTextRun(text: "\(cleanTitle).", formatting: .italic))
            if let pub = nonEmpty(entry.publisher) ?? (cleanVenue.isEmpty ? nil : cleanVenue) {
                runs.append(CSLTextRun(text: " \(pub)."))
            }

        case .phdthesis:
            runs.append(CSLTextRun(text: cleanTitle, formatting: .italic))
            if !cleanVenue.isEmpty {
                runs.append(CSLTextRun(text: " [Doctoral dissertation, \(cleanVenue)]."))
            } else {
                runs.append(CSLTextRun(text: " [Doctoral dissertation]."))
            }

        case .techreport:
            runs.append(CSLTextRun(text: "\(cleanTitle).", formatting: .italic))
            let inst = nonEmpty(entry.publisher) ?? (cleanVenue.isEmpty ? nil : cleanVenue)
            if let inst {
                runs.append(CSLTextRun(text: " \(inst)."))
            }

        case .preprint, .misc:
            runs.append(CSLTextRun(text: "\(cleanTitle).", formatting: .italic))
            if let arxiv = nonEmpty(entry.arxivID) {
                runs.append(CSLTextRun(text: " arXiv."))
                if nonEmpty(entry.doi) == nil {
                    let link = "https://arxiv.org/abs/\(arxiv)"
                    runs.append(CSLTextRun(text: " "))
                    runs.append(CSLTextRun(text: link, formatting: .link, destinationURL: link))
                    return runs
                }
            } else if !cleanVenue.isEmpty {
                runs.append(CSLTextRun(text: " \(cleanVenue)."))
            }
        }

        // APA 7th: DOI formatted as `https://doi.org/...` with NO trailing period
        if let doi = canonicalDOIString(entry.doi) {
            let url = "https://doi.org/\(doi)"
            runs.append(CSLTextRun(text: " "))
            runs.append(CSLTextRun(text: url, formatting: .link, destinationURL: url))
        } else if let url = nonEmpty(entry.url) {
            runs.append(CSLTextRun(text: " "))
            runs.append(CSLTextRun(text: url, formatting: .link, destinationURL: url))
        }

        return runs
    }

    private func formatAPA7BibliographyAuthors(_ authors: [BibAuthor], authorsTruncated: Bool = false) -> String {
        guard !authors.isEmpty else { return authorsTruncated ? "et al." : "" }
        let formatted = authors.map(\.apaShortForm)
        if authorsTruncated {
            if formatted.count <= 20 {
                return "\(formatted.joined(separator: ", ")), et al."
            }
            return "\(formatted.prefix(19).joined(separator: ", ")), ... et al."
        }
        if formatted.count == 1 {
            return formatted[0]
        }
        if formatted.count <= 20 {
            let leading = formatted.dropLast().joined(separator: ", ")
            return "\(leading), & \(formatted[formatted.count - 1])"
        }
        // APA 7th 21+ authors rule: first 19 authors, `, ... `, final author
        let first19 = formatted.prefix(19).joined(separator: ", ")
        let finalAuthor = formatted[formatted.count - 1]
        return "\(first19), ... \(finalAuthor)"
    }

    // MARK: - IEEE Formatter

    private func buildIEEEBibliographyRuns(for entry: BibliographyEntry) -> [CSLTextRun] {
        var runs: [CSLTextRun] = []

        let authorsStr = formatIEEEAuthors(entry.authors, authorsTruncated: entry.authorsTruncated)
        if !authorsStr.isEmpty {
            runs.append(CSLTextRun(text: "\(authorsStr), "))
        }

        let cleanTitle = stripTrailingPeriod(entry.title)
        let cleanVenue = entry.venue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch entry.kind {
        case .book:
            runs.append(CSLTextRun(text: cleanTitle, formatting: .italic))
            if let pub = nonEmpty(entry.publisher) ?? (cleanVenue.isEmpty ? nil : cleanVenue) {
                runs.append(CSLTextRun(text: ", \(pub)"))
            }
            if let y = entry.year {
                runs.append(CSLTextRun(text: ", \(y)"))
            }
            runs.append(CSLTextRun(text: "."))

        case .inproceedings, .incollection:
            runs.append(CSLTextRun(text: "\"\(cleanTitle),\" "))
            if !cleanVenue.isEmpty {
                let procVenue = cleanVenue.lowercased().hasPrefix("proc.") || cleanVenue.lowercased().hasPrefix("proceedings")
                    ? cleanVenue
                    : "Proc. \(cleanVenue)"
                runs.append(CSLTextRun(text: "in "))
                runs.append(CSLTextRun(text: procVenue, formatting: .italic))
            }
            if let y = entry.year {
                runs.append(CSLTextRun(text: ", \(y)"))
            }
            if let pages = nonEmpty(entry.pages) {
                runs.append(CSLTextRun(text: ", pp. \(normalizeEnDash(pages))"))
            }
            if let doi = canonicalDOIString(entry.doi) {
                runs.append(CSLTextRun(text: ", doi: \(doi)"))
            }
            runs.append(CSLTextRun(text: "."))

        case .phdthesis:
            runs.append(CSLTextRun(text: "\"\(cleanTitle),\" Ph.D. dissertation"))
            if !cleanVenue.isEmpty {
                runs.append(CSLTextRun(text: ", \(cleanVenue)"))
            }
            if let y = entry.year {
                runs.append(CSLTextRun(text: ", \(y)"))
            }
            runs.append(CSLTextRun(text: "."))

        case .techreport:
            runs.append(CSLTextRun(text: "\"\(cleanTitle),\" "))
            let inst = nonEmpty(entry.publisher) ?? cleanVenue
            if !inst.isEmpty {
                runs.append(CSLTextRun(text: "\(inst), Tech. Rep."))
            } else {
                runs.append(CSLTextRun(text: "Tech. Rep."))
            }
            if let y = entry.year {
                runs.append(CSLTextRun(text: ", \(y)"))
            }
            runs.append(CSLTextRun(text: "."))

        case .preprint:
            runs.append(CSLTextRun(text: "\"\(cleanTitle),\" "))
            if let y = entry.year {
                runs.append(CSLTextRun(text: "\(y)"))
            }
            if let arxiv = nonEmpty(entry.arxivID) {
                runs.append(CSLTextRun(text: entry.year != nil ? ", arXiv:\(arxiv)." : "arXiv:\(arxiv)."))
            } else {
                runs.append(CSLTextRun(text: "."))
            }

        case .article, .misc:
            runs.append(CSLTextRun(text: "\"\(cleanTitle),\" "))
            if !cleanVenue.isEmpty {
                runs.append(CSLTextRun(text: cleanVenue, formatting: .italic))
            }
            if let vol = nonEmpty(entry.volume) {
                runs.append(CSLTextRun(text: ", vol. \(vol)"))
            }
            if let iss = nonEmpty(entry.issue) {
                runs.append(CSLTextRun(text: ", no. \(iss)"))
            }
            if let pages = nonEmpty(entry.pages) {
                runs.append(CSLTextRun(text: ", pp. \(normalizeEnDash(pages))"))
            }
            if let y = entry.year {
                runs.append(CSLTextRun(text: ", \(y)"))
            }
            if let doi = canonicalDOIString(entry.doi) {
                runs.append(CSLTextRun(text: ", doi: \(doi)"))
            }
            runs.append(CSLTextRun(text: "."))
        }

        return runs
    }

    private func formatIEEEAuthors(_ authors: [BibAuthor], authorsTruncated: Bool = false) -> String {
        guard !authors.isEmpty else { return authorsTruncated ? "et al." : "" }
        let names = authors.map(\.ieeeForm)
        if authorsTruncated {
            if names.count == 1 {
                return "\(names[0]) et al."
            }
            if names.count <= 6 {
                return "\(names.joined(separator: ", ")), et al."
            }
            return "\(names[0]) et al."
        }
        if names.count == 1 {
            return names[0]
        }
        if names.count == 2 {
            return "\(names[0]) and \(names[1])"
        }
        if names.count <= 6 {
            return "\(names.dropLast().joined(separator: ", ")), and \(names[names.count - 1])"
        }
        // IEEE standard: >6 authors uses first author followed by `et al.`
        return "\(names[0]) et al."
    }

    // MARK: - ACM Reference Format Formatter

    private func buildACMBibliographyRuns(for entry: BibliographyEntry, yearSuffix: String) -> [CSLTextRun] {
        var runs: [CSLTextRun] = []

        let authorsStr = formatACMAuthors(entry.authors, authorsTruncated: entry.authorsTruncated)
        if !authorsStr.isEmpty {
            runs.append(CSLTextRun(text: ensureTrailingPeriod(authorsStr) + " "))
        }

        let yearStr = renderedYearString(for: entry, suffix: yearSuffix)
        runs.append(CSLTextRun(text: "\(yearStr). "))

        let cleanTitle = stripTrailingPeriod(entry.title)
        let cleanVenue = entry.venue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch entry.kind {
        case .inproceedings, .incollection:
            runs.append(CSLTextRun(text: "\(cleanTitle). "))
            if !cleanVenue.isEmpty {
                let procTitle = cleanVenue.lowercased().hasPrefix("proceedings") ? cleanVenue : "Proceedings of \(cleanVenue)"
                runs.append(CSLTextRun(text: "In "))
                runs.append(CSLTextRun(text: procTitle, formatting: .italic))
                if let pages = nonEmpty(entry.pages) {
                    runs.append(CSLTextRun(text: ", \(normalizeEnDash(pages))."))
                } else {
                    runs.append(CSLTextRun(text: "."))
                }
            }
        case .book:
            runs.append(CSLTextRun(text: "\(cleanTitle).", formatting: .italic))
            if let pub = nonEmpty(entry.publisher) {
                runs.append(CSLTextRun(text: " \(pub)."))
            }
        default:
            runs.append(CSLTextRun(text: "\(cleanTitle). "))
            if !cleanVenue.isEmpty {
                runs.append(CSLTextRun(text: cleanVenue, formatting: .italic))
                if let vol = nonEmpty(entry.volume) {
                    runs.append(CSLTextRun(text: " \(vol)"))
                    if let iss = nonEmpty(entry.issue) {
                        runs.append(CSLTextRun(text: ", \(iss)"))
                    }
                }
                runs.append(CSLTextRun(text: " (\(yearStr))"))
                if let pages = nonEmpty(entry.pages) {
                    runs.append(CSLTextRun(text: ", \(normalizeEnDash(pages))."))
                } else {
                    runs.append(CSLTextRun(text: "."))
                }
            } else if let arxiv = nonEmpty(entry.arxivID) {
                runs.append(CSLTextRun(text: "arXiv:\(arxiv)."))
            }
        }

        if let doi = canonicalDOIString(entry.doi) {
            let link = "https://doi.org/\(doi)"
            runs.append(CSLTextRun(text: " "))
            runs.append(CSLTextRun(text: link, formatting: .link, destinationURL: link))
        }
        return runs
    }

    private func formatACMAuthors(_ authors: [BibAuthor], authorsTruncated: Bool = false) -> String {
        guard !authors.isEmpty else { return authorsTruncated ? "et al." : "" }
        let names = authors.map(\.description)
        if authorsTruncated {
            if names.count == 1 { return "\(names[0]) et al." }
            return "\(names.joined(separator: ", ")), et al."
        }
        if names.count == 1 { return names[0] }
        if names.count == 2 { return "\(names[0]) and \(names[1])" }
        return "\(names.dropLast().joined(separator: ", ")), and \(names[names.count - 1])"
    }

    // MARK: - Nature Portfolio Formatter

    private func buildNatureBibliographyRuns(for entry: BibliographyEntry) -> [CSLTextRun] {
        var runs: [CSLTextRun] = []

        let authorsStr = formatNatureAuthors(entry.authors, authorsTruncated: entry.authorsTruncated)
        if !authorsStr.isEmpty {
            runs.append(CSLTextRun(text: ensureTrailingPeriod(authorsStr) + " "))
        }

        let cleanTitle = stripTrailingPeriod(entry.title)
        runs.append(CSLTextRun(text: "\(cleanTitle). "))

        let cleanVenue = entry.venue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanVenue.isEmpty {
            let abbrevVenue = abbreviateJournalVenue(cleanVenue, keepPeriods: true)
            runs.append(CSLTextRun(text: abbrevVenue, formatting: .italic))
            if let vol = nonEmpty(entry.volume) {
                runs.append(CSLTextRun(text: " "))
                runs.append(CSLTextRun(text: vol, formatting: .bold))
                if let pages = nonEmpty(entry.pages) {
                    runs.append(CSLTextRun(text: ", \(normalizeEnDash(pages))"))
                }
            } else if let pages = nonEmpty(entry.pages) {
                runs.append(CSLTextRun(text: " \(normalizeEnDash(pages))"))
            }
            if let y = entry.year {
                runs.append(CSLTextRun(text: " (\(y))."))
            } else {
                runs.append(CSLTextRun(text: "."))
            }
        } else if let arxiv = nonEmpty(entry.arxivID) {
            let yr = entry.year.map { " (\($0))" } ?? ""
            runs.append(CSLTextRun(text: "Preprint at https://arxiv.org/abs/\(arxiv)\(yr)."))
        } else if let y = entry.year {
            runs.append(CSLTextRun(text: "(\(y))."))
        }

        return runs
    }

    private func formatNatureAuthors(_ authors: [BibAuthor], authorsTruncated: Bool = false) -> String {
        guard !authors.isEmpty else { return authorsTruncated ? "et al." : "" }
        let formatted = authors.map(\.apaShortForm)
        if authorsTruncated {
            if formatted.count == 1 { return "\(formatted[0]) et al." }
            if formatted.count <= 5 {
                return "\(formatted.joined(separator: ", ")), et al."
            }
            return "\(formatted[0]) et al."
        }
        if formatted.count == 1 { return formatted[0] }
        if formatted.count <= 5 {
            return "\(formatted.dropLast().joined(separator: ", ")) & \(formatted[formatted.count - 1])"
        }
        // Nature >5 authors rule: first author + `et al.`
        return "\(formatted[0]) et al."
    }

    // MARK: - Vancouver / ICMJE (NLM Biomedical) Formatter

    private func buildVancouverBibliographyRuns(for entry: BibliographyEntry) -> [CSLTextRun] {
        var runs: [CSLTextRun] = []

        let authorsStr = formatVancouverAuthors(entry.authors, authorsTruncated: entry.authorsTruncated)
        if !authorsStr.isEmpty {
            runs.append(CSLTextRun(text: ensureTrailingPeriod(authorsStr) + " "))
        }

        let cleanTitle = stripTrailingPeriod(entry.title)
        runs.append(CSLTextRun(text: "\(cleanTitle). "))

        let cleanVenue = entry.venue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanVenue.isEmpty {
            let nlmVenue = stripTrailingPeriod(abbreviateJournalVenue(cleanVenue, keepPeriods: false))
            runs.append(CSLTextRun(text: "\(nlmVenue)."))
        } else if entry.arxivID != nil {
            runs.append(CSLTextRun(text: "arXiv [Preprint]."))
        }

        var bibDetail = ""
        if let y = entry.year {
            bibDetail += " \(y)"
        }
        if let vol = nonEmpty(entry.volume) {
            bibDetail += ";\(vol)"
            if let iss = nonEmpty(entry.issue) {
                bibDetail += "(\(iss))"
            }
        }
        if let pages = nonEmpty(entry.pages) {
            bibDetail += ":\(normalizeEnDash(pages))"
        }
        if !bibDetail.isEmpty {
            runs.append(CSLTextRun(text: "\(bibDetail)."))
        }

        if let doi = canonicalDOIString(entry.doi) {
            runs.append(CSLTextRun(text: " doi:\(doi)."))
        }
        if let pmid = nonEmpty(entry.pmid) {
            runs.append(CSLTextRun(text: " PMID: \(pmid)."))
        }

        return runs
    }

    private func formatVancouverAuthors(_ authors: [BibAuthor], authorsTruncated: Bool = false) -> String {
        guard !authors.isEmpty else { return authorsTruncated ? "et al." : "" }
        let formatted = authors.map { author -> String in
            let compactInitials = author.givenName
                .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." })
                .compactMap(\.first)
                .map(String.init)
                .joined()
            return compactInitials.isEmpty ? author.familyName : "\(author.familyName) \(compactInitials)"
        }
        if authorsTruncated {
            return "\(formatted.prefix(6).joined(separator: ", ")), et al."
        }
        if formatted.count <= 6 {
            return formatted.joined(separator: ", ")
        }
        // ICMJE / NLM rule: list first 6 authors followed by `, et al.`
        return "\(formatted.prefix(6).joined(separator: ", ")), et al."
    }

    // MARK: - In-Text Helpers, Ordering & Year Disambiguation

    private func formatSingleInText(
        entry: BibliographyEntry,
        style: CitationFormatStyle,
        mode: InTextCitationMode,
        citationNumber: Int,
        yearSuffix: String,
        locator: CitationLocator?
    ) -> String {
        let yearStr = renderedYearString(for: entry, suffix: yearSuffix)
        let locatorText = locator.map { ", \($0.kind.apaAbbreviation) \($0.value)" } ?? ""

        switch style {
        case .apa7:
            let authorStr = authorShortLabel(for: entry, style: .apa7, parenthetical: mode == .parenthetical)
            if mode == .parenthetical {
                return "(\(authorStr), \(yearStr)\(locatorText))"
            } else {
                return "\(authorStr) (\(yearStr)\(locatorText))"
            }

        case .acm:
            let authorStr = authorShortLabel(for: entry, style: .acm, parenthetical: mode == .parenthetical)
            if mode == .parenthetical {
                return "[\(authorStr) \(yearStr)\(locatorText)]"
            } else {
                return "\(authorStr) [\(yearStr)\(locatorText)]"
            }

        case .ieee:
            let locInBracket = locator.map { ", \($0.kind.apaAbbreviation) \($0.value)" } ?? ""
            if mode == .parenthetical {
                return "[\(citationNumber)\(locInBracket)]"
            } else {
                let authorStr = authorShortLabel(for: entry, style: .ieee, parenthetical: false)
                return "\(authorStr) [\(citationNumber)\(locInBracket)]"
            }

        case .nature:
            let sup = Self.toUnicodeSuperscript("\(citationNumber)")
            if mode == .parenthetical {
                return sup
            } else {
                let authorStr = authorShortLabel(for: entry, style: .nature, parenthetical: false)
                return "\(authorStr)\(sup)"
            }

        case .vancouver:
            if mode == .parenthetical {
                return "(\(citationNumber))"
            } else {
                let authorStr = authorShortLabel(for: entry, style: .vancouver, parenthetical: false)
                return "\(authorStr) (\(citationNumber))"
            }
        }
    }

    private func authorShortLabel(
        for entry: BibliographyEntry,
        style: CitationFormatStyle,
        parenthetical: Bool
    ) -> String {
        guard !entry.authors.isEmpty else {
            let shortTitle = entry.title.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
            return shortTitle.isEmpty ? "Anonymous" : "\"\(shortTitle)\""
        }
        let f0 = entry.authors[0].familyName
        if entry.authorsTruncated {
            return "\(f0) et al."
        }
        if entry.authors.count == 1 {
            return f0
        }
        if entry.authors.count == 2 {
            let f1 = entry.authors[1].familyName
            let conj = (style == .apa7 && parenthetical) ? "&" : "and"
            return "\(f0) \(conj) \(f1)"
        }
        return "\(f0) et al."
    }

    private func computeYearDisambiguationSuffixes(
        entries: [BibliographyEntry],
        style: CitationFormatStyle
    ) -> [String: String] {
        guard style == .apa7 || style == .acm else { return [:] }

        var buckets: [String: [BibliographyEntry]] = [:]
        for entry in entries {
            let authorKey = authorShortLabel(for: entry, style: style, parenthetical: true).lowercased()
            let yearKey = entry.year.map(String.init) ?? "n.d."
            let groupKey = "\(authorKey)|\(yearKey)"
            buckets[groupKey, default: []].append(entry)
        }

        var suffixes: [String: String] = [:]
        for group in buckets.values where group.count >= 2 {
            let sortedGroup = group.sorted { lhs, rhs in
                let tCompare = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if tCompare != .orderedSame {
                    return tCompare == .orderedAscending
                }
                return lhs.citeKey < rhs.citeKey
            }
            for (idx, item) in sortedGroup.enumerated() {
                let letter = alphabeticDisambiguationLabel(forZeroBasedIndex: idx)
                suffixes[item.citeKey] = (item.year == nil) ? "-\(letter)" : letter
            }
        }
        return suffixes
    }

    private func alphabeticDisambiguationLabel(forZeroBasedIndex index: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        var n = index
        var chars: [Character] = []
        repeat {
            chars.insert(alphabet[n % 26], at: 0)
            n = (n / 26) - 1
        } while n >= 0
        return String(chars)
    }

    private func orderBibliographyEntries(
        _ entries: [BibliographyEntry],
        style: CitationFormatStyle,
        citedOrder: [String]
    ) -> [BibliographyEntry] {
        if isNumericStyle(style) {
            if citedOrder.isEmpty {
                return entries
            }
            var rankByKey: [String: Int] = [:]
            for (idx, k) in citedOrder.enumerated() where rankByKey[k] == nil {
                rankByKey[k] = idx
            }
            return entries.enumerated().sorted { lhs, rhs in
                let r1 = rankByKey[lhs.element.citeKey] ?? (Int.max - 100_000 + lhs.offset)
                let r2 = rankByKey[rhs.element.citeKey] ?? (Int.max - 100_000 + rhs.offset)
                return r1 < r2
            }.map(\.element)
        } else {
            return entries.sorted(by: compareAuthorYearOrder)
        }
    }

    private func assignCitationNumbers(
        entries: [BibliographyEntry],
        style: CitationFormatStyle,
        citedOrder: [String]
    ) -> [String: Int] {
        let ordered = orderBibliographyEntries(entries, style: style, citedOrder: citedOrder)
        var map: [String: Int] = [:]
        for (idx, e) in ordered.enumerated() {
            map[e.citeKey] = idx + 1
        }
        return map
    }

    private func compareAuthorYearOrder(_ lhs: BibliographyEntry, _ rhs: BibliographyEntry) -> Bool {
        let famA = lhs.firstAuthorFamily.lowercased()
        let famB = rhs.firstAuthorFamily.lowercased()
        if famA != famB {
            return famA.localizedStandardCompare(famB) == .orderedAscending
        }
        let yA = lhs.year ?? Int.max
        let yB = rhs.year ?? Int.max
        if yA != yB {
            return yA < yB
        }
        let titleCompare = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleCompare != .orderedSame {
            return titleCompare == .orderedAscending
        }
        return lhs.citeKey < rhs.citeKey
    }

    private func isNumericStyle(_ style: CitationFormatStyle) -> Bool {
        switch style {
        case .ieee, .nature, .vancouver: return true
        case .apa7, .acm: return false
        }
    }

    private func renderedYearString(for entry: BibliographyEntry, suffix: String) -> String {
        if let y = entry.year {
            return "\(y)\(suffix)"
        }
        return "n.d.\(suffix)"
    }

    private func abbreviateJournalVenue(_ venue: String, keepPeriods: Bool) -> String {
        let normalizedKey = venue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let hit = Self.iso4JournalAbbreviations[normalizedKey] {
            return keepPeriods ? hit : hit.replacingOccurrences(of: ".", with: "")
        }
        return keepPeriods ? venue : venue.replacingOccurrences(of: ".", with: "")
    }

    // MARK: - Run Renderers (Plain / Markdown / LaTeX)

    private func renderRunsPlainText(_ runs: [CSLTextRun]) -> String {
        runs.map(\.text).joined()
    }

    private func renderRunsMarkdown(_ runs: [CSLTextRun]) -> String {
        runs.map { run in
            guard !run.text.isEmpty else { return "" }
            switch run.formatting {
            case .plain:
                return run.text
            case .italic:
                return "*\(run.text)*"
            case .bold:
                return "**\(run.text)**"
            case .superscript:
                return "^\(run.text)^"
            case .link:
                if let url = run.destinationURL {
                    return "[\(run.text)](\(url))"
                }
                return run.text
            }
        }.joined()
    }

    private func renderRunsLaTeX(_ runs: [CSLTextRun]) -> String {
        runs.map { run in
            let escaped = escapeLaTeXSpecials(run.text)
            switch run.formatting {
            case .plain:
                return escaped
            case .italic:
                return "\\textit{\(escaped)}"
            case .bold:
                return "\\textbf{\(escaped)}"
            case .superscript:
                return "\\textsuperscript{\(escaped)}"
            case .link:
                if let url = run.destinationURL {
                    return "\\url{\(url)}"
                }
                return escaped
            }
        }.joined()
    }

    private func escapeLaTeXSpecials(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "\\&")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func stripTrailingPeriod(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".") && !s.hasSuffix("...") {
            s.removeLast()
        }
        return s
    }

    private func ensureTrailingPeriod(_ text: String) -> String {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        return s.hasSuffix(".") ? s : "\(s)."
    }

    private func normalizeEnDash(_ pages: String) -> String {
        pages
            .replacingOccurrences(of: "---", with: "–")
            .replacingOccurrences(of: "--", with: "–")
            .replacingOccurrences(of: "-", with: "–")
    }

    private func canonicalDOIString(_ raw: String?) -> String? {
        ReferenceIdentifierNormalizer.normalizeDOI(raw)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return nil
        }
        return v
    }
}
