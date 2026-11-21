import Darwin
import Foundation
import ScholarModels
import ScholarPDFProvenance

// MARK: - Shared Local PDF Segmentation & Evidence Localization Service (CLI + MCP, M4 Stage 03)

public enum PDFEvidenceCLIAndMCPService {
    public static let defaultTopK: Int = 3

    public struct PDFSegmentChunkJSONRecord: Sendable, Codable, Hashable {
        public let id: String
        public let readingSequence: Int
        public let kind: PDFPassageChunkKind
        public let page: Int
        public let pageIndex: Int
        public let boundingBox: EvidenceBoundingBox
        public let columnIndex: Int
        public let sectionTitle: String
        public let text: String

        public init(chunk: PDFPassageChunk) {
            self.id = chunk.id
            self.readingSequence = chunk.readingSequence
            self.kind = chunk.kind
            self.page = chunk.pageNumber
            self.pageIndex = chunk.boundingBox.pageIndex
            self.boundingBox = EvidenceBoundingBox(regionBox: chunk.boundingBox)
            self.columnIndex = chunk.columnIndex
            self.sectionTitle = chunk.sectionTitle
            self.text = chunk.passageText
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case readingSequence = "reading_sequence"
            case kind
            case page
            case pageIndex = "page_index"
            case boundingBox = "bounding_box"
            case columnIndex = "column_index"
            case sectionTitle = "section_title"
            case text
        }
    }

    public struct PDFSegmentationJSONReport: Sendable, Codable, Hashable {
        public static let currentSchema = "scholaros.pdf_segments/1"

        public let schema: String
        public let pdfFile: String
        public let pageCount: Int
        public let chunkCount: Int
        public let chunks: [PDFSegmentChunkJSONRecord]

        public init(
            schema: String = PDFSegmentationJSONReport.currentSchema,
            pdfFile: String,
            pageCount: Int,
            chunks: [PDFSegmentChunkJSONRecord]
        ) {
            self.schema = schema
            self.pdfFile = pdfFile
            self.pageCount = pageCount
            self.chunkCount = chunks.count
            self.chunks = chunks
        }

        private enum CodingKeys: String, CodingKey {
            case schema
            case pdfFile = "pdf_file"
            case pageCount = "page_count"
            case chunkCount = "chunk_count"
            case chunks
        }
    }

    /// Validates that `rawPath` is an existing readable regular PDF file with extractable non-margin text,
    /// and segments it via `PDFMultiColumnSegmenter`.
    public static func loadAndSegmentLocalPDF(
        atPath rawPath: String,
        language: ScholarLanguage = .en
    ) throws -> (pdfFileName: String, chunks: [PDFPassageChunk]) {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw ScholarOSError.invalidCLIArguments(
                language.L(
                    "PDF file path must not be empty.",
                    "PDF 文件路径不能为空。"
                )
            )
        }

        var st = Darwin.stat()
        if stat(trimmedPath, &st) != 0 {
            let err = errno
            if err == ENOENT || err == ENOTDIR {
                throw ScholarOSError.fileNotFound(trimmedPath)
            }
            let detail = String(cString: Darwin.strerror(err))
            throw ScholarOSError.pdfExtractionFailure(
                language.L(
                    "Cannot access PDF file '\(trimmedPath)': \(detail)",
                    "无法访问 PDF 文件 '\(trimmedPath)'：\(detail)"
                )
            )
        }

        let modeBits = st.st_mode & S_IFMT
        if modeBits == S_IFDIR {
            throw ScholarOSError.pdfExtractionFailure(
                language.L(
                    "Path '\(trimmedPath)' is a directory, not a PDF file.",
                    "路径 '\(trimmedPath)' 是目录而非 PDF 文件。"
                )
            )
        }
        if modeBits != S_IFREG {
            throw ScholarOSError.pdfExtractionFailure(
                language.L(
                    "Path '\(trimmedPath)' is not a regular PDF file.",
                    "路径 '\(trimmedPath)' 不是普通 PDF 文件。"
                )
            )
        }

        let pdfURL = URL(fileURLWithPath: trimmedPath)
        let data: Data
        do {
            data = try Data(contentsOf: pdfURL)
        } catch {
            throw ScholarOSError.pdfExtractionFailure(
                language.L(
                    "Cannot read PDF file '\(trimmedPath)': \(error.localizedDescription)",
                    "无法读取 PDF 文件 '\(trimmedPath)'：\(error.localizedDescription)"
                )
            )
        }

