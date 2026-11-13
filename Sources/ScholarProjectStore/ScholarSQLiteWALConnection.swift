import CryptoKit
import Foundation
import SQLite3
import ScholarModels

// MARK: - Deterministic SHA-256 Digest Utility

public enum ScholarCryptoDigest: Sendable {
    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        var result = ""
        result.reserveCapacity(64)
        for byte in digest {
            let high = byte >> 4
            let low = byte & 0x0F
            result.append(hexScalar(high))
            result.append(hexScalar(low))
        }
        return result
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    @inline(__always)
    private static func hexScalar(_ nibble: UInt8) -> Character {
        switch nibble {
        case 0: return "0"
        case 1: return "1"
        case 2: return "2"
        case 3: return "3"
        case 4: return "4"
        case 5: return "5"
        case 6: return "6"
        case 7: return "7"
        case 8: return "8"
        case 9: return "9"
        case 10: return "a"
        case 11: return "b"
        case 12: return "c"
        case 13: return "d"
        case 14: return "e"
        default: return "f"
        }
    }
}

// MARK: - Typed SQLite Values & Bindings

public enum SQLiteValue: Sendable, Hashable, Codable, CustomStringConvertible,
    ExpressibleByNilLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByBooleanLiteral
{
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(nilLiteral: ()) {
        self = .null
    }

    public init(integerLiteral value: Int64) {
        self = .integer(value)
    }

    public init(floatLiteral value: Double) {
        self = .real(value)
    }

    public init(stringLiteral value: String) {
        self = .text(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .integer(value ? 1 : 0)
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var int64Value: Int64? {
        switch self {
        case .integer(let v):
            return v
        case .real(let d):
            return Int64(exactly: d) ?? Int64(d)
        case .text(let s):
            return Int64(s.trimmingCharacters(in: .whitespacesAndNewlines))
        case .null, .blob:
            return nil
        }
    }

    public var intValue: Int? {
        guard let v = int64Value else { return nil }
        return Int(exactly: v)
    }

    public var doubleValue: Double? {
        switch self {
        case .real(let d):
            return d
        case .integer(let v):
            return Double(v)
        case .text(let s):
            return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        case .null, .blob:
            return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .integer(let v):
            return v != 0
        case .real(let d):
            return d != 0.0
        case .text(let s):
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        case .null, .blob:
            return nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .text(let s):
            return s
        case .integer(let v):
            return String(v)
        case .real(let d):
            return String(d)
        case .blob(let data):
            return String(data: data, encoding: .utf8)
        case .null:
            return nil
        }
    }

    public var dataValue: Data? {
        switch self {
        case .blob(let data):
            return data
        case .text(let s):
            return Data(s.utf8)
        case .null, .integer, .real:
            return nil
        }
    }

    public var uuidValue: UUID? {
        guard let s = stringValue else { return nil }
        return UUID(uuidString: s)
    }

    public var dateValue: Date? {
        switch self {
        case .real(let seconds):
            return Date(timeIntervalSince1970: seconds)
        case .integer(let seconds):
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        case .text(let iso):
            if let numeric = Double(iso) {
                return Date(timeIntervalSince1970: numeric)
            }
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: iso)
        case .null, .blob:
            return nil
        }
    }

    public var description: String {
        switch self {
        case .null:
            return "NULL"
        case .integer(let v):
            return String(v)
        case .real(let d):
            return String(d)
        case .text(let s):
            return "'\(s)'"
        case .blob(let data):
            return "<BLOB \(data.count) bytes>"
        }
    }
}

public protocol SQLiteBindable: Sendable {
    var sqliteValue: SQLiteValue { get }
}

extension SQLiteValue: SQLiteBindable {
    public var sqliteValue: SQLiteValue { self }
}

extension Int: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .integer(Int64(self)) }
}

extension Int32: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .integer(Int64(self)) }
}

extension Int64: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .integer(self) }
}

extension UInt64: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .integer(Int64(bitPattern: self)) }
}

extension Double: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .real(self) }
}

extension Float: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .real(Double(self)) }
}

extension Bool: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .integer(self ? 1 : 0) }
}

extension String: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .text(self) }
}

extension Substring: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .text(String(self)) }
}

extension Data: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .blob(self) }
}

extension UUID: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .text(uuidString) }
}

extension Date: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .real(timeIntervalSince1970) }
}

extension Optional: SQLiteBindable where Wrapped: SQLiteBindable {
    public var sqliteValue: SQLiteValue {
        switch self {
        case .some(let wrapped):
            return wrapped.sqliteValue
        case .none:
            return .null
        }
    }
}

// MARK: - Decoded Result Rows

public struct SQLiteRow: Sendable, Hashable {
    public let columns: [String]
    public let values: [SQLiteValue]
    private let columnIndexByLowercasedName: [String: Int]

    public init(columns: [String], values: [SQLiteValue]) {
        self.columns = columns
        self.values = values
        var lookup: [String: Int] = [:]
        lookup.reserveCapacity(columns.count)
        for (idx, col) in columns.enumerated() {
            let key = col.lowercased()
            if lookup[key] == nil {
                lookup[key] = idx
            }
        }
        self.columnIndexByLowercasedName = lookup
    }

    public var count: Int { values.count }

    public subscript(index: Int) -> SQLiteValue {
        guard index >= 0 && index < values.count else { return .null }
        return values[index]
    }

    public subscript(column: String) -> SQLiteValue {
        guard let idx = columnIndexByLowercasedName[column.lowercased()] else {
            return .null
        }
        return values[idx]
    }

