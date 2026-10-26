import XCTest
@testable import MacScope

final class MacIRNEONPredicateTests: XCTestCase {
    func testUnsignedVersusLiteralZeroArity() {
        let unsigned = MacIRNEONPredicate(kind: .cmhi, elementBytes: 8, activeBytes: 16)!
        XCTAssertEqual(unsigned.arity, 2)
        XCTAssertFalse(unsigned.comparesZero)
        let zero = MacIRNEONPredicate(kind: .cmle, elementBytes: 2, activeBytes: 8)!
        XCTAssertEqual(zero.arity, 1)
        XCTAssertTrue(zero.comparesZero)
        XCTAssertEqual(zero.laneCount, 4)
        XCTAssertEqual(Set([zero, zero]).count, 1)
    }
    func testReservedOneDAndMalformedWidths() {
        XCTAssertNil(MacIRNEONPredicate(kind: .cmhs, elementBytes: 8, activeBytes: 8))
        XCTAssertNil(MacIRNEONPredicate(kind: .cmlt, elementBytes: 3, activeBytes: 16))
        XCTAssertNil(MacIRNEONPredicate(kind: .cmeq, elementBytes: 4, activeBytes: 32))
    }
    // Source-only native XCTest. Full20 new producer/consumer witnesses live in portable/main.swift.
}
