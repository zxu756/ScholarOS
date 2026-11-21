import Foundation
import PDFKit
import Testing
import ScholarModels
import ScholarPDFProvenance

extension PDFProvenanceAndCitationGraphTests {

    private static var pdfSegmentation04cFixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pdf-segmentation-04c", isDirectory: true)
    }

    private static func lmWordTokensForOverlap(_ text: String) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: #"[A-Za-z0-9]+(?:\.[0-9]+)?"#) else {
            return []
        }
        let ns = text as NSString
        return rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased()
        }
    }

    @Test("S12-11: Default Latin Modern two-column justified math PDF avoids spurious intra-word spaces, yields 0 extra two-letter fragments, and achieves >= 98% word overlap")
    func s12LatinModernMathAndKerningAvoidsSpuriousIntraWordSpaces() throws {
        let pdfURL = Self.pdfSegmentation04cFixturesURL.appendingPathComponent("s12_lm_math_kerning.pdf")
        let chunks = try PDFMultiColumnSegmenter().segmentPDF(at: pdfURL, citeKey: "lmmath2026")

        let headerChunks = chunks.filter { $0.kind == .header }
        let footerChunks = chunks.filter { $0.kind == .footer }
        let bodyChunks = chunks.filter { $0.kind == .body }
        let headingChunks = chunks.filter { $0.kind == .sectionHeading }

        #expect(headerChunks.count == 2)
        #expect(footerChunks.count == 2)
        #expect(!bodyChunks.isEmpty)

        // 1. Margin headers and footers must be stripped cleanly without entering body chunks
        #expect(headerChunks.allSatisfy { $0.passageText.contains("Statistical Risk and Variance Bounds") })
        #expect(footerChunks.contains { $0.passageText == "Page 1 of 2" })
        #expect(footerChunks.contains { $0.passageText == "Page 2 of 2" })
        for body in bodyChunks {
            #expect(!body.passageText.contains("Statistical Risk and Variance Bounds"))
            #expect(!body.passageText.contains("Page 1 of 2"))
            #expect(!body.passageText.contains("Page 2 of 2"))
        }

        // 2. Section headings (Introduction and References) must be recognized
        let headingTexts = Set(headingChunks.map(\.passageText))
        #expect(headingTexts.contains("1 Introduction"))
        #expect(headingTexts.contains { $0.hasSuffix("References") })

        // 3. No intra-word spaces across Latin Modern / Computer Modern math, kerning pairs, italics, or period transitions
        let nonMarginChunks = chunks.filter { $0.kind != .header && $0.kind != .footer }
        let combinedNonMargin = nonMarginChunks.map(\.passageText).joined(separator: "\n")

        let forbiddenSplitSubstrings = [
            "f ollowing", "f ollowin", "af f", "ef f",
            "M t", "N d", "N ab", "M to", "4M t",
            "f (x)", "f (z)",
            "lo g", "Va r", "V ar", "populatio n", "tha t", "ri sk", "t he", "hold s"
        ]
        var foundForbiddenSplits: [String] = []
        for pat in forbiddenSplitSubstrings where combinedNonMargin.contains(pat) {
            foundForbiddenSplits.append(pat)
        }
        #expect(foundForbiddenSplits.isEmpty, "Found spurious intra-word split substrings: \(foundForbiddenSplits)")

        #expect(combinedNonMargin.contains("f(x), product terms Mt, Nd, Nab, and Mto"))
        #expect(combinedNonMargin.contains("following(x), affine(z), effective(w)"))
        #expect(combinedNonMargin.contains("To, Va, AV, Ta, We, Yo"))
        #expect(combinedNonMargin.contains("bounded. Following, holds. To, and valid. Va"))

        // 4. Compare against dehyphenated `pdftotext -raw` non-margin reference vocabulary:
        //    0 extra 2-letter alphabetic fragments and >= 98% multiset word overlap.
        let pdftotextReferenceNonMargin = """
        1 Introduction
        To understand why empirical risk minimization requires variance control under heavy-tailed noise, consider a hypothesis class over feature pairs. Following standard martingale arguments, we prove that the excess population risk holds with high probability whenever Var(Zi), log(2n/δ), and exp(−γM) remain bounded. Very sharp oracle inequalities follow when kerning pairs such as To, Va, AV, Ta, We, Yo and ligatures such as ff, fi, fl, ﬀi, ffl appear throughout justified columns.
        Notice that authors frequently mix upright operators log(n/δ), Var(g(Xk)), and exp(−tk) with italic variables f(x), product terms Mt, Nd, Nab, and Mto, subscripted capacities Nk and Vd, and multi-letter math-italic identifiers such as following(x), affine(z), effective(w), hold(Z), and risk(f). In italicized regime descriptions, the following population risk bound holds without splitting words. Period-adjacent transitions such as bounded. Following, holds. To, and valid. Va must preserve clean word boundaries.
        2 Oracle Inequalities and Tail Control
        Assume that independent observations X1,...,Xn satisfy Var(ℓ(f,Xi)) ≤ σ2 n for every predictor. Whenever tilting parameter γn ∈ (0,1) is active, it follows that the empirical objective satisfies
        R( ˆ fn) − R(f∗ ) ≤ 2Var(ℓf)log(Nk/δ) n + 4Mtlog(2/δ) 3n .
        Then, the following lower bounds on the population risk hold across discrete model families when f(x), Mt, Nd, and Tf(x) are evaluated at boundary points. Specifically, if log(1+exp(−ui)) denotes the logistic loss, then Var(θ̂n) scales inversely with sample size neﬀ and satisfies Pn(f) ̸= Qn(f) under covariate shift.
        3 Finite-Sample Concentration
        To verify that the excess risk bound holds uniformly, we decompose stochastic fluctuation into a variance term Var(Sn) and a logarithmic complexity term log(Md/δ). Across all candidate estimators, following population risk guarantees and asymptotic variance bounds remain valid even when f(z), Nab, Mto, affine(u), effective(v), and following(z) appear inline.
        In the second column of page one and continuing onto page two, kerning pairs To, Va, AV, and ligatures oﬀice, finite, flat, aﬀine, and shuffle test character-level glyph alignment. Every prose sentence after a period. That bound holds. Risk remains controlled. Following standard practice, upright logx, Var(Yi), and exp(λt) sit immediately adjacent to italic delimiters.
        4 Empirical Calibration
        Across 500 synthetic trials, average excess risk matches the theoretical logn/n rate without spurious word fragmentation. When evaluating f(x), Mt, Nd, Nab, affine(x), and Var(Zi) + log(n/δ) across two-column paragraphs, extracted tokens must match reference vocabulary without two-letter fragments.
        Furthermore, assume that the following oracle bound holds on the population risk whenever exp(−βHk) and Var(Uk) are finite. Sharp concentration holds for every block estimator across heavy-tailed distributions.
        5 Conclusion
        Aligning each selection character to its monotonic singlebaseline PDF glyph advance and calibrating inter-word clearance against the line’s bimodal spacing distribution prevents intra-word splits on Latin Modern and Computer Modern mathematical prose while preserving tight justified space recovery.
        6 References
        [1] O. Catoni, “Challenging the empirical mean and empirical variance,” Ann. Inst. H. Poincare, vol. 48, no. 4, pp. 1148–1185, 2012.
        [2] G. Lugosi and S. Mendelson, “Mean estimation and regression under heavy-tailed distributions,” Ann. Statist., vol. 47, no. 5, pp. 2238–2264, 2019.
        """

        var refCounts: [String: Int] = [:]
        for tok in Self.lmWordTokensForOverlap(pdftotextReferenceNonMargin) {
            refCounts[tok, default: 0] += 1
        }
        let extTokens = Self.lmWordTokensForOverlap(combinedNonMargin)
        var extCounts: [String: Int] = [:]
        for tok in extTokens {
            extCounts[tok, default: 0] += 1
        }

        var extraTwoLetterFragments: [String: Int] = [:]
        for (tok, cnt) in extCounts where tok.count == 2 && tok.allSatisfy(\.isLetter) {
            let excess = cnt - refCounts[tok, default: 0]
            if excess > 0 {
                extraTwoLetterFragments[tok] = excess
            }
        }
        let totalExtraTwoLetter = extraTwoLetterFragments.values.reduce(0, +)
        #expect(totalExtraTwoLetter == 0, "Expected 0 extra two-letter fragments vs pdftotext -raw, got \(totalExtraTwoLetter): \(extraTwoLetterFragments)")

        let refTotal = refCounts.values.reduce(0, +)
        let matchedTotal = refCounts.reduce(0) { acc, kv in
            acc + min(extCounts[kv.key, default: 0], kv.value)
        }
        let recall = Double(matchedTotal) / Double(max(1, refTotal))
        #expect(recall >= 0.98, "Expected multiset word overlap >= 98%, got \(String(format: "%.2f%%", recall * 100.0)) (\(matchedTotal)/\(refTotal))")
    }
}
