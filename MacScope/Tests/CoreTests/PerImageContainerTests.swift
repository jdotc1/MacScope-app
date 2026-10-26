import XCTest
@testable import MacScope

/// Characterization + unit tests for the per-image analysis container refactor (Step-4).
///
/// Phase 0 (this initial set) pins behaviors the refactor MUST preserve — they pass on the current
/// flat storage and must still pass once `WorkspaceSnapshot` stores `analysisBySlot`. Later phases
/// append container-specific tests (compat-init routing, writable projections, image-scoped API).
final class PerImageContainerTests: XCTestCase {

    // MARK: - Sample builders (minimal, mirror the existing test-suite constructors)

    private func sampleBinary(slot: ImageSlot = .primary) -> BinaryImage {
        BinaryImage(id: UUID(), name: "fixture", path: "/tmp/fixture",
                    kind: "fixture", architecture: "arm64", slot: slot)
    }

    private func sampleFunction(_ start: UInt64 = 0x1000) -> FunctionSummary {
        FunctionSummary(id: UUID(), name: "fn", startAddress: start, endAddress: start + 4, confidence: 1.0)
    }

    private func sampleBlock(_ start: UInt64 = 0x1000) -> BasicBlockSummary {
        BasicBlockSummary(id: UUID(), functionID: UUID(), startAddress: start, endAddress: start + 4,
                          instructionCount: 1)
    }

    private func sampleDiagnostic() -> AnalysisDiagnostic {
        AnalysisDiagnostic(severity: .error, address: 0x1004, kind: .unresolvedBranchTarget, message: "test")
    }

    // MARK: - ImageAnalysis (Phase 1)

    func testImageAnalysisHoldsAll23DerivedFields() {
        var a = ImageAnalysis()
        a.functions = [sampleFunction()]
        a.basicBlocks = [sampleBlock()]
        a.diagnostics = [sampleDiagnostic()]
        a.imageBytes = Data([0xCF, 0xFA, 0xED, 0xFE])
        a.jumpTables[0x1000] = [0x2000]
        XCTAssertEqual(a.functions.count, 1)
        XCTAssertEqual(a.basicBlocks.count, 1)
        XCTAssertEqual(a.diagnostics.count, 1)
        XCTAssertEqual(a.imageBytes.count, 4)
        XCTAssertEqual(a.jumpTables[0x1000], [0x2000])
        XCTAssertNil(ImageAnalysis().machOMetadata)
    }

    /// The decisive routing test: the compat init must route derived data to
    /// `binaries.first?.slot`, NOT literal `.primary`. The XPC codec fixture builds its sole binary
    /// at `ImageSlot(rawValue: Int.max)`; if the init wrote slot 0 while the shims read
    /// `primarySlot == Int.max`, every derived read would be empty.
    func testCompatInitRoutesToFirstBinarySlotNotLiteralPrimary() {
        let img = sampleBinary(slot: ImageSlot(rawValue: Int.max))
        let snap = WorkspaceSnapshot(binaries: [img],
                                     functions: [sampleFunction()],
                                     instructions: [], xrefs: [], hexBytes: Data())
        XCTAssertEqual(snap.functions.count, 1)
        XCTAssertEqual(snap.analysis(in: ImageSlot(rawValue: Int.max))?.functions.count, 1)
        XCTAssertNil(snap.analysis(in: .primary), "nothing must land in literal .primary")
    }

    /// Flat projections must write through for arrays, dictionaries, `Data`, and optionals — the
    /// whole point of making them writable rather than getter-only.
    func testFlatProjectionWriteThroughForArrayDictDataOptional() {
        var snap = WorkspaceSnapshot(binaries: [sampleBinary()],
                                     functions: [], instructions: [], xrefs: [], hexBytes: Data())
        snap.functions.append(sampleFunction())
        snap.jumpTables[0x1000] = [0x2000]
        snap.imageBytes.append(0xAB)
        snap.machOMetadata = nil
        XCTAssertEqual(snap.functions.count, 1)
        XCTAssertEqual(snap.jumpTables[0x1000], [0x2000])
        XCTAssertEqual(snap.imageBytes.last, 0xAB)
        // replaceAnalysis swaps the whole bucket
        var fresh = ImageAnalysis(); fresh.functions = [sampleFunction(), sampleFunction()]
        snap.replaceAnalysis(fresh, in: snap.primarySlot)
        XCTAssertEqual(snap.functions.count, 2)
    }

