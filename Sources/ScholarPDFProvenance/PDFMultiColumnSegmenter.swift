import CoreGraphics
import CoreText
import Foundation
import PDFKit
import ScholarModels

// MARK: - PDFKit Geometric Multi-Column Reading-Order Segmenter

public struct PDFMultiColumnSegmenter: Sendable {
    /// Top/bottom page-height fraction scanned for cross-page repeating headers and footers.
    public static let marginBandHeightRatio: Double = 0.10
    /// Top/bottom page-height fraction scanned for isolated standalone page numbers (including single-page PDFs).
    public static let standalonePageNumberBandRatio: Double = 0.085
    /// Minimum vertical gap (pt) separating an isolated standalone page number from interior content.
    public static let standalonePageNumberMinGapPt: Double = 10.0
    /// Minimum fraction of page width for a single text line to count as intrinsically full-width spanning.
    public static let spanningLineWidthRatio: Double = 0.56
    /// Half-width around `mediaBox.midX` (pt) used to detect lines crossing the central two-column gutter.
    public static let centralGutterCrossingHalfWidthPt: Double = 18.0
    /// Minimum straddle around `mediaBox.midX` (pt) for a caption line to count as cross-column spanning.
    public static let spanningCaptionCenterHalfWidthPt: Double = 10.0
    /// Maximum horizontal gap (pt) for coalescing touching or overlapping intra-line math/kerning glyph fragments.
    public static let kerningCoalesceMaxGapPt: Double = 3.5
    /// Maximum vertical gap (pt) before starting a new paragraph within a column stream.
    public static let paragraphVerticalGapThresholdPt: Double = 11.5

    public init() {}

    public func segmentPDF(at url: URL, citeKey: String) throws -> [PDFPassageChunk] {
        guard let document = PDFDocument(url: url) else {
            throw ScholarOSError.pdfExtractionFailure("PDFKit could not open '\(url.path)'")
        }
        return segmentDocument(document, pdfFileName: url.lastPathComponent, citeKey: citeKey)
    }

    public func segmentPDF(data: Data, pdfFileName: String, citeKey: String) throws -> [PDFPassageChunk] {
        guard let document = PDFDocument(data: data) else {
            throw ScholarOSError.pdfExtractionFailure("PDFKit could not decode PDF data for '\(pdfFileName)'")
        }
        return segmentDocument(document, pdfFileName: pdfFileName, citeKey: citeKey)
    }

    public func segmentDocument(_ document: PDFDocument, pdfFileName: String, citeKey: String) -> [PDFPassageChunk] {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }

        // Pass 1: Extract positioned lines on every page and build cross-page margin template frequencies
        var rawPages: [PageRawLayout] = []
        rawPages.reserveCapacity(pageCount)

        var topTemplatePages: [String: Set<Int>] = [:]
        var bottomTemplatePages: [String: Set<Int>] = [:]

        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let mediaBox = page.bounds(for: .mediaBox)
            let lines = extractPositionedLines(from: page, pageIndex: pageIndex)
            guard !lines.isEmpty else { continue }

            let pageMinY = Double(mediaBox.minY)
            let pageMaxY = Double(mediaBox.maxY)
            let pageHeight = max(1.0, pageMaxY - pageMinY)
            let topCutoffY = pageMaxY - Self.marginBandHeightRatio * pageHeight
            let bottomCutoffY = pageMinY + Self.marginBandHeightRatio * pageHeight

            for line in lines {
                if line.minY >= topCutoffY, let tpl = Self.normalizeMarginTemplate(line.text) {
                    topTemplatePages[tpl, default: []].insert(pageIndex)
                }
                if line.maxY <= bottomCutoffY, let tpl = Self.normalizeMarginTemplate(line.text) {
                    bottomTemplatePages[tpl, default: []].insert(pageIndex)
                }
            }

