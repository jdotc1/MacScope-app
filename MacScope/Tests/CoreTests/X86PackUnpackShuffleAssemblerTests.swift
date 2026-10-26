import Foundation
import XCTest
@testable import MacScope

final class X86PackUnpackShuffleAssemblerTests: XCTestCase {
    private let assembler = X86_64Assembler()

    private func assertEncodes(_ text: String, _ expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTAssertEqual(bytes, expected, "encoding mismatch for '\(text)'", file: file, line: line)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
        }
    }

    func testPackForms() {
        assertEncodes("vpackssdw %xmm1, %xmm2, %xmm3", [0xc5, 0xe9, 0x6b, 0xd9])
        assertEncodes("vpackusdw %xmm1, %xmm2, %xmm3", [0xc4, 0xe2, 0x69, 0x2b, 0xd9])
    }

    func testUnpackEachElementWidth() {
        assertEncodes("vpunpcklbw %xmm1, %xmm2, %xmm3", [0xc5, 0xe9, 0x60, 0xd9])
        assertEncodes("vpunpcklwd %xmm1, %xmm2, %xmm3", [0xc5, 0xe9, 0x61, 0xd9])
        assertEncodes("vpunpckldq %xmm1, %xmm2, %xmm3", [0xc5, 0xe9, 0x62, 0xd9])
        assertEncodes("vpunpcklqdq %ymm1, %ymm2, %ymm3", [0xc5, 0xed, 0x6c, 0xd9])
    }

    func testByteShuffleRegisterAndMemory() {
        assertEncodes("vpshufb %xmm1, %xmm2, %xmm3", [0xc4, 0xe2, 0x69, 0x00, 0xd9])
        assertEncodes("vpshufb (%rax), %xmm2, %xmm3", [0xc4, 0xe2, 0x69, 0x00, 0x18])
    }

    func testImmediateShufflesUseDestinationRegField() {
        assertEncodes("vpshufd $0x1b, %xmm2, %xmm3", [0xc5, 0xf9, 0x70, 0xda, 0x1b])
        assertEncodes("vpshuflw $0x93, %xmm2, %xmm3", [0xc5, 0xfb, 0x70, 0xda, 0x93])
        assertEncodes("vpshufhw $0x4e, %xmm2, %xmm3", [0xc5, 0xfa, 0x70, 0xda, 0x4e])
    }

    func testEVEXDecorationsBroadcastAndHighRegisters() {
        assertEncodes("vpunpckldq %zmm1, %zmm2, %zmm3 {%k2} {z}", [0x62, 0xf1, 0x6d, 0xca, 0x62, 0xd9])
        assertEncodes("vpackusdw (%rax){1to16}, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x58, 0x2b, 0x18])
        assertEncodes("vpackssdw %zmm16, %zmm17, %zmm18", [0x62, 0xa1, 0x75, 0x40, 0x6b, 0xd0])
    }

    func testVEXVersusEVEXSelection() {
        assertEncodes("vpshufd $0x1b, %xmm2, %xmm3", [0xc5, 0xf9, 0x70, 0xda, 0x1b])
        assertEncodes("vpshufd $0x1b, %xmm20, %xmm21", [0x62, 0xa1, 0x7d, 0x08, 0x70, 0xec, 0x1b])
        assertEncodes("vpshufd $0x1b, %zmm2, %zmm3 {%k1} {z}", [0x62, 0xf1, 0x7d, 0xc9, 0x70, 0xda, 0x1b])
    }
}
