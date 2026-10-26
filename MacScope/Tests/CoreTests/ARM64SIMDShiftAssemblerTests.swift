import Foundation
import XCTest
@testable import MacScope

final class ARM64SIMDShiftAssemblerTests: XCTestCase {
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

    func testShiftLeftImmediateEncodings() {
        assertEncodes("shl v0.8b, v1.8b, #1", 0x0f09_5420)
        assertEncodes("shl v0.8b, v1.8b, #7", 0x0f0f_5420)
        assertEncodes("shl v0.16b, v1.16b, #3", 0x4f0b_5420)
        assertEncodes("shl v0.8h, v1.8h, #15", 0x4f1f_5420)
        assertEncodes("shl v0.4s, v1.4s, #16", 0x4f30_5420)
        assertEncodes("shl v0.2d, v1.2d, #63", 0x4f7f_5420)
    }

    func testShiftRightImmediateEncodings() {
        assertEncodes("sshr v0.8b, v1.8b, #1", 0x0f0f_0420)
        assertEncodes("sshr v0.16b, v1.16b, #8", 0x4f08_0420)
        assertEncodes("ushr v0.8b, v1.8b, #8", 0x2f08_0420)
        assertEncodes("ushr v0.8h, v1.8h, #16", 0x6f10_0420)
        assertEncodes("sshr v0.4s, v1.4s, #32", 0x4f20_0420)
        assertEncodes("ushr v0.2d, v1.2d, #64", 0x6f40_0420)
    }

    func testRoundingAndAccumulateRightShiftEncodings() {
        assertEncodes("srshr v0.4h, v1.4h, #4", 0x0f1c_2420)
        assertEncodes("urshr v0.4s, v1.4s, #8", 0x6f38_2420)
        assertEncodes("ssra v0.16b, v1.16b, #2", 0x4f0e_1420)
        assertEncodes("usra v0.8h, v1.8h, #5", 0x6f1b_1420)
        assertEncodes("srsra v0.2s, v1.2s, #3", 0x0f3d_3420)
        assertEncodes("ursra v0.2d, v1.2d, #10", 0x6f76_3420)
    }

    func testInsertAndSaturatingShiftEncodings() {
        assertEncodes("sli v0.16b, v1.16b, #4", 0x6f0c_5420)
        assertEncodes("sli v0.2d, v1.2d, #40", 0x6f68_5420)
        assertEncodes("sri v0.8h, v1.8h, #7", 0x6f19_4420)
        assertEncodes("sri v0.4s, v1.4s, #20", 0x6f2c_4420)
        assertEncodes("sqshl v0.8b, v1.8b, #3", 0x0f0b_7420)
        assertEncodes("uqshl v0.4s, v1.4s, #12", 0x6f2c_7420)
        assertEncodes("sqshlu v0.8h, v1.8h, #6", 0x6f16_6420)
    }

    func testHighRegisterAndBoundaryEncodings() {
        assertEncodes("shl v31.4s, v30.4s, #24", 0x4f38_57df)
        assertEncodes("ushr v16.2d, v17.2d, #33", 0x6f5f_0630)
        assertEncodes("sshr v0.16b, v31.16b, #4", 0x4f0c_07e0)
        assertEncodes("shl v0.8b, v1.8b, #0", 0x0f08_5420)
        assertEncodes("sshr v0.8b, v1.8b, #8", 0x0f08_0420)
    }

    func testOutOfRangeAndIllegalFormsFail() {
        assertFails("shl v0.8b, v1.8b, #8", contains: "0..7")
        assertFails("sli v0.2d, v1.2d, #64", contains: "0..63")
        assertFails("sqshl v0.4s, v1.4s, #-1", contains: "out of range")
        assertFails("sshr v0.8b, v1.8b, #0", contains: "1..8")
        assertFails("ushr v0.8b, v1.8b, #9", contains: "1..8")
        assertFails("sri v0.2d, v1.2d, #65", contains: "1..64")
        assertFails("shl v0.8b, v1.16b, #1", contains: "matching vector arrangements")
        assertFails("shl v0.1d, v1.1d, #1", contains: "unsupported vector arrangement")
    }

    func testExistingIntegerScalarFPAndThreeSameEncodingsRemainUnchanged() {
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

        assertEncodes("add v0.8b, v1.8b, v2.8b", 0x0e22_8420)
        assertEncodes("mul v0.4s, v1.4s, v2.4s", 0x4ea2_9c20)
        assertEncodes("sshl v0.4s, v1.4s, v2.4s", 0x4ea2_4420)
    }
}
