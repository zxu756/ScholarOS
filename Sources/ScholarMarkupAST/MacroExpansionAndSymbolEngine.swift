import Foundation
import ScholarModels

// MARK: - Macro Definition Records & Origin Taxonomy

/// Identifies the declaration construct that introduced a macro or custom operator.
public enum MacroOriginKind: String, Sendable, Codable, Hashable, CaseIterable {
    case latexNewCommand = "newcommand"
    case latexRenewCommand = "renewcommand"
    case latexProvideCommand = "providecommand"
    case latexDeclareRobustCommand = "DeclareRobustCommand"
    case latexNewDocumentCommand = "NewDocumentCommand"
    case latexTeXDef = "def"
    case latexDeclareMathOperator = "DeclareMathOperator"
    case typstLetBinding = "typstLet"
    case builtInStandard = "builtIn"
}

/// Complete cross-file metadata for a LaTeX or Typst user-defined macro.
public struct MacroDefinitionRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(filePath):\(name):\(span.start.line):\(span.start.column)" }
    /// Canonical command or identifier name (e.g. `\R`, `\argmin`, or `norm` in Typst).
    public let name: String
    public let originKind: MacroOriginKind
    /// Total formal parameter count (`0...9` in LaTeX, `0...N` in Typst).
    public let parameterCount: Int
    /// Optional default value for `#1` when declared as `\newcommand{\R}[1][\mathbb{R}]{#1^n}`.
    public let defaultOptionalArgument: String?
    /// Formal parameter names (`["#1", "#2"]` in LaTeX or `["x", "y"]` in Typst `#let f(x, y) = ...`).
    public let parameterNames: [String]
    /// Raw macro body prior to expansion.
    public let replacementBody: String
    /// True when declared via `\DeclareMathOperator*` (limits placed above/below in display mode).
    public let isStarredMathOperator: Bool
    public let filePath: String
    public let span: TextSpan
    public let documentationComment: String?

    public init(
        name: String,
        originKind: MacroOriginKind = .latexNewCommand,
        parameterCount: Int = 0,
        defaultOptionalArgument: String? = nil,
        parameterNames: [String]? = nil,
        replacementBody: String,
        isStarredMathOperator: Bool = false,
        filePath: String = "main.tex",
        span: TextSpan,
        documentationComment: String? = nil
    ) {
        self.name = name
        self.originKind = originKind
        self.parameterCount = max(0, parameterCount)
        self.defaultOptionalArgument = defaultOptionalArgument
        if let explicitNames = parameterNames {
            self.parameterNames = explicitNames
        } else if parameterCount > 0 {
            self.parameterNames = (1...parameterCount).map { "#\($0)" }
        } else {
            self.parameterNames = []
        }
        self.replacementBody = replacementBody
        self.isStarredMathOperator = isStarredMathOperator
        self.filePath = filePath
        self.span = span
        self.documentationComment = documentationComment
    }

    /// Number of mandatory `{...}` arguments required at the call site when optional `#1` is omitted.
    public var mandatoryParameterCount: Int {
        if defaultOptionalArgument != nil && parameterCount >= 1 {
            return parameterCount - 1
        }
        return parameterCount
    }

    /// Human-readable signature suitable for LSP hover & completion subtitles (e.g. `\R[opt=\mathbb{R}]` or `\inner{#1}{#2}`).
    public var signatureDisplay: String {
        if originKind == .typstLetBinding {
            if parameterNames.isEmpty {
                return "#let \(name)"
            }
            return "#let \(name)(\(parameterNames.joined(separator: ", ")))"
        }
        guard parameterCount > 0 else { return name }
        var sig = name
        var startIdx = 1
        if let defVal = defaultOptionalArgument {
            sig += "[#1=\(defVal)]"
            startIdx = 2
        }
        if startIdx <= parameterCount {
            for idx in startIdx...parameterCount {
                sig += "{#\(idx)}"
            }
        }
        return sig
    }
}

// MARK: - Symbol Table Records (Labels, Citations, Cross-Refs, Environments)

/// Semantic namespace of a `\label{...}` or Typst `<label>` declaration.
public enum LabelCategory: String, Sendable, Codable, Hashable, CaseIterable {
    case section = "Section"
    case appendix = "Appendix"
    case figure = "Figure"
    case table = "Table"
    case equation = "Equation"
    case theorem = "Theorem/Lemma"
    case algorithm = "Algorithm"
    case listing = "Listing"
    case general = "General"

    public static func infer(fromKey key: String, enclosingEnvironment: String? = nil) -> LabelCategory {
        let lower = key.lowercased()
        if lower.hasPrefix("sec:") || lower.hasPrefix("subsec:") || lower.hasPrefix("chap:") || lower.hasPrefix("ch:") || lower.hasPrefix("part:") {
            return .section
        }
        if lower.hasPrefix("app:") || lower.hasPrefix("appendix:") {
            return .appendix
        }
        if lower.hasPrefix("fig:") || lower.hasPrefix("subfig:") {
            return .figure
        }
        if lower.hasPrefix("tab:") || lower.hasPrefix("tbl:") {
            return .table
        }
        if lower.hasPrefix("eq:") || lower.hasPrefix("eqn:") {
            return .equation
        }
        if lower.hasPrefix("thm:") || lower.hasPrefix("lem:") || lower.hasPrefix("prop:")
            || lower.hasPrefix("cor:") || lower.hasPrefix("def:") || lower.hasPrefix("rem:") || lower.hasPrefix("assump:") {
            return .theorem
        }
        if lower.hasPrefix("alg:") || lower.hasPrefix("algo:") {
            return .algorithm
        }
        if lower.hasPrefix("lst:") || lower.hasPrefix("code:") {
            return .listing
        }

        if let env = enclosingEnvironment?.lowercased() {
            if env.hasPrefix("figure") || env.hasPrefix("subfigure") || env == "wrapfigure" {
                return .figure
            }
            if env.hasPrefix("table") || env.hasPrefix("tabular") || env == "longtable" {
                return .table
            }
            if env.hasPrefix("equation") || env.hasPrefix("align") || env.hasPrefix("gather") || env.hasPrefix("multline") {
                return .equation
            }
            if env == "theorem" || env == "lemma" || env == "proposition" || env == "corollary" || env == "definition" {
                return .theorem
            }
            if env.hasPrefix("algorithm") {
                return .algorithm
            }
            if env == "lstlisting" || env == "minted" {
                return .listing
            }
        }
        return .general
    }
}

/// Indexed `\label{...}` or `<label>` declaration with its enclosing context.
public struct LabelSymbolRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(filePath):\(key):\(span.start.line):\(span.start.column)" }
    public let key: String
    public let category: LabelCategory
    public let enclosingTitleOrCaption: String?
    public let enclosingEnvironment: String?
    public let filePath: String
    public let span: TextSpan

    public init(
        key: String,
        category: LabelCategory,
        enclosingTitleOrCaption: String? = nil,
        enclosingEnvironment: String? = nil,
        filePath: String,
        span: TextSpan
    ) {
        self.key = key
        self.category = category
        self.enclosingTitleOrCaption = enclosingTitleOrCaption
        self.enclosingEnvironment = enclosingEnvironment
        self.filePath = filePath
        self.span = span
    }
}

/// Indexed occurrence of a bibliography citation key in manuscript prose or captions.
public struct CitationOccurrenceRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(span.filePath):\(span.start.line):\(span.start.column):\(citeKey)" }
    public let citeKey: String
    public let command: String
    public let prenote: String?
    public let postnote: String?
    public let enclosingSectionTitle: String?
    public let surroundingParagraphPreview: String?
    public let span: TextSpan

    public init(
        citeKey: String,
        command: String,
        prenote: String? = nil,
        postnote: String? = nil,
        enclosingSectionTitle: String? = nil,
        surroundingParagraphPreview: String? = nil,
        span: TextSpan
    ) {
        self.citeKey = citeKey
        self.command = command
        self.prenote = prenote
        self.postnote = postnote
        self.enclosingSectionTitle = enclosingSectionTitle
        self.surroundingParagraphPreview = surroundingParagraphPreview
        self.span = span
    }
}

/// Indexed cross-reference call (`\ref`, `\eqref`, `\cref`, `\autoref`, `#ref`, `@sec:...`).
public struct CrossReferenceOccurrenceRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(span.filePath):\(span.start.line):\(span.start.column):\(targetKey)" }
    public let command: String
    public let targetKey: String
    public let expectedCategory: LabelCategory?
    public let span: TextSpan

    public init(
        command: String,
        targetKey: String,
        expectedCategory: LabelCategory? = nil,
        span: TextSpan
    ) {
        self.command = command
        self.targetKey = targetKey
        self.expectedCategory = expectedCategory
        self.span = span
    }
}

