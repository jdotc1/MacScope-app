import AppKit
import SwiftUI
import XCTest
@testable import MacScope

/// The large-overview crash (libjpeg, 914 functions: AttributeGraph table exhausted by one view
/// per node): a 1,000-function overview selects the single-Canvas renderer, renders offscreen,
/// and its hit test finds nodes; the drawn-node cap holds.
@MainActor
final class GraphLargeOverviewTests: XCTestCase {
    private static func id(_ n: UInt64) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", n))!
    }

    /// `functions` functions of three blocks each, chained by fall-throughs and a call apiece.
    static func overview(functions: Int) -> FocusedGraphProjection {
        var summaries: [FunctionSummary] = [], blocks: [BasicBlockSummary] = []
        var edges: [ControlFlowEdge] = [], xrefs: [XRef] = []
        for f in 0..<functions {
            let base = 0x10_0000 + UInt64(f) * 0x100
            let function = FunctionSummary(id: id(UInt64(f) + 1), name: "fn_\(f)", startAddress: base,
                                           endAddress: base + 0x30, confidence: 1)
            summaries.append(function)
            for b in 0..<3 {
                let start = base + UInt64(b) * 0x10
                blocks.append(BasicBlockSummary(id: id(0x1_0000_0000 + UInt64(f * 3 + b)), functionID: function.id,
                                                startAddress: start, endAddress: start + 0x10, instructionCount: 4))
                if b < 2 {
                    edges.append(ControlFlowEdge(id: id(0x2_0000_0000 + UInt64(f * 3 + b)), from: start + 0xc,
                                                 to: start + 0x10, kind: "fallthrough"))
                }
            }
            if f > 0 { xrefs.append(XRef(id: id(0x3_0000_0000 + UInt64(f)), from: base + 0x4, to: base - 0x100, kind: "call")) }
        }
        return FocusedGraphProjection(imageSlot: .primary, ownerBinaryID: id(9), functions: summaries, basicBlocks: blocks,
                                      instructions: [], controlFlowEdges: edges, xrefs: xrefs, presentationByAddress: [:])
    }

    func testThousandFunctionOverviewRendersAsOneCanvas() throws {
        let layout = FocusedGraphBuilder.build(Self.overview(functions: 1_000), viewport: CGSize(width: 1_200, height: 800))
        XCTAssertEqual(layout.nodes.count, 3_000)
        XCTAssertTrue(GraphRenderBudget.drawsAsCanvas(layout), "no per-node views above the budget")
        XCTAssertLessThanOrEqual(layout.nodes.count, GraphRenderBudget.maximumDrawnNodes)

        // Render a window of the canvas offscreen: one Canvas, however many nodes it draws.
        let view = GraphLargeCanvas(layout: layout, selectedAddress: nil, selectedEdgeID: nil, onSelect: { _ in })
            .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
            .frame(width: 1_200, height: 800, alignment: .topLeading)
            .clipped()
        let renderer = ImageRenderer(content: view)
        XCTAssertNotNil(renderer.cgImage)

        let node = try XCTUnwrap(layout.nodes.dropFirst(10).first)
        XCTAssertEqual(GraphLargeCanvas.node(at: node.center, in: layout)?.id, node.id)
        XCTAssertNil(GraphLargeCanvas.node(at: CGPoint(x: -10, y: -10), in: layout))
    }

    func testSmallGraphsKeepPerNodeViews() {
        let layout = FocusedGraphBuilder.build(Self.overview(functions: 20), viewport: CGSize(width: 1_200, height: 800))
        XCTAssertFalse(GraphRenderBudget.drawsAsCanvas(layout))
    }

    func testRenderLargeOverviewForReview() throws {
        let layout = FocusedGraphBuilder.build(Self.overview(functions: 400), viewport: CGSize(width: 1_200, height: 800))
        XCTAssertTrue(GraphRenderBudget.drawsAsCanvas(layout))
        let selected = ImageAddress(slot: .primary, address: layout.nodes[4].startAddress)
        try UIReviewShots.write("graph-large-overview-canvas", size: CGSize(width: 1_200, height: 700)) {
            GraphLargeCanvas(layout: layout, selectedAddress: selected, selectedEdgeID: nil, onSelect: { _ in })
                .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
                .frame(width: 1_200, height: 700, alignment: .topLeading)
                .clipped()
        }
    }
}
