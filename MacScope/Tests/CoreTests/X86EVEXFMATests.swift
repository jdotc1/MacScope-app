import Foundation
import XCTest
@testable import MacScope

final class X86EVEXFMATests: XCTestCase {
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

    func testExistingEVEXVfmadd213psUnchanged() {
        assertInstruction([0x62, 0xF2, 0x75, 0x48, 0xA8, 0xC2],
                          "vfmadd213ps %zmm2, %zmm1, %zmm0", length: 6)
    }

    func testEVEXVfmaddScalarAndRounding() {
        assertInstruction([0x62, 0xF2, 0x75, 0x08, 0x99, 0xC2],
                          "vfmadd132ss %xmm2, %xmm1, %xmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xF5, 0x08, 0xA9, 0xC2],
                          "vfmadd213sd %xmm2, %xmm1, %xmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0x75, 0x18, 0x99, 0xC2],
                          "vfmadd132ss {rn-sae}, %xmm2, %xmm1, %xmm0", length: 6)
    }

    func testEVEXVfmsubForms() {
        assertInstruction([0x62, 0xF2, 0x75, 0x48, 0x9A, 0x40, 0x01],
                          "vfmsub132ps 0x40(%rax), %zmm1, %zmm0", length: 7)
        assertInstruction([0x62, 0xF2, 0x75, 0x08, 0xAB, 0xC2],
                          "vfmsub213ss %xmm2, %xmm1, %xmm0", length: 6)
    }

    func testEVEXNegativeFMAForms() {
        assertInstruction([0x62, 0xF2, 0xF5, 0x48, 0xBC, 0xC2],
                          "vfnmadd231pd %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xF5, 0x08, 0xBF, 0xC2],
                          "vfnmsub231sd %xmm2, %xmm1, %xmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xF5, 0x78, 0xBF, 0xC2],
                          "vfnmsub231sd {rz-sae}, %xmm2, %xmm1, %xmm0", length: 6)
    }

    func testEVEXAddSubFamilies() {
        assertInstruction([0x62, 0xF2, 0x75, 0x58, 0x96, 0x40, 0x10],
                          "vfmaddsub132ps 0x40(%rax){1to16}, %zmm1, %zmm0", length: 7)
        assertInstruction([0x62, 0xF2, 0xF5, 0x48, 0xA6, 0xC2],
                          "vfmaddsub213pd %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0x75, 0x58, 0x97, 0x40, 0x10],
                          "vfmsubadd132ps 0x40(%rax){1to16}, %zmm1, %zmm0", length: 7)
        assertInstruction([0x62, 0xF2, 0xF5, 0x78, 0xB7, 0xC2],
                          "vfmsubadd231pd {rz-sae}, %zmm2, %zmm1, %zmm0", length: 6)
    }

    func testCorpusScalarVEXGroundtruthForms() {
        assertInstruction([0xC4, 0xE2, 0x71, 0x99, 0xC2],
                          "vfmadd132ss %xmm2, %xmm1, %xmm0", length: 5)
        assertInstruction([0xC4, 0xE2, 0xF1, 0xBF, 0xC2],
                          "vfnmsub231sd %xmm2, %xmm1, %xmm0", length: 5)
    }
}
