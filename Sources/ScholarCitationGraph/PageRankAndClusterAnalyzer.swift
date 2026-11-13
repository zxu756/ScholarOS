import Foundation
import ScholarModels

// MARK: - PageRank, Co-Citation / Bibliographic Coupling & Bridge-Paper Analyzer

public struct CitationKnowledgeGraphSnapshot: Sendable, Codable, Hashable {
    public let nodes: [CitationGraphNode]
    public let edges: [CitationGraphEdge]
    public let clusterLabels: [Int: String]
    public let bridgeCiteKeys: [String]

    public init(
        nodes: [CitationGraphNode],
        edges: [CitationGraphEdge],
        clusterLabels: [Int: String],
        bridgeCiteKeys: [String]
    ) {
        self.nodes = nodes
        self.edges = edges
        self.clusterLabels = clusterLabels
        self.bridgeCiteKeys = bridgeCiteKeys
    }
}

public struct CitationGraphBuilder: Sendable {
    public let layoutEngine: BarnesHutGraphLayoutEngine

    public init(layoutConfig: BarnesHutLayoutConfig = BarnesHutLayoutConfig()) {
        self.layoutEngine = BarnesHutGraphLayoutEngine(config: layoutConfig)
    }

    public func buildKnowledgeGraph(from entries: [BibliographyEntry]) -> CitationKnowledgeGraphSnapshot {
        guard !entries.isEmpty else {
            return CitationKnowledgeGraphSnapshot(nodes: [], edges: [], clusterLabels: [:], bridgeCiteKeys: [])
        }

        let sortedEntries = entries.sorted { $0.citeKey < $1.citeKey }
        let n = sortedEntries.count
        var keyToIndex: [String: Int] = [:]
        for (i, e) in sortedEntries.enumerated() {
            keyToIndex[e.citeKey] = i
        }

        var directAdj = [[Int]](repeating: [], count: n)
        var inDeg = [Int](repeating: 0, count: n)
        var outDeg = [Int](repeating: 0, count: n)
        var edges: [CitationGraphEdge] = []
        var seenDirect = Set<String>()

        for (u, entry) in sortedEntries.enumerated() {
            for refKey in entry.referencesKeys {
                if let v = keyToIndex[refKey], u != v {
                    let pairKey = "\(u)->\(v)"
                    if seenDirect.insert(pairKey).inserted {
                        directAdj[u].append(v)
                        outDeg[u] += 1
                        inDeg[v] += 1
                        edges.append(
                            CitationGraphEdge(
                                sourceCiteKey: entry.citeKey,
                                targetCiteKey: refKey,
                                kind: .directCitation,
                                weight: 1.0
                            )
                        )
                    }
                }
            }
            for citerKey in entry.citedByKeys {
                if let citerIdx = keyToIndex[citerKey], citerIdx != u {
                    let pairKey = "\(citerIdx)->\(u)"
                    if seenDirect.insert(pairKey).inserted {
                        directAdj[citerIdx].append(u)
                        outDeg[citerIdx] += 1
                        inDeg[u] += 1
                        edges.append(
                            CitationGraphEdge(
                                sourceCiteKey: citerKey,
                                targetCiteKey: entry.citeKey,
                                kind: .directCitation,
                                weight: 1.0
                            )
                        )
                    }
                }
            }
        }

        // Synthesize Co-Citation (two papers cited together by >=1 source) & Bibliographic Coupling (shared references)
        for i in 0..<n {
            for j in (i + 1)..<n {
                // Co-citation count: how many nodes k cite both i and j
                var coCitedCount = 0
                for k in 0..<n where directAdj[k].contains(i) && directAdj[k].contains(j) {
                    coCitedCount += 1
                }
                if coCitedCount > 0 {
                    edges.append(
                        CitationGraphEdge(
                            sourceCiteKey: sortedEntries[i].citeKey,
                            targetCiteKey: sortedEntries[j].citeKey,
                            kind: .coCitation,
                            weight: Double(coCitedCount) * 0.75
                        )
                    )
                }

                // Bibliographic coupling: shared outgoing references between i and j
                let refsI = Set(directAdj[i])
                let sharedRefs = refsI.intersection(directAdj[j]).count
                if sharedRefs > 0 {
                    edges.append(
                        CitationGraphEdge(
                            sourceCiteKey: sortedEntries[i].citeKey,
                            targetCiteKey: sortedEntries[j].citeKey,
                            kind: .bibliographicCoupling,
                            weight: Double(sharedRefs) * 0.55
                        )
                    )
                }
            }
        }

        // Power-Iteration PageRank (damping = 0.85)
        let pageRanks = computePageRank(nodeCount: n, adjacency: directAdj, damping: 0.85)

        // Weighted Label-Propagation Community Clustering
        let clusters = computeWeightedCommunities(nodeCount: n, entries: sortedEntries, edges: edges, keyToIndex: keyToIndex)

        // Brandes Undirected Shortest-Path Betweenness & Cross-Cluster Bridge Detection
        let betweenness = computeBetweennessCentrality(nodeCount: n, edges: edges, keyToIndex: keyToIndex)
        var undirectedNeighbors = [Set<Int>](repeating: [], count: n)
        for e in edges {
            if let u = keyToIndex[e.sourceCiteKey], let v = keyToIndex[e.targetCiteKey], u != v {
                undirectedNeighbors[u].insert(v)
                undirectedNeighbors[v].insert(u)
            }
        }

        var rawNodes: [CitationGraphNode] = []
        rawNodes.reserveCapacity(n)
        var bridgeKeys: [String] = []

        for i in 0..<n {
            let entry = sortedEntries[i]
            let yearVal = entry.year ?? 2026
            let neighborClusters = Set(undirectedNeighbors[i].map { clusters[$0] })
            let connectsMultipleClusters = neighborClusters.subtracting([clusters[i]]).count >= 1 && undirectedNeighbors[i].count >= 2
            let isBridge = connectsMultipleClusters && (betweenness[i] > 0.05 || neighborClusters.count >= 2)
            if isBridge {
                bridgeKeys.append(entry.citeKey)
            }

            rawNodes.append(
                CitationGraphNode(
                    citeKey: entry.citeKey,
                    title: entry.title,
                    authorYearLabel: "\(entry.firstAuthorFamily) (\(yearVal))",
                    year: yearVal,
                    inDegree: inDeg[i],
                    outDegree: outDeg[i],
                    pageRank: pageRanks[i],
                    betweennessScore: betweenness[i],
                    clusterIndex: clusters[i],
                    isBridgePaper: isBridge
                )
            )
        }

        let laidOutNodes = layoutEngine.computeLayout(nodes: rawNodes, edges: edges)
        let clusterLabels = synthesizeClusterThemes(entries: sortedEntries, clusters: clusters)

        return CitationKnowledgeGraphSnapshot(
            nodes: laidOutNodes,
            edges: edges,
            clusterLabels: clusterLabels,
            bridgeCiteKeys: bridgeKeys
        )
    }

