import Foundation
import ScholarModels

// MARK: - Multi-File Source Providers (In-Memory, Overlay & Disk)

/// Abstraction supplying manuscript source files for multi-file include resolution,
/// enabling deterministic in-memory unit tests, dirty LSP buffer overlays, and local filesystem projects.
public protocol ManuscriptSourceProvider: Sendable {
    func fileExists(at relativeOrAbsolutePath: String) -> Bool
    func readSource(at relativeOrAbsolutePath: String) throws -> String
}

/// Pure in-memory manuscript file dictionary keyed by normalized relative path.
public struct InMemoryManuscriptSourceProvider: ManuscriptSourceProvider, Sendable {
    private let normalizedFiles: [String: String]

    public init(files: [String: String]) {
        var table: [String: String] = [:]
        table.reserveCapacity(files.count)
        for (rawKey, content) in files {
            let cleanKey = IncludePathNormalizer.normalizePath(rawKey)
            table[cleanKey] = content
        }
        self.normalizedFiles = table
    }

    public func fileExists(at relativeOrAbsolutePath: String) -> Bool {
        let key = IncludePathNormalizer.normalizePath(relativeOrAbsolutePath)
        return normalizedFiles[key] != nil
    }

    public func readSource(at relativeOrAbsolutePath: String) throws -> String {
        let key = IncludePathNormalizer.normalizePath(relativeOrAbsolutePath)
        guard let text = normalizedFiles[key] else {
            throw ScholarOSError.fileNotFound(relativeOrAbsolutePath)
        }
        return text
    }

    public var allFiles: [String: String] {
        normalizedFiles
    }
}

/// Hybrid provider consulting open unsaved editor buffers first and falling back to `projectRootDirectory` on disk.
public struct DiskAndOverlayManuscriptSourceProvider: ManuscriptSourceProvider, Sendable {
    public let projectRootDirectory: String
    private let overlayBuffers: [String: String]

    public init(projectRootDirectory: String, unsavedBuffers: [String: String] = [:]) {
        self.projectRootDirectory = IncludePathNormalizer.normalizePath(projectRootDirectory)
        var table: [String: String] = [:]
        for (k, v) in unsavedBuffers {
            table[IncludePathNormalizer.normalizePath(k)] = v
        }
        self.overlayBuffers = table
    }

    public func fileExists(at relativeOrAbsolutePath: String) -> Bool {
        let norm = IncludePathNormalizer.normalizePath(relativeOrAbsolutePath)
        if overlayBuffers[norm] != nil {
            return true
        }
        let fullPath = resolveFilesystemPath(norm)
        return FileManager.default.fileExists(atPath: fullPath)
    }

    public func readSource(at relativeOrAbsolutePath: String) throws -> String {
        let norm = IncludePathNormalizer.normalizePath(relativeOrAbsolutePath)
        if let dirty = overlayBuffers[norm] {
            return dirty
        }
        let fullPath = resolveFilesystemPath(norm)
        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw ScholarOSError.fileNotFound(relativeOrAbsolutePath)
        }
        return try String(contentsOfFile: fullPath, encoding: .utf8)
    }

    private func resolveFilesystemPath(_ normalizedPath: String) -> String {
        if normalizedPath.hasPrefix("/") {
            return normalizedPath
        }
        if projectRootDirectory.isEmpty || projectRootDirectory == "." {
            return normalizedPath
        }
        return (projectRootDirectory as NSString).appendingPathComponent(normalizedPath)
    }
}

// MARK: - Include Graph Models & Diagnostics

/// Classifies cross-file inclusion and bibliography resource directives across LaTeX, Typst, and Markdown.
public enum IncludeDirectiveKind: String, Sendable, Codable, Hashable, CaseIterable {
    case latexInput = "\\input"
    case latexInclude = "\\include"
    case latexSubfile = "\\subfile"
    case latexImport = "\\import"
    case latexBibliography = "\\bibliography"
    case latexAddBibResource = "\\addbibresource"
    case typstInclude = "#include"
    case typstImport = "#import"
    case typstBibliography = "#bibliography"
    case genericInclude = "include"

    public var isBibliographyResource: Bool {
        switch self {
        case .latexBibliography, .latexAddBibResource, .typstBibliography:
            return true
        default:
            return false
        }
    }

    public static func classify(command: String) -> IncludeDirectiveKind {
        switch command {
        case "\\input", "\\inputIfFileExists":
            return .latexInput
        case "\\include", "\\includeonly":
            return .latexInclude
        case "\\subfile":
            return .latexSubfile
        case "\\import", "\\subimport":
            return .latexImport
        case "\\bibliography", "\\nobibliography":
            return .latexBibliography
        case "\\addbibresource", "\\addglobalbib":
            return .latexAddBibResource
        case "#include":
            return .typstInclude
        case "#import":
            return .typstImport
        case "#bibliography":
            return .typstBibliography
        default:
            return .genericInclude
        }
    }
}

