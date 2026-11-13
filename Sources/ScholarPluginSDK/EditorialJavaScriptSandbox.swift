import Foundation
import JavaScriptCore
import ScholarModels
import ScholarMarkupAST
import ScholarBibAndCSL

// MARK: - Editorial Sandbox Modes, Console Ring Buffer & Execution Telemetry

/// Target publication stage controlling venue-gate strictness (e.g., double-blind anonymization vs. camera-ready).
public enum EditorialVenueAuditMode: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case doubleBlindSubmission = "doubleBlindSubmission"
    case cameraReady = "cameraReady"
    case preprintDraft = "preprintDraft"

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .doubleBlindSubmission: return "Double-Blind Submission"
        case .cameraReady: return "Camera-Ready Proceedings"
        case .preprintDraft: return "Preprint / Working Draft"
        }
    }
}

/// Severity channel for deterministic `console.*` messages captured inside a plugin's `JSContext`.
public enum PluginConsoleLevel: String, Sendable, Codable, Hashable, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// Single structured console message emitted by an editorial JavaScript plugin.
public struct PluginConsoleLogEntry: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let sequence: Int
    public let pluginID: String
    public let level: PluginConsoleLevel
    public let message: String
    public let elapsedMilliseconds: Double

    public init(
        id: UUID = UUID(),
        sequence: Int,
        pluginID: String,
        level: PluginConsoleLevel,
        message: String,
        elapsedMilliseconds: Double
    ) {
        self.id = id
        self.sequence = sequence
        self.pluginID = pluginID
        self.level = level
        self.message = message
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    public var formattedLine: String {
        let ms = String(format: "%.2fms", elapsedMilliseconds)
        return "[\(pluginID) #\(sequence) \(level.rawValue) +\(ms)] \(message)"
    }
}

/// Deterministic fixed-capacity ring buffer retaining the most recent `capacity` console log entries in FIFO order.
public struct PluginConsoleRingBuffer: Sendable, Hashable {
    public let capacity: Int
    private var storage: [PluginConsoleLogEntry?]
    private var writeCursor: Int = 0
    public private(set) var totalRecordedCount: Int = 0

    public init(capacity: Int = 256) {
        let clamped = max(1, capacity)
        self.capacity = clamped
        self.storage = Array(repeating: nil, count: clamped)
    }

    public var evictedCount: Int {
        max(0, totalRecordedCount - capacity)
    }

    public var count: Int {
        min(totalRecordedCount, capacity)
    }

    public mutating func append(
        pluginID: String,
        level: PluginConsoleLevel,
        message: String,
        elapsedMilliseconds: Double
    ) {
        let entry = PluginConsoleLogEntry(
            sequence: totalRecordedCount,
            pluginID: pluginID,
            level: level,
            message: message,
            elapsedMilliseconds: elapsedMilliseconds
        )
        storage[writeCursor] = entry
        writeCursor = (writeCursor + 1) % capacity
        totalRecordedCount += 1
    }

    /// Returns retained entries in deterministic chronological (`sequence` ascending) order.
    public func entries() -> [PluginConsoleLogEntry] {
        guard totalRecordedCount > 0 else { return [] }
        if totalRecordedCount <= capacity {
            return storage[0..<totalRecordedCount].compactMap { $0 }
        }
        var ordered: [PluginConsoleLogEntry] = []
        ordered.reserveCapacity(capacity)
        for offset in 0..<capacity {
            let idx = (writeCursor + offset) % capacity
            if let item = storage[idx] {
                ordered.append(item)
            }
        }
        return ordered
    }

    public mutating func clear() {
        storage = Array(repeating: nil, count: capacity)
        writeCursor = 0
        totalRecordedCount = 0
    }
}

/// Records an unauthorized bridge access attempt blocked by the `ScholarPluginCapability` gate.
public struct PluginCapabilityViolation: Sendable, Codable, Hashable, Equatable {
    public let pluginID: String
    public let requiredCapability: ScholarPluginCapability
    public let attemptedAPI: String

    public init(
        pluginID: String,
        requiredCapability: ScholarPluginCapability,
        attemptedAPI: String
    ) {
        self.pluginID = pluginID
        self.requiredCapability = requiredCapability
        self.attemptedAPI = attemptedAPI
    }
}

/// Sandbox policy and venue parameters supplied to `EditorialJavaScriptSandbox`.
public struct EditorialSandboxConfiguration: Sendable, Codable, Hashable {
    public var consoleRingBufferCapacity: Int
    public var maxFindingsPerPlugin: Int
    public var venueMode: EditorialVenueAuditMode
    public var maxAbstractWords: Int
    public var strictCapabilityEnforcement: Bool
    public var customConfigJSON: String

    public init(
        consoleRingBufferCapacity: Int = 256,
        maxFindingsPerPlugin: Int = 500,
        venueMode: EditorialVenueAuditMode = .doubleBlindSubmission,
        maxAbstractWords: Int = 250,
        strictCapabilityEnforcement: Bool = true,
        customConfigJSON: String = "{}"
    ) {
        self.consoleRingBufferCapacity = max(8, consoleRingBufferCapacity)
        self.maxFindingsPerPlugin = max(1, maxFindingsPerPlugin)
        self.venueMode = venueMode
        self.maxAbstractWords = max(50, maxAbstractWords)
        self.strictCapabilityEnforcement = strictCapabilityEnforcement
        self.customConfigJSON = customConfigJSON
    }

    public static let standard = EditorialSandboxConfiguration()
}

/// Result of running a single `ScholarPluginManifest` inside its isolated `JSVirtualMachine`.
public struct EditorialSinglePluginResult: Sendable, Codable, Hashable {
    public let pluginID: String
    public let pluginName: String
    public let findings: [EditorialAuditFinding]
    public let logs: [PluginConsoleLogEntry]
    public let capabilityViolations: [PluginCapabilityViolation]
    public let executionTimeMs: Double
    public let evictedLogCount: Int

    public init(
        pluginID: String,
        pluginName: String,
        findings: [EditorialAuditFinding],
        logs: [PluginConsoleLogEntry],
        capabilityViolations: [PluginCapabilityViolation],
        executionTimeMs: Double,
        evictedLogCount: Int
    ) {
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.findings = findings
        self.logs = logs
        self.capabilityViolations = capabilityViolations
        self.executionTimeMs = executionTimeMs
        self.evictedLogCount = evictedLogCount
    }
}

// MARK: - Pure-Swift Exact Statistical Special Functions (Lanczos lnΓ + Lentz I_x(a,b) & Q(a,x))

/// Pure-Swift double-precision special functions and exact $p$-value calculators exposed to both Swift and JS plugins.
///
/// Uses:
/// - 9-term Lanczos approximation ($g = 7$) for $\ln\Gamma(z)$ with ~15-digit IEEE 754 precision.
/// - Modified Lentz continued-fraction evaluation (`eps = 1e-14`, `tiny = 1e-30`) for the regularized
///   incomplete beta function $I_x(a, b)$ with symmetry reflection around $\frac{a + 1}{a + b + 2}$.
/// - Series + Legendre continued-fraction split around $x = a + 1$ for the regularized incomplete gamma
///   functions $P(a, x)$ and $Q(a, x)$.
public enum ScholarStatisticalDistributions: Sendable {
    private static let lanczosG: Double = 7.0
    private static let lanczosCoefficients: [Double] = [
        0.99999999999980993227684700473478,
        676.520368121885098567009190444019,
        -1259.13921672240287047156078755283,
        771.3234287776530788486528258894,
        -176.61502916214059906584551354,
        12.507343278686904814458936853,
        -0.13857109526572011689554707,
        9.984369578019570859563e-6,
        1.50563273514931155834e-7
    ]

    private static let halfLogTwoPi: Double = 0.91893853320467274178032973640562
    private static let lentzTiny: Double = 1.0e-30
    private static let lentzEpsilon: Double = 1.0e-14
    private static let maxContinuedFractionIterations: Int = 600

    /// Computes $\ln\Gamma(z)$ for $z > 0$ (and non-integer $z < 0.5$ via Euler's reflection identity).
    public static func lnGamma(_ z: Double) -> Double {
        guard z.isFinite else { return .nan }
        if z <= 0.0 && z == floor(z) {
            return .infinity
        }
        if z < 0.5 {
            // Euler reflection: Γ(z)Γ(1-z) = π / sin(πz)
            let sinTerm = abs(sin(Double.pi * z))
            guard sinTerm > 0 else { return .infinity }
            return log(Double.pi) - log(sinTerm) - lnGamma(1.0 - z)
        }

        let shifted = z - 1.0
        var sum = lanczosCoefficients[0]
        for idx in 1..<lanczosCoefficients.count {
            sum += lanczosCoefficients[idx] / (shifted + Double(idx))
        }
        let t = shifted + lanczosG + 0.5
        return halfLogTwoPi + (shifted + 0.5) * log(t) - t + log(sum)
    }

    /// Computes $\ln B(a, b) = \ln\Gamma(a) + \ln\Gamma(b) - \ln\Gamma(a + b)$ for $a > 0, b > 0$.
    public static func lnBeta(_ a: Double, _ b: Double) -> Double {
        guard a > 0, b > 0, a.isFinite, b.isFinite else { return .nan }
        return lnGamma(a) + lnGamma(b) - lnGamma(a + b)
    }

