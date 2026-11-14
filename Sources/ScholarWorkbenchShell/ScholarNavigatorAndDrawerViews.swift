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
    @ObservedObject private var localizer: ScholarLocalizer = .shared
    public let projectTitle: String
    public let isDemoMode: Bool
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
        isDemoMode: Bool = false,
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
        self.isDemoMode = isDemoMode
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
            // Row 1: Studio Pill Switcher + Command Palette + Undo/Redo/Snapshot + Language Toggle + Preferences
            HStack(spacing: 8) {
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
                .help(localizer.L("Toggle Left Project & Outline Sidebar (⌘B)", "显示 / 隐藏左侧项目与大纲导航栏 (⌘B)"))

                studioTabStrip

                Spacer(minLength: 6)

                if isDemoMode {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(localizer.L("DEMO — Unverified Sample Data", "DEMO / 演示数据 — 未核查示例"))
                            .font(CambridgeTypography.uiSectionLabel)
                    }
                    .foregroundStyle(CambridgeLinenPalette.driftAmber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .fill(CambridgeLinenPalette.driftAmberBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .strokeBorder(CambridgeLinenPalette.driftAmberBorder, lineWidth: CambridgeMetrics.hairline)
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }

                commandPaletteTriggerButton

                undoRedoSnapshotCluster

                ScholarLanguageTogglePill(localizer: localizer)

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
                        Text(docking.activeDrawerChannel.localizedTitle(localizer.language))
                            .font(CambridgeTypography.uiSectionLabel)
                            .tracking(0)
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
                .help(localizer.L("Toggle 4-Channel Bottom Drawer (⌘J)", "显示 / 隐藏四通道底部诊断抽屉 (⌘J)"))
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
                        HStack(spacing: 4.5) {
                            Image(systemName: CambridgeLinenPalette.resolvedSymbolName(for: tab.sfSymbolName))
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(tab.localizedTitle(localizer.language))
                                .font(isActive ? CambridgeTypography.uiControlSemibold : CambridgeTypography.uiControlMedium)
                                .tracking(0)
                        }
                        .foregroundStyle(isActive ? CambridgeLinenPalette.archivalPaper : CambridgeLinenPalette.oxfordCharcoal)
                        .padding(.horizontal, 8)
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
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Text(localizer.L("Jump / Cite", "跳转 / 引用"))
                    .font(CambridgeTypography.uiControlMedium)
                    .tracking(0)
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                ScholarKeycapBadge("⌘K")
            }
            .padding(.horizontal, 7.5)
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
        .help(localizer.L("Open Subsequence Fuzzy Command, Section & Citation Palette (⌘K)", "打开子序列模糊命令、章节与参考文献跳转面板 (⌘K)"))
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
            .help(canUndo
                  ? localizer.L("Undo \(topUndoTitle ?? "Last Action") (⌘Z)", "撤销 \(topUndoTitle ?? "上一步修改") (⌘Z)")
                  : localizer.L("Undo Stack Empty", "撤销栈为空"))

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
            .help(canRedo
                  ? localizer.L("Redo \(topRedoTitle ?? "Next Action") (⇧⌘Z)", "重做 \(topRedoTitle ?? "下一步修改") (⇧⌘Z)")
                  : localizer.L("Redo Stack Empty", "重做栈为空"))

            Button(action: onCreateSnapshot) {
                HStack(spacing: 4) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(localizer.L("Snapshot", "快照"))
                        .font(CambridgeTypography.uiControlMedium)
                        .tracking(0)
                }
            }
            .buttonStyle(CambridgeSecondaryButtonStyle())
            .help(localizer.L("Save Named Manuscript Revision Snapshot (⌥⌘S)", "保存命名手稿修订快照 (⌥⌘S)"))
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
            .help(localizer.L("Keyboard Shortcut Legend (⌘/)", "全局键盘快捷键手册 (⌘/)"))

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
            .help(localizer.L("ScholarOS Preferences (⌘,)", "ScholarOS 偏好设置 (⌘,)"))
        }
    }

    private var breadcrumbTrail: some View {
        HStack(spacing: 6) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)

            Text(localizedProjectTitle)
                .font(.system(size: 12.5, weight: .semibold, design: .serif))
                .tracking(0)
                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                .fixedSize(horizontal: true, vertical: false)

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
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text(docking.synchronizedCursor.localizedLineColumnLabel(localizer.language))
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

    private var localizedProjectTitle: String {
        if projectTitle == "Verifiable Citation Firewalls & Sandboxes" {
            return localizer.L("Verifiable Citation Firewalls & Sandboxes", "可验证引文防火墙与沙盒审稿工作站")
        }
        return String(projectTitle.prefix(48))
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
                        Text(mode.localizedShortLabel(localizer.language))
                            .font(CambridgeTypography.uiSectionLabel)
                            .tracking(0)
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
    @ObservedObject private var localizer: ScholarLocalizer = .shared

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
                                    Text(localizer.L("\(tab.wordCount)w", "\(tab.wordCount)词"))
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
    @ObservedObject private var localizer: ScholarLocalizer = .shared
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
                Text(localizer.L("MANUSCRIPT FILES", "手稿文件"))
                    .font(CambridgeTypography.uiSectionLabel)
                    .tracking(0)
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

                        Text(localizer.L("\(file.wordCount)w", "\(file.wordCount)词"))
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
                Text(localizer.L("SECTION OUTLINE", "章节大纲"))
                    .font(CambridgeTypography.uiSectionLabel)
                    .tracking(0)
                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                Spacer()
                Text("\(outlineEntries.count)")
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
            }

            if outlineEntries.isEmpty {
                Text(localizer.L("No \\section or Typst headings parsed yet.", "尚未解析到 \\section 或 Typst 章节标题。"))
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
                                Text(localizer.L("\(entry.wordCountInSection)w", "\(entry.wordCountInSection)词"))
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
                        Text(localizer.L("Citation Firewall", "引文防火墙"))
                            .font(CambridgeTypography.uiControlSemibold)
                            .tracking(0)
                            .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                        Spacer()
                        Text(localizer.L("\(verifiedCount)/\(totalBib) OK", "\(verifiedCount)/\(totalBib) 已核验"))
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.verifiedEmerald)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    HStack(spacing: 8) {
                        if blockedCount > 0 {
                            Text(localizer.L("\(blockedCount) Blocked", "已拦截 \(blockedCount) 篇"))
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.blockedCrimson)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(CambridgeLinenPalette.blockedCrimsonBg)
                                )
                                .fixedSize(horizontal: true, vertical: false)
                        } else if totalBib == 0 {
                            Text(localizer.L("No entries loaded", "未载入文献"))
                                .font(CambridgeTypography.uiCaption)
                                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                        } else {
                            Text(localizer.L("\(totalBib - verifiedCount) Unverified", "\(totalBib - verifiedCount) 篇未核查"))
                                .font(CambridgeTypography.uiCaption)
                                .foregroundStyle(CambridgeLinenPalette.slateEditorial)
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
                        Text(localizer.L("PRISMA κ & Audit", "PRISMA 信度与审稿"))
                            .font(CambridgeTypography.uiSectionLabel)
                            .tracking(0)
                            .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                        Text(
                            localizer.L(
                                String(format: "κ = %.2f • %d studies", kappa, prismaCount),
                                String(format: "κ = %.2f • %d 篇研究", kappa, prismaCount)
                            )
                        )
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer()
                    if editorialCount > 0 {
                        Text(localizer.L("\(editorialCount) flags", "\(editorialCount) 项提示"))
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
/// Title and detail text for a bottom-drawer channel that has nothing to list.
///
/// An empty list is not a result. The copy returned here may say that a check came back clean only
/// when the inputs show that the check actually ran on loaded data; with nothing loaded (or nothing
/// run) it says so instead. Pure functions, so the rule is unit-tested without rendering a view.
public enum ScholarDrawerEmptyStateCopy {
    public struct Copy: Sendable, Hashable {
        public let title: String
        public let detail: String
        /// True only when the copy reports the clean outcome of a check that ran on loaded data.
        public let reportsCleanResult: Bool

        public init(title: String, detail: String, reportsCleanResult: Bool) {
            self.title = title
            self.detail = detail
            self.reportsCleanResult = reportsCleanResult
        }
    }

    /// Diagnostics channel. `shownCount` is always 0 when this is called; `totalDiagnosticCount` is the
    /// number before the severity filter.
    public static func diagnostics(
        manuscriptFileCount: Int,
        totalDiagnosticCount: Int,
        language: ScholarLanguage
    ) -> Copy {
        if manuscriptFileCount == 0 {
            return Copy(
                title: language.L("No Manuscript Loaded", "未载入手稿"),
                detail: language.L(
                    "Nothing has been parsed, so there are no diagnostics to show.",
                    "没有解析过任何文件，所以没有诊断结果。"
                ),
                reportsCleanResult: false
            )
        }
        if totalDiagnosticCount > 0 {
            return Copy(
                title: language.L("No Diagnostics Match the Current Filter", "当前筛选条件下没有诊断"),
                detail: language.L(
                    "\(totalDiagnosticCount) diagnostics are hidden by the severity filter.",
                    "有 \(totalDiagnosticCount) 条诊断被严重级别筛选隐藏。"
                ),
                reportsCleanResult: false
            )
        }
        return Copy(
            title: language.L("Zero Markup or Macro Diagnostics", "零语法或宏展开异常"),
            detail: language.L(
                "The LaTeX/Typst parser and macro symbol table reported no diagnostics for \(manuscriptFileCount) loaded file(s).",
                "LaTeX/Typst 解析器与宏符号表对已载入的 \(manuscriptFileCount) 个文件没有报出诊断。"
            ),
            reportsCleanResult: true
        )
    }

    /// Citation channel. `verifiedCount` is the number of loaded entries whose class is `VERIFIED`.
    public static func citationFirewall(
        bibliographyEntryCount: Int,
        verifiedCount: Int,
        language: ScholarLanguage
    ) -> Copy {
        if bibliographyEntryCount == 0 {
            return Copy(
                title: language.L("No Bibliography Loaded", "未载入文献"),
                detail: language.L(
                    "No entries have been checked.",
                    "没有任何条目被检查过。"
                ),
                reportsCleanResult: false
            )
        }
        if verifiedCount == bibliographyEntryCount {
            return Copy(
                title: language.L("All \(bibliographyEntryCount) Entries Are VERIFIED", "全部 \(bibliographyEntryCount) 条文献均为 VERIFIED"),
                detail: language.L(
                    "No retracted, not-found, drifted, or unverified bibliography keys match the current filter.",
                    "当前筛选条件下没有撤稿、未找到、元数据漂移或未核查的文献键。"
                ),
                reportsCleanResult: true
            )
        }
        return Copy(
            title: language.L("No Entries Match the Current Filter", "当前筛选条件下没有条目"),
            detail: language.L(
                "\(verifiedCount) of \(bibliographyEntryCount) entries are VERIFIED.",
                "\(bibliographyEntryCount) 条文献中有 \(verifiedCount) 条为 VERIFIED。"
            ),
            reportsCleanResult: false
        )
    }

    /// Editorial channel. `pluginsRunCount` is the number of plugins that have reported a timing,
    /// i.e. that actually ran; `totalFindingCount` is the number before the severity filter.
    public static func editorialAudit(
        manuscriptFileCount: Int,
        pluginsRunCount: Int,
        totalFindingCount: Int,
        language: ScholarLanguage
    ) -> Copy {
        if manuscriptFileCount == 0 {
            return Copy(
                title: language.L("No Manuscript Loaded", "未载入手稿"),
                detail: language.L(
                    "No editorial check has been run.",
                    "没有运行过任何审稿检查。"
                ),
                reportsCleanResult: false
            )
        }
        if pluginsRunCount == 0 {
            return Copy(
                title: language.L("Editorial Checks Have Not Been Run", "尚未运行审稿检查"),
                detail: language.L(
                    "Run the editorial plugins to check the loaded manuscript.",
                    "运行审稿插件后才会有检查结果。"
                ),
                reportsCleanResult: false
            )
        }
        if totalFindingCount > 0 {
            return Copy(
                title: language.L("No Findings Match the Current Filter", "当前筛选条件下没有发现项"),
                detail: language.L(
                    "\(totalFindingCount) findings are hidden by the severity filter.",
                    "有 \(totalFindingCount) 条发现项被严重级别筛选隐藏。"
                ),
                reportsCleanResult: false
            )
        }
        return Copy(
            title: language.L("No Editorial Findings", "审稿检查没有发现问题"),
            detail: language.L(
                "\(pluginsRunCount) editorial plugin(s) ran on the loaded manuscript and reported nothing.",
                "\(pluginsRunCount) 个审稿插件已在载入的手稿上运行，没有报出问题。"
            ),
            reportsCleanResult: true
        )
    }
}

public struct ScholarBottomDrawerView: View {
    @ObservedObject public var docking: ScholarDockingController
    @ObservedObject private var localizer: ScholarLocalizer = .shared
    /// Number of manuscript files loaded in the workspace (0 in the default empty state).
    public let manuscriptFileCount: Int
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
        manuscriptFileCount: Int = 0,
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
        self.manuscriptFileCount = manuscriptFileCount
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
                        Text(channel.localizedTitle(localizer.language))
                            .font(isSelected ? CambridgeTypography.uiControlSemibold : CambridgeTypography.uiControlMedium)
                            .tracking(0)
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
            .help(localizer.L("Collapse Bottom Drawer", "收起底部诊断抽屉"))
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
                Button(localizer.L("All", "全部")) { minimumDiagnosticSeverity = nil }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: minimumDiagnosticSeverity == nil))
                Button(localizer.L("Warnings+", "警告+")) { minimumDiagnosticSeverity = .warning }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: minimumDiagnosticSeverity == .warning))
                Button(localizer.L("Errors", "错误")) { minimumDiagnosticSeverity = .error }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: minimumDiagnosticSeverity == .error))
            }
        case .citationFirewall:
            Button(
                firewallFilterOnlyIssues
                    ? localizer.L("Showing Blocked/Drift", "当前：仅看漂移与拦截")
                    : localizer.L("Filter Issues Only", "仅筛查异常引文")
            ) {
                firewallFilterOnlyIssues.toggle()
            }
            .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: firewallFilterOnlyIssues))
        case .editorialAudit:
            HStack(spacing: 6) {
                Button(localizer.L("All", "全部")) { minimumEditorialSeverity = nil }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: minimumEditorialSeverity == nil))
                Button(localizer.L("Blockers", "投稿阻断")) { minimumEditorialSeverity = .submissionBlocker }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: minimumEditorialSeverity == .submissionBlocker))
                Button {
                    onRunEditorialAudit()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text(localizer.L("Run JS Plugins", "运行审稿插件"))
                            .tracking(0)
                    }
                }
                .buttonStyle(CambridgePrimaryButtonStyle())
            }
        case .syncTeXLog:
            Text(
                localizer.L(
                    "\(syncTeXAnchors.count) SyncTeX anchors • \(pluginLogs.count) JS logs",
                    "\(syncTeXAnchors.count) 处 SyncTeX 锚点 • \(pluginLogs.count) 条沙盒日志"
                )
            )
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
            return bibliographyEntries.filter { !$0.firewallClass.allowsManuscriptInsertion || $0.firewallClass == .drift }.count
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
                let copy = ScholarDrawerEmptyStateCopy.diagnostics(
                    manuscriptFileCount: manuscriptFileCount,
                    totalDiagnosticCount: diagnostics.count,
                    language: localizer.language
                )
                emptyDrawerPlaceholder(
                    symbol: copy.reportsCleanResult ? "checkmark.seal" : "tray",
                    title: copy.title,
                    detail: copy.detail,
                    reportsCleanResult: copy.reportsCleanResult
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
                                Text(diag.localizedMessage(localizer.language))
                                    .font(CambridgeTypography.uiControl)
                                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                Text("\(diag.span.filePath):\(diag.span.start.line):\(diag.span.start.column)")
                                    .font(CambridgeTypography.monoSmall)
                                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                            }

                            Spacer(minLength: 8)

                            if diag.suggestedFix != nil {
                                Button(localizer.L("Apply Quick Fix", "一键修复")) {
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
            return entry.firewallClass != .verified
        }
        return ScrollView {
            if filtered.isEmpty {
                let copy = ScholarDrawerEmptyStateCopy.citationFirewall(
                    bibliographyEntryCount: bibliographyEntries.count,
                    verifiedCount: bibliographyEntries.filter { $0.firewallClass == .verified }.count,
                    language: localizer.language
                )
                emptyDrawerPlaceholder(
                    symbol: copy.reportsCleanResult ? "lock.shield" : "tray",
                    title: copy.title,
                    detail: copy.detail,
                    reportsCleanResult: copy.reportsCleanResult
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
                                let localizedNote = entry.localizedFirewallAuditNote(localizer.language)
                                Text(localizedNote.isEmpty ? "\(entry.firstAuthorFamily) (\(entry.year.map(String.init) ?? "n.d."))" : localizedNote)
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

                            Button(localizer.L("Inspect", "核查详情")) {
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
                    let copy = ScholarDrawerEmptyStateCopy.editorialAudit(
                        manuscriptFileCount: manuscriptFileCount,
                        pluginsRunCount: perPluginTimingsMs.count,
                        totalFindingCount: editorialFindings.count,
                        language: localizer.language
                    )
                    emptyDrawerPlaceholder(
                        symbol: copy.reportsCleanResult ? "highlighter" : "tray",
                        title: copy.title,
                        detail: copy.detail,
                        reportsCleanResult: copy.reportsCleanResult
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filtered) { finding in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    EditorialSeverityPill(severity: finding.severity, compact: true)
                                    Text(finding.localizedCategory(localizer.language))
                                        .font(CambridgeTypography.uiControlSemibold)
                                        .tracking(0)
                                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                    Text("\(finding.filePath):\(finding.line)")
                                        .font(CambridgeTypography.monoSmall)
                                        .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Spacer()
                                    Text(finding.localizedPluginName(localizer.language))
                                        .font(CambridgeTypography.uiCaption)
                                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                }

                                Text(finding.localizedExplanation(localizer.language))
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
                                        Button(localizer.L("Apply Scholarly Rewrite", "采纳学术改写")) {
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
                    Text(localizer.L("BIDIRECTIONAL SYNCTEX ANCHORS", "双向 SYNCTEX 坐标锚点"))
                        .font(CambridgeTypography.uiSectionLabel)
                        .tracking(0)
                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)

                    if syncTeXAnchors.isEmpty {
                        Text(localizer.L(
                            "Compile or preview manuscript to populate deterministic source-to-PDF anchors.",
                            "预览手稿后即可自动生成确定性源码至 PDF 双向坐标锚点。"
                        ))
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
                                    Text(
                                        localizer.L(
                                            String(format: "Page %d (%.0f, %.0f pt)", anchor.pdfPageIndex + 1, anchor.xPt, anchor.yPt),
                                            String(format: "第 %d 页 (%.0f, %.0f pt)", anchor.pdfPageIndex + 1, anchor.xPt, anchor.yPt)
                                        )
                                    )
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
                    Text(localizer.L("JAVASCRIPTCORE SANDBOX RING BUFFER", "JAVASCRIPTCORE 沙盒环形日志"))
                        .font(CambridgeTypography.uiSectionLabel)
                        .tracking(0)
                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)

                    if pluginLogs.isEmpty {
                        Text(localizer.L(
                            "Run JS Editorial Plugins to inspect deterministic console ring telemetry.",
                            "运行 JS 审稿插件即可查看隔离沙盒控制台环形日志。"
                        ))
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

    private func emptyDrawerPlaceholder(
        symbol: String,
        title: String,
        detail: String,
        reportsCleanResult: Bool
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: CambridgeLinenPalette.resolvedSymbolName(for: symbol))
                .font(.system(size: 20, weight: .medium))
                // The "verified" green is reserved for a check that ran and came back clean.
                .foregroundStyle(reportsCleanResult ? CambridgeLinenPalette.verifiedEmerald : CambridgeLinenPalette.mutedMetadata)
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
