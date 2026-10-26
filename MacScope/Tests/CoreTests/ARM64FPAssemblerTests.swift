import Foundation
import XCTest
@testable import MacScope

final class ARM64FPAssemblerTests: XCTestCase {
    private let assembler = ARM64Assembler()

    private func assertEncodes(_ text: String, _ expectedWord: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        let expectedBytes = [
            UInt8(expectedWord & 0xff),
            UInt8((expectedWord >> 8) & 0xff),
            UInt8((expectedWord >> 16) & 0xff),
            UInt8((expectedWord >> 24) & 0xff),
        ]
        switch assembler.assemble(text) {
        case .success(let bytes):
            XCTAssertEqual(bytes, expectedBytes, "encoding mismatch for '\(text)'", file: file, line: line)
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
        }
    }

    private func assertFails(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        if case .success(let bytes) = assembler.assemble(text) {
            XCTFail("expected '\(text)' to fail but got bytes \(bytes)", file: file, line: line)
        }
    }

    func testScalarFloatingPointCorpusEncodings() {
        let cases: [(String, UInt32)] = [
            ("fmov s0, s1", 0x1e20_4020),
            ("fmov d0, d1", 0x1e60_4020),
            ("fmov s0, #1.0", 0x1e2e_1000),
            ("fmov d0, #2.0", 0x1e60_1000),
            ("fmov d5, #-0.5", 0x1e7c_1005),
            ("fmov w0, s0", 0x1e26_0000),
            ("fmov s0, w1", 0x1e27_0020),
            ("fmov x0, d0", 0x9e66_0000),
            ("fmov d0, x1", 0x9e67_0020),

            ("fadd s0, s1, s2", 0x1e22_2820),
            ("fadd d0, d1, d2", 0x1e62_2820),
            ("fsub s3, s4, s5", 0x1e25_3883),
            ("fsub d3, d4, d5", 0x1e65_3883),
            ("fmul s0, s1, s2", 0x1e22_0820),
            ("fmul d0, d1, d2", 0x1e62_0820),
            ("fdiv s0, s1, s2", 0x1e22_1820),
            ("fdiv d7, d8, d9", 0x1e69_1907),
            ("fnmul s0, s1, s2", 0x1e22_8820),

            ("fabs s0, s1", 0x1e20_c020),
            ("fabs d0, d1", 0x1e60_c020),
            ("fneg s2, s3", 0x1e21_4062),
            ("fneg d2, d3", 0x1e61_4062),
            ("fsqrt s0, s1", 0x1e21_c020),
            ("fsqrt d10, d11", 0x1e61_c16a),

            ("fmadd s0, s1, s2, s3", 0x1f02_0c20),
            ("fmadd d0, d1, d2, d3", 0x1f42_0c20),
            ("fmsub s4, s5, s6, s7", 0x1f06_9ca4),
            ("fnmadd d0, d1, d2, d3", 0x1f62_0c20),
            ("fnmsub s0, s1, s2, s3", 0x1f22_8c20),

            ("fmax s0, s1, s2", 0x1e22_4820),
            ("fmin d0, d1, d2", 0x1e62_5820),
            ("fmaxnm s3, s4, s5", 0x1e25_6883),
            ("fminnm d3, d4, d5", 0x1e65_7883),

            ("fcmp s0, s1", 0x1e21_2000),
            ("fcmp d0, d1", 0x1e61_2000),
            ("fcmp s0, #0.0", 0x1e20_2008),
            ("fcmpe d0, d1", 0x1e61_2010),

            ("fcvt d0, s1", 0x1e22_c020),
            ("fcvt s0, d1", 0x1e62_4020),
            ("fcvt s0, h1", 0x1ee2_4020),
            ("fcvt d0, h1", 0x1ee2_c020),

            ("scvtf s0, w1", 0x1e22_0020),
            ("scvtf d0, x1", 0x9e62_0020),
            ("ucvtf s0, w1", 0x1e23_0020),
            ("fcvtzs w0, s1", 0x1e38_0020),
            ("fcvtzs x0, d1", 0x9e78_0020),
            ("fcvtzu w0, s1", 0x1e39_0020),

            ("frinta s0, s1", 0x1e26_4020),
            ("frintn d0, d1", 0x1e64_4020),
            ("frintp s2, s3", 0x1e24_c062),
            ("frintm d2, d3", 0x1e65_4062),
            ("frintz s0, s1", 0x1e25_c020),
            ("frintx d0, d1", 0x1e67_4020),
            ("frinti s0, s1", 0x1e27_c020),

            ("fcsel s0, s1, s2, eq", 0x1e22_0c20),
            ("fcsel d0, d1, d2, ne", 0x1e62_1c20),
        ]

        for (text, word) in cases {
            assertEncodes(text, word)
        }
    }

    func testScalarFloatingPointFailureCases() {
        assertFails("fadd s0, d1, s2")
        assertFails("fmadd s0, s1, s2, d3")
        assertFails("fcsel s0, s1, d2, eq")
        assertFails("fcsel s0, s1, s2, zz")
        assertFails("fcvt s0, s1")
        assertFails("fcmp s0, #1.0")
        assertFails("fmov s0, #0.0")
        assertFails("fmov d0, w1")
        assertFails("scvtf s0, s1")
        assertFails("fcvtzs s0, w1")
    }

    func testIntegerEncodingAnchorsRemainUnchanged() {
        assertEncodes("sub sp, sp, #0x20", 0xd100_83ff)
        assertEncodes("nop", 0xd503_201f)
        assertEncodes("ret", 0xd65f_03c0)
        assertEncodes("mov x0, #0", 0xd280_0000)
        assertEncodes("movk x0, #1", 0xf280_0020)
    }
}
