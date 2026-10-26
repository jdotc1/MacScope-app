import Foundation
import XCTest
@testable import MacScope

/// Pure-model coverage for the v22 authoring batch: BytePatch hex parsing/validation,
/// the effective-xref merge (add/suppress), the undefined code-exclusion, and the
/// snapshot bookmark helpers. View-free; the store/scripting/DB layers are covered in
/// their own suites.
final class AuthoringBatch4ModelTests: XCTestCase {

    // MARK: - BytePatch hex parsing + validation

    func testBytePatchParsesSpaceSeparatedHex() {
        XCTAssertEqual(BytePatch.parse(hex: "1f 20 03 d5")?.bytes, [0x1f, 0x20, 0x03, 0xd5])
    }

    func testBytePatchParsesCommaSeparatedHex() {
        XCTAssertEqual(BytePatch.parse(hex: "1f,20,03,d5")?.bytes, [0x1f, 0x20, 0x03, 0xd5])
    }

    func testBytePatchParsesBareEvenRun() {
        XCTAssertEqual(BytePatch.parse(hex: "1f2003d5")?.bytes, [0x1f, 0x20, 0x03, 0xd5])
    }

    func testBytePatchParsesSingleByte() {
        XCTAssertEqual(BytePatch.parse(hex: "90")?.bytes, [0x90])
    }

    func testBytePatchRejectsOddLengthRun() {
        XCTAssertNil(BytePatch.parse(hex: "1f200"))
    }

    func testBytePatchRejectsNonHex() {
        XCTAssertNil(BytePatch.parse(hex: "zz 20"))
        XCTAssertNil(BytePatch.parse(hex: "gg"))
    }

    func testBytePatchRejectsEmptyInput() {
        XCTAssertNil(BytePatch.parse(hex: ""))
        XCTAssertNil(BytePatch.parse(hex: "   "))
    }

    func testBytePatchByteTextRoundTrips() {
        XCTAssertEqual(BytePatch.arm64NOP.byteText, "1f 20 03 d5")
    }

    func testBytePatchIsEmptyForNoBytes() {
        XCTAssertTrue(BytePatch(bytes: []).isEmpty)
        XCTAssertFalse(BytePatch.arm64NOP.isEmpty)
    }

    // MARK: - AddressOverride pruning includes the new fields

    func testEmptyOverrideStaysEmptyWithDefaultedNewFields() {
        XCTAssertTrue(AddressOverride().isEmpty)
        XCTAssertFalse(AddressOverride(isUndefined: true).isEmpty)
        XCTAssertFalse(AddressOverride(patch: BytePatch.arm64NOP).isEmpty)
        // A patch with no bytes prunes like a cleared override.
        XCTAssertTrue(AddressOverride(patch: BytePatch(bytes: [])).isEmpty)
    }

    func testAddressOverrideCodableRoundTripsUndefinedAndPatch() throws {
        let override = AddressOverride(customName: "x", isUndefined: true, patch: BytePatch(bytes: [0xaa, 0xbb]))
        let data = try JSONEncoder().encode(override)
        let decoded = try JSONDecoder().decode(AddressOverride.self, from: data)
        XCTAssertEqual(decoded, override)
        XCTAssertTrue(decoded.isUndefined)
        XCTAssertEqual(decoded.patch?.bytes, [0xaa, 0xbb])
    }

    // MARK: - effectiveXRefs merge (add / suppress)