    private func computePageRank(nodeCount n: Int, adjacency: [[Int]], damping: Double) -> [Double] {
        guard n > 0 else { return [] }
        let invN = 1.0 / Double(n)
        var rank = [Double](repeating: invN, count: n)
        let teleport = (1.0 - damping) * invN

        for _ in 0..<80 {
            var next = [Double](repeating: teleport, count: n)
            var danglingMass = 0.0
            for u in 0..<n {
                if adjacency[u].isEmpty {
                    danglingMass += rank[u]
                } else {
                    let share = damping * (rank[u] / Double(adjacency[u].count))
                    for v in adjacency[u] {
                        next[v] += share
                    }
                }
            }
            let danglingShare = damping * danglingMass * invN
            var l1Diff = 0.0
            for i in 0..<n {
                next[i] += danglingShare
                l1Diff += abs(next[i] - rank[i])
            }
            rank = next
            if l1Diff < 1e-8 { break }
        }
        return rank
    }

    private func computeWeightedCommunities(
        nodeCount n: Int,
        entries: [BibliographyEntry],
        edges: [CitationGraphEdge],
        keyToIndex: [String: Int]
    ) -> [Int] {
        var labels = Array(0..<n)
        var weightedAdj = [[(Int, Double)]](repeating: [], count: n)
        for e in edges {
            guard let u = keyToIndex[e.sourceCiteKey], let v = keyToIndex[e.targetCiteKey], u != v else { continue }
            weightedAdj[u].append((v, e.weight))
            weightedAdj[v].append((u, e.weight))
        }

        for _ in 0..<24 {
            var changed = false
            for i in 0..<n {
                guard !weightedAdj[i].isEmpty else { continue }
                var scoreByLabel: [Int: Double] = [:]
                for (nbr, w) in weightedAdj[i] {
                    scoreByLabel[labels[nbr], default: 0.0] += w
                }
                if let best = scoreByLabel.max(by: { lhs, rhs in
                    if abs(lhs.value - rhs.value) > 1e-9 { return lhs.value < rhs.value }
                    return lhs.key > rhs.key // deterministic tie-break toward smaller label
                })?.key, best != labels[i] {
                    labels[i] = best
                    changed = true
                }
            }
            if !changed { break }
        }

        // Re-index cluster IDs densely 0..<K
        var remap: [Int: Int] = [:]
        var nextCluster = 0
        return labels.map { raw in
            if let mapped = remap[raw] { return mapped }
            let assigned = nextCluster
            remap[raw] = assigned
            nextCluster += 1
            return assigned
        }
    }

