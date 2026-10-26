import Foundation
import XCTest
@testable import MacScope

final class ARM64DisassemblyTests: XCTestCase {
    func testARM64DecoderConformsToDisassemblerSeam() {
        // ARM64Decoder is reachable through the architecture-neutral `Disassembler`
        // protocol, returning neutral `DecodedInstruction`s.
        let decoder: any Disassembler = ARM64Decoder()
        var bytes = Data()
        bytes.appendUInt32LE(0xd10083ff) // sub sp, sp, #0x20

        let rows: [DecodedInstruction] = decoder.decode(bytes, baseAddress: 0x1_0000_1000, maxInstructionCount: 1)
        XCTAssertEqual(rows.first?.mnemonic, "sub")
        XCTAssertEqual(rows.first?.operands, "sp, sp, #0x20")
        XCTAssertEqual(rows.first?.address, 0x1_0000_1000)
    }

    private func decode1(_ word: UInt32) -> (mnemonic: String, operands: String) {
        var bytes = Data(); bytes.appendUInt32LE(word)
        let row = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return (row.mnemonic, row.operands)
    }

    /// DP05-C09: preserve the SP destination role of the ORR-immediate MOV alias.
    func testLogicalImmediateMOVPreservesStackPointerDestination() {
        XCTAssertEqual(decode1(0x320083ff).operands, "wsp, #0x10001") // DP05-C09
        XCTAssertEqual(decode1(0x320c47ff).operands, "wsp, #0xfff0003f") // DP05-C09
        XCTAssertEqual(decode1(0x32184bff).operands, "wsp, #0x7ffff00") // DP05-C09
        XCTAssertEqual(decode1(0x322483ff).operands, "wsp, #0x10001000") // DP05-C09
        XCTAssertEqual(decode1(0x323093ff).operands, "wsp, #0x1f001f") // DP05-C09
        XCTAssertEqual(decode1(0x323c57ff).operands, "wsp, #0x3fffff0") // DP05-C09
        XCTAssertEqual(decode1(0xb205afff).operands, "sp, #0xf87ff87ff87ff87f") // DP05-C09
        XCTAssertEqual(decode1(0xb20e2fff).operands, "sp, #0x3ffc00003ffc0000") // DP05-C09
        XCTAssertEqual(decode1(0xb2169bff).operands, "sp, #0xfc01fc01fc01fc01") // DP05-C09
        XCTAssertEqual(decode1(0xb21f1bff).operands, "sp, #0xfe000000fe") // DP05-C09
        XCTAssertEqual(decode1(0xb22783ff).operands, "sp, #0x200020002000200") // DP05-C09
        XCTAssertEqual(decode1(0xb23003ff).operands, "sp, #0x1000000010000") // DP05-C09
        XCTAssertEqual(decode1(0xb2386bff).operands, "sp, #0xffffff07ffffff07") // DP05-C09
        XCTAssertEqual(decode1(0xb2415bff).operands, "sp, #0x80000000003fffff") // DP05-C09
        XCTAssertEqual(decode1(0xb24bb3ff).operands, "sp, #0xffe00003ffffffff") // DP05-C09
        XCTAssertEqual(decode1(0xb25653ff).operands, "sp, #0x7ffffc0000000000") // DP05-C09
        XCTAssertEqual(decode1(0xb260a7ff).operands, "sp, #0xffffffff000003ff") // DP05-C09
        XCTAssertEqual(decode1(0xb26b47ff).operands, "sp, #0x7fffe00000") // DP05-C09
        XCTAssertEqual(decode1(0xb2759fff).operands, "sp, #0x7fffffffff800") // DP05-C09
        XCTAssertEqual(decode1(0xb27ff7ff).operands, "sp, #0x7ffffffffffffffe") // DP05-C09
        XCTAssertEqual(decode1(0x320083ff).mnemonic, "mov")
        XCTAssertEqual(decode1(0x320083e0).operands, "w0, #0x10001")
    }

    /// MOV (to/from SP) — the alias the otool differential surfaced (MacScope was emitting
    /// `add x29, sp, #0` where otool emits the `mov` alias).
    func testMovToFromStackPointerAlias() {
        XCTAssertEqual(decode1(0x910003fd).mnemonic, "mov")      // add x29, sp, #0
        XCTAssertEqual(decode1(0x910003fd).operands, "x29, sp")
        XCTAssertEqual(decode1(0x910003bf).operands, "sp, x29")  // add sp, x29, #0 -> mov sp, x29
        XCTAssertEqual(decode1(0x910003ff).operands, "sp, sp")   // add sp, sp, #0  -> mov sp, sp
        // Non-alias regressions: neither register is SP, or the immediate is non-zero.
        XCTAssertEqual(decode1(0x910000a5).mnemonic, "add")      // add x5, x5, #0 (no SP)
        XCTAssertEqual(decode1(0x910000a5).operands, "x5, x5, #0")
        XCTAssertEqual(decode1(0x910043e0).mnemonic, "add")      // add x0, sp, #0x10 (nonzero imm)
        XCTAssertEqual(decode1(0x910043e0).operands, "x0, sp, #0x10")
    }

    /// SIMD DUP — the decode gap the differential surfaced (`0x4e080d20` was `unknown`).
    func testSIMDDupDecodes() {
        func text(_ w: UInt32) -> String { let r = decode1(w); return "\(r.mnemonic) \(r.operands)" }
        XCTAssertEqual(text(0x4e080d20), "dup v0.2d, x9")       // DUP general, 64-bit (the surfaced one)
        XCTAssertEqual(text(0x4e040c00), "dup v0.4s, w0")       // DUP general, 32-bit
        XCTAssertEqual(text(0x4e080420), "dup v0.2d, v1.d[0]")  // DUP element, 64-bit
        XCTAssertEqual(text(0x0e010420), "dup v0.8b, v1.b[0]")  // DUP element, 8-bit, Q=0
    }

    /// Advanced SIMD table lookup (tbl/tbx) and extract (ext) instructions. These
    /// encodings were derived from the A64 instruction row definitions and
    /// assembled manually. Each word here is encoded in little-endian form via
    /// `appendUInt32LE`, so the numeric literal appears in big-endian order.
    func testSIMDTableLookupAndExtDecodes() {
        func text(_ w: UInt32) -> String { let r = decode1(w); return "\(r.mnemonic) \(r.operands)" }
        // tbl v0.8b, {v1.16b}, v2.8b (Q=0, len=0, op=0)
        XCTAssertEqual(text(0x0e020020), "tbl v0.8b, {v1.16b}, v2.8b")
        // tbx v3.16b, {v4.16b, v5.16b}, v6.16b (Q=1, len=1, op=1)
        XCTAssertEqual(text(0x4e063083), "tbx v3.16b, {v4.16b, v5.16b}, v6.16b")
        // ext v0.8b, v1.8b, v2.8b, #3 (Q=0, index=3)
        XCTAssertEqual(text(0x2e021820), "ext v0.8b, v1.8b, v2.8b, #3")
        // ext v2.16b, v3.16b, v4.16b, #12 (Q=1, index=12)
        XCTAssertEqual(text(0x6e046062), "ext v2.16b, v3.16b, v4.16b, #12")
    }

    /// Advanced SIMD permutations: zip1/zip2, uzp1/uzp2, trn1/trn2. These
    /// encodings were assembled manually using the instruction row patterns.
    /// Each literal is given in big-endian form and appended via
    /// `appendUInt32LE` to provide the correct little-endian byte order.
    func testSIMDZipUzpTrnDecodes() {
        func text(_ w: UInt32) -> String { let r = decode1(w); return "\(r.mnemonic) \(r.operands)" }
        // zip1 v0.8b, v1.8b, v2.8b (size=0, Q=0)
        XCTAssertEqual(text(0x0e023820), "zip1 v0.8b, v1.8b, v2.8b")
        // uzp1 v0.8b, v1.8b, v2.8b
        XCTAssertEqual(text(0x0e021820), "uzp1 v0.8b, v1.8b, v2.8b")
        // trn1 v0.8b, v1.8b, v2.8b
        XCTAssertEqual(text(0x0e022820), "trn1 v0.8b, v1.8b, v2.8b")
        // zip2 v3.16b, v4.16b, v5.16b (Q=1)
        XCTAssertEqual(text(0x4e057883), "zip2 v3.16b, v4.16b, v5.16b")
        // size=3,Q=0 is reserved (no .1d permute) — must degrade to `unknown`, not mislabel as .1d.
        XCTAssertEqual(decode1(0x0ec23820).mnemonic, "unknown")
    }

    /// LSE atomic read-modify-write instructions. These encodings were assembled
    /// manually from the arm64 LSE atomic instruction row definitions. Each
    /// constant is provided in big-endian form and encoded little-endian via
    /// `appendUInt32LE`.
    func testLSEAtomicDecodes() {
        func text(_ w: UInt32) -> String { let r = decode1(w); return "\(r.mnemonic) \(r.operands)" }
        // ldaddal w2, w3, [x4] (size=word, acquire+release)
        XCTAssertEqual(text(0xb8e20083), "ldaddal w2, w3, [x4]")
        // swpl x1, x2, [x3] (size=dword, release)
        XCTAssertEqual(text(0xf8618062), "swpl x1, x2, [x3]")
        // staddb w5, [x6] (store alias of ldaddb; size=byte)
        XCTAssertEqual(text(0x382500df), "staddb w5, [x6]")
        // SP base: Rn==31 is the stack pointer (never XZR) for the atomic [Xn|SP] base.
        XCTAssertEqual(text(0xb82003e1), "ldadd w0, w1, [sp]")
        XCTAssertEqual(text(0xf82083e1), "swp x0, x1, [sp]")
        XCTAssertEqual(text(0xb82003ff), "stadd w0, [sp]")
        // bare ldadd (no acquire/release, x-base)
        XCTAssertEqual(text(0xb8200041), "ldadd w0, w1, [x2]")
        // (cas/casp are now decoded — see testSIMDStructureAndCASDecodes.)
    }

