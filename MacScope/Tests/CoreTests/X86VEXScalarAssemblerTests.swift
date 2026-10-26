import Foundation
import XCTest
@testable import MacScope

final class X86VEXScalarAssemblerTests: XCTestCase {
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

    func testScalarArithmeticAndConvertsUseF3F2Prefixes() {
        assertEncodes("vaddss %xmm2, %xmm1, %xmm0", [0xc5, 0xf2, 0x58, 0xc2])
        assertEncodes("vaddsd %xmm2, %xmm1, %xmm0", [0xc5, 0xf3, 0x58, 0xc2])
        assertEncodes("vsubss %xmm2, %xmm1, %xmm0", [0xc5, 0xf2, 0x5c, 0xc2])
        assertEncodes("vmulsd 0x20(%rdi), %xmm1, %xmm0", [0xc5, 0xf3, 0x59, 0x47, 0x20])
        assertEncodes("vsqrtss %xmm2, %xmm1, %xmm0", [0xc5, 0xf2, 0x51, 0xc2])
        assertEncodes("vsqrtsd %xmm2, %xmm1, %xmm0", [0xc5, 0xf3, 0x51, 0xc2])
        assertEncodes("vcvtss2sd %xmm2, %xmm1, %xmm0", [0xc5, 0xf2, 0x5a, 0xc2])
        assertEncodes("vcvtsd2ss %xmm2, %xmm1, %xmm0", [0xc5, 0xf3, 0x5a, 0xc2])
    }

    func testScalarMoveRegisterMergeVersusMemoryForms() {
        assertEncodes("vmovss %xmm2, %xmm1, %xmm0", [0xc5, 0xf2, 0x10, 0xc2])
        assertEncodes("vmovsd %xmm2, %xmm1, %xmm0", [0xc5, 0xf3, 0x10, 0xc2])
        assertEncodes("vmovss (%rdi), %xmm0", [0xc5, 0xfa, 0x10, 0x07])
        assertEncodes("vmovsd (%rdi), %xmm0", [0xc5, 0xfb, 0x10, 0x07])
        assertEncodes("vmovss %xmm0, (%rdi)", [0xc5, 0xfa, 0x11, 0x07])
        assertEncodes("vmovsd %xmm0, 0x8(%rsp)", [0xc5, 0xfb, 0x11, 0x44, 0x24, 0x08])
        assertFails("vmovss %xmm1, %xmm0")
        assertFails("vmovss (%rdi), %xmm1, %xmm0")
    }

    func testScalarComparesUseNoRepPrefixForSingleAnd66ForDouble() {
        assertEncodes("vcomiss %xmm1, %xmm0", [0xc5, 0xf8, 0x2f, 0xc1])
        assertEncodes("vcomisd %xmm1, %xmm0", [0xc5, 0xf9, 0x2f, 0xc1])
        assertEncodes("vucomiss %xmm1, %xmm0", [0xc5, 0xf8, 0x2e, 0xc1])
        assertEncodes("vucomisd %xmm3, %xmm2", [0xc5, 0xf9, 0x2e, 0xd3])
    }

    func testScalarFMAUsesMap38P66AndWBitForDouble() {
        assertEncodes("vfmadd132ss %xmm2, %xmm1, %xmm0", [0xc4, 0xe2, 0x71, 0x99, 0xc2])
        assertEncodes("vfmadd213ss %xmm2, %xmm1, %xmm0", [0xc4, 0xe2, 0x71, 0xa9, 0xc2])
        assertEncodes("vfmadd231ss %xmm2, %xmm1, %xmm0", [0xc4, 0xe2, 0x71, 0xb9, 0xc2])
        assertEncodes("vfmadd132sd %xmm2, %xmm1, %xmm0", [0xc4, 0xe2, 0xf1, 0x99, 0xc2])
        assertEncodes("vfmadd213sd %xmm2, %xmm1, %xmm0", [0xc4, 0xe2, 0xf1, 0xa9, 0xc2])
        assertEncodes("vfmsub213ss %xmm2, %xmm1, %xmm0", [0xc4, 0xe2, 0x71, 0xab, 0xc2])
        assertEncodes("vfnmadd231sd %xmm2, %xmm1, %xmm0", [0xc4, 0xe2, 0xf1, 0xbd, 0xc2])
        assertEncodes("vfnmsub132ss %xmm2, %xmm1, %xmm0", [0xc4, 0xe2, 0x71, 0x9f, 0xc2])
    }

    func testHighRegistersUseTwoByteVEXWhenOnlyRorVIsHigh() {
        assertEncodes("vaddss %xmm2, %xmm1, %xmm8", [0xc5, 0x72, 0x58, 0xc2])
        assertEncodes("vaddss %xmm2, %xmm11, %xmm0", [0xc5, 0xa2, 0x58, 0xc2])
        assertEncodes("vmovss %xmm10, %xmm1, %xmm0", [0xc5, 0x72, 0x11, 0xd0])
    }

    func testHighRMOrMemoryBaseForcesThreeByteVEX() {
        assertEncodes("vaddss %xmm10, %xmm1, %xmm0", [0xc4, 0xc1, 0x72, 0x58, 0xc2])
        assertEncodes("vaddss (%r8), %xmm1, %xmm0", [0xc4, 0xc1, 0x72, 0x58, 0x00])
        assertEncodes("vfmadd231sd %xmm10, %xmm9, %xmm8", [0xc4, 0x42, 0xb1, 0xb9, 0xc2])
    }

    func testScalarFormsRejectYMMRegisters() {
        assertFails("vaddss %ymm2, %ymm1, %ymm0")
        assertFails("vfmadd213sd %xmm2, %ymm1, %xmm0")
    }
}
