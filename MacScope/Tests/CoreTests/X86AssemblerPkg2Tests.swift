import Foundation
import XCTest
@testable import MacScope

final class X86AssemblerPkg2Tests: XCTestCase {
    private let assembler = X86_64Assembler()

    private func assertEncodes(_ text: String, _ expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTAssertEqual(bytes, expected, "encoding mismatch for '\(text)'", file: file, line: line)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
        }
    }

    private func assertFails(_ text: String, _ expected: X86_64Assembler.Diagnostic, file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTFail("expected '\(text)' to fail but got bytes \(bytes)", file: file, line: line)
        case .failure(let diagnostic):
            XCTAssertEqual(diagnostic, expected, file: file, line: line)
        }
    }

    func testUnsuffixedRegisterWidthInferenceExactBytes() {
        assertEncodes("mov %rbx, %rax", [0x48, 0x89, 0xd8])
        assertEncodes("mov %ebx, %eax", [0x89, 0xd8])
        assertEncodes("mov %bx, %ax", [0x66, 0x89, 0xd8])
        assertEncodes("mov %bl, %al", [0x88, 0xd8])
        assertEncodes("mov %r9, %r10", [0x4d, 0x89, 0xca])

        assertEncodes("add %rbx, %rax", [0x48, 0x01, 0xd8])
        assertEncodes("add %r14, %r9", [0x4d, 0x01, 0xf1])
        assertEncodes("sub %rcx, %rdx", [0x48, 0x29, 0xca])
        assertEncodes("and %rbx, %rax", [0x48, 0x21, 0xd8])
        assertEncodes("or %rbx, %rax", [0x48, 0x09, 0xd8])
        assertEncodes("xor %eax, %eax", [0x31, 0xc0])
        assertEncodes("cmp %rbx, %rax", [0x48, 0x39, 0xd8])
        assertEncodes("test %rax, %rax", [0x48, 0x85, 0xc0])
        assertEncodes("test %r15, %r15", [0x4d, 0x85, 0xff])
    }

    func testUnsuffixedImmediateUnaryAndStackExactBytes() {
        assertEncodes("add $0x10, %rax", [0x48, 0x83, 0xc0, 0x10])
        assertEncodes("add $0x10, %al", [0x04, 0x10])
        assertEncodes("sub $0x8, %rsp", [0x48, 0x83, 0xec, 0x08])
        assertEncodes("cmp $0x0, %eax", [0x83, 0xf8, 0x00])
        assertEncodes("test $0x10, %al", [0xa8, 0x10])
        assertEncodes("and $0xff, %eax", [0x25, 0xff, 0x00, 0x00, 0x00])
        assertEncodes("mov $0x1234, %eax", [0xb8, 0x34, 0x12, 0x00, 0x00])
        assertEncodes("mov $0x1234, %rax", [0x48, 0xc7, 0xc0, 0x34, 0x12, 0x00, 0x00])

        assertEncodes("inc %rax", [0x48, 0xff, 0xc0])
        assertEncodes("dec %rcx", [0x48, 0xff, 0xc9])
        assertEncodes("neg %rax", [0x48, 0xf7, 0xd8])
        assertEncodes("not %rbx", [0x48, 0xf7, 0xd3])
        assertEncodes("push %rax", [0x50])
        assertEncodes("push %r12", [0x41, 0x54])
        assertEncodes("push $0x10", [0x6a, 0x10])
        assertEncodes("pop %rbx", [0x5b])
        assertEncodes("pop %r13", [0x41, 0x5d])
    }

    func testDirectRel32BranchesExactBytes() {
        assertEncodes("jmp 0x40", [0xe9, 0x40, 0x00, 0x00, 0x00])
        assertEncodes("jmp 0x0", [0xe9, 0x00, 0x00, 0x00, 0x00])
        assertEncodes("jmp 0x7fffffff", [0xe9, 0xff, 0xff, 0xff, 0x7f])
        assertEncodes("jmp 0x80000000", [0xe9, 0x00, 0x00, 0x00, 0x80])
        assertEncodes("jmp 0xffffffff", [0xe9, 0xff, 0xff, 0xff, 0xff])
        assertEncodes("jmp -0x1", [0xe9, 0xff, 0xff, 0xff, 0xff])
        assertEncodes("call 0x100", [0xe8, 0x00, 0x01, 0x00, 0x00])
        assertEncodes("call 0xffffffff", [0xe8, 0xff, 0xff, 0xff, 0xff])
        assertEncodes("call -0x80000000", [0xe8, 0x00, 0x00, 0x00, 0x80])

        let conditions: [(String, UInt8)] = [
            ("jo", 0x80), ("jno", 0x81), ("jb", 0x82), ("jae", 0x83),
            ("je", 0x84), ("jne", 0x85), ("jbe", 0x86), ("ja", 0x87),
            ("js", 0x88), ("jns", 0x89), ("jp", 0x8a), ("jnp", 0x8b),
            ("jl", 0x8c), ("jge", 0x8d), ("jle", 0x8e), ("jg", 0x8f),
        ]
        for (mnemonic, opcode) in conditions {
            assertEncodes("\(mnemonic) 0x40", [0x0f, opcode, 0x40, 0x00, 0x00, 0x00])
        }
    }

    func testDirectRel32BranchAliases() {
        let aliases: [(String, UInt8)] = [
            ("jc", 0x82), ("jnae", 0x82),
            ("jnb", 0x83), ("jnc", 0x83),
            ("jz", 0x84), ("jnz", 0x85),
            ("jna", 0x86), ("jnbe", 0x87),
            ("jpe", 0x8a), ("jpo", 0x8b),
            ("jnge", 0x8c), ("jnl", 0x8d),
            ("jng", 0x8e), ("jnle", 0x8f),
        ]
        for (mnemonic, opcode) in aliases {
            assertEncodes("\(mnemonic) 0x80", [0x0f, opcode, 0x80, 0x00, 0x00, 0x00])
        }
    }

    func testAmbiguousUnsuffixedFormsRequireSuffix() {
        assertFails("mov $0x1, (%rdi)", .ambiguousWidth(mnemonic: "mov"))
        assertFails("add $0x1, (%rdi)", .ambiguousWidth(mnemonic: "add"))
        assertFails("inc (%rdi)", .ambiguousWidth(mnemonic: "inc"))
        assertFails("test $0x1, (%rdi)", .ambiguousWidth(mnemonic: "test"))
    }
}
