import Foundation
import ScholarModels

// MARK: - PRISMA 2020 Dual-Blind Screening Engine, Cohen's Kappa & PABAK

public final class PRISMAScreeningEngine: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var protocolSpec: PICOProtocolSpec
    private var studiesByID: [String: ScreeningStudyRecord] = [:]
    private var orderedStudyIDs: [String] = []
    public var duplicateRecordsRemovedCount: Int
    public var registerRecordsIdentifiedCount: Int
    public var reportsNotRetrievedCount: Int

    public init(
        protocolSpec: PICOProtocolSpec = PRISMAScreeningEngine.defaultPICOProtocol(),
        studies: [ScreeningStudyRecord] = [],
        duplicateRecordsRemovedCount: Int = 0,
        registerRecordsIdentifiedCount: Int = 0,
        reportsNotRetrievedCount: Int = 0
    ) {
        self.protocolSpec = protocolSpec
        self.duplicateRecordsRemovedCount = duplicateRecordsRemovedCount
        self.registerRecordsIdentifiedCount = registerRecordsIdentifiedCount
        self.reportsNotRetrievedCount = reportsNotRetrievedCount
        for study in studies {
            studiesByID[study.id] = study
            orderedStudyIDs.append(study.id)
        }
    }

    public static func defaultPICOProtocol() -> PICOProtocolSpec {
        PICOProtocolSpec(
            reviewTitle: "Hardware-Isolated Agent Execution & Verifiable Tool Sandboxes: A PRISMA 2020 Systematic Review",
            population: "Autonomous LLM coding, research, and computer-use agent runtimes",
            intervention: "MicroVM virtualization, capability-based sandboxing, or cryptographic provenance gates",
            comparator: "Unconfined host shell execution or container-only shared-kernel baselines",
            outcomes: "Boot latency, memory overhead, escape surface reduction, and benchmark task pass rate",
            inclusionCriteria: [
                "Peer-reviewed systems/security paper or verified technical report (2020–2026)",
                "Evaluates concrete isolation or provenance mechanisms with empirical benchmarks",
                "Reports quantitative latency, throughput, or security containment metrics"
            ],
            exclusionRules: [
                ExclusionReasonRule(priorityOrder: 1, code: "E1_OFF_TOPIC", label: "Not related to autonomous agent sandboxing or provenance"),
                ExclusionReasonRule(priorityOrder: 2, code: "E2_NO_EMPIRICAL_EVAL", label: "Position paper or editorial without empirical evaluation"),
                ExclusionReasonRule(priorityOrder: 3, code: "E3_CONTAINER_ONLY", label: "Evaluates generic container orchestration without isolation metrics"),
                ExclusionReasonRule(priorityOrder: 4, code: "E4_NON_PRIMARY", label: "Secondary survey or duplicate preprint superseded by camera-ready")
            ]
        )
    }

    public func updateProtocol(_ updated: PICOProtocolSpec) throws {
        let codes = updated.exclusionRules.map(\.code)
        guard !codes.isEmpty, Set(codes).count == codes.count else {
            throw ScholarOSError.prismaProtocolViolation("Exclusion reason codes must be non-empty and unique.")
        }
        lock.lock()
        defer { lock.unlock() }
        self.protocolSpec = updated
    }

    public func ingestStudies(_ incoming: [ScreeningStudyRecord], deduplicateByDOIAndTitle: Bool = true) -> Int {
        lock.lock()
        defer { lock.unlock() }

        var removedDuplicates = 0
        for candidate in incoming {
            if deduplicateByDOIAndTitle {
                let isDuplicate = studiesByID.values.contains { existing in
                    if let d1 = existing.doi?.lowercased(), let d2 = candidate.doi?.lowercased(), !d1.isEmpty, d1 == d2 {
                        return true
                    }
                    let t1 = Self.normalizeTitle(existing.title)
                    let t2 = Self.normalizeTitle(candidate.title)
                    return !t1.isEmpty && t1 == t2 && existing.year == candidate.year
                }
                if isDuplicate {
                    removedDuplicates += 1
                    duplicateRecordsRemovedCount += 1
                    continue
                }
            }
            if studiesByID[candidate.id] == nil {
                orderedStudyIDs.append(candidate.id)
            }
            studiesByID[candidate.id] = candidate
        }
        return removedDuplicates
    }

    public func allStudies() -> [ScreeningStudyRecord] {
        lock.lock()
        defer { lock.unlock() }
        return orderedStudyIDs.compactMap { studiesByID[$0] }
    }

    /// Blinded Reviewer A vote — Reviewer B's vote is hidden while voting!
    public func castReviewerAVote(studyID: String, decision: ScreeningDecision) throws {
        try validateDecisionAgainstProtocol(decision)
        lock.lock()
        defer { lock.unlock() }
        guard var study = studiesByID[studyID] else {
            throw ScholarOSError.prismaProtocolViolation("Unknown study ID '\(studyID)'")
        }
        study.reviewerADecision = decision
        autoAdvanceIfConsensus(&study)
        studiesByID[studyID] = study
    }

    /// Blinded Reviewer B vote — Reviewer A's vote is hidden while voting!
    public func castReviewerBVote(studyID: String, decision: ScreeningDecision) throws {
        try validateDecisionAgainstProtocol(decision)
        lock.lock()
        defer { lock.unlock() }
        guard var study = studiesByID[studyID] else {
            throw ScholarOSError.prismaProtocolViolation("Unknown study ID '\(studyID)'")
        }
        study.reviewerBDecision = decision
        autoAdvanceIfConsensus(&study)
        studiesByID[studyID] = study
    }

    /// Third-reviewer conflict adjudication with mandatory rationale.
    public func adjudicateConflict(studyID: String, finalDecision: ScreeningDecision, rationale: String) throws {
        try validateDecisionAgainstProtocol(finalDecision)
        guard !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScholarOSError.prismaProtocolViolation("Conflict adjudication requires an explicit written rationale.")
        }
        lock.lock()
        defer { lock.unlock() }
        guard var study = studiesByID[studyID] else {
            throw ScholarOSError.prismaProtocolViolation("Unknown study ID '\(studyID)'")
        }
        study.adjudicatedDecision = finalDecision
        study.adjudicationRationale = rationale
        if finalDecision == .include && study.stage == .titleAbstract {
            study.stage = .fullText
        }
        studiesByID[studyID] = study
    }

    public func conflictedStudies() -> [ScreeningStudyRecord] {
        allStudies().filter(\.hasReviewerConflict)
    }

    /// Computes complete PRISMA 2020 flow counts alongside nominal Cohen's $\kappa$ and Brennan-Prediger PABAK over `ScreeningDecision` categories.
    public func computePRISMA2020Metrics() -> PRISMA2020SummaryMetrics {
        let studies = allStudies()
        let screened = studies.count
        let dbIdentified = screened + duplicateRecordsRemovedCount

        var taExcluded = 0
        var ftExcludedByCode: [String: Int] = [:]
        var finalIncluded = 0

        var pairedCount = 0
        var agreements = 0
        var countsA: [ScreeningDecision: Int] = [:]
        var countsB: [ScreeningDecision: Int] = [:]
        var categories = Set<ScreeningDecision>()

        for study in studies {
            if let a = study.reviewerADecision, let b = study.reviewerBDecision {
                pairedCount += 1
                if a == b {
                    agreements += 1
                }
                countsA[a, default: 0] += 1
                countsB[b, default: 0] += 1
                categories.insert(a)
                categories.insert(b)
            }

            let effectiveDecision = study.adjudicatedDecision ?? consensusDecision(study)
            switch (study.stage, effectiveDecision) {
            case (.titleAbstract, .exclude):
                taExcluded += 1
            case (.fullText, .exclude(let code)):
                ftExcludedByCode[code, default: 0] += 1
            case (.fullText, .include):
                finalIncluded += 1
            case (.titleAbstract, .include):
                // Promoted or included directly
                finalIncluded += 1
            default:
                break
            }
        }

        let soughtForRetrieval = max(0, screened - taExcluded)
        let ftAssessed = max(0, soughtForRetrieval - reportsNotRetrievedCount)

        let po: Double
        let kappa: Double
        let pabak: Double
        if pairedCount > 0 {
            let n = Double(pairedCount)
            po = Double(agreements) / n
            var peNumerator = 0.0
            for cat in categories {
                let fa = Double(countsA[cat] ?? 0)
                let fb = Double(countsB[cat] ?? 0)
                peNumerator += fa * fb
            }
            let pe = peNumerator / (n * n)
            if abs(1.0 - pe) < 1e-12 {
                kappa = 1.0
            } else {
                kappa = (po - pe) / (1.0 - pe)
            }
            let k = max(2, categories.count)
            pabak = (Double(k) * po - 1.0) / Double(k - 1)
        } else {
            po = 1.0
            kappa = 1.0
            pabak = 1.0
        }

        return PRISMA2020SummaryMetrics(
            databaseRecordsIdentified: dbIdentified,
            registerRecordsIdentified: registerRecordsIdentifiedCount,
            duplicateRecordsRemoved: duplicateRecordsRemovedCount,
            recordsScreenedTitleAbstract: screened,
            recordsExcludedTitleAbstract: taExcluded,
            reportsSoughtForRetrieval: soughtForRetrieval,
            reportsNotRetrieved: reportsNotRetrievedCount,
            fullTextAssessed: ftAssessed,
            fullTextExcludedByReason: ftExcludedByCode,
            finalIncludedStudies: finalIncluded,
            observedAgreementRate: po,
            cohensKappa: kappa,
            pabakScore: pabak
        )
    }

    private func validateDecisionAgainstProtocol(_ decision: ScreeningDecision) throws {
        if case .exclude(let code) = decision {
            let validCodes = Set(protocolSpec.exclusionRules.map(\.code))
            guard validCodes.contains(code) else {
                throw ScholarOSError.prismaProtocolViolation("Exclusion code '\(code)' is not registered in the active PICO protocol.")
            }
        }
    }

    private func consensusDecision(_ study: ScreeningStudyRecord) -> ScreeningDecision? {
        guard let a = study.reviewerADecision, let b = study.reviewerBDecision, a == b else {
            return nil
        }
        return a
    }

    private func autoAdvanceIfConsensus(_ study: inout ScreeningStudyRecord) {
        if study.stage == .titleAbstract,
           study.reviewerADecision == .include,
           study.reviewerBDecision == .include {
            study.stage = .fullText
        }
    }

    private static func normalizeTitle(_ raw: String) -> String {
        raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
