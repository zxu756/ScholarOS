import Foundation
import SwiftUI
import ScholarModels
import ScholarProjectStore
import ScholarPluginSDK

// MARK: - Multi-Tab `⌘,` Workstation Preferences (`ScholarWorkbenchPreferences`)

/// Four canonical preference panes inside the `⌘,` ScholarOS Preferences window.
public enum ScholarPreferencesTab: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case typographyAndEditor = "Typography & Editor"
    case citationAndZotero = "Citation & Zotero Firewall"
    case prismaAndScreening = "PRISMA & Screening"
    case editorialJSPlugins = "Editorial JS Plugins"

    public var id: String { rawValue }

    public var sfSymbolName: String {
        switch self {
        case .typographyAndEditor: return "textformat.size"
        case .citationAndZotero: return "lock.shield"
        case .prismaAndScreening: return "checklist.checked"
        case .editorialJSPlugins: return "curlybraces.square"
        }
    }
}

/// Observable workstation configuration store backing `ScholarPreferencesSheetView` and runtime editorial gates.
@MainActor
public final class ScholarWorkbenchPreferences: ObservableObject {
    // 1. Typography & Editor
    @Published public var editorFontSize: Double = 13.5
    @Published public var lineHeightMultiple: Double = 1.42
    @Published public var columnRulerWidth: Int = 100
    @Published public var enableLiveLSPDiagnostics: Bool = true
    @Published public var showLineNumbersAndCodeFolding: Bool = true
    @Published public var targetVenuePresetLabel: String = "NeurIPS / ICML (9 pages)"

    // 2. Citation & Zotero Firewall
    @Published public var defaultCitationStyle: CitationFormatStyle = .apa7
    @Published public var enforceStrictHardwareFirewallGate: Bool = true
    @Published public var blockUnverifiedOfflineCitations: Bool = true
    @Published public var crossrefPolitePoolEmail: String = "editorial-lab@university.edu"
    @Published public var zoteroSQLiteDatabasePath: String = "~/Zotero/zotero.sqlite"
    @Published public var jaroWinklerDeduplicationThreshold: Double = 0.92

    // 3. PRISMA & Screening
    @Published public var blindReviewerBUntilCommitted: Bool = true
    @Published public var minimumTargetCohensKappa: Double = 0.75
    @Published public var enforcePriorityExclusionCodes: Bool = true
    @Published public var activeReviewerHandle: String = "Reviewer A"

    // 4. Editorial JS Plugins
    @Published public var venueAuditMode: EditorialVenueAuditMode = .doubleBlindSubmission
    @Published public var maxAbstractWords: Int = 250
    @Published public var pluginManifests: [ScholarPluginManifest]

    public init(
        initialPlugins: [ScholarPluginManifest] = BuiltInEditorialPluginCatalog.allPlugins
    ) {
        self.pluginManifests = initialPlugins
    }

    public func togglePluginEnabled(id: String) {
        guard let idx = pluginManifests.firstIndex(where: { $0.id == id }) else { return }
        pluginManifests[idx].isEnabled.toggle()
    }

    public func upsertCustomPlugin(_ manifest: ScholarPluginManifest) {
        if let idx = pluginManifests.firstIndex(where: { $0.id == manifest.id }) {
            pluginManifests[idx] = manifest
        } else {
            pluginManifests.append(manifest)
        }
    }

    public func removeCustomPlugin(id: String) {
        pluginManifests.removeAll { !$0.isBuiltIn && $0.id == id }
    }

    public func restoreDefaults() {
        editorFontSize = 13.5
        lineHeightMultiple = 1.42
        columnRulerWidth = 100
        enableLiveLSPDiagnostics = true
        showLineNumbersAndCodeFolding = true
        defaultCitationStyle = .apa7
        enforceStrictHardwareFirewallGate = true
        blockUnverifiedOfflineCitations = true
        jaroWinklerDeduplicationThreshold = 0.92
        blindReviewerBUntilCommitted = true
        minimumTargetCohensKappa = 0.75
        enforcePriorityExclusionCodes = true
        venueAuditMode = .doubleBlindSubmission
        maxAbstractWords = 250
        pluginManifests = BuiltInEditorialPluginCatalog.allPlugins
    }

    public func buildAuditRunOptions() -> EditorialAuditRunOptions {
        EditorialAuditRunOptions(
            venueMode: venueAuditMode,
            maxAbstractWords: maxAbstractWords,
            continueOnPluginError: true,
            deduplicateIdenticalFindings: true
        )
    }
}

