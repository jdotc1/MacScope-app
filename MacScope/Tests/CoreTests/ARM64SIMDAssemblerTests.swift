import Foundation
import XCTest
@testable import MacScope

final class ARM64SIMDAssemblerTests: XCTestCase {
    private let assembler = ARM64Assembler()

    private func expectedBytes(_ word: UInt32) -> [UInt8] {
        [
            UInt8(word & 0xff),
            UInt8((word >> 8) & 0xff),
            UInt8((word >> 16) & 0xff),
            UInt8((word >> 24) & 0xff),
        ]
    }

    private func assertEncodes(_ text: String, _ expectedWord: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTAssertEqual(bytes, expectedBytes(expectedWord), "encoding mismatch for '\(text)'", file: file, line: line)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
        }
    }

    private func assertFails(_ text: String, contains expected: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTFail("expected '\(text)' to fail but got bytes \(bytes)", file: file, line: line)
        case .failure(let diagnostic):
            if let expected {
                XCTAssertTrue(
                    diagnostic.description.contains(expected),
                    "expected diagnostic containing '\(expected)' for '\(text)', got '\(diagnostic)'",
                    file: file,
                    line: line
                )
            }
        }
    }

    func testSIMDArithmeticAndRegisterRangeEncodings() {
        assertEncodes("add v0.8b, v1.8b, v2.8b", 0x0e22_8420)
        assertEncodes("add v0.2d, v1.2d, v2.2d", 0x4ee2_8420)
        assertEncodes("sub v3.16b, v4.16b, v5.16b", 0x6e25_8483)
        assertEncodes("sub v3.2d, v4.2d, v5.2d", 0x6ee5_8483)
        assertEncodes("mul v0.8b, v1.8b, v2.8b", 0x0e22_9c20)
        assertEncodes("mul v0.4s, v1.4s, v2.4s", 0x4ea2_9c20)
        assertEncodes("add v31.4s, v30.4s, v29.4s", 0x4ebd_87df)
        assertEncodes("mul v16.8h, v17.8h, v18.8h", 0x4e72_9e30)
    }

    func testSIMDLogicalByteArrangementEncodings() {
        assertEncodes("and v0.8b, v1.8b, v2.8b", 0x0e22_1c20)
        assertEncodes("and v0.16b, v1.16b, v2.16b", 0x4e22_1c20)
        assertEncodes("orr v0.16b, v1.16b, v2.16b", 0x4ea2_1c20)
        assertEncodes("eor v0.16b, v1.16b, v2.16b", 0x6e22_1c20)
        assertEncodes("bic v0.16b, v1.16b, v2.16b", 0x4e62_1c20)
        assertEncodes("orn v0.16b, v1.16b, v2.16b", 0x4ee2_1c20)
    }

    func testSIMDCompareAndMinMaxEncodings() {
        assertEncodes("cmeq v0.16b, v1.16b, v2.16b", 0x6e22_8c20)
        assertEncodes("cmeq v0.2d, v1.2d, v2.2d", 0x6ee2_8c20)
        assertEncodes("cmgt v0.4s, v1.4s, v2.4s", 0x4ea2_3420)
        assertEncodes("cmge v0.8h, v1.8h, v2.8h", 0x4e62_3c20)
        assertEncodes("cmhi v0.16b, v1.16b, v2.16b", 0x6e22_3420)
        assertEncodes("cmhs v0.2s, v1.2s, v2.2s", 0x2ea2_3c20)
        assertEncodes("smax v0.16b, v1.16b, v2.16b", 0x4e22_6420)
        assertEncodes("smin v0.8h, v1.8h, v2.8h", 0x4e62_6c20)
        assertEncodes("umax v0.4s, v1.4s, v2.4s", 0x6ea2_6420)
        assertEncodes("umin v0.16b, v1.16b, v2.16b", 0x6e22_6c20)
    }

    func testSIMDPairwiseSaturatingShiftAndAccumulateEncodings() {
        assertEncodes("addp v0.4s, v1.4s, v2.4s", 0x4ea2_bc20)
        assertEncodes("addp v0.2d, v1.2d, v2.2d", 0x4ee2_bc20)
        assertEncodes("sqadd v0.16b, v1.16b, v2.16b", 0x4e22_0c20)
        assertEncodes("uqadd v0.4s, v1.4s, v2.4s", 0x6ea2_0c20)
        assertEncodes("sqsub v0.8h, v1.8h, v2.8h", 0x4e62_2c20)
        assertEncodes("sshl v0.4s, v1.4s, v2.4s", 0x4ea2_4420)
        assertEncodes("ushl v0.2d, v1.2d, v2.2d", 0x6ee2_4420)
        assertEncodes("mla v0.4s, v1.4s, v2.4s", 0x4ea2_9420)
        assertEncodes("mls v0.8h, v1.8h, v2.8h", 0x6e62_9420)
    }

    func testSIMDIllegalArrangementsFailWithDiagnostics() {
        assertFails("add v0.3s, v1.3s, v2.3s", contains: "unsupported vector arrangement")
        assertFails("add v0.8b, v1.16b, v2.8b", contains: "matching vector arrangements")
        assertFails("mul v0.2d, v1.2d, v2.2d", contains: "does not support .2d")
        assertFails("mla v0.2d, v1.2d, v2.2d", contains: "does not support .2d")
        assertFails("smax v0.2d, v1.2d, v2.2d", contains: "does not support .2d")
        assertFails("and v0.4h, v1.4h, v2.4h", contains: "does not support .4h")
        assertFails("orr v0.1d, v1.1d, v2.1d", contains: "unsupported vector arrangement")
    }

    func testExistingIntegerAndScalarFPEncodingsRemainUnchanged() {
        assertEncodes("sub sp, sp, #0x20", 0xd100_83ff)
        assertEncodes("nop", 0xd503_201f)
        assertEncodes("ret", 0xd65f_03c0)
        assertEncodes("mov x0, #0", 0xd280_0000)
        assertEncodes("movk x0, #1", 0xf280_0020)

        assertEncodes("fmov s0, s1", 0x1e20_4020)
        assertEncodes("fadd s0, s1, s2", 0x1e22_2820)
        assertEncodes("fmadd d0, d1, d2, d3", 0x1f42_0c20)
        assertEncodes("fcvt d0, s1", 0x1e22_c020)
        assertEncodes("fcsel s0, s1, s2, eq", 0x1e22_0c20)
    }
}
