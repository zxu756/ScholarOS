import Foundation
import Testing
import ScholarModels
import ScholarBibAndCSL
import ScholarLSPEngine
import ScholarProjectStore

@Suite("SQLite WAL Project Store, Myers Track Changes, Undo Journal & Archive Bundle")
struct ProjectStoreAndTrackChangesTests {

    // MARK: - Helpers

    private static var recordedRegistryFixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/registry", isDirectory: true)
    }

    private func makeTempDirectory(prefix: String = "scholaros-store") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeBibEntry(
        key: String,
        title: String,
        year: Int = 2024,
        doi: String? = "10.1145/3000.1",
        firewallClass: CitationFirewallClass = .verified,
        note: String = "Verified registry record"
    ) -> BibliographyEntry {
        BibliographyEntry(
            citeKey: key,
            kind: .article,
            title: title,
            authors: [BibAuthor(givenName: "Ada", familyName: "Lovelace")],
            year: year,
            venue: "Journal of Symbolic Computation",
            doi: doi,
            firewallClass: firewallClass,
            firewallAuditNote: note
        )
    }

    // MARK: - 1. ScholarSQLiteWALConnection & Schema Migrations v1 -> v4

    @Test("ScholarSQLiteWALConnection enables WAL mode, tracks LRU statement cache hits, and passes integrity check")
    func sqliteWALConnectionJournalModeStatementCacheAndIntegrity() throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-wal")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let conn = try ScholarSQLiteWALConnection(databasePath: dbPath)
        defer { conn.close() }

        #expect(conn.isOpen)
        #expect(!conn.isInMemory)

        try conn.executeScript("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT NOT NULL);")
        for idx in 1...6 {
            _ = try conn.execute("INSERT INTO items (id, label) VALUES (?, ?);", bindings: [idx, "Item-\(idx)"])
        }

        let count = try conn.scalarInt("SELECT COUNT(*) FROM items;")
        #expect(count == 6)

        let cacheMetrics = conn.statementCacheMetrics()
        #expect(cacheMetrics.cacheHits >= 4)
        #expect(cacheMetrics.hitRate > 0.5)

        let integrity = try conn.runIntegrityCheck()
        #expect(integrity.isHealthy)
        #expect(integrity.journalMode.lowercased() == "wal")
        #expect(integrity.foreignKeyViolations.isEmpty)

        let ckpt = try conn.walCheckpoint(mode: .truncate)
        #expect(ckpt.busyStatus == 0)
    }

    @Test("ScholarSQLiteWALConnection savepoint rollback, transaction atomicity, and online backup")
    func sqliteWALSavepointRollbackAndOnlineBackup() throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-backup")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryPath = tempDir.appendingPathComponent("primary.sqlite").path
        let backupPath = tempDir.appendingPathComponent("backup.sqlite").path

        let conn = try ScholarSQLiteWALConnection(databasePath: primaryPath)
        defer { conn.close() }

        try conn.executeScript("CREATE TABLE ledger (k TEXT PRIMARY KEY, v INTEGER NOT NULL);")
        _ = try conn.execute("INSERT INTO ledger (k, v) VALUES (?, ?);", bindings: ["alpha", 10])

        // Nested savepoint error rolls back inner mutation while preserving outer state
        struct IntentionalSavepointAbort: Error {}
        #expect(throws: IntentionalSavepointAbort.self) {
            try conn.withSavepoint("sp_abort") {
                _ = try conn.execute("INSERT INTO ledger (k, v) VALUES (?, ?);", bindings: ["beta", 99])
                throw IntentionalSavepointAbort()
            }
        }

        #expect(try conn.scalarInt("SELECT COUNT(*) FROM ledger;") == 1)

        // Online SQLite backup produces an independent consistent database file
        try conn.onlineBackup(toDestinationPath: backupPath)
        let backupConn = try ScholarSQLiteWALConnection(databasePath: backupPath)
        defer { backupConn.close() }
        let copiedVal = try backupConn.scalarInt("SELECT v FROM ledger WHERE k = ?;", bindings: ["alpha"])
        #expect(copiedVal == 10)
    }

    @Test("ScholarProjectDatabase step-by-step schema migration v1 -> v2 -> v3 -> v4 is idempotent and auditable")
    func stepByStepSchemaMigrationV1ThroughV4() throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-mig")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("migrated.sqlite").path
        let conn = try ScholarSQLiteWALConnection(databasePath: dbPath)

        // Migrate sequentially v1 -> v2 -> v3 -> v4
        try ScholarProjectDatabase.migrate(connection: conn, upTo: 1)
        #expect(try conn.userVersion() == 1)
        #expect(try conn.tableExists("manuscript_files"))
        #expect(try conn.tableExists("bibliography_entries"))

        try ScholarProjectDatabase.migrate(connection: conn, upTo: 2)
        #expect(try conn.userVersion() == 2)
        #expect(try conn.tableExists("prisma_protocols"))
        #expect(try conn.tableExists("screening_studies"))

        try ScholarProjectDatabase.migrate(connection: conn, upTo: 3)
        #expect(try conn.userVersion() == 3)
        #expect(try conn.tableExists("pdf_passages"))
        #expect(try conn.tableExists("claim_provenance_links"))

        try ScholarProjectDatabase.migrate(connection: conn, upTo: 4)
        #expect(try conn.userVersion() == 4)
        #expect(try conn.tableExists("undo_redo_journal"))
        #expect(try conn.tableExists("audit_events"))
        conn.close()

        // Re-opening via ScholarProjectDatabase upgrades v4 -> v5 idempotently
        let db = try ScholarProjectDatabase(path: dbPath)
        defer { db.close() }
        #expect(try db.currentSchemaVersion() == ScholarProjectDatabase.latestSchemaVersion)
        let migrations = try db.appliedMigrations()
        #expect(migrations.map(\.version) == [1, 2, 3, 4, 5])
        #expect(migrations.allSatisfy { $0.ddlSHA256.count == 64 })
    }

    // MARK: - 2. .scholarproj Bundle & Domain CRUD

    @Test("ScholarProjectDatabase initializes .scholarproj bundle on disk with seeded research project")
    func scholarprojBundleInitializationAndProjectStats() throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-bundle")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("TestStudy.scholarproj", isDirectory: true)
        let db = try ScholarProjectDatabase(bundleURL: bundleURL, seedDemoIfEmpty: true)
        defer { db.close() }

        let stats = try db.computeProjectStats()
        #expect(stats.schemaVersion == 5)
        #expect(stats.manuscriptWordCount > 150)
        #expect(stats.bibliographyCount >= 8)
        #expect(stats.verifiedCitationCount == 0)
        #expect(stats.blockedCitationCount == 1)
        #expect(stats.indexedPDFPassageCount >= 6)
        #expect(stats.prismaStudyCount >= 10)
        #expect(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("manuscripts/main.tex").path))
    }

    @Test("Manuscript file CRUD, word counting, and snapshot create/restore round-trip")
    func manuscriptCRUDAndSnapshotRestoreRoundTrip() throws {
        let db = try ScholarProjectDatabase.inMemory(seedDemo: false)
        defer { db.close() }

        try db.setProjectTitle("Quantum Error Mitigation Study")
        try db.setPreferredCitationStyle(.nature)
        #expect(try db.projectTitle() == "Quantum Error Mitigation Study")
        #expect(try db.preferredCitationStyle() == .nature)

        let v1Tex = """
        \\begin{document}
        \\section{Introduction}
        Initial baseline manuscript text with seven counted words.
        \\end{document}
        """
        let rec1 = try db.upsertManuscriptFile(path: "main.tex", content: v1Tex, format: .latex, mirrorToBundleDisk: false)
        #expect(rec1.wordCount > 5)

        let snap1 = try db.createSnapshot(label: "v1-baseline", authorName: "Ada", filePath: "main.tex")
        #expect(snap1.sourceContent == v1Tex)

        let v2Tex = """
        \\begin{document}
        \\section{Introduction}
        Completely rewritten camera-ready draft with substantially expanded empirical observations across benchmarks.
        \\end{document}
        """
        _ = try db.upsertManuscriptFile(path: "main.tex", content: v2Tex, format: .latex, mirrorToBundleDisk: false)
        #expect(try db.manuscriptContent(path: "main.tex") == v2Tex)

        // Restore v1 snapshot overwrites manuscript back to v1Tex
        let restored = try db.restoreSnapshot(id: snap1.id)
        #expect(restored.content == v1Tex)
        #expect(try db.manuscriptContent(path: "main.tex") == v1Tex)

        _ = try db.upsertManuscriptFile(path: "notes.md", content: "Scratch notes", format: .markdown, mirrorToBundleDisk: false)
        #expect(try db.listManuscriptFiles().count == 2)
        #expect(try db.deleteManuscriptFile(path: "notes.md"))
        #expect(try db.listManuscriptFiles().count == 1)
    }

    @Test("validateCitationKeyForInsertion blocks unverified demo entries, smith2025hallucinated, and missing keys, and permits verified records")
    func validateCitationKeyForInsertionEnforcesFirewall() async throws {
        let db = try ScholarProjectDatabase.inMemory(seedDemo: true)
        defer { db.close() }

        // 1. Demo-seeded entries start UNVERIFIED ("Demo data - unverified") and MUST be blocked until verified
        do {
            _ = try db.validateCitationKeyForInsertion("vaswani2017attention")
            Issue.record("Expected unverified demo entry vaswani2017attention to be blocked until verified")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }

        // 2a. Stored SQLite `firewall_class = VERIFIED` alone is NOT trusted without an in-run verdict (M1 item 8 / S42/S48).
        try db.updateCitationFirewallStatus(
            citeKey: "vaswani2017attention",
            firewallClass: .verified,
            auditNote: "Verified against registry"
        )
        do {
            _ = try db.validateCitationKeyForInsertion("vaswani2017attention")
            Issue.record("Expected stored SQLite VERIFIED status without in-run verdict to be blocked")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }

        // 2b. Once verified in the current run against recorded registry fixtures, insertion succeeds.
        let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
        let firewall = CitationVerificationFirewall()
        let vaswaniEntry = try #require(try db.bibliographyEntry(citeKey: "vaswani2017attention"))
        let vaswaniVerdict = await firewall.verifyAgainstPublicRegistries(entry: vaswaniEntry, session: replay)
        #expect(vaswaniVerdict.firewallClass == .verified)
        db.recordInRunVerdict(vaswaniVerdict)

        let verified = try db.validateCitationKeyForInsertion("vaswani2017attention")
        #expect(verified.firewallClass == .verified)

        // 3. Blocked hallucination (smith2025hallucinated) MUST throw ERR_UNVERIFIED_CITATION
        let smithEntry = try #require(try db.bibliographyEntry(citeKey: "smith2025hallucinated"))
        let smithVerdict = await firewall.verifyAgainstPublicRegistries(entry: smithEntry, session: replay)
        #expect(smithVerdict.firewallClass == .notFound)
        db.recordInRunVerdict(smithVerdict)
        do {
            _ = try db.validateCitationKeyForInsertion("smith2025hallucinated")
            Issue.record("Expected smith2025hallucinated to be blocked by Citation Firewall")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }

        // 4. Unverified offline entry MUST throw ERR_UNVERIFIED_CITATION
        try db.upsertBibliographyEntry(
            makeBibEntry(
                key: "offline2025draft",
                title: "Unverified Local Draft",
                doi: nil,
                firewallClass: .unverified,
                note: "Pending online check"
            )
        )
        do {
            _ = try db.validateCitationKeyForInsertion("offline2025draft")
            Issue.record("Expected unverified offline entry to be blocked")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }

        // 5. Missing unknown citeKey MUST throw ERR_UNVERIFIED_CITATION
        do {
            _ = try db.validateCitationKeyForInsertion("nonexistent2099ghost")
            Issue.record("Expected missing citeKey to throw ERR_UNVERIFIED_CITATION")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }
    }

    @Test("Bibliography filtering, firewall status updates, and duplicate candidate detection in SQLite")
    func bibliographyFilteringUpdatesAndDuplicateDetection() throws {
        let db = try ScholarProjectDatabase.inMemory(seedDemo: false)
        defer { db.close() }

        let primary = makeBibEntry(
            key: "lecun2015deep",
            title: "Deep Learning",
            year: 2015,
            doi: "10.1038/nature14539",
            firewallClass: .verified
        )
        let nearDup = makeBibEntry(
            key: "lecun2015deep_copy",
            title: "Deep learning",
            year: 2015,
            doi: "10.1038/nature14539",
            firewallClass: .unverified
        )
        try db.upsertBibliographyEntries([primary, nearDup])

        let dups = try db.detectDuplicateBibliographyCandidates(similarityThreshold: 0.90)
        #expect(dups.count == 1)
        #expect(dups[0].exactDOIMatch)

        try db.updateCitationFirewallStatus(
            citeKey: "lecun2015deep_copy",
            firewallClass: .notFound,
            auditNote: "Duplicate suppressed"
        )
        let blockedOnly = try db.listBibliographyEntries(firewallFilter: .notFound)
        #expect(blockedOnly.map(\.citeKey) == ["lecun2015deep_copy"])
    }

    @Test("PRISMA screening, PDF provenance, citation graph cache, and audit event CRUD in SQLite")
    func prismaProvenanceGraphAndAuditCRUD() throws {
        let db = try ScholarProjectDatabase.inMemory(seedDemo: false)
        defer { db.close() }

        let protocolSpec = PICOProtocolSpec(
            reviewTitle: "Sandboxed Execution Review",
            population: "LLM Agents",
            intervention: "MicroVM",
            comparator: "Host Shell",
            outcomes: "Containment",
            inclusionCriteria: ["Empirical"],
            exclusionRules: [ExclusionReasonRule(priorityOrder: 1, code: "E1", label: "Off-topic")]
        )
        try db.savePRISMAProtocol(protocolSpec, duplicateRecordsRemoved: 3, registerRecordsIdentified: 1, reportsNotRetrieved: 0)
        #expect(try db.loadPRISMAProtocol()?.reviewTitle == "Sandboxed Execution Review")

        try db.upsertScreeningStudy(
            ScreeningStudyRecord(
                id: "st-1",
                citeKey: "agache2020",
                title: "Firecracker MicroVMs",
                authorsLine: "Agache et al.",
                year: 2020,
                venue: "NSDI",
                abstractText: "Serverless microVMs.",
                stage: .fullText
            )
        )
        _ = try db.recordScreeningDecision(studyID: "st-1", reviewerSlot: "A", decision: .include)
        _ = try db.recordScreeningDecision(studyID: "st-1", reviewerSlot: "B", decision: .include)
        let irr = try db.computeInterRaterAgreement()
        #expect(irr.observedAgreement == 1.0)
        #expect(try db.computePRISMAMetrics().finalIncludedStudies == 1)

        // PDF passages & claim provenance CRUD
        let chunk = PDFPassageChunk(
            id: "agache2020#p1",
            citeKey: "agache2020",
            pdfFileName: "agache2020.pdf",
            sectionTitle: "Evaluation",
            columnIndex: 1,
            readingSequence: 1,
            boundingBox: PDFPageRegionBox(pageIndex: 0, x: 40, y: 100, width: 200, height: 50),
            passageText: "Boot time is 125 ms."
        )
        try db.upsertPDFPassage(chunk)
        #expect(try db.listPDFPassages(citeKey: "agache2020").count == 1)

        let link = ClaimEvidenceProvenance(
            manuscriptFile: "main.tex",
            manuscriptLine: 12,
            manuscriptClaim: "Firecracker boots in 125 ms \\cite{agache2020}.",
            citeKey: "agache2020",
            passageID: chunk.id,
            pdfExcerpt: chunk.passageText,
            boundingBox: chunk.boundingBox,
            bm25Score: 5.1,
            verdict: .groundedEntailment
        )
        try db.upsertClaimProvenance(link)
        #expect(try db.listClaimProvenanceLinks(verdict: .groundedEntailment).count == 1)

        // Citation graph cache & audit events
        try db.saveCitationGraph(
            nodes: [CitationGraphNode(citeKey: "agache2020", title: "Firecracker", authorYearLabel: "Agache 2020", year: 2020, pageRank: 1.0)],
            edges: []
        )
        #expect(try db.loadCitationGraph().nodes.count == 1)

        try db.recordAuditEvent(category: "FIREWALL", action: "VERIFY", targetKey: "agache2020", details: ["status": "ok"])
        #expect(try db.listAuditEvents(category: "FIREWALL").count == 1)
    }

    // MARK: - 3. Myers O(ND) Word-Level Track Changes Engine

    @Test("MyersWordLevelTrackChangesEngine preserves exact original/revised text reconstruction and atomic LaTeX tokens")
    func myersTrackChangesLosslessReconstructionAndAtomicLaTeXTokens() {
        let original = """
        We evaluate \\cite{vaswani2017attention} under inline bound $\\alpha + \\beta \\le 1$ across 120 GPU nodes with baseline latency.
        """
        let revised = """
        We rigorously evaluate \\cite{vaswani2017attention,dao2023flashattention2} under inline bound $\\alpha + \\beta \\le 1$ across 256 H100 GPU nodes with sub-millisecond latency.
        """

        let engine = MyersWordLevelTrackChangesEngine()
        let report = engine.diff(original: original, revised: revised)

        // Lossless exact reconstruction invariants!
        #expect(report.reconstructBaselineText() == original)
        #expect(report.reconstructRevisedText() == revised)
        #expect(report.insertedWordCount > 0)
        #expect(report.deletedWordCount > 0)
        #expect(report.editDistance > 0)
        #expect(report.similarityRatio > 0.4 && report.similarityRatio < 1.0)
        #expect(report.hasUnresolvedChanges)
    }

    @Test("MyersWordLevelTrackChangesEngine single-span and adjacent-hunk accept/reject algebra")
    func myersTrackChangesAcceptAndRejectSpanAndHunkAlgebra() throws {
        let original = "The heuristic baseline achieves moderate throughput on small graphs."
        let revised = "The deterministic algorithm achieves superior throughput on massive graphs."

        let engine = MyersWordLevelTrackChangesEngine()
        let report = engine.diff(original: original, revised: revised)
        let hunks = report.extractHunks()
        #expect(hunks.count == 3)

        // Accepting all changes yields the revised text with 0 unresolved changes
        let allAccepted = report.acceptAllChanges()
        #expect(!allAccepted.hasUnresolvedChanges)
        #expect(allAccepted.reconstructBaselineText() == revised)
        #expect(allAccepted.reconstructRevisedText() == revised)

        // Rejecting all changes reverts cleanly to the baseline text with 0 unresolved changes
        let allRejected = report.rejectAllChanges()
        #expect(!allRejected.hasUnresolvedChanges)
        #expect(allRejected.reconstructBaselineText() == original)
        #expect(allRejected.reconstructRevisedText() == original)

        // Accepting just the first hunk resolves that hunk while leaving remaining hunks editable
        let firstSpanID = try #require(hunks.first?.spanIDs.first)
        let partial = report.acceptHunk(containingSpanID: firstSpanID)
        #expect(partial.reconstructBaselineText().contains("deterministic algorithm"))
        #expect(partial.hasUnresolvedChanges)
    }

    @Test("MyersWordLevelTrackChangesEngine renders compilable latexdiff document with DIFadd and DIFdel macros")
    func myersTrackChangesCompilableLatexdiffMarkupGeneration() {
        let origDoc = """
        \\documentclass{article}
        \\begin{document}
        Old preliminary result of 78\\% accuracy.
        \\end{document}
        """
        let revDoc = """
        \\documentclass{article}
        \\begin{document}
        Verified final result of 94.2\\% accuracy.
        \\end{document}
        """

        let engine = MyersWordLevelTrackChangesEngine()
        let latexdiffDoc = engine.renderCompilableLatexdiffDocument(
            originalDocument: origDoc,
            revisedDocument: revDoc,
            colorScheme: .cambridgeAcademic
        )

        #expect(latexdiffDoc.contains("\\providecommand{\\DIFadd}"))
        #expect(latexdiffDoc.contains("\\providecommand{\\DIFdel}"))
        #expect(latexdiffDoc.contains("\\DIFdel{"))
        #expect(latexdiffDoc.contains("\\DIFadd{"))
        #expect(latexdiffDoc.contains("\\begin{document}"))
        #expect(latexdiffDoc.contains("\\end{document}"))
    }

    @Test("MyersWordLevelTrackChangesEngine diffs stored ManuscriptSnapshots accurately")
    func myersDiffSnapshotsFromDatabase() throws {
        let s1 = ManuscriptSnapshot(label: "Draft 1", filePath: "main.tex", sourceContent: "Alpha beta gamma.", wordCount: 3)
        let s2 = ManuscriptSnapshot(label: "Draft 2", filePath: "main.tex", sourceContent: "Alpha delta epsilon gamma.", wordCount: 4)

        let diff = MyersWordLevelTrackChangesEngine().diffSnapshots(baseline: s1, revised: s2)
        #expect(diff.baselineLabel == "Draft 1")
        #expect(diff.revisedLabel == "Draft 2")
        #expect(diff.reconstructBaselineText() == s1.sourceContent)
        #expect(diff.reconstructRevisedText() == s2.sourceContent)
    }

    // MARK: - 4. Crash-Safe Persistent ScholarUndoRedoController

    @Test("ScholarUndoRedoController round-trips manuscript, bibliography, and screening vote mutations")
    func undoRedoControllerMultiDomainRoundTrips() throws {
        let db = try ScholarProjectDatabase.inMemory(seedDemo: false)
        defer { db.close() }

        _ = try db.upsertManuscriptFile(path: "main.tex", content: "Version 0", format: .latex, mirrorToBundleDisk: false)
        try db.upsertScreeningStudy(
            ScreeningStudyRecord(
                id: "st1",
                citeKey: "k1",
                title: "Study 1",
                authorsLine: "Author A",
                year: 2025,
                venue: "ICML",
                abstractText: "Abstract",
                stage: .titleAbstract
            )
        )

        let undoController = ScholarUndoRedoController(database: db)
        let bibEntry = makeBibEntry(key: "vaswani2017", title: "Attention Is All You Need", year: 2017)

        // 1. Manuscript edit
        _ = try undoController.performAndRecord(
            .editManuscript(filePath: "main.tex", previousText: "Version 0", updatedText: "Version 1"),
            actionTitle: "Draft Intro"
        )
        // 2. Bibliography insert
        _ = try undoController.performAndRecord(
            .upsertBibliography(previous: nil, updated: bibEntry),
            actionTitle: "Add Vaswani 2017"
        )
        // 3. Screening vote
        _ = try undoController.performAndRecord(
            .recordScreeningVote(studyID: "st1", reviewerSlot: "A", previous: nil, updated: .include),
            actionTitle: "Vote Include st1"
        )

        #expect(undoController.undoDepth == 3)
        #expect(try db.manuscriptContent(path: "main.tex") == "Version 1")
        #expect(try db.bibliographyEntry(citeKey: "vaswani2017") != nil)
        #expect(try db.screeningStudy(id: "st1")?.reviewerADecision == .include)

        // Undo all 3 steps in reverse order
        _ = try undoController.undoMultiple(steps: 3)
        #expect(undoController.undoDepth == 0)
        #expect(undoController.redoDepth == 3)
        #expect(try db.manuscriptContent(path: "main.tex") == "Version 0")
        #expect(try db.bibliographyEntry(citeKey: "vaswani2017") == nil)
        #expect(try db.screeningStudy(id: "st1")?.reviewerADecision == nil)

        // Redo all 3 steps restores everything
        _ = try undoController.redoMultiple(steps: 3)
        #expect(undoController.undoDepth == 3)
        #expect(undoController.redoDepth == 0)
        #expect(try db.manuscriptContent(path: "main.tex") == "Version 1")
        #expect(try db.bibliographyEntry(citeKey: "vaswani2017") != nil)
        #expect(try db.screeningStudy(id: "st1")?.reviewerADecision == .include)
        #expect(try undoController.verifyJournalConsistency())
    }

    @Test("ScholarUndoRedoController persists journal across controller re-instantiation and coalesces rapid keystrokes")
    func undoRedoPersistenceAcrossRestartAndKeystrokeCoalescing() throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-undo")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("undo.sqlite").path
        do {
            let db1 = try ScholarProjectDatabase(path: dbPath)
            defer { db1.close() }
            _ = try db1.upsertManuscriptFile(path: "main.tex", content: "A", format: .latex, mirrorToBundleDisk: false)

            let ctrl1 = ScholarUndoRedoController(database: db1)
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            _ = try db1.upsertManuscriptFile(path: "main.tex", content: "AB", format: .latex, mirrorToBundleDisk: false)
            ctrl1.recordCoalescingManuscriptEdit(filePath: "main.tex", previousText: "A", updatedText: "AB", now: t0)

            _ = try db1.upsertManuscriptFile(path: "main.tex", content: "ABC", format: .latex, mirrorToBundleDisk: false)
            ctrl1.recordCoalescingManuscriptEdit(
                filePath: "main.tex",
                previousText: "AB",
                updatedText: "ABC",
                now: t0.addingTimeInterval(0.4)
            )
            // Rapid edits within 2.5s coalesce into a single undo entry ("A" -> "ABC")!
            #expect(ctrl1.undoDepth == 1)
        }

        // Re-open database and instantiate a brand-new controller (simulating app restart)
        let db2 = try ScholarProjectDatabase(path: dbPath)
        defer { db2.close() }
        let ctrl2 = ScholarUndoRedoController(database: db2)
        #expect(ctrl2.undoDepth == 1)
        _ = try ctrl2.undo()
        #expect(try db2.manuscriptContent(path: "main.tex") == "A")
        #expect(ctrl2.redoDepth == 1)

        // Performing a new branch edit clears the redo stack
        _ = try ctrl2.performAndRecord(
            .editManuscript(filePath: "main.tex", previousText: "A", updatedText: "BranchZ"),
            actionTitle: "New Branch"
        )
        #expect(ctrl2.redoDepth == 0)
        #expect(try ctrl2.verifyJournalConsistency())
    }

    // MARK: - 5. AcademicArchiveBundleCodec (arXiv Flattening, Firewall Gate, Tarball & SHA-256 Verification)

    @Test("AcademicArchiveBundleCodec flattens nested \\input files, strips % comments while keeping \\% and verbatim, and builds .bib/.bbl")
    func archiveBundleFlattensInputsStripsCommentsAndGeneratesBBL() throws {
        let mainTex = #"""
        \documentclass{article}
        % Secret internal reviewer comment that MUST be stripped!
        \begin{document}
        Accuracy reached 99.4\% on \cite{vaswani2017attention}.
        \input{sections/method}
        \begin{verbatim}
        % Verbatim percent sign MUST NOT be stripped!
        \end{verbatim}
        \bibliography{refs}
        \end{document}
        """#
        let methodTex = #"""
        \section{Method}
        % Another private comment
        Tiled attention \cite{dao2023flashattention2} scales cleanly.
        """#

        let bib: [String: BibliographyEntry] = [
            "vaswani2017attention": makeBibEntry(key: "vaswani2017attention", title: "Attention Is All You Need", year: 2017),
            "dao2023flashattention2": makeBibEntry(
                key: "dao2023flashattention2",
                title: "FlashAttention-2",
                year: 2023,
                doi: nil,
                firewallClass: .verified
            ),
            "unused2020": makeBibEntry(key: "unused2020", title: "Uncited Paper", year: 2020)
        ]

        let codec = AcademicArchiveBundleCodec()
        let bundle = try codec.buildSubmissionBundle(
            projectTitle: "Flattened ArXiv Test",
            entryManuscriptPath: "main.tex",
            manuscriptFiles: ["main.tex": mainTex, "sections/method.tex": methodTex],
            bibliographyByKey: bib,
            citationStyle: .ieee,
            options: .arxivDefault
        )

        #expect(bundle.manifest.inlinedFiles == ["sections/method.tex"])
        #expect(bundle.manifest.strippedCommentCount >= 2)
        #expect(!bundle.flattenedTexContent.contains("Secret internal reviewer comment"))
        #expect(bundle.flattenedTexContent.contains("99.4\\%"))
        #expect(bundle.flattenedTexContent.contains("% Verbatim percent sign MUST NOT be stripped!"))
        #expect(bundle.flattenedTexContent.contains("Tiled attention"))
        // Only cited entries are exported into filtered .bib, omitting unused2020!
        #expect(bundle.manifest.exportedBibKeys.sorted() == ["dao2023flashattention2", "vaswani2017attention"])
        #expect(!bundle.filteredBibContent.contains("unused2020"))
        #expect(bundle.generatedBBLContent.contains("\\begin{thebibliography}"))
        #expect(bundle.manifest.passedAllBlockingChecks)
    }

    @Test("AcademicArchiveBundleCodec blocks unverified/hallucinated citations unless allowUnverifiedCitationsOverride is set")
    func archiveBundleBlocksUnverifiedCitationsUnlessExplicitlyOverridden() throws {
        let mainTex = """
        \\documentclass{article}
        \\begin{document}
        Hallucinated claim \\cite{smith2025hallucinated} and verified \\cite{vaswani2017attention}.
        \\end{document}
        """
        let bib: [String: BibliographyEntry] = [
            "vaswani2017attention": makeBibEntry(key: "vaswani2017attention", title: "Attention Is All You Need", year: 2017),
            "smith2025hallucinated": makeBibEntry(
                key: "smith2025hallucinated",
                title: "Fabricated Paper",
                year: 2025,
                doi: "10.5555/fake-llm-cite.9999",
                firewallClass: .notFound,
                note: "Hallucinated DOI"
            )
        ]

        let codec = AcademicArchiveBundleCodec()

        // Default strict arXiv export MUST refuse export with ERR_UNVERIFIED_CITATION!
        do {
            _ = try codec.buildSubmissionBundle(
                projectTitle: "Blocked Export",
                entryManuscriptPath: "main.tex",
                manuscriptFiles: ["main.tex": mainTex],
                bibliographyByKey: bib,
                options: .arxivDefault
            )
            Issue.record("Expected AcademicArchiveBundleCodec to block smith2025hallucinated")
        } catch let err as ScholarOSError {
            #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
        }

        // Explicit override permits bundle creation while recording smith2025hallucinated in overriddenUnverifiedKeys
        var overrideOpts = SubmissionArchiveOptions.arxivDefault
        overrideOpts.allowUnverifiedCitationsOverride = true
        let overriddenBundle = try codec.buildSubmissionBundle(
            projectTitle: "Overridden Export",
            entryManuscriptPath: "main.tex",
            manuscriptFiles: ["main.tex": mainTex],
            bibliographyByKey: bib,
            options: overrideOpts
        )
        #expect(overriddenBundle.manifest.overriddenUnverifiedKeys == ["smith2025hallucinated"])
    }

    @Test("AcademicArchiveBundleCodec blocks unverified demo database by default and strips commented-out smith2025hallucinated when overridden")
    func archiveBundleExportsSeededDatabaseAfterCommentStripping() throws {
        let db = try ScholarProjectDatabase.inMemory(seedDemo: true)
        defer { db.close() }

        // Demo entries are UNVERIFIED in M0, so strict default export blocks until verified or explicitly overridden
        #expect(throws: ScholarOSError.self) {
            _ = try AcademicArchiveBundleCodec().buildSubmissionBundle(from: db, options: .arxivDefault)
        }

        // With allowUnverifiedCitationsOverride, commented-out \cite{smith2025hallucinated} is stripped first
        var opts = SubmissionArchiveOptions.arxivDefault
        opts.allowUnverifiedCitationsOverride = true
        let bundle = try AcademicArchiveBundleCodec().buildSubmissionBundle(from: db, options: opts)
        #expect(!bundle.manifest.citedKeysInAppearanceOrder.contains("smith2025hallucinated"))
        #expect(bundle.manifest.citedKeysInAppearanceOrder.contains("vaswani2017attention"))
        #expect(bundle.manifest.inlinedFiles.contains("sections/methodology.tex"))
    }

    @Test("AcademicArchiveBundleCodec POSIX USTAR tarball round-trip and SHA-256 tamper detection on disk")
    func archiveBundleUSTARTarballRoundTripAndTamperVerification() throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-export")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try ScholarProjectDatabase.inMemory(seedDemo: true)
        defer { db.close() }

        let codec = AcademicArchiveBundleCodec()
        var opts = SubmissionArchiveOptions.arxivDefault
        opts.allowUnverifiedCitationsOverride = true
        let bundle = try codec.buildSubmissionBundle(from: db, options: opts)

        // 1. POSIX USTAR tarball round-trip in memory
        let tarData = codec.encodeSubmissionTarball(from: bundle, options: .arxivDefault)
        #expect(tarData.count % 512 == 0)
        let unpacked = try codec.decodeSubmissionTarball(tarData)
        #expect(String(decoding: unpacked["ms.tex"] ?? Data(), as: UTF8.self) == bundle.flattenedTexContent)
        #expect(String(decoding: unpacked["references.bib"] ?? Data(), as: UTF8.self) == bundle.filteredBibContent)
        #expect(String(decoding: unpacked["ms.bbl"] ?? Data(), as: UTF8.self) == bundle.generatedBBLContent)

        // 2. Write to disk and verify intact SHA-256 Merkle bundle digest
        try codec.writeBundle(bundle, to: tempDir, options: .arxivDefault)
        let cleanVerify = try codec.verifyExportedBundle(at: tempDir)
        #expect(cleanVerify.isValid)
        #expect(cleanVerify.missingOrTamperedFiles.isEmpty)
        #expect(cleanVerify.expectedBundleSHA256 == cleanVerify.recomputedBundleSHA256)

        // 3. Tamper with ms.tex on disk -> verifyExportedBundle MUST catch SHA-256 mismatch!
        let msTexURL = tempDir.appendingPathComponent("ms.tex")
        try (bundle.flattenedTexContent + "\n% Tampered post-export!").write(to: msTexURL, atomically: true, encoding: .utf8)
        let tamperedVerify = try codec.verifyExportedBundle(at: tempDir)
        #expect(!tamperedVerify.isValid)
        #expect(tamperedVerify.missingOrTamperedFiles.contains("ms.tex"))
    }

    @Test("AcademicArchiveBundleCodec detects circular \\input cycles during flattening")
    func archiveBundleDetectsCircularInputCycle() {
        let files = [
            "main.tex": "\\documentclass{article}\\begin{document}\\input{loopA}\\end{document}",
            "loopA.tex": "Section A \\input{loopB}",
            "loopB.tex": "Section B \\input{loopA}"
        ]
        #expect(throws: ScholarOSError.self) {
            _ = try AcademicArchiveBundleCodec().buildSubmissionBundle(
                projectTitle: "Cycle Test",
                entryManuscriptPath: "main.tex",
                manuscriptFiles: files,
                bibliographyByKey: [:]
            )
        }
    }

    @Test("ScholarWordCounter accurately counts LaTeX, Typst, and Markdown prose while ignoring math and comments")
    func scholarWordCounterMultiFormatAccuracy() {
        let latex = """
        \\documentclass{article}
        % Ignored comment with many words one two three four
        \\begin{document}
        Exact five prose words here $x^2 + y^2 = z^2$.
        \\end{document}
        """
        let typst = """
        #cite(<vaswani2017>)
        // Ignored Typst comment
        Four clean Typst words @vaswani2017
        """
        let md = "Six simple markdown prose words here."

        #expect(ScholarWordCounter.countAcademicWords(latex, format: .latex) == 5)
        #expect(ScholarWordCounter.countAcademicWords(typst, format: .typst) == 4)
        #expect(ScholarWordCounter.countAcademicWords(md, format: .markdown) == 6)
    }

    // MARK: - M1 Stage 09: S48 Schema v4 -> v5 Migration, Legacy Untrusted VERIFIED & Persisted Provenance TTL

    private final class StoreDialableClock: RegistryClock, @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        private var uptime: TimeInterval = 200.0

        init(initialUTCDate: Date) {
            self.date = initialUTCDate
        }

        func advance(by seconds: TimeInterval) {
            lock.lock()
            date = date.addingTimeInterval(seconds)
            uptime += seconds
            lock.unlock()
        }

        func now() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return uptime
        }

        func currentDate() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }

        func sleep(_ seconds: TimeInterval) async throws {
            advance(by: seconds)
        }
    }

    @Test("M1 Stage 09 (S48 item 4): synthetic v4 DB with legacy VERIFIED migrates cleanly to v5 and treats legacy rows as unchecked; v5 persisted provenance expires via clock")
    func m1Stage09SchemaV4ToV5MigrationLegacyUntrustedAndPostMigrationClockTTL() async throws {
        let tempDir = try makeTempDirectory(prefix: "scholaros-m1-s48-mig")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("legacy_v4.sqlite").path

        // 1. Pre-migration: construct synthetic v4 SQLite database directly and insert a legacy VERIFIED row (no source/date columns)
        do {
            let conn = try ScholarSQLiteWALConnection(databasePath: dbPath)
            defer { conn.close() }
            try ScholarProjectDatabase.migrate(connection: conn, upTo: 4)
            #expect(try conn.userVersion() == 4)
            let authorsJSON = "[{\"familyName\":\"LeCun\",\"givenName\":\"Yann\"}]"
            _ = try conn.execute(
                """
                INSERT INTO bibliography_entries (
                    cite_key, kind, title, authors_json, year, venue, doi,
                    firewall_class, firewall_note, cited_by_json, references_json, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, '[]', '[]', ?);
                """,
                bindings: [
                    "legacy_v4_lecun", "article", "Deep learning", authorsJSON, 2015,
                    "Nature", "10.1038/nature14539", "VERIFIED", "Legacy v4 stored verified", 1_700_000_000.0
                ]
            )
        }

        // Tests/Fixtures/registry was recorded on 2026-11-15 (S75 populates firewallVerifiedAtUTC from recorded fetchedAt)
        let initialUTC = try #require(BibliographyEntry.parseUTCDayStart("2026-11-15")).addingTimeInterval(8 * 3600)
        let clock = StoreDialableClock(initialUTCDate: initialUTC)

        // 2. Open legacy v4 DB via ScholarProjectDatabase -> migrates cleanly to v5 without error; legacy VERIFIED is treated as unchecked!
        do {
            let db = try ScholarProjectDatabase(path: dbPath, clock: clock)
            defer { db.close() }
            #expect(try db.currentSchemaVersion() == 5)
            let migrations = try db.appliedMigrations()
            #expect(migrations.map(\.version) == [1, 2, 3, 4, 5])

            let stats = try db.computeProjectStats()
            #expect(stats.schemaVersion == 5)
            #expect(stats.bibliographyCount == 1)
            #expect(stats.verifiedCitationCount == 0, "Legacy v4 VERIFIED without source/date must NOT count as verified")

            let legacyEntry = try #require(try db.bibliographyEntry(citeKey: "legacy_v4_lecun"))
            #expect(legacyEntry.firewallVerifiedSource == nil)
            #expect(legacyEntry.firewallVerifiedAtUTC == nil)
            #expect(legacyEntry.trustedFirewallClass(at: clock.currentDate()) == .unverified)

            do {
                _ = try db.validateCitationKeyForInsertion("legacy_v4_lecun")
                Issue.record("Expected legacy v4 VERIFIED row without provenance to be rejected on insertion")
            } catch let err as ScholarOSError {
                #expect(err.errorCodeIdentifier == "ERR_UNVERIFIED_CITATION")
            }

            // Completion and hover on legacy v4 entry must NOT show Verified
            let lsp = ScholarLSPWorkspaceService(
                rootFilePath: "main.tex",
                files: ["main.tex": "\\documentclass{article}\\begin{document}\\cite{legacy_v4_lecun}\n\\cite{legacy_}\\end{document}"],
                bibliography: [legacyEntry],
                clock: clock
            )
            let hover = try #require(lsp.hover(atLine: 1, column: 48, in: "main.tex"))
            #expect(hover.firewallClass == .unverified)
            let comp = try #require(lsp.completions(atLine: 2, column: 13, in: "main.tex").first { $0.insertText == "legacy_v4_lecun" })
            #expect(!comp.subtitle.contains("• Verified"))

            // 3. Post-migration v5: verify via replay, persist auditedEntry (carrying source + 2026-11-16) to SQLite
            let replay = try RegistryReplaySession(directoryURL: Self.recordedRegistryFixturesURL)
            let freshLecun = BibliographyEntry(
                citeKey: "real_lecun",
                kind: .article,
                title: "Deep learning",
                authors: [
                    BibAuthor(givenName: "Yann", familyName: "LeCun"),
                    BibAuthor(givenName: "Yoshua", familyName: "Bengio"),
                    BibAuthor(givenName: "Geoffrey", familyName: "Hinton")
                ],
                year: 2015,
                venue: "Nature",
                doi: "10.1038/nature14539"
            )
            let verdict = await CitationVerificationFirewall(clock: clock).verifyAgainstPublicRegistries(
                entry: freshLecun,
                session: replay
            )
            #expect(verdict.firewallClass == .verified)
            try db.upsertBibliographyEntry(verdict.auditedEntry)
        }

        // 4. Reopen v5 DB from disk in a brand-new process handle (zero inRunVerdicts): valid at +29d, expired past +30d!
        let reopened = try ScholarProjectDatabase(path: dbPath, clock: clock)
        defer { reopened.close() }
        #expect(reopened.inRunVerdicts().isEmpty)

        clock.advance(by: 29 * 86_400)
        let allowedAt29d = try reopened.validateCitationKeyForInsertion("real_lecun")
        #expect(allowedAt29d.firewallClass == .verified)
        #expect(allowedAt29d.firewallVerifiedAtUTC == "2026-11-15")
        #expect(try reopened.computeProjectStats().verifiedCitationCount == 1)

        clock.advance(by: 2 * 86_400) // +31d total -> expired!
        #expect(try reopened.computeProjectStats().verifiedCitationCount == 0)
        do {
            _ = try reopened.validateCitationKeyForInsertion("real_lecun", language: .zhHans)
            Issue.record("Expected persisted v5 VERIFIED row to expire past 30 days")
        } catch let ScholarOSError.unverifiedCitationBlocked(_, status, reasonZH) {
            #expect(status == "UNVERIFIED")
            #expect(reasonZH.contains("结论是 2026-11-15 取得的，已过期，需要重新核查"))
        }
    }
}
