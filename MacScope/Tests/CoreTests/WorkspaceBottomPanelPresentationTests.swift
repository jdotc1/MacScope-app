import XCTest
@testable import MacScope

@MainActor
final class WorkspaceBottomPanelPresentationTests: XCTestCase {
    func testCompactAndLiveDefaultsYieldToUserHeightWithoutResizeReset() {
        var state = WorkspaceBottomPanelPresentation()
        let large = DSBottomPanelGeometry(availableHeight: 1_000, dividerHeight: 1)
        let small = DSBottomPanelGeometry(availableHeight: 480, dividerHeight: 1)
        XCTAssertEqual(state.preferredHeight(debuggerExpanded: false), 48)
        XCTAssertEqual(state.preferredHeight(debuggerExpanded: true), 148)

        state[heightIn: large, debuggerExpanded: true] = 210
        XCTAssertEqual(state[heightIn: large, debuggerExpanded: false], 210)
        XCTAssertEqual(state[heightIn: small, debuggerExpanded: true], 119)
        XCTAssertEqual(state[heightIn: large, debuggerExpanded: true], 210)
        XCTAssertEqual(state.debuggerUserHeight, 210)
    }

    func testHideSwitchAndShowRetainSelectedDebuggerTabAndIndependentHeights() {
        var state = WorkspaceBottomPanelPresentation()
        let geometry = DSBottomPanelGeometry(availableHeight: 1_000, dividerHeight: 1)
        state.debuggerTab = .registers
        state[heightIn: geometry, debuggerExpanded: true] = 180
        state.isPresented = false
        state.show(.shell)
        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.preferredHeight(debuggerExpanded: true), 148)
        state[heightIn: geometry, debuggerExpanded: true] = 220
        state.isPresented = false
        state.show(.debugger)
        XCTAssertEqual(state.debuggerTab, .registers)
        XCTAssertEqual(state.preferredHeight(debuggerExpanded: true), 180)
        state.show(.shell)
        XCTAssertEqual(state.preferredHeight(debuggerExpanded: false), 220)
    }

    func testSmallWindowDoesNotEraseVisibilityIntentOrSelectedDeck() {
        var state = WorkspaceBottomPanelPresentation()
        state.show(.shell)
        let small = DSBottomPanelGeometry(availableHeight: 390, dividerHeight: 1)
        let large = DSBottomPanelGeometry(availableHeight: 800, dividerHeight: 1)
        XCTAssertFalse(state[isPresentedIn: small])
        XCTAssertTrue(state.isPresented)
        XCTAssertTrue(state[isPresentedIn: large])
        XCTAssertEqual(state.selectedDeck, .shell)
    }

    func testSidebarCommandsRevealDebuggerAndIgnoreUnrelatedSelections() {
        var state = WorkspaceBottomPanelPresentation()
        state.show(.shell)
        state.isPresented = false
        state.routeSidebarSelection("debug:breakpoints")
        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.selectedDeck, .debugger)
        XCTAssertEqual(state.debuggerTab, .breakpoints)
        state.isPresented = false
        state.routeSidebarSelection("debug:breakpoints")
        XCTAssertTrue(state.isPresented, "Reactivating the same row reveals a hidden panel")
        state.routeSidebarSelection("debug:console")
        XCTAssertEqual(state.debuggerTab, .console)
        state.show(.shell)
        state.isPresented = false
        let unchanged = state
        state.routeSidebarSelection("project:images")
        XCTAssertEqual(state, unchanged)
        state.routeSidebarSelection("debug:session")
        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.selectedDeck, .debugger)
    }

    func testLogicalBreakpointCommandOnlyRevealsItsTargetWindow() {
        let target = makeBottomPanelStore("Target")
        let other = makeBottomPanelStore("Other")
        for store in [target, other] {
            store.bottomPanelPresentation.show(.shell)
            store.bottomPanelPresentation.isPresented = false
        }
        let notification = Notification(
            name: .macScopeShowLogicalBreakpoints,
            userInfo: Notification.commandTargetUserInfo(target)
        )
        WorkspaceBottomPanelRouting.showLogicalBreakpoints(in: target, notification: notification)
        WorkspaceBottomPanelRouting.showLogicalBreakpoints(in: other, notification: notification)
        XCTAssertTrue(target.bottomPanelPresentation.isPresented)
        XCTAssertEqual(target.bottomPanelPresentation.selectedDeck, .debugger)
        XCTAssertEqual(target.bottomPanelPresentation.debuggerTab, .breakpoints)
        XCTAssertEqual(target.selectedSidebarItemID, "debug:breakpoints")
        XCTAssertFalse(other.bottomPanelPresentation.isPresented)
        XCTAssertEqual(other.bottomPanelPresentation.selectedDeck, .shell)

        WorkspaceBottomPanelRouting.showLogicalBreakpoints(
            in: other, notification: Notification(name: .macScopeShowLogicalBreakpoints)
        )
        XCTAssertFalse(other.bottomPanelPresentation.isPresented)
    }
}

@MainActor
private func makeBottomPanelStore(_ name: String) -> WorkspaceStore {
    WorkspaceStore(
        workspaceName: name,
        snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
        engine: AnalysisEngine(),
        autosaveScheduler: nil
    )
}
