import Foundation
import XCTest
@testable import MacScope

/// Ground-truth for every expected string below is `clang -arch x86_64` + `otool -tvVj`
/// (mnemonics/operands rendered in the decoder's AT&T house style; byte boundaries and
/// branch targets verified to match otool exactly). See X86_64Decoder.swift.
final class X86DisassemblyTests: XCTestCase {
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

    // MARK: - Seam

    func testX86DecoderConformsToDisassemblerSeam() {
        let seam: any Disassembler = X86_64Decoder()
        let rows = seam.decode(Data([0x55]), baseAddress: 0x4000, maxInstructionCount: 1)
        XCTAssertEqual(rows.first?.mnemonic, "push")
        XCTAssertEqual(rows.first?.operands, "%rbp")
        XCTAssertEqual(rows.first?.address, 0x4000)
    }

    // MARK: - Integer core

    func testPushPopIncludingREXExtendedRegisters() {
        assertDecode([0x55], "push", "%rbp")
        assertDecode([0x41, 0x54], "push", "%r12")
        assertDecode([0x5D], "pop", "%rbp")
        assertDecode([0x41, 0x5D], "pop", "%r13")
    }

    func testMovRegisterImmediateAndMemoryForms() {
        assertDecode([0x48, 0x89, 0xE5], "mov", "%rsp, %rbp")            // store: reg -> r/m
        assertDecode([0x89, 0xC1], "mov", "%eax, %ecx")
        assertDecode([0xB8, 0x01, 0x00, 0x00, 0x00], "mov", "$0x1, %eax")
        assertDecode([0x48, 0xB8, 0xBE, 0xBA, 0xFE, 0xCA, 0xEF, 0xBE, 0xAD, 0xDE],
                     "movabs", "$0xdeadbeefcafebabe, %rax")
        assertDecode([0x48, 0x8B, 0x45, 0x10], "mov", "0x10(%rbp), %rax") // load: disp8(base)
        assertDecode([0x48, 0x89, 0x45, 0xF8], "mov", "%rax, -0x8(%rbp)") // negative disp8
        assertDecode([0x8B, 0x7C, 0x24, 0x08], "mov", "0x8(%rsp), %edi")  // SIB base, no index
        assertDecode([0x48, 0x8B, 0x04, 0xF7], "mov", "(%rdi,%rsi,8), %rax") // SIB scale-8 index
    }

    // MARK: - otool/LLVM AT&T operand-spelling fidelity
    //
    // These pin the shared memory-operand formatter (decodeModRM) to the exact
    // `X86ATTInstPrinter::printMemReference` rendering rule so a reverse-engineer
    // diffing MacScope against otool sees identical operand text:
    //   • the displacement is printed only when it is NON-ZERO, or when there is
    //     neither a base nor an index register (a bare absolute address).
    //   • the SIB scale is printed only when it is not 1.

    /// A zero displacement is suppressed whenever a base or index register is present.
    /// The ABI FORCES mod=01 disp8=0x00 on %rbp/%r13 bases (mod=00 base=101 means
    /// RIP/disp32), and otool renders `(%rbp)` / `(%r13)` — never `0x0(%rbp)`.
    func testZeroDisplacementIsSuppressedWhenBaseOrIndexPresent() {
        assertDecode([0x49, 0x8B, 0x45, 0x00], "mov", "(%r13), %rax") // ABI-forced disp8=0, %r13
        assertDecode([0x48, 0x8B, 0x45, 0x00], "mov", "(%rbp), %rax") // ABI-forced disp8=0, %rbp
        assertDecode([0x48, 0x8B, 0x40, 0x00], "mov", "(%rax), %rax") // explicit disp8=0, general base
        // index register present, disp32 == 0 -> disp suppressed, scale kept, leading comma
        assertDecode([0x48, 0x8D, 0x0C, 0x8D, 0x00, 0x00, 0x00, 0x00], "lea", "(,%rcx,4), %rcx")
        // GUARD: nonzero displacements are unchanged.
        assertDecode([0x48, 0x8B, 0x45, 0x08], "mov", "0x8(%rbp), %rax")
        assertDecode([0x49, 0x8B, 0x45, 0x08], "mov", "0x8(%r13), %rax")
        // GUARD: a bare absolute [disp32] with NO base and NO index still shows the zero.
        assertDecode([0x48, 0x8B, 0x04, 0x25, 0x00, 0x00, 0x00, 0x00], "mov", "0x0, %rax")
    }

