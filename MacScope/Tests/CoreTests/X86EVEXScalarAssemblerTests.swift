import Foundation
import XCTest
@testable import MacScope

final class X86EVEXScalarAssemblerTests: XCTestCase {
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

    func testScalarMasksAndZeroingForceEVEX() {
        assertEncodes("vaddss %xmm2, %xmm1, %xmm0 {%k1}", [0x62, 0xf1, 0x76, 0x09, 0x58, 0xc2])
        assertEncodes("vsubss %xmm2, %xmm1, %xmm0 {%k2} {z}", [0x62, 0xf1, 0x76, 0x8a, 0x5c, 0xc2])
        assertEncodes("vmulsd %xmm2, %xmm1, %xmm0 {%k7} {z}", [0x62, 0xf1, 0xf7, 0x8f, 0x59, 0xc2])
        assertEncodes("vfnmadd213ss %xmm2, %xmm1, %xmm0 {%k1}", [0x62, 0xf2, 0x75, 0x09, 0xad, 0xc2])
    }

    func testEmbeddedRoundingModesUseBBitAndLLControl() {
        assertEncodes("vaddss {rn-sae}, %xmm2, %xmm1, %xmm0", [0x62, 0xf1, 0x76, 0x18, 0x58, 0xc2])
        assertEncodes("vaddsd {rd-sae}, %xmm2, %xmm1, %xmm0", [0x62, 0xf1, 0xf7, 0x38, 0x58, 0xc2])
        assertEncodes("vmulss {ru-sae}, %xmm2, %xmm1, %xmm0", [0x62, 0xf1, 0x76, 0x58, 0x59, 0xc2])
        assertEncodes("vdivsd {rz-sae}, %xmm2, %xmm1, %xmm0", [0x62, 0xf1, 0xf7, 0x78, 0x5e, 0xc2])
        assertEncodes("vaddsd {rn-sae}, %xmm2, %xmm1, %xmm0 {%k1} {z}", [0x62, 0xf1, 0xf7, 0x99, 0x58, 0xc2])
    }

    func testSAEOnlyScalarForms() {
        assertEncodes("vminss {sae}, %xmm2, %xmm1, %xmm0", [0x62, 0xf1, 0x76, 0x18, 0x5d, 0xc2])
        assertEncodes("vmaxsd {sae}, %xmm2, %xmm1, %xmm0", [0x62, 0xf1, 0xf7, 0x18, 0x5f, 0xc2])
        assertEncodes("vcvtss2sd {sae}, %xmm2, %xmm1, %xmm0", [0x62, 0xf1, 0x76, 0x18, 0x5a, 0xc2])
        assertEncodes("vcvtsd2ss {rn-sae}, %xmm2, %xmm1, %xmm0", [0x62, 0xf1, 0xf7, 0x18, 0x5a, 0xc2])
        assertFails("vaddss {sae}, %xmm2, %xmm1, %xmm0")
        assertFails("vminss {rn-sae}, %xmm2, %xmm1, %xmm0")
    }

    func testTuple1ScalarMemoryDisp8DoesNotSetRoundingBBit() {
        assertEncodes("vaddss (%rdi), %xmm1, %xmm0 {%k1}", [0x62, 0xf1, 0x76, 0x09, 0x58, 0x07])
        assertEncodes("vmulsd 0x8(%rdi), %xmm1, %xmm0 {%k2} {z}", [0x62, 0xf1, 0xf7, 0x8a, 0x59, 0x47, 0x01])
        assertFails("vaddss {rn-sae}, (%rdi), %xmm1, %xmm0")
    }

    func testHighXMMRegistersForceEVEX() {
        assertEncodes("vaddss %xmm30, %xmm29, %xmm16 {%k1}", [0x62, 0x81, 0x16, 0x01, 0x58, 0xc6])
        assertEncodes("vmulsd %xmm16, %xmm17, %xmm18 {%k4} {z}", [0x62, 0xa1, 0xf7, 0x84, 0x59, 0xd0])
        assertEncodes("vfmadd213ss {rn-sae}, %xmm31, %xmm30, %xmm29", [0x62, 0x02, 0x0d, 0x10, 0xa9, 0xef])
        assertEncodes("vsqrtsd %xmm20, %xmm21, %xmm22 {%k5}", [0x62, 0xa1, 0xd7, 0x05, 0x51, 0xf4])
    }
}
