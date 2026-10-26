import XCTest
@testable import MacScope

final class MacIRNEONByteDotProductTests: XCTestCase {
    func testSignedUnsignedAndOldAccumulatorWrap() throws {
        let signed = try XCTUnwrap(MacIRNEONByteDotProduct(kind: .sdot, activeBytes: 8))
        let unsigned = try XCTUnwrap(MacIRNEONByteDotProduct(kind: .udot, activeBytes: 8))
        let a: (low: UInt64, high: UInt64) = (0x01010101ffffffff, .max)
        let b: (low: UInt64, high: UInt64) = (0x0202020201010101, .max)
        let old: (low: UInt64, high: UInt64) = (0xfffffffc00000002, .max)
        let s = signed.evaluate(first: a, second: b, old: old)
        let u = unsigned.evaluate(first: a, second: b, old: old)
        XCTAssertEqual(s.low, 0x00000004fffffffe)
        XCTAssertEqual(u.low, 0x00000004000003fe)
        XCTAssertEqual(s.high, 0); XCTAssertEqual(u.high, 0)
    }
    func testDescriptorShape() {
        XCTAssertNil(MacIRNEONByteDotProduct(kind: .sdot, activeBytes: 4))
        XCTAssertNil(MacIRNEONByteDotProduct(kind: .udot, activeBytes: 12))
        XCTAssertEqual(MacIRNEONByteDotProduct(kind: .udot, activeBytes: 16)?.groupBytes, 4)
    }
}
