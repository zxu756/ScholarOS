import Foundation
import PDFKit
import Testing
import ScholarModels
import ScholarPDFProvenance

extension PDFProvenanceAndCitationGraphTests {

    private static var pdfSegmentation02bFixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pdf-segmentation-02b", isDirectory: true)
    }

    // MARK: - M4-02b Item 2: Candidate Ranking Prioritizes Passages Containing Aligned Numbers

    @Test("S13-4: Among passing candidates, ranking prioritizes passages containing numbers with the same noun or dimension over higher-coverage numberless summaries")
    func s13CandidateRankingPrioritizesPassagesWithAlignedNumbers() throws {
        let locator = EvidenceLocatorAndNumericChecker()

        let passages: [PDFPassageChunk] = [
            // Page 9 Conclusion: 100% keyword coverage (all 6 query keywords hit), but NO numbers at all
            PDFPassageChunk(
                id: "rank2026#p9-c2-1",
                citeKey: "rank2026",
                pdfFileName: "rank2026.pdf",
                sectionTitle: "6 Conclusion",
                columnIndex: 2,
                readingSequence: 10,
                boundingBox: PDFPageRegionBox(pageIndex: 8, x: 318, y: 420, width: 230, height: 60),
                passageText: "In conclusion, our hierarchical verifier evaluates benchmark queries with low memory consumption and high precision across deployments.",
                kind: .body
            ),
            // Page 4 Table Note / Method: passes >= 0.60 threshold (4/6 = 0.67 coverage, 0.33 lower than Conclusion!),
            // and actually contains the aligned benchmark query count and memory numbers
            PDFPassageChunk(
                id: "rank2026#p4-c0-2",
                citeKey: "rank2026",
                pdfFileName: "rank2026.pdf",
                sectionTitle: "4 Experiments",
                columnIndex: 0,
                readingSequence: 4,
                boundingBox: PDFPageRegionBox(pageIndex: 3, x: 54, y: 560, width: 504, height: 42),
                passageText: "Table 2 note: our hierarchical verifier evaluates 1,240 benchmark queries while memory consumption stays at 48 MB.",
                kind: .tableOrFigure
            )
        ]

        // 1. Numeric mismatch claim: must select Page 4 (with '1,240 benchmark queries') rather than Page 9 Conclusion (pdf_text == nil)
        let mismatchRes = locator.locateEvidence(
            claim: "Our hierarchical verifier evaluates 5,000 benchmark queries with low memory consumption and high precision.",
            passages: passages,
            pdfFileName: "rank2026.pdf"
        )
        #expect(mismatchRes.verdict == .numericMismatch)
        #expect(mismatchRes.page == 4)
        #expect(mismatchRes.discrepancies.contains {
            $0.claimText.contains("5,000 benchmark queries") && ($0.pdfText?.contains("1,240 benchmark queries") == true)
        })

        // 2. Matching numeric claim (unit-converted 0.048 GB == 48 MB, coverage 0.67 vs Conclusion 1.00): must select Page 4 as FOUND
        let foundRes = locator.locateEvidence(
            claim: "Our hierarchical verifier evaluates benchmark queries with 0.048 GB memory consumption and high precision.",
            passages: passages,
            pdfFileName: "rank2026.pdf"
        )
        #expect(foundRes.verdict == .found)
        #expect(foundRes.page == 4)
        #expect(foundRes.discrepancies.isEmpty)

        // 3. Fallback when NO passing passage has an aligned number: preserve original coverage/tier order (Page 9 Conclusion wins)
        let noAlignedPassages: [PDFPassageChunk] = [
            passages[0],
            PDFPassageChunk(
                id: "rank2026#p2-c1-3",
                citeKey: "rank2026",
                pdfFileName: "rank2026.pdf",
                sectionTitle: "2 Related Work",
                columnIndex: 1,
                readingSequence: 2,
                boundingBox: PDFPageRegionBox(pageIndex: 1, x: 54, y: 320, width: 230, height: 50),
                passageText: "Prior hierarchical verifiers evaluate benchmark queries with bounded memory consumption.",
                kind: .body
            )
        ]
        let fallbackRes = locator.locateEvidence(
            claim: "Our hierarchical verifier evaluates 5,000 benchmark queries with low memory consumption and high precision.",
            passages: noAlignedPassages,
            pdfFileName: "rank2026.pdf"
        )
        #expect(fallbackRes.verdict == .numericMismatch)
        #expect(fallbackRes.page == 9)
    }

    // MARK: - M4-02b Item 3: Same Noun with Different Value (Swapped Pairs -> NUMERIC_MISMATCH)

    @Test("S13-5: Swapping values across nouns ('4 layers and 3 attention heads' vs '3 layers, 4 attention heads') returns NUMERIC_MISMATCH pointing to source values")
    func s13SameNounDifferentValueSwappedPairsReturnNumericMismatch() throws {
        let locator = EvidenceLocatorAndNumericChecker()

        // 1. Direct PDF check on s12_wide_table_fig_cols.pdf ('3 layers, 4 attention heads')
        let pdfURL = Self.pdfSegmentation02bFixturesURL.appendingPathComponent("s12_wide_table_fig_cols.pdf")
        let pdfSwap = try locator.locateEvidence(
            claim: "Our reference encoder uses 4 layers and 3 attention heads with a hidden width of 256 units.",
            inPDFAt: pdfURL,
            citeKey: "fhbi2026"
        )
        #expect(pdfSwap.verdict == .numericMismatch)
        #expect(pdfSwap.page == 1)
        #expect(pdfSwap.discrepancies.contains {
            $0.claimText.contains("4 layers") && ($0.pdfText?.contains("3 layers") == true)
        })
        #expect(pdfSwap.discrepancies.contains {
            $0.claimText.contains("3 attention heads") && ($0.pdfText?.contains("4 attention heads") == true)
        })

        // 2. Cross-modifier collision ('3 multi-head attention layers, 4 per-layer attention heads')
        let compoundPassages = [
            PDFPassageChunk(
                id: "arch#p2-c1-1",
                citeKey: "arch2026",
                pdfFileName: "arch2026.pdf",
                sectionTitle: "3 Architecture",
                columnIndex: 1,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 1, x: 54, y: 400, width: 230, height: 50),
                passageText: "The transformer backbone stacks 3 multi-head attention layers, 4 per-layer attention heads, and residual projections.",
                kind: .body
            )
        ]
        let compoundSwap = locator.locateEvidence(
            claim: "The transformer backbone stacks 4 layers and 3 attention heads with residual projections.",
            passages: compoundPassages
        )
        #expect(compoundSwap.verdict == .numericMismatch)
        #expect(compoundSwap.discrepancies.contains {
            $0.claimText.contains("4 layers") && ($0.pdfText?.contains("3 multi-head attention layers") == true)
        })
        #expect(compoundSwap.discrepancies.contains {
            $0.claimText.contains("3 attention heads") && ($0.pdfText?.contains("4 per-layer attention heads") == true)
        })

        // 3. Same head noun with distinct modifiers ('4 encoder layers and 3 decoder layers' vs '3 encoder layers, 4 decoder layers')
        let encDecPassages = [
            PDFPassageChunk(
                id: "encdec#p3-c2-1",
                citeKey: "encdec2026",
                pdfFileName: "encdec2026.pdf",
                sectionTitle: "3 Model",
                columnIndex: 2,
                readingSequence: 2,
                boundingBox: PDFPageRegionBox(pageIndex: 2, x: 318, y: 400, width: 230, height: 50),
                passageText: "Our sequence transducer comprises 3 encoder layers, 4 decoder layers, and shared embeddings.",
                kind: .body
            )
        ]
        let encDecSwap = locator.locateEvidence(
            claim: "Our sequence transducer comprises 4 encoder layers and 3 decoder layers with shared embeddings.",
            passages: encDecPassages
        )
        #expect(encDecSwap.verdict == .numericMismatch)
        #expect(encDecSwap.discrepancies.contains {
            $0.claimText.contains("4 encoder layers") && ($0.pdfText?.contains("3 encoder layers") == true)
        })
        #expect(encDecSwap.discrepancies.contains {
            $0.claimText.contains("3 decoder layers") && ($0.pdfText?.contains("4 decoder layers") == true)
        })

        // 4. Synonym-group distinct nouns ('4 datasets and 3 benchmarks' vs '3 datasets, 4 benchmarks')
        let synPassages = [
            PDFPassageChunk(
                id: "syn#p4-c1-1",
                citeKey: "syn2026",
                pdfFileName: "syn2026.pdf",
                sectionTitle: "4 Evaluation",
                columnIndex: 1,
                readingSequence: 3,
                boundingBox: PDFPageRegionBox(pageIndex: 3, x: 54, y: 360, width: 230, height: 50),
                passageText: "Empirical validation spans 3 datasets, 4 benchmarks, and standardized evaluation splits.",
                kind: .body
            )
        ]
        let synSwap = locator.locateEvidence(
            claim: "Empirical validation spans 4 datasets and 3 benchmarks with standardized evaluation splits.",
            passages: synPassages
        )
        #expect(synSwap.verdict == .numericMismatch)
        #expect(synSwap.discrepancies.contains {
            $0.claimText.contains("4 datasets") && ($0.pdfText?.contains("3 datasets") == true)
        })
        #expect(synSwap.discrepancies.contains {
            $0.claimText.contains("3 benchmarks") && ($0.pdfText?.contains("4 benchmarks") == true)
        })
    }

    // MARK: - M4-02b Item 4: Noun Phrase Boundary (Participles/Verbs/Prepositions) & '(N) of <Noun>'

    @Test("S13-6: Trailing noun phrases stop at participles/verbs/prepositions ('19 datasets grouped into') and '(610) of PuzzleScript games' binds to 'games'")
    func s13NounBindingStopsAtParticiplesVerbsPrepositionsAndBindsParenOfNoun() throws {
        let locator = EvidenceLocatorAndNumericChecker()

        // 1. Direct binding check: '19 datasets grouped into 4 task families' -> '19 datasets' (headNoun == 'dataset', NOT 'group')
        let bindings1 = locator.extractQuantitativeBindings(
            from: "We evaluate across 19 datasets grouped into 4 task families and 12 pretrained models trained on public corpora."
        )
        let b19 = try #require(bindings1.first { Int($0.rawNumericValue) == 19 })
        #expect(b19.rawSurfaceText == "19 datasets")
        #expect(b19.headNoun == "dataset")

        let b12 = try #require(bindings1.first { Int($0.rawNumericValue) == 12 })
        #expect(b12.rawSurfaceText == "12 pretrained models")
        #expect(b12.headNoun == "model")

        let bindings2 = locator.extractQuantitativeBindings(
            from: "Across 368 regression tests covering core modules, 8 baseline systems outperform manual rules."
        )
        let b368 = try #require(bindings2.first { Int($0.rawNumericValue) == 368 })
        #expect(b368.rawSurfaceText == "368 regression tests")
        #expect(b368.headNoun == "test")
        let b8 = try #require(bindings2.first { Int($0.rawNumericValue) == 8 })
        #expect(b8.rawSurfaceText == "8 baseline systems")
        #expect(b8.headNoun == "system")

        // 2. Direct binding check: 'a small dataset (610) of PuzzleScript games' -> bound to 'game' with modifier 'puzzlescript'
        let parenBindings = locator.extractQuantitativeBindings(
            from: "We curate a small dataset (610) of PuzzleScript games for procedural synthesis."
        )
        let b610 = try #require(parenBindings.first { Int($0.rawNumericValue) == 610 })
        #expect(b610.headNoun == "game")
        #expect(b610.modifiers.contains("puzzlescript"))

        // 3. End-to-end localization against s12_wide_table_fig_cols.pdf for both '19 datasets grouped into...' and '(610) of PuzzleScript games'
        let pdfURL = Self.pdfSegmentation02bFixturesURL.appendingPathComponent("s12_wide_table_fig_cols.pdf")

        let datasetsMismatch = try locator.locateEvidence(
            claim: "Architectural parameters are strictly audited across 25 datasets collected from 4 task families.",
            inPDFAt: pdfURL,
            citeKey: "fhbi2026"
        )
        #expect(datasetsMismatch.verdict == .numericMismatch)
        #expect(datasetsMismatch.page == 1)
        #expect(datasetsMismatch.discrepancies.contains {
            $0.claimText.contains("25 datasets") && ($0.pdfText == "19 datasets")
        })

        let gamesFound = try locator.locateEvidence(
            claim: "Architectural parameters are strictly audited on 610 PuzzleScript games.",
            inPDFAt: pdfURL,
            citeKey: "fhbi2026"
        )
        #expect(gamesFound.verdict == .found)
        #expect(gamesFound.page == 1)

        let gamesMismatch = try locator.locateEvidence(
            claim: "Architectural parameters are strictly audited on 850 PuzzleScript games.",
            inPDFAt: pdfURL,
            citeKey: "fhbi2026"
        )
        #expect(gamesMismatch.verdict == .numericMismatch)
        #expect(gamesMismatch.page == 1)
        #expect(gamesMismatch.discrepancies.contains {
            $0.claimText.contains("850 PuzzleScript games") && ($0.pdfText?.contains("610") == true)
        })
    }

    // MARK: - M4-02b Item 5: Spaced Thousands ('30, 000' / '1, 000') vs Coordinates/Lists ('(1, 2)')

    @Test("S13-7: Spaced thousands separators ('30, 000', 'n = 1, 000 samples') merge as thousands while coordinates/lists ('(1, 2)') do not")
    func s13SpacedThousandsMergedWhileCoordinatesAndShortListsExcluded() throws {
        let locator = EvidenceLocatorAndNumericChecker()

        // 1. Positive: 'n = 1, 000 samples' and '30, 000 evaluation queries'
        let posBindings = locator.extractQuantitativeBindings(
            from: "Training uses n = 1, 000 samples and evaluates 30, 000 evaluation queries."
        )
        let b1000 = try #require(posBindings.first { $0.headNoun == "sampl" })
        #expect(b1000.canonicalValue == 1000.0)
        let b30000 = try #require(posBindings.first { $0.headNoun == "query" })
        #expect(b30000.canonicalValue == 30000.0)

        // End-to-end against s12_wide_table_fig_cols.pdf ('n = 1, 000 samples' on Page 1, '30, 000 evaluation queries' on Page 2)
        let pdfURL = Self.pdfSegmentation02bFixturesURL.appendingPathComponent("s12_wide_table_fig_cols.pdf")
        let samplesFound = try locator.locateEvidence(
            claim: "Architectural parameters are strictly audited with 1,000 samples per split.",
            inPDFAt: pdfURL,
            citeKey: "fhbi2026"
        )
        #expect(samplesFound.verdict == .found)
        #expect(samplesFound.page == 1)

        let samplesMismatch = try locator.locateEvidence(
            claim: "Architectural parameters are strictly audited with 5,000 samples per split.",
            inPDFAt: pdfURL,
            citeKey: "fhbi2026"
        )
        #expect(samplesMismatch.verdict == .numericMismatch)
        #expect(samplesMismatch.page == 1)
        #expect(samplesMismatch.discrepancies.contains {
            $0.claimText.contains("5,000 samples") && ($0.pdfText?.contains("1, 000") == true)
        })

        let queriesFound = try locator.locateEvidence(
            claim: "FHBI outperforms heuristic baselines by 14.1 percentage points on in-domain suites across 30,000 evaluation queries.",
            inPDFAt: pdfURL,
            citeKey: "fhbi2026"
        )
        #expect(queriesFound.verdict == .found)
        #expect(queriesFound.page == 2)

        // 2. Negative: '(1, 2)', '(10, 20)', '(0, 100)', and '1, 2000' must NEVER be merged as thousands
        let negBindings = locator.extractQuantitativeBindings(
            from: "Grid coordinates (1, 2) and (10, 20) over interval (0, 100) with indices 1, 2000 yield 12 configurations."
        )
        #expect(negBindings.count == 1)
        #expect(negBindings.first?.canonicalValue == 12.0)
        #expect(negBindings.first?.rawSurfaceText == "12 configurations")

        // Ensure '(1, 2)' in a passage never falsely satisfies a claim of '12 configurations' when passage actually says '8 configurations'
        let coordPassages = [
            PDFPassageChunk(
                id: "coord#p1-c1-1",
                citeKey: "coord2026",
                pdfFileName: "coord2026.pdf",
                sectionTitle: "3 Setup",
                columnIndex: 1,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 0, x: 54, y: 400, width: 230, height: 50),
                passageText: "At grid point (1, 2), the ablation evaluates 8 configurations across runs.",
                kind: .body
            )
        ]
        let coordCheck = locator.locateEvidence(
            claim: "At grid point (1, 2), the ablation evaluates 12 configurations across runs.",
            passages: coordPassages
        )
        #expect(coordCheck.verdict == .numericMismatch)
        #expect(coordCheck.discrepancies.contains {
            $0.claimText.contains("12 configurations") && ($0.pdfText == "8 configurations")
        })
    }
}
