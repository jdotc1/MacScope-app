import XCTest
@testable import MacScope

/// WS-7 Task 4 (store side): the runtime-VA display mode is presentation-only. `.image` renders the
/// image VA; `.runtime` reprojects through the layout. Goto honors the mode; selection stays image-VA.
@MainActor
final class AddressDisplayModeTests: XCTestCase {
    private let slotB = ImageSlot(rawValue: 1)

    private func image(_ slot: ImageSlot, minVA: UInt64, size: UInt64, name: String) -> (BinaryImage, ImageAnalysis) {
        var a = ImageAnalysis()
        a.sections = [SectionSummary(id: UUID(), name: "__text", address: minVA, size: size,
                                     fileOffset: 0, isExecutable: true)]
        let b = BinaryImage(id: UUID(), name: name, path: "/tmp/\(name)", kind: "executable",
                            architecture: "arm64", slot: slot)
        return (b, a)
    }

    private func twoImageStore() -> WorkspaceStore {
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: image(.primary, minVA: 0x1_0000_0000, size: 0x8000, name: "a").0,
                             analysis: image(.primary, minVA: 0x1_0000_0000, size: 0x8000, name: "a").1)
        snapshot.insertImage(binary: image(slotB, minVA: 0x1_0000_0000, size: 0x9000, name: "b").0,
                             analysis: image(slotB, minVA: 0x1_0000_0000, size: 0x9000, name: "b").1)
        let store = WorkspaceStore(workspaceName: "WS7", snapshot: snapshot, engine: AnalysisEngine(),
                                   autosaveScheduler: nil)
        store.recomputeCrossImageXrefs()   // derive imageLayout
        return store
    }

    func testImageModeRendersRawRuntimeModeReprojects() {
        let s = twoImageStore()
        s.focusImage(slotB)
        let bImageVA: UInt64 = 0x1_0000_5000
        XCTAssertEqual(EditorStatusBar.selectedAddressText(for: s), "Go to Address")
        s.selectInstruction(bImageVA)
        s.addressDisplayMode = .image
        XCTAssertEqual(s.displayAddressString(bImageVA), bImageVA.hexAddress)
        XCTAssertEqual(EditorStatusBar.selectedAddressText(for: s), bImageVA.hexAddress)
        s.addressDisplayMode = .runtime
        let expected = s.imageLayout.runtimeVA(ImageAddress(slot: slotB, address: bImageVA)).hexAddress
        XCTAssertEqual(s.displayAddressString(bImageVA), expected)
        XCTAssertEqual(EditorStatusBar.selectedAddressText(for: s), expected)
        XCTAssertNotEqual(s.displayAddressString(bImageVA), bImageVA.hexAddress, "B is slid, so runtime != image")
    }

    func testStatusSymbolNavigationRetainsCapturedImageIdentity() {
        let s = twoImageStore()
        let ownerID = s.snapshot.binary(in: slotB)!.id
        let address: UInt64 = 0x1_0000_5000
        s.focusImage(.primary)
        XCTAssertTrue(EditorStatusBar.navigateToSymbol(address, in: slotB,
                                                       ownerBinaryID: ownerID, store: s))
        XCTAssertEqual(s.focusedImageSlot, slotB)
        XCTAssertEqual(s.selectedAddress, address)

        let replacement = image(slotB, minVA: 0x1_0000_0000, size: 0x9000, name: "replacement")
        var replacedSnapshot = s.snapshot
        replacedSnapshot.removeImage(in: slotB)
        replacedSnapshot.insertImage(binary: replacement.0, analysis: replacement.1)
        s.snapshot = replacedSnapshot
        XCTAssertEqual(s.snapshot.binary(in: slotB)?.id, replacement.0.id)
        XCTAssertEqual(s.snapshot.binaries.filter { $0.slot == slotB }.count, 1)
        s.focusImage(.primary)
        s.selectInstruction(0x1_0000_2000)
        let mode = s.editorMode
        XCTAssertFalse(EditorStatusBar.navigateToSymbol(address, in: slotB,
                                                        ownerBinaryID: ownerID, store: s))
        XCTAssertEqual(s.focusedImageSlot, .primary)
        XCTAssertEqual(s.selectedAddress, 0x1_0000_2000)
        XCTAssertEqual(s.editorMode, mode)
    }

    func testGotoRuntimeResolvesAndFocuses() {
        let s = twoImageStore()
        s.focusImage(.primary)
        s.addressDisplayMode = .runtime
        let bRuntime = s.imageLayout.runtimeVA(ImageAddress(slot: slotB, address: 0x1_0000_5000))
        s.gotoRuntimeOrImage(bRuntime)
        XCTAssertEqual(s.focusedImageSlot, slotB, "runtime goto focuses the resolved image")
        XCTAssertEqual(s.selectedAddress, 0x1_0000_5000, "and selects its image-VA")
    }

    func testGotoImageModeSelectsRaw() {
        let s = twoImageStore()
        s.focusImage(.primary)
        s.addressDisplayMode = .image
        s.gotoRuntimeOrImage(0x1_0000_2000)
        XCTAssertEqual(s.selectedAddress, 0x1_0000_2000)
        XCTAssertEqual(s.focusedImageSlot, .primary, "image-mode goto does not switch focus")
    }

    func testSingleImageRuntimeModeIsIdentity() {
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: image(.primary, minVA: 0x1_0000_0000, size: 0x8000, name: "solo").0,
                             analysis: image(.primary, minVA: 0x1_0000_0000, size: 0x8000, name: "solo").1)
        let s = WorkspaceStore(workspaceName: "solo", snapshot: snapshot, engine: AnalysisEngine(),
                               autosaveScheduler: nil)
        s.recomputeCrossImageXrefs()
        s.addressDisplayMode = .runtime
        XCTAssertEqual(s.displayAddressString(0x1_0000_1000), UInt64(0x1_0000_1000).hexAddress,
                       "primary slide 0 → runtime mode is identity")
    }
}