        // Verify PDF magic header (`%PDF-`) within the first 1024 bytes per ISO 32000-1
        let headerWindow = data.prefix(1024)
        guard headerWindow.range(of: Data("%PDF-".utf8)) != nil else {
            throw ScholarOSError.pdfExtractionFailure(
                language.L(
                    "File '\(trimmedPath)' is not a valid PDF document (missing %PDF- header).",
                    "文件 '\(trimmedPath)' 不是有效的 PDF 文档（缺少 %PDF- 文件头）。"
                )
            )
        }

        let pdfFileName = pdfURL.lastPathComponent
        let effectiveCiteKey = pdfURL.deletingPathExtension().lastPathComponent
        let chunks = try PDFMultiColumnSegmenter().segmentPDF(
            data: data,
            pdfFileName: pdfFileName,
            citeKey: effectiveCiteKey
        )

        let hasExtractableText = chunks.contains { chunk in
            !chunk.kind.isHeaderOrFooter
                && !chunk.passageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasExtractableText else {
            throw ScholarOSError.pdfExtractionFailure(
                language.L(
                    "No extractable text found in PDF '\(trimmedPath)' (blank document or scanned image pages without a text layer).",
                    "无法从 PDF '\(trimmedPath)' 中提取到可检索文字（可能是空白文档或无文字层的扫描件）。"
                )
            )
        }

        return (pdfFileName, chunks)
    }

    /// Unified local PDF evidence localization and explicit numeric checking entry point shared by CLI and MCP.
    public static func locateEvidenceInLocalPDF(
        atPath pdfPath: String,
        claim: String,
        topK: Int = defaultTopK,
        language: ScholarLanguage = .en
    ) throws -> EvidenceLocalizationResult {
        guard !claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScholarOSError.invalidCLIArguments(
                language.L(
                    "Claim text must not be empty or whitespace-only.",
                    "论断文字（claim）不能为空或仅包含空白字符。"
                )
            )
        }
        guard topK >= 1 else {
            throw ScholarOSError.invalidCLIArguments(
                language.L(
                    "top-k must be a positive integer (>= 1), got \(topK).",
                    "top-k 必须是大于等于 1 的正整数，当前收到 \(topK)。"
                )
            )
        }

