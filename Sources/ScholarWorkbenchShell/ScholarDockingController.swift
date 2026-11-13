import Foundation
import SwiftUI
import ScholarModels
import ScholarProjectStore
import ScholarPluginSDK

// MARK: - Docking Modes, Drawer Channels, Cursor Coordinates & Manuscript Tabs

/// Optional secondary split-pane inspector alongside the primary Manuscript & LSP editor.
public enum ScholarRightInspectorMode: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case none = "None"
    case pdfPreview = "PDF & SyncTeX"
    case trackChanges = "Track Changes"
    case citationInspector = "Citation Inspector"

    public var id: String { rawValue }

    public var sfSymbolName: String {
        switch self {
        case .none: return "rectangle"
        case .pdfPreview: return "doc.richtext"
        case .trackChanges: return "arrow.left.arrow.right.square"
        case .citationInspector: return "quote.closing"
        }
    }

    public var shortLabel: String {
        switch self {
        case .none: return "Single Pane"
        case .pdfPreview: return "PDF Split"
        case .trackChanges: return "Diff Split"
        case .citationInspector: return "Cite Split"
        }
    }

    public func localizedShortLabel(_ lang: ScholarLanguage) -> String {
        switch self {
        case .none: return lang.L("Single Pane", "单栏编辑")
        case .pdfPreview: return lang.L("PDF Split", "PDF分栏")
        case .trackChanges: return lang.L("Diff Split", "修订对比")
        case .citationInspector: return lang.L("Cite Split", "引文详情")
        }
    }
}

/// Active diagnostic or telemetry channel inside the resizable bottom workbench drawer.
public enum ScholarBottomDrawerChannel: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case diagnostics = "Diagnostics"
    case citationFirewall = "Citation Firewall"
    case editorialAudit = "Editorial Audit"
    case syncTeXLog = "Build & SyncTeX"

    public var id: String { rawValue }

    public var sfSymbolName: String {
        switch self {
        case .diagnostics: return "exclamationmark.Bubble".lowercased() == "exclamationmark.bubble" ? "exclamationmark.bubble" : "list.bullet.rectangle"
        case .citationFirewall: return "lock.shield"
        case .editorialAudit: return "highlighter"
        case .syncTeXLog: return "point.topleft.down.curvedto.point.bottomright.up"
        }
    }

    public var subtitle: String {
        switch self {
        case .diagnostics: return "Incremental LaTeX / Typst CST & Macro LSP Diagnostics"
        case .citationFirewall: return "5-Class Crossref / arXiv / PubMed Verification Ledger"
        case .editorialAudit: return "Isolated JavaScriptCore Rhetoric, Prose & APA 7th Findings"
        case .syncTeXLog: return "Bidirectional Source-to-PDF Anchors & Sandbox Console Ring"
        }
    }

    public func localizedTitle(_ lang: ScholarLanguage) -> String {
        switch self {
        case .diagnostics: return lang.L("Diagnostics", "LSP 诊断")
        case .citationFirewall: return lang.L("Citation Firewall", "引文防火墙")
        case .editorialAudit: return lang.L("Editorial Audit", "审稿插件审计")
        case .syncTeXLog: return lang.L("Build & SyncTeX", "构建与 SyncTeX")
        }
    }

    public func localizedSubtitle(_ lang: ScholarLanguage) -> String {
        switch self {
        case .diagnostics:
            return lang.L("Incremental LaTeX / Typst CST & Macro LSP Diagnostics", "增量式 LaTeX / Typst 语法树与防环宏展开诊断")
        case .citationFirewall:
            return lang.L("5-Class Crossref / arXiv / PubMed Verification Ledger", "五级 Crossref / arXiv / PubMed 引文核验台账")
        case .editorialAudit:
            return lang.L("Isolated JavaScriptCore Rhetoric, Prose & APA 7th Findings", "隔离沙盒 JavaScriptCore 修辞、文风与 APA 7th 统计核查")
        case .syncTeXLog:
            return lang.L("Bidirectional Source-to-PDF Anchors & Sandbox Console Ring", "双向源码至 PDF 坐标锚点与沙盒环形日志")
        }
    }
}

