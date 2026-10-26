import CoreGraphics
import Foundation
import XCTest
@testable import MacScope

/// The 16 minimised failing graphs from the review/fuzz of `LayeredGraphLayout`
/// (I1F, 2026-10-15, `fixtures/failing-graphs.json`), each asserting the expected behaviour:
/// a clean refusal instead of a trap or runaway allocation, geometry independent of edge order,
/// frames and routes inside `size`, no overlap at fractional sizes, and no avoidable crossing.
final class LayeredGraphLayoutFuzzRegressionTests: XCTestCase {
    /// The harness defaults: 120 × 40 nodes, gaps 32 / 48, margin 24.
    private func metrics(width: CGFloat = 120, height: CGFloat = 40, horizontalGap: CGFloat = 32,
                         layerGap: CGFloat = 48, margin: CGFloat = 24) -> LayeredGraphLayout.Metrics {
        .init(nodeSize: CGSize(width: width, height: height), horizontalGap: horizontalGap,
              layerGap: layerGap, margin: margin)
    }

    private func run(_ nodeCount: Int, entry: Int? = 0, _ pairs: [(Int, Int)], fixedRanks: [Int]? = nil,
                     metrics: LayeredGraphLayout.Metrics? = nil,
                     limits: LayeredGraphLayout.Limits = .init()) -> Result<LayeredGraphLayout, LayeredGraphLayout.Refusal> {
        LayeredGraphLayout.layout(nodeCount: nodeCount, entry: entry,
                                  edges: pairs.map { .init(from: $0.0, to: $0.1) }, fixedRanks: fixedRanks,
                                  metrics: metrics ?? self.metrics(), limits: limits)
    }

    private func assertRefused(_ result: Result<LayeredGraphLayout, LayeredGraphLayout.Refusal>,
                               file: StaticString = #filePath, line: UInt = #line) {
        if case .success = result { XCTFail("expected a refusal", file: file, line: line) }
    }

    private func assertOrderIndependent(_ nodeCount: Int, entry: Int?, _ pairs: [(Int, Int)], fixedRanks: [Int]?,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let forward = try run(nodeCount, entry: entry, pairs, fixedRanks: fixedRanks).get()
        let reversed = try run(nodeCount, entry: entry, pairs.reversed(), fixedRanks: fixedRanks).get()
        XCTAssertEqual(forward.centers, reversed.centers, file: file, line: line)
        XCTAssertEqual(forward.size, reversed.size, file: file, line: line)
        XCTAssertEqual(forward.crossings, reversed.crossings, file: file, line: line)
        // The same route lands on the same edge, under its reversed index.
        let count = pairs.count
        for edge in forward.edges {
            let twin = try XCTUnwrap(reversed.edges.first { $0.index == count - 1 - edge.index })
            XCTAssertEqual(edge.points, twin.points, file: file, line: line)
        }
    }

    private func frames(_ layout: LayeredGraphLayout, _ m: LayeredGraphLayout.Metrics) -> [CGRect] {
        layout.centers.map {
            CGRect(x: $0.x - m.nodeSize.width / 2, y: $0.y - m.nodeSize.height / 2,
                   width: m.nodeSize.width, height: m.nodeSize.height)
        }
    }

    // MARK: - P1

    func testRankSubtractionOverflowIsRefused() {
        assertRefused(run(2, [], fixedRanks: [Int.min, 0]))
    }

    func testLayerCountOverflowIsRefused() {
        assertRefused(run(2, [], fixedRanks: [0, Int.max]))
    }

    func testUnboundedSparseLayersAreRefusedBeforeAllocation() {
        assertRefused(run(2, [], fixedRanks: [0, 1_000_000_000]))
    }

    func testDummyCapIsCheckedBeforeExpansion() {
        var limits = LayeredGraphLayout.Limits()
        limits.maximumLayeredNodes = 3
        limits.maximumLayers = LayeredGraphLayout.Limits.ceiling.maximumLayers
        guard case .failure(.tooManyLayeredNodes) = run(2, [(0, 1)], fixedRanks: [0, 99_999], limits: limits) else {
            return XCTFail("expected the routing-slot cap before any dummy is created")
        }
    }

    func testPermutationDeterminismWithFixedRanks() throws {
        try assertOrderIndependent(3, entry: 2, [(0, 2), (1, 0)], fixedRanks: [0, 2, 2])
    }

    func testPermutationDeterminismWithoutFixedRanks() throws {
        try assertOrderIndependent(4, entry: nil, [(2, 0), (2, 1), (3, 0), (3, 1), (3, 2)], fixedRanks: nil)
    }

    // MARK: - P2

    func testFractionalNodesDoNotOverlap() throws {
        let m = metrics(width: 1.1, horizontalGap: 0)
        let layout = try run(2, [], metrics: m).get()
        let f = frames(layout, m)
        XCTAssertLessThanOrEqual(f[0].maxX, f[1].minX + 1e-9)
    }