// MARK: - `⌘,` Multi-Tab Preferences Sheet View (`ScholarPreferencesSheetView`)

/// Archival Cambridge Linen & Pure Paper `⌘,` Preferences modal sheet.
public struct ScholarPreferencesSheetView: View {
    @ObservedObject public var preferences: ScholarWorkbenchPreferences
    @Binding public var isPresented: Bool
    public let onSyncPluginsToDatabase: ([ScholarPluginManifest]) -> Void

    @State private var selectedTab: ScholarPreferencesTab = .typographyAndEditor
    @State private var selectedPluginID: String = BuiltInEditorialPluginCatalog.overclaimingRhetoricDetectorID
    @State private var customDraftTitle: String = ""
    @State private var customDraftScript: String = EditorialCustomPluginTemplates.crossReferenceConsistencyTemplate.scriptSource

    public init(
        preferences: ScholarWorkbenchPreferences,
        isPresented: Binding<Bool>,
        onSyncPluginsToDatabase: @escaping ([ScholarPluginManifest]) -> Void = { _ in }
    ) {
        self.preferences = preferences
        self._isPresented = isPresented
        self.onSyncPluginsToDatabase = onSyncPluginsToDatabase
    }

    public var body: some View {
        VStack(spacing: 0) {
            preferencesHeader
            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)
            preferencesTabBar
            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            ScrollView {
                Group {
                    switch selectedTab {
                    case .typographyAndEditor:
                        typographyAndEditorPane
                    case .citationAndZotero:
                        citationAndZoteroPane
                    case .prismaAndScreening:
                        prismaAndScreeningPane
                    case .editorialJSPlugins:
                        editorialJSPluginsPane
                    }
                }
                .padding(18)
            }
            .background(CambridgeLinenPalette.cambridgeLinen)

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            preferencesFooter
        }
        .frame(width: 800, height: 560)
        .background(CambridgeLinenPalette.cambridgeLinen)
        .preferredColorScheme(.light)
    }

    private var preferencesHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ScholarOS Workstation Preferences")
                    .font(CambridgeTypography.scholarlyTitle)
                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                Text("Configure archival typography, hardware-gated Citation Firewall rules, PRISMA 2020 blinding, and JavaScriptCore sandboxes.")
                    .font(CambridgeTypography.uiCaption)
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
            }
            Spacer()
            ScholarKeycapBadge("⌘,")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(CambridgeLinenPalette.archivalPaper)
    }

    private var preferencesTabBar: some View {
        HStack(spacing: 6) {
            ForEach(ScholarPreferencesTab.allCases) { tab in
                let isSelected = (selectedTab == tab)
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.sfSymbolName)
                            .font(.system(size: 12, weight: .semibold))
                        Text(tab.rawValue)
                            .font(isSelected ? CambridgeTypography.uiControlSemibold : CambridgeTypography.uiControlMedium)
                    }
                    .foregroundStyle(isSelected ? CambridgeLinenPalette.archivalPaper : CambridgeLinenPalette.oxfordCharcoal)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
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
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(CambridgeLinenPalette.warmVellum)
    }

    // MARK: Tab 1 — Typography & Editor

    private var typographyAndEditorPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                CambridgeSectionHeader(
                    title: "Archival Manuscript Typography",
                    subtitle: "Cambridge Linen (#F8F6F0) canvas with Pure Archival Paper (#FFFFFF) editor well"
                )

                HStack {
                    Text("Editor Monospace Font Size")
                        .font(CambridgeTypography.uiControlMedium)
                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                    Spacer()
                    Slider(value: $preferences.editorFontSize, in: 11.0...20.0, step: 0.5)
                        .frame(width: 220)
                    Text(String(format: "%.1f pt", preferences.editorFontSize))
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                        .frame(width: 58, alignment: .trailing)
                }

                HStack {
                    Text("Editorial Line Height Multiple")
                        .font(CambridgeTypography.uiControlMedium)
                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                    Spacer()
                    Slider(value: $preferences.lineHeightMultiple, in: 1.20...1.80, step: 0.02)
                        .frame(width: 220)
                    Text(String(format: "%.2f×", preferences.lineHeightMultiple))
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                        .frame(width: 58, alignment: .trailing)
                }

                HStack {
                    Text("Wrap & Column Ruler Guide")
                        .font(CambridgeTypography.uiControlMedium)
                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                    Spacer()
                    ForEach([80, 100, 120], id: \.self) { col in
                        Button("\(col) cols") {
                            preferences.columnRulerWidth = col
                        }
                        .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: preferences.columnRulerWidth == col))
                    }
                }
            }
            .cambridgeArchivalCard(padding: 14)

            VStack(alignment: .leading, spacing: 10) {
                CambridgeSectionHeader(
                    title: "Incremental LaTeX / Typst LSP & Venue Budget",
                    subtitle: "Sub-20ms incremental CST re-lexing and live texcount budget tracking"
                )

                Toggle("Enable live LaTeX / Typst CST & cycle-safe macro diagnostics", isOn: $preferences.enableLiveLSPDiagnostics)
                    .font(CambridgeTypography.uiControl)
                Toggle("Show monospaced gutter line numbers and section fold markers", isOn: $preferences.showLineNumbersAndCodeFolding)
                    .font(CambridgeTypography.uiControl)

                HStack {
                    Text("Target Submission Venue Preset")
                        .font(CambridgeTypography.uiControlMedium)
                    Spacer()
                    TextField("Venue Preset", text: $preferences.targetVenuePresetLabel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
            }
            .cambridgeArchivalCard(padding: 14)
        }
    }

    // MARK: Tab 2 — Citation & Zotero Firewall

    private var citationAndZoteroPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                CambridgeSectionHeader(
                    title: "Hardware-Gated 5-Class Citation Verification Firewall",
                    subtitle: "Prevents unverified, hallucinated, or retracted citeKeys from entering manuscripts via UI, CLI, or MCP"
                )

                HStack {
                    Text("Default CSL Citation Format")
                        .font(CambridgeTypography.uiControlMedium)
                    Spacer()
                    ForEach(CitationFormatStyle.allCases) { style in
                        Button(style.rawValue) {
                            preferences.defaultCitationStyle = style
                        }
                        .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: preferences.defaultCitationStyle == style))
                    }
                }

                Toggle("Enforce ERR_UNVERIFIED_CITATION block on BLOCKED_HALLUCINATED entries", isOn: $preferences.enforceStrictHardwareFirewallGate)
                    .font(CambridgeTypography.uiControl)
                Toggle("Require DOI / arXiv / PubMed verification before inserting UNVERIFIED_OFFLINE keys", isOn: $preferences.blockUnverifiedOfflineCitations)
                    .font(CambridgeTypography.uiControl)

                HStack {
                    Text("Jaro-Winkler Title Deduplication Threshold")
                        .font(CambridgeTypography.uiControlMedium)
                    Spacer()
                    Slider(value: $preferences.jaroWinklerDeduplicationThreshold, in: 0.84...0.98, step: 0.01)
                        .frame(width: 210)
                    Text(String(format: "%.2f", preferences.jaroWinklerDeduplicationThreshold))
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            .cambridgeArchivalCard(padding: 14)

            VStack(alignment: .leading, spacing: 10) {
                CambridgeSectionHeader(
                    title: "Local Zotero SQLite Read-Only Bridge & Crossref Polite Pool",
                    subtitle: "Zero-lock immutable SQLite snapshot import from Zotero 7"
                )

                HStack {
                    Text("Zotero SQLite Path")
                        .font(CambridgeTypography.uiControlMedium)
                    Spacer()
                    TextField("~/Zotero/zotero.sqlite", text: $preferences.zoteroSQLiteDatabasePath)
                        .font(CambridgeTypography.monoCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 360)
                }

                HStack {
                    Text("Crossref Polite-Pool Contact Email")
                        .font(CambridgeTypography.uiControlMedium)
                    Spacer()
                    TextField("researcher@institution.edu", text: $preferences.crossrefPolitePoolEmail)
                        .font(CambridgeTypography.monoCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 360)
                }
            }
            .cambridgeArchivalCard(padding: 14)
        }
    }

    // MARK: Tab 3 — PRISMA & Screening

    private var prismaAndScreeningPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                CambridgeSectionHeader(
                    title: "PRISMA 2020 Dual-Blind Screening Protocol",
                    subtitle: "Independent nominal reviewer voting, priority exclusion codes, and chance-corrected Cohen's κ"
                )

                Toggle("Mask Reviewer B's decisions until Reviewer A has committed a vote", isOn: $preferences.blindReviewerBUntilCommitted)
                    .font(CambridgeTypography.uiControl)
                Toggle("Require priority-ordered exclusion reason code on every EXCLUDE vote", isOn: $preferences.enforcePriorityExclusionCodes)
                    .font(CambridgeTypography.uiControl)

                HStack {
                    Text("Minimum Target Inter-Rater Reliability (Cohen's κ)")
                        .font(CambridgeTypography.uiControlMedium)
                    Spacer()
                    Slider(value: $preferences.minimumTargetCohensKappa, in: 0.55...0.95, step: 0.01)
                        .frame(width: 210)
                    Text(String(format: "κ ≥ %.2f", preferences.minimumTargetCohensKappa))
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                        .frame(width: 68, alignment: .trailing)
                }

                HStack {
                    Text("Active Local Reviewer Slot")
                        .font(CambridgeTypography.uiControlMedium)
                    Spacer()
                    ForEach(["Reviewer A", "Reviewer B", "Adjudicator"], id: \.self) { slot in
                        Button(slot) {
                            preferences.activeReviewerHandle = slot
                        }
                        .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: preferences.activeReviewerHandle == slot))
                    }
                }
            }
            .cambridgeArchivalCard(padding: 14)
        }
    }

    // MARK: Tab 4 — Editorial JS Plugins

    private var editorialJSPluginsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                CambridgeSectionHeader(
                    title: "Venue Gate & Abstract Budget Policy",
                    subtitle: "Passed to isolated JavaScriptCore plugin sandboxes via scholar.getConfig()"
                )

                HStack {
                    Text("Venue Anonymization Mode")
                        .font(CambridgeTypography.uiControlMedium)
                    Spacer()
                    ForEach(EditorialVenueAuditMode.allCases) { mode in
                        Button(mode.displayTitle) {
                            preferences.venueAuditMode = mode
                        }
                        .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: preferences.venueAuditMode == mode))
                    }
                }

                HStack {
                    Text("Maximum Abstract Word Count")
                        .font(CambridgeTypography.uiControlMedium)
                    Spacer()
                    Stepper(value: $preferences.maxAbstractWords, in: 100...500, step: 25) {
                        Text("\(preferences.maxAbstractWords) words")
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                    }
                }
            }
            .cambridgeArchivalCard(padding: 14)

            VStack(alignment: .leading, spacing: 10) {
                CambridgeSectionHeader(
                    title: "Installed JavaScriptCore Editorial Sandboxes",
                    subtitle: "Each plugin executes inside its own isolated JSVirtualMachine with capability-gated scholar.* APIs",
                    countBadge: preferences.pluginManifests.count
                ) {
                    Button("Add Cross-Ref Starter Plugin") {
                        let title = customDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        let newID = title.isEmpty
                            ? "custom.crossref-\(preferences.pluginManifests.count + 1)"
                            : "custom.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
                        let created = ScholarPluginManifest(
                            id: newID,
                            name: title.isEmpty ? "Cross-Reference & Orphan Label Auditor" : title,
                            version: "1.0.0",
                            summary: "Custom project JS plugin running in isolated JavaScriptCore sandbox.",
                            capabilities: [.readManuscriptAST, .emitEditorialFindings],
                            isBuiltIn: false,
                            isEnabled: true,
                            scriptSource: customDraftScript
                        )
                        preferences.upsertCustomPlugin(created)
                        selectedPluginID = created.id
                        onSyncPluginsToDatabase(preferences.pluginManifests)
                    }
                    .buttonStyle(CambridgeSecondaryButtonStyle())
                }

                ForEach(preferences.pluginManifests) { plugin in
                    let validation = EditorialPluginSyntaxValidator.validate(plugin)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { plugin.isEnabled },
                                    set: { _ in
                                        preferences.togglePluginEnabled(id: plugin.id)
                                        onSyncPluginsToDatabase(preferences.pluginManifests)
                                    }
                                )
                            )
                            .labelsHidden()

                            Text(plugin.name)
                                .font(CambridgeTypography.uiControlSemibold)
                                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)

                            Text("v\(plugin.version)")
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)

                            if plugin.isBuiltIn {
                                Text("Built-In")
                                    .font(CambridgeTypography.uiSectionLabel)
                                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(CambridgeLinenPalette.libraryForestTint)
                                    )
                            }

                            Spacer()

                            Text(validation.isReadyToExecute ? "JS Valid" : "Check Syntax")
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(validation.isReadyToExecute ? CambridgeLinenPalette.verifiedEmerald : CambridgeLinenPalette.blockedCrimson)
                        }

                        Text(plugin.summary)
                            .font(CambridgeTypography.uiCaption)
                            .foregroundStyle(CambridgeLinenPalette.slateEditorial)

                        HStack(spacing: 5) {
                            ForEach(plugin.capabilities, id: \.self) { cap in
                                Text(cap.rawValue)
                                    .font(CambridgeTypography.monoSmall)
                                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(CambridgeLinenPalette.warmVellum)
                                    )
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            Spacer()
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .fill(CambridgeLinenPalette.cambridgeLinen)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                    )
                }
            }
            .cambridgeArchivalCard(padding: 14)
        }
    }

    private var preferencesFooter: some View {
        HStack {
            Button("Restore Archival Defaults") {
                preferences.restoreDefaults()
                onSyncPluginsToDatabase(preferences.pluginManifests)
            }
            .buttonStyle(CambridgeSecondaryButtonStyle())

            Spacer()

            Button("Done") {
                onSyncPluginsToDatabase(preferences.pluginManifests)
                isPresented = false
            }
            .buttonStyle(CambridgePrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(CambridgeLinenPalette.archivalPaper)
    }
}

// MARK: - Non-Intrusive Toast Notification Banner Queue (`ScholarToastCenter`)

/// Semantic tone for non-intrusive Cambridge Linen toast banners.
public enum ScholarToastTone: String, Sendable, Codable, Hashable, CaseIterable {
    case info
    case verified
    case advisory
    case blocker

    public var accentColor: Color {
        switch self {
        case .info: return CambridgeLinenPalette.libraryForestGreen
        case .verified: return CambridgeLinenPalette.verifiedEmerald
        case .advisory: return CambridgeLinenPalette.preprintOchre
        case .blocker: return CambridgeLinenPalette.blockedCrimson
        }
    }

    public var sfSymbolName: String {
        switch self {
        case .info: return "info.circle.fill"
        case .verified: return "checkmark.seal.fill"
        case .advisory: return "exclamationmark.triangle.fill"
        case .blocker: return "xmark.octagon.fill"
        }
    }
}

/// Immutable toast banner item displayed in the bottom-trailing workstation notification queue.
public struct ScholarToastBanner: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let tone: ScholarToastTone
    public let title: String
    public let detail: String?
    public let actionButtonTitle: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        tone: ScholarToastTone = .info,
        title: String,
        detail: String? = nil,
        actionButtonTitle: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.tone = tone
        self.title = title
        self.detail = detail
        self.actionButtonTitle = actionButtonTitle
        self.createdAt = createdAt
    }
}

