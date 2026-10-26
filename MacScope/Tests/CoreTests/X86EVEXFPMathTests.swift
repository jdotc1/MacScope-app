import Foundation
import XCTest
@testable import MacScope

final class X86EVEXFPMathTests: XCTestCase {
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

    func testGetExpPackedScalarMemoryAndSAE() {
        assertInstruction([0x62, 0xF2, 0x7D, 0x48, 0x42, 0xC1],
                          "vgetexpps %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0x7D, 0x48, 0x42, 0x40, 0x01],
                          "vgetexpps 0x40(%rax), %zmm0", length: 7)
        assertInstruction([0x62, 0xF2, 0xFD, 0x18, 0x42, 0xC1],
                          "vgetexppd {sae}, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0x75, 0x08, 0x43, 0xC2],
                          "vgetexpss %xmm2, %xmm1, %xmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xF5, 0x08, 0x43, 0xC2],
                          "vgetexpsd %xmm2, %xmm1, %xmm0", length: 6)
    }

    func testGetMantReduceAndRndScaleImmediateForms() {
        assertInstruction([0x62, 0xF3, 0x7D, 0x48, 0x26, 0xC1, 0x01],
                          "vgetmantps $0x1, %zmm1, %zmm0", length: 7)
        assertInstruction([0x62, 0xF3, 0xFD, 0x48, 0x26, 0x40, 0x01, 0x02],
                          "vgetmantpd $0x2, 0x40(%rax), %zmm0", length: 8)
        assertInstruction([0x62, 0xF3, 0x75, 0x08, 0x27, 0xC2, 0x01],
                          "vgetmantss $0x1, %xmm2, %xmm1, %xmm0", length: 7)
        assertInstruction([0x62, 0xF3, 0xFD, 0x48, 0x56, 0xC1, 0x03],
                          "vreducepd $0x3, %zmm1, %zmm0", length: 7)
        assertInstruction([0x62, 0xF3, 0xF5, 0x08, 0x57, 0xC2, 0x01],
                          "vreducesd $0x1, %xmm2, %xmm1, %xmm0", length: 7)
        assertInstruction([0x62, 0xF3, 0x7D, 0x18, 0x08, 0xC1, 0x01],
                          "vrndscaleps $0x1, {sae}, %zmm1, %zmm0", length: 7)
        assertInstruction([0x62, 0xF3, 0xF5, 0x08, 0x0B, 0xC2, 0x03],
                          "vrndscalesd $0x3, %xmm2, %xmm1, %xmm0", length: 7)
    }

    func testRangeAndFixupImmThreeOperandForms() {
        assertInstruction([0x62, 0xF3, 0x75, 0x48, 0x50, 0xC2, 0x04],
                          "vrangeps $0x4, %zmm2, %zmm1, %zmm0", length: 7)
        assertInstruction([0x62, 0xF3, 0xF5, 0x48, 0x50, 0xC2, 0x02],
                          "vrangepd $0x2, %zmm2, %zmm1, %zmm0", length: 7)
        assertInstruction([0x62, 0xF3, 0x75, 0x08, 0x51, 0xC2, 0x01],
                          "vrangess $0x1, %xmm2, %xmm1, %xmm0", length: 7)
        assertInstruction([0x62, 0xF3, 0x75, 0x48, 0x54, 0xC2, 0x00],
                          "vfixupimmps $0x0, %zmm2, %zmm1, %zmm0", length: 7)
        assertInstruction([0x62, 0xF3, 0xF5, 0x48, 0x54, 0xC2, 0x01],
                          "vfixupimmpd $0x1, %zmm2, %zmm1, %zmm0", length: 7)
        assertInstruction([0x62, 0xF3, 0xF5, 0x08, 0x55, 0xC2, 0x03],
                          "vfixupimmsd $0x3, %xmm2, %xmm1, %xmm0", length: 7)
    }

    func testRcp14Rsqrt14LzcntAndConflictForms() {
        assertInstruction([0x62, 0xF2, 0x7D, 0x48, 0x4C, 0xC1],
                          "vrcp14ps %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xF5, 0x08, 0x4D, 0xC2],
                          "vrcp14sd %xmm2, %xmm1, %xmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0x7D, 0x48, 0x4E, 0xC1],
                          "vrsqrt14ps %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0x75, 0x08, 0x4F, 0xC2],
                          "vrsqrt14ss %xmm2, %xmm1, %xmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0x7D, 0x48, 0x44, 0xC1],
                          "vplzcntd %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xFD, 0x48, 0x44, 0xC1],
                          "vplzcntq %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0x7D, 0x48, 0xC4, 0xC1],
                          "vpconflictd %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xFD, 0x48, 0xC4, 0xC1],
                          "vpconflictq %zmm1, %zmm0", length: 6)
    }

    func testNarrowingConvertsUseAuthoritativeWidths() {
        assertInstruction([0x62, 0xF1, 0x7F, 0x48, 0x7A, 0xC1],
                          "vcvtudq2ps %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF1, 0xFD, 0x48, 0x5A, 0xC1],
                          "vcvtpd2ps %zmm1, %ymm0", length: 6)
        assertInstruction([0x62, 0xF1, 0xFF, 0x48, 0xE6, 0xC1],
                          "vcvtpd2dq %zmm1, %ymm0", length: 6)
        assertInstruction([0x62, 0xF1, 0xFD, 0x48, 0xE6, 0xC1],
                          "vcvttpd2dq %zmm1, %ymm0", length: 6)
        assertInstruction([0x62, 0xF1, 0xFF, 0x48, 0x7A, 0xC1],
                          "vcvtuqq2ps %zmm1, %ymm0", length: 6)
        assertInstruction([0x62, 0xF1, 0xFD, 0x18, 0x5A, 0xC1],
                          "vcvtpd2ps {rn-sae}, %zmm1, %ymm0", length: 6)
    }

    func testEVEXFPMathImmediateDesyncGuard() {
        let stream: [UInt8] = [
            0x62, 0xF3, 0x7D, 0x18, 0x08, 0xC1, 0x01,
            0xC3,
        ]
        let rows = decoder.decode(Data(stream), baseAddress: 0x1000, maxInstructionCount: 4)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "vrndscaleps")
        XCTAssertEqual(rows[0].operands, "$0x1, {sae}, %zmm1, %zmm0")
        XCTAssertEqual(rows[0].bytes.count, 7)
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1007)
    }

    // The narrowing/converts must render embedded rounding / {sae} when the EVEX b-bit is set on a
    // register source (b=0 forms already worked; the b=1 rounding sub-form was the gap).
    func testConvertsEmbeddedRoundingAndSAE() {
        assertInstruction([0x62, 0xF1, 0xFF, 0x18, 0xE6, 0xC1], "vcvtpd2dq {rn-sae}, %zmm1, %ymm0", length: 6)
        assertInstruction([0x62, 0xF1, 0xFF, 0x58, 0xE6, 0xC1], "vcvtpd2dq {ru-sae}, %zmm1, %ymm0", length: 6)
        assertInstruction([0x62, 0xF1, 0xFD, 0x18, 0xE6, 0xC1], "vcvttpd2dq {sae}, %zmm1, %ymm0", length: 6)
        assertInstruction([0x62, 0xF1, 0x7F, 0x18, 0x7A, 0xC1], "vcvtudq2ps {rn-sae}, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF1, 0xFF, 0x18, 0x7A, 0xC1], "vcvtuqq2ps {rn-sae}, %zmm1, %ymm0", length: 6)
    }
}
