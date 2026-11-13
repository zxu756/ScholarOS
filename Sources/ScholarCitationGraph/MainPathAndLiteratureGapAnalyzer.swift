import Foundation
import ScholarModels

// MARK: - Search Path Count (SPC) Main-Path Analysis Models

/// Traversal-count weighting variant from Hummon & Doreian (1989) and Batagelj (2003).
public enum TraversalWeightVariant: String, Sendable, Codable, Hashable, CaseIterable {
    /// Search Path Count: counts paths strictly from zero-indegree foundational roots to zero-outdegree frontier sinks.
    case searchPathCountSPC = "SPC (Search Path Count)"
    /// Search Path Link Count: counts paths originating at any ancestor (including intermediate nodes) to frontier sinks.
    case searchPathLinkCountSPLC = "SPLC (Search Path Link Count)"
    /// Search Path Node Pair: counts all paths between every ordered ancestor-descendant pair traversing the link.
    case searchPathNodePairSPNP = "SPNP (Search Path Node Pair)"
}

/// Directed knowledge-diffusion link $(u \to v)$ where older foundational paper $u$ influences newer paper $v$ (i.e. $v$ cites $u$).
public struct MainPathKnowledgeLink: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(foundationalCiteKey)->\(descendantCiteKey)" }
    public let foundationalCiteKey: String
    public let descendantCiteKey: String
    public let foundationalYear: Int
    public let descendantYear: Int
    public let rawTraversalCount: Double
    public let normalizedTraversalShare: Double
    public let isOnGlobalMainPath: Bool
    public let isOnForwardLocalPath: Bool
    public let isKeyRouteBottleneck: Bool

    public init(
        foundationalCiteKey: String,
        descendantCiteKey: String,
        foundationalYear: Int,
        descendantYear: Int,
        rawTraversalCount: Double,
        normalizedTraversalShare: Double,
        isOnGlobalMainPath: Bool,
        isOnForwardLocalPath: Bool,
        isKeyRouteBottleneck: Bool
    ) {
        self.foundationalCiteKey = foundationalCiteKey
        self.descendantCiteKey = descendantCiteKey
        self.foundationalYear = foundationalYear
        self.descendantYear = descendantYear
        self.rawTraversalCount = rawTraversalCount
        self.normalizedTraversalShare = normalizedTraversalShare
        self.isOnGlobalMainPath = isOnGlobalMainPath
        self.isOnForwardLocalPath = isOnForwardLocalPath
        self.isKeyRouteBottleneck = isKeyRouteBottleneck
    }
}

/// Intellectual trajectory chain from foundational origin to contemporary research frontier.
public struct IntellectualTrajectoryRoute: Sendable, Codable, Hashable, Identifiable {
    public var id: String { routeKind + ":" + orderedCiteKeys.joined(separator: "->") }
    public let routeKind: String
    public let orderedCiteKeys: [String]
    public let cumulativeNormalizedSPC: Double
    public let bottleneckCiteKey: String?
    public let startYear: Int
    public let endYear: Int

    public init(
        routeKind: String,
        orderedCiteKeys: [String],
        cumulativeNormalizedSPC: Double,
        bottleneckCiteKey: String?,
        startYear: Int,
        endYear: Int
    ) {
        self.routeKind = routeKind
        self.orderedCiteKeys = orderedCiteKeys
        self.cumulativeNormalizedSPC = cumulativeNormalizedSPC
        self.bottleneckCiteKey = bottleneckCiteKey
        self.startYear = startYear
        self.endYear = endYear
    }
}

/// Complete Hummon & Doreian / Liu & Lu Main-Path Analysis snapshot over a scholarly corpus.
public struct MainPathAnalysisReport: Sendable, Codable, Hashable {
    public let variant: TraversalWeightVariant
    public let totalDAGNodes: Int
    public let totalKnowledgeFlowEdges: Int
    public let feedbackArcsBrokenForDAG: Int
    public let totalSourceToSinkPaths: Double
    public let foundationalOriginCiteKeys: [String]
    public let researchFrontierSinkCiteKeys: [String]
    public let globalMainPath: IntellectualTrajectoryRoute
    public let forwardLocalMainPath: IntellectualTrajectoryRoute
    public let keyRouteTrajectories: [IntellectualTrajectoryRoute]
    public let rankedKnowledgeLinks: [MainPathKnowledgeLink]
    public let nodeTraversalCentralityByCiteKey: [String: Double]

    public init(
        variant: TraversalWeightVariant,
        totalDAGNodes: Int,
        totalKnowledgeFlowEdges: Int,
        feedbackArcsBrokenForDAG: Int,
        totalSourceToSinkPaths: Double,
        foundationalOriginCiteKeys: [String],
        researchFrontierSinkCiteKeys: [String],
        globalMainPath: IntellectualTrajectoryRoute,
        forwardLocalMainPath: IntellectualTrajectoryRoute,
        keyRouteTrajectories: [IntellectualTrajectoryRoute],
        rankedKnowledgeLinks: [MainPathKnowledgeLink],
        nodeTraversalCentralityByCiteKey: [String: Double]
    ) {
        self.variant = variant
        self.totalDAGNodes = totalDAGNodes
        self.totalKnowledgeFlowEdges = totalKnowledgeFlowEdges
        self.feedbackArcsBrokenForDAG = feedbackArcsBrokenForDAG
        self.totalSourceToSinkPaths = totalSourceToSinkPaths
        self.foundationalOriginCiteKeys = foundationalOriginCiteKeys
        self.researchFrontierSinkCiteKeys = researchFrontierSinkCiteKeys
        self.globalMainPath = globalMainPath
        self.forwardLocalMainPath = forwardLocalMainPath
        self.keyRouteTrajectories = keyRouteTrajectories
        self.rankedKnowledgeLinks = rankedKnowledgeLinks
        self.nodeTraversalCentralityByCiteKey = nodeTraversalCentralityByCiteKey
    }
}

// MARK: - Missing Seminal Citation Recommender & Literature Gap Models

public enum MissingCitationCategory: String, Sendable, Codable, Hashable, CaseIterable {
    case foundationalSeminalPillar = "Missing Foundational Pillar"
    case mainPathBackboneMilestone = "Uncited Main-Path Milestone"
    case recentFrontierCompetitor = "Uncited Recent Frontier SOTA"
    case interdisciplinaryStructuralBridge = "Missing Cross-Cluster Bridge"
    case highCouplingSiblingStudy = "High Bibliographic-Coupling Sibling"
}

public enum SuggestedManuscriptSection: String, Sendable, Codable, Hashable, CaseIterable {
    case introduction = "Introduction"
    case relatedWork = "Related Work"
    case methodology = "Methodology & Baselines"
    case discussionAndLimitations = "Discussion & Limitations"
}

/// Actionable recommendation for a high-value uncited paper in the project or discovery corpus.
public struct MissingSeminalCitationRecommendation: Sendable, Codable, Hashable, Identifiable {
    public var id: String { citeKey }
    public let citeKey: String
    public let title: String
    public let authorYearDisplay: String
    public let publicationYear: Int
    public let venue: String
    public let firewallClass: CitationFirewallClass
    public let category: MissingCitationCategory
    public let suggestedSection: SuggestedManuscriptSection
    /// Number of papers *already cited* in the manuscript that cite this candidate.
    public let coCitedByManuscriptRefsCount: Int
    public let supportingManuscriptCiteKeys: [String]
    /// Number of outgoing references shared between this candidate and the manuscript's cited bibliography.
    public let sharedOutgoingReferencesCount: Int
    public let corpusInDegree: Int
    public let mainPathTraversalScore: Double
    public let lexicalRelevanceScore: Double
    public let priorityRecommendationScore: Double
    public let latexCiteSnippet: String
    public let typstCiteSnippet: String
    public let gapExplanation: String

