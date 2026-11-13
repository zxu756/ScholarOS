import CoreGraphics
import CoreText
import Foundation
import PDFKit
import ScholarModels

// MARK: - PDFKit Geometric Multi-Column Reading-Order Segmenter

public struct PDFMultiColumnSegmenter: Sendable {
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
        var chunks: [PDFPassageChunk] = []
        var globalSeq = 0
        var activeSection = "Front Matter & Abstract"

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let mediaBox = page.bounds(for: .mediaBox)
            let midX = Double(mediaBox.midX)
            let pageWidth = Double(max(1.0, mediaBox.width))

            let rawLines = extractPositionedLines(from: page, pageIndex: pageIndex)
            guard !rawLines.isEmpty else { continue }

            // Partition into spanning blocks (full-width headers/abstract), left column, and right column
            var spanningLines: [PositionedTextLine] = []
            var leftLines: [PositionedTextLine] = []
            var rightLines: [PositionedTextLine] = []

            for line in rawLines {
                let widthRatio = line.width / pageWidth
                let crossesCenter = line.minX < (midX - 24.0) && line.maxX > (midX + 24.0)
                if widthRatio > 0.56 || crossesCenter {
                    spanningLines.append(line)
                } else if line.midX <= midX {
                    leftLines.append(line)
                } else {
                    rightLines.append(line)
                }
            }

            // Sort each stream top-to-bottom (in PDF coordinates, larger Y is higher on page)
            let sortTopDown: (PositionedTextLine, PositionedTextLine) -> Bool = { a, b in
                if abs(a.maxY - b.maxY) > 3.0 { return a.maxY > b.maxY }
                return a.minX < b.minX
            }
            spanningLines.sort(by: sortTopDown)
            leftLines.sort(by: sortTopDown)
            rightLines.sort(by: sortTopDown)

            let streams: [(Int, [PositionedTextLine])]
            if leftLines.count >= 3 && rightLines.count >= 3 {
                streams = [(0, spanningLines), (1, leftLines), (2, rightLines)]
            } else {
                var mergedSingle = rawLines
                mergedSingle.sort(by: sortTopDown)
                streams = [(0, mergedSingle)]
            }

            for (colIdx, streamLines) in streams where !streamLines.isEmpty {
                let groupedParagraphs = groupLinesIntoParagraphs(streamLines)
                for para in groupedParagraphs {
                    if let heading = detectSectionHeading(para.text) {
                        activeSection = heading
                    }
                    guard para.text.count >= 18 else { continue }
                    globalSeq += 1
                    let bbox = PDFPageRegionBox(
                        pageIndex: pageIndex,
                        x: para.minX,
                        y: para.minY,
                        width: max(8.0, para.maxX - para.minX),
                        height: max(8.0, para.maxY - para.minY)
                    )
                    chunks.append(
                        PDFPassageChunk(
                            id: "\(citeKey)#p\(pageIndex + 1)-c\(colIdx)-\(globalSeq)",
                            citeKey: citeKey,
                            pdfFileName: pdfFileName,
                            sectionTitle: activeSection,
                            columnIndex: colIdx,
                            readingSequence: globalSeq,
                            boundingBox: bbox,
                            passageText: para.text
                        )
                    )
                }
            }
        }

        return chunks
    }

    private struct PositionedTextLine {
        let text: String
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double
        var width: Double { maxX - minX }
        var midX: Double { (minX + maxX) * 0.5 }
    }

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

    private func groupLinesIntoParagraphs(_ lines: [PositionedTextLine]) -> [PositionedTextLine] {
        guard var current = lines.first else { return [] }
        var paragraphs: [PositionedTextLine] = []

        for next in lines.dropFirst() {
            let verticalGap = current.minY - next.maxY
            let nextLooksLikeHeading = detectSectionHeading(next.text) != nil
            if verticalGap > 11.5 || nextLooksLikeHeading || current.text.count > 520 {
                paragraphs.append(current)
                current = next
            } else {
                let joinedText: String
                if current.text.hasSuffix("-") {
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
            }
        }
        paragraphs.append(current)
        return paragraphs
    }

    private func detectSectionHeading(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 && trimmed.count <= 72 else { return nil }
        let known = [
            "abstract", "introduction", "background", "related work",
            "methodology", "methods", "architecture", "evaluation",
            "experiments", "results", "discussion", "limitations", "conclusion"
        ]
        let lower = trimmed.lowercased()
        for kw in known {
            if lower == kw || lower.hasPrefix("1 \(kw)") || lower.hasPrefix("2 \(kw)")
                || lower.hasPrefix("3 \(kw)") || lower.hasPrefix("4 \(kw)")
                || lower.hasPrefix("5 \(kw)") || lower.hasPrefix("6 \(kw)")
                || lower.hasPrefix("i. \(kw)") || lower.hasPrefix("ii. \(kw)") {
                return trimmed
            }
        }
        return nil
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
