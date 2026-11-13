import Foundation
import Testing
import ScholarModels
import ScholarPRISMAEngine

@Suite("PRISMA 2020 Screening, Psychometrics, RoB 2.0 & Meta-Analysis")
struct PRISMAAndPsychometricsTests {

    // MARK: - Helpers

    private func makeStudy(
        id: String,
        citeKey: String? = nil,
        title: String = "Empirical Sandboxed Evaluation Study",
        year: Int = 2025,
        doi: String? = nil,
        stage: ScreeningStage = .titleAbstract,
        revA: ScreeningDecision? = nil,
        revB: ScreeningDecision? = nil
    ) -> ScreeningStudyRecord {
        ScreeningStudyRecord(
            id: id,
            citeKey: citeKey ?? id,
            title: title,
            authorsLine: "Rostova, E. & Takahashi, K.",
            year: year,
            venue: "IEEE S&P",
            doi: doi,
            abstractText: "Autonomous agent microVM sandboxing benchmark measuring boot latency, escape surface, and throughput.",
            stage: stage,
            reviewerADecision: revA,
            reviewerBDecision: revB
        )
    }

    // MARK: - 1. Cohen's Kappa (Unweighted, Linear, Quadratic), PABAK, Fleiss' Kappa & Gwet's AC1

    @Test("KappaWeightingScheme verifies unweighted, Cicchetti-Allison linear, and Fleiss-Cohen quadratic weights")
    func kappaWeightingSchemesVerifyExactWeights() {
        // 4 ordered categories: indices 0, 1, 2, 3 (max distance = 3)
        #expect(KappaWeightingScheme.unweighted.agreementWeight(categoryIndexA: 1, categoryIndexB: 1, categoryCount: 4) == 1.0)
        #expect(KappaWeightingScheme.unweighted.agreementWeight(categoryIndexA: 1, categoryIndexB: 2, categoryCount: 4) == 0.0)

        // Linear weight: 1 - |1 - 2| / (4 - 1) = 2/3
        let linear = KappaWeightingScheme.linearCicchettiAllison.agreementWeight(categoryIndexA: 1, categoryIndexB: 2, categoryCount: 4)
        #expect(abs(linear - (2.0 / 3.0)) < 1e-9)

        // Quadratic weight: 1 - (1 - 2)^2 / (4 - 1)^2 = 1 - 1/9 = 8/9
        let quad = KappaWeightingScheme.quadraticFleissCohen.agreementWeight(categoryIndexA: 1, categoryIndexB: 2, categoryCount: 4)
        #expect(abs(quad - (8.0 / 9.0)) < 1e-9)
        #expect(quad > linear)
    }

    @Test("Dual-rater Cohen's kappa matches exact hand-calculated 2x2 formula, CI bounds, and Landis-Koch band")
    func dualRaterCohensKappaMatchesExactClosedForm() {
        let spec = PRISMAScreeningEngine.defaultPICOProtocol()
        // 2x2 table over N = 20:
        // Both Positive (++): 8
        // A+ B- (+-): 1
        // A- B+ (-+): 1
        // Both Negative (--): 10
        // Po = (8 + 10)/20 = 0.90
        // P(A+) = 9/20 = 0.45, P(B+) = 9/20 = 0.45 -> 0.2025
        // P(A-) = 11/20 = 0.55, P(B-) = 11/20 = 0.55 -> 0.3025
        // Pe = 0.505 -> kappa = (0.90 - 0.505) / (1 - 0.505) = 0.395 / 0.495 = 0.79797979...
        // PABAK = 2 * 0.90 - 1 = 0.80
        var studies: [ScreeningStudyRecord] = []
        for idx in 1...8 {
            studies.append(makeStudy(id: "pp\(idx)", revA: .include, revB: .include))
        }
        studies.append(makeStudy(id: "pn1", revA: .include, revB: .exclude(reasonCode: "E1_OFF_TOPIC")))
        studies.append(makeStudy(id: "np1", revA: .exclude(reasonCode: "E1_OFF_TOPIC"), revB: .include))
        for idx in 1...10 {
            studies.append(makeStudy(id: "nn\(idx)", revA: .exclude(reasonCode: "E1_OFF_TOPIC"), revB: .exclude(reasonCode: "E1_OFF_TOPIC")))
        }

        let qc = InterRaterReliabilityAndSeedQCEngine()
        let reportLinear = qc.evaluateDualRaterAgreement(
            studies: studies,
            protocolSpec: spec,
            multiclassWeighting: .linearCicchettiAllison
        )
        let reportQuadratic = qc.evaluateDualRaterAgreement(
            studies: studies,
            protocolSpec: spec,
            multiclassWeighting: .quadraticFleissCohen
        )

        #expect(reportLinear.evaluatedStudyCount == 20)
        #expect(abs(reportLinear.observedProportionAgreement - 0.90) < 1e-9)
        #expect(abs(reportLinear.cohensKappa.pointEstimate - (0.395 / 0.495)) < 1e-6)
        #expect(abs(reportLinear.byrtsPABAK.pointEstimate - 0.80) < 1e-9)
        #expect(reportLinear.cohensKappa.lowerCI < reportLinear.cohensKappa.pointEstimate)
        #expect(reportLinear.cohensKappa.upperCI > reportLinear.cohensKappa.pointEstimate)
        #expect(reportLinear.cohensKappa.benchmarkBand == .substantial)
        #expect(reportLinear.cohensKappa.benchmarkBand.meetsPRISMACalibrationGate)
        #expect(reportQuadratic.weightedMulticlassKappa.pointEstimate >= reportLinear.weightedMulticlassKappa.pointEstimate - 1e-9)
    }

