import Foundation
import ScholarModels

// MARK: - Louvain Modularity, Structural Holes & Kleinberg Burst Models

/// Hierarchical coarsening pass summary produced during multi-level Louvain modularity optimization (Blondel et al., 2008).
public struct LouvainHierarchyPass: Sendable, Codable, Hashable, Identifiable {
    public var id: Int { passIndex }
    public let passIndex: Int
    public let superNodeCount: Int
    public let resultingCommunityCount: Int
    public let modularityBeforePass: Double
    public let modularityAfterPass: Double
    public let localMovesPerformed: Int

    public init(
        passIndex: Int,
        superNodeCount: Int,
        resultingCommunityCount: Int,
        modularityBeforePass: Double,
        modularityAfterPass: Double,
        localMovesPerformed: Int
    ) {
        self.passIndex = passIndex
        self.superNodeCount = superNodeCount
        self.resultingCommunityCount = resultingCommunityCount
        self.modularityBeforePass = modularityBeforePass
        self.modularityAfterPass = modularityAfterPass
        self.localMovesPerformed = localMovesPerformed
    }
}

/// Quantitative profile of a detected Louvain citation community.
public struct LouvainCommunitySummary: Sendable, Codable, Hashable, Identifiable {
    public var id: Int { communityID }
    public let communityID: Int
    public let thematicLabel: String
    public let memberCiteKeys: [String]
    public let internalEdgeWeight: Double
    public let boundaryCutWeight: Double
    public let conductance: Double
    public let internalDensity: Double
    public let modularityContribution: Double
    public let medianPublicationYear: Int
    public let leadHubCiteKey: String?

    public init(
        communityID: Int,
        thematicLabel: String,
        memberCiteKeys: [String],
        internalEdgeWeight: Double,
        boundaryCutWeight: Double,
        conductance: Double,
        internalDensity: Double,
        modularityContribution: Double,
        medianPublicationYear: Int,
        leadHubCiteKey: String?
    ) {
        self.communityID = communityID
        self.thematicLabel = thematicLabel
        self.memberCiteKeys = memberCiteKeys
        self.internalEdgeWeight = internalEdgeWeight
        self.boundaryCutWeight = boundaryCutWeight
        self.conductance = conductance
        self.internalDensity = internalDensity
        self.modularityContribution = modularityContribution
        self.medianPublicationYear = medianPublicationYear
        self.leadHubCiteKey = leadHubCiteKey
    }
}

/// Complete output of multi-level Louvain community detection with resolution parameter $\gamma$.
public struct LouvainCommunityPartition: Sendable, Codable, Hashable {
    public let resolutionGamma: Double
    public let totalGraphEdgeWeightM: Double
    public let modularityQ: Double
    public let communityByCiteKey: [String: Int]
    public let communities: [LouvainCommunitySummary]
    public let hierarchyPasses: [LouvainHierarchyPass]

    public init(
        resolutionGamma: Double,
        totalGraphEdgeWeightM: Double,
        modularityQ: Double,
        communityByCiteKey: [String: Int],
        communities: [LouvainCommunitySummary],
        hierarchyPasses: [LouvainHierarchyPass]
    ) {
        self.resolutionGamma = resolutionGamma
        self.totalGraphEdgeWeightM = totalGraphEdgeWeightM
        self.modularityQ = modularityQ
        self.communityByCiteKey = communityByCiteKey
        self.communities = communities
        self.hierarchyPasses = hierarchyPasses
    }
}

/// Guimerà & Amaral (2005) cartographic role classification in modular networks.
public enum NetworkCartographicRole: String, Sendable, Codable, Hashable, CaseIterable {
    case kinlessGlobalHub = "R7: Kinless Global Hub (z >= 2.5, P > 0.75)"
    case connectorHub = "R6: Connector Hub (z >= 2.5, 0.30 < P <= 0.75)"
    case provincialHub = "R5: Provincial Intra-Cluster Hub (z >= 2.5, P <= 0.30)"
    case kinlessBridge = "R4: Kinless Cross-Cluster Bridge (z < 2.5, P > 0.80)"
    case nonHubConnectorBridge = "R3: Structural Connector Bridge (z < 2.5, 0.62 < P <= 0.80)"
    case peripheralConnector = "R2: Peripheral Connector (z < 2.5, 0.05 < P <= 0.62)"
    case ultraPeripheral = "R1: Ultra-Peripheral Specialist (z < 2.5, P <= 0.05)"

    public static func classify(withinModuleZ z: Double, participationP p: Double) -> NetworkCartographicRole {
        if z >= 2.5 {
            if p > 0.75 { return .kinlessGlobalHub }
            if p > 0.30 { return .connectorHub }
            return .provincialHub
        } else {
            if p > 0.80 { return .kinlessBridge }
            if p > 0.62 { return .nonHubConnectorBridge }
            if p > 0.05 { return .peripheralConnector }
            return .ultraPeripheral
        }
    }

    public var isInterdisciplinaryBridge: Bool {
        switch self {
        case .kinlessGlobalHub, .connectorHub, .kinlessBridge, .nonHubConnectorBridge:
            return true
        case .provincialHub, .peripheralConnector, .ultraPeripheral:
            return false
        }
    }
}

/// Structural-hole and Brandes betweenness profile for a single publication node.
public struct StructuralBridgePaperProfile: Sendable, Codable, Hashable, Identifiable {
    public var id: String { citeKey }
    public let citeKey: String
    public let title: String
    public let publicationYear: Int
    public let assignedCommunityID: Int
    public let distinctNeighborCommunitiesCount: Int
    public let unweightedBetweenness: Double
    public let weightedBetweenness: Double
    /// Burt (1992) ego-network constraint $C_i \in [0, 1.125]$; smaller values indicate richer structural holes!
    public let burtNetworkConstraint: Double
    /// Burt (1992) effective ego-network size (non-redundant contacts).
    public let burtEffectiveSize: Double
    /// Guimerà & Amaral (2005) participation coefficient $P_i \in [0, 1]$.
    public let participationCoefficient: Double
    /// Guimerà & Amaral (2005) within-module degree $z$-score.
    public let withinModuleDegreeZ: Double
    public let cartographicRole: NetworkCartographicRole
    public let compositeBridgeScore: Double
    public let isStructuralHoleBridge: Bool

    public init(
        citeKey: String,
        title: String,
        publicationYear: Int,
        assignedCommunityID: Int,
        distinctNeighborCommunitiesCount: Int,
        unweightedBetweenness: Double,
        weightedBetweenness: Double,
        burtNetworkConstraint: Double,
        burtEffectiveSize: Double,
        participationCoefficient: Double,
        withinModuleDegreeZ: Double,
        cartographicRole: NetworkCartographicRole,
        compositeBridgeScore: Double,
        isStructuralHoleBridge: Bool
    ) {
        self.citeKey = citeKey
        self.title = title
        self.publicationYear = publicationYear
        self.assignedCommunityID = assignedCommunityID
        self.distinctNeighborCommunitiesCount = distinctNeighborCommunitiesCount
        self.unweightedBetweenness = unweightedBetweenness
        self.weightedBetweenness = weightedBetweenness
        self.burtNetworkConstraint = burtNetworkConstraint
        self.burtEffectiveSize = burtEffectiveSize
        self.participationCoefficient = participationCoefficient
        self.withinModuleDegreeZ = withinModuleDegreeZ
        self.cartographicRole = cartographicRole
        self.compositeBridgeScore = compositeBridgeScore
        self.isStructuralHoleBridge = isStructuralHoleBridge
    }
}

// MARK: - Co-Citation (C = A^T A) & Bibliographic Coupling (B = A A^T) Models

