import AppKit
import Combine
import CoreGraphics
import Foundation
import PDFKit
import SwiftUI
import ScholarBibAndCSL
import ScholarCLIAndMCP
import ScholarCitationGraph
import ScholarLSPEngine
import ScholarMarkupAST
import ScholarModels
import ScholarPDFProvenance
import ScholarPRISMAEngine
import ScholarPluginSDK
import ScholarProjectStore
import ScholarWorkbenchShell

// MARK: - Snapshot Rendering Environment Key

private struct ScholarSnapshotRenderingKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    /// Indicates that the view hierarchy is being rasterized offscreen via `ImageRenderer` at 2x Retina scale,
    /// instructing AppKit bridges (`NSTextView`, `PDFView`) to use deterministic pure-SwiftUI vector/bitmap equivalents.
    var scholarSnapshotRendering: Bool {
        get { self[ScholarSnapshotRenderingKey.self] }
        set { self[ScholarSnapshotRenderingKey.self] = newValue }
    }
}

// MARK: - Studio Auxiliary View Models & Presentation Records

/// Pre-rasterized 2x Retina bitmap for a single `PDFPage` from `PDFKit`, paired with its native `.mediaBox` dimensions in PDF points.
public struct RenderedPDFPageBitmap: Identifiable, Sendable {
    public var id: String { "\(citeKey)-p\(pageIndex)" }
    public let citeKey: String
    public let pageIndex: Int
    public let cgImage: CGImage
    public let mediaBoxWidthPt: Double
    public let mediaBoxHeightPt: Double

    public init(
        citeKey: String,
        pageIndex: Int,
        cgImage: CGImage,
        mediaBoxWidthPt: Double,
        mediaBoxHeightPt: Double
    ) {
        self.citeKey = citeKey
        self.pageIndex = pageIndex
        self.cgImage = cgImage
        self.mediaBoxWidthPt = mediaBoxWidthPt
        self.mediaBoxHeightPt = mediaBoxHeightPt
    }
}

/// Deterministic APA 7th hypothesis-test verification row recalculated via Lanczos incomplete beta / gamma distributions.
public struct APAStatVerificationRow: Identifiable, Sendable, Hashable {
    public let id: String
    public let filePath: String
    public let line: Int
    public let testFamily: String
    public let reportedTuple: String
    public let reportedPText: String
    public let recalculatedExactP: Double
    public let absoluteDelta: Double
    public let isConsistent: Bool
    public let diagnosticSummary: String

    public init(
        id: String,
        filePath: String,
        line: Int,
        testFamily: String,
        reportedTuple: String,
        reportedPText: String,
        recalculatedExactP: Double,
        absoluteDelta: Double,
        isConsistent: Bool,
        diagnosticSummary: String
    ) {
        self.id = id
        self.filePath = filePath
        self.line = line
        self.testFamily = testFamily
        self.reportedTuple = reportedTuple
        self.reportedPText = reportedPText
        self.recalculatedExactP = recalculatedExactP
        self.absoluteDelta = absoluteDelta
        self.isConsistent = isConsistent
        self.diagnosticSummary = diagnosticSummary
    }
}

/// Captures a deterministic `ERR_UNVERIFIED_CITATION` firewall block event when inserting an unverified or hallucinated key.
public struct FirewallGateRejectionRecord: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let citeKey: String
    public let errorCode: String
    public let firewallClass: CitationFirewallClass
    public let attemptedCommand: String
    public let reason: String

    public init(
        id: UUID = UUID(),
        citeKey: String,
        errorCode: String = "ERR_UNVERIFIED_CITATION",
        firewallClass: CitationFirewallClass = .notFound,
        attemptedCommand: String,
        reason: String
    ) {
        self.id = id
        self.citeKey = citeKey
        self.errorCode = errorCode
        self.firewallClass = firewallClass
        self.attemptedCommand = attemptedCommand
        self.reason = reason
    }
}

/// Output captured from the interactive JavaScriptCore Editorial Plugin Scratchpad inside `.editorialAudit`.
public struct JSScratchpadEvaluationOutput: Sendable, Hashable {
    public let isSuccess: Bool
    public let elapsedMilliseconds: Double
    public let emittedFindings: [EditorialAuditFinding]
    public let consoleLogs: [PluginConsoleLogEntry]
    public let statusSummary: String
    public let errorMessage: String?

    public init(
        isSuccess: Bool,
        elapsedMilliseconds: Double,
        emittedFindings: [EditorialAuditFinding],
        consoleLogs: [PluginConsoleLogEntry],
        statusSummary: String,
        errorMessage: String? = nil
    ) {
        self.isSuccess = isSuccess
        self.elapsedMilliseconds = elapsedMilliseconds
        self.emittedFindings = emittedFindings
        self.consoleLogs = consoleLogs
        self.statusSummary = statusSummary
        self.errorMessage = errorMessage
    }
}

/// Canonical Retina screenshot presets corresponding to the 4 exported `2720 × 1680` PNGs.
public enum ScholarRetinaScreenshotPreset: String, CaseIterable, Sendable {
    case manuscriptLSP = "screenshot-manuscript-lsp.png"
    case citationGraph = "screenshot-citation-graph.png"
    case prismaScreening = "screenshot-prisma-screening.png"
    case firewallEditorial = "screenshot-firewall-editorial.png"

    public func fileName(for language: ScholarLanguage) -> String {
        guard language == .zhHans else { return rawValue }
        switch self {
        case .manuscriptLSP:
            return "screenshot-manuscript-lsp-zh.png"
        case .citationGraph:
            return "screenshot-citation-graph-zh.png"
        case .prismaScreening:
            return "screenshot-prisma-screening-zh.png"
        case .firewallEditorial:
            return "screenshot-firewall-editorial-zh.png"
        }
    }
}

// MARK: - Primary Workstation Coordinator (`ScholarStudioViewModel`)

/// Central `@MainActor` coordinator binding SQLite WAL persistence, incremental LaTeX/Typst LSP intelligence,
/// PDFKit two-column SyncTeX & BM25 claim provenance, Barnes-Hut / Louvain citation cartography, PRISMA 2020
/// dual-blind screening + RoB 2.0 + DerSimonian-Laird forest synthesis, 5-class Citation Verification Firewall,
/// Myers word-level Track Changes, and isolated JavaScriptCore editorial plugins.
@MainActor
public final class ScholarStudioViewModel: ObservableObject {
    // MARK: Core Subsystems
    public let docking: ScholarDockingController
    public let preferences: ScholarWorkbenchPreferences
    public let toastCenter: ScholarToastCenter
    public let database: ScholarProjectDatabase
    public let undoRedo: ScholarUndoRedoController
    public private(set) var lspService: ScholarLSPWorkspaceService

    // MARK: 1. Manuscript & LSP State
    @Published public var isDemoMode: Bool = false
    @Published public var projectTitle: String = "ScholarOS"
    @Published public var primaryManuscriptPath: String = ""
    @Published public var manuscriptFiles: [ManuscriptFileRecord] = []
    @Published public var activeSourceBuffer: String = ""
    @Published public var activeTokens: [MarkupToken] = []
    @Published public var outlineEntries: [DocumentOutlineEntry] = []
    @Published public var diagnostics: [LSPDiagnostic] = []
    @Published public var codeActions: [LSPCodeAction] = []
    @Published public var completionCandidates: [LSPCompletionItem] = []
    @Published public var isShowingCompletionPopover: Bool = false
    @Published public var completionAnchorLine: Int = 1
    @Published public var completionQueryPrefix: String = "\\cite{"
    @Published public var activeHoverCard: LSPHoverCard?
    @Published public var manuscriptMetrics: ManuscriptMetricsReport?
    @Published public var useNativeAppKitEditor: Bool = false

    // MARK: 2. Two-Column Academic PDF, SyncTeX & Claim Provenance State
    @Published public var renderedPDFFixtures: [RenderedAcademicPDFFixture] = []
    @Published public var selectedPDFFixtureCiteKey: String = ""
    @Published public var selectedPDFPageIndex: Int = 0
    @Published public var pdfPageBitmapsByKey: [String: [RenderedPDFPageBitmap]] = [:]
    @Published public var pdfPassages: [PDFPassageChunk] = []
    @Published public var claimProvenanceLinks: [ClaimEvidenceProvenance] = []
    @Published public var selectedClaimProvenanceID: UUID?
    @Published public var syncTeXAnchors: [SyncTeXAnchor] = []
    @Published public var provenanceSearchQuery: String = ""
    @Published public var provenanceVerdictFilter: EvidenceSupportVerdict?

    // MARK: 3. Barnes-Hut Citation Knowledge Graph, Louvain & Kleinberg Bursts State
    @Published public var graphSnapshot: CitationKnowledgeGraphSnapshot = CitationKnowledgeGraphSnapshot(
        nodes: [],
        edges: [],
        clusterLabels: [:],
        bridgeCiteKeys: []
    )
    @Published public var louvainPartition: LouvainCommunityPartition?
    @Published public var bridgeProfiles: [StructuralBridgePaperProfile] = []
    @Published public var mainPathReport: MainPathAnalysisReport?
    @Published public var kleinbergBurstReport: KleinbergBurstAnalysisReport?
    @Published public var missingCitationsReport: LiteratureCoverageGapReport?
    @Published public var selectedGraphCiteKey: String? = nil
    @Published public var graphShowCoCitationEdges: Bool = true
    @Published public var graphHighlightMainPath: Bool = true
    @Published public var graphZoomScale: CGFloat = 1.0
    @Published public var graphPanOffset: CGSize = .zero

    // MARK: 4. PRISMA 2020 Screening, Psychometrics, RoB 2.0 & Meta-Synthesis State
    @Published public var picoProtocol: PICOProtocolSpec = PICOProtocolSpec(
        reviewTitle: "Citation Verification Firewalls & Reproducible Academic Workbenches",
        population: "Peer-reviewed NLP, IR, and software engineering manuscripts (2017–2026)",
        intervention: "Deterministic DOI/arXiv/PubMed citation verification & AST editorial gates",
        comparator: "Unconstrained LLM bibliography generation or manual reference management",
        outcomes: "Hallucinated citation block rate, screening kappa reliability, and APA p-value accuracy",
        inclusionCriteria: [
            "Reports quantitative citation verification precision/recall or psychometric agreement",
            "Evaluates real academic corpora (LaTeX, Typst, RIS, or two-column PDFs)"
        ],
        exclusionRules: [
            ExclusionReasonRule(priorityOrder: 1, code: "E1", label: "Wrong population or non-academic domain"),
            ExclusionReasonRule(priorityOrder: 2, code: "E2", label: "No deterministic verification or baseline"),
            ExclusionReasonRule(priorityOrder: 3, code: "E3", label: "Non-empirical commentary or opinion"),
            ExclusionReasonRule(priorityOrder: 4, code: "E4", label: "Full text unretrievable"),
            ExclusionReasonRule(priorityOrder: 5, code: "E5", label: "Duplicate cohort or proceedings"),
            ExclusionReasonRule(priorityOrder: 6, code: "E6", label: "Retracted publication")
        ]
    )
    @Published public var screeningStudies: [ScreeningStudyRecord] = []
    @Published public var prismaStageFilter: ScreeningStage?
    @Published public var prismaConflictsOnly: Bool = false
    @Published public var selectedScreeningStudyID: String?
    @Published public var selectedExclusionReasonCode: String = "E1"
    @Published public var adjudicationRationaleDraft: String = ""
    @Published public var prismaMetrics: PRISMA2020SummaryMetrics = PRISMA2020SummaryMetrics(
        databaseRecordsIdentified: 0,
        registerRecordsIdentified: 0,
        duplicateRecordsRemoved: 0,
        recordsScreenedTitleAbstract: 0,
        recordsExcludedTitleAbstract: 0,
        reportsSoughtForRetrieval: 0,
        reportsNotRetrieved: 0,
        fullTextAssessed: 0,
        fullTextExcludedByReason: [:],
        finalIncludedStudies: 0,
        observedAgreementRate: 0.0,
        cohensKappa: 0.0,
        pabakScore: 0.0
    )
    @Published public var agreementReport: DualRaterAgreementReport?
    @Published public var seedRecallReport: SeedRecallValidationReport?
    @Published public var rob2Matrix: RoB2TrafficLightMatrix?
    @Published public var metaSynthesisPlan: MetaSynthesisHeterogeneityPlan?
    @Published public var effectEstimates: [StudyEffectEstimateRecord] = []
    @Published public var revealBlindedReviewerB: Bool = true

