import Foundation
import SwiftUI
import ScholarBibAndCSL
import ScholarModels
import ScholarPluginSDK
import ScholarProjectStore
import ScholarWorkbenchShell

// MARK: - Studio 5: 5-Class Citation Verification Firewall, CSL 5-Style & Myers Track Changes (`CitationFirewallAndTrackChangesStudioView`)

/// Full-width `.citationFirewall` studio featuring the live `ERR_UNVERIFIED_CITATION` hardware gate alert,
/// 5-class Citation Verification Firewall table, Jaro-Winkler duplicate reference merger, BibTeX/RIS/Zotero import bar,
/// 5-style CSL formatted preview, and Myers $O(ND)$ Word-Level Track Changes diff viewer.
public struct CitationFirewallAndTrackChangesStudioView: View {
    @ObservedObject public var viewModel: ScholarStudioViewModel
    @ObservedObject private var localizer = ScholarLocalizer.shared
    @State private var showImportSheet: Bool = false

    public init(viewModel: ScholarStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            firewallSummaryToolbar

            if let rejection = viewModel.lastBlockedInsertionAlert {
                firewallBlockedBanner(rejection)
            }

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            HStack(spacing: 0) {
                // Left Split: 5-Class Citation Firewall Table + Deduplication + CSL 5-Style Preview
                firewallLedgerAndCSLColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Rectangle()
                    .fill(CambridgeLinenPalette.stoneHairline)
                    .frame(width: CambridgeMetrics.hairline)

                // Right Split: Myers O(ND) Word-Level Track Changes + APA 7th Stat Quick-Check
                VStack(spacing: 0) {
                    ReusableTrackChangesInspectorPane(viewModel: viewModel, compactHeader: false)
                }
                .frame(width: 536)
                .background(CambridgeLinenPalette.cambridgeLinen)
            }
        }
        .background(CambridgeLinenPalette.cambridgeLinen)
        .sheet(isPresented: $showImportSheet) {
            bibTeXAndRISImportModal
        }
    }

    // MARK: 1. Firewall Audit KPI Toolbar

    private var firewallSummaryToolbar: some View {
        let report = viewModel.firewallAuditReport
        let verifiedCount = report?.verifiedCount ?? 0
        let driftCount = report?.driftCount ?? 0
        let unverifiedCount = report?.unverifiedCount ?? 0
        let notFoundCount = report?.notFoundCount ?? 0
        let retractedCount = report?.retractedCount ?? 0

        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Text(localizer.L("5-Class Citation Verification Firewall", "五级引文真实性核验防火墙"))
                    .font(CambridgeTypography.scholarlyHeadline)
                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                    .fixedSize(horizontal: true, vertical: false)
            }

            firewallTierFilterChip(
                title: localizer.L("All (\(viewModel.bibliographyEntries.count))", "全部 (\(viewModel.bibliographyEntries.count))"),
                target: nil,
                accent: CambridgeLinenPalette.oxfordCharcoal
            )
            firewallTierFilterChip(
                title: localizer.L("Verified (\(verifiedCount))", "已验证 (\(verifiedCount))"),
                target: .verified,
                accent: CambridgeLinenPalette.verifiedEmerald
            )
            firewallTierFilterChip(
                title: localizer.L("Drift (\(driftCount))", "漂移 (\(driftCount))"),
                target: .drift,
                accent: CambridgeLinenPalette.driftAmber
            )
            firewallTierFilterChip(
                title: localizer.L("Unverified (\(unverifiedCount))", "未核查 (\(unverifiedCount))"),
                target: .unverified,
                accent: CambridgeLinenPalette.slateEditorial
            )
            firewallTierFilterChip(
                title: localizer.L("Not Found (\(notFoundCount))", "未找到 (\(notFoundCount))"),
                target: .notFound,
                accent: CambridgeLinenPalette.blockedCrimson
            )
            firewallTierFilterChip(
                title: localizer.L("Retracted (\(retractedCount))", "已撤稿 (\(retractedCount))"),
                target: .retracted,
                accent: CambridgeLinenPalette.blockedCrimson
            )

            Spacer(minLength: 4)

            Button {
                _ = viewModel.attemptInsertCitation("smith2025hallucinated")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.octagon")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(localizer.L("Test Block Gate", "测试拦截门禁"))
                }
            }
            .buttonStyle(CambridgeSecondaryButtonStyle())
            .fixedSize(horizontal: true, vertical: false)

            Button {
                showImportSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(localizer.L("Import BibTeX / RIS", "导入 BibTeX / RIS"))
                }
            }
            .buttonStyle(CambridgePrimaryButtonStyle())
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CambridgeLinenPalette.warmVellum)
    }

    private func firewallTierFilterChip(
        title: String,
        target: CitationFirewallClass?,
        accent: Color
    ) -> some View {
        let isSelected = (viewModel.firewallClassFilter == target)
        return Button {
            viewModel.firewallClassFilter = target
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(isSelected ? CambridgeLinenPalette.archivalPaper : CambridgeLinenPalette.oxfordCharcoal)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.archivalPaper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    // MARK: 2. `ERR_UNVERIFIED_CITATION` Gate Banner

    private func firewallBlockedBanner(_ rejection: FirewallGateRejectionRecord) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(CambridgeLinenPalette.blockedCrimson)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(rejection.errorCode)
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(CambridgeLinenPalette.archivalPaper)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(CambridgeLinenPalette.blockedCrimson)
                        )
                        .fixedSize(horizontal: true, vertical: false)

                    Text(
                        localizer.L(
                            "Attempted insertion \(rejection.attemptedCommand) blocked before AST write",
                            "尝试插入 \(rejection.attemptedCommand) 已在写入 AST 前被防火墙拦截"
                        )
                    )
                    .font(CambridgeTypography.uiControlSemibold)
                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Text(localizedRejectionReason(rejection))
                    .font(CambridgeTypography.uiCaption)
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(CambridgeLinenPalette.blockedCrimsonBg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CambridgeLinenPalette.blockedCrimsonBorder)
                .frame(height: 1)
        }
    }

    private func localizedRejectionReason(_ rejection: FirewallGateRejectionRecord) -> String {
        guard localizer.language == .zhHans else { return rejection.reason }
        if rejection.firewallClass == .retracted {
            return "引文防火墙拒绝合入：文献键 @\(rejection.citeKey) 命中内置离线撤稿名单（内置名单，不完整）。"
        }
        if rejection.firewallClass == .notFound {
            return "引文防火墙拒绝合入：文献键 @\(rejection.citeKey) 标识符格式非法或未找到 (NOT_FOUND)。"
        }
        return "引文防火墙拒绝合入：文献键 @\(rejection.citeKey) 尚未通过外部注册库核查 (ERR_UNVERIFIED_CITATION)。"
    }

    // MARK: 3. Left Firewall Ledger + Jaro-Winkler Deduplicator + CSL 5-Style Previewer

    private var firewallLedgerAndCSLColumn: some View {
        // Prioritize showcasing all 5 distinct Firewall classes at the top so every tier is immediately visible!
        let orderedEntries = prioritizedFirewallEntries(viewModel.filteredBibliographyEntries)
        let selectedEntry = viewModel.bibliographyEntries.first(where: { $0.citeKey == viewModel.docking.selectedCiteKey })
            ?? orderedEntries.first

        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Jaro-Winkler Duplicate Merger Strip
                    if let dup = viewModel.duplicateCandidates.first {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.merge")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(CambridgeLinenPalette.driftAmber)

                            VStack(alignment: .leading, spacing: 1.5) {
                                Text(
                                    localizer.language == .zhHans
                                        ? String(format: "检测到 Jaro-Winkler 疑似重复文献（相似度 %.1f%%）", dup.titleJaroWinkler * 100.0)
                                        : String(format: "Jaro-Winkler Duplicate Detected (%.1f%% Similarity)", dup.titleJaroWinkler * 100.0)
                                )
                                .font(CambridgeTypography.uiControlSemibold)
                                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                Text(
                                    localizer.L(
                                        "@\(dup.duplicateCiteKey) duplicates canonical DOI record @\(dup.primaryCiteKey)",
                                        "@\(dup.duplicateCiteKey) 与权威 DOI 文献条目 @\(dup.primaryCiteKey) 重复"
                                    )
                                )
                                .font(CambridgeTypography.uiCaption)
                                .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                            }

                            Spacer(minLength: 4)

                            Button(localizer.L("Merge into @\(dup.primaryCiteKey)", "合并至 @\(dup.primaryCiteKey)")) {
                                viewModel.mergeDuplicateReference(dup)
                            }
                            .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: true))
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(9)
                        .background(
                            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                                .fill(CambridgeLinenPalette.driftAmberBg)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                                .strokeBorder(CambridgeLinenPalette.driftAmberBorder, lineWidth: CambridgeMetrics.hairline)
                        )
                    }

                    // 5-Class Reference Rows
                    ForEach(orderedEntries) { entry in
                        firewallEntryRow(entry)
                    }
                }
                .padding(10)
            }

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            // Bottom Live 5-Style CSL Citation Formatter Bar
            if let entry = selectedEntry {
                cslFiveStylePreviewCard(for: entry)
            }
        }
    }

    private func prioritizedFirewallEntries(_ list: [BibliographyEntry]) -> [BibliographyEntry] {
        let priorityOrder: [String] = [
            "smith2025hallucinated",
            "vaswani2017attention",
            "min2023factscore",
            "gao2023aclarc",
            "kleinberg2003bursty",
            "page2021prisma"
        ]
        var rankMap: [String: Int] = [:]
        for (i, k) in priorityOrder.enumerated() {
            rankMap[k] = i
        }
        return list.sorted { a, b in
            let rA = rankMap[a.citeKey] ?? 999
            let rB = rankMap[b.citeKey] ?? 999
            if rA != rB { return rA < rB }
            return a.citeKey < b.citeKey
        }
    }

    private func firewallEntryRow(_ entry: BibliographyEntry) -> some View {
        let isSelected = (viewModel.docking.selectedCiteKey == entry.citeKey)
        let effectiveClass = entry.trustedFirewallClass()
        let isBlocked = !effectiveClass.allowsManuscriptInsertion

        return Button {
            viewModel.docking.selectedCiteKey = entry.citeKey
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    FirewallBadgeView(firewallClass: effectiveClass, compact: true)
                        .fixedSize(horizontal: true, vertical: false)

                    Text("@\(entry.citeKey)")
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(isBlocked ? CambridgeLinenPalette.blockedCrimson : CambridgeLinenPalette.libraryForestGreen)
                        .fixedSize(horizontal: true, vertical: false)

                    if let yr = entry.year {
                        Text("(\(String(yr)))")
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Spacer(minLength: 4)

                    if let doi = entry.doi, !doi.isEmpty {
                        Text("DOI:\(doi)")
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(isBlocked ? CambridgeLinenPalette.blockedCrimson : CambridgeLinenPalette.slateEditorial)
                            .fixedSize(horizontal: true, vertical: false)
                    } else if let ax = entry.arxivID, !ax.isEmpty {
                        Text("arXiv:\(ax)")
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.preprintOchre)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Button(isBlocked ? localizer.L("Gate Check", "触发门禁") : localizer.L("Cite", "引用")) {
                        _ = viewModel.attemptInsertCitation(entry.citeKey)
                    }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: !isBlocked && isSelected))
                    .fixedSize(horizontal: true, vertical: false)
                }

                Text(entry.title)
                    .font(CambridgeTypography.uiControlSemibold)
                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                    .fixedSize(horizontal: false, vertical: true)

                Text(entry.localizedFirewallAuditNote(localizer.language))
                    .font(CambridgeTypography.uiCaption)
                    .foregroundStyle(isBlocked ? CambridgeLinenPalette.blockedCrimson : CambridgeLinenPalette.slateEditorial)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                    .fill(isBlocked ? CambridgeLinenPalette.blockedCrimsonBg.opacity(0.42) : CambridgeLinenPalette.archivalPaper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? CambridgeLinenPalette.libraryForestGreen
                            : (isBlocked ? CambridgeLinenPalette.blockedCrimsonBorder : CambridgeLinenPalette.stoneHairline),
                        lineWidth: isSelected ? 1.5 : CambridgeMetrics.hairline
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func cslFiveStylePreviewCard(for entry: BibliographyEntry) -> some View {
        let formatted = CSLCitationFormatterEngine().formatEntry(entry, style: viewModel.selectedCSLStyle)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(localizer.L("CSL 5-STYLE PREVIEW", "CSL 五大期刊引文格式实时预览"))
                    .font(CambridgeTypography.uiSectionLabel)
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                ForEach(CitationFormatStyle.allCases, id: \.self) { style in
                    Button(shortCSLName(style)) {
                        viewModel.selectedCSLStyle = style
                        viewModel.refreshFirewallAndTrackChanges()
                    }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: viewModel.selectedCSLStyle == style))
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            Text(formatted.bibliographyPlainText)
                .font(CambridgeTypography.uiCaption)
                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text(localizer.L("In-Text: \(formatted.inTextParenthetical)", "正文夹注: \(formatted.inTextParenthetical)"))
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                    .fixedSize(horizontal: true, vertical: false)

                Text("LaTeX: \(formatted.inTextLaTeX)")
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer()
            }
        }
        .padding(10)
        .background(CambridgeLinenPalette.warmVellum)
    }

    private func shortCSLName(_ style: CitationFormatStyle) -> String {
        switch style {
        case .apa7: return "APA 7th"
        case .ieee: return "IEEE"
        case .acm: return "ACM"
        case .nature: return "Nature"
        case .vancouver: return "Vancouver"
        }
    }

    private var bibTeXAndRISImportModal: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localizer.L("Import BibTeX, RIS, or PubMed .nbib Records", "导入 BibTeX、RIS 或 PubMed .nbib 文献记录"))
                .font(CambridgeTypography.scholarlyTitle)
                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)

            Text(
                localizer.L(
                    "Every imported entry is immediately audited through the 5-class Citation Verification Firewall and Jaro-Winkler deduplicator.",
                    "所有导入条目将立即经过五级引文真实性防火墙审计与 Jaro-Winkler 重复率检测。"
                )
            )
            .font(CambridgeTypography.uiCaption)
            .foregroundStyle(CambridgeLinenPalette.slateEditorial)

            TextEditor(text: $viewModel.bibtexImportDraft)
                .font(CambridgeTypography.monoCode)
                .frame(height: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: 1)
                )

            HStack {
                Button(localizer.L("Load Sample BibTeX", "载入示例 BibTeX")) {
                    viewModel.bibtexImportDraft = """
                    @article{higgins2003measuring,
                      title = {Measuring inconsistency in meta-analyses},
                      author = {Higgins, Julian P. T. and Thompson, Simon G.},
                      journal = {BMJ},
                      year = {2003},
                      volume = {327},
                      pages = {557--560},
                      doi = {10.1136/bmj.327.7414.557}
                    }
                    """
                }
                .buttonStyle(CambridgeSecondaryButtonStyle())

                Spacer()

                Button(localizer.L("Cancel", "取消")) { showImportSheet = false }
                    .buttonStyle(CambridgeSecondaryButtonStyle())

                Button(localizer.L("Audit & Import", "核验并导入")) {
                    viewModel.importBibliographyText(viewModel.bibtexImportDraft)
                    showImportSheet = false
                }
                .buttonStyle(CambridgePrimaryButtonStyle())
            }
        }
        .padding(18)
        .frame(width: 560)
        .background(CambridgeLinenPalette.cambridgeLinen)
        .preferredColorScheme(.light)
    }
}

