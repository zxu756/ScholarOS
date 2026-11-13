import SwiftUI
import AppKit
import ScholarModels

// MARK: - Cambridge Linen & Library Forest Green Design System (`CambridgeLinenPalette`)

/// Canonical archival color tokens for the ScholarOS macOS research workstation.
///
/// Strictly enforces light-first **Cambridge Linen (`#F8F6F0`)**, **Pure Archival Paper (`#FFFFFF`)**,
/// **Warm Vellum (`#F1EEE6`)**, **Stone Hairline (`#DEDAD0`)**, **Oxford Charcoal (`#191B1A`)**,
/// and **Library Forest Green (`#1D4D3E`)** — zero dark-mode neon, zero glassmorphism.
public enum CambridgeLinenPalette {
    // MARK: Surface Hierarchy
    /// Primary canvas background — Cambridge Linen `#F8F6F0`
    public static let cambridgeLinen = Color(red: 0xF8 / 255.0, green: 0xF6 / 255.0, blue: 0xF0 / 255.0)
    /// Elevated editor well & archival card surface — Pure Archival Paper `#FFFFFF`
    public static let archivalPaper = Color(red: 1.0, green: 1.0, blue: 1.0)
    /// Secondary navigator & structural chrome — Warm Vellum `#F1EEE6`
    public static let warmVellum = Color(red: 0xF1 / 255.0, green: 0xEE / 255.0, blue: 0xE6 / 255.0)
    /// Interactive hover / active row vellum — Aged Vellum `#EAE6DC`
    public static let hoverVellum = Color(red: 0xEA / 255.0, green: 0xE6 / 255.0, blue: 0xDC / 255.0)
    /// Subtle code/excerpt well background — Parchment Well `#F5F3EC`
    public static let parchmentWell = Color(red: 0xF5 / 255.0, green: 0xF3 / 255.0, blue: 0xEC / 255.0)

    // MARK: Borders & Hairlines
    /// Crisp `1pt` structural divider — Stone Hairline `#DEDAD0`
    public static let stoneHairline = Color(red: 0xDE / 255.0, green: 0xDA / 255.0, blue: 0xD0 / 255.0)
    /// Emphasized card border on focus/hover — Deep Stone `#C8C2B4`
    public static let deepStoneBorder = Color(red: 0xC8 / 255.0, green: 0xC2 / 255.0, blue: 0xB4 / 255.0)

    // MARK: Editorial Inks
    /// Primary manuscript & heading ink — Oxford Charcoal `#191B1A`
    public static let oxfordCharcoal = Color(red: 0x19 / 255.0, green: 0x1B / 255.0, blue: 0x1A / 255.0)
    /// Secondary UI & prose summary ink — Slate Editorial `#5A605D`
    public static let slateEditorial = Color(red: 0x5A / 255.0, green: 0x60 / 255.0, blue: 0x5D / 255.0)
    /// Tertiary captions, timestamps & line gutters — Muted Metadata `#7A807C`
    public static let mutedMetadata = Color(red: 0x7A / 255.0, green: 0x80 / 255.0, blue: 0x7C / 255.0)

    // MARK: Primary Brand Accent
    /// Active selection pills, primary buttons & section numbers — Library Forest Green `#1D4D3E`
    public static let libraryForestGreen = Color(red: 0x1D / 255.0, green: 0x4D / 255.0, blue: 0x3E / 255.0)
    /// Pressed state for primary accent — Deep Bodleian Pine `#153A2E`
    public static let libraryForestPressed = Color(red: 0x15 / 255.0, green: 0x3A / 255.0, blue: 0x2E / 255.0)
    /// Soft selection background tint — Cambridge Sage Tint `#E6EFEA`
    public static let libraryForestTint = Color(red: 0xE6 / 255.0, green: 0xEF / 255.0, blue: 0xEA / 255.0)
    /// Subtle hairline border for forest-tinted badges — `#BDD3C9`
    public static let libraryForestBorder = Color(red: 0xBD / 255.0, green: 0xD3 / 255.0, blue: 0xC9 / 255.0)

