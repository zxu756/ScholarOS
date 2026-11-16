import Foundation
import ScholarModels
import ScholarMarkupAST
import ScholarBibAndCSL

// MARK: - Structured Manuscript Diagnostics JSON Schema (`scholaros.diagnostics/1`)

public struct DiagnosticsFileRecord: Sendable, Codable, Hashable {
    public let path: String
    public let encoding: String
    public let includedFrom: String?

    public init(path: String, encoding: String = "utf-8", includedFrom: String? = nil) {
        self.path = path
        self.encoding = encoding
        self.includedFrom = includedFrom
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case encoding
        case includedFrom
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(encoding, forKey: .encoding)
        if let includedFrom {
            try container.encode(includedFrom, forKey: .includedFrom)
        } else {
            try container.encodeNil(forKey: .includedFrom)
        }
    }
}

public struct DiagnosticsBibliographyParseError: Sendable, Codable, Hashable {
    public let key: String?
    public let startLine: Int
    public let line: Int
    public let message: String

    public init(key: String?, startLine: Int, line: Int, message: String) {
        self.key = key
        self.startLine = startLine
        self.line = line
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case startLine
        case line
        case message
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let key {
            try container.encode(key, forKey: .key)
        } else {
            try container.encodeNil(forKey: .key)
        }
        try container.encode(startLine, forKey: .startLine)
        try container.encode(line, forKey: .line)
        try container.encode(message, forKey: .message)
    }
}

public struct DiagnosticsBibliographySource: Sendable, Codable, Hashable {
    public let kind: String
    public let path: String
    public let entries: Int
    public let errors: [DiagnosticsBibliographyParseError]

    public init(
        kind: String,
        path: String,
        entries: Int,
        errors: [DiagnosticsBibliographyParseError] = []
    ) {
        self.kind = kind
        self.path = path
        self.entries = entries
        self.errors = errors
    }
}

public struct DiagnosticsCitationOccurrence: Sendable, Codable, Hashable {
    public let file: String
    public let line: Int
    public let column: Int
    public let command: String

    public init(file: String, line: Int, column: Int, command: String) {
        self.file = file
        self.line = line
        self.column = column
        self.command = command
    }
}

public struct DiagnosticsCitationVerification: Sendable, Codable, Hashable {
    public let verdict: String
    public let reasons: [String]
    public let sources: [CitationVerdictSourceRecord]
    public let fields: [CitationFieldDiscrepancy]
    public let findings: [FirewallFinding]
    public let insertable: Bool

    public init(
        verdict: String,
        reasons: [String],
        sources: [CitationVerdictSourceRecord],
        fields: [CitationFieldDiscrepancy],
        findings: [FirewallFinding] = [],
        insertable: Bool
    ) {
        self.verdict = verdict
        self.reasons = reasons
        self.sources = sources
        self.fields = fields
        self.findings = findings
        self.insertable = insertable
    }

    public init(from entryVerdict: CitationFirewallEntryVerdict) {
        self.verdict = entryVerdict.firewallClass.rawValue
        self.reasons = entryVerdict.reasons
        self.sources = entryVerdict.sources
        self.fields = entryVerdict.fields
        self.findings = entryVerdict.findings
        self.insertable = entryVerdict.insertable
    }
}

public struct DiagnosticsCitationEntry: Sendable, Codable, Hashable {
    public let key: String
    public let defined: Bool
    public let source: String?
    public let occurrences: [DiagnosticsCitationOccurrence]
    public let verification: DiagnosticsCitationVerification?

    public init(
        key: String,
        defined: Bool,
        source: String?,
        occurrences: [DiagnosticsCitationOccurrence],
        verification: DiagnosticsCitationVerification?
    ) {
        self.key = key
        self.defined = defined
        self.source = source
        self.occurrences = occurrences
        self.verification = verification
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case defined
        case source
        case occurrences
        case verification
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(defined, forKey: .defined)
        if let source {
            try container.encode(source, forKey: .source)
        } else {
            try container.encodeNil(forKey: .source)
        }
        try container.encode(occurrences, forKey: .occurrences)
        if let verification {
            try container.encode(verification, forKey: .verification)
        } else {
            try container.encodeNil(forKey: .verification)
        }
    }
}