    public init(
        citeKey: String,
        title: String,
        authorYearDisplay: String,
        publicationYear: Int,
        venue: String,
        firewallClass: CitationFirewallClass,
        category: MissingCitationCategory,
        suggestedSection: SuggestedManuscriptSection,
        coCitedByManuscriptRefsCount: Int,
        supportingManuscriptCiteKeys: [String],
        sharedOutgoingReferencesCount: Int,
        corpusInDegree: Int,
        mainPathTraversalScore: Double,
        lexicalRelevanceScore: Double,
        priorityRecommendationScore: Double,
        latexCiteSnippet: String,
        typstCiteSnippet: String,
        gapExplanation: String
    ) {
        self.citeKey = citeKey
        self.title = title
        self.authorYearDisplay = authorYearDisplay
        self.publicationYear = publicationYear
        self.venue = venue
        self.firewallClass = firewallClass
        self.category = category
        self.suggestedSection = suggestedSection
        self.coCitedByManuscriptRefsCount = coCitedByManuscriptRefsCount
        self.supportingManuscriptCiteKeys = supportingManuscriptCiteKeys
        self.sharedOutgoingReferencesCount = sharedOutgoingReferencesCount
        self.corpusInDegree = corpusInDegree
        self.mainPathTraversalScore = mainPathTraversalScore
        self.lexicalRelevanceScore = lexicalRelevanceScore
        self.priorityRecommendationScore = priorityRecommendationScore
        self.latexCiteSnippet = latexCiteSnippet
        self.typstCiteSnippet = typstCiteSnippet
        self.gapExplanation = gapExplanation
    }
}

/// Coverage diagnosis across detected thematic clusters and temporal windows.
public struct LiteratureCoverageGapReport: Sendable, Codable, Hashable {
    public let manuscriptCitedKeys: [String]
    public let corpusSize: Int
    public let manuscriptCoverageRatio: Double
    public let uncitedClusterIDs: [Int]
    public let uncitedClusterLabels: [String]
    public let recencyRatioLast3Years: Double
    public let foundationalMainPathCoverageRatio: Double
    public let recommendations: [MissingSeminalCitationRecommendation]

    public init(
        manuscriptCitedKeys: [String],
        corpusSize: Int,
        manuscriptCoverageRatio: Double,
        uncitedClusterIDs: [Int],
        uncitedClusterLabels: [String],
        recencyRatioLast3Years: Double,
        foundationalMainPathCoverageRatio: Double,
        recommendations: [MissingSeminalCitationRecommendation]
    ) {
        self.manuscriptCitedKeys = manuscriptCitedKeys
        self.corpusSize = corpusSize
        self.manuscriptCoverageRatio = manuscriptCoverageRatio
        self.uncitedClusterIDs = uncitedClusterIDs
        self.uncitedClusterLabels = uncitedClusterLabels
        self.recencyRatioLast3Years = recencyRatioLast3Years
        self.foundationalMainPathCoverageRatio = foundationalMainPathCoverageRatio
        self.recommendations = recommendations
    }
}

// MARK: - Vector SVG & TikZ Network Export Configuration

public struct CitationNetworkExportConfig: Sendable, Codable, Hashable {
    public var canvasWidth: Double
    public var canvasHeight: Double
    public var includeCoCitationEdges: Bool
    public var includeBibliographicCouplingEdges: Bool
    public var highlightMainPathBackbone: Bool
    public var highlightUncitedRecommendations: Bool
    public var maxLabeledNodes: Int

    public init(
        canvasWidth: Double = 1200.0,
        canvasHeight: Double = 800.0,
        includeCoCitationEdges: Bool = true,
        includeBibliographicCouplingEdges: Bool = false,
        highlightMainPathBackbone: Bool = true,
        highlightUncitedRecommendations: Bool = true,
        maxLabeledNodes: Int = 45
    ) {
        self.canvasWidth = max(480.0, canvasWidth)
        self.canvasHeight = max(360.0, canvasHeight)
        self.includeCoCitationEdges = includeCoCitationEdges
        self.includeBibliographicCouplingEdges = includeBibliographicCouplingEdges
        self.highlightMainPathBackbone = highlightMainPathBackbone
        self.highlightUncitedRecommendations = highlightUncitedRecommendations
        self.maxLabeledNodes = max(5, maxLabeledNodes)
    }
}

// MARK: - Main-Path, Missing Seminal Recommender & Vector Exporter Engine

/// Scientometric backbone tracer, missing seminal citation recommender, and SVG/TikZ network vector exporter.
public struct MainPathAndLiteratureGapAnalyzer: Sendable {
    public let currentReferenceYear: Int

    public init(currentReferenceYear: Int = 2026) {
        self.currentReferenceYear = currentReferenceYear
    }

    // MARK: 1. Hummon & Doreian SPC / SPLC / SPNP Main-Path Analysis

