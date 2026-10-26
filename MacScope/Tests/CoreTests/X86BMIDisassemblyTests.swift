import Foundation
import XCTest
@testable import MacScope

/// Tests for VEX-encoded BMI1/BMI2 plus the scalar 0F38/0F3A fills added with
/// the x86-64 breadth slice. Ground truth comes from `clang -arch x86_64` plus
/// `otool -tvVj`; every case asserts mnemonic, operands, and decoded length.
final class X86BMIDisassemblyTests: XCTestCase {
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
        decoder.decode(Data(bytes), baseAddress: 0x1000, maxInstructionCount: 8)
    }

    // MARK: - BMI2 variable shifts

    func testVEXMap2ShiftVariable32() {
        // c4 e2 71 f7 c3  ->  shlxl %ecx, %ebx, %eax
        assertDecode([0xC4, 0xE2, 0x71, 0xF7, 0xC3], "shlxl", "%ecx, %ebx, %eax", length: 5)
        // c4 e2 72 f7 c3  ->  sarxl %ecx, %ebx, %eax
        assertDecode([0xC4, 0xE2, 0x72, 0xF7, 0xC3], "sarxl", "%ecx, %ebx, %eax", length: 5)
        // c4 e2 73 f7 c3  ->  shrxl %ecx, %ebx, %eax
        assertDecode([0xC4, 0xE2, 0x73, 0xF7, 0xC3], "shrxl", "%ecx, %ebx, %eax", length: 5)
    }

    // MARK: - BMI1/BMI2 three-operand forms

    func testVEXMap2BMIThreeOperand32() {
        // c4 e2 60 f2 c1  ->  andnl %ecx, %ebx, %eax
        assertDecode([0xC4, 0xE2, 0x60, 0xF2, 0xC1], "andnl", "%ecx, %ebx, %eax", length: 5)
        // c4 e2 70 f5 c3  ->  bzhil %ecx, %ebx, %eax
        assertDecode([0xC4, 0xE2, 0x70, 0xF5, 0xC3], "bzhil", "%ecx, %ebx, %eax", length: 5)
        // c4 e2 62 f5 c1  ->  pextl %ecx, %ebx, %eax
        assertDecode([0xC4, 0xE2, 0x62, 0xF5, 0xC1], "pextl", "%ecx, %ebx, %eax", length: 5)
        // c4 e2 63 f5 c1  ->  pdepl %ecx, %ebx, %eax
        assertDecode([0xC4, 0xE2, 0x63, 0xF5, 0xC1], "pdepl", "%ecx, %ebx, %eax", length: 5)
        // c4 e2 63 f6 c1  ->  mulxl %ecx, %ebx, %eax
        assertDecode([0xC4, 0xE2, 0x63, 0xF6, 0xC1], "mulxl", "%ecx, %ebx, %eax", length: 5)
        // c4 e2 70 f7 c3  ->  bextrl %ecx, %ebx, %eax
        assertDecode([0xC4, 0xE2, 0x70, 0xF7, 0xC3], "bextrl", "%ecx, %ebx, %eax", length: 5)
    }

    func testVEXMap2BLSGroup32() {
        // c4 e2 78 f3 d9  ->  blsil %ecx, %eax
        assertDecode([0xC4, 0xE2, 0x78, 0xF3, 0xD9], "blsil", "%ecx, %eax", length: 5)
        // c4 e2 78 f3 d1  ->  blsmskl %ecx, %eax
        assertDecode([0xC4, 0xE2, 0x78, 0xF3, 0xD1], "blsmskl", "%ecx, %eax", length: 5)
        // c4 e2 78 f3 c9  ->  blsrl %ecx, %eax
        assertDecode([0xC4, 0xE2, 0x78, 0xF3, 0xC9], "blsrl", "%ecx, %eax", length: 5)
    }

    // MARK: - BMI2 immediate rotate

    func testVEXMap3RORX32() {
        // c4 e3 7b f0 c3 05  ->  rorxl $0x5, %ebx, %eax
        assertDecode([0xC4, 0xE3, 0x7B, 0xF0, 0xC3, 0x05], "rorxl", "$0x5, %ebx, %eax", length: 6)
    }

    func testVEXBMISuffix64() {
        // c4 e2 f1 f7 c3  ->  shlxq %rcx, %rbx, %rax
        assertDecode([0xC4, 0xE2, 0xF1, 0xF7, 0xC3], "shlxq", "%rcx, %rbx, %rax", length: 5)
        // c4 e2 e0 f2 c1  ->  andnq %rcx, %rbx, %rax
        assertDecode([0xC4, 0xE2, 0xE0, 0xF2, 0xC1], "andnq", "%rcx, %rbx, %rax", length: 5)
        // c4 e3 fb f0 c3 05  ->  rorxq $0x5, %rbx, %rax
        assertDecode([0xC4, 0xE3, 0xFB, 0xF0, 0xC3, 0x05], "rorxq", "$0x5, %rbx, %rax", length: 6)
    }

    func testVEXBMIMemoryOperands() {
        // c4 e2 60 f2 07  ->  andnl (%rdi), %ebx, %eax
        assertDecode([0xC4, 0xE2, 0x60, 0xF2, 0x07], "andnl", "(%rdi), %ebx, %eax", length: 5)
        // c4 e2 60 f7 07  ->  bextrl %ebx, (%rdi), %eax
        assertDecode([0xC4, 0xE2, 0x60, 0xF7, 0x07], "bextrl", "%ebx, (%rdi), %eax", length: 5)
        // c4 e2 61 f7 07  ->  shlxl %ebx, (%rdi), %eax
        assertDecode([0xC4, 0xE2, 0x61, 0xF7, 0x07], "shlxl", "%ebx, (%rdi), %eax", length: 5)
        // c4 e3 7b f0 07 05  ->  rorxl $0x5, (%rdi), %eax
        assertDecode([0xC4, 0xE3, 0x7B, 0xF0, 0x07, 0x05], "rorxl", "$0x5, (%rdi), %eax", length: 6)
        // c4 e2 63 f6 07  ->  mulxl (%rdi), %ebx, %eax
        assertDecode([0xC4, 0xE2, 0x63, 0xF6, 0x07], "mulxl", "(%rdi), %ebx, %eax", length: 5)
    }

    func testVEXBMIUnknownMap2LengthCorrect() {
        // c4 e2 60 99 c1  ->  unmapped VEX map-2 opcode with ModRM
        let rows = sweep([0xC4, 0xE2, 0x60, 0x99, 0xC1, 0xC3])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "(vex38)")
        XCTAssertEqual(rows[0].bytes.count, 5)
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 5)
    }

    // MARK: - SSE4.2, AES, MOVBE, POPCNT, PCLMULQDQ

    func testCRC32MOVBEAndPOPCNT() {
        // f2 0f 38 f0 c3  ->  crc32b %bl, %eax
        assertDecode([0xF2, 0x0F, 0x38, 0xF0, 0xC3], "crc32b", "%bl, %eax", length: 5)
        // f2 0f 38 f1 c3  ->  crc32l %ebx, %eax
        assertDecode([0xF2, 0x0F, 0x38, 0xF1, 0xC3], "crc32l", "%ebx, %eax", length: 5)
        // f2 48 0f 38 f0 c3  ->  crc32b %bl, %rax
        assertDecode([0xF2, 0x48, 0x0F, 0x38, 0xF0, 0xC3], "crc32b", "%bl, %rax", length: 6)
        // f2 48 0f 38 f1 c3  ->  crc32q %rbx, %rax
        assertDecode([0xF2, 0x48, 0x0F, 0x38, 0xF1, 0xC3], "crc32q", "%rbx, %rax", length: 6)
        // 66 f2 0f 38 f1 c3  ->  crc32w %bx, %eax
        assertDecode([0x66, 0xF2, 0x0F, 0x38, 0xF1, 0xC3], "crc32w", "%bx, %eax", length: 6)
        // 0f 38 f0 07  ->  movbel (%rdi), %eax
        assertDecode([0x0F, 0x38, 0xF0, 0x07], "movbel", "(%rdi), %eax", length: 4)
        // 0f 38 f1 07  ->  movbel %eax, (%rdi)
        assertDecode([0x0F, 0x38, 0xF1, 0x07], "movbel", "%eax, (%rdi)", length: 4)
        // 66 0f 38 f0 07  ->  movbew (%rdi), %ax
        assertDecode([0x66, 0x0F, 0x38, 0xF0, 0x07], "movbew", "(%rdi), %ax", length: 5)
        // f3 0f b8 c3  ->  popcntl %ebx, %eax
        assertDecode([0xF3, 0x0F, 0xB8, 0xC3], "popcntl", "%ebx, %eax", length: 4)
        // 66 f3 0f b8 c3  ->  popcntw %bx, %ax
        assertDecode([0x66, 0xF3, 0x0F, 0xB8, 0xC3], "popcntw", "%bx, %ax", length: 5)
    }

    func testAESAndPCLMULQDQ() {
        // 66 0f 38 dc c1  ->  aesenc %xmm1, %xmm0
        assertDecode([0x66, 0x0F, 0x38, 0xDC, 0xC1], "aesenc", "%xmm1, %xmm0", length: 5)
        // 66 0f 38 dd c1  ->  aesenclast %xmm1, %xmm0
        assertDecode([0x66, 0x0F, 0x38, 0xDD, 0xC1], "aesenclast", "%xmm1, %xmm0", length: 5)
        // 66 0f 38 de c1  ->  aesdec %xmm1, %xmm0
        assertDecode([0x66, 0x0F, 0x38, 0xDE, 0xC1], "aesdec", "%xmm1, %xmm0", length: 5)
        // 66 0f 38 df c1  ->  aesdeclast %xmm1, %xmm0
        assertDecode([0x66, 0x0F, 0x38, 0xDF, 0xC1], "aesdeclast", "%xmm1, %xmm0", length: 5)
        // 66 0f 38 db c1  ->  aesimc %xmm1, %xmm0
        assertDecode([0x66, 0x0F, 0x38, 0xDB, 0xC1], "aesimc", "%xmm1, %xmm0", length: 5)
        // 66 0f 3a df c1 01  ->  aeskeygenassist $0x1, %xmm1, %xmm0
        assertDecode([0x66, 0x0F, 0x3A, 0xDF, 0xC1, 0x01], "aeskeygenassist", "$0x1, %xmm1, %xmm0", length: 6)
        // 66 0f 3a 44 c1 10  ->  pclmulqdq $0x10, %xmm1, %xmm0
        assertDecode([0x66, 0x0F, 0x3A, 0x44, 0xC1, 0x10], "pclmulqdq", "$0x10, %xmm1, %xmm0", length: 6)
    }
}
