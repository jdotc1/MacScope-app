import Foundation
import XCTest
@testable import MacScope

/// Adversarial oracle verification of Package B (ARM64 crypto + SIMD three-different/two-reg-misc).
/// Every expected rendering is the canonical AArch64 form of what `clang -arch arm64` + `otool -tvVj`
/// produced for these words (otool's `.dot` surface syntax translated to canonical, e.g.
/// otool `saddl.8h v0, v1, v2` → `saddl v0.8h, v1.8b, v2.8b`). Independent of the package's own tests.
final class ARM64CryptoSIMDOracleTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        var data = Data()
        data.append(UInt8(word & 0xff)); data.append(UInt8((word >> 8) & 0xff))
        data.append(UInt8((word >> 16) & 0xff)); data.append(UInt8((word >> 24) & 0xff))
        let r = ARM64Decoder().decode(data, baseAddress: 0x1_0000_0000, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    func testCryptoAndSIMDDecodesMatchOtool() {
        // crypto AES
        XCTAssertEqual(text(0x4e284820), "aese v0.16b, v1.16b")
        XCTAssertEqual(text(0x4e285862), "aesd v2.16b, v3.16b")
        XCTAssertEqual(text(0x4e286820), "aesmc v0.16b, v1.16b")
        XCTAssertEqual(text(0x4e2878a4), "aesimc v4.16b, v5.16b")
        // crypto SHA1/SHA256
        XCTAssertEqual(text(0x5e020020), "sha1c q0, s1, v2.4s")
        XCTAssertEqual(text(0x5e280820), "sha1h s0, s1")
        XCTAssertEqual(text(0x5e024020), "sha256h q0, q1, v2.4s")
        XCTAssertEqual(text(0x5e282820), "sha256su0 v0.4s, v1.4s")
        // crypto three-reg-512 / SHA3
        XCTAssertEqual(text(0xce628020), "sha512h q0, q1, v2.2d")
        XCTAssertEqual(text(0xce220c20), "bcax v0.16b, v1.16b, v2.16b, v3.16b")
        XCTAssertEqual(text(0xce020c20), "eor3 v0.16b, v1.16b, v2.16b, v3.16b")
        XCTAssertEqual(text(0xce628c20), "rax1 v0.2d, v1.2d, v2.2d")
        // SIMD three-different (dest arrangement wider than sources; the `2` forms read .16b/.4s)
        XCTAssertEqual(text(0x0e220020), "saddl v0.8h, v1.8b, v2.8b")
        XCTAssertEqual(text(0x4e220020), "saddl2 v0.8h, v1.16b, v2.16b")
        XCTAssertEqual(text(0x0e622020), "ssubl v0.4s, v1.4h, v2.4h")
        XCTAssertEqual(text(0x4ea2c020), "smull2 v0.2d, v1.4s, v2.4s")
        XCTAssertEqual(text(0x2e221020), "uaddw v0.8h, v1.8h, v2.8b")
        // SIMD two-register-misc conversions
        XCTAssertEqual(text(0x0e217820), "fcvtl v0.4s, v1.4h")
        XCTAssertEqual(text(0x0e216820), "fcvtn v0.4h, v1.4s")
        XCTAssertEqual(text(0x4e21d820), "scvtf v0.4s, v1.4s")
        XCTAssertEqual(text(0x4ea1b820), "fcvtzs v0.4s, v1.4s")
    }

    /// SHA3 four/two-register coverage across operand encodings — the cases the package's own tests
    /// (which used Ra whose low bits were 0b11) hid: BCAX must decode for ANY Ra, and EOR3/XAR exist.
    func testSHA3FourAndTwoRegisterDecodes() {
        XCTAssertEqual(text(0xce220020), "bcax v0.16b, v1.16b, v2.16b, v0.16b")   // Ra=0 (was unknown)
        XCTAssertEqual(text(0xce220420), "bcax v0.16b, v1.16b, v2.16b, v1.16b")   // Ra=1 (was unknown)
        XCTAssertEqual(text(0xce020020), "eor3 v0.16b, v1.16b, v2.16b, v0.16b")   // EOR3 (was unknown)
        XCTAssertEqual(text(0xce820420), "xar v0.2d, v1.2d, v2.2d, #1")            // XAR (was unknown)
    }

    /// Dispatch-shadowing guard: the 5 new hooks sit BEFORE the existing three-same/copy/etc. hooks,
    /// so a too-broad mask would swallow valid existing SIMD. Confirm neighbors still decode right.
    func testNewHooksDoNotShadowExistingSIMD() {
        // otool ground truth for these existing forms:
        XCTAssertEqual(text(0x4ea28420), "add v0.4s, v1.4s, v2.4s")        // three-same integer add
        XCTAssertEqual(text(0x4e22d420), "fadd v0.4s, v1.4s, v2.4s")        // three-same FP add
        XCTAssertEqual(text(0x6e21dc20).hasPrefix("fmul"), true)           // three-same FP (U=1)
        XCTAssertEqual(text(0x4e080c20).hasPrefix("dup"), true)            // SIMD copy dup (general)
    }
}
