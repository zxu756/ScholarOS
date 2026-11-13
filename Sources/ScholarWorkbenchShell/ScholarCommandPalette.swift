import Foundation
import SwiftUI
import ScholarModels
import ScholarProjectStore

// MARK: - Command Palette Models & Action Payloads (`ScholarPaletteItem`)

/// Filterable domain categories inside the `⌘K` Command, Section, Citation & Action Palette.
public enum ScholarPaletteCategory: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case all = "All"
    case studio = "Studios"
    case sections = "Sections"
    case citations = "Citations"
    case files = "Files"
    case actions = "Actions"

    public var id: String { rawValue }

    public var sfSymbolName: String {
        switch self {
        case .all: return "command"
        case .studio: return "square.grid.2x2"
        case .sections: return "list.number"
        case .citations: return "quote.bubble"
        case .files: return "doc.text"
        case .actions: return "bolt.horizontal"
        }
    }
}

/// Deterministic action dispatched when the user confirms a `ScholarPaletteItem` via `↩` or click.
public enum ScholarPaletteCommandAction: Sendable, Hashable {
    case switchStudioTab(ScholarStudioTab)
    case openManuscriptLocation(filePath: String, line: Int)
    case focusCitation(citeKey: String)
    case insertVerifiedCitation(citeKey: String)
    case setRightInspector(ScholarRightInspectorMode)
    case revealDrawer(ScholarBottomDrawerChannel)
    case toggleLeftSidebar
    case runEditorialPlugins
    case createSnapshot
    case undo
    case redo
    case openPreferences
    case openShortcutLegend
    case custom(id: String)
}

/// Single searchable entry in the `⌘K` ScholarOS Command Palette.
public struct ScholarPaletteItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let monospacedTag: String?
    public let category: ScholarPaletteCategory
    public let sfSymbolName: String
    public let shortcutHint: String?
    public let firewallClass: CitationFirewallClass?
    public let baseWeight: Double
    public let action: ScholarPaletteCommandAction

    public init(
        id: String,
        title: String,
        subtitle: String,
        monospacedTag: String? = nil,
        category: ScholarPaletteCategory,
        sfSymbolName: String = "command",
        shortcutHint: String? = nil,
        firewallClass: CitationFirewallClass? = nil,
        baseWeight: Double = 0.0,
        action: ScholarPaletteCommandAction
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.monospacedTag = monospacedTag
        self.category = category
        self.sfSymbolName = sfSymbolName
        self.shortcutHint = shortcutHint
        self.firewallClass = firewallClass
        self.baseWeight = baseWeight
        self.action = action
    }
}

/// Ranked subsequence match result including character indices for bold Library Forest Green highlighting.
public struct ScholarFuzzyScoredItem: Sendable, Hashable, Identifiable {
    public var id: String { item.id }
    public let item: ScholarPaletteItem
    public let score: Double
    public let matchedTitleIndices: [Int]
    public let matchedTagIndices: [Int]

    public init(
        item: ScholarPaletteItem,
        score: Double,
        matchedTitleIndices: [Int] = [],
        matchedTagIndices: [Int] = []
    ) {
        self.item = item
        self.score = score
        self.matchedTitleIndices = matchedTitleIndices
        self.matchedTagIndices = matchedTagIndices
    }
}

// MARK: - Zero-Latency Subsequence Fuzzy Scorer (`ScholarSubsequenceFuzzyScorer`)

/// Pure-Swift subsequence fuzzy matcher with word-boundary, prefix, consecutive-run, and camelCase bonuses.
public struct ScholarSubsequenceFuzzyScorer: Sendable {
    public static let prefixMatchBonus: Double = 52.0
    public static let wordBoundaryBonus: Double = 24.0
    public static let consecutiveStreakBonus: Double = 15.0
    public static let exactCaseBonus: Double = 2.5
    public static let perCharacterBaseScore: Double = 10.0
    public static let skippedCharacterPenalty: Double = 1.35
    public static let trailingLengthPenalty: Double = 0.12

    public init() {}

