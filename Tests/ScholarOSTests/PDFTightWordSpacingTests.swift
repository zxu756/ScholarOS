import Foundation
import PDFKit
import Testing
import ScholarModels
import ScholarPDFProvenance

extension PDFProvenanceAndCitationGraphTests {

    private static var pdfSegmentation04bFixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pdf-segmentation-04b", isDirectory: true)
    }

    private static func wordTokensForOverlap(_ text: String) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: #"[A-Za-z0-9]+(?:\.[0-9]+)?"#) else {
            return []
        }
        let ns = text as NSString
        return rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased()
        }
    }

    @Test("S12-10: Tightly justified two-column PDF (~2.2pt word gaps) recovers inter-word spaces without glued words, strips Page N of M footers, and achieves >= 95% word overlap")
    func s12TightWordSpacingRecoversInterWordSpacesAndStripsMargins() throws {
        let pdfURL = Self.pdfSegmentation04bFixturesURL.appendingPathComponent("s12_tight_word_spacing.pdf")
        let chunks = try PDFMultiColumnSegmenter().segmentPDF(at: pdfURL, citeKey: "tight2026")

        let headerChunks = chunks.filter { $0.kind == .header }
        let footerChunks = chunks.filter { $0.kind == .footer }
        let bodyChunks = chunks.filter { $0.kind == .body }
        let headingChunks = chunks.filter { $0.kind == .sectionHeading }

        #expect(headerChunks.count == 2)
        #expect(footerChunks.count == 2)
        #expect(!bodyChunks.isEmpty)

        // 1. Repeating headers and "Page N of M" footers must be recognized with spaces intact and never enter body chunks
        #expect(headerChunks.allSatisfy { $0.passageText.contains("Autonomous Planetary Robotics Review") })
        #expect(footerChunks.contains { $0.passageText == "Page 1 of 2" })
        #expect(footerChunks.contains { $0.passageText == "Page 2 of 2" })
        for body in bodyChunks {
            #expect(!body.passageText.contains("Autonomous Planetary Robotics Review"))
            #expect(!body.passageText.contains("AutonomousPlanetaryRoboticsReview"))
            #expect(!body.passageText.contains("Page 1 of 2"))
            #expect(!body.passageText.contains("Page 2 of 2"))
            #expect(!body.passageText.contains("Page1of2"))
            #expect(!body.passageText.contains("Page2of2"))
        }

        // 2. Section headings (including Introduction and References) must be recognized
        let headingTexts = Set(headingChunks.map(\.passageText))
        #expect(headingTexts.contains("1 Introduction"))
        #expect(headingTexts.contains("References"))

        // 3. No glued long alphanumeric words (>= 19 letters without internal hyphen) in non-margin chunks
        let nonMarginChunks = chunks.filter { $0.kind != .header && $0.kind != .footer }
        let combinedNonMargin = nonMarginChunks.map(\.passageText).joined(separator: "\n")
        let plainAlphaTokens = Self.wordTokensForOverlap(combinedNonMargin)
        let gluedLongTokens = plainAlphaTokens.filter { $0.count >= 19 }
        #expect(gluedLongTokens.isEmpty, "Found glued long tokens: \(gluedLongTokens)")

        // 4. Preserve number+unit spacing ("2.5 m", "40 ms"), intra-line hyphens, and math symbols
        #expect(combinedNonMargin.contains("2.5 m"))
        #expect(combinedNonMargin.contains("40 ms"))
        #expect(combinedNonMargin.contains("3.4%"))
        #expect(combinedNonMargin.contains("1,200 simulated episodes"))
        #expect(combinedNonMargin.contains("whole-body"))
        #expect(combinedNonMargin.contains("safety-constrained"))
        #expect(combinedNonMargin.contains("joint-limit"))
        #expect(combinedNonMargin.contains("multi-step"))
        #expect(combinedNonMargin.contains("S ⊂ R"))
        #expect(combinedNonMargin.contains("γ = 0.99"))

        // 5. Multiset word overlap against reference prose vocabulary must be >= 95%
        let referenceProse = """
        1 Introduction
        Robotic platforms operating across unstructured planetary terrains must preserve closed-loop stability while executing whole-body manipulation tasks under severe communication latency. When typesetting templates compress justified inter-word spaces toward two points, naive selection strings silently concatenate adjacent words into unreadable tokens.
        Beyond locomotion, autonomous surface missions require coordinated force control, real-time obstacle avoidance, and explicit safety verification across irregular regolith slopes. Our controller enforces torque bounds up to 2.5 m from the base frame while tolerating actuation delays of 40 ms during contact transitions.
        2 Constrained Policy Architecture
        We formulate terrain-aware whole-body control over state space S R with bounded disturbance parameter 0 1 and discount factor 0.99. Rather than relying on hand-tuned penalty weights, each joint-limit violation triggers a calibrated termination probability during rollout collection.
        Across 1,200 simulated episodes on Crater-Bench, low-level tracking error remains below 3.4% without sacrificing end-effector responsiveness. Hyphenated compound descriptors such as safety-constrained and hardware-in-the-loop retain their internal hyphens across column line breaks and never split mid-word.
        3 System Calibration
        Actuator torque observers continuously estimate contact wrenches from joint-encoder histories and inertial-measurement streams without external force-torque sensors. Calibration sweeps across regolith simulant beds confirm repeatable foot-ground impedance behavior under variable normal loads.
        4 Experimental Evaluation
        To evaluate robustness under realistic inertial uncertainty, we randomize payload mass, terrain friction, and actuator damping across five difficulty tiers. Every policy checkpoint is tested on steep unconsolidated slopes, embedded boulders, and recessed sample-cache receptacles before deployment.
        Quantitative comparisons confirm that constrained rollouts eliminate catastrophic knee-torque spikes while maintaining smooth velocity profiles throughout multi-step grasping sequences. Both left and right prose columns maintain strict reading order from top to bottom on every page of the manuscript.
        5 Conclusion
        Recovering exact horizontal glyph clearances from PDF page streams prevents word concatenation on tightly justified two-column layouts while keeping margin headers and page footers cleanly separated from body passages.
        References
        1 A. Rivera and K. Lindholm, Geometric word-boundary recovery in tightly justified scientific documents, Proc. Int. Conf. Document Analysis, pp. 104 115, 2025.
        2 C. Okafor, Safety-constrained locomotion over deformable lunar regolith, J. Field Robotics, vol. 43, no. 2, pp. 210 228, 2026.
        """

        var refCounts: [String: Int] = [:]
        for tok in Self.wordTokensForOverlap(referenceProse) {
            refCounts[tok, default: 0] += 1
        }
        var extCounts: [String: Int] = [:]
        for tok in plainAlphaTokens {
            extCounts[tok, default: 0] += 1
        }
        let refTotal = refCounts.values.reduce(0, +)
        let matchedTotal = refCounts.reduce(0) { acc, kv in
            acc + min(extCounts[kv.key, default: 0], kv.value)
        }
        let recall = Double(matchedTotal) / Double(max(1, refTotal))
        #expect(recall >= 0.95, "Expected multiset word overlap >= 95%, got \(String(format: "%.2f%%", recall * 100.0)) (\(matchedTotal)/\(refTotal))")
    }
}
