import CoreGraphics
import Foundation

/// Canonical ordering for graph elements whose virtual addresses may collide.
///
/// UUID string order matches the live graph's established tie-break while keeping the export
/// geometry deterministic regardless of input collection order.
enum GraphElementOrdering {
    static func isOrderedBefore(
        address lhsAddress: UInt64,
        id lhsID: UUID,
        than rhsAddress: UInt64,
        id rhsID: UUID
    ) -> Bool {
        if lhsAddress != rhsAddress { return lhsAddress < rhsAddress }
        return lhsID.uuidString < rhsID.uuidString
    }
}

/// A pure, view-independent layout of the control-flow GRAPH: one vertical *lane* per
/// function, basic-block nodes stacked within each lane, and Bézier edges between
/// nodes. It mirrors how `GraphView` (the on-screen canvas) arranges the graph — the
/// same function→lane / block→node grouping and the same edge sourcing (control-flow
/// edges first, then deduplicated xrefs) — but computes everything with `CoreGraphics`
/// only, so it can drive the headless `GraphPDFRenderer` and be unit-tested without
/// SwiftUI / a `GeometryReader`.
///
/// The geometry is laid out in a TOP-LEFT origin coordinate space (matching the live
/// canvas); the PDF renderer Y-flips the page once before drawing.
struct GraphLayoutGeometry {
    struct Node: Identifiable, Equatable {
        var id: String
        var title: String
        var subtitle: String
        var detail: String
        var startAddress: UInt64
        var endAddress: UInt64
        var isEntry: Bool
        /// Frozen graph-visible authoring for this node's start address.
        var tag: String?
        var colorTag: ColorTag?
        var frame: CGRect

        /// True when `address` falls inside the node's half-open `[start, end)` range
        /// (or equals `start` for a zero-width node). Used to anchor edges to nodes.
        func contains(_ address: UInt64) -> Bool {
            if endAddress > startAddress {
                return address >= startAddress && address < endAddress
            }
            return address == startAddress
        }

        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    }

    struct Lane: Identifiable, Equatable {
        var id: String
        var title: String
        var subtitle: String
        var frame: CGRect
        var nodes: [Node]
    }

    enum EdgeKind: Equatable {
        case call
        case reference
        case fallThrough
        case branch

        init(rawKind: String) {
            switch rawKind {
            case "call": self = .call
            case "reference", "string", "selref", "classref", "data": self = .reference
            case "fallthrough": self = .fallThrough
            default: self = .branch
            }
        }
    }

    struct Edge: Identifiable, Equatable {
        var id: String
        var from: CGPoint
        var to: CGPoint
        var control1: CGPoint
        var control2: CGPoint
        var arrowAngle: CGFloat
        var kind: EdgeKind
    }

    let lanes: [Lane]
    let edges: [Edge]
    let pageSize: CGSize

    var nodeCount: Int { lanes.reduce(0) { $0 + $1.nodes.count } }

    /// Primary-image compatibility wrapper for legacy snapshot-only callers.
    init(snapshot: WorkspaceSnapshot, metrics: GraphPDFRenderer.Metrics.Type) {
        self.init(
            projection: snapshot.graphProjection(in: snapshot.primarySlot),
            metrics: metrics
        )
    }

