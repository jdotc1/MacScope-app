import XCTest
@testable import MacScope

/// Source-only native API boundary checks; not a native execution receipt.
final class MacIRNEONIndexedProductPairwiseTests: XCTestCase {
    func testExistingAdjacentPairDescriptor() {
        XCTAssertNotNil(MacIRNEONPairwise(kind: .addp, elementBytes: 4, activeBytes: 16))
        XCTAssertNil(MacIRNEONPairwise(kind: .addp, elementBytes: 3, activeBytes: 16))
    }
}
