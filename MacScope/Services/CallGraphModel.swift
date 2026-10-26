import CoreGraphics
import Foundation

/// The selected function's callers and callees, to a chosen depth, from the image's existing
/// `call` xrefs (no new analysis). A call xref links the function whose range contains its
/// `from` address to the function that starts at (or uniquely contains) its `to` address; xrefs
/// whose ends no single function owns are skipped, never guessed. Callers sit above the root
/// (rank −depth), callees below (rank +depth), each function at its first BFS discovery; the
/// layered engine places them, and edges that run upward (a callee calling back) are back edges.
struct CallGraphModel: Equatable {
    struct Node: Identifiable, Equatable {
        var functionID: UUID
        var name: String
        var startAddress: UInt64
        /// Negative for callers, 0 for the root, positive for callees.
        var depth: Int
        var center: CGPoint = .zero
        var id: UUID { functionID }
        var isRoot: Bool { depth == 0 }
    }

    struct Edge: Identifiable, Equatable {
        var from: UUID
        var to: UUID
        /// Number of distinct call sites folded into this caller → callee edge.
        var callSites: Int
        var points: [CGPoint] = []
        var isBackEdge = false
        var id: String { "\(from.uuidString)->\(to.uuidString)" }
    }

    static let maximumDepth = 4
    static let defaultMaximumNodes = 120

    var nodes: [Node]
    var edges: [Edge]
    var size: CGSize = .zero
    /// Set when the neighbourhood was cut at `maximumNodes`; the canvas says so.
    var truncatedAt: Int?
    var layoutRefusal: String?

    static func build(
        projection: FocusedGraphProjection,
        rootFunctionID: UUID,
        depth requestedDepth: Int,
        maximumNodes: Int = defaultMaximumNodes,
        metrics: LayeredGraphLayout.Metrics
    ) -> CallGraphModel? {
        let depth = min(max(requestedDepth, 1), maximumDepth)
        let functions = projection.functions
            .filter { $0.endAddress > $0.startAddress }
            .sorted { GraphElementOrdering.isOrderedBefore(address: $0.startAddress, id: $0.id,
                                                           than: $1.startAddress, id: $1.id) }
        guard let root = functions.first(where: { $0.id == rootFunctionID }) else { return nil }
        let index = FunctionRangeIndex(functions)

        // Caller → callee adjacency with call-site counts, from call xrefs only.
        var calls: [UUID: [UUID: Set<UInt64>]] = [:]
        for xref in projection.xrefs where xref.kind == "call" {
            guard let caller = index.owner(of: xref.from),
                  let callee = index.function(startingAt: xref.to) ?? index.owner(of: xref.to) else { continue }
            calls[caller.id, default: [:]][callee.id, default: []].insert(xref.from)
        }
        var callers: [UUID: [UUID: Set<UInt64>]] = [:]
        for (caller, callees) in calls { for (callee, sites) in callees { callers[callee, default: [:]][caller] = sites } }
        let byID = Dictionary(uniqueKeysWithValues: functions.map { ($0.id, $0) })
        func ordered(_ ids: [UUID]) -> [UUID] {
            ids.compactMap { byID[$0] }
                .sorted { GraphElementOrdering.isOrderedBefore(address: $0.startAddress, id: $0.id,
                                                               than: $1.startAddress, id: $1.id) }
                .map(\.id)
        }

        // Alternate caller and callee rings so a cap keeps both directions balanced. Each direction
        // keeps its own visited set (DP11): a function first reached as a callee keeps that rank, but
        // its callers are still explored, so mutual recursion doesn't hide them.
        var depthOf: [UUID: Int] = [root.id: 0]
        var order: [UUID] = [root.id]
        var truncated = false
        var upFrontier = [root.id], downFrontier = [root.id]
        var seenDown: Set<UUID> = [root.id], seenUp: Set<UUID> = [root.id]
        ringLoop: for ring in 1...depth {
            for (frontier, sign, adjacency) in [(downFrontier, 1, calls), (upFrontier, -1, callers)] {
                var next: [UUID] = []
                for id in frontier {
                    for neighbour in ordered(Array((adjacency[id] ?? [:]).keys)) {
                        let fresh = sign == 1 ? seenDown.insert(neighbour).inserted : seenUp.insert(neighbour).inserted
                        guard fresh else { continue }
                        if depthOf[neighbour] == nil {
                            guard order.count < maximumNodes else { truncated = true; break ringLoop }
                            depthOf[neighbour] = sign * ring
                            order.append(neighbour)
                        }
                        next.append(neighbour)
                    }
                }
                if sign == 1 { downFrontier = next } else { upFrontier = next }
            }
        }

        let presentation = projection.presentationByAddress
        var nodes = order.compactMap { id -> Node? in
            guard let function = byID[id], let d = depthOf[id] else { return nil }
            return Node(functionID: id, name: presentation[function.startAddress]?.customName ?? function.name,
                        startAddress: function.startAddress, depth: d)
        }
        let slot = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.functionID, $0.offset) })
        var edges: [Edge] = []
        for caller in order {
            for (callee, sites) in calls[caller] ?? [:] {
                guard slot[callee] != nil else { continue }
                edges.append(Edge(from: caller, to: callee, callSites: sites.count))
            }
        }
        edges.sort { (slot[$0.from]!, slot[$0.to]!) < (slot[$1.from]!, slot[$1.to]!) }

        var model = CallGraphModel(nodes: nodes, edges: edges, truncatedAt: truncated ? maximumNodes : nil)
        let result = LayeredGraphLayout.layout(
            nodeCount: nodes.count, entry: 0,
            edges: edges.map { .init(from: slot[$0.from]!, to: slot[$0.to]!) },
            fixedRanks: nodes.map(\.depth), metrics: metrics
        )
        switch result {
        case .success(let layout):
            for i in nodes.indices { nodes[i].center = layout.centers[i] }
            for routed in layout.edges {
                edges[routed.index].points = routed.points
                edges[routed.index].isBackEdge = routed.isBackEdge
            }
            model.nodes = nodes
            model.edges = edges
            model.size = layout.size
        case .failure(let refusal):
            model.layoutRefusal = refusal.message
        }
        return model
    }
}