    /// Traces the intellectual backbone of `entries` from foundational source papers to frontier sinks via exact topological dynamic programming.
    public func analyzeMainPaths(
        entries: [BibliographyEntry],
        variant: TraversalWeightVariant = .searchPathCountSPC,
        keyRouteTopLinksK: Int = 5
    ) -> MainPathAnalysisReport {
        let sortedEntries = entries.sorted { lhs, rhs in
            let yL = lhs.year ?? currentReferenceYear
            let yR = rhs.year ?? currentReferenceYear
            if yL != yR { return yL < yR }
            return lhs.citeKey < rhs.citeKey
        }
        let n = sortedEntries.count
        guard n > 0 else {
            let emptyRoute = IntellectualTrajectoryRoute(
                routeKind: "Empty",
                orderedCiteKeys: [],
                cumulativeNormalizedSPC: 0.0,
                bottleneckCiteKey: nil,
                startYear: currentReferenceYear,
                endYear: currentReferenceYear
            )
            return MainPathAnalysisReport(
                variant: variant,
                totalDAGNodes: 0,
                totalKnowledgeFlowEdges: 0,
                feedbackArcsBrokenForDAG: 0,
                totalSourceToSinkPaths: 0.0,
                foundationalOriginCiteKeys: [],
                researchFrontierSinkCiteKeys: [],
                globalMainPath: emptyRoute,
                forwardLocalMainPath: emptyRoute,
                keyRouteTrajectories: [],
                rankedKnowledgeLinks: [],
                nodeTraversalCentralityByCiteKey: [:]
            )
        }

        var keyToIdx: [String: Int] = [:]
        for (i, e) in sortedEntries.enumerated() {
            keyToIdx[e.citeKey] = i
        }

        // Build raw knowledge-diffusion edges: if paper `citer` cites `cited`, intellectual influence flows `cited -> citer`!
        var rawKnowledgeEdges = Set<String>()
        var rawOutAdj = [[Int]](repeating: [], count: n)
        for (idx, entry) in sortedEntries.enumerated() {
            for refKey in entry.referencesKeys {
                if let citedIdx = keyToIdx[refKey], citedIdx != idx {
                    let pair = "\(citedIdx)->\(idx)"
                    if rawKnowledgeEdges.insert(pair).inserted {
                        rawOutAdj[citedIdx].append(idx)
                    }
                }
            }
            for citerKey in entry.citedByKeys {
                if let citerIdx = keyToIdx[citerKey], citerIdx != idx {
                    let pair = "\(idx)->\(citerIdx)"
                    if rawKnowledgeEdges.insert(pair).inserted {
                        rawOutAdj[idx].append(citerIdx)
                    }
                }
            }
        }

        // Acyclify knowledge-flow graph chronologically + Kahn/greedy feedback-arc removal so DP is 100% cycle-free
        let (dagOut, dagIn, topoOrder, brokenArcs) = Self.buildChronologicalDAG(
            entries: sortedEntries,
            rawOutAdj: rawOutAdj,
            defaultYear: currentReferenceYear
        )

        let totalDAGEdges = dagOut.reduce(0) { $0 + $1.count }
        let sources = (0..<n).filter { dagIn[$0].isEmpty && !dagOut[$0].isEmpty }
        let sinks = (0..<n).filter { dagOut[$0].isEmpty && !dagIn[$0].isEmpty }

        if totalDAGEdges == 0 {
            let fallbackKeys = sortedEntries.prefix(1).map(\.citeKey)
            let yr = sortedEntries.first?.year ?? currentReferenceYear
            let trivialRoute = IntellectualTrajectoryRoute(
                routeKind: "Isolated Corpus",
                orderedCiteKeys: fallbackKeys,
                cumulativeNormalizedSPC: 0.0,
                bottleneckCiteKey: fallbackKeys.first,
                startYear: yr,
                endYear: yr
            )
            return MainPathAnalysisReport(
                variant: variant,
                totalDAGNodes: n,
                totalKnowledgeFlowEdges: 0,
                feedbackArcsBrokenForDAG: brokenArcs,
                totalSourceToSinkPaths: 0.0,
                foundationalOriginCiteKeys: sortedEntries.map(\.citeKey),
                researchFrontierSinkCiteKeys: sortedEntries.map(\.citeKey),
                globalMainPath: trivialRoute,
                forwardLocalMainPath: trivialRoute,
                keyRouteTrajectories: [],
                rankedKnowledgeLinks: [],
                nodeTraversalCentralityByCiteKey: Dictionary(uniqueKeysWithValues: sortedEntries.map { ($0.citeKey, 0.0) })
            )
        }

        // Forward DP along topological order for N^-(u)
        var nMinus = Array(repeating: 0.0, count: n)
        switch variant {
        case .searchPathCountSPC:
            for s in sources {
                nMinus[s] = 1.0
            }
        case .searchPathLinkCountSPLC, .searchPathNodePairSPNP:
            for u in 0..<n {
                nMinus[u] = 1.0
            }
        }
        for u in topoOrder {
            let incomingFlow = nMinus[u]
            guard incomingFlow > 0.0 else { continue }
            for v in dagOut[u] {
                nMinus[v] += incomingFlow
            }
        }

        // Backward DP along reverse topological order for N^+(v)
        var nPlus = Array(repeating: 0.0, count: n)
        switch variant {
        case .searchPathCountSPC, .searchPathLinkCountSPLC:
            for t in sinks {
                nPlus[t] = 1.0
            }
        case .searchPathNodePairSPNP:
            for v in 0..<n {
                nPlus[v] = 1.0
            }
        }
        for u in topoOrder.reversed() {
            for v in dagOut[u] {
                nPlus[u] += nPlus[v]
            }
        }

        // Total normalizing path volume across the DAG
        let totalPaths: Double
        switch variant {
        case .searchPathCountSPC:
            totalPaths = max(1.0, sources.reduce(0.0) { $0 + nPlus[$1] })
        case .searchPathLinkCountSPLC:
            totalPaths = max(1.0, (0..<n).reduce(0.0) { $0 + (dagOut[$1].isEmpty ? 0.0 : nPlus[$1]) })
        case .searchPathNodePairSPNP:
            totalPaths = max(1.0, (0..<n).reduce(0.0) { $0 + max(0.0, nPlus[$1] - 1.0) })
        }

        // Compute link traversal weights w(u -> v) = N^-(u) * N^+(v)
        var edgeWeightMap: [[Int: (raw: Double, norm: Double)]] = Array(repeating: [:], count: n)
        var allEdgeTuples: [(u: Int, v: Int, raw: Double, norm: Double)] = []
        var nodeTraversal = Array(repeating: 0.0, count: n)

        for u in 0..<n {
            for v in dagOut[u] {
                let rawW = nMinus[u] * nPlus[v]
                let normW = rawW / totalPaths
                edgeWeightMap[u][v] = (rawW, normW)
                allEdgeTuples.append((u, v, rawW, normW))
                nodeTraversal[u] = max(nodeTraversal[u], normW)
                nodeTraversal[v] = max(nodeTraversal[v], normW)
            }
        }

        // 1. Global Maximum-SPC Main Path via exact DAG longest-path DP
        let globalPathIndices = Self.extractGlobalMaxWeightPath(
            nodeCount: n,
            topoOrder: topoOrder,
            dagOut: dagOut,
            edgeWeightMap: edgeWeightMap
        )
        let globalEdgeSet = Self.edgeKeySet(fromPath: globalPathIndices)

        // 2. Hummon & Doreian Forward Local Main Path (greedy maximum outgoing link from best source)
        let forwardLocalIndices = Self.extractForwardLocalPath(
            sources: sources,
            dagOut: dagOut,
            edgeWeightMap: edgeWeightMap
        )
        let forwardEdgeSet = Self.edgeKeySet(fromPath: forwardLocalIndices)

        // 3. Liu & Lu (2012) Key-Route Main Paths around top-K highest-SPC bottleneck links
        allEdgeTuples.sort { a, b in
            if abs(a.norm - b.norm) > 1e-12 { return a.norm > b.norm }
            if a.u != b.u { return a.u < b.u }
            return a.v < b.v
        }
        let topKeyEdges = Array(allEdgeTuples.prefix(max(1, keyRouteTopLinksK)))
        var keyBottleneckEdgeSet = Set<String>()
        var keyRoutes: [IntellectualTrajectoryRoute] = []
        var seenRouteSignatures = Set<String>()

        for item in topKeyEdges {
            keyBottleneckEdgeSet.insert("\(item.u)->\(item.v)")
            let routeNodes = Self.extendKeyRoute(
                seedU: item.u,
                seedV: item.v,
                dagIn: dagIn,
                dagOut: dagOut,
                edgeWeightMap: edgeWeightMap
            )
            let sig = routeNodes.map { String($0) }.joined(separator: "->")
            if seenRouteSignatures.insert(sig).inserted {
                keyRoutes.append(
                    Self.buildTrajectoryModel(
                        kind: "Key-Route Trajectory",
                        indices: routeNodes,
                        entries: sortedEntries,
                        edgeWeightMap: edgeWeightMap,
                        defaultYear: currentReferenceYear
                    )
                )
            }
        }

        let globalRouteModel = Self.buildTrajectoryModel(
            kind: "Global Maximum-SPC Main Path",
            indices: globalPathIndices,
            entries: sortedEntries,
            edgeWeightMap: edgeWeightMap,
            defaultYear: currentReferenceYear
        )
        let forwardRouteModel = Self.buildTrajectoryModel(
            kind: "Forward Local Main Path",
            indices: forwardLocalIndices,
            entries: sortedEntries,
            edgeWeightMap: edgeWeightMap,
            defaultYear: currentReferenceYear
        )

        let links: [MainPathKnowledgeLink] = allEdgeTuples.map { item in
            let ek = "\(item.u)->\(item.v)"
            return MainPathKnowledgeLink(
                foundationalCiteKey: sortedEntries[item.u].citeKey,
                descendantCiteKey: sortedEntries[item.v].citeKey,
                foundationalYear: sortedEntries[item.u].year ?? currentReferenceYear,
                descendantYear: sortedEntries[item.v].year ?? currentReferenceYear,
                rawTraversalCount: item.raw,
                normalizedTraversalShare: item.norm,
                isOnGlobalMainPath: globalEdgeSet.contains(ek),
                isOnForwardLocalPath: forwardEdgeSet.contains(ek),
                isKeyRouteBottleneck: keyBottleneckEdgeSet.contains(ek)
            )
        }

        var nodeMap: [String: Double] = [:]
        for i in 0..<n {
            nodeMap[sortedEntries[i].citeKey] = nodeTraversal[i]
        }

        return MainPathAnalysisReport(
            variant: variant,
            totalDAGNodes: n,
            totalKnowledgeFlowEdges: totalDAGEdges,
            feedbackArcsBrokenForDAG: brokenArcs,
            totalSourceToSinkPaths: totalPaths,
            foundationalOriginCiteKeys: sources.map { sortedEntries[$0].citeKey },
            researchFrontierSinkCiteKeys: sinks.map { sortedEntries[$0].citeKey },
            globalMainPath: globalRouteModel,
            forwardLocalMainPath: forwardRouteModel,
            keyRouteTrajectories: keyRoutes,
            rankedKnowledgeLinks: links,
            nodeTraversalCentralityByCiteKey: nodeMap
        )
    }

