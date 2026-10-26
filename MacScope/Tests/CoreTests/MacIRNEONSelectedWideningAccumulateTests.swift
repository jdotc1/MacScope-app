import XCTest
@testable import MacScope
final class MacIRNEONSelectedWideningAccumulateTests: XCTestCase {
    func testDistinctWideAccumulatorRoles() throws {
        let d = try XCTUnwrap(MacIRNEONSelectedWideningAccumulate(signedness: .signed, kind: .subtract, narrowBits: 32, sourceHighHalf: true, selectedLane: 3))
        XCTAssertEqual(d.outputLaneBits, 64); XCTAssertEqual(d.laneCount, 2)
        XCTAssertTrue(d.firstSource.signed); XCTAssertTrue(d.firstSource.highHalf)
        XCTAssertEqual(d.coefficient.index, 3); XCTAssertEqual(Set([d, d]).count, 1)
    }
    func testOnlyActualHAndSShapes() {
        XCTAssertNil(MacIRNEONSelectedWideningAccumulate(signedness: .unsigned, kind: .add, narrowBits: 8, sourceHighHalf: false, selectedLane: 0))
        XCTAssertNil(MacIRNEONSelectedWideningAccumulate(signedness: .signed, kind: .subtract, narrowBits: 16, sourceHighHalf: true, selectedLane: 8))
    }
}
