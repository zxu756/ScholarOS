import Foundation

// MARK: - Manuscript Languages, Text Spans & Hardware-Gated Errors

public enum ManuscriptFormat: String, Sendable, Codable, Hashable, CaseIterable {
    case latex = "LaTeX"
    case typst = "Typst"
    case markdown = "Markdown"

    public static func detect(fromPath path: String) -> ManuscriptFormat {
        switch (path as NSString).pathExtension.lowercased() {
        case "typ": return .typst
        case "md", "markdown": return .markdown
        default: return .latex
        }
    }
}

public struct TextPosition: Sendable, Codable, Hashable, Comparable {
    public let line: Int       // 1-based
    public let column: Int     // 1-based
    public let utf8Offset: Int // 0-based

    public init(line: Int, column: Int, utf8Offset: Int = 0) {
        self.line = line
        self.column = column
        self.utf8Offset = utf8Offset
    }

    public static let startOfFile = TextPosition(line: 1, column: 1, utf8Offset: 0)

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        return lhs.column < rhs.column
    }
}

public struct TextSpan: Sendable, Codable, Hashable {
    public let filePath: String
    public let start: TextPosition
    public let end: TextPosition

    public init(filePath: String = "main.tex", start: TextPosition, end: TextPosition) {
        self.filePath = filePath
        self.start = start
        self.end = end
    }
}

public enum ScholarOSError: Error, LocalizedError, Sendable, Equatable {
    case fileNotFound(String)
    case markupParseFailure(file: String, line: Int, detail: String)
    case bibliographyParseFailure(format: String, line: Int, detail: String)
    /// Hardware-gated citation firewall error — blocks unverified/hallucinated citations in CLI & MCP!
    case unverifiedCitationBlocked(citeKey: String, statusCode: String, reason: String)
    case syncTeXMappingNotFound(String)
    case pdfExtractionFailure(String)
    case prismaProtocolViolation(String)
    case sqliteError(code: Int32, message: String)
    case pluginError(pluginID: String, message: String)
    case invalidCLIArguments(String)

    public var errorCodeIdentifier: String {
        switch self {
        case .unverifiedCitationBlocked:
            return "ERR_UNVERIFIED_CITATION"
        case .prismaProtocolViolation:
            return "ERR_PRISMA_PROTOCOL"
        case .bibliographyParseFailure:
            return "ERR_BIB_SYNTAX"
        default:
            return "ERR_SCHOLAROS"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p):
            return "File not found: \(p)"
        case .markupParseFailure(let f, let l, let d):
            return "Markup parse error in \(f):\(l): \(d)"
        case .bibliographyParseFailure(let fmt, let l, let d):
            return "\(fmt) parse error at line \(l): \(d)"
        case .unverifiedCitationBlocked(let key, let status, let reason):
            return "[ERR_UNVERIFIED_CITATION] Key '\(key)' (\(status)) rejected by Citation Firewall: \(reason)"
        case .syncTeXMappingNotFound(let msg):
            return "SyncTeX mapping unavailable: \(msg)"
        case .pdfExtractionFailure(let msg):
            return "PDF provenance segmentation error: \(msg)"
        case .prismaProtocolViolation(let msg):
            return "PRISMA 2020 protocol error: \(msg)"
        case .sqliteError(let code, let msg):
            return "SQLite WAL/FTS5 error (\(code)): \(msg)"
        case .pluginError(let id, let msg):
            return "Editorial plugin '\(id)' error: \(msg)"
        case .invalidCLIArguments(let msg):
            return "Invalid CLI usage: \(msg)"
        }
    }
}
