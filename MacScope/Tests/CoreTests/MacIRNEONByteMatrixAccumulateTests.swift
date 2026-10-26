import XCTest
@testable import MacScope

/// Source-only native tests. Portable proof is a separately authorized fresh witness.
final class MacIRNEONByteMatrixAccumulateTests: XCTestCase {
    func testFixedRolesAndMatrixLayout() throws {
        let mixed = MacIRNEONByteMatrixAccumulate(kind: .usmmla)
        XCTAssertEqual(mixed.firstExtension, .unsigned)
        XCTAssertEqual(mixed.secondExtension, .signed)
        XCTAssertEqual(mixed.laneCount, 4)
        XCTAssertEqual(mixed.termCount, 8)
        XCTAssertEqual(mixed.byteIndices(outputLane: 1, term: 3)?.first, 3)
        XCTAssertEqual(mixed.byteIndices(outputLane: 1, term: 3)?.second, 11)
        XCTAssertEqual(mixed.byteIndices(outputLane: 2, term: 3)?.first, 11)
        XCTAssertEqual(mixed.byteIndices(outputLane: 2, term: 3)?.second, 3)
        XCTAssertNil(mixed.byteIndices(outputLane: 4, term: 0))
        XCTAssertNil(mixed.byteIndices(outputLane: 0, term: 8))
        XCTAssertEqual(Set([mixed, mixed]).count, 1)
    }
}
