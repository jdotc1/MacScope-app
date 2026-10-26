import XCTest
@testable import MacScope

/// WS-6 Tasks 3 + 4: the store chokepoint (`recomputeCrossImageXrefs`) and the inspector/navigation
/// helpers. The resolver body lands separately (Task 2); these tests exercise the store-side wiring
/// and the pure snapshot-filter helpers with HAND-CONSTRUCTED edges, so they do not depend on it.
@MainActor
final class CrossImageXRefStoreTests: XCTestCase {
    private let slotB = ImageSlot(rawValue: 1)

    private func binary(_ slot: ImageSlot, name: String) -> BinaryImage {
        BinaryImage(id: UUID(), name: name, path: "/tmp/\(name)", kind: "executable",
                    architecture: "arm64", slot: slot)
    }

    /// A two-image snapshot (A=primary, B=slot1), each with a single instruction so the images are
    /// real, and a hand-built cross-image edge A@0x2340 → B@0x5000 for `_foo`.
    private func twoImageSnapshotWithEdge() -> WorkspaceSnapshot {
        var a = ImageAnalysis()
        a.instructions = [
            InstructionRow(address: 0x2340, bytes: "00", mnemonic: "bl", operands: "_foo",
                           hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x2344, bytes: "00", mnemonic: "nop", operands: "",
                           hasBreakpoint: false, comment: nil),
        ]
        var b = ImageAnalysis()
        b.instructions = [InstructionRow(address: 0x5000, bytes: "00", mnemonic: "ret", operands: "",
                                         hasBreakpoint: false, comment: nil)]
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: binary(.primary, name: "a"), analysis: a)
        snapshot.insertImage(binary: binary(slotB, name: "b"), analysis: b)
        snapshot.crossImageXrefs = [
            CrossImageXRef(id: UUID(), fromSlot: .primary, from: 0x2340,
                           toSlot: slotB, to: 0x5000, symbol: "_foo", kind: XRefKind.call)
        ]
        return snapshot
    }

    private func store(_ snapshot: WorkspaceSnapshot) -> WorkspaceStore {
        WorkspaceStore(workspaceName: "WS6", snapshot: snapshot, engine: AnalysisEngine(),
                       autosaveScheduler: nil)
    }

    // MARK: - Task 4: inspector + navigation helpers

    func testInboundCrossImageEntriesForFocusedExportImage() {
        let s = store(twoImageSnapshotWithEdge())
        s.focusImage(slotB)                                   // viewing the exporting image
        XCTAssertEqual(s.crossImageInbound(at: 0x5000).map(\.symbol), ["_foo"])
        XCTAssertTrue(s.crossImageInbound(at: 0x9999).isEmpty)
    }

    func testOutboundCrossImageEntryForFocusedCallerImage() {
        let s = store(twoImageSnapshotWithEdge())
        s.focusImage(.primary)                                // viewing the calling image
        XCTAssertEqual(s.crossImageOutbound(at: 0x2340).map(\.symbol), ["_foo"])
        XCTAssertTrue(s.crossImageOutbound(at: 0x5000).isEmpty, "0x5000 is inbound, not outbound, here")
    }

    func testNavigatingCrossImageEndpointSwitchesFocusAndSelects() {
        let s = store(twoImageSnapshotWithEdge())
        s.focusImage(.primary)
        s.navigateCrossImage(to: slotB, address: 0x5000)
        XCTAssertEqual(s.focusedImageSlot, slotB)
        XCTAssertEqual(s.selectedAddress, 0x5000)
    }

    func testNavigatingToAbsentSlotIsNoOp() {
        let s = store(twoImageSnapshotWithEdge())
        s.focusImage(.primary)
        s.navigateCrossImage(to: ImageSlot(rawValue: 99), address: 0x5000)
        XCTAssertEqual(s.focusedImageSlot, .primary, "no image at slot 99 → focus unchanged")
    }

    func testRetainedCrossImageRowNavigatesUnchangedOutboundAndInboundProjection() throws {
        let s = store(twoImageSnapshotWithEdge())
        let edge = try XCTUnwrap(s.snapshot.crossImageXrefs.first)

        s.focusImage(.primary)
        XCTAssertTrue(s.selectAddress(ImageAddress(slot: .primary, address: 0x2340)))
        let outbound = try XCTUnwrap(s.crossImageXRefNavigationTarget(
            for: edge,
            endpoint: ImageAddress(slot: slotB, address: 0x5000)
        ))
        XCTAssertTrue(s.navigateCrossImage(outbound))
        XCTAssertEqual(s.focusedImageSlot, slotB)
        XCTAssertEqual(s.selectedImageAddress, ImageAddress(slot: slotB, address: 0x5000))

        let inbound = try XCTUnwrap(s.crossImageXRefNavigationTarget(
            for: edge,
            endpoint: ImageAddress(slot: .primary, address: 0x2340)
        ))
        XCTAssertTrue(s.navigateCrossImage(inbound))
        XCTAssertEqual(s.focusedImageSlot, .primary)
        XCTAssertEqual(s.selectedImageAddress, ImageAddress(slot: .primary, address: 0x2340))
    }

    func testRetainedCrossImageRowRejectsDestinationOwnerReplacement() throws {
        let s = store(twoImageSnapshotWithEdge())
        s.focusImage(.primary)
        XCTAssertTrue(s.selectAddress(ImageAddress(slot: .primary, address: 0x2340)))
        let edge = try XCTUnwrap(s.snapshot.crossImageXrefs.first)
        let target = try XCTUnwrap(s.crossImageXRefNavigationTarget(
            for: edge,
            endpoint: ImageAddress(slot: slotB, address: 0x5000)
        ))
        var replacement = s.snapshot
        replacement.binaries = replacement.binaries.map { binary in
            guard binary.slot == slotB else { return binary }
            return BinaryImage(
                id: UUID(),
                name: binary.name,
                path: binary.path,
                kind: binary.kind,
                architecture: binary.architecture,
                originalPathBookmark: binary.originalPathBookmark,
                metadata: binary.metadata,
                selectedSliceIndex: binary.selectedSliceIndex,
                slot: binary.slot
            )
        }
        s.snapshot = replacement

        XCTAssertFalse(s.navigateCrossImage(target))
        XCTAssertEqual(s.focusedImageSlot, .primary)
        XCTAssertEqual(s.selectedImageAddress, ImageAddress(slot: .primary, address: 0x2340))
    }

    func testRetainedCrossImageRowRejectsRemovedEdgeOrChangedOpeningSelection() throws {
        let s = store(twoImageSnapshotWithEdge())
        s.focusImage(.primary)
        XCTAssertTrue(s.selectAddress(ImageAddress(slot: .primary, address: 0x2340)))
        let edge = try XCTUnwrap(s.snapshot.crossImageXrefs.first)
        let target = try XCTUnwrap(s.crossImageXRefNavigationTarget(
            for: edge,
            endpoint: ImageAddress(slot: slotB, address: 0x5000)
        ))

        XCTAssertTrue(s.selectAddress(ImageAddress(slot: .primary, address: 0x2344)))
        XCTAssertFalse(s.navigateCrossImage(target))
        XCTAssertEqual(s.focusedImageSlot, .primary)
        XCTAssertEqual(s.selectedImageAddress, ImageAddress(slot: .primary, address: 0x2344))

        XCTAssertTrue(s.selectAddress(ImageAddress(slot: .primary, address: 0x2340)))
        let refreshedTarget = try XCTUnwrap(s.crossImageXRefNavigationTarget(
            for: edge,
            endpoint: ImageAddress(slot: slotB, address: 0x5000)
        ))
        var withoutEdge = s.snapshot
        withoutEdge.crossImageXrefs = []
        s.snapshot = withoutEdge

        XCTAssertFalse(s.navigateCrossImage(refreshedTarget))
        XCTAssertEqual(s.focusedImageSlot, .primary)
        XCTAssertEqual(s.selectedImageAddress, ImageAddress(slot: .primary, address: 0x2340))
    }

    // MARK: - Task 3: chokepoint wiring

    func testRecomputeIsNotAUserEdit() {
        let s = store(twoImageSnapshotWithEdge())   // a freshly constructed store starts clean
        XCTAssertFalse(s.isDirty)
        s.recomputeCrossImageXrefs()
        XCTAssertFalse(s.isDirty, "re-deriving cross-image edges must not mark the document mutated")
    }

    func testSingleImageSnapshotResolvesToNoCrossEdges() {
        var a = ImageAnalysis()
        a.instructions = [InstructionRow(address: 0x1000, bytes: "00", mnemonic: "ret", operands: "",
                                         hasBreakpoint: false, comment: nil)]
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: binary(.primary, name: "solo"), analysis: a)
        let s = store(snapshot)
        s.recomputeCrossImageXrefs()
        XCTAssertTrue(s.snapshot.crossImageXrefs.isEmpty)
    }
}
