import Foundation
import XCTest
@testable import MacScope

final class ARM64FPRoundConvertTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    private func mnemonic(_ word: UInt32) -> String {
        String(text(word).split(separator: " ")[0])
    }

    func testRoundToIntegralVectorForms() {
        XCTAssertEqual(text(0x0e218820), "frintn v0.2s, v1.2s")
        XCTAssertEqual(text(0x4e218820), "frintn v0.4s, v1.4s")
        XCTAssertEqual(text(0x4e618820), "frintn v0.2d, v1.2d")
        XCTAssertEqual(text(0x0e219820), "frintm v0.2s, v1.2s")
        XCTAssertEqual(text(0x4e219820), "frintm v0.4s, v1.4s")
        XCTAssertEqual(text(0x4e619820), "frintm v0.2d, v1.2d")
        XCTAssertEqual(text(0x0ea18820), "frintp v0.2s, v1.2s")
        XCTAssertEqual(text(0x4ea18820), "frintp v0.4s, v1.4s")
        XCTAssertEqual(text(0x4ee18820), "frintp v0.2d, v1.2d")
        XCTAssertEqual(text(0x0ea19820), "frintz v0.2s, v1.2s")
        XCTAssertEqual(text(0x4ea19820), "frintz v0.4s, v1.4s")
        XCTAssertEqual(text(0x4ee19820), "frintz v0.2d, v1.2d")
        XCTAssertEqual(text(0x2e218820), "frinta v0.2s, v1.2s")
        XCTAssertEqual(text(0x6e218820), "frinta v0.4s, v1.4s")
        XCTAssertEqual(text(0x6e618820), "frinta v0.2d, v1.2d")
        XCTAssertEqual(text(0x2e219820), "frintx v0.2s, v1.2s")
        XCTAssertEqual(text(0x6e219820), "frintx v0.4s, v1.4s")
        XCTAssertEqual(text(0x6e619820), "frintx v0.2d, v1.2d")
        XCTAssertEqual(text(0x2ea19820), "frinti v0.2s, v1.2s")
        XCTAssertEqual(text(0x6ea19820), "frinti v0.4s, v1.4s")
        XCTAssertEqual(text(0x6ee19820), "frinti v0.2d, v1.2d")
    }

    func testConvertToIntegerVectorForms() {
        XCTAssertEqual(text(0x0e21a820), "fcvtns v0.2s, v1.2s")
        XCTAssertEqual(text(0x4e21a820), "fcvtns v0.4s, v1.4s")
        XCTAssertEqual(text(0x4e61a820), "fcvtns v0.2d, v1.2d")
        XCTAssertEqual(text(0x0e21b820), "fcvtms v0.2s, v1.2s")
        XCTAssertEqual(text(0x4e21b820), "fcvtms v0.4s, v1.4s")
        XCTAssertEqual(text(0x4e61b820), "fcvtms v0.2d, v1.2d")
        XCTAssertEqual(text(0x0ea1a820), "fcvtps v0.2s, v1.2s")
        XCTAssertEqual(text(0x4ea1a820), "fcvtps v0.4s, v1.4s")
        XCTAssertEqual(text(0x4ee1a820), "fcvtps v0.2d, v1.2d")
        XCTAssertEqual(text(0x0e21c820), "fcvtas v0.2s, v1.2s")
        XCTAssertEqual(text(0x4e21c820), "fcvtas v0.4s, v1.4s")
        XCTAssertEqual(text(0x4e61c820), "fcvtas v0.2d, v1.2d")
        XCTAssertEqual(text(0x2e21a820), "fcvtnu v0.2s, v1.2s")
        XCTAssertEqual(text(0x6e21a820), "fcvtnu v0.4s, v1.4s")
        XCTAssertEqual(text(0x6e61a820), "fcvtnu v0.2d, v1.2d")
        XCTAssertEqual(text(0x2e21b820), "fcvtmu v0.2s, v1.2s")
        XCTAssertEqual(text(0x6e21b820), "fcvtmu v0.4s, v1.4s")
        XCTAssertEqual(text(0x6e61b820), "fcvtmu v0.2d, v1.2d")
        XCTAssertEqual(text(0x2ea1a820), "fcvtpu v0.2s, v1.2s")
        XCTAssertEqual(text(0x6ea1a820), "fcvtpu v0.4s, v1.4s")
        XCTAssertEqual(text(0x6ee1a820), "fcvtpu v0.2d, v1.2d")
        XCTAssertEqual(text(0x2e21c820), "fcvtau v0.2s, v1.2s")
        XCTAssertEqual(text(0x6e21c820), "fcvtau v0.4s, v1.4s")
        XCTAssertEqual(text(0x6e61c820), "fcvtau v0.2d, v1.2d")
    }

    func testReciprocalEstimateVectorForms() {
        XCTAssertEqual(text(0x0ea1d820), "frecpe v0.2s, v1.2s")
        XCTAssertEqual(text(0x4ea1d820), "frecpe v0.4s, v1.4s")
        XCTAssertEqual(text(0x4ee1d820), "frecpe v0.2d, v1.2d")
        XCTAssertEqual(text(0x2ea1d820), "frsqrte v0.2s, v1.2s")
        XCTAssertEqual(text(0x6ea1d820), "frsqrte v0.4s, v1.4s")
        XCTAssertEqual(text(0x6ee1d820), "frsqrte v0.2d, v1.2d")
        XCTAssertEqual(text(0x0ea1c820), "urecpe v0.2s, v1.2s")
        XCTAssertEqual(text(0x4ea1c820), "urecpe v0.4s, v1.4s")
        XCTAssertEqual(text(0x2ea1c820), "ursqrte v0.2s, v1.2s")
        XCTAssertEqual(text(0x6ea1c820), "ursqrte v0.4s, v1.4s")
    }

    func testPairwiseFPVectorForms() {
        XCTAssertEqual(text(0x2e22d420), "faddp v0.2s, v1.2s, v2.2s")
        XCTAssertEqual(text(0x6e22d420), "faddp v0.4s, v1.4s, v2.4s")
        XCTAssertEqual(text(0x6e62d420), "faddp v0.2d, v1.2d, v2.2d")
        XCTAssertEqual(text(0x2e22c420), "fmaxnmp v0.2s, v1.2s, v2.2s")
        XCTAssertEqual(text(0x6e22c420), "fmaxnmp v0.4s, v1.4s, v2.4s")
        XCTAssertEqual(text(0x6e62c420), "fmaxnmp v0.2d, v1.2d, v2.2d")
        XCTAssertEqual(text(0x2ea2c420), "fminnmp v0.2s, v1.2s, v2.2s")
        XCTAssertEqual(text(0x6ea2c420), "fminnmp v0.4s, v1.4s, v2.4s")
        XCTAssertEqual(text(0x6ee2c420), "fminnmp v0.2d, v1.2d, v2.2d")
        XCTAssertEqual(text(0x2e22f420), "fmaxp v0.2s, v1.2s, v2.2s")
        XCTAssertEqual(text(0x6e22f420), "fmaxp v0.4s, v1.4s, v2.4s")
        XCTAssertEqual(text(0x6e62f420), "fmaxp v0.2d, v1.2d, v2.2d")
        XCTAssertEqual(text(0x2ea2f420), "fminp v0.2s, v1.2s, v2.2s")
        XCTAssertEqual(text(0x6ea2f420), "fminp v0.4s, v1.4s, v2.4s")
        XCTAssertEqual(text(0x6ee2f420), "fminp v0.2d, v1.2d, v2.2d")
    }

    func testExistingSharedSlotsStillDecode() {
        XCTAssertEqual(text(0x4e21d820), "scvtf v0.4s, v1.4s")
        XCTAssertEqual(text(0x6e61d820), "ucvtf v0.2d, v1.2d")
        XCTAssertEqual(text(0x4ea1b820), "fcvtzs v0.4s, v1.4s")
        XCTAssertEqual(text(0x6ee1b820), "fcvtzu v0.2d, v1.2d")
        XCTAssertEqual(text(0x4e21e820), "frint32z v0.4s, v1.4s")
        XCTAssertEqual(text(0x6e61f820), "frint64x v0.2d, v1.2d")
        XCTAssertEqual(text(0x6ea1f820), "fsqrt v0.4s, v1.4s")
    }

    func testReservedSlotsAreUnknown() {
        XCTAssertEqual(mnemonic(0x0e618820), "unknown")
        XCTAssertEqual(mnemonic(0x0e61a820), "unknown")
        XCTAssertEqual(mnemonic(0x2ee19820), "unknown")
        XCTAssertEqual(mnemonic(0x2ea18820), "unknown")
        XCTAssertEqual(mnemonic(0x6ea18820), "unknown")
        XCTAssertEqual(mnemonic(0x4ee1c820), "unknown")
        XCTAssertEqual(mnemonic(0x6ee1c820), "unknown")
        XCTAssertEqual(mnemonic(0x4ea1e820), "unknown")
        XCTAssertEqual(mnemonic(0x4ea1f820), "unknown")
        XCTAssertEqual(mnemonic(0x2ee1f820), "unknown")
        XCTAssertEqual(mnemonic(0x2e62d420), "unknown")
        XCTAssertEqual(mnemonic(0x2ee2f420), "unknown")
    }
}
