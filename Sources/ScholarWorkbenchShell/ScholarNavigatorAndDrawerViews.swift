import Foundation
import SwiftUI
import ScholarModels
import ScholarProjectStore
import ScholarPluginSDK

// MARK: - Top Breadcrumb, Studio Switcher & Undo/Redo/Snapshot Toolbar (`ScholarTopWorkbenchToolbarView`)

/// Primary top chrome bar framing studio switching, breadcrumb location, undo/redo journal controls,
/// snapshot creation, split-pane toggles, and `⌘K` / `⌘,` triggers in Cambridge Linen & Library Forest Green.
public struct ScholarTopWorkbenchToolbarView: View {
    @ObservedObject public var docking: ScholarDockingController
    public let projectTitle: String
    public let activeSectionTitle: String?
    public let canUndo: Bool
    public let canRedo: Bool
    public let undoDepth: Int
    public let redoDepth: Int
    public let topUndoTitle: String?
    public let topRedoTitle: String?
    public let onUndo: () -> Void
    public let onRedo: () -> Void
    public let onCreateSnapshot: () -> Void

    public init(
        docking: ScholarDockingController,
        projectTitle: String,
        activeSectionTitle: String? = nil,
        canUndo: Bool = false,
        canRedo: Bool = false,
        undoDepth: Int = 0,
        redoDepth: Int = 0,
        topUndoTitle: String? = nil,
        topRedoTitle: String? = nil,
        onUndo: @escaping () -> Void = {},
        onRedo: @escaping () -> Void = {},
        onCreateSnapshot: @escaping () -> Void = {}
    ) {
        self.docking = docking
        self.projectTitle = projectTitle
        self.activeSectionTitle = activeSectionTitle
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.undoDepth = undoDepth
        self.redoDepth = redoDepth
        self.topUndoTitle = topUndoTitle
        self.topRedoTitle = topRedoTitle
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onCreateSnapshot = onCreateSnapshot
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Row 1: Studio Pill Switcher + Command Palette + Undo/Redo/Snapshot + Preferences
            HStack(spacing: 10) {
                Button {
                    docking.toggleLeftSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(
                            docking.isLeftSidebarVisible
                                ? CambridgeLinenPalette.libraryForestGreen
                                : CambridgeLinenPalette.slateEditorial
                        )
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                                .fill(docking.isLeftSidebarVisible ? CambridgeLinenPalette.libraryForestTint : CambridgeLinenPalette.archivalPaper)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                                .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                        )
                }
                .buttonStyle(.plain)
                .help("Toggle Left Project & Outline Sidebar (⌘B)")

                studioTabStrip

                Spacer(minLength: 8)

                commandPaletteTriggerButton

                undoRedoSnapshotCluster

                preferencesAndShortcutsCluster
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(CambridgeLinenPalette.warmVellum)

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            // Row 2: Project -> File -> Section Breadcrumb + Cursor Coordinates + Right Split-Pane Selector
            HStack(spacing: 8) {
                breadcrumbTrail

                Spacer(minLength: 8)

                if docking.activeStudioTab == .manuscriptEditor {
                    rightInspectorSplitPicker
                }

                Button {
                    docking.toggleBottomDrawer()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "menubar.dock.rectangle")
                            .font(.system(size: 11, weight: .semibold))
                        Text(docking.activeDrawerChannel.rawValue)
                            .font(CambridgeTypography.uiSectionLabel)
                    }
                    .foregroundStyle(
                        docking.isBottomDrawerVisible
                            ? CambridgeLinenPalette.libraryForestGreen
                            : CambridgeLinenPalette.slateEditorial
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .fill(docking.isBottomDrawerVisible ? CambridgeLinenPalette.libraryForestTint : CambridgeLinenPalette.archivalPaper)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .help("Toggle 4-Channel Bottom Drawer (⌘J)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(CambridgeLinenPalette.cambridgeLinen)

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)
        }
    }