    private func snapshotWithRecoveredXRefs() -> WorkspaceSnapshot {
        WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [
            XRef(id: UUID(), from: 0x1000, to: 0x2000, kind: XRefKind.call),
            XRef(id: UUID(), from: 0x1004, to: 0x3000, kind: XRefKind.data),
        ], hexBytes: Data())
    }

    func testEffectiveXRefsWithNoEditsReturnsRecoveredVerbatim() {
        let snap = snapshotWithRecoveredXRefs()
        XCTAssertEqual(snap.effectiveXRefs().count, 2)
        XCTAssertEqual(snap.effectiveXRefs(from: 0x1000).count, 1)
    }

    func testSuppressionRemovesRecoveredXRefByEndpoints() {
        var snap = snapshotWithRecoveredXRefs()
        snap.manualXRefs = [ManualXRef(from: 0x1000, to: 0x2000, kind: XRefKind.call, isSuppression: true)]
        XCTAssertTrue(snap.effectiveXRefs(from: 0x1000).isEmpty)
        // The other recovered edge is untouched.
        XCTAssertEqual(snap.effectiveXRefs(from: 0x1004).count, 1)
    }

    func testAddMergesNewXRef() {
        var snap = snapshotWithRecoveredXRefs()
        snap.manualXRefs = [ManualXRef(from: 0x5000, to: 0x6000, kind: XRefKind.call, isSuppression: false)]
        XCTAssertEqual(snap.effectiveXRefs().count, 3)
        XCTAssertEqual(snap.effectiveXRefs(to: 0x6000).first?.from, 0x5000)
    }

    func testAddDoesNotDuplicateAnAlreadyPresentRecoveredXRef() {
        var snap = snapshotWithRecoveredXRefs()
        // Add an endpoint identical to a recovered one — it must not double up.
        snap.manualXRefs = [ManualXRef(from: 0x1000, to: 0x2000, kind: XRefKind.call, isSuppression: false)]
        XCTAssertEqual(snap.effectiveXRefs(from: 0x1000).count, 1)
    }

    func testSuppressionWinsOverAddForSameEndpoint() {
        var snap = snapshotWithRecoveredXRefs()
        snap.manualXRefs = [
            ManualXRef(from: 0x1000, to: 0x2000, kind: XRefKind.call, isSuppression: false),
            ManualXRef(from: 0x1000, to: 0x2000, kind: XRefKind.call, isSuppression: true),
        ]
        XCTAssertTrue(snap.effectiveXRefs(from: 0x1000).isEmpty)
    }

    // MARK: - codeExcludedAddresses unifies data / shape / undefined

    func testCodeExcludedAddressesUnionsDataShapeAndUndefined() {
        var snap = WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        snap.addressOverrides = [
            .primary(0x1000): AddressOverride(isData: true),
            .primary(0x1004): AddressOverride(dataShape: DataShapeOverride(kind: .array, elementCount: 4)),
            .primary(0x1008): AddressOverride(isUndefined: true),
            .primary(0x100C): AddressOverride(customName: "named"), // not excluded
        ]
        let excluded = snap.codeExcludedAddresses(in: .primary)
        XCTAssertEqual(excluded, [0x1000, 0x1004, 0x1008])
    }

    /// Regression: `isUndefined` must sit in the SAME navigation bucket as mark-as-data,
    /// not leak into Next-Code. A mark-as-undefined row keeps its decoded instruction (so
    /// the listing can render `; undefined`), so if `dataMarkedAddresses()` omitted it,
    /// `AddressNavigation.nextCode` would land on it as if it were live code.
    func testDataMarkedAddressesIncludesUndefinedSoNextCodeSkipsIt() {
        var snap = WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        snap.addressOverrides = [
            .primary(0x1004): AddressOverride(isUndefined: true),
        ]
        // The undefined address is bucketed with data...
        XCTAssertTrue(snap.dataMarkedAddresses(in: .primary).contains(0x1004))
        // ...so Next-Code skips it (0x1000 -> 0x1008, not 0x1004)...
        let instructionAddresses: [UInt64] = [0x1000, 0x1004, 0x1008]
        XCTAssertEqual(
            AddressNavigation.nextCode(after: 0x1000,
                                       instructionAddresses: instructionAddresses,
                                       dataAddresses: snap.dataMarkedAddresses(in: .primary)),
            0x1008
        )
        // ...and Next-Data finds it.
        XCTAssertEqual(
            AddressNavigation.nextData(after: 0x1000, dataAddresses: snap.dataMarkedAddresses(in: .primary)),
            0x1004
        )
    }

    // MARK: - Bookmark helpers

    func testSortedBookmarksAreAddressOrdered() {
        var snap = WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        snap.bookmarks = [
            Bookmark(address: 0x2000, name: "b"),
            Bookmark(address: 0x1000, name: "a"),
        ]
        XCTAssertEqual(snap.sortedBookmarks().map(\.address), [0x1000, 0x2000])
        XCTAssertEqual(snap.bookmark(at: 0x1000)?.name, "a")
        XCTAssertNil(snap.bookmark(at: 0x9999))
    }
}