/// Manages a bounded non-intrusive FIFO toast notification queue for undo feedback, firewall blocks, and snapshots.
@MainActor
public final class ScholarToastCenter: ObservableObject {
    public let maxVisibleBanners: Int
    @Published public private(set) var activeBanners: [ScholarToastBanner] = []
    private var actionHandlers: [UUID: () -> Void] = [:]

    public init(maxVisibleBanners: Int = 3) {
        self.maxVisibleBanners = max(1, maxVisibleBanners)
    }

    public func enqueue(
        tone: ScholarToastTone = .info,
        title: String,
        detail: String? = nil,
        actionTitle: String? = nil,
        autoDismissSeconds: TimeInterval? = 4.2,
        onAction: (() -> Void)? = nil
    ) {
        let banner = ScholarToastBanner(
            tone: tone,
            title: title,
            detail: detail,
            actionButtonTitle: actionTitle
        )
        if let onAction {
            actionHandlers[banner.id] = onAction
        }

        activeBanners.append(banner)
        if activeBanners.count > maxVisibleBanners {
            let overflow = activeBanners.count - maxVisibleBanners
            for dropped in activeBanners.prefix(overflow) {
                actionHandlers.removeValue(forKey: dropped.id)
            }
            activeBanners.removeFirst(overflow)
        }

        if let seconds = autoDismissSeconds, seconds > 0 {
            let targetID = banner.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self?.dismiss(id: targetID)
            }
        }
    }

    public func triggerAction(for id: UUID) {
        let callback = actionHandlers.removeValue(forKey: id)
        dismiss(id: id)
        callback?()
    }

    public func dismiss(id: UUID) {
        actionHandlers.removeValue(forKey: id)
        activeBanners.removeAll { $0.id == id }
    }

    public func dismissAll() {
        actionHandlers.removeAll()
        activeBanners.removeAll()
    }
}