    public func containsColumn(_ column: String) -> Bool {
        columnIndexByLowercasedName[column.lowercased()] != nil
    }

    public func requireValue(_ column: String) throws -> SQLiteValue {
        guard let idx = columnIndexByLowercasedName[column.lowercased()] else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_RANGE,
                message: "Expected SQLite result column '\(column)' not found in [\(columns.joined(separator: ", "))]"
            )
        }
        return values[idx]
    }

    public func int64(_ column: String) throws -> Int64 {
        let raw = try requireValue(column)
        guard let value = raw.int64Value else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_MISMATCH,
                message: "Column '\(column)' expected INTEGER, got \(raw)"
            )
        }
        return value
    }

    public func optionalInt64(_ column: String) -> Int64? {
        self[column].int64Value
    }

    public func int(_ column: String) throws -> Int {
        let value64 = try int64(column)
        guard let exact = Int(exactly: value64) else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_MISMATCH,
                message: "Column '\(column)' value \(value64) overflows platform Int"
            )
        }
        return exact
    }

    public func optionalInt(_ column: String) -> Int? {
        self[column].intValue
    }

    public func double(_ column: String) throws -> Double {
        let raw = try requireValue(column)
        guard let value = raw.doubleValue else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_MISMATCH,
                message: "Column '\(column)' expected REAL, got \(raw)"
            )
        }
        return value
    }

    public func optionalDouble(_ column: String) -> Double? {
        self[column].doubleValue
    }

    public func bool(_ column: String) throws -> Bool {
        let raw = try requireValue(column)
        guard let value = raw.boolValue else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_MISMATCH,
                message: "Column '\(column)' expected BOOLEAN/INTEGER, got \(raw)"
            )
        }
        return value
    }

    public func optionalBool(_ column: String) -> Bool? {
        self[column].boolValue
    }

    public func string(_ column: String) throws -> String {
        let raw = try requireValue(column)
        guard !raw.isNull, let value = raw.stringValue else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_MISMATCH,
                message: "Column '\(column)' expected non-null TEXT, got \(raw)"
            )
        }
        return value
    }

    public func optionalString(_ column: String) -> String? {
        let raw = self[column]
        if raw.isNull { return nil }
        return raw.stringValue
    }

    public func data(_ column: String) throws -> Data {
        let raw = try requireValue(column)
        guard !raw.isNull, let value = raw.dataValue else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_MISMATCH,
                message: "Column '\(column)' expected BLOB, got \(raw)"
            )
        }
        return value
    }

    public func optionalData(_ column: String) -> Data? {
        let raw = self[column]
        if raw.isNull { return nil }
        return raw.dataValue
    }

    public func uuid(_ column: String) throws -> UUID {
        let text = try string(column)
        guard let parsed = UUID(uuidString: text) else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_MISMATCH,
                message: "Column '\(column)' expected UUID text, got '\(text)'"
            )
        }
        return parsed
    }

    public func optionalUUID(_ column: String) -> UUID? {
        self[column].uuidValue
    }

    public func date(_ column: String) throws -> Date {
        let raw = try requireValue(column)
        guard let parsed = raw.dateValue else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_MISMATCH,
                message: "Column '\(column)' expected UNIX epoch REAL/INTEGER date, got \(raw)"
            )
        }
        return parsed
    }

    public func optionalDate(_ column: String) -> Date? {
        let raw = self[column]
        if raw.isNull { return nil }
        return raw.dateValue
    }

    public func jsonDecode<T: Decodable>(
        _ type: T.Type,
        column: String,
        decoder: JSONDecoder = ScholarSQLiteJSONCodec.makeDecoder()
    ) throws -> T {
        let jsonString = try string(column)
        do {
            return try decoder.decode(T.self, from: Data(jsonString.utf8))
        } catch {
            throw ScholarOSError.sqliteError(
                code: SQLITE_MISMATCH,
                message: "Failed decoding JSON column '\(column)' as \(T.self): \(error.localizedDescription)"
            )
        }
    }

    public func optionalJSONDecode<T: Decodable>(
        _ type: T.Type,
        column: String,
        decoder: JSONDecoder = ScholarSQLiteJSONCodec.makeDecoder()
    ) throws -> T? {
        guard let jsonString = optionalString(column), !jsonString.isEmpty else {
            return nil
        }
        do {
            return try decoder.decode(T.self, from: Data(jsonString.utf8))
        } catch {
            throw ScholarOSError.sqliteError(
                code: SQLITE_MISMATCH,
                message: "Failed decoding optional JSON column '\(column)' as \(T.self): \(error.localizedDescription)"
            )
        }
    }

    public func asDictionary() -> [String: SQLiteValue] {
        var result: [String: SQLiteValue] = [:]
        result.reserveCapacity(columns.count)
        for (idx, col) in columns.enumerated() where idx < values.count {
            result[col] = values[idx]
        }
        return result
    }
}

// MARK: - Canonical JSON Codec for SQLite Columns

public enum ScholarSQLiteJSONCodec: Sendable {
    public static func makeEncoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted {
            formatting.insert(.prettyPrinted)
        }
        encoder.outputFormatting = formatting
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public static func encodeString<T: Encodable>(_ value: T, prettyPrinted: Bool = false) throws -> String {
        let data = try makeEncoder(prettyPrinted: prettyPrinted).encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_ERROR,
                message: "Unable to UTF-8 encode JSON payload for \(T.self)"
            )
        }
        return string
    }

    public static func decodeString<T: Decodable>(_ type: T.Type, from jsonString: String) throws -> T {
        try makeDecoder().decode(T.self, from: Data(jsonString.utf8))
    }
}

