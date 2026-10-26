import Foundation
import XCTest
@testable import MacScope

final class ARM64SIMDNarrowingAssemblerTests: XCTestCase {
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

    func testExtractNarrowEncodings() {
        assertEncodes("xtn v0.8b, v1.8h", 0x0e21_2820)
        assertEncodes("xtn v0.4h, v1.4s", 0x0e61_2820)
        assertEncodes("xtn v0.2s, v1.2d", 0x0ea1_2820)
        assertEncodes("xtn2 v0.16b, v1.8h", 0x4e21_2820)
        assertEncodes("xtn2 v0.8h, v1.4s", 0x4e61_2820)
        assertEncodes("xtn2 v0.4s, v1.2d", 0x4ea1_2820)

        assertEncodes("sqxtn v0.4h, v1.4s", 0x0e61_4820)
        assertEncodes("sqxtn2 v0.8h, v1.4s", 0x4e61_4820)
        assertEncodes("uqxtn v0.2s, v1.2d", 0x2ea1_4820)
        assertEncodes("uqxtn2 v0.4s, v1.2d", 0x6ea1_4820)

        assertEncodes("sqxtun v0.8b, v1.8h", 0x2e21_2820)
        assertEncodes("sqxtun2 v0.16b, v1.8h", 0x6e21_2820)
    }

    func testShiftRightNarrowEncodings() {
        assertEncodes("shrn v0.8b, v1.8h, #3", 0x0f0d_8420)
        assertEncodes("shrn2 v0.16b, v1.8h, #3", 0x4f0d_8420)
        assertEncodes("rshrn v0.4h, v1.4s, #8", 0x0f18_8c20)
        assertEncodes("rshrn2 v0.8h, v1.4s, #8", 0x4f18_8c20)

        assertEncodes("sqshrn v0.2s, v1.2d, #16", 0x0f30_9420)
        assertEncodes("sqshrn2 v0.4s, v1.2d, #16", 0x4f30_9420)
        assertEncodes("uqshrn v0.4h, v1.4s, #5", 0x2f1b_9420)
        assertEncodes("uqshrn2 v0.8h, v1.4s, #5", 0x6f1b_9420)

        assertEncodes("sqrshrn v0.8b, v1.8h, #6", 0x0f0a_9c20)
        assertEncodes("sqrshrn2 v0.16b, v1.8h, #6", 0x4f0a_9c20)
        assertEncodes("uqrshrn v0.4h, v1.4s, #7", 0x2f19_9c20)
        assertEncodes("uqrshrn2 v0.8h, v1.4s, #7", 0x6f19_9c20)

        assertEncodes("sqshrun v0.2s, v1.2d, #12", 0x2f34_8420)
        assertEncodes("sqshrun2 v0.4s, v1.2d, #12", 0x6f34_8420)
        assertEncodes("sqrshrun v0.8b, v1.8h, #4", 0x2f0c_8c20)
        assertEncodes("sqrshrun2 v0.16b, v1.8h, #4", 0x6f0c_8c20)
    }

    func testTwoVariantsOnlySetQBit() {
        assertQBitPair("xtn v0.8b, v1.8h", "xtn2 v0.16b, v1.8h")
        assertQBitPair("sqxtun v0.8b, v1.8h", "sqxtun2 v0.16b, v1.8h")
        assertQBitPair("shrn v0.8b, v1.8h, #3", "shrn2 v0.16b, v1.8h, #3")
        assertQBitPair("uqrshrn v0.4h, v1.4s, #7", "uqrshrn2 v0.8h, v1.4s, #7")
    }

    func testHighRegisterEncodings() {
        assertEncodes("sqxtn v31.8b, v30.8h", 0x0e21_4bdf)
        assertEncodes("xtn2 v16.16b, v17.8h", 0x4e21_2a30)
        assertEncodes("uqrshrn2 v31.4s, v30.2d, #31", 0x6f21_9fdf)
    }

    func testIllegalPairingsAndShiftRangesFail() {
        assertFails("xtn v0.8b, v1.4s", contains: "requires Vn.8h")
        assertFails("xtn2 v0.8b, v1.8h", contains: "128-bit destination")
        assertFails("sqxtn v0.8h, v1.4s", contains: "64-bit destination")
        assertFails("uqxtn2 v0.4s, v1.4s", contains: "requires Vn.2d")
        assertFails("sqxtun v0.2s, v1.4s", contains: "requires Vn.2d")

        assertFails("shrn v0.8b, v1.8h, #0", contains: "1..8")
        assertFails("shrn v0.8b, v1.8h, #9", contains: "1..8")
        assertFails("rshrn2 v0.8h, v1.4s, #17", contains: "1..16")
        assertFails("sqshrn v0.2s, v1.2d, #-1", contains: "out of range")
        assertFails("uqrshrn v0.2s, v1.2d, #33", contains: "1..32")
        assertFails("sqshrun2 v0.8b, v1.8h, #3", contains: "128-bit destination")
        assertFails("sqrshrun v0.8b, v1.4s, #3", contains: "requires Vn.8h")
    }

    func testExistingIntegerSIMDPathsRemainUnchanged() {
        assertEncodes("abs v0.8b, v1.8b", 0x0e20_b820)
        assertEncodes("neg v0.16b, v1.16b", 0x6e20_b820)
        assertEncodes("add v0.8b, v1.8b, v2.8b", 0x0e22_8420)
        assertEncodes("sshr v0.8b, v1.8b, #1", 0x0f0f_0420)
        assertEncodes("shl v0.16b, v1.16b, #3", 0x4f0b_5420)
    }
}
