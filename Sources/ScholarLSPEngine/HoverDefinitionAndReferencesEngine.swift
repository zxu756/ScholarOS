import Foundation
import ScholarModels
import ScholarMarkupAST
import ScholarBibAndCSL

// MARK: - Hover Cards, Location Links & Cursor Symbol Resolution Models

public enum LSPLocationRole: String, Sendable, Codable, Hashable, CaseIterable {
    case declaration = "declaration"
    case definition = "definition"
    case reference = "reference"
    case citationOccurrence = "citation_occurrence"
    case macroCall = "macro_call"
    case fileInclude = "file_include"
}

public struct LSPLocationLink: Sendable, Codable, Hashable, Identifiable {
    public var id: String {
        "\(role.rawValue):\(targetSpan.filePath):\(targetSpan.start.line):\(targetSpan.start.column)"
    }
    public let originSpan: TextSpan?
    public let targetSpan: TextSpan
    public let previewExcerpt: String
    public let role: LSPLocationRole

    public init(
        originSpan: TextSpan? = nil,
        targetSpan: TextSpan,
        previewExcerpt: String,
        role: LSPLocationRole
    ) {
        self.originSpan = originSpan
        self.targetSpan = targetSpan
        self.previewExcerpt = previewExcerpt
        self.role = role
    }
}

public struct LSPHoverCard: Sendable, Codable, Hashable {
    public let title: String
    public let categoryBadge: String
    public let markdownBody: String
    public let firewallClass: CitationFirewallClass?
    public let targetSpan: TextSpan?
    public let expandedPreview: String?

    public init(
        title: String,
        categoryBadge: String,
        markdownBody: String,
        firewallClass: CitationFirewallClass? = nil,
        targetSpan: TextSpan? = nil,
        expandedPreview: String? = nil
    ) {
        self.title = title
        self.categoryBadge = categoryBadge
        self.markdownBody = markdownBody
        self.firewallClass = firewallClass
        self.targetSpan = targetSpan
        self.expandedPreview = expandedPreview
    }
}

public enum ResolvedCursorSymbol: Sendable, Codable, Hashable {
    case citation(citeKey: String, command: String, keySpan: TextSpan, directiveSpan: TextSpan, clusterKeys: [String])
    case labelDeclaration(key: String, keySpan: TextSpan, directiveSpan: TextSpan)
    case crossReference(targetKey: String, command: String, keySpan: TextSpan, directiveSpan: TextSpan)
    case userMacroDeclaration(macro: MacroDefinitionRecord)
    case userMacroCall(macro: MacroDefinitionRecord, callSnippet: String, callSpan: TextSpan)
    case mathExpression(node: MarkupASTNode)
    case fileInclude(edge: IncludeGraphEdge)
    case environmentTag(name: String, span: TextSpan)
    case builtinCommand(command: String, span: TextSpan)
}

// MARK: - Multi-File Hover, Go-To-Definition & Find-All-References Engine

public struct HoverDefinitionAndReferencesEngine: Sendable {
    public let macroEngine: MacroExpansionEngine
    public let cslFormatter: CSLCitationFormatterEngine
    public let firewall: CitationVerificationFirewall

    public init(
        macroEngine: MacroExpansionEngine = MacroExpansionEngine(),
        cslFormatter: CSLCitationFormatterEngine = CSLCitationFormatterEngine(),
        firewall: CitationVerificationFirewall = CitationVerificationFirewall()
    ) {
        self.macroEngine = macroEngine
        self.cslFormatter = cslFormatter
        self.firewall = firewall
    }

    // MARK: - Public Symbol Resolution API