/// Synchronized `(filePath, line, column)` cursor anchor shared across the editor, outline tree, SyncTeX pane, and drawers.
public struct ScholarCursorLocation: Sendable, Codable, Hashable {
    public var filePath: String
    public var line: Int
    public var column: Int

    public init(filePath: String = "main.tex", line: Int = 1, column: Int = 1) {
        self.filePath = filePath.isEmpty ? "main.tex" : filePath
        self.line = max(1, line)
        self.column = max(1, column)
    }

    public var compactLabel: String {
        "\(filePath):\(line):\(column)"
    }

    public var lineColumnLabel: String {
        "Ln \(line), Col \(column)"
    }

    public func localizedLineColumnLabel(_ lang: ScholarLanguage) -> String {
        lang.L("Ln \(line), Col \(column)", "第 \(line) 行, 第 \(column) 列")
    }
}

/// Open document tab state inside the multi-file manuscript editor strip.
public struct OpenManuscriptTab: Sendable, Codable, Hashable, Identifiable {
    public var id: String { filePath }
    public let filePath: String
    public let format: ManuscriptFormat
    public var isPinned: Bool
    public var isDirty: Bool
    public var wordCount: Int
    public var lastCursorLine: Int
    public var lastCursorColumn: Int

    public init(
        filePath: String,
        format: ManuscriptFormat? = nil,
        isPinned: Bool = false,
        isDirty: Bool = false,
        wordCount: Int = 0,
        lastCursorLine: Int = 1,
        lastCursorColumn: Int = 1
    ) {
        self.filePath = filePath
        self.format = format ?? ManuscriptFormat.detect(fromPath: filePath)
        self.isPinned = isPinned
        self.isDirty = isDirty
        self.wordCount = max(0, wordCount)
        self.lastCursorLine = max(1, lastCursorLine)
        self.lastCursorColumn = max(1, lastCursorColumn)
    }

    public var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    public var directoryPrefix: String? {
        let dir = (filePath as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }
}

/// Codable snapshot of the workbench layout for deterministic session persistence and testing.
public struct ScholarWorkspaceLayoutSnapshot: Sendable, Codable, Hashable {
    public let activeStudioTab: ScholarStudioTab
    public let openTabs: [OpenManuscriptTab]
    public let activeManuscriptFilePath: String
    public let rightInspectorMode: ScholarRightInspectorMode
    public let isLeftSidebarVisible: Bool
    public let leftSidebarWidth: Double
    public let rightInspectorWidth: Double
    public let isBottomDrawerVisible: Bool
    public let activeDrawerChannel: ScholarBottomDrawerChannel
    public let bottomDrawerHeight: Double
    public let zoomScale: Double
    public let synchronizedCursor: ScholarCursorLocation
    public let selectedCiteKey: String?