/// Bottom-trailing archival toast banner stack overlay.
public struct ScholarToastQueueOverlayView: View {
    @ObservedObject public var toastCenter: ScholarToastCenter

    public init(toastCenter: ScholarToastCenter) {
        self.toastCenter = toastCenter
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(toastCenter.activeBanners) { banner in
                HStack(alignment: .center, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(banner.tone.accentColor)
                        .frame(width: 3.5, height: 32)

                    Image(systemName: banner.tone.sfSymbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(banner.tone.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.title)
                            .font(CambridgeTypography.uiControlSemibold)
                            .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                        if let detail = banner.detail, !detail.isEmpty {
                            Text(detail)
                                .font(CambridgeTypography.uiCaption)
                                .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                        }
                    }

                    Spacer(minLength: 6)

                    if let actionLabel = banner.actionButtonTitle {
                        Button(actionLabel) {
                            toastCenter.triggerAction(for: banner.id)
                        }
                        .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: true))
                    }

                    Button {
                        toastCenter.dismiss(id: banner.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(width: 390)
                .background(
                    RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                        .fill(CambridgeLinenPalette.archivalPaper)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                        .strokeBorder(CambridgeLinenPalette.deepStoneBorder, lineWidth: CambridgeMetrics.hairline)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
            }
        }
        .padding(16)
    }
}

// MARK: - Keyboard Shortcut Legend Sheet (`ScholarShortcutLegendSheetView`)

public struct ScholarShortcutEntry: Sendable, Hashable, Identifiable {
    public var id: String { "\(group):\(keys):\(command)" }
    public let group: String
    public let keys: String
    public let command: String