public struct DiagnosticsLabelRecord: Sendable, Codable, Hashable {
    public let key: String
    public let file: String
    public let line: Int

    public init(key: String, file: String, line: Int) {
        self.key = key
        self.file = file
        self.line = line
    }
}

public struct DiagnosticsReferenceRecord: Sendable, Codable, Hashable {
    public let key: String
    public let file: String
    public let line: Int
    public let command: String
    public let resolved: Bool

    public init(key: String, file: String, line: Int, command: String, resolved: Bool) {
        self.key = key
        self.file = file
        self.line = line
        self.command = command
        self.resolved = resolved
    }
}

public struct DiagnosticsItemRecord: Sendable, Codable, Hashable {
    public let code: String
    public let category: LSPDiagnosticCategory
    public let severity: LSPDiagnosticSeverity
    public let file: String
    public let line: Int
    public let column: Int
    public let message: String

    public init(
        code: String,
        category: LSPDiagnosticCategory,
        severity: LSPDiagnosticSeverity,
        file: String,
        line: Int,
        column: Int,
        message: String
    ) {
        self.code = code
        self.category = category
        self.severity = severity
        self.file = file
        self.line = line
        self.column = column
        self.message = message
    }

    public init(from diagnostic: LSPDiagnostic) {
        self.code = diagnostic.code
        self.category = diagnostic.category
        self.severity = diagnostic.severity
        self.file = diagnostic.span.filePath
        self.line = diagnostic.span.start.line
        self.column = diagnostic.span.start.column
        self.message = diagnostic.message
    }
}

public struct DiagnosticsCountsSummary: Sendable, Codable, Hashable {
    public let byCode: [String: Int]
    public let bySeverity: [String: Int]
    public let verdicts: [String: Int]

    public init(
        byCode: [String: Int],
        bySeverity: [String: Int],
        verdicts: [String: Int]
    ) {
        self.byCode = byCode
        self.bySeverity = bySeverity
        self.verdicts = verdicts
    }
}

public struct ScholarDiagnosticsJSONReport: Sendable, Codable, Hashable {
    public static let currentSchema = "scholaros.diagnostics/1"

    public let schema: String
    public let mode: String
    public let root: String
    public let files: [DiagnosticsFileRecord]
    public let bibliographySources: [DiagnosticsBibliographySource]
    public let citations: [DiagnosticsCitationEntry]
    public let uncitedEntries: [String]
    public let labels: [DiagnosticsLabelRecord]
    public let references: [DiagnosticsReferenceRecord]
    public let diagnostics: [DiagnosticsItemRecord]
    public let complete: Bool
    public let counts: DiagnosticsCountsSummary

    public init(
        schema: String = ScholarDiagnosticsJSONReport.currentSchema,
        mode: String,
        root: String,
        files: [DiagnosticsFileRecord],
        bibliographySources: [DiagnosticsBibliographySource],
        citations: [DiagnosticsCitationEntry],
        uncitedEntries: [String],
        labels: [DiagnosticsLabelRecord],
        references: [DiagnosticsReferenceRecord],
        diagnostics: [DiagnosticsItemRecord],
        complete: Bool,
        counts: DiagnosticsCountsSummary
    ) {
        self.schema = schema
        self.mode = mode
        self.root = root
        self.files = files
        self.bibliographySources = bibliographySources
        self.citations = citations
        self.uncitedEntries = uncitedEntries
        self.labels = labels
        self.references = references
        self.diagnostics = diagnostics
        self.complete = complete
        self.counts = counts
    }

    public func encodeJSONData(sortedKeys: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if sortedKeys {
            encoder.outputFormatting = [.sortedKeys]
        }
        return try encoder.encode(self)
    }
}