// MARK: - Reusable Myers O(ND) Word-Level Track Changes Pane (`ReusableTrackChangesInspectorPane`)

/// Displays Myers $O(ND)$ word-level manuscript diffs across SQLite snapshots, per-hunk Accept/Reject actions,
/// `%DIF` `latexdiff` export source, and APA 7th exact p-value verification highlights.
public struct ReusableTrackChangesInspectorPane: View {
    @ObservedObject public var viewModel: ScholarStudioViewModel
    public let compactHeader: Bool
    @ObservedObject private var localizer = ScholarLocalizer.shared

    public init(viewModel: ScholarStudioViewModel, compactHeader: Bool = false) {
        self.viewModel = viewModel
        self.compactHeader = compactHeader
    }

    public var body: some View {
        let report = viewModel.trackChangesReport
        let hunks = viewModel.trackChangesHunks

        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localizer.L("Myers O(ND) Word-Level Track Changes", "Myers O(ND) 词级修订追踪对比"))
                        .font(CambridgeTypography.uiControlSemibold)
                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                    if let report {
                        Text(
                            localizer.L(
                                "+\(report.insertedWordCount) ins • −\(report.deletedWordCount) del • \(hunks.count) hunks",
                                "+\(report.insertedWordCount) 新增 • −\(report.deletedWordCount) 删除 • \(hunks.count) 处变更块"
                            )
                        )
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }

                Spacer(minLength: 4)

                Button(viewModel.showLatexdiffSource ? localizer.L("Word Hunks", "词级对比") : localizer.L("%DIF latexdiff", "%DIF 源码")) {
                    viewModel.showLatexdiffSource.toggle()
                }
                .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: viewModel.showLatexdiffSource))
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(10)
            .background(CambridgeLinenPalette.warmVellum)

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if viewModel.showLatexdiffSource, let report {
                        Text(report.renderLatexdiffMarkup(includeBeginEndHooks: false))
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(CambridgeLinenPalette.archivalPaper)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: 1)
                            )
                    } else {
                        // Inline Word-Span Diff Preview Card
                        if let report {
                            inlineWordDiffCard(report)
                        }

                        // Per-Hunk Accept / Reject Queue
                        ForEach(hunks.prefix(3)) { hunk in
                            trackChangeHunkCard(hunk)
                        }

                        // APA 7th Statistical p-Value Consistency Summary Card
                        if !compactHeader {
                            apaCompactSummaryCard
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private func inlineWordDiffCard(_ report: TrackChangesDiffReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(localizedSnapshotLabel(report.baselineLabel)) → \(localizedSnapshotLabel(report.revisedLabel))")
                    .font(CambridgeTypography.uiSectionLabel)
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Spacer()
                Text(
                    localizer.language == .zhHans
                        ? String(format: "相似度 %.0f%%", report.similarityRatio * 100.0)
                        : String(format: "Similarity %.0f%%", report.similarityRatio * 100.0)
                )
                .font(CambridgeTypography.monoSmall)
                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                .fixedSize(horizontal: true, vertical: false)
            }

            composedWordDiffText(Array(report.spans.prefix(24)))
                .font(.system(size: 11.5, weight: .regular, design: .serif))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cambridgeArchivalCard(padding: 10)
    }

    private func localizedSnapshotLabel(_ raw: String) -> String {
        guard localizer.language == .zhHans else { return raw }
        switch raw {
        case "v1.0 Initial Submission Draft": return "v1.0 初投稿基线"
        case "v1.2 Camera-Ready Calibration": return "v1.2 录用定稿校订"
        case "v1.0 Submission Baseline": return "v1.0 投稿基线"
        case "Working Buffer": return "当前工作区手稿"
        default: return raw
        }
    }

    private func composedWordDiffText(_ spans: [TrackChangeWordSpan]) -> Text {
        var result = Text("")
        var prevKind: TrackChangeSpanKind?
        for span in spans {
            let clean = span.text.replacingOccurrences(of: "\n", with: " ")
            let needsGap = (prevKind == .deletion && span.kind == .insertion && !clean.hasPrefix(" "))
            let prefixSpace = needsGap ? Text(" ") : Text("")
            prevKind = span.kind
            switch span.kind {
            case .equal:
                result = result + prefixSpace + Text(clean)
                    .foregroundColor(CambridgeLinenPalette.oxfordCharcoal)
            case .insertion:
                result = result + prefixSpace + Text(clean)
                    .foregroundColor(CambridgeLinenPalette.verifiedEmerald)
                    .fontWeight(.semibold)
                    .underline(true, color: CambridgeLinenPalette.verifiedEmerald)
            case .deletion:
                result = result + prefixSpace + Text(clean)
                    .foregroundColor(CambridgeLinenPalette.blockedCrimson)
                    .strikethrough(true, color: CambridgeLinenPalette.blockedCrimson)
            }
        }
        return result
    }

    private func trackChangeHunkCard(_ hunk: TrackChangeHunk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(localizer.L("Hunk @ Ln \(hunk.approximateLine)", "变更块 @ 第\(hunk.approximateLine)行"))
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer()

                Button(localizer.L("Accept", "接受")) {
                    viewModel.acceptTrackChangeHunk(hunk)
                }
                .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: true))
                .fixedSize(horizontal: true, vertical: false)

                Button(localizer.L("Reject", "拒绝")) {
                    viewModel.rejectTrackChangeHunk(hunk)
                }
                .buttonStyle(CambridgeSecondaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
            }

            if !hunk.deletedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("− " + hunk.deletedText.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.blockedCrimson)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !hunk.insertedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("+ " + hunk.insertedText.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.verifiedEmerald)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .fill(CambridgeLinenPalette.archivalPaper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
        )
    }

    private var apaCompactSummaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(localizer.L("APA 7TH EXACT p-VALUE RECALCULATOR", "APA 7th 精确 p 值重算核验器"))
                    .font(CambridgeTypography.uiSectionLabel)
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Spacer()
                Text(localizer.L("Lanczos Beta/Gamma", "Lanczos 特殊函数"))
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                    .fixedSize(horizontal: true, vertical: false)
            }

            ForEach(viewModel.apaStatRows.prefix(3)) { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(row.isConsistent ? CambridgeLinenPalette.verifiedEmerald : CambridgeLinenPalette.blockedCrimson)
                        .frame(width: 6.5, height: 6.5)

                    Text(row.reportedTuple)
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 4)

                    Text(
                        localizer.language == .zhHans
                            ? String(format: "精确 p = %.4f", row.recalculatedExactP)
                            : String(format: "Exact p = %.4f", row.recalculatedExactP)
                    )
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(row.isConsistent ? CambridgeLinenPalette.verifiedEmerald : CambridgeLinenPalette.blockedCrimson)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .cambridgeArchivalCard(padding: 9)
    }
}