    // MARK: Semantic Verification & Firewall Tokens
    /// Verified / Grounded Entailment foreground — Verified Emerald `#1F6E4A`
    public static let verifiedEmerald = Color(red: 0x1F / 255.0, green: 0x6E / 255.0, blue: 0x4A / 255.0)
    /// Verified Emerald pill fill — `#E8F5EE`
    public static let verifiedEmeraldBg = Color(red: 0xE8 / 255.0, green: 0xF5 / 255.0, blue: 0xEE / 255.0)
    /// Verified Emerald pill border — `#BBE0CD`
    public static let verifiedEmeraldBorder = Color(red: 0xBB / 255.0, green: 0xE0 / 255.0, blue: 0xCD / 255.0)

    /// Verified Preprint / Style Advisory foreground — Preprint Ochre `#9A6700`
    public static let preprintOchre = Color(red: 0x9A / 255.0, green: 0x67 / 255.0, blue: 0x00 / 255.0)
    /// Preprint Ochre pill fill — `#FEF6E4`
    public static let preprintOchreBg = Color(red: 0xFE / 255.0, green: 0xF6 / 255.0, blue: 0xE4 / 255.0)
    /// Preprint Ochre pill border — `#F0D699`
    public static let preprintOchreBorder = Color(red: 0xF0 / 255.0, green: 0xD6 / 255.0, blue: 0x99 / 255.0)

    /// Metadata Drift / Rigor Warning foreground — Metadata Drift Amber `#B54708`
    public static let driftAmber = Color(red: 0xB5 / 255.0, green: 0x47 / 255.0, blue: 0x08 / 255.0)
    /// Metadata Drift Amber pill fill — `#FFF1E6`
    public static let driftAmberBg = Color(red: 0xFF / 255.0, green: 0xF1 / 255.0, blue: 0xE6 / 255.0)
    /// Metadata Drift Amber pill border — `#F6C8A8`
    public static let driftAmberBorder = Color(red: 0xF6 / 255.0, green: 0xC8 / 255.0, blue: 0xA8 / 255.0)

    /// Firewall Blocked / Submission Blocker foreground — Firewall Blocked Crimson `#B42318`
    public static let blockedCrimson = Color(red: 0xB4 / 255.0, green: 0x23 / 255.0, blue: 0x18 / 255.0)
    /// Firewall Blocked Crimson pill fill — `#FEECEB`
    public static let blockedCrimsonBg = Color(red: 0xFE / 255.0, green: 0xEC / 255.0, blue: 0xEB / 255.0)
    /// Firewall Blocked Crimson pill border — `#F5B7B2`
    public static let blockedCrimsonBorder = Color(red: 0xF5 / 255.0, green: 0xB7 / 255.0, blue: 0xB2 / 255.0)

    // MARK: AppKit NSColor Counterparts (for NSTextView / NSSplitView integration)
    public static let nsCambridgeLinen = NSColor(srgbRed: 0xF8 / 255.0, green: 0xF6 / 255.0, blue: 0xF0 / 255.0, alpha: 1.0)
    public static let nsArchivalPaper = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    public static let nsWarmVellum = NSColor(srgbRed: 0xF1 / 255.0, green: 0xEE / 255.0, blue: 0xE6 / 255.0, alpha: 1.0)
    public static let nsStoneHairline = NSColor(srgbRed: 0xDE / 255.0, green: 0xDA / 255.0, blue: 0xD0 / 255.0, alpha: 1.0)
    public static let nsOxfordCharcoal = NSColor(srgbRed: 0x19 / 255.0, green: 0x1B / 255.0, blue: 0x1A / 255.0, alpha: 1.0)
    public static let nsLibraryForestGreen = NSColor(srgbRed: 0x1D / 255.0, green: 0x4D / 255.0, blue: 0x3E / 255.0, alpha: 1.0)