    /// Builds geometry from one frozen, image-owned graph projection using the
    /// GraphPDFRenderer metrics.
    init(projection: FocusedGraphProjection, metrics: GraphPDFRenderer.Metrics.Type) {
        let captionBand: CGFloat = 30
        let topInset = metrics.margin + captionBand

        // Group functions into lanes, ascending by start address (the same ordering the
        // on-screen graph uses), then stack each function's basic blocks as nodes.
        let functions = projection.functions.sorted {
            GraphElementOrdering.isOrderedBefore(
                address: $0.startAddress,
                id: $0.id,
                than: $1.startAddress,
                id: $1.id
            )
        }
        let blocksByFunction = Dictionary(grouping: projection.basicBlocks, by: \.functionID)

        var lanes: [Lane] = []
        var nodesByAddressRange: [Node] = []

        var laneOriginX = metrics.margin
        var maxLaneBottom = topInset

        func addLane(
            id: String,
            functionName: String,
            functionAddressText: String,
            entries: [(
                title: String,
                subtitle: String,
                detail: String,
                start: UInt64,
                end: UInt64,
                isEntry: Bool,
                presentation: GraphAddressPresentation?
            )]
        ) {
            var nodes: [Node] = []
            var nodeY = topInset + metrics.headerHeight + metrics.nodeTopPadding
            for entry in entries {
                let frame = CGRect(
                    x: laneOriginX + (metrics.laneWidth - metrics.nodeWidth) / 2,
                    y: nodeY,
                    width: metrics.nodeWidth,
                    height: metrics.nodeHeight
                )
                let node = Node(
                    id: entry.title.isEmpty ? "\(id):\(entry.start)" : "\(id):\(entry.start):\(entry.title)",
                    title: entry.title,
                    subtitle: entry.subtitle,
                    detail: entry.detail,
                    startAddress: entry.start,
                    endAddress: entry.end,
                    isEntry: entry.isEntry,
                    tag: entry.presentation?.tag,
                    colorTag: entry.presentation?.colorTag,
                    frame: frame
                )
                nodes.append(node)
                nodesByAddressRange.append(node)
                nodeY += metrics.nodeHeight + metrics.nodeVerticalGap
            }

            let laneHeight = max(
                metrics.headerHeight + 2 * metrics.nodeTopPadding + metrics.nodeHeight,
                (nodeY - metrics.nodeVerticalGap) - topInset + metrics.nodeTopPadding
            )
            let laneFrame = CGRect(x: laneOriginX, y: topInset, width: metrics.laneWidth, height: laneHeight)
            lanes.append(Lane(id: id, title: functionName, subtitle: functionAddressText, frame: laneFrame, nodes: nodes))
            maxLaneBottom = max(maxLaneBottom, laneFrame.maxY)
            laneOriginX += metrics.laneWidth + metrics.laneGap
        }

        for function in functions {
            let functionPresentation = projection.presentationByAddress[function.startAddress]
            let functionName = functionPresentation?.customName ?? function.name
            let sortedBlocks = (blocksByFunction[function.id] ?? []).sorted {
                GraphElementOrdering.isOrderedBefore(
                    address: $0.startAddress,
                    id: $0.id,
                    than: $1.startAddress,
                    id: $1.id
                )
            }

            if sortedBlocks.isEmpty {
                addLane(
                    id: "function:\(function.id.uuidString)",
                    functionName: functionName,
                    functionAddressText: function.startAddress.hexAddress,
                    entries: [(
                        title: functionName,
                        subtitle: function.startAddress.hexAddress,
                        detail: "",
                        start: function.startAddress,
                        end: function.endAddress,
                        isEntry: true,
                        presentation: functionPresentation
                    )]
                )
            } else {
                let entries = sortedBlocks.enumerated().map { index, block in
                    let presentation = projection.presentationByAddress[block.startAddress]
                    return (
                        title: index == 0 ? "Entry block" : "Block \(index + 1)",
                        subtitle: "\(block.startAddress.hexAddress)",
                        detail: "\(block.instructionCount) insn",
                        start: block.startAddress,
                        end: block.endAddress,
                        isEntry: index == 0,
                        presentation: presentation
                    )
                }
                addLane(
                    id: "function:\(function.id.uuidString)",
                    functionName: functionName,
                    functionAddressText: function.startAddress.hexAddress,
                    entries: entries
                )
            }
        }

        // Orphan blocks (no owning function) and, failing everything, an instruction-range
        // fallback — same degenerate-case handling the live graph performs so an export of
        // a sparse binary still has at least one node.
        let knownFunctionIDs = Set(functions.map(\.id))
        let orphanBlocks = projection.basicBlocks
            .filter { !knownFunctionIDs.contains($0.functionID) }
            .sorted {
                GraphElementOrdering.isOrderedBefore(
                    address: $0.startAddress,
                    id: $0.id,
                    than: $1.startAddress,
                    id: $1.id
                )
            }
        if !orphanBlocks.isEmpty {
            let entries = orphanBlocks.enumerated().map { index, block in
                let presentation = projection.presentationByAddress[block.startAddress]
                return (
                    title: index == 0 ? "Entry block" : "Block \(index + 1)",
                    subtitle: block.startAddress.hexAddress,
                    detail: "\(block.instructionCount) insn",
                    start: block.startAddress,
                    end: block.endAddress,
                    isEntry: index == 0,
                    presentation: presentation
                )
            }
            addLane(id: "unowned-blocks", functionName: "Unowned blocks",
                    functionAddressText: "\(orphanBlocks.count) blocks", entries: entries)
        }

        if lanes.isEmpty,
           let range = projection.sparseInstructionRange,
           let first = projection.instructions.first {
            addLane(
                id: "instruction-range",
                functionName: "Instructions",
                functionAddressText: "\(projection.instructions.count) rows",
                entries: [(
                    title: "Instruction range",
                    subtitle: first.address.hexAddress,
                    detail: "\(projection.instructions.count) insn",
                    start: range.lowerBound,
                    end: range.upperBound,
                    isEntry: true,
                    presentation: projection.presentationByAddress[first.address]
                )]
            )
        }

        // Edges: control-flow edges first, then xrefs not already covered (matching the
        // live graph's dedupe-by-endpoint sourcing).
        var edgeInputs: [(id: String, from: UInt64, to: UInt64, kind: String)] =
            projection.controlFlowEdges.map { ("cfg:\($0.id.uuidString)", $0.from, $0.to, $0.kind) }
        var seenKeys = Set(edgeInputs.map { "\($0.from)->\($0.to):\($0.kind)" })
        for xref in projection.xrefs {
            let key = "\(xref.from)->\(xref.to):\(xref.kind)"
            if seenKeys.insert(key).inserted {
                edgeInputs.append(("xref:\(xref.id.uuidString)", xref.from, xref.to, xref.kind))
            }
        }

        var pairOffsets: [String: Int] = [:]
        var edges: [Edge] = []
        for input in edgeInputs {
            guard
                let source = nodesByAddressRange.first(where: { $0.contains(input.from) }),
                let target = nodesByAddressRange.first(where: { $0.contains(input.to) })
            else { continue }

            let pairKey = "\(source.id)->\(target.id)"
            let offsetIndex = pairOffsets[pairKey, default: 0]
            pairOffsets[pairKey] = offsetIndex + 1
            let route = Self.route(source: source, target: target, offsetIndex: offsetIndex)
            edges.append(Edge(
                id: input.id,
                from: route.from,
                to: route.to,
                control1: route.control1,
                control2: route.control2,
                arrowAngle: route.arrowAngle,
                kind: EdgeKind(rawKind: input.kind)
            ))
        }

        let pageWidth = max(metrics.minPageWidth, laneOriginX - metrics.laneGap + metrics.margin)
        let pageHeight = max(metrics.minPageHeight, maxLaneBottom + metrics.margin)

        self.lanes = lanes
        self.edges = edges
        self.pageSize = CGSize(width: pageWidth, height: pageHeight)
    }