    private var studioTabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(ScholarStudioTab.allCases) { tab in
                    let isActive = (docking.activeStudioTab == tab)
                    Button {
                        docking.activeStudioTab = tab
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: CambridgeLinenPalette.resolvedSymbolName(for: tab.sfSymbolName))
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(tab.rawValue)
                                .font(isActive ? CambridgeTypography.uiControlSemibold : CambridgeTypography.uiControlMedium)
                        }
                        .foregroundStyle(isActive ? CambridgeLinenPalette.archivalPaper : CambridgeLinenPalette.oxfordCharcoal)
                        .padding(.horizontal, 9.5)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                                .fill(isActive ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.archivalPaper)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                                .strokeBorder(
                                    isActive ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.stoneHairline,
                                    lineWidth: CambridgeMetrics.hairline
                                )
                        )
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var commandPaletteTriggerButton: some View {
        Button {
            docking.isCommandPalettePresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Text("Jump / Cite")
                    .font(CambridgeTypography.uiControlMedium)
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                ScholarKeycapBadge("⌘K")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                    .fill(CambridgeLinenPalette.archivalPaper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                    .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .help("Open Subsequence Fuzzy Command, Section & Citation Palette (⌘K)")
    }

    private var undoRedoSnapshotCluster: some View {
        HStack(spacing: 4) {
            Button(action: onUndo) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11.5, weight: .semibold))
                    if undoDepth > 0 {
                        Text("\(undoDepth)")
                            .font(CambridgeTypography.monoSmall)
                    }
                }
                .foregroundStyle(canUndo ? CambridgeLinenPalette.oxfordCharcoal : CambridgeLinenPalette.mutedMetadata.opacity(0.55))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                        .fill(CambridgeLinenPalette.archivalPaper)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                        .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .disabled(!canUndo)
            .help(canUndo ? "Undo \(topUndoTitle ?? "Last Action") (⌘Z)" : "Undo Stack Empty")

            Button(action: onRedo) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 11.5, weight: .semibold))
                    if redoDepth > 0 {
                        Text("\(redoDepth)")
                            .font(CambridgeTypography.monoSmall)
                    }
                }
                .foregroundStyle(canRedo ? CambridgeLinenPalette.oxfordCharcoal : CambridgeLinenPalette.mutedMetadata.opacity(0.55))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                        .fill(CambridgeLinenPalette.archivalPaper)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                        .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .disabled(!canRedo)
            .help(canRedo ? "Redo \(topRedoTitle ?? "Next Action") (⇧⌘Z)" : "Redo Stack Empty")

            Button(action: onCreateSnapshot) {
                HStack(spacing: 4) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("Snapshot")
                        .font(CambridgeTypography.uiControlMedium)
                }
            }
            .buttonStyle(CambridgeSecondaryButtonStyle())
            .help("Save Named Manuscript Revision Snapshot (⌥⌘S)")
        }
    }

    private var preferencesAndShortcutsCluster: some View {
        HStack(spacing: 4) {
            Button {
                docking.isShortcutLegendPresented = true
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .fill(CambridgeLinenPalette.archivalPaper)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                    )
            }
            .buttonStyle(.plain)
            .help("Keyboard Shortcut Legend (⌘/)")

            Button {
                docking.isPreferencesPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .fill(CambridgeLinenPalette.archivalPaper)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                    )
            }
            .buttonStyle(.plain)
            .help("ScholarOS Preferences (⌘,)")
        }
    }

    private var breadcrumbTrail: some View {
        HStack(spacing: 6) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)

            Text(shortenedProjectTitle)
                .font(.system(size: 12.5, weight: .semibold, design: .serif))
                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)

            Text(docking.synchronizedCursor.filePath)
                .font(CambridgeTypography.monoSmall)
                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                .fixedSize(horizontal: true, vertical: false)

            if let section = activeSectionTitle, !section.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                Text(section)
                    .font(CambridgeTypography.uiCaption)
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
            }

            Text(docking.synchronizedCursor.lineColumnLabel)
                .font(CambridgeTypography.monoSmall)
                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(CambridgeLinenPalette.warmVellum)
                )
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var shortenedProjectTitle: String {
        if projectTitle.count <= 48 { return projectTitle }
        return String(projectTitle.prefix(46)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private var rightInspectorSplitPicker: some View {
        HStack(spacing: 4) {
            ForEach(ScholarRightInspectorMode.allCases) { mode in
                let isSelected = (docking.rightInspectorMode == mode)
                Button {
                    docking.rightInspectorMode = mode
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.sfSymbolName)
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(mode.shortLabel)
                            .font(CambridgeTypography.uiSectionLabel)
                    }
                    .foregroundStyle(isSelected ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.slateEditorial)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .fill(isSelected ? CambridgeLinenPalette.libraryForestTint : CambridgeLinenPalette.archivalPaper)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .strokeBorder(
                                isSelected ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.stoneHairline,
                                lineWidth: CambridgeMetrics.hairline
                            )
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Open Manuscript Tab Strip (`ScholarOpenManuscriptTabStripView`)

/// Multi-file document tab bar above the manuscript editor well.
public struct ScholarOpenManuscriptTabStripView: View {
    @ObservedObject public var docking: ScholarDockingController

    public init(docking: ScholarDockingController) {
        self.docking = docking
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(docking.openManuscriptTabs) { tab in
                    let isActive = (docking.activeManuscriptFilePath == tab.filePath)
                    HStack(spacing: 6) {
                        Button {
                            docking.openManuscript(
                                filePath: tab.filePath,
                                line: tab.lastCursorLine,
                                column: tab.lastCursorColumn
                            )
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: tab.isPinned ? "pin.fill" : "doc.text")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(isActive ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.mutedMetadata)
                                Text(tab.filePath)
                                    .font(isActive ? CambridgeTypography.uiControlSemibold : CambridgeTypography.uiControl)
                                    .foregroundStyle(isActive ? CambridgeLinenPalette.oxfordCharcoal : CambridgeLinenPalette.slateEditorial)
                                if tab.isDirty {
                                    Circle()
                                        .fill(CambridgeLinenPalette.driftAmber)
                                        .frame(width: 6, height: 6)
                                }
                                if tab.wordCount > 0 {
                                    Text("\(tab.wordCount)w")
                                        .font(CambridgeTypography.monoSmall)
                                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)

                        if !tab.isPinned && docking.openManuscriptTabs.count > 1 {
                            Button {
                                docking.closeManuscriptTab(tab.filePath)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .fill(isActive ? CambridgeLinenPalette.archivalPaper : CambridgeLinenPalette.warmVellum)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .strokeBorder(
                                isActive ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.stoneHairline,
                                lineWidth: CambridgeMetrics.hairline
                            )
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(CambridgeLinenPalette.cambridgeLinen)
    }
}

// MARK: - Left Archival Project & Numbered Section Outline Sidebar (`ScholarLeftNavigatorSidebarView`)

/// Warm Vellum `#F1EEE6` left navigator displaying manuscript files, word counts, numbered outline tree,
/// and quick Citation Firewall + PRISMA Cohen's $\kappa$ integrity summary cards.
public struct ScholarLeftNavigatorSidebarView: View {
    @ObservedObject public var docking: ScholarDockingController
    public let manuscriptFiles: [ManuscriptFileRecord]
    public let primaryManuscriptPath: String
    public let outlineEntries: [DocumentOutlineEntry]
    public let projectStats: ScholarProjectStats?

    public init(
        docking: ScholarDockingController,
        manuscriptFiles: [ManuscriptFileRecord],
        primaryManuscriptPath: String = "main.tex",
        outlineEntries: [DocumentOutlineEntry],
        projectStats: ScholarProjectStats? = nil
    ) {
        self.docking = docking
        self.manuscriptFiles = manuscriptFiles
        self.primaryManuscriptPath = primaryManuscriptPath
        self.outlineEntries = outlineEntries
        self.projectStats = projectStats
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        manuscriptFilesSection
                        numberedOutlineSection
                    }
                    .padding(12)
                }

                Divider()
                    .overlay(CambridgeLinenPalette.stoneHairline)

                integrityHealthFooterCards
                    .padding(10)
                    .background(CambridgeLinenPalette.cambridgeLinen)
            }
            .frame(width: docking.leftSidebarWidth)
            .background(CambridgeLinenPalette.warmVellum)

            // Crisp 1pt Stone Hairline divider with subtle drag resize target
            Rectangle()
                .fill(CambridgeLinenPalette.stoneHairline)
                .frame(width: CambridgeMetrics.hairline)
                .contentShape(Rectangle().inset(by: -3))
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            docking.resizeLeftSidebar(to: docking.leftSidebarWidth + value.translation.width)
                        }
                )
        }
    }

    private var manuscriptFilesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("MANUSCRIPT FILES")
                    .font(CambridgeTypography.uiSectionLabel)
                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                Spacer()
                Text("\(manuscriptFiles.count)")
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
            }

            ForEach(manuscriptFiles) { file in
                let isSelected = (docking.activeManuscriptFilePath == file.path && docking.activeStudioTab == .manuscriptEditor)
                Button {
                    docking.openManuscript(filePath: file.path, wordCount: file.wordCount, switchToEditor: true)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: file.path == primaryManuscriptPath ? "star.square.fill" : "doc.text")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                isSelected || file.path == primaryManuscriptPath
                                    ? CambridgeLinenPalette.libraryForestGreen
                                    : CambridgeLinenPalette.slateEditorial
                            )

                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.path)
                                .font(isSelected ? CambridgeTypography.uiControlSemibold : CambridgeTypography.uiControl)
                                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                            Text(file.format.rawValue)
                                .font(CambridgeTypography.uiCaption)
                                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                        }

                        Spacer(minLength: 4)

                        Text("\(file.wordCount)w")
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(isSelected ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.slateEditorial)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .fill(isSelected ? CambridgeLinenPalette.archivalPaper : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .strokeBorder(
                                isSelected ? CambridgeLinenPalette.stoneHairline : Color.clear,
                                lineWidth: CambridgeMetrics.hairline
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var numberedOutlineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SECTION OUTLINE")
                    .font(CambridgeTypography.uiSectionLabel)
                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                Spacer()
                Text("\(outlineEntries.count)")
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
            }

            if outlineEntries.isEmpty {
                Text("No \\section or Typst headings parsed yet.")
                    .font(CambridgeTypography.uiCaption)
                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                    .padding(.vertical, 6)
            } else {
                ForEach(outlineEntries) { entry in
                    let isCurrent = (docking.selectedOutlineEntryID == entry.id)
                    let indent = CGFloat(max(0, entry.level - 1)) * 12.0
                    Button {
                        docking.navigateToOutlineEntry(entry)
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.numberPrefix.isEmpty ? "•" : entry.numberPrefix)
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                                .fixedSize(horizontal: true, vertical: false)

                            VStack(alignment: .leading, spacing: 1.5) {
                                Text(entry.title)
                                    .font(entry.level == 1 ? CambridgeTypography.uiControlSemibold : CambridgeTypography.uiControl)
                                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                    .multilineTextAlignment(.leading)

                                if let lbl = entry.label, !lbl.isEmpty {
                                    Text("#\(lbl)")
                                        .font(CambridgeTypography.monoSmall)
                                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                }
                            }

                            Spacer(minLength: 4)

                            if entry.wordCountInSection > 0 {
                                Text("\(entry.wordCountInSection)w")
                                    .font(CambridgeTypography.monoSmall)
                                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .padding(.leading, 6 + indent)
                        .padding(.trailing, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                                .fill(isCurrent ? CambridgeLinenPalette.libraryForestTint : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var integrityHealthFooterCards: some View {
        let verifiedCount = projectStats?.verifiedCitationCount ?? 0
        let blockedCount = projectStats?.blockedCitationCount ?? 0
        let totalBib = projectStats?.bibliographyCount ?? 0
        let kappa = projectStats?.cohensKappa ?? 0.0
        let prismaCount = projectStats?.prismaStudyCount ?? 0
        let editorialCount = projectStats?.editorialFindingCount ?? 0

        VStack(spacing: 8) {
            // Card 1: 5-Class Citation Verification Firewall Summary
            Button {
                docking.activeStudioTab = .citationFirewall
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(blockedCount > 0 ? CambridgeLinenPalette.blockedCrimson : CambridgeLinenPalette.verifiedEmerald)
                        Text("Citation Firewall")
                            .font(CambridgeTypography.uiControlSemibold)
                            .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                        Spacer()
                        Text("\(verifiedCount)/\(totalBib) OK")
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.verifiedEmerald)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    HStack(spacing: 8) {
                        if blockedCount > 0 {
                            Text("\(blockedCount) Blocked")
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.blockedCrimson)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(CambridgeLinenPalette.blockedCrimsonBg)
                                )
                                .fixedSize(horizontal: true, vertical: false)
                        } else {
                            Text("Zero Hallucinations")
                                .font(CambridgeTypography.uiCaption)
                                .foregroundStyle(CambridgeLinenPalette.verifiedEmerald)
                        }
                        Spacer()
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                        .fill(CambridgeLinenPalette.archivalPaper)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                        .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                )
            }
            .buttonStyle(.plain)

            // Card 2: PRISMA 2020 Cohen's κ & Editorial Plugins Health
            Button {
                docking.activeStudioTab = .prismaScreening
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PRISMA κ & Audit")
                            .font(CambridgeTypography.uiSectionLabel)
                            .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                        Text(String(format: "κ = %.2f • %d studies", kappa, prismaCount))
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer()
                    if editorialCount > 0 {
                        Text("\(editorialCount) flags")
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.driftAmber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(CambridgeLinenPalette.driftAmberBg)
                            )
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                        .fill(CambridgeLinenPalette.archivalPaper)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                        .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 4-Channel Resizable Bottom Drawer (`ScholarBottomDrawerView`)

/// Resizable 4-channel bottom inspection drawer (`Diagnostics`, `Citation Firewall`, `Editorial Audit`, `Build & SyncTeX`).
public struct ScholarBottomDrawerView: View {
    @ObservedObject public var docking: ScholarDockingController
    public let diagnostics: [LSPDiagnostic]
    public let bibliographyEntries: [BibliographyEntry]
    public let editorialFindings: [EditorialAuditFinding]
    public let perPluginTimingsMs: [String: Double]
    public let syncTeXAnchors: [SyncTeXAnchor]
    public let pluginLogs: [PluginConsoleLogEntry]
    public let onApplyDiagnosticFix: (LSPDiagnostic) -> Void
    public let onApplyEditorialRewrite: (EditorialAuditFinding) -> Void
    public let onRunEditorialAudit: () -> Void

    @State private var minimumDiagnosticSeverity: LSPDiagnosticSeverity? = nil
    @State private var firewallFilterOnlyIssues: Bool = false
    @State private var minimumEditorialSeverity: EditorialSeverity? = nil

    public init(
        docking: ScholarDockingController,
        diagnostics: [LSPDiagnostic] = [],
        bibliographyEntries: [BibliographyEntry] = [],
        editorialFindings: [EditorialAuditFinding] = [],
        perPluginTimingsMs: [String: Double] = [:],
        syncTeXAnchors: [SyncTeXAnchor] = [],
        pluginLogs: [PluginConsoleLogEntry] = [],
        onApplyDiagnosticFix: @escaping (LSPDiagnostic) -> Void = { _ in },
        onApplyEditorialRewrite: @escaping (EditorialAuditFinding) -> Void = { _ in },
        onRunEditorialAudit: @escaping () -> Void = {}
    ) {
        self.docking = docking
        self.diagnostics = diagnostics
        self.bibliographyEntries = bibliographyEntries
        self.editorialFindings = editorialFindings
        self.perPluginTimingsMs = perPluginTimingsMs
        self.syncTeXAnchors = syncTeXAnchors
        self.pluginLogs = pluginLogs
        self.onApplyDiagnosticFix = onApplyDiagnosticFix
        self.onApplyEditorialRewrite = onApplyEditorialRewrite
        self.onRunEditorialAudit = onRunEditorialAudit
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Drag-resizable Stone Hairline top handle
            ZStack {
                Rectangle()
                    .fill(CambridgeLinenPalette.stoneHairline)
                    .frame(height: CambridgeMetrics.hairline)
                Capsule()
                    .fill(CambridgeLinenPalette.deepStoneBorder)
                    .frame(width: 36, height: 3)
            }
            .frame(height: 6)
            .background(CambridgeLinenPalette.warmVellum)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        docking.resizeBottomDrawer(to: docking.bottomDrawerHeight - value.translation.height)
                    }
            )

            drawerHeaderBar

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            Group {
                switch docking.activeDrawerChannel {
                case .diagnostics:
                    diagnosticsChannelContent
                case .citationFirewall:
                    citationFirewallChannelContent
                case .editorialAudit:
                    editorialAuditChannelContent
                case .syncTeXLog:
                    syncTeXAndLogsChannelContent
                }
            }
            .frame(height: docking.bottomDrawerHeight)
            .background(CambridgeLinenPalette.archivalPaper)
        }
    }

    private var drawerHeaderBar: some View {
        HStack(spacing: 8) {
            ForEach(ScholarBottomDrawerChannel.allCases) { channel in
                let isSelected = (docking.activeDrawerChannel == channel)
                let badgeCount = countForChannel(channel)
                Button {
                    docking.activeDrawerChannel = channel
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: CambridgeLinenPalette.resolvedSymbolName(for: channel.sfSymbolName))
                            .font(.system(size: 11, weight: .semibold))
                        Text(channel.rawValue)
                            .font(isSelected ? CambridgeTypography.uiControlSemibold : CambridgeTypography.uiControlMedium)
                        Text("\(badgeCount)")
                            .font(CambridgeTypography.monoSmall)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(isSelected ? CambridgeLinenPalette.archivalPaper.opacity(0.22) : CambridgeLinenPalette.warmVellum)
                            )
                    }
                    .foregroundStyle(isSelected ? CambridgeLinenPalette.archivalPaper : CambridgeLinenPalette.oxfordCharcoal)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .fill(isSelected ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.archivalPaper)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .strokeBorder(
                                isSelected ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.stoneHairline,
                                lineWidth: CambridgeMetrics.hairline
                            )
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 8)

            channelContextControls

            Button {
                docking.isBottomDrawerVisible = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                    .padding(5)
            }
            .buttonStyle(.plain)
            .help("Collapse Bottom Drawer")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(CambridgeLinenPalette.warmVellum)
    }

    @ViewBuilder
    private var channelContextControls: some View {
        switch docking.activeDrawerChannel {
        case .diagnostics:
            HStack(spacing: 4) {
                Button("All") { minimumDiagnosticSeverity = nil }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: minimumDiagnosticSeverity == nil))
                Button("Warnings+") { minimumDiagnosticSeverity = .warning }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: minimumDiagnosticSeverity == .warning))
                Button("Errors") { minimumDiagnosticSeverity = .error }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: minimumDiagnosticSeverity == .error))
            }
        case .citationFirewall:
            Button(firewallFilterOnlyIssues ? "Showing Blocked/Drift" : "Filter Issues Only") {
                firewallFilterOnlyIssues.toggle()
            }
            .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: firewallFilterOnlyIssues))
        case .editorialAudit:
            HStack(spacing: 6) {
                Button("All") { minimumEditorialSeverity = nil }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: minimumEditorialSeverity == nil))
                Button("Blockers") { minimumEditorialSeverity = .submissionBlocker }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: minimumEditorialSeverity == .submissionBlocker))
                Button {
                    onRunEditorialAudit()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("Run JS Plugins")
                    }
                }
                .buttonStyle(CambridgePrimaryButtonStyle())
            }
        case .syncTeXLog:
            Text("\(syncTeXAnchors.count) SyncTeX anchors • \(pluginLogs.count) JS logs")
                .font(CambridgeTypography.monoSmall)
                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func countForChannel(_ channel: ScholarBottomDrawerChannel) -> Int {
        switch channel {
        case .diagnostics:
            return diagnostics.count
        case .citationFirewall:
            return bibliographyEntries.filter { !$0.firewallClass.allowsManuscriptInsertion || $0.firewallClass == .metadataDriftAdvisory }.count
        case .editorialAudit:
            return editorialFindings.count
        case .syncTeXLog:
            return syncTeXAnchors.count + pluginLogs.count
        }
    }

    // MARK: Channel 1 — LSP Diagnostics

    private var diagnosticsChannelContent: some View {
        let filtered = diagnostics.filter { diag in
            guard let minSev = minimumDiagnosticSeverity else { return true }
            return diag.severity >= minSev
        }
        return ScrollView {
            if filtered.isEmpty {
                emptyDrawerPlaceholder(
                    symbol: "checkmark.seal",
                    title: "Zero Markup or Macro Diagnostics",
                    detail: "Incremental LaTeX/Typst CST parser and cycle-safe macro symbol table reported clean syntax."
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filtered) { diag in
                        HStack(alignment: .top, spacing: 10) {
                            LSPDiagnosticSeverityBadge(severity: diag.severity)

                            Text("[\(diag.code)]")
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                                .fixedSize(horizontal: true, vertical: false)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(diag.message)
                                    .font(CambridgeTypography.uiControl)
                                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                Text("\(diag.span.filePath):\(diag.span.start.line):\(diag.span.start.column)")
                                    .font(CambridgeTypography.monoSmall)
                                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                            }

                            Spacer(minLength: 8)

                            if diag.suggestedFix != nil {
                                Button("Apply Quick Fix") {
                                    onApplyDiagnosticFix(diag)
                                }
                                .buttonStyle(CambridgeSecondaryButtonStyle())
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                                .fill(CambridgeLinenPalette.cambridgeLinen)
                        )
                        .onTapGesture {
                            docking.navigateToDiagnostic(diag)
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    // MARK: Channel 2 — Citation Verification Firewall

    private var citationFirewallChannelContent: some View {
        let filtered = bibliographyEntries.filter { entry in
            if !firewallFilterOnlyIssues { return true }
            return entry.firewallClass != .verifiedCanonicalDOI && entry.firewallClass != .verifiedPreprintRegistry
        }
        return ScrollView {
            if filtered.isEmpty {
                emptyDrawerPlaceholder(
                    symbol: "lock.shield",
                    title: "All Cited Entries Verified",
                    detail: "No blocked, hallucinated, retracted, or drifted bibliography keys match the current filter."
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filtered) { entry in
                        HStack(alignment: .center, spacing: 10) {
                            FirewallBadgeView(firewallClass: entry.firewallClass, compact: true)

                            Text("@\(entry.citeKey)")
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                                .fixedSize(horizontal: true, vertical: false)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(CambridgeTypography.uiControlMedium)
                                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                Text(entry.firewallAuditNote.isEmpty ? "\(entry.firstAuthorFamily) (\(entry.year.map(String.init) ?? "n.d."))" : entry.firewallAuditNote)
                                    .font(CambridgeTypography.uiCaption)
                                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                            }

                            Spacer(minLength: 8)

                            if let doi = entry.doi, !doi.isEmpty {
                                Text("DOI:\(doi)")
                                    .font(CambridgeTypography.monoSmall)
                                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                    .fixedSize(horizontal: true, vertical: false)
                            }

                            Button("Inspect") {
                                docking.focusCitation(entry.citeKey, openRightInspector: true)
                            }
                            .buttonStyle(CambridgeSecondaryButtonStyle())
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                                .fill(CambridgeLinenPalette.cambridgeLinen)
                        )
                    }
                }
                .padding(10)
            }
        }
    }

    // MARK: Channel 3 — Editorial JS Plugin Audit

    private var editorialAuditChannelContent: some View {
        let filtered = editorialFindings.filter { finding in
            guard let minSev = minimumEditorialSeverity else { return true }
            return finding.severity >= minSev
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !perPluginTimingsMs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(perPluginTimingsMs.keys.sorted(), id: \.self) { pluginID in
                                let ms = perPluginTimingsMs[pluginID] ?? 0.0
                                Text(String(format: "%@ • %.2fms", pluginID, ms))
                                    .font(CambridgeTypography.monoSmall)
                                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(CambridgeLinenPalette.warmVellum)
                                    )
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                }

                if filtered.isEmpty {
                    emptyDrawerPlaceholder(
                        symbol: "highlighter",
                        title: "Manuscript Passed Editorial & Statistical Rigor Checks",
                        detail: "No overclaiming rhetoric, AI prose tropes, APA 7th p-value discrepancies, or venue leaks matched."
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filtered) { finding in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    EditorialSeverityPill(severity: finding.severity, compact: true)
                                    Text(finding.category)
                                        .font(CambridgeTypography.uiControlSemibold)
                                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                    Text("\(finding.filePath):\(finding.line)")
                                        .font(CambridgeTypography.monoSmall)
                                        .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Spacer()
                                    Text(finding.pluginName)
                                        .font(CambridgeTypography.uiCaption)
                                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                }

                                Text(finding.explanation)
                                    .font(CambridgeTypography.uiControl)
                                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)

                                HStack(spacing: 8) {
                                    Text(finding.matchedExcerpt)
                                        .font(CambridgeTypography.monoCode)
                                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                        .padding(6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .fill(CambridgeLinenPalette.parchmentWell)
                                        )

                                    Spacer(minLength: 6)

                                    if let rewrite = finding.suggestedRewrite, !rewrite.isEmpty {
                                        Button("Apply Scholarly Rewrite") {
                                            onApplyEditorialRewrite(finding)
                                        }
                                        .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: true))
                                    }
                                }
                            }
                            .padding(9)
                            .background(
                                RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                                    .fill(CambridgeLinenPalette.cambridgeLinen)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                                    .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                            )
                            .onTapGesture {
                                docking.navigateToEditorialFinding(finding)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    // MARK: Channel 4 — Build & SyncTeX Anchors + JS Sandbox Ring Buffer Logs

    private var syncTeXAndLogsChannelContent: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("BIDIRECTIONAL SYNCTEX ANCHORS")
                        .font(CambridgeTypography.uiSectionLabel)
                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)

                    if syncTeXAnchors.isEmpty {
                        Text("Compile or preview manuscript to populate deterministic source-to-PDF anchors.")
                            .font(CambridgeTypography.uiCaption)
                            .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                            .padding(.top, 4)
                    } else {
                        ForEach(syncTeXAnchors) { anchor in
                            Button {
                                docking.navigateToSyncTeXAnchor(anchor)
                            } label: {
                                HStack {
                                    Text("\(anchor.sourceFile):\(anchor.line)")
                                        .font(CambridgeTypography.monoSmall)
                                        .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                                    Image(systemName: "arrow.left.and.right")
                                        .font(.system(size: 10))
                                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                    Text(String(format: "Page %d (%.0f, %.0f pt)", anchor.pdfPageIndex + 1, anchor.xPt, anchor.yPt))
                                        .font(CambridgeTypography.monoSmall)
                                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                    Spacer()
                                }
                                .padding(6)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(CambridgeLinenPalette.cambridgeLinen)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity)

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Text("JAVASCRIPTCORE SANDBOX RING BUFFER")
                        .font(CambridgeTypography.uiSectionLabel)
                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)

                    if pluginLogs.isEmpty {
                        Text("Run JS Editorial Plugins to inspect deterministic console ring telemetry.")
                            .font(CambridgeTypography.uiCaption)
                            .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                            .padding(.top, 4)
                    } else {
                        ForEach(pluginLogs) { entry in
                            Text(entry.formattedLine)
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(
                                    entry.level == .error
                                        ? CambridgeLinenPalette.blockedCrimson
                                        : (entry.level == .warn ? CambridgeLinenPalette.driftAmber : CambridgeLinenPalette.oxfordCharcoal)
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func emptyDrawerPlaceholder(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: CambridgeLinenPalette.resolvedSymbolName(for: symbol))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(CambridgeLinenPalette.verifiedEmerald)
            Text(title)
                .font(CambridgeTypography.uiControlSemibold)
                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
            Text(detail)
                .font(CambridgeTypography.uiCaption)
                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
