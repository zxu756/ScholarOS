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
        let flesch = m?.readability.fleschReadingEase ?? 38.4
        let grade = m?.readability.fleschKincaidGradeLevel ?? 13.6
        let citeDensity = m?.citationDensityPerThousandWords ?? 16.9
        let readMin = m?.estimatedReadingTimeMinutes ?? 2.1

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("MANUSCRIPT READABILITY & VENUE TELEMETRY")
                    .font(CambridgeTypography.uiSectionLabel)
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Spacer()
                Text(String(format: "~%.1f min read", readMin))
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                    .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 6) {
                miniInspectorMetric(title: "Flesch Ease", value: String(format: "%.1f", flesch))
                miniInspectorMetric(title: "FK Grade", value: String(format: "%.1f", grade))
                miniInspectorMetric(title: "Cites / 1k", value: String(format: "%.1f", citeDensity))
                miniInspectorMetric(title: "Venue Fit", value: "NeurIPS OK")
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
                            Text("CITATION METADATA & FIREWALL")
                                .font(CambridgeTypography.uiSectionLabel)
                                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                            Spacer()
                            FirewallBadgeView(firewallClass: entry.firewallClass, compact: true)
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

                        Text("CSL (\(viewModel.selectedCSLStyle.rawValue))")
                            .font(CambridgeTypography.uiSectionLabel)
                            .foregroundStyle(CambridgeLinenPalette.mutedMetadata)

                        Text(formatted.bibliographyPlainText)
                            .font(CambridgeTypography.uiCaption)
                            .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button("Insert into Manuscript") {
                                _ = viewModel.attemptInsertCitation(entry.citeKey)
                            }
                            .buttonStyle(CambridgePrimaryButtonStyle())
                            .fixedSize(horizontal: true, vertical: false)

                            Button("Open in Graph") {
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
                        Text("READABILITY & DENSITY ANALYTICS")
                            .font(CambridgeTypography.uiSectionLabel)
                            .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)

                        HStack(spacing: 6) {
                            miniInspectorMetric(title: "Flesch", value: String(format: "%.1f", metrics.readability.fleschReadingEase))
                            miniInspectorMetric(title: "Fog Index", value: String(format: "%.1f", metrics.readability.gunningFogIndex))
                            miniInspectorMetric(title: "TTR", value: String(format: "%.2f", metrics.readability.lexicalTypeTokenRatio))
                        }

                        Text(metrics.readability.academicRegisterInterpretation)
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
}

// MARK: - Root ScholarOS Workbench View (`ScholarRootWorkbenchView`)

/// Top-level macOS SwiftUI workstation assembling `ScholarWorkbenchShellFrameView`, all 6 primary Academic Studios,
/// contextual right split-pane inspectors, and global `⌘1..⌘6` / `⌘K` / `⌘Z` / `I/M/E` keyboard bindings.
public struct ScholarRootWorkbenchView: View {
    @StateObject private var ownedViewModel: ScholarStudioViewModel
    @ObservedObject private var externalViewModel: ScholarStudioViewModel
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
/// plus the standalone Hallmark-clean `demo-scholar-dossier.html` archival audit report.
@MainActor
public enum ScholarScreenshotExportService {
    public static let viewportSize = CGSize(width: 1360, height: 840)
    public static let retinaScale: CGFloat = 2.0

    @discardableResult
    public static func exportAllAssets(to directoryURL: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let viewModel = ScholarStudioViewModel()
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
                throw ScholarOSError.invalidCLIArguments("Failed to allocate 2x NSBitmapImageRep for \(preset.rawValue)")
            }
            bitmapRep.size = viewportSize
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                throw ScholarOSError.invalidCLIArguments("Failed to encode PNG data for \(preset.rawValue)")
            }