// MARK: - Studio 6: JavaScriptCore Editorial & Statistical Rigor Studio (`EditorialJavaScriptAuditStudioView`)

/// Full-width `.editorialAudit` studio running the 4 built-in isolated JavaScriptCore plugins
/// (`Overclaim Detector`, `Anti-AI Prose Sanitizer`, `APA 7th Stat Checker`, `Venue Double-Blind Gate`),
/// displaying one-click scholarly rewrites, exact $t$/$F$/$\chi^2$ $p$-value recalculation, and a live JS Scratchpad.
public struct EditorialJavaScriptAuditStudioView: View {
    @ObservedObject public var viewModel: ScholarStudioViewModel
    @ObservedObject private var localizer = ScholarLocalizer.shared

    public init(viewModel: ScholarStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            editorialTopGateBar

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            HStack(spacing: 0) {
                // Left Column: 4 Built-In JS Plugin Toggles + Actionable Editorial Findings
                VStack(spacing: 0) {
                    pluginManifestStrip
                    Divider()
                        .overlay(CambridgeLinenPalette.stoneHairline)
                    findingsScrollList
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Rectangle()
                    .fill(CambridgeLinenPalette.stoneHairline)
                    .frame(width: CambridgeMetrics.hairline)

                // Right Column: APA 7th Statistical Verifier Table + Live JavaScriptCore Scratchpad
                VStack(spacing: 0) {
                    apaStatisticalTableSection
                    Divider()
                        .overlay(CambridgeLinenPalette.stoneHairline)
                    jsScratchpadSection
                }
                .frame(width: 508)
                .background(CambridgeLinenPalette.cambridgeLinen)
            }
        }
        .background(CambridgeLinenPalette.cambridgeLinen)
    }

