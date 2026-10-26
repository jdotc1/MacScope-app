import Foundation
import XCTest
@testable import MacScope

final class X86EVEXDataMoveAssemblerTests: XCTestCase {
    private let assembler = X86_64Assembler()

    private func assertEncodes(_ text: String, _ expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTAssertEqual(bytes, expected, "encoding mismatch for '\(text)'", file: file, line: line)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
        }
    }

    private func assertFails(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTFail("expected '\(text)' to fail but got bytes \(bytes)", file: file, line: line)
        case .failure:
            break
        }
    }

    func testIntegerMoveWAndPrefixTable() {
        assertEncodes("vmovdqa32 %zmm1, %zmm0", [0x62, 0xf1, 0x7d, 0x48, 0x6f, 0xc1])
        assertEncodes("vmovdqa64 %zmm1, %zmm0", [0x62, 0xf1, 0xfd, 0x48, 0x6f, 0xc1])
        assertEncodes("vmovdqu8 %zmm1, %zmm0", [0x62, 0xf1, 0x7f, 0x48, 0x6f, 0xc1])
        assertEncodes("vmovdqu16 %zmm1, %zmm0", [0x62, 0xf1, 0xff, 0x48, 0x6f, 0xc1])
        assertEncodes("vmovdqu32 %zmm1, %zmm0", [0x62, 0xf1, 0x7e, 0x48, 0x6f, 0xc1])
        assertEncodes("vmovdqu64 %zmm1, %zmm0", [0x62, 0xf1, 0xfe, 0x48, 0x6f, 0xc1])
    }

    func testMovesUseDestinationMasksAndFullTupleDisp8() {
        assertEncodes("vmovdqa64 %zmm0, 0x40(%rdi)", [0x62, 0xf1, 0xfd, 0x48, 0x7f, 0x47, 0x01])
        assertEncodes("vmovdqu8 0x40(%rdi), %zmm0 {%k3}", [0x62, 0xf1, 0x7f, 0x4b, 0x6f, 0x47, 0x01])
        assertEncodes("vmovdqu64 %xmm1, %xmm0 {%k2} {z}", [0x62, 0xf1, 0xfe, 0x8a, 0x6f, 0xc1])
        assertEncodes("vmovapd %zmm1, %zmm0 {%k1} {z}", [0x62, 0xf1, 0xfd, 0xc9, 0x28, 0xc1])
        assertEncodes("vmovupd %zmm0, (%rdi) {%k4}", [0x62, 0xf1, 0xfd, 0x4c, 0x11, 0x07])
        assertFails("vmovupd %zmm0, (%rdi) {%k4} {z}")
    }

    func testBroadcastTupleScalesAndSources() {
        assertEncodes("vpbroadcastd 0x40(%rdi), %zmm1", [0x62, 0xf2, 0x7d, 0x48, 0x58, 0x4f, 0x10])
        assertEncodes("vpbroadcastw 0x40(%rdi), %zmm1", [0x62, 0xf2, 0x7d, 0x48, 0x79, 0x4f, 0x20])
        assertEncodes("vbroadcastsd 0x40(%rdi), %zmm1", [0x62, 0xf2, 0xfd, 0x48, 0x19, 0x4f, 0x08])
        assertEncodes("vpbroadcastq %rax, %zmm1", [0x62, 0xf2, 0xfd, 0x48, 0x7c, 0xc8])
        assertEncodes("vpbroadcastb %r8d, %zmm1", [0x62, 0xd2, 0x7d, 0x48, 0x7a, 0xc8])
        assertEncodes("vbroadcasti32x4 0x40(%rdi), %zmm0", [0x62, 0xf2, 0x7d, 0x48, 0x5a, 0x47, 0x04])
        assertEncodes("vbroadcastf64x4 0x40(%rdi), %zmm0", [0x62, 0xf2, 0xfd, 0x48, 0x1b, 0x47, 0x02])
    }

    func testHighRegistersAndVEXSelection() {
        assertEncodes("vmovdqa64 %zmm30, %zmm16", [0x62, 0x81, 0xfd, 0x48, 0x6f, 0xc6])
        assertEncodes("vpbroadcastd %xmm16, %zmm17", [0x62, 0xa2, 0x7d, 0x48, 0x58, 0xc8])
        assertEncodes("vmovaps %zmm31, %zmm20 {%k5}", [0x62, 0x81, 0x7c, 0x4d, 0x28, 0xe7])
        assertEncodes("vmovaps %xmm1, %xmm0", [0xc5, 0xf8, 0x28, 0xc1])
        assertEncodes("vmovaps %xmm1, %xmm0 {%k1}", [0x62, 0xf1, 0x7c, 0x09, 0x28, 0xc1])
        assertEncodes("vpbroadcastd %xmm0, %ymm1", [0xc4, 0xe2, 0x7d, 0x58, 0xc8])
        assertEncodes("vpbroadcastd %xmm0, %zmm1", [0x62, 0xf2, 0x7d, 0x48, 0x58, 0xc8])
    }
}
