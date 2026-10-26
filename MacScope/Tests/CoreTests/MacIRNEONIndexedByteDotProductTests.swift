import XCTest
@testable import MacScope
final class MacIRNEONIndexedByteDotProductTests: XCTestCase {
    func testSelectedGroupThreeIgnoresQAndClearsHigh() throws {
        let d = try XCTUnwrap(MacIRNEONIndexedByteDotProduct(kind: .sdot, selectedGroup: 3, activeBytes: 8))
        let r = d.evaluate(first: (0x01010101ffffffff, .max), second: (0, 0x0202020200000000), old: (0xfffffffc00000002, .max))
        XCTAssertEqual(r.low, 0x00000004fffffffa); XCTAssertEqual(r.high, 0)
    }
    func testImmutableShape() {
        XCTAssertNil(MacIRNEONIndexedByteDotProduct(kind: .udot, selectedGroup: 4, activeBytes: 8))
        XCTAssertNil(MacIRNEONIndexedByteDotProduct(kind: .sdot, selectedGroup: 3, activeBytes: 12))
    }
}
