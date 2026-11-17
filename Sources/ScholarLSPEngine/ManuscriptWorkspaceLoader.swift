import Foundation
import ScholarBibAndCSL
import ScholarMarkupAST
import ScholarModels

// MARK: - Unified Manuscript Workspace Loader

private final class RecordingDiskSourceProvider: ManuscriptSourceProvider, @unchecked Sendable {
    let baseDirectoryURL: URL
    private let lock = NSLock()
    private var decodedByNormalizedPath: [String: DecodedTextFile] = [:]
    private var encodingOrder: [String] = []

    init(baseDirectoryURL: URL) {
        self.baseDirectoryURL = baseDirectoryURL.standardizedFileURL
    }

    func fileExists(at relativeOrAbsolutePath: String) -> Bool {
        let norm = MultiFileIncludeGraphResolver.normalizeRelativePath(relativeOrAbsolutePath)
        guard !norm.isEmpty else { return false }
        let fullURL = resolveURL(for: norm)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: fullURL.path, isDirectory: &isDir) && !isDir.boolValue
    }

    func readSource(at relativeOrAbsolutePath: String) throws -> String {
        try readDecoded(at: relativeOrAbsolutePath).text
    }

    func readDecoded(at relativeOrAbsolutePath: String) throws -> DecodedTextFile {
        let norm = MultiFileIncludeGraphResolver.normalizeRelativePath(relativeOrAbsolutePath)
        lock.lock()
        if let cached = decodedByNormalizedPath[norm] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fullURL = resolveURL(for: norm)
        let decoded = try ScholarTextFileReader.readRegularFile(atPath: fullURL.path)

        lock.lock()
        if decodedByNormalizedPath[norm] == nil {
            decodedByNormalizedPath[norm] = decoded
            encodingOrder.append(norm)
        }
        let stored = decodedByNormalizedPath[norm] ?? decoded
        lock.unlock()
        return stored
    }

    func snapshotDecodedFiles() -> (byPath: [String: DecodedTextFile], order: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (decodedByNormalizedPath, encodingOrder)
    }

    private func resolveURL(for normalizedPath: String) -> URL {
        if normalizedPath.hasPrefix("/") {
            return URL(fileURLWithPath: normalizedPath).standardizedFileURL
        }
        return URL(fileURLWithPath: normalizedPath, relativeTo: baseDirectoryURL).standardizedFileURL
    }
}

/// Unified multi-file manuscript and bibliography loader shared by CLI (`diagnostics`, `outline`),
/// LSP workspace initialization, and MCP.
public struct ManuscriptWorkspaceLoader: Sendable {
    public init() {}

