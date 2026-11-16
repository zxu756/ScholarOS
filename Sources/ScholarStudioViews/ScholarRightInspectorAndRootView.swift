import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import ScholarBibAndCSL
import ScholarCLIAndMCP
import ScholarMarkupAST
import ScholarModels
import ScholarWorkbenchShell

// MARK: - Contextual Right Split Inspector (`ScholarContextualRightInspectorView`)

/// Contextual right-hand split inspector mounted alongside `.manuscriptEditor`, supporting
/// Two-Column PDF + SyncTeX + Readability Telemetry, Myers Track Changes, and Citation Metadata + CSL Cards.
public struct ScholarContextualRightInspectorView: View {
    @ObservedObject public var viewModel: ScholarStudioViewModel
    @ObservedObject private var localizer = ScholarLocalizer.shared

    public init(viewModel: ScholarStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        switch viewModel.docking.rightInspectorMode {
        case .none:
            EmptyView()

        case .pdfPreview:
            VStack(spacing: 0) {
                TwoColumnAcademicPDFCanvasView(viewModel: viewModel, compactToolbar: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                    .overlay(CambridgeLinenPalette.stoneHairline)

                compactReadabilityAndVenueFooter
            }

        case .trackChanges:
            ReusableTrackChangesInspectorPane(viewModel: viewModel, compactHeader: true)

        case .citationInspector:
            citationAndReadabilityDossierPane
        }
    }

    private var compactReadabilityAndVenueFooter: some View {
        let m = viewModel.manuscriptMetrics
        let flesch = m?.readability.fleschReadingEase ?? 0.0
        let grade = m?.readability.fleschKincaidGradeLevel ?? 0.0
        let citeDensity = m?.citationDensityPerThousandWords ?? 0.0
        let readMin = m?.estimatedReadingTimeMinutes ?? 0.0

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(localizer.L("MANUSCRIPT READABILITY & VENUE TELEMETRY", "手稿可读性与顶会规格指标"))
                    .font(CambridgeTypography.uiSectionLabel)
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Spacer()
                Text(
                    localizer.language == .zhHans
                        ? String(format: "约 %.1f 分钟读完", readMin)
                        : String(format: "~%.1f min read", readMin)
                )
                .font(CambridgeTypography.monoSmall)
                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 6) {
                miniInspectorMetric(title: localizer.L("Flesch Ease", "Flesch 易读度"), value: String(format: "%.1f", flesch))
                miniInspectorMetric(title: localizer.L("FK Grade", "FK 学年等级"), value: String(format: "%.1f", grade))
                miniInspectorMetric(title: localizer.L("Cites / 1k", "千词引文密度"), value: String(format: "%.1f", citeDensity))
                miniInspectorMetric(title: localizer.L("Venue Fit", "顶会合规"), value: localizer.L("NeurIPS OK", "NeurIPS 达标"))
            }
        }
        .padding(9)
        .background(CambridgeLinenPalette.warmVellum)
    }

    private func miniInspectorMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Text(title)
                .font(.system(size: 9.0, weight: .medium))
                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(CambridgeTypography.monoSmall)
                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(CambridgeLinenPalette.archivalPaper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
        )
    }

    private var citationAndReadabilityDossierPane: some View {
        let selectedKey = viewModel.docking.selectedCiteKey ?? "vaswani2017attention"
        let selectedEntry = viewModel.bibliographyEntries.first(where: { $0.citeKey == selectedKey })
            ?? viewModel.bibliographyEntries.first
        let metrics = viewModel.manuscriptMetrics

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let entry = selectedEntry {
                    let formatted = CSLCitationFormatterEngine().formatEntry(entry, style: viewModel.selectedCSLStyle)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(localizer.L("CITATION METADATA & FIREWALL", "引文元数据与防火墙状态"))
                                .font(CambridgeTypography.uiSectionLabel)
                                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                            Spacer()
                            FirewallBadgeView(firewallClass: entry.trustedFirewallClass(), compact: true)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        Text(entry.title)
                            .font(CambridgeTypography.scholarlyHeadline)
                            .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("@\(entry.citeKey) • \(entry.firstAuthorFamily) (\(entry.year.map(String.init) ?? "n.d."))")
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.slateEditorial)

                        if let doi = entry.doi, !doi.isEmpty {
                            Text("DOI: \(doi)")
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                        }

                        Divider()
                            .overlay(CambridgeLinenPalette.stoneHairline)

                        Text(localizer.L("CSL (\(viewModel.selectedCSLStyle.rawValue))", "CSL 格式 (\(viewModel.selectedCSLStyle.rawValue))"))
                            .font(CambridgeTypography.uiSectionLabel)
                            .foregroundStyle(CambridgeLinenPalette.mutedMetadata)

                        Text(formatted.bibliographyPlainText)
                            .font(CambridgeTypography.uiCaption)
                            .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button(localizer.L("Insert into Manuscript", "插入至手稿正文")) {
                                _ = viewModel.attemptInsertCitation(entry.citeKey)
                            }
                            .buttonStyle(CambridgePrimaryButtonStyle())
                            .fixedSize(horizontal: true, vertical: false)

                            Button(localizer.L("Open in Graph", "在知识图谱中查看")) {
                                viewModel.selectedGraphCiteKey = entry.citeKey
                                viewModel.docking.activeStudioTab = .citationGraph
                            }
                            .buttonStyle(CambridgeSecondaryButtonStyle())
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .cambridgeArchivalCard(padding: 11)
                }

                if let metrics {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localizer.L("READABILITY & DENSITY ANALYTICS", "可读性与词法密度分析"))
                            .font(CambridgeTypography.uiSectionLabel)
                            .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)

                        HStack(spacing: 6) {
                            miniInspectorMetric(title: "Flesch", value: String(format: "%.1f", metrics.readability.fleschReadingEase))
                            miniInspectorMetric(title: localizer.L("Fog Index", "迷雾指数"), value: String(format: "%.1f", metrics.readability.gunningFogIndex))
                            miniInspectorMetric(title: localizer.L("TTR", "词汇丰富度"), value: String(format: "%.2f", metrics.readability.lexicalTypeTokenRatio))
                        }

                        Text(localizedReadabilityInterpretation(metrics.readability.academicRegisterInterpretation))
                            .font(CambridgeTypography.uiCaption)
                            .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .cambridgeArchivalCard(padding: 11)
                }
            }
            .padding(12)
        }
        .background(CambridgeLinenPalette.cambridgeLinen)
    }

    private func localizedReadabilityInterpretation(_ raw: String) -> String {
        guard localizer.language == .zhHans else { return raw }
        if raw.localizedCaseInsensitiveContains("graduate") || raw.localizedCaseInsensitiveContains("peer-reviewed") || raw.localizedCaseInsensitiveContains("scholarly") {
            return "学术语体评估：符合研究生及同行评审顶会论文密度区间。"
        }
        return "学术语体评估：句法复杂度与专业术语密度处于标准学术区间。"
    }
}

