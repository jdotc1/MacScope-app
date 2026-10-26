import AppKit
import LumenTokens
import LumenUI
import SwiftUI
import XCTest
@testable import MacScope

/// Offscreen PNG renders of the layered CFG and the call graph for visual review (never
/// goldens, never compared). Written to `MACSCOPE_UI_SHOTS_DIR` (pass it as
/// `TEST_RUNNER_MACSCOPE_UI_SHOTS_DIR`), else a temporary directory; paths are printed.
@MainActor
final class GraphLayoutShotTests: XCTestCase {
    private func write<V: View>(_ name: String, size: CGSize, _ view: V) throws {
        let directory = ProcessInfo.processInfo.environment["MACSCOPE_UI_SHOTS_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent("MacScopeUIShots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let subject = DSSnapshot.Subject(name: name, size: size, view: AnyView(view.lumenRendersOffscreen(true)))
        for variant in [DSSnapshot.Variant(themeID: DSBuiltInThemes.scope.id, colorScheme: .light),
                        DSSnapshot.Variant(themeID: DSBuiltInThemes.scope.id, colorScheme: .dark)] {
            let png = try XCTUnwrap(DSSnapshot.png(of: subject, in: variant, scale: 1.5))
            let url = directory.appendingPathComponent("\(name)-\(variant.label).png")
            try png.write(to: url)
            print("UI review shot: \(url.path)")
        }
    }

    private static func id(_ n: UInt64) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", n))!
    }

    /// A loop around an if/else with an early exit: entry → header ⇄ body (if/else) → latch → header,
    /// header → exit, plus a skip edge from the entry straight to the exit.
    static func loopProjection() -> FocusedGraphProjection {
        let function = FunctionSummary(id: id(1), name: "_parse_records", startAddress: 0x1000, endAddress: 0x1100, confidence: 1)
        let starts: [UInt64] = [0x1000, 0x1010, 0x1020, 0x1030, 0x1040, 0x1050, 0x1060, 0x1070]
        let blocks = starts.enumerated().map { index, start in
            BasicBlockSummary(id: id(0x100 + UInt64(index)), functionID: function.id, startAddress: start,
                              endAddress: start + 0x10, instructionCount: 4)
        }
        let edges: [(UInt64, UInt64, String)] = [
            (0x100c, 0x1010, "fallthrough"), (0x100c, 0x1070, "branch"),
            (0x101c, 0x1020, "fallthrough"), (0x101c, 0x1060, "branch"),
            (0x102c, 0x1030, "fallthrough"), (0x102c, 0x1040, "branch"),
            (0x103c, 0x1050, "branch"), (0x104c, 0x1050, "fallthrough"),
            (0x105c, 0x1010, "branch"), (0x106c, 0x1070, "fallthrough"),
        ]
        return FocusedGraphProjection(
            imageSlot: .primary, ownerBinaryID: id(9), functions: [function], basicBlocks: blocks, instructions: [],
            controlFlowEdges: edges.enumerated().map {
                ControlFlowEdge(id: id(0x200 + UInt64($0.offset)), from: $0.element.0, to: $0.element.1, kind: $0.element.2)
            },
            xrefs: [], presentationByAddress: [:])
    }

    func testRenderLayeredFunctionGraphForReview() throws {
        let layout = FocusedGraphBuilder.build(Self.loopProjection(), viewport: CGSize(width: 1_100, height: 800), layered: true)
        XCTAssertNil(layout.layoutNote)
        XCTAssertTrue(layout.edges.contains(where: \.isBackEdge))
        try write("graph-layered-cfg", size: layout.canvasSize, GraphLayoutReviewCanvas(layout: layout))
    }

    func testRenderCallGraphForReview() throws {
        let names = ["main", "_parse_records", "_read_line", "_tokenize", "_malloc", "_free", "start", "_log_error"]
        let functions = names.enumerated().map {
            FunctionSummary(id: Self.id(UInt64($0.offset + 1)), name: $0.element,
                            startAddress: 0x1000 * UInt64($0.offset + 1), endAddress: 0x1000 * UInt64($0.offset + 1) + 0x100,
                            confidence: 1)
        }
        func call(_ from: Int, _ to: Int, site: UInt64 = 0x10) -> XRef {
            XRef(id: UUID(), from: functions[from].startAddress + site, to: functions[to].startAddress, kind: "call")
        }
        let projection = FocusedGraphProjection(
            imageSlot: .primary, ownerBinaryID: Self.id(9), functions: functions, basicBlocks: [], instructions: [],
            controlFlowEdges: [],
            xrefs: [call(6, 0), call(0, 1), call(0, 1, site: 0x20), call(0, 7), call(1, 2), call(1, 3), call(1, 7),
                    call(2, 4), call(3, 4), call(3, 5), call(3, 1, site: 0x40)],
            presentationByAddress: [:])
        let model = try XCTUnwrap(CallGraphModel.build(projection: projection, rootFunctionID: functions[1].id,
                                                       depth: 2, metrics: CallGraphPanel.metrics))
        try write("graph-call-graph", size: model.size,
                  CallGraphCanvas(model: model, focusedBinaryName: nil) { _ in })
    }
}
