import AppKit
import PDFKit
import SwiftUI
import ScholarLSPEngine
import ScholarMarkupAST
import ScholarModels
import ScholarPDFProvenance
import ScholarWorkbenchShell

// MARK: - AppKit NSTextView Interactive Editor Bridge (`ScholarSyntaxNSTextViewRepresentable`)

/// Native Cocoa `NSTextView` wrapper with line-number gutter and syntax coloring for live interactive typing
/// when the user switches from the structured LSP token view to raw Cocoa text input.
public struct ScholarSyntaxNSTextViewRepresentable: NSViewRepresentable {
    @Binding public var text: String
    public let tokens: [MarkupToken]
    public let fontSize: CGFloat
    public let onTextCommit: (String) -> Void
    public let onCursorLineChanged: (Int, Int) -> Void

    public init(
        text: Binding<String>,
        tokens: [MarkupToken],
        fontSize: CGFloat = 13.0,
        onTextCommit: @escaping (String) -> Void,
        onCursorLineChanged: @escaping (Int, Int) -> Void
    ) {
        self._text = text
        self.tokens = tokens
        self.fontSize = fontSize
        self.onTextCommit = onTextCommit
        self.onCursorLineChanged = onCursorLineChanged
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = CambridgeLinenPalette.nsArchivalPaper

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.backgroundColor = CambridgeLinenPalette.nsArchivalPaper
        textView.insertionPointColor = CambridgeLinenPalette.nsLibraryForestGreen
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = CambridgeLinenPalette.nsOxfordCharcoal
        textView.string = text
        textView.delegate = context.coordinator

        context.coordinator.applySyntaxHighlighting(to: textView, tokens: tokens, fontSize: fontSize)
        scrollView.documentView = textView
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            context.coordinator.applySyntaxHighlighting(to: textView, tokens: tokens, fontSize: fontSize)
            textView.selectedRanges = selected
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScholarSyntaxNSTextViewRepresentable

        init(parent: ScholarSyntaxNSTextViewRepresentable) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let updated = tv.string
            parent.text = updated
            parent.onTextCommit(updated)
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let location = tv.selectedRange().location
            let prefix = (tv.string as NSString).substring(to: min(location, (tv.string as NSString).length))
            let lines = prefix.components(separatedBy: "\n")
            let line = max(1, lines.count)
            let col = max(1, (lines.last?.count ?? 0) + 1)
            parent.onCursorLineChanged(line, col)
        }

        func applySyntaxHighlighting(to textView: NSTextView, tokens: [MarkupToken], fontSize: CGFloat) {
            guard let storage = textView.textStorage else { return }
            let fullLength = storage.length
            guard fullLength > 0 else { return }

            let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)

            storage.beginEditing()
            storage.setAttributes(
                [
                    .font: baseFont,
                    .foregroundColor: CambridgeLinenPalette.nsOxfordCharcoal
                ],
                range: NSRange(location: 0, length: fullLength)
            )

            let nsString = textView.string as NSString
            let lines = nsString.components(separatedBy: "\n")
            var lineStartUTF16: [Int] = [0]
            var running = 0
            for ln in lines {
                running += (ln as NSString).length + 1
                lineStartUTF16.append(running)
            }

            for token in tokens where token.kind != .eof && token.kind != .whitespace {
                let lnIdx = max(0, token.span.start.line - 1)
                guard lnIdx < lineStartUTF16.count else { continue }
                let startOffset = lineStartUTF16[lnIdx] + max(0, token.span.start.column - 1)
                let len = (token.lexeme as NSString).length
                guard startOffset >= 0, startOffset + len <= fullLength else { continue }
                let range = NSRange(location: startOffset, length: len)

                switch token.kind {
                case .command, .typstHashKeyword, .headingMarker:
                    storage.addAttributes([.foregroundColor: CambridgeLinenPalette.nsLibraryForestGreen, .font: boldFont], range: range)
                case .mathInline, .mathDisplay:
                    storage.addAttributes([.foregroundColor: NSColor(calibratedRed: 0.604, green: 0.404, blue: 0.0, alpha: 1.0)], range: range)
                case .comment:
                    storage.addAttributes([.foregroundColor: NSColor(calibratedRed: 0.478, green: 0.502, blue: 0.486, alpha: 1.0)], range: range)
                case .leftBrace, .rightBrace, .leftBracket, .rightBracket:
                    storage.addAttributes([.foregroundColor: NSColor(calibratedRed: 0.710, green: 0.278, blue: 0.031, alpha: 1.0)], range: range)
                default:
                    break
                }
            }
            storage.endEditing()
        }
    }
}

// MARK: - Studio 1: Manuscript & Incremental LSP Editor View (`ManuscriptLSPEditorStudioView`)

