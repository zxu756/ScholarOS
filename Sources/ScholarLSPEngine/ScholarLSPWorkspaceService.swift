import Foundation
import ScholarModels
import ScholarMarkupAST
import ScholarBibAndCSL

// MARK: - Incremental Document Buffer & Workspace Telemetry Snapshots

public struct DocumentBufferSnapshot: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(filePath)#v\(version)" }
    public let filePath: String
    public let format: ManuscriptFormat
    public let version: Int
    public let source: String
    public let lineIndex: LineByteIndex
    public let tokens: [MarkupToken]
    public let parseResult: MarkupParseResult
    public let lastRelexMetrics: IncrementalRelexMetrics?

    public init(
        filePath: String,
        format: ManuscriptFormat,
        version: Int,
        source: String,
        lineIndex: LineByteIndex,
        tokens: [MarkupToken],
        parseResult: MarkupParseResult,
        lastRelexMetrics: IncrementalRelexMetrics? = nil
    ) {
        self.filePath = filePath
        self.format = format
        self.version = version
        self.source = source
        self.lineIndex = lineIndex
        self.tokens = tokens
        self.parseResult = parseResult
        self.lastRelexMetrics = lastRelexMetrics
    }
}

public struct ScholarLSPWorkspaceStatus: Sendable, Codable, Hashable {
    public let rootFilePath: String
    public let trackedDocumentCount: Int
    public let bibliographyEntryCount: Int
    public let outlineSectionCount: Int
    public let declaredLabelCount: Int
    public let declaredMacroCount: Int
    public let totalCitationOccurrences: Int
    public let errorDiagnosticCount: Int
    public let warningDiagnosticCount: Int
    public let firewallViolationCount: Int
    public let syncTeXPageCount: Int
    public let isUsingSyntheticSyncTeX: Bool

    public init(
        rootFilePath: String,
        trackedDocumentCount: Int,
        bibliographyEntryCount: Int,
        outlineSectionCount: Int,
        declaredLabelCount: Int,
        declaredMacroCount: Int,
        totalCitationOccurrences: Int,
        errorDiagnosticCount: Int,
        warningDiagnosticCount: Int,
        firewallViolationCount: Int,
        syncTeXPageCount: Int,
        isUsingSyntheticSyncTeX: Bool
    ) {
        self.rootFilePath = rootFilePath
        self.trackedDocumentCount = trackedDocumentCount
        self.bibliographyEntryCount = bibliographyEntryCount
        self.outlineSectionCount = outlineSectionCount
        self.declaredLabelCount = declaredLabelCount
        self.declaredMacroCount = declaredMacroCount
        self.totalCitationOccurrences = totalCitationOccurrences
        self.errorDiagnosticCount = errorDiagnosticCount
        self.warningDiagnosticCount = warningDiagnosticCount
        self.firewallViolationCount = firewallViolationCount
        self.syncTeXPageCount = syncTeXPageCount
        self.isUsingSyntheticSyncTeX = isUsingSyntheticSyncTeX
    }
}

// MARK: - Thread-Safe Unified ScholarLSPWorkspaceService Coordinator

public final class ScholarLSPWorkspaceService: @unchecked Sendable {
    public let lexer: IncrementalMarkupLexer
    public let parser: HandwrittenMarkupCSTParser
    public let macroEngine: MacroExpansionEngine
    public let includeResolver: MultiFileIncludeGraphResolver
    public let metricsAnalyzer: AcademicManuscriptMetricsAnalyzer
    public let completionEngine: AcademicCompletionEngine
    public let navigationEngine: HoverDefinitionAndReferencesEngine
    public let diagnosticsEngine: WorkspaceDiagnosticsAndQuickFixEngine
    public let renameRefactorer: ScholarRenameRefactorer
    public let syntheticSyncTeXBuilder: SyntheticSyncTeXBuilder
    public let bibCodec: BibTeXCodec
    public let cslFormatter: CSLCitationFormatterEngine
    public let citationFirewall: CitationVerificationFirewall

    private struct InternalState {
        var rootFilePath: String
        var citationStyle: CitationFormatStyle
        var documents: [String: DocumentBufferSnapshot]
        var bibliographyByKey: [String: BibliographyEntry]
        var orderedBibliographyKeys: [String]
        var bibliographyRawFiles: [String: String]
        var cachedWorkspaceAST: MergedManuscriptWorkspaceAST?
        var cachedDiagnosticsReport: WorkspaceDiagnosticsReport?
        var externalSyncTeXSolver: SyncTeXCoordinateSolver?
        var cachedSyntheticSyncTeXSolver: SyncTeXCoordinateSolver?
    }

    private let lock = NSLock()
    private var state: InternalState