    // MARK: 2. Automatic Missing Seminal Citation Recommender & Literature Gap Detector

    /// Parses cited keys directly from LaTeX (`\cite{...}`), Typst (`@key` / `#cite(<key>)`), or Markdown (`[@key]`) manuscript source and recommends uncited seminal, main-path, and recent frontier works.
    public func recommendMissingCitationsForManuscript(
        manuscriptSource: String,
        corpus: [BibliographyEntry],
        maxRecommendations: Int = 15
    ) -> LiteratureCoverageGapReport {
        let extractedKeys = Self.extractCiteKeysFromMarkup(manuscriptSource)
        return recommendMissingCitations(
            citedKeysInManuscript: extractedKeys,
            manuscriptContextText: manuscriptSource,
            corpus: corpus,
            maxRecommendations: maxRecommendations
        )
    }

    /// Recommends high-impact uncited neighbors from `corpus` by fusing co-citation prospect, bibliographic coupling, SPC main-path centrality, Louvain cluster coverage, and lexical relevance.
    public func recommendMissingCitations(
        citedKeysInManuscript: Set<String>,
        manuscriptContextText: String = "",
        corpus: [BibliographyEntry],
        maxRecommendations: Int = 15
    ) -> LiteratureCoverageGapReport {
        guard !corpus.isEmpty else {
            return LiteratureCoverageGapReport(
                manuscriptCitedKeys: citedKeysInManuscript.sorted(),
                corpusSize: 0,
                manuscriptCoverageRatio: 1.0,
                uncitedClusterIDs: [],
                uncitedClusterLabels: [],
                recencyRatioLast3Years: 1.0,
                foundationalMainPathCoverageRatio: 1.0,
                recommendations: []
            )
        }

        let sortedCorpus = corpus.sorted { $0.citeKey < $1.citeKey }
        var entryByKey: [String: BibliographyEntry] = [:]
        for e in sortedCorpus {
            entryByKey[e.citeKey] = e
        }

        // Build complete incoming and outgoing citation sets across corpus
        var outgoingRefs: [String: Set<String>] = [:]
        var incomingCiters: [String: Set<String>] = [:]
        for e in sortedCorpus {
            outgoingRefs[e.citeKey] = []
            incomingCiters[e.citeKey] = []
        }
        for e in sortedCorpus {
            for ref in e.referencesKeys where ref != e.citeKey && entryByKey[ref] != nil {
                outgoingRefs[e.citeKey, default: []].insert(ref)
                incomingCiters[ref, default: []].insert(e.citeKey)
            }
            for citer in e.citedByKeys where citer != e.citeKey && entryByKey[citer] != nil {
                outgoingRefs[citer, default: []].insert(e.citeKey)
                incomingCiters[e.citeKey, default: []].insert(citer)
            }
        }

        let mainPathReport = analyzeMainPaths(entries: sortedCorpus, variant: .searchPathCountSPC)
        let mainPathBackboneSet = Set(mainPathReport.globalMainPath.orderedCiteKeys)

        let louvainEngine = LouvainModularityAndBridgeDetector()
        let partition = louvainEngine.detectLouvainCommunities(entries: sortedCorpus)
        let bridgeProfiles = louvainEngine.analyzeStructuralBridges(entries: sortedCorpus, partition: partition)
        let bridgeSet = Set(bridgeProfiles.filter(\.isStructuralHoleBridge).map(\.citeKey))

        // Aggregate all outgoing references of the manuscript's cited bibliography
        var manuscriptSecondOrderRefs = Set<String>()
        var citedInCorpusCount = 0
        var recentCitedCount = 0
        var citedClusters = Set<Int>()

        for key in citedKeysInManuscript {
            if let entry = entryByKey[key] {
                citedInCorpusCount += 1
                if let yr = entry.year, yr >= (currentReferenceYear - 2) {
                    recentCitedCount += 1
                }
                if let cid = partition.communityByCiteKey[key] {
                    citedClusters.insert(cid)
                }
                if let refs = outgoingRefs[key] {
                    manuscriptSecondOrderRefs.formUnion(refs)
                }
            }
        }

        var uncitedClusterIDs: [Int] = []
        var uncitedClusterLabels: [String] = []
        for comm in partition.communities where !citedClusters.contains(comm.communityID) {
            uncitedClusterIDs.append(comm.communityID)
            uncitedClusterLabels.append(comm.thematicLabel)
        }

        let contextTokens = Set(Self.tokenizeKeywords(manuscriptContextText))
        let maxCorpusInDeg = max(1, incomingCiters.values.map(\.count).max() ?? 1)

        var candidates: [MissingSeminalCitationRecommendation] = []
        for candidate in sortedCorpus {
            // Skip already-cited papers AND firewall-blocked hallucinated/retracted entries!
            if citedKeysInManuscript.contains(candidate.citeKey) {
                continue
            }
            if candidate.firewallClass == .notFound || candidate.firewallClass == .retracted {
                continue
            }

            let citersOfCand = incomingCiters[candidate.citeKey] ?? []
            let supportingManuscriptRefs = citersOfCand.intersection(citedKeysInManuscript).sorted()
            let coCitedCount = supportingManuscriptRefs.count

            let candOutRefs = outgoingRefs[candidate.citeKey] ?? []
            let sharedRefsWithBib = candOutRefs.intersection(citedKeysInManuscript.union(manuscriptSecondOrderRefs)).count

            let inDeg = citersOfCand.count
            let spcScore = mainPathReport.nodeTraversalCentralityByCiteKey[candidate.citeKey] ?? 0.0
            let isBackbone = mainPathBackboneSet.contains(candidate.citeKey)
            let isBridge = bridgeSet.contains(candidate.citeKey)
            let candYear = candidate.year ?? currentReferenceYear
            let isRecentFrontier = candYear >= (currentReferenceYear - 2)

            let candTokens = Set(Self.tokenizeKeywords(candidate.title + " " + (candidate.abstractText ?? "")))
            let lexSim: Double
            if contextTokens.isEmpty || candTokens.isEmpty {
                lexSim = 0.0
            } else {
                let overlap = candTokens.intersection(contextTokens).count
                lexSim = min(1.0, Double(overlap) / Double(min(8, max(1, candTokens.count))))
            }

            let coCiteNorm = citedInCorpusCount > 0
                ? min(1.0, Double(coCitedCount) / Double(max(1, min(5, citedInCorpusCount))))
                : 0.0
            let inDegNorm = Double(inDeg) / Double(maxCorpusInDeg)
            let couplingNorm = min(1.0, Double(sharedRefsWithBib) / 4.0)
            let clusterGapBonus: Double = {
                if let cid = partition.communityByCiteKey[candidate.citeKey], !citedClusters.contains(cid) {
                    return 0.12
                }
                return 0.0
            }()

            let priorityScore = 0.34 * coCiteNorm
                + 0.22 * inDegNorm
                + 0.18 * min(1.0, spcScore * 2.5)
                + 0.14 * couplingNorm
                + 0.12 * lexSim
                + (isBackbone ? 0.10 : 0.0)
                + (isBridge ? 0.07 : 0.0)
                + clusterGapBonus

            // Require meaningful structural or lexical signal so unrelated noise isn't recommended
            guard priorityScore > 0.04 || inDeg >= 1 || coCitedCount >= 1 || sharedRefsWithBib >= 1 || lexSim > 0.15 else {
                continue
            }

            let category: MissingCitationCategory
            let section: SuggestedManuscriptSection
            if isBackbone {
                category = .mainPathBackboneMilestone
                section = candYear <= (currentReferenceYear - 4) ? .introduction : .relatedWork
            } else if coCitedCount >= 2 || (inDeg >= 2 && candYear <= currentReferenceYear - 3) {
                category = .foundationalSeminalPillar
                section = .introduction
            } else if isBridge {
                category = .interdisciplinaryStructuralBridge
                section = .discussionAndLimitations
            } else if isRecentFrontier && (sharedRefsWithBib >= 1 || lexSim >= 0.20) {
                category = .recentFrontierCompetitor
                section = .methodology
            } else {
                category = .highCouplingSiblingStudy
                section = .relatedWork
            }

            let authorYr = "\(candidate.firstAuthorFamily) (\(candYear))"
            var reasons: [String] = []
            if coCitedCount > 0 {
                let preview = supportingManuscriptRefs.prefix(3).joined(separator: ", ")
                reasons.append("cited by \(coCitedCount) of your existing references (\(preview))")
            }
            if isBackbone {
                reasons.append(String(format: "lies on the global SPC intellectual main path (SPC = %.2f)", spcScore))
            }
            if inDeg > 0 {
                reasons.append("corpus in-degree = \(inDeg)")
            }
            if sharedRefsWithBib > 0 {
                reasons.append("shares \(sharedRefsWithBib) bibliographic coupling reference(s)")
            }
            if candidate.firewallClass == .unverified {
                reasons.append("verify DOI before insertion")
            }
            let explanation = reasons.isEmpty
                ? "Thematically aligned \(candYear) reference in \(section.rawValue)."
                : "Recommended for \(section.rawValue): " + reasons.joined(separator: "; ") + "."

            candidates.append(
                MissingSeminalCitationRecommendation(
                    citeKey: candidate.citeKey,
                    title: candidate.title,
                    authorYearDisplay: authorYr,
                    publicationYear: candYear,
                    venue: candidate.venue,
                    firewallClass: candidate.firewallClass,
                    category: category,
                    suggestedSection: section,
                    coCitedByManuscriptRefsCount: coCitedCount,
                    supportingManuscriptCiteKeys: supportingManuscriptRefs,
                    sharedOutgoingReferencesCount: sharedRefsWithBib,
                    corpusInDegree: inDeg,
                    mainPathTraversalScore: spcScore,
                    lexicalRelevanceScore: lexSim,
                    priorityRecommendationScore: priorityScore,
                    latexCiteSnippet: "\\cite{\(candidate.citeKey)}",
                    typstCiteSnippet: "@\(candidate.citeKey)",
                    gapExplanation: explanation
                )
            )
        }

        candidates.sort { lhs, rhs in
            if abs(lhs.priorityRecommendationScore - rhs.priorityRecommendationScore) > 1e-9 {
                return lhs.priorityRecommendationScore > rhs.priorityRecommendationScore
            }
            if lhs.coCitedByManuscriptRefsCount != rhs.coCitedByManuscriptRefsCount {
                return lhs.coCitedByManuscriptRefsCount > rhs.coCitedByManuscriptRefsCount
            }
            return lhs.citeKey < rhs.citeKey
        }

        let backboneCoveredCount = mainPathBackboneSet.intersection(citedKeysInManuscript).count
        let backboneCoverage = mainPathBackboneSet.isEmpty
            ? 1.0
            : Double(backboneCoveredCount) / Double(mainPathBackboneSet.count)
        let recencyRatio = citedInCorpusCount > 0
            ? Double(recentCitedCount) / Double(citedInCorpusCount)
            : 0.0
        let coverageRatio = Double(citedInCorpusCount) / Double(sortedCorpus.count)

        return LiteratureCoverageGapReport(
            manuscriptCitedKeys: citedKeysInManuscript.sorted(),
            corpusSize: sortedCorpus.count,
            manuscriptCoverageRatio: coverageRatio,
            uncitedClusterIDs: uncitedClusterIDs,
            uncitedClusterLabels: uncitedClusterLabels,
            recencyRatioLast3Years: recencyRatio,
            foundationalMainPathCoverageRatio: backboneCoverage,
            recommendations: Array(candidates.prefix(max(1, maxRecommendations)))
        )
    }