    /// A simple Bézier route between two node frames: self-loops bow out to the right,
    /// vertically-stacked siblings hug the right edge, and cross-lane edges arc between
    /// the facing sides. Mirrors `GraphView`'s `GraphEdgeRoute` shaping at a smaller scale.
    private static func route(
        source: Node,
        target: Node,
        offsetIndex: Int
    ) -> (from: CGPoint, to: CGPoint, control1: CGPoint, control2: CGPoint, arrowAngle: CGFloat) {
        let nodeWidth = max(source.frame.width, target.frame.width)
        let nodeHeight = max(source.frame.height, target.frame.height)
        let pairOffset = CGFloat(offsetIndex) * 12
        let from: CGPoint
        let to: CGPoint
        let control1: CGPoint
        let control2: CGPoint

        if source.id == target.id {
            let loopOffset = 28 + pairOffset
            from = CGPoint(x: source.center.x + nodeWidth / 2, y: source.center.y - nodeHeight * 0.24)
            to = CGPoint(x: target.center.x + nodeWidth / 2, y: target.center.y + nodeHeight * 0.24)
            control1 = CGPoint(x: from.x + loopOffset, y: from.y - 24)
            control2 = CGPoint(x: to.x + loopOffset, y: to.y + 24)
        } else if abs(source.center.x - target.center.x) < 4 {
            let sideOffset = 30 + pairOffset
            let sourceAbove = source.center.y <= target.center.y
            from = CGPoint(x: source.center.x + nodeWidth / 2,
                           y: source.center.y + (sourceAbove ? nodeHeight * 0.24 : -nodeHeight * 0.24))
            to = CGPoint(x: target.center.x + nodeWidth / 2,
                         y: target.center.y + (sourceAbove ? -nodeHeight * 0.24 : nodeHeight * 0.24))
            control1 = CGPoint(x: from.x + sideOffset, y: from.y)
            control2 = CGPoint(x: to.x + sideOffset, y: to.y)
        } else {
            let targetIsRight = target.center.x > source.center.x
            let sourceEdgeX = source.center.x + (targetIsRight ? nodeWidth / 2 : -nodeWidth / 2)
            let targetEdgeX = target.center.x + (targetIsRight ? -nodeWidth / 2 : nodeWidth / 2)
            let horizontalDelta = max(40, abs(targetEdgeX - sourceEdgeX) * 0.42)
            let signedDelta = targetIsRight ? horizontalDelta : -horizontalDelta
            from = CGPoint(x: sourceEdgeX, y: source.center.y - 8 + pairOffset)
            to = CGPoint(x: targetEdgeX, y: target.center.y - 8 + pairOffset)
            control1 = CGPoint(x: from.x + signedDelta, y: from.y)
            control2 = CGPoint(x: to.x - signedDelta, y: to.y)
        }

        let arrowAngle = atan2(to.y - control2.y, to.x - control2.x)
        return (from, to, control1, control2, arrowAngle)
    }
}
