import Foundation
import XCTest
@testable import MacScope

final class X86VEXAssemblerTests: XCTestCase {
    private let assembler = X86_64Assembler()

    private func assertEncodes(_ text: String, _ expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTAssertEqual(bytes, expected, "encoding mismatch for '\(text)'", file: file, line: line)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
        }
    }

    private func assertFails(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTFail("expected '\(text)' to fail but got bytes \(bytes)", file: file, line: line)
        case .failure:
            break
        }
    }

    func testPackedFloatArithmeticUsesTwoByteVEXWhenLegal() {
        assertEncodes("vaddps %xmm2, %xmm1, %xmm0", [0xc5, 0xf0, 0x58, 0xc2])
        assertEncodes("vaddpd %xmm2, %xmm1, %xmm0", [0xc5, 0xf1, 0x58, 0xc2])
        assertEncodes("vsubps %xmm2, %xmm1, %xmm0", [0xc5, 0xf0, 0x5c, 0xc2])
        assertEncodes("vmulpd %ymm2, %ymm1, %ymm0", [0xc5, 0xf5, 0x59, 0xc2])
    }

    func testYMMAndMemoryForms() {
        assertEncodes("vaddps %ymm2, %ymm1, %ymm0", [0xc5, 0xf4, 0x58, 0xc2])
        assertEncodes("vaddpd 0x20(%rdi), %ymm1, %ymm0", [0xc5, 0xf5, 0x58, 0x47, 0x20])
        assertEncodes("vpaddd (%rdi,%rsi,4), %xmm1, %xmm0", [0xc5, 0xf1, 0xfe, 0x04, 0xb7])
        assertEncodes("vaddps 0x1234(%rip), %xmm1, %xmm0", [0xc5, 0xf0, 0x58, 0x05, 0x34, 0x12, 0x00, 0x00])
    }

    func testPackedIntegerAndMap38Forms() {
        assertEncodes("vpaddb %xmm2, %xmm1, %xmm0", [0xc5, 0xf1, 0xfc, 0xc2])
        assertEncodes("vpxor %xmm2, %xmm1, %xmm0", [0xc5, 0xf1, 0xef, 0xc2])
        assertEncodes("vpcmpeqd %ymm2, %ymm1, %ymm0", [0xc5, 0xf5, 0x76, 0xc2])
        assertEncodes("vpmulld %xmm2, %xmm1, %xmm0", [0xc4, 0xe2, 0x71, 0x40, 0xc2])
    }

    func testMovesLoadStoreAndHighRegisters() {
        assertEncodes("vmovaps %xmm1, %xmm0", [0xc5, 0xf8, 0x28, 0xc1])
        assertEncodes("vmovaps %xmm8, %xmm0", [0xc5, 0x78, 0x29, 0xc0])
        assertEncodes("vmovaps %ymm1, %ymm0", [0xc5, 0xfc, 0x28, 0xc1])
        assertEncodes("vmovdqu %xmm1, %xmm0", [0xc5, 0xfa, 0x6f, 0xc1])
        assertEncodes("vmovaps (%rdi), %ymm0", [0xc5, 0xfc, 0x28, 0x07])
        assertEncodes("vmovups %ymm0, (%rdi)", [0xc5, 0xfc, 0x11, 0x07])
        assertEncodes("vaddps %xmm10, %xmm11, %xmm12", [0xc4, 0x41, 0x20, 0x58, 0xe2])
        assertEncodes("vpxor %ymm14, %ymm15, %ymm13", [0xc4, 0x41, 0x05, 0xef, 0xee])
        assertEncodes("vmovaps %xmm9, %xmm8", [0xc4, 0x41, 0x78, 0x28, 0xc1])
    }

    func testRejectsMismatchedVectorWidths() {
        assertFails("vaddps %xmm2, %ymm1, %ymm0")
        assertFails("vmovaps %xmm1, %ymm0")
    }
}
