import Foundation
import XCTest
@testable import MacScope

final class ARM64SIMDLoadStoreStructureAssemblerTests: XCTestCase {
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

    func testMultipleStructureLoadStoreEncodings() {
        assertEncodes("ld1 {v0.8b}, [x0]", 0x0c40_7000)
        assertEncodes("ld1 {v0.16b}, [x0]", 0x4c40_7000)
        assertEncodes("ld1 {v0.8b, v1.8b}, [x0]", 0x0c40_a000)
        assertEncodes("ld1 {v0.4h, v1.4h, v2.4h}, [x0]", 0x0c40_6400)
        assertEncodes("ld1 {v0.2s, v1.2s, v2.2s, v3.2s}, [x0]", 0x0c40_2800)
        assertEncodes("ld1 {v0.1d}, [x0]", 0x0c40_7c00)
        assertEncodes("ld2 {v0.8b, v1.8b}, [x0]", 0x0c40_8000)
        assertEncodes("ld2 {v0.4s, v1.4s}, [x0]", 0x4c40_8800)
        assertEncodes("ld3 {v0.4h, v1.4h, v2.4h}, [x0]", 0x0c40_4400)
        assertEncodes("ld4 {v0.2s, v1.2s, v2.2s, v3.2s}, [x0]", 0x0c40_0800)

        assertEncodes("st1 {v0.16b}, [x0]", 0x4c00_7000)
        assertEncodes("st1 {v0.8b, v1.8b}, [x0]", 0x0c00_a000)
        assertEncodes("st2 {v0.8h, v1.8h}, [x0]", 0x4c00_8400)
        assertEncodes("st3 {v0.2s, v1.2s, v2.2s}, [x0]", 0x0c00_4800)
        assertEncodes("st4 {v0.2d, v1.2d, v2.2d, v3.2d}, [x0]", 0x4c00_0c00)
    }

    func testRangeSyntaxAndWrapping() {
        assertEncodes("ld1 {v0.16b-v3.16b}, [x0]", 0x4c40_2000)
        assertEncodes("ld4 {v4.4s-v7.4s}, [x0]", 0x4c40_0804)
        assertEncodes("ld4 {v30.8b-v1.8b}, [x0]", 0x0c40_001e)
        assertEncodes("ld4 {v30.b-v1.b}[7], [x0]", 0x0d60_3c1e)
    }

    func testPostIndexImmediateAndRegisterForms() {
        assertEncodes("ld1 {v0.8b}, [x0], #8", 0x0cdf_7000)
        assertEncodes("ld1 {v0.16b}, [x0], #16", 0x4cdf_7000)
        assertEncodes("ld2 {v0.8b, v1.8b}, [x0], #16", 0x0cdf_8000)
        assertEncodes("ld1 {v0.8b, v1.8b}, [x0], x1", 0x0cc1_a000)
        assertEncodes("st1 {v0.16b}, [x0], #16", 0x4c9f_7000)
        assertEncodes("ld4 {v0.2s, v1.2s, v2.2s, v3.2s}, [x0], x2", 0x0cc2_0800)
    }

    func testSingleLaneFormsAtEachElementSize() {
        assertEncodes("ld1 {v0.b}[3], [x0]", 0x0d40_0c00)
        assertEncodes("ld1 {v0.h}[2], [x0]", 0x0d40_5000)
        assertEncodes("ld1 {v0.s}[1], [x0]", 0x0d40_9000)
        assertEncodes("ld1 {v0.d}[0], [x0]", 0x0d40_8400)
        assertEncodes("st1 {v0.s}[3], [x0]", 0x4d00_9000)
        assertEncodes("ld2 {v0.h, v1.h}[4], [x0]", 0x4d60_4000)
        assertEncodes("ld3 {v0.s, v1.s, v2.s}[1], [x0]", 0x0d40_b000)
        assertEncodes("ld4 {v0.b, v1.b, v2.b, v3.b}[7], [x0]", 0x0d60_3c00)
        assertEncodes("ld1 {v0.b}[3], [x0], #1", 0x0ddf_0c00)
        assertEncodes("st1 {v0.d}[1], [x0], x1", 0x4d81_8400)
    }

    func testReplicateLoadEncodings() {
        assertEncodes("ld1r {v0.8b}, [x0]", 0x0d40_c000)
        assertEncodes("ld1r {v0.4s}, [x0]", 0x4d40_c800)
        assertEncodes("ld1r {v0.2d}, [x0]", 0x4d40_cc00)
        assertEncodes("ld2r {v0.8b, v1.8b}, [x0]", 0x0d60_c000)
        assertEncodes("ld3r {v0.4h, v1.4h, v2.4h}, [x0]", 0x0d40_e400)
        assertEncodes("ld4r {v0.2s, v1.2s, v2.2s, v3.2s}, [x0]", 0x0d60_e800)
        assertEncodes("ld1r {v0.4s}, [x0], #4", 0x4ddf_c800)
        assertEncodes("ld2r {v0.1d, v1.1d}, [x0]", 0x0d60_cc00)
    }

    func testIllegalFormsFailWithDiagnostics() {
        assertFails("ld2 {v0.1d, v1.1d}, [x0]", contains: ".1d")
        assertFails("ld2 {v0.8b}, [x0]", contains: "exactly 2")
        assertFails("ld3 {v0.8b, v1.8b}, [x0]", contains: "exactly 3")
        assertFails("ld1 {v0.8b, v2.8b}, [x0]", contains: "consecutive")
        assertFails("ld1 {v0.b}[16], [x0]", contains: "0..15")
        assertFails("ld1 {v0.d}[2], [x0]", contains: "0..1")
        assertFails("ld1 {v0.8b}, [x0], #4", contains: "#8")
        assertFails("ld1 {v0.b}[3], [x0], #2", contains: "#1")
        assertFails("ld1 {v0.8b}, [x0], xzr", contains: "X0-X30")
        assertFails("ld1r {v0.8b, v1.8b}, [x0]", contains: "exactly 1")
        assertFails("ld1 {v0.2h}, [x0]", contains: "unsupported")
    }

    func testExistingSIMDTableAndScalarPathsRemainUnchanged() {
        assertEncodes("tbl v0.8b, {v1.16b}, v2.8b", 0x0e02_0020)
        assertEncodes("tbl v0.16b, {v1.16b, v2.16b}, v3.16b", 0x4e03_2020)
        assertEncodes("tbx v0.8b, {v1.16b, v2.16b, v3.16b}, v4.8b", 0x0e04_5020)
        assertEncodes("add v0.8b, v1.8b, v2.8b", 0x0e22_8420)
        assertEncodes("sub sp, sp, #0x20", 0xd100_83ff)
        assertEncodes("ldr x0, [x1, #8]", 0xf940_0420)
    }
}
