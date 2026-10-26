import Foundation
import XCTest
@testable import MacScope

final class X86EVEXWidenCmpTests: XCTestCase {
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

    func testWideningMemoryDisp8ScalesAcrossVL() {
        assertInstruction([0x62, 0xF1, 0x7E, 0x48, 0xE6, 0x40, 0x02],
                          "vcvtdq2pd 0x40(%rax), %zmm0", length: 7)
        assertInstruction([0x62, 0xF1, 0x7E, 0x28, 0xE6, 0x40, 0x04],
                          "vcvtdq2pd 0x40(%rax), %ymm0", length: 7)
        assertInstruction([0x62, 0xF1, 0x7E, 0x08, 0xE6, 0x40, 0x08],
                          "vcvtdq2pd 0x40(%rax), %xmm0", length: 7)
    }

    func testWideningRegisterSourcesUseNarrowVectorWidths() {
        assertInstruction([0x62, 0xF1, 0x7E, 0x48, 0xE6, 0xC1],
                          "vcvtdq2pd %ymm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0x7D, 0x48, 0x31, 0xC1],
                          "vpmovzxbd %xmm1, %zmm0", length: 6)
    }

    func testVPCmpResolvedAndUnresolvedPredicates() {
        assertInstruction([0x62, 0xF3, 0x75, 0x48, 0x1F, 0xCA, 0x01],
                          "vpcmpltd %zmm2, %zmm1, %k1", length: 7)
        assertInstruction([0x62, 0xF3, 0x75, 0x48, 0x1E, 0xCA, 0x01],
                          "vpcmpltud %zmm2, %zmm1, %k1", length: 7)
        assertInstruction([0x62, 0xF3, 0x75, 0x48, 0x1F, 0xCA, 0x03],
                          "vpcmpd $0x3, %zmm2, %zmm1, %k1", length: 7)
    }

    func testVCmpFullPredicateTable() {
        assertInstruction([0x62, 0xF1, 0x74, 0x48, 0xC2, 0xCA, 0x00],
                          "vcmpeqps %zmm2, %zmm1, %k1", length: 7)
        assertInstruction([0x62, 0xF1, 0x74, 0x48, 0xC2, 0xCA, 0x08],
                          "vcmpeq_uqps %zmm2, %zmm1, %k1", length: 7)
        assertInstruction([0x62, 0xF1, 0xF5, 0x48, 0xC2, 0xCA, 0x1F],
                          "vcmptrue_uspd %zmm2, %zmm1, %k1", length: 7)
        assertInstruction([0x62, 0xF1, 0x76, 0x08, 0xC2, 0xCA, 0x1F],
                          "vcmptrue_usss %xmm2, %xmm1, %k1", length: 7)
    }

    func testExistingEVEXArithmeticStillDecodes() {
        assertInstruction([0x62, 0xF1, 0x75, 0x48, 0xFE, 0xC2],
                          "vpaddd %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF1, 0x74, 0x48, 0x5F, 0xC2],
                          "vmaxps %zmm2, %zmm1, %zmm0", length: 6)
    }
}