    public init(group: String, keys: String, command: String) {
        self.group = group
        self.keys = keys
        self.command = command
    }
}

/// Complete workstation keybinding legend presented via `⌘/`.
public struct ScholarShortcutLegendSheetView: View {
    @Binding public var isPresented: Bool

    public static let canonicalShortcuts: [ScholarShortcutEntry] = [
        ScholarShortcutEntry(group: "Command & Studio Navigation", keys: "⌘K", command: "Open Fuzzy Command, §Section & @Citation Palette"),
        ScholarShortcutEntry(group: "Command & Studio Navigation", keys: "⌘1 – ⌘6", command: "Switch Primary Studio (Manuscript, Provenance, Graph, PRISMA, Firewall, Editorial)"),
        ScholarShortcutEntry(group: "Command & Studio Navigation", keys: "⌘B", command: "Toggle Left Project & Numbered Outline Sidebar"),
        ScholarShortcutEntry(group: "Command & Studio Navigation", keys: "⌘J", command: "Toggle 4-Channel Resizable Bottom Drawer"),
        ScholarShortcutEntry(group: "Manuscript, Snapshots & Undo", keys: "⌘Z / ⇧⌘Z", command: "Undo / Redo Persistent SQLite WAL Mutation"),
        ScholarShortcutEntry(group: "Manuscript, Snapshots & Undo", keys: "⌥⌘S", command: "Create Named Revision Snapshot for Myers Diffing"),
        ScholarShortcutEntry(group: "Manuscript, Snapshots & Undo", keys: "⌥⌘1 / 2 / 3", command: "Toggle Right Split (PDF SyncTeX, Track Changes, Citation Inspector)"),
        ScholarShortcutEntry(group: "Screening & Editorial Gate", keys: "⇧⌘E", command: "Execute JavaScriptCore Editorial & APA 7th Statistical Plugins"),
        ScholarShortcutEntry(group: "Screening & Editorial Gate", keys: "I / M / E", command: "PRISMA 2020 Deck: Vote Include / Maybe / Exclude with Reason Code"),
        ScholarShortcutEntry(group: "Screening & Editorial Gate", keys: "⌘, / ⌘/", command: "Open Workstation Preferences / Show Shortcut Legend")
    ]

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    private var groupedEntries: [(group: String, items: [ScholarShortcutEntry])] {
        let groups = ["Command & Studio Navigation", "Manuscript, Snapshots & Undo", "Screening & Editorial Gate"]
        return groups.map { grp in
            (grp, Self.canonicalShortcuts.filter { $0.group == grp })
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ScholarOS Keyboard Shortcut Reference")
                        .font(CambridgeTypography.scholarlyTitle)
                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                    Text("Keyboard-first navigation across LaTeX/Typst editing, Citation Firewall, and PRISMA 2020 screening.")
                        .font(CambridgeTypography.uiCaption)
                        .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                }
                Spacer()
                Button("Close") {
                    isPresented = false
                }
                .buttonStyle(CambridgePrimaryButtonStyle())
            }
            .padding(16)
            .background(CambridgeLinenPalette.archivalPaper)

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groupedEntries, id: \.group) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.group.uppercased())
                                .font(CambridgeTypography.uiSectionLabel)
                                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)

                            ForEach(section.items) { item in
                                HStack {
                                    Text(item.command)
                                        .font(CambridgeTypography.uiControl)
                                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                    Spacer(minLength: 12)
                                    ScholarKeycapBadge(item.keys)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        .cambridgeArchivalCard(padding: 12)
                    }
                }
                .padding(16)
            }
            .background(CambridgeLinenPalette.cambridgeLinen)
        }
        .frame(width: 620, height: 470)
        .preferredColorScheme(.light)
    }
}

