import Foundation
import Testing
import ScholarModels
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
}
