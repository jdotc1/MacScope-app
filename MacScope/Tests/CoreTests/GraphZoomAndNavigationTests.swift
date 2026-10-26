import Foundation
import XCTest
import SwiftUI
import LumenUI
@testable import MacScope

/// Graph zoom steps (⌘= / ⌘− / ⌘0) and the navigator following call-graph navigation.
@MainActor
final class GraphZoomAndNavigationTests: XCTestCase {
    func testZoomStepsAreBoundedAndReversible() {
        XCTAssertEqual(GraphZoomControls.step(1, by: 1), 1.25)
        XCTAssertEqual(GraphZoomControls.step(1, by: -1), 0.8)
        XCTAssertEqual(GraphZoomControls.step(GraphZoomControls.step(1, by: 1), by: -1), 1)
        XCTAssertEqual(GraphZoomControls.step(2, by: 1), 2, "clamped at the largest step")
        XCTAssertEqual(GraphZoomControls.step(0.25, by: -1), 0.25, "clamped at the smallest step")
        XCTAssertEqual(GraphZoomControls.step(0.9, by: -1), 0.8, "an off-step zoom moves to the next step")
    }

    func testCallGraphNavigationMovesTheNavigatorSelection() throws {
        let code = Data([0xc0, 0x03, 0x5f, 0xd6]) // ret
        let url = try TinyMachO.make(code: code).write()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try MCPLauncher.makeStore(binaryURL: url)
        let function = try XCTUnwrap(store.snapshot.functions.first)
        store.selectedTool = .project
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: store.focusedImageSlot, address: function.startAddress)))
        store.syncSidebarSelection(functionID: function.id)
        XCTAssertEqual(store.selectedSidebarItemID, "function:\(function.id.uuidString)")
    }

    func testRenderZoomControlsForReview() throws {
        try UIReviewShots.write("graph-zoom-controls", size: CGSize(width: 760, height: 64)) {
            HStack(spacing: Lumen.Space.s4) {
                LumenModeSwitcher(selection: .constant(GraphScope.function), options: GraphScope.allCases, style: .pill) { $0.title }
                Spacer(minLength: Lumen.Space.s4)
                GraphZoomControls(zoom: .constant(0.8))
            }
            .padding(Lumen.Space.s5)
        }
    }

    /// Live check of 8b6f1ac2d: ⌘0 must return the image overview to the zoom it opens at. Zoom is
    /// per scope, every scope opens at `openingZoom`, and resetting restores it for that scope only.
    func testZoomIsPerScopeAndResetsToTheOpeningZoom() {
        var state = GraphZoomState()
        XCTAssertEqual(state.zoom(for: .overview), GraphZoomState.openingZoom)
        state.set(GraphZoomControls.step(1, by: -1), for: .function)
        XCTAssertEqual(state.zoom(for: .overview), GraphZoomState.openingZoom, "the overview opens at its own zoom")
        state.set(0.5, for: .overview)
        state.set(GraphZoomState.openingZoom, for: .overview) // ⌘0
        XCTAssertEqual(state.zoom(for: .overview), GraphZoomState.openingZoom)
        XCTAssertEqual(state.zoom(for: .function), 0.8, "other scopes keep their zoom")
    }
}