// MARK: - Unified Composable Workstation Shell Frame (`ScholarWorkbenchShellFrameView`)

/// Ready-to-mount Cambridge Linen & Library Forest Green shell container assembling the top toolbar,
/// left project/outline sidebar, center studio canvas + optional right inspector split, 4-channel bottom drawer,
/// `⌘K` Command Palette overlay, toast banner stack, and `⌘,` / `⌘/` sheets.
public struct ScholarWorkbenchShellFrameView<CenterCanvas: View, RightInspector: View>: View {
    @ObservedObject public var docking: ScholarDockingController
    @ObservedObject public var preferences: ScholarWorkbenchPreferences
    @ObservedObject public var toastCenter: ScholarToastCenter

    public let projectTitle: String
    public let primaryManuscriptPath: String
    public let activeSectionTitle: String?
    public let manuscriptFiles: [ManuscriptFileRecord]
    public let outlineEntries: [DocumentOutlineEntry]
    public let bibliographyEntries: [BibliographyEntry]
    public let diagnostics: [LSPDiagnostic]
    public let editorialFindings: [EditorialAuditFinding]
    public let perPluginTimingsMs: [String: Double]
    public let syncTeXAnchors: [SyncTeXAnchor]
    public let pluginLogs: [PluginConsoleLogEntry]
    public let projectStats: ScholarProjectStats?
    public let canUndo: Bool
    public let canRedo: Bool
    public let undoDepth: Int
    public let redoDepth: Int
    public let topUndoTitle: String?
    public let topRedoTitle: String?

