import Foundation
import PDFKit
import Testing
import ScholarModels
import ScholarPDFProvenance

extension PDFProvenanceAndCitationGraphTests {

    private static var pdfSegmentation02bFixturesURLForWideFloat: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pdf-segmentation-02b", isDirectory: true)
    }

    @Test("S12-9: Wide spanning table and wide multi-panel figure with scattered ticks/Score(%)/legend do not collapse lower two-column prose into one interleaved column")
    func s12WideTableAndFigurePreserveTwoColumnProseWithoutInterleaving() throws {
        let pdfURL = Self.pdfSegmentation02bFixturesURLForWideFloat.appendingPathComponent("s12_wide_table_fig_cols.pdf")
        let chunks = try PDFMultiColumnSegmenter().segmentPDF(at: pdfURL, citeKey: "fhbi2026")

        let page2Chunks = chunks.filter { $0.boundingBox.pageIndex == 1 }
        let page2Body = page2Chunks.filter { $0.kind == .body }
        #expect(page2Body.count >= 2)

        // Every body chunk on Page 2 must be separated into left (col 1) or right (col 2), never merged as col 0
        for bodyChunk in page2Body {
            #expect(bodyChunk.columnIndex == 1 || bodyChunk.columnIndex == 2)
            #expect(!bodyChunk.passageText.contains("Score (%)"))
            #expect(!bodyChunk.passageText.contains("(a) In-Domain"))
            #expect(!bodyChunk.passageText.contains("(b) Out-of-Domain"))
        }

        let leftBody = try #require(page2Body.first { $0.passageText.contains("evaluate our layout recovery pipeline") })
        let rightBody = try #require(page2Body.first { $0.passageText.contains("baselines, outperforming them by 14.1 percentage points") })

        #expect(leftBody.columnIndex == 1)
        #expect(rightBody.columnIndex == 2)
        #expect(leftBody.sectionTitle == "4 Experimental Results")
        #expect(rightBody.sectionTitle == "4 Experimental Results")
        #expect(leftBody.readingSequence < rightBody.readingSequence)

        // Left and right sentences must not interleave horizontally
        #expect(leftBody.passageText.contains("preserves exact paragraph boundaries in the left column."))
        #expect(!leftBody.passageText.contains("baselines, outperforming"))
        #expect(!leftBody.passageText.contains("30, 000"))
        #expect(rightBody.passageText.contains("maintains 88.7% accuracy in the right column."))
        #expect(!rightBody.passageText.contains("layout recovery pipeline"))

        // Wide table and wide figure (including axis label Score (%)) must be tableOrFigure chunks preceding body columns
        let page2Floats = page2Chunks.filter { $0.kind == .tableOrFigure }
        let tableChunk = try #require(page2Floats.first { $0.passageText.contains("Table 1:") })
        let figureChunk = try #require(page2Floats.first { $0.passageText.contains("Figure 1:") })
        #expect(tableChunk.columnIndex == 0)
        #expect(figureChunk.columnIndex == 0)
        #expect(figureChunk.passageText.contains("Score (%)"))
        #expect(tableChunk.readingSequence < leftBody.readingSequence)
        #expect(figureChunk.readingSequence < leftBody.readingSequence)
    }
}