    public init(
        activeStudioTab: ScholarStudioTab,
        openTabs: [OpenManuscriptTab],
        activeManuscriptFilePath: String,
        rightInspectorMode: ScholarRightInspectorMode,
        isLeftSidebarVisible: Bool,
        leftSidebarWidth: Double,
        rightInspectorWidth: Double,
        isBottomDrawerVisible: Bool,
        activeDrawerChannel: ScholarBottomDrawerChannel,
        bottomDrawerHeight: Double,
        zoomScale: Double,
        synchronizedCursor: ScholarCursorLocation,
        selectedCiteKey: String?
    ) {
        self.activeStudioTab = activeStudioTab
        self.openTabs = openTabs
        self.activeManuscriptFilePath = activeManuscriptFilePath
        self.rightInspectorMode = rightInspectorMode
        self.isLeftSidebarVisible = isLeftSidebarVisible
        self.leftSidebarWidth = leftSidebarWidth
        self.rightInspectorWidth = rightInspectorWidth
        self.isBottomDrawerVisible = isBottomDrawerVisible
        self.activeDrawerChannel = activeDrawerChannel
        self.bottomDrawerHeight = bottomDrawerHeight
        self.zoomScale = zoomScale
        self.synchronizedCursor = synchronizedCursor
        self.selectedCiteKey = selectedCiteKey
    }
}

// MARK: - Workbench Split-Pane & Multi-Tab Docking Controller (`ScholarDockingController`)

/// Coordinates studio navigation, multi-tab manuscript docking, right split-pane inspection,
/// 4-channel bottom drawer sizing, zoom scaling, and synchronized `(filePath, line, column)` + `citeKey` focus.
@MainActor
public final class ScholarDockingController: ObservableObject {
    // MARK: Bounds Constants
    public static let minSidebarWidth: CGFloat = 228
    public static let maxSidebarWidth: CGFloat = 380
    public static let minRightInspectorWidth: CGFloat = 300
    public static let maxRightInspectorWidth: CGFloat = 560
    public static let minDrawerHeight: CGFloat = 152
    public static let maxDrawerHeight: CGFloat = 420
    public static let minZoomScale: Double = 0.75
    public static let maxZoomScale: Double = 1.75

    // MARK: Primary Studio & Tab State
    @Published public var activeStudioTab: ScholarStudioTab
    @Published public var openManuscriptTabs: [OpenManuscriptTab]
    @Published public var activeManuscriptFilePath: String

    // MARK: Split-Pane & Drawer Chrome State
    @Published public var rightInspectorMode: ScholarRightInspectorMode
    @Published public var isLeftSidebarVisible: Bool
    @Published public var leftSidebarWidth: CGFloat
    @Published public var rightInspectorWidth: CGFloat
    @Published public var isBottomDrawerVisible: Bool
    @Published public var activeDrawerChannel: ScholarBottomDrawerChannel
    @Published public var bottomDrawerHeight: CGFloat
    @Published public var zoomScale: Double

    // MARK: Synchronized Selection & Cursor State
    @Published public var synchronizedCursor: ScholarCursorLocation
    @Published public var selectedCiteKey: String?
    @Published public var selectedOutlineEntryID: String?
    @Published public var selectedSnapshotID: UUID?
    @Published public var activeSyncTeXAnchor: SyncTeXAnchor?

    // MARK: Workbench Overlay Presentation State
    @Published public var isCommandPalettePresented: Bool = false
    @Published public var isPreferencesPresented: Bool = false
    @Published public var isShortcutLegendPresented: Bool = false

    public init(
        activeStudioTab: ScholarStudioTab = .manuscriptEditor,
        initialTabs: [OpenManuscriptTab] = [
            OpenManuscriptTab(filePath: "main.tex", isPinned: true)
        ],
        activeManuscriptFilePath: String = "main.tex",
        rightInspectorMode: ScholarRightInspectorMode = .pdfPreview,
        isLeftSidebarVisible: Bool = true,
        leftSidebarWidth: CGFloat = 264,
        rightInspectorWidth: CGFloat = 372,
        isBottomDrawerVisible: Bool = true,
        activeDrawerChannel: ScholarBottomDrawerChannel = .diagnostics,
        bottomDrawerHeight: CGFloat = 208,
        zoomScale: Double = 1.0,
        synchronizedCursor: ScholarCursorLocation? = nil,
        selectedCiteKey: String? = nil
    ) {
        let nonEmptyTabs = initialTabs.isEmpty
            ? [OpenManuscriptTab(filePath: activeManuscriptFilePath, isPinned: true)]
            : initialTabs
        self.activeStudioTab = activeStudioTab
        self.openManuscriptTabs = nonEmptyTabs
        self.activeManuscriptFilePath = activeManuscriptFilePath
        self.rightInspectorMode = rightInspectorMode
        self.isLeftSidebarVisible = isLeftSidebarVisible
        self.leftSidebarWidth = Self.clamp(leftSidebarWidth, min: Self.minSidebarWidth, max: Self.maxSidebarWidth)
        self.rightInspectorWidth = Self.clamp(rightInspectorWidth, min: Self.minRightInspectorWidth, max: Self.maxRightInspectorWidth)
        self.isBottomDrawerVisible = isBottomDrawerVisible
        self.activeDrawerChannel = activeDrawerChannel
        self.bottomDrawerHeight = Self.clamp(bottomDrawerHeight, min: Self.minDrawerHeight, max: Self.maxDrawerHeight)
        self.zoomScale = min(Self.maxZoomScale, max(Self.minZoomScale, zoomScale))
        self.synchronizedCursor = synchronizedCursor ?? ScholarCursorLocation(
            filePath: activeManuscriptFilePath,
            line: 1,
            column: 1
        )
        self.selectedCiteKey = selectedCiteKey
    }