    public let onUndo: () -> Void
    public let onRedo: () -> Void
    public let onCreateSnapshot: () -> Void
    public let onRunEditorialAudit: () -> Void
    public let onApplyDiagnosticFix: (LSPDiagnostic) -> Void
    public let onApplyEditorialRewrite: (EditorialAuditFinding) -> Void
    public let onPaletteAction: (ScholarPaletteCommandAction) -> Void
    public let onSyncPluginsToDatabase: ([ScholarPluginManifest]) -> Void

    private let centerCanvas: CenterCanvas
    private let rightInspector: RightInspector

    public init(
        docking: ScholarDockingController,
        preferences: ScholarWorkbenchPreferences,
        toastCenter: ScholarToastCenter,
        projectTitle: String,
        primaryManuscriptPath: String = "main.tex",
        activeSectionTitle: String? = nil,
        manuscriptFiles: [ManuscriptFileRecord] = [],
        outlineEntries: [DocumentOutlineEntry] = [],
        bibliographyEntries: [BibliographyEntry] = [],
        diagnostics: [LSPDiagnostic] = [],
        editorialFindings: [EditorialAuditFinding] = [],
        perPluginTimingsMs: [String: Double] = [:],
        syncTeXAnchors: [SyncTeXAnchor] = [],
        pluginLogs: [PluginConsoleLogEntry] = [],
        projectStats: ScholarProjectStats? = nil,
        canUndo: Bool = false,
        canRedo: Bool = false,
        undoDepth: Int = 0,
        redoDepth: Int = 0,
        topUndoTitle: String? = nil,
        topRedoTitle: String? = nil,
        onUndo: @escaping () -> Void = {},
        onRedo: @escaping () -> Void = {},
        onCreateSnapshot: @escaping () -> Void = {},
        onRunEditorialAudit: @escaping () -> Void = {},
        onApplyDiagnosticFix: @escaping (LSPDiagnostic) -> Void = { _ in },
        onApplyEditorialRewrite: @escaping (EditorialAuditFinding) -> Void = { _ in },
        onPaletteAction: @escaping (ScholarPaletteCommandAction) -> Void = { _ in },
        onSyncPluginsToDatabase: @escaping ([ScholarPluginManifest]) -> Void = { _ in },
        @ViewBuilder centerCanvas: () -> CenterCanvas,
        @ViewBuilder rightInspector: () -> RightInspector
    ) {
        self.docking = docking
        self.preferences = preferences
        self.toastCenter = toastCenter
        self.projectTitle = projectTitle
        self.primaryManuscriptPath = primaryManuscriptPath
        self.activeSectionTitle = activeSectionTitle
        self.manuscriptFiles = manuscriptFiles
        self.outlineEntries = outlineEntries
        self.bibliographyEntries = bibliographyEntries
        self.diagnostics = diagnostics
        self.editorialFindings = editorialFindings
        self.perPluginTimingsMs = perPluginTimingsMs
        self.syncTeXAnchors = syncTeXAnchors
        self.pluginLogs = pluginLogs
        self.projectStats = projectStats
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.undoDepth = undoDepth
        self.redoDepth = redoDepth
        self.topUndoTitle = topUndoTitle
        self.topRedoTitle = topRedoTitle
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onCreateSnapshot = onCreateSnapshot
        self.onRunEditorialAudit = onRunEditorialAudit
        self.onApplyDiagnosticFix = onApplyDiagnosticFix
        self.onApplyEditorialRewrite = onApplyEditorialRewrite
        self.onPaletteAction = onPaletteAction
        self.onSyncPluginsToDatabase = onSyncPluginsToDatabase
        self.centerCanvas = centerCanvas()
        self.rightInspector = rightInspector()
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                ScholarTopWorkbenchToolbarView(
                    docking: docking,
                    projectTitle: projectTitle,
                    activeSectionTitle: activeSectionTitle,
                    canUndo: canUndo,
                    canRedo: canRedo,
                    undoDepth: undoDepth,
                    redoDepth: redoDepth,
                    topUndoTitle: topUndoTitle,
                    topRedoTitle: topRedoTitle,
                    onUndo: onUndo,
                    onRedo: onRedo,
                    onCreateSnapshot: onCreateSnapshot
                )

                HStack(spacing: 0) {
                    if docking.isLeftSidebarVisible {
                        ScholarLeftNavigatorSidebarView(
                            docking: docking,
                            manuscriptFiles: manuscriptFiles,
                            primaryManuscriptPath: primaryManuscriptPath,
                            outlineEntries: outlineEntries,
                            projectStats: projectStats
                        )
                    }

                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            centerCanvas
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(CambridgeLinenPalette.cambridgeLinen)

                            if docking.activeStudioTab == .manuscriptEditor && docking.rightInspectorMode != .none {
                                Rectangle()
                                    .fill(CambridgeLinenPalette.stoneHairline)
                                    .frame(width: CambridgeMetrics.hairline)
                                    .contentShape(Rectangle().inset(by: -3))
                                    .gesture(
                                        DragGesture(minimumDistance: 2)
                                            .onChanged { value in
                                                docking.resizeRightInspector(to: docking.rightInspectorWidth - value.translation.width)
                                            }
                                    )

                                rightInspector
                                    .frame(width: docking.rightInspectorWidth)
                                    .frame(maxHeight: .infinity)
                                    .background(CambridgeLinenPalette.archivalPaper)
                            }
                        }

                        if docking.isBottomDrawerVisible {
                            ScholarBottomDrawerView(
                                docking: docking,
                                diagnostics: diagnostics,
                                bibliographyEntries: bibliographyEntries,
                                editorialFindings: editorialFindings,
                                perPluginTimingsMs: perPluginTimingsMs,
                                syncTeXAnchors: syncTeXAnchors,
                                pluginLogs: pluginLogs,
                                onApplyDiagnosticFix: onApplyDiagnosticFix,
                                onApplyEditorialRewrite: onApplyEditorialRewrite,
                                onRunEditorialAudit: onRunEditorialAudit
                            )
                        }
                    }
                }
            }
            .background(CambridgeLinenPalette.cambridgeLinen)

            ScholarToastQueueOverlayView(toastCenter: toastCenter)

            if docking.isCommandPalettePresented {
                let catalog = ScholarCommandPaletteCatalog.buildItems(
                    manuscriptFiles: manuscriptFiles,
                    outlineEntries: outlineEntries,
                    bibliographyEntries: bibliographyEntries,
                    canUndo: canUndo,
                    topUndoTitle: topUndoTitle,
                    canRedo: canRedo,
                    topRedoTitle: topRedoTitle
                )
                ScholarCommandPaletteOverlayView(
                    isPresented: $docking.isCommandPalettePresented,
                    items: catalog,
                    onTriggerAction: onPaletteAction
                )
            }
        }
        .sheet(isPresented: $docking.isPreferencesPresented) {
            ScholarPreferencesSheetView(
                preferences: preferences,
                isPresented: $docking.isPreferencesPresented,
                onSyncPluginsToDatabase: onSyncPluginsToDatabase
            )
        }
        .sheet(isPresented: $docking.isShortcutLegendPresented) {
            ScholarShortcutLegendSheetView(
                isPresented: $docking.isShortcutLegendPresented
            )
        }
        .preferredColorScheme(.light)
    }
}