            rawPages.append(PageRawLayout(pageIndex: pageIndex, mediaBox: mediaBox, lines: lines))
        }

        // Pass 2: Segment each page into headers, spanning floats/front-matter, two-column/single-column prose, and footers
        var chunks: [PDFPassageChunk] = []
        var globalSeq = 0
        var activeSection = "Front Matter & Abstract"

        func appendChunk(
            pageIndex: Int,
            columnIndex: Int,
            sectionTitle: String,
            kind: PDFPassageChunkKind,
            block: PositionedTextLine
        ) {
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            globalSeq += 1
            let bbox = PDFPageRegionBox(
                pageIndex: pageIndex,
                x: block.minX,
                y: block.minY,
                width: max(8.0, block.maxX - block.minX),
                height: max(8.0, block.maxY - block.minY)
            )
            chunks.append(
                PDFPassageChunk(
                    id: "\(citeKey)#p\(pageIndex + 1)-c\(columnIndex)-\(globalSeq)",
                    citeKey: citeKey,
                    pdfFileName: pdfFileName,
                    sectionTitle: sectionTitle,
                    columnIndex: columnIndex,
                    readingSequence: globalSeq,
                    boundingBox: bbox,
                    passageText: trimmed,
                    kind: kind
                )
            )
        }

        for rawPage in rawPages {
            let pageIndex = rawPage.pageIndex
            let mediaBox = rawPage.mediaBox
            let midX = Double(mediaBox.midX)
            let pageWidth = Double(max(1.0, mediaBox.width))

            // 1. Strip repeating headers/footers and isolated standalone page numbers
            let partitioned = Self.partitionMarginLines(
                lines: rawPage.lines,
                pageIndex: pageIndex,
                totalPageCount: pageCount,
                mediaBox: mediaBox,
                topTemplatePages: topTemplatePages,
                bottomTemplatePages: bottomTemplatePages
            )

            let headerBlocks = Self.mergeHorizontalRows(partitioned.headers)
            for hb in headerBlocks {
                appendChunk(
                    pageIndex: pageIndex,
                    columnIndex: 0,
                    sectionTitle: activeSection,
                    kind: .header,
                    block: hb
                )
            }

            let contentLines = partitioned.content
            if !contentLines.isEmpty {
                // 2. Isolate cross-column spanning tables/figures (carrying along narrow column cells inside their Y band)
                let tableExtraction = Self.extractSpanningTablesAndFigures(
                    from: contentLines,
                    midX: midX,
                    pageWidth: pageWidth
                )
                let spanningFloats = tableExtraction.floatBlocks
                let proseLines = tableExtraction.remainingLines

                // 3. Partition remaining prose/heading lines into spanning, gutter-straddling short fragments, left, and right streams
                let minSpanningFloatY = spanningFloats.map(\.minY).min()
                let hasLowerColumnProse: Bool = {
                    guard let floatBottomY = minSpanningFloatY else { return false }
                    let belowFloat = proseLines.filter { $0.maxY <= floatBottomY + 4.0 && !Self.isSpanningLine($0, midX: midX, pageWidth: pageWidth) }
                    let hasSubstantialLeft = belowFloat.contains { $0.maxX <= (midX + 10.0) && ($0.width / pageWidth) >= 0.22 }
                    let hasSubstantialRight = belowFloat.contains { $0.minX >= (midX - 10.0) && ($0.width / pageWidth) >= 0.22 }
                    return hasSubstantialLeft && hasSubstantialRight
                }()

                var upperStrayFloatFragments: [PositionedTextLine] = []
                var spanningProse: [PositionedTextLine] = []
                var leftProse: [PositionedTextLine] = []
                var rightProse: [PositionedTextLine] = []

                for line in proseLines {
                    // Short axis/legend fragments stranded above a spanning float must not distort lower two-column bounds
                    if let floatBottomY = minSpanningFloatY,
                       hasLowerColumnProse,
                       line.minY >= (floatBottomY - 2.0),
                       (line.width / pageWidth) < 0.26,
                       Self.detectSectionHeading(line.text) == nil,
                       !Self.isTableOrFigureCaption(line.text),
                       Self.alphabeticWordCount(line.text) <= 4 {
                        upperStrayFloatFragments.append(line)
                        continue
                    }

                    if Self.isSpanningLine(line, midX: midX, pageWidth: pageWidth) {
                        spanningProse.append(line)
                    } else if line.midX <= midX {
                        leftProse.append(line)
                    } else {
                        rightProse.append(line)
                    }
                }

                spanningProse.sort(by: Self.sortTopDown)
                leftProse.sort(by: Self.sortTopDown)
                rightProse.sort(by: Self.sortTopDown)

                let maxLeftMaxX = leftProse.map(\.maxX).max() ?? -.infinity
                let minRightMinX = rightProse.map(\.minX).min() ?? .infinity
                let effectiveLeftBound: Double = {
                    guard leftProse.count >= 4 else { return maxLeftMaxX }
                    let sortedMaxX = leftProse.map(\.maxX).sorted()
                    let idx = min(sortedMaxX.count - 1, Int(Double(sortedMaxX.count - 1) * 0.90))
                    return sortedMaxX[idx]
                }()
                let effectiveRightBound: Double = {
                    guard rightProse.count >= 4 else { return minRightMinX }
                    let sortedMinX = rightProse.map(\.minX).sorted()
                    let idx = max(0, Int(Double(sortedMinX.count - 1) * 0.10))
                    return sortedMinX[idx]
                }()

                let twoColTopY = max(
                    leftProse.map(\.maxY).max() ?? -.infinity,
                    rightProse.map(\.maxY).max() ?? -.infinity
                )
                let twoColBottomY = min(
                    leftProse.map(\.minY).min() ?? .infinity,
                    rightProse.map(\.minY).min() ?? .infinity
                )
                let interleavedSpanningCount = spanningProse.filter {
                    $0.midY < twoColTopY - 4.0 && $0.midY > twoColBottomY + 4.0
                }.count

                let hasCleanTwoColumnBothSides =
                    !leftProse.isEmpty
                    && !rightProse.isEmpty
                    && effectiveLeftBound < (midX + 12.0)
                    && effectiveRightBound > (midX - 12.0)
                    && effectiveLeftBound < effectiveRightBound
                    && interleavedSpanningCount * 3 <= (leftProse.count + rightProse.count)

                let hasLeftOnlyTwoColumnStream =
                    !leftProse.isEmpty
                    && rightProse.isEmpty
                    && maxLeftMaxX <= (midX + 8.0)
                    && interleavedSpanningCount == 0

                let isTwoColumn = hasCleanTwoColumnBothSides || hasLeftOnlyTwoColumnStream

                // Merge any stranded upper float fragments with top floats
                var allSpanningFloats = spanningFloats
                if !upperStrayFloatFragments.isEmpty {
                    let mergedStranded = Self.mergeHorizontalRows(upperStrayFloatFragments)
                    allSpanningFloats.append(contentsOf: mergedStranded)
                }

                // Split spanning floats into top floats (above body columns) vs bottom floats
                let topThresholdY = (leftProse.isEmpty && rightProse.isEmpty) ? -.infinity : (twoColTopY - 6.0)
                let topFloats = allSpanningFloats.filter { $0.minY >= topThresholdY }
                let bottomFloats = allSpanningFloats.filter { $0.minY < topThresholdY }

                func emitProseStream(columnIndex: Int, lines: [PositionedTextLine]) {
                    guard !lines.isEmpty else { return }
                    let paragraphs = groupLinesIntoParagraphs(lines)
                    for para in paragraphs {
                        if let heading = para.detectedHeading {
                            activeSection = heading
                            appendChunk(
                                pageIndex: pageIndex,
                                columnIndex: columnIndex,
                                sectionTitle: activeSection,
                                kind: .sectionHeading,
                                block: para.block
                            )
                        } else if Self.isTableOrFigureCaption(para.block.text) {
                            appendChunk(
                                pageIndex: pageIndex,
                                columnIndex: columnIndex,
                                sectionTitle: activeSection,
                                kind: .tableOrFigure,
                                block: para.block
                            )
                        } else {
                            appendChunk(
                                pageIndex: pageIndex,
                                columnIndex: columnIndex,
                                sectionTitle: activeSection,
                                kind: .body,
                                block: para.block
                            )
                        }
                    }
                }

                if isTwoColumn {
                    let topSpanningProse = spanningProse.filter { $0.midY >= twoColTopY - 4.0 }
                    let lowerSpanningProse = spanningProse.filter { $0.midY < twoColTopY - 4.0 }

                    // Emit top spanning prose and top spanning floats ordered top-to-bottom
                    enum TopSpanItem {
                        case prose(GroupedParagraph)
                        case tableFigure(PositionedTextLine)
                        var maxY: Double {
                            switch self {
                            case .prose(let p): return p.block.maxY
                            case .tableFigure(let b): return b.maxY
                            }
                        }
                    }
                    var topItems: [TopSpanItem] = []
                    for p in groupLinesIntoParagraphs(topSpanningProse) {
                        topItems.append(.prose(p))
                    }
                    for tf in topFloats {
                        topItems.append(.tableFigure(tf))
                    }
                    topItems.sort { $0.maxY > $1.maxY }

                    for item in topItems {
                        switch item {
                        case .prose(let para):
                            if let heading = para.detectedHeading {
                                activeSection = heading
                                appendChunk(pageIndex: pageIndex, columnIndex: 0, sectionTitle: activeSection, kind: .sectionHeading, block: para.block)
                            } else {
                                appendChunk(pageIndex: pageIndex, columnIndex: 0, sectionTitle: activeSection, kind: .body, block: para.block)
                            }
                        case .tableFigure(let tf):
                            appendChunk(pageIndex: pageIndex, columnIndex: 0, sectionTitle: activeSection, kind: .tableOrFigure, block: tf)
                        }
                    }

                    // Left column strictly precedes right column
                    emitProseStream(columnIndex: 1, lines: leftProse)
                    emitProseStream(columnIndex: 2, lines: rightProse)

                    if !lowerSpanningProse.isEmpty {
                        emitProseStream(columnIndex: 0, lines: lowerSpanningProse)
                    }
                    for tf in bottomFloats.sorted(by: Self.sortTopDown) {
                        appendChunk(pageIndex: pageIndex, columnIndex: 0, sectionTitle: activeSection, kind: .tableOrFigure, block: tf)
                    }
                } else {
                    // Single-column page: interleave single-column prose blocks and spanning floats top-to-bottom
                    for tf in topFloats.sorted(by: Self.sortTopDown) {
                        appendChunk(pageIndex: pageIndex, columnIndex: 0, sectionTitle: activeSection, kind: .tableOrFigure, block: tf)
                    }
                    var mergedSingle = spanningProse + leftProse + rightProse
                    mergedSingle.sort(by: Self.sortTopDown)
                    emitProseStream(columnIndex: 0, lines: mergedSingle)
                    for tf in bottomFloats.sorted(by: Self.sortTopDown) {
                        appendChunk(pageIndex: pageIndex, columnIndex: 0, sectionTitle: activeSection, kind: .tableOrFigure, block: tf)
                    }
                }
            }

            let footerBlocks = Self.mergeHorizontalRows(partitioned.footers)
            for fb in footerBlocks {
                appendChunk(
                    pageIndex: pageIndex,
                    columnIndex: 0,
                    sectionTitle: activeSection,
                    kind: .footer,
                    block: fb
                )
            }
        }

        return chunks
    }

    // MARK: - Internal Geometry Types

    private struct PageRawLayout {
        let pageIndex: Int
        let mediaBox: CGRect
        let lines: [PositionedTextLine]
    }

    private struct PositionedTextLine {
        let text: String
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double
        var width: Double { maxX - minX }
        var height: Double { maxY - minY }
        var midX: Double { (minX + maxX) * 0.5 }
        var midY: Double { (minY + maxY) * 0.5 }
    }

    private static func sortTopDown(_ a: PositionedTextLine, _ b: PositionedTextLine) -> Bool {
        if abs(a.maxY - b.maxY) > 3.0 { return a.maxY > b.maxY }
        return a.minX < b.minX
    }

    private static func isSpanningLine(_ line: PositionedTextLine, midX: Double, pageWidth: Double) -> Bool {
        let widthRatio = line.width / pageWidth
        let crossesGutter =
            line.minX < (midX - centralGutterCrossingHalfWidthPt)
            && line.maxX > (midX + centralGutterCrossingHalfWidthPt)
        return widthRatio > spanningLineWidthRatio || crossesGutter
    }

    // MARK: - PDFKit Line Extraction

    private func extractPositionedLines(from page: PDFPage, pageIndex: Int) -> [PositionedTextLine] {
        guard let fullSelection = page.selection(for: page.bounds(for: .mediaBox)) else {
            if let fallback = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
                let b = page.bounds(for: .mediaBox)
                return fallback.components(separatedBy: .newlines).enumerated().compactMap { idx, line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return nil }
                    let y = Double(b.maxY) - Double(idx + 1) * 14.0
                    return PositionedTextLine(
                        text: trimmed,
                        minX: Double(b.minX) + 36.0,
                        minY: max(0.0, y - 12.0),
                        maxX: Double(b.maxX) - 36.0,
                        maxY: max(12.0, y)
                    )
                }
            }
            return []
        }

        var lines: [PositionedTextLine] = []
        for lineSel in fullSelection.selectionsByLine() {
            guard let raw = lineSel.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            let bounds = lineSel.bounds(for: page)
            lines.append(
                PositionedTextLine(
                    text: raw,
                    minX: Double(bounds.minX),
                    minY: Double(bounds.minY),
                    maxX: Double(bounds.maxX),
                    maxY: Double(bounds.maxY)
                )
            )
        }
        return lines
    }

    // MARK: - Margin Header & Footer Stripping

    private static func normalizeMarginTemplate(_ raw: String) -> String? {
        let collapsed = raw
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }

        var digitNormalized = collapsed.replacingOccurrences(
            of: #"\d+"#,
            with: "#",
            options: .regularExpression
        )

        // Strip leading or trailing page number tokens ("4 ieee transactions..." / "... title 5")
        let strippedEdgeNum = digitNormalized
            .replacingOccurrences(of: #"^#\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+#$"#, with: "", options: .regularExpression)
        let alphaCount = strippedEdgeNum.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if alphaCount >= 6 {
            digitNormalized = strippedEdgeNum
        }

        let totalLetters = digitNormalized.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard totalLetters >= 3 || digitNormalized.contains("page #") else { return nil }
        return digitNormalized
    }

    private static func isStandalonePageNumber(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, s.count <= 24 else { return false }
        if s.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil {
            return true
        }
        if s.range(of: #"^[-–—]\s*\d{1,4}\s*[-–—]$"#, options: .regularExpression) != nil {
            return true
        }
        if s.range(of: #"^page\s+\d{1,4}(?:\s*(?:of|/)\s*\d{1,4})?$"#, options: .regularExpression) != nil {
            return true
        }
        if s.range(of: #"^[ivxlcdm]{1,6}$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func partitionMarginLines(
        lines: [PositionedTextLine],
        pageIndex: Int,
        totalPageCount: Int,
        mediaBox: CGRect,
        topTemplatePages: [String: Set<Int>],
        bottomTemplatePages: [String: Set<Int>]
    ) -> (headers: [PositionedTextLine], footers: [PositionedTextLine], content: [PositionedTextLine]) {
        let pageMinY = Double(mediaBox.minY)
        let pageMaxY = Double(mediaBox.maxY)
        let pageHeight = max(1.0, pageMaxY - pageMinY)

        let topBandY = pageMaxY - marginBandHeightRatio * pageHeight
        let bottomBandY = pageMinY + marginBandHeightRatio * pageHeight
        let topPageNumY = pageMaxY - standalonePageNumberBandRatio * pageHeight
        let bottomPageNumY = pageMinY + standalonePageNumberBandRatio * pageHeight

        let interiorLines = lines.filter { $0.minY < topBandY && $0.maxY > bottomBandY }
        let interiorTopMaxY = interiorLines.map(\.maxY).max()
        let interiorBottomMinY = interiorLines.map(\.minY).min()

        var headers: [PositionedTextLine] = []
        var footers: [PositionedTextLine] = []
        var content: [PositionedTextLine] = []

        for line in lines {
            if line.minY >= topBandY {
                let repeatsAcrossPages =
                    totalPageCount >= 2
                    && (normalizeMarginTemplate(line.text).map { (topTemplatePages[$0]?.count ?? 0) >= 2 } ?? false)
                let isolatedPageNum =
                    line.minY >= topPageNumY
                    && isStandalonePageNumber(line.text)
                    && (interiorTopMaxY.map { line.minY - $0 >= standalonePageNumberMinGapPt } ?? true)
                if repeatsAcrossPages || isolatedPageNum {
                    headers.append(line)
                    continue
                }
            }

            if line.maxY <= bottomBandY {
                let repeatsAcrossPages =
                    totalPageCount >= 2
                    && (normalizeMarginTemplate(line.text).map { (bottomTemplatePages[$0]?.count ?? 0) >= 2 } ?? false)
                let isolatedPageNum =
                    line.maxY <= bottomPageNumY
                    && isStandalonePageNumber(line.text)
                    && (interiorBottomMinY.map { $0 - line.maxY >= standalonePageNumberMinGapPt } ?? true)
                if repeatsAcrossPages || isolatedPageNum {
                    footers.append(line)
                    continue
                }
            }

            content.append(line)
        }

        return (headers, footers, content)
    }

    private static func mergeHorizontalRows(_ lines: [PositionedTextLine]) -> [PositionedTextLine] {
        guard !lines.isEmpty else { return [] }
        let sorted = lines.sorted(by: sortTopDown)
        var rowGroups: [[PositionedTextLine]] = []

        for line in sorted {
            if let idx = rowGroups.firstIndex(where: { abs($0[0].midY - line.midY) <= 4.0 }) {
                rowGroups[idx].append(line)
            } else {
                rowGroups.append([line])
            }
        }

        return rowGroups.map { group in
            let lr = group.sorted { $0.minX < $1.minX }
            return PositionedTextLine(
                text: lr.map(\.text).joined(separator: " "),
                minX: lr.map(\.minX).min() ?? 0.0,
                minY: lr.map(\.minY).min() ?? 0.0,
                maxX: lr.map(\.maxX).max() ?? 0.0,
                maxY: lr.map(\.maxY).max() ?? 0.0
            )
        }
        .sorted(by: sortTopDown)
    }

    // MARK: - Spanning Table & Figure Detection

    private static let captionProseFollowers: Set<String> = [
        "shows", "show", "illustrates", "illustrate", "reports", "report",
        "summarizes", "summarize", "compares", "compare", "depicts", "depict",
        "presents", "present", "demonstrates", "demonstrate", "lists", "list",
        "gives", "give", "provides", "provide", "contains", "contain",
        "is", "are", "was", "were", "has", "have", "can", "will",
        "in", "on", "at", "to", "for", "of", "with", "from", "and", "or", "that"
    ]

    private static func isTableOrFigureCaption(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let prefixPattern = #"^(?:table|tab\.|figure|fig\.|figs\.|algorithm|alg\.|scheme|chart)(?:\s*\d+[a-z]?|\s+(?:[ivxlcdm]{1,6}|[a-z]\d*))"#
        guard let matchRange = trimmed.range(of: prefixPattern, options: [.regularExpression, .caseInsensitive]) else {
            return false
        }
        let remainder = String(trimmed[matchRange.upperBound...])
        if remainder.isEmpty {
            return true
        }
        if let firstChar = remainder.first, ":.—–-".contains(firstChar) {
            return true
        }
        let afterSpace = remainder.trimmingCharacters(in: .whitespaces)
        guard afterSpace.count < remainder.count, let nextChar = afterSpace.first else {
            return false
        }
        if nextChar == "(" || nextChar == "[" {
            return true
        }
        guard nextChar.isLetter, nextChar.isUppercase else {
            return false
        }
        let firstWord = afterSpace
            .components(separatedBy: .whitespaces)
            .first?
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased() ?? ""
        return !captionProseFollowers.contains(firstWord)
    }

    private static func coalesceHorizontalSegments(
        _ lines: [PositionedTextLine],
        maxGapPt: Double
    ) -> [PositionedTextLine] {
        let sorted = lines.sorted {
            if abs($0.minX - $1.minX) > 0.5 { return $0.minX < $1.minX }
            return $0.maxY > $1.maxY
        }
        guard var current = sorted.first else { return [] }
        var merged: [PositionedTextLine] = []
        for next in sorted.dropFirst() {
            let gap = next.minX - current.maxX
            if gap <= maxGapPt {
                current = PositionedTextLine(
                    text: current.text + " " + next.text,
                    minX: min(current.minX, next.minX),
                    minY: min(current.minY, next.minY),
                    maxX: max(current.maxX, next.maxX),
                    maxY: max(current.maxY, next.maxY)
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    private static func hasDenseTabularMetrics(_ text: String) -> Bool {
        let parts = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var decimalOrUnitTokens = 0
        var plainNumericTokens = 0
        for part in parts {
            let cleaned = part.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
            if cleaned.range(
                of: #"^[+-]?(?:\d+[.,]\d+(?:%|ms|s|x|×|mb|gb|kb|m|k)?|\d+(?:%|ms|s|x|×|mb|gb|kb))$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                decimalOrUnitTokens += 1
            } else if let intVal = Int(cleaned), !(1900...2039).contains(intVal) {
                plainNumericTokens += 1
            }
        }
        return decimalOrUnitTokens >= 3 || (decimalOrUnitTokens >= 1 && (decimalOrUnitTokens + plainNumericTokens) >= 4)
    }

    private static func isMathEquationSegment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isTableOrFigureCaption(trimmed) || hasDenseTabularMetrics(trimmed) {
            return false
        }
        if trimmed.range(of: #"[\u{f8eb}-\u{f8fe}]"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"[=≈∝≡→←↔↦≤≥≪≫∂∇∫∬∮∑∏⟨⟩±∓⊗⊕∈∉⊂⊆∀∃ˆ¯]"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"(?:^|\s)\((?:[A-Z]\.)?\d{1,3}[a-z]?\)\.?$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func isBibliographyHeading(_ raw: String) -> Bool {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !trimmed.isEmpty, trimmed.count <= 48 else { return false }
        return trimmed.range(
            of: #"^(?:(?:\d{1,2}\.?|[ivxlcdm]{1,6}\.)\s+)?(?:references|bibliography|works cited|literature cited|references and notes)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func hasBibliographicCue(_ text: String) -> Bool {
        let patterns = [
            #"\b(?:19\d{2}|20[0-3]\d)[a-z]?\b"#,
            #"\bpp?\.\s*\d"#,
            #"\bvol\.\s*\d"#,
            #"\bno\.\s*\d"#,
            #"\barxiv(?:\s+preprint|:)"#,
            #"\bdoi\s*:"#,
            #"\b(?:proceedings|conference|symposium|transactions|journal|letters|annals)\b"#,
            #"\bet\s+al\."#,
            #"\b\d{1,5}[–—-]\d{1,5}\b"#
        ]
        return patterns.contains { pat in
            text.range(of: pat, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func isBibliographyEntryStart(_ raw: String) -> Bool {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !trimmed.isEmpty, !hasDenseTabularMetrics(trimmed) else { return false }

        // 1. Bracketed numeric item ("[1]", "[12] Author...")
        if trimmed.range(of: #"^\[\d{1,4}\](?:\s+\S.*|$)"#, options: .regularExpression) != nil {
            return true
        }
        // 2. Dotted numeric item ("1. A. Rivera...", "12. Qingyao Ai... 2018")
        if trimmed.range(of: #"^\d{1,4}\.\s+[A-Z]"#, options: .regularExpression) != nil,
           detectSectionHeading(trimmed) == nil,
           hasBibliographicCue(trimmed) {
            return true
        }
        // 3. Author-name / Author-year item ("Rivera, A., 2024...", "Qingyao Ai, Keping Bi, and ... 2018.")
        if trimmed.range(of: #"^[A-Z][A-Za-z'’-]+,\s+(?:[A-Z]\.|[A-Z][a-z]+)"#, options: .regularExpression) != nil,
           hasBibliographicCue(trimmed) {
            return true
        }
        if trimmed.range(of: #"^[A-Z][A-Za-z'’-]+\s+[A-Z][A-Za-z'’.-]+(?:,\s+|\s+and\s+|\s+&\s+)"#, options: .regularExpression) != nil,
           hasBibliographicCue(trimmed) {
            return true
        }
        return false
    }

    private static func alphabeticWordCount(_ text: String) -> Int {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { tok in
                tok.unicodeScalars.contains { CharacterSet.letters.contains($0) }
            }
            .count
    }

    private static func isFigureCaptionText(_ raw: String) -> Bool {
        guard isTableOrFigureCaption(raw) else { return false }
        let low = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return low.hasPrefix("figure") || low.hasPrefix("fig.") || low.hasPrefix("figs.")
            || low.hasPrefix("chart") || low.hasPrefix("scheme")
    }

    private static func looksTabularRow(_ text: String, segmentCount: Int) -> Bool {
        if isMathEquationSegment(text) && !hasDenseTabularMetrics(text) {
            return false
        }
        if segmentCount >= 3 { return true }
        if hasDenseTabularMetrics(text) { return true }
        var numericTokens = 0
        let parts = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        for part in parts {
            if part.range(of: #"^[+-]?\d+(?:[.,]\d+)?(?:%|ms|s|x|×|mb|gb|kb)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                numericTokens += 1
            }
        }
        return numericTokens >= 3
    }

    private static func extractSpanningTablesAndFigures(
        from contentLines: [PositionedTextLine],
        midX: Double,
        pageWidth: Double
    ) -> (floatBlocks: [PositionedTextLine], remainingLines: [PositionedTextLine]) {
        guard !contentLines.isEmpty else { return ([], []) }

        // Group content lines into horizontal Y-bands (tolerance 4 pt) to evaluate cross-column spanning structure
        struct HorizontalRow {
            var indices: [Int]
            var lines: [PositionedTextLine]
            var segments: [PositionedTextLine]
            var minX: Double
            var maxX: Double
            var minY: Double
            var maxY: Double
            var midY: Double { (minY + maxY) * 0.5 }
            var combinedWidth: Double { maxX - minX }
        }

        let indexedSorted = contentLines.enumerated().sorted { sortTopDown($0.element, $1.element) }
        var rows: [HorizontalRow] = []

        for (origIdx, line) in indexedSorted {
            if let rIdx = rows.firstIndex(where: { abs($0.midY - line.midY) <= 4.0 }) {
                rows[rIdx].indices.append(origIdx)
                rows[rIdx].lines.append(line)
                rows[rIdx].minX = min(rows[rIdx].minX, line.minX)
                rows[rIdx].maxX = max(rows[rIdx].maxX, line.maxX)
                rows[rIdx].minY = min(rows[rIdx].minY, line.minY)
                rows[rIdx].maxY = max(rows[rIdx].maxY, line.maxY)
            } else {
                rows.append(
                    HorizontalRow(
                        indices: [origIdx],
                        lines: [line],
                        segments: [line],
                        minX: line.minX,
                        maxX: line.maxX,
                        minY: line.minY,
                        maxY: line.maxY
                    )
                )
            }
        }
        for rIdx in rows.indices {
            rows[rIdx].segments = coalesceHorizontalSegments(
                rows[rIdx].lines,
                maxGapPt: kerningCoalesceMaxGapPt
            )
        }
        rows.sort { $0.maxY > $1.maxY }

        func rowHasSpanningCaption(_ row: HorizontalRow) -> Bool {
            let captionPieces = coalesceHorizontalSegments(row.lines, maxGapPt: 12.0)
            return captionPieces.contains { piece in
                guard isTableOrFigureCaption(piece.text) else { return false }
                if isSpanningLine(piece, midX: midX, pageWidth: pageWidth) {
                    return true
                }
                if piece.minX < (midX - spanningCaptionCenterHalfWidthPt)
                    && piece.maxX > (midX + spanningCaptionCenterHalfWidthPt) {
                    return true
                }
                if abs(piece.midX - midX) <= 20.0 && piece.minX < midX && piece.maxX > midX {
                    return true
                }
                return false
            }
        }

        func partitionRowAroundGutter(_ row: HorizontalRow) -> (
            left: [PositionedTextLine],
            bridge: [PositionedTextLine],
            right: [PositionedTextLine]
        ) {
            var left: [PositionedTextLine] = []
            var bridge: [PositionedTextLine] = []
            var right: [PositionedTextLine] = []
            for seg in row.segments {
                if seg.maxX <= (midX + 12.0) {
                    left.append(seg)
                } else if seg.minX >= (midX - 12.0) {
                    right.append(seg)
                } else {
                    bridge.append(seg)
                }
            }
            return (left, bridge, right)
        }

        func isReferenceListCluster(_ orderedRows: [HorizontalRow], rowTexts: [String]) -> Bool {
            for (row, fullText) in zip(orderedRows, rowTexts) {
                if isBibliographyHeading(fullText) { return true }
                for seg in row.segments where isBibliographyHeading(seg.text) {
                    return true
                }
            }

            var entryStartRows = 0
            var bibCueRows = 0
            for (row, fullText) in zip(orderedRows, rowTexts) {
                if hasDenseTabularMetrics(fullText) { continue }
                let parts = partitionRowAroundGutter(row)
                let leftText = parts.left.map(\.text).joined(separator: " ")
                let rightText = parts.right.map(\.text).joined(separator: " ")

                let rowStartsEntry =
                    isBibliographyEntryStart(fullText)
                    || isBibliographyEntryStart(leftText)
                    || isBibliographyEntryStart(rightText)
                    || row.segments.contains { isBibliographyEntryStart($0.text) }
                if rowStartsEntry {
                    entryStartRows += 1
                }
                if hasBibliographicCue(fullText) {
                    bibCueRows += 1
                }
            }

            if entryStartRows >= 2 { return true }
            if entryStartRows >= 1 && bibCueRows * 2 >= orderedRows.count { return true }
            return false
        }

        // Mark candidate spanning rows: spanning caption, single gutter-crossing line, or multi-column grid across both sides
        func rowHasFigureCaption(_ row: HorizontalRow) -> Bool {
            let captionPieces = coalesceHorizontalSegments(row.lines, maxGapPt: 12.0)
            return captionPieces.contains { isFigureCaptionText($0.text) }
        }

        func rowContinuesProseParagraphAbove(_ rIdx: Int, phrases: [PositionedTextLine]) -> Bool {
            guard rIdx > 0 else { return false }
            let row = rows[rIdx]
            let prev = rows[rIdx - 1]
            let vGap = prev.minY - row.maxY
            guard vGap >= -2.0 && vGap <= 9.0 else { return false }
            let prevPhrases = coalesceHorizontalSegments(prev.lines, maxGapPt: 8.0)
            for p in phrases {
                let matchesUpperProse = prevPhrases.contains { up in
                    abs(up.minX - p.minX) <= 10.0
                        && (up.width / pageWidth) >= 0.28
                        && alphabeticWordCount(up.text) >= 5
                        && !looksTabularRow(up.text, segmentCount: 1)
                }
                if matchesUpperProse {
                    return true
                }
            }
            return false
        }

        // True when a horizontal row consists solely of short chart ticks, axis labels (e.g. "Score (%)"),
        // legend items, subplot tags ("(a) ..."), or multi-cell fragments — never full column prose or headings.
        func isChartOrFloatFragmentRow(_ rIdx: Int) -> Bool {
            let row = rows[rIdx]
            if rowHasSpanningCaption(row) { return false }
            let joined = row.segments.map(\.text).joined(separator: " ")
            if detectSectionHeading(joined) != nil || isBibliographyHeading(joined) || isBibliographyEntryStart(joined) {
                return false
            }
            if isMathEquationSegment(joined) && !hasDenseTabularMetrics(joined) {
                return false
            }

            let phrases = coalesceHorizontalSegments(row.lines, maxGapPt: 8.0)
            if phrases.contains(where: {
                detectSectionHeading($0.text) != nil || isBibliographyHeading($0.text) || isBibliographyEntryStart($0.text)
            }) {
                return false
            }
            if rowContinuesProseParagraphAbove(rIdx, phrases: phrases) {
                return false
            }

            for phrase in phrases {
                let widthRatio = phrase.width / pageWidth
                let words = alphabeticWordCount(phrase.text)
                if widthRatio >= 0.28 && words >= 5 && !looksTabularRow(phrase.text, segmentCount: 1) {
                    return false
                }
                if words > 5 && !looksTabularRow(phrase.text, segmentCount: phrases.count) {
                    return false
                }
            }
            return true
        }

        func rowIsSpanningCandidate(_ row: HorizontalRow) -> Bool {
            if rowHasSpanningCaption(row) {
                return true
            }
            let lrText = row.segments.map(\.text).joined(separator: " ")
            if row.lines.contains(where: { isSpanningLine($0, midX: midX, pageWidth: pageWidth) }) {
                if isMathEquationSegment(lrText) && !hasDenseTabularMetrics(lrText) {
                    return false
                }
                return true
            }

            guard (row.combinedWidth / pageWidth) > spanningLineWidthRatio,
                  row.minX < (midX - centralGutterCrossingHalfWidthPt),
                  row.maxX > (midX + centralGutterCrossingHalfWidthPt) else {
                return false
            }

            let parts = partitionRowAroundGutter(row)
            if !parts.bridge.isEmpty {
                return row.segments.count >= 3 && !isMathEquationSegment(lrText)
            }

            // Without any centerline-bridging cell, segments must appear on both sides (>= 3 total) and neither side may be a math equation
            guard !parts.left.isEmpty, !parts.right.isEmpty, row.segments.count >= 3 else {
                return false
            }
            let leftText = parts.left.map(\.text).joined(separator: " ")
            let rightText = parts.right.map(\.text).joined(separator: " ")
            if isMathEquationSegment(leftText) || isMathEquationSegment(rightText) {
                return false
            }
            return true
        }

        // Build contiguous vertical clusters of spanning candidate rows (gap <= 22 pt)
        var clusters: [[Int]] = []
        for rIdx in rows.indices where rowIsSpanningCandidate(rows[rIdx]) {
            if let lastCluster = clusters.last,
               let prevRowIdx = lastCluster.last,
               (rows[prevRowIdx].minY - rows[rIdx].maxY) <= 22.0 {
                clusters[clusters.count - 1].append(rIdx)
            } else {
                clusters.append([rIdx])
            }
        }

        var consumedLineIndices: Set<Int> = []
        var floatBlocks: [PositionedTextLine] = []

        for cluster in clusters {
            var expandedRowIndices = Set(cluster)
            // Attach immediately adjacent spanning caption rows within 20 pt (never single-column captions)
            if let firstR = cluster.first, firstR > 0 {
                let above = rows[firstR - 1]
                if (above.minY - rows[firstR].maxY) <= 20.0 && rowHasSpanningCaption(above) {
                    expandedRowIndices.insert(firstR - 1)
                }
            }
            if let lastR = cluster.last, lastR + 1 < rows.count {
                let below = rows[lastR + 1]
                if (rows[lastR].minY - below.maxY) <= 20.0 && rowHasSpanningCaption(below) {
                    expandedRowIndices.insert(lastR + 1)
                }
            }

            // When a spanning figure caption sits below its plot area (or above it), sweep contiguous unconsumed
            // chart/axis/tick/legend fragment rows (e.g. "Score (%)", numeric ticks, "(a)/(b)", legend boxes)
            // into the figure block, stopping immediately at any genuine prose line, heading, or prior float.
            let containsSpanningFigCaption = expandedRowIndices.contains {
                rowHasSpanningCaption(rows[$0]) && rowHasFigureCaption(rows[$0])
            }
            if containsSpanningFigCaption, let minR = expandedRowIndices.min() {
                var scanUp = minR - 1
                var prevMaxY = rows[minR].maxY
                var sweptUpCount = 0
                while scanUp >= 0 {
                    let candidateRow = rows[scanUp]
                    if candidateRow.indices.contains(where: { consumedLineIndices.contains($0) }) {
                        break
                    }
                    let stepGap = candidateRow.minY - prevMaxY
                    if stepGap > 95.0 {
                        break
                    }
                    guard isChartOrFloatFragmentRow(scanUp) else {
                        break
                    }
                    expandedRowIndices.insert(scanUp)
                    prevMaxY = candidateRow.maxY
                    sweptUpCount += 1
                    scanUp -= 1
                }

                // If the figure caption was placed above the plot rather than below, sweep downward through chart fragments
                if sweptUpCount == 0, let maxR = expandedRowIndices.max() {
                    var scanDown = maxR + 1
                    var prevMinY = rows[maxR].minY
                    while scanDown < rows.count {
                        let candidateRow = rows[scanDown]
                        if candidateRow.indices.contains(where: { consumedLineIndices.contains($0) }) {
                            break
                        }
                        let stepGap = prevMinY - candidateRow.maxY
                        if stepGap > 95.0 {
                            break
                        }
                        guard isChartOrFloatFragmentRow(scanDown) else {
                            break
                        }
                        expandedRowIndices.insert(scanDown)
                        prevMinY = candidateRow.minY
                        scanDown += 1
                    }
                }
            }

            // Bridge across a multi-column super-header row ONLY when a spanning caption sits immediately above it
            if !containsSpanningFigCaption, let minR = expandedRowIndices.min(), minR >= 2 {
                let above = rows[minR - 1]
                let captionAbove = rows[minR - 2]
                if !above.indices.contains(where: { consumedLineIndices.contains($0) }),
                   !captionAbove.indices.contains(where: { consumedLineIndices.contains($0) }),
                   (above.minY - rows[minR].maxY) <= 18.0,
                   above.segments.count >= 2,
                   isChartOrFloatFragmentRow(minR - 1),
                   (captionAbove.minY - above.maxY) <= 20.0,
                   rowHasSpanningCaption(captionAbove) {
                    expandedRowIndices.insert(minR - 1)
                    expandedRowIndices.insert(minR - 2)
                }
            }

            // Absorb wrapped second line of a bottom spanning caption when line 1 did not end a sentence
            if let maxR = expandedRowIndices.max(),
               maxR + 1 < rows.count,
               rowHasSpanningCaption(rows[maxR]) {
                let capText = rows[maxR].segments.map(\.text).joined(separator: " ")
                let nextRow = rows[maxR + 1]
                let nextParts = partitionRowAroundGutter(nextRow)
                if !endsSentence(capText),
                   !nextRow.indices.contains(where: { consumedLineIndices.contains($0) }),
                   (rows[maxR].minY - nextRow.maxY) <= 6.5,
                   nextParts.right.isEmpty,
                   nextParts.bridge.isEmpty,
                   abs(nextRow.minX - rows[maxR].minX) <= 12.0,
                   detectSectionHeading(nextRow.segments.map(\.text).joined(separator: " ")) == nil {
                    expandedRowIndices.insert(maxR + 1)
                }
            }

            var orderedRows = expandedRowIndices.sorted().map { rows[$0] }
            let rowTexts = orderedRows.map { r in
                r.segments.map(\.text).joined(separator: " ")
            }

            let hasSpanningCaption = orderedRows.contains { rowHasSpanningCaption($0) }
            if !hasSpanningCaption && isReferenceListCluster(orderedRows, rowTexts: rowTexts) {
                continue
            }

            let tabularRowCount = zip(orderedRows, rowTexts).filter { r, txt in
                let parts = partitionRowAroundGutter(r)
                let effectiveSegments: Int
                if !parts.bridge.isEmpty || r.lines.contains(where: { isSpanningLine($0, midX: midX, pageWidth: pageWidth) }) {
                    effectiveSegments = r.segments.count
                } else if !parts.left.isEmpty && !parts.right.isEmpty && r.segments.count >= 3 {
                    effectiveSegments = r.segments.count
                } else {
                    effectiveSegments = 1
                }
                return looksTabularRow(txt, segmentCount: effectiveSegments)
            }.count
            let startsLikeAbstract = rowTexts.first?.lowercased().hasPrefix("abstract") == true

            guard hasSpanningCaption || (tabularRowCount >= 2 && !startsLikeAbstract) else {
                continue
            }

            // Once validated as a genuine spanning table/figure, absorb any immediately adjacent (<= 18 pt) multi-column header row above it
            if !containsSpanningFigCaption, let minR = expandedRowIndices.min(), minR > 0 {
                let above = rows[minR - 1]
                if !above.indices.contains(where: { consumedLineIndices.contains($0) }),
                   (above.minY - rows[minR].maxY) <= 18.0,
                   above.segments.count >= 2,
                   isChartOrFloatFragmentRow(minR - 1) {
                    expandedRowIndices.insert(minR - 1)
                    orderedRows = expandedRowIndices.sorted().map { rows[$0] }
                }
            }

            let clusterMinY = orderedRows.map(\.minY).min() ?? 0.0
            let clusterMaxY = orderedRows.map(\.maxY).max() ?? 0.0

            // Sweep every content line on this page whose midY lies within the spanning float's Y interval
            // (captures narrow left/right table column headers like "Engine Variant" that do not cross midX)
            var clusterLines: [PositionedTextLine] = []
            for (idx, line) in contentLines.enumerated() where !consumedLineIndices.contains(idx) {
                if line.midY >= (clusterMinY - 2.5) && line.midY <= (clusterMaxY + 2.5) {
                    consumedLineIndices.insert(idx)
                    clusterLines.append(line)
                }
            }

            let mergedRows = mergeHorizontalRows(clusterLines)
            guard !mergedRows.isEmpty else { continue }
            let combinedText = mergedRows.map(\.text).joined(separator: " ")
            let floatBox = PositionedTextLine(
                text: combinedText,
                minX: mergedRows.map(\.minX).min() ?? 0.0,
                minY: mergedRows.map(\.minY).min() ?? 0.0,
                maxX: mergedRows.map(\.maxX).max() ?? 0.0,
                maxY: mergedRows.map(\.maxY).max() ?? 0.0
            )
            floatBlocks.append(floatBox)
        }

        let remaining = contentLines.enumerated().compactMap { idx, line in
            consumedLineIndices.contains(idx) ? nil : line
        }
        return (floatBlocks.sorted(by: sortTopDown), remaining)
    }

    // MARK: - Paragraph Grouping & Section Heading Detection

    private static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return false }
        if trimmed.range(of: #"^\[\d{1,4}\]$"#, options: .regularExpression) != nil {
            return false
        }
        return ".?!\"”)]".contains(last)
    }

    private static func shouldDehyphenateJoin(_ currentText: String, _ nextText: String) -> Bool {
        guard currentText.hasSuffix("-"), !currentText.hasSuffix("--") else { return false }
        let beforeHyphen = currentText.dropLast()
        guard let prevChar = beforeHyphen.last,
              prevChar.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }),
              let nextFirst = nextText.first,
              nextFirst.isLowercase else {
            return false
        }
        return true
    }

    private struct GroupedParagraph {
        let block: PositionedTextLine
        let detectedHeading: String?
    }

    private func groupLinesIntoParagraphs(_ lines: [PositionedTextLine]) -> [GroupedParagraph] {
        guard !lines.isEmpty else { return [] }
        let columnLeftMargin = lines.map(\.minX).min() ?? lines[0].minX

        var lineHeadings: [String?] = []
        lineHeadings.reserveCapacity(lines.count)
        for idx in lines.indices {
            if idx > 0 {
                let prev = lines[idx - 1]
                let cur = lines[idx]
                let sameHorizWithPrev = abs(prev.midY - cur.midY) <= 4.0 && cur.minX >= (prev.maxX - 2.0)
                if sameHorizWithPrev {
                    lineHeadings.append(nil)
                    continue
                }
            }
            let nextLineText: String?
            if idx + 1 < lines.count, (lines[idx].minY - lines[idx + 1].maxY) <= 20.0 {
                nextLineText = lines[idx + 1].text
            } else {
                nextLineText = nil
            }
            lineHeadings.append(Self.detectSectionHeading(lines[idx].text, nextLine: nextLineText))
        }

        var current = lines[0]
        var currentHeading = lineHeadings[0]
        var paragraphs: [GroupedParagraph] = []

        for idx in lines.indices.dropFirst() {
            let next = lines[idx]
            let nextHeading = lineHeadings[idx]
            let verticalGap = current.minY - next.maxY
            let sameHorizontalLine = abs(current.midY - next.midY) <= 4.0 && next.minX >= (current.maxX - 2.0)
            let currentIsHeading = (currentHeading != nil)
            let nextIsHeading = !sameHorizontalLine && (nextHeading != nil)
            let nextStartsCaption = !sameHorizontalLine && Self.isTableOrFigureCaption(next.text)
            let nextIsIndentedNewParagraph =
                !sameHorizontalLine
                && !currentIsHeading
                && (next.minX - columnLeftMargin) >= 6.5
                && (current.minX - columnLeftMargin) <= 3.5
                && Self.endsSentence(current.text)

            if currentIsHeading
                || nextIsHeading
                || nextStartsCaption
                || verticalGap > Self.paragraphVerticalGapThresholdPt
                || nextIsIndentedNewParagraph {
                paragraphs.append(GroupedParagraph(block: current, detectedHeading: currentHeading))
                current = next
                currentHeading = nextHeading
            } else {
                let joinedText: String
                if Self.shouldDehyphenateJoin(current.text, next.text) {
                    joinedText = String(current.text.dropLast()) + next.text
                } else {
                    joinedText = current.text + " " + next.text
                }
                current = PositionedTextLine(
                    text: joinedText,
                    minX: min(current.minX, next.minX),
                    minY: min(current.minY, next.minY),
                    maxX: max(current.maxX, next.maxX),
                    maxY: max(current.maxY, next.maxY)
                )
                let followingLineText: String? = (idx + 1 < lines.count && (current.minY - lines[idx + 1].maxY) <= 20.0)
                    ? lines[idx + 1].text
                    : nil
                currentHeading = Self.detectMultiLineWrappedHeading(current.text, nextLine: followingLineText)
            }
        }
        paragraphs.append(GroupedParagraph(block: current, detectedHeading: currentHeading))
        return paragraphs
    }

    public static func detectSectionHeading(_ line: String, nextLine: String? = nil) -> String? {
        guard let candidate = detectSingleLineSectionHeading(line, forceTitleCase: false) else { return nil }
        if let nextLine, nextLineContinuesSameSentence(nextLine, afterCandidateHeading: candidate) {
            return nil
        }
        return candidate
    }

    private static func detectMultiLineWrappedHeading(_ text: String, nextLine: String?) -> String? {
        guard let candidate = detectSingleLineSectionHeading(text, forceTitleCase: true) else { return nil }
        if let nextLine, nextLineContinuesSameSentence(nextLine, afterCandidateHeading: candidate) {
            return nil
        }
        return candidate
    }

    private static func nextLineContinuesSameSentence(
        _ nextRaw: String,
        afterCandidateHeading candidate: String
    ) -> Bool {
        let nextTrimmed = nextRaw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let firstChar = nextTrimmed.first else { return false }

        // 1. Next line begins with a lowercase word (excluding camelCase proper nouns such as iOS, macOS, vLLM, mRNA)
        if firstChar.isLetter && firstChar.isLowercase {
            let firstToken = nextTrimmed.prefix(while: { !$0.isWhitespace })
            if !firstToken.dropFirst().contains(where: \.isUppercase) {
                return true
            }
        }

        // 2. Next line begins with a bracketed citation (e.g. "[33], we can compute..."),
        //    unless the candidate heading itself introduces a bibliography section ("References", "Bibliography")
        if firstChar == "[" && !isBibliographyHeading(candidate) {
            return true
        }

        // 3. Next line begins with continuation or closing punctuation
        if ",.;:?!)]}—–".contains(firstChar) || nextTrimmed.hasPrefix("--") {
            return true
        }

        return false
    }

    private static func detectSingleLineSectionHeading(_ line: String, forceTitleCase: Bool = false) -> String? {
        let trimmed = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard trimmed.count >= 4, trimmed.count <= 80 else { return nil }
        guard let lastChar = trimmed.last, !".;,:-–—".contains(lastChar) else { return nil }
        guard trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "=<>$%[]{}")) == nil else {
            return nil
        }

        // First alphabetic character must be uppercase (rejects wrapped lowercase words at paragraph tails)
        guard let firstLetter = trimmed.first(where: { $0.isLetter }), firstLetter.isUppercase else {
            return nil
        }

        // 1. Standalone unnumbered academic headings
        let lower = trimmed.lowercased()
        if standaloneSectionTitles.contains(lower) {
            return trimmed
        }

        // 2. Appendix headings ("Appendix A", "Appendix B: Extended Proofs")
        if trimmed.range(of: #"^(?:Appendix|APPENDIX)\s+[A-Z0-9]{1,3}(?:[:.]?\s+[A-Z].*)?$"#, options: .regularExpression) != nil {
            return trimmed
        }

        // 3. Roman-numeral headings I..XV ("I. Introduction", "II. Related Work", "XIV. Extended Limitations")
        if let titleBody = matchNumberedPrefix(
            in: trimmed,
            pattern: #"^(?:I|II|III|IV|V|VI|VII|VIII|IX|X|XI|XII|XIII|XIV|XV)\.\s+(.+)$"#
        ) {
            if isValidHeadingTitleBody(titleBody, requireTitleCase: forceTitleCase) {
                return trimmed
            }
            return nil
        }

        // 4. Dotted Arabic section or multi-level subsection ("3. Methodology", "3.1 Geometric Partitioning", "2.1.2 Setup")
        if let titleBody = matchNumberedPrefix(
            in: trimmed,
            pattern: #"^(?:(?:[1-9]|1[0-9]|20)(?:\.\d{1,2})+\.?|(?:[1-9]|1[0-9]|20)\.)\s+(.+)$"#
        ) {
            if isValidHeadingTitleBody(titleBody, requireTitleCase: forceTitleCase) {
                return trimmed
            }
            return nil
        }

        // 5. Undotted Arabic integer 1..20 + Title-Case / Uppercase heading ("1 Introduction", "4 Experimental Evaluation")
        if let titleBody = matchNumberedPrefix(
            in: trimmed,
            pattern: #"^(?:[1-9]|1[0-9]|20)\s+(.+)$"#
        ) {
            if isValidHeadingTitleBody(titleBody, requireTitleCase: true) {
                return trimmed
            }
            return nil
        }

        return nil
    }

    private func detectSectionHeading(_ line: String) -> String? {
        Self.detectSectionHeading(line)
    }

    private static let standaloneSectionTitles: Set<String> = [
        "abstract",
        "introduction",
        "background",
        "preliminaries",
        "overview",
        "related work",
        "prior work",
        "literature review",
        "methodology",
        "methods",
        "method",
        "proposed method",
        "approach",
        "system design",
        "architecture",
        "implementation",
        "experimental setup",
        "experimental evaluation",
        "experiments",
        "evaluation",
        "empirical evaluation",
        "results",
        "results and discussion",
        "discussion",
        "analysis",
        "ablation study",
        "limitations",
        "threats to validity",
        "ethical considerations",
        "broader impact",
        "conclusion",
        "conclusions",
        "conclusion and future work",
        "future work",
        "summary",
        "acknowledgments",
        "acknowledgements",
        "acknowledgment",
        "acknowledgement",
        "references",
        "bibliography",
        "works cited",
        "literature cited",
        "references and notes",
        "appendix",
        "appendices",
        "supplementary material"
    ]

    private static let minorTitleConnectors: Set<String> = [
        "a", "an", "the", "of", "in", "on", "for", "and", "or", "to", "with",
        "vs", "vs.", "from", "by", "at", "via", "over", "under", "across",
        "without", "into", "between", "through", "as", "&"
    ]

    private static let finiteProseVerbs: Set<String> = [
        "is", "are", "was", "were", "have", "has", "had", "can", "could",
        "will", "would", "should", "may", "might", "must", "remained",
        "achieved", "completes", "evaluates", "requires", "required",
        "vanishes", "vanish", "holds", "follows", "implies", "denotes"
    ]

    private static func matchNumberedPrefix(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges >= 2,
              let bodyRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[bodyRange])
    }

    private static func isValidHeadingTitleBody(_ body: String, requireTitleCase: Bool) -> Bool {
        let words = body.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 9 else { return false }

        // First word must begin with an uppercase letter (blocks "18 distinct conference templates", "368 regression tests")
        guard let firstChar = words[0].first, firstChar.isLetter, firstChar.isUppercase else {
            return false
        }

        // Reject author middle/first initials like "I. Goodfellow and Y. Bengio" or "A. Rivera"
        if body.range(of: #"\b[A-Z]\."#, options: .regularExpression) != nil {
            return false
        }

        let nonSpaceScalars = body.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        let letterScalars = nonSpaceScalars.filter { CharacterSet.letters.contains($0) }
        guard letterScalars.count >= 3,
              Double(letterScalars.count) / Double(max(1, nonSpaceScalars.count)) >= 0.50 else {
            return false
        }

        for word in words {
            let lowerWord = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if finiteProseVerbs.contains(lowerWord) {
                return false
            }
        }

        if requireTitleCase {
            for word in words {
                let lowerWord = word.lowercased()
                if minorTitleConnectors.contains(lowerWord) { continue }
                // Allow trailing section numbers or acronyms/hyphenated capitalized compounds
                if word.allSatisfy(\.isNumber) { continue }
                guard let firstAlpha = word.first(where: { $0.isLetter }), firstAlpha.isUppercase else {
                    return false
                }
            }
        }

        return true
    }
}

// MARK: - Synthetic Multi-Column Academic PDF Generator (For Demos & End-to-End Tests)

public enum SyntheticAcademicPDFBuilder {
    public static func renderTwoColumnPaperPDF(
        title: String,
        authors: String,
        abstractParagraph: String,
        leftColumnParagraphs: [(heading: String, body: String)],
        rightColumnParagraphs: [(heading: String, body: String)]
    ) -> Data {
        let outData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        guard let consumer = CGDataConsumer(data: outData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        ctx.beginPDFPage(nil)
        drawTextBlock(title, in: CGRect(x: 48, y: 716, width: 516, height: 42), fontSize: 15, bold: true, ctx: ctx)
        drawTextBlock(authors, in: CGRect(x: 48, y: 692, width: 516, height: 20), fontSize: 10, bold: false, ctx: ctx)
        drawTextBlock("Abstract", in: CGRect(x: 48, y: 664, width: 516, height: 18), fontSize: 11, bold: true, ctx: ctx)
        drawTextBlock(abstractParagraph, in: CGRect(x: 48, y: 586, width: 516, height: 74), fontSize: 9.5, bold: false, ctx: ctx)

        var leftY: CGFloat = 548
        for item in leftColumnParagraphs {
            drawTextBlock(item.heading, in: CGRect(x: 48, y: leftY - 16, width: 244, height: 16), fontSize: 10.5, bold: true, ctx: ctx)
            leftY -= 20
            drawTextBlock(item.body, in: CGRect(x: 48, y: leftY - 130, width: 244, height: 128), fontSize: 9.2, bold: false, ctx: ctx)
            leftY -= 146
        }

        var rightY: CGFloat = 548
        for item in rightColumnParagraphs {
            drawTextBlock(item.heading, in: CGRect(x: 320, y: rightY - 16, width: 244, height: 16), fontSize: 10.5, bold: true, ctx: ctx)
            rightY -= 20
            drawTextBlock(item.body, in: CGRect(x: 320, y: rightY - 130, width: 244, height: 128), fontSize: 9.2, bold: false, ctx: ctx)
            rightY -= 146
        }

        ctx.endPDFPage()
        ctx.closePDF()
        return outData as Data
    }

    private static func drawTextBlock(_ text: String, in rect: CGRect, fontSize: CGFloat, bold: Bool, ctx: CGContext) {
        let fontName = bold ? "Helvetica-Bold" : "Helvetica"
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 0.08, alpha: 1.0)
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attrStr.length), path, nil)
        CTFrameDraw(frame, ctx)
    }
}
