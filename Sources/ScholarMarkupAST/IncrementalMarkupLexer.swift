import Foundation
import ScholarModels

// MARK: - UTF-8 Line & Scalar Position Index

/// Binary-searchable line-start offset table mapping 0-based UTF-8 byte offsets
/// to 1-based `(line, column)` Unicode-scalar coordinates in O(log L + C) time.
public struct LineByteIndex: Sendable, Codable, Hashable {
    /// 0-based UTF-8 byte offset of the start of each line (`index 0` is line 1 at byte `0`).
    public let lineStartUTF8Offsets: [Int]
    /// Total length of the indexed buffer in UTF-8 bytes.
    public let totalUTF8Bytes: Int

    public init(lineStartUTF8Offsets: [Int], totalUTF8Bytes: Int) {
        self.lineStartUTF8Offsets = lineStartUTF8Offsets.isEmpty ? [0] : lineStartUTF8Offsets
        self.totalUTF8Bytes = max(0, totalUTF8Bytes)
    }

    public init(source: String) {
        var starts: [Int] = [0]
        starts.reserveCapacity(max(16, source.utf8.count / 48))
        let utf8 = Array(source.utf8)
        var idx = 0
        let count = utf8.count
        while idx < count {
            let byte = utf8[idx]
            if byte == 0x0A { // '\n'
                starts.append(idx + 1)
            } else if byte == 0x0D { // '\r'
                if idx + 1 < count && utf8[idx + 1] == 0x0A {
                    idx += 1
                }
                starts.append(idx + 1)
            }
            idx += 1
        }
        self.lineStartUTF8Offsets = starts
        self.totalUTF8Bytes = count
    }

    public init(utf8Bytes: [UInt8]) {
        var starts: [Int] = [0]
        starts.reserveCapacity(max(16, utf8Bytes.count / 48))
        var idx = 0
        let count = utf8Bytes.count
        while idx < count {
            let byte = utf8Bytes[idx]
            if byte == 0x0A {
                starts.append(idx + 1)
            } else if byte == 0x0D {
                if idx + 1 < count && utf8Bytes[idx + 1] == 0x0A {
                    idx += 1
                }
                starts.append(idx + 1)
            }
            idx += 1
        }
        self.lineStartUTF8Offsets = starts
        self.totalUTF8Bytes = count
    }

    /// Number of 1-based lines in the source buffer.
    public var lineCount: Int {
        lineStartUTF8Offsets.count
    }

    /// Returns the 1-based line number containing `utf8Offset`.
    public func lineNumber(forUTF8Offset utf8Offset: Int) -> Int {
        let clamped = max(0, min(utf8Offset, totalUTF8Bytes))
        var low = 0
        var high = lineStartUTF8Offsets.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let midOffset = lineStartUTF8Offsets[mid]
            if midOffset == clamped {
                return mid + 1
            } else if midOffset < clamped {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return max(1, low)
    }

    /// Returns the 0-based UTF-8 byte offset where 1-based `line` starts.
    public func startUTF8Offset(ofLine line: Int) -> Int {
        guard !lineStartUTF8Offsets.isEmpty else { return 0 }
        let clampedLine = max(1, min(line, lineStartUTF8Offsets.count))
        return lineStartUTF8Offsets[clampedLine - 1]
    }

    /// Returns the 0-based UTF-8 byte offset where 1-based `line` ends (including its newline bytes if any).
    public func endUTF8Offset(ofLine line: Int) -> Int {
        guard !lineStartUTF8Offsets.isEmpty else { return 0 }
        let clampedLine = max(1, min(line, lineStartUTF8Offsets.count))
        if clampedLine < lineStartUTF8Offsets.count {
            return lineStartUTF8Offsets[clampedLine]
        }
        return totalUTF8Bytes
    }

    /// Computes a full `TextPosition` with 1-based `line`, 1-based Unicode-scalar `column`, and 0-based `utf8Offset`.
    public func position(forUTF8Offset utf8Offset: Int, in utf8Bytes: [UInt8]) -> TextPosition {
        let clamped = max(0, min(utf8Offset, utf8Bytes.count))
        let line = lineNumber(forUTF8Offset: clamped)
        let lineStart = startUTF8Offset(ofLine: line)
        var scalarCount = 0
        var cursor = lineStart
        while cursor < clamped {
            let lead = utf8Bytes[cursor]
            // Count only UTF-8 scalar lead bytes (not continuation bytes 10xxxxxx).
            if (lead & 0b1100_0000) != 0b1000_0000 {
                scalarCount += 1
            }
            cursor += 1
        }
        return TextPosition(line: line, column: scalarCount + 1, utf8Offset: clamped)
    }

    /// Convenience wrapper computing `TextPosition` from a `String`.
    public func position(forUTF8Offset utf8Offset: Int, in source: String) -> TextPosition {
        position(forUTF8Offset: utf8Offset, in: Array(source.utf8))
    }

    /// Resolves a 1-based `(line, column)` pair into a 0-based UTF-8 byte offset in `source`.
    public func utf8Offset(forLine line: Int, column: Int, in source: String) -> Int {
        let bytes = Array(source.utf8)
        let lineStart = startUTF8Offset(ofLine: line)
        let lineEnd = endUTF8Offset(ofLine: line)
        let targetScalars = max(0, column - 1)
        var seenScalars = 0
        var cursor = lineStart
        while cursor < lineEnd && seenScalars < targetScalars {
            let byte = bytes[cursor]
            if byte == 0x0A || byte == 0x0D {
                break
            }
            let step = UTF8ByteClassifier.scalarByteLength(leadingByte: byte)
            cursor = min(lineEnd, cursor + step)
            seenScalars += 1
        }
        return cursor
    }

    /// Maps a 0-based UTF-8 byte range to the inclusive 1-based line range touched by that range.
    public func lineRange(forUTF8Range byteRange: Range<Int>) -> ClosedRange<Int> {
        let startLine = lineNumber(forUTF8Offset: byteRange.lowerBound)
        let endProbe = byteRange.isEmpty ? byteRange.lowerBound : max(byteRange.lowerBound, byteRange.upperBound - 1)
        let endLine = max(startLine, lineNumber(forUTF8Offset: endProbe))
        return startLine...endLine
    }

    /// Maps an inclusive 1-based line range to its covering 0-based UTF-8 byte range.
    public func utf8ByteRange(forLines lines: ClosedRange<Int>) -> Range<Int> {
        let lower = startUTF8Offset(ofLine: lines.lowerBound)
        let upper = endUTF8Offset(ofLine: lines.upperBound)
        return lower..<max(lower, upper)
    }
}

// MARK: - Command & Directive Semantic Classifiers

/// Fine-grained lexical classification for LaTeX control words and control symbols.
public enum LaTeXCommandRole: String, Sendable, Codable, Hashable, CaseIterable {
    case documentClass
    case packageImport
    case sectioning
    case appendixSwitch
    case environmentBegin
    case environmentEnd
    case citation
    case labelDeclaration
    case crossReference
    case fileInclude
    case bibliographyResource
    case macroDefinition
    case mathDelimiter
    case captionCommand
    case footnoteCommand
    case proseFormatting
    case controlSymbol
    case generalCommand

    private static let sectioningCommands: Set<String> = [
        "\\part", "\\part*",
        "\\chapter", "\\chapter*",
        "\\section", "\\section*",
        "\\subsection", "\\subsection*",
        "\\subsubsection", "\\subsubsection*",
        "\\paragraph", "\\paragraph*",
        "\\subparagraph", "\\subparagraph*"
    ]

    private static let citationCommands: Set<String> = [
        "\\cite", "\\cite*", "\\citep", "\\citep*", "\\citet", "\\citet*",
        "\\citealt", "\\citealt*", "\\citealp", "\\citealp*",
        "\\citeauthor", "\\citeauthor*", "\\citeyear", "\\citeyearpar",
        "\\parencite", "\\parencite*", "\\textcite", "\\textcite*",
        "\\autocite", "\\autocite*", "\\footcite", "\\footfullcite",
        "\\fullcite", "\\supercite", "\\smartcite", "\\nocite",
        "\\cites", "\\parencites", "\\textcites", "\\autocites"
    ]

    private static let crossRefCommands: Set<String> = [
        "\\ref", "\\eqref", "\\autoref", "\\cref", "\\Cref",
        "\\cpageref", "\\Cpageref", "\\pageref", "\\nameref",
        "\\hyperref", "\\vref", "\\Vref", "\\fref", "\\Fref", "\\sref"
    ]

    private static let fileIncludeCommands: Set<String> = [
        "\\input", "\\include", "\\includeonly", "\\subfile",
        "\\import", "\\subimport", "\\inputIfFileExists"
    ]

    private static let bibliographyCommands: Set<String> = [
        "\\bibliography", "\\addbibresource", "\\addglobalbib", "\\nobibliography"
    ]

    private static let macroDefinitionCommands: Set<String> = [
        "\\newcommand", "\\newcommand*",
        "\\renewcommand", "\\renewcommand*",
        "\\providecommand", "\\providecommand*",
        "\\DeclareRobustCommand", "\\DeclareRobustCommand*",
        "\\DeclareMathOperator", "\\DeclareMathOperator*",
        "\\NewDocumentCommand", "\\RenewDocumentCommand", "\\ProvideDocumentCommand",
        "\\def", "\\gdef", "\\edef", "\\xdef"
    ]

    private static let captionCommands: Set<String> = [
        "\\caption", "\\caption*", "\\captionof", "\\subcaption", "\\bicaption"
    ]

    private static let footnoteCommands: Set<String> = [
        "\\footnote", "\\footnotetext", "\\marginpar", "\\marginnote", "\\thanks"
    ]

