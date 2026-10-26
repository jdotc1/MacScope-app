import Foundation
import XCTest
@testable import MacScope

/// Advanced-SIMD two-register miscellaneous breadth (round 3): the integer unary ops plus
/// fabs/fneg/fsqrt and the FP compare-with-zero forms. Words + renderings are ground-truthed
/// via `clang -arch arm64` + `otool -tvVj`. (The frintN/M/P/Z/A/X/I and fcvtN/M/P/A S/U
/// round/convert sub-group — the bit23-split family — is deferred to a later round.)
final class ARM64TwoRegMiscTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    // MARK: - Integer unary (same-width)
    func testReverseElements() {
        XCTAssertEqual(text(0x4ea00820), "rev64 v0.4s, v1.4s")
        XCTAssertEqual(text(0x6e600820), "rev32 v0.8h, v1.8h")
        XCTAssertEqual(text(0x4e201820), "rev16 v0.16b, v1.16b")
    }
    func testCountAndBitwise() {
        XCTAssertEqual(text(0x4e205820), "cnt v0.16b, v1.16b")
        XCTAssertEqual(text(0x6e205820), "mvn v0.16b, v1.16b")   // NOT, preferred alias
        XCTAssertEqual(text(0x6e605820), "rbit v0.16b, v1.16b")  // byte arrangement despite size=01
        XCTAssertEqual(text(0x4ea04820), "cls v0.4s, v1.4s")
        XCTAssertEqual(text(0x6ea04820), "clz v0.4s, v1.4s")
    }
    func testAbsNegSaturating() {
        XCTAssertEqual(text(0x4ea0b820), "abs v0.4s, v1.4s")
        XCTAssertEqual(text(0x6ee0b820), "neg v0.2d, v1.2d")
        XCTAssertEqual(text(0x4ea07820), "sqabs v0.4s, v1.4s")
        XCTAssertEqual(text(0x6ea07820), "sqneg v0.4s, v1.4s")
        XCTAssertEqual(text(0x4ea03820), "suqadd v0.4s, v1.4s")
        XCTAssertEqual(text(0x6ea03820), "usqadd v0.4s, v1.4s")
    }
    func testPairwiseWidening() {
        XCTAssertEqual(text(0x4ea02820), "saddlp v0.2d, v1.4s")
        XCTAssertEqual(text(0x6ea02820), "uaddlp v0.2d, v1.4s")
        XCTAssertEqual(text(0x4ea06820), "sadalp v0.2d, v1.4s")
        XCTAssertEqual(text(0x6ea06820), "uadalp v0.2d, v1.4s")
    }
    func testNarrowingAndShll() {
        XCTAssertEqual(text(0x0e612820), "xtn v0.4h, v1.4s")
        XCTAssertEqual(text(0x4e612820), "xtn2 v0.8h, v1.4s")
        XCTAssertEqual(text(0x0e614820), "sqxtn v0.4h, v1.4s")
        XCTAssertEqual(text(0x2e612820), "sqxtun v0.4h, v1.4s")
        XCTAssertEqual(text(0x2e614820), "uqxtn v0.4h, v1.4s")
        XCTAssertEqual(text(0x2e613820), "shll v0.4s, v1.4h, #16")
        XCTAssertEqual(text(0x6e613820), "shll2 v0.4s, v1.8h, #16")
    }

    // MARK: - FP unary + compare-with-zero
    func testFPUnary() {
        XCTAssertEqual(text(0x4ea0f820), "fabs v0.4s, v1.4s")
        XCTAssertEqual(text(0x6ea0f820), "fneg v0.4s, v1.4s")
        XCTAssertEqual(text(0x6ea1f820), "fsqrt v0.4s, v1.4s")
    }
    func testFPCompareZero() {
        XCTAssertEqual(text(0x4ea0c820), "fcmgt v0.4s, v1.4s, #0.0")
        XCTAssertEqual(text(0x6ea0c820), "fcmge v0.4s, v1.4s, #0.0")
        XCTAssertEqual(text(0x4ea0d820), "fcmeq v0.4s, v1.4s, #0.0")
        XCTAssertEqual(text(0x6ea0d820), "fcmle v0.4s, v1.4s, #0.0")
        XCTAssertEqual(text(0x4ea0e820), "fcmlt v0.4s, v1.4s, #0.0")
    }

    // MARK: - Reserved encodings: size=11/Q=0 (.1d) is undefined for these vector ops (clang
    // rejects `abs v0.1d`; otool prints `.long`). The decoder must return `unknown`, not fabricate .1d.
    private func mnemonic(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        return ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0].mnemonic
    }
    func testReservedDoublewordScalarSlotIsUnknown() {
        XCTAssertEqual(mnemonic(0x0ee0b820), "unknown")  // abs .1d
        XCTAssertEqual(mnemonic(0x2ee0b820), "unknown")  // neg .1d
        XCTAssertEqual(mnemonic(0x0ee07820), "unknown")  // sqabs .1d
        XCTAssertEqual(mnemonic(0x2ee07820), "unknown")  // sqneg .1d
        XCTAssertEqual(mnemonic(0x0ee03820), "unknown")  // suqadd .1d
        XCTAssertEqual(mnemonic(0x2ee03820), "unknown")  // usqadd .1d
    }

    // MARK: - Regression: pre-existing two-reg-misc ops must still decode after the additions
    func testExistingUnchanged() {
        XCTAssertEqual(text(0x4ea08820), "cmgt v0.4s, v1.4s, #0")   // compare-with-zero
        XCTAssertEqual(text(0x0e216820), "fcvtn v0.4h, v1.4s")      // narrowing convert
        XCTAssertEqual(text(0x4e21d820), "scvtf v0.4s, v1.4s")      // int -> FP convert
        XCTAssertEqual(text(0x4ea1b820), "fcvtzs v0.4s, v1.4s")     // FP -> int (round toward zero)
    }
}
