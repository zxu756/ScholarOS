import Foundation
import Testing
import ScholarModels
import ScholarPRISMAEngine
import ScholarWorkbenchShell
import ScholarStudioViews

@Suite("ScholarStudioViews Empty Default State & Demo Mode Honesty")
struct ScholarStudioViewsTests {

    @Test("S21/S22 regression: ScholarStudioViewModel starts completely empty without manuscripts, citations, PDFs, or fake HTTP 404 alert")
    @MainActor
    func s21AndS22StudioViewModelStartsEmptyWithoutDemoDataOrFakeAlert() {
        let vm = ScholarStudioViewModel()
        #expect(!vm.isDemoMode)
        #expect(vm.manuscriptFiles.isEmpty)
        #expect(vm.bibliographyEntries.isEmpty)
        #expect(vm.screeningStudies.isEmpty)
        #expect(vm.lastBlockedInsertionAlert == nil)
        #expect(vm.renderedPDFFixtures.isEmpty)
        #expect(vm.docking.openManuscriptTabs.isEmpty)
        #expect(vm.activeSourceBuffer.isEmpty)

        // Explicit demo load activates DEMO badge and marks every sample entry unverified or not_found (zero VERIFIED)
        vm.loadDemoWorkspace()
        #expect(vm.isDemoMode)
        #expect(!vm.bibliographyEntries.isEmpty)
        #expect(vm.bibliographyEntries.allSatisfy { $0.firewallClass != .verified })
        #expect(vm.lastBlockedInsertionAlert == nil)
    }

    // MARK: - S30: no conclusion is displayed that was not computed from loaded data

    /// Words that assert a verification or a passed check, in either language.
    private static let conclusionWords = ["verified", "passed", "100%", "clean", "核验", "核查通过", "通过", "已验证"]

    private func assertsAConclusion(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return Self.conclusionWords.contains { lowered.contains($0.lowercased()) }
    }

    private func makeSeedReport(total: Int, retained: Int, passesGate: Bool) -> SeedRecallValidationReport {
        let recall = total > 0 ? Double(retained) / Double(total) : 1.0
        return SeedRecallValidationReport(
            totalSeedCount: total,
            retrievedInCorpusCount: total,
            searchStrategyRecall: 1.0,
            searchRecall95CILower: 0.0,
            searchRecall95CIUpper: 1.0,
            retainedInSynthesisCount: retained,
            screeningSensitivityAmongRetrieved: recall,
            endToEndSeedRecall: recall,
            endToEndRecall95CILower: 0.0,
            endToEndRecall95CIUpper: 1.0,
            raterASeedSensitivity: 1.0,
            raterBSeedSensitivity: 1.0,
            passesStrictPRISMASeedGate: passesGate,
            perSeedOutcomes: []
        )
    }