    // MARK: Semantic Token Triples

    public struct SemanticBadgeStyle: Sendable {
        public let foreground: Color
        public let background: Color
        public let border: Color
        public let sfSymbol: String

        public init(foreground: Color, background: Color, border: Color, sfSymbol: String) {
            self.foreground = foreground
            self.background = background
            self.border = border
            self.sfSymbol = sfSymbol
        }
    }

    public static func style(for firewallClass: CitationFirewallClass) -> SemanticBadgeStyle {
        switch firewallClass {
        case .verified:
            return SemanticBadgeStyle(
                foreground: verifiedEmerald,
                background: verifiedEmeraldBg,
                border: verifiedEmeraldBorder,
                sfSymbol: "checkmark.seal.fill"
            )
        case .drift:
            return SemanticBadgeStyle(
                foreground: driftAmber,
                background: driftAmberBg,
                border: driftAmberBorder,
                sfSymbol: "exclamationmark.triangle.fill"
            )
        case .unverified:
            return SemanticBadgeStyle(
                foreground: slateEditorial,
                background: warmVellum,
                border: stoneHairline,
                sfSymbol: "questionmark.circle"
            )
        case .notFound:
            return SemanticBadgeStyle(
                foreground: blockedCrimson,
                background: blockedCrimsonBg,
                border: blockedCrimsonBorder,
                sfSymbol: "xmark.octagon.fill"
            )
        case .retracted:
            return SemanticBadgeStyle(
                foreground: blockedCrimson,
                background: blockedCrimsonBg,
                border: blockedCrimsonBorder,
                sfSymbol: "exclamationmark.octagon.fill"
            )
        }
    }

    public static func style(for severity: EditorialSeverity) -> SemanticBadgeStyle {
        switch severity {
        case .note:
            return SemanticBadgeStyle(
                foreground: slateEditorial,
                background: warmVellum,
                border: stoneHairline,
                sfSymbol: "info.circle"
            )
        case .styleSuggestion:
            return SemanticBadgeStyle(
                foreground: preprintOchre,
                background: preprintOchreBg,
                border: preprintOchreBorder,
                sfSymbol: "pencil.and.outline"
            )
        case .rigorWarning:
            return SemanticBadgeStyle(
                foreground: driftAmber,
                background: driftAmberBg,
                border: driftAmberBorder,
                sfSymbol: "exclamationmark.triangle.fill"
            )
        case .submissionBlocker:
            return SemanticBadgeStyle(
                foreground: blockedCrimson,
                background: blockedCrimsonBg,
                border: blockedCrimsonBorder,
                sfSymbol: "hand.raised.fill"
            )
        }
    }

    public static func style(for diagnosticSeverity: LSPDiagnosticSeverity) -> SemanticBadgeStyle {
        switch diagnosticSeverity {
        case .hint:
            return SemanticBadgeStyle(
                foreground: mutedMetadata,
                background: warmVellum,
                border: stoneHairline,
                sfSymbol: "lightbulb"
            )
        case .info:
            return SemanticBadgeStyle(
                foreground: libraryForestGreen,
                background: libraryForestTint,
                border: libraryForestBorder,
                sfSymbol: "info.circle.fill"
            )
        case .warning:
            return SemanticBadgeStyle(
                foreground: driftAmber,
                background: driftAmberBg,
                border: driftAmberBorder,
                sfSymbol: "exclamationmark.triangle.fill"
            )
        case .error:
            return SemanticBadgeStyle(
                foreground: blockedCrimson,
                background: blockedCrimsonBg,
                border: blockedCrimsonBorder,
                sfSymbol: "xmark.circle.fill"
            )
        }
    }

    /// Normalizes SF Symbol names (e.g., `"Highlighter"` -> `"highlighter"`) so AppKit/SwiftUI never drops icons.
    public static func resolvedSymbolName(for rawSymbol: String) -> String {
        if NSImage(systemSymbolName: rawSymbol, accessibilityDescription: nil) != nil {
            return rawSymbol
        }
        let lower = rawSymbol.lowercased()
        if NSImage(systemSymbolName: lower, accessibilityDescription: nil) != nil {
            return lower
        }
        return "doc.text"
    }
}

