import Foundation
import XCTest
@testable import MacScope

final class X86BlendTernlogAssemblerTests: XCTestCase {
    private let assembler = X86_64Assembler()

    private func assertEncodes(_ text: String, _ expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTAssertEqual(bytes, expected, "encoding mismatch for '\(text)'", file: file, line: line)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
        }
    }

    func testEVEXMaskBlendOpcodeAndWTable() {
        assertEncodes("vpblendmb %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x66, 0xd9])
        assertEncodes("vpblendmw %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x66, 0xd9])
        assertEncodes("vpblendmd %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x64, 0xd9])
        assertEncodes("vpblendmq %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x64, 0xd9])
        assertEncodes("vblendmps %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x65, 0xd9])
        assertEncodes("vblendmpd %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x65, 0xd9])
    }

    func testMaskBlendEVEXOnlyVLAndDecorations() {
        assertEncodes("vpblendmd %xmm1, %xmm2, %xmm3", [0x62, 0xf2, 0x6d, 0x08, 0x64, 0xd9])
        assertEncodes("vpblendmq %ymm1, %ymm2, %ymm3", [0x62, 0xf2, 0xed, 0x28, 0x64, 0xd9])
        assertEncodes("vpblendmd %zmm1, %zmm2, %zmm3 {%k1}", [0x62, 0xf2, 0x6d, 0x49, 0x64, 0xd9])
        assertEncodes("vpblendmq %zmm1, %zmm2, %zmm3 {%k2} {z}", [0x62, 0xf2, 0xed, 0xca, 0x64, 0xd9])
    }

    func testMaskBlendBroadcastAndHighRegisters() {
        assertEncodes("vpblendmd (%rax){1to16}, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x58, 0x64, 0x18])
        assertEncodes("vblendmpd (%rax){1to8}, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x58, 0x65, 0x18])
        assertEncodes("vpblendmd %zmm16, %zmm17, %zmm18", [0x62, 0xa2, 0x75, 0x40, 0x64, 0xd0])
    }

    func testEVEXTernaryLogicImmediateAndWTable() {
        assertEncodes("vpternlogd $0xca, %zmm1, %zmm2, %zmm3", [0x62, 0xf3, 0x6d, 0x48, 0x25, 0xd9, 0xca])
        assertEncodes("vpternlogq $0x96, %zmm1, %zmm2, %zmm3", [0x62, 0xf3, 0xed, 0x48, 0x25, 0xd9, 0x96])
        assertEncodes("vpternlogd $0xff, %xmm1, %xmm2, %xmm3", [0x62, 0xf3, 0x6d, 0x08, 0x25, 0xd9, 0xff])
        assertEncodes("vpternlogq $0x00, %ymm1, %ymm2, %ymm3", [0x62, 0xf3, 0xed, 0x28, 0x25, 0xd9, 0x00])
    }

    func testTernaryLogicDecorationsBroadcastAndHighRegisters() {
        assertEncodes("vpternlogd $0xca, %zmm1, %zmm2, %zmm3 {%k1}", [0x62, 0xf3, 0x6d, 0x49, 0x25, 0xd9, 0xca])
        assertEncodes("vpternlogd $0xca, %zmm1, %zmm2, %zmm3 {%k1} {z}", [0x62, 0xf3, 0x6d, 0xc9, 0x25, 0xd9, 0xca])
        assertEncodes("vpternlogd $0x55, (%rax){1to16}, %zmm2, %zmm3", [0x62, 0xf3, 0x6d, 0x58, 0x25, 0x18, 0x55])
        assertEncodes("vpternlogq $0x55, (%rax){1to8}, %zmm2, %zmm3", [0x62, 0xf3, 0xed, 0x58, 0x25, 0x18, 0x55])
        assertEncodes("vpternlogd $0xca, %zmm16, %zmm17, %zmm18", [0x62, 0xa3, 0x75, 0x40, 0x25, 0xd0, 0xca])
    }
}
