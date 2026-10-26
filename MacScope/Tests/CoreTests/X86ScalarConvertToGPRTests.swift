import Foundation
import XCTest
@testable import MacScope

final class X86ScalarConvertToGPRTests: XCTestCase {
    private let decoder = X86_64Decoder()

    private func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    private func one(_ hex: String, at address: UInt64 = 0x1000) -> DecodedInstruction {
        decoder.decode(Data(bytes(hex)), baseAddress: address, maxInstructionCount: 1)[0]
    }

    private func assertInstruction(_ hex: String, _ expected: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let row = one(hex)
        let text = row.operands.isEmpty ? row.mnemonic : row.mnemonic + " " + row.operands
        XCTAssertEqual(text, expected, file: file, line: line)
        XCTAssertEqual(row.bytes.count, bytes(hex).count, file: file, line: line)
    }

    private func assertInstructions(_ cases: [(String, String)],
                                    file: StaticString = #filePath, line: UInt = #line) {
        for (hex, expected) in cases {
            assertInstruction(hex, expected, file: file, line: line)
        }
    }

    func testVEXSignedScalarConvertToGPRMatrix() {
        assertInstructions([
            ("c5fa2dc1", "vcvtss2si %xmm1, %eax"),
            ("c4e1fa2dc1", "vcvtss2si %xmm1, %rax"),
            ("c5fb2dc1", "vcvtsd2si %xmm1, %eax"),
            ("c4e1fb2dc1", "vcvtsd2si %xmm1, %rax"),
            ("c5fa2d07", "vcvtss2si (%rdi), %eax"),
            ("c4e1fa2d07", "vcvtss2si (%rdi), %rax"),
            ("c5fb2d07", "vcvtsd2si (%rdi), %eax"),
            ("c4e1fb2d07", "vcvtsd2si (%rdi), %rax"),
            ("c5fa2cc1", "vcvttss2si %xmm1, %eax"),
            ("c4e1fa2cc1", "vcvttss2si %xmm1, %rax"),
            ("c5fb2cc1", "vcvttsd2si %xmm1, %eax"),
            ("c4e1fb2cc1", "vcvttsd2si %xmm1, %rax"),
            ("c5fa2c07", "vcvttss2si (%rdi), %eax"),
            ("c4e1fa2c07", "vcvttss2si (%rdi), %rax"),
            ("c5fb2c07", "vcvttsd2si (%rdi), %eax"),
            ("c4e1fb2c07", "vcvttsd2si (%rdi), %rax"),
            ("c57a2dc1", "vcvtss2si %xmm1, %r8d"),
            ("c461fb2df9", "vcvtsd2si %xmm1, %r15"),
            ("c57a2cd1", "vcvttss2si %xmm1, %r10d"),
        ])
    }

    func testEVEXSignedScalarConvertToGPRMatrixAndDecorations() {
        assertInstructions([
            ("62f17e082dc1", "vcvtss2si %xmm1, %eax"),
            ("62f1fe082dc1", "vcvtss2si %xmm1, %rax"),
            ("62f17f082dc1", "vcvtsd2si %xmm1, %eax"),
            ("62f1ff082dc1", "vcvtsd2si %xmm1, %rax"),
            ("62f17e082d07", "vcvtss2si (%rdi), %eax"),
            ("62f1fe082d07", "vcvtss2si (%rdi), %rax"),
            ("62f17f082d07", "vcvtsd2si (%rdi), %eax"),
            ("62f1ff082d07", "vcvtsd2si (%rdi), %rax"),
            ("62f17e082cc1", "vcvttss2si %xmm1, %eax"),
            ("62f1fe082cc1", "vcvttss2si %xmm1, %rax"),
            ("62f17f082cc1", "vcvttsd2si %xmm1, %eax"),
            ("62f1ff082cc1", "vcvttsd2si %xmm1, %rax"),
            ("62f17e082c07", "vcvttss2si (%rdi), %eax"),
            ("62f1fe082c07", "vcvttss2si (%rdi), %rax"),
            ("62f17f082c07", "vcvttsd2si (%rdi), %eax"),
            ("62f1ff082c07", "vcvttsd2si (%rdi), %rax"),
            ("62f17e582dc1", "vcvtss2si {ru-sae}, %xmm1, %eax"),
            ("62f1ff782dc1", "vcvtsd2si {rz-sae}, %xmm1, %rax"),
            ("62f17e182cc1", "vcvttss2si {sae}, %xmm1, %eax"),
            ("62f1ff182cc1", "vcvttsd2si {sae}, %xmm1, %rax"),
            ("62f17e082d4710", "vcvtss2si 0x40(%rdi), %eax"),
            ("62f1ff082d4710", "vcvtsd2si 0x80(%rdi), %rax"),
            ("62717e082dc1", "vcvtss2si %xmm1, %r8d"),
            ("6271ff082df9", "vcvtsd2si %xmm1, %r15"),
            ("62917e082dc7", "vcvtss2si %xmm31, %eax"),
            ("6211ff082cf6", "vcvttsd2si %xmm30, %r14"),
        ])
    }

