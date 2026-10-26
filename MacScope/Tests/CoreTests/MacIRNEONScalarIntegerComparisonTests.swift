import XCTest
@testable import MacScope
final class MacIRNEONScalarIntegerComparisonTests: XCTestCase {
    func testScalarMaskEncodingAndHighClear() throws {
        let signed = try XCTUnwrap(MacIRNEONScalarIntegerComparison(encodedWord: 0x5ee13400))
        let unsigned = try XCTUnwrap(MacIRNEONScalarIntegerComparison(encodedWord: 0x7ee13400))
        XCTAssertEqual(signed.kind, .cmgt); XCTAssertEqual(unsigned.kind, .cmhi)
        XCTAssertEqual(signed.evaluate(1 << 63, 0).low, 0)
        XCTAssertEqual(unsigned.evaluate(1 << 63, 0).low, UInt64.max)
        XCTAssertEqual(unsigned.evaluate(1 << 63, 0).high, 0)
        XCTAssertEqual(signed.sourceBits, 128); XCTAssertEqual(signed.outputBits, 128)
    }
    func testOnlyExactDTwoSource() {
        XCTAssertNil(MacIRNEONScalarIntegerComparison(encodedWord: 0x5e613400))
        XCTAssertNil(MacIRNEONScalarIntegerComparison(encodedWord: 0x4ee13400))
        XCTAssertNil(MacIRNEONScalarIntegerComparison(encodedWord: 0x5ee03800))
        XCTAssertNil(MacIRNEONScalarIntegerComparison(encodedWord: 0x5ee13000))
    }
}