public struct BibliometricMatrixPairEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(citeKeyA)<->\(citeKeyB)" }
    public let citeKeyA: String
    public let citeKeyB: String
    public let rawSharedCount: Int
    public let saltonCosineSimilarity: Double
    public let jaccardIndex: Double

    public init(
        citeKeyA: String,
        citeKeyB: String,
        rawSharedCount: Int,
        saltonCosineSimilarity: Double,
        jaccardIndex: Double
    ) {
        self.citeKeyA = citeKeyA
        self.citeKeyB = citeKeyB
        self.rawSharedCount = rawSharedCount
        self.saltonCosineSimilarity = saltonCosineSimilarity
        self.jaccardIndex = jaccardIndex
    }
}

/// Dense + sparse representation of directed adjacency $A$, Co-Citation $C = A^T A$, and Bibliographic Coupling $B = A A^T$.
public struct CoCitationAndCouplingAnalysis: Sendable, Codable, Hashable {
    public let orderedCiteKeys: [String]
    /// Directed citation matrix $A_{ij} \in \{0, 1\}$ where $i$ cites $j$.
    public let citationAdjacencyMatrixA: [[Int]]
    /// Symmetric co-citation count matrix $C = A^T A$ ($C_{ij}$ = number of papers citing both $i$ and $j$; $C_{ii} = \text{inDeg}(i)$).
    public let coCitationMatrixC: [[Int]]
    /// Symmetric bibliographic coupling matrix $B = A A^T$ ($B_{ij}$ = number of references shared by $i$ and $j$; $B_{ii} = \text{outDeg}(i)$).
    public let bibliographicCouplingMatrixB: [[Int]]
    /// Salton cosine-normalized co-citation matrix $\tilde{C}_{ij} = C_{ij} / \sqrt{C_{ii} C_{jj}}$.
    public let normalizedCoCitationCosine: [[Double]]
    /// Salton cosine-normalized bibliographic coupling matrix $\tilde{B}_{ij} = B_{ij} / \sqrt{B_{ii} B_{jj}}$.
    public let normalizedCouplingCosine: [[Double]]
    public let topCoCitedPairs: [BibliometricMatrixPairEntry]
    public let topBibliographicallyCoupledPairs: [BibliometricMatrixPairEntry]

    public init(
        orderedCiteKeys: [String],
        citationAdjacencyMatrixA: [[Int]],
        coCitationMatrixC: [[Int]],
        bibliographicCouplingMatrixB: [[Int]],
        normalizedCoCitationCosine: [[Double]],
        normalizedCouplingCosine: [[Double]],
        topCoCitedPairs: [BibliometricMatrixPairEntry],
        topBibliographicallyCoupledPairs: [BibliometricMatrixPairEntry]
    ) {
        self.orderedCiteKeys = orderedCiteKeys
        self.citationAdjacencyMatrixA = citationAdjacencyMatrixA
        self.coCitationMatrixC = coCitationMatrixC
        self.bibliographicCouplingMatrixB = bibliographicCouplingMatrixB
        self.normalizedCoCitationCosine = normalizedCoCitationCosine
        self.normalizedCouplingCosine = normalizedCouplingCosine
        self.topCoCitedPairs = topCoCitedPairs
        self.topBibliographicallyCoupledPairs = topBibliographicallyCoupledPairs
    }
}

// MARK: - Kleinberg (2002) Burst-Detection Models

/// Detected burst interval $[startYear, endYear]$ from Kleinberg's multi-state infinite-automaton Viterbi solver.
public struct KleinbergBurstEpisode: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(targetIdentifier):\(startYear)-\(endYear):L\(peakStateLevel)" }
    public let targetIdentifier: String
    public let displayLabel: String
    public let kind: String
    public let startYear: Int
    public let endYear: Int
    public let durationYears: Int
    public let peakStateLevel: Int
    public let burstStrengthWeight: Double
    public let observedEventsInWindow: Int
    public let baselineExpectedEvents: Double
    public let foldElevationRatio: Double

    public init(
        targetIdentifier: String,
        displayLabel: String,
        kind: String,
        startYear: Int,
        endYear: Int,
        durationYears: Int,
        peakStateLevel: Int,
        burstStrengthWeight: Double,
        observedEventsInWindow: Int,
        baselineExpectedEvents: Double,
        foldElevationRatio: Double
    ) {
        self.targetIdentifier = targetIdentifier
        self.displayLabel = displayLabel
        self.kind = kind
        self.startYear = startYear
        self.endYear = endYear
        self.durationYears = durationYears
        self.peakStateLevel = peakStateLevel
        self.burstStrengthWeight = burstStrengthWeight
        self.observedEventsInWindow = observedEventsInWindow
        self.baselineExpectedEvents = baselineExpectedEvents
        self.foldElevationRatio = foldElevationRatio
    }
}

public struct KleinbergBurstAnalysisReport: Sendable, Codable, Hashable {
    public let minYear: Int
    public let maxYear: Int
    public let scalingBaseS: Double
    public let transitionGamma: Double
    public let stateCountK: Int
    public let paperCitationBursts: [KleinbergBurstEpisode]
    public let topicalKeywordBursts: [KleinbergBurstEpisode]
    public let annualPublicationCounts: [Int: Int]

    public init(
        minYear: Int,
        maxYear: Int,
        scalingBaseS: Double,
        transitionGamma: Double,
        stateCountK: Int,
        paperCitationBursts: [KleinbergBurstEpisode],
        topicalKeywordBursts: [KleinbergBurstEpisode],
        annualPublicationCounts: [Int: Int]
    ) {
        self.minYear = minYear
        self.maxYear = maxYear
        self.scalingBaseS = scalingBaseS
        self.transitionGamma = transitionGamma
        self.stateCountK = stateCountK
        self.paperCitationBursts = paperCitationBursts
        self.topicalKeywordBursts = topicalKeywordBursts
        self.annualPublicationCounts = annualPublicationCounts
    }
}

// MARK: - Binary Min-Heap for Brandes O(VE + V^2 log V) Weighted Shortest-Path Betweenness

private struct IndexedDistanceMinHeap {
    private var heap: [(node: Int, dist: Double)] = []

    var isEmpty: Bool { heap.isEmpty }

    mutating func push(node: Int, dist: Double) {
        heap.append((node, dist))
        siftUp(from: heap.count - 1)
    }

    mutating func popMin() -> (node: Int, dist: Double)? {
        guard !heap.isEmpty else { return nil }
        if heap.count == 1 {
            return heap.removeLast()
        }
        let top = heap[0]
        heap[0] = heap.removeLast()
        siftDown(from: 0)
        return top
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            if isHigherPriority(heap[child], than: heap[parent]) {
                heap.swapAt(child, parent)
                child = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        let count = heap.count
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var candidate = parent
            if left < count && isHigherPriority(heap[left], than: heap[candidate]) {
                candidate = left
            }
            if right < count && isHigherPriority(heap[right], than: heap[candidate]) {
                candidate = right
            }
            if candidate == parent {
                break
            }
            heap.swapAt(parent, candidate)
            parent = candidate
        }
    }

    private func isHigherPriority(_ a: (node: Int, dist: Double), than b: (node: Int, dist: Double)) -> Bool {
        if abs(a.dist - b.dist) > 1e-12 {
            return a.dist < b.dist
        }
        return a.node < b.node
    }
}

// MARK: - Louvain Modularity, Brandes Bridge, Co-Citation & Kleinberg Burst Engine

/// Pure-Swift scientometric graph analytics engine implementing multi-level Louvain modularity optimization, exact Brandes unweighted/weighted betweenness centrality, Burt's structural holes, $C = A^T A$ / $B = A A^T$ matrices, and Kleinberg's Viterbi burst detector.
public struct LouvainModularityAndBridgeDetector: Sendable {
    public let resolutionGamma: Double
    public let maxLocalIterationsPerPass: Int
    public let maxHierarchyPasses: Int

    public init(
        resolutionGamma: Double = 1.0,
        maxLocalIterationsPerPass: Int = 40,
        maxHierarchyPasses: Int = 12
    ) {
        self.resolutionGamma = max(0.05, resolutionGamma)
        self.maxLocalIterationsPerPass = max(4, maxLocalIterationsPerPass)
        self.maxHierarchyPasses = max(1, maxHierarchyPasses)
    }

