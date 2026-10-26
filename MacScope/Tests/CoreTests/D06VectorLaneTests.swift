import Foundation
import XCTest
@testable import MacScope

/// General per-row Advanced SIMD lane lifting in the D06 region path, checked
/// on hand-computed lanes and on one real libjpeg-turbo function.
final class D06VectorLaneTests: XCTestCase {
    private typealias Lane = MacIRNEONLaneOp

    func testLaneSemanticsMatchHandComputedLanes() throws {
        let umull = try XCTUnwrap(Lane(kind: .mull, isSigned: false, laneBits: 8, highHalf: false))
        let product = umull.evaluate(n: (0x0807_0605_0403_0201, 0), m: (0x0303_0303_0303_0303, 0))
        XCTAssertEqual(product.low, 0x000c_0009_0006_0003)
        XCTAssertEqual(product.high, 0x0018_0015_0012_000f)

        let umlal2 = try XCTUnwrap(Lane(kind: .mlal, isSigned: false, laneBits: 8, highHalf: true))
        XCTAssertTrue(umlal2.readsDestination)
        let accumulated = umlal2.evaluate(n: (0, .max), m: (0, 0x0101_0101_0101_0101),
                                          oldDestination: (0x0001_0001_0001_0001, 0x0001_0001_0001_0001))
        XCTAssertEqual(accumulated.low, 0x0100_0100_0100_0100)
        XCTAssertEqual(accumulated.high, 0x0100_0100_0100_0100)

        let uaddw = try XCTUnwrap(Lane(kind: .addw, isSigned: false, laneBits: 8, highHalf: false))
        let wrapped = uaddw.evaluate(n: (.max, .max), m: (0x0101_0101_0101_0101, 0))
        XCTAssertEqual(wrapped.low, 0)
        XCTAssertEqual(wrapped.high, 0)

        let ushll2 = try XCTUnwrap(Lane(kind: .shll, isSigned: false, laneBits: 8, highHalf: true))
        let widened = ushll2.evaluate(n: (0, 0x8070_6050_4030_2010))
        XCTAssertEqual(widened.low, 0x0040_0030_0020_0010)
        XCTAssertEqual(widened.high, 0x0080_0070_0060_0050)

        let sshll = try XCTUnwrap(Lane(kind: .shll, isSigned: true, laneBits: 8, highHalf: false))
        XCTAssertEqual(sshll.evaluate(n: (0x80, 0)).low, 0xff80)

        let smull = try XCTUnwrap(Lane(kind: .mull, isSigned: true, laneBits: 16, highHalf: false))
        XCTAssertEqual(smull.evaluate(n: (0xfffe, 0), m: (0x3, 0)).low, 0xffff_fffa)
        let umull32 = try XCTUnwrap(Lane(kind: .mull, isSigned: false, laneBits: 32, highHalf: false))
        XCTAssertEqual(umull32.evaluate(n: (0xffff_ffff, 0), m: (0xffff_ffff, 0)).low, 0xffff_fffe_0000_0001)

        let shrn = try XCTUnwrap(Lane(kind: .shrn, isSigned: false, laneBits: 8, highHalf: false, shift: 2))
        let narrowed = shrn.evaluate(n: (0x0103_0103_0103_0103, 0x0103_0103_0103_0103))
        XCTAssertEqual(narrowed.low, 0x4040_4040_4040_4040)
        XCTAssertEqual(narrowed.high, 0)

        let rshrn2 = try XCTUnwrap(Lane(kind: .rshrn, isSigned: false, laneBits: 8, highHalf: true, shift: 2))
        XCTAssertTrue(rshrn2.readsDestination)
        let rounded = rshrn2.evaluate(n: (0x0002_0002_0002_0002, 0x0002_0002_0002_0002),
                                      oldDestination: (0xdead, 0xffff))
        XCTAssertEqual(rounded.low, 0xdead)
        XCTAssertEqual(rounded.high, 0x0101_0101_0101_0101)
        // Rounding must not overflow the wide lane before narrowing.
        let rshrnEdge = try XCTUnwrap(Lane(kind: .rshrn, isSigned: false, laneBits: 32, highHalf: false, shift: 1))
        XCTAssertEqual(rshrnEdge.evaluate(n: (.max, 0)).low, 0)

        let sub = try XCTUnwrap(Lane(kind: .sub, isSigned: false, laneBits: 16, highHalf: false, activeBytes: 16))
        XCTAssertEqual(sub.evaluate(n: (0x0005, 0), m: (0x0007, 0)).low, 0xfffe)
        let not16 = try XCTUnwrap(Lane(kind: .not, isSigned: false, laneBits: 8, highHalf: false, activeBytes: 16))
        let inverted = not16.evaluate(n: (0x00ff, 0))
        XCTAssertEqual(inverted.low, 0xffff_ffff_ffff_ff00)
        XCTAssertEqual(inverted.high, .max)
        let not8 = try XCTUnwrap(Lane(kind: .not, isSigned: false, laneBits: 8, highHalf: false, activeBytes: 8))
        XCTAssertEqual(not8.evaluate(n: (0, .max)).high, 0)

        XCTAssertNil(Lane(kind: .shrn, isSigned: false, laneBits: 8, highHalf: false, shift: 9))
        XCTAssertNil(Lane(kind: .not, isSigned: false, laneBits: 16, highHalf: false, activeBytes: 16))
        XCTAssertNil(Lane(kind: .mull, isSigned: false, laneBits: 64, highHalf: false))
    }

    func testRowAdmissionUsesExactArrangements() throws {
        func lane(_ mnemonic: String, _ operands: String) -> MacIRBuilder.NEONLaneOperands? {
            MacIRBuilder.neonLaneOperation(mnemonic: mnemonic, operandText: operands)
        }
        let umull = try XCTUnwrap(lane("umull", "v2.8h, v4.8b, v0.8b"))
        XCTAssertEqual(umull.semantics.kind, .mull)
        XCTAssertEqual(umull.destination, "v2")
        XCTAssertEqual(umull.sources, ["v4", "v0"])
        XCTAssertEqual(lane("umull2", "v16.8h, v5.16b, v1.16b")?.semantics.highHalf, true)
        XCTAssertEqual(lane("rshrn2", "v16.16b, v2.8h, #2")?.semantics.shift, 2)
        XCTAssertEqual(lane("ushll", "v6.8h, v4.8b, #0")?.semantics.kind, .shll)
        XCTAssertEqual(lane("uxtl", "v6.8h, v4.8b")?.semantics.kind, .shll)
        XCTAssertEqual(lane("uaddw", "v3.8h, v2.8h, v5.8b")?.semantics.kind, .addw)
        XCTAssertEqual(lane("mvn", "v5.16b, v7.16b")?.semantics.kind, .not)
        XCTAssertEqual(lane("add", "v0.4s, v1.4s, v2.4s")?.semantics.laneBits, 32)
        XCTAssertEqual(lane("sub", "v5.8h, v6.8h, v5.8h")?.semantics.kind, .sub)

        XCTAssertNil(lane("umull", "v2.8h, v4.16b, v0.8b"), "Q source without the 2 suffix")
        XCTAssertNil(lane("umull2", "v2.8h, v4.8b, v0.8b"), "2 suffix with D sources")
        XCTAssertEqual(lane("smlal", "v0.4s, v1.4h, v2.h[3]")?.semantics.elementIndex, 3, "I5 admits indexed long multiplication")
        XCTAssertNil(lane("sqdmull", "v0.4s, v1.4h, v2.4h"))
        XCTAssertNil(lane("uaddlv", "h0, v1.8b"))
        XCTAssertNil(lane("sub", "w10, w1, #0x1"), "scalar rows stay scalar")
        XCTAssertNil(lane("add", "v0.4s, v1.4s, v2.2s"))
        XCTAssertNil(lane("shrn", "v1.8b, v2.8h, #9"))

        let movi = try XCTUnwrap(MacIRBuilder.neonMoveImmediate(mnemonic: "movi", operandText: "v0.8b, #3"))
        XCTAssertEqual(movi.destination, "v0")
        XCTAssertEqual(movi.semantics.low, 0x0303_0303_0303_0303)
        XCTAssertEqual(movi.semantics.high, 0)

        let ldur = try XCTUnwrap(MacIRBuilder.neonPlainQMemory(mnemonic: "ldur", operandText: "q6, [x0, #-0x1]"))
        XCTAssertEqual(ldur, .init(isLoad: true, vector: "v6", base: "x0", offset: -1))
        XCTAssertNil(MacIRBuilder.neonPlainQMemory(mnemonic: "ldr", operandText: "q0, [x1], #16"))
        XCTAssertNil(MacIRBuilder.neonPlainQMemory(mnemonic: "ldr", operandText: "q0, [x1, #16]!"))
        XCTAssertNil(MacIRBuilder.neonPlainQMemory(mnemonic: "ldr", operandText: "q0, [x1, x2]"))
        XCTAssertEqual(MacIRBuilder.neonPlainQMemory(mnemonic: "ldr", operandText: "q0, [sp, #16]"),
                       .init(isLoad: true, vector: "v0", base: "sp", offset: 16), "SP-based Q loads read memory")
        XCTAssertNil(MacIRBuilder.neonPlainQMemory(mnemonic: "str", operandText: "q0, [sp, #16]"),
                     "SP-based Q stores stay with the stack model")
        XCTAssertEqual(MacIRBuilder.neonQWriteback(mnemonic: "ldr", operandText: "q0, [x1, #-0x10]!"),
                       .init(isLoad: true, vector: "v0", base: "x1", offset: -16, writeback: .pre))
        XCTAssertEqual(MacIRBuilder.neonQWriteback(mnemonic: "str", operandText: "q3, [x0], #0x20"),
                       .init(isLoad: false, vector: "v3", base: "x0", offset: 32, writeback: .post))
        XCTAssertNil(MacIRBuilder.neonQWriteback(mnemonic: "ldr", operandText: "q0, [sp], #0x30"),
                     "SP writeback moves the stack coordinate system")
        XCTAssertNil(MacIRBuilder.neonQWriteback(mnemonic: "ldr", operandText: "q0, [x1, #0x10]"))
        // SP-based Q memory goes through the ordinary stack model, not the plain lifters.
        for (mnemonic, operands) in [("str", "q0, [sp, #0x30]"), ("ldr", "q0, [sp], #0x30"),
                                     ("str", "q0, [sp, x2]"), ("stp", "q0, q1, [sp, #0]!")] {
            XCTAssertTrue(MacIRBuilder.isSPBasedQMemory(mnemonic: mnemonic, operandText: operands), operands)
            let fragment = MacIRBuilder().buildFunction(name: "sp_q", startAddress: 0x6000, instructions: [
                InstructionRow(address: 0x6000, bytes: "", mnemonic: mnemonic, operands: operands,
                               hasBreakpoint: false, comment: nil)])
            XCTAssertFalse(fragment.instructions.contains {
                if case .unknown = $0.operation { return true }; return false
            }, "\(mnemonic) \(operands)")
        }
        XCTAssertFalse(MacIRBuilder.isSPBasedQMemory(mnemonic: "str", operandText: "x0, [sp, #0x30]"))
    }

