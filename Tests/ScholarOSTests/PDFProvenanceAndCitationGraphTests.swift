import Foundation
import PDFKit
import Testing
import ScholarModels
import ScholarPDFProvenance
import ScholarCitationGraph

@Suite("Multi-Column PDF Provenance, FTS5 Entailment & Citation Graph Analytics")
struct PDFProvenanceAndCitationGraphTests {

    // MARK: - Helpers

    private func makePlantedCitationCorpus() -> [BibliographyEntry] {
        // Community A (Transformers & Attention, 2017-2022)
        let a1 = BibliographyEntry(
            citeKey: "vaswani2017",
            kind: .inproceedings,
            title: "Attention Is All You Need for Sequence Transduction",
            authors: [BibAuthor(givenName: "Ashish", familyName: "Vaswani")],
            year: 2017,
            venue: "NeurIPS",
            doi: "10.5555/3295222.3295349",
            firewallClass: .verified,
            citedByKeys: ["devlin2019", "brown2020", "dao2022", "bridge2023", "burstTarget2020"],
            referencesKeys: []
        )
        let a2 = BibliographyEntry(
            citeKey: "devlin2019",
            kind: .inproceedings,
            title: "BERT Pre-training of Deep Bidirectional Transformers",
            authors: [BibAuthor(givenName: "Jacob", familyName: "Devlin")],
            year: 2019,
            venue: "NAACL",
            doi: "10.18653/v1/N19-1423",
            firewallClass: .verified,
            citedByKeys: ["brown2020", "dao2022"],
            referencesKeys: ["vaswani2017"]
        )
        let a3 = BibliographyEntry(
            citeKey: "brown2020",
            kind: .inproceedings,
            title: "Language Models are Few-Shot Learners with Transformers",
            authors: [BibAuthor(givenName: "Tom", familyName: "Brown")],
            year: 2020,
            venue: "NeurIPS",
            arxivID: "2005.14165",
            firewallClass: .verified,
            citedByKeys: ["dao2022", "bridge2023"],
            referencesKeys: ["vaswani2017", "devlin2019"]
        )
        let a4 = BibliographyEntry(
            citeKey: "dao2022",
            kind: .inproceedings,
            title: "FlashAttention IO-Aware Exact Transformer Kernels",
            authors: [BibAuthor(givenName: "Tri", familyName: "Dao")],
            year: 2022,
            venue: "NeurIPS",
            arxivID: "2205.14135",
            firewallClass: .verified,
            citedByKeys: ["bridge2023"],
            referencesKeys: ["vaswani2017", "devlin2019", "brown2020"]
        )

        // Community B (Systematic Reviews & PRISMA Psychometrics, 2009-2022)
        let b1 = BibliographyEntry(
            citeKey: "moher2009",
            kind: .article,
            title: "Preferred Reporting Items for Systematic Reviews and Meta-Analyses",
            authors: [BibAuthor(givenName: "David", familyName: "Moher")],
            year: 2009,
            venue: "PLOS Medicine",
            doi: "10.1371/journal.pmed.1000097",
            firewallClass: .verified,
            citedByKeys: ["sterne2019", "page2021", "higgins2022", "bridge2023"],
            referencesKeys: []
        )
        let b2 = BibliographyEntry(
            citeKey: "sterne2019",
            kind: .article,
            title: "RoB 2 Revised Tool for Assessing Risk of Bias in Randomised Trials",
            authors: [BibAuthor(givenName: "Jonathan", familyName: "Sterne")],
            year: 2019,
            venue: "BMJ",
            doi: "10.1136/bmj.l4898",
            firewallClass: .verified,
            citedByKeys: ["page2021", "higgins2022"],
            referencesKeys: ["moher2009"]
        )
        let b3 = BibliographyEntry(
            citeKey: "page2021",
            kind: .article,
            title: "The PRISMA 2020 Statement Updated Guideline for Systematic Reviews",
            authors: [BibAuthor(givenName: "Matthew", familyName: "Page")],
            year: 2021,
            venue: "BMJ",
            doi: "10.1136/bmj.n71",
            firewallClass: .verified,
            citedByKeys: ["higgins2022", "bridge2023"],
            referencesKeys: ["moher2009", "sterne2019"]
        )
        let b4 = BibliographyEntry(
            citeKey: "higgins2022",
            kind: .article,
            title: "Cochrane Handbook Meta-Analysis Heterogeneity and Evidence Synthesis",
            authors: [BibAuthor(givenName: "Julian", familyName: "Higgins")],
            year: 2022,
            venue: "Cochrane",
            doi: "10.1002/9781119536604",
            firewallClass: .verified,
            citedByKeys: ["bridge2023"],
            referencesKeys: ["moher2009", "sterne2019", "page2021"]
        )

        // Structural Bridge connecting Community A and Community B
        let bridge = BibliographyEntry(
            citeKey: "bridge2023",
            kind: .article,
            title: "Automated PRISMA Systematic Screening with Transformer Citation Verification",
            authors: [BibAuthor(givenName: "Elena", familyName: "Rostova")],
            year: 2023,
            venue: "JMLR",
            doi: "10.5555/jmlr.2023.bridge",
            firewallClass: .verified,
            citedByKeys: ["frontier2025"],
            referencesKeys: ["vaswani2017", "brown2020", "dao2022", "moher2009", "page2021", "higgins2022"]
        )
        let frontier = BibliographyEntry(
            citeKey: "frontier2025",
            kind: .inproceedings,
            title: "Deterministic Citation Firewalls for Reproducible Evidence Synthesis",
            authors: [BibAuthor(givenName: "Lin", familyName: "Chen")],
            year: 2025,
            venue: "ACL",
            doi: "10.18653/v1/2025.acl-long.42",
            firewallClass: .verified,
            citedByKeys: [],
            referencesKeys: ["bridge2023", "dao2022", "page2021"]
        )

        return [a1, a2, a3, a4, b1, b2, b3, b4, bridge, frontier]
    }

    // MARK: - 1. Synthetic Multi-Page Two-Column PDF Generation & XY-Cut Extraction