    /// Computes the regularized incomplete beta function $I_x(a, b)$ for $x \in [0, 1]$ and $a > 0, b > 0$.
    public static func regularizedIncompleteBeta(x: Double, a: Double, b: Double) -> Double {
        guard x.isFinite, a.isFinite, b.isFinite, a > 0.0, b > 0.0 else { return .nan }
        if x < 0.0 || x > 1.0 { return .nan }
        if x == 0.0 { return 0.0 }
        if x == 1.0 { return 1.0 }

        let logPrefactor = a * log(x) + b * log(1.0 - x) - lnBeta(a, b)
        let prefactor = exp(logPrefactor)

        let symmetryThreshold = (a + 1.0) / (a + b + 2.0)
        if x < symmetryThreshold {
            let cf = betaContinuedFractionLentz(x: x, a: a, b: b)
            return min(1.0, max(0.0, (prefactor * cf) / a))
        } else {
            let cf = betaContinuedFractionLentz(x: 1.0 - x, a: b, b: a)
            return min(1.0, max(0.0, 1.0 - (prefactor * cf) / b))
        }
    }

    private static func betaContinuedFractionLentz(x: Double, a: Double, b: Double) -> Double {
        let qab = a + b
        let qap = a + 1.0
        let qam = a - 1.0

        var c = 1.0
        var d = 1.0 - (qab * x) / qap
        if abs(d) < lentzTiny { d = lentzTiny }
        d = 1.0 / d
        var h = d

        for m in 1...maxContinuedFractionIterations {
            let mDouble = Double(m)
            let twoM = 2.0 * mDouble

            // Even step d_{2m}
            let aaEven = (mDouble * (b - mDouble) * x) / ((qam + twoM) * (a + twoM))
            d = 1.0 + aaEven * d
            if abs(d) < lentzTiny { d = lentzTiny }
            c = 1.0 + aaEven / c
            if abs(c) < lentzTiny { c = lentzTiny }
            d = 1.0 / d
            h *= d * c

            // Odd step d_{2m+1}
            let aaOdd = -((a + mDouble) * (qab + mDouble) * x) / ((a + twoM) * (qap + twoM))
            d = 1.0 + aaOdd * d
            if abs(d) < lentzTiny { d = lentzTiny }
            c = 1.0 + aaOdd / c
            if abs(c) < lentzTiny { c = lentzTiny }
            d = 1.0 / d
            let delta = d * c
            h *= delta

            if abs(delta - 1.0) < lentzEpsilon {
                break
            }
        }
        return h
    }

    /// Computes the regularized lower incomplete gamma function $P(a, x) = \frac{\gamma(a, x)}{\Gamma(a)}$.
    public static func regularizedLowerIncompleteGamma(a: Double, x: Double) -> Double {
        guard a.isFinite, x.isFinite, a > 0.0, x >= 0.0 else { return .nan }
        if x == 0.0 { return 0.0 }
        if x < a + 1.0 {
            return lowerGammaSeries(a: a, x: x)
        } else {
            return min(1.0, max(0.0, 1.0 - upperGammaContinuedFractionLentz(a: a, x: x)))
        }
    }

    /// Computes the regularized upper incomplete gamma function $Q(a, x) = \frac{\Gamma(a, x)}{\Gamma(a)}$.
    public static func regularizedUpperIncompleteGamma(a: Double, x: Double) -> Double {
        guard a.isFinite, x.isFinite, a > 0.0, x >= 0.0 else { return .nan }
        if x == 0.0 { return 1.0 }
        if x < a + 1.0 {
            return min(1.0, max(0.0, 1.0 - lowerGammaSeries(a: a, x: x)))
        } else {
            return min(1.0, max(0.0, upperGammaContinuedFractionLentz(a: a, x: x)))
        }
    }

    private static func lowerGammaSeries(a: Double, x: Double) -> Double {
        var ap = a
        var term = 1.0 / a
        var sum = term
        for _ in 1...maxContinuedFractionIterations {
            ap += 1.0
            term *= x / ap
            sum += term
            if abs(term) < abs(sum) * lentzEpsilon {
                break
            }
        }
        let logScale = -x + a * log(x) - lnGamma(a)
        if logScale < -708.0 { return 0.0 }
        return min(1.0, max(0.0, sum * exp(logScale)))
    }

    private static func upperGammaContinuedFractionLentz(a: Double, x: Double) -> Double {
        var b = x + 1.0 - a
        var c = 1.0 / lentzTiny
        var d = b
        if abs(d) < lentzTiny { d = lentzTiny }
        d = 1.0 / d
        var h = d

        for i in 1...maxContinuedFractionIterations {
            let iDouble = Double(i)
            let an = -iDouble * (iDouble - a)
            b += 2.0
            d = an * d + b
            if abs(d) < lentzTiny { d = lentzTiny }
            c = b + an / c
            if abs(c) < lentzTiny { c = lentzTiny }
            d = 1.0 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1.0) < lentzEpsilon {
                break
            }
        }

        let logScale = -x + a * log(x) - lnGamma(a)
        if logScale < -708.0 { return 0.0 }
        return min(1.0, max(0.0, exp(logScale) * h))
    }

    // MARK: Exact Hypothesis-Test p-Value Calculators

    /// Two-tailed Student's $t$-distribution $p$-value: $p = I_{\frac{\nu}{\nu + t^2}}(\nu/2, 1/2)$.
    public static func computeTwoTailedTPValue(tStat: Double, df: Double) -> Double {
        guard tStat.isFinite, df.isFinite, df > 0.0 else { return .nan }
        if tStat == 0.0 { return 1.0 }
        let t2 = tStat * tStat
        let x = df / (df + t2)
        return regularizedIncompleteBeta(x: x, a: 0.5 * df, b: 0.5)
    }

    /// Upper-tail Fisher–Snedecor $F$-distribution $p$-value: $p = I_{\frac{d_2}{d_2 + d_1 F}}(d_2/2, d_1/2)$.
    public static func computeFPValue(fStat: Double, df1: Double, df2: Double) -> Double {
        guard fStat.isFinite, df1.isFinite, df2.isFinite, df1 > 0.0, df2 > 0.0, fStat >= 0.0 else {
            return .nan
        }
        if fStat == 0.0 { return 1.0 }
        let denom = df2 + df1 * fStat
        guard denom > 0.0 else { return 0.0 }
        let x = df2 / denom
        return regularizedIncompleteBeta(x: x, a: 0.5 * df2, b: 0.5 * df1)
    }

    /// Upper-tail Pearson $\chi^2$ $p$-value: $p = Q(k/2, \chi^2/2)$.
    public static func computeChiSquarePValue(chiSq: Double, df: Double) -> Double {
        guard chiSq.isFinite, df.isFinite, df > 0.0, chiSq >= 0.0 else { return .nan }
        if chiSq == 0.0 { return 1.0 }
        return regularizedUpperIncompleteGamma(a: 0.5 * df, x: 0.5 * chiSq)
    }

    /// Two-tailed Pearson correlation $r$ $p$-value via exact $t = r \sqrt{\frac{\text{df}}{1 - r^2}}$ transformation.
    public static func computePearsonRPValue(r: Double, df: Double) -> Double {
        guard r.isFinite, df.isFinite, df > 0.0, abs(r) <= 1.0 else { return .nan }
        if abs(r) == 1.0 { return 0.0 }
        if r == 0.0 { return 1.0 }
        let tStat = abs(r) * sqrt(df / max(1.0e-15, 1.0 - r * r))
        return computeTwoTailedTPValue(tStat: tStat, df: df)
    }

    /// Two-tailed standard normal $Z$-test $p$-value: $p = \operatorname{erfc}(|z| / \sqrt{2}) = Q(1/2, z^2 / 2)$.
    public static func computeTwoTailedZPValue(zStat: Double) -> Double {
        guard zStat.isFinite else { return .nan }
        if zStat == 0.0 { return 1.0 }
        return regularizedUpperIncompleteGamma(a: 0.5, x: 0.5 * zStat * zStat)
    }
}

// MARK: - Precomputed Workspace Snapshot & Annotated Prose Line Model

/// Lexical and structural context for a single manuscript line, enabling JS editorial plugins to skip
/// comments, verbatim blocks, math formulas, and theorem proofs without fragile ad-hoc regexes.
public struct AnnotatedManuscriptLine: Sendable, Codable, Hashable {
    public let lineNumber: Int
    public let rawText: String
    public let proseText: String
    public let commentStrippedText: String
    public let isCommentOnly: Bool
    public let inVerbatimBlock: Bool
    public let inDisplayMathBlock: Bool
    public let inAbstractBlock: Bool
    public let inTheoremOrProofBlock: Bool
    public let enclosingEnvironment: String

    public init(
        lineNumber: Int,
        rawText: String,
        proseText: String,
        commentStrippedText: String,
        isCommentOnly: Bool,
        inVerbatimBlock: Bool,
        inDisplayMathBlock: Bool,
        inAbstractBlock: Bool,
        inTheoremOrProofBlock: Bool,
        enclosingEnvironment: String
    ) {
        self.lineNumber = lineNumber
        self.rawText = rawText
        self.proseText = proseText
        self.commentStrippedText = commentStrippedText
        self.isCommentOnly = isCommentOnly
        self.inVerbatimBlock = inVerbatimBlock
        self.inDisplayMathBlock = inDisplayMathBlock
        self.inAbstractBlock = inAbstractBlock
        self.inTheoremOrProofBlock = inTheoremOrProofBlock
        self.enclosingEnvironment = enclosingEnvironment
    }
}