    // MARK: 3. Interactive Vector SVG & LaTeX TikZ Citation Network Exporters

    /// Exports an interactive standalone SVG citation network featuring community color halos, curved Bezier directed edges, highlighted SPC main-path spine, double-ring bridge papers, and hover tooltips.
    public func exportInteractiveCitationNetworkSVG(
        snapshot: CitationKnowledgeGraphSnapshot,
        mainPathReport: MainPathAnalysisReport? = nil,
        gapReport: LiteratureCoverageGapReport? = nil,
        config: CitationNetworkExportConfig = CitationNetworkExportConfig()
    ) -> String {
        let w = Int(config.canvasWidth.rounded())
        let h = Int(config.canvasHeight.rounded())
        let palette = [
            "#1D5B4C", "#2E5EAA", "#9A4C2E", "#6B4E8E",
            "#2B7A78", "#A36A1E", "#8A334A", "#3D5A80"
        ]

        var nodeByKey: [String: CitationGraphNode] = [:]
        for node in snapshot.nodes {
            nodeByKey[node.citeKey] = node
        }

        var mainPathDirectedPairs = Set<String>()
        if config.highlightMainPathBackbone, let mp = mainPathReport {
            let keys = mp.globalMainPath.orderedCiteKeys
            if keys.count >= 2 {
                for idx in 0..<(keys.count - 1) {
                    // Main path flows foundational -> descendant, while citation edge is descendant -> foundational; match either orientation!
                    mainPathDirectedPairs.insert("\(keys[idx])->\(keys[idx + 1])")
                    mainPathDirectedPairs.insert("\(keys[idx + 1])->\(keys[idx])")
                }
            }
        }

        let recommendedKeys = config.highlightUncitedRecommendations
            ? Set(gapReport?.recommendations.prefix(8).map(\.citeKey) ?? [])
            : Set<String>()

        var svg: [String] = []
        svg.append("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(w) \(h)\" width=\"\(w)\" height=\"\(h)\" font-family=\"ui-sans-serif, -apple-system, BlinkMacSystemFont, sans-serif\">")
        svg.append("  <style>")
        svg.append("    .scholar-node { cursor: pointer; transition: opacity 0.18s ease; }")
        svg.append("    .scholar-node:hover circle.primary-ring { stroke-width: 3.2px; filter: brightness(1.08); }")
        svg.append("    .scholar-edge { pointer-events: stroke; }")
        svg.append("    .scholar-edge:hover { stroke-opacity: 0.95; stroke-width: 2.6px; }")
        svg.append("  </style>")
        svg.append("  <rect width=\"\(w)\" height=\"\(h)\" fill=\"#F9F7F1\" rx=\"10\"/>")
        svg.append("  <defs>")
        svg.append("    <marker id=\"cite-arrow\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"6\" markerHeight=\"6\" orient=\"auto-start-reverse\">")
        svg.append("      <path d=\"M 0 1.5 L 10 5 L 0 8.5 z\" fill=\"#5C6460\"/>")
        svg.append("    </marker>")
        svg.append("    <marker id=\"mainpath-arrow\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\">")
        svg.append("      <path d=\"M 0 1 L 10 5 L 0 9 z\" fill=\"#B8332A\"/>")
        svg.append("    </marker>")
        svg.append("  </defs>")

        // 1. Soft Community Centroid Halos
        var nodesByCluster: [Int: [CitationGraphNode]] = [:]
        for n in snapshot.nodes {
            nodesByCluster[n.clusterIndex, default: []].append(n)
        }
        for (cid, members) in nodesByCluster.sorted(by: { $0.key < $1.key }) where members.count >= 2 {
            let cx = members.reduce(0.0) { $0 + $1.x } / Double(members.count)
            let cy = members.reduce(0.0) { $0 + $1.y } / Double(members.count)
            let maxDist = members.map { (($0.x - cx) * ($0.x - cx) + ($0.y - cy) * ($0.y - cy)).squareRoot() }.max() ?? 40.0
            let radius = min(240.0, max(54.0, maxDist + 36.0))
            let color = palette[abs(cid) % palette.count]
            svg.append(String(format: "  <circle cx=\"%.1f\" cy=\"%.1f\" r=\"%.1f\" fill=\"%@\" fill-opacity=\"0.055\" stroke=\"%@\" stroke-opacity=\"0.18\" stroke-dasharray=\"4 4\"/>", cx, cy, radius, color, color))
            if let label = snapshot.clusterLabels[cid] {
                svg.append(String(format: "  <text x=\"%.1f\" y=\"%.1f\" text-anchor=\"middle\" font-size=\"11\" font-weight=\"600\" fill=\"%@\" fill-opacity=\"0.72\">%@</text>", cx, max(20.0, cy - radius + 16.0), color, Self.escapeXML(label)))
            }
        }

        // 2. Edges (Curved Quadratic Bezier Paths)
        for edge in snapshot.edges {
            if edge.kind == .coCitation && !config.includeCoCitationEdges { continue }
            if edge.kind == .bibliographicCoupling && !config.includeBibliographicCouplingEdges { continue }
            guard let src = nodeByKey[edge.sourceCiteKey],
                  let dst = nodeByKey[edge.targetCiteKey] else { continue }

            let isBackbone = (edge.kind == .directCitation)
                && mainPathDirectedPairs.contains("\(edge.sourceCiteKey)->\(edge.targetCiteKey)")

            let mx = 0.5 * (src.x + dst.x)
            let my = 0.5 * (src.y + dst.y)
            let dx = dst.x - src.x
            let dy = dst.y - src.y
            let len = max(1.0, (dx * dx + dy * dy).squareRoot())
            // Subtle normal offset for visual separation of bidirectional/dense links
            let curvature = min(28.0, len * 0.12)
            let ctrlX = mx - (dy / len) * curvature
            let ctrlY = my + (dx / len) * curvature

            if isBackbone {
                svg.append(
                    String(
                        format: "  <path class=\"scholar-edge\" d=\"M %.1f %.1f Q %.1f %.1f %.1f %.1f\" fill=\"none\" stroke=\"#B8332A\" stroke-width=\"2.8\" stroke-opacity=\"0.92\" marker-end=\"url(#mainpath-arrow)\"/>",
                        src.x, src.y, ctrlX, ctrlY, dst.x, dst.y
                    )
                )
            } else {
                let strokeDash: String
                let strokeColor: String
                let opacity: Double
                let markerAttr: String
                switch edge.kind {
                case .directCitation:
                    strokeDash = ""
                    strokeColor = "#5C6460"
                    opacity = 0.44
                    markerAttr = " marker-end=\"url(#cite-arrow)\""
                case .coCitation:
                    strokeDash = " stroke-dasharray=\"4 3\""
                    strokeColor = "#7B6D54"
                    opacity = 0.28
                    markerAttr = ""
                case .bibliographicCoupling:
                    strokeDash = " stroke-dasharray=\"2 3\""
                    strokeColor = "#6A7B8A"
                    opacity = 0.24
                    markerAttr = ""
                }
                svg.append(
                    String(
                        format: "  <path class=\"scholar-edge\" d=\"M %.1f %.1f Q %.1f %.1f %.1f %.1f\" fill=\"none\" stroke=\"%@\" stroke-width=\"1.25\" stroke-opacity=\"%.2f\"%@%@/>",
                        src.x, src.y, ctrlX, ctrlY, dst.x, dst.y, strokeColor, opacity, strokeDash, markerAttr
                    )
                )
            }
        }

        // 3. Nodes (PageRank-scaled radius, double-ring bridge badge, dashed gold missing-recommendation halo)
        let sortedForLabelPriority = snapshot.nodes.sorted { a, b in
            if abs(a.pageRank - b.pageRank) > 1e-9 { return a.pageRank > b.pageRank }
            return a.inDegree > b.inDegree
        }
        let labeledSet = Set(sortedForLabelPriority.prefix(config.maxLabeledNodes).map(\.citeKey))

        for node in snapshot.nodes {
            let fill = palette[abs(node.clusterIndex) % palette.count]
            let r = min(22.0, max(6.5, 6.5 + (node.pageRank * Double(max(4, snapshot.nodes.count))).squareRoot() * 4.2))
            let spcVal = mainPathReport?.nodeTraversalCentralityByCiteKey[node.citeKey] ?? 0.0
            let tooltip = "\(node.authorYearLabel) — \(node.title) [in=\(node.inDegree), out=\(node.outDegree), PR=\(String(format: "%.3f", node.pageRank)), SPC=\(String(format: "%.2f", spcVal))]"

            svg.append("  <g class=\"scholar-node\" data-citekey=\"\(Self.escapeXML(node.citeKey))\">")
            svg.append("    <title>\(Self.escapeXML(tooltip))</title>")

            if recommendedKeys.contains(node.citeKey) {
                svg.append(String(format: "    <circle cx=\"%.1f\" cy=\"%.1f\" r=\"%.1f\" fill=\"none\" stroke=\"#D9822B\" stroke-width=\"2.2\" stroke-dasharray=\"3 2\"/>", node.x, node.y, r + 5.5))
            }
            if node.isBridgePaper {
                svg.append(String(format: "    <circle cx=\"%.1f\" cy=\"%.1f\" r=\"%.1f\" fill=\"none\" stroke=\"#1B2420\" stroke-width=\"1.6\"/>", node.x, node.y, r + 3.0))
            }

            svg.append(String(format: "    <circle class=\"primary-ring\" cx=\"%.1f\" cy=\"%.1f\" r=\"%.1f\" fill=\"%@\" stroke=\"#FFFFFF\" stroke-width=\"1.6\"/>", node.x, node.y, r, fill))

            if labeledSet.contains(node.citeKey) {
                svg.append(
                    String(
                        format: "    <text x=\"%.1f\" y=\"%.1f\" text-anchor=\"middle\" font-size=\"10.5\" font-weight=\"600\" fill=\"#1E2421\">%@</text>",
                        node.x, node.y - r - 5.0, Self.escapeXML(node.authorYearLabel)
                    )
                )
            }
            svg.append("  </g>")
        }

        // 4. Footer Legend
        svg.append("  <rect x=\"18\" y=\"\(h - 38)\" width=\"560\" height=\"24\" rx=\"4\" fill=\"#EFECE3\" fill-opacity=\"0.92\"/>")
        svg.append("  <text x=\"28\" y=\"\(h - 22)\" font-size=\"10.5\" fill=\"#333835\">Crimson Spine: SPC Main Path · Double Ring: Structural Bridge · Dashed Amber: Recommended Seminal Gap</text>")
        svg.append("</svg>")
        return svg.joined(separator: "\n")
    }