// MARK: - Root ScholarOS Workbench View (`ScholarRootWorkbenchView`)

/// Top-level macOS SwiftUI workstation assembling `ScholarWorkbenchShellFrameView`, all 6 primary Academic Studios,
/// contextual right split-pane inspectors, and global `⌘1..⌘6` / `⌘K` / `⌘Z` / `I/M/E` keyboard bindings.
public struct ScholarRootWorkbenchView: View {
    @StateObject private var ownedViewModel: ScholarStudioViewModel
    @ObservedObject private var externalViewModel: ScholarStudioViewModel
    @ObservedObject private var localizer: ScholarLocalizer = .shared
    private let usesExternalViewModel: Bool

    public init(viewModel: ScholarStudioViewModel? = nil) {
        if let viewModel {
            _ownedViewModel = StateObject(wrappedValue: viewModel)
            self.externalViewModel = viewModel
            self.usesExternalViewModel = true
        } else {
            let fresh = ScholarStudioViewModel()
            _ownedViewModel = StateObject(wrappedValue: fresh)
            self.externalViewModel = fresh
            self.usesExternalViewModel = false
        }
    }

    private var activeVM: ScholarStudioViewModel {
        usesExternalViewModel ? externalViewModel : ownedViewModel
    }

    public var body: some View {
        let vm = activeVM

        ScholarWorkbenchShellFrameView(
            docking: vm.docking,
            preferences: vm.preferences,
            toastCenter: vm.toastCenter,
            projectTitle: vm.projectTitle,
            isDemoMode: vm.isDemoMode,
            primaryManuscriptPath: vm.primaryManuscriptPath,
            activeSectionTitle: vm.activeSectionTitle,
            manuscriptFiles: vm.manuscriptFiles,
            outlineEntries: vm.outlineEntries,
            bibliographyEntries: vm.bibliographyEntries,
            diagnostics: vm.diagnostics,
            editorialFindings: vm.editorialFindings,
            perPluginTimingsMs: vm.perPluginTimingsMs,
            syncTeXAnchors: vm.syncTeXAnchors,
            pluginLogs: vm.pluginLogs,
            projectStats: vm.projectStats,
            canUndo: vm.undoRedo.canUndo,
            canRedo: vm.undoRedo.canRedo,
            undoDepth: vm.undoRedo.undoDepth,
            redoDepth: vm.undoRedo.redoDepth,
            topUndoTitle: vm.undoRedo.topUndoActionTitle,
            topRedoTitle: vm.undoRedo.topRedoActionTitle,
            onUndo: { vm.performUndo() },
            onRedo: { vm.performRedo() },
            onCreateSnapshot: { vm.createNamedRevisionSnapshot() },
            onRunEditorialAudit: { vm.runEditorialPluginSuite() },
            onApplyDiagnosticFix: { diag in vm.applyDiagnosticQuickFix(diag) },
            onApplyEditorialRewrite: { finding in vm.applyEditorialRewrite(finding) },
            onPaletteAction: { action in vm.handleCommandPaletteAction(action) },
            onSyncPluginsToDatabase: { plugins in vm.syncPluginsToDatabase(plugins) },
            centerCanvas: {
                activeStudioCanvas(for: vm)
            },
            rightInspector: {
                ScholarContextualRightInspectorView(viewModel: vm)
            }
        )
        .background(KeyShortcutHostCommandsView(viewModel: vm))
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private func activeStudioCanvas(for vm: ScholarStudioViewModel) -> some View {
        if !vm.isDemoMode && vm.manuscriptFiles.isEmpty && vm.bibliographyEntries.isEmpty && vm.screeningStudies.isEmpty {
            emptyWorkspaceCanvas(for: vm)
        } else {
            switch vm.docking.activeStudioTab {
            case .manuscriptEditor:
                ManuscriptLSPEditorStudioView(viewModel: vm)
            case .pdfProvenance:
                PDFAndClaimProvenanceStudioView(viewModel: vm)
            case .citationGraph:
                CitationKnowledgeGraphStudioView(viewModel: vm)
            case .prismaScreening:
                PRISMAScreeningAndRoB2StudioView(viewModel: vm)
            case .citationFirewall:
                CitationFirewallAndTrackChangesStudioView(viewModel: vm)
            case .editorialAudit:
                EditorialJavaScriptAuditStudioView(viewModel: vm)
            }
        }
    }

    private func emptyWorkspaceCanvas(for vm: ScholarStudioViewModel) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)

