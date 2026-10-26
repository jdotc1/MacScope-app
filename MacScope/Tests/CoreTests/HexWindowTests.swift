import XCTest
@testable import MacScope

/// MS-10: the hex pane shows a window over the FULL persisted slice that follows the selection,
/// not only the first 4 KiB. Offsets the pane, its edit model and its callbacks use are
/// window-relative; mappings are clipped and shifted so they stay exact.
@MainActor
final class HexWindowTests: XCTestCase {
    private let base: UInt64 = 0x1000_0000
    private let sliceSize = 200_000

    private func makeStore(sliceSize: Int? = nil) -> WorkspaceStore {
        let size = sliceSize ?? self.sliceSize
        let bytes = Data((0..<size).map { UInt8($0 % 251) })
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "big", path: "", kind: "fixture", architecture: "arm64")],
            functions: [],
            instructions: [InstructionRow(address: base, bytes: "00000000", mnemonic: "udf", operands: "#0",
                                          hasBreakpoint: false, comment: nil)],
            xrefs: [],
            hexBytes: Data(bytes.prefix(WorkspaceSnapshot.hexViewByteWindow)),
            sections: [SectionSummary(id: UUID(), name: "__text", address: base, size: UInt64(size),
                                      fileOffset: 0, isExecutable: true)],
            imageBytes: bytes
        )
        return WorkspaceStore(workspaceName: "hex window", snapshot: snapshot,
                              engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    func testWindowStartsAtTheSliceStartAndIsLargerThanTheOldPrefix() {
        let store = makeStore()
        let range = store.hexWindowRange()
        XCTAssertEqual(range, 0..<WorkspaceStore.hexPaneWindowByteCount)
        XCTAssertGreaterThan(range.count, WorkspaceSnapshot.hexViewByteWindow)
        XCTAssertEqual(store.patchedHexWindow().bytes.count, range.count)
        XCTAssertEqual(store.hexSliceByteCount, sliceSize)
    }

    func testSelectionPastTheFirstWindowMovesTheWindowAndShowsItsBytes() throws {
        let store = makeStore()
        let target: UInt64 = 150_000
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: store.focusedImageSlot, address: base + target)))
        let range = store.hexWindowRange()
        XCTAssertTrue(range.contains(Int(target)), "\(range)")
        XCTAssertEqual(range.lowerBound % AppEditorChrome.hexBytesPerRow, 0)
        let bytes = store.patchedHexWindow().bytes
        let offset = Int(target) - range.lowerBound
        XCTAssertEqual(bytes[bytes.startIndex + offset], UInt8(Int(target) % 251))
        // Mappings are window-relative and still name the true address.
        let mapping = try XCTUnwrap(store.hexWindowMappings.first)
        XCTAssertEqual(mapping.fileOffset, 0)
        XCTAssertEqual(mapping.virtualAddress, base + UInt64(range.lowerBound))
        XCTAssertEqual(mapping.size, UInt64(range.count))
        XCTAssertEqual(
            FileAddressMapping.resolvedVirtualAddress(forFileOffset: UInt64(offset), in: store.hexWindowMappings),
            base + target
        )
    }

    func testWindowStaysPutWhileTheSelectionMovesInsideIt() {
        let store = makeStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: store.focusedImageSlot, address: base + 150_000)))
        let first = store.hexWindowRange()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: store.focusedImageSlot, address: base + 150_400)))
        XCTAssertEqual(store.hexWindowRange(), first)
        // Near the window's edge it re-centres.
        let nearEdge = UInt64(first.upperBound - 10)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: store.focusedImageSlot, address: base + nearEdge)))
        let moved = store.hexWindowRange()
        XCTAssertNotEqual(moved, first)
        XCTAssertTrue(moved.contains(Int(nearEdge)))
    }

    func testEditInAMovedWindowPatchesTheSliceAddressAndHighlightsTheWindowCell() {
        let store = makeStore()
        let target: UInt64 = 150_000
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: store.focusedImageSlot, address: base + target)))
        let range = store.hexWindowRange()
        let offset = Int(target) - range.lowerBound
        store.withSynchronousReanalysis {
            XCTAssertTrue(store.applyHexByteEdit(offset: offset, value: 0xAB))
        }
        XCTAssertEqual(store.snapshot.patches(in: store.focusedImageSlot)[base + target]?.bytes, [0xAB])
        let window = store.patchedHexWindow()
        XCTAssertEqual(store.hexWindowRange(), range)
        XCTAssertEqual(window.bytes[window.bytes.startIndex + offset], 0xAB)
        XCTAssertEqual(window.patchedOffsets, [offset])
    }

    func testSmallSliceShowsWhole() {
        let store = makeStore(sliceSize: 6_000)
        XCTAssertEqual(store.hexWindowRange(), 0..<6_000)
        XCTAssertEqual(store.patchedHexWindow().bytes.count, 6_000)
    }

    func testRebasedMappingsClipAndShiftEachRun() {
        let mappings = [
            FileAddressMapping(fileOffset: 0, size: 100, virtualAddress: 0x1000, sectionName: "a"),
            FileAddressMapping(fileOffset: 100, size: 100, virtualAddress: 0x5000, sectionName: "b"),
            FileAddressMapping(fileOffset: 300, size: 10, virtualAddress: 0x9000, sectionName: "c"),
        ]
        let rebased = WorkspaceStore.rebasedMappings(mappings, to: 50..<150)
        XCTAssertEqual(rebased, [
            FileAddressMapping(fileOffset: 0, size: 50, virtualAddress: 0x1032, sectionName: "a"),
            FileAddressMapping(fileOffset: 50, size: 50, virtualAddress: 0x5000, sectionName: "b"),
        ])
    }
}
