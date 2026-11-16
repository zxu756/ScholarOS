import Foundation
import SQLite3
import Testing
import ScholarModels
@testable import ScholarBibAndCSL

@Suite("BibTeX/RIS/NBIB Codecs, Deduplication, 5-Style CSL & Citation Firewall")
struct BibCSLAndFirewallTests {

    // MARK: - Helpers

    /// True when `text` contains CJK ideographs, CJK punctuation, or full-width forms.
    private func containsChineseCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x3000...0x303F).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x4E00...0x9FFF).contains(v)
                || (0xFF00...0xFFEF).contains(v)
        }
    }

    private func makeVaswaniEntry() -> BibliographyEntry {
        BibliographyEntry(
            citeKey: "vaswani2017attention",
            kind: .inproceedings,
            title: "Attention Is All You Need",
            authors: [
                BibAuthor(givenName: "Ashish", familyName: "Vaswani", orcid: "0000-0002-1825-0097"),
                BibAuthor(givenName: "Noam", familyName: "Shazeer"),
                BibAuthor(givenName: "Niki", familyName: "Parmar"),
                BibAuthor(givenName: "Jakob", familyName: "Uszkoreit")
            ],
            year: 2017,
            venue: "Advances in Neural Information Processing Systems",
            publisher: "Curran Associates",
            volume: "30",
            pages: "5998-6008",
            doi: "10.5555/3295222.3295349",
            arxivID: "1706.03762",
            firewallClass: .verified,
            firewallAuditNote: "Verified registry record"
        )
    }

    private func makeHallucinatedSmithEntry() -> BibliographyEntry {
        BibliographyEntry(
            citeKey: "smith2025hallucinated",
            kind: .article,
            title: "Autonomous Quantum Hyper-Transformers for Zero-Shot Omniscience",
            authors: [BibAuthor(givenName: "John", familyName: "Smith")],
            year: 2025,
            venue: "Journal of Synthetic Hallucinations",
            doi: "10.9999/hallucinated.2025.0001",
            firewallClass: .notFound,
            firewallAuditNote: "Sentinel fabricated DOI prefix 10.9999"
        )
    }

    // MARK: - 1. BibTeX & LaTeX Text Codec Tests

    @Test("BibTeX @string macro expansion, # concatenation, and @preamble preservation")
    func bibTeXStringMacroConcatenationAndPreambleParsing() throws {
        let bibSource = """
        @preamble{"\\providecommand{\\noopsort}[1]{}"}
        @string{neurips = "Advances in Neural Information Processing Systems"}
        @string{pub = "Curran"}

        @inproceedings{dao2022flashattention,
          author    = {Dao, Tri and Fu, Daniel Y. and Ermon, Stefano and Rudra, Atri and R{\\'e}, Christopher},
          title     = {{FlashAttention}: Fast and Memory-Efficient Exact Attention with {IO}-Awareness},
          booktitle = neurips # " (NeurIPS)",
          publisher = pub # " Associates",
          year      = 2022,
          volume    = 35,
          pages     = {16344--16359},
          doi       = {10.48550/arXiv.2205.14135}
        }
        """
        let codec = BibTeXCodec()
        let doc = try codec.parseDocument(bibSource)

        #expect(doc.preambles.count == 1)
        #expect(doc.macros["neurips"] == "Advances in Neural Information Processing Systems")
        #expect(doc.entries.count == 1)

        let entry = try #require(doc.entries.first)
        #expect(entry.citeKey == "dao2022flashattention")
        #expect(entry.venue == "Advances in Neural Information Processing Systems (NeurIPS)")
        #expect(entry.publisher == "Curran Associates")
        #expect(entry.authors.count == 5)
        #expect(entry.authors.last?.familyName == "Ré")
        #expect(entry.title.contains("FlashAttention"))
    }

    @Test("LaTeXTextCodec decodes European diacritics and protects uppercase acronyms on encode")
    func latexTextCodecDiacriticsAndAcronymBracePreservation() {
        let textCodec = LaTeXTextCodec()
        let decoded = textCodec.decode("Schr{\\\"o}dinger, Erv{\\'i}n and {\\v{S}}vec, J. and {\\aa}ngstr{\\\"o}m and Erd{\\H{o}}s and Gau{\\ss}")
        #expect(decoded.contains("Schrödinger"))
        #expect(decoded.contains("Švec"))
        #expect(decoded.contains("ångström"))
        #expect(decoded.contains("Erdős"))
        #expect(decoded.contains("Gauß"))

        let encodedTitle = textCodec.encode(
            "Evaluating PRISMA Screening with GPU-Accelerated LLM Verifiers",
            escapeUnicodeToLaTeX: false,
            protectAcronymsInTitle: true
        )
        #expect(encodedTitle.contains("{PRISMA}"))
        #expect(encodedTitle.contains("{LLM}"))

        let stripped = textCodec.stripProtectiveBraces("{FlashAttention}: {IO}-Aware {GPU} Kernels")
        #expect(stripped == "FlashAttention: IO-Aware GPU Kernels")
    }

    @Test("BibTeXAuthorParser handles corporate braces, von particles, Jr. suffixes, and ORCIDs")
    func bibTeXAuthorParserCorporateVonAndORCIDSupport() {
        let rawAuthors = "van der Waals, Johannes Diderik and {World Health Organization} and Gates, III, William Henry"
        let orcids = "0000-0002-1825-0097; ; 0000-0002-1694-233X"
        let parsed = BibTeXAuthorParser.parseAuthors(rawAuthors, orcidField: orcids)

        #expect(parsed.count == 3)
        #expect(parsed[0].familyName.contains("van der Waals"))
        #expect(parsed[0].givenName == "Johannes Diderik")
        #expect(parsed[0].orcid == "0000-0002-1825-0097")
        #expect(parsed[1].familyName == "World Health Organization")
        #expect(parsed[1].givenName.isEmpty)
        #expect(parsed[2].familyName.contains("Gates"))

        #expect(parsed[0].apaShortForm.contains("van der Waals"))
        #expect(parsed[0].ieeeForm.contains("van der Waals"))
    }

    @Test("BibTeXCodec lossless document serialization round-trip and collision-free citeKey generation")
    func bibTeXLosslessDocumentRoundTripAndCiteKeyGeneration() throws {
        var entry = makeVaswaniEntry()
        entry.citedByKeys = ["dao2022flashattention"]
        entry.referencesKeys = ["bahdanau2015neural"]

        let codec = BibTeXCodec(options: .canonical)
        let serialized = codec.serialize([entry])
        #expect(serialized.contains("@inproceedings{vaswani2017attention,"))
        #expect(serialized.contains("10.5555/3295222.3295349"))

        let reparsed = try codec.parse(serialized)
        let restored = try #require(reparsed.first)
        #expect(restored.citeKey == entry.citeKey)
        #expect(restored.title == entry.title)
        #expect(restored.year == 2017)
        #expect(restored.doi == entry.doi)
        #expect(restored.authors.count == 4)

        let generated1 = BibTeXCodec.generateCiteKey(for: entry, existingKeys: [])
        let generated2 = BibTeXCodec.generateCiteKey(for: entry, existingKeys: [generated1])
        #expect(!generated1.isEmpty)
        #expect(generated1 != generated2)
    }

    // MARK: - 2. RIS & PubMed MEDLINE (.nbib) Parser Tests

    @Test("RISParser multi-record import/export round-trip and strict-mode syntax error enforcement")
    func risMultiRecordImportExportRoundTripAndStrictValidation() throws {
        let risText = """
        TY  - JOUR
        ID  - page2021prisma
        TI  - The PRISMA 2020 statement: an updated guideline for reporting systematic reviews
        AU  - Page, Matthew J
        AU  - McKenzie, Joanne E
        AU  - Bossuyt, Patrick M
        JO  - BMJ
        PY  - 2021/03/29/
        VL  - 372
        SP  - n71
        DO  - 10.1136/bmj.n71
        AB  - Updated PRISMA 2020 reporting checklist and flow diagram specification.
        ER  - 

        TY  - CONF
        ID  - dao2022flash
        TI  - FlashAttention: Fast and Memory-Efficient Exact Attention
        AU  - Dao, Tri
        T2  - NeurIPS
        PY  - 2022
        SP  - 16344
        EP  - 16359
        ER  - 
        """

        let parser = RISParser(strictMode: true)
        let entries = try parser.parse(risText)
        #expect(entries.count == 2)
        #expect(entries[0].kind == .article)
        #expect(entries[0].year == 2021)
        #expect(entries[0].doi == "10.1136/bmj.n71")
        #expect(entries[0].authors.count == 3)
        #expect(entries[1].kind == .inproceedings)
        #expect(entries[1].pages == "16344-16359" || entries[1].pages == "16344–16359")

        let exported = parser.export(entries)
        let reparsed = try parser.parse(exported)
        #expect(reparsed.count == 2)
        #expect(reparsed[0].doi == "10.1136/bmj.n71")

        #expect(throws: ScholarOSError.self) {
            _ = try parser.parse("INVALID RIS WITHOUT TAGS OR ER RECORD")
        }
    }

    @Test("PubMedNBIBParser parses MEDLINE multi-line continuations, ORCIDs, and expands abbreviated page ranges")
    func pubMedNBIBMedlineContinuationAndPageRangeExpansion() throws {
        #expect(PubMedNBIBParser.expandMedlinePageRange("1059-68").contains("1068"))
        #expect(PubMedNBIBParser.expandMedlinePageRange("5992-8").contains("5998"))
        #expect(PubMedNBIBParser.expandMedlinePageRange("S12-8").contains("S18"))

        let nbibSource = """
        PMID- 33782057
        OWN - NLM
        STAT- MEDLINE
        TI  - The PRISMA 2020 statement: an updated guideline for reporting
              systematic reviews and meta-analyses.
        PG  - 1059-68
        LID - 10.1016/j.jclinepi.2021.03.001 [doi]
        AB  - Background: Systematic reviews underpin evidence-based medicine
              across clinical and computational disciplines.
        FAU - Page, Matthew J
        AU  - Page MJ
        AUID- ORCID: 0000-0001-9824-8678
        FAU - Moher, David
        AU  - Moher D
        JT  - Journal of Clinical Epidemiology
        DP  - 2021 Jun
        VI  - 134
        IP  - 6
        PT  - Journal Article
        """

        let nbibParser = PubMedNBIBParser(strictMode: true)
        let parsed = try nbibParser.parse(nbibSource)
        #expect(parsed.count == 1)

        let item = try #require(parsed.first)
        #expect(item.pmid == "33782057")
        #expect(item.doi == "10.1016/j.jclinepi.2021.03.001")
        #expect(item.year == 2021)
        #expect(item.title.contains("systematic reviews and meta-analyses"))
        #expect(item.pages?.contains("1068") == true)
        #expect(item.authors.first?.orcid == "0000-0001-9824-8678")

        let exportedNBIB = nbibParser.export([item])
        #expect(exportedNBIB.contains("PMID- 33782057"))
        let roundTripped = try nbibParser.parse(exportedNBIB)
        #expect(roundTripped.first?.pmid == "33782057")
    }

    // MARK: - 3. Jaro-Winkler & Reference Deduplicator Tests

    @Test("ReferenceIdentifierNormalizer canonicalizes DOIs, versioned arXiv IDs, PMIDs, and surnames")
    func identifierNormalizationDOIArXivPMIDAndTitleTokens() {
        #expect(ReferenceIdentifierNormalizer.normalizeDOI("https://doi.org/10.1145/3581783.3612345 ") == "10.1145/3581783.3612345")
        #expect(ReferenceIdentifierNormalizer.normalizeDOI("DOI:10.1038/NATURE14539") == "10.1038/nature14539")
        #expect(ReferenceIdentifierNormalizer.normalizeArXivID("arXiv:2205.14135v3", stripVersion: true) == "2205.14135")
        #expect(ReferenceIdentifierNormalizer.extractArXivVersion("arXiv:2205.14135v3") == 3)
        #expect(ReferenceIdentifierNormalizer.normalizePMID("PMID: 33782057") == "33782057")
        #expect(ReferenceIdentifierNormalizer.normalizeSurname("Müller") == "muller")
        #expect(ReferenceIdentifierNormalizer.normalizeSurname("Ré") == "re")
    }

    @Test("Classical Jaro, Jaro-Winkler prefix boost, and token Jaccard similarity bounds")
    func jaroWinklerAndTokenJaccardSimilarityMetrics() {
        let dedup = ReferenceDeduplicator()
        let jaro = dedup.jaroSimilarity("MARTHA", "MARHTA")
        let jw = dedup.jaroWinklerSimilarity("MARTHA", "MARHTA")

        #expect(abs(jaro - (17.0 / 18.0)) < 1e-6)
        #expect(jw > jaro)
        #expect(abs(jw - 0.961111) < 1e-3)
        #expect(dedup.jaroWinklerSimilarity("identical", "identical") == 1.0)
        #expect(dedup.jaroWinklerSimilarity("", "nonempty") == 0.0)

        let jaccard = dedup.tokenJaccardSimilarity(["attention", "is", "all"], ["attention", "all", "need"])
        #expect(abs(jaccard - 0.5) < 1e-9)
    }

    @Test("ReferenceDeduplicator merges arXiv preprint with camera-ready venue while keeping distinct DOIs separate")
    func deduplicatorClustersPreprintWithPublishedVenueAndRejectsConflictingDOIs() {
        let preprint = BibliographyEntry(
            citeKey: "dao2022arxiv",
            kind: .preprint,
            title: "FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness",
            authors: [BibAuthor(givenName: "Tri", familyName: "Dao"), BibAuthor(givenName: "Christopher", familyName: "Re")],
            year: 2022,
            venue: "arXiv preprint",
            arxivID: "2205.14135v1",
            firewallClass: .unverified,
            citedByKeys: ["paperA"]
        )
        let published = BibliographyEntry(
            citeKey: "dao2022neurips",
            kind: .inproceedings,
            title: "FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness!",
            authors: [BibAuthor(givenName: "Tri", familyName: "Dao"), BibAuthor(givenName: "Christopher", familyName: "Ré")],
            year: 2022,
            venue: "Advances in Neural Information Processing Systems",
            volume: "35",
            pages: "16344-16359",
            doi: "10.5555/3540261.3541505",
            firewallClass: .verified,
            citedByKeys: ["paperB"]
        )
        // Distinct sequel paper with a DIFFERENT canonical DOI must NEVER be falsely collapsed!
        let sequelPaper = BibliographyEntry(
            citeKey: "dao2023flash2",
            kind: .inproceedings,
            title: "FlashAttention-2: Faster Attention with Better Parallelism and Work Partitioning",
            authors: [BibAuthor(givenName: "Tri", familyName: "Dao")],
            year: 2023,
            venue: "ICLR",
            doi: "10.48550/arXiv.2307.08691",
            firewallClass: .verified
        )

        let dedup = ReferenceDeduplicator()
        let result = dedup.deduplicateLibrary([preprint, published, sequelPaper])

        #expect(result.canonicalEntries.count == 2)
        let mergedCluster = try! #require(result.clusters.first { $0.memberCiteKeys.count == 2 })
        let merged = mergedCluster.mergedEntry
        #expect(merged.firewallClass == .verified)
        #expect(merged.doi == "10.5555/3540261.3541505")
        #expect(merged.arxivID != nil)
        #expect(Set(merged.citedByKeys) == Set(["paperA", "paperB"]))
        #expect(result.citeKeyRedirectMap["dao2022arxiv"] == merged.citeKey || result.citeKeyRedirectMap["dao2022neurips"] == merged.citeKey)
    }

    // MARK: - 4. 5-Style CSL Citation Formatter Tests

    @Test("CSL APA 7th parenthetical, narrative, locator, and 2017a/2017b year suffix disambiguation")
    func cslAPA7FormattingParentheticalNarrativeAndYearSuffixDisambiguation() {
        let engine = CSLCitationFormatterEngine()
        let vaswani = makeVaswaniEntry()

        let single = engine.formatEntry(
            vaswani,
            style: .apa7,
            locator: CitationLocator(kind: .pages, value: "6001-6003")
        )
        #expect(single.inTextParenthetical.contains("Vaswani et al., 2017"))
        #expect(single.inTextParenthetical.contains("pp."))
        #expect(single.inTextNarrative.hasPrefix("Vaswani et al. (2017"))
        #expect(single.bibliographyPlainText.contains("(2017)."))
        #expect(single.bibliographyPlainText.contains("https://doi.org/10.5555/3295222.3295349"))

        // Same first author + year -> automatic 2017a / 2017b suffix disambiguation
        let sibling = BibliographyEntry(
            citeKey: "vaswani2017tensor2tensor",
            kind: .inproceedings,
            title: "Tensor2Tensor for Neural Machine Translation",
            authors: vaswani.authors,
            year: 2017,
            venue: "AMTA",
            doi: "10.18653/v1/W18-1819",
            firewallClass: .verified
        )
        let bib = engine.formatBibliography(entries: [vaswani, sibling], style: .apa7)
        let suffixes = Set(bib.yearSuffixesByCiteKey.values)
        #expect(suffixes == Set(["a", "b"]))
    }

    @Test("CSL IEEE numeric bracket range compression and order-of-appearance bibliography")
    func cslIEEEBracketCompressionAndNumericOrderOfAppearance() {
        let compressed = CSLCitationFormatterEngine.compressIEEEBracketedRanges([1, 2, 3, 5, 8, 9, 10])
        #expect(compressed.contains("[1]"))
        #expect(compressed.contains("[3]"))
        #expect(compressed.contains("[5]"))
        #expect(compressed.contains("[8]"))
        #expect(compressed.contains("[10]"))

        let engine = CSLCitationFormatterEngine()
        let e1 = makeVaswaniEntry()
        let e2 = BibliographyEntry(
            citeKey: "page2021prisma",
            kind: .article,
            title: "The PRISMA 2020 statement",
            authors: [BibAuthor(givenName: "Matthew J.", familyName: "Page")],
            year: 2021,
            venue: "BMJ",
            volume: "372",
            pages: "n71",
            doi: "10.1136/bmj.n71",
            firewallClass: .verified
        )
        let library = [e1.citeKey: e1, e2.citeKey: e2]
        let cluster = engine.formatInTextCluster(
            citeKeys: ["page2021prisma", "vaswani2017attention"],
            in: library,
            style: .ieee,
            mode: .parenthetical,
            orderOfAppearance: ["page2021prisma", "vaswani2017attention"]
        )
        #expect(cluster.contains("1"))
        #expect(cluster.contains("2"))

        let ieeeBib = engine.formatBibliography(
            entries: [e1, e2],
            style: .ieee,
            citedOrder: ["page2021prisma", "vaswani2017attention"]
        )
        #expect(ieeeBib.citationNumbersByCiteKey["page2021prisma"] == 1)
        #expect(ieeeBib.citationNumbersByCiteKey["vaswani2017attention"] == 2)
        #expect(ieeeBib.plainText.contains("[1]"))
        #expect(ieeeBib.latexEnvironment.contains("\\begin{thebibliography}"))
    }

    @Test("CSL ACM, Nature Unicode superscript, and Vancouver ISO-4 styles render distinct conventions")
    func cslACMNatureAndVancouverFormattingInvariants() {
        let engine = CSLCitationFormatterEngine()
        let entry = BibliographyEntry(
            citeKey: "lecun2015deep",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2015,
            venue: "Proceedings of the National Academy of Sciences",
            volume: "521",
            issue: "7553",
            pages: "436-444",
            doi: "10.1038/nature14539",
            firewallClass: .verified
        )

        let acm = engine.formatEntry(entry, style: .acm, citationNumber: 4)
        let nature = engine.formatEntry(entry, style: .nature, citationNumber: 4)
        let vancouver = engine.formatEntry(entry, style: .vancouver, citationNumber: 4)

        #expect(acm.inTextParenthetical.contains("LeCun et al. 2015"))
        #expect(acm.bibliographyPlainText.contains("Yann LeCun, Yoshua Bengio, and Geoffrey Hinton. 2015."))

        #expect(nature.inTextSuperscript == "⁴")
        #expect(nature.bibliographyPlainText.hasPrefix("4."))

        #expect(vancouver.inTextParenthetical == "(4)")
        #expect(vancouver.bibliographyPlainText.contains("LeCun Y"))
        #expect(vancouver.bibliographyPlainText.contains("2015;521(7553):436-444") || vancouver.bibliographyPlainText.contains("2015;521"))
    }

    // MARK: - 5. Citation Verification Firewall & Identifier Checksum Tests

    @Test("ScholarlyIdentifierValidator validates ISO DOI syntax and arXiv calendar/version constraints")
    func scholarlyIdentifierValidatorDOISyntaxAndArXivCalendarBounds() {
        let validDOI = ScholarlyIdentifierValidator.validateDOISyntax("https://doi.org/10.1145/3581783.3612345")
        #expect(validDOI.isValid)
        #expect(validDOI.normalized == "10.1145/3581783.3612345")

        let invalidDOI = ScholarlyIdentifierValidator.validateDOISyntax("doi:99.1234/not-a-ten-prefix")
        #expect(!invalidDOI.isValid)

        let validModernArXiv = ScholarlyIdentifierValidator.validateArXivID("arXiv:1706.03762v5")
        #expect(validModernArXiv.isValid)
        #expect(validModernArXiv.canonicalBaseID == "1706.03762")
        #expect(validModernArXiv.inferredSubmissionYear == 2017)
        #expect(validModernArXiv.inferredSubmissionMonth == 6)

        let validLegacyArXiv = ScholarlyIdentifierValidator.validateArXivID("hep-th/9901001v2")
        #expect(validLegacyArXiv.isValid)

        // Month 19 does not exist in calendar -> must fail!
        let bogusMonthArXiv = ScholarlyIdentifierValidator.validateArXivID("2319.99999")
        #expect(!bogusMonthArXiv.isValid)

        // Version v0 is illegal on arXiv (versions are 1-indexed)
        let zeroVersionArXiv = ScholarlyIdentifierValidator.validateArXivID("2305.14314v0")
        #expect(!zeroVersionArXiv.isValid)
    }

    @Test("ScholarlyIdentifierValidator verifies PMID bounds, ORCID ISO 7064 Mod 11-2, and ISSN ISO 3297 checksums")
    func scholarlyIdentifierValidatorPMIDORCIDMod11AndISSNMod11Checksums() {
        #expect(ScholarlyIdentifierValidator.validatePMID("33782057").isValid)
        #expect(!ScholarlyIdentifierValidator.validatePMID("0").isValid)
        #expect(!ScholarlyIdentifierValidator.validatePMID("999999999999").isValid)

        // Valid ORCIDs (including check digit 'X')
        #expect(ScholarlyIdentifierValidator.validateORCID("0000-0002-1825-0097").isValid)
        #expect(ScholarlyIdentifierValidator.validateORCID("https://orcid.org/0000-0002-1694-233X").isValid)
        // Corrupted check digit
        #expect(!ScholarlyIdentifierValidator.validateORCID("0000-0002-1825-0098").isValid)

        // Valid ISSNs (Nature 0028-0836; 2049-3630; check digit X e.g. 2434-561X)
        #expect(ScholarlyIdentifierValidator.validateISSN("0028-0836").isValid)
        #expect(ScholarlyIdentifierValidator.validateISSN("2434-561X").isValid)
        #expect(!ScholarlyIdentifierValidator.validateISSN("0028-0837").isValid)
    }

    @Test("CitationVerificationFirewall offline evaluate assigns UNVERIFIED, RETRACTED, and NOT_FOUND honestly without claiming VERIFIED")
    func firewallEvaluatesOfflineClassesHonestly() {
        let firewall = CitationVerificationFirewall()

        // 1. Syntactically valid DOI offline -> UNVERIFIED (never VERIFIED without registry query)
        let validDOI = makeVaswaniEntry()
        let v1 = firewall.evaluate(validDOI)
        #expect(v1.firewallClass == .unverified)
        #expect(!v1.allowsManuscriptInsertion)

        // 2. Syntactically valid arXiv ID offline -> UNVERIFIED
        let validPreprint = BibliographyEntry(
            citeKey: "kaplan2020scaling",
            kind: .preprint,
            title: "Scaling Laws for Neural Language Models",
            authors: [BibAuthor(givenName: "Jared", familyName: "Kaplan")],
            year: 2020,
            venue: "arXiv",
            arxivID: "2001.08361"
        )
        let v2 = firewall.evaluate(validPreprint)
        #expect(v2.firewallClass == .unverified)
        #expect(!v2.allowsManuscriptInsertion)

        // 3. Built-in retracted DOI offline -> RETRACTED (with incomplete built-in list notice)
        let retracted = BibliographyEntry(
            citeKey: "wakefield1998",
            kind: .article,
            title: "Ileal-lymphoid-nodular hyperplasia",
            authors: [BibAuthor(givenName: "Andrew", familyName: "Wakefield")],
            year: 1998,
            venue: "The Lancet",
            doi: "10.1016/S0140-6736(97)11096-0"
        )
        let v3 = firewall.evaluate(retracted)
        #expect(v3.firewallClass == .retracted)
        #expect(!v3.allowsManuscriptInsertion)

        // 4. Missing identifier offline -> UNVERIFIED
        let missingPID = BibliographyEntry(
            citeKey: "knuth1997taocp",
            kind: .book,
            title: "The Art of Computer Programming, Volume 1: Fundamental Algorithms",
            authors: [BibAuthor(givenName: "Donald E.", familyName: "Knuth")],
            year: 1997,
            publisher: "Addison-Wesley"
        )
        let v4 = firewall.evaluate(missingPID)
        #expect(v4.firewallClass == .unverified)
        #expect(!v4.allowsManuscriptInsertion)

        // 5a. Placeholder prefix with syntactically valid ISO 26324 DOI offline -> UNVERIFIED (reason: offline) with sentinel finding
        let blocked = makeHallucinatedSmithEntry()
        let v5 = firewall.evaluate(blocked)
        #expect(v5.firewallClass == .unverified)
        #expect(v5.reasons == ["offline"])
        #expect(v5.findings.contains { $0.code == .blockedPlaceholderSentinel })
        #expect(!v5.allowsManuscriptInsertion)

        // 5b. Malformed DOI syntax offline -> NOT_FOUND (reason: invalid_identifier)
        let malformedDOI = BibliographyEntry(
            citeKey: "bad2025syntax",
            kind: .article,
            title: "Paper With Malformed Identifier",
            authors: [BibAuthor(givenName: "Ada", familyName: "Lovelace")],
            year: 2025,
            doi: "not-a-valid-doi"
        )
        let vMalformed = firewall.evaluate(malformedDOI)
        #expect(vMalformed.firewallClass == .notFound)
        #expect(vMalformed.reasons == ["invalid_identifier"])
        #expect(!vMalformed.allowsManuscriptInsertion)
    }

    @Test("Firewall hard-blocks smith2025hallucinated, retracted DOIs, and unverified entries with ERR_UNVERIFIED_CITATION")
    func firewallHardBlocksSmith2025HallucinatedAndRetractedDOIsWithErrUnverifiedCitation() async throws {
        let firewall = CitationVerificationFirewall()
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let vaswaniStoredOnly = makeVaswaniEntry()
        let lecunClean = BibliographyEntry(
            citeKey: "lecun2015deep",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )
        let smithFake = makeHallucinatedSmithEntry()
        let wakefieldRetracted = BibliographyEntry(
            citeKey: "wakefield1998retracted",
            kind: .article,
            title: "Ileal-lymphoid-nodular hyperplasia",
            authors: [BibAuthor(givenName: "Andrew", familyName: "Wakefield")],
            year: 1998,
            venue: "The Lancet",
            doi: "10.1016/S0140-6736(97)11096-0"
        )
        let offlineOnly = BibliographyEntry(
            citeKey: "offline2024draft",
            kind: .misc,
            title: "Working Note Without Any Persistent Identifier",
            authors: [BibAuthor(givenName: "Alice", familyName: "Lee")],
            year: 2024
        )

        let library: [String: BibliographyEntry] = [
            vaswaniStoredOnly.citeKey: vaswaniStoredOnly,
            lecunClean.citeKey: lecunClean,
            smithFake.citeKey: smithFake,
            wakefieldRetracted.citeKey: wakefieldRetracted,
            offlineOnly.citeKey: offlineOnly
        ]

        // Stored `.verified` flag on BibliographyEntry without an in-run verdict MUST NOT clear the gate (S42, S48)
        do {
            _ = try firewall.assertCitationAllowed(citeKey: "vaswani2017attention", in: library)
            Issue.record("Expected stored-only firewallClass to be rejected without in-run verdict")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }

        let inRunVerdicts: [String: CitationFirewallEntryVerdict] = [
            lecunClean.citeKey: await firewall.verifyAgainstPublicRegistries(entry: lecunClean, session: replay),
            smithFake.citeKey: await firewall.verifyAgainstPublicRegistries(entry: smithFake, session: replay),
            wakefieldRetracted.citeKey: await firewall.verifyAgainstPublicRegistries(entry: wakefieldRetracted, session: replay)
        ]

        // Entry verified in-run against recorded registry fixtures clears the gate
        let cleared = try firewall.assertCitationAllowed(
            citeKey: "lecun2015deep",
            in: library,
            verifiedVerdicts: inRunVerdicts
        )
        #expect(cleared.citeKey == "lecun2015deep")

        // Blocked, retracted, unverified-in-run, and missing keys all throw ERR_UNVERIFIED_CITATION
        for forbiddenKey in ["vaswani2017attention", "smith2025hallucinated", "wakefield1998retracted", "offline2024draft", "missingKey999"] {
            do {
                _ = try firewall.assertCitationAllowed(
                    citeKey: forbiddenKey,
                    in: library,
                    verifiedVerdicts: inRunVerdicts
                )
                Issue.record("Expected ERR_UNVERIFIED_CITATION for \(forbiddenKey)")
            } catch let err as ScholarOSError {
                #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
            }
        }
    }

    @Test("CitationVerificationFirewall.auditLibrary aggregates 5-class ledger counts and pass rate")
    func firewallAuditLibrarySummaryMetricsAndPassRate() {
        let firewall = CitationVerificationFirewall()
        let entries: [BibliographyEntry] = [
            makeVaswaniEntry(),
            BibliographyEntry(
                citeKey: "arxiv2023valid",
                kind: .preprint,
                title: "Direct Preference Optimization: Your Language Model is Secretly a Reward Model",
                authors: [BibAuthor(givenName: "Rafael", familyName: "Rafailov")],
                year: 2023,
                arxivID: "2305.18290"
            ),
            BibliographyEntry(
                citeKey: "offline2022tech",
                kind: .techreport,
                title: "Internal Compiler Memo on SSA Register Allocation",
                authors: [BibAuthor(givenName: "grace", familyName: "Hopper")],
                year: 2022
            ),
            makeHallucinatedSmithEntry()
        ]

        let report = firewall.auditLibrary(entries)
        #expect(report.totalEvaluated == 4)
        #expect(report.complete == false)
        #expect(report.verifiedCount == 0)
        #expect(report.driftCount == 0)
        #expect(report.retractedCount == 0)
        #expect(report.unverifiedCount == 4)
        #expect(report.notFoundCount == 0)
        #expect(report.unverifiedByReason == ["offline": 4])
        #expect(report.manuscriptInsertionAllowedCount == 0)
        #expect(abs(report.insertionPassRate - 0.0) < 1e-9)
        #expect(report.blockedCiteKeys.isEmpty)
        #expect(report.unverifiedCiteKeys == ["vaswani2017attention", "arxiv2023valid", "offline2022tech", "smith2025hallucinated"])
    }

    @Test("S2 regression: offline evaluate never returns VERIFIED even when DOI or arXiv syntax is valid")
    func firewallOfflineNeverReturnsVerifiedForValidOrFabricatedDOI() {
        let firewall = CitationVerificationFirewall()

        // 1. Syntactically valid but fabricated DOI (`10.1038/fake.2026.99999`)
        let fabricatedNatureDOI = BibliographyEntry(
            citeKey: "fake2026nature",
            kind: .article,
            title: "Plausible Sounding Paper with Syntactically Valid Nature DOI",
            authors: [BibAuthor(givenName: "Alice", familyName: "Example")],
            year: 2026,
            venue: "Nature",
            doi: "10.1038/fake.2026.99999"
        )
        let vFabricated = firewall.evaluate(fabricatedNatureDOI)
        #expect(vFabricated.firewallClass.rawValue == "UNVERIFIED")
        #expect(!vFabricated.allowsManuscriptInsertion)

        // 2. Syntactically valid real DOI (`10.1038/nature14539`, LeCun 2015) checked offline without registry query
        let realUnqueriedDOI = BibliographyEntry(
            citeKey: "lecun2015deep",
            kind: .article,
            title: "Deep learning",
            authors: [BibAuthor(givenName: "Yann", familyName: "LeCun")],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )
        let vRealOffline = firewall.evaluate(realUnqueriedDOI)
        #expect(vRealOffline.firewallClass.rawValue == "UNVERIFIED")
        #expect(!vRealOffline.allowsManuscriptInsertion)
    }

    @Test("S6 regression: built-in retracted DOI list yields RETRACTED and explicitly notes incomplete built-in list")
    func firewallOfflineBuiltInRetractedDOIReportsIncompleteListNotice() {
        let firewall = CitationVerificationFirewall()
        let wakefield = BibliographyEntry(
            citeKey: "wakefield1998retracted",
            kind: .article,
            title: "Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children",
            authors: [BibAuthor(givenName: "A. J.", familyName: "Wakefield")],
            year: 1998,
            venue: "The Lancet",
            doi: "10.1016/S0140-6736(97)11096-0"
        )
        let verdict = firewall.evaluate(wakefield)
        #expect(verdict.firewallClass.rawValue == "RETRACTED")
        #expect(!verdict.allowsManuscriptInsertion)
        // S32: the library note is English; the Chinese wording lives only in the zh localization.
        #expect(verdict.auditNote.contains("built-in list, incomplete"))
        #expect(!containsChineseCharacters(verdict.auditNote))
        #expect(verdict.auditedEntry.localizedFirewallAuditNote(.zhHans).contains("内置名单，不完整"))
        #expect(verdict.auditedEntry.localizedFirewallAuditNote(.en) == verdict.auditNote)
    }

    @Test("S32 regression: English firewall notes and finding details contain no Chinese characters")
    func s32EnglishFirewallNotesContainNoChineseCharacters() {
        let firewall = CitationVerificationFirewall()
        let samples: [BibliographyEntry] = [
            BibliographyEntry(
                citeKey: "wakefield1998retracted",
                kind: .article,
                title: "Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children",
                authors: [BibAuthor(givenName: "A. J.", familyName: "Wakefield")],
                year: 1998,
                venue: "The Lancet",
                doi: "10.1016/S0140-6736(97)11096-0"
            ),
            BibliographyEntry(
                citeKey: "titleMarkedRetracted",
                kind: .article,
                title: "RETRACTED: A study that was withdrawn",
                authors: [BibAuthor(givenName: "Ada", familyName: "Example")],
                year: 2012,
                venue: "Journal of Examples"
            ),
            BibliographyEntry(
                citeKey: "lecun2015deep",
                kind: .article,
                title: "Deep learning",
                authors: [BibAuthor(givenName: "Yann", familyName: "LeCun")],
                year: 2015,
                venue: "Nature",
                doi: "10.1038/nature14539"
            ),
            BibliographyEntry(
                citeKey: "sentinel2026",
                kind: .article,
                title: "Self-Supervised Topological Priors for Protein Folding",
                authors: [BibAuthor(givenName: "Ngozi", familyName: "Okafor")],
                year: 2026,
                venue: "Science",
                doi: "10.1234/fake.2026.99999"
            ),
            BibliographyEntry(
                citeKey: "knuth1968",
                kind: .book,
                title: "The Art of Computer Programming, Volume 1: Fundamental Algorithms",
                authors: [BibAuthor(givenName: "Donald E.", familyName: "Knuth")],
                year: 1968,
                venue: ""
            )
        ]
        for entry in samples {
            let verdict = firewall.evaluate(entry)
            #expect(!containsChineseCharacters(verdict.auditNote), "note of \(entry.citeKey): \(verdict.auditNote)")
            for finding in verdict.findings {
                #expect(!containsChineseCharacters(finding.detail), "finding of \(entry.citeKey): \(finding.detail)")
            }
        }
        // Built-in DOI list yields RETRACTED offline; title-only retraction prefix stays UNVERIFIED offline with warning finding (M1 item 4 / S41).
        #expect(firewall.evaluate(samples[0]).auditNote.contains("built-in list, incomplete"))
        let titleOnlyVerdict = firewall.evaluate(samples[1])
        #expect(titleOnlyVerdict.firewallClass == .unverified)
        #expect(titleOnlyVerdict.reasons == ["offline"])
        #expect(titleOnlyVerdict.findings.contains { $0.code == .blockedRetractedWork })
    }

    @Test("S33 regression: notes say 'not checked' without claiming an offline mode, and a VERIFIED note never carries a not-checked clause")
    func s33NotCheckedWordingIsHonestAndVerifiedNoteIsNotSelfContradictory() async {
        struct UnreachableRegistrySession: CitationRegistrySession {
            func send(_ request: URLRequest) async throws -> RegistryHTTPResponse {
                throw URLError(.notConnectedToInternet)
            }
        }

        let firewall = CitationVerificationFirewall()
        let doiEntry = BibliographyEntry(
            citeKey: "lecun2015deep",
            kind: .article,
            title: "Deep learning",
            authors: [BibAuthor(givenName: "Yann", familyName: "LeCun")],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )
        let arxivEntry = BibliographyEntry(
            citeKey: "vaswani2017attention",
            kind: .misc,
            title: "Attention Is All You Need",
            authors: [BibAuthor(givenName: "Ashish", familyName: "Vaswani")],
            year: 2017,
            venue: "arXiv",
            arxivID: "1706.03762"
        )
        let pmidEntry = BibliographyEntry(
            citeKey: "page2021prisma",
            kind: .article,
            title: "The PRISMA 2020 statement",
            authors: [BibAuthor(givenName: "Matthew J.", familyName: "Page")],
            year: 2021,
            venue: "BMJ",
            pmid: "33782057"
        )
        let noIdentifierEntry = BibliographyEntry(
            citeKey: "knuth1968",
            kind: .book,
            title: "The Art of Computer Programming, Volume 1: Fundamental Algorithms",
            authors: [BibAuthor(givenName: "Donald E.", familyName: "Knuth")],
            year: 1968,
            venue: ""
        )

        for entry in [doiEntry, arxivEntry, pmidEntry, noIdentifierEntry] {
            let verdict = firewall.evaluate(entry)
            #expect(verdict.firewallClass == .unverified)
            // 1. Without a registry query the note says so, and does not pretend the user chose an "offline" mode.
            #expect(verdict.auditNote.contains("Not checked against any external registry."), "\(verdict.auditNote)")
            #expect(!verdict.auditNote.lowercased().contains("offline"), "\(verdict.auditNote)")
            // The Chinese rendering states the same thing, again without an "offline mode".
            let zhNote = verdict.auditedEntry.localizedFirewallAuditNote(.zhHans)
            #expect(zhNote.contains("尚未向外部注册库核查"), "\(zhNote)")
            #expect(!zhNote.contains("离线"), "\(zhNote)")

            // 2. Positive (pass) findings state facts about syntax only. They are what a VERIFIED note is
            //    built from, so none of them may say "not checked" or "offline".
            for finding in verdict.findings where finding.severity == .pass {
                #expect(!finding.detail.lowercased().contains("not checked"), "\(finding.detail)")
                #expect(!finding.detail.lowercased().contains("offline"), "\(finding.detail)")
            }
        }

        // 3. Compose the note the way the online path does when a registry record matches: the offline
        //    findings plus a registry-match finding, summarized for class VERIFIED. (This exercises the note
        //    composer only; it is not evidence that online verification works. That is M1.)
        let offlineFindings = firewall.evaluate(doiEntry).findings
        let registryMatch = FirewallFinding(
            code: .registryVerifiedMatch,
            severity: .pass,
            field: "registry",
            detail: "Verified live metadata match against Crossref (title Jaro-Winkler 1.000)."
        )
        let verifiedNote = firewall.summarizeFindings(offlineFindings + [registryMatch], assignedClass: .verified)
        #expect(verifiedNote.hasPrefix("[VERIFIED] "))
        #expect(!verifiedNote.lowercased().contains("not checked"), "\(verifiedNote)")
        #expect(!verifiedNote.lowercased().contains("offline"), "\(verifiedNote)")
        var verifiedEntry = doiEntry
        verifiedEntry.firewallClass = .verified
        verifiedEntry.firewallAuditNote = verifiedNote
        let zhVerifiedNote = verifiedEntry.localizedFirewallAuditNote(.zhHans)
        #expect(!zhVerifiedNote.contains("尚未"), "\(zhVerifiedNote)")
        #expect(!zhVerifiedNote.contains("离线"), "\(zhVerifiedNote)")

        // 4. When a lookup was attempted and failed, the note reports the failure; it neither repeats the
        //    "not checked" sentence of the no-lookup path nor mentions an offline mode.
        let failed = await firewall.verifyAgainstPublicRegistries(entry: doiEntry, session: UnreachableRegistrySession())
        #expect(failed.firewallClass == .unverified)
        #expect(failed.auditNote.contains("unreachable"), "\(failed.auditNote)")
        #expect(!failed.auditNote.contains("Not checked against any external registry."), "\(failed.auditNote)")
        #expect(!failed.auditNote.contains("(offline)"), "\(failed.auditNote)")
    }

    @Test("S19 regression: transport error, HTTP 429, and HTTP 500 in verifyAgainstPublicRegistries all return UNVERIFIED")
    func firewallOnlineRegistryTransport429And500FailuresReturnUnverified() async {
        struct FailingRegistrySession: CitationRegistrySession {
            enum Mode: Sendable {
                case transportError
                case status(Int)
            }
            let mode: Mode
            func send(_ request: URLRequest) async throws -> RegistryHTTPResponse {
                switch mode {
                case .transportError:
                    throw URLError(.notConnectedToInternet)
                case .status(let code):
                    return RegistryHTTPResponse(statusCode: code, body: Data("{\"error\":\"unavailable\"}".utf8))
                }
            }
        }

        let firewall = CitationVerificationFirewall(rateLimiter: RegistryRateLimiter(clock: .immediate))
        let entry = BibliographyEntry(
            citeKey: "lecun2015deep",
            kind: .article,
            title: "Deep learning",
            authors: [BibAuthor(givenName: "Yann", familyName: "LeCun")],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )

        let transportVerdict = await firewall.verifyAgainstPublicRegistries(
            entry: entry,
            session: FailingRegistrySession(mode: .transportError)
        )
        #expect(transportVerdict.firewallClass.rawValue == "UNVERIFIED")
        #expect(!transportVerdict.allowsManuscriptInsertion)

        let rateLimitedVerdict = await firewall.verifyAgainstPublicRegistries(
            entry: entry,
            session: FailingRegistrySession(mode: .status(429))
        )
        #expect(rateLimitedVerdict.firewallClass.rawValue == "UNVERIFIED")
        #expect(!rateLimitedVerdict.allowsManuscriptInsertion)

        let serverErrorVerdict = await firewall.verifyAgainstPublicRegistries(
            entry: entry,
            session: FailingRegistrySession(mode: .status(500))
        )
        #expect(serverErrorVerdict.firewallClass.rawValue == "UNVERIFIED")
        #expect(!serverErrorVerdict.allowsManuscriptInsertion)

        let notFoundVerdict = await firewall.verifyAgainstPublicRegistries(
            entry: entry,
            session: FailingRegistrySession(mode: .status(404))
        )
        #expect(notFoundVerdict.firewallClass.rawValue == "UNVERIFIED")
        #expect(notFoundVerdict.reasons == ["unparseable"])
        #expect(!notFoundVerdict.allowsManuscriptInsertion)
    }

    // MARK: - 6. Zotero SQLite Read-Only Bridge Tests

    @Test("ZoteroSQLiteReadBridge summarizes, imports, and searches temporary synthetic Zotero SQLite database")
    func zoteroSQLiteReadBridgeSummaryImportAndSearchOnTempDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-zotero-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("zotero.sqlite").path
        let seedEntries: [BibliographyEntry] = [
            makeVaswaniEntry(),
            BibliographyEntry(
                citeKey: "rafailov2023dpo",
                kind: .preprint,
                title: "Direct Preference Optimization: Your Language Model is Secretly a Reward Model",
                authors: [
                    BibAuthor(givenName: "Rafael", familyName: "Rafailov"),
                    BibAuthor(givenName: "Archit", familyName: "Sharma")
                ],
                year: 2023,
                venue: "arXiv",
                arxivID: "2305.18290"
            ),
            makeHallucinatedSmithEntry()
        ]

        _ = try ZoteroSQLiteReadBridge.createSyntheticZoteroDatabase(
            at: dbPath,
            entries: seedEntries,
            collectionName: "Transformers & Alignment",
            createMockPDFAttachmentFiles: true
        )

        let bridge = ZoteroSQLiteReadBridge()
        let summary = try bridge.summarizeLibrary(databasePath: dbPath, immutable: true)

        #expect(summary.openedImmutableReadOnly)
        #expect(summary.bibliographicItemsCount == 3)
        #expect(summary.totalCollectionsCount >= 1)
        #expect(summary.totalCreatorsCount >= 5)

        var importOpts = ZoteroImportOptions.standard
        importOpts.zoteroDataDirectoryPath = tempDir.path
        let imported = try bridge.importEntries(databasePath: dbPath, options: importOpts)

        #expect(imported.count == 3)
        #expect(imported.contains { $0.doi == "10.5555/3295222.3295349" && $0.firewallClass == .unverified })
        #expect(imported.contains { $0.arxivID == "2305.18290" && $0.firewallClass == .unverified })
        #expect(imported.contains { $0.doi == "10.9999/hallucinated.2025.0001" && $0.firewallClass == .unverified })

        let dpoHits = try bridge.searchEntries(databasePath: dbPath, query: "Preference Optimization", options: importOpts)
        #expect(dpoHits.count == 1)
        #expect(dpoHits.first?.arxivID == "2305.18290")
    }

    @Test("ZoteroSQLiteReadBridge filters by collection name and respects maxItemsLimit")
    func zoteroSQLiteReadBridgeCollectionFilterAndIncludeTrashedOption() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-zotero-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("zotero.sqlite").path
        _ = try ZoteroSQLiteReadBridge.createSyntheticZoteroDatabase(
            at: dbPath,
            entries: [makeVaswaniEntry(), makeHallucinatedSmithEntry()],
            collectionName: "Core Reading List",
            createMockPDFAttachmentFiles: false
        )

        let bridge = ZoteroSQLiteReadBridge()
        let matchedCollection = try bridge.importEntries(
            databasePath: dbPath,
            options: ZoteroImportOptions(collectionNameFilter: "Core Reading List", maxItemsLimit: 1)
        )
        #expect(matchedCollection.count == 1)

        let unmatchedCollection = try bridge.importEntries(
            databasePath: dbPath,
            options: ZoteroImportOptions(collectionNameFilter: "Nonexistent Subcollection")
        )
        #expect(unmatchedCollection.isEmpty)
    }

    // MARK: - 7. S43 Registry Transport Layer Tests

    @Test("S43 regression: ephemeral session config has nil URLCache, 15s timeout, ScholarOS/1.2.0 User-Agent without @ or mailto, and no politeMailto in Sources")
    func s43TransportDefaultsUserAgentAndNoPoliteMailtoInSources() async throws {
        let defaultClient = LiveURLSessionRegistryClient()
        #expect(defaultClient.timeoutInterval == 15.0)
        #expect(LiveURLSessionRegistryClient.defaultUserAgent == "ScholarOS/1.2.0")

        let config = try #require(defaultClient.sessionConfiguration)
        #expect(config.urlCache == nil)
        #expect(config.httpCookieStorage == nil)
        #expect(!config.httpShouldSetCookies)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(config.timeoutIntervalForRequest == 15.0)
        #expect(config.timeoutIntervalForResource == 15.0)

        let hasPoliteMailtoProperty = Mirror(reflecting: defaultClient).children.contains {
            $0.label == "politeMailto"
        }
        #expect(!hasPoliteMailtoProperty)

        actor CapturedRequestBox {
            var request: URLRequest?
            func store(_ req: URLRequest) { request = req }
        }
        let box = CapturedRequestBox()
        let client = LiveURLSessionRegistryClient { req in
            await box.store(req)
            let url = try #require(req.url)
            let http = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (Data("{}".utf8), http)
        }

        let targetURL = try #require(RegistryURLBuilder.crossrefWorkURL(doi: "10.1038/nature14539"))
        var incoming = URLRequest(url: targetURL)
        incoming.setValue("CustomCaller/0.1", forHTTPHeaderField: "User-Agent")
        _ = try await client.send(incoming)

        let sent = try #require(await box.request)
        #expect(sent.timeoutInterval == 15.0)
        #expect(sent.cachePolicy == .reloadIgnoringLocalCacheData)
        let ua = try #require(sent.value(forHTTPHeaderField: "User-Agent"))
        #expect(ua == "ScholarOS/1.2.0")
        #expect(!ua.contains("@"))
        #expect(!ua.lowercased().contains("mailto"))
        #expect(!ua.lowercased().contains("http://"))
        #expect(!ua.lowercased().contains("https://"))

        // Verify Sources/ contains no politeMailto or mailto references.
        try Self.assertSourcesContainNoMailtoReferences()
    }

    private static func assertSourcesContainNoMailtoReferences() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesDir = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil))
        var swiftFileCount = 0
        while let item = enumerator.nextObject() {
            guard let fileURL = item as? URL, fileURL.pathExtension == "swift" else {
                continue
            }
            swiftFileCount += 1
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(!contents.contains("politeMailto"), "Found forbidden politeMailto in \(fileURL.lastPathComponent)")
            #expect(!contents.lowercased().contains("mailto"), "Found forbidden mailto in \(fileURL.lastPathComponent)")
        }
        #expect(swiftFileCount > 0)
    }

    @Test("S43 regression: response headers from item 5 are returned case-insensitively and unlisted headers are excluded")
    func s43TransportReturnsCapturedHeadersViaClosureAndURLProtocol() async throws {
        let rawWireHeaders: [String: String] = [
            "content-type": "application/json; charset=utf-8",
            "retry-after": "7",
            "X-Rate-Limit-Limit": "5",
            "x-rate-limit-interval": "1s",
            "X-Concurrency-Limit": "1",
            "X-RateLimit-Remaining": "958",
            "x-ratelimit-cost-usd": "0.001",
            "X-Unlisted-Server-Noise": "ignored"
        ]

        // 1. Test via injected dataLoader closure
        let loaderClient = LiveURLSessionRegistryClient { req in
            let url = try #require(req.url)
            let http = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 429,
                    httpVersion: "HTTP/2",
                    headerFields: rawWireHeaders
                )
            )
            return (Data("{\"status\":\"rate_limited\"}".utf8), http)
        }

        let url = try #require(RegistryURLBuilder.openAlexWorkURL(doi: "10.1038/nature14539"))
        let res = try await loaderClient.send(URLRequest(url: url))
        #expect(res.statusCode == 429)
        #expect(res.headers.count == 7)
        #expect(res.headers["Content-Type"] == "application/json; charset=utf-8")
        #expect(res.headers["Retry-After"] == "7")
        #expect(res.headers["x-rate-limit-limit"] == "5")
        #expect(res.headers["x-rate-limit-interval"] == "1s")
        #expect(res.headers["x-concurrency-limit"] == "1")
        #expect(res.headers["x-ratelimit-remaining"] == "958")
        #expect(res.headers["x-ratelimit-cost-usd"] == "0.001")
        #expect(res.headers["X-Unlisted-Server-Noise"] == nil)
        #expect(res.headerValue(for: "RETRY-AFTER") == "7")

        // 2. Test via offline URLProtocol attached to LiveURLSessionRegistryClient's ephemeral URLSession
        final class HeaderStubURLProtocol: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let reqURL = request.url,
                      let http = HTTPURLResponse(
                          url: reqURL,
                          statusCode: 200,
                          httpVersion: "HTTP/1.1",
                          headerFields: [
                              "Content-Type": "application/json",
                              "x-ratelimit-remaining": "990",
                              "x-ratelimit-cost-usd": "0",
                              "Server": "stub"
                          ]
                      ) else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                let sentUA = request.value(forHTTPHeaderField: "User-Agent") ?? ""
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(sentUA.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        let protocolClient = LiveURLSessionRegistryClient(protocolClasses: [HeaderStubURLProtocol.self])
        let protoRes = try await protocolClient.send(URLRequest(url: url))
        #expect(protoRes.statusCode == 200)
        #expect(String(data: protoRes.body, encoding: .utf8) == "ScholarOS/1.2.0")
        #expect(protoRes.headers["Content-Type"] == "application/json")
        #expect(protoRes.headers["x-ratelimit-remaining"] == "990")
        #expect(protoRes.headers["x-ratelimit-cost-usd"] == "0")
        #expect(protoRes.headers["Server"] == nil)
    }

    @Test("S43 regression: non-HTTP URLResponse throws transport_error instead of defaulting to 200")
    func s43NonHTTPURLResponseThrowsTransportErrorAndNeverDefaultsTo200() async throws {
        final class NonHTTPStubURLProtocol: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let reqURL = request.url ?? URL(string: "https://api.crossref.org/works/10.1038/nature14539")!
                let plainResponse = URLResponse(
                    url: reqURL,
                    mimeType: "application/octet-stream",
                    expectedContentLength: 2,
                    textEncodingName: nil
                )
                client?.urlProtocol(self, didReceive: plainResponse, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        let url = try #require(RegistryURLBuilder.crossrefWorkURL(doi: "10.1038/nature14539"))

        // 1. Direct dataLoader returning plain URLResponse
        let closureClient = LiveURLSessionRegistryClient { req in
            let reqURL = try #require(req.url)
            let nonHTTP = URLResponse(url: reqURL, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil)
            return (Data(), nonHTTP)
        }

        do {
            _ = try await closureClient.send(URLRequest(url: url))
            Issue.record("Expected RegistryTransportError(.transportError) for non-HTTP URLResponse")
        } catch let err as RegistryTransportError {
            #expect(err.kind == .transportError)
            #expect(err.reasonCode == "transport_error")
        }

        // 2. Ephemeral URLSession with URLProtocol returning plain URLResponse
        let protocolClient = LiveURLSessionRegistryClient(protocolClasses: [NonHTTPStubURLProtocol.self])
        do {
            _ = try await protocolClient.send(URLRequest(url: url))
            Issue.record("Expected RegistryTransportError(.transportError) from URLSession non-HTTP response")
        } catch let err as RegistryTransportError {
            #expect(err.kind == .transportError)
            #expect(err.reasonCode == "transport_error")
        }

        // 3. End-to-end firewall verdict is UNVERIFIED (never VERIFIED)
        let firewall = CitationVerificationFirewall()
        let entry = BibliographyEntry(
            citeKey: "lecun2015",
            kind: .article,
            title: "Deep learning",
            authors: [BibAuthor(givenName: "Yann", familyName: "LeCun")],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )
        let verdict = await firewall.verifyAgainstPublicRegistries(entry: entry, session: protocolClient)
        #expect(verdict.firewallClass == .unverified)
        #expect(!verdict.allowsManuscriptInsertion)
    }

    @Test("S43 regression: request timeout surfaces RegistryTransportError.timeout in both dataLoader and ephemeral URLSession")
    func s43RequestTimeoutThrowsTimeoutErrorAndFirewallReturnsUnverified() async throws {
        final class HangingURLProtocol: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                // Intentionally never finishes so URLSession enforces timeoutInterval.
            }
            override func stopLoading() {}
        }

        let url = try #require(RegistryURLBuilder.crossrefWorkURL(doi: "10.1038/nature14539"))

        // 1. Injected URLError(.timedOut)
        let loaderTimeoutClient = LiveURLSessionRegistryClient { _ in
            throw URLError(.timedOut)
        }
        do {
            _ = try await loaderTimeoutClient.send(URLRequest(url: url))
            Issue.record("Expected timeout error from URLError(.timedOut)")
        } catch let err as RegistryTransportError {
            #expect(err.kind == .timeout)
            #expect(err.reasonCode == "timeout")
        }

        // 2. Real URLSession timeout enforcement with HangingURLProtocol (0.15s)
        let sessionTimeoutClient = LiveURLSessionRegistryClient(
            timeoutInterval: 0.15,
            protocolClasses: [HangingURLProtocol.self]
        )
        do {
            _ = try await sessionTimeoutClient.send(URLRequest(url: url))
            Issue.record("Expected timeout error from hanging URLProtocol")
        } catch let err as RegistryTransportError {
            #expect(err.kind == .timeout)
            #expect(err.reasonCode == "timeout")
        }

        // 3. Firewall marks entry UNVERIFIED on timeout
        let firewall = CitationVerificationFirewall()
        let entry = BibliographyEntry(
            citeKey: "lecun2015",
            kind: .article,
            title: "Deep learning",
            authors: [BibAuthor(givenName: "Yann", familyName: "LeCun")],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )
        let verdict = await firewall.verifyAgainstPublicRegistries(entry: entry, session: loaderTimeoutClient)
        #expect(verdict.firewallClass == .unverified)
        #expect(!verdict.allowsManuscriptInsertion)
    }

    @Test("S43 regression: URLComponents builds valid URLs when DOI contains #, ?, spaces, angle brackets, and percent signs")
    func s43URLComponentsEncodesSpecialCharacterDOIsAndClosureSessionInjection() async throws {
        // 1. Direct URLComponents builder checks with #, ?, spaces, <, >, %
        let doiHashQuerySpace = "10.1000/abc#def?ghi jkl"
        let crossref1 = try #require(RegistryURLBuilder.crossrefWorkURL(doi: doiHashQuerySpace))
        let openAlex1 = try #require(RegistryURLBuilder.openAlexWorkURL(doi: doiHashQuerySpace))
        let handle1 = try #require(RegistryURLBuilder.doiHandleURL(doi: doiHashQuerySpace))

        #expect(crossref1.absoluteString == "https://api.crossref.org/works/10.1000/abc%23def%3Fghi%20jkl")
        #expect(openAlex1.absoluteString == "https://api.openalex.org/works/https://doi.org/10.1000/abc%23def%3Fghi%20jkl")
        #expect(handle1.absoluteString == "https://doi.org/api/handles/10.1000/abc%23def%3Fghi%20jkl")

        for built in [crossref1, openAlex1, handle1] {
            #expect(built.query == nil)
            #expect(built.fragment == nil)
        }

        // ? before # plus & and space
        let doiQueryBeforeHash = "https://doi.org/10.1000/part?x=1&y=2#sec 3"
        let crossref2 = try #require(RegistryURLBuilder.crossrefWorkURL(doi: doiQueryBeforeHash))
        #expect(crossref2.absoluteString == "https://api.crossref.org/works/10.1000/part%3Fx=1&y=2%23sec%203")
        #expect(crossref2.query == nil)
        #expect(crossref2.fragment == nil)

        // Query endpoints with special characters (#, ?, &, +, spaces)
        let crSearch = try #require(RegistryURLBuilder.crossrefBibliographicSearchURL(query: "C++ & Q#? 1986", rows: 5))
        #expect(crSearch.host == "api.crossref.org")
        #expect(crSearch.path == "/works")
        #expect(crSearch.fragment == nil)
        #expect(crSearch.absoluteString.contains("%2B%2B"))
        #expect(crSearch.absoluteString.contains("%23"))
        #expect(crSearch.absoluteString.contains("%3F"))

        let oaSearch = try #require(RegistryURLBuilder.openAlexSearchURL(query: "Knuth #1? Vol 1", perPage: 5))
        #expect(oaSearch.host == "api.openalex.org")
        #expect(oaSearch.fragment == nil)

        let arxivURL = try #require(RegistryURLBuilder.arXivQueryURL(arXivID: "1706.03762"))
        #expect(arxivURL.absoluteString == "https://export.arxiv.org/api/query?id_list=1706.03762")

        let pmidURL = try #require(RegistryURLBuilder.pubMedSummaryURL(pmid: "9500320"))
        #expect(pmidURL.absoluteString == "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id=9500320&retmode=json")

        // 2. End-to-end verifyAgainstPublicRegistries using ClosureRegistrySession on a DOI with <, >, #, ?
        actor URLRecorder {
            var urls: [URL] = []
            func append(_ url: URL?) {
                if let url { urls.append(url) }
            }
        }
        let recorder = URLRecorder()
        let closureSession = ClosureRegistrySession { request in
            await recorder.append(request.url)
            return RegistryHTTPResponse(statusCode: 404, body: Data("not found".utf8))
        }

        let firewall = CitationVerificationFirewall()
        let trickyEntry = BibliographyEntry(
            citeKey: "sici1998",
            kind: .article,
            title: "Sample SICI Identifier Entry",
            authors: [BibAuthor(givenName: "Ada", familyName: "Lovelace")],
            year: 1998,
            venue: "Statistics in Medicine",
            doi: "10.1002/(sici)1097-0258<1661>?v=1#sec"
        )

        _ = await firewall.verifyAgainstPublicRegistries(
            entry: trickyEntry,
            session: closureSession
        )

        let urls = await recorder.urls
        #expect(urls.count == 3)
        for url in urls {
            #expect(url.query == nil, "Unexpected query in \(url.absoluteString)")
            #expect(url.fragment == nil, "Unexpected fragment in \(url.absoluteString)")
            #expect(url.absoluteString.contains("%3C1661%3E"), "Missing encoded angle brackets in \(url.absoluteString)")
            #expect(url.absoluteString.contains("%3Fv=1%23sec"), "Missing encoded ? and # in \(url.absoluteString)")
        }
    }

    // MARK: - 8. M1 Item 9 Registry Recording & Replay Transport Tests

    @Test("M1 item 9: recordingCapturedHeaderNames captures all 11 headers, preserves 404 body byte-for-byte, and validates SHA-256 on replay")
    func m1Item9RecordingPreservesRawBytesCapturesAllHeadersAndValidatesReplaySHA256() async throws {
        #expect(LiveURLSessionRegistryClient.recordingCapturedHeaderNames.count == 11)
        for expectedHeader in [
            "Content-Type",
            "Retry-After",
            "x-rate-limit-limit",
            "x-rate-limit-interval",
            "x-concurrency-limit",
            "x-ratelimit-remaining",
            "x-ratelimit-cost-usd",
            "Date",
            "x-ratelimit-limit",
            "x-ratelimit-reset",
            "x-ratelimit-credits-used"
        ] {
            #expect(LiveURLSessionRegistryClient.recordingCapturedHeaderNames.contains(expectedHeader))
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-rec-unit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Exact raw 404 body including trailing bytes and upstream contact string (doi.org 404 pattern);
        // must be saved verbatim without altering a single byte.
        let exact404Body: Data = {
            var buf = Data("{\"responseCode\":100,\"handle\":\"10.1234/fake.2026.99999\",\"message\":\"contact admin@doi.example.org\"}\r\n".utf8)
            buf.append(contentsOf: [0x00, 0xFF, 0x0A])
            return buf
        }()

        let client = LiveURLSessionRegistryClient(
            capturedHeaderNames: LiveURLSessionRegistryClient.recordingCapturedHeaderNames
        ) { req in
            let reqURL = try #require(req.url)
            let http = try #require(
                HTTPURLResponse(
                    url: reqURL,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json;charset=UTF-8",
                        "Date": "Sun, 15 Nov 2026 11:00:00 GMT",
                        "x-ratelimit-limit": "1000",
                        "x-ratelimit-remaining": "958",
                        "x-ratelimit-reset": "46800",
                        "x-ratelimit-credits-used": "0",
                        "x-ratelimit-cost-usd": "0"
                    ]
                )
            )
            return (exact404Body, http)
        }

        let recorder = try RegistryRecordingSession(
            directoryURL: tempDir,
            transport: client,
            minimumIntervalSeconds: 0
        )
        let handleURL = try #require(RegistryURLBuilder.doiHandleURL(doi: "10.1234/fake.2026.99999"))
        let recordedResp = try await recorder.send(URLRequest(url: handleURL))
        #expect(recordedResp.statusCode == 404)
        #expect(recordedResp.body == exact404Body)

        let manifest = try await recorder.finalize()
        #expect(manifest.count == 1)
        #expect(manifest.totalHTTPRequestsSent == 1)
        #expect(manifest.userAgent == "ScholarOS/1.2.0")

        let item = try #require(manifest.items.first)
        #expect(item.service == "doi")
        #expect(item.status == 404)
        #expect(item.byteLength == exact404Body.count)
        #expect(item.responseDateHeader == "Sun, 15 Nov 2026 11:00:00 GMT")
        #expect(item.requestHeaders["User-Agent"] == "ScholarOS/1.2.0")
        #expect(item.responseHeaders["Date"] == "Sun, 15 Nov 2026 11:00:00 GMT")
        #expect(item.responseHeaders["x-ratelimit-limit"] == "1000")
        #expect(item.responseHeaders["x-ratelimit-remaining"] == "958")
        #expect(item.responseHeaders["x-ratelimit-reset"] == "46800")
        #expect(item.responseHeaders["x-ratelimit-credits-used"] == "0")

        let diskRaw = try Data(contentsOf: tempDir.appendingPathComponent(item.rawFile))
        #expect(diskRaw == exact404Body)

        // Replay returns identical bytes and headers, and bypassesCache is true
        let replay = try RegistryReplaySession(directoryURL: tempDir)
        #expect(replay.bypassesCache)
        let replayedResp = try await replay.send(URLRequest(url: handleURL))
        #expect(replayedResp.statusCode == 404)
        #expect(replayedResp.body == exact404Body)
        #expect(replayedResp.headerValue(for: "Date") == "Sun, 15 Nov 2026 11:00:00 GMT")
        #expect(replayedResp.headerValue(for: "x-ratelimit-remaining") == "958")

        // Unrecorded URL during replay throws RegistryReplayError.unrecordedRequest carrying the missing URL
        let unrecordedURL = try #require(RegistryURLBuilder.crossrefWorkURL(doi: "10.1038/unrecorded.2026"))
        do {
            _ = try await replay.send(URLRequest(url: unrecordedURL))
            Issue.record("Expected RegistryReplayError.unrecordedRequest for unrecorded URL")
        } catch let err as RegistryReplayError {
            #expect(err.localizedDescription.contains(unrecordedURL.absoluteString))
        }

        // Corrupting 1 byte of .raw causes RegistryReplaySession init to fail SHA-256 verification
        var tamperedRaw = diskRaw
        tamperedRaw[0] ^= 0x01
        try tamperedRaw.write(to: tempDir.appendingPathComponent(item.rawFile))
        #expect(throws: RegistryReplayError.self) {
            _ = try RegistryReplaySession(directoryURL: tempDir)
        }
    }

    @Test("M1 item 9: RegistryRecordingSession rejects disallowed hosts, @/mailto/api_key/local paths in URL or headers, and stops immediately on 429")
    func m1Item9RecordingRejectsSensitiveRequestDataAndStopsOn429() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-rec-guard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        actor CallCounter {
            var count = 0
            func increment() -> Int {
                count += 1
                return count
            }
        }
        let counter = CallCounter()
        let transport = ClosureRegistrySession { _ in
            _ = await counter.increment()
            return RegistryHTTPResponse(statusCode: 429, body: Data("rate limited".utf8), headers: ["Retry-After": "5"])
        }

        let recorder = try RegistryRecordingSession(
            directoryURL: tempDir,
            transport: transport,
            minimumIntervalSeconds: 0
        )

        // 1. Disallowed host rejected before transport is called
        let badHostReq = URLRequest(url: try #require(URL(string: "https://api.semanticscholar.org/graph/v1/paper/123")))
        await #expect(throws: RegistryRecordingError.self) {
            _ = try await recorder.send(badHostReq)
        }

        // 2. Email/@, mailto, api_key, or local path in URL rejected before transport is called
        let forbiddenURLs = [
            "https://api.crossref.org/works/10.1038/nature14539?mailto=user@example.com",
            "https://api.openalex.org/works?search=test&api_key=secret123",
            "https://api.crossref.org/works/10.1038/nature14539?contact=alice%40example.com",
            "https://api.crossref.org/works?query.bibliographic=" + NSHomeDirectory()
        ]
        for raw in forbiddenURLs {
            if let badURL = URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw) ?? URL(string: raw) {
                await #expect(throws: RegistryRecordingError.self) {
                    _ = try await recorder.send(URLRequest(url: badURL))
                }
            }
        }

        // 3. Forbidden header value (@ or api_key) rejected before transport is called
        var badHeaderReq = URLRequest(url: try #require(RegistryURLBuilder.crossrefWorkURL(doi: "10.1038/nature14539")))
        badHeaderReq.setValue("Bearer secret_api_key", forHTTPHeaderField: "X-Custom-Auth")
        await #expect(throws: RegistryRecordingError.self) {
            _ = try await recorder.send(badHeaderReq)
        }

        #expect(await counter.count == 0)

        // 4. Clean allowed request hits transport; HTTP 429 aborts recording immediately without writing .raw
        let cleanDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-rec-429-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cleanDir) }
        let recorder429 = try RegistryRecordingSession(
            directoryURL: cleanDir,
            transport: transport,
            minimumIntervalSeconds: 0
        )
        let validReq = URLRequest(url: try #require(RegistryURLBuilder.crossrefWorkURL(doi: "10.1038/nature14539")))
        await #expect(throws: RegistryRecordingError.self) {
            _ = try await recorder429.send(validReq)
        }
        #expect(await counter.count == 1)
        let writtenFiles = (try? FileManager.default.contentsOfDirectory(atPath: cleanDir.path)) ?? []
        #expect(!writtenFiles.contains { $0.hasSuffix(".raw") })
    }

    // MARK: - 9. M1 Stage 03 Verdict Structure & Comparison Rule Tests (TDD)

    private static var recordedRegistryFixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/registry", isDirectory: true)
    }

    private func encodeVerdictJSONObject(_ verdict: CitationFirewallEntryVerdict) throws -> [String: Any] {
        let data = try JSONEncoder().encode(verdict)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("M1 row 9: every drifted title, surname typo, missing field, and wrong venue pair yields DRIFT with remote values in fields and insertable=false")
    func m1Stage03Row9DriftPairsAndMissingOrWrongFields() async throws {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall()

        let lecunAuthors = [
            BibAuthor(givenName: "Yann", familyName: "LeCun"),
            BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
            BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
        ]
        let lstmAuthors = [
            BibAuthor(givenName: "Sepp", familyName: "Hochreiter"),
            BibAuthor(givenName: "Jürgen", familyName: "Schmidhuber")
        ]
        let vaswaniAuthors = [
            BibAuthor(givenName: "Ashish", familyName: "Vaswani"),
            BibAuthor(givenName: "Noam", familyName: "Shazeer"),
            BibAuthor(givenName: "Niki", familyName: "Parmar"),
            BibAuthor(givenName: "Jakob", familyName: "Uszkoreit"),
            BibAuthor(givenName: "Llion", familyName: "Jones"),
            BibAuthor(givenName: "Aidan N.", familyName: "Gomez"),
            BibAuthor(givenName: "Lukasz", familyName: "Kaiser"),
            BibAuthor(givenName: "Illia", familyName: "Polosukhin")
        ]

        // 1. Real DOI + "Deep learning for protein structure prediction"
        let v1 = await firewall.verifyAgainstPublicRegistries(
            entry: BibliographyEntry(
                citeKey: "drift_protein",
                kind: .article,
                title: "Deep learning for protein structure prediction",
                authors: lecunAuthors,
                year: 2015,
                venue: "Nature",
                doi: "10.1038/nature14539"
            ),
            session: replay
        )
        #expect(v1.firewallClass == .drift)
        let j1 = try encodeVerdictJSONObject(v1)
        #expect(j1["insertable"] as? Bool == false)
        #expect(j1["confidenceScore"] == nil)
        let f1 = (j1["fields"] as? [[String: Any]]) ?? []
        #expect(f1.contains { ($0["field"] as? String) == "title" && ($0["remoteValue"] as? String) == "Deep learning" })

        // 2. Real DOI + single-letter typo "Deep lerning"
        let v2 = await firewall.verifyAgainstPublicRegistries(
            entry: BibliographyEntry(
                citeKey: "drift_typo",
                kind: .article,
                title: "Deep lerning",
                authors: lecunAuthors,
                year: 2015,
                venue: "Nature",
                doi: "10.1038/nature14539"
            ),
            session: replay
        )
        #expect(v2.firewallClass == .drift)
        let j2 = try encodeVerdictJSONObject(v2)
        #expect(j2["insertable"] as? Bool == false)
        let f2 = (j2["fields"] as? [[String: Any]]) ?? []
        #expect(f2.contains { ($0["field"] as? String) == "title" && ($0["remoteValue"] as? String) == "Deep learning" })

        // 3. LSTM DOI + "Long Short-Term Memory Networks for Weather"
        let v3 = await firewall.verifyAgainstPublicRegistries(
            entry: BibliographyEntry(
                citeKey: "drift_lstm_weather",
                kind: .article,
                title: "Long Short-Term Memory Networks for Weather",
                authors: lstmAuthors,
                year: 1997,
                venue: "Neural Computation",
                doi: "10.1162/neco.1997.9.8.1735"
            ),
            session: replay
        )
        #expect(v3.firewallClass == .drift)
        let j3 = try encodeVerdictJSONObject(v3)
        #expect(j3["insertable"] as? Bool == false)
        let f3 = (j3["fields"] as? [[String: Any]]) ?? []
        #expect(f3.contains { ($0["field"] as? String) == "title" && ($0["remoteValue"] as? String) == "Long Short-Term Memory" })

        // 4. 10.48550/arXiv.1706.03762 + "Attention is not all you need"
        let v4 = await firewall.verifyAgainstPublicRegistries(
            entry: BibliographyEntry(
                citeKey: "drift_attention_not",
                kind: .article,
                title: "Attention is not all you need",
                authors: vaswaniAuthors,
                year: 2017,
                doi: "10.48550/arXiv.1706.03762"
            ),
            session: replay
        )
        #expect(v4.firewallClass == .drift)
        let j4 = try encodeVerdictJSONObject(v4)
        #expect(j4["insertable"] as? Bool == false)
        let f4 = (j4["fields"] as? [[String: Any]]) ?? []
        #expect(f4.contains { ($0["field"] as? String) == "title" && ($0["remoteValue"] as? String) == "Attention Is All You Need" })

        // 5a. First author surname off by 1 letter: LeCunn vs LeCun
        let v5a = await firewall.verifyAgainstPublicRegistries(
            entry: BibliographyEntry(
                citeKey: "drift_lecunn",
                kind: .article,
                title: "Deep learning",
                authors: [
                    BibAuthor(givenName: "Yann", familyName: "LeCunn"),
                    BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                    BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
                ],
                year: 2015,
                venue: "Nature",
                doi: "10.1038/nature14539"
            ),
            session: replay
        )
        #expect(v5a.firewallClass == .drift)
        let j5a = try encodeVerdictJSONObject(v5a)
        #expect(j5a["insertable"] as? Bool == false)
        let f5a = (j5a["fields"] as? [[String: Any]]) ?? []
        #expect(f5a.contains { ($0["field"] as? String) == "firstAuthor" && ($0["remoteValue"] as? String) == "LeCun" })

        // 5b. First author surname off by 1 letter: Hochriter vs Hochreiter
        let v5b = await firewall.verifyAgainstPublicRegistries(
            entry: BibliographyEntry(
                citeKey: "drift_hochriter",
                kind: .article,
                title: "Long Short-Term Memory",
                authors: [
                    BibAuthor(givenName: "Sepp", familyName: "Hochriter"),
                    BibAuthor(givenName: "Jürgen", familyName: "Schmidhuber")
                ],
                year: 1997,
                venue: "Neural Computation",
                doi: "10.1162/neco.1997.9.8.1735"
            ),
            session: replay
        )
        #expect(v5b.firewallClass == .drift)
        let j5b = try encodeVerdictJSONObject(v5b)
        #expect(j5b["insertable"] as? Bool == false)
        let f5b = (j5b["fields"] as? [[String: Any]]) ?? []
        #expect(f5b.contains { ($0["field"] as? String) == "firstAuthor" && ($0["remoteValue"] as? String) == "Hochreiter" })

        // 6. Only title + DOI, missing year and author
        let missingBib = """
        @article{missing_year_author,
          title = {Deep learning},
          doi   = {10.1038/nature14539}
        }
        """
        let missingEntry = try #require(try BibTeXCodec().parse(missingBib).first)
        let v6 = await firewall.verifyAgainstPublicRegistries(entry: missingEntry, session: replay)
        #expect(v6.firewallClass == .drift)
        let j6 = try encodeVerdictJSONObject(v6)
        #expect(j6["insertable"] as? Bool == false)
        let f6 = (j6["fields"] as? [[String: Any]]) ?? []
        #expect(f6.contains { ($0["field"] as? String) == "year" && ($0["remoteValue"] as? String) == "2015" })
        #expect(f6.contains { ($0["field"] as? String) == "firstAuthor" && ($0["remoteValue"] as? String) == "LeCun" })

        // 7. Wrong journal / venue ("Science" vs "Nature")
        let v7 = await firewall.verifyAgainstPublicRegistries(
            entry: BibliographyEntry(
                citeKey: "drift_wrong_venue",
                kind: .article,
                title: "Deep learning",
                authors: lecunAuthors,
                year: 2015,
                venue: "Science",
                doi: "10.1038/nature14539"
            ),
            session: replay
        )
        #expect(v7.firewallClass == .drift)
        let j7 = try encodeVerdictJSONObject(v7)
        #expect(j7["insertable"] as? Bool == false)
        let f7 = (j7["fields"] as? [[String: Any]]) ?? []
        #expect(f7.contains { ($0["field"] as? String) == "venue" && ($0["remoteValue"] as? String) == "Nature" })
    }

    @Test("M1 item 1 & 2: clean real entries are VERIFIED with sources/reasons/fields/insertable and no confidenceScore")
    func m1Stage03CleanRealEntriesRemainVerifiedWithoutConfidenceScore() async throws {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall()

        let cleanLeCun = BibliographyEntry(
            citeKey: "real_lecun",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )
        let verdict = await firewall.verifyAgainstPublicRegistries(entry: cleanLeCun, session: replay)
        #expect(verdict.firewallClass == .verified)

        let json = try encodeVerdictJSONObject(verdict)
        #expect(json["insertable"] as? Bool == true)
        #expect(json["confidenceScore"] == nil)
        #expect(json["reasons"] as? [String] != nil)
        let fields = try #require(json["fields"] as? [[String: Any]])
        #expect(fields.isEmpty)
        let sources = try #require(json["sources"] as? [[String: Any]])
        #expect(sources.count == 2)
        #expect(sources.first?["origin"] as? String == "replay")
        #expect(sources.first?["status"] as? Int == 200)
        #expect((sources.first?["url"] as? String) == "https://api.crossref.org/works/10.1038/nature14539")
        #expect((sources.last?["url"] as? String) == "https://api.openalex.org/works/https://doi.org/10.1038/nature14539")

        // Abbreviated venue "Neural Comput." matches "Neural Computation"
        let cleanLSTM = BibliographyEntry(
            citeKey: "real_lstm_abbrev",
            kind: .article,
            title: "Long Short-Term Memory",
            authors: [
                BibAuthor(givenName: "Sepp", familyName: "Hochreiter"),
                BibAuthor(givenName: "Jürgen", familyName: "Schmidhuber")
            ],
            year: 1997,
            venue: "Neural Comput.",
            doi: "10.1162/neco.1997.9.8.1735"
        )
        let lstmVerdict = await firewall.verifyAgainstPublicRegistries(entry: cleanLSTM, session: replay)
        #expect(lstmVerdict.firewallClass == .verified)
    }

    @Test("M1 item 4: sentinel list and wrong ORCID check digit emit findings only and still verify online")
    func m1Stage03PlaceholderAndBadORCIDDoNotBlockOnlineVerification() async throws {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall(additionalSentinelDOIs: ["10.1038/nature14539"])

        let lecunBadORCID = BibliographyEntry(
            citeKey: "lecun_bad_orcid",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun", orcid: "0000-0002-1825-0098"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )

        // Offline: must be UNVERIFIED (reason offline), NOT NOT_FOUND, while retaining advisory findings
        let offlineVerdict = firewall.evaluate(lecunBadORCID)
        #expect(offlineVerdict.firewallClass == .unverified)
        #expect(offlineVerdict.findings.contains { $0.code == .invalidORCIDChecksum })
        #expect(offlineVerdict.findings.contains { $0.code == .blockedPlaceholderSentinel })
        let offlineJSON = try encodeVerdictJSONObject(offlineVerdict)
        #expect((offlineJSON["reasons"] as? [String]) == ["offline"])

        // Online (replay): must NOT short-circuit on offline hints; queries Crossref and derives VERIFIED
        let onlineVerdict = await firewall.verifyAgainstPublicRegistries(entry: lecunBadORCID, session: replay)
        #expect(onlineVerdict.firewallClass == .verified)
        let onlineJSON = try encodeVerdictJSONObject(onlineVerdict)
        #expect(onlineJSON["insertable"] as? Bool == true)
    }

    @Test("M1 item 1: injected disconnect, timeout, 429, 500, and malformed 200 JSON return UNVERIFIED with corresponding reason codes")
    func m1Stage03InjectedFailuresReturnUnverifiedWithExactReasonCodes() async throws {
        let firewall = CitationVerificationFirewall(rateLimiter: RegistryRateLimiter(clock: .immediate))
        let entry = BibliographyEntry(
            citeKey: "lecun2015",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )

        let cases: [(String, ClosureRegistrySession)] = [
            ("transport_error", ClosureRegistrySession { _ in throw URLError(.notConnectedToInternet) }),
            ("timeout", ClosureRegistrySession { _ in throw URLError(.timedOut) }),
            ("rate_limited", ClosureRegistrySession { _ in RegistryHTTPResponse(statusCode: 429, body: Data("too many".utf8)) }),
            ("server_error", ClosureRegistrySession { _ in RegistryHTTPResponse(statusCode: 500, body: Data("boom".utf8)) }),
            ("unparseable", ClosureRegistrySession { _ in RegistryHTTPResponse(statusCode: 200, body: Data("{corrupt_json".utf8)) })
        ]

        for (expectedReason, session) in cases {
            let verdict = await firewall.verifyAgainstPublicRegistries(entry: entry, session: session)
            #expect(verdict.firewallClass == .unverified, "Expected UNVERIFIED for \(expectedReason)")
            let json = try encodeVerdictJSONObject(verdict)
            #expect(json["insertable"] as? Bool == false)
            let reasons = (json["reasons"] as? [String]) ?? []
            #expect(reasons == [expectedReason], "Expected [\(expectedReason)], got \(reasons)")
        }
    }

    @Test("M1 item 2: 'and others' author truncation, untruncated author count mismatch, and 1-year vs >=2-year drift notes on recorded fixtures")
    func m1Stage03AuthorTruncationCountAndYearDriftRules() async throws {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall()

        // 1. `and others` truncation on 5-author FlashAttention arXiv record -> VERIFIED
        let truncatedBib = """
        @inproceedings{dao2022_etal,
          author        = {Dao, Tri and others},
          title         = {FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness},
          booktitle     = {NeurIPS},
          year          = {2022},
          eprint        = {2205.14135},
          archivePrefix = {arXiv}
        }
        """
        let truncatedEntry = try #require(try BibTeXCodec().parse(truncatedBib).first)
        let vTruncated = await firewall.verifyAgainstPublicRegistries(entry: truncatedEntry, session: replay)
        #expect(vTruncated.firewallClass == .verified)
        #expect(vTruncated.insertable == true)

        // 2. Untruncated 1-author list on 5-author FlashAttention record -> DRIFT (authorCount 1 vs 5)
        let untruncatedOneAuthor = BibliographyEntry(
            citeKey: "dao2022_missing_coauthors",
            kind: .inproceedings,
            title: "FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness",
            authors: [BibAuthor(givenName: "Tri", familyName: "Dao")],
            year: 2022,
            arxivID: "2205.14135"
        )
        let vCountMismatch = await firewall.verifyAgainstPublicRegistries(entry: untruncatedOneAuthor, session: replay)
        #expect(vCountMismatch.firewallClass == .drift)
        #expect(vCountMismatch.reasons.contains("author_count_mismatch"))
        #expect(vCountMismatch.fields.contains { $0.field == "authorCount" && $0.localValue == "1" && $0.remoteValue == "5" })

        // 3. Year off by 1 on LeCun 2015 -> DRIFT with online-first vs. print-issue notice (warning)
        let yearOffBy1 = BibliographyEntry(
            citeKey: "lecun_year_2014",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2014,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )
        let vYear1 = await firewall.verifyAgainstPublicRegistries(entry: yearOffBy1, session: replay)
        #expect(vYear1.firewallClass == .drift)
        #expect(vYear1.reasons.contains("year_diff_1"))
        let yr1Field = try #require(vYear1.fields.first { $0.field == "year" })
        #expect(yr1Field.severity == "warning")
        #expect((yr1Field.note ?? "").contains(CitationAuditWording.yearOnlineVsPrintNotice))

        // 4. Year off by >= 2 on LeCun 2015 -> DRIFT marked as error
        let yearOffBy3 = BibliographyEntry(
            citeKey: "lecun_year_2012",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2012,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )
        let vYear3 = await firewall.verifyAgainstPublicRegistries(entry: yearOffBy3, session: replay)
        #expect(vYear3.firewallClass == .drift)
        #expect(vYear3.reasons.contains("year_mismatch"))
        let yr3Field = try #require(vYear3.fields.first { $0.field == "year" })
        #expect(yr3Field.severity == "error")
    }

    // MARK: - 10. M1 Stage 04 DOI Lookup Order, doi.org Handle & Retraction Tests

    @Test("M1 item 3 (Stage 04): fabricated DOI with real prefix + fake suffix queries doi.org handle + Crossref search and returns NOT_FOUND without not_found_in_registries")
    func m1Stage04FabricatedDOIVerifiesViaDOIHandleAndRemovesNotFoundInRegistries() async throws {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall()

        let fabricated = BibliographyEntry(
            citeKey: "fake_nonsentinel",
            kind: .article,
            title: "Quantum Gradient Descent in Biological Neural Networks",
            authors: [
                BibAuthor(givenName: "Eleanor", familyName: "Whitfield"),
                BibAuthor(givenName: "Raj", familyName: "Patel")
            ],
            year: 2025,
            venue: "Nature Machine Intelligence",
            doi: "10.1038/fake.2026.99999"
        )

        let verdict = await firewall.verifyAgainstPublicRegistries(entry: fabricated, session: replay)
        #expect(verdict.firewallClass == .notFound)
        #expect(verdict.insertable == false)
        #expect(!verdict.reasons.contains("not_found_in_registries"))
        #expect(verdict.reasons == ["doi_not_registered"])
        #expect(verdict.auditNote.contains("doi.org"))
        #expect(verdict.auditNote.contains("not registered"))
        #expect(verdict.sources.contains {
            $0.source == "doi.org" && $0.url == "https://doi.org/api/handles/10.1038/fake.2026.99999"
        })
        #expect(verdict.sources.contains {
            $0.source == "Crossref" && $0.url.contains("query.bibliographic=") && $0.url.contains("rows=5")
        })
    }

    @Test("M1 item 3 (Stage 04): real publication paired with unregistered DOI is upgraded to DRIFT with true remote DOI in fields")
    func m1Stage04RealPaperWithUnregisteredDOIRecoversTrueDOIViaBibliographicSearchAsDrift() async throws {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall()

        let typoDOIEntry = BibliographyEntry(
            citeKey: "lstm_wrong_doi",
            kind: .article,
            title: "Long Short-Term Memory",
            authors: [
                BibAuthor(givenName: "Sepp", familyName: "Hochreiter"),
                BibAuthor(givenName: "Jürgen", familyName: "Schmidhuber")
            ],
            year: 1997,
            venue: "Neural Computation",
            doi: "10.1162/neco.1997.99999"
        )

        let verdict = await firewall.verifyAgainstPublicRegistries(entry: typoDOIEntry, session: replay)
        #expect(verdict.firewallClass == .drift)
        #expect(verdict.insertable == false)
        #expect(verdict.sources.contains {
            $0.source == "doi.org" && $0.url == "https://doi.org/api/handles/10.1162/neco.1997.99999"
        })
        #expect(verdict.sources.contains {
            $0.source == "Crossref" && $0.url.contains("query.bibliographic=") && $0.url.contains("rows=5")
        })
        let doiField = try #require(verdict.fields.first { $0.field == "doi" })
        #expect(doiField.localValue == "10.1162/neco.1997.99999")
        #expect(doiField.remoteValue == "10.1162/neco.1997.9.8.1735")
        #expect(doiField.source == "Crossref")
    }

    @Test("M1 item 3 (Stage 04): unregistered DataCite-prefix DOI 10.4230/LIPIcs.ICALP.2015.1 (doi.org responseCode 100) returns NOT_FOUND")
    func m1Stage04UnregisteredDataCitePrefixDOIReturnsNotFoundViaDOIHandle() async throws {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall()

        let unregisteredDataCiteEntry = BibliographyEntry(
            citeKey: "lipics_icalp_2015",
            kind: .inproceedings,
            title: "ICALP 2015 Frontmatter",
            authors: [BibAuthor(givenName: "Magnús M.", familyName: "Halldórsson")],
            year: 2015,
            venue: "LIPIcs",
            doi: "10.4230/LIPIcs.ICALP.2015.1"
        )

        let verdict = await firewall.verifyAgainstPublicRegistries(entry: unregisteredDataCiteEntry, session: replay)
        #expect(verdict.firewallClass == .notFound)
        #expect(verdict.insertable == false)
        #expect(!verdict.reasons.contains("not_found_in_registries"))
        #expect(verdict.reasons == ["doi_not_registered"])
        #expect(verdict.auditNote.contains("doi.org"))
        #expect(verdict.auditNote.contains("not registered"))
        #expect(verdict.sources.count == 4)
        #expect(verdict.sources.contains {
            $0.source == "doi.org"
                && $0.url == "https://doi.org/api/handles/10.4230/lipics.icalp.2015.1"
                && $0.status == 404
        })
        #expect(verdict.sources.contains {
            $0.source == "Crossref" && $0.url.contains("query.bibliographic=") && $0.status == 200
        })
    }

    @Test("M1 item 3 (Stage 04): real CNKI/ISTIC-registered DOI missing from Crossref and OpenAlex returns UNVERIFIED with registered_no_metadata")
    func m1Stage04DataCiteRegisteredDOIWithoutMetadataReturnsUnverifiedRegisteredNoMetadata() async throws {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall()

        let registeredNoMetadataEntry = BibliographyEntry(
            citeKey: "yang2024jos",
            kind: .article,
            title: "Deep Learning Based Code Generation Methods: Literature Review",
            authors: [
                BibAuthor(givenName: "Zezhou", familyName: "Yang"),
                BibAuthor(givenName: "Sirong", familyName: "Chen"),
                BibAuthor(givenName: "Cuiyun", familyName: "Gao"),
                BibAuthor(givenName: "Zhenhao", familyName: "Li"),
                BibAuthor(givenName: "Ge", familyName: "Li"),
                BibAuthor(givenName: "Michael", familyName: "Lyu")
            ],
            year: 2024,
            venue: "Journal of Software",
            doi: "10.13328/j.cnki.jos.006981"
        )

        let verdict = await firewall.verifyAgainstPublicRegistries(entry: registeredNoMetadataEntry, session: replay)
        #expect(verdict.firewallClass == .unverified)
        #expect(verdict.insertable == false)
        #expect(verdict.reasons == [CitationUnverifiedReasonCode.registeredNoMetadata.rawValue])
        #expect(verdict.sources.count == 3)
        #expect(verdict.sources.contains {
            $0.source == "doi.org"
                && $0.url == "https://doi.org/api/handles/10.13328/j.cnki.jos.006981"
                && $0.status == 200
        })
    }

    @Test("M1 item 1 & 3 (Stage 04): injected doi.org disconnect, timeout, 500, 503, handle error code 2, 429, and corrupt JSON return UNVERIFIED and never NOT_FOUND")
    func m1Stage04InjectedDOIHandleFailuresReturnUnverifiedNeverNotFound() async throws {
        let firewall = CitationVerificationFirewall(rateLimiter: RegistryRateLimiter(clock: .immediate))
        let entry = BibliographyEntry(
            citeKey: "doi_handle_fail_probe",
            kind: .article,
            title: "Synthetic Probe Entry for Handle Failure Modes",
            authors: [BibAuthor(givenName: "Ada", familyName: "Lovelace")],
            year: 2024,
            venue: "Journal of Probes",
            doi: "10.1038/probe.2024.99999"
        )

        let failureModes: [(String, @Sendable (URLRequest) async throws -> RegistryHTTPResponse)] = [
            ("transport_error", { req in
                if req.url?.host == "doi.org" {
                    throw URLError(.notConnectedToInternet)
                }
                return RegistryHTTPResponse(statusCode: 404, body: Data("not found".utf8))
            }),
            ("timeout", { req in
                if req.url?.host == "doi.org" {
                    throw URLError(.timedOut)
                }
                return RegistryHTTPResponse(statusCode: 404, body: Data("not found".utf8))
            }),
            ("server_error", { req in
                if req.url?.host == "doi.org" {
                    return RegistryHTTPResponse(statusCode: 500, body: Data("internal error".utf8))
                }
                return RegistryHTTPResponse(statusCode: 404, body: Data("not found".utf8))
            }),
            ("rate_limited", { req in
                if req.url?.host == "doi.org" {
                    return RegistryHTTPResponse(statusCode: 503, body: Data("service unavailable".utf8))
                }
                return RegistryHTTPResponse(statusCode: 404, body: Data("not found".utf8))
            }),
            ("server_error", { req in
                if req.url?.host == "doi.org" {
                    return RegistryHTTPResponse(statusCode: 200, body: Data("{\"responseCode\":2,\"handle\":\"10.1038/probe.2024.99999\"}".utf8))
                }
                return RegistryHTTPResponse(statusCode: 404, body: Data("not found".utf8))
            }),
            ("rate_limited", { req in
                if req.url?.host == "doi.org" {
                    return RegistryHTTPResponse(statusCode: 429, body: Data("slow down".utf8))
                }
                return RegistryHTTPResponse(statusCode: 404, body: Data("not found".utf8))
            }),
            ("unparseable", { req in
                if req.url?.host == "doi.org" {
                    return RegistryHTTPResponse(statusCode: 404, body: Data("plain text 404 without handle json".utf8))
                }
                return RegistryHTTPResponse(statusCode: 404, body: Data("not found".utf8))
            }),
            ("unparseable", { req in
                if req.url?.host == "doi.org" {
                    return RegistryHTTPResponse(statusCode: 200, body: Data("{corrupt-json".utf8))
                }
                return RegistryHTTPResponse(statusCode: 404, body: Data("not found".utf8))
            })
        ]

        for (expectedReason, handler) in failureModes {
            let verdict = await firewall.verifyAgainstPublicRegistries(
                entry: entry,
                session: ClosureRegistrySession(handler)
            )
            #expect(verdict.firewallClass == .unverified, "Expected UNVERIFIED when doi.org fails with \(expectedReason), got \(verdict.firewallClass)")
            #expect(verdict.firewallClass != .notFound)
            #expect(verdict.insertable == false)
            #expect(verdict.reasons == [expectedReason], "Expected [\(expectedReason)], got \(verdict.reasons)")
            #expect(verdict.sources.contains { $0.source == "doi.org" })
        }
    }

    @Test("M1 item 2 & 3 (Stage 04): Wakefield without built-in list, Séralini 2012, OpenAlex cross-check, and RETRACTED: title prefix")
    func m1Stage04RetractionChecksWakefieldWithoutBuiltInListSeraliniOpenAlexCrossCheckAndRetractedPrefix() async throws {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let defaultFirewall = CitationVerificationFirewall()

        let wakefield = BibliographyEntry(
            citeKey: "retracted_wakefield",
            kind: .article,
            title: "Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children",
            authors: [
                BibAuthor(givenName: "AJ", familyName: "Wakefield"),
                BibAuthor(givenName: "", familyName: "others")
            ],
            year: 1998,
            venue: "The Lancet",
            doi: "10.1016/S0140-6736(97)11096-0"
        )

        // Default offline check still honors built-in list and states "built-in list, incomplete"
        let offlineWakefield = defaultFirewall.evaluate(wakefield)
        #expect(offlineWakefield.firewallClass == .retracted)
        #expect(offlineWakefield.reasons == ["retracted_builtin_list"])
        #expect(offlineWakefield.auditNote.contains(CitationAuditWording.builtInRetractionListNotice))

        // With built-in retraction list disabled, Wakefield is UNVERIFIED offline, yet STILL RETRACTED online from upstream fields
        let noBuiltInFirewall = CitationVerificationFirewall(includeBuiltInRetractedDOIs: false)
        #expect(noBuiltInFirewall.evaluate(wakefield).firewallClass == .unverified)

        let wakefieldWithoutBuiltIn = await noBuiltInFirewall.verifyAgainstPublicRegistries(entry: wakefield, session: replay)
        #expect(wakefieldWithoutBuiltIn.firewallClass == .retracted)
        #expect(wakefieldWithoutBuiltIn.firewallClass != .drift)
        #expect(wakefieldWithoutBuiltIn.fields.isEmpty)
        #expect(!wakefieldWithoutBuiltIn.auditNote.contains(CitationAuditWording.builtInRetractionListNotice))
        #expect(wakefieldWithoutBuiltIn.reasons == ["retracted_crossref", "retracted_openalex"])
        #expect(wakefieldWithoutBuiltIn.auditNote.contains("Crossref"))
        #expect(wakefieldWithoutBuiltIn.auditNote.contains("updated-by"))
        #expect(wakefieldWithoutBuiltIn.auditNote.contains("OpenAlex"))
        #expect(wakefieldWithoutBuiltIn.auditNote.contains("is_retracted"))
        #expect(wakefieldWithoutBuiltIn.sources.contains { $0.source == "Crossref" && $0.status == 200 })
        #expect(wakefieldWithoutBuiltIn.sources.contains { $0.source == "OpenAlex" && $0.status == 200 })

        // Default firewall online check also cross-checks OpenAlex single-work after Crossref 200 and names upstream source + field
        let onlineWakefield = await defaultFirewall.verifyAgainstPublicRegistries(entry: wakefield, session: replay)
        #expect(onlineWakefield.firewallClass == .retracted)
        #expect(onlineWakefield.firewallClass != .drift)
        #expect(onlineWakefield.fields.isEmpty)
        #expect(!onlineWakefield.auditNote.contains(CitationAuditWording.builtInRetractionListNotice))
        #expect(onlineWakefield.auditNote.contains("Crossref"))
        #expect(onlineWakefield.auditNote.contains("updated-by"))
        #expect(onlineWakefield.auditNote.contains("OpenAlex"))
        #expect(onlineWakefield.auditNote.contains("is_retracted"))
        #expect(onlineWakefield.sources.contains { $0.source == "Crossref" && $0.status == 200 })
        #expect(onlineWakefield.sources.contains { $0.source == "OpenAlex" && $0.status == 200 })

        // Séralini 2012 (not in built-in list; upstream Crossref title starts with "RETRACTED:") -> RETRACTED, not DRIFT
        let seralini = BibliographyEntry(
            citeKey: "retracted_seralini",
            kind: .article,
            title: "Long term toxicity of a Roundup herbicide and a Roundup-tolerant genetically modified maize",
            authors: [
                BibAuthor(givenName: "Gilles-Eric", familyName: "Séralini"),
                BibAuthor(givenName: "", familyName: "others")
            ],
            year: 2012,
            venue: "Food and Chemical Toxicology",
            doi: "10.1016/j.fct.2012.08.005"
        )
        #expect(defaultFirewall.evaluate(seralini).firewallClass == .unverified)

        let onlineSeralini = await defaultFirewall.verifyAgainstPublicRegistries(entry: seralini, session: replay)
        #expect(onlineSeralini.firewallClass == .retracted)
        #expect(onlineSeralini.firewallClass != .drift)
        #expect(onlineSeralini.fields.isEmpty)
        #expect(onlineSeralini.auditNote.contains("Crossref"))
        #expect(onlineSeralini.auditNote.contains("OpenAlex"))
        #expect(onlineSeralini.auditNote.contains("is_retracted"))
        #expect(onlineSeralini.sources.contains { $0.source == "Crossref" && $0.status == 200 })
        #expect(onlineSeralini.sources.contains { $0.source == "OpenAlex" && $0.status == 200 })

        // Upstream "RETRACTED:" title prefix never produces a title mismatch discrepancy
        let titleCheck = defaultFirewall.compareTitle(
            localTitle: wakefield.title,
            remoteTitle: "RETRACTED: Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children",
            sourceName: "Crossref"
        )
        #expect(titleCheck.discrepancy == nil)
        #expect(titleCheck.reason == nil)
    }

    // MARK: - 11. M1 Stage 05 arXiv, PubMed & Identifierless Search Tests (TDD)

    @Test("M1 item 3 (Stage 05): arXiv parses totalResults and <entry> independent of HTTP status, verifies 1706.03762, and flags wrong title as DRIFT")
    func m1Stage05ArXivTotalResultsParsingStatusIndependenceAndDrift() async throws {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall()
        let vaswaniAuthors = [
            BibAuthor(givenName: "Ashish", familyName: "Vaswani"),
            BibAuthor(givenName: "Noam", familyName: "Shazeer"),
            BibAuthor(givenName: "Niki", familyName: "Parmar"),
            BibAuthor(givenName: "Jakob", familyName: "Uszkoreit"),
            BibAuthor(givenName: "Llion", familyName: "Jones"),
            BibAuthor(givenName: "Aidan N.", familyName: "Gomez"),
            BibAuthor(givenName: "Lukasz", familyName: "Kaiser"),
            BibAuthor(givenName: "Illia", familyName: "Polosukhin")
        ]

        // 1. Real arXiv ID 1706.03762 (without DOI) -> VERIFIED from recorded Atom feed
        let cleanArXiv = BibliographyEntry(
            citeKey: "vaswani2017_arxiv",
            kind: .misc,
            title: "Attention Is All You Need",
            authors: vaswaniAuthors,
            year: 2017,
            arxivID: "1706.03762"
        )
        let vClean = await firewall.verifyAgainstPublicRegistries(entry: cleanArXiv, session: replay)
        #expect(vClean.firewallClass == .verified)
        #expect(vClean.insertable == true)
        #expect(vClean.sources.contains { $0.source == "arXiv" && $0.status == 200 })

        // 2. arXiv-only entry with wrong title -> DRIFT
        let wrongTitleArXiv = BibliographyEntry(
            citeKey: "vaswani2017_wrong_title",
            kind: .misc,
            title: "Attention Is Completely Optional for Sequence Transduction",
            authors: vaswaniAuthors,
            year: 2017,
            arxivID: "1706.03762"
        )
        let vDrift = await firewall.verifyAgainstPublicRegistries(entry: wrongTitleArXiv, session: replay)
        #expect(vDrift.firewallClass == .drift)
        #expect(vDrift.insertable == false)
        #expect(vDrift.fields.contains { $0.field == "title" && $0.remoteValue == "Attention Is All You Need" })

        // 3. Recorded nonexistent arXiv ID 2401.99999 (HTTP 200 with <opensearch:totalResults>0</opensearch:totalResults>) -> NOT_FOUND
        let nonexistentEntry = BibliographyEntry(
            citeKey: "arxiv_nonexistent",
            kind: .misc,
            title: "On Analytical Engines for Nonexistent Preprints",
            authors: [BibAuthor(givenName: "Ada", familyName: "Lovelace")],
            year: 2024,
            arxivID: "2401.99999"
        )
        let vMissing = await firewall.verifyAgainstPublicRegistries(entry: nonexistentEntry, session: replay)
        #expect(vMissing.firewallClass == .notFound)
        #expect(vMissing.insertable == false)
        #expect(vMissing.reasons == ["arxiv_not_found"])
        #expect(vMissing.sources.contains { $0.source == "arXiv" && $0.status == 200 && $0.origin == .replay })
        #expect(vMissing.auditNote.contains("arXiv"))

        // 4. DataCite arXiv DOI 10.48550/arXiv.1706.03762 routes through arXiv API -> VERIFIED
        let dataCiteArXiv = BibliographyEntry(
            citeKey: "vaswani2017_datacite",
            kind: .misc,
            title: "Attention Is All You Need",
            authors: vaswaniAuthors,
            year: 2017,
            doi: "10.48550/arXiv.1706.03762"
        )
        let vDataCite = await firewall.verifyAgainstPublicRegistries(entry: dataCiteArXiv, session: replay)
        #expect(vDataCite.firewallClass == .verified)
        #expect(vDataCite.sources.map(\.source) == ["arXiv"])

        // 5. HTTP 404 with non-Atom HTML body MUST NOT be judged NOT_FOUND (must judge by totalResults & <entry>, not HTTP status)
        let html404Session = ClosureRegistrySession { _ in
            RegistryHTTPResponse(statusCode: 404, body: Data("<html><body>404 Gateway Not Found</body></html>".utf8))
        }
        let vHtml404 = await CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: .immediate)
        ).verifyAgainstPublicRegistries(entry: cleanArXiv, session: html404Session)
        #expect(vHtml404.firewallClass == .unverified)
        #expect(vHtml404.firewallClass != .notFound)
        #expect(vHtml404.reasons == [CitationUnverifiedReasonCode.unparseable.rawValue])
    }

    @Test("M1 item 3 (Stage 05): PubMed esummary replay verifies real PMID 26017312, flags nonexistent PMID 99999999 as NOT_FOUND, and flags Wakefield PMID 9500320 as RETRACTED")
    func m1Stage05PubMedSummaryReplayVerifiesRealFlagsNonexistentAndDetectsRetraction() async throws {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall(includeBuiltInRetractedDOIs: false)

        // 1. Real PMID 26017312 (Ito et al. 2015, Nature) -> VERIFIED
        let realPMID = BibliographyEntry(
            citeKey: "pmid_real_ito2015",
            kind: .article,
            title: "A prefrontal-thalamo-hippocampal circuit for goal-directed spatial navigation",
            authors: [
                BibAuthor(givenName: "Hiroshi T.", familyName: "Ito"),
                BibAuthor(givenName: "Sheng-Jia", familyName: "Zhang"),
                BibAuthor(givenName: "Menno P.", familyName: "Witter"),
                BibAuthor(givenName: "Edvard I.", familyName: "Moser"),
                BibAuthor(givenName: "May-Britt", familyName: "Moser")
            ],
            year: 2015,
            venue: "Nature",
            pmid: "26017312"
        )
        let vReal = await firewall.verifyAgainstPublicRegistries(entry: realPMID, session: replay)
        #expect(vReal.firewallClass == .verified)
        #expect(vReal.insertable == true)
        #expect(vReal.sources.count == 1)
        #expect(vReal.sources.first?.source == "PubMed")
        #expect(vReal.sources.first?.status == 200)
        #expect(vReal.sources.first?.origin == .replay)

        // 2. Nonexistent PMID 99999999 (HTTP 200 with result[pmid].error) -> NOT_FOUND
        let missingPMID = BibliographyEntry(
            citeKey: "pmid_nonexistent",
            kind: .article,
            title: "Synthetic Nonexistent PubMed Record",
            authors: [BibAuthor(givenName: "Ada", familyName: "Lovelace")],
            year: 2024,
            venue: "Journal of Imaginary Medicine",
            pmid: "99999999"
        )
        let vMissing = await firewall.verifyAgainstPublicRegistries(entry: missingPMID, session: replay)
        #expect(vMissing.firewallClass == .notFound)
        #expect(vMissing.insertable == false)
        #expect(vMissing.reasons == ["pmid_not_found"])
        #expect(vMissing.auditNote.contains("PubMed"))

        // 3. Retracted PMID 9500320 (Wakefield 1998 without DOI, offline retraction list disabled) -> RETRACTED via PubMed pubtype
        let retractedPMID = BibliographyEntry(
            citeKey: "pmid_retracted_wakefield",
            kind: .article,
            title: "Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children",
            authors: [
                BibAuthor(givenName: "A. J.", familyName: "Wakefield"),
                BibAuthor(givenName: "", familyName: "others")
            ],
            year: 1998,
            venue: "The Lancet",
            pmid: "9500320"
        )
        let vRetracted = await firewall.verifyAgainstPublicRegistries(entry: retractedPMID, session: replay)
        #expect(vRetracted.firewallClass == .retracted)
        #expect(vRetracted.insertable == false)
        #expect(vRetracted.reasons == ["retracted_pubmed"])
        #expect(vRetracted.auditNote.contains("PubMed"))
        #expect(vRetracted.auditNote.contains("pubtype"))
    }

    @Test("M1 item 3 (Stage 05): dual DOI + arXiv entry queries both registries with DOI authoritative and cross-checks arXiv")
    func m1Stage05DualDOIAndArXivQueriesBothWithDOIAuthoritative() async throws {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall()
        let resnetAuthors = [
            BibAuthor(givenName: "Kaiming", familyName: "He"),
            BibAuthor(givenName: "Xiangyu", familyName: "Zhang"),
            BibAuthor(givenName: "Shaoqing", familyName: "Ren"),
            BibAuthor(givenName: "Jian", familyName: "Sun")
        ]

        // 1. Clean ResNet CVPR DOI (10.1109/CVPR.2016.90) + arXiv 1512.03385 -> VERIFIED, both paths queried
        let cleanResNet = BibliographyEntry(
            citeKey: "doi_and_arxiv_resnet",
            kind: .inproceedings,
            title: "Deep Residual Learning for Image Recognition",
            authors: resnetAuthors,
            year: 2016,
            venue: "2016 IEEE Conference on Computer Vision and Pattern Recognition (CVPR)",
            doi: "10.1109/CVPR.2016.90",
            arxivID: "1512.03385"
        )
        let vClean = await firewall.verifyAgainstPublicRegistries(entry: cleanResNet, session: replay)
        #expect(vClean.firewallClass == .verified)
        #expect(vClean.insertable == true)
        #expect(vClean.sources.map(\.source) == ["Crossref", "OpenAlex", "arXiv"])

        // 2. DOI is authoritative: year=2015 matches arXiv preprint year (2015) but NOT CVPR DOI record (2016) -> DRIFT from Crossref
        var preprintYearResNet = cleanResNet
        preprintYearResNet.year = 2015
        let vYearDrift = await firewall.verifyAgainstPublicRegistries(entry: preprintYearResNet, session: replay)
        #expect(vYearDrift.firewallClass == .drift)
        #expect(vYearDrift.insertable == false)
        #expect(vYearDrift.fields.contains { $0.field == "year" && $0.source == "Crossref" && $0.remoteValue == "2016" })

        // 3. Valid DOI paired with a different paper's arXiv ID (1706.03762) -> DRIFT (arxiv_mismatch)
        var wrongArXivResNet = cleanResNet
        wrongArXivResNet.arxivID = "1706.03762"
        let vMismatch = await firewall.verifyAgainstPublicRegistries(entry: wrongArXivResNet, session: replay)
        #expect(vMismatch.firewallClass == .drift)
        #expect(vMismatch.insertable == false)
        #expect(vMismatch.reasons.contains("arxiv_mismatch"))
        #expect(vMismatch.fields.contains { $0.field == "arxivID" })

        // 4. Valid DOI paired with nonexistent arXiv ID (2401.99999) -> DRIFT (arxiv_not_found), NOT NOT_FOUND because DOI exists
        var missingArXivResNet = cleanResNet
        missingArXivResNet.arxivID = "2401.99999"
        let vMissingArXiv = await firewall.verifyAgainstPublicRegistries(entry: missingArXivResNet, session: replay)
        #expect(vMissingArXiv.firewallClass == .drift)
        #expect(vMissingArXiv.insertable == false)
        #expect(vMissingArXiv.reasons.contains("arxiv_not_found"))
        #expect(vMissingArXiv.fields.contains { $0.field == "arxivID" })
    }

    @Test("M1 item 3 (Stage 05): identifierless search replay matches LeCun 2015 with remote DOI and returns no_match_in_search with honest explanation when absent in both sources")
    func m1Stage05IdentifierlessSearchReplaySingleMatchAndNoMatchInSearch() async throws {
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall()

        // 1. Single match in Crossref search -> VERIFIED, remote DOI 10.1038/nature14539 surfaced in fields, OpenAlex search not called
        let nodoiLeCun = BibliographyEntry(
            citeKey: "nodoi_real_lecun",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2015,
            venue: "Nature"
        )
        let vMatched = await firewall.verifyAgainstPublicRegistries(entry: nodoiLeCun, session: replay)
        #expect(vMatched.firewallClass == .verified)
        #expect(vMatched.insertable == true)
        #expect(vMatched.sources.map(\.source) == ["Crossref"])
        #expect(vMatched.fields.contains { $0.field == "doi" && $0.localValue.isEmpty && $0.remoteValue == "10.1038/nature14539" })
        #expect(vMatched.auditNote.contains("10.1038/nature14539"))

        // 2. Neither Crossref nor OpenAlex matches -> UNVERIFIED (no_match_in_search), stating both possibilities without "fabricated"/"编造"
        let nodoiUnpublished = BibliographyEntry(
            citeKey: "draft2024unverified",
            kind: .misc,
            title: "Unpublished Workshop Notes on Attention Kernels",
            authors: [BibAuthor(givenName: "Pat", familyName: "Taylor")],
            year: 2024
        )
        let vNoMatch = await firewall.verifyAgainstPublicRegistries(entry: nodoiUnpublished, session: replay)
        #expect(vNoMatch.firewallClass == .unverified)
        #expect(vNoMatch.insertable == false)
        #expect(vNoMatch.reasons == [CitationUnverifiedReasonCode.noMatchInSearch.rawValue])
        #expect(vNoMatch.sources.map(\.source) == ["Crossref", "OpenAlex"])
        #expect(vNoMatch.auditNote.contains("may not exist, or it may not be indexed"))
        #expect(!vNoMatch.auditNote.lowercased().contains("fabricated"))
        let zhNote = vNoMatch.auditedEntry.localizedFirewallAuditNote(.zhHans)
        #expect(zhNote.contains("可能文献并不存在，也可能是数据源没有收录"))
        #expect(!zhNote.contains("编造"))

        // 3. Fixtures/citations-m0-recheck.bib: real_nodoi (Knuth 1968, book reviews & 1978 edition excluded) and fake_nodoi are no_match_in_search, NOT offline
        let repoRoot = Self.recordedRegistryFixturesURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let recheckBib = try String(contentsOf: repoRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib"), encoding: .utf8)
        let recheckEntries = try BibTeXCodec().parse(recheckBib)
        for targetKey in ["real_nodoi", "fake_nodoi"] {
            let entry = try #require(recheckEntries.first { $0.citeKey == targetKey })
            let verdict = await firewall.verifyAgainstPublicRegistries(entry: entry, session: replay)
            #expect(verdict.firewallClass == .unverified)
            #expect(verdict.reasons == [CitationUnverifiedReasonCode.noMatchInSearch.rawValue])
            #expect(verdict.reasons != [CitationUnverifiedReasonCode.offline.rawValue])
            #expect(verdict.sources.map(\.source) == ["Crossref", "OpenAlex"])
        }
    }

    @Test("M1 item 3, 5 & 6 (Stage 05/06): unified RegistryRateLimiter enforces >= 3s spacing between arXiv requests via injectable RegistryClock without real sleep")
    func m1Stage05ArXivInjectableRateLimiterEnforcesThreeSecondSpacingWithoutRealSleep() async throws {
        final class MockClockState: @unchecked Sendable {
            private let lock = NSLock()
            var now: TimeInterval = 100.0
            var recordedSleeps: [TimeInterval] = []

            func currentTime() -> TimeInterval {
                lock.lock()
                defer { lock.unlock() }
                return now
            }

            func advance(_ delta: TimeInterval) {
                lock.lock()
                defer { lock.unlock() }
                now += delta
            }

            func recordSleep(_ seconds: TimeInterval) {
                lock.lock()
                defer { lock.unlock() }
                recordedSleeps.append(seconds)
                now += seconds
            }
        }

        let clockState = MockClockState()
        let clock = ClosureRegistryClock(
            now: { clockState.currentTime() },
            sleep: { seconds in clockState.recordSleep(seconds) }
        )
        let limiter = RegistryRateLimiter(clock: clock)
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall(rateLimiter: limiter)
        let entry = BibliographyEntry(
            citeKey: "vaswani2017_paced",
            kind: .misc,
            title: "Attention Is All You Need",
            authors: [
                BibAuthor(givenName: "Ashish", familyName: "Vaswani"),
                BibAuthor(givenName: "", familyName: "others")
            ],
            year: 2017,
            arxivID: "1706.03762"
        )

        let wallStart = ProcessInfo.processInfo.systemUptime
        // 1st arXiv call at t=100.0 -> 0s sleep
        _ = await firewall.verifyAgainstPublicRegistries(entry: entry, session: replay)
        // 2nd arXiv call 1.2s later at t=101.2 -> must sleep 1.8s (advancing mock clock to 103.0)
        clockState.advance(1.2)
        _ = await firewall.verifyAgainstPublicRegistries(entry: entry, session: replay)
        // 3rd arXiv call immediately at t=103.0 -> must sleep full 3.0s (advancing mock clock to 106.0)
        _ = await firewall.verifyAgainstPublicRegistries(entry: entry, session: replay)
        // 4th arXiv call 3.5s later at t=109.5 -> >=3.0s elapsed, 0s sleep
        clockState.advance(3.5)
        _ = await firewall.verifyAgainstPublicRegistries(entry: entry, session: replay)
        let wallElapsed = ProcessInfo.processInfo.systemUptime - wallStart

        #expect(wallElapsed < 1.0, "Unit test must never sleep real 3 seconds (took \(wallElapsed)s)")
        #expect(clockState.recordedSleeps.count == 2)
        if clockState.recordedSleeps.count == 2 {
            #expect(abs(clockState.recordedSleeps[0] - 1.8) < 0.001)
            #expect(abs(clockState.recordedSleeps[1] - 3.0) < 0.001)
        }
    }

    @Test("M1 item 1, 3 & 4 (Stage 05): injected disconnect, timeout, 500, 429, and corrupt 200 on arXiv, PubMed, and identifierless search return UNVERIFIED, never NOT_FOUND")
    func m1Stage05InjectedFailuresAcrossArXivPubMedAndSearchReturnUnverifiedNeverNotFound() async throws {
        // 8-digit PMID (e.g. 99999999) is syntactically valid so online PubMed esummary is queried
        #expect(ScholarlyIdentifierValidator.validatePMID("99999999").isValid)

        let firewall = CitationVerificationFirewall(rateLimiter: RegistryRateLimiter(clock: .immediate))
        let arxivEntry = BibliographyEntry(
            citeKey: "arxiv_fail_probe",
            kind: .misc,
            title: "Attention Is All You Need",
            authors: [BibAuthor(givenName: "Ashish", familyName: "Vaswani")],
            year: 2017,
            arxivID: "1706.03762"
        )
        let pmidEntry = BibliographyEntry(
            citeKey: "pmid_fail_probe",
            kind: .article,
            title: "A prefrontal-thalamo-hippocampal circuit for goal-directed spatial navigation",
            authors: [BibAuthor(givenName: "Hiroshi T.", familyName: "Ito")],
            year: 2015,
            venue: "Nature",
            pmid: "26017312"
        )
        let nodoiEntry = BibliographyEntry(
            citeKey: "nodoi_fail_probe",
            kind: .article,
            title: "Deep learning",
            authors: [BibAuthor(givenName: "Yann", familyName: "LeCun")],
            year: 2015,
            venue: "Nature"
        )

        let failureModes: [(String, @Sendable (URLRequest) async throws -> RegistryHTTPResponse)] = [
            ("transport_error", { _ in throw URLError(.notConnectedToInternet) }),
            ("timeout", { _ in throw URLError(.timedOut) }),
            ("server_error", { _ in RegistryHTTPResponse(statusCode: 500, body: Data("internal server error".utf8)) }),
            ("rate_limited", { _ in RegistryHTTPResponse(statusCode: 429, body: Data("too many requests".utf8)) }),
            ("unparseable", { _ in RegistryHTTPResponse(statusCode: 200, body: Data("<<<corrupt-payload".utf8)) })
        ]

        for target in [arxivEntry, pmidEntry, nodoiEntry] {
            for (expectedReason, handler) in failureModes {
                let verdict = await firewall.verifyAgainstPublicRegistries(
                    entry: target,
                    session: ClosureRegistrySession(handler)
                )
                #expect(
                    verdict.firewallClass == .unverified,
                    "Entry \(target.citeKey) under \(expectedReason) returned \(verdict.firewallClass)"
                )
                #expect(verdict.firewallClass != .notFound)
                #expect(verdict.insertable == false)
                #expect(
                    verdict.reasons == [expectedReason],
                    "Entry \(target.citeKey) expected [\(expectedReason)], got \(verdict.reasons)"
                )
                #expect(!verdict.sources.isEmpty)
            }
        }

        // Identifierless search where Crossref returns 200 (0 matches) and OpenAlex fails with 500 -> UNVERIFIED (server_error), NOT no_match_in_search
        let openAlex500AfterEmptyCrossref = ClosureRegistrySession { req in
            if req.url?.host == "api.crossref.org" {
                return RegistryHTTPResponse(statusCode: 200, body: Data("{\"status\":\"ok\",\"message\":{\"items\":[]}}".utf8))
            }
            return RegistryHTTPResponse(statusCode: 500, body: Data("openalex 500".utf8))
        }
        let partialSearchFail = await firewall.verifyAgainstPublicRegistries(
            entry: nodoiEntry,
            session: openAlex500AfterEmptyCrossref
        )
        #expect(partialSearchFail.firewallClass == .unverified)
        #expect(partialSearchFail.reasons == [CitationUnverifiedReasonCode.serverError.rawValue])
        #expect(partialSearchFail.sources.count == 2)
    }

    @Test("M1 item 3 (Stage 05, synthetic search response): identifierless search with >=2 equally matching candidates returns UNVERIFIED with reason ambiguous")
    func m1Stage05SyntheticSearchResponseAmbiguousIdentifierlessCandidatesReturnUnverifiedAmbiguous() async throws {
        let firewall = CitationVerificationFirewall(rateLimiter: RegistryRateLimiter(clock: .immediate))
        let entry = BibliographyEntry(
            citeKey: "ambiguous_nodoi",
            kind: .article,
            title: "On Computable Numbers",
            authors: [BibAuthor(givenName: "Alan", familyName: "Turing")],
            year: 1936
        )
        let tiedCrossrefSearchJSON = """
        {
          "status": "ok",
          "message": {
            "items": [
              {
                "DOI": "10.1112/plms/s2-42.1.230",
                "title": ["On Computable Numbers"],
                "author": [{"given": "Alan", "family": "Turing", "sequence": "first"}],
                "issued": {"date-parts": [[1936]]}
              },
              {
                "DOI": "10.2307/2268810",
                "title": ["On Computable Numbers"],
                "author": [{"given": "Alan", "family": "Turing", "sequence": "first"}],
                "issued": {"date-parts": [[1936]]}
              }
            ]
          }
        }
        """
        let crossrefTiedSession = ClosureRegistrySession { _ in
            RegistryHTTPResponse(statusCode: 200, body: Data(tiedCrossrefSearchJSON.utf8))
        }
        let vCrossrefTied = await firewall.verifyAgainstPublicRegistries(entry: entry, session: crossrefTiedSession)
        #expect(vCrossrefTied.firewallClass == .unverified)
        #expect(vCrossrefTied.insertable == false)
        #expect(vCrossrefTied.reasons == [CitationUnverifiedReasonCode.ambiguous.rawValue])

        let tiedOpenAlexSearchJSON = """
        {
          "results": [
            {
              "id": "https://openalex.org/W1",
              "doi": "https://doi.org/10.1112/plms/s2-42.1.230",
              "title": "On Computable Numbers",
              "publication_year": 1936,
              "authorships": [{"raw_author_name": "Alan Turing"}]
            },
            {
              "id": "https://openalex.org/W2",
              "doi": "https://doi.org/10.2307/2268810",
              "title": "On Computable Numbers",
              "publication_year": 1936,
              "authorships": [{"raw_author_name": "Alan Turing"}]
            }
          ]
        }
        """
        let openAlexTiedSession = ClosureRegistrySession { req in
            if req.url?.host == "api.crossref.org" {
                return RegistryHTTPResponse(statusCode: 200, body: Data("{\"status\":\"ok\",\"message\":{\"items\":[]}}".utf8))
            }
            return RegistryHTTPResponse(statusCode: 200, body: Data(tiedOpenAlexSearchJSON.utf8))
        }
        let vOpenAlexTied = await firewall.verifyAgainstPublicRegistries(entry: entry, session: openAlexTiedSession)
        #expect(vOpenAlexTied.firewallClass == .unverified)
        #expect(vOpenAlexTied.insertable == false)
        #expect(vOpenAlexTied.reasons == [CitationUnverifiedReasonCode.ambiguous.rawValue])
        #expect(vOpenAlexTied.sources.map(\.source) == ["Crossref", "OpenAlex"])
    }

    // MARK: - 12. M1 Stage 06 Rate Limiting, Retry, OpenAlex Budget & Injectable Clock Tests (TDD)

    @Test("M1 row 14 (Stage 06): 1st & 2nd 429 (Retry-After: 2) then 3rd 200 matches replay with [2.0, 2.0] sleeps; 4 consecutive 429s stop at 4 requests with UNVERIFIED rate_limited")
    func m1Stage06Row14RetryAfterAndFourConsecutive429sAnd5xxRetryPolicy() async throws {
        final class RecordedClock: @unchecked Sendable {
            private let lock = NSLock()
            var now: TimeInterval = 50.0
            var sleeps: [TimeInterval] = []

            func current() -> TimeInterval {
                lock.lock()
                defer { lock.unlock() }
                return now
            }

            func sleep(_ s: TimeInterval) {
                lock.lock()
                defer { lock.unlock() }
                sleeps.append(s)
                now += s
            }

            func reset() {
                lock.lock()
                defer { lock.unlock() }
                now = 50.0
                sleeps.removeAll()
            }
        }

        actor AttemptCounter {
            var total: Int = 0
            var byHost: [String: Int] = [:]
            func next(for host: String) -> Int {
                total += 1
                let n = (byHost[host] ?? 0) + 1
                byHost[host] = n
                return n
            }
        }

        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let lecunEntry = BibliographyEntry(
            citeKey: "lecun2015",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )
        let baselineReplayVerdict = await CitationVerificationFirewall().verifyAgainstPublicRegistries(
            entry: lecunEntry,
            session: replay
        )
        #expect(baselineReplayVerdict.firewallClass == .verified)

        // 1. Row 14a: 1st & 2nd attempt 429 (Retry-After: 2), 3rd attempt 200 from replay -> verdict matches replay, sleeps == [2.0, 2.0]
        let clockStateA = RecordedClock()
        let limiterA = RegistryRateLimiter(
            clock: ClosureRegistryClock(now: { clockStateA.current() }, sleep: { clockStateA.sleep($0) })
        )
        let counterA = AttemptCounter()
        let retryThen200Session = ClosureRegistrySession { req in
            let host = req.url?.host ?? ""
            let attempt = await counterA.next(for: host)
            if host == "api.crossref.org" && attempt <= 2 {
                return RegistryHTTPResponse(
                    statusCode: 429,
                    body: Data("Too Many Requests".utf8),
                    headers: ["Retry-After": "2"]
                )
            }
            return try await replay.send(req)
        }
        let wallStart = ProcessInfo.processInfo.systemUptime
        let retriedVerdict = await CitationVerificationFirewall(rateLimiter: limiterA).verifyAgainstPublicRegistries(
            entry: lecunEntry,
            session: retryThen200Session
        )
        let wallElapsed = ProcessInfo.processInfo.systemUptime - wallStart
        #expect(wallElapsed < 1.0, "Retry test must use injected clock without real sleep")
        #expect(retriedVerdict.firewallClass == baselineReplayVerdict.firewallClass)
        #expect(retriedVerdict.insertable == baselineReplayVerdict.insertable)
        #expect(retriedVerdict.reasons == baselineReplayVerdict.reasons)
        #expect(retriedVerdict.fields == baselineReplayVerdict.fields)
        #expect(await counterA.byHost["api.crossref.org"] == 3)
        #expect(clockStateA.sleeps == [2.0, 2.0])

        // 2. Row 14b: 4 consecutive 429s -> UNVERIFIED, reason rate_limited, total requests sent == 4 (without Retry-After -> [1, 2, 4] exponential backoff)
        let pmidEntry = BibliographyEntry(
            citeKey: "pmid_real_ito2015",
            kind: .article,
            title: "A prefrontal-thalamo-hippocampal circuit for goal-directed spatial navigation",
            authors: [
                BibAuthor(givenName: "Hiroshi T.", familyName: "Ito"),
                BibAuthor(givenName: "Sheng-Jia", familyName: "Zhang"),
                BibAuthor(givenName: "Menno P.", familyName: "Witter"),
                BibAuthor(givenName: "Edvard I.", familyName: "Moser"),
                BibAuthor(givenName: "May-Britt", familyName: "Moser")
            ],
            year: 2015,
            venue: "Nature",
            pmid: "26017312"
        )
        let clockStateB = RecordedClock()
        let limiterB = RegistryRateLimiter(
            clock: ClosureRegistryClock(now: { clockStateB.current() }, sleep: { clockStateB.sleep($0) })
        )
        let counterB = AttemptCounter()
        let four429Session = ClosureRegistrySession { req in
            let n = await counterB.next(for: req.url?.host ?? "")
            if n <= 4 {
                return RegistryHTTPResponse(statusCode: 429, body: Data("rate limited".utf8))
            }
            // Even if a 5th request would return 200, max 3 retries (4 attempts) must stop at 4!
            return try await replay.send(req)
        }
        let exhausted429 = await CitationVerificationFirewall(rateLimiter: limiterB).verifyAgainstPublicRegistries(
            entry: pmidEntry,
            session: four429Session
        )
        #expect(exhausted429.firewallClass == .unverified)
        #expect(exhausted429.insertable == false)
        #expect(exhausted429.reasons == [CitationUnverifiedReasonCode.rateLimited.rawValue])
        #expect(await counterB.total == 4)
        #expect(clockStateB.sleeps == [1.0, 2.0, 4.0])

        // 3. 503 with Retry-After > 60s caps Retry-After at 60s and after 4 attempts returns UNVERIFIED + rate_limited
        let clockState503 = RecordedClock()
        let limiter503 = RegistryRateLimiter(
            clock: ClosureRegistryClock(now: { clockState503.current() }, sleep: { clockState503.sleep($0) })
        )
        let counter503 = AttemptCounter()
        let four503Session = ClosureRegistrySession { req in
            _ = await counter503.next(for: req.url?.host ?? "")
            return RegistryHTTPResponse(
                statusCode: 503,
                body: Data("service unavailable".utf8),
                headers: ["Retry-After": "180"]
            )
        }
        let exhausted503 = await CitationVerificationFirewall(rateLimiter: limiter503).verifyAgainstPublicRegistries(
            entry: pmidEntry,
            session: four503Session
        )
        #expect(exhausted503.firewallClass == .unverified)
        #expect(exhausted503.reasons == [CitationUnverifiedReasonCode.rateLimited.rawValue])
        #expect(await counter503.total == 4)
        #expect(clockState503.sleeps == [60.0, 60.0, 60.0])

        // 4. Other 5xx (e.g. 500 / 502) retries exactly 1 time (2 total attempts):
        //    - persistent 500 -> 2 total requests, UNVERIFIED, server_error
        //    - transient 502 then 200 -> 2 total requests, VERIFIED
        let counter500 = AttemptCounter()
        let persistent500Verdict = await CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: .immediate)
        ).verifyAgainstPublicRegistries(
            entry: pmidEntry,
            session: ClosureRegistrySession { req in
                _ = await counter500.next(for: req.url?.host ?? "")
                return RegistryHTTPResponse(statusCode: 500, body: Data("internal error".utf8))
            }
        )
        #expect(persistent500Verdict.firewallClass == .unverified)
        #expect(persistent500Verdict.reasons == [CitationUnverifiedReasonCode.serverError.rawValue])
        #expect(await counter500.total == 2)

        let counter502 = AttemptCounter()
        let recovered502Verdict = await CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: .immediate)
        ).verifyAgainstPublicRegistries(
            entry: pmidEntry,
            session: ClosureRegistrySession { req in
                let n = await counter502.next(for: req.url?.host ?? "")
                if n == 1 {
                    return RegistryHTTPResponse(statusCode: 502, body: Data("bad gateway".utf8))
                }
                return try await replay.send(req)
            }
        )
        #expect(recovered502Verdict.firewallClass == .verified)
        #expect(await counter502.total == 2)
    }

    @Test("M1 item 6 (Stage 06): OpenAlex x-ratelimit-remaining < 10 halts subsequent OpenAlex searches in the run with UNVERIFIED budget_exhausted")
    func m1Stage06OpenAlexRemainingBelowTenSkipsSearchAndReturnsBudgetExhausted() async throws {
        actor RequestLog {
            var openAlexSearchCount: Int = 0
            var openAlexSingleWorkCount: Int = 0
            var crossrefSearchCount: Int = 0

            func record(_ url: URL?) {
                guard let url, let host = url.host else { return }
                if host == "api.openalex.org" {
                    if (url.query ?? "").contains("search=") {
                        openAlexSearchCount += 1
                    } else {
                        openAlexSingleWorkCount += 1
                    }
                } else if host == "api.crossref.org" && (url.query ?? "").contains("query.bibliographic=") {
                    crossrefSearchCount += 1
                }
            }
        }

        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let sharedRunLimiter = RegistryRateLimiter(clock: .immediate)
        let firewall = CitationVerificationFirewall(rateLimiter: sharedRunLimiter)
        let log = RequestLog()

        let session = ClosureRegistrySession { req in
            await log.record(req.url)
            let base = try await replay.send(req)
            // Simulate Entry 1's OpenAlex single-work response reporting x-ratelimit-remaining: 9 (< 10)
            if req.url?.host == "api.openalex.org" {
                var updatedHeaders = base.headers
                updatedHeaders["x-ratelimit-remaining"] = "9"
                return RegistryHTTPResponse(
                    statusCode: base.statusCode,
                    body: base.body,
                    headers: updatedHeaders,
                    origin: base.origin,
                    fetchedAt: base.fetchedAt
                )
            }
            return base
        }

        // Entry 1: DOI lookup succeeds, OpenAlex cross-check returns 200 with x-ratelimit-remaining: 9
        let doiEntry = BibliographyEntry(
            citeKey: "lecun2015",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )
        let v1 = await firewall.verifyAgainstPublicRegistries(entry: doiEntry, session: session)
        #expect(v1.firewallClass == .verified)
        #expect(await log.openAlexSingleWorkCount == 1)
        #expect(await log.openAlexSearchCount == 0)

        // Entry 2: Identifierless entry where Crossref search finds 0 matches -> needs OpenAlex search,
        // which MUST NOT be sent because x-ratelimit-remaining < 10 in this run!
        let nodoiEntry = BibliographyEntry(
            citeKey: "draft2024unverified",
            kind: .misc,
            title: "Unpublished Workshop Notes on Attention Kernels",
            authors: [BibAuthor(givenName: "Pat", familyName: "Taylor")],
            year: 2024
        )
        let v2 = await firewall.verifyAgainstPublicRegistries(entry: nodoiEntry, session: session)
        #expect(v2.firewallClass == .unverified)
        #expect(v2.insertable == false)
        #expect(v2.reasons == [CitationUnverifiedReasonCode.budgetExhausted.rawValue])
        #expect(await log.crossrefSearchCount == 1)
        #expect(await log.openAlexSearchCount == 0, "OpenAlex search must not be sent once x-ratelimit-remaining < 10")

        // Also verify direct OpenAlex 429 with x-ratelimit-remaining: 0 returns budget_exhausted immediately without retrying
        let directLog = RequestLog()
        let directBudgetFirewall = CitationVerificationFirewall(rateLimiter: RegistryRateLimiter(clock: .immediate))
        let directSession = ClosureRegistrySession { req in
            await directLog.record(req.url)
            if req.url?.host == "api.crossref.org" {
                return RegistryHTTPResponse(statusCode: 200, body: Data("{\"status\":\"ok\",\"message\":{\"items\":[]}}".utf8))
            }
            return RegistryHTTPResponse(
                statusCode: 429,
                body: Data("daily credit limit exceeded".utf8),
                headers: ["x-ratelimit-remaining": "0"]
            )
        }
        let vDirect = await directBudgetFirewall.verifyAgainstPublicRegistries(entry: nodoiEntry, session: directSession)
        #expect(vDirect.firewallClass == .unverified)
        #expect(vDirect.reasons == [CitationUnverifiedReasonCode.budgetExhausted.rawValue])
        #expect(await directLog.openAlexSearchCount == 1)
    }

    @Test("M1 item 6 (Stage 06): Crossref in-flight concurrency never exceeds 1, respects default 5/s & 1/s and dynamic rate-limit headers, and PubMed paces at 3/s")
    func m1Stage06CrossrefSingleInFlightDynamicHeadersAndPubMedThreePerSecondPacing() async throws {
        final class VirtualClock: @unchecked Sendable {
            private let lock = NSLock()
            var now: TimeInterval = 10.0
            var sleeps: [TimeInterval] = []

            func current() -> TimeInterval {
                lock.lock()
                defer { lock.unlock() }
                return now
            }

            func sleep(_ seconds: TimeInterval) {
                lock.lock()
                defer { lock.unlock() }
                sleeps.append(seconds)
                now += seconds
            }
        }

        actor ConcurrencyProbe {
            var currentCrossrefInFlight: Int = 0
            var maxCrossrefInFlight: Int = 0
            var completedCrossrefRequests: Int = 0

            func enterCrossref() {
                currentCrossrefInFlight += 1
                if currentCrossrefInFlight > maxCrossrefInFlight {
                    maxCrossrefInFlight = currentCrossrefInFlight
                }
            }

            func leaveCrossref() {
                currentCrossrefInFlight -= 1
                completedCrossrefRequests += 1
            }
        }

        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)

        // 1. Crossref concurrency: 6 concurrent tasks -> max in-flight on api.crossref.org is strictly 1
        let probe = ConcurrencyProbe()
        let concurrentClock = VirtualClock()
        let concurrentLimiter = RegistryRateLimiter(
            clock: ClosureRegistryClock(now: { concurrentClock.current() }, sleep: { concurrentClock.sleep($0) })
        )
        let concurrentFirewall = CitationVerificationFirewall(rateLimiter: concurrentLimiter)
        let concurrentSession = ClosureRegistrySession { req in
            let isCrossref = (req.url?.host == "api.crossref.org")
            if isCrossref {
                await probe.enterCrossref()
            }
            // Yield across suspension points so any overlapping Crossref request would be caught
            await Task.yield()
            await Task.yield()
            let resp = try await replay.send(req)
            if isCrossref {
                await probe.leaveCrossref()
            }
            return resp
        }

        let lecunEntry = BibliographyEntry(
            citeKey: "lecun2015",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )

        await withTaskGroup(of: CitationFirewallEntryVerdict.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await concurrentFirewall.verifyAgainstPublicRegistries(entry: lecunEntry, session: concurrentSession)
                }
            }
            for await verdict in group {
                #expect(verdict.firewallClass == .verified)
            }
        }
        #expect(await probe.completedCrossrefRequests == 6)
        #expect(await probe.maxCrossrefInFlight == 1)
        #expect(await concurrentLimiter.maxObservedCrossrefInFlight == 1)

        // 2. Crossref default intervals (0.2s single-work, 1.0s search when headers absent) + dynamic header update (2 per 1s -> 0.5s)
        let headerClock = VirtualClock()
        let headerLimiter = RegistryRateLimiter(
            clock: ClosureRegistryClock(now: { headerClock.current() }, sleep: { headerClock.sleep($0) })
        )
        let singleURL = try #require(RegistryURLBuilder.crossrefWorkURL(doi: "10.1038/nature14539"))
        let searchURL = try #require(RegistryURLBuilder.crossrefBibliographicSearchURL(query: "Deep learning LeCun 2015", rows: 5))

        // Call 1 (single, no rate headers) -> 0s sleep
        _ = try await headerLimiter.send(
            URLRequest(url: singleURL),
            source: "Crossref",
            using: ClosureRegistrySession { _ in RegistryHTTPResponse(statusCode: 200, body: Data("{}".utf8)) }
        )
        // Call 2 (single, uses default 5/s = 0.2s, returns headers x-rate-limit-limit: 2, x-rate-limit-interval: 1s -> next interval 0.5s)
        _ = try await headerLimiter.send(
            URLRequest(url: singleURL),
            source: "Crossref",
            using: ClosureRegistrySession { _ in
                RegistryHTTPResponse(
                    statusCode: 200,
                    body: Data("{}".utf8),
                    headers: ["x-rate-limit-limit": "2", "x-rate-limit-interval": "1s"]
                )
            }
        )
        // Call 3 (single, uses updated 0.5s interval)
        _ = try await headerLimiter.send(
            URLRequest(url: singleURL),
            source: "Crossref",
            using: ClosureRegistrySession { _ in RegistryHTTPResponse(statusCode: 200, body: Data("{}".utf8)) }
        )
        // Call 4 (search, no search headers yet -> default 1.0s interval)
        _ = try await headerLimiter.send(
            URLRequest(url: searchURL),
            source: "Crossref",
            using: ClosureRegistrySession { _ in RegistryHTTPResponse(statusCode: 200, body: Data("{}".utf8)) }
        )
        // Call 5 (search again -> default 1.0s interval)
        _ = try await headerLimiter.send(
            URLRequest(url: searchURL),
            source: "Crossref",
            using: ClosureRegistrySession { _ in RegistryHTTPResponse(statusCode: 200, body: Data("{}".utf8)) }
        )
        #expect(headerClock.sleeps.count == 4)
        if headerClock.sleeps.count == 4 {
            #expect(abs(headerClock.sleeps[0] - 0.2) < 0.001)
            #expect(abs(headerClock.sleeps[1] - 0.5) < 0.001)
            #expect(abs(headerClock.sleeps[2] - 1.0) < 0.001)
            #expect(abs(headerClock.sleeps[3] - 1.0) < 0.001)
        }

        // 3. PubMed pacing: max 3 req/s (1/3 s between consecutive requests)
        let pubmedClock = VirtualClock()
        let pubmedLimiter = RegistryRateLimiter(
            clock: ClosureRegistryClock(now: { pubmedClock.current() }, sleep: { pubmedClock.sleep($0) })
        )
        let pubmedURL = try #require(RegistryURLBuilder.pubMedSummaryURL(pmid: "26017312"))
        for _ in 0..<3 {
            _ = try await pubmedLimiter.send(
                URLRequest(url: pubmedURL),
                source: "PubMed",
                using: replay
            )
        }
        #expect(pubmedClock.sleeps.count == 2)
        for s in pubmedClock.sleeps {
            #expect(abs(s - (1.0 / 3.0)) < 0.001)
        }
    }

    // MARK: - M1 Item 7 (Stage 07): SQLite Response Cache, TTLs, Key Normalization, Hygiene & Resilience

    @Test("M1 item 7 (Stage 07): running the 22 recorded entries twice with the same SQLite cache sends 0 requests for all 19 cacheable entries on run 2, preserves identical verdicts, and records cache origin + UTC date")
    func m1Stage07CacheReplayRunTwiceZeroRequestsIdenticalVerdictsAndProvenance() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-stage07-twice-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let recheckRaw = try String(
            contentsOf: repoRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib"),
            encoding: .utf8
        )
        let stage05Raw = try String(
            contentsOf: repoRoot.appendingPathComponent("Tests/Fixtures/registry-sources/stage05-arxiv-pmid-search.bib"),
            encoding: .utf8
        )
        let entries = try BibTeXCodec().parseDocument(recheckRaw + "\n" + stage05Raw).entries
        #expect(entries.count == 22)

        let fixedDate = Date(timeIntervalSince1970: 1_794_817_800) // 2026-11-16T08:30:00Z
        let clock = ClosureRegistryClock(
            now: { 0.0 },
            currentDate: { fixedDate },
            sleep: { _ in }
        )

        let dbURL = tempDir.appendingPathComponent("caches/registry.sqlite")
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)

        actor SessionCounter {
            var count: Int = 0
            func increment() { count += 1 }
            func resetAndRead() -> Int {
                let current = count
                count = 0
                return current
            }
        }

        final class EventBag: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [RegistryRequestTelemetryEvent] = []
            func append(_ e: RegistryRequestTelemetryEvent) {
                lock.lock()
                items.append(e)
                lock.unlock()
            }
            func drain() -> [RegistryRequestTelemetryEvent] {
                lock.lock()
                defer { lock.unlock() }
                let copy = items
                items.removeAll()
                return copy
            }
        }

        let counter = SessionCounter()
        let countingSession = ClosureRegistrySession { req in
            await counter.increment()
            return try await replay.send(req)
        }

        // Run 1: warms the SQLite cache
        let cache1 = RegistryResponseCache(fileURL: dbURL, clock: clock)
        let firewall1 = CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: clock),
            cache: cache1
        )
        var run1Verdicts: [String: CitationFirewallEntryVerdict] = [:]
        for entry in entries {
            run1Verdicts[entry.citeKey] = await firewall1.verifyAgainstPublicRegistries(entry: entry, session: countingSession)
        }
        let run1TotalRequests = await counter.resetAndRead()
        #expect(run1TotalRequests > 30)
        #expect(FileManager.default.fileExists(atPath: dbURL.path))

        // Run 2: opens a brand-new RegistryResponseCache on the same SQLite file
        let events = EventBag()
        final class SleepCounter: @unchecked Sendable {
            private let lock = NSLock()
            var sleeps: Int = 0
            func record() {
                lock.lock()
                sleeps += 1
                lock.unlock()
            }
        }
        let sleepCounter = SleepCounter()
        let run2Clock = ClosureRegistryClock(
            now: { 100.0 },
            currentDate: { fixedDate },
            sleep: { _ in sleepCounter.record() }
        )
        let cache2 = RegistryResponseCache(fileURL: dbURL, clock: run2Clock)
        let firewall2 = CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: run2Clock),
            cache: cache2,
            requestObserver: { events.append($0) }
        )

        let uncachedNoMatchKeys: Set<String> = ["real_nodoi", "fake_nodoi", "draft2024unverified"]
        let typoDOINotFoundKeys: Set<String> = ["fake_nonsentinel", "fake_sentinel"]

        for entry in entries {
            _ = events.drain()
            _ = await counter.resetAndRead()
            let v2 = await firewall2.verifyAgainstPublicRegistries(entry: entry, session: countingSession)
            let entryRequests = await counter.resetAndRead()
            let entryEvents = events.drain()
            let v1 = try #require(run1Verdicts[entry.citeKey])

            #expect(v2.firewallClass == v1.firewallClass, "Class mismatch on \(entry.citeKey)")
            #expect(v2.insertable == v1.insertable, "Insertable mismatch on \(entry.citeKey)")
            #expect(v2.reasons == v1.reasons, "Reasons mismatch on \(entry.citeKey)")
            #expect(v2.fields == v1.fields, "Fields mismatch on \(entry.citeKey)")

            if uncachedNoMatchKeys.contains(entry.citeKey) {
                #expect(entryRequests == 2, "no_match_in_search entry \(entry.citeKey) must not be cached")
            } else if typoDOINotFoundKeys.contains(entry.citeKey) {
                #expect(entryRequests == 1, "Unmatched Crossref title search on \(entry.citeKey) must not be cached (got \(entryRequests))")
                let handleSrc = try #require(v2.sources.first { $0.source == "doi.org" })
                #expect(handleSrc.origin == .cache)
                #expect(handleSrc.fetchedAt == "2026-11-16")
                let searchSrc = try #require(v2.sources.first { $0.source == "Crossref" })
                #expect(searchSrc.origin == .replay)
            } else {
                #expect(entryRequests == 0, "Cached entry \(entry.citeKey) must send 0 transport requests on run 2 (got \(entryRequests))")
                #expect(!v2.sources.isEmpty, "Cached entry \(entry.citeKey) must record sources")
                for src in v2.sources {
                    #expect(src.origin == .cache, "Expected origin == .cache for \(entry.citeKey) source \(src.source)")
                    #expect(src.fetchedAt == "2026-11-16", "Expected UTC date 2026-11-16 on \(entry.citeKey), got \(src.fetchedAt)")
                }
                #expect(!entryEvents.isEmpty, "Expected --verbose observer events for cached entry \(entry.citeKey)")
                #expect(entryEvents.allSatisfy { $0.origin == .cache })
                if v2.firewallClass == .verified {
                    #expect(v2.auditNote.contains("fetched 2026-11-16 (cache)"))
                }
            }
        }
    }

    @Test("M1 item 7 (Stage 07): HTTP 500, 429, timeout, disconnect, bad JSON, ambiguous, no_match_in_search, and registered_no_metadata never enter cache")
    func m1Stage07TransientFailuresAmbiguousAndNoMatchNeverEnterCache() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-stage07-nocache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("registry.sqlite")
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let clock = ClosureRegistryClock.immediate

        let cache = RegistryResponseCache(fileURL: dbURL, clock: clock)
        let firewall = CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: clock),
            cache: cache
        )

        let lecunEntry = BibliographyEntry(
            citeKey: "real_lecun",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )
        let arxivEntry = BibliographyEntry(
            citeKey: "arxiv_real_vaswani",
            kind: .misc,
            title: "Attention Is All You Need",
            authors: [
                BibAuthor(givenName: "Ashish", familyName: "Vaswani"),
                BibAuthor(givenName: "Noam", familyName: "Shazeer"),
                BibAuthor(givenName: "Niki", familyName: "Parmar"),
                BibAuthor(givenName: "Jakob", familyName: "Uszkoreit"),
                BibAuthor(givenName: "Llion", familyName: "Jones"),
                BibAuthor(givenName: "Aidan N.", familyName: "Gomez"),
                BibAuthor(givenName: "Lukasz", familyName: "Kaiser"),
                BibAuthor(givenName: "Illia", familyName: "Polosukhin")
            ],
            year: 2017,
            arxivID: "1706.03762"
        )
        let pmidEntry = BibliographyEntry(
            citeKey: "pmid_real_ito2015",
            kind: .article,
            title: "A prefrontal-thalamo-hippocampal circuit for goal-directed spatial navigation",
            authors: [
                BibAuthor(givenName: "Hiroshi T.", familyName: "Ito"),
                BibAuthor(givenName: "Sheng-Jia", familyName: "Zhang"),
                BibAuthor(givenName: "Menno P.", familyName: "Witter"),
                BibAuthor(givenName: "Edvard I.", familyName: "Moser"),
                BibAuthor(givenName: "May-Britt", familyName: "Moser")
            ],
            year: 2015,
            venue: "Nature",
            pmid: "26017312"
        )

        // 1. Inject 500, 429, timeout, transport error, and unparseable 200 JSON/XML on run 1
        let fail500 = ClosureRegistrySession { _ in
            RegistryHTTPResponse(statusCode: 500, body: Data("Internal Server Error".utf8))
        }
        let fail429 = ClosureRegistrySession { _ in
            RegistryHTTPResponse(statusCode: 429, body: Data("Too Many Requests".utf8), headers: ["Retry-After": "1"])
        }
        let failTimeout = ClosureRegistrySession { req in
            throw RegistryTransportError(kind: .timeout, detail: "Simulated timeout", url: req.url)
        }
        let failDisconnect = ClosureRegistrySession { req in
            throw RegistryTransportError(kind: .transportError, detail: "Simulated offline", url: req.url)
        }
        let failBadPayload = ClosureRegistrySession { _ in
            RegistryHTTPResponse(statusCode: 200, body: Data("{corrupt-json-not-valid".utf8))
        }

        for session in [fail500, fail429, failTimeout, failDisconnect, failBadPayload] {
            let vDOI = await firewall.verifyAgainstPublicRegistries(entry: lecunEntry, session: session)
            let vArXiv = await firewall.verifyAgainstPublicRegistries(entry: arxivEntry, session: session)
            let vPMID = await firewall.verifyAgainstPublicRegistries(entry: pmidEntry, session: session)
            #expect(vDOI.firewallClass == .unverified)
            #expect(vArXiv.firewallClass == .unverified)
            #expect(vPMID.firewallClass == .unverified)
        }

        // 2. Ambiguous (both identifierless search and typo-DOI search), no_match_in_search, and registered_no_metadata
        let ambiguousTiedPayload = Data("""
        {
          "status": "ok",
          "message": {
            "items": [
              {
                "DOI": "10.1000/ambig.1",
                "title": ["Identical Ambiguous Title"],
                "author": [{"given": "Alice", "family": "chen"}],
                "issued": {"date-parts": [[2022]]},
                "container-title": ["Journal of Testing"]
              },
              {
                "DOI": "10.1000/ambig.2",
                "title": ["Identical Ambiguous Title"],
                "author": [{"given": "Alice", "family": "Chen"}],
                "issued": {"date-parts": [[2022]]},
                "container-title": ["Journal of Testing"]
              }
            ]
          }
        }
        """.utf8)

        let ambigNoPID = BibliographyEntry(
            citeKey: "ambig_nopid",
            kind: .article,
            title: "Identical Ambiguous Title",
            authors: [BibAuthor(givenName: "Alice", familyName: "Chen")],
            year: 2022,
            venue: "Journal of Testing"
        )
        let ambigTypoDOI = BibliographyEntry(
            citeKey: "ambig_typodoi",
            kind: .article,
            title: "Identical Ambiguous Title",
            authors: [BibAuthor(givenName: "Alice", familyName: "Chen")],
            year: 2022,
            venue: "Journal of Testing",
            doi: "10.1000/nonexistent.9999"
        )
        let ambigSession = ClosureRegistrySession { req in
            let host = req.url?.host ?? ""
            let query = req.url?.query ?? ""
            if host == "api.crossref.org" && query.contains("query.bibliographic=") {
                return RegistryHTTPResponse(statusCode: 200, body: ambiguousTiedPayload)
            }
            if host == "doi.org" {
                return RegistryHTTPResponse(statusCode: 404, body: Data("{\"responseCode\":100}".utf8))
            }
            return RegistryHTTPResponse(statusCode: 404, body: Data("Not Found".utf8))
        }

        let vAmbig1 = await firewall.verifyAgainstPublicRegistries(entry: ambigNoPID, session: ambigSession)
        let vAmbig2 = await firewall.verifyAgainstPublicRegistries(entry: ambigTypoDOI, session: ambigSession)
        #expect(vAmbig1.firewallClass == .unverified)
        #expect(vAmbig1.reasons == [CitationUnverifiedReasonCode.ambiguous.rawValue])
        #expect(vAmbig2.firewallClass == .unverified)
        #expect(vAmbig2.reasons == [CitationUnverifiedReasonCode.ambiguous.rawValue])

        let noMatchEntry = BibliographyEntry(
            citeKey: "draft2024unverified",
            kind: .misc,
            title: "Unpublished Workshop Notes on Attention Kernels",
            authors: [BibAuthor(givenName: "Pat", familyName: "Taylor")],
            year: 2024
        )
        let cnkiRegisteredNoMeta = BibliographyEntry(
            citeKey: "yang2024jos",
            kind: .article,
            title: "Deep Learning Based Code Generation Methods: Literature Review",
            authors: [BibAuthor(givenName: "Zezhou", familyName: "Yang")],
            year: 2024,
            venue: "Journal of Software",
            doi: "10.13328/j.cnki.jos.006981"
        )
        let vNoMatch = await firewall.verifyAgainstPublicRegistries(entry: noMatchEntry, session: replay)
        let vRegNoMeta = await firewall.verifyAgainstPublicRegistries(entry: cnkiRegisteredNoMeta, session: replay)
        #expect(vNoMatch.firewallClass == .unverified)
        #expect(vNoMatch.reasons == [CitationUnverifiedReasonCode.noMatchInSearch.rawValue])
        #expect(vRegNoMeta.firewallClass == .unverified)
        #expect(vRegNoMeta.reasons == [CitationUnverifiedReasonCode.registeredNoMetadata.rawValue])

        // Assert zero rows were written to SQLite across all failure/ambiguous/no_match_in_search runs!
        if FileManager.default.fileExists(atPath: dbURL.path) {
            var db: OpaquePointer?
            #expect(sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
            defer { sqlite3_close_v2(db) }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM registry_cache;", -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    #expect(sqlite3_column_int64(stmt, 0) == 0)
                }
            }
        }

        // 3. Second run with normal replay session sends normal requests and gets the true VERIFIED verdicts
        actor RecoveryCounter {
            var count = 0
            func inc() { count += 1 }
        }
        let recoveryCounter = RecoveryCounter()
        let normalSession = ClosureRegistrySession { req in
            await recoveryCounter.inc()
            return try await replay.send(req)
        }
        let recoveredDOI = await firewall.verifyAgainstPublicRegistries(entry: lecunEntry, session: normalSession)
        let recoveredArXiv = await firewall.verifyAgainstPublicRegistries(entry: arxivEntry, session: normalSession)
        let recoveredPMID = await firewall.verifyAgainstPublicRegistries(entry: pmidEntry, session: normalSession)
        #expect(recoveredDOI.firewallClass == .verified)
        #expect(recoveredArXiv.firewallClass == .verified)
        #expect(recoveredPMID.firewallClass == .verified)
        #expect(await recoveryCounter.count == 4) // 2 (Crossref + OpenAlex) + 1 (arXiv) + 1 (PubMed)
    }

    @Test("M1 item 7 (Stage 07): injectable clock expires all 3 substantiated not-found types after 1 day and valid 200 records after 30 days (not at 29 days)")
    func m1Stage07InjectableClockExpiration1DayNotFoundAnd30DayValidRecords() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-stage07-ttl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        final class SteppableClock: @unchecked Sendable {
            private let lock = NSLock()
            private var offsetSeconds: TimeInterval = 0
            let baseEpoch: TimeInterval = 1_794_787_200 // 2026-11-16T00:00:00Z

            func setOffset(_ seconds: TimeInterval) {
                lock.lock()
                offsetSeconds = seconds
                lock.unlock()
            }

            func now() -> TimeInterval {
                lock.lock()
                defer { lock.unlock() }
                return offsetSeconds
            }

            func currentDate() -> Date {
                lock.lock()
                defer { lock.unlock() }
                return Date(timeIntervalSince1970: baseEpoch + offsetSeconds)
            }
        }

        actor Counter {
            var count = 0
            func inc() { count += 1 }
            func drain() -> Int {
                let c = count
                count = 0
                return c
            }
        }

        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let counter = Counter()
        let countingSession = ClosureRegistrySession { req in
            await counter.inc()
            return try await replay.send(req)
        }

        // Part A: Three substantiated "not found" types (doi.org 100, arXiv totalResults 0, PubMed error) -> 1-day TTL
        let notFoundClockState = SteppableClock()
        let notFoundClock = ClosureRegistryClock(
            now: { notFoundClockState.now() },
            currentDate: { notFoundClockState.currentDate() },
            sleep: { _ in }
        )
        let notFoundDB = tempDir.appendingPathComponent("notfound.sqlite")
        let notFoundCache = RegistryResponseCache(fileURL: notFoundDB, clock: notFoundClock)
        let notFoundFirewall = CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: notFoundClock),
            cache: notFoundCache
        )

        let doiNotFound = BibliographyEntry(
            citeKey: "fake_nonsentinel",
            kind: .article,
            title: "Quantum Gradient Descent in Biological Neural Networks",
            authors: [
                BibAuthor(givenName: "Eleanor", familyName: "Whitfield"),
                BibAuthor(givenName: "Raj", familyName: "Patel")
            ],
            year: 2026,
            venue: "Nature Machine Intelligence",
            doi: "10.1038/fake.2026.99999"
        )
        let arxivNotFound = BibliographyEntry(
            citeKey: "arxiv_nonexistent",
            kind: .misc,
            title: "Synthetic Nonexistent Preprint",
            authors: [BibAuthor(givenName: "Alex", familyName: "Rivera")],
            year: 2024,
            arxivID: "2401.99999"
        )
        let pmidNotFound = BibliographyEntry(
            citeKey: "pmid_nonexistent",
            kind: .article,
            title: "Synthetic Nonexistent PubMed Study",
            authors: [BibAuthor(givenName: "Jordan", familyName: "Lee")],
            year: 2024,
            pmid: "99999999"
        )

        for entry in [doiNotFound, arxivNotFound, pmidNotFound] {
            let v = await notFoundFirewall.verifyAgainstPublicRegistries(entry: entry, session: countingSession)
            #expect(v.firewallClass == .notFound)
        }
        #expect(await counter.drain() == 6) // 4 (Crossref, OpenAlex, doi.org, CrossrefSearch) + 1 (arXiv) + 1 (PubMed)

        // At +23 hours (< 1 day): doi.org/arXiv/PubMed 1d rows hit cache; only doiNotFound's unmatched Crossref title search re-sends (1 request)
        notFoundClockState.setOffset(23 * 3600)
        for entry in [doiNotFound, arxivNotFound, pmidNotFound] {
            let v = await notFoundFirewall.verifyAgainstPublicRegistries(entry: entry, session: countingSession)
            #expect(v.firewallClass == .notFound)
            if entry.citeKey == "fake_nonsentinel" {
                #expect(v.sources.contains { $0.source == "doi.org" && $0.origin == .cache && $0.fetchedAt == "2026-11-16" })
                #expect(v.sources.contains { $0.source == "Crossref" && $0.origin == .replay })
            } else {
                #expect(v.sources.allSatisfy { $0.origin == .cache && $0.fetchedAt == "2026-11-16" })
            }
        }
        #expect(await counter.drain() == 1)

        // At +1 day + 1 second (86_401s -> 2026-11-17T00:00:01Z): all 3 expire and re-send requests, overwriting expired rows
        notFoundClockState.setOffset(86_401)
        _ = await counter.drain()
        let vDOIAfter1d = await notFoundFirewall.verifyAgainstPublicRegistries(entry: doiNotFound, session: countingSession)
        let doiReqsAfter1d = await counter.drain()
        let vArXivAfter1d = await notFoundFirewall.verifyAgainstPublicRegistries(entry: arxivNotFound, session: countingSession)
        let arxivReqsAfter1d = await counter.drain()
        let vPMIDAfter1d = await notFoundFirewall.verifyAgainstPublicRegistries(entry: pmidNotFound, session: countingSession)
        let pmidReqsAfter1d = await counter.drain()

        #expect(vDOIAfter1d.firewallClass == .notFound)
        #expect(doiReqsAfter1d == 4, "Expired doi.org 100 entry must re-query Crossref + OpenAlex + doi.org + Crossref title search after 1 day")
        #expect(vArXivAfter1d.firewallClass == .notFound)
        #expect(arxivReqsAfter1d == 1, "Expired arXiv totalResults=0 entry must re-query arXiv after 1 day")
        #expect(vPMIDAfter1d.firewallClass == .notFound)
        #expect(pmidReqsAfter1d == 1, "Expired PubMed error entry must re-query PubMed after 1 day")

        // Confirm overwritten timestamp is 2026-11-17 on immediate subsequent lookup (only doiNotFound's unmatched Crossref search re-sends)
        notFoundClockState.setOffset(86_460)
        for entry in [doiNotFound, arxivNotFound, pmidNotFound] {
            let v = await notFoundFirewall.verifyAgainstPublicRegistries(entry: entry, session: countingSession)
            #expect(v.firewallClass == .notFound)
            #expect(v.sources.contains { $0.origin == .cache && $0.fetchedAt == "2026-11-17" })
        }
        #expect(await counter.drain() == 1)

        // Part B: Valid 200 records -> 30-day TTL (29 days: 0 requests; >30 days: re-sends & overwrites)
        let validClockState = SteppableClock()
        let validClock = ClosureRegistryClock(
            now: { validClockState.now() },
            currentDate: { validClockState.currentDate() },
            sleep: { _ in }
        )
        let validDB = tempDir.appendingPathComponent("valid.sqlite")
        let validCache = RegistryResponseCache(fileURL: validDB, clock: validClock)
        let validFirewall = CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: validClock),
            cache: validCache
        )

        let lecun = BibliographyEntry(
            citeKey: "real_lecun",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )
        let vaswani = BibliographyEntry(
            citeKey: "arxiv_real_vaswani",
            kind: .misc,
            title: "Attention Is All You Need",
            authors: [
                BibAuthor(givenName: "Ashish", familyName: "Vaswani"),
                BibAuthor(givenName: "Noam", familyName: "Shazeer"),
                BibAuthor(givenName: "Niki", familyName: "Parmar"),
                BibAuthor(givenName: "Jakob", familyName: "Uszkoreit"),
                BibAuthor(givenName: "Llion", familyName: "Jones"),
                BibAuthor(givenName: "Aidan N.", familyName: "Gomez"),
                BibAuthor(givenName: "Lukasz", familyName: "Kaiser"),
                BibAuthor(givenName: "Illia", familyName: "Polosukhin")
            ],
            year: 2017,
            arxivID: "1706.03762"
        )
        let ito = BibliographyEntry(
            citeKey: "pmid_real_ito2015",
            kind: .article,
            title: "A prefrontal-thalamo-hippocampal circuit for goal-directed spatial navigation",
            authors: [
                BibAuthor(givenName: "Hiroshi T.", familyName: "Ito"),
                BibAuthor(givenName: "Sheng-Jia", familyName: "Zhang"),
                BibAuthor(givenName: "Menno P.", familyName: "Witter"),
                BibAuthor(givenName: "Edvard I.", familyName: "Moser"),
                BibAuthor(givenName: "May-Britt", familyName: "Moser")
            ],
            year: 2015,
            venue: "Nature",
            pmid: "26017312"
        )

        for entry in [lecun, vaswani, ito] {
            let v = await validFirewall.verifyAgainstPublicRegistries(entry: entry, session: countingSession)
            #expect(v.firewallClass == .verified)
        }
        #expect(await counter.drain() == 4)

        // At +29 days: 0 requests sent
        validClockState.setOffset(29 * 86_400)
        for entry in [lecun, vaswani, ito] {
            let v = await validFirewall.verifyAgainstPublicRegistries(entry: entry, session: countingSession)
            #expect(v.firewallClass == .verified)
            #expect(v.sources.allSatisfy { $0.origin == .cache && $0.fetchedAt == "2026-11-16" })
        }
        #expect(await counter.drain() == 0)

        // At +30 days + 1 second (2026-12-16T00:00:01Z): all 3 expire, re-send requests, and overwrite rows
        validClockState.setOffset(30 * 86_400 + 1)
        for entry in [lecun, vaswani, ito] {
            let v = await validFirewall.verifyAgainstPublicRegistries(entry: entry, session: countingSession)
            #expect(v.firewallClass == .verified)
        }
        #expect(await counter.drain() == 4)

        // Subsequent check at +30 days + 60 seconds hits refreshed rows (2026-12-16) with 0 requests
        validClockState.setOffset(30 * 86_400 + 60)
        for entry in [lecun, vaswani, ito] {
            let v = await validFirewall.verifyAgainstPublicRegistries(entry: entry, session: countingSession)
            #expect(v.firewallClass == .verified)
            #expect(v.sources.allSatisfy { $0.origin == .cache && $0.fetchedAt == "2026-12-16" })
        }
        #expect(await counter.drain() == 0)
    }

    @Test("M1 item 7 (Stage 07): canonical URL key normalizes parameter order, case, and percent-escapes while SQLite stores only url, status, body, and fetched_at")
    func m1Stage07CanonicalURLKeyNormalizationAndSQLiteSchemaHygiene() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-stage07-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("registry.sqlite")
        let fixedDate = Date(timeIntervalSince1970: 1_794_787_200) // 2026-11-16T00:00:00Z
        let clock = ClosureRegistryClock(now: { 0 }, currentDate: { fixedDate }, sleep: { _ in })
        let cache = RegistryResponseCache(fileURL: dbURL, clock: clock)

        // 1. Query parameter order, host/scheme case, default port, fragment, and percent-encoding normalization
        let unnormalizedPubMed = try #require(
            URL(string: "HTTPS://EUTILS.NCBI.NLM.NIH.GOV:443/entrez/eutils/esummary.fcgi?retmode=json&id=26017312&db=%70ubmed#frag")
        )
        let canonicalPubMed = try #require(
            URL(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id=26017312&retmode=json")
        )
        #expect(RegistryResponseCache.canonicalKey(for: unnormalizedPubMed) == RegistryResponseCache.canonicalKey(for: canonicalPubMed))

        let unnormalizedCrossrefSearch = try #require(
            URL(string: "HTTPS://API.Crossref.ORG:443/works?rows=5&query.bibliographic=ICALP%202015%20Halld%c3%b3rsson")
        )
        let canonicalCrossrefSearch = try #require(
            URL(string: "https://api.crossref.org/works?query.bibliographic=ICALP%202015%20Halld%C3%B3rsson&rows=5")
        )
        #expect(RegistryResponseCache.canonicalKey(for: unnormalizedCrossrefSearch) == RegistryResponseCache.canonicalKey(for: canonicalCrossrefSearch))

        let unnormalizedDOI = try #require(
            URL(string: "HTTPS://API.CROSSREF.ORG:443/works/10.1038/Nature14539#section")
        )
        let canonicalDOI = try #require(
            URL(string: "https://api.crossref.org/works/10.1038/nature14539")
        )
        #expect(RegistryResponseCache.canonicalKey(for: unnormalizedDOI) == RegistryResponseCache.canonicalKey(for: canonicalDOI))

        // Store via unnormalized URL, lookup via canonical URL (and confirm headers play no part)
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: clock),
            cache: cache
        )
        let secretBibEntry = try #require(
            BibTeXCodec().parseDocument("""
            @article{secret_local_citekey_never_stored,
              author  = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
              title   = {Deep learning},
              journal = {Nature},
              year    = {2015},
              doi     = {10.1038/nature14539},
              note    = {private_bib_note_never_stored}
            }
            """).entries.first
        )
        let headerInjectedSession = ClosureRegistrySession { req in
            let base = try await replay.send(req)
            return RegistryHTTPResponse(
                statusCode: base.statusCode,
                body: base.body,
                headers: [
                    "User-Agent": "ScholarOS/1.2.0",
                    "X-Secret-Test-Header": "must-never-be-persisted-in-sqlite"
                ],
                origin: .network,
                fetchedAt: base.fetchedAt
            )
        }
        let v = await firewall.verifyAgainstPublicRegistries(entry: secretBibEntry, session: headerInjectedSession)
        #expect(v.firewallClass == .verified)

        // Lookup using uppercase host/DOI URL hits the exact cached record
        let hitViaUnnormalized = try #require(cache.lookup(for: unnormalizedDOI))
        #expect(hitViaUnnormalized.origin == .cache)
        #expect(hitViaUnnormalized.statusCode == 200)
        #expect(hitViaUnnormalized.fetchedAt == "2026-11-16")
        #expect(hitViaUnnormalized.headers.isEmpty)

        // 2. Inspect SQLite schema & raw bytes for strict data hygiene (Item 7)
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(db) }

        var colNames: [String] = []
        var pragmaStmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "PRAGMA table_info(registry_cache);", -1, &pragmaStmt, nil) == SQLITE_OK)
        while sqlite3_step(pragmaStmt) == SQLITE_ROW {
            if let cName = sqlite3_column_text(pragmaStmt, 1) {
                colNames.append(String(cString: cName))
            }
        }
        sqlite3_finalize(pragmaStmt)
        #expect(colNames == ["url", "status", "body", "fetched_at"])

        // Checkpoint WAL or read all SQLite artifacts to ensure zero headers, local paths, or .bib content
        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: dbURL.path + suffix)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let rawBytes = try Data(contentsOf: fileURL)
            let latin1 = String(decoding: rawBytes, as: UTF8.self)
            #expect(!latin1.contains("X-Secret-Test-Header"))
            #expect(!latin1.contains("must-never-be-persisted-in-sqlite"))
            #expect(!latin1.contains("ScholarOS/1.2.0"))
            #expect(!latin1.contains("secret_local_citekey_never_stored"))
            #expect(!latin1.contains("private_bib_note_never_stored"))
            #expect(!latin1.contains(tempDir.path))
        }
    }

    @Test("M1 item 7 (Stage 07): corrupt SQLite bytes and unwritable cache paths emit one warning without failing verification, and concurrent connections succeed")
    func m1Stage07CorruptDatabaseAndConcurrentConnectionsResilience() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-stage07-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)

        final class WarningCollector: @unchecked Sendable {
            private let lock = NSLock()
            var messages: [String] = []
            func append(_ msg: String) {
                lock.lock()
                messages.append(msg)
                lock.unlock()
            }
        }

        // 1. Corrupt registry.sqlite containing random non-SQLite bytes
        let corruptDBURL = tempDir.appendingPathComponent("corrupt.sqlite")
        var garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF, 0x42, 0x13, 0x7F, 0x80])
        garbage.append(Data("corrupt-not-a-sqlite-header-at-all".utf8))
        try garbage.write(to: corruptDBURL)

        let corruptWarnings = WarningCollector()
        let corruptCache = RegistryResponseCache(
            fileURL: corruptDBURL,
            clock: .immediate,
            warningHandler: { corruptWarnings.append($0) }
        )
        let corruptFirewall = CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: .immediate),
            cache: corruptCache
        )

        let lecun = BibliographyEntry(
            citeKey: "real_lecun",
            kind: .article,
            title: "Deep learning",
            authors: [
                BibAuthor(givenName: "Yann", familyName: "LeCun"),
                BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
            ],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539"
        )
        let vaswani = BibliographyEntry(
            citeKey: "arxiv_real_vaswani",
            kind: .misc,
            title: "Attention Is All You Need",
            authors: [
                BibAuthor(givenName: "Ashish", familyName: "Vaswani"),
                BibAuthor(givenName: "Noam", familyName: "Shazeer"),
                BibAuthor(givenName: "Niki", familyName: "Parmar"),
                BibAuthor(givenName: "Jakob", familyName: "Uszkoreit"),
                BibAuthor(givenName: "Llion", familyName: "Jones"),
                BibAuthor(givenName: "Aidan N.", familyName: "Gomez"),
                BibAuthor(givenName: "Lukasz", familyName: "Kaiser"),
                BibAuthor(givenName: "Illia", familyName: "Polosukhin")
            ],
            year: 2017,
            arxivID: "1706.03762"
        )

        let v1 = await corruptFirewall.verifyAgainstPublicRegistries(entry: lecun, session: replay)
        let v2 = await corruptFirewall.verifyAgainstPublicRegistries(entry: vaswani, session: replay)
        #expect(v1.firewallClass == .verified)
        #expect(v2.firewallClass == .verified)
        #expect(corruptWarnings.messages.count == 1)
        #expect(corruptWarnings.messages.first?.contains("\n") == false)

        // 2. Unwritable cache path (regular file blocking directory creation)
        let blockingFileURL = tempDir.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blockingFileURL)
        let unwritableDBURL = blockingFileURL.appendingPathComponent("registry.sqlite")
        let unwritableWarnings = WarningCollector()
        let unwritableCache = RegistryResponseCache(
            fileURL: unwritableDBURL,
            clock: .immediate,
            warningHandler: { unwritableWarnings.append($0) }
        )
        let unwritableFirewall = CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: .immediate),
            cache: unwritableCache
        )
        let vUnwritable = await unwritableFirewall.verifyAgainstPublicRegistries(entry: lecun, session: replay)
        #expect(vUnwritable.firewallClass == .verified)
        #expect(unwritableWarnings.messages.count == 1)

        // 3. Multi-connection concurrent reads & writes on the same SQLite database (busy_timeout + WAL)
        let concurrentDBURL = tempDir.appendingPathComponent("concurrent/registry.sqlite")
        let concurrentWarnings = WarningCollector()
        await withTaskGroup(of: CitationFirewallEntryVerdict.self) { group in
            for idx in 0..<16 {
                let targetEntry = (idx % 2 == 0) ? lecun : vaswani
                group.addTask {
                    let workerCache = RegistryResponseCache(
                        fileURL: concurrentDBURL,
                        clock: .immediate,
                        warningHandler: { concurrentWarnings.append($0) }
                    )
                    let workerFirewall = CitationVerificationFirewall(
                        rateLimiter: RegistryRateLimiter(clock: .immediate),
                        cache: workerCache
                    )
                    return await workerFirewall.verifyAgainstPublicRegistries(entry: targetEntry, session: replay)
                }
            }
            for await verdict in group {
                #expect(verdict.firewallClass == .verified)
            }
        }
        #expect(concurrentWarnings.messages.isEmpty)
    }

    // MARK: - M1 Item 7 (Stage 08 Follow-up Fix 1): Unmatched Search Responses Never Cached

    @Test("M1 item 7 (Stage 08 Fix 1): unmatched search responses in typo-DOI and identifierless fallback are never cached; run 2 sends only that 1 search and +2 days re-sends both doi.org and title search")
    func m1Stage08Fix1UnmatchedSearchResponsesNeverCachedAcrossTypoDOIAndIdentifierless() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-stage08-fix1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let recheckRaw = try String(
            contentsOf: repoRoot.appendingPathComponent("Fixtures/citations-m0-recheck.bib"),
            encoding: .utf8
        )
        let recheckEntries = try BibTeXCodec().parseDocument(recheckRaw).entries
        let fakeNonSentinel = try #require(recheckEntries.first { $0.citeKey == "fake_nonsentinel" })
        let fakeSentinel = try #require(recheckEntries.first { $0.citeKey == "fake_sentinel" })

        let baseDate = Date(timeIntervalSince1970: 1_794_787_200) // 2026-11-16T00:00:00Z
        let clock = ClosureRegistryClock(now: { 0 }, currentDate: { baseDate }, sleep: { _ in })

        actor RequestRecorder {
            var urls: [String] = []
            func record(_ url: String) { urls.append(url) }
            func drain() -> [String] {
                let copy = urls
                urls.removeAll()
                return copy
            }
        }

        // Part 1: Typo-DOI fallback on fake_nonsentinel and fake_sentinel (doi.org 100 -> Crossref title search with 0 matching candidates)
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let recorder = RequestRecorder()
        let recordingSession = ClosureRegistrySession { req in
            await recorder.record(req.url?.absoluteString ?? "")
            return try await replay.send(req)
        }

        let typoDB = tempDir.appendingPathComponent("typo-search.sqlite")
        let typoCache = RegistryResponseCache(fileURL: typoDB, clock: clock)
        let typoFirewall = CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: clock),
            cache: typoCache
        )

        // Run 1: populates doi.org 100 (1-day TTL), must NOT store unmatched Crossref title search
        for entry in recheckEntries {
            _ = await typoFirewall.verifyAgainstPublicRegistries(entry: entry, session: recordingSession)
        }
        _ = await recorder.drain()

        // Run 2 immediately (< 1 day): doi.org hits cache, only the 1 unmatched Crossref title search is sent per entry
        for fakeEntry in [fakeNonSentinel, fakeSentinel] {
            let v2 = await typoFirewall.verifyAgainstPublicRegistries(entry: fakeEntry, session: recordingSession)
            let sentURLs = await recorder.drain()
            #expect(v2.firewallClass == .notFound)
            #expect(
                sentURLs.count == 1,
                "Expected run 2 on \(fakeEntry.citeKey) to send only the 1 unmatched Crossref title search, got \(sentURLs.count): \(sentURLs)"
            )
            #expect(sentURLs.first?.contains("api.crossref.org/works?query.bibliographic=") == true)
            #expect(v2.sources.first { $0.source == "doi.org" }?.origin == .cache)
            #expect(v2.sources.first { $0.source == "Crossref" }?.origin == .replay)
        }

        // Dial ALL cached rows back by 2 days (2026-11-14T00:00:00Z): 1-day doi.org expires, and title search must STILL re-send (not hit a 30d cache!)
        do {
            var db: OpaquePointer?
            #expect(sqlite3_open_v2(typoDB.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            defer { sqlite3_close_v2(db) }
            #expect(sqlite3_exec(db, "UPDATE registry_cache SET fetched_at = '2026-11-14T00:00:00Z';", nil, nil, nil) == SQLITE_OK)
        }

        let freshCacheAfter2d = RegistryResponseCache(fileURL: typoDB, clock: clock)
        let firewallAfter2d = CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: clock),
            cache: freshCacheAfter2d
        )
        for fakeEntry in [fakeNonSentinel, fakeSentinel] {
            let vAfter2d = await firewallAfter2d.verifyAgainstPublicRegistries(entry: fakeEntry, session: recordingSession)
            let sentAfter2d = await recorder.drain()
            #expect(vAfter2d.firewallClass == .notFound)
            #expect(
                sentAfter2d.count == 4,
                "After 2 days on \(fakeEntry.citeKey), Crossref single + OpenAlex single + doi.org + Crossref title search must all be sent (got \(sentAfter2d.count): \(sentAfter2d))"
            )
            #expect(sentAfter2d.contains { $0.contains("doi.org/api/handles/") })
            #expect(
                sentAfter2d.contains { $0.contains("api.crossref.org/works?query.bibliographic=") },
                "After 2 days on \(fakeEntry.citeKey), Crossref title search must be re-sent rather than served from 30d cache"
            )
        }

        // Part 2: Identifierless entry where Crossref search has 0 matches and OpenAlex search matches a candidate (using real recorded Knuth payloads)
        let knuthCrossrefRaw = try Data(
            contentsOf: Self.recordedRegistryFixturesURL.appendingPathComponent(
                "crossref_title_The_Art_of_Computer_Programming_Volume_1_Fundame_46dd1a7787.raw"
            )
        )
        let knuthOpenAlexRaw = try Data(
            contentsOf: Self.recordedRegistryFixturesURL.appendingPathComponent(
                "openalex_title_The_Art_of_Computer_Programming_Volume_1_Fundame_5209a5b41f.raw"
            )
        )
        let knuth2011 = BibliographyEntry(
            citeKey: "knuth2011taocp4a",
            kind: .book,
            title: "The Art of Computer Programming: Combinatorial Algorithms, Part 1",
            authors: [BibAuthor(givenName: "Donald E.", familyName: "Knuth")],
            year: 2011
        )
        let oaRecorder = RequestRecorder()
        let knuthSession = ClosureRegistrySession { req in
            let urlStr = req.url?.absoluteString ?? ""
            await oaRecorder.record(urlStr)
            let host = req.url?.host ?? ""
            if host == "api.crossref.org" {
                return RegistryHTTPResponse(statusCode: 200, body: knuthCrossrefRaw, origin: .replay, fetchedAt: "2026-11-15")
            }
            if host == "api.openalex.org" {
                return RegistryHTTPResponse(statusCode: 200, body: knuthOpenAlexRaw, origin: .replay, fetchedAt: "2026-11-15")
            }
            return RegistryHTTPResponse(statusCode: 404, body: Data("Not Found".utf8), origin: .replay)
        }

        let noPIDDB = tempDir.appendingPathComponent("identifierless-oa.sqlite")
        let noPIDCache = RegistryResponseCache(fileURL: noPIDDB, clock: clock)
        let noPIDFirewall = CitationVerificationFirewall(
            rateLimiter: RegistryRateLimiter(clock: clock),
            cache: noPIDCache
        )

        let knuthV1 = await noPIDFirewall.verifyAgainstPublicRegistries(entry: knuth2011, session: knuthSession)
        let knuthRun1URLs = await oaRecorder.drain()
        #expect(knuthV1.firewallClass == .verified || knuthV1.firewallClass == .drift)
        #expect(knuthRun1URLs.count == 2)

        // Inspect SQLite: ONLY OpenAlex's matched search URL may be stored; Crossref's unmatched search URL must NOT be stored
        do {
            var db: OpaquePointer?
            #expect(sqlite3_open_v2(noPIDDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
            defer { sqlite3_close_v2(db) }
            var cachedURLs: [String] = []
            var stmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "SELECT url FROM registry_cache;", -1, &stmt, nil) == SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    cachedURLs.append(String(cString: cStr))
                }
            }
            #expect(cachedURLs.count == 1, "Expected only the matched OpenAlex search response in cache, got: \(cachedURLs)")
            #expect(cachedURLs.allSatisfy { $0.contains("api.openalex.org") })
            #expect(!cachedURLs.contains { $0.contains("api.crossref.org") })
        }

        // Run 2 on knuth2011: sends ONLY the 1 unmatched Crossref search; OpenAlex search comes from cache
        let knuthV2 = await noPIDFirewall.verifyAgainstPublicRegistries(entry: knuth2011, session: knuthSession)
        let knuthRun2URLs = await oaRecorder.drain()
        #expect(knuthV2.firewallClass == knuthV1.firewallClass)
        #expect(knuthRun2URLs.count == 1, "Expected run 2 to send only the 1 unmatched Crossref search, got: \(knuthRun2URLs)")
        #expect(knuthRun2URLs.first?.contains("api.crossref.org") == true)
        #expect(knuthV2.sources.first { $0.source == "OpenAlex" }?.origin == .cache)
    }

    // MARK: - M1 Stage 09: S51 (.bib CRLF, CR, and Mixed Line Endings)

    @Test("S51 regression: BibTeXCodec parses CRLF, standalone CR, and mixed line endings identically to LF without leaving carriage returns in any field")
    func s51BibTeXCodecParsesCRLFStandaloneCRAndMixedLineEndingsIdenticallyToLF() throws {
        let fixturesDir = Self.recordedRegistryFixturesURL.deletingLastPathComponent()
        let crlfURL = fixturesDir.appendingPathComponent("crlf-two-entries.bib")
        let mixedURL = fixturesDir.appendingPathComponent("mixed-line-endings.bib")

        // Verify raw fixture bytes genuinely contain CRLF (0x0D 0x0A)
        let crlfBytes = Array(try Data(contentsOf: crlfURL))
        #expect(crlfBytes.contains(0x0D))
        #expect(zip(crlfBytes, crlfBytes.dropFirst()).contains { $0 == 0x0D && $1 == 0x0A })

        let mixedBytes = Array(try Data(contentsOf: mixedURL))
        #expect(zip(mixedBytes, mixedBytes.dropFirst()).contains { $0 == 0x0D && $1 == 0x0A })
        #expect(zip(mixedBytes, mixedBytes.dropFirst()).contains { $0 == 0x0D && $1 != 0x0A })
        #expect(zip(mixedBytes, mixedBytes.dropFirst()).contains { $0 != 0x0D && $1 == 0x0A })

        let crlfRaw = String(decoding: crlfBytes, as: UTF8.self)
        let lfFromCRLF = crlfRaw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let crOnlyRaw = lfFromCRLF.replacingOccurrences(of: "\n", with: "\r")

        let codec = BibTeXCodec()
        let expectedLFDoc = try codec.parseDocument(lfFromCRLF)
        let parsedCRLFDoc = try codec.parseDocument(crlfRaw)
        let parsedCROnlyDoc = try codec.parseDocument(crOnlyRaw)

        #expect(expectedLFDoc.entries.count == 2)
        #expect(parsedCRLFDoc == expectedLFDoc)
        #expect(parsedCROnlyDoc == expectedLFDoc)

        let mixedRaw = String(decoding: mixedBytes, as: UTF8.self)
        let lfFromMixed = mixedRaw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let expectedMixedLFDoc = try codec.parseDocument(lfFromMixed)
        let parsedMixedDoc = try codec.parseDocument(mixedRaw)
        #expect(expectedMixedLFDoc.entries.count == 2)
        #expect(parsedMixedDoc == expectedMixedLFDoc)

        // Ensure NO field value or unmapped field retains '\r' or '\r\n'
        for doc in [parsedCRLFDoc, parsedCROnlyDoc, parsedMixedDoc] {
            for entry in doc.entries {
                let allStrings: [String?] = [
                    entry.citeKey,
                    entry.title,
                    entry.venue,
                    entry.publisher,
                    entry.volume,
                    entry.issue,
                    entry.pages,
                    entry.doi,
                    entry.arxivID,
                    entry.pmid,
                    entry.url,
                    entry.abstractText
                ] + entry.authors.flatMap { [$0.givenName, $0.familyName, $0.orcid] }
                for val in allStrings.compactMap({ $0 }) {
                    #expect(!val.unicodeScalars.contains("\r"), "Found residual CR in '\(val)' for \(entry.citeKey)")
                }
            }
            for (_, unmapped) in doc.unmappedFieldsByCiteKey {
                for (_, val) in unmapped {
                    #expect(!val.unicodeScalars.contains("\r"), "Found residual CR in unmapped value '\(val)'")
                }
            }
        }

        // Direct LaTeXTextCodec and BibTeXAuthorParser calls with CRLF / CR
        #expect(LaTeXTextCodec().decode("Deep\r\nlearning\rmodels") == "Deep learning models")
        let authors = BibTeXAuthorParser.parseAuthors("Bratteli, O.\r\nand\rRobinson, D.W.")
        #expect(authors.map(\.familyName) == ["Bratteli", "Robinson"])
    }

    // MARK: - M1 Stage 09: S52 (Non-arXiv eprint, Multi-URL url, and Valid DOI + Malformed Explicit arXiv)

    @Test("S52 regression: 5 real entries in eprint-url-not-arxiv.bib all evaluate offline to UNVERIFIED (offline) with 0 NOT_FOUND")
    func s52FiveEntriesInEprintURLNotArXivEvaluateOfflineToUnverifiedZeroNotFound() async throws {
        let fixturesDir = Self.recordedRegistryFixturesURL.deletingLastPathComponent()
        let bibURL = fixturesDir.appendingPathComponent("eprint-url-not-arxiv.bib")
        let rawBib = try String(contentsOf: bibURL, encoding: .utf8)
        let entries = try BibTeXCodec().parse(rawBib)
        #expect(entries.count == 5)

        // Entry 1 (real_human_011): url has two whitespace-separated URLs -> clean arXiv ID 2107.07597
        let e1 = try #require(entries.first { $0.citeKey == "real_human_011" })
        #expect(e1.doi == "10.1137/21M1434180")
        #expect(e1.arxivID == "2107.07597")

        // Entries 2..5: publisher PDF / doi.org eprint without archivePrefix -> NOT treated as arXiv ID
        for key in ["real_human_031", "real_human_059", "real_human_081", "real_human_099"] {
            let entry = try #require(entries.first { $0.citeKey == key })
            #expect(entry.arxivID == nil, "Expected nil arxivID on \(key), got \(String(describing: entry.arxivID))")
            #expect(entry.doi != nil)
        }

        let enRes = try await CitationVerificationFirewall.verifyBibliography(
            entries: entries,
            mode: .offline,
            language: .en
        )
        #expect(enRes.report.notFoundCount == 0)
        #expect(enRes.report.unverifiedCount == 5)
        for v in enRes.report.verdicts {
            #expect(v.firewallClass == .unverified)
            #expect(v.reasons == ["offline"])
            #expect(!v.reasons.contains("invalid_identifier"))
        }

        let zhRes = try await CitationVerificationFirewall.verifyBibliography(
            entries: entries,
            mode: .offline,
            language: .zhHans
        )
        #expect(zhRes.report.notFoundCount == 0)
        #expect(zhRes.report.unverifiedCount == 5)
        for key in ["real_human_031", "real_human_059", "real_human_081", "real_human_099"] {
            let vZH = try #require(zhRes.report.verdicts.first { $0.citeKey == key })
            #expect(
                vZH.findings.contains { $0.detail.contains("eprint 字段不是 arXiv 编号，未当作标识符") },
                "Expected ZH non-arXiv eprint finding on \(key), got \(vZH.findings)"
            )
            let vEN = try #require(enRes.report.verdicts.first { $0.citeKey == key })
            #expect(
                vEN.findings.contains { $0.field == "eprint" && $0.detail.contains("not an arXiv identifier") },
                "Expected EN non-arXiv eprint finding on \(key), got \(vEN.findings)"
            )
        }
    }

    @Test("S52 unit rules 1-3: bare eprint arXiv formats, non-arXiv eprint finding, multi-URL arXiv/DOI extraction, and valid DOI + malformed explicit arXiv -> DRIFT")
    func s52UnitRulesBareEprintMultiURLAndValidDOIWithMalformedExplicitArXiv() async throws {
        let codec = BibTeXCodec()
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)

        // Rule 1a: Valid arXiv IDs in eprint WITHOUT archivePrefix/eprinttype (modern, versioned, arXiv: prefix, legacy) are recognized
        let bareArXivCases: [(String, String)] = [
            ("2107.07597", "2107.07597"),
            ("2107.07597v3", "2107.07597v3"),
            ("arXiv:1706.03762v5", "1706.03762v5"),
            ("1409.4842", "1409.4842"),
            ("hep-th/9901001", "hep-th/9901001"),
            ("arXiv:math.GT/0309136v2", "math.GT/0309136v2")
        ]
        for (rawVal, expectedID) in bareArXivCases {
            let bib = """
            @misc{test_bare,
              author = {Author, A.},
              title  = {Test Paper},
              year   = {2021},
              eprint = {\(rawVal)}
            }
            """
            let parsed = try #require(try codec.parse(bib).first)
            #expect(parsed.arxivID == expectedID, "Expected '\(rawVal)' without archivePrefix to parse as arxivID '\(expectedID)', got \(String(describing: parsed.arxivID))")
            let v = CitationVerificationFirewall().evaluate(parsed)
            #expect(v.firewallClass == .unverified)
            #expect(v.reasons == ["offline"])
            #expect(!v.findings.contains { $0.field == "eprint" })
        }

        // Rule 1b: eprint = {https://...pdf} or non-arXiv repo ID -> NOT recognized as arXiv ID, emits finding, no invalid_identifier
        let pdfEprintBib = """
        @article{pdf_eprint_only,
          author = {Author, B.},
          title  = {Publisher PDF in Eprint},
          year   = {2022},
          eprint = {https://publisher.example.org/journal/paper.pdf}
        }
        """
        let pdfEntry = try #require(try codec.parse(pdfEprintBib).first)
        #expect(pdfEntry.arxivID == nil)
        let zhPDFRes = try await CitationVerificationFirewall.verifyBibliography(
            entries: [pdfEntry],
            mode: .offline,
            language: .zhHans
        )
        let zhPDFVerdict = try #require(zhPDFRes.report.verdicts.first)
        #expect(zhPDFVerdict.firewallClass == .unverified)
        #expect(!zhPDFVerdict.reasons.contains("invalid_identifier"))
        #expect(zhPDFVerdict.findings.contains { $0.detail.contains("eprint 字段不是 arXiv 编号，未当作标识符") })

        // Rule 2a: url with multiple whitespace-separated URLs -> takes first arxiv.org abs/pdf ID only; ignores non-abs/pdf URLs
        let multiURLBib = """
        @article{multi_url_entry,
          author = {Park, Youngmin},
          title  = {Multi URL Test},
          year   = {2021},
          url    = {https://arxiv.org/list/cs.LG/recent https://export.arxiv.org/pdf/1706.03762v5.pdf http://arxiv.org/abs/2107.07597 http://dx.doi.org/10.1038/nature14539}
        }
        """
        let multiParsed = try #require(try codec.parse(multiURLBib).first)
        #expect(multiParsed.arxivID == "1706.03762v5")
        // Rule 2b: url has dx.doi.org and entry has NO doi field -> populates doi from url!
        #expect(multiParsed.doi == "10.1038/nature14539")

        // Rule 2c: When entry HAS a doi field, doi.org in url is ignored for doi
        let explicitDOIBib = """
        @article{explicit_doi_entry,
          author = {LeCun, Yann},
          title  = {Deep learning},
          year   = {2015},
          doi    = {10.1038/nature14539},
          url    = {https://doi.org/10.1145/9999999.8888888 https://arxiv.org/abs/2107.07597}
        }
        """
        let explicitDOIParsed = try #require(try codec.parse(explicitDOIBib).first)
        #expect(explicitDOIParsed.doi == "10.1038/nature14539")
        #expect(explicitDOIParsed.arxivID == "2107.07597")

        // Rule 3a: Valid DOI + explicit archivePrefix={arXiv} + malformed eprint -> looks up by DOI, records malformed arxivID in fields, yields DRIFT (not NOT_FOUND, not VERIFIED)
        let validDOIInvalidArXivBib = """
        @article{lecun_bad_explicit_arxiv,
          author        = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
          title         = {Deep learning},
          journal       = {Nature},
          year          = {2015},
          doi           = {10.1038/nature14539},
          archivePrefix = {arXiv},
          eprint        = {not-a-valid-arxiv-99}
        }
        """
        let mixedEntry = try #require(try codec.parse(validDOIInvalidArXivBib).first)
        let offlineMixed = CitationVerificationFirewall().evaluate(mixedEntry)
        #expect(offlineMixed.firewallClass == .unverified, "Offline valid DOI + invalid arXiv must be UNVERIFIED, not NOT_FOUND")
        #expect(offlineMixed.reasons == ["offline"])

        let replaySnapshot = try RegistryReplaySnapshot(directoryURL: Self.recordedRegistryFixturesURL)
        let onlineMixedZH = try await CitationVerificationFirewall.verifyBibliography(
            entries: [mixedEntry],
            mode: .replay(snapshot: replaySnapshot),
            language: .zhHans
        )
        let mixedVerdictZH = try #require(onlineMixedZH.report.verdicts.first)
        #expect(mixedVerdictZH.firewallClass == .drift)
        #expect(mixedVerdictZH.insertable == false)
        #expect(!mixedVerdictZH.sources.isEmpty, "Must query registry by valid DOI")
        #expect(
            mixedVerdictZH.fields.contains {
                $0.field == "arxivID"
                    && $0.localValue == "not-a-valid-arxiv-99"
                    && ($0.remoteValue.contains("格式不合法") || ($0.note ?? "").contains("格式不合法"))
            },
            "Expected fields to record localValue and '格式不合法', got \(mixedVerdictZH.fields)"
        )

        let onlineMixedEN = try await CitationVerificationFirewall.verifyBibliography(
            entries: [mixedEntry],
            mode: .replay(snapshot: replaySnapshot),
            language: .en
        )
        let mixedVerdictEN = try #require(onlineMixedEN.report.verdicts.first)
        #expect(mixedVerdictEN.firewallClass == .drift)
        #expect(mixedVerdictEN.fields.contains { $0.field == "arxivID" && $0.localValue == "not-a-valid-arxiv-99" })

        // Rule 3b: Entry with ONLY arXiv and malformed format -> still NOT_FOUND (invalid_identifier)
        let onlyBadArXivBib = """
        @misc{only_bad_arxiv,
          author        = {Lovelace, Ada},
          title         = {Only Malformed ArXiv},
          year          = {2024},
          archivePrefix = {arXiv},
          eprint        = {not-a-valid-arxiv-99}
        }
        """
        let onlyBadEntry = try #require(try codec.parse(onlyBadArXivBib).first)
        let onlyBadOffline = CitationVerificationFirewall().evaluate(onlyBadEntry)
        #expect(onlyBadOffline.firewallClass == .notFound)
        #expect(onlyBadOffline.reasons == ["invalid_identifier"])
        let onlyBadOnline = await CitationVerificationFirewall().verifyAgainstPublicRegistries(entry: onlyBadEntry, session: replay)
        #expect(onlyBadOnline.firewallClass == .notFound)
        #expect(onlyBadOnline.reasons == ["invalid_identifier"])
    }
}