/// Directed edge in a multi-file manuscript project dependency graph.
public struct IncludeGraphEdge: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(sourceFile)->\(resolvedTargetFile)@\(directiveSpan.start.line):\(directiveSpan.start.column)" }
    public let sourceFile: String
    public let rawTargetPath: String
    public let resolvedTargetFile: String
    public let kind: IncludeDirectiveKind
    public let isBibliographyResource: Bool
    public let targetExists: Bool
    public let directiveSpan: TextSpan

    public init(
        sourceFile: String,
        rawTargetPath: String,
        resolvedTargetFile: String,
        kind: IncludeDirectiveKind,
        isBibliographyResource: Bool,
        targetExists: Bool,
        directiveSpan: TextSpan
    ) {
        self.sourceFile = sourceFile
        self.rawTargetPath = rawTargetPath
        self.resolvedTargetFile = resolvedTargetFile
        self.kind = kind
        self.isBibliographyResource = isBibliographyResource
        self.targetExists = targetExists
        self.directiveSpan = directiveSpan
    }
}

/// Strongly connected cycle discovered by Tarjan SCC + elementary cycle path reconstruction.
public struct IncludeCycleRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String { cyclePath.joined(separator: " -> ") }
    /// Closed loop sequence of normalized file paths (e.g. `["main.tex", "a.tex", "b.tex", "a.tex"]`).
    public let cyclePath: [String]
    /// Source span of the back-edge include directive closing the cycle.
    public let triggeringSpan: TextSpan?

    public init(cyclePath: [String], triggeringSpan: TextSpan? = nil) {
        self.cyclePath = cyclePath
        self.triggeringSpan = triggeringSpan
    }
}

/// Resolved multi-file project include graph with cycle records, missing files, bibliography paths, and topological compilation order.
public struct ManuscriptIncludeGraph: Sendable, Codable, Hashable {
    public let rootFilePath: String
    public let format: ManuscriptFormat
    /// Reachable manuscript files in pre-order document reading sequence starting from `rootFilePath`.
    public let documentReadingOrder: [String]
    /// Dependency-first topological compilation order (included leaf files precede the files that include them).
    public let topologicalCompilationOrder: [String]
    /// Normalized `.bib` / `.yml` bibliography database paths referenced via `\bibliography`, `\addbibresource`, or `#bibliography`.
    public let bibliographyFiles: [String]
    /// Referenced manuscript or bibliography files that could not be found in the workspace.
    public let missingFiles: [String]
    public let edges: [IncludeGraphEdge]
    public let stronglyConnectedCycles: [IncludeCycleRecord]

    public init(
        rootFilePath: String,
        format: ManuscriptFormat,
        documentReadingOrder: [String],
        topologicalCompilationOrder: [String],
        bibliographyFiles: [String],
        missingFiles: [String],
        edges: [IncludeGraphEdge],
        stronglyConnectedCycles: [IncludeCycleRecord]
    ) {
        self.rootFilePath = rootFilePath
        self.format = format
        self.documentReadingOrder = documentReadingOrder
        self.topologicalCompilationOrder = topologicalCompilationOrder
        self.bibliographyFiles = bibliographyFiles
        self.missingFiles = missingFiles
        self.edges = edges
        self.stronglyConnectedCycles = stronglyConnectedCycles
    }

    public var hasCycles: Bool {
        !stronglyConnectedCycles.isEmpty
    }

    /// Generates `LSPDiagnostic` items for missing `\input`/`\include`/`.bib` targets and cyclic includes.
    public func diagnostics() -> [LSPDiagnostic] {
        var output: [LSPDiagnostic] = []

        for cycle in stronglyConnectedCycles {
            let chain = cycle.cyclePath.joined(separator: " -> ")
            let span = cycle.triggeringSpan ?? TextSpan(
                filePath: rootFilePath,
                start: .startOfFile,
                end: .startOfFile
            )
            output.append(
                LSPDiagnostic(
                    code: "INC001",
                    severity: .error,
                    message: "Circular file include cycle detected: \(chain).",
                    span: span,
                    suggestedFix: "Remove recursive include directive to break the cycle."
                )
            )
        }

        for edge in edges where !edge.targetExists {
            let kindDesc = edge.isBibliographyResource ? "bibliography resource" : "included manuscript file"
            output.append(
                LSPDiagnostic(
                    code: "INC002",
                    severity: .error,
                    message: "Missing \(kindDesc) '\(edge.resolvedTargetFile)' (referenced via '\(edge.kind.rawValue)').",
                    span: edge.directiveSpan,
                    suggestedFix: "Create '\(edge.resolvedTargetFile)' or check relative path spelling."
                )
            )
        }

        return output
    }
}

/// Complete workspace resolution bundle combining the include graph, merged AST, per-file parse trees,
/// numbered `DocumentOutlineEntry` hierarchy, cross-file `ManuscriptSymbolTable`, and all diagnostics.
public struct MergedManuscriptWorkspaceAST: Sendable, Codable, Hashable {
    public let includeGraph: ManuscriptIncludeGraph
    public let mergedRootAST: MarkupASTNode
    public let perFileParseResults: [String: MarkupParseResult]
    public let outline: [DocumentOutlineEntry]
    public let symbolTable: ManuscriptSymbolTable
    public let diagnostics: [LSPDiagnostic]

    public init(
        includeGraph: ManuscriptIncludeGraph,
        mergedRootAST: MarkupASTNode,
        perFileParseResults: [String: MarkupParseResult],
        outline: [DocumentOutlineEntry],
        symbolTable: ManuscriptSymbolTable,
        diagnostics: [LSPDiagnostic]
    ) {
        self.includeGraph = includeGraph
        self.mergedRootAST = mergedRootAST
        self.perFileParseResults = perFileParseResults
        self.outline = outline
        self.symbolTable = symbolTable
        self.diagnostics = diagnostics
    }
}