// MARK: - WAL Checkpoint, Integrity & Storage Diagnostics

public enum SQLiteWALCheckpointMode: String, Sendable, Codable, Hashable, CaseIterable {
    case passive = "PASSIVE"
    case full = "FULL"
    case restart = "RESTART"
    case truncate = "TRUNCATE"

    var cFlag: Int32 {
        switch self {
        case .passive: return SQLITE_CHECKPOINT_PASSIVE
        case .full: return SQLITE_CHECKPOINT_FULL
        case .restart: return SQLITE_CHECKPOINT_RESTART
        case .truncate: return SQLITE_CHECKPOINT_TRUNCATE
        }
    }
}

public struct SQLiteWALCheckpointResult: Sendable, Codable, Hashable {
    public let mode: SQLiteWALCheckpointMode
    public let busyStatus: Int32
    public let totalWALFrames: Int32
    public let checkpointedFrames: Int32

    public init(
        mode: SQLiteWALCheckpointMode,
        busyStatus: Int32,
        totalWALFrames: Int32,
        checkpointedFrames: Int32
    ) {
        self.mode = mode
        self.busyStatus = busyStatus
        self.totalWALFrames = totalWALFrames
        self.checkpointedFrames = checkpointedFrames
    }

    public var isFullyCheckpointed: Bool {
        busyStatus == 0 && (totalWALFrames <= 0 || checkpointedFrames == totalWALFrames)
    }
}

public struct SQLiteForeignKeyViolation: Sendable, Codable, Hashable {
    public let table: String
    public let rowID: Int64
    public let parentTable: String
    public let foreignKeyIndex: Int

    public init(table: String, rowID: Int64, parentTable: String, foreignKeyIndex: Int) {
        self.table = table
        self.rowID = rowID
        self.parentTable = parentTable
        self.foreignKeyIndex = foreignKeyIndex
    }
}

public struct SQLiteIntegrityReport: Sendable, Codable, Hashable {
    public let isHealthy: Bool
    public let messages: [String]
    public let foreignKeyViolations: [SQLiteForeignKeyViolation]
    public let journalMode: String
    public let pageSize: Int64
    public let pageCount: Int64
    public let freelistCount: Int64

    public init(
        isHealthy: Bool,
        messages: [String],
        foreignKeyViolations: [SQLiteForeignKeyViolation],
        journalMode: String,
        pageSize: Int64,
        pageCount: Int64,
        freelistCount: Int64
    ) {
        self.isHealthy = isHealthy
        self.messages = messages
        self.foreignKeyViolations = foreignKeyViolations
        self.journalMode = journalMode
        self.pageSize = pageSize
        self.pageCount = pageCount
        self.freelistCount = freelistCount
    }
}

public struct SQLiteStorageAccounting: Sendable, Codable, Hashable {
    public let databasePath: String
    public let walPath: String
    public let shmPath: String
    public let isInMemory: Bool
    public let sqliteBytes: Int64
    public let walBytes: Int64
    public let shmBytes: Int64
    public let pageSize: Int64
    public let pageCount: Int64
    public let freelistPages: Int64

    public init(
        databasePath: String,
        walPath: String,
        shmPath: String,
        isInMemory: Bool,
        sqliteBytes: Int64,
        walBytes: Int64,
        shmBytes: Int64,
        pageSize: Int64,
        pageCount: Int64,
        freelistPages: Int64
    ) {
        self.databasePath = databasePath
        self.walPath = walPath
        self.shmPath = shmPath
        self.isInMemory = isInMemory
        self.sqliteBytes = sqliteBytes
        self.walBytes = walBytes
        self.shmBytes = shmBytes
        self.pageSize = pageSize
        self.pageCount = pageCount
        self.freelistPages = freelistPages
    }

    public var totalOnDiskBytes: Int64 {
        sqliteBytes + walBytes + shmBytes
    }

    public var livePayloadBytesEstimate: Int64 {
        let livePages = max(0, pageCount - freelistPages)
        return livePages * pageSize
    }
}

public struct SQLiteStatementCacheMetrics: Sendable, Codable, Hashable {
    public let cachedCount: Int
    public let capacity: Int
    public let cacheHits: Int64
    public let cacheMisses: Int64
    public let evictions: Int64

    public init(
        cachedCount: Int,
        capacity: Int,
        cacheHits: Int64,
        cacheMisses: Int64,
        evictions: Int64
    ) {
        self.cachedCount = cachedCount
        self.capacity = capacity
        self.cacheHits = cacheHits
        self.cacheMisses = cacheMisses
        self.evictions = evictions
    }

    public var hitRate: Double {
        let total = cacheHits + cacheMisses
        guard total > 0 else { return 0.0 }
        return Double(cacheHits) / Double(total)
    }
}

public struct SQLiteConnectionConfiguration: Sendable, Hashable {
    public var busyTimeoutMilliseconds: Int32
    public var maxCachedStatements: Int
    public var synchronousMode: String
    public var journalSizeLimitBytes: Int64
    public var cacheSizeKiB: Int
    public var enableForeignKeys: Bool
    public var enableWAL: Bool

    public init(
        busyTimeoutMilliseconds: Int32 = 5_000,
        maxCachedStatements: Int = 96,
        synchronousMode: String = "NORMAL",
        journalSizeLimitBytes: Int64 = 67_108_864,
        cacheSizeKiB: Int = 16_384,
        enableForeignKeys: Bool = true,
        enableWAL: Bool = true
    ) {
        self.busyTimeoutMilliseconds = max(0, busyTimeoutMilliseconds)
        self.maxCachedStatements = max(0, maxCachedStatements)
        self.synchronousMode = synchronousMode
        self.journalSizeLimitBytes = journalSizeLimitBytes
        self.cacheSizeKiB = max(256, cacheSizeKiB)
        self.enableForeignKeys = enableForeignKeys
        self.enableWAL = enableWAL
    }

