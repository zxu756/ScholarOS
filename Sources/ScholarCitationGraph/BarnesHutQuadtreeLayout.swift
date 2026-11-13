import Foundation
import ScholarModels

// MARK: - Barnes-Hut 2D Quadtree O(N log N) Force-Directed Layout Engine

private final class QuadtreeCell {
    let minX: Double
    let minY: Double
    let size: Double
    var mass: Double = 0.0
    var centerOfMassX: Double = 0.0
    var centerOfMassY: Double = 0.0
    var singleNodeIndex: Int?
    var nw: QuadtreeCell?
    var ne: QuadtreeCell?
    var sw: QuadtreeCell?
    var se: QuadtreeCell?

    init(minX: Double, minY: Double, size: Double) {
        self.minX = minX
        self.minY = minY
        self.size = max(1e-3, size)
    }

    var isLeaf: Bool {
        nw == nil && ne == nil && sw == nil && se == nil
    }

    func insert(nodeIndex: Int, x: Double, y: Double, weight: Double, depth: Int = 0) {
        let clampedWeight = max(0.1, weight)
        let newMass = mass + clampedWeight
        centerOfMassX = (centerOfMassX * mass + x * clampedWeight) / newMass
        centerOfMassY = (centerOfMassY * mass + y * clampedWeight) / newMass
        mass = newMass

        if depth >= 18 {
            return
        }

        if isLeaf {
            if let existing = singleNodeIndex {
                singleNodeIndex = nil
                subdivide()
                // Existing node center of mass was previously sole mass before current insert;
                // recover approximate previous coordinate cleanly:
                let prevMass = newMass - clampedWeight
                let prevX = prevMass > 0 ? (centerOfMassX * newMass - x * clampedWeight) / prevMass : x
                let prevY = prevMass > 0 ? (centerOfMassY * newMass - y * clampedWeight) / prevMass : y
                insertIntoQuadrant(nodeIndex: existing, x: prevX, y: prevY, weight: prevMass, depth: depth + 1)
                insertIntoQuadrant(nodeIndex: nodeIndex, x: x, y: y, weight: clampedWeight, depth: depth + 1)
            } else {
                singleNodeIndex = nodeIndex
            }
        } else {
            insertIntoQuadrant(nodeIndex: nodeIndex, x: x, y: y, weight: clampedWeight, depth: depth + 1)
        }
    }

    private func subdivide() {
        let half = size * 0.5
        nw = QuadtreeCell(minX: minX, minY: minY + half, size: half)
        ne = QuadtreeCell(minX: minX + half, minY: minY + half, size: half)
        sw = QuadtreeCell(minX: minX, minY: minY, size: half)
        se = QuadtreeCell(minX: minX + half, minY: minY, size: half)
    }

    private func insertIntoQuadrant(nodeIndex: Int, x: Double, y: Double, weight: Double, depth: Int) {
        let midX = minX + size * 0.5
        let midY = minY + size * 0.5
        if y >= midY {
            if x < midX {
                nw?.insert(nodeIndex: nodeIndex, x: x, y: y, weight: weight, depth: depth)
            } else {
                ne?.insert(nodeIndex: nodeIndex, x: x, y: y, weight: weight, depth: depth)
            }
        } else {
            if x < midX {
                sw?.insert(nodeIndex: nodeIndex, x: x, y: y, weight: weight, depth: depth)
            } else {
                se?.insert(nodeIndex: nodeIndex, x: x, y: y, weight: weight, depth: depth)
            }
        }
    }

    func accumulateRepulsion(
        forNode nodeIndex: Int,
        px: Double,
        py: Double,
        theta: Double,
        repulsionConstant: Double,
        fx: inout Double,
        fy: inout Double
    ) {
        guard mass > 0 else { return }
        if isLeaf && singleNodeIndex == nodeIndex {
            return
        }

        let dx = px - centerOfMassX
        let dy = py - centerOfMassY
        let distSq = max(4.0, dx * dx + dy * dy)
        let dist = distSq.squareRoot()

        if isLeaf || (size / dist) < theta {
            let force = (repulsionConstant * mass) / distSq
            fx += (dx / dist) * force
            fy += (dy / dist) * force
        } else {
            nw?.accumulateRepulsion(forNode: nodeIndex, px: px, py: py, theta: theta, repulsionConstant: repulsionConstant, fx: &fx, fy: &fy)
            ne?.accumulateRepulsion(forNode: nodeIndex, px: px, py: py, theta: theta, repulsionConstant: repulsionConstant, fx: &fx, fy: &fy)
            sw?.accumulateRepulsion(forNode: nodeIndex, px: px, y: py, theta: theta, repulsionConstant: repulsionConstant, fx: &fx, fy: &fy)
            se?.accumulateRepulsion(forNode: nodeIndex, px: px, py: py, theta: theta, repulsionConstant: repulsionConstant, fx: &fx, fy: &fy)
        }
    }

    private func accumulateRepulsion(
        forNode nodeIndex: Int,
        px: Double,
        y py: Double,
        theta: Double,
        repulsionConstant: Double,
        fx: inout Double,
        fy: inout Double
    ) {
        accumulateRepulsion(
            forNode: nodeIndex,
            px: px,
            py: py,
            theta: theta,
            repulsionConstant: repulsionConstant,
            fx: &fx,
            fy: &fy
        )
    }
}

public struct BarnesHutLayoutConfig: Sendable, Codable, Hashable {
    public var iterations: Int
    public var theta: Double
    public var repulsionStrength: Double
    public var springStiffness: Double
    public var idealEdgeLength: Double
    public var centerGravity: Double
    public var canvasWidth: Double
    public var canvasHeight: Double