    // MARK: 1. Pure-Swift Multi-Phase Louvain Modularity Optimization

    /// Optimizes Newman-Girvan generalized modularity $Q = \frac{1}{2m} \sum_{ij} \left[A_{ij} - \gamma \frac{k_i k_j}{2m}\right] \delta(c_i, c_j)$ via Phase-1 local node moves + Phase-2 super-node coarsening.
    public func detectLouvainCommunities(
        entries: [BibliographyEntry],
        edges: [CitationGraphEdge]? = nil
    ) -> LouvainCommunityPartition {
        let sortedEntries = entries.sorted { $0.citeKey < $1.citeKey }
        let n = sortedEntries.count
        guard n > 0 else {
            return LouvainCommunityPartition(
                resolutionGamma: resolutionGamma,
                totalGraphEdgeWeightM: 0.0,
                modularityQ: 0.0,
                communityByCiteKey: [:],
                communities: [],
                hierarchyPasses: []
            )
        }

        var keyToIdx: [String: Int] = [:]
        for (i, e) in sortedEntries.enumerated() {
            keyToIdx[e.citeKey] = i
        }

        // Build symmetric undirected weighted adjacency matrix / list (self-loops tracked explicitly for coarsening!)
        let effectiveEdges = edges ?? synthesizeHybridEdges(from: sortedEntries, keyToIdx: keyToIdx)
        var baseNeighbors = [[Int: Double]](repeating: [:], count: n)
        var totalTwiceM = 0.0 // 2m = sum_{i,j} A_{ij}

        for edge in effectiveEdges {
            guard let u = keyToIdx[edge.sourceCiteKey],
                  let v = keyToIdx[edge.targetCiteKey],
                  edge.weight > 0.0 else { continue }
            if u == v {
                baseNeighbors[u][u, default: 0.0] += 2.0 * edge.weight
                totalTwiceM += 2.0 * edge.weight
            } else {
                baseNeighbors[u][v, default: 0.0] += edge.weight
                baseNeighbors[v][u, default: 0.0] += edge.weight
                totalTwiceM += 2.0 * edge.weight
            }
        }

        let mWeight = 0.5 * totalTwiceM
        if totalTwiceM <= 1e-12 {
            // Disconnected edgeless corpus: each paper is its own singleton community
            var singletonMap: [String: Int] = [:]
            var summaries: [LouvainCommunitySummary] = []
            for (idx, entry) in sortedEntries.enumerated() {
                singletonMap[entry.citeKey] = idx
                summaries.append(
                    LouvainCommunitySummary(
                        communityID: idx,
                        thematicLabel: Self.deriveThemeLabel(for: [entry], fallbackID: idx),
                        memberCiteKeys: [entry.citeKey],
                        internalEdgeWeight: 0.0,
                        boundaryCutWeight: 0.0,
                        conductance: 0.0,
                        internalDensity: 1.0,
                        modularityContribution: 0.0,
                        medianPublicationYear: entry.year ?? 2026,
                        leadHubCiteKey: entry.citeKey
                    )
                )
            }
            return LouvainCommunityPartition(
                resolutionGamma: resolutionGamma,
                totalGraphEdgeWeightM: 0.0,
                modularityQ: 0.0,
                communityByCiteKey: singletonMap,
                communities: summaries,
                hierarchyPasses: []
            )
        }

        // Multi-level Louvain state:
        // `currentAdj` holds super-node adjacency (including self-loops A_{cc} from aggregated intra-cluster edges)
        var currentAdj = baseNeighbors
        var fineNodeToSuperNode = Array(0..<n)
        var passes: [LouvainHierarchyPass] = []

        for passIdx in 0..<maxHierarchyPasses {
            let superN = currentAdj.count
            var deg = Array(repeating: 0.0, count: superN)
            var selfLoop = Array(repeating: 0.0, count: superN)
            for u in 0..<superN {
                for (v, w) in currentAdj[u] {
                    deg[u] += w
                    if u == v {
                        selfLoop[u] = w
                    }
                }
            }

            var comm = Array(0..<superN)
            var sigmaTot = deg // sum of degrees of nodes in community c
            let qBefore = Self.computeModularity(
                adj: currentAdj,
                comm: comm,
                deg: deg,
                twiceM: totalTwiceM,
                gamma: resolutionGamma
            )

            var movesInPass = 0
            for _ in 0..<maxLocalIterationsPerPass {
                var movedThisSweep = false
                for i in 0..<superN {
                    let oldComm = comm[i]
                    let ki = deg[i]
                    guard ki > 0.0 else { continue }

                    // Compute edge weights from i to every neighboring community (excluding i itself)
                    var weightToComm: [Int: Double] = [:]
                    for (nbr, w) in currentAdj[i] where nbr != i {
                        weightToComm[comm[nbr], default: 0.0] += w
                    }

                    // Temporarily remove i from `oldComm`
                    let kiInOld = weightToComm[oldComm] ?? 0.0
                    sigmaTot[oldComm] -= ki

                    // Baseline gain of returning i to `oldComm`:
                    // Gain(i -> c) proportional to: k_{i,in}(c) - gamma * sigmaTot[c] * k_i / (2m)
                    let removalBaseline = kiInOld - resolutionGamma * (sigmaTot[oldComm] * ki) / totalTwiceM
                    var bestComm = oldComm
                    var bestDeltaOverOld = 0.0

                    var candidateComms = Array(weightToComm.keys)
                    candidateComms.sort()

                    for cand in candidateComms where cand != oldComm {
                        let kiInCand = weightToComm[cand] ?? 0.0
                        let gainCand = kiInCand - resolutionGamma * (sigmaTot[cand] * ki) / totalTwiceM
                        let netImprovement = gainCand - removalBaseline
                        if netImprovement > bestDeltaOverOld + 1e-11 {
                            bestDeltaOverOld = netImprovement
                            bestComm = cand
                        }
                    }

                    // Place i into `bestComm`
                    comm[i] = bestComm
                    sigmaTot[bestComm] += ki
                    if bestComm != oldComm {
                        movedThisSweep = true
                        movesInPass += 1
                    }
                }
                if !movedThisSweep {
                    break
                }
            }

            // Compress community indices densely 0..<newSuperN
            var remap: [Int: Int] = [:]
            var nextID = 0
            var denseComm = Array(repeating: 0, count: superN)
            for u in 0..<superN {
                let raw = comm[u]
                if let mapped = remap[raw] {
                    denseComm[u] = mapped
                } else {
                    remap[raw] = nextID
                    denseComm[u] = nextID
                    nextID += 1
                }
            }

            let qAfter = Self.computeModularity(
                adj: currentAdj,
                comm: denseComm,
                deg: deg,
                twiceM: totalTwiceM,
                gamma: resolutionGamma
            )

            passes.append(
                LouvainHierarchyPass(
                    passIndex: passIdx + 1,
                    superNodeCount: superN,
                    resultingCommunityCount: nextID,
                    modularityBeforePass: qBefore,
                    modularityAfterPass: qAfter,
                    localMovesPerformed: movesInPass
                )
            )

            // Propagate super-node assignment back to original paper nodes
            for origIdx in 0..<n {
                fineNodeToSuperNode[origIdx] = denseComm[fineNodeToSuperNode[origIdx]]
            }

            if movesInPass == 0 || nextID == superN || (qAfter - qBefore) < 1e-9 {
                break
            }

            // Phase 2: Coarsen graph into `nextID` super-nodes preserving exact total degree & intra-community self-loops
            var coarsenedAdj = [[Int: Double]](repeating: [:], count: nextID)
            for u in 0..<superN {
                let cu = denseComm[u]
                for (v, w) in currentAdj[u] {
                    let cv = denseComm[v]
                    coarsenedAdj[cu][cv, default: 0.0] += w
                }
            }
            currentAdj = coarsenedAdj
        }

        // Canonicalize final community IDs ordered by descending size (then earliest first citeKey)
        var membersByRawComm: [Int: [Int]] = [:]
        for i in 0..<n {
            membersByRawComm[fineNodeToSuperNode[i], default: []].append(i)
        }
        let sortedRawGroups = membersByRawComm.values.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return (lhs.first ?? 0) < (rhs.first ?? 0)
        }

