import XCTest
@testable import MacScope

final class MacIRNEONWideningPairwiseTests: XCTestCase {
    func testWideningDescriptorAndOldDestinationRole() {
        let signed = MacIRNEONWideningPairwise(kind: .sadalp, sourceElementBytes: 4, activeBytes: 8)!
        XCTAssertEqual(signed.sourceLaneCount, 2)
        XCTAssertEqual(signed.destinationLaneCount, 1)
        XCTAssertEqual(signed.destinationElementBytes, 8)
        XCTAssertTrue(signed.isSigned)
        XCTAssertTrue(signed.accumulates)
        XCTAssertEqual(signed.arity, 2)
        XCTAssertEqual(Set([signed, signed]).count, 1)
        let unsigned = MacIRNEONWideningPairwise(kind: .uaddlp, sourceElementBytes: 1, activeBytes: 16)!
        XCTAssertFalse(unsigned.isSigned)
        XCTAssertFalse(unsigned.accumulates)
        XCTAssertEqual(unsigned.arity, 1)
    }
    func testNoSourceDOrUnsupportedPhysicalWidth() {
        XCTAssertNil(MacIRNEONWideningPairwise(kind: .saddlp, sourceElementBytes: 8, activeBytes: 16))
        XCTAssertNil(MacIRNEONWideningPairwise(kind: .uadalp, sourceElementBytes: 3, activeBytes: 16))
        XCTAssertNil(MacIRNEONWideningPairwise(kind: .sadalp, sourceElementBytes: 4, activeBytes: 4))
    }
    // Native source-only tests. Fresh full20 producer/consumer execution is in portable/main.swift.
}
