import Foundation
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

        // 5. Sentinel / malformed DOI offline -> NOT_FOUND
        let blocked = makeHallucinatedSmithEntry()
        let v5 = firewall.evaluate(blocked)
        #expect(v5.firewallClass == .notFound)
        #expect(!v5.allowsManuscriptInsertion)
    }

    @Test("Firewall hard-blocks smith2025hallucinated, retracted DOIs, and unverified entries with ERR_UNVERIFIED_CITATION")
    func firewallHardBlocksSmith2025HallucinatedAndRetractedDOIsWithErrUnverifiedCitation() throws {
        let firewall = CitationVerificationFirewall()
        let vaswani = makeVaswaniEntry()
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
            vaswani.citeKey: vaswani,
            smithFake.citeKey: smithFake,
            wakefieldRetracted.citeKey: wakefieldRetracted,
            offlineOnly.citeKey: offlineOnly
        ]

        // Verified entry clears hardware gate
        let cleared = try firewall.assertCitationAllowed(citeKey: "vaswani2017attention", in: library)
        #expect(cleared.citeKey == "vaswani2017attention")

        // Blocked hallucinated key throws ERR_UNVERIFIED_CITATION
        for forbiddenKey in ["smith2025hallucinated", "wakefield1998retracted", "offline2024draft", "missingKey999"] {
            do {
                _ = try firewall.assertCitationAllowed(citeKey: forbiddenKey, in: library)
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
        #expect(report.verifiedCount == 0)
        #expect(report.driftCount == 0)
        #expect(report.retractedCount == 0)
        #expect(report.unverifiedCount == 3)
        #expect(report.notFoundCount == 1)
        #expect(report.manuscriptInsertionAllowedCount == 0)
        #expect(abs(report.insertionPassRate - 0.0) < 1e-9)
        #expect(report.blockedCiteKeys == ["smith2025hallucinated"])
        #expect(report.unverifiedCiteKeys == ["vaswani2017attention", "arxiv2023valid", "offline2022tech"])
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
        // Both ways of reaching RETRACTED offline say that the list is built in and incomplete, in English.
        #expect(firewall.evaluate(samples[0]).auditNote.contains("built-in list, incomplete"))
        #expect(firewall.evaluate(samples[1]).firewallClass == .retracted)
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

        let firewall = CitationVerificationFirewall()
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
        #expect(notFoundVerdict.firewallClass.rawValue == "NOT_FOUND")
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
        #expect(imported.contains { $0.firewallClass == .notFound })

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
        #expect(urls.count == 2)
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
        #expect(sources.count == 1)
        #expect(sources.first?["origin"] as? String == "replay")
        #expect(sources.first?["status"] as? Int == 200)
        #expect((sources.first?["url"] as? String) == "https://api.crossref.org/works/10.1038/nature14539")

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
        let firewall = CitationVerificationFirewall()
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
}