// MARK: - Path & Extension Normalization Engine

enum IncludePathNormalizer {
    static func normalizePath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !trimmed.isEmpty else { return "" }

        let isAbsolute = trimmed.hasPrefix("/")
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        var stack: [Substring] = []
        stack.reserveCapacity(parts.count)

        for segment in parts {
            if segment == "." {
                continue
            } else if segment == ".." {
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
            } else {
                stack.append(segment)
            }
        }

        let joined = stack.joined(separator: "/")
        if isAbsolute {
            return "/" + joined
        }
        return joined.isEmpty ? "." : joined
    }

    static func parentDirectory(of normalizedFilePath: String) -> String {
        guard let slashIdx = normalizedFilePath.lastIndex(of: "/") else {
            return ""
        }
        if slashIdx == normalizedFilePath.startIndex {
            return "/"
        }
        return String(normalizedFilePath[..<slashIdx])
    }

    static func join(directory: String, relativePath: String) -> String {
        if relativePath.hasPrefix("/") || directory.isEmpty || directory == "." {
            return normalizePath(relativePath)
        }
        return normalizePath(directory + "/" + relativePath)
    }

    /// Normalizes extensions (`.tex`, `.typ`, `.bib`, `.md`) and checks candidate relative locations
    /// (root directory first for LaTeX `\input`/`\include`, current file's directory first for Typst `#include`/`\subimport`).
    static func resolveIncludeTarget(
        rawTarget: String,
        kind: IncludeDirectiveKind,
        includingFile: String,
        rootFile: String,
        format: ManuscriptFormat,
        provider: any ManuscriptSourceProvider
    ) -> (resolvedPath: String, exists: Bool) {
        let cleaned = rawTarget
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard !cleaned.isEmpty else {
            return ("", false)
        }

        let hasExplicitExt = !(cleaned as NSString).pathExtension.isEmpty
        var extensionCandidates: [String] = [cleaned]
        if !hasExplicitExt {
            if kind.isBibliographyResource {
                extensionCandidates = [cleaned + ".bib", cleaned + ".yml", cleaned]
            } else {
                switch format {
                case .latex:
                    extensionCandidates = [cleaned + ".tex", cleaned + ".sty", cleaned]
                case .typst:
                    extensionCandidates = [cleaned + ".typ", cleaned]
                case .markdown:
                    extensionCandidates = [cleaned + ".md", cleaned + ".qmd", cleaned]
                }
            }
        }

        let rootDir = parentDirectory(of: rootFile)
        let currentDir = parentDirectory(of: includingFile)

        // LaTeX resolves `\input` / `\include` / `\bibliography` relative to the root `.tex` working directory first,
        // then falls back to the including file's directory; Typst resolves relative to `includingFile` first.
        let baseDirectories: [String]
        if format == .typst || kind == .latexImport {
            baseDirectories = (currentDir == rootDir) ? [currentDir] : [currentDir, rootDir]
        } else {
            baseDirectories = (rootDir == currentDir) ? [rootDir] : [rootDir, currentDir]
        }

        var primaryFallback: String? = nil
        for baseDir in baseDirectories {
            for extCandidate in extensionCandidates {
                let candidatePath = join(directory: baseDir, relativePath: extCandidate)
                if primaryFallback == nil {
                    primaryFallback = candidatePath
                }
                if provider.fileExists(at: candidatePath) {
                    return (candidatePath, true)
                }
            }
        }

        return (primaryFallback ?? normalizePath(extensionCandidates[0]), false)
    }
}

// MARK: - Multi-File Include Graph Resolver & Numbered Outline Builder

/// Resolves multi-file LaTeX, Typst, and Markdown projects, detects circular includes via Tarjan's SCC algorithm,
/// computes topological compilation order, splices merged ASTs, and builds numbered `DocumentOutlineEntry` hierarchies.
public struct MultiFileIncludeGraphResolver: Sendable {
    public let lexer: IncrementalMarkupLexer
    public let parser: HandwrittenMarkupCSTParser
    public let macroEngine: MacroExpansionEngine

    public init(
        lexer: IncrementalMarkupLexer = IncrementalMarkupLexer(configuration: .losslessCST),
        parser: HandwrittenMarkupCSTParser? = nil,
        macroEngine: MacroExpansionEngine? = nil
    ) {
        self.lexer = lexer
        self.parser = parser ?? HandwrittenMarkupCSTParser(lexer: lexer)
        self.macroEngine = macroEngine ?? MacroExpansionEngine(lexer: lexer)
    }

    // MARK: Public Workspace Resolution APIs

    /// Resolves an entire multi-file project from an in-memory `[filePath: source]` dictionary.
    public func resolveWorkspace(
        rootFilePath: String,
        files: [String: String]
    ) -> MergedManuscriptWorkspaceAST {
        let provider = InMemoryManuscriptSourceProvider(files: files)
        return resolveWorkspace(rootFilePath: rootFilePath, provider: provider)
    }

    /// Resolves a multi-file project from disk with optional unsaved dirty editor buffer overlays.
    public func resolveFromDisk(
        rootFilePath: String,
        projectDirectory: String,
        unsavedBuffers: [String: String] = [:]
    ) -> MergedManuscriptWorkspaceAST {
        let provider = DiskAndOverlayManuscriptSourceProvider(
            projectRootDirectory: projectDirectory,
            unsavedBuffers: unsavedBuffers
        )
        return resolveWorkspace(rootFilePath: rootFilePath, provider: provider)
    }

