import Foundation
import XCTest
@testable import MacScope

/// Tier 2b finding: importing a large binary (/usr/bin/vim) hung on the main actor because the
/// store's graph-selection sync built the whole graph, and edge routing scanned every node per edge.
/// The sync now reads node targets only, and edges look nodes up through `GraphNodeIndex`, which
/// must pick exactly the node a linear first-match scan would.
@MainActor
final class GraphNodeIndexTests: XCTestCase {
    private func node(_ start: UInt64, _ end: UInt64, slot: ImageSlot = .primary, id: String) -> GraphNodeModel {
        GraphNodeModel(
            selectionTarget: GraphSelectionTarget(id: id, imageSlot: slot, title: id, startAddress: start,
                                                  endAddress: end, functionID: nil),
            title: id, subtitle: "", instructionCount: 1, confidence: 1, kind: .basicBlock,
            functionName: "f", ordinal: nil, isEntry: false
        )
    }

    private func linearFirst(_ nodes: [GraphNodeModel], _ address: ImageAddress, orStartingAt start: UInt64? = nil) -> String? {
        nodes.first { $0.contains(address) || (start != nil && $0.startAddress == start) }?.id
    }

    func testTheIndexPicksTheSameNodeAsALinearScan() {
        let nodes = [
            node(0x1000, 0x1040, id: "a"), node(0x1040, 0x1100, id: "b"), node(0x1100, 0x1100, id: "empty"),
            node(0x1020, 0x1030, id: "nested-later"), node(0x2000, 0x9000, id: "wide"),
            node(0x2100, 0x2200, id: "inside-wide"), node(0x1000, 0x1010, slot: ImageSlot(rawValue: 1), id: "other-slot"),
        ]
        let index = GraphNodeIndex(nodes)
        for raw in stride(from: UInt64(0x0FF0), through: 0x9010, by: 0x10) {
            let address = ImageAddress(slot: .primary, address: raw)
            XCTAssertEqual(index.first(containing: address)?.id, linearFirst(nodes, address), String(raw, radix: 16))
            XCTAssertEqual(index.first(containing: address, orStartingAt: raw)?.id,
                           linearFirst(nodes, address, orStartingAt: raw), String(raw, radix: 16))
        }
        XCTAssertEqual(index.first(containing: ImageAddress(slot: .primary, address: 0x1100))?.id, "empty",
                       "A zero-length node contains its own start")
        XCTAssertEqual(index.first(containing: ImageAddress(slot: .primary, address: 0x1024))?.id, "a",
                       "Overlaps keep the earliest node in array order")
    }

    func testSelectionTargetsMatchTheBuiltGraphsNodesWithoutBuildingIt() {
        let snapshot = AnalysisEngine.previewSnapshot()
        let projection = snapshot.graphProjection(in: snapshot.primarySlot)
        let built = FocusedGraphBuilder.build(projection, viewport: .zero)
        XCTAssertFalse(built.nodes.isEmpty)
        XCTAssertEqual(FocusedGraphBuilder.selectionTargets(projection), built.nodes.map(\.selectionTarget))
        let index = GraphNodeIndex(built.nodes)
        for edge in built.edges {
            let from = ImageAddress(slot: projection.imageSlot, address: edge.selectionTarget.fromAddress)
            XCTAssertEqual(index.first(containing: from)?.displayTitle, edge.sourceTitle)
        }
    }
    // MARK: U9-5: block-less function nodes count their rows by binary search

    private func row(_ address: UInt64) -> InstructionRow {
        InstructionRow(address: address, bytes: "1f2003d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil)
    }

    private func target(_ start: UInt64, _ end: UInt64) -> GraphSelectionTarget {
        GraphSelectionTarget(id: "t", imageSlot: .primary, title: "t", startAddress: start, endAddress: end, functionID: nil)
    }

    func testTheAddressIndexCountsExactlyTheRowsContainsAccepts() {
        // Unsorted, with a duplicate address and rows at both extremes.
        let rows = [0x1010, 0x1000, 0x1004, 0x1004, 0x2000, 0, UInt64.max].map(row)
        let index = InstructionAddressIndex(rows)
        let targets = [
            target(0x1000, 0x1010), target(0x1004, 0x1004), target(0x1004, 0x1000), target(0x3000, 0x4000),
            target(0, 0x1001), target(0x2000, UInt64.max), target(UInt64.max, UInt64.max), target(UInt64.max, 0),
        ]
        for target in targets {
            let linear = rows.filter { target.contains(ImageAddress(slot: .primary, address: $0.address)) }.count
            XCTAssertEqual(index.count(in: target), linear, "\(target.startAddress.hexAddress)…\(target.endAddress.hexAddress)")
        }
    }

    /// The vim open spent ~17 s here: each block-less function scanned every instruction.
    func testThousandsOfBlocklessFunctionsBuildTheirTargetsQuickly() {
        let rows = (0..<50_000).map { row(0x1_0000_0000 + UInt64($0) * 4) }
        let functions = (0..<2_000).map { index in
            FunctionSummary(id: UUID(), name: "f\(index)", startAddress: 0x1_0000_0000 + UInt64(index) * 100,
                            endAddress: 0x1_0000_0000 + UInt64(index + 1) * 100, confidence: 1)
        }
        let projection = FocusedGraphProjection(imageSlot: .primary, functions: functions, basicBlocks: [],
                                                instructions: rows, controlFlowEdges: [], xrefs: [],
                                                presentationByAddress: [:])
        let start = Date()
        let targets = FocusedGraphBuilder.selectionTargets(projection)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(targets.count, 2_000)
        XCTAssertLessThan(elapsed, 1, "2,000 block-less functions over 50,000 rows took \(elapsed) s")
    }
}

