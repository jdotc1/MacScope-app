import CoreGraphics
import Foundation

/// A pure, deterministic layered (Sugiyama-style) layout for a directed graph of equal-size nodes:
///   1. Back edges are found by an iterative DFS from the entry (then from every unvisited node in
///      index order); reversing them leaves a DAG.
///   2. Ranks are longest-path depths in that DAG (or caller-supplied fixed ranks).
///   3. Edges spanning more than one rank get dummy nodes, one per crossed layer.
///   4. Crossings are reduced with alternating down/up barycenter sweeps, then a bounded
///      adjacent-transpose pass that keeps only strict improvements; the best order seen wins.
///   5. x coordinates are pulled toward neighbour medians with a minimum separation, y is the rank.
///   6. Each edge becomes a polyline through its dummy slots; back edges keep their original
///      direction (they run upward) and are flagged so the canvas can draw them distinctly.
///
/// Determinism: edges are processed in canonical (from, to, input index) order, so dummy identity,
/// initial positions and every tie-break depend on node indices only; permuting the edge array
/// changes only which `RoutedEdge.index` a route reports. Every input is validated and every cap
/// is checked before anything proportional to it is allocated; anything outside the bounds is a
/// `Refusal`, never a trap. (Dot review I1F, 2026-10-15.)
struct LayeredGraphLayout: Equatable {
    struct Limits: Equatable {
        var maximumNodes = 400
        var maximumEdges = 1_600
        /// Dummy nodes plus real nodes; long edges in a deep graph are what make sweeps expensive.
        var maximumLayeredNodes = 6_000
        /// Rank span (fixed ranks can be sparse, so this is not implied by the node count).
        var maximumLayers = 1_000
        var sweeps = 8
        static let maximumSweeps = 64
        /// Absolute ceilings a caller may raise the limits to; beyond them the request is refused,
        /// which keeps every count and dummy sum far from integer overflow (dot I1F2).
        static let ceiling = Limits(maximumNodes: 100_000, maximumEdges: 1_000_000,
                                    maximumLayeredNodes: 1_000_000, maximumLayers: 100_000, sweeps: maximumSweeps)
    }

    struct Metrics: Equatable {
        var nodeSize: CGSize
        var horizontalGap: CGFloat
        var layerGap: CGFloat
        var margin: CGFloat

        /// Largest accepted size, gap or margin. Products with node and layer counts stay finite
        /// (a finite 1e308 width would otherwise overflow to inf/NaN coordinates, dot I1F2).
        static let maximumValue: CGFloat = 1_000_000

