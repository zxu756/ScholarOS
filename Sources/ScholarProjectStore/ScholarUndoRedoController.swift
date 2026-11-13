import Foundation
import SQLite3
import ScholarModels

// MARK: - Persistent Undo/Redo Journal Models

public enum UndoRedoStackKind: String, Sendable, Codable, Hashable, CaseIterable {
    case undo = "UNDO"
    case redo = "REDO"
}

public enum UndoMutationCategory: String, Sendable, Codable, Hashable, CaseIterable {
    case manuscriptEdit = "MANUSCRIPT_EDIT"
    case bibliographyUpsert = "BIBLIOGRAPHY_UPSERT"
    case screeningVote = "SCREENING_VOTE"

    public static func classify(_ mutation: ScholarUndoMutation) -> UndoMutationCategory {
        switch mutation {
        case .editManuscript:
            return .manuscriptEdit
        case .upsertBibliography:
            return .bibliographyUpsert
        case .recordScreeningVote:
            return .screeningVote
        }
    }
}

public struct UndoRedoJournalEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID { entryID }
    public let sequenceNumber: Int64
    public let entryID: UUID
    public let stack: UndoRedoStackKind
    public let actionTitle: String
    public let category: UndoMutationCategory
    public let mutation: ScholarUndoMutation
    public let createdAt: Date

    public init(
        sequenceNumber: Int64,
        entryID: UUID,
        stack: UndoRedoStackKind,
        actionTitle: String,
        category: UndoMutationCategory,
        mutation: ScholarUndoMutation,
        createdAt: Date
    ) {
        self.sequenceNumber = sequenceNumber
        self.entryID = entryID
        self.stack = stack
        self.actionTitle = actionTitle
        self.category = category
        self.mutation = mutation
        self.createdAt = createdAt
    }

    public var targetSummary: String {
        switch mutation {
        case .editManuscript(let filePath, let prev, let next):
            let delta = next.count - prev.count
            let sign = delta >= 0 ? "+" : ""
            return "\(filePath) (\(sign)\(delta) chars)"
        case .upsertBibliography(let prev, let next):
            if let next, prev == nil {
                return "Insert @\(next.citeKey)"
            } else if let prev, next == nil {
                return "Delete @\(prev.citeKey)"
            } else if let next {
                return "Update @\(next.citeKey)"
            }
            return "Bibliography noop"
        case .recordScreeningVote(let studyID, let slot, _, let next):
            return "\(studyID) [\(slot) -> \(next?.summaryLabel ?? "CLEARED")]"
        }
    }
}

// MARK: - Crash-Safe Transactional Undo/Redo Controller

public final class ScholarUndoRedoController: @unchecked Sendable {
    public let database: ScholarProjectDatabase
    public let maxHistoryDepth: Int

    private let lock = NSRecursiveLock()
    private var lastRecordedErrorMessage: String?

    public init(
        database: ScholarProjectDatabase,
        maxHistoryDepth: Int = 500
    ) {
        self.database = database
        self.maxHistoryDepth = max(1, maxHistoryDepth)
    }

    // MARK: - Stack Introspection Properties

    public var undoDepth: Int {
        withLock {
            (try? database.connection.scalarInt(
                "SELECT COUNT(*) FROM undo_redo_journal WHERE stack_state = 'UNDO';"
            )) ?? 0
        }
    }

    public var redoDepth: Int {
        withLock {
            (try? database.connection.scalarInt(
                "SELECT COUNT(*) FROM undo_redo_journal WHERE stack_state = 'REDO';"
            )) ?? 0
        }
    }

    public var canUndo: Bool {
        undoDepth > 0
    }

    public var canRedo: Bool {
        redoDepth > 0
    }

    public var topUndoActionTitle: String? {
        withLock {
            try? database.connection.scalarString(
                """
                SELECT action_title
                FROM undo_redo_journal
                WHERE stack_state = 'UNDO'
                ORDER BY seq DESC
                LIMIT 1;
                """
            )
        }
    }

    public var topRedoActionTitle: String? {
        withLock {
            try? database.connection.scalarString(
                """
                SELECT action_title
                FROM undo_redo_journal
                WHERE stack_state = 'REDO'
                ORDER BY seq DESC
                LIMIT 1;
                """
            )
        }
    }

