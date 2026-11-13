import Foundation
import SQLite3
import ScholarModels

// MARK: - Zotero Collection Metadata, Library Summary & Import Configuration

public struct ZoteroCollectionRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: Int { collectionID }
    public let collectionID: Int
    public let key: String
    public let name: String
    public let parentCollectionID: Int?
    public let fullBreadcrumbPath: String
    public let directItemCount: Int

    public init(
        collectionID: Int,
        key: String,
        name: String,
        parentCollectionID: Int?,
        fullBreadcrumbPath: String,
        directItemCount: Int
    ) {
        self.collectionID = collectionID
        self.key = key
        self.name = name
        self.parentCollectionID = parentCollectionID
        self.fullBreadcrumbPath = fullBreadcrumbPath
        self.directItemCount = directItemCount
    }
}

public struct ZoteroLibrarySummary: Sendable, Codable, Hashable {
    public let databasePath: String
    public let openedImmutableReadOnly: Bool
    public let zoteroSchemaVersion: Int?
    public let totalItemsCount: Int
    public let bibliographicItemsCount: Int
    public let trashedItemsCount: Int
    public let attachmentItemsCount: Int
    public let pdfAttachmentCount: Int
    public let noteItemsCount: Int
    public let totalCreatorsCount: Int
    public let totalCollectionsCount: Int
    public let itemCountsByZoteroType: [String: Int]
    public let collections: [ZoteroCollectionRecord]

    public init(
        databasePath: String,
        openedImmutableReadOnly: Bool,
        zoteroSchemaVersion: Int?,
        totalItemsCount: Int,
        bibliographicItemsCount: Int,
        trashedItemsCount: Int,
        attachmentItemsCount: Int,
        pdfAttachmentCount: Int,
        noteItemsCount: Int,
        totalCreatorsCount: Int,
        totalCollectionsCount: Int,
        itemCountsByZoteroType: [String: Int],
        collections: [ZoteroCollectionRecord]
    ) {
        self.databasePath = databasePath
        self.openedImmutableReadOnly = openedImmutableReadOnly
        self.zoteroSchemaVersion = zoteroSchemaVersion
        self.totalItemsCount = totalItemsCount
        self.bibliographicItemsCount = bibliographicItemsCount
        self.trashedItemsCount = trashedItemsCount
        self.attachmentItemsCount = attachmentItemsCount
        self.pdfAttachmentCount = pdfAttachmentCount
        self.noteItemsCount = noteItemsCount
        self.totalCreatorsCount = totalCreatorsCount
        self.totalCollectionsCount = totalCollectionsCount
        self.itemCountsByZoteroType = itemCountsByZoteroType
        self.collections = collections
    }
}

public struct ZoteroImportOptions: Sendable, Codable, Hashable {
    public var immutableReadOnlyURI: Bool
    public var includeTrashedItems: Bool
    public var collectionKeyFilter: String?
    public var collectionNameFilter: String?
    public var zoteroDataDirectoryPath: String?
    public var linkedAttachmentBaseDirectoryPath: String?
    public var evaluateOfflineFirewall: Bool
    public var maxItemsLimit: Int?

    public init(
        immutableReadOnlyURI: Bool = true,
        includeTrashedItems: Bool = false,
        collectionKeyFilter: String? = nil,
        collectionNameFilter: String? = nil,
        zoteroDataDirectoryPath: String? = nil,
        linkedAttachmentBaseDirectoryPath: String? = nil,
        evaluateOfflineFirewall: Bool = true,
        maxItemsLimit: Int? = nil
    ) {
        self.immutableReadOnlyURI = immutableReadOnlyURI
        self.includeTrashedItems = includeTrashedItems
        self.collectionKeyFilter = collectionKeyFilter
        self.collectionNameFilter = collectionNameFilter
        self.zoteroDataDirectoryPath = zoteroDataDirectoryPath
        self.linkedAttachmentBaseDirectoryPath = linkedAttachmentBaseDirectoryPath
        self.evaluateOfflineFirewall = evaluateOfflineFirewall
        self.maxItemsLimit = maxItemsLimit
    }

    public static let standard = ZoteroImportOptions()
}

// MARK: - Immutable Read-Only Zotero 6/7 SQLite Bridge

public struct ZoteroSQLiteReadBridge: Sendable {

    /// Zotero non-bibliographic internal item types excluded from citation import.
    private static let nonBibliographicItemTypes: Set<String> = [
        "attachment",
        "note",
        "annotation"
    ]

    public let defaultOptions: ZoteroImportOptions
    private let firewall: CitationVerificationFirewall

    public init(
        defaultOptions: ZoteroImportOptions = .standard,
        firewall: CitationVerificationFirewall = CitationVerificationFirewall()
    ) {
        self.defaultOptions = defaultOptions
        self.firewall = firewall
    }

    /// Locates the user's default macOS Zotero 6/7 SQLite database (`~/Zotero/zotero.sqlite`) without opening or locking it.
    public static func discoverDefaultMacOSZoteroDatabasePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Zotero/zotero.sqlite",
            "\(home)/Library/Application Support/Zotero/Profiles/default/zotero/zotero.sqlite"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - Public Read-Only Inspection & Import API