    public func resolveSymbol(
        at position: TextPosition,
        in filePath: String,
        workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String] = [:],
        bibliography: [BibliographyEntry] = []
    ) -> ResolvedCursorSymbol? {
        guard let parseResult = workspace.perFileParseResults[filePath] ?? fallbackParse(filePath: filePath, sourcesByFile: sourcesByFile) else {
            return nil
        }
        let source = sourcesByFile[filePath] ?? parseResult.tokens.map(\.lexeme).joined()
        let lineIdx = LineByteIndex(source: source)
        let cursor = AcademicCompletionEngine.normalizeCursorPosition(position, in: source, lineIndex: lineIdx)
        let bibKeys = Set(bibliography.map(\.citeKey))

        // 1. Check IncludeGraphEdge directives first (`\input{...}`, `\include{...}`, `#include "..."`, `\bibliography{...}`)
        for edge in workspace.includeGraph.edges where edge.sourceFile == filePath {
            if spanContains(edge.directiveSpan, position: cursor) {
                return .fileInclude(edge: edge)
            }
        }

        // 2. Check user macro declarations (`\newcommand{\foo}...`, `#let foo = ...`)
        for decl in workspace.symbolTable.allMacroDeclarations where decl.filePath == filePath {
            if let nameSpan = locateDeclaredMacroNameSpan(decl: decl, tokens: parseResult.tokens),
               spanContains(nameSpan, position: cursor) {
                return .userMacroDeclaration(macro: decl)
            }
        }

        // 3. Token-level pinpoint scan for citations, cross-refs, labels, Typst `@ref`/`<lbl>`, user macro calls, and `\begin{env}`
        if let tokenResolved = resolveFromTokenStream(
            tokens: parseResult.tokens,
            format: parseResult.format,
            filePath: filePath,
            source: source,
            lineIndex: lineIdx,
            cursor: cursor,
            symbolTable: workspace.symbolTable,
            bibliographyKeys: bibKeys
        ) {
            return tokenResolved
        }

        // 4. Check if cursor sits inside a `.mathExpression` AST node
        if let mathNode = innermostMathNode(in: parseResult.root, at: cursor) {
            return .mathExpression(node: mathNode)
        }

        // 5. Check built-in command token under cursor for documentation hover
        for tok in parseResult.tokens where tok.kind == .command || tok.kind == .typstHashKeyword {
            if spanContains(tok.span, position: cursor) {
                return .builtinCommand(command: tok.lexeme, span: tok.span)
            }
        }

        return nil
    }

    // MARK: - Rich Hover APIs

    public func hover(
        at position: TextPosition,
        in workspace: MergedManuscriptWorkspaceAST,
        bibliography: [BibliographyEntry] = [],
        bibliographyFiles: [String: String] = [:],
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict] = [:]
    ) -> LSPHoverCard? {
        hover(
            at: position,
            in: workspace.includeGraph.rootFilePath,
            workspace: workspace,
            sourcesByFile: [:],
            bibliography: bibliography,
            bibliographyFiles: bibliographyFiles,
            inRunVerdictsByKey: inRunVerdictsByKey
        )
    }

    public func hover(
        at position: TextPosition,
        in filePath: String,
        workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String] = [:],
        bibliography: [BibliographyEntry] = [],
        bibliographyFiles: [String: String] = [:],
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict] = [:]
    ) -> LSPHoverCard? {
        guard let symbol = resolveSymbol(
            at: position,
            in: filePath,
            workspace: workspace,
            sourcesByFile: sourcesByFile,
            bibliography: bibliography
        ) else {
            return nil
        }

        let bibByKey = Dictionary(bibliography.map { ($0.citeKey, $0) }, uniquingKeysWith: { first, _ in first })

        switch symbol {
        case .citation(let citeKey, let command, _, _, let clusterKeys):
            return buildCitationHoverCard(
                citeKey: citeKey,
                command: command,
                clusterKeys: clusterKeys,
                bibByKey: bibByKey,
                workspace: workspace,
                bibliographyFiles: bibliographyFiles,
                inRunVerdictsByKey: inRunVerdictsByKey
            )

        case .crossReference(let targetKey, let command, _, _):
            return buildLabelOrRefHoverCard(
                key: targetKey,
                invokedVia: command,
                workspace: workspace,
                sourcesByFile: sourcesByFile
            )

        case .labelDeclaration(let key, _, _):
            return buildLabelOrRefHoverCard(
                key: key,
                invokedVia: "\\label",
                workspace: workspace,
                sourcesByFile: sourcesByFile
            )

        case .userMacroDeclaration(let macro):
            return buildMacroHoverCard(
                macro: macro,
                callSnippet: nil,
                format: ManuscriptFormat.detect(fromPath: filePath),
                workspace: workspace
            )

        case .userMacroCall(let macro, let callSnippet, _):
            return buildMacroHoverCard(
                macro: macro,
                callSnippet: callSnippet,
                format: ManuscriptFormat.detect(fromPath: filePath),
                workspace: workspace
            )

        case .mathExpression(let mathNode):
            return buildMathExpressionHoverCard(
                node: mathNode,
                format: ManuscriptFormat.detect(fromPath: filePath),
                workspace: workspace
            )

        case .fileInclude(let edge):
            return buildFileIncludeHoverCard(edge: edge, workspace: workspace)

        case .environmentTag(let envName, let span):
            return buildEnvironmentHoverCard(envName: envName, span: span)

        case .builtinCommand(let cmd, let span):
            return buildBuiltinCommandHoverCard(command: cmd, span: span, format: ManuscriptFormat.detect(fromPath: filePath))
        }
    }

    // MARK: - Go-To-Definition APIs

    public func definition(
        at position: TextPosition,
        in workspace: MergedManuscriptWorkspaceAST,
        bibliography: [BibliographyEntry] = [],
        bibliographyFiles: [String: String] = [:]
    ) -> [LSPLocationLink] {
        definition(
            at: position,
            in: workspace.includeGraph.rootFilePath,
            workspace: workspace,
            sourcesByFile: [:],
            bibliography: bibliography,
            bibliographyFiles: bibliographyFiles
        )
    }

    public func definition(
        at position: TextPosition,
        in filePath: String,
        workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String] = [:],
        bibliography: [BibliographyEntry] = [],
        bibliographyFiles: [String: String] = [:]
    ) -> [LSPLocationLink] {
        guard let symbol = resolveSymbol(
            at: position,
            in: filePath,
            workspace: workspace,
            sourcesByFile: sourcesByFile,
            bibliography: bibliography
        ) else {
            return []
        }

        switch symbol {
        case .crossReference(let targetKey, _, let keySpan, _):
            var links: [LSPLocationLink] = []
            for decl in workspace.symbolTable.allLabelDeclarations where decl.key == targetKey {
                let excerpt = extractLineExcerpt(at: decl.span, workspace: workspace, sourcesByFile: sourcesByFile)
                links.append(
                    LSPLocationLink(
                        originSpan: keySpan,
                        targetSpan: decl.span,
                        previewExcerpt: excerpt,
                        role: .declaration
                    )
                )
            }
            return links

        case .labelDeclaration(let key, let keySpan, _):
            if let primary = workspace.symbolTable.labelsByKey[key] {
                let excerpt = extractLineExcerpt(at: primary.span, workspace: workspace, sourcesByFile: sourcesByFile)
                return [
                    LSPLocationLink(
                        originSpan: keySpan,
                        targetSpan: primary.span,
                        previewExcerpt: excerpt,
                        role: .declaration
                    )
                ]
            }
            return []

        case .userMacroCall(let macro, _, let callSpan):
            let excerpt = extractLineExcerpt(at: macro.span, workspace: workspace, sourcesByFile: sourcesByFile)
            return [
                LSPLocationLink(
                    originSpan: callSpan,
                    targetSpan: macro.span,
                    previewExcerpt: excerpt,
                    role: .definition
                )
            ]

        case .userMacroDeclaration(let macro):
            let excerpt = extractLineExcerpt(at: macro.span, workspace: workspace, sourcesByFile: sourcesByFile)
            return [
                LSPLocationLink(
                    originSpan: macro.span,
                    targetSpan: macro.span,
                    previewExcerpt: excerpt,
                    role: .declaration
                )
            ]

        case .citation(let citeKey, _, let keySpan, _, _):
            if let bibLink = locateBibTeXEntryDefinition(
                citeKey: citeKey,
                originSpan: keySpan,
                bibliographyFiles: bibliographyFiles,
                workspace: workspace,
                sourcesByFile: sourcesByFile
            ) {
                return [bibLink]
            }
            // If `.bib` raw source was not loaded in memory, link to referenced bibliography file if declared
            if let firstBibPath = workspace.includeGraph.bibliographyFiles.first {
                let entrySummary = bibliography.first(where: { $0.citeKey == citeKey }).map {
                    "@\($0.kind.rawValue){\($0.citeKey)} — \($0.title)"
                } ?? "@entry{\(citeKey)}"
                return [
                    LSPLocationLink(
                        originSpan: keySpan,
                        targetSpan: TextSpan(filePath: firstBibPath, start: .startOfFile, end: .startOfFile),
                        previewExcerpt: entrySummary,
                        role: .definition
                    )
                ]
            }
            return []

        case .fileInclude(let edge):
            guard edge.targetExists else { return [] }
            let targetSpan = TextSpan(filePath: edge.resolvedTargetFile, start: .startOfFile, end: .startOfFile)
            let firstLine = extractLineExcerpt(at: targetSpan, workspace: workspace, sourcesByFile: sourcesByFile)
            return [
                LSPLocationLink(
                    originSpan: edge.directiveSpan,
                    targetSpan: targetSpan,
                    previewExcerpt: firstLine.isEmpty ? edge.resolvedTargetFile : firstLine,
                    role: .fileInclude
                )
            ]

        case .mathExpression, .environmentTag, .builtinCommand:
            return []
        }
    }

    // MARK: - Find-All-References APIs

    public func findReferences(
        at position: TextPosition,
        in workspace: MergedManuscriptWorkspaceAST,
        includeDeclaration: Bool = true
    ) -> [LSPLocationLink] {
        findReferences(
            at: position,
            in: workspace.includeGraph.rootFilePath,
            workspace: workspace,
            sourcesByFile: [:],
            bibliography: [],
            bibliographyFiles: [:],
            includeDeclaration: includeDeclaration
        )
    }

    public func findReferences(
        at position: TextPosition,
        in filePath: String,
        workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String] = [:],
        bibliography: [BibliographyEntry] = [],
        bibliographyFiles: [String: String] = [:],
        includeDeclaration: Bool = true
    ) -> [LSPLocationLink] {
        guard let symbol = resolveSymbol(
            at: position,
            in: filePath,
            workspace: workspace,
            sourcesByFile: sourcesByFile,
            bibliography: bibliography
        ) else {
            return []
        }

        switch symbol {
        case .labelDeclaration(let key, let origin, _),
             .crossReference(let key, _, let origin, _):
            return collectAllLabelReferences(
                key: key,
                originSpan: origin,
                workspace: workspace,
                sourcesByFile: sourcesByFile,
                includeDeclaration: includeDeclaration
            )

        case .citation(let citeKey, _, let origin, _, _):
            return collectAllCitationReferences(
                citeKey: citeKey,
                originSpan: origin,
                workspace: workspace,
                sourcesByFile: sourcesByFile,
                bibliographyFiles: bibliographyFiles,
                includeDeclaration: includeDeclaration
            )

        case .userMacroDeclaration(let macro):
            return collectAllMacroReferences(
                macro: macro,
                originSpan: macro.span,
                workspace: workspace,
                sourcesByFile: sourcesByFile,
                includeDeclaration: includeDeclaration
            )

        case .userMacroCall(let macro, _, let callSpan):
            return collectAllMacroReferences(
                macro: macro,
                originSpan: callSpan,
                workspace: workspace,
                sourcesByFile: sourcesByFile,
                includeDeclaration: includeDeclaration
            )

        case .fileInclude(let edge):
            return workspace.includeGraph.edges
                .filter { $0.resolvedTargetFile == edge.resolvedTargetFile }
                .map { item in
                    LSPLocationLink(
                        originSpan: edge.directiveSpan,
                        targetSpan: item.directiveSpan,
                        previewExcerpt: extractLineExcerpt(at: item.directiveSpan, workspace: workspace, sourcesByFile: sourcesByFile),
                        role: .fileInclude
                    )
                }

        case .mathExpression, .environmentTag, .builtinCommand:
            return []
        }
    }

    // MARK: - Internal Hover Builders

    private func buildCitationHoverCard(
        citeKey: String,
        command: String,
        clusterKeys: [String],
        bibByKey: [String: BibliographyEntry],
        workspace: MergedManuscriptWorkspaceAST,
        bibliographyFiles: [String: String],
        inRunVerdictsByKey: [String: CitationFirewallEntryVerdict]
    ) -> LSPHoverCard {
        let occurrences = workspace.symbolTable.citationsByKey[citeKey] ?? []
        let defLink = locateBibTeXEntryDefinition(
            citeKey: citeKey,
            originSpan: nil,
            bibliographyFiles: bibliographyFiles,
            workspace: workspace,
            sourcesByFile: [:]
        )

        let resolvedEntry = bibByKey[citeKey]
            ?? bibByKey.first(where: { $0.key.lowercased() == citeKey.lowercased() })?.value
        guard let entry = resolvedEntry else {
            let suggestion = closestKey(to: citeKey, among: Array(bibByKey.keys))
            var md: [String] = [
                "> **Error (`CITE404`):** Citation key `\(citeKey)` was not found in the workspace bibliography.",
                "",
                "- **Command:** `\(command)`",
                "- **Occurrences in Manuscript:** \(occurrences.count)"
            ]
            if let sug = suggestion {
                md.append("- **Did you mean:** `\(sug)`?")
            }
            return LSPHoverCard(
                title: citeKey,
                categoryBadge: "Missing Citation (CITE404)",
                markdownBody: md.joined(separator: "\n"),
                firewallClass: nil,
                targetSpan: defLink?.targetSpan,
                expandedPreview: nil
            )
        }

        let (effectiveFirewallClass, effectiveAuditNote) = firewall.resolveEffectiveStatus(
            for: entry,
            inRunVerdictsByKey: inRunVerdictsByKey
        )

        let apaFormatted = cslFormatter.formatEntry(entry, style: .apa7)
        let ieeeFormatted = cslFormatter.formatEntry(entry, style: .ieee, citationNumber: 1)

        var lines: [String] = []
        lines.append("**Firewall Status:** `\(effectiveFirewallClass.badgeTitle)` (`\(effectiveFirewallClass.rawValue)`)")
        if !effectiveFirewallClass.allowsManuscriptInsertion {
            lines.append("> **Citation Firewall (`ERR_UNVERIFIED_CITATION`):** \(effectiveAuditNote)")
        } else if !effectiveAuditNote.isEmpty {
            lines.append("_\(effectiveAuditNote)_")
        }

        lines.append("")
        lines.append("**APA 7th:**")
        lines.append(apaFormatted.bibliographyMarkdown)
        lines.append("")
        lines.append("**IEEE:**")
        lines.append(ieeeFormatted.bibliographyPlainText)

        var identifiers: [String] = []
        if let doi = entry.doi, !doi.isEmpty { identifiers.append("**DOI:** `\(doi)`") }
        if let arxiv = entry.arxivID, !arxiv.isEmpty { identifiers.append("**arXiv:** `\(arxiv)`") }
        if let pmid = entry.pmid, !pmid.isEmpty { identifiers.append("**PMID:** `\(pmid)`") }
        if let url = entry.url, !url.isEmpty, entry.doi == nil { identifiers.append("**URL:** \(url)") }
        if !identifiers.isEmpty {
            lines.append("")
            lines.append(identifiers.joined(separator: " · "))
        }

        let citedSections = Array(Set(occurrences.compactMap(\.enclosingSectionTitle))).sorted()
        lines.append("")
        if citedSections.isEmpty {
            lines.append("**Manuscript Usage:** Cited **\(occurrences.count)** time\(occurrences.count == 1 ? "" : "s") across workspace.")
        } else {
            lines.append("**Manuscript Usage:** Cited **\(occurrences.count)** time\(occurrences.count == 1 ? "" : "s") (in \(citedSections.prefix(4).joined(separator: ", "))).")
        }

        if clusterKeys.count > 1 {
            let siblingPreview = clusterKeys.map { "`\($0)`" }.joined(separator: ", ")
            lines.append("**Cluster (\(clusterKeys.count) keys):** \(siblingPreview)")
        }

        let yr = entry.year.map(String.init) ?? "n.d."
        return LSPHoverCard(
            title: "\(entry.firstAuthorFamily) (\(yr)) — \(citeKey)",
            categoryBadge: effectiveFirewallClass.badgeTitle,
            markdownBody: lines.joined(separator: "\n"),
            firewallClass: effectiveFirewallClass,
            targetSpan: defLink?.targetSpan,
            expandedPreview: apaFormatted.inTextParenthetical
        )
    }

    private func buildLabelOrRefHoverCard(
        key: String,
        invokedVia command: String,
        workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String]
    ) -> LSPHoverCard {
        let incomingRefs = workspace.symbolTable.crossReferences.filter { $0.targetKey == key }

        guard let labelRecord = workspace.symbolTable.labelsByKey[key] else {
            let suggestion = closestKey(to: key, among: Array(workspace.symbolTable.labelsByKey.keys))
            var md: [String] = [
                "> **Unresolved Cross-Reference (`SYM004`):** No `\\label{\(key)}` or `<\(key)>` declaration found in workspace.",
                "",
                "- **Command:** `\(command)`",
                "- **Reference Attempts:** \(incomingRefs.count)"
            ]
            if let sug = suggestion {
                md.append("- **Suggested Label:** `\(sug)`")
            }
            return LSPHoverCard(
                title: key,
                categoryBadge: "Unresolved Label",
                markdownBody: md.joined(separator: "\n"),
                firewallClass: nil,
                targetSpan: nil,
                expandedPreview: nil
            )
        }

        var md: [String] = []
        md.append("**Target:** `\(labelRecord.filePath):\(labelRecord.span.start.line)`")

        // Check outline entry if this is a section label
        if let outlineMatch = workspace.outline.first(where: { $0.label == key || ($0.filePath == labelRecord.filePath && abs($0.line - labelRecord.span.start.line) <= 2 && labelRecord.category == .section) }) {
            let numStr = outlineMatch.numberPrefix.isEmpty ? "" : "\(outlineMatch.numberPrefix) "
            md.append("**Section:** \(numStr)\(outlineMatch.title) _(\(outlineMatch.wordCountInSection) words)_")
        }

        // Check environment symbol record (`Figure 1`, `Table 2`, etc.)
        if let envRec = workspace.symbolTable.environments.first(where: { $0.label == key }) {
            let ordStr = envRec.ordinalNumber.map { " #\($0)" } ?? ""
            md.append("**Environment:** `\(envRec.name)`\(ordStr)")
            if let cap = envRec.caption, !cap.isEmpty {
                md.append("")
                md.append("> \(cap)")
            }
        } else if let capOrTitle = labelRecord.enclosingTitleOrCaption, !capOrTitle.isEmpty {
            md.append("")
            md.append("> \(capOrTitle)")
        }

        // Check if label belongs to a `.mathExpression` node to render formula + Unicode math approximation!
        var formulaUnicodePreview: String? = nil
        if let targetParse = workspace.perFileParseResults[labelRecord.filePath] {
            if let mathNode = targetParse.root.allMathExpressions.first(where: {
                if case .mathExpression(_, _, let lbl) = $0.kind, lbl == key { return true }
                return spanContains($0.span, position: labelRecord.span.start)
            }), let mathPrev = macroEngine.previewMathExpression(mathNode, using: workspace.symbolTable, format: targetParse.format) {
                formulaUnicodePreview = mathPrev.unicodeApproximation
                md.append("")
                md.append("**Equation Source:**")
                md.append("```latex\n\(mathPrev.originalFormula)\n```")
                if mathPrev.expandedFormula != mathPrev.originalFormula {
                    md.append("**Expanded Formula:** `\(mathPrev.expandedFormula)`")
                }
                md.append("**Unicode Preview:** `\(mathPrev.unicodeApproximation)`")
            }
        }

        if formulaUnicodePreview == nil {
            let linePreview = extractLineExcerpt(at: labelRecord.span, workspace: workspace, sourcesByFile: sourcesByFile)
            if !linePreview.isEmpty {
                md.append("")
                md.append("**Source Excerpt:** `\(linePreview)`")
            }
        }

        md.append("")
        md.append("_Referenced **\(incomingRefs.count)** time\(incomingRefs.count == 1 ? "" : "s") across manuscript._")

        return LSPHoverCard(
            title: "\(labelRecord.category.rawValue): \(key)",
            categoryBadge: labelRecord.category.rawValue,
            markdownBody: md.joined(separator: "\n"),
            firewallClass: nil,
            targetSpan: labelRecord.span,
            expandedPreview: formulaUnicodePreview ?? labelRecord.enclosingTitleOrCaption
        )
    }

    private func buildMacroHoverCard(
        macro: MacroDefinitionRecord,
        callSnippet: String?,
        format: ManuscriptFormat,
        workspace: MergedManuscriptWorkspaceAST
    ) -> LSPHoverCard {
        let expansionTarget = callSnippet ?? macro.replacementBody
        let expansionResult = macroEngine.expand(
            text: expansionTarget,
            using: workspace.symbolTable,
            format: format
        )
        let syntheticMathNode = MarkupASTNode(
            kind: .mathExpression(isDisplayMode: false, formulaSource: expansionTarget, label: nil),
            span: macro.span
        )
        let mathPreview = macroEngine.previewMathExpression(
            syntheticMathNode,
            using: workspace.symbolTable,
            format: format
        )
        let unicodeText = mathPreview?.unicodeApproximation ?? expansionResult.expandedSource

        var md: [String] = []
        md.append("**Signature:** `\(macro.signatureDisplay)`")
        md.append("**Declared at:** `\(macro.filePath):\(macro.span.start.line)` (`\(macro.originKind.rawValue)`)")
        if let doc = macro.documentationComment, !doc.isEmpty {
            md.append("")
            md.append("_\(doc)_")
        }
        md.append("")
        md.append("**Replacement Template:**")
        md.append("```latex\n\(macro.replacementBody)\n```")

        if let call = callSnippet {
            md.append("**Live Call Expansion (`\(call)`):**")
            md.append("```latex\n\(expansionResult.expandedSource)\n```")
        }
        if !unicodeText.isEmpty && unicodeText != macro.replacementBody {
            md.append("**Unicode Math Approximation:** `\(unicodeText)`")
        }
        if !expansionResult.issues.isEmpty {
            for issue in expansionResult.issues {
                md.append("> **Warning:** \(issue.message)")
            }
        }

        return LSPHoverCard(
            title: macro.signatureDisplay,
            categoryBadge: "User Macro",
            markdownBody: md.joined(separator: "\n"),
            firewallClass: nil,
            targetSpan: macro.span,
            expandedPreview: unicodeText.isEmpty ? expansionResult.expandedSource : unicodeText
        )
    }

    private func buildMathExpressionHoverCard(
        node: MarkupASTNode,
        format: ManuscriptFormat,
        workspace: MergedManuscriptWorkspaceAST
    ) -> LSPHoverCard? {
        guard let preview = macroEngine.previewMathExpression(node, using: workspace.symbolTable, format: format) else {
            return nil
        }
        var md: [String] = []
        if let lbl = preview.label {
            md.append("**Equation Label:** `\(lbl)`")
        }
        md.append("**Unicode Preview:**")
        md.append("`\(preview.unicodeApproximation)`")
        if preview.expandedFormula != preview.originalFormula {
            md.append("")
            md.append("**Macro-Expanded TeX:**")
            md.append("```latex\n\(preview.expandedFormula)\n```")
        }
        if !preview.referencedMacros.isEmpty {
            md.append("")
            md.append("**Macros Applied:** \(preview.referencedMacros.map { "`\($0)`" }.joined(separator: ", "))")
        }

        return LSPHoverCard(
            title: preview.isDisplayMode ? "Display Math Expression" : "Inline Math Expression",
            categoryBadge: preview.isDisplayMode ? "Display Math" : "Inline Math",
            markdownBody: md.joined(separator: "\n"),
            firewallClass: nil,
            targetSpan: node.span,
            expandedPreview: preview.unicodeApproximation
        )
    }

    private func buildFileIncludeHoverCard(
        edge: IncludeGraphEdge,
        workspace: MergedManuscriptWorkspaceAST
    ) -> LSPHoverCard {
        var md: [String] = []
        md.append("**Directive:** `\(edge.kind.rawValue)`")
        md.append("**Resolved Path:** `\(edge.resolvedTargetFile)`")
        md.append("**Status:** \(edge.targetExists ? "Resolved in workspace" : "Missing file (`INC002`)")")

        if let childParse = workspace.perFileParseResults[edge.resolvedTargetFile] {
            let sectionCount = childParse.root.allSections.count
            let citeCount = childParse.root.allCitations.count
            let eqCount = childParse.root.allMathExpressions.count
            md.append("")
            md.append("- **Sections:** \(sectionCount) · **Citations:** \(citeCount) · **Math Blocks:** \(eqCount)")
        }

        let targetSpan = edge.targetExists
            ? TextSpan(filePath: edge.resolvedTargetFile, start: .startOfFile, end: .startOfFile)
            : nil
        return LSPHoverCard(
            title: edge.resolvedTargetFile,
            categoryBadge: edge.isBibliographyResource ? "Bibliography File" : "Included Manuscript",
            markdownBody: md.joined(separator: "\n"),
            firewallClass: nil,
            targetSpan: targetSpan,
            expandedPreview: nil
        )
    }

    private func buildEnvironmentHoverCard(envName: String, span: TextSpan) -> LSPHoverCard? {
        guard let tmpl = AcademicCompletionEngine.builtinEnvironments.first(where: { $0.realLatexEnvironmentTag == envName || $0.name == envName }) else {
            return LSPHoverCard(
                title: "\\begin{\(envName)}",
                categoryBadge: "LaTeX Environment",
                markdownBody: "LaTeX environment `\(envName)`.",
                targetSpan: span
            )
        }
        var md: [String] = [tmpl.summary]
        if let pkg = tmpl.packageRequirement {
            md.append("**Package:** `\\usepackage{\(pkg)}`")
        }
        return LSPHoverCard(
            title: "\\begin{\(tmpl.realLatexEnvironmentTag)}",
            categoryBadge: tmpl.groupCategory,
            markdownBody: md.joined(separator: "\n\n"),
            targetSpan: span
        )
    }

    private func buildBuiltinCommandHoverCard(
        command: String,
        span: TextSpan,
        format: ManuscriptFormat
    ) -> LSPHoverCard? {
        guard let entry = AcademicCompletionEngine.builtinCommandsAndSymbols.first(where: { $0.format == format && $0.trigger == command })
            ?? AcademicCompletionEngine.builtinCommandsAndSymbols.first(where: { $0.trigger == command }) else {
            return nil
        }
        var md: [String] = [entry.summary]
        if let uni = entry.unicodePreview {
            md.append("**Symbol:** `\(uni)`")
        }
        if let pkg = entry.packageHint {
            md.append("**Package:** `\(pkg)`")
        }
        return LSPHoverCard(
            title: entry.trigger,
            categoryBadge: entry.category.rawValue,
            markdownBody: md.joined(separator: "\n\n"),
            targetSpan: span,
            expandedPreview: entry.unicodePreview
        )
    }

    // MARK: - Token-Stream Pinpoint Symbol Scanner

    private static var citeCommandSet: Set<String> { LaTeXCommandRole.allCitationCommands }

    private static var refCommandSet: Set<String> { LaTeXCommandRole.allCrossReferenceCommands }

    private func resolveFromTokenStream(
        tokens: [MarkupToken],
        format: ManuscriptFormat,
        filePath: String,
        source: String,
        lineIndex: LineByteIndex,
        cursor: TextPosition,
        symbolTable: ManuscriptSymbolTable,
        bibliographyKeys: Set<String>
    ) -> ResolvedCursorSymbol? {
        let count = tokens.count
        var i = 0

        while i < count {
            let tok = tokens[i]

            // 1. LaTeX commands (`\cite`, `\ref`, `\label`, `\begin`, `\end`, or user macro `\mycmd`)
            if tok.kind == .command {
                let cmd = tok.lexeme

                if Self.citeCommandSet.contains(cmd) {
                    if let (braceStartByte, braceEndByte, innerContent, fullEndPos) = consumeCommandBraceGroup(tokens: tokens, commandIndex: i, allowOptionalBrackets: true) {
                        let fullSpan = TextSpan(filePath: filePath, start: tok.span.start, end: fullEndPos)
                        if spanContains(fullSpan, position: cursor) {
                            let splitItems = splitCommaSeparatedSpans(
                                innerContent: innerContent,
                                contentStartUTF8: braceStartByte + 1,
                                filePath: filePath,
                                source: source,
                                lineIndex: lineIndex
                            )
                            let allKeys = splitItems.map(\.key)
                            if let hoveredItem = splitItems.first(where: { spanContains($0.span, position: cursor) }) ?? splitItems.first {
                                _ = braceEndByte
                                return .citation(
                                    citeKey: hoveredItem.key,
                                    command: cmd,
                                    keySpan: hoveredItem.span,
                                    directiveSpan: fullSpan,
                                    clusterKeys: allKeys
                                )
                            }
                        }
                    }
                } else if Self.refCommandSet.contains(cmd) {
                    if let (braceStartByte, _, innerContent, fullEndPos) = consumeCommandBraceGroup(tokens: tokens, commandIndex: i, allowOptionalBrackets: true) {
                        let fullSpan = TextSpan(filePath: filePath, start: tok.span.start, end: fullEndPos)
                        if spanContains(fullSpan, position: cursor) {
                            let splitItems = splitCommaSeparatedSpans(
                                innerContent: innerContent,
                                contentStartUTF8: braceStartByte + 1,
                                filePath: filePath,
                                source: source,
                                lineIndex: lineIndex
                            )
                            if let hoveredItem = splitItems.first(where: { spanContains($0.span, position: cursor) }) ?? splitItems.first {
                                return .crossReference(
                                    targetKey: hoveredItem.key,
                                    command: cmd,
                                    keySpan: hoveredItem.span,
                                    directiveSpan: fullSpan
                                )
                            }
                        }
                    }
                } else if cmd == "\\label" {
                    if let (braceStartByte, _, innerContent, fullEndPos) = consumeCommandBraceGroup(tokens: tokens, commandIndex: i, allowOptionalBrackets: false) {
                        let fullSpan = TextSpan(filePath: filePath, start: tok.span.start, end: fullEndPos)
                        if spanContains(fullSpan, position: cursor) {
                            let trimmed = innerContent.trimmingCharacters(in: .whitespacesAndNewlines)
                            let leadCount = innerContent.prefix(while: { $0.isWhitespace }).utf8.count
                            let kStart = lineIndex.position(forUTF8Offset: braceStartByte + 1 + leadCount, in: source)
                            let kEnd = lineIndex.position(forUTF8Offset: braceStartByte + 1 + leadCount + trimmed.utf8.count, in: source)
                            if !trimmed.isEmpty {
                                return .labelDeclaration(
                                    key: trimmed,
                                    keySpan: TextSpan(filePath: filePath, start: kStart, end: kEnd),
                                    directiveSpan: fullSpan
                                )
                            }
                        }
                    }
                } else if cmd == "\\begin" || cmd == "\\end" {
                    if let (_, _, innerContent, fullEndPos) = consumeCommandBraceGroup(tokens: tokens, commandIndex: i, allowOptionalBrackets: false) {
                        let fullSpan = TextSpan(filePath: filePath, start: tok.span.start, end: fullEndPos)
                        if spanContains(fullSpan, position: cursor) {
                            let envName = innerContent.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !envName.isEmpty {
                                return .environmentTag(name: envName, span: fullSpan)
                            }
                        }
                    }
                } else if let macro = symbolTable.macrosByName[cmd] {
                    // User macro invocation `\mycmd[opt]{arg1}{arg2}`
                    let (callSnippet, callEndPos) = consumeLatexMacroCall(tokens: tokens, startIndex: i, macro: macro)
                    let callSpan = TextSpan(filePath: filePath, start: tok.span.start, end: callEndPos)
                    // Check if cursor is directly on `\mycmd` token (or within its arguments if no inner `\ref`/`\cite` matched)
                    if spanContains(tok.span, position: cursor) {
                        return .userMacroCall(macro: macro, callSnippet: callSnippet, callSpan: callSpan)
                    }
                }
            }

            // 2. Typst `#cite(<key>)`, `#ref(<lbl>)`, `@key`, `<label>`, and `#usermacro(...)`
            if format == .typst {
                if tok.kind == .typstHashKeyword {
                    if tok.lexeme.hasPrefix("@") && tok.lexeme.count > 1 && spanContains(tok.span, position: cursor) {
                        let key = String(tok.lexeme.dropFirst())
                        let keyStart = lineIndex.position(forUTF8Offset: tok.span.start.utf8Offset + 1, in: source)
                        let keySpan = TextSpan(filePath: filePath, start: keyStart, end: tok.span.end)
                        if symbolTable.labelsByKey[key] != nil || (!bibliographyKeys.contains(key) && isLikelyStructuralLabelKey(key)) {
                            return .crossReference(targetKey: key, command: "@", keySpan: keySpan, directiveSpan: tok.span)
                        } else {
                            return .citation(citeKey: key, command: "@", keySpan: keySpan, directiveSpan: tok.span, clusterKeys: [key])
                        }
                    }

                    if (tok.lexeme == "#cite" || tok.lexeme == "#ref"),
                       let (innerKey, innerSpan, fullSpan) = consumeTypstAngleOrLabelCall(tokens: tokens, startIndex: i, filePath: filePath, source: source, lineIndex: lineIndex),
                       spanContains(fullSpan, position: cursor) {
                        if tok.lexeme == "#cite" {
                            return .citation(citeKey: innerKey, command: "#cite", keySpan: innerSpan, directiveSpan: fullSpan, clusterKeys: [innerKey])
                        } else {
                            return .crossReference(targetKey: innerKey, command: "#ref", keySpan: innerSpan, directiveSpan: fullSpan)
                        }
                    }

                    if tok.lexeme.hasPrefix("#") && tok.lexeme.count > 1 {
                        let bareName = String(tok.lexeme.dropFirst())
                        if let macro = symbolTable.macrosByName[bareName], spanContains(tok.span, position: cursor) {
                            let (callSnippet, endPos) = consumeTypstMacroCall(tokens: tokens, startIndex: i, macro: macro)
                            let callSpan = TextSpan(filePath: filePath, start: tok.span.start, end: endPos)
                            return .userMacroCall(macro: macro, callSnippet: callSnippet, callSpan: callSpan)
                        }
                    }
                } else if tok.kind == .identifier && tok.lexeme.hasPrefix("<") && tok.lexeme.hasSuffix(">") && tok.lexeme.count > 2 {
                    // Standalone Typst `<sec:intro>` label declaration (when NOT inside `#cite(<...>)` or `#ref(<...>)`)
                    if spanContains(tok.span, position: cursor) {
                        let innerKey = String(tok.lexeme.dropFirst().dropLast())
                        let kStart = lineIndex.position(forUTF8Offset: tok.span.start.utf8Offset + 1, in: source)
                        let kEnd = lineIndex.position(forUTF8Offset: tok.span.end.utf8Offset - 1, in: source)
                        return .labelDeclaration(
                            key: innerKey,
                            keySpan: TextSpan(filePath: filePath, start: kStart, end: kEnd),
                            directiveSpan: tok.span
                        )
                    }
                }
            }

            i += 1
        }

        return nil
    }

    // MARK: - Reference Collection Helpers

    private func collectAllLabelReferences(
        key: String,
        originSpan: TextSpan?,
        workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String],
        includeDeclaration: Bool
    ) -> [LSPLocationLink] {
        var links: [LSPLocationLink] = []
        if includeDeclaration {
            for decl in workspace.symbolTable.allLabelDeclarations where decl.key == key {
                links.append(
                    LSPLocationLink(
                        originSpan: originSpan,
                        targetSpan: decl.span,
                        previewExcerpt: extractLineExcerpt(at: decl.span, workspace: workspace, sourcesByFile: sourcesByFile),
                        role: .declaration
                    )
                )
            }
        }
        for ref in workspace.symbolTable.crossReferences where ref.targetKey == key {
            links.append(
                LSPLocationLink(
                    originSpan: originSpan,
                    targetSpan: ref.span,
                    previewExcerpt: extractLineExcerpt(at: ref.span, workspace: workspace, sourcesByFile: sourcesByFile),
                    role: .reference
                )
            )
        }
        return sortLocationLinks(links)
    }

    private func collectAllCitationReferences(
        citeKey: String,
        originSpan: TextSpan?,
        workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String],
        bibliographyFiles: [String: String],
        includeDeclaration: Bool
    ) -> [LSPLocationLink] {
        var links: [LSPLocationLink] = []
        if includeDeclaration,
           let bibDef = locateBibTeXEntryDefinition(
            citeKey: citeKey,
            originSpan: originSpan,
            bibliographyFiles: bibliographyFiles,
            workspace: workspace,
            sourcesByFile: sourcesByFile
           ) {
            links.append(bibDef)
        }
        for occ in workspace.symbolTable.citationsByKey[citeKey] ?? [] {
            links.append(
                LSPLocationLink(
                    originSpan: originSpan,
                    targetSpan: occ.span,
                    previewExcerpt: extractLineExcerpt(at: occ.span, workspace: workspace, sourcesByFile: sourcesByFile),
                    role: .citationOccurrence
                )
            )
        }
        return sortLocationLinks(links)
    }

    private func collectAllMacroReferences(
        macro: MacroDefinitionRecord,
        originSpan: TextSpan?,
        workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String],
        includeDeclaration: Bool
    ) -> [LSPLocationLink] {
        var links: [LSPLocationLink] = []
        if includeDeclaration {
            links.append(
                LSPLocationLink(
                    originSpan: originSpan,
                    targetSpan: macro.span,
                    previewExcerpt: extractLineExcerpt(at: macro.span, workspace: workspace, sourcesByFile: sourcesByFile),
                    role: .declaration
                )
            )
        }

        let isTypstMacro = (macro.originKind == .typstLetBinding)
        let targetLexeme = isTypstMacro ? "#\(macro.name)" : macro.name

        for filePath in workspace.includeGraph.documentReadingOrder {
            guard let pr = workspace.perFileParseResults[filePath] else { continue }
            for tok in pr.tokens {
                // Skip tokens inside the macro's own declaration header!
                if filePath == macro.filePath && spanOverlaps(tok.span, macro.span) {
                    continue
                }
                if !isTypstMacro && tok.kind == .command && tok.lexeme == targetLexeme {
                    links.append(
                        LSPLocationLink(
                            originSpan: originSpan,
                            targetSpan: tok.span,
                            previewExcerpt: extractLineExcerpt(at: tok.span, workspace: workspace, sourcesByFile: sourcesByFile),
                            role: .macroCall
                        )
                    )
                } else if isTypstMacro {
                    if (tok.kind == .typstHashKeyword && tok.lexeme == targetLexeme)
                        || ((tok.kind == .identifier || tok.kind == .textWord) && tok.lexeme == macro.name) {
                        links.append(
                            LSPLocationLink(
                                originSpan: originSpan,
                                targetSpan: tok.span,
                                previewExcerpt: extractLineExcerpt(at: tok.span, workspace: workspace, sourcesByFile: sourcesByFile),
                                role: .macroCall
                            )
                        )
                    }
                }
            }
        }
        return sortLocationLinks(links)
    }

    // MARK: - BibTeX Entry Span Locator & Structural Token Scanners

    public func locateBibTeXEntryDefinition(
        citeKey: String,
        originSpan: TextSpan?,
        bibliographyFiles: [String: String],
        workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String]
    ) -> LSPLocationLink? {
        var candidateBibSources: [(String, String)] = bibliographyFiles.sorted { $0.key < $1.key }
        for bibPath in workspace.includeGraph.bibliographyFiles where bibliographyFiles[bibPath] == nil {
            if let s = sourcesByFile[bibPath] {
                candidateBibSources.append((bibPath, s))
            }
        }

        for (bibPath, bibText) in candidateBibSources {
            let idx = LineByteIndex(source: bibText)
            let bytes = Array(bibText.utf8)
            var i = 0
            while i < bytes.count {
                if bytes[i] == 0x40 { // '@'
                    let entryStart = i
                    i += 1
                    while i < bytes.count && bytes[i].isBibASCIILetter { i += 1 }
                    while i < bytes.count && (bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D) { i += 1 }
                    if i < bytes.count && (bytes[i] == 0x7B || bytes[i] == 0x28) { // '{' or '('
                        i += 1
                        while i < bytes.count && (bytes[i] == 0x20 || bytes[i] == 0x09) { i += 1 }
                        let keyStart = i
                        while i < bytes.count && bytes[i] != 0x2C && bytes[i] != 0x7D && bytes[i] != 0x0A && bytes[i] != 0x20 {
                            i += 1
                        }
                        let foundKey = String(decoding: bytes[keyStart..<i], as: UTF8.self)
                        if foundKey == citeKey || foundKey.lowercased() == citeKey.lowercased() {
                            let startPos = idx.position(forUTF8Offset: entryStart, in: bibText)
                            let endPos = idx.position(forUTF8Offset: i, in: bibText)
                            let lineEnd = idx.endUTF8Offset(ofLine: startPos.line)
                            let excerpt = String(decoding: bytes[entryStart..<min(bytes.count, lineEnd)], as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            return LSPLocationLink(
                                originSpan: originSpan,
                                targetSpan: TextSpan(filePath: bibPath, start: startPos, end: endPos),
                                previewExcerpt: excerpt,
                                role: .definition
                            )
                        }
                    }
                }
                i += 1
            }
        }
        return nil
    }

    private func consumeCommandBraceGroup(
        tokens: [MarkupToken],
        commandIndex: Int,
        allowOptionalBrackets: Bool
    ) -> (braceStartByte: Int, braceEndByte: Int, innerContent: String, fullEndPos: TextPosition)? {
        var j = commandIndex + 1
        let count = tokens.count

        while j < count {
            let t = tokens[j]
            if t.kind == .whitespace || t.kind == .comment {
                j += 1
                continue
            }
            if allowOptionalBrackets && t.kind == .leftBracket {
                var bDepth = 1
                j += 1
                while j < count && bDepth > 0 {
                    if tokens[j].kind == .leftBracket { bDepth += 1 }
                    else if tokens[j].kind == .rightBracket { bDepth -= 1 }
                    j += 1
                }
                continue
            }
            break
        }

        guard j < count, tokens[j].kind == .leftBrace else { return nil }
        let braceOpenToken = tokens[j]
        j += 1
        var depth = 1
        var parts: [String] = []
        var endToken = braceOpenToken

        while j < count && depth > 0 {
            let t = tokens[j]
            endToken = t
            if t.kind == .leftBrace {
                depth += 1
                parts.append(t.lexeme)
            } else if t.kind == .rightBrace {
                depth -= 1
                if depth > 0 {
                    parts.append(t.lexeme)
                }
            } else if t.kind != .eof {
                parts.append(t.lexeme)
            }
            j += 1
        }
        return (braceOpenToken.span.start.utf8Offset, endToken.span.end.utf8Offset, parts.joined(), endToken.span.end)
    }

    private func splitCommaSeparatedSpans(
        innerContent: String,
        contentStartUTF8: Int,
        filePath: String,
        source: String,
        lineIndex: LineByteIndex
    ) -> [(key: String, span: TextSpan)] {
        var results: [(String, TextSpan)] = []
        let segments = innerContent.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var runningUTF8 = contentStartUTF8

        for (segIdx, seg) in segments.enumerated() {
            let leadBytes = seg.prefix(while: { $0.isWhitespace }).utf8.count
            let trimmed = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = LaTeXKeyNormalizer.normalize(trimmed)
            if !normalized.isEmpty {
                let kStartByte = runningUTF8 + leadBytes
                let kEndByte = kStartByte + trimmed.utf8.count
                let startPos = lineIndex.position(forUTF8Offset: kStartByte, in: source)
                let endPos = lineIndex.position(forUTF8Offset: kEndByte, in: source)
                results.append((normalized, TextSpan(filePath: filePath, start: startPos, end: endPos)))
            }
            runningUTF8 += seg.utf8.count
            if segIdx + 1 < segments.count {
                runningUTF8 += 1 // ','
            }
        }
        return results
    }

    private func consumeLatexMacroCall(
        tokens: [MarkupToken],
        startIndex: Int,
        macro: MacroDefinitionRecord
    ) -> (String, TextPosition) {
        var parts: [String] = [tokens[startIndex].lexeme]
        var endPos = tokens[startIndex].span.end
        guard macro.parameterCount > 0 else {
            return (parts.joined(), endPos)
        }

        var idx = startIndex + 1
        let count = tokens.count
        var remaining = macro.mandatoryParameterCount

        // Optional `[...]` argument if `defaultOptionalArgument != nil`
        while idx < count && tokens[idx].kind == .whitespace && !tokens[idx].lexeme.contains("\n") {
            parts.append(tokens[idx].lexeme)
            idx += 1
        }
        if macro.defaultOptionalArgument != nil, idx < count, tokens[idx].kind == .leftBracket {
            var bDepth = 1
            parts.append(tokens[idx].lexeme)
            endPos = tokens[idx].span.end
            idx += 1
            while idx < count && bDepth > 0 {
                let t = tokens[idx]
                parts.append(t.lexeme)
                endPos = t.span.end
                if t.kind == .leftBracket { bDepth += 1 }
                else if t.kind == .rightBracket { bDepth -= 1 }
                idx += 1
            }
        }

        while remaining > 0 && idx < count {
            while idx < count && tokens[idx].kind == .whitespace && !tokens[idx].lexeme.contains("\n") {
                parts.append(tokens[idx].lexeme)
                idx += 1
            }
            guard idx < count, tokens[idx].kind == .leftBrace else { break }
            var depth = 1
            parts.append(tokens[idx].lexeme)
            endPos = tokens[idx].span.end
            idx += 1
            while idx < count && depth > 0 {
                let t = tokens[idx]
                parts.append(t.lexeme)
                endPos = t.span.end
                if t.kind == .leftBrace { depth += 1 }
                else if t.kind == .rightBrace { depth -= 1 }
                idx += 1
            }
            remaining -= 1
        }

        return (parts.joined(), endPos)
    }

    private func consumeTypstAngleOrLabelCall(
        tokens: [MarkupToken],
        startIndex: Int,
        filePath: String,
        source: String,
        lineIndex: LineByteIndex
    ) -> (key: String, keySpan: TextSpan, fullSpan: TextSpan)? {
        let head = tokens[startIndex]
        var j = startIndex + 1
        let count = tokens.count
        guard j < count, tokens[j].kind == .punctuation, tokens[j].lexeme == "(" else { return nil }
        j += 1
        var depth = 1
        var foundKey: String? = nil
        var foundKeySpan: TextSpan? = nil
        var endPos = head.span.end

        while j < count && depth > 0 {
            let t = tokens[j]
            endPos = t.span.end
            if t.kind == .punctuation && t.lexeme == "(" {
                depth += 1
            } else if t.kind == .punctuation && t.lexeme == ")" {
                depth -= 1
            } else if foundKey == nil && t.kind == .identifier && t.lexeme.hasPrefix("<") && t.lexeme.hasSuffix(">") && t.lexeme.count > 2 {
                let inner = String(t.lexeme.dropFirst().dropLast())
                let s = lineIndex.position(forUTF8Offset: t.span.start.utf8Offset + 1, in: source)
                let e = lineIndex.position(forUTF8Offset: t.span.end.utf8Offset - 1, in: source)
                foundKey = inner
                foundKeySpan = TextSpan(filePath: filePath, start: s, end: e)
            } else if foundKey == nil && t.kind == .identifier && t.lexeme.hasPrefix("\"") && t.lexeme.hasSuffix("\"") && t.lexeme.count > 2 {
                let inner = String(t.lexeme.dropFirst().dropLast())
                let s = lineIndex.position(forUTF8Offset: t.span.start.utf8Offset + 1, in: source)
                let e = lineIndex.position(forUTF8Offset: t.span.end.utf8Offset - 1, in: source)
                foundKey = inner
                foundKeySpan = TextSpan(filePath: filePath, start: s, end: e)
            }
            j += 1
        }
        guard let k = foundKey, let ks = foundKeySpan else { return nil }
        return (k, ks, TextSpan(filePath: filePath, start: head.span.start, end: endPos))
    }

    private func consumeTypstMacroCall(
        tokens: [MarkupToken],
        startIndex: Int,
        macro: MacroDefinitionRecord
    ) -> (String, TextPosition) {
        var parts = [tokens[startIndex].lexeme]
        var endPos = tokens[startIndex].span.end
        guard macro.parameterCount > 0 else { return (parts.joined(), endPos) }
        var j = startIndex + 1
        guard j < tokens.count, tokens[j].kind == .punctuation, tokens[j].lexeme == "(" else {
            return (parts.joined(), endPos)
        }
        var depth = 1
        parts.append(tokens[j].lexeme)
        endPos = tokens[j].span.end
        j += 1
        while j < tokens.count && depth > 0 {
            let t = tokens[j]
            parts.append(t.lexeme)
            endPos = t.span.end
            if t.kind == .punctuation && t.lexeme == "(" { depth += 1 }
            else if t.kind == .punctuation && t.lexeme == ")" { depth -= 1 }
            j += 1
        }
        return (parts.joined(), endPos)
    }

    private func locateDeclaredMacroNameSpan(decl: MacroDefinitionRecord, tokens: [MarkupToken]) -> TextSpan? {
        for tok in tokens where spanOverlaps(tok.span, decl.span) {
            if decl.originKind == .typstLetBinding {
                if (tok.kind == .identifier || tok.kind == .textWord) && tok.lexeme == decl.name {
                    return tok.span
                }
            } else {
                if tok.kind == .command && tok.lexeme == decl.name {
                    return tok.span
                }
            }
        }
        return decl.span
    }

    private func innermostMathNode(in root: MarkupASTNode, at cursor: TextPosition) -> MarkupASTNode? {
        var best: MarkupASTNode? = nil
        func walk(_ node: MarkupASTNode) {
            guard spanContains(node.span, position: cursor) else { return }
            if case .mathExpression = node.kind {
                best = node
            }
            for child in node.children {
                walk(child)
            }
        }
        walk(root)
        return best
    }

    private func fallbackParse(filePath: String, sourcesByFile: [String: String]) -> MarkupParseResult? {
        guard let src = sourcesByFile[filePath] else { return nil }
        return HandwrittenMarkupCSTParser().parse(source: src, filePath: filePath)
    }

    private func extractLineExcerpt(
        at span: TextSpan,
        workspace: MergedManuscriptWorkspaceAST,
        sourcesByFile: [String: String]
    ) -> String {
        let source: String
        if let s = sourcesByFile[span.filePath] {
            source = s
        } else if let pr = workspace.perFileParseResults[span.filePath] {
            source = pr.tokens.map(\.lexeme).joined()
        } else {
            return ""
        }
        let idx = LineByteIndex(source: source)
        let startByte = idx.startUTF8Offset(ofLine: span.start.line)
        let endByte = idx.endUTF8Offset(ofLine: span.start.line)
        let bytes = Array(source.utf8)
        guard startByte >= 0, endByte <= bytes.count, startByte <= endByte else { return "" }
        return String(decoding: bytes[startByte..<endByte], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isLikelyStructuralLabelKey(_ key: String) -> Bool {
        LabelCategory.infer(fromKey: key) != .general
    }

    private func spanContains(_ span: TextSpan, position: TextPosition) -> Bool {
        if span.start.utf8Offset > 0 || span.end.utf8Offset > 0 {
            return position.utf8Offset >= span.start.utf8Offset && position.utf8Offset <= span.end.utf8Offset
        }
        return position >= span.start && position <= span.end
    }

    private func spanOverlaps(_ a: TextSpan, _ b: TextSpan) -> Bool {
        a.start.utf8Offset < b.end.utf8Offset && b.start.utf8Offset < a.end.utf8Offset
    }

    private func sortLocationLinks(_ links: [LSPLocationLink]) -> [LSPLocationLink] {
        var seen = Set<String>()
        var unique: [LSPLocationLink] = []
        for link in links {
            let key = "\(link.role.rawValue)|\(link.targetSpan.filePath)|\(link.targetSpan.start.line)|\(link.targetSpan.start.column)"
            if seen.insert(key).inserted {
                unique.append(link)
            }
        }
        return unique.sorted { lhs, rhs in
            if lhs.role == .declaration && rhs.role != .declaration { return true }
            if rhs.role == .declaration && lhs.role != .declaration { return false }
            if lhs.role == .definition && rhs.role != .definition { return true }
            if rhs.role == .definition && lhs.role != .definition { return false }
            if lhs.targetSpan.filePath != rhs.targetSpan.filePath {
                return lhs.targetSpan.filePath < rhs.targetSpan.filePath
            }
            return lhs.targetSpan.start < rhs.targetSpan.start
        }
    }

    private func closestKey(to target: String, among candidates: [String]) -> String? {
        guard !target.isEmpty, !candidates.isEmpty else { return nil }
        var best: String? = nil
        var bestDist = Int.max
        for cand in candidates {
            let d = editDistance(target.lowercased(), cand.lowercased())
            if d < bestDist && d <= 4 {
                bestDist = d
                best = cand
            }
        }
        return best
    }

    private func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = (aChars[i - 1] == bChars[j - 1]) ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }
}

private extension UInt8 {
    var isBibASCIILetter: Bool {
        (self >= 0x41 && self <= 0x5A) || (self >= 0x61 && self <= 0x7A)
    }
}
