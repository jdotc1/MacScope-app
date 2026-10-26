import Foundation
import XCTest
@testable import MacScope

final class NavigationHistoryTests: XCTestCase {
    func testQualifiedHistoryTokensNeverRebindAcrossResetAndPruning() {
        let session = UUID(), workspace = UUID(), document = UUID(), binary = UUID()
        func location(_ address: UInt64, sessionID: UUID? = nil) -> WorkspaceNavigationLocation {
            .init(sessionID: sessionID ?? session, workspaceID: workspace, documentID: document,
                target: .primary(address), binaryID: binary, editorMode: .graph)
        }
        var history = WorkspaceNavigationHistory(maxEntries: 2)
        history.record(location(0x1000))
        let oldToken = history.panelEntries[0].panelIndex
        history.record(location(0x1004))
        history.record(location(0x1008))
        XCTAssertNil(history.jump(to: oldToken))
        XCTAssertEqual(history.goBack()?.target.address, 0x1004)
        history.reset(seed: location(0x1000, sessionID: UUID()))
        XCTAssertNil(history.jump(to: oldToken))
        XCTAssertNotEqual(history.current?.sessionID, session)
        history.prune { $0.sessionID == session }
        XCTAssertTrue(history.entries.isEmpty)
    }
    // MARK: - Pure history logic

    func testRecordAndCurrent() {
        var history = NavigationHistory()
        XCTAssertNil(history.current)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        history.record(0x1000)
        XCTAssertEqual(history.current, 0x1000)
        history.record(0x2000)
        XCTAssertEqual(history.current, 0x2000)
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }

    func testBackForward() {
        var history = NavigationHistory()
        history.record(0x1000)
        history.record(0x2000)
        history.record(0x3000)
        XCTAssertEqual(history.goBack(), 0x2000)
        XCTAssertEqual(history.goBack(), 0x1000)
        XCTAssertNil(history.goBack()) // at the start
        XCTAssertEqual(history.current, 0x1000)
        XCTAssertEqual(history.goForward(), 0x2000)
        XCTAssertEqual(history.goForward(), 0x3000)
        XCTAssertNil(history.goForward()) // at the end
    }