        var finalCommOfNode = Array(repeating: 0, count: n)
        for (canonID, indices) in sortedRawGroups.enumerated() {
            for idx in indices {
                finalCommOfNode[idx] = canonID
            }
        }

        var baseDeg = Array(repeating: 0.0, count: n)
        for u in 0..<n {
            for (_, w) in baseNeighbors[u] {
                baseDeg[u] += w
            }
        }

        let finalQ = Self.computeModularity(
            adj: baseNeighbors,
            comm: finalCommOfNode,
            deg: baseDeg,
            twiceM: totalTwiceM,
            gamma: resolutionGamma
        )

        var communityMap: [String: Int] = [:]
        for i in 0..<n {
            communityMap[sortedEntries[i].citeKey] = finalCommOfNode[i]
        }

        // Build rich per-community scientometric metrics
        var summaries: [LouvainCommunitySummary] = []
        for (canonID, memberIndices) in sortedRawGroups.enumerated() {
            let memberSet = Set(memberIndices)
            var twiceInternalWeight = 0.0
            var cutWeight = 0.0
            var sumDegC = 0.0

            for u in memberIndices {
                sumDegC += baseDeg[u]
                for (v, w) in baseNeighbors[u] {
                    if memberSet.contains(v) {
                        twiceInternalWeight += w
                    } else {
                        cutWeight += w
                    }
                }
            }

            let internalEdgeWeight = 0.5 * twiceInternalWeight
            let volumeDenom = min(sumDegC, max(0.0, totalTwiceM - sumDegC))
            let conductance = volumeDenom > 1e-12 ? (cutWeight / volumeDenom) : 0.0

            let kMembers = memberIndices.count
            let maxPossiblePairs = kMembers > 1 ? Double(kMembers * (kMembers - 1)) * 0.5 : 1.0
            var presentPairs = 0
            for u in memberIndices {
                for (v, w) in baseNeighbors[u] where v > u && w > 0.0 && memberSet.contains(v) {
                    presentPairs += 1
                }
            }
            let density = kMembers > 1 ? min(1.0, Double(presentPairs) / maxPossiblePairs) : 1.0
            let qContrib = (twiceInternalWeight / totalTwiceM) - resolutionGamma * Foundation.pow(sumDegC / totalTwiceM, 2.0)

            let memberEntries = memberIndices.map { sortedEntries[$0] }
            let years = memberEntries.compactMap(\.year).sorted()
            let medianYr = years.isEmpty ? 2026 : years[years.count / 2]

            let leadIdx = memberIndices.max { a, b in
                if abs(baseDeg[a] - baseDeg[b]) > 1e-9 { return baseDeg[a] < baseDeg[b] }
                return sortedEntries[a].citeKey > sortedEntries[b].citeKey
            }

            summaries.append(
                LouvainCommunitySummary(
                    communityID: canonID,
                    thematicLabel: Self.deriveThemeLabel(for: memberEntries, fallbackID: canonID),
                    memberCiteKeys: memberEntries.map(\.citeKey),
                    internalEdgeWeight: internalEdgeWeight,
                    boundaryCutWeight: cutWeight,
                    conductance: conductance,
                    internalDensity: density,
                    modularityContribution: qContrib,
                    medianPublicationYear: medianYr,
                    leadHubCiteKey: leadIdx.map { sortedEntries[$0].citeKey }
                )
            )
        }

