import Foundation
import XCTest
@testable import MacScope

final class ARM64SIMDReductionTests: XCTestCase {
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

    func testIntegerAcrossLaneReductionEncodings() {
        assertEncodes("addv b0, v1.8b", 0x0e31_b820)
        assertEncodes("addv b31, v30.16b", 0x4e31_bbdf)
        assertEncodes("addv h0, v1.4h", 0x0e71_b820)
        assertEncodes("addv s0, v1.4s", 0x4eb1_b820)

        assertEncodes("smaxv s0, v31.4s", 0x4eb0_abe0)
        assertEncodes("sminv b0, v1.8b", 0x0e31_a820)
        assertEncodes("umaxv h0, v1.4h", 0x2e70_a820)
        assertEncodes("uminv s0, v1.4s", 0x6eb1_a820)
    }

    func testLongAcrossLaneReductionDestinationIsOneSizeWider() {
        assertEncodes("saddlv h0, v1.8b", 0x0e30_3820)
        assertEncodes("saddlv s0, v1.8h", 0x4e70_3820)
        assertEncodes("saddlv d5, v20.4s", 0x4eb0_3a85)

        assertEncodes("uaddlv h0, v1.16b", 0x6e30_3820)
        assertEncodes("uaddlv s0, v1.4h", 0x2e70_3820)
        assertEncodes("uaddlv d0, v1.4s", 0x6eb0_3820)
    }

    func testFloatingPointAcrossLaneReductionEncodings() {
        assertEncodes("fmaxv h0, v1.4h", 0x0e30_f820)
        assertEncodes("fmaxv h0, v1.8h", 0x4e30_f820)
        assertEncodes("fmaxv s0, v1.4s", 0x6e30_f820)

        assertEncodes("fminv s0, v1.4s", 0x6eb0_f820)
        assertEncodes("fmaxnmv s0, v1.4s", 0x6e30_c820)
        assertEncodes("fminnmv h0, v1.4h", 0x0eb0_c820)
    }

    func testIllegalArrangementsAndDestinationWidthsFail() {
        assertFails("addv d0, v1.4s", contains: "destination must use an s-register")
        assertFails("addv s0, v1.2s", contains: "does not support .2s")
        assertFails("addv b0, v1.2d", contains: "does not support .2d")

        assertFails("saddlv b0, v1.8b", contains: "destination must use an h-register")
        assertFails("saddlv h0, v1.8h", contains: "destination must use an s-register")
        assertFails("uaddlv s0, v1.4s", contains: "destination must use a d-register")

        assertFails("fmaxv s0, v1.4h", contains: "destination must use an h-register")
        assertFails("fmaxv s0, v1.2s", contains: "does not support .2s")
        assertFails("fminnmv d0, v1.2d", contains: "does not support .2d")
    }

    func testExistingIntegerScalarFPThreeSameShiftImmediateAndTwoRegMiscRemainUnchanged() {
        assertEncodes("sub sp, sp, #0x20", 0xd100_83ff)
        assertEncodes("ret", 0xd65f_03c0)
        assertEncodes("mov x0, #0", 0xd280_0000)

        assertEncodes("fadd s0, s1, s2", 0x1e22_2820)
        assertEncodes("fcvt d0, s1", 0x1e22_c020)

        assertEncodes("add v0.8b, v1.8b, v2.8b", 0x0e22_8420)
        assertEncodes("cmgt v0.4s, v1.4s, v2.4s", 0x4ea2_3420)

        assertEncodes("shl v0.16b, v1.16b, #3", 0x4f0b_5420)
        assertEncodes("ushr v0.2d, v1.2d, #64", 0x6f40_0420)

        assertEncodes("cnt v0.16b, v1.16b", 0x4e20_5820)
        assertEncodes("abs v0.8h, v1.8h", 0x4e60_b820)
    }
}
