import Foundation
import XCTest
@testable import MacScope

/// C2 (vim open-path profile): every selection change re-synced the graph element by rebuilding
/// every node's selection target, ~190 ms per click on vim. The store now reuses the targets while
/// the graph projection is unchanged and rebuilds them when it changes (a rename, a reanalysis).
@MainActor
final class GraphSelectionSyncCacheTests: XCTestCase {
    private static let base: UInt64 = 0x1_0000_0000

    /// 1,000 functions of 40 four-byte blocks each, then one block-less function.
    private func store() -> (WorkspaceStore, [BasicBlockSummary], FunctionSummary) {
        var analysis = ImageAnalysis()
        var functions: [FunctionSummary] = []
        var blocks: [BasicBlockSummary] = []
        var rows: [InstructionRow] = []
        for f in 0..<1_000 {
            let start = Self.base + UInt64(f) * 160
            let function = FunctionSummary(id: UUID(), name: "f\(f)", startAddress: start, endAddress: start + 160, confidence: 1)
            functions.append(function)
            for b in 0..<40 {
                let address = start + UInt64(b) * 4
                blocks.append(BasicBlockSummary(id: UUID(), functionID: function.id, startAddress: address,
                                                endAddress: address + 4, instructionCount: 1))
                rows.append(InstructionRow(address: address, bytes: "1f2003d5", mnemonic: "nop", operands: "",
                                           hasBreakpoint: false, comment: nil))
            }
        }
        let blockless = FunctionSummary(id: UUID(), name: "lonely", startAddress: Self.base + 160_000,
                                        endAddress: Self.base + 160_008, confidence: 1)
        functions.append(blockless)
        rows.append(InstructionRow(address: blockless.startAddress, bytes: "c0035fd6", mnemonic: "ret", operands: "",
                                   hasBreakpoint: false, comment: nil))
        analysis.functions = functions
        analysis.basicBlocks = blocks
        analysis.instructions = rows
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "big", path: "/tmp/big", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis]
        )
        let store = WorkspaceStore(workspaceName: "Big", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        return (store, blocks, blockless)
    }

    func testSelectionChangesReuseTheGraphTargetsUntilTheProjectionChanges() throws {
        let (store, blocks, blockless) = store()
        let slot = store.focusedImageSlot
        // Warm: the first sync builds the targets once.
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slot, address: blocks[0].startAddress)))

        let started = Date()
        for i in stride(from: 0, to: 300 * 97, by: 97) {
            let block = blocks[i % blocks.count]
            XCTAssertTrue(store.selectAddress(ImageAddress(slot: slot, address: block.startAddress)))
            XCTAssertEqual(store.selectedGraphElementID, "image:\(slot.rawValue):block:\(block.id.uuidString)")
        }
        let perSelection = Date().timeIntervalSince(started) / 300
        // One full rebuild of the targets, which every selection used to pay.
        let rebuildStarted = Date()
        _ = FocusedGraphBuilder.selectionTargets(store.focusedGraphProjection)
        let rebuild = Date().timeIntervalSince(rebuildStarted)
        XCTAssertLessThan(perSelection, rebuild,
                          "a selection (\(perSelection) s) should cost less than one target rebuild (\(rebuild) s)")
        print("C2 graph targets: rebuild \(rebuild) s, selection \(perSelection) s")

        // A rename changes the projection, so the block-less function's target picks up the new name.
        let before = try XCTUnwrap(store.graphNodeSelectionTargets.first { $0.functionID == blockless.id })
        XCTAssertEqual(before.title, "lonely")
        store.setCustomName(blockless.startAddress, name: "renamed")
        let after = try XCTUnwrap(store.graphNodeSelectionTargets.first { $0.functionID == blockless.id })
        XCTAssertEqual(after.title, "renamed")
    }
}
