import Foundation
import XCTest
@testable import MacScope

final class ARM64ScalarTwoRegMiscTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    private func mnemonic(_ word: UInt32) -> String {
        String(text(word).split(separator: " ")[0])
    }

    func testSaturatingUnarySameWidth() {
        XCTAssertEqual(text(0x5e203820), "suqadd b0, b1")
        XCTAssertEqual(text(0x5e603862), "suqadd h2, h3")
        XCTAssertEqual(text(0x5ea038a4), "suqadd s4, s5")
        XCTAssertEqual(text(0x5ee038e6), "suqadd d6, d7")
        XCTAssertEqual(text(0x7e203928), "usqadd b8, b9")
        XCTAssertEqual(text(0x7e60396a), "usqadd h10, h11")
        XCTAssertEqual(text(0x7ea039ac), "usqadd s12, s13")
        XCTAssertEqual(text(0x7ee039ee), "usqadd d14, d15")

        XCTAssertEqual(text(0x5e207820), "sqabs b0, b1")
        XCTAssertEqual(text(0x5e607862), "sqabs h2, h3")
        XCTAssertEqual(text(0x5ea078a4), "sqabs s4, s5")
        XCTAssertEqual(text(0x5ee078e6), "sqabs d6, d7")
        XCTAssertEqual(text(0x7e207928), "sqneg b8, b9")
        XCTAssertEqual(text(0x7e60796a), "sqneg h10, h11")
        XCTAssertEqual(text(0x7ea079ac), "sqneg s12, s13")
        XCTAssertEqual(text(0x7ee079ee), "sqneg d14, d15")
    }

    func testDOnlyIntegerUnaryAndCompareZero() {
        XCTAssertEqual(text(0x5ee0b820), "abs d0, d1")
        XCTAssertEqual(text(0x7ee0b862), "neg d2, d3")

        XCTAssertEqual(text(0x5ee08820), "cmgt d0, d1, #0")
        XCTAssertEqual(text(0x7ee08862), "cmge d2, d3, #0")
        XCTAssertEqual(text(0x5ee098a4), "cmeq d4, d5, #0")
        XCTAssertEqual(text(0x7ee098e6), "cmle d6, d7, #0")
        XCTAssertEqual(text(0x5ee0a928), "cmlt d8, d9, #0")
    }

    func testScalarNarrowing() {
        XCTAssertEqual(text(0x5e214820), "sqxtn b0, h1")
        XCTAssertEqual(text(0x5e614862), "sqxtn h2, s3")
        XCTAssertEqual(text(0x5ea148a4), "sqxtn s4, d5")
        XCTAssertEqual(text(0x7e2128e6), "sqxtun b6, h7")
        XCTAssertEqual(text(0x7e612928), "sqxtun h8, s9")
        XCTAssertEqual(text(0x7ea1296a), "sqxtun s10, d11")
        XCTAssertEqual(text(0x7e2149ac), "uqxtn b12, h13")
        XCTAssertEqual(text(0x7e6149ee), "uqxtn h14, s15")
        XCTAssertEqual(text(0x7ea14a30), "uqxtn s16, d17")
        XCTAssertEqual(text(0x7e616820), "fcvtxn s0, d1")
    }

    func testFloatToIntegerConvertClassA() {
        XCTAssertEqual(text(0x5e21a820), "fcvtns s0, s1")
        XCTAssertEqual(text(0x5e61a862), "fcvtns d2, d3")
        XCTAssertEqual(text(0x7e21a8a4), "fcvtnu s4, s5")
        XCTAssertEqual(text(0x7e61a8e6), "fcvtnu d6, d7")
        XCTAssertEqual(text(0x5e21b928), "fcvtms s8, s9")
        XCTAssertEqual(text(0x5e61b96a), "fcvtms d10, d11")
        XCTAssertEqual(text(0x7e21b9ac), "fcvtmu s12, s13")
        XCTAssertEqual(text(0x7e61b9ee), "fcvtmu d14, d15")
        XCTAssertEqual(text(0x5ea1aa30), "fcvtps s16, s17")
        XCTAssertEqual(text(0x5ee1aa72), "fcvtps d18, d19")
        XCTAssertEqual(text(0x7ea1aab4), "fcvtpu s20, s21")
        XCTAssertEqual(text(0x7ee1aaf6), "fcvtpu d22, d23")
        XCTAssertEqual(text(0x5e21cb38), "fcvtas s24, s25")
        XCTAssertEqual(text(0x5e61cb7a), "fcvtas d26, d27")
        XCTAssertEqual(text(0x7e21cbbc), "fcvtau s28, s29")
        XCTAssertEqual(text(0x7e61cbfe), "fcvtau d30, d31")
        XCTAssertEqual(text(0x5ea1b820), "fcvtzs s0, s1")
        XCTAssertEqual(text(0x5ee1b862), "fcvtzs d2, d3")
        XCTAssertEqual(text(0x7ea1b8a4), "fcvtzu s4, s5")
        XCTAssertEqual(text(0x7ee1b8e6), "fcvtzu d6, d7")
    }

    func testIntegerToFloatAndReciprocalClassA() {
        XCTAssertEqual(text(0x5e21d820), "scvtf s0, s1")
        XCTAssertEqual(text(0x5e61d862), "scvtf d2, d3")
        XCTAssertEqual(text(0x7e21d8a4), "ucvtf s4, s5")
        XCTAssertEqual(text(0x7e61d8e6), "ucvtf d6, d7")
        XCTAssertEqual(text(0x5ea1d820), "frecpe s0, s1")
        XCTAssertEqual(text(0x5ee1d862), "frecpe d2, d3")
        XCTAssertEqual(text(0x7ea1d8a4), "frsqrte s4, s5")
        XCTAssertEqual(text(0x7ee1d8e6), "frsqrte d6, d7")
        XCTAssertEqual(text(0x5ea1f928), "frecpx s8, s9")
        XCTAssertEqual(text(0x5ee1f96a), "frecpx d10, d11")
    }

    func testFPCompareZeroClassA() {
        XCTAssertEqual(text(0x5ea0c820), "fcmgt s0, s1, #0.0")
        XCTAssertEqual(text(0x5ee0c862), "fcmgt d2, d3, #0.0")
        XCTAssertEqual(text(0x7ea0c8a4), "fcmge s4, s5, #0.0")
        XCTAssertEqual(text(0x7ee0c8e6), "fcmge d6, d7, #0.0")
        XCTAssertEqual(text(0x5ea0d928), "fcmeq s8, s9, #0.0")
        XCTAssertEqual(text(0x5ee0d96a), "fcmeq d10, d11, #0.0")
        XCTAssertEqual(text(0x7ea0d9ac), "fcmle s12, s13, #0.0")
        XCTAssertEqual(text(0x7ee0d9ee), "fcmle d14, d15, #0.0")
        XCTAssertEqual(text(0x5ea0ea30), "fcmlt s16, s17, #0.0")
        XCTAssertEqual(text(0x5ee0ea72), "fcmlt d18, d19, #0.0")
    }

    func testFP16ConvertAndReciprocal() {
        XCTAssertEqual(text(0x5e79a820), "fcvtns h0, h1")
        XCTAssertEqual(text(0x7e79a862), "fcvtnu h2, h3")
        XCTAssertEqual(text(0x5e79b8a4), "fcvtms h4, h5")
        XCTAssertEqual(text(0x7e79b8e6), "fcvtmu h6, h7")
        XCTAssertEqual(text(0x5ef9a928), "fcvtps h8, h9")
        XCTAssertEqual(text(0x7ef9a96a), "fcvtpu h10, h11")
        XCTAssertEqual(text(0x5e79c9ac), "fcvtas h12, h13")
        XCTAssertEqual(text(0x7e79c9ee), "fcvtau h14, h15")
        XCTAssertEqual(text(0x5ef9ba30), "fcvtzs h16, h17")
        XCTAssertEqual(text(0x7ef9ba72), "fcvtzu h18, h19")
        XCTAssertEqual(text(0x5e79dab4), "scvtf h20, h21")
        XCTAssertEqual(text(0x7e79daf6), "ucvtf h22, h23")
        XCTAssertEqual(text(0x5ef9db38), "frecpe h24, h25")
        XCTAssertEqual(text(0x7ef9db7a), "frsqrte h26, h27")
        XCTAssertEqual(text(0x5ef9fbbc), "frecpx h28, h29")
    }

    func testFP16CompareZero() {
        XCTAssertEqual(text(0x5ef8c820), "fcmgt h0, h1, #0.0")
        XCTAssertEqual(text(0x7ef8c862), "fcmge h2, h3, #0.0")
        XCTAssertEqual(text(0x5ef8d8a4), "fcmeq h4, h5, #0.0")
        XCTAssertEqual(text(0x7ef8d8e6), "fcmle h6, h7, #0.0")
        XCTAssertEqual(text(0x5ef8e928), "fcmlt h8, h9, #0.0")
    }

    func testReservedSlotsAreUnknown() {
        XCTAssertEqual(mnemonic(0x5e20b820), "unknown")
        XCTAssertEqual(mnemonic(0x7ea0b820), "unknown")
        XCTAssertEqual(mnemonic(0x5e208820), "unknown")
        XCTAssertEqual(mnemonic(0x5e203020), "unknown")
        XCTAssertEqual(mnemonic(0x5ee00820), "unknown")
        XCTAssertEqual(mnemonic(0x5ee10820), "unknown")
    }
}