    func testFractionalNodeStaysInsideBounds() throws {
        let m = metrics(width: 0.2, margin: 0)
        let layout = try run(1, [], metrics: m).get()
        let frame = frames(layout, m)[0]
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertLessThanOrEqual(frame.maxX, layout.size.width)
    }

    func testSelfLoopRouteStaysInsideBounds() throws {
        let layout = try run(1, [(0, 0)], metrics: metrics(margin: 0)).get()
        for point in layout.edges.flatMap(\.points) {
            XCTAssertLessThanOrEqual(point.x, layout.size.width)
            XCTAssertLessThanOrEqual(point.y, layout.size.height)
        }
    }

    func testWrongFixedRankLengthIsRefused() {
        assertRefused(run(2, [(0, 1), (1, 0)], fixedRanks: []))
    }

    func testLayeredCapAppliesWithoutEdges() {
        var limits = LayeredGraphLayout.Limits()
        limits.maximumLayeredNodes = 0
        assertRefused(run(1, entry: nil, [], limits: limits))
        limits.maximumLayeredNodes = 1
        assertRefused(run(2, [(0, 0), (1, 1)], limits: limits))
    }

    func testNegativeSweepsAreRefused() {
        var limits = LayeredGraphLayout.Limits()
        limits.sweeps = -1
        assertRefused(run(4, [(0, 3), (1, 2)], limits: limits))
    }

    func testUnboundedSweepsAreRefused() {
        var limits = LayeredGraphLayout.Limits()
        limits.sweeps = Int(Int32.max)
        assertRefused(run(4, [(0, 2), (0, 3), (1, 2), (1, 3)], limits: limits))
    }

    func testNonFiniteMetricsAreRefused() {
        assertRefused(run(1, [], metrics: metrics(width: .nan)))
        assertRefused(run(1, [], metrics: metrics(height: .infinity)))
        assertRefused(run(2, [(0, 1)], metrics: metrics(layerGap: -1)))
    }

    // MARK: - P3

    func testInvalidEndpointsAndNegativeCountAreRefused() {
        assertRefused(run(0, entry: nil, [(0, 0)]))
        assertRefused(run(-1, entry: nil, []))
    }

    func testAdjacentTransposeRemovesTheAvoidableCrossing() throws {
        let layout = try run(6, entry: nil, [(0, 3), (1, 5), (2, 3), (2, 4)], fixedRanks: [0, 0, 0, 1, 1, 1]).get()
        XCTAssertEqual(layout.crossings, 0, "Graphviz dot finds an order with no crossing")
    }

    // MARK: - Re-fuzz (I1F2)

    func testRaisedLayerLimitCannotOverflowTheDummySum() {
        var limits = LayeredGraphLayout.Limits()
        limits.maximumLayers = 4_611_686_018_427_387_906
        limits.maximumLayeredNodes = 3
        assertRefused(run(2, [(0, 1), (0, 1)], fixedRanks: [0, 4_611_686_018_427_387_905], limits: limits))
        // Within the ceilings, the cap is still checked before expansion.
        limits.maximumLayers = LayeredGraphLayout.Limits.ceiling.maximumLayers
        guard case .failure(.tooManyLayeredNodes) = run(2, [(0, 1), (0, 1)], fixedRanks: [0, 90_000], limits: limits) else {
            return XCTFail("expected the routing-slot cap")
        }
    }

    func testHugeFiniteMetricsAreRefused() {
        assertRefused(run(1, [], metrics: metrics(width: 1e308, horizontalGap: 1e308)))
    }

    func testBackEdgeTouchesSmallNodes() throws {
        let m = metrics(width: 1)
        let layout = try run(2, [(0, 1)], fixedRanks: [1, 0], metrics: m).get()
        let f = frames(layout, m)
        let route = try XCTUnwrap(layout.edges.first)
        XCTAssertTrue(route.isBackEdge)
        let start = try XCTUnwrap(route.points.first), end = try XCTUnwrap(route.points.last)
        XCTAssertTrue(f[0].insetBy(dx: -1e-9, dy: -1e-9).contains(start), "starts on its source node")
        XCTAssertTrue(f[1].insetBy(dx: -1e-9, dy: -1e-9).contains(end), "ends on its target node")
    }

    func testSidewaysTransposeEscapesTheTiedLocalMinimum() throws {
        let layout = try run(9, entry: nil, [(0, 4), (1, 8), (2, 4), (2, 7), (3, 5)],
                             fixedRanks: [0, 0, 0, 0, 1, 1, 1, 1, 1]).get()
        XCTAssertEqual(layout.crossings, 0, "Graphviz dot finds an order with no crossing")
    }
}
