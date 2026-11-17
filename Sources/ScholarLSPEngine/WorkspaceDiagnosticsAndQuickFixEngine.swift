import Foundation
import ScholarModels
import ScholarMarkupAST
import ScholarBibAndCSL

// MARK: - Text Edits, Workspace Edits & Code Action Models

public struct LSPTextEdit: Sendable, Codable, Hashable, Identifiable {
    public var id: String {
        "\(filePath):\(replaceByteRange.lowerBound)..<\(replaceByteRange.upperBound)->\(replacementText.hashValue)"
    }
    public let filePath: String
    public let replaceByteRange: Range<Int>
    public let span: TextSpan
    public let replacementText: String

    public init(
        filePath: String,
        replaceByteRange: Range<Int>,
        span: TextSpan,
        replacementText: String
    ) {
        self.filePath = filePath
        self.replaceByteRange = replaceByteRange
        self.span = span
        self.replacementText = replacementText
    }
}

public struct LSPWorkspaceEdit: Sendable, Codable, Hashable {
    public let title: String
    public let editsByFile: [String: [LSPTextEdit]]

    public var affectedEditCount: Int {
        editsByFile.values.reduce(0) { $0 + $1.count }
    }

    public init(title: String, editsByFile: [String: [LSPTextEdit]]) {
        self.title = title
        self.editsByFile = editsByFile
    }

    /// Applies all non-overlapping UTF-8 byte range edits to `files` in descending offset order.
    public func apply(toFiles files: [String: String]) -> [String: String] {
        var updatedFiles = files

        for (filePath, edits) in editsByFile where !edits.isEmpty {
            guard let original = updatedFiles[filePath] else { continue }
            var bytes = Array(original.utf8)

            // Sort descending by lowerBound; deduplicate identical edits and skip overlapping ranges safely.
            let sortedDescending = edits.sorted { lhs, rhs in
                if lhs.replaceByteRange.lowerBound != rhs.replaceByteRange.lowerBound {
                    return lhs.replaceByteRange.lowerBound > rhs.replaceByteRange.lowerBound
                }
                return lhs.replaceByteRange.upperBound > rhs.replaceByteRange.upperBound
            }

            var lowestTouchedOffset = bytes.count + 1
            for edit in sortedDescending {
                let lower = max(0, min(bytes.count, edit.replaceByteRange.lowerBound))
                let upper = max(lower, min(bytes.count, edit.replaceByteRange.upperBound))
                guard upper <= lowestTouchedOffset else {
                    continue
                }
                let replacementUTF8 = Array(edit.replacementText.utf8)
                bytes.replaceSubrange(lower..<upper, with: replacementUTF8)
                lowestTouchedOffset = lower
            }

            updatedFiles[filePath] = String(decoding: bytes, as: UTF8.self)
        }

        return updatedFiles
    }
}

public enum LSPCodeActionKind: String, Sendable, Codable, Hashable, CaseIterable {
    case quickFix = "quickfix"
    case refactorRename = "refactor.rename"
    case refactorRewrite = "refactor.rewrite"
    case sourceFixAll = "source.fixAll"
    case citationFirewallRemediation = "scholar.firewall"
}

public struct LSPCodeAction: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let diagnosticCode: String
    public let kind: LSPCodeActionKind
    public let workspaceEdit: LSPWorkspaceEdit

    public init(
        id: String = UUID().uuidString,
        title: String,
        diagnosticCode: String,
        kind: LSPCodeActionKind = .quickFix,
        workspaceEdit: LSPWorkspaceEdit
    ) {
        self.id = id
        self.title = title
        self.diagnosticCode = diagnosticCode
        self.kind = kind
        self.workspaceEdit = workspaceEdit
    }
}

public struct WorkspaceDiagnosticsReport: Sendable, Codable, Hashable {
    public let diagnostics: [LSPDiagnostic]
    public let codeActions: [LSPCodeAction]
    public let errorCount: Int
    public let warningCount: Int
    public let firewallViolationCount: Int

    public init(
        diagnostics: [LSPDiagnostic],
        codeActions: [LSPCodeAction]
    ) {
        self.diagnostics = diagnostics
        self.codeActions = codeActions
        self.errorCount = diagnostics.filter { $0.severity == .error }.count
        self.warningCount = diagnostics.filter { $0.severity == .warning }.count
        self.firewallViolationCount = diagnostics.filter {
            $0.code == "ERR_UNVERIFIED_CITATION" || $0.code == "CITE404" || $0.code == "FW_METADATA_DRIFT"
        }.count
    }
}

// MARK: - Unified Academic Diagnostics & Quick-Fix Engine

public struct WorkspaceDiagnosticsAndQuickFixEngine: Sendable {
    public let firewall: CitationVerificationFirewall
    public var enableMissingTieLint: Bool
    public var enableUncitedBibLint: Bool

    public init(
        firewall: CitationVerificationFirewall = CitationVerificationFirewall(),
        enableMissingTieLint: Bool = true,
        enableUncitedBibLint: Bool = true
    ) {
        self.firewall = firewall
        self.enableMissingTieLint = enableMissingTieLint
        self.enableUncitedBibLint = enableUncitedBibLint
    }