    /// Filters and ranks `items` against `query` and optional `categoryFilter` in microseconds.
    public func rank(
        items: [ScholarPaletteItem],
        query: String,
        categoryFilter: ScholarPaletteCategory = .all,
        limit: Int = 60
    ) -> [ScholarFuzzyScoredItem] {
        let filteredByCategory: [ScholarPaletteItem]
        if categoryFilter == .all {
            filteredByCategory = items
        } else {
            filteredByCategory = items.filter { $0.category == categoryFilter }
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return Array(
                filteredByCategory
                    .sorted { lhs, rhs in
                        if lhs.baseWeight != rhs.baseWeight {
                            return lhs.baseWeight > rhs.baseWeight
                        }
                        return lhs.title < rhs.title
                    }
                    .prefix(limit)
                    .map { ScholarFuzzyScoredItem(item: $0, score: $0.baseWeight) }
            )
        }

        // Strip leading `@` or `\` when users search `@vaswani` or `\sec`
        let normalizedQuery: String
        if trimmedQuery.hasPrefix("@") || trimmedQuery.hasPrefix("\\") {
            let stripped = String(trimmedQuery.dropFirst())
            normalizedQuery = stripped.isEmpty ? trimmedQuery : stripped
        } else {
            normalizedQuery = trimmedQuery
        }

        var scored: [ScholarFuzzyScoredItem] = []
        scored.reserveCapacity(filteredByCategory.count)

        for candidate in filteredByCategory {
            let titleMatch = scoreSubsequence(query: normalizedQuery, target: candidate.title)
            let tagMatch = candidate.monospacedTag.flatMap { scoreSubsequence(query: normalizedQuery, target: $0) }
            let subtitleMatch = scoreSubsequence(query: normalizedQuery, target: candidate.subtitle)

            var bestScore: Double?
            var titleIndices: [Int] = []
            var tagIndices: [Int] = []

            if let tm = titleMatch {
                bestScore = tm.score + candidate.baseWeight
                titleIndices = tm.indices
            }

            if let tgm = tagMatch {
                // Tag matches (e.g., exact BibTeX citeKey or section number `2.1`) earn a high precision boost
                let boostedTagScore = tgm.score + 26.0 + candidate.baseWeight
                if bestScore == nil || boostedTagScore > bestScore! {
                    bestScore = boostedTagScore
                }
                tagIndices = tgm.indices
            }

            if let sm = subtitleMatch {
                let weightedSub = sm.score * 0.78 + candidate.baseWeight
                if bestScore == nil || weightedSub > bestScore! {
                    bestScore = weightedSub
                }
            }

            if let resolvedScore = bestScore {
                scored.append(
                    ScholarFuzzyScoredItem(
                        item: candidate,
                        score: resolvedScore,
                        matchedTitleIndices: titleIndices,
                        matchedTagIndices: tagIndices
                    )
                )
            }
        }

        scored.sort { lhs, rhs in
            if abs(lhs.score - rhs.score) > 1.0e-6 {
                return lhs.score > rhs.score
            }
            return lhs.item.title < rhs.item.title
        }

        if scored.count > limit {
            return Array(scored.prefix(limit))
        }
        return scored
    }

    /// Computes subsequence alignment score and matched character positions, or `nil` if `query` is not a subsequence.
    public func scoreSubsequence(
        query: String,
        target: String
    ) -> (score: Double, indices: [Int])? {
        guard !query.isEmpty, !target.isEmpty else { return nil }

        let qChars = Array(query)
        let qLower = Array(query.lowercased())
        let tChars = Array(target)
        let tLower = Array(target.lowercased())

        guard qLower.count <= tLower.count else { return nil }

        // First verify subsequence existence and try boundary-preferring anchor alignment
        var bestAlignment = alignGreedy(
            qChars: qChars,
            qLower: qLower,
            tChars: tChars,
            tLower: tLower,
            preferWordBoundaries: true
        )

        if let plainAlignment = alignGreedy(
            qChars: qChars,
            qLower: qLower,
            tChars: tChars,
            tLower: tLower,
            preferWordBoundaries: false
        ) {
            if bestAlignment == nil || plainAlignment.score > bestAlignment!.score {
                bestAlignment = plainAlignment
            }
        }

        return bestAlignment
    }