    @Test("Byrt's PABAK and Gwet's AC1 stay resilient under the Feinstein-Cicchetti high-prevalence paradox")
    func pabakAndGwetsAC1UnderHighPrevalenceParadox() {
        let spec = PRISMAScreeningEngine.defaultPICOProtocol()
        // N = 40 studies with extreme negative prevalence (typical systematic review ~92.5% exclusion):
        // ++ = 0, +- = 1, -+ = 2, -- = 37
        // Po = 37 / 40 = 0.925 (92.5% observed agreement!)
        // Yet marginal positives are tiny (1/40 and 2/40), so Cohen's kappa collapses near 0 or negative!
        var studies: [ScreeningStudyRecord] = [
            makeStudy(id: "s1", revA: .include, revB: .exclude(reasonCode: "E1_OFF_TOPIC")),
            makeStudy(id: "s2", revA: .exclude(reasonCode: "E1_OFF_TOPIC"), revB: .include),
            makeStudy(id: "s3", revA: .exclude(reasonCode: "E1_OFF_TOPIC"), revB: .include)
        ]
        for idx in 4...40 {
            studies.append(makeStudy(id: "s\(idx)", revA: .exclude(reasonCode: "E1_OFF_TOPIC"), revB: .exclude(reasonCode: "E1_OFF_TOPIC")))
        }

        let report = InterRaterReliabilityAndSeedQCEngine().evaluateDualRaterAgreement(
            studies: studies,
            protocolSpec: spec
        )

        #expect(abs(report.observedProportionAgreement - 0.925) < 1e-9)
        #expect(report.cohensKappa.pointEstimate < 0.10)
        // PABAK = 2(0.925) - 1 = 0.85; Gwet's AC1 also > 0.90!
        #expect(abs(report.byrtsPABAK.pointEstimate - 0.85) < 1e-9)
        #expect(report.gwetsAC1.pointEstimate > 0.88)
        #expect(report.feinsteinCicchettiParadoxDetected)
        #expect(abs(report.prevalenceIndex) > 0.80)
    }

    @Test("Fleiss' multi-rater kappa and Krippendorff's nominal alpha across 4 independent reviewers")
    func fleissMultiRaterKappaAndKrippendorffAlpha() {
        var ballots: [MultiRaterScreeningBallot] = []
        // 10 studies with unanimous 4-rater agreement (5 INCLUDE, 5 EXCLUDE E1) + 2 split 3-vs-1 studies
        for idx in 1...5 {
            ballots.append(
                MultiRaterScreeningBallot(
                    id: "inc\(idx)",
                    citeKey: "inc\(idx)",
                    votesByReviewerID: [
                        "R1": .include, "R2": .include, "R3": .include, "R4": .include
                    ]
                )
            )
        }
        for idx in 1...5 {
            let ex = ScreeningDecision.exclude(reasonCode: "E1_OFF_TOPIC")
            ballots.append(
                MultiRaterScreeningBallot(
                    id: "exc\(idx)",
                    citeKey: "exc\(idx)",
                    votesByReviewerID: ["R1": ex, "R2": ex, "R3": ex, "R4": ex]
                )
            )
        }
        ballots.append(
            MultiRaterScreeningBallot(
                id: "split1",
                citeKey: "split1",
                votesByReviewerID: [
                    "R1": .include, "R2": .include, "R3": .include,
                    "R4": .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL")
                ]
            )
        )
        ballots.append(
            MultiRaterScreeningBallot(
                id: "split2",
                citeKey: "split2",
                votesByReviewerID: [
                    "R1": .exclude(reasonCode: "E1_OFF_TOPIC"),
                    "R2": .exclude(reasonCode: "E1_OFF_TOPIC"),
                    "R3": .exclude(reasonCode: "E1_OFF_TOPIC"),
                    "R4": .include
                ]
            )
        )

        let report = InterRaterReliabilityAndSeedQCEngine().evaluateMultiRaterPanel(
            ballots: ballots,
            collapseExclusionsIntoSingleCategory: true
        )

        #expect(report.studyCount == 12)
        #expect(report.modalRatersPerStudy == 4)
        #expect(report.unanimousStudyCount == 10)
        #expect(report.fleissKappa.pointEstimate > 0.70)
        #expect(report.multiRaterGwetAC1.pointEstimate > 0.70)
        #expect(report.krippendorffsAlphaNominal > 0.70)
        #expect(!report.categoryBreakdown.isEmpty)
    }

    @Test("PsychometricNormalMath verifies Gaussian CDF, quantile inverse, chi-square tail, and Wilson CI")
    func psychometricNormalMathStatisticalIdentities() {
        #expect(abs(PsychometricNormalMath.standardNormalCDF(0.0) - 0.5) < 1e-7)
        #expect(abs(PsychometricNormalMath.standardNormalCDF(1.959964) - 0.975) < 1e-4)
        #expect(abs(PsychometricNormalMath.twoSidedNormalPValue(zScore: 1.959964) - 0.05) < 1e-3)

        let inv975 = PsychometricNormalMath.inverseStandardNormalCDF(0.975)
        #expect(abs(inv975 - 1.959964) < 1e-3)

        let chiP = PsychometricNormalMath.chiSquareUpperTailPValue(chiSquare: 3.8414588, degreesOfFreedom: 1)
        #expect(abs(chiP - 0.05) < 2e-3)

        let wilson = PsychometricNormalMath.wilsonScoreInterval(successes: 10, trials: 10, confidenceLevel: 0.95)
        #expect(wilson.lower > 0.65 && wilson.lower < 1.0)
        #expect(abs(wilson.upper - 1.0) < 1e-6)
    }

    // MARK: - 2. Exclusion Confusion Matrix, Gold-Standard Seed Recall QC & Near-Miss Sampling

