import CoreGraphics
import Foundation
import XCTest
@testable import MacScope

/// The layered CFG layout and the call graph built on it: deterministic geometry, ranks from
/// back-edge removal, no overlapping nodes, crossing reduction, and the size cap's refusal.
final class LayeredGraphLayoutTests: XCTestCase {
    private let metrics = LayeredGraphLayout.Metrics(
        nodeSize: CGSize(width: 120, height: 40), horizontalGap: 32, layerGap: 48, margin: 24)

    private func edges(_ pairs: [(Int, Int)]) -> [LayeredGraphLayout.EdgeInput] {
        pairs.map { .init(from: $0.0, to: $0.1) }
    }

    private func layout(_ count: Int, _ pairs: [(Int, Int)], limits: LayeredGraphLayout.Limits = .init())
        throws -> LayeredGraphLayout {
        try LayeredGraphLayout.layout(nodeCount: count, entry: 0, edges: edges(pairs),
                                      metrics: metrics, limits: limits).get()
    }

    /// if/else diamond inside a loop: 0 → 1 → {2,3} → 4 → 1 (back), 4 → 5.
    private let loopDiamond = [(0, 1), (1, 2), (1, 3), (2, 4), (3, 4), (4, 1), (4, 5)]

    func testRanksFollowLongestPathAfterBackEdgeRemoval() throws {
        let result = try layout(6, loopDiamond)
        XCTAssertEqual(result.ranks, [0, 1, 2, 2, 3, 4])
        let back = result.edges.filter(\.isBackEdge)
        XCTAssertEqual(back.map(\.index), [5], "only 4 → 1 closes the loop")
        let backPoints = try XCTUnwrap(back.first?.points)
        XCTAssertGreaterThan(backPoints.first!.y, backPoints.last!.y, "a back edge keeps its upward direction")
    }

    func testLoneEntryIsCentredOverTheDrawing() throws {
        // The entry fans out to a deep left chain and a short right exit; it sits mid-drawing.
        let result = try layout(6, [(0, 1), (0, 5), (1, 2), (1, 3), (2, 4), (3, 4), (4, 1)])
        let xs = result.centers.dropFirst().map(\.x)
        XCTAssertEqual(result.centers[0].x, ((xs.min()! + xs.max()!) / 2).rounded(), accuracy: 1)
    }

    func testGeometryIsDeterministicAndIndependentOfEdgeOrder() throws {
        let a = try layout(6, loopDiamond)
        let b = try layout(6, loopDiamond)
        XCTAssertEqual(a, b)
        let shuffled = try layout(6, loopDiamond.reversed())
        XCTAssertEqual(a.centers, shuffled.centers)
        XCTAssertEqual(a.ranks, shuffled.ranks)
    }

    func testNoNodesOverlapAndLongEdgesBendThroughDummySlots() throws {
        // A skip edge 0 → 3 over a 0 → 1 → 2 → 3 chain, plus a wide fan.
        let pairs = [(0, 1), (1, 2), (2, 3), (0, 3), (0, 4), (0, 5), (0, 6), (4, 3), (5, 3), (6, 3)]
        let result = try layout(7, pairs)
        let frames = result.centers.map {
            CGRect(x: $0.x - 60, y: $0.y - 20, width: 120, height: 40)
        }
        for i in frames.indices { for j in frames.indices where i < j {
            XCTAssertFalse(frames[i].intersects(frames[j]), "nodes \(i) and \(j) overlap")
        } }
        let skip = try XCTUnwrap(result.edges.first { $0.index == 3 })
        XCTAssertEqual(skip.points.count, 6, "two crossed layers → a vertical run through each slot")
        // Between layers the route only crosses gaps: no segment's interior enters a node.
        for (a, b) in zip(skip.points, skip.points.dropFirst()) {
            for frame in frames.indices.filter({ $0 != 0 && $0 != 3 }).map({ frames[$0] }) {
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                XCTAssertFalse(frame.insetBy(dx: 1, dy: 1).contains(mid), "skip edge runs through a node")
            }
        }
        XCTAssertTrue(frames.allSatisfy { $0.minX >= 24 && $0.minY >= 24 })
        XCTAssertTrue(frames.allSatisfy { $0.maxX <= result.size.width && $0.maxY <= result.size.height })
    }

    func testBarycenterSweepsRemoveAvoidableCrossings() throws {
        // Address order puts 1 and 2 against their targets: 1 → 4, 2 → 3. Sweeps uncross them.
        let result = try layout(5, [(0, 1), (0, 2), (1, 4), (2, 3)])
        XCTAssertEqual(result.crossings, 0)
    }