    /// A redundant SIB scale of 1 is omitted: `(%rbx,%rcx)`, not `(%rbx,%rcx,1)`.
    func testRedundantSibScaleOneIsOmitted() {
        assertDecode([0x48, 0x8D, 0x04, 0x0B], "lea", "(%rbx,%rcx), %rax")   // scale 1 dropped
        // GUARD: scales other than 1 are kept.
        assertDecode([0x48, 0x8D, 0x04, 0x4B], "lea", "(%rbx,%rcx,2), %rax") // scale 2
        assertDecode([0x48, 0x8D, 0x04, 0xCB], "lea", "(%rbx,%rcx,8), %rax") // scale 8
    }

    /// A zero %rip displacement is suppressed: `(%rip)`, not `0x0(%rip)`.
    /// The resolved-address comment must still be produced.
    func testZeroRipDisplacementIsSuppressed() {
        let z = one([0x48, 0x8B, 0x05, 0x00, 0x00, 0x00, 0x00], at: 0x1000)
        XCTAssertEqual(z.mnemonic, "mov")
        XCTAssertEqual(z.operands, "(%rip), %rax")
        XCTAssertEqual(z.comment, "0x1007") // next-instruction address + disp 0x0
        // GUARD: a nonzero %rip displacement is kept.
        let nz = one([0x48, 0x8B, 0x05, 0x10, 0x00, 0x00, 0x00], at: 0x1000)
        XCTAssertEqual(nz.operands, "0x10(%rip), %rax")
        XCTAssertEqual(nz.comment, "0x1017") // next-instruction (0x1007) + disp 0x10
    }

    func testLeaRipRelativeResolvesAbsoluteAddress() {
        let r = one([0x48, 0x8D, 0x05, 0x08, 0x00, 0x00, 0x00], at: 0x1000)
        XCTAssertEqual(r.mnemonic, "lea")
        XCTAssertEqual(r.operands, "0x8(%rip), %rax")
        XCTAssertEqual(r.comment, "0x100f") // next-instruction (0x1007) + disp 0x8
    }

    func testALUFormsAndImmediateGroups() {
        assertDecode([0x48, 0x01, 0xD8], "add", "%rbx, %rax")            // 0x01 r/m, r
        assertDecode([0x48, 0x83, 0xC4, 0x20], "add", "$0x20, %rsp")     // group1 imm8 sign-ext
        assertDecode([0x83, 0xFF, 0x00], "cmp", "$0x0, %edi")            // group1 reg-field = CMP
        assertDecode([0x31, 0xC0], "xor", "%eax, %eax")
        assertDecode([0x48, 0x85, 0xC0], "test", "%rax, %rax")
        assertDecode([0x48, 0xFF, 0xC8], "dec", "%rax")                  // group5 reg-field = DEC
        assertDecode([0xFF, 0xC0], "inc", "%eax")
        assertDecode([0x48, 0xC1, 0xE0, 0x04], "shl", "$0x4, %rax")      // group2 shift imm8
    }

    func testMovzxMovsxAndMovslq() {
        assertDecode([0x0F, 0xB6, 0x07], "movzbl", "(%rdi), %eax")
        assertDecode([0x48, 0x63, 0xC0], "movslq", "%eax, %rax")
    }

    func testRelativeBranchTargets() {
        let call = one([0xE8, 0x00, 0x00, 0x00, 0x00], at: 0x1000)
        XCTAssertEqual(call.mnemonic, "call")
        XCTAssertEqual(call.branchTarget, 0x1005) // 0x1000 + 5 + 0
        let je = one([0x74, 0x10], at: 0x1000)
        XCTAssertEqual(je.mnemonic, "je")
        XCTAssertEqual(je.branchTarget, 0x1012) // 0x1000 + 2 + 0x10
    }

    // MARK: - SSE / SSE2

    func testSSEDataMovementAndArithmetic() {
        assertDecode([0x0F, 0x28, 0xC1], "movaps", "%xmm1, %xmm0")
        assertDecode([0xF3, 0x0F, 0x10, 0x17], "movss", "(%rdi), %xmm2")
        assertDecode([0xF2, 0x0F, 0x58, 0xC1], "addsd", "%xmm1, %xmm0")
        assertDecode([0x66, 0x0F, 0xEF, 0xDB], "pxor", "%xmm3, %xmm3")
        assertDecode([0x66, 0x0F, 0x6F, 0x2E], "movdqa", "(%rsi), %xmm5")
        assertDecode([0x66, 0x0F, 0xD4, 0xE2], "paddq", "%xmm2, %xmm4")
    }