/// Indexed environment instance (`figure`, `table`, `equation`, `theorem`, `algorithm`, etc.).
public struct EnvironmentSymbolRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(span.filePath):\(span.start.line):\(span.start.column):\(name)" }
    public let name: String
    public let label: String?
    public let caption: String?
    public let ordinalNumber: Int?
    public let span: TextSpan

    public init(
        name: String,
        label: String? = nil,
        caption: String? = nil,
        ordinalNumber: Int? = nil,
        span: TextSpan
    ) {
        self.name = name
        self.label = label
        self.caption = caption
        self.ordinalNumber = ordinalNumber
        self.span = span
    }
}

/// Unified multi-file symbol table aggregating macros, labels, citations, cross-references, and environments.
public struct ManuscriptSymbolTable: Sendable, Codable, Hashable {
    public let macrosByName: [String: MacroDefinitionRecord]
    public let allMacroDeclarations: [MacroDefinitionRecord]
    public let macroDependencyCycles: [[String]]
    public let labelsByKey: [String: LabelSymbolRecord]
    public let allLabelDeclarations: [LabelSymbolRecord]
    public let duplicateLabels: [LabelSymbolRecord]
    public let citationsByKey: [String: [CitationOccurrenceRecord]]
    public let allCitationOccurrences: [CitationOccurrenceRecord]
    public let crossReferences: [CrossReferenceOccurrenceRecord]
    public let unresolvedCrossReferences: [CrossReferenceOccurrenceRecord]
    public let environments: [EnvironmentSymbolRecord]
    public let customCommandsUsed: Set<String>

    public init(
        macrosByName: [String: MacroDefinitionRecord],
        allMacroDeclarations: [MacroDefinitionRecord],
        macroDependencyCycles: [[String]],
        labelsByKey: [String: LabelSymbolRecord],
        allLabelDeclarations: [LabelSymbolRecord],
        duplicateLabels: [LabelSymbolRecord],
        citationsByKey: [String: [CitationOccurrenceRecord]],
        allCitationOccurrences: [CitationOccurrenceRecord],
        crossReferences: [CrossReferenceOccurrenceRecord],
        unresolvedCrossReferences: [CrossReferenceOccurrenceRecord],
        environments: [EnvironmentSymbolRecord],
        customCommandsUsed: Set<String>
    ) {
        self.macrosByName = macrosByName
        self.allMacroDeclarations = allMacroDeclarations
        self.macroDependencyCycles = macroDependencyCycles
        self.labelsByKey = labelsByKey
        self.allLabelDeclarations = allLabelDeclarations
        self.duplicateLabels = duplicateLabels
        self.citationsByKey = citationsByKey
        self.allCitationOccurrences = allCitationOccurrences
        self.crossReferences = crossReferences
        self.unresolvedCrossReferences = unresolvedCrossReferences
        self.environments = environments
        self.customCommandsUsed = customCommandsUsed
    }

    public static let empty = ManuscriptSymbolTable(
        macrosByName: [:],
        allMacroDeclarations: [],
        macroDependencyCycles: [],
        labelsByKey: [:],
        allLabelDeclarations: [],
        duplicateLabels: [],
        citationsByKey: [:],
        allCitationOccurrences: [],
        crossReferences: [],
        unresolvedCrossReferences: [],
        environments: [],
        customCommandsUsed: []
    )

    /// Emits semantic symbol diagnostics (duplicate labels, unresolved cross-references, `\eqref` non-equation mismatch, recursive macro loops).
    public func symbolDiagnostics() -> [LSPDiagnostic] {
        var diagnostics: [LSPDiagnostic] = []

        // 1. Recursive macro cycles
        for cycle in macroDependencyCycles {
            guard let headName = cycle.first,
                  let decl = macrosByName[headName] else { continue }
            let chainText = cycle.joined(separator: " -> ")
            diagnostics.append(
                LSPDiagnostic(
                    code: "SYM001",
                    severity: .error,
                    message: "Recursive macro definition cycle detected: \(chainText).",
                    span: decl.span,
                    suggestedFix: "Break self-referential macro expansion in '\(headName)'."
                )
            )
        }

        // 2. Duplicate `\newcommand` redeclarations (when not using `\renewcommand` or `\providecommand`)
        var seenNewCommands: [String: MacroDefinitionRecord] = [:]
        for decl in allMacroDeclarations {
            if let existing = seenNewCommands[decl.name], decl.originKind == .latexNewCommand {
                diagnostics.append(
                    LSPDiagnostic(
                        code: "SYM002",
                        severity: .warning,
                        message: "Macro '\(decl.name)' was already defined at \(existing.filePath):\(existing.span.start.line); use '\\renewcommand' to override.",
                        span: decl.span,
                        suggestedFix: "\\renewcommand{\(decl.name)}"
                    )
                )
            } else {
                seenNewCommands[decl.name] = decl
            }
        }

        // 3. Duplicate `\label{...}` declarations
        for dup in duplicateLabels {
            let firstLoc = labelsByKey[dup.key].map { "\($0.filePath):\($0.span.start.line)" } ?? "earlier location"
            diagnostics.append(
                LSPDiagnostic(
                    code: "SYM003",
                    severity: .error,
                    message: "Duplicate label '\(dup.key)' already declared at \(firstLoc).",
                    span: dup.span,
                    suggestedFix: "Rename duplicate label '\(dup.key)' to a unique identifier."
                )
            )
        }

        // 4. Unresolved cross-references (`\ref`, `\eqref`, `\cref`, `\autoref`)
        for unresolved in unresolvedCrossReferences {
            let suggestion = closestLabelCandidate(for: unresolved.targetKey)
            diagnostics.append(
                LSPDiagnostic(
                    code: "SYM004",
                    severity: .warning,
                    message: "Unresolved cross-reference '\(unresolved.targetKey)' in '\(unresolved.command)'.",
                    span: unresolved.span,
                    suggestedFix: suggestion.map { "Did you mean '\($0)'?" }
                )
            )
        }

        // 5. Category mismatch: `\eqref{...}` pointing to a non-equation label (`fig:...`, `sec:...`, `tab:...`)
        for ref in crossReferences where ref.command == "\\eqref" {
            if let resolved = labelsByKey[ref.targetKey],
               resolved.category != .equation && resolved.category != .general {
                diagnostics.append(
                    LSPDiagnostic(
                        code: "SYM005",
                        severity: .info,
                        message: "'\\eqref{\(ref.targetKey)}' references a \(resolved.category.rawValue) label rather than an Equation.",
                        span: ref.span,
                        suggestedFix: "\\cref{\(ref.targetKey)}"
                    )
                )
            }
        }

        return diagnostics
    }

    /// Generates ranked `LSPCompletionItem` entries for user macros, labels, environments, and math symbols.
    public func completionItems(matchingPrefix prefix: String = "") -> [LSPCompletionItem] {
        let normalizedQuery = prefix.lowercased()
        var items: [LSPCompletionItem] = []

        // User macros
        for (_, macro) in macrosByName {
            if !normalizedQuery.isEmpty && !macro.name.lowercased().contains(normalizedQuery) {
                continue
            }
            var snippet = macro.name
            if macro.mandatoryParameterCount > 0 && macro.originKind != .typstLetBinding {
                for _ in 0..<macro.mandatoryParameterCount {
                    snippet += "{}"
                }
            }
            items.append(
                LSPCompletionItem(
                    id: "macro:\(macro.name)",
                    insertText: snippet,
                    title: macro.signatureDisplay,
                    subtitle: "User Macro (\(macro.filePath):\(macro.span.start.line))",
                    detailMarkdown: "Expands to: `\(macro.replacementBody)`",
                    category: .userMacro,
                    relevanceScore: 0.96
                )
            )
        }

        // Declared labels
        for (_, lbl) in labelsByKey {
            if !normalizedQuery.isEmpty && !lbl.key.lowercased().contains(normalizedQuery) {
                continue
            }
            let contextNote = lbl.enclosingTitleOrCaption ?? lbl.enclosingEnvironment ?? lbl.category.rawValue
            items.append(
                LSPCompletionItem(
                    id: "label:\(lbl.key)",
                    insertText: lbl.key,
                    title: lbl.key,
                    subtitle: "\(lbl.category.rawValue) — \(contextNote)",
                    detailMarkdown: "Declared in `\(lbl.filePath)` line \(lbl.span.start.line)",
                    category: .labelRef,
                    relevanceScore: 0.94
                )
            )
        }

        return items.sorted {
            if $0.relevanceScore != $1.relevanceScore {
                return $0.relevanceScore > $1.relevanceScore
            }
            return $0.title < $1.title
        }
    }