    public init(
        rootFilePath: String = "main.tex",
        files: [String: String] = [:],
        bibliography: [BibliographyEntry] = [],
        bibliographyFiles: [String: String] = [:],
        syncTeXData: Data? = nil,
        citationStyle: CitationFormatStyle = .apa7
    ) {
        let sharedLexer = IncrementalMarkupLexer(configuration: .losslessCST)
        let sharedParser = HandwrittenMarkupCSTParser(lexer: sharedLexer)
        let sharedMacro = MacroExpansionEngine(lexer: sharedLexer)
        let sharedResolver = MultiFileIncludeGraphResolver(lexer: sharedLexer, parser: sharedParser, macroEngine: sharedMacro)
        let sharedCSL = CSLCitationFormatterEngine()
        let sharedFirewall = CitationVerificationFirewall()

        self.lexer = sharedLexer
        self.parser = sharedParser
        self.macroEngine = sharedMacro
        self.includeResolver = sharedResolver
        self.metricsAnalyzer = AcademicManuscriptMetricsAnalyzer(lexer: sharedLexer, parser: sharedParser, includeResolver: sharedResolver)
        self.completionEngine = AcademicCompletionEngine(cslFormatter: sharedCSL, firewall: sharedFirewall)
        self.navigationEngine = HoverDefinitionAndReferencesEngine(macroEngine: sharedMacro, cslFormatter: sharedCSL, firewall: sharedFirewall)
        self.diagnosticsEngine = WorkspaceDiagnosticsAndQuickFixEngine(firewall: sharedFirewall)
        self.renameRefactorer = ScholarRenameRefactorer()
        self.syntheticSyncTeXBuilder = SyntheticSyncTeXBuilder()
        self.bibCodec = BibTeXCodec()
        self.cslFormatter = sharedCSL
        self.citationFirewall = sharedFirewall

        let normRoot = Self.normalizeWorkspacePath(rootFilePath)
        var initialDocs: [String: DocumentBufferSnapshot] = [:]
        for (rawPath, content) in files {
            let normPath = Self.normalizeWorkspacePath(rawPath)
            let fmt = ManuscriptFormat.detect(fromPath: normPath)
            let lineIdx = LineByteIndex(source: content)
            let toks = sharedLexer.tokenize(source: content, format: fmt, filePath: normPath)
            let pr = sharedParser.parse(tokens: toks, format: fmt, filePath: normPath)
            initialDocs[normPath] = DocumentBufferSnapshot(
                filePath: normPath,
                format: fmt,
                version: 1,
                source: content,
                lineIndex: lineIdx,
                tokens: toks,
                parseResult: pr
            )
        }

        var bibMap: [String: BibliographyEntry] = [:]
        var bibOrder: [String] = []
        for entry in bibliography {
            if bibMap[entry.citeKey] == nil {
                bibOrder.append(entry.citeKey)
            }
            bibMap[entry.citeKey] = entry
        }

        var rawBibs: [String: String] = [:]
        for (bPath, bText) in bibliographyFiles {
            let normBib = Self.normalizeWorkspacePath(bPath)
            rawBibs[normBib] = bText
            if let parsed = try? bibCodec.parse(bText) {
                for entry in parsed {
                    if bibMap[entry.citeKey] == nil {
                        bibOrder.append(entry.citeKey)
                        bibMap[entry.citeKey] = entry
                    }
                }
            }
        }

        let extSolver: SyncTeXCoordinateSolver?
        if let syncData = syncTeXData {
            extSolver = try? SyncTeXCoordinateSolver(data: syncData)
        } else {
            extSolver = nil
        }

        self.state = InternalState(
            rootFilePath: normRoot,
            citationStyle: citationStyle,
            documents: initialDocs,
            bibliographyByKey: bibMap,
            orderedBibliographyKeys: bibOrder,
            bibliographyRawFiles: rawBibs,
            cachedWorkspaceAST: nil,
            cachedDiagnosticsReport: nil,
            externalSyncTeXSolver: extSolver,
            cachedSyntheticSyncTeXSolver: nil
        )
    }

    /// Loads an entire scholarly project directory from disk (`.tex`, `.typ`, `.md`, `.bib`, and optional `.synctex.gz` / `.synctex`).
    public static func loadFromDirectory(
        projectDirectory: String,
        rootFilePath: String = "main.tex",
        citationStyle: CitationFormatStyle = .apa7
    ) throws -> ScholarLSPWorkspaceService {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectDirectory, isDirectory: &isDir), isDir.boolValue else {
            throw ScholarOSError.fileNotFound(projectDirectory)
        }

        let rootURL = URL(fileURLWithPath: projectDirectory, isDirectory: true).standardizedFileURL
        let rootPathStd = rootURL.path
        var manuscriptFiles: [String: String] = [:]
        var bibFiles: [String: String] = [:]
        var discoveredSyncTeXData: Data? = nil

        if let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let stdFile = fileURL.standardizedFileURL.path
                guard stdFile.hasPrefix(rootPathStd) else { continue }
                var rel = String(stdFile.dropFirst(rootPathStd.count))
                if rel.hasPrefix("/") { rel.removeFirst() }
                let lower = rel.lowercased()

