import Foundation
import XCTest
@testable import MacScope

final class ARM64SIMDFPConvertAssemblerTests: XCTestCase {
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

    func testSameWidthIntegerFloatConvertEncodings() {
        assertEncodes("scvtf v0.4s, v1.4s", 0x4e21_d820)
        assertEncodes("scvtf v0.2d, v1.2d", 0x4e61_d820)
        assertEncodes("scvtf v0.2s, v1.2s", 0x0e21_d820)
        assertEncodes("ucvtf v0.4s, v1.4s", 0x6e21_d820)
        assertEncodes("ucvtf v0.2d, v1.2d", 0x6e61_d820)
        assertEncodes("fcvtzs v0.4s, v1.4s", 0x4ea1_b820)
        assertEncodes("fcvtzs v0.2d, v1.2d", 0x4ee1_b820)
        assertEncodes("fcvtzu v0.2s, v1.2s", 0x2ea1_b820)
        assertEncodes("fcvtzu v0.4s, v1.4s", 0x6ea1_b820)
    }

    func testExplicitRoundingFloatToIntegerConvertEncodings() {
        assertEncodes("fcvtas v0.4s, v1.4s", 0x4e21_c820)
        assertEncodes("fcvtau v0.2d, v1.2d", 0x6e61_c820)
        assertEncodes("fcvtms v0.2s, v1.2s", 0x0e21_b820)
        assertEncodes("fcvtmu v0.4s, v1.4s", 0x6e21_b820)
        assertEncodes("fcvtns v0.2d, v1.2d", 0x4e61_a820)
        assertEncodes("fcvtnu v0.4s, v1.4s", 0x6e21_a820)
        assertEncodes("fcvtps v0.2d, v1.2d", 0x4ee1_a820)
        assertEncodes("fcvtpu v0.4s, v1.4s", 0x6ea1_a820)
    }

    func testRoundToIntegralFloatEncodings() {
        assertEncodes("frinta v0.4s, v1.4s", 0x6e21_8820)
        assertEncodes("frinti v0.2d, v1.2d", 0x6ee1_9820)
        assertEncodes("frintm v0.2s, v1.2s", 0x0e21_9820)
        assertEncodes("frintn v0.4s, v1.4s", 0x4e21_8820)
        assertEncodes("frintp v0.2d, v1.2d", 0x4ee1_8820)
        assertEncodes("frintx v0.4s, v1.4s", 0x6e21_9820)
        assertEncodes("frintz v0.2d, v1.2d", 0x4ee1_9820)
    }

    func testWidenNarrowAndRoundToOddConvertEncodings() {
        assertEncodes("fcvtl v0.4s, v1.4h", 0x0e21_7820)
        assertEncodes("fcvtl v0.2d, v1.2s", 0x0e61_7820)
        assertEncodes("fcvtl2 v0.4s, v1.8h", 0x4e21_7820)
        assertEncodes("fcvtl2 v0.2d, v1.4s", 0x4e61_7820)

        assertEncodes("fcvtn v0.4h, v1.4s", 0x0e21_6820)
        assertEncodes("fcvtn v0.2s, v1.2d", 0x0e61_6820)
        assertEncodes("fcvtn2 v0.8h, v1.4s", 0x4e21_6820)
        assertEncodes("fcvtn2 v0.4s, v1.2d", 0x4e61_6820)
        assertEncodes("fcvtxn v0.2s, v1.2d", 0x2e61_6820)
        assertEncodes("fcvtxn2 v0.4s, v1.2d", 0x6e61_6820)

        assertEncodes("scvtf v31.4s, v30.4s", 0x4e21_dbdf)
        assertEncodes("fcvtl2 v16.2d, v17.4s", 0x4e61_7a30)
    }

    func testIllegalArrangementsAndPairingsFail() {
        assertFails("scvtf v0.16b, v1.16b", contains: "does not support .16b")
        assertFails("ucvtf v0.8b, v1.8b", contains: "does not support .8b")
        assertFails("frintn v0.16b, v1.16b", contains: "does not support .16b")
        assertFails("fcvtzs v0.1d, v1.1d", contains: "unsupported vector arrangement")
        assertFails("fcvtas v0.2d, v1.4s", contains: "matching vector arrangements")

        assertFails("fcvtl v0.4s, v1.8h", contains: "does not support source .8h")
        assertFails("fcvtl2 v0.4s, v1.4h", contains: "does not support source .4h")
        assertFails("fcvtn v0.8h, v1.4s", contains: "requires destination .4h")
        assertFails("fcvtn2 v0.4h, v1.4s", contains: "requires destination .8h")
        assertFails("fcvtxn v0.4h, v1.4s", contains: "does not support source .4s")
    }

    func testScalarConvertAndRoundRegressionsRemainUnchanged() {
        assertEncodes("scvtf s0, w1", 0x1e22_0020)
        assertEncodes("scvtf d0, x1", 0x9e62_0020)
        assertEncodes("ucvtf s0, w1", 0x1e23_0020)
        assertEncodes("fcvtzs w0, s1", 0x1e38_0020)
        assertEncodes("fcvtzs x0, d1", 0x9e78_0020)
        assertEncodes("fcvtzu w0, s1", 0x1e39_0020)
        assertEncodes("frinta s0, s1", 0x1e26_4020)
        assertEncodes("frintn d0, d1", 0x1e64_4020)
    }
}