    func testSelfLoopIsABackEdgeOnTheRight() throws {
        let result = try layout(2, [(0, 1), (1, 1)])
        let loop = try XCTUnwrap(result.edges.first(where: \.isSelfLoop))
        XCTAssertTrue(loop.isBackEdge)
        XCTAssertTrue(loop.points.allSatisfy { $0.x >= result.centers[1].x + 60 })
    }

    func testCapRefusesWithAClearMessage() {
        let pairs = (0..<9).map { ($0, $0 + 1) }
        var limits = LayeredGraphLayout.Limits()
        limits.maximumNodes = 8
        let result = LayeredGraphLayout.layout(nodeCount: 10, entry: 0, edges: edges(pairs), metrics: metrics, limits: limits)
        guard case .failure(let refusal) = result else { return XCTFail("expected the node cap to refuse") }
        XCTAssertEqual(refusal, .tooManyNodes(count: 10, limit: 8))
        XCTAssertTrue(refusal.message.contains("10 blocks is over the 8-block limit"))

        limits = .init()
        limits.maximumLayeredNodes = 5
        let deep = LayeredGraphLayout.layout(nodeCount: 4, entry: 0, edges: edges([(0, 1), (1, 2), (2, 3), (0, 3)]),
                                             metrics: metrics, limits: limits)
        guard case .failure(.tooManyLayeredNodes) = deep else { return XCTFail("expected the routing-slot cap") }
    }

    // MARK: - Call graph

    private func function(_ name: String, _ start: UInt64, _ end: UInt64) -> FunctionSummary {
        FunctionSummary(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", start))!,
                        name: name, startAddress: start, endAddress: end, confidence: 1)
    }

    private func call(_ from: UInt64, _ to: UInt64) -> XRef {
        XRef(id: UUID(), from: from, to: to, kind: "call")
    }

    func testCallGraphPlacesCallersAboveAndCalleesBelowToTheRequestedDepth() throws {
        let main = function("main", 0x1000, 0x1100)
        let parse = function("parse", 0x2000, 0x2100)
        let lex = function("lex", 0x3000, 0x3100)
        let alloc = function("alloc", 0x4000, 0x4100)
        let start = function("start", 0x500, 0x600)
        let projection = FocusedGraphProjection(
            imageSlot: .primary, ownerBinaryID: UUID(),
            functions: [main, parse, lex, alloc, start], basicBlocks: [], instructions: [], controlFlowEdges: [],
            xrefs: [call(0x510, 0x1000), call(0x1010, 0x2000), call(0x1020, 0x2000), call(0x2010, 0x3000),
                    call(0x3010, 0x4000), call(0x3020, 0x2000), XRef(id: UUID(), from: 0x1030, to: 0x4000, kind: "data")],
            presentationByAddress: [:])

        let depth1 = try XCTUnwrap(CallGraphModel.build(projection: projection, rootFunctionID: main.id, depth: 1, metrics: metrics))
        XCTAssertEqual(depth1.nodes.map(\.name), ["main", "parse", "start"])
        XCTAssertEqual(depth1.nodes.map(\.depth), [0, 1, -1])
        XCTAssertEqual(depth1.edges.first { $0.from == main.id }?.callSites, 2, "two call sites fold into one edge")
        let root = try XCTUnwrap(depth1.nodes.first(where: \.isRoot))
        XCTAssertLessThan(depth1.nodes.first { $0.name == "start" }!.center.y, root.center.y)
        XCTAssertGreaterThan(depth1.nodes.first { $0.name == "parse" }!.center.y, root.center.y)

        let depth3 = try XCTUnwrap(CallGraphModel.build(projection: projection, rootFunctionID: main.id, depth: 3, metrics: metrics))
        XCTAssertEqual(Set(depth3.nodes.map(\.name)), ["main", "parse", "lex", "alloc", "start"])
        XCTAssertFalse(depth3.edges.contains { $0.to == alloc.id && $0.from == main.id }, "data xrefs are not calls")
        XCTAssertTrue(try XCTUnwrap(depth3.edges.first { $0.from == lex.id && $0.to == parse.id }).isBackEdge,
                      "lex → parse runs upward (recursion through parse)")
        XCTAssertEqual(depth3, CallGraphModel.build(projection: projection, rootFunctionID: main.id, depth: 3, metrics: metrics))

        let capped = try XCTUnwrap(CallGraphModel.build(projection: projection, rootFunctionID: main.id, depth: 3,
                                                        maximumNodes: 2, metrics: metrics))
        XCTAssertEqual(capped.nodes.count, 2)
        XCTAssertEqual(capped.truncatedAt, 2)
    }
}
