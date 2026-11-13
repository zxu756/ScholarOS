import Foundation

// MARK: - Editorial JavaScriptCore Plugins & Cambridge Linen Workbench Models

public enum ScholarPluginCapability: String, Sendable, Codable, Hashable, CaseIterable {
    case readManuscriptAST = "manuscript.read"
    case readBibliography = "bibliography.read"
    case emitEditorialFindings = "editorial.emit"
    case suggestProseRewrite = "prose.rewrite"
}

public enum EditorialSeverity: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case note = "NOTE"
    case styleSuggestion = "STYLE"
    case rigorWarning = "RIGOR_WARN"
    case submissionBlocker = "SUBMISSION_BLOCKER"

    private var rank: Int {
        switch self {
        case .note: return 0
        case .styleSuggestion: return 1
        case .rigorWarning: return 2
        case .submissionBlocker: return 3
        }
    }

    public static func < (lhs: EditorialSeverity, rhs: EditorialSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct EditorialAuditFinding: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let pluginID: String
    public let pluginName: String
    public let severity: EditorialSeverity
    public let category: String
    public let filePath: String
    public let line: Int
    public let matchedExcerpt: String
    public let explanation: String
    public let suggestedRewrite: String?

    public init(
        id: UUID = UUID(),
        pluginID: String,
        pluginName: String,
        severity: EditorialSeverity,
        category: String,
        filePath: String = "main.tex",
        line: Int,
        matchedExcerpt: String,
        explanation: String,
        suggestedRewrite: String? = nil
    ) {
        self.id = id
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.severity = severity
        self.category = category
        self.filePath = filePath
        self.line = line
        self.matchedExcerpt = matchedExcerpt
        self.explanation = explanation
        self.suggestedRewrite = suggestedRewrite
    }
}

public struct ScholarPluginManifest: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let summary: String
    public let capabilities: [ScholarPluginCapability]
    public let isBuiltIn: Bool
    public var isEnabled: Bool
    public let scriptSource: String

    public init(
        id: String,
        name: String,
        version: String = "1.0.0",
        summary: String,
        capabilities: [ScholarPluginCapability],
        isBuiltIn: Bool = true,
        isEnabled: Bool = true,
        scriptSource: String
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.capabilities = capabilities
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
        self.scriptSource = scriptSource
    }
}

public enum ScholarUndoMutation: Sendable, Codable, Hashable {
    case editManuscript(filePath: String, previousText: String, updatedText: String)
    case upsertBibliography(previous: BibliographyEntry?, updated: BibliographyEntry?)
    case recordScreeningVote(studyID: String, reviewerSlot: String, previous: ScreeningDecision?, updated: ScreeningDecision?)

    public var inverted: ScholarUndoMutation {
        switch self {
        case .editManuscript(let f, let prev, let next):
            return .editManuscript(filePath: f, previousText: next, updatedText: prev)
        case .upsertBibliography(let prev, let next):
            return .upsertBibliography(previous: next, updated: prev)
        case .recordScreeningVote(let id, let slot, let prev, let next):
            return .recordScreeningVote(studyID: id, reviewerSlot: slot, previous: next, updated: prev)
        }
    }
}

public enum ScholarStudioTab: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case manuscriptEditor = "Manuscript & LSP"
    case pdfProvenance = "PDF Provenance"
    case citationGraph = "Citation Graph"
    case prismaScreening = "PRISMA 2020 Deck"
    case citationFirewall = "Bib & Firewall"
    case editorialAudit = "Editorial Plugins"

    public var id: String { rawValue }

    public var sfSymbolName: String {
        switch self {
        case .manuscriptEditor: return "doc.text.magnifyingglass"
        case .pdfProvenance: return "rectangle.split.2x1"
        case .citationGraph: return "circle.hexagongrid"
        case .prismaScreening: return "checklist.checked"
        case .citationFirewall: return "lock.shield"
        case .editorialAudit: return "Highlighter"
        }
    }
}

public struct ScholarProjectStats: Sendable, Codable, Hashable {
    public let projectTitle: String
    public let primaryManuscriptFile: String
    public let schemaVersion: Int
    public let sqliteBytes: Int64
    public let walBytes: Int64
    public let manuscriptWordCount: Int
    public let bibliographyCount: Int
    public let verifiedCitationCount: Int
    public let blockedCitationCount: Int
    public let indexedPDFPassageCount: Int
    public let prismaStudyCount: Int
    public let cohensKappa: Double
    public let editorialFindingCount: Int
    public let undoDepth: Int
    public let redoDepth: Int

    public init(
        projectTitle: String,
        primaryManuscriptFile: String,
        schemaVersion: Int,
        sqliteBytes: Int64,
        walBytes: Int64,
        manuscriptWordCount: Int,
        bibliographyCount: Int,
        verifiedCitationCount: Int,
        blockedCitationCount: Int,
        indexedPDFPassageCount: Int,
        prismaStudyCount: Int,
        cohensKappa: Double,
        editorialFindingCount: Int,
        undoDepth: Int,
        redoDepth: Int
    ) {
        self.projectTitle = projectTitle
        self.primaryManuscriptFile = primaryManuscriptFile
        self.schemaVersion = schemaVersion
        self.sqliteBytes = sqliteBytes
        self.walBytes = walBytes
        self.manuscriptWordCount = manuscriptWordCount
        self.bibliographyCount = bibliographyCount
        self.verifiedCitationCount = verifiedCitationCount
        self.blockedCitationCount = blockedCitationCount
        self.indexedPDFPassageCount = indexedPDFPassageCount
        self.prismaStudyCount = prismaStudyCount
        self.cohensKappa = cohensKappa
        self.editorialFindingCount = editorialFindingCount
        self.undoDepth = undoDepth
        self.redoDepth = redoDepth
    }
}