    // MARK: Convenience Tuple Accessor

    public var cursorTuple: (filePath: String, line: Int, column: Int) {
        (synchronizedCursor.filePath, synchronizedCursor.line, synchronizedCursor.column)
    }

    // MARK: Multi-Tab Manuscript Operations

    /// Synchronizes open tabs with persisted `ManuscriptFileRecord` metadata without losing tab pin/cursor state.
    public func syncWithManuscriptRecords(
        _ records: [ManuscriptFileRecord],
        primaryFile: String = "main.tex"
    ) {
        guard !records.isEmpty else { return }
        let byPath = Dictionary(uniqueKeysWithValues: records.map { ($0.path, $0) })

        var updatedTabs: [OpenManuscriptTab] = []
        for var tab in openManuscriptTabs {
            if let rec = byPath[tab.filePath] {
                tab.wordCount = rec.wordCount
                updatedTabs.append(tab)
            }
        }

        if updatedTabs.isEmpty {
            for rec in records {
                updatedTabs.append(
                    OpenManuscriptTab(
                        filePath: rec.path,
                        format: rec.format,
                        isPinned: rec.path == primaryFile,
                        isDirty: false,
                        wordCount: rec.wordCount
                    )
                )
            }
        }

        openManuscriptTabs = updatedTabs
        if !openManuscriptTabs.contains(where: { $0.filePath == activeManuscriptFilePath }),
           let fallback = openManuscriptTabs.first
        {
            activeManuscriptFilePath = fallback.filePath
            synchronizedCursor = ScholarCursorLocation(
                filePath: fallback.filePath,
                line: fallback.lastCursorLine,
                column: fallback.lastCursorColumn
            )
        }
    }

    /// Opens or focuses `filePath`, updates the synchronized cursor, and optionally switches to `.manuscriptEditor`.
    public func openManuscript(
        filePath: String,
        line: Int? = nil,
        column: Int = 1,
        wordCount: Int? = nil,
        switchToEditor: Bool = true
    ) {
        let normalized = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if let existingIdx = openManuscriptTabs.firstIndex(where: { $0.filePath == normalized }) {
            if let wc = wordCount {
                openManuscriptTabs[existingIdx].wordCount = max(0, wc)
            }
            let targetLine = max(1, line ?? openManuscriptTabs[existingIdx].lastCursorLine)
            let targetCol = max(1, column)
            openManuscriptTabs[existingIdx].lastCursorLine = targetLine
            openManuscriptTabs[existingIdx].lastCursorColumn = targetCol
            activeManuscriptFilePath = normalized
            synchronizedCursor = ScholarCursorLocation(filePath: normalized, line: targetLine, column: targetCol)
        } else {
            let targetLine = max(1, line ?? 1)
            let targetCol = max(1, column)
            let newTab = OpenManuscriptTab(
                filePath: normalized,
                isPinned: openManuscriptTabs.isEmpty,
                isDirty: false,
                wordCount: wordCount ?? 0,
                lastCursorLine: targetLine,
                lastCursorColumn: targetCol
            )
            openManuscriptTabs.append(newTab)
            activeManuscriptFilePath = normalized
            synchronizedCursor = ScholarCursorLocation(filePath: normalized, line: targetLine, column: targetCol)
        }

        if switchToEditor {
            activeStudioTab = .manuscriptEditor
        }
    }

