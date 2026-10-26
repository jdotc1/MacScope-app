import Foundation
import XCTest
@testable import MacScope

/// Tests for EVEX/AVX-512 decoding. Ground-truth byte sequences and renderings
/// come from `clang -arch x86_64` + `otool -tvVj`. Coverage spans the Full-tuple
/// arithmetic/logic/permute/shuffle/convert/compare families across maps 1–3
/// (non-Full tuples — broadcasts, widening converts, vpcmpd predicates — are
/// deliberately deferred and stay length-correct placeholders). Each test asserts
/// mnemonic, operands, and instruction length; the memory-operand cases prove the
/// compressed-disp8 (Full-tuple = vector-length) scaling, and desync-guard tests
/// prove the variable-length sweep stays byte-synchronized across an EVEX form.
final class X86EVEXDisassemblyTests: XCTestCase {
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

    private func sweep(_ bytes: [UInt8]) -> [DecodedInstruction] {
        return decoder.decode(Data(bytes), baseAddress: 0x1000, maxInstructionCount: 8)
    }

    // 62 f1 74 48 58 c2  ->  vaddps %zmm2, %zmm1, %zmm0   (otool ground truth)
    func testEVEXVaddpsZmm() {
        assertDecode([0x62, 0xF1, 0x74, 0x48, 0x58, 0xC2],
                     "vaddps", "%zmm2, %zmm1, %zmm0")
    }

    // 62 f1 f5 48 58 c2  ->  vaddpd %zmm2, %zmm1, %zmm0   (66 prefix via pp=1, W=1)
    func testEVEXVaddpdZmm() {
        assertDecode([0x62, 0xF1, 0xF5, 0x48, 0x58, 0xC2],
                     "vaddpd", "%zmm2, %zmm1, %zmm0")
    }

    // 62 f1 75 29 fe c2  ->  vpaddd %ymm2, %ymm1, %ymm0 {%k1}   (LL=01 -> ymm, aaa=1)
    func testEVEXVpadddYmmWithMask() {
        assertDecode([0x62, 0xF1, 0x75, 0x29, 0xFE, 0xC2],
                     "vpaddd", "%ymm2, %ymm1, %ymm0 {%k1}")
    }

    // 62 f1 74 c9 58 c2  ->  vaddps %zmm2, %zmm1, %zmm0 {%k1} {z}  (z + mask, otool spacing)
    func testEVEXVaddpsZmmZeroingMask() {
        assertDecode([0x62, 0xF1, 0x74, 0xC9, 0x58, 0xC2],
                     "vaddps", "%zmm2, %zmm1, %zmm0 {%k1} {z}")
    }

    // 62 f3 75 48 25 c2 96  ->  vpternlogd $0x96, %zmm2, %zmm1, %zmm0
    func testEVEXMap3VpternlogdZmm() {
        assertDecode([0x62, 0xF3, 0x75, 0x48, 0x25, 0xC2, 0x96],
                     "vpternlogd", "$0x96, %zmm2, %zmm1, %zmm0", length: 7)
    }

    // 62 f1 75 48 fe 47 01  ->  vpaddd 0x40(%rdi), %zmm1, %zmm0
    func testEVEXVpadddCompressedDisp8Scale() {
        assertDecode([0x62, 0xF1, 0x75, 0x48, 0xFE, 0x47, 0x01],
                     "vpaddd", "0x40(%rdi), %zmm1, %zmm0", length: 7)
    }

    // 62 f1 74 48 58 47 02  ->  vaddps 0x80(%rdi), %zmm1, %zmm0
    func testEVEXVaddpsCompressedDisp8Scale() {
        assertDecode([0x62, 0xF1, 0x74, 0x48, 0x58, 0x47, 0x02],
                     "vaddps", "0x80(%rdi), %zmm1, %zmm0", length: 7)
    }

    // 62 f1 f5 48 58 47 01  ->  vaddpd 0x40(%rdi), %zmm1, %zmm0
    func testEVEXVaddpdCompressedDisp8Scale() {
        assertDecode([0x62, 0xF1, 0xF5, 0x48, 0x58, 0x47, 0x01],
                     "vaddpd", "0x40(%rdi), %zmm1, %zmm0", length: 7)
    }