    public static let standard = SQLiteConnectionConfiguration()
}

// MARK: - Thread-Safe SQLite3 WAL Connection Wrapper

public final class ScholarSQLiteWALConnection: @unchecked Sendable {
    private struct CachedStatementEntry {
        let handle: OpaquePointer
        var lastAccessGeneration: UInt64
    }

    private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public let databasePath: String
    public let isInMemory: Bool
    public let configuration: SQLiteConnectionConfiguration

    private let lock = NSRecursiveLock()
    private var dbHandle: OpaquePointer?
    private var isClosed: Bool = false

    private var statementCache: [String: CachedStatementEntry] = [:]
    private var activeCheckedOutSQL: Set<String> = []
    private var accessGenerationCounter: UInt64 = 0
    private var cacheHits: Int64 = 0
    private var cacheMisses: Int64 = 0
    private var cacheEvictions: Int64 = 0
    private var savepointSequence: UInt64 = 0

    public init(
        databasePath: String,
        configuration: SQLiteConnectionConfiguration = .standard
    ) throws {
        let trimmed = databasePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_CANTOPEN,
                message: "Database path cannot be empty."
            )
        }

        let memoryFlag = (trimmed == ":memory:" || trimmed.hasPrefix("file::memory:"))
        self.databasePath = trimmed
        self.isInMemory = memoryFlag
        self.configuration = configuration

        if !memoryFlag && !trimmed.hasPrefix("file:") {
            let parentURL = URL(fileURLWithPath: trimmed).deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(
                    at: parentURL,
                    withIntermediateDirectories: true
                )
            } catch {
                throw ScholarOSError.sqliteError(
                    code: SQLITE_CANTOPEN,
                    message: "Unable to create parent directory '\(parentURL.path)': \(error.localizedDescription)"
                )
            }
        }

        var rawHandle: OpaquePointer?
        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_EXRESCODE
        let rc = sqlite3_open_v2(trimmed, &rawHandle, openFlags, nil)
        guard rc == SQLITE_OK, let openedHandle = rawHandle else {
            let msg = rawHandle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let rawHandle {
                sqlite3_close_v2(rawHandle)
            }
            throw ScholarOSError.sqliteError(
                code: rc,
                message: "Failed opening SQLite database at '\(trimmed)': \(msg)"
            )
        }

        self.dbHandle = openedHandle
        sqlite3_busy_timeout(openedHandle, configuration.busyTimeoutMilliseconds)

        do {
            try configureConnectionPragmas()
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    // MARK: - Connection Lifecycle & Pragmas

    private func configureConnectionPragmas() throws {
        try executeScript("PRAGMA busy_timeout = \(configuration.busyTimeoutMilliseconds);")
        if configuration.enableWAL {
            let mode = try scalarString("PRAGMA journal_mode = WAL;")?.lowercased() ?? ""
            if !isInMemory && mode != "wal" {
                throw ScholarOSError.sqliteError(
                    code: SQLITE_ERROR,
                    message: "Expected SQLite journal_mode=WAL on '\(databasePath)', got '\(mode)'."
                )
            }
        }
        try executeScript("PRAGMA synchronous = \(configuration.synchronousMode);")
        if configuration.enableForeignKeys {
            try executeScript("PRAGMA foreign_keys = ON;")
        } else {
            try executeScript("PRAGMA foreign_keys = OFF;")
        }
        try executeScript("PRAGMA temp_store = MEMORY;")
        try executeScript("PRAGMA cache_size = -\(configuration.cacheSizeKiB);")
        if !isInMemory && configuration.journalSizeLimitBytes > 0 {
            try executeScript("PRAGMA journal_size_limit = \(configuration.journalSizeLimitBytes);")
        }
    }

    public var isOpen: Bool {
        withLock { !isClosed && dbHandle != nil }
    }

    public func close() {
        withLock {
            guard !isClosed else { return }
            for (_, entry) in statementCache {
                sqlite3_finalize(entry.handle)
            }
            statementCache.removeAll()
            activeCheckedOutSQL.removeAll()
            if let handle = dbHandle {
                if !isInMemory {
                    var logFrames: Int32 = 0
                    var ckptFrames: Int32 = 0
                    _ = sqlite3_wal_checkpoint_v2(
                        handle,
                        nil,
                        SQLITE_CHECKPOINT_PASSIVE,
                        &logFrames,
                        &ckptFrames
                    )
                }
                sqlite3_close_v2(handle)
                dbHandle = nil
            }
            isClosed = true
        }
    }

    // MARK: - Byte-Size Accounting

    public var walFilePath: String {
        isInMemory ? "" : "\(databasePath)-wal"
    }

    public var shmFilePath: String {
        isInMemory ? "" : "\(databasePath)-shm"
    }

    public var sqliteBytes: Int64 {
        withLock {
            if !isInMemory {
                let onDisk = Self.fileSizeOnDisk(atPath: databasePath)
                if onDisk > 0 {
                    return onDisk
                }
            }
            let pageSize = (try? scalarInt64("PRAGMA page_size;")) ?? 4096
            let pageCount = (try? scalarInt64("PRAGMA page_count;")) ?? 0
            return pageSize * pageCount
        }
    }

    public var walBytes: Int64 {
        withLock {
            guard !isInMemory else { return 0 }
            return Self.fileSizeOnDisk(atPath: walFilePath)
        }
    }

    public var shmBytes: Int64 {
        withLock {
            guard !isInMemory else { return 0 }
            return Self.fileSizeOnDisk(atPath: shmFilePath)
        }
    }

    public func storageAccounting() -> SQLiteStorageAccounting {
        withLock {
            let pageSize = (try? scalarInt64("PRAGMA page_size;")) ?? 4096
            let pageCount = (try? scalarInt64("PRAGMA page_count;")) ?? 0
            let freelist = (try? scalarInt64("PRAGMA freelist_count;")) ?? 0
            return SQLiteStorageAccounting(
                databasePath: databasePath,
                walPath: walFilePath,
                shmPath: shmFilePath,
                isInMemory: isInMemory,
                sqliteBytes: sqliteBytes,
                walBytes: walBytes,
                shmBytes: shmBytes,
                pageSize: pageSize,
                pageCount: pageCount,
                freelistPages: freelist
            )
        }
    }

    private static func fileSizeOnDisk(atPath path: String) -> Int64 {
        guard !path.isEmpty else { return 0 }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attrs[.size] as? NSNumber
        else {
            return 0
        }
        return number.int64Value
    }

    // MARK: - Prepared Statement Cache Management

    public func statementCacheMetrics() -> SQLiteStatementCacheMetrics {
        withLock {
            SQLiteStatementCacheMetrics(
                cachedCount: statementCache.count,
                capacity: configuration.maxCachedStatements,
                cacheHits: cacheHits,
                cacheMisses: cacheMisses,
                evictions: cacheEvictions
            )
        }
    }

    public func clearStatementCache() {
        withLock {
            for (sql, entry) in statementCache where !activeCheckedOutSQL.contains(sql) {
                sqlite3_finalize(entry.handle)
                statementCache.removeValue(forKey: sql)
            }
        }
    }

    private func requireOpenDatabase() throws -> OpaquePointer {
        guard !isClosed, let handle = dbHandle else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_MISUSE,
                message: "SQLite connection at '\(databasePath)' has already been closed."
            )
        }
        return handle
    }

    private func withPreparedStatement<T>(
        _ sql: String,
        cacheable: Bool = true,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        try withLock {
            let db = try requireOpenDatabase()
            let canUseCache = cacheable
                && configuration.maxCachedStatements > 0
                && !activeCheckedOutSQL.contains(sql)

            if canUseCache, var cached = statementCache[sql] {
                cacheHits += 1
                accessGenerationCounter &+= 1
                cached.lastAccessGeneration = accessGenerationCounter
                statementCache[sql] = cached
                activeCheckedOutSQL.insert(sql)
                sqlite3_reset(cached.handle)
                sqlite3_clear_bindings(cached.handle)
                defer {
                    sqlite3_reset(cached.handle)
                    sqlite3_clear_bindings(cached.handle)
                    activeCheckedOutSQL.remove(sql)
                }
                return try body(cached.handle)
            }

            cacheMisses += 1
            var rawStmt: OpaquePointer?
            let prepFlags: UInt32 = canUseCache ? UInt32(SQLITE_PREPARE_PERSISTENT) : 0
            let rc = sqlite3_prepare_v3(db, sql, -1, prepFlags, &rawStmt, nil)
            guard rc == SQLITE_OK, let stmt = rawStmt else {
                let errMsg = String(cString: sqlite3_errmsg(db))
                if let rawStmt {
                    sqlite3_finalize(rawStmt)
                }
                throw ScholarOSError.sqliteError(
                    code: rc,
                    message: "sqlite3_prepare_v3 error (\(errMsg)) in SQL: \(sql)"
                )
            }

            if canUseCache {
                if statementCache.count >= configuration.maxCachedStatements {
                    evictLeastRecentlyUsedStatement()
                }
                accessGenerationCounter &+= 1
                statementCache[sql] = CachedStatementEntry(
                    handle: stmt,
                    lastAccessGeneration: accessGenerationCounter
                )
                activeCheckedOutSQL.insert(sql)
                defer {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    activeCheckedOutSQL.remove(sql)
                }
                return try body(stmt)
            } else {
                defer {
                    sqlite3_finalize(stmt)
                }
                return try body(stmt)
            }
        }
    }

    private func evictLeastRecentlyUsedStatement() {
        var oldestKey: String?
        var oldestGen: UInt64 = .max
        for (sql, entry) in statementCache where !activeCheckedOutSQL.contains(sql) {
            if entry.lastAccessGeneration < oldestGen {
                oldestGen = entry.lastAccessGeneration
                oldestKey = sql
            }
        }
        if let keyToEvict = oldestKey, let removed = statementCache.removeValue(forKey: keyToEvict) {
            sqlite3_finalize(removed.handle)
            cacheEvictions += 1
        }
    }

    // MARK: - Parameter Binding Engine

    private func bindValue(_ value: SQLiteValue, at parameterIndex: Int32, in stmt: OpaquePointer) throws {
        let db = try requireOpenDatabase()
        let rc: Int32
        switch value {
        case .null:
            rc = sqlite3_bind_null(stmt, parameterIndex)
        case .integer(let intVal):
            rc = sqlite3_bind_int64(stmt, parameterIndex, intVal)
        case .real(let doubleVal):
            rc = sqlite3_bind_double(stmt, parameterIndex, doubleVal)
        case .text(let stringVal):
            rc = stringVal.withCString { cStr in
                sqlite3_bind_text(stmt, parameterIndex, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
        case .blob(let data):
            if data.isEmpty {
                var emptyByte: UInt8 = 0
                rc = withUnsafePointer(to: &emptyByte) { ptr in
                    sqlite3_bind_blob(stmt, parameterIndex, ptr, 0, SQLITE_TRANSIENT_DESTRUCTOR)
                }
            } else {
                rc = data.withUnsafeBytes { rawBuffer in
                    sqlite3_bind_blob(
                        stmt,
                        parameterIndex,
                        rawBuffer.baseAddress,
                        Int32(data.count),
                        SQLITE_TRANSIENT_DESTRUCTOR
                    )
                }
            }
        }

        guard rc == SQLITE_OK else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw ScholarOSError.sqliteError(
                code: rc,
                message: "Failed binding SQLite parameter #\(parameterIndex) (\(value)): \(errMsg)"
            )
        }
    }

    private func bindPositional(_ bindings: [any SQLiteBindable], to stmt: OpaquePointer) throws {
        for (offset, item) in bindings.enumerated() {
            try bindValue(item.sqliteValue, at: Int32(offset + 1), in: stmt)
        }
    }

    private func bindNamed(_ bindings: [String: any SQLiteBindable], to stmt: OpaquePointer) throws {
        for (rawName, item) in bindings {
            let candidateNames: [String]
            if rawName.hasPrefix(":") || rawName.hasPrefix("@") || rawName.hasPrefix("$") {
                candidateNames = [rawName]
            } else {
                candidateNames = [":\(rawName)", "@\(rawName)", "$\(rawName)"]
            }

            var resolvedIndex: Int32 = 0
            for candidate in candidateNames {
                let idx = candidate.withCString { sqlite3_bind_parameter_index(stmt, $0) }
                if idx > 0 {
                    resolvedIndex = idx
                    break
                }
            }

            guard resolvedIndex > 0 else {
                throw ScholarOSError.sqliteError(
                    code: SQLITE_RANGE,
                    message: "Named SQLite parameter '\(rawName)' not present in prepared statement."
                )
            }
            try bindValue(item.sqliteValue, at: resolvedIndex, in: stmt)
        }
    }

    // MARK: - Statement Execution & Querying

    public func executeScript(_ sql: String) throws {
        try withLock {
            let db = try requireOpenDatabase()
            var errorPointer: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &errorPointer)
            if rc != SQLITE_OK {
                let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
                if let errorPointer {
                    sqlite3_free(errorPointer)
                }
                throw ScholarOSError.sqliteError(
                    code: rc,
                    message: "sqlite3_exec failed: \(message)"
                )
            }
        }
    }

    @discardableResult
    public func execute(
        _ sql: String,
        bindings: [any SQLiteBindable] = [],
        cacheable: Bool = true
    ) throws -> Int {
        try withLock {
            let db = try requireOpenDatabase()
            return try withPreparedStatement(sql, cacheable: cacheable) { stmt in
                try bindPositional(bindings, to: stmt)
                let stepRC = sqlite3_step(stmt)
                guard stepRC == SQLITE_DONE || stepRC == SQLITE_ROW else {
                    let msg = String(cString: sqlite3_errmsg(db))
                    throw ScholarOSError.sqliteError(
                        code: stepRC,
                        message: "Execution failed (\(msg)) for SQL: \(sql)"
                    )
                }
                return Int(sqlite3_changes(db))
            }
        }
    }

    @discardableResult
    public func executeNamed(
        _ sql: String,
        bindings: [String: any SQLiteBindable],
        cacheable: Bool = true
    ) throws -> Int {
        try withLock {
            let db = try requireOpenDatabase()
            return try withPreparedStatement(sql, cacheable: cacheable) { stmt in
                try bindNamed(bindings, to: stmt)
                let stepRC = sqlite3_step(stmt)
                guard stepRC == SQLITE_DONE || stepRC == SQLITE_ROW else {
                    let msg = String(cString: sqlite3_errmsg(db))
                    throw ScholarOSError.sqliteError(
                        code: stepRC,
                        message: "Named execution failed (\(msg)) for SQL: \(sql)"
                    )
                }
                return Int(sqlite3_changes(db))
            }
        }
    }

    public func insertReturningRowID(
        _ sql: String,
        bindings: [any SQLiteBindable] = []
    ) throws -> Int64 {
        try withLock {
            let db = try requireOpenDatabase()
            _ = try execute(sql, bindings: bindings)
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func query(
        _ sql: String,
        bindings: [any SQLiteBindable] = [],
        cacheable: Bool = true
    ) throws -> [SQLiteRow] {
        try withLock {
            let db = try requireOpenDatabase()
            return try withPreparedStatement(sql, cacheable: cacheable) { stmt in
                try bindPositional(bindings, to: stmt)
                return try drainRows(from: stmt, db: db, sql: sql)
            }
        }
    }

    public func queryNamed(
        _ sql: String,
        bindings: [String: any SQLiteBindable],
        cacheable: Bool = true
    ) throws -> [SQLiteRow] {
        try withLock {
            let db = try requireOpenDatabase()
            return try withPreparedStatement(sql, cacheable: cacheable) { stmt in
                try bindNamed(bindings, to: stmt)
                return try drainRows(from: stmt, db: db, sql: sql)
            }
        }
    }

    public func queryOne(
        _ sql: String,
        bindings: [any SQLiteBindable] = [],
        cacheable: Bool = true
    ) throws -> SQLiteRow? {
        try query(sql, bindings: bindings, cacheable: cacheable).first
    }

    public func scalarInt64(
        _ sql: String,
        bindings: [any SQLiteBindable] = []
    ) throws -> Int64 {
        guard let row = try queryOne(sql, bindings: bindings), row.count > 0 else {
            return 0
        }
        return row[0].int64Value ?? 0
    }

    public func scalarInt(
        _ sql: String,
        bindings: [any SQLiteBindable] = []
    ) throws -> Int {
        Int(try scalarInt64(sql, bindings: bindings))
    }

    public func scalarDouble(
        _ sql: String,
        bindings: [any SQLiteBindable] = []
    ) throws -> Double {
        guard let row = try queryOne(sql, bindings: bindings), row.count > 0 else {
            return 0.0
        }
        return row[0].doubleValue ?? 0.0
    }

    public func scalarString(
        _ sql: String,
        bindings: [any SQLiteBindable] = []
    ) throws -> String? {
        guard let row = try queryOne(sql, bindings: bindings), row.count > 0 else {
            return nil
        }
        return row[0].stringValue
    }

    private func drainRows(
        from stmt: OpaquePointer,
        db: OpaquePointer,
        sql: String
    ) throws -> [SQLiteRow] {
        let columnCount = Int(sqlite3_column_count(stmt))
        var columns: [String] = []
        columns.reserveCapacity(columnCount)
        for colIdx in 0..<columnCount {
            if let namePtr = sqlite3_column_name(stmt, Int32(colIdx)) {
                columns.append(String(cString: namePtr))
            } else {
                columns.append("col_\(colIdx)")
            }
        }

        var rows: [SQLiteRow] = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                var values: [SQLiteValue] = []
                values.reserveCapacity(columnCount)
                for colIdx in 0..<columnCount {
                    values.append(readColumnValue(from: stmt, index: Int32(colIdx)))
                }
                rows.append(SQLiteRow(columns: columns, values: values))
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                let errMsg = String(cString: sqlite3_errmsg(db))
                throw ScholarOSError.sqliteError(
                    code: stepRC,
                    message: "sqlite3_step failed (\(errMsg)) in query: \(sql)"
                )
            }
        }
        return rows
    }

    private func readColumnValue(from stmt: OpaquePointer, index: Int32) -> SQLiteValue {
        let columnType = sqlite3_column_type(stmt, index)
        switch columnType {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, index))
        case SQLITE_TEXT:
            if let textPtr = sqlite3_column_text(stmt, index) {
                return .text(String(cString: textPtr))
            }
            return .text("")
        case SQLITE_BLOB:
            let byteCount = Int(sqlite3_column_bytes(stmt, index))
            guard byteCount > 0, let rawPtr = sqlite3_column_blob(stmt, index) else {
                return .blob(Data())
            }
            return .blob(Data(bytes: rawPtr, count: byteCount))
        default:
            return .null
        }
    }

    // MARK: - Transactions & Savepoints

    public var isInTransaction: Bool {
        withLock {
            guard let db = dbHandle, !isClosed else { return false }
            return sqlite3_get_autocommit(db) == 0
        }
    }

    public func beginSavepoint(_ name: String) throws {
        let safe = Self.sanitizeIdentifier(name)
        try execute("SAVEPOINT \(safe);", cacheable: false)
    }

    public func releaseSavepoint(_ name: String) throws {
        let safe = Self.sanitizeIdentifier(name)
        try execute("RELEASE SAVEPOINT \(safe);", cacheable: false)
    }

    public func rollbackToSavepoint(_ name: String) throws {
        let safe = Self.sanitizeIdentifier(name)
        try execute("ROLLBACK TO SAVEPOINT \(safe);", cacheable: false)
    }

    public func withSavepoint<T>(_ label: String = "sp", _ body: () throws -> T) throws -> T {
        try withLock {
            savepointSequence &+= 1
            let spName = "sp_\(savepointSequence)_\(Self.sanitizeIdentifier(label))"
            try beginSavepoint(spName)
            do {
                let result = try body()
                try releaseSavepoint(spName)
                return result
            } catch {
                try? rollbackToSavepoint(spName)
                try? releaseSavepoint(spName)
                throw error
            }
        }
    }

    public func withTransaction<T>(immediate: Bool = true, _ body: () throws -> T) throws -> T {
        try withLock {
            if isInTransaction {
                return try withSavepoint("nested_tx", body)
            }
            let beginSQL = immediate ? "BEGIN IMMEDIATE TRANSACTION;" : "BEGIN DEFERRED TRANSACTION;"
            try execute(beginSQL, cacheable: false)
            do {
                let result = try body()
                try execute("COMMIT TRANSACTION;", cacheable: false)
                return result
            } catch {
                if isInTransaction {
                    _ = try? execute("ROLLBACK TRANSACTION;", cacheable: false)
                }
                throw error
            }
        }
    }

    private static func sanitizeIdentifier(_ raw: String) -> String {
        let filtered = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                return Character(scalar)
            }
            return "_"
        }
        let joined = String(filtered)
        if joined.isEmpty {
            return "sp_default"
        }
        if let first = joined.first, first.isNumber {
            return "sp_\(joined)"
        }
        return joined
    }

    // MARK: - Schema Introspection, WAL Checkpointing, Integrity & Online Backup

    public func userVersion() throws -> Int {
        try scalarInt("PRAGMA user_version;")
    }

    public func setUserVersion(_ version: Int) throws {
        try executeScript("PRAGMA user_version = \(max(0, version));")
    }

    public func tableExists(_ tableName: String) throws -> Bool {
        let count = try scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?;",
            bindings: [tableName]
        )
        return count > 0
    }

    public func columnNames(inTable tableName: String) throws -> Set<String> {
        let safe = Self.sanitizeIdentifier(tableName)
        let rows = try query("PRAGMA table_info(\(safe));", cacheable: false)
        var names = Set<String>()
        for row in rows {
            if let colName = row.optionalString("name") {
                names.insert(colName)
            }
        }
        return names
    }

    @discardableResult
    public func walCheckpoint(
        mode: SQLiteWALCheckpointMode = .truncate
    ) throws -> SQLiteWALCheckpointResult {
        try withLock {
            if isInMemory {
                return SQLiteWALCheckpointResult(
                    mode: mode,
                    busyStatus: 0,
                    totalWALFrames: 0,
                    checkpointedFrames: 0
                )
            }

            let rows = try query("PRAGMA wal_checkpoint(\(mode.rawValue));", cacheable: false)
            if let first = rows.first, first.count >= 3 {
                let busy = Int32(first[0].int64Value ?? 0)
                let logFrames = Int32(first[1].int64Value ?? 0)
                let checkpointed = Int32(first[2].int64Value ?? 0)
                return SQLiteWALCheckpointResult(
                    mode: mode,
                    busyStatus: busy,
                    totalWALFrames: logFrames,
                    checkpointedFrames: checkpointed
                )
            }

            let db = try requireOpenDatabase()
            var logFrames: Int32 = 0
            var checkpointedFrames: Int32 = 0
            let rc = sqlite3_wal_checkpoint_v2(
                db,
                nil,
                mode.cFlag,
                &logFrames,
                &checkpointedFrames
            )
            guard rc == SQLITE_OK || rc == SQLITE_BUSY else {
                let errMsg = String(cString: sqlite3_errmsg(db))
                throw ScholarOSError.sqliteError(
                    code: rc,
                    message: "WAL checkpoint (\(mode.rawValue)) failed: \(errMsg)"
                )
            }
            return SQLiteWALCheckpointResult(
                mode: mode,
                busyStatus: rc == SQLITE_BUSY ? 1 : 0,
                totalWALFrames: logFrames,
                checkpointedFrames: checkpointedFrames
            )
        }
    }

    public func runIntegrityCheck(maxErrors: Int = 100) throws -> SQLiteIntegrityReport {
        try withLock {
            let boundedLimit = max(1, maxErrors)
            let integrityRows = try query("PRAGMA integrity_check(\(boundedLimit));", cacheable: false)
            var messages: [String] = []
            for row in integrityRows {
                if let msg = row[0].stringValue {
                    messages.append(msg)
                }
            }

            let fkRows = try query("PRAGMA foreign_key_check;", cacheable: false)
            var violations: [SQLiteForeignKeyViolation] = []
            for fkRow in fkRows {
                let table = fkRow[0].stringValue ?? "unknown"
                let rowID = fkRow[1].int64Value ?? -1
                let parent = fkRow[2].stringValue ?? "unknown"
                let fkIndex = fkRow[3].intValue ?? 0
                violations.append(
                    SQLiteForeignKeyViolation(
                        table: table,
                        rowID: rowID,
                        parentTable: parent,
                        foreignKeyIndex: fkIndex
                    )
                )
            }

            let journalMode = (try? scalarString("PRAGMA journal_mode;")) ?? "unknown"
            let pageSize = (try? scalarInt64("PRAGMA page_size;")) ?? 4096
            let pageCount = (try? scalarInt64("PRAGMA page_count;")) ?? 0
            let freelistCount = (try? scalarInt64("PRAGMA freelist_count;")) ?? 0
            let passedIntegrity = (messages.count == 1 && messages[0].lowercased() == "ok")
            let healthy = passedIntegrity && violations.isEmpty

            return SQLiteIntegrityReport(
                isHealthy: healthy,
                messages: messages,
                foreignKeyViolations: violations,
                journalMode: journalMode,
                pageSize: pageSize,
                pageCount: pageCount,
                freelistCount: freelistCount
            )
        }
    }

    public func vacuum() throws {
        try withLock {
            guard !isInTransaction else {
                throw ScholarOSError.sqliteError(
                    code: SQLITE_ERROR,
                    message: "VACUUM cannot execute inside an active transaction."
                )
            }
            try executeScript("VACUUM;")
        }
    }

    public func onlineBackup(toDestinationPath destinationPath: String) throws {
        try withLock {
            let sourceDB = try requireOpenDatabase()
            let parentURL = URL(fileURLWithPath: destinationPath).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

            var destHandle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            let openRC = sqlite3_open_v2(destinationPath, &destHandle, flags, nil)
            guard openRC == SQLITE_OK, let destDB = destHandle else {
                let msg = destHandle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open destination failed"
                if let destHandle {
                    sqlite3_close_v2(destHandle)
                }
                throw ScholarOSError.sqliteError(
                    code: openRC,
                    message: "Failed opening backup destination '\(destinationPath)': \(msg)"
                )
            }
            defer {
                sqlite3_close_v2(destDB)
            }

            guard let backup = sqlite3_backup_init(destDB, "main", sourceDB, "main") else {
                let msg = String(cString: sqlite3_errmsg(destDB))
                throw ScholarOSError.sqliteError(
                    code: sqlite3_errcode(destDB),
                    message: "sqlite3_backup_init failed: \(msg)"
                )
            }

            let stepRC = sqlite3_backup_step(backup, -1)
            let finishRC = sqlite3_backup_finish(backup)
            guard stepRC == SQLITE_DONE && finishRC == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(destDB))
                throw ScholarOSError.sqliteError(
                    code: finishRC != SQLITE_OK ? finishRC : stepRC,
                    message: "Online SQLite backup to '\(destinationPath)' failed: \(msg)"
                )
            }
        }
    }

    @inline(__always)
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
