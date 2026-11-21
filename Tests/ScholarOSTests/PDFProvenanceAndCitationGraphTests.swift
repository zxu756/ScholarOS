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

    @Test("S12-6: All-caps REFERENCES heading and bracketed bibliography items remain body chunks while genuine spanning table stays tableOrFigure")
    func s12AllCapsReferencesAndBibliographyExcludedFromTableWhileSpanningTablePreserved() throws {
        let pdfURL = Self.pdfSegmentationFixturesURL.appendingPathComponent("s12_acm_refs.pdf")
        let chunks = try PDFMultiColumnSegmenter().segmentPDF(at: pdfURL, citeKey: "riveraACM2026")

        let headings = chunks.filter { $0.kind == .sectionHeading }.map(\.passageText)
        #expect(headings == [
            "ABSTRACT",
            "1 INTRODUCTION",
            "2 METHODOLOGY",
            "3 EXPERIMENTS",
            "4 CONCLUSION",
            "REFERENCES"
        ])

        #expect(PDFMultiColumnSegmenter.detectSectionHeading("REFERENCES") == "REFERENCES")
        #expect(PDFMultiColumnSegmenter.detectSectionHeading("BIBLIOGRAPHY") == "BIBLIOGRAPHY")

        // Genuine cross-column Table 1 on Page 2 must still be classified as tableOrFigure (col == 0)
        let tableChunks = chunks.filter { $0.kind == .tableOrFigure }
        let spanningTable = try #require(tableChunks.first { $0.passageText.contains("Table 1: Cross-column evaluation") })
        #expect(spanningTable.columnIndex == 0)
        #expect(spanningTable.boundingBox.pageIndex == 1)
        #expect(spanningTable.passageText.contains("Model Variant"))
        #expect(spanningTable.passageText.contains("Proposed Listwise Model"))

        // Reference heading, bibliography entries, and prose cross-references must never become tableOrFigure
        #expect(!tableChunks.contains { $0.passageText.contains("REFERENCES") })
        #expect(!tableChunks.contains { $0.passageText.contains("[1] Qingyao Ai") })
        #expect(!tableChunks.contains { $0.passageText.contains("[6] Changhua Pei") })
        #expect(!tableChunks.contains { $0.passageText.contains("Table 1 reports ranking performance") })

        let proseRef = try #require(chunks.first { $0.kind == .body && $0.passageText.contains("Table 1 reports ranking performance") })
        #expect(proseRef.columnIndex == 1)
        #expect(proseRef.sectionTitle == "3 EXPERIMENTS")

        let leftBib = try #require(chunks.first { $0.kind == .body && $0.passageText.contains("[1] Qingyao Ai") })
        let rightBib = try #require(chunks.first { $0.kind == .body && $0.passageText.contains("[6] Changhua Pei") })
        #expect(leftBib.sectionTitle == "REFERENCES")
        #expect(rightBib.sectionTitle == "REFERENCES")
        #expect(leftBib.columnIndex == 1)
        #expect(rightBib.columnIndex == 2)
        #expect(leftBib.readingSequence < rightBib.readingSequence)
        #expect(!leftBib.passageText.contains("Changhua Pei"))
    }

    @Test("S12-7: Display equations and inline math in two-column prose do not become spanning tables or swallow section headings")
    func s12DisplayEquationsInTwoColumnProsePreserveHeadingsAndColumns() throws {
        let pdfURL = Self.pdfSegmentationFixturesURL.appendingPathComponent("s12_math_columns.pdf")
        let chunks = try PDFMultiColumnSegmenter().segmentPDF(at: pdfURL, citeKey: "ovchinnikova2026")

        let headings = chunks.filter { $0.kind == .sectionHeading }.map(\.passageText)
        #expect(headings == [
            "Abstract",
            "1. Introduction",
            "2. Stochastic Dynamics and Operators",
            "3. Global Symmetries and Supergauge Field",
            "4. Effective Field Theory",
            "5. Generating Functional",
            "6. Conclusion",
            "References"
        ])

        let tableChunks = chunks.filter { $0.kind == .tableOrFigure }
        #expect(tableChunks.isEmpty)

        // All body chunks after front-matter/abstract must belong to column 1 or column 2, never column 0
        let twoColumnBody = chunks.filter {
            $0.kind == .body
            && $0.sectionTitle != "Front Matter & Abstract"
            && $0.sectionTitle != "Abstract"
        }
        #expect(!twoColumnBody.isEmpty)
        for chunk in twoColumnBody {
            #expect(chunk.columnIndex == 1 || chunk.columnIndex == 2)
        }

        let sec3Body = try #require(twoColumnBody.first { $0.passageText.contains("The topological symmetry is defined") })
        let page2RightBody = try #require(twoColumnBody.first { $0.passageText.contains("represents the spatial densities") })
        let sec5Body = try #require(twoColumnBody.first { $0.passageText.contains("Once the effective action is established") })
        #expect(sec3Body.columnIndex == 1)
        #expect(page2RightBody.columnIndex == 2)
        #expect(sec3Body.readingSequence < page2RightBody.readingSequence)
        #expect(!sec3Body.passageText.contains("exp(c(x)"))
        #expect(sec5Body.columnIndex == 2)
        #expect(sec5Body.sectionTitle == "5. Generating Functional")
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

    @Test("FTS5ProvenanceIndex.locateClaimEvidence distinguishes FOUND vs NUMERIC_MISMATCH vs NOT_FOUND")
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

        // 1. Exact quantitative agreement -> FOUND
        let found = try index.locateClaimEvidence(
            claim: "FlashAttention achieves 3.2x wall-clock training speedup and reduces HBM memory footprint by 84.5% \\cite{dao2022}.",
            citeKeyFilter: "dao2022"
        )
        #expect(found.verdict == .found)
        #expect(found.page == 4)
        #expect(found.pageIndex == 3)
        #expect((found.coverage ?? 0.0) >= 0.60)

        // 2. Fabricated/inflated number (9.8x instead of 3.2x) -> NUMERIC_MISMATCH
        let distorted = try index.locateClaimEvidence(
            claim: "FlashAttention achieves 9.8x wall-clock training speedup and reduces HBM memory footprint by 99.1% \\cite{dao2022}.",
            citeKeyFilter: "dao2022"
        )
        #expect(distorted.verdict == .numericMismatch)
        #expect(!distorted.discrepancies.isEmpty)

        // 3. Unindexed citeKey -> NOT_FOUND
        let notFound = try index.locateClaimEvidence(
            claim: "Protein folding converges in 12 picoseconds \\cite{unknown2024}.",
            citeKeyFilter: "unknown2024"
        )
        #expect(notFound.verdict == .notFound)
        #expect(notFound.matches.isEmpty)
    }

    @Test("EvidenceLocatorAndNumericChecker extracts units, speedups, p-values, and checks manuscript claims")
    func numericClaimAuditorUnitConversionRoundingAndDistortionDetection() throws {
        let locator = EvidenceLocatorAndNumericChecker()

        let tokens = locator.extractQuantitativeBindings(
            from: "Latency dropped to 14.5 ms (3.2x speedup, 84.5% reduction, p < 0.01, N = 1200)."
        )
        let families = Set(tokens.map(\.family))
        #expect(families.contains(.duration))
        #expect(families.contains(.multiplier))
        #expect(families.contains(.percent))
        #expect(families.contains(.pValue))
        #expect(families.contains(.sampleSize))

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

        let report = locator.locateManuscriptClaims(
            manuscriptSource: manuscript,
            filePath: "main.tex",
            passages: passages
        )
        #expect(report.totalCitedClaimsChecked == 2)
        #expect(report.foundCount >= 1)
        #expect(report.numericMismatchCount >= 1)
        #expect(!report.lspDiagnostics.isEmpty)
    }

    @Test("Canonical provenance benchmark bundle end-to-end FTS5 + evidence localization check")
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

        let locator = EvidenceLocatorAndNumericChecker()
        let report = try locator.locateManuscriptClaims(
            manuscriptSource: bundle.sampleManuscriptWithGroundedAndMismatchedClaims,
            filePath: "main.tex",
            provenanceIndex: index
        )
        #expect(report.totalCitedClaimsChecked >= 2)
        #expect(report.foundCount >= 1)
        #expect(report.numericMismatchCount >= 1)
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

    @Test("EvidenceLocatorAndNumericChecker verifies p-value inequality compatibility vs significance inflation")
    func numericAuditorPValueInequalityEntailmentAndUnitEquivalence() {
        let locator = EvidenceLocatorAndNumericChecker()
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

        // p = 0.008 in PDF satisfies claim p < 0.05, and 0.015 s equals 15 ms -> FOUND
        let validManuscript = "Intervention reduced error rates significantly across cohorts (p < 0.05, latency 0.015 s) \\cite{trial2023}."
        let validReport = locator.locateManuscriptClaims(
            manuscriptSource: validManuscript,
            filePath: "main.tex",
            passages: passages
        )
        #expect(validReport.foundCount == 1)
        #expect(validReport.numericMismatchCount == 0)

        // Claiming p < 0.001 when PDF only achieved p = 0.008 is significance inflation -> NUMERIC_MISMATCH
        let inflatedManuscript = "Intervention reduced error rates significantly across cohorts (p < 0.001) \\cite{trial2023}."
        let inflatedReport = locator.locateManuscriptClaims(
            manuscriptSource: inflatedManuscript,
            filePath: "main.tex",
            passages: passages
        )
        #expect(inflatedReport.numericMismatchCount == 1)
        #expect(inflatedReport.claimChecks.first?.result.discrepancies.first?.pdfText == "p = 0.008")
    }

    // MARK: - 4. S13 Evidence Localization & Quantitative Alignment Tests (M4 Stage 2)

    @Test("S13-1: 12+1 English claims (C01-C09 incl. C01B, C06 unit conversion, C07 negation non-entailment) against s12_paper.pdf")
    func s13TwelveClaimsAgainstS12PaperPDF() throws {
        let pdfURL = Self.pdfSegmentationFixturesURL.appendingPathComponent("s12_paper.pdf")
        let chunks = try PDFMultiColumnSegmenter().segmentPDF(at: pdfURL, citeKey: "rivera2026")
        let locator = EvidenceLocatorAndNumericChecker()

        // Also build a multi-document FTS5 index to verify citation keys never leak into full-text OR queries
        let multiIndex = try FTS5ProvenanceIndex()
        var indexedChunks = chunks
        for idx in 1...10 {
            indexedChunks.append(
                PDFPassageChunk(
                    id: "bg\(idx)#p1-c1-\(idx)",
                    citeKey: "bg\(idx)",
                    pdfFileName: "bg\(idx).pdf",
                    sectionTitle: "Background",
                    columnIndex: 1,
                    readingSequence: idx,
                    boundingBox: PDFPageRegionBox(pageIndex: 0, x: 48, y: 200, width: 220, height: 50),
                    passageText: "Classical algebraic lattice homomorphisms over finite commutative rings in cohort \(idx)."
                )
            )
        }
        try multiIndex.indexPassages(indexedChunks)

        // C01_EXACT: Exact numbers & units -> FOUND on page 1
        let c01 = locator.locateEvidence(
            claim: "Our deterministic verifier completes static analysis across 368 regression tests in 14.5 ms \\cite{rivera2026}.",
            passages: chunks,
            pdfFileName: "s12_paper.pdf",
            citeKeyFilter: "rivera2026"
        )
        #expect(c01.schema == "scholaros.evidence/1")
        #expect(c01.verdict == .found)
        #expect(c01.page == 1)
        #expect(c01.pageIndex == 0)
        #expect(c01.sectionTitle == "1 Introduction")
        #expect((c01.coverage ?? 0.0) >= 0.60)
        #expect(c01.discrepancies.isEmpty)
        #expect((c01.boundingBox?.width ?? 0.0) > 0.0)
        #expect((c01.boundingBox?.height ?? 0.0) > 0.0)

        let c01FTS = try locator.locateEvidence(
            claim: "Our deterministic verifier completes static analysis across 368 regression tests in 14.5 ms \\cite{rivera2026}.",
            in: multiIndex,
            citeKeyFilter: "rivera2026",
            pdfFileName: "s12_paper.pdf"
        )
        #expect(c01FTS.verdict == .found)
        #expect(c01FTS.page == 1)

        // C01B_PARAPHRASE: Paraphrased articles/prepositions -> FOUND on page 1
        let c01b = locator.locateEvidence(
            claim: "The deterministic verifier completes static analysis on 368 regression tests in 14.5 ms \\cite{rivera2026}.",
            passages: chunks,
            pdfFileName: "s12_paper.pdf",
            citeKeyFilter: "rivera2026"
        )
        #expect(c01b.verdict == .found)
        #expect(c01b.page == 1)
        #expect(c01b.discrepancies.isEmpty)

        // C02_NUM_9999_PLUS_MS: Bare count changed 368 -> 9999 while 14.5 ms matches -> NUMERIC_MISMATCH pointing to 368
        let c02 = locator.locateEvidence(
            claim: "Our deterministic verifier completes static analysis across 9999 regression tests in 14.5 ms \\cite{rivera2026}.",
            passages: chunks,
            pdfFileName: "s12_paper.pdf",
            citeKeyFilter: "rivera2026"
        )
        #expect(c02.verdict == .numericMismatch)
        #expect(c02.page == 1)
        #expect(c02.discrepancies.contains {
            $0.claimText.contains("9999") && ($0.pdfText?.contains("368") == true)
        })

        // C03_NUM_3680_ONLY: Bare count changed 368 -> 3680 with no unit in claim -> NUMERIC_MISMATCH pointing to 368
        let c03 = locator.locateEvidence(
            claim: "Our deterministic verifier completes static analysis across 3680 regression tests on a single CPU core \\cite{rivera2026}.",
            passages: chunks,
            pdfFileName: "s12_paper.pdf",
            citeKeyFilter: "rivera2026"
        )
        #expect(c03.verdict == .numericMismatch)
        #expect(c03.page == 1)
        #expect(c03.discrepancies.contains {
            $0.claimText.contains("3680") && ($0.pdfText?.contains("368") == true)
        })

        // C04_CROSS_NOUN_48: Cross-noun collision (48 benchmark queries vs PDF 1,240 benchmark queries + 48 MB) -> NUMERIC_MISMATCH
        let c04 = locator.locateEvidence(
            claim: "Across 48 benchmark queries, memory consumption remained 48 MB \\cite{rivera2026}.",
            passages: chunks,
            pdfFileName: "s12_paper.pdf",
            citeKeyFilter: "rivera2026"
        )
        #expect(c04.verdict == .numericMismatch)
        #expect(c04.page == 1)
        #expect(c04.columnIndex == 2)
        #expect(c04.sectionTitle == "4 Experimental Evaluation")
        #expect(c04.discrepancies.contains {
            $0.claimText.contains("48 benchmark queries") && ($0.pdfText?.contains("1,240 benchmark queries") == true)
        })

        // C05A_UNIT_S_VS_MS: 14.5 s vs PDF 14.5 ms -> NUMERIC_MISMATCH
        let c05a = locator.locateEvidence(
            claim: "Our deterministic verifier completes static analysis across 368 regression tests in 14.5 s \\cite{rivera2026}.",
            passages: chunks,
            pdfFileName: "s12_paper.pdf",
            citeKeyFilter: "rivera2026"
        )
        #expect(c05a.verdict == .numericMismatch)
        #expect(c05a.page == 1)
        #expect(c05a.discrepancies.contains {
            $0.claimText.contains("14.5 s") && ($0.pdfText?.contains("14.5 ms") == true)
        })

        // C05B_UNIT_GB_VS_MB: 48 GB vs PDF 48 MB -> NUMERIC_MISMATCH
        let c05b = locator.locateEvidence(
            claim: "Across 1,240 benchmark queries, memory consumption remained 48 GB while achieving 94.2\\% precision \\cite{rivera2026}.",
            passages: chunks,
            pdfFileName: "s12_paper.pdf",
            citeKeyFilter: "rivera2026"
        )
        #expect(c05b.verdict == .numericMismatch)
        #expect(c05b.page == 1)
        #expect(c05b.columnIndex == 2)
        #expect(c05b.sectionTitle == "4 Experimental Evaluation")
        #expect(c05b.discrepancies.contains {
            $0.claimText.contains("48 GB") && ($0.pdfText?.contains("48 MB") == true)
        })

        // C05C_UNIT_DAYS_VS_HOURS: 2.5 days vs PDF 2.5 hours -> NUMERIC_MISMATCH
        let c05c = locator.locateEvidence(
            claim: "Dataset preparation required 2.5 days across 18 distinct conference templates \\cite{rivera2026}.",
            passages: chunks,
            pdfFileName: "s12_paper.pdf",
            citeKeyFilter: "rivera2026"
        )
        #expect(c05c.verdict == .numericMismatch)
        #expect(c05c.page == 1)
        #expect(c05c.columnIndex == 2)
        #expect(c05c.sectionTitle == "4 Experimental Evaluation")
        #expect(c05c.discrepancies.contains {
            $0.claimText.contains("2.5 days") && ($0.pdfText?.contains("2.5 hours") == true)
        })

        // C06_UNIT_CONVERTED: 0.0145 s == PDF 14.5 ms -> FOUND on page 1
        let c06 = locator.locateEvidence(
            claim: "Our deterministic verifier completes static analysis across 368 regression tests in 0.0145 s \\cite{rivera2026}.",
            passages: chunks,
            pdfFileName: "s12_paper.pdf",
            citeKeyFilter: "rivera2026"
        )
        #expect(c06.verdict == .found)
        #expect(c06.page == 1)
        #expect(c06.discrepancies.isEmpty)

        // C07_NEGATION_INVERT: "relies on large neural network components" vs PDF "without any neural network components".
        // NOTE: Expected verdict is FOUND — this tool locates lexically similar passages and checks explicit numbers;
        // it deliberately does NOT judge semantic entailment or whether the passage supports the author's conclusion.
        let c07 = locator.locateEvidence(
            claim: "Our deterministic verifier relies on large neural network components to complete static analysis \\cite{rivera2026}.",
            passages: chunks,
            pdfFileName: "s12_paper.pdf",
            citeKeyFilter: "rivera2026"
        )
        #expect(c07.verdict == .found)
        #expect(c07.page == 1)
        #expect((c07.coverage ?? 0.0) >= 0.60)

        // C08A_MOON_PURE_EN: Unrelated English claim (even with \cite{rivera2026}) -> NOT_FOUND (both in-memory & FTS5)
        let c08a = locator.locateEvidence(
            claim: "The moon is made of green cheese \\cite{rivera2026}.",
            passages: chunks,
            pdfFileName: "s12_paper.pdf",
            citeKeyFilter: "rivera2026"
        )
        #expect(c08a.verdict == .notFound)
        #expect(c08a.matches.isEmpty)
        #expect(c08a.boundingBox == nil)

        let c08aFTS = try locator.locateEvidence(
            claim: "The moon is made of green cheese \\cite{rivera2026}.",
            in: multiIndex,
            citeKeyFilter: "rivera2026",
            pdfFileName: "s12_paper.pdf"
        )
        #expect(c08aFTS.verdict == .notFound)
        #expect(c08aFTS.matches.isEmpty)

        // C08B_MOON_SHARED_WORD: Unrelated claim sharing 1 common word ("analysis") -> NOT_FOUND (cov = 0.20 < 0.60, no BM25 OR bypass)
        let c08b = locator.locateEvidence(
            claim: "The moon is made of green cheese in our analysis \\cite{rivera2026}.",
            passages: chunks,
            pdfFileName: "s12_paper.pdf",
            citeKeyFilter: "rivera2026"
        )
        #expect(c08b.verdict == .notFound)
        #expect(c08b.matches.isEmpty)

        let c08bFTS = try locator.locateEvidence(
            claim: "The moon is made of green cheese in our analysis \\cite{rivera2026}.",
            in: multiIndex,
            citeKeyFilter: "rivera2026",
            pdfFileName: "s12_paper.pdf"
        )
        #expect(c08bFTS.verdict == .notFound)
        #expect(c08bFTS.matches.isEmpty)

        // C09_MOON_ZH: Unrelated Chinese claim with \cite{rivera2026} -> NOT_FOUND
        let c09 = try locator.locateEvidence(
            claim: "月亮是绿奶酪做的 \\cite{rivera2026}。",
            in: multiIndex,
            citeKeyFilter: "rivera2026",
            pdfFileName: "s12_paper.pdf"
        )
        #expect(c09.verdict == .notFound)
        #expect(c09.matches.isEmpty)
    }

    @Test("S13-2: 4 Chinese claims against Chinese passages and cross-language Chinese claim against English PDF returning NOT_FOUND")
    func s13ChineseClaimsAndSameLanguageBoundary() throws {
        let locator = EvidenceLocatorAndNumericChecker()
        let zhChunks: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "zhou2026#p1-c1-1",
                citeKey: "zhou2026",
                pdfFileName: "zhou2026_zh.pdf",
                sectionTitle: "1 引言",
                columnIndex: 1,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 0, x: 52, y: 510, width: 230, height: 64),
                passageText: "确定性验证器在单核处理器上用 14.5 毫秒完成了 368 个测试的静态分析。"
            ),
            PDFPassageChunk(
                id: "zhou2026#p2-c2-2",
                citeKey: "zhou2026",
                pdfFileName: "zhou2026_zh.pdf",
                sectionTitle: "4 实验评估",
                columnIndex: 2,
                readingSequence: 2,
                boundingBox: PDFPageRegionBox(pageIndex: 1, x: 318, y: 420, width: 230, height: 60),
                passageText: "在 1,240 个基准查询上，内存占用保持在 48 MB，准确率达到 94.2%。"
            )
        ]

        let zhIndex = try FTS5ProvenanceIndex()
        try zhIndex.indexPassages(zhChunks)

        // ZH-1: Matching numbers & units -> FOUND (both in-memory and FTS5)
        let zh1 = try locator.locateEvidence(
            claim: "确定性验证器用 14.5 毫秒完成了 368 个测试的静态分析 \\cite{zhou2026}。",
            in: zhIndex,
            citeKeyFilter: "zhou2026",
            pdfFileName: "zhou2026_zh.pdf"
        )
        #expect(zh1.verdict == .found)
        #expect(zh1.page == 1)
        #expect(zh1.discrepancies.isEmpty)

        // ZH-2: Bare count + classifier + noun mismatch (9999 个测试 vs 368 个测试) -> NUMERIC_MISMATCH
        let zh2 = try locator.locateEvidence(
            claim: "确定性验证器用 14.5 毫秒完成了 9999 个测试的静态分析 \\cite{zhou2026}。",
            in: zhIndex,
            citeKeyFilter: "zhou2026",
            pdfFileName: "zhou2026_zh.pdf"
        )
        #expect(zh2.verdict == .numericMismatch)
        #expect(zh2.page == 1)
        #expect(zh2.discrepancies.contains {
            $0.claimText.contains("9999") && ($0.pdfText?.contains("368") == true)
        })

        // ZH-3: Chinese time unit mismatch (14.5 秒 vs 14.5 毫秒) -> NUMERIC_MISMATCH
        let zh3 = try locator.locateEvidence(
            claim: "确定性验证器用 14.5 秒完成了 368 个测试的静态分析 \\cite{zhou2026}。",
            in: zhIndex,
            citeKeyFilter: "zhou2026",
            pdfFileName: "zhou2026_zh.pdf"
        )
        #expect(zh3.verdict == .numericMismatch)
        #expect(zh3.page == 1)
        #expect(zh3.discrepancies.contains {
            $0.claimText.contains("14.5") && ($0.pdfText?.contains("14.5 毫秒") == true)
        })

        // ZH-4: Unrelated Chinese claim -> NOT_FOUND
        let zh4 = try locator.locateEvidence(
            claim: "月亮是绿奶酪做的 \\cite{zhou2026}。",
            in: zhIndex,
            citeKeyFilter: "zhou2026",
            pdfFileName: "zhou2026_zh.pdf"
        )
        #expect(zh4.verdict == .notFound)
        #expect(zh4.matches.isEmpty)

        // Cross-language boundary (User decision #5): Chinese claim against English PDF returns NOT_FOUND
        let enPDFURL = Self.pdfSegmentationFixturesURL.appendingPathComponent("s12_paper.pdf")
        let zhOnEn1 = try locator.locateEvidence(
            claim: "确定性验证器在单核上用 14.5 毫秒完成了 368 个回归测试的静态分析 \\cite{rivera2026}。",
            inPDFAt: enPDFURL,
            citeKey: "rivera2026"
        )
        #expect(zhOnEn1.verdict == .notFound)
        #expect(zhOnEn1.matches.isEmpty)

        let zhOnEn2 = try locator.locateEvidence(
            claim: "在 single CPU core 上完成了 368 个回归测试 \\cite{rivera2026}。",
            inPDFAt: enPDFURL,
            citeKey: "rivera2026"
        )
        #expect(zhOnEn2.verdict == .notFound)
        #expect(zhOnEn2.matches.isEmpty)
    }

    @Test("S13-3: Retrieval enforces |Q|=0/1/2 rules, excludes header/footer chunks, prioritizes body over References, and skips structural numbers")
    func s13ThresholdHeaderExclusionBodyPriorityAndStructuralNumbers() throws {
        let locator = EvidenceLocatorAndNumericChecker()
        let chunks: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "doc#hdr",
                citeKey: "doc2026",
                pdfFileName: "doc2026.pdf",
                sectionTitle: "Front Matter & Abstract",
                columnIndex: 0,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 0, x: 48, y: 740, width: 500, height: 14),
                passageText: "Exclusive Header Sentinel Token QuantumAnnealingHeader",
                kind: .header
            ),
            PDFPassageChunk(
                id: "doc#ref",
                citeKey: "doc2026",
                pdfFileName: "doc2026.pdf",
                sectionTitle: "References",
                columnIndex: 2,
                readingSequence: 2,
                boundingBox: PDFPageRegionBox(pageIndex: 2, x: 318, y: 200, width: 230, height: 40),
                passageText: "[12] Rivera (2024). Speculative decoding kernels accelerate token generation.",
                kind: .body
            ),
            PDFPassageChunk(
                id: "doc#body",
                citeKey: "doc2026",
                pdfFileName: "doc2026.pdf",
                sectionTitle: "3. Evaluation",
                columnIndex: 1,
                readingSequence: 3,
                boundingBox: PDFPageRegionBox(pageIndex: 1, x: 48, y: 400, width: 230, height: 55),
                passageText: "As shown in Section 3, Table 1, and Fig. 2 [12], speculative decoding kernels accelerate token generation across 64 sequences in 2024.",
                kind: .body
            )
        ]

        // 1. |Q| = 0 (only stopwords / citations / bare numbers) -> NOT_FOUND
        let emptyQ = locator.locateEvidence(claim: "In \\cite{doc2026}, 2026.", passages: chunks)
        #expect(emptyQ.verdict == .notFound)

        // 2. |Q| = 2 -> must match BOTH keywords (1/2 = 0.50 -> NOT_FOUND)
        let twoWordPartial = locator.locateEvidence(claim: "Speculative teleportation.", passages: chunks)
        #expect(twoWordPartial.verdict == .notFound)

        // 3. Header/footer chunks never participate in retrieval
        let headerQuery = locator.locateEvidence(claim: "Exclusive Header Sentinel Token QuantumAnnealingHeader.", passages: chunks)
        #expect(headerQuery.verdict == .notFound)

        // 4. Body chunk prioritized over References chunk at equal coverage, and structural numbers (Section 4, Table 2, Fig. 9, [33], 2026) do not trigger false numeric mismatch
        let bodyPreferred = locator.locateEvidence(
            claim: "In Section 4 and Table 2 (Fig. 9) [33], speculative decoding kernels accelerate token generation across 64 sequences (2026).",
            passages: chunks
        )
        #expect(bodyPreferred.verdict == .found)
        #expect(bodyPreferred.page == 2)
        #expect(bodyPreferred.sectionTitle == "3. Evaluation")
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