    /// Closes an unpinned tab while always retaining at least one active manuscript buffer.
    public func closeManuscriptTab(_ filePath: String) {
        guard openManuscriptTabs.count > 1,
              let idx = openManuscriptTabs.firstIndex(where: { $0.filePath == filePath }),
              !openManuscriptTabs[idx].isPinned
        else { return }

        let wasActive = (activeManuscriptFilePath == filePath)
        openManuscriptTabs.remove(at: idx)
        if wasActive {
            let nextIdx = min(idx, openManuscriptTabs.count - 1)
            let replacement = openManuscriptTabs[nextIdx]
            activeManuscriptFilePath = replacement.filePath
            synchronizedCursor = ScholarCursorLocation(
                filePath: replacement.filePath,
                line: replacement.lastCursorLine,
                column: replacement.lastCursorColumn
            )
        }
    }

    public func togglePinTab(_ filePath: String) {
        guard let idx = openManuscriptTabs.firstIndex(where: { $0.filePath == filePath }) else { return }
        openManuscriptTabs[idx].isPinned.toggle()
    }

    public func setTabDirty(_ filePath: String, isDirty: Bool, wordCount: Int? = nil) {
        guard let idx = openManuscriptTabs.firstIndex(where: { $0.filePath == filePath }) else { return }
        openManuscriptTabs[idx].isDirty = isDirty
        if let wordCount {
            openManuscriptTabs[idx].wordCount = max(0, wordCount)
        }
    }

    public func selectNextTab() {
        guard openManuscriptTabs.count > 1,
              let currentIdx = openManuscriptTabs.firstIndex(where: { $0.filePath == activeManuscriptFilePath })
        else { return }
        let nextTab = openManuscriptTabs[(currentIdx + 1) % openManuscriptTabs.count]
        openManuscript(filePath: nextTab.filePath, line: nextTab.lastCursorLine, column: nextTab.lastCursorColumn)
    }

    public func selectPreviousTab() {
        guard openManuscriptTabs.count > 1,
              let currentIdx = openManuscriptTabs.firstIndex(where: { $0.filePath == activeManuscriptFilePath })
        else { return }
        let prevIdx = (currentIdx - 1 + openManuscriptTabs.count) % openManuscriptTabs.count
        let prevTab = openManuscriptTabs[prevIdx]
        openManuscript(filePath: prevTab.filePath, line: prevTab.lastCursorLine, column: prevTab.lastCursorColumn)
    }

    // MARK: Synchronized Cursor, Outline, Diagnostic & Citation Navigation

    public func updateCursor(filePath: String? = nil, line: Int, column: Int = 1) {
        let resolvedFile = filePath ?? activeManuscriptFilePath
        let cleanLine = max(1, line)
        let cleanCol = max(1, column)
        synchronizedCursor = ScholarCursorLocation(filePath: resolvedFile, line: cleanLine, column: cleanCol)
        if let idx = openManuscriptTabs.firstIndex(where: { $0.filePath == resolvedFile }) {
            openManuscriptTabs[idx].lastCursorLine = cleanLine
            openManuscriptTabs[idx].lastCursorColumn = cleanCol
        }
    }

    public func navigateToOutlineEntry(_ entry: DocumentOutlineEntry) {
        selectedOutlineEntryID = entry.id
        openManuscript(filePath: entry.filePath, line: entry.line, column: 1, switchToEditor: true)
    }

