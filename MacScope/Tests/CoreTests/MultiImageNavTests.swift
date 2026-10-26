import XCTest
@testable import MacScope

/// WS-8 Phase A: the slot-aware navigation core. `goToAddress(_:in:)` resolves against a specific
/// image (not the primary projection) and focuses it; `imagesContaining(_:)` is the collision
/// resolver behind Go-to disambiguation. Single-image workspaces behave exactly as before.
@MainActor
final class MultiImageNavTests: XCTestCase {
    private let slotB = ImageSlot(rawValue: 1)

    private func image(_ slot: ImageSlot, name: String, addrs: [UInt64]) -> (BinaryImage, ImageAnalysis) {
        var a = ImageAnalysis()
        a.instructions = addrs.map { InstructionRow(address: $0, bytes: "00", mnemonic: "nop",
                                                    operands: "", hasBreakpoint: false, comment: nil) }
        // A section TIGHT to the instruction span (min…max+4) so containment reflects the actual
        // range — a wide fixed-size section would make disjoint images falsely overlap.
        let lo = addrs.min() ?? 0, hi = addrs.max() ?? 0
        a.sections = [SectionSummary(id: UUID(), name: "__text", address: lo,
                                     size: (hi - lo) + 4, fileOffset: 0, isExecutable: true)]
        let b = BinaryImage(id: UUID(), name: name, path: "/tmp/\(name)", kind: "executable",
                            architecture: "arm64", slot: slot)
        return (b, a)
    }