    /// Core multi-file resolution pipeline: DFS discovery -> Tarjan SCC cycle analysis -> topological sort
    /// -> cycle-safe AST splicing -> cross-file symbol table -> numbered outline with section word counts.
    public func resolveWorkspace(
        rootFilePath: String,
        provider: any ManuscriptSourceProvider
    ) -> MergedManuscriptWorkspaceAST {
        let normalizedRoot = IncludePathNormalizer.normalizePath(rootFilePath)
        let rootFormat = ManuscriptFormat.detect(fromPath: normalizedRoot)

        var perFileParseResults: [String: MarkupParseResult] = [:]
        var perFileRawSources: [String: String] = [:]
        var allEdges: [IncludeGraphEdge] = []
        var adjacency: [String: [IncludeGraphEdge]] = [:]
        var readingOrder: [String] = []
        var bibliographyFiles: [String] = []
        var bibSeen = Set<String>()
        var missingFiles: [String] = []
        var missingSeen = Set<String>()
        var visitedManuscripts = Set<String>()

        // Step 1: Parse reachable manuscript files in DFS reading order, collecting include & bib edges.
        func discoverFile(_ filePath: String) {
            guard !visitedManuscripts.contains(filePath) else { return }
            visitedManuscripts.insert(filePath)

            guard let source = try? provider.readSource(at: filePath) else {
                if !missingSeen.contains(filePath) {
                    missingSeen.insert(filePath)
                    missingFiles.append(filePath)
                }
                return
            }

            readingOrder.append(filePath)
            perFileRawSources[filePath] = source
            let fileFormat = ManuscriptFormat.detect(fromPath: filePath)
            let parseResult = parser.parse(source: source, filePath: filePath, format: fileFormat)
            perFileParseResults[filePath] = parseResult

            let includeNodes = parseResult.root.allFileIncludes
            var fileOutgoing: [IncludeGraphEdge] = []

            for incNode in includeNodes {
                guard case .fileInclude(let cmd, let rawTarget) = incNode.kind else { continue }
                // `\includeonly{...}` restricts compilation rather than inserting text directly.
                if cmd == "\\includeonly" { continue }

                let directiveKind = IncludeDirectiveKind.classify(command: cmd)
                let resolved = IncludePathNormalizer.resolveIncludeTarget(
                    rawTarget: rawTarget,
                    kind: directiveKind,
                    includingFile: filePath,
                    rootFile: normalizedRoot,
                    format: fileFormat,
                    provider: provider
                )
                guard !resolved.resolvedPath.isEmpty else { continue }

                let edge = IncludeGraphEdge(
                    sourceFile: filePath,
                    rawTargetPath: rawTarget,
                    resolvedTargetFile: resolved.resolvedPath,
                    kind: directiveKind,
                    isBibliographyResource: directiveKind.isBibliographyResource,
                    targetExists: resolved.exists,
                    directiveSpan: incNode.span
                )
                allEdges.append(edge)
                fileOutgoing.append(edge)

                if !resolved.exists {
                    if !missingSeen.contains(resolved.resolvedPath) {
                        missingSeen.insert(resolved.resolvedPath)
                        missingFiles.append(resolved.resolvedPath)
                    }
                    continue
                }

                if directiveKind.isBibliographyResource {
                    if !bibSeen.contains(resolved.resolvedPath) {
                        bibSeen.insert(resolved.resolvedPath)
                        bibliographyFiles.append(resolved.resolvedPath)
                    }
                } else {
                    discoverFile(resolved.resolvedPath)
                }
            }

            adjacency[filePath] = fileOutgoing
        }

        discoverFile(normalizedRoot)

        // Step 2: Run Tarjan's Strongly Connected Components + exact elementary cycle extraction.
        let cycles = detectCyclesViaTarjan(
            nodes: readingOrder,
            adjacency: adjacency
        )

        // Step 3: Compute deterministic dependency-first topological compilation order (breaking back-edges if cyclic).
        let topologicalOrder = computeTopologicalCompilationOrder(
            nodes: readingOrder,
            adjacency: adjacency
        )

        let includeGraph = ManuscriptIncludeGraph(
            rootFilePath: normalizedRoot,
            format: rootFormat,
            documentReadingOrder: readingOrder,
            topologicalCompilationOrder: topologicalOrder,
            bibliographyFiles: bibliographyFiles,
            missingFiles: missingFiles,
            edges: allEdges,
            stronglyConnectedCycles: cycles
        )

        // Step 4: Splice included child ASTs into a unified multi-file `.document(format:)` AST
        // and normalize hierarchical section nesting across `\input` boundaries!
        let mergedAST: MarkupASTNode
        if let rootParse = perFileParseResults[normalizedRoot] {
            var activeIncludeStack: Set<String> = [normalizedRoot]
            let rawSplicedChildren = spliceChildren(
                of: rootParse.root,
                currentFile: normalizedRoot,
                edgesByFile: adjacency,
                perFileParseResults: perFileParseResults,
                activeStack: &activeIncludeStack
            )
            let normalizedChildren = rebuildCrossFileSectionHierarchy(from: rawSplicedChildren)
            mergedAST = MarkupASTNode(
                kind: .document(format: rootFormat),
                span: rootParse.root.span,
                children: normalizedChildren
            )
        } else {
            let emptyPos = TextPosition.startOfFile
            mergedAST = MarkupASTNode(
                kind: .document(format: rootFormat),
                span: TextSpan(filePath: normalizedRoot, start: emptyPos, end: emptyPos),
                children: []
            )
        }

        // Step 5: Build cross-file symbol table in document reading order.
        let orderedResults = readingOrder.compactMap { perFileParseResults[$0] }
        let symbolTable = macroEngine.buildSymbolTable(from: orderedResults)

        // Step 6: Build numbered `DocumentOutlineEntry` hierarchy (`1`, `1.1`, `Appendix A`, `A.1`) with section word counts!
        let appendixSectionIDs = collectAppendixSectionIDs(
            rootFile: normalizedRoot,
            edgesByFile: adjacency,
            perFileParseResults: perFileParseResults
        )
        let outline = buildOutlineInternal(
            from: mergedAST,
            perFileParseResults: perFileParseResults,
            appendixSectionIDs: appendixSectionIDs
        )

        // Step 7: Aggregate all parse, include-graph, and symbol diagnostics cleanly.
        var combinedDiagnostics: [LSPDiagnostic] = []
        for file in readingOrder {
            if let res = perFileParseResults[file] {
                combinedDiagnostics.append(contentsOf: res.lspDiagnostics)
            }
        }
        combinedDiagnostics.append(contentsOf: includeGraph.diagnostics())
        combinedDiagnostics.append(contentsOf: symbolTable.symbolDiagnostics())

        return MergedManuscriptWorkspaceAST(
            includeGraph: includeGraph,
            mergedRootAST: mergedAST,
            perFileParseResults: perFileParseResults,
            outline: outline,
            symbolTable: symbolTable,
            diagnostics: combinedDiagnostics
        )
    }

