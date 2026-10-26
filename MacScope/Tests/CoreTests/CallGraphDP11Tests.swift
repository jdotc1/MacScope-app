import CoreGraphics
import Foundation
import XCTest
@testable import MacScope

/// DP11 findings on the call graph: (a) the owning function of a call site is found however many
/// functions start between its start and the call site; (b) a mutually recursive neighbour still
/// has its own callers expanded.
final class CallGraphDP11Tests: XCTestCase {
    private let metrics = LayeredGraphLayout.Metrics(nodeSize: CGSize(width: 120, height: 40), horizontalGap: 32,
                                                     layerGap: 48, margin: 24)

    private func function(_ name: String, _ start: UInt64, _ end: UInt64) -> FunctionSummary {
        FunctionSummary(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", start))!,
                        name: name, startAddress: start, endAddress: end, confidence: 1)
    }

    private func call(_ from: UInt64, _ to: UInt64) -> XRef { XRef(id: UUID(), from: from, to: to, kind: "call") }

    private func projection(_ functions: [FunctionSummary], _ xrefs: [XRef]) -> FocusedGraphProjection {
        FocusedGraphProjection(imageSlot: .primary, ownerBinaryID: UUID(), functions: functions, basicBlocks: [],
                               instructions: [], controlFlowEdges: [], xrefs: xrefs, presentationByAddress: [:])
    }

    func testOwnerIsFoundPastManyInterveningStarts() throws {
        let outer = function("outer", 0x1000, 0x9000)
        // 70 small functions start inside `outer` (e.g. outlined fragments) but end before the call site.
        let fragments = (0..<70).map { function("frag_\($0)", 0x2000 + UInt64($0) * 0x10, 0x2000 + UInt64($0) * 0x10 + 8) }
        let callee = function("callee", 0xA000, 0xA100)
        let index = FunctionRangeIndex([outer, callee] + fragments)
        XCTAssertEqual(index.owner(of: 0x8000)?.id, outer.id, "found beyond 64 intervening starts")
        XCTAssertEqual(index.owner(of: 0x2004)?.id, nil, "two containers (outer and a fragment): ambiguous, not guessed")

        let model = try XCTUnwrap(CallGraphModel.build(projection: projection([outer, callee] + fragments, [call(0x8000, 0xA000)]),
                                                       rootFunctionID: callee.id, depth: 1, metrics: metrics))
        XCTAssertEqual(model.nodes.first { $0.depth == -1 }?.name, "outer", "the call is attributed to its real caller")
    }

    func testMutuallyRecursiveNeighbourKeepsItsCallers() throws {
        let root = function("root", 0x1000, 0x1100)
        let peer = function("peer", 0x2000, 0x2100)     // root ⇄ peer
        let outside = function("outside", 0x3000, 0x3100) // outside → peer
        let model = try XCTUnwrap(CallGraphModel.build(
            projection: projection([root, peer, outside], [call(0x1010, 0x2000), call(0x2010, 0x1000), call(0x3010, 0x2000)]),
            rootFunctionID: root.id, depth: 2, metrics: metrics))
        XCTAssertTrue(model.nodes.contains { $0.name == "outside" }, "peer's caller is found even though peer was first reached as a callee")
        XCTAssertEqual(model.nodes.first { $0.name == "peer" }?.depth, 1, "a node keeps the rank of its first discovery")
        XCTAssertTrue(model.edges.contains { $0.from == outside.id && $0.to == peer.id })
    }
}
