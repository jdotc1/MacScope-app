import XCTest
@testable import MacScope

final class MacIRNEONRoundedShiftTests: XCTestCase {
    func testUnsigned64CarryAndEndpoint() throws {
        let half = try XCTUnwrap(MacIRNEONRoundedShift(kind: .urshr, elementBits: 64, shift: 1, activeBytes: 16))
        let h = half.evaluate(source: (.max, 1))
        XCTAssertEqual(h.low, 0x8000000000000000); XCTAssertEqual(h.high, 1)
        let full = try XCTUnwrap(MacIRNEONRoundedShift(kind: .urshr, elementBits: 64, shift: 64, activeBytes: 16))
        let f = full.evaluate(source: (.max, 0x7fffffffffffffff))
        XCTAssertEqual(f.low, 1); XCTAssertEqual(f.high, 0)
    }
    func testSignedTiesAndQ0Clearing() throws {
        let d = try XCTUnwrap(MacIRNEONRoundedShift(kind: .srshr, elementBits: 8, shift: 1, activeBytes: 8))
        let result = d.evaluate(source: (0x0503fffdfb01007f, .max))
        XCTAssertEqual(result.low, 0x030200fffE010040)
        XCTAssertEqual(result.high, 0)
        let full = try XCTUnwrap(MacIRNEONRoundedShift(kind: .srshr, elementBits: 64, shift: 64, activeBytes: 16))
        let f = full.evaluate(source: (0x8000000000000000, 0x7fffffffffffffff))
        XCTAssertEqual(f.low, 0); XCTAssertEqual(f.high, 0)
    }
    func testReservedAndOutOfRangeDescriptors() {
        XCTAssertNil(MacIRNEONRoundedShift(kind: .srshr, elementBits: 64, shift: 64, activeBytes: 8))
        XCTAssertNil(MacIRNEONRoundedShift(kind: .urshr, elementBits: 8, shift: 0, activeBytes: 16))
        XCTAssertNil(MacIRNEONRoundedShift(kind: .urshr, elementBits: 32, shift: 33, activeBytes: 16))
    }
}