    private func store(_ images: [(BinaryImage, ImageAnalysis)]) -> WorkspaceStore {
        var s = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        for (b, a) in images { s.insertImage(binary: b, analysis: a) }
        return WorkspaceStore(workspaceName: "WS8", snapshot: s, engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    func testImagesContainingFindsCollisionsAscending() {
        // a spans [0x1000..0x1900], b spans [0x1900..0x2800] — overlapping only at the collision VA
        // 0x1900, with 0x1000 unique to a and 0x2800 unique to b.
        let s = store([image(.primary, name: "a", addrs: [0x1000, 0x1900]),
                       image(slotB, name: "b", addrs: [0x1900, 0x2800])])
        XCTAssertEqual(s.imagesContaining(0x1900), [.primary, slotB])  // colliding VA in both
        XCTAssertEqual(s.imagesContaining(0x1000), [.primary])          // only a
        XCTAssertEqual(s.imagesContaining(0x2800), [slotB])            // only b
        XCTAssertTrue(s.imagesContaining(0x9_9999).isEmpty)           // neither
    }

    func testHistoryReplaysExactImageOwnerAndEditorModeAcrossCollidingAddresses() {
        let a = image(.primary, name: "a", addrs: [0x1000, 0x1004])
        let b = image(slotB, name: "b", addrs: [0x1000, 0x1004])
        let s = store([a, b])
        s.editorMode = .pseudocode
        s.selectInstruction(0x1004)
        s.focusImage(slotB)
        s.editorMode = .hex
        s.selectInstruction(0x1004)
        XCTAssertEqual(s.navigationHistoryRows.count, 3)
        XCTAssertEqual(s.navigationHistoryRows.first?.imageName, "b")
        s.navigateBack()
        XCTAssertEqual(s.focusedImageSlot, .primary)
        XCTAssertEqual(s.selectedImageAddress, .primary(0x1004))
        XCTAssertEqual(s.editorMode, .pseudocode)
        s.navigateForward()
        XCTAssertEqual(s.focusedImageSlot, slotB)
        XCTAssertEqual(s.selectedImageAddress, ImageAddress(slot: slotB, address: 0x1004))
        XCTAssertEqual(s.editorMode, .hex)
    }

    func testHistoryPrunesOnlyReplacedOwnerAndRejectsRetainedPanelToken() {
        let a = image(.primary, name: "a", addrs: [0x1000, 0x1004])
        let b = image(slotB, name: "b", addrs: [0x1000, 0x1004])
        let s = store([a, b])
        s.selectInstruction(0x1004)
        s.focusImage(slotB)
        s.selectInstruction(0x1004)
        let oldBToken = s.navigationHistoryRows.first!.panelIndex
        let replacement = image(slotB, name: "replacement", addrs: [0x1000, 0x1004])
        s.snapshot.binaries[1] = replacement.0
        s.snapshot.replaceAnalysis(replacement.1, in: slotB)
        XCTAssertEqual(s.navigationHistoryRows.count, 2)
        XCTAssertTrue(s.navigationHistoryRows.allSatisfy { $0.imageName == "a" })
        let before = s.selectedImageAddress
        s.navigateToHistoryEntry(at: oldBToken)
        XCTAssertEqual(s.selectedImageAddress, before)
        XCTAssertEqual(s.focusedImageSlot, slotB)
        s.selectInstruction(0x1000)
        s.navigateBack()
        XCTAssertEqual(s.focusedImageSlot, .primary)
        XCTAssertEqual(s.selectedAddress, 0x1004)
    }

    func testGoToAddressInSlotFocusesAndSelects() {
        let s = store([image(.primary, name: "a", addrs: [0x374]),
                       image(slotB, name: "b", addrs: [0x374])])
        s.focusImage(.primary)
        XCTAssertTrue(s.goToAddress(0x374, in: slotB))
        XCTAssertEqual(s.focusedImageSlot, slotB, "navigation focuses the target image")
        XCTAssertEqual(s.selectedAddress, 0x374, "focus resets selection, so it must be set AFTER focusing")
    }

    func testGoToAddressInSlotReturnsFalseForAbsentAddress() {
        let s = store([image(.primary, name: "a", addrs: [0x374])])
        XCTAssertFalse(s.goToAddress(0x9_9999, in: .primary))
    }

    func testGoToAddressInAbsentSlotReturnsFalse() {
        let s = store([image(.primary, name: "a", addrs: [0x374])])
        XCTAssertFalse(s.goToAddress(0x374, in: slotB), "no image at slot B → no-op")
    }

    func testFocusedWrapperTargetsFocusedSlot() {
        let s = store([image(.primary, name: "a", addrs: [0x100]),
                       image(slotB, name: "b", addrs: [0x200])])
        s.focusImage(slotB)
        XCTAssertTrue(s.goToAddress(0x200))       // existing signature → focused slot (b)
        XCTAssertEqual(s.selectedAddress, 0x200)
        XCTAssertFalse(s.goToAddress(0x100), "0x100 is in a, not the focused image b → false")
    }

    func testFindNextStepsIntoTheHitsImage() {
        let s = store([image(.primary, name: "a", addrs: [0x1000]),
                       image(slotB, name: "b", addrs: [0x2000])])
        s.focusImage(.primary)
        s.seedSearchCursor([
            BinarySearchResult(address: 0x1000, kind: .instruction, preview: "nop", imageSlot: .primary),
            BinarySearchResult(address: 0x2000, kind: .instruction, preview: "nop", imageSlot: slotB),
        ])
        s.findNext()                                   // → first hit (a, 0x1000)
        XCTAssertEqual(s.focusedImageSlot, .primary)
        XCTAssertEqual(s.selectedAddress, 0x1000)
        s.findNext()                                   // → second hit (b, 0x2000)
        XCTAssertEqual(s.focusedImageSlot, slotB, "stepping into a sibling image's hit focuses that image")
        XCTAssertEqual(s.selectedAddress, 0x2000)
    }

    func testNavigateToReferenceEditorModeHonorsFocusedImage() {
        // b has an instruction at 0x200 that the PRIMARY image does not; following a reference to it
        // while b is focused must land in disassembly, not hex.
        let s = store([image(.primary, name: "a", addrs: [0x100]),
                       image(slotB, name: "b", addrs: [0x200])])
        s.focusImage(slotB)
        s.navigateToReference(0x200)
        XCTAssertEqual(s.editorMode, .disassembly, "0x200 is an instruction in the focused image b")
        XCTAssertEqual(s.selectedAddress, 0x200)
    }

    func testFindCursorSeedUsesTheSelectedImageAtCollidingAddresses() {
        let s = store([image(.primary, name: "a", addrs: [0x1000, 0x1004]),
                       image(slotB, name: "b", addrs: [0x1000, 0x1004])])
        XCTAssertTrue(s.goToAddress(0x1000, in: slotB))
        s.seedSearchCursor([
            BinarySearchResult(address: 0x1000, kind: .instruction, preview: "nop", imageSlot: .primary),
            BinarySearchResult(address: 0x1000, kind: .instruction, preview: "nop", imageSlot: slotB),
            BinarySearchResult(address: 0x1004, kind: .instruction, preview: "nop", imageSlot: slotB),
        ], selecting: s.selectedImageAddress)

        XCTAssertEqual(s.searchCursor?.current?.imageSlot, slotB)
        XCTAssertEqual(s.searchCursor?.positionLabel, "2 of 3")
        s.perform(.findNext)
        XCTAssertEqual(s.selectedImageAddress, ImageAddress(slot: slotB, address: 0x1004))
        s.perform(.findPrevious)
        XCTAssertEqual(s.selectedImageAddress, ImageAddress(slot: slotB, address: 0x1000))
    }

    private func xrefStore(primaryReferrers: [UInt64], secondaryReferrers: [UInt64]) -> WorkspaceStore {
        // Both images map all candidate VAs: a wrong-image lookup must fail on the
        // selected destination, rather than being hidden by an out-of-range guard.
        let addresses: [UInt64] = [0x1000, 0x1100, 0x1200, 0x1300]
        var a = image(.primary, name: "a", addrs: addresses)
        var b = image(slotB, name: "b", addrs: addresses)
        a.1.xrefs = primaryReferrers.map {
            XRef(id: UUID(), from: $0, to: 0x1000, kind: XRefKind.call)
        }
        b.1.xrefs = secondaryReferrers.map {
            XRef(id: UUID(), from: $0, to: 0x1000, kind: XRefKind.call)
        }
        return store([a, b])
    }

    func testXRefOrbitIsRetiredWhenSnapshotRemovesItsReferrers() throws {
        let s = xrefStore(primaryReferrers: [], secondaryReferrers: [0x1200, 0x1300])
        XCTAssertTrue(s.goToAddress(0x1000, in: slotB))
        s.perform(.nextXRef)
        XCTAssertEqual(s.selectedAddress, 0x1200)
        XCTAssertNotNil(s.xrefCursor)
        var next = s.snapshot
        var analysis = try XCTUnwrap(next.analysis(in: slotB))
        analysis.xrefs = []
        next.replaceAnalysis(analysis, in: slotB)
        s.snapshot = next
        XCTAssertNil(s.xrefCursor)
        XCTAssertFalse(s.isEnabled(.nextXRef))
        s.perform(.nextXRef)
        XCTAssertEqual(s.selectedAddress, 0x1200)
    }

    func testSearchAndXRefCursorsDoNotSurviveSameSlotOwnerReplacement() {
        let s = xrefStore(primaryReferrers: [], secondaryReferrers: [0x1200, 0x1300])
        XCTAssertTrue(s.goToAddress(0x1000, in: slotB))
        s.perform(.nextXRef)
        s.seedSearchCursor([
            BinarySearchResult(address: 0x1200, kind: .instruction, preview: "old owner", imageSlot: slotB),
            BinarySearchResult(address: 0x1300, kind: .instruction, preview: "old owner", imageSlot: slotB),
        ], selecting: s.selectedImageAddress)
        XCTAssertNotNil(s.searchCursor)
        XCTAssertNotNil(s.xrefCursor)
        let replacement = image(slotB, name: "replacement", addrs: [0x1000, 0x1200, 0x1300])
        var next = s.snapshot
        next.removeImage(in: slotB)
        next.insertImage(binary: replacement.0, analysis: replacement.1)
        s.snapshot = next
        XCTAssertNil(s.searchCursor)
        XCTAssertNil(s.xrefCursor)
        XCTAssertFalse(s.isEnabled(.findNext))
    }

    func testXRefCommandsUseFocusedReferrersAndRetireTheOrbitOnFocusChange() {
        let s = xrefStore(primaryReferrers: [0x1100], secondaryReferrers: [0x1200, 0x1300])
        XCTAssertTrue(s.goToAddress(0x1000, in: slotB))
        XCTAssertTrue(s.isEnabled(.nextXRef))
        s.perform(.nextXRef)
        XCTAssertEqual(s.selectedImageAddress, ImageAddress(slot: slotB, address: 0x1200))
        s.perform(.nextXRef)
        XCTAssertEqual(s.selectedImageAddress, ImageAddress(slot: slotB, address: 0x1300))
        s.perform(.previousXRef)
        XCTAssertEqual(s.selectedImageAddress, ImageAddress(slot: slotB, address: 0x1200))

        XCTAssertTrue(s.goToAddress(0x1000, in: .primary))
        s.perform(.nextXRef)
        XCTAssertEqual(s.selectedImageAddress, .primary(0x1100))
    }

    func testXRefCommandsAreEnabledWhenOnlyFocusedImageHasReferrers() {
        let s = xrefStore(primaryReferrers: [], secondaryReferrers: [0x1200])
        XCTAssertTrue(s.goToAddress(0x1000, in: slotB))
        XCTAssertTrue(s.isEnabled(.nextXRef))
        XCTAssertTrue(s.isEnabled(.previousXRef))
        s.perform(.nextXRef)
        XCTAssertEqual(s.selectedImageAddress, ImageAddress(slot: slotB, address: 0x1200))
    }

    func testXRefCommandsAreDisabledWhenOnlyPrimaryImageHasReferrers() {
        let s = xrefStore(primaryReferrers: [0x1100], secondaryReferrers: [])
        XCTAssertTrue(s.goToAddress(0x1000, in: slotB))
        XCTAssertFalse(s.isEnabled(.nextXRef))
        XCTAssertFalse(s.isEnabled(.previousXRef))
        s.perform(.nextXRef)
        XCTAssertEqual(s.selectedImageAddress, ImageAddress(slot: slotB, address: 0x1000))
    }
}
