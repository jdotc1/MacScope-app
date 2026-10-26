import Foundation
import XCTest
@testable import MacScope

final class ARM64SIMDPairwiseAssemblerTests: XCTestCase {
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

    func testVectorPairwiseThreeSameEncodings() {
        assertEncodes("addp v0.8b, v1.8b, v2.8b", 0x0e22_bc20)
        assertEncodes("addp v0.4s, v1.4s, v2.4s", 0x4ea2_bc20)
        assertEncodes("addp v0.2d, v1.2d, v2.2d", 0x4ee2_bc20)

        assertEncodes("smaxp v0.4h, v1.4h, v2.4h", 0x0e62_a420)
        assertEncodes("sminp v0.4s, v1.4s, v2.4s", 0x4ea2_ac20)
        assertEncodes("umaxp v0.16b, v1.16b, v2.16b", 0x6e22_a420)
        assertEncodes("uminp v0.8h, v1.8h, v2.8h", 0x6e62_ac20)

        assertEncodes("faddp v0.2s, v1.2s, v2.2s", 0x2e22_d420)
        assertEncodes("faddp v0.4s, v1.4s, v2.4s", 0x6e22_d420)
        assertEncodes("fmaxnmp v0.2d, v1.2d, v2.2d", 0x6e62_c420)
        assertEncodes("fminnmp v0.4s, v1.4s, v2.4s", 0x6ea2_c420)
        assertEncodes("fmaxp v0.4s, v1.4s, v2.4s", 0x6e22_f420)
        assertEncodes("fminp v0.2s, v1.2s, v2.2s", 0x2ea2_f420)
        assertEncodes("faddp v0.4h, v1.4h, v2.4h", 0x2e42_1420)
        assertEncodes("fminp v0.8h, v1.8h, v2.8h", 0x6ec2_3420)
    }

    func testLongPairwiseTwoRegMiscEncodings() {
        assertEncodes("saddlp v0.4h, v1.8b", 0x0e20_2820)
        assertEncodes("saddlp v0.1d, v1.2s", 0x0ea0_2820)
        assertEncodes("uaddlp v0.8h, v1.16b", 0x6e20_2820)
        assertEncodes("sadalp v0.4h, v1.8b", 0x0e20_6820)
        assertEncodes("uadalp v0.2d, v1.4s", 0x6ea0_6820)
        assertEncodes("saddlp v16.8h, v17.16b", 0x4e20_2a30)
    }

    func testScalarPairwiseEncodings() {
        assertEncodes("addp d0, v1.2d", 0x5ef1_b820)
        assertEncodes("faddp h0, v1.2h", 0x5e30_d820)
        assertEncodes("faddp s0, v1.2s", 0x7e30_d820)
        assertEncodes("faddp d0, v1.2d", 0x7e70_d820)
        assertEncodes("fmaxp s0, v1.2s", 0x7e30_f820)
        assertEncodes("fminp d0, v1.2d", 0x7ef0_f820)
        assertEncodes("fmaxnmp d0, v1.2d", 0x7e70_c820)
    }

    func testIllegalPairwiseArrangementsFail() {
        assertFails("smaxp v0.2d, v1.2d, v2.2d", contains: "does not support .2d")
        assertFails("faddp v0.2h, v1.2h, v2.2h", contains: "does not support .2h")
        assertFails("faddp v0.4s, v1.2s, v2.4s", contains: "matching vector arrangements")
        assertFails("saddlp v0.4s, v1.8b", contains: "requires destination .4h")
        assertFails("saddlp v0.2d, v1.2d", contains: "does not support .2d")
        assertFails("addp s0, v1.2s", contains: "d-register")
        assertFails("faddp s0, v1.4s", contains: "source .2s")
    }
}