    func testSSEImmediateAndMixedAndThreeByteForms() {
        assertDecode([0x66, 0x0F, 0x70, 0xC8, 0x1B], "pshufd", "$0x1b, %xmm0, %xmm1") // imm8
        assertDecode([0xF2, 0x0F, 0x2A, 0xC7], "cvtsi2sd", "%edi, %xmm0")             // int -> xmm
        assertDecode([0x66, 0x0F, 0x6E, 0xC0], "movd", "%eax, %xmm0")                 // gpr -> xmm
        assertDecode([0x66, 0x0F, 0x38, 0x22, 0x0F], "pmovsxbq", "(%rdi), %xmm1")     // 0x0F38 escape
        assertDecode([0x66, 0x0F, 0x73, 0xDA, 0x04], "psrldq", "$0x4, %xmm2")         // shift-by-imm group
    }

    // MARK: - Robustness (variable-length re-sync)

    func testTrailingGroupOpcodeWithoutModRMDoesNotCrash() {
        // A group opcode (0xFF) at the very end of the buffer has no ModRM byte;
        // it must degrade to a single .byte rather than indexing out of bounds.
        let r = one([0xFF])
        XCTAssertEqual(r.mnemonic, ".byte")
        XCTAssertEqual(r.bytes.count, 1)
    }

