import Foundation
import Testing
import ScholarModels
import ScholarBibAndCSL

@Suite("BibTeX/RIS/NBIB Codecs, Deduplication, 5-Style CSL & Citation Firewall")
struct BibCSLAndFirewallTests {

    // MARK: - Helpers

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
        #expect(verdict.auditNote.contains("内置名单，不完整"))
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
}