    public func navigateToDiagnostic(_ diagnostic: LSPDiagnostic) {
        openManuscript(
            filePath: diagnostic.span.filePath,
            line: diagnostic.span.start.line,
            column: diagnostic.span.start.column,
            switchToEditor: true
        )
    }

    public func navigateToEditorialFinding(_ finding: EditorialAuditFinding) {
        openManuscript(
            filePath: finding.filePath,
            line: finding.line,
            column: 1,
            switchToEditor: true
        )
    }

    public func navigateToSyncTeXAnchor(_ anchor: SyncTeXAnchor) {
        activeSyncTeXAnchor = anchor
        if rightInspectorMode == .none {
            rightInspectorMode = .pdfPreview
        }
        openManuscript(
            filePath: anchor.sourceFile,
            line: anchor.line,
            column: anchor.column,
            switchToEditor: true
        )
    }

    public func focusCitation(_ citeKey: String, openRightInspector: Bool = false, switchToFirewallStudio: Bool = false) {
        selectedCiteKey = citeKey
        if switchToFirewallStudio {
            activeStudioTab = .citationFirewall
        } else if openRightInspector {
            activeStudioTab = .manuscriptEditor
            rightInspectorMode = .citationInspector
        }
    }

    // MARK: Sidebar, Split-Pane, Drawer & Zoom Controls

    public func toggleLeftSidebar() {
        isLeftSidebarVisible.toggle()
    }

    public func setRightInspectorMode(_ mode: ScholarRightInspectorMode) {
        if rightInspectorMode == mode {
            rightInspectorMode = .none
        } else {
            rightInspectorMode = mode
        }
    }

    public func revealBottomDrawer(channel: ScholarBottomDrawerChannel) {
        activeDrawerChannel = channel
        isBottomDrawerVisible = true
    }

    public func toggleBottomDrawer(preferredChannel: ScholarBottomDrawerChannel? = nil) {
        if let preferredChannel {
            if isBottomDrawerVisible && activeDrawerChannel == preferredChannel {
                isBottomDrawerVisible = false
            } else {
                activeDrawerChannel = preferredChannel
                isBottomDrawerVisible = true
            }
        } else {
            isBottomDrawerVisible.toggle()
        }
    }

    public func resizeLeftSidebar(to proposedWidth: CGFloat) {
        leftSidebarWidth = Self.clamp(proposedWidth, min: Self.minSidebarWidth, max: Self.maxSidebarWidth)
    }

    public func resizeRightInspector(to proposedWidth: CGFloat) {
        rightInspectorWidth = Self.clamp(proposedWidth, min: Self.minRightInspectorWidth, max: Self.maxRightInspectorWidth)
    }

    public func resizeBottomDrawer(to proposedHeight: CGFloat) {
        bottomDrawerHeight = Self.clamp(proposedHeight, min: Self.minDrawerHeight, max: Self.maxDrawerHeight)
    }

    public func zoomIn(step: Double = 0.10) {
        zoomScale = min(Self.maxZoomScale, (zoomScale + step * 100.0 / 100.0))
    }

    public func zoomOut(step: Double = 0.10) {
        zoomScale = max(Self.minZoomScale, zoomScale - step)
    }

    public func resetZoom() {
        zoomScale = 1.0
    }

    // MARK: Layout Snapshot Persistence

    public func exportLayoutSnapshot() -> ScholarWorkspaceLayoutSnapshot {
        ScholarWorkspaceLayoutSnapshot(
            activeStudioTab: activeStudioTab,
            openTabs: openManuscriptTabs,
            activeManuscriptFilePath: activeManuscriptFilePath,
            rightInspectorMode: rightInspectorMode,
            isLeftSidebarVisible: isLeftSidebarVisible,
            leftSidebarWidth: Double(leftSidebarWidth),
            rightInspectorWidth: Double(rightInspectorWidth),
            isBottomDrawerVisible: isBottomDrawerVisible,
            activeDrawerChannel: activeDrawerChannel,
            bottomDrawerHeight: Double(bottomDrawerHeight),
            zoomScale: zoomScale,
            synchronizedCursor: synchronizedCursor,
            selectedCiteKey: selectedCiteKey
        )
    }

