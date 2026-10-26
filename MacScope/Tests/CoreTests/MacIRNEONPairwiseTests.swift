import XCTest
@testable import MacScope

final class MacIRNEONPairwiseTests: XCTestCase {
    func testDoublewordOnlyADDP() {
        XCTAssertNotNil(MacIRNEONPairwise(kind: .addp, elementBytes: 8, activeBytes: 16))
        XCTAssertNil(MacIRNEONPairwise(kind: .addp, elementBytes: 8, activeBytes: 8))
        XCTAssertNil(MacIRNEONPairwise(kind: .sminp, elementBytes: 8, activeBytes: 16))
        XCTAssertNil(MacIRNEONPairwise(kind: .umaxp, elementBytes: 8, activeBytes: 16))
    }
    func testDescriptorIsImmutableHashableValue() {
        let a = MacIRNEONPairwise(kind: .sminp, elementBytes: 1, activeBytes: 8)!
        XCTAssertEqual(Set([a,a]).count, 1)
        XCTAssertEqual(a.laneCount, 8)
    }
    // Full20 decoder/builder/name-erased typed-consumer behavioral assertions
    // live in this packet's portable/main.swift and ran only on fresh DOT49 states.
    // Native XCTest target/build execution remains owner-controlled.
}
