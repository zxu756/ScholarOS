import Foundation
import SQLite3
import ScholarModels

// MARK: - SQLite Registry Response Cache (M1 Item 7)

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class RegistryResponseCache: @unchecked Sendable {
    public static let validRecordTTLSeconds: TimeInterval = 30 * 86_400
    public static let substantiatedNotFoundTTLSeconds: TimeInterval = 86_400

    private static let expectedColumnNames = ["url", "status", "body", "fetched_at"]

    public let fileURL: URL
    public let clock: any RegistryClock
    private let warningHandler: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var db: OpaquePointer?
    private var isDisabled: Bool = false
    private var hasEmittedWarning: Bool = false

    public init(
        fileURL: URL,
        clock: any RegistryClock = SystemRegistryClock(),
        warningHandler: (@Sendable (String) -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.clock = clock
        self.warningHandler = warningHandler
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    public static func resolveDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let rawDir = environment["SCHOLAR_CACHE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawDir.isEmpty {
            return URL(fileURLWithPath: rawDir, isDirectory: true)
                .appendingPathComponent("registry.sqlite", isDirectory: false)
        }
        let homePath: String
        if let rawHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawHome.isEmpty {
            homePath = rawHome
        } else {
            homePath = NSHomeDirectory()
        }
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("ScholarOS", isDirectory: true)
            .appendingPathComponent("registry.sqlite", isDirectory: false)
    }

    // MARK: - Canonical Request URL Key Normalization (Item 3)

    public static func canonicalKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let rawScheme = components.scheme?.lowercased(),
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty else {
            return url.absoluteString
        }

        components.scheme = rawScheme
        components.host = rawHost
        if (rawScheme == "https" && components.port == 443) || (rawScheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.fragment = nil

        let rawPath = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        var normalizedPath = normalizeRFC3986PercentEncoding(in: rawPath)

        // ISO 26324 DOIs are case-insensitive; unify case on single-DOI path endpoints while keeping %XX uppercase.
        if rawHost == "api.crossref.org", normalizedPath.lowercased().hasPrefix("/works/"), normalizedPath.count > "/works/".count {
            normalizedPath = lowercaseASCIIOutsidePercentEscapes(in: normalizedPath)
        } else if rawHost == "api.openalex.org", normalizedPath.lowercased().hasPrefix("/works/https://doi.org/") {
            normalizedPath = lowercaseASCIIOutsidePercentEscapes(in: normalizedPath)
        } else if rawHost == "doi.org", normalizedPath.lowercased().hasPrefix("/api/handles/"), normalizedPath.count > "/api/handles/".count {
            normalizedPath = lowercaseASCIIOutsidePercentEscapes(in: normalizedPath)
        }
        components.percentEncodedPath = normalizedPath

        if let rawItems = components.percentEncodedQueryItems {
            if rawItems.isEmpty {
                components.percentEncodedQuery = nil
            } else {
                var normalizedItems: [URLQueryItem] = []
                normalizedItems.reserveCapacity(rawItems.count)
                for item in rawItems {
                    let normName = normalizeRFC3986PercentEncoding(in: item.name)
                    let normVal = item.value.map { normalizeRFC3986PercentEncoding(in: $0) }
                    normalizedItems.append(URLQueryItem(name: normName, value: normVal))
                }
                normalizedItems.sort { lhs, rhs in
                    if lhs.name != rhs.name {
                        return lhs.name < rhs.name
                    }
                    return (lhs.value ?? "") < (rhs.value ?? "")
                }
                components.percentEncodedQueryItems = normalizedItems
            }
        } else {
            components.percentEncodedQuery = nil
        }

        return components.string ?? url.absoluteString
    }

    // MARK: - Lookup & Store

    public func lookup(for url: URL) -> RegistryHTTPResponse? {
        lock.lock()
        defer { lock.unlock() }

        if isDisabled {
            return nil
        }

        if db == nil {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
            if !exists {
                return nil
            }
            if isDir.boolValue {
                disableLocked(reason: "cache file path points to a directory")
                return nil
            }
            guard openAndEnsureSchemaLocked(createIfMissing: false) else {
                return nil
            }
        }

        guard let handle = db else {
            return nil
        }

        let key = Self.canonicalKey(for: url)
        let selectSQL = "SELECT status, body, fetched_at FROM registry_cache WHERE url = ?1 LIMIT 1;"

        var stmt: OpaquePointer?
        let prepRC = stepWithBusyRetry {
            sqlite3_prepare_v2(handle, selectSQL, -1, &stmt, nil)
        }
        guard prepRC == SQLITE_OK, let statement = stmt else {
            let msg = sqliteErrorMessage(handle, fallbackCode: prepRC)
            if let s = stmt { sqlite3_finalize(s) }
            disableLocked(reason: msg)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_text(statement, 1, key, -1, sqliteTransientDestructor) == SQLITE_OK else {
            disableLocked(reason: sqliteErrorMessage(handle, fallbackCode: SQLITE_ERROR))
            return nil
        }

        let stepRC = stepWithBusyRetry {
            sqlite3_step(statement)
        }
        if stepRC == SQLITE_DONE {
            return nil
        }
        guard stepRC == SQLITE_ROW else {
            disableLocked(reason: sqliteErrorMessage(handle, fallbackCode: stepRC))
            return nil
        }

        let status = Int(sqlite3_column_int(statement, 0))
        let byteLength = Int(sqlite3_column_bytes(statement, 1))
        let body: Data
        if byteLength > 0, let rawPtr = sqlite3_column_blob(statement, 1) {
            body = Data(bytes: rawPtr, count: byteLength)
        } else {
            body = Data()
        }
        guard let cFetchedAt = sqlite3_column_text(statement, 2) else {
            return nil
        }
        let fetchedAtRaw = String(cString: cFetchedAt)

        guard let storedDate = Self.parseUTCISO8601(fetchedAtRaw) else {
            return nil
        }

        let ttl = Self.ttlSeconds(forCanonicalURL: key, statusCode: status, body: body)
        let age = clock.currentDate().timeIntervalSince(storedDate)
        if age > ttl {
            return nil
        }

        let utcDay = Self.utcDayString(from: storedDate)
        return RegistryHTTPResponse(
            statusCode: status,
            body: body,
            headers: [:],
            origin: .cache,
            fetchedAt: utcDay
        )
    }

    public func store(url: URL, statusCode: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }

        if isDisabled {
            return
        }

        let key = Self.canonicalKey(for: url)
        guard (try? RegistryCanonicalURL.validateNoSensitiveContent(inURLString: key)) != nil else {
            return
        }

        if db == nil {
            guard openAndEnsureSchemaLocked(createIfMissing: true) else {
                return
            }
        }

        guard let handle = db else {
            return
        }

        let fetchedAt = Self.formatUTCISO8601(clock.currentDate())
        let upsertSQL = """
            INSERT OR REPLACE INTO registry_cache (url, status, body, fetched_at)
            VALUES (?1, ?2, ?3, ?4);
            """

        var stmt: OpaquePointer?
        let prepRC = stepWithBusyRetry {
            sqlite3_prepare_v2(handle, upsertSQL, -1, &stmt, nil)
        }
        guard prepRC == SQLITE_OK, let statement = stmt else {
            let msg = sqliteErrorMessage(handle, fallbackCode: prepRC)
            if let s = stmt { sqlite3_finalize(s) }
            disableLocked(reason: msg)
            return
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_text(statement, 1, key, -1, sqliteTransientDestructor) == SQLITE_OK,
              sqlite3_bind_int(statement, 2, Int32(statusCode)) == SQLITE_OK,
              sqlite3_bind_text(statement, 4, fetchedAt, -1, sqliteTransientDestructor) == SQLITE_OK else {
            disableLocked(reason: sqliteErrorMessage(handle, fallbackCode: SQLITE_ERROR))
            return
        }

        let bindBlobRC: Int32 = body.withUnsafeBytes { rawBuf in
            if let base = rawBuf.baseAddress, !body.isEmpty {
                return sqlite3_bind_blob(statement, 3, base, Int32(body.count), sqliteTransientDestructor)
            } else {
                var emptyByte: UInt8 = 0
                return withUnsafePointer(to: &emptyByte) { ptr in
                    sqlite3_bind_blob(statement, 3, ptr, 0, sqliteTransientDestructor)
                }
            }
        }
        guard bindBlobRC == SQLITE_OK else {
            disableLocked(reason: sqliteErrorMessage(handle, fallbackCode: bindBlobRC))
            return
        }

        let stepRC = stepWithBusyRetry {
            sqlite3_step(statement)
        }
        if stepRC != SQLITE_DONE {
            disableLocked(reason: sqliteErrorMessage(handle, fallbackCode: stepRC))
        }
    }

    // MARK: - Cache Clear Helper (`scholaros cache clear`)

    public static func clearCacheFiles(at databaseURL: URL) throws -> [URL] {
        let fm = FileManager.default
        let targets = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
        var removed: [URL] = []
        for candidate in targets {
            if fm.fileExists(atPath: candidate.path) {
                try fm.removeItem(at: candidate)
                removed.append(candidate)
            }
        }
        return removed
    }

    // MARK: - Internal TTL Classification

    internal static func ttlSeconds(forCanonicalURL canonicalURL: String, statusCode: Int, body: Data) -> TimeInterval {
        if let parsedURL = URL(string: canonicalURL),
           let host = parsedURL.host?.lowercased() {
            if host == "doi.org" {
                return substantiatedNotFoundTTLSeconds
            }
            if host == "export.arxiv.org",
               CitationVerificationFirewall.isSubstantiatedArXivNotFoundPayload(body) {
                return substantiatedNotFoundTTLSeconds
            }
            if host == "eutils.ncbi.nlm.nih.gov",
               CitationVerificationFirewall.isSubstantiatedPubMedNotFoundPayload(body, requestURL: parsedURL) {
                return substantiatedNotFoundTTLSeconds
            }
        }
        _ = statusCode
        return validRecordTTLSeconds
    }

    // MARK: - SQLite Connection, Schema & Resilience

    private func openAndEnsureSchemaLocked(createIfMissing: Bool) -> Bool {
        let parentDir = fileURL.deletingLastPathComponent()
        if createIfMissing {
            do {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            } catch {
                disableLocked(reason: error.localizedDescription)
                return false
            }
        }

        var flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if createIfMissing {
            flags |= SQLITE_OPEN_CREATE
        }

        var rawHandle: OpaquePointer?
        let openRC = sqlite3_open_v2(fileURL.path, &rawHandle, flags, nil)
        guard openRC == SQLITE_OK, let handle = rawHandle else {
            let msg = rawHandle.map { sqliteErrorMessage($0, fallbackCode: openRC) } ?? "SQLite open failed (\(openRC))"
            if let h = rawHandle { sqlite3_close_v2(h) }
            disableLocked(reason: msg)
            return false
        }

        sqlite3_busy_timeout(handle, 10_000)

        let pragmaRC = execSQLWithBusyRetry(
            handle,
            sql: "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;"
        )
        guard pragmaRC == SQLITE_OK else {
            let msg = sqliteErrorMessage(handle, fallbackCode: pragmaRC)
            sqlite3_close_v2(handle)
            disableLocked(reason: msg)
            return false
        }

        let schemaSQL = """
            CREATE TABLE IF NOT EXISTS registry_cache (
                url TEXT PRIMARY KEY NOT NULL,
                status INTEGER NOT NULL,
                body BLOB NOT NULL,
                fetched_at TEXT NOT NULL
            );
            """
        let createRC = execSQLWithBusyRetry(handle, sql: schemaSQL)
        guard createRC == SQLITE_OK else {
            let msg = sqliteErrorMessage(handle, fallbackCode: createRC)
            sqlite3_close_v2(handle)
            disableLocked(reason: msg)
            return false
        }

        // Verify table columns match our exact 4-column contract.
        var infoStmt: OpaquePointer?
        let infoRC = stepWithBusyRetry {
            sqlite3_prepare_v2(handle, "PRAGMA table_info(registry_cache);", -1, &infoStmt, nil)
        }
        guard infoRC == SQLITE_OK, let statement = infoStmt else {
            let msg = sqliteErrorMessage(handle, fallbackCode: infoRC)
            if let s = infoStmt { sqlite3_finalize(s) }
            sqlite3_close_v2(handle)
            disableLocked(reason: msg)
            return false
        }
        var columns: [String] = []
        while true {
            let rc = stepWithBusyRetry { sqlite3_step(statement) }
            if rc == SQLITE_ROW {
                if let cText = sqlite3_column_text(statement, 1) {
                    columns.append(String(cString: cText))
                }
            } else if rc == SQLITE_DONE {
                break
            } else {
                let msg = sqliteErrorMessage(handle, fallbackCode: rc)
                sqlite3_finalize(statement)
                sqlite3_close_v2(handle)
                disableLocked(reason: msg)
                return false
            }
        }
        sqlite3_finalize(statement)

        guard columns == Self.expectedColumnNames else {
            sqlite3_close_v2(handle)
            disableLocked(reason: "unexpected registry_cache schema")
            return false
        }

        self.db = handle
        return true
    }

    private func execSQLWithBusyRetry(_ handle: OpaquePointer, sql: String) -> Int32 {
        stepWithBusyRetry {
            sqlite3_exec(handle, sql, nil, nil, nil)
        }
    }

    private func stepWithBusyRetry(_ operation: () -> Int32) -> Int32 {
        var rc = operation()
        var retries = 0
        while (rc == SQLITE_BUSY || rc == SQLITE_LOCKED) && retries < 8 {
            retries += 1
            Thread.sleep(forTimeInterval: 0.02 * Double(retries))
            rc = operation()
        }
        return rc
    }

    private func sqliteErrorMessage(_ handle: OpaquePointer, fallbackCode: Int32) -> String {
        if let cMsg = sqlite3_errmsg(handle) {
            let text = String(cString: cMsg).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        return "SQLite error \(fallbackCode)"
    }

    private func disableLocked(reason: String) {
        if let existing = db {
            sqlite3_close_v2(existing)
            db = nil
        }
        isDisabled = true
        guard !hasEmittedWarning else { return }
        hasEmittedWarning = true
        let cleanReason = reason
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "[CACHE] Response cache unavailable (\(cleanReason)); continuing verification without cache."
        warningHandler?(message)
    }

    // MARK: - RFC 3986 Percent-Encoding & UTC Date Helpers

    private static func normalizeRFC3986PercentEncoding(in raw: String) -> String {
        guard raw.contains("%") else { return raw }
        let bytes = Array(raw.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var idx = 0
        while idx < bytes.count {
            if bytes[idx] == 0x25,
               idx + 2 < bytes.count,
               let hi = hexValue(bytes[idx + 1]),
               let lo = hexValue(bytes[idx + 2]) {
                let decodedByte = (hi << 4) | lo
                if isRFC3986Unreserved(decodedByte) {
                    out.append(decodedByte)
                } else {
                    out.append(0x25)
                    out.append(uppercaseHexDigit(hi))
                    out.append(uppercaseHexDigit(lo))
                }
                idx += 3
            } else {
                out.append(bytes[idx])
                idx += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func lowercaseASCIIOutsidePercentEscapes(in raw: String) -> String {
        let bytes = Array(raw.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var idx = 0
        while idx < bytes.count {
            let b = bytes[idx]
            if b == 0x25,
               idx + 2 < bytes.count,
               let hi = hexValue(bytes[idx + 1]),
               let lo = hexValue(bytes[idx + 2]) {
                out.append(0x25)
                out.append(uppercaseHexDigit(hi))
                out.append(uppercaseHexDigit(lo))
                idx += 3
            } else if b >= 0x41 && b <= 0x5A {
                out.append(b + 32)
                idx += 1
            } else {
                out.append(b)
                idx += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isRFC3986Unreserved(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x2D // -
            || byte == 0x2E // .
            || byte == 0x5F // _
            || byte == 0x7E // ~
    }

    private static func hexValue(_ ascii: UInt8) -> UInt8? {
        if ascii >= 0x30 && ascii <= 0x39 { return ascii - 0x30 }
        if ascii >= 0x41 && ascii <= 0x46 { return ascii - 0x41 + 10 }
        if ascii >= 0x61 && ascii <= 0x66 { return ascii - 0x61 + 10 }
        return nil
    }

    private static func uppercaseHexDigit(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? (0x30 + nibble) : (0x41 + nibble - 10)
    }

    internal static func formatUTCISO8601(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            c.year ?? 1970,
            c.month ?? 1,
            c.day ?? 1,
            c.hour ?? 0,
            c.minute ?? 0,
            c.second ?? 0
        )
    }

    internal static func utcDayString(from date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            c.year ?? 1970,
            c.month ?? 1,
            c.day ?? 1
        )
    }

    internal static func parseUTCISO8601(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: trimmed) {
            return d
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let d = formatter.date(from: trimmed) {
            return d
        }
        if trimmed.count == 10 {
            formatter.formatOptions = [.withFullDate]
            return formatter.date(from: trimmed)
        }
        return nil
    }
}
