import CoreGraphics
import CoreText
import Foundation
import PDFKit
import ScholarModels

// MARK: - Synthetic Two-Column Academic PDF Typography & Document Specifications

/// Standard academic typesetting geometry presets (US Letter & A4 conference/journal layouts).
public enum SyntheticPaperTypographyPreset: String, Sendable, Codable, Hashable, CaseIterable {
    case acmSigplanTwoColumn = "ACM SIGPLAN Two-Column (US Letter)"
    case ieeeTransactionsTwoColumn = "IEEE Transactions Two-Column (US Letter)"
    case neuripsWorkshopTwoColumn = "NeurIPS / ICML Compact Two-Column"
    case natureResearchTwoColumn = "Nature Portfolio Two-Column (A4)"

    public var pageSizePoints: CGSize {
        switch self {
        case .natureResearchTwoColumn:
            return CGSize(width: 595.28, height: 841.89) // ISO A4
        case .acmSigplanTwoColumn, .ieeeTransactionsTwoColumn, .neuripsWorkshopTwoColumn:
            return CGSize(width: 612.0, height: 792.0)   // US Letter
        }
    }

    public var horizontalMarginPt: Double {
        switch self {
        case .acmSigplanTwoColumn: return 46.0
        case .ieeeTransactionsTwoColumn: return 42.0
        case .neuripsWorkshopTwoColumn: return 48.0
        case .natureResearchTwoColumn: return 44.0
        }
    }

    public var topMarginPt: Double { 50.0 }
    public var bottomMarginPt: Double { 50.0 }

    public var columnGutterPt: Double {
        switch self {
        case .ieeeTransactionsTwoColumn: return 16.0
        default: return 20.0
        }
    }

    public var bodyFontName: String {
        switch self {
        case .acmSigplanTwoColumn, .ieeeTransactionsTwoColumn:
            return "Times-Roman"
        case .neuripsWorkshopTwoColumn, .natureResearchTwoColumn:
            return "Helvetica"
        }
    }

    public var boldFontName: String {
        switch self {
        case .acmSigplanTwoColumn, .ieeeTransactionsTwoColumn:
            return "Times-Bold"
        case .neuripsWorkshopTwoColumn, .natureResearchTwoColumn:
            return "Helvetica-Bold"
        }
    }

    public var italicFontName: String {
        switch self {
        case .acmSigplanTwoColumn, .ieeeTransactionsTwoColumn:
            return "Times-Italic"
        case .neuripsWorkshopTwoColumn, .natureResearchTwoColumn:
            return "Helvetica-Oblique"
        }
    }

    public var monospaceFontName: String { "Courier" }

    public var bodyFontSizePt: Double {
        switch self {
        case .ieeeTransactionsTwoColumn: return 9.5
        default: return 9.2
        }
    }
}

/// Vector bar-series datum rendered programmatically inside a synthetic academic figure.
public struct SyntheticFigureBarDatum: Sendable, Codable, Hashable, Identifiable {
    public var id: String { seriesLabel }
    public let seriesLabel: String
    public let numericValue: Double
    public let formattedValueTag: String
    public let isHighlightedMethod: Bool

    public init(
        seriesLabel: String,
        numericValue: Double,
        formattedValueTag: String,
        isHighlightedMethod: Bool = false
    ) {
        self.seriesLabel = seriesLabel
        self.numericValue = numericValue
        self.formattedValueTag = formattedValueTag
        self.isHighlightedMethod = isHighlightedMethod
    }
}

/// Specification for a single-column embedded vector chart + caption inside a synthetic paper.
public struct SyntheticFigureSpec: Sendable, Codable, Hashable, Identifiable {
    public var id: String { figureNumberTag }
    public let figureNumberTag: String
    public let captionText: String
    public let yAxisUnitLabel: String
    public let bars: [SyntheticFigureBarDatum]

    public init(
        figureNumberTag: String,
        captionText: String,
        yAxisUnitLabel: String,
        bars: [SyntheticFigureBarDatum]
    ) {
        self.figureNumberTag = figureNumberTag
        self.captionText = captionText
        self.yAxisUnitLabel = yAxisUnitLabel
        self.bars = bars
    }
}

/// Specification for a `booktabs`-styled quantitative benchmark table inside a column or full-width banner.
public struct SyntheticBooktabsTableSpec: Sendable, Codable, Hashable, Identifiable {
    public var id: String { tableNumberTag }
    public let tableNumberTag: String
    public let captionText: String
    public let columnHeaders: [String]
    public let rows: [[String]]

    public init(
        tableNumberTag: String,
        captionText: String,
        columnHeaders: [String],
        rows: [[String]]
    ) {
        self.tableNumberTag = tableNumberTag
        self.captionText = captionText
        self.columnHeaders = columnHeaders
        self.rows = rows
    }

    /// Plain-text linearized form mirroring how `PDFKit` line selection reads tabular rows.
    public var plainLinearizedSummary: String {
        let headerLine = columnHeaders.joined(separator: " | ")
        let rowLines = rows.map { $0.joined(separator: " | ") }.joined(separator: " ; ")
        return "\(tableNumberTag): \(captionText) — \(headerLine) — \(rowLines)"
    }
}

/// Content element within a body section of a synthetic two-column academic paper.
public enum SyntheticSectionElement: Sendable, Codable, Hashable {
    case bodyParagraph(text: String, sourceTeXLine: Int?)
    case displayEquation(equationNumber: String, formulaText: String, sourceTeXLine: Int?)
    case vectorFigure(SyntheticFigureSpec)
    case benchmarkTable(SyntheticBooktabsTableSpec)
}

/// Numbered section in a synthetic academic paper (`1 Introduction`, `2 Architecture`, `3 Evaluation`, etc.).
public struct SyntheticPaperSectionSpec: Sendable, Codable, Hashable, Identifiable {
    public var id: String { headingTitle }
    public let headingTitle: String
    public let sourceTeXLine: Int?
    public let elements: [SyntheticSectionElement]

    public init(
        headingTitle: String,
        sourceTeXLine: Int? = nil,
        elements: [SyntheticSectionElement]
    ) {
        self.headingTitle = headingTitle
        self.sourceTeXLine = sourceTeXLine
        self.elements = elements
    }
}

/// Complete declarative blueprint for generating a multi-page two-column academic PDF fixture.
public struct SyntheticPaperFixtureSpec: Sendable, Codable, Hashable, Identifiable {
    public var id: String { citeKey }
    public let citeKey: String
    public let pdfFileName: String
    public let sourceTeXFileName: String
    public let typography: SyntheticPaperTypographyPreset
    public let runningVenueBanner: String
    public let doiIdentifier: String
    public let paperTitle: String
    public let authorsLine: String
    public let affiliationsLine: String
    public let abstractText: String
    public let keywords: [String]
    public let sections: [SyntheticPaperSectionSpec]
    public let formattedReferences: [String]

    public init(
        citeKey: String,
        pdfFileName: String,
        sourceTeXFileName: String = "main.tex",
        typography: SyntheticPaperTypographyPreset = .acmSigplanTwoColumn,
        runningVenueBanner: String,
        doiIdentifier: String,
        paperTitle: String,
        authorsLine: String,
        affiliationsLine: String,
        abstractText: String,
        keywords: [String],
        sections: [SyntheticPaperSectionSpec],
        formattedReferences: [String]
    ) {
        self.citeKey = citeKey
        self.pdfFileName = pdfFileName
        self.sourceTeXFileName = sourceTeXFileName
        self.typography = typography
        self.runningVenueBanner = runningVenueBanner
        self.doiIdentifier = doiIdentifier
        self.paperTitle = paperTitle
        self.authorsLine = authorsLine
        self.affiliationsLine = affiliationsLine
        self.abstractText = abstractText
        self.keywords = keywords
        self.sections = sections
        self.formattedReferences = formattedReferences
    }
}