                if lower.hasSuffix(".tex") || lower.hasSuffix(".typ") || lower.hasSuffix(".md") || lower.hasSuffix(".markdown") {
                    if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                        manuscriptFiles[rel] = content
                    }
                } else if lower.hasSuffix(".bib") {
                    if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                        bibFiles[rel] = content
                    }
                } else if discoveredSyncTeXData == nil && (lower.hasSuffix(".synctex.gz") || lower.hasSuffix(".synctex")) {
                    discoveredSyncTeXData = try? Data(contentsOf: fileURL)
                }
            }
        }

        return ScholarLSPWorkspaceService(
            rootFilePath: rootFilePath,
            files: manuscriptFiles,
            bibliography: [],
            bibliographyFiles: bibFiles,
            syncTeXData: discoveredSyncTeXData,
            citationStyle: citationStyle
        )
    }

    // MARK: - Lock Helper

    private func withLock<T>(_ body: (inout InternalState) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    // MARK: - Document Buffer & Incremental Token Re-Lexing Management

    public var rootFilePath: String {
        withLock { $0.rootFilePath }
    }

    public func setRootFilePath(_ newRoot: String) {
        withLock { st in
            let norm = Self.normalizeWorkspacePath(newRoot)
            if st.rootFilePath != norm {
                st.rootFilePath = norm
                invalidateDerivedCaches(&st)
            }
        }
    }

    public var citationStyle: CitationFormatStyle {
        get { withLock { $0.citationStyle } }
        set { withLock { $0.citationStyle = newValue } }
    }

    public var allManuscriptFiles: [String: String] {
        withLock { st in
            var out: [String: String] = [:]
            for (k, snap) in st.documents {
                out[k] = snap.source
            }
            return out
        }
    }

    public func sourceText(for filePath: String) -> String? {
        let norm = Self.normalizeWorkspacePath(filePath)
        return withLock { st in
            st.documents[norm]?.source ?? st.bibliographyRawFiles[norm]
        }
    }

    public func documentSnapshot(for filePath: String) -> DocumentBufferSnapshot? {
        let norm = Self.normalizeWorkspacePath(filePath)
        return withLock { $0.documents[norm] }
    }

    @discardableResult
    public func openOrReplaceDocument(filePath: String, source: String) -> DocumentBufferSnapshot {
        let norm = Self.normalizeWorkspacePath(filePath)
        let fmt = ManuscriptFormat.detect(fromPath: norm)
        let lineIdx = LineByteIndex(source: source)
        let toks = lexer.tokenize(source: source, format: fmt, filePath: norm)
        let parsed = parser.parse(tokens: toks, format: fmt, filePath: norm)

        return withLock { st in
            let nextVersion = (st.documents[norm]?.version ?? 0) + 1
            let snap = DocumentBufferSnapshot(
                filePath: norm,
                format: fmt,
                version: nextVersion,
                source: source,
                lineIndex: lineIdx,
                tokens: toks,
                parseResult: parsed,
                lastRelexMetrics: nil
            )
            st.documents[norm] = snap
            invalidateDerivedCaches(&st)
            return snap
        }
    }

    /// Applies an incremental UTF-8 byte-range edit to `filePath`, splicing only the dirty line window
    /// via `IncrementalMarkupLexer.relexEditDetailed` and re-parsing from the spliced token stream!
    @discardableResult
    public func applyIncrementalEdit(
        filePath: String,
        editByteRange: Range<Int>,
        replacementText: String
    ) throws -> IncrementalRelexResult {
        let norm = Self.normalizeWorkspacePath(filePath)
        return try withLock { st in
            guard let existing = st.documents[norm] else {
                throw ScholarOSError.fileNotFound(norm)
            }
            var utf8Bytes = Array(existing.source.utf8)
            let oldLen = utf8Bytes.count
            let clampedStart = max(0, min(oldLen, editByteRange.lowerBound))
            let clampedEnd = max(clampedStart, min(oldLen, editByteRange.upperBound))
            let safeRange = clampedStart..<clampedEnd

            utf8Bytes.replaceSubrange(safeRange, with: replacementText.utf8)
            let updatedSource = String(decoding: utf8Bytes, as: UTF8.self)

            let relexResult = lexer.relexEditDetailed(
                previousTokens: existing.tokens,
                previousSourceLengthUTF8: oldLen,
                updatedSource: updatedSource,
                editByteRange: safeRange,
                filePath: norm,
                format: existing.format
            )

            let updatedParse = parser.parse(
                tokens: relexResult.tokens,
                format: existing.format,
                filePath: norm
            )

            st.documents[norm] = DocumentBufferSnapshot(
                filePath: norm,
                format: existing.format,
                version: existing.version + 1,
                source: updatedSource,
                lineIndex: relexResult.lineIndex,
                tokens: relexResult.tokens,
                parseResult: updatedParse,
                lastRelexMetrics: relexResult.metrics
            )
            invalidateDerivedCaches(&st)
            return relexResult
        }
    }

    /// Convenience incremental edit using 1-based `(line, column)` start/end positions.
    @discardableResult
    public func applyRangeEdit(
        filePath: String,
        startLine: Int,
        startColumn: Int,
        endLine: Int,
        endColumn: Int,
        replacementText: String
    ) throws -> IncrementalRelexResult {
        let norm = Self.normalizeWorkspacePath(filePath)
        let byteRange: Range<Int> = try withLock { st in
            guard let doc = st.documents[norm] else {
                throw ScholarOSError.fileNotFound(norm)
            }
            let s = doc.lineIndex.utf8Offset(forLine: max(1, startLine), column: max(1, startColumn), in: doc.source)
            let e = doc.lineIndex.utf8Offset(forLine: max(1, endLine), column: max(1, endColumn), in: doc.source)
            return min(s, e)..<max(s, e)
        }
        return try applyIncrementalEdit(filePath: norm, editByteRange: byteRange, replacementText: replacementText)
    }

    @discardableResult
    public func applyTextEdit(_ edit: LSPTextEdit) throws -> IncrementalRelexResult {
        try applyIncrementalEdit(
            filePath: edit.filePath,
            editByteRange: edit.replaceByteRange,
            replacementText: edit.replacementText
        )
    }

    /// Atomically applies a multi-file `LSPWorkspaceEdit` across manuscript documents and `.bib` files.
    @discardableResult
    public func applyWorkspaceEdit(_ workspaceEdit: LSPWorkspaceEdit) -> [String: String] {
        withLock { st in
            var combinedFiles: [String: String] = [:]
            for (k, snap) in st.documents { combinedFiles[k] = snap.source }
            for (k, bib) in st.bibliographyRawFiles { combinedFiles[k] = bib }

            let updatedMap = workspaceEdit.apply(toFiles: combinedFiles)
            var changedAny = false

            for (path, newContent) in updatedMap {
                if let oldSnap = st.documents[path], oldSnap.source != newContent {
                    changedAny = true
                    // If single edit in this file, run incremental token splicing; otherwise re-tokenize cleanly
                    if let fileEdits = workspaceEdit.editsByFile[path], fileEdits.count == 1 {
                        let single = fileEdits[0]
                        let oldLen = oldSnap.lineIndex.totalUTF8Bytes
                        let s = max(0, min(oldLen, single.replaceByteRange.lowerBound))
                        let e = max(s, min(oldLen, single.replaceByteRange.upperBound))
                        let relex = lexer.relexEditDetailed(
                            previousTokens: oldSnap.tokens,
                            previousSourceLengthUTF8: oldLen,
                            updatedSource: newContent,
                            editByteRange: s..<e,
                            filePath: path,
                            format: oldSnap.format
                        )
                        let pr = parser.parse(tokens: relex.tokens, format: oldSnap.format, filePath: path)
                        st.documents[path] = DocumentBufferSnapshot(
                            filePath: path,
                            format: oldSnap.format,
                            version: oldSnap.version + 1,
                            source: newContent,
                            lineIndex: relex.lineIndex,
                            tokens: relex.tokens,
                            parseResult: pr,
                            lastRelexMetrics: relex.metrics
                        )
                    } else {
                        let lineIdx = LineByteIndex(source: newContent)
                        let toks = lexer.tokenize(source: newContent, format: oldSnap.format, filePath: path)
                        let pr = parser.parse(tokens: toks, format: oldSnap.format, filePath: path)
                        st.documents[path] = DocumentBufferSnapshot(
                            filePath: path,
                            format: oldSnap.format,
                            version: oldSnap.version + 1,
                            source: newContent,
                            lineIndex: lineIdx,
                            tokens: toks,
                            parseResult: pr,
                            lastRelexMetrics: nil
                        )
                    }
                } else if st.bibliographyRawFiles[path] != nil && st.bibliographyRawFiles[path] != newContent {
                    changedAny = true
                    st.bibliographyRawFiles[path] = newContent
                    if let reparsed = try? bibCodec.parse(newContent) {
                        var newBibMap: [String: BibliographyEntry] = [:]
                        var newOrder: [String] = []
                        for entry in reparsed {
                            if newBibMap[entry.citeKey] == nil {
                                newOrder.append(entry.citeKey)
                            }
                            newBibMap[entry.citeKey] = entry
                        }
                        st.bibliographyByKey = newBibMap
                        st.orderedBibliographyKeys = newOrder
                    }
                }
            }

            if changedAny {
                invalidateDerivedCaches(&st)
            }
            return updatedMap
        }
    }

    public func closeOrRemoveDocument(filePath: String) {
        let norm = Self.normalizeWorkspacePath(filePath)
        withLock { st in
            if st.documents.removeValue(forKey: norm) != nil {
                invalidateDerivedCaches(&st)
            }
        }
    }

    // MARK: - Bibliography & Hardware-Gated Citation Firewall Management

    public var bibliographyEntries: [BibliographyEntry] {
        withLock { st in
            st.orderedBibliographyKeys.compactMap { st.bibliographyByKey[$0] }
        }
    }

    public func bibliographyEntry(forCiteKey citeKey: String) -> BibliographyEntry? {
        withLock { $0.bibliographyByKey[citeKey] }
    }

    public func setBibliography(_ entries: [BibliographyEntry]) {
        withLock { st in
            var map: [String: BibliographyEntry] = [:]
            var order: [String] = []
            for entry in entries {
                if map[entry.citeKey] == nil {
                    order.append(entry.citeKey)
                }
                map[entry.citeKey] = entry
            }
            st.bibliographyByKey = map
            st.orderedBibliographyKeys = order
            st.cachedDiagnosticsReport = nil
        }
    }

    public func upsertBibliographyEntry(_ entry: BibliographyEntry) {
        withLock { st in
            if st.bibliographyByKey[entry.citeKey] == nil {
                st.orderedBibliographyKeys.append(entry.citeKey)
            }
            st.bibliographyByKey[entry.citeKey] = entry
            st.cachedDiagnosticsReport = nil
        }
    }

    public func removeBibliographyEntry(citeKey: String) {
        withLock { st in
            st.bibliographyByKey.removeValue(forKey: citeKey)
            st.orderedBibliographyKeys.removeAll { $0 == citeKey }
            st.cachedDiagnosticsReport = nil
        }
    }

    @discardableResult
    public func loadBibTeXSource(_ bibSource: String, virtualFilePath: String = "references.bib") throws -> [BibliographyEntry] {
        let normBib = Self.normalizeWorkspacePath(virtualFilePath)
        let parsed = try bibCodec.parse(bibSource)
        withLock { st in
            st.bibliographyRawFiles[normBib] = bibSource
            for entry in parsed {
                if st.bibliographyByKey[entry.citeKey] == nil {
                    st.orderedBibliographyKeys.append(entry.citeKey)
                }
                st.bibliographyByKey[entry.citeKey] = entry
            }
            st.cachedDiagnosticsReport = nil
        }
        return parsed
    }

    public func auditWorkspaceCitations() -> CitationFirewallAuditReport {
        let entries = bibliographyEntries
        return citationFirewall.auditLibrary(entries)
    }

    /// Hardware-gated assertion throwing `ScholarOSError.unverifiedCitationBlocked` (`ERR_UNVERIFIED_CITATION`)
    /// if ANY cited key in the manuscript is missing, unverified, or blocked/retracted!
    public func assertAllCitedEntriesPassFirewall() throws {
        let (ws, bibMap) = withLock { st -> (MergedManuscriptWorkspaceAST, [String: BibliographyEntry]) in
            (ensureWorkspaceAST(&st), st.bibliographyByKey)
        }

        let uniqueCited = Set(ws.symbolTable.allCitationOccurrences.map(\.citeKey)).sorted()
        _ = try citationFirewall.assertAllCitationsAllowed(citeKeys: uniqueCited, in: bibMap)
    }

    /// Runs live/mocked online registry verification (Crossref, arXiv, PubMed) across all bibliography entries
    /// and updates the workspace bibliography index atomically.
    public func verifyCitationsOnline(
        using session: any CitationRegistrySession = LiveURLSessionRegistryClient()
    ) async -> CitationFirewallAuditReport {
        let snapshotEntries = bibliographyEntries
        var updatedEntries: [BibliographyEntry] = []
        updatedEntries.reserveCapacity(snapshotEntries.count)

        for entry in snapshotEntries {
            let verdict = await citationFirewall.verifyAgainstPublicRegistries(entry: entry, session: session)
            updatedEntries.append(verdict.auditedEntry)
        }

        setBibliography(updatedEntries)
        return citationFirewall.auditLibrary(updatedEntries)
    }

    // MARK: - Workspace AST, Document Outline, Symbol Table & Metrics

    public var currentWorkspaceAST: MergedManuscriptWorkspaceAST {
        withLock { ensureWorkspaceAST(&$0) }
    }

    public var documentOutline: [DocumentOutlineEntry] {
        currentWorkspaceAST.outline
    }

    public var symbolTable: ManuscriptSymbolTable {
        currentWorkspaceAST.symbolTable
    }

    public func manuscriptMetrics(venues: [AcademicVenuePreset] = AcademicVenuePreset.allCases) -> ManuscriptMetricsReport {
        let ws = currentWorkspaceAST
        return metricsAnalyzer.analyze(workspace: ws, venues: venues)
    }

    public func statusSummary() -> ScholarLSPWorkspaceStatus {
        withLock { st in
            let ws = ensureWorkspaceAST(&st)
            let diagRep = ensureDiagnosticsReport(&st, workspace: ws)
            let solver = ensureSyncTeXSolver(&st, workspace: ws)
            return ScholarLSPWorkspaceStatus(
                rootFilePath: st.rootFilePath,
                trackedDocumentCount: st.documents.count,
                bibliographyEntryCount: st.bibliographyByKey.count,
                outlineSectionCount: ws.outline.count,
                declaredLabelCount: ws.symbolTable.labelsByKey.count,
                declaredMacroCount: ws.symbolTable.macrosByName.count,
                totalCitationOccurrences: ws.symbolTable.allCitationOccurrences.count,
                errorDiagnosticCount: diagRep.errorCount,
                warningDiagnosticCount: diagRep.warningCount,
                firewallViolationCount: diagRep.firewallViolationCount,
                syncTeXPageCount: solver.pageCount,
                isUsingSyntheticSyncTeX: st.externalSyncTeXSolver == nil
            )
        }
    }

    // MARK: - Context-Aware Completions

    public func completionContext(at position: TextPosition, in filePath: String) -> AcademicCompletionContext? {
        let norm = Self.normalizeWorkspacePath(filePath)
        return withLock { st in
            guard let doc = st.documents[norm] else { return nil }
            return completionEngine.detectContext(in: doc.source, filePath: norm, at: position, lineIndex: doc.lineIndex)
        }
    }

    public func completions(
        at position: TextPosition,
        in filePath: String,
        maxItems: Int = 50
    ) -> [LSPCompletionItem] {
        let norm = Self.normalizeWorkspacePath(filePath)
        let (docOpt, ws, bibList, knownFiles) = withLock { st -> (DocumentBufferSnapshot?, MergedManuscriptWorkspaceAST, [BibliographyEntry], [String]) in
            let w = ensureWorkspaceAST(&st)
            let b = st.orderedBibliographyKeys.compactMap { st.bibliographyByKey[$0] }
            let files = Array(st.documents.keys) + Array(st.bibliographyRawFiles.keys)
            return (st.documents[norm], w, b, files)
        }
        guard let doc = docOpt else { return [] }
        let ctx = completionEngine.detectContext(in: doc.source, filePath: norm, at: position, lineIndex: doc.lineIndex)
        return completionEngine.complete(
            for: ctx,
            in: doc.source,
            symbolTable: ws.symbolTable,
            bibliography: bibList,
            workspaceFiles: knownFiles,
            maxItems: maxItems
        )
    }

    public func completions(
        atLine line: Int,
        column: Int,
        in filePath: String,
        maxItems: Int = 50
    ) -> [LSPCompletionItem] {
        completions(at: TextPosition(line: line, column: column), in: filePath, maxItems: maxItems)
    }

    // MARK: - Rich Hover, Go-To-Definition & Find-All-References

    public func hover(at position: TextPosition, in filePath: String) -> LSPHoverCard? {
        let norm = Self.normalizeWorkspacePath(filePath)
        let (ws, sources, bibList, bibRaw) = snapshotNavigationInputs()
        return navigationEngine.hover(
            at: position,
            in: norm,
            workspace: ws,
            sourcesByFile: sources,
            bibliography: bibList,
            bibliographyFiles: bibRaw
        )
    }

    public func hover(atLine line: Int, column: Int, in filePath: String) -> LSPHoverCard? {
        hover(at: TextPosition(line: line, column: column), in: filePath)
    }

    public func definition(at position: TextPosition, in filePath: String) -> [LSPLocationLink] {
        let norm = Self.normalizeWorkspacePath(filePath)
        let (ws, sources, bibList, bibRaw) = snapshotNavigationInputs()
        return navigationEngine.definition(
            at: position,
            in: norm,
            workspace: ws,
            sourcesByFile: sources,
            bibliography: bibList,
            bibliographyFiles: bibRaw
        )
    }

    public func definition(atLine line: Int, column: Int, in filePath: String) -> [LSPLocationLink] {
        definition(at: TextPosition(line: line, column: column), in: filePath)
    }

    public func findReferences(
        at position: TextPosition,
        in filePath: String,
        includeDeclaration: Bool = true
    ) -> [LSPLocationLink] {
        let norm = Self.normalizeWorkspacePath(filePath)
        let (ws, sources, bibList, bibRaw) = snapshotNavigationInputs()
        return navigationEngine.findReferences(
            at: position,
            in: norm,
            workspace: ws,
            sourcesByFile: sources,
            bibliography: bibList,
            bibliographyFiles: bibRaw,
            includeDeclaration: includeDeclaration
        )
    }

    public func findReferences(
        atLine line: Int,
        column: Int,
        in filePath: String,
        includeDeclaration: Bool = true
    ) -> [LSPLocationLink] {
        findReferences(at: TextPosition(line: line, column: column), in: filePath, includeDeclaration: includeDeclaration)
    }

    // MARK: - Unified Workspace Diagnostics & Quick-Fix Code Actions

    public func diagnosticsReport() -> WorkspaceDiagnosticsReport {
        withLock { st in
            let ws = ensureWorkspaceAST(&st)
            return ensureDiagnosticsReport(&st, workspace: ws)
        }
    }

    public func diagnostics(in filePath: String? = nil) -> [LSPDiagnostic] {
        let report = diagnosticsReport()
        guard let rawFilter = filePath else { return report.diagnostics }
        let norm = Self.normalizeWorkspacePath(rawFilter)
        return report.diagnostics.filter { $0.span.filePath == norm }
    }

    public func codeActions(in filePath: String? = nil, overlapping range: TextSpan? = nil) -> [LSPCodeAction] {
        let report = diagnosticsReport()
        let normFile = filePath.map(Self.normalizeWorkspacePath)
        return report.codeActions.filter { action in
            if let f = normFile, action.workspaceEdit.editsByFile[f] == nil {
                return false
            }
            if let r = range {
                let normRFile = Self.normalizeWorkspacePath(r.filePath)
                guard let edits = action.workspaceEdit.editsByFile[normRFile] else { return false }
                return edits.contains {
                    $0.span.start.utf8Offset <= r.end.utf8Offset && r.start.utf8Offset <= $0.span.end.utf8Offset
                }
            }
            return true
        }
    }

    @discardableResult
    public func applyCodeAction(id actionID: String) throws -> [String: String] {
        let report = diagnosticsReport()
        guard let action = report.codeActions.first(where: { $0.id == actionID }) else {
            throw ScholarOSError.invalidCLIArguments("Code action '\(actionID)' not found in current workspace diagnostics.")
        }
        return applyWorkspaceEdit(action.workspaceEdit)
    }

    // MARK: - Safe Project-Wide Rename Refactoring

    public func renameLabel(
        oldKey: String,
        newKey: String,
        applyImmediately: Bool = false
    ) -> LSPWorkspaceEdit {
        let (ws, sources, _, _) = snapshotNavigationInputs()
        let edit = renameRefactorer.renameLabel(oldKey: oldKey, newKey: newKey, in: ws, sourcesByFile: sources)
        if applyImmediately && edit.affectedEditCount > 0 {
            _ = applyWorkspaceEdit(edit)
        }
        return edit
    }

    public func renameCiteKey(
        oldKey: String,
        newKey: String,
        applyImmediately: Bool = false
    ) -> LSPWorkspaceEdit {
        let (ws, sources, _, bibRaw) = snapshotNavigationInputs()
        let edit = renameRefactorer.renameCiteKey(
            oldKey: oldKey,
            newKey: newKey,
            in: ws,
            sourcesByFile: sources,
            bibliographyFiles: bibRaw
        )
        if applyImmediately {
            withLock { st in
                if let entry = st.bibliographyByKey.removeValue(forKey: oldKey) {
                    let renamedEntry = BibliographyEntry(
                        citeKey: newKey,
                        kind: entry.kind,
                        title: entry.title,
                        authors: entry.authors,
                        year: entry.year,
                        venue: entry.venue,
                        publisher: entry.publisher,
                        volume: entry.volume,
                        issue: entry.issue,
                        pages: entry.pages,
                        doi: entry.doi,
                        arxivID: entry.arxivID,
                        pmid: entry.pmid,
                        url: entry.url,
                        abstractText: entry.abstractText,
                        firewallClass: entry.firewallClass,
                        firewallAuditNote: entry.firewallAuditNote,
                        attachedPDFPath: entry.attachedPDFPath,
                        citedByKeys: entry.citedByKeys,
                        referencesKeys: entry.referencesKeys
                    )
                    st.bibliographyByKey[newKey] = renamedEntry
                    if let idx = st.orderedBibliographyKeys.firstIndex(of: oldKey) {
                        st.orderedBibliographyKeys[idx] = newKey
                    } else {
                        st.orderedBibliographyKeys.append(newKey)
                    }
                    st.cachedDiagnosticsReport = nil
                }
            }
            if edit.affectedEditCount > 0 {
                _ = applyWorkspaceEdit(edit)
            }
        }
        return edit
    }

    public func renameMacro(
        oldName: String,
        newName: String,
        applyImmediately: Bool = false
    ) -> LSPWorkspaceEdit {
        let (ws, sources, _, _) = snapshotNavigationInputs()
        let edit = renameRefactorer.renameMacro(oldName: oldName, newName: newName, in: ws, sourcesByFile: sources)
        if applyImmediately && edit.affectedEditCount > 0 {
            _ = applyWorkspaceEdit(edit)
        }
        return edit
    }

    public func renameSymbol(
        at position: TextPosition,
        in filePath: String,
        newName: String,
        applyImmediately: Bool = false
    ) throws -> LSPWorkspaceEdit {
        let norm = Self.normalizeWorkspacePath(filePath)
        let (ws, sources, bibList, bibRaw) = snapshotNavigationInputs()
        let edit = try renameRefactorer.renameSymbol(
            at: position,
            in: norm,
            newName: newName,
            workspace: ws,
            sourcesByFile: sources,
            bibliography: bibList,
            bibliographyFiles: bibRaw
        )
        if applyImmediately && edit.affectedEditCount > 0 {
            _ = applyWorkspaceEdit(edit)
        }
        return edit
    }

    // MARK: - SyncTeX Bidirectional Navigation & Synthetic Export

    public func loadSyncTeX(data: Data) throws {
        let parsed = try SyncTeXCoordinateSolver(data: data)
        withLock { st in
            st.externalSyncTeXSolver = parsed
        }
    }

    public func loadSyncTeX(fromFilePath path: String) throws {
        let parsed = try SyncTeXCoordinateSolver.load(fromFilePath: path)
        withLock { st in
            st.externalSyncTeXSolver = parsed
        }
    }

    public func clearExternalSyncTeX() {
        withLock { st in
            st.externalSyncTeXSolver = nil
        }
    }

    public var syncTeXSolver: SyncTeXCoordinateSolver {
        withLock { st in
            let ws = ensureWorkspaceAST(&st)
            return ensureSyncTeXSolver(&st, workspace: ws)
        }
    }

    @discardableResult
    public func rebuildSyntheticSyncTeX() -> SyncTeXCoordinateSolver {
        withLock { st in
            let ws = ensureWorkspaceAST(&st)
            let built = (try? syntheticSyncTeXBuilder.buildSolver(from: ws)) ?? SyncTeXCoordinateSolver()
            st.cachedSyntheticSyncTeXSolver = built
            return built
        }
    }

    public func forwardSearch(sourceFile: String, line: Int, column: Int = 1) -> SyncTeXAnchor? {
        syncTeXSolver.forwardSearch(sourceFile: Self.normalizeWorkspacePath(sourceFile), line: line, column: column)
    }

    public func resolveForwardSearch(sourceFile: String, line: Int, column: Int = 1) throws -> SyncTeXAnchor {
        try syncTeXSolver.resolveForwardSearch(sourceFile: Self.normalizeWorkspacePath(sourceFile), line: line, column: column)
    }

    public func inverseSearch(pdfPageIndex: Int, xPt: Double, yPt: Double) -> SyncTeXInverseMatch? {
        syncTeXSolver.inverseSearch(pdfPageIndex: pdfPageIndex, xPt: xPt, yPt: yPt)
    }

    public func resolveInverseSearch(pdfPageIndex: Int, xPt: Double, yPt: Double) throws -> SyncTeXInverseMatch {
        try syncTeXSolver.resolveInverseSearch(pdfPageIndex: pdfPageIndex, xPt: xPt, yPt: yPt)
    }

    public func exportSyntheticSyncTeXData(compressed: Bool = true) throws -> Data {
        let ws = currentWorkspaceAST
        return try syntheticSyncTeXBuilder.buildSyncTeXData(from: ws, compressed: compressed)
    }

    // MARK: - Private Cache Rebuild Helpers

    private func invalidateDerivedCaches(_ st: inout InternalState) {
        st.cachedWorkspaceAST = nil
        st.cachedDiagnosticsReport = nil
        st.cachedSyntheticSyncTeXSolver = nil
    }

    private func ensureWorkspaceAST(_ st: inout InternalState) -> MergedManuscriptWorkspaceAST {
        if let cached = st.cachedWorkspaceAST {
            return cached
        }
        var rawFiles: [String: String] = [:]
        for (path, snap) in st.documents {
            rawFiles[path] = snap.source
        }
        for (bibPath, bibText) in st.bibliographyRawFiles {
            rawFiles[bibPath] = bibText
        }
        if rawFiles[st.rootFilePath] == nil, let firstDocKey = st.documents.keys.sorted().first {
            st.rootFilePath = firstDocKey
        }
        let resolved = includeResolver.resolveWorkspace(rootFilePath: st.rootFilePath, files: rawFiles)
        st.cachedWorkspaceAST = resolved
        return resolved
    }

    private func ensureDiagnosticsReport(
        _ st: inout InternalState,
        workspace: MergedManuscriptWorkspaceAST
    ) -> WorkspaceDiagnosticsReport {
        if let cached = st.cachedDiagnosticsReport {
            return cached
        }
        var sources: [String: String] = [:]
        for (k, snap) in st.documents { sources[k] = snap.source }
        let bibList = st.orderedBibliographyKeys.compactMap { st.bibliographyByKey[$0] }
        let report = diagnosticsEngine.analyze(
            workspace: workspace,
            bibliography: bibList,
            sourcesByFile: sources,
            bibliographyFiles: st.bibliographyRawFiles
        )
        st.cachedDiagnosticsReport = report
        return report
    }

    private func ensureSyncTeXSolver(
        _ st: inout InternalState,
        workspace: MergedManuscriptWorkspaceAST
    ) -> SyncTeXCoordinateSolver {
        if let external = st.externalSyncTeXSolver {
            return external
        }
        if let synthetic = st.cachedSyntheticSyncTeXSolver {
            return synthetic
        }
        let built = (try? syntheticSyncTeXBuilder.buildSolver(from: workspace)) ?? SyncTeXCoordinateSolver()
        st.cachedSyntheticSyncTeXSolver = built
        return built
    }

    private func snapshotNavigationInputs() -> (
        MergedManuscriptWorkspaceAST,
        [String: String],
        [BibliographyEntry],
        [String: String]
    ) {
        withLock { st in
            let ws = ensureWorkspaceAST(&st)
            var sources: [String: String] = [:]
            for (k, snap) in st.documents { sources[k] = snap.source }
            let bibList = st.orderedBibliographyKeys.compactMap { st.bibliographyByKey[$0] }
            return (ws, sources, bibList, st.bibliographyRawFiles)
        }
    }

    private static func normalizeWorkspacePath(_ raw: String) -> String {
        SyncTeXCoordinateSolver.normalizeSyncPath(raw)
    }
}
