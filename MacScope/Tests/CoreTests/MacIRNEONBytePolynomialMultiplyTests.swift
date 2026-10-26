import XCTest
@testable import MacScope

final class MacIRNEONBytePolynomialMultiplyTests: XCTestCase {
    func testCarrylessTruncationAndCancellation() throws {
        let q0 = try XCTUnwrap(MacIRNEONBytePolynomialMultiply(activeBytes: 8))
        let result = q0.evaluate(first: (0x80800303, .max), second: (0x02800303, .max))
        XCTAssertEqual(result.low, 0x00000505) // 3×3 coefficients cancel x; high products truncate.
        XCTAssertEqual(result.high, 0)
        XCTAssertEqual(q0.coefficientDomain, .gf2)
        XCTAssertEqual(q0.resultRule, .truncateLow8)
        XCTAssertEqual(Set([q0, q0]).count, 1)
    }
    func testIndependentHighByteLanes() throws {
        let q1 = try XCTUnwrap(MacIRNEONBytePolynomialMultiply(activeBytes: 16))
        let result = q1.evaluate(first: (1, 0x80), second: (0xff, 1))
        XCTAssertEqual(result.low, 0xff); XCTAssertEqual(result.high, 0x80)
        XCTAssertNil(MacIRNEONBytePolynomialMultiply(activeBytes: 4))
        XCTAssertNil(MacIRNEONBytePolynomialMultiply(activeBytes: 32))
    }
}