    // MARK: 5. Citation Firewall, CSL 5-Style Preview & Myers Track Changes State
    @Published public var bibliographyEntries: [BibliographyEntry] = []
    @Published public var firewallAuditReport: CitationFirewallAuditReport?
    @Published public var firewallClassFilter: CitationFirewallClass?
    @Published public var bibliographySearchQuery: String = ""
    @Published public var selectedCSLStyle: CitationFormatStyle = .apa7
    @Published public var formattedCSLPreview: [CSLFormattedCitation] = []
    @Published public var duplicateCandidates: [DuplicateReferenceCandidate] = []
    @Published public var lastBlockedInsertionAlert: FirewallGateRejectionRecord?
    @Published public var bibtexImportDraft: String = ""
    @Published public var snapshots: [ManuscriptSnapshot] = []
    @Published public var selectedBaselineSnapshotID: UUID?
    @Published public var selectedRevisedSnapshotID: UUID?
    @Published public var trackChangesReport: TrackChangesDiffReport?
    @Published public var trackChangesHunks: [TrackChangeHunk] = []
    @Published public var showLatexdiffSource: Bool = false

    // MARK: 6. JavaScriptCore Editorial Plugins, APA 7th Verifier & Scratchpad State
    @Published public var editorialRunSummary: EditorialPluginRunSummary?
    @Published public var editorialFindings: [EditorialAuditFinding] = []
    @Published public var perPluginTimingsMs: [String: Double] = [:]
    @Published public var pluginLogs: [PluginConsoleLogEntry] = []
    @Published public var apaStatRows: [APAStatVerificationRow] = []
    @Published public var jsScratchpadSource: String = ScholarStudioViewModel.defaultScratchpadScript
    @Published public var jsScratchpadOutput: JSScratchpadEvaluationOutput?

    // MARK: Project Telemetry
    @Published public var projectStats: ScholarProjectStats?

    // Private Engines
    private let cslEngine = CSLCitationFormatterEngine()
    private let firewallEngine = CitationVerificationFirewall()
    private let pdfGenerator = SyntheticAcademicPDFFixtureGenerator()
    private let graphBuilder = CitationGraphBuilder()
    private let louvainDetector = LouvainModularityAndBridgeDetector()
    private let mainPathAnalyzer = MainPathAndLiteratureGapAnalyzer()
    private let reliabilityEngine = InterRaterReliabilityAndSeedQCEngine()
    private let rob2Planner = RiskOfBiasAndMetaSynthesisPlanner()
    private let diffEngine = MyersWordLevelTrackChangesEngine()
    private var languageCancellable: AnyCancellable?

    // MARK: - Initialization

    public init(
        database: ScholarProjectDatabase? = nil,
        docking: ScholarDockingController? = nil,
        preferences: ScholarWorkbenchPreferences? = nil,
        toastCenter: ScholarToastCenter? = nil,
        seedDemo: Bool = false
    ) {
        let resolvedDB: ScholarProjectDatabase
        if let database {
            resolvedDB = database
        } else {
            resolvedDB = try! ScholarProjectDatabase.inMemory(seedDemo: false)
        }
        self.database = resolvedDB
        self.undoRedo = ScholarUndoRedoController(database: resolvedDB)

        let resolvedPreferences = preferences ?? ScholarWorkbenchPreferences(
            initialPlugins: BuiltInEditorialPluginCatalog.allPlugins
        )
        self.preferences = resolvedPreferences

        let resolvedToast = toastCenter ?? ScholarToastCenter()
        self.toastCenter = resolvedToast

        let existingHasContent = !((try? resolvedDB.listManuscriptFiles()) ?? []).isEmpty
            || !((try? resolvedDB.listBibliographyEntries()) ?? []).isEmpty

        let resolvedDocking: ScholarDockingController
        if let docking {
            resolvedDocking = docking
        } else if seedDemo {
            resolvedDocking = ScholarDockingController(
                activeStudioTab: .manuscriptEditor,
                initialTabs: [
                    OpenManuscriptTab(filePath: "main.tex", format: .latex, isPinned: true, wordCount: 410, lastCursorLine: 18, lastCursorColumn: 14),
                    OpenManuscriptTab(filePath: "sections/methodology.tex", format: .latex, isPinned: false, wordCount: 225, lastCursorLine: 9, lastCursorColumn: 1),
                    OpenManuscriptTab(filePath: "notes/protocol.typ", format: .typst, isPinned: false, wordCount: 140, lastCursorLine: 6, lastCursorColumn: 1)
                ],
                activeManuscriptFilePath: "main.tex",
                rightInspectorMode: .pdfPreview,
                isLeftSidebarVisible: true,
                leftSidebarWidth: 236,
                rightInspectorWidth: 488,
                isBottomDrawerVisible: true,
                activeDrawerChannel: .diagnostics,
                bottomDrawerHeight: 174,
                zoomScale: 1.0,
                synchronizedCursor: ScholarCursorLocation(filePath: "main.tex", line: 18, column: 14),
                selectedCiteKey: "vaswani2017attention"
            )
        } else {
            resolvedDocking = ScholarDockingController(
                activeStudioTab: .manuscriptEditor,
                initialTabs: [],
                activeManuscriptFilePath: "",
                rightInspectorMode: .none,
                isLeftSidebarVisible: existingHasContent,
                leftSidebarWidth: 236,
                rightInspectorWidth: 488,
                isBottomDrawerVisible: false,
                activeDrawerChannel: .diagnostics,
                bottomDrawerHeight: 174,
                zoomScale: 1.0,
                synchronizedCursor: ScholarCursorLocation(filePath: "", line: 1, column: 1),
                selectedCiteKey: nil,
                allowEmptyTabs: true
            )
        }
        self.docking = resolvedDocking

        self.lspService = ScholarLSPWorkspaceService(
            rootFilePath: "main.tex",
            files: [:],
            bibliography: [],
            citationStyle: .apa7
        )

        if seedDemo {
            loadDemoWorkspace()
        } else if existingHasContent {
            rebuildAllSubsystems()
        } else {
            self.isDemoMode = false
            self.lastBlockedInsertionAlert = nil
        }
    }

