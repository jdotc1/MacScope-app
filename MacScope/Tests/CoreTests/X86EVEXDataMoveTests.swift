import Foundation
import XCTest
@testable import MacScope

final class X86EVEXDataMoveTests: XCTestCase {
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

    func testExpandUsesTuple1ScalarDisp8AndLoadOperandOrder() {
        assertInstruction([0x62, 0xF2, 0x7D, 0x48, 0x89, 0xC1],
                          "vpexpandd %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xFD, 0x48, 0x89, 0x40, 0x08],
                          "vpexpandq 0x40(%rax), %zmm0", length: 7)
        assertInstruction([0x62, 0xF2, 0x7D, 0x49, 0x89, 0x40, 0x10],
                          "vpexpandd 0x40(%rax), %zmm0 {%k1}", length: 7)
        assertInstruction([0x62, 0xF2, 0x7D, 0x48, 0x88, 0xC1],
                          "vexpandps %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xFD, 0x48, 0x88, 0x40, 0x08],
                          "vexpandpd 0x40(%rax), %zmm0", length: 7)
    }

    func testCompressUsesStoreOperandOrderAndTuple1ScalarDisp8() {
        assertInstruction([0x62, 0xF2, 0x7D, 0x48, 0x8B, 0xC1],
                          "vpcompressd %zmm0, %zmm1", length: 6)
        assertInstruction([0x62, 0xF2, 0xFD, 0x4A, 0x8B, 0x40, 0x08],
                          "vpcompressq %zmm0, 0x40(%rax) {%k2}", length: 7)
        assertInstruction([0x62, 0xF2, 0x7D, 0x48, 0x8A, 0x40, 0x10],
                          "vcompressps %zmm0, 0x40(%rax)", length: 7)
        assertInstruction([0x62, 0xF2, 0xFD, 0x48, 0x8A, 0xC1],
                          "vcompresspd %zmm0, %zmm1", length: 6)
    }

    func testPermi2AndPermt2RenderDestAsThirdOperand() {
        assertInstruction([0x62, 0xF2, 0x75, 0x48, 0x76, 0xC2],
                          "vpermi2d %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xF5, 0x48, 0x76, 0xC2],
                          "vpermi2q %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0x75, 0x48, 0x77, 0xC2],
                          "vpermi2ps %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xF5, 0x48, 0x77, 0xC2],
                          "vpermi2pd %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xF5, 0x48, 0x75, 0xC2],
                          "vpermi2w %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0x75, 0x48, 0x7E, 0xC2],
                          "vpermt2d %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xF5, 0x48, 0x7E, 0xC2],
                          "vpermt2q %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0x75, 0x48, 0x7F, 0xC2],
                          "vpermt2ps %zmm2, %zmm1, %zmm0", length: 6)
        assertInstruction([0x62, 0xF2, 0xF5, 0x48, 0x7F, 0xC2],
                          "vpermt2pd %zmm2, %zmm1, %zmm0", length: 6)
    }

    func testKMovOpmaskRegisterAndMemoryDirections() {
        assertInstruction([0xC5, 0xF8, 0x90, 0xD1],
                          "kmovw %k1, %k2", length: 4)
        assertInstruction([0xC5, 0xF8, 0x90, 0x48, 0x40],
                          "kmovw 0x40(%rax), %k1", length: 5)
        assertInstruction([0xC5, 0xF8, 0x91, 0x48, 0x40],
                          "kmovw %k1, 0x40(%rax)", length: 5)
        assertInstruction([0xC5, 0xF9, 0x90, 0xD1],
                          "kmovb %k1, %k2", length: 4)
    }

    func testKMovAllGPWidthsAndDirections() {
        assertInstruction([0xC5, 0xF8, 0x92, 0xC8],
                          "kmovw %eax, %k1", length: 4)
        assertInstruction([0xC5, 0xF8, 0x93, 0xC1],
                          "kmovw %k1, %eax", length: 4)
        assertInstruction([0xC5, 0xF9, 0x92, 0xC8],
                          "kmovb %eax, %k1", length: 4)
        assertInstruction([0xC5, 0xFB, 0x92, 0xC8],
                          "kmovd %eax, %k1", length: 4)
        assertInstruction([0xC5, 0xFB, 0x93, 0xC1],
                          "kmovd %k1, %eax", length: 4)
        assertInstruction([0xC4, 0xE1, 0xFB, 0x92, 0xC8],
                          "kmovq %rax, %k1", length: 5)
        assertInstruction([0xC4, 0xE1, 0xFB, 0x93, 0xC1],
                          "kmovq %k1, %rax", length: 5)
    }

    func testDataMoveStreamStaysSynchronizedAfterNewForms() {
        let stream: [UInt8] = [
            0x62, 0xF2, 0x7D, 0x49, 0x89, 0x40, 0x10,
            0x62, 0xF2, 0xFD, 0x4A, 0x8B, 0x40, 0x08,
            0x62, 0xF2, 0x75, 0x48, 0x76, 0xC2,
            0xC5, 0xFB, 0x93, 0xC1,
            0xC3,
        ]
        let rows = decoder.decode(Data(stream), baseAddress: 0x1000, maxInstructionCount: 8)
        XCTAssertEqual(rows.map(\.mnemonic), ["vpexpandd", "vpcompressq", "vpermi2d", "kmovd", "ret"])
        XCTAssertEqual(rows.map { $0.bytes.count }, [7, 7, 6, 4, 1])
        XCTAssertEqual(rows.last?.address, 0x1018)
    }

    // vpermi2/t2 d/q/ps/pd support a broadcast memory source; kmov width honors the REX.W bit for the
    // none (w/q) and 66 (b/d) prefixes — not just the F2 (d/q) prefix.
    func testPermuteBroadcastAndKMovWidths() {
        assertInstruction([0x62, 0xF2, 0x75, 0x58, 0x76, 0x40, 0x10],
                          "vpermi2d 0x40(%rax){1to16}, %zmm1, %zmm0", length: 7)
        assertInstruction([0x62, 0xF2, 0x75, 0x58, 0x7E, 0x40, 0x10],
                          "vpermt2d 0x40(%rax){1to16}, %zmm1, %zmm0", length: 7)
        assertInstruction([0xC4, 0xE1, 0xF9, 0x90, 0x48, 0x40], "kmovd 0x40(%rax), %k1", length: 6)  // 66 W1
        assertInstruction([0xC4, 0xE1, 0xF8, 0x91, 0x53, 0x08], "kmovq %k2, 0x8(%rbx)", length: 6)    // none W1
    }

    // compress with a REGISTER destination may zero-mask ({z} is valid); compress to memory + {z} is
    // illegal. The mask/z must render on the destination (r/m) for the store direction.
    func testCompressRegisterZeroMasking() {
        assertInstruction([0x62, 0xF2, 0x7D, 0xCB, 0x8A, 0xC1], "vcompressps %zmm0, %zmm1 {%k3} {z}", length: 6)
        assertInstruction([0x62, 0xF2, 0xFD, 0xCB, 0x8B, 0xC1], "vpcompressq %zmm0, %zmm1 {%k3} {z}", length: 6)
        assertInstruction([0x62, 0x22, 0x7D, 0xCA, 0x8B, 0xF9], "vpcompressd %zmm31, %zmm17 {%k2} {z}", length: 6)
        assertInstruction([0x62, 0xF2, 0x7D, 0x4B, 0x8B, 0xC1], "vpcompressd %zmm0, %zmm1 {%k3}", length: 6) // no z, control
    }
}