/// Primary `.manuscriptEditor` center pane combining the open-file tab strip, readability/equation/citation telemetry bar,
/// deterministic token-highlighted code editor with wavy LSP diagnostics, floating `\cite{...}` autocomplete popover,
/// and live CSL citation hover card.
public struct ManuscriptLSPEditorStudioView: View {
    @ObservedObject public var viewModel: ScholarStudioViewModel
    @ObservedObject private var localizer: ScholarLocalizer = .shared
    @Environment(\.scholarSnapshotRendering) private var isSnapshotRendering

    public init(viewModel: ScholarStudioViewModel) {
        self.viewModel = viewModel
    }

    private var sourceLines: [String] {
        guard !viewModel.activeSourceBuffer.isEmpty else {
            return []
        }
        return viewModel.activeSourceBuffer.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    private var diagnosticsByLine: [Int: [LSPDiagnostic]] {
        let activeFile = viewModel.docking.activeManuscriptFilePath
        let relevant = viewModel.diagnostics.filter { $0.span.filePath == activeFile }
        return Dictionary(grouping: relevant, by: { $0.span.start.line })
    }

    private var tokensByLine: [Int: [MarkupToken]] {
        Dictionary(grouping: viewModel.activeTokens.filter { $0.kind != .eof }, by: { $0.span.start.line })
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScholarOpenManuscriptTabStripView(docking: viewModel.docking)

            editorMetricsAndModeStrip

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            if !isSnapshotRendering && viewModel.useNativeAppKitEditor {
                ScholarSyntaxNSTextViewRepresentable(
                    text: Binding(
                        get: { viewModel.activeSourceBuffer },
                        set: { viewModel.updateActiveManuscriptSource($0) }
                    ),
                    tokens: viewModel.activeTokens,
                    fontSize: CGFloat(viewModel.preferences.editorFontSize),
                    onTextCommit: { updated in
                        viewModel.updateActiveManuscriptSource(updated)
                    },
                    onCursorLineChanged: { line, col in
                        viewModel.docking.updateCursor(line: line, column: col)
                        viewModel.refreshActiveEditorLSPState()
                    }
                )
            } else {
                deterministicTokenEditorWell
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }

            if let hover = viewModel.activeHoverCard {
                Divider()
                    .overlay(CambridgeLinenPalette.stoneHairline)
                lspHoverPreviewFooter(hover)
            }
        }
        .background(CambridgeLinenPalette.archivalPaper)
        .onChange(of: viewModel.docking.activeManuscriptFilePath) { _, _ in
            viewModel.refreshActiveEditorLSPState()
        }
    }

    // MARK: Editor Telemetry & Mode Strip

    private var editorMetricsAndModeStrip: some View {
        let metrics = viewModel.manuscriptMetrics
        let words = metrics?.totalCountedWords ?? 0
        let eqs = metrics?.totalEquationCount ?? 0
        let cites = metrics?.totalCitationOccurrences ?? 0
        let fog = metrics?.readability.gunningFogIndex ?? 0.0
        let activeFormat = ManuscriptFormat.detect(fromPath: viewModel.docking.activeManuscriptFilePath)

        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Text(localizer.L("\(activeFormat.rawValue) CST", "\(activeFormat.rawValue) 语法树"))
                    .font(CambridgeTypography.uiSectionLabel)
                    .tracking(0)
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(CambridgeLinenPalette.libraryForestTint)
            )
            .fixedSize(horizontal: true, vertical: false)

            metricChip(label: localizer.L("Words", "字数"), value: "\(words)")
            metricChip(label: localizer.L("Eqs", "公式"), value: "\(eqs)")
            metricChip(label: localizer.L("Cites", "引文"), value: "\(cites)")
            metricChip(label: localizer.L("Fog", "可读性"), value: String(format: "%.1f", fog))

            Spacer(minLength: 4)