    /// Standalone outline builder from any single-file or merged `MarkupASTNode` root.
    public func buildOutline(
        from rootAST: MarkupASTNode,
        parseResult: MarkupParseResult? = nil
    ) -> [DocumentOutlineEntry] {
        var resultsMap: [String: MarkupParseResult] = [:]
        if let pr = parseResult {
            resultsMap[pr.filePath] = pr
        }
        let appIDs = collectAppendixSectionIDs(
            rootFile: rootAST.span.filePath,
            edgesByFile: [:],
            perFileParseResults: resultsMap
        )
        return buildOutlineInternal(
            from: rootAST,
            perFileParseResults: resultsMap,
            appendixSectionIDs: appIDs
        )
    }

    // MARK: - Tarjan's Strongly Connected Components & Cycle Path Reconstruction

    private func detectCyclesViaTarjan(
        nodes: [String],
        adjacency: [String: [IncludeGraphEdge]]
    ) -> [IncludeCycleRecord] {
        var currentIndex = 0
        var indices: [String: Int] = [:]
        var lowlink: [String: Int] = [:]
        var onStack: Set<String> = []
        var tarjanStack: [String] = []
        var sccs: [[String]] = []

        func strongConnect(_ v: String) {
            indices[v] = currentIndex
            lowlink[v] = currentIndex
            currentIndex += 1
            tarjanStack.append(v)
            onStack.insert(v)

            for edge in adjacency[v] ?? [] where !edge.isBibliographyResource && edge.targetExists {
                let w = edge.resolvedTargetFile
                if indices[w] == nil {
                    strongConnect(w)
                    lowlink[v] = min(lowlink[v]!, lowlink[w]!)
                } else if onStack.contains(w) {
                    lowlink[v] = min(lowlink[v]!, indices[w]!)
                }
            }

            if lowlink[v] == indices[v] {
                var component: [String] = []
                while let w = tarjanStack.popLast() {
                    onStack.remove(w)
                    component.append(w)
                    if w == v { break }
                }
                sccs.append(component)
            }
        }

        for node in nodes where indices[node] == nil {
            strongConnect(node)
        }

        // For every non-trivial SCC (`count > 1`, or `count == 1` with a self-loop edge `v -> v`),
        // extract explicit closed cycle paths along with the triggering include directive span.
        var cycles: [IncludeCycleRecord] = []
        var seenCycleKeys: Set<String> = []

        for comp in sccs {
            let compSet = Set(comp)
            if comp.count == 1 {
                let single = comp[0]
                if let selfEdge = (adjacency[single] ?? []).first(where: { !$0.isBibliographyResource && $0.resolvedTargetFile == single }) {
                    let path = [single, single]
                    let key = path.joined(separator: "->")
                    if !seenCycleKeys.contains(key) {
                        seenCycleKeys.insert(key)
                        cycles.append(IncludeCycleRecord(cyclePath: path, triggeringSpan: selfEdge.directiveSpan))
                    }
                }
                continue
            }

            // Reconstruct concrete cycle inside `compSet` starting from the earliest file in `nodes`.
            let orderedMembers = nodes.filter { compSet.contains($0) }
            guard let entry = orderedMembers.first else { continue }

            var dfsStack: [String] = []
            var dfsVisited: Set<String> = []

            func findCycleFrom(_ u: String) {
                dfsVisited.insert(u)
                dfsStack.append(u)
                for edge in adjacency[u] ?? [] where !edge.isBibliographyResource && compSet.contains(edge.resolvedTargetFile) {
                    let target = edge.resolvedTargetFile
                    if let idx = dfsStack.firstIndex(of: target) {
                        let loop = Array(dfsStack[idx...]) + [target]
                        let sig = canonicalCycleSignature(loop)
                        if !seenCycleKeys.contains(sig) {
                            seenCycleKeys.insert(sig)
                            cycles.append(IncludeCycleRecord(cyclePath: loop, triggeringSpan: edge.directiveSpan))
                        }
                    } else if !dfsVisited.contains(target) {
                        findCycleFrom(target)
                    }
                }
                _ = dfsStack.popLast()
            }

            findCycleFrom(entry)
        }

        return cycles
    }