    @Test("SyntheticAcademicPDFFixtureGenerator renders real multi-page two-column PDFs across typography presets")
    func syntheticPDFGeneratorRendersMultiPageTwoColumnFixtures() throws {
        let specs = SyntheticAcademicPDFFixtureGenerator.canonicalFixtureSpecifications()
        #expect(!specs.isEmpty)

        let generator = SyntheticAcademicPDFFixtureGenerator()
        let renderedCanonical = try generator.renderAcademicPDF(spec: specs[0])
        #expect(renderedCanonical.pageCount >= 1)

        // Construct an 8-section specification that overflows onto >= 2 two-column pages
        let repeatedSections = (1...8).map { idx in
            SyntheticPaperSectionSpec(
                headingTitle: "\(idx). Asymptotic Tiled Attention Section \(idx)",
                sourceTeXLine: idx * 20,
                elements: [
                    .bodyParagraph(
                        text: "In section \(idx), we establish deterministic memory-hierarchy bounds across high-bandwidth GPU caches, proving that tiled online softmax reduces off-chip HBM read-write traffic by \(80 + idx).4% across 64K sequence lengths while preserving IEEE-754 numerical accuracy.",
                        sourceTeXLine: idx * 20 + 2
                    ),
                    .displayEquation(
                        equationNumber: "(\(idx))",
                        formulaText: "O(N^2 d^2 / M) <= T_HBM(N, d, M)",
                        sourceTeXLine: idx * 20 + 6
                    ),
                    .bodyParagraph(
                        text: "Furthermore, empirical wall-clock profiling across 128 distributed nodes confirms a \(idx).2x end-to-end throughput speedup (p < 0.001) without gradient overflow or attention entropy collapse.",
                        sourceTeXLine: idx * 20 + 10
                    )
                ]
            )
        }
        let multiPageSpec = SyntheticPaperFixtureSpec(
            citeKey: "multipage2026",
            pdfFileName: "multipage2026.pdf",
            typography: .ieeeTransactionsTwoColumn,
            runningVenueBanner: "IEEE Transactions on Academic Systems 2026",
            doiIdentifier: "10.1109/TAS.2026.10042",
            paperTitle: "Multi-Page Two-Column Geometric Pagination and Provenance Verification",
            authorsLine: "Ada Lovelace, Grace Hopper, and Donald Knuth",
            affiliationsLine: "Department of Computer Science, University of Cambridge",
            abstractText: "We present a comprehensive multi-page benchmark evaluating two-column XY-cut geometric extraction, SyncTeX anchor emission, and quantitative claim entailment across dense academic manuscripts.",
            keywords: ["multi-column PDF", "XY-cut", "provenance", "BM25"],
            sections: repeatedSections,
            formattedReferences: [
                "[1] T. Dao et al., FlashAttention: Fast and Memory-Efficient Exact Attention, NeurIPS 2022.",
                "[2] A. Vaswani et al., Attention Is All You Need, NeurIPS 2017."
            ]
        )

        let rendered = try generator.renderAcademicPDF(spec: multiPageSpec)
        #expect(rendered.pdfData.count > 4_000)
        let headerASCII = String(decoding: rendered.pdfData.prefix(5), as: UTF8.self)
        #expect(headerASCII == "%PDF-")
        #expect(rendered.pageCount >= 2)
        #expect(!rendered.groundTruthRegions.isEmpty)
        #expect(!rendered.syncTeXAnchors.isEmpty)
        #expect(!rendered.expectedPassageChunks().isEmpty)

        let pdfDoc = try #require(PDFDocument(data: rendered.pdfData))
        #expect(pdfDoc.pageCount == rendered.pageCount)
    }

    @Test("SyntheticAcademicPDFFixtureGenerator writes PDF to temporary path and renders provenance-highlighted overlay")
    func syntheticPDFGeneratorWritesToTempFileAndRendersProvenanceOverlay() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let generator = SyntheticAcademicPDFFixtureGenerator()
        let spec = SyntheticAcademicPDFFixtureGenerator.canonicalFixtureSpecifications()[0]
        let outURL = tempDir.appendingPathComponent(spec.pdfFileName)

        let rendered = try generator.writeAcademicPDF(spec: spec, to: outURL)
        #expect(FileManager.default.fileExists(atPath: outURL.path))

        let firstRegion = try #require(rendered.groundTruthRegions.first { $0.kind == .bodyParagraph })
        let sampleProvenance = ClaimEvidenceProvenance(
            manuscriptFile: "main.tex",
            manuscriptLine: 18,
            manuscriptClaim: firstRegion.groundTruthText,
            citeKey: rendered.citeKey,
            passageID: firstRegion.id,
            pdfExcerpt: firstRegion.groundTruthText,
            boundingBox: firstRegion.boundingBox,
            bm25Score: 6.4,
            verdict: .groundedEntailment
        )

