import Foundation
import SQLite3
import ScholarModels

// MARK: - Persistent Store Domain Records

public struct SchemaMigrationRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: Int { version }
    public let version: Int
    public let summary: String
    public let ddlSHA256: String
    public let appliedAt: Date

    public init(version: Int, summary: String, ddlSHA256: String, appliedAt: Date) {
        self.version = version
        self.summary = summary
        self.ddlSHA256 = ddlSHA256
        self.appliedAt = appliedAt
    }
}

public struct ManuscriptFileRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let format: ManuscriptFormat
    public let content: String
    public let wordCount: Int
    public let sha256: String
    public let updatedAt: Date

    public init(
        path: String,
        format: ManuscriptFormat,
        content: String,
        wordCount: Int,
        sha256: String,
        updatedAt: Date
    ) {
        self.path = path
        self.format = format
        self.content = content
        self.wordCount = wordCount
        self.sha256 = sha256
        self.updatedAt = updatedAt
    }
}

public struct ScholarAuditEventRecord: Sendable, Codable, Hashable, Identifiable {
    public let id: Int64
    public let eventUUID: UUID
    public let category: String
    public let action: String
    public let actor: String
    public let targetKey: String?
    public let details: [String: String]
    public let createdAt: Date

    public init(
        id: Int64,
        eventUUID: UUID,
        category: String,
        action: String,
        actor: String,
        targetKey: String?,
        details: [String: String],
        createdAt: Date
    ) {
        self.id = id
        self.eventUUID = eventUUID
        self.category = category
        self.action = action
        self.actor = actor
        self.targetKey = targetKey
        self.details = details
        self.createdAt = createdAt
    }
}

// MARK: - Academic Prose Word Counter

public enum ScholarWordCounter: Sendable {
    private static let nonProseArgumentCommands: Set<String> = [
        "cite", "citep", "citet", "citealt", "citealp", "citeauthor", "citeyear",
        "parencite", "textcite", "autocite", "nocite", "label", "ref", "eqref",
        "pageref", "autoref", "cref", "Cref", "input", "include", "bibliography",
        "bibliographystyle", "usepackage", "documentclass", "newcommand",
        "renewcommand", "DeclareMathOperator", "includegraphics", "vspace", "hspace"
    ]

    public static func countAcademicWords(_ text: String, format: ManuscriptFormat = .latex) -> Int {
        switch format {
        case .latex:
            return countLaTeXWords(text)
        case .typst:
            return countTypstOrMarkdownWords(text, stripSlashComments: true)
        case .markdown:
            return countTypstOrMarkdownWords(text, stripSlashComments: false)
        }
    }

    private static func countLaTeXWords(_ source: String) -> Int {
        var bodySource = source
        if let beginRange = source.range(of: "\\begin{document}") {
            bodySource = String(source[beginRange.upperBound...])
            if let endRange = bodySource.range(of: "\\end{document}") {
                bodySource = String(bodySource[..<endRange.lowerBound])
            }
        }

        let chars = Array(bodySource)
        let length = chars.count
        var idx = 0
        var count = 0

        while idx < length {
            let ch = chars[idx]

            // Strip unescaped % comments up to end-of-line
            if ch == "%" {
                var backslashes = 0
                var scan = idx
                while scan > 0 && chars[scan - 1] == "\\" {
                    backslashes += 1
                    scan -= 1
                }
                if backslashes % 2 == 0 {
                    while idx < length && chars[idx] != "\n" {
                        idx += 1
                    }
                    continue
                }
            }

            // Skip inline and display math regions ($...$ / $$...$$)
            if ch == "$" {
                var backslashes = 0
                var scan = idx
                while scan > 0 && chars[scan - 1] == "\\" {
                    backslashes += 1
                    scan -= 1
                }
                if backslashes % 2 == 0 {
                    let isDisplay = (idx + 1 < length && chars[idx + 1] == "$")
                    idx += isDisplay ? 2 : 1
                    while idx < length {
                        if chars[idx] == "$" {
                            var innerSlashes = 0
                            var s = idx
                            while s > 0 && chars[s - 1] == "\\" {
                                innerSlashes += 1
                                s -= 1
                            }
                            if innerSlashes % 2 == 0 {
                                if isDisplay && idx + 1 < length && chars[idx + 1] == "$" {
                                    idx += 2
                                    break
                                } else if !isDisplay {
                                    idx += 1
                                    break
                                }
                            }
                        }
                        idx += 1
                    }
                    continue
                }
            }

            // Handle LaTeX commands
            if ch == "\\" {
                idx += 1
                guard idx < length else { break }
                if !chars[idx].isLetter {
                    idx += 1
                    continue
                }
                let cmdStart = idx
                while idx < length && (chars[idx].isLetter || chars[idx] == "*") {
                    idx += 1
                }
                let rawCommand = String(chars[cmdStart..<idx]).replacingOccurrences(of: "*", with: "")

                if rawCommand == "begin" || rawCommand == "end" {
                    idx = skipBalancedGroup(in: chars, from: idx, open: "{", close: "}")
                    if rawCommand == "begin" {
                        // Skip equation/align environments if encountered
                        let envName = extractGroupContent(in: chars, beforeIndex: idx)
                        if envName == "equation" || envName == "align" || envName == "eqnarray" || envName == "math" {
                            let closingTag = Array("\\end{\(envName)}")
                            idx = advancePastSubsequence(in: chars, from: idx, needle: closingTag)
                        }
                    }
                    continue
                }

                if nonProseArgumentCommands.contains(rawCommand) {
                    while idx < length && (chars[idx] == " " || chars[idx] == "\t") {
                        idx += 1
                    }
                    while idx < length && chars[idx] == "[" {
                        idx = skipBalancedGroup(in: chars, from: idx, open: "[", close: "]")
                    }
                    while idx < length && chars[idx] == "{" {
                        idx = skipBalancedGroup(in: chars, from: idx, open: "{", close: "}")
                    }
                }
                continue
            }

            if ch.isLetter || ch.isNumber {
                var hasLetterOrDigit = false
                while idx < length {
                    let c = chars[idx]
                    if c.isLetter || c.isNumber {
                        hasLetterOrDigit = true
                        idx += 1
                    } else if (c == "-" || c == "'" || c == "\u{2019}")
                        && idx + 1 < length
                        && (chars[idx + 1].isLetter || chars[idx + 1].isNumber)
                    {
                        idx += 1
                    } else {
                        break
                    }
                }
                if hasLetterOrDigit {
                    count += 1
                }
            } else {
                idx += 1
            }
        }

        return count
    }

    private static func countTypstOrMarkdownWords(_ source: String, stripSlashComments: Bool) -> Int {
        var count = 0
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = Substring(rawLine)
            if stripSlashComments, let commentRange = line.range(of: "//") {
                line = line[..<commentRange.lowerBound]
            }
            for token in line.split(whereSeparator: { $0.isWhitespace }) {
                if token.hasPrefix("#") || token.hasPrefix("@") {
                    continue
                }
                if token.contains(where: { $0.isLetter || $0.isNumber }) {
                    count += 1
                }
            }
        }
        return count
    }

    private static func skipBalancedGroup(
        in chars: [Character],
        from start: Int,
        open: Character,
        close: Character
    ) -> Int {
        var idx = start
        while idx < chars.count && (chars[idx] == " " || chars[idx] == "\t") {
            idx += 1
        }
        guard idx < chars.count && chars[idx] == open else { return start }
        var depth = 0
        while idx < chars.count {
            if chars[idx] == open {
                depth += 1
            } else if chars[idx] == close {
                depth -= 1
                if depth == 0 {
                    return idx + 1
                }
            }
            idx += 1
        }
        return chars.count
    }

    private static func extractGroupContent(in chars: [Character], beforeIndex endIdx: Int) -> String {
        guard endIdx > 2 && endIdx <= chars.count && chars[endIdx - 1] == "}" else { return "" }
        var openIdx = endIdx - 2
        while openIdx >= 0 && chars[openIdx] != "{" {
            openIdx -= 1
        }
        guard openIdx >= 0 && chars[openIdx] == "{" else { return "" }
        return String(chars[(openIdx + 1)..<(endIdx - 1)]).replacingOccurrences(of: "*", with: "")
    }

    private static func advancePastSubsequence(
        in chars: [Character],
        from start: Int,
        needle: [Character]
    ) -> Int {
        guard !needle.isEmpty, start + needle.count <= chars.count else { return start }
        let limit = chars.count - needle.count
        var i = start
        while i <= limit {
            var matched = true
            for j in 0..<needle.count where chars[i + j] != needle[j] {
                matched = false
                break
            }
            if matched {
                return i + needle.count
            }
            i += 1
        }
        return chars.count
    }
}

// MARK: - ScholarProjectDatabase (Schema v1 -> v2 -> v3 -> v4)

public final class ScholarProjectDatabase: @unchecked Sendable {
    public static let latestSchemaVersion: Int = 4

    public let projectRootURL: URL?
    public let sqliteFilePath: String
    public let connection: ScholarSQLiteWALConnection

    private let lock = NSRecursiveLock()

    public convenience init(
        bundleURL: URL,
        configuration: SQLiteConnectionConfiguration = .standard,
        seedDemoIfEmpty: Bool = false
    ) throws {
        try self.init(
            path: bundleURL.path,
            configuration: configuration,
            seedDemoIfEmpty: seedDemoIfEmpty
        )
    }

    public init(
        path: String,
        configuration: SQLiteConnectionConfiguration = .standard,
        seedDemoIfEmpty: Bool = false
    ) throws {
        let resolved = try Self.resolveProjectPaths(from: path)
        self.projectRootURL = resolved.bundleDirectory
        self.sqliteFilePath = resolved.sqlitePath
        self.connection = try ScholarSQLiteWALConnection(
            databasePath: resolved.sqlitePath,
            configuration: configuration
        )

        do {
            try Self.migrate(connection: connection, upTo: Self.latestSchemaVersion)
            if seedDemoIfEmpty {
                let existingFiles = try connection.scalarInt("SELECT COUNT(*) FROM manuscript_files;")
                let existingBib = try connection.scalarInt("SELECT COUNT(*) FROM bibliography_entries;")
                if existingFiles == 0 && existingBib == 0 {
                    try seedDeterministicResearchProject()
                }
            }
        } catch {
            connection.close()
            throw error
        }
    }

    public static func inMemory(seedDemo: Bool = false) throws -> ScholarProjectDatabase {
        try ScholarProjectDatabase(
            path: ":memory:",
            configuration: .standard,
            seedDemoIfEmpty: seedDemo
        )
    }

    public func close() {
        withLock {
            connection.close()
        }
    }

    private static func resolveProjectPaths(from rawPath: String) throws -> (bundleDirectory: URL?, sqlitePath: String) {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == ":memory:" || trimmed.hasPrefix("file::memory:") {
            return (nil, trimmed)
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let ext = url.pathExtension.lowercased()

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if ext == "sqlite" || ext == "sqlite3" || ext == "db" || (exists && !isDir.boolValue) {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            return (parent, url.path)
        }

        // Treat as .scholarproj bundle or project workspace directory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for subdir in ["manuscripts", "pdfs", "exports"] {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(subdir, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let sqliteURL = url.appendingPathComponent("project.sqlite", isDirectory: false)
        return (url, sqliteURL.path)
    }

    // MARK: - Explicit Forward Schema Migrations (v1 -> v2 -> v3 -> v4)

    public func currentSchemaVersion() throws -> Int {
        try withLock {
            try connection.userVersion()
        }
    }

    public func appliedMigrations() throws -> [SchemaMigrationRecord] {
        try withLock {
            guard try connection.tableExists("schema_migrations") else { return [] }
            let rows = try connection.query(
                "SELECT version, summary, ddl_sha256, applied_at FROM schema_migrations ORDER BY version ASC;"
            )
            return try rows.map { row in
                SchemaMigrationRecord(
                    version: try row.int("version"),
                    summary: try row.string("summary"),
                    ddlSHA256: try row.string("ddl_sha256"),
                    appliedAt: try row.date("applied_at")
                )
            }
        }
    }

    public static func migrate(
        connection: ScholarSQLiteWALConnection,
        upTo targetVersion: Int = latestSchemaVersion
    ) throws {
        guard targetVersion >= 1 && targetVersion <= latestSchemaVersion else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_ERROR,
                message: "Unsupported target schema version \(targetVersion); valid range is 1...\(latestSchemaVersion)."
            )
        }

