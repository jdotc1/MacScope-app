import XCTest
@testable import MacScope
final class MacIRNEONFullWidthShiftTests: XCTestCase {
    func testFixedEndpointHasNoArbitraryShiftOrDestinationHalf() throws {
        let d = try XCTUnwrap(MacIRNEONFullWidthShift(narrowBits: 32, sourceHighHalf: true))
        XCTAssertEqual(d.shift, 32); XCTAssertEqual(d.outputLaneBits, 64)
        XCTAssertEqual(d.outputBits, 128); XCTAssertEqual(d.sourceBits, 128)
        XCTAssertEqual(d.laneCount, 2); XCTAssertTrue(d.sourceHighHalf)
        XCTAssertEqual(Set([d, d]).count, 1)
    }
    func testOnlyActualNarrowWidths() {
        XCTAssertNil(MacIRNEONFullWidthShift(narrowBits: 0, sourceHighHalf: false))
        XCTAssertNil(MacIRNEONFullWidthShift(narrowBits: 64, sourceHighHalf: true))
    }
    func testPackingEndpointRemainsExcluded() {
        XCTAssertNil(MacIRNEONPacking(kind: .unsignedWiden, narrowBits: 8, shift: 8))
        XCTAssertNil(MacIRNEONPacking(kind: .signedWiden, narrowBits: 32, shift: 32))
    }
}