    private static let formattingCommands: Set<String> = [
        "\\textbf", "\\textit", "\\emph", "\\texttt", "\\textsc",
        "\\textrm", "\\textsf", "\\underline", "\\text", "\\mbox"
    ]

    public static func classify(_ lexeme: String) -> LaTeXCommandRole {
        guard lexeme.hasPrefix("\\"), lexeme.count >= 2 else {
            return .generalCommand
        }
        if lexeme == "\\documentclass" || lexeme == "\\LoadClass" {
            return .documentClass
        }
        if lexeme == "\\usepackage" || lexeme == "\\RequirePackage" {
            return .packageImport
        }
        if lexeme == "\\appendix" || lexeme == "\\appendices" {
            return .appendixSwitch
        }
        if lexeme == "\\begin" {
            return .environmentBegin
        }
        if lexeme == "\\end" {
            return .environmentEnd
        }
        if lexeme == "\\label" || lexeme == "\\linelabel" {
            return .labelDeclaration
        }
        if lexeme == "\\(" || lexeme == "\\)" || lexeme == "\\[" || lexeme == "\\]" {
            return .mathDelimiter
        }
        if sectioningCommands.contains(lexeme) {
            return .sectioning
        }
        if citationCommands.contains(lexeme) {
            return .citation
        }
        if crossRefCommands.contains(lexeme) {
            return .crossReference
        }
        if fileIncludeCommands.contains(lexeme) {
            return .fileInclude
        }
        if bibliographyCommands.contains(lexeme) {
            return .bibliographyResource
        }
        if macroDefinitionCommands.contains(lexeme) {
            return .macroDefinition
        }
        if captionCommands.contains(lexeme) {
            return .captionCommand
        }
        if footnoteCommands.contains(lexeme) {
            return .footnoteCommand
        }
        if formattingCommands.contains(lexeme) {
            return .proseFormatting
        }
        if lexeme.utf8.count == 2 {
            let second = lexeme.utf8[lexeme.utf8.index(after: lexeme.utf8.startIndex)]
            if !UTF8ByteClassifier.isASCIILetter(second) {
                return .controlSymbol
            }
        }
        return .generalCommand
    }
}

/// Fine-grained lexical classification for Typst `#` directives and `@` reference shorthands.
public enum TypstDirectiveRole: String, Sendable, Codable, Hashable, CaseIterable {
    case setRule
    case showRule
    case letBinding
    case importModule
    case includeFile
    case citeCall
    case refCall
    case shorthandReference
    case figureCall
    case tableCall
    case bibliographyCall
    case headingCall
    case mathEquationCall
    case generalHashDirective

    public static func classify(_ lexeme: String) -> TypstDirectiveRole {
        if lexeme.hasPrefix("@") {
            return .shorthandReference
        }
        switch lexeme {
        case "#set":
            return .setRule
        case "#show":
            return .showRule
        case "#let":
            return .letBinding
        case "#import":
            return .importModule
        case "#include":
            return .includeFile
        case "#cite":
            return .citeCall
        case "#ref":
            return .refCall
        case "#figure":
            return .figureCall
        case "#table":
            return .tableCall
        case "#bibliography":
            return .bibliographyCall
        case "#heading":
            return .headingCall
        case "#math.equation":
            return .mathEquationCall
        default:
            return .generalHashDirective
        }
    }
}

// MARK: - Lexer Configuration & Incremental Re-Lex Telemetry

/// Controls whitespace/comment retention for CST fidelity vs compact semantic streams.
public struct LexerConfiguration: Sendable, Codable, Hashable {
    public var includeWhitespaceTokens: Bool
    public var includeCommentTokens: Bool

    public init(
        includeWhitespaceTokens: Bool = true,
        includeCommentTokens: Bool = true
    ) {
        self.includeWhitespaceTokens = includeWhitespaceTokens
        self.includeCommentTokens = includeCommentTokens
    }

    /// Retains every byte of whitespace and comments so token concatenation reconstructs the exact source.
    public static let losslessCST = LexerConfiguration(
        includeWhitespaceTokens: true,
        includeCommentTokens: true
    )

    /// Strips whitespace tokens while preserving comments and structural tokens.
    public static let compactSemantic = LexerConfiguration(
        includeWhitespaceTokens: false,
        includeCommentTokens: true
    )
}

/// Telemetry reporting how much of the token stream was reused vs re-lexed during an incremental edit.
public struct IncrementalRelexMetrics: Sendable, Codable, Hashable {
    public let reusedPrefixTokenCount: Int
    public let relexedTokenCount: Int
    public let reusedSuffixTokenCount: Int
    public let dirtyStartUTF8Offset: Int
    public let dirtyEndUTF8OffsetInUpdated: Int
    public let byteDelta: Int
    public let lineDelta: Int
    public let fellBackToFullLex: Bool

    public init(
        reusedPrefixTokenCount: Int,
        relexedTokenCount: Int,
        reusedSuffixTokenCount: Int,
        dirtyStartUTF8Offset: Int,
        dirtyEndUTF8OffsetInUpdated: Int,
        byteDelta: Int,
        lineDelta: Int,
        fellBackToFullLex: Bool
    ) {
        self.reusedPrefixTokenCount = reusedPrefixTokenCount
        self.relexedTokenCount = relexedTokenCount
        self.reusedSuffixTokenCount = reusedSuffixTokenCount
        self.dirtyStartUTF8Offset = dirtyStartUTF8Offset
        self.dirtyEndUTF8OffsetInUpdated = dirtyEndUTF8OffsetInUpdated
        self.byteDelta = byteDelta
        self.lineDelta = lineDelta
        self.fellBackToFullLex = fellBackToFullLex
    }
}

/// Complete output of an incremental re-lex pass including updated tokens, telemetry, and fresh line index.
public struct IncrementalRelexResult: Sendable, Codable, Hashable {
    public let tokens: [MarkupToken]
    public let metrics: IncrementalRelexMetrics
    public let lineIndex: LineByteIndex

    public init(
        tokens: [MarkupToken],
        metrics: IncrementalRelexMetrics,
        lineIndex: LineByteIndex
    ) {
        self.tokens = tokens
        self.metrics = metrics
        self.lineIndex = lineIndex
    }
}

// MARK: - UTF-8 Byte Classification Helpers

enum UTF8ByteClassifier {
    @inline(__always)
    static func isASCIILetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    @inline(__always)
    static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    @inline(__always)
    static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        isASCIILetter(byte) || isASCIIDigit(byte)
    }

    @inline(__always)
    static func isHorizontalWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0B || byte == 0x0C
    }

    @inline(__always)
    static func isNewline(_ byte: UInt8) -> Bool {
        byte == 0x0A || byte == 0x0D
    }

    @inline(__always)
    static func isTypstIdentifierStart(_ byte: UInt8) -> Bool {
        isASCIILetter(byte) || byte == 0x5F // '_'
    }

    @inline(__always)
    static func isTypstIdentifierContinue(_ byte: UInt8) -> Bool {
        isASCIIAlphanumeric(byte) || byte == 0x5F || byte == 0x2D // '_' or '-'
    }

    @inline(__always)
    static func isCitationOrLabelChar(_ byte: UInt8) -> Bool {
        isASCIIAlphanumeric(byte)
            || byte == 0x5F // '_'
            || byte == 0x2D // '-'
            || byte == 0x3A // ':'
            || byte == 0x2E // '.'
            || byte == 0x2F // '/'
    }

    @inline(__always)
    static func scalarByteLength(leadingByte: UInt8) -> Int {
        if (leadingByte & 0b1000_0000) == 0 {
            return 1
        } else if (leadingByte & 0b1110_0000) == 0b1100_0000 {
            return 2
        } else if (leadingByte & 0b1111_0000) == 0b1110_0000 {
            return 3
        } else if (leadingByte & 0b1111_1000) == 0b1111_0000 {
            return 4
        }
        return 1
    }

    static func decodeScalar(at offset: Int, in bytes: [UInt8]) -> (scalar: UnicodeScalar, byteLength: Int) {
        let count = bytes.count
        guard offset < count else {
            return (UnicodeScalar(0), 0)
        }
        let b0 = bytes[offset]
        if b0 < 0x80 {
            return (UnicodeScalar(b0), 1)
        }
        let expectedLen = scalarByteLength(leadingByte: b0)
        guard offset + expectedLen <= count else {
            return (UnicodeScalar(0xFFFD)!, 1)
        }
        var codePoint: UInt32 = 0
        switch expectedLen {
        case 2:
            let b1 = bytes[offset + 1]
            guard (b1 & 0xC0) == 0x80 else { return (UnicodeScalar(0xFFFD)!, 1) }
            codePoint = (UInt32(b0 & 0x1F) << 6) | UInt32(b1 & 0x3F)
            if codePoint < 0x80 { return (UnicodeScalar(0xFFFD)!, 1) }
        case 3:
            let b1 = bytes[offset + 1]
            let b2 = bytes[offset + 2]
            guard (b1 & 0xC0) == 0x80, (b2 & 0xC0) == 0x80 else { return (UnicodeScalar(0xFFFD)!, 1) }
            codePoint = (UInt32(b0 & 0x0F) << 12) | (UInt32(b1 & 0x3F) << 6) | UInt32(b2 & 0x3F)
            if codePoint < 0x800 || (codePoint >= 0xD800 && codePoint <= 0xDFFF) {
                return (UnicodeScalar(0xFFFD)!, 1)
            }
        case 4:
            let b1 = bytes[offset + 1]
            let b2 = bytes[offset + 2]
            let b3 = bytes[offset + 3]
            guard (b1 & 0xC0) == 0x80, (b2 & 0xC0) == 0x80, (b3 & 0xC0) == 0x80 else {
                return (UnicodeScalar(0xFFFD)!, 1)
            }
            codePoint = (UInt32(b0 & 0x07) << 18)
                | (UInt32(b1 & 0x3F) << 12)
                | (UInt32(b2 & 0x3F) << 6)
                | UInt32(b3 & 0x3F)
            if codePoint < 0x10000 || codePoint > 0x10FFFF {
                return (UnicodeScalar(0xFFFD)!, 1)
            }
        default:
            return (UnicodeScalar(0xFFFD)!, 1)
        }
        if let scalar = UnicodeScalar(codePoint) {
            return (scalar, expectedLen)
        }
        return (UnicodeScalar(0xFFFD)!, 1)
    }

    static func isUnicodeWordScalar(_ scalar: UnicodeScalar) -> Bool {
        if scalar.value < 0x80 {
            let b = UInt8(scalar.value)
            return isASCIIAlphanumeric(b)
        }
        return CharacterSet.alphanumerics.contains(scalar)
            || CharacterSet.nonBaseCharacters.contains(scalar)
    }
}