// MARK: - Ground-Truth Bounding-Box Manifest & Segmentation Benchmark Models

public enum SyntheticGroundTruthBlockKind: String, Sendable, Codable, Hashable, CaseIterable {
    case runningBanner = "Running Header"
    case titleBanner = "Title"
    case authorBlock = "Authors & Affiliations"
    case abstractBox = "Abstract"
    case sectionHeading = "Section Heading"
    case bodyParagraph = "Body Paragraph"
    case displayEquation = "Display Equation"
    case figureGraphicAndCaption = "Figure & Caption"
    case benchmarkTableAndCaption = "Table & Caption"
    case bibliographyReference = "Reference Entry"
}

/// Exact coordinate ground truth emitted during CoreGraphics PDF typesetting.
public struct SyntheticGroundTruthRegion: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let kind: SyntheticGroundTruthBlockKind
    public let sectionTitle: String
    /// `0` = full-width spanning block, `1` = left column, `2` = right column.
    public let columnIndex: Int
    public let readingSequenceOrder: Int
    public let boundingBox: PDFPageRegionBox
    public let groundTruthText: String
    public let sourceTeXLine: Int?

    public init(
        id: String,
        kind: SyntheticGroundTruthBlockKind,
        sectionTitle: String,
        columnIndex: Int,
        readingSequenceOrder: Int,
        boundingBox: PDFPageRegionBox,
        groundTruthText: String,
        sourceTeXLine: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sectionTitle = sectionTitle
        self.columnIndex = columnIndex
        self.readingSequenceOrder = readingSequenceOrder
        self.boundingBox = boundingBox
        self.groundTruthText = groundTruthText
        self.sourceTeXLine = sourceTeXLine
    }
}

/// Result of rendering a synthetic multi-page two-column academic PDF in memory or on disk.
public struct RenderedAcademicPDFFixture: Sendable, Codable, Hashable {
    public let citeKey: String
    public let pdfFileName: String
    public let pdfData: Data
    public let pageCount: Int
    public let groundTruthRegions: [SyntheticGroundTruthRegion]
    public let syncTeXAnchors: [SyncTeXAnchor]

    public init(
        citeKey: String,
        pdfFileName: String,
        pdfData: Data,
        pageCount: Int,
        groundTruthRegions: [SyntheticGroundTruthRegion],
        syncTeXAnchors: [SyncTeXAnchor]
    ) {
        self.citeKey = citeKey
        self.pdfFileName = pdfFileName
        self.pdfData = pdfData
        self.pageCount = pageCount
        self.groundTruthRegions = groundTruthRegions
        self.syncTeXAnchors = syncTeXAnchors
    }

    /// Converts ground-truth narrative/table/caption blocks directly into `PDFPassageChunk` records.
    public func expectedPassageChunks() -> [PDFPassageChunk] {
        groundTruthRegions
            .filter {
                switch $0.kind {
                case .abstractBox, .bodyParagraph, .figureGraphicAndCaption, .benchmarkTableAndCaption:
                    return true
                default:
                    return false
                }
            }
            .enumerated()
            .map { idx, reg in
                PDFPassageChunk(
                    id: "\(citeKey)#gt-\(idx + 1)",
                    citeKey: citeKey,
                    pdfFileName: pdfFileName,
                    sectionTitle: reg.sectionTitle,
                    columnIndex: reg.columnIndex,
                    readingSequence: idx + 1,
                    boundingBox: reg.boundingBox,
                    passageText: reg.groundTruthText
                )
            }
    }
}

/// Quantitative geometric & reading-order evaluation of `PDFMultiColumnSegmenter` against ground-truth coordinates.
public struct SegmentationGeometricBenchmarkReport: Sendable, Codable, Hashable {
    public let citeKey: String
    public let pageCount: Int
    public let groundTruthBodyBlockCount: Int
    public let extractedPassageChunkCount: Int
    public let meanBoundingBoxIoU: Double
    public let columnClassificationAccuracy: Double
    public let kendallTauReadingOrderCorrelation: Double
    public let quantitativeTokenPreservationRate: Double

    public init(
        citeKey: String,
        pageCount: Int,
        groundTruthBodyBlockCount: Int,
        extractedPassageChunkCount: Int,
        meanBoundingBoxIoU: Double,
        columnClassificationAccuracy: Double,
        kendallTauReadingOrderCorrelation: Double,
        quantitativeTokenPreservationRate: Double
    ) {
        self.citeKey = citeKey
        self.pageCount = pageCount
        self.groundTruthBodyBlockCount = groundTruthBodyBlockCount
        self.extractedPassageChunkCount = extractedPassageChunkCount
        self.meanBoundingBoxIoU = meanBoundingBoxIoU
        self.columnClassificationAccuracy = columnClassificationAccuracy
        self.kendallTauReadingOrderCorrelation = kendallTauReadingOrderCorrelation
        self.quantitativeTokenPreservationRate = quantitativeTokenPreservationRate
    }
}

/// Complete self-contained testbed bundle with rendered PDFs, bibliography entries, and grounded + adversarial test claims.
public struct SyntheticProvenanceBenchmarkBundle: Sendable, Codable, Hashable {
    public let fixtures: [RenderedAcademicPDFFixture]
    public let bibliographyEntries: [BibliographyEntry]
    public let sampleManuscriptWithGroundedAndMismatchedClaims: String

    public init(
        fixtures: [RenderedAcademicPDFFixture],
        bibliographyEntries: [BibliographyEntry],
        sampleManuscriptWithGroundedAndMismatchedClaims: String
    ) {
        self.fixtures = fixtures
        self.bibliographyEntries = bibliographyEntries
        self.sampleManuscriptWithGroundedAndMismatchedClaims = sampleManuscriptWithGroundedAndMismatchedClaims
    }
}

// MARK: - CoreGraphics / CoreText Multi-Page Two-Column Academic PDF Generator

/// Programmatically typesets deterministic, multi-page, two-column academic PDFs using CoreGraphics + CoreText + PDFKit.
public struct SyntheticAcademicPDFFixtureGenerator: Sendable {
    public init() {}

    // MARK: 1. In-Memory & Disk Multi-Page Two-Column PDF Renderer

    /// Renders `spec` into a real multi-page vector PDF (`Data`) alongside exact ground-truth bounding boxes and `SyncTeXAnchor` mappings.
    public func renderAcademicPDF(spec: SyntheticPaperFixtureSpec) throws -> RenderedAcademicPDFFixture {
        let preset = spec.typography
        let pageSize = preset.pageSizePoints
        let pageW = Double(pageSize.width)
        let pageH = Double(pageSize.height)
        let marginX = preset.horizontalMarginPt
        let gutter = preset.columnGutterPt
        let fullSpanWidth = pageW - 2.0 * marginX
        let colWidth = (fullSpanWidth - gutter) * 0.5
        let leftColX = marginX
        let rightColX = marginX + colWidth + gutter
        let minBodyY = preset.bottomMarginPt + 12.0
        let standardTopBodyY = pageH - preset.topMarginPt - 18.0

        let outData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: outData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ScholarOSError.pdfExtractionFailure("Failed to initialize CoreGraphics PDF context for '\(spec.pdfFileName)'.")
        }

        var groundTruth: [SyntheticGroundTruthRegion] = []
        var syncAnchors: [SyncTeXAnchor] = []
        var readingSeq = 0
        var currentPageIndex = 0
        var activeColumn = 1 // 1 = left column, 2 = right column
        var cursorY = standardTopBodyY

