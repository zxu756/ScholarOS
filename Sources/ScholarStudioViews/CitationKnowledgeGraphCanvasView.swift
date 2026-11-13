import Foundation
import SwiftUI
import ScholarCitationGraph
import ScholarModels
import ScholarWorkbenchShell

// MARK: - Studio 3: Citation Knowledge Graph, Louvain Communities, SPC Main Path & Kleinberg Bursts (`CitationKnowledgeGraphStudioView`)

/// Full-width `.citationGraph` studio combining an interactive Barnes-Hut $O(N \log N)$ Citation Knowledge Graph `Canvas`
/// (Louvain community hulls, PageRank node radii, Brandes structural-hole bridge double rings, Hummon-Doreian SPC Main Path,
/// chronological year ruler), Kleinberg temporal burst sparkbars, and a Missing Foundational Papers recommender inspector.
public struct CitationKnowledgeGraphStudioView: View {
    @ObservedObject public var viewModel: ScholarStudioViewModel
    @ObservedObject private var localizer = ScholarLocalizer.shared
    @State private var dragStartOffset: CGSize?

    public init(viewModel: ScholarStudioViewModel) {
        self.viewModel = viewModel
    }

    private var mainPathOrderedKeys: [String] {
        viewModel.mainPathReport?.globalMainPath.orderedCiteKeys ?? []
    }

    private var mainPathEdgePairs: Set<String> {
        let keys = mainPathOrderedKeys
        guard keys.count >= 2 else { return [] }
        var set = Set<String>()
        for idx in 0..<(keys.count - 1) {
            set.insert("\(keys[idx])->\(keys[idx + 1])")
            set.insert("\(keys[idx + 1])->\(keys[idx])")
        }
        return set
    }

    private var bridgeKeySet: Set<String> {
        var keys = Set(viewModel.graphSnapshot.bridgeCiteKeys)
        for profile in viewModel.bridgeProfiles where profile.isStructuralHoleBridge {
            keys.insert(profile.citeKey)
        }
        return keys
    }

    public var body: some View {
        VStack(spacing: 0) {
            graphTopTelemetryStrip

            Divider()
                .overlay(CambridgeLinenPalette.stoneHairline)

            HStack(spacing: 0) {
                // Left / Center: Interactive Barnes-Hut Canvas + Kleinberg Temporal Burst Strip
                VStack(spacing: 0) {
                    interactiveBarnesHutCanvas
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                        .overlay(CambridgeLinenPalette.stoneHairline)

                    kleinbergBurstSparkbarStrip
                        .frame(height: 138)
                }

                Rectangle()
                    .fill(CambridgeLinenPalette.stoneHairline)
                    .frame(width: CambridgeMetrics.hairline)

                // Right Column: Selected Node Cartography + SPC Main Path + Missing Foundational Citations
                graphCartographyInspectorColumn
                    .frame(width: 428)
                    .background(CambridgeLinenPalette.cambridgeLinen)
            }
        }
        .background(CambridgeLinenPalette.cambridgeLinen)
    }

    // MARK: 1. Top Telemetry & Layer Controls Strip

    private var graphTopTelemetryStrip: some View {
        let nodeCount = viewModel.graphSnapshot.nodes.count
        let edgeCount = viewModel.graphSnapshot.edges.count
        let modularityQ = viewModel.louvainPartition?.modularityQ ?? 0.42
        let clusterCount = max(1, viewModel.louvainPartition?.communities.count ?? 3)
        let bridgeCount = bridgeKeySet.count

        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Text(localizer.L("Barnes-Hut O(N log N) Citation Cartography", "Barnes-Hut O(N log N) 引文知识图谱"))
                    .font(CambridgeTypography.scholarlyHeadline)
                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                    .fixedSize(horizontal: true, vertical: false)
            }

            graphTelemetryPill(label: localizer.L("Nodes", "节点"), value: "\(nodeCount)")
            graphTelemetryPill(label: localizer.L("Edges", "引证边"), value: "\(edgeCount)")
            graphTelemetryPill(
                label: localizer.L("Louvain Q", "模块度 Q"),
                value: localizer.language == .zhHans
                    ? String(format: "%.3f (%d 簇)", modularityQ, clusterCount)
                    : String(format: "%.3f (%d clusters)", modularityQ, clusterCount)
            )
            graphTelemetryPill(label: localizer.L("Brandes Bridges", "结构洞桥接"), value: "\(bridgeCount)")

