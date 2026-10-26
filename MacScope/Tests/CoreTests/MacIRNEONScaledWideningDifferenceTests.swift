import XCTest
@testable import MacScope

/// Source-only native checks; portable witnesses are separately released once.
final class MacIRNEONScaledWideningDifferenceTests: XCTestCase {
    func testBoundedShiftConstructorsRemainExistingTypes() {
        XCTAssertNotNil(MacIRNEONShiftNarrow(narrowBits:16, shift:1, destinationHighHalf:false))
        XCTAssertNotNil(MacIRNEONShiftNarrow(narrowBits:16, shift:16, destinationHighHalf:true))
        XCTAssertNil(MacIRNEONShiftNarrow(narrowBits:16, shift:17, destinationHighHalf:false))
        XCTAssertNotNil(MacIRNEONShiftInsert(kind:.sshr, arrangement:.s4, shift:16))
    }
}
