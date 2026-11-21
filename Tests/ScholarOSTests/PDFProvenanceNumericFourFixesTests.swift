import Foundation
import Testing
import ScholarModels
import ScholarPDFProvenance

extension PDFProvenanceAndCitationGraphTests {

    // MARK: - M4-02c Item 1: Qualifier-Distinguished Same-Noun Swaps ('of <noun>' & Same-Clause Unit Quantities)

    @Test("S13-8: Swapping values across same nouns distinguished by trailing 'of' qualifiers or same-clause unit quantities returns NUMERIC_MISMATCH while matching/unqualified/identical qualifiers return FOUND")
    func s13QualifierDistinguishedSameNounSwapsAndCounterexamples() throws {
        let locator = EvidenceLocatorAndNumericChecker()

        // 1A. Trailing `of <noun>` qualifier swap -> NUMERIC_MISMATCH pointing to each source value
        let membranePassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "desal2026#p3-c1-1",
                citeKey: "desal2026",
                pdfFileName: "desal2026.pdf",
                sectionTitle: "3 Experimental Manifold",
                columnIndex: 1,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 2, x: 54, y: 420, width: 230, height: 54),
                passageText: "The desalination manifold stores 42 vials of permeate and 6 vials of brine during membrane characterization.",
                kind: .body
            )
        ]

        let ofSwap = locator.locateEvidence(
            claim: "The desalination manifold stores 6 vials of permeate and 42 vials of brine during membrane characterization.",
            passages: membranePassages,
            pdfFileName: "desal2026.pdf"
        )
        #expect(ofSwap.verdict == .numericMismatch)
        #expect(ofSwap.page == 3)
        #expect(ofSwap.discrepancies.contains {
            $0.claimText.contains("6 vials") && ($0.pdfText?.contains("42 vials") == true)
        })
        #expect(ofSwap.discrepancies.contains {
            $0.claimText.contains("42 vials") && ($0.pdfText?.contains("6 vials") == true)
        })

        // Single-side swapped `of` qualifier -> NUMERIC_MISMATCH pointing to 42 vials
        let ofSingleSwap = locator.locateEvidence(
            claim: "The desalination manifold stores 6 vials of permeate during membrane characterization.",
            passages: membranePassages,
            pdfFileName: "desal2026.pdf"
        )
        #expect(ofSingleSwap.verdict == .numericMismatch)
        #expect(ofSingleSwap.discrepancies.contains {
            $0.claimText.contains("6 vials") && ($0.pdfText?.contains("42 vials") == true)
        })

        // 1B. Same-clause unit-bearing companion quantity swap (`; ` in passage vs ` and ` in claim) -> NUMERIC_MISMATCH
        let waferPassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "anneal2026#p4-c2-1",
                citeKey: "anneal2026",
                pdfFileName: "anneal2026.pdf",
                sectionTitle: "4 Thermal Protocol",
                columnIndex: 2,
                readingSequence: 2,
                boundingBox: PDFPageRegionBox(pageIndex: 3, x: 318, y: 380, width: 230, height: 56),
                passageText: "During annealing trials, the initial 24 wafers baked for 15 min; the remaining 8 wafers baked for 90 min.",
                kind: .body
            )
        ]

        let clauseSwap = locator.locateEvidence(
            claim: "During annealing trials, the initial 8 wafers baked for 15 min and the remaining 24 wafers baked for 90 min.",
            passages: waferPassages,
            pdfFileName: "anneal2026.pdf"
        )
        #expect(clauseSwap.verdict == .numericMismatch)
        #expect(clauseSwap.page == 4)
        #expect(clauseSwap.discrepancies.contains {
            $0.claimText.contains("8 wafers") && ($0.pdfText?.contains("24 wafers") == true)
        })
        #expect(clauseSwap.discrepancies.contains {
            $0.claimText.contains("24 wafers") && ($0.pdfText?.contains("8 wafers") == true)
        })

        // 1C. Counter-examples (must NOT false-report -> FOUND):
        // (i) Matching qualifiers (including converted unit companion 0.25 hours == 15 min, 1.5 hours == 90 min)
        let ofExact = locator.locateEvidence(
            claim: "The desalination manifold stores 42 vials of permeate and 6 vials of brine during membrane characterization.",
            passages: membranePassages
        )
        #expect(ofExact.verdict == .found)
        #expect(ofExact.discrepancies.isEmpty)

        let clauseConvertedMatch = locator.locateEvidence(
            claim: "During annealing trials, the initial 24 wafers baked for 0.25 hours and the remaining 8 wafers baked for 1.5 hours.",
            passages: waferPassages
        )
        #expect(clauseConvertedMatch.verdict == .found)
        #expect(clauseConvertedMatch.discrepancies.isEmpty)

        // (ii) Claim omits qualifiers -> FOUND
        let unqualifiedClaim = locator.locateEvidence(
            claim: "The desalination manifold stores 6 vials and 42 vials during membrane characterization.",
            passages: membranePassages
        )
        #expect(unqualifiedClaim.verdict == .found)

        // (iii) Identical qualifiers on both occurrences -> FOUND
        let sameQualifierPassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "desal2026#p5-c1-2",
                citeKey: "desal2026",
                pdfFileName: "desal2026.pdf",
                sectionTitle: "5 Staging",
                columnIndex: 1,
                readingSequence: 3,
                boundingBox: PDFPageRegionBox(pageIndex: 4, x: 54, y: 300, width: 230, height: 50),
                passageText: "The collector retains 42 vials of permeate in stage one and 6 vials of permeate in stage two.",
                kind: .body
            )
        ]
        let identicalQualifierClaim = locator.locateEvidence(
            claim: "The collector retains 6 vials of permeate in stage two.",
            passages: sameQualifierPassages
        )
        #expect(identicalQualifierClaim.verdict == .found)
    }

    // MARK: - M4-02c Item 2: Multiple Same-Noun Candidates Disambiguated by Surrounding Word Context

    @Test("S13-9: When a passage has multiple numbers for the same noun, discrepancy reporting selects the counterpart sharing surrounding context words")
    func s13SameNounMultipleCandidatesSelectsContextAlignedCounterpart() throws {
        let locator = EvidenceLocatorAndNumericChecker()

        let skyPassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "astro2026#p2-c1-1",
                citeKey: "astro2026",
                pdfFileName: "astro2026.pdf",
                sectionTitle: "2 Survey Catalog",
                columnIndex: 1,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 1, x: 54, y: 460, width: 230, height: 64),
                passageText: "Each calibration pointing images roughly 180 galaxies per field, whereas the compiled redshift catalog contains 64,820 galaxies across the southern sky.",
                kind: .body
            )
        ]

        // 1. Positive A: '6,482 galaxies' is numerically closer to 180 than to 64,820, but shares context 'compiled redshift catalog contains ... across southern sky' -> must report '64,820 galaxies'
        let catalogMismatch = locator.locateEvidence(
            claim: "The compiled redshift catalog contains 6,482 galaxies across the southern sky.",
            passages: skyPassages,
            pdfFileName: "astro2026.pdf"
        )
        #expect(catalogMismatch.verdict == .numericMismatch)
        #expect(catalogMismatch.discrepancies.count == 1)
        #expect(catalogMismatch.discrepancies.first?.claimText == "6,482 galaxies")
        #expect(catalogMismatch.discrepancies.first?.pdfText == "64,820 galaxies")

        // 2. Positive B: '50,000 galaxies per field' is numerically closer to 64,820 than to 180, but shares 'calibration pointing images ... per field' -> must report '180 galaxies'
        let fieldMismatch = locator.locateEvidence(
            claim: "Each calibration pointing images 50,000 galaxies per field in the redshift catalog.",
            passages: skyPassages,
            pdfFileName: "astro2026.pdf"
        )
        #expect(fieldMismatch.verdict == .numericMismatch)
        #expect(fieldMismatch.discrepancies.count == 1)
        #expect(fieldMismatch.discrepancies.first?.claimText == "50,000 galaxies")
        #expect(fieldMismatch.discrepancies.first?.pdfText == "180 galaxies")

        // 3. Counter-example: Grounded claim matching either number returns FOUND, and zero-context-overlap fallback keeps closest value
        let catalogFound = locator.locateEvidence(
            claim: "The compiled redshift catalog contains 64,820 galaxies across the southern sky.",
            passages: skyPassages
        )
        #expect(catalogFound.verdict == .found)
        #expect(catalogFound.discrepancies.isEmpty)

        let tiePassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "astro2026#p3-c1-2",
                citeKey: "astro2026",
                pdfFileName: "astro2026.pdf",
                sectionTitle: "3 Subsamples",
                columnIndex: 1,
                readingSequence: 2,
                boundingBox: PDFPageRegionBox(pageIndex: 2, x: 54, y: 380, width: 230, height: 52),
                passageText: "Across the southern sky redshift catalog, tier alpha includes 180 galaxies and tier beta includes 64,820 galaxies.",
                kind: .body
            )
        ]
        let zeroOverlapFallback = locator.locateEvidence(
            claim: "Across the southern sky redshift catalog, our subsample includes 210 galaxies.",
            passages: tiePassages
        )
        #expect(zeroOverlapFallback.verdict == .numericMismatch)
        #expect(zeroOverlapFallback.discrepancies.first?.pdfText == "180 galaxies")
    }

    // MARK: - M4-02c Item 3(a) & 3(b): Unit Abbreviations (Case-Sensitive b vs B) and Ranges / Dropped-Dash Ranges

    @Test("S13-10: Unit abbreviations ('16-bit' vs '(16 b)', 'kbps' vs 'kbit/s', 'ms' vs 'msec', case-sensitive 'b' vs 'B') and PDF ranges / dropped-dash ranges ('2448 kHz', '1224 bit') avoid false mismatches while catching genuine mismatches")
    func s13UnitAbbreviationsCaseSensitiveBitByteAndDroppedDashRanges() throws {
        let locator = EvidenceLocatorAndNumericChecker()

        // 3(a) Unit abbreviation equivalences (negative for mismatch -> FOUND)
        let neuralPassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "neuro2026#p3-c2-1",
                citeKey: "neuro2026",
                pdfFileName: "neuro2026.pdf",
                sectionTitle: "3 Telemetry ASIC",
                columnIndex: 2,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 2, x: 318, y: 500, width: 230, height: 64),
                passageText: "The implantable neural digitizer quantizes extracellular channels with (16 b) resolution, transmits telemetry at 256 kbps, buffers 32 kb frames, and flushes packets every 40 msec.",
                kind: .body
            )
        ]

        let abbrevFound = locator.locateEvidence(
            claim: "The implantable neural digitizer quantizes extracellular channels with 16-bit resolution, transmits telemetry at 256 kbit/s, buffers 32 kbit frames, and flushes packets every 40 ms.",
            passages: neuralPassages,
            pdfFileName: "neuro2026.pdf"
        )
        #expect(abbrevFound.verdict == .found)
        #expect(abbrevFound.discrepancies.isEmpty)

        // Byte-to-bit exact equivalence: 2 B == 16 b, 4 KB == 32 kb -> FOUND
        let byteConvertedFound = locator.locateEvidence(
            claim: "The implantable neural digitizer quantizes extracellular channels with 2 B resolution and buffers 4 KB frames.",
            passages: neuralPassages
        )
        #expect(byteConvertedFound.verdict == .found)

        // 3(a) Positive mismatch checks: case-sensitive '16 B' (16 bytes) vs '(16 b)' (16 bits), and '32 KB' vs '32 kb'
        let bitVsByteMismatch = locator.locateEvidence(
            claim: "The implantable neural digitizer quantizes extracellular channels with 16 B resolution and buffers 32 KB frames.",
            passages: neuralPassages
        )
        #expect(bitVsByteMismatch.verdict == .numericMismatch)
        #expect(bitVsByteMismatch.discrepancies.count == 2)
        #expect(bitVsByteMismatch.discrepancies.contains {
            $0.claimText.contains("16 B") && ($0.pdfText?.contains("16 b") == true)
        })
        #expect(bitVsByteMismatch.discrepancies.contains {
            $0.claimText.contains("32 KB") && ($0.pdfText?.contains("32 kb") == true)
        })

        // 3(b)-1 Dropped-dash range corroborated by intact '24–48' in passage context ('2448 kHz' -> [24, 48] kHz)
        let sonarPassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "sonar2026#p2-c1-1",
                citeKey: "sonar2026",
                pdfFileName: "sonar2026.pdf",
                sectionTitle: "2 Acoustic Array",
                columnIndex: 1,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 1, x: 54, y: 410, width: 230, height: 56),
                passageText: "Across the 24–48 kHz sonar band, our benthic array transmits 2448 kHz chirps over coastal transects.",
                kind: .body
            )
        ]

        let sonarRangeFound = locator.locateEvidence(
            claim: "Our benthic array transmits 24 to 48 kHz chirps over coastal transects.",
            passages: sonarPassages
        )
        #expect(sonarRangeFound.verdict == .found)

        let sonarEndpointFound = locator.locateEvidence(
            claim: "Our benthic array transmits 24 kHz chirps over coastal transects.",
            passages: sonarPassages
        )
        #expect(sonarEndpointFound.verdict == .found)

        // 3(b)-2 Dropped-dash range corroborated solely by concatenation of claim numbers ('12' + '24' == '1224')
        let mantissaPassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "sonar2026#p4-c2-2",
                citeKey: "sonar2026",
                pdfFileName: "sonar2026.pdf",
                sectionTitle: "4 Compression",
                columnIndex: 2,
                readingSequence: 2,
                boundingBox: PDFPageRegionBox(pageIndex: 3, x: 318, y: 360, width: 230, height: 50),
                passageText: "Acoustic envelope compression adapts dynamically across 1224 bit mantissas during benthic telemetry.",
                kind: .body
            )
        ]

        let concatRangeFound = locator.locateEvidence(
            claim: "Acoustic envelope compression adapts dynamically across 12–24 bit mantissas during benthic telemetry.",
            passages: mantissaPassages
        )
        #expect(concatRangeFound.verdict == .found)

        let concatTwoNumsFound = locator.locateEvidence(
            claim: "Acoustic envelope compression adapts dynamically across 12-bit and 24-bit mantissas during benthic telemetry.",
            passages: mantissaPassages
        )
        #expect(concatTwoNumsFound.verdict == .found)

        // 3(b)-3 Intact range in passage ('12–24 ms') satisfies endpoint/in-range claim without false '24 ms' mismatch
        let syncPassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "sonar2026#p5-c1-3",
                citeKey: "sonar2026",
                pdfFileName: "sonar2026.pdf",
                sectionTitle: "5 Synchronization",
                columnIndex: 1,
                readingSequence: 3,
                boundingBox: PDFPageRegionBox(pageIndex: 4, x: 54, y: 300, width: 230, height: 48),
                passageText: "Hydrophone synchronization settles within 12–24 ms across coastal moorings.",
                kind: .body
            )
        ]
        let inRangeFound = locator.locateEvidence(
            claim: "Hydrophone synchronization settles within 12 ms across coastal moorings.",
            passages: syncPassages
        )
        #expect(inRangeFound.verdict == .found)

        // 3(b)-4 Positive mismatch: genuine 4-digit count '1224' with no range context and single claim number '12' MUST still report NUMERIC_MISMATCH
        let pingCountPassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "sonar2026#p6-c1-4",
                citeKey: "sonar2026",
                pdfFileName: "sonar2026.pdf",
                sectionTitle: "6 Field Log",
                columnIndex: 1,
                readingSequence: 4,
                boundingBox: PDFPageRegionBox(pageIndex: 5, x: 54, y: 280, width: 230, height: 48),
                passageText: "The benthic survey cataloged 1224 hydrophone pings across coastal stations.",
                kind: .body
            )
        ]
        let genuine1224Mismatch = locator.locateEvidence(
            claim: "The benthic survey cataloged 12 hydrophone pings across coastal stations.",
            passages: pingCountPassages
        )
        #expect(genuine1224Mismatch.verdict == .numericMismatch)
        #expect(genuine1224Mismatch.discrepancies.contains {
            $0.claimText.contains("12 hydrophone pings") && ($0.pdfText == "1224 hydrophone pings")
        })
    }

    // MARK: - M4-02c Item 3(c): Any Passing Candidate Matching All Claim Numbers Returns FOUND

    @Test("S13-11: Among all candidates passing the keyword threshold, if any passage satisfies every claim number by noun or dimension, return FOUND pointing to that passage without weakening the keyword threshold")
    func s13AnyPassingCandidateSatisfyingAllNumbersReturnsFound() throws {
        let locator = EvidenceLocatorAndNumericChecker()

        // Case 1: Highest-coverage candidate (Page 1, cov = 1.00) misses '180 m' and carries an extra '5 km',
        // while Page 5 candidate (cov = 0.70 >= 0.60) matches both '36 borehole sensors' and '180 m' -> must return FOUND on Page 5
        let seismicPassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "seis2026#p1-c1-1",
                citeKey: "seis2026",
                pdfFileName: "seis2026.pdf",
                sectionTitle: "Abstract",
                columnIndex: 1,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 0, x: 54, y: 600, width: 230, height: 60),
                passageText: "Within 5 km of the alpine fault zone, our distributed acoustic array deploys 36 borehole sensors to monitor microseismic depth.",
                kind: .body
            ),
            PDFPassageChunk(
                id: "seis2026#p5-c2-4",
                citeKey: "seis2026",
                pdfFileName: "seis2026.pdf",
                sectionTitle: "3 Field Deployment",
                columnIndex: 2,
                readingSequence: 4,
                boundingBox: PDFPageRegionBox(pageIndex: 4, x: 318, y: 410, width: 230, height: 54),
                passageText: "In field installation, our distributed acoustic array deploys 36 borehole sensors at 180 m depth.",
                kind: .body
            ),
            // Sub-threshold distractor (cov = 2/10 = 0.20 < 0.60) with invented numbers: must NEVER pass threshold
            PDFPassageChunk(
                id: "seis2026#p8-c1-9",
                citeKey: "seis2026",
                pdfFileName: "seis2026.pdf",
                sectionTitle: "Appendix",
                columnIndex: 1,
                readingSequence: 9,
                boundingBox: PDFPageRegionBox(pageIndex: 7, x: 54, y: 200, width: 230, height: 48),
                passageText: "Synthetic calibration simulates 99 borehole sensors at 500 m depth.",
                kind: .body
            )
        ]

        let foundPage5 = locator.locateEvidence(
            claim: "Our distributed acoustic array deploys 36 borehole sensors at 180 m depth across the alpine fault zone.",
            passages: seismicPassages,
            pdfFileName: "seis2026.pdf"
        )
        #expect(foundPage5.verdict == .found)
        #expect(foundPage5.page == 5)
        #expect(foundPage5.sectionTitle == "3 Field Deployment")
        #expect(foundPage5.discrepancies.isEmpty)

        // Case 2: Highest-coverage candidate (Page 2 Related Work, cov = 1.00) has prior-work numbers,
        // while Page 6 Results (cov = 0.67 >= 0.60, > 0.15 below 1.00) matches all numbers -> FOUND on Page 6
        let latencyPassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "seis2026#p2-c1-2",
                citeKey: "seis2026",
                pdfFileName: "seis2026.pdf",
                sectionTitle: "2 Related Work",
                columnIndex: 1,
                readingSequence: 2,
                boundingBox: PDFPageRegionBox(pageIndex: 1, x: 54, y: 500, width: 230, height: 58),
                passageText: "Conventional geophone networks deploy 12 borehole sensors with 85 ms telemetry latency across the alpine fault zone.",
                kind: .body
            ),
            PDFPassageChunk(
                id: "seis2026#p6-c1-5",
                citeKey: "seis2026",
                pdfFileName: "seis2026.pdf",
                sectionTitle: "4 Telemetry Results",
                columnIndex: 1,
                readingSequence: 5,
                boundingBox: PDFPageRegionBox(pageIndex: 5, x: 54, y: 420, width: 230, height: 52),
                passageText: "Our distributed network deploys 36 borehole sensors with 12 ms telemetry latency.",
                kind: .body
            )
        ]

        let foundPage6 = locator.locateEvidence(
            claim: "The network deploys 36 borehole sensors with 12 ms telemetry latency across the alpine fault zone.",
            passages: latencyPassages,
            pdfFileName: "seis2026.pdf"
        )
        #expect(foundPage6.verdict == .found)
        #expect(foundPage6.page == 6)
        #expect(foundPage6.discrepancies.isEmpty)

        // Positive check: sub-threshold Page 8 distractor ('99 borehole sensors at 500 m depth') does NOT rescue a wrong claim
        let stillMismatch = locator.locateEvidence(
            claim: "Our distributed acoustic array deploys 99 borehole sensors at 500 m depth across the alpine fault zone.",
            passages: seismicPassages,
            pdfFileName: "seis2026.pdf"
        )
        #expect(stillMismatch.verdict == .numericMismatch)
        #expect(stillMismatch.page != 8)
    }

    // MARK: - M4-02c Item 4: Unit-Magnitude Errors ('cm' vs 'm', 'km' vs 'm', 'mg' vs 'g', 'ms' vs 's', 'MB' vs 'GB')

    @Test("S13-12: Unit-magnitude errors with identical numeric value in the same dimension select the source passage containing that value and report the exact source number")
    func s13UnitMagnitudeErrorsSelectPassageAndReportSourceNumber() throws {
        let locator = EvidenceLocatorAndNumericChecker()

        // 1. Length scale mismatch ('18 m' claim vs Page 1 numberless cov=1.00, Page 2 '3 m' cov=0.89, Page 4 '18 cm' cov=0.78)
        // Must select Page 4 and report '18 cm' (never nil and never '3 m')
        let glacierPassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "ice2026#p1-c1-1",
                citeKey: "ice2026",
                pdfFileName: "ice2026.pdf",
                sectionTitle: "Abstract",
                columnIndex: 1,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 0, x: 54, y: 620, width: 230, height: 55),
                passageText: "The thermal melt probe penetrates glacial firn cores cleanly during polar extraction.",
                kind: .body
            ),
            PDFPassageChunk(
                id: "ice2026#p2-c2-2",
                citeKey: "ice2026",
                pdfFileName: "ice2026.pdf",
                sectionTitle: "2 Rig Geometry",
                columnIndex: 2,
                readingSequence: 2,
                boundingBox: PDFPageRegionBox(pageIndex: 1, x: 318, y: 510, width: 230, height: 55),
                passageText: "Mounted on a 3 m gantry, the thermal melt probe penetrates glacial firn cores.",
                kind: .body
            ),
            PDFPassageChunk(
                id: "ice2026#p4-c1-5",
                citeKey: "ice2026",
                pdfFileName: "ice2026.pdf",
                sectionTitle: "4 Melt Penetration",
                columnIndex: 1,
                readingSequence: 5,
                boundingBox: PDFPageRegionBox(pageIndex: 3, x: 54, y: 400, width: 230, height: 55),
                passageText: "In bench tests, the thermal melt probe penetrates up to 18 cm in glacial firn cores.",
                kind: .body
            )
        ]

        let lengthScaleMismatch = locator.locateEvidence(
            claim: "The thermal melt probe penetrates up to 18 m in glacial firn cores during polar extraction.",
            passages: glacierPassages,
            pdfFileName: "ice2026.pdf"
        )
        #expect(lengthScaleMismatch.verdict == .numericMismatch)
        #expect(lengthScaleMismatch.page == 4)
        #expect(lengthScaleMismatch.discrepancies.contains {
            $0.claimText.contains("18 m") && ($0.pdfText == "18 cm")
        })

        // km vs m in single passage with competing m value ('2 km' cable vs '350 m' tether, claim says '350 km')
        let kmVsMPassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "ice2026#p7-c1-7",
                citeKey: "ice2026",
                pdfFileName: "ice2026.pdf",
                sectionTitle: "5 Telemetry Tether",
                columnIndex: 1,
                readingSequence: 7,
                boundingBox: PDFPageRegionBox(pageIndex: 6, x: 54, y: 360, width: 230, height: 52),
                passageText: "Along the 2 km glacier transect, spooling payout reaches 350 m before anchor lock.",
                kind: .body
            )
        ]
        let kmMismatch = locator.locateEvidence(
            claim: "Along the glacier transect, maximum spooling payout reaches 350 km.",
            passages: kmVsMPassages
        )
        #expect(kmMismatch.verdict == .numericMismatch)
        #expect(kmMismatch.discrepancies.first?.pdfText == "350 m")

        // 2. Memory & duration scale mismatch when passage puts noun before verb ('memory stays at 48 MB' vs '2 GB memory')
        let memPassages: [PDFPassageChunk] = [
            PDFPassageChunk(
                id: "mem2026#p2-c1-1",
                citeKey: "mem2026",
                pdfFileName: "mem2026.pdf",
                sectionTitle: "2 Prior Systems",
                columnIndex: 1,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 1, x: 54, y: 500, width: 230, height: 50),
                passageText: "Legacy hydrological solvers allocate 2 GB memory during watershed routing.",
                kind: .body
            ),
            PDFPassageChunk(
                id: "mem2026#p5-c2-3",
                citeKey: "mem2026",
                pdfFileName: "mem2026.pdf",
                sectionTitle: "4 Watershed Routing",
                columnIndex: 2,
                readingSequence: 3,
                boundingBox: PDFPageRegionBox(pageIndex: 4, x: 318, y: 400, width: 230, height: 50),
                passageText: "During watershed routing, peak solver allocation stays at 48 MB.",
                kind: .body
            )
        ]
        let gbVsMbMismatch = locator.locateEvidence(
            claim: "During watershed routing, the solver allocates 48 GB memory.",
            passages: memPassages,
            pdfFileName: "mem2026.pdf"
        )
        #expect(gbVsMbMismatch.verdict == .numericMismatch)
        #expect(gbVsMbMismatch.page == 5)
        #expect(gbVsMbMismatch.discrepancies.first?.pdfText == "48 MB")

        // 3. Counter-examples: true unit conversion ('0.18 m' == '18 cm', '0.35 km' == '350 m', '0.048 GB' == '48 MB') -> FOUND
        let cmConvertedFound = locator.locateEvidence(
            claim: "The thermal melt probe penetrates up to 0.18 m in glacial firn cores during polar extraction.",
            passages: glacierPassages
        )
        #expect(cmConvertedFound.verdict == .found)
        #expect(cmConvertedFound.page == 4)

        let kmConvertedFound = locator.locateEvidence(
            claim: "Along the glacier transect, maximum spooling payout reaches 0.35 km.",
            passages: kmVsMPassages
        )
        #expect(kmConvertedFound.verdict == .found)
    }
}
