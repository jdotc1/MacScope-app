import Foundation
import XCTest
@testable import MacScope

final class ARM64SIMDLongWideningAssemblerTests: XCTestCase {
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
            XCTAssertEqual(actual.count, 4, "encoding length mismatch for '\(text)'", file: file, line: line)
            XCTAssertEqual(actual, bytes(expectedWord), "encoding mismatch for '\(text)'", file: file, line: line)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
        }
    }

    private func assembledWord(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> UInt32? {
        switch assembler.assemble(text) {
        case .success(let actual):
            XCTAssertEqual(actual.count, 4, "encoding length mismatch for '\(text)'", file: file, line: line)
            guard actual.count == 4 else { return nil }
            return UInt32(actual[0])
                | (UInt32(actual[1]) << 8)
                | (UInt32(actual[2]) << 16)
                | (UInt32(actual[3]) << 24)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
            return nil
        }
    }

    private func assertQBitPair(_ base: String, _ high: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let baseWord = assembledWord(base, file: file, line: line),
              let highWord = assembledWord(high, file: file, line: line) else {
            return
        }
        XCTAssertEqual(highWord ^ baseWord, 0x4000_0000, "`2` form should only set Q for '\(base)'", file: file, line: line)
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

    func testAddSubLongAndWideEncodings() {
        assertEncodes("saddl v0.8h, v1.8b, v2.8b", 0x0e22_0020)
        assertEncodes("uaddl v0.8h, v1.8b, v2.8b", 0x2e22_0020)
        assertEncodes("ssubl v0.4s, v1.4h, v2.4h", 0x0e62_2020)
        assertEncodes("usubl v0.2d, v1.2s, v2.2s", 0x2ea2_2020)

        assertEncodes("saddw v0.8h, v1.8h, v2.8b", 0x0e22_1020)
        assertEncodes("uaddw v0.4s, v1.4s, v2.4h", 0x2e62_1020)
        assertEncodes("ssubw v0.2d, v1.2d, v2.2s", 0x0ea2_3020)
        assertEncodes("usubw2 v0.4s, v1.4s, v2.8h", 0x6e62_3020)
    }

    func testAbsoluteDifferenceLongEncodings() {
        assertEncodes("sabdl v0.8h, v1.8b, v2.8b", 0x0e22_7020)
        assertEncodes("uabdl v0.4s, v1.4h, v2.4h", 0x2e62_7020)
        assertEncodes("sabal v0.2d, v1.2s, v2.2s", 0x0ea2_5020)
        assertEncodes("uabal v0.8h, v1.8b, v2.8b", 0x2e22_5020)
    }

    func testVectorMultiplyLongAndAccumulateEncodings() {
        assertEncodes("smull v0.8h, v1.8b, v2.8b", 0x0e22_c020)
        assertEncodes("umull v0.4s, v1.4h, v2.4h", 0x2e62_c020)
        assertEncodes("smlal v0.8h, v1.8b, v2.8b", 0x0e22_8020)
        assertEncodes("umlal v0.4s, v1.4h, v2.4h", 0x2e62_8020)
        assertEncodes("smlsl v0.2d, v1.2s, v2.2s", 0x0ea2_a020)
        assertEncodes("umlsl v0.8h, v1.8b, v2.8b", 0x2e22_a020)
    }

    func testSaturatingDoublingAndPolynomialEncodings() {
        assertEncodes("sqdmull v0.4s, v1.4h, v2.4h", 0x0e62_d020)
        assertEncodes("sqdmlal v0.4s, v1.4h, v2.4h", 0x0e62_9020)
        assertEncodes("sqdmlsl v0.2d, v1.2s, v2.2s", 0x0ea2_b020)
        assertEncodes("pmull v0.8h, v1.8b, v2.8b", 0x0e22_e020)
    }

    func testTwoVariantsSetOnlyQBitAndUseHighHalfSources() {
        assertEncodes("saddl2 v0.8h, v1.16b, v2.16b", 0x4e22_0020)
        assertEncodes("uaddl2 v0.4s, v1.8h, v2.8h", 0x6e62_0020)
        assertEncodes("ssubl2 v0.2d, v1.4s, v2.4s", 0x4ea2_2020)
        assertEncodes("saddw2 v0.8h, v1.8h, v2.16b", 0x4e22_1020)
        assertEncodes("sabdl2 v0.4s, v1.8h, v2.8h", 0x4e62_7020)
        assertEncodes("sabal2 v0.8h, v1.16b, v2.16b", 0x4e22_5020)
        assertEncodes("smull2 v0.2d, v1.4s, v2.4s", 0x4ea2_c020)
        assertEncodes("smlal2 v0.4s, v1.8h, v2.8h", 0x4e62_8020)
        assertEncodes("sqdmull2 v0.2d, v1.4s, v2.4s", 0x4ea2_d020)
        assertEncodes("sqdmlal2 v0.4s, v1.8h, v2.8h", 0x4e62_9020)
        assertEncodes("pmull2 v0.8h, v1.16b, v2.16b", 0x4e22_e020)

        assertQBitPair("saddl v0.8h, v1.8b, v2.8b", "saddl2 v0.8h, v1.16b, v2.16b")
        assertQBitPair("saddw v0.8h, v1.8h, v2.8b", "saddw2 v0.8h, v1.8h, v2.16b")
        assertQBitPair("smull v0.8h, v1.8b, v2.8b", "smull2 v0.8h, v1.16b, v2.16b")
        assertQBitPair("pmull v0.8h, v1.8b, v2.8b", "pmull2 v0.8h, v1.16b, v2.16b")
    }

    func testVectorVersusByElementDispatch() {
        assertEncodes("smull v0.8h, v1.8b, v2.8b", 0x0e22_c020)
        assertEncodes("smull v0.4s, v1.4h, v2.h[1]", 0x0f52_a020)

        assertEncodes("umlal2 v0.2d, v1.4s, v2.s[1]", 0x6fa2_2020)
        assertEncodes("smlsl v0.4s, v1.4h, v2.h[3]", 0x0f72_6020)
        assertEncodes("sqdmlal v0.4s, v1.4h, v2.h[1]", 0x0f52_3020)
        assertEncodes("sqdmlsl2 v0.4s, v1.8h, v2.h[5]", 0x4f52_7820)
    }

    func testIllegalArrangementPairingsFail() {
        assertFails("saddl v0.8h, v1.16b, v2.16b", contains: "requires Vn.8b")
        assertFails("saddl2 v0.8h, v1.8b, v2.8b", contains: "requires Vn.16b")
        assertFails("saddl v0.4h, v1.8b, v2.8b", contains: "destination must be .8h")
        assertFails("saddw v0.8h, v1.8b, v2.8b", contains: "requires Vn.8h")
        assertFails("uaddw2 v0.4s, v1.4s, v2.4h", contains: "requires Vm.8h")
        // dst=.4s and Vn=.2d are both valid-but-mismatched wide arrangements; the assembler
        // anchors on Vn and reports the destination must match it. Still a correct rejection.
        assertFails("ssubw v0.4s, v1.2d, v2.2s", contains: "destination must be .2d")

        assertFails("sqdmull v0.8h, v1.8b, v2.8b", contains: "supports .h or .s")
        assertFails("sqdmlal2 v0.4s, v1.4h, v2.4h", contains: "requires Vn.8h")
        assertFails("pmull v0.4s, v1.4h, v2.4h", contains: "supports only .b")
        assertFails("pmull2 v0.8h, v1.8b, v2.8b", contains: "requires Vn.16b")
    }

    func testExistingByElementAndNarrowingPathsRemainUnchanged() {
        assertEncodes("sqdmull v0.4s, v1.4h, v2.h[2]", 0x0f62_b020)
        assertEncodes("smlal v0.4s, v1.4h, v2.h[0]", 0x0f42_2020)
        assertEncodes("umlsl v0.2d, v1.2s, v2.s[1]", 0x2fa2_6020)

        assertEncodes("xtn v0.8b, v1.8h", 0x0e21_2820)
        assertEncodes("shrn v0.8b, v1.8h, #3", 0x0f0d_8420)
    }
}
