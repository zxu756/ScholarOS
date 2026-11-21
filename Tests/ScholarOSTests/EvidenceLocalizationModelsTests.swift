import Foundation
import Testing
import ScholarModels

extension BibCSLAndFirewallTests {

    @Test("EvidenceLocalizationResult encodes scholaros.evidence/1 JSON contract for FOUND, NUMERIC_MISMATCH, and NOT_FOUND")
    func evidenceLocalizationResultJSONSchemaContract() throws {
        let chunk = PDFPassageChunk(
            id: "rivera2026#p1-c1-6",
            citeKey: "rivera2026",
            pdfFileName: "s12_paper.pdf",
            sectionTitle: "1 Introduction",
            columnIndex: 1,
            readingSequence: 6,
            boundingBox: PDFPageRegionBox(pageIndex: 0, x: 54.0, y: 412.5, width: 234.0, height: 68.0),
            passageText: "Our deterministic verifier completes static analysis across 368 regression tests in 14.5 ms on a single CPU core.",
            kind: .body
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        // 1. FOUND
        let foundMatch = EvidencePassageMatch(
            chunk: chunk,
            coverage: 1.0,
            matchedKeywords: ["determinist", "verifi", "complet", "static", "analysis", "regress", "test"],
            bm25Score: 18.4
        )
        let foundResult = EvidenceLocalizationResult(
            claim: "Our deterministic verifier completes static analysis across 368 regression tests in 14.5 ms.",
            pdfFile: "s12_paper.pdf",
            verdict: .found,
            queryKeywords: ["determinist", "verifi", "complet", "static", "analysis", "regress", "test"],
            matches: [foundMatch]
        )
        let foundData = try encoder.encode(foundResult)
        let foundJSON = try #require(JSONSerialization.jsonObject(with: foundData) as? [String: Any])
        #expect(foundJSON["schema"] as? String == "scholaros.evidence/1")
        #expect(foundJSON["verdict"] as? String == "FOUND")
        #expect(foundJSON["page"] as? Int == 1)
        #expect(foundJSON["page_index"] as? Int == 0)
        #expect(foundJSON["column_index"] as? Int == 1)
        #expect(foundJSON["section_title"] as? String == "1 Introduction")
        #expect(foundJSON["coverage"] as? Double == 1.0)
        #expect((foundJSON["excerpt"] as? String)?.contains("368 regression tests") == true)
        let bbox = try #require(foundJSON["bounding_box"] as? [String: Double])
        #expect(bbox["x"] == 54.0)
        #expect(bbox["y"] == 412.5)
        #expect(bbox["width"] == 234.0)
        #expect(bbox["height"] == 68.0)
        #expect((foundJSON["discrepancies"] as? [Any])?.isEmpty == true)
        #expect(foundResult.verdict.cliExitCode == 0)

        // Ensure round-trip Codable decoding
        let decodedFound = try JSONDecoder().decode(EvidenceLocalizationResult.self, from: foundData)
        #expect(decodedFound == foundResult)

        // 2. NUMERIC_MISMATCH
        let discrepancy = EvidenceNumericDiscrepancy(
            claimText: "9999 regression tests",
            pdfText: "368 regression tests",
            reason: "Claim states '9999 regression tests', whereas PDF passage reports '368 regression tests'."
        )
        let mismatchMatch = EvidencePassageMatch(
            chunk: chunk,
            coverage: 1.0,
            matchedKeywords: ["determinist", "verifi", "complet", "static", "analysis", "regress", "test"],
            bm25Score: 18.4,
            discrepancies: [discrepancy]
        )
        let mismatchResult = EvidenceLocalizationResult(
            claim: "Our deterministic verifier completes static analysis across 9999 regression tests in 14.5 ms.",
            pdfFile: "s12_paper.pdf",
            verdict: .numericMismatch,
            queryKeywords: ["determinist", "verifi", "complet", "static", "analysis", "regress", "test"],
            matches: [mismatchMatch],
            discrepancies: [discrepancy]
        )
        let mismatchData = try encoder.encode(mismatchResult)
        let mismatchJSON = try #require(JSONSerialization.jsonObject(with: mismatchData) as? [String: Any])
        #expect(mismatchJSON["schema"] as? String == "scholaros.evidence/1")
        #expect(mismatchJSON["verdict"] as? String == "NUMERIC_MISMATCH")
        let discArr = try #require(mismatchJSON["discrepancies"] as? [[String: Any]])
        #expect(discArr.count == 1)
        #expect(discArr[0]["claim_text"] as? String == "9999 regression tests")
        #expect(discArr[0]["pdf_text"] as? String == "368 regression tests")
        #expect((discArr[0]["reason"] as? String)?.isEmpty == false)
        #expect(mismatchResult.verdict.cliExitCode == 1)

        // 3. NOT_FOUND — must emit empty matches and no fake bounding box or excerpt
        let notFoundResult = EvidenceLocalizationResult(
            claim: "The moon is made of green cheese.",
            pdfFile: "s12_paper.pdf",
            verdict: .notFound,
            queryKeywords: ["moon", "made", "green", "chees"]
        )
        let notFoundData = try encoder.encode(notFoundResult)
        let notFoundJSON = try #require(JSONSerialization.jsonObject(with: notFoundData) as? [String: Any])
        #expect(notFoundJSON["schema"] as? String == "scholaros.evidence/1")
        #expect(notFoundJSON["verdict"] as? String == "NOT_FOUND")
        #expect((notFoundJSON["matches"] as? [Any])?.isEmpty == true)
        #expect(notFoundJSON["page"] == nil)
        #expect(notFoundJSON["page_index"] == nil)
        #expect(notFoundJSON["bounding_box"] == nil)
        #expect(notFoundJSON["excerpt"] == nil)
        #expect(notFoundResult.verdict.cliExitCode == 3)

        // No verdict rawValue may claim entailment or groundedness
        let allRawValues = EvidenceLocalizationVerdict.allCases.map(\.rawValue)
        #expect(allRawValues == ["FOUND", "NUMERIC_MISMATCH", "NOT_FOUND"])
    }
}