    func testRefusedVectorWriteIsUnavailableUntilNextWrite() {
        var state = BuilderState(parameters: [])
        state.permitsNEONBufferCarrier = true
        let prior = state.writeRegister("v5")
        state.recordUnmodeledDefiniteWrite(for: "v5")
        XCTAssertEqual(state.readRegister("v5"), .unknown("unavailable_v5"))
        XCTAssertEqual(state.readRegister("q5"), .unknown("unavailable_v5"))
        let next = state.writeRegister("v5")
        XCTAssertNotEqual(next, prior)
        XCTAssertEqual(state.readRegister("v5"), next)
    }

    // The 292-byte `_jsimd_h2v1_fancy_upsample_neon` (0x55d08) from Homebrew
    // libjpeg-turbo. A fixed symbol slice keeps the test independent of the
    // local library and avoids a binary-wide decode.
    private let fancyWords: [UInt32] = [
        0x7100_041f, 0x5400_08eb, 0xd280_0008, 0xf940_0069,
        0x5100_042a, 0x531f_782b, 0x5100_056b, 0x2a00_03ec,
        0x0f00_e460, 0x4f00_e461, 0xf868_784d, 0xf868_792e,
        0x3940_01af, 0x3900_01cf, 0x3dc0_01a4, 0x3cc0_11a5,
        0x2e20_c082, 0x2e25_1043, 0x6f08_a4a2, 0x6e21_8082,
        0x2f08_a486, 0x2e20_c0a7, 0x6f08_a484, 0x6e21_c0b0,
        0x6e20_58e5, 0x6e65_84c5, 0x6e20_5a06, 0x6e66_8484,
        0x7100_443f, 0x5400_03e3, 0x5280_0031, 0x5280_0210,
        0x1280_000f, 0x8b30_41a0, 0x3cdf_f006, 0x3dc0_0007,
        0x0f0e_8c70, 0x4f0e_8c50, 0x0f0e_84b1, 0x4f0e_8491,
        0x2e20_c0c2, 0x2e27_1043, 0x6f08_a4e2, 0x6e21_80c2,
        0x2f08_a4c4, 0x2e20_c0e5, 0x6f08_a4c6, 0x6e21_c0e7,
        0x8b31_41d1, 0x4c00_8230, 0x1100_81ef, 0x1100_4210,
        0x6e20_58a5, 0x6e65_8485, 0x6e20_58e4, 0x6e64_84c4,
        0xaa0f_03f1, 0x6b01_021f, 0x54ff_fce3, 0x1400_0002,
        0x5280_002f, 0x0f0e_8c66, 0x4f0e_8c46, 0x0f0e_84a7,
        0x4f0e_8487, 0x8b0f_01cf, 0x4c00_81e6, 0x386a_49ad,
        0x382b_49cd, 0x9100_0508, 0xeb0c_011f, 0x54ff_f861,
        0xd65f_03c0
    ]

    func testFancyUpsampleComposesWideningLanesAcrossLoopJoins() throws {
        let bytes = Data(fancyWords.flatMap { word in
            withUnsafeBytes(of: word.littleEndian) { Array($0) }
        })
        let decoded = ARM64Decoder().decode(bytes, baseAddress: 0x55d08,
            maxInstructionCount: fancyWords.count).map { item in
            InstructionRow(address: item.address, bytes: item.byteText,
                mnemonic: item.mnemonic, operands: item.operands,
                hasBreakpoint: false, comment: item.comment)
        }
        XCTAssertEqual(decoded.count, fancyWords.count)
        XCTAssertFalse(decoded.contains { $0.mnemonic == "unknown" || $0.mnemonic == "unavailable" })
        let function = MacIRBuilder().buildFunction(name: "_jsimd_h2v1_fancy_upsample_neon",
            startAddress: 0x55d08, instructions: decoded)
        XCTAssertFalse(function.instructions.contains {
            if case .unknown = $0.operation { return true }; return false
        }, "every row lifts")

        let umull = try XCTUnwrap(function.instructions.first { $0.source.address == 0x55d48 })
        XCTAssertEqual(umull.neonLaneOp?.kind, .mull)
        let rshrn2 = try XCTUnwrap(function.instructions.first { $0.source.address == 0x55d9c })
        guard case let .intrinsic(_, _, arguments) = rshrn2.operation else { return XCTFail("rshrn2") }
        XCTAssertEqual(arguments.count, 2, "source plus preserved old low half")

        let ldur = try XCTUnwrap(function.instructions.first { $0.source.address == 0x55d90 })
        XCTAssertEqual(ldur.memoryAccess?.byteWidth, 16)
        guard case let .load(_, .binaryExpression("-", _, .immediate(1))) = ldur.operation else {
            return XCTFail("ldur q6, [x0, #-1] address")
        }

        // v2..v5 are carried around the inner loop: the header joins them.
        let headerVectorPhis = function.phis.filter { $0.blockAddress == 0x55d8c && $0.bitWidth == 128 }
        XCTAssertFalse(headerVectorPhis.isEmpty)
        for phi in headerVectorPhis {
            XCTAssertEqual(phi.incoming.count, 2)
            XCTAssertFalse(phi.incoming.contains {
                if case .unknown = $0.value { return true }; return false
            })
        }

        let text = PseudocodePrinter(options: DecompilerOptions(
            structureControlFlow: true, deadCodeElimination: false,
            nopElision: false, functionSizeGate: 1_024
        )).print(function: function).text
        XCTAssertFalse(text.contains("__unknown"), text)
        XCTAssertFalse(text.contains("__unavailable_cfg_phi"), text)
        XCTAssertTrue(text.contains("__neon_umull_8h_from_8b("), text)
        XCTAssertTrue(text.contains("__neon_rshrn2_16b_from_8h_shift2_keep_low64("), text)
        XCTAssertTrue(text.contains("const __uint128_t __edge_"), text)
    }

