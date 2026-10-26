import XCTest
@testable import MacScope

final class MacIRNEONIndexedMixedByteDotProductTests: XCTestCase {
    func testImmutableDistinctMixedRolesAndFullCoefficient() throws {
        let u = try XCTUnwrap(MacIRNEONIndexedMixedByteDotProduct(kind: .usdot, selectedGroup: 3, activeBytes: 8))
        let s = try XCTUnwrap(MacIRNEONIndexedMixedByteDotProduct(kind: .sudot, selectedGroup: 3, activeBytes: 8))
        XCTAssertEqual(u.firstRole, .unsigned)
        XCTAssertEqual(u.coefficientRole, .signed)
        XCTAssertEqual(s.firstRole, .signed)
        XCTAssertEqual(s.coefficientRole, .unsigned)
        XCTAssertEqual(u.coefficientBytes, 16)
        XCTAssertEqual(u.groupBytes, 4)
        XCTAssertEqual(u.laneCount, 2)
        XCTAssertNotEqual(u, s)
    }
    func testBoundedConstructor() {
        XCTAssertNil(MacIRNEONIndexedMixedByteDotProduct(kind: .usdot, selectedGroup: -1, activeBytes: 8))
        XCTAssertNil(MacIRNEONIndexedMixedByteDotProduct(kind: .sudot, selectedGroup: 4, activeBytes: 16))
        XCTAssertNil(MacIRNEONIndexedMixedByteDotProduct(kind: .usdot, selectedGroup: 3, activeBytes: 4))
    }
    func testIndependentHighCoefficientAndQZeroClear() throws {
        let d = try XCTUnwrap(MacIRNEONIndexedMixedByteDotProduct(kind: .usdot, selectedGroup: 3, activeBytes: 8))
        let result = d.evaluate(first: (0x8080808080808080, 0), second: (0, 0xffffffff00000000), old: (0x0000000100000001, UInt64.max))
        XCTAssertEqual(result.low, 0xfffffe01fffffe01)
        XCTAssertEqual(result.high, 0)
    }
}