/// Float/environment summary extracted from the manuscript CST/AST for structural venue checks.
public struct EditorialEnvironmentRecord: Sendable, Codable, Hashable {
    public let name: String
    public let label: String?
    public let caption: String?
    public let hasCaptionCommand: Bool
    public let hasLabelCommand: Bool
    public let filePath: String
    public let startLine: Int
    public let endLine: Int

    public init(
        name: String,
        label: String?,
        caption: String?,
        hasCaptionCommand: Bool,
        hasLabelCommand: Bool,
        filePath: String,
        startLine: Int,
        endLine: Int
    ) {
        self.name = name
        self.label = label
        self.caption = caption
        self.hasCaptionCommand = hasCaptionCommand
        self.hasLabelCommand = hasLabelCommand
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
    }
}

/// Immutable, pre-parsed multi-file manuscript + bibliography snapshot shared safely across multiple JS plugin sandboxes.
public struct PreparedEditorialWorkspace: Sendable {
    public let primaryFilePath: String
    public let orderedFilePaths: [String]
    public let filesByPath: [String: String]
    public let rawLinesByFile: [String: [String]]
    public let annotatedLinesByFile: [String: [AnnotatedManuscriptLine]]
    public let outline: [DocumentOutlineEntry]
    public let citations: [CitationOccurrenceRecord]
    public let labels: [LabelSymbolRecord]
    public let crossReferences: [CrossReferenceOccurrenceRecord]
    public let macrosByName: [String: MacroDefinitionRecord]
    public let environments: [EditorialEnvironmentRecord]
    public let metricsReport: ManuscriptMetricsReport
    public let orderedBibliography: [BibliographyEntry]
    public let bibliographyByKey: [String: BibliographyEntry]

    public init(
        files: [String: String],
        primaryFilePath: String = "main.tex",
        bibliography: [BibliographyEntry] = [],
        lexer: IncrementalMarkupLexer = IncrementalMarkupLexer(configuration: .losslessCST)
    ) {
        let parser = HandwrittenMarkupCSTParser(lexer: lexer)
        let macroEngine = MacroExpansionEngine(lexer: lexer)
        let includeResolver = MultiFileIncludeGraphResolver(
            lexer: lexer,
            parser: parser,
            macroEngine: macroEngine
        )
        let metricsAnalyzer = AcademicManuscriptMetricsAnalyzer(
            lexer: lexer,
            parser: parser,
            includeResolver: includeResolver
        )

        var normalizedFiles: [String: String] = [:]
        for (rawKey, content) in files {
            let cleanKey = Self.normalizePath(rawKey)
            normalizedFiles[cleanKey] = content
        }

        let normalizedPrimary = Self.normalizePath(primaryFilePath)
        let resolvedPrimary: String
        if normalizedFiles[normalizedPrimary] != nil {
            resolvedPrimary = normalizedPrimary
        } else if let firstTex = normalizedFiles.keys.sorted().first(where: { $0.hasSuffix(".tex") || $0.hasSuffix(".typ") }) {
            resolvedPrimary = firstTex
        } else if let anyFirst = normalizedFiles.keys.sorted().first {
            resolvedPrimary = anyFirst
        } else {
            resolvedPrimary = normalizedPrimary
            normalizedFiles[resolvedPrimary] = ""
        }

        self.primaryFilePath = resolvedPrimary
        self.filesByPath = normalizedFiles

        var orderedPaths: [String] = [resolvedPrimary]
        for path in normalizedFiles.keys.sorted() where path != resolvedPrimary {
            orderedPaths.append(path)
        }
        self.orderedFilePaths = orderedPaths

        let workspaceAST = includeResolver.resolveWorkspace(
            rootFilePath: resolvedPrimary,
            files: normalizedFiles
        )

        // Ensure standalone unreferenced files in `normalizedFiles` are also parsed for citations & environments.
        var allParseResults: [MarkupParseResult] = []
        var parsedSet = Set<String>()
        for path in workspaceAST.includeGraph.documentReadingOrder {
            if let pr = workspaceAST.perFileParseResults[path] {
                allParseResults.append(pr)
                parsedSet.insert(path)
            }
        }
        for path in orderedPaths where !parsedSet.contains(path) {
            if let source = normalizedFiles[path] {
                let pr = parser.parse(source: source, filePath: path)
                allParseResults.append(pr)
                parsedSet.insert(path)
            }
        }

        let unifiedSymbols = macroEngine.buildSymbolTable(from: allParseResults)
        let computedMetrics = metricsAnalyzer.analyze(workspace: workspaceAST)

        self.outline = workspaceAST.outline
        self.citations = unifiedSymbols.allCitationOccurrences
        self.labels = unifiedSymbols.allLabelDeclarations
        self.crossReferences = unifiedSymbols.crossReferences
        self.macrosByName = unifiedSymbols.macrosByName
        self.metricsReport = computedMetrics

        var rawLinesMap: [String: [String]] = [:]
        var annotatedMap: [String: [AnnotatedManuscriptLine]] = [:]
        var envRecords: [EditorialEnvironmentRecord] = []

        for path in orderedPaths {
            let text = normalizedFiles[path] ?? ""
            let format = ManuscriptFormat.detect(fromPath: path)
            let splitLines = Self.splitPreservingTrailingLines(text)
            rawLinesMap[path] = splitLines
            annotatedMap[path] = Self.annotateLines(splitLines, format: format)
            envRecords.append(contentsOf: Self.extractEnvironmentRecords(
                lines: splitLines,
                filePath: path,
                astSymbols: unifiedSymbols.environments.filter { Self.normalizePath($0.span.filePath) == path }
            ))
        }

        self.rawLinesByFile = rawLinesMap
        self.annotatedLinesByFile = annotatedMap
        self.environments = envRecords

        self.orderedBibliography = bibliography
        var bibDict: [String: BibliographyEntry] = [:]
        for entry in bibliography {
            bibDict[entry.citeKey] = entry
        }
        self.bibliographyByKey = bibDict
    }

    public static func normalizePath(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("./") {
            trimmed.removeFirst(2)
        }
        if trimmed.hasPrefix("/") {
            trimmed.removeFirst()
        }
        return trimmed.isEmpty ? "main.tex" : trimmed
    }