    private func canonicalCycleSignature(_ closedLoop: [String]) -> String {
        let core = Array(closedLoop.dropLast())
        guard let minElem = core.min(), let minIdx = core.firstIndex(of: minElem) else {
            return closedLoop.joined(separator: "->")
        }
        let rotated = Array(core[minIdx...]) + Array(core[..<minIdx])
        return rotated.joined(separator: "->")
    }

    private func computeTopologicalCompilationOrder(
        nodes: [String],
        adjacency: [String: [IncludeGraphEdge]]
    ) -> [String] {
        enum State { case unvisited, visiting, visited }
        var state: [String: State] = [:]
        var postOrder: [String] = []
        postOrder.reserveCapacity(nodes.count)

        func visit(_ u: String) {
            state[u] = .visiting
            for edge in adjacency[u] ?? [] where !edge.isBibliographyResource && edge.targetExists {
                let v = edge.resolvedTargetFile
                if (state[v] ?? .unvisited) == .unvisited {
                    visit(v)
                }
            }
            state[u] = .visited
            postOrder.append(u)
        }

        for n in nodes where (state[n] ?? .unvisited) == .unvisited {
            visit(n)
        }
        // `postOrder` places leaf included `.tex`/`.typ` files BEFORE the parent files that include them!
        return postOrder
    }

    // MARK: - Cycle-Safe Multi-File AST Splicing & Cross-File Section Re-Nesting

    private func spliceChildren(
        of parentNode: MarkupASTNode,
        currentFile: String,
        edgesByFile: [String: [IncludeGraphEdge]],
        perFileParseResults: [String: MarkupParseResult],
        activeStack: inout Set<String>
    ) -> [MarkupASTNode] {
        var output: [MarkupASTNode] = []
        let fileEdges = edgesByFile[currentFile] ?? []

        for child in parentNode.children {
            if case .fileInclude(let cmd, _) = child.kind {
                let kind = IncludeDirectiveKind.classify(command: cmd)
                if kind.isBibliographyResource {
                    output.append(child)
                    continue
                }
                // Match the exact resolved edge by directive span & command
                if let matchedEdge = fileEdges.first(where: { $0.directiveSpan == child.span && !$0.isBibliographyResource }),
                   matchedEdge.targetExists,
                   !activeStack.contains(matchedEdge.resolvedTargetFile),
                   let includedResult = perFileParseResults[matchedEdge.resolvedTargetFile] {
                    // Preserve the `.fileInclude` marker node AND splice the included file's children immediately!
                    output.append(child)
                    activeStack.insert(matchedEdge.resolvedTargetFile)
                    let splicedSubtree = spliceChildren(
                        of: includedResult.root,
                        currentFile: matchedEdge.resolvedTargetFile,
                        edgesByFile: edgesByFile,
                        perFileParseResults: perFileParseResults,
                        activeStack: &activeStack
                    )
                    activeStack.remove(matchedEdge.resolvedTargetFile)
                    output.append(contentsOf: splicedSubtree)
                } else {
                    output.append(child)
                }
            } else if !child.children.isEmpty {
                let updatedGrandchildren = spliceChildren(
                    of: child,
                    currentFile: currentFile,
                    edgesByFile: edgesByFile,
                    perFileParseResults: perFileParseResults,
                    activeStack: &activeStack
                )
                output.append(
                    MarkupASTNode(
                        id: child.id,
                        kind: child.kind,
                        span: child.span,
                        children: updatedGrandchildren
                    )
                )
            } else {
                output.append(child)
            }
        }
        return output
    }

