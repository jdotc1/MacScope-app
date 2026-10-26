import XCTest
@testable import MacScope
final class MacIRNEONMixedByteDotProductTests: XCTestCase {
    func testFixedRolesModulo32AndQ0Clear() throws {
        let d = try XCTUnwrap(MacIRNEONMixedByteDotProduct(activeBytes: 8))
        let r = d.evaluate(firstUnsigned: (0x01010101ffffffff, .max), secondSigned: (0x02020202ffffffff, .max), old: (0xfffffffc00000002, .max))
        XCTAssertEqual(r.low, 0x00000004fffffc06); XCTAssertEqual(r.high, 0)
        XCTAssertEqual(d.firstSignedness, .unsigned); XCTAssertEqual(d.secondSignedness, .signed)
    }
    func testImmutableFixedShape() {
        XCTAssertNil(MacIRNEONMixedByteDotProduct(activeBytes: 4))
        XCTAssertNil(MacIRNEONMixedByteDotProduct(activeBytes: 12))
    }
}