        let annotatedData = try generator.renderProvenanceAnnotatedPDF(
            sourcePDFData: rendered.pdfData,
            provenances: [sampleProvenance]
        )
        #expect(annotatedData.count > 2_000)
        #expect(PDFDocument(data: annotatedData)?.pageCount == rendered.pageCount)
    }

    @Test("PDFMultiColumnSegmenter preserves left-column-before-right-column XY-cut reading order")
    func multiColumnPDFSegmenterPreservesXYCutColumnReadingOrder() throws {
        let pdfData = SyntheticAcademicPDFBuilder.renderTwoColumnPaperPDF(
            title: "Deterministic Two-Column XY-Cut Geometric Evaluation",
            authors: "Ada Lovelace and Alan Turing",
            abstractParagraph: "Full-width spanning abstract paragraph summarizing multi-column geometric segmentation accuracy across benchmark layouts.",
            leftColumnParagraphs: [
                ("1. Introduction", "LEFT_MARKER_ONE: The left column introduces asymptotic bounds and establishes foundational definitions across lines."),
                ("2. Theoretical Model", "LEFT_MARKER_TWO: Continuing down the left column before crossing the central gutter to the right stream.")
            ],
            rightColumnParagraphs: [
                ("3. Empirical Results", "RIGHT_MARKER_ONE: The right column reports a 94.6% accuracy improvement over heuristic baseline extractors."),
                ("4. Conclusion", "RIGHT_MARKER_TWO: Concluding remarks appear at the bottom of the right column in reading order.")
            ]
        )

        let segmenter = PDFMultiColumnSegmenter()
        let chunks = try segmenter.segmentPDF(data: pdfData, pdfFileName: "twocol.pdf", citeKey: "lovelace2025")
        #expect(chunks.count >= 4)

        let leftChunk = try #require(chunks.first { $0.passageText.contains("LEFT_MARKER_ONE") || $0.columnIndex == 1 })
        let rightChunk = try #require(chunks.first { $0.passageText.contains("RIGHT_MARKER_ONE") || $0.columnIndex == 2 })

        // Left column MUST precede right column in readingSequence!
        #expect(leftChunk.readingSequence < rightChunk.readingSequence)
        #expect(leftChunk.boundingBox.x < rightChunk.boundingBox.x)
    }

    @Test("Multi-column geometric segmentation benchmark verifies column accuracy and token preservation")
    func multiColumnSegmentationBenchmarkReportMetrics() throws {
        let generator = SyntheticAcademicPDFFixtureGenerator()
        let spec = SyntheticAcademicPDFFixtureGenerator.canonicalFixtureSpecifications()[0]
        let report = try generator.benchmarkMultiColumnSegmenter(spec: spec)

        #expect(report.pageCount >= 1)
        #expect(report.extractedPassageChunkCount > 0)
        #expect(report.columnClassificationAccuracy >= 0.70)
        #expect(report.kendallTauReadingOrderCorrelation > 0.50)
        #expect(report.quantitativeTokenPreservationRate >= 0.75)
    }

    // MARK: - 1B. S12 Tectonic Two-Column PDF Segmentation Regression Tests

    private static var pdfSegmentationFixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pdf-segmentation", isDirectory: true)
    }

    @Test("S12-1: Repeating headers and footers are stripped from body chunks and preserved as header/footer chunks")
    func s12RepeatingHeadersAndFootersStrippedFromBodyChunks() throws {
        let pdfURL = Self.pdfSegmentationFixturesURL.appendingPathComponent("s12_paper.pdf")
        let chunks = try PDFMultiColumnSegmenter().segmentPDF(at: pdfURL, citeKey: "rivera2026")

        let bodyChunks = chunks.filter { $0.kind == .body }
        #expect(!bodyChunks.isEmpty)

        for chunk in bodyChunks {
            #expect(!chunk.passageText.contains("Journal of Reproducible Systems"))
            #expect(!chunk.passageText.contains("Lexical Grounding Study"))
            #expect(!chunk.passageText.contains("Preprint Under Review"))
        }

        let headerChunks = chunks.filter { $0.kind == .header }
        let footerChunks = chunks.filter { $0.kind == .footer }
        #expect(headerChunks.count >= 3)
        #expect(footerChunks.count == 3)
        #expect(headerChunks.contains { $0.passageText.contains("Journal of Reproducible Systems") })
        #expect(footerChunks.contains { $0.passageText.contains("Page 1") })
        #expect(footerChunks.contains { $0.passageText.contains("Page 2") })
        #expect(footerChunks.contains { $0.passageText.contains("Page 3") })
    }

    @Test("S12-2: Section headings recognize dotted/undotted Arabic, Roman I-XV, subsections, and References without matching numeric prose")
    func s12SectionHeadingsRecognizedAcrossConventions() throws {
        let segmenter = PDFMultiColumnSegmenter()

        let paperURL = Self.pdfSegmentationFixturesURL.appendingPathComponent("s12_paper.pdf")
        let paperChunks = try segmenter.segmentPDF(at: paperURL, citeKey: "rivera2026")
        let paperHeadings = paperChunks.filter { $0.kind == .sectionHeading }.map(\.passageText)
        #expect(paperHeadings == [
            "Abstract",
            "1 Introduction",
            "2 Related Work",
            "3. Methodology",
            "4 Experimental Evaluation",
            "5 Conclusion",
            "References"
        ])

        // Verify subsequent body chunks inherit the recognized sectionTitle
        let evalBody = try #require(paperChunks.first { $0.kind == .body && $0.passageText.contains("Across 1,240 benchmark queries") })
        #expect(evalBody.sectionTitle == "4 Experimental Evaluation")
        let conclBody = try #require(paperChunks.first { $0.kind == .body && $0.passageText.contains("Separating repeating margin furniture") })
        #expect(conclBody.sectionTitle == "5 Conclusion")
        let refBody = try #require(paperChunks.first { $0.kind == .body && $0.passageText.contains("[1] A. Rivera") })
        #expect(refBody.sectionTitle == "References")

        let ieeeURL = Self.pdfSegmentationFixturesURL.appendingPathComponent("s12_ieeetran.pdf")
        let ieeeChunks = try segmenter.segmentPDF(at: ieeeURL, citeKey: "riveraIEEE2026")
        let ieeeHeadings = ieeeChunks.filter { $0.kind == .sectionHeading }.map(\.passageText)
        #expect(ieeeHeadings == [
            "I. Introduction",
            "II. Related Work",
            "III. Methodology",
            "IV. Experiments",
            "V. Conclusion",
            "References"
        ])

        // Subsections, Roman up to XV, Bibliography, Acknowledgments vs numeric prose traps
        #expect(PDFMultiColumnSegmenter.detectSectionHeading("3.1 Geometric Column Partitioning") == "3.1 Geometric Column Partitioning")
        #expect(PDFMultiColumnSegmenter.detectSectionHeading("XIV. Extended Limitations") == "XIV. Extended Limitations")
        #expect(PDFMultiColumnSegmenter.detectSectionHeading("Bibliography") == "Bibliography")
        #expect(PDFMultiColumnSegmenter.detectSectionHeading("Acknowledgments") == "Acknowledgments")

        #expect(PDFMultiColumnSegmenter.detectSectionHeading("368 regression tests in 14.5 ms on a single CPU core.") == nil)
        #expect(PDFMultiColumnSegmenter.detectSectionHeading("18 distinct conference templates.") == nil)
        #expect(PDFMultiColumnSegmenter.detectSectionHeading("4 GPU nodes were profiled across runs") == nil)
        #expect(PDFMultiColumnSegmenter.detectSectionHeading("4 12.0 24 3.5 98.4%") == nil)
    }

    @Test("S12-3: Long paragraphs preserve trailing words without 520-char truncation loss")
    func s12LongParagraphsPreserveTrailingWordsWithoutTruncationLoss() throws {
        let pdfURL = Self.pdfSegmentationFixturesURL.appendingPathComponent("s12_paper.pdf")
        let chunks = try PDFMultiColumnSegmenter().segmentPDF(at: pdfURL, citeKey: "rivera2026")
        let nonHeaderFooterText = chunks
            .filter { !$0.kind.isHeaderOrFooter }
            .map(\.passageText)
            .joined(separator: " ")

        #expect(nonHeaderFooterText.contains("checks explicit numbers."))
        #expect(!chunks.contains { $0.passageText.hasSuffix("checks ex-") })
    }

    @Test("S12-4: Spanning tables become tableOrFigure chunks and retain narrow column cells")
    func s12SpanningTablesBecomeTableOrFigureChunksWithNarrowCells() throws {
        let pdfURL = Self.pdfSegmentationFixturesURL.appendingPathComponent("s12_paper.pdf")
        let chunks = try PDFMultiColumnSegmenter().segmentPDF(at: pdfURL, citeKey: "rivera2026")

        let tableChunks = chunks.filter { $0.kind == .tableOrFigure }
        #expect(tableChunks.count == 2)

        let table1 = try #require(tableChunks.first { $0.passageText.contains("Table 1:") })
        #expect(table1.boundingBox.pageIndex == 1)
        #expect(table1.passageText.contains("Engine Variant"))
        #expect(table1.passageText.contains("Header Leak Rate"))
        #expect(table1.passageText.contains("Proposed Margin-Trimmed XY"))

        let table2 = try #require(tableChunks.first { $0.passageText.contains("Table 2:") })
        #expect(table2.boundingBox.pageIndex == 2)
        #expect(table2.passageText.contains("Template Family"))

        // Narrow table header cell must not leak into body chunks
        #expect(!chunks.filter { $0.kind == .body }.contains { $0.passageText.contains("Engine Variant") })
    }

    @Test("S12-5: Wide spanning tables do not degrade 1-2 line two-column body text into single-column interleaving")
    func s12WideTablePreservesLeftBeforeRightReadingOrderOnSparseColumns() throws {
        let pdfURL = Self.pdfSegmentationFixturesURL.appendingPathComponent("s12_paper.pdf")
        let chunks = try PDFMultiColumnSegmenter().segmentPDF(at: pdfURL, citeKey: "rivera2026")

        let page3Body = chunks.filter { $0.boundingBox.pageIndex == 2 && $0.kind == .body }
        let leftPage3 = try #require(page3Body.first { $0.passageText.contains("PAGE3_LEFT_1") })
        let rightPage3 = try #require(page3Body.first { $0.passageText.contains("PAGE3_RIGHT_1") })

        #expect(leftPage3.passageText.contains("PAGE3_LEFT_2"))
        #expect(!leftPage3.passageText.contains("PAGE3_RIGHT_1"))
        #expect(leftPage3.columnIndex == 1)
        #expect(rightPage3.columnIndex == 2)
        #expect(leftPage3.readingSequence < rightPage3.readingSequence)

        let page2Body = chunks.filter { $0.boundingBox.pageIndex == 1 && $0.kind == .body }
        let leftPage2 = try #require(page2Body.first { $0.passageText.contains("LEFT_COL_LINE_1") })
        let rightPage2 = try #require(page2Body.first { $0.passageText.contains("RIGHT_COL_LINE_1") })
        #expect(leftPage2.columnIndex == 1)
        #expect(rightPage2.columnIndex == 2)
        #expect(leftPage2.readingSequence < rightPage2.readingSequence)
    }

    // MARK: - 2. SQLite FTS5 BM25 Retrieval & Numeric Claim Entailment Tests

    @Test("FTS5ProvenanceIndex indexes passages in temp SQLite DB and ranks citeKey-filtered BM25 hits")
    func fts5ProvenanceIndexBM25SearchAndCiteKeyFiltering() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-fts5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ftsURL = tempDir.appendingPathComponent("provenance-fts5.sqlite")
        let index = try FTS5ProvenanceIndex(sqliteFileURL: ftsURL)

        let passages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "dao2022#p4-c1-1",
                citeKey: "dao2022",
                pdfFileName: "dao2022.pdf",
                sectionTitle: "Experiments",
                columnIndex: 1,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 3, x: 48, y: 220, width: 240, height: 64),
                passageText: "FlashAttention achieves a 3.2x wall-clock speedup on GPT-2 training while reducing HBM memory traffic by 84.5%."
            ),
            PDFPassageChunk(
                id: "vaswani2017#p8-c2-2",
                citeKey: "vaswani2017",
                pdfFileName: "vaswani2017.pdf",
                sectionTitle: "Machine Translation",
                columnIndex: 2,
                readingSequence: 2,
                boundingBox: PDFPageRegionBox(pageIndex: 7, x: 318, y: 410, width: 240, height: 58),
                passageText: "On WMT 2014 English-to-German translation, the big Transformer model reaches 28.4 BLEU."
            )
        ]

        try index.indexPassages(passages)
        #expect(index.passageCount() == 2)

        let hits = try index.searchPassages(query: "wall-clock speedup HBM memory", citeKeyFilter: "dao2022", limit: 5)
        #expect(hits.count == 1)
        #expect(hits[0].chunk.id == "dao2022#p4-c1-1")
        #expect(hits[0].bm25Magnitude > 0.0)
    }

    @Test("FTS5ProvenanceIndex.verifyClaimProvenance distinguishes GROUNDED vs NUMERIC_MISMATCH vs UNSUPPORTED")
    func fts5VerifyClaimProvenanceVerdicts() throws {
        let index = try FTS5ProvenanceIndex()
        var passages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "dao2022#p4-c1-1",
                citeKey: "dao2022",
                pdfFileName: "dao2022.pdf",
                sectionTitle: "Benchmarks",
                columnIndex: 1,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 3, x: 50, y: 200, width: 230, height: 60),
                passageText: "FlashAttention achieves 3.2x wall-clock training speedup and reduces HBM memory footprint by 84.5% across sequence lengths."
            )
        ]
        // Populate realistic background passages so FTS5 IDF yields positive BM25 discrimination
        for idx in 1...12 {
            passages.append(
                PDFPassageChunk(
                    id: "bg\(idx)#p1-c1",
                    citeKey: "bg\(idx)",
                    pdfFileName: "bg\(idx).pdf",
                    sectionTitle: "Related Literature",
                    columnIndex: 1,
                    readingSequence: idx,
                    boundingBox: PDFPageRegionBox(pageIndex: 0, x: 48, y: 120, width: 220, height: 50),
                    passageText: "Classical dynamic programming alignment and syntactic parsing over discrete symbolic trees in cohort \(idx)."
                )
            )
        }
        try index.indexPassages(passages)

        // 1. Exact quantitative agreement -> GROUNDED
        let grounded = try index.verifyClaimProvenance(
            manuscriptFile: "main.tex",
            manuscriptLine: 14,
            claimSentence: "FlashAttention achieves 3.2x wall-clock training speedup and reduces HBM memory footprint by 84.5% \\cite{dao2022}.",
            citeKey: "dao2022"
        )
        #expect(grounded.verdict == .groundedEntailment)
        #expect(grounded.bm25Score >= 2.2)

        // 2. Fabricated/inflated number (9.8x instead of 3.2x) -> NUMERIC_MISMATCH
        let distorted = try index.verifyClaimProvenance(
            manuscriptFile: "main.tex",
            manuscriptLine: 19,
            claimSentence: "FlashAttention achieves 9.8x wall-clock training speedup and reduces HBM memory footprint by 99.1% \\cite{dao2022}.",
            citeKey: "dao2022"
        )
        #expect(distorted.verdict == .numericDiscrepancy)

        // 3. Unindexed citeKey -> UNSUPPORTED
        let unsupported = try index.verifyClaimProvenance(
            manuscriptFile: "main.tex",
            manuscriptLine: 25,
            claimSentence: "Protein folding converges in 12 picoseconds \\cite{unknown2024}.",
            citeKey: "unknown2024"
        )
        #expect(unsupported.verdict == .unsupportedClaim)
    }

    @Test("NumericClaimAndCitationEntailmentAuditor extracts units, speedups, p-values, and audits manuscript claims")
    func numericClaimAuditorUnitConversionRoundingAndDistortionDetection() throws {
        let auditor = NumericClaimAndCitationEntailmentAuditor()

        let tokens = auditor.extractQuantitativeTokens(
            from: "Latency dropped to 14.5 ms (3.2x speedup, 84.5% reduction, p < 0.01, N = 1200)."
        )
        let kinds = Set(tokens.map(\.kind))
        #expect(kinds.contains(.latencyOrDuration))
        #expect(kinds.contains(.speedupOrMultiplier))
        #expect(kinds.contains(.percentage))
        #expect(kinds.contains(.pValueSignificance))

        let passages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "kernel2024#p3-c1-1",
                citeKey: "kernel2024",
                pdfFileName: "kernel2024.pdf",
                sectionTitle: "Latency",
                columnIndex: 1,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 2, x: 48, y: 300, width: 240, height: 60),
                passageText: "Our fused attention kernel reduces median inference latency to 14.5 ms with a 3.2x throughput speedup and 84.5% memory savings."
            )
        ]

        let manuscript = """
        \\section{Related Work}
        Fused attention kernels reduce median inference latency to 14.5 ms with a 3.2x throughput speedup \\cite{kernel2024}.
        However, an inflated draft erroneously claims fused attention latency reaches 2.1 ms with a 15.0x throughput speedup \\cite{kernel2024}.
        """

        let report = auditor.auditManuscriptAgainstPassages(
            manuscriptSource: manuscript,
            filePath: "main.tex",
            passages: passages
        )
        #expect(report.totalCitedClaimsAudited == 2)
        #expect(report.groundedEntailmentCount >= 1)
        #expect(report.numericDiscrepancyCount >= 1)
        #expect(!report.lspDiagnostics.isEmpty)
    }

    @Test("Canonical provenance benchmark bundle end-to-end FTS5 + numeric entailment audit")
    func canonicalProvenanceBenchmarkBundleEndToEndAudit() throws {
        let generator = SyntheticAcademicPDFFixtureGenerator()
        let bundle = try generator.buildCanonicalBenchmarkBundle()
        #expect(!bundle.fixtures.isEmpty)
        #expect(!bundle.bibliographyEntries.isEmpty)

        let index = try FTS5ProvenanceIndex()
        for fixture in bundle.fixtures {
            try index.indexPassages(fixture.expectedPassageChunks())
        }
        #expect(index.passageCount() > 0)

        let auditor = NumericClaimAndCitationEntailmentAuditor()
        let report = try auditor.auditManuscriptAgainstIndex(
            manuscriptSource: bundle.sampleManuscriptWithGroundedAndMismatchedClaims,
            filePath: "main.tex",
            provenanceIndex: index
        )
        #expect(report.totalCitedClaimsAudited >= 2)
        #expect(report.groundedEntailmentCount >= 1)
        #expect(report.numericDiscrepancyCount >= 1)
    }

    // MARK: - 3. Barnes-Hut Quadtree Layout, PageRank, Louvain, Brandes, Bursts & Main Path Tests

    @Test("BarnesHutGraphLayoutEngine converges to finite non-NaN bounded coordinates on 64-node network")
    func barnesHutQuadtreeLayoutFiniteNonNaNConvergence() {
        var nodes: [CitationGraphNode] = []
        var edges: [CitationGraphEdge] = []

        for i in 0..<64 {
            nodes.append(
                CitationGraphNode(
                    citeKey: "paper_\(i)",
                    title: "Synthetic Graph Node \(i)",
                    authorYearLabel: "Author \(i) (\(2000 + (i % 25)))",
                    year: 2000 + (i % 25),
                    inDegree: i == 0 ? 20 : 1,
                    outDegree: 2,
                    clusterIndex: i % 4
                )
            )
            if i > 0 {
                edges.append(CitationGraphEdge(
                    sourceCiteKey: "paper_\(i)",
                    targetCiteKey: "paper_\(i / 2)",
                    kind: .directCitation
                ))
            }
        }

        let config = BarnesHutLayoutConfig(
            iterations: 90,
            theta: 0.72,
            canvasWidth: 1200.0,
            canvasHeight: 800.0
        )
        let laidOut = BarnesHutGraphLayoutEngine(config: config).computeLayout(nodes: nodes, edges: edges)

        #expect(laidOut.count == 64)
        for node in laidOut {
            #expect(node.x.isFinite && !node.x.isNaN)
            #expect(node.y.isFinite && !node.y.isNaN)
            #expect(node.x >= 0.0 && node.x <= 1200.0)
            #expect(node.y >= 0.0 && node.y <= 800.0)
        }

        let xs = laidOut.map(\.x)
        let ys = laidOut.map(\.y)
        #expect((xs.max()! - xs.min()!) > 50.0)
        #expect((ys.max()! - ys.min()!) > 50.0)
    }

    @Test("CitationGraphBuilder PageRank probabilities sum to ~1.0 and rank foundational hubs highest")
    func citationGraphBuilderPageRankProbabilityConservationAndHubRanking() throws {
        let corpus = makePlantedCitationCorpus()
        let builder = CitationGraphBuilder(layoutConfig: BarnesHutLayoutConfig(iterations: 60))
        let snapshot = builder.buildKnowledgeGraph(from: corpus)

        #expect(snapshot.nodes.count == corpus.count)
        #expect(!snapshot.edges.isEmpty)

        let pageRankSum = snapshot.nodes.map(\.pageRank).reduce(0.0, +)
        #expect(abs(pageRankSum - 1.0) < 1e-3)

        for node in snapshot.nodes {
            #expect(node.pageRank > 0.0 && node.pageRank.isFinite)
            #expect(node.x.isFinite && node.y.isFinite)
        }

        let vaswaniPR = try #require(snapshot.nodes.first { $0.citeKey == "vaswani2017" }?.pageRank)
        let frontierPR = try #require(snapshot.nodes.first { $0.citeKey == "frontier2025" }?.pageRank)
        // Foundational hub cited by 5 papers must strictly exceed uncited 2025 leaf!
        #expect(vaswaniPR > frontierPR)
    }

    @Test("LouvainModularityAndBridgeDetector recovers planted communities with positive modularity Q")
    func louvainCommunityPartitionPositiveModularityAndSeparation() {
        let corpus = makePlantedCitationCorpus()
        let detector = LouvainModularityAndBridgeDetector(resolutionGamma: 1.0)
        let partition = detector.detectLouvainCommunities(entries: corpus)

        #expect(partition.communities.count >= 2)
        #expect(partition.modularityQ > 0.15)
        #expect(partition.modularityQ <= 1.0)
        #expect(partition.communityByCiteKey.count == corpus.count)

        // Foundational Transformer paper and foundational PRISMA paper belong to distinct thematic communities!
        #expect(partition.communityByCiteKey["vaswani2017"] != partition.communityByCiteKey["moher2009"])
    }

    @Test("Brandes betweenness centrality and Burt structural-hole constraint pinpoint cross-cluster bridge paper")
    func brandesBetweennessAndBurtConstraintIdentifyStructuralBridge() throws {
        let corpus = makePlantedCitationCorpus()
        let detector = LouvainModularityAndBridgeDetector()
        let partition = detector.detectLouvainCommunities(entries: corpus)
        let profiles = detector.analyzeStructuralBridges(entries: corpus, partition: partition)

        #expect(profiles.count == corpus.count)
        let bridgeProfile = try #require(profiles.first { $0.citeKey == "bridge2023" })
        #expect(bridgeProfile.distinctNeighborCommunitiesCount >= 2)
        #expect(bridgeProfile.unweightedBetweenness > 0.0)
        #expect(bridgeProfile.participationCoefficient > 0.30)
        #expect(bridgeProfile.isStructuralHoleBridge || bridgeProfile.compositeBridgeScore > 0.25)

        // Verify Guimera-Amaral cartographic role classifier directly
        #expect(NetworkCartographicRole.classify(withinModuleZ: 3.0, participationP: 0.80) == .kinlessGlobalHub)
        #expect(NetworkCartographicRole.classify(withinModuleZ: 1.2, participationP: 0.70) == .nonHubConnectorBridge)
        #expect(NetworkCartographicRole.classify(withinModuleZ: 0.5, participationP: 0.01) == .ultraPeripheral)
    }

    @Test("Co-citation C = A^T A and bibliographic coupling B = A A^T matrix symmetry and Salton cosine bounds")
    func coCitationAndBibliographicCouplingMatrixSymmetry() {
        let corpus = makePlantedCitationCorpus()
        let analysis = LouvainModularityAndBridgeDetector().buildCoCitationAndCouplingMatrices(entries: corpus)
        let n = analysis.orderedCiteKeys.count
        #expect(n == corpus.count)

        for i in 0..<n {
            for j in 0..<n {
                #expect(analysis.coCitationMatrixC[i][j] == analysis.coCitationMatrixC[j][i])
                #expect(analysis.bibliographicCouplingMatrixB[i][j] == analysis.bibliographicCouplingMatrixB[j][i])
                let cosC = analysis.normalizedCoCitationCosine[i][j]
                let cosB = analysis.normalizedCouplingCosine[i][j]
                #expect(cosC >= -1e-9 && cosC <= 1.0 + 1e-9)
                #expect(cosB >= -1e-9 && cosB <= 1.0 + 1e-9)
            }
        }
        #expect(!analysis.topCoCitedPairs.isEmpty)
        #expect(!analysis.topBibliographicallyCoupledPairs.isEmpty)
    }

    @Test("Kleinberg 2-state/K-state Viterbi burst detector identifies concentrated temporal citation surge")
    func kleinbergTemporalCitationAndKeywordBurstDetection() {
        var entries: [BibliographyEntry] = [
            BibliographyEntry(
                citeKey: "seminal2016",
                kind: .article,
                title: "Foundational Neural Scaling Architecture",
                authors: [BibAuthor(givenName: "Kaiming", familyName: "He")],
                year: 2016,
                venue: "CVPR",
                doi: "10.1109/CVPR.2016.90",
                firewallClass: .verified
            ),
            BibliographyEntry(
                citeKey: "steady2016",
                kind: .article,
                title: "Classical Numerical Linear Algebra Baseline",
                authors: [BibAuthor(givenName: "Gene", familyName: "Golub")],
                year: 2016,
                venue: "SIAM",
                doi: "10.1137/1600001",
                firewallClass: .verified
            )
        ]

        // Baseline background publications 2017-2021 (sparse citations to seminal2016)
        for yr in 2017...2021 {
            for idx in 1...4 {
                entries.append(
                    BibliographyEntry(
                        citeKey: "bg_\(yr)_\(idx)",
                        kind: .article,
                        title: "Classical Optimization Iterative Solver Study \(yr) \(idx)",
                        authors: [BibAuthor(givenName: "Res", familyName: "Author\(idx)")],
                        year: yr,
                        venue: "SIAM",
                        doi: "10.1137/\(yr).\(idx)",
                        firewallClass: .verified,
                        referencesKeys: idx == 1 ? ["steady2016"] : []
                    )
                )
            }
        }

        // Massive citation & keyword burst in 2023-2024 citing `seminal2016` with "QuantumAgentic" keyword!
        for yr in 2023...2024 {
            for idx in 1...10 {
                entries.append(
                    BibliographyEntry(
                        citeKey: "surge_\(yr)_\(idx)",
                        kind: .inproceedings,
                        title: "QuantumAgentic Verification Scaling Framework \(yr) \(idx)",
                        authors: [BibAuthor(givenName: "Burst", familyName: "Author\(idx)")],
                        year: yr,
                        venue: "NeurIPS",
                        doi: "10.5555/\(yr).\(idx)",
                        firewallClass: .verified,
                        referencesKeys: ["seminal2016"]
                    )
                )
            }
        }

        let report = LouvainModularityAndBridgeDetector().detectKleinbergTemporalBursts(
            entries: entries,
            scalingBaseS: 1.8,
            transitionGamma: 0.8,
            stateCountK: 4
        )
        #expect(report.minYear == 2016)
        #expect(report.maxYear == 2024)
        #expect(!report.paperCitationBursts.isEmpty || !report.topicalKeywordBursts.isEmpty)
        if let topPaperBurst = report.paperCitationBursts.first {
            #expect(topPaperBurst.burstStrengthWeight > 0.0)
            #expect(topPaperBurst.peakStateLevel >= 1)
        }
    }

    @Test("Hummon-Doreian SPC, SPLC, and SPNP main-path knowledge trajectory analysis")
    func hummonDoreianMainPathSPCAndSPLCAnalysis() {
        let corpus = makePlantedCitationCorpus()
        let analyzer = MainPathAndLiteratureGapAnalyzer(currentReferenceYear: 2026)

        let spcReport = analyzer.analyzeMainPaths(entries: corpus, variant: .searchPathCountSPC)
        #expect(spcReport.totalDAGNodes == corpus.count)
        #expect(spcReport.totalKnowledgeFlowEdges > 0)
        #expect(spcReport.totalSourceToSinkPaths >= 1.0)
        #expect(spcReport.foundationalOriginCiteKeys.contains("vaswani2017") || spcReport.foundationalOriginCiteKeys.contains("moher2009"))
        #expect(spcReport.researchFrontierSinkCiteKeys.contains("frontier2025"))
        #expect(spcReport.globalMainPath.orderedCiteKeys.count >= 3)
        #expect(spcReport.globalMainPath.startYear <= spcReport.globalMainPath.endYear)

        let splcReport = analyzer.analyzeMainPaths(entries: corpus, variant: .searchPathLinkCountSPLC)
        let spnpReport = analyzer.analyzeMainPaths(entries: corpus, variant: .searchPathNodePairSPNP)
        #expect(!splcReport.rankedKnowledgeLinks.isEmpty)
        #expect(!spnpReport.rankedKnowledgeLinks.isEmpty)
    }

    @Test("Literature gap analyzer recommends uncited foundational/coupled papers and excludes blocked hallucinations")
    func literatureGapRecommenderFindsMissingSeminalWorksAndExcludesBlockedEntries() {
        var corpus = makePlantedCitationCorpus()
        // Inject a firewall-blocked hallucinated paper co-cited heavily — recommender MUST NOT suggest blocked papers!
        corpus.append(
            BibliographyEntry(
                citeKey: "smith2025hallucinated",
                kind: .article,
                title: "Hallucinated Transformer PRISMA Paper",
                authors: [BibAuthor(givenName: "John", familyName: "Smith")],
                year: 2025,
                venue: "Fake Venue",
                doi: "10.9999/fake.999",
                firewallClass: .notFound,
                citedByKeys: ["dao2022", "bridge2023"],
                referencesKeys: ["vaswani2017", "page2021"]
            )
        )

        // Manuscript cites `dao2022` and `higgins2022`, omitting foundational `vaswani2017`, `moher2009`, `page2021`, and `bridge2023`!
        let manuscript = """
        \\section{Introduction}
        Recent IO-aware attention kernels \\cite{dao2022} and meta-analytic synthesis \\cite{higgins2022} motivate our system.
        """

        let analyzer = MainPathAndLiteratureGapAnalyzer(currentReferenceYear: 2026)
        let gapReport = analyzer.recommendMissingCitationsForManuscript(
            manuscriptSource: manuscript,
            corpus: corpus,
            maxRecommendations: 8
        )

        #expect(gapReport.manuscriptCitedKeys.sorted() == ["dao2022", "higgins2022"])
        #expect(!gapReport.recommendations.isEmpty)
        let recommendedKeys = Set(gapReport.recommendations.map(\.citeKey))
        // Must recommend foundational / co-cited pillars like `vaswani2017`, `moher2009`, or `page2021`
        #expect(recommendedKeys.contains("vaswani2017") || recommendedKeys.contains("moher2009") || recommendedKeys.contains("page2021"))
        // Must NEVER recommend already-cited keys or firewall-blocked `smith2025hallucinated`!
        #expect(!recommendedKeys.contains("dao2022"))
        #expect(!recommendedKeys.contains("smith2025hallucinated"))
    }

    @Test("Citation network interactive SVG and LaTeX TikZ vector exports produce valid standalone markup")
    func citationNetworkSVGAndTikZExportMarkup() {
        let corpus = makePlantedCitationCorpus()
        let snapshot = CitationGraphBuilder(layoutConfig: BarnesHutLayoutConfig(iterations: 40)).buildKnowledgeGraph(from: corpus)
        let analyzer = MainPathAndLiteratureGapAnalyzer(currentReferenceYear: 2026)
        let mainPath = analyzer.analyzeMainPaths(entries: corpus)

        let svg = analyzer.exportInteractiveCitationNetworkSVG(snapshot: snapshot, mainPathReport: mainPath)
        #expect(svg.contains("<svg"))
        #expect(svg.contains("</svg>"))
        #expect(svg.contains("vaswani2017"))

        let tikz = analyzer.exportLaTeXTikZCitationNetwork(snapshot: snapshot, mainPathReport: mainPath)
        #expect(tikz.contains("\\begin{tikzpicture}"))
        #expect(tikz.contains("\\end{tikzpicture}"))
    }

    @Test("PDFMultiColumnSegmenter throws structured pdfExtractionFailure on invalid PDF data")
    func pdfSegmenterThrowsCleanErrorOnCorruptedPDFBytes() {
        let segmenter = PDFMultiColumnSegmenter()
        let corruptBytes = Data("NOT_A_VALID_PDF_HEADER".utf8)
        #expect(throws: ScholarOSError.self) {
            _ = try segmenter.segmentPDF(data: corruptBytes, pdfFileName: "corrupt.pdf", citeKey: "bad2025")
        }
    }

    @Test("Numeric entailment auditor verifies p-value inequality entailment vs significance inflation")
    func numericAuditorPValueInequalityEntailmentAndUnitEquivalence() {
        let auditor = NumericClaimAndCitationEntailmentAuditor()
        let passages = [
            PDFPassageChunk(
                id: "trial2023#p5-c1-1",
                citeKey: "trial2023",
                pdfFileName: "trial2023.pdf",
                sectionTitle: "Results",
                columnIndex: 1,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 4, x: 50, y: 300, width: 220, height: 50),
                passageText: "Intervention reduced error rates significantly across cohorts (p = 0.008, latency 15 ms)."
            )
        ]

        // p = 0.008 in PDF entails claim p < 0.05, and 0.015 s equals 15 ms!
        let validManuscript = "Intervention reduced error rates significantly across cohorts (p < 0.05, latency 0.015 s) \\cite{trial2023}."
        let validAudit = auditor.auditManuscriptAgainstPassages(
            manuscriptSource: validManuscript,
            filePath: "main.tex",
            passages: passages
        )
        #expect(validAudit.numericDiscrepancyCount == 0)

        // Claiming p < 0.001 when PDF only achieved p = 0.008 is significance inflation!
        let inflatedManuscript = "Intervention reduced error rates significantly across cohorts (p < 0.001) \\cite{trial2023}."
        let inflatedAudit = auditor.auditManuscriptAgainstPassages(
            manuscriptSource: inflatedManuscript,
            filePath: "main.tex",
            passages: passages
        )
        #expect(inflatedAudit.numericDiscrepancyCount == 1)
    }

    @Test("MainPathAndLiteratureGapAnalyzer breaks mutual-citation cycles into a valid DAG without hanging")
    func mainPathFeedbackArcBreakingHandlesMutualCitationCycles() {
        let cyclicEntries: [BibliographyEntry] = [
            BibliographyEntry(
                citeKey: "origin2018",
                title: "Origin Foundation",
                authors: [BibAuthor(givenName: "A", familyName: "Origin")],
                year: 2018,
                doi: "10.1000/origin",
                firewallClass: .verified,
                citedByKeys: ["cycleA2021"]
            ),
            BibliographyEntry(
                citeKey: "cycleA2021",
                title: "Concurrent Study A",
                authors: [BibAuthor(givenName: "B", familyName: "Alpha")],
                year: 2021,
                doi: "10.1000/cycleA",
                firewallClass: .verified,
                citedByKeys: ["cycleB2021", "sink2024"],
                referencesKeys: ["origin2018", "cycleB2021"]
            ),
            BibliographyEntry(
                citeKey: "cycleB2021",
                title: "Concurrent Study B",
                authors: [BibAuthor(givenName: "C", familyName: "Beta")],
                year: 2021,
                doi: "10.1000/cycleB",
                firewallClass: .verified,
                citedByKeys: ["cycleA2021", "sink2024"],
                referencesKeys: ["cycleA2021"]
            ),
            BibliographyEntry(
                citeKey: "sink2024",
                title: "Frontier Synthesis",
                authors: [BibAuthor(givenName: "D", familyName: "Sink")],
                year: 2024,
                doi: "10.1000/sink",
                firewallClass: .verified,
                referencesKeys: ["cycleA2021", "cycleB2021"]
            )
        ]

        let report = MainPathAndLiteratureGapAnalyzer().analyzeMainPaths(entries: cyclicEntries)
        #expect(report.totalDAGNodes == 4)
        #expect(report.feedbackArcsBrokenForDAG >= 1)
        #expect(!report.globalMainPath.orderedCiteKeys.isEmpty)
    }
}
