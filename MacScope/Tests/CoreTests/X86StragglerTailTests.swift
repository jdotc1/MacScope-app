import Foundation
import XCTest
@testable import MacScope

/// Ground truth is `handoff/package/groundtruth.txt` (`otool -arch x86_64 -tvj`),
/// normalized to the decoder's house style: AT&T operands with redundant GP size
/// suffixes dropped.
final class X86StragglerTailTests: XCTestCase {
    private let decoder = X86_64Decoder()

    private func one(_ bytes: [UInt8], at address: UInt64 = 0x1000) -> DecodedInstruction {
        decoder.decode(Data(bytes), baseAddress: address, maxInstructionCount: 1)[0]
    }

    private func assertDecode(_ bytes: [UInt8], _ expected: String, length: Int? = nil,
                              file: StaticString = #filePath, line: UInt = #line) {
        let r = one(bytes)
        let actual = r.operands.isEmpty ? r.mnemonic : r.mnemonic + " " + r.operands
        XCTAssertEqual(actual, expected, "instruction text", file: file, line: line)
        XCTAssertEqual(r.bytes.count, length ?? bytes.count, "length", file: file, line: line)
    }

    func testXaddForms() {
        assertDecode([0x4C, 0x0F, 0xC1, 0x33], "xadd %r14, (%rbx)", length: 4)
        assertDecode([0x44, 0x0F, 0xC1, 0x33], "xadd %r14d, (%rbx)", length: 4)
        assertDecode([0x44, 0x0F, 0xC0, 0x33], "xadd %r14b, (%rbx)", length: 4)
        assertDecode([0x0F, 0xC1, 0xCA], "xadd %ecx, %edx", length: 3)
    }

    func testSSEConvertAndReciprocalForms() {
        assertDecode([0x0F, 0x5B, 0xC0], "cvtdq2ps %xmm0, %xmm0", length: 3)
        assertDecode([0x66, 0x0F, 0x5B, 0xC2], "cvtps2dq %xmm2, %xmm0", length: 4)
        assertDecode([0xF3, 0x0F, 0x5B, 0xC9], "cvttps2dq %xmm1, %xmm1", length: 4)
        assertDecode([0x0F, 0x53, 0xC8], "rcpps %xmm0, %xmm1", length: 3)
        assertDecode([0xF3, 0x0F, 0x53, 0xD1], "rcpss %xmm1, %xmm2", length: 4)
    }

    func testPinsrwAndPextrwSSEAndMMXForms() {
        assertDecode([0x66, 0x0F, 0xC4, 0xC7, 0x01], "pinsrw $0x1, %edi, %xmm0", length: 5)
        assertDecode([0x66, 0x0F, 0xC4, 0x18, 0x02], "pinsrw $0x2, (%rax), %xmm3", length: 5)
        assertDecode([0x66, 0x0F, 0xC5, 0xC0, 0x00], "pextrw $0x0, %xmm0, %eax", length: 5)
        assertDecode([0x66, 0x0F, 0xC5, 0xD7, 0x03], "pextrw $0x3, %xmm7, %edx", length: 5)

        assertDecode([0x0F, 0xC4, 0xC7, 0x01], "pinsrw $0x1, %edi, %mm0", length: 4)
        assertDecode([0x0F, 0xC4, 0x18, 0x02], "pinsrw $0x2, (%rax), %mm3", length: 4)
        assertDecode([0x0F, 0xC5, 0xC0, 0x00], "pextrw $0x0, %mm0, %eax", length: 4)
        assertDecode([0x0F, 0xC5, 0xD7, 0x03], "pextrw $0x3, %mm7, %edx", length: 4)
    }

    func testSegmentRegisterMovForms() {
        assertDecode([0x8C, 0xD0], "mov %ss, %eax", length: 2)
        assertDecode([0x8E, 0x55, 0x48], "mov 0x48(%rbp), %ss", length: 3)
        assertDecode([0x8E, 0xE9], "mov %ecx, %gs", length: 2)
        assertDecode([0x48, 0x8C, 0xEF], "mov %gs, %rdi", length: 3)
    }

