import Foundation
import XCTest
@testable import MacScope

/// Round-2 arm64 decode tail: load-literal (PC-relative `ldr`/`ldrsw`/`prfm`), long/widening
/// by-element multiply-accumulate, and the v8.5 two-register-misc rounding/narrowing ops.
/// Words + renderings are ground-truthed via `clang -arch arm64` + `otool -tvVj`. Decoded at
/// baseAddress 0, so a literal's resolved target equals its byte offset (imm19 << 2).
final class ARM64LoadLiteralLongSIMDTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    // MARK: - Load register (literal) — PC-relative, resolved-address rendering like adr
    func testLoadLiteral() {
        XCTAssertEqual(text(0x18000381), "ldr w1, 0x0000000000000070")   // 32-bit GPR
        XCTAssertEqual(text(0x58000360), "ldr x0, 0x000000000000006c")   // 64-bit GPR
        XCTAssertEqual(text(0x98000342), "ldrsw x2, 0x0000000000000068") // sign-extending word
        XCTAssertEqual(text(0x1c000320), "ldr s0, 0x0000000000000064")   // FP single
        XCTAssertEqual(text(0x5c000301), "ldr d1, 0x0000000000000060")   // FP double
        XCTAssertEqual(text(0x9c0002e2), "ldr q2, 0x000000000000005c")   // 128-bit vector
        XCTAssertEqual(text(0xd80002c0), "prfm pldl1keep, 0x0000000000000058")
    }

    // MARK: - Long / widening by indexed element (Vd wide, Vn narrow, Vm.Ts[index])
    func testLongByElement() {
        XCTAssertEqual(text(0x0f52a020), "smull v0.4s, v1.4h, v2.h[1]")
        XCTAssertEqual(text(0x4f72a820), "smull2 v0.4s, v1.8h, v2.h[7]")   // Q high-half, max H index
        XCTAssertEqual(text(0x2fa2a820), "umull v0.2d, v1.2s, v2.s[3]")
        XCTAssertEqual(text(0x6fa5a083), "umull2 v3.2d, v4.4s, v5.s[1]")   // Vm=M:Rm reaches v5
        XCTAssertEqual(text(0x0f52b020), "sqdmull v0.4s, v1.4h, v2.h[1]")
        XCTAssertEqual(text(0x4f82b820), "sqdmull2 v0.2d, v1.4s, v2.s[2]")
        XCTAssertEqual(text(0x0f522020), "smlal v0.4s, v1.4h, v2.h[1]")
        XCTAssertEqual(text(0x6fa22020), "umlal2 v0.2d, v1.4s, v2.s[1]")
        XCTAssertEqual(text(0x0f726020), "smlsl v0.4s, v1.4h, v2.h[3]")
        XCTAssertEqual(text(0x6fa26020), "umlsl2 v0.2d, v1.4s, v2.s[1]")
        XCTAssertEqual(text(0x0f523020), "sqdmlal v0.4s, v1.4h, v2.h[1]")
        XCTAssertEqual(text(0x4f527820), "sqdmlsl2 v0.4s, v1.8h, v2.h[5]")
    }

    // MARK: - Two-register misc: v8.5 rounding + FP64->FP32 narrowing
    func testFrintAndFcvtxn() {
        XCTAssertEqual(text(0x4e21e820), "frint32z v0.4s, v1.4s")
        XCTAssertEqual(text(0x6e21e820), "frint32x v0.4s, v1.4s")
        XCTAssertEqual(text(0x4e61f820), "frint64z v0.2d, v1.2d")
        XCTAssertEqual(text(0x6e61f820), "frint64x v0.2d, v1.2d")
        XCTAssertEqual(text(0x2e616820), "fcvtxn v0.2s, v1.2d")
        XCTAssertEqual(text(0x6e616820), "fcvtxn2 v0.4s, v1.2d")
    }
}