    private func alignGreedy(
        qChars: [Character],
        qLower: [Character],
        tChars: [Character],
        tLower: [Character],
        preferWordBoundaries: Bool
    ) -> (score: Double, indices: [Int])? {
        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(qLower.count)

        var tCursor = 0
        for qIdx in 0..<qLower.count {
            let needle = qLower[qIdx]
            let remainingNeeded = qLower.count - qIdx - 1
            let maxSearchEnd = tLower.count - remainingNeeded - 1
            guard tCursor <= maxSearchEnd else { return nil }

            var chosenIndex: Int?
            if preferWordBoundaries {
                // Look ahead for a word-boundary or consecutive match that still leaves room for remaining chars
                for pos in tCursor...maxSearchEnd where tLower[pos] == needle {
                    let isConsecutive = (!matchedIndices.isEmpty && pos == matchedIndices.last! + 1)
                    if isConsecutive || Self.isWordBoundary(in: tChars, at: pos) {
                        if canCompleteSubsequence(qLower: qLower, fromQ: qIdx + 1, tLower: tLower, fromT: pos + 1) {
                            chosenIndex = pos
                            break
                        }
                    }
                }
            }

            if chosenIndex == nil {
                for pos in tCursor...maxSearchEnd where tLower[pos] == needle {
                    chosenIndex = pos
                    break
                }
            }

            guard let found = chosenIndex else { return nil }
            matchedIndices.append(found)
            tCursor = found + 1
        }

        var totalScore: Double = 0.0
        var consecutiveStreak = 0

        for (step, pos) in matchedIndices.enumerated() {
            totalScore += Self.perCharacterBaseScore

            if pos == 0 {
                totalScore += Self.prefixMatchBonus
            } else if Self.isWordBoundary(in: tChars, at: pos) {
                totalScore += Self.wordBoundaryBonus
            }

            if step < qChars.count && qChars[step] == tChars[pos] {
                totalScore += Self.exactCaseBonus
            }

            if step > 0 {
                let prevPos = matchedIndices[step - 1]
                if pos == prevPos + 1 {
                    consecutiveStreak += 1
                    totalScore += Self.consecutiveStreakBonus * Double(min(consecutiveStreak, 4))
                } else {
                    consecutiveStreak = 0
                    let gap = pos - prevPos - 1
                    totalScore -= Self.skippedCharacterPenalty * Double(gap)
                }
            } else if pos > 0 {
                totalScore -= 0.45 * Double(pos)
            }
        }

        let unmatchedTail = max(0, tChars.count - (matchedIndices.last ?? 0) - 1)
        totalScore -= Self.trailingLengthPenalty * Double(unmatchedTail)
        return (score: totalScore, indices: matchedIndices)
    }

    private func canCompleteSubsequence(
        qLower: [Character],
        fromQ: Int,
        tLower: [Character],
        fromT: Int
    ) -> Bool {
        var qi = fromQ
        var ti = fromT
        while qi < qLower.count && ti < tLower.count {
            if qLower[qi] == tLower[ti] {
                qi += 1
            }
            ti += 1
        }
        return qi == qLower.count
    }

    private static func isWordBoundary(in chars: [Character], at index: Int) -> Bool {
        if index == 0 { return true }
        let prev = chars[index - 1]
        let curr = chars[index]
        if prev == " " || prev == "/" || prev == "-" || prev == "_" || prev == ":" || prev == "." || prev == "(" {
            return true
        }
        if prev.isLowercase && curr.isUppercase {
            return true
        }
        if prev.isLetter && curr.isNumber {
            return true
        }
        return false
    }
}

// MARK: - Unified Palette Catalog Builder (`ScholarCommandPaletteCatalog`)