    public static func load(
        rootFilePath: String,
        explicitBibPath: String? = nil,
        syncTeXData: Data? = nil,
        citationStyle: CitationFormatStyle = .apa7,
        clock: any RegistryClock = SystemRegistryClock()
    ) throws -> ScholarLSPWorkspaceService {
        // Validate root file exists as a regular file and can be read (UTF-8 or Windows-1252 fallback).
        _ = try ScholarTextFileReader.readRegularFile(atPath: rootFilePath)

        let rootURL = URL(fileURLWithPath: rootFilePath).standardizedFileURL
        let baseDirURL = rootURL.deletingLastPathComponent()
        let rootRelPath = rootURL.lastPathComponent

        let lexer = IncrementalMarkupLexer(configuration: .losslessCST)
        let parser = HandwrittenMarkupCSTParser(lexer: lexer)
        let macroEngine = MacroExpansionEngine(lexer: lexer)
        let resolver = MultiFileIncludeGraphResolver(lexer: lexer, parser: parser, macroEngine: macroEngine)
        let bibCodec = BibTeXCodec()

        let recordingProvider = RecordingDiskSourceProvider(baseDirectoryURL: baseDirURL)
        let hasExplicitBib = explicitBibPath != nil

        let initialWorkspace = resolver.resolveWorkspace(
            rootFilePath: rootRelPath,
            provider: recordingProvider,
            ignoreBibliographyDirectives: hasExplicitBib
        )

        var manuscriptFiles: [String: String] = [:]
        for relPath in initialWorkspace.includeGraph.documentReadingOrder {
            if let decoded = try? recordingProvider.readDecoded(at: relPath) {
                manuscriptFiles[relPath] = decoded.text
            }
        }

        var entries: [BibliographyEntry] = []
        var rawBibFiles: [String: String] = [:]
        var bibSources: [DiagnosticsBibliographySource] = []
        var entrySourceByKey: [String: String] = [:]
        var loaderDiagnostics: [LSPDiagnostic] = []
        var satisfiedMissingBibPaths: Set<String> = []
        var fallbackBBLFiles: [String: String] = [:]
        var explicitDecodedByPath: [String: DecodedTextFile] = [:]

        var pendingBib003: [(displayPath: String, diag: BibTeXParseDiagnostic, targetKey: String)] = []

        func appendBibDocument(
            _ bibDoc: BibTeXDocument,
            displayPath: String
        ) {
            for entry in bibDoc.entries {
                entries.append(entry)
                if entrySourceByKey[entry.citeKey] == nil {
                    entrySourceByKey[entry.citeKey] = displayPath
                }
            }
            let parseErrs = bibDoc.errors.map { err in
                DiagnosticsBibliographyParseError(
                    key: err.key,
                    startLine: err.startLine,
                    line: err.line,
                    message: err.message
                )
            }
            bibSources.append(
                DiagnosticsBibliographySource(
                    kind: "bib",
                    path: displayPath,
                    entries: Set(bibDoc.entries.map { $0.citeKey.lowercased() }).count,
                    errors: parseErrs
                )
            )
            for err in bibDoc.errors {
                let errLine = max(1, err.line)
                let keyClause = err.key.map { "entry '\($0)' " } ?? ""
                loaderDiagnostics.append(
                    LSPDiagnostic(
                        code: "BIB001",
                        category: .structure,
                        severity: .error,
                        message: "BibTeX parse error in \(keyClause)(started at line \(err.startLine), error at line \(err.line)): \(err.message)",
                        span: TextSpan(
                            filePath: displayPath,
                            start: TextPosition(line: errLine, column: 1),
                            end: TextPosition(line: errLine, column: 1)
                        )
                    )
                )
            }
            for diag in bibDoc.diagnostics {
                let diagLine = max(1, diag.line)
                let diagCol = max(1, diag.column)
                let span = TextSpan(
                    filePath: displayPath,
                    start: TextPosition(line: diagLine, column: diagCol),
                    end: TextPosition(line: diagLine, column: diagCol)
                )
                if diag.code == "BIB002" {
                    loaderDiagnostics.append(
                        LSPDiagnostic(
                            code: "BIB002",
                            category: .structure,
                            severity: .warning,
                            message: diag.message,
                            span: span
                        )
                    )
                } else if diag.code == "BIB003" {
                    let targetKey: String = {
                        if let r = diag.message.range(of: "crossref parent '"),
                           let end = diag.message[r.upperBound...].firstIndex(of: "'") {
                            return String(diag.message[r.upperBound..<end])
                        }
                        return ""
                    }()
                    pendingBib003.append((displayPath: displayPath, diag: diag, targetKey: targetKey))
                }
            }
        }

        if let explicitBibPath {
            let decodedBib = try ScholarTextFileReader.readRegularFile(atPath: explicitBibPath)
            let displayPath = Self.displayRelativePath(explicitBibPath, baseDirURL: baseDirURL)
            explicitDecodedByPath[displayPath] = decodedBib

            let bibDoc = try bibCodec.parseDocument(decodedBib.text)
            rawBibFiles[displayPath] = decodedBib.text
            appendBibDocument(bibDoc, displayPath: displayPath)
        } else {
            let rootStem = (rootRelPath as NSString).deletingPathExtension
            let mainBblRelPath = (rootStem.isEmpty ? rootRelPath : rootStem) + ".bbl"
            let mainBblExists = recordingProvider.fileExists(at: mainBblRelPath)

            var seenBibPaths: Set<String> = []
            var loadedMainBblFallback = false

            for edge in initialWorkspace.includeGraph.edges where edge.isBibliographyResource {
                let targetBibPath = edge.resolvedTargetFile
                if edge.targetExists {
                    guard !seenBibPaths.contains(targetBibPath) else { continue }
                    seenBibPaths.insert(targetBibPath)

                    guard let decodedBib = try? recordingProvider.readDecoded(at: targetBibPath) else {
                        continue
                    }
                    rawBibFiles[targetBibPath] = decodedBib.text
                    let bibDoc = bibCodec.parseDocumentRecovering(decodedBib.text)
                    appendBibDocument(bibDoc, displayPath: targetBibPath)
                } else if mainBblExists {
                    satisfiedMissingBibPaths.insert(targetBibPath)
                    if !loadedMainBblFallback {
                        loadedMainBblFallback = true
                        if let decodedBbl = try? recordingProvider.readDecoded(at: mainBblRelPath) {
                            fallbackBBLFiles[mainBblRelPath] = decodedBbl.text
                        }
                        bibSources.append(
                            DiagnosticsBibliographySource(
                                kind: "bbl",
                                path: mainBblRelPath,
                                entries: 0
                            )
                        )
                    }
                    loaderDiagnostics.append(
                        LSPDiagnostic(
                            code: "BIB_FROM_BBL",
                            category: .structure,
                            severity: .info,
                            message: "Bibliography resource '\(targetBibPath)' not found; reading '\(mainBblRelPath)' instead.",
                            span: edge.directiveSpan
                        )
                    )
                }
            }
        }

        // Resolve cross-file `crossref` parents across multiple `.bib` files and emit `BIB003` only when absent everywhere.
        if !pendingBib003.isEmpty {
            var firstEntryByLowerKey: [String: BibliographyEntry] = [:]
            for entry in entries where firstEntryByLowerKey[entry.citeKey.lowercased()] == nil {
                firstEntryByLowerKey[entry.citeKey.lowercased()] = entry
            }
            entries = entries.map { child in
                guard let crKey = child.crossref?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !crKey.isEmpty,
                      crKey.lowercased() != child.citeKey.lowercased(),
                      let parent = firstEntryByLowerKey[crKey.lowercased()]
                else {
                    return child
                }
                var updated = child
                if updated.year == nil { updated.year = parent.year }
                if updated.venue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { updated.venue = parent.venue }
                if (updated.publisher ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { updated.publisher = parent.publisher }
                if (updated.volume ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { updated.volume = parent.volume }
                if (updated.issue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { updated.issue = parent.issue }
                if (updated.pages ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { updated.pages = parent.pages }
                if updated.authors.isEmpty && !updated.authorsTruncated {
                    updated.authors = parent.authors
                    updated.authorsTruncated = parent.authorsTruncated
                }
                return updated
            }
            for item in pendingBib003 where firstEntryByLowerKey[item.targetKey.lowercased()] == nil {
                let diagLine = max(1, item.diag.line)
                let diagCol = max(1, item.diag.column)
                loaderDiagnostics.append(
                    LSPDiagnostic(
                        code: "BIB003",
                        category: .structure,
                        severity: .warning,
                        message: item.diag.message,
                        span: TextSpan(
                            filePath: item.displayPath,
                            start: TextPosition(line: diagLine, column: diagCol),
                            end: TextPosition(line: diagLine, column: diagCol)
                        )
                    )
                )
            }
        }

        // Collect file encodings and emit WARNING ENC001 for every file decoded via Windows-1252 fallback.
        let snapshot = recordingProvider.snapshotDecodedFiles()
        var encodingsByPath: [String: String] = [:]
        var emittedEncodingWarningPaths: Set<String> = []

        for path in snapshot.order {
            guard let decoded = snapshot.byPath[path] else { continue }
            encodingsByPath[path] = decoded.encodingName
            if decoded.usedFallbackEncoding && emittedEncodingWarningPaths.insert(path).inserted {
                loaderDiagnostics.append(Self.makeEncodingFallbackDiagnostic(forPath: path))
            }
        }
        for path in explicitDecodedByPath.keys.sorted() {
            guard let decoded = explicitDecodedByPath[path] else { continue }
            encodingsByPath[path] = decoded.encodingName
            if decoded.usedFallbackEncoding && emittedEncodingWarningPaths.insert(path).inserted {
                loaderDiagnostics.append(Self.makeEncodingFallbackDiagnostic(forPath: path))
            }
        }

        let service = ScholarLSPWorkspaceService(
            rootFilePath: rootRelPath,
            files: manuscriptFiles,
            bibliography: entries,
            bibliographyFiles: rawBibFiles,
            parseRawBibliographyFiles: false,
            syncTeXData: syncTeXData,
            citationStyle: citationStyle,
            clock: clock
        )
        service.configureSourceMetadata(
            fileEncodingsByPath: encodingsByPath,
            bibliographySources: bibSources,
            entrySourceByKey: entrySourceByKey,
            loaderDiagnostics: loaderDiagnostics,
            ignoreBibliographyDirectives: hasExplicitBib,
            satisfiedMissingBibliographyPaths: satisfiedMissingBibPaths,
            fallbackBBLFiles: fallbackBBLFiles
        )
        return service
    }

    private static func makeEncodingFallbackDiagnostic(forPath path: String) -> LSPDiagnostic {
        LSPDiagnostic(
            code: "ENC001",
            category: .structure,
            severity: .warning,
            message: "File '\(path)' is not valid UTF-8; decoded using Windows-1252.",
            span: TextSpan(filePath: path, start: .startOfFile, end: .startOfFile)
        )
    }

    static func displayRelativePath(_ rawPath: String, baseDirURL: URL) -> String {
        let targetURL = URL(fileURLWithPath: rawPath).standardizedFileURL
        let basePath = baseDirURL.standardizedFileURL.path
        let targetPath = targetURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : (basePath + "/")
        if targetPath.hasPrefix(prefix) {
            return MultiFileIncludeGraphResolver.normalizeRelativePath(
                String(targetPath.dropFirst(prefix.count))
            )
        }
        return targetURL.lastPathComponent
    }
}
