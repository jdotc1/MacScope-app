import XCTest
@testable import MacScope

/// WS-7 Task 3: the chokepoint now derives `imageLayout` alongside the cross-image edges, and merges
/// symbolic (WS-6) + address (WS-7) edges. Uses the real resolvers; the address resolver is a stub
/// until its body lands (Task 2), so these assert the layout wiring, not address-edge content.
@MainActor
final class RuntimeSlideStoreTests: XCTestCase {
    private let slotB = ImageSlot(rawValue: 1)

    private func image(_ slot: ImageSlot, minVA: UInt64, size: UInt64, name: String) -> (BinaryImage, ImageAnalysis) {
        var a = ImageAnalysis()
        a.sections = [SectionSummary(id: UUID(), name: "__text", address: minVA, size: size,
                                     fileOffset: 0, isExecutable: true)]
        let b = BinaryImage(id: UUID(), name: name, path: "/tmp/\(name)", kind: "executable",
                            architecture: "arm64", slot: slot)
        return (b, a)
    }

    private func store(_ images: [(BinaryImage, ImageAnalysis)]) -> WorkspaceStore {
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        for (b, a) in images { snapshot.insertImage(binary: b, analysis: a) }
        return WorkspaceStore(workspaceName: "WS7", snapshot: snapshot, engine: AnalysisEngine(),
                              autosaveScheduler: nil)
    }

    func testRecomputePopulatesLayoutForBothImages() {
        let s = store([image(.primary, minVA: 0x1_0000_0000, size: 0x8000, name: "a"),
                       image(slotB,   minVA: 0x1_0000_0000, size: 0x9000, name: "b")])
        s.recomputeCrossImageXrefs()
        XCTAssertEqual(s.imageLayout.slide(.primary), 0)
        XCTAssertGreaterThan(s.imageLayout.slide(slotB), 0, "B is slid off the primary")
        XCTAssertNotNil(s.imageLayout.placements[slotB])
    }

    func testSingleImageLayoutIsTrivialAndNoEdges() {
        let s = store([image(.primary, minVA: 0x1_0000_0000, size: 0x8000, name: "solo")])
        s.recomputeCrossImageXrefs()
        XCTAssertEqual(s.imageLayout.slide(.primary), 0)
        XCTAssertTrue(s.snapshot.crossImageXrefs.isEmpty, "one image → no cross-image edges")
        XCTAssertFalse(s.isDirty, "layout/edge derivation is not a user edit")
    }
}