/// Synthesizes searchable `ScholarPaletteItem` entries from studios, manuscript files, numbered sections,
/// 5-class Citation Firewall bibliography entries, undo/redo history, and editorial actions.
public enum ScholarCommandPaletteCatalog {
    public static func buildItems(
        manuscriptFiles: [ManuscriptFileRecord] = [],
        outlineEntries: [DocumentOutlineEntry] = [],
        bibliographyEntries: [BibliographyEntry] = [],
        canUndo: Bool = false,
        topUndoTitle: String? = nil,
        canRedo: Bool = false,
        topRedoTitle: String? = nil
    ) -> [ScholarPaletteItem] {
        var items: [ScholarPaletteItem] = []

        // 1. Six Primary Studios (`⌘1` ... `⌘6`)
        for (idx, tab) in ScholarStudioTab.allCases.enumerated() {
            items.append(
                ScholarPaletteItem(
                    id: "studio.\(tab.rawValue)",
                    title: "Open \(tab.rawValue)",
                    subtitle: "Switch primary workstation studio canvas",
                    monospacedTag: "Studio \(idx + 1)",
                    category: .studio,
                    sfSymbolName: CambridgeLinenPalette.resolvedSymbolName(for: tab.sfSymbolName),
                    shortcutHint: "⌘\(idx + 1)",
                    baseWeight: 20.0 - Double(idx),
                    action: .switchStudioTab(tab)
                )
            )
        }

        // 2. High-Frequency Editorial, Snapshot, Docking & Preferences Actions
        items.append(contentsOf: [
            ScholarPaletteItem(
                id: "action.run-editorial-audit",
                title: "Run JavaScriptCore Editorial & Statistical Audit",
                subtitle: "Execute Overclaiming, Anti-AI Prose, APA 7th p-Value, and Venue Gate plugins",
                monospacedTag: "4 JS Plugins",
                category: .actions,
                sfSymbolName: "highlighter",
                shortcutHint: "⇧⌘E",
                baseWeight: 24.0,
                action: .runEditorialPlugins
            ),
            ScholarPaletteItem(
                id: "action.create-snapshot",
                title: "Create Named Manuscript Snapshot",
                subtitle: "Save immutable revision checkpoint for Myers word-level Track Changes diffing",
                monospacedTag: "SQLite WAL",
                category: .actions,
                sfSymbolName: "camera.aperture",
                shortcutHint: "⌥⌘S",
                baseWeight: 18.0,
                action: .createSnapshot
            ),
            ScholarPaletteItem(
                id: "action.split-pdf",
                title: "Toggle Right Split: PDF & SyncTeX Preview",
                subtitle: "Synchronize manuscript cursor with compiled PDF bounding boxes",
                category: .actions,
                sfSymbolName: "doc.richtext",
                shortcutHint: "⌥⌘1",
                baseWeight: 14.0,
                action: .setRightInspector(.pdfPreview)
            ),
            ScholarPaletteItem(
                id: "action.split-diff",
                title: "Toggle Right Split: Word-Level Track Changes",
                subtitle: "Compare live LaTeX/Typst buffer against archival snapshots",
                category: .actions,
                sfSymbolName: "arrow.left.arrow.right.square",
                shortcutHint: "⌥⌘2",
                baseWeight: 13.5,
                action: .setRightInspector(.trackChanges)
            ),
            ScholarPaletteItem(
                id: "action.split-citation",
                title: "Toggle Right Split: Citation & Provenance Inspector",
                subtitle: "Inspect Crossref metadata and BM25 PDF bounding-box evidence",
                category: .actions,
                sfSymbolName: "quote.closing",
                shortcutHint: "⌥⌘3",
                baseWeight: 13.0,
                action: .setRightInspector(.citationInspector)
            ),
            ScholarPaletteItem(
                id: "action.drawer-diagnostics",
                title: "Reveal Bottom Drawer: LSP Diagnostics",
                subtitle: "Inspect incremental LaTeX/Typst parser and macro cycle diagnostics",
                category: .actions,
                sfSymbolName: "exclamationmark.bubble",
                shortcutHint: "⌘J",
                baseWeight: 12.0,
                action: .revealDrawer(.diagnostics)
            ),
            ScholarPaletteItem(
                id: "action.drawer-firewall",
                title: "Reveal Bottom Drawer: Citation Firewall Ledger",
                subtitle: "Audit Verified DOI, Metadata Drift, Unverified, and Blocked citations",
                category: .actions,
                sfSymbolName: "lock.shield",
                baseWeight: 11.8,
                action: .revealDrawer(.citationFirewall)
            ),
            ScholarPaletteItem(
                id: "action.drawer-editorial",
                title: "Reveal Bottom Drawer: Editorial Audit Findings",
                subtitle: "Browse JavaScriptCore plugin findings and one-click scholarly rewrites",
                category: .actions,
                sfSymbolName: "highlighter",
                baseWeight: 11.6,
                action: .revealDrawer(.editorialAudit)
            ),
            ScholarPaletteItem(
                id: "action.toggle-sidebar",
                title: "Toggle Left Project & Outline Navigator",
                subtitle: "Show or hide manuscript files, numbered sections, and Firewall/PRISMA cards",
                category: .actions,
                sfSymbolName: "sidebar.left",
                shortcutHint: "⌘B",
                baseWeight: 11.0,
                action: .toggleLeftSidebar
            ),
            ScholarPaletteItem(
                id: "action.preferences",
                title: "Open ScholarOS Preferences…",
                subtitle: "Configure Typography, Citation Firewall, Zotero SQLite, PRISMA κ, and JS Plugins",
                category: .actions,
                sfSymbolName: "gearshape",
                shortcutHint: "⌘,",
                baseWeight: 10.5,
                action: .openPreferences
            ),
            ScholarPaletteItem(
                id: "action.shortcut-legend",
                title: "Show Keyboard Shortcut Reference",
                subtitle: "Display complete workstation keybinding legend",
                category: .actions,
                sfSymbolName: "keyboard",
                shortcutHint: "⌘/",
                baseWeight: 10.0,
                action: .openShortcutLegend
            )
        ])

        if canUndo {
            items.append(
                ScholarPaletteItem(
                    id: "action.undo",
                    title: "Undo: \(topUndoTitle ?? "Last Mutation")",
                    subtitle: "Revert top entry from persistent SQLite WAL undo journal",
                    category: .actions,
                    sfSymbolName: "arrow.uturn.backward",
                    shortcutHint: "⌘Z",
                    baseWeight: 16.0,
                    action: .undo
                )
            )
        }

        if canRedo {
            items.append(
                ScholarPaletteItem(
                    id: "action.redo",
                    title: "Redo: \(topRedoTitle ?? "Reverted Mutation")",
                    subtitle: "Reapply top entry from persistent SQLite WAL redo journal",
                    category: .actions,
                    sfSymbolName: "arrow.uturn.forward",
                    shortcutHint: "⇧⌘Z",
                    baseWeight: 15.5,
                    action: .redo
                )
            )
        }

        // 3. Manuscript Files
        for file in manuscriptFiles {
            items.append(
                ScholarPaletteItem(
                    id: "file.\(file.path)",
                    title: file.path,
                    subtitle: "\(file.format.rawValue) Manuscript • \(file.wordCount) words",
                    monospacedTag: "\(file.wordCount)w",
                    category: .files,
                    sfSymbolName: "doc.text",
                    baseWeight: file.path == "main.tex" ? 17.0 : 12.5,
                    action: .openManuscriptLocation(filePath: file.path, line: 1)
                )
            )
        }

        // 4. Numbered Outline Sections
        for entry in outlineEntries {
            let prefixDisplay = entry.numberPrefix.isEmpty ? "§" : "§\(entry.numberPrefix)"
            items.append(
                ScholarPaletteItem(
                    id: "section.\(entry.id)",
                    title: entry.title,
                    subtitle: "\(entry.filePath):\(entry.line) • \(entry.wordCountInSection) words in section",
                    monospacedTag: prefixDisplay,
                    category: .sections,
                    sfSymbolName: "list.number",
                    baseWeight: 14.5 - Double(entry.level),
                    action: .openManuscriptLocation(filePath: entry.filePath, line: entry.line)
                )
            )
        }

        // 5. Bibliography & Citation Firewall Entries
        for bib in bibliographyEntries {
            let yearStr = bib.year.map(String.init) ?? "n.d."
            let authorYear = "\(bib.firstAuthorFamily) (\(yearStr))"
            let action: ScholarPaletteCommandAction = bib.firewallClass.allowsManuscriptInsertion
                ? .insertVerifiedCitation(citeKey: bib.citeKey)
                : .focusCitation(citeKey: bib.citeKey)

            items.append(
                ScholarPaletteItem(
                    id: "cite.\(bib.citeKey)",
                    title: bib.title,
                    subtitle: "\(authorYear) • \(bib.venue.isEmpty ? bib.kind.rawValue : bib.venue)",
                    monospacedTag: "@\(bib.citeKey)",
                    category: .citations,
                    sfSymbolName: "quote.bubble",
                    firewallClass: bib.firewallClass,
                    baseWeight: bib.firewallClass.allowsManuscriptInsertion ? 13.0 : 9.0,
                    action: action
                )
            )
        }

        return items
    }
}

