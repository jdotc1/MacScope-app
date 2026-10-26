import Foundation
import XCTest
@testable import MacScope

/// Breadth tests for the EVEX/AVX-512 renderer. Byte sequences and renderings
/// are derived from `clang -arch x86_64 -mavx512f -mavx512bw -mavx512dq` plus
/// `otool -tvVj`; memory spellings use the relocation-free `llvm-objdump`
/// AT&T form because the decoder sees only bytes, not object-file symbols.
final class X86EVEXBreadthOracleTests: XCTestCase {
    private let decoder = X86_64Decoder()

    private func one(_ bytes: [UInt8], at address: UInt64 = 0x1000) -> DecodedInstruction {
        let rows = decoder.decode(Data(bytes), baseAddress: address, maxInstructionCount: 1)
        return rows[0]
    }

    private func assertDecode(_ bytes: [UInt8], _ mnemonic: String, _ operands: String,
                              length: Int? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let r = one(bytes)
        XCTAssertEqual(r.mnemonic, mnemonic, "mnemonic", file: file, line: line)
        XCTAssertEqual(r.operands, operands, "operands", file: file, line: line)
        XCTAssertEqual(r.bytes.count, length ?? bytes.count, "length", file: file, line: line)
    }

    private func sweep(_ bytes: [UInt8], n: Int = 8) -> [DecodedInstruction] {
        decoder.decode(Data(bytes), baseAddress: 0x1000, maxInstructionCount: n)
    }

    // MARK: - Data movement

    func testEVEXAlignedAndUnalignedMoves() {
        // 62 f1 7d 48 6f c2  ->  vmovdqa32 %zmm2, %zmm0
        assertDecode([0x62, 0xF1, 0x7D, 0x48, 0x6F, 0xC2],
                     "vmovdqa32", "%zmm2, %zmm0", length: 6)
        // 62 f1 fd 48 6f c2  ->  vmovdqa64 %zmm2, %zmm0
        assertDecode([0x62, 0xF1, 0xFD, 0x48, 0x6F, 0xC2],
                     "vmovdqa64", "%zmm2, %zmm0", length: 6)
        // 62 f1 7f 48 6f c2  ->  vmovdqu8 %zmm2, %zmm0
        assertDecode([0x62, 0xF1, 0x7F, 0x48, 0x6F, 0xC2],
                     "vmovdqu8", "%zmm2, %zmm0", length: 6)
        // 62 f1 ff 48 6f c2  ->  vmovdqu16 %zmm2, %zmm0
        assertDecode([0x62, 0xF1, 0xFF, 0x48, 0x6F, 0xC2],
                     "vmovdqu16", "%zmm2, %zmm0", length: 6)
        // 62 f1 7e 48 6f c2  ->  vmovdqu32 %zmm2, %zmm0
        assertDecode([0x62, 0xF1, 0x7E, 0x48, 0x6F, 0xC2],
                     "vmovdqu32", "%zmm2, %zmm0", length: 6)
        // 62 f1 fe 48 6f c2  ->  vmovdqu64 %zmm2, %zmm0
        assertDecode([0x62, 0xF1, 0xFE, 0x48, 0x6F, 0xC2],
                     "vmovdqu64", "%zmm2, %zmm0", length: 6)
    }

    func testEVEXFloatMovesAndStores() {
        // 62 f1 7c 48 28 c2  ->  vmovaps %zmm2, %zmm0
        assertDecode([0x62, 0xF1, 0x7C, 0x48, 0x28, 0xC2],
                     "vmovaps", "%zmm2, %zmm0", length: 6)
        // 62 f1 fd 48 28 c2  ->  vmovapd %zmm2, %zmm0
        assertDecode([0x62, 0xF1, 0xFD, 0x48, 0x28, 0xC2],
                     "vmovapd", "%zmm2, %zmm0", length: 6)
        // 62 f1 7c 48 10 c2  ->  vmovups %zmm2, %zmm0
        assertDecode([0x62, 0xF1, 0x7C, 0x48, 0x10, 0xC2],
                     "vmovups", "%zmm2, %zmm0", length: 6)
        // 62 f1 fd 48 11 07  ->  vmovupd %zmm0, (%rdi)
        assertDecode([0x62, 0xF1, 0xFD, 0x48, 0x11, 0x07],
                     "vmovupd", "%zmm0, (%rdi)", length: 6)
    }

