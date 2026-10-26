import Foundation
import XCTest
@testable import MacScope

final class X86EVEXIntegerMinMaxMulAssemblerTests: XCTestCase {
    private let assembler = X86_64Assembler()

    private func assertEncodes(_ text: String, _ expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTAssertEqual(bytes, expected, "encoding mismatch for '\(text)'", file: file, line: line)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
        }
    }

    func testEVEXSignedMinMaxAllWidths() {
        assertEncodes("vpmaxsb %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x3c, 0xd9])
        assertEncodes("vpminsb %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x38, 0xd9])
        assertEncodes("vpmaxsw %zmm1, %zmm2, %zmm3", [0x62, 0xf1, 0x6d, 0x48, 0xee, 0xd9])
        assertEncodes("vpminsw %zmm1, %zmm2, %zmm3", [0x62, 0xf1, 0x6d, 0x48, 0xea, 0xd9])
        assertEncodes("vpmaxsd %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x3d, 0xd9])
        assertEncodes("vpminsd %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x39, 0xd9])
        assertEncodes("vpmaxsq %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x3d, 0xd9])
        assertEncodes("vpminsq %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x39, 0xd9])
    }

    func testEVEXUnsignedMinMaxAllWidths() {
        assertEncodes("vpmaxub %zmm1, %zmm2, %zmm3", [0x62, 0xf1, 0x6d, 0x48, 0xde, 0xd9])
        assertEncodes("vpminub %zmm1, %zmm2, %zmm3", [0x62, 0xf1, 0x6d, 0x48, 0xda, 0xd9])
        assertEncodes("vpmaxuw %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x3e, 0xd9])
        assertEncodes("vpminuw %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x3a, 0xd9])
        assertEncodes("vpmaxud %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x3f, 0xd9])
        assertEncodes("vpminud %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x3b, 0xd9])
        assertEncodes("vpmaxuq %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x3f, 0xd9])
        assertEncodes("vpminuq %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x3b, 0xd9])
    }

    func testEVEXExtendedMultiplyForms() {
        assertEncodes("vpmuldq %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x28, 0xd9])
        assertEncodes("vpmuludq %zmm1, %zmm2, %zmm3", [0x62, 0xf1, 0xed, 0x48, 0xf4, 0xd9])
        assertEncodes("vpmullw %zmm1, %zmm2, %zmm3", [0x62, 0xf1, 0x6d, 0x48, 0xd5, 0xd9])
        assertEncodes("vpmulhw %zmm1, %zmm2, %zmm3", [0x62, 0xf1, 0x6d, 0x48, 0xe5, 0xd9])
        assertEncodes("vpmulhuw %zmm1, %zmm2, %zmm3", [0x62, 0xf1, 0x6d, 0x48, 0xe4, 0xd9])
        assertEncodes("vpmulhrsw %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x0b, 0xd9])
    }

    func testEVEXDecorationsBroadcastAndHighRegisters() {
        assertEncodes("vpminsq %zmm1, %zmm2, %zmm3 {%k2} {z}", [0x62, 0xf2, 0xed, 0xca, 0x39, 0xd9])
        assertEncodes("vpmaxsd (%rax){1to16}, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x58, 0x3d, 0x18])
        assertEncodes("vpmuldq (%rax){1to8}, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x58, 0x28, 0x18])
        assertEncodes("vpmaxsd %xmm16, %xmm17, %xmm18", [0x62, 0xa2, 0x75, 0x00, 0x3d, 0xd0])
    }

    func testVEXSelectionAndTwoByteCanonicalization() {
        assertEncodes("vpmaxsw %xmm1, %xmm2, %xmm3", [0xc5, 0xe9, 0xee, 0xd9])
        assertEncodes("vpmaxsd %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x3d, 0xd9])
        assertEncodes("vpmaxub %xmm8, %xmm1, %xmm0", [0xc5, 0xb9, 0xde, 0xc1])
        assertEncodes("vpmullw %xmm8, %xmm1, %xmm0", [0xc5, 0xb9, 0xd5, 0xc1])
    }
}