    private func closestLabelCandidate(for target: String) -> String? {
        guard !target.isEmpty, !labelsByKey.isEmpty else { return nil }
        var bestKey: String? = nil
        var bestDist = Int.max
        for candidate in labelsByKey.keys.sorted() {
            let dist = Self.levenshteinDistance(target, candidate)
            if dist < bestDist && dist <= 3 {
                bestDist = dist
                bestKey = candidate
            }
        }
        return bestKey
    }

    private static func levenshteinDistance(_ a: String, _ b: String) -> Int {
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

// MARK: - Macro Expansion Results & Math Preview Models

public enum MacroExpansionIssueKind: String, Sendable, Codable, Hashable {
    case recursiveMacroCycle = "MAC001"
    case maxExpansionDepthExceeded = "MAC002"
    case outputBudgetExceeded = "MAC003"
    case missingMandatoryArgument = "MAC004"
    case unclosedMacroArgument = "MAC005"
}

public struct MacroExpansionIssue: Sendable, Codable, Hashable {
    public let kind: MacroExpansionIssueKind
    public let macroName: String
    public let callChain: [String]
    public let message: String

    public init(
        kind: MacroExpansionIssueKind,
        macroName: String,
        callChain: [String],
        message: String
    ) {
        self.kind = kind
        self.macroName = macroName
        self.callChain = callChain
        self.message = message
    }

    public func toLSPDiagnostic(at span: TextSpan) -> LSPDiagnostic {
        LSPDiagnostic(
            code: kind.rawValue,
            severity: kind == .recursiveMacroCycle ? .error : .warning,
            message: message,
            span: span
        )
    }
}

/// Result of bounded, cycle-safe macro expansion over a LaTeX or Typst snippet.
public struct MacroExpansionResult: Sendable, Codable, Hashable {
    public let originalSource: String
    public let expandedSource: String
    public let appliedMacroNames: [String]
    public let peakExpansionDepth: Int
    public let wasTruncatedBySafetyLimit: Bool
    public let issues: [MacroExpansionIssue]

    public init(
        originalSource: String,
        expandedSource: String,
        appliedMacroNames: [String],
        peakExpansionDepth: Int,
        wasTruncatedBySafetyLimit: Bool,
        issues: [MacroExpansionIssue]
    ) {
        self.originalSource = originalSource
        self.expandedSource = expandedSource
        self.appliedMacroNames = appliedMacroNames
        self.peakExpansionDepth = peakExpansionDepth
        self.wasTruncatedBySafetyLimit = wasTruncatedBySafetyLimit
        self.issues = issues
    }
}

/// Expanded preview of an inline or display mathematical formula for LSP hover cards & symbol inspection.
public struct MathFormulaPreview: Sendable, Codable, Hashable {
    public let originalFormula: String
    public let expandedFormula: String
    public let unicodeApproximation: String
    public let isDisplayMode: Bool
    public let label: String?
    public let span: TextSpan
    public let referencedMacros: [String]
    public let issues: [MacroExpansionIssue]

    public init(
        originalFormula: String,
        expandedFormula: String,
        unicodeApproximation: String,
        isDisplayMode: Bool,
        label: String?,
        span: TextSpan,
        referencedMacros: [String],
        issues: [MacroExpansionIssue]
    ) {
        self.originalFormula = originalFormula
        self.expandedFormula = expandedFormula
        self.unicodeApproximation = unicodeApproximation
        self.isDisplayMode = isDisplayMode
        self.label = label
        self.span = span
        self.referencedMacros = referencedMacros
        self.issues = issues
    }
}

// MARK: - Cycle-Safe Macro Expansion & Cross-File Symbol Engine

/// Tracks `\newcommand`, `\renewcommand`, `\providecommand`, `\def`, `\DeclareMathOperator`, and Typst `#let`
/// definitions across files, performs bounded cycle-safe macro expansion (`maxExpansionDepth = 32`),
/// previews expanded math formulas, and builds workspace-wide `ManuscriptSymbolTable` indices.
public struct MacroExpansionEngine: Sendable {
    public static let defaultMaxExpansionDepth: Int = 32
    public static let defaultMaxExpandedOutputBytes: Int = 262_144

    public let maxExpansionDepth: Int
    public let maxExpandedOutputBytes: Int
    private let lexer: IncrementalMarkupLexer

    public init(
        maxExpansionDepth: Int = MacroExpansionEngine.defaultMaxExpansionDepth,
        maxExpandedOutputBytes: Int = MacroExpansionEngine.defaultMaxExpandedOutputBytes,
        lexer: IncrementalMarkupLexer = IncrementalMarkupLexer(configuration: .losslessCST)
    ) {
        self.maxExpansionDepth = max(1, maxExpansionDepth)
        self.maxExpandedOutputBytes = max(1_024, maxExpandedOutputBytes)
        self.lexer = lexer
    }

    // MARK: Public Macro Extraction & Symbol Table Construction

    /// Extracts rich `MacroDefinitionRecord` entries (including optional default `#1` values, `#let` parameter names,
    /// and `\DeclareMathOperator*` star flags) from a `MarkupParseResult`.
    public func extractMacroDefinitions(from parseResult: MarkupParseResult) -> [MacroDefinitionRecord] {
        var records: [MacroDefinitionRecord] = []
        switch parseResult.format {
        case .latex, .markdown:
            records.append(contentsOf: extractLaTeXMacrosFromTokens(parseResult.tokens, filePath: parseResult.filePath))
        case .typst:
            records.append(contentsOf: extractTypstMacrosFromTokens(parseResult.tokens, filePath: parseResult.filePath))
        }

        // Fallback supplement: if an AST was constructed synthetically without matching lexical tokens,
        // ensure every `.macroDefinition` AST node is still represented.
        let extractedSpans = Set(records.map(\.span))
        for node in parseResult.root.allMacroDefinitions {
            if !extractedSpans.contains(node.span),
               case .macroDefinition(let name, let paramCount, let body) = node.kind {
                let origin: MacroOriginKind = parseResult.format == .typst ? .typstLetBinding : .latexNewCommand
                records.append(
                    MacroDefinitionRecord(
                        name: name,
                        originKind: origin,
                        parameterCount: paramCount,
                        replacementBody: body,
                        filePath: node.span.filePath,
                        span: node.span
                    )
                )
            }
        }
        return records
    }

    /// Builds a complete symbol table from a single `MarkupParseResult`.
    public func buildSymbolTable(from parseResult: MarkupParseResult) -> ManuscriptSymbolTable {
        buildSymbolTable(from: [parseResult])
    }

    /// Builds a unified cross-file `ManuscriptSymbolTable` across an ordered list of `MarkupParseResult` files.
    public func buildSymbolTable(from parseResults: [MarkupParseResult]) -> ManuscriptSymbolTable {
        var macrosByName: [String: MacroDefinitionRecord] = [:]
        var allMacroDeclarations: [MacroDefinitionRecord] = []

        var labelsByKey: [String: LabelSymbolRecord] = [:]
        var allLabelDeclarations: [LabelSymbolRecord] = []
        var duplicateLabels: [LabelSymbolRecord] = []

        var citationsByKey: [String: [CitationOccurrenceRecord]] = [:]
        var allCitationOccurrences: [CitationOccurrenceRecord] = []

        var rawCrossReferences: [CrossReferenceOccurrenceRecord] = []
        var environments: [EnvironmentSymbolRecord] = []
        var environmentCounters: [String: Int] = [:]
        var customCommandsUsed: Set<String> = []

        // Pass 1: Extract macros in file order respecting `\newcommand` / `\renewcommand` / `\providecommand` semantics!
        for result in parseResults {
            let fileMacros = extractMacroDefinitions(from: result)
            for macro in fileMacros {
                allMacroDeclarations.append(macro)
                switch macro.originKind {
                case .latexProvideCommand:
                    // `\providecommand` only defines the macro if it does NOT already exist!
                    if macrosByName[macro.name] == nil {
                        macrosByName[macro.name] = macro
                    }
                default:
                    macrosByName[macro.name] = macro
                }
            }
        }

        // Pass 2: Walk each file's AST hierarchically to index labels, citations, cross-refs, and environments
        // with full enclosing section/environment/paragraph context.
        for result in parseResults {
            indexASTSubtree(
                node: result.root,
                enclosingSectionTitle: nil,
                enclosingEnvironment: nil,
                enclosingCaption: nil,
                enclosingParagraphPreview: nil,
                labelsByKey: &labelsByKey,
                allLabelDeclarations: &allLabelDeclarations,
                duplicateLabels: &duplicateLabels,
                citationsByKey: &citationsByKey,
                allCitationOccurrences: &allCitationOccurrences,
                crossReferences: &rawCrossReferences,
                environments: &environments,
                environmentCounters: &environmentCounters
            )

            // Also track custom commands referenced in tokens.
            for tok in result.tokens {
                if tok.kind == .command, macrosByName[tok.lexeme] != nil {
                    customCommandsUsed.insert(tok.lexeme)
                } else if tok.kind == .typstHashKeyword, tok.lexeme.hasPrefix("#") {
                    let stripped = String(tok.lexeme.dropFirst())
                    if macrosByName[stripped] != nil {
                        customCommandsUsed.insert(stripped)
                    }
                }
            }
        }

        // Pass 3: Reclassify any Typst `@key` citation across files that actually matches a `<label>` declared in ANOTHER included `.typ` file!
        var resolvedCitationsByKey: [String: [CitationOccurrenceRecord]] = [:]
        var resolvedAllCitations: [CitationOccurrenceRecord] = []
        var finalCrossReferences = rawCrossReferences

        for occ in allCitationOccurrences {
            if occ.command == "@" && labelsByKey[occ.citeKey] != nil {
                finalCrossReferences.append(
                    CrossReferenceOccurrenceRecord(
                        command: "@",
                        targetKey: occ.citeKey,
                        expectedCategory: nil,
                        span: occ.span
                    )
                )
            } else {
                resolvedAllCitations.append(occ)
                resolvedCitationsByKey[occ.citeKey, default: []].append(occ)
            }
        }

        let unresolvedCrossRefs = finalCrossReferences.filter { ref in
            !ref.targetKey.isEmpty && labelsByKey[ref.targetKey] == nil
        }

        let cycles = detectMacroCycles(in: macrosByName)

        return ManuscriptSymbolTable(
            macrosByName: macrosByName,
            allMacroDeclarations: allMacroDeclarations,
            macroDependencyCycles: cycles,
            labelsByKey: labelsByKey,
            allLabelDeclarations: allLabelDeclarations,
            duplicateLabels: duplicateLabels,
            citationsByKey: resolvedCitationsByKey,
            allCitationOccurrences: resolvedAllCitations,
            crossReferences: finalCrossReferences,
            unresolvedCrossReferences: unresolvedCrossRefs,
            environments: environments,
            customCommandsUsed: customCommandsUsed
        )
    }

    // MARK: Static Macro Dependency Cycle Detection

    /// Detects self-recursive (`\newcommand{\foo}{\foo}`) and mutually recursive (`\a -> \b -> \a`) macro loops.
    public func detectMacroCycles(in macros: [String: MacroDefinitionRecord]) -> [[String]] {
        // Build directed call graph among known user macros.
        var adjacency: [String: [String]] = [:]
        for (name, record) in macros {
            let format: ManuscriptFormat = record.originKind == .typstLetBinding ? .typst : .latex
            let bodyTokens = lexer.tokenize(source: record.replacementBody, format: format, filePath: record.filePath)
            var callees: [String] = []
            var seen = Set<String>()
            for tok in bodyTokens {
                let candidate: String?
                if format == .typst {
                    if tok.kind == .typstHashKeyword && tok.lexeme.hasPrefix("#") {
                        candidate = String(tok.lexeme.dropFirst())
                    } else if tok.kind == .textWord || tok.kind == .identifier {
                        candidate = tok.lexeme
                    } else {
                        candidate = nil
                    }
                } else {
                    candidate = tok.kind == .command ? tok.lexeme : nil
                }
                if let c = candidate, macros[c] != nil, !seen.contains(c) {
                    seen.insert(c)
                    callees.append(c)
                }
            }
            adjacency[name] = callees.sorted()
        }

        enum VisitColor { case white, gray, black }
        var color: [String: VisitColor] = [:]
        var pathStack: [String] = []
        var cycles: [[String]] = []
        var recordedCycleSignatures: Set<String> = []

        func dfs(_ node: String) {
            color[node] = .gray
            pathStack.append(node)

            for neighbor in adjacency[node] ?? [] {
                let neighborState = color[neighbor] ?? .white
                if neighborState == .gray {
                    if let cycleStart = pathStack.firstIndex(of: neighbor) {
                        var cycle = Array(pathStack[cycleStart...])
                        cycle.append(neighbor)
                        // Canonicalize cycle rotation to avoid duplicate reports.
                        let core = Array(cycle.dropLast())
                        if let minElem = core.min(), let minPos = core.firstIndex(of: minElem) {
                            let rotated = Array(core[minPos...]) + Array(core[..<minPos]) + [minElem]
                            let sig = rotated.joined(separator: "->")
                            if !recordedCycleSignatures.contains(sig) {
                                recordedCycleSignatures.insert(sig)
                                cycles.append(rotated)
                            }
                        }
                    }
                } else if neighborState == .white {
                    dfs(neighbor)
                }
            }

            _ = pathStack.popLast()
            color[node] = .black
        }

        for macroName in macros.keys.sorted() {
            if (color[macroName] ?? .white) == .white {
                dfs(macroName)
            }
        }
        return cycles
    }

    // MARK: Bounded, Cycle-Safe Macro Expansion

    /// Expands LaTeX or Typst user macros inside `text` up to `maxExpansionDepth` (default `32`),
    /// catching direct/mutual recursion and substituting `#1`..`#9` plus optional default `[default]` `#1` arguments.
    public func expand(
        text: String,
        using macros: [String: MacroDefinitionRecord],
        format: ManuscriptFormat = .latex
    ) -> MacroExpansionResult {
        guard !macros.isEmpty, !text.isEmpty else {
            return MacroExpansionResult(
                originalSource: text,
                expandedSource: text,
                appliedMacroNames: [],
                peakExpansionDepth: 0,
                wasTruncatedBySafetyLimit: false,
                issues: []
            )
        }

        var state = ExpansionExecutionState(
            macros: macros,
            format: format,
            maxDepth: maxExpansionDepth,
            maxOutputBytes: maxExpandedOutputBytes,
            lexer: lexer
        )
        let expanded = state.expandSegment(text, depth: 0, activeChain: [])
        return MacroExpansionResult(
            originalSource: text,
            expandedSource: expanded,
            appliedMacroNames: state.appliedMacrosInOrder,
            peakExpansionDepth: state.peakDepth,
            wasTruncatedBySafetyLimit: state.truncatedByLimit,
            issues: state.issues
        )
    }

    /// Convenience overload expanding `text` against a built `ManuscriptSymbolTable`.
    public func expand(
        text: String,
        using symbolTable: ManuscriptSymbolTable,
        format: ManuscriptFormat = .latex
    ) -> MacroExpansionResult {
        expand(text: text, using: symbolTable.macrosByName, format: format)
    }

    // MARK: Math Formula Expansion & Unicode Hover Preview

    /// Expands all custom macros inside a `.mathExpression` AST node and renders an approximate Unicode math preview.
    public func previewMathExpression(
        _ node: MarkupASTNode,
        using symbolTable: ManuscriptSymbolTable,
        format: ManuscriptFormat = .latex
    ) -> MathFormulaPreview? {
        guard case .mathExpression(let isDisplay, let formulaSource, let label) = node.kind else {
            return nil
        }
        let expansion = expand(text: formulaSource, using: symbolTable.macrosByName, format: format)
        let unicode = Self.approximateUnicodeMath(from: expansion.expandedSource)
        return MathFormulaPreview(
            originalFormula: formulaSource,
            expandedFormula: expansion.expandedSource,
            unicodeApproximation: unicode,
            isDisplayMode: isDisplay,
            label: label,
            span: node.span,
            referencedMacros: expansion.appliedMacroNames,
            issues: expansion.issues
        )
    }

    /// Previews all `.mathExpression` nodes inside an AST root (deduplicating display-environment wrappers).
    public func previewAllMathExpressions(
        in root: MarkupASTNode,
        using symbolTable: ManuscriptSymbolTable,
        format: ManuscriptFormat = .latex
    ) -> [MathFormulaPreview] {
        root.allMathExpressions.compactMap {
            previewMathExpression($0, using: symbolTable, format: format)
        }
    }

    // MARK: - Internal Token-Level Macro Definition Extractors

    private func extractLaTeXMacrosFromTokens(
        _ tokens: [MarkupToken],
        filePath: String
    ) -> [MacroDefinitionRecord] {
        var results: [MacroDefinitionRecord] = []
        var idx = 0
        let count = tokens.count

        while idx < count {
            let tok = tokens[idx]
            guard tok.kind == .command, LaTeXCommandRole.classify(tok.lexeme) == .macroDefinition else {
                idx += 1
                continue
            }

            let docComment = findPrecedingComment(in: tokens, beforeIndex: idx)
            let startPos = tok.span.start
            let cmdLexeme = tok.lexeme
            idx += 1

            // Skip horizontal whitespace
            skipSpaces(in: tokens, index: &idx, allowSingleNewline: true)

            // Case A: `\def\foo#1#2{body}`
            if cmdLexeme == "\\def" || cmdLexeme == "\\gdef" || cmdLexeme == "\\edef" || cmdLexeme == "\\xdef" {
                guard idx < count, tokens[idx].kind == .command else { continue }
                let macroName = tokens[idx].lexeme
                idx += 1
                var paramCount = 0
                while idx < count && tokens[idx].kind != .leftBrace && tokens[idx].kind != .eof {
                    if tokens[idx].kind == .whitespace && (tokens[idx].lexeme.contains("\n") || tokens[idx].lexeme.contains("\r")) {
                        break
                    }
                    if tokens[idx].kind == .identifier, tokens[idx].lexeme.hasPrefix("#"),
                       let digit = Int(tokens[idx].lexeme.dropFirst()), digit > paramCount {
                        paramCount = digit
                    }
                    idx += 1
                }
                guard idx < count, tokens[idx].kind == .leftBrace else { continue }
                let bodyGrp = readBalancedGroup(in: tokens, index: &idx, openKind: .leftBrace, closeKind: .rightBrace)
                results.append(
                    MacroDefinitionRecord(
                        name: macroName,
                        originKind: .latexTeXDef,
                        parameterCount: paramCount,
                        replacementBody: bodyGrp.content,
                        filePath: filePath,
                        span: TextSpan(filePath: filePath, start: startPos, end: bodyGrp.endPos),
                        documentationComment: docComment
                    )
                )
                continue
            }

            // Case B: `\newcommand`, `\renewcommand`, `\providecommand`, `\DeclareRobustCommand`, `\DeclareMathOperator`
            let origin: MacroOriginKind
            let isStarredOperator = (cmdLexeme == "\\DeclareMathOperator*")
            if cmdLexeme.hasPrefix("\\newcommand") {
                origin = .latexNewCommand
            } else if cmdLexeme.hasPrefix("\\renewcommand") {
                origin = .latexRenewCommand
            } else if cmdLexeme.hasPrefix("\\providecommand") {
                origin = .latexProvideCommand
            } else if cmdLexeme.hasPrefix("\\DeclareRobustCommand") {
                origin = .latexDeclareRobustCommand
            } else if cmdLexeme.hasPrefix("\\DeclareMathOperator") {
                origin = .latexDeclareMathOperator
            } else {
                origin = .latexNewDocumentCommand
            }

            var macroName = ""
            if idx < count && tokens[idx].kind == .leftBrace {
                let nameGrp = readBalancedGroup(in: tokens, index: &idx, openKind: .leftBrace, closeKind: .rightBrace)
                macroName = nameGrp.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if idx < count && tokens[idx].kind == .command {
                macroName = tokens[idx].lexeme
                idx += 1
            } else {
                continue
            }
            guard !macroName.isEmpty else { continue }

            skipSpaces(in: tokens, index: &idx, allowSingleNewline: true)

            var paramCount = 0
            var defaultOptionalArg: String? = nil

            if origin == .latexNewDocumentCommand {
                if idx < count && tokens[idx].kind == .leftBrace {
                    let specGrp = readBalancedGroup(in: tokens, index: &idx, openKind: .leftBrace, closeKind: .rightBrace)
                    paramCount = parseXparseArgSpec(specGrp.content, defaultOut: &defaultOptionalArg)
                    skipSpaces(in: tokens, index: &idx, allowSingleNewline: true)
                }
            } else if origin != .latexDeclareMathOperator {
                if idx < count && tokens[idx].kind == .leftBracket {
                    let arityGrp = readBalancedGroup(in: tokens, index: &idx, openKind: .leftBracket, closeKind: .rightBracket)
                    if let n = Int(arityGrp.content.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        paramCount = max(0, min(9, n))
                    }
                    skipSpaces(in: tokens, index: &idx, allowSingleNewline: true)
                }
                if idx < count && tokens[idx].kind == .leftBracket {
                    let defGrp = readBalancedGroup(in: tokens, index: &idx, openKind: .leftBracket, closeKind: .rightBracket)
                    defaultOptionalArg = defGrp.content
                    skipSpaces(in: tokens, index: &idx, allowSingleNewline: true)
                }
            }

            guard idx < count, tokens[idx].kind == .leftBrace else { continue }
            let bodyGrp = readBalancedGroup(in: tokens, index: &idx, openKind: .leftBrace, closeKind: .rightBrace)

            let bodyText: String
            if origin == .latexDeclareMathOperator {
                bodyText = isStarredOperator
                    ? "\\operatorname*{\(bodyGrp.content)}"
                    : "\\operatorname{\(bodyGrp.content)}"
            } else {
                bodyText = bodyGrp.content
            }

            results.append(
                MacroDefinitionRecord(
                    name: macroName,
                    originKind: origin,
                    parameterCount: paramCount,
                    defaultOptionalArgument: defaultOptionalArg,
                    replacementBody: bodyText,
                    isStarredMathOperator: isStarredOperator,
                    filePath: filePath,
                    span: TextSpan(filePath: filePath, start: startPos, end: bodyGrp.endPos),
                    documentationComment: docComment
                )
            )
        }

        return results
    }

    private func parseXparseArgSpec(_ spec: String, defaultOut: inout String?) -> Int {
        var count = 0
        let chars = Array(spec)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "m" || c == "o" {
                count += 1
            } else if c == "O" {
                count += 1
                // `O{default}` specifies an optional parameter with default!
                if i + 1 < chars.count && chars[i + 1] == "{" {
                    i += 2
                    var defChars: [Character] = []
                    var depth = 1
                    while i < chars.count && depth > 0 {
                        if chars[i] == "{" { depth += 1 }
                        else if chars[i] == "}" { depth -= 1 }
                        if depth > 0 { defChars.append(chars[i]) }
                        i += 1
                    }
                    if defaultOut == nil {
                        defaultOut = String(defChars)
                    }
                    continue
                }
            }
            i += 1
        }
        return count
    }

    private func extractTypstMacrosFromTokens(
        _ tokens: [MarkupToken],
        filePath: String
    ) -> [MacroDefinitionRecord] {
        var results: [MacroDefinitionRecord] = []
        var idx = 0
        let count = tokens.count

        while idx < count {
            let tok = tokens[idx]
            guard tok.kind == .typstHashKeyword && tok.lexeme == "#let" else {
                idx += 1
                continue
            }

            let docComment = findPrecedingComment(in: tokens, beforeIndex: idx)
            let startPos = tok.span.start
            idx += 1
            skipSpaces(in: tokens, index: &idx, allowSingleNewline: false)

            guard idx < count, tokens[idx].kind == .textWord || tokens[idx].kind == .identifier else {
                continue
            }
            let name = tokens[idx].lexeme
            idx += 1

            var paramNames: [String] = []
            var defaultFirstArg: String? = nil

            if idx < count && tokens[idx].kind == .punctuation && tokens[idx].lexeme == "(" {
                idx += 1 // '('
                var rawParamStr = ""
                var depth = 1
                while idx < count && depth > 0 && tokens[idx].kind != .eof {
                    let t = tokens[idx]
                    if t.kind == .punctuation && t.lexeme == "(" { depth += 1 }
                    else if t.kind == .punctuation && t.lexeme == ")" { depth -= 1 }
                    if depth > 0 && t.kind != .comment {
                        rawParamStr.append(t.lexeme)
                    }
                    idx += 1
                }
                for rawPart in rawParamStr.split(separator: ",") {
                    let trimmed = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if let colonIdx = trimmed.firstIndex(of: ":") {
                        let pName = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                        let pDef = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                        if paramNames.isEmpty && !pDef.isEmpty {
                            defaultFirstArg = pDef
                        }
                        if !pName.isEmpty {
                            paramNames.append(pName)
                        }
                    } else {
                        paramNames.append(trimmed)
                    }
                }
            }

            skipSpaces(in: tokens, index: &idx, allowSingleNewline: false)
            if idx < count && tokens[idx].kind == .punctuation && tokens[idx].lexeme == "=" {
                idx += 1
            }
            skipSpaces(in: tokens, index: &idx, allowSingleNewline: false)

            var bodyParts: [String] = []
            var endPos = startPos
            var parenDepth = 0
            var braceDepth = 0
            var bracketDepth = 0

            while idx < count && tokens[idx].kind != .eof {
                let t = tokens[idx]
                if parenDepth == 0 && braceDepth == 0 && bracketDepth == 0 {
                    if t.kind == .whitespace && (t.lexeme.contains("\n") || t.lexeme.contains("\r")) {
                        break
                    }
                }
                if t.kind == .punctuation && t.lexeme == "(" { parenDepth += 1 }
                else if t.kind == .punctuation && t.lexeme == ")" && parenDepth > 0 { parenDepth -= 1 }
                else if t.kind == .leftBrace { braceDepth += 1 }
                else if t.kind == .rightBrace && braceDepth > 0 { braceDepth -= 1 }
                else if t.kind == .leftBracket { bracketDepth += 1 }
                else if t.kind == .rightBracket && bracketDepth > 0 { bracketDepth -= 1 }

                if t.kind != .comment {
                    bodyParts.append(t.lexeme)
                }
                endPos = t.span.end
                idx += 1
            }

            let cleanBody = bodyParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(
                MacroDefinitionRecord(
                    name: name,
                    originKind: .typstLetBinding,
                    parameterCount: paramNames.count,
                    defaultOptionalArgument: defaultFirstArg,
                    parameterNames: paramNames,
                    replacementBody: cleanBody,
                    filePath: filePath,
                    span: TextSpan(filePath: filePath, start: startPos, end: endPos),
                    documentationComment: docComment
                )
            )
        }

        return results
    }

    private func findPrecedingComment(in tokens: [MarkupToken], beforeIndex idx: Int) -> String? {
        var cursor = idx - 1
        var newlines = 0
        while cursor >= 0 {
            let t = tokens[cursor]
            if t.kind == .whitespace {
                if t.lexeme.contains("\n") || t.lexeme.contains("\r") {
                    newlines += 1
                    if newlines > 1 { return nil }
                }
                cursor -= 1
            } else if t.kind == .comment {
                var cleaned = t.lexeme
                while cleaned.hasPrefix("%") || cleaned.hasPrefix("/") || cleaned.hasPrefix("*") {
                    cleaned.removeFirst()
                }
                if cleaned.hasSuffix("*/") {
                    cleaned = String(cleaned.dropLast(2))
                }
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } else {
                return nil
            }
        }
        return nil
    }

    private func skipSpaces(in tokens: [MarkupToken], index: inout Int, allowSingleNewline: Bool) {
        var seenNewlines = 0
        while index < tokens.count {
            let t = tokens[index]
            if t.kind == .comment {
                index += 1
            } else if t.kind == .whitespace {
                if t.lexeme.contains("\n") || t.lexeme.contains("\r") {
                    if !allowSingleNewline || seenNewlines >= 1 {
                        break
                    }
                    seenNewlines += 1
                }
                index += 1
            } else {
                break
            }
        }
    }

    private func readBalancedGroup(
        in tokens: [MarkupToken],
        index: inout Int,
        openKind: MarkupTokenKind,
        closeKind: MarkupTokenKind
    ) -> (content: String, endPos: TextPosition) {
        let openTok = tokens[index]
        var endPos = openTok.span.end
        index += 1
        var depth = 1
        var braceGuard = 0
        var parts: [String] = []

        while index < tokens.count && depth > 0 && tokens[index].kind != .eof {
            let t = tokens[index]
            if openKind == .leftBracket {
                if t.kind == .leftBrace { braceGuard += 1 }
                else if t.kind == .rightBrace && braceGuard > 0 { braceGuard -= 1 }
            }
            if braceGuard == 0 && t.kind == openKind {
                depth += 1
                parts.append(t.lexeme)
                endPos = t.span.end
                index += 1
            } else if braceGuard == 0 && t.kind == closeKind {
                depth -= 1
                endPos = t.span.end
                index += 1
                if depth > 0 {
                    parts.append(t.lexeme)
                }
            } else {
                if t.kind != .comment {
                    parts.append(t.lexeme)
                }
                endPos = t.span.end
                index += 1
            }
        }
        return (parts.joined(), endPos)
    }

    // MARK: - Internal AST Symbol Indexing Walk

    private func indexASTSubtree(
        node: MarkupASTNode,
        enclosingSectionTitle: String?,
        enclosingEnvironment: String?,
        enclosingCaption: String?,
        enclosingParagraphPreview: String?,
        labelsByKey: inout [String: LabelSymbolRecord],
        allLabelDeclarations: inout [LabelSymbolRecord],
        duplicateLabels: inout [LabelSymbolRecord],
        citationsByKey: inout [String: [CitationOccurrenceRecord]],
        allCitationOccurrences: inout [CitationOccurrenceRecord],
        crossReferences: inout [CrossReferenceOccurrenceRecord],
        environments: inout [EnvironmentSymbolRecord],
        environmentCounters: inout [String: Int]
    ) {
        var nextSectionTitle = enclosingSectionTitle
        var nextEnvironment = enclosingEnvironment
        var nextCaption = enclosingCaption
        var nextParagraphPreview = enclosingParagraphPreview

        switch node.kind {
        case .section(_, let title, _):
            nextSectionTitle = title

        case .environment(let name, let rawLabel, let caption):
            let label = rawLabel.map { LaTeXKeyNormalizer.normalize($0) }
            nextEnvironment = name
            nextCaption = caption
            let isNumberedEnv = !name.hasSuffix("*") && name != "abstract" && name != "proof" && name != "itemize" && name != "enumerate"
            let ordinal: Int?
            if isNumberedEnv {
                let nextVal = (environmentCounters[name] ?? 0) + 1
                environmentCounters[name] = nextVal
                ordinal = nextVal
            } else {
                ordinal = nil
            }
            environments.append(
                EnvironmentSymbolRecord(
                    name: name,
                    label: label,
                    caption: caption,
                    ordinalNumber: ordinal,
                    span: node.span
                )
            )

        case .paragraph(let plainPreview):
            nextParagraphPreview = plainPreview

        case .labelDeclaration(let rawKey):
            let key = LaTeXKeyNormalizer.normalize(rawKey)
            guard !key.isEmpty else { break }
            let category = LabelCategory.infer(fromKey: key, enclosingEnvironment: enclosingEnvironment)
            let contextTitle = enclosingCaption ?? enclosingSectionTitle
            let record = LabelSymbolRecord(
                key: key,
                category: category,
                enclosingTitleOrCaption: contextTitle,
                enclosingEnvironment: enclosingEnvironment,
                filePath: node.span.filePath,
                span: node.span
            )
            allLabelDeclarations.append(record)
            if labelsByKey[key] != nil {
                duplicateLabels.append(record)
            } else {
                labelsByKey[key] = record
            }

        case .citation(let command, let citeKeys, let prenote, let postnote):
            for rawKey in citeKeys {
                let key = LaTeXKeyNormalizer.normalize(rawKey)
                guard key != "*" && !key.isEmpty else { continue }
                let occ = CitationOccurrenceRecord(
                    citeKey: key,
                    command: command,
                    prenote: prenote,
                    postnote: postnote,
                    enclosingSectionTitle: enclosingSectionTitle,
                    surroundingParagraphPreview: enclosingParagraphPreview,
                    span: node.span
                )
                allCitationOccurrences.append(occ)
                citationsByKey[key, default: []].append(occ)
            }

        case .crossReference(let command, let rawTargetKey):
            let targetKey = LaTeXKeyNormalizer.normalize(rawTargetKey)
            let expectedCat: LabelCategory? = (command == "\\eqref" || command == "\\eqref*") ? .equation : nil
            crossReferences.append(
                CrossReferenceOccurrenceRecord(
                    command: command,
                    targetKey: targetKey,
                    expectedCategory: expectedCat,
                    span: node.span
                )
            )

        default:
            break
        }

        for child in node.children {
            indexASTSubtree(
                node: child,
                enclosingSectionTitle: nextSectionTitle,
                enclosingEnvironment: nextEnvironment,
                enclosingCaption: nextCaption,
                enclosingParagraphPreview: nextParagraphPreview,
                labelsByKey: &labelsByKey,
                allLabelDeclarations: &allLabelDeclarations,
                duplicateLabels: &duplicateLabels,
                citationsByKey: &citationsByKey,
                allCitationOccurrences: &allCitationOccurrences,
                crossReferences: &crossReferences,
                environments: &environments,
                environmentCounters: &environmentCounters
            )
        }
    }

    // MARK: - Unicode Math Approximation for LSP Hover Cards

    private static let latexToUnicodeMathMap: [(String, String)] = [
        ("\\mathbb{R}", "ℝ"), ("\\mathbb{N}", "ℕ"), ("\\mathbb{Z}", "ℤ"),
        ("\\mathbb{Q}", "ℚ"), ("\\mathbb{C}", "ℂ"), ("\\mathbb{E}", "𝔼"),
        ("\\mathbb{P}", "ℙ"), ("\\mathbb{I}", "𝕀"),
        ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"),
        ("\\epsilon", "ϵ"), ("\\varepsilon", "ε"), ("\\zeta", "ζ"), ("\\eta", "η"),
        ("\\theta", "θ"), ("\\vartheta", "ϑ"), ("\\iota", "ι"), ("\\kappa", "κ"),
        ("\\lambda", "λ"), ("\\mu", "μ"), ("\\nu", "ν"), ("\\xi", "ξ"),
        ("\\pi", "π"), ("\\rho", "ρ"), ("\\sigma", "σ"), ("\\tau", "τ"),
        ("\\upsilon", "υ"), ("\\phi", "ϕ"), ("\\varphi", "φ"), ("\\chi", "χ"),
        ("\\psi", "ψ"), ("\\omega", "ω"),
        ("\\Gamma", "Γ"), ("\\Delta", "Δ"), ("\\Theta", "Θ"), ("\\Lambda", "Λ"),
        ("\\Xi", "Ξ"), ("\\Pi", "Π"), ("\\Sigma", "Σ"), ("\\Phi", "Φ"),
        ("\\Psi", "Ψ"), ("\\Omega", "Ω"),
        ("\\leq", "≤"), ("\\le", "≤"), ("\\geq", "≥"), ("\\ge", "≥"),
        ("\\neq", "≠"), ("\\ne", "≠"), ("\\approx", "≈"), ("\\equiv", "≡"),
        ("\\sim", "∼"), ("\\simeq", "≃"), ("\\propto", "∝"),
        ("\\in", "∈"), ("\\notin", "∉"), ("\\subset", "⊂"), ("\\subseteq", "⊆"),
        ("\\supset", "⊃"), ("\\supseteq", "⊇"), ("\\cup", "∪"), ("\\cap", "∩"),
        ("\\emptyset", "∅"), ("\\varnothing", "∅"),
        ("\\forall", "∀"), ("\\exists", "∃"), ("\\nabla", "∇"), ("\\partial", "∂"),
        ("\\infty", "∞"), ("\\sum", "∑"), ("\\prod", "∏"), ("\\int", "∫"),
        ("\\times", "×"), ("\\cdot", "·"), ("\\pm", "±"), ("\\mp", "∓"),
        ("\\otimes", "⊗"), ("\\oplus", "⊕"), ("\\odot", "⊙"),
        ("\\to", "→"), ("\\rightarrow", "→"), ("\\leftarrow", "←"),
        ("\\Rightarrow", "⇒"), ("\\Leftarrow", "⇐"), ("\\Leftrightarrow", "⇔"),
        ("\\iff", "⟺"), ("\\mapsto", "↦"),
        ("\\langle", "⟨"), ("\\rangle", "⟩"), ("\\| ", "‖"), ("\\|", "‖"),
        ("\\sqrt", "√"), ("\\ell", "ℓ"), ("\\hbar", "ℏ"), ("\\dagger", "†"),
        ("\\dots", "…"), ("\\ldots", "…"), ("\\cdots", "⋯"),
        ("\\,", " "), ("\\;", " "), ("\\:", " "), ("\\!", ""),
        ("\\left", ""), ("\\right", "")
    ]

    static func approximateUnicodeMath(from expandedFormula: String) -> String {
        var result = expandedFormula
        // Sort longest command first implicitly via ordered list; apply replacements safely
        for (cmd, uni) in latexToUnicodeMathMap {
            result = replaceCommandBoundaryAware(in: result, command: cmd, with: uni)
        }
        // Unwrap `\operatorname*{foo}` and `\operatorname{foo}` -> `foo`
        result = unwrapSingleArgCommand(in: result, command: "\\operatorname*")
        result = unwrapSingleArgCommand(in: result, command: "\\operatorname")
        result = unwrapSingleArgCommand(in: result, command: "\\mathbf")
        result = unwrapSingleArgCommand(in: result, command: "\\mathcal")
        result = unwrapSingleArgCommand(in: result, command: "\\mathrm")
        result = unwrapSingleArgCommand(in: result, command: "\\text")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceCommandBoundaryAware(in source: String, command: String, with replacement: String) -> String {
        guard source.contains(command) else { return source }
        // Commands ending in a letter must NOT match prefixes of longer commands (e.g. `\le` inside `\left`!).
        let endsWithLetter = command.last?.isLetter == true
        if !endsWithLetter {
            return source.replacingOccurrences(of: command, with: replacement)
        }
        var out = ""
        out.reserveCapacity(source.count)
        var searchStart = source.startIndex
        while let range = source.range(of: command, range: searchStart..<source.endIndex) {
            out.append(contentsOf: source[searchStart..<range.lowerBound])
            let afterIdx = range.upperBound
            if afterIdx < source.endIndex && source[afterIdx].isLetter {
                out.append(contentsOf: source[range])
            } else {
                out.append(replacement)
            }
            searchStart = afterIdx
        }
        out.append(contentsOf: source[searchStart..<source.endIndex])
        return out
    }

    private static func unwrapSingleArgCommand(in source: String, command: String) -> String {
        guard source.contains(command) else { return source }
        var current = source
        while let cmdRange = current.range(of: command) {
            var cursor = cmdRange.upperBound
            while cursor < current.endIndex && current[cursor] == " " {
                cursor = current.index(after: cursor)
            }
            guard cursor < current.endIndex, current[cursor] == "{" else { break }
            var depth = 1
            var scan = current.index(after: cursor)
            let bodyStart = scan
            var bodyEnd: String.Index? = nil
            while scan < current.endIndex && depth > 0 {
                if current[scan] == "{" { depth += 1 }
                else if current[scan] == "}" {
                    depth -= 1
                    if depth == 0 {
                        bodyEnd = scan
                        break
                    }
                }
                scan = current.index(after: scan)
            }
            guard let validEnd = bodyEnd else { break }
            let inner = String(current[bodyStart..<validEnd])
            let afterClose = current.index(after: validEnd)
            current.replaceSubrange(cmdRange.lowerBound..<afterClose, with: inner)
        }
        return current
    }
}

// MARK: - Internal Bounded Recursive Macro Expander

private struct ExpansionExecutionState {
    let macros: [String: MacroDefinitionRecord]
    let format: ManuscriptFormat
    let maxDepth: Int
    let maxOutputBytes: Int
    let lexer: IncrementalMarkupLexer

    var appliedMacrosInOrder: [String] = []
    var appliedMacroSet: Set<String> = []
    var peakDepth: Int = 0
    var truncatedByLimit: Bool = false
    var issues: [MacroExpansionIssue] = []

    mutating func recordApplied(_ name: String) {
        if !appliedMacroSet.contains(name) {
            appliedMacroSet.insert(name)
            appliedMacrosInOrder.append(name)
        }
    }

    mutating func expandSegment(
        _ input: String,
        depth: Int,
        activeChain: [String]
    ) -> String {
        if depth > peakDepth {
            peakDepth = depth
        }
        if depth > maxDepth {
            truncatedByLimit = true
            let culprit = activeChain.last ?? "macro"
            issues.append(
                MacroExpansionIssue(
                    kind: .maxExpansionDepthExceeded,
                    macroName: culprit,
                    callChain: activeChain,
                    message: "Macro expansion exceeded maximum depth (\(maxDepth)) at '\(culprit)'."
                )
            )
            return input
        }

        let tokens = lexer.tokenize(source: input, format: format, filePath: "<expansion>")
        var out = ""
        out.reserveCapacity(input.utf8.count)
        var idx = 0
        let coreCount = (tokens.last?.kind == .eof) ? (tokens.count - 1) : tokens.count

        while idx < coreCount {
            if out.utf8.count > maxOutputBytes {
                truncatedByLimit = true
                let culprit = activeChain.last ?? "macro"
                issues.append(
                    MacroExpansionIssue(
                        kind: .outputBudgetExceeded,
                        macroName: culprit,
                        callChain: activeChain,
                        message: "Expanded macro output exceeded \(maxOutputBytes) bytes safety cap."
                    )
                )
                // Append unexpanded remainder safely and halt further expansion.
                while idx < coreCount {
                    out.append(tokens[idx].lexeme)
                    idx += 1
                }
                break
            }

            let tok = tokens[idx]

            // LaTeX macro invocation (`\R`, `\norm{x}`, `\R[\mathbb{C}]`)
            if format != .typst, tok.kind == .command, let macro = macros[tok.lexeme] {
                if activeChain.contains(macro.name) {
                    let cycleChain = activeChain + [macro.name]
                    issues.append(
                        MacroExpansionIssue(
                            kind: .recursiveMacroCycle,
                            macroName: macro.name,
                            callChain: cycleChain,
                            message: "Cycle detected while expanding '\(macro.name)': \(cycleChain.joined(separator: " -> "))."
                        )
                    )
                    truncatedByLimit = true
                    out.append(tok.lexeme)
                    idx += 1
                    continue
                }

                idx += 1 // consume macro command token
                let argsResult = consumeLaTeXCallArguments(for: macro, tokens: tokens, index: &idx, coreCount: coreCount, activeChain: activeChain)
                let substituted = substituteLaTeXParameters(body: macro.replacementBody, arguments: argsResult)

                // Note: in LaTeX, a zero-arg control word like `\R x` absorbs trailing spaces ONLY if unbraced;
                // preserving tokens directly keeps math spacing intact (`\mathbb{R}^n` or `\mathbb{R} + 1`).
                recordApplied(macro.name)
                let nextChain = activeChain + [macro.name]
                let recursivelyExpanded = expandSegment(substituted, depth: depth + 1, activeChain: nextChain)
                out.append(recursivelyExpanded)
                continue
            }

            // Typst `#macro(...)` or `#macro` invocation
            if format == .typst, tok.kind == .typstHashKeyword, tok.lexeme.hasPrefix("#") {
                let name = String(tok.lexeme.dropFirst())
                if let macro = macros[name] {
                    if activeChain.contains(macro.name) {
                        let cycleChain = activeChain + [macro.name]
                        issues.append(
                            MacroExpansionIssue(
                                kind: .recursiveMacroCycle,
                                macroName: macro.name,
                                callChain: cycleChain,
                                message: "Cycle detected while expanding Typst '#\(macro.name)': \(cycleChain.joined(separator: " -> "))."
                            )
                        )
                        truncatedByLimit = true
                        out.append(tok.lexeme)
                        idx += 1
                        continue
                    }

                    idx += 1
                    let args = consumeTypstCallArguments(for: macro, tokens: tokens, index: &idx, coreCount: coreCount)
                    let substituted = substituteTypstParameters(macro: macro, arguments: args)
                    recordApplied(macro.name)
                    let nextChain = activeChain + [macro.name]
                    let recursivelyExpanded = expandSegment(substituted, depth: depth + 1, activeChain: nextChain)
                    out.append(recursivelyExpanded)
                    continue
                }
            }

            out.append(tok.lexeme)
            idx += 1
        }

        return out
    }

    private mutating func consumeLaTeXCallArguments(
        for macro: MacroDefinitionRecord,
        tokens: [MarkupToken],
        index: inout Int,
        coreCount: Int,
        activeChain: [String]
    ) -> [String] {
        guard macro.parameterCount > 0 else { return [] }
        var args: [String] = []
        args.reserveCapacity(macro.parameterCount)

        var mandatoryNeeded = macro.parameterCount

        // Handle optional `#1` argument if macro declared `[default]`!
        if let defaultOpt = macro.defaultOptionalArgument {
            let savedIdx = index
            skipHorizontalWhitespace(tokens: tokens, index: &index, coreCount: coreCount)
            if index < coreCount && tokens[index].kind == .leftBracket {
                let optArg = readBracketArg(tokens: tokens, index: &index, coreCount: coreCount, macroName: macro.name, activeChain: activeChain)
                args.append(optArg)
            } else {
                index = savedIdx
                args.append(defaultOpt)
            }
            mandatoryNeeded -= 1
        }

        for _ in 0..<mandatoryNeeded {
            skipHorizontalWhitespace(tokens: tokens, index: &index, coreCount: coreCount)
            guard index < coreCount else {
                issues.append(
                    MacroExpansionIssue(
                        kind: .missingMandatoryArgument,
                        macroName: macro.name,
                        callChain: activeChain + [macro.name],
                        message: "Missing mandatory argument for '\(macro.name)' (expected \(macro.parameterCount) parameters)."
                    )
                )
                args.append("")
                continue
            }

            if tokens[index].kind == .leftBrace {
                let grp = readBraceArg(tokens: tokens, index: &index, coreCount: coreCount, macroName: macro.name, activeChain: activeChain)
                args.append(grp)
            } else {
                // TeX single-token unbraced argument rule (`\vec x` -> `#1 = "x"`)
                let singleTok = tokens[index]
                index += 1
                args.append(singleTok.lexeme)
            }
        }

        return args
    }

    private mutating func skipHorizontalWhitespace(tokens: [MarkupToken], index: inout Int, coreCount: Int) {
        while index < coreCount {
            let t = tokens[index]
            if t.kind == .whitespace && !t.lexeme.contains("\n") && !t.lexeme.contains("\r") {
                index += 1
            } else if t.kind == .comment {
                index += 1
            } else {
                break
            }
        }
    }

    private mutating func readBraceArg(
        tokens: [MarkupToken],
        index: inout Int,
        coreCount: Int,
        macroName: String,
        activeChain: [String]
    ) -> String {
        index += 1 // `{`
        var depth = 1
        var parts: [String] = []
        while index < coreCount && depth > 0 {
            let t = tokens[index]
            if t.kind == .leftBrace {
                depth += 1
                parts.append(t.lexeme)
            } else if t.kind == .rightBrace {
                depth -= 1
                if depth > 0 {
                    parts.append(t.lexeme)
                }
            } else if t.kind != .comment {
                parts.append(t.lexeme)
            }
            index += 1
        }
        if depth > 0 {
            issues.append(
                MacroExpansionIssue(
                    kind: .unclosedMacroArgument,
                    macroName: macroName,
                    callChain: activeChain + [macroName],
                    message: "Unclosed '{' argument when expanding '\(macroName)'."
                )
            )
        }
        return parts.joined()
    }

    private mutating func readBracketArg(
        tokens: [MarkupToken],
        index: inout Int,
        coreCount: Int,
        macroName: String,
        activeChain: [String]
    ) -> String {
        index += 1 // `[`
        var bracketDepth = 1
        var braceDepth = 0
        var parts: [String] = []
        while index < coreCount && bracketDepth > 0 {
            let t = tokens[index]
            if t.kind == .leftBrace {
                braceDepth += 1
                parts.append(t.lexeme)
            } else if t.kind == .rightBrace {
                if braceDepth > 0 { braceDepth -= 1 }
                parts.append(t.lexeme)
            } else if braceDepth == 0 && t.kind == .leftBracket {
                bracketDepth += 1
                parts.append(t.lexeme)
            } else if braceDepth == 0 && t.kind == .rightBracket {
                bracketDepth -= 1
                if bracketDepth > 0 {
                    parts.append(t.lexeme)
                }
            } else if t.kind != .comment {
                parts.append(t.lexeme)
            }
            index += 1
        }
        if bracketDepth > 0 {
            issues.append(
                MacroExpansionIssue(
                    kind: .unclosedMacroArgument,
                    macroName: macroName,
                    callChain: activeChain + [macroName],
                    message: "Unclosed '[' optional argument when expanding '\(macroName)'."
                )
            )
        }
        return parts.joined()
    }

    private func substituteLaTeXParameters(body: String, arguments: [String]) -> String {
        guard !body.isEmpty else { return "" }
        let chars = Array(body)
        var out = ""
        out.reserveCapacity(body.count + arguments.reduce(0) { $0 + $1.count })
        var i = 0
        while i < chars.count {
            if chars[i] == "#" && i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "#" {
                    // Escaped `##` inside nested macro definitions reduces to `#`.
                    out.append("#")
                    i += 2
                    continue
                }
                if let paramIndex = next.wholeNumberValue, paramIndex >= 1 && paramIndex <= 9 {
                    if paramIndex - 1 < arguments.count {
                        out.append(arguments[paramIndex - 1])
                    }
                    i += 2
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private func consumeTypstCallArguments(
        for macro: MacroDefinitionRecord,
        tokens: [MarkupToken],
        index: inout Int,
        coreCount: Int
    ) -> [String] {
        guard macro.parameterCount > 0 else { return [] }
        guard index < coreCount, tokens[index].kind == .punctuation, tokens[index].lexeme == "(" else {
            if let def = macro.defaultOptionalArgument {
                return [def]
            }
            return []
        }
        index += 1 // '('
        var args: [String] = []
        var currentParts: [String] = []
        var depth = 1

        while index < coreCount && depth > 0 {
            let t = tokens[index]
            if t.kind == .punctuation && t.lexeme == "(" {
                depth += 1
                currentParts.append(t.lexeme)
            } else if t.kind == .punctuation && t.lexeme == ")" {
                depth -= 1
                if depth > 0 {
                    currentParts.append(t.lexeme)
                } else {
                    let finalArg = currentParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !finalArg.isEmpty || !args.isEmpty {
                        args.append(finalArg)
                    }
                }
            } else if depth == 1 && t.kind == .punctuation && t.lexeme == "," {
                args.append(currentParts.joined().trimmingCharacters(in: .whitespacesAndNewlines))
                currentParts.removeAll(keepingCapacity: true)
            } else if t.kind != .comment {
                currentParts.append(t.lexeme)
            }
            index += 1
        }
        return args
    }

    private func substituteTypstParameters(macro: MacroDefinitionRecord, arguments: [String]) -> String {
        guard !macro.parameterNames.isEmpty else { return macro.replacementBody }
        var result = macro.replacementBody
        for (idx, paramName) in macro.parameterNames.enumerated() {
            let value: String
            if idx < arguments.count {
                value = arguments[idx]
            } else if idx == 0, let def = macro.defaultOptionalArgument {
                value = def
            } else {
                value = ""
            }
            // Substitute both `#x` (markup/math mode interpolation) and bare identifier `x`
            result = result.replacingOccurrences(of: "#\(paramName)", with: value)
        }
        return result
    }
}