    func testRecordingAfterBackTruncatesForward() {
        var history = NavigationHistory()
        history.record(0x1000)
        history.record(0x2000)
        history.record(0x3000)
        _ = history.goBack() // now at 0x2000
        history.record(0x9000) // new jump truncates 0x3000
        XCTAssertEqual(history.current, 0x9000)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.locations, [0x1000, 0x2000, 0x9000])
    }

    func testConsecutiveDuplicatesAreIgnored() {
        var history = NavigationHistory()
        history.record(0x1000)
        history.record(0x1000)
        history.record(0x1000)
        XCTAssertEqual(history.locations, [0x1000])
        XCTAssertFalse(history.canGoBack)
    }

    func testCapDropsOldestAndKeepsIndexValid() {
        var history = NavigationHistory(maxEntries: 3)
        history.record(0x1000)
        history.record(0x2000)
        history.record(0x3000)
        history.record(0x4000) // drops 0x1000
        XCTAssertEqual(history.locations, [0x2000, 0x3000, 0x4000])
        XCTAssertEqual(history.current, 0x4000)
        XCTAssertEqual(history.goBack(), 0x3000)
        XCTAssertEqual(history.goBack(), 0x2000)
        XCTAssertNil(history.goBack())
    }

    func testJumpToIndexMovesCursorWithoutTruncating() {
        var history = NavigationHistory()
        history.record(0x1000)
        history.record(0x2000)
        history.record(0x3000)
        // Jump to an OLDER entry: cursor moves, forward history is preserved.
        XCTAssertEqual(history.jump(to: 0), 0x1000)
        XCTAssertEqual(history.current, 0x1000)
        XCTAssertTrue(history.canGoForward)
        XCTAssertFalse(history.canGoBack)
        // Jump forward to the newest: still no truncation, can go back again.
        XCTAssertEqual(history.jump(to: 2), 0x3000)
        XCTAssertEqual(history.current, 0x3000)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.locations, [0x1000, 0x2000, 0x3000])
    }

    func testJumpToOutOfRangeIsNoOp() {
        var history = NavigationHistory()
        history.record(0x1000)
        history.record(0x2000)
        XCTAssertNil(history.jump(to: 9))
        XCTAssertNil(history.jump(to: -1))
        XCTAssertEqual(history.current, 0x2000) // cursor unchanged
    }

    func testPanelEntriesAreNewestFirstWithCurrentFlagged() {
        var history = NavigationHistory()
        history.record(0x1000)
        history.record(0x2000)
        history.record(0x3000)
        _ = history.goBack() // current is now 0x2000 (index 1)

        let entries = history.panelEntries
        XCTAssertEqual(entries.map(\.address), [0x3000, 0x2000, 0x1000]) // newest first
        XCTAssertEqual(entries.map(\.panelIndex), [2, 1, 0]) // original indices preserved
        XCTAssertEqual(entries.filter(\.isCurrent).map(\.address), [0x2000]) // exactly the cursor
    }

    func testResetSeedsOrClears() {
        var history = NavigationHistory()
        history.record(0x1000)
        history.record(0x2000)
        history.reset(seed: 0x5000)
        XCTAssertEqual(history.current, 0x5000)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        history.reset(seed: nil)
        XCTAssertNil(history.current)
        XCTAssertEqual(history.locations, [])
    }

    // MARK: - Store integration

    private func row(_ address: UInt64) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil)
    }

    private func snapshot(_ addresses: [UInt64]) -> WorkspaceSnapshot {
        WorkspaceSnapshot(binaries: [], functions: [], instructions: addresses.map(row), xrefs: [], hexBytes: Data())
    }

    @MainActor
    func testStoreRecordsJumpsAndNavigatesBackForward() {
        let store = WorkspaceStore(workspaceName: "Nav", snapshot: snapshot([0x1000, 0x1004, 0x1008]), engine: AnalysisEngine())
        XCTAssertEqual(store.selectedAddress, 0x1000) // seeded
        XCTAssertFalse(store.canNavigateBack)

        store.selectInstruction(0x1004)
        store.selectInstruction(0x1008)
        XCTAssertTrue(store.canNavigateBack)
        XCTAssertFalse(store.canNavigateForward)

        store.navigateBack()
        XCTAssertEqual(store.selectedAddress, 0x1004)
        XCTAssertTrue(store.canNavigateForward)
        store.navigateBack()
        XCTAssertEqual(store.selectedAddress, 0x1000)
        XCTAssertFalse(store.canNavigateBack)

        store.navigateForward()
        XCTAssertEqual(store.selectedAddress, 0x1004)

        // A fresh jump after going back drops the forward entry (0x1008).
        store.selectInstruction(0x1000)
        XCTAssertFalse(store.canNavigateForward)
    }

    @MainActor
    func testArrowSteppingDoesNotPolluteHistory() {
        let store = WorkspaceStore(workspaceName: "Nav", snapshot: snapshot([0x1000, 0x1004, 0x1008]), engine: AnalysisEngine())
        store.selectInstruction(0x1008) // jump → history [0x1000, 0x1008]
        store.selectAdjacentInstruction(.previous) // arrow-step to 0x1004, NOT recorded
        XCTAssertEqual(store.selectedAddress, 0x1004)
        store.navigateBack() // returns to the prior jump origin, not the stepped-to address
        XCTAssertEqual(store.selectedAddress, 0x1000)
    }

    @MainActor
    func testGraphNodeClickIsRecordedAsAJump() {
        let store = WorkspaceStore(workspaceName: "Nav", snapshot: snapshot([0x1000, 0x1004, 0x1008]), engine: AnalysisEngine())
        // Clicking a graph node is a jump (like a sidebar/xref click), so Back works.
        store.selectGraphNode(id: "node-1", address: 0x1008, functionID: nil)
        XCTAssertEqual(store.selectedAddress, 0x1008)
        XCTAssertTrue(store.canNavigateBack)
        store.navigateBack()
        XCTAssertEqual(store.selectedAddress, 0x1000)
    }

    // MARK: - History panel rows + select-to-jump

    @MainActor
    func testHistoryPanelRowsAreNewestFirstWithCurrentFlagged() {
        let store = WorkspaceStore(workspaceName: "Nav", snapshot: snapshot([0x1000, 0x1004, 0x1008]), engine: AnalysisEngine())
        store.selectInstruction(0x1004)
        store.selectInstruction(0x1008) // history seed→[0x1000, 0x1004, 0x1008], current 0x1008

        let rows = store.navigationHistoryRows
        XCTAssertEqual(rows.map(\.address), [0x1008, 0x1004, 0x1000]) // newest first
        XCTAssertEqual(rows.filter(\.isCurrent).map(\.address), [0x1008]) // exactly the cursor
        XCTAssertEqual(rows.first?.panelIndex, 2) // original index, not display index
    }

    @MainActor
    func testHistoryPanelSelectJumpsAndUpdatesCurrentWithoutTruncating() {
        let store = WorkspaceStore(workspaceName: "Nav", snapshot: snapshot([0x1000, 0x1004, 0x1008]), engine: AnalysisEngine())
        store.selectInstruction(0x1004)
        store.selectInstruction(0x1008) // history [0x1000, 0x1004, 0x1008]

        // Selecting the OLDEST row jumps there and updates the current selection…
        let oldest = store.navigationHistoryRows.last!
        XCTAssertEqual(oldest.address, 0x1000)
        store.navigateToHistoryEntry(at: oldest.panelIndex)
        XCTAssertEqual(store.selectedAddress, 0x1000)
        XCTAssertEqual(store.navigationHistoryRows.filter(\.isCurrent).map(\.address), [0x1000])

        // …without truncating the forward list — the newest row is still reachable.
        XCTAssertTrue(store.canNavigateForward)
        let newest = store.navigationHistoryRows.first!
        XCTAssertEqual(newest.address, 0x1008)
        store.navigateToHistoryEntry(at: newest.panelIndex)
        XCTAssertEqual(store.selectedAddress, 0x1008)
        XCTAssertEqual(store.navigationHistoryRows.map(\.address), [0x1008, 0x1004, 0x1000]) // intact
    }

    @MainActor
    func testHistoryPanelRowResolvesSymbolAndSectionContext() {
        let function = FunctionSummary(id: UUID(), name: "_start", startAddress: 0x1000, endAddress: 0x1010, confidence: 1)
        let section = SectionSummary(
            id: UUID(), name: "__text", address: 0x1000, size: 0x1000,
            fileOffset: 0, isExecutable: true
        )
        var snap = WorkspaceSnapshot(
            binaries: [],
            functions: [function],
            instructions: [row(0x1000), row(0x1008)],
            xrefs: [],
            hexBytes: Data()
        )
        snap.sections = [section]
        let store = WorkspaceStore(workspaceName: "Nav", snapshot: snap, engine: AnalysisEngine())
        store.selectInstruction(0x1008) // inside _start, offset 8

        let rows = store.navigationHistoryRows
        let startRow = rows.first { $0.address == 0x1000 }
        let midRow = rows.first { $0.address == 0x1008 }
        XCTAssertEqual(startRow?.symbolName, "_start") // exact function start uses the name
        XCTAssertEqual(midRow?.symbolName, "_start+0x8") // offset into the function
        XCTAssertEqual(startRow?.sectionName, "__text") // section context resolved
    }
}
