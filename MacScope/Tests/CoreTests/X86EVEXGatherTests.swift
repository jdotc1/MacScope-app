import Foundation
import XCTest
@testable import MacScope

final class X86EVEXGatherTests: XCTestCase {
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

    func testDwordIndexGatherUsesVectorSIBAndElementDisp8Scale() {
        assertInstruction([0x62, 0xF2, 0x7D, 0x49, 0x92, 0x44, 0x88, 0x10],
                          "vgatherdps 0x40(%rax,%zmm1,4), %zmm0 {%k1}",
                          length: 8)
    }

    func testQwordIndexGatherCanUseNarrowerDataVector() {
        assertInstruction([0x62, 0xF2, 0x7D, 0x49, 0x93, 0x44, 0x88, 0x10],
                          "vgatherqps 0x40(%rax,%zmm1,4), %ymm0 {%k1}",
                          length: 8)
    }

    func testDwordIndexScatterCanUseNarrowerIndexVectorAndQwordScale() {
        assertInstruction([0x62, 0xF2, 0xFD, 0x49, 0xA0, 0x44, 0xC8, 0x08],
                          "vpscatterdq %zmm0, 0x40(%rax,%ymm1,8) {%k1}",
                          length: 8)
    }

    func testQwordIndexScatterUsesScatterOperandOrder() {
        assertInstruction([0x62, 0xF2, 0x7D, 0x49, 0xA1, 0x44, 0x88, 0x10],
                          "vpscatterqd %ymm0, 0x40(%rax,%zmm1,4) {%k1}",
                          length: 8)
    }

    func testVSIBIndexAndBaseExtension() {
        assertInstruction([0x62, 0xB2, 0x7D, 0x41, 0x92, 0x44, 0x88, 0x10],
                          "vgatherdps 0x40(%rax,%zmm25,4), %zmm0 {%k1}",
                          length: 8)
        assertInstruction([0x62, 0xD2, 0x7D, 0x0A, 0x90, 0x34, 0x2E],
                          "vpgatherdd (%r14,%xmm5), %xmm6 {%k2}",
                          length: 7)
    }

    func testExistingMap2WideningDecodeIsUnchanged() {
        assertInstruction([0x62, 0xF2, 0x7D, 0x48, 0x30, 0xC1],
                          "vpmovzxbw %ymm1, %zmm0",
                          length: 6)
    }
}