    public init(
        iterations: Int = 180,
        theta: Double = 0.72,
        repulsionStrength: Double = 6800.0,
        springStiffness: Double = 0.045,
        idealEdgeLength: Double = 140.0,
        centerGravity: Double = 0.018,
        canvasWidth: Double = 1200.0,
        canvasHeight: Double = 800.0
    ) {
        self.iterations = iterations
        self.theta = theta
        self.repulsionStrength = repulsionStrength
        self.springStiffness = springStiffness
        self.idealEdgeLength = idealEdgeLength
        self.centerGravity = centerGravity
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }
}

public struct BarnesHutGraphLayoutEngine: Sendable {
    public let config: BarnesHutLayoutConfig

    public init(config: BarnesHutLayoutConfig = BarnesHutLayoutConfig()) {
        self.config = config
    }

    /// Computes a deterministic, high-readability 2D layout for `nodes` and `edges` in $O(I \cdot N \log N)$ time.
    public func computeLayout(nodes: [CitationGraphNode], edges: [CitationGraphEdge]) -> [CitationGraphNode] {
        guard !nodes.isEmpty else { return [] }
        var positioned = nodes
        let n = positioned.count
        let cx = config.canvasWidth * 0.5
        let cy = config.canvasHeight * 0.5

        // Seed deterministic golden-angle phyllotaxis spiral grouped subtly by clusterIndex
        let goldenAngle = Double.pi * (3.0 - 5.0.squareRoot())
        for i in 0..<n {
            if positioned[i].x == 0.0 && positioned[i].y == 0.0 {
                let radius = 34.0 * Double(i + 1).squareRoot()
                let angle = Double(i) * goldenAngle + Double(positioned[i].clusterIndex) * 0.85
                positioned[i].x = cx + Foundation.cos(angle) * radius
                positioned[i].y = cy + Foundation.sin(angle) * radius
            }
        }

        if n == 1 {
            positioned[0].x = cx
            positioned[0].y = cy
            return positioned
        }

        var indexByKey: [String: Int] = [:]
        indexByKey.reserveCapacity(n)
        for (idx, node) in positioned.enumerated() {
            indexByKey[node.citeKey] = idx
        }

        let resolvedEdges: [(Int, Int, Double)] = edges.compactMap { edge in
            guard let u = indexByKey[edge.sourceCiteKey],
                  let v = indexByKey[edge.targetCiteKey],
                  u != v else { return nil }
            return (u, v, max(0.25, edge.weight))
        }

        var vx = [Double](repeating: 0.0, count: n)
        var vy = [Double](repeating: 0.0, count: n)

        for step in 0..<max(1, config.iterations) {
            let cooling = 1.0 - (Double(step) / Double(max(1, config.iterations))) * 0.82

            var minX = positioned[0].x
            var maxX = positioned[0].x
            var minY = positioned[0].y
            var maxY = positioned[0].y
            for i in 1..<n {
                minX = min(minX, positioned[i].x)
                maxX = max(maxX, positioned[i].x)
                minY = min(minY, positioned[i].y)
                maxY = max(maxY, positioned[i].y)
            }
            let span = max(maxX - minX, maxY - minY) + 64.0
            let quad = QuadtreeCell(minX: minX - 32.0, minY: minY - 32.0, size: span)

            for i in 0..<n {
                let nodeMass = 1.0 + positioned[i].pageRank * Double(n) * 0.35
                quad.insert(nodeIndex: i, x: positioned[i].x, y: positioned[i].y, weight: nodeMass)
            }

            var fx = [Double](repeating: 0.0, count: n)
            var fy = [Double](repeating: 0.0, count: n)

            // 1. Barnes-Hut repulsive forces
            for i in 0..<n {
                quad.accumulateRepulsion(
                    forNode: i,
                    px: positioned[i].x,
                    py: positioned[i].y,
                    theta: config.theta,
                    repulsionConstant: config.repulsionStrength,
                    fx: &fx[i],
                    fy: &fy[i]
                )
                // Gentle radial gravity toward canvas center
                fx[i] += (cx - positioned[i].x) * config.centerGravity
                fy[i] += (cy - positioned[i].y) * config.centerGravity
            }

            // 2. Hooke spring attractive forces along citation/co-citation edges
            for (u, v, weight) in resolvedEdges {
                let dx = positioned[v].x - positioned[u].x
                let dy = positioned[v].y - positioned[u].y
                let dist = max(1.0, (dx * dx + dy * dy).squareRoot())
                let displacement = dist - config.idealEdgeLength
                let springForce = config.springStiffness * displacement * weight
                let ux = (dx / dist) * springForce
                let uy = (dy / dist) * springForce
                fx[u] += ux
                fy[u] += uy
                fx[v] -= ux
                fy[v] -= uy
            }

            // 3. Damped velocity integration & margin clamping
            let maxStep = 42.0 * cooling + 1.5
            let pad = 68.0
            for i in 0..<n {
                vx[i] = (vx[i] + fx[i] * 0.08) * 0.72
                vy[i] = (vy[i] + fy[i] * 0.08) * 0.72
                let speed = (vx[i] * vx[i] + vy[i] * vy[i]).squareRoot()
                if speed > maxStep {
                    let scale = maxStep / speed
                    vx[i] *= scale
                    vy[i] *= scale
                }
                positioned[i].x = min(max(pad, positioned[i].x + vx[i]), config.canvasWidth - pad)
                positioned[i].y = min(max(pad, positioned[i].y + vy[i]), config.canvasHeight - pad)
            }
        }

        return positioned
    }
}