    // MARK: - Atomic image ops + invariants (Phase 1.4)

    /// A two-image snapshot with distinct derived data + slot-1 authoring, for remap/invariant tests.
    private func twoImageSnapshot(slots: [Int]) -> WorkspaceSnapshot {
        var byslot: [ImageSlot: ImageAnalysis] = [:]
        var bins: [BinaryImage] = []
        for raw in slots {
            let s = ImageSlot(rawValue: raw)
            bins.append(sampleBinary(slot: s))
            var a = ImageAnalysis(); a.functions = [sampleFunction(UInt64(0x1000 + raw))]
            byslot[s] = a
        }
        return WorkspaceSnapshot(binaries: bins, analysisBySlot: byslot)
    }

    func testRemapMovesBinaryAnalysisBucketAndAuthoringAtomically() {
        var snap = twoImageSnapshot(slots: [0, 1])
        snap.addressOverrides[ImageAddress(slot: ImageSlot(rawValue: 1), address: 0x1001)] =
            AddressOverride(customName: "renamed")
        snap.remapImageSlot(from: ImageSlot(rawValue: 1), to: ImageSlot(rawValue: 5))
        XCTAssertNil(snap.analysis(in: ImageSlot(rawValue: 1)))
        XCTAssertEqual(snap.analysis(in: ImageSlot(rawValue: 5))?.functions.count, 1)
        XCTAssertNotNil(snap.binary(in: ImageSlot(rawValue: 5)))
        XCTAssertNotNil(snap.addressOverrides[ImageAddress(slot: ImageSlot(rawValue: 5), address: 0x1001)])
        XCTAssertNil(snap.addressOverrides[ImageAddress(slot: ImageSlot(rawValue: 1), address: 0x1001)])
        XCTAssertNoThrow(try snap.validateInvariants())
    }

    func testValidateInvariantsRejectsDuplicateSlotsAndOrphanAnalysis() {
        // duplicate slots
        var dup = WorkspaceSnapshot(binaries: [sampleBinary(slot: .primary), sampleBinary(slot: .primary)],
                                    analysisBySlot: [.primary: ImageAnalysis()])
        XCTAssertThrowsError(try dup.validateInvariants()) { err in
            XCTAssertEqual(err as? WorkspaceSnapshotInvariantError, .duplicateSlot(.primary))
        }
        // orphan analysis bucket (a non-primary slot with no binary)
        var orphan = twoImageSnapshot(slots: [0])
        orphan.replaceAnalysis(ImageAnalysis(), in: ImageSlot(rawValue: 9))
        XCTAssertThrowsError(try orphan.validateInvariants()) { err in
            XCTAssertEqual(err as? WorkspaceSnapshotInvariantError, .orphanAnalysis(ImageSlot(rawValue: 9)))
        }
        // binary-less .primary bucket is tolerated
        let fixture = WorkspaceSnapshot(binaries: [], functions: [sampleFunction()],
                                        instructions: [], xrefs: [], hexBytes: Data())
        XCTAssertNoThrow(try fixture.validateInvariants())
    }

    func testInsertAndRemoveImage() {
        var snap = twoImageSnapshot(slots: [0])
        var a = ImageAnalysis(); a.functions = [sampleFunction(0x2000)]
        snap.insertImage(binary: sampleBinary(slot: ImageSlot(rawValue: 3)), analysis: a)
        XCTAssertNotNil(snap.binary(in: ImageSlot(rawValue: 3)))
        XCTAssertEqual(snap.analysis(in: ImageSlot(rawValue: 3))?.functions.count, 1)
        XCTAssertNoThrow(try snap.validateInvariants())
        snap.removeImage(in: ImageSlot(rawValue: 3))
        XCTAssertNil(snap.binary(in: ImageSlot(rawValue: 3)))
        XCTAssertNil(snap.analysis(in: ImageSlot(rawValue: 3)))
    }