        return LouvainCommunityPartition(
            resolutionGamma: resolutionGamma,
            totalGraphEdgeWeightM: mWeight,
            modularityQ: finalQ,
            communityByCiteKey: communityMap,
            communities: summaries,
            hierarchyPasses: passes
        )
    }

    // MARK: 2. Brandes Exact Unweighted O(VE) + Weighted O(VE + V^2 log V) Betweenness & Structural Holes

    /// Computes exact Brandes unweighted & weighted betweenness centrality, Burt's structural-hole constraint $C_i$, and Guimerà-Amaral cartographic roles to pinpoint interdisciplinary bridge papers.
    public func analyzeStructuralBridges(
        entries: [BibliographyEntry],
        edges: [CitationGraphEdge]? = nil,
        partition: LouvainCommunityPartition? = nil
    ) -> [StructuralBridgePaperProfile] {
        let sortedEntries = entries.sorted { $0.citeKey < $1.citeKey }
        let n = sortedEntries.count
        guard n > 0 else { return [] }

        var keyToIdx: [String: Int] = [:]
        for (i, e) in sortedEntries.enumerated() {
            keyToIdx[e.citeKey] = i
        }

        let resolvedEdges = edges ?? synthesizeHybridEdges(from: sortedEntries, keyToIdx: keyToIdx)
        let resolvedPartition = partition ?? detectLouvainCommunities(entries: sortedEntries, edges: resolvedEdges)

        var undirectedAdj = [[Int: Double]](repeating: [:], count: n)
        for edge in resolvedEdges {
            guard let u = keyToIdx[edge.sourceCiteKey],
                  let v = keyToIdx[edge.targetCiteKey],
                  u != v,
                  edge.weight > 0.0 else { continue }
            undirectedAdj[u][v, default: 0.0] += edge.weight
            undirectedAdj[v][u, default: 0.0] += edge.weight
        }

        let unweightedAdjList: [[Int]] = undirectedAdj.map { $0.keys.sorted() }
        // In citation similarity networks, stronger edge weight = closer conceptual proximity -> shortest-path distance = 1 / weight
        let weightedCostAdjList: [[(neighbor: Int, distanceCost: Double)]] = undirectedAdj.map { dict in
            dict.keys.sorted().map { nbr in
                let strength = max(1e-6, dict[nbr] ?? 1.0)
                return (nbr, 1.0 / strength)
            }
        }

        let unweightedCB = Self.brandesUnweightedBetweenness(nodeCount: n, adj: unweightedAdjList)
        let weightedCB = Self.brandesWeightedBetweenness(nodeCount: n, adj: weightedCostAdjList)

        let commOfNode: [Int] = sortedEntries.map { resolvedPartition.communityByCiteKey[$0.citeKey] ?? 0 }

        // Precompute within-module degree mean and SD for each community (Guimerà & Amaral 2005)
        var withinModStrength = Array(repeating: 0.0, count: n)
        var commMembers: [Int: [Int]] = [:]
        for i in 0..<n {
            let ci = commOfNode[i]
            commMembers[ci, default: []].append(i)
            var kappaIS = 0.0
            for (nbr, w) in undirectedAdj[i] where commOfNode[nbr] == ci {
                kappaIS += w
            }
            withinModStrength[i] = kappaIS
        }

        var withinModZ = Array(repeating: 0.0, count: n)
        for (_, indices) in commMembers {
            guard !indices.isEmpty else { continue }
            let meanK = indices.reduce(0.0) { $0 + withinModStrength[$1] } / Double(indices.count)
            let varK = indices.reduce(0.0) { $0 + Foundation.pow(withinModStrength[$1] - meanK, 2.0) } / Double(indices.count)
            let sdK = varK.squareRoot()
            for idx in indices {
                withinModZ[idx] = sdK > 1e-9 ? ((withinModStrength[idx] - meanK) / sdK) : 0.0
            }
        }

        var profiles: [StructuralBridgePaperProfile] = []
        profiles.reserveCapacity(n)

        for i in 0..<n {
            let nbrDict = undirectedAdj[i]
            let totalStrength = nbrDict.values.reduce(0.0, +)

            // 1. Guimerà-Amaral Participation Coefficient P_i = 1 - sum_s (k_{i,s} / k_i)^2
            var strengthByComm: [Int: Double] = [:]
            for (nbr, w) in nbrDict {
                strengthByComm[commOfNode[nbr], default: 0.0] += w
            }
            let participationP: Double
            if totalStrength > 1e-12 {
                let sumSq = strengthByComm.values.reduce(0.0) { acc, ks in
                    let ratio = ks / totalStrength
                    return acc + ratio * ratio
                }
                participationP = max(0.0, min(1.0, 1.0 - sumSq))
            } else {
                participationP = 0.0
            }

            // 2. Burt's Network Constraint C_i = sum_j (p_{ij} + sum_{q != i,j} p_{iq} p_{qj})^2 & Effective Size
            let (burtConstraint, burtEffSize) = Self.computeBurtStructuralHoleMetrics(
                ego: i,
                undirectedAdj: undirectedAdj
            )

            let role = NetworkCartographicRole.classify(withinModuleZ: withinModZ[i], participationP: participationP)
            let externalCommCount = strengthByComm.keys.filter { $0 != commOfNode[i] }.count

            // Composite structural-bridge index combining weighted Brandes betweenness, participation, and low Burt constraint (1 - C_i)
            let holeFreedom = max(0.0, 1.0 - min(1.0, burtConstraint))
            let composite = 0.42 * min(1.0, weightedCB[i] * 4.0)
                + 0.33 * participationP
                + 0.25 * holeFreedom

            let isBridge = externalCommCount >= 1
                && nbrDict.count >= 2
                && (role.isInterdisciplinaryBridge || weightedCB[i] >= 0.06 || (participationP >= 0.40 && burtConstraint <= 0.65))

            profiles.append(
                StructuralBridgePaperProfile(
                    citeKey: sortedEntries[i].citeKey,
                    title: sortedEntries[i].title,
                    publicationYear: sortedEntries[i].year ?? 2026,
                    assignedCommunityID: commOfNode[i],
                    distinctNeighborCommunitiesCount: strengthByComm.count,
                    unweightedBetweenness: unweightedCB[i],
                    weightedBetweenness: weightedCB[i],
                    burtNetworkConstraint: burtConstraint,
                    burtEffectiveSize: burtEffSize,
                    participationCoefficient: participationP,
                    withinModuleDegreeZ: withinModZ[i],
                    cartographicRole: role,
                    compositeBridgeScore: composite,
                    isStructuralHoleBridge: isBridge
                )
            )
        }

        return profiles.sorted { lhs, rhs in
            if lhs.isStructuralHoleBridge != rhs.isStructuralHoleBridge {
                return lhs.isStructuralHoleBridge && !rhs.isStructuralHoleBridge
            }
            if abs(lhs.compositeBridgeScore - rhs.compositeBridgeScore) > 1e-9 {
                return lhs.compositeBridgeScore > rhs.compositeBridgeScore
            }
            return lhs.citeKey < rhs.citeKey
        }
    }

    // MARK: 3. Co-Citation (C = A^T A) & Bibliographic Coupling (B = A A^T) Matrix Builder

    /// Builds exact directed adjacency $A$, Co-Citation matrix $C = A^T A$, Bibliographic Coupling matrix $B = A A^T$, Salton's cosine normalizations, and top coupled pairs.
    public func buildCoCitationAndCouplingMatrices(
        entries: [BibliographyEntry],
        topPairLimit: Int = 25
    ) -> CoCitationAndCouplingAnalysis {
        let sortedEntries = entries.sorted { $0.citeKey < $1.citeKey }
        let n = sortedEntries.count
        let keys = sortedEntries.map(\.citeKey)
        guard n > 0 else {
            return CoCitationAndCouplingAnalysis(
                orderedCiteKeys: [],
                citationAdjacencyMatrixA: [],
                coCitationMatrixC: [],
                bibliographicCouplingMatrixB: [],
                normalizedCoCitationCosine: [],
                normalizedCouplingCosine: [],
                topCoCitedPairs: [],
                topBibliographicallyCoupledPairs: []
            )
        }

        var keyToIdx: [String: Int] = [:]
        for (i, k) in keys.enumerated() {
            keyToIdx[k] = i
        }

        // Directed adjacency A[u][v] = 1 iff paper u cites paper v
        var matA = Array(repeating: Array(repeating: 0, count: n), count: n)
        for (u, entry) in sortedEntries.enumerated() {
            for refKey in entry.referencesKeys {
                if let v = keyToIdx[refKey], u != v {
                    matA[u][v] = 1
                }
            }
            for citerKey in entry.citedByKeys {
                if let citer = keyToIdx[citerKey], citer != u {
                    matA[citer][u] = 1
                }
            }
        }

        // Sparse outgoing & incoming index lists for fast O(nnz) matrix multiplication
        var outLists = [[Int]](repeating: [], count: n)
        var inLists = [[Int]](repeating: [], count: n)
        for u in 0..<n {
            for v in 0..<n where matA[u][v] == 1 {
                outLists[u].append(v)
                inLists[v].append(u)
            }
        }

        // Co-citation C = A^T A: C[i][j] = sum_k A[k][i] * A[k][j] = |inLists[i] intersect inLists[j]|
        var matC = Array(repeating: Array(repeating: 0, count: n), count: n)
        for k in 0..<n {
            let cited = outLists[k]
            for aIdx in 0..<cited.count {
                let i = cited[aIdx]
                matC[i][i] += 1
                for bIdx in (aIdx + 1)..<cited.count {
                    let j = cited[bIdx]
                    matC[i][j] += 1
                    matC[j][i] += 1
                }
            }
        }

        // Bibliographic coupling B = A A^T: B[i][j] = sum_k A[i][k] * A[j][k] = |outLists[i] intersect outLists[j]|
        var matB = Array(repeating: Array(repeating: 0, count: n), count: n)
        for k in 0..<n {
            let citers = inLists[k]
            for aIdx in 0..<citers.count {
                let i = citers[aIdx]
                matB[i][i] += 1
                for bIdx in (aIdx + 1)..<citers.count {
                    let j = citers[bIdx]
                    matB[i][j] += 1
                    matB[j][i] += 1
                }
            }
        }

        var cosC = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        var cosB = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        var coCitedPairs: [BibliometricMatrixPairEntry] = []
        var coupledPairs: [BibliometricMatrixPairEntry] = []

        for i in 0..<n {
            cosC[i][i] = matC[i][i] > 0 ? 1.0 : 0.0
            cosB[i][i] = matB[i][i] > 0 ? 1.0 : 0.0
            for j in (i + 1)..<n {
                let cij = matC[i][j]
                if cij > 0 {
                    let denomCos = (Double(matC[i][i]) * Double(matC[j][j])).squareRoot()
                    let cSim = denomCos > 0.0 ? Double(cij) / denomCos : 0.0
                    let unionIn = max(1, matC[i][i] + matC[j][j] - cij)
                    let jacc = Double(cij) / Double(unionIn)
                    cosC[i][j] = cSim
                    cosC[j][i] = cSim
                    coCitedPairs.append(
                        BibliometricMatrixPairEntry(
                            citeKeyA: keys[i],
                            citeKeyB: keys[j],
                            rawSharedCount: cij,
                            saltonCosineSimilarity: cSim,
                            jaccardIndex: jacc
                        )
                    )
                }

                let bij = matB[i][j]
                if bij > 0 {
                    let denomCos = (Double(matB[i][i]) * Double(matB[j][j])).squareRoot()
                    let bSim = denomCos > 0.0 ? Double(bij) / denomCos : 0.0
                    let unionOut = max(1, matB[i][i] + matB[j][j] - bij)
                    let jacc = Double(bij) / Double(unionOut)
                    cosB[i][j] = bSim
                    cosB[j][i] = bSim
                    coupledPairs.append(
                        BibliometricMatrixPairEntry(
                            citeKeyA: keys[i],
                            citeKeyB: keys[j],
                            rawSharedCount: bij,
                            saltonCosineSimilarity: bSim,
                            jaccardIndex: jacc
                        )
                    )
                }
            }
        }

        let sortPairs: (BibliometricMatrixPairEntry, BibliometricMatrixPairEntry) -> Bool = { a, b in
            if abs(a.saltonCosineSimilarity - b.saltonCosineSimilarity) > 1e-9 {
                return a.saltonCosineSimilarity > b.saltonCosineSimilarity
            }
            if a.rawSharedCount != b.rawSharedCount {
                return a.rawSharedCount > b.rawSharedCount
            }
            return a.id < b.id
        }
        coCitedPairs.sort(by: sortPairs)
        coupledPairs.sort(by: sortPairs)

        let cap = max(1, topPairLimit)
        return CoCitationAndCouplingAnalysis(
            orderedCiteKeys: keys,
            citationAdjacencyMatrixA: matA,
            coCitationMatrixC: matC,
            bibliographicCouplingMatrixB: matB,
            normalizedCoCitationCosine: cosC,
            normalizedCouplingCosine: cosB,
            topCoCitedPairs: Array(coCitedPairs.prefix(cap)),
            topBibliographicallyCoupledPairs: Array(coupledPairs.prefix(cap))
        )
    }

    // MARK: 4. Kleinberg (2002) Multi-State Viterbi Burst-Detection over Publication Years

    /// Runs Kleinberg's (KDD 2002) hierarchical infinite-automaton Viterbi dynamic program over publication years to detect both citation surges on seminal papers and emerging topical keyword bursts.
    public func detectKleinbergTemporalBursts(
        entries: [BibliographyEntry],
        scalingBaseS: Double = 2.0,
        transitionGamma: Double = 1.0,
        stateCountK: Int = 4
    ) -> KleinbergBurstAnalysisReport {
        let validEntries = entries.filter { $0.year != nil }
        guard !validEntries.isEmpty else {
            return KleinbergBurstAnalysisReport(
                minYear: 2020,
                maxYear: 2026,
                scalingBaseS: scalingBaseS,
                transitionGamma: transitionGamma,
                stateCountK: stateCountK,
                paperCitationBursts: [],
                topicalKeywordBursts: [],
                annualPublicationCounts: [:]
            )
        }

        let years = validEntries.compactMap(\.year)
        let minYr = years.min() ?? 2020
        let maxYr = years.max() ?? 2026
        let sBase = max(1.25, scalingBaseS)
        let gamma = max(0.10, transitionGamma)
        let kStates = max(2, min(8, stateCountK))

        var annualDocs: [Int: Int] = [:]
        for yr in minYr...maxYr {
            annualDocs[yr] = 0
        }
        for e in validEntries {
            if let yr = e.year {
                annualDocs[yr, default: 0] += 1
            }
        }

        let orderedYears = Array(minYr...maxYr)
        let dtStream = orderedYears.map { annualDocs[$0] ?? 0 }

        guard orderedYears.count >= 2 else {
            return KleinbergBurstAnalysisReport(
                minYear: minYr,
                maxYear: maxYr,
                scalingBaseS: sBase,
                transitionGamma: gamma,
                stateCountK: kStates,
                paperCitationBursts: [],
                topicalKeywordBursts: [],
                annualPublicationCounts: annualDocs
            )
        }

        // Build full directed citation index to count how many papers published in year `t` cited `target`
        var entryByKey: [String: BibliographyEntry] = [:]
        for e in entries {
            entryByKey[e.citeKey] = e
        }
        var citingYearsByTarget: [String: [Int: Int]] = [:]
        for e in validEntries {
            guard let sourceYear = e.year else { continue }
            for refKey in Set(e.referencesKeys) where refKey != e.citeKey {
                citingYearsByTarget[refKey, default: [:]][sourceYear, default: 0] += 1
            }
        }
        for e in entries {
            for citerKey in Set(e.citedByKeys) where citerKey != e.citeKey {
                if let citerYr = entryByKey[citerKey]?.year {
                    citingYearsByTarget[e.citeKey, default: [:]][citerYr, default: 0] += 1
                }
            }
        }

        // A. Paper Citation Bursts
        var paperBursts: [KleinbergBurstEpisode] = []
        for (targetKey, countsByYear) in citingYearsByTarget.sorted(by: { $0.key < $1.key }) {
            let pubYr = entryByKey[targetKey]?.year ?? minYr
            // Evaluate burstiness from publication year onward
            let activeIndices = orderedYears.indices.filter { orderedYears[$0] >= pubYr && dtStream[$0] > 0 }
            guard activeIndices.count >= 2 else { continue }
            let subYears = activeIndices.map { orderedYears[$0] }
            let subDt = activeIndices.map { dtStream[$0] }
            let subRt = subYears.map { min(countsByYear[$0] ?? 0, annualDocs[$0] ?? 0) }
            let totalR = subRt.reduce(0, +)
            guard totalR >= 2 else { continue }

            let title = entryByKey[targetKey]?.title ?? targetKey
            let episodes = Self.solveKleinbergViterbiStream(
                targetIdentifier: targetKey,
                displayLabel: title,
                kind: "Paper Citation Surge",
                years: subYears,
                eventCountsRt: subRt,
                totalTrialsDt: subDt,
                scalingS: sBase,
                gamma: gamma,
                kStates: kStates
            )
            paperBursts.append(contentsOf: episodes)
        }

        // B. Topical Keyword Bursts across Titles & Abstracts
        var keywordYearCounts: [String: [Int: Int]] = [:]
        var keywordDocFreq: [String: Int] = [:]
        for e in validEntries {
            guard let yr = e.year else { continue }
            let uniqueWords = Set(Self.extractDomainKeywords(from: e.title + " " + (e.abstractText ?? "")))
            for word in uniqueWords {
                keywordYearCounts[word, default: [:]][yr, default: 0] += 1
                keywordDocFreq[word, default: 0] += 1
            }
        }

        let activeYearIndices = orderedYears.indices.filter { dtStream[$0] > 0 }
        let activeYears = activeYearIndices.map { orderedYears[$0] }
        let activeDt = activeYearIndices.map { dtStream[$0] }

        var keywordBursts: [KleinbergBurstEpisode] = []
        if activeYears.count >= 2 {
            for (term, totalDF) in keywordDocFreq.sorted(by: { $0.key < $1.key }) where totalDF >= 2 {
                let yearMap = keywordYearCounts[term] ?? [:]
                let rt = activeYears.map { min(yearMap[$0] ?? 0, annualDocs[$0] ?? 0) }
                let episodes = Self.solveKleinbergViterbiStream(
                    targetIdentifier: term,
                    displayLabel: term.capitalized,
                    kind: "Topical Research Front",
                    years: activeYears,
                    eventCountsRt: rt,
                    totalTrialsDt: activeDt,
                    scalingS: sBase,
                    gamma: gamma,
                    kStates: kStates
                )
                keywordBursts.append(contentsOf: episodes)
            }
        }

        let sortEpisodes: (KleinbergBurstEpisode, KleinbergBurstEpisode) -> Bool = { a, b in
            if abs(a.burstStrengthWeight - b.burstStrengthWeight) > 1e-9 {
                return a.burstStrengthWeight > b.burstStrengthWeight
            }
            if a.peakStateLevel != b.peakStateLevel {
                return a.peakStateLevel > b.peakStateLevel
            }
            return a.id < b.id
        }
        paperBursts.sort(by: sortEpisodes)
        keywordBursts.sort(by: sortEpisodes)

        return KleinbergBurstAnalysisReport(
            minYear: minYr,
            maxYear: maxYr,
            scalingBaseS: sBase,
            transitionGamma: gamma,
            stateCountK: kStates,
            paperCitationBursts: paperBursts,
            topicalKeywordBursts: keywordBursts,
            annualPublicationCounts: annualDocs
        )
    }

    // MARK: - Internal Graph & Dynamic-Programming Algorithms

    private func synthesizeHybridEdges(
        from sortedEntries: [BibliographyEntry],
        keyToIdx: [String: Int]
    ) -> [CitationGraphEdge] {
        let n = sortedEntries.count
        var directSet = Set<String>()
        var outRefs = [Set<Int>](repeating: [], count: n)
        var edges: [CitationGraphEdge] = []

        for (u, entry) in sortedEntries.enumerated() {
            for ref in entry.referencesKeys {
                if let v = keyToIdx[ref], u != v {
                    outRefs[u].insert(v)
                    let key = "\(u)->\(v)"
                    if directSet.insert(key).inserted {
                        edges.append(CitationGraphEdge(sourceCiteKey: entry.citeKey, targetCiteKey: ref, kind: .directCitation, weight: 1.0))
                    }
                }
            }
            for citer in entry.citedByKeys {
                if let cIdx = keyToIdx[citer], cIdx != u {
                    outRefs[cIdx].insert(u)
                    let key = "\(cIdx)->\(u)"
                    if directSet.insert(key).inserted {
                        edges.append(CitationGraphEdge(sourceCiteKey: citer, targetCiteKey: entry.citeKey, kind: .directCitation, weight: 1.0))
                    }
                }
            }
        }

        for i in 0..<n {
            for j in (i + 1)..<n {
                var coCited = 0
                for k in 0..<n where outRefs[k].contains(i) && outRefs[k].contains(j) {
                    coCited += 1
                }
                if coCited > 0 {
                    edges.append(
                        CitationGraphEdge(
                            sourceCiteKey: sortedEntries[i].citeKey,
                            targetCiteKey: sortedEntries[j].citeKey,
                            kind: .coCitation,
                            weight: Double(coCited) * 0.70
                        )
                    )
                }
                let coupled = outRefs[i].intersection(outRefs[j]).count
                if coupled > 0 {
                    edges.append(
                        CitationGraphEdge(
                            sourceCiteKey: sortedEntries[i].citeKey,
                            targetCiteKey: sortedEntries[j].citeKey,
                            kind: .bibliographicCoupling,
                            weight: Double(coupled) * 0.50
                        )
                    )
                }
            }
        }
        return edges
    }

    private static func computeModularity(
        adj: [[Int: Double]],
        comm: [Int],
        deg: [Double],
        twiceM: Double,
        gamma: Double
    ) -> Double {
        guard twiceM > 1e-12 else { return 0.0 }
        let n = adj.count
        var intraByComm: [Int: Double] = [:]
        var totByComm: [Int: Double] = [:]

        for u in 0..<n {
            let cu = comm[u]
            totByComm[cu, default: 0.0] += deg[u]
            for (v, w) in adj[u] where comm[v] == cu {
                intraByComm[cu, default: 0.0] += w
            }
        }

        var q = 0.0
        for (c, tot) in totByComm {
            let intra = intraByComm[c] ?? 0.0
            q += (intra / twiceM) - gamma * Foundation.pow(tot / twiceM, 2.0)
        }
        return q
    }

    /// Exact Brandes (2001) unweighted betweenness centrality in $O(VE)$ time.
    private static func brandesUnweightedBetweenness(nodeCount n: Int, adj: [[Int]]) -> [Double] {
        guard n > 2 else { return Array(repeating: 0.0, count: n) }
        var cb = Array(repeating: 0.0, count: n)

        for s in 0..<n {
            var stack: [Int] = []
            stack.reserveCapacity(n)
            var preds = [[Int]](repeating: [], count: n)
            var sigma = Array(repeating: 0.0, count: n)
            sigma[s] = 1.0
            var dist = Array(repeating: -1, count: n)
            dist[s] = 0
            var queue: [Int] = [s]
            var qHead = 0

            while qHead < queue.count {
                let v = queue[qHead]
                qHead += 1
                stack.append(v)
                for w in adj[v] {
                    if dist[w] < 0 {
                        dist[w] = dist[v] + 1
                        queue.append(w)
                    }
                    if dist[w] == dist[v] + 1 {
                        sigma[w] += sigma[v]
                        preds[w].append(v)
                    }
                }
            }

            var delta = Array(repeating: 0.0, count: n)
            while let w = stack.popLast() {
                if sigma[w] > 0.0 {
                    for v in preds[w] {
                        delta[v] += (sigma[v] / sigma[w]) * (1.0 + delta[w])
                    }
                }
                if w != s {
                    cb[w] += delta[w]
                }
            }
        }

        // Undirected Brandes normalization: divide by (n - 1)(n - 2) since each undirected pair is traversed from both endpoints
        let norm = Double((n - 1) * (n - 2))
        return norm > 0.0 ? cb.map { $0 / norm } : cb
    }

    /// Exact Brandes (2001) weighted shortest-path betweenness centrality in $O(VE + V^2 \log V)$ via Dijkstra min-heap.
    private static func brandesWeightedBetweenness(
        nodeCount n: Int,
        adj: [[(neighbor: Int, distanceCost: Double)]]
    ) -> [Double] {
        guard n > 2 else { return Array(repeating: 0.0, count: n) }
        var cb = Array(repeating: 0.0, count: n)
        let eps = 1e-10

        for s in 0..<n {
            var stack: [Int] = []
            stack.reserveCapacity(n)
            var preds = [[Int]](repeating: [], count: n)
            var sigma = Array(repeating: 0.0, count: n)
            sigma[s] = 1.0
            var dist = Array(repeating: Double.infinity, count: n)
            dist[s] = 0.0

            var pq = IndexedDistanceMinHeap()
            pq.push(node: s, dist: 0.0)

            while let current = pq.popMin() {
                let v = current.node
                if current.dist > dist[v] + eps {
                    continue
                }
                stack.append(v)
                for edge in adj[v] {
                    let w = edge.neighbor
                    let altDist = dist[v] + edge.distanceCost
                    if altDist < dist[w] - eps {
                        dist[w] = altDist
                        sigma[w] = sigma[v]
                        preds[w] = [v]
                        pq.push(node: w, dist: altDist)
                    } else if abs(altDist - dist[w]) <= eps {
                        sigma[w] += sigma[v]
                        preds[w].append(v)
                    }
                }
            }

            var delta = Array(repeating: 0.0, count: n)
            while let w = stack.popLast() {
                if sigma[w] > 0.0 {
                    for v in preds[w] {
                        delta[v] += (sigma[v] / sigma[w]) * (1.0 + delta[w])
                    }
                }
                if w != s {
                    cb[w] += delta[w]
                }
            }
        }

        let norm = Double((n - 1) * (n - 2))
        return norm > 0.0 ? cb.map { $0 / norm } : cb
    }

    /// Computes Burt (1992) ego-network constraint $C_i$ and effective non-redundant network size.
    private static func computeBurtStructuralHoleMetrics(
        ego i: Int,
        undirectedAdj: [[Int: Double]]
    ) -> (constraint: Double, effectiveSize: Double) {
        let egoNbrs = undirectedAdj[i]
        guard !egoNbrs.isEmpty else { return (1.0, 0.0) }
        let egoSum = egoNbrs.values.reduce(0.0, +)
        guard egoSum > 1e-12 else { return (1.0, 0.0) }

        // Proportional tie investments p_{ij} = w_{ij} / sum_k w_{ik}
        var pijMap: [Int: Double] = [:]
        for (j, w) in egoNbrs {
            pijMap[j] = w / egoSum
        }

        // Precompute neighbor marginal totals and max tie for effective size
        var nbrTotals: [Int: Double] = [:]
        var nbrMaxTie: [Int: Double] = [:]
        for j in egoNbrs.keys {
            let jAdj = undirectedAdj[j]
            nbrTotals[j] = max(1e-12, jAdj.values.reduce(0.0, +))
            nbrMaxTie[j] = max(1e-12, jAdj.values.max() ?? 1.0)
        }

        var totalConstraint = 0.0
        var effectiveSizeAccum = 0.0

        for (j, pij) in pijMap {
            var indirectInvestment = 0.0
            var redundancySum = 0.0
            for (q, piq) in pijMap where q != j {
                if let wqj = undirectedAdj[q][j], wqj > 0.0 {
                    let pqj = wqj / (nbrTotals[q] ?? 1.0)
                    indirectInvestment += piq * pqj

                    let mqj = (undirectedAdj[j][q] ?? 0.0) / (nbrMaxTie[j] ?? 1.0)
                    redundancySum += piq * mqj
                }
            }
            let dyadic = pij + indirectInvestment
            totalConstraint += dyadic * dyadic
            effectiveSizeAccum += max(0.0, 1.0 - redundancySum)
        }

        return (totalConstraint, effectiveSizeAccum)
    }

    /// Exact Kleinberg (2002) Viterbi solver for discrete binomial/Poisson batched streams $(r_t, d_t)_{t=1}^T$.
    private static func solveKleinbergViterbiStream(
        targetIdentifier: String,
        displayLabel: String,
        kind: String,
        years: [Int],
        eventCountsRt: [Int],
        totalTrialsDt: [Int],
        scalingS: Double,
        gamma: Double,
        kStates: Int
    ) -> [KleinbergBurstEpisode] {
        let tLen = years.count
        let sumR = eventCountsRt.reduce(0, +)
        let sumD = totalTrialsDt.reduce(0, +)
        guard tLen >= 2, sumR > 0, sumD > 0 else { return [] }

        let p0 = max(1e-6, min(0.45, Double(sumR) / Double(sumD)))
        var stateProbs = Array(repeating: p0, count: kStates)
        for q in 1..<kStates {
            stateProbs[q] = min(0.9999, p0 * Foundation.pow(scalingS, Double(q)))
        }

        let logT = Foundation.log(Double(max(2, tLen)))
        func transitionCost(from prevQ: Int, to nextQ: Int) -> Double {
            guard nextQ > prevQ else { return 0.0 }
            return Double(nextQ - prevQ) * gamma * logT
        }

        func emissionCost(stateQ: Int, r: Int, d: Int) -> Double {
            guard d > 0 else { return 0.0 }
            let p = stateProbs[stateQ]
            let clampedR = min(d, max(0, r))
            // Exact negative log binomial likelihood: -ln C(d, r) - r ln(p) - (d - r) ln(1 - p)
            let logComb = logBinomialCoefficient(n: d, k: clampedR)
            let logLik = logComb + Double(clampedR) * Foundation.log(p) + Double(d - clampedR) * Foundation.log(1.0 - p)
            return -logLik
        }

        // Dynamic programming table: dp[t][q] and backpointer[t][q]
        var dp = Array(repeating: Array(repeating: Double.infinity, count: kStates), count: tLen)
        var backptr = Array(repeating: Array(repeating: 0, count: kStates), count: tLen)

        for q in 0..<kStates {
            dp[0][q] = transitionCost(from: 0, to: q) + emissionCost(stateQ: q, r: eventCountsRt[0], d: totalTrialsDt[0])
            backptr[0][q] = 0
        }

        for t in 1..<tLen {
            for nextQ in 0..<kStates {
                let emit = emissionCost(stateQ: nextQ, r: eventCountsRt[t], d: totalTrialsDt[t])
                var bestPrevCost = Double.infinity
                var bestPrevState = 0
                for prevQ in 0..<kStates {
                    let cand = dp[t - 1][prevQ] + transitionCost(from: prevQ, to: nextQ) + emit
                    if cand < bestPrevCost {
                        bestPrevCost = cand
                        bestPrevState = prevQ
                    }
                }
                dp[t][nextQ] = bestPrevCost
                backptr[t][nextQ] = bestPrevState
            }
        }

        // Backtrack optimal Viterbi state sequence q_0, ..., q_{T-1}
        var optimalStates = Array(repeating: 0, count: tLen)
        var bestFinalQ = 0
        var bestFinalVal = dp[tLen - 1][0]
        for q in 1..<kStates {
            if dp[tLen - 1][q] < bestFinalVal {
                bestFinalVal = dp[tLen - 1][q]
                bestFinalQ = q
            }
        }
        optimalStates[tLen - 1] = bestFinalQ
        for t in stride(from: tLen - 1, through: 1, by: -1) {
            optimalStates[t - 1] = backptr[t][optimalStates[t]]
        }

        // Extract maximal contiguous hierarchical burst intervals for each elevation level L >= 1 (Kleinberg 2002 Sec. 3)
        // Collect top-level non-redundant burst intervals where optimalStates[t] >= 1
        var episodes: [KleinbergBurstEpisode] = []
        var idx = 0
        while idx < tLen {
            guard optimalStates[idx] >= 1 else {
                idx += 1
                continue
            }
            let startIdx = idx
            var endIdx = idx
            var peakLevel = optimalStates[idx]
            while endIdx + 1 < tLen && optimalStates[endIdx + 1] >= 1 {
                endIdx += 1
                peakLevel = max(peakLevel, optimalStates[endIdx])
            }

            var weightSum = 0.0
            var obsEvents = 0
            var windowTrials = 0
            for t in startIdx...endIdx {
                let r = eventCountsRt[t]
                let d = totalTrialsDt[t]
                let q = optimalStates[t]
                obsEvents += r
                windowTrials += d
                // Kleinberg burst weight: excess log-likelihood improvement over baseline state 0
                weightSum += max(0.0, emissionCost(stateQ: 0, r: r, d: d) - emissionCost(stateQ: q, r: r, d: d))
            }

            let expectedEvents = Double(windowTrials) * p0
            let fold = expectedEvents > 1e-9 ? (Double(obsEvents) / expectedEvents) : Double(obsEvents)
            let sYr = years[startIdx]
            let eYr = years[endIdx]

            if weightSum > 0.05 {
                episodes.append(
                    KleinbergBurstEpisode(
                        targetIdentifier: targetIdentifier,
                        displayLabel: displayLabel,
                        kind: kind,
                        startYear: sYr,
                        endYear: eYr,
                        durationYears: (eYr - sYr) + 1,
                        peakStateLevel: peakLevel,
                        burstStrengthWeight: weightSum,
                        observedEventsInWindow: obsEvents,
                        baselineExpectedEvents: expectedEvents,
                        foldElevationRatio: fold
                    )
                )
            }

            idx = endIdx + 1
        }

        return episodes
    }

    private static func logBinomialCoefficient(n: Int, k: Int) -> Double {
        if k <= 0 || k >= n { return 0.0 }
        return logFactorialApprox(n) - logFactorialApprox(k) - logFactorialApprox(n - k)
    }

    /// Exact log-factorial for small $n \le 32$ and Stirling-Ramanujan $O(n^{-3})$ series for larger $n$.
    private static func logFactorialApprox(_ n: Int) -> Double {
        if n <= 1 { return 0.0 }
        if n <= 32 {
            var acc = 0.0
            for i in 2...n {
                acc += Foundation.log(Double(i))
            }
            return acc
        }
        let x = Double(n)
        return x * Foundation.log(x) - x + 0.5 * Foundation.log(2.0 * Double.pi * x)
            + (1.0 / (12.0 * x)) - (1.0 / (360.0 * x * x * x))
    }

    private static let themeStopWords: Set<String> = [
        "the", "and", "for", "with", "from", "using", "via", "into", "over", "under",
        "towards", "toward", "based", "study", "studies", "analysis", "system", "systems",
        "method", "methods", "approach", "approaches", "model", "models", "framework",
        "paper", "evaluation", "empirical", "large", "modern", "novel", "efficient"
    ]

    private static func deriveThemeLabel(for entries: [BibliographyEntry], fallbackID: Int) -> String {
        var counts: [String: Int] = [:]
        for entry in entries {
            let toks = Set(extractDomainKeywords(from: entry.title))
            for t in toks {
                counts[t, default: 0] += 1
            }
        }
        let top = counts.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
            return a.key < b.key
        }.prefix(2).map { $0.key.capitalized }
        return top.isEmpty ? "Community \(fallbackID + 1)" : top.joined(separator: " & ")
    }

    private static func extractDomainKeywords(from text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !themeStopWords.contains($0) && Int($0) == nil }
    }
}