    @Test("ExclusionCodeConfusionMatrix detects hierarchical priority-order drift and computes Stuart-Maxwell chi-square")
    func exclusionConfusionMatrixDetectsPriorityOrderDrift() {
        let spec = PRISMAScreeningEngine.defaultPICOProtocol()
        let studies: [ScreeningStudyRecord] = [
            makeStudy(id: "s1", revA: .include, revB: .include),
            makeStudy(id: "s2", revA: .exclude(reasonCode: "E1_OFF_TOPIC"), revB: .exclude(reasonCode: "E1_OFF_TOPIC")),
            // Priority drift: Reviewer A picked E1 (priority 1), Reviewer B picked E3 (priority 3)
            makeStudy(id: "s3", revA: .exclude(reasonCode: "E1_OFF_TOPIC"), revB: .exclude(reasonCode: "E3_CONTAINER_ONLY")),
            // Priority drift: Reviewer A picked E4 (priority 4), Reviewer B picked E2 (priority 2)
            makeStudy(id: "s4", revA: .exclude(reasonCode: "E4_NON_PRIMARY"), revB: .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL"))
        ]

        let matrix = InterRaterReliabilityAndSeedQCEngine().buildExclusionConfusionMatrix(
            studies: studies,
            protocolSpec: spec
        )

        #expect(matrix.totalPairedStudies == 4)
        #expect(matrix.dualExcludedCodeMismatchCount == 2)
        #expect(matrix.priorityDriftCases.count == 2)
        #expect(matrix.count(raterACode: "E1_OFF_TOPIC", raterBCode: "E3_CONTAINER_ONLY") == 1)

        let driftS3 = matrix.priorityDriftCases.first { $0.studyID == "s3" }
        #expect(driftS3?.recommendedCanonicalCode == "E1_OFF_TOPIC")
        #expect(driftS3?.priorityStepDistance == 2)
        #expect(matrix.stuartMaxwellChiSquare >= 0.0)
    }

    @Test("GoldStandardSeedStudy recall QC passes strict 100% gate when all seeds retained and flags false negatives")
    func goldStandardSeedRecallValidationGate() {
        let seeds = [
            GoldStandardSeedStudy(
                seedID: "seed-1",
                expectedCiteKey: "agache2020firecracker",
                expectedDOI: "10.5555/firecracker2020",
                canonicalTitle: "Firecracker: Lightweight Virtualization for Serverless Applications",
                publicationYear: 2020,
                inclusionRationale: "Canonical microVM isolation benchmark"
            ),
            GoldStandardSeedStudy(
                seedID: "seed-2",
                expectedCiteKey: "watson2010capsicum",
                expectedDOI: "10.5555/capsicum2010",
                canonicalTitle: "Capsicum: Practical Capabilities for UNIX",
                publicationYear: 2010,
                inclusionRationale: "Foundational capability-based OS sandbox"
            )
        ]

        // Case A: Both seeds retrieved and included -> passesStrictPRISMASeedGate == true
        let passingCorpus = [
            makeStudy(
                id: "st1",
                citeKey: "agache2020firecracker",
                title: "Firecracker: Lightweight Virtualization for Serverless Applications",
                year: 2020,
                doi: "10.5555/firecracker2020",
                stage: .fullText,
                revA: .include,
                revB: .include
            ),
            makeStudy(
                id: "st2",
                citeKey: "watson2010capsicum",
                title: "Capsicum: Practical Capabilities for UNIX",
                year: 2010,
                doi: "10.5555/capsicum2010",
                stage: .fullText,
                revA: .include,
                revB: .include
            )
        ]
        let qcEngine = InterRaterReliabilityAndSeedQCEngine()
        let passReport = qcEngine.validateGoldStandardSeedRecall(seeds: seeds, screenedCorpus: passingCorpus)
        #expect(passReport.searchStrategyRecall == 1.0)
        #expect(passReport.screeningSensitivityAmongRetrieved == 1.0)
        #expect(passReport.endToEndSeedRecall == 1.0)
        #expect(passReport.passesStrictPRISMASeedGate)

        // Case B: One seed erroneously excluded at Title/Abstract, one missing from search
        let failingCorpus = [
            makeStudy(
                id: "st1",
                citeKey: "agache2020firecracker",
                title: "Firecracker: Lightweight Virtualization for Serverless Applications",
                year: 2020,
                doi: "10.5555/firecracker2020",
                stage: .titleAbstract,
                revA: .exclude(reasonCode: "E1_OFF_TOPIC"),
                revB: .exclude(reasonCode: "E1_OFF_TOPIC")
            )
        ]
        let failReport = qcEngine.validateGoldStandardSeedRecall(seeds: seeds, screenedCorpus: failingCorpus)
        #expect(!failReport.passesStrictPRISMASeedGate)
        #expect(abs(failReport.searchStrategyRecall - 0.5) < 1e-9)
        #expect(failReport.endToEndSeedRecall == 0.0)
        #expect(failReport.perSeedOutcomes.contains { $0.outcomeKind == .erroneouslyExcludedAtTitleAbstract })
        #expect(failReport.perSeedOutcomes.contains { $0.outcomeKind == .missingFromRetrievedCorpus })
    }

    @Test("Deterministic near-miss exclusion recheck sampling and Markdown QC audit report generation")
    func nearMissRecheckSamplingDeterminismAndMarkdownExport() {
        let spec = PRISMAScreeningEngine.defaultPICOProtocol()
        var studies: [ScreeningStudyRecord] = [
            makeStudy(id: "inc1", title: "MicroVM virtualization capability sandbox boot latency", stage: .fullText, revA: .include, revB: .include)
        ]
        for idx in 1...12 {
            var s = makeStudy(
                id: "exc\(idx)",
                title: "Container sandbox virtualization isolation benchmark \(idx)",
                stage: .titleAbstract,
                revA: idx == 1 ? .maybe : .exclude(reasonCode: "E3_CONTAINER_ONLY"),
                revB: .exclude(reasonCode: "E3_CONTAINER_ONLY")
            )
            if idx == 1 {
                s.adjudicatedDecision = .exclude(reasonCode: "E3_CONTAINER_ONLY")
                s.adjudicationRationale = "Lacks hardware microVM boundary."
            }
            studies.append(s)
        }

        let qc = InterRaterReliabilityAndSeedQCEngine()
        let config = NearMissRecheckSamplingConfig(targetSampleFraction: 0.35, minimumSampleSize: 4, maximumSampleSize: 8, randomSeed: 42)
        let planA = qc.sampleNearMissExclusions(studies: studies, protocolSpec: spec, config: config)
        let planB = qc.sampleNearMissExclusions(studies: studies, protocolSpec: spec, config: config)

        // Identical PRNG seed produces identical candidate ordering
        #expect(planA == planB)
        #expect(planA.totalExcludedPoolCount == 12)
        #expect(planA.selectedSampleCount >= 4)
        #expect(planA.zeroDefectUpper95FalseOmissionBound > 0.0)

        let dual = qc.evaluateDualRaterAgreement(studies: studies, protocolSpec: spec)
        let cm = qc.buildExclusionConfusionMatrix(studies: studies, protocolSpec: spec)
        let seeds = qc.validateGoldStandardSeedRecall(seeds: [], screenedCorpus: studies)
        let markdown = qc.exportMarkdownQCAuditReport(
            reviewTitle: spec.reviewTitle,
            dualReport: dual,
            confusionMatrix: cm,
            seedReport: seeds,
            nearMissPlan: planA
        )
        #expect(markdown.contains("Cohen"))
        #expect(markdown.contains("PABAK"))
    }

    // MARK: - 3. PRISMAScreeningEngine Blinded Workflow, Protocol Gates & 4-Phase Flow Conservation

    @Test("PRISMAScreeningEngine enforces protocol exclusion codes, deduplicates ingest, and adjudicates conflicts")
    func prismaScreeningEngineBlindedWorkflowAndProtocolViolations() throws {
        let engine = PRISMAScreeningEngine()
        let dupRemoved = engine.ingestStudies([
            makeStudy(id: "s1", citeKey: "paperA", title: "MicroVM Isolation for Coding Agents", year: 2025, doi: "10.1145/1001"),
            // Duplicate DOI -> automatically removed!
            makeStudy(id: "s1-dup", citeKey: "paperA_arxiv", title: "MicroVM Isolation for Coding Agents (Preprint)", year: 2025, doi: "10.1145/1001"),
            makeStudy(id: "s2", citeKey: "paperB", title: "Capability-Gated Provenance Firewalls", year: 2026, doi: "10.1145/1002")
        ])

        #expect(dupRemoved == 1)
        #expect(engine.duplicateRecordsRemovedCount == 1)
        #expect(engine.allStudies().count == 2)

        // Unknown exclusion reason code MUST throw ERR_PRISMA_PROTOCOL
        #expect(throws: ScholarOSError.self) {
            try engine.castReviewerAVote(studyID: "s1", decision: .exclude(reasonCode: "E99_BOGUS"))
        }

        // Consensus INCLUDE auto-promotes Title/Abstract -> Full-Text stage
        try engine.castReviewerAVote(studyID: "s1", decision: .include)
        try engine.castReviewerBVote(studyID: "s1", decision: .include)
        let s1After = try #require(engine.allStudies().first { $0.id == "s1" })
        #expect(s1After.stage == .fullText)

        // Disagreement flags conflict; empty adjudication rationale throws ERR_PRISMA_PROTOCOL
        try engine.castReviewerAVote(studyID: "s2", decision: .include)
        try engine.castReviewerBVote(studyID: "s2", decision: .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL"))
        #expect(engine.conflictedStudies().map(\.id) == ["s2"])

        #expect(throws: ScholarOSError.self) {
            try engine.adjudicateConflict(studyID: "s2", finalDecision: .include, rationale: "   ")
        }

        try engine.adjudicateConflict(
            studyID: "s2",
            finalDecision: .include,
            rationale: "Appendix C contains full empirical latency benchmark across 500 trials."
        )
        #expect(engine.conflictedStudies().isEmpty)
    }