    // MARK: - Per-slot render helpers (Phase 4.0)

    /// The `(in slot:)` render-helper overloads must resolve the REQUESTED slot's authoring +
    /// derived data, not the primary — so the focused UI can render a non-primary image while the
    /// default (no slot) still resolves the primary for golden/scripting.
    func testSlotRenderHelpersResolveRequestedSlotNotPrimary() {
        let s1 = ImageSlot(rawValue: 1)
        var b = ImageAnalysis()
        b.xrefs = [XRef(id: UUID(), from: 0x2000, to: 0x2100, kind: "call")]
        var snap = WorkspaceSnapshot(binaries: [sampleBinary(), sampleBinary(slot: s1)],
                                     analysisBySlot: [.primary: ImageAnalysis(), s1: b])
        snap.addressOverrides[ImageAddress(slot: s1, address: 0x2000)] = AddressOverride(customName: "slot1name")

        // displayName resolves the requested slot's authoring
        XCTAssertEqual(snap.displayName(at: 0x2000, in: s1, default: "raw"), "slot1name")
        XCTAssertEqual(snap.displayName(at: 0x2000, default: "raw"), "raw", "primary has no override")
        // effectiveXRefs reads the requested slot's derived xrefs
        XCTAssertEqual(snap.effectiveXRefs(in: s1).count, 1)
        XCTAssertEqual(snap.effectiveXRefs().count, 0, "primary has no xrefs")
    }

    // MARK: - Characterization (must hold before AND after the refactor)

    /// A workspace whose sole binary sits at a NONZERO slot must still expose its derived data
    /// through the flat accessors — because those resolve `primarySlot`, not literal slot 0.
    func testNonzeroFirstBinarySlotExposesDerivedThroughFlatShim() {
        let snap = WorkspaceSnapshot(binaries: [sampleBinary(slot: ImageSlot(rawValue: 7))],
                                     functions: [sampleFunction()],
                                     instructions: [], xrefs: [], hexBytes: Data())
        XCTAssertEqual(snap.primarySlot, ImageSlot(rawValue: 7))
        XCTAssertEqual(snap.functions.count, 1, "flat accessor must resolve the primary slot's derived data")
    }

    /// A binary-less snapshot with nonempty derived data must remain representable (~46 test
    /// fixtures construct `binaries: []` with real functions/instructions).
    func testBinaryLessSnapshotWithNonemptyDerivedIsRepresentable() {
        let snap = WorkspaceSnapshot(binaries: [],
                                     functions: [sampleFunction()],
                                     instructions: [], xrefs: [], hexBytes: Data())
        XCTAssertEqual(snap.functions.count, 1)
        XCTAssertEqual(snap.primarySlot, .primary, "no binary → primary slot")
    }

    /// Production mutates flat derived fields AFTER construction (AnalysisEngine assigns basicBlocks/
    /// diagnostics; the store replaces instructions). Direct assignment and `.append` must write
    /// through — this is why the refactor's flat projections must be writable, not getter-only.
    func testFlatFieldDirectAssignmentAndAppendWriteThrough() {
        var snap = WorkspaceSnapshot(binaries: [sampleBinary()],
                                     functions: [], instructions: [], xrefs: [], hexBytes: Data())
        snap.basicBlocks = [sampleBlock()]                 // mirrors AnalysisEngine.swift:333
        snap.diagnostics.append(sampleDiagnostic())        // mirrors post-construction .append
        snap.imageBytes.append(0xAB)                        // Data mutation
        XCTAssertEqual(snap.basicBlocks.count, 1)
        XCTAssertEqual(snap.diagnostics.count, 1)
        XCTAssertEqual(snap.imageBytes.last, 0xAB)
    }
}