    /// Inspects a Zotero 6/7 SQLite database in strict read-only / immutable mode and returns counts, schema version, and collection hierarchy.
    public func summarizeLibrary(
        databasePath: String,
        immutable: Bool = true
    ) throws -> ZoteroLibrarySummary {
        let db = try openReadOnlyZoteroConnection(atPath: databasePath, immutable: immutable)
        defer { sqlite3_close_v2(db) }

        try verifyCoreZoteroSchema(db)

        let schemaVersion = queryOptionalInt(
            db,
            sql: "SELECT version FROM version WHERE schema = 'userdata' LIMIT 1;"
        ) ?? queryOptionalInt(
            db,
            sql: "SELECT MAX(version) FROM version;"
        )

        let trashedIDs = try loadDeletedItemIDs(db)
        let collections = try loadCollections(db, excludedItemIDs: trashedIDs)
        let totalCreators = queryOptionalInt(db, sql: "SELECT COUNT(*) FROM creators;") ?? 0

        let typeRowsSQL = """
            SELECT it.typeName, i.itemID
            FROM items i
            JOIN itemTypes it ON it.itemTypeID = i.itemTypeID;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, typeRowsSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteFailure(db, context: "preparing item type summary query")
        }
        defer { sqlite3_finalize(stmt) }

        var totalItems = 0
        var bibCount = 0
        var attachmentCount = 0
        var noteCount = 0
        var countsByType: [String: Int] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let typeName = columnText(stmt, 0) ?? "unknown"
            let itemID = Int(sqlite3_column_int64(stmt, 1))
            totalItems += 1

            if trashedIDs.contains(itemID) {
                continue
            }

            countsByType[typeName, default: 0] += 1
            if typeName == "attachment" {
                attachmentCount += 1
            } else if typeName == "note" || typeName == "annotation" {
                noteCount += 1
            } else {
                bibCount += 1
            }
        }

        let pdfCount: Int = {
            guard tableExists(db, name: "itemAttachments") else { return 0 }
            let sql = """
                SELECT COUNT(*)
                FROM itemAttachments ia
                WHERE (LOWER(COALESCE(ia.contentType, '')) = 'application/pdf'
                   OR LOWER(COALESCE(ia.path, '')) LIKE '%.pdf');
                """
            return queryOptionalInt(db, sql: sql) ?? 0
        }()

        return ZoteroLibrarySummary(
            databasePath: databasePath,
            openedImmutableReadOnly: immutable,
            zoteroSchemaVersion: schemaVersion,
            totalItemsCount: totalItems,
            bibliographicItemsCount: bibCount,
            trashedItemsCount: trashedIDs.count,
            attachmentItemsCount: attachmentCount,
            pdfAttachmentCount: pdfCount,
            noteItemsCount: noteCount,
            totalCreatorsCount: totalCreators,
            totalCollectionsCount: collections.count,
            itemCountsByZoteroType: countsByType,
            collections: collections
        )
    }

    /// Imports bibliographic records, creators, collection filters, Better BibTeX keys, and PDF attachment paths in strict read-only mode.
    public func importEntries(
        databasePath: String,
        options: ZoteroImportOptions? = nil
    ) throws -> [BibliographyEntry] {
        let activeOptions = options ?? defaultOptions
        let db = try openReadOnlyZoteroConnection(
            atPath: databasePath,
            immutable: activeOptions.immutableReadOnlyURI
        )
        defer { sqlite3_close_v2(db) }

        try verifyCoreZoteroSchema(db)

        let resolvedDataDir = activeOptions.zoteroDataDirectoryPath
            ?? URL(fileURLWithPath: databasePath).deletingLastPathComponent().path

        let trashedIDs = activeOptions.includeTrashedItems ? Set<Int>() : (try loadDeletedItemIDs(db))
        let allowedCollectionItemIDs = try resolveCollectionFilterItemIDs(db, options: activeOptions)

        let rawItems = try loadTopLevelBibliographicItems(
            db,
            excludedItemIDs: trashedIDs,
            allowedItemIDs: allowedCollectionItemIDs,
            limit: activeOptions.maxItemsLimit
        )
        if rawItems.isEmpty { return [] }

        let targetItemIDs = Set(rawItems.map(\.itemID))
        let fieldsByItemID = try loadEAVFieldsByItemID(db, targetItemIDs: targetItemIDs)
        let creatorsByItemID = try loadCreatorsByItemID(db, targetItemIDs: targetItemIDs)
        let pdfAttachmentsByParentID = try loadPDFAttachmentsByParentItemID(
            db,
            targetParentIDs: targetItemIDs,
            excludedItemIDs: trashedIDs,
            zoteroDataDir: resolvedDataDir,
            linkedBaseDir: activeOptions.linkedAttachmentBaseDirectoryPath
        )
        let betterBibTeXKeysByItemID = loadOptionalBetterBibTeXKeys(db, targetItemIDs: targetItemIDs)

        var entries: [BibliographyEntry] = []
        entries.reserveCapacity(rawItems.count)
        var usedCiteKeys: Set<String> = []

        for rawItem in rawItems {
            let fieldMap = fieldsByItemID[rawItem.itemID] ?? [:]
            let authors = creatorsByItemID[rawItem.itemID] ?? []
            let pdfPath = pdfAttachmentsByParentID[rawItem.itemID]
            let bbtKey = betterBibTeXKeysByItemID[rawItem.itemID]

            let built = assembleBibliographyEntry(
                rawItem: rawItem,
                fieldMap: fieldMap,
                authors: authors,
                attachedPDFPath: pdfPath,
                betterBibTeXKey: bbtKey,
                evaluateFirewall: activeOptions.evaluateOfflineFirewall,
                usedCiteKeys: &usedCiteKeys
            )
            entries.append(built)
        }

        return entries
    }

    /// Searches a Zotero database by case-insensitive substring across title, author family name, venue, DOI, and arXiv ID.
    public func searchEntries(
        databasePath: String,
        query: String,
        options: ZoteroImportOptions? = nil
    ) throws -> [BibliographyEntry] {
        let allEntries = try importEntries(databasePath: databasePath, options: options)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return allEntries }

        return allEntries.filter { entry in
            if entry.citeKey.lowercased().contains(needle) { return true }
            if entry.title.lowercased().contains(needle) { return true }
            if entry.venue.lowercased().contains(needle) { return true }
            if let doi = entry.doi?.lowercased(), doi.contains(needle) { return true }
            if let arxiv = entry.arxivID?.lowercased(), arxiv.contains(needle) { return true }
            if let pmid = entry.pmid?.lowercased(), pmid.contains(needle) { return true }
            if entry.authors.contains(where: { $0.description.lowercased().contains(needle) }) {
                return true
            }
            return false
        }
    }

    // MARK: - Synthetic Zotero 6/7 Schema SQLite Builder for Deterministic Offline Testing

    /// Creates a complete Zotero 6/7 relational SQLite database on disk (`version`, `itemTypes`, `fields`, `creatorTypes`, `items`, `deletedItems`, `itemDataValues`, `itemData`, `creators`, `itemCreators`, `collections`, `collectionItems`, `itemAttachments`) populated with `entries`.
    @discardableResult
    public static func createSyntheticZoteroDatabase(
        at databasePath: String,
        entries: [BibliographyEntry],
        collectionName: String = "ScholarOS Synthetic Collection",
        createMockPDFAttachmentFiles: Bool = false
    ) throws -> URL {
        let dbURL = URL(fileURLWithPath: databasePath)
        let parentDir = dbURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: databasePath) {
            try FileManager.default.removeItem(atPath: databasePath)
        }

        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let openRC = sqlite3_open_v2(databasePath, &db, openFlags, nil)
        guard openRC == SQLITE_OK, let validDB = db else {
            let msg = db.flatMap { sqlite3_errmsg($0).map(String.init(cString:)) } ?? "Unable to create synthetic Zotero DB"
            if let db { sqlite3_close_v2(db) }
            throw ScholarOSError.sqliteError(code: openRC, message: msg)
        }
        defer { sqlite3_close_v2(validDB) }

        // Use DELETE journal mode so that on close zero `-wal`/`-shm` sidecar files remain, ensuring `?immutable=1` reads 100% of committed pages
        try execSQL(validDB, sql: "PRAGMA journal_mode = DELETE;")
        try execSQL(validDB, sql: "PRAGMA foreign_keys = ON;")
        try execSQL(validDB, sql: syntheticZoteroDDL)

        try execSQL(validDB, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try seedZoteroLookupTables(validDB)
            try populateSyntheticEntries(
                validDB,
                entries: entries,
                collectionName: collectionName,
                zoteroBaseDir: parentDir,
                createMockPDFs: createMockPDFAttachmentFiles
            )
            try execSQL(validDB, sql: "COMMIT;")
        } catch {
            _ = try? execSQL(validDB, sql: "ROLLBACK;")
            throw error
        }

        return dbURL
    }

    /// Creates an isolated temporary directory containing `zotero.sqlite` (and optional `storage/<KEY>/paper.pdf` attachments) for unit tests.
    public static func createTemporarySyntheticZoteroDatabase(
        entries: [BibliographyEntry],
        collectionName: String = "ScholarOS Test Corpus",
        createMockPDFAttachmentFiles: Bool = true
    ) throws -> URL {
        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholaros-zotero-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        let sqliteURL = tempFolder.appendingPathComponent("zotero.sqlite")
        return try createSyntheticZoteroDatabase(
            at: sqliteURL.path,
            entries: entries,
            collectionName: collectionName,
            createMockPDFAttachmentFiles: createMockPDFAttachmentFiles
        )
    }

    // MARK: - Private Read-Only SQLite Connection & Query Implementation

    private struct RawZoteroItemRow {
        let itemID: Int
        let key: String
        let typeName: String
        let libraryID: Int
    }

    private func openReadOnlyZoteroConnection(atPath path: String, immutable: Bool) throws -> OpaquePointer {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw ScholarOSError.fileNotFound(expandedPath)
        }

        var db: OpaquePointer?
        let rc: Int32

        if immutable {
            let uriString = makeImmutableSQLiteFileURI(forPath: expandedPath)
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
            rc = sqlite3_open_v2(uriString, &db, flags, nil)
        } else {
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            rc = sqlite3_open_v2(expandedPath, &db, flags, nil)
        }

        guard rc == SQLITE_OK, let validDB = db else {
            let detail = db.flatMap { sqlite3_errmsg($0).map(String.init(cString:)) } ?? "Unable to open Zotero SQLite database"
            if let db { sqlite3_close_v2(db) }
            throw ScholarOSError.sqliteError(code: rc, message: detail)
        }

        // Belt-and-suspenders engine guard: forbid any write statement even if SQLite flags were ever altered
        _ = sqlite3_exec(validDB, "PRAGMA query_only = ON;", nil, nil, nil)
        return validDB
    }

    /// Encodes a POSIX file path as an RFC 3986 SQLite URI (`file:///path/to/zotero.sqlite?immutable=1`), escaping `?`, `#`, and `%` per SQLite URI spec.
    private func makeImmutableSQLiteFileURI(forPath path: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(path.count + 24)
        for byte in path.utf8 {
            switch byte {
            case UInt8(ascii: "%"):
                escaped.append("%25")
            case UInt8(ascii: "?"):
                escaped.append("%3f")
            case UInt8(ascii: "#"):
                escaped.append("%23")
            case UInt8(ascii: " "):
                escaped.append("%20")
            default:
                escaped.append(Character(UnicodeScalar(byte)))
            }
        }
        if escaped.hasPrefix("/") {
            return "file://\(escaped)?immutable=1"
        }
        return "file:\(escaped)?immutable=1"
    }

    private func verifyCoreZoteroSchema(_ db: OpaquePointer) throws {
        let requiredTables = ["items", "itemTypes", "itemData", "itemDataValues", "creators", "itemCreators"]
        for table in requiredTables {
            if !tableExists(db, name: table) {
                throw ScholarOSError.sqliteError(
                    code: SQLITE_ERROR,
                    message: "Database is missing required Zotero 6/7 schema table '\(table)'."
                )
            }
        }
    }

    private func tableExists(_ db: OpaquePointer, name: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE (type = 'table' OR type = 'view') AND name = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, name, -1, transient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func loadDeletedItemIDs(_ db: OpaquePointer) throws -> Set<Int> {
        guard tableExists(db, name: "deletedItems") else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT itemID FROM deletedItems;", -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteFailure(db, context: "reading deletedItems")
        }
        defer { sqlite3_finalize(stmt) }
        var ids: Set<Int> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.insert(Int(sqlite3_column_int64(stmt, 0)))
        }
        return ids
    }

    private func loadCollections(
        _ db: OpaquePointer,
        excludedItemIDs: Set<Int>
    ) throws -> [ZoteroCollectionRecord] {
        guard tableExists(db, name: "collections") else { return [] }

        var directCounts: [Int: Int] = [:]
        if tableExists(db, name: "collectionItems") {
            var cStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT collectionID, itemID FROM collectionItems;", -1, &cStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(cStmt) }
                while sqlite3_step(cStmt) == SQLITE_ROW {
                    let cid = Int(sqlite3_column_int64(cStmt, 0))
                    let iid = Int(sqlite3_column_int64(cStmt, 1))
                    if !excludedItemIDs.contains(iid) {
                        directCounts[cid, default: 0] += 1
                    }
                }
            }
        }

        struct RawCol {
            let id: Int
            let key: String
            let name: String
            let parentID: Int?
        }

        var stmt: OpaquePointer?
        let sql = "SELECT collectionID, key, collectionName, parentCollectionID FROM collections ORDER BY collectionName ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteFailure(db, context: "loading Zotero collections")
        }
        defer { sqlite3_finalize(stmt) }

        var rawByID: [Int: RawCol] = [:]
        var orderedIDs: [Int] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cid = Int(sqlite3_column_int64(stmt, 0))
            let key = columnText(stmt, 1) ?? "COL\(cid)"
            let name = columnText(stmt, 2) ?? "Untitled Collection"
            let parentID: Int? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int64(stmt, 3))
            rawByID[cid] = RawCol(id: cid, key: key, name: name, parentID: parentID)
            orderedIDs.append(cid)
        }

        func buildBreadcrumb(for id: Int) -> String {
            var segments: [String] = []
            var visited: Set<Int> = []
            var cursor: Int? = id
            while let cur = cursor, !visited.contains(cur), let node = rawByID[cur] {
                visited.insert(cur)
                segments.insert(node.name, at: 0)
                cursor = node.parentID
            }
            return segments.joined(separator: " / ")
        }

        return orderedIDs.compactMap { cid in
            guard let raw = rawByID[cid] else { return nil }
            return ZoteroCollectionRecord(
                collectionID: raw.id,
                key: raw.key,
                name: raw.name,
                parentCollectionID: raw.parentID,
                fullBreadcrumbPath: buildBreadcrumb(for: cid),
                directItemCount: directCounts[cid] ?? 0
            )
        }
    }

    private func resolveCollectionFilterItemIDs(
        _ db: OpaquePointer,
        options: ZoteroImportOptions
    ) throws -> Set<Int>? {
        let keyFilter = options.collectionKeyFilter?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameFilter = options.collectionNameFilter?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (keyFilter != nil && !keyFilter!.isEmpty) || (nameFilter != nil && !nameFilter!.isEmpty) else {
            return nil
        }
        guard tableExists(db, name: "collections"), tableExists(db, name: "collectionItems") else {
            return []
        }

        let allCollections = try loadCollections(db, excludedItemIDs: [])
        var matchedIDs: Set<Int> = []
        for col in allCollections {
            if let kf = keyFilter, !kf.isEmpty, col.key.caseInsensitiveCompare(kf) == .orderedSame {
                matchedIDs.insert(col.collectionID)
            }
            if let nf = nameFilter, !nf.isEmpty,
               (col.name.localizedCaseInsensitiveContains(nf) || col.fullBreadcrumbPath.localizedCaseInsensitiveContains(nf)) {
                matchedIDs.insert(col.collectionID)
            }
        }
        if matchedIDs.isEmpty { return [] }

        // Include descendant sub-collections recursively
        var changed = true
        while changed {
            changed = false
            for col in allCollections {
                if let p = col.parentCollectionID, matchedIDs.contains(p), !matchedIDs.contains(col.collectionID) {
                    matchedIDs.insert(col.collectionID)
                    changed = true
                }
            }
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT collectionID, itemID FROM collectionItems;", -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteFailure(db, context: "filtering collectionItems")
        }
        defer { sqlite3_finalize(stmt) }

        var itemIDs: Set<Int> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cid = Int(sqlite3_column_int64(stmt, 0))
            let iid = Int(sqlite3_column_int64(stmt, 1))
            if matchedIDs.contains(cid) {
                itemIDs.insert(iid)
            }
        }
        return itemIDs
    }

    private func loadTopLevelBibliographicItems(
        _ db: OpaquePointer,
        excludedItemIDs: Set<Int>,
        allowedItemIDs: Set<Int>?,
        limit: Int?
    ) throws -> [RawZoteroItemRow] {
        let sql = """
            SELECT i.itemID, i.key, it.typeName, COALESCE(i.libraryID, 1)
            FROM items i
            JOIN itemTypes it ON it.itemTypeID = i.itemTypeID
            ORDER BY i.itemID ASC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteFailure(db, context: "querying Zotero items")
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [RawZoteroItemRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemID = Int(sqlite3_column_int64(stmt, 0))
            if excludedItemIDs.contains(itemID) { continue }
            if let allowed = allowedItemIDs, !allowed.contains(itemID) { continue }

            let key = columnText(stmt, 1) ?? "ZITEM\(itemID)"
            let typeName = columnText(stmt, 2) ?? "document"
            if Self.nonBibliographicItemTypes.contains(typeName) {
                continue
            }
            let libID = Int(sqlite3_column_int64(stmt, 3))
            rows.append(RawZoteroItemRow(itemID: itemID, key: key, typeName: typeName, libraryID: libID))
            if let maxLimit = limit, maxLimit > 0, rows.count >= maxLimit {
                break
            }
        }
        return rows
    }

