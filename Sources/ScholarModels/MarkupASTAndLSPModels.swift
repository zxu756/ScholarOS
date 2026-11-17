import Foundation

// MARK: - Incremental LaTeX / Typst CST, AST & Built-in LSP Models

public enum MarkupTokenKind: String, Sendable, Codable, Hashable, CaseIterable {
    case command            // \section, \cite, \begin
    case typstHashKeyword   // #set, #show, #cite, @key
    case leftBrace          // {
    case rightBrace         // }
    case leftBracket        // [
    case rightBracket       // ]
    case mathInline         // $
    case mathDisplay        // $$ or \[ \]
    case comment            // % or //
    case verbatim           // opaque verbatim / conditional-skip / raw URL content
    case headingMarker      // = in Typst
    case identifier
    case numeric
    case punctuation
    case whitespace
    case textWord
    case eof
}

public struct MarkupToken: Sendable, Codable, Hashable {
    public let kind: MarkupTokenKind
    public let lexeme: String
    public let span: TextSpan

    public init(kind: MarkupTokenKind, lexeme: String, span: TextSpan) {
        self.kind = kind
        self.lexeme = lexeme
        self.span = span
    }
}

public enum MarkupASTNodeKind: Sendable, Codable, Hashable {
    case document(format: ManuscriptFormat)
    case section(level: Int, title: String, label: String?)
    case environment(name: String, label: String?, caption: String?)
    case citation(command: String, citeKeys: [String], prenote: String?, postnote: String?)
    case labelDeclaration(key: String)
    case crossReference(command: String, targetKey: String)
    case fileInclude(command: String, targetPath: String)
    case macroDefinition(name: String, parameterCount: Int, replacementBody: String)
    case mathExpression(isDisplayMode: Bool, formulaSource: String, label: String?)
    case paragraph(plainPreview: String)
    case syntaxErrorRecovery(message: String)
}

public struct MarkupASTNode: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let kind: MarkupASTNodeKind
    public let span: TextSpan
    public let children: [MarkupASTNode]

    public init(
        id: UUID = UUID(),
        kind: MarkupASTNodeKind,
        span: TextSpan,
        children: [MarkupASTNode] = []
    ) {
        self.id = id
        self.kind = kind
        self.span = span
        self.children = children
    }
}

public enum LSPDiagnosticSeverity: String, Sendable, Codable, Hashable, Comparable {
    case hint = "HINT"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"

    private var rank: Int {
        switch self {
        case .hint: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LSPDiagnosticSeverity, rhs: LSPDiagnosticSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum LSPDiagnosticCategory: String, Sendable, Codable, Hashable, CaseIterable {
    case structure = "structure"
    case citation = "citation"
    case lint = "lint"

    public static func infer(fromCode code: String) -> LSPDiagnosticCategory {
        if code == "ERR_UNVERIFIED_CITATION" || code.hasPrefix("FW_") {
            return .citation
        }
        if code.hasPrefix("LINT_") {
            return .lint
        }
        return .structure
    }
}

public struct LSPDiagnostic: Sendable, Codable, Hashable, Identifiable {
    public var id: String {
        "\(code)|\(span.filePath):\(span.start.line):\(span.start.column)|\(message)"
    }
    public let code: String
    public let category: LSPDiagnosticCategory
    public let severity: LSPDiagnosticSeverity
    public let message: String
    public let span: TextSpan
    public let suggestedFix: String?

    public init(
        code: String,
        category: LSPDiagnosticCategory? = nil,
        severity: LSPDiagnosticSeverity,
        message: String,
        span: TextSpan,
        suggestedFix: String? = nil
    ) {
        self.code = code
        self.category = category ?? LSPDiagnosticCategory.infer(fromCode: code)
        self.severity = severity
        self.message = message
        self.span = span
        self.suggestedFix = suggestedFix
    }
}

public enum LSPCompletionCategory: String, Sendable, Codable, Hashable {
    case citation = "Citation"
    case labelRef = "Cross-Ref"
    case command = "Command"
    case environment = "Environment"
    case mathSymbol = "Math Symbol"
    case userMacro = "User Macro"
}

public struct LSPCompletionItem: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let insertText: String
    public let title: String
    public let subtitle: String
    public let detailMarkdown: String
    public let category: LSPCompletionCategory
    public let relevanceScore: Double

    public init(
        id: String,
        insertText: String,
        title: String,
        subtitle: String,
        detailMarkdown: String = "",
        category: LSPCompletionCategory,
        relevanceScore: Double = 1.0
    ) {
        self.id = id
        self.insertText = insertText
        self.title = title
        self.subtitle = subtitle
        self.detailMarkdown = detailMarkdown
        self.category = category
        self.relevanceScore = relevanceScore
    }
}

public struct DocumentOutlineEntry: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let level: Int
    public let numberPrefix: String
    public let title: String
    public let label: String?
    public let filePath: String
    public let line: Int
    public let wordCountInSection: Int

    public init(
        level: Int,
        numberPrefix: String,
        title: String,
        label: String? = nil,
        filePath: String,
        line: Int,
        wordCountInSection: Int = 0
    ) {
        self.id = "\(filePath):\(line):\(title)"
        self.level = level
        self.numberPrefix = numberPrefix
        self.title = title
        self.label = label
        self.filePath = filePath
        self.line = line
        self.wordCountInSection = wordCountInSection
    }
}

public struct SyncTeXAnchor: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(sourceFile):\(line)->p\(pdfPageIndex)" }
    public let sourceFile: String
    public let line: Int
    public let column: Int
    public let pdfPageIndex: Int
    public let xPt: Double
    public let yPt: Double
    public let widthPt: Double
    public let heightPt: Double

    public init(
        sourceFile: String,
        line: Int,
        column: Int = 1,
        pdfPageIndex: Int,
        xPt: Double,
        yPt: Double,
        widthPt: Double,
        heightPt: Double
    ) {
        self.sourceFile = sourceFile
        self.line = line
        self.column = column
        self.pdfPageIndex = pdfPageIndex
        self.xPt = xPt
        self.yPt = yPt
        self.widthPt = widthPt
        self.heightPt = heightPt
    }
}