    @Test("S30 regression: with nothing loaded, the interface texts say 'no data' and never claim that something was verified or passed")
    @MainActor
    func s30EmptyWorkspaceShowsNoDataInsteadOfVerifiedOrPassedConclusions() {
        let vm = ScholarStudioViewModel()

        // Seed recall: the default view model has no report, so the card and the QC pill have no number to show.
        #expect(vm.seedRecallReport == nil)
        #expect(!SeedRecallDisplay.hasData(vm.seedRecallReport))
        #expect(SeedRecallDisplay.pillValue(vm.seedRecallReport) == nil)
        #expect(SeedRecallDisplay.summaryLine(vm.seedRecallReport, language: .en) == "No seed-recall data.")
        #expect(SeedRecallDisplay.summaryLine(vm.seedRecallReport, language: .zhHans) == "没有种子文献召回数据。")
        // The engine's vacuous report for zero seeds (recall 1.0, gate true) is "no data" as well, not a pass.
        let vacuous = InterRaterReliabilityAndSeedQCEngine().validateGoldStandardSeedRecall(seeds: [], screenedCorpus: [])
        #expect(vacuous.endToEndSeedRecall == 1.0 && vacuous.passesStrictPRISMASeedGate)
        #expect(SeedRecallDisplay.pillValue(vacuous) == nil)
        #expect(SeedRecallDisplay.summaryLine(vacuous, language: .en) == "No seed-recall data.")

        // Bottom drawer: fed with the default view model's own (empty) state, none of the three channels may
        // report a clean result, and none of their texts may contain a verification / pass conclusion.
        for language in [ScholarLanguage.en, ScholarLanguage.zhHans] {
            let copies = [
                ScholarDrawerEmptyStateCopy.diagnostics(
                    manuscriptFileCount: vm.manuscriptFiles.count,
                    totalDiagnosticCount: vm.diagnostics.count,
                    language: language
                ),
                ScholarDrawerEmptyStateCopy.citationFirewall(
                    bibliographyEntryCount: vm.bibliographyEntries.count,
                    verifiedCount: vm.bibliographyEntries.filter { $0.firewallClass == .verified }.count,
                    language: language
                ),
                ScholarDrawerEmptyStateCopy.editorialAudit(
                    manuscriptFileCount: vm.manuscriptFiles.count,
                    pluginsRunCount: vm.perPluginTimingsMs.count,
                    totalFindingCount: vm.editorialFindings.count,
                    language: language
                )
            ]
            for copy in copies {
                #expect(!copy.reportsCleanResult, "\(copy.title)")
                #expect(!assertsAConclusion(copy.title), "\(copy.title)")
                #expect(!assertsAConclusion(copy.detail), "\(copy.detail)")
            }
        }
        #expect(
            ScholarDrawerEmptyStateCopy.citationFirewall(bibliographyEntryCount: 0, verifiedCount: 0, language: .en).title
                == "No Bibliography Loaded"
        )
        #expect(
            ScholarDrawerEmptyStateCopy.citationFirewall(bibliographyEntryCount: 0, verifiedCount: 0, language: .zhHans).detail
                == "没有任何条目被检查过。"
        )

        // The sample statistics rows (which carry written-out consistent / mismatch labels) exist only in demo mode.
        #expect(vm.apaStatRows.isEmpty)
    }

    @Test("S30 regression: seed-recall text and drawer conclusions are computed from the data they describe")
    @MainActor
    func s30SeedRecallTextAndDrawerConclusionsAreComputedFromData() {
        // 1. Seed recall wording follows the numbers of the report it is given.
        let allRetained = makeSeedReport(total: 3, retained: 3, passesGate: true)
        #expect(SeedRecallDisplay.pillValue(allRetained) == "100% (3/3)")
        #expect(SeedRecallDisplay.summaryLine(allRetained, language: .en)
            == "Seed recall 100%: 3 of 3 seed studies retained; strict seed check passed.")
        #expect(SeedRecallDisplay.summaryLine(allRetained, language: .zhHans)
            == "种子文献召回 100%：3 篇种子文献中保留 3 篇；通过严格种子检查。")

        let oneLost = makeSeedReport(total: 3, retained: 2, passesGate: false)
        #expect(SeedRecallDisplay.pillValue(oneLost) == "67% (2/3)")
        #expect(SeedRecallDisplay.summaryLine(oneLost, language: .en)
            == "Seed recall 67%: 2 of 3 seed studies retained; strict seed check NOT passed.")
        #expect(SeedRecallDisplay.summaryLine(oneLost, language: .zhHans)
            == "种子文献召回 67%：3 篇种子文献中保留 2 篇；未通过严格种子检查。")

        let noneRetained = makeSeedReport(total: 4, retained: 0, passesGate: false)
        #expect(SeedRecallDisplay.pillValue(noneRetained) == "0% (0/4)")
        #expect(SeedRecallDisplay.summaryLine(noneRetained, language: .en).contains("NOT passed"))

        // 2. With the demo deck loaded, the displayed text is built from the engine's report for that deck,
        //    and that report agrees with an independent count over the deck itself.
        let vm = ScholarStudioViewModel()
        vm.loadDemoWorkspace()
        #expect(vm.isDemoMode)
        let report = vm.seedRecallReport
        #expect(SeedRecallDisplay.hasData(report))
        if let report {
            let line = SeedRecallDisplay.summaryLine(report, language: .en)
            #expect(line.contains("\(report.retainedInSynthesisCount) of \(report.totalSeedCount) seed studies retained"))
            #expect(line.contains(String(format: "%.0f%%", report.endToEndSeedRecall * 100.0)))
            #expect(line.hasSuffix(report.passesStrictPRISMASeedGate ? "strict seed check passed." : "strict seed check NOT passed."))
            #expect(abs(report.endToEndSeedRecall - Double(report.retainedInSynthesisCount) / Double(report.totalSeedCount)) < 1e-12)
            #expect(report.perSeedOutcomes.count == report.totalSeedCount)
            #expect(report.perSeedOutcomes.filter { $0.outcomeKind == .retainedIncluded }.count == report.retainedInSynthesisCount)
        }
        #expect(!vm.apaStatRows.isEmpty)

        // 3. Drawer copy reports a clean result only when a check ran on loaded data and found nothing.
        let cleanDiagnostics = ScholarDrawerEmptyStateCopy.diagnostics(manuscriptFileCount: 2, totalDiagnosticCount: 0, language: .en)
        #expect(cleanDiagnostics.reportsCleanResult)
        #expect(cleanDiagnostics.detail.contains("2 loaded file(s)"))
        let filteredDiagnostics = ScholarDrawerEmptyStateCopy.diagnostics(manuscriptFileCount: 2, totalDiagnosticCount: 5, language: .en)
        #expect(!filteredDiagnostics.reportsCleanResult)
        #expect(filteredDiagnostics.detail.contains("5 diagnostics are hidden"))

        let allVerified = ScholarDrawerEmptyStateCopy.citationFirewall(bibliographyEntryCount: 3, verifiedCount: 3, language: .en)
        #expect(allVerified.reportsCleanResult)
        #expect(allVerified.title == "All 3 Entries Are VERIFIED")
        let noneVerified = ScholarDrawerEmptyStateCopy.citationFirewall(bibliographyEntryCount: 3, verifiedCount: 0, language: .en)
        #expect(!noneVerified.reportsCleanResult)
        #expect(!noneVerified.title.lowercased().contains("verified"))
        #expect(noneVerified.detail == "0 of 3 entries are VERIFIED.")
        let someVerified = ScholarDrawerEmptyStateCopy.citationFirewall(bibliographyEntryCount: 3, verifiedCount: 2, language: .zhHans)
        #expect(!someVerified.reportsCleanResult)
        #expect(someVerified.detail == "3 条文献中有 2 条为 VERIFIED。")

        let notRun = ScholarDrawerEmptyStateCopy.editorialAudit(manuscriptFileCount: 1, pluginsRunCount: 0, totalFindingCount: 0, language: .en)
        #expect(!notRun.reportsCleanResult)
        #expect(notRun.title == "Editorial Checks Have Not Been Run")
        let ranClean = ScholarDrawerEmptyStateCopy.editorialAudit(manuscriptFileCount: 1, pluginsRunCount: 2, totalFindingCount: 0, language: .en)
        #expect(ranClean.reportsCleanResult)
        #expect(ranClean.detail.contains("2 editorial plugin(s) ran"))
        let ranFiltered = ScholarDrawerEmptyStateCopy.editorialAudit(manuscriptFileCount: 1, pluginsRunCount: 2, totalFindingCount: 4, language: .en)
        #expect(!ranFiltered.reportsCleanResult)
    }

    @Test("M1 Stage 09 (S48 item 5): ScholarStudioViewModel and Command Palette never display sourceless or expired VERIFIED entries as Verified")
    @MainActor
    func m1Stage09StudioViewModelAndPaletteNeverShowExpiredOrSourcelessVerifiedAsVerified() {
        let vm = ScholarStudioViewModel()
        let sourcelessVerified = BibliographyEntry(
            citeKey: "sourceless_verified",
            title: "Sourceless Entry",
            authors: [BibAuthor(givenName: "Yann", familyName: "LeCun")],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539",
            firewallClass: .verified,
            firewallAuditNote: "Legacy bare verified"
        )
        let expiredVerified = BibliographyEntry(
            citeKey: "expired_verified",
            title: "Old Entry",
            authors: [BibAuthor(givenName: "Yann", familyName: "LeCun")],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539",
            firewallClass: .verified,
            firewallAuditNote: "Old verified",
            firewallVerifiedSource: "Crossref",
            firewallVerifiedAtUTC: "2020-01-01"
        )
        let todayUTC = BibliographyEntry.formatUTCDay(Date())
        let freshVerified = BibliographyEntry(
            citeKey: "fresh_verified",
            title: "Fresh Entry",
            authors: [BibAuthor(givenName: "Yann", familyName: "LeCun")],
            year: 2015,
            venue: "Nature",
            doi: "10.1038/nature14539",
            firewallClass: .verified,
            firewallAuditNote: "Fresh verified",
            firewallVerifiedSource: "Crossref",
            firewallVerifiedAtUTC: todayUTC
        )

        vm.bibliographyEntries = [sourcelessVerified, expiredVerified, freshVerified]
        vm.docking.selectedCiteKey = "sourceless_verified"
        vm.refreshActiveEditorLSPState()

        let activeLang = ScholarLocalizer.shared.language
        let verifiedBadge = CitationFirewallClass.verified.localizedBadgeTitle(activeLang)
        let unverifiedBadge = CitationFirewallClass.unverified.localizedBadgeTitle(activeLang)

        #expect(vm.activeHoverCard?.firewallClass == .unverified)
        let sourcelessComp = vm.completionCandidates.first { $0.insertText == "sourceless_verified" }
        #expect(sourcelessComp?.subtitle.contains(unverifiedBadge) == true)
        #expect(sourcelessComp?.subtitle.contains("• \(verifiedBadge)") == false)
        let expiredComp = vm.completionCandidates.first { $0.insertText == "expired_verified" }
        #expect(expiredComp?.subtitle.contains(unverifiedBadge) == true)
        #expect(expiredComp?.subtitle.contains("• \(verifiedBadge)") == false)
        let freshComp = vm.completionCandidates.first { $0.insertText == "fresh_verified" }
        #expect(freshComp?.subtitle.contains(verifiedBadge) == true)

        let paletteItems = ScholarCommandPaletteCatalog.buildItems(
            bibliographyEntries: [sourcelessVerified, expiredVerified, freshVerified]
        )
        let pSourceless = paletteItems.first { $0.id == "cite.sourceless_verified" }
        let pExpired = paletteItems.first { $0.id == "cite.expired_verified" }
        let pFresh = paletteItems.first { $0.id == "cite.fresh_verified" }
        #expect(pSourceless?.firewallClass == .unverified)
        #expect(pExpired?.firewallClass == .unverified)
        #expect(pFresh?.firewallClass == .verified)
    }
}