        /// Positive node size; non-negative gaps and margin; all at most `maximumValue`.
        var isValid: Bool {
            [nodeSize.width, nodeSize.height].allSatisfy { $0.isFinite && $0 > 0 && $0 <= Self.maximumValue }
                && [horizontalGap, layerGap, margin].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= Self.maximumValue }
        }
    }

    struct EdgeInput: Equatable {
        var from: Int
        var to: Int
    }

    struct RoutedEdge: Equatable {
        /// Index into the caller's edge array.
        var index: Int
        var points: [CGPoint]
        var isBackEdge: Bool
        var isSelfLoop: Bool
    }

    /// Node centers, indexed like the input.
    let centers: [CGPoint]
    let ranks: [Int]
    let edges: [RoutedEdge]
    /// Encloses every node frame and every route point, plus the margin on the right and bottom.
    let size: CGSize
    let crossings: Int

    enum Refusal: Error, Equatable {
        case tooManyNodes(count: Int, limit: Int)
        case tooManyEdges(count: Int, limit: Int)
        case tooManyLayeredNodes(count: Int, limit: Int)
        case tooManyLayers(count: Int, limit: Int)
        /// Caller error (bad node count, edge endpoint, fixed-rank length, metrics or limits).
        case invalidInput(String)

        var message: String {
            switch self {
            case .tooManyNodes(let count, let limit):
                "Layered layout is off for this graph: \(count) blocks is over the \(limit)-block limit. Blocks are stacked in address order."
            case .tooManyEdges(let count, let limit):
                "Layered layout is off for this graph: \(count) edges is over the \(limit)-edge limit. Blocks are stacked in address order."
            case .tooManyLayeredNodes(let count, let limit):
                "Layered layout is off for this graph: its long edges need \(count) routing slots, over the \(limit) limit. Blocks are stacked in address order."
            case .tooManyLayers(let count, let limit):
                "Layered layout is off for this graph: it needs \(count) layers, over the \(limit)-layer limit. Blocks are stacked in address order."
            case .invalidInput(let reason):
                "Layered layout is off for this graph: \(reason). Blocks are stacked in address order."
            }
        }
    }

    static func layout(
        nodeCount: Int,
        entry: Int?,
        edges: [EdgeInput],
        fixedRanks: [Int]? = nil,
        metrics: Metrics,
        limits: Limits = Limits()
    ) -> Result<LayeredGraphLayout, Refusal> {
        // 0. Validation; nothing proportional to an unchecked value is allocated before this passes.
        guard nodeCount >= 0 else { return .failure(.invalidInput("negative node count")) }
        guard nodeCount <= limits.maximumNodes else {
            return .failure(.tooManyNodes(count: nodeCount, limit: limits.maximumNodes))
        }
        guard edges.count <= limits.maximumEdges else {
            return .failure(.tooManyEdges(count: edges.count, limit: limits.maximumEdges))
        }
        guard metrics.isValid else { return .failure(.invalidInput("node size, gaps or margin are not finite and positive")) }
        let ceiling = Limits.ceiling
        guard (0...Limits.maximumSweeps).contains(limits.sweeps),
              (0...ceiling.maximumLayeredNodes).contains(limits.maximumLayeredNodes),
              (1...ceiling.maximumLayers).contains(limits.maximumLayers),
              (0...ceiling.maximumNodes).contains(limits.maximumNodes),
              (0...ceiling.maximumEdges).contains(limits.maximumEdges) else {
            return .failure(.invalidInput("layout limits are out of range"))
        }
        guard edges.allSatisfy({ (0..<nodeCount).contains($0.from) && (0..<nodeCount).contains($0.to) }) else {
            return .failure(.invalidInput("an edge names a node that does not exist"))
        }
        if let fixedRanks, fixedRanks.count != nodeCount {
            return .failure(.invalidInput("fixed ranks do not match the node count"))
        }
        guard nodeCount <= limits.maximumLayeredNodes else {
            return .failure(.tooManyLayeredNodes(count: nodeCount, limit: limits.maximumLayeredNodes))
        }
        guard nodeCount > 0 else {
            return .success(LayeredGraphLayout(centers: [], ranks: [], edges: [], size: .zero, crossings: 0))
        }

        // Canonical processing order: (from, to, input index). Output keeps the input index.
        let ordered: [(index: Int, edge: EdgeInput)] = edges.enumerated()
            .map { (index: $0.offset, edge: $0.element) }
            .sorted { lhs, rhs in
                if lhs.edge.from != rhs.edge.from { return lhs.edge.from < rhs.edge.from }
                if lhs.edge.to != rhs.edge.to { return lhs.edge.to < rhs.edge.to }
                return lhs.index < rhs.index
            }

        // 1. Back edges.
        var successors = Array(repeating: [Int](), count: nodeCount)
        for item in ordered where item.edge.from != item.edge.to { successors[item.edge.from].append(item.edge.to) }
        for index in successors.indices { successors[index] = Array(Set(successors[index])).sorted() }
        let backPairs = fixedRanks == nil ? backEdgePairs(nodeCount: nodeCount, entry: entry, successors: successors) : []

        // 2. Ranks, with the span checked without overflow before any layer is allocated.
        let ranks: [Int]
        if let fixedRanks {
            let low = fixedRanks.min() ?? 0, high = fixedRanks.max() ?? 0
            let (span, overflow) = high.subtractingReportingOverflow(low)
            guard !overflow, span < limits.maximumLayers else {
                return .failure(.tooManyLayers(count: overflow || span == Int.max ? Int.max : span + 1,
                                                limit: limits.maximumLayers))
            }
            ranks = fixedRanks.map { $0 - low }
        } else {
            ranks = longestPathRanks(nodeCount: nodeCount, successors: successors, backPairs: backPairs)
            // A longest path has at most nodeCount ranks; still checked against the same limit.
            let span = ranks.max() ?? 0
            guard span < limits.maximumLayers else {
                return .failure(.tooManyLayers(count: span + 1, limit: limits.maximumLayers))
            }
        }
        let layerCount = (ranks.max() ?? 0) + 1
        func isBack(_ edge: EdgeInput) -> Bool {
            if edge.from == edge.to { return true }
            if fixedRanks != nil { return ranks[edge.from] > ranks[edge.to] }
            return backPairs.contains(Pair(edge.from, edge.to))
        }

        // 3. Layered graph with dummies. The dummy total is counted first (ranks are bounded, so
        // the sum cannot overflow) and checked before any dummy is created.
        // Ranks are below maximumLayers (≤ 100,000) and the sum stops at the first excess, so
        // nothing here can overflow.
        var dummyCount = 0
        for item in ordered where item.edge.from != item.edge.to {
            dummyCount += max(abs(ranks[item.edge.to] - ranks[item.edge.from]) - 1, 0)
            guard nodeCount + dummyCount <= limits.maximumLayeredNodes else {
                return .failure(.tooManyLayeredNodes(count: nodeCount + dummyCount, limit: limits.maximumLayeredNodes))
            }
        }
        var layerOf = ranks
        layerOf.reserveCapacity(nodeCount + dummyCount)
        var chains: [(index: Int, chain: [Int], back: Bool, from: Int)] = []
        var down = Array(repeating: [Int](), count: nodeCount)
        var up = Array(repeating: [Int](), count: nodeCount)
        func addVertex(rank: Int) -> Int {
            layerOf.append(rank); down.append([]); up.append([]); return layerOf.count - 1
        }
        for item in ordered where item.edge.from != item.edge.to {
            let edge = item.edge
            let (top, bottom) = ranks[edge.from] <= ranks[edge.to] ? (edge.from, edge.to) : (edge.to, edge.from)
            var chain = [top]
            if ranks[bottom] - ranks[top] > 1 {
                for rank in (ranks[top] + 1)..<ranks[bottom] { chain.append(addVertex(rank: rank)) }
            }
            chain.append(bottom)
            for (a, b) in zip(chain, chain.dropFirst()) where layerOf[a] != layerOf[b] {
                down[a].append(b); up[b].append(a)
            }
            chains.append((item.index, chain, isBack(edge), edge.from))
        }

        // 4. Ordering. Initial order: real nodes in index order, dummies in canonical creation order.
        var layers = Array(repeating: [Int](), count: layerCount)
        for vertex in layerOf.indices { layers[layerOf[vertex]].append(vertex) }
        var position = Array(repeating: 0, count: layerOf.count)
        func renumber() { for layer in layers { for (slot, vertex) in layer.enumerated() { position[vertex] = slot } } }
        renumber()
        // Sweeps from both starting directions on the same initial order; the fewer crossings
        // win (ties keep the downward-first result), so one direction's local minimum is not final.
        let initial = layers
        var best = layers
        var bestCrossings = countCrossings(layers: layers, down: down, position: position)
        if bestCrossings > 0 {
            for startsDownward in [true, false] {
                layers = initial
                renumber()
                for sweep in 0..<limits.sweeps {
                    let downward = (sweep % 2 == 0) == startsDownward
                    let order = downward ? Array(1..<max(layerCount, 1)) : Array((0..<max(layerCount - 1, 0)).reversed())
                    for layerIndex in order {
                        let neighbours = downward ? up : down
                        var keyed: [(key: Double, slot: Int, vertex: Int)] = []
                        for (slot, vertex) in layers[layerIndex].enumerated() {
                            let adjacent = neighbours[vertex]
                            var key = Double(slot)
                            if !adjacent.isEmpty {
                                var sum = 0
                                for neighbour in adjacent { sum += position[neighbour] }
                                key = Double(sum) / Double(adjacent.count)
                            }
                            keyed.append((key, slot, vertex))
                        }
                        keyed.sort { lhs, rhs in lhs.key != rhs.key ? lhs.key < rhs.key : lhs.slot < rhs.slot }
                        layers[layerIndex] = keyed.map(\.vertex)
                        for (slot, vertex) in layers[layerIndex].enumerated() { position[vertex] = slot }
                    }
                    let crossings = countCrossings(layers: layers, down: down, position: position)
                    if crossings < bestCrossings { best = layers; bestCrossings = crossings }
                    if bestCrossings == 0 { break }
                }
                if bestCrossings == 0 { break }
            }
        }
        layers = best
        renumber()
        if bestCrossings > 0 {
            bestCrossings = transpose(layers: &layers, position: &position, up: up, down: down,
                                      crossings: bestCrossings, passes: limits.sweeps)
        }

        // 5. Coordinates (unrounded: rounding centres independently can break separation).
        let step = metrics.nodeSize.width + metrics.horizontalGap
        var x = Array(repeating: CGFloat(0), count: layerOf.count)
        for layer in layers { for (slot, vertex) in layer.enumerated() { x[vertex] = CGFloat(slot) * step } }
        for pass in 0..<4 {
            let downward = pass % 2 == 0
            let order = downward ? Array(0..<layerCount) : Array((0..<layerCount).reversed())
            for layerIndex in order {
                let neighbours = downward ? up : down
                let layer = layers[layerIndex]
                var desired: [CGFloat] = []
                for vertex in layer {
                    let adjacent: [CGFloat] = neighbours[vertex].map { x[$0] }.sorted()
                    let middle = adjacent.count / 2
                    if adjacent.isEmpty {
                        desired.append(x[vertex])
                    } else if adjacent.count % 2 == 1 {
                        desired.append(adjacent[middle])
                    } else {
                        desired.append((adjacent[middle - 1] + adjacent[middle]) / 2)
                    }
                }
                // Keep order and minimum separation.
                for slot in desired.indices.dropFirst() where desired[slot] < desired[slot - 1] + step {
                    desired[slot] = desired[slot - 1] + step
                }
                for (slot, vertex) in layer.enumerated() { x[vertex] = desired[slot] }
            }
        }
        // A lone entry on the top layer sits centred over the drawing, not wherever the median
        // passes pulled it.
        if fixedRanks == nil, let entry, entry >= 0, entry < nodeCount, layers.first == [entry] {
            let others = (0..<nodeCount).filter { $0 != entry }.map { x[$0] }
            if let low = others.min(), let high = others.max() { x[entry] = (low + high) / 2 }
        }
        let minimumX = x.min() ?? 0
        let originX = metrics.margin + metrics.nodeSize.width / 2 - minimumX
        let layerStep = metrics.nodeSize.height + metrics.layerGap
        func center(_ vertex: Int) -> CGPoint {
            let cx: CGFloat = x[vertex] + originX
            let cy: CGFloat = metrics.margin + metrics.nodeSize.height / 2 + CGFloat(layerOf[vertex]) * layerStep
            return CGPoint(x: cx, y: cy)
        }
        let centers = (0..<nodeCount).map(center)

        // 6. Routes.
        let half = metrics.nodeSize.height / 2
        var routed: [RoutedEdge] = []
        // A back edge is nudged sideways so it never hides under a forward edge between the
        // same two nodes (a call and its recursive return, a loop latch beside a fall-through).
        // Capped by node width so a back edge still touches small nodes (dot I1F2).
        let backOffset: CGFloat = min(metrics.horizontalGap * 0.4, 14, metrics.nodeSize.width / 4)
        for (index, chain, back, from) in chains {
            let first = center(chain[0]), last = center(chain[chain.count - 1])
            var points: [CGPoint] = []
            if first.y < last.y {
                // Leave the upper node from its bottom, run vertically through each crossed
                // layer's slot (top and bottom of the slot), enter the lower node from its top:
                // between layers the edge only crosses the gap, never a node.
                points.append(CGPoint(x: first.x, y: first.y + half))
                for dummy in chain.dropFirst().dropLast() {
                    let c = center(dummy)
                    points.append(CGPoint(x: c.x, y: c.y - half))
                    points.append(CGPoint(x: c.x, y: c.y + half))
                }
                points.append(CGPoint(x: last.x, y: last.y - half))
            } else {
                // Same rank (fixed ranks only): side to side.
                let sign: CGFloat = last.x > first.x ? 1 : -1
                points = [CGPoint(x: first.x + sign * metrics.nodeSize.width / 2, y: first.y),
                          CGPoint(x: last.x - sign * metrics.nodeSize.width / 2, y: last.y)]
            }
            if back {
                for i in points.indices { points[i].x += backOffset }
            }
            if chain[0] != from { points.reverse() }
            routed.append(RoutedEdge(index: index, points: points, isBackEdge: back, isSelfLoop: false))
        }
        for item in ordered where item.edge.from == item.edge.to {
            let c = centers[item.edge.from]
            let right = c.x + metrics.nodeSize.width / 2
            let loop = min(metrics.horizontalGap * 0.6, 28)
            routed.append(RoutedEdge(index: item.index, points: [
                CGPoint(x: right, y: c.y - half * 0.4),
                CGPoint(x: right + loop, y: c.y - half * 0.4),
                CGPoint(x: right + loop, y: c.y + half * 0.4),
                CGPoint(x: right, y: c.y + half * 0.4),
            ], isBackEdge: true, isSelfLoop: true))
        }
        routed.sort { $0.index < $1.index }

        // Size encloses every node frame and every route point (self-loops reach right of nodes).
        var maxX: CGFloat = 0, maxY: CGFloat = 0
        for c in centers {
            maxX = max(maxX, c.x + metrics.nodeSize.width / 2)
            maxY = max(maxY, c.y + half)
        }
        for edge in routed {
            for point in edge.points { maxX = max(maxX, point.x); maxY = max(maxY, point.y) }
        }
        return .success(LayeredGraphLayout(
            centers: centers, ranks: ranks, edges: routed,
            size: CGSize(width: (maxX + metrics.margin).rounded(.up), height: (maxY + metrics.margin).rounded(.up)),
            crossings: bestCrossings
        ))
    }

    /// Adjacent transposition: swaps neighbours in a layer when that lowers, or keeps equal, the
    /// crossings between their edges (sideways moves escape tie-bound local minima, dot I1F2).
    /// An adjacent swap changes the total by exactly that pair's difference, so the running total
    /// is kept without a recount; the best order seen is restored at the end. At most `passes`
    /// rounds; equal swaps are only taken while crossings remain.
    private static func transpose(layers: inout [[Int]], position: inout [Int], up: [[Int]], down: [[Int]],
                                  crossings: Int, passes: Int) -> Int {
        func pairCrossings(_ u: Int, _ v: Int) -> Int {
            // Crossings between u's and v's edges when u sits left of v.
            var total = 0
            for neighbours in [up, down] {
                for a in neighbours[u] { for b in neighbours[v] where position[a] > position[b] { total += 1 } }
            }
            return total
        }
        var total = crossings
        var best = layers
        var bestTotal = crossings
        for _ in 0..<passes {
            var changed = false
            for layerIndex in layers.indices where layers[layerIndex].count > 1 {
                for slot in 0..<(layers[layerIndex].count - 1) where bestTotal > 0 {
                    let u = layers[layerIndex][slot], v = layers[layerIndex][slot + 1]
                    let current = pairCrossings(u, v), swapped = pairCrossings(v, u)
                    guard swapped < current || (swapped == current && current > 0) else { continue }
                    layers[layerIndex].swapAt(slot, slot + 1)
                    position[u] = slot + 1
                    position[v] = slot
                    total += swapped - current
                    changed = true
                    if total < bestTotal { bestTotal = total; best = layers }
                }
            }
            if !changed || bestTotal == 0 { break }
        }
        layers = best
        for layer in layers { for (slot, vertex) in layer.enumerated() { position[vertex] = slot } }
        return bestTotal
    }

    // MARK: - Steps

    private struct Pair: Hashable {
        let a: Int, b: Int
        init(_ a: Int, _ b: Int) { self.a = a; self.b = b }
    }

    private static func backEdgePairs(nodeCount: Int, entry: Int?, successors: [[Int]]) -> Set<Pair> {
        var state = Array(repeating: UInt8(0), count: nodeCount) // 0 new, 1 on stack, 2 done
        var back = Set<Pair>()
        var roots: [Int] = []
        if let entry, entry >= 0, entry < nodeCount { roots.append(entry) }
        roots += (0..<nodeCount)
        for root in roots where state[root] == 0 {
            var stack: [(vertex: Int, next: Int)] = [(root, 0)]
            state[root] = 1
            while let top = stack.last {
                let list = successors[top.vertex]
                if top.next < list.count {
                    stack[stack.count - 1].next += 1
                    let target = list[top.next]
                    switch state[target] {
                    case 0: state[target] = 1; stack.append((target, 0))
                    case 1: back.insert(Pair(top.vertex, target))
                    default: break
                    }
                } else {
                    state[top.vertex] = 2
                    stack.removeLast()
                }
            }
        }
        return back
    }

    private static func longestPathRanks(nodeCount: Int, successors: [[Int]], backPairs: Set<Pair>) -> [Int] {
        var forward = Array(repeating: [Int](), count: nodeCount)
        var indegree = Array(repeating: 0, count: nodeCount)
        for from in 0..<nodeCount {
            for to in successors[from] where !backPairs.contains(Pair(from, to)) {
                forward[from].append(to); indegree[to] += 1
            }
        }
        var rank = Array(repeating: 0, count: nodeCount)
        var ready = (0..<nodeCount).filter { indegree[$0] == 0 }
        var cursor = 0
        while cursor < ready.count {
            let vertex = ready[cursor]; cursor += 1
            for target in forward[vertex] {
                rank[target] = max(rank[target], rank[vertex] + 1)
                indegree[target] -= 1
                if indegree[target] == 0 { ready.append(target) }
            }
        }
        return rank
    }

    private static func countCrossings(layers: [[Int]], down: [[Int]], position: [Int]) -> Int {
        var total = 0
        for layer in layers.dropLast() {
            var segments: [(Int, Int)] = []
            for vertex in layer { for target in down[vertex] { segments.append((position[vertex], position[target])) } }
            segments.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            // Inversions in the lower endpoints (n² is fine at these bounds per layer pair).
            if segments.count > 1 {
                for i in 0..<(segments.count - 1) {
                    for j in (i + 1)..<segments.count
                    where segments[i].0 != segments[j].0 && segments[j].1 < segments[i].1 { total += 1 }
                }
            }
        }
        return total
    }
}