    func testControlFlowClassificationMatchesLegacyMnemonicLogic() {
        // The neutral `flow` must reproduce exactly the call/branch/return roles the
        // analysis pipeline previously derived inline from these arm64 mnemonics.
        func flow(_ word: UInt32) -> InstructionFlow {
            var bytes = Data(); bytes.appendUInt32LE(word)
            return ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_0000, maxInstructionCount: 1)[0].flow
        }
        XCTAssertEqual(flow(0x9400_0000), .call)            // bl
        XCTAssertEqual(flow(0x1400_0000), .jump)            // b
        XCTAssertEqual(flow(0xd61f_0000), .indirectJump)    // br x0
        XCTAssertEqual(flow(0xd65f_03c0), .return)          // ret
        XCTAssertEqual(flow(0x5400_0000), .conditionalJump) // b.eq
        XCTAssertEqual(flow(0x3400_0000), .conditionalJump) // cbz w0
        XCTAssertEqual(flow(0xd503_201f), .normal)          // nop
    }

    /// arm64e authenticated branches + plain `blr` must classify with their REAL control-flow role,
    /// not `.normal`. This is the macOS-27 readiness bug: on arm64e every PAC-protected function
    /// ends in `retaa`/`retab` and many calls are `blraa`, so misclassifying them as `.normal`
    /// silently breaks function discovery, CFG exit blocks, and decompiler structuring. Encodings
    /// are clang/otool ground truth (`clang -arch arm64e`).
    func testAuthenticatedAndIndirectBranchFlowClassification() {
        func decoded(_ word: UInt32) -> DecodedInstruction {
            var bytes = Data(); bytes.appendUInt32LE(word)
            return ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_0000, maxInstructionCount: 1)[0]
        }
        // Authenticated returns — the critical case (arm64e function epilogues).
        XCTAssertEqual(decoded(0xd65f0bff).mnemonic, "retaa")
        XCTAssertEqual(decoded(0xd65f0bff).flow, .return)
        XCTAssertEqual(decoded(0xd65f0fff).mnemonic, "retab")
        XCTAssertEqual(decoded(0xd65f0fff).flow, .return)
        // Authenticated indirect branches (tail calls / dispatch) — terminators like `br`.
        XCTAssertEqual(decoded(0xd71f0801).mnemonic, "braa")
        XCTAssertEqual(decoded(0xd71f0801).flow, .indirectJump)   // braa x0, x1
        XCTAssertEqual(decoded(0xd71f0c01).flow, .indirectJump)   // brab x0, x1
        XCTAssertEqual(decoded(0xd61f085f).flow, .indirectJump)   // braaz x2
        // Authenticated indirect calls + plain `blr` — calls, not "normal".
        XCTAssertEqual(decoded(0xd63f0000).mnemonic, "blr")
        XCTAssertEqual(decoded(0xd63f0000).flow, .indirectCall)   // blr x0
        XCTAssertEqual(decoded(0xd73f0801).flow, .indirectCall)   // blraa x0, x1
        XCTAssertEqual(decoded(0xd73f0c01).flow, .indirectCall)   // blrab x0, x1
        XCTAssertEqual(decoded(0xd73f093f).operands, "x9, sp")    // blraa x9, sp
        XCTAssertEqual(decoded(0xd73f0d5f).operands, "x10, sp")   // blrab x10, sp
        XCTAssertEqual(decoded(0xd63f087f).flow, .indirectCall)   // blraaz x3
        // arm64e authenticated EXCEPTION returns (kernel/driver) — terminators, consistent with
        // the data-xref resolver's `eret*` handling. Without this they'd merge into the next block.
        XCTAssertEqual(decoded(0xd69f0bff).mnemonic, "eretaa")
        XCTAssertEqual(decoded(0xd69f0bff).flow, .return)
        XCTAssertEqual(decoded(0xd69f0fff).flow, .return)         // eretab
    }

    func testDecoderResolvesADRAbsoluteTarget() {
        var bytes = Data()
        bytes.appendUInt32LE(0x1000_00a0) // adr x0, #0x14

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_1000)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].mnemonic, "adr")
        XCTAssertEqual(rows[0].operands, "x0, 0x0000000100001014")
        XCTAssertNil(rows[0].branchTarget)
        XCTAssertEqual(rows[0].comment, "PC-relative address")
    }

    func testDecoderResolvesADRPPageTarget() {
        var bytes = Data()
        bytes.appendUInt32LE(0xd000_0008) // adrp x8, #0x2000

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_000c)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].mnemonic, "adrp")
        XCTAssertEqual(rows[0].operands, "x8, 0x0000000100002000")
        XCTAssertNil(rows[0].branchTarget)
        XCTAssertEqual(rows[0].comment, "Page-relative address")
    }

    func testDecoderRecognizesDirectConditionalCompareAndTestBranches() {
        var bytes = Data()
        bytes.appendUInt32LE(0x1400_0002) // b +0x8
        bytes.appendUInt32LE(0x5400_0040) // b.eq +0x8
        bytes.appendUInt32LE(0xb400_0040) // cbz x0, +0x8
        bytes.appendUInt32LE(0x3500_0041) // cbnz w1, +0x8
        bytes.appendUInt32LE(0x3618_0042) // tbz w2, #3, +0x8
        bytes.appendUInt32LE(0xb740_0043) // tbnz x3, #40, +0x8

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_1000)

        XCTAssertEqual(rows.map(\.mnemonic), ["b", "b.eq", "cbz", "cbnz", "tbz", "tbnz"])
        XCTAssertEqual(rows[0].operands, "0x0000000100001008")
        XCTAssertEqual(rows[1].operands, "0x000000010000100c")
        XCTAssertEqual(rows[2].operands, "x0, 0x0000000100001010")
        XCTAssertEqual(rows[3].operands, "w1, 0x0000000100001014")
        XCTAssertEqual(rows[4].operands, "w2, #3, 0x0000000100001018")
        XCTAssertEqual(rows[5].operands, "x3, #40, 0x000000010000101c")
        XCTAssertEqual(rows.compactMap(\.branchTarget), [
            0x1_0000_1008,
            0x1_0000_100c,
            0x1_0000_1010,
            0x1_0000_1014,
            0x1_0000_1018,
            0x1_0000_101c
        ])
    }

    func testDecoderRecognizesConditionalSelectAndSetAliases() {
        var bytes = Data()
        bytes.appendUInt32LE(0x1a9f_07e0) // cset w0, ne
        bytes.appendUInt32LE(0x9a9f_17e1) // cset x1, eq
        bytes.appendUInt32LE(0x9a84_3062) // csel x2, x3, x4, lo
        bytes.appendUInt32LE(0x9a84_3462) // csinc x2, x3, x4, lo
        bytes.appendUInt32LE(0xda87_a0c5) // csinv x5, x6, x7, ge
        bytes.appendUInt32LE(0x5a8a_1528) // csneg w8, w9, w10, ne

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_1800)

        XCTAssertEqual(rows.map(\.mnemonic), ["cset", "cset", "csel", "csinc", "csinv", "csneg"])
        XCTAssertEqual(rows[0].operands, "w0, ne")
        XCTAssertEqual(rows[1].operands, "x1, eq")
        XCTAssertEqual(rows[2].operands, "x2, x3, x4, lo")
        XCTAssertEqual(rows[3].operands, "x2, x3, x4, lo")
        XCTAssertEqual(rows[4].operands, "x5, x6, x7, ge")
        XCTAssertEqual(rows[5].operands, "w8, w9, w10, ne")
        XCTAssertTrue(rows.allSatisfy { $0.branchTarget == nil })
        XCTAssertTrue(rows.allSatisfy { $0.comment == nil })
    }

    func testDecoderRecognizesIndirectBranchCallAndRegisterReturn() {
        var bytes = Data()
        bytes.appendUInt32LE(0xd61f_0200) // br x16
        bytes.appendUInt32LE(0xd63f_0120) // blr x9
        bytes.appendUInt32LE(0xd65f_0260) // ret x19

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_2000)

        XCTAssertEqual(rows.map(\.mnemonic), ["br", "blr", "ret"])
        XCTAssertEqual(rows.map(\.operands), ["x16", "x9", "x19"])
        XCTAssertTrue(rows.allSatisfy { $0.branchTarget == nil })
    }

    // Encodings below are ground-truth: assembled with `clang -arch arm64` and
    // captured via `otool -tvVj`, so each word and its canonical disassembly are
    // exactly what the system toolchain produces.

    func testDecoderRecognizesAddSubtractShiftedRegisterAndAliases() {
        var bytes = Data()
        bytes.appendUInt32LE(0x8b02_0020) // add  x0, x1, x2
        bytes.appendUInt32LE(0x0b05_0083) // add  w3, w4, w5
        bytes.appendUInt32LE(0x8b08_0ce6) // add  x6, x7, x8, lsl #3
        bytes.appendUInt32LE(0xab0b_0149) // adds x9, x10, x11
        bytes.appendUInt32LE(0xcb0e_01ac) // sub  x12, x13, x14
        bytes.appendUInt32LE(0xeb11_020f) // subs x15, x16, x17
        bytes.appendUInt32LE(0x4b54_0a72) // sub  w18, w19, w20, lsr #2
        bytes.appendUInt32LE(0xeb01_001f) // cmp  x0, x1
        bytes.appendUInt32LE(0x6b03_005f) // cmp  w2, w3
        bytes.appendUInt32LE(0xab05_009f) // cmn  x4, x5
        bytes.appendUInt32LE(0xcb07_03e6) // neg  x6, x7
        bytes.appendUInt32LE(0xeb09_03e8) // negs x8, x9

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_3000)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "add", "add", "add", "adds", "sub", "subs", "sub", "cmp", "cmp", "cmn", "neg", "negs"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, x1, x2",
            "w3, w4, w5",
            "x6, x7, x8, lsl #3",
            "x9, x10, x11",
            "x12, x13, x14",
            "x15, x16, x17",
            "w18, w19, w20, lsr #2",
            "x0, x1",
            "w2, w3",
            "x4, x5",
            "x6, x7",
            "x8, x9"
        ])
    }

    func testDecoderRecognizesLogicalShiftedRegisterAndAliases() {
        var bytes = Data()
        bytes.appendUInt32LE(0x8a02_0020) // and  x0, x1, x2
        bytes.appendUInt32LE(0xaa05_0083) // orr  x3, x4, x5
        bytes.appendUInt32LE(0xca08_00e6) // eor  x6, x7, x8
        bytes.appendUInt32LE(0xea0b_0149) // ands x9, x10, x11
        bytes.appendUInt32LE(0x8a2e_01ac) // bic  x12, x13, x14
        bytes.appendUInt32LE(0xaa31_020f) // orn  x15, x16, x17
        bytes.appendUInt32LE(0xca34_0272) // eon  x18, x19, x20
        bytes.appendUInt32LE(0x8a17_12d5) // and  x21, x22, x23, lsl #4
        bytes.appendUInt32LE(0xaa19_03f8) // mov  x24, x25
        bytes.appendUInt32LE(0xaa3b_03fa) // mvn  x26, x27
        bytes.appendUInt32LE(0xea00_039f) // tst  x28, x0
        bytes.appendUInt32LE(0x2a02_03e1) // mov  w1, w2

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_3400)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "and", "orr", "eor", "ands", "bic", "orn", "eon", "and", "mov", "mvn", "tst", "mov"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, x1, x2",
            "x3, x4, x5",
            "x6, x7, x8",
            "x9, x10, x11",
            "x12, x13, x14",
            "x15, x16, x17",
            "x18, x19, x20",
            "x21, x22, x23, lsl #4",
            "x24, x25",
            "x26, x27",
            "x28, x0",
            "w1, w2"
        ])
    }

    func testDecoderRecognizesDataProcessingOneAndTwoSource() {
        var bytes = Data()
        bytes.appendUInt32LE(0xdac0_0020) // rbit  x0, x1
        bytes.appendUInt32LE(0xdac0_0462) // rev16 x2, x3
        bytes.appendUInt32LE(0xdac0_08a4) // rev32 x4, x5
        bytes.appendUInt32LE(0xdac0_0ce6) // rev   x6, x7
        bytes.appendUInt32LE(0xdac0_1128) // clz   x8, x9
        bytes.appendUInt32LE(0xdac0_156a) // cls   x10, x11
        bytes.appendUInt32LE(0x5ac0_09ac) // rev   w12, w13
        bytes.appendUInt32LE(0x9ac2_0820) // udiv  x0, x1, x2
        bytes.appendUInt32LE(0x9ac5_0c83) // sdiv  x3, x4, x5
        bytes.appendUInt32LE(0x9ac8_20e6) // lsl   x6, x7, x8
        bytes.appendUInt32LE(0x9acb_2549) // lsr   x9, x10, x11
        bytes.appendUInt32LE(0x9ace_29ac) // asr   x12, x13, x14
        bytes.appendUInt32LE(0x9ad1_2e0f) // ror   x15, x16, x17
        bytes.appendUInt32LE(0x1ad4_2272) // lsl   w18, w19, w20

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_3800)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "rbit", "rev16", "rev32", "rev", "clz", "cls", "rev",
            "udiv", "sdiv", "lsl", "lsr", "asr", "ror", "lsl"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, x1", "x2, x3", "x4, x5", "x6, x7", "x8, x9", "x10, x11", "w12, w13",
            "x0, x1, x2", "x3, x4, x5", "x6, x7, x8", "x9, x10, x11",
            "x12, x13, x14", "x15, x16, x17", "w18, w19, w20"
        ])
    }

    func testDecoderRecognizesDataProcessingThreeSourceAndMultiplyAliases() {
        var bytes = Data()
        bytes.appendUInt32LE(0x9b02_0c20) // madd   x0, x1, x2, x3
        bytes.appendUInt32LE(0x9b06_9ca4) // msub   x4, x5, x6, x7
        bytes.appendUInt32LE(0x9b0a_7d28) // mul    x8, x9, x10
        bytes.appendUInt32LE(0x9b0d_fd8b) // mneg   x11, x12, x13
        bytes.appendUInt32LE(0x9b30_7dee) // smull  x14, w15, w16
        bytes.appendUInt32LE(0x9bb3_7e51) // umull  x17, w18, w19
        bytes.appendUInt32LE(0x9b56_7eb4) // smulh  x20, x21, x22
        bytes.appendUInt32LE(0x9bd9_7f17) // umulh  x23, x24, x25
        bytes.appendUInt32LE(0x9b3c_777a) // smaddl x26, w27, w28, x29

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_3c00)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "madd", "msub", "mul", "mneg", "smull", "umull", "smulh", "umulh", "smaddl"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, x1, x2, x3",
            "x4, x5, x6, x7",
            "x8, x9, x10",
            "x11, x12, x13",
            "x14, w15, w16",
            "x17, w18, w19",
            "x20, x21, x22",
            "x23, x24, x25",
            "x26, w27, w28, x29"
        ])
    }

    func testDecoderRecognizesSizedUnsignedOffsetLoadsAndStores() {
        var bytes = Data()
        bytes.appendUInt32LE(0x3940_1020) // ldrb  w0, [x1, #4]
        bytes.appendUInt32LE(0x3900_0062) // strb  w2, [x3]
        bytes.appendUInt32LE(0x7940_10a4) // ldrh  w4, [x5, #8]
        bytes.appendUInt32LE(0x7900_04e6) // strh  w6, [x7, #2]
        bytes.appendUInt32LE(0x39c0_0528) // ldrsb w8, [x9, #1]
        bytes.appendUInt32LE(0x79c0_096a) // ldrsh w10, [x11, #4]
        bytes.appendUInt32LE(0xb980_09ac) // ldrsw x12, [x13, #8]
        bytes.appendUInt32LE(0xf940_09ee) // ldr   x14, [x15, #16]
        bytes.appendUInt32LE(0xb900_0e30) // str   w16, [x17, #12]
        bytes.appendUInt32LE(0x3940_0272) // ldrb  w18, [x19]

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_4000)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "ldrb", "strb", "ldrh", "strh", "ldrsb", "ldrsh", "ldrsw", "ldr", "str", "ldrb"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "w0, [x1, #4]",
            "w2, [x3]",
            "w4, [x5, #8]",
            "w6, [x7, #2]",
            "w8, [x9, #1]",
            "w10, [x11, #4]",
            "x12, [x13, #8]",
            "x14, [x15, #0x10]",
            "w16, [x17, #0xc]",
            "w18, [x19]"
        ])
    }

    func testDecoderRecognizesUnscaledAndIndexedLoadsAndStores() {
        var bytes = Data()
        bytes.appendUInt32LE(0xf85f_8020) // ldur   x0, [x1, #-8]
        bytes.appendUInt32LE(0xb81f_c062) // stur   w2, [x3, #-4]
        bytes.appendUInt32LE(0x385f_f0a4) // ldurb  w4, [x5, #-1]
        bytes.appendUInt32LE(0xb89f_00e6) // ldursw x6, [x7, #-16]
        bytes.appendUInt32LE(0xf841_0420) // ldr    x0, [x1], #16   (post)
        bytes.appendUInt32LE(0xb81f_8462) // str    w2, [x3], #-8   (post)
        bytes.appendUInt32LE(0x3840_14a4) // ldrb   w4, [x5], #1    (post)
        bytes.appendUInt32LE(0xf841_0c20) // ldr    x0, [x1, #16]!  (pre)
        bytes.appendUInt32LE(0xf81f_0c62) // str    x2, [x3, #-16]! (pre)
        bytes.appendUInt32LE(0x3800_2ca4) // strb   w4, [x5, #2]!   (pre)

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_4400)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "ldur", "stur", "ldurb", "ldursw", "ldr", "str", "ldrb", "ldr", "str", "strb"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, [x1, #-0x8]",
            "w2, [x3, #-0x4]",
            "w4, [x5, #-0x1]",
            "x6, [x7, #-0x10]",
            "x0, [x1], #0x10",
            "w2, [x3], #-0x8",
            "w4, [x5], #1",
            "x0, [x1, #0x10]!",
            "x2, [x3, #-0x10]!",
            "w4, [x5, #2]!"
        ])
    }

    func testDecoderRecognizesRegisterOffsetLoadsAndStores() {
        var bytes = Data()
        bytes.appendUInt32LE(0xf862_6820) // ldr x0, [x1, x2]
        bytes.appendUInt32LE(0xf862_7820) // ldr x0, [x1, x2, lsl #3]
        bytes.appendUInt32LE(0xb825_5883) // str w3, [x4, w5, uxtw #2]
        bytes.appendUInt32LE(0x3868_68e6) // ldrb w6, [x7, x8]
        bytes.appendUInt32LE(0xf86b_e949) // ldr x9, [x10, x11, sxtx]

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_4800)

        XCTAssertEqual(rows.map(\.mnemonic), ["ldr", "ldr", "str", "ldrb", "ldr"])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, [x1, x2]",
            "x0, [x1, x2, lsl #3]",
            "w3, [x4, w5, uxtw #2]",
            "w6, [x7, x8]",
            "x9, [x10, x11, sxtx]"
        ])
    }

    func testDecoderRecognizesLoadStorePairIndexForms() {
        var bytes = Data()
        bytes.appendUInt32LE(0xa9bf_7bfd) // stp x29, x30, [sp, #-16]!
        bytes.appendUInt32LE(0xa8c1_7bfd) // ldp x29, x30, [sp], #16
        bytes.appendUInt32LE(0xa901_0440) // stp x0, x1, [x2, #16]
        bytes.appendUInt32LE(0x28c1_10a3) // ldp w3, w4, [x5], #8

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_4c00)

        XCTAssertEqual(rows.map(\.mnemonic), ["stp", "ldp", "stp", "ldp"])
        XCTAssertEqual(rows.map(\.operands), [
            "x29, x30, [sp, #-0x10]!",
            "x29, x30, [sp], #0x10",
            "x0, x1, [x2, #0x10]",
            "w3, w4, [x5], #8"
        ])
    }

    func testDecoderRecognizesBitfieldExtractInsertAndAliases() {
        var bytes = Data()
        bytes.appendUInt32LE(0x9340_1c20) // sxtb  x0, w1
        bytes.appendUInt32LE(0x9340_3c62) // sxth  x2, w3
        bytes.appendUInt32LE(0x9340_7ca4) // sxtw  x4, w5
        bytes.appendUInt32LE(0x5300_1ce6) // uxtb  w6, w7
        bytes.appendUInt32LE(0x5300_3d28) // uxth  w8, w9
        bytes.appendUInt32LE(0x9345_fd6a) // asr   x10, x11, #5
        bytes.appendUInt32LE(0xd37c_edac) // lsl   x12, x13, #4
        bytes.appendUInt32LE(0xd346_fdee) // lsr   x14, x15, #6
        bytes.appendUInt32LE(0x531d_7020) // lsl   w0, w1, #3
        bytes.appendUInt32LE(0x1307_7c62) // asr   w2, w3, #7
        bytes.appendUInt32LE(0x9343_1e30) // sbfx  x16, x17, #3, #5
        bytes.appendUInt32LE(0xd342_2672) // ubfx  x18, x19, #2, #8
        bytes.appendUInt32LE(0x937c_16b4) // sbfiz x20, x21, #4, #6
        bytes.appendUInt32LE(0xd37e_26f6) // ubfiz x22, x23, #2, #10
        bytes.appendUInt32LE(0xb37d_1338) // bfi   x24, x25, #3, #5
        bytes.appendUInt32LE(0xb342_177a) // bfxil x26, x27, #2, #4

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_5000)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "sxtb", "sxth", "sxtw", "uxtb", "uxth", "asr", "lsl", "lsr", "lsl", "asr",
            "sbfx", "ubfx", "sbfiz", "ubfiz", "bfi", "bfxil"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, w1", "x2, w3", "x4, w5", "w6, w7", "w8, w9",
            "x10, x11, #5", "x12, x13, #4", "x14, x15, #6", "w0, w1, #3", "w2, w3, #7",
            "x16, x17, #3, #5", "x18, x19, #2, #8", "x20, x21, #4, #6", "x22, x23, #2, #10",
            "x24, x25, #3, #5", "x26, x27, #2, #4"
        ])
    }

    func testDecoderRecognizesConditionalCompareRegisterAndImmediate() {
        var bytes = Data()
        bytes.appendUInt32LE(0xfa42_0803) // ccmp x0, #2, #3, eq
        bytes.appendUInt32LE(0xfa45_1080) // ccmp x4, x5, #0, ne
        bytes.appendUInt32LE(0xba41_c8c5) // ccmn x6, #1, #5, gt
        bytes.appendUInt32LE(0xba48_b0e2) // ccmn x7, x8, #2, lt

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_5400)

        XCTAssertEqual(rows.map(\.mnemonic), ["ccmp", "ccmp", "ccmn", "ccmn"])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, #2, #3, eq",
            "x4, x5, #0, ne",
            "x6, #1, #5, gt",
            "x7, x8, #2, lt"
        ])
    }

    func testDecoderRecognizesMoveWideVariants() {
        var bytes = Data()
        bytes.appendUInt32LE(0xd282_4680) // movz x0, #0x1234       -> mov
        bytes.appendUInt32LE(0xd2aa_cf01) // movz x1, #0x5678, lsl #16 -> mov
        bytes.appendUInt32LE(0x9280_1fe2) // movn x2, #0xff         -> mov #-0x100
        bytes.appendUInt32LE(0xf2d5_79a3) // movk x3, #0xabcd, lsl #32
        bytes.appendUInt32LE(0x5280_0124) // movz w4, #0x9          -> mov

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_5800)

        XCTAssertEqual(rows.map(\.mnemonic), ["mov", "mov", "mov", "movk", "mov"])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, #0x1234",
            "x1, #0x56780000",
            "x2, #-0x100",
            "x3, #0xabcd, lsl #32",
            "w4, #9"
        ])
    }

    // Corner vectors surfaced by the adversarial load/store review: sign-extend
    // destination widths, scale-0 register offsets, lsl #0, no-amount extends,
    // ldpsw/stnp, imm boundaries, xzr rendering, and pre/post writeback.
    func testDecoderLoadStoreCornerRegressionVectors() {
        var bytes = Data()
        bytes.appendUInt32LE(0x3980_0c20) // ldrsb  x0, [x1, #3]   (opc=2 -> X dst)
        bytes.appendUInt32LE(0x39c0_1020) // ldrsb  w0, [x1, #4]   (opc=3 -> W dst)
        bytes.appendUInt32LE(0xb880_7020) // ldursw x0, [x1, #7]
        bytes.appendUInt32LE(0xb8a2_7820) // ldrsw  x0, [x1, x2, lsl #2]
        bytes.appendUInt32LE(0x38a2_6820) // ldrsb  x0, [x1, x2]
        bytes.appendUInt32LE(0x3862_7820) // ldrb   w0, [x1, x2, lsl #0]
        bytes.appendUInt32LE(0xf862_4820) // ldr    x0, [x1, w2, uxtw]
        bytes.appendUInt32LE(0xf862_c820) // ldr    x0, [x1, w2, sxtw]
        bytes.appendUInt32LE(0xf862_e820) // ldr    x0, [x1, x2, sxtx]
        bytes.appendUInt32LE(0x6940_87e0) // ldpsw  x0, x1, [sp, #4]
        bytes.appendUInt32LE(0xa801_07e0) // stnp   x0, x1, [sp, #16]
        bytes.appendUInt32LE(0xf850_0020) // ldur   x0, [x1, #-256]
        bytes.appendUInt32LE(0xf97f_fc20) // ldr    x0, [x1, #0x7ff8]  (max imm12)
        bytes.appendUInt32LE(0xf900_083f) // str    xzr, [x1, #16]
        bytes.appendUInt32LE(0xf840_8420) // ldr    x0, [x1], #8
        bytes.appendUInt32LE(0xb81f_cc20) // str    w0, [x1, #-4]!

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_6000)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "ldrsb", "ldrsb", "ldursw", "ldrsw", "ldrsb", "ldrb", "ldr", "ldr", "ldr",
            "ldpsw", "stnp", "ldur", "ldr", "str", "ldr", "str"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, [x1, #3]",
            "w0, [x1, #4]",
            "x0, [x1, #7]",
            "x0, [x1, x2, lsl #2]",
            "x0, [x1, x2]",
            "w0, [x1, x2, lsl #0]",
            "x0, [x1, w2, uxtw]",
            "x0, [x1, w2, sxtw]",
            "x0, [x1, x2, sxtx]",
            "x0, x1, [sp, #4]",
            "x0, x1, [sp, #0x10]",
            "x0, [x1, #-0x100]",
            "x0, [x1, #0x7ff8]",
            "xzr, [x1, #0x10]",
            "x0, [x1], #8",
            "w0, [x1, #-0x4]!"
        ])
    }

    func testDecoderLeavesArchitecturallyUnallocatedSIMDCopyUnknown() {
        var bytes = Data()
        bytes.appendUInt32LE(0x4e01_4c20) // SIMD-copy imm4=0b1001 — architecturally unallocated (otool emits .long)

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_6400)

        XCTAssertEqual(rows.map(\.mnemonic), ["unknown"])
    }

    func testDecoderRecognizesConditionalSelectIncrementInvertNegateAliases() {
        var bytes = Data()
        bytes.appendUInt32LE(0x9a81_1420) // cinc  x0, x1, eq
        bytes.appendUInt32LE(0x1a83_0462) // cinc  w2, w3, ne
        bytes.appendUInt32LE(0xda85_a4a4) // cneg  x4, x5, lt
        bytes.appendUInt32LE(0xda9f_d3e6) // csetm x6, gt
        bytes.appendUInt32LE(0x5a9f_53e7) // csetm w7, mi
        bytes.appendUInt32LE(0x9a9f_17e8) // cset  x8, eq
        bytes.appendUInt32LE(0x9a8b_2149) // csel  x9, x10, x11, hs

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_6800)

        XCTAssertEqual(rows.map(\.mnemonic), ["cinc", "cinc", "cneg", "csetm", "csetm", "cset", "csel"])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, x1, eq",
            "w2, w3, ne",
            "x4, x5, lt",
            "x6, gt",
            "w7, mi",
            "x8, eq",
            "x9, x10, x11, hs"
        ])
    }

    func testDecoderRecognizesLogicalImmediateAndAliases() {
        var bytes = Data()
        bytes.appendUInt32LE(0x9240_1c20) // and  x0, x1, #0xff
        bytes.appendUInt32LE(0x3200_0000) // orr  w0, w0, #1
        bytes.appendUInt32LE(0xd27c_0c62) // eor  x2, x3, #0xf0
        bytes.appendUInt32LE(0xf240_04a4) // ands x4, x5, #3
        bytes.appendUInt32LE(0xf240_1cdf) // tst  x6, #0xff
        bytes.appendUInt32LE(0x121d_7128) // and  w8, w9, #0xfffffff8
        bytes.appendUInt32LE(0xb200_f16a) // orr  x10, x11, #0x5555555555555555
        bytes.appendUInt32LE(0xf240_001f) // tst  x0, #1
        bytes.appendUInt32LE(0x5201_00a4) // eor  w4, w5, #0x80000000
        bytes.appendUInt32LE(0xd201_f230) // eor  x16, x17, #0xaaaaaaaaaaaaaaaa
        bytes.appendUInt32LE(0xf210_3e72) // ands x18, x19, #0xffff0000ffff0000
        bytes.appendUInt32LE(0x9240_1c1f) // and  sp, x0, #0xff
        bytes.appendUInt32LE(0xb240_0c3f) // orr  sp, x1, #0xf
        bytes.appendUInt32LE(0xb270_bfe0) // orr  x0, xzr, #0xffffffffffff0000 (movn -> stays orr)
        bytes.appendUInt32LE(0x321f_7be0) // orr  w0, wzr, #0xfffffffe (movn -> stays orr)
        bytes.appendUInt32LE(0xb200_f3e0) // mov  x0, #0x5555555555555555
        bytes.appendUInt32LE(0xb200_03e0) // mov  x0, #0x100000001

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_8000)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "and", "orr", "eor", "ands", "tst", "and", "orr", "tst", "eor", "eor",
            "ands", "and", "orr", "orr", "orr", "mov", "mov"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, x1, #0xff",
            "w0, w0, #1",
            "x2, x3, #0xf0",
            "x4, x5, #3",
            "x6, #0xff",
            "w8, w9, #0xfffffff8",
            "x10, x11, #0x5555555555555555",
            "x0, #1",
            "w4, w5, #0x80000000",
            "x16, x17, #0xaaaaaaaaaaaaaaaa",
            "x18, x19, #0xffff0000ffff0000",
            "sp, x0, #0xff",
            "sp, x1, #0xf",
            "x0, xzr, #0xffffffffffff0000",
            "w0, wzr, #0xfffffffe",
            "x0, #0x5555555555555555",
            "x0, #0x100000001"
        ])
    }

    func testDecoderRecognizesSystemHintsAndBarriers() {
        var bytes = Data()
        bytes.appendUInt32LE(0xd503_201f) // nop
        bytes.appendUInt32LE(0xd503_203f) // yield
        bytes.appendUInt32LE(0xd503_205f) // wfe
        bytes.appendUInt32LE(0xd503_207f) // wfi
        bytes.appendUInt32LE(0xd503_209f) // sev
        bytes.appendUInt32LE(0xd503_20bf) // sevl
        bytes.appendUInt32LE(0xd503_217f) // hint #0xb
        bytes.appendUInt32LE(0xd503_2fff) // hint #0x7f
        bytes.appendUInt32LE(0xd503_3fbf) // dmb sy
        bytes.appendUInt32LE(0xd503_3bbf) // dmb ish
        bytes.appendUInt32LE(0xd503_3abf) // dmb ishst
        bytes.appendUInt32LE(0xd503_3dbf) // dmb ld
        bytes.appendUInt32LE(0xd503_3ebf) // dmb st
        bytes.appendUInt32LE(0xd503_3f9f) // dsb sy
        bytes.appendUInt32LE(0xd503_3b9f) // dsb ish
        bytes.appendUInt32LE(0xd503_3fdf) // isb

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_8400)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "nop", "yield", "wfe", "wfi", "sev", "sevl", "hint", "hint",
            "dmb", "dmb", "dmb", "dmb", "dmb", "dsb", "dsb", "isb"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "", "", "", "", "", "", "#0xb", "#0x7f",
            "sy", "ish", "ishst", "ld", "st", "sy", "ish", ""
        ])
    }

    func testDecoderRecognizesPacPrologueHints() {
        var bytes = Data()
        bytes.appendUInt32LE(0xd503_233f) // paciasp
        bytes.appendUInt32LE(0xd503_237f) // pacibsp
        bytes.appendUInt32LE(0xd503_23bf) // autiasp
        bytes.appendUInt32LE(0xd503_23ff) // autibsp
        bytes.appendUInt32LE(0xd503_231f) // paciaz
        bytes.appendUInt32LE(0xd503_20ff) // xpaclri

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_8800)

        XCTAssertEqual(rows.map(\.mnemonic), ["paciasp", "pacibsp", "autiasp", "autibsp", "paciaz", "xpaclri"])
        XCTAssertTrue(rows.allSatisfy { $0.operands.isEmpty })
    }

    func testDecoderRecognizesExceptionGenerating() {
        var bytes = Data()
        bytes.appendUInt32LE(0xd400_0001) // svc #0
        bytes.appendUInt32LE(0xd400_0021) // svc #1
        bytes.appendUInt32LE(0xd400_0042) // hvc #2
        bytes.appendUInt32LE(0xd400_0063) // smc #3
        bytes.appendUInt32LE(0xd420_0020) // brk #0x1
        bytes.appendUInt32LE(0xd420_0000) // brk #0
        bytes.appendUInt32LE(0xd45e_0000) // hlt #0xf000

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_8c00)

        XCTAssertEqual(rows.map(\.mnemonic), ["svc", "svc", "hvc", "smc", "brk", "brk", "hlt"])
        XCTAssertEqual(rows.map(\.operands), ["#0", "#1", "#2", "#3", "#1", "#0", "#0xf000"])
    }

    func testDecoderRecognizesSystemRegisterMoves() {
        var bytes = Data()
        bytes.appendUInt32LE(0xd503_42df) // msr daifset, #2
        bytes.appendUInt32LE(0xd503_4fff) // msr daifclr, #0xf
        bytes.appendUInt32LE(0xd53b_4200) // mrs x0, nzcv
        bytes.appendUInt32LE(0xd51b_4201) // msr nzcv, x1
        bytes.appendUInt32LE(0xd53b_4402) // mrs x2, fpcr
        bytes.appendUInt32LE(0xd53b_4424) // mrs x4, fpsr
        bytes.appendUInt32LE(0xd53b_d045) // mrs x5, tpidr_el0
        bytes.appendUInt32LE(0xd538_0007) // mrs x7, midr_el1
        bytes.appendUInt32LE(0xd539_b04a) // mrs x10, s3_1_c11_c0_2 (unnamed -> generic)

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_9000)

        XCTAssertEqual(rows.map(\.mnemonic), ["msr", "msr", "mrs", "msr", "mrs", "mrs", "mrs", "mrs", "mrs"])
        XCTAssertEqual(rows.map(\.operands), [
            "daifset, #2",
            "daifclr, #0xf",
            "x0, nzcv",
            "nzcv, x1",
            "x2, fpcr",
            "x4, fpsr",
            "x5, tpidr_el0",
            "x7, midr_el1",
            "x10, s3_1_c11_c0_2"
        ])
    }

    func testDecoderExtractAndRorAlias() {
        var bytes = Data()
        bytes.appendUInt32LE(0x93c2_1420) // extr x0, x1, x2, #5
        bytes.appendUInt32LE(0x1385_2883) // extr w3, w4, w5, #10
        bytes.appendUInt32LE(0x93c7_50e6) // ror  x6, x7, #20
        bytes.appendUInt32LE(0x1389_0d28) // ror  w8, w9, #3
        bytes.appendUInt32LE(0x93cb_016a) // ror  x10, x11, #0
        bytes.appendUInt32LE(0x93d0_fdee) // extr x14, x15, x16, #63

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_9400)

        XCTAssertEqual(rows.map(\.mnemonic), ["extr", "extr", "ror", "ror", "ror", "extr"])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, x1, x2, #5",
            "w3, w4, w5, #10",
            "x6, x7, #20",
            "w8, w9, #3",
            "x10, x11, #0",
            "x14, x15, x16, #63"
        ])
    }

    func testDecoderRecognizesPointerAuthDataProcessing() {
        var bytes = Data()
        bytes.appendUInt32LE(0xdac1_0020) // pacia  x0, x1
        bytes.appendUInt32LE(0xdac1_0420) // pacib  x0, x1
        bytes.appendUInt32LE(0xdac1_1020) // autia  x0, x1
        bytes.appendUInt32LE(0xdac1_1c20) // autdb  x0, x1
        bytes.appendUInt32LE(0xdac1_23e0) // paciza x0
        bytes.appendUInt32LE(0xdac1_27e0) // pacizb x0
        bytes.appendUInt32LE(0xdac1_3fe0) // autdzb x0
        bytes.appendUInt32LE(0xdac1_43e0) // xpaci  x0
        bytes.appendUInt32LE(0xdac1_47e0) // xpacd  x0
        bytes.appendUInt32LE(0xdac1_43fe) // xpaci  x30
        bytes.appendUInt32LE(0x9ac2_3020) // pacga  x0, x1, x2

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_9800)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "pacia", "pacib", "autia", "autdb", "paciza", "pacizb", "autdzb",
            "xpaci", "xpacd", "xpaci", "pacga"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, x1", "x0, x1", "x0, x1", "x0, x1", "x0", "x0", "x0",
            "x0", "x0", "x30", "x0, x1, x2"
        ])
    }

    func testDecoderRecognizesPointerAuthBranches() {
        var bytes = Data()
        bytes.appendUInt32LE(0xd71f_0801) // braa   x0, x1
        bytes.appendUInt32LE(0xd71f_0c01) // brab   x0, x1
        bytes.appendUInt32LE(0xd73f_0822) // blraa  x1, x2
        bytes.appendUInt32LE(0xd61f_081f) // braaz  x0
        bytes.appendUInt32LE(0xd63f_083f) // blraaz x1
        bytes.appendUInt32LE(0xd65f_0bff) // retaa
        bytes.appendUInt32LE(0xd65f_0fff) // retab
        bytes.appendUInt32LE(0xd69f_0bff) // eretaa
        bytes.appendUInt32LE(0xd69f_0fff) // eretab

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_9c00)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "braa", "brab", "blraa", "braaz", "blraaz", "retaa", "retab", "eretaa", "eretab"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, x1", "x0, x1", "x1, x2", "x0", "x1", "", "", "", ""
        ])
    }

    func testDecoderLeavesPlainBranchesUnaffectedByPointerAuthHook() {
        var bytes = Data()
        bytes.appendUInt32LE(0xd61f_0200) // br  x16
        bytes.appendUInt32LE(0xd63f_0120) // blr x9
        bytes.appendUInt32LE(0xd65f_0260) // ret x19
        bytes.appendUInt32LE(0xd65f_03c0) // ret (x30)

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_a000)

        XCTAssertEqual(rows.map(\.mnemonic), ["br", "blr", "ret", "ret"])
        XCTAssertEqual(rows.map(\.operands), ["x16", "x9", "x19", ""])
    }

    func testDecoderRecognizesAddSubtractImmediateFlagFormsAndAliases() {
        var bytes = Data()
        bytes.appendUInt32LE(0x7100_141f) // cmp  w0, #5
        bytes.appendUInt32LE(0xf100_403f) // cmp  x1, #0x10
        bytes.appendUInt32LE(0xb100_0c5f) // cmn  x2, #3
        bytes.appendUInt32LE(0xf100_2083) // subs x3, x4, #8
        bytes.appendUInt32LE(0x3100_04c5) // adds w5, w6, #1
        bytes.appendUInt32LE(0xf140_04ff) // cmp  x7, #0x1, lsl #12 -> folded #0x1000
        bytes.appendUInt32LE(0x3103_fd1f) // cmn  w8, #0xff
        bytes.appendUInt32LE(0xd100_83ff) // sub  sp, sp, #0x20
        bytes.appendUInt32LE(0x9100_43fd) // add  x29, sp, #0x10

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_a400)

        XCTAssertEqual(rows.map(\.mnemonic), ["cmp", "cmp", "cmn", "subs", "adds", "cmp", "cmn", "sub", "add"])
        XCTAssertEqual(rows.map(\.operands), [
            "w0, #5",
            "x1, #0x10",
            "x2, #3",
            "x3, x4, #8",
            "w5, w6, #1",
            "x7, #0x1000",
            "w8, #0xff",
            "sp, sp, #0x20",
            "x29, sp, #0x10"
        ])
    }

    func testDecoderRecognizesFPLoadStore() {
        var bytes = Data()
        bytes.appendUInt32LE(0x3dc0_0000) // ldr  q0, [x0]
        bytes.appendUInt32LE(0x3d80_0401) // str  q1, [x0, #16]
        bytes.appendUInt32LE(0xfd40_0420) // ldr  d0, [x1, #8]
        bytes.appendUInt32LE(0xbd00_0442) // str  s2, [x2, #4]
        bytes.appendUInt32LE(0x3d40_0063) // ldr  b3, [x3]
        bytes.appendUInt32LE(0x7d40_0484) // ldr  h4, [x4, #2]
        bytes.appendUInt32LE(0xbc61_7800) // ldr  s0, [x0, x1, lsl #2]
        bytes.appendUInt32LE(0xfc5f_8000) // ldur d0, [x0, #-8]
        bytes.appendUInt32LE(0xfc41_0c20) // ldr  d0, [x1, #16]!
        bytes.appendUInt32LE(0xbc00_4440) // str  s0, [x2], #4
        bytes.appendUInt32LE(0xad40_0400) // ldp  q0, q1, [x0]
        bytes.appendUInt32LE(0xadbf_0fe2) // stp  q2, q3, [sp, #-32]!
        bytes.appendUInt32LE(0x6d41_0400) // ldp  d0, d1, [x0, #16]
        bytes.appendUInt32LE(0x2cc1_0440) // ldp  s0, s1, [x2], #8
        bytes.appendUInt32LE(0xfd00_07e8) // str  d8, [sp, #8]

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_a800)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "ldr", "str", "ldr", "str", "ldr", "ldr", "ldr", "ldur", "ldr", "str",
            "ldp", "stp", "ldp", "ldp", "str"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "q0, [x0]",
            "q1, [x0, #0x10]",
            "d0, [x1, #8]",
            "s2, [x2, #4]",
            "b3, [x3]",
            "h4, [x4, #2]",
            "s0, [x0, x1, lsl #2]",
            "d0, [x0, #-0x8]",
            "d0, [x1, #0x10]!",
            "s0, [x2], #4",
            "q0, q1, [x0]",
            "q2, q3, [sp, #-0x20]!",
            "d0, d1, [x0, #0x10]",
            "s0, s1, [x2], #8",
            "d8, [sp, #8]"
        ])
    }

    func testDecoderRendersThirtyTwoBitStackPointerAsWsp() {
        var bytes = Data()
        bytes.appendUInt32LE(0x1100_103f) // add wsp, w1, #4
        bytes.appendUInt32LE(0x5100_43ff) // sub wsp, wsp, #16
        bytes.appendUInt32LE(0x1200_1c3f) // and wsp, w1, #0xff
        bytes.appendUInt32LE(0x9100_205f) // add sp, x2, #8 (64-bit stays sp)

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_ac00)

        XCTAssertEqual(rows.map(\.mnemonic), ["add", "sub", "and", "add"])
        XCTAssertEqual(rows.map(\.operands), [
            "wsp, w1, #4",
            "wsp, wsp, #0x10",
            "wsp, w1, #0xff",
            "sp, x2, #8"
        ])
    }

    func testDecoderRecognizesScalarFPDataProcessingAndCompare() {
        var bytes = Data()
        bytes.appendUInt32LE(0x1e60_4020) // fmov   d0, d1
        bytes.appendUInt32LE(0x1e20_4020) // fmov   s0, s1
        bytes.appendUInt32LE(0x1e60_c020) // fabs   d0, d1
        bytes.appendUInt32LE(0x1e21_4020) // fneg   s0, s1
        bytes.appendUInt32LE(0x1e61_c062) // fsqrt  d2, d3
        bytes.appendUInt32LE(0x1e22_c000) // fcvt   d0, s0
        bytes.appendUInt32LE(0x1e62_4000) // fcvt   s0, d0
        bytes.appendUInt32LE(0x1e23_c000) // fcvt   h0, s0
        bytes.appendUInt32LE(0x1e66_4020) // frinta d0, d1
        bytes.appendUInt32LE(0x1e25_c020) // frintz s0, s1
        bytes.appendUInt32LE(0x1e62_2820) // fadd   d0, d1, d2
        bytes.appendUInt32LE(0x1e22_3820) // fsub   s0, s1, s2
        bytes.appendUInt32LE(0x1e62_0820) // fmul   d0, d1, d2
        bytes.appendUInt32LE(0x1e22_1820) // fdiv   s0, s1, s2
        bytes.appendUInt32LE(0x1e62_4820) // fmax   d0, d1, d2
        bytes.appendUInt32LE(0x1e62_8820) // fnmul  d0, d1, d2
        bytes.appendUInt32LE(0x1f42_0c20) // fmadd  d0, d1, d2, d3
        bytes.appendUInt32LE(0x1f02_8c20) // fmsub  s0, s1, s2, s3
        bytes.appendUInt32LE(0x1f62_0c20) // fnmadd d0, d1, d2, d3
        bytes.appendUInt32LE(0x1f22_8c20) // fnmsub s0, s1, s2, s3
        bytes.appendUInt32LE(0x1e61_2000) // fcmp   d0, d1
        bytes.appendUInt32LE(0x1e60_2008) // fcmp   d0, #0.0
        bytes.appendUInt32LE(0x1e21_2010) // fcmpe  s0, s1
        bytes.appendUInt32LE(0x1e60_2018) // fcmpe  d0, #0.0
        bytes.appendUInt32LE(0x1e61_0400) // fccmp  d0, d1, #0, eq
        bytes.appendUInt32LE(0x1e21_1413) // fccmpe s0, s1, #3, ne
        bytes.appendUInt32LE(0x1e62_cc20) // fcsel  d0, d1, d2, gt
        bytes.appendUInt32LE(0x1e22_bc20) // fcsel  s0, s1, s2, lt

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_b000)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "fmov", "fmov", "fabs", "fneg", "fsqrt", "fcvt", "fcvt", "fcvt", "frinta", "frintz",
            "fadd", "fsub", "fmul", "fdiv", "fmax", "fnmul", "fmadd", "fmsub", "fnmadd", "fnmsub",
            "fcmp", "fcmp", "fcmpe", "fcmpe", "fccmp", "fccmpe", "fcsel", "fcsel"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "d0, d1", "s0, s1", "d0, d1", "s0, s1", "d2, d3", "d0, s0", "s0, d0", "h0, s0", "d0, d1", "s0, s1",
            "d0, d1, d2", "s0, s1, s2", "d0, d1, d2", "s0, s1, s2", "d0, d1, d2", "d0, d1, d2",
            "d0, d1, d2, d3", "s0, s1, s2, s3", "d0, d1, d2, d3", "s0, s1, s2, s3",
            "d0, d1", "d0, #0.0", "s0, s1", "d0, #0.0", "d0, d1, #0, eq", "s0, s1, #3, ne",
            "d0, d1, d2, gt", "s0, s1, s2, lt"
        ])
    }

    func testDecoderRecognizesFPIntegerConversionsAndImmediate() {
        var bytes = Data()
        bytes.appendUInt32LE(0x1e62_0000) // scvtf  d0, w0
        bytes.appendUInt32LE(0x9e22_0000) // scvtf  s0, x0
        bytes.appendUInt32LE(0x9e63_0000) // ucvtf  d0, x0
        bytes.appendUInt32LE(0x1e23_0000) // ucvtf  s0, w0
        bytes.appendUInt32LE(0x1e78_0000) // fcvtzs w0, d0
        bytes.appendUInt32LE(0x9e38_0000) // fcvtzs x0, s0
        bytes.appendUInt32LE(0x1e39_0000) // fcvtzu w0, s0
        bytes.appendUInt32LE(0x9e60_0000) // fcvtns x0, d0
        bytes.appendUInt32LE(0x1e24_0000) // fcvtas w0, s0
        bytes.appendUInt32LE(0x9e68_0000) // fcvtps x0, d0
        bytes.appendUInt32LE(0x1e30_0000) // fcvtms w0, s0
        bytes.appendUInt32LE(0x1e26_0000) // fmov   w0, s0
        bytes.appendUInt32LE(0x1e27_0000) // fmov   s0, w0
        bytes.appendUInt32LE(0x9e66_0000) // fmov   x0, d0
        bytes.appendUInt32LE(0x9e67_0000) // fmov   d0, x0
        bytes.appendUInt32LE(0x9eae_0000) // fmov   x0, v0.d[1]
        bytes.appendUInt32LE(0x9eaf_0000) // fmov   v0.d[1], x0
        bytes.appendUInt32LE(0x1e02_f000) // scvtf  s0, w0, #4
        bytes.appendUInt32LE(0x1e18_f800) // fcvtzs w0, s0, #2
        bytes.appendUInt32LE(0x1e2e_1000) // fmov   s0, #1.0
        bytes.appendUInt32LE(0x1e60_1000) // fmov   d0, #2.0
        bytes.appendUInt32LE(0x1e2c_1000) // fmov   s0, #0.5
        bytes.appendUInt32LE(0x1e7c_1000) // fmov   d0, #-0.5
        bytes.appendUInt32LE(0x1e3e_1000) // fmov   s0, #-1.0
        bytes.appendUInt32LE(0x1e68_1000) // fmov   d0, #0.125
        bytes.appendUInt32LE(0x1e27_f000) // fmov   s0, #31.0

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_b400)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "scvtf", "scvtf", "ucvtf", "ucvtf", "fcvtzs", "fcvtzs", "fcvtzu", "fcvtns", "fcvtas",
            "fcvtps", "fcvtms", "fmov", "fmov", "fmov", "fmov", "fmov", "fmov", "scvtf", "fcvtzs",
            "fmov", "fmov", "fmov", "fmov", "fmov", "fmov", "fmov"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "d0, w0", "s0, x0", "d0, x0", "s0, w0", "w0, d0", "x0, s0", "w0, s0", "x0, d0", "w0, s0",
            "x0, d0", "w0, s0", "w0, s0", "s0, w0", "x0, d0", "d0, x0", "x0, v0.d[1]", "v0.d[1], x0",
            "s0, w0, #4", "w0, s0, #2",
            "s0, #1.00000000", "d0, #2.00000000", "s0, #0.50000000", "d0, #-0.50000000",
            "s0, #-1.00000000", "d0, #0.12500000", "s0, #31.00000000"
        ])
    }

    func testDecoderRecognizesAddSubtractExtendedRegister() {
        var bytes = Data()
        bytes.appendUInt32LE(0x8b22_4020) // add  x0, x1, w2, uxtw
        bytes.appendUInt32LE(0x8b25_c883) // add  x3, x4, w5, sxtw #2
        bytes.appendUInt32LE(0x8b21_63e0) // add  x0, sp, x1   (uxtx, omitted)
        bytes.appendUInt32LE(0x8b21_601f) // add  sp, x0, x1
        bytes.appendUInt32LE(0xcb22_2020) // sub  x0, x1, w2, uxth
        bytes.appendUInt32LE(0xeb28_ece6) // subs x6, x7, x8, sxtx #3
        bytes.appendUInt32LE(0xeb21_401f) // cmp  x0, w1, uxtw
        bytes.appendUInt32LE(0xab22_63ff) // cmn  sp, x2
        bytes.appendUInt32LE(0x0b22_0020) // add  w0, w1, w2, uxtb
        bytes.appendUInt32LE(0xcb20_63ff) // sub  sp, sp, x0
        bytes.appendUInt32LE(0xeb21_63ff) // cmp  sp, x1

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_b800)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "add", "add", "add", "add", "sub", "subs", "cmp", "cmn", "add", "sub", "cmp"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "x0, x1, w2, uxtw",
            "x3, x4, w5, sxtw #2",
            "x0, sp, x1",
            "sp, x0, x1",
            "x0, x1, w2, uxth",
            "x6, x7, x8, sxtx #3",
            "x0, w1, uxtw",
            "sp, x2",
            "w0, w1, w2, uxtb",
            "sp, sp, x0",
            "sp, x1"
        ])
    }

    func testDecoderRecognizesSIMDThreeSameVector() {
        var bytes = Data()
        bytes.appendUInt32LE(0x4ea2_8420) // add  v0.4s, v1.4s, v2.4s
        bytes.appendUInt32LE(0x6e62_8420) // sub  v0.8h, v1.8h, v2.8h
        bytes.appendUInt32LE(0x4e22_9c20) // mul  v0.16b, v1.16b, v2.16b
        bytes.appendUInt32LE(0x4e22_1c20) // and  v0.16b, v1.16b, v2.16b
        bytes.appendUInt32LE(0x0ea2_1c20) // orr  v0.8b, v1.8b, v2.8b
        bytes.appendUInt32LE(0x6e22_1c20) // eor  v0.16b, v1.16b, v2.16b
        bytes.appendUInt32LE(0x4e22_d420) // fadd v0.4s, v1.4s, v2.4s
        bytes.appendUInt32LE(0x6e62_dc20) // fmul v0.2d, v1.2d, v2.2d
        bytes.appendUInt32LE(0x4ea2_d420) // fsub v0.4s, v1.4s, v2.4s
        bytes.appendUInt32LE(0x6ea2_8c20) // cmeq v0.4s, v1.4s, v2.4s
        bytes.appendUInt32LE(0x4ea2_bc20) // addp v0.4s, v1.4s, v2.4s

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_bc00)

        XCTAssertEqual(rows.map(\.mnemonic), [
            "add", "sub", "mul", "and", "orr", "eor", "fadd", "fmul", "fsub", "cmeq", "addp"
        ])
        XCTAssertEqual(rows.map(\.operands), [
            "v0.4s, v1.4s, v2.4s",
            "v0.8h, v1.8h, v2.8h",
            "v0.16b, v1.16b, v2.16b",
            "v0.16b, v1.16b, v2.16b",
            "v0.8b, v1.8b, v2.8b",
            "v0.16b, v1.16b, v2.16b",
            "v0.4s, v1.4s, v2.4s",
            "v0.2d, v1.2d, v2.2d",
            "v0.4s, v1.4s, v2.4s",
            "v0.4s, v1.4s, v2.4s",
            "v0.4s, v1.4s, v2.4s"
        ])
    }

    func testDecoderRecognizesCryptoAESAndSHA() {
        func text(_ w: UInt32) -> String { let r = decode1(w); return "\(r.mnemonic) \(r.operands)" }

        XCTAssertEqual(text(0x4e28_4820), "aese v0.16b, v1.16b")
        XCTAssertEqual(text(0x4e28_6820), "aesmc v0.16b, v1.16b")
        XCTAssertEqual(text(0x5e02_4020), "sha256h q0, q1, v2.4s")
        XCTAssertEqual(text(0x5e02_0020), "sha1c q0, s1, v2.4s")
    }

    func testDecoderRecognizesCryptoThreeReg512() {
        func text(_ w: UInt32) -> String { let r = decode1(w); return "\(r.mnemonic) \(r.operands)" }

        XCTAssertEqual(text(0xce22_0c20), "bcax v0.16b, v1.16b, v2.16b, v3.16b")
        XCTAssertEqual(text(0xce62_8020), "sha512h q0, q1, v2.2d")
    }

    func testDecoderRecognizesSIMDThreeDifferentAndDoesNotMisdecodeSaddlAsAdd() {
        func text(_ w: UInt32) -> String { let r = decode1(w); return "\(r.mnemonic) \(r.operands)" }

        XCTAssertEqual(text(0x0e20_0020), "saddl v0.8h, v1.8b, v0.8b")
        XCTAssertEqual(decode1(0x0e20_0020).mnemonic, "saddl")
        XCTAssertNotEqual(decode1(0x0e20_0020).mnemonic, "add")
        XCTAssertEqual(text(0x0e22_0020), "saddl v0.8h, v1.8b, v2.8b")
        XCTAssertEqual(text(0x0e22_2020), "ssubl v0.8h, v1.8b, v2.8b")
        XCTAssertEqual(text(0x4e22_c020), "smull2 v0.8h, v1.16b, v2.16b")
        XCTAssertEqual(text(0x2e22_1020), "uaddw v0.8h, v1.8h, v2.8b")
    }

    func testDecoderRecognizesSIMDTwoRegisterMiscConversions() {
        func text(_ w: UInt32) -> String { let r = decode1(w); return "\(r.mnemonic) \(r.operands)" }

        XCTAssertEqual(text(0x0e21_7820), "fcvtl v0.4s, v1.4h")
        XCTAssertEqual(text(0x0e21_6820), "fcvtn v0.4h, v1.4s")
        XCTAssertEqual(text(0x4e21_d820), "scvtf v0.4s, v1.4s")
        XCTAssertEqual(text(0x4ea1_b820), "fcvtzs v0.4s, v1.4s")
    }

    func testDecoderKeepsScalarFP16FaddRegression() {
        func text(_ w: UInt32) -> String { let r = decode1(w); return "\(r.mnemonic) \(r.operands)" }

        XCTAssertEqual(text(0x1ee2_2820), "fadd h0, h1, h2")
    }

    // DP05-C01: minimized dot vectors from DP05/extracted/fixtures/decoder-disagreements.json.
    func testRejectPAuthZeroModifierWithNon31Rm() {
        let reservedWords: [UInt32] = [
            0xd61f0800,
            0xd61f081e,
            0xd61f0be0,
            0xd61f0bfe,
            0xd61f0c00,
            0xd61f0c1e,
            0xd61f0fe0,
            0xd61f0ffe,
            0xd63f0800,
            0xd63f081e,
            0xd63f0be0,
            0xd63f0bfe,
            0xd63f0c00,
            0xd63f0c1e,
            0xd63f0fe0,
            0xd63f0ffe,
        ]
        for word in reservedWords {
            XCTAssertEqual(decode1(word).mnemonic, "unknown", String(format: "DP05-C01 0x%08x", word))
        }

        do {
            let row = decode1(0xd61f081f)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "braaz x0")
        }
        do {
            let row = decode1(0xd61f0c1f)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "brabz x0")
        }
        do {
            let row = decode1(0xd63f081f)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "blraaz x0")
        }
        do {
            let row = decode1(0xd63f0c1f)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "blrabz x0")
        }
    }

    // DP05-C03: minimized dot vectors from DP05/extracted/fixtures/decoder-disagreements.json.
    func testRejectFPIntegerConversionReservedScaleBit() {
        let reservedWords: [UInt32] = [
            0x1e208000,
            0x1e228000,
            0x1e248000,
            0x1e268000,
            0x1e298000,
            0x1e318000,
            0x1e398000,
            0x1e618000,
            0x1e638000,
            0x1e658000,
            0x1e698000,
            0x1e718000,
            0x1e798000,
            0x1ee08000,
            0x1ee28000,
            0x1ee48000,
            0x1ee68000,
            0x1ee98000,
            0x1ef18000,
            0x1ef98000,
        ]
        for word in reservedWords {
            XCTAssertEqual(decode1(word).mnemonic, "unknown", String(format: "DP05-C03 0x%08x", word))
        }

        do {
            let row = decode1(0x1e220000)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "scvtf s0, w0")
        }
        do {
            let row = decode1(0x1e02fc00)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "scvtf s0, w0, #1")
        }
    }

    // DP05-C04: minimized dot vectors from DP05/extracted/fixtures/decoder-disagreements.json.
    func testRejectFMOVGeneralWidthMismatch() {
        let reservedWords: [UInt32] = [
            0x1e660000,
            0x1e670000,
            0x1eae0000,
            0x1eaf0000,
            0x9e260000,
            0x9e270000,
        ]
        for word in reservedWords {
            XCTAssertEqual(decode1(word).mnemonic, "unknown", String(format: "DP05-C04 0x%08x", word))
        }

        do {
            let row = decode1(0x1e260000)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "fmov w0, s0")
        }
        do {
            let row = decode1(0x1e270000)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "fmov s0, w0")
        }
        do {
            let row = decode1(0x9e660000)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "fmov x0, d0")
        }
        do {
            let row = decode1(0x9e670000)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "fmov d0, x0")
        }
        do {
            let row = decode1(0x9eae0000)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "fmov x0, v0.d[1]")
        }
        do {
            let row = decode1(0x9eaf0000)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "fmov v0.d[1], x0")
        }
        do {
            let row = decode1(0x1ee60000)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "fmov w0, h0")
        }
        do {
            let row = decode1(0x1ee70000)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "fmov h0, w0")
        }
        do {
            let row = decode1(0x9ee60000)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "fmov x0, h0")
        }
        do {
            let row = decode1(0x9ee70000)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "fmov h0, x0")
        }
    }

    // DP05-C05: minimized dot vectors from DP05/extracted/fixtures/decoder-disagreements.json.
    func testRejectSHATwoRegisterNonzeroSize() {
        let reservedWords: [UInt32] = [
            0x5e680800,
            0x5e681800,
            0x5e682800,
            0x5ea80800,
            0x5ea81800,
            0x5ea82800,
            0x5ee80800,
            0x5ee81800,
            0x5ee82800,
        ]
        for word in reservedWords {
            XCTAssertEqual(decode1(word).mnemonic, "unknown", String(format: "DP05-C05 0x%08x", word))
        }

        do {
            let row = decode1(0x5e280800)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "sha1h s0, s0")
        }
        do {
            let row = decode1(0x5e281800)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "sha1su1 v0.4s, v0.4s")
        }
        do {
            let row = decode1(0x5e282800)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "sha256su0 v0.4s, v0.4s")
        }
    }

    // DP05-C06: minimized dot vectors from DP05/extracted/fixtures/decoder-disagreements.json.
    func testRejectScalarCopyReservedOp() {
        let reservedWords: [UInt32] = [
            0x7e010400,
            0x7e020400,
            0x7e040400,
            0x7e080400,
            0x7e0f0400,
            0x7e110400,
            0x7e120400,
            0x7e140400,
            0x7e180400,
            0x7e1f0400,
        ]
        for word in reservedWords {
            XCTAssertEqual(decode1(word).mnemonic, "unknown", String(format: "DP05-C06 0x%08x", word))
        }

        do {
            let row = decode1(0x5e010400)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "mov b0, v0.b[0]")
        }
        do {
            let row = decode1(0x5e020400)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "mov h0, v0.h[0]")
        }
        do {
            let row = decode1(0x5e040400)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "mov s0, v0.s[0]")
        }
        do {
            let row = decode1(0x5e080400)
            XCTAssertEqual("\(row.mnemonic) \(row.operands)", "mov d0, v0.d[0]")
        }
    }

    func testDecoderRecognizesSIMDModifiedImmediate() {
        var bytes = Data()
        bytes.appendUInt32LE(0x6f00_e400) // movi v0.2d, #0
        bytes.appendUInt32LE(0x4f07_e7e0) // movi v0.16b, #0xff
        bytes.appendUInt32LE(0x4f00_0420) // movi v0.4s, #1
        bytes.appendUInt32LE(0x4f00_2420) // movi v0.4s, #1, lsl #8
        bytes.appendUInt32LE(0x0f02_e6a0) // movi v0.8b, #0x55
        bytes.appendUInt32LE(0x6f07_07e0) // mvni v0.4s, #0xff
        bytes.appendUInt32LE(0x0f00_8600) // movi v0.4h, #0x10
        bytes.appendUInt32LE(0x0f00_0400) // movi v0.2s, #0

        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1_0000_c000)

        XCTAssertEqual(rows.map(\.mnemonic), ["movi", "movi", "movi", "movi", "movi", "mvni", "movi", "movi"])
        XCTAssertEqual(rows.map(\.operands), [
            "v0.2d, #0",
            "v0.16b, #0xff",
            "v0.4s, #1",
            "v0.4s, #1, lsl #8",
            "v0.8b, #0x55",
            "v0.4s, #0xff",
            "v0.4h, #0x10",
            "v0.2s, #0"
        ])
    }

    /// SIMD structure load/store (the implemented ld1/ld2/st4 multiple-structure + post-index forms)
    /// and CAS/CASP. Ground truth: `clang -arch arm64` + `otool` (canonical arrangement syntax).
    func testSIMDStructureAndCASDecodes() {
        func text(_ w: UInt32) -> String { let r = decode1(w); return "\(r.mnemonic) \(r.operands)" }
        XCTAssertEqual(text(0x4c40a0a0), "ld1 {v0.16b, v1.16b}, [x5]")
        XCTAssertEqual(text(0x0cdf80c0), "ld2 {v0.8b, v1.8b}, [x6], #16")          // post-index immediate
        XCTAssertEqual(text(0x4c880ce0), "st4 {v0.2d, v1.2d, v2.2d, v3.2d}, [x7], x8") // post-index register
        XCTAssertEqual(text(0x88a07c41), "cas w0, w1, [x2]")
        XCTAssertEqual(text(0xc8e0fc61), "casal x0, x1, [x3]")
        XCTAssertEqual(text(0x48207c82), "casp x0, x1, x2, x3, [x4]")
        // suffix order is acquire/release THEN size (casalb, not casbal)
        XCTAssertEqual(text(0x08e0fc41), "casalb w0, w1, [x2]")
        XCTAssertEqual(text(0x08e07c41), "casab w0, w1, [x2]")
        XCTAssertEqual(text(0x48e0fc41), "casalh w0, w1, [x2]")
    }

    /// CAS/CASP share the bits[29:24]=0x08 load/store-exclusive space with ldxr/stxr/ldar/stlr/ldxp.
    /// decodeCAS must REJECT those so they reach the exclusive-family decoder and render as their
    /// real mnemonic — never mis-decoded as a CAS. (otool-verified 32-bit forms.)
    func testCASDoesNotShadowLoadStoreExclusive() {
        func text(_ w: UInt32) -> String { let r = decode1(w); return "\(r.mnemonic) \(r.operands)" }
        XCTAssertEqual(text(0x885f7c20), "ldxr w0, [x1]")
        XCTAssertEqual(text(0x88027c20), "stxr w2, w0, [x1]")
        XCTAssertEqual(text(0x88dffc20), "ldar w0, [x1]")
        XCTAssertEqual(text(0x889ffc20), "stlr w0, [x1]")
        XCTAssertEqual(text(0xc87f0440), "ldxp x0, x1, [x2]")
        XCTAssertEqual(text(0x885ffc20), "ldaxr w0, [x1]")
    }

    /// Package E: the full AdvSIMD load/store structure matrix (multiple + single/lane + replicate)
    /// and the SIMD-copy extract forms (umov/smov/ins). Every word is ground-truthed against
    /// `clang -arch arm64` + `otool -tvVj`; otool's `mov`/`umov`-alias surface is translated to the
    /// canonical AArch64 rendering the decoder emits (e.g. otool `mov.s v0[1], w5` → `ins v0.s[1], w5`).
    func testSIMDStructureAndCopyDecodes() {
        func text(_ w: UInt32) -> String { let r = decode1(w); return "\(r.mnemonic) \(r.operands)" }

        // --- multiple-structure: register counts 1–4 across arrangements ---
        XCTAssertEqual(text(0x4c407000), "ld1 {v0.16b}, [x0]")
        XCTAssertEqual(text(0x4c40a420), "ld1 {v0.8h, v1.8h}, [x1]")
        XCTAssertEqual(text(0x4c406840), "ld1 {v0.4s, v1.4s, v2.4s}, [x2]")
        XCTAssertEqual(text(0x4c402c60), "ld1 {v0.2d, v1.2d, v2.2d, v3.2d}, [x3]")
        XCTAssertEqual(text(0x0c408480), "ld2 {v0.4h, v1.4h}, [x4]")
        XCTAssertEqual(text(0x0c4048a0), "ld3 {v0.2s, v1.2s, v2.2s}, [x5]")
        XCTAssertEqual(text(0x0c4000c0), "ld4 {v0.8b, v1.8b, v2.8b, v3.8b}, [x6]")
        XCTAssertEqual(text(0x0c0070c5), "st1 {v5.8b}, [x6]")
        XCTAssertEqual(text(0x4c0088e0), "st2 {v0.4s, v1.4s}, [x7]")
        XCTAssertEqual(text(0x4c880ce0), "st4 {v0.2d, v1.2d, v2.2d, v3.2d}, [x7], x8") // post-index register
        XCTAssertEqual(text(0x4cdf2120), "ld1 {v0.16b, v1.16b, v2.16b, v3.16b}, [x9], #64") // post-index imm
        XCTAssertEqual(text(0x0cdf80c0), "ld2 {v0.8b, v1.8b}, [x6], #16")
        XCTAssertEqual(text(0x4c40ac1f), "ld1 {v31.2d, v0.2d}, [x0]") // register-list wrap past v31
        // `.1d` arrangement is valid ONLY for ld1/st1 (not ld2/3/4 — see DeliberateGaps).
        XCTAssertEqual(text(0x0c407c20), "ld1 {v0.1d}, [x1]")
        XCTAssertEqual(text(0x0c40ac20), "ld1 {v0.1d, v1.1d}, [x1]")

        // --- single-structure (one-lane) forms, lane index from Q:S:size ---
        XCTAssertEqual(text(0x0d400c00), "ld1 {v0.b}[3], [x0]")
        XCTAssertEqual(text(0x0d604840), "ld2 {v0.h, v1.h}[1], [x2]")
        XCTAssertEqual(text(0x4d40a060), "ld3 {v0.s, v1.s, v2.s}[2], [x3]")
        XCTAssertEqual(text(0x4d60a480), "ld4 {v0.d, v1.d, v2.d, v3.d}[1], [x4]")
        XCTAssertEqual(text(0x0d9f1420), "st1 {v0.b}[5], [x1], #1")        // post-index imm (stride = elem bytes)
        XCTAssertEqual(text(0x4dffb080), "ld4 {v0.s, v1.s, v2.s, v3.s}[3], [x4], #16")
        XCTAssertEqual(text(0x0dc90020), "ld1 {v0.b}[0], [x1], x9")        // post-index REGISTER (not undefined)
        XCTAssertEqual(text(0x0da90440), "st2 {v0.b, v1.b}[1], [x2], x9")

        // --- replicate (ldNr), incl. post-index register + immediate ---
        XCTAssertEqual(text(0x4d40c8c0), "ld1r {v0.4s}, [x6]")
        XCTAssertEqual(text(0x4d60c4e0), "ld2r {v0.8h, v1.8h}, [x7]")
        XCTAssertEqual(text(0x4d60e100), "ld4r {v0.16b, v1.16b, v2.16b, v3.16b}, [x8]")
        XCTAssertEqual(text(0x0dc9c020), "ld1r {v0.8b}, [x1], x9")          // post-index register
        XCTAssertEqual(text(0x4ddfc820), "ld1r {v0.4s}, [x1], #4")          // post-index imm (stride = elem bytes × N)
        XCTAssertEqual(text(0x4dffc820), "ld2r {v0.4s, v1.4s}, [x1], #8")

        // --- SIMD copy: ins (general & element), umov, smov ---
        XCTAssertEqual(text(0x4e0c1ca0), "ins v0.s[1], w5")
        XCTAssertEqual(text(0x4e081cc0), "ins v0.d[0], x6")
        XCTAssertEqual(text(0x6e0f2c20), "ins v0.b[7], v1.b[5]") // element-insert: src lane = imm4 >> size
        XCTAssertEqual(text(0x6e063420), "ins v0.h[1], v1.h[3]")
        XCTAssertEqual(text(0x6e0c4420), "ins v0.s[1], v1.s[2]")
        XCTAssertEqual(text(0x6e180420), "ins v0.d[1], v1.d[0]")
        XCTAssertEqual(text(0x0e013c20), "umov w0, v1.b[0]")
        XCTAssertEqual(text(0x0e1c3c20), "umov w0, v1.s[3]")
        XCTAssertEqual(text(0x4e183c20), "umov x0, v1.d[1]")
        XCTAssertEqual(text(0x0e043c20), "umov w0, v1.s[0]") // was a deliberate gap in Package D; now decoded
        XCTAssertEqual(text(0x0e0a2c20), "smov w0, v1.h[2]")
        XCTAssertEqual(text(0x4e0c2c20), "smov x0, v1.s[1]")
    }

    /// Deliberate gaps: reserved structure/copy encodings must stay `unknown`, never a fabricated decode.
    func testSIMDStructureAndCopyDeliberateGaps() {
        XCTAssertEqual(decode1(0x0dc88920).mnemonic, "unknown") // single-structure scale=2 with size[1]=1 — reserved
        XCTAssertEqual(decode1(0x0e083c20).mnemonic, "unknown") // umov .d with Q=0 — reserved (d-element needs Q=1)
        XCTAssertEqual(decode1(0x0c408c40).mnemonic, "unknown") // ld2 with .1d (size=3,Q=0) — reserved (only ld1/st1 allow .1d)
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