// MARK: - Stateful UTF-8 Cursor Scanner

private struct UTF8Cursor {
    let bytes: [UInt8]
    let endOffset: Int
    let filePath: String
    var offset: Int
    var line: Int
    var column: Int

    init(
        bytes: [UInt8],
        startOffset: Int = 0,
        endOffset: Int? = nil,
        initialLine: Int = 1,
        initialColumn: Int = 1,
        filePath: String
    ) {
        self.bytes = bytes
        self.offset = max(0, min(startOffset, bytes.count))
        self.endOffset = max(self.offset, min(endOffset ?? bytes.count, bytes.count))
        self.line = max(1, initialLine)
        self.column = max(1, initialColumn)
        self.filePath = filePath
    }

    @inline(__always)
    var isAtEnd: Bool {
        offset >= endOffset
    }

    @inline(__always)
    var currentPosition: TextPosition {
        TextPosition(line: line, column: column, utf8Offset: offset)
    }

    @inline(__always)
    var isAtStartOfLine: Bool {
        column == 1
    }

    @inline(__always)
    func peekByte(_ ahead: Int = 0) -> UInt8? {
        let idx = offset + ahead
        guard idx >= 0 && idx < endOffset else { return nil }
        return bytes[idx]
    }

    @inline(__always)
    func previousByte() -> UInt8? {
        guard offset > 0 && offset - 1 < bytes.count else { return nil }
        return bytes[offset - 1]
    }

    @inline(__always)
    mutating func advanceASCIIByte() {
        guard offset < endOffset else { return }
        let b = bytes[offset]
        if b == 0x0A {
            offset += 1
            line += 1
            column = 1
        } else if b == 0x0D {
            if offset + 1 < endOffset && bytes[offset + 1] == 0x0A {
                offset += 2
            } else {
                offset += 1
            }
            line += 1
            column = 1
        } else {
            offset += 1
            column += 1
        }
    }

    @inline(__always)
    mutating func advanceASCIICount(_ count: Int) {
        for _ in 0..<count {
            advanceASCIIByte()
        }
    }

    @inline(__always)
    mutating func advanceOneScalar() {
        guard offset < endOffset else { return }
        let b = bytes[offset]
        if b < 0x80 {
            advanceASCIIByte()
        } else {
            let (_, len) = UTF8ByteClassifier.decodeScalar(at: offset, in: bytes)
            let clampedLen = min(len, endOffset - offset)
            offset += max(1, clampedLen)
            column += 1
        }
    }

    func sliceString(from startByte: Int, to endByte: Int) -> String {
        guard startByte < endByte, startByte >= 0, endByte <= bytes.count else {
            return ""
        }
        return String(decoding: bytes[startByte..<endByte], as: UTF8.self)
    }

    func makeToken(kind: MarkupTokenKind, from startPos: TextPosition) -> MarkupToken {
        let endPos = currentPosition
        let lexeme = sliceString(from: startPos.utf8Offset, to: endPos.utf8Offset)
        return MarkupToken(
            kind: kind,
            lexeme: lexeme,
            span: TextSpan(filePath: filePath, start: startPos, end: endPos)
        )
    }

    func matchesASCII(_ literal: StaticString) -> Bool {
        let ptr = literal.utf8Start
        let len = literal.utf8CodeUnitCount
        guard offset + len <= endOffset else { return false }
        for i in 0..<len {
            if bytes[offset + i] != ptr[i] {
                return false
            }
        }
        return true
    }
}

// MARK: - Incremental Markup Lexer

/// Handwritten UTF-8 & Unicode-scalar position-tracking lexer for LaTeX, Typst, and Academic Markdown
/// with line-boundary incremental re-lexing and zero external process invocations.
public struct IncrementalMarkupLexer: Sendable {
    public let configuration: LexerConfiguration

    public init(configuration: LexerConfiguration = .losslessCST) {
        self.configuration = configuration
    }

    // MARK: Public Full-Document Entry Points

    /// Tokenizes `source` according to `format`, emitting exact 1-based `(line, column)` and 0-based `utf8Offset` spans.
    public func tokenize(
        source: String,
        format: ManuscriptFormat,
        filePath: String = "main.tex"
    ) -> [MarkupToken] {
        let bytes = Array(source.utf8)
        var tokens = tokenizeSlice(
            bytes: bytes,
            startOffset: 0,
            endOffset: bytes.count,
            initialLine: 1,
            initialColumn: 1,
            format: format,
            filePath: filePath
        )
        let cursorAtEnd = computeEndPosition(
            fromTokens: tokens,
            bytes: bytes,
            fallbackInitialLine: 1,
            fallbackInitialColumn: 1,
            startOffset: 0
        )
        tokens.append(
            MarkupToken(
                kind: .eof,
                lexeme: "",
                span: TextSpan(filePath: filePath, start: cursorAtEnd, end: cursorAtEnd)
            )
        )
        return tokens
    }

    /// Tokenizes `source` by automatically inferring `ManuscriptFormat` from `filePath`.
    public func tokenize(source: String, filePath: String) -> [MarkupToken] {
        let detectedFormat = ManuscriptFormat.detect(fromPath: filePath)
        return tokenize(source: source, format: detectedFormat, filePath: filePath)
    }

    // MARK: Public Incremental Token-Splicing API

    /// Re-lexes only the dirty line window touched by `editByteRange`, splicing updated tokens into
    /// `previousTokens` and shifting downstream token `line` and `utf8Offset` coordinates in O(N) without full re-lexing.
    public func relexEdit(
        previousTokens: [MarkupToken],
        updatedSource: String,
        editByteRange: Range<Int>,
        filePath: String
    ) -> [MarkupToken] {
        let format = ManuscriptFormat.detect(fromPath: filePath)
        return relexEditDetailed(
            previousTokens: previousTokens,
            updatedSource: updatedSource,
            editByteRange: editByteRange,
            filePath: filePath,
            format: format
        ).tokens
    }