    private static func splitPreservingTrailingLines(_ source: String) -> [String] {
        if source.isEmpty { return [""] }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: "\n")
    }

    // MARK: Lexical Comment / Math / Verbatim / Environment Line Annotator

    private static let verbatimEnvironments: Set<String> = [
        "verbatim", "verbatim*", "lstlisting", "minted", "alltt", "comment", "filecontents", "filecontents*"
    ]

    private static let displayMathEnvironments: Set<String> = [
        "equation", "equation*", "align", "align*", "gather", "gather*",
        "multline", "multline*", "eqnarray", "eqnarray*", "flalign", "flalign*", "math", "displaymath"
    ]

    private static let theoremEnvironments: Set<String> = [
        "theorem", "theorem*", "lemma", "lemma*", "proposition", "proposition*",
        "corollary", "corollary*", "proof", "definition", "assumption", "remark"
    ]

    private static func annotateLines(_ lines: [String], format: ManuscriptFormat) -> [AnnotatedManuscriptLine] {
        var results: [AnnotatedManuscriptLine] = []
        results.reserveCapacity(lines.count)

        var envStack: [String] = []
        var inTypstCodeFence = false
        var inDisplayDollarBlock = false

        for (idx, rawLine) in lines.enumerated() {
            let lineNum = idx + 1
            let trimmedRaw = rawLine.trimmingCharacters(in: .whitespaces)

            if format != .latex {
                if trimmedRaw.hasPrefix("```") {
                    inTypstCodeFence.toggle()
                    results.append(AnnotatedManuscriptLine(
                        lineNumber: lineNum,
                        rawText: rawLine,
                        proseText: "",
                        commentStrippedText: "",
                        isCommentOnly: false,
                        inVerbatimBlock: true,
                        inDisplayMathBlock: false,
                        inAbstractBlock: false,
                        inTheoremOrProofBlock: false,
                        enclosingEnvironment: "codefence"
                    ))
                    continue
                }
            }

            let activeEnv = envStack.last ?? ""
            let currentlyVerbatim = inTypstCodeFence || envStack.contains(where: { verbatimEnvironments.contains($0) })

            if currentlyVerbatim {
                // Check if `\end{verbatim...}` closes on this line
                updateEnvironmentStack(on: rawLine, stack: &envStack)
                results.append(AnnotatedManuscriptLine(
                    lineNumber: lineNum,
                    rawText: rawLine,
                    proseText: "",
                    commentStrippedText: "",
                    isCommentOnly: false,
                    inVerbatimBlock: true,
                    inDisplayMathBlock: false,
                    inAbstractBlock: envStack.contains("abstract"),
                    inTheoremOrProofBlock: envStack.contains(where: { theoremEnvironments.contains($0) }),
                    enclosingEnvironment: activeEnv
                ))
                continue
            }

            let commentStripped = stripComments(from: rawLine, format: format)
            let trimmedNoComment = commentStripped.trimmingCharacters(in: .whitespaces)
            let isCommentOnly = !trimmedRaw.isEmpty && trimmedNoComment.isEmpty

            updateEnvironmentStack(on: commentStripped, stack: &envStack)

            // Toggle `$$` display math blocks spanning multiple lines
            let doubleDollarCount = countUnescapedDoubleDollars(in: commentStripped)
            let lineStartsOrEndsDisplayDollar = doubleDollarCount > 0
            if doubleDollarCount % 2 == 1 {
                inDisplayDollarBlock.toggle()
            }

            let postEnv = envStack.last ?? activeEnv
            let inVerbatimAfter = envStack.contains(where: { verbatimEnvironments.contains($0) })
            let inDisplayMath = inDisplayDollarBlock
                || lineStartsOrEndsDisplayDollar
                || envStack.contains(where: { displayMathEnvironments.contains($0) })
                || trimmedNoComment.hasPrefix("\\[")
                || trimmedNoComment.hasSuffix("\\]")
            let inAbstract = envStack.contains("abstract")
            let inTheorem = envStack.contains(where: { theoremEnvironments.contains($0) })

            let prose = (isCommentOnly || inVerbatimAfter || inDisplayMath)
                ? ""
                : extractCleanProseLine(from: commentStripped, format: format)

            results.append(AnnotatedManuscriptLine(
                lineNumber: lineNum,
                rawText: rawLine,
                proseText: prose,
                commentStrippedText: commentStripped,
                isCommentOnly: isCommentOnly,
                inVerbatimBlock: inVerbatimAfter,
                inDisplayMathBlock: inDisplayMath,
                inAbstractBlock: inAbstract,
                inTheoremOrProofBlock: inTheorem,
                enclosingEnvironment: postEnv
            ))
        }

        return results
    }

    private static func stripComments(from line: String, format: ManuscriptFormat) -> String {
        let chars = Array(line)
        switch format {
        case .latex:
            for i in 0..<chars.count where chars[i] == "%" {
                var backslashes = 0
                var j = i
                while j > 0 && chars[j - 1] == "\\" {
                    backslashes += 1
                    j -= 1
                }
                if backslashes % 2 == 0 {
                    return String(chars[0..<i])
                }
            }
            return line
        case .typst:
            for i in 0..<(chars.count - 1) where chars[i] == "/" && chars[i + 1] == "/" {
                // Do not strip `https://` or `http://` URLs!
                if i > 0 && chars[i - 1] == ":" { continue }
                return String(chars[0..<i])
            }
            return line
        case .markdown:
            return line
        }
    }

    private static func countUnescapedDoubleDollars(in text: String) -> Int {
        let chars = Array(text)
        var idx = 0
        var count = 0
        while idx + 1 < chars.count {
            if chars[idx] == "$" && chars[idx + 1] == "$" {
                var slashes = 0
                var s = idx
                while s > 0 && chars[s - 1] == "\\" {
                    slashes += 1
                    s -= 1
                }
                if slashes % 2 == 0 {
                    count += 1
                    idx += 2
                    continue
                }
            }
            idx += 1
        }
        return count
    }

    private static func updateEnvironmentStack(on line: String, stack: inout [String]) {
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" {
                let rem = String(chars[i...])
                if rem.hasPrefix("\\begin{") {
                    if let closeBrace = rem.dropFirst(7).firstIndex(of: "}") {
                        let envName = String(rem.dropFirst(7)[..<closeBrace]).trimmingCharacters(in: .whitespaces)
                        if !envName.isEmpty {
                            stack.append(envName)
                        }
                    }
                } else if rem.hasPrefix("\\end{") {
                    if let closeBrace = rem.dropFirst(5).firstIndex(of: "}") {
                        let envName = String(rem.dropFirst(5)[..<closeBrace]).trimmingCharacters(in: .whitespaces)
                        if let lastIdx = stack.lastIndex(of: envName) {
                            stack.remove(at: lastIdx)
                        }
                    }
                }
            }
            i += 1
        }
    }

    /// Replaces inline `$ ... $`, `\(...\)`, `\texttt{...}`, `\verb|...|`, and non-prose citation/ref arguments
    /// while preserving `100\%` -> `100%` and formatting wrappers (`\textbf{word}` -> `word`) for accurate prose scanning.
    private static func extractCleanProseLine(from text: String, format: ManuscriptFormat) -> String {
        guard format == .latex else { return text }

        // Skip pure preamble directives
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let preamblePrefixes = [
            "\\documentclass", "\\usepackage", "\\newcommand", "\\renewcommand",
            "\\providecommand", "\\DeclareMathOperator", "\\bibliographystyle",
            "\\bibliography", "\\input{", "\\include{", "\\maketitle", "\\begin{document}", "\\end{document}"
        ]
        for prefix in preamblePrefixes where trimmed.hasPrefix(prefix) {
            return ""
        }

        let skippedArgCommands: Set<String> = [
            "cite", "citep", "citet", "citealt", "citealp", "parencite", "textcite",
            "autocite", "nocite", "label", "ref", "eqref", "cref", "Cref", "autoref",
            "pageref", "url", "href", "texttt", "includegraphics", "begin", "end",
            "vspace", "hspace"
        ]

        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var idx = 0

        while idx < chars.count {
            let ch = chars[idx]

            // Replace unescaped `%` already stripped, unescape `\%` -> `%`
            if ch == "\\" && idx + 1 < chars.count && chars[idx + 1] == "%" {
                out.append("%")
                idx += 2
                continue
            }

            // Skip `\(...\)` inline math
            if ch == "\\" && idx + 1 < chars.count && chars[idx + 1] == "(" {
                idx += 2
                while idx + 1 < chars.count {
                    if chars[idx] == "\\" && chars[idx + 1] == ")" {
                        idx += 2
                        break
                    }
                    idx += 1
                }
                out.append(" ")
                continue
            }

            // Skip `$ ... $` inline math
            if ch == "$" {
                var slashes = 0
                var s = idx
                while s > 0 && chars[s - 1] == "\\" {
                    slashes += 1
                    s -= 1
                }
                if slashes % 2 == 0 {
                    idx += 1
                    while idx < chars.count {
                        if chars[idx] == "$" {
                            var innerSlashes = 0
                            var k = idx
                            while k > 0 && chars[k - 1] == "\\" {
                                innerSlashes += 1
                                k -= 1
                            }
                            if innerSlashes % 2 == 0 {
                                idx += 1
                                break
                            }
                        }
                        idx += 1
                    }
                    out.append(" ")
                    continue
                }
            }

            // Handle LaTeX commands
            if ch == "\\" {
                idx += 1
                guard idx < chars.count else { break }
                if !chars[idx].isLetter {
                    if chars[idx] == "," || chars[idx] == ";" || chars[idx] == " " {
                        out.append(" ")
                    }
                    idx += 1
                    continue
                }
                let start = idx
                while idx < chars.count && (chars[idx].isLetter || chars[idx] == "*") {
                    idx += 1
                }
                let cmdName = String(chars[start..<idx]).replacingOccurrences(of: "*", with: "")

                if cmdName == "verb" && idx < chars.count {
                    let delim = chars[idx]
                    idx += 1
                    while idx < chars.count && chars[idx] != delim {
                        idx += 1
                    }
                    if idx < chars.count { idx += 1 }
                    out.append(" ")
                    continue
                }

                if skippedArgCommands.contains(cmdName) {
                    while idx < chars.count && (chars[idx] == " " || chars[idx] == "\t") { idx += 1 }
                    while idx < chars.count && chars[idx] == "[" {
                        idx = skipGroup(chars, from: idx, open: "[", close: "]")
                    }
                    if cmdName == "href" {
                        // Skip URL group `{...}` and keep link label `{...}`
                        if idx < chars.count && chars[idx] == "{" {
                            idx = skipGroup(chars, from: idx, open: "{", close: "}")
                        }
                    } else {
                        while idx < chars.count && chars[idx] == "{" {
                            idx = skipGroup(chars, from: idx, open: "{", close: "}")
                        }
                    }
                    out.append(" ")
                    continue
                }

                // For formatting commands like `\textbf{...}`, `\emph{...}`, `\section{...}`, unwrap braces naturally
                continue
            }

            if ch == "~" {
                out.append(" ")
                idx += 1
                continue
            }

            if ch == "{" || ch == "}" {
                idx += 1
                continue
            }

            out.append(ch)
            idx += 1
        }

        // Collapse redundant spaces
        return String(out)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func skipGroup(_ chars: [Character], from start: Int, open: Character, close: Character) -> Int {
        guard start < chars.count, chars[start] == open else { return start }
        var depth = 0
        var i = start
        while i < chars.count {
            if chars[i] == open {
                depth += 1
            } else if chars[i] == close {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return chars.count
    }

    private static func extractEnvironmentRecords(
        lines: [String],
        filePath: String,
        astSymbols: [EnvironmentSymbolRecord]
    ) -> [EditorialEnvironmentRecord] {
        struct OpenEnv {
            let name: String
            let startLine: Int
            var hasCaption: Bool
            var hasLabel: Bool
            var captionExcerpt: String?
            var labelKey: String?
        }

        var records: [EditorialEnvironmentRecord] = []
        var stack: [OpenEnv] = []

        for (i, raw) in lines.enumerated() {
            let lineNo = i + 1
            let clean = stripComments(from: raw, format: ManuscriptFormat.detect(fromPath: filePath))

            if let beginRange = clean.range(of: "\\begin{") {
                let after = clean[beginRange.upperBound...]
                if let endBrace = after.firstIndex(of: "}") {
                    let envName = String(after[..<endBrace]).trimmingCharacters(in: .whitespaces)
                    if !envName.isEmpty && envName != "document" {
                        stack.append(OpenEnv(
                            name: envName,
                            startLine: lineNo,
                            hasCaption: false,
                            hasLabel: false,
                            captionExcerpt: nil,
                            labelKey: nil
                        ))
                    }
                }
            }

            if !stack.isEmpty {
                if let capRange = clean.range(of: "\\caption") {
                    stack[stack.count - 1].hasCaption = true
                    let tail = String(clean[capRange.lowerBound...]).trimmingCharacters(in: .whitespaces)
                    if stack[stack.count - 1].captionExcerpt == nil {
                        stack[stack.count - 1].captionExcerpt = String(tail.prefix(140))
                    }
                }
                if let lblRange = clean.range(of: "\\label{") {
                    stack[stack.count - 1].hasLabel = true
                    let after = clean[lblRange.upperBound...]
                    if let close = after.firstIndex(of: "}") {
                        stack[stack.count - 1].labelKey = String(after[..<close])
                    }
                }
            }

            if let endRange = clean.range(of: "\\end{") {
                let after = clean[endRange.upperBound...]
                if let endBrace = after.firstIndex(of: "}") {
                    let envName = String(after[..<endBrace]).trimmingCharacters(in: .whitespaces)
                    if let matchIdx = stack.lastIndex(where: { $0.name == envName }) {
                        let popped = stack.remove(at: matchIdx)
                        let astMatch = astSymbols.first {
                            $0.name == popped.name && abs($0.span.start.line - popped.startLine) <= 2
                        }
                        records.append(EditorialEnvironmentRecord(
                            name: popped.name,
                            label: popped.labelKey ?? astMatch?.label,
                            caption: popped.captionExcerpt ?? astMatch?.caption,
                            hasCaptionCommand: popped.hasCaption || (astMatch?.caption != nil),
                            hasLabelCommand: popped.hasLabel || (astMatch?.label != nil),
                            filePath: filePath,
                            startLine: popped.startLine,
                            endLine: lineNo
                        ))
                    }
                }
            }
        }

        return records
    }
}

// MARK: - Per-Plugin Isolated JavaScriptCore Sandbox (`EditorialJavaScriptSandbox`)

/// Executes `ScholarPluginManifest` JavaScript plugins inside an isolated per-plugin `JSVirtualMachine` + `JSContext`
/// with capability-gated `scholar.*` native bridges, deterministic console ring buffering, and exact statistical kernels.
public struct EditorialJavaScriptSandbox: Sendable {
    public let configuration: EditorialSandboxConfiguration

    public init(configuration: EditorialSandboxConfiguration = .standard) {
        self.configuration = configuration
    }

    /// Executes a single `ScholarPluginManifest` against raw manuscript text and optional `[BibliographyEntry]` items.
    public func executePlugin(
        _ manifest: ScholarPluginManifest,
        manuscriptSource: String,
        filePath: String = "main.tex",
        bibliography: [BibliographyEntry] = []
    ) throws -> EditorialSinglePluginResult {
        let workspace = PreparedEditorialWorkspace(
            files: [filePath: manuscriptSource],
            primaryFilePath: filePath,
            bibliography: bibliography
        )
        return try executePlugin(manifest, in: workspace)
    }

    /// Executes a single `ScholarPluginManifest` against a multi-file `PreparedEditorialWorkspace`.
    public func executePlugin(
        _ manifest: ScholarPluginManifest,
        in workspace: PreparedEditorialWorkspace
    ) throws -> EditorialSinglePluginResult {
        let startNanos = DispatchTime.now().uptimeNanoseconds

        guard let vm = JSVirtualMachine() else {
            throw ScholarOSError.pluginError(
                pluginID: manifest.id,
                message: "Failed to allocate isolated JSVirtualMachine for plugin '\(manifest.id)'."
            )
        }
        guard let context = JSContext(virtualMachine: vm) else {
            throw ScholarOSError.pluginError(
                pluginID: manifest.id,
                message: "Failed to create JSContext in isolated JSVirtualMachine for plugin '\(manifest.id)'."
            )
        }
        context.name = "ScholarOS.Plugin.\(manifest.id)"

        let session = SandboxBridgeSession(
            manifest: manifest,
            workspace: workspace,
            configuration: configuration,
            startNanos: startNanos
        )

        context.exceptionHandler = { _, exceptionValue in
            let message = Self.formatJSException(exceptionValue)
            session.capturedExceptionMessage = message
            session.recordLog(level: .error, message: "Uncaught JS exception: \(message)")
        }

        installConsoleBridge(into: context, session: session)
        installScholarNativeBridge(into: context, session: session)
        installLegacyHostShim(into: context)

        let sourceURL = URL(string: "scholar-plugin://\(manifest.id)/index.js")
        _ = context.evaluateScript(manifest.scriptSource, withSourceURL: sourceURL)

        if let exceptionMessage = session.capturedExceptionMessage {
            throw ScholarOSError.pluginError(
                pluginID: manifest.id,
                message: exceptionMessage
            )
        }

        // Support declarative `function audit(manuscript, bibliography)` or `function runEditorialPlugin(scholar)`
        // entry points in addition to top-level imperative plugin scripts!
        if let auditFn = context.objectForKeyedSubscript("audit"),
           !auditFn.isUndefined,
           !auditFn.isNull,
           auditFn.ObjectIsCallable(in: context)
        {
            let primaryText = session.capabilities.contains(.readManuscriptAST)
                ? (workspace.filesByPath[workspace.primaryFilePath] ?? "")
                : ""
            let bibArg: Any = session.capabilities.contains(.readBibliography)
                ? session.serializedBibliographyArray()
                : []
            let returned = auditFn.call(withArguments: [primaryText, bibArg])
            if let exceptionMessage = session.capturedExceptionMessage {
                throw ScholarOSError.pluginError(pluginID: manifest.id, message: exceptionMessage)
            }
            if let returnedArray = returned?.toArray() {
                for element in returnedArray {
                    if let dict = element as? [String: Any] {
                        try session.ingestFindingDictionary(dict, context: context)
                    }
                }
            }
        } else if let runFn = context.objectForKeyedSubscript("runEditorialPlugin"),
                  !runFn.isUndefined,
                  !runFn.isNull,
                  runFn.ObjectIsCallable(in: context),
                  let scholarObj = context.objectForKeyedSubscript("scholar")
        {
            _ = runFn.call(withArguments: [scholarObj])
            if let exceptionMessage = session.capturedExceptionMessage {
                throw ScholarOSError.pluginError(pluginID: manifest.id, message: exceptionMessage)
            }
        }

        if let exceptionMessage = session.capturedExceptionMessage {
            throw ScholarOSError.pluginError(pluginID: manifest.id, message: exceptionMessage)
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000.0
        return EditorialSinglePluginResult(
            pluginID: manifest.id,
            pluginName: manifest.name,
            findings: session.findings,
            logs: session.consoleBuffer.entries(),
            capabilityViolations: session.capabilityViolations,
            executionTimeMs: elapsedMs,
            evictedLogCount: session.consoleBuffer.evictedCount
        )
    }

    // MARK: - Native Bridge Wiring

    private func installConsoleBridge(into context: JSContext, session: SandboxBridgeSession) {
        guard let consoleObj = JSValue(newObjectIn: context) else { return }

        let logBlock: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            session.recordLog(level: .info, message: Self.joinJSArguments(args))
        }
        let debugBlock: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            session.recordLog(level: .debug, message: Self.joinJSArguments(args))
        }
        let warnBlock: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            session.recordLog(level: .warn, message: Self.joinJSArguments(args))
        }
        let errorBlock: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            session.recordLog(level: .error, message: Self.joinJSArguments(args))
        }

        consoleObj.setObject(logBlock, forKeyedSubscript: "log" as NSString)
        consoleObj.setObject(logBlock, forKeyedSubscript: "info" as NSString)
        consoleObj.setObject(debugBlock, forKeyedSubscript: "debug" as NSString)
        consoleObj.setObject(warnBlock, forKeyedSubscript: "warn" as NSString)
        consoleObj.setObject(errorBlock, forKeyedSubscript: "error" as NSString)
        context.setObject(consoleObj, forKeyedSubscript: "console" as NSString)
    }

    private func installScholarNativeBridge(into context: JSContext, session: SandboxBridgeSession) {
        guard let scholarObj = JSValue(newObjectIn: context) else { return }

        // 1. Metadata & configuration
        let pluginInfoBlock: @convention(block) () -> [String: Any] = {
            [
                "id": session.manifest.id,
                "name": session.manifest.name,
                "version": session.manifest.version,
                "capabilities": session.manifest.capabilities.map(\.rawValue),
                "venueMode": session.configuration.venueMode.rawValue,
                "maxAbstractWords": session.configuration.maxAbstractWords,
                "primaryFile": session.workspace.primaryFilePath
            ]
        }

        let getConfigBlock: @convention(block) () -> [String: Any] = {
            var base: [String: Any] = [
                "venueMode": session.configuration.venueMode.rawValue,
                "maxAbstractWords": session.configuration.maxAbstractWords
            ]
            if let data = session.configuration.customConfigJSON.data(using: .utf8),
               let custom = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                for (k, v) in custom {
                    base[k] = v
                }
            }
            return base
        }

        // 2. Manuscript AST & Line Readers (gated by `.readManuscriptAST`)
        let listFilesBlock: @convention(block) () -> [String] = {
            guard session.requireCapability(.readManuscriptAST, api: "scholar.listFiles") else {
                return []
            }
            return session.workspace.orderedFilePaths
        }

        let getManuscriptTextBlock: @convention(block) (JSValue?) -> String = { fileArg in
            guard session.requireCapability(.readManuscriptAST, api: "scholar.getManuscriptText") else {
                return ""
            }
            let target = session.resolveFilePathArgument(fileArg)
            return session.workspace.filesByPath[target] ?? ""
        }

        let getManuscriptLinesBlock: @convention(block) (JSValue?) -> [String] = { fileArg in
            guard session.requireCapability(.readManuscriptAST, api: "scholar.getManuscriptLines") else {
                return []
            }
            let target = session.resolveFilePathArgument(fileArg)
            return session.workspace.rawLinesByFile[target] ?? []
        }

        let getAnnotatedLinesBlock: @convention(block) (JSValue?) -> [[String: Any]] = { fileArg in
            guard session.requireCapability(.readManuscriptAST, api: "scholar.getAnnotatedLines") else {
                return []
            }
            let target = session.resolveFilePathArgument(fileArg)
            let lines = session.workspace.annotatedLinesByFile[target] ?? []
            return lines.map { ln in
                [
                    "line": ln.lineNumber,
                    "raw": ln.rawText,
                    "prose": ln.proseText,
                    "commentStripped": ln.commentStrippedText,
                    "isComment": ln.isCommentOnly,
                    "inVerbatim": ln.inVerbatimBlock,
                    "inDisplayMath": ln.inDisplayMathBlock,
                    "inAbstract": ln.inAbstractBlock,
                    "inTheorem": ln.inTheoremOrProofBlock,
                    "environment": ln.enclosingEnvironment
                ]
            }
        }

        let getSectionsBlock: @convention(block) () -> [[String: Any]] = {
            guard session.requireCapability(.readManuscriptAST, api: "scholar.getSections") else {
                return []
            }
            return session.workspace.outline.map { sec in
                var dict: [String: Any] = [
                    "level": sec.level,
                    "numberPrefix": sec.numberPrefix,
                    "title": sec.title,
                    "filePath": sec.filePath,
                    "line": sec.line,
                    "wordCount": sec.wordCountInSection
                ]
                dict["label"] = sec.label ?? NSNull()
                return dict
            }
        }

        let getCitationsBlock: @convention(block) () -> [[String: Any]] = {
            guard session.requireCapability(.readManuscriptAST, api: "scholar.getCitations") else {
                return []
            }
            return session.workspace.citations.map { cite in
                var dict: [String: Any] = [
                    "citeKey": cite.citeKey,
                    "command": cite.command,
                    "filePath": cite.span.filePath,
                    "line": cite.span.start.line,
                    "column": cite.span.start.column
                ]
                dict["sectionTitle"] = cite.enclosingSectionTitle ?? NSNull()
                dict["prenote"] = cite.prenote ?? NSNull()
                dict["postnote"] = cite.postnote ?? NSNull()
                return dict
            }
        }

        let getEnvironmentsBlock: @convention(block) () -> [[String: Any]] = {
            guard session.requireCapability(.readManuscriptAST, api: "scholar.getEnvironments") else {
                return []
            }
            return session.workspace.environments.map { env in
                var dict: [String: Any] = [
                    "name": env.name,
                    "hasCaption": env.hasCaptionCommand,
                    "hasLabel": env.hasLabelCommand,
                    "filePath": env.filePath,
                    "startLine": env.startLine,
                    "endLine": env.endLine
                ]
                dict["label"] = env.label ?? NSNull()
                dict["caption"] = env.caption ?? NSNull()
                return dict
            }
        }

        let getLabelsBlock: @convention(block) () -> [[String: Any]] = {
            guard session.requireCapability(.readManuscriptAST, api: "scholar.getLabels") else {
                return []
            }
            return session.workspace.labels.map { lbl in
                [
                    "key": lbl.key,
                    "category": lbl.category.rawValue,
                    "filePath": lbl.filePath,
                    "line": lbl.span.start.line
                ]
            }
        }

        let getCrossReferencesBlock: @convention(block) () -> [[String: Any]] = {
            guard session.requireCapability(.readManuscriptAST, api: "scholar.getCrossReferences") else {
                return []
            }
            let declaredKeys = Set(session.workspace.labels.map(\.key))
            return session.workspace.crossReferences.map { xref in
                [
                    "command": xref.command,
                    "targetKey": xref.targetKey,
                    "isResolved": declaredKeys.contains(xref.targetKey),
                    "filePath": xref.span.filePath,
                    "line": xref.span.start.line,
                    "column": xref.span.start.column
                ]
            }
        }

        let getMacrosBlock: @convention(block) () -> [[String: Any]] = {
            guard session.requireCapability(.readManuscriptAST, api: "scholar.getMacros") else {
                return []
            }
            return session.workspace.macrosByName.values
                .sorted { $0.name < $1.name }
                .map { mac in
                    [
                        "name": mac.name,
                        "parameterCount": mac.parameterCount,
                        "replacementBody": mac.replacementBody,
                        "filePath": mac.filePath,
                        "line": mac.span.start.line
                    ]
                }
        }

        let expandMacrosBlock: @convention(block) (String) -> String = { snippet in
            guard session.requireCapability(.readManuscriptAST, api: "scholar.expandMacros") else {
                return ""
            }
            let expander = MacroExpansionEngine()
            let format = ManuscriptFormat.detect(fromPath: session.workspace.primaryFilePath)
            return expander.expand(
                text: snippet,
                using: session.workspace.macrosByName,
                format: format
            ).expandedSource
        }

        let getMetricsSummaryBlock: @convention(block) () -> [String: Any] = {
            guard session.requireCapability(.readManuscriptAST, api: "scholar.getMetricsSummary") else {
                return [:]
            }
            let m = session.workspace.metricsReport
            return [
                "bodyProseWordCount": m.bodyProseWordCount,
                "appendixProseWordCount": m.appendixProseWordCount,
                "abstractWordCount": m.abstractWordCount,
                "captionWordCount": m.captionWordCount,
                "headerWordCount": m.headerWordCount,
                "footnoteWordCount": m.footnoteWordCount,
                "totalCountedWords": m.totalCountedWords,
                "characterCountWithSpaces": m.characterCountWithSpaces,
                "characterCountWithoutSpaces": m.characterCountWithoutSpaces,
                "paragraphCount": m.paragraphCount,
                "inlineEquationCount": m.inlineEquationCount,
                "displayEquationCount": m.displayEquationCount,
                "totalEquationCount": m.totalEquationCount,
                "figureCount": m.figureCount,
                "tableCount": m.tableCount,
                "algorithmCount": m.algorithmCount,
                "theoremAndLemmaCount": m.theoremAndLemmaCount,
                "totalCitationOccurrences": m.totalCitationOccurrences,
                "uniqueCitedKeysCount": m.uniqueCitedKeysCount,
                "uniqueCitedKeys": m.uniqueCitedKeys,
                "citationDensityPerThousandWords": m.citationDensityPerThousandWords,
                "estimatedReadingTimeMinutes": m.estimatedReadingTimeMinutes,
                "fleschReadingEase": m.readability.fleschReadingEase,
                "fleschKincaidGradeLevel": m.readability.fleschKincaidGradeLevel
            ]
        }

        // 3. Bibliography & Firewall Readers (gated by `.readBibliography`)
        let getBibliographyBlock: @convention(block) () -> [[String: Any]] = {
            guard session.requireCapability(.readBibliography, api: "scholar.getBibliography") else {
                return []
            }
            return session.serializedBibliographyArray()
        }

        let getEntryBlock: @convention(block) (String) -> Any = { citeKey in
            guard session.requireCapability(.readBibliography, api: "scholar.getEntry") else {
                return NSNull()
            }
            let trimmed = citeKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let entry = session.workspace.bibliographyByKey[trimmed] else {
                return NSNull()
            }
            return SandboxBridgeSession.serializeBibliographyEntry(entry)
        }

        // 4. Exact Pure-Swift Statistical Verification Functions
        let twoTailedTPBlock: @convention(block) (Double, Double) -> Double = { tStat, df in
            ScholarStatisticalDistributions.computeTwoTailedTPValue(tStat: tStat, df: df)
        }

        let fPValueBlock: @convention(block) (Double, Double, Double) -> Double = { fStat, df1, df2 in
            ScholarStatisticalDistributions.computeFPValue(fStat: fStat, df1: df1, df2: df2)
        }

        let chiSqPValueBlock: @convention(block) (Double, Double) -> Double = { chiSq, df in
            ScholarStatisticalDistributions.computeChiSquarePValue(chiSq: chiSq, df: df)
        }

        let pearsonRPValueBlock: @convention(block) (Double, Double) -> Double = { rVal, df in
            ScholarStatisticalDistributions.computePearsonRPValue(r: rVal, df: df)
        }

        let zPValueBlock: @convention(block) (Double) -> Double = { zStat in
            ScholarStatisticalDistributions.computeTwoTailedZPValue(zStat: zStat)
        }

        // 5. Capability-Gated Finding Emission (`.emitEditorialFindings` + `.suggestProseRewrite`)
        let emitFindingBlock: @convention(block) (JSValue) -> String = { payload in
            guard let currentCtx = JSContext.current() else { return "" }
            guard session.requireCapability(.emitEditorialFindings, api: "scholar.emitFinding") else {
                return ""
            }
            guard payload.isObject, let dict = payload.toDictionary() as? [String: Any] else {
                let errMsg = "scholar.emitFinding expects a structured object payload."
                session.capturedExceptionMessage = errMsg
                currentCtx.exception = JSValue(newErrorFromMessage: errMsg, in: currentCtx)
                return ""
            }
            do {
                let created = try session.ingestFindingDictionary(dict, context: currentCtx)
                return created?.id.uuidString ?? ""
            } catch {
                let msg = error.localizedDescription
                session.capturedExceptionMessage = msg
                currentCtx.exception = JSValue(newErrorFromMessage: msg, in: currentCtx)
                return ""
            }
        }

        scholarObj.setObject(pluginInfoBlock, forKeyedSubscript: "pluginInfo" as NSString)
        scholarObj.setObject(getConfigBlock, forKeyedSubscript: "getConfig" as NSString)
        scholarObj.setObject(listFilesBlock, forKeyedSubscript: "listFiles" as NSString)
        scholarObj.setObject(getManuscriptTextBlock, forKeyedSubscript: "getManuscriptText" as NSString)
        scholarObj.setObject(getManuscriptLinesBlock, forKeyedSubscript: "getManuscriptLines" as NSString)
        scholarObj.setObject(getAnnotatedLinesBlock, forKeyedSubscript: "getAnnotatedLines" as NSString)
        scholarObj.setObject(getSectionsBlock, forKeyedSubscript: "getSections" as NSString)
        scholarObj.setObject(getCitationsBlock, forKeyedSubscript: "getCitations" as NSString)
        scholarObj.setObject(getEnvironmentsBlock, forKeyedSubscript: "getEnvironments" as NSString)
        scholarObj.setObject(getLabelsBlock, forKeyedSubscript: "getLabels" as NSString)
        scholarObj.setObject(getCrossReferencesBlock, forKeyedSubscript: "getCrossReferences" as NSString)
        scholarObj.setObject(getMacrosBlock, forKeyedSubscript: "getMacros" as NSString)
        scholarObj.setObject(expandMacrosBlock, forKeyedSubscript: "expandMacros" as NSString)
        scholarObj.setObject(getMetricsSummaryBlock, forKeyedSubscript: "getMetricsSummary" as NSString)
        scholarObj.setObject(getBibliographyBlock, forKeyedSubscript: "getBibliography" as NSString)
        scholarObj.setObject(getEntryBlock, forKeyedSubscript: "getEntry" as NSString)
        scholarObj.setObject(twoTailedTPBlock, forKeyedSubscript: "computeTwoTailedTPValue" as NSString)
        scholarObj.setObject(fPValueBlock, forKeyedSubscript: "computeFPValue" as NSString)
        scholarObj.setObject(chiSqPValueBlock, forKeyedSubscript: "computeChiSquarePValue" as NSString)
        scholarObj.setObject(pearsonRPValueBlock, forKeyedSubscript: "computePearsonRPValue" as NSString)
        scholarObj.setObject(zPValueBlock, forKeyedSubscript: "computeZPValue" as NSString)
        scholarObj.setObject(emitFindingBlock, forKeyedSubscript: "emitFinding" as NSString)

        context.setObject(scholarObj, forKeyedSubscript: "scholar" as NSString)
    }

    /// Provides backwards-compatibility for demo manifests stored in seeded SQLite databases (`ScholarHost.*`).
    private func installLegacyHostShim(into context: JSContext) {
        let shimSource = #"""
        const ScholarHost = {
          scanAbsoluteOverclaims: function(_manuscript) {
            const files = scholar.listFiles();
            const findings = [];
            const rx = /\b(undeniably\s+guarantees|without\s+exception|100\\?%\s+elimination|proves\s+universally)\b/i;
            for (let f = 0; f < files.length; f++) {
              const lines = scholar.getAnnotatedLines(files[f]);
              for (let i = 0; i < lines.length; i++) {
                const ln = lines[i];
                if (ln.isComment || ln.inVerbatim || ln.inDisplayMath) continue;
                const m = rx.exec(ln.prose || ln.commentStripped);
                if (m) {
                  findings.push({
                    severity: "SUBMISSION_BLOCKER",
                    category: "Empirical Overclaim",
                    filePath: files[f],
                    line: ln.line,
                    matchedExcerpt: ln.commentStripped.trim(),
                    explanation: "Non-falsifiable universal quantifier ('" + m[1] + "') overstates empirical benchmark scope.",
                    suggestedRewrite: "Empirically reduces error rates substantially across the evaluated benchmarks."
                  });
                }
              }
            }
            return findings;
          },
          auditMetadataDrift: function(_manuscript, _bib) {
            const cites = scholar.getCitations();
            const seen = {};
            const findings = [];
            for (let i = 0; i < cites.length; i++) {
              const c = cites[i];
              if (seen[c.citeKey]) continue;
              seen[c.citeKey] = true;
              const entry = scholar.getEntry(c.citeKey);
              if (entry && entry.firewallClass === "DRIFT") {
                findings.push({
                  severity: "RIGOR_WARN",
                  category: "Citation Metadata Drift",
                  filePath: c.filePath,
                  line: c.line,
                  matchedExcerpt: "\\" + c.command + "{" + c.citeKey + "}",
                  explanation: "Cited entry '" + c.citeKey + "' carries DRIFT status: " + (entry.firewallAuditNote || "reconcile preprint vs. proceedings metadata.")
                });
              }
            }
            return findings;
          }
        };
        """#
        _ = context.evaluateScript(shimSource)
    }

    private static func joinJSArguments(_ args: [JSValue]) -> String {
        args.map { val in
            if val.isUndefined { return "undefined" }
            if val.isNull { return "null" }
            if val.isString { return val.toString() ?? "" }
            if val.isObject,
               let dict = val.toObject(),
               JSONSerialization.isValidJSONObject(dict),
               let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8)
            {
                return json
            }
            return val.toString() ?? ""
        }.joined(separator: " ")
    }

    private static func formatJSException(_ exceptionValue: JSValue?) -> String {
        guard let exceptionValue else { return "Unknown JavaScript exception" }
        let baseMessage = exceptionValue.toString() ?? "JavaScript runtime error"
        if exceptionValue.isObject,
           let lineVal = exceptionValue.forProperty("line"),
           lineVal.isNumber
        {
            let lineNum = lineVal.toInt32()
            if lineNum > 0 {
                return "\(baseMessage) (at plugin line \(lineNum))"
            }
        }
        return baseMessage
    }
}

// MARK: - Internal Single-Thread Sandbox Bridge Session

private final class SandboxBridgeSession {
    let manifest: ScholarPluginManifest
    let capabilities: Set<ScholarPluginCapability>
    let workspace: PreparedEditorialWorkspace
    let configuration: EditorialSandboxConfiguration
    let startNanos: UInt64

    var consoleBuffer: PluginConsoleRingBuffer
    var findings: [EditorialAuditFinding] = []
    var capabilityViolations: [PluginCapabilityViolation] = []
    var capturedExceptionMessage: String?

    init(
        manifest: ScholarPluginManifest,
        workspace: PreparedEditorialWorkspace,
        configuration: EditorialSandboxConfiguration,
        startNanos: UInt64
    ) {
        self.manifest = manifest
        self.capabilities = Set(manifest.capabilities)
        self.workspace = workspace
        self.configuration = configuration
        self.startNanos = startNanos
        self.consoleBuffer = PluginConsoleRingBuffer(capacity: configuration.consoleRingBufferCapacity)
    }

    func elapsedMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000.0
    }

    func recordLog(level: PluginConsoleLevel, message: String) {
        consoleBuffer.append(
            pluginID: manifest.id,
            level: level,
            message: message,
            elapsedMilliseconds: elapsedMs()
        )
    }

    func requireCapability(_ required: ScholarPluginCapability, api: String) -> Bool {
        if capabilities.contains(required) {
            return true
        }
        let violation = PluginCapabilityViolation(
            pluginID: manifest.id,
            requiredCapability: required,
            attemptedAPI: api
        )
        capabilityViolations.append(violation)
        let message = "Capability '\(required.rawValue)' is required to call \(api) in plugin '\(manifest.id)'."
        recordLog(level: .error, message: message)
        if configuration.strictCapabilityEnforcement {
            capturedExceptionMessage = message
            if let ctx = JSContext.current() {
                ctx.exception = JSValue(newErrorFromMessage: message, in: ctx)
            }
        }
        return false
    }

    func resolveFilePathArgument(_ arg: JSValue?) -> String {
        guard let arg, !arg.isUndefined, !arg.isNull else {
            return workspace.primaryFilePath
        }
        let raw = (arg.toString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw == "undefined" || raw == "null" {
            return workspace.primaryFilePath
        }
        let normalized = PreparedEditorialWorkspace.normalizePath(raw)
        if workspace.filesByPath[normalized] != nil {
            return normalized
        }
        return normalized
    }

    func serializedBibliographyArray() -> [[String: Any]] {
        workspace.orderedBibliography.map(Self.serializeBibliographyEntry)
    }

    static func serializeBibliographyEntry(_ entry: BibliographyEntry) -> [String: Any] {
        var dict: [String: Any] = [
            "citeKey": entry.citeKey,
            "kind": entry.kind.rawValue,
            "title": entry.title,
            "firstAuthor": entry.firstAuthorFamily,
            "authors": entry.authors.map(\.description),
            "venue": entry.venue,
            "firewallClass": entry.firewallClass.rawValue,
            "allowsManuscriptInsertion": entry.firewallClass.allowsManuscriptInsertion,
            "firewallAuditNote": entry.firewallAuditNote,
            "citedByKeys": entry.citedByKeys,
            "referencesKeys": entry.referencesKeys
        ]
        dict["year"] = entry.year ?? NSNull()
        dict["doi"] = entry.doi ?? NSNull()
        dict["arxivID"] = entry.arxivID ?? NSNull()
        dict["pmid"] = entry.pmid ?? NSNull()
        dict["url"] = entry.url ?? NSNull()
        return dict
    }

    @discardableResult
    func ingestFindingDictionary(_ dict: [String: Any], context: JSContext) throws -> EditorialAuditFinding? {
        guard findings.count < configuration.maxFindingsPerPlugin else {
            return nil
        }

        let rawSeverity = (dict["severity"] as? String) ?? EditorialSeverity.note.rawValue
        let severity = Self.parseSeverity(rawSeverity)
        let category = ((dict["category"] as? String) ?? "Editorial Audit")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPath = (dict["filePath"] as? String) ?? workspace.primaryFilePath
        let filePath = PreparedEditorialWorkspace.normalizePath(rawPath)

        let lineNumber: Int
        if let intLine = dict["line"] as? Int {
            lineNumber = max(1, intLine)
        } else if let numLine = dict["line"] as? NSNumber {
            lineNumber = max(1, numLine.intValue)
        } else {
            lineNumber = 1
        }

        let matchedExcerpt = ((dict["matchedExcerpt"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let explanation = ((dict["explanation"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !explanation.isEmpty else {
            throw ScholarOSError.pluginError(
                pluginID: manifest.id,
                message: "scholar.emitFinding requires a non-empty 'explanation' string."
            )
        }

        var suggestedRewrite: String?
        if let rawRewrite = dict["suggestedRewrite"] as? String {
            let trimmedRewrite = rawRewrite.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRewrite.isEmpty {
                if !capabilities.contains(.suggestProseRewrite) {
                    let violation = PluginCapabilityViolation(
                        pluginID: manifest.id,
                        requiredCapability: .suggestProseRewrite,
                        attemptedAPI: "scholar.emitFinding(suggestedRewrite)"
                    )
                    capabilityViolations.append(violation)
                    if configuration.strictCapabilityEnforcement {
                        let msg = "Capability '\(ScholarPluginCapability.suggestProseRewrite.rawValue)' is required to emit 'suggestedRewrite' in plugin '\(manifest.id)'."
                        capturedExceptionMessage = msg
                        context.exception = JSValue(newErrorFromMessage: msg, in: context)
                        throw ScholarOSError.pluginError(pluginID: manifest.id, message: msg)
                    }
                } else {
                    suggestedRewrite = trimmedRewrite
                }
            }
        }

        // Deterministic UUID derivation option when `deterministicKey` is omitted: preserve standard UUID()
        let finding = EditorialAuditFinding(
            pluginID: manifest.id,
            pluginName: manifest.name,
            severity: severity,
            category: category.isEmpty ? "Editorial Audit" : category,
            filePath: filePath,
            line: lineNumber,
            matchedExcerpt: matchedExcerpt.isEmpty ? "(line \(lineNumber))" : matchedExcerpt,
            explanation: explanation,
            suggestedRewrite: suggestedRewrite
        )
        findings.append(finding)
        return finding
    }

    private static func parseSeverity(_ raw: String) -> EditorialSeverity {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch normalized {
        case "SUBMISSION_BLOCKER", "SUBMISSIONBLOCKER", "BLOCKER", "ERROR", "CRITICAL":
            return .submissionBlocker
        case "RIGOR_WARN", "RIGORWARNING", "RIGOR", "WARN", "WARNING":
            return .rigorWarning
        case "STYLE", "STYLE_SUGGESTION", "STYLESUGGESTION", "SUGGESTION":
            return .styleSuggestion
        default:
            return .note
        }
    }
}

private extension JSValue {
    func ObjectIsCallable(in context: JSContext) -> Bool {
        guard isObject else { return false }
        let checkFn = context.evaluateScript("(function(v) { return typeof v === 'function'; })")
        return checkFn?.call(withArguments: [self])?.toBool() ?? false
    }
}

// MARK: - Static Syntax & Capability Manifest Validator (`EditorialPluginSyntaxValidator`)

/// Pre-flight syntax and capability diagnostic report for custom user JavaScript plugins.
public struct EditorialPluginValidationReport: Sendable, Codable, Hashable {
    public let pluginID: String
    public let isSyntaxValid: Bool
    public let syntaxErrorMessage: String?
    public let undeclaredCapabilitiesUsed: [ScholarPluginCapability]
    public let detectedBridgeCalls: [String]
    public let isReadyToExecute: Bool

    public init(
        pluginID: String,
        isSyntaxValid: Bool,
        syntaxErrorMessage: String? = nil,
        undeclaredCapabilitiesUsed: [ScholarPluginCapability] = [],
        detectedBridgeCalls: [String] = []
    ) {
        self.pluginID = pluginID
        self.isSyntaxValid = isSyntaxValid
        self.syntaxErrorMessage = syntaxErrorMessage
        self.undeclaredCapabilitiesUsed = undeclaredCapabilitiesUsed
        self.detectedBridgeCalls = detectedBridgeCalls
        self.isReadyToExecute = isSyntaxValid && undeclaredCapabilitiesUsed.isEmpty
    }
}

/// Validates JavaScript syntax inside a disposable `JSVirtualMachine` without executing side effects,
/// and cross-checks `scholar.*` API calls against declared `ScholarPluginManifest.capabilities`.
public enum EditorialPluginSyntaxValidator: Sendable {
    private static let apiCapabilityTable: [(api: String, capability: ScholarPluginCapability)] = [
        ("scholar.listFiles", .readManuscriptAST),
        ("scholar.getManuscriptText", .readManuscriptAST),
        ("scholar.getManuscriptLines", .readManuscriptAST),
        ("scholar.getAnnotatedLines", .readManuscriptAST),
        ("scholar.getSections", .readManuscriptAST),
        ("scholar.getCitations", .readManuscriptAST),
        ("scholar.getEnvironments", .readManuscriptAST),
        ("scholar.getLabels", .readManuscriptAST),
        ("scholar.getCrossReferences", .readManuscriptAST),
        ("scholar.getMacros", .readManuscriptAST),
        ("scholar.expandMacros", .readManuscriptAST),
        ("scholar.getMetricsSummary", .readManuscriptAST),
        ("scholar.getBibliography", .readBibliography),
        ("scholar.getEntry", .readBibliography),
        ("scholar.emitFinding", .emitEditorialFindings)
    ]

    public static func validate(_ manifest: ScholarPluginManifest) -> EditorialPluginValidationReport {
        guard let vm = JSVirtualMachine(),
              let ctx = JSContext(virtualMachine: vm) else {
            return EditorialPluginValidationReport(
                pluginID: manifest.id,
                isSyntaxValid: false,
                syntaxErrorMessage: "Unable to initialize JSVirtualMachine for syntax check."
            )
        }

        var syntaxErr: String?
        ctx.exceptionHandler = { _, exc in
            syntaxErr = exc?.toString() ?? "JavaScript syntax error"
        }

        // Compile via `new Function(src)` so syntax is verified without invoking runtime code!
        ctx.setObject(manifest.scriptSource, forKeyedSubscript: "__candidateSource" as NSString)
        _ = ctx.evaluateScript("new Function(__candidateSource);")

        let declared = Set(manifest.capabilities)
        var detectedCalls: [String] = []
        var missingCaps: [ScholarPluginCapability] = []

        for pair in apiCapabilityTable where manifest.scriptSource.contains(pair.api) {
            detectedCalls.append(pair.api)
            if !declared.contains(pair.capability) && !missingCaps.contains(pair.capability) {
                missingCaps.append(pair.capability)
            }
        }

        if manifest.scriptSource.contains("suggestedRewrite") && !declared.contains(.suggestProseRewrite) {
            missingCaps.append(.suggestProseRewrite)
        }

        return EditorialPluginValidationReport(
            pluginID: manifest.id,
            isSyntaxValid: syntaxErr == nil,
            syntaxErrorMessage: syntaxErr,
            undeclaredCapabilitiesUsed: missingCaps,
            detectedBridgeCalls: detectedCalls
        )
    }
}