        let loaded = try loadAndSegmentLocalPDF(atPath: pdfPath, language: language)
        return EvidenceLocatorAndNumericChecker().locateEvidence(
            claim: claim,
            passages: loaded.chunks,
            pdfFileName: loaded.pdfFileName,
            citeKeyFilter: nil,
            topK: topK
        )
    }

    public static func encodeEvidenceLocalizationJSON(_ result: EvidenceLocalizationResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(result)
        return String(decoding: data, as: UTF8.self)
    }

    public static func buildSegmentationReport(
        pdfFileName: String,
        chunks: [PDFPassageChunk]
    ) -> PDFSegmentationJSONReport {
        let records = chunks.map(PDFSegmentChunkJSONRecord.init(chunk:))
        let maxPage = records.map(\.page).max() ?? 0
        return PDFSegmentationJSONReport(
            pdfFile: pdfFileName,
            pageCount: maxPage,
            chunks: records
        )
    }

    public static func encodeSegmentationJSON(_ report: PDFSegmentationJSONReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }

    public static func formatHumanLocateEvidenceSummary(
        _ result: EvidenceLocalizationResult,
        language: ScholarLanguage
    ) -> String {
        let pdfLabel = result.pdfFile ?? "document.pdf"
        switch result.verdict {
        case .found:
            let page = result.page ?? 1
            let col = result.columnIndex ?? 0
            let section = result.sectionTitle ?? ""
            let covPct = String(format: "%.1f%%", (result.coverage ?? 0.0) * 100.0)
            let boxText: String
            if let b = result.boundingBox {
                boxText = String(format: "[x=%.1f, y=%.1f, w=%.1f, h=%.1f]", b.x, b.y, b.width, b.height)
            } else {
                boxText = "[]"
            }
            let excerpt = result.excerpt ?? ""
            var lines: [String] = []
            if language == .zhHans {
                lines.append("[FOUND] 已在 \(pdfLabel) 定位到相近段落（第 \(page) 页，栏=\(col)，章节=\"\(section)\"，位置框=\(boxText)，关键词覆盖率=\(covPct)）。")
                lines.append("说明：仅定位词汇相近段落并核对显式数字与单位。")
                lines.append("原文摘录：\(excerpt)")
                if result.matches.count > 1 {
                    for (idx, m) in result.matches.dropFirst().enumerated() {
                        lines.append("候选[\(idx + 2)] 第 \(m.page) 页 栏=\(m.columnIndex) 章节=\"\(m.sectionTitle)\"：\(m.excerpt)")
                    }
                }
            } else {
                lines.append("[FOUND] Located matching passage in \(pdfLabel) (page \(page), col=\(col), section=\"\(section)\", box=\(boxText), keyword_coverage=\(covPct)).")
                lines.append("Note: Locates lexically matching passages and checks explicit numbers/units only.")
                lines.append("Excerpt: \(excerpt)")
                if result.matches.count > 1 {
                    for (idx, m) in result.matches.dropFirst().enumerated() {
                        lines.append("Candidate[\(idx + 2)] p.\(m.page) col=\(m.columnIndex) section=\"\(m.sectionTitle)\": \(m.excerpt)")
                    }
                }
            }
            return lines.joined(separator: "\n")

        case .numericMismatch:
            let page = result.page ?? 1
            let col = result.columnIndex ?? 0
            let section = result.sectionTitle ?? ""
            let boxText: String
            if let b = result.boundingBox {
                boxText = String(format: "[x=%.1f, y=%.1f, w=%.1f, h=%.1f]", b.x, b.y, b.width, b.height)
            } else {
                boxText = "[]"
            }
            let excerpt = result.excerpt ?? ""
            var lines: [String] = []
            if language == .zhHans {
                lines.append("[NUMERIC_MISMATCH] 已在 \(pdfLabel) 定位到相近段落（第 \(page) 页，栏=\(col)，章节=\"\(section)\"，位置框=\(boxText)），但显式数字或单位不一致：")
                for d in result.discrepancies {
                    let pdfSide = d.pdfText ?? "（原文无对应数字）"
                    lines.append("  - 论断 \"\(d.claimText)\" 对比原文 \"\(pdfSide)\"：\(d.reason)")
                }
                lines.append("原文摘录：\(excerpt)")
            } else {
                lines.append("[NUMERIC_MISMATCH] Located matching passage in \(pdfLabel) (page \(page), col=\(col), section=\"\(section)\", box=\(boxText)), but explicit numbers/units differ:")
                for d in result.discrepancies {
                    let pdfSide = d.pdfText ?? "(none in passage)"
                    lines.append("  - claim \"\(d.claimText)\" vs PDF \"\(pdfSide)\": \(d.reason)")
                }
                lines.append("Excerpt: \(excerpt)")
            }
            return lines.joined(separator: "\n")

        case .notFound:
            if language == .zhHans {
                return "[NOT_FOUND] 在 \(pdfLabel) 中未找到满足关键词覆盖率门槛的相近段落：\"\(result.claim)\""
            } else {
                return "[NOT_FOUND] No passage in \(pdfLabel) met the keyword coverage threshold for claim: \"\(result.claim)\""
            }
        }
    }

    public static func formatHumanSegmentationSummary(
        _ report: PDFSegmentationJSONReport,
        language: ScholarLanguage
    ) -> String {
        var countsByKind: [PDFPassageChunkKind: Int] = [:]
        for c in report.chunks {
            countsByKind[c.kind, default: 0] += 1
        }
        let bodyCount = countsByKind[.body, default: 0]
        let headingCount = countsByKind[.sectionHeading, default: 0]
        let tableCount = countsByKind[.tableOrFigure, default: 0]
        let headerCount = countsByKind[.header, default: 0]
        let footerCount = countsByKind[.footer, default: 0]

        var lines: [String] = []
        if language == .zhHans {
            lines.append("已分段 \(report.pdfFile)：共 \(report.pageCount) 页，\(report.chunkCount) 个分段块（正文=\(bodyCount)，章节标题=\(headingCount)，图表=\(tableCount)，页眉=\(headerCount)，页脚=\(footerCount)）")
            for c in report.chunks {
                let boxStr = String(format: "%.1f,%.1f,%.1fx%.1f", c.boundingBox.x, c.boundingBox.y, c.boundingBox.width, c.boundingBox.height)
                lines.append("[\(c.readingSequence)] [\(c.kind.rawValue)] 第\(c.page)页 栏=\(c.columnIndex) 章节=\"\(c.sectionTitle)\" 位置框=[\(boxStr)]：\(c.text)")
            }
        } else {
            lines.append("Segmented \(report.pdfFile): \(report.pageCount) page(s), \(report.chunkCount) chunk(s) (body=\(bodyCount), section_heading=\(headingCount), table_or_figure=\(tableCount), header=\(headerCount), footer=\(footerCount))")
            for c in report.chunks {
                let boxStr = String(format: "%.1f,%.1f,%.1fx%.1f", c.boundingBox.x, c.boundingBox.y, c.boundingBox.width, c.boundingBox.height)
                lines.append("[\(c.readingSequence)] [\(c.kind.rawValue)] p.\(c.page) col=\(c.columnIndex) section=\"\(c.sectionTitle)\" box=[\(boxStr)]: \(c.text)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