// MARK: - Spatial Metrics & Typography (`CambridgeMetrics`, `CambridgeTypography`)

public enum CambridgeMetrics {
    public static let hairline: CGFloat = 1.0
    public static let cornerRadiusSmall: CGFloat = 6.0
    public static let cornerRadiusCard: CGFloat = 8.0
    public static let spacingXS: CGFloat = 4.0
    public static let spacingSM: CGFloat = 8.0
    public static let spacingMD: CGFloat = 12.0
    public static let spacingLG: CGFloat = 16.0
    public static let spacingXL: CGFloat = 24.0
}

/// Typographic hierarchy pairing scholarly serif headings, crisp UI controls, and tabular monospaced figures.
public enum CambridgeTypography {
    public static let scholarlyTitle = Font.system(.title3, design: .serif).weight(.semibold)
    public static let scholarlyHeadline = Font.system(.headline, design: .serif).weight(.semibold)
    public static let scholarlyDisplay = Font.system(size: 20, weight: .semibold, design: .serif)

    public static let uiControl = Font.system(size: 12.5, weight: .regular, design: .default)
    public static let uiControlMedium = Font.system(size: 12.5, weight: .medium, design: .default)
    public static let uiControlSemibold = Font.system(size: 12.5, weight: .semibold, design: .default)
    public static let uiSectionLabel = Font.system(size: 11, weight: .semibold, design: .default)
    public static let uiCaption = Font.system(size: 11.5, weight: .regular, design: .default)

    public static let monoCode = Font.system(size: 12, weight: .regular, design: .monospaced).monospacedDigit()
    public static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit()
    public static let monoMetricValue = Font.system(size: 17, weight: .semibold, design: .monospaced).monospacedDigit()
    public static let monoKeycap = Font.system(size: 10.5, weight: .semibold, design: .monospaced).monospacedDigit()
}

// MARK: - Reusable Archival Components (`ScholarLanguageTogglePill`, `FirewallBadgeView`, `EditorialSeverityPill`, `ScholarMetricCard`)

/// Crisp Cambridge-Linen (`#F8F6F0`) & Library-Forest-Green (`#1D4D3E`) `中文 | EN` segmented language toggle pill.
public struct ScholarLanguageTogglePill: View {
    @ObservedObject public var localizer: ScholarLocalizer

    public init(localizer: ScholarLocalizer = .shared) {
        self.localizer = localizer
    }

    public var body: some View {
        HStack(spacing: 2) {
            segmentButton(for: .zhHans)
            segmentButton(for: .en)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .fill(CambridgeLinenPalette.cambridgeLinen)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
        )
        .fixedSize(horizontal: true, vertical: false)
        .help(localizer.L("Toggle Language: 中文 / EN (⇧⌘L)", "切换界面语言：中文 / EN (⇧⌘L)"))
    }

    private func segmentButton(for target: ScholarLanguage) -> some View {
        let isActive = (localizer.language == target)
        return Button {
            localizer.setLanguage(target)
        } label: {
            Text(target.badge)
                .font(.system(size: 11.5, weight: isActive ? .semibold : .medium, design: .default))
                .tracking(0)
                .foregroundStyle(isActive ? CambridgeLinenPalette.archivalPaper : CambridgeLinenPalette.slateEditorial)
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(isActive ? CambridgeLinenPalette.libraryForestGreen : Color.clear)
                )
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }
}

/// Crisp 5-class Citation Verification Firewall badge with semantic emerald/ochre/amber/crimson colors.
public struct FirewallBadgeView: View {
    public let firewallClass: CitationFirewallClass
    public let compact: Bool
    @ObservedObject private var localizer: ScholarLocalizer = .shared