    /// Flattens section boundaries across `\input` files and re-nests `.section(level:...)` cleanly
    /// so e.g. `\section{Method}` in `main.tex` followed by `\input{sections/sub_loss.tex}` containing
    /// `\subsection{Loss}` nests `\subsection{Loss}` properly under `\section{Method}`!
    private func rebuildCrossFileSectionHierarchy(from splicedTopNodes: [MarkupASTNode]) -> [MarkupASTNode] {
        // First unpack section spines into a flat sequential stream of items while keeping non-section subtrees intact.
        var sequentialStream: [MarkupASTNode] = []
        func unpackSections(_ nodes: [MarkupASTNode]) {
            for node in nodes {
                if case .section(let level, let title, let label) = node.kind {
                    // Separate direct non-section header attachments (like the section's own `.labelDeclaration`)
                    // vs body content and subsections so nothing is lost.
                    var bodyAndSubsections: [MarkupASTNode] = []
                    for c in node.children {
                        bodyAndSubsections.append(c)
                    }
                    let shellSection = MarkupASTNode(
                        id: node.id,
                        kind: .section(level: level, title: title, label: label),
                        span: node.span,
                        children: []
                    )
                    sequentialStream.append(shellSection)
                    unpackSections(bodyAndSubsections)
                } else {
                    sequentialStream.append(node)
                }
            }
        }
        unpackSections(splicedTopNodes)

        struct SectionBuilder {
            let id: UUID
            let level: Int
            let title: String
            let label: String?
            let span: TextSpan
            var children: [MarkupASTNode]
        }

        var rootChildren: [MarkupASTNode] = []
        var stack: [SectionBuilder] = []

        func closeDownTo(level: Int) {
            while let top = stack.last, top.level >= level {
                let finished = stack.removeLast()
                // Update span end only if all children reside in the same file; otherwise keep header/local span intact.
                let finalSpan: TextSpan
                if let lastSameFile = finished.children.last(where: { $0.span.filePath == finished.span.filePath }),
                   finished.span.end < lastSameFile.span.end {
                    finalSpan = TextSpan(filePath: finished.span.filePath, start: finished.span.start, end: lastSameFile.span.end)
                } else {
                    finalSpan = finished.span
                }
                let built = MarkupASTNode(
                    id: finished.id,
                    kind: .section(level: finished.level, title: finished.title, label: finished.label),
                    span: finalSpan,
                    children: finished.children
                )
                if !stack.isEmpty {
                    stack[stack.count - 1].children.append(built)
                } else {
                    rootChildren.append(built)
                }
            }
        }

        for item in sequentialStream {
            if case .section(let level, let title, let label) = item.kind {
                closeDownTo(level: level)
                stack.append(
                    SectionBuilder(
                        id: item.id,
                        level: level,
                        title: title,
                        label: label,
                        span: item.span,
                        children: []
                    )
                )
            } else {
                if !stack.isEmpty {
                    stack[stack.count - 1].children.append(item)
                } else {
                    rootChildren.append(item)
                }
            }
        }

        closeDownTo(level: Int.min)
        return rootChildren
    }

    // MARK: - Numbered Document Outline & Per-Section Word Count Engine

    /// Walks the multi-file AST in exact `\input`/`\include` splice order so `\appendix` in `main.tex`
    /// only marks sections spliced *after* `\appendix` (and never sections spliced via earlier `\input` lines!).
    private func collectAppendixSectionIDs(
        rootFile: String,
        edgesByFile: [String: [IncludeGraphEdge]],
        perFileParseResults: [String: MarkupParseResult]
    ) -> Set<UUID> {
        var appendixIDs: Set<UUID> = []
        var activeStack: Set<String> = []
        var inAppendix = false

        func localAppendixSwitchOffset(in parseResult: MarkupParseResult) -> Int? {
            for tok in parseResult.tokens {
                if tok.kind == .command && (tok.lexeme == "\\appendix" || tok.lexeme == "\\appendices") {
                    return tok.span.start.utf8Offset
                }
                if tok.kind == .command && tok.lexeme == "\\begin" {
                    if let envNode = parseResult.root.allEnvironments.first(where: { $0.span.start == tok.span.start }),
                       case .environment(let name, _, _) = envNode.kind,
                       name == "appendices" || name == "appendix" {
                        return tok.span.start.utf8Offset
                    }
                }
            }
            return nil
        }

        func walkFile(_ filePath: String) {
            guard !activeStack.contains(filePath),
                  let pr = perFileParseResults[filePath] else { return }
            activeStack.insert(filePath)
            defer { activeStack.remove(filePath) }

            let localSwitchOffset = localAppendixSwitchOffset(in: pr)
            let fileEdges = edgesByFile[filePath] ?? []

            func walkNode(_ node: MarkupASTNode) {
                if let switchOffset = localSwitchOffset, node.span.start.utf8Offset >= switchOffset {
                    inAppendix = true
                }
                switch node.kind {
                case .section(_, let title, let label):
                    let lower = title.lowercased()
                    let lblLower = label?.lowercased() ?? ""
                    if lower == "appendix" || lower.hasPrefix("appendix ") || lower.hasPrefix("appendix:")
                        || lblLower.hasPrefix("app:") || lblLower.hasPrefix("appendix:") {
                        inAppendix = true
                    }
                    if inAppendix {
                        appendixIDs.insert(node.id)
                    }
                case .fileInclude(let cmd, _):
                    let directiveKind = IncludeDirectiveKind.classify(command: cmd)
                    if !directiveKind.isBibliographyResource,
                       let matchedEdge = fileEdges.first(where: { $0.directiveSpan == node.span && !$0.isBibliographyResource }),
                       matchedEdge.targetExists {
                        walkFile(matchedEdge.resolvedTargetFile)
                    }
                default:
                    break
                }
                for child in node.children {
                    walkNode(child)
                }
            }

            for topChild in pr.root.children {
                walkNode(topChild)
            }
            if localSwitchOffset != nil {
                inAppendix = true
            }
        }

        walkFile(rootFile)
        return appendixIDs
    }