        try connection.executeScript(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                summary TEXT NOT NULL,
                ddl_sha256 TEXT NOT NULL,
                applied_at REAL NOT NULL
            );
            """
        )

        var current = try connection.userVersion()
        if current > latestSchemaVersion {
            throw ScholarOSError.sqliteError(
                code: SQLITE_SCHEMA,
                message: "Project schema version \(current) is newer than supported version \(latestSchemaVersion)."
            )
        }

        while current < targetVersion {
            let nextVersion = current + 1
            let step = migrationStepSQL(forVersion: nextVersion)
            try connection.withTransaction(immediate: true) {
                try connection.executeScript(step.ddl)
                let digest = ScholarCryptoDigest.sha256Hex(step.ddl)
                try connection.execute(
                    """
                    INSERT OR REPLACE INTO schema_migrations (version, summary, ddl_sha256, applied_at)
                    VALUES (?, ?, ?, ?);
                    """,
                    bindings: [nextVersion, step.summary, digest, Date()]
                )
                try connection.setUserVersion(nextVersion)
            }
            current = nextVersion
        }
    }

    private static func migrationStepSQL(forVersion version: Int) -> (summary: String, ddl: String) {
        switch version {
        case 1:
            return (
                summary: "v1: Project metadata, manuscript files, and 5-class Citation Firewall bibliography entries",
                ddl: """
                CREATE TABLE IF NOT EXISTS project_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS manuscript_files (
                    path TEXT PRIMARY KEY,
                    format TEXT NOT NULL,
                    content TEXT NOT NULL,
                    word_count INTEGER NOT NULL DEFAULT 0,
                    sha256 TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_manuscript_files_updated
                    ON manuscript_files(updated_at DESC);

                CREATE TABLE IF NOT EXISTS bibliography_entries (
                    cite_key TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    authors_json TEXT NOT NULL,
                    year INTEGER,
                    venue TEXT NOT NULL DEFAULT '',
                    publisher TEXT,
                    volume TEXT,
                    issue TEXT,
                    pages TEXT,
                    doi TEXT,
                    arxiv_id TEXT,
                    pmid TEXT,
                    url TEXT,
                    abstract_text TEXT,
                    firewall_class TEXT NOT NULL,
                    firewall_note TEXT NOT NULL DEFAULT '',
                    attached_pdf_path TEXT,
                    cited_by_json TEXT NOT NULL DEFAULT '[]',
                    references_json TEXT NOT NULL DEFAULT '[]',
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_bib_firewall_class
                    ON bibliography_entries(firewall_class);
                CREATE INDEX IF NOT EXISTS idx_bib_doi
                    ON bibliography_entries(doi) WHERE doi IS NOT NULL;
                CREATE INDEX IF NOT EXISTS idx_bib_year
                    ON bibliography_entries(year);
                """
            )
        case 2:
            return (
                summary: "v2: PRISMA 2020 PICO protocols, dual-blind screening studies, and manuscript snapshots",
                ddl: """
                CREATE TABLE IF NOT EXISTS prisma_protocols (
                    protocol_id TEXT PRIMARY KEY,
                    review_title TEXT NOT NULL,
                    population TEXT NOT NULL,
                    intervention TEXT NOT NULL,
                    comparator TEXT NOT NULL,
                    outcomes TEXT NOT NULL,
                    inclusion_criteria_json TEXT NOT NULL,
                    exclusion_rules_json TEXT NOT NULL,
                    duplicate_records_removed INTEGER NOT NULL DEFAULT 0,
                    register_records_identified INTEGER NOT NULL DEFAULT 0,
                    reports_not_retrieved INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS screening_studies (
                    id TEXT PRIMARY KEY,
                    cite_key TEXT NOT NULL,
                    title TEXT NOT NULL,
                    authors_line TEXT NOT NULL,
                    year INTEGER NOT NULL,
                    venue TEXT NOT NULL,
                    doi TEXT,
                    abstract_text TEXT NOT NULL,
                    stage TEXT NOT NULL,
                    reviewer_a_json TEXT,
                    reviewer_b_json TEXT,
                    adjudicated_json TEXT,
                    adjudication_rationale TEXT,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_screening_stage
                    ON screening_studies(stage);
                CREATE INDEX IF NOT EXISTS idx_screening_cite_key
                    ON screening_studies(cite_key);

                CREATE TABLE IF NOT EXISTS manuscript_snapshots (
                    id TEXT PRIMARY KEY,
                    label TEXT NOT NULL,
                    author_name TEXT NOT NULL,
                    file_path TEXT NOT NULL,
                    source_content TEXT NOT NULL,
                    word_count INTEGER NOT NULL,
                    sha256 TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_snapshots_file_created
                    ON manuscript_snapshots(file_path, created_at ASC);
                """
            )
        case 3:
            return (
                summary: "v3: PDF passage bounding boxes, BM25 claim provenance links, and Barnes-Hut citation graph cache",
                ddl: """
                CREATE TABLE IF NOT EXISTS pdf_passages (
                    id TEXT PRIMARY KEY,
                    cite_key TEXT NOT NULL,
                    pdf_file_name TEXT NOT NULL,
                    section_title TEXT NOT NULL,
                    column_index INTEGER NOT NULL,
                    reading_sequence INTEGER NOT NULL,
                    page_index INTEGER NOT NULL,
                    bbox_x REAL NOT NULL,
                    bbox_y REAL NOT NULL,
                    bbox_width REAL NOT NULL,
                    bbox_height REAL NOT NULL,
                    passage_text TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_pdf_passages_cite_seq
                    ON pdf_passages(cite_key, reading_sequence ASC);

                CREATE TABLE IF NOT EXISTS claim_provenance_links (
                    id TEXT PRIMARY KEY,
                    manuscript_file TEXT NOT NULL,
                    manuscript_line INTEGER NOT NULL,
                    manuscript_claim TEXT NOT NULL,
                    cite_key TEXT NOT NULL,
                    passage_id TEXT NOT NULL,
                    pdf_excerpt TEXT NOT NULL,
                    page_index INTEGER NOT NULL,
                    bbox_x REAL NOT NULL,
                    bbox_y REAL NOT NULL,
                    bbox_width REAL NOT NULL,
                    bbox_height REAL NOT NULL,
                    bm25_score REAL NOT NULL,
                    verdict TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_provenance_file_line
                    ON claim_provenance_links(manuscript_file, manuscript_line ASC);
                CREATE INDEX IF NOT EXISTS idx_provenance_cite_key
                    ON claim_provenance_links(cite_key);
                CREATE INDEX IF NOT EXISTS idx_provenance_verdict
                    ON claim_provenance_links(verdict);

                CREATE TABLE IF NOT EXISTS citation_graph_cache (
                    entry_id TEXT PRIMARY KEY,
                    entry_kind TEXT NOT NULL CHECK(entry_kind IN ('NODE', 'EDGE')),
                    cite_key TEXT,
                    source_cite_key TEXT,
                    target_cite_key TEXT,
                    edge_kind TEXT,
                    weight REAL NOT NULL DEFAULT 1.0,
                    payload_json TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_citation_graph_kind
                    ON citation_graph_cache(entry_kind);
                """
            )
        case 4:
            return (
                summary: "v4: Editorial audit findings, JavaScriptCore plugin states, crash-safe Undo/Redo journal, and audit events",
                ddl: """
                CREATE TABLE IF NOT EXISTS editorial_findings (
                    id TEXT PRIMARY KEY,
                    plugin_id TEXT NOT NULL,
                    plugin_name TEXT NOT NULL,
                    severity TEXT NOT NULL,
                    category TEXT NOT NULL,
                    file_path TEXT NOT NULL,
                    line INTEGER NOT NULL,
                    matched_excerpt TEXT NOT NULL,
                    explanation TEXT NOT NULL,
                    suggested_rewrite TEXT,
                    created_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_editorial_file_line
                    ON editorial_findings(file_path, line ASC);
                CREATE INDEX IF NOT EXISTS idx_editorial_severity
                    ON editorial_findings(severity);
                CREATE INDEX IF NOT EXISTS idx_editorial_plugin
                    ON editorial_findings(plugin_id);

                CREATE TABLE IF NOT EXISTS plugin_states (
                    plugin_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    version TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    capabilities_json TEXT NOT NULL,
                    is_built_in INTEGER NOT NULL,
                    is_enabled INTEGER NOT NULL,
                    script_source TEXT NOT NULL,
                    config_json TEXT NOT NULL DEFAULT '{}',
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS undo_redo_journal (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    entry_id TEXT NOT NULL UNIQUE,
                    stack_state TEXT NOT NULL CHECK(stack_state IN ('UNDO', 'REDO')),
                    action_title TEXT NOT NULL,
                    mutation_kind TEXT NOT NULL,
                    mutation_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_undo_redo_stack_seq
                    ON undo_redo_journal(stack_state, seq DESC);

                CREATE TABLE IF NOT EXISTS audit_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_uuid TEXT NOT NULL UNIQUE,
                    category TEXT NOT NULL,
                    action TEXT NOT NULL,
                    actor TEXT NOT NULL,
                    target_key TEXT,
                    detail_json TEXT NOT NULL DEFAULT '{}',
                    created_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_audit_category_created
                    ON audit_events(category, created_at DESC);
                """
            )
        default:
            return (summary: "noop", ddl: "SELECT 1;")
        }
    }

    // MARK: - Project Metadata CRUD

    public func getProjectMeta(key: String) throws -> String? {
        try withLock {
            try connection.scalarString(
                "SELECT value FROM project_meta WHERE key = ?;",
                bindings: [key]
            )
        }
    }

    public func setProjectMeta(key: String, value: String, updatedAt: Date = Date()) throws {
        try withLock {
            try connection.execute(
                """
                INSERT INTO project_meta (key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value = excluded.value,
                    updated_at = excluded.updated_at;
                """,
                bindings: [key, value, updatedAt]
            )
        }
    }

    public func allProjectMeta() throws -> [String: String] {
        try withLock {
            let rows = try connection.query("SELECT key, value FROM project_meta ORDER BY key ASC;")
            var dict: [String: String] = [:]
            dict.reserveCapacity(rows.count)
            for row in rows {
                dict[try row.string("key")] = try row.string("value")
            }
            return dict
        }
    }

    public func projectTitle() throws -> String {
        try getProjectMeta(key: "project_title") ?? "Untitled ScholarOS Research Project"
    }

    public func setProjectTitle(_ title: String) throws {
        try setProjectMeta(key: "project_title", value: title)
    }

    public func primaryManuscriptFile() throws -> String {
        if let explicit = try getProjectMeta(key: "primary_manuscript_file"), !explicit.isEmpty {
            return explicit
        }
        if let first = try connection.scalarString("SELECT path FROM manuscript_files ORDER BY path ASC LIMIT 1;") {
            return first
        }
        return "main.tex"
    }

    public func setPrimaryManuscriptFile(_ filePath: String) throws {
        try setProjectMeta(key: "primary_manuscript_file", value: Self.normalizeRelativePath(filePath))
    }

    public func preferredCitationStyle() throws -> CitationFormatStyle {
        guard let raw = try getProjectMeta(key: "citation_style"),
              let style = CitationFormatStyle(rawValue: raw)
        else {
            return .ieee
        }
        return style
    }

    public func setPreferredCitationStyle(_ style: CitationFormatStyle) throws {
        try setProjectMeta(key: "citation_style", value: style.rawValue)
    }

    // MARK: - Manuscript Files CRUD

    @discardableResult
    public func upsertManuscriptFile(
        path: String,
        content: String,
        format: ManuscriptFormat? = nil,
        updatedAt: Date = Date(),
        mirrorToBundleDisk: Bool = true
    ) throws -> ManuscriptFileRecord {
        try withLock {
            let normalizedPath = Self.normalizeRelativePath(path)
            let resolvedFormat = format ?? ManuscriptFormat.detect(fromPath: normalizedPath)
            let wordCount = ScholarWordCounter.countAcademicWords(content, format: resolvedFormat)
            let sha256 = ScholarCryptoDigest.sha256Hex(content)

            try connection.execute(
                """
                INSERT INTO manuscript_files (path, format, content, word_count, sha256, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    format = excluded.format,
                    content = excluded.content,
                    word_count = excluded.word_count,
                    sha256 = excluded.sha256,
                    updated_at = excluded.updated_at;
                """,
                bindings: [normalizedPath, resolvedFormat.rawValue, content, wordCount, sha256, updatedAt]
            )

            if mirrorToBundleDisk, let bundleRoot = projectRootURL {
                let manuscriptsRoot = bundleRoot.appendingPathComponent("manuscripts", isDirectory: true)
                let targetFileURL = manuscriptsRoot.appendingPathComponent(normalizedPath, isDirectory: false)
                let standardizedRoot = manuscriptsRoot.standardizedFileURL.path
                let standardizedTarget = targetFileURL.standardizedFileURL.path
                if standardizedTarget.hasPrefix(standardizedRoot + "/") {
                    try? FileManager.default.createDirectory(
                        at: targetFileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? Data(content.utf8).write(to: targetFileURL, options: .atomic)
                }
            }

            return ManuscriptFileRecord(
                path: normalizedPath,
                format: resolvedFormat,
                content: content,
                wordCount: wordCount,
                sha256: sha256,
                updatedAt: updatedAt
            )
        }
    }

    public func manuscriptFile(path: String) throws -> ManuscriptFileRecord? {
        try withLock {
            let normalized = Self.normalizeRelativePath(path)
            guard let row = try connection.queryOne(
                """
                SELECT path, format, content, word_count, sha256, updated_at
                FROM manuscript_files
                WHERE path = ?;
                """,
                bindings: [normalized]
            ) else {
                return nil
            }
            return try Self.decodeManuscriptRow(row)
        }
    }

    public func manuscriptContent(path: String) throws -> String {
        guard let record = try manuscriptFile(path: path) else {
            throw ScholarOSError.fileNotFound(Self.normalizeRelativePath(path))
        }
        return record.content
    }

    public func listManuscriptFiles() throws -> [ManuscriptFileRecord] {
        try withLock {
            let rows = try connection.query(
                """
                SELECT path, format, content, word_count, sha256, updated_at
                FROM manuscript_files
                ORDER BY CASE WHEN path = 'main.tex' THEN 0 ELSE 1 END, path ASC;
                """
            )
            return try rows.map(Self.decodeManuscriptRow)
        }
    }

    @discardableResult
    public func deleteManuscriptFile(path: String) throws -> Bool {
        try withLock {
            let normalized = Self.normalizeRelativePath(path)
            let deleted = try connection.execute(
                "DELETE FROM manuscript_files WHERE path = ?;",
                bindings: [normalized]
            )
            if let bundleRoot = projectRootURL {
                let diskURL = bundleRoot
                    .appendingPathComponent("manuscripts", isDirectory: true)
                    .appendingPathComponent(normalized, isDirectory: false)
                try? FileManager.default.removeItem(at: diskURL)
            }
            return deleted > 0
        }
    }

    public func totalManuscriptWordCount() throws -> Int {
        try withLock {
            try connection.scalarInt("SELECT COALESCE(SUM(word_count), 0) FROM manuscript_files;")
        }
    }

    private static func decodeManuscriptRow(_ row: SQLiteRow) throws -> ManuscriptFileRecord {
        let path = try row.string("path")
        let formatRaw = try row.string("format")
        let format = ManuscriptFormat(rawValue: formatRaw) ?? ManuscriptFormat.detect(fromPath: path)
        return ManuscriptFileRecord(
            path: path,
            format: format,
            content: try row.string("content"),
            wordCount: try row.int("word_count"),
            sha256: try row.string("sha256"),
            updatedAt: try row.date("updated_at")
        )
    }

    public static func normalizeRelativePath(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while cleaned.hasPrefix("./") {
            cleaned.removeFirst(2)
        }
        while cleaned.hasPrefix("/") {
            cleaned.removeFirst()
        }
        let segments = cleaned
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
        return segments.isEmpty ? "main.tex" : segments.joined(separator: "/")
    }

    // MARK: - Bibliography & 5-Class Citation Firewall CRUD

    public func upsertBibliographyEntry(_ entry: BibliographyEntry, updatedAt: Date = Date()) throws {
        try withLock {
            let authorsJSON = try ScholarSQLiteJSONCodec.encodeString(entry.authors)
            let citedByJSON = try ScholarSQLiteJSONCodec.encodeString(entry.citedByKeys)
            let referencesJSON = try ScholarSQLiteJSONCodec.encodeString(entry.referencesKeys)

            try connection.execute(
                """
                INSERT INTO bibliography_entries (
                    cite_key, kind, title, authors_json, year, venue, publisher,
                    volume, issue, pages, doi, arxiv_id, pmid, url, abstract_text,
                    firewall_class, firewall_note, attached_pdf_path,
                    cited_by_json, references_json, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(cite_key) DO UPDATE SET
                    kind = excluded.kind,
                    title = excluded.title,
                    authors_json = excluded.authors_json,
                    year = excluded.year,
                    venue = excluded.venue,
                    publisher = excluded.publisher,
                    volume = excluded.volume,
                    issue = excluded.issue,
                    pages = excluded.pages,
                    doi = excluded.doi,
                    arxiv_id = excluded.arxiv_id,
                    pmid = excluded.pmid,
                    url = excluded.url,
                    abstract_text = excluded.abstract_text,
                    firewall_class = excluded.firewall_class,
                    firewall_note = excluded.firewall_note,
                    attached_pdf_path = excluded.attached_pdf_path,
                    cited_by_json = excluded.cited_by_json,
                    references_json = excluded.references_json,
                    updated_at = excluded.updated_at;
                """,
                bindings: [
                    entry.citeKey,
                    entry.kind.rawValue,
                    entry.title,
                    authorsJSON,
                    entry.year,
                    entry.venue,
                    entry.publisher,
                    entry.volume,
                    entry.issue,
                    entry.pages,
                    entry.doi,
                    entry.arxivID,
                    entry.pmid,
                    entry.url,
                    entry.abstractText,
                    entry.firewallClass.rawValue,
                    entry.firewallAuditNote,
                    entry.attachedPDFPath,
                    citedByJSON,
                    referencesJSON,
                    updatedAt
                ]
            )
        }
    }

    public func upsertBibliographyEntries(_ entries: [BibliographyEntry], updatedAt: Date = Date()) throws {
        try withLock {
            try connection.withTransaction {
                for entry in entries {
                    try upsertBibliographyEntry(entry, updatedAt: updatedAt)
                }
            }
        }
    }

    public func bibliographyEntry(citeKey: String) throws -> BibliographyEntry? {
        try withLock {
            guard let row = try connection.queryOne(
                "SELECT * FROM bibliography_entries WHERE cite_key = ?;",
                bindings: [citeKey]
            ) else {
                return nil
            }
            return try Self.decodeBibliographyRow(row)
        }
    }

    public func listBibliographyEntries(
        firewallFilter: CitationFirewallClass? = nil,
        searchQuery: String? = nil
    ) throws -> [BibliographyEntry] {
        try withLock {
            var conditions: [String] = []
            var bindings: [any SQLiteBindable] = []

            if let firewallFilter {
                conditions.append("firewall_class = ?")
                bindings.append(firewallFilter.rawValue)
            }

            if let queryText = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
               !queryText.isEmpty
            {
                let pattern = "%\(queryText)%"
                conditions.append(
                    "(cite_key LIKE ? OR title LIKE ? OR authors_json LIKE ? OR venue LIKE ? OR COALESCE(doi, '') LIKE ?)"
                )
                bindings.append(contentsOf: [pattern, pattern, pattern, pattern, pattern])
            }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let rows = try connection.query(
                "SELECT * FROM bibliography_entries \(whereClause) ORDER BY cite_key ASC;",
                bindings: bindings
            )
            return try rows.map(Self.decodeBibliographyRow)
        }
    }

    @discardableResult
    public func deleteBibliographyEntry(citeKey: String) throws -> Bool {
        try withLock {
            let changes = try connection.execute(
                "DELETE FROM bibliography_entries WHERE cite_key = ?;",
                bindings: [citeKey]
            )
            return changes > 0
        }
    }

    public func updateCitationFirewallStatus(
        citeKey: String,
        firewallClass: CitationFirewallClass,
        auditNote: String,
        updatedAt: Date = Date()
    ) throws {
        try withLock {
            let changes = try connection.execute(
                """
                UPDATE bibliography_entries
                SET firewall_class = ?, firewall_note = ?, updated_at = ?
                WHERE cite_key = ?;
                """,
                bindings: [firewallClass.rawValue, auditNote, updatedAt, citeKey]
            )
            guard changes > 0 else {
                throw ScholarOSError.fileNotFound("Bibliography entry '\(citeKey)'")
            }
        }
    }

    /// Hardware-gated Citation Firewall verification: blocks unverified or hallucinated citeKeys.
    @discardableResult
    public func validateCitationKeyForInsertion(_ citeKey: String) throws -> BibliographyEntry {
        try withLock {
            guard let entry = try bibliographyEntry(citeKey: citeKey) else {
                throw ScholarOSError.unverifiedCitationBlocked(
                    citeKey: citeKey,
                    statusCode: "MISSING_BIB_ENTRY",
                    reason: "Cite key '\(citeKey)' is absent from the verified project bibliography."
                )
            }
            guard entry.firewallClass.allowsManuscriptInsertion else {
                throw ScholarOSError.unverifiedCitationBlocked(
                    citeKey: entry.citeKey,
                    statusCode: entry.firewallClass.rawValue,
                    reason: entry.firewallAuditNote.isEmpty
                        ? "Blocked by 5-class Citation Verification Firewall (\(entry.firewallClass.badgeTitle))."
                        : entry.firewallAuditNote
                )
            }
            return entry
        }
    }

    public func detectDuplicateBibliographyCandidates(
        similarityThreshold: Double = 0.90
    ) throws -> [DuplicateReferenceCandidate] {
        let entries = try listBibliographyEntries()
        guard entries.count > 1 else { return [] }

        var duplicates: [DuplicateReferenceCandidate] = []
        for i in 0..<(entries.count - 1) {
            for j in (i + 1)..<entries.count {
                let lhs = entries[i]
                let rhs = entries[j]
                let exactDOI: Bool
                if let d1 = lhs.doi?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                   let d2 = rhs.doi?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                   !d1.isEmpty, d1 == d2
                {
                    exactDOI = true
                } else {
                    exactDOI = false
                }

                let jw = Self.jaroWinklerSimilarity(
                    lhs.title.lowercased(),
                    rhs.title.lowercased()
                )
                if exactDOI || jw >= similarityThreshold {
                    let reason = exactDOI
                        ? "Identical normalized DOI (\(lhs.doi ?? ""))"
                        : String(format: "High normalized title Jaro-Winkler similarity (%.3f)", jw)
                    duplicates.append(
                        DuplicateReferenceCandidate(
                            primaryCiteKey: lhs.citeKey,
                            duplicateCiteKey: rhs.citeKey,
                            titleJaroWinkler: jw,
                            exactDOIMatch: exactDOI,
                            reason: reason
                        )
                    )
                }
            }
        }
        return duplicates
    }

    private static func decodeBibliographyRow(_ row: SQLiteRow) throws -> BibliographyEntry {
        let kindRaw = try row.string("kind")
        let kind = BibEntryKind(rawValue: kindRaw) ?? .article
        let firewallRaw = try row.string("firewall_class")
        let firewall = CitationFirewallClass(rawValue: firewallRaw) ?? .unverifiedPendingCheck
        let authors = try row.jsonDecode([BibAuthor].self, column: "authors_json")
        let citedBy = try row.jsonDecode([String].self, column: "cited_by_json")
        let refs = try row.jsonDecode([String].self, column: "references_json")

        return BibliographyEntry(
            citeKey: try row.string("cite_key"),
            kind: kind,
            title: try row.string("title"),
            authors: authors,
            year: row.optionalInt("year"),
            venue: row.optionalString("venue") ?? "",
            publisher: row.optionalString("publisher"),
            volume: row.optionalString("volume"),
            issue: row.optionalString("issue"),
            pages: row.optionalString("pages"),
            doi: row.optionalString("doi"),
            arxivID: row.optionalString("arxiv_id"),
            pmid: row.optionalString("pmid"),
            url: row.optionalString("url"),
            abstractText: row.optionalString("abstract_text"),
            firewallClass: firewall,
            firewallAuditNote: row.optionalString("firewall_note") ?? "",
            attachedPDFPath: row.optionalString("attached_pdf_path"),
            citedByKeys: citedBy,
            referencesKeys: refs
        )
    }

    private static func jaroWinklerSimilarity(_ s1: String, _ s2: String) -> Double {
        let a = Array(s1)
        let b = Array(s2)
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }

        let matchDistance = max(0, max(a.count, b.count) / 2 - 1)
        var aMatches = Array(repeating: false, count: a.count)
        var bMatches = Array(repeating: false, count: b.count)

        var matches = 0
        for i in 0..<a.count {
            let start = max(0, i - matchDistance)
            let end = min(i + matchDistance + 1, b.count)
            guard start < end else { continue }
            for j in start..<end where !bMatches[j] && a[i] == b[j] {
                aMatches[i] = true
                bMatches[j] = true
                matches += 1
                break
            }
        }
        if matches == 0 { return 0.0 }

        var transpositions = 0
        var k = 0
        for i in 0..<a.count where aMatches[i] {
            while k < b.count && !bMatches[k] {
                k += 1
            }
            if k < b.count && a[i] != b[k] {
                transpositions += 1
            }
            k += 1
        }

        let m = Double(matches)
        let jaro = (m / Double(a.count) + m / Double(b.count) + (m - Double(transpositions) / 2.0) / m) / 3.0
        var prefix = 0
        let maxPrefix = min(4, min(a.count, b.count))
        while prefix < maxPrefix && a[prefix] == b[prefix] {
            prefix += 1
        }
        return jaro + Double(prefix) * 0.1 * (1.0 - jaro)
    }

    // MARK: - PRISMA 2020 Protocol & Dual-Blind Screening Studies CRUD

    public func savePRISMAProtocol(
        _ protocolSpec: PICOProtocolSpec,
        protocolID: String = "default",
        duplicateRecordsRemoved: Int = 14,
        registerRecordsIdentified: Int = 3,
        reportsNotRetrieved: Int = 1,
        updatedAt: Date = Date()
    ) throws {
        try withLock {
            let inclusionJSON = try ScholarSQLiteJSONCodec.encodeString(protocolSpec.inclusionCriteria)
            let exclusionJSON = try ScholarSQLiteJSONCodec.encodeString(
                protocolSpec.exclusionRules.sorted { $0.priorityOrder < $1.priorityOrder }
            )
            try connection.execute(
                """
                INSERT INTO prisma_protocols (
                    protocol_id, review_title, population, intervention, comparator, outcomes,
                    inclusion_criteria_json, exclusion_rules_json,
                    duplicate_records_removed, register_records_identified, reports_not_retrieved,
                    updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(protocol_id) DO UPDATE SET
                    review_title = excluded.review_title,
                    population = excluded.population,
                    intervention = excluded.intervention,
                    comparator = excluded.comparator,
                    outcomes = excluded.outcomes,
                    inclusion_criteria_json = excluded.inclusion_criteria_json,
                    exclusion_rules_json = excluded.exclusion_rules_json,
                    duplicate_records_removed = excluded.duplicate_records_removed,
                    register_records_identified = excluded.register_records_identified,
                    reports_not_retrieved = excluded.reports_not_retrieved,
                    updated_at = excluded.updated_at;
                """,
                bindings: [
                    protocolID,
                    protocolSpec.reviewTitle,
                    protocolSpec.population,
                    protocolSpec.intervention,
                    protocolSpec.comparator,
                    protocolSpec.outcomes,
                    inclusionJSON,
                    exclusionJSON,
                    max(0, duplicateRecordsRemoved),
                    max(0, registerRecordsIdentified),
                    max(0, reportsNotRetrieved),
                    updatedAt
                ]
            )
        }
    }

    public func loadPRISMAProtocol(protocolID: String = "default") throws -> PICOProtocolSpec? {
        try withLock {
            guard let row = try connection.queryOne(
                "SELECT * FROM prisma_protocols WHERE protocol_id = ?;",
                bindings: [protocolID]
            ) else {
                return nil
            }
            let inclusion = try row.jsonDecode([String].self, column: "inclusion_criteria_json")
            let exclusion = try row.jsonDecode([ExclusionReasonRule].self, column: "exclusion_rules_json")
            return PICOProtocolSpec(
                reviewTitle: try row.string("review_title"),
                population: try row.string("population"),
                intervention: try row.string("intervention"),
                comparator: try row.string("comparator"),
                outcomes: try row.string("outcomes"),
                inclusionCriteria: inclusion,
                exclusionRules: exclusion
            )
        }
    }

    public func upsertScreeningStudy(_ study: ScreeningStudyRecord, updatedAt: Date = Date()) throws {
        try withLock {
            let revA = try study.reviewerADecision.map { try ScholarSQLiteJSONCodec.encodeString($0) }
            let revB = try study.reviewerBDecision.map { try ScholarSQLiteJSONCodec.encodeString($0) }
            let adj = try study.adjudicatedDecision.map { try ScholarSQLiteJSONCodec.encodeString($0) }

            try connection.execute(
                """
                INSERT INTO screening_studies (
                    id, cite_key, title, authors_line, year, venue, doi, abstract_text,
                    stage, reviewer_a_json, reviewer_b_json, adjudicated_json,
                    adjudication_rationale, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    cite_key = excluded.cite_key,
                    title = excluded.title,
                    authors_line = excluded.authors_line,
                    year = excluded.year,
                    venue = excluded.venue,
                    doi = excluded.doi,
                    abstract_text = excluded.abstract_text,
                    stage = excluded.stage,
                    reviewer_a_json = excluded.reviewer_a_json,
                    reviewer_b_json = excluded.reviewer_b_json,
                    adjudicated_json = excluded.adjudicated_json,
                    adjudication_rationale = excluded.adjudication_rationale,
                    updated_at = excluded.updated_at;
                """,
                bindings: [
                    study.id,
                    study.citeKey,
                    study.title,
                    study.authorsLine,
                    study.year,
                    study.venue,
                    study.doi,
                    study.abstractText,
                    study.stage.rawValue,
                    revA,
                    revB,
                    adj,
                    study.adjudicationRationale,
                    updatedAt
                ]
            )
        }
    }

    public func upsertScreeningStudies(_ studies: [ScreeningStudyRecord], updatedAt: Date = Date()) throws {
        try withLock {
            try connection.withTransaction {
                for study in studies {
                    try upsertScreeningStudy(study, updatedAt: updatedAt)
                }
            }
        }
    }

    public func screeningStudy(id: String) throws -> ScreeningStudyRecord? {
        try withLock {
            guard let row = try connection.queryOne(
                "SELECT * FROM screening_studies WHERE id = ?;",
                bindings: [id]
            ) else {
                return nil
            }
            return try Self.decodeScreeningStudyRow(row)
        }
    }

    public func listScreeningStudies(
        stage: ScreeningStage? = nil,
        conflictsOnly: Bool = false
    ) throws -> [ScreeningStudyRecord] {
        try withLock {
            let rows: [SQLiteRow]
            if let stage {
                rows = try connection.query(
                    "SELECT * FROM screening_studies WHERE stage = ? ORDER BY id ASC;",
                    bindings: [stage.rawValue]
                )
            } else {
                rows = try connection.query("SELECT * FROM screening_studies ORDER BY id ASC;")
            }
            let decoded = try rows.map(Self.decodeScreeningStudyRow)
            if conflictsOnly {
                return decoded.filter(\.hasReviewerConflict)
            }
            return decoded
        }
    }

    @discardableResult
    public func recordScreeningDecision(
        studyID: String,
        reviewerSlot: String,
        decision: ScreeningDecision?,
        rationale: String? = nil,
        updatedAt: Date = Date()
    ) throws -> ScreeningStudyRecord {
        try withLock {
            guard var study = try screeningStudy(id: studyID) else {
                throw ScholarOSError.prismaProtocolViolation(
                    "Screening study '\(studyID)' does not exist in screening_studies."
                )
            }

            if case .exclude(let reasonCode) = decision {
                if reasonCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ScholarOSError.prismaProtocolViolation(
                        "PRISMA 2020 exclusion decision requires a non-empty ordered reasonCode."
                    )
                }
                if let spec = try loadPRISMAProtocol(), !spec.exclusionRules.isEmpty {
                    let validCodes = Set(spec.exclusionRules.map(\.code))
                    if !validCodes.contains(reasonCode) {
                        throw ScholarOSError.prismaProtocolViolation(
                            "Exclusion code '\(reasonCode)' is not registered in active PICO protocol [\(validCodes.sorted().joined(separator: ", "))]."
                        )
                    }
                }
            }

            let normalizedSlot = reviewerSlot.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalizedSlot {
            case "a", "reviewera", "reviewer_a":
                study.reviewerADecision = decision
            case "b", "reviewerb", "reviewer_b":
                study.reviewerBDecision = decision
            case "adjudicated", "adjudicator", "adjudicate", "c", "third":
                study.adjudicatedDecision = decision
                if let rationale {
                    study.adjudicationRationale = rationale
                }
            default:
                throw ScholarOSError.prismaProtocolViolation(
                    "Unknown reviewer slot '\(reviewerSlot)'. Expected 'A', 'B', or 'adjudicated'."
                )
            }

            try upsertScreeningStudy(study, updatedAt: updatedAt)
            return study
        }
    }

    @discardableResult
    public func deleteScreeningStudy(id: String) throws -> Bool {
        try withLock {
            try connection.execute("DELETE FROM screening_studies WHERE id = ?;", bindings: [id]) > 0
        }
    }

    public func computeInterRaterAgreement(
        studies: [ScreeningStudyRecord]? = nil
    ) throws -> (observedAgreement: Double, cohensKappa: Double, pabak: Double) {
        let allStudies = try (studies ?? listScreeningStudies())
        let dualCoded = allStudies.compactMap { study -> (ScreeningDecision, ScreeningDecision)? in
            guard let a = study.reviewerADecision, let b = study.reviewerBDecision else {
                return nil
            }
            return (a, b)
        }

        let n = dualCoded.count
        guard n > 0 else {
            return (observedAgreement: 1.0, cohensKappa: 1.0, pabak: 1.0)
        }

        var agreements = 0
        var countsA: [ScreeningDecision: Int] = [:]
        var countsB: [ScreeningDecision: Int] = [:]
        var categories = Set<ScreeningDecision>()

        for (voteA, voteB) in dualCoded {
            if voteA == voteB {
                agreements += 1
            }
            countsA[voteA, default: 0] += 1
            countsB[voteB, default: 0] += 1
            categories.insert(voteA)
            categories.insert(voteB)
        }

        let nDouble = Double(n)
        let po = Double(agreements) / nDouble
        var peNumerator = 0.0
        for category in categories {
            let aFreq = Double(countsA[category] ?? 0)
            let bFreq = Double(countsB[category] ?? 0)
            peNumerator += aFreq * bFreq
        }
        let pe = peNumerator / (nDouble * nDouble)
        let kappa: Double
        if abs(1.0 - pe) < 1e-12 {
            kappa = 1.0
        } else {
            kappa = (po - pe) / (1.0 - pe)
        }
        let pabak = 2.0 * po - 1.0
        return (observedAgreement: po, cohensKappa: kappa, pabak: pabak)
    }

    public func computePRISMAMetrics(protocolID: String = "default") throws -> PRISMA2020SummaryMetrics {
        try withLock {
            let studies = try listScreeningStudies()
            let agreement = try computeInterRaterAgreement(studies: studies)

            let metaRow = try connection.queryOne(
                """
                SELECT duplicate_records_removed, register_records_identified, reports_not_retrieved
                FROM prisma_protocols
                WHERE protocol_id = ?;
                """,
                bindings: [protocolID]
            )
            let duplicatesRemoved = metaRow?.optionalInt("duplicate_records_removed") ?? 0
            let registerRecords = metaRow?.optionalInt("register_records_identified") ?? 0
            let notRetrieved = metaRow?.optionalInt("reports_not_retrieved") ?? 0

            let totalScreened = studies.count
            let dbIdentified = max(totalScreened, totalScreened + duplicatesRemoved - registerRecords)

            var excludedTA = 0
            var fullTextAssessed = 0
            var fullTextExcludedByReason: [String: Int] = [:]
            var finalIncluded = 0

            for study in studies {
                let effectiveDecision = Self.effectiveScreeningDecision(for: study)
                switch study.stage {
                case .titleAbstract:
                    if case .exclude = effectiveDecision {
                        excludedTA += 1
                    }
                case .fullText:
                    fullTextAssessed += 1
                    switch effectiveDecision {
                    case .include:
                        finalIncluded += 1
                    case .exclude(let code):
                        fullTextExcludedByReason[code, default: 0] += 1
                    case .maybe, .none:
                        break
                    }
                }
            }

            let soughtForRetrieval = fullTextAssessed + notRetrieved

            return PRISMA2020SummaryMetrics(
                databaseRecordsIdentified: dbIdentified,
                registerRecordsIdentified: registerRecords,
                duplicateRecordsRemoved: duplicatesRemoved,
                recordsScreenedTitleAbstract: totalScreened,
                recordsExcludedTitleAbstract: excludedTA,
                reportsSoughtForRetrieval: soughtForRetrieval,
                reportsNotRetrieved: notRetrieved,
                fullTextAssessed: fullTextAssessed,
                fullTextExcludedByReason: fullTextExcludedByReason,
                finalIncludedStudies: finalIncluded,
                observedAgreementRate: agreement.observedAgreement,
                cohensKappa: agreement.cohensKappa,
                pabakScore: agreement.pabak
            )
        }
    }

    private static func effectiveScreeningDecision(for study: ScreeningStudyRecord) -> ScreeningDecision? {
        if let adjudicated = study.adjudicatedDecision {
            return adjudicated
        }
        if let a = study.reviewerADecision, let b = study.reviewerBDecision, a == b {
            return a
        }
        return nil
    }

    private static func decodeScreeningStudyRow(_ row: SQLiteRow) throws -> ScreeningStudyRecord {
        let stageRaw = try row.string("stage")
        let stage = ScreeningStage(rawValue: stageRaw) ?? .titleAbstract
        let revA = try row.optionalJSONDecode(ScreeningDecision.self, column: "reviewer_a_json")
        let revB = try row.optionalJSONDecode(ScreeningDecision.self, column: "reviewer_b_json")
        let adjudicated = try row.optionalJSONDecode(ScreeningDecision.self, column: "adjudicated_json")

        return ScreeningStudyRecord(
            id: try row.string("id"),
            citeKey: try row.string("cite_key"),
            title: try row.string("title"),
            authorsLine: try row.string("authors_line"),
            year: try row.int("year"),
            venue: try row.string("venue"),
            doi: row.optionalString("doi"),
            abstractText: try row.string("abstract_text"),
            stage: stage,
            reviewerADecision: revA,
            reviewerBDecision: revB,
            adjudicatedDecision: adjudicated,
            adjudicationRationale: row.optionalString("adjudication_rationale")
        )
    }

    // MARK: - Manuscript Snapshots CRUD

    @discardableResult
    public func createSnapshot(
        id: UUID = UUID(),
        label: String,
        authorName: String = "Lead Author",
        filePath: String,
        sourceContent: String? = nil,
        createdAt: Date = Date()
    ) throws -> ManuscriptSnapshot {
        try withLock {
            let normalizedPath = Self.normalizeRelativePath(filePath)
            let resolvedContent: String
            if let sourceContent {
                resolvedContent = sourceContent
            } else {
                resolvedContent = try manuscriptContent(path: normalizedPath)
            }
            let fmt = ManuscriptFormat.detect(fromPath: normalizedPath)
            let words = ScholarWordCounter.countAcademicWords(resolvedContent, format: fmt)
            let snapshot = ManuscriptSnapshot(
                id: id,
                label: label,
                authorName: authorName,
                filePath: normalizedPath,
                sourceContent: resolvedContent,
                wordCount: words,
                createdAt: createdAt
            )
            try upsertSnapshot(snapshot)
            return snapshot
        }
    }

    public func upsertSnapshot(_ snapshot: ManuscriptSnapshot) throws {
        try withLock {
            let normalizedPath = Self.normalizeRelativePath(snapshot.filePath)
            let sha256 = ScholarCryptoDigest.sha256Hex(snapshot.sourceContent)
            try connection.execute(
                """
                INSERT INTO manuscript_snapshots (
                    id, label, author_name, file_path, source_content, word_count, sha256, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    label = excluded.label,
                    author_name = excluded.author_name,
                    file_path = excluded.file_path,
                    source_content = excluded.source_content,
                    word_count = excluded.word_count,
                    sha256 = excluded.sha256,
                    created_at = excluded.created_at;
                """,
                bindings: [
                    snapshot.id,
                    snapshot.label,
                    snapshot.authorName,
                    normalizedPath,
                    snapshot.sourceContent,
                    snapshot.wordCount,
                    sha256,
                    snapshot.createdAt
                ]
            )
        }
    }

    public func snapshot(id: UUID) throws -> ManuscriptSnapshot? {
        try withLock {
            guard let row = try connection.queryOne(
                "SELECT * FROM manuscript_snapshots WHERE id = ?;",
                bindings: [id]
            ) else {
                return nil
            }
            return try Self.decodeSnapshotRow(row)
        }
    }

    public func listSnapshots(filePath: String? = nil) throws -> [ManuscriptSnapshot] {
        try withLock {
            let rows: [SQLiteRow]
            if let filePath {
                rows = try connection.query(
                    "SELECT * FROM manuscript_snapshots WHERE file_path = ? ORDER BY created_at ASC, id ASC;",
                    bindings: [Self.normalizeRelativePath(filePath)]
                )
            } else {
                rows = try connection.query(
                    "SELECT * FROM manuscript_snapshots ORDER BY created_at ASC, id ASC;"
                )
            }
            return try rows.map(Self.decodeSnapshotRow)
        }
    }

    @discardableResult
    public func deleteSnapshot(id: UUID) throws -> Bool {
        try withLock {
            try connection.execute("DELETE FROM manuscript_snapshots WHERE id = ?;", bindings: [id]) > 0
        }
    }

    @discardableResult
    public func restoreSnapshot(id: UUID) throws -> ManuscriptFileRecord {
        try withLock {
            guard let snap = try snapshot(id: id) else {
                throw ScholarOSError.fileNotFound("Snapshot \(id.uuidString)")
            }
            return try upsertManuscriptFile(path: snap.filePath, content: snap.sourceContent)
        }
    }

    private static func decodeSnapshotRow(_ row: SQLiteRow) throws -> ManuscriptSnapshot {
        ManuscriptSnapshot(
            id: try row.uuid("id"),
            label: try row.string("label"),
            authorName: try row.string("author_name"),
            filePath: try row.string("file_path"),
            sourceContent: try row.string("source_content"),
            wordCount: try row.int("word_count"),
            createdAt: try row.date("created_at")
        )
    }

    // MARK: - PDF Passages & Claim Provenance Links CRUD

    public func upsertPDFPassage(_ passage: PDFPassageChunk) throws {
        try withLock {
            try connection.execute(
                """
                INSERT INTO pdf_passages (
                    id, cite_key, pdf_file_name, section_title, column_index, reading_sequence,
                    page_index, bbox_x, bbox_y, bbox_width, bbox_height, passage_text
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    cite_key = excluded.cite_key,
                    pdf_file_name = excluded.pdf_file_name,
                    section_title = excluded.section_title,
                    column_index = excluded.column_index,
                    reading_sequence = excluded.reading_sequence,
                    page_index = excluded.page_index,
                    bbox_x = excluded.bbox_x,
                    bbox_y = excluded.bbox_y,
                    bbox_width = excluded.bbox_width,
                    bbox_height = excluded.bbox_height,
                    passage_text = excluded.passage_text;
                """,
                bindings: [
                    passage.id,
                    passage.citeKey,
                    passage.pdfFileName,
                    passage.sectionTitle,
                    passage.columnIndex,
                    passage.readingSequence,
                    passage.boundingBox.pageIndex,
                    passage.boundingBox.x,
                    passage.boundingBox.y,
                    passage.boundingBox.width,
                    passage.boundingBox.height,
                    passage.passageText
                ]
            )
        }
    }

    public func upsertPDFPassages(_ passages: [PDFPassageChunk]) throws {
        try withLock {
            try connection.withTransaction {
                for passage in passages {
                    try upsertPDFPassage(passage)
                }
            }
        }
    }

    public func pdfPassage(id: String) throws -> PDFPassageChunk? {
        try withLock {
            guard let row = try connection.queryOne(
                "SELECT * FROM pdf_passages WHERE id = ?;",
                bindings: [id]
            ) else {
                return nil
            }
            return try Self.decodePDFPassageRow(row)
        }
    }

    public func listPDFPassages(citeKey: String? = nil) throws -> [PDFPassageChunk] {
        try withLock {
            let rows: [SQLiteRow]
            if let citeKey {
                rows = try connection.query(
                    "SELECT * FROM pdf_passages WHERE cite_key = ? ORDER BY reading_sequence ASC, id ASC;",
                    bindings: [citeKey]
                )
            } else {
                rows = try connection.query(
                    "SELECT * FROM pdf_passages ORDER BY cite_key ASC, reading_sequence ASC, id ASC;"
                )
            }
            return try rows.map(Self.decodePDFPassageRow)
        }
    }

    @discardableResult
    public func deletePDFPassages(citeKey: String) throws -> Int {
        try withLock {
            try connection.execute("DELETE FROM pdf_passages WHERE cite_key = ?;", bindings: [citeKey])
        }
    }

    public func upsertClaimProvenance(_ link: ClaimEvidenceProvenance) throws {
        try withLock {
            try connection.execute(
                """
                INSERT INTO claim_provenance_links (
                    id, manuscript_file, manuscript_line, manuscript_claim, cite_key, passage_id,
                    pdf_excerpt, page_index, bbox_x, bbox_y, bbox_width, bbox_height,
                    bm25_score, verdict
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    manuscript_file = excluded.manuscript_file,
                    manuscript_line = excluded.manuscript_line,
                    manuscript_claim = excluded.manuscript_claim,
                    cite_key = excluded.cite_key,
                    passage_id = excluded.passage_id,
                    pdf_excerpt = excluded.pdf_excerpt,
                    page_index = excluded.page_index,
                    bbox_x = excluded.bbox_x,
                    bbox_y = excluded.bbox_y,
                    bbox_width = excluded.bbox_width,
                    bbox_height = excluded.bbox_height,
                    bm25_score = excluded.bm25_score,
                    verdict = excluded.verdict;
                """,
                bindings: [
                    link.id,
                    Self.normalizeRelativePath(link.manuscriptFile),
                    link.manuscriptLine,
                    link.manuscriptClaim,
                    link.citeKey,
                    link.passageID,
                    link.pdfExcerpt,
                    link.boundingBox.pageIndex,
                    link.boundingBox.x,
                    link.boundingBox.y,
                    link.boundingBox.width,
                    link.boundingBox.height,
                    link.bm25Score,
                    link.verdict.rawValue
                ]
            )
        }
    }

    public func upsertClaimProvenanceLinks(_ links: [ClaimEvidenceProvenance]) throws {
        try withLock {
            try connection.withTransaction {
                for link in links {
                    try upsertClaimProvenance(link)
                }
            }
        }
    }

    public func claimProvenance(id: UUID) throws -> ClaimEvidenceProvenance? {
        try withLock {
            guard let row = try connection.queryOne(
                "SELECT * FROM claim_provenance_links WHERE id = ?;",
                bindings: [id]
            ) else {
                return nil
            }
            return try Self.decodeClaimProvenanceRow(row)
        }
    }

    public func listClaimProvenanceLinks(
        manuscriptFile: String? = nil,
        citeKey: String? = nil,
        verdict: EvidenceSupportVerdict? = nil
    ) throws -> [ClaimEvidenceProvenance] {
        try withLock {
            var clauses: [String] = []
            var bindings: [any SQLiteBindable] = []

            if let manuscriptFile {
                clauses.append("manuscript_file = ?")
                bindings.append(Self.normalizeRelativePath(manuscriptFile))
            }
            if let citeKey {
                clauses.append("cite_key = ?")
                bindings.append(citeKey)
            }
            if let verdict {
                clauses.append("verdict = ?")
                bindings.append(verdict.rawValue)
            }

            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let rows = try connection.query(
                """
                SELECT * FROM claim_provenance_links
                \(whereSQL)
                ORDER BY manuscript_file ASC, manuscript_line ASC, bm25_score DESC;
                """,
                bindings: bindings
            )
            return try rows.map(Self.decodeClaimProvenanceRow)
        }
    }

    @discardableResult
    public func deleteClaimProvenance(id: UUID) throws -> Bool {
        try withLock {
            try connection.execute("DELETE FROM claim_provenance_links WHERE id = ?;", bindings: [id]) > 0
        }
    }

    private static func decodePDFPassageRow(_ row: SQLiteRow) throws -> PDFPassageChunk {
        PDFPassageChunk(
            id: try row.string("id"),
            citeKey: try row.string("cite_key"),
            pdfFileName: try row.string("pdf_file_name"),
            sectionTitle: try row.string("section_title"),
            columnIndex: try row.int("column_index"),
            readingSequence: try row.int("reading_sequence"),
            boundingBox: PDFPageRegionBox(
                pageIndex: try row.int("page_index"),
                x: try row.double("bbox_x"),
                y: try row.double("bbox_y"),
                width: try row.double("bbox_width"),
                height: try row.double("bbox_height")
            ),
            passageText: try row.string("passage_text")
        )
    }

    private static func decodeClaimProvenanceRow(_ row: SQLiteRow) throws -> ClaimEvidenceProvenance {
        let verdictRaw = try row.string("verdict")
        let verdict = EvidenceSupportVerdict(rawValue: verdictRaw) ?? .groundedEntailment
        return ClaimEvidenceProvenance(
            id: try row.uuid("id"),
            manuscriptFile: try row.string("manuscript_file"),
            manuscriptLine: try row.int("manuscript_line"),
            manuscriptClaim: try row.string("manuscript_claim"),
            citeKey: try row.string("cite_key"),
            passageID: try row.string("passage_id"),
            pdfExcerpt: try row.string("pdf_excerpt"),
            boundingBox: PDFPageRegionBox(
                pageIndex: try row.int("page_index"),
                x: try row.double("bbox_x"),
                y: try row.double("bbox_y"),
                width: try row.double("bbox_width"),
                height: try row.double("bbox_height")
            ),
            bm25Score: try row.double("bm25_score"),
            verdict: verdict
        )
    }

    // MARK: - Citation Graph Cache CRUD

    public func upsertCitationGraphNode(_ node: CitationGraphNode, updatedAt: Date = Date()) throws {
        try withLock {
            let payload = try ScholarSQLiteJSONCodec.encodeString(node)
            try connection.execute(
                """
                INSERT INTO citation_graph_cache (
                    entry_id, entry_kind, cite_key, source_cite_key, target_cite_key,
                    edge_kind, weight, payload_json, updated_at
                ) VALUES (?, 'NODE', ?, NULL, NULL, NULL, ?, ?, ?)
                ON CONFLICT(entry_id) DO UPDATE SET
                    cite_key = excluded.cite_key,
                    weight = excluded.weight,
                    payload_json = excluded.payload_json,
                    updated_at = excluded.updated_at;
                """,
                bindings: ["node:\(node.citeKey)", node.citeKey, node.pageRank, payload, updatedAt]
            )
        }
    }

    public func upsertCitationGraphEdge(_ edge: CitationGraphEdge, updatedAt: Date = Date()) throws {
        try withLock {
            let payload = try ScholarSQLiteJSONCodec.encodeString(edge)
            try connection.execute(
                """
                INSERT INTO citation_graph_cache (
                    entry_id, entry_kind, cite_key, source_cite_key, target_cite_key,
                    edge_kind, weight, payload_json, updated_at
                ) VALUES (?, 'EDGE', NULL, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(entry_id) DO UPDATE SET
                    source_cite_key = excluded.source_cite_key,
                    target_cite_key = excluded.target_cite_key,
                    edge_kind = excluded.edge_kind,
                    weight = excluded.weight,
                    payload_json = excluded.payload_json,
                    updated_at = excluded.updated_at;
                """,
                bindings: [
                    "edge:\(edge.id)",
                    edge.sourceCiteKey,
                    edge.targetCiteKey,
                    edge.kind.rawValue,
                    edge.weight,
                    payload,
                    updatedAt
                ]
            )
        }
    }

    public func saveCitationGraph(
        nodes: [CitationGraphNode],
        edges: [CitationGraphEdge],
        updatedAt: Date = Date()
    ) throws {
        try withLock {
            try connection.withTransaction {
                try connection.execute("DELETE FROM citation_graph_cache;")
                for node in nodes {
                    try upsertCitationGraphNode(node, updatedAt: updatedAt)
                }
                for edge in edges {
                    try upsertCitationGraphEdge(edge, updatedAt: updatedAt)
                }
            }
        }
    }

    public func loadCitationGraph() throws -> (nodes: [CitationGraphNode], edges: [CitationGraphEdge]) {
        try withLock {
            let nodeRows = try connection.query(
                "SELECT payload_json FROM citation_graph_cache WHERE entry_kind = 'NODE' ORDER BY cite_key ASC;"
            )
            let edgeRows = try connection.query(
                "SELECT payload_json FROM citation_graph_cache WHERE entry_kind = 'EDGE' ORDER BY entry_id ASC;"
            )
            let nodes = try nodeRows.map { try $0.jsonDecode(CitationGraphNode.self, column: "payload_json") }
            let edges = try edgeRows.map { try $0.jsonDecode(CitationGraphEdge.self, column: "payload_json") }
            return (nodes: nodes, edges: edges)
        }
    }

    public func clearCitationGraphCache() throws {
        try withLock {
            try connection.execute("DELETE FROM citation_graph_cache;")
        }
    }

    // MARK: - Editorial Findings, Plugin States & Audit Events CRUD

    public func upsertEditorialFinding(_ finding: EditorialAuditFinding, createdAt: Date = Date()) throws {
        try withLock {
            try connection.execute(
                """
                INSERT INTO editorial_findings (
                    id, plugin_id, plugin_name, severity, category, file_path, line,
                    matched_excerpt, explanation, suggested_rewrite, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    plugin_id = excluded.plugin_id,
                    plugin_name = excluded.plugin_name,
                    severity = excluded.severity,
                    category = excluded.category,
                    file_path = excluded.file_path,
                    line = excluded.line,
                    matched_excerpt = excluded.matched_excerpt,
                    explanation = excluded.explanation,
                    suggested_rewrite = excluded.suggested_rewrite,
                    created_at = excluded.created_at;
                """,
                bindings: [
                    finding.id,
                    finding.pluginID,
                    finding.pluginName,
                    finding.severity.rawValue,
                    finding.category,
                    Self.normalizeRelativePath(finding.filePath),
                    finding.line,
                    finding.matchedExcerpt,
                    finding.explanation,
                    finding.suggestedRewrite,
                    createdAt
                ]
            )
        }
    }

    public func replaceEditorialFindings(
        _ findings: [EditorialAuditFinding],
        forPluginID pluginID: String? = nil,
        createdAt: Date = Date()
    ) throws {
        try withLock {
            try connection.withTransaction {
                if let pluginID {
                    try connection.execute(
                        "DELETE FROM editorial_findings WHERE plugin_id = ?;",
                        bindings: [pluginID]
                    )
                } else {
                    try connection.execute("DELETE FROM editorial_findings;")
                }
                for finding in findings {
                    try upsertEditorialFinding(finding, createdAt: createdAt)
                }
            }
        }
    }

    public func listEditorialFindings(
        filePath: String? = nil,
        minimumSeverity: EditorialSeverity? = nil
    ) throws -> [EditorialAuditFinding] {
        try withLock {
            let rows: [SQLiteRow]
            if let filePath {
                rows = try connection.query(
                    """
                    SELECT * FROM editorial_findings
                    WHERE file_path = ?
                    ORDER BY line ASC, id ASC;
                    """,
                    bindings: [Self.normalizeRelativePath(filePath)]
                )
            } else {
                rows = try connection.query(
                    "SELECT * FROM editorial_findings ORDER BY file_path ASC, line ASC, id ASC;"
                )
            }
            let decoded = try rows.map(Self.decodeEditorialFindingRow)
            if let minimumSeverity {
                return decoded.filter { $0.severity >= minimumSeverity }
            }
            return decoded
        }
    }

    @discardableResult
    public func deleteEditorialFinding(id: UUID) throws -> Bool {
        try withLock {
            try connection.execute("DELETE FROM editorial_findings WHERE id = ?;", bindings: [id]) > 0
        }
    }

    public func upsertPluginManifest(
        _ manifest: ScholarPluginManifest,
        configJSON: String = "{}",
        updatedAt: Date = Date()
    ) throws {
        try withLock {
            let capabilitiesJSON = try ScholarSQLiteJSONCodec.encodeString(manifest.capabilities)
            try connection.execute(
                """
                INSERT INTO plugin_states (
                    plugin_id, name, version, summary, capabilities_json,
                    is_built_in, is_enabled, script_source, config_json, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(plugin_id) DO UPDATE SET
                    name = excluded.name,
                    version = excluded.version,
                    summary = excluded.summary,
                    capabilities_json = excluded.capabilities_json,
                    is_built_in = excluded.is_built_in,
                    is_enabled = excluded.is_enabled,
                    script_source = excluded.script_source,
                    config_json = excluded.config_json,
                    updated_at = excluded.updated_at;
                """,
                bindings: [
                    manifest.id,
                    manifest.name,
                    manifest.version,
                    manifest.summary,
                    capabilitiesJSON,
                    manifest.isBuiltIn,
                    manifest.isEnabled,
                    manifest.scriptSource,
                    configJSON,
                    updatedAt
                ]
            )
        }
    }

    public func setPluginEnabled(
        pluginID: String,
        isEnabled: Bool,
        updatedAt: Date = Date()
    ) throws {
        try withLock {
            let changed = try connection.execute(
                "UPDATE plugin_states SET is_enabled = ?, updated_at = ? WHERE plugin_id = ?;",
                bindings: [isEnabled, updatedAt, pluginID]
            )
            guard changed > 0 else {
                throw ScholarOSError.pluginError(
                    pluginID: pluginID,
                    message: "Plugin '\(pluginID)' is not registered in plugin_states."
                )
            }
        }
    }

    public func listPluginManifests(enabledOnly: Bool = false) throws -> [ScholarPluginManifest] {
        try withLock {
            let sql = enabledOnly
                ? "SELECT * FROM plugin_states WHERE is_enabled = 1 ORDER BY plugin_id ASC;"
                : "SELECT * FROM plugin_states ORDER BY plugin_id ASC;"
            let rows = try connection.query(sql)
            return try rows.map { row in
                let caps = try row.jsonDecode([ScholarPluginCapability].self, column: "capabilities_json")
                return ScholarPluginManifest(
                    id: try row.string("plugin_id"),
                    name: try row.string("name"),
                    version: try row.string("version"),
                    summary: try row.string("summary"),
                    capabilities: caps,
                    isBuiltIn: try row.bool("is_built_in"),
                    isEnabled: try row.bool("is_enabled"),
                    scriptSource: try row.string("script_source")
                )
            }
        }
    }

    public func pluginConfigurationJSON(pluginID: String) throws -> String? {
        try withLock {
            try connection.scalarString(
                "SELECT config_json FROM plugin_states WHERE plugin_id = ?;",
                bindings: [pluginID]
            )
        }
    }

    public func recordAuditEvent(
        category: String,
        action: String,
        actor: String = "ScholarOS",
        targetKey: String? = nil,
        details: [String: String] = [:],
        eventUUID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws {
        try withLock {
            let detailsJSON = try ScholarSQLiteJSONCodec.encodeString(details)
            try connection.execute(
                """
                INSERT INTO audit_events (
                    event_uuid, category, action, actor, target_key, detail_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [eventUUID, category, action, actor, targetKey, detailsJSON, createdAt]
            )
        }
    }

    public func listAuditEvents(category: String? = nil, limit: Int = 100) throws -> [ScholarAuditEventRecord] {
        try withLock {
            let bounded = max(1, limit)
            let rows: [SQLiteRow]
            if let category {
                rows = try connection.query(
                    """
                    SELECT * FROM audit_events
                    WHERE category = ?
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?;
                    """,
                    bindings: [category, bounded]
                )
            } else {
                rows = try connection.query(
                    """
                    SELECT * FROM audit_events
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?;
                    """,
                    bindings: [bounded]
                )
            }
            return try rows.map { row in
                ScholarAuditEventRecord(
                    id: try row.int64("id"),
                    eventUUID: try row.uuid("event_uuid"),
                    category: try row.string("category"),
                    action: try row.string("action"),
                    actor: try row.string("actor"),
                    targetKey: row.optionalString("target_key"),
                    details: try row.jsonDecode([String: String].self, column: "detail_json"),
                    createdAt: try row.date("created_at")
                )
            }
        }
    }

    private static func decodeEditorialFindingRow(_ row: SQLiteRow) throws -> EditorialAuditFinding {
        let sevRaw = try row.string("severity")
        let severity = EditorialSeverity(rawValue: sevRaw) ?? .styleSuggestion
        return EditorialAuditFinding(
            id: try row.uuid("id"),
            pluginID: try row.string("plugin_id"),
            pluginName: try row.string("plugin_name"),
            severity: severity,
            category: try row.string("category"),
            filePath: try row.string("file_path"),
            line: try row.int("line"),
            matchedExcerpt: try row.string("matched_excerpt"),
            explanation: try row.string("explanation"),
            suggestedRewrite: row.optionalString("suggested_rewrite")
        )
    }

    // MARK: - Project Telemetry & Aggregate Statistics

    public func computeProjectStats() throws -> ScholarProjectStats {
        try withLock {
            let title = try projectTitle()
            let primaryFile = try primaryManuscriptFile()
            let version = try currentSchemaVersion()
            let accounting = connection.storageAccounting()

            let wordCount = try totalManuscriptWordCount()
            let bibCount = try connection.scalarInt("SELECT COUNT(*) FROM bibliography_entries;")
            let verifiedCount = try connection.scalarInt(
                """
                SELECT COUNT(*) FROM bibliography_entries
                WHERE firewall_class IN ('VERIFIED_DOI', 'VERIFIED_ARXIV_PMID');
                """
            )
            let blockedCount = try connection.scalarInt(
                """
                SELECT COUNT(*) FROM bibliography_entries
                WHERE firewall_class = 'BLOCKED_HALLUCINATED';
                """
            )
            let passageCount = try connection.scalarInt("SELECT COUNT(*) FROM pdf_passages;")
            let studyCount = try connection.scalarInt("SELECT COUNT(*) FROM screening_studies;")
            let agreement = try computeInterRaterAgreement()
            let findingCount = try connection.scalarInt("SELECT COUNT(*) FROM editorial_findings;")
            let undoDepth = try connection.scalarInt(
                "SELECT COUNT(*) FROM undo_redo_journal WHERE stack_state = 'UNDO';"
            )
            let redoDepth = try connection.scalarInt(
                "SELECT COUNT(*) FROM undo_redo_journal WHERE stack_state = 'REDO';"
            )

            return ScholarProjectStats(
                projectTitle: title,
                primaryManuscriptFile: primaryFile,
                schemaVersion: version,
                sqliteBytes: accounting.sqliteBytes,
                walBytes: accounting.walBytes,
                manuscriptWordCount: wordCount,
                bibliographyCount: bibCount,
                verifiedCitationCount: verifiedCount,
                blockedCitationCount: blockedCount,
                indexedPDFPassageCount: passageCount,
                prismaStudyCount: studyCount,
                cohensKappa: agreement.cohensKappa,
                editorialFindingCount: findingCount,
                undoDepth: undoDepth,
                redoDepth: redoDepth
            )
        }
    }

    // MARK: - Deterministic Academic Flagship Demo Seeder

    public func seedDeterministicResearchProject() throws {
        try withLock {
            let anchorEpoch: TimeInterval = 1_762_992_000 // Fixed deterministic anchor timestamp
            let anchorDate = Date(timeIntervalSince1970: anchorEpoch)

            try connection.withTransaction(immediate: true) {
                try setProjectMeta(
                    key: "project_title",
                    value: "Verifiable Citation Firewalls and Sub-20ms Sandboxes for Autonomous Research Agents",
                    updatedAt: anchorDate
                )
                try setProjectMeta(
                    key: "primary_manuscript_file",
                    value: "main.tex",
                    updatedAt: anchorDate
                )
                try setProjectMeta(
                    key: "citation_style",
                    value: CitationFormatStyle.ieee.rawValue,
                    updatedAt: anchorDate
                )
                try setProjectMeta(
                    key: "lead_author",
                    value: "Elena Rostova, Kenji Takahashi, & Aria Lindholm",
                    updatedAt: anchorDate
                )

                // 1. Seed main.tex & sections/methodology.tex
                let mainTex = Self.flagshipMainTexSource
                let methodologyTex = Self.flagshipMethodologyTexSource

                try upsertManuscriptFile(
                    path: "main.tex",
                    content: mainTex,
                    format: .latex,
                    updatedAt: anchorDate
                )
                try upsertManuscriptFile(
                    path: "sections/methodology.tex",
                    content: methodologyTex,
                    format: .latex,
                    updatedAt: anchorDate
                )

                // 2. Seed 10 realistic BibliographyEntry records across all 5 CitationFirewallClasses
                let bibEntries = Self.flagshipBibliographyEntries()
                try upsertBibliographyEntries(bibEntries, updatedAt: anchorDate)

                // 3. Seed PRISMA 2020 PICO Protocol + 12 Dual-Blind Screening Studies (Cohen's kappa ≈ 0.78)
                let picoSpec = Self.flagshipPICOProtocol()
                try savePRISMAProtocol(
                    picoSpec,
                    protocolID: "default",
                    duplicateRecordsRemoved: 14,
                    registerRecordsIdentified: 3,
                    reportsNotRetrieved: 1,
                    updatedAt: anchorDate
                )
                try upsertScreeningStudies(Self.flagshipScreeningStudies(), updatedAt: anchorDate)

                // 4. Seed 8 PDFPassageChunks + 8 ClaimEvidenceProvenance links
                let passages = Self.flagshipPDFPassages()
                try upsertPDFPassages(passages)
                let provenanceLinks = Self.flagshipClaimProvenanceLinks()
                try upsertClaimProvenanceLinks(provenanceLinks)

                // 5. Seed 3 ManuscriptSnapshots for immediate Myers Track Changes diffing
                let snapshots = Self.flagshipSnapshots(anchorEpoch: anchorEpoch)
                for snap in snapshots {
                    try upsertSnapshot(snap)
                }

                // 6. Seed Citation Graph Cache & Built-in Editorial Findings / Plugins
                let graph = Self.flagshipCitationGraph(from: bibEntries)
                try saveCitationGraph(nodes: graph.nodes, edges: graph.edges, updatedAt: anchorDate)

                for plugin in Self.flagshipPluginManifests() {
                    try upsertPluginManifest(plugin, updatedAt: anchorDate)
                }
                try replaceEditorialFindings(Self.flagshipEditorialFindings(), createdAt: anchorDate)

                try recordAuditEvent(
                    category: "SEED",
                    action: "seedDeterministicResearchProject",
                    actor: "ScholarProjectStore",
                    targetKey: "main.tex",
                    details: [
                        "bibliography_count": "10",
                        "screening_studies": "12",
                        "pdf_passages": "8",
                        "snapshots": "3"
                    ],
                    eventUUID: UUID(uuidString: "99000000-0000-4000-8000-000000000001")!,
                    createdAt: anchorDate
                )
            }
        }
    }

    // MARK: - Flagship Seed Payloads

    private static let flagshipMainTexSource = #"""
    \documentclass[11pt,twocolumn]{article}
    \usepackage{amsmath,amssymb,booktabs,graphicx,hyperref,xspace}

    % Custom domain macros verified by ScholarOS incremental LSP
    \newcommand{\sysname}{\textsc{ScholarOS}\xspace}
    \newcommand{\firewalltag}[1]{\texttt{#1}}
    \newcommand{\kappacoef}{\kappa}

    % INTERNAL AUTHOR NOTE: Stripped automatically during arXiv/NeurIPS archive flattening.
    % Rejected hallucinated citation \cite{smith2025hallucinated} (bogus DOI 10.5555/fake-llm-cite.9999) via hardware-gated firewall.

    \title{Verifiable Citation Firewalls and Sub-20ms Sandboxes for Autonomous Research Agents}
    \author{Elena Rostova \and Kenji Takahashi \and Aria Lindholm}
    \date{November 2026}

    \begin{document}
    \maketitle

    \begin{abstract}
    Autonomous large language model research pipelines routinely synthesize plausible yet fabricated bibliographic citations when drafting scientific manuscripts. We present \sysname, a deterministic macOS workstation kernel combining a five-class hardware-gated Citation Verification Firewall, sub-20ms isolated editorial sandboxes, and bounding-box PDF provenance grounding. Across 1,420 benchmarked literature synthesis runs, \sysname blocks 99.4\% of fabricated identifiers prior to compilation while maintaining 14.2\,ms median incremental verification latency.
    \end{abstract}

    \section{Introduction}\label{sec:intro}
    Transformer architectures \cite{vaswani2017attention} and hardware-aware I/O-tiled attention kernels \cite{dao2023flashattention2} have accelerated automated literature review workflows, while message-passing graph encoders \cite{kipf2017semi} structure multi-hop citation networks. However, unconstrained agentic drafting frequently introduces non-existent DOIs, version drift between preprints and camera-ready proceedings \cite{chen2024agentdrift}, and ungrounded empirical assertions.

    To enforce methodological rigor aligned with the PRISMA 2020 reporting standard \cite{page2021prisma}, \sysname interposes a transactional SQLite Write-Ahead Logging (WAL) store and deterministic verification gate between manuscript editing and archival export. Our architecture undeniably guarantees 100\% elimination of all scholarly hallucinations across every conceivable scientific discipline without exception. Section~\ref{sec:methodology} formalizes our firewall state machine, Cohen's inter-rater reliability objective (Equation~\ref{eq:kappa}), and latency profile (Table~\ref{tab:latency}).

    \input{sections/methodology}

    \section{Empirical Evaluation}\label{sec:evaluation}
    Figure~\ref{fig:architecture} illustrates the end-to-end verification pipeline, and Table~\ref{tab:latency} summarizes subsystem p50 and p99 execution times on Apple Silicon. Force-directed bibliographic clustering leverages a Barnes--Hut quadtree approximation \cite{barnes1986hierarchical} to maintain interactive frame rates, while revision tracking executes Eugene Myers' shortest-edit-script algorithm \cite{myers1986ond} over tokenized LaTeX spans.

    \begin{figure}[t]
      \centering
      \fbox{\parbox{0.88\columnwidth}{\centering \sysname Five-Class Citation Firewall \& WAL Provenance Pipeline}}
      \caption{Hardware-gated verification flow from \texttt{\textbackslash cite} token resolution to PDF bounding-box entailment.}
      \label{fig:architecture}
    \end{figure}

    \begin{table}[t]
      \centering
      \caption{Subsystem latency and throughput across 10,000 incremental manuscript edits.}
      \label{tab:latency}
      \begin{tabular}{lrrr}
        \toprule
        Subsystem & p50 (ms) & p99 (ms) & Pass Rate \\
        \midrule
        Citation Firewall Lookup & 0.42 & 1.18 & 99.4\% \\
        JSC Editorial Sandbox & 6.80 & 17.90 & 100.0\% \\
        Myers Word-Level Diff & 1.35 & 4.10 & 100.0\% \\
        SQLite WAL Savepoint & 0.29 & 0.94 & 100.0\% \\
        \bottomrule
      \end{tabular}
    \end{table}

    \section{Conclusion}\label{sec:conclusion}
    By unifying verified Crossref/arXiv provenance, PRISMA 2020 dual-blind adjudication \cite{page2021prisma,cohen1960coefficient}, and crash-safe undo journals, \sysname establishes an auditable foundation for human--AI scholarly authorship.

    \bibliographystyle{IEEEtran}
    \bibliography{references}
    \end{document}
    """#

    private static let flagshipMethodologyTexSource = #"""
    \section{Methodology and Verification Semantics}\label{sec:methodology}
    % Private methodology scratch comment: double-check Reviewer 2's PABAK sensitivity note before camera-ready!

    \subsection{Five-Class Citation Firewall}\label{subsec:firewall}
    Every bibliographic key $k \in \mathcal{K}$ referenced in a manuscript AST is classified into one of five mutually exclusive verification states: \firewalltag{VERIFIED\_DOI}, \firewalltag{VERIFIED\_ARXIV\_PMID}, \firewalltag{METADATA\_DRIFT}, \firewalltag{UNVERIFIED\_OFFLINE}, or \firewalltag{BLOCKED\_HALLUCINATED}. Both archival flattening and MCP agent mutations reject any key $k$ lacking verified registry lineage or carrying a retraction/hallucination signature.

    \subsection{Dual-Blind PRISMA Screening and Inter-Rater Reliability}\label{subsec:prisma}
    Following PRISMA 2020 protocol guidelines \cite{page2021prisma}, two blinded reviewers independently assign nominal eligibility decisions across candidate records, and chance-corrected agreement is quantified via Cohen's $\kappacoef$ \cite{cohen1960coefficient}:
    \begin{equation}\label{eq:kappa}
      \kappacoef = \frac{P_o - P_e}{1 - P_e}, \qquad P_e = \frac{1}{N^2} \sum_{c \in \mathcal{C}} n_{c,A} \, n_{c,B},
    \end{equation}
    where $P_o$ denotes observed exact concordance across $N$ dual-screened studies and $n_{c,A}, n_{c,B}$ denote marginal category counts for Reviewers A and B.

    \subsection{PDF Bounding-Box Provenance and Graph Layout}\label{subsec:provenance}
    Extracted two-column PDF passages are scored against manuscript sentences using BM25 lexical-structural alignment while citation neighborhoods are embedded in $O(V \log V)$ time via hierarchical Barnes--Hut multipole cells \cite{barnes1986hierarchical}:
    \begin{equation}\label{eq:barnes-hut}
      \frac{s}{d} < \theta \implies \mathbf{F}_{\text{cell}}(\mathbf{x}_i) \approx -G_{\text{rep}} \frac{M_{\text{cell}}}{\|\mathbf{x}_i - \mathbf{x}_{\text{com}}\|^2 + \varepsilon} \hat{\mathbf{r}}.
    \end{equation}
    Word-level revision histories between snapshots are computed via Myers' $O(ND)$ shortest-edit-script recurrence \cite{myers1986ond}, preserving atomic \LaTeX{} citation and math tokens.
    """#

    private static func flagshipBibliographyEntries() -> [BibliographyEntry] {
        [
            BibliographyEntry(
                citeKey: "vaswani2017attention",
                kind: .inproceedings,
                title: "Attention Is All You Need",
                authors: [
                    BibAuthor(givenName: "Ashish", familyName: "Vaswani"),
                    BibAuthor(givenName: "Noam", familyName: "Shazeer"),
                    BibAuthor(givenName: "Niki", familyName: "Parmar"),
                    BibAuthor(givenName: "Jakob", familyName: "Uszkoreit"),
                    BibAuthor(givenName: "Llion", familyName: "Jones"),
                    BibAuthor(givenName: "Aidan N.", familyName: "Gomez"),
                    BibAuthor(givenName: "Lukasz", familyName: "Kaiser"),
                    BibAuthor(givenName: "Illia", familyName: "Polosukhin")
                ],
                year: 2017,
                venue: "Advances in Neural Information Processing Systems (NeurIPS)",
                publisher: "Curran Associates, Inc.",
                volume: "30",
                pages: "5998--6008",
                doi: "10.1145/3295222.3295349",
                arxivID: "1706.03762",
                url: "https://proceedings.neurips.cc/paper/2017/hash/3f5ee243547dee91fbd053c1c4a845aa-Abstract.html",
                abstractText: "The dominant sequence transduction models are based on complex recurrent or convolutional neural networks. We propose a new simple network architecture, the Transformer, based solely on attention mechanisms.",
                firewallClass: .verifiedCanonicalDOI,
                firewallAuditNote: "Canonical DOI and author fingerprint verified against Crossref and NeurIPS proceedings registry.",
                attachedPDFPath: "pdfs/vaswani2017attention.pdf",
                citedByKeys: ["dao2023flashattention2", "chen2024agentdrift"],
                referencesKeys: []
            ),
            BibliographyEntry(
                citeKey: "dao2023flashattention2",
                kind: .preprint,
                title: "FlashAttention-2: Faster Attention with Better Parallelism and Work Partitioning",
                authors: [
                    BibAuthor(givenName: "Tri", familyName: "Dao", orcid: "0000-0002-3669-2893")
                ],
                year: 2023,
                venue: "arXiv e-prints",
                arxivID: "2307.08691",
                url: "https://arxiv.org/abs/2307.08691",
                abstractText: "Scaling Transformer models to longer sequence lengths has been a major problem. FlashAttention-2 achieves 2x speedup over FlashAttention through improved warp-level work partitioning and reduced non-matmul FLOPs.",
                firewallClass: .verifiedPreprintRegistry,
                firewallAuditNote: "Verified against arXiv OAI-PMH v2 metadata feed (arXiv:2307.08691v1).",
                attachedPDFPath: "pdfs/dao2023flashattention2.pdf",
                citedByKeys: ["chen2024agentdrift"],
                referencesKeys: ["vaswani2017attention"]
            ),
            BibliographyEntry(
                citeKey: "kipf2017semi",
                kind: .inproceedings,
                title: "Semi-Supervised Classification with Graph Convolutional Networks",
                authors: [
                    BibAuthor(givenName: "Thomas N.", familyName: "Kipf"),
                    BibAuthor(givenName: "Max", familyName: "Welling")
                ],
                year: 2017,
                venue: "International Conference on Learning Representations (ICLR)",
                doi: "10.48550/arXiv.1609.02907",
                arxivID: "1609.02907",
                url: "https://openreview.net/forum?id=SJU4ayYgl",
                abstractText: "We present a scalable approach for semi-supervised learning on graph-structured data that is based on an efficient variant of convolutional neural networks which operate directly on graphs.",
                firewallClass: .verifiedCanonicalDOI,
                firewallAuditNote: "Verified DataCite DOI 10.48550/arXiv.1609.02907 and OpenReview ICLR 2017 acceptance record.",
                attachedPDFPath: "pdfs/kipf2017semi.pdf",
                citedByKeys: ["chen2024agentdrift"],
                referencesKeys: ["barnes1986hierarchical"]
            ),
            BibliographyEntry(
                citeKey: "page2021prisma",
                kind: .article,
                title: "The PRISMA 2020 statement: an updated guideline for reporting systematic reviews",
                authors: [
                    BibAuthor(givenName: "Matthew J.", familyName: "Page", orcid: "0000-0002-4242-7928"),
                    BibAuthor(givenName: "Joanne E.", familyName: "McKenzie"),
                    BibAuthor(givenName: "Patrick M.", familyName: "Bossuyt"),
                    BibAuthor(givenName: "Isabelle", familyName: "Boutron"),
                    BibAuthor(givenName: "Tammy C.", familyName: "Hoffmann"),
                    BibAuthor(givenName: "Cynthia D.", familyName: "Mulrow"),
                    BibAuthor(givenName: "David", familyName: "Moher")
                ],
                year: 2021,
                venue: "BMJ",
                publisher: "BMJ Publishing Group Ltd",
                volume: "372",
                pages: "n71",
                doi: "10.1136/bmj.n71",
                pmid: "33782057",
                url: "https://doi.org/10.1136/bmj.n71",
                abstractText: "The Preferred Reporting Items for Systematic reviews and Meta-Analyses (PRISMA) statement, published in 2009, has been updated to PRISMA 2020 to reflect advances in methods to identify, select, appraise, and synthesise studies.",
                firewallClass: .verifiedCanonicalDOI,
                firewallAuditNote: "Verified Crossref DOI 10.1136/bmj.n71 and PubMed PMID 33782057.",
                attachedPDFPath: "pdfs/page2021prisma.pdf",
                citedByKeys: ["chen2024agentdrift"],
                referencesKeys: ["cohen1960coefficient"]
            ),
            BibliographyEntry(
                citeKey: "cohen1960coefficient",
                kind: .article,
                title: "A Coefficient of Agreement for Nominal Scales",
                authors: [
                    BibAuthor(givenName: "Jacob", familyName: "Cohen")
                ],
                year: 1960,
                venue: "Educational and Psychological Measurement",
                publisher: "SAGE Publications",
                volume: "20",
                issue: "1",
                pages: "37--46",
                doi: "10.1177/001316446002000104",
                url: "https://doi.org/10.1177/001316446002000104",
                abstractText: "Introduces kappa, a coefficient of inter-judge agreement for nominal scales that corrects observed agreement proportion for chance agreement determined by marginal distributions.",
                firewallClass: .verifiedCanonicalDOI,
                firewallAuditNote: "Verified Crossref archival DOI 10.1177/001316446002000104.",
                attachedPDFPath: "pdfs/cohen1960coefficient.pdf",
                citedByKeys: ["page2021prisma"],
                referencesKeys: []
            ),
            BibliographyEntry(
                citeKey: "barnes1986hierarchical",
                kind: .article,
                title: "A hierarchical O(N log N) force-calculation algorithm",
                authors: [
                    BibAuthor(givenName: "Josh", familyName: "Barnes"),
                    BibAuthor(givenName: "Piet", familyName: "Hut")
                ],
                year: 1986,
                venue: "Nature",
                publisher: "Nature Publishing Group",
                volume: "324",
                issue: "6096",
                pages: "446--449",
                doi: "10.1038/324446a0",
                url: "https://doi.org/10.1038/324446a0",
                abstractText: "Presents a tree-structured hierarchical subdivision of space that reduces N-body gravitational force evaluation complexity from O(N^2) to O(N log N) using opening-angle multipole acceptance criteria.",
                firewallClass: .verifiedCanonicalDOI,
                firewallAuditNote: "Verified Crossref Nature DOI 10.1038/324446a0.",
                attachedPDFPath: "pdfs/barnes1986hierarchical.pdf",
                citedByKeys: ["kipf2017semi"],
                referencesKeys: []
            ),
            BibliographyEntry(
                citeKey: "myers1986ond",
                kind: .article,
                title: "An O(ND) Difference Algorithm and Its Variations",
                authors: [
                    BibAuthor(givenName: "Eugene W.", familyName: "Myers")
                ],
                year: 1986,
                venue: "Algorithmica",
                publisher: "Springer-Verlag",
                volume: "1",
                issue: "1-4",
                pages: "251--266",
                doi: "10.1007/BF01840446",
                url: "https://doi.org/10.1007/BF01840446",
                abstractText: "Develops an O((M+N)D) greedy edit-graph search algorithm for finding longest common subsequences and shortest edit scripts, optimal when edit distance D is small.",
                firewallClass: .verifiedCanonicalDOI,
                firewallAuditNote: "Verified Crossref Springer DOI 10.1007/BF01840446.",
                attachedPDFPath: "pdfs/myers1986ond.pdf",
                citedByKeys: ["chen2024agentdrift"],
                referencesKeys: []
            ),
            BibliographyEntry(
                citeKey: "chen2024agentdrift",
                kind: .inproceedings,
                title: "Sandboxed Tool Execution and Provenance Auditing for Autonomous Literature Synthesis",
                authors: [
                    BibAuthor(givenName: "Lin", familyName: "Chen"),
                    BibAuthor(givenName: "Priya", familyName: "Ramanathan"),
                    BibAuthor(givenName: "Marcus", familyName: "Vogt")
                ],
                year: 2024,
                venue: "USENIX Annual Technical Conference (USENIX ATC 24)",
                publisher: "USENIX Association",
                pages: "411--428",
                doi: "10.5555/usenix-atc24.chen411",
                arxivID: "2311.09412",
                url: "https://www.usenix.org/conference/atc24/presentation/chen",
                abstractText: "Evaluates deterministic sandbox isolation and citation metadata drift between arXiv preprints and peer-reviewed systems proceedings across 480 autonomous research workflows.",
                firewallClass: .metadataDriftAdvisory,
                firewallAuditNote: "Advisory: Local BibTeX originally imported 2023 arXiv preprint title; Crossref/DBLP resolves 2024 USENIX ATC camera-ready proceedings (pp. 411-428) with third co-author Marcus Vogt added.",
                attachedPDFPath: "pdfs/chen2024agentdrift.pdf",
                citedByKeys: [],
                referencesKeys: ["vaswani2017attention", "dao2023flashattention2", "page2021prisma", "myers1986ond"]
            ),
            BibliographyEntry(
                citeKey: "patel2025offline",
                kind: .techreport,
                title: "Incremental Concrete Syntax Tree Recovery for Scientific Typst and LaTeX Workspaces",
                authors: [
                    BibAuthor(givenName: "Kavita", familyName: "Patel"),
                    BibAuthor(givenName: "Henrik", familyName: "Lindqvist")
                ],
                year: 2025,
                venue: "ETH Zurich Systems Group Technical Report ETH-SYS-2025-04",
                publisher: "ETH Zurich",
                abstractText: "Describes error-recovering incremental CST reparsing for mixed LaTeX and Typst manuscripts under strict sub-5ms keystroke budgets.",
                firewallClass: .unverifiedPendingCheck,
                firewallAuditNote: "Imported while offline in air-gapped session; Crossref DOI and ETH Research Collection checksum verification pending.",
                attachedPDFPath: nil,
                citedByKeys: [],
                referencesKeys: ["myers1986ond"]
            ),
            BibliographyEntry(
                citeKey: "smith2025hallucinated",
                kind: .article,
                title: "Zero-Latency Quantum Citation Telepathy in Autonomous Foundation Models",
                authors: [
                    BibAuthor(givenName: "J.", familyName: "Smith"),
                    BibAuthor(givenName: "A.", familyName: "Doe")
                ],
                year: 2025,
                venue: "Journal of Synthetic Agentic Hallucinations",
                volume: "99",
                issue: "12",
                pages: "1--42",
                doi: "10.5555/fake-llm-cite.9999",
                abstractText: "Fabricated placeholder abstract produced by an unguarded LLM agent attempting to justify unsupported zero-latency claims.",
                firewallClass: .blockedHallucinatedOrRetracted,
                firewallAuditNote: "HARD BLOCK: DOI '10.5555/fake-llm-cite.9999' returned HTTP 404 in Crossref/DataCite; venue ISSN does not exist; flagged as LLM-fabricated citation signature.",
                attachedPDFPath: nil,
                citedByKeys: [],
                referencesKeys: []
            )
        ]
    }

    private static func flagshipPICOProtocol() -> PICOProtocolSpec {
        PICOProtocolSpec(
            reviewTitle: "Systematic Review of Citation Verification Firewalls and Deterministic Sandboxes in Scientific AI Agents",
            population: "Autonomous and human-in-the-loop AI research writing systems generating LaTeX/Typst manuscripts with bibliographic citations",
            intervention: "Deterministic registry-backed citation verification gates, bounded-latency execution sandboxes, and PDF passage provenance grounding",
            comparator: "Unconstrained LLM citation generation or post-hoc heuristic string matching without DOI/arXiv cryptographic or registry verification",
            outcomes: "Hallucinated citation block rate, metadata drift detection recall, median verification latency (ms), and inter-rater screening agreement (Cohen's kappa)",
            inclusionCriteria: [
                "I1: Peer-reviewed systems/NLP/ML paper or verified technical preprint (2017-2026) evaluating automated citation verification, provenance grounding, or sandboxed editorial tooling",
                "I2: Reports quantitative precision/recall on citation hallucination or p50/p99 subsystem latency benchmarks",
                "I3: Provides reproducible algorithm specification or open benchmark artifacts"
            ],
            exclusionRules: [
                ExclusionReasonRule(
                    priorityOrder: 1,
                    code: "E1_NO_FIREWALL",
                    label: "No bibliographic verification or provenance grounding mechanism evaluated"
                ),
                ExclusionReasonRule(
                    priorityOrder: 2,
                    code: "E2_NON_EMPIRICAL",
                    label: "Position piece, opinion editorial, or non-empirical commentary without quantitative benchmarks"
                ),
                ExclusionReasonRule(
                    priorityOrder: 3,
                    code: "E3_LATENCY_UNBOUNDED",
                    label: "Unbounded remote agent loop lacking deterministic timeout or sandbox isolation metrics"
                )
            ]
        )
    }

    /// 12 dual-blind studies engineered with exact nominal marginals yielding Cohen's kappa = 83/107 ≈ 0.78 (0.7757),
    /// including 4 agreed Full-Text includes, 1 agreed Title/Abstract maybe, 5 agreed excludes across E1/E2/E3,
    /// 1 adjudicated conflict (Full-Text included), and 1 active unresolved Reviewer A/B conflict.
    private static func flagshipScreeningStudies() -> [ScreeningStudyRecord] {
        [
            ScreeningStudyRecord(
                id: "SR-01",
                citeKey: "vaswani2017attention",
                title: "Attention Is All You Need",
                authorsLine: "Vaswani, A., Shazeer, N., Parmar, N., et al.",
                year: 2017,
                venue: "NeurIPS",
                doi: "10.1145/3295222.3295349",
                abstractText: "Foundational self-attention sequence architecture underpinning modern scientific language models and citation-aware encoders.",
                stage: .fullText,
                reviewerADecision: .include,
                reviewerBDecision: .include
            ),
            ScreeningStudyRecord(
                id: "SR-02",
                citeKey: "dao2023flashattention2",
                title: "FlashAttention-2: Faster Attention with Better Parallelism and Work Partitioning",
                authorsLine: "Dao, T.",
                year: 2023,
                venue: "arXiv",
                doi: nil,
                abstractText: "Hardware-aware I/O-tiled attention kernel establishing empirical p50/p99 latency reporting methodology for long-context document processing.",
                stage: .fullText,
                reviewerADecision: .include,
                reviewerBDecision: .include
            ),
            ScreeningStudyRecord(
                id: "SR-03",
                citeKey: "page2021prisma",
                title: "The PRISMA 2020 statement: an updated guideline for reporting systematic reviews",
                authorsLine: "Page, M. J., McKenzie, J. E., Bossuyt, P. M., et al.",
                year: 2021,
                venue: "BMJ",
                doi: "10.1136/bmj.n71",
                abstractText: "Canonical 27-item evidence synthesis reporting guideline and flow-diagram accounting specification for dual-reviewer study selection.",
                stage: .fullText,
                reviewerADecision: .include,
                reviewerBDecision: .include
            ),
            ScreeningStudyRecord(
                id: "SR-04",
                citeKey: "myers1986ond",
                title: "An O(ND) Difference Algorithm and Its Variations",
                authorsLine: "Myers, E. W.",
                year: 1986,
                venue: "Algorithmica",
                doi: "10.1007/BF01840446",
                abstractText: "Shortest-edit-script algorithm powering deterministic word-level manuscript revision tracking and provenance span diffing.",
                stage: .fullText,
                reviewerADecision: .include,
                reviewerBDecision: .include
            ),
            ScreeningStudyRecord(
                id: "SR-05",
                citeKey: "patel2025offline",
                title: "Incremental Concrete Syntax Tree Recovery for Scientific Typst and LaTeX Workspaces",
                authorsLine: "Patel, K. & Lindqvist, H.",
                year: 2025,
                venue: "ETH Zurich Tech Report",
                doi: nil,
                abstractText: "Evaluates sub-5ms incremental CST error recovery; awaiting full-text appendix retrieval to confirm citation firewall benchmark coverage.",
                stage: .titleAbstract,
                reviewerADecision: .maybe,
                reviewerBDecision: .maybe
            ),
            ScreeningStudyRecord(
                id: "SR-06",
                citeKey: "blog2023prompting",
                title: "Casual Zero-Shot Prompting Tricks for Essay Generation",
                authorsLine: "Miller, R.",
                year: 2023,
                venue: "Workshop on Informal Prompting",
                doi: nil,
                abstractText: "Describes ad-hoc prompt templates for undergraduate essays without bibliographic registries, citation validation, or provenance checks.",
                stage: .titleAbstract,
                reviewerADecision: .exclude(reasonCode: "E1_NO_FIREWALL"),
                reviewerBDecision: .exclude(reasonCode: "E1_NO_FIREWALL")
            ),
            ScreeningStudyRecord(
                id: "SR-07",
                citeKey: "nguyen2022poetry",
                title: "Stylistic Metre Control in Creative Verse Transformers",
                authorsLine: "Nguyen, T. & Alvarez, S.",
                year: 2022,
                venue: "Computational Creativity Letters",
                doi: "10.1000/ccl.2022.19",
                abstractText: "Focuses exclusively on syllable stress patterns in lyrical generation with zero scholarly citation or factual grounding components.",
                stage: .titleAbstract,
                reviewerADecision: .exclude(reasonCode: "E1_NO_FIREWALL"),
                reviewerBDecision: .exclude(reasonCode: "E1_NO_FIREWALL")
            ),
            ScreeningStudyRecord(
                id: "SR-08",
                citeKey: "harper2024opinion",
                title: "Why Autonomous Science Might Eventually Replace Peer Review: An Opinion",
                authorsLine: "Harper, D.",
                year: 2024,
                venue: "Future Research Commentary",
                doi: nil,
                abstractText: "A three-page philosophical commentary containing no system implementation, dataset, or quantitative empirical evaluation.",
                stage: .titleAbstract,
                reviewerADecision: .exclude(reasonCode: "E2_NON_EMPIRICAL"),
                reviewerBDecision: .exclude(reasonCode: "E2_NON_EMPIRICAL")
            ),
            ScreeningStudyRecord(
                id: "SR-09",
                citeKey: "keller2023editorial",
                title: "Editorial Note on Generative Text Policies in Society Journals",
                authorsLine: "Keller, M.",
                year: 2023,
                venue: "Transactions Policy Briefs",
                doi: nil,
                abstractText: "Brief policy announcement regarding author disclosure checkboxes without technical or empirical verification experiments.",
                stage: .fullText,
                reviewerADecision: .exclude(reasonCode: "E2_NON_EMPIRICAL"),
                reviewerBDecision: .exclude(reasonCode: "E2_NON_EMPIRICAL")
            ),
            ScreeningStudyRecord(
                id: "SR-10",
                citeKey: "zhou2024unbounded",
                title: "Multi-Hour Recursive Web Scraping Agents for Open-Ended Summaries",
                authorsLine: "Zhou, W., Park, J., & Silva, C.",
                year: 2024,
                venue: "Agentic Workflows Symposium",
                doi: nil,
                abstractText: "Runs unconstrained 4-hour browser loops without sandbox memory caps, deterministic watchdogs, or tail-latency reporting.",
                stage: .fullText,
                reviewerADecision: .exclude(reasonCode: "E3_LATENCY_UNBOUNDED"),
                reviewerBDecision: .exclude(reasonCode: "E3_LATENCY_UNBOUNDED")
            ),
            ScreeningStudyRecord(
                id: "SR-11",
                citeKey: "chen2024agentdrift",
                title: "Sandboxed Tool Execution and Provenance Auditing for Autonomous Literature Synthesis",
                authorsLine: "Chen, L., Ramanathan, P., & Vogt, M.",
                year: 2024,
                venue: "USENIX ATC 24",
                doi: "10.5555/usenix-atc24.chen411",
                abstractText: "Benchmarks sandbox isolation and preprint-to-proceedings citation drift across 480 autonomous research runs.",
                stage: .fullText,
                reviewerADecision: .include,
                reviewerBDecision: .maybe,
                adjudicatedDecision: .include,
                adjudicationRationale: "Third-reviewer full-text audit confirmed Section 5 reports exact p50/p99 sandbox watchdog latencies (<18ms) and Crossref drift recall."
            ),
            ScreeningStudyRecord(
                id: "SR-12",
                citeKey: "okafor2025hybrid",
                title: "Hybrid Local-Cloud Verification Caches for Bibliographic Knowledge Graphs",
                authorsLine: "Okafor, N. & Bergstrom, L.",
                year: 2025,
                venue: "Systems for ML Workshop",
                doi: "10.48550/arXiv.2501.04410",
                abstractText: "Combines local SQLite DOI caches with fallback cloud resolvers; Reviewer A flagged unbounded WAN fallback tail latency while Reviewer B voted include for local cache hit benchmarks.",
                stage: .fullText,
                reviewerADecision: .exclude(reasonCode: "E3_LATENCY_UNBOUNDED"),
                reviewerBDecision: .include,
                adjudicatedDecision: nil,
                adjudicationRationale: nil
            )
        ]
    }

    private static func flagshipPDFPassages() -> [PDFPassageChunk] {
        [
            PDFPassageChunk(
                id: "PSG-vaswani-p2-c1",
                citeKey: "vaswani2017attention",
                pdfFileName: "vaswani2017attention.pdf",
                sectionTitle: "3.2 Attention",
                columnIndex: 0,
                readingSequence: 1,
                boundingBox: PDFPageRegionBox(pageIndex: 2, x: 54.0, y: 412.0, width: 238.0, height: 96.0),
                passageText: "Scaled dot-product attention computes softmax((QK^T)/sqrt(d_k))V, enabling constant-path-length O(1) sequential operations between arbitrary token positions in scientific sequences."
            ),
            PDFPassageChunk(
                id: "PSG-dao-p4-c2",
                citeKey: "dao2023flashattention2",
                pdfFileName: "dao2023flashattention2.pdf",
                sectionTitle: "2.3 Work Partitioning Between Warps",
                columnIndex: 1,
                readingSequence: 2,
                boundingBox: PDFPageRegionBox(pageIndex: 3, x: 306.0, y: 518.0, width: 240.0, height: 104.0),
                passageText: "FlashAttention-2 partitions keys and values across shared-memory tiles while splitting query blocks across GPU warps, eliminating inter-warp atomic reductions and achieving 2.0x end-to-end kernel speedup."
            ),
            PDFPassageChunk(
                id: "PSG-kipf-p3-c1",
                citeKey: "kipf2017semi",
                pdfFileName: "kipf2017semi.pdf",
                sectionTitle: "2 Fast Approximate Convolutions on Graphs",
                columnIndex: 0,
                readingSequence: 3,
                boundingBox: PDFPageRegionBox(pageIndex: 2, x: 56.0, y: 280.0, width: 236.0, height: 88.0),
                passageText: "A layer-wise propagation rule H^{(l+1)} = sigma(D^{-1/2} A_hat D^{-1/2} H^{(l)} W^{(l)}) aggregates first-order citation neighborhoods in time linear in the number of bibliographic edges."
            ),
            PDFPassageChunk(
                id: "PSG-page-p2-c1",
                citeKey: "page2021prisma",
                pdfFileName: "page2021prisma.pdf",
                sectionTitle: "Study Selection and Flow Diagram (Items 8 & 16)",
                columnIndex: 0,
                readingSequence: 4,
                boundingBox: PDFPageRegionBox(pageIndex: 4, x: 52.0, y: 604.0, width: 242.0, height: 112.0),
                passageText: "Authors should specify how many reviewers independently screened each record and report retrieved, whether they worked independently, and provide exact exclusion counts for each full-text eligibility criterion."
            ),
            PDFPassageChunk(
                id: "PSG-cohen-p4-c1",
                citeKey: "cohen1960coefficient",
                pdfFileName: "cohen1960coefficient.pdf",
                sectionTitle: "Formulation of Kappa",
                columnIndex: 0,
                readingSequence: 5,
                boundingBox: PDFPageRegionBox(pageIndex: 3, x: 60.0, y: 340.0, width: 390.0, height: 92.0),
                passageText: "The coefficient kappa = (p_o - p_c) / (1 - p_c) expresses the proportion of joint judgments in which there is agreement, after chance agreement p_c determined by the judges' marginal proportions is excluded."
            ),
            PDFPassageChunk(
                id: "PSG-barnes-p1-c2",
                citeKey: "barnes1986hierarchical",
                pdfFileName: "barnes1986hierarchical.pdf",
                sectionTitle: "Hierarchical Force Calculation",
                columnIndex: 1,
                readingSequence: 6,
                boundingBox: PDFPageRegionBox(pageIndex: 0, x: 308.0, y: 196.0, width: 234.0, height: 108.0),
                passageText: "By recursively dividing space into cubic or quadtree cells and approximating distant clusters whose cell width s and distance d satisfy s/d < theta as single center-of-mass monopoles, work scales as O(N log N)."
            ),
            PDFPassageChunk(
                id: "PSG-myers-p6-c1",
                citeKey: "myers1986ond",
                pdfFileName: "myers1986ond.pdf",
                sectionTitle: "2 An O((M+N)D) Greedy Algorithm",
                columnIndex: 0,
                readingSequence: 7,
                boundingBox: PDFPageRegionBox(pageIndex: 5, x: 72.0, y: 448.0, width: 410.0, height: 100.0),
                passageText: "Searching furthest-reaching D-paths along diagonals k = x - y finds a shortest edit script in O((M+N)D) time and O(D) working space per trace step, ideal when manuscript revisions share long unchanged snakes."
            ),
            PDFPassageChunk(
                id: "PSG-chen-p8-c2",
                citeKey: "chen2024agentdrift",
                pdfFileName: "chen2024agentdrift.pdf",
                sectionTitle: "5.2 Preprint-to-Proceedings Drift & Hallucination Rates",
                columnIndex: 1,
                readingSequence: 8,
                boundingBox: PDFPageRegionBox(pageIndex: 7, x: 304.0, y: 310.0, width: 240.0, height: 116.0),
                passageText: "Across 480 autonomous synthesis runs, 18.6% of valid preprints exhibited metadata drift against camera-ready proceedings, while deterministic sandboxed DOI gates blocked 99.1% of fabricated citations within 17.8 ms p99."
            )
        ]
    }

    private static func flagshipClaimProvenanceLinks() -> [ClaimEvidenceProvenance] {
        [
            ClaimEvidenceProvenance(
                id: UUID(uuidString: "77000000-0000-4000-8000-000000000001")!,
                manuscriptFile: "main.tex",
                manuscriptLine: 23,
                manuscriptClaim: "Transformer architectures and hardware-aware I/O-tiled attention kernels have accelerated automated literature review workflows",
                citeKey: "vaswani2017attention",
                passageID: "PSG-vaswani-p2-c1",
                pdfExcerpt: "Scaled dot-product attention computes softmax((QK^T)/sqrt(d_k))V, enabling constant-path-length O(1) sequential operations",
                boundingBox: PDFPageRegionBox(pageIndex: 2, x: 54.0, y: 412.0, width: 238.0, height: 96.0),
                bm25Score: 14.82,
                verdict: .groundedEntailment
            ),
            ClaimEvidenceProvenance(
                id: UUID(uuidString: "77000000-0000-4000-8000-000000000002")!,
                manuscriptFile: "main.tex",
                manuscriptLine: 23,
                manuscriptClaim: "hardware-aware I/O-tiled attention kernels have accelerated automated literature review workflows",
                citeKey: "dao2023flashattention2",
                passageID: "PSG-dao-p4-c2",
                pdfExcerpt: "FlashAttention-2 partitions keys and values across shared-memory tiles while splitting query blocks across GPU warps",
                boundingBox: PDFPageRegionBox(pageIndex: 3, x: 306.0, y: 518.0, width: 240.0, height: 104.0),
                bm25Score: 16.45,
                verdict: .groundedEntailment
            ),
            ClaimEvidenceProvenance(
                id: UUID(uuidString: "77000000-0000-4000-8000-000000000003")!,
                manuscriptFile: "main.tex",
                manuscriptLine: 23,
                manuscriptClaim: "message-passing graph encoders structure multi-hop citation networks",
                citeKey: "kipf2017semi",
                passageID: "PSG-kipf-p3-c1",
                pdfExcerpt: "aggregates first-order citation neighborhoods in time linear in the number of bibliographic edges",
                boundingBox: PDFPageRegionBox(pageIndex: 2, x: 56.0, y: 280.0, width: 236.0, height: 88.0),
                bm25Score: 13.19,
                verdict: .groundedEntailment
            ),
            ClaimEvidenceProvenance(
                id: UUID(uuidString: "77000000-0000-4000-8000-000000000004")!,
                manuscriptFile: "main.tex",
                manuscriptLine: 23,
                manuscriptClaim: "version drift between preprints and camera-ready proceedings",
                citeKey: "chen2024agentdrift",
                passageID: "PSG-chen-p8-c2",
                pdfExcerpt: "18.6% of valid preprints exhibited metadata drift against camera-ready proceedings, while deterministic sandboxed DOI gates blocked 99.1%",
                boundingBox: PDFPageRegionBox(pageIndex: 7, x: 304.0, y: 310.0, width: 240.0, height: 116.0),
                bm25Score: 15.70,
                verdict: .numericDiscrepancy
            ),
            ClaimEvidenceProvenance(
                id: UUID(uuidString: "77000000-0000-4000-8000-000000000005")!,
                manuscriptFile: "sections/methodology.tex",
                manuscriptLine: 9,
                manuscriptClaim: "Following PRISMA 2020 protocol guidelines, two blinded reviewers independently assign nominal eligibility decisions",
                citeKey: "page2021prisma",
                passageID: "PSG-page-p2-c1",
                pdfExcerpt: "specify how many reviewers independently screened each record and report retrieved, whether they worked independently",
                boundingBox: PDFPageRegionBox(pageIndex: 4, x: 52.0, y: 604.0, width: 242.0, height: 112.0),
                bm25Score: 17.94,
                verdict: .groundedEntailment
            ),
            ClaimEvidenceProvenance(
                id: UUID(uuidString: "77000000-0000-4000-8000-000000000006")!,
                manuscriptFile: "sections/methodology.tex",
                manuscriptLine: 9,
                manuscriptClaim: "chance-corrected agreement is quantified via Cohen's kappa",
                citeKey: "cohen1960coefficient",
                passageID: "PSG-cohen-p4-c1",
                pdfExcerpt: "The coefficient kappa = (p_o - p_c) / (1 - p_c) expresses the proportion of joint judgments in which there is agreement",
                boundingBox: PDFPageRegionBox(pageIndex: 3, x: 60.0, y: 340.0, width: 390.0, height: 92.0),
                bm25Score: 18.61,
                verdict: .groundedEntailment
            ),
            ClaimEvidenceProvenance(
                id: UUID(uuidString: "77000000-0000-4000-8000-000000000007")!,
                manuscriptFile: "sections/methodology.tex",
                manuscriptLine: 16,
                manuscriptClaim: "citation neighborhoods are embedded in O(V log V) time via hierarchical Barnes-Hut multipole cells",
                citeKey: "barnes1986hierarchical",
                passageID: "PSG-barnes-p1-c2",
                pdfExcerpt: "approximating distant clusters whose cell width s and distance d satisfy s/d < theta as single center-of-mass monopoles, work scales as O(N log N)",
                boundingBox: PDFPageRegionBox(pageIndex: 0, x: 308.0, y: 196.0, width: 234.0, height: 108.0),
                bm25Score: 16.08,
                verdict: .groundedEntailment
            ),
            ClaimEvidenceProvenance(
                id: UUID(uuidString: "77000000-0000-4000-8000-000000000008")!,
                manuscriptFile: "main.tex",
                manuscriptLine: 25,
                manuscriptClaim: "Our architecture undeniably guarantees 100% elimination of all scholarly hallucinations across every conceivable scientific discipline without exception.",
                citeKey: "chen2024agentdrift",
                passageID: "PSG-chen-p8-c2",
                pdfExcerpt: "deterministic sandboxed DOI gates blocked 99.1% of fabricated citations within 17.8 ms p99.",
                boundingBox: PDFPageRegionBox(pageIndex: 7, x: 304.0, y: 310.0, width: 240.0, height: 116.0),
                bm25Score: 6.12,
                verdict: .unsupportedClaim
            )
        ]
    }

    private static func flagshipSnapshots(anchorEpoch: TimeInterval) -> [ManuscriptSnapshot] {
        let draft1Content = #"""
        \documentclass[11pt,twocolumn]{article}
        \usepackage{amsmath,amssymb,booktabs,hyperref,xspace}
        \newcommand{\sysname}{\textsc{ScholarOS}\xspace}

        \title{Citation Firewalls for Autonomous Research Agents}
        \author{Elena Rostova \and Kenji Takahashi}
        \date{October 2026}

        \begin{document}
        \maketitle

        \begin{abstract}
        Autonomous language models frequently fabricate citations during literature synthesis. We introduce \sysname, a local verification layer blocking unverified bibliographic keys before compilation across 800 preliminary runs.
        \end{abstract}

        \section{Introduction}\label{sec:intro}
        Transformer architectures \cite{vaswani2017attention} have accelerated automated drafting, yet unverified DOIs remain widespread. \sysname enforces PRISMA 2020 screening rules \cite{page2021prisma} backed by SQLite storage.

        \section{Conclusion}\label{sec:conclusion}
        \sysname improves bibliographic reliability for scientific writing workflows.
        \bibliographystyle{IEEEtran}
        \bibliography{references}
        \end{document}
        """#

        let draft2Content = #"""
        \documentclass[11pt,twocolumn]{article}
        \usepackage{amsmath,amssymb,booktabs,graphicx,hyperref,xspace}
        \newcommand{\sysname}{\textsc{ScholarOS}\xspace}
        \newcommand{\firewalltag}[1]{\texttt{#1}}
        \newcommand{\kappacoef}{\kappa}

        \title{Verifiable Citation Firewalls and Sandboxes for Autonomous Research Agents}
        \author{Elena Rostova \and Kenji Takahashi \and Aria Lindholm}
        \date{November 2026}

        \begin{document}
        \maketitle

        \begin{abstract}
        Autonomous large language model research pipelines routinely synthesize plausible yet fabricated citations when drafting manuscripts. We present \sysname, a macOS workstation combining a five-class Citation Verification Firewall and PDF provenance grounding. Across 1,200 synthesis runs, \sysname blocks 98.9\% of fabricated identifiers within 16.5\,ms median latency.
        \end{abstract}

        \section{Introduction}\label{sec:intro}
        Transformer architectures \cite{vaswani2017attention} and I/O-tiled attention kernels \cite{dao2023flashattention2} accelerate literature synthesis, while graph encoders \cite{kipf2017semi} structure citation networks. Aligned with PRISMA 2020 \cite{page2021prisma}, \sysname interposes a transactional SQLite WAL store and Myers word-level diff engine \cite{myers1986ond}.

        \input{sections/methodology}

        \section{Conclusion}\label{sec:conclusion}
        By unifying Crossref provenance and dual-blind adjudication \cite{page2021prisma,cohen1960coefficient}, \sysname establishes a reproducible scholarly workstation.
        \bibliographystyle{IEEEtran}
        \bibliography{references}
        \end{document}
        """#

        let draft3Content = flagshipMainTexSource

        return [
            ManuscriptSnapshot(
                id: UUID(uuidString: "88000000-0000-4000-8000-000000000001")!,
                label: "Initial Submission Draft",
                authorName: "Elena Rostova",
                filePath: "main.tex",
                sourceContent: draft1Content,
                wordCount: ScholarWordCounter.countAcademicWords(draft1Content, format: .latex),
                createdAt: Date(timeIntervalSince1970: anchorEpoch - 14 * 86_400)
            ),
            ManuscriptSnapshot(
                id: UUID(uuidString: "88000000-0000-4000-8000-000000000002")!,
                label: "Post-Reviewer-2 Revision",
                authorName: "Kenji Takahashi",
                filePath: "main.tex",
                sourceContent: draft2Content,
                wordCount: ScholarWordCounter.countAcademicWords(draft2Content, format: .latex),
                createdAt: Date(timeIntervalSince1970: anchorEpoch - 3 * 86_400)
            ),
            ManuscriptSnapshot(
                id: UUID(uuidString: "88000000-0000-4000-8000-000000000003")!,
                label: "Camera-Ready Candidate",
                authorName: "Aria Lindholm",
                filePath: "main.tex",
                sourceContent: draft3Content,
                wordCount: ScholarWordCounter.countAcademicWords(draft3Content, format: .latex),
                createdAt: Date(timeIntervalSince1970: anchorEpoch - 3_600)
            )
        ]
    }

    private static func flagshipCitationGraph(
        from entries: [BibliographyEntry]
    ) -> (nodes: [CitationGraphNode], edges: [CitationGraphEdge]) {
        var nodes: [CitationGraphNode] = []
        var edges: [CitationGraphEdge] = []
        let validKeys = Set(entries.map(\.citeKey))

        for (index, entry) in entries.enumerated() {
            let angle = (2.0 * Double.pi * Double(index)) / Double(max(1, entries.count))
            let radius = 180.0
            let cluster: Int
            switch entry.firewallClass {
            case .verifiedCanonicalDOI, .verifiedPreprintRegistry:
                cluster = index % 2
            case .metadataDriftAdvisory:
                cluster = 2
            case .unverifiedPendingCheck, .blockedHallucinatedOrRetracted:
                cluster = 3
            }

            let inDeg = entry.citedByKeys.filter { validKeys.contains($0) }.count
            let outDeg = entry.referencesKeys.filter { validKeys.contains($0) }.count
            let pr = 0.06 + 0.04 * Double(inDeg) + 0.015 * Double(outDeg)

            nodes.append(
                CitationGraphNode(
                    citeKey: entry.citeKey,
                    title: entry.title,
                    authorYearLabel: "\(entry.firstAuthorFamily) (\(entry.year ?? 2025))",
                    year: entry.year ?? 2025,
                    inDegree: inDeg,
                    outDegree: outDeg,
                    pageRank: pr,
                    betweennessScore: inDeg > 0 && outDeg > 0 ? 0.42 : 0.08,
                    clusterIndex: cluster,
                    isBridgePaper: entry.citeKey == "chen2024agentdrift" || entry.citeKey == "page2021prisma",
                    x: cos(angle) * radius,
                    y: sin(angle) * radius
                )
            )

            for refTarget in entry.referencesKeys where validKeys.contains(refTarget) {
                edges.append(
                    CitationGraphEdge(
                        sourceCiteKey: entry.citeKey,
                        targetCiteKey: refTarget,
                        kind: .directCitation,
                        weight: 1.0
                    )
                )
            }
        }
        return (nodes: nodes, edges: edges)
    }

    private static func flagshipPluginManifests() -> [ScholarPluginManifest] {
        [
            ScholarPluginManifest(
                id: "builtin.overclaim-sentinel",
                name: "Scientific Overclaim & Absolute Quantifier Sentinel",
                version: "1.2.0",
                summary: "Flags non-falsifiable universal quantifiers ('undeniably guarantees 100%', 'without exception') in empirical claims.",
                capabilities: [.readManuscriptAST, .emitEditorialFindings, .suggestProseRewrite],
                isBuiltIn: true,
                isEnabled: true,
                scriptSource: """
                function audit(manuscript) {
                  return ScholarHost.scanAbsoluteOverclaims(manuscript);
                }
                """
            ),
            ScholarPluginManifest(
                id: "builtin.drift-advisor",
                name: "Preprint-to-Proceedings Drift Advisor",
                version: "1.1.0",
                summary: "Cross-checks cited preprints against peer-reviewed conference proceedings metadata in bibliography_entries.",
                capabilities: [.readManuscriptAST, .readBibliography, .emitEditorialFindings],
                isBuiltIn: true,
                isEnabled: true,
                scriptSource: """
                function audit(manuscript, bibliography) {
                  return ScholarHost.auditMetadataDrift(manuscript, bibliography);
                }
                """
            )
        ]
    }

    private static func flagshipEditorialFindings() -> [EditorialAuditFinding] {
        [
            EditorialAuditFinding(
                id: UUID(uuidString: "66000000-0000-4000-8000-000000000001")!,
                pluginID: "builtin.overclaim-sentinel",
                pluginName: "Scientific Overclaim & Absolute Quantifier Sentinel",
                severity: .submissionBlocker,
                category: "Empirical Overclaim",
                filePath: "main.tex",
                line: 25,
                matchedExcerpt: "Our architecture undeniably guarantees 100\\% elimination of all scholarly hallucinations across every conceivable scientific discipline without exception.",
                explanation: "Universal non-falsifiable claim ('undeniably guarantees 100%', 'without exception') contradicts Abstract & Table 1 empirical pass rate (99.4%).",
                suggestedRewrite: "Empirically, our architecture blocks 99.4\\% of benchmarked citation hallucinations across evaluated computer science and biomedical corpora (Table~\\ref{tab:latency})."
            ),
            EditorialAuditFinding(
                id: UUID(uuidString: "66000000-0000-4000-8000-000000000002")!,
                pluginID: "builtin.drift-advisor",
                pluginName: "Preprint-to-Proceedings Drift Advisor",
                severity: .rigorWarning,
                category: "Citation Metadata Drift",
                filePath: "main.tex",
                line: 23,
                matchedExcerpt: "\\cite{chen2024agentdrift}",
                explanation: "Entry 'chen2024agentdrift' carries METADATA_DRIFT status: verify page numbers (pp. 411--428) and third co-author against USENIX ATC 24 proceedings.",
                suggestedRewrite: nil
            )
        ]
    }

    @discardableResult
    @inline(__always)
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
