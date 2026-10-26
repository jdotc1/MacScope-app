import Foundation
import XCTest
@testable import MacScope

/// Independent adversarial oracle tests for the x86-64 breadth slice (commit
/// dd39b58: EVEX map2/3, BMI1/2, SSE4.2, AES, MOVBE/POPCNT/CRC32).
///
/// Every byte sequence and rendering here was derived FRESH from
/// `clang -arch x86_64` (assembling `.byte` directives) + `otool -tvVj` —
/// independent of the encodings the package author chose for the shipped tests.
/// Cases focus on the neighbors / high-register extensions / disp8-compression /
/// illegal-encoding handling that the shipped tests do not cover.
final class X86BreadthOracleTests: XCTestCase {
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

    // MARK: - High-register extension naming (otool ground truth)

    // c4 62 60 f2 c1  ->  andnl %ecx, %ebx, %r8d   (VEX.R extends dest -> r8d)
    func testBMIDestHighReg() {
        assertDecode([0xC4, 0x62, 0x60, 0xF2, 0xC1], "andnl", "%ecx, %ebx, %r8d", length: 5)
    }

    // c4 e2 31 f7 c3  ->  shlxl %r9d, %ebx, %eax   (VEX.vvvv encodes r9d)
    func testBMIvvvvHighReg() {
        assertDecode([0xC4, 0xE2, 0x31, 0xF7, 0xC3], "shlxl", "%r9d, %ebx, %eax", length: 5)
    }

    // c4 c2 e0 f2 00  ->  andnq (%r8), %rbx, %rax   (VEX.B extends rm base -> r8)
    func testBMIrmBaseHighReg() {
        assertDecode([0xC4, 0xC2, 0xE0, 0xF2, 0x00], "andnq", "(%r8), %rbx, %rax", length: 5)
    }

    // f2 49 0f 38 f1 c0  ->  crc32q %r8, %rax   (REX.B + REX.W)
    func testCRC32HighReg() {
        assertDecode([0xF2, 0x49, 0x0F, 0x38, 0xF1, 0xC0], "crc32q", "%r8, %rax", length: 6)
    }

    // MARK: - Scalar EVEX compressed disp8 (tuple = element size, NOT vector width)

    // 62 f1 f7 08 58 47 01  ->  vaddsd 0x8(%rdi), %xmm1, %xmm0   (scalar f64, scale 8)
    func testEVEXVaddsdScalarDisp8() {
        assertDecode([0x62, 0xF1, 0xF7, 0x08, 0x58, 0x47, 0x01],
                     "vaddsd", "0x8(%rdi), %xmm1, %xmm0", length: 7)
    }

    // 62 f1 76 08 58 47 01  ->  vaddss 0x4(%rdi), %xmm1, %xmm0   (scalar f32, scale 4)
    func testEVEXVaddssScalarDisp8() {
        assertDecode([0x62, 0xF1, 0x76, 0x08, 0x58, 0x47, 0x01],
                     "vaddss", "0x4(%rdi), %xmm1, %xmm0", length: 7)
    }

    // MARK: - vpternlogq / vpmullq (REX.W variants)

    // 62 f3 f5 48 25 c2 96  ->  vpternlogq $0x96, %zmm2, %zmm1, %zmm0
    func testEVEXVpternlogq() {
        assertDecode([0x62, 0xF3, 0xF5, 0x48, 0x25, 0xC2, 0x96],
                     "vpternlogq", "$0x96, %zmm2, %zmm1, %zmm0", length: 7)
    }

    // 62 f2 f5 48 40 c2  ->  vpmullq %zmm2, %zmm1, %zmm0
    func testEVEXVpmullq() {
        assertDecode([0x62, 0xF2, 0xF5, 0x48, 0x40, 0xC2],
                     "vpmullq", "%zmm2, %zmm1, %zmm0", length: 6)
    }

    // MARK: - crc32 word + memory forms

    // 66 f2 0f 38 f1 d3  ->  crc32w %bx, %edx
    func testCRC32WordReg() {
        assertDecode([0x66, 0xF2, 0x0F, 0x38, 0xF1, 0xD3], "crc32w", "%bx, %edx", length: 6)
    }

    // MARK: - Desync guards across the new families followed by ret (0xc3)

