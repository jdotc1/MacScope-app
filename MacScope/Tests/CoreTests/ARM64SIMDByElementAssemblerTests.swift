import Foundation
import XCTest
@testable import MacScope

final class ARM64SIMDByElementAssemblerTests: XCTestCase {
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

    func testCorpusIntegerByElementEncodings() {
        assertEncodes("mul v0.4h, v1.4h, v2.h[0]", 0x0f42_8020)
        assertEncodes("mul v0.8h, v1.8h, v2.h[7]", 0x4f72_8820)
        assertEncodes("mul v0.2s, v1.2s, v2.s[0]", 0x0f82_8020)
        assertEncodes("mul v0.4s, v1.4s, v2.s[3]", 0x4fa2_8820)
        assertEncodes("mla v0.4h, v1.4h, v2.h[1]", 0x2f52_0020)
        assertEncodes("mla v0.4s, v1.4s, v2.s[2]", 0x6f82_0820)
        assertEncodes("mls v0.8h, v1.8h, v2.h[5]", 0x6f52_4820)
        assertEncodes("mls v0.2s, v1.2s, v2.s[1]", 0x2fa2_4020)
        assertEncodes("sqdmulh v0.4h, v1.4h, v2.h[3]", 0x0f72_c020)
        assertEncodes("sqdmulh v0.4s, v1.4s, v2.s[1]", 0x4fa2_c020)
        assertEncodes("sqrdmulh v0.8h, v1.8h, v2.h[0]", 0x4f42_d020)
        assertEncodes("sqrdmulh v0.2s, v1.2s, v2.s[2]", 0x0f82_d820)
    }

    func testCorpusWideningByElementEncodings() {
        assertEncodes("sqdmull v0.4s, v1.4h, v2.h[2]", 0x0f62_b020)
        assertEncodes("sqdmull v0.2d, v1.2s, v2.s[0]", 0x0f82_b020)
        assertEncodes("smull v0.4s, v1.4h, v2.h[1]", 0x0f52_a020)
        assertEncodes("umull v0.2d, v1.2s, v2.s[3]", 0x2fa2_a820)
        assertEncodes("smlal v0.4s, v1.4h, v2.h[0]", 0x0f42_2020)
        assertEncodes("umlsl v0.2d, v1.2s, v2.s[1]", 0x2fa2_6020)
    }

    func testCorpusFloatingPointByElementEncodings() {
        assertEncodes("fmul v0.2s, v1.2s, v2.s[0]", 0x0f82_9020)
        assertEncodes("fmul v0.4s, v1.4s, v2.s[3]", 0x4fa2_9820)
        assertEncodes("fmul v0.2d, v1.2d, v2.d[1]", 0x4fc2_9820)
        assertEncodes("fmla v0.4s, v1.4s, v2.s[2]", 0x4f82_1820)
        assertEncodes("fmls v0.2d, v1.2d, v2.d[0]", 0x4fc2_5020)
        assertEncodes("fmulx v0.4s, v1.4s, v2.s[1]", 0x6fa2_9020)
    }

    func testHighRegistersAndIndexPacking() {
        assertEncodes("mul v31.4s, v30.4s, v15.s[3]", 0x4faf_8bdf)
        assertEncodes("fmla v16.2d, v17.2d, v18.d[1]", 0x4fd2_1a30)
        assertEncodes("mul v0.8h, v1.8h, v15.h[7]", 0x4f7f_8820)
        assertEncodes("mul v0.4s, v1.4s, v31.s[3]", 0x4fbf_8820)
    }

    func testWideningDestinationAndHighHalfEncodings() {
        assertEncodes("smull2 v0.4s, v1.8h, v2.h[1]", 0x4f52_a020)
        assertEncodes("umull2 v0.2d, v1.4s, v31.s[3]", 0x6fbf_a820)
        assertFails("sqdmull v0.2d, v1.4h, v2.h[0]", contains: "destination must be .4s")
        assertFails("smull2 v0.4s, v1.4h, v2.h[0]", contains: "requires Vn.8h")
        assertFails("smull v0.4s, v1.8h, v2.h[0]", contains: "requires Vn.4h")
    }

    func testIllegalIndexedElementFormsFail() {
        assertFails("mul v0.4h, v1.4h, v2.h[8]", contains: "0..7")
        assertFails("mul v0.4s, v1.4s, v2.s[4]", contains: "0..3")
        assertFails("fmul v0.2d, v1.2d, v2.d[2]", contains: "0..1")
        assertFails("mul v0.4h, v1.4h, v16.h[0]", contains: "v0-v15")
        assertFails("mul v0.4s, v1.4s, v2.h[0]", contains: "lane .h")
        assertFails("fmul v0.4h, v1.4h, v2.h[0]", contains: "does not support .4h")
    }

    func testExistingScalarFPAndThreeSamePathsRemainUnchanged() {
        assertEncodes("fmul s0, s1, s2", 0x1e22_0820)
        assertEncodes("mul v0.4s, v1.4s, v2.4s", 0x4ea2_9c20)
        assertEncodes("mla v0.4s, v1.4s, v2.4s", 0x4ea2_9420)
        assertEncodes("mls v0.8h, v1.8h, v2.8h", 0x6e62_9420)
        assertEncodes("sub sp, sp, #0x20", 0xd100_83ff)
        assertEncodes("ldr x0, [x1, #8]", 0xf940_0420)
    }
}