// MARK: - SwiftUI `⌘K` Command Palette Overlay View (`ScholarCommandPaletteOverlayView`)

/// Zero-latency Cambridge Linen & Pure Archival Paper `⌘K` Command Palette with `↑`/`↓`/`↩`/`⎋` keyboard control.
public struct ScholarCommandPaletteOverlayView: View {
    @Binding public var isPresented: Bool
    public let items: [ScholarPaletteItem]
    public let onTriggerAction: (ScholarPaletteCommandAction) -> Void

    @State private var searchQuery: String = ""
    @State private var selectedCategory: ScholarPaletteCategory = .all
    @State private var highlightedIndex: Int = 0
    @FocusState private var isSearchFieldFocused: Bool

    private let scorer = ScholarSubsequenceFuzzyScorer()

    public init(
        isPresented: Binding<Bool>,
        items: [ScholarPaletteItem],
        onTriggerAction: @escaping (ScholarPaletteCommandAction) -> Void
    ) {
        self._isPresented = isPresented
        self.items = items
        self.onTriggerAction = onTriggerAction
    }

    private var rankedResults: [ScholarFuzzyScoredItem] {
        scorer.rank(items: items, query: searchQuery, categoryFilter: selectedCategory, limit: 45)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // Solid non-glassmorphic warm ink scrim
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            VStack(spacing: 0) {
                searchInputHeader
                Divider()
                    .overlay(CambridgeLinenPalette.stoneHairline)
                categoryFilterBar
                Divider()
                    .overlay(CambridgeLinenPalette.stoneHairline)
                resultsScrollList
                Divider()
                    .overlay(CambridgeLinenPalette.stoneHairline)
                paletteFooterBar
            }
            .frame(width: 660)
            .background(
                RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                    .fill(CambridgeLinenPalette.archivalPaper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                    .strokeBorder(CambridgeLinenPalette.deepStoneBorder, lineWidth: CambridgeMetrics.hairline)
            )
            .shadow(color: Color.black.opacity(0.14), radius: 22, x: 0, y: 10)
            .padding(.top, 56)
            .onAppear {
                highlightedIndex = 0
                isSearchFieldFocused = true
            }
            .onChange(of: searchQuery) { _, _ in
                highlightedIndex = 0
            }
            .onChange(of: selectedCategory) { _, _ in
                highlightedIndex = 0
            }
            .onKeyPress(.upArrow) {
                moveSelection(delta: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveSelection(delta: 1)
                return .handled
            }
            .onKeyPress(.return) {
                confirmHighlightedSelection()
                return .handled
            }
            .onKeyPress(.escape) {
                isPresented = false
                return .handled
            }
        }
        .preferredColorScheme(.light)
    }

    private var searchInputHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)