        func recordGroundTruth(
            kind: SyntheticGroundTruthBlockKind,
            section: String,
            col: Int,
            rect: CGRect,
            text: String,
            texLine: Int? = nil
        ) {
            readingSeq += 1
            let bbox = PDFPageRegionBox(
                pageIndex: currentPageIndex,
                x: Double(rect.minX),
                y: Double(rect.minY),
                width: Double(rect.width),
                height: Double(rect.height)
            )
            groundTruth.append(
                SyntheticGroundTruthRegion(
                    id: "\(spec.citeKey)#r\(readingSeq)",
                    kind: kind,
                    sectionTitle: section,
                    columnIndex: col,
                    readingSequenceOrder: readingSeq,
                    boundingBox: bbox,
                    groundTruthText: text,
                    sourceTeXLine: texLine
                )
            )
            if let texLine {
                syncAnchors.append(
                    SyncTeXAnchor(
                        sourceFile: spec.sourceTeXFileName,
                        line: texLine,
                        column: 1,
                        pdfPageIndex: currentPageIndex,
                        xPt: Double(rect.minX),
                        yPt: Double(rect.minY),
                        widthPt: Double(rect.width),
                        heightPt: Double(rect.height)
                    )
                )
            }
        }

        func drawPageChrome(pageIdx: Int) {
            // Running conference/journal header & bottom page folio
            let headerText = pageIdx == 0
                ? "\(spec.runningVenueBanner)  ·  DOI: \(spec.doiIdentifier)"
                : "\(spec.runningVenueBanner)  —  \(spec.paperTitle)"
            let headerRect = CGRect(x: marginX, y: pageH - 34.0, width: fullSpanWidth, height: 12.0)
            Self.drawStyledText(
                headerText,
                in: headerRect,
                fontName: preset.italicFontName,
                fontSize: 7.8,
                grayLevel: 0.36,
                ctx: ctx
            )
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(gray: 0.72, alpha: 1.0))
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: marginX, y: pageH - 37.0))
            ctx.addLine(to: CGPoint(x: pageW - marginX, y: pageH - 37.0))
            ctx.strokePath()
            ctx.restoreGState()

            let footerRect = CGRect(x: marginX, y: 24.0, width: fullSpanWidth, height: 12.0)
            Self.drawStyledText(
                "Page \(pageIdx + 1)  ·  ScholarOS Deterministic Provenance Fixture (\(spec.citeKey))",
                in: footerRect,
                fontName: preset.bodyFontName,
                fontSize: 7.8,
                grayLevel: 0.42,
                ctx: ctx
            )
        }

        func advanceToNextColumnOrPage() {
            if activeColumn == 1 {
                activeColumn = 2
                cursorY = currentPageIndex == 0 ? pageOneColumnStartY : standardTopBodyY
            } else {
                ctx.endPDFPage()
                currentPageIndex += 1
                ctx.beginPDFPage(nil)
                drawPageChrome(pageIdx: currentPageIndex)
                activeColumn = 1
                cursorY = standardTopBodyY
            }
        }

        func currentColumnX() -> Double {
            activeColumn == 1 ? leftColX : rightColX
        }

        // Begin Page 1 & render full-width Spanning Front Matter (Title, Authors, Affiliations, Abstract, Keywords)
        ctx.beginPDFPage(nil)
        drawPageChrome(pageIdx: 0)

        var bannerY = pageH - preset.topMarginPt - 4.0

        // 1. Paper Title
        let titleHeight = Self.measureTextHeight(
            spec.paperTitle,
            width: fullSpanWidth,
            fontName: preset.boldFontName,
            fontSize: 15.5
        ) + 4.0
        let titleRect = CGRect(x: marginX, y: bannerY - titleHeight, width: fullSpanWidth, height: titleHeight)
        Self.drawStyledText(spec.paperTitle, in: titleRect, fontName: preset.boldFontName, fontSize: 15.5, grayLevel: 0.05, ctx: ctx)
        recordGroundTruth(kind: .titleBanner, section: "Front Matter & Abstract", col: 0, rect: titleRect, text: spec.paperTitle, texLine: 1)
        bannerY -= (titleHeight + 6.0)

        // 2. Authors & Affiliations
        let authorCombined = "\(spec.authorsLine)\n\(spec.affiliationsLine)"
        let authorH = Self.measureTextHeight(authorCombined, width: fullSpanWidth, fontName: preset.bodyFontName, fontSize: 9.8) + 4.0
        let authorRect = CGRect(x: marginX, y: bannerY - authorH, width: fullSpanWidth, height: authorH)
        Self.drawStyledText(authorCombined, in: authorRect, fontName: preset.bodyFontName, fontSize: 9.8, grayLevel: 0.18, ctx: ctx)
        recordGroundTruth(kind: .authorBlock, section: "Front Matter & Abstract", col: 0, rect: authorRect, text: authorCombined, texLine: 4)
        bannerY -= (authorH + 10.0)

        // 3. Spanning Abstract Box with light linen tint & rule
        let abstractHeading = "Abstract"
        let keywordsFooter = spec.keywords.isEmpty ? "" : "Keywords: " + spec.keywords.joined(separator: "; ")
        let abstractFullBody = keywordsFooter.isEmpty ? spec.abstractText : "\(spec.abstractText)\n\(keywordsFooter)"
        let absBodyH = Self.measureTextHeight(abstractFullBody, width: fullSpanWidth - 20.0, fontName: preset.bodyFontName, fontSize: 9.0) + 6.0
        let totalAbsBoxH = absBodyH + 24.0
        let absBoxRect = CGRect(x: marginX, y: bannerY - totalAbsBoxH, width: fullSpanWidth, height: totalAbsBoxH)

        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 0.968, green: 0.962, blue: 0.945, alpha: 1.0))
        ctx.setStrokeColor(CGColor(srgbRed: 0.78, green: 0.75, blue: 0.69, alpha: 1.0))
        ctx.setLineWidth(0.7)
        ctx.addRect(absBoxRect)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()

        let absHeadRect = CGRect(x: marginX + 10.0, y: absBoxRect.maxY - 17.0, width: fullSpanWidth - 20.0, height: 13.0)
        Self.drawStyledText(abstractHeading, in: absHeadRect, fontName: preset.boldFontName, fontSize: 10.0, grayLevel: 0.08, ctx: ctx)

        let absTextRect = CGRect(x: marginX + 10.0, y: absBoxRect.minY + 5.0, width: fullSpanWidth - 20.0, height: absBodyH)
        Self.drawStyledText(abstractFullBody, in: absTextRect, fontName: preset.bodyFontName, fontSize: 9.0, grayLevel: 0.10, ctx: ctx)
        recordGroundTruth(
            kind: .abstractBox,
            section: "Abstract",
            col: 0,
            rect: absBoxRect,
            text: "Abstract. " + abstractFullBody,
            texLine: 8
        )

        let pageOneColumnStartY = Double(absBoxRect.minY) - 16.0
        cursorY = pageOneColumnStartY
        activeColumn = 1

        // 4. Flow Two-Column Sections, Paragraphs, Equations, Vector Figures & Booktabs Tables
        for section in spec.sections {
            let headH = Self.measureTextHeight(section.headingTitle, width: colWidth, fontName: preset.boldFontName, fontSize: 10.8) + 4.0
            // Keep heading attached to at least 36 pt of following content (widow/orphan prevention)
            if cursorY - (headH + 38.0) < minBodyY {
                advanceToNextColumnOrPage()
            }
            let hRect = CGRect(x: currentColumnX(), y: cursorY - headH, width: colWidth, height: headH)
            Self.drawStyledText(section.headingTitle, in: hRect, fontName: preset.boldFontName, fontSize: 10.8, grayLevel: 0.06, ctx: ctx)
            recordGroundTruth(
                kind: .sectionHeading,
                section: section.headingTitle,
                col: activeColumn,
                rect: hRect,
                text: section.headingTitle,
                texLine: section.sourceTeXLine
            )
            cursorY -= (headH + 5.0)

            for element in section.elements {
                switch element {
                case .bodyParagraph(let paraText, let texLine):
                    // Flow paragraph across column/page boundaries if needed using CoreText fitRange!
                    var remaining = paraText
                    var isFirstChunk = true
                    while !remaining.isEmpty {
                        let availableH = cursorY - minBodyY
                        if availableH < 26.0 {
                            advanceToNextColumnOrPage()
                            continue
                        }
                        let (drawnSubstring, usedHeight) = Self.drawFlowingParagraphSlice(
                            remaining,
                            x: currentColumnX(),
                            topY: cursorY,
                            width: colWidth,
                            maxHeight: availableH,
                            fontName: preset.bodyFontName,
                            fontSize: preset.bodyFontSizePt,
                            ctx: ctx
                        )
                        guard !drawnSubstring.isEmpty else {
                            advanceToNextColumnOrPage()
                            continue
                        }
                        let sliceRect = CGRect(x: currentColumnX(), y: cursorY - usedHeight, width: colWidth, height: usedHeight)
                        recordGroundTruth(
                            kind: .bodyParagraph,
                            section: section.headingTitle,
                            col: activeColumn,
                            rect: sliceRect,
                            text: drawnSubstring,
                            texLine: isFirstChunk ? texLine : nil
                        )
                        isFirstChunk = false
                        cursorY -= (usedHeight + 6.5)

                        if drawnSubstring.count >= remaining.count {
                            remaining = ""
                        } else {
                            let dropIdx = remaining.index(remaining.startIndex, offsetBy: drawnSubstring.count)
                            remaining = String(remaining[dropIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !remaining.isEmpty {
                                advanceToNextColumnOrPage()
                            }
                        }
                    }

                case .displayEquation(let eqNum, let formula, let texLine):
                    let eqBoxH = 26.0
                    if cursorY - eqBoxH < minBodyY {
                        advanceToNextColumnOrPage()
                    }
                    let eqRect = CGRect(x: currentColumnX(), y: cursorY - eqBoxH, width: colWidth, height: eqBoxH)
                    ctx.saveGState()
                    ctx.setFillColor(CGColor(gray: 0.965, alpha: 1.0))
                    ctx.addRect(eqRect)
                    ctx.fillPath()
                    ctx.restoreGState()

                    let eqDisplay = "    \(formula)    (\(eqNum))"
                    Self.drawStyledText(
                        eqDisplay,
                        in: eqRect.insetBy(dx: 6.0, dy: 5.0),
                        fontName: preset.italicFontName,
                        fontSize: 9.2,
                        grayLevel: 0.08,
                        ctx: ctx
                    )
                    recordGroundTruth(
                        kind: .displayEquation,
                        section: section.headingTitle,
                        col: activeColumn,
                        rect: eqRect,
                        text: "\(formula) (\(eqNum))",
                        texLine: texLine
                    )
                    cursorY -= (eqBoxH + 7.0)

                case .vectorFigure(let figSpec):
                    let captionFull = "\(figSpec.figureNumberTag). \(figSpec.captionText)"
                    let capH = Self.measureTextHeight(captionFull, width: colWidth - 8.0, fontName: preset.bodyFontName, fontSize: 8.4) + 6.0
                    let plotH = 108.0
                    let totalFigH = plotH + capH + 10.0
                    if cursorY - totalFigH < minBodyY {
                        advanceToNextColumnOrPage()
                    }
                    let totalRect = CGRect(x: currentColumnX(), y: cursorY - totalFigH, width: colWidth, height: totalFigH)
                    let plotRect = CGRect(x: currentColumnX() + 4.0, y: totalRect.minY + capH + 6.0, width: colWidth - 8.0, height: plotH)
                    Self.drawVectorBarChart(figSpec, in: plotRect, preset: preset, ctx: ctx)

                    let capRect = CGRect(x: currentColumnX() + 4.0, y: totalRect.minY + 2.0, width: colWidth - 8.0, height: capH)
                    Self.drawStyledText(captionFull, in: capRect, fontName: preset.bodyFontName, fontSize: 8.4, grayLevel: 0.12, ctx: ctx)

                    let barValuesSummary = figSpec.bars.map { "\($0.seriesLabel): \($0.formattedValueTag)" }.joined(separator: ", ")
                    recordGroundTruth(
                        kind: .figureGraphicAndCaption,
                        section: section.headingTitle,
                        col: activeColumn,
                        rect: totalRect,
                        text: "\(captionFull) [\(barValuesSummary)]"
                    )
                    cursorY -= (totalFigH + 8.0)

                case .benchmarkTable(let tabSpec):
                    let capTitle = "\(tabSpec.tableNumberTag). \(tabSpec.captionText)"
                    let capH = Self.measureTextHeight(capTitle, width: colWidth, fontName: preset.boldFontName, fontSize: 8.4) + 4.0
                    let rowH = 14.5
                    let tableGridH = Double(tabSpec.rows.count + 1) * rowH + 8.0
                    let totalTabH = capH + tableGridH + 4.0
                    if cursorY - totalTabH < minBodyY {
                        advanceToNextColumnOrPage()
                    }
                    let totalRect = CGRect(x: currentColumnX(), y: cursorY - totalTabH, width: colWidth, height: totalTabH)
                    let capRect = CGRect(x: currentColumnX(), y: totalRect.maxY - capH, width: colWidth, height: capH)
                    Self.drawStyledText(capTitle, in: capRect, fontName: preset.boldFontName, fontSize: 8.4, grayLevel: 0.08, ctx: ctx)

                    let gridRect = CGRect(x: currentColumnX(), y: totalRect.minY, width: colWidth, height: tableGridH)
                    Self.drawBooktabsTable(tabSpec, in: gridRect, rowHeight: rowH, preset: preset, ctx: ctx)

                    recordGroundTruth(
                        kind: .benchmarkTableAndCaption,
                        section: section.headingTitle,
                        col: activeColumn,
                        rect: totalRect,
                        text: tabSpec.plainLinearizedSummary
                    )
                    cursorY -= (totalTabH + 8.0)
                }
            }
        }

        // 5. References Section
        if !spec.formattedReferences.isEmpty {
            let refTitle = "References"
            let refHeadH = 16.0
            if cursorY - 42.0 < minBodyY {
                advanceToNextColumnOrPage()
            }
            let rHeadRect = CGRect(x: currentColumnX(), y: cursorY - refHeadH, width: colWidth, height: refHeadH)
            Self.drawStyledText(refTitle, in: rHeadRect, fontName: preset.boldFontName, fontSize: 10.5, grayLevel: 0.06, ctx: ctx)
            recordGroundTruth(kind: .sectionHeading, section: refTitle, col: activeColumn, rect: rHeadRect, text: refTitle)
            cursorY -= (refHeadH + 4.0)

            for (rIdx, refLine) in spec.formattedReferences.enumerated() {
                let numbered = "[\(rIdx + 1)] \(refLine)"
                let refH = Self.measureTextHeight(numbered, width: colWidth, fontName: preset.bodyFontName, fontSize: 8.1) + 3.0
                if cursorY - refH < minBodyY {
                    advanceToNextColumnOrPage()
                }
                let rRect = CGRect(x: currentColumnX(), y: cursorY - refH, width: colWidth, height: refH)
                Self.drawStyledText(numbered, in: rRect, fontName: preset.bodyFontName, fontSize: 8.1, grayLevel: 0.16, ctx: ctx)
                recordGroundTruth(kind: .bibliographyReference, section: refTitle, col: activeColumn, rect: rRect, text: numbered)
                cursorY -= (refH + 3.5)
            }
        }

        ctx.endPDFPage()
        ctx.closePDF()

        let finalData = outData as Data
        let verifiedPageCount = PDFDocument(data: finalData)?.pageCount ?? (currentPageIndex + 1)

        return RenderedAcademicPDFFixture(
            citeKey: spec.citeKey,
            pdfFileName: spec.pdfFileName,
            pdfData: finalData,
            pageCount: verifiedPageCount,
            groundTruthRegions: groundTruth,
            syncTeXAnchors: syncAnchors
        )
    }

    /// Renders `spec` directly to `destinationURL` on disk and returns the `RenderedAcademicPDFFixture`.
    public func writeAcademicPDF(spec: SyntheticPaperFixtureSpec, to destinationURL: URL) throws -> RenderedAcademicPDFFixture {
        let rendered = try renderAcademicPDF(spec: spec)
        try rendered.pdfData.write(to: destinationURL, options: .atomic)
        return rendered
    }

    // MARK: 2. Vector Provenance Bounding-Box Overlay Renderer (Pure CoreGraphics + PDFKit)

    /// Renders translucent color-coded provenance highlight boxes & verdict callout tags (`GROUNDED`, `PARTIAL`, `NUMERIC_MISMATCH`, `UNSUPPORTED`) onto an existing PDF `Data`.
    public func renderProvenanceAnnotatedPDF(
        sourcePDFData: Data,
        provenances: [ClaimEvidenceProvenance]
    ) throws -> Data {
        guard let srcDoc = PDFDocument(data: sourcePDFData), srcDoc.pageCount > 0 else {
            throw ScholarOSError.pdfExtractionFailure("Cannot annotate empty or invalid PDF document data.")
        }

        var provsByPage: [Int: [ClaimEvidenceProvenance]] = [:]
        for p in provenances where p.boundingBox.width > 1.0 && p.boundingBox.height > 1.0 {
            provsByPage[p.boundingBox.pageIndex, default: []].append(p)
        }

        let outData = NSMutableData()
        var firstBox = srcDoc.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: outData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else {
            throw ScholarOSError.pdfExtractionFailure("Failed to allocate CoreGraphics overlay PDF context.")
        }

        for pIdx in 0..<srcDoc.pageCount {
            guard let page = srcDoc.page(at: pIdx) else { continue }
            var pageBox = page.bounds(for: .mediaBox)
            let pageDict: [CFString: Any] = [
                kCGPDFContextMediaBox: Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)
            ]
            ctx.beginPDFPage(pageDict as CFDictionary)
            page.draw(with: .mediaBox, to: ctx)

            if let overlays = provsByPage[pIdx] {
                for ov in overlays {
                    let rect = CGRect(
                        x: ov.boundingBox.x - 2.0,
                        y: ov.boundingBox.y - 2.0,
                        width: ov.boundingBox.width + 4.0,
                        height: ov.boundingBox.height + 4.0
                    )
                    let (r, g, b): (CGFloat, CGFloat, CGFloat) = {
                        switch ov.verdict {
                        case .groundedEntailment: return (0.14, 0.56, 0.36)
                        case .partialEvidence: return (0.82, 0.56, 0.12)
                        case .numericDiscrepancy: return (0.78, 0.18, 0.18)
                        case .unsupportedClaim: return (0.58, 0.22, 0.52)
                        }
                    }()

                    ctx.saveGState()
                    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 0.14))
                    ctx.setStrokeColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 0.88))
                    ctx.setLineWidth(1.3)
                    ctx.addRect(rect)
                    ctx.drawPath(using: .fillStroke)

                    // Draw compact verdict tag at top-right of bounding box
                    let badgeText = "\(ov.verdict.rawValue) (L\(ov.manuscriptLine))"
                    let badgeW = min(130.0, Double(badgeText.count) * 4.8 + 8.0)
                    let badgeRect = CGRect(x: Double(rect.maxX) - badgeW, y: Double(rect.maxY) + 1.0, width: badgeW, height: 10.5)
                    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 0.92))
                    ctx.addRect(badgeRect)
                    ctx.fillPath()
                    ctx.restoreGState()

                    Self.drawStyledText(
                        badgeText,
                        in: badgeRect.insetBy(dx: 3.0, dy: 1.0),
                        fontName: "Helvetica-Bold",
                        fontSize: 6.8,
                        rgbWhite: true,
                        ctx: ctx
                    )
                }
            }

            ctx.endPDFPage()
        }

        ctx.closePDF()
        return outData as Data
    }

    // MARK: 3. Segmenter Geometric IoU & Kendall's Tau Reading-Order Evaluator

    /// Renders `spec`, runs `PDFMultiColumnSegmenter`, and computes exact bounding-box IoU, column-assignment accuracy, Kendall's $\tau$ reading-order correlation, and numeric token preservation.
    public func benchmarkMultiColumnSegmenter(
        spec: SyntheticPaperFixtureSpec,
        segmenter: PDFMultiColumnSegmenter = PDFMultiColumnSegmenter()
    ) throws -> SegmentationGeometricBenchmarkReport {
        let rendered = try renderAcademicPDF(spec: spec)
        let extracted = try segmenter.segmentPDF(
            data: rendered.pdfData,
            pdfFileName: rendered.pdfFileName,
            citeKey: rendered.citeKey
        )

        let gtNarrative = rendered.groundTruthRegions.filter {
            switch $0.kind {
            case .abstractBox, .bodyParagraph, .figureGraphicAndCaption, .benchmarkTableAndCaption:
                return true
            default:
                return false
            }
        }

        guard !gtNarrative.isEmpty, !extracted.isEmpty else {
            return SegmentationGeometricBenchmarkReport(
                citeKey: spec.citeKey,
                pageCount: rendered.pageCount,
                groundTruthBodyBlockCount: gtNarrative.count,
                extractedPassageChunkCount: extracted.count,
                meanBoundingBoxIoU: 0.0,
                columnClassificationAccuracy: 0.0,
                kendallTauReadingOrderCorrelation: 0.0,
                quantitativeTokenPreservationRate: 0.0
            )
        }

        var iouSum = 0.0
        var colExactHits = 0
        var matchedPairsOrder: [(gtSeq: Int, extSeq: Int)] = []

        for gt in gtNarrative {
            let samePage = extracted.filter { $0.boundingBox.pageIndex == gt.boundingBox.pageIndex }
            guard let best = samePage.max(by: {
                Self.boxOverlapScore(gt.boundingBox, $0.boundingBox) < Self.boxOverlapScore(gt.boundingBox, $1.boundingBox)
            }) else {
                continue
            }
            let iou = Self.intersectionOverUnion(gt.boundingBox, best.boundingBox)
            iouSum += iou
            if best.columnIndex == gt.columnIndex {
                colExactHits += 1
            }
            matchedPairsOrder.append((gt.readingSequenceOrder, best.readingSequence))
        }

        let denom = Double(gtNarrative.count)
        let meanIoU = iouSum / denom
        let colAcc = Double(colExactHits) / denom
        let kendallTau = Self.computeKendallTauRankCorrelation(pairs: matchedPairsOrder)

        // Check numeric token preservation across PDFKit extraction
        let auditor = NumericClaimAndCitationEntailmentAuditor()
        let gtAllText = gtNarrative.map(\.groundTruthText).joined(separator: "\n")
        let extAllText = extracted.map(\.passageText).joined(separator: "\n")
        let gtNums = auditor.extractQuantitativeTokens(from: gtAllText)
        let extNums = auditor.extractQuantitativeTokens(from: extAllText)

        let preservedCount = gtNums.filter { gTok in
            extNums.contains { eTok in
                eTok.kind == gTok.kind && abs(eTok.canonicalValue - gTok.canonicalValue) <= (gTok.halfLastDecimalPlaceTolerance + 1e-6)
            }
        }.count
        let quantRate = gtNums.isEmpty ? 1.0 : Double(preservedCount) / Double(gtNums.count)

        return SegmentationGeometricBenchmarkReport(
            citeKey: spec.citeKey,
            pageCount: rendered.pageCount,
            groundTruthBodyBlockCount: gtNarrative.count,
            extractedPassageChunkCount: extracted.count,
            meanBoundingBoxIoU: meanIoU,
            columnClassificationAccuracy: colAcc,
            kendallTauReadingOrderCorrelation: kendallTau,
            quantitativeTokenPreservationRate: quantRate
        )
    }

    // MARK: 4. Canonical Multi-Page Benchmark Fixture Catalog (Zero Copyright Dependencies)

    /// Returns deterministic multi-page two-column academic fixture specs rich in quantitative benchmarks (`%`, `x`, `ms`, `p-value`, `N`, `F1`, tables, figures) for live provenance inspection and automated tests.
    public static func canonicalFixtureSpecifications() -> [SyntheticPaperFixtureSpec] {
        let microVMPaper = SyntheticPaperFixtureSpec(
            citeKey: "chen2025aegisvm",
            pdfFileName: "chen2025aegisvm_sosp.pdf",
            sourceTeXFileName: "aegisvm.tex",
            typography: .acmSigplanTwoColumn,
            runningVenueBanner: "Proceedings of the ACM SIGOPS Symposium on Operating Systems Principles (SOSP '25)",
            doiIdentifier: "10.1145/3694715.3695812",
            paperTitle: "AegisVM: Sub-10ms Hardware-Isolated MicroVMs for Verifiable Autonomous Agent Tool Execution",
            authorsLine: "Linnea Chen, Marcus Vance, Haruki Sato, and Elena Rostova",
            affiliationsLine: "Systems & Verification Group, Cambridge Institute of Computing",
            abstractText: "Autonomous coding and research agents invoke untrusted toolchains thousands of times per session, exposing host kernels to container escape vulnerabilities. We present AegisVM, a snapshot-forked KVM microVM runtime with hardware-enforced Virtio-FS capability gates. Across N = 1,240 multi-step SWE-bench and OS-audit workloads, AegisVM achieves a 6.4 ms cold-restore boot latency, representing a 3.4x speedup over Firecracker baseline snapshots while maintaining a 94.2% task completion rate and p < 0.001 tail-latency stability.",
            keywords: ["MicroVM", "Agent Sandboxing", "Copy-on-Write Snapshot", "Capability Provenance"],
            sections: [
                SyntheticPaperSectionSpec(
                    headingTitle: "1 Introduction",
                    sourceTeXLine: 18,
                    elements: [
                        .bodyParagraph(
                            text: "Modern autonomous software agents routinely synthesize shell scripts, compile native binaries, and parse untrusted network payloads. Shared-kernel Linux containers leave over 340 system calls exposed on the host syscall boundary, whereas conventional virtual machines incur prohibitive startup delays above 120 ms per invocation.",
                            sourceTeXLine: 20
                        ),
                        .bodyParagraph(
                            text: "AegisVM bridges this isolation-performance gap by combining pre-warmed EPT page-table templates with lazy demand-paged memory overlays. In production evaluation across N = 1,240 agent trajectories, AegisVM reduces per-sandbox memory overhead to 18.5 MB and achieves 6.4 ms median restore latency without sacrificing hardware hypervisor containment.",
                            sourceTeXLine: 28
                        )
                    ]
                ),
                SyntheticPaperSectionSpec(
                    headingTitle: "2 Architecture",
                    sourceTeXLine: 38,
                    elements: [
                        .bodyParagraph(
                            text: "Each AegisVM worker inherits a read-only golden guest kernel image mapped via shared physical hugepages. Dirty guest pages are tracked through hardware PML buffers, bounding copy-on-write fault service time to 14.2 us at the 99th percentile.",
                            sourceTeXLine: 40
                        ),
                        .displayEquation(
                            equationNumber: "1",
                            formulaText: "T_restore = T_vcpu_reset (1.1 ms) + N_eager * T_ept_map (5.3 ms) = 6.4 ms",
                            sourceTeXLine: 46
                        ),
                        .vectorFigure(
                            SyntheticFigureSpec(
                                figureNumberTag: "Figure 1",
                                captionText: "Median sandbox startup latency (ms) across isolation runtimes on 64-core EPYC hosts.",
                                yAxisUnitLabel: "Latency (ms)",
                                bars: [
                                    SyntheticFigureBarDatum(seriesLabel: "QEMU-Lite", numericValue: 84.0, formattedValueTag: "84.0 ms"),
                                    SyntheticFigureBarDatum(seriesLabel: "Kata-VM", numericValue: 46.5, formattedValueTag: "46.5 ms"),
                                    SyntheticFigureBarDatum(seriesLabel: "Firecracker", numericValue: 21.8, formattedValueTag: "21.8 ms"),
                                    SyntheticFigureBarDatum(seriesLabel: "AegisVM", numericValue: 6.4, formattedValueTag: "6.4 ms", isHighlightedMethod: true)
                                ]
                            )
                        )
                    ]
                ),
                SyntheticPaperSectionSpec(
                    headingTitle: "3 Evaluation",
                    sourceTeXLine: 62,
                    elements: [
                        .bodyParagraph(
                            text: "We benchmarked AegisVM against Firecracker v1.7, gVisor, and unconfined Docker across N = 1,240 tool-intensive tasks. AegisVM sustains 1,480 req/s aggregate sandbox throughput on a single dual-socket node (3.4x higher than Firecracker) while blocking 100% of kernel CVE exploit probes.",
                            sourceTeXLine: 64
                        ),
                        .benchmarkTable(
                            SyntheticBooktabsTableSpec(
                                tableNumberTag: "Table 1",
                                captionText: "End-to-end isolation latency, memory footprint, and SWE-bench pass rate.",
                                columnHeaders: ["Runtime", "Boot", "Memory", "Pass Rate"],
                                rows: [
                                    ["Docker (Unconfined)", "2.9 ms", "11.2 MB", "94.5%"],
                                    ["gVisor (Systrap)", "14.6 ms", "29.4 MB", "91.8%"],
                                    ["Firecracker Snap", "21.8 ms", "34.0 MB", "93.9%"],
                                    ["AegisVM (Ours)", "6.4 ms", "18.5 MB", "94.2%"]
                                ]
                            )
                        ),
                        .bodyParagraph(
                            text: "On our provenance-verification F1 benchmark, AegisVM's deterministic syscall audit log achieves F1 = 88.7 (95% CI [87.4, 90.0], p < 0.001 via paired Wilcoxon signed-rank test against heuristic eBPF tracing).",
                            sourceTeXLine: 82
                        )
                    ]
                ),
                SyntheticPaperSectionSpec(
                    headingTitle: "4 Limitations & Conclusion",
                    sourceTeXLine: 92,
                    elements: [
                        .bodyParagraph(
                            text: "Nested GPU passthrough currently adds 9.1 ms of IOMMU context binding latency and does not improve raw tensor-core GEMM throughput compared to bare-metal execution. Nevertheless, AegisVM establishes that sub-10ms hardware isolation is practical for interactive AI research workstations.",
                            sourceTeXLine: 94
                        )
                    ]
                )
            ],
            formattedReferences: [
                "Agache, A., Brooker, M., Iordache, A., et al. (2020). Firecracker: Lightweight virtualization for serverless applications. NSDI '20, pp. 419-434.",
                "Manco, F., Lupu, C., Schmidt, F., et al. (2017). My VM is lighter (and safer) than your container. SOSP '17, pp. 218-233.",
                "Watson, R. N., Woodruff, J., Neumann, P. G., et al. (2015). CHERI: A hybrid capability-system architecture. IEEE S&P '15."
            ]
        )

        let retrievalPaper = SyntheticPaperFixtureSpec(
            citeKey: "patel2026vericite",
            pdfFileName: "patel2026vericite_acl.pdf",
            sourceTeXFileName: "vericite.tex",
            typography: .neuripsWorkshopTwoColumn,
            runningVenueBanner: "Proceedings of the Annual Meeting of the Association for Computational Linguistics (ACL '26)",
            doiIdentifier: "10.18653/v1/2026.acl-long.104",
            paperTitle: "VeriCite: Bounding-Box Grounded Entailment Auditing for Quantitative Scientific Claims",
            authorsLine: "Ananya Patel, Tobias Lindqvist, and Mei-Ling Zhou",
            affiliationsLine: "Computational Metascience Lab, ETH Zurich & Oxford",
            abstractText: "Large language models frequently fabricate or transpose numerical metrics when summarizing cited literature. We introduce VeriCite, a dual-stage BM25 and unit-canonicalized entailment auditor evaluated on N = 860 peer-reviewed manuscripts. VeriCite detects numeric citation distortions with F1 = 92.6 and AUC = 0.964, reducing unverified quantitative hallucinations by 78.4% (p < 0.001) at an interactive indexing latency of 4.8 ms per PDF page.",
            keywords: ["Citation Verification", "Bounding-Box Provenance", "Quantitative Entailment", "Academic Integrity"],
            sections: [
                SyntheticPaperSectionSpec(
                    headingTitle: "1 Introduction",
                    sourceTeXLine: 14,
                    elements: [
                        .bodyParagraph(
                            text: "Empirical audits of AI-assisted drafts reveal that 19.3% of cited quantitative comparisons suffer from rounding inflation, unit confusion, or cross-paper attribution swaps. Standard DOI-existence checks confirm that a paper exists while overlooking whether page-level prose actually entails the cited figure.",
                            sourceTeXLine: 16
                        )
                    ]
                ),
                SyntheticPaperSectionSpec(
                    headingTitle: "2 Methodology",
                    sourceTeXLine: 26,
                    elements: [
                        .bodyParagraph(
                            text: "VeriCite segments two-column PDF pages into reading-order passage chunks and normalizes extracted SI durations, byte footprints, and statistical p-value inequalities prior to entailment scoring.",
                            sourceTeXLine: 28
                        ),
                        .benchmarkTable(
                            SyntheticBooktabsTableSpec(
                                tableNumberTag: "Table 1",
                                captionText: "Claim-entailment precision, recall, and F1 on SciNumVerify (N = 860).",
                                columnHeaders: ["Auditor", "Precision", "Recall", "F1"],
                                rows: [
                                    ["Dense-RAG Cosine", "74.1%", "68.9%", "71.4"],
                                    ["Cross-Encoder NLI", "83.5%", "79.2%", "81.3"],
                                    ["VeriCite (Ours)", "94.1%", "91.2%", "92.6"]
                                ]
                            )
                        )
                    ]
                ),
                SyntheticPaperSectionSpec(
                    headingTitle: "3 Results",
                    sourceTeXLine: 44,
                    elements: [
                        .bodyParagraph(
                            text: "Across N = 860 manuscripts, VeriCite achieves F1 = 92.6 and AUC = 0.964 while processing multi-column PDFs in 4.8 ms per page (2.9x faster than neural OCR pipelines). Inter-annotator agreement with human domain reviewers reached kappa = 0.84.",
                            sourceTeXLine: 46
                        )
                    ]
                )
            ],
            formattedReferences: [
                "Robertson, S., & Zaragoza, H. (2009). The probabilistic relevance framework: BM25 and beyond. FnTIR, 3(4), 333-389.",
                "Wadden, D., Lin, S., Lo, K., et al. (2020). Fact or fiction: Verifying scientific claims. EMNLP '20."
            ]
        )

        return [microVMPaper, retrievalPaper]
    }

    /// Builds a ready-to-run `SyntheticProvenanceBenchmarkBundle` containing rendered multi-page PDFs, `BibliographyEntry` metadata, and a sample LaTeX manuscript with both grounded and intentionally mismatched numbers.
    public func buildCanonicalBenchmarkBundle() throws -> SyntheticProvenanceBenchmarkBundle {
        let specs = Self.canonicalFixtureSpecifications()
        let rendered = try specs.map { try renderAcademicPDF(spec: $0) }

        let bibEntries: [BibliographyEntry] = [
            BibliographyEntry(
                citeKey: "chen2025aegisvm",
                kind: .inproceedings,
                title: specs[0].paperTitle,
                authors: [
                    BibAuthor(givenName: "Linnea", familyName: "Chen"),
                    BibAuthor(givenName: "Marcus", familyName: "Vance")
                ],
                year: 2025,
                venue: "SOSP '25",
                doi: specs[0].doiIdentifier,
                abstractText: specs[0].abstractText,
                firewallClass: .unverified,
                firewallAuditNote: "Synthetic test fixture - unverified",
                attachedPDFPath: specs[0].pdfFileName
            ),
            BibliographyEntry(
                citeKey: "patel2026vericite",
                kind: .inproceedings,
                title: specs[1].paperTitle,
                authors: [
                    BibAuthor(givenName: "Ananya", familyName: "Patel"),
                    BibAuthor(givenName: "Tobias", familyName: "Lindqvist")
                ],
                year: 2026,
                venue: "ACL '26",
                doi: specs[1].doiIdentifier,
                abstractText: specs[1].abstractText,
                firewallClass: .unverified,
                firewallAuditNote: "Synthetic test fixture - unverified",
                attachedPDFPath: specs[1].pdfFileName,
                referencesKeys: ["chen2025aegisvm"]
            )
        ]

        let sampleManuscript = """
        \\section{Related Work}
        Snapshot-forked microVMs achieve 6.4 ms cold-restore boot latency and a 3.4x speedup across N = 1,240 agent workloads while maintaining a 94.2\\% task completion rate ($p < 0.001$) \\cite{chen2025aegisvm}.
        Bounding-box entailment auditing detects numeric distortions with F1 = 92.6 and reduces quantitative hallucinations by 78.4\\% at 4.8 ms per page \\cite{patel2026vericite}.
        However, an unverified draft erroneously claimed a 99.1\\% task completion rate and 1.2 ms startup latency \\cite{chen2025aegisvm}.
        """

        return SyntheticProvenanceBenchmarkBundle(
            fixtures: rendered,
            bibliographyEntries: bibEntries,
            sampleManuscriptWithGroundedAndMismatchedClaims: sampleManuscript
        )
    }

    // MARK: - Internal CoreText & CoreGraphics Rendering Primitives

    private static func measureTextHeight(
        _ text: String,
        width: Double,
        fontName: String,
        fontSize: Double
    ) -> Double {
        guard !text.isEmpty else { return 0.0 }
        let font = CTFontCreateWithName(fontName as CFString, CGFloat(fontSize), nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, attrStr.length),
            nil,
            CGSize(width: max(20.0, width), height: CGFloat.greatestFiniteMagnitude),
            nil
        )
        return Double(ceil(suggested.height))
    }

    private static func drawStyledText(
        _ text: String,
        in rect: CGRect,
        fontName: String,
        fontSize: Double,
        grayLevel: CGFloat = 0.08,
        rgbWhite: Bool = false,
        ctx: CGContext
    ) {
        guard !text.isEmpty, rect.width > 1.0, rect.height > 1.0 else { return }
        let font = CTFontCreateWithName(fontName as CFString, CGFloat(fontSize), nil)
        let color = rgbWhite ? CGColor(gray: 1.0, alpha: 1.0) : CGColor(gray: grayLevel, alpha: 1.0)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attrStr.length), path, nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    private static func drawFlowingParagraphSlice(
        _ fullText: String,
        x: Double,
        topY: Double,
        width: Double,
        maxHeight: Double,
        fontName: String,
        fontSize: Double,
        ctx: CGContext
    ) -> (drawnText: String, heightUsed: Double) {
        let font = CTFontCreateWithName(fontName as CFString, CGFloat(fontSize), nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 0.08, alpha: 1.0)
        ]
        let attrStr = NSAttributedString(string: fullText, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)

        var fitRange = CFRangeMake(0, 0)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, attrStr.length),
            nil,
            CGSize(width: width, height: maxHeight),
            &fitRange
        )

        guard fitRange.length > 0 else { return ("", 0.0) }
        let usedH = min(maxHeight, Double(ceil(suggested.height)) + 2.0)
        let rect = CGRect(x: x, y: topY - usedH, width: width, height: usedH)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, fitRange, path, nil)

        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()

        let ns = fullText as NSString
        let safeLen = min(ns.length, fitRange.length)
        let drawn = ns.substring(with: NSRange(location: 0, length: safeLen))
        return (drawn, usedH)
    }

    private static func drawVectorBarChart(
        _ fig: SyntheticFigureSpec,
        in rect: CGRect,
        preset: SyntheticPaperTypographyPreset,
        ctx: CGContext
    ) {
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 0.985, green: 0.985, blue: 0.98, alpha: 1.0))
        ctx.setStrokeColor(CGColor(gray: 0.65, alpha: 1.0))
        ctx.setLineWidth(0.6)
        ctx.addRect(rect)
        ctx.drawPath(using: .fillStroke)

        let plotLeft = Double(rect.minX) + 28.0
        let plotRight = Double(rect.maxX) - 10.0
        let plotBottom = Double(rect.minY) + 20.0
        let plotTop = Double(rect.maxY) - 16.0
        let plotW = max(20.0, plotRight - plotLeft)
        let plotH = max(20.0, plotTop - plotBottom)

        // Axes
        ctx.setStrokeColor(CGColor(gray: 0.25, alpha: 1.0))
        ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: plotLeft, y: plotTop))
        ctx.addLine(to: CGPoint(x: plotLeft, y: plotBottom))
        ctx.addLine(to: CGPoint(x: plotRight, y: plotBottom))
        ctx.strokePath()

        let maxVal = max(1e-6, fig.bars.map(\.numericValue).max() ?? 1.0)
        let count = max(1, fig.bars.count)
        let slotW = plotW / Double(count)
        let barW = min(32.0, slotW * 0.58)

        for (idx, bar) in fig.bars.enumerated() {
            let normH = max(2.0, (bar.numericValue / maxVal) * (plotH - 12.0))
            let bx = plotLeft + Double(idx) * slotW + (slotW - barW) * 0.5
            let barRect = CGRect(x: bx, y: plotBottom, width: barW, height: normH)

            if bar.isHighlightedMethod {
                ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.42, blue: 0.34, alpha: 1.0))
            } else {
                ctx.setFillColor(CGColor(srgbRed: 0.52, green: 0.56, blue: 0.60, alpha: 1.0))
            }
            ctx.addRect(barRect)
            ctx.fillPath()

            // Value label above bar (renderable text so PDFKit extracts exact figure numbers too!)
            let valRect = CGRect(x: bx - 8.0, y: plotBottom + normH + 1.0, width: barW + 16.0, height: 10.0)
            drawStyledText(bar.formattedValueTag, in: valRect, fontName: preset.boldFontName, fontSize: 6.8, grayLevel: 0.10, ctx: ctx)

            // Series label below axis
            let lblRect = CGRect(x: bx - 8.0, y: Double(rect.minY) + 3.0, width: barW + 16.0, height: 12.0)
            drawStyledText(bar.seriesLabel, in: lblRect, fontName: preset.bodyFontName, fontSize: 6.6, grayLevel: 0.18, ctx: ctx)
        }

        ctx.restoreGState()
    }

    private static func drawBooktabsTable(
        _ table: SyntheticBooktabsTableSpec,
        in rect: CGRect,
        rowHeight: Double,
        preset: SyntheticPaperTypographyPreset,
        ctx: CGContext
    ) {
        let colCount = max(1, table.columnHeaders.count)
        let colW = Double(rect.width) / Double(colCount)
        let leftX = Double(rect.minX)
        let rightX = Double(rect.maxX)
        var yTop = Double(rect.maxY) - 2.0

        ctx.saveGState()
        // Toprule (thick)
        ctx.setStrokeColor(CGColor(gray: 0.10, alpha: 1.0))
        ctx.setLineWidth(1.1)
        ctx.move(to: CGPoint(x: leftX, y: yTop))
        ctx.addLine(to: CGPoint(x: rightX, y: yTop))
        ctx.strokePath()

        // Header cells
        for (cIdx, hdr) in table.columnHeaders.enumerated() {
            let cellRect = CGRect(x: leftX + Double(cIdx) * colW + 2.0, y: yTop - rowHeight + 1.0, width: colW - 4.0, height: rowHeight - 2.0)
            drawStyledText(hdr, in: cellRect, fontName: preset.boldFontName, fontSize: 7.6, grayLevel: 0.06, ctx: ctx)
        }
        yTop -= rowHeight

        // Midrule (thin)
        ctx.setLineWidth(0.55)
        ctx.move(to: CGPoint(x: leftX, y: yTop))
        ctx.addLine(to: CGPoint(x: rightX, y: yTop))
        ctx.strokePath()

        // Body rows
        for row in table.rows {
            for cIdx in 0..<colCount {
                let cellVal = cIdx < row.count ? row[cIdx] : ""
                let cellRect = CGRect(x: leftX + Double(cIdx) * colW + 2.0, y: yTop - rowHeight + 1.0, width: colW - 4.0, height: rowHeight - 2.0)
                drawStyledText(cellVal, in: cellRect, fontName: preset.bodyFontName, fontSize: 7.5, grayLevel: 0.10, ctx: ctx)
            }
            yTop -= rowHeight
        }

        // Bottomrule (thick)
        ctx.setLineWidth(1.1)
        ctx.move(to: CGPoint(x: leftX, y: max(Double(rect.minY), yTop)))
        ctx.addLine(to: CGPoint(x: rightX, y: max(Double(rect.minY), yTop)))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Geometric IoU & Kendall's Tau Helpers

    private static func boxOverlapScore(_ a: PDFPageRegionBox, _ b: PDFPageRegionBox) -> Double {
        guard a.pageIndex == b.pageIndex else { return 0.0 }
        let ix1 = max(a.x, b.x)
        let iy1 = max(a.y, b.y)
        let ix2 = min(a.x + a.width, b.x + b.width)
        let iy2 = min(a.y + a.height, b.y + b.height)
        guard ix2 > ix1, iy2 > iy1 else { return 0.0 }
        return (ix2 - ix1) * (iy2 - iy1)
    }

    private static func intersectionOverUnion(_ a: PDFPageRegionBox, _ b: PDFPageRegionBox) -> Double {
        let inter = boxOverlapScore(a, b)
        guard inter > 0.0 else { return 0.0 }
        let areaA = max(1e-6, a.width * a.height)
        let areaB = max(1e-6, b.width * b.height)
        let union = areaA + areaB - inter
        return union > 0.0 ? min(1.0, inter / union) : 0.0
    }

    private static func computeKendallTauRankCorrelation(pairs: [(gtSeq: Int, extSeq: Int)]) -> Double {
        let n = pairs.count
        guard n >= 2 else { return 1.0 }
        var concordant = 0
        var discordant = 0
        for i in 0..<n {
            for j in (i + 1)..<n {
                let dg = pairs[j].gtSeq - pairs[i].gtSeq
                let de = pairs[j].extSeq - pairs[i].extSeq
                let prod = dg * de
                if prod > 0 {
                    concordant += 1
                } else if prod < 0 {
                    discordant += 1
                }
            }
        }
        let totalPairs = concordant + discordant
        guard totalPairs > 0 else { return 1.0 }
        return Double(concordant - discordant) / Double(totalPairs)
    }
}