    public init(firewallClass: CitationFirewallClass, compact: Bool = false) {
        self.firewallClass = firewallClass
        self.compact = compact
    }

    private var shortTitle: String {
        firewallClass.localizedBadgeTitle(localizer.language)
    }

    public var body: some View {
        let token = CambridgeLinenPalette.style(for: firewallClass)
        HStack(spacing: 4) {
            Image(systemName: token.sfSymbol)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
            Text(shortTitle)
                .font(compact ? CambridgeTypography.uiSectionLabel : CambridgeTypography.uiControlMedium)
                .tracking(0)
        }
        .foregroundStyle(token.foreground)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2.5 : 3.5)
        .background(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .fill(token.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .strokeBorder(token.border, lineWidth: CambridgeMetrics.hairline)
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Crisp status pill for `EditorialSeverity` findings (`NOTE`, `STYLE`, `RIGOR_WARN`, `SUBMISSION_BLOCKER`).
public struct EditorialSeverityPill: View {
    public let severity: EditorialSeverity
    public let compact: Bool
    @ObservedObject private var localizer: ScholarLocalizer = .shared

    public init(severity: EditorialSeverity, compact: Bool = false) {
        self.severity = severity
        self.compact = compact
    }

    public var displayLabel: String {
        switch severity {
        case .note:
            return localizer.L("Note", "提示")
        case .styleSuggestion:
            return compact
                ? localizer.L("Style", "文风")
                : localizer.L("Style Suggestion", "文风建议")
        case .rigorWarning:
            return compact
                ? localizer.L("Rigor Warn", "严谨警告")
                : localizer.L("Rigor Warning", "严谨性警告")
        case .submissionBlocker:
            return compact
                ? localizer.L("Blocker", "投稿阻断")
                : localizer.L("Submission Blocker", "投稿阻断")
        }
    }

    public var body: some View {
        let token = CambridgeLinenPalette.style(for: severity)
        HStack(spacing: 4) {
            Image(systemName: token.sfSymbol)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
            Text(displayLabel)
                .font(CambridgeTypography.uiSectionLabel)
                .tracking(0)
        }
        .foregroundStyle(token.foreground)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2.5 : 3.5)
        .background(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .fill(token.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .strokeBorder(token.border, lineWidth: CambridgeMetrics.hairline)
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Crisp status badge for `LSPDiagnosticSeverity`.
public struct LSPDiagnosticSeverityBadge: View {
    public let severity: LSPDiagnosticSeverity
    @ObservedObject private var localizer: ScholarLocalizer = .shared

    public init(severity: LSPDiagnosticSeverity) {
        self.severity = severity
    }

    public var body: some View {
        let token = CambridgeLinenPalette.style(for: severity)
        HStack(spacing: 4) {
            Image(systemName: token.sfSymbol)
                .font(.system(size: 10, weight: .semibold))
            Text(severity.localizedLabel(localizer.language))
                .font(localizer.language == .zhHans ? CambridgeTypography.uiSectionLabel : CambridgeTypography.monoKeycap)
                .tracking(0)
        }
        .foregroundStyle(token.foreground)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .fill(token.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .strokeBorder(token.border, lineWidth: CambridgeMetrics.hairline)
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Archival Pure Paper telemetry card displaying a primary monospaced figure, title, and semantic subtitle.
public struct ScholarMetricCard: View {
    public let title: String
    public let monospacedValue: String
    public let subtitle: String
    public let sfSymbol: String
    public let accentColor: Color

    public init(
        title: String,
        monospacedValue: String,
        subtitle: String,
        sfSymbol: String = "chart.bar.doc.horizontal",
        accentColor: Color = CambridgeLinenPalette.libraryForestGreen
    ) {
        self.title = title
        self.monospacedValue = monospacedValue
        self.subtitle = subtitle
        self.sfSymbol = sfSymbol
        self.accentColor = accentColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: CambridgeLinenPalette.resolvedSymbolName(for: sfSymbol))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(CambridgeTypography.uiSectionLabel)
                    .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                Spacer(minLength: 4)
            }

            Text(monospacedValue)
                .font(CambridgeTypography.monoMetricValue)
                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                .fixedSize(horizontal: true, vertical: false)

            Text(subtitle)
                .font(CambridgeTypography.uiCaption)
                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Scholarly serif section header with optional monospaced count badge and trailing action view.
public struct CambridgeSectionHeader<TrailingContent: View>: View {
    public let title: String
    public let subtitle: String?
    public let countBadge: Int?
    private let trailingContent: TrailingContent

    public init(
        title: String,
        subtitle: String? = nil,
        countBadge: Int? = nil,
        @ViewBuilder trailing: () -> TrailingContent
    ) {
        self.title = title
        self.subtitle = subtitle
        self.countBadge = countBadge
        self.trailingContent = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(CambridgeTypography.scholarlyHeadline)
                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                    if let countBadge {
                        Text("\(countBadge)")
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(CambridgeLinenPalette.libraryForestTint)
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(CambridgeLinenPalette.libraryForestBorder, lineWidth: CambridgeMetrics.hairline)
                            )
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(CambridgeTypography.uiCaption)
                        .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                }
            }
            Spacer(minLength: 8)
            trailingContent
        }
    }
}

public extension CambridgeSectionHeader where TrailingContent == EmptyView {
    init(title: String, subtitle: String? = nil, countBadge: Int? = nil) {
        self.init(title: title, subtitle: subtitle, countBadge: countBadge) {
            EmptyView()
        }
    }
}

/// Monospaced hardware keyboard shortcut keycap pill (`⌘K`, `⇧⌘Z`, `⌘,`).
public struct ScholarKeycapBadge: View {
    public let keys: String

    public init(_ keys: String) {
        self.keys = keys
    }

    public var body: some View {
        Text(keys)
            .font(CambridgeTypography.monoKeycap)
            .foregroundStyle(CambridgeLinenPalette.slateEditorial)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(CambridgeLinenPalette.warmVellum)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
            )
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Button & Card Styles

/// Primary Library Forest Green `#1D4D3E` action button style.
public struct CambridgePrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CambridgeTypography.uiControlSemibold)
            .foregroundStyle(CambridgeLinenPalette.archivalPaper)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                    .fill(configuration.isPressed
                          ? CambridgeLinenPalette.libraryForestPressed
                          : CambridgeLinenPalette.libraryForestGreen)
            )
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Secondary Archival Paper `#FFFFFF` button with `1pt` Stone Hairline `#DEDAD0` border.
public struct CambridgeSecondaryButtonStyle: ButtonStyle {
    public var isSelected: Bool

    public init(isSelected: Bool = false) {
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isSelected ? CambridgeTypography.uiControlSemibold : CambridgeTypography.uiControlMedium)
            .foregroundStyle(isSelected ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.oxfordCharcoal)
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .background(
                RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                    .fill(configuration.isPressed
                          ? CambridgeLinenPalette.hoverVellum
                          : (isSelected ? CambridgeLinenPalette.libraryForestTint : CambridgeLinenPalette.archivalPaper))
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
}

/// View modifier framing any panel as an archival Pure Paper card on Cambridge Linen.
public struct CambridgeArchivalCardModifier: ViewModifier {
    public let paddingAmount: CGFloat
    public let cornerRadius: CGFloat

    public init(paddingAmount: CGFloat = 12, cornerRadius: CGFloat = CambridgeMetrics.cornerRadiusCard) {
        self.paddingAmount = paddingAmount
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .padding(paddingAmount)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(CambridgeLinenPalette.archivalPaper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
            )
    }
}

public extension View {
    func cambridgeArchivalCard(
        padding: CGFloat = 12,
        cornerRadius: CGFloat = CambridgeMetrics.cornerRadiusCard
    ) -> some View {
        modifier(CambridgeArchivalCardModifier(paddingAmount: padding, cornerRadius: cornerRadius))
    }
}
