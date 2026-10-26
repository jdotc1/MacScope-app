import Foundation
import XCTest
@testable import MacScope

final class X86IntegerShiftAssemblerTests: XCTestCase {
    private let assembler = X86_64Assembler()

    private func assertEncodes(_ text: String, _ expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTAssertEqual(bytes, expected, "encoding mismatch for '\(text)'", file: file, line: line)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
        }
    }

    func testVariablePerElementShiftForms() {
        assertEncodes("vpsllvd %xmm1, %xmm2, %xmm3", [0xc4, 0xe2, 0x69, 0x47, 0xd9])
        assertEncodes("vpsravq %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x46, 0xd9])
        assertEncodes("vpsrlvw %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x10, 0xd9])
    }

    func testShiftByXMMCountForms() {
        assertEncodes("vpsllw %xmm1, %xmm2, %xmm3", [0xc5, 0xe9, 0xf1, 0xd9])
        assertEncodes("vpslld %xmm1, %ymm2, %ymm3", [0xc5, 0xed, 0xf2, 0xd9])
        assertEncodes("vpsraq %xmm1, %xmm2, %xmm3", [0x62, 0xf1, 0xed, 0x08, 0xe2, 0xd9])
    }

    func testImmediateShiftOpcodeGroups() {
        assertEncodes("vpsllw $3, %zmm2, %zmm3", [0x62, 0xf1, 0x65, 0x48, 0x71, 0xf2, 0x03])
        assertEncodes("vpsraw $3, %ymm2, %ymm3", [0xc5, 0xe5, 0x71, 0xe2, 0x03])
        assertEncodes("vpslld $5, %xmm2, %xmm3", [0xc5, 0xe1, 0x72, 0xf2, 0x05])
        assertEncodes("vpsrld $5, %xmm2, %xmm3", [0xc5, 0xe1, 0x72, 0xd2, 0x05])
        assertEncodes("vpsrad $5, %xmm2, %xmm3", [0xc5, 0xe1, 0x72, 0xe2, 0x05])
        assertEncodes("vpsllq $7, %ymm2, %ymm3", [0xc5, 0xe5, 0x73, 0xf2, 0x07])
        assertEncodes("vpsrlq $7, %ymm2, %ymm3", [0xc5, 0xe5, 0x73, 0xd2, 0x07])
    }

    func testEVEXDecorationsBroadcastAndHighRegisters() {
        assertEncodes("vpslld $5, %zmm2, %zmm3 {%k1} {z}", [0x62, 0xf1, 0x65, 0xc9, 0x72, 0xf2, 0x05])
        assertEncodes("vpsrld $8, (%rax){1to16}, %zmm3", [0x62, 0xf1, 0x65, 0x58, 0x72, 0x10, 0x08])
        assertEncodes("vpslld $5, %zmm17, %zmm18", [0x62, 0xb1, 0x6d, 0x40, 0x72, 0xf1, 0x05])
    }

    func testVEXVersusEVEXSelection() {
        assertEncodes("vpsllvd %xmm1, %xmm2, %xmm3", [0xc4, 0xe2, 0x69, 0x47, 0xd9])
        assertEncodes("vpsllvd %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x47, 0xd9])
        assertEncodes("vpsraq $7, %xmm2, %xmm3", [0x62, 0xf1, 0xe5, 0x08, 0x72, 0xe2, 0x07])
    }
}