    func testUnknownLeadingByteAdvancesOneByteForLinearResync() {
        // 0x06 is invalid in 64-bit mode: emit .byte and advance exactly one byte so
        // the linear sweep can re-synchronize on the following instruction.
        let rows = decoder.decode(Data([0x06, 0x90]), baseAddress: 0x1000, maxInstructionCount: 8)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, ".byte")
        XCTAssertEqual(rows[1].mnemonic, "nop")
        XCTAssertEqual(rows[1].address, 0x1001)
    }

    func testLinearSweepKeepsBoundariesAcrossMixedStream() {
        // push %rbp ; mov %rsp,%rbp ; sub $0x20,%rsp ; pxor %xmm0,%xmm0 ; leave ; ret
        let stream: [UInt8] = [0x55, 0x48, 0x89, 0xE5, 0x48, 0x83, 0xEC, 0x20,
                               0x66, 0x0F, 0xEF, 0xC0, 0xC9, 0xC3]
        let rows = decoder.decode(Data(stream), baseAddress: 0x2000, maxInstructionCount: 64)
        XCTAssertEqual(rows.map(\.mnemonic), ["push", "mov", "sub", "pxor", "leave", "ret"])
        XCTAssertEqual(rows.map(\.address), [0x2000, 0x2001, 0x2004, 0x2008, 0x200c, 0x200d])
    }

    // MARK: - Control-flow classification (the arch-neutral seam)

    func testControlFlowClassification() {
        XCTAssertEqual(one([0xE8, 0x00, 0x00, 0x00, 0x00]).flow, .call)        // call rel32
        XCTAssertEqual(one([0xE9, 0x00, 0x00, 0x00, 0x00]).flow, .jump)        // jmp rel32
        XCTAssertEqual(one([0xEB, 0x00]).flow, .jump)                          // jmp rel8
        XCTAssertEqual(one([0x74, 0x05]).flow, .conditionalJump)              // je
        XCTAssertEqual(one([0xE2, 0x05]).flow, .conditionalJump)              // loop
        XCTAssertEqual(one([0xC3]).flow, .return)                             // ret
        XCTAssertEqual(one([0xC2, 0x08, 0x00]).flow, .return)                 // ret imm16
        XCTAssertEqual(one([0xFF, 0xD0]).flow, .indirectCall)                // call *%rax
        XCTAssertEqual(one([0xFF, 0xE0]).flow, .indirectJump)                // jmp *%rax
        XCTAssertEqual(one([0x48, 0x89, 0xE5]).flow, .normal)                // mov
    }

    // MARK: - Regression: opcodes whose absence desynced the sweep (review w28vsivbq)

    func testImulImmediateThreeOperandForms() {
        assertDecode([0x48, 0x6B, 0xC7, 0x18], "imul", "$0x18, %rdi, %rax")              // imm8
        assertDecode([0x48, 0x69, 0xC3, 0x78, 0x56, 0x34, 0x12], "imul", "$0x12345678, %rbx, %rax") // imm32 (even under REX.W)
    }

    func testBitTestImmediateGroupAndMovnti() {
        assertDecode([0x0F, 0xBA, 0x20, 0x05], "bt", "$0x5, (%rax)")     // 0x0F 0xBA /4 ib
        assertDecode([0x0F, 0xC3, 0x08], "movnti", "%ecx, (%rax)")       // had been mis-decoded as a spurious `ret`
    }

    func testShldEnterRetImm() {
        assertDecode([0x0F, 0xA4, 0xD1, 0x04], "shld", "$0x4, %edx, %ecx")
        assertDecode([0xC8, 0x10, 0x00, 0x00], "enter", "$0x10, $0x0")
        assertDecode([0xC2, 0x08, 0x00], "ret", "$0x8")
    }

    func testSegmentOverrideRendersQualifier() {
        // The stack-canary load — present in nearly every protected function — must keep
        // its %fs: qualifier rather than reading as a bare absolute access.
        assertDecode([0x64, 0x48, 0x8B, 0x04, 0x25, 0x28, 0x00, 0x00, 0x00], "mov", "%fs:0x28, %rax")
        assertDecode([0x65, 0x8B, 0x03], "mov", "%gs:(%rbx), %eax")
    }

    func testImulImmediateDoesNotEatTheFollowingRet() {
        // The original desync: a missing 0x6B case advanced one byte and swallowed the
        // trailing mov AND ret. The whole stream must now decode as three instructions.
        let stream: [UInt8] = [0x48, 0x6B, 0xC7, 0x18, 0x48, 0x89, 0xC1, 0xC3]
        let rows = decoder.decode(Data(stream), baseAddress: 0x3000, maxInstructionCount: 64)
        XCTAssertEqual(rows.map(\.mnemonic), ["imul", "mov", "ret"])
        XCTAssertEqual(rows.last?.address, 0x3007) // ret survives at the right address
    }

    // MARK: - AVX / VEX

    func testAVXVaddpsThreeOperand() {
        assertDecode([0xC5, 0xF0, 0x58, 0xC2], "vaddps", "%xmm2, %xmm1, %xmm0")
    }

    func testAVX256BitMovaps() {
        assertDecode([0xC5, 0x84, 0x28, 0xC1], "vmovaps", "%ymm1, %ymm0")
    }

    func testAVXVpxor() {
        assertDecode([0xC5, 0xE1, 0xEF, 0xDB], "vpxor", "%xmm3, %xmm3, %xmm3")
    }

    func testAVXVshufpsImmediate() {
        assertDecode([0xC5, 0xF0, 0xC6, 0xC2, 0x1B], "vshufps", "$0x1b, %xmm2, %xmm1, %xmm0")
    }

    func testAVXVpshufdImmediate() {
        assertDecode([0xC5, 0xFD, 0x70, 0xC1, 0x1B], "vpshufd", "$0x1b, %ymm1, %ymm0")
    }

    func testAVXVCvtsi2sdThreeOperand() {
        assertDecode([0xC4, 0xE1, 0xF3, 0x2A, 0xC7], "vcvtsi2sd", "%rdi, %xmm1, %xmm0")
    }

    func testAVXVzeroupperAndVzeroall() {
        assertDecode([0xC5, 0xF8, 0x77], "vzeroupper", "")
        assertDecode([0xC5, 0xFC, 0x77], "vzeroall", "")
    }

    func testAVXDesyncRegression() {
        let stream: [UInt8] = [0xC5, 0xF0, 0x58, 0xC2, 0xC3]
        let rows = decoder.decode(Data(stream), baseAddress: 0x4000, maxInstructionCount: 64)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "vaddps")
        XCTAssertEqual(rows[0].operands, "%xmm2, %xmm1, %xmm0")
        XCTAssertEqual(rows[0].bytes.count, 4)
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x4004)
    }

    /// The 3-operand and asymmetric-width VEX forms whose vvvv (third operand) or operand width was
    /// previously mis-rendered. Ground truth: `clang -arch x86_64` + `otool -tvVj` (length was always
    /// correct — these lock the operand rendering).
    func testAVXThreeOperandAndWidthRendering() {
        assertDecode([0xC5, 0xEA, 0x10, 0xD9], "vmovss", "%xmm1, %xmm2, %xmm3")       // scalar reg-form merge
        assertDecode([0xC5, 0xEB, 0x51, 0xD9], "vsqrtsd", "%xmm1, %xmm2, %xmm3")
        assertDecode([0xC5, 0xEB, 0x5A, 0xD9], "vcvtsd2ss", "%xmm1, %xmm2, %xmm3")
        assertDecode([0xC5, 0xED, 0x71, 0xD1, 0x02], "vpsrlw", "$0x2, %ymm1, %ymm2")  // shift-by-imm: vvvv = dst
        assertDecode([0xC5, 0xE9, 0x72, 0xF1, 0x03], "vpslld", "$0x3, %xmm1, %xmm2")
        assertDecode([0xC5, 0xFC, 0x5A, 0xD1], "vcvtps2pd", "%xmm1, %ymm2")           // widen: src xmm, dst ymm
        assertDecode([0xC5, 0xFA, 0x5B, 0xD1], "vcvttps2dq", "%xmm1, %xmm2")          // was mis-slotted to F2
        assertDecode([0xC5, 0xFD, 0x5A, 0xD1], "vcvtpd2ps", "%ymm1, %xmm2")           // narrow: src ymm, dst xmm
    }

}