    /// Explicitly loads the built-in sample study and enables the window-wide `DEMO` indicator.
    public func loadDemoWorkspace() {
        isDemoMode = true
        isShowingCompletionPopover = true
        completionAnchorLine = 18
        adjudicationRationaleDraft = "Demo protocol adjudication note (unverified sample)."
        docking.isLeftSidebarVisible = true
        docking.isBottomDrawerVisible = true
        docking.rightInspectorMode = .pdfPreview
        docking.openManuscriptTabs = [
            OpenManuscriptTab(filePath: "main.tex", format: .latex, isPinned: true, wordCount: 410, lastCursorLine: 18, lastCursorColumn: 14),
            OpenManuscriptTab(filePath: "sections/methodology.tex", format: .latex, isPinned: false, wordCount: 225, lastCursorLine: 9, lastCursorColumn: 1),
            OpenManuscriptTab(filePath: "notes/protocol.typ", format: .typst, isPinned: false, wordCount: 140, lastCursorLine: 6, lastCursorColumn: 1)
        ]
        docking.activeManuscriptFilePath = "main.tex"
        docking.synchronizedCursor = ScholarCursorLocation(filePath: "main.tex", line: 18, column: 14)
        docking.selectedCiteKey = "vaswani2017attention"
        seedRichAcademicStudyIfNeeded()
        rebuildAllSubsystems()

        languageCancellable = ScholarLocalizer.shared.$language
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshActiveEditorLSPState()
                self.objectWillChange.send()
            }
    }

    // MARK: - Deterministic Rich Academic Corpus Seeding

    private func seedRichAcademicStudyIfNeeded() {
        try? database.setProjectTitle("[DEMO] Citation Audit & Academic Sample")

        _ = try? database.connection.execute("DELETE FROM plugin_states;")
        for plugin in BuiltInEditorialPluginCatalog.allPlugins {
            try? database.upsertPluginManifest(plugin)
        }
        preferences.pluginManifests = BuiltInEditorialPluginCatalog.allPlugins

        let mainTex = Self.canonicalMainTeXSource
        let methodologyTex = Self.canonicalMethodologyTeXSource
        let protocolTyp = Self.canonicalProtocolTypstSource
            .components(separatedBy: "\n")
            .map { $0.count < 2 ? ($0 + "  ") : $0 }
            .joined(separator: "\n")

        _ = try? database.upsertManuscriptFile(path: "main.tex", content: mainTex, format: .latex)
        _ = try? database.upsertManuscriptFile(path: "sections/methodology.tex", content: methodologyTex, format: .latex)
        _ = try? database.upsertManuscriptFile(path: "notes/protocol.typ", content: protocolTyp, format: .typst)

        for entry in Self.canonicalBibliographyCorpus {
            try? database.upsertBibliographyEntry(entry)
        }

        try? database.savePRISMAProtocol(
            picoProtocol,
            protocolID: "default",
            duplicateRecordsRemoved: 64,
            registerRecordsIdentified: 38,
            reportsNotRetrieved: 2
        )
        for study in Self.canonicalScreeningDeck {
            try? database.upsertScreeningStudy(study)
        }

        let existingSnapshots = (try? database.listSnapshots(filePath: "main.tex")) ?? []
        if existingSnapshots.count < 2 {
            _ = try? database.createSnapshot(
                label: "v1.0 Initial Submission Draft",
                authorName: "E. Vance (Demo)",
                filePath: "main.tex",
                sourceContent: Self.baselineSnapshotMainTeX,
                createdAt: Date(timeIntervalSince1970: 1_762_992_000)
            )
            _ = try? database.createSnapshot(
                label: "v1.2 Revised Sample Draft",
                authorName: "E. Vance & K. Takahashi (Demo)",
                filePath: "main.tex",
                sourceContent: mainTex,
                createdAt: Date(timeIntervalSince1970: 1_762_995_600)
            )
        }

        hydratePDFFixturesAndProvenance()
        lastBlockedInsertionAlert = nil
    }

    private func hydratePDFFixturesAndProvenance() {
        let specs = SyntheticAcademicPDFFixtureGenerator.canonicalFixtureSpecifications()
        var fixtures: [RenderedAcademicPDFFixture] = []
        var bitmapsMap: [String: [RenderedPDFPageBitmap]] = [:]
        var allPassages: [PDFPassageChunk] = []
        var allAnchors: [SyncTeXAnchor] = []

        for spec in specs {
            if let rendered = try? pdfGenerator.renderAcademicPDF(spec: spec) {
                fixtures.append(rendered)
                allPassages.append(contentsOf: rendered.expectedPassageChunks())
                allAnchors.append(contentsOf: rendered.syncTeXAnchors)
                bitmapsMap[rendered.citeKey] = Self.rasterizePDFPages(
                    pdfData: rendered.pdfData,
                    citeKey: rendered.citeKey,
                    scale: 2.0
                )
            }
        }

        self.renderedPDFFixtures = fixtures
        self.pdfPageBitmapsByKey = bitmapsMap
        if let firstFixture = fixtures.first {
            self.selectedPDFFixtureCiteKey = firstFixture.citeKey
        }
        try? database.upsertPDFPassages(allPassages)
        self.pdfPassages = (try? database.listPDFPassages()) ?? allPassages
        self.syncTeXAnchors = allAnchors

        // Build deterministic ClaimEvidenceProvenance rows aligned with real PDFPageRegionBox coordinates on page 0/1
        let primaryKey = fixtures.first?.citeKey ?? "vaswani2017attention"
        let secondaryKey = fixtures.dropFirst().first?.citeKey ?? primaryKey
        let primaryChunks = fixtures.first?.expectedPassageChunks() ?? []
        let box0 = primaryChunks.first?.boundingBox ?? PDFPageRegionBox(pageIndex: 0, x: 54, y: 470, width: 236, height: 86)
        let box1 = primaryChunks.dropFirst().first?.boundingBox ?? PDFPageRegionBox(pageIndex: 0, x: 318, y: 470, width: 236, height: 86)
        let box2 = primaryChunks.dropFirst(2).first?.boundingBox ?? PDFPageRegionBox(pageIndex: 0, x: 54, y: 320, width: 236, height: 92)
        let box3 = primaryChunks.dropFirst(3).first?.boundingBox ?? PDFPageRegionBox(pageIndex: 0, x: 318, y: 310, width: 236, height: 92)

        let links: [ClaimEvidenceProvenance] = [
            ClaimEvidenceProvenance(
                id: UUID(uuidString: "11111111-2222-4333-8444-555555555501")!,
                manuscriptFile: "main.tex",
                manuscriptLine: 16,
                manuscriptClaim: "Multi-head scaled dot-product attention achieves 28.4 BLEU on WMT 2014 EN-DE without recurrence.",
                citeKey: primaryKey,
                passageID: primaryChunks.first?.id ?? "chunk-01",
                pdfExcerpt: "On the WMT 2014 English-to-German translation task, the big Transformer model achieves 28.4 BLEU, outperforming prior ensembles by over 2.0 BLEU.",
                boundingBox: box0,
                bm25Score: 14.82,
                verdict: .groundedEntailment
            ),
            ClaimEvidenceProvenance(
                id: UUID(uuidString: "11111111-2222-4333-8444-555555555502")!,
                manuscriptFile: "main.tex",
                manuscriptLine: 22,
                manuscriptClaim: "Citation audit checks reduce 99.4% of hallucinated BibTeX keys prior to compilation.",
                citeKey: primaryKey,
                passageID: primaryChunks.dropFirst().first?.id ?? "chunk-02",
                pdfExcerpt: "Empirical audit across 1,240 LLM-assisted drafts reported a 94.2% reduction (not 99.4%) in unresolved DOI insertions under offline lexicon checks.",
                boundingBox: box1,
                bm25Score: 11.36,
                verdict: .numericDiscrepancy
            ),
            ClaimEvidenceProvenance(
                id: UUID(uuidString: "11111111-2222-4333-8444-555555555503")!,
                manuscriptFile: "sections/methodology.tex",
                manuscriptLine: 11,
                manuscriptClaim: "PRISMA 2020 flow reporting separates database records (n = 412) from trial registry records (n = 38).",
                citeKey: secondaryKey,
                passageID: primaryChunks.dropFirst(2).first?.id ?? "chunk-03",
                pdfExcerpt: "PRISMA 2020 Item 16a mandates disaggregating records identified from bibliographic databases versus clinical and protocol registers.",
                boundingBox: box2,
                bm25Score: 13.15,
                verdict: .groundedEntailment
            ),
            ClaimEvidenceProvenance(
                id: UUID(uuidString: "11111111-2222-4333-8444-555555555504")!,
                manuscriptFile: "sections/methodology.tex",
                manuscriptLine: 19,
                manuscriptClaim: "Byrt's PABAK mitigates high-prevalence kappa attenuation when inclusion rates fall below 12%.",
                citeKey: primaryKey,
                passageID: primaryChunks.dropFirst(3).first?.id ?? "chunk-04",
                pdfExcerpt: "Under skewed marginal distributions, Cohen's kappa exhibits paradoxical suppression while PABAK and Gwet's AC1 remain stable.",
                boundingBox: box3,
                bm25Score: 9.74,
                verdict: .partialEvidence
            ),
            ClaimEvidenceProvenance(
                id: UUID(uuidString: "11111111-2222-4333-8444-555555555505")!,
                manuscriptFile: "main.tex",
                manuscriptLine: 27,
                manuscriptClaim: "Zero-shot neural theorem synthesis resolves every undecidable macro expansion cycle in O(1) time.",
                citeKey: "smith2025hallucinated",
                passageID: "unindexed-hallucinated",
                pdfExcerpt: "No indexed PDF passage exists: target key @smith2025hallucinated is marked NOT_FOUND.",
                boundingBox: PDFPageRegionBox(pageIndex: 0, x: 318, y: 190, width: 236, height: 74),
                bm25Score: 0.42,
                verdict: .unsupportedClaim
            )
        ]

        try? database.upsertClaimProvenanceLinks(links)
        self.claimProvenanceLinks = (try? database.listClaimProvenanceLinks()) ?? links
        self.selectedClaimProvenanceID = self.claimProvenanceLinks.first?.id
    }

    // MARK: - Full Subsystem Recomputation Pipeline

    public func rebuildAllSubsystems() {
        manuscriptFiles = (try? database.listManuscriptFiles()) ?? []
        bibliographyEntries = (try? database.listBibliographyEntries()) ?? []
        let hasWorkspaceData = !manuscriptFiles.isEmpty || !bibliographyEntries.isEmpty || isDemoMode

        let rawTitle = (try? database.projectTitle()) ?? (isDemoMode ? "[DEMO] Citation Audit & Academic Sample" : "ScholarOS")
        projectTitle = hasWorkspaceData ? rawTitle : "ScholarOS"
        primaryManuscriptPath = manuscriptFiles.isEmpty ? "" : ((try? database.primaryManuscriptFile()) ?? manuscriptFiles[0].path)

        docking.syncWithManuscriptRecords(
            manuscriptFiles,
            primaryFile: primaryManuscriptPath.isEmpty ? "main.tex" : primaryManuscriptPath
        )

        // 1. Rebuild Incremental LSP Workspace (never inject synthetic demo TeX when empty)
        var fileMap: [String: String] = [:]
        for record in manuscriptFiles {
            fileMap[record.path] = record.content
        }

        let lsp = ScholarLSPWorkspaceService(
            rootFilePath: primaryManuscriptPath.isEmpty ? "main.tex" : primaryManuscriptPath,
            files: fileMap,
            bibliography: bibliographyEntries,
            citationStyle: selectedCSLStyle
        )
        self.lspService = lsp
        refreshActiveEditorLSPState()

        // 2. Rebuild Firewall Audit, Deduplication, CSL Preview & Myers Track Changes
        refreshFirewallAndTrackChanges()

        // 3. Rebuild Barnes-Hut Citation Graph, Louvain Communities, Main Path, Kleinberg Bursts & Missing Citations
        refreshCitationKnowledgeGraph()

        // 4. Rebuild PRISMA 2020 Deck, Cohen's Kappa / PABAK / AC1, Seed Recall, RoB 2.0 & Meta-Synthesis
        refreshPRISMAAndMetaSynthesis()

        // 5. Run JavaScriptCore Editorial Plugins & Exact APA 7th Statistical Recalculator
        runEditorialPluginSuite()

        // 6. Refresh SQLite WAL Project Telemetry
        projectStats = try? database.computeProjectStats()
    }

    public func refreshActiveEditorLSPState() {
        let activePath = docking.activeManuscriptFilePath
        let source = lspService.documentSnapshot(for: activePath)?.source
            ?? (try? database.manuscriptContent(path: activePath))
            ?? ""
        activeSourceBuffer = source
        activeTokens = lspService.documentSnapshot(for: activePath)?.tokens ?? []
        outlineEntries = lspService.documentOutline
        if docking.selectedOutlineEntryID == nil {
            docking.selectedOutlineEntryID = outlineEntries.first?.id
        }

        let diagReport = lspService.diagnosticsReport()
        diagnostics = diagReport.diagnostics
        codeActions = diagReport.codeActions
        manuscriptMetrics = lspService.manuscriptMetrics()

        // Live completion candidates at `\cite{` anchor or current cursor
        let cursor = docking.synchronizedCursor
        let rawCompletions = lspService.completions(
            atLine: cursor.line,
            column: cursor.column,
            in: activePath,
            maxItems: 8
        )
        if !rawCompletions.isEmpty {
            let lang = ScholarLocalizer.shared.language
            completionCandidates = rawCompletions.map { item in
                guard lang == .zhHans, item.category == .citation,
                      let entry = bibliographyEntries.first(where: { $0.citeKey == item.insertText })
                else {
                    return item
                }
                return LSPCompletionItem(
                    id: item.id,
                    insertText: item.insertText,
                    title: item.title,
                    subtitle: "\(entry.firstAuthorFamily) (\(entry.year.map(String.init) ?? "n.d.")) • \(entry.firewallClass.localizedBadgeTitle(lang))",
                    detailMarkdown: item.detailMarkdown,
                    category: item.category,
                    relevanceScore: item.relevanceScore
                )
            }
        } else {
            let lang = ScholarLocalizer.shared.language
            // Provide deterministic citation completions so popover card is always rich when toggled
            completionCandidates = bibliographyEntries.prefix(6).map { entry in
                LSPCompletionItem(
                    id: "cite-\(entry.citeKey)",
                    insertText: entry.citeKey,
                    title: "@\(entry.citeKey)",
                    subtitle: "\(entry.firstAuthorFamily) (\(entry.year.map(String.init) ?? "n.d.")) • \(entry.firewallClass.localizedBadgeTitle(lang))",
                    detailMarkdown: "\(entry.title) — \(entry.venue.isEmpty ? lang.L("Archival Preprint", "预印本档案") : entry.venue)",
                    category: .citation,
                    relevanceScore: entry.firewallClass.allowsManuscriptInsertion ? 0.96 : 0.15
                )
            }
        }

        // Hover preview for selected citation or cursor token
        let lang = ScholarLocalizer.shared.language
        if let hover = lspService.hover(atLine: cursor.line, column: cursor.column, in: activePath) {
            if let fw = hover.firewallClass, lang == .zhHans {
                activeHoverCard = LSPHoverCard(
                    title: hover.title,
                    categoryBadge: fw.localizedBadgeTitle(lang),
                    markdownBody: hover.markdownBody,
                    firewallClass: fw,
                    targetSpan: hover.targetSpan,
                    expandedPreview: hover.expandedPreview
                )
            } else {
                activeHoverCard = hover
            }
        } else if let selectedKey = docking.selectedCiteKey,
                  let entry = bibliographyEntries.first(where: { $0.citeKey == selectedKey })
        {
            let csl = cslEngine.formatEntry(entry, style: selectedCSLStyle)
            activeHoverCard = LSPHoverCard(
                title: "\(entry.firstAuthorFamily) (\(entry.year.map(String.init) ?? "n.d.")) — @\(entry.citeKey)",
                categoryBadge: entry.firewallClass.localizedBadgeTitle(lang),
                markdownBody: entry.title,
                firewallClass: entry.firewallClass,
                targetSpan: TextSpan(
                    filePath: activePath,
                    start: TextPosition(line: cursor.line, column: cursor.column),
                    end: TextPosition(line: cursor.line, column: cursor.column + selectedKey.count)
                ),
                expandedPreview: csl.bibliographyPlainText
            )
        }
    }

    public func refreshFirewallAndTrackChanges() {
        bibliographyEntries = (try? database.listBibliographyEntries()) ?? bibliographyEntries
        firewallAuditReport = firewallEngine.auditLibrary(bibliographyEntries)
        duplicateCandidates = (try? database.detectDuplicateBibliographyCandidates(
            similarityThreshold: preferences.jaroWinklerDeduplicationThreshold
        )) ?? []
        formattedCSLPreview = cslEngine.formatBibliography(entries: bibliographyEntries, style: selectedCSLStyle).items

        snapshots = (try? database.listSnapshots(filePath: primaryManuscriptPath)) ?? []
        // Note: `listSnapshots` returns oldest first (`created_at ASC`)
        if snapshots.count >= 2 {
            let baseline = snapshots[0]
            let newest = snapshots[snapshots.count - 1]
            if selectedBaselineSnapshotID == nil { selectedBaselineSnapshotID = baseline.id }
            if selectedRevisedSnapshotID == nil { selectedRevisedSnapshotID = newest.id }
        }
        recomputeTrackChangesDiff()
    }

    public func recomputeTrackChangesDiff() {
        let baseSnap = snapshots.first(where: { $0.id == selectedBaselineSnapshotID }) ?? snapshots.first
        let revSnap = snapshots.first(where: { $0.id == selectedRevisedSnapshotID }) ?? snapshots.last

        if let baseSnap, let revSnap, baseSnap.id != revSnap.id {
            let report = diffEngine.diffSnapshots(baseline: baseSnap, revised: revSnap)
            self.trackChangesReport = report
            self.trackChangesHunks = report.extractHunks(contextCharacterLimit: 48)
        } else if !activeSourceBuffer.isEmpty {
            let report = diffEngine.diff(
                original: baseSnap?.sourceContent ?? activeSourceBuffer,
                revised: activeSourceBuffer,
                filePath: primaryManuscriptPath.isEmpty ? "main.tex" : primaryManuscriptPath,
                baselineLabel: baseSnap?.label ?? "Baseline",
                revisedLabel: "Working Buffer"
            )
            self.trackChangesReport = report
            self.trackChangesHunks = report.extractHunks(contextCharacterLimit: 48)
        } else {
            self.trackChangesReport = nil
            self.trackChangesHunks = []
        }
    }

    public func refreshCitationKnowledgeGraph() {
        let snapshot = graphBuilder.buildKnowledgeGraph(from: bibliographyEntries)
        self.graphSnapshot = snapshot

        let partition = louvainDetector.detectLouvainCommunities(
            entries: bibliographyEntries,
            edges: snapshot.edges
        )
        self.louvainPartition = partition
        self.bridgeProfiles = louvainDetector.analyzeStructuralBridges(
            entries: bibliographyEntries,
            edges: snapshot.edges,
            partition: partition
        )
        self.kleinbergBurstReport = louvainDetector.detectKleinbergTemporalBursts(entries: bibliographyEntries)
        self.mainPathReport = mainPathAnalyzer.analyzeMainPaths(entries: bibliographyEntries)

        let citedKeys = extractCitedKeysAcrossManuscripts()
        let combinedProse = manuscriptFiles.map(\.content).joined(separator: "\n")
        self.missingCitationsReport = mainPathAnalyzer.recommendMissingCitations(
            citedKeysInManuscript: citedKeys,
            manuscriptContextText: combinedProse,
            corpus: bibliographyEntries
        )

        if selectedGraphCiteKey == nil || !snapshot.nodes.contains(where: { $0.citeKey == selectedGraphCiteKey }) {
            selectedGraphCiteKey = snapshot.nodes.first?.citeKey
        }
    }

    public func refreshPRISMAAndMetaSynthesis() {
        if let loadedProto = try? database.loadPRISMAProtocol() {
            picoProtocol = loadedProto
        }
        let allStudies = (try? database.listScreeningStudies(
            stage: prismaStageFilter,
            conflictsOnly: prismaConflictsOnly
        )) ?? []
        screeningStudies = allStudies

        let fullDeck = (try? database.listScreeningStudies()) ?? allStudies
        if selectedScreeningStudyID == nil || !allStudies.contains(where: { $0.id == selectedScreeningStudyID }) {
            selectedScreeningStudyID = allStudies.first(where: \.hasReviewerConflict)?.id ?? allStudies.first?.id
        }

        if let computedMetrics = try? database.computePRISMAMetrics() {
            prismaMetrics = computedMetrics
        }

        guard !fullDeck.isEmpty else {
            agreementReport = nil
            seedRecallReport = nil
            rob2Matrix = nil
            effectEstimates = []
            metaSynthesisPlan = nil
            return
        }

        agreementReport = reliabilityEngine.evaluateDualRaterAgreement(
            studies: fullDeck,
            protocolSpec: picoProtocol
        )

        let seeds: [GoldStandardSeedStudy] = [
            GoldStandardSeedStudy(
                seedID: "seed-page2021",
                expectedCiteKey: "page2021prisma",
                expectedDOI: "10.1136/bmj.n71",
                canonicalTitle: "The PRISMA 2020 statement: an updated guideline for reporting systematic reviews",
                publicationYear: 2021,
                inclusionRationale: "Canonical reporting standard for transparent multi-phase evidence synthesis."
            ),
            GoldStandardSeedStudy(
                seedID: "seed-cohen1960",
                expectedCiteKey: "cohen1960kappa",
                expectedDOI: "10.1177/001316446002000104",
                canonicalTitle: "A Coefficient of Agreement for Nominal Scales",
                publicationYear: 1960,
                inclusionRationale: "Foundational chance-corrected nominal inter-rater reliability estimator."
            ),
            GoldStandardSeedStudy(
                seedID: "seed-vaswani2017",
                expectedCiteKey: "vaswani2017attention",
                expectedDOI: "10.48550/arXiv.1706.03762",
                canonicalTitle: "Attention Is All You Need",
                publicationYear: 2017,
                inclusionRationale: "Benchmark transformer baseline evaluated in citation grounding experiments."
            )
        ]
        seedRecallReport = reliabilityEngine.validateGoldStandardSeedRecall(
            seeds: seeds,
            screenedCorpus: fullDeck
        )

        let assessments: [RoB2StudyAssessment] = Self.canonicalRoB2Assessments
        rob2Matrix = rob2Planner.buildRoB2TrafficLightMatrix(assessments: assessments)

        let effects = Self.canonicalEffectEstimates
        self.effectEstimates = effects
        metaSynthesisPlan = rob2Planner.planMetaSynthesis(
            outcomeName: "Citation Hallucination Reduction (Hedges' g)",
            effectMeasureLabel: "Hedges' g",
            studies: effects
        )
    }

    private static func sanitizeFilesForEditorialWorkspace(_ rawFiles: [String: String]) -> [String: String] {
        var safe: [String: String] = [:]
        for (path, content) in rawFiles {
            if ManuscriptFormat.detect(fromPath: path) == .typst {
                safe[path] = content
                    .components(separatedBy: "\n")
                    .map { $0.count < 2 ? ($0 + "  ") : $0 }
                    .joined(separator: "\n")
            } else {
                safe[path] = content
            }
        }
        return safe
    }

    public func runEditorialPluginSuite() {
        var filesMap: [String: String] = [:]
        for file in manuscriptFiles {
            filesMap[file.path] = file.content
        }
        if filesMap.isEmpty && !activeSourceBuffer.isEmpty {
            filesMap[primaryManuscriptPath.isEmpty ? "main.tex" : primaryManuscriptPath] = activeSourceBuffer
        }
        guard !filesMap.isEmpty else {
            editorialRunSummary = nil
            editorialFindings = []
            perPluginTimingsMs = [:]
            pluginLogs = []
            apaStatRows = []
            jsScratchpadOutput = nil
            projectStats = try? database.computeProjectStats()
            return
        }
        let safeFilesMap = Self.sanitizeFilesForEditorialWorkspace(filesMap)

        let runner = EditorialPluginAuditRunner(options: preferences.buildAuditRunOptions())
        if let summary = try? runner.run(
            files: safeFilesMap,
            primaryFilePath: primaryManuscriptPath.isEmpty ? "main.tex" : primaryManuscriptPath,
            bibliography: bibliographyEntries,
            plugins: preferences.pluginManifests
        ) {
            editorialRunSummary = summary
            editorialFindings = summary.findings
            perPluginTimingsMs = summary.perPluginTimingsMs
            pluginLogs = summary.logs
            try? database.replaceEditorialFindings(summary.findings)
        }

        apaStatRows = computeAPAStatVerificationTable()
        if jsScratchpadOutput == nil {
            evaluateScratchpadJS()
        }
        projectStats = try? database.computeProjectStats()
    }

    // MARK: - Interactive Workbench Mutations & Actions

    /// Updates the active manuscript buffer, re-lexing incrementally via `ScholarLSPWorkspaceService` and recording undo state.
    public func updateActiveManuscriptSource(_ updatedText: String) {
        let path = docking.activeManuscriptFilePath
        let previousText = activeSourceBuffer
        guard updatedText != previousText else { return }

        activeSourceBuffer = updatedText
        lspService.openOrReplaceDocument(filePath: path, source: updatedText)
        undoRedo.recordCoalescingManuscriptEdit(
            filePath: path,
            previousText: previousText,
            updatedText: updatedText,
            actionTitle: "Edit \(path)"
        )
        manuscriptFiles = (try? database.listManuscriptFiles()) ?? manuscriptFiles
        docking.setTabDirty(path, isDirty: false, wordCount: updatedText.split(whereSeparator: \.isWhitespace).count)
        refreshActiveEditorLSPState()
        recomputeTrackChangesDiff()
    }

    /// Enforces the 5-class `CitationVerificationFirewall` gate before inserting `\cite{key}` or `@key` into the manuscript.
    @discardableResult
    public func attemptInsertCitation(_ citeKey: String) -> Bool {
        let path = docking.activeManuscriptFilePath
        let format = ManuscriptFormat.detect(fromPath: path)
        let commandSnippet = (format == .typst) ? "@\(citeKey)" : "\\cite{\(citeKey)}"

        do {
            let entry = try database.validateCitationKeyForInsertion(citeKey)
            let previous = activeSourceBuffer
            let updated = previous + (previous.hasSuffix("\n") ? "" : " ") + commandSnippet
            try undoRedo.performAndRecord(
                .editManuscript(filePath: path, previousText: previous, updatedText: updated),
                actionTitle: "Cite @\(entry.citeKey)"
            )
            lspService.openOrReplaceDocument(filePath: path, source: updated)
            manuscriptFiles = (try? database.listManuscriptFiles()) ?? manuscriptFiles
            refreshActiveEditorLSPState()
            projectStats = try? database.computeProjectStats()
            let lang = ScholarLocalizer.shared.language
            toastCenter.enqueue(
                tone: .verified,
                title: lang.L("Inserted Verified Citation @\(entry.citeKey)", "已插入权威核验引文 @\(entry.citeKey)"),
                detail: "\(entry.firewallClass.localizedBadgeTitle(lang)) — \(entry.doi ?? entry.arxivID ?? lang.L("Archival Registry", "学术注册库"))"
            )
            return true
        } catch let error as ScholarOSError {
            let lang = ScholarLocalizer.shared.language
            let entryClass = bibliographyEntries.first(where: { $0.citeKey == citeKey })?.firewallClass ?? .notFound
            let rejection = FirewallGateRejectionRecord(
                citeKey: citeKey,
                errorCode: error.errorCodeIdentifier,
                firewallClass: entryClass,
                attemptedCommand: commandSnippet,
                reason: error.localizedDescription
            )
            lastBlockedInsertionAlert = rejection
            toastCenter.enqueue(
                tone: .blocker,
                title: lang.L("BLOCKED \(error.errorCodeIdentifier): @\(citeKey)", "防火墙已拦截 \(error.errorCodeIdentifier): @\(citeKey)"),
                detail: lang.L(
                    "Unverified or hallucinated citation cannot enter manuscript prose.",
                    "未核验或被标记为伪造/撤稿的引文禁止写入手稿正文。"
                ),
                actionTitle: lang.L("Inspect Firewall", "查看防火墙")
            ) { [weak self] in
                self?.docking.focusCitation(citeKey, switchToFirewallStudio: true)
            }
            return false
        } catch {
            return false
        }
    }

    /// Jumps bidirectionally from a manuscript `(file, line)` coordinate to its matching two-column PDF SyncTeX anchor.
    public func triggerForwardSyncTeXJump(filePath: String? = nil, line: Int? = nil) {
        let file = filePath ?? docking.activeManuscriptFilePath
        let targetLine = line ?? docking.synchronizedCursor.line
        if let anchor = lspService.forwardSearch(sourceFile: file, line: targetLine, column: 1)
            ?? syncTeXAnchors.min(by: { abs($0.line - targetLine) < abs($1.line - targetLine) })
        {
            docking.activeSyncTeXAnchor = anchor
            selectedPDFPageIndex = anchor.pdfPageIndex
            if docking.activeStudioTab == .manuscriptEditor && docking.rightInspectorMode == .none {
                docking.rightInspectorMode = .pdfPreview
            }
        }
    }

    /// Jumps from a PDF coordinate `(pageIndex, xPt, yPt)` back to the originating LaTeX/Typst source line.
    public func triggerInverseSyncTeXJump(pageIndex: Int, xPt: Double, yPt: Double) {
        if let anchor = lspService.inverseSearch(pdfPageIndex: pageIndex, xPt: xPt, yPt: yPt)?.anchor
            ?? syncTeXAnchors.filter({ $0.pdfPageIndex == pageIndex }).min(by: {
                hypot($0.xPt - xPt, $0.yPt - yPt) < hypot($1.xPt - xPt, $1.yPt - yPt)
            })
        {
            docking.navigateToSyncTeXAnchor(anchor)
            refreshActiveEditorLSPState()
        }
    }

    /// Focuses a `ClaimEvidenceProvenance` row, highlighting its bounding box on the two-column PDF page.
    public func selectClaimProvenance(_ claim: ClaimEvidenceProvenance) {
        selectedClaimProvenanceID = claim.id
        if renderedPDFFixtures.contains(where: { $0.citeKey == claim.citeKey }) {
            selectedPDFFixtureCiteKey = claim.citeKey
        }
        selectedPDFPageIndex = claim.boundingBox.pageIndex
        docking.selectedCiteKey = claim.citeKey
    }

    /// Records a Reviewer A / Reviewer B screening vote in SQLite WAL with full undo/redo support.
    public func voteOnSelectedScreeningStudy(decision: ScreeningDecision, reviewerSlot: String = "A") {
        guard let studyID = selectedScreeningStudyID,
              let current = screeningStudies.first(where: { $0.id == studyID })
        else { return }

        let previousDecision = (reviewerSlot == "B") ? current.reviewerBDecision : current.reviewerADecision
        _ = try? undoRedo.performAndRecord(
            .recordScreeningVote(
                studyID: studyID,
                reviewerSlot: reviewerSlot,
                previous: previousDecision,
                updated: decision
            ),
            actionTitle: "PRISMA Vote \(decision.summaryLabel)"
        )
        refreshPRISMAAndMetaSynthesis()
        projectStats = try? database.computeProjectStats()
    }

    /// Adjudicates a dual-rater conflict on the currently selected `ScreeningStudyRecord`.
    public func adjudicateSelectedScreeningStudy(decision: ScreeningDecision, rationale: String) {
        guard let studyID = selectedScreeningStudyID else { return }
        _ = try? database.recordScreeningDecision(
            studyID: studyID,
            reviewerSlot: "ADJUDICATED",
            decision: decision,
            rationale: rationale.isEmpty ? "Consensus third-reviewer protocol adjudication." : rationale
        )
        refreshPRISMAAndMetaSynthesis()
        projectStats = try? database.computeProjectStats()
        let lang = ScholarLocalizer.shared.language
        toastCenter.enqueue(
            tone: .verified,
            title: lang.L(
                "Conflict Adjudicated (\(decision.summaryLabel))",
                "已完成分歧裁决 (\(decision.localizedSummaryLabel(lang)))"
            ),
            detail: lang.L(
                "Updated PRISMA 2020 flow counts and Reviewer B unblinded audit log.",
                "已同步更新 PRISMA 2020 流程计数与审稿人 B 审计日志。"
            )
        )
    }

    public func selectNextScreeningStudy(delta: Int) {
        guard !screeningStudies.isEmpty else { return }
        let currentIndex = screeningStudies.firstIndex(where: { $0.id == selectedScreeningStudyID }) ?? 0
        let nextIndex = (currentIndex + delta + screeningStudies.count) % screeningStudies.count
        selectedScreeningStudyID = screeningStudies[nextIndex].id
    }

    /// Accepts a single Myers word-level diff hunk and writes the resulting source back to the active manuscript buffer.
    public func acceptTrackChangeHunk(_ hunk: TrackChangeHunk) {
        guard let report = trackChangesReport,
              let firstSpanID = hunk.spanIDs.first
        else { return }
        let updatedReport = report.acceptHunk(containingSpanID: firstSpanID)
        let mergedText = updatedReport.reconstructRevisedText()
        let previous = activeSourceBuffer
        _ = try? undoRedo.performAndRecord(
            .editManuscript(filePath: primaryManuscriptPath, previousText: previous, updatedText: mergedText),
            actionTitle: "Accept Diff Hunk Ln \(hunk.approximateLine)"
        )
        lspService.openOrReplaceDocument(filePath: primaryManuscriptPath, source: mergedText)
        manuscriptFiles = (try? database.listManuscriptFiles()) ?? manuscriptFiles
        trackChangesReport = updatedReport
        trackChangesHunks = updatedReport.extractHunks(contextCharacterLimit: 48)
        refreshActiveEditorLSPState()
    }

    /// Rejects a single Myers word-level diff hunk, reverting that span to the baseline snapshot wording.
    public func rejectTrackChangeHunk(_ hunk: TrackChangeHunk) {
        guard let report = trackChangesReport,
              let firstSpanID = hunk.spanIDs.first
        else { return }
        let updatedReport = report.rejectHunk(containingSpanID: firstSpanID)
        let revertedText = updatedReport.reconstructRevisedText()
        let previous = activeSourceBuffer
        _ = try? undoRedo.performAndRecord(
            .editManuscript(filePath: primaryManuscriptPath, previousText: previous, updatedText: revertedText),
            actionTitle: "Reject Diff Hunk Ln \(hunk.approximateLine)"
        )
        lspService.openOrReplaceDocument(filePath: primaryManuscriptPath, source: revertedText)
        manuscriptFiles = (try? database.listManuscriptFiles()) ?? manuscriptFiles
        trackChangesReport = updatedReport
        trackChangesHunks = updatedReport.extractHunks(contextCharacterLimit: 48)
        refreshActiveEditorLSPState()
    }

    /// Applies an `EditorialAuditFinding.suggestedRewrite` directly to its source manuscript file with SQLite undo journaling.
    public func applyEditorialRewrite(_ finding: EditorialAuditFinding) {
        let currentSource = (try? database.manuscriptContent(path: finding.filePath)) ?? activeSourceBuffer
        guard let rewritten = EditorialPluginAuditRunner.applySuggestedRewrite(finding, to: currentSource) else {
            return
        }
        _ = try? undoRedo.performAndRecord(
            .editManuscript(filePath: finding.filePath, previousText: currentSource, updatedText: rewritten),
            actionTitle: "Rewrite \(finding.category)"
        )
        lspService.openOrReplaceDocument(filePath: finding.filePath, source: rewritten)
        manuscriptFiles = (try? database.listManuscriptFiles()) ?? manuscriptFiles
        refreshActiveEditorLSPState()
        runEditorialPluginSuite()
        let lang = ScholarLocalizer.shared.language
        toastCenter.enqueue(
            tone: .verified,
            title: lang.L(
                "Applied Scholarly Rewrite (\(finding.filePath):\(finding.line))",
                "已应用学术改写建议 (\(finding.filePath):\(finding.line))"
            ),
            detail: finding.suggestedRewrite ?? finding.localizedCategory(lang)
        )
    }

    /// Applies an LSP diagnostic quick-fix onto its target file.
    public func applyDiagnosticQuickFix(_ diagnostic: LSPDiagnostic) {
        if let matchAction = codeActions.first(where: { $0.diagnosticCode == diagnostic.code }),
           (try? lspService.applyCodeAction(id: matchAction.id)) != nil,
           let snap = lspService.documentSnapshot(for: diagnostic.span.filePath)
        {
            let previous = (try? database.manuscriptContent(path: diagnostic.span.filePath)) ?? ""
            _ = try? undoRedo.performAndRecord(
                .editManuscript(filePath: diagnostic.span.filePath, previousText: previous, updatedText: snap.source),
                actionTitle: "Quick Fix \(diagnostic.code)"
            )
            manuscriptFiles = (try? database.listManuscriptFiles()) ?? manuscriptFiles
            refreshActiveEditorLSPState()
        } else if let suggested = diagnostic.suggestedFix {
            toastCenter.enqueue(tone: .info, title: "Suggested Fix [\(diagnostic.code)]", detail: suggested)
        }
    }

    /// Merges a Jaro-Winkler duplicate reference candidate, retaining the canonical DOI-verified primary entry.
    public func mergeDuplicateReference(_ candidate: DuplicateReferenceCandidate) {
        _ = try? database.deleteBibliographyEntry(citeKey: candidate.duplicateCiteKey)
        refreshFirewallAndTrackChanges()
        refreshCitationKnowledgeGraph()
        projectStats = try? database.computeProjectStats()
        toastCenter.enqueue(
            tone: .verified,
            title: "Deduplicated @\(candidate.duplicateCiteKey) → @\(candidate.primaryCiteKey)",
            detail: String(format: "Jaro-Winkler %.1f%% merged into canonical record.", candidate.titleJaroWinkler * 100.0)
        )
    }

    /// Parses BibTeX or RIS/PubMed `.nbib` text, audits through `CitationVerificationFirewall`, and imports into SQLite.
    public func importBibliographyText(_ rawText: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var parsedEntries: [BibliographyEntry] = []
        if trimmed.contains("@") {
            if let result = try? BibTeXCodec().parse(trimmed) {
                parsedEntries = result
            }
        } else if trimmed.contains("PMID-") || trimmed.contains("TI  -") {
            parsedEntries = (try? PubMedNBIBParser().parse(trimmed)) ?? []
        } else {
            parsedEntries = (try? RISParser().parse(trimmed)) ?? []
        }

        guard !parsedEntries.isEmpty else {
            toastCenter.enqueue(tone: .advisory, title: "No BibTeX / RIS Entries Parsed", detail: "Provide valid @article{...} or TY  - JOUR records.")
            return
        }

        let auditedEntries = firewallEngine.auditLibrary(parsedEntries).auditedEntries
        for audited in auditedEntries {
            _ = try? undoRedo.performAndRecord(
                .upsertBibliography(previous: nil, updated: audited),
                actionTitle: "Import @\(audited.citeKey)"
            )
        }

        bibtexImportDraft = ""
        rebuildAllSubsystems()
        toastCenter.enqueue(
            tone: .verified,
            title: "Imported \(parsedEntries.count) Reference(s) via Firewall",
            detail: "Evaluated DOI/arXiv/PubMed syntax and Jaro-Winkler duplicates."
        )
    }

    /// Evaluates the interactive JavaScriptCore scratchpad plugin in an isolated `JSVirtualMachine`.
    public func evaluateScratchpadJS() {
        var filesMap: [String: String] = [:]
        for f in manuscriptFiles {
            filesMap[f.path] = f.content
        }
        if filesMap.isEmpty {
            filesMap[primaryManuscriptPath] = activeSourceBuffer
        }

        let workspace = PreparedEditorialWorkspace(
            files: Self.sanitizeFilesForEditorialWorkspace(filesMap),
            primaryFilePath: primaryManuscriptPath,
            bibliography: bibliographyEntries
        )
        let manifest = ScholarPluginManifest(
            id: "scratchpad.live-evaluator",
            name: "Interactive JS Scratchpad",
            version: "1.0.0",
            summary: "Ad-hoc JavaScriptCore AST, Metrics & Statistical Sandbox",
            capabilities: ScholarPluginCapability.allCases,
            isBuiltIn: false,
            isEnabled: true,
            scriptSource: jsScratchpadSource
        )
        let validation = EditorialPluginSyntaxValidator.validate(manifest)
        if !validation.isSyntaxValid {
            jsScratchpadOutput = JSScratchpadEvaluationOutput(
                isSuccess: false,
                elapsedMilliseconds: 0.0,
                emittedFindings: [],
                consoleLogs: [],
                statusSummary: "Syntax Error",
                errorMessage: validation.syntaxErrorMessage
            )
            return
        }

        let sandbox = EditorialJavaScriptSandbox(
            configuration: EditorialSandboxConfiguration(venueMode: preferences.venueAuditMode)
        )
        do {
            let res = try sandbox.executePlugin(manifest, in: workspace)
            jsScratchpadOutput = JSScratchpadEvaluationOutput(
                isSuccess: true,
                elapsedMilliseconds: res.executionTimeMs,
                emittedFindings: res.findings,
                consoleLogs: res.logs,
                statusSummary: String(
                    format: "OK • %.2f ms • %d finding(s) • %d console line(s)",
                    res.executionTimeMs,
                    res.findings.count,
                    res.logs.count
                )
            )
        } catch {
            jsScratchpadOutput = JSScratchpadEvaluationOutput(
                isSuccess: false,
                elapsedMilliseconds: 0.0,
                emittedFindings: [],
                consoleLogs: [],
                statusSummary: "Runtime Exception",
                errorMessage: error.localizedDescription
            )
        }
    }

    public func createNamedRevisionSnapshot() {
        let path = docking.activeManuscriptFilePath
        let content = (try? database.manuscriptContent(path: path)) ?? activeSourceBuffer
        let nextIndex = snapshots.count + 1
        if let snap = try? database.createSnapshot(
            label: "v1.\(nextIndex) Archival Checkpoint",
            authorName: "ScholarOS Studio",
            filePath: path,
            sourceContent: content
        ) {
            snapshots = (try? database.listSnapshots(filePath: primaryManuscriptPath)) ?? snapshots
            selectedRevisedSnapshotID = snap.id
            recomputeTrackChangesDiff()
            let lang = ScholarLocalizer.shared.language
            toastCenter.enqueue(
                tone: .verified,
                title: lang.L("Saved Snapshot \(snap.label)", "已保存修订快照 \(snap.label)"),
                detail: lang.L("\(snap.wordCount) words archived in SQLite WAL.", "共 \(snap.wordCount) 词已归档至 SQLite WAL。")
            )
        }
    }

    public func performUndo() {
        guard undoRedo.canUndo else { return }
        if let label = try? undoRedo.undo() {
            rebuildAllSubsystems()
            let lang = ScholarLocalizer.shared.language
            toastCenter.enqueue(tone: .info, title: lang.L("Undid \(label)", "已撤销 \(label)"))
        }
    }

    public func performRedo() {
        guard undoRedo.canRedo else { return }
        if let label = try? undoRedo.redo() {
            rebuildAllSubsystems()
            let lang = ScholarLocalizer.shared.language
            toastCenter.enqueue(tone: .info, title: lang.L("Redid \(label)", "已重做 \(label)"))
        }
    }

    public func syncPluginsToDatabase(_ manifests: [ScholarPluginManifest]) {
        preferences.pluginManifests = manifests
        for item in manifests {
            try? database.upsertPluginManifest(item)
        }
        runEditorialPluginSuite()
    }

    public func handleCommandPaletteAction(_ action: ScholarPaletteCommandAction) {
        switch action {
        case .switchStudioTab(let tab):
            docking.activeStudioTab = tab
        case .openManuscriptLocation(let filePath, let line):
            docking.openManuscript(filePath: filePath, line: line, switchToEditor: true)
            refreshActiveEditorLSPState()
        case .focusCitation(let citeKey):
            docking.focusCitation(citeKey, openRightInspector: true)
            refreshActiveEditorLSPState()
        case .insertVerifiedCitation(let citeKey):
            _ = attemptInsertCitation(citeKey)
        case .setRightInspector(let mode):
            docking.setRightInspectorMode(mode)
        case .revealDrawer(let channel):
            docking.revealBottomDrawer(channel: channel)
        case .toggleLeftSidebar:
            docking.toggleLeftSidebar()
        case .runEditorialPlugins:
            runEditorialPluginSuite()
            docking.activeStudioTab = .editorialAudit
        case .createSnapshot:
            createNamedRevisionSnapshot()
        case .undo:
            performUndo()
        case .redo:
            performRedo()
        case .openPreferences:
            docking.isPreferencesPresented = true
        case .openShortcutLegend:
            docking.isShortcutLegendPresented = true
        case .toggleLanguage:
            ScholarLocalizer.shared.toggleLanguage()
            let lang = ScholarLocalizer.shared.language
            toastCenter.enqueue(
                tone: .info,
                title: lang.L("Switched to English", "已切换至简体中文"),
                detail: lang.L("All ScholarOS studios updated live.", "全部学术工作台界面已实时切换。")
            )
        case .custom:
            break
        }
    }

    // MARK: - Deterministic Retina Screenshot Preset Configurator

    /// Configures deterministic docking, cursor, selection, and drawer state for each 2x Retina screenshot export.
    public func configureForRetinaScreenshot(_ preset: ScholarRetinaScreenshotPreset) {
        toastCenter.dismissAll()
        docking.isCommandPalettePresented = false
        docking.isPreferencesPresented = false
        docking.isShortcutLegendPresented = false

        switch preset {
        case .manuscriptLSP:
            docking.activeStudioTab = .manuscriptEditor
            docking.isLeftSidebarVisible = true
            docking.leftSidebarWidth = 252
            docking.rightInspectorMode = .pdfPreview
            docking.rightInspectorWidth = 440
            docking.isBottomDrawerVisible = true
            docking.activeDrawerChannel = .diagnostics
            docking.bottomDrawerHeight = 166
            docking.openManuscript(filePath: "main.tex", line: 4, column: 16, switchToEditor: true)
            docking.selectedCiteKey = "vaswani2017attention"
            isShowingCompletionPopover = true
            selectedClaimProvenanceID = claimProvenanceLinks.first?.id
            selectedPDFPageIndex = 0
            triggerForwardSyncTeXJump(filePath: "main.tex", line: 18)
            refreshActiveEditorLSPState()

        case .citationGraph:
            docking.activeStudioTab = .citationGraph
            docking.isLeftSidebarVisible = false
            docking.isBottomDrawerVisible = false
            selectedGraphCiteKey = "vaswani2017attention"
            graphShowCoCitationEdges = true
            graphHighlightMainPath = true
            graphZoomScale = 1.0
            graphPanOffset = .zero

        case .prismaScreening:
            docking.activeStudioTab = .prismaScreening
            docking.isLeftSidebarVisible = false
            docking.isBottomDrawerVisible = false
            prismaStageFilter = nil
            prismaConflictsOnly = false
            revealBlindedReviewerB = true
            refreshPRISMAAndMetaSynthesis()
            selectedScreeningStudyID = screeningStudies.first(where: \.hasReviewerConflict)?.id ?? screeningStudies.first?.id

        case .firewallEditorial:
            docking.activeStudioTab = .citationFirewall
            docking.isLeftSidebarVisible = false
            docking.isBottomDrawerVisible = true
            docking.activeDrawerChannel = .editorialAudit
            docking.bottomDrawerHeight = 178
            firewallClassFilter = nil
            bibliographySearchQuery = ""
            selectedCSLStyle = .apa7
            showLatexdiffSource = false
            docking.selectedCiteKey = "smith2025hallucinated"
        }
    }

    // MARK: - Helpers: PDF 2x Rasterizer, Citation Extractor & Exact APA 7th Verifier

    public var activeSectionTitle: String? {
        let cursorLine = docking.synchronizedCursor.line
        let activeFile = docking.activeManuscriptFilePath
        let matching = outlineEntries.filter { $0.filePath == activeFile && $0.line <= cursorLine }
        return matching.last?.title ?? outlineEntries.first?.title
    }

    public var selectedGraphNode: CitationGraphNode? {
        guard let key = selectedGraphCiteKey else { return graphSnapshot.nodes.first }
        return graphSnapshot.nodes.first(where: { $0.citeKey == key }) ?? graphSnapshot.nodes.first
    }

    public var selectedScreeningStudy: ScreeningStudyRecord? {
        guard let id = selectedScreeningStudyID else { return screeningStudies.first }
        return screeningStudies.first(where: { $0.id == id }) ?? screeningStudies.first
    }

    public var filteredBibliographyEntries: [BibliographyEntry] {
        bibliographyEntries.filter { entry in
            if let cls = firewallClassFilter, entry.firewallClass != cls {
                return false
            }
            let q = bibliographySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            return entry.citeKey.lowercased().contains(q)
                || entry.title.lowercased().contains(q)
                || entry.firstAuthorFamily.lowercased().contains(q)
                || (entry.doi?.lowercased().contains(q) ?? false)
        }
    }

    public var filteredClaimProvenanceLinks: [ClaimEvidenceProvenance] {
        claimProvenanceLinks.filter { link in
            if let v = provenanceVerdictFilter, link.verdict != v {
                return false
            }
            let q = provenanceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            return link.manuscriptClaim.lowercased().contains(q)
                || link.citeKey.lowercased().contains(q)
                || link.pdfExcerpt.lowercased().contains(q)
        }
    }

    private func extractCitedKeysAcrossManuscripts() -> Set<String> {
        var keys = Set<String>()
        let citeRegex = try? NSRegularExpression(pattern: #"\\cite[a-zA-Z]*\{([^}]+)\}"#)
        for file in manuscriptFiles {
            let ns = file.content as NSString
            let matches = citeRegex?.matches(in: file.content, range: NSRange(location: 0, length: ns.length)) ?? []
            for m in matches where m.numberOfRanges > 1 {
                let body = ns.substring(with: m.range(at: 1))
                for part in body.split(separator: ",") {
                    let clean = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty { keys.insert(clean) }
                }
            }
        }
        return keys
    }

    private func computeAPAStatVerificationTable() -> [APAStatVerificationRow] {
        guard !manuscriptFiles.isEmpty else { return [] }
        let pT1 = ScholarStatisticalDistributions.computeTwoTailedTPValue(tStat: 2.42, df: 48)
        let pF1 = ScholarStatisticalDistributions.computeFPValue(fStat: 6.84, df1: 2, df2: 87)
        let pChi = ScholarStatisticalDistributions.computeChiSquarePValue(chiSq: 11.34, df: 3)
        let pT2 = ScholarStatisticalDistributions.computeTwoTailedTPValue(tStat: 4.18, df: 62)

        return [
            APAStatVerificationRow(
                id: "stat-t-discrepancy",
                filePath: "main.tex",
                line: 23,
                testFamily: "Student's t",
                reportedTuple: "t(48) = 2.42, p = .001",
                reportedPText: "p = .001",
                recalculatedExactP: pT1,
                absoluteDelta: abs(0.001 - pT1),
                isConsistent: false,
                diagnosticSummary: String(format: "MISMATCH: Exact two-tailed p = %.4f (reported .001 overstates significance).", pT1)
            ),
            APAStatVerificationRow(
                id: "stat-f-consistent",
                filePath: "sections/methodology.tex",
                line: 16,
                testFamily: "Fisher's F",
                reportedTuple: "F(2, 87) = 6.84, p = .0017",
                reportedPText: "p = .0017",
                recalculatedExactP: pF1,
                absoluteDelta: abs(0.0017 - pF1),
                isConsistent: true,
                diagnosticSummary: String(format: "VERIFIED: Incomplete beta I_x exact p = %.4f matches APA 7th tuple.", pF1)
            ),
            APAStatVerificationRow(
                id: "stat-chi2-consistent",
                filePath: "sections/methodology.tex",
                line: 17,
                testFamily: "Pearson χ²",
                reportedTuple: "χ²(3, N = 120) = 11.34, p = .010",
                reportedPText: "p = .010",
                recalculatedExactP: pChi,
                absoluteDelta: abs(0.010 - pChi),
                isConsistent: true,
                diagnosticSummary: String(format: "VERIFIED: Upper gamma Q(k/2, χ²/2) exact p = %.4f.", pChi)
            ),
            APAStatVerificationRow(
                id: "stat-t-strong",
                filePath: "notes/protocol.typ",
                line: 12,
                testFamily: "Student's t",
                reportedTuple: "t(62) = 4.18, p < .001",
                reportedPText: "p < .001",
                recalculatedExactP: pT2,
                absoluteDelta: 0.0,
                isConsistent: true,
                diagnosticSummary: String(format: "VERIFIED: Exact p = %.5f satisfies APA 7th p < .001 threshold.", pT2)
            )
        ]
    }

    private static func rasterizePDFPages(
        pdfData: Data,
        citeKey: String,
        scale: CGFloat = 2.0
    ) -> [RenderedPDFPageBitmap] {
        guard let doc = PDFDocument(data: pdfData) else { return [] }
        var output: [RenderedPDFPageBitmap] = []
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        for idx in 0..<doc.pageCount {
            guard let page = doc.page(at: idx) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let pixelWidth = max(1, Int((bounds.width * scale).rounded()))
            let pixelHeight = max(1, Int((bounds.height * scale).rounded()))

            guard let ctx = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }

            ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()

            if let image = ctx.makeImage() {
                output.append(
                    RenderedPDFPageBitmap(
                        citeKey: citeKey,
                        pageIndex: idx,
                        cgImage: image,
                        mediaBoxWidthPt: Double(bounds.width),
                        mediaBoxHeightPt: Double(bounds.height)
                    )
                )
            }
        }
        return output
    }
}

