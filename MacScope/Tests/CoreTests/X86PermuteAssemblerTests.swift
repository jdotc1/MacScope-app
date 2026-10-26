import Foundation
import XCTest
@testable import MacScope

final class X86PermuteAssemblerTests: XCTestCase {
    private let assembler = X86_64Assembler()

    private func assertEncodes(_ text: String, _ expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTAssertEqual(bytes, expected, "encoding mismatch for '\(text)'", file: file, line: line)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
        }
    }

    private func assertRejects(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTFail("assembled '\(text)' unexpectedly as \(bytes.map { String(format: "%02x", $0) }.joined())", file: file, line: line)
        case .failure:
            break
        }
    }

    func testIndexVectorPermuteOpcodeAndWTable() {
        assertEncodes("vpermd %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x36, 0xd9])
        assertEncodes("vpermq %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x36, 0xd9])
        assertEncodes("vpermps %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x16, 0xd9])
        assertEncodes("vpermpd %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x16, 0xd9])
        assertEncodes("vpermw %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x8d, 0xd9])
        assertEncodes("vpermb %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x8d, 0xd9])
    }

    func testVpermi2Vpermt2OpcodeAndWTable() {
        assertEncodes("vpermi2b %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x75, 0xd9])
        assertEncodes("vpermi2w %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x75, 0xd9])
        assertEncodes("vpermi2d %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x76, 0xd9])
        assertEncodes("vpermi2q %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x76, 0xd9])
        assertEncodes("vpermi2ps %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x77, 0xd9])
        assertEncodes("vpermi2pd %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x77, 0xd9])
        assertEncodes("vpermt2b %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x7d, 0xd9])
        assertEncodes("vpermt2w %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x7d, 0xd9])
        assertEncodes("vpermt2d %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x7e, 0xd9])
        assertEncodes("vpermt2q %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x7e, 0xd9])
        assertEncodes("vpermt2ps %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x48, 0x7f, 0xd9])
        assertEncodes("vpermt2pd %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x7f, 0xd9])
    }

    func testVpermqVpermpdDispatchesThreeOperandAndImmediateForms() {
        assertEncodes("vpermq %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x36, 0xd9])
        assertEncodes("vpermq $0x1b, %zmm2, %zmm3", [0x62, 0xf3, 0xfd, 0x48, 0x00, 0xda, 0x1b])
        assertEncodes("vpermpd %zmm1, %zmm2, %zmm3", [0x62, 0xf2, 0xed, 0x48, 0x16, 0xd9])
        assertEncodes("vpermpd $0xe4, %ymm2, %ymm3", [0xc4, 0xe3, 0xfd, 0x01, 0xda, 0xe4])
    }

    func testDecorationsBroadcastVEXAndHighRegisters() {
        assertEncodes("vpermd %ymm1, %ymm2, %ymm3", [0xc4, 0xe2, 0x6d, 0x36, 0xd9])
        assertEncodes("vpermq %zmm1, %zmm2, %zmm3 {%k1}", [0x62, 0xf2, 0xed, 0x49, 0x36, 0xd9])
        assertEncodes("vpermd (%rax){1to16}, %zmm2, %zmm3", [0x62, 0xf2, 0x6d, 0x58, 0x36, 0x18])
        assertEncodes("vpermpd $0x1b, (%rax){1to8}, %zmm3", [0x62, 0xf3, 0xfd, 0x58, 0x01, 0x18, 0x1b])
        assertEncodes("vpermi2d %zmm16, %zmm17, %zmm18 {%k2} {z}", [0x62, 0xa2, 0x75, 0xc2, 0x76, 0xd0])
    }

    func testByteWordPermutesRejectBroadcast() {
        assertRejects("vpermb (%rax){1to64}, %zmm2, %zmm3")
        assertRejects("vpermw (%rax){1to32}, %zmm2, %zmm3")
        assertRejects("vpermi2b (%rax){1to64}, %zmm2, %zmm3")
        assertRejects("vpermt2w (%rax){1to32}, %zmm2, %zmm3")
    }
}
