import Foundation
import XCTest
@testable import MacScope

/// Covers the CFG node multi-select color/group op: `setColorTag(at:color:)` must paint
/// EXACTLY the addresses passed (a graph node multi-selection), as ONE undoable step, and a
/// nil color must clear only those, leaving other overrides intact.
final class GraphNodeColorGroupTests: XCTestCase {
    private func row(_ address: UInt64) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil)
    }

    private func snapshot(_ addresses: [UInt64]) -> WorkspaceSnapshot {
        WorkspaceSnapshot(binaries: [], functions: [], instructions: addresses.map(row), xrefs: [], hexBytes: Data())
    }

    @MainActor
    func testBatchColorAppliesToEveryPassedAddressOnly() {
        let store = WorkspaceStore(workspaceName: "G", snapshot: snapshot([0x1000, 0x1004, 0x1008]), engine: AnalysisEngine())
        store.setColorTag(at: [0x1000, 0x1008], color: .blue)

        XCTAssertEqual(store.snapshot.colorTag(at: 0x1000), .blue)
        XCTAssertEqual(store.snapshot.colorTag(at: 0x1008), .blue)
        // The address NOT in the selection is untouched.
        XCTAssertNil(store.snapshot.colorTag(at: 0x1004))
    }

    @MainActor
    func testBatchColorIsASingleUndoStep() {
        let store = WorkspaceStore(workspaceName: "G", snapshot: snapshot([0x1000, 0x1004, 0x1008]), engine: AnalysisEngine())
        store.setColorTag(at: [0x1000, 0x1004, 0x1008], color: .red)
        XCTAssertEqual(store.snapshot.colorTag(at: 0x1000), .red)
        XCTAssertEqual(store.snapshot.colorTag(at: 0x1008), .red)

        // ONE undo reverts ALL three — painting a group is not three separate steps.
        store.undoManager.undo()
        XCTAssertNil(store.snapshot.colorTag(at: 0x1000))
        XCTAssertNil(store.snapshot.colorTag(at: 0x1004))
        XCTAssertNil(store.snapshot.colorTag(at: 0x1008))

        // …and one redo re-applies all three.
        store.undoManager.redo()
        XCTAssertEqual(store.snapshot.colorTag(at: 0x1000), .red)
        XCTAssertEqual(store.snapshot.colorTag(at: 0x1004), .red)
        XCTAssertEqual(store.snapshot.colorTag(at: 0x1008), .red)
    }

    @MainActor
    func testBatchClearRemovesOnlyTheSelectedColors() {
        let store = WorkspaceStore(workspaceName: "G", snapshot: snapshot([0x1000, 0x1004, 0x1008]), engine: AnalysisEngine())
        store.setColorTag(0x1000, color: .green)
        store.setColorTag(0x1004, color: .green)
        store.setColorTag(0x1008, color: .green)

        store.setColorTag(at: [0x1000, 0x1008], color: nil) // clear two of three
        XCTAssertNil(store.snapshot.colorTag(at: 0x1000))
        XCTAssertNil(store.snapshot.colorTag(at: 0x1008))
        XCTAssertEqual(store.snapshot.colorTag(at: 0x1004), .green) // untouched
    }

    @MainActor
    func testBatchColorPreservesOtherOverridesAtTheSameAddress() {
        let store = WorkspaceStore(workspaceName: "G", snapshot: snapshot([0x1000]), engine: AnalysisEngine())
        store.setCustomName(0x1000, name: "myLabel") // a non-color override already exists

        store.setColorTag(at: [0x1000], color: .purple)
        XCTAssertEqual(store.snapshot.colorTag(at: 0x1000), .purple)
        // The rename survives the color paint — only colorTag changed.
        XCTAssertEqual(store.snapshot.displayName(at: 0x1000, default: "fallback"), "myLabel")
    }

    @MainActor
    func testEmptySelectionIsANoOp() {
        let store = WorkspaceStore(workspaceName: "G", snapshot: snapshot([0x1000]), engine: AnalysisEngine())
        store.setColorTag(at: [], color: .yellow)
        XCTAssertNil(store.snapshot.colorTag(at: 0x1000))
        XCTAssertFalse(store.undoManager.canUndo) // nothing registered
    }
}
