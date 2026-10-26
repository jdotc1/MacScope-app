import Foundation
import XCTest
@testable import MacScope

final class ARM64SIMDPermuteTableAssemblerTests: XCTestCase {
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
            XCTAssertEqual(actual.count, 4, "ARM64 instructions must encode to exactly 4 bytes", file: file, line: line)
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

    func testZipUzpTrnEncodingsAtByteWidths() {
        assertEncodes("zip1 v0.8b, v1.8b, v2.8b", 0x0e02_3820)
        assertEncodes("zip1 v0.16b, v1.16b, v2.16b", 0x4e02_3820)
        assertEncodes("uzp1 v0.8b, v1.8b, v2.8b", 0x0e02_1820)
        assertEncodes("uzp2 v0.16b, v1.16b, v2.16b", 0x4e02_5820)
        assertEncodes("trn1 v0.8b, v1.8b, v2.8b", 0x0e02_2820)
        assertEncodes("trn2 v0.16b, v1.16b, v2.16b", 0x4e02_6820)
    }

    func testPermuteDoubleAndHighRegisterEncodings() {
        assertEncodes("zip2 v0.2d, v1.2d, v2.2d", 0x4ec2_7820)
        assertEncodes("uzp2 v0.2d, v1.2d, v2.2d", 0x4ec2_5820)
        assertEncodes("trn2 v0.2d, v1.2d, v2.2d", 0x4ec2_6820)
        assertEncodes("zip2 v31.2d, v30.2d, v29.2d", 0x4edd_7bdf)
    }

    func testExtEncodingsAndBoundaries() {
        assertEncodes("ext v0.8b, v1.8b, v2.8b, #0", 0x2e02_0020)
        assertEncodes("ext v0.8b, v1.8b, v2.8b, #7", 0x2e02_3820)
        assertEncodes("ext v0.16b, v1.16b, v2.16b, #0", 0x6e02_0020)
        assertEncodes("ext v0.16b, v1.16b, v2.16b, #15", 0x6e02_7820)
        assertEncodes("ext v16.16b, v17.16b, v18.16b, #5", 0x6e12_2a30)
    }

    func testTableLookupEncodingsAndWrap() {
        assertEncodes("tbl v0.8b, {v1.16b}, v2.8b", 0x0e02_0020)
        assertEncodes("tbl v0.16b, {v1.16b, v2.16b}, v3.16b", 0x4e03_2020)
        assertEncodes("tbl v0.8b, {v1.16b, v2.16b, v3.16b}, v4.8b", 0x0e04_4020)
        assertEncodes("tbl v0.16b, {v1.16b, v2.16b, v3.16b, v4.16b}, v5.16b", 0x4e05_6020)
        assertEncodes("tbx v0.8b, {v1.16b}, v2.8b", 0x0e02_1020)
        assertEncodes("tbx v0.16b, {v1.16b, v2.16b}, v3.16b", 0x4e03_3020)
        assertEncodes("tbx v0.8b, {v1.16b, v2.16b, v3.16b}, v4.8b", 0x0e04_5020)
        assertEncodes("tbx v0.16b, {v1.16b, v2.16b, v3.16b, v4.16b}, v5.16b", 0x4e05_7020)
        assertEncodes("tbl v0.16b, {v31.16b, v0.16b}, v1.16b", 0x4e01_23e0)
        assertEncodes("tbx v16.8b, {v30.16b, v31.16b, v0.16b}, v17.8b", 0x0e11_53d0)
    }

    func testIllegalFormsFailWithDiagnostics() {
        assertFails("zip1 v0.1d, v1.1d, v2.1d", contains: "does not support .1d")
        assertFails("ext v0.8b, v1.8b, v2.8b, #8", contains: "0..7")
        assertFails("ext v0.16b, v1.16b, v2.16b, #16", contains: "0..15")
        assertFails("ext v0.4h, v1.4h, v2.4h, #1", contains: "supports only .8b or .16b")
        assertFails("tbl v0.8b, {}, v2.8b", contains: "1..4")
        assertFails("tbl v0.8b, {v1.16b, v2.16b, v3.16b, v4.16b, v5.16b}, v6.8b", contains: "1..4")
        assertFails("tbl v0.8b, {v1.8b}, v2.8b", contains: "table registers must be .16b")
        assertFails("tbl v0.8b, {v1.16b, v3.16b}, v2.8b", contains: "consecutive")
        assertFails("tbx v0.4h, {v1.16b}, v2.4h", contains: "supports only .8b or .16b")
    }

    func testExistingPathsRemainUnchanged() {
        assertEncodes("add v0.8b, v1.8b, v2.8b", 0x0e22_8420)
        assertEncodes("mul v0.4s, v1.4s, v2.4s", 0x4ea2_9c20)
        assertEncodes("shl v0.8b, v1.8b, #7", 0x0f0f_5420)
        assertEncodes("sub sp, sp, #0x20", 0xd100_83ff)
        assertEncodes("ldr x0, [x1, #8]", 0xf940_0420)
    }
}