    public var lastJournalError: String? {
        withLock { lastRecordedErrorMessage }
    }

    // MARK: - Recording & Performing Mutations

    /// Records a completed mutation onto the persistent SQLite `undo_redo_journal` UNDO stack,
    /// atomically clearing any divergent REDO branch and enforcing `maxHistoryDepth`.
    public func record(_ mutation: ScholarUndoMutation, actionTitle: String) {
        withLock {
            do {
                _ = try appendJournalMutationThrowing(
                    mutation,
                    actionTitle: actionTitle,
                    createdAt: Date()
                )
                lastRecordedErrorMessage = nil
            } catch {
                lastRecordedErrorMessage = error.localizedDescription
            }
        }
    }

    /// Atomically applies `mutation` to `ScholarProjectDatabase` AND appends it to `undo_redo_journal`
    /// inside a single SQLite WAL savepoint.
    @discardableResult
    public func performAndRecord(
        _ mutation: ScholarUndoMutation,
        actionTitle: String,
        createdAt: Date = Date()
    ) throws -> UndoRedoJournalEntry {
        try withLock {
            try database.connection.withSavepoint("undo_perform_record") {
                try applyMutationToStore(mutation)
                let entry = try appendJournalMutationThrowing(
                    mutation,
                    actionTitle: actionTitle,
                    createdAt: createdAt
                )
                try database.recordAuditEvent(
                    category: "UNDO_JOURNAL",
                    action: "performAndRecord",
                    actor: "ScholarUndoRedoController",
                    targetKey: entry.targetSummary,
                    details: [
                        "entry_id": entry.entryID.uuidString,
                        "action_title": entry.actionTitle,
                        "category": entry.category.rawValue
                    ],
                    createdAt: createdAt
                )
                return entry
            }
        }
    }

