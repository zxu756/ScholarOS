import Foundation
import SQLite3
import ScholarModels

// MARK: - SQLite FTS5 BM25 Local PDF Passage Index (M4 Citation-Key-Isolated & CJK Bigram Enabled)

private let SQLITE_TRANSIENT_BRIDGE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class FTS5ProvenanceIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?

    public init(sqliteFileURL: URL? = nil) throws {
        let path = sqliteFileURL?.path ?? ":memory:"
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw ScholarOSError.sqliteError(code: rc, message: msg)
        }
        self.db = opened
        try bootstrapSchema()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func bootstrapSchema() throws {
        let ddl = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;

        CREATE TABLE IF NOT EXISTS pdf_passages (
            passage_id TEXT PRIMARY KEY,
            cite_key TEXT NOT NULL,
            pdf_file_name TEXT NOT NULL,
            section_title TEXT NOT NULL,
            column_index INTEGER NOT NULL,
            reading_seq INTEGER NOT NULL,
            page_index INTEGER NOT NULL,
            bbox_x REAL NOT NULL,
            bbox_y REAL NOT NULL,
            bbox_w REAL NOT NULL,
            bbox_h REAL NOT NULL,
            passage_text TEXT NOT NULL,
            chunk_kind TEXT NOT NULL DEFAULT 'body'
        );
        CREATE INDEX IF NOT EXISTS idx_pdf_passages_cite ON pdf_passages(cite_key);

        CREATE VIRTUAL TABLE IF NOT EXISTS pdf_passages_fts USING fts5(
            passage_id UNINDEXED,
            section_title,
            passage_text,
            cjk_tokens,
            tokenize = 'porter unicode61'
        );
        """
        try executeRaw(ddl)
        try ensureChunkKindColumnExists()
    }

    private func ensureChunkKindColumnExists() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(pdf_passages);", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        var hasChunkKind = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let colNamePtr = sqlite3_column_text(stmt, 1) {
                if String(cString: colNamePtr) == "chunk_kind" {
                    hasChunkKind = true
                    break
                }
            }
        }
        if !hasChunkKind {
            try executeUnlocked("ALTER TABLE pdf_passages ADD COLUMN chunk_kind TEXT NOT NULL DEFAULT 'body';")
        }
    }

    public func indexPassages(_ passages: [PDFPassageChunk]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let delMeta = "DELETE FROM pdf_passages WHERE passage_id = ?1;"
            let delFTS = "DELETE FROM pdf_passages_fts WHERE passage_id = ?1;"
            let insMeta = """
            INSERT INTO pdf_passages (
                passage_id, cite_key, pdf_file_name, section_title, column_index, reading_seq,
                page_index, bbox_x, bbox_y, bbox_w, bbox_h, passage_text, chunk_kind
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13);
            """
            let insFTS = """
            INSERT INTO pdf_passages_fts (passage_id, section_title, passage_text, cjk_tokens)
            VALUES (?1, ?2, ?3, ?4);
            """

            for chunk in passages {
                try runStatement(db: db, sql: delMeta) { stmt in
                    sqlite3_bind_text(stmt, 1, chunk.id, -1, SQLITE_TRANSIENT_BRIDGE)
                }
                try runStatement(db: db, sql: delFTS) { stmt in
                    sqlite3_bind_text(stmt, 1, chunk.id, -1, SQLITE_TRANSIENT_BRIDGE)
                }
                try runStatement(db: db, sql: insMeta) { stmt in
                    sqlite3_bind_text(stmt, 1, chunk.id, -1, SQLITE_TRANSIENT_BRIDGE)
                    sqlite3_bind_text(stmt, 2, chunk.citeKey, -1, SQLITE_TRANSIENT_BRIDGE)
                    sqlite3_bind_text(stmt, 3, chunk.pdfFileName, -1, SQLITE_TRANSIENT_BRIDGE)
                    sqlite3_bind_text(stmt, 4, chunk.sectionTitle, -1, SQLITE_TRANSIENT_BRIDGE)
                    sqlite3_bind_int(stmt, 5, Int32(chunk.columnIndex))
                    sqlite3_bind_int(stmt, 6, Int32(chunk.readingSequence))
                    sqlite3_bind_int(stmt, 7, Int32(chunk.boundingBox.pageIndex))
                    sqlite3_bind_double(stmt, 8, chunk.boundingBox.x)
                    sqlite3_bind_double(stmt, 9, chunk.boundingBox.y)
                    sqlite3_bind_double(stmt, 10, chunk.boundingBox.width)
                    sqlite3_bind_double(stmt, 11, chunk.boundingBox.height)
                    sqlite3_bind_text(stmt, 12, chunk.passageText, -1, SQLITE_TRANSIENT_BRIDGE)
                    sqlite3_bind_text(stmt, 13, chunk.kind.rawValue, -1, SQLITE_TRANSIENT_BRIDGE)
                }

                // Header and footer margin furniture never enter the searchable FTS5 index
                if !chunk.kind.isHeaderOrFooter {
                    let cjkJoined = EvidenceLocatorAndNumericChecker
                        .extractCJKTerms(from: chunk.sectionTitle + " " + chunk.passageText)
                        .joined(separator: " ")
                    try runStatement(db: db, sql: insFTS) { stmt in
                        sqlite3_bind_text(stmt, 1, chunk.id, -1, SQLITE_TRANSIENT_BRIDGE)
                        sqlite3_bind_text(stmt, 2, chunk.sectionTitle, -1, SQLITE_TRANSIENT_BRIDGE)
                        sqlite3_bind_text(stmt, 3, chunk.passageText, -1, SQLITE_TRANSIENT_BRIDGE)
                        sqlite3_bind_text(stmt, 4, cjkJoined, -1, SQLITE_TRANSIENT_BRIDGE)
                    }
                }
            }
            try executeUnlocked("COMMIT;")
        } catch {
            try? executeUnlocked("ROLLBACK;")
            throw error
        }
    }

    public func passageCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pdf_passages;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    public func searchPassages(
        query: String,
        citeKeyFilter: String? = nil,
        limit: Int = 8
    ) throws -> [(chunk: PDFPassageChunk, bm25Magnitude: Double)] {
        let terms = Self.buildFTS5MatchExpression(from: query)
        guard !terms.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        let sql: String
        if citeKeyFilter != nil {
            sql = """
            SELECT m.passage_id, m.cite_key, m.pdf_file_name, m.section_title, m.column_index, m.reading_seq,
                   m.page_index, m.bbox_x, m.bbox_y, m.bbox_w, m.bbox_h, m.passage_text, m.chunk_kind,
                   (-bm25(pdf_passages_fts, 0.0, 1.5, 3.0, 3.0)) AS rank_score
            FROM pdf_passages_fts
            JOIN pdf_passages m ON m.passage_id = pdf_passages_fts.passage_id
            WHERE pdf_passages_fts MATCH ?1
              AND m.cite_key = ?2
              AND m.chunk_kind NOT IN ('header', 'footer')
            ORDER BY rank_score DESC
            LIMIT ?3;
            """
        } else {
            sql = """
            SELECT m.passage_id, m.cite_key, m.pdf_file_name, m.section_title, m.column_index, m.reading_seq,
                   m.page_index, m.bbox_x, m.bbox_y, m.bbox_w, m.bbox_h, m.passage_text, m.chunk_kind,
                   (-bm25(pdf_passages_fts, 0.0, 1.5, 3.0, 3.0)) AS rank_score
            FROM pdf_passages_fts
            JOIN pdf_passages m ON m.passage_id = pdf_passages_fts.passage_id
            WHERE pdf_passages_fts MATCH ?1
              AND m.chunk_kind NOT IN ('header', 'footer')
            ORDER BY rank_score DESC
            LIMIT ?2;
            """
        }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ScholarOSError.sqliteError(code: rc, message: msg)
        }
        defer { sqlite3_finalize(prepared) }

        sqlite3_bind_text(prepared, 1, terms, -1, SQLITE_TRANSIENT_BRIDGE)
        if let citeKeyFilter {
            sqlite3_bind_text(prepared, 2, citeKeyFilter, -1, SQLITE_TRANSIENT_BRIDGE)
            sqlite3_bind_int(prepared, 3, Int32(max(1, limit)))
        } else {
            sqlite3_bind_int(prepared, 2, Int32(max(1, limit)))
        }

        var hits: [(PDFPassageChunk, Double)] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            let chunk = Self.decodeChunkRow(prepared)
            let score = max(0.01, sqlite3_column_double(prepared, 13))
            hits.append((chunk, score))
        }
        return hits
    }

    internal func loadSearchablePassages(citeKeyFilter: String? = nil) throws -> [PDFPassageChunk] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        let sql: String
        if citeKeyFilter != nil {
            sql = """
            SELECT passage_id, cite_key, pdf_file_name, section_title, column_index, reading_seq,
                   page_index, bbox_x, bbox_y, bbox_w, bbox_h, passage_text, chunk_kind
            FROM pdf_passages
            WHERE cite_key = ?1 AND chunk_kind NOT IN ('header', 'footer')
            ORDER BY reading_seq ASC;
            """
        } else {
            sql = """
            SELECT passage_id, cite_key, pdf_file_name, section_title, column_index, reading_seq,
                   page_index, bbox_x, bbox_y, bbox_w, bbox_h, passage_text, chunk_kind
            FROM pdf_passages
            WHERE chunk_kind NOT IN ('header', 'footer')
            ORDER BY reading_seq ASC;
            """
        }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            throw ScholarOSError.sqliteError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(prepared) }

        if let citeKeyFilter {
            sqlite3_bind_text(prepared, 1, citeKeyFilter, -1, SQLITE_TRANSIENT_BRIDGE)
        }

        var chunks: [PDFPassageChunk] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            chunks.append(Self.decodeChunkRow(prepared))
        }
        return chunks
    }

    /// Unified M4 entry point on `FTS5ProvenanceIndex`: locates candidate passages meeting the majority keyword threshold
    /// and checks explicit `<number + unit/classifier/noun>` bindings. Replaces legacy `verifyClaimProvenance`.
    public func locateClaimEvidence(
        claim: String,
        citeKeyFilter: String? = nil,
        pdfFileName: String? = nil,
        topK: Int = 3
    ) throws -> EvidenceLocalizationResult {
        try EvidenceLocatorAndNumericChecker().locateEvidence(
            claim: claim,
            in: self,
            citeKeyFilter: citeKeyFilter,
            pdfFileName: pdfFileName,
            topK: topK
        )
    }

    public static func buildFTS5MatchExpression(from raw: String) -> String {
        let rawTerms = EvidenceLocatorAndNumericChecker.extractFTS5QueryTerms(from: raw)
        guard !rawTerms.isEmpty else { return "" }
        return rawTerms.prefix(24).map { term in
            let safe = term.replacingOccurrences(of: "\"", with: "")
            return "\"\(safe)\""
        }.joined(separator: " OR ")
    }

    private static func decodeChunkRow(_ stmt: OpaquePointer) -> PDFPassageChunk {
        let pid = String(cString: sqlite3_column_text(stmt, 0))
        let ckey = String(cString: sqlite3_column_text(stmt, 1))
        let fname = String(cString: sqlite3_column_text(stmt, 2))
        let sec = String(cString: sqlite3_column_text(stmt, 3))
        let col = Int(sqlite3_column_int(stmt, 4))
        let seq = Int(sqlite3_column_int(stmt, 5))
        let page = Int(sqlite3_column_int(stmt, 6))
        let bx = sqlite3_column_double(stmt, 7)
        let by = sqlite3_column_double(stmt, 8)
        let bw = sqlite3_column_double(stmt, 9)
        let bh = sqlite3_column_double(stmt, 10)
        let ptext = String(cString: sqlite3_column_text(stmt, 11))
        let kindStr = sqlite3_column_text(stmt, 12).map { String(cString: $0) } ?? "body"
        let kind = PDFPassageChunkKind(rawValue: kindStr) ?? .body

        return PDFPassageChunk(
            id: pid,
            citeKey: ckey,
            pdfFileName: fname,
            sectionTitle: sec,
            columnIndex: col,
            readingSequence: seq,
            boundingBox: PDFPageRegionBox(pageIndex: page, x: bx, y: by, width: bw, height: bh),
            passageText: ptext,
            kind: kind
        )
    }

    private func executeRaw(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeUnlocked(sql)
    }

    private func executeUnlocked(_ sql: String) throws {
        guard let db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "SQLite exec error"
            sqlite3_free(errMsg)
            throw ScholarOSError.sqliteError(code: rc, message: message)
        }
    }

    private func runStatement(db: OpaquePointer, sql: String, bind: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            throw ScholarOSError.sqliteError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(prepared) }
        bind(prepared)
        let stepRC = sqlite3_step(prepared)
        guard stepRC == SQLITE_DONE || stepRC == SQLITE_ROW else {
            throw ScholarOSError.sqliteError(code: stepRC, message: String(cString: sqlite3_errmsg(db)))
        }
    }
}
