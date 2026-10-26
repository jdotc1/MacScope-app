import Foundation
import XCTest
@testable import MacScope

final class ARM64ScalarPairwiseTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    private func mnemonic(_ word: UInt32) -> String {
        String(text(word).split(separator: " ")[0])
    }

    func testFloatingPointPairwiseHSD() {
        XCTAssertEqual(text(0x5e30d820), "faddp h0, v1.2h")
        XCTAssertEqual(text(0x7e30d820), "faddp s0, v1.2s")
        XCTAssertEqual(text(0x7e70d820), "faddp d0, v1.2d")

        XCTAssertEqual(text(0x5e30f862), "fmaxp h2, v3.2h")
        XCTAssertEqual(text(0x7e30f862), "fmaxp s2, v3.2s")
        XCTAssertEqual(text(0x7e70f96a), "fmaxp d10, v11.2d")

        XCTAssertEqual(text(0x5eb0f8a4), "fminp h4, v5.2h")
        XCTAssertEqual(text(0x7eb0f8a4), "fminp s4, v5.2s")
        XCTAssertEqual(text(0x7ef0f9ac), "fminp d12, v13.2d")

        XCTAssertEqual(text(0x5e30c8e6), "fmaxnmp h6, v7.2h")
        XCTAssertEqual(text(0x7e30c8e6), "fmaxnmp s6, v7.2s")
        XCTAssertEqual(text(0x7e70c9ee), "fmaxnmp d14, v15.2d")

        XCTAssertEqual(text(0x5eb0c928), "fminnmp h8, v9.2h")
        XCTAssertEqual(text(0x7eb0c928), "fminnmp s8, v9.2s")
        XCTAssertEqual(text(0x7ef0ca30), "fminnmp d16, v17.2d")
    }

    func testIntegerPairwiseAddp() {
        XCTAssertEqual(text(0x5ef1b820), "addp d0, v1.2d")
        XCTAssertEqual(text(0x5ef1bbff), "addp d31, v31.2d")
    }

    func testReservedSlotsAreUnknown() {
        XCTAssertEqual(mnemonic(0x5e300820), "unknown")  // unmapped opcode
        XCTAssertEqual(mnemonic(0x5eb0d820), "unknown")  // faddp has no a=1 form
        XCTAssertEqual(mnemonic(0x7ef0d820), "unknown")  // faddp has no a=1 form
        XCTAssertEqual(mnemonic(0x5e70c820), "unknown")  // FP16 pairwise requires bit22=0
        XCTAssertEqual(mnemonic(0x5e31b820), "unknown")  // addp requires sz=11
        XCTAssertEqual(mnemonic(0x7ef1b820), "unknown")  // addp has no U=1 form
    }

    func testScalarTwoRegMiscNeighborStillDecodes() {
        XCTAssertEqual(text(0x5ee0d820), "fcmeq d0, d1, #0.0")
        XCTAssertEqual(text(0x5ee1b820), "fcvtzs d0, d1")
    }
}