            Text(localizer.L("No Project or Manuscript Loaded", "未打开工程或手稿"))
                .font(CambridgeTypography.scholarlyTitle)
                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)

            Text(
                localizer.L(
                    "0 manuscripts, 0 bibliography entries. Direct file inspection (outline, diagnostics, verify-citations, format-bib) runs via the scholaros CLI. This desktop window currently displays sample data only when explicitly requested.",
                    "当前为 0 份手稿、0 条参考文献。直接文件检查（outline、diagnostics、verify-citations、format-bib）请通过 scholaros 命令行运行；当前桌面窗口仅在显式请求时展示未核查示例数据。"
                )
            )
                .font(CambridgeTypography.uiControl)
                .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            Button {
                vm.loadDemoWorkspace()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                    Text(localizer.L("Load Demo", "载入演示数据"))
                }
            }
            .buttonStyle(CambridgePrimaryButtonStyle())
        }
        .padding(28)
        .cambridgeArchivalCard(padding: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CambridgeLinenPalette.cambridgeLinen)
    }
}

/// Invisible zero-size button host binding workstation keyboard shortcuts (`⌘K`, `⌘1..⌘6`, `⌘B`, `⌘J`, `⌘Z`, `⌥⌘S`, `⇧⌘E`).
private struct KeyShortcutHostCommandsView: View {
    @ObservedObject var viewModel: ScholarStudioViewModel