    private func computeBetweennessCentrality(
        nodeCount n: Int,
        edges: [CitationGraphEdge],
        keyToIndex: [String: Int]
    ) -> [Double] {
        guard n > 2 else { return [Double](repeating: 0.0, count: n) }
        var adj = [[Int]](repeating: [], count: n)
        for e in edges {
            guard let u = keyToIndex[e.sourceCiteKey], let v = keyToIndex[e.targetCiteKey], u != v else { continue }
            if !adj[u].contains(v) { adj[u].append(v) }
            if !adj[v].contains(u) { adj[v].append(u) }
        }

        var cb = [Double](repeating: 0.0, count: n)
        for s in 0..<n {
            var stack: [Int] = []
            var preds = [[Int]](repeating: [], count: n)
            var sigma = [Double](repeating: 0.0, count: n)
            sigma[s] = 1.0
            var dist = [Int](repeating: -1, count: n)
            dist[s] = 0
            var queue: [Int] = [s]
            var qHead = 0

            while qHead < queue.count {
                let v = queue[qHead]
                qHead += 1
                stack.append(v)
                for w in adj[v] {
                    if dist[w] < 0 {
                        queue.append(w)
                        dist[w] = dist[v] + 1
                    }
                    if dist[w] == dist[v] + 1 {
                        sigma[w] += sigma[v]
                        preds[w].append(v)
                    }
                }
            }

            var delta = [Double](repeating: 0.0, count: n)
            while let w = stack.popLast() {
                for v in preds[w] where sigma[w] > 0 {
                    delta[v] += (sigma[v] / sigma[w]) * (1.0 + delta[w])
                }
                if w != s {
                    cb[w] += delta[w]
                }
            }
        }

        let norm = Double((n - 1) * (n - 2))
        guard norm > 0 else { return cb }
        return cb.map { $0 / norm }
    }

    private func synthesizeClusterThemes(entries: [BibliographyEntry], clusters: [Int]) -> [Int: String] {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "from", "using", "via", "towards", "into",
            "study", "analysis", "system", "systems", "based", "approach", "method"
        ]
        var freqByCluster: [Int: [String: Int]] = [:]
        for (i, entry) in entries.enumerated() {
            let cid = clusters[i]
            let words = entry.title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 && !stopWords.contains($0) }
            for w in words {
                freqByCluster[cid, default: [:]][w, default: 0] += 1
            }
        }

        var result: [Int: String] = [:]
        for (cid, counts) in freqByCluster {
            let top = counts.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }.prefix(2).map { $0.key.capitalized }
            result[cid] = top.isEmpty ? "Cluster \(cid + 1)" : top.joined(separator: " & ")
        }
        return result
    }
}