    private func buildOutlineInternal(
        from rootAST: MarkupASTNode,
        perFileParseResults: [String: MarkupParseResult],
        appendixSectionIDs: Set<UUID>
    ) -> [DocumentOutlineEntry] {
        // Counters for hierarchical numbering `[c1, c2, c3, c4, c5]`
        var counters = Array(repeating: 0, count: 8)
        var inAppendixMode = false
        var entries: [DocumentOutlineEntry] = []

        func isSectionStarred(_ secNode: MarkupASTNode) -> Bool {
            guard let pr = perFileParseResults[secNode.span.filePath] else { return false }
            if let tok = pr.tokens.first(where: { $0.span.start == secNode.span.start }) {
                return tok.lexeme.hasSuffix("*")
            }
            return false
        }

        func hasReachedAppendix(_ secNode: MarkupASTNode, title: String) -> Bool {
            if inAppendixMode || appendixSectionIDs.contains(secNode.id) {
                return true
            }
            let lower = title.lowercased()
            if lower == "appendix" || lower.hasPrefix("appendix ") || lower.hasPrefix("appendix:") {
                return true
            }
            if let lbl = extractSectionLabel(secNode)?.lowercased(),
               lbl.hasPrefix("app:") || lbl.hasPrefix("appendix:") {
                return true
            }
            return false
        }

        func visitSectionTree(_ node: MarkupASTNode) {
            if case .section(let rawLevel, let title, let label) = node.kind {
                let normalizedLevel = max(1, min(6, rawLevel == 0 ? 1 : rawLevel))
                let starred = isSectionStarred(node)

                if normalizedLevel == 1 && hasReachedAppendix(node, title: title) && !inAppendixMode {
                    inAppendixMode = true
                    counters = Array(repeating: 0, count: 8)
                }

                let numberPrefix: String
                if starred {
                    numberPrefix = ""
                } else {
                    counters[normalizedLevel] += 1
                    for deeper in (normalizedLevel + 1)..<counters.count {
                        counters[deeper] = 0
                    }
                    // Ensure parent counter is at least 1 when a manuscript jumps straight to `\subsection`
                    for ancestor in 1..<normalizedLevel where counters[ancestor] == 0 {
                        counters[ancestor] = 1
                    }

                    if inAppendixMode {
                        let letterOrdinal = max(1, counters[1])
                        let appendixLetter = Self.appendixLetter(for: letterOrdinal)
                        if normalizedLevel == 1 {
                            numberPrefix = "Appendix \(appendixLetter)"
                        } else {
                            let subParts = (2...normalizedLevel).map { String(counters[$0]) }.joined(separator: ".")
                            numberPrefix = "\(appendixLetter).\(subParts)"
                        }
                    } else {
                        numberPrefix = (1...normalizedLevel).map { String(counters[$0]) }.joined(separator: ".")
                    }
                }

                let sectionWords = countProseWordsInSection(node)
                entries.append(
                    DocumentOutlineEntry(
                        level: normalizedLevel,
                        numberPrefix: numberPrefix,
                        title: title,
                        label: label,
                        filePath: node.span.filePath,
                        line: node.span.start.line,
                        wordCountInSection: sectionWords
                    )
                )
            }

            for child in node.children {
                visitSectionTree(child)
            }
        }

        visitSectionTree(rootAST)
        return entries
    }

    private func extractSectionLabel(_ node: MarkupASTNode) -> String? {
        if case .section(_, _, let lbl) = node.kind {
            return lbl
        }
        return nil
    }

    private static func appendixLetter(for oneBasedIndex: Int) -> String {
        var n = max(1, oneBasedIndex)
        var result = ""
        while n > 0 {
            let rem = (n - 1) % 26
            if let scalar = UnicodeScalar(65 + rem) {
                result.insert(Character(scalar), at: result.startIndex)
            }
            n = (n - 1) / 26
        }
        return result
    }

    /// Counts clean prose words inside `sectionNode` (including nested paragraphs & list items,
    /// while excluding child `.section` subtrees so parent and subsection counts don't double-count,
    /// or wait: let's check whether `wordCountInSection` should count the section's entire subtree or direct + non-section children!).
    /// Actually, let's check! In an outline view:
    /// Suppose Section 1 has an intro paragraph (50 words) + Subsection 1.1 (200 words) + Subsection 1.2 (150 words).
    /// Total words in Section 1 is 400 words, Subsection 1.1 is 200 words, Subsection 1.2 is 150 words!
    /// Counting all prose paragraphs within the section subtree (excluding figures/tables/code/math) gives non-zero, intuitive section totals even when a `\section` immediately begins with `\subsection`!
    private func countProseWordsInSection(_ sectionNode: MarkupASTNode) -> Int {
        var total = 0
        func walk(_ n: MarkupASTNode) {
            switch n.kind {
            case .paragraph(let plainPreview):
                total += Self.countWords(in: plainPreview)
            case .environment(let name, _, _):
                let excluded: Set<String> = [
                    "tikzpicture", "lstlisting", "minted", "verbatim",
                    "tabular", "tabularx", "equation", "equation*", "align", "align*"
                ]
                if !excluded.contains(name) {
                    for c in n.children {
                        walk(c)
                    }
                }
            case .section:
                for c in n.children {
                    walk(c)
                }
            default:
                break
            }
        }
        for child in sectionNode.children {
            walk(child)
        }
        return total
    }

    static func countWords(in text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord {
                    count += 1
                    inWord = true
                }
            } else if scalar == "-" || scalar == "'" || scalar == "’" {
                // Internal hyphen or apostrophe keeps current word open
                continue
            } else {
                inWord = false
            }
        }
        return count
    }
}