    func testDesyncBMIThenRet() {
        // c4 e2 60 f2 c1  (andnl, 5 bytes) then c3 (ret)
        let rows = sweep([0xC4, 0xE2, 0x60, 0xF2, 0xC1, 0xC3])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "andnl")
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 5)
    }

    func testDesyncCRC32ThenRet() {
        // f2 0f 38 f1 c3 (crc32l, 5 bytes) then c3 (ret)
        let rows = sweep([0xF2, 0x0F, 0x38, 0xF1, 0xC3, 0xC3])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "crc32l")
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 5)
    }

    func testDesyncRorxThenRet() {
        // c4 e3 7b f0 c3 05 (rorxl, 6 bytes) then c3 (ret)
        let rows = sweep([0xC4, 0xE3, 0x7B, 0xF0, 0xC3, 0x05, 0xC3])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "rorxl")
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 6)
    }

    func testDesyncAESThenRet() {
        // 66 0f 38 dc c1 (aesenc, 5 bytes) then c3
        let rows = sweep([0x66, 0x0F, 0x38, 0xDC, 0xC1, 0xC3])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "aesenc")
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 5)
    }

    // MARK: - EVEX displacement forms (disp32 unscaled; SIB+disp8 scaled; map3 mem scaled)

    // 62 f1 75 48 fe 87 00 01 00 00  ->  vpaddd 0x100(%rdi), %zmm1, %zmm0   (disp32, NOT scaled)
    func testEVEXVpadddDisp32Unscaled() {
        assertDecode([0x62, 0xF1, 0x75, 0x48, 0xFE, 0x87, 0x00, 0x01, 0x00, 0x00],
                     "vpaddd", "0x100(%rdi), %zmm1, %zmm0", length: 10)
    }

    // 62 f1 74 48 58 44 24 02  ->  vaddps 0x80(%rsp), %zmm1, %zmm0   (SIB + compressed disp8)
    func testEVEXVaddpsSIBDisp8Scaled() {
        assertDecode([0x62, 0xF1, 0x74, 0x48, 0x58, 0x44, 0x24, 0x02],
                     "vaddps", "0x80(%rsp), %zmm1, %zmm0", length: 8)
    }

    // 62 f3 75 48 25 47 01 96  ->  vpternlogd $0x96, 0x40(%rdi), %zmm1, %zmm0   (map3 mem disp8 scaled)
    func testEVEXVpternlogdMemDisp8Scaled() {
        assertDecode([0x62, 0xF3, 0x75, 0x48, 0x25, 0x47, 0x01, 0x96],
                     "vpternlogd", "$0x96, 0x40(%rdi), %zmm1, %zmm0", length: 8)
    }

    // f2 0f 38 f1 47 10  ->  crc32l 0x10(%rdi), %eax   (legacy disp8, NOT scaled)
    func testCRC32MemDisp8Unscaled() {
        assertDecode([0xF2, 0x0F, 0x38, 0xF1, 0x47, 0x10],
                     "crc32l", "0x10(%rdi), %eax", length: 6)
    }

    // MARK: - Illegal-encoding handling (length-correct placeholder, NOT a wrong mnemonic)

    // MOVBE with a register r/m (mod==11) is #UD on hardware. The decoder must NOT emit a confident
    // `movbel`; it emits a length-correct 4-byte placeholder so the linear sweep re-syncs cleanly.
    // (Ground truth: real `otool -tvVj` does not produce a single 4-byte unit — it segments
    // `0f 38 f0 c3` as `0f` bad-opcode / `38 f0` cmpb / `c3` retq = 1+2+1. The decoder's one-unit
    // placeholder is a deliberate design choice; what matters is both re-sync to `ret` at offset 4,
    // so the sweep does not adopt a fictional decode or drift.)
    func testMOVBERegisterOperandIsNotMisdecoded() {
        let r = one([0x0F, 0x38, 0xF0, 0xC3])
        XCTAssertNotEqual(r.mnemonic, "movbel",
                          "MOVBE with a register operand is illegal; must not render as movbe")
        XCTAssertEqual(r.bytes.count, 4, "placeholder must stay length-correct")
        // The 0xF1 (store) direction with a register r/m is likewise illegal.
        let r2 = one([0x0F, 0x38, 0xF1, 0xC3])
        XCTAssertNotEqual(r2.mnemonic, "movbel")
        XCTAssertEqual(r2.bytes.count, 4)
    }

    // Desync guard: illegal movbe-reg (4 bytes) followed by ret must stay synced.
    func testMOVBERegisterOperandDesyncGuard() {
        let rows = sweep([0x0F, 0x38, 0xF0, 0xC3, 0xC3])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 4)
    }
}
