import SwiftUI
import XCTest
@testable import LumenUI

@MainActor
final class LumenEditorLayoutTests: XCTestCase {
    private func tab(_ id: String, pinned: Bool = false, preview: Bool = false) -> LumenDocumentTab {
        LumenDocumentTab(id: id, title: id, systemImage: "doc", isPreview: preview, isPinned: pinned)
    }

    private func layout() -> LumenEditorLayout {
        LumenEditorLayout(panes: [LumenEditorPane(id: "L", tabs: [tab("a"), tab("b"), tab("c")], selection: "b"),
                                  LumenEditorPane(id: "R", tabs: [tab("d")])])
    }

    func testClosingTheSelectedTabShowsItsNeighbor() {
        var l = layout()
        l.close("b", inPane: "L")
        XCTAssertEqual(l.panes[0].tabs.map(\.id), ["a", "c"])
        XCTAssertEqual(l.panes[0].selection, "c")
    }

    func testAnEmptiedPaneClosesUnlessItIsTheLast() {
        var l = layout()
        l.close("d", inPane: "R")
        XCTAssertEqual(l.panes.map(\.id), ["L"])
        l.closeAll(inPane: "L")
        XCTAssertEqual(l.panes.count, 1, "The last pane stays, empty")
        XCTAssertTrue(l.panes[0].tabs.isEmpty)
    }

    func testPinnedTabsComeFirstAndSurviveCloseOthersAndCloseAll() {
        var l = layout()
        l.togglePin("c", inPane: "L")
        XCTAssertEqual(l.panes[0].orderedTabs.map(\.id), ["c", "a", "b"])
        l.closeOthers("a", inPane: "L")
        XCTAssertEqual(l.panes[0].orderedTabs.map(\.id), ["c", "a"])
        l.closeAll(inPane: "L")
        XCTAssertEqual(l.panes[0].tabs.map(\.id), ["c"])
        XCTAssertEqual(l.panes[0].selection, "c")
    }

    func testMovingATabAcrossPanesFocusesItAndClosesTheEmptiedPane() {
        var l = layout()
        l.move("d", toPane: "L", at: 1)
        XCTAssertEqual(l.panes.map(\.id), ["L"])
        XCTAssertEqual(l.panes[0].tabs.map(\.id), ["a", "d", "b", "c"])
        XCTAssertEqual(l.panes[0].selection, "d")
        l.move("a", toPane: "L", at: 4)
        XCTAssertEqual(l.panes[0].tabs.map(\.id), ["d", "b", "c", "a"], "Past the end moves to the end")
    }

    func testSplittingDuplicatesTheTabBesideItsPane() {
        var l = layout()
        let id = l.split("b", fromPane: "L", edge: .trailing)
        XCTAssertEqual(l.panes.map(\.id), ["L", id!, "R"])
        XCTAssertEqual(l.panes[1].tabs.map(\.id), ["b"])
        XCTAssertEqual(l.focusedPaneID, id)
        l.split("a", fromPane: "L", edge: .leading)
        XCTAssertEqual(l.panes.count, 4)
        XCTAssertEqual(l.panes[0].tabs.map(\.id), ["a"])
    }

    func testAPreviewTabIsReplacedByTheNextPreview() {
        var l = layout()
        l.open(tab("p1", preview: true))
        l.open(tab("p2", preview: true))
        XCTAssertEqual(l.panes[0].tabs.map(\.id), ["a", "b", "c", "p2"])
        l.open(tab("a"))
        XCTAssertEqual(l.panes[0].selection, "a")
    }

    func testPaneWidthsHonorTheMinimum() {
        let widths = LumenSplitEditor<EmptyView>.widths(for: [1, 6], total: 700, minimum: 200)
        XCTAssertEqual(widths[0], 200, accuracy: 0.5)
        XCTAssertEqual(widths.reduce(0, +), 700, accuracy: 0.5)
    }

    // Every bulk close asks the veto, once per tab, and keeps refused tabs.
    func testBulkClosesAskTheVetoAndKeepRefusedTabs() {
        var l = layout()
        var asked: [String] = []
        l.closeOthers("a", inPane: "L") { asked.append($0.id); return $0.id != "b" }
        XCTAssertEqual(asked, ["b", "c"])
        XCTAssertEqual(l.panes[0].tabs.map(\.id), ["a", "b"], "Close Others keeps the refused tab")
        asked = []
        l.closeAll(inPane: "L") { asked.append($0.id); return false }
        XCTAssertEqual(asked, ["a", "b"])
        XCTAssertEqual(l.panes[0].tabs.map(\.id), ["a", "b"], "Close All closes nothing the veto refuses")
        l.closePane("L") { $0.id != "b" }
        XCTAssertEqual(l.panes.map(\.id), ["L", "R"], "Close Split leaves a pane holding a refused tab")
        XCTAssertEqual(l.panes[0].tabs.map(\.id), ["b"])
        XCTAssertEqual(l.panes[0].selection, "b")
        l.closePane("L") { _ in true }
        XCTAssertEqual(l.panes.map(\.id), ["R"], "Close Split closes the pane once every tab may close")
    }

    // After Duplicate in Split the same tab is in two panes; a drag
    // names its pane, so the move takes the tab from there, not the first pane holding it.
    func testMovingADuplicatedTabTakesItFromItsOwnPane() throws {
        var l = LumenEditorLayout(panes: [LumenEditorPane(id: "L", tabs: [tab("a")]), LumenEditorPane(id: "X", tabs: [tab("x")])])
        let right = try XCTUnwrap(l.split("a", fromPane: "L", edge: .trailing))
        l.move("a", fromPane: right, toPane: "X", at: 1)
        XCTAssertEqual(l.panes.map(\.id), ["L", "X"], "The emptied right pane closes, not the left")
        XCTAssertEqual(l.panes[0].tabs.map(\.id), ["a"])
        XCTAssertEqual(l.panes[1].tabs.map(\.id), ["x", "a"])
        // Into a pane that already shows it: the tab moves there once, never twice.
        l.move("a", fromPane: "X", toPane: "L", at: 0)
        XCTAssertEqual(l.panes.map(\.id), ["L", "X"])
        XCTAssertEqual(l.panes[0].tabs.map(\.id), ["a"])
        XCTAssertEqual(l.panes[1].tabs.map(\.id), ["x"])
    }

    func testDraggedTabPayloadsCarryTheirPane() throws {
        let fromPane = try XCTUnwrap(lumenTabDragContents(lumenTabDragPayload("doc:1", pane: "P")))
        XCTAssertEqual(fromPane.tabID, "doc:1")
        XCTAssertEqual(fromPane.pane, "P")
        let plain = try XCTUnwrap(lumenTabDragContents(lumenTabDragPayload("doc:1", pane: nil)))
        XCTAssertEqual(plain.tabID, "doc:1")
        XCTAssertNil(plain.pane)
        XCTAssertNil(lumenTabDragContents("some text"))
    }

    // The grips are drawn whatever is collapsed, so the minimum counts them.
    func testStackedSidebarMinimumCoversHeadersAndGrips() {
        XCTAssertEqual(LumenStackedSidebar.chromeHeight(paneCount: 3, headerHeight: 36), 3 * 36 + 2 * 7)
        XCTAssertEqual(LumenStackedSidebar.chromeHeight(paneCount: 1, headerHeight: 36), 36)
        XCTAssertEqual(LumenStackedSidebar.chromeHeight(paneCount: 0, headerHeight: 36), 0)
    }
}
