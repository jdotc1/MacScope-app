import Foundation
import XCTest
@testable import MacScope

final class X86AssemblerTests: XCTestCase {
    private let assembler = X86_64Assembler()

    // MARK: - Helpers

    private func assembleBytes(_ text: String, at address: UInt64 = 0, file: StaticString = #filePath, line: UInt = #line) -> [UInt8]? {
        switch assembler.assemble(text, at: address) {
        case .success(let bytes):
            return bytes
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
            return nil
        }
    }

    private func assertEncodes(_ text: String, _ expected: [UInt8], at address: UInt64 = 0, file: StaticString = #filePath, line: UInt = #line) {
        guard let bytes = assembleBytes(text, at: address, file: file, line: line) else { return }
        XCTAssertEqual(bytes, expected, "encoding mismatch for '\(text)'", file: file, line: line)
    }

    private func assertFails(_ text: String, _ expected: X86_64Assembler.Diagnostic, at address: UInt64 = 0, file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text, at: address) {
        case .success(let bytes):
            XCTFail("expected '\(text)' to fail but got bytes \(bytes)", file: file, line: line)
        case .failure(let diagnostic):
            XCTAssertEqual(diagnostic, expected, file: file, line: line)
        }
    }

    // MARK: - MOV

    func testMoveRegisterRegisterWidthsAndREX() {
        assertEncodes("movq %rbx, %rax", [0x48, 0x89, 0xd8])
        assertEncodes("movl %ebx, %eax", [0x89, 0xd8])
        assertEncodes("movw %bx, %ax", [0x66, 0x89, 0xd8])
        assertEncodes("movb %bl, %al", [0x88, 0xd8])
        assertEncodes("movq %r9, %r10", [0x4d, 0x89, 0xca])
        assertEncodes("movb %r9b, %al", [0x44, 0x88, 0xc8])
    }

    func testMoveImmediateForms() {
        assertEncodes("movl $0x1234, %eax", [0xb8, 0x34, 0x12, 0x00, 0x00])
        assertEncodes("movq $0x1234, %rax", [0x48, 0xc7, 0xc0, 0x34, 0x12, 0x00, 0x00])
        assertEncodes("movb $0x7f, %al", [0xb0, 0x7f])
        assertEncodes("movw $0xabcd, %cx", [0x66, 0xb9, 0xcd, 0xab])
        assertEncodes("movabsq $0x1122334455667788, %rax", [0x48, 0xb8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
        assertEncodes("movl $0x0, %r11d", [0x41, 0xbb, 0x00, 0x00, 0x00, 0x00])
    }

    func testMoveMemoryAndLEAForms() {
        assertEncodes("movq (%rdi), %rax", [0x48, 0x8b, 0x07])
        assertEncodes("movq 0x10(%rdi), %rax", [0x48, 0x8b, 0x47, 0x10])
        assertEncodes("movq -0x8(%rbp), %rax", [0x48, 0x8b, 0x45, 0xf8])
        assertEncodes("movq (%rdi,%rsi,8), %rax", [0x48, 0x8b, 0x04, 0xf7])
        assertEncodes("movq 0x20(%rdi,%rcx,4), %rdx", [0x48, 0x8b, 0x54, 0x8f, 0x20])
        assertEncodes("movq %rax, 0x10(%rdi)", [0x48, 0x89, 0x47, 0x10])
        assertEncodes("movl %eax, (%r8)", [0x41, 0x89, 0x00])
        assertEncodes("movq 0x1000(%rip), %rax", [0x48, 0x8b, 0x05, 0x00, 0x10, 0x00, 0x00])
        assertEncodes("leaq 0x10(%rdi), %rax", [0x48, 0x8d, 0x47, 0x10])
        assertEncodes("leaq (%rdi,%rsi,8), %rax", [0x48, 0x8d, 0x04, 0xf7])
        assertEncodes("leaq 0x1000(%rip), %rcx", [0x48, 0x8d, 0x0d, 0x00, 0x10, 0x00, 0x00])
    }

    // MARK: - ALU / Unary

    func testALURegisterImmediateAndMemoryForms() {
        assertEncodes("addq %rbx, %rax", [0x48, 0x01, 0xd8])
        assertEncodes("addl $0x10, %eax", [0x83, 0xc0, 0x10])
        assertEncodes("addq $0x8, %rsp", [0x48, 0x83, 0xc4, 0x08])
        assertEncodes("subq %rcx, %rdx", [0x48, 0x29, 0xca])
        assertEncodes("andl $0xff, %eax", [0x25, 0xff, 0x00, 0x00, 0x00])
        assertEncodes("xorq %rax, %rax", [0x48, 0x31, 0xc0])
        assertEncodes("cmpl $0x0, %eax", [0x83, 0xf8, 0x00])
        assertEncodes("cmpq $0x10, (%rdi)", [0x48, 0x83, 0x3f, 0x10])
        assertEncodes("testq %rax, %rax", [0x48, 0x85, 0xc0])
        assertEncodes("addq (%rdi), %rax", [0x48, 0x03, 0x07])
        assertEncodes("subq %rax, (%rdi)", [0x48, 0x29, 0x07])
    }

    func testUnaryForms() {
        assertEncodes("incq %rax", [0x48, 0xff, 0xc0])
        assertEncodes("decq %rcx", [0x48, 0xff, 0xc9])
        assertEncodes("negq %rax", [0x48, 0xf7, 0xd8])
        assertEncodes("notq %rbx", [0x48, 0xf7, 0xd3])
        assertEncodes("incl %eax", [0xff, 0xc0])
    }

    // MARK: - Stack / Control / Shifts

    func testStackAndIndirectControlFlow() {
        assertEncodes("pushq %rax", [0x50])
        assertEncodes("pushq %r12", [0x41, 0x54])
        assertEncodes("popq %rbx", [0x5b])
        assertEncodes("popq %r13", [0x41, 0x5d])
        assertEncodes("pushq $0x10", [0x6a, 0x10])
        assertEncodes("ret", [0xc3])
        assertEncodes("retq", [0xc3])
        assertEncodes("leave", [0xc9])
        assertEncodes("nop", [0x90])
        assertEncodes("call *%rax", [0xff, 0xd0])
        assertEncodes("call *(%rdi)", [0xff, 0x17])
        assertEncodes("jmp *%rax", [0xff, 0xe0])
        assertEncodes("jmp *(%rdi,%rsi,8)", [0xff, 0x24, 0xf7])
    }

    func testShiftForms() {
        assertEncodes("shlq $0x4, %rax", [0x48, 0xc1, 0xe0, 0x04])
        assertEncodes("shrq $0x1, %rbx", [0x48, 0xd1, 0xeb])
        assertEncodes("sarq %cl, %rdx", [0x48, 0xd3, 0xfa])
        assertEncodes("shlq %cl, %rax", [0x48, 0xd3, 0xe0])
    }

    // MARK: - Diagnostics

    func testFailureDiagnostics() {
        assertFails("", .empty)
        assertFails("frobq %rax", .unknownMnemonic("frobq"))
        assertFails("movq %rax", .wrongOperandCount(mnemonic: "movq", expected: "source, destination"))
        assertFails("movq %eax, %rax", .badRegister("%eax does not match movq's q-width form"))
        assertFails("movq $0x1122334455667788, %rax", .immediateOutOfRange("movq immediate requires sign-extended imm32; use movabsq for imm64"))
        assertFails("jmp %rax", .badOperand("jmp direct targets require a bare rel32 displacement; indirect targets require '*'"))
        assertFails("movq (%rax,%rsp,2), %rdx", .notEncodable("%rsp cannot be used as an index register"))
    }
}