    public func applyLayoutSnapshot(_ snapshot: ScholarWorkspaceLayoutSnapshot) {
        activeStudioTab = snapshot.activeStudioTab
        if !snapshot.openTabs.isEmpty {
            openManuscriptTabs = snapshot.openTabs
        }
        activeManuscriptFilePath = snapshot.activeManuscriptFilePath
        rightInspectorMode = snapshot.rightInspectorMode
        isLeftSidebarVisible = snapshot.isLeftSidebarVisible
        leftSidebarWidth = Self.clamp(CGFloat(snapshot.leftSidebarWidth), min: Self.minSidebarWidth, max: Self.maxSidebarWidth)
        rightInspectorWidth = Self.clamp(CGFloat(snapshot.rightInspectorWidth), min: Self.minRightInspectorWidth, max: Self.maxRightInspectorWidth)
        isBottomDrawerVisible = snapshot.isBottomDrawerVisible
        activeDrawerChannel = snapshot.activeDrawerChannel
        bottomDrawerHeight = Self.clamp(CGFloat(snapshot.bottomDrawerHeight), min: Self.minDrawerHeight, max: Self.maxDrawerHeight)
        zoomScale = min(Self.maxZoomScale, max(Self.minZoomScale, snapshot.zoomScale))
        synchronizedCursor = snapshot.synchronizedCursor
        selectedCiteKey = snapshot.selectedCiteKey
    }

    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(upper, Swift.max(lower, value))
    }
}

// MARK: - Database-Backed `EditorialPluginAuditRunner` Bridge

public extension EditorialPluginAuditRunner {
    /// Executes all enabled built-in and stored custom JavaScript plugins directly against a `ScholarProjectDatabase`,
    /// optionally persisting the resulting `EditorialAuditFinding` records back into SQLite WAL storage.
    func run(
        against database: ScholarProjectDatabase,
        persistFindings: Bool = true
    ) throws -> EditorialPluginRunSummary {
        let manuscriptRecords = try database.listManuscriptFiles()
        var filesDict: [String: String] = [:]
        for record in manuscriptRecords {
            filesDict[record.path] = record.content
        }

        let primaryPath = try database.primaryManuscriptFile()
        if filesDict.isEmpty {
            filesDict[primaryPath] = ""
        }

        let bibEntries = try database.listBibliographyEntries()
        let storedManifests = try database.listPluginManifests(enabledOnly: false)
        let mergedPlugins = Self.mergeBuiltInAndStoredManifests(stored: storedManifests)

        var perPluginConfigs: [String: String] = [:]
        for plugin in mergedPlugins {
            if let cfg = try database.pluginConfigurationJSON(pluginID: plugin.id) {
                perPluginConfigs[plugin.id] = cfg
            }
        }

        let summary = try run(
            files: filesDict,
            primaryFilePath: primaryPath,
            bibliography: bibEntries,
            plugins: mergedPlugins,
            perPluginConfigJSON: perPluginConfigs
        )

        if persistFindings {
            try database.replaceEditorialFindings(summary.findings)
            try database.recordAuditEvent(
                category: "EDITORIAL_AUDIT",
                action: "runJavaScriptPlugins",
                targetKey: primaryPath,
                details: [
                    "executed_plugins": "\(summary.executedPluginIDs.count)",
                    "findings": "\(summary.findings.count)",
                    "blockers": "\(summary.blockerCount)",
                    "camera_ready": summary.canSubmitCameraReady ? "true" : "false"
                ]
            )
        }

        return summary
    }
}
