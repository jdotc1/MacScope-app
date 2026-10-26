import XCTest
@testable import MacScope

final class MacIRNEONMagnitudeClampTests: XCTestCase {
    func testDoublewordsAreUnaryAndQ1Only() {
        XCTAssertNotNil(MacIRNEONMagnitudeClamp(kind: .abs, elementBytes: 8, activeBytes: 16))
        XCTAssertNotNil(MacIRNEONMagnitudeClamp(kind: .neg, elementBytes: 8, activeBytes: 16))
        XCTAssertNil(MacIRNEONMagnitudeClamp(kind: .abs, elementBytes: 8, activeBytes: 8))
        XCTAssertNil(MacIRNEONMagnitudeClamp(kind: .smin, elementBytes: 8, activeBytes: 16))
        XCTAssertNil(MacIRNEONMagnitudeClamp(kind: .umax, elementBytes: 8, activeBytes: 16))
    }
    func testSemanticShapeIsImmutableHashableValue() {
        let a = MacIRNEONMagnitudeClamp(kind: .abs, elementBytes: 1, activeBytes: 8)!
        let b = MacIRNEONMagnitudeClamp(kind: .smin, elementBytes: 4, activeBytes: 16)!
        XCTAssertEqual(Set([a,a]).count, 1)
        XCTAssertEqual(a.laneCount, 8)
        XCTAssertEqual(a.arity, 1)
        XCTAssertEqual(b.arity, 2)
    }
    // Fresh full20 decoder → actual builder → name-erased typed evaluator
    // behavioral assertions are in portable/main.swift. Native target build
    // and execution remain owner-controlled, not claimed by portable evidence.
}