            Button {
                viewModel.isShowingCompletionPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "text.badge.checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(localizer.L("\\cite Popover", "\\cite 补全窗"))
                        .font(CambridgeTypography.uiCaption)
                        .tracking(0)
                }
            }
            .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: viewModel.isShowingCompletionPopover))
            .fixedSize(horizontal: true, vertical: false)

            Button {
                viewModel.triggerForwardSyncTeXJump()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.doc.on.clipboard")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(localizer.L("SyncTeX ⇢", "同步跳转 ⇢"))
                        .font(CambridgeTypography.uiCaption)
                        .tracking(0)
                }
            }
            .buttonStyle(CambridgeSecondaryButtonStyle())
            .fixedSize(horizontal: true, vertical: false)

            if !isSnapshotRendering {
                Button(viewModel.useNativeAppKitEditor
                       ? localizer.L("Token View", "语法视图")
                       : localizer.L("Raw Edit", "源码编辑")) {
                    viewModel.useNativeAppKitEditor.toggle()
                }
                .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: viewModel.useNativeAppKitEditor))
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(CambridgeLinenPalette.cambridgeLinen)
    }

    private func metricChip(label: String, value: String) -> some View {
        HStack(spacing: 3.5) {
            Text(label)
                .font(CambridgeTypography.uiCaption)
                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
            Text(value)
                .font(CambridgeTypography.monoSmall)
                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(CambridgeLinenPalette.archivalPaper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: Deterministic Line-Numbered Token Editor + Wavy Diagnostics + `\cite` Popover

    private var deterministicTokenEditorWell: some View {
        let lines = sourceLines
        let cursorLine = viewModel.docking.synchronizedCursor.line
        let lineDiags = diagnosticsByLine
        let lineToks = tokensByLine

        return ZStack(alignment: .topLeading) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, rawLine in
                        let lineNumber = index + 1
                        let isCurrentLine = (lineNumber == cursorLine)
                        let diagsOnLine = lineDiags[lineNumber] ?? []
                        let tokensOnLine = lineToks[lineNumber] ?? []

                        editorCodeRow(
                            lineNumber: lineNumber,
                            rawLine: rawLine,
                            tokens: tokensOnLine,
                            diagnostics: diagsOnLine,
                            isCurrentLine: isCurrentLine
                        )

                        // Render floating `\cite{...}` LSP completion popover directly beneath cursor line 18 (or active line)
                        if viewModel.isShowingCompletionPopover && lineNumber == min(max(1, cursorLine), lines.count) {
                            citeAutocompletePopoverCard
                                .padding(.leading, 44)
                                .padding(.trailing, 12)
                                .padding(.vertical, 6)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .background(CambridgeLinenPalette.archivalPaper)
        }
    }

    private func editorCodeRow(
        lineNumber: Int,
        rawLine: String,
        tokens: [MarkupToken],
        diagnostics: [LSPDiagnostic],
        isCurrentLine: Bool
    ) -> some View {
        let highestSeverity = diagnostics.map(\.severity).max()

        return Button {
            viewModel.docking.updateCursor(line: lineNumber, column: 1)
            viewModel.triggerForwardSyncTeXJump(line: lineNumber)
            viewModel.refreshActiveEditorLSPState()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                // Line number gutter
                HStack(spacing: 3) {
                    if let sev = highestSeverity {
                        Circle()
                            .fill(gutterDotColor(for: sev))
                            .frame(width: 5.5, height: 5.5)
                    } else {
                        Spacer()
                            .frame(width: 5.5, height: 5.5)
                    }

                    Text("\(lineNumber)")
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(
                            isCurrentLine
                                ? CambridgeLinenPalette.libraryForestGreen
                                : CambridgeLinenPalette.mutedMetadata
                        )
                        .frame(width: 24, alignment: .trailing)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.leading, 6)
                .padding(.top, 2)

                Rectangle()
                    .fill(CambridgeLinenPalette.stoneHairline)
                    .frame(width: CambridgeMetrics.hairline)

                VStack(alignment: .leading, spacing: 2) {
                    styledTokenText(rawLine: rawLine, tokens: tokens, hasError: highestSeverity == .error)
                        .font(.system(size: 12.0, weight: .regular, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let topDiag = diagnostics.first {
                        HStack(spacing: 5) {
                            WavySquiggleLine(color: gutterDotColor(for: topDiag.severity))
                                .frame(width: 68, height: 4)

                            Text("[\(topDiag.code)] \(topDiag.localizedMessage(localizer.language))")
                                .font(CambridgeTypography.uiCaption)
                                .foregroundStyle(gutterDotColor(for: topDiag.severity))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
                .padding(.vertical, 2)
            }
            .background(
                isCurrentLine
                    ? CambridgeLinenPalette.libraryForestTint.opacity(0.65)
                    : (highestSeverity == .error ? CambridgeLinenPalette.blockedCrimsonBg.opacity(0.45) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func styledTokenText(rawLine: String, tokens: [MarkupToken], hasError: Bool) -> Text {
        guard !rawLine.isEmpty else { return Text(" ") }
        guard !tokens.isEmpty else {
            return Text(rawLine).foregroundColor(CambridgeLinenPalette.oxfordCharcoal)
        }

        var composed = Text("")
        for token in tokens {
            let lex = token.lexeme
            if lex.contains("smith2025hallucinated") {
                composed = composed + Text(lex)
                    .foregroundColor(CambridgeLinenPalette.blockedCrimson)
                    .underline(true, color: CambridgeLinenPalette.blockedCrimson)
                    .fontWeight(.semibold)
            } else {
                switch token.kind {
                case .command, .typstHashKeyword:
                    composed = composed + Text(lex)
                        .foregroundColor(CambridgeLinenPalette.libraryForestGreen)
                        .fontWeight(.semibold)
                case .headingMarker:
                    composed = composed + Text(lex)
                        .foregroundColor(CambridgeLinenPalette.libraryForestGreen)
                        .fontWeight(.bold)
                case .mathInline, .mathDisplay:
                    composed = composed + Text(lex)
                        .foregroundColor(CambridgeLinenPalette.preprintOchre)
                case .comment:
                    composed = composed + Text(lex)
                        .foregroundColor(CambridgeLinenPalette.mutedMetadata)
                        .italic()
                case .leftBrace, .rightBrace, .leftBracket, .rightBracket:
                    composed = composed + Text(lex)
                        .foregroundColor(CambridgeLinenPalette.driftAmber)
                case .identifier:
                    let isVerifiedCite = viewModel.bibliographyEntries.contains {
                        $0.citeKey == lex && $0.firewallClass.allowsManuscriptInsertion
                    }
                    if isVerifiedCite {
                        composed = composed + Text(lex)
                            .foregroundColor(CambridgeLinenPalette.verifiedEmerald)
                            .fontWeight(.medium)
                    } else {
                        composed = composed + Text(lex)
                            .foregroundColor(hasError ? CambridgeLinenPalette.blockedCrimson : CambridgeLinenPalette.oxfordCharcoal)
                    }
                case .numeric:
                    composed = composed + Text(lex)
                        .foregroundColor(CambridgeLinenPalette.libraryForestPressed)
                default:
                    composed = composed + Text(lex)
                        .foregroundColor(CambridgeLinenPalette.oxfordCharcoal)
                }
            }
        }
        return composed
    }

    private func gutterDotColor(for severity: LSPDiagnosticSeverity) -> Color {
        switch severity {
        case .error: return CambridgeLinenPalette.blockedCrimson
        case .warning: return CambridgeLinenPalette.driftAmber
        case .info: return CambridgeLinenPalette.libraryForestGreen
        case .hint: return CambridgeLinenPalette.mutedMetadata
        }
    }

    // MARK: Floating `\cite{...}` LSP Autocomplete Popover Card

    private var citeAutocompletePopoverCard: some View {
        let featuredEntries = Array(viewModel.bibliographyEntries.prefix(4)) +
            viewModel.bibliographyEntries.filter { $0.citeKey == "smith2025hallucinated" }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "quote.closing")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Text(localizer.L("LSP \\cite{…} Completion — Firewall-Gated", "LSP \\cite{…} 引文自动补全 · 防火墙强受控"))
                    .font(CambridgeTypography.uiControlSemibold)
                    .tracking(0)
                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                Spacer(minLength: 6)
                ScholarKeycapBadge(localizer.L("↩ Insert", "↩ 插入"))
            }

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            ForEach(featuredEntries.prefix(4)) { entry in
                let isSelected = (viewModel.docking.selectedCiteKey == entry.citeKey)
                Button {
                    viewModel.docking.selectedCiteKey = entry.citeKey
                    _ = viewModel.attemptInsertCitation(entry.citeKey)
                } label: {
                    HStack(spacing: 8) {
                        Text("@\(entry.citeKey)")
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(
                                entry.firewallClass.allowsManuscriptInsertion
                                    ? CambridgeLinenPalette.libraryForestGreen
                                    : CambridgeLinenPalette.blockedCrimson
                            )
                            .fixedSize(horizontal: true, vertical: false)

                        Text("\(entry.firstAuthorFamily) (\(entry.year.map(String.init) ?? "n.d."))")
                            .font(CambridgeTypography.uiCaption)
                            .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 4)

                        FirewallBadgeView(firewallClass: entry.firewallClass, compact: true)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isSelected ? CambridgeLinenPalette.libraryForestTint : CambridgeLinenPalette.cambridgeLinen)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                .fill(CambridgeLinenPalette.archivalPaper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                .strokeBorder(CambridgeLinenPalette.libraryForestBorder, lineWidth: 1.0)
        )
        .shadow(color: Color.black.opacity(0.07), radius: 6, x: 0, y: 3)
    }

    // MARK: Live LSP Citation & Macro Hover Footer

    private func lspHoverPreviewFooter(_ hover: LSPHoverCard) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.square.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text(localizer.L("LSP Hover", "LSP 悬停卡片"))
                        .font(CambridgeTypography.uiSectionLabel)
                        .tracking(0)
                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                        .fixedSize(horizontal: true, vertical: false)

                    Text(hover.title)
                        .font(CambridgeTypography.uiControlSemibold)
                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    if let fw = hover.firewallClass {
                        FirewallBadgeView(firewallClass: fw, compact: true)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                if let expanded = hover.expandedPreview, !expanded.isEmpty {
                    Text(expanded)
                        .font(CambridgeTypography.uiCaption)
                        .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(CambridgeLinenPalette.warmVellum)
    }
}

/// Crisp vector wavy diagnostic underline rendered in pure SwiftUI.
private struct WavySquiggleLine: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 4.0
            var x: CGFloat = 0.0
            var up = true
            path.move(to: CGPoint(x: 0, y: size.height * 0.5))
            while x < size.width {
                let nextX = min(size.width, x + step)
                let nextY: CGFloat = up ? 0.5 : size.height - 0.5
                path.addLine(to: CGPoint(x: nextX, y: nextY))
                x = nextX
                up.toggle()
            }
            context.stroke(path, with: .color(color), lineWidth: 1.2)
        }
    }
}

// MARK: - Reusable Two-Column Academic PDF + SyncTeX & Grounding Overlay (`TwoColumnAcademicPDFCanvasView`)

/// Renders a real `PDFDocument` two-column academic PDF page (rasterized at 2x Retina from `SyntheticAcademicPDFFixtureGenerator`)
/// overlaid with SyncTeX coordinate crosshairs and grounded / numeric-mismatch `PDFPageRegionBox` highlight boxes.
public struct TwoColumnAcademicPDFCanvasView: View {
    @ObservedObject public var viewModel: ScholarStudioViewModel
    public let compactToolbar: Bool
    @ObservedObject private var localizer = ScholarLocalizer.shared

    public init(viewModel: ScholarStudioViewModel, compactToolbar: Bool = false) {
        self.viewModel = viewModel
        self.compactToolbar = compactToolbar
    }

    private var activePages: [RenderedPDFPageBitmap] {
        if let pages = viewModel.pdfPageBitmapsByKey[viewModel.selectedPDFFixtureCiteKey], !pages.isEmpty {
            return pages
        }
        return viewModel.pdfPageBitmapsByKey.values.first ?? []
    }

    private var currentBitmap: RenderedPDFPageBitmap? {
        let pages = activePages
        guard !pages.isEmpty else { return nil }
        let idx = min(max(0, viewModel.selectedPDFPageIndex), pages.count - 1)
        return pages[idx]
    }

    public var body: some View {
        VStack(spacing: 0) {
            pdfHeaderToolbar

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            GeometryReader { geo in
                let availW = max(180, geo.size.width - 20)
                let availH = max(180, geo.size.height - 20)

                if let bitmap = currentBitmap {
                    let aspect = CGFloat(bitmap.mediaBoxWidthPt / max(1.0, bitmap.mediaBoxHeightPt))
                    let fitH = min(availH, availW / aspect)
                    let fitW = fitH * aspect
                    let ptScale = fitW / CGFloat(bitmap.mediaBoxWidthPt)

                    ZStack {
                        CambridgeLinenPalette.parchmentWell

                        ZStack(alignment: .topLeading) {
                            Image(decorative: bitmap.cgImage, scale: 2.0, orientation: .up)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: fitW, height: fitH)
                                .background(CambridgeLinenPalette.archivalPaper)
                                .overlay(
                                    Rectangle()
                                        .strokeBorder(CambridgeLinenPalette.deepStoneBorder, lineWidth: 1.0)
                                )
                                .shadow(color: Color.black.opacity(0.08), radius: 7, x: 0, y: 3)

                            // Claim-to-PDF Provenance Bounding Box Overlays
                            ForEach(claimsOnCurrentPage(pageIndex: bitmap.pageIndex)) { claim in
                                provenanceRegionOverlay(
                                    claim: claim,
                                    mediaBoxHeightPt: bitmap.mediaBoxHeightPt,
                                    ptScale: ptScale
                                )
                            }

                            // Bidirectional SyncTeX Crosshair Overlay
                            if let anchor = activeAnchorOnPage(pageIndex: bitmap.pageIndex) {
                                syncTeXCrosshairOverlay(
                                    anchor: anchor,
                                    mediaBoxHeightPt: bitmap.mediaBoxHeightPt,
                                    ptScale: ptScale,
                                    pageWidth: fitW
                                )
                            }
                        }
                        .frame(width: fitW, height: fitH)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            let pdfX = Double(location.x / max(0.01, ptScale))
                            let pdfY = bitmap.mediaBoxHeightPt - Double(location.y / max(0.01, ptScale))
                            viewModel.triggerInverseSyncTeXJump(
                                pageIndex: bitmap.pageIndex,
                                xPt: pdfX,
                                yPt: pdfY
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(localizer.L("Generating Two-Column Academic PDF…", "正在渲染双栏学术 PDF 预览"))
                        .font(CambridgeTypography.uiControl)
                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            pdfLegendFooter
        }
        .background(CambridgeLinenPalette.parchmentWell)
    }

    private var pdfHeaderToolbar: some View {
        let pages = activePages
        return HStack(spacing: 6) {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)

            Text(
                compactToolbar
                    ? localizer.L("Two-Column PDF & SyncTeX", "双栏 PDF 与 SyncTeX 联动")
                    : localizer.L("Academic Two-Column PDF & Bounding-Box Verifier", "学术双栏 PDF 与证据边界框核验器")
            )
            .font(CambridgeTypography.uiControlSemibold)
            .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            if !compactToolbar && viewModel.renderedPDFFixtures.count > 1 {
                ForEach(viewModel.renderedPDFFixtures, id: \.citeKey) { fixture in
                    Button("@\(fixture.citeKey)") {
                        viewModel.selectedPDFFixtureCiteKey = fixture.citeKey
                        viewModel.selectedPDFPageIndex = 0
                    }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: viewModel.selectedPDFFixtureCiteKey == fixture.citeKey))
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            HStack(spacing: 3) {
                ForEach(0..<max(1, pages.count), id: \.self) { pIdx in
                    Button(localizer.L("p.\(pIdx + 1)", "第\(pIdx + 1)页")) {
                        viewModel.selectedPDFPageIndex = pIdx
                    }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: viewModel.selectedPDFPageIndex == pIdx))
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(CambridgeLinenPalette.warmVellum)
    }

    private func claimsOnCurrentPage(pageIndex: Int) -> [ClaimEvidenceProvenance] {
        viewModel.claimProvenanceLinks.filter {
            $0.boundingBox.pageIndex == pageIndex && $0.verdict != .unsupportedClaim
        }
    }

    private func activeAnchorOnPage(pageIndex: Int) -> SyncTeXAnchor? {
        if let active = viewModel.docking.activeSyncTeXAnchor, active.pdfPageIndex == pageIndex {
            return active
        }
        return viewModel.syncTeXAnchors.first(where: { $0.pdfPageIndex == pageIndex })
    }

    private func provenanceRegionOverlay(
        claim: ClaimEvidenceProvenance,
        mediaBoxHeightPt: Double,
        ptScale: CGFloat
    ) -> some View {
        let box = claim.boundingBox
        let isSelected = (viewModel.selectedClaimProvenanceID == claim.id)
        let x = CGFloat(box.x) * ptScale
        let y = CGFloat(max(0.0, mediaBoxHeightPt - box.y - box.height)) * ptScale
        let w = CGFloat(box.width) * ptScale
        let h = CGFloat(box.height) * ptScale
        let accent = verdictColor(claim.verdict)

        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accent.opacity(isSelected ? 0.17 : 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(
                            accent,
                            style: StrokeStyle(
                                lineWidth: isSelected ? 1.8 : 1.1,
                                dash: claim.verdict == .numericDiscrepancy ? [4, 2] : []
                            )
                        )
                )

            Text(shortVerdictTag(claim))
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(CambridgeLinenPalette.archivalPaper)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(accent)
                )
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: -2, y: -9)
        }
        .frame(width: max(24, w), height: max(16, h))
        .position(x: x + w * 0.5, y: y + h * 0.5)
        .onTapGesture {
            viewModel.selectClaimProvenance(claim)
        }
    }

    private func syncTeXCrosshairOverlay(
        anchor: SyncTeXAnchor,
        mediaBoxHeightPt: Double,
        ptScale: CGFloat,
        pageWidth: CGFloat
    ) -> some View {
        let targetY = CGFloat(max(18.0, min(mediaBoxHeightPt - 18.0, mediaBoxHeightPt - anchor.yPt))) * ptScale
        let targetX = CGFloat(max(24.0, anchor.xPt)) * ptScale

        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(CambridgeLinenPalette.libraryForestGreen.opacity(0.28))
                .frame(width: pageWidth, height: 1.2)
                .position(x: pageWidth * 0.5, y: targetY)

            HStack(spacing: 3) {
                Image(systemName: "scope")
                    .font(.system(size: 8.5, weight: .bold))
                Text(localizer.L("SyncTeX Ln \(anchor.line)", "SyncTeX 第\(anchor.line)行"))
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(CambridgeLinenPalette.archivalPaper)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(CambridgeLinenPalette.libraryForestGreen)
            )
            .fixedSize(horizontal: true, vertical: false)
            .position(x: min(pageWidth - 56, max(56, targetX)), y: max(12, targetY - 11))
        }
    }

    private var pdfLegendFooter: some View {
        HStack(spacing: 8) {
            legendDot(
                color: CambridgeLinenPalette.verifiedEmerald,
                label: compactToolbar ? localizer.L("Grounded", "证据吻合") : localizer.L("Grounded Claim", "证据吻合断言")
            )
            legendDot(
                color: CambridgeLinenPalette.blockedCrimson,
                label: compactToolbar ? localizer.L("Mismatch", "数值偏差") : localizer.L("Numeric Mismatch", "数值偏差拦截")
            )
            legendDot(
                color: CambridgeLinenPalette.libraryForestGreen,
                label: compactToolbar ? localizer.L("SyncTeX", "双向定位") : localizer.L("SyncTeX Anchor", "SyncTeX 锚点")
            )
            Spacer(minLength: 4)
            Text(
                compactToolbar
                    ? localizer.L("Click PDF → SyncTeX", "点击 PDF → 反向定位源码")
                    : localizer.L("Click PDF region for Inverse SyncTeX", "点击 PDF 区域反向定位源码行")
            )
            .font(CambridgeTypography.uiCaption)
            .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5.5)
        .background(CambridgeLinenPalette.cambridgeLinen)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6.5, height: 6.5)
            Text(label)
                .font(CambridgeTypography.uiCaption)
                .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func verdictColor(_ verdict: EvidenceSupportVerdict) -> Color {
        switch verdict {
        case .groundedEntailment: return CambridgeLinenPalette.verifiedEmerald
        case .partialEvidence: return CambridgeLinenPalette.preprintOchre
        case .numericDiscrepancy, .unsupportedClaim: return CambridgeLinenPalette.blockedCrimson
        }
    }

    private func shortVerdictTag(_ claim: ClaimEvidenceProvenance) -> String {
        switch claim.verdict {
        case .groundedEntailment:
            return localizer.language == .zhHans
                ? String(format: "证据吻合 %.1f", claim.bm25Score)
                : String(format: "GROUNDED %.1f", claim.bm25Score)
        case .partialEvidence:
            return localizer.language == .zhHans
                ? String(format: "部分支持 %.1f", claim.bm25Score)
                : String(format: "PARTIAL %.1f", claim.bm25Score)
        case .numericDiscrepancy:
            return localizer.L("MISMATCH 99.4%≠94.2%", "数值偏差 99.4%≠94.2%")
        case .unsupportedClaim:
            return localizer.L("UNSUPPORTED", "缺乏证据")
        }
    }
}

// MARK: - Studio 2: Full PDF & Claim-to-Passage Provenance Studio (`PDFAndClaimProvenanceStudioView`)

/// Full-width `.pdfProvenance` studio pairing the two-column Academic PDF bounding-box canvas with
/// FTS5 BM25 Claim-to-Passage Provenance & Numeric Entailment auditing and segmented column chunks.
public struct PDFAndClaimProvenanceStudioView: View {
    @ObservedObject public var viewModel: ScholarStudioViewModel
    @ObservedObject private var localizer = ScholarLocalizer.shared

    public init(viewModel: ScholarStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Left Split: Two-Column Academic PDF Canvas + Column Segmentation Strip
            VStack(spacing: 0) {
                TwoColumnAcademicPDFCanvasView(viewModel: viewModel, compactToolbar: false)

                Divider()
                    .overlay(CambridgeLinenPalette.stoneHairline)

                segmentedColumnPassagesStrip
                    .frame(height: 158)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(CambridgeLinenPalette.stoneHairline)
                .frame(width: CambridgeMetrics.hairline)

            // Right Split: Claim-to-PDF BM25 Provenance & Numeric Entailment Matrix
            claimProvenanceMatrixColumn
                .frame(width: 500)
                .background(CambridgeLinenPalette.cambridgeLinen)
        }
    }

    private var segmentedColumnPassagesStrip: some View {
        let chunks = viewModel.pdfPassages.filter { $0.citeKey == viewModel.selectedPDFFixtureCiteKey }
        let displayChunks = chunks.isEmpty ? Array(viewModel.pdfPassages.prefix(4)) : Array(chunks.prefix(4))

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(
                    localizer.L(
                        "XY-CUT TWO-COLUMN READING SEQUENCE (\(displayChunks.count) PASSAGES)",
                        "XY-Cut 双栏阅读序列（共 \(displayChunks.count) 段）"
                    )
                )
                .font(CambridgeTypography.uiSectionLabel)
                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Spacer()
                Text(localizer.L("FTS5 + Porter Stemmer Indexed", "FTS5 全文检索索引已就绪"))
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(displayChunks) { chunk in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(
                                    localizer.L(
                                        "Seq #\(chunk.readingSequence + 1) • Col \(chunk.columnIndex + 1)",
                                        "段落 #\(chunk.readingSequence + 1) • 第\(chunk.columnIndex + 1)栏"
                                    )
                                )
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                                .fixedSize(horizontal: true, vertical: false)
                                Spacer()
                                Text(localizer.L("p.\(chunk.boundingBox.pageIndex + 1)", "第\(chunk.boundingBox.pageIndex + 1)页"))
                                    .font(CambridgeTypography.monoSmall)
                                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                    .fixedSize(horizontal: true, vertical: false)
                            }

                            Text(chunk.sectionTitle)
                                .font(CambridgeTypography.uiControlSemibold)
                                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)

                            Text(chunk.passageText)
                                .font(CambridgeTypography.uiCaption)
                                .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .frame(width: 268, alignment: .leading)
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
                .padding(.bottom, 8)
            }
        }
        .background(CambridgeLinenPalette.cambridgeLinen)
    }

    private var claimProvenanceMatrixColumn: some View {
        let links = viewModel.filteredClaimProvenanceLinks
        let groundedCount = viewModel.claimProvenanceLinks.filter { $0.verdict == .groundedEntailment }.count
        let mismatchCount = viewModel.claimProvenanceLinks.filter {
            $0.verdict == .numericDiscrepancy || $0.verdict == .unsupportedClaim
        }.count

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizer.L("Claim-to-PDF Provenance Matrix", "手稿断言至 PDF 证据溯源矩阵"))
                            .font(CambridgeTypography.scholarlyHeadline)
                            .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                        Text(localizer.L("BM25 lexical grounding & numeric entailment verifier", "BM25 词法证据对齐与数值一致性核验器"))
                            .font(CambridgeTypography.uiCaption)
                            .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                    }
                    Spacer()
                    Text(localizer.L("\(groundedCount) OK • \(mismatchCount) Flagged", "\(groundedCount) 吻合 • \(mismatchCount) 异常"))
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(mismatchCount > 0 ? CambridgeLinenPalette.blockedCrimson : CambridgeLinenPalette.verifiedEmerald)
                        .fixedSize(horizontal: true, vertical: false)
                }

                HStack(spacing: 5) {
                    Button(localizer.L("All (\(viewModel.claimProvenanceLinks.count))", "全部 (\(viewModel.claimProvenanceLinks.count))")) {
                        viewModel.provenanceVerdictFilter = nil
                    }
                    .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: viewModel.provenanceVerdictFilter == nil))
                    .fixedSize(horizontal: true, vertical: false)

                    ForEach(EvidenceSupportVerdict.allCases, id: \.self) { verdict in
                        Button(verdict.localizedLabel(localizer.language)) {
                            viewModel.provenanceVerdictFilter = verdict
                        }
                        .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: viewModel.provenanceVerdictFilter == verdict))
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .padding(12)
            .background(CambridgeLinenPalette.warmVellum)

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(links) { link in
                        provenanceClaimCard(link)
                    }
                }
                .padding(12)
            }
        }
    }

    private func provenanceClaimCard(_ link: ClaimEvidenceProvenance) -> some View {
        let isSelected = (viewModel.selectedClaimProvenanceID == link.id)
        let accent = verdictBadgeColor(link.verdict)

        return Button {
            viewModel.selectClaimProvenance(link)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(link.verdict.localizedLabel(localizer.language))
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(accent.opacity(0.12))
                        )
                        .fixedSize(horizontal: true, vertical: false)

                    Text("@\(link.citeKey)")
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                        .fixedSize(horizontal: true, vertical: false)

                    Text("\(link.manuscriptFile):\(link.manuscriptLine)")
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 4)

                    Text(String(format: "BM25 %.2f", link.bm25Score))
                        .font(CambridgeTypography.monoSmall)
                        .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                        .fixedSize(horizontal: true, vertical: false)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(localizer.L("MANUSCRIPT CLAIM", "手稿正文断言"))
                        .font(CambridgeTypography.uiSectionLabel)
                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                    Text(link.manuscriptClaim)
                        .font(CambridgeTypography.uiControlMedium)
                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(localizer.L("SOURCE PDF PASSAGE (p.\(link.boundingBox.pageIndex + 1))", "原文献 PDF 段落（第\(link.boundingBox.pageIndex + 1)页）"))
                        .font(CambridgeTypography.uiSectionLabel)
                        .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                    Text(link.pdfExcerpt)
                        .font(CambridgeTypography.uiCaption)
                        .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                    .fill(CambridgeLinenPalette.archivalPaper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusCard, style: .continuous)
                    .strokeBorder(
                        isSelected ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.stoneHairline,
                        lineWidth: isSelected ? 1.5 : CambridgeMetrics.hairline
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func verdictBadgeColor(_ verdict: EvidenceSupportVerdict) -> Color {
        switch verdict {
        case .groundedEntailment: return CambridgeLinenPalette.verifiedEmerald
        case .partialEvidence: return CambridgeLinenPalette.preprintOchre
        case .numericDiscrepancy, .unsupportedClaim: return CambridgeLinenPalette.blockedCrimson
        }
    }
}
