import Foundation
import PDFKit
import Testing
import ScholarModels
import ScholarPDFProvenance

extension PDFProvenanceAndCitationGraphTests {

    @Test("S12-8: Numbered lines whose next line continues the same sentence are not misclassified as section headings")
    func s12NumberedLinesWithSentenceContinuationOnNextLineAreNotHeadings() throws {
        let pdfData = SyntheticAcademicPDFBuilder.renderTwoColumnPaperPDF(
            title: "Avoiding Wrapped Numbered Prose Heading False Positives",
            authors: "Alice Rivera and Bernard Vance",
            abstractParagraph: "Wrapped numbered list items and wrapped figure captions must remain prose rather than becoming section headings.",
            leftColumnParagraphs: [
                (
                    heading: "1. Introduction",
                    body: "We compare two solver pipelines.\n2. By using Magma\n[33], we can compute the dense factorization on GPU.\n4. Under peak load\n, latency remains bounded across runs."
                )
            ],
            rightColumnParagraphs: [
                (
                    heading: "2. Experiments",
                    body: "Angular alignment is summarized below.\nFig.\n3. Gradients\nangular similarities with m = 4 across layers.\nReferences\n[1] A. Rivera, Reproducible PDF segmentation, 2026."
                )
            ]
        )

        let chunks = try PDFMultiColumnSegmenter().segmentPDF(
            data: pdfData,
            pdfFileName: "wrapped_numbered_lines.pdf",
            citeKey: "rivera2026wrap"
        )

        let headings = chunks.filter { $0.kind == .sectionHeading }.map(\.passageText)

        // Genuine headings (including References followed by [1] bibliography entry) must be recognized
        #expect(headings == [
            "Abstract",
            "1. Introduction",
            "2. Experiments",
            "References"
        ])

        // False-positive candidates whose next line starts with '[33]', ',', or lowercase 'angular' must not become headings
        #expect(!headings.contains("2. By using Magma"))
        #expect(!headings.contains("4. Under peak load"))
        #expect(!headings.contains("3. Gradients"))

        // And their text must remain intact inside body chunks
        let bodyJoined = chunks
            .filter { $0.kind == .body }
            .map(\.passageText)
            .joined(separator: " ")
        #expect(bodyJoined.contains("2. By using Magma [33], we can compute"))
        #expect(bodyJoined.contains("3. Gradients angular similarities with m = 4"))

        // Direct API checks for detectSectionHeading(_:nextLine:)
        #expect(PDFMultiColumnSegmenter.detectSectionHeading("2. By using Magma", nextLine: "[33], we can compute the dense factorization.") == nil)
        #expect(PDFMultiColumnSegmenter.detectSectionHeading("3. Gradients", nextLine: "angular similarities with m = 4") == nil)
        #expect(PDFMultiColumnSegmenter.detectSectionHeading("4. Under peak load", nextLine: ", latency remains bounded.") == nil)
        #expect(PDFMultiColumnSegmenter.detectSectionHeading("3. Methodology", nextLine: "We segment each PDF page into lines.") == "3. Methodology")
        #expect(PDFMultiColumnSegmenter.detectSectionHeading("References", nextLine: "[1] A. Rivera, 2026.") == "References")
    }
}