    /// Detailed incremental re-lexing entry point returning both the spliced `[MarkupToken]` stream,
    /// reuse/shift telemetry (`IncrementalRelexMetrics`), and the updated `LineByteIndex`.
    public func relexEditDetailed(
        previousTokens: [MarkupToken],
        previousSourceLengthUTF8: Int? = nil,
        updatedSource: String,
        editByteRange: Range<Int>,
        filePath: String,
        format: ManuscriptFormat? = nil
    ) -> IncrementalRelexResult {
        let resolvedFormat = format ?? ManuscriptFormat.detect(fromPath: filePath)
        let updatedBytes = Array(updatedSource.utf8)
        let updatedLineIndex = LineByteIndex(utf8Bytes: updatedBytes)
        let updatedLen = updatedBytes.count

        // Fast fallback when there is no usable prior token stream or whitespace was elided
        // (compact streams lack exact newline token boundaries on blank lines).
        guard !previousTokens.isEmpty, configuration.includeWhitespaceTokens else {
            let fullTokens = tokenize(source: updatedSource, format: resolvedFormat, filePath: filePath)
            let metrics = IncrementalRelexMetrics(
                reusedPrefixTokenCount: 0,
                relexedTokenCount: fullTokens.count,
                reusedSuffixTokenCount: 0,
                dirtyStartUTF8Offset: 0,
                dirtyEndUTF8OffsetInUpdated: updatedLen,
                byteDelta: updatedLen,
                lineDelta: updatedLineIndex.lineCount - 1,
                fellBackToFullLex: true
            )
            return IncrementalRelexResult(tokens: fullTokens, metrics: metrics, lineIndex: updatedLineIndex)
        }

        // Strip trailing EOF token from previous stream to work over real lexical tokens.
        let priorHasEOF = previousTokens.last?.kind == .eof
        let priorCoreCount = priorHasEOF ? (previousTokens.count - 1) : previousTokens.count
        let inferredOldLen = previousSourceLengthUTF8
            ?? previousTokens.last?.span.end.utf8Offset
            ?? 0
        let totalByteDelta = updatedLen - inferredOldLen

        // Empty updated document shortcut.
        if updatedLen == 0 {
            let eofPos = TextPosition.startOfFile
            let eofToken = MarkupToken(
                kind: .eof,
                lexeme: "",
                span: TextSpan(filePath: filePath, start: eofPos, end: eofPos)
            )
            let oldLines = previousTokens.last?.span.end.line ?? 1
            let metrics = IncrementalRelexMetrics(
                reusedPrefixTokenCount: 0,
                relexedTokenCount: 1,
                reusedSuffixTokenCount: 0,
                dirtyStartUTF8Offset: 0,
                dirtyEndUTF8OffsetInUpdated: 0,
                byteDelta: totalByteDelta,
                lineDelta: 1 - oldLines,
                fellBackToFullLex: false
            )
            return IncrementalRelexResult(tokens: [eofToken], metrics: metrics, lineIndex: updatedLineIndex)
        }

        // Determine conservative dirty start & end offsets across both old and new coordinate spaces.
        // Callers may pass `editByteRange` in either pre-edit or post-edit coordinates; taking the conservative
        // envelope handles insertions, replacements, and deletions identically.
        let safeEditStart = max(0, min(editByteRange.lowerBound, min(inferredOldLen, updatedLen)))

        let rawUpper = max(editByteRange.lowerBound, editByteRange.upperBound)
        let conservativeOldDirtyEnd = min(
            inferredOldLen,
            max(safeEditStart, max(rawUpper, rawUpper - min(0, totalByteDelta)))
        )
        let conservativeNewDirtyEnd = min(
            updatedLen,
            max(safeEditStart, max(rawUpper, rawUpper + max(0, totalByteDelta)))
        )

        // 1. Locate the latest prefix cut point in `previousTokens[0..<priorCoreCount]` where:
        //    - The next token starts at `column == 1` (exact line-start boundary)
        //    - `utf8Offset <= safeEditStart`
        //    - And in `updatedBytes`, `dirtyStartByte` is ALSO at a line start (byte 0 or preceded by '\n'/'\r').
        var prefixCount = findLineAlignedPrefixCut(
            in: previousTokens,
            coreCount: priorCoreCount,
            maxUTF8Offset: safeEditStart,
            updatedBytes: updatedBytes
        )

        // Ensure prefix does not end immediately after a multi-line comment or fenced construct in Typst/Markdown.
        while prefixCount > 0 && tokenMayAffectMultiLineState(previousTokens[prefixCount - 1], format: resolvedFormat) {
            prefixCount -= 1
            while prefixCount > 0 && previousTokens[prefixCount].span.start.column != 1 {
                prefixCount -= 1
            }
        }

        let dirtyStartPos: TextPosition
        if prefixCount == 0 {
            dirtyStartPos = .startOfFile
        } else if prefixCount < priorCoreCount {
            dirtyStartPos = previousTokens[prefixCount].span.start
        } else {
            dirtyStartPos = previousTokens[prefixCount - 1].span.end
        }
        let dirtyStartByte = dirtyStartPos.utf8Offset

        // Verify `dirtyStartByte` is a valid line start in `updatedBytes` as well.
        if dirtyStartByte > 0 {
            let prevByte = updatedBytes[dirtyStartByte - 1]
            if prevByte != 0x0A && prevByte != 0x0D {
                return performFullFallbackLex(
                    updatedSource: updatedSource,
                    updatedBytes: updatedBytes,
                    updatedLineIndex: updatedLineIndex,
                    format: resolvedFormat,
                    filePath: filePath,
                    byteDelta: totalByteDelta,
                    previousEndLine: previousTokens.last?.span.end.line ?? 1
                )
            }
        }

        // 2. Locate the earliest line-aligned suffix cut point in `previousTokens[prefixCount..<priorCoreCount]`
        //    strictly after `conservativeOldDirtyEnd` whose corresponding offset `oldOffset + totalByteDelta`
        //    in `updatedBytes` is also >= `conservativeNewDirtyEnd` and sits at a line boundary (`column == 1`).
        var suffixStartIndex: Int? = findLineAlignedSuffixCut(
            in: previousTokens,
            fromIndex: prefixCount,
            coreCount: priorCoreCount,
            minOldUTF8Offset: conservativeOldDirtyEnd,
            minNewUTF8Offset: conservativeNewDirtyEnd,
            byteDelta: totalByteDelta,
            updatedBytes: updatedBytes
        )

        // If any skipped old token in `[prefixCount ..< suffixStartIndex]` had multi-line comment/fence delimiters,
        // or the dirty slice in `updatedBytes` contains multi-line comment/fence markers, disable suffix reuse
        // so nested `/* ... */` or ```` ``` ```` state propagates cleanly to EOF.
        if let candidateSuffix = suffixStartIndex {
            let oldWindowHasMultiLine = (prefixCount..<candidateSuffix).contains { idx in
                tokenMayAffectMultiLineState(previousTokens[idx], format: resolvedFormat)
            }
            let newEndByte = previousTokens[candidateSuffix].span.start.utf8Offset + totalByteDelta
            let newSliceHasMultiLine = sliceContainsMultiLineDelimiter(
                bytes: updatedBytes,
                range: dirtyStartByte..<max(dirtyStartByte, min(updatedLen, newEndByte)),
                format: resolvedFormat
            )
            if oldWindowHasMultiLine || newSliceHasMultiLine {
                suffixStartIndex = nil
            }
        }

        // 3. Re-lex ONLY `[dirtyStartByte ..< dirtyEndByteInUpdated]`.
        let dirtyEndByteInUpdated: Int
        if let validSuffixIdx = suffixStartIndex {
            dirtyEndByteInUpdated = previousTokens[validSuffixIdx].span.start.utf8Offset + totalByteDelta
        } else {
            dirtyEndByteInUpdated = updatedLen
        }

        let relexedMiddle = tokenizeSlice(
            bytes: updatedBytes,
            startOffset: dirtyStartByte,
            endOffset: dirtyEndByteInUpdated,
            initialLine: dirtyStartPos.line,
            initialColumn: 1,
            format: resolvedFormat,
            filePath: filePath
        )

        // Compute exact post-middle cursor state to verify line alignment and shift suffix tokens.
        let middleEndPos = computeEndPosition(
            fromTokens: relexedMiddle,
            bytes: updatedBytes,
            fallbackInitialLine: dirtyStartPos.line,
            fallbackInitialColumn: 1,
            startOffset: dirtyStartByte
        )

        // Assemble final token array with preallocated capacity.
        let suffixCount = suffixStartIndex.map { priorCoreCount - $0 } ?? 0
        var assembled: [MarkupToken] = []
        assembled.reserveCapacity(prefixCount + relexedMiddle.count + suffixCount + 1)

        if prefixCount > 0 {
            assembled.append(contentsOf: previousTokens[0..<prefixCount])
        }
        assembled.append(contentsOf: relexedMiddle)

        let actualLineDelta: Int
        if let validSuffixIdx = suffixStartIndex {
            let firstSuffixOldStart = previousTokens[validSuffixIdx].span.start
            // Safety guard: the re-lexed slice must end at column 1 and exact `dirtyEndByteInUpdated`.
            if middleEndPos.column != 1 || middleEndPos.utf8Offset != dirtyEndByteInUpdated {
                return performFullFallbackLex(
                    updatedSource: updatedSource,
                    updatedBytes: updatedBytes,
                    updatedLineIndex: updatedLineIndex,
                    format: resolvedFormat,
                    filePath: filePath,
                    byteDelta: totalByteDelta,
                    previousEndLine: previousTokens.last?.span.end.line ?? 1
                )
            }
            actualLineDelta = middleEndPos.line - firstSuffixOldStart.line

            for idx in validSuffixIdx..<priorCoreCount {
                let oldTok = previousTokens[idx]
                let shiftedStart = TextPosition(
                    line: oldTok.span.start.line + actualLineDelta,
                    column: oldTok.span.start.column,
                    utf8Offset: oldTok.span.start.utf8Offset + totalByteDelta
                )
                let shiftedEnd = TextPosition(
                    line: oldTok.span.end.line + actualLineDelta,
                    column: oldTok.span.end.column,
                    utf8Offset: oldTok.span.end.utf8Offset + totalByteDelta
                )
                assembled.append(
                    MarkupToken(
                        kind: oldTok.kind,
                        lexeme: oldTok.lexeme,
                        span: TextSpan(filePath: filePath, start: shiftedStart, end: shiftedEnd)
                    )
                )
            }

            let eofPosition: TextPosition
            if let lastCore = assembled.last {
                eofPosition = lastCore.span.end
            } else {
                eofPosition = middleEndPos
            }
            assembled.append(
                MarkupToken(
                    kind: .eof,
                    lexeme: "",
                    span: TextSpan(filePath: filePath, start: eofPosition, end: eofPosition)
                )
            )
        } else {
            let oldEndLine = previousTokens.last?.span.end.line ?? 1
            actualLineDelta = middleEndPos.line - oldEndLine
            assembled.append(
                MarkupToken(
                    kind: .eof,
                    lexeme: "",
                    span: TextSpan(filePath: filePath, start: middleEndPos, end: middleEndPos)
                )
            )
        }

        let metrics = IncrementalRelexMetrics(
            reusedPrefixTokenCount: prefixCount,
            relexedTokenCount: relexedMiddle.count + (suffixStartIndex == nil ? 1 : 0),
            reusedSuffixTokenCount: suffixCount + (suffixStartIndex != nil ? 1 : 0),
            dirtyStartUTF8Offset: dirtyStartByte,
            dirtyEndUTF8OffsetInUpdated: dirtyEndByteInUpdated,
            byteDelta: totalByteDelta,
            lineDelta: actualLineDelta,
            fellBackToFullLex: false
        )
        return IncrementalRelexResult(tokens: assembled, metrics: metrics, lineIndex: updatedLineIndex)
    }

    // MARK: - Internal Incremental Splicing Helpers

