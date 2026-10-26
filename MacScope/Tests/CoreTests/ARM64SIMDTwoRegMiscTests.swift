import Foundation
import XCTest
@testable import MacScope

final class ARM64SIMDTwoRegMiscTests: XCTestCase {
    private let assembler = ARM64Assembler()

    private func bytes(_ word: UInt32) -> [UInt8] {
        [
            UInt8(word & 0xff),
            UInt8((word >> 8) & 0xff),
            UInt8((word >> 16) & 0xff),
            UInt8((word >> 24) & 0xff),
        ]
    }

    private func assertEncodes(_ text: String, _ expectedWord: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let actual):
            XCTAssertEqual(actual, bytes(expectedWord), "encoding mismatch for '\(text)'", file: file, line: line)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
        }
    }

    private func assertFails(_ text: String, contains expected: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        switch assembler.assemble(text) {
        case .success(let actual):
            XCTFail("expected '\(text)' to fail but got bytes \(actual)", file: file, line: line)
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

    func testAbsNegAllIntegerArrangementEncodings() {
        assertEncodes("abs v0.8b, v1.8b", 0x0e20_b820)
        assertEncodes("abs v0.16b, v1.16b", 0x4e20_b820)
        assertEncodes("abs v0.4h, v1.4h", 0x0e60_b820)
        assertEncodes("abs v0.2s, v1.2s", 0x0ea0_b820)
        assertEncodes("abs v0.2d, v1.2d", 0x4ee0_b820)
        assertEncodes("neg v0.16b, v1.16b", 0x6e20_b820)
        assertEncodes("neg v0.4s, v1.4s", 0x6ea0_b820)
        assertEncodes("neg v0.2d, v1.2d", 0x6ee0_b820)
        assertEncodes("abs v31.4s, v30.4s", 0x4ea0_bbdf)
        assertEncodes("neg v16.8h, v17.8h", 0x6e60_ba30)
    }

    func testByteUnaryAndReverseEncodings() {
        assertEncodes("not v0.8b, v1.8b", 0x2e20_5820)
        assertEncodes("not v0.16b, v1.16b", 0x6e20_5820)
        assertEncodes("mvn v0.16b, v1.16b", 0x6e20_5820)
        assertEncodes("cnt v0.8b, v1.8b", 0x0e20_5820)
        assertEncodes("cnt v0.16b, v1.16b", 0x4e20_5820)
        assertEncodes("rbit v0.16b, v1.16b", 0x6e60_5820)

        assertEncodes("rev16 v0.16b, v1.16b", 0x4e20_1820)
        assertEncodes("rev32 v0.8b, v1.8b", 0x2e20_0820)
        assertEncodes("rev32 v0.4h, v1.4h", 0x2e60_0820)
        assertEncodes("rev64 v0.16b, v1.16b", 0x4e20_0820)
        assertEncodes("rev64 v0.8h, v1.8h", 0x4e60_0820)
        assertEncodes("rev64 v0.4s, v1.4s", 0x4ea0_0820)
    }

    func testCountLeadingAndCompareZeroEncodings() {
        assertEncodes("cls v0.16b, v1.16b", 0x4e20_4820)
        assertEncodes("cls v0.8h, v1.8h", 0x4e60_4820)
        assertEncodes("clz v0.4s, v1.4s", 0x6ea0_4820)

        assertEncodes("cmeq v0.16b, v1.16b, #0", 0x4e20_9820)
        assertEncodes("cmge v0.4s, v1.4s, #0", 0x6ea0_8820)
        assertEncodes("cmgt v0.8h, v1.8h, #0", 0x4e60_8820)
        assertEncodes("cmle v0.2d, v1.2d, #0", 0x6ee0_9820)
        assertEncodes("cmlt v0.16b, v1.16b, #0", 0x4e20_a820)
        assertEncodes("cmeq v29.2d, v28.2d, #0", 0x4ee0_9b9d)
    }

    func testSaturatingUnaryAndAccumulateEncodings() {
        assertEncodes("sqabs v0.8h, v1.8h", 0x4e60_7820)
        assertEncodes("sqneg v0.4s, v1.4s", 0x6ea0_7820)
        assertEncodes("sqabs v0.2d, v1.2d", 0x4ee0_7820)
        assertEncodes("suqadd v0.16b, v1.16b", 0x4e20_3820)
        assertEncodes("usqadd v0.4s, v1.4s", 0x6ea0_3820)
    }

    func testIllegalArrangementsAndCompareZeroDiagnostics() {
        assertFails("not v0.4h, v1.4h", contains: "does not support .4h")
        assertFails("cnt v0.4s, v1.4s", contains: "does not support .4s")
        assertFails("rbit v0.4h, v1.4h", contains: "does not support .4h")
        assertFails("rev16 v0.4h, v1.4h", contains: "does not support .4h")
        assertFails("rev32 v0.2s, v1.2s", contains: "does not support .2s")
        assertFails("rev64 v0.2d, v1.2d", contains: "does not support .2d")
        assertFails("clz v0.2d, v1.2d", contains: "does not support .2d")
        assertFails("abs v0.1d, v1.1d", contains: "unsupported vector arrangement")
        assertFails("cmeq v0.16b, v1.8b, #0", contains: "matching vector arrangements")
        assertFails("cmle v0.16b, v1.16b", contains: "Vd.<T>, Vn.<T>, #0")
        assertFails("cmlt v0.16b, v1.16b, #1", contains: "only accepts #0")
    }

    func testExistingIntegerScalarFPThreeSameAndShiftImmediateEncodingsRemainUnchanged() {
        assertEncodes("sub sp, sp, #0x20", 0xd100_83ff)
        assertEncodes("nop", 0xd503_201f)
        assertEncodes("ret", 0xd65f_03c0)
        assertEncodes("mov x0, #0", 0xd280_0000)
        assertEncodes("neg x0, x1", 0xcb01_03e0)
        assertEncodes("negs x2, x3, lsl #3", 0xeb03_0fe2)
        assertEncodes("mvn x0, x1", 0xaa21_03e0)

        assertEncodes("fmov s0, s1", 0x1e20_4020)
        assertEncodes("fadd s0, s1, s2", 0x1e22_2820)
        assertEncodes("fmadd d0, d1, d2, d3", 0x1f42_0c20)
        assertEncodes("fcvt d0, s1", 0x1e22_c020)

        assertEncodes("cmeq v0.16b, v1.16b, v2.16b", 0x6e22_8c20)
        assertEncodes("cmgt v0.4s, v1.4s, v2.4s", 0x4ea2_3420)
        assertEncodes("cmge v0.8h, v1.8h, v2.8h", 0x4e62_3c20)
        assertEncodes("add v0.8b, v1.8b, v2.8b", 0x0e22_8420)

        assertEncodes("shl v0.16b, v1.16b, #3", 0x4f0b_5420)
        assertEncodes("ushr v0.2d, v1.2d, #64", 0x6f40_0420)
    }
}