/// Address → owning function over non-overlapping-or-not function ranges: `owner(of:)` answers
/// only when exactly one function's half-open range contains the address.
struct FunctionRangeIndex {
    private let functions: [FunctionSummary]
    /// `maximumEnd[i]` is the largest end address among `functions[0...i]`: the backward scan
    /// stops as soon as no earlier range can reach the address (DP11: exact, no fixed look-back).
    private let maximumEnd: [UInt64]
    private let byStart: [UInt64: FunctionSummary]

    init(_ functions: [FunctionSummary]) {
        self.functions = functions.sorted { $0.startAddress < $1.startAddress }
        var running: UInt64 = 0
        self.maximumEnd = self.functions.map { running = max(running, $0.endAddress); return running }
        var byStart: [UInt64: FunctionSummary] = [:]
        var ambiguous = Set<UInt64>()
        for function in functions {
            if byStart[function.startAddress] != nil { ambiguous.insert(function.startAddress) }
            byStart[function.startAddress] = function
        }
        for address in ambiguous { byStart[address] = nil }
        self.byStart = byStart
    }

    func function(startingAt address: UInt64) -> FunctionSummary? { byStart[address] }

    func owner(of address: UInt64) -> FunctionSummary? {
        // Last function starting at or before the address; then check every earlier one that
        // might still overlap (ranges may nest), refusing when more than one contains it.
        var low = 0, high = functions.count
        while low < high {
            let mid = (low + high) / 2
            if functions[mid].startAddress <= address { low = mid + 1 } else { high = mid }
        }
        var found: FunctionSummary?
        var cursor = low - 1
        while cursor >= 0, maximumEnd[cursor] > address {
            let candidate = functions[cursor]
            if address < candidate.endAddress {
                if found != nil { return nil }
                found = candidate
            }
            cursor -= 1
        }
        return found
    }
}