    private func loadEAVFieldsByItemID(
        _ db: OpaquePointer,
        targetItemIDs: Set<Int>
    ) throws -> [Int: [String: String]] {
        // Zotero 6/7 uses `fieldsCombined` when custom fields exist, falling back to `fields`
        let fieldsTable = tableExists(db, name: "fieldsCombined") ? "fieldsCombined" : "fields"
        let sql = """
            SELECT id.itemID, f.fieldName, idv.value
            FROM itemData id
            JOIN \(fieldsTable) f ON f.fieldID = id.fieldID
            JOIN itemDataValues idv ON idv.valueID = id.valueID;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteFailure(db, context: "querying Zotero itemData EAV fields")
        }
        defer { sqlite3_finalize(stmt) }

        var map: [Int: [String: String]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemID = Int(sqlite3_column_int64(stmt, 0))
            guard targetItemIDs.contains(itemID) else { continue }
            guard let fieldName = columnText(stmt, 1),
                  let value = columnText(stmt, 2) else { continue }
            map[itemID, default: [:]][fieldName] = value
        }
        return map
    }

    private func loadCreatorsByItemID(
        _ db: OpaquePointer,
        targetItemIDs: Set<Int>
    ) throws -> [Int: [BibAuthor]] {
        let hasCreatorTypes = tableExists(db, name: "creatorTypes")
        let sql: String
        if hasCreatorTypes {
            sql = """
                SELECT ic.itemID, c.firstName, c.lastName, COALESCE(c.fieldMode, 0), ct.creatorType, ic.orderIndex
                FROM itemCreators ic
                JOIN creators c ON c.creatorID = ic.creatorID
                LEFT JOIN creatorTypes ct ON ct.creatorTypeID = ic.creatorTypeID
                ORDER BY ic.itemID ASC, ic.orderIndex ASC;
                """
        } else {
            sql = """
                SELECT ic.itemID, c.firstName, c.lastName, COALESCE(c.fieldMode, 0), 'author', ic.orderIndex
                FROM itemCreators ic
                JOIN creators c ON c.creatorID = ic.creatorID
                ORDER BY ic.itemID ASC, ic.orderIndex ASC;
                """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteFailure(db, context: "querying Zotero creators")
        }
        defer { sqlite3_finalize(stmt) }

        var primaryAuthorsByItem: [Int: [BibAuthor]] = [:]
        var fallbackEditorsByItem: [Int: [BibAuthor]] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemID = Int(sqlite3_column_int64(stmt, 0))
            guard targetItemIDs.contains(itemID) else { continue }

            let firstName = (columnText(stmt, 1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lastName = (columnText(stmt, 2) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fieldMode = Int(sqlite3_column_int64(stmt, 3))
            let role = (columnText(stmt, 4) ?? "author").lowercased()

            guard !lastName.isEmpty || !firstName.isEmpty else { continue }

            // `fieldMode == 1` in Zotero denotes single-field corporate/institutional creator stored in `lastName`
            let author: BibAuthor
            if fieldMode == 1 {
                author = BibAuthor(givenName: "", familyName: lastName.isEmpty ? firstName : lastName)
            } else {
                author = BibAuthor(givenName: firstName, familyName: lastName)
            }

            if role == "author" || role == "inventor" || role == "programmer" || role == "podcaster" || role == "presenter" {
                primaryAuthorsByItem[itemID, default: []].append(author)
            } else if role == "editor" || role == "serieseditor" || role == "bookauthor" {
                fallbackEditorsByItem[itemID, default: []].append(author)
            } else {
                primaryAuthorsByItem[itemID, default: []].append(author)
            }
        }

        var resolved: [Int: [BibAuthor]] = primaryAuthorsByItem
        for (itemID, editors) in fallbackEditorsByItem where resolved[itemID] == nil {
            resolved[itemID] = editors
        }
        return resolved
    }

    private func loadPDFAttachmentsByParentItemID(
        _ db: OpaquePointer,
        targetParentIDs: Set<Int>,
        excludedItemIDs: Set<Int>,
        zoteroDataDir: String,
        linkedBaseDir: String?
    ) throws -> [Int: String] {
        guard tableExists(db, name: "itemAttachments") else { return [:] }

        let sql = """
            SELECT ia.itemID, ia.parentItemID, i.key, COALESCE(ia.contentType, ''), COALESCE(ia.path, '')
            FROM itemAttachments ia
            JOIN items i ON i.itemID = ia.itemID
            WHERE ia.parentItemID IS NOT NULL
            ORDER BY ia.itemID ASC;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteFailure(db, context: "querying Zotero itemAttachments")
        }
        defer { sqlite3_finalize(stmt) }

