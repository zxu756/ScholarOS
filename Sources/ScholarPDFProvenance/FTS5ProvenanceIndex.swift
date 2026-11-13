import Foundation
import SQLite3
import ScholarModels

// MARK: - SQLite FTS5 BM25 Claim-to-Bounding-Box Provenance Index

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
            passage_text TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_pdf_passages_cite ON pdf_passages(cite_key);

        CREATE VIRTUAL TABLE IF NOT EXISTS pdf_passages_fts USING fts5(
            passage_id UNINDEXED,
            cite_key,
            section_title,
            passage_text,
            tokenize = 'porter unicode61'
        );
        """
        try executeRaw(ddl)
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
                page_index, bbox_x, bbox_y, bbox_w, bbox_h, passage_text
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12);
            """
            let insFTS = """
            INSERT INTO pdf_passages_fts (passage_id, cite_key, section_title, passage_text)
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
                }
                try runStatement(db: db, sql: insFTS) { stmt in
                    sqlite3_bind_text(stmt, 1, chunk.id, -1, SQLITE_TRANSIENT_BRIDGE)
                    sqlite3_bind_text(stmt, 2, chunk.citeKey, -1, SQLITE_TRANSIENT_BRIDGE)
                    sqlite3_bind_text(stmt, 3, chunk.sectionTitle, -1, SQLITE_TRANSIENT_BRIDGE)
                    sqlite3_bind_text(stmt, 4, chunk.passageText, -1, SQLITE_TRANSIENT_BRIDGE)
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

    public func searchPassages(query: String, citeKeyFilter: String? = nil, limit: Int = 8) throws -> [(chunk: PDFPassageChunk, bm25Magnitude: Double)] {
        let terms = buildFTS5MatchExpression(from: query)
        guard !terms.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        let sql: String
        if citeKeyFilter != nil {
            sql = """
            SELECT m.passage_id, m.cite_key, m.pdf_file_name, m.section_title, m.column_index, m.reading_seq,
                   m.page_index, m.bbox_x, m.bbox_y, m.bbox_w, m.bbox_h, m.passage_text,
                   (-bm25(pdf_passages_fts, 0.0, 0.5, 1.5, 3.0)) AS rank_score
            FROM pdf_passages_fts
            JOIN pdf_passages m ON m.passage_id = pdf_passages_fts.passage_id
            WHERE pdf_passages_fts MATCH ?1 AND m.cite_key = ?2
            ORDER BY rank_score DESC
            LIMIT ?3;
            """
        } else {
            sql = """
            SELECT m.passage_id, m.cite_key, m.pdf_file_name, m.section_title, m.column_index, m.reading_seq,
                   m.page_index, m.bbox_x, m.bbox_y, m.bbox_w, m.bbox_h, m.passage_text,
                   (-bm25(pdf_passages_fts, 0.0, 0.5, 1.5, 3.0)) AS rank_score
            FROM pdf_passages_fts
            JOIN pdf_passages m ON m.passage_id = pdf_passages_fts.passage_id
            WHERE pdf_passages_fts MATCH ?1
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
            let pid = String(cString: sqlite3_column_text(prepared, 0))
            let ckey = String(cString: sqlite3_column_text(prepared, 1))
            let fname = String(cString: sqlite3_column_text(prepared, 2))
            let sec = String(cString: sqlite3_column_text(prepared, 3))
            let col = Int(sqlite3_column_int(prepared, 4))
            let seq = Int(sqlite3_column_int(prepared, 5))
            let page = Int(sqlite3_column_int(prepared, 6))
            let bx = sqlite3_column_double(prepared, 7)
            let by = sqlite3_column_double(prepared, 8)
            let bw = sqlite3_column_double(prepared, 9)
            let bh = sqlite3_column_double(prepared, 10)
            let ptext = String(cString: sqlite3_column_text(prepared, 11))
            let score = max(0.01, sqlite3_column_double(prepared, 12))

            let chunk = PDFPassageChunk(
                id: pid,
                citeKey: ckey,
                pdfFileName: fname,
                sectionTitle: sec,
                columnIndex: col,
                readingSequence: seq,
                boundingBox: PDFPageRegionBox(pageIndex: page, x: bx, y: by, width: bw, height: bh),
                passageText: ptext
            )
            hits.append((chunk, score))
        }
        return hits
    }

    /// Links a manuscript claim sentence citing `citeKey` to its highest-ranking PDF bounding box and verifies quantitative consistency.
    public func verifyClaimProvenance(
        manuscriptFile: String,
        manuscriptLine: Int,
        claimSentence: String,
        citeKey: String
    ) throws -> ClaimEvidenceProvenance {
        let hits = try searchPassages(query: claimSentence, citeKeyFilter: citeKey, limit: 3)
        guard let best = hits.first else {
            return ClaimEvidenceProvenance(
                manuscriptFile: manuscriptFile,
                manuscriptLine: manuscriptLine,
                manuscriptClaim: claimSentence,
                citeKey: citeKey,
                passageID: "\(citeKey)#unmatched",
                pdfExcerpt: "No matching passage found in attached PDF for '\(citeKey)'.",
                boundingBox: PDFPageRegionBox(pageIndex: 0, x: 0, y: 0, width: 0, height: 0),
                bm25Score: 0.0,
                verdict: .unsupportedClaim
            )
        }

        let claimNumbers = extractNumericTokens(claimSentence)
        let passageNumbers = extractNumericTokens(best.chunk.passageText)
        let verdict: EvidenceSupportVerdict
        if !claimNumbers.isEmpty && !claimNumbers.isSubset(of: passageNumbers) {
            verdict = .numericDiscrepancy
        } else if best.bm25Magnitude >= 2.2 {
            verdict = .groundedEntailment
        } else {
            verdict = .partialEvidence
        }

        return ClaimEvidenceProvenance(
            manuscriptFile: manuscriptFile,
            manuscriptLine: manuscriptLine,
            manuscriptClaim: claimSentence,
            citeKey: citeKey,
            passageID: best.chunk.id,
            pdfExcerpt: best.chunk.passageText,
            boundingBox: best.chunk.boundingBox,
            bm25Score: best.bm25Magnitude,
            verdict: verdict
        )
    }

    private func buildFTS5MatchExpression(from raw: String) -> String {
        let stopWords: Set<String> = [
            "the", "and", "that", "this", "with", "from", "were", "have", "been",
            "into", "their", "while", "where", "which", "cite", "citet", "citep"
        ]
        let tokens = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        var seen = Set<String>()
        let unique = tokens.filter { seen.insert($0).inserted }.prefix(14)
        return unique.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    private func extractNumericTokens(_ text: String) -> Set<String> {
        let pattern = #"\b\d+(?:\.\d+)?%?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var nums = Set<String>()
        for m in matches {
            let tok = ns.substring(with: m.range)
            // Ignore typical publication years 1990..2030 so year citations don't trigger numeric mismatch
            if let yr = Int(tok), (1990...2030).contains(yr) { continue }
            nums.insert(tok)
        }
        return nums
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