    @Test("PRISMA 2020 4-phase flow arithmetic conservation invariants hold strictly")
    func prisma2020FourPhaseFlowArithmeticConservationInvariants() {
        let studies: [ScreeningStudyRecord] = [
            // 4 excluded at Title/Abstract
            makeStudy(id: "ta1", stage: .titleAbstract, revA: .exclude(reasonCode: "E1_OFF_TOPIC"), revB: .exclude(reasonCode: "E1_OFF_TOPIC")),
            makeStudy(id: "ta2", stage: .titleAbstract, revA: .exclude(reasonCode: "E1_OFF_TOPIC"), revB: .exclude(reasonCode: "E1_OFF_TOPIC")),
            makeStudy(id: "ta3", stage: .titleAbstract, revA: .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL"), revB: .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL")),
            makeStudy(id: "ta4", stage: .titleAbstract, revA: .exclude(reasonCode: "E4_NON_PRIMARY"), revB: .exclude(reasonCode: "E4_NON_PRIMARY")),
            // 2 excluded at Full-Text with explicit reason codes
            makeStudy(id: "ft1", stage: .fullText, revA: .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL"), revB: .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL")),
            makeStudy(id: "ft2", stage: .fullText, revA: .exclude(reasonCode: "E3_CONTAINER_ONLY"), revB: .exclude(reasonCode: "E3_CONTAINER_ONLY")),
            // 4 included in final synthesis
            makeStudy(id: "in1", stage: .fullText, revA: .include, revB: .include),
            makeStudy(id: "in2", stage: .fullText, revA: .include, revB: .include),
            makeStudy(id: "in3", stage: .fullText, revA: .include, revB: .include),
            makeStudy(id: "in4", stage: .fullText, revA: .include, revB: .include)
        ]

        let engine = PRISMAScreeningEngine(
            studies: studies,
            duplicateRecordsRemovedCount: 7,
            registerRecordsIdentifiedCount: 3,
            reportsNotRetrievedCount: 0
        )
        let m = engine.computePRISMA2020Metrics()

        // Phase 1: Identification -> Screening
        #expect(m.databaseRecordsIdentified == 17)
        #expect(m.registerRecordsIdentified == 3)
        #expect(m.duplicateRecordsRemoved == 7)
        #expect(m.databaseRecordsIdentified - m.duplicateRecordsRemoved == m.recordsScreenedTitleAbstract)
        #expect(m.recordsScreenedTitleAbstract == 10)

        // Phase 2: Screening -> Retrieval
        #expect(m.recordsExcludedTitleAbstract == 4)
        #expect(m.recordsScreenedTitleAbstract - m.recordsExcludedTitleAbstract == m.reportsSoughtForRetrieval)
        #expect(m.reportsSoughtForRetrieval == 6)

        // Phase 3: Retrieval -> Eligibility
        #expect(m.reportsSoughtForRetrieval - m.reportsNotRetrieved == m.fullTextAssessed)
        #expect(m.fullTextAssessed == 6)

        // Phase 4: Eligibility -> Included
        let totalFTExcluded = m.fullTextExcludedByReason.values.reduce(0, +)
        #expect(totalFTExcluded == 2)
        #expect(m.fullTextAssessed - totalFTExcluded == m.finalIncludedStudies)
        #expect(m.finalIncludedStudies == 4)
    }

    @Test("PRISMA2020DiagramExporter produces valid standalone SVG, LaTeX TikZ diagram, and RIS decision log")
    func prisma2020DiagramExporterSVGLaTeXTikZAndRIS() {
        let studies: [ScreeningStudyRecord] = [
            makeStudy(id: "s1", citeKey: "vaswani2017", stage: .fullText, revA: .include, revB: .include),
            makeStudy(id: "s2", citeKey: "smith2024", stage: .fullText, revA: .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL"), revB: .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL")),
            makeStudy(id: "s3", citeKey: "blog2023", stage: .titleAbstract, revA: .exclude(reasonCode: "E1_OFF_TOPIC"), revB: .exclude(reasonCode: "E1_OFF_TOPIC"))
        ]
        let engine = PRISMAScreeningEngine(
            studies: studies,
            duplicateRecordsRemovedCount: 5,
            registerRecordsIdentifiedCount: 2,
            reportsNotRetrievedCount: 0
        )
        let metrics = engine.computePRISMA2020Metrics()
        let exporter = PRISMA2020DiagramExporter()

        let svg = exporter.exportVectorSVG(metrics: metrics)
        #expect(svg.contains("<svg"))
        #expect(svg.contains("</svg>"))
        #expect(svg.contains("E2_NO_EMPIRICAL_EVAL") || svg.contains("Included"))

        let tikz = exporter.exportLaTeXTikZ(metrics: metrics, reviewTitle: "Agent Isolation Systematic Review")
        #expect(tikz.contains("\\begin{tikzpicture}"))
        #expect(tikz.contains("\\end{tikzpicture}"))

        let ris = exporter.exportRISDecisions(studies: studies)
        #expect(ris.contains("TY  - "))
        #expect(ris.contains("ER  -"))
        #expect(ris.contains("INCLUDE"))
        #expect(ris.contains("E2_NO_EMPIRICAL_EVAL"))
    }

    // MARK: - 4. Cochrane RoB 2.0, ROBINS-I, Newcastle-Ottawa Scale, DerSimonian-Laird Meta-Analysis & GRADE

    @Test("Cochrane RoB 2.0 signaling checklist evaluates 5 domains and enforces worst-domain overall rule")
    func cochraneRoB2SignalingChecklistAndWorstDomainAggregation() {
        let planner = RiskOfBiasAndMetaSynthesisPlanner()

        // 1. All clean signaling answers -> Low Risk across all 5 domains
        let lowStudy = planner.evaluateCochraneRoB2Checklist(
            citeKey: "trialA",
            studyLabel: "Rostova et al. (2025)",
            outcomeAssessed: "Task Pass Rate",
            checklist: RoB2SignalingChecklist(),
            relativeWeightPercent: 45.0
        )
        #expect(lowStudy.domainJudgments.count == 5)
        #expect(lowStudy.overallJudgment == .lowRisk)

        // 2. Missing allocation concealment / non-random allocation + baseline imbalance -> High Risk in D1 & overall
        var highChecklist = RoB2SignalingChecklist()
        highChecklist.allocationSequenceRandom = .no
        highChecklist.allocationConcealedUntilEnrolment = .no
        highChecklist.baselineImbalanceSuggestsProblem = .yes
        let highStudy = planner.evaluateCochraneRoB2Checklist(
            citeKey: "trialB",
            studyLabel: "Takahashi et al. (2024)",
            outcomeAssessed: "Task Pass Rate",
            checklist: highChecklist,
            relativeWeightPercent: 25.0
        )
        #expect(highStudy.domainJudgments[.randomizationProcess] == .highRisk)
        #expect(highStudy.overallJudgment == .highRisk)

        // 3. Multiple domains with Some Concerns escalate or propagate via worst-domain rule
        var concernsChecklist = RoB2SignalingChecklist()
        concernsChecklist.analyzedAccordingToPrespecifiedPlan = .noInformation
        let someConcernsStudy = planner.evaluateCochraneRoB2Checklist(
            citeKey: "trialC",
            studyLabel: "Lindholm et al. (2026)",
            outcomeAssessed: "Task Pass Rate",
            checklist: concernsChecklist,
            relativeWeightPercent: 30.0
        )
        #expect(someConcernsStudy.overallJudgment >= .someConcerns)

        let matrix = planner.buildRoB2TrafficLightMatrix(assessments: [lowStudy, highStudy, someConcernsStudy])
        #expect(matrix.assessments.count == 3)
        #expect(abs((matrix.lowRiskStudyProportion + matrix.someConcernsStudyProportion + matrix.highRiskStudyProportion) - 1.0) < 1e-9)

        let robSVG = planner.exportRoB2TrafficLightAndSummarySVG(matrix: matrix)
        #expect(robSVG.contains("<svg"))
        #expect(robSVG.contains("</svg>"))
        #expect(robSVG.contains(RoB2Judgment.lowRisk.trafficLightHexFill))
    }

    @Test("ROBINS-I target-trial appraisal and Newcastle-Ottawa Scale AHRQ quality tier mapping")
    func robinsIAndNewcastleOttawaScaleAppraisal() {
        // ROBINS-I: Critical confounding -> ineligible for primary synthesis
        let criticalROBINS = ROBINSIStudyAssessment(
            citeKey: "obs2023",
            studyLabel: "Chen et al. (2023)",
            targetTrialAnalogy: "Pragmatic cluster benchmark",
            domainJudgments: [
                .confounding: .critical,
                .participantSelection: .low,
                .interventionClassification: .low,
                .intendedInterventionDeviations: .low,
                .missingData: .moderate,
                .outcomeMeasurement: .low,
                .reportedResultSelection: .low
            ]
        )
        #expect(criticalROBINS.overallJudgment == .critical)
        #expect(!criticalROBINS.eligibleForPrimarySynthesis)

        let moderateROBINS = ROBINSIStudyAssessment(
            citeKey: "obs2025",
            studyLabel: "Patel et al. (2025)",
            targetTrialAnalogy: "Matched observational benchmark",
            domainJudgments: [
                .confounding: .moderate,
                .participantSelection: .low,
                .interventionClassification: .low,
                .intendedInterventionDeviations: .low,
                .missingData: .low,
                .outcomeMeasurement: .low,
                .reportedResultSelection: .low
            ]
        )
        #expect(moderateROBINS.overallJudgment == .moderate)
        #expect(moderateROBINS.eligibleForPrimarySynthesis)

        // Newcastle-Ottawa Scale: 4 Selection + 2 Comparability + 3 Outcome = 9 stars -> Good Quality (AHRQ)
        let goodNOS = NewcastleOttawaAssessment(
            citeKey: "cohortGood",
            studyLabel: "Kim et al. (2025)",
            designVariant: .cohort,
            selectionStars: 4,
            comparabilityStars: 2,
            outcomeOrExposureStars: 3
        )
        #expect(goodNOS.totalStars == 9)
        #expect(goodNOS.ahrqQualityTier == .good)

        // 2 Selection + 0 Comparability + 2 Outcome = 4 stars -> Poor Quality (AHRQ)
        let poorNOS = NewcastleOttawaAssessment(
            citeKey: "cohortPoor",
            studyLabel: "Lee et al. (2022)",
            designVariant: .cohort,
            selectionStars: 2,
            comparabilityStars: 0,
            outcomeOrExposureStars: 2
        )
        #expect(poorNOS.totalStars == 4)
        #expect(poorNOS.ahrqQualityTier == .poor)
    }

    @Test("DerSimonian-Laird meta-analysis yields tau^2 = 0 and I^2 = 0% on homogeneous studies")
    func derSimonianLairdHomogeneousStudiesZeroTauSquared() {
        let studies = [
            StudyEffectEstimateRecord(citeKey: "s1", studyLabel: "Study 1", publicationYear: 2023, sampleSizeN: 100, effectEstimate: 0.50, standardError: 0.10),
            StudyEffectEstimateRecord(citeKey: "s2", studyLabel: "Study 2", publicationYear: 2024, sampleSizeN: 100, effectEstimate: 0.50, standardError: 0.10),
            StudyEffectEstimateRecord(citeKey: "s3", studyLabel: "Study 3", publicationYear: 2025, sampleSizeN: 100, effectEstimate: 0.50, standardError: 0.10),
            StudyEffectEstimateRecord(citeKey: "s4", studyLabel: "Study 4", publicationYear: 2026, sampleSizeN: 100, effectEstimate: 0.50, standardError: 0.10)
        ]

        let plan = RiskOfBiasAndMetaSynthesisPlanner().planMetaSynthesis(
            outcomeName: "Normalized Escape Reduction",
            studies: studies
        )

        #expect(plan.kStudies == 4)
        #expect(plan.degreesOfFreedom == 3)
        #expect(abs(plan.cochransQ) < 1e-9)
        #expect(abs(plan.higginsISquaredPercent) < 1e-9)
        #expect(abs(plan.tauSquaredDL) < 1e-9)
        #expect(abs(plan.fixedEffectEstimate - 0.50) < 1e-9)
        #expect(abs(plan.randomEffectsEstimate - 0.50) < 1e-9)
        // Pooled SE for 4 equal studies with SE=0.10 (variance=0.01 -> w_i=100, sum w=400 -> SE = 1/20 = 0.05)
        #expect(abs(plan.fixedEffectSE - 0.05) < 1e-9)
        let weightSum = plan.normalizedRandomWeightsByCiteKey.values.reduce(0.0, +)
        #expect(abs(weightSum - 100.0) < 1e-6)
    }

    @Test("DerSimonian-Laird random-effects meta-analysis computes Cochran's Q, Higgins' I^2, tau^2, and 95% CI under heterogeneity")
    func derSimonianLairdHeterogeneousRandomEffectsMetaAnalysis() {
        // 5 heterogeneous studies with markedly dispersed effects -> Q >> df, tau^2 > 0, I^2 > 75%, random SE > fixed SE
        let studies = [
            StudyEffectEstimateRecord(citeKey: "h1", studyLabel: "Alpha (2022)", publicationYear: 2022, sampleSizeN: 120, effectEstimate: 0.15, standardError: 0.08),
            StudyEffectEstimateRecord(citeKey: "h2", studyLabel: "Beta (2023)", publicationYear: 2023, sampleSizeN: 140, effectEstimate: 0.42, standardError: 0.09),
            StudyEffectEstimateRecord(citeKey: "h3", studyLabel: "Gamma (2024)", publicationYear: 2024, sampleSizeN: 95, effectEstimate: 0.78, standardError: 0.11),
            StudyEffectEstimateRecord(citeKey: "h4", studyLabel: "Delta (2025)", publicationYear: 2025, sampleSizeN: 180, effectEstimate: 1.05, standardError: 0.07),
            StudyEffectEstimateRecord(citeKey: "h5", studyLabel: "Epsilon (2026)", publicationYear: 2026, sampleSizeN: 110, effectEstimate: 0.60, standardError: 0.10)
        ]

        let plan = RiskOfBiasAndMetaSynthesisPlanner().planMetaSynthesis(
            outcomeName: "Sandboxed Task Pass Gain (Hedges' g)",
            studies: studies
        )

        #expect(plan.kStudies == 5)
        #expect(plan.totalSampleSize == 645)
        #expect(plan.degreesOfFreedom == 4)
        #expect(plan.cochransQ > 40.0)
        #expect(plan.heterogeneityPValue < 0.001)
        #expect(plan.higginsISquaredPercent > 80.0)
        #expect(plan.tauSquaredDL > 0.05)
        #expect(plan.tauBetweenStudySD == sqrt(plan.tauSquaredDL))
        #expect(plan.randomEffectsSE > plan.fixedEffectSE)
        #expect(plan.randomEffects95CILower < plan.randomEffectsEstimate)
        #expect(plan.randomEffects95CIUpper > plan.randomEffectsEstimate)
        let weightSum = plan.normalizedRandomWeightsByCiteKey.values.reduce(0.0, +)
        #expect(abs(weightSum - 100.0) < 1e-6)
    }

    @Test("GRADE Summary-of-Findings certainty derivation and LaTeX booktabs table exports")
    func gradeCertaintyDerivationAndLaTeXSummaryTableExports() {
        let planner = RiskOfBiasAndMetaSynthesisPlanner()
        let studies = [
            StudyEffectEstimateRecord(citeKey: "s1", studyLabel: "Rostova (2025)", publicationYear: 2025, sampleSizeN: 240, effectEstimate: 0.62, standardError: 0.08),
            StudyEffectEstimateRecord(citeKey: "s2", studyLabel: "Takahashi (2025)", publicationYear: 2025, sampleSizeN: 260, effectEstimate: 0.58, standardError: 0.07),
            StudyEffectEstimateRecord(citeKey: "s3", studyLabel: "Lindholm (2026)", publicationYear: 2026, sampleSizeN: 220, effectEstimate: 0.65, standardError: 0.09)
        ]
        let plan = planner.planMetaSynthesis(outcomeName: "Citation Verification Precision", studies: studies)
        let robAssessments = studies.map {
            planner.evaluateCochraneRoB2Checklist(
                citeKey: $0.citeKey,
                studyLabel: $0.studyLabel,
                outcomeAssessed: "Precision",
                checklist: RoB2SignalingChecklist()
            )
        }
        let robMatrix = planner.buildRoB2TrafficLightMatrix(assessments: robAssessments)

        let gradeRow = planner.deriveGRADEOutcomeRow(
            plan: plan,
            robMatrix: robMatrix,
            designClass: .randomizedControlledTrials,
            optimalInformationSizeThreshold: 400
        )
        #expect(gradeRow.certaintyLevel == .high)
        #expect(gradeRow.certaintyLevel.unicodeSymbols == "⊕⊕⊕⊕")

        let gradeTex = planner.exportLaTeXGRADESummaryTable(outcomes: [gradeRow])
        #expect(gradeTex.contains("\\begin{table"))
        #expect(gradeTex.contains("Citation Verification Precision"))

        let charTex = planner.exportLaTeXStudyCharacteristicsTable(rows: [
            StudyCharacteristicsRow(
                citeKey: "s1",
                authorYearDisplay: "Rostova (2025)",
                studyDesign: "Controlled Benchmark",
                populationOrBenchmark: "1,420 synthesis runs",
                sampleSizeDescription: "N = 240",
                interventionMechanism: "5-Class Firewall",
                comparatorBaseline: "Unverified LLM",
                primaryOutcomeSummary: "g = 0.62",
                overallRiskOfBiasSummary: "Low"
            )
        ])
        #expect(charTex.contains("Rostova (2025)"))

        let engine = PRISMAScreeningEngine()
        let methodsTex = planner.exportLaTeXPRISMAMethodsDraft(
            protocolSpec: engine.protocolSpec,
            prismaMetrics: engine.computePRISMA2020Metrics()
        )
        #expect(methodsTex.contains("PRISMA"))
        #expect(methodsTex.contains("DerSimonian--Laird"))
        #expect(methodsTex.contains("Eligibility Criteria"))
    }

    @Test("PRISMAScreeningEngine rejects duplicate or empty exclusion rule codes on protocol update")
    func prismaProtocolUpdateRejectsEmptyOrDuplicateCodes() {
        let engine = PRISMAScreeningEngine()
        let emptyProtocol = PICOProtocolSpec(
            reviewTitle: "Invalid Empty Rules",
            population: "Agents",
            intervention: "Sandbox",
            comparator: "Host",
            outcomes: "Safety",
            inclusionCriteria: ["Empirical"],
            exclusionRules: []
        )
        #expect(throws: ScholarOSError.self) {
            try engine.updateProtocol(emptyProtocol)
        }

        let duplicateCodeProtocol = PICOProtocolSpec(
            reviewTitle: "Invalid Duplicate Codes",
            population: "Agents",
            intervention: "Sandbox",
            comparator: "Host",
            outcomes: "Safety",
            inclusionCriteria: ["Empirical"],
            exclusionRules: [
                ExclusionReasonRule(priorityOrder: 1, code: "E1_DUP", label: "First"),
                ExclusionReasonRule(priorityOrder: 2, code: "E1_DUP", label: "Duplicate")
            ]
        )
        #expect(throws: ScholarOSError.self) {
            try engine.updateProtocol(duplicateCodeProtocol)
        }
    }

    @Test("AgreementBenchmarkBand classifies full spectrum from poor (<0) to almostPerfect (>0.80)")
    func agreementBenchmarkBandFullSpectrumClassification() {
        #expect(AgreementBenchmarkBand.classify(-0.15) == .poor)
        #expect(AgreementBenchmarkBand.classify(0.10) == .slight)
        #expect(AgreementBenchmarkBand.classify(0.32) == .fair)
        #expect(AgreementBenchmarkBand.classify(0.54) == .moderate)
        #expect(AgreementBenchmarkBand.classify(0.74) == .substantial)
        #expect(AgreementBenchmarkBand.classify(0.89) == .almostPerfect)
        #expect(!AgreementBenchmarkBand.moderate.meetsPRISMACalibrationGate)
        #expect(AgreementBenchmarkBand.substantial.meetsPRISMACalibrationGate)
        #expect(AgreementBenchmarkBand.almostPerfect.meetsPRISMACalibrationGate)
    }

    @Test("DerSimonian-Laird subgroup-stratified and sparse-k SWiM synthesis mode recommendations")
    func metaSynthesisSubgroupAndSWiMRecommendationModes() {
        let planner = RiskOfBiasAndMetaSynthesisPlanner()

        // Single study (k = 1) -> recommends SWiM (Synthesis Without Meta-Analysis)
        let singlePlan = planner.planMetaSynthesis(
            outcomeName: "Single Study Outcome",
            studies: [
                StudyEffectEstimateRecord(citeKey: "only1", studyLabel: "Solo (2026)", publicationYear: 2026, sampleSizeN: 80, effectEstimate: 0.40, standardError: 0.12)
            ]
        )
        #expect(singlePlan.kStudies == 1)
        #expect(singlePlan.recommendedSynthesisMode == .synthesisWithoutMetaAnalysisSWiM)

        // Multi-subgroup heterogeneous studies -> recommends subgroupStratifiedMetaAnalysis or randomEffectsDerSimonianLaird
        let subgroupStudies = [
            StudyEffectEstimateRecord(citeKey: "vm1", studyLabel: "VM-1", publicationYear: 2024, sampleSizeN: 150, effectEstimate: 0.90, standardError: 0.06, subgroupLabel: "MicroVM"),
            StudyEffectEstimateRecord(citeKey: "vm2", studyLabel: "VM-2", publicationYear: 2025, sampleSizeN: 160, effectEstimate: 0.88, standardError: 0.06, subgroupLabel: "MicroVM"),
            StudyEffectEstimateRecord(citeKey: "ct1", studyLabel: "CT-1", publicationYear: 2024, sampleSizeN: 150, effectEstimate: 0.22, standardError: 0.06, subgroupLabel: "Container"),
            StudyEffectEstimateRecord(citeKey: "ct2", studyLabel: "CT-2", publicationYear: 2025, sampleSizeN: 160, effectEstimate: 0.25, standardError: 0.06, subgroupLabel: "Container")
        ]
        let subgroupPlan = planner.planMetaSynthesis(outcomeName: "Containment Score", studies: subgroupStudies)
        #expect(subgroupPlan.higginsISquaredPercent > 85.0)
        #expect(
            subgroupPlan.recommendedSynthesisMode == .subgroupStratifiedMetaAnalysis
                || subgroupPlan.recommendedSynthesisMode == .randomEffectsDerSimonianLaird
        )
    }

    @Test("MultiRaterScreeningBallot initializes cleanly from ScreeningStudyRecord with optional third-rater adjudicator")
    func multiRaterBallotFromScreeningStudyRecord() {
        var record = makeStudy(
            id: "study-adj",
            citeKey: "rostova2026",
            stage: .titleAbstract,
            revA: .include,
            revB: .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL")
        )
        record.adjudicatedDecision = .include
        record.adjudicationRationale = "Empirical evaluation confirmed in Section 5."

        let twoRaterBallot = MultiRaterScreeningBallot(from: record, includeAdjudicatorAsThirdRater: false)
        #expect(twoRaterBallot.votesByReviewerID.count == 2)

        let threeRaterBallot = MultiRaterScreeningBallot(from: record, includeAdjudicatorAsThirdRater: true)
        #expect(threeRaterBallot.votesByReviewerID.count == 3)
    }

    @Test("S25 regression: 5-category nominal Cohen's kappa and Brennan-Prediger PABAK match exact closed-form hand calculation (83/107 and 19/24)")
    func s25FiveCategoryNominalKappaAndMulticlassPABAKMatchHandCalculation() {
        let spec = PRISMAScreeningEngine.defaultPICOProtocol()
        // Construct exact 12-study 5-category rater contingency table:
        // Categories: INCLUDE (I), MAYBE (M), E1_OFF_TOPIC (E1), E2_NO_EMPIRICAL_EVAL (E2), E3_CONTAINER_ONLY (E3)
        // Agreements (10/12): 4 (I,I), 1 (M,M), 2 (E1,E1), 2 (E2,E2), 1 (E3,E3) -> Po = 10/12
        // Disagreements (2/12): 1 (I,M), 1 (E3,I)
        // Marginals:
        //   A: I=5, M=1, E1=2, E2=2, E3=2
        //   B: I=5, M=2, E1=2, E2=2, E3=1
        // Pe = (5*5 + 1*2 + 2*2 + 2*2 + 2*1) / 144 = 37 / 144
        // Cohen's kappa = (10/12 - 37/144) / (1 - 37/144) = (83/144) / (107/144) = 83 / 107
        // Brennan-Prediger 5-category PABAK = (5 * (10/12) - 1) / (5 - 1) = (19/6) / 4 = 19 / 24
        let studies: [ScreeningStudyRecord] = [
            makeStudy(id: "sr1", stage: .fullText, revA: .include, revB: .include),
            makeStudy(id: "sr2", stage: .fullText, revA: .include, revB: .include),
            makeStudy(id: "sr3", stage: .fullText, revA: .include, revB: .include),
            makeStudy(id: "sr4", stage: .fullText, revA: .include, revB: .include),
            makeStudy(id: "sr5", stage: .titleAbstract, revA: .maybe, revB: .maybe),
            makeStudy(id: "sr6", stage: .titleAbstract, revA: .exclude(reasonCode: "E1_OFF_TOPIC"), revB: .exclude(reasonCode: "E1_OFF_TOPIC")),
            makeStudy(id: "sr7", stage: .titleAbstract, revA: .exclude(reasonCode: "E1_OFF_TOPIC"), revB: .exclude(reasonCode: "E1_OFF_TOPIC")),
            makeStudy(id: "sr8", stage: .titleAbstract, revA: .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL"), revB: .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL")),
            makeStudy(id: "sr9", stage: .titleAbstract, revA: .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL"), revB: .exclude(reasonCode: "E2_NO_EMPIRICAL_EVAL")),
            makeStudy(id: "sr10", stage: .titleAbstract, revA: .exclude(reasonCode: "E3_CONTAINER_ONLY"), revB: .exclude(reasonCode: "E3_CONTAINER_ONLY")),
            makeStudy(id: "sr11", stage: .titleAbstract, revA: .include, revB: .maybe),
            makeStudy(id: "sr12", stage: .titleAbstract, revA: .exclude(reasonCode: "E3_CONTAINER_ONLY"), revB: .include)
        ]

        let engine = PRISMAScreeningEngine(studies: studies)
        let prismaMetrics = engine.computePRISMA2020Metrics()
        let confusion = InterRaterReliabilityAndSeedQCEngine().buildExclusionConfusionMatrix(
            studies: studies,
            protocolSpec: spec
        )

        let expectedKappa = 83.0 / 107.0
        let expectedPABAK = 19.0 / 24.0
        #expect(abs(prismaMetrics.cohensKappa - expectedKappa) < 1e-9)
        #expect(abs(confusion.nominalMulticlassKappa.pointEstimate - expectedKappa) < 1e-9)
        #expect(abs(prismaMetrics.cohensKappa - confusion.nominalMulticlassKappa.pointEstimate) < 1e-12)
        #expect(abs(prismaMetrics.pabakScore - expectedPABAK) < 1e-9)
    }
}