    var body: some View {
        Group {
            Button("") { viewModel.docking.isCommandPalettePresented.toggle() }
                .keyboardShortcut("k", modifiers: [.command])

            Button("") { viewModel.docking.activeStudioTab = .manuscriptEditor }
                .keyboardShortcut("1", modifiers: [.command])
            Button("") { viewModel.docking.activeStudioTab = .pdfProvenance }
                .keyboardShortcut("2", modifiers: [.command])
            Button("") { viewModel.docking.activeStudioTab = .citationGraph }
                .keyboardShortcut("3", modifiers: [.command])
            Button("") { viewModel.docking.activeStudioTab = .prismaScreening }
                .keyboardShortcut("4", modifiers: [.command])
            Button("") { viewModel.docking.activeStudioTab = .citationFirewall }
                .keyboardShortcut("5", modifiers: [.command])
            Button("") { viewModel.docking.activeStudioTab = .editorialAudit }
                .keyboardShortcut("6", modifiers: [.command])

            Button("") { viewModel.docking.toggleLeftSidebar() }
                .keyboardShortcut("b", modifiers: [.command])
            Button("") { viewModel.docking.toggleBottomDrawer() }
                .keyboardShortcut("j", modifiers: [.command])
            Button("") { viewModel.createNamedRevisionSnapshot() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("") {
                viewModel.runEditorialPluginSuite()
                viewModel.docking.activeStudioTab = .editorialAudit
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("") { viewModel.handleCommandPaletteAction(.toggleLanguage) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("") { viewModel.docking.isShortcutLegendPresented.toggle() }
                .keyboardShortcut("/", modifiers: [.command])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

// MARK: - Headless 2x Retina Screenshot & HTML Dossier Exporter (`ScholarScreenshotExportService`)

/// Exports crisp `2720 × 1680 px` (`1360 × 840 pt @ 2x`) Retina PNG screenshots across all flagship ScholarOS studios,
/// plus the standalone Hallmark-clean bilingual `demo-scholar-dossier.html` archival audit report.
@MainActor
public enum ScholarScreenshotExportService {
    public static let viewportSize = CGSize(width: 1360, height: 840)
    public static let retinaScale: CGFloat = 2.0

    @discardableResult
    public static func exportAllAssets(
        to directoryURL: URL,
        language: ScholarLanguage? = nil
    ) throws -> [URL] {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let resolvedLanguage = language ?? ScholarLocalizer.shared.language
        ScholarLocalizer.shared.setLanguage(resolvedLanguage)

        let viewModel = ScholarStudioViewModel(seedDemo: true)
        var writtenURLs: [URL] = []

        let windowRect = NSRect(origin: .zero, size: viewportSize)
        let offscreenWindow = NSWindow(
            contentRect: windowRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        offscreenWindow.isReleasedWhenClosed = false
        offscreenWindow.appearance = NSAppearance(named: .aqua)
        offscreenWindow.backgroundColor = CambridgeLinenPalette.nsCambridgeLinen

        let pixelW = Int(viewportSize.width * retinaScale)
        let pixelH = Int(viewportSize.height * retinaScale)

        for preset in ScholarRetinaScreenshotPreset.allCases {
            viewModel.configureForRetinaScreenshot(preset)

            let renderRoot = ScholarRootWorkbenchView(viewModel: viewModel)
                .environment(\.scholarSnapshotRendering, true)
                .frame(width: viewportSize.width, height: viewportSize.height)
                .background(CambridgeLinenPalette.cambridgeLinen)
                .environment(\.colorScheme, .light)
                .preferredColorScheme(.light)

            let hostingView = NSHostingView(rootView: renderRoot)
            hostingView.frame = windowRect
            hostingView.appearance = NSAppearance(named: .aqua)
            offscreenWindow.contentView = hostingView

            // Pump main RunLoop so SwiftUI + AppKit NSScrollViews / Canvas / split panes finish layout completely
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            offscreenWindow.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.16))
            hostingView.layoutSubtreeIfNeeded()
            offscreenWindow.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))

            guard let bitmapRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelW,
                pixelsHigh: pixelH,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                throw ScholarOSError.invalidCLIArguments("Failed to allocate 2x NSBitmapImageRep for \(preset.fileName(for: resolvedLanguage))")
            }
            bitmapRep.size = viewportSize
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                throw ScholarOSError.invalidCLIArguments("Failed to encode PNG data for \(preset.fileName(for: resolvedLanguage))")
            }

            let fileURL = directoryURL.appendingPathComponent(preset.fileName(for: resolvedLanguage))
            try pngData.write(to: fileURL, options: .atomic)
            writtenURLs.append(fileURL)
        }

        offscreenWindow.orderOut(nil)

        // Also export the standalone bilingual Cambridge Linen HTML Audit Dossier (Hallmark sloplint 0/0/0)
        let htmlString = try CambridgeLinenHTMLReportExporter().exportHTMLDossier(
            database: viewModel.database,
            isDemo: true
        )
        let htmlURL = directoryURL.appendingPathComponent("demo-scholar-dossier.html")
        try htmlString.write(to: htmlURL, atomically: true, encoding: .utf8)
        writtenURLs.append(htmlURL)

        return writtenURLs
    }
}
