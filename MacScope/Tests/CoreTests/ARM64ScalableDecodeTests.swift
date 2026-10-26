import Foundation
import XCTest
@testable import MacScope

final class ARM64ScalableDecodeTests: XCTestCase {
    private func decode(_ word: UInt32) -> DecodedInstruction {
        var littleEndian = word.littleEndian
        return withUnsafeBytes(of: &littleEndian) {
            ARM64Decoder().decode(Data($0), baseAddress: 0x1000, maxInstructionCount: 1)[0]
        }
    }

    // Expected text independently observed with Apple LLVM's generic ELF printer.
    func testSMEStateAndCanonicalZeroAliases() {
        let cases: [(UInt32, String, String)] = [
            (0xd503477f, "smstart", ""), (0xd503437f, "smstart", "sm"),
            (0xd503457f, "smstart", "za"), (0xd503467f, "smstop", ""),
            (0xd503427f, "smstop", "sm"), (0xd503447f, "smstop", "za"),
            (0x04bf5fff, "rdsvl", "xzr, #-1"), (0x04bf5c15, "rdsvl", "x21, #-32"),
            (0xe1000000, "ldr", "za[w12, 0], [x0]"),
            (0xe13f83e0, "str", "zt0, [sp]"),
            (0xc0080000, "zero", "{}"), (0xc0080001, "zero", "{za0.d}"),
            (0xc0080011, "zero", "{za0.s}"), (0xc0080033, "zero", "{za0.s,za1.s}"),
            (0xc0080055, "zero", "{za0.h}"), (0xc00800aa, "zero", "{za1.h}"),
            (0xc00800ff, "zero", "{za}")
        ]
        for (word, name, operands) in cases {
            let actual = decode(word)
            XCTAssertEqual(actual.mnemonic, name, String(word, radix: 16))
            XCTAssertEqual(actual.operands, operands, String(word, radix: 16))
            XCTAssertEqual(actual.flow, .normal)
            XCTAssertNil(actual.branchTarget)
        }
    }

    func testStreamingVectorClasses() {
        let cases: [(UInt32, String, String)] = [
            (0x2518e3e0, "ptrue", "p0.b"), (0x2558e103, "ptrue", "p3.h, vl8"),
            (0x25d8e3ef, "ptrue", "p15.d"),
            (0x25a11400, "whilelt", "p0.s, x0, x1"),
            (0x256704a3, "whilelt", "p3.h, w5, w7"),
            (0x25eb1d42, "whilelo", "p2.d, x10, x11"),
            (0x25231057, "whilegt", "p7.b, x2, x3"),
            (0x65820020, "fadd", "z0.s, z1.s, z2.s"),
            (0x65c50483, "fsub", "z3.d, z4.d, z5.d"),
            (0x654808e6, "fmul", "z6.h, z7.h, z8.h"),
            (0x05223020, "tbl", "z0.b, { z1.b }, z2.b"),
            (0x25b8c000, "mov", "z0.s, #0x0"),
            (0xa540bd52, "ld1w", "{ z18.s }, p7/z, [x10]"),
            (0xe540eb78, "st1w", "{ z24.s }, p2, [x27]")
        ]
        for (word, name, operands) in cases {
            let actual = decode(word)
            XCTAssertEqual(actual.mnemonic, name, String(word, radix: 16))
            XCTAssertEqual(actual.operands, operands, String(word, radix: 16))
        }
    }

    // Fixed vectors from the retained RX18 check.oracle; no new oracle run.
    func testMatrixOuterProductAndLookupWidths() {
        let cases: [(UInt32, String, String)] = [
            (0x81a1f522, "fmopa", "za2.s, p5/m, p7/m, z9.h, z1.h"),
            (0xc0cc0000, "luti2", "z0.b, zt0, z0[0]"),
            (0xc0cc1000, "luti2", "z0.h, zt0, z0[0]"),
            (0xc0cc2000, "luti2", "z0.s, zt0, z0[0]")
        ]
        for (word, name, operands) in cases {
            let actual = decode(word)
            XCTAssertEqual(actual.mnemonic, name, String(word, radix: 16))
            XCTAssertEqual(actual.operands, operands, String(word, radix: 16))
            XCTAssertEqual(actual.flow, .normal)
            XCTAssertNil(actual.branchTarget)
        }
    }

    func testScalableMemorySignedOffsetBoundaries() {
        let cases: [(UInt32, String, String)] = [
            (0xa547a054, "ld1w", "{ z20.s }, p0/z, [x2, #7, mul vl]"),
            (0xa548a0ac, "ld1w", "{ z12.s }, p0/z, [x5, #-8, mul vl]"),
            (0xe547e031, "st1w", "{ z17.s }, p0, [x1, #7, mul vl]"),
            (0xe548e002, "st1w", "{ z2.s }, p0, [x0, #-8, mul vl]")
        ]
        for (word, name, operands) in cases {
            let actual = decode(word)
            XCTAssertEqual(actual.mnemonic, name, String(word, radix: 16))
            XCTAssertEqual(actual.operands, operands, String(word, radix: 16))
            XCTAssertEqual(actual.flow, .normal)
            XCTAssertNil(actual.branchTarget)
        }
    }

    func testReservedFormsDoNotClaimWords() {
        let decoder = ARM64Decoder()
        for word in [UInt32(0xd503407f), 0xd503417f, 0xc0cc3000, 0x65000000,
                             0x2518e1c0, 0x2518e390, 0xd503201f, 0x91000400] {
            XCTAssertNil(decoder.decodeScalableMatrixExtension(word: word, bytes: [], address: 0))
        }
    }
}