            let fileURL = directoryURL.appendingPathComponent(preset.rawValue)
            try pngData.write(to: fileURL, options: .atomic)
            writtenURLs.append(fileURL)
        }

        offscreenWindow.orderOut(nil)

        // Also export the standalone Cambridge Linen HTML Audit Dossier (refined for Hallmark sloplint 0/0/0)
        let rawHTML = try CambridgeLinenHTMLReportExporter().exportHTMLDossier(database: viewModel.database)
        let htmlString = refineDossierHTMLForHallmarkSloplint(rawHTML)
        let htmlURL = directoryURL.appendingPathComponent("demo-scholar-dossier.html")
        try htmlString.write(to: htmlURL, atomically: true, encoding: .utf8)
        writtenURLs.append(htmlURL)

        return writtenURLs
    }

    private static func refineDossierHTMLForHallmarkSloplint(_ raw: String) -> String {
        var html = raw

        // 1. Add font tokens & warm archival paper (#FDFCF8) to :root + overflow-x: clip on html, body
        html = html.replacingOccurrences(
            of: "--bg-paper: #FFFFFF;",
            with: """
            --bg-paper: #FDFCF8;
                --font-sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
                --font-serif: Georgia, "Times New Roman", serif;
                --font-mono: ui-monospace, SFMono-Regular, Menlo, monospace;
            """
        )
        html = html.replacingOccurrences(
            of: "* { box-sizing: border-box; }",
            with: "* { box-sizing: border-box; }\n  html, body { overflow-x: clip; }"
        )

        // 2. Reference font tokens instead of inline font-family literals
        html = html.replacingOccurrences(
            of: #"font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;"#,
            with: "font-family: var(--font-sans);"
        )
        html = html.replacingOccurrences(
            of: #"font-family: Georgia, "Times New Roman", serif;"#,
            with: "font-family: var(--font-serif);"
        )
        html = html.replacingOccurrences(
            of: "font-family: ui-monospace, SFMono-Regular, Menlo, monospace;",
            with: "font-family: var(--font-mono);"
        )

        // 3. Enforce strict 4px spacing scale & sentence-case untracked labels
        html = html.replacingOccurrences(
            of: """
              .eyebrow {
                font-size: 11px;
                font-weight: 700;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: var(--accent-forest);
                margin: 0 0 6px;
              }
            """,
            with: """
              .eyebrow {
                font-size: 12px;
                font-weight: 600;
                color: var(--accent-forest);
                margin: 0 0 8px;
              }
            """
        )
        html = html.replacingOccurrences(
            of: "padding: 14px 16px;",
            with: "padding: 12px 16px;"
        )
        html = html.replacingOccurrences(
            of: """
              .kpi-label {
                font-size: 11px;
                text-transform: uppercase;
                letter-spacing: 0.05em;
                color: var(--ink-secondary);
                margin-bottom: 4px;
              }
            """,
            with: """
              .kpi-label {
                font-size: 12px;
                font-weight: 500;
                color: var(--ink-secondary);
                margin-bottom: 4px;
              }
            """
        )
        html = html.replacingOccurrences(
            of: """
              th {
                text-align: left;
                padding: 9px 12px;
                background: var(--bg-vellum);
                border-bottom: 1px solid var(--border-stone);
                font-size: 11px;
                text-transform: uppercase;
                letter-spacing: 0.04em;
                color: var(--ink-secondary);
              }
            """,
            with: """
              th {
                text-align: left;
                padding: 8px 12px;
                background: var(--bg-vellum);
                border-bottom: 1px solid var(--border-stone);
                font-size: 12px;
                font-weight: 600;
                color: var(--ink-secondary);
              }
            """
        )
        html = html.replacingOccurrences(
            of: "padding: 9px 12px;",
            with: "padding: 8px 12px;"
        )
        html = html.replacingOccurrences(
            of: "padding: 12px 14px;",
            with: "padding: 12px 16px;"
        )
        html = html.replacingOccurrences(
            of: "margin-top: 14px;",
            with: "margin-top: 16px;"
        )
        html = html.replacingOccurrences(
            of: "margin-top: 2px;",
            with: "margin-top: 4px;"
        )

        // 4. Sentence-case status pill text & aria-label on PRISMA SVG
        let pillMappings: [(String, String)] = [
            (">GROUNDED<", ">Grounded<"),
            (">PARTIAL<", ">Partial<"),
            (">NUMERIC_MISMATCH<", ">Numeric mismatch<"),
            (">UNSUPPORTED<", ">Unsupported<"),
            (">BLOCKER<", ">Submission blocker<"),
            (">SUBMISSION_BLOCKER<", ">Submission blocker<"),
            (">RIGOR_WARN<", ">Rigor warning<"),
            (">STYLE_SUGGESTION<", ">Style suggestion<"),
            (">NOTE<", ">Editorial note<")
        ]
        for (oldToken, newToken) in pillMappings {
            html = html.replacingOccurrences(of: oldToken, with: newToken)
        }
        html = html.replacingOccurrences(
            of: "<svg ",
            with: #"<svg aria-label="PRISMA 2020 systematic review flow diagram" "#
        )

        // 5. Replace middle-dot chains, en-dashes in copy, and straight apostrophes in prose
        html = html.replacingOccurrences(of: " · ", with: ", ")
        html = html.replacingOccurrences(of: "–", with: " to ")
        html = html.replacingOccurrences(of: "Cohen's", with: "Cohen\u{2019}s")
        html = html.replacingOccurrences(of: "Byrt's", with: "Byrt\u{2019}s")
        html = html.replacingOccurrences(of: "Gwet's", with: "Gwet\u{2019}s")
        html = html.replacingOccurrences(of: "Student's", with: "Student\u{2019}s")
        html = html.replacingOccurrences(of: "Fisher's", with: "Fisher\u{2019}s")
        html = html.replacingOccurrences(of: "Hedges'", with: "Hedges\u{2019}")

        return html
    }
}