    func testVectorMultiplyAccumulateDecodesAndEvaluates() throws {
        func text(_ word: UInt32) -> String {
            let data = Data(withUnsafeBytes(of: word.littleEndian) { Array($0) })
            let item = ARM64Decoder().decode(data, baseAddress: 0x1000, maxInstructionCount: 1)[0]
            return "\(item.mnemonic) \(item.operands)"
        }
        // Apple llvm-objdump: mla.8h v5, v4, v2 / mls.8h v5, v4, v2 / mla.8b; .2d reserved.
        XCTAssertEqual(text(0x4e62_9485), "mla v5.8h, v4.8h, v2.8h")
        XCTAssertEqual(text(0x6e62_9485), "mls v5.8h, v4.8h, v2.8h")
        XCTAssertEqual(text(0x0e22_9485), "mla v5.8b, v4.8b, v2.8b")
        XCTAssertEqual(text(0x4ee2_9485).split(separator: " ").first, "unknown")

        let mla = try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: "mla", operandText: "v5.8h, v4.8h, v2.8h"))
        XCTAssertEqual(mla.semantics.kind, .mla)
        XCTAssertTrue(mla.semantics.readsDestination)
        XCTAssertEqual(MacIRBuilder.neonLaneOperation(mnemonic: "mla", operandText: "v0.8h, v1.8h, v2.h[3]")?
            .semantics.elementIndex, 3, "by-element MLA uses one lane of Vm")
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "mul", operandText: "x0, x1, x2"))
        XCTAssertNil(Lane(kind: .mul, isSigned: false, laneBits: 64, highHalf: false, activeBytes: 16))
        // lanes: 3 * 7 + 1 = 22; 1 - 3 * 7 wraps to 0xffec.
        let accumulate = try XCTUnwrap(Lane(kind: .mla, isSigned: false, laneBits: 16, highHalf: false, activeBytes: 16))
        XCTAssertEqual(accumulate.evaluate(n: (0x3, 0), m: (0x7, 0), oldDestination: (0x1, 0)).low, 22)
        let subtract = try XCTUnwrap(Lane(kind: .mls, isSigned: false, laneBits: 16, highHalf: false, activeBytes: 8))
        let wrapped = subtract.evaluate(n: (0x3, 0), m: (0x7, 0), oldDestination: (0x1, .max))
        XCTAssertEqual(wrapped.low, 0xffec)
        XCTAssertEqual(wrapped.high, 0, "64-bit form zeroes the upper half")
    }

    // The 668-byte `_jsimd_h2v2_fancy_upsample_neon` (0x55e2c, through its RET) from Homebrew
    // libjpeg-turbo, fixed as a symbol slice.
    private let fancy2Words: [UInt32] = [
        0x7100_040d, 0x5400_14ab, 0xa9bf_4ff4, 0xd280_0008,
        0xd280_0009, 0xf940_006a, 0x5100_042b, 0x531f_782c,
        0x5100_058c, 0x5301_7dad, 0x1100_05ad, 0x0f00_e460,
        0x4f00_e461, 0x4f00_8462, 0x4f00_84e3, 0x8b09_0c4e,
        0xa97f_bdd1, 0x9100_0529, 0xf869_7850, 0x8b08_0d4e,
        0xa940_39c0, 0x3940_01e3, 0x0b03_0463, 0x3940_0224,
        0x0b04_0063, 0x531e_7463, 0x1100_2063, 0x5304_7c64,
        0xaa00_03e3, 0x381f_f464, 0x3940_01e4, 0x0b04_0484,
        0x3940_0205, 0x0b05_0084, 0x531e_7484, 0x1100_2084,
        0x5304_7c85, 0xaa0e_03e4, 0x381f_f485, 0x3dc0_0224,
        0x3dc0_01e5, 0x3dc0_0206, 0x2e20_c0a7, 0x2e24_10f0,
        0x6f08_a484, 0x6e21_80a4, 0x2e26_10e7, 0x6f08_a4c6,
        0x6e21_80a6, 0x3cc0_1225, 0x3cc0_11f1, 0x3cc0_1212,
        0x2e20_c233, 0x2e25_1274, 0x6f08_a4a5, 0x6e21_8225,
        0x2e32_1273, 0x6f08_a652, 0x6e21_8232, 0x4eb0_1e11,
        0x4e62_9691, 0x4ea4_1c95, 0x4e62_94b5, 0x4ea7_1cf6,
        0x4e62_9676, 0x4ea6_1cd7, 0x4e62_9657, 0x4e62_9614,
        0x4e62_9485, 0x4e63_84a4, 0x4e63_8685, 0x0f0c_84b8,
        0x4f0c_8498, 0x0f0c_8e39, 0x4f0c_8eb9, 0x4e62_94f3,
        0x4e62_94d2, 0x4e63_8644, 0x4e63_8665, 0x0f0c_84a5,
        0x4f0c_8485, 0x0f0c_8ec6, 0x4f0c_8ee6, 0x9100_0405,
        0x4c00_80b8, 0x9100_05c5, 0x4c00_80a5, 0x7100_443f,
        0x5400_0743, 0x5280_0205, 0x5280_0406, 0x8b25_4227,
        0x3cdf_f0e4, 0x8b25_41f3, 0x3cdf_f265, 0x8b25_4214,
        0x3cdf_f286, 0x2e20_c0a7, 0x2e24_10f0, 0x6f08_a484,
        0x6e21_80a4, 0x2e26_10e7, 0x6f08_a4c6, 0x6e21_80a6,
        0x3dc0_00e5, 0x3dc0_0271, 0x3dc0_0292, 0x2e20_c233,
        0x2e25_1274, 0x6f08_a4a5, 0x6e21_8225, 0x2e32_1273,
        0x6f08_a652, 0x6e21_8232, 0x4eb0_1e11, 0x4e62_9691,
        0x4ea4_1c95, 0x4e62_94b5, 0x4ea7_1cf6, 0x4e62_9676,
        0x4ea6_1cd7, 0x4e62_9657, 0x4e62_9614, 0x4e62_9485,
        0x4e63_84a4, 0x4e63_8685, 0x0f0c_84b8, 0x4f0c_8498,
        0x0f0c_8e39, 0x4f0c_8eb9, 0x4e62_94f3, 0x4e62_94d2,
        0x4e63_8644, 0x4e63_8665, 0x0f0c_84a5, 0x4f0c_8485,
        0x0f0c_8ec6, 0x8b26_4067, 0x4c00_80f8, 0x4f0c_8ee6,
        0x8b26_4087, 0x4c00_80e5, 0x1100_40a5, 0x1100_80c6,
        0x6b01_00bf, 0x54ff_f943, 0x9100_0908, 0x386b_49e3,
        0x0b03_0463, 0x386b_4a31, 0x0b11_0071, 0x531e_7631,
        0x1100_1e31, 0x5304_7e31, 0x382c_4811, 0x386b_49ef,
        0x0b0f_05ef, 0x386b_4a10, 0x0b10_01ef, 0x531e_75ef,
        0x1100_1def, 0x5304_7def, 0x382c_49cf, 0xeb0d_013f,
        0x54ff_ed61, 0xa8c1_4ff4, 0xd65f_03c0
    ]

    func testTwoRowFancyUpsampleLiftsVectorMultiplyAccumulate() throws {
        let bytes = Data(fancy2Words.flatMap { word in
            withUnsafeBytes(of: word.littleEndian) { Array($0) }
        })
        let decoded = ARM64Decoder().decode(bytes, baseAddress: 0x55e2c,
            maxInstructionCount: fancy2Words.count).map { item in
            InstructionRow(address: item.address, bytes: item.byteText,
                mnemonic: item.mnemonic, operands: item.operands,
                hasBreakpoint: false, comment: item.comment)
        }
        XCTAssertEqual(decoded.count, fancy2Words.count)
        XCTAssertFalse(decoded.contains { $0.mnemonic == "unknown" || $0.mnemonic == "unavailable" })
        let function = MacIRBuilder().buildFunction(name: "_jsimd_h2v2_fancy_upsample_neon",
            startAddress: 0x55e2c, instructions: decoded)
        XCTAssertFalse(function.instructions.contains {
            if case .unknown = $0.operation { return true }; return false
        })
        XCTAssertTrue(function.instructions.contains { $0.neonLaneOp?.kind == .mla })

        // One undecodable word: its writes are unknowable, so the region path
        // must not compose vector dataflow around it.
        var withReserved = decoded
        let index = try XCTUnwrap(withReserved.firstIndex { $0.mnemonic == "mla" })
        let original = withReserved[index]
        withReserved[index] = InstructionRow(address: original.address, bytes: original.bytes,
            mnemonic: "unknown", operands: "0x4ee29485", hasBreakpoint: false, comment: nil)
        let refused = MacIRBuilder(ssaEnabled: false).buildFunction(name: "reserved_word", startAddress: 0x55e2c,
                                                   instructions: withReserved)
        XCTAssertFalse(refused.instructions.contains { $0.neonLaneOp != nil })

        // Ordinary SSA may model other exact rows after region admission fails.
        // The undecodable row itself must remain unknown, never a typed lane.
        let ssaRefused = MacIRBuilder(ssaEnabled: true).buildFunction(name: "reserved_word_ssa",
            startAddress: 0x55e2c, instructions: withReserved)
        XCTAssertTrue(ssaRefused.ssaEnabled)
        XCTAssertTrue(ssaRefused.instructions.contains {
            guard $0.source.address == original.address else { return false }
            if case .unknown = $0.operation { return true }; return false
        })
        XCTAssertFalse(ssaRefused.instructions.contains {
            $0.source.address == original.address && $0.neonLaneOp != nil
        })
        let admitted = ssaRefused.instructions.filter { $0.neonLaneOp != nil }
        XCTAssertFalse(admitted.isEmpty)
        for instruction in admitted {
            let descriptor = try XCTUnwrap(MacIRBuilder.ssaIntegerLaneOperation(
                mnemonic: instruction.source.mnemonic, operands: instruction.source.operands))
            XCTAssertEqual(instruction.neonLaneOp, descriptor.semantics)
        }
    }

    func testUnaryCompareShiftAndPermuteLanes() throws {
        func text(_ word: UInt32) -> String {
            let data = Data(withUnsafeBytes(of: word.littleEndian) { Array($0) })
            let item = ARM64Decoder().decode(data, baseAddress: 0x1000, maxInstructionCount: 1)[0]
            return "\(item.mnemonic) \(item.operands)"
        }
        // Apple llvm-objdump: ushl.8h v3, v3, v4 (real quantize word) / sshl.8h; .1d reserved.
        XCTAssertEqual(text(0x6e64_4463), "ushl v3.8h, v3.8h, v4.8h")
        XCTAssertEqual(text(0x4e64_4463), "sshl v3.8h, v3.8h, v4.8h")
        XCTAssertEqual(text(0x0ee4_4463).split(separator: " ").first, "unknown")

        func lane(_ mnemonic: String, _ operands: String) throws -> MacIRBuilder.NEONLaneOperands {
            try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: mnemonic, operandText: operands),
                          "\(mnemonic) \(operands)")
        }
        XCTAssertEqual(try lane("cmlt", "v27.8h, v3.8h, #0").semantics.kind, .cmltz)
        XCTAssertEqual(try lane("cmlt", "v27.8h, v3.8h, #0").sources, ["v3"])
        // Arm ISA_A64 2025-12, CMGT_advsimd_reg Operation compares signed
        // corresponding lanes from both source registers, producing ones or zero.
        let registerCompare = try lane("cmgt", "v0.8h, v1.8h, v2.8h")
        XCTAssertEqual(registerCompare.semantics.kind, .cmgt)
        XCTAssertEqual(registerCompare.sources, ["v1", "v2"])
        XCTAssertEqual(try lane("neg", "v4.8h, v20.8h").semantics.kind, .neg)
        XCTAssertEqual(try lane("abs", "v0.8h, v0.8h").semantics.kind, .abs)
        XCTAssertEqual(try lane("uzp2", "v0.8h, v16.8h, v0.8h").sources, ["v16", "v0"])
        XCTAssertEqual(try lane("ushl", "v0.8h, v0.8h, v4.8h").semantics.kind, .ushl)
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "neg", operandText: "x0, x1"))

        func op(_ kind: Lane.Kind, _ bits: Int = 16) throws -> Lane {
            try XCTUnwrap(Lane(kind: kind, isSigned: false, laneBits: bits, highHalf: false, activeBytes: 16))
        }
        // 16-bit lanes, low half: [5, 0xfffb (-5), 0, 0x8000]
        let x: Lane.Vector = (0x8000_0000_fffb_0005, 0)
        XCTAssertEqual(try op(.neg).evaluate(n: x).low, 0x8000_0000_0005_fffb)
        XCTAssertEqual(try op(.abs).evaluate(n: x).low, 0x8000_0000_0005_0005, "abs(INT16_MIN) wraps")
        XCTAssertEqual(try op(.cmltz).evaluate(n: x).low, 0xffff_0000_ffff_0000)
        XCTAssertEqual(try op(.cmeqz).evaluate(n: x).low & 0xffff_ffff_ffff, 0xffff_0000_0000)
        // Shift counts come from the signed low byte: +2, -2, +16 (clears), 0x7f00 lane uses 0x00.
        let counts: Lane.Vector = (0x7f00_0010_00fe_0002, 0)
        let lanes: Lane.Vector = (0x0003_0003_8000_0003, 0)
        XCTAssertEqual(try op(.ushl).evaluate(n: lanes, m: counts).low, 0x0003_0000_2000_000c)
        XCTAssertEqual(try op(.sshl).evaluate(n: lanes, m: counts).low, 0x0003_0000_e000_000c)
        // Permutes over 8 lanes of 16 bits: n = 0..7, m = 8..15.
        let n: Lane.Vector = (0x0003_0002_0001_0000, 0x0007_0006_0005_0004)
        let m: Lane.Vector = (0x000b_000a_0009_0008, 0x000f_000e_000d_000c)
        let uzp2 = try op(.uzp2).evaluate(n: n, m: m)
        XCTAssertEqual(uzp2.low, 0x0007_0005_0003_0001)
        XCTAssertEqual(uzp2.high, 0x000f_000d_000b_0009)
        XCTAssertEqual(try op(.zip1).evaluate(n: n, m: m).low, 0x0009_0001_0008_0000)
        XCTAssertEqual(try op(.trn2).evaluate(n: n, m: m).low, 0x000b_0003_0009_0001)
    }

    // The 404-byte branch-free `_jsimd_quantize_neon` (0x5799c), through RET.
    private let quantizeWords: [UInt32] = [
        0xad40_0440, 0xad41_0c42, 0xad40_1424, 0xad41_1c26,
        0xad44_4430, 0xad45_4c32, 0xad4c_5434, 0xad4d_5c36,
        0x4e60_a818, 0x4e60_a839, 0x4e60_a85a, 0x4e60_a87b,
        0x4e60_b800, 0x4e60_b821, 0x4e60_b842, 0x4e60_b863,
        0x4e70_8400, 0x4e71_8421, 0x4e72_8442, 0x4e73_8463,
        0x2e64_c010, 0x6e64_c000, 0x2e65_c024, 0x6e65_c021,
        0x2e66_c045, 0x6e66_c042, 0x2e67_c066, 0x6e67_c063,
        0x4e40_5a00, 0x4e41_5881, 0x4e42_58a2, 0x4e43_58c3,
        0x6e60_ba84, 0x6e64_4400, 0x6e60_baa4, 0x6e64_4421,
        0x6e60_bac4, 0x6e64_4442, 0x6e60_bae4, 0x6e64_4463,
        0x6e38_1c00, 0x6e78_8400, 0x6e39_1c21, 0x6e79_8421,
        0x6e3a_1c42, 0x6e7a_8442, 0x6e3b_1c63, 0x6e7b_8463,
        0xad00_0400, 0xad01_0c02, 0xad42_0440, 0xad43_0c42,
        0xad42_1424, 0xad43_1c26, 0xad46_4430, 0xad47_4c32,
        0xad4e_5434, 0xad4f_5c36, 0x4e60_a818, 0x4e60_a839,
        0x4e60_a85a, 0x4e60_a87b, 0x4e60_b800, 0x4e60_b821,
        0x4e60_b842, 0x4e60_b863, 0x4e70_8400, 0x4e71_8421,
        0x4e72_8442, 0x4e73_8463, 0x2e64_c010, 0x6e64_c000,
        0x2e65_c024, 0x6e65_c021, 0x2e66_c045, 0x6e66_c042,
        0x2e67_c066, 0x6e67_c063, 0x4e40_5a00, 0x4e41_5881,
        0x4e42_58a2, 0x4e43_58c3, 0x6e60_ba84, 0x6e64_4400,
        0x6e60_baa4, 0x6e64_4421, 0x6e60_bac4, 0x6e64_4442,
        0x6e60_bae4, 0x6e64_4463, 0x6e38_1c00, 0x6e78_8400,
        0x6e39_1c21, 0x6e79_8421, 0x6e3a_1c42, 0x6e7a_8442,
        0x6e3b_1c63, 0xad02_0400, 0x6e7b_8460, 0xad03_0002,
        0xd65f_03c0
    ]

    private func rows(_ words: [UInt32], at base: UInt64) -> [InstructionRow] {
        let bytes = Data(words.flatMap { word in withUnsafeBytes(of: word.littleEndian) { Array($0) } })
        return ARM64Decoder().decode(bytes, baseAddress: base, maxInstructionCount: words.count).map { item in
            InstructionRow(address: item.address, bytes: item.byteText, mnemonic: item.mnemonic,
                           operands: item.operands, hasBreakpoint: false, comment: item.comment)
        }
    }

    func testBranchFreeQuantizeLiftsEveryRowAndTypesQPairs() throws {
        let decoded = rows(quantizeWords, at: 0x5799c)
        XCTAssertEqual(decoded.count, quantizeWords.count)
        XCTAssertFalse(decoded.contains { $0.mnemonic == "unknown" || $0.mnemonic == "unavailable" })
        XCTAssertTrue(MacIRBuilder.isBranchFreeVectorLeaf(decoded))
        let function = MacIRBuilder().buildFunction(name: "_jsimd_quantize_neon",
                                                    startAddress: 0x5799c, instructions: decoded)
        XCTAssertFalse(function.instructions.contains {
            if case .unknown = $0.operation { return true }; return false
        })
        let pairLoad = try XCTUnwrap(function.instructions.first { $0.source.address == 0x5799c })
        XCTAssertEqual(pairLoad.memoryAccess?.byteWidth, 16)
        guard case .intrinsic(nil, "restore_pair", let arguments) = pairLoad.operation else {
            return XCTFail("ldp q0, q1 must be a typed Q pair")
        }
        XCTAssertEqual(arguments.count, 3)
        for kind: Lane.Kind in [.uzp2, .ushl, .neg, .abs, .cmltz, .mull] {
            XCTAssertTrue(function.instructions.contains { $0.neonLaneOp?.kind == kind }, "\(kind)")
        }
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertFalse(text.contains("__unknown"), text)
        XCTAssertTrue(text.contains("*(__uint128_t *)("), text)
        XCTAssertFalse(text.contains("restores register pair"), "Q data pairs are not register saves")
    }

    /// Purely scalar branch-free leaves, and branch-free leaves with any scalar
    /// arithmetic row, stay with the ordinary builder unchanged.
    func testScalarAndArithmeticBranchFreeLeavesStayOrdinary() {
        func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
            InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
                           hasBreakpoint: false, comment: nil)
        }
        // Scalar-only: an exact ordinary-builder sequence rewrite (x * 0xcccccccd >> 34 == x / 5)
        // must still be recovered, which the region path never performs.
        let scalar = [row(0x1000, "mov", "w8, #52429"), row(0x1004, "movk", "w8, #52428, lsl #16"),
                      row(0x1008, "umull", "x8, w0, w8"), row(0x100c, "lsr", "x0, x8, #34"),
                      row(0x1010, "ret", "")]
        XCTAssertFalse(MacIRBuilder.attemptsGeneralVectorRegion(scalar))
        let scalarFunction = MacIRBuilder().buildFunction(name: "div5", startAddress: 0x1000, instructions: scalar)
        guard case .assign(_, .unary("(uint64_t)", .binaryExpression("/", _, .unary("(uint32_t)", .immediate(5))))) =
                scalarFunction.instructions[3].operation else {
            return XCTFail("ordinary builder reciprocal recovery must still apply: \(scalarFunction.instructions[3].operation)")
        }
        XCTAssertFalse(scalarFunction.instructions.contains { $0.neonLaneOp != nil })

        // A vector row plus one scalar arithmetic row: not a branch-free vector leaf.
        let mixed = [row(0x2000, "ldr", "q0, [x1]"), row(0x2004, "add", "x0, x0, #0x1"),
                     row(0x2008, "neg", "v1.8h, v0.8h"), row(0x200c, "str", "q1, [x1]"),
                     row(0x2010, "ret", "")]
        XCTAssertFalse(MacIRBuilder.isBranchFreeVectorLeaf(mixed))
        XCTAssertFalse(MacIRBuilder.attemptsGeneralVectorRegion(mixed))
        let mixedFunction = MacIRBuilder().buildFunction(name: "mixed", startAddress: 0x2000, instructions: mixed)
        XCTAssertFalse(mixedFunction.instructions.contains { $0.neonLaneOp != nil },
                       "the ordinary builder has no per-row lane lifting")

        // The same leaf without the arithmetic row is claimed.
        let vectorOnly = [row(0x2000, "ldr", "q0, [x1]"), row(0x2004, "neg", "v1.8h, v0.8h"),
                          row(0x2008, "str", "q1, [x1]"), row(0x200c, "ret", "")]
        XCTAssertTrue(MacIRBuilder.isBranchFreeVectorLeaf(vectorOnly), "vector-only leaf admission")
        // A one-row vector fragment (no RET) lifts per row; a scalar one stays ordinary.
        let fragment = MacIRBuilder().buildFunction(name: "fragment", startAddress: 0x4000,
                                                    instructions: [row(0x4000, "ldr", "q0, [sp, #0x30]")])
        XCTAssertEqual(fragment.instructions.first?.memoryAccess?.byteWidth, 16)
        guard case .load = fragment.instructions.first?.operation else {
            return XCTFail("Q load fragment must be a typed load")
        }
        XCTAssertFalse(MacIRBuilder.isBranchFreeVectorLeaf([row(0x4000, "ldr", "x0, [x1]")]))
        let vectorFunction = MacIRBuilder().buildFunction(name: "vector", startAddress: 0x2000, instructions: vectorOnly)
        XCTAssertTrue(vectorFunction.instructions.contains { $0.neonLaneOp?.kind == .neg },
                      vectorFunction.instructions.map { "\($0.source.address): \($0.operation)" }.joined(separator: "\n"))
    }

    /// The A64 concrete evaluator executes lifted lane ops; expected lanes are
    /// computed here from plain arrays, independent of MacIRNEONLaneOp.evaluate.
    func testConcreteEvaluatorExecutesLiftedLaneOps() throws {
        func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
            InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
                           hasBreakpoint: false, comment: nil)
        }
        let rows = [
            row(0x3000, "umull", "v2.8h, v4.8b, v0.8b"),
            row(0x3004, "mla", "v2.8h, v5.8h, v6.8h"),
            row(0x3008, "uzp2", "v3.8h, v2.8h, v5.8h"),
            row(0x300c, "ushl", "v3.8h, v3.8h, v7.8h"),
            row(0x3010, "rshrn2", "v3.16b, v2.8h, #2"),
            row(0x3014, "cmlt", "v1.8h, v3.8h, #0"),
            row(0x3018, "ret", ""),
        ]
        let function = MacIRBuilder().buildFunction(name: "lanes", startAddress: 0x3000, instructions: rows)
        XCTAssertEqual(function.instructions.filter { $0.neonLaneOp != nil }.count, 6)

        func bytes(_ v: A64MachineState.V128) -> [UInt64] { (0..<16).map { (($0 < 8 ? v.low : v.high) >> UInt64(($0 % 8) * 8)) & 0xff } }
        func halves(_ v: A64MachineState.V128) -> [UInt64] { (0..<8).map { (($0 < 4 ? v.low : v.high) >> UInt64(($0 % 4) * 16)) & 0xffff } }
        func fromHalves(_ h: [UInt64]) -> A64MachineState.V128 {
            var v = A64MachineState.V128(low: 0, high: 0)
            for (i, lane) in h.enumerated() {
                if i < 4 { v.low |= (lane & 0xffff) << UInt64(i * 16) } else { v.high |= (lane & 0xffff) << UInt64((i - 4) * 16) }
            }
            return v
        }
        var state = try A64MachineState(seeding: try JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
        state.v[0] = .init(low: 0x0303_0303_0303_0303, high: 0)
        state.v[4] = .init(low: 0x80ff_7f40_2010_0201, high: 0x1111_1111_1111_1111)
        state.v[5] = .init(low: 0x0004_0003_0002_0001, high: 0x0008_0007_0006_0005)
        state.v[6] = .init(low: 0x0100_0010_0002_ffff, high: 0x0003_0003_0003_0003)
        state.v[7] = .init(low: 0x00fe_0001_00ff_0002, high: 0x0010_0000_00f0_0003)
        state.v[3] = .init(low: 0xdead_beef_0bad_f00d, high: 0)
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        try evaluator.run(function.instructions)
        let out = evaluator.state

        // umull then mla: v2 = v4.8b * v0.8b + v5 * v6 (16-bit lanes, wrapping).
        let b4 = bytes(state.v[4]), b0 = bytes(state.v[0])
        let h5 = halves(state.v[5]), h6 = halves(state.v[6])
        let v2 = (0..<8).map { (b4[$0] * b0[$0] + h5[$0] * h6[$0]) & 0xffff }
        XCTAssertEqual(halves(out.v[2]), v2)
        // uzp2 (odd lanes of v2 then v5), then ushl by the signed low byte of v7.
        let odd = [v2[1], v2[3], v2[5], v2[7], h5[1], h5[3], h5[5], h5[7]]
        let counts = halves(state.v[7]).map { Int(Int8(truncatingIfNeeded: $0)) }
        let shifted = zip(odd, counts).map { lane, c -> UInt64 in
            c >= 16 || c <= -16 ? 0 : c >= 0 ? (lane << UInt64(c)) & 0xffff : lane >> UInt64(-c)
        }
        // rshrn2: high 8 bytes = round(v2 / 4) narrowed; low 8 bytes keep shifted's low half.
        let low = fromHalves(shifted).low
        var high: UInt64 = 0
        for (i, lane) in v2.enumerated() { high |= (((lane + 2) >> 2) & 0xff) << UInt64(i * 8) }
        XCTAssertEqual(out.v[3], .init(low: low, high: high))
        // cmlt #0 on v3's 16-bit lanes.
        let v1 = halves(out.v[3]).map { $0 & 0x8000 != 0 ? UInt64(0xffff) : 0 }
        XCTAssertEqual(halves(out.v[1]), v1)
    }

    /// PC-relative constant loads and D views inside a branch-free vector leaf.
    func testAdrpConstantAndDViewLoadShareTheVectorCarrier() throws {
        func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
            InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
                           hasBreakpoint: false, comment: nil)
        }
        let rows = [
            row(0x7000, "adrp", "x9, 0x5a000"),
            row(0x7004, "ldr", "d0, [x9, #0x620]"),
            row(0x7008, "add", "v1.8h, v0.8h, v0.8h"),
            row(0x700c, "str", "q1, [x0]"),
            row(0x7010, "ret", ""),
        ]
        XCTAssertTrue(MacIRBuilder.isBranchFreeVectorLeaf(rows))
        let function = MacIRBuilder().buildFunction(name: "constant", startAddress: 0x7000, instructions: rows)
        XCTAssertFalse(function.instructions.contains {
            if case .unknown = $0.operation { return true }; return false
        }, function.instructions.map { "\($0.operation)" }.joined(separator: "\n"))
        // The D-view load writes v0, which the vector add then reads.
        let load = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7004 })
        guard case let .load(destination, _) = load.operation,
              case .register(name: "v0", _) = destination else { return XCTFail("\(load.operation)") }
        let add = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7008 })
        guard case let .intrinsic(_, _, arguments) = add.operation else { return XCTFail("add") }
        XCTAssertEqual(arguments.first, destination)

        // A scalar FP arithmetic row on a D view still keeps the region out.
        let scalarFP = [row(0x8000, "ldr", "q0, [x1]"), row(0x8004, "fadd", "d1, d0, d0"),
                        row(0x8008, "str", "q0, [x1]"), row(0x800c, "ret", "")]
        let ordinary = MacIRBuilder().buildFunction(name: "scalar_fp", startAddress: 0x8000, instructions: scalarFP)
        XCTAssertFalse(ordinary.instructions.contains { $0.neonLaneOp != nil })
        XCTAssertFalse(MacIRBuilder.isBranchFreeVectorLeaf([row(0x9000, "adrp", "x9, 0x5a000"),
                                                           row(0x9004, "ret", "")]),
                       "PC-relative rows alone are not a vector leaf")
        // The :lo12 half of an ADRP pair is address formation; any other add is arithmetic.
        let paired = [row(0xd000, "adrp", "x8, 0x5a000"), row(0xd004, "add", "x8, x8, #0x630"),
                      row(0xd008, "ldr", "q0, [x8]"), row(0xd00c, "str", "q0, [x0]"), row(0xd010, "ret", "")]
        XCTAssertTrue(MacIRBuilder.isBranchFreeVectorLeaf(paired))
        let pairedFunction = MacIRBuilder().buildFunction(name: "paired", startAddress: 0xd000, instructions: paired)
        XCTAssertFalse(pairedFunction.instructions.contains {
            if case .unknown = $0.operation { return true }; return false
        })
        for other in [[row(0xe000, "add", "x8, x1, #0x630")],
                      [row(0xe000, "adrp", "x8, 0x5a000"), row(0xe004, "mov", "x8, x1"), row(0xe008, "add", "x8, x8, #0x10")],
                      [row(0xe000, "adrp", "x8, 0x5a000"), row(0xe004, "add", "x8, x8, #0x1000")]] {
            let rows = other + [row(0xe010, "ldr", "q0, [x8]"), row(0xe014, "ret", "")]
            XCTAssertFalse(MacIRBuilder.isBranchFreeVectorLeaf(rows), "\(other.map(\.operands))")
        }
        // An unsupported vector row does not keep the leaf out; it is refused alone.
        let partial = [row(0xa000, "ldr", "q0, [x1]"), row(0xa004, "ld4", "{v1.8h, v2.8h, v3.8h, v4.8h}, [x2]"),
                       row(0xa008, "add", "v5.8h, v0.8h, v0.8h"), row(0xa00c, "ret", "")]
        XCTAssertTrue(MacIRBuilder.isBranchFreeVectorLeaf(partial))
        let lifted = MacIRBuilder().buildFunction(name: "partial", startAddress: 0xa000, instructions: partial)
        XCTAssertTrue(lifted.instructions.contains { $0.neonLaneOp?.kind == .add })
        XCTAssertTrue(lifted.instructions.contains {
            guard $0.source.address == 0xa004, case .unknown = $0.operation else { return false }
            return true
        })
    }

    func testBySaturatingDoublingMultiplyHighAndQCPrinting() throws {
        // (2 * 0x4000 * 0x4000) >> 16 = 0x2000; MIN * MIN saturates to 0x7fff and sets QC.
        let op = try XCTUnwrap(Lane(kind: .sqdmulh, isSigned: false, laneBits: 16, highHalf: false,
                                    activeBytes: 16, elementIndex: 2))
        let m: Lane.Vector = (0x0000_8000_0000_0000, 0)          // lane 2 = 0x8000
        let n: Lane.Vector = (0x0000_0000_8000_4000, 0)          // lanes: 0x4000, 0x8000
        let out = op.evaluate(n: n, m: m)
        XCTAssertEqual(out.low & 0xffff_ffff, 0x7fff_c000, "0x4000 * MIN -> -0x4000; MIN * MIN -> MAX")
        XCTAssertTrue(op.saturates(n: n, m: m))
        XCTAssertFalse(op.saturates(n: (0x4000, 0), m: m))
        let plain = try XCTUnwrap(Lane(kind: .sqdmulh, isSigned: false, laneBits: 16, highHalf: false, activeBytes: 16))
        XCTAssertEqual(plain.evaluate(n: (0x4000, 0), m: (0x4000, 0)).low, 0x2000)

        let parsed = try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: "sqdmulh", operandText: "v0.8h, v4.8h, v0.h[2]"))
        XCTAssertEqual(parsed.semantics.kind, .sqdmulh)
        XCTAssertEqual(parsed.semantics.elementIndex, 2)
        XCTAssertEqual(parsed.sources, ["v4", "v0"])
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "sqdmulh", operandText: "v0.8h, v4.8h, v0.s[1]"))

        func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
            InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
                           hasBreakpoint: false, comment: nil)
        }
        let body = [row(0xb000, "ldr", "q4, [x1]"), row(0xb004, "ldr", "q0, [x2]"),
                    row(0xb008, "sqdmulh", "v0.8h, v4.8h, v0.h[2]"), row(0xb00c, "str", "q0, [x1]")]
        let silent = MacIRBuilder().buildFunction(name: "silent", startAddress: 0xb000,
                                                  instructions: body + [row(0xb010, "ret", "")])
        XCTAssertTrue(silent.instructions.contains { $0.neonLaneOp?.setsQC == true }, "QC effect stays in the IR")
        XCTAssertFalse(PseudocodePrinter().print(function: silent).text.contains("__neon_qc"))
        let observed = MacIRBuilder().buildFunction(name: "observed", startAddress: 0xb000,
            instructions: body + [row(0xb010, "mrs", "x0, fpsr"), row(0xb014, "ret", "")])
        XCTAssertTrue(observed.observesFPSR)
        let text = PseudocodePrinter().print(function: observed).text
        XCTAssertTrue(text.contains("__neon_qc |= __neon_sqdmulh_8h_by_lane2_saturates("), text)

        // The evaluator sets sticky FPSR.QC on saturation.
        var state = try A64MachineState(seeding: try JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
        state.v[4] = .init(low: 0x8000, high: 0)
        state.v[0] = .init(low: 0x0000_8000_0000_0000, high: 0)
        let direct = MacIRBuilder().buildFunction(name: "direct", startAddress: 0xc000, instructions: [
            row(0xc000, "sqdmulh", "v0.8h, v4.8h, v0.h[2]"), row(0xc004, "ret", "")])
        let lane = try XCTUnwrap(direct.instructions.first { $0.neonLaneOp != nil })
        var evaluator = MacIRConcreteEvaluator(function: direct, state: state)
        try evaluator.run([lane])
        XCTAssertEqual(evaluator.state.fpsr & (1 << 27), 1 << 27)
        XCTAssertEqual(evaluator.state.v[0].low & 0xffff, 0x7fff)
    }

    func testSaturatingNarrowRoundingMultiplyDupAndMvni() throws {
        // sqrdmulh: (2*0x4000*0x2000 + 0x8000) >> 16 = 0x1000; MIN*MIN saturates.
        let rd = try XCTUnwrap(Lane(kind: .sqrdmulh, isSigned: false, laneBits: 16, highHalf: false, activeBytes: 16))
        XCTAssertEqual(rd.evaluate(n: (0x4000, 0), m: (0x2000, 0)).low & 0xffff, 0x1000)
        XCTAssertEqual(rd.evaluate(n: (0x0001, 0), m: (0x4000, 0)).low & 0xffff, 0x0001, "rounding")
        XCTAssertTrue(rd.saturates(n: (0x8000, 0), m: (0x8000, 0)))
        // sqxtun 8h -> 8b: -1 -> 0, 0x0123 -> 0xff, 0x0042 -> 0x42; any clamp sets QC.
        let xt = try XCTUnwrap(Lane(kind: .sqxtun, isSigned: false, laneBits: 8, highHalf: false))
        let wide: Lane.Vector = (0x0000_0042_0123_ffff, 0)
        XCTAssertEqual(xt.evaluate(n: wide).low & 0xff_ffff, 0x42_ff00)
        XCTAssertEqual(xt.evaluate(n: wide).high, 0)
        XCTAssertTrue(xt.saturates(n: wide, m: (0, 0)))
        XCTAssertFalse(xt.saturates(n: (0x0042, 0), m: (0, 0)))
        let xt2 = try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: "sqxtun2", operandText: "v16.16b, v6.8h"))
        XCTAssertTrue(xt2.semantics.readsDestination)
        XCTAssertEqual(MacIRBuilder.neonLaneOperation(mnemonic: "sqrdmulh", operandText: "v5.8h, v5.8h, v3.h[3]")?
            .semantics.elementIndex, 3)
        // dup from a W register, and mvni.
        let dup = try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: "dup", operandText: "v0.8h, w8"))
        XCTAssertEqual(dup.sources, ["w8"])
        XCTAssertEqual(dup.semantics.sourceCount, 1, "DUP from a GPR has one source (DP11)")
        XCTAssertEqual(dup.semantics.arity, dup.sources.count)
        XCTAssertEqual(dup.semantics.evaluate(n: (0x1_2345, 0)).low, 0x2345_2345_2345_2345)
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "dup", operandText: "v0.2d, w8"), "2d needs an X source")
        let mvni = try XCTUnwrap(MacIRBuilder.neonMoveImmediate(mnemonic: "mvni", operandText: "v1.8h, #0x7f"))
        XCTAssertEqual(mvni.semantics.low, 0xff80_ff80_ff80_ff80)
    }

    /// DP05/#679: scalar SQ(R)DMULH (register and by-element) and scalar SQXTUN.
    func testScalarSaturatingForms() throws {
        func op(_ mnemonic: String, _ text: String) throws -> MacIRBuilder.NEONLaneOperands {
            try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: mnemonic, operandText: text), text)
        }
        let h = try op("sqrdmulh", "h0, h1, h2")
        XCTAssertEqual(h.destination, "v0")
        XCTAssertEqual(h.sources, ["v1", "v2"])
        XCTAssertEqual(h.semantics.evaluate(n: (0xffff_ffff_ffff_4000, 1), m: (0xffff_ffff_ffff_4000, 1)).low, 0x2000)
        XCTAssertEqual(h.semantics.evaluate(n: (0x4000, 1), m: (0x4000, 1)).high, 0, "upper bytes are zeroed")
        XCTAssertTrue(h.semantics.setsQC)
        let s = try op("sqdmulh", "s3, s4, s5")
        XCTAssertEqual(s.semantics.evaluate(n: (0x8000_0000, 0), m: (0x8000_0000, 0)).low, 0x7fff_ffff)
        XCTAssertTrue(s.semantics.saturates(n: (0x8000_0000, 0), m: (0x8000_0000, 0)))
        XCTAssertFalse(s.semantics.saturates(n: (0x8000_0000_0000_0001, 0), m: (0x8000_0000_8000_0000, 0)),
                       "only lane 0 counts in the scalar form")
        let byElement = try op("sqrdmulh", "h0, h1, v2.h[3]")
        XCTAssertEqual(byElement.semantics.elementIndex, 3)
        XCTAssertEqual(byElement.semantics.evaluate(n: (0x4000, 0), m: (0x4000_0000_0000_0000, 0)).low, 0x2000)
        let narrow = try op("sqxtun", "b0, h1")
        XCTAssertEqual(narrow.sources, ["v1"])
        XCTAssertEqual(narrow.semantics.evaluate(n: (0xffff_ffff_ffff_0123, 0)).low, 0xff)
        XCTAssertEqual(narrow.semantics.evaluate(n: (0xff80, 0)).low, 0)
        XCTAssertEqual(narrow.semantics.evaluate(n: (0x0042, 0)).low, 0x42)
        XCTAssertTrue(narrow.semantics.saturates(n: (0x0123, 0), m: (0, 0)))
        XCTAssertFalse(narrow.semantics.saturates(n: (0x0123_0042, 0), m: (0, 0)), "only lane 0 counts")
        XCTAssertEqual(try op("sqxtun", "s0, d1").semantics.evaluate(n: (0x1_0000_0000, 0)).low, 0xffff_ffff)
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "sqxtun", operandText: "b0, s1"), "source must be twice as wide")
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "sqrdmulh", operandText: "h0, s1, h2"))
    }

    /// B11: consume builder-emitted DUPs, including both initial and SSA vector
    /// sources. Distinct upper lanes expose a consumer that discards bits 64–127.
    func testConcreteEvaluatorPreservesUpperSourceLanesForVectorDup() throws {
        func row(_ address: UInt64, _ operands: String) -> InstructionRow {
            InstructionRow(address: address, bytes: "", mnemonic: "dup", operands: operands,
                           hasBreakpoint: false, comment: nil)
        }
        let function = MacIRBuilder().buildFunction(name: "vector_dup_upper_lanes", startAddress: 0xe000,
            instructions: [
                row(0xe000, "v0.4s, v1.s[3]"),
                row(0xe004, "v2.8b, v1.b[14]"),
                row(0xe008, "v3.2d, v0.d[1]"),
                row(0xe00c, "v4.8h, w8"),
            ])
        XCTAssertEqual(function.instructions.filter { $0.neonLaneOp?.kind == .dup }.count, 4)
        var state = try A64MachineState(seeding: try JSONDecoder().decode(A64OracleVector.State.self,
                                                                          from: Data("{}".utf8)))
        state.v[1] = .init(low: 0x0706_0504_0302_0100, high: 0x0f0e_0d0c_0b0a_0908)
        state.v[2] = .init(low: .max, high: .max)
        state.x[8] = 0x1234_5678_9abc_2345
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        try evaluator.run(function.instructions)
        XCTAssertEqual(evaluator.state.v[0], .init(low: 0x0f0e_0d0c_0f0e_0d0c, high: 0x0f0e_0d0c_0f0e_0d0c))
        XCTAssertEqual(evaluator.state.v[2], .init(low: 0x0e0e_0e0e_0e0e_0e0e, high: 0),
                       "8-byte DUP clears the old upper half")
        XCTAssertEqual(evaluator.state.v[3], .init(low: 0x0f0e_0d0c_0f0e_0d0c, high: 0x0f0e_0d0c_0f0e_0d0c),
                       "a newly written SSA source retains its upper half")
        XCTAssertEqual(evaluator.state.v[4], .init(low: 0x2345_2345_2345_2345, high: 0x2345_2345_2345_2345),
                       "GPR broadcast still uses the low lane")
    }

    func testConcreteEvaluatorPreservesUpperSourceLanesForScalarDup() throws {
        let operands = ["b0, v1.b[15]", "h2, v1.h[6]", "s3, v1.s[2]", "d4, v1.d[1]"]
        let rows = operands.enumerated().map { index, operands in
            InstructionRow(address: 0xf000 + UInt64(index) * 4, bytes: "", mnemonic: "dup",
                           operands: operands, hasBreakpoint: false, comment: nil)
        }
        // Keep this regression at the requested oracle-consumer boundary. The
        // whole-function region admission currently rejects B/H/S/D tokens;
        // the existing per-row builder does emit their typed DUP operations.
        var builderState = BuilderState(parameters: [])
        builderState.permitsNEONBufferCarrier = true
        builderState.permitsNEONScalarViewCarrier = true
        let emitted = try rows.map { row -> MacIRInstruction in
            let lane = try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: row.mnemonic, operandText: row.operands))
            let operation = MacIRBuilder.liftNEONLane(lane, state: &builderState)
            return .init(source: .init(address: row.address, byteText: row.bytes, mnemonic: row.mnemonic,
                                       operands: row.operands, comment: nil), operation: operation, neonLaneOp: lane.semantics)
        }
        let function = MacIRFunction(name: "scalar_dup_upper_lanes", startAddress: 0xf000, instructions: emitted)
        XCTAssertEqual(function.instructions.filter { $0.neonLaneOp?.kind == .dup }.count, 4)
        var state = try A64MachineState(seeding: try JSONDecoder().decode(A64OracleVector.State.self,
                                                                          from: Data("{}".utf8)))
        state.v[1] = .init(low: 0x0706_0504_0302_0100, high: 0x0f0e_0d0c_0b0a_0908)
        for index in [0, 2, 3, 4] { state.v[index] = .init(low: .max, high: .max) }
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        try evaluator.run(function.instructions)
        XCTAssertEqual(evaluator.state.v[0], .init(low: 0x0f, high: 0))
        XCTAssertEqual(evaluator.state.v[2], .init(low: 0x0d0c, high: 0))
        XCTAssertEqual(evaluator.state.v[3], .init(low: 0x0b0a_0908, high: 0))
        XCTAssertEqual(evaluator.state.v[4], .init(low: 0x0f0e_0d0c_0b0a_0908, high: 0))
    }

    /// DP05/#679: DUP by element (vector) and the scalar `mov Bd|Hd|Sd|Dd, Vn.t[i]`
    /// were the largest UNLIFTED oracle family.
    func testDupByElementBroadcastsOneLane() throws {
        typealias Lane = MacIRNEONLaneOp
        let n: Lane.Vector = (0x0706_0504_0302_0100, 0x0f0e_0d0c_0b0a_0908)
        func op(_ mnemonic: String, _ text: String) throws -> MacIRBuilder.NEONLaneOperands {
            try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: mnemonic, operandText: text), text)
        }
        let byte = try op("dup", "v0.8b, v1.b[3]")
        XCTAssertEqual(byte.sources, ["v1"])
        XCTAssertEqual(byte.semantics.arity, 1)
        XCTAssertEqual(byte.semantics.evaluate(n: n).low, 0x0303_0303_0303_0303)
        XCTAssertEqual(byte.semantics.evaluate(n: n).high, 0, "8b form zeroes the upper half")
        let word = try op("dup", "v2.4s, v1.s[2]")
        XCTAssertEqual(word.semantics.evaluate(n: n).low, 0x0b0a_0908_0b0a_0908)
        XCTAssertEqual(word.semantics.evaluate(n: n).high, 0x0b0a_0908_0b0a_0908)
        let double = try op("dup", "v3.2d, v1.d[1]")
        XCTAssertEqual(double.semantics.evaluate(n: n).low, n.high)
        let scalarD = try op("mov", "d0, v1.d[1]")
        XCTAssertEqual(scalarD.destination, "v0")
        XCTAssertEqual(scalarD.semantics.evaluate(n: n).low, n.high)
        XCTAssertEqual(scalarD.semantics.evaluate(n: n).high, 0)
        let scalarB = try op("mov", "b5, v1.b[15]")
        XCTAssertEqual(scalarB.destination, "v5")
        XCTAssertEqual(scalarB.semantics.evaluate(n: n).low, 0x0f)
        XCTAssertEqual(scalarB.semantics.evaluate(n: n).high, 0)
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "dup", operandText: "v0.8b, v1.h[0]"),
                     "lane width must match the arrangement")
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "mov", operandText: "h0, v1.b[0]"))
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "dup", operandText: "v0.16b, v1.b[16]"))
    }

    // DOT-DUP-scalar: exercise the whole-function region, not liftNEONLane directly.
    private func scalarDupRows(_ body: [(String, String)]) -> [InstructionRow] {
        (body + [("ret", "")]).enumerated().map { index, row in
            InstructionRow(address: 0x11000 + UInt64(index) * 4, bytes: "",
                           mnemonic: row.0, operands: row.1, hasBreakpoint: false, comment: nil)
        }
    }

    private func checkWholeFunctionScalarDup(_ letter: String, bits: Int, lane: Int,
                                            expected: UInt64, file: StaticString = #filePath,
                                            line: UInt = #line) throws {
        for mnemonic in ["mov", "dup"] {
            for source in [0, 1] { // Source/destination alias must capture the old source first.
                let consumer: (String, String) = bits == 32 ? ("fmov", "w3, s0")
                    : bits == 64 ? ("fmov", "x3, d0") : ("str", "\(letter)0, [x4]")
                let rows = scalarDupRows([
                    (mnemonic, "\(letter)0, v\(source).\(letter)[\(lane)]"),
                    // A full vector read observes every zeroed upper bit.
                    ("orr", "v2.16b, v0.16b, v0.16b"), consumer,
                ])
                XCTAssertTrue(MacIRBuilder.attemptsGeneralVectorRegion(rows), file: file, line: line)
                let region = MacIRBuilder().buildGeneralVectorRegion(name: "scalar_dup_region",
                    startAddress: 0x11000, rows: rows, initialState: BuilderState(parameters: []),
                    hasExternalFacts: false, isVariadic: false)
                XCTAssertNotNil(region, "whole-function admission: \(mnemonic) \(letter)", file: file, line: line)
                let function = MacIRBuilder().buildFunction(name: "scalar_dup_whole",
                    startAddress: 0x11000, instructions: rows)
                let emitted = try XCTUnwrap(function.instructions.first { $0.source.address == 0x11000 },
                                            file: file, line: line)
                XCTAssertEqual(emitted.neonLaneOp?.kind, .dup, file: file, line: line)
                XCTAssertEqual(emitted.neonLaneOp?.laneBits, bits, file: file, line: line)
                XCTAssertEqual(emitted.neonLaneOp?.activeBytes, bits / 8, file: file, line: line)
                XCTAssertEqual(emitted.neonLaneOp?.elementIndex, lane, file: file, line: line)
                var state = try A64MachineState(seeding: try JSONDecoder().decode(
                    A64OracleVector.State.self, from: Data("{}".utf8)))
                state.v[0] = .init(low: .max, high: .max)
                state.v[2] = .init(low: .max, high: .max)
                state.v[source] = .init(low: 0x7766_5544_3322_1100, high: 0xffee_ddcc_bbaa_9988)
                state.x[3] = .max
                state.x[4] = 0x500400
                // Guard bytes also establish the scalar store's exact footprint.
                for offset in 0..<16 { state.setByte(0xa5, at: state.x[4] + UInt64(offset)) }
                var evaluator = MacIRConcreteEvaluator(function: function, state: state)
                try evaluator.run(function.instructions)
                let result = A64MachineState.V128(low: expected, high: 0)
                XCTAssertEqual(evaluator.state.v[0], result, "selected lane; ALL other bits zero", file: file, line: line)
                XCTAssertEqual(evaluator.state.v[2], result, "later full-vector read", file: file, line: line)
                if bits >= 32 {
                    XCTAssertEqual(evaluator.state.x[3], expected, "later scalar FMOV", file: file, line: line)
                } else {
                    for offset in 0..<16 {
                        let byte: UInt8 = offset < bits / 8 ? UInt8(truncatingIfNeeded: expected >> (offset * 8)) : 0xa5
                        XCTAssertEqual(evaluator.state.byte(at: state.x[4] + UInt64(offset)), byte,
                                       "scalar store byte \(offset)", file: file, line: line)
                    }
                }
            }
        }
    }

    func testWholeFunctionScalarDupByteZeroesUpperBits() throws {
        try checkWholeFunctionScalarDup("b", bits: 8, lane: 15, expected: 0xff)
    }

    func testWholeFunctionScalarDupHalfwordZeroesUpperBits() throws {
        try checkWholeFunctionScalarDup("h", bits: 16, lane: 7, expected: 0xffee)
    }

    func testWholeFunctionScalarDupWordZeroesUpperBits() throws {
        try checkWholeFunctionScalarDup("s", bits: 32, lane: 3, expected: 0xffee_ddcc)
    }

    func testWholeFunctionScalarDupDoublewordZeroesUpperBits() throws {
        try checkWholeFunctionScalarDup("d", bits: 64, lane: 1, expected: 0xffee_ddcc_bbaa_9988)
    }

    func testWholeFunctionScalarDupRefusesOtherScalarForms() {
        let refused: [(String, String)] = [
            ("mov", "b0, v1.b[16]"), ("mov", "h0, v1.h[8]"),
            ("dup", "s0, v1.s[4]"), ("dup", "d0, v1.d[2]"),
            ("mov", "h0, v1.b[0]"), ("dup", "s0, v1.d[0]"),
            ("mov", "b0, v1.b[-1]"), ("mov", "b0, v1.b[+1]"),
            ("mov", "b0, v1.b[01]"), ("mov", "b0, v1.b[1], #0"),
            ("mov", "b0, v32.b[0]"), ("mov", "b0, q1.b[0]"),
            ("mov", "b0, v1.b[0] trailing"), ("dup", "b0, w1"),
            ("mov", "b0, b1"), ("mov", "b0, #1"),
            ("sqxtun", "b0, h1"), ("sqrdmulh", "h0, h1, h2"),
            ("fadd", "s0, s1, s2"),
        ]
        for (mnemonic, operands) in refused {
            let rows = scalarDupRows([(mnemonic, operands), ("orr", "v2.16b, v0.16b, v0.16b")])
            XCTAssertNil(MacIRBuilder().buildGeneralVectorRegion(name: "refused_scalar",
                startAddress: 0x11000, rows: rows, initialState: BuilderState(parameters: []),
                hasExternalFacts: false, isVariadic: false), "\(mnemonic) \(operands)")
        }
        // The exception must not admit a previously refused FMOV-only leaf.
        let noDup = scalarDupRows([("orr", "v2.16b, v0.16b, v0.16b"), ("fmov", "w3, s0")])
        XCTAssertNil(MacIRBuilder().buildGeneralVectorRegion(name: "no_scalar_dup",
            startAddress: 0x11000, rows: noDup, initialState: BuilderState(parameters: []),
            hasExternalFacts: false, isVariadic: false))
    }

    func testWholeFunctionScalarDupTracksScalarDestinationAtLoopJoin() throws {
        // v0 never appears textually: its scalar spelling must still join as V0.
        let rows = scalarDupRows([
            ("mov", "w9, #2"), ("str", "b0, [x4]"),
            ("mov", "b0, v1.b[15]"), ("sub", "w9, w9, #1"),
            ("cbnz", "w9, 0x11004"),
        ])
        let region = try XCTUnwrap(MacIRBuilder().buildGeneralVectorRegion(name: "scalar_dup_loop",
            startAddress: 0x11000, rows: rows, initialState: BuilderState(parameters: []),
            hasExternalFacts: false, isVariadic: false))
        let phi = try XCTUnwrap(region.phis.first { phi in
            guard phi.blockAddress == 0x11004, phi.bitWidth == 128 else { return false }
            if case .register(name: "v0", _) = phi.destination { return true }; return false
        })
        XCTAssertEqual(phi.incoming.count, 2)
        XCTAssertFalse(phi.incoming.contains { if case .unknown = $0.value { return true }; return false })
        let store = try XCTUnwrap(region.instructions.first { $0.source.address == 0x11004 })
        guard case let .store(value, _) = store.operation else { return XCTFail("expected scalar store") }
        XCTAssertEqual(value, phi.destination)
    }

    func testWholeFunctionScalarDupReadsFreshSSASourceAndRegister31() throws {
        let rows = scalarDupRows([
            ("movi", "v1.16b, #0xa5"),
            ("mov", "b31, v1.b[15]"),
            ("orr", "v0.16b, v31.16b, v31.16b"),
        ])
        let function = MacIRBuilder().buildFunction(name: "scalar_dup_fresh_source",
            startAddress: 0x11000, instructions: rows)
        XCTAssertEqual(function.instructions.first { $0.source.address == 0x11004 }?.neonLaneOp?.kind, .dup)
        var state = try A64MachineState(seeding: try JSONDecoder().decode(
            A64OracleVector.State.self, from: Data("{}".utf8)))
        state.v[1] = .init(low: 0x1111, high: 0x2222)
        state.v[31] = .init(low: .max, high: .max)
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        try evaluator.run(function.instructions)
        XCTAssertEqual(evaluator.state.v[31], .init(low: 0xa5, high: 0))
        XCTAssertEqual(evaluator.state.v[0], .init(low: 0xa5, high: 0))
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "mov", operandText: "b32, v1.b[15]"))
    }

    func testWholeFunctionScalarDupDoesNotAdmitMalformedFMOVOrStaleADRP() {
        for operands in ["s0, d1", "b0, b1", "w32, s0", "w-1, s0", "s0, #1.0"] {
            let rows = scalarDupRows([("mov", "s0, v1.s[3]"), ("fmov", operands)])
            XCTAssertFalse(MacIRBuilder.isBranchFreeVectorLeaf(rows), operands)
        }
        let rows = scalarDupRows([
            ("adrp", "x8, 0x5000"), ("mov", "d0, v1.d[1]"),
            ("fmov", "x8, d0"), ("add", "x8, x8, #16"),
        ])
        XCTAssertFalse(MacIRBuilder.isBranchFreeVectorLeaf(rows), "FMOV invalidates the old ADRP page")
    }
    func testScalarDupNarrowStoreParserRefusesUnsupportedForms() {
        let refused: [(String, String)] = [
            ("ldr", "b0, [x4]"), ("ldur", "h0, [x4]"), ("stp", "b0, b1, [x4]"),
            ("strb", "b0, [x4]"), ("str", "s0, [x4]"), ("str", "h32, [x4]"),
            ("str", "b00, [x4]"), ("str", "b0, [x31]"), ("str", "h0, [w4]"),
            ("str", "b0, [sp]"), ("str", "b0, [x4, #1]!"), ("str", "h0, [x4], #2"),
            ("str", "b0, [x4, x5]"), ("str", "b0, [x4, #4096]"),
            ("str", "h0, [x4, #8192]"), ("str", "h0, [x4, #1]"),
            ("str", "b0, [x4, #-1]"), ("stur", "b0, [x4, #-257]"),
            ("stur", "h0, [x4, #256]"), ("str", "b0, [x4],"),
            ("str", "b0, [x4] trailing"), ("str", "b0, [x4, #0, #1]"),
        ]
        for (mnemonic, operands) in refused {
            XCTAssertNil(MacIRBuilder.neonPlainNarrowScalarStore(mnemonic: mnemonic, operandText: operands),
                         "\(mnemonic) \(operands)")
        }
    }

    func testWholeFunctionScalarDupNarrowStoreOffsetsAndFootprints() throws {
        for (letter, bytes, lane, expected) in [("b", 1, 15, UInt64(0xff)), ("h", 2, 7, UInt64(0xffee))] {
            for (mnemonic, offset) in [("str", 4095 * bytes), ("stur", -256), ("stur", 255)] {
                let rows = scalarDupRows([
                    ("mov", "\(letter)0, v1.\(letter)[\(lane)]"),
                    (mnemonic, "\(letter)0, [x4, #\(offset)]"),
                ])
                let function = MacIRBuilder().buildFunction(name: "scalar_dup_store_offset",
                    startAddress: 0x11000, instructions: rows)
                let store = try XCTUnwrap(function.instructions.first { $0.source.address == 0x11004 })
                XCTAssertEqual(store.memoryAccess?.byteWidth, bytes)
                var state = try A64MachineState(seeding: try JSONDecoder().decode(
                    A64OracleVector.State.self, from: Data("{}".utf8)))
                state.v[1] = .init(low: 0x7766_5544_3322_1100, high: 0xffee_ddcc_bbaa_9988)
                state.x[4] = 0x500400
                let address = UInt64(Int64(state.x[4]) + Int64(offset))
                for delta in -1...bytes { state.setByte(0xa5, at: UInt64(Int64(address) + Int64(delta))) }
                var evaluator = MacIRConcreteEvaluator(function: function, state: state)
                try evaluator.run(function.instructions)
                XCTAssertEqual(evaluator.state.x[4], state.x[4], "non-writeback base")
                for delta in -1...bytes {
                    let value: UInt8 = (0..<bytes).contains(delta)
                        ? UInt8(truncatingIfNeeded: expected >> (delta * 8)) : 0xa5
                    XCTAssertEqual(evaluator.state.byte(at: UInt64(Int64(address) + Int64(delta))), value)
                }
            }
        }
    }
    func testScalarDupNarrowStoreRefusesMultipleImmediateSigns() {
        for (mnemonic, operands) in [("str", "b0, [x4, #--1]"), ("stur", "h0, [x4, #-+1]")] {
            XCTAssertNil(MacIRBuilder.neonPlainNarrowScalarStore(mnemonic: mnemonic, operandText: operands),
                         "\(mnemonic) \(operands)")
        }
    }

    func testScalarDupNarrowStoreInvalidatesAliasedEntryStackFormal() throws {
        for letter in ["b", "h"] {
            for mnemonic in ["str", "stur"] {
                let parameter = try XCTUnwrap(MacIRFunctionParameter(
                    id: .init(rawValue: "narrow-store-stack-formal"), bindingID: nil, sourcePosition: 0,
                    abiLocation: .entryStack(byteOffset: 0, size: 8, alignment: 8),
                    type: "uint64_t", name: "stack_argument", evidence: .authoritativeUser))
                var initial = BuilderState(parameters: [parameter])
                initial.stackBaseOffsets["x29"] = 0
                let rows = scalarDupRows([
                    ("mov", "\(letter)0, v1.\(letter)[0]"),
                    (mnemonic, "\(letter)0, [x29]"), ("ldr", "x0, [sp]"),
                ])
                let region = try XCTUnwrap(MacIRBuilder().buildGeneralVectorRegion(name: "scalar_dup_alias",
                    startAddress: 0x11000, rows: rows, initialState: initial,
                    hasExternalFacts: false, isVariadic: false))
                XCTAssertNil(region.parameters.first?.bindingID,
                             "partial overwrite must prevent recovery of the original stack formal")
            }
        }
    }
    func testScalarDupNarrowStoreRefusesOverflowAndMalformedMagnitudes() {
        // These dangerous malformed inputs were not executed against the unsafe
        // inherited parser; this is post-fix coverage, not baseline-red evidence.
        for immediate in ["--9223372036854775808", "-9223372036854775808", "9223372036854775808",
                          "+1", "-+0x1", "0x", "-0x", "0xg", "1_0", "1.0"] {
            XCTAssertNil(MacIRBuilder.neonPlainNarrowScalarStore(
                mnemonic: "stur", operandText: "h0, [x4, #\(immediate)]"), immediate)
        }
    }
}