            TextField("Jump to studio, §section, @citeKey, manuscript file, or command…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    confirmHighlightedSelection()
                }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                }
                .buttonStyle(.plain)
            }

            ScholarKeycapBadge("ESC")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(CambridgeLinenPalette.archivalPaper)
    }

    private var categoryFilterBar: some View {
        HStack(spacing: 6) {
            ForEach(ScholarPaletteCategory.allCases) { cat in
                let isSelected = (selectedCategory == cat)
                Button {
                    selectedCategory = cat
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: cat.sfSymbolName)
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(cat.rawValue)
                            .font(CambridgeTypography.uiSectionLabel)
                    }
                    .foregroundStyle(isSelected ? CambridgeLinenPalette.archivalPaper : CambridgeLinenPalette.slateEditorial)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
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
            Text("\(rankedResults.count) matches")
                .font(CambridgeTypography.monoSmall)
                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(CambridgeLinenPalette.cambridgeLinen)
    }

    private var resultsScrollList: some View {
        let currentResults = rankedResults
        return ScrollViewReader { proxy in
            ScrollView {
                if currentResults.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                        Text("No matching sections, citations, files, or studio actions")
                            .font(CambridgeTypography.uiControlMedium)
                            .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                        Text("Try a BibTeX key (@vaswani2017attention), section prefix (§2.1), or action ('Editorial').")
                            .font(CambridgeTypography.uiCaption)
                            .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 34)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(currentResults.enumerated()), id: \.element.id) { idx, entry in
                            paletteRow(for: entry, isHighlighted: idx == highlightedIndex)
                                .id(entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    highlightedIndex = idx
                                    executeAndDismiss(entry.item.action)
                                }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(minHeight: 220, maxHeight: 340)
            .background(CambridgeLinenPalette.archivalPaper)
            .onChange(of: highlightedIndex) { _, newIdx in
                if newIdx >= 0 && newIdx < currentResults.count {
                    proxy.scrollTo(currentResults[newIdx].id, anchor: .center)
                }
            }
        }
    }

    private func paletteRow(for scored: ScholarFuzzyScoredItem, isHighlighted: Bool) -> some View {
        let item = scored.item
        return HStack(spacing: 10) {
            Image(systemName: CambridgeLinenPalette.resolvedSymbolName(for: item.sfSymbolName))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHighlighted ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.slateEditorial)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let tag = item.monospacedTag, !tag.isEmpty {
                        Text(tag)
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(CambridgeLinenPalette.libraryForestTint)
                            )
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    highlightedTitleText(item.title, matchedIndices: Set(scored.matchedTitleIndices))
                }

                Text(item.subtitle)
                    .font(CambridgeTypography.uiCaption)
                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
            }

            Spacer(minLength: 8)

            if let fw = item.firewallClass {
                FirewallBadgeView(firewallClass: fw, compact: true)
            }

            if let shortcut = item.shortcutHint {
                ScholarKeycapBadge(shortcut)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .fill(isHighlighted ? CambridgeLinenPalette.libraryForestTint : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .strokeBorder(
                    isHighlighted ? CambridgeLinenPalette.libraryForestBorder : Color.clear,
                    lineWidth: CambridgeMetrics.hairline
                )
        )
    }

    private func highlightedTitleText(_ title: String, matchedIndices: Set<Int>) -> Text {
        guard !matchedIndices.isEmpty else {
            return Text(title)
                .font(CambridgeTypography.uiControlMedium)
                .foregroundColor(CambridgeLinenPalette.oxfordCharcoal)
        }
        let chars = Array(title)
        var composed = Text("")
        for (idx, ch) in chars.enumerated() {
            let segment = Text(String(ch))
            if matchedIndices.contains(idx) {
                composed = composed + segment
                    .font(CambridgeTypography.uiControlSemibold)
                    .foregroundColor(CambridgeLinenPalette.libraryForestGreen)
            } else {
                composed = composed + segment
                    .font(CambridgeTypography.uiControlMedium)
                    .foregroundColor(CambridgeLinenPalette.oxfordCharcoal)
            }
        }
        return composed
    }

    private var paletteFooterBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ScholarKeycapBadge("↑↓")
                Text("Navigate")
                    .font(CambridgeTypography.uiCaption)
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
            }
            HStack(spacing: 4) {
                ScholarKeycapBadge("↩")
                Text("Execute / Jump")
                    .font(CambridgeTypography.uiCaption)
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
            }
            HStack(spacing: 4) {
                ScholarKeycapBadge("⎋")
                Text("Dismiss")
                    .font(CambridgeTypography.uiCaption)
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
            }
            Spacer()
            Text("Subsequence Fuzzy Index • Citation Firewall Enforced")
                .font(CambridgeTypography.uiCaption)
                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(CambridgeLinenPalette.warmVellum)
    }

    private func moveSelection(delta: Int) {
        let count = rankedResults.count
        guard count > 0 else { return }
        highlightedIndex = (highlightedIndex + delta + count) % count
    }

    private func confirmHighlightedSelection() {
        let results = rankedResults
        guard !results.isEmpty else { return }
        let clamped = min(max(0, highlightedIndex), results.count - 1)
        executeAndDismiss(results[clamped].item.action)
    }

    private func executeAndDismiss(_ action: ScholarPaletteCommandAction) {
        isPresented = false
        onTriggerAction(action)
    }
}