    private func performFullFallbackLex(
        updatedSource: String,
        updatedBytes: [UInt8],
        updatedLineIndex: LineByteIndex,
        format: ManuscriptFormat,
        filePath: String,
        byteDelta: Int,
        previousEndLine: Int
    ) -> IncrementalRelexResult {
        let fullTokens = tokenize(source: updatedSource, format: format, filePath: filePath)
        let newEndLine = fullTokens.last?.span.end.line ?? 1
        let metrics = IncrementalRelexMetrics(
            reusedPrefixTokenCount: 0,
            relexedTokenCount: fullTokens.count,
            reusedSuffixTokenCount: 0,
            dirtyStartUTF8Offset: 0,
            dirtyEndUTF8OffsetInUpdated: updatedBytes.count,
            byteDelta: byteDelta,
            lineDelta: newEndLine - previousEndLine,
            fellBackToFullLex: true
        )
        return IncrementalRelexResult(tokens: fullTokens, metrics: metrics, lineIndex: updatedLineIndex)
    }

    private func findLineAlignedPrefixCut(
        in tokens: [MarkupToken],
        coreCount: Int,
        maxUTF8Offset: Int,
        updatedBytes: [UInt8]
    ) -> Int {
        guard coreCount > 0, maxUTF8Offset > 0 else { return 0 }

        // Binary search the last token starting at or before `maxUTF8Offset`.
        var low = 0
        var high = coreCount - 1
        var candidate = 0
        while low <= high {
            let mid = (low + high) / 2
            if tokens[mid].span.start.utf8Offset <= maxUTF8Offset {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        // Walk backward to a token boundary whose start sits at `column == 1` AND matches a line start in `updatedBytes`
        // AND is strictly before `maxUTF8Offset` (leaving one clean line buffer before the edit point so line-start
        // constructs like `=` in Typst or `#` in Markdown on the edited line re-lex from column 1).
        var idx = candidate
        while idx > 0 {
            let pos = tokens[idx].span.start
            if pos.column == 1 && pos.utf8Offset <= maxUTF8Offset && pos.utf8Offset <= updatedBytes.count {
                if pos.utf8Offset == 0 {
                    return 0
                }
                let precedingUpdatedByte = updatedBytes[pos.utf8Offset - 1]
                // Ensure the preceding token in `tokens` ended cleanly at `pos` with a newline.
                let prevTokEnd = tokens[idx - 1].span.end
                if prevTokEnd == pos && (precedingUpdatedByte == 0x0A || precedingUpdatedByte == 0x0D) {
                    // If `pos.utf8Offset == maxUTF8Offset`, step back one more line just in case an insertion
                    // deleted or merged with a `\r\n` pair right at `pos.utf8Offset`.
                    if pos.utf8Offset < maxUTF8Offset || (precedingUpdatedByte == 0x0A && !(pos.utf8Offset >= 2 && updatedBytes[pos.utf8Offset - 2] == 0x0D)) {
                        return idx
                    }
                }
            }
            idx -= 1
        }
        return 0
    }

    private func findLineAlignedSuffixCut(
        in tokens: [MarkupToken],
        fromIndex: Int,
        coreCount: Int,
        minOldUTF8Offset: Int,
        minNewUTF8Offset: Int,
        byteDelta: Int,
        updatedBytes: [UInt8]
    ) -> Int? {
        guard fromIndex < coreCount else { return nil }

        // Binary search first token with `start.utf8Offset > minOldUTF8Offset`.
        var low = fromIndex
        var high = coreCount - 1
        var startSearch: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if tokens[mid].span.start.utf8Offset > minOldUTF8Offset {
                startSearch = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        guard var idx = startSearch else { return nil }

        while idx < coreCount {
            let oldStart = tokens[idx].span.start
            if oldStart.column == 1 {
                let mappedNewOffset = oldStart.utf8Offset + byteDelta
                if mappedNewOffset >= minNewUTF8Offset && mappedNewOffset > 0 && mappedNewOffset < updatedBytes.count {
                    let prevNewByte = updatedBytes[mappedNewByteIndex(mappedNewOffset)]
                    if prevNewByte == 0x0A || (prevNewByte == 0x0D && updatedBytes[mappedNewOffset] != 0x0A) {
                        return idx
                    }
                }
            }
            idx += 1
        }
        return nil
    }

    @inline(__always)
    private func mappedNewByteIndex(_ mappedOffset: Int) -> Int {
        max(0, mappedOffset - 1)
    }

    private func tokenMayAffectMultiLineState(_ token: MarkupToken, format: ManuscriptFormat) -> Bool {
        switch format {
        case .latex:
            return false
        case .typst:
            if token.kind == .comment && token.lexeme.hasPrefix("/*") {
                return true
            }
            return token.lexeme.contains("/*") || token.lexeme.contains("*/")
        case .markdown:
            if token.kind == .comment && token.lexeme.hasPrefix("<!--") {
                return true
            }
            return token.lexeme.contains("```") || token.lexeme.contains("~~~") || token.lexeme.contains("<!--") || token.lexeme.contains("-->")
        }
    }

    private func sliceContainsMultiLineDelimiter(
        bytes: [UInt8],
        range: Range<Int>,
        format: ManuscriptFormat
    ) -> Bool {
        guard !range.isEmpty else { return false }
        switch format {
        case .latex:
            return false
        case .typst:
            var i = range.lowerBound
            while i + 1 < range.upperBound {
                if (bytes[i] == 0x2F && bytes[i + 1] == 0x2A) || (bytes[i] == 0x2A && bytes[i + 1] == 0x2F) {
                    return true
                }
                i += 1
            }
            return false
        case .markdown:
            var i = range.lowerBound
            while i + 2 < range.upperBound {
                if bytes[i] == 0x60 && bytes[i + 1] == 0x60 && bytes[i + 2] == 0x60 {
                    return true
                }
                if bytes[i] == 0x7E && bytes[i + 1] == 0x7E && bytes[i + 2] == 0x7E {
                    return true
                }
                if bytes[i] == 0x3C && bytes[i + 1] == 0x21 && bytes[i + 2] == 0x2D {
                    return true
                }
                if bytes[i] == 0x2D && bytes[i + 1] == 0x2D && bytes[i + 2] == 0x3E {
                    return true
                }
                i += 1
            }
            return false
        }
    }

    private func computeEndPosition(
        fromTokens tokens: [MarkupToken],
        bytes: [UInt8],
        fallbackInitialLine: Int,
        fallbackInitialColumn: Int,
        startOffset: Int
    ) -> TextPosition {
        if configuration.includeWhitespaceTokens && configuration.includeCommentTokens {
            if let last = tokens.last {
                return last.span.end
            }
            return TextPosition(line: fallbackInitialLine, column: fallbackInitialColumn, utf8Offset: startOffset)
        }
        // When whitespace or comments were filtered out, advance a lightweight cursor from the last kept token
        // (or `startOffset`) to the end of `bytes` so EOF has the exact line/column/utf8Offset.
        let basePos = tokens.last?.span.end ?? TextPosition(
            line: fallbackInitialLine,
            column: fallbackInitialColumn,
            utf8Offset: startOffset
        )
        var cursor = UTF8Cursor(
            bytes: bytes,
            startOffset: basePos.utf8Offset,
            endOffset: bytes.count,
            initialLine: basePos.line,
            initialColumn: basePos.column,
            filePath: ""
        )
        while !cursor.isAtEnd {
            cursor.advanceOneScalar()
        }
        return cursor.currentPosition
    }

    // MARK: - Format-Specific Slice Dispatch

    private func tokenizeSlice(
        bytes: [UInt8],
        startOffset: Int,
        endOffset: Int,
        initialLine: Int,
        initialColumn: Int,
        format: ManuscriptFormat,
        filePath: String
    ) -> [MarkupToken] {
        var cursor = UTF8Cursor(
            bytes: bytes,
            startOffset: startOffset,
            endOffset: endOffset,
            initialLine: initialLine,
            initialColumn: initialColumn,
            filePath: filePath
        )
        var output: [MarkupToken] = []
        output.reserveCapacity(max(16, (endOffset - startOffset) / 5))

        switch format {
        case .latex:
            lexLaTeX(cursor: &cursor, into: &output)
        case .typst:
            lexTypst(cursor: &cursor, into: &output)
        case .markdown:
            lexMarkdown(cursor: &cursor, into: &output)
        }
        return output
    }

    @inline(__always)
    private func emit(_ token: MarkupToken, into output: inout [MarkupToken]) {
        switch token.kind {
        case .whitespace:
            if configuration.includeWhitespaceTokens {
                output.append(token)
            }
        case .comment:
            if configuration.includeCommentTokens {
                output.append(token)
            }
        default:
            output.append(token)
        }
    }

    // MARK: - 1. LaTeX Handwritten State-Machine Lexer

    private func lexLaTeX(cursor: inout UTF8Cursor, into output: inout [MarkupToken]) {
        while !cursor.isAtEnd {
            let startPos = cursor.currentPosition
            guard let b = cursor.peekByte() else { break }

            // 1. Linebreaks: emitted as a single-newline `.whitespace` token so every subsequent line
            //    begins cleanly at `column == 1` for incremental line-window splicing.
            if UTF8ByteClassifier.isNewline(b) {
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .whitespace, from: startPos), into: &output)
                continue
            }

            // 2. Horizontal whitespace runs (' ', '\t', etc.) never cross a newline.
            if UTF8ByteClassifier.isHorizontalWhitespace(b) {
                cursor.advanceASCIIByte()
                while let next = cursor.peekByte(), UTF8ByteClassifier.isHorizontalWhitespace(next) {
                    cursor.advanceASCIIByte()
                }
                emit(cursor.makeToken(kind: .whitespace, from: startPos), into: &output)
                continue
            }

            // 3. LaTeX `%` line comments (consumes up to, but NOT including, the newline so newline keeps its invariant).
            if b == 0x25 { // '%'
                cursor.advanceASCIIByte()
                while let next = cursor.peekByte(), !UTF8ByteClassifier.isNewline(next) {
                    cursor.advanceOneScalar()
                }
                emit(cursor.makeToken(kind: .comment, from: startPos), into: &output)
                continue
            }

            // 4. Backslash commands, math delimiters (`\[`, `\]`, `\(`, `\)`), and control symbols (`\%`, `\{`, `\$`, etc.).
            if b == 0x5C { // '\'
                cursor.advanceASCIIByte()
                guard let second = cursor.peekByte() else {
                    emit(cursor.makeToken(kind: .command, from: startPos), into: &output)
                    continue
                }

                // Display math delimiters `\[` and `\]`
                if second == 0x5B || second == 0x5D { // '[' or ']'
                    cursor.advanceASCIIByte()
                    emit(cursor.makeToken(kind: .mathDisplay, from: startPos), into: &output)
                    continue
                }

                // Inline math delimiters `\(` and `\)`
                if second == 0x28 || second == 0x29 { // '(' or ')'
                    cursor.advanceASCIIByte()
                    emit(cursor.makeToken(kind: .mathInline, from: startPos), into: &output)
                    continue
                }

                // Control words: `\` followed by ASCII letters (plus `@` inside internal macros like `\makeatletter`,
                // and optional trailing `*` for starred forms like `\section*`, `\newcommand*`, `\DeclareMathOperator*`).
                if UTF8ByteClassifier.isASCIILetter(second) || second == 0x40 { // '@'
                    cursor.advanceASCIIByte()
                    while let cont = cursor.peekByte(),
                          UTF8ByteClassifier.isASCIILetter(cont) || cont == 0x40 {
                        cursor.advanceASCIIByte()
                    }
                    // Attach trailing `*` for starred sectioning/citation/macro commands (`\section*`, `\parencite*`, etc.)
                    if cursor.peekByte() == 0x2A { // '*'
                        let wordSoFar = cursor.sliceString(from: startPos.utf8Offset, to: cursor.offset)
                        if Self.starredCapableCommands.contains(wordSoFar) {
                            cursor.advanceASCIIByte()
                        }
                    }
                    emit(cursor.makeToken(kind: .command, from: startPos), into: &output)
                    continue
                }

                // Control symbol: `\` followed by a single non-letter scalar (except newline!).
                if !UTF8ByteClassifier.isNewline(second) {
                    cursor.advanceOneScalar()
                }
                emit(cursor.makeToken(kind: .command, from: startPos), into: &output)
                continue
            }

            // 5. Structural braces and brackets.
            switch b {
            case 0x7B: // '{'
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .leftBrace, from: startPos), into: &output)
                continue
            case 0x7D: // '}'
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .rightBrace, from: startPos), into: &output)
                continue
            case 0x5B: // '['
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .leftBracket, from: startPos), into: &output)
                continue
            case 0x5D: // ']'
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .rightBracket, from: startPos), into: &output)
                continue
            case 0x24: // '$' or '$$'
                cursor.advanceASCIIByte()
                if cursor.peekByte() == 0x24 {
                    cursor.advanceASCIIByte()
                    emit(cursor.makeToken(kind: .mathDisplay, from: startPos), into: &output)
                } else {
                    emit(cursor.makeToken(kind: .mathInline, from: startPos), into: &output)
                }
                continue
            default:
                break
            }

            // 6. TeX macro parameter token `#1`..`#9` or escaped `##`.
            if b == 0x23 { // '#'
                cursor.advanceASCIIByte()
                if let digit = cursor.peekByte(), (digit >= 0x31 && digit <= 0x39) || digit == 0x23 {
                    cursor.advanceASCIIByte()
                    emit(cursor.makeToken(kind: .identifier, from: startPos), into: &output)
                } else {
                    emit(cursor.makeToken(kind: .punctuation, from: startPos), into: &output)
                }
                continue
            }

            // 7. Numeric literals (`42`, `3.14159`, `1,000` only if decimal dot).
            if UTF8ByteClassifier.isASCIIDigit(b) {
                lexNumericRun(cursor: &cursor)
                // If immediately followed by letters (e.g. `2026a`, `3D`, `vaswani2017` suffix), upgrade to `.textWord`.
                if let afterNum = cursor.peekByte(), UTF8ByteClassifier.isASCIILetter(afterNum) {
                    while let cont = cursor.peekByte(), UTF8ByteClassifier.isASCIIAlphanumeric(cont) {
                        cursor.advanceASCIIByte()
                    }
                    emit(cursor.makeToken(kind: .textWord, from: startPos), into: &output)
                } else {
                    emit(cursor.makeToken(kind: .numeric, from: startPos), into: &output)
                }
                continue
            }

            // 8. ASCII or Unicode word / identifier runs (including internal hyphens/apostrophes when flanked by letters
            //    or cite-key characters like `sec:intro` when appropriate — note: keeping `:` and `-` carefully handled!).
            //    Wait: in `\label{sec:intro}` or `\cite{vaswani2017,dao2022}`, parser collects all tokens between `{` and `}`,
            //    so keeping words clean (`vaswani2017` -> `.textWord`, `sec` + `:` + `intro` -> `.textWord`, `.punctuation`, `.textWord`)
            //    works seamlessly for BOTH prose word counting AND `{...}` argument reconstruction!
            if UTF8ByteClassifier.isASCIILetter(b) {
                cursor.advanceASCIIByte()
                while let next = cursor.peekByte() {
                    if UTF8ByteClassifier.isASCIIAlphanumeric(next) || next == 0x5F {
                        cursor.advanceASCIIByte()
                    } else if next >= 0x80 {
                        let (scalar, _) = UTF8ByteClassifier.decodeScalar(at: cursor.offset, in: cursor.bytes)
                        if UTF8ByteClassifier.isUnicodeWordScalar(scalar) {
                            cursor.advanceOneScalar()
                        } else {
                            break
                        }
                    } else {
                        break
                    }
                }
                emit(cursor.makeToken(kind: .textWord, from: startPos), into: &output)
                continue
            }

            // 9. Multi-byte UTF-8 Unicode scalars (accented European scholars, Greek, CJK, mathematical Unicode).
            if b >= 0x80 {
                let (firstScalar, _) = UTF8ByteClassifier.decodeScalar(at: cursor.offset, in: cursor.bytes)
                if UTF8ByteClassifier.isUnicodeWordScalar(firstScalar) {
                    cursor.advanceOneScalar()
                    while let next = cursor.peekByte() {
                        if UTF8ByteClassifier.isASCIIAlphanumeric(next) {
                            cursor.advanceASCIIByte()
                        } else if next >= 0x80 {
                            let (scalar, _) = UTF8ByteClassifier.decodeScalar(at: cursor.offset, in: cursor.bytes)
                            if UTF8ByteClassifier.isUnicodeWordScalar(scalar) {
                                cursor.advanceOneScalar()
                            } else {
                                break
                            }
                        } else {
                            break
                        }
                    }
                    emit(cursor.makeToken(kind: .textWord, from: startPos), into: &output)
                } else {
                    cursor.advanceOneScalar()
                    emit(cursor.makeToken(kind: .punctuation, from: startPos), into: &output)
                }
                continue
            }

            // 10. Multi-character LaTeX ligature punctuation (`---`, `--`, ``` `` ```, `''`) or single ASCII punctuation.
            if b == 0x2D { // '-'
                cursor.advanceASCIIByte()
                if cursor.peekByte() == 0x2D {
                    cursor.advanceASCIIByte()
                    if cursor.peekByte() == 0x2D {
                        cursor.advanceASCIIByte()
                    }
                }
                emit(cursor.makeToken(kind: .punctuation, from: startPos), into: &output)
                continue
            }

            cursor.advanceASCIIByte()
            emit(cursor.makeToken(kind: .punctuation, from: startPos), into: &output)
        }
    }

    private static let starredCapableCommands: Set<String> = [
        "\\part", "\\chapter", "\\section", "\\subsection", "\\subsubsection",
        "\\paragraph", "\\subparagraph",
        "\\newcommand", "\\renewcommand", "\\providecommand", "\\DeclareRobustCommand",
        "\\DeclareMathOperator", "\\caption",
        "\\cite", "\\citep", "\\citet", "\\citealt", "\\citealp", "\\citeauthor",
        "\\parencite", "\\textcite", "\\autocite", "\\vspace", "\\hspace"
    ]

    // MARK: - 2. Typst Handwritten State-Machine Lexer

    private func lexTypst(cursor: inout UTF8Cursor, into output: inout [MarkupToken]) {
        var atLineStartIgnoringSpaces = cursor.isAtStartOfLine

        while !cursor.isAtEnd {
            let startPos = cursor.currentPosition
            guard let b = cursor.peekByte() else { break }

            // 1. Linebreaks reset `atLineStartIgnoringSpaces = true`.
            if UTF8ByteClassifier.isNewline(b) {
                cursor.advanceASCIIByte()
                atLineStartIgnoringSpaces = true
                emit(cursor.makeToken(kind: .whitespace, from: startPos), into: &output)
                continue
            }

            // 2. Horizontal whitespace preserves `atLineStartIgnoringSpaces` if nothing non-space appeared yet on this line.
            if UTF8ByteClassifier.isHorizontalWhitespace(b) {
                cursor.advanceASCIIByte()
                while let next = cursor.peekByte(), UTF8ByteClassifier.isHorizontalWhitespace(next) {
                    cursor.advanceASCIIByte()
                }
                emit(cursor.makeToken(kind: .whitespace, from: startPos), into: &output)
                continue
            }

            // 3. Typst `//` line comments and `/* ... */` NESTED block comments.
            if b == 0x2F { // '/'
                if cursor.peekByte(1) == 0x2F { // '//'
                    cursor.advanceASCIICount(2)
                    while let next = cursor.peekByte(), !UTF8ByteClassifier.isNewline(next) {
                        cursor.advanceOneScalar()
                    }
                    atLineStartIgnoringSpaces = false
                    emit(cursor.makeToken(kind: .comment, from: startPos), into: &output)
                    continue
                }
                if cursor.peekByte(1) == 0x2A { // '/*'
                    cursor.advanceASCIICount(2)
                    var nestingDepth = 1
                    while !cursor.isAtEnd && nestingDepth > 0 {
                        if cursor.peekByte() == 0x2F && cursor.peekByte(1) == 0x2A {
                            cursor.advanceASCIICount(2)
                            nestingDepth += 1
                        } else if cursor.peekByte() == 0x2A && cursor.peekByte(1) == 0x2F {
                            cursor.advanceASCIICount(2)
                            nestingDepth -= 1
                        } else {
                            cursor.advanceOneScalar()
                        }
                    }
                    atLineStartIgnoringSpaces = cursor.isAtStartOfLine
                    emit(cursor.makeToken(kind: .comment, from: startPos), into: &output)
                    continue
                }
            }

            // 4. Typst line-start heading markers `=`, `==`, `===`, `====` followed by horizontal whitespace or EOL.
            if atLineStartIgnoringSpaces && b == 0x3D { // '='
                var eqLen = 1
                while cursor.peekByte(eqLen) == 0x3D {
                    eqLen += 1
                }
                let afterEq = cursor.peekByte(eqLen)
                if afterEq == nil || UTF8ByteClassifier.isHorizontalWhitespace(afterEq!) || UTF8ByteClassifier.isNewline(afterEq!) {
                    cursor.advanceASCIICount(eqLen)
                    atLineStartIgnoringSpaces = false
                    emit(cursor.makeToken(kind: .headingMarker, from: startPos), into: &output)
                    continue
                }
            }

            atLineStartIgnoringSpaces = false

            // 5. Typst backslash escapes (`\$`, `\#`, `\@`, `\<`, `\>`, `\\`, etc.).
            if b == 0x5C { // '\'
                cursor.advanceASCIIByte()
                if let next = cursor.peekByte(), !UTF8ByteClassifier.isNewline(next) {
                    cursor.advanceOneScalar()
                }
                emit(cursor.makeToken(kind: .command, from: startPos), into: &output)
                continue
            }

            // 6. Typst `#` directives (`#set`, `#show`, `#let`, `#import`, `#include`, `#cite`, `#figure`, `#table`, `#bibliography`).
            if b == 0x23 { // '#'
                cursor.advanceASCIIByte()
                if let second = cursor.peekByte(), UTF8ByteClassifier.isTypstIdentifierStart(second) {
                    cursor.advanceASCIIByte()
                    while let cont = cursor.peekByte(),
                          UTF8ByteClassifier.isTypstIdentifierContinue(cont) || cont == 0x2E { // allow `#math.equation` when followed by ident
                        if cont == 0x2E {
                            if let afterDot = cursor.peekByte(1), UTF8ByteClassifier.isTypstIdentifierStart(afterDot) {
                                cursor.advanceASCIIByte()
                            } else {
                                break
                            }
                        } else {
                            cursor.advanceASCIIByte()
                        }
                    }
                    emit(cursor.makeToken(kind: .typstHashKeyword, from: startPos), into: &output)
                } else {
                    emit(cursor.makeToken(kind: .typstHashKeyword, from: startPos), into: &output)
                }
                continue
            }

            // 7. Typst `@citekey` / `@sec:intro` shorthand references (only when NOT preceded by alphanumeric, avoiding emails).
            if b == 0x40 { // '@'
                let prev = cursor.previousByte()
                let precededByWord = prev.map { UTF8ByteClassifier.isASCIIAlphanumeric($0) } ?? false
                if !precededByWord, let second = cursor.peekByte(1), UTF8ByteClassifier.isCitationOrLabelChar(second) {
                    cursor.advanceASCIICount(2)
                    while let cont = cursor.peekByte(), UTF8ByteClassifier.isCitationOrLabelChar(cont) {
                        // Do not absorb trailing sentence punctuation `.` or `:` at the very end of `@vaswani2017.`!
                        if cont == 0x2E || cont == 0x3A {
                            if let afterPunct = cursor.peekByte(1), UTF8ByteClassifier.isASCIIAlphanumeric(afterPunct) || afterPunct == 0x5F || afterPunct == 0x2D {
                                cursor.advanceASCIIByte()
                            } else {
                                break
                            }
                        } else {
                            cursor.advanceASCIIByte()
                        }
                    }
                    emit(cursor.makeToken(kind: .typstHashKeyword, from: startPos), into: &output)
                    continue
                }
            }

            // 8. Typst `<label>` declarations & label literals (`<sec:intro>`, `<vaswani2017>`).
            if b == 0x3C { // '<'
                if let labelByteLen = scanTypstAngleLabelLength(cursor: cursor) {
                    cursor.advanceASCIICount(labelByteLen)
                    emit(cursor.makeToken(kind: .identifier, from: startPos), into: &output)
                    continue
                }
            }

            // 9. Typst string literals `"..."` (kept intact so `#include "appendix.typ"` and `#bibliography("refs.bib")` lex cleanly).
            if b == 0x22 { // '"'
                cursor.advanceASCIIByte()
                while let ch = cursor.peekByte(), !UTF8ByteClassifier.isNewline(ch) {
                    if ch == 0x5C { // '\"' escape
                        cursor.advanceASCIIByte()
                        if let esc = cursor.peekByte(), !UTF8ByteClassifier.isNewline(esc) {
                            cursor.advanceOneScalar()
                        }
                    } else if ch == 0x22 {
                        cursor.advanceASCIIByte()
                        break
                    } else {
                        cursor.advanceOneScalar()
                    }
                }
                emit(cursor.makeToken(kind: .identifier, from: startPos), into: &output)
                continue
            }

            // 10. Typst `$` math delimiter.
            if b == 0x24 { // '$'
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .mathInline, from: startPos), into: &output)
                continue
            }

            // 11. Braces & brackets.
            switch b {
            case 0x7B:
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .leftBrace, from: startPos), into: &output)
                continue
            case 0x7D:
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .rightBrace, from: startPos), into: &output)
                continue
            case 0x5B:
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .leftBracket, from: startPos), into: &output)
                continue
            case 0x5D:
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .rightBracket, from: startPos), into: &output)
                continue
            default:
                break
            }

            // 12. Numbers & words.
            if UTF8ByteClassifier.isASCIIDigit(b) {
                lexNumericRun(cursor: &cursor)
                // Consume optional Typst unit suffix (`12pt`, `2em`, `80%` stays separate `%`).
                if let next = cursor.peekByte(), UTF8ByteClassifier.isASCIILetter(next) {
                    while let u = cursor.peekByte(), UTF8ByteClassifier.isASCIIAlphanumeric(u) {
                        cursor.advanceASCIIByte()
                    }
                    emit(cursor.makeToken(kind: .numeric, from: startPos), into: &output)
                } else {
                    emit(cursor.makeToken(kind: .numeric, from: startPos), into: &output)
                }
                continue
            }

            if UTF8ByteClassifier.isASCIILetter(b) || b == 0x5F {
                cursor.advanceASCIIByte()
                while let next = cursor.peekByte() {
                    if UTF8ByteClassifier.isASCIIAlphanumeric(next) || next == 0x5F {
                        cursor.advanceASCIIByte()
                    } else if next >= 0x80 {
                        let (scalar, _) = UTF8ByteClassifier.decodeScalar(at: cursor.offset, in: cursor.bytes)
                        if UTF8ByteClassifier.isUnicodeWordScalar(scalar) {
                            cursor.advanceOneScalar()
                        } else {
                            break
                        }
                    } else {
                        break
                    }
                }
                emit(cursor.makeToken(kind: .textWord, from: startPos), into: &output)
                continue
            }

            if b >= 0x80 {
                let (scalar, _) = UTF8ByteClassifier.decodeScalar(at: cursor.offset, in: cursor.bytes)
                if UTF8ByteClassifier.isUnicodeWordScalar(scalar) {
                    cursor.advanceOneScalar()
                    while let next = cursor.peekByte() {
                        if UTF8ByteClassifier.isASCIIAlphanumeric(next) {
                            cursor.advanceASCIIByte()
                        } else if next >= 0x80 {
                            let (s2, _) = UTF8ByteClassifier.decodeScalar(at: cursor.offset, in: cursor.bytes)
                            if UTF8ByteClassifier.isUnicodeWordScalar(s2) {
                                cursor.advanceOneScalar()
                            } else {
                                break
                            }
                        } else {
                            break
                        }
                    }
                    emit(cursor.makeToken(kind: .textWord, from: startPos), into: &output)
                } else {
                    cursor.advanceOneScalar()
                    emit(cursor.makeToken(kind: .punctuation, from: startPos), into: &output)
                }
                continue
            }

            cursor.advanceASCIIByte()
            emit(cursor.makeToken(kind: .punctuation, from: startPos), into: &output)
        }
    }

    /// Checks whether `cursor` sits at a valid Typst `<label>` literal `<[A-Za-z0-9_][A-Za-z0-9_.:-]*>` on a single line.
    private func scanTypstAngleLabelLength(cursor: UTF8Cursor) -> Int? {
        guard cursor.peekByte(0) == 0x3C else { return nil } // '<'
        guard let firstInner = cursor.peekByte(1),
              UTF8ByteClassifier.isASCIIAlphanumeric(firstInner) || firstInner == 0x5F else {
            return nil
        }
        var idx = 2
        while let ch = cursor.peekByte(idx) {
            if ch == 0x3E { // '>'
                return idx + 1
            }
            if !UTF8ByteClassifier.isCitationOrLabelChar(ch) {
                return nil
            }
            idx += 1
        }
        return nil
    }

    // MARK: - 3. Academic Markdown (Pandoc / Quarto / Embedded LaTeX) Lexer

    private func lexMarkdown(cursor: inout UTF8Cursor, into output: inout [MarkupToken]) {
        var atLineStartIgnoringSpaces = cursor.isAtStartOfLine

        while !cursor.isAtEnd {
            let startPos = cursor.currentPosition
            guard let b = cursor.peekByte() else { break }

            if UTF8ByteClassifier.isNewline(b) {
                cursor.advanceASCIIByte()
                atLineStartIgnoringSpaces = true
                emit(cursor.makeToken(kind: .whitespace, from: startPos), into: &output)
                continue
            }

            if UTF8ByteClassifier.isHorizontalWhitespace(b) {
                cursor.advanceASCIIByte()
                while let next = cursor.peekByte(), UTF8ByteClassifier.isHorizontalWhitespace(next) {
                    cursor.advanceASCIIByte()
                }
                emit(cursor.makeToken(kind: .whitespace, from: startPos), into: &output)
                continue
            }

            // HTML comment `<!-- ... -->`
            if b == 0x3C && cursor.matchesASCII("<!--") {
                cursor.advanceASCIICount(4)
                while !cursor.isAtEnd {
                    if cursor.matchesASCII("-->") {
                        cursor.advanceASCIICount(3)
                        break
                    }
                    cursor.advanceOneScalar()
                }
                atLineStartIgnoringSpaces = cursor.isAtStartOfLine
                emit(cursor.makeToken(kind: .comment, from: startPos), into: &output)
                continue
            }

            // ATX Markdown headings `#`, `##`, ..., `######` at line start followed by space/EOL.
            if atLineStartIgnoringSpaces && b == 0x23 { // '#'
                var hashCount = 1
                while hashCount < 6 && cursor.peekByte(hashCount) == 0x23 {
                    hashCount += 1
                }
                let afterHashes = cursor.peekByte(hashCount)
                if afterHashes == nil
                    || UTF8ByteClassifier.isHorizontalWhitespace(afterHashes!)
                    || UTF8ByteClassifier.isNewline(afterHashes!) {
                    cursor.advanceASCIICount(hashCount)
                    atLineStartIgnoringSpaces = false
                    emit(cursor.makeToken(kind: .headingMarker, from: startPos), into: &output)
                    continue
                }
            }

            atLineStartIgnoringSpaces = false

            // Embedded LaTeX commands & math delimiters (`\cite`, `\eqref`, `\begin`, `\[`, `\]`, `\(`, `\)`).
            if b == 0x5C { // '\'
                cursor.advanceASCIIByte()
                if let second = cursor.peekByte() {
                    if second == 0x5B || second == 0x5D {
                        cursor.advanceASCIIByte()
                        emit(cursor.makeToken(kind: .mathDisplay, from: startPos), into: &output)
                        continue
                    }
                    if second == 0x28 || second == 0x29 {
                        cursor.advanceASCIIByte()
                        emit(cursor.makeToken(kind: .mathInline, from: startPos), into: &output)
                        continue
                    }
                    if UTF8ByteClassifier.isASCIILetter(second) {
                        cursor.advanceASCIIByte()
                        while let cont = cursor.peekByte(), UTF8ByteClassifier.isASCIILetter(cont) {
                            cursor.advanceASCIIByte()
                        }
                        if cursor.peekByte() == 0x2A {
                            cursor.advanceASCIIByte()
                        }
                        emit(cursor.makeToken(kind: .command, from: startPos), into: &output)
                        continue
                    }
                    if !UTF8ByteClassifier.isNewline(second) {
                        cursor.advanceOneScalar()
                    }
                }
                emit(cursor.makeToken(kind: .command, from: startPos), into: &output)
                continue
            }

            // Pandoc / Quarto `@citekey` citations (`[@vaswani2017; @dao2022]` or `@vaswani2017`).
            if b == 0x40 { // '@'
                let prev = cursor.previousByte()
                let precededByWord = prev.map { UTF8ByteClassifier.isASCIIAlphanumeric($0) } ?? false
                if !precededByWord, let second = cursor.peekByte(1), UTF8ByteClassifier.isCitationOrLabelChar(second) {
                    cursor.advanceASCIICount(2)
                    while let cont = cursor.peekByte(), UTF8ByteClassifier.isCitationOrLabelChar(cont) {
                        if cont == 0x2E || cont == 0x3A {
                            if let afterPunct = cursor.peekByte(1), UTF8ByteClassifier.isASCIIAlphanumeric(afterPunct) || afterPunct == 0x5F || afterPunct == 0x2D {
                                cursor.advanceASCIIByte()
                            } else {
                                break
                            }
                        } else {
                            cursor.advanceASCIIByte()
                        }
                    }
                    emit(cursor.makeToken(kind: .typstHashKeyword, from: startPos), into: &output)
                    continue
                }
            }

            // Math `$` and `$$`.
            if b == 0x24 {
                cursor.advanceASCIIByte()
                if cursor.peekByte() == 0x24 {
                    cursor.advanceASCIIByte()
                    emit(cursor.makeToken(kind: .mathDisplay, from: startPos), into: &output)
                } else {
                    emit(cursor.makeToken(kind: .mathInline, from: startPos), into: &output)
                }
                continue
            }

            // Braces & brackets.
            switch b {
            case 0x7B:
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .leftBrace, from: startPos), into: &output)
                continue
            case 0x7D:
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .rightBrace, from: startPos), into: &output)
                continue
            case 0x5B:
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .leftBracket, from: startPos), into: &output)
                continue
            case 0x5D:
                cursor.advanceASCIIByte()
                emit(cursor.makeToken(kind: .rightBracket, from: startPos), into: &output)
                continue
            default:
                break
            }

            // Numbers & words.
            if UTF8ByteClassifier.isASCIIDigit(b) {
                lexNumericRun(cursor: &cursor)
                if let next = cursor.peekByte(), UTF8ByteClassifier.isASCIILetter(next) {
                    while let cont = cursor.peekByte(), UTF8ByteClassifier.isASCIIAlphanumeric(cont) {
                        cursor.advanceASCIIByte()
                    }
                    emit(cursor.makeToken(kind: .textWord, from: startPos), into: &output)
                } else {
                    emit(cursor.makeToken(kind: .numeric, from: startPos), into: &output)
                }
                continue
            }

            if UTF8ByteClassifier.isASCIILetter(b) {
                cursor.advanceASCIIByte()
                while let next = cursor.peekByte() {
                    if UTF8ByteClassifier.isASCIIAlphanumeric(next) || next == 0x5F {
                        cursor.advanceASCIIByte()
                    } else if next >= 0x80 {
                        let (scalar, _) = UTF8ByteClassifier.decodeScalar(at: cursor.offset, in: cursor.bytes)
                        if UTF8ByteClassifier.isUnicodeWordScalar(scalar) {
                            cursor.advanceOneScalar()
                        } else {
                            break
                        }
                    } else {
                        break
                    }
                }
                emit(cursor.makeToken(kind: .textWord, from: startPos), into: &output)
                continue
            }

            if b >= 0x80 {
                let (scalar, _) = UTF8ByteClassifier.decodeScalar(at: cursor.offset, in: cursor.bytes)
                if UTF8ByteClassifier.isUnicodeWordScalar(scalar) {
                    cursor.advanceOneScalar()
                    while let next = cursor.peekByte() {
                        if UTF8ByteClassifier.isASCIIAlphanumeric(next) {
                            cursor.advanceASCIIByte()
                        } else if next >= 0x80 {
                            let (s2, _) = UTF8ByteClassifier.decodeScalar(at: cursor.offset, in: cursor.bytes)
                            if UTF8ByteClassifier.isUnicodeWordScalar(s2) {
                                cursor.advanceOneScalar()
                            } else {
                                break
                            }
                        } else {
                            break
                        }
                    }
                    emit(cursor.makeToken(kind: .textWord, from: startPos), into: &output)
                } else {
                    cursor.advanceOneScalar()
                    emit(cursor.makeToken(kind: .punctuation, from: startPos), into: &output)
                }
                continue
            }

            cursor.advanceASCIIByte()
            emit(cursor.makeToken(kind: .punctuation, from: startPos), into: &output)
        }
    }

    // MARK: - Shared Numeric Sub-Scanner

    private func lexNumericRun(cursor: inout UTF8Cursor) {
        cursor.advanceASCIIByte()
        while let d = cursor.peekByte(), UTF8ByteClassifier.isASCIIDigit(d) {
            cursor.advanceASCIIByte()
        }
        // Decimal fractional component `.1415`
        if cursor.peekByte(0) == 0x2E, let frac = cursor.peekByte(1), UTF8ByteClassifier.isASCIIDigit(frac) {
            cursor.advanceASCIICount(2)
            while let d = cursor.peekByte(), UTF8ByteClassifier.isASCIIDigit(d) {
                cursor.advanceASCIIByte()
            }
        }
    }
}