    func testEVEXUnsignedScalarConvertToGPRMatrixAndDecorations() {
        assertInstructions([
            ("62f17e0879c1", "vcvtss2usi %xmm1, %eax"),
            ("62f1fe0879c1", "vcvtss2usi %xmm1, %rax"),
            ("62f17f0879c1", "vcvtsd2usi %xmm1, %eax"),
            ("62f1ff0879c1", "vcvtsd2usi %xmm1, %rax"),
            ("62f17e087907", "vcvtss2usi (%rdi), %eax"),
            ("62f1fe087907", "vcvtss2usi (%rdi), %rax"),
            ("62f17f087907", "vcvtsd2usi (%rdi), %eax"),
            ("62f1ff087907", "vcvtsd2usi (%rdi), %rax"),
            ("62f17e0878c1", "vcvttss2usi %xmm1, %eax"),
            ("62f1fe0878c1", "vcvttss2usi %xmm1, %rax"),
            ("62f17f0878c1", "vcvttsd2usi %xmm1, %eax"),
            ("62f1ff0878c1", "vcvttsd2usi %xmm1, %rax"),
            ("62f17e087807", "vcvttss2usi (%rdi), %eax"),
            ("62f1fe087807", "vcvttss2usi (%rdi), %rax"),
            ("62f17f087807", "vcvttsd2usi (%rdi), %eax"),
            ("62f1ff087807", "vcvttsd2usi (%rdi), %rax"),
            ("62f1fe5879c1", "vcvtss2usi {ru-sae}, %xmm1, %rax"),
            ("62f17f1879c1", "vcvtsd2usi {rn-sae}, %xmm1, %eax"),
            ("62f1fe1878c1", "vcvttss2usi {sae}, %xmm1, %rax"),
            ("62f17f1878c1", "vcvttsd2usi {sae}, %xmm1, %eax"),
            ("62f17e08794710", "vcvtss2usi 0x40(%rdi), %eax"),
            ("62f1ff08794710", "vcvtsd2usi 0x80(%rdi), %rax"),
            ("62717e0879c1", "vcvtss2usi %xmm1, %r8d"),
            ("6271ff0879f9", "vcvtsd2usi %xmm1, %r15"),
            ("6211ff0879ff", "vcvtsd2usi %xmm31, %r15"),
            ("62117e0878c6", "vcvttss2usi %xmm30, %r8d"),
        ])
    }

    func testLegacyAndPackedConvertRegressionsRemainUnchanged() {
        assertInstructions([
            ("f30f2dc1", "cvtss2si %xmm1, %eax"),
            ("f20f2cc1", "cvttsd2si %xmm1, %eax"),
            ("62f17c0879d1", "vcvtps2udq %xmm1, %xmm2"),
            ("62f1fc0878d1", "vcvttpd2udq %xmm1, %xmm2"),
        ])
    }
}