    public func analyze(
        workspace: MergedManuscriptWorkspaceAST,
        bibliography: [BibliographyEntry] = [],
        sourcesByFile: [String: String] = [:],
        bibliographyFiles: [String: String] = [:],
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict] = [:],
        extraDiagnostics: [LSPDiagnostic] = []
    ) -> WorkspaceDiagnosticsReport {
        var diagnostics: [LSPDiagnostic] = []
        var actions: [LSPCodeAction] = []

        // Resolve canonical source map from lossless CST tokens + optional overrides
        var resolvedSources = sourcesByFile
        for (path, pr) in workspace.perFileParseResults where resolvedSources[path] == nil {
            resolvedSources[path] = pr.tokens.map(\.lexeme).joined()
        }

        // 1. Upstream Syntax/CST Recovery + Include Graph + Symbol Table + Loader Diagnostics
        diagnostics.append(contentsOf: workspace.diagnostics)
        diagnostics.append(contentsOf: extraDiagnostics)
        actions.append(contentsOf: buildSymbolDiagnosticQuickFixes(workspace: workspace, sourcesByFile: resolvedSources))

        // 2. Citation Verification Firewall Diagnostics (`CITE404`, `ERR_UNVERIFIED_CITATION`, advisories)
        let (fwDiags, fwActions) = analyzeCitationFirewallGates(
            workspace: workspace,
            bibliography: bibliography,
            sourcesByFile: resolvedSources,
            inRunVerdictsByKey: inRunVerdictsByKey
        )
        diagnostics.append(contentsOf: fwDiags)
        actions.append(contentsOf: fwActions)

        // 3. Structural Academic Lint Rules (Floats, Label-Before-Caption, Unreferenced Floats/Equations, Uncited Bib, Non-Breaking Ties)
        let (lintDiags, lintActions) = analyzeStructuralAcademicLintRules(
            workspace: workspace,
            bibliography: bibliography,
            sourcesByFile: resolvedSources,
            bibliographyFiles: bibliographyFiles
        )
        diagnostics.append(contentsOf: lintDiags)
        actions.append(contentsOf: lintActions)

        // Deduplicate & deterministically order diagnostics (errors first, then file/line/column)
        let dedupedDiagnostics = deduplicateAndSortDiagnostics(diagnostics)
        return WorkspaceDiagnosticsReport(diagnostics: dedupedDiagnostics, codeActions: actions)
    }

    public func diagnostics(
        in workspace: MergedManuscriptWorkspaceAST,
        bibliography: [BibliographyEntry] = [],
        filePathFilter: String? = nil,
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict] = [:]
    ) -> [LSPDiagnostic] {
        let all = analyze(
            workspace: workspace,
            bibliography: bibliography,
            inRunVerdictsByKey: inRunVerdictsByKey
        ).diagnostics
        guard let filter = filePathFilter else { return all }
        return all.filter { $0.span.filePath == filter }
    }

    public func codeActions(
        in workspace: MergedManuscriptWorkspaceAST,
        bibliography: [BibliographyEntry] = [],
        filePath: String? = nil,
        overlapping range: TextSpan? = nil,
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict] = [:]
    ) -> [LSPCodeAction] {
        let all = analyze(
            workspace: workspace,
            bibliography: bibliography,
            inRunVerdictsByKey: inRunVerdictsByKey
        ).codeActions
        return all.filter { action in
            if let f = filePath, action.workspaceEdit.editsByFile[f] == nil {
                return false
            }
            if let r = range {
                guard let fileEdits = action.workspaceEdit.editsByFile[r.filePath] else { return false }
                return fileEdits.contains { spansOverlapOrTouch($0.span, r) }
            }
            return true
        }
    }

    // MARK: - Layer 1/2 Quick-Fixes for Symbol Diagnostics

    private func buildSymbolDiagnosticQuickFixes(
        workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String]
    ) -> [LSPCodeAction] {
        var actions: [LSPCodeAction] = []
        let allLabelKeys = workspace.symbolTable.labelsByKey.keys.sorted()

        // Unresolved cross-references (`SYM004`): fuzzy-suggest closest existing label!
        for unresolved in workspace.symbolTable.unresolvedCrossReferences {
            guard let bestMatch = closestCandidate(to: unresolved.targetKey, in: allLabelKeys, maxDistance: 3),
                  let pr = workspace.perFileParseResults[unresolved.span.filePath],
                  let source = sourcesByFile[unresolved.span.filePath] else {
                continue
            }
            let lineIdx = LineByteIndex(source: source)
            if let keyEdit = locateKeyEditInDirective(
                tokens: pr.tokens,
                directiveSpan: unresolved.span,
                oldKey: unresolved.targetKey,
                newKey: bestMatch,
                source: source,
                lineIndex: lineIdx
            ) {
                let wsEdit = LSPWorkspaceEdit(
                    title: "Change cross-reference '\(unresolved.targetKey)' to '\(bestMatch)'",
                    editsByFile: [unresolved.span.filePath: [keyEdit]]
                )
                actions.append(
                    LSPCodeAction(
                        id: "fix:SYM004:\(unresolved.span.filePath):\(unresolved.span.start.line):\(unresolved.targetKey)",
                        title: "Replace '\(unresolved.targetKey)' with '\(bestMatch)'",
                        diagnosticCode: "SYM004",
                        kind: .quickFix,
                        workspaceEdit: wsEdit
                    )
                )
            }
        }

        // `\eqref` on non-equation (`SYM005`): replace `\eqref` with `\cref`
        for ref in workspace.symbolTable.crossReferences where ref.command == "\\eqref" {
            guard let resolved = workspace.symbolTable.labelsByKey[ref.targetKey],
                  resolved.category != .equation && resolved.category != .general,
                  let pr = workspace.perFileParseResults[ref.span.filePath] else {
                continue
            }
            if let cmdTok = pr.tokens.first(where: { $0.kind == .command && $0.lexeme == "\\eqref" && $0.span.start.utf8Offset == ref.span.start.utf8Offset }) {
                let edit = LSPTextEdit(
                    filePath: ref.span.filePath,
                    replaceByteRange: cmdTok.span.start.utf8Offset..<cmdTok.span.end.utf8Offset,
                    span: cmdTok.span,
                    replacementText: "\\cref"
                )
                actions.append(
                    LSPCodeAction(
                        id: "fix:SYM005:\(ref.span.filePath):\(ref.span.start.line):\(ref.targetKey)",
                        title: "Replace '\\eqref' with '\\cref' for \(resolved.category.rawValue) label",
                        diagnosticCode: "SYM005",
                        kind: .quickFix,
                        workspaceEdit: LSPWorkspaceEdit(
                            title: "Use \\cref{\(ref.targetKey)}",
                            editsByFile: [ref.span.filePath: [edit]]
                        )
                    )
                )
            }
        }

        // Duplicate `\newcommand` (`SYM002`): replace `\newcommand` with `\renewcommand`
        var seenMacros = Set<String>()
        for decl in workspace.symbolTable.allMacroDeclarations {
            if !seenMacros.insert(decl.name).inserted && decl.originKind == .latexNewCommand,
               let pr = workspace.perFileParseResults[decl.filePath],
               let cmdTok = pr.tokens.first(where: { $0.kind == .command && $0.lexeme.hasPrefix("\\newcommand") && $0.span.start.utf8Offset == decl.span.start.utf8Offset }) {
                let edit = LSPTextEdit(
                    filePath: decl.filePath,
                    replaceByteRange: cmdTok.span.start.utf8Offset..<cmdTok.span.end.utf8Offset,
                    span: cmdTok.span,
                    replacementText: "\\renewcommand"
                )
                actions.append(
                    LSPCodeAction(
                        id: "fix:SYM002:\(decl.filePath):\(decl.span.start.line):\(decl.name)",
                        title: "Change '\\newcommand' to '\\renewcommand' for '\(decl.name)'",
                        diagnosticCode: "SYM002",
                        kind: .quickFix,
                        workspaceEdit: LSPWorkspaceEdit(
                            title: "Use \\renewcommand for \(decl.name)",
                            editsByFile: [decl.filePath: [edit]]
                        )
                    )
                )
            }
        }

        return actions
    }

    // MARK: - Layer 4: Citation Verification Firewall Gate Analysis

    private func analyzeCitationFirewallGates(
        workspace: MergedManuscriptWorkspaceAST,
        bibliography: [BibliographyEntry],
        sourcesByFile: [String: String],
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict]
    ) -> ([LSPDiagnostic], [LSPCodeAction]) {
        var diagnostics: [LSPDiagnostic] = []
        var actions: [LSPCodeAction] = []

        let bibByKey = Dictionary(bibliography.map { ($0.citeKey, $0) }, uniquingKeysWith: { first, _ in first })
        let bibByLowerKey = Dictionary(
            bibliography.map { ($0.citeKey.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let verifiedCiteKeys = bibliography
            .filter { resolveEffectiveFirewall(for: $0, inRunVerdictsByKey: inRunVerdictsByKey).0.allowsManuscriptInsertion }
            .map(\.citeKey)
        let allCiteKeys = bibByKey.keys.sorted()
        var reportedCaseMismatchKeys = Set<String>()

        for occ in workspace.symbolTable.allCitationOccurrences {
            let entry: BibliographyEntry
            if let exactEntry = bibByKey[occ.citeKey] {
                entry = exactEntry
            } else if let ciEntry = bibByLowerKey[occ.citeKey.lowercased()] {
                entry = ciEntry
                if reportedCaseMismatchKeys.insert(occ.citeKey).inserted {
                    diagnostics.append(
                        LSPDiagnostic(
                            code: "CITE_KEY_CASE",
                            category: .structure,
                            severity: .warning,
                            message: "Citation key '\(occ.citeKey)' matched bibliography entry '\(ciEntry.citeKey)' only case-insensitively (cited as '\(occ.citeKey)', defined in bibliography as '\(ciEntry.citeKey)').",
                            span: occ.span,
                            suggestedFix: "Change '\(occ.citeKey)' to '\(ciEntry.citeKey)'."
                        )
                    )
                    if let pr = workspace.perFileParseResults[occ.span.filePath],
                       let source = sourcesByFile[occ.span.filePath] {
                        let lineIdx = LineByteIndex(source: source)
                        if let replaceEdit = locateKeyEditInDirective(
                            tokens: pr.tokens,
                            directiveSpan: occ.span,
                            oldKey: occ.citeKey,
                            newKey: ciEntry.citeKey,
                            source: source,
                            lineIndex: lineIdx
                        ) {
                            actions.append(
                                LSPCodeAction(
                                    id: "fix:CITE_KEY_CASE:\(occ.span.filePath):\(occ.span.start.line):\(occ.citeKey)",
                                    title: "Match bibliography key case '\(occ.citeKey)' -> '\(ciEntry.citeKey)'",
                                    diagnosticCode: "CITE_KEY_CASE",
                                    kind: .quickFix,
                                    workspaceEdit: LSPWorkspaceEdit(
                                        title: "Match citation key case '\(occ.citeKey)' -> '\(ciEntry.citeKey)'",
                                        editsByFile: [occ.span.filePath: [replaceEdit]]
                                    )
                                )
                            )
                        }
                    }
                }
            } else {
                // Missing from bibliography (`CITE404`)
                let closest = closestCandidate(to: occ.citeKey, in: verifiedCiteKeys.isEmpty ? allCiteKeys : verifiedCiteKeys, maxDistance: 4)
                diagnostics.append(
                    LSPDiagnostic(
                        code: "CITE404",
                        severity: .error,
                        message: "Cited key '\(occ.citeKey)' does not exist in workspace bibliography.",
                        span: occ.span,
                        suggestedFix: closest.map { "Replace with '\($0)' or import BibTeX entry." } ?? "Add '\(occ.citeKey)' to your .bib file."
                    )
                )

                if let suggestion = closest,
                   let pr = workspace.perFileParseResults[occ.span.filePath],
                   let source = sourcesByFile[occ.span.filePath] {
                    let lineIdx = LineByteIndex(source: source)
                    if let replaceEdit = locateKeyEditInDirective(
                        tokens: pr.tokens,
                        directiveSpan: occ.span,
                        oldKey: occ.citeKey,
                        newKey: suggestion,
                        source: source,
                        lineIndex: lineIdx
                    ) {
                        actions.append(
                            LSPCodeAction(
                                id: "fix:CITE404:\(occ.span.filePath):\(occ.span.start.line):\(occ.citeKey)",
                                title: "Replace missing citation '\(occ.citeKey)' with '\(suggestion)'",
                                diagnosticCode: "CITE404",
                                kind: .quickFix,
                                workspaceEdit: LSPWorkspaceEdit(
                                    title: "Fix citation typo '\(occ.citeKey)' -> '\(suggestion)'",
                                    editsByFile: [occ.span.filePath: [replaceEdit]]
                                )
                            )
                        )
                    }
                }
                continue
            }

            let (effectiveClass, verdictNote) = resolveEffectiveFirewall(
                for: entry,
                inRunVerdictsByKey: inRunVerdictsByKey
            )

            switch effectiveClass {
            case .verified:
                break

            case .drift:
                diagnostics.append(
                    LSPDiagnostic(
                        code: "ERR_UNVERIFIED_CITATION",
                        severity: .error,
                        message: "[ERR_UNVERIFIED_CITATION] Citation '\(occ.citeKey)' is DRIFT (\(verdictNote)).",
                        span: occ.span,
                        suggestedFix: "Reconcile title/year/author fields against registry metadata or remove citation '\(occ.citeKey)'."
                    )
                )

            case .unverified:
                diagnostics.append(
                    LSPDiagnostic(
                        code: "ERR_UNVERIFIED_CITATION",
                        severity: .error,
                        message: "[ERR_UNVERIFIED_CITATION] Citation '\(occ.citeKey)' is UNVERIFIED (\(verdictNote)). Citation Firewall blocks manuscript export until verified.",
                        span: occ.span,
                        suggestedFix: "Verify citation against external registries or remove unverified citation."
                    )
                )
                if let removeAction = buildRemoveCitedKeyCodeAction(
                    occurrence: occ,
                    reasonLabel: "unverified citation",
                    workspace: workspace,
                    sourcesByFile: sourcesByFile
                ) {
                    actions.append(removeAction)
                }

            case .notFound, .retracted:
                let statusLabel = effectiveClass.rawValue
                diagnostics.append(
                    LSPDiagnostic(
                        code: "ERR_UNVERIFIED_CITATION",
                        severity: .error,
                        message: "[ERR_UNVERIFIED_CITATION] Citation '\(occ.citeKey)' is \(statusLabel) (\(verdictNote)).",
                        span: occ.span,
                        suggestedFix: "Remove \(statusLabel.lowercased()) citation '\(occ.citeKey)' immediately."
                    )
                )
                if let removeAction = buildRemoveCitedKeyCodeAction(
                    occurrence: occ,
                    reasonLabel: "\(statusLabel.lowercased()) citation",
                    workspace: workspace,
                    sourcesByFile: sourcesByFile
                ) {
                    actions.append(removeAction)
                }
            }
        }

        return (diagnostics, actions)
    }

    private func resolveEffectiveFirewall(
        for entry: BibliographyEntry,
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict]
    ) -> (CitationFirewallClass, String) {
        firewall.resolveEffectiveStatus(for: entry, inRunVerdictsByKey: inRunVerdictsByKey)
    }

    // MARK: - Layer 5: Structural Academic Lint Rules & Quick-Fixes

    private static let floatEnvNames: Set<String> = [
        "figure", "figure*", "wrapfigure", "sidewaysfigure",
        "table", "table*", "sidewaystable", "longtable",
        "algorithm", "algorithm*"
    ]

    private static let numberedEquationEnvs: Set<String> = [
        "equation", "align", "gather", "multline"
    ]

    private func analyzeStructuralAcademicLintRules(
        workspace: MergedManuscriptWorkspaceAST,
        bibliography: [BibliographyEntry],
        sourcesByFile: [String: String],
        bibliographyFiles: [String: String]
    ) -> ([LSPDiagnostic], [LSPCodeAction]) {
        var diagnostics: [LSPDiagnostic] = []
        var actions: [LSPCodeAction] = []

        let referencedLabelKeys = Set(workspace.symbolTable.crossReferences.map(\.targetKey))
        let citedBibKeys = Set(workspace.symbolTable.citationsByKey.keys)

        // 5A. Inspect each file's floats for missing `\label` or `\label` placed BEFORE `\caption`!
        for filePath in workspace.includeGraph.documentReadingOrder {
            guard let pr = workspace.perFileParseResults[filePath],
                  let source = sourcesByFile[filePath] else { continue }
            let lineIdx = LineByteIndex(source: source)

            if pr.format == .latex {
                let floatFindings = inspectLatexFloatsInTokens(
                    tokens: pr.tokens,
                    filePath: filePath,
                    source: source,
                    lineIndex: lineIdx
                )
                diagnostics.append(contentsOf: floatFindings.diagnostics)
                actions.append(contentsOf: floatFindings.actions)

                if enableMissingTieLint {
                    let tieFindings = inspectMissingNonBreakingTies(
                        tokens: pr.tokens,
                        filePath: filePath,
                        source: source,
                        lineIndex: lineIdx
                    )
                    diagnostics.append(contentsOf: tieFindings.diagnostics)
                    actions.append(contentsOf: tieFindings.actions)
                }
            }
        }

        // 5B. Unreferenced floats & unreferenced numbered equations
        for env in workspace.symbolTable.environments {
            if Self.floatEnvNames.contains(env.name), let lbl = env.label, !referencedLabelKeys.contains(lbl) {
                diagnostics.append(
                    LSPDiagnostic(
                        code: "LINT_UNREFERENCED_FLOAT",
                        severity: .warning,
                        message: "Float '\(env.name)' with label '\(lbl)' is never referenced in the manuscript text.",
                        span: env.span,
                        suggestedFix: "Reference it in prose via '\\cref{\(lbl)}' or '\\ref{\(lbl)}'."
                    )
                )
            }
        }

        for lblRecord in workspace.symbolTable.allLabelDeclarations where lblRecord.category == .equation {
            if let envName = lblRecord.enclosingEnvironment,
               Self.numberedEquationEnvs.contains(envName),
               !referencedLabelKeys.contains(lblRecord.key) {
                diagnostics.append(
                    LSPDiagnostic(
                        code: "LINT_UNREFERENCED_EQUATION",
                        severity: .info,
                        message: "Numbered equation label '\(lblRecord.key)' is never referenced via \\eqref or \\cref.",
                        span: lblRecord.span,
                        suggestedFix: "Reference equation '\(lblRecord.key)' or switch to unnumbered '\(envName)*'."
                    )
                )

                // Quick-fix to delete unused `\label{...}`
                let removeEdit = LSPTextEdit(
                    filePath: lblRecord.filePath,
                    replaceByteRange: lblRecord.span.start.utf8Offset..<lblRecord.span.end.utf8Offset,
                    span: lblRecord.span,
                    replacementText: ""
                )
                actions.append(
                    LSPCodeAction(
                        id: "fix:LINT_UNREFERENCED_EQUATION:\(lblRecord.filePath):\(lblRecord.span.start.line):\(lblRecord.key)",
                        title: "Remove unreferenced equation label '\\label{\(lblRecord.key)}'",
                        diagnosticCode: "LINT_UNREFERENCED_EQUATION",
                        kind: .quickFix,
                        workspaceEdit: LSPWorkspaceEdit(
                            title: "Remove unused \\label{\(lblRecord.key)}",
                            editsByFile: [lblRecord.filePath: [removeEdit]]
                        )
                    )
                )
            }
        }

        // 5C. Uncited bibliography entries (`LINT_UNCITED_BIB_ENTRY`)
        if enableUncitedBibLint && !bibliography.isEmpty && !workspace.symbolTable.allCitationOccurrences.isEmpty {
            let citedLowerBibKeys = Set(citedBibKeys.map { $0.lowercased() })
            let hoverEngine = HoverDefinitionAndReferencesEngine(firewall: firewall)
            let fallbackBibEdge = workspace.includeGraph.edges.first(where: \.isBibliographyResource)
            let rootSpan = TextSpan(filePath: workspace.includeGraph.rootFilePath, start: .startOfFile, end: .startOfFile)

            for entry in bibliography where !citedBibKeys.contains(entry.citeKey) && !citedLowerBibKeys.contains(entry.citeKey.lowercased()) {
                let targetSpan = hoverEngine.locateBibTeXEntryDefinition(
                    citeKey: entry.citeKey,
                    originSpan: nil,
                    bibliographyFiles: bibliographyFiles,
                    workspace: workspace,
                    sourcesByFile: sourcesByFile
                )?.targetSpan ?? fallbackBibEdge?.directiveSpan ?? rootSpan

                diagnostics.append(
                    LSPDiagnostic(
                        code: "LINT_UNCITED_BIB_ENTRY",
                        severity: .hint,
                        message: "Bibliography entry '\(entry.citeKey)' (\(entry.firstAuthorFamily), \(entry.year.map(String.init) ?? "n.d.")) is uncited in the manuscript.",
                        span: targetSpan,
                        suggestedFix: "Cite via '\\cite{\(entry.citeKey)}' or prune unused reference."
                    )
                )
            }
        }

        return (diagnostics, actions)
    }

    private struct FloatDirectiveHit {
        let span: TextSpan
        let byteRange: Range<Int>
        let argumentText: String
        let fullSnippet: String
    }

    private func inspectLatexFloatsInTokens(
        tokens: [MarkupToken],
        filePath: String,
        source: String,
        lineIndex: LineByteIndex
    ) -> (diagnostics: [LSPDiagnostic], actions: [LSPCodeAction]) {
        var diags: [LSPDiagnostic] = []
        var actions: [LSPCodeAction] = []

        struct ActiveFloatFrame {
            let envName: String
            let beginSpan: TextSpan
            var firstCaption: FloatDirectiveHit?
            var firstLabel: FloatDirectiveHit?
        }

        var stack: [ActiveFloatFrame] = []
        let bytes = Array(source.utf8)
        var i = 0
        let count = tokens.count

        while i < count {
            let tok = tokens[i]
            if tok.kind == .command {
                if tok.lexeme == "\\begin", let (envName, endPos, nextIdx) = readSimpleBraceArg(tokens: tokens, commandIndex: i) {
                    if Self.floatEnvNames.contains(envName) {
                        let span = TextSpan(filePath: filePath, start: tok.span.start, end: endPos)
                        stack.append(ActiveFloatFrame(envName: envName, beginSpan: span))
                    }
                    i = nextIdx
                    continue
                } else if tok.lexeme == "\\end", let (envName, _, nextIdx) = readSimpleBraceArg(tokens: tokens, commandIndex: i) {
                    if Self.floatEnvNames.contains(envName),
                       let matchIdx = stack.lastIndex(where: { $0.envName == envName }) {
                        let closed = stack.remove(at: matchIdx)
                        // Evaluate closed float!
                        if let cap = closed.firstCaption, let lbl = closed.firstLabel {
                            if lbl.byteRange.lowerBound < cap.byteRange.lowerBound {
                                // CRITICAL LaTeX bug: `\label` placed BEFORE `\caption`!
                                diags.append(
                                    LSPDiagnostic(
                                        code: "LINT_LABEL_BEFORE_CAPTION",
                                        severity: .error,
                                        message: "'\\label{\(lbl.argumentText)}' appears before '\\caption' inside '\(closed.envName)'; in LaTeX this binds \\ref to the section counter instead of the float number!",
                                        span: lbl.span,
                                        suggestedFix: "Move '\\label{\(lbl.argumentText)}' immediately after '\\caption{...}'."
                                    )
                                )

                                // Build clean 2-edit workspace action: remove early `\label{...}` and insert after `\caption{...}`
                                let deleteEdit = LSPTextEdit(
                                    filePath: filePath,
                                    replaceByteRange: lbl.byteRange,
                                    span: lbl.span,
                                    replacementText: ""
                                )
                                let insertPos = lineIndex.position(forUTF8Offset: cap.byteRange.upperBound, in: source)
                                let insertSpan = TextSpan(filePath: filePath, start: insertPos, end: insertPos)
                                let insertEdit = LSPTextEdit(
                                    filePath: filePath,
                                    replaceByteRange: cap.byteRange.upperBound..<cap.byteRange.upperBound,
                                    span: insertSpan,
                                    replacementText: "\n    \(lbl.fullSnippet)"
                                )
                                actions.append(
                                    LSPCodeAction(
                                        id: "fix:LINT_LABEL_BEFORE_CAPTION:\(filePath):\(lbl.span.start.line):\(lbl.argumentText)",
                                        title: "Move '\\label{\(lbl.argumentText)}' after '\\caption'",
                                        diagnosticCode: "LINT_LABEL_BEFORE_CAPTION",
                                        kind: .quickFix,
                                        workspaceEdit: LSPWorkspaceEdit(
                                            title: "Move \\label{\(lbl.argumentText)} after \\caption",
                                            editsByFile: [filePath: [deleteEdit, insertEdit]]
                                        )
                                    )
                                )
                            }
                        } else if let cap = closed.firstCaption, closed.firstLabel == nil {
                            // Float has `\caption` without `\label`!
                            let prefix = closed.envName.hasPrefix("tab") || closed.envName == "longtable"
                                ? "tab:"
                                : (closed.envName.hasPrefix("alg") ? "alg:" : "fig:")
                            let slug = synthesizeLabelSlug(fromCaption: cap.argumentText, prefix: prefix)

                            diags.append(
                                LSPDiagnostic(
                                    code: "LINT_FLOAT_MISSING_LABEL",
                                    severity: .warning,
                                    message: "Float '\(closed.envName)' has a \\caption but no \\label{...} for cross-referencing.",
                                    span: cap.span,
                                    suggestedFix: "Insert '\\label{\(slug)}' after '\\caption'."
                                )
                            )

                            let insertPos = lineIndex.position(forUTF8Offset: cap.byteRange.upperBound, in: source)
                            let insertSpan = TextSpan(filePath: filePath, start: insertPos, end: insertPos)
                            let insertEdit = LSPTextEdit(
                                filePath: filePath,
                                replaceByteRange: cap.byteRange.upperBound..<cap.byteRange.upperBound,
                                span: insertSpan,
                                replacementText: "\n    \\label{\(slug)}"
                            )
                            actions.append(
                                LSPCodeAction(
                                    id: "fix:LINT_FLOAT_MISSING_LABEL:\(filePath):\(cap.span.start.line):\(slug)",
                                    title: "Insert '\\label{\(slug)}' after '\\caption'",
                                    diagnosticCode: "LINT_FLOAT_MISSING_LABEL",
                                    kind: .quickFix,
                                    workspaceEdit: LSPWorkspaceEdit(
                                        title: "Insert \\label{\(slug)}",
                                        editsByFile: [filePath: [insertEdit]]
                                    )
                                )
                            )
                        }
                    }
                    i = nextIdx
                    continue
                } else if !stack.isEmpty && (tok.lexeme == "\\caption" || tok.lexeme == "\\caption*") {
                    if let (capText, endPos, nextIdx) = readSimpleBraceArg(tokens: tokens, commandIndex: i, allowOptionalBracketBeforeBrace: true) {
                        let range = tok.span.start.utf8Offset..<endPos.utf8Offset
                        let rawSnippet = String(decoding: bytes[range], as: UTF8.self)
                        let hit = FloatDirectiveHit(
                            span: TextSpan(filePath: filePath, start: tok.span.start, end: endPos),
                            byteRange: range,
                            argumentText: capText,
                            fullSnippet: rawSnippet
                        )
                        if stack[stack.count - 1].firstCaption == nil {
                            stack[stack.count - 1].firstCaption = hit
                        }
                        i = nextIdx
                        continue
                    }
                } else if !stack.isEmpty && tok.lexeme == "\\label" {
                    if let (lblText, endPos, nextIdx) = readSimpleBraceArg(tokens: tokens, commandIndex: i) {
                        let range = tok.span.start.utf8Offset..<endPos.utf8Offset
                        let rawSnippet = String(decoding: bytes[range], as: UTF8.self)
                        let hit = FloatDirectiveHit(
                            span: TextSpan(filePath: filePath, start: tok.span.start, end: endPos),
                            byteRange: range,
                            argumentText: lblText.trimmingCharacters(in: .whitespacesAndNewlines),
                            fullSnippet: rawSnippet
                        )
                        if stack[stack.count - 1].firstLabel == nil {
                            stack[stack.count - 1].firstLabel = hit
                        }
                        i = nextIdx
                        continue
                    }
                }
            }
            i += 1
        }

        return (diags, actions)
    }

    private static let tieRequiredCommands: Set<String> = [
        "\\ref", "\\eqref", "\\pageref", "\\cite", "\\citep"
    ]

    private static let tiePrecedingTriggerWords: Set<String> = [
        "figure", "figures", "fig", "figs",
        "table", "tables", "tab", "tabs",
        "section", "sections", "sec", "secs",
        "equation", "equations", "eq", "eqs",
        "theorem", "lemma", "proposition", "corollary", "algorithm", "appendix", "chapter"
    ]

    private func inspectMissingNonBreakingTies(
        tokens: [MarkupToken],
        filePath: String,
        source: String,
        lineIndex: LineByteIndex
    ) -> (diagnostics: [LSPDiagnostic], actions: [LSPCodeAction]) {
        var diags: [LSPDiagnostic] = []
        var actions: [LSPCodeAction] = []
        _ = lineIndex

        guard tokens.count >= 3 else { return ([], []) }
        for i in 2..<tokens.count {
            let cmdTok = tokens[i]
            guard cmdTok.kind == .command, Self.tieRequiredCommands.contains(cmdTok.lexeme) else { continue }
            let wsTok = tokens[i - 1]
            // Only flag horizontal single-line spaces (not newline paragraph/line starts!)
            guard wsTok.kind == .whitespace, !wsTok.lexeme.contains("\n"), !wsTok.lexeme.contains("\r") else {
                continue
            }

            // Check preceding word (e.g. `Figure \ref{...}` or `Fig. \ref{...}` or prose before `\cite{...}`)
            var prevIdx = i - 2
            if tokens[prevIdx].kind == .punctuation && tokens[prevIdx].lexeme == "." && prevIdx > 0 {
                prevIdx -= 1
            }
            let prevWordTok = tokens[prevIdx]
            guard prevWordTok.kind == .textWord || prevWordTok.kind == .identifier else { continue }
            let prevLower = prevWordTok.lexeme.lowercased()

            let shouldFlag: Bool
            if cmdTok.lexeme == "\\cite" || cmdTok.lexeme == "\\citep" {
                // Flag prose word followed by space + `\cite`
                shouldFlag = prevWordTok.lexeme.first?.isLetter == true
            } else {
                shouldFlag = Self.tiePrecedingTriggerWords.contains(prevLower)
            }
            guard shouldFlag else { continue }

            diags.append(
                LSPDiagnostic(
                    code: "LINT_MISSING_NONBREAKING_TIE",
                    severity: .hint,
                    message: "Missing non-breaking tie '~' before '\(cmdTok.lexeme)' (prevents awkward TeX line breaks after '\(prevWordTok.lexeme)').",
                    span: wsTok.span,
                    suggestedFix: "Replace space with '~' (\(prevWordTok.lexeme)~\(cmdTok.lexeme))."
                )
            )

            let tieEdit = LSPTextEdit(
                filePath: filePath,
                replaceByteRange: wsTok.span.start.utf8Offset..<wsTok.span.end.utf8Offset,
                span: wsTok.span,
                replacementText: "~"
            )
            actions.append(
                LSPCodeAction(
                    id: "fix:TIE:\(filePath):\(wsTok.span.start.line):\(wsTok.span.start.column)",
                    title: "Insert non-breaking tie '~' before '\(cmdTok.lexeme)'",
                    diagnosticCode: "LINT_MISSING_NONBREAKING_TIE",
                    kind: .quickFix,
                    workspaceEdit: LSPWorkspaceEdit(
                        title: "Use non-breaking tie '~'",
                        editsByFile: [filePath: [tieEdit]]
                    )
                )
            )
        }

        return (diags, actions)
    }

    // MARK: - Quick-Fix Helper Builders

    private func buildRemoveCitedKeyCodeAction(
        occurrence: CitationOccurrenceRecord,
        reasonLabel: String,
        workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String]
    ) -> LSPCodeAction? {
        guard let pr = workspace.perFileParseResults[occurrence.span.filePath],
              let source = sourcesByFile[occurrence.span.filePath] else {
            return nil
        }
        let lineIdx = LineByteIndex(source: source)

        // Inspect if this is a multi-key LaTeX citation `\cite{a, badKey, b}` or a single-key citation
        if pr.format == .latex,
           let cmdIdx = pr.tokens.firstIndex(where: { $0.span.start.utf8Offset == occurrence.span.start.utf8Offset }),
           let (braceStartByte, braceEndByte, innerContent) = readBraceByteSpan(tokens: pr.tokens, commandIndex: cmdIdx) {
            let keys = innerContent
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if keys.count > 1 {
                let remaining = keys.filter { $0 != occurrence.citeKey }.joined(separator: ", ")
                let innerRange = (braceStartByte + 1)..<(braceEndByte - 1)
                let sPos = lineIdx.position(forUTF8Offset: innerRange.lowerBound, in: source)
                let ePos = lineIdx.position(forUTF8Offset: innerRange.upperBound, in: source)
                let edit = LSPTextEdit(
                    filePath: occurrence.span.filePath,
                    replaceByteRange: innerRange,
                    span: TextSpan(filePath: occurrence.span.filePath, start: sPos, end: ePos),
                    replacementText: remaining
                )
                return LSPCodeAction(
                    id: "fix:FW_REMOVE:\(occurrence.span.filePath):\(occurrence.span.start.line):\(occurrence.citeKey)",
                    title: "Remove \(reasonLabel) '\(occurrence.citeKey)' from citation cluster",
                    diagnosticCode: "ERR_UNVERIFIED_CITATION",
                    kind: .citationFirewallRemediation,
                    workspaceEdit: LSPWorkspaceEdit(
                        title: "Remove '\(occurrence.citeKey)'",
                        editsByFile: [occurrence.span.filePath: [edit]]
                    )
                )
            }
        }

        // Single-key citation: remove the directive span cleanly
        let edit = LSPTextEdit(
            filePath: occurrence.span.filePath,
            replaceByteRange: occurrence.span.start.utf8Offset..<occurrence.span.end.utf8Offset,
            span: occurrence.span,
            replacementText: ""
        )
        return LSPCodeAction(
            id: "fix:FW_REMOVE:\(occurrence.span.filePath):\(occurrence.span.start.line):\(occurrence.citeKey)",
            title: "Remove \(reasonLabel) '\(occurrence.citeKey)'",
            diagnosticCode: "ERR_UNVERIFIED_CITATION",
            kind: .citationFirewallRemediation,
            workspaceEdit: LSPWorkspaceEdit(
                title: "Remove citation '\(occurrence.citeKey)'",
                editsByFile: [occurrence.span.filePath: [edit]]
            )
        )
    }

    fileprivate func locateKeyEditInDirective(
        tokens: [MarkupToken],
        directiveSpan: TextSpan,
        oldKey: String,
        newKey: String,
        source: String,
        lineIndex: LineByteIndex
    ) -> LSPTextEdit? {
        // Typst `@oldKey` shorthand token
        if let atTok = tokens.first(where: { $0.kind == .typstHashKeyword && $0.lexeme == "@\(oldKey)" && $0.span.start.utf8Offset == directiveSpan.start.utf8Offset }) {
            let startByte = atTok.span.start.utf8Offset + 1
            let endByte = atTok.span.end.utf8Offset
            let sPos = lineIndex.position(forUTF8Offset: startByte, in: source)
            let ePos = lineIndex.position(forUTF8Offset: endByte, in: source)
            return LSPTextEdit(
                filePath: directiveSpan.filePath,
                replaceByteRange: startByte..<endByte,
                span: TextSpan(filePath: directiveSpan.filePath, start: sPos, end: ePos),
                replacementText: newKey
            )
        }

        // Typst `#cite(<oldKey>)` or `#ref(<oldKey>)`
        for tok in tokens where tok.span.start.utf8Offset >= directiveSpan.start.utf8Offset && tok.span.end.utf8Offset <= directiveSpan.end.utf8Offset {
            if tok.kind == .identifier && tok.lexeme == "<\(oldKey)>" {
                let sByte = tok.span.start.utf8Offset + 1
                let eByte = tok.span.end.utf8Offset - 1
                let sPos = lineIndex.position(forUTF8Offset: sByte, in: source)
                let ePos = lineIndex.position(forUTF8Offset: eByte, in: source)
                return LSPTextEdit(
                    filePath: directiveSpan.filePath,
                    replaceByteRange: sByte..<eByte,
                    span: TextSpan(filePath: directiveSpan.filePath, start: sPos, end: ePos),
                    replacementText: newKey
                )
            }
        }

        // LaTeX `\cmd[...]{a, oldKey, b}`
        if let cmdIdx = tokens.firstIndex(where: { $0.span.start.utf8Offset == directiveSpan.start.utf8Offset }),
           let (braceStartByte, _, innerContent) = readBraceByteSpan(tokens: tokens, commandIndex: cmdIdx) {
            let items = splitExactCommaKeys(innerContent: innerContent, contentStartUTF8: braceStartByte + 1)
            if let hit = items.first(where: { $0.key == oldKey }) {
                let sPos = lineIndex.position(forUTF8Offset: hit.byteRange.lowerBound, in: source)
                let ePos = lineIndex.position(forUTF8Offset: hit.byteRange.upperBound, in: source)
                return LSPTextEdit(
                    filePath: directiveSpan.filePath,
                    replaceByteRange: hit.byteRange,
                    span: TextSpan(filePath: directiveSpan.filePath, start: sPos, end: ePos),
                    replacementText: newKey
                )
            }
        }
        return nil
    }

    private func readBraceByteSpan(tokens: [MarkupToken], commandIndex: Int) -> (Int, Int, String)? {
        var j = commandIndex + 1
        while j < tokens.count {
            let t = tokens[j]
            if t.kind == .whitespace || t.kind == .comment { j += 1; continue }
            if t.kind == .leftBracket {
                var bd = 1
                j += 1
                while j < tokens.count && bd > 0 {
                    if tokens[j].kind == .leftBracket { bd += 1 }
                    else if tokens[j].kind == .rightBracket { bd -= 1 }
                    j += 1
                }
                continue
            }
            break
        }
        guard j < tokens.count, tokens[j].kind == .leftBrace else { return nil }
        let openByte = tokens[j].span.start.utf8Offset
        j += 1
        var depth = 1
        var parts: [String] = []
        var closeEndByte = openByte + 1
        while j < tokens.count && depth > 0 {
            let t = tokens[j]
            closeEndByte = t.span.end.utf8Offset
            if t.kind == .leftBrace {
                depth += 1
                parts.append(t.lexeme)
            } else if t.kind == .rightBrace {
                depth -= 1
                if depth > 0 { parts.append(t.lexeme) }
            } else if t.kind != .eof {
                parts.append(t.lexeme)
            }
            j += 1
        }
        return (openByte, closeEndByte, parts.joined())
    }

    private func readSimpleBraceArg(
        tokens: [MarkupToken],
        commandIndex: Int,
        allowOptionalBracketBeforeBrace: Bool = false
    ) -> (String, TextPosition, Int)? {
        var j = commandIndex + 1
        while j < tokens.count {
            let t = tokens[j]
            if t.kind == .whitespace || t.kind == .comment { j += 1; continue }
            if allowOptionalBracketBeforeBrace && t.kind == .leftBracket {
                var bd = 1
                j += 1
                while j < tokens.count && bd > 0 {
                    if tokens[j].kind == .leftBracket { bd += 1 }
                    else if tokens[j].kind == .rightBracket { bd -= 1 }
                    j += 1
                }
                continue
            }
            break
        }
        guard j < tokens.count, tokens[j].kind == .leftBrace else { return nil }
        var endPos = tokens[j].span.end
        j += 1
        var depth = 1
        var parts: [String] = []
        while j < tokens.count && depth > 0 {
            let t = tokens[j]
            endPos = t.span.end
            if t.kind == .leftBrace {
                depth += 1
                parts.append(t.lexeme)
            } else if t.kind == .rightBrace {
                depth -= 1
                if depth > 0 { parts.append(t.lexeme) }
            } else if t.kind != .eof {
                parts.append(t.lexeme)
            }
            j += 1
        }
        return (parts.joined(), endPos, j)
    }

    private func synthesizeLabelSlug(fromCaption caption: String, prefix: String) -> String {
        let stopWords: Set<String> = ["the", "a", "an", "of", "in", "on", "for", "and", "with", "across", "our", "to", "by"]
        let words = caption
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
        if words.isEmpty {
            return "\(prefix)item"
        }
        return prefix + words.prefix(3).joined(separator: "-")
    }

    private func deduplicateAndSortDiagnostics(_ list: [LSPDiagnostic]) -> [LSPDiagnostic] {
        var seen = Set<String>()
        var unique: [LSPDiagnostic] = []
        unique.reserveCapacity(list.count)
        for d in list {
            let sig = "\(d.code)|\(d.span.filePath)|\(d.span.start.line)|\(d.span.start.column)|\(d.message)"
            if seen.insert(sig).inserted {
                unique.append(d)
            }
        }
        return unique.sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                return lhs.severity > rhs.severity
            }
            if lhs.span.filePath != rhs.span.filePath {
                return lhs.span.filePath < rhs.span.filePath
            }
            if lhs.span.start != rhs.span.start {
                return lhs.span.start < rhs.span.start
            }
            if lhs.code != rhs.code {
                return lhs.code < rhs.code
            }
            return lhs.message < rhs.message
        }
    }

    private func spansOverlapOrTouch(_ a: TextSpan, _ b: TextSpan) -> Bool {
        guard a.filePath == b.filePath else { return false }
        return a.start.utf8Offset <= b.end.utf8Offset && b.start.utf8Offset <= a.end.utf8Offset
    }

    private func closestCandidate(to target: String, in candidates: [String], maxDistance: Int) -> String? {
        guard !target.isEmpty, !candidates.isEmpty else { return nil }
        var best: String? = nil
        var bestDist = Int.max
        for cand in candidates {
            let d = levenshtein(target.lowercased(), cand.lowercased())
            if d < bestDist && d <= maxDistance {
                bestDist = d
                best = cand
            }
        }
        return best
    }

    private func levenshtein(_ a: String, _ b: String) -> Int {
        let ac = Array(a)
        let bc = Array(b)
        if ac.isEmpty { return bc.count }
        if bc.isEmpty { return ac.count }
        var prev = Array(0...bc.count)
        var curr = Array(repeating: 0, count: bc.count + 1)
        for i in 1...ac.count {
            curr[0] = i
            for j in 1...bc.count {
                let cost = (ac[i - 1] == bc[j - 1]) ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[bc.count]
    }
}

// MARK: - Safe Project-Wide Rename Refactoring Engine

public struct ScholarRenameRefactorer: Sendable {
    private let lexer = IncrementalMarkupLexer(configuration: .losslessCST)

    public init() {}

    private static let labelBearingRefCommands: Set<String> = [
        "\\label", "\\ref", "\\eqref", "\\pageref", "\\autoref",
        "\\cref", "\\Cref", "\\cpageref", "\\Cpageref",
        "\\namecref", "\\nameCref", "\\vref", "\\Vref",
        "\\fref", "\\Fref", "\\labelcref"
    ]

    private static let citationCommands: Set<String> = [
        "\\cite", "\\cite*", "\\citep", "\\citep*", "\\citet", "\\citet*",
        "\\citealp", "\\citealt", "\\citeauthor", "\\citeyear", "\\citeyearpar",
        "\\parencite", "\\parencite*", "\\textcite", "\\autocite", "\\autocite*",
        "\\footcite", "\\supercite", "\\smartcite", "\\nocite", "\\fullcite", "\\cites"
    ]

    // MARK: 1. Rename Label Across Workspace (`\label`, `\ref`, `\eqref`, `\autoref`, `\cref`, `\Cref`, Typst `<lbl>` & `@lbl`)

    public func renameLabel(
        oldKey: String,
        newKey: String,
        in workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String] = [:]
    ) -> LSPWorkspaceEdit {
        let cleanOld = oldKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNew = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOld.isEmpty, !cleanNew.isEmpty, cleanOld != cleanNew else {
            return LSPWorkspaceEdit(title: "No-op label rename", editsByFile: [:])
        }

        let fileSources = collectWorkspaceFileSources(workspace: workspace, overrides: sourcesByFile)
        var editsByFile: [String: [LSPTextEdit]] = [:]

        for (filePath, source) in fileSources {
            let format = ManuscriptFormat.detect(fromPath: filePath)
            let tokens = workspace.perFileParseResults[filePath]?.tokens ?? lexer.tokenize(source: source, format: format, filePath: filePath)
            let lineIdx = LineByteIndex(source: source)
            var fileEdits: [LSPTextEdit] = []

            var i = 0
            while i < tokens.count {
                let tok = tokens[i]

                if format == .latex && tok.kind == .command {
                    if Self.labelBearingRefCommands.contains(tok.lexeme) {
                        if let (braceOpenByte, innerContent, nextIdx) = scanBracedGroupAfterCommand(tokens: tokens, commandIndex: i, allowOptionalBrackets: true) {
                            let splitKeys = splitExactCommaKeys(innerContent: innerContent, contentStartUTF8: braceOpenByte + 1)
                            for item in splitKeys where item.key == cleanOld {
                                fileEdits.append(makeEdit(filePath: filePath, byteRange: item.byteRange, replacement: cleanNew, source: source, lineIndex: lineIdx))
                            }
                            i = nextIdx
                            continue
                        }
                    } else if tok.lexeme == "\\hyperref" {
                        // `\hyperref[oldKey]{text}`
                        if let (bracketOpenByte, innerBracket, nextIdx) = scanBracketGroupAfterCommand(tokens: tokens, commandIndex: i) {
                            let trimmed = innerBracket.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed == cleanOld {
                                let lead = innerBracket.prefix(while: { $0.isWhitespace }).utf8.count
                                let startB = bracketOpenByte + 1 + lead
                                let endB = startB + trimmed.utf8.count
                                fileEdits.append(makeEdit(filePath: filePath, byteRange: startB..<endB, replacement: cleanNew, source: source, lineIndex: lineIdx))
                            }
                            i = nextIdx
                            continue
                        }
                    }
                } else if format == .typst {
                    // `<oldKey>` declaration or `#ref(<oldKey>)` argument (only when NOT preceded by `#cite(`!)
                    if tok.kind == .identifier && tok.lexeme == "<\(cleanOld)>" {
                        if !isInsideTypstCiteCall(tokens: tokens, tokenIndex: i) {
                            let sByte = tok.span.start.utf8Offset + 1
                            let eByte = tok.span.end.utf8Offset - 1
                            fileEdits.append(makeEdit(filePath: filePath, byteRange: sByte..<eByte, replacement: cleanNew, source: source, lineIndex: lineIdx))
                        }
                    } else if tok.kind == .typstHashKeyword && tok.lexeme == "@\(cleanOld)" {
                        // Exact full token `@oldKey` -> never matches `@oldKey-extra` or `@oldKey2`!
                        let sByte = tok.span.start.utf8Offset + 1
                        let eByte = tok.span.end.utf8Offset
                        fileEdits.append(makeEdit(filePath: filePath, byteRange: sByte..<eByte, replacement: cleanNew, source: source, lineIndex: lineIdx))
                    } else if tok.kind == .typstHashKeyword && tok.lexeme == "#ref" {
                        // `#ref(label("oldKey"))` string form
                        if let strEdit = scanTypstLabelStringCallEdit(tokens: tokens, startIndex: i, oldKey: cleanOld, newKey: cleanNew, filePath: filePath, source: source, lineIndex: lineIdx) {
                            fileEdits.append(strEdit)
                        }
                    }
                }

                i += 1
            }

            if !fileEdits.isEmpty {
                editsByFile[filePath] = fileEdits
            }
        }

        return LSPWorkspaceEdit(
            title: "Rename label '\(cleanOld)' to '\(cleanNew)'",
            editsByFile: editsByFile
        )
    }

    // MARK: 2. Rename Citation Key Across Multi-Key `\cite{a, oldKey, b}`, Typst `#cite(<oldKey>)` / `@oldKey` & `.bib` Files

    public func renameCiteKey(
        oldKey: String,
        newKey: String,
        in workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String] = [:],
        bibliographyFiles: [String: String] = [:]
    ) -> LSPWorkspaceEdit {
        let cleanOld = oldKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNew = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOld.isEmpty, !cleanNew.isEmpty, cleanOld != cleanNew else {
            return LSPWorkspaceEdit(title: "No-op citeKey rename", editsByFile: [:])
        }

        let fileSources = collectWorkspaceFileSources(workspace: workspace, overrides: sourcesByFile)
        var editsByFile: [String: [LSPTextEdit]] = [:]

        for (filePath, source) in fileSources {
            let format = ManuscriptFormat.detect(fromPath: filePath)
            let tokens = workspace.perFileParseResults[filePath]?.tokens ?? lexer.tokenize(source: source, format: format, filePath: filePath)
            let lineIdx = LineByteIndex(source: source)
            var fileEdits: [LSPTextEdit] = []

            var i = 0
            while i < tokens.count {
                let tok = tokens[i]

                if format == .latex && tok.kind == .command && Self.citationCommands.contains(tok.lexeme) {
                    if let (braceOpenByte, innerContent, nextIdx) = scanBracedGroupAfterCommand(tokens: tokens, commandIndex: i, allowOptionalBrackets: true) {
                        let splitKeys = splitExactCommaKeys(innerContent: innerContent, contentStartUTF8: braceOpenByte + 1)
                        for item in splitKeys where item.key == cleanOld {
                            fileEdits.append(makeEdit(filePath: filePath, byteRange: item.byteRange, replacement: cleanNew, source: source, lineIndex: lineIdx))
                        }
                        i = nextIdx
                        continue
                    }
                } else if format == .typst {
                    if tok.kind == .typstHashKeyword && tok.lexeme == "#cite" {
                        if let citeEdit = scanTypstCiteAngleOrStringEdit(tokens: tokens, startIndex: i, oldKey: cleanOld, newKey: cleanNew, filePath: filePath, source: source, lineIndex: lineIdx) {
                            fileEdits.append(citeEdit)
                        }
                    } else if tok.kind == .typstHashKeyword && tok.lexeme == "@\(cleanOld)" {
                        // Only rename `@oldKey` as citation if `oldKey` is not shadowed by a document `<oldKey>` label
                        if workspace.symbolTable.labelsByKey[cleanOld] == nil {
                            let sByte = tok.span.start.utf8Offset + 1
                            let eByte = tok.span.end.utf8Offset
                            fileEdits.append(makeEdit(filePath: filePath, byteRange: sByte..<eByte, replacement: cleanNew, source: source, lineIndex: lineIdx))
                        }
                    }
                } else if format == .markdown {
                    // Pandoc `@oldKey` inside `[@oldKey]` or prose
                    if (tok.kind == .typstHashKeyword || tok.kind == .identifier || tok.kind == .textWord) && tok.lexeme == "@\(cleanOld)" {
                        let sByte = tok.span.start.utf8Offset + 1
                        let eByte = tok.span.end.utf8Offset
                        fileEdits.append(makeEdit(filePath: filePath, byteRange: sByte..<eByte, replacement: cleanNew, source: source, lineIndex: lineIdx))
                    }
                }

                i += 1
            }

            if !fileEdits.isEmpty {
                editsByFile[filePath] = fileEdits
            }
        }

        // Also update `@article{oldKey,` headers inside any provided `.bib` files!
        for (bibPath, bibSource) in bibliographyFiles {
            let bibEdits = findBibEntryHeaderKeyEdits(in: bibSource, filePath: bibPath, oldKey: cleanOld, newKey: cleanNew)
            if !bibEdits.isEmpty {
                editsByFile[bibPath, default: []].append(contentsOf: bibEdits)
            }
        }

        return LSPWorkspaceEdit(
            title: "Rename citation key '\(cleanOld)' to '\(cleanNew)'",
            editsByFile: editsByFile
        )
    }

    // MARK: 3. Rename User Macro Across Declarations & All Call Sites

    public func renameMacro(
        oldName: String,
        newName: String,
        in workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String] = [:]
    ) -> LSPWorkspaceEdit {
        let rawOld = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawOld.isEmpty, !rawNew.isEmpty else {
            return LSPWorkspaceEdit(title: "No-op macro rename", editsByFile: [:])
        }

        let bareOld = stripLeadingMacroSigil(rawOld)
        let bareNew = stripLeadingMacroSigil(rawNew)
        guard !bareOld.isEmpty, !bareNew.isEmpty, bareOld != bareNew else {
            return LSPWorkspaceEdit(title: "No-op macro rename", editsByFile: [:])
        }

        let latexOld = "\\\(bareOld)"
        let latexNew = "\\\(bareNew)"

        let fileSources = collectWorkspaceFileSources(workspace: workspace, overrides: sourcesByFile)
        var editsByFile: [String: [LSPTextEdit]] = [:]

        for (filePath, source) in fileSources {
            let format = ManuscriptFormat.detect(fromPath: filePath)
            let tokens = workspace.perFileParseResults[filePath]?.tokens ?? lexer.tokenize(source: source, format: format, filePath: filePath)
            let lineIdx = LineByteIndex(source: source)
            var fileEdits: [LSPTextEdit] = []

            for tok in tokens {
                if format == .latex {
                    // Exact command match (`\oldcmd` in both `\newcommand{\oldcmd}` and `\oldcmd{arg}` — never matches `\oldcmdextra`!)
                    if tok.kind == .command && tok.lexeme == latexOld {
                        fileEdits.append(
                            makeEdit(
                                filePath: filePath,
                                byteRange: tok.span.start.utf8Offset..<tok.span.end.utf8Offset,
                                replacement: latexNew,
                                source: source,
                                lineIndex: lineIdx
                            )
                        )
                    }
                } else if format == .typst {
                    if tok.kind == .typstHashKeyword && tok.lexeme == "#\(bareOld)" {
                        fileEdits.append(
                            makeEdit(
                                filePath: filePath,
                                byteRange: tok.span.start.utf8Offset..<tok.span.end.utf8Offset,
                                replacement: "#\(bareNew)",
                                source: source,
                                lineIndex: lineIdx
                            )
                        )
                    } else if (tok.kind == .identifier || tok.kind == .textWord) && tok.lexeme == bareOld {
                        // Matches `#let oldName(...) = ...` declaration identifier and math-mode calls
                        fileEdits.append(
                            makeEdit(
                                filePath: filePath,
                                byteRange: tok.span.start.utf8Offset..<tok.span.end.utf8Offset,
                                replacement: bareNew,
                                source: source,
                                lineIndex: lineIdx
                            )
                        )
                    }
                }
            }

            if !fileEdits.isEmpty {
                editsByFile[filePath] = fileEdits
            }
        }

        return LSPWorkspaceEdit(
            title: "Rename macro '\(rawOld)' to '\(rawNew)'",
            editsByFile: editsByFile
        )
    }

    // MARK: 4. Symbol-At-Cursor Unified Rename Entry Point

    public func renameSymbol(
        at position: TextPosition,
        in filePath: String,
        newName: String,
        workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String] = [:],
        bibliography: [BibliographyEntry] = [],
        bibliographyFiles: [String: String] = [:]
    ) throws -> LSPWorkspaceEdit {
        let resolver = HoverDefinitionAndReferencesEngine()
        guard let symbol = resolver.resolveSymbol(
            at: position,
            in: filePath,
            workspace: workspace,
            sourcesByFile: sourcesByFile,
            bibliography: bibliography
        ) else {
            throw ScholarOSError.invalidCLIArguments("No renameable symbol (label, citeKey, or user macro) found at \(filePath):\(position.line):\(position.column).")
        }

        switch symbol {
        case .labelDeclaration(let key, _, _),
             .crossReference(let key, _, _, _):
            return renameLabel(oldKey: key, newKey: newName, in: workspace, sourcesByFile: sourcesByFile)

        case .citation(let citeKey, _, _, _, _):
            return renameCiteKey(oldKey: citeKey, newKey: newName, in: workspace, sourcesByFile: sourcesByFile, bibliographyFiles: bibliographyFiles)

        case .userMacroDeclaration(let macro),
             .userMacroCall(let macro, _, _):
            return renameMacro(oldName: macro.name, newName: newName, in: workspace, sourcesByFile: sourcesByFile)

        default:
            throw ScholarOSError.invalidCLIArguments("Symbol at \(filePath):\(position.line):\(position.column) does not support project-wide rename.")
        }
    }

    // MARK: - Internal Rename Scanning Helpers

    private func collectWorkspaceFileSources(
        workspace: MergedManuscriptWorkspaceAST,
        overrides: [String: String]
    ) -> [(String, String)] {
        var map: [String: String] = [:]
        for (path, pr) in workspace.perFileParseResults {
            map[path] = pr.tokens.map(\.lexeme).joined()
        }
        for (path, text) in overrides {
            map[path] = text
        }
        return map.keys.sorted().compactMap { k in map[k].map { (k, $0) } }
    }

    private func stripLeadingMacroSigil(_ raw: String) -> String {
        if raw.hasPrefix("\\") || raw.hasPrefix("#") {
            return String(raw.dropFirst())
        }
        return raw
    }

    private func scanBracedGroupAfterCommand(
        tokens: [MarkupToken],
        commandIndex: Int,
        allowOptionalBrackets: Bool
    ) -> (braceOpenByte: Int, innerContent: String, nextIndex: Int)? {
        var j = commandIndex + 1
        while j < tokens.count {
            let t = tokens[j]
            if t.kind == .whitespace || t.kind == .comment { j += 1; continue }
            if allowOptionalBrackets && t.kind == .leftBracket {
                var bd = 1
                j += 1
                while j < tokens.count && bd > 0 {
                    if tokens[j].kind == .leftBracket { bd += 1 }
                    else if tokens[j].kind == .rightBracket { bd -= 1 }
                    j += 1
                }
                continue
            }
            break
        }
        guard j < tokens.count, tokens[j].kind == .leftBrace else { return nil }
        let braceOpenByte = tokens[j].span.start.utf8Offset
        j += 1
        var depth = 1
        var parts: [String] = []
        while j < tokens.count && depth > 0 {
            let t = tokens[j]
            if t.kind == .leftBrace {
                depth += 1
                parts.append(t.lexeme)
            } else if t.kind == .rightBrace {
                depth -= 1
                if depth > 0 { parts.append(t.lexeme) }
            } else if t.kind != .eof {
                parts.append(t.lexeme)
            }
            j += 1
        }
        return (braceOpenByte, parts.joined(), j)
    }

    private func scanBracketGroupAfterCommand(
        tokens: [MarkupToken],
        commandIndex: Int
    ) -> (bracketOpenByte: Int, innerContent: String, nextIndex: Int)? {
        var j = commandIndex + 1
        while j < tokens.count && (tokens[j].kind == .whitespace || tokens[j].kind == .comment) {
            j += 1
        }
        guard j < tokens.count, tokens[j].kind == .leftBracket else { return nil }
        let openByte = tokens[j].span.start.utf8Offset
        j += 1
        var depth = 1
        var parts: [String] = []
        while j < tokens.count && depth > 0 {
            let t = tokens[j]
            if t.kind == .leftBracket {
                depth += 1
                parts.append(t.lexeme)
            } else if t.kind == .rightBracket {
                depth -= 1
                if depth > 0 { parts.append(t.lexeme) }
            } else if t.kind != .eof {
                parts.append(t.lexeme)
            }
            j += 1
        }
        return (openByte, parts.joined(), j)
    }

    private func isInsideTypstCiteCall(tokens: [MarkupToken], tokenIndex: Int) -> Bool {
        var k = tokenIndex - 1
        while k >= 0 && tokenIndex - k <= 4 {
            let t = tokens[k]
            if t.kind == .typstHashKeyword && t.lexeme == "#cite" {
                return true
            }
            if t.kind == .punctuation && t.lexeme == ")" {
                return false
            }
            k -= 1
        }
        return false
    }

    private func scanTypstCiteAngleOrStringEdit(
        tokens: [MarkupToken],
        startIndex: Int,
        oldKey: String,
        newKey: String,
        filePath: String,
        source: String,
        lineIndex: LineByteIndex
    ) -> LSPTextEdit? {
        var j = startIndex + 1
        guard j < tokens.count, tokens[j].kind == .punctuation, tokens[j].lexeme == "(" else { return nil }
        j += 1
        var depth = 1
        while j < tokens.count && depth > 0 {
            let t = tokens[j]
            if t.kind == .punctuation && t.lexeme == "(" { depth += 1 }
            else if t.kind == .punctuation && t.lexeme == ")" { depth -= 1 }
            else if t.kind == .identifier && (t.lexeme == "<\(oldKey)>" || t.lexeme == "\"\(oldKey)\"") {
                let sByte = t.span.start.utf8Offset + 1
                let eByte = t.span.end.utf8Offset - 1
                return makeEdit(filePath: filePath, byteRange: sByte..<eByte, replacement: newKey, source: source, lineIndex: lineIndex)
            }
            j += 1
        }
        return nil
    }

    private func scanTypstLabelStringCallEdit(
        tokens: [MarkupToken],
        startIndex: Int,
        oldKey: String,
        newKey: String,
        filePath: String,
        source: String,
        lineIndex: LineByteIndex
    ) -> LSPTextEdit? {
        var j = startIndex + 1
        guard j < tokens.count, tokens[j].kind == .punctuation, tokens[j].lexeme == "(" else { return nil }
        j += 1
        var depth = 1
        while j < tokens.count && depth > 0 {
            let t = tokens[j]
            if t.kind == .punctuation && t.lexeme == "(" { depth += 1 }
            else if t.kind == .punctuation && t.lexeme == ")" { depth -= 1 }
            else if t.kind == .identifier && t.lexeme == "\"\(oldKey)\"" {
                let sByte = t.span.start.utf8Offset + 1
                let eByte = t.span.end.utf8Offset - 1
                return makeEdit(filePath: filePath, byteRange: sByte..<eByte, replacement: newKey, source: source, lineIndex: lineIndex)
            }
            j += 1
        }
        return nil
    }

    private func findBibEntryHeaderKeyEdits(
        in bibSource: String,
        filePath: String,
        oldKey: String,
        newKey: String
    ) -> [LSPTextEdit] {
        var edits: [LSPTextEdit] = []
        let lineIdx = LineByteIndex(source: bibSource)
        let bytes = Array(bibSource.utf8)
        var i = 0

        while i < bytes.count {
            if bytes[i] == 0x40 { // '@'
                i += 1
                while i < bytes.count && ((bytes[i] >= 0x41 && bytes[i] <= 0x5A) || (bytes[i] >= 0x61 && bytes[i] <= 0x7A)) {
                    i += 1
                }
                while i < bytes.count && (bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D) {
                    i += 1
                }
                if i < bytes.count && (bytes[i] == 0x7B || bytes[i] == 0x28) {
                    i += 1
                    while i < bytes.count && (bytes[i] == 0x20 || bytes[i] == 0x09) {
                        i += 1
                    }
                    let keyStart = i
                    while i < bytes.count && bytes[i] != 0x2C && bytes[i] != 0x7D && bytes[i] != 0x0A && bytes[i] != 0x20 {
                        i += 1
                    }
                    let keyEnd = i
                    let parsedKey = String(decoding: bytes[keyStart..<keyEnd], as: UTF8.self)
                    if parsedKey == oldKey {
                        edits.append(makeEdit(filePath: filePath, byteRange: keyStart..<keyEnd, replacement: newKey, source: bibSource, lineIndex: lineIdx))
                    }
                    continue
                }
            }
            i += 1
        }
        return edits
    }

    private func makeEdit(
        filePath: String,
        byteRange: Range<Int>,
        replacement: String,
        source: String,
        lineIndex: LineByteIndex
    ) -> LSPTextEdit {
        let startPos = lineIndex.position(forUTF8Offset: byteRange.lowerBound, in: source)
        let endPos = lineIndex.position(forUTF8Offset: byteRange.upperBound, in: source)
        return LSPTextEdit(
            filePath: filePath,
            replaceByteRange: byteRange,
            span: TextSpan(filePath: filePath, start: startPos, end: endPos),
            replacementText: replacement
        )
    }
}

// MARK: - File-Private Exact Comma Splitting Helper

private func splitExactCommaKeys(
    innerContent: String,
    contentStartUTF8: Int
) -> [(key: String, byteRange: Range<Int>)] {
    var items: [(String, Range<Int>)] = []
    let segments = innerContent.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    var offset = contentStartUTF8

    for (idx, seg) in segments.enumerated() {
        let leadUTF8 = seg.prefix(while: { $0.isWhitespace }).utf8.count
        let trimmed = seg.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let start = offset + leadUTF8
            let end = start + trimmed.utf8.count
            items.append((trimmed, start..<end))
        }
        offset += seg.utf8.count
        if idx + 1 < segments.count {
            offset += 1 // ','
        }
    }
    return items
}