    func testCmpxchgUdFenceAndPopForms() {
        assertDecode([0x0F, 0xC7, 0x0E], "cmpxchg8b (%rsi)", length: 3)
        assertDecode([0x49, 0x0F, 0xC7, 0x4E, 0x50], "cmpxchg16b 0x50(%r14)", length: 5)
        assertDecode([0x67, 0x0F, 0xB9, 0x40, 0x19], "ud1 0x19(%eax), %eax", length: 5)
        assertDecode([0x0F, 0xAE, 0xF0], "mfence", length: 3)
        assertDecode([0x0F, 0xAE, 0xF8], "sfence", length: 3)
        assertDecode([0x0F, 0xAE, 0xE8], "lfence", length: 3)
        assertDecode([0x8F, 0x00], "pop (%rax)", length: 2)
        // pop r/m honors the 0x66 operand-size prefix (16-bit form).
        assertDecode([0x66, 0x8F, 0xC0], "pop %ax", length: 3)
        assertDecode([0x66, 0x41, 0x8F, 0xC0], "pop %r8w", length: 4)
    }

    func testAddressSize32EIPRelativeVsAbsolute() {
        // 0x67 with mod=00/rm=101 and NO SIB is EIP-relative in long mode, not absolute.
        assertDecode([0x67, 0x8B, 0x05, 0x78, 0x56, 0x34, 0x12], "mov 0x12345678(%eip), %eax", length: 7)
        assertDecode([0x67, 0x8B, 0x1D, 0x10, 0x00, 0x00, 0x00], "mov 0x10(%eip), %ebx", length: 7)
        assertDecode([0x67, 0x48, 0x8B, 0x05, 0x10, 0x00, 0x00, 0x00], "mov 0x10(%eip), %rax", length: 8)
        // SIB no-base (base=101, mod=00) IS a true absolute [disp32] — bare, no %eip.
        assertDecode([0x67, 0x8B, 0x04, 0x25, 0x78, 0x56, 0x34, 0x12], "mov 0x12345678, %eax", length: 8)
    }

    func testImplicitShiftByOneDropsCountOnlyForD0D1() {
        assertDecode([0xD1, 0xE2], "shl %edx", length: 2)
        assertDecode([0x48, 0xD1, 0xEB], "shr %rbx", length: 3)
        assertDecode([0xD1, 0x38], "sar (%rax)", length: 2)

        assertDecode([0xD3, 0xE2], "shl %cl, %edx", length: 2)
        assertDecode([0xC1, 0xE2, 0x04], "shl $0x4, %edx", length: 3)
    }

    func testDoubleREXConsumesAllPrefixesAndSingleREXStillWorks() {
        assertDecode([0x40, 0x48, 0x85, 0xFF], "test %rdi, %rdi", length: 4)
        assertDecode([0x46, 0x4E, 0xDF, 0x55, 0x48], "fists 0x48(%rbp)", length: 5)
        assertDecode([0x48, 0x89, 0xC8], "mov %rcx, %rax", length: 3)
    }

    func testMMXPackedIntegerForms() {
        assertDecode([0x0F, 0xFD, 0xFF], "paddw %mm7, %mm7", length: 3)
        assertDecode([0x0F, 0xFE, 0xFF], "paddd %mm7, %mm7", length: 3)
        assertDecode([0x0F, 0xF9, 0xFF], "psubw %mm7, %mm7", length: 3)
        assertDecode([0x0F, 0x74, 0x01], "pcmpeqb (%rcx), %mm0", length: 3)
        assertDecode([0x0F, 0xF2, 0xFF], "pslld %mm7, %mm7", length: 3)
        assertDecode([0x0F, 0xF3, 0xFF], "psllq %mm7, %mm7", length: 3)
        assertDecode([0x0F, 0x71, 0xF1, 0x02], "psllw $0x2, %mm1", length: 4)
        assertDecode([0x0F, 0xEF, 0xDB], "pxor %mm3, %mm3", length: 3)
    }
}