    /// Exports a publication-ready LaTeX `tikzpicture` citation & main-path diagram suitable for direct inclusion in academic surveys.
    public func exportLaTeXTikZCitationNetwork(
        snapshot: CitationKnowledgeGraphSnapshot,
        mainPathReport: MainPathAnalysisReport? = nil,
        widthCentimeters: Double = 14.5,
        heightCentimeters: Double = 9.5
    ) -> String {
        guard !snapshot.nodes.isEmpty else {
            return "% Empty citation graph\n\\begin{tikzpicture}\\node {No bibliography entries};\\end{tikzpicture}"
        }

        let minX = snapshot.nodes.map(\.x).min() ?? 0.0
        let maxX = snapshot.nodes.map(\.x).max() ?? 100.0
        let minY = snapshot.nodes.map(\.y).min() ?? 0.0
        let maxY = snapshot.nodes.map(\.y).max() ?? 100.0
        let spanX = max(1.0, maxX - minX)
        let spanY = max(1.0, maxY - minY)

        var mainPathEdges = Set<String>()
        if let mp = mainPathReport {
            let keys = mp.globalMainPath.orderedCiteKeys
            if keys.count >= 2 {
                for idx in 0..<(keys.count - 1) {
                    mainPathEdges.insert("\(keys[idx])->\(keys[idx + 1])")
                    mainPathEdges.insert("\(keys[idx + 1])->\(keys[idx])")
                }
            }
        }

        var tikz: [String] = []
        tikz.append("% Generated by ScholarOS MainPathAndLiteratureGapAnalyzer")
        tikz.append("\\begin{tikzpicture}[")
        tikz.append("  citenode/.style={circle, draw=black!75, fill=teal!14, minimum size=5.5pt, inner sep=1.2pt},")
        tikz.append("  bridgenode/.style={circle, double, draw=black!85, fill=orange!20, minimum size=6.5pt, inner sep=1.4pt},")
        tikz.append("  citeedge/.style={-Latex, thin, draw=black!40},")
        tikz.append("  mainpathedge/.style={-Latex, very thick, draw=red!75!black}")
        tikz.append("]")

        var safeIDByKey: [String: String] = [:]
        for (idx, node) in snapshot.nodes.enumerated() {
            let safeID = "n\(idx)"
            safeIDByKey[node.citeKey] = safeID
            let tx = ((node.x - minX) / spanX) * widthCentimeters
            // Invert Y from screen top-down to TikZ bottom-up coordinates
            let ty = ((maxY - node.y) / spanY) * heightCentimeters
            let style = node.isBridgePaper ? "bridgenode" : "citenode"
            let label = Self.escapeLaTeX(node.authorYearLabel)
            tikz.append(String(format: "  \\node[%@, label={[font=\\tiny]above:%@}] (%@) at (%.2f, %.2f) {};", style, label, safeID, tx, ty))
        }

        for edge in snapshot.edges where edge.kind == .directCitation {
            guard let uID = safeIDByKey[edge.sourceCiteKey],
                  let vID = safeIDByKey[edge.targetCiteKey] else { continue }
            let isMain = mainPathEdges.contains("\(edge.sourceCiteKey)->\(edge.targetCiteKey)")
            let eStyle = isMain ? "mainpathedge" : "citeedge"
            tikz.append("  \\draw[\(eStyle)] (\(uID)) -- (\(vID));")
        }

        tikz.append("\\end{tikzpicture}")
        return tikz.joined(separator: "\n")
    }