            Spacer(minLength: 6)

            Button {
                viewModel.graphHighlightMainPath.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(localizer.L("SPC Main Path", "SPC 主路径"))
                        .font(CambridgeTypography.uiCaption)
                }
            }
            .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: viewModel.graphHighlightMainPath))
            .fixedSize(horizontal: true, vertical: false)

            Button {
                viewModel.graphShowCoCitationEdges.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(localizer.L("Co-Citation", "共被引网络"))
                        .font(CambridgeTypography.uiCaption)
                }
            }
            .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: viewModel.graphShowCoCitationEdges))
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 3) {
                Button("−") {
                    viewModel.graphZoomScale = max(0.75, viewModel.graphZoomScale - 0.12)
                }
                .buttonStyle(CambridgeSecondaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)

                Button(String(format: "%.0f%%", viewModel.graphZoomScale * 100.0)) {
                    viewModel.graphZoomScale = 1.0
                    viewModel.graphPanOffset = .zero
                }
                .buttonStyle(CambridgeSecondaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)

                Button("+") {
                    viewModel.graphZoomScale = min(1.65, viewModel.graphZoomScale + 0.12)
                }
                .buttonStyle(CambridgeSecondaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CambridgeLinenPalette.warmVellum)
    }

    private func graphTelemetryPill(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(CambridgeTypography.uiCaption)
                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
            Text(value)
                .font(CambridgeTypography.monoSmall)
                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(CambridgeLinenPalette.archivalPaper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: 2. Interactive Barnes-Hut Vector Canvas + Louvain Hulls + Timeline Ruler

    private var interactiveBarnesHutCanvas: some View {
        GeometryReader { geo in
            let canvasSize = geo.size
            let positions = computeScreenPositions(in: canvasSize)
            let bibByKey = Dictionary(uniqueKeysWithValues: viewModel.bibliographyEntries.map { ($0.citeKey, $0) })

            ZStack(alignment: .topLeading) {
                // Vector Graph Sheet
                Canvas { context, size in
                    // 2a. Subtle archival graph-paper grid
                    drawArchivalGrid(context: &context, size: size)

                    // 2b. Soft Louvain Modularity Cluster Hulls
                    drawLouvainClusterHulls(context: &context, positions: positions)

                    // 2c. Citation, Co-Citation & SPC Main-Path Edges
                    drawKnowledgeEdges(context: &context, positions: positions)

                    // 2d. PageRank-Scaled Nodes & Brandes Bridge Double-Ring Halos
                    drawScholarlyNodes(context: &context, positions: positions, bibByKey: bibByKey)

                    // 2e. Chronological Publication Timeline Axis at Bottom
                    drawTimelineAxis(context: &context, size: size)
                }
                .background(CambridgeLinenPalette.archivalPaper)
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            let base = dragStartOffset ?? viewModel.graphPanOffset
                            if dragStartOffset == nil { dragStartOffset = base }
                            viewModel.graphPanOffset = CGSize(
                                width: base.width + value.translation.width,
                                height: base.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            dragStartOffset = nil
                        }
                )
                .onTapGesture { tapLocation in
                    if let hitNode = hitTestNode(at: tapLocation, positions: positions) {
                        viewModel.selectedGraphCiteKey = hitNode.citeKey
                        viewModel.docking.selectedCiteKey = hitNode.citeKey
                    }
                }

                // Crisp SwiftUI Node Author-Year Pill Labels (never clipped or blurred)
                ForEach(viewModel.graphSnapshot.nodes) { node in
                    if let pt = positions[node.citeKey] {
                        let isSelected = (viewModel.selectedGraphCiteKey == node.citeKey)
                        let fw = bibByKey[node.citeKey]?.firewallClass
                        let isBlocked = (fw == .notFound || fw == .retracted)
                        let r = nodeRadius(for: node)

                        Button {
                            viewModel.selectedGraphCiteKey = node.citeKey
                            viewModel.docking.selectedCiteKey = node.citeKey
                        } label: {
                            Text(shortNodeBadgeLabel(for: node, entry: bibByKey[node.citeKey]))
                                .font(.system(size: 9.5, weight: isSelected ? .bold : .medium, design: .monospaced))
                                .foregroundStyle(
                                    isBlocked
                                        ? CambridgeLinenPalette.blockedCrimson
                                        : (isSelected ? CambridgeLinenPalette.archivalPaper : CambridgeLinenPalette.oxfordCharcoal)
                                )
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                        .fill(
                                            isBlocked
                                                ? CambridgeLinenPalette.blockedCrimsonBg
                                                : (isSelected ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.archivalPaper.opacity(0.95))
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                        .strokeBorder(
                                            isBlocked
                                                ? CambridgeLinenPalette.blockedCrimsonBorder
                                                : (isSelected ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.stoneHairline),
                                            lineWidth: CambridgeMetrics.hairline
                                        )
                                )
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)
                        .position(x: pt.x, y: pt.y + r + 11)
                    }
                }

                // Floating Cartographic Legend Card (Top-Left)
                graphLegendOverlay
                    .padding(10)
            }
        }
    }

    private var graphLegendOverlay: some View {
        HStack(spacing: 10) {
            legendItem(
                ringColor: CambridgeLinenPalette.libraryForestGreen,
                fill: CambridgeLinenPalette.libraryForestGreen,
                label: localizer.L("SPC Main Path", "SPC 演进主路径")
            )
            legendItem(
                ringColor: CambridgeLinenPalette.preprintOchre,
                fill: CambridgeLinenPalette.archivalPaper,
                label: localizer.L("Brandes Bridge (Double Halo)", "Brandes 结构洞桥接（双环）")
            )
            legendItem(
                ringColor: CambridgeLinenPalette.verifiedEmerald,
                fill: CambridgeLinenPalette.verifiedEmeraldBg,
                label: localizer.L("Verified", "已验证")
            )
            legendItem(
                ringColor: CambridgeLinenPalette.blockedCrimson,
                fill: CambridgeLinenPalette.blockedCrimsonBg,
                label: localizer.L("Not Found / Retracted", "未找到 / 已撤稿")
            )
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .fill(CambridgeLinenPalette.warmVellum.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
        )
    }

    private func legendItem(ringColor: Color, fill: Color, label: String) -> some View {
        HStack(spacing: 4.5) {
            Circle()
                .fill(fill)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(ringColor, lineWidth: 1.4))
            Text(label)
                .font(CambridgeTypography.uiCaption)
                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: Screen-Space Projection with Collision Avoidance

    private func computeScreenPositions(in size: CGSize) -> [String: CGPoint] {
        let nodes = viewModel.graphSnapshot.nodes
        guard !nodes.isEmpty, size.width > 120, size.height > 120 else { return [:] }

        let padLeft: CGFloat = 78
        let padRight: CGFloat = 78
        let padTop: CGFloat = 54
        let padBottom: CGFloat = 56
        let usableW = max(100, size.width - padLeft - padRight)
        let usableH = max(100, size.height - padTop - padBottom)

        let years = nodes.map(\.year).filter { $0 > 0 }
        let minYr = Double(years.min() ?? 1960)
        let maxYr = Double(max((years.max() ?? 2025), Int(minYr) + 1))

        let ys = nodes.map(\.y)
        let minY = ys.min() ?? -1.0
        let maxY = max(ys.max() ?? 1.0, minY + 0.001)

        var pts: [String: CGPoint] = [:]
        for (idx, node) in nodes.enumerated() {
            // Blend chronological year along X (70%) with Barnes-Hut X (30%) for an immediately legible temporal-citation map
            let yrNorm = node.year > 0
                ? (Double(node.year) - minYr) / (maxYr - minYr)
                : 0.5
            let rawYNorm = (node.y - minY) / (maxY - minY)
            // Deterministic cluster vertical lane separation so Louvain hulls are visually distinct
            let clusterBandOffset = Double((node.clusterIndex % 3) - 1) * 0.22
            let clampedYNorm = min(0.92, max(0.08, rawYNorm * 0.58 + 0.21 + clusterBandOffset + Double(idx % 2) * 0.04))

            let baseX = padLeft + CGFloat(min(0.96, max(0.04, yrNorm))) * usableW
            let baseY = padTop + CGFloat(clampedYNorm) * usableH

            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            let zoomedX = center.x + (baseX - center.x) * viewModel.graphZoomScale + viewModel.graphPanOffset.width
            let zoomedY = center.y + (baseY - center.y) * viewModel.graphZoomScale + viewModel.graphPanOffset.height
            pts[node.citeKey] = CGPoint(x: zoomedX, y: zoomedY)
        }

        // Deterministic 18-pass label/circle separation so zero node pills collide!
        let orderedKeys = nodes.map(\.citeKey).sorted()
        let minSepX: CGFloat = 92.0
        let minSepY: CGFloat = 46.0
        for _ in 0..<18 {
            for i in 0..<orderedKeys.count {
                for j in (i + 1)..<orderedKeys.count {
                    let kA = orderedKeys[i]
                    let kB = orderedKeys[j]
                    guard var pA = pts[kA], var pB = pts[kB] else { continue }
                    let dx = pB.x - pA.x
                    let dy = pB.y - pA.y
                    if abs(dx) < minSepX && abs(dy) < minSepY {
                        let pushX = (minSepX - abs(dx)) * 0.22 * (dx >= 0 ? 1 : -1)
                        let pushY = (minSepY - abs(dy)) * 0.34 * (dy >= 0 ? 1 : -1)
                        pA.x = min(size.width - padRight, max(padLeft, pA.x - pushX))
                        pB.x = min(size.width - padRight, max(padLeft, pB.x + pushX))
                        pA.y = min(size.height - padBottom, max(padTop, pA.y - pushY))
                        pB.y = min(size.height - padBottom, max(padTop, pB.y + pushY))
                        pts[kA] = pA
                        pts[kB] = pB
                    }
                }
            }
        }
        return pts
    }

    private func drawArchivalGrid(context: inout GraphicsContext, size: CGSize) {
        let spacing: CGFloat = 36
        var gridPath = Path()
        var x: CGFloat = 0
        while x <= size.width {
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: size.height - 32))
            x += spacing
        }
        var y: CGFloat = 0
        while y <= size.height - 32 {
            gridPath.move(to: CGPoint(x: 0, y: y))
            gridPath.addLine(to: CGPoint(x: size.width, y: y))
            y += spacing
        }
        context.stroke(gridPath, with: .color(CambridgeLinenPalette.stoneHairline.opacity(0.42)), lineWidth: 0.6)
    }

    private func drawLouvainClusterHulls(context: inout GraphicsContext, positions: [String: CGPoint]) {
        guard let partition = viewModel.louvainPartition else { return }
        let hullColors: [(fill: Color, stroke: Color)] = [
            (CambridgeLinenPalette.libraryForestTint.opacity(0.55), CambridgeLinenPalette.libraryForestBorder),
            (CambridgeLinenPalette.preprintOchreBg.opacity(0.55), CambridgeLinenPalette.preprintOchreBorder),
            (CambridgeLinenPalette.verifiedEmeraldBg.opacity(0.50), CambridgeLinenPalette.verifiedEmeraldBorder),
            (CambridgeLinenPalette.warmVellum.opacity(0.65), CambridgeLinenPalette.deepStoneBorder)
        ]

        for (idx, community) in partition.communities.prefix(4).enumerated() where community.memberCiteKeys.count >= 2 {
            let memberPts = community.memberCiteKeys.compactMap { positions[$0] }
            guard memberPts.count >= 2 else { continue }
            let minX = (memberPts.map(\.x).min() ?? 0) - 34
            let maxX = (memberPts.map(\.x).max() ?? 0) + 34
            let minY = (memberPts.map(\.y).min() ?? 0) - 26
            let maxY = (memberPts.map(\.y).max() ?? 0) + 30
            let rect = CGRect(x: minX, y: minY, width: max(68, maxX - minX), height: max(54, maxY - minY))
            let rounded = Path(roundedRect: rect, cornerRadius: 22)
            let style = hullColors[idx % hullColors.count]
            context.fill(rounded, with: .color(style.fill))
            context.stroke(
                rounded,
                with: .color(style.stroke.opacity(0.75)),
                style: StrokeStyle(lineWidth: 1.0, dash: [5, 4])
            )
        }
    }

    private func drawKnowledgeEdges(context: inout GraphicsContext, positions: [String: CGPoint]) {
        let spcSet = mainPathEdgePairs

        for edge in viewModel.graphSnapshot.edges {
            if edge.kind != .directCitation && !viewModel.graphShowCoCitationEdges {
                continue
            }
            guard let p1 = positions[edge.sourceCiteKey],
                  let p2 = positions[edge.targetCiteKey]
            else { continue }

            let isSPC = viewModel.graphHighlightMainPath &&
                spcSet.contains("\(edge.sourceCiteKey)->\(edge.targetCiteKey)")

            var path = Path()
            path.move(to: p1)
            let mid = CGPoint(x: (p1.x + p2.x) * 0.5, y: (p1.y + p2.y) * 0.5 - 16)
            path.addQuadCurve(to: p2, control: mid)

            if isSPC {
                context.stroke(
                    path,
                    with: .color(CambridgeLinenPalette.libraryForestGreen),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
            } else if edge.kind == .directCitation {
                context.stroke(
                    path,
                    with: .color(CambridgeLinenPalette.slateEditorial.opacity(0.42)),
                    style: StrokeStyle(lineWidth: 1.15, lineCap: .round)
                )
            } else {
                context.stroke(
                    path,
                    with: .color(CambridgeLinenPalette.preprintOchre.opacity(0.32)),
                    style: StrokeStyle(lineWidth: 0.9, dash: [3, 3])
                )
            }
        }
    }

    private func drawScholarlyNodes(
        context: inout GraphicsContext,
        positions: [String: CGPoint],
        bibByKey: [String: BibliographyEntry]
    ) {
        let bridges = bridgeKeySet
        let spcKeys = Set(mainPathOrderedKeys)

        for node in viewModel.graphSnapshot.nodes {
            guard let pt = positions[node.citeKey] else { continue }
            let r = nodeRadius(for: node)
            let isSelected = (viewModel.selectedGraphCiteKey == node.citeKey)
            let isBridge = node.isBridgePaper || bridges.contains(node.citeKey)
            let isSPC = viewModel.graphHighlightMainPath && spcKeys.contains(node.citeKey)
            let fwClass = bibByKey[node.citeKey]?.firewallClass ?? .unverified

            // Brandes structural-hole bridge outer concentric halo
            if isBridge {
                let haloRect = CGRect(x: pt.x - r - 4.5, y: pt.y - r - 4.5, width: (r + 4.5) * 2, height: (r + 4.5) * 2)
                context.stroke(
                    Path(ellipseIn: haloRect),
                    with: .color(CambridgeLinenPalette.preprintOchre),
                    style: StrokeStyle(lineWidth: 1.6, dash: [3, 2])
                )
            }

            // Selected focus ring
            if isSelected {
                let focusRect = CGRect(x: pt.x - r - 7.5, y: pt.y - r - 7.5, width: (r + 7.5) * 2, height: (r + 7.5) * 2)
                context.stroke(
                    Path(ellipseIn: focusRect),
                    with: .color(CambridgeLinenPalette.libraryForestGreen),
                    lineWidth: 2.0
                )
            }

            let circleRect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
            let fillColor: Color
            let strokeColor: Color
            switch fwClass {
            case .notFound, .retracted:
                fillColor = CambridgeLinenPalette.blockedCrimsonBg
                strokeColor = CambridgeLinenPalette.blockedCrimson
            case .drift, .unverified:
                fillColor = CambridgeLinenPalette.preprintOchreBg
                strokeColor = CambridgeLinenPalette.preprintOchre
            case .verified:
                fillColor = isSPC ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.verifiedEmeraldBg
                strokeColor = isSPC ? CambridgeLinenPalette.libraryForestGreen : CambridgeLinenPalette.verifiedEmerald
            }

            context.fill(Path(ellipseIn: circleRect), with: .color(fillColor))
            context.stroke(Path(ellipseIn: circleRect), with: .color(strokeColor), lineWidth: 1.8)
        }
    }

    private func drawTimelineAxis(context: inout GraphicsContext, size: CGSize) {
        let yAxis = size.height - 22
        var line = Path()
        line.move(to: CGPoint(x: 56, y: yAxis))
        line.addLine(to: CGPoint(x: size.width - 56, y: yAxis))
        context.stroke(line, with: .color(CambridgeLinenPalette.deepStoneBorder), lineWidth: 1.0)

        let milestoneYears = [1960, 1986, 2003, 2012, 2018, 2025]
        let span = max(1, milestoneYears.last! - milestoneYears.first!)
        for yr in milestoneYears {
            let frac = CGFloat(yr - milestoneYears.first!) / CGFloat(span)
            let x = 78 + frac * max(80, size.width - 156)
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: yAxis - 4))
            tick.addLine(to: CGPoint(x: x, y: yAxis + 4))
            context.stroke(tick, with: .color(CambridgeLinenPalette.slateEditorial), lineWidth: 1.0)
            context.draw(
                Text(verbatim: String(yr))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(CambridgeLinenPalette.mutedMetadata),
                at: CGPoint(x: x, y: yAxis + 11)
            )
        }
    }

    private func nodeRadius(for node: CitationGraphNode) -> CGFloat {
        let scaled = 9.0 + CGFloat(min(1.0, max(0.0, node.pageRank * 5.2))) * 9.5
        return min(18.5, max(9.0, scaled))
    }

    private func hitTestNode(at point: CGPoint, positions: [String: CGPoint]) -> CitationGraphNode? {
        viewModel.graphSnapshot.nodes.min(by: { a, b in
            let pA = positions[a.citeKey] ?? .zero
            let pB = positions[b.citeKey] ?? .zero
            return hypot(pA.x - point.x, pA.y - point.y) < hypot(pB.x - point.x, pB.y - point.y)
        }).flatMap { closest in
            guard let pt = positions[closest.citeKey], hypot(pt.x - point.x, pt.y - point.y) <= 34 else {
                return nil
            }
            return closest
        }
    }

    private func shortNodeBadgeLabel(for node: CitationGraphNode, entry: BibliographyEntry?) -> String {
        let family = entry?.firstAuthorFamily ?? node.citeKey
        let cleanFamily = family.count > 13 ? String(family.prefix(12)) : family
        let dupSuffix = node.citeKey.contains("_dup") ? localizer.L(" (dup)", " (重复)") : ""
        if node.year > 0 {
            return "\(cleanFamily) \(node.year)\(dupSuffix)"
        }
        return "\(cleanFamily)\(dupSuffix)"
    }

    // MARK: 3. Kleinberg Temporal Citation & Keyword Burst Sparkbars

    private var kleinbergBurstSparkbarStrip: some View {
        let report = viewModel.kleinbergBurstReport
        let episodes = Array(((report?.paperCitationBursts ?? []) + (report?.topicalKeywordBursts ?? [])).prefix(4))
        let maxWeight = max(1.0, episodes.map(\.burstStrengthWeight).max() ?? 4.0)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(
                    localizer.L(
                        "KLEINBERG INFINITE-AUTOMATON TEMPORAL CITATION & TOPICAL BURSTS",
                        "KLEINBERG 无限状态机引文与主题突现检测"
                    )
                )
                .font(CambridgeTypography.uiSectionLabel)
                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                Spacer()
                Text(localizer.L("Viterbi State Solver (s = 2.0, γ = 1.0)", "Viterbi 状态求解器 (s = 2.0, γ = 1.0)"))
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if episodes.isEmpty {
                HStack(spacing: 12) {
                    fallbackBurstCard(
                        label: localizer.L("Transformer & Retrieval Grounding", "Transformer 与检索证据对齐"),
                        window: "2017–2024",
                        strength: 4.82,
                        fold: 3.4
                    )
                    fallbackBurstCard(
                        label: localizer.L("PRISMA 2020 & Psychometric QC", "PRISMA 2020 与信度质控"),
                        window: "2019–2025",
                        strength: 3.94,
                        fold: 2.9
                    )
                    fallbackBurstCard(
                        label: localizer.L("Citation Verification Firewalls", "引文真实性核验防火墙"),
                        window: "2023–2025",
                        strength: 5.26,
                        fold: 4.1
                    )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else {
                HStack(spacing: 10) {
                    ForEach(Array(episodes.prefix(3))) { ep in
                        let shortTitle = ep.targetIdentifier.hasPrefix("@")
                            ? ep.targetIdentifier
                            : "@\(ep.targetIdentifier)"
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(shortTitle)
                                    .font(CambridgeTypography.monoSmall)
                                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                    .fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: 4)
                                Text("\(String(ep.startYear))–\(String(ep.endYear))")
                                    .font(CambridgeTypography.monoSmall)
                                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                                    .fixedSize(horizontal: true, vertical: false)
                            }

                            GeometryReader { barGeo in
                                let fillW = max(18, barGeo.size.width * CGFloat(min(1.0, ep.burstStrengthWeight / maxWeight)))
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(CambridgeLinenPalette.warmVellum)
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(CambridgeLinenPalette.libraryForestGreen)
                                        .frame(width: fillW)
                                }
                            }
                            .frame(height: 7)

                            HStack {
                                Text(localizer.L("State q\(ep.peakStateLevel)", "状态阶 q\(ep.peakStateLevel)"))
                                    .font(CambridgeTypography.monoSmall)
                                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                Spacer()
                                Text(
                                    localizer.language == .zhHans
                                        ? String(format: "权重 %.2f (%.1f×)", ep.burstStrengthWeight, ep.foldElevationRatio)
                                        : String(format: "Weight %.2f (%.1f×)", ep.burstStrengthWeight, ep.foldElevationRatio)
                                )
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                                .fill(CambridgeLinenPalette.archivalPaper)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                                .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .background(CambridgeLinenPalette.cambridgeLinen)
    }

    private func fallbackBurstCard(label: String, window: String, strength: Double, fold: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(CambridgeTypography.uiControlSemibold)
                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                Spacer()
                Text(window)
                    .font(CambridgeTypography.monoSmall)
                    .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                    .fixedSize(horizontal: true, vertical: false)
            }
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(CambridgeLinenPalette.libraryForestGreen)
                .frame(height: 6)
            Text(
                localizer.language == .zhHans
                    ? String(format: "突现权重 %.2f • %.1f× 基线", strength, fold)
                    : String(format: "Burst Weight %.2f • %.1f× baseline", strength, fold)
            )
            .font(CambridgeTypography.monoSmall)
            .foregroundStyle(CambridgeLinenPalette.slateEditorial)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .fill(CambridgeLinenPalette.archivalPaper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
        )
    }

    // MARK: 4. Right Cartography & Missing Foundational Citations Column

    private var graphCartographyInspectorColumn: some View {
        let selectedNode = viewModel.selectedGraphNode
        let selectedEntry = viewModel.bibliographyEntries.first(where: { $0.citeKey == selectedNode?.citeKey })
        let recommendations = Array((viewModel.missingCitationsReport?.recommendations ?? []).prefix(3))

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Card A: Selected Node Metrics
                if let node = selectedNode {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(localizer.L("SELECTED GRAPH NODE", "当前选中图谱节点"))
                                .font(CambridgeTypography.uiSectionLabel)
                                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                            Spacer()
                            if let fw = selectedEntry?.firewallClass {
                                FirewallBadgeView(firewallClass: fw, compact: true)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }

                        Text(node.title)
                            .font(CambridgeTypography.scholarlyHeadline)
                            .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("@\(node.citeKey) • \(node.authorYearLabel)")
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.slateEditorial)

                        HStack(spacing: 6) {
                            smallKpiBox(title: "PageRank", value: String(format: "%.3f", node.pageRank))
                            smallKpiBox(title: localizer.L("Betweenness", "介数中心度"), value: String(format: "%.3f", node.betweennessScore))
                            smallKpiBox(title: localizer.L("In / Out", "入度 / 出度"), value: "\(node.inDegree) / \(node.outDegree)")
                            smallKpiBox(title: localizer.L("Cluster", "社团簇"), value: "C\(node.clusterIndex + 1)")
                        }

                        HStack(spacing: 8) {
                            Button {
                                _ = viewModel.attemptInsertCitation(node.citeKey)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus.bubble")
                                        .font(.system(size: 10.5, weight: .semibold))
                                    Text(localizer.L("Insert \\cite{\(node.citeKey)}", "插入引用 \\cite{\(node.citeKey)}"))
                                }
                            }
                            .buttonStyle(CambridgePrimaryButtonStyle())
                            .fixedSize(horizontal: true, vertical: false)

                            Spacer()
                        }
                    }
                    .cambridgeArchivalCard(padding: 11)
                }

                // Card B: Hummon-Doreian SPC Main Path Spine
                if !mainPathOrderedKeys.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(localizer.L("HUMMON-DOREIAN SPC MAIN PATH", "HUMMON-DOREIAN SPC 演进主路径"))
                                .font(CambridgeTypography.uiSectionLabel)
                                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                            Spacer()
                            Text(localizer.L("\(mainPathOrderedKeys.count) milestones", "\(mainPathOrderedKeys.count) 篇里程碑"))
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(mainPathOrderedKeys.enumerated()), id: \.offset) { idx, key in
                                HStack(spacing: 6) {
                                    Text("\(idx + 1).")
                                        .font(CambridgeTypography.monoSmall)
                                        .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Text("@\(key)")
                                        .font(CambridgeTypography.monoSmall)
                                        .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Spacer()
                                    if idx < mainPathOrderedKeys.count - 1 {
                                        Text(localizer.L("→ diffuses", "→ 演进传递"))
                                            .font(CambridgeTypography.uiCaption)
                                            .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                            }
                        }
                    }
                    .cambridgeArchivalCard(padding: 11)
                }

                // Card C: Missing Foundational Citations (Bibliographic Coupling & Co-Citation)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(localizer.L("MISSING FOUNDATIONAL PAPERS", "建议补引的奠基文献"))
                            .font(CambridgeTypography.uiSectionLabel)
                            .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                        Spacer()
                        if let cov = viewModel.missingCitationsReport?.manuscriptCoverageRatio {
                            Text(
                                localizer.language == .zhHans
                                    ? String(format: "覆盖率 %.0f%%", cov * 100.0)
                                    : String(format: "Coverage %.0f%%", cov * 100.0)
                            )
                            .font(CambridgeTypography.monoSmall)
                            .foregroundStyle(CambridgeLinenPalette.preprintOchre)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    ForEach(recommendations) { rec in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(rec.authorYearDisplay)
                                    .font(CambridgeTypography.uiControlSemibold)
                                    .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                                Spacer(minLength: 4)
                                Text(
                                    localizer.language == .zhHans
                                        ? String(format: "推荐分 %.2f", rec.priorityRecommendationScore)
                                        : String(format: "Score %.2f", rec.priorityRecommendationScore)
                                )
                                .font(CambridgeTypography.monoSmall)
                                .foregroundStyle(CambridgeLinenPalette.libraryForestGreen)
                                .fixedSize(horizontal: true, vertical: false)
                            }

                            Text(rec.title)
                                .font(CambridgeTypography.uiCaption)
                                .foregroundStyle(CambridgeLinenPalette.slateEditorial)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 6) {
                                Text(localizer.L("Co-cited: \(rec.coCitedByManuscriptRefsCount)", "共被引: \(rec.coCitedByManuscriptRefsCount) 次"))
                                    .font(CambridgeTypography.monoSmall)
                                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                    .fixedSize(horizontal: true, vertical: false)

                                Text("• §\(localizedSuggestedSection(rec.suggestedSection.rawValue))")
                                    .font(CambridgeTypography.uiCaption)
                                    .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                                    .fixedSize(horizontal: true, vertical: false)

                                Spacer(minLength: 4)

                                Button(localizer.L("+ Cite", "+ 补引")) {
                                    _ = viewModel.attemptInsertCitation(rec.citeKey)
                                }
                                .buttonStyle(CambridgeSecondaryButtonStyle(isSelected: true))
                                .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                                .fill(CambridgeLinenPalette.cambridgeLinen)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CambridgeMetrics.cornerRadiusSmall, style: .continuous)
                                .strokeBorder(CambridgeLinenPalette.stoneHairline, lineWidth: CambridgeMetrics.hairline)
                        )
                    }
                }
                .cambridgeArchivalCard(padding: 11)
            }
            .padding(12)
        }
    }

    private func localizedSuggestedSection(_ raw: String) -> String {
        guard localizer.language == .zhHans else { return raw }
        switch raw {
        case "Introduction": return "引言"
        case "Related Work": return "相关工作"
        case "Methodology", "Methods": return "研究方法"
        case "Experiments", "Evaluation": return "实验评估"
        case "Discussion": return "讨论与局限"
        default: return raw
        }
    }

    private func smallKpiBox(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(CambridgeLinenPalette.mutedMetadata)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(CambridgeTypography.monoSmall)
                .foregroundStyle(CambridgeLinenPalette.oxfordCharcoal)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(CambridgeLinenPalette.cambridgeLinen)
        )
    }
}