    /// Coalesces rapid sequential keystrokes in the same manuscript file within `coalescingWindowSeconds`
    /// into the top UNDO entry so Cmd+Z steps back by logical typing bursts rather than single characters.
    public func recordCoalescingManuscriptEdit(
        filePath: String,
        previousText: String,
        updatedText: String,
        actionTitle: String = "Edit Manuscript",
        coalescingWindowSeconds: TimeInterval = 2.5,
        now: Date = Date()
    ) {
        guard previousText != updatedText else { return }
        let normalizedPath = ScholarProjectDatabase.normalizeRelativePath(filePath)
        let freshMutation = ScholarUndoMutation.editManuscript(
            filePath: normalizedPath,
            previousText: previousText,
            updatedText: updatedText
        )

        withLock {
            do {
                try database.connection.withSavepoint("undo_coalesce_edit") {
                    // Any new forward edit invalidates REDO history
                    try database.connection.execute(
                        "DELETE FROM undo_redo_journal WHERE stack_state = 'REDO';"
                    )

                    if let topRow = try database.connection.queryOne(
                        """
                        SELECT seq, entry_id, stack_state, action_title, mutation_kind, mutation_json, created_at
                        FROM undo_redo_journal
                        WHERE stack_state = 'UNDO'
                        ORDER BY seq DESC
                        LIMIT 1;
                        """
                    ) {
                        let topEntry = try Self.decodeJournalRow(topRow)
                        let elapsed = now.timeIntervalSince(topEntry.createdAt)
                        if elapsed >= 0 && elapsed <= coalescingWindowSeconds,
                           case .editManuscript(let topPath, let olderBaseline, let topUpdated) = topEntry.mutation,
                           topPath == normalizedPath,
                           topUpdated == previousText
                        {
                            if olderBaseline == updatedText {
                                // User typed and immediately backspaced back to exact baseline
                                try database.connection.execute(
                                    "DELETE FROM undo_redo_journal WHERE seq = ?;",
                                    bindings: [topEntry.sequenceNumber]
                                )
                                return
                            }

                            let mergedMutation = ScholarUndoMutation.editManuscript(
                                filePath: normalizedPath,
                                previousText: olderBaseline,
                                updatedText: updatedText
                            )
                            let mergedJSON = try ScholarSQLiteJSONCodec.encodeString(mergedMutation)
                            try database.connection.execute(
                                """
                                UPDATE undo_redo_journal
                                SET action_title = ?, mutation_json = ?, created_at = ?
                                WHERE seq = ?;
                                """,
                                bindings: [
                                    Self.sanitizedTitle(actionTitle, fallback: topEntry.actionTitle),
                                    mergedJSON,
                                    now,
                                    topEntry.sequenceNumber
                                ]
                            )
                            return
                        }
                    }

                    _ = try appendJournalMutationThrowing(
                        freshMutation,
                        actionTitle: actionTitle,
                        createdAt: now
                    )
                }
                lastRecordedErrorMessage = nil
            } catch {
                lastRecordedErrorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func appendJournalMutationThrowing(
        _ mutation: ScholarUndoMutation,
        actionTitle: String,
        createdAt: Date
    ) throws -> UndoRedoJournalEntry {
        try database.connection.withSavepoint("undo_append") {
            // Standard linear undo semantics: recording a new forward edit truncates REDO branch
            try database.connection.execute(
                "DELETE FROM undo_redo_journal WHERE stack_state = 'REDO';"
            )

            let entryID = UUID()
            let cleanTitle = Self.sanitizedTitle(actionTitle, fallback: "Academic Workspace Edit")
            let category = UndoMutationCategory.classify(mutation)
            let payloadJSON = try ScholarSQLiteJSONCodec.encodeString(mutation)

            let insertedSeq = try database.connection.insertReturningRowID(
                """
                INSERT INTO undo_redo_journal (
                    entry_id, stack_state, action_title, mutation_kind, mutation_json, created_at
                ) VALUES (?, 'UNDO', ?, ?, ?, ?);
                """,
                bindings: [entryID, cleanTitle, category.rawValue, payloadJSON, createdAt]
            )

            try pruneOverflowUndoHistoryIfNeeded()

            return UndoRedoJournalEntry(
                sequenceNumber: insertedSeq,
                entryID: entryID,
                stack: .undo,
                actionTitle: cleanTitle,
                category: category,
                mutation: mutation,
                createdAt: createdAt
            )
        }
    }

    private func pruneOverflowUndoHistoryIfNeeded() throws {
        let currentCount = try database.connection.scalarInt(
            "SELECT COUNT(*) FROM undo_redo_journal WHERE stack_state = 'UNDO';"
        )
        let excess = currentCount - maxHistoryDepth
        guard excess > 0 else { return }

        try database.connection.execute(
            """
            DELETE FROM undo_redo_journal
            WHERE seq IN (
                SELECT seq FROM undo_redo_journal
                WHERE stack_state = 'UNDO'
                ORDER BY seq ASC
                LIMIT ?
            );
            """,
            bindings: [excess]
        )
    }

    // MARK: - Atomic Undo & Redo Execution

    /// Pops the most recent entry from the persistent UNDO stack, atomically applies its inverse
    /// mutation to `ScholarProjectDatabase`, pushes the entry onto the REDO stack, and returns
    /// the applied inverse `ScholarUndoMutation` (or `nil` if the UNDO stack is empty).
    @discardableResult
    public func undo() throws -> ScholarUndoMutation? {
        try withLock {
            try database.connection.withSavepoint("undo_step") {
                guard let row = try database.connection.queryOne(
                    """
                    SELECT seq, entry_id, stack_state, action_title, mutation_kind, mutation_json, created_at
                    FROM undo_redo_journal
                    WHERE stack_state = 'UNDO'
                    ORDER BY seq DESC
                    LIMIT 1;
                    """
                ) else {
                    return nil
                }

                let entry = try Self.decodeJournalRow(row)
                let inverseMutation = entry.mutation.inverted

                try applyMutationToStore(inverseMutation)

                // Move from UNDO to REDO with a fresh monotonic seq so LIFO order on REDO is exact
                try database.connection.execute(
                    "DELETE FROM undo_redo_journal WHERE seq = ?;",
                    bindings: [entry.sequenceNumber]
                )
                let forwardJSON = try ScholarSQLiteJSONCodec.encodeString(entry.mutation)
                _ = try database.connection.insertReturningRowID(
                    """
                    INSERT INTO undo_redo_journal (
                        entry_id, stack_state, action_title, mutation_kind, mutation_json, created_at
                    ) VALUES (?, 'REDO', ?, ?, ?, ?);
                    """,
                    bindings: [
                        entry.entryID,
                        entry.actionTitle,
                        entry.category.rawValue,
                        forwardJSON,
                        Date()
                    ]
                )

                try database.recordAuditEvent(
                    category: "UNDO_JOURNAL",
                    action: "undo",
                    actor: "ScholarUndoRedoController",
                    targetKey: entry.actionTitle,
                    details: [
                        "entry_id": entry.entryID.uuidString,
                        "category": entry.category.rawValue
                    ]
                )

                return inverseMutation
            }
        }
    }

    /// Pops the most recently undone entry from the persistent REDO stack, atomically reapplies its
    /// forward mutation to `ScholarProjectDatabase`, pushes it back onto the UNDO stack, and returns
    /// the reapplied forward `ScholarUndoMutation` (or `nil` if the REDO stack is empty).
    @discardableResult
    public func redo() throws -> ScholarUndoMutation? {
        try withLock {
            try database.connection.withSavepoint("redo_step") {
                guard let row = try database.connection.queryOne(
                    """
                    SELECT seq, entry_id, stack_state, action_title, mutation_kind, mutation_json, created_at
                    FROM undo_redo_journal
                    WHERE stack_state = 'REDO'
                    ORDER BY seq DESC
                    LIMIT 1;
                    """
                ) else {
                    return nil
                }

                let entry = try Self.decodeJournalRow(row)
                try applyMutationToStore(entry.mutation)

                try database.connection.execute(
                    "DELETE FROM undo_redo_journal WHERE seq = ?;",
                    bindings: [entry.sequenceNumber]
                )
                let forwardJSON = try ScholarSQLiteJSONCodec.encodeString(entry.mutation)
                _ = try database.connection.insertReturningRowID(
                    """
                    INSERT INTO undo_redo_journal (
                        entry_id, stack_state, action_title, mutation_kind, mutation_json, created_at
                    ) VALUES (?, 'UNDO', ?, ?, ?, ?);
                    """,
                    bindings: [
                        entry.entryID,
                        entry.actionTitle,
                        entry.category.rawValue,
                        forwardJSON,
                        Date()
                    ]
                )

                try pruneOverflowUndoHistoryIfNeeded()

                try database.recordAuditEvent(
                    category: "UNDO_JOURNAL",
                    action: "redo",
                    actor: "ScholarUndoRedoController",
                    targetKey: entry.actionTitle,
                    details: [
                        "entry_id": entry.entryID.uuidString,
                        "category": entry.category.rawValue
                    ]
                )

                return entry.mutation
            }
        }
    }

    public func undoMultiple(steps: Int) throws -> [ScholarUndoMutation] {
        guard steps > 0 else { return [] }
        return try withLock {
            try database.connection.withSavepoint("undo_multiple") {
                var applied: [ScholarUndoMutation] = []
                applied.reserveCapacity(steps)
                for _ in 0..<steps {
                    guard let m = try undo() else { break }
                    applied.append(m)
                }
                return applied
            }
        }
    }

    public func redoMultiple(steps: Int) throws -> [ScholarUndoMutation] {
        guard steps > 0 else { return [] }
        return try withLock {
            try database.connection.withSavepoint("redo_multiple") {
                var reapplied: [ScholarUndoMutation] = []
                reapplied.reserveCapacity(steps)
                for _ in 0..<steps {
                    guard let m = try redo() else { break }
                    reapplied.append(m)
                }
                return reapplied
            }
        }
    }

    // MARK: - Journal History Inspection & Maintenance

    /// Returns all persisted Undo & Redo journal entries ordered chronologically (`seq ASC`).
    public func historyEntries() -> [UndoRedoJournalEntry] {
        withLock {
            guard let rows = try? database.connection.query(
                """
                SELECT seq, entry_id, stack_state, action_title, mutation_kind, mutation_json, created_at
                FROM undo_redo_journal
                ORDER BY seq ASC;
                """
            ) else {
                return []
            }
            return rows.compactMap { try? Self.decodeJournalRow($0) }
        }
    }

    /// Returns persisted journal entries filtered to a specific stack (`UNDO` or `REDO`),
    /// ordered top-of-stack first (`seq DESC`).
    public func historyEntries(in stack: UndoRedoStackKind) -> [UndoRedoJournalEntry] {
        withLock {
            guard let rows = try? database.connection.query(
                """
                SELECT seq, entry_id, stack_state, action_title, mutation_kind, mutation_json, created_at
                FROM undo_redo_journal
                WHERE stack_state = ?
                ORDER BY seq DESC;
                """,
                bindings: [stack.rawValue]
            ) else {
                return []
            }
            return rows.compactMap { try? Self.decodeJournalRow($0) }
        }
    }

    public func clearRedoStack() throws {
        try withLock {
            try database.connection.execute(
                "DELETE FROM undo_redo_journal WHERE stack_state = 'REDO';"
            )
        }
    }

    public func clearHistory() throws {
        try withLock {
            try database.connection.execute("DELETE FROM undo_redo_journal;")
        }
    }

    /// Audits that every persisted `undo_redo_journal` entry cleanly deserializes into a valid
    /// `ScholarUndoMutation` and carries a recognized stack state.
    public func verifyJournalConsistency() throws -> Bool {
        try withLock {
            let rows = try database.connection.query(
                """
                SELECT seq, entry_id, stack_state, action_title, mutation_kind, mutation_json, created_at
                FROM undo_redo_journal
                ORDER BY seq ASC;
                """
            )
            for row in rows {
                _ = try Self.decodeJournalRow(row)
            }
            return true
        }
    }

    // MARK: - Store Mutation Application

    private func applyMutationToStore(_ mutation: ScholarUndoMutation) throws {
        switch mutation {
        case .editManuscript(let filePath, _, let updatedText):
            _ = try database.upsertManuscriptFile(
                path: filePath,
                content: updatedText
            )

        case .upsertBibliography(let previous, let updated):
            if let updatedEntry = updated {
                if let prevEntry = previous, prevEntry.citeKey != updatedEntry.citeKey {
                    _ = try database.deleteBibliographyEntry(citeKey: prevEntry.citeKey)
                }
                try database.upsertBibliographyEntry(updatedEntry)
            } else if let deletedEntry = previous {
                _ = try database.deleteBibliographyEntry(citeKey: deletedEntry.citeKey)
            }

        case .recordScreeningVote(let studyID, let reviewerSlot, _, let updatedDecision):
            guard var study = try database.screeningStudy(id: studyID) else {
                throw ScholarOSError.prismaProtocolViolation(
                    "Cannot apply Undo/Redo screening mutation: study '\(studyID)' not found."
                )
            }

            let normalizedSlot = reviewerSlot.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalizedSlot {
            case "a", "reviewera", "reviewer_a":
                study.reviewerADecision = updatedDecision
            case "b", "reviewerb", "reviewer_b":
                study.reviewerBDecision = updatedDecision
            case "adjudicated", "adjudicator", "adjudicate", "c", "third":
                study.adjudicatedDecision = updatedDecision
                if updatedDecision == nil {
                    study.adjudicationRationale = nil
                }
            default:
                throw ScholarOSError.prismaProtocolViolation(
                    "Cannot apply Undo/Redo screening mutation for unrecognized reviewer slot '\(reviewerSlot)'."
                )
            }
            try database.upsertScreeningStudy(study)
        }
    }

    private static func decodeJournalRow(_ row: SQLiteRow) throws -> UndoRedoJournalEntry {
        let stackRaw = try row.string("stack_state")
        guard let stack = UndoRedoStackKind(rawValue: stackRaw) else {
            throw ScholarOSError.sqliteError(
                code: SQLITE_MISMATCH,
                message: "Invalid stack_state '\(stackRaw)' in undo_redo_journal."
            )
        }
        let mutation = try row.jsonDecode(ScholarUndoMutation.self, column: "mutation_json")
        let catRaw = try row.string("mutation_kind")
        let category = UndoMutationCategory(rawValue: catRaw) ?? UndoMutationCategory.classify(mutation)

        return UndoRedoJournalEntry(
            sequenceNumber: try row.int64("seq"),
            entryID: try row.uuid("entry_id"),
            stack: stack,
            actionTitle: try row.string("action_title"),
            category: category,
            mutation: mutation,
            createdAt: try row.date("created_at")
        )
    }

    private static func sanitizedTitle(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    @discardableResult
    @inline(__always)
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
