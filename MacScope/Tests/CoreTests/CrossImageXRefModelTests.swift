import XCTest
@testable import MacScope

/// WS-6 Phase A: the cross-image edge model + its transient snapshot field + the frozen resolver
/// signature. The resolver body (and its exhaustive tests) land in Task 2; here we pin the type
/// contract and the byte-identity-preserving "transient, defaults empty" property.
final class CrossImageXRefModelTests: XCTestCase {
    func testCrossImageXRefCodableRoundTrip() throws {
        let edge = CrossImageXRef(id: UUID(), fromSlot: .primary, from: 0x2340,
                                  toSlot: ImageSlot(rawValue: 1), to: 0x5000,
                                  symbol: "_foo", kind: XRefKind.call)
        let data = try JSONEncoder().encode(edge)
        let decoded = try JSONDecoder().decode(CrossImageXRef.self, from: data)
        XCTAssertEqual(decoded, edge)
    }

    func testSnapshotCrossImageXrefsDefaultsEmpty() {
        // A snapshot with no images (and any single-image snapshot) has no cross-image edges. The
        // field is memory-only — it is never encoded into the DB / `.mscope` codecs.
        let snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        XCTAssertTrue(snapshot.crossImageXrefs.isEmpty)
    }

    func testResolverStubReturnsEmpty() {
        let (edges, diagnostics) = CrossImageReferenceResolver.resolve(WorkspaceSnapshot(binaries: [], analysisBySlot: [:]))
        XCTAssertTrue(edges.isEmpty)
        XCTAssertTrue(diagnostics.isEmpty)
    }
}
