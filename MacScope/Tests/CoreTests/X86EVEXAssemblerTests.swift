import Foundation
import XCTest
@testable import MacScope

final class X86EVEXAssemblerTests: XCTestCase {
    private let assembler = X86_64Assembler()

    private func assertEncodes(_ text: String, _ expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTAssertEqual(bytes, expected, "encoding mismatch for '\(text)'", file: file, line: line)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
        }
    }

    func testZMMPackedFPAndIntegerUseEVEX() {
        assertEncodes("vaddps %zmm2, %zmm1, %zmm0", [0x62, 0xf1, 0x74, 0x48, 0x58, 0xc2])
        assertEncodes("vaddpd %zmm2, %zmm1, %zmm0", [0x62, 0xf1, 0xf5, 0x48, 0x58, 0xc2])
        assertEncodes("vpaddd %zmm2, %zmm1, %zmm0", [0x62, 0xf1, 0x75, 0x48, 0xfe, 0xc2])
        assertEncodes("vpandd %zmm2, %zmm1, %zmm0", [0x62, 0xf1, 0x75, 0x48, 0xdb, 0xc2])
        assertEncodes("vpmulld %zmm2, %zmm1, %zmm0", [0x62, 0xf2, 0x75, 0x48, 0x40, 0xc2])
    }

    func testMaskAndZeroingDecorateDestination() {
        assertEncodes("vaddps %zmm2, %zmm1, %zmm0 {%k1}", [0x62, 0xf1, 0x74, 0x49, 0x58, 0xc2])
        assertEncodes("vaddpd %zmm2, %zmm1, %zmm0 {%k3}", [0x62, 0xf1, 0xf5, 0x4b, 0x58, 0xc2])
        assertEncodes("vpaddd %zmm2, %zmm1, %zmm0 {%k1} {z}", [0x62, 0xf1, 0x75, 0xc9, 0xfe, 0xc2])
        assertEncodes("vmulps %zmm2, %zmm1, %zmm0 {%k7} {z}", [0x62, 0xf1, 0x74, 0xcf, 0x59, 0xc2])
    }

    func testBroadcastMemorySetsBAndElementScale() {
        assertEncodes("vaddps (%rdi){1to16}, %zmm1, %zmm0", [0x62, 0xf1, 0x74, 0x58, 0x58, 0x07])
        assertEncodes("vaddpd (%rdi){1to8}, %zmm1, %zmm0", [0x62, 0xf1, 0xf5, 0x58, 0x58, 0x07])
        assertEncodes("vpaddd (%rdi){1to16}, %zmm1, %zmm0 {%k2}", [0x62, 0xf1, 0x75, 0x5a, 0xfe, 0x07])
    }

    func testMaskedXMMAndYMMFormsUseEVEXVL() {
        assertEncodes("vaddps %xmm2, %xmm1, %xmm0 {%k1}", [0x62, 0xf1, 0x74, 0x09, 0x58, 0xc2])
        assertEncodes("vaddpd %ymm2, %ymm1, %ymm0 {%k1}", [0x62, 0xf1, 0xf5, 0x29, 0x58, 0xc2])
        assertEncodes("vpaddd %ymm2, %ymm1, %ymm0 {%k2} {z}", [0x62, 0xf1, 0x75, 0xaa, 0xfe, 0xc2])
    }

    func testHighVectorRegistersUseEVEXPrimeBits() {
        assertEncodes("vaddps %zmm30, %zmm29, %zmm16", [0x62, 0x81, 0x14, 0x40, 0x58, 0xc6])
        assertEncodes("vpaddd %zmm31, %zmm20, %zmm10", [0x62, 0x11, 0x5d, 0x40, 0xfe, 0xd7])
        assertEncodes("vmulps %zmm16, %zmm17, %zmm18 {%k4}", [0x62, 0xa1, 0x74, 0x44, 0x59, 0xd0])
        assertEncodes("vaddpd %zmm25, %zmm26, %zmm27 {%k5} {z}", [0x62, 0x01, 0xad, 0xc5, 0x58, 0xd9])
    }

    func testCompressedDisp8UsesTupleOrBroadcastScale() {
        assertEncodes("vaddps 0x40(%rdi), %zmm1, %zmm0", [0x62, 0xf1, 0x74, 0x48, 0x58, 0x47, 0x01])
        assertEncodes("vmulpd 0x40(%rdi), %zmm1, %zmm0", [0x62, 0xf1, 0xf5, 0x48, 0x59, 0x47, 0x01])
        assertEncodes("vaddps 0x40(%rdi){1to16}, %zmm1, %zmm0", [0x62, 0xf1, 0x74, 0x58, 0x58, 0x47, 0x10])
        assertEncodes("vaddpd 0x40(%rdi){1to8}, %zmm1, %zmm0", [0x62, 0xf1, 0xf5, 0x58, 0x58, 0x47, 0x08])
    }
}
