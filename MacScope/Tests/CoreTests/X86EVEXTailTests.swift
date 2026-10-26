import Foundation
import XCTest
@testable import MacScope

final class X86EVEXTailTests: XCTestCase {
    private let decoder = X86_64Decoder()

    private func one(_ bytes: [UInt8], at address: UInt64 = 0x1000) -> DecodedInstruction {
        decoder.decode(Data(bytes), baseAddress: address, maxInstructionCount: 1)[0]
    }

    private func assertInstruction(_ bytes: [UInt8], _ expected: String, length: Int? = nil,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let row = one(bytes)
        let text = row.operands.isEmpty ? row.mnemonic : row.mnemonic + " " + row.operands
        XCTAssertEqual(text, expected, file: file, line: line)
        XCTAssertEqual(row.bytes.count, length ?? bytes.count, file: file, line: line)
    }

    func testQqToPdConvertsAreFullTuple() {
        assertInstruction([0x62, 0xF1, 0xFE, 0x48, 0xE6, 0xC1],
                          "vcvtqq2pd %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF1, 0xFE, 0x48, 0x7A, 0xC1],
                          "vcvtuqq2pd %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF1, 0xFE, 0x48, 0xE6, 0x40, 0x01],
                          "vcvtqq2pd 0x40(%rax), %zmm0", length: 7)
        assertInstruction([0x62, 0xF1, 0xFE, 0x4B, 0xE6, 0xC1],
                          "vcvtqq2pd %zmm1, %zmm0 {%k3}", length: 6)
    }

    func testLegacyMaskCompares() {
        assertInstruction([0x62, 0xF1, 0x75, 0x48, 0x74, 0xC2],
                          "vpcmpeqb %zmm2, %zmm1, %k0", length: 6)
        assertInstruction([0x62, 0xF1, 0x75, 0x48, 0x65, 0xC2],
                          "vpcmpgtw %zmm2, %zmm1, %k0", length: 6)
    }

    func testEmbeddedRoundingAllLLModes() {
        assertInstruction([0x62, 0xF1, 0x74, 0x18, 0x58, 0xC2],
                          "vaddps {rn-sae}, %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF1, 0x74, 0x38, 0x58, 0xC2],
                          "vaddps {rd-sae}, %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF1, 0x74, 0x58, 0x58, 0xC2],
                          "vaddps {ru-sae}, %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF1, 0x74, 0x78, 0x58, 0xC2],
                          "vaddps {rz-sae}, %zmm2, %zmm1, %zmm0", length: 6)
    }

    func testSAEOnlyAndVCmpDecoration() {
        assertInstruction([0x62, 0xF1, 0x74, 0x18, 0x5F, 0xC2],
                          "vmaxps {sae}, %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF1, 0x74, 0x18, 0xC2, 0xC2, 0x00],
                          "vcmpeqps {sae}, %zmm2, %zmm1, %k0", length: 7)
    }

    func testExistingB0FPFormsRemainUndecorated() {
        assertInstruction([0x62, 0xF1, 0x74, 0x48, 0x58, 0xC2],
                          "vaddps %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF1, 0x74, 0x48, 0x5F, 0xC2],
                          "vmaxps %zmm2, %zmm1, %zmm0", length: 6)
    }
}