    // MARK: - Internal DAG, Dynamic-Programming & Markup Extraction Helpers

    private static func buildChronologicalDAG(
        entries: [BibliographyEntry],
        rawOutAdj: [[Int]],
        defaultYear: Int
    ) -> (dagOut: [[Int]], dagIn: [[Int]], topoOrder: [Int], brokenArcs: Int) {
        let n = entries.count
        // Establish strict total order by (publicationYear ASC, outDegree DESC, citeKey ASC)
        // Any edge violating chronological order (younger -> strictly older) or mutual same-year cycle is reversed/dropped if cyclic.
        var rankOfNode = Array(repeating: 0, count: n)
        let orderedIndices = (0..<n).sorted { a, b in
            let ya = entries[a].year ?? defaultYear
            let yb = entries[b].year ?? defaultYear
            if ya != yb { return ya < yb }
            if rawOutAdj[a].count != rawOutAdj[b].count { return rawOutAdj[a].count > rawOutAdj[b].count }
            return entries[a].citeKey < entries[b].citeKey
        }
        for (pos, nodeIdx) in orderedIndices.enumerated() {
            rankOfNode[nodeIdx] = pos
        }

        // First run Kahn's algorithm on edges respecting chronological non-decrease (year[u] <= year[v]);
        // only drop tie-year edges if they participate in an actual directed cycle!
        var candidateOut = [[Int]](repeating: [], count: n)
        var inDeg = Array(repeating: 0, count: n)
        var brokenArcs = 0

        for u in 0..<n {
            let yu = entries[u].year ?? defaultYear
            for v in rawOutAdj[u] where u != v {
                let yv = entries[v].year ?? defaultYear
                if yu < yv || (yu == yv && rankOfNode[u] < rankOfNode[v]) {
                    candidateOut[u].append(v)
                    inDeg[v] += 1
                } else if yu == yv && !rawOutAdj[v].contains(u) {
                    // Same-year asymmetric citation where rank order happened to be inverted: check reachability before adding
                    if !isReachable(from: v, to: u, adj: candidateOut) {
                        candidateOut[u].append(v)
                        inDeg[v] += 1
                    } else {
                        brokenArcs += 1
                    }
                } else {
                    // Anachronistic citation (e.g. revised edition year metadata drift) — add only if it creates no cycle
                    if !isReachable(from: v, to: u, adj: candidateOut) {
                        candidateOut[u].append(v)
                        inDeg[v] += 1
                    } else {
                        brokenArcs += 1
                    }
                }
            }
        }

        var dagIn = [[Int]](repeating: [], count: n)
        for u in 0..<n {
            candidateOut[u].sort()
            for v in candidateOut[u] {
                dagIn[v].append(u)
            }
        }

        // Compute exact topological sort via Kahn's queue (deterministic tie-break by rankOfNode)
        var remInDeg = inDeg
        var ready = (0..<n).filter { remInDeg[$0] == 0 }.sorted { rankOfNode[$0] < rankOfNode[$1] }
        var topo: [Int] = []
        topo.reserveCapacity(n)

        while !ready.isEmpty {
            let u = ready.removeFirst()
            topo.append(u)
            for v in candidateOut[u] {
                remInDeg[v] -= 1
                if remInDeg[v] == 0 {
                    ready.append(v)
                    ready.sort { rankOfNode[$0] < rankOfNode[$1] }
                }
            }
        }

        return (candidateOut, dagIn, topo, brokenArcs)
    }

    private static func isReachable(from start: Int, to target: Int, adj: [[Int]]) -> Bool {
        if start == target { return true }
        var visited = Array(repeating: false, count: adj.count)
        var stack = [start]
        visited[start] = true
        while let curr = stack.popLast() {
            for nxt in adj[curr] {
                if nxt == target { return true }
                if !visited[nxt] {
                    visited[nxt] = true
                    stack.append(nxt)
                }
            }
        }
        return false
    }

