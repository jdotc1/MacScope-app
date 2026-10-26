import Foundation
import XCTest
@testable import MacScope

/// Full-sweep desync + correctness test over a REAL clang -O2 compiled function
/// that exercises BMI1/BMI2/SSE4.2/POPCNT (commit dd39b58). The byte stream and
/// the expected per-instruction (address, mnemonic, operands) were taken verbatim
/// from `clang -arch x86_64 -O2 -mbmi -mbmi2 -msse4.2 -mpopcnt` + `otool -tvVj`.
final class X86RealFunctionSweepTests: XCTestCase {
    private let decoder = X86_64Decoder()

    func testRealBMIFunctionSweep() {
        // _f from real.c, full __text bytes:
        let bytes: [UInt8] = [
            0x55,                               // pushq %rbp
            0x48,0x89,0xe5,                     // movq %rsp, %rbp
            0xc4,0xe2,0xc0,0xf2,0xc6,           // andnq %rsi, %rdi, %rax
            0x89,0xd1,                          // movl %edx, %ecx
            0xc4,0xe2,0xf0,0xf5,0xcf,           // bzhiq %rcx, %rdi, %rcx
            0xc4,0x62,0xc2,0xf5,0xc6,           // pextq %rsi, %rdi, %r8
            0x49,0x31,0xc0,                     // xorq %rax, %r8
            0x49,0x31,0xc8,                     // xorq %rcx, %r8
            0xc4,0xe2,0xc3,0xf5,0xc6,           // pdepq %rsi, %rdi, %rax
            0x4c,0x31,0xc0,                     // xorq %r8, %rax
            0xf3,0x48,0x0f,0xb8,0xcf,           // popcntq %rdi, %rcx
            0x48,0x01,0xc1,                     // addq %rax, %rcx
            0xb8,0x04,0x08,0x00,0x00,           // movl $0x804, %eax
            0xc4,0xe2,0xf8,0xf7,0xc7,           // bextrq %rax, %rdi, %rax
            0x48,0x31,0xc8,                     // xorq %rcx, %rax
            0xf2,0x40,0x0f,0x38,0xf0,0xd6,      // crc32b %sil, %edx
            0xf2,0x48,0x0f,0x38,0xf1,0xd7,      // crc32q %rdi, %rdx
            0x48,0x01,0xd0,                     // addq %rdx, %rax
            0x5d,                               // popq %rbp
            0xc3,                               // retq
        ]
        // (offset, mnemonic, operands) — operands only checked for the new families.
        let rows = decoder.decode(Data(bytes), baseAddress: 0, maxInstructionCount: 64)

        // 1) Desync guard: every byte consumed, ends exactly at ret.
        let total = rows.reduce(0) { $0 + $1.bytes.count }
        XCTAssertEqual(total, bytes.count, "sweep consumed wrong number of bytes (desync)")
        XCTAssertEqual(rows.last?.mnemonic, "ret")
        XCTAssertEqual(rows.last?.address, UInt64(bytes.count - 1))

        // 2) Spot-check the new-family instructions against otool ground truth.
        func find(_ addr: UInt64) -> DecodedInstruction? { rows.first { $0.address == addr } }
        XCTAssertEqual(find(0x04)?.mnemonic, "andnq")
        XCTAssertEqual(find(0x04)?.operands, "%rsi, %rdi, %rax")
        XCTAssertEqual(find(0x0b)?.mnemonic, "bzhiq")
        XCTAssertEqual(find(0x0b)?.operands, "%rcx, %rdi, %rcx")
        XCTAssertEqual(find(0x10)?.mnemonic, "pextq")
        XCTAssertEqual(find(0x10)?.operands, "%rsi, %rdi, %r8")
        XCTAssertEqual(find(0x1b)?.mnemonic, "pdepq")
        XCTAssertEqual(find(0x1b)?.operands, "%rsi, %rdi, %rax")
        XCTAssertEqual(find(0x23)?.mnemonic, "popcntq")
        XCTAssertEqual(find(0x23)?.operands, "%rdi, %rcx")
        XCTAssertEqual(find(0x30)?.mnemonic, "bextrq")
        XCTAssertEqual(find(0x30)?.operands, "%rax, %rdi, %rax")
        XCTAssertEqual(find(0x38)?.mnemonic, "crc32b")
        XCTAssertEqual(find(0x38)?.operands, "%sil, %edx")
        XCTAssertEqual(find(0x3e)?.mnemonic, "crc32q")
        XCTAssertEqual(find(0x3e)?.operands, "%rdi, %rdx")
    }
}