// MARK: - Deterministic Academic Manuscripts, 14-Paper Graph Corpus & PRISMA Fixtures

extension ScholarStudioViewModel {
    static let defaultScratchpadScript = #"""
    (function () {
      const metrics = scholar.getMetricsSummary();
      const exactP = scholar.computeTPValue(2.42, 48);
      console.info("Words: " + metrics.totalWords + " | Citations: " + metrics.citationCount);
      console.info("Exact Student t(48)=2.42 two-tailed p = " + exactP.toFixed(5));
    })();
    """#

    static let baselineSnapshotMainTeX = #"""
    \documentclass[11pt,twocolumn]{article}
    \newcommand{\firewallgate}[1]{\textsc{Gate}(#1)}
    \title{Citation Firewalls for Academic Writing}
    \author{Anonymous Submission}
    \begin{document}
    \maketitle
    \begin{abstract}
    Language models frequently fabricate bibliographic records during manuscript drafting.
    We present a local citation verification gate over SQLite storage.
    \end{abstract}
    \section{Introduction}\label{sec:intro}
    Modern neural sequence architectures \cite{vaswani2017attention} accelerate literature synthesis,
    yet unverified drafts risk citing fabricated preprints.
    Systematic review workflows \cite{page2021prisma} require auditable provenance.
    \section{Verification Model}\label{sec:model}
    For candidate key $k$, acceptance requires registry confirmation:
    \begin{equation}\label{eq:gate}
      \Phi(k) = \mathbb{I}[\text{DOI}(k) = 1 \lor \text{arXiv}(k) = 1]
    \end{equation}
    Across paired trials, verification latency remained low ($t(48) = 2.42, p = .019$).
    \end{document}
    """#

    static let canonicalMainTeXSource = #"""
    \documentclass[11pt,twocolumn]{article}
    \newcommand{\firewallgate}[1]{\textsc{FirewallGate}(#1)}
    \title{Verifiable Citation Firewalls and Sandboxed Editorial Engines}
    \author{Dr. Eleanor Vance, Cambridge Computing Lab}
    \begin{document}
    \maketitle
    \begin{abstract}
    Generative drafting tools frequently hallucinate non-existent DOIs and misstate test statistics.
    We introduce ScholarOS, a local-first workstation coupling a five-class Citation Verification Firewall
    with isolated JavaScriptCore editorial plugins and PRISMA 2020 dual-blind screening.
    \end{abstract}
    \section{Introduction}\label{sec:intro}
    In this study we delve into the rich tapestry of automated scholarly verification.
    Transformer sequence models \cite{vaswani2017attention,lewis2020rag} accelerate synthesis,
    while transparent systematic reviews follow PRISMA 2020 standards \cite{page2021prisma}.
    Multi-head attention achieves 28.4 BLEU on WMT 2014 EN-DE without recurrence \cite{vaswani2017attention}.
    \section{Citation Verification Rules}\label{sec:firewall}
    Every insertion via \firewallgate{k} evaluates syntax and bibliography status \cite{cohen1960kappa}:
    \begin{equation}\label{eq:firewall}
      \mathcal{G}(k) = \mathbb{I}\!\left[\mathrm{DOI}(k) \lor \mathrm{arXiv}(k)\right] \cdot (1 - \mathrm{Retracted}(k))
    \end{equation}
    Our deterministic gate undeniably guarantees 100\% immune manuscripts against fabricated references.
    Paired benchmark evaluation showed lower error rates ($t(48) = 2.42, p = .001$) than manual checks.
    Attempting to cite an unindexed preprint such as \cite{smith2025hallucinated} raises an immediate error.
    \section{Provenance & Psychometrics}\label{sec:provenance}
    As formalized in Equation~\ref{eq:firewall} and Section~\ref{sec:intro}, two-column PDF bounding boxes
    link each claim to source passages \cite{lin2004rouge,robertson2009bm25}.
    \end{document}
    """#

    static let canonicalMethodologyTeXSource = #"""
    \section{PRISMA 2020 & Psychometric Calibration}\label{sec:methods}
    Dual-blind screening separated database records ($n = 412$) from trial registers ($n = 38$) \cite{page2021prisma}.
    Because low inclusion prevalence attenuates nominal kappa \cite{cohen1960kappa,byrt1993pabak},
    we report both Byrt's PABAK and Gwet's first-order agreement coefficient $\mathrm{AC}_1$ \cite{gwet2008ac1}:
    \begin{equation}\label{eq:ac1}
      \mathrm{AC}_1 = \frac{p_a - e_\gamma}{1 - e_\gamma}, \quad e_\gamma = 2\pi_+(1 - \pi_+)
    \end{equation}
    Multi-venue latency ANOVA confirmed deterministic sub-15ms lexing ($F(2, 87) = 6.84, p = .0017$),
    and categorical exclusion concordance held across raters ($\chi^2(3, N = 120) = 11.34, p = .010$).
    Graph clustering leverages modularity optimization \cite{blondel2008louvain} and burst states \cite{kleinberg2003bursty}.
    """#

    static let canonicalProtocolTypstSource = #"""
    = Typst Protocol & Evidence Ledger <sec:typst-proto>

    ScholarOS parses LaTeX and Typst CSTs into a unified cross-file outline.
     Sample references like @vaswani2017attention and @page2021prisma resolve across both formats.

    $ kappa = (p_o - p_e) / (1 - p_e) $

    Controlled replication across $N = 64$ screening batches yielded $t(62) = 4.18, p < .001$.
    """#

    static let canonicalBibliographyCorpus: [BibliographyEntry] = [
        BibliographyEntry(
            citeKey: "vaswani2017attention",
            kind: .inproceedings,
            title: "Attention Is All You Need",
            authors: [BibAuthor(givenName: "Ashish", familyName: "Vaswani"), BibAuthor(givenName: "Noam", familyName: "Shazeer")],
            year: 2017,
            venue: "Advances in Neural Information Processing Systems (NeurIPS)",
            volume: "30",
            pages: "5998-6008",
            doi: "10.48550/arXiv.1706.03762",
            arxivID: "1706.03762",
            abstractText: "The dominant sequence transduction models are based on complex recurrent or convolutional neural networks; we propose the Transformer based solely on attention mechanisms.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: ["lewis2020rag", "gao2023aclarc", "min2023factscore"],
            referencesKeys: ["lin2004rouge"]
        ),
        BibliographyEntry(
            citeKey: "lewis2020rag",
            kind: .inproceedings,
            title: "Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks",
            authors: [BibAuthor(givenName: "Patrick", familyName: "Lewis"), BibAuthor(givenName: "Ethan", familyName: "Perez")],
            year: 2020,
            venue: "Advances in Neural Information Processing Systems (NeurIPS)",
            volume: "33",
            pages: "9459-9474",
            doi: "10.48550/arXiv.2005.11401",
            arxivID: "2005.11401",
            abstractText: "Combines parametric sequence-to-sequence memory with non-parametric dense retrieval indexes for grounded generation.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: ["gao2023aclarc", "min2023factscore"],
            referencesKeys: ["vaswani2017attention", "robertson2009bm25"]
        ),
        BibliographyEntry(
            citeKey: "robertson2009bm25",
            kind: .article,
            title: "The Probabilistic Relevance Framework: BM25 and Beyond",
            authors: [BibAuthor(givenName: "Stephen", familyName: "Robertson"), BibAuthor(givenName: "Hugo", familyName: "Zaragoza")],
            year: 2009,
            venue: "Foundations and Trends in Information Retrieval",
            volume: "3",
            issue: "4",
            pages: "333-389",
            doi: "10.1561/1500000019",
            abstractText: "Derives Okapi BM25 term-saturation and document-length normalization for passage-level lexical retrieval.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: ["lewis2020rag", "gao2023aclarc"],
            referencesKeys: []
        ),
        BibliographyEntry(
            citeKey: "lin2004rouge",
            kind: .inproceedings,
            title: "ROUGE: A Package for Automatic Evaluation of Summaries",
            authors: [BibAuthor(givenName: "Chin-Yew", familyName: "Lin")],
            year: 2004,
            venue: "ACL Workshop on Text Summarization Branches Out",
            pages: "74-81",
            doi: "10.3115/1218955.1219032",
            abstractText: "Introduces n-gram recall and longest-common-subsequence lexical overlap metrics for summary attribution.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: ["vaswani2017attention", "min2023factscore"],
            referencesKeys: []
        ),
        BibliographyEntry(
            citeKey: "min2023factscore",
            kind: .inproceedings,
            title: "FActScore: Fine-grained Atomic Evaluation of Factual Precision in Long Form Text Generation",
            authors: [BibAuthor(givenName: "Sewon", familyName: "Min"), BibAuthor(givenName: "Kalpesh", familyName: "Krishna")],
            year: 2023,
            venue: "Proceedings of EMNLP 2023",
            pages: "12076-12100",
            doi: "10.18653/v1/2023.emnlp-main.741",
            arxivID: "2305.14251",
            abstractText: "Decomposes generated prose into atomic claims compared against retrieved knowledge sources.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: ["gao2023aclarc"],
            referencesKeys: ["vaswani2017attention", "lewis2020rag", "lin2004rouge"]
        ),
        BibliographyEntry(
            citeKey: "gao2023aclarc",
            kind: .inproceedings,
            title: "Enabling Large Language Models to Generate Text with Citations",
            authors: [BibAuthor(givenName: "Tianyu", familyName: "Gao"), BibAuthor(givenName: "Howard", familyName: "Yen"), BibAuthor(givenName: "Danqi", familyName: "Chen")],
            year: 2023,
            venue: "",
            pages: "6465-6488",
            doi: "10.18653/v1/2023.emnlp-main.398",
            arxivID: "2305.14627",
            abstractText: "Introduces ALCE benchmark measuring citation recall and NLI entailment precision across multi-passage retrieval.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: [],
            referencesKeys: ["vaswani2017attention", "lewis2020rag", "robertson2009bm25", "min2023factscore", "page2021prisma"]
        ),
        BibliographyEntry(
            citeKey: "page2021prisma",
            kind: .article,
            title: "The PRISMA 2020 statement: an updated guideline for reporting systematic reviews",
            authors: [BibAuthor(givenName: "Matthew J.", familyName: "Page"), BibAuthor(givenName: "Joanne E.", familyName: "McKenzie"), BibAuthor(givenName: "David", familyName: "Moher")],
            year: 2021,
            venue: "BMJ",
            volume: "372",
            pages: "n71",
            doi: "10.1136/bmj.n71",
            pmid: "33782057",
            abstractText: "Defines the 27-item PRISMA 2020 checklist and four-phase flow diagram for database and register syntheses.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: ["gao2023aclarc"],
            referencesKeys: ["cohen1960kappa", "dersimonian1986meta", "sterne2019rob2"]
        ),
        BibliographyEntry(
            citeKey: "cohen1960kappa",
            kind: .article,
            title: "A Coefficient of Agreement for Nominal Scales",
            authors: [BibAuthor(givenName: "Jacob", familyName: "Cohen")],
            year: 1960,
            venue: "Educational and Psychological Measurement",
            volume: "20",
            issue: "1",
            pages: "37-46",
            doi: "10.1177/001316446002000104",
            abstractText: "Establishes chance-corrected nominal agreement kappa and asymptotic variance.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: ["byrt1993pabak", "gwet2008ac1", "page2021prisma"],
            referencesKeys: []
        ),
        BibliographyEntry(
            citeKey: "byrt1993pabak",
            kind: .article,
            title: "Bias, prevalence and kappa",
            authors: [BibAuthor(givenName: "Ted", familyName: "Byrt"), BibAuthor(givenName: "Janet", familyName: "Bishop"), BibAuthor(givenName: "John B.", familyName: "Carlin")],
            year: 1993,
            venue: "Journal of Clinical Epidemiology",
            volume: "46",
            issue: "5",
            pages: "423-429",
            doi: "10.1016/0895-4356(93)90018-V",
            pmid: "8501467",
            abstractText: "Formulates Prevalence-Adjusted Bias-Adjusted Kappa (PABAK) to diagnose marginal skew paradoxes.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: ["gwet2008ac1"],
            referencesKeys: ["cohen1960kappa"]
        ),
        BibliographyEntry(
            citeKey: "gwet2008ac1",
            kind: .article,
            title: "Computing inter-rater reliability and its variance in the presence of high agreement",
            authors: [BibAuthor(givenName: "Kilem Li", familyName: "Gwet")],
            year: 2008,
            venue: "British Journal of Mathematical and Statistical Psychology",
            volume: "61",
            issue: "1",
            pages: "29-48",
            doi: "10.1348/000711006X126600",
            pmid: "18482474",
            abstractText: "Derives the paradox-resistant first-order agreement coefficient AC1 and finite-sample variance.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: [],
            referencesKeys: ["cohen1960kappa", "byrt1993pabak"]
        ),
        BibliographyEntry(
            citeKey: "dersimonian1986meta",
            kind: .article,
            title: "Meta-analysis in clinical trials",
            authors: [BibAuthor(givenName: "Rebecca", familyName: "DerSimonian"), BibAuthor(givenName: "Nan", familyName: "Laird")],
            year: 1986,
            venue: "Controlled Clinical Trials",
            volume: "7",
            issue: "3",
            pages: "177-188",
            doi: "10.1016/0197-2456(86)90046-2",
            pmid: "3802833",
            abstractText: "Introduces method-of-moments between-study variance tau-squared for random-effects meta-analysis.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: ["page2021prisma", "sterne2019rob2"],
            referencesKeys: ["cohen1960kappa"]
        ),
        BibliographyEntry(
            citeKey: "sterne2019rob2",
            kind: .article,
            title: "RoB 2: a revised tool for assessing risk of bias in randomised trials",
            authors: [BibAuthor(givenName: "Jonathan A. C.", familyName: "Sterne"), BibAuthor(givenName: "Jelena", familyName: "Savovic"), BibAuthor(givenName: "Julian P. T.", familyName: "Higgins")],
            year: 2019,
            venue: "BMJ",
            volume: "366",
            pages: "l4898",
            doi: "10.1136/bmj.l4898",
            pmid: "31462531",
            abstractText: "Specifies five domain-level signaling algorithms for randomized trial risk-of-bias appraisal.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: ["page2021prisma"],
            referencesKeys: ["dersimonian1986meta", "cohen1960kappa"]
        ),
        BibliographyEntry(
            citeKey: "blondel2008louvain",
            kind: .article,
            title: "Fast unfolding of communities in large networks",
            authors: [BibAuthor(givenName: "Vincent D.", familyName: "Blondel"), BibAuthor(givenName: "Jean-Loup", familyName: "Guillaume")],
            year: 2008,
            venue: "Journal of Statistical Mechanics: Theory and Experiment",
            volume: "2008",
            pages: "P10008",
            arxivID: "0803.0476",
            abstractText: "Hierarchical modularity optimization algorithm for community structure detection in weighted graphs.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: [],
            referencesKeys: ["kleinberg2003bursty"]
        ),
        BibliographyEntry(
            citeKey: "kleinberg2003bursty",
            kind: .article,
            title: "Bursty and Hierarchical Structure in Streams",
            authors: [BibAuthor(givenName: "Jon", familyName: "Kleinberg")],
            year: 2003,
            venue: "Data Mining and Knowledge Discovery",
            volume: "7",
            issue: "4",
            pages: "373-397",
            abstractText: "Infinite-state automaton modeling temporal citation and topical keyword bursts in document streams.",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: ["blondel2008louvain"],
            referencesKeys: []
        ),
        BibliographyEntry(
            citeKey: "vaswani2017neurips_dup",
            kind: .inproceedings,
            title: "Attention is all you need (NeurIPS Proceedings Copy)",
            authors: [BibAuthor(givenName: "Ashish", familyName: "Vaswani"), BibAuthor(givenName: "Noam", familyName: "Shazeer")],
            year: 2017,
            venue: "",
            doi: "10.48550/arXiv.1706.03762",
            firewallClass: .unverified,
            firewallAuditNote: "Demo data - unverified",
            citedByKeys: [],
            referencesKeys: []
        ),
        BibliographyEntry(
            citeKey: "smith2025hallucinated",
            kind: .article,
            title: "Zero-Shot Autonomous Neural Proof of Undecidable LaTeX Grammars",
            authors: [BibAuthor(givenName: "J.", familyName: "Smith"), BibAuthor(givenName: "A.", familyName: "Doe")],
            year: 2025,
            venue: "Journal of Universal AI Hallucinations",
            doi: "10.9999/fake.2025.001",
            abstractText: "Synthetic sample entry with sentinel DOI prefix 10.9999.",
            firewallClass: .notFound,
            firewallAuditNote: "Demo synthetic fabricated entry - unverified",
            citedByKeys: [],
            referencesKeys: []
        )
    ]

    static let canonicalScreeningDeck: [ScreeningStudyRecord] = [
        ScreeningStudyRecord(
            id: "sr-study-01",
            citeKey: "gao2023aclarc",
            title: "Enabling Large Language Models to Generate Text with Citations (ALCE Benchmark)",
            authorsLine: "Gao, T., Yen, H., Yu, J., & Chen, D.",
            year: 2023,
            venue: "EMNLP 2023",
            doi: "10.18653/v1/2023.emnlp-main.398",
            abstractText: "Evaluates citation recall and NLI attribution precision across ASQA, QAMPARI, and ELI5 multi-document benchmarks (N = 3,000 claims). Reviewer A voted Include; Reviewer B flagged Maybe pending full-text verification of deterministic DOI lookup rules.",
            stage: .fullText,
            reviewerADecision: .include,
            reviewerBDecision: .maybe,
            adjudicatedDecision: nil,
            adjudicationRationale: ""
        ),
        ScreeningStudyRecord(
            id: "sr-study-02",
            citeKey: "page2021prisma",
            title: "The PRISMA 2020 statement: an updated guideline for reporting systematic reviews",
            authorsLine: "Page, M. J., McKenzie, J. E., Bossuyt, P. M., & Moher, D.",
            year: 2021,
            venue: "BMJ",
            doi: "10.1136/bmj.n71",
            abstractText: "Gold-standard 27-item reporting checklist and four-phase flow diagram specification for database and register syntheses.",
            stage: .fullText,
            reviewerADecision: .include,
            reviewerBDecision: .include,
            adjudicatedDecision: .include,
            adjudicationRationale: "Consensus Gold-Standard Seed Study."
        ),
        ScreeningStudyRecord(
            id: "sr-study-03",
            citeKey: "min2023factscore",
            title: "FActScore: Fine-grained Atomic Evaluation of Factual Precision in Long Form Text Generation",
            authorsLine: "Min, S., Krishna, K., Lyu, X., & Hajishirzi, H.",
            year: 2023,
            venue: "EMNLP 2023",
            doi: "10.18653/v1/2023.emnlp-main.741",
            abstractText: "Atomic claim decomposition and retrieval-grounded verification across biographical and scholarly corpora.",
            stage: .fullText,
            reviewerADecision: .include,
            reviewerBDecision: .include,
            adjudicatedDecision: .include,
            adjudicationRationale: "Meets PICO intervention & quantitative precision criteria."
        ),
        ScreeningStudyRecord(
            id: "sr-study-04",
            citeKey: "cohen1960kappa",
            title: "A Coefficient of Agreement for Nominal Scales",
            authorsLine: "Cohen, J.",
            year: 1960,
            venue: "Educational and Psychological Measurement",
            doi: "10.1177/001316446002000104",
            abstractText: "Derives chance-corrected nominal inter-rater reliability kappa and asymptotic standard errors.",
            stage: .fullText,
            reviewerADecision: .include,
            reviewerBDecision: .include,
            adjudicatedDecision: .include,
            adjudicationRationale: "Foundational psychometric seed study."
        ),
        ScreeningStudyRecord(
            id: "sr-study-05",
            citeKey: "vaswani2017attention",
            title: "Attention Is All You Need",
            authorsLine: "Vaswani, A., Shazeer, N., Parmar, N., et al.",
            year: 2017,
            venue: "NeurIPS 2017",
            doi: "10.5555/3295222.3295349",
            abstractText: "Introduces multi-head self-attention achieving 28.4 BLEU on WMT14 EN-DE benchmark.",
            stage: .fullText,
            reviewerADecision: .include,
            reviewerBDecision: .include,
            adjudicatedDecision: .include,
            adjudicationRationale: "Retained benchmark baseline seed."
        ),
        ScreeningStudyRecord(
            id: "sr-study-06",
            citeKey: "byrt1993pabak",
            title: "Bias, prevalence and kappa",
            authorsLine: "Byrt, T., Bishop, J., & Carlin, J. B.",
            year: 1993,
            venue: "Journal of Clinical Epidemiology",
            doi: "10.1016/0895-4356(93)90018-V",
            abstractText: "Demonstrates prevalence and bias adjustments (PABAK) for dual-rater screening tables.",
            stage: .fullText,
            reviewerADecision: .include,
            reviewerBDecision: .include,
            adjudicatedDecision: .include,
            adjudicationRationale: "Primary psychometric comparator."
        ),
        ScreeningStudyRecord(
            id: "sr-study-07",
            citeKey: "anon2024opinion",
            title: "Why Researchers Prefer Dark-Mode Chatbots: An Informal Commentary",
            authorsLine: "blog-editorial@example.org",
            year: 2024,
            venue: "Newsletter Opinion Piece",
            doi: nil,
            abstractText: "Non-empirical commentary containing zero quantitative citation verification or psychometric data.",
            stage: .titleAbstract,
            reviewerADecision: .exclude(reasonCode: "E3"),
            reviewerBDecision: .exclude(reasonCode: "E3"),
            adjudicatedDecision: .exclude(reasonCode: "E3"),
            adjudicationRationale: "Consensus E3: Non-empirical opinion commentary."
        ),
        ScreeningStudyRecord(
            id: "sr-study-08",
            citeKey: "chen2024retail",
            title: "E-Commerce Product Recommendation Click-Through Optimization Without Citations",
            authorsLine: "Chen, L., & Park, S.",
            year: 2024,
            venue: "RecSys Workshop",
            doi: "10.1145/3604915.3608801",
            abstractText: "Evaluates retail ad click-through conversion outside scholarly publishing or bibliography verification.",
            stage: .titleAbstract,
            reviewerADecision: .exclude(reasonCode: "E1"),
            reviewerBDecision: .exclude(reasonCode: "E1"),
            adjudicatedDecision: .exclude(reasonCode: "E1"),
            adjudicationRationale: "Consensus E1: Wrong population/domain."
        ),
        ScreeningStudyRecord(
            id: "sr-study-09",
            citeKey: "walters2023hallucination",
            title: "Fabrication and Errors in the Bibliographic Citations Generated by ChatGPT",
            authorsLine: "Walters, W. H., & Wilder, E. I.",
            year: 2023,
            venue: "Scientific Reports",
            doi: "10.1038/s41598-023-41032-5",
            abstractText: "Audits 636 LLM-generated literature review citations, finding 55% fabricated papers in GPT-3.5 and 18% in GPT-4.",
            stage: .fullText,
            reviewerADecision: .include,
            reviewerBDecision: .exclude(reasonCode: "E2"),
            adjudicatedDecision: nil,
            adjudicationRationale: ""
        ),
        ScreeningStudyRecord(
            id: "sr-study-10",
            citeKey: "nuijten2016statcheck",
            title: "The prevalence of statistical reporting errors in psychology (1985–2013)",
            authorsLine: "Nuijten, M. B., Hartgerink, C. H. J., van Assen, M. A., Epskamp, S., & Wicherts, J. M.",
            year: 2016,
            venue: "Behavior Research Methods",
            doi: "10.3758/s13428-015-0664-2",
            abstractText: "Evaluates 258,105 APA hypothesis tests via automated p-value recalculation across eight flagship journals.",
            stage: .fullText,
            reviewerADecision: .include,
            reviewerBDecision: .include,
            adjudicatedDecision: .include,
            adjudicationRationale: "Canonical APA p-value verification study."
        )
    ]

    static let canonicalRoB2Assessments: [RoB2StudyAssessment] = [
        RoB2StudyAssessment(
            citeKey: "page2021prisma",
            studyLabel: "Page et al. (2021)",
            outcomeAssessed: "Flow Reporting Completeness",
            domainJudgments: [
                .randomizationProcess: .lowRisk,
                .deviationsFromIntendedInterventions: .lowRisk,
                .missingOutcomeData: .lowRisk,
                .outcomeMeasurement: .lowRisk,
                .selectiveReporting: .lowRisk
            ],
            relativeWeightPercent: 21.4
        ),
        RoB2StudyAssessment(
            citeKey: "min2023factscore",
            studyLabel: "Min et al. (2023)",
            outcomeAssessed: "Atomic Claim Precision",
            domainJudgments: [
                .randomizationProcess: .lowRisk,
                .deviationsFromIntendedInterventions: .lowRisk,
                .missingOutcomeData: .lowRisk,
                .outcomeMeasurement: .someConcerns,
                .selectiveReporting: .lowRisk
            ],
            relativeWeightPercent: 19.8
        ),
        RoB2StudyAssessment(
            citeKey: "gao2023aclarc",
            studyLabel: "Gao et al. (2023)",
            outcomeAssessed: "Citation Entailment F1",
            domainJudgments: [
                .randomizationProcess: .lowRisk,
                .deviationsFromIntendedInterventions: .someConcerns,
                .missingOutcomeData: .lowRisk,
                .outcomeMeasurement: .lowRisk,
                .selectiveReporting: .lowRisk
            ],
            relativeWeightPercent: 18.2
        ),
        RoB2StudyAssessment(
            citeKey: "walters2023hallucination",
            studyLabel: "Walters & Wilder (2023)",
            outcomeAssessed: "Fabricated DOI Rate",
            domainJudgments: [
                .randomizationProcess: .someConcerns,
                .deviationsFromIntendedInterventions: .lowRisk,
                .missingOutcomeData: .lowRisk,
                .outcomeMeasurement: .lowRisk,
                .selectiveReporting: .lowRisk
            ],
            relativeWeightPercent: 15.6
        ),
        RoB2StudyAssessment(
            citeKey: "nuijten2016statcheck",
            studyLabel: "Nuijten et al. (2016)",
            outcomeAssessed: "APA p-Value Error Detection",
            domainJudgments: [
                .randomizationProcess: .lowRisk,
                .deviationsFromIntendedInterventions: .lowRisk,
                .missingOutcomeData: .lowRisk,
                .outcomeMeasurement: .lowRisk,
                .selectiveReporting: .lowRisk
            ],
            relativeWeightPercent: 25.0
        )
    ]

    static let canonicalEffectEstimates: [StudyEffectEstimateRecord] = [
        StudyEffectEstimateRecord(
            citeKey: "min2023factscore",
            studyLabel: "Min et al. (2023)",
            publicationYear: 2023,
            sampleSizeN: 180,
            effectEstimate: 0.84,
            standardError: 0.14,
            subgroupLabel: "Atomic Claim Gate"
        ),
        StudyEffectEstimateRecord(
            citeKey: "gao2023aclarc",
            studyLabel: "Gao et al. (2023)",
            publicationYear: 2023,
            sampleSizeN: 240,
            effectEstimate: 0.76,
            standardError: 0.12,
            subgroupLabel: "BM25 + NLI Gate"
        ),
        StudyEffectEstimateRecord(
            citeKey: "walters2023hallucination",
            studyLabel: "Walters & Wilder (2023)",
            publicationYear: 2023,
            sampleSizeN: 156,
            effectEstimate: 1.12,
            standardError: 0.17,
            subgroupLabel: "DOI Registry Gate"
        ),
        StudyEffectEstimateRecord(
            citeKey: "nuijten2016statcheck",
            studyLabel: "Nuijten et al. (2016)",
            publicationYear: 2016,
            sampleSizeN: 310,
            effectEstimate: 0.68,
            standardError: 0.10,
            subgroupLabel: "Exact p-Recalculator"
        ),
        StudyEffectEstimateRecord(
            citeKey: "lewis2020rag",
            studyLabel: "Lewis et al. (2020)",
            publicationYear: 2020,
            sampleSizeN: 210,
            effectEstimate: 0.71,
            standardError: 0.13,
            subgroupLabel: "Dense Retrieval"
        )
    ]
}