    private static func extractGlobalMaxWeightPath(
        nodeCount n: Int,
        topoOrder: [Int],
        dagOut: [[Int]],
        edgeWeightMap: [[Int: (raw: Double, norm: Double)]]
    ) -> [Int] {
        guard n > 0 else { return [] }
        var dp = Array(repeating: 0.0, count: n)
        var parent = Array(repeating: -1, count: n)

        for u in topoOrder {
            for v in dagOut[u] {
                let w = edgeWeightMap[u][v]?.norm ?? 0.0
                let cand = dp[u] + w
                if cand > dp[v] + 1e-12 || (abs(cand - dp[v]) <= 1e-12 && parent[v] == -1) {
                    dp[v] = cand
                    parent[v] = u
                }
            }
        }

        var bestEnd = 0
        for i in 1..<n {
            if dp[i] > dp[bestEnd] + 1e-12 {
                bestEnd = i
            }
        }

        if dp[bestEnd] <= 0.0 {
            return topoOrder.first.map { [$0] } ?? []
        }

        var path: [Int] = []
        var curr = bestEnd
        while curr != -1 {
            path.append(curr)
            curr = parent[curr]
        }
        path.reverse()
        return path
    }

    private static func extractForwardLocalPath(
        sources: [Int],
        dagOut: [[Int]],
        edgeWeightMap: [[Int: (raw: Double, norm: Double)]]
    ) -> [Int] {
        // Pick source with highest maximum outgoing SPC edge
        guard let startSource = sources.max(by: { a, b in
            let maxA = dagOut[a].compactMap { edgeWeightMap[a][$0]?.norm }.max() ?? 0.0
            let maxB = dagOut[b].compactMap { edgeWeightMap[b][$0]?.norm }.max() ?? 0.0
            if abs(maxA - maxB) > 1e-12 { return maxA < maxB }
            return a > b
        }) else {
            return []
        }

        var path: [Int] = [startSource]
        var visited = Set<Int>([startSource])
        var curr = startSource

        while !dagOut[curr].isEmpty {
            guard let nextNode = dagOut[curr]
                .filter({ !visited.contains($0) })
                .max(by: { v1, v2 in
                    let w1 = edgeWeightMap[curr][v1]?.norm ?? 0.0
                    let w2 = edgeWeightMap[curr][v2]?.norm ?? 0.0
                    if abs(w1 - w2) > 1e-12 { return w1 < w2 }
                    return v1 > v2
                }) else {
                break
            }
            visited.insert(nextNode)
            path.append(nextNode)
            curr = nextNode
        }
        return path
    }

    private static func extendKeyRoute(
        seedU: Int,
        seedV: Int,
        dagIn: [[Int]],
        dagOut: [[Int]],
        edgeWeightMap: [[Int: (raw: Double, norm: Double)]]
    ) -> [Int] {
        // Backward greedy extension from `seedU` to a foundational root
        var prefixRev: [Int] = [seedU]
        var visited = Set<Int>([seedU, seedV])
        var backCurr = seedU
        while !dagIn[backCurr].isEmpty {
            guard let prev = dagIn[backCurr]
                .filter({ !visited.contains($0) })
                .max(by: { p1, p2 in
                    let w1 = edgeWeightMap[p1][backCurr]?.norm ?? 0.0
                    let w2 = edgeWeightMap[p2][backCurr]?.norm ?? 0.0
                    if abs(w1 - w2) > 1e-12 { return w1 < w2 }
                    return p1 > p2
                }) else {
                break
            }
            visited.insert(prev)
            prefixRev.append(prev)
            backCurr = prev
        }

        // Forward greedy extension from `seedV` to a frontier sink
        var suffix: [Int] = [seedV]
        var fwdCurr = seedV
        while !dagOut[fwdCurr].isEmpty {
            guard let nxt = dagOut[fwdCurr]
                .filter({ !visited.contains($0) })
                .max(by: { n1, n2 in
                    let w1 = edgeWeightMap[fwdCurr][n1]?.norm ?? 0.0
                    let w2 = edgeWeightMap[fwdCurr][n2]?.norm ?? 0.0
                    if abs(w1 - w2) > 1e-12 { return w1 < w2 }
                    return n1 > n2
                }) else {
                break
            }
            visited.insert(nxt)
            suffix.append(nxt)
            fwdCurr = nxt
        }

        return prefixRev.reversed() + suffix
    }

    private static func buildTrajectoryModel(
        kind: String,
        indices: [Int],
        entries: [BibliographyEntry],
        edgeWeightMap: [[Int: (raw: Double, norm: Double)]],
        defaultYear: Int
    ) -> IntellectualTrajectoryRoute {
        let keys = indices.map { entries[$0].citeKey }
        var totalNorm = 0.0
        var bestEdgeW = -1.0
        var bottleneckKey: String? = keys.first

        if indices.count >= 2 {
            for idx in 0..<(indices.count - 1) {
                let u = indices[idx]
                let v = indices[idx + 1]
                let w = edgeWeightMap[u][v]?.norm ?? 0.0
                totalNorm += w
                if w > bestEdgeW {
                    bestEdgeW = w
                    bottleneckKey = entries[u].citeKey
                }
            }
        }

        let startYr = indices.first.flatMap { entries[$0].year } ?? defaultYear
        let endYr = indices.last.flatMap { entries[$0].year } ?? defaultYear
        return IntellectualTrajectoryRoute(
            routeKind: kind,
            orderedCiteKeys: keys,
            cumulativeNormalizedSPC: totalNorm,
            bottleneckCiteKey: bottleneckKey,
            startYear: startYr,
            endYear: endYr
        )
    }

    private static func edgeKeySet(fromPath indices: [Int]) -> Set<String> {
        guard indices.count >= 2 else { return [] }
        var s = Set<String>()
        for i in 0..<(indices.count - 1) {
            s.insert("\(indices[i])->\(indices[i + 1])")
        }
        return s
    }

    /// Extracts cited keys from LaTeX `\cite*{k1, k2}`, Typst `@citeKey` / `#cite(<key>)`, and Pandoc Markdown `[@citeKey]`.
    public static func extractCiteKeysFromMarkup(_ source: String) -> Set<String> {
        var found = Set<String>()
        let ns = source as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        // 1. LaTeX \cite, \citep, \citet, \citeauthor, \citeyear, \parencite, \textcite, \autocite
        if let latexRegex = try? NSRegularExpression(
            pattern: #"\\(?:cite[a-zA-Z]*|parencite|textcite|autocite|nocite)\*?(?:\[[^\]]*\])*\{([^}]+)\}"#
        ) {
            for m in latexRegex.matches(in: source, range: fullRange) where m.numberOfRanges > 1 {
                let group = ns.substring(with: m.range(at: 1))
                for part in group.split(separator: ",") {
                    let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        found.insert(trimmed)
                    }
                }
            }
        }

        // 2. Typst #cite(<key>)
        if let typstCallRegex = try? NSRegularExpression(pattern: #"#cite\(\s*<([A-Za-z0-9_:\-\.]+)>"#) {
            for m in typstCallRegex.matches(in: source, range: fullRange) where m.numberOfRanges > 1 {
                found.insert(ns.substring(with: m.range(at: 1)))
            }
        }

        // 3. Typst / Pandoc @key (excluding email addresses like user@domain)
        if let atKeyRegex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9._%+-])@([A-Za-z][A-Za-z0-9_:\-]{2,})"#) {
            for m in atKeyRegex.matches(in: source, range: fullRange) where m.numberOfRanges > 1 {
                let candidate = ns.substring(with: m.range(at: 1))
                found.insert(candidate)
            }
        }

        return found
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "into", "using", "via",
        "study", "studies", "paper", "system", "systems", "method", "methods", "model",
        "models", "based", "analysis", "results", "section", "begin", "end", "cite",
        "citep", "citet", "figure", "table", "label", "textbf", "emph"
    ]

    private static func tokenizeKeywords(_ raw: String) -> [String] {
        raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopWords.contains($0) && Int($0) == nil }
    }

    private static func escapeXML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeLaTeX(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\textbackslash{}")
            .replacingOccurrences(of: "&", with: "\\&")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