    // Desync guard: an EVEX instruction (6 bytes) followed by ret (0xc3, 1 byte)
    // must decode as exactly two instructions, with ret at the correct address.
    func testEVEXDesyncGuard() {
        let stream: [UInt8] = [0x62, 0xF1, 0x74, 0x48, 0x58, 0xC2, 0xC3]
        let rows = sweep(stream)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "vaddps")
        XCTAssertEqual(rows[0].bytes.count, 6)
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 6)
    }

    // An unrecognized EVEX map-1 opcode must still consume the full encoding length
    // (3 payload + opcode + ModRM) and not desync a trailing ret.
    func testEVEXUnknownOpcodeLengthCorrect() {
        // 62 f1 74 48 <unknown 0x59=vmulps not mapped> c2  ->  6 bytes, generic mnemonic.
        let stream: [UInt8] = [0x62, 0xF1, 0x74, 0x48, 0x59, 0xC2, 0xC3]
        let rows = sweep(stream)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].bytes.count, 6)
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 6)
    }

    // 62 f3 75 48 99 c2 7f  ->  unmapped EVEX map-3 opcode with ModRM + imm8
    func testEVEXUnknownMap3OpcodeLengthCorrect() {
        let stream: [UInt8] = [0x62, 0xF3, 0x75, 0x48, 0x99, 0xC2, 0x7F, 0xC3]
        let rows = sweep(stream)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "(evex3a)")
        XCTAssertEqual(rows[0].bytes.count, 7)
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 7)
    }

    // MARK: - Full-tuple breadth (map1/map2/map3), clang -arch x86_64 + otool -tvVj ground truth.
    // All register forms are 6 bytes (3 EVEX payload + opcode + ModRM); imm forms add 1.

    // --- map1 arithmetic (evexRegRM) ---
    func testEVEXVmaxps()  { assertDecode([0x62, 0xF1, 0x74, 0x48, 0x5F, 0xC2], "vmaxps",  "%zmm2, %zmm1, %zmm0") }
    func testEVEXVmaxpd()  { assertDecode([0x62, 0xF1, 0xF5, 0x48, 0x5F, 0xC2], "vmaxpd",  "%zmm2, %zmm1, %zmm0") }
    func testEVEXVminps()  { assertDecode([0x62, 0xF1, 0x74, 0x48, 0x5D, 0xC2], "vminps",  "%zmm2, %zmm1, %zmm0") }
    func testEVEXVminpd()  { assertDecode([0x62, 0xF1, 0xF5, 0x48, 0x5D, 0xC2], "vminpd",  "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpmuludq() { assertDecode([0x62, 0xF1, 0xF5, 0x48, 0xF4, 0xC2], "vpmuludq", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpunpcklqdq() { assertDecode([0x62, 0xF1, 0xF5, 0x48, 0x6C, 0xC2], "vpunpcklqdq", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpunpckhqdq() { assertDecode([0x62, 0xF1, 0xF5, 0x48, 0x6D, 0xC2], "vpunpckhqdq", "%zmm2, %zmm1, %zmm0") }

    // --- map1 unary (evexUnary) ---
    func testEVEXVsqrtps()    { assertDecode([0x62, 0xF1, 0x7C, 0x48, 0x51, 0xC1], "vsqrtps",    "%zmm1, %zmm0") }
    func testEVEXVsqrtpd()    { assertDecode([0x62, 0xF1, 0xFD, 0x48, 0x51, 0xC1], "vsqrtpd",    "%zmm1, %zmm0") }
    func testEVEXVcvtdq2ps()  { assertDecode([0x62, 0xF1, 0x7C, 0x48, 0x5B, 0xC1], "vcvtdq2ps",  "%zmm1, %zmm0") }
    func testEVEXVcvtps2dq()  { assertDecode([0x62, 0xF1, 0x7D, 0x48, 0x5B, 0xC1], "vcvtps2dq",  "%zmm1, %zmm0") }
    func testEVEXVcvttps2dq() { assertDecode([0x62, 0xF1, 0x7E, 0x48, 0x5B, 0xC1], "vcvttps2dq", "%zmm1, %zmm0") }

    // --- map1 imm shuffle (evexUnaryImm / evexImmRegRM) ---
    func testEVEXVpshufd() { assertDecode([0x62, 0xF1, 0x7D, 0x48, 0x70, 0xC1, 0x1B], "vpshufd", "$0x1b, %zmm1, %zmm0", length: 7) }
    func testEVEXVshufps() { assertDecode([0x62, 0xF1, 0x74, 0x48, 0xC6, 0xC2, 0x1B], "vshufps", "$0x1b, %zmm2, %zmm1, %zmm0", length: 7) }
    func testEVEXVshufpd() { assertDecode([0x62, 0xF1, 0xF5, 0x48, 0xC6, 0xC2, 0x03], "vshufpd", "$0x3, %zmm2, %zmm1, %zmm0", length: 7) }

    // --- map2 (evexRegRM), d/q selected by W ---
    func testEVEXVpmuldq() { assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x28, 0xC2], "vpmuldq", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpsllvd() { assertDecode([0x62, 0xF2, 0x75, 0x48, 0x47, 0xC2], "vpsllvd", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpsllvq() { assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x47, 0xC2], "vpsllvq", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpsrlvd() { assertDecode([0x62, 0xF2, 0x75, 0x48, 0x45, 0xC2], "vpsrlvd", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpsrlvq() { assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x45, 0xC2], "vpsrlvq", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpsravd() { assertDecode([0x62, 0xF2, 0x75, 0x48, 0x46, 0xC2], "vpsravd", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpsravq() { assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x46, 0xC2], "vpsravq", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpermd()  { assertDecode([0x62, 0xF2, 0x75, 0x48, 0x36, 0xC2], "vpermd",  "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpermps() { assertDecode([0x62, 0xF2, 0x75, 0x48, 0x16, 0xC2], "vpermps", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpermpd() { assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x16, 0xC2], "vpermpd", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpminsd() { assertDecode([0x62, 0xF2, 0x75, 0x48, 0x39, 0xC2], "vpminsd", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpminsq() { assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x39, 0xC2], "vpminsq", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpmaxsd() { assertDecode([0x62, 0xF2, 0x75, 0x48, 0x3D, 0xC2], "vpmaxsd", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpmaxsq() { assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x3D, 0xC2], "vpmaxsq", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpminud() { assertDecode([0x62, 0xF2, 0x75, 0x48, 0x3B, 0xC2], "vpminud", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpminuq() { assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x3B, 0xC2], "vpminuq", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpmaxud() { assertDecode([0x62, 0xF2, 0x75, 0x48, 0x3F, 0xC2], "vpmaxud", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpmaxuq() { assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x3F, 0xC2], "vpmaxuq", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpshufb() { assertDecode([0x62, 0xF2, 0x75, 0x48, 0x00, 0xC2], "vpshufb", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpblendmd() { assertDecode([0x62, 0xF2, 0x75, 0x48, 0x64, 0xC2], "vpblendmd", "%zmm2, %zmm1, %zmm0") }
    func testEVEXVpblendmq() { assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x64, 0xC2], "vpblendmq", "%zmm2, %zmm1, %zmm0") }

    // --- map2 unary (evexUnary); vpabsd=0x1E, vpabsq=0x1F (distinct opcodes) ---
    func testEVEXVpabsd() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x1E, 0xC1], "vpabsd", "%zmm1, %zmm0") }
    func testEVEXVpabsq() { assertDecode([0x62, 0xF2, 0xFD, 0x48, 0x1F, 0xC1], "vpabsq", "%zmm1, %zmm0") }

    // --- map2 mask-dest (evexMaskRegRM) ---
    func testEVEXVptestmd() { assertDecode([0x62, 0xF2, 0x75, 0x48, 0x27, 0xC2], "vptestmd", "%zmm2, %zmm1, %k0") }
    func testEVEXVptestmq() { assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x27, 0xC2], "vptestmq", "%zmm2, %zmm1, %k0") }

    // --- map3 imm unary (evexUnaryImm) ---
    func testEVEXVpermqImm() { assertDecode([0x62, 0xF3, 0xFD, 0x48, 0x00, 0xC1, 0x1B], "vpermq", "$0x1b, %zmm1, %zmm0", length: 7) }

    // --- memory + broadcast forms prove compressed-disp8 scaling (Full tuple = vector length) ---
    func testEVEXVmaxpsMem() { assertDecode([0x62, 0xF1, 0x74, 0x48, 0x5F, 0x47, 0x01], "vmaxps", "0x40(%rdi), %zmm1, %zmm0", length: 7) }
    func testEVEXVmaxpsBroadcast() { assertDecode([0x62, 0xF1, 0x74, 0x58, 0x5F, 0x47, 0x10], "vmaxps", "0x40(%rdi){1to16}, %zmm1, %zmm0", length: 7) }
    func testEVEXVsqrtpsMem() { assertDecode([0x62, 0xF1, 0x7C, 0x48, 0x51, 0x47, 0x02], "vsqrtps", "0x80(%rdi), %zmm0", length: 7) }
    func testEVEXVsqrtpsBroadcast() { assertDecode([0x62, 0xF1, 0x7C, 0x58, 0x51, 0x47, 0x10], "vsqrtps", "0x40(%rdi){1to16}, %zmm0", length: 7) }
    func testEVEXVpshufdMem() { assertDecode([0x62, 0xF1, 0x7D, 0x48, 0x70, 0x47, 0x01, 0x1B], "vpshufd", "$0x1b, 0x40(%rdi), %zmm0", length: 8) }
    func testEVEXVpabsdMem() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x1E, 0x47, 0x01], "vpabsd", "0x40(%rdi), %zmm0", length: 7) }
    func testEVEXVptestmdMem() { assertDecode([0x62, 0xF2, 0x75, 0x48, 0x27, 0x47, 0x01], "vptestmd", "0x40(%rdi), %zmm1, %k0", length: 7) }
    func testEVEXVpermqMem() { assertDecode([0x62, 0xF3, 0xFD, 0x48, 0x00, 0x47, 0x01, 0x1B], "vpermq", "$0x1b, 0x40(%rdi), %zmm0", length: 8) }

    // MARK: - Broadcast family (map2). Tuple scales measured empirically from otool
    // memory forms (disp 0x40): Tuple1Scalar = element size (1/2/4/8), sub-vector
    // Tuple2/4 = 16, Tuple8/4 = 32. Source register class varies (xmm / GPR / k-mask).

    // --- element broadcast, xmm source (Tuple1Scalar) ---
    func testEVEXVpbroadcastbXmm() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x78, 0xC8], "vpbroadcastb", "%xmm0, %zmm1") }
    func testEVEXVpbroadcastwXmm() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x79, 0xC8], "vpbroadcastw", "%xmm0, %zmm1") }
    func testEVEXVpbroadcastdXmm() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x58, 0xC8], "vpbroadcastd", "%xmm0, %zmm1") }
    func testEVEXVpbroadcastqXmm() { assertDecode([0x62, 0xF2, 0xFD, 0x48, 0x59, 0xC8], "vpbroadcastq", "%xmm0, %zmm1") }
    func testEVEXVbroadcastss()    { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x18, 0xC8], "vbroadcastss", "%xmm0, %zmm1") }
    func testEVEXVbroadcastsd()    { assertDecode([0x62, 0xF2, 0xFD, 0x48, 0x19, 0xC8], "vbroadcastsd", "%xmm0, %zmm1") }

    // --- element broadcast, GPR source ---
    func testEVEXVpbroadcastbGPR() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x7A, 0xC8], "vpbroadcastb", "%eax, %zmm1") }
    func testEVEXVpbroadcastwGPR() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x7B, 0xC8], "vpbroadcastw", "%eax, %zmm1") }
    func testEVEXVpbroadcastdGPR() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x7C, 0xC8], "vpbroadcastd", "%eax, %zmm1") }
    func testEVEXVpbroadcastqGPR() { assertDecode([0x62, 0xF2, 0xFD, 0x48, 0x7C, 0xC8], "vpbroadcastq", "%rax, %zmm1") }

    // --- element broadcast, memory source (Tuple1Scalar disp8 = element size) ---
    func testEVEXVpbroadcastbMem() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x78, 0x4F, 0x40], "vpbroadcastb", "0x40(%rdi), %zmm1", length: 7) }
    func testEVEXVpbroadcastwMem() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x79, 0x4F, 0x20], "vpbroadcastw", "0x40(%rdi), %zmm1", length: 7) }
    func testEVEXVpbroadcastdMem() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x58, 0x4F, 0x10], "vpbroadcastd", "0x40(%rdi), %zmm1", length: 7) }
    func testEVEXVpbroadcastqMem() { assertDecode([0x62, 0xF2, 0xFD, 0x48, 0x59, 0x4F, 0x08], "vpbroadcastq", "0x40(%rdi), %zmm1", length: 7) }
    func testEVEXVbroadcastssMem() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x18, 0x4F, 0x10], "vbroadcastss", "0x40(%rdi), %zmm1", length: 7) }
    func testEVEXVbroadcastsdMem() { assertDecode([0x62, 0xF2, 0xFD, 0x48, 0x19, 0x4F, 0x08], "vbroadcastsd", "0x40(%rdi), %zmm1", length: 7) }

    // --- sub-vector broadcast, memory-only (Tuple4/2 = 16 bytes; Tuple8/4 = 32 bytes) ---
    func testEVEXVbroadcastf32x4() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x1A, 0x47, 0x04], "vbroadcastf32x4", "0x40(%rdi), %zmm0", length: 7) }
    func testEVEXVbroadcasti32x4() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x5A, 0x47, 0x04], "vbroadcasti32x4", "0x40(%rdi), %zmm0", length: 7) }
    func testEVEXVbroadcastf64x2() { assertDecode([0x62, 0xF2, 0xFD, 0x48, 0x1A, 0x47, 0x04], "vbroadcastf64x2", "0x40(%rdi), %zmm0", length: 7) }
    func testEVEXVbroadcasti64x2() { assertDecode([0x62, 0xF2, 0xFD, 0x48, 0x5A, 0x47, 0x04], "vbroadcasti64x2", "0x40(%rdi), %zmm0", length: 7) }
    func testEVEXVbroadcastf32x8() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x1B, 0x47, 0x02], "vbroadcastf32x8", "0x40(%rdi), %zmm0", length: 7) }
    func testEVEXVbroadcasti32x8() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x5B, 0x47, 0x02], "vbroadcasti32x8", "0x40(%rdi), %zmm0", length: 7) }
    func testEVEXVbroadcastf64x4() { assertDecode([0x62, 0xF2, 0xFD, 0x48, 0x1B, 0x47, 0x02], "vbroadcastf64x4", "0x40(%rdi), %zmm0", length: 7) }
    func testEVEXVbroadcasti64x4() { assertDecode([0x62, 0xF2, 0xFD, 0x48, 0x5B, 0x47, 0x02], "vbroadcasti64x4", "0x40(%rdi), %zmm0", length: 7) }

    // --- mask-source broadcast (F3 prefix, k register source, register-only) ---
    func testEVEXVpbroadcastmb2q() { assertDecode([0x62, 0xF2, 0xFE, 0x48, 0x2A, 0xC1], "vpbroadcastmb2q", "%k1, %zmm0") }
    func testEVEXVpbroadcastmw2d() { assertDecode([0x62, 0xF2, 0x7E, 0x48, 0x3A, 0xC1], "vpbroadcastmw2d", "%k1, %zmm0") }

    // --- W-bit disambiguation: 0x19 and 0x59 are W-pairs (AVX-512DQ x2 forms at W0).
    // Both have xmm-register AND memory (Tuple2 = 8-byte) source forms. ---
    func testEVEXVbroadcastf32x2Xmm() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x19, 0xFB], "vbroadcastf32x2", "%xmm3, %zmm7") }
    func testEVEXVbroadcastf32x2Mem() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x19, 0x6F, 0x08], "vbroadcastf32x2", "0x40(%rdi), %zmm5", length: 7) }
    func testEVEXVbroadcasti32x2Xmm() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x59, 0xFB], "vbroadcasti32x2", "%xmm3, %zmm7") }
    func testEVEXVbroadcasti32x2Mem() { assertDecode([0x62, 0xF2, 0x7D, 0x48, 0x59, 0x76, 0x08], "vbroadcasti32x2", "0x40(%rsi), %zmm6", length: 7) }

    // --- diversity: masks / zeroing / higher regs ---
    func testEVEXVpbroadcastdMasked() { assertDecode([0x62, 0xF2, 0x7D, 0x4B, 0x58, 0xCA], "vpbroadcastd", "%xmm2, %zmm1 {%k3}") }
    func testEVEXVpbroadcastqZeroing() { assertDecode([0x62, 0xF2, 0xFD, 0xCA, 0x59, 0xC8], "vpbroadcastq", "%xmm0, %zmm1 {%k2} {z}") }
    func testEVEXVbroadcastf32x4Masked() { assertDecode([0x62, 0xF2, 0x7D, 0x49, 0x1A, 0x47, 0x04], "vbroadcastf32x4", "0x40(%rdi), %zmm0 {%k1}", length: 7) }
}