    private var editorialTopGateBar: some View {
        let summary = viewModel.editorialRunSummary
        let blockers = summary?.blockerCount ?? 0
        let warnings = summary?.rigorWarningCount ?? 0
        let styles = summary?.styleSuggestionCount ?? 0
        let elapsed = summary?.totalElapsedMs ?? 4.2

        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "curlybraces.square.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Text(localizer.L("Sandboxed JavaScriptCore Editorial & APA 7th Studio", "JavaScriptCore 隔离沙盒审稿与统计核验台"))
                    .font(CambridgeTypography.scholarlyHeadline)
                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text(
                blockers == 0
                    ? localizer.L("GATE: CAMERA-READY", "门禁: 允许定稿")
                    : localizer.L("GATE: HOLD (\(blockers) BLOCKERS)", "门禁: 阻断 (\(blockers) 项违规)")
            )
            .font(CambridgeTypography.monoSmall)
            .foregroundStyle(blockers == 0 ? CambridgeLinenPalette.verifiedEmerald : CambridgeLinenPalette.blockedCrimson)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(blockers == 0 ? CambridgeLinenPalette.verifiedEmeraldBg : CambridgeLinenPalette.blockedCrimsonBg)
            )
            .fixedSize(horizontal: true, vertical: false)

            Text(
                localizer.language == .zhHans
                    ? String(format: "%d 严谨性 • %d 文风 • %.1f ms", warnings, styles, elapsed)
                    : "\(warnings) Rigor • \(styles) Style • \(String(format: "%.1f ms", elapsed))"
            )
            .font(CambridgeTypography.monoSmall)
            .foregroundStyle(CambridgeLinenPalette.slateEditorial)
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            ForEach(EditorialVenueAuditMode.allCases) { mode in
                Button(shortVenueModeLabel(mode)) {
                    viewModel.preferences.venueAuditMode = mode
                    viewModel.runEditorialPluginSuite()
                }
                .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: viewModel.preferences.venueAuditMode == mode))
                .fixedSize(horizontal: true, vertical: false)
            }

            Button {
                viewModel.runEditorialPluginSuite()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                    Text(localizer.L("Run 4 JS Plugins", "运行 4 款插件"))
                }
            }
            .buttonStyle(CambridgePrimaryButtonStyle())
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CambridgeLinenPalette.warmVellum)
    }

    private func shortVenueModeLabel(_ mode: EditorialVenueAuditMode) -> String {
        switch mode {
        case .doubleBlindSubmission: return localizer.L("Double-Blind", "双盲投稿")
        case .cameraReady: return localizer.L("Camera-Ready", "录用定稿")
        case .preprintDraft: return localizer.L("Preprint", "预印本")
        }
    }

    private var pluginManifestStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.preferences.pluginManifests) { plugin in
                    let ms = viewModel.perPluginTimingsMs[plugin.id] ?? 0.8
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { plugin.isEnabled },
                                    set: { _ in
                                        viewModel.preferences.togglePluginEnabled(id: plugin.id)
                                        viewModel.syncPluginsToDatabase(viewModel.preferences.pluginManifests)
                                    }
                                )
                            )
                            .labelsHidden()
                            .controlSize(.mini)

                            Text(plugin.localizedName(localizer.language))
                                .font(CambridgeTypography.uiControlSemibold)
                                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                .fixedSize(horizontal: true, vertical: false)

                            Spacer(minLength: 4)

                            Text(String(format: "%.2fms", ms))
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        Text(
                            localizer.L(
                                "JSVirtualMachine • \(plugin.capabilities.count) capabilities",
                                "独立 JSVirtualMachine • \(plugin.capabilities.count) 项能力授权"
                            )
                        )
                        .font(CambridgeTypography.uiCaption)
                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .fill(CambridgeLinenPalette.archivalPaper)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                            .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(CambridgeLinenPalette.cambridgeLinen)
    }

    private var findingsScrollList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.editorialFindings) { finding in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            EditorialSeverityPill(severity: finding.severity, compact: true)
                                .fixedSize(horizontal: true, vertical: false)

                            Text(finding.localizedCategory(localizer.language))
                                .font(CambridgeTypography.uiControlSemibold)
                                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)

                            Text("\(finding.filePath):\(finding.line)")
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                .fixedSize(horizontal: true, vertical: false)

                            Spacer(minLength: 4)

                            if finding.suggestedRewrite != nil {
                                Button(localizer.L("Apply Scholarly Rewrite", "应用学术改写建议")) {
                                    viewModel.applyEditorialRewrite(finding)
                                }
                                .buttonStyle(CambridgePrimaryButtonStyle())
                                .fixedSize(horizontal: true, vertical: false)
                            }
                        }

                        Text(finding.localizedExplanation(localizer.language))
                            .font(CambridgeTypography.uiCaption)
                            .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Text("− \(finding.matchedExcerpt)")
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.blockedCrimson)
                                .fixedSize(horizontal: false, vertical: true)

                            if let rewrite = finding.suggestedRewrite {
                                Text("→ + \(rewrite)")
                                    .font(CambridgeTypography.monoSmall)
                                    .foregroundStyle(CambridgeLinenPalette.verifiedEmerald)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(CambridgeLinenPalette.cambridgeLinen)
                        )
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                            .fill(CambridgeLinenPalette.archivalPaper)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                            .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                    )
                }
            }
            .padding(12)
        }
    }

    private var apaStatisticalTableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localizer.L("APA 7TH HYPOTHESIS-TEST p-VALUE RECALCULATOR", "APA 7th 假设检验 p 值精确重算表"))
                    .font(CambridgeTypography.uiSectionLabel)
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Spacer()
                Text(localizer.L("Incomplete Beta & Gamma", "不完全 Beta 与 Gamma"))
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                    .fixedSize(horizontal: true, vertical: false)
            }

            ForEach(viewModel.apaStatRows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.isConsistent ? localizer.L("PASS", "核验通过") : localizer.L("MISMATCH", "显著性矛盾"))
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(row.isConsistent ? CambridgeLinenPalette.verifiedEmerald : CambridgeLinenPalette.blockedCrimson)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .fill(row.isConsistent ? CambridgeLinenPalette.verifiedEmeraldBg : CambridgeLinenPalette.blockedCrimsonBg)
                            )
                            .fixedSize(horizontal: true, vertical: false)

                        Text(row.reportedTuple)
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 4)

                        Text(
                            localizer.language == .zhHans
                                ? String(format: "精确 p = %.4f", row.recalculatedExactP)
                                : String(format: "Exact p = %.4f", row.recalculatedExactP)
                        )
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    Text(localizedAPADiagnostic(row))
                        .font(CambridgeTypography.uiCaption)
                        .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(CambridgeLinenPalette.archivalPaper)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                )
            }
        }
        .padding(12)
    }

    private func localizedAPADiagnostic(_ row: APAStatVerificationRow) -> String {
        guard localizer.language == .zhHans else { return row.diagnosticSummary }
        switch row.id {
        case "stat-t-discrepancy":
            return String(format: "数值矛盾：重算精确双尾 p = %.4f，正文报告的 p = .001 夸大了统计显著性。", row.recalculatedExactP)
        case "stat-f-consistent":
            return String(format: "核验一致：不完全 Beta 函数 I_x 重算精确 p = %.4f，与 APA 7th 元组吻合。", row.recalculatedExactP)
        case "stat-chi2-consistent":
            return String(format: "核验一致：正则化上不完全 Gamma 函数 Q(k/2, χ²/2) 重算精确 p = %.4f。", row.recalculatedExactP)
        case "stat-t-strong":
            return String(format: "核验一致：重算精确 p = %.5f，满足 APA 7th p < .001 报告阈值。", row.recalculatedExactP)
        default:
            return row.diagnosticSummary
        }
    }

    private var jsScratchpadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localizer.L("INTERACTIVE JAVASCRIPTCORE SCRATCHPAD", "交互式 JAVASCRIPTCORE 插件演练场"))
                    .font(CambridgeTypography.uiSectionLabel)
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Spacer()
                Button(localizer.L("Evaluate JS", "执行脚本")) {
                    viewModel.evaluateScratchpadJS()
                }
                .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: true))
                .fixedSize(horizontal: true, vertical: false)
            }

            TextEditor(text: $viewModel.jsScratchpadSource)
                .font(CambridgeTypography.monoSmall)
                .frame(height: 86)
                .padding(4)
                .background(CambridgeLinenPalette.archivalPaper)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: 1)
                )

            if let out = viewModel.jsScratchpadOutput {
                VStack(alignment: .leading, spacing: 3) {
                    Text(out.statusSummary)
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(out.isSuccess ? CambridgeLinenPalette.verifiedEmerald : CambridgeLinenPalette.blockedCrimson)
                    ForEach(out.consoleLogs.prefix(3)) { log in
                        Text(log.formattedLine)
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let err = out.errorMessage {
                        Text(err)
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.blockedCrimson)
                    }
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(CambridgeLinenPalette.archivalPaper)
                )
            }

            Spacer(minLength: 0)
        }
        .padding(12)
    }
}