    func testEVEXMaskedMoveLoad() {
        // 62 f1 7e c9 6f ca  ->  vmovdqu32 %zmm2, %zmm1 {%k1} {z}
        assertDecode([0x62, 0xF1, 0x7E, 0xC9, 0x6F, 0xCA],
                     "vmovdqu32", "%zmm2, %zmm1 {%k1} {z}", length: 6)
    }

    // MARK: - Logical and integer arithmetic

    func testEVEXLogicalDwordAndQword() {
        // 62 f1 75 48 ef c2  ->  vpxord %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0x75, 0x48, 0xEF, 0xC2],
                     "vpxord", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f1 f5 48 ef c2  ->  vpxorq %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0xF5, 0x48, 0xEF, 0xC2],
                     "vpxorq", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f1 75 48 db c2  ->  vpandd %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0x75, 0x48, 0xDB, 0xC2],
                     "vpandd", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f1 f5 48 db c2  ->  vpandq %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0xF5, 0x48, 0xDB, 0xC2],
                     "vpandq", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f1 75 48 df c2  ->  vpandnd %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0x75, 0x48, 0xDF, 0xC2],
                     "vpandnd", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f1 f5 48 eb c2  ->  vporq %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0xF5, 0x48, 0xEB, 0xC2],
                     "vporq", "%zmm2, %zmm1, %zmm0", length: 6)
    }

    func testEVEXIntegerArithmetic() {
        // 62 f1 75 48 fc c2  ->  vpaddb %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0x75, 0x48, 0xFC, 0xC2],
                     "vpaddb", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f1 75 48 fd c2  ->  vpaddw %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0x75, 0x48, 0xFD, 0xC2],
                     "vpaddw", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f1 75 48 fe c2  ->  vpaddd %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0x75, 0x48, 0xFE, 0xC2],
                     "vpaddd", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f1 f5 48 d4 c2  ->  vpaddq %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0xF5, 0x48, 0xD4, 0xC2],
                     "vpaddq", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f1 75 48 f8 c2  ->  vpsubb %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0x75, 0x48, 0xF8, 0xC2],
                     "vpsubb", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f1 f5 48 fb c2  ->  vpsubq %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0xF5, 0x48, 0xFB, 0xC2],
                     "vpsubq", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f2 75 48 40 c2  ->  vpmulld %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF2, 0x75, 0x48, 0x40, 0xC2],
                     "vpmulld", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f2 f5 48 40 c2  ->  vpmullq %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x40, 0xC2],
                     "vpmullq", "%zmm2, %zmm1, %zmm0", length: 6)
    }

    // MARK: - Floating point arithmetic and FMA

    func testEVEXFloatArithmetic() {
        // 62 f1 74 48 59 c2  ->  vmulps %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0x74, 0x48, 0x59, 0xC2],
                     "vmulps", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f1 f5 48 59 c2  ->  vmulpd %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0xF5, 0x48, 0x59, 0xC2],
                     "vmulpd", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f1 74 48 5c c2  ->  vsubps %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0x74, 0x48, 0x5C, 0xC2],
                     "vsubps", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f1 f5 48 5e c2  ->  vdivpd %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0xF5, 0x48, 0x5E, 0xC2],
                     "vdivpd", "%zmm2, %zmm1, %zmm0", length: 6)
    }

    func testEVEXFMAFamilies() {
        // 62 f2 75 48 98 c2  ->  vfmadd132ps %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF2, 0x75, 0x48, 0x98, 0xC2],
                     "vfmadd132ps", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f2 75 48 a8 c2  ->  vfmadd213ps %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF2, 0x75, 0x48, 0xA8, 0xC2],
                     "vfmadd213ps", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f2 75 48 b8 c2  ->  vfmadd231ps %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF2, 0x75, 0x48, 0xB8, 0xC2],
                     "vfmadd231ps", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f2 f5 48 98 c2  ->  vfmadd132pd %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x98, 0xC2],
                     "vfmadd132pd", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f2 f5 48 a8 c2  ->  vfmadd213pd %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF2, 0xF5, 0x48, 0xA8, 0xC2],
                     "vfmadd213pd", "%zmm2, %zmm1, %zmm0", length: 6)
        // 62 f2 f5 48 b8 c2  ->  vfmadd231pd %zmm2, %zmm1, %zmm0
        assertDecode([0x62, 0xF2, 0xF5, 0x48, 0xB8, 0xC2],
                     "vfmadd231pd", "%zmm2, %zmm1, %zmm0", length: 6)
    }

    // MARK: - Compare to mask

    func testEVEXCompareToMask() {
        // 62 f1 75 48 76 c2  ->  vpcmpeqd %zmm2, %zmm1, %k0
        assertDecode([0x62, 0xF1, 0x75, 0x48, 0x76, 0xC2],
                     "vpcmpeqd", "%zmm2, %zmm1, %k0", length: 6)
        // 62 f2 f5 48 29 c2  ->  vpcmpeqq %zmm2, %zmm1, %k0
        assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x29, 0xC2],
                     "vpcmpeqq", "%zmm2, %zmm1, %k0", length: 6)
        // 62 f1 75 48 66 c2  ->  vpcmpgtd %zmm2, %zmm1, %k0
        assertDecode([0x62, 0xF1, 0x75, 0x48, 0x66, 0xC2],
                     "vpcmpgtd", "%zmm2, %zmm1, %k0", length: 6)
        // 62 f2 f5 48 37 c2  ->  vpcmpgtq %zmm2, %zmm1, %k0
        assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x37, 0xC2],
                     "vpcmpgtq", "%zmm2, %zmm1, %k0", length: 6)
        // 62 f1 74 48 c2 c2 00  ->  vcmpeqps %zmm2, %zmm1, %k0
        assertDecode([0x62, 0xF1, 0x74, 0x48, 0xC2, 0xC2, 0x00],
                     "vcmpeqps", "%zmm2, %zmm1, %k0", length: 7)
        // 62 f1 f5 48 c2 c2 00  ->  vcmpeqpd %zmm2, %zmm1, %k0
        assertDecode([0x62, 0xF1, 0xF5, 0x48, 0xC2, 0xC2, 0x00],
                     "vcmpeqpd", "%zmm2, %zmm1, %k0", length: 7)
    }

    func testEVEXCompareMaskAndPredicateDecorations() {
        // 62 f1 75 4a 76 da  ->  vpcmpeqd %zmm2, %zmm1, %k3 {%k2}
        assertDecode([0x62, 0xF1, 0x75, 0x4A, 0x76, 0xDA],
                     "vpcmpeqd", "%zmm2, %zmm1, %k3 {%k2}", length: 6)
        // 62 f1 74 4a c2 da 01  ->  vcmpltps %zmm2, %zmm1, %k3 {%k2}
        assertDecode([0x62, 0xF1, 0x74, 0x4A, 0xC2, 0xDA, 0x01],
                     "vcmpltps", "%zmm2, %zmm1, %k3 {%k2}", length: 7)
        // 62 f1 74 58 c2 1f 05  ->  vcmpnltps (%rdi){1to16}, %zmm1, %k3
        assertDecode([0x62, 0xF1, 0x74, 0x58, 0xC2, 0x1F, 0x05],
                     "vcmpnltps", "(%rdi){1to16}, %zmm1, %k3", length: 7)
    }

    // MARK: - EVEX decorations and register breadth

    func testEVEXBroadcastDecorations() {
        // 62 f1 75 58 fe 07  ->  vpaddd (%rdi){1to16}, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0x75, 0x58, 0xFE, 0x07],
                     "vpaddd", "(%rdi){1to16}, %zmm1, %zmm0", length: 6)
        // 62 f1 f5 58 d4 07  ->  vpaddq (%rdi){1to8}, %zmm1, %zmm0
        assertDecode([0x62, 0xF1, 0xF5, 0x58, 0xD4, 0x07],
                     "vpaddq", "(%rdi){1to8}, %zmm1, %zmm0", length: 6)
        // 62 f1 74 18 58 07  ->  vaddps (%rdi){1to4}, %xmm1, %xmm0
        assertDecode([0x62, 0xF1, 0x74, 0x18, 0x58, 0x07],
                     "vaddps", "(%rdi){1to4}, %xmm1, %xmm0", length: 6)
        // 62 f1 f5 18 58 07  ->  vaddpd (%rdi){1to2}, %xmm1, %xmm0
        assertDecode([0x62, 0xF1, 0xF5, 0x18, 0x58, 0x07],
                     "vaddpd", "(%rdi){1to2}, %xmm1, %xmm0", length: 6)
    }

    func testEVEXHighVectorRegisters() {
        // 62 a1 74 40 58 c2  ->  vaddps %zmm18, %zmm17, %zmm16
        assertDecode([0x62, 0xA1, 0x74, 0x40, 0x58, 0xC2],
                     "vaddps", "%zmm18, %zmm17, %zmm16", length: 6)
        // 62 01 0c 40 58 ef  ->  vaddps %zmm31, %zmm30, %zmm29
        assertDecode([0x62, 0x01, 0x0C, 0x40, 0x58, 0xEF],
                     "vaddps", "%zmm31, %zmm30, %zmm29", length: 6)
        // 62 d1 74 48 58 00  ->  vaddps (%r8), %zmm1, %zmm0
        assertDecode([0x62, 0xD1, 0x74, 0x48, 0x58, 0x00],
                     "vaddps", "(%r8), %zmm1, %zmm0", length: 6)
    }

    // MARK: - Desync guards

    func testRenderedEVEXThenRetDesyncGuard() {
        let rows = sweep([0x62, 0xF2, 0xF5, 0x48, 0x40, 0xC2, 0xC3])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "vpmullq")
        XCTAssertEqual(rows[0].bytes.count, 6)
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 6)
    }

    // 0x73 is the vector shift-by-immediate group (ModRM.reg is an opcode extension), not yet
    // rendered — it exercises the map1 imm8 PLACEHOLDER path: the decoder must still consume the
    // trailing imm8 (7 bytes total) so a following ret does not desync. (0xC6/vshufps, the old
    // example here, is now a rendered form covered by X86EVEXDisassemblyTests.)
    func testEVEXMap1ImmediatePlaceholderThenRetDesyncGuard() {
        let rows = sweep([0x62, 0xF1, 0x74, 0x48, 0x73, 0xC2, 0x1B, 0xC3])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "(evex)")
        XCTAssertEqual(rows[0].bytes.count, 7)
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 7)
    }

    // 0xB4 is vpmadd52luq (AVX512-IFMA), still unrendered — it exercises the map2 (0F38) PLACEHOLDER
    // path: the decoder must consume the ModRM (6 bytes total) so a following ret does not desync.
    // (0x99/vfmadd132ss, the old example here, is now a rendered form covered by X86EVEXFMATests.)
    func testEVEXMap2PlaceholderThenRetDesyncGuard() {
        let rows = sweep([0x62, 0xF2, 0x75, 0x48, 0xB4, 0xC2, 0xC3])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "(evex38)")
        XCTAssertEqual(rows[0].bytes.count, 6)
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 6)
    }
}