        var pdfByParent: [Int: String] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let attachmentItemID = Int(sqlite3_column_int64(stmt, 0))
            if excludedItemIDs.contains(attachmentItemID) { continue }

            let parentID = Int(sqlite3_column_int64(stmt, 1))
            guard targetParentIDs.contains(parentID), pdfByParent[parentID] == nil else { continue }

            let attachmentKey = columnText(stmt, 2) ?? ""
            let contentType = (columnText(stmt, 3) ?? "").lowercased()
            let rawPath = (columnText(stmt, 4) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            let isPDF = contentType == "application/pdf" || rawPath.lowercased().hasSuffix(".pdf")
            guard isPDF, !rawPath.isEmpty else { continue }

            let resolvedPath = resolveZoteroAttachmentPath(
                rawPath: rawPath,
                attachmentItemKey: attachmentKey,
                zoteroDataDir: zoteroDataDir,
                linkedBaseDir: linkedBaseDir
            )
            pdfByParent[parentID] = resolvedPath
        }

        return pdfByParent
    }

    private func loadOptionalBetterBibTeXKeys(
        _ db: OpaquePointer,
        targetItemIDs: Set<Int>
    ) -> [Int: String] {
        // Support Better BibTeX `citationkey` table if co-located in SQLite
        guard tableExists(db, name: "citationkey") else { return [:] }
        var stmt: OpaquePointer?
        let sql = "SELECT itemID, citationKey FROM citationkey;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var map: [Int: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemID = Int(sqlite3_column_int64(stmt, 0))
            if targetItemIDs.contains(itemID), let key = columnText(stmt, 1), !key.isEmpty {
                map[itemID] = key
            }
        }
        return map
    }

    // MARK: - Zotero Item Assembly & `extra` Metadata Parsing

    private func assembleBibliographyEntry(
        rawItem: RawZoteroItemRow,
        fieldMap: [String: String],
        authors: [BibAuthor],
        attachedPDFPath: String?,
        betterBibTeXKey: String?,
        evaluateFirewall: Bool,
        usedCiteKeys: inout Set<String>
    ) -> BibliographyEntry {
        let extraKV = parseZoteroExtraKeyValues(fieldMap["extra"])

        let title = nonEmpty(fieldMap["title"])
            ?? nonEmpty(fieldMap["caseName"])
            ?? nonEmpty(fieldMap["nameOfAct"])
            ?? "Untitled"

        let kind = mapZoteroItemType(rawItem.typeName, archive: fieldMap["archive"] ?? fieldMap["repository"])

        let venue = nonEmpty(fieldMap["publicationTitle"])
            ?? nonEmpty(fieldMap["proceedingsTitle"])
            ?? nonEmpty(fieldMap["bookTitle"])
            ?? nonEmpty(fieldMap["university"])
            ?? nonEmpty(fieldMap["institution"])
            ?? nonEmpty(fieldMap["repository"])
            ?? nonEmpty(fieldMap["blogTitle"])
            ?? nonEmpty(fieldMap["websiteTitle"])
            ?? ""

        let publisher = nonEmpty(fieldMap["publisher"])
            ?? nonEmpty(fieldMap["university"])
            ?? nonEmpty(fieldMap["institution"])

        let year = extractZoteroYear(from: fieldMap["date"] ?? extraKV["issued"])
        let volume = nonEmpty(fieldMap["volume"])
        let issue = nonEmpty(fieldMap["issue"]) ?? nonEmpty(fieldMap["number"])
        let pages = nonEmpty(fieldMap["pages"])

        let doi = ReferenceIdentifierNormalizer.normalizeDOI(
            nonEmpty(fieldMap["DOI"]) ?? extraKV["doi"]
        )

        var arxivID = ReferenceIdentifierNormalizer.normalizeArXivID(
            extraKV["arxiv"] ?? extraKV["arxivid"],
            stripVersion: false
        )
        if arxivID == nil,
           let archive = fieldMap["archive"]?.lowercased(),
           archive.contains("arxiv"),
           let loc = nonEmpty(fieldMap["archiveLocation"]) {
            arxivID = ReferenceIdentifierNormalizer.normalizeArXivID(loc, stripVersion: false)
        }
        if arxivID == nil, let url = fieldMap["url"], url.lowercased().contains("arxiv.org/") {
            arxivID = ReferenceIdentifierNormalizer.normalizeArXivID(url, stripVersion: false)
        }

        let pmid = ReferenceIdentifierNormalizer.normalizePMID(extraKV["pmid"])
        let url = nonEmpty(fieldMap["url"])
        let abstractText = nonEmpty(fieldMap["abstractNote"])

        // Enrich authors with ORCIDs stored in `extra` (`ORCID: 0000-...`) if single-author or indexed
        let enrichedAuthors: [BibAuthor] = {
            if authors.count == 1, authors[0].orcid == nil, let singleORCID = extraKV["orcid"] {
                return [BibAuthor(givenName: authors[0].givenName, familyName: authors[0].familyName, orcid: singleORCID)]
            }
            return authors
        }()

        var provisional = BibliographyEntry(
            citeKey: "",
            kind: kind,
            title: title,
            authors: enrichedAuthors,
            year: year,
            venue: venue,
            publisher: publisher,
            volume: volume,
            issue: issue,
            pages: pages,
            doi: doi,
            arxivID: arxivID,
            pmid: pmid,
            url: url,
            abstractText: abstractText,
            attachedPDFPath: attachedPDFPath
        )

        let preferredKey = nonEmpty(betterBibTeXKey)
            ?? nonEmpty(extraKV["citation key"])
            ?? nonEmpty(extraKV["bibtex"])

        let resolvedKey: String
        if let preferredKey, !usedCiteKeys.contains(preferredKey) {
            resolvedKey = preferredKey.filter { !$0.isWhitespace && $0 != "," }
        } else {
            resolvedKey = BibTeXCodec.generateCiteKey(for: provisional, existingKeys: usedCiteKeys)
        }
        usedCiteKeys.insert(resolvedKey)

        provisional = BibliographyEntry(
            citeKey: resolvedKey,
            kind: provisional.kind,
            title: provisional.title,
            authors: provisional.authors,
            year: provisional.year,
            venue: provisional.venue,
            publisher: provisional.publisher,
            volume: provisional.volume,
            issue: provisional.issue,
            pages: provisional.pages,
            doi: provisional.doi,
            arxivID: provisional.arxivID,
            pmid: provisional.pmid,
            url: provisional.url,
            abstractText: provisional.abstractText,
            attachedPDFPath: provisional.attachedPDFPath
        )

        if evaluateFirewall {
            return firewall.evaluate(provisional).auditedEntry
        }
        return provisional
    }

    private func resolveZoteroAttachmentPath(
        rawPath: String,
        attachmentItemKey: String,
        zoteroDataDir: String,
        linkedBaseDir: String?
    ) -> String {
        if rawPath.hasPrefix("storage:") {
            let relativeFilename = String(rawPath.dropFirst("storage:".count))
            return URL(fileURLWithPath: zoteroDataDir)
                .appendingPathComponent("storage", isDirectory: true)
                .appendingPathComponent(attachmentItemKey, isDirectory: true)
                .appendingPathComponent(relativeFilename)
                .path
        }
        if rawPath.hasPrefix("attachments:") {
            let rel = String(rawPath.dropFirst("attachments:".count))
            let base = linkedBaseDir ?? zoteroDataDir
            return URL(fileURLWithPath: base).appendingPathComponent(rel).path
        }
        if rawPath.hasPrefix("file://"), let url = URL(string: rawPath), url.isFileURL {
            return url.path
        }
        return rawPath
    }

    private func parseZoteroExtraKeyValues(_ rawExtra: String?) -> [String: String] {
        guard let rawExtra, !rawExtra.isEmpty else { return [:] }
        var result: [String: String] = [:]
        let lines = rawExtra
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map(String.init)

        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && !val.isEmpty {
                result[key] = val
            }
        }
        return result
    }

    private func mapZoteroItemType(_ zoteroType: String, archive: String?) -> BibEntryKind {
        switch zoteroType {
        case "journalArticle", "magazineArticle", "newspaperArticle":
            if let archive = archive?.lowercased(), archive.contains("arxiv") {
                return .preprint
            }
            return .article
        case "conferencePaper":
            return .inproceedings
        case "book", "dictionaryEntry", "encyclopediaArticle":
            return .book
        case "bookSection":
            return .incollection
        case "thesis":
            return .phdthesis
        case "report", "standard", "statute", "patent":
            return .techreport
        case "preprint", "manuscript":
            return .preprint
        default:
            return .misc
        }
    }

    private func extractZoteroYear(from rawDate: String?) -> Int? {
        guard let rawDate, !rawDate.isEmpty else { return nil }
        // Zotero SQLite stores `2017-12-04 2017-12-04` (parsed ISO prefix + display suffix) or `2017`
        let chars = Array(rawDate)
        if chars.count >= 4 {
            for i in 0...(chars.count - 4) {
                let slice = chars[i..<(i + 4)]
                if slice.allSatisfy(\.isNumber), let yr = Int(String(slice)), (1000...2100).contains(yr) {
                    return yr
                }
            }
        }
        return nil
    }

    private func queryOptionalInt(_ db: OpaquePointer, sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, col) else {
            return nil
        }
        return String(cString: ptr)
    }

    private func sqliteFailure(_ db: OpaquePointer, context: String) -> ScholarOSError {
        let code = sqlite3_errcode(db)
        let msg = sqlite3_errmsg(db).map(String.init(cString:)) ?? "SQLite error"
        return .sqliteError(code: code, message: "ZoteroSQLiteReadBridge (\(context)): \(msg)")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let t = value?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return nil
        }
        return t
    }

    // MARK: - Synthetic Zotero 6/7 DDL & Data Seeding Implementation

    private static let syntheticZoteroDDL = """
        CREATE TABLE version (
            schema TEXT PRIMARY KEY,
            version INTEGER NOT NULL
        );

        CREATE TABLE itemTypes (
            itemTypeID INTEGER PRIMARY KEY,
            typeName TEXT NOT NULL UNIQUE,
            custom INTEGER DEFAULT 0
        );

        CREATE TABLE fields (
            fieldID INTEGER PRIMARY KEY,
            fieldName TEXT NOT NULL UNIQUE
        );

        CREATE TABLE creatorTypes (
            creatorTypeID INTEGER PRIMARY KEY,
            creatorType TEXT NOT NULL UNIQUE
        );

        CREATE TABLE items (
            itemID INTEGER PRIMARY KEY,
            itemTypeID INTEGER NOT NULL REFERENCES itemTypes(itemTypeID),
            dateAdded TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            dateModified TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            clientDateModified TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            libraryID INTEGER NOT NULL DEFAULT 1,
            key TEXT NOT NULL UNIQUE,
            version INTEGER NOT NULL DEFAULT 1,
            synced INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE deletedItems (
            itemID INTEGER PRIMARY KEY REFERENCES items(itemID),
            dateDeleted TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE itemDataValues (
            valueID INTEGER PRIMARY KEY,
            value TEXT NOT NULL UNIQUE
        );

        CREATE TABLE itemData (
            itemID INTEGER NOT NULL REFERENCES items(itemID),
            fieldID INTEGER NOT NULL REFERENCES fields(fieldID),
            valueID INTEGER NOT NULL REFERENCES itemDataValues(valueID),
            PRIMARY KEY (itemID, fieldID)
        );

        CREATE TABLE creators (
            creatorID INTEGER PRIMARY KEY,
            firstName TEXT NOT NULL DEFAULT '',
            lastName TEXT NOT NULL DEFAULT '',
            fieldMode INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE itemCreators (
            itemID INTEGER NOT NULL REFERENCES items(itemID),
            creatorID INTEGER NOT NULL REFERENCES creators(creatorID),
            creatorTypeID INTEGER NOT NULL REFERENCES creatorTypes(creatorTypeID),
            orderIndex INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (itemID, orderIndex)
        );

        CREATE TABLE collections (
            collectionID INTEGER PRIMARY KEY,
            collectionName TEXT NOT NULL,
            parentCollectionID INTEGER REFERENCES collections(collectionID),
            clientDateModified TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            libraryID INTEGER NOT NULL DEFAULT 1,
            key TEXT NOT NULL UNIQUE,
            version INTEGER NOT NULL DEFAULT 1,
            synced INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE collectionItems (
            collectionID INTEGER NOT NULL REFERENCES collections(collectionID),
            itemID INTEGER NOT NULL REFERENCES items(itemID),
            orderIndex INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (collectionID, itemID)
        );

        CREATE TABLE itemAttachments (
            itemID INTEGER PRIMARY KEY REFERENCES items(itemID),
            parentItemID INTEGER REFERENCES items(itemID),
            linkMode INTEGER NOT NULL DEFAULT 0,
            contentType TEXT,
            charsetID INTEGER,
            path TEXT,
            syncState INTEGER DEFAULT 0,
            storageModTime INTEGER,
            storageHash TEXT
        );
        """

    private static let zoteroTypeIDByName: [(Int, String)] = [
        (1, "note"),
        (2, "attachment"),
        (3, "journalArticle"),
        (4, "conferencePaper"),
        (5, "book"),
        (6, "bookSection"),
        (7, "thesis"),
        (8, "report"),
        (9, "preprint"),
        (10, "document")
    ]

    private static let zoteroFieldIDByName: [(Int, String)] = [
        (1, "title"),
        (2, "date"),
        (3, "publicationTitle"),
        (4, "proceedingsTitle"),
        (5, "bookTitle"),
        (6, "publisher"),
        (7, "university"),
        (8, "institution"),
        (9, "volume"),
        (10, "issue"),
        (11, "pages"),
        (12, "DOI"),
        (13, "url"),
        (14, "abstractNote"),
        (15, "extra"),
        (16, "archive"),
        (17, "archiveLocation")
    ]

    private static func seedZoteroLookupTables(_ db: OpaquePointer) throws {
        try execSQL(db, sql: "INSERT INTO version (schema, version) VALUES ('userdata', 120);")

        for (id, name) in zoteroTypeIDByName {
            try runParameterizedInsert(
                db,
                sql: "INSERT INTO itemTypes (itemTypeID, typeName) VALUES (?, ?);",
                bindings: [.int(id), .text(name)]
            )
        }

        for (id, name) in zoteroFieldIDByName {
            try runParameterizedInsert(
                db,
                sql: "INSERT INTO fields (fieldID, fieldName) VALUES (?, ?);",
                bindings: [.int(id), .text(name)]
            )
        }

        try runParameterizedInsert(
            db,
            sql: "INSERT INTO creatorTypes (creatorTypeID, creatorType) VALUES (1, 'author'), (2, 'editor');"
        )
    }

    private static func populateSyntheticEntries(
        _ db: OpaquePointer,
        entries: [BibliographyEntry],
        collectionName: String,
        zoteroBaseDir: URL,
        createMockPDFs: Bool
    ) throws {
        let collectionID = 1
        try runParameterizedInsert(
            db,
            sql: "INSERT INTO collections (collectionID, collectionName, parentCollectionID, key) VALUES (?, ?, NULL, ?);",
            bindings: [.int(collectionID), .text(collectionName), .text("SCOL0001")]
        )

        var nextItemID = 100
        var nextValueID = 1
        var valueIDByText: [String: Int] = [:]
        var nextCreatorID = 1

        func internValue(_ text: String) throws -> Int {
            if let existing = valueIDByText[text] {
                return existing
            }
            let vid = nextValueID
            nextValueID += 1
            try runParameterizedInsert(
                db,
                sql: "INSERT INTO itemDataValues (valueID, value) VALUES (?, ?);",
                bindings: [.int(vid), .text(text)]
            )
            valueIDByText[text] = vid
            return vid
        }

        func setItemField(itemID: Int, fieldID: Int, value: String?) throws {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
                return
            }
            let vid = try internValue(v)
            try runParameterizedInsert(
                db,
                sql: "INSERT INTO itemData (itemID, fieldID, valueID) VALUES (?, ?, ?);",
                bindings: [.int(itemID), .int(fieldID), .int(vid)]
            )
        }

        for (orderIndex, entry) in entries.enumerated() {
            let itemID = nextItemID
            nextItemID += 1

            let zoteroTypeID = mapEntryKindToZoteroTypeID(entry.kind)
            let itemKey = String(format: "ZKEY%04d", orderIndex + 1)

            try runParameterizedInsert(
                db,
                sql: "INSERT INTO items (itemID, itemTypeID, key) VALUES (?, ?, ?);",
                bindings: [.int(itemID), .int(zoteroTypeID), .text(itemKey)]
            )

            try runParameterizedInsert(
                db,
                sql: "INSERT INTO collectionItems (collectionID, itemID, orderIndex) VALUES (?, ?, ?);",
                bindings: [.int(collectionID), .int(itemID), .int(orderIndex)]
            )

            try setItemField(itemID: itemID, fieldID: 1, value: entry.title)
            if let yr = entry.year {
                try setItemField(itemID: itemID, fieldID: 2, value: "\(yr)-01-01 \(yr)")
            }

            switch entry.kind {
            case .inproceedings:
                try setItemField(itemID: itemID, fieldID: 4, value: entry.venue)
            case .incollection:
                try setItemField(itemID: itemID, fieldID: 5, value: entry.venue)
            case .phdthesis:
                try setItemField(itemID: itemID, fieldID: 7, value: entry.venue)
            case .techreport:
                try setItemField(itemID: itemID, fieldID: 8, value: entry.venue)
            default:
                try setItemField(itemID: itemID, fieldID: 3, value: entry.venue)
            }

            try setItemField(itemID: itemID, fieldID: 6, value: entry.publisher)
            try setItemField(itemID: itemID, fieldID: 9, value: entry.volume)
            try setItemField(itemID: itemID, fieldID: 10, value: entry.issue)
            try setItemField(itemID: itemID, fieldID: 11, value: entry.pages)
            try setItemField(itemID: itemID, fieldID: 12, value: entry.doi)
            try setItemField(itemID: itemID, fieldID: 13, value: entry.url)
            try setItemField(itemID: itemID, fieldID: 14, value: entry.abstractText)

            var extraLines: [String] = ["Citation Key: \(entry.citeKey)"]
            if let arxiv = entry.arxivID, !arxiv.isEmpty {
                extraLines.append("arXiv: \(arxiv)")
                try setItemField(itemID: itemID, fieldID: 16, value: "arXiv")
                try setItemField(itemID: itemID, fieldID: 17, value: arxiv)
            }
            if let pmid = entry.pmid, !pmid.isEmpty {
                extraLines.append("PMID: \(pmid)")
            }
            if entry.authors.count == 1, let orcid = entry.authors[0].orcid, !orcid.isEmpty {
                extraLines.append("ORCID: \(orcid)")
            }
            try setItemField(itemID: itemID, fieldID: 15, value: extraLines.joined(separator: "\n"))

            // Insert creators
            for (cIdx, author) in entry.authors.enumerated() {
                let creatorID = nextCreatorID
                nextCreatorID += 1
                let fieldMode = author.givenName.isEmpty ? 1 : 0
                try runParameterizedInsert(
                    db,
                    sql: "INSERT INTO creators (creatorID, firstName, lastName, fieldMode) VALUES (?, ?, ?, ?);",
                    bindings: [.int(creatorID), .text(author.givenName), .text(author.familyName), .int(fieldMode)]
                )
                try runParameterizedInsert(
                    db,
                    sql: "INSERT INTO itemCreators (itemID, creatorID, creatorTypeID, orderIndex) VALUES (?, ?, 1, ?);",
                    bindings: [.int(itemID), .int(creatorID), .int(cIdx)]
                )
            }

            // Insert PDF attachment if entry has attachedPDFPath or createMockPDFs is requested
            if entry.attachedPDFPath != nil || createMockPDFs {
                let attachItemID = nextItemID
                nextItemID += 1
                let attachKey = String(format: "ATTK%04d", orderIndex + 1)

                try runParameterizedInsert(
                    db,
                    sql: "INSERT INTO items (itemID, itemTypeID, key) VALUES (?, 2, ?);",
                    bindings: [.int(attachItemID), .text(attachKey)]
                )

                let attachmentStoragePath: String
                if let explicitPath = entry.attachedPDFPath, !explicitPath.isEmpty, !createMockPDFs {
                    attachmentStoragePath = explicitPath
                } else {
                    let filename = "\(entry.citeKey).pdf"
                    attachmentStoragePath = "storage:\(filename)"
                    if createMockPDFs {
                        let storageDir = zoteroBaseDir
                            .appendingPathComponent("storage", isDirectory: true)
                            .appendingPathComponent(attachKey, isDirectory: true)
                        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
                        let pdfFileURL = storageDir.appendingPathComponent(filename)
                        let minimalPDFBytes = Data("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\n%%EOF\n".utf8)
                        try minimalPDFBytes.write(to: pdfFileURL)
                    }
                }

                try runParameterizedInsert(
                    db,
                    sql: "INSERT INTO itemAttachments (itemID, parentItemID, linkMode, contentType, path) VALUES (?, ?, 0, 'application/pdf', ?);",
                    bindings: [.int(attachItemID), .int(itemID), .text(attachmentStoragePath)]
                )
            }
        }
    }

    private static func mapEntryKindToZoteroTypeID(_ kind: BibEntryKind) -> Int {
        switch kind {
        case .article: return 3
        case .inproceedings: return 4
        case .book: return 5
        case .incollection: return 6
        case .phdthesis: return 7
        case .techreport: return 8
        case .preprint: return 9
        case .misc: return 10
        }
    }

    private enum SQLiteBindValue {
        case int(Int)
        case text(String)
    }

    @discardableResult
    private static func execSQL(_ db: OpaquePointer, sql: String) throws -> Int32 {
        var errMsgPtr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsgPtr)
        if rc != SQLITE_OK {
            let message = errMsgPtr.map { String(cString: $0) } ?? "SQLite execution failure"
            if let errMsgPtr { sqlite3_free(errMsgPtr) }
            throw ScholarOSError.sqliteError(code: rc, message: message)
        }
        return rc
    }

    private static func runParameterizedInsert(
        _ db: OpaquePointer,
        sql: String,
        bindings: [SQLiteBindValue] = []
    ) throws {
        var stmt: OpaquePointer?
        let prepRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepRC == SQLITE_OK, let validStmt = stmt else {
            let msg = sqlite3_errmsg(db).map(String.init(cString:)) ?? "SQLite prepare failure"
            throw ScholarOSError.sqliteError(code: prepRC, message: msg)
        }
        defer { sqlite3_finalize(validStmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (zeroIdx, binding) in bindings.enumerated() {
            let paramIndex = Int32(zeroIdx + 1)
            let brc: Int32
            switch binding {
            case .int(let value):
                brc = sqlite3_bind_int64(validStmt, paramIndex, sqlite3_int64(value))
            case .text(let value):
                brc = sqlite3_bind_text(validStmt, paramIndex, value, -1, transient)
            }
            if brc != SQLITE_OK {
                throw ScholarOSError.sqliteError(code: brc, message: "Failed binding SQLite parameter #\(paramIndex)")
            }
        }

        let stepRC = sqlite3_step(validStmt)
        guard stepRC == SQLITE_DONE || stepRC == SQLITE_ROW else {
            let msg = sqlite3_errmsg(db).map(String.init(cString:)) ?? "SQLite step failure"
            throw ScholarOSError.sqliteError(code: stepRC, message: msg)
        }
    }
}
