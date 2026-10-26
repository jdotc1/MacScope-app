import Foundation
import XCTest
@testable import MacScope

final class ARM64ReservedEncodingRegressionTests: XCTestCase {
    private func decode1(_ word: UInt32) -> (mnemonic: String, operands: String) {
        var bytes = Data()
        withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) }
        let row = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return (row.mnemonic, row.operands)
    }

    func testRejectConditionalCompareReservedBits() {
        // CCMP W0, W1/#1, #0, EQ: bit11 selects the immediate form.
        for word: UInt32 in [0x7a41_0000, 0x7a41_0800] {
            XCTAssertEqual(decode1(word).mnemonic, "ccmp")
        }
        for word: UInt32 in [
            0x7a41_0010, // Reserved bit4 set in the register form.
            0x7a41_0400, // Reserved bit10 set in the register form.
        ] {
            XCTAssertEqual(decode1(word).mnemonic, "unknown", String(format: "0x%08x", word))
        }
    }

    func testConditionalCompareAllowsALAndNV() {
        // cond is bits15:12; bit30 selects CCMP (1) or CCMN (0).
        for condition: UInt32 in [0xe, 0xf] {
            for form: UInt32 in [0, 0x800] {
                XCTAssertEqual(decode1(0x7a41_0000 | condition << 12 | form).mnemonic, "ccmp")
                XCTAssertEqual(decode1(0x3a41_0000 | condition << 12 | form).mnemonic, "ccmn")
            }
        }
    }

    func testBitfieldValidBoundaryRendering() {
        // Encoding = sf<<31 | opc<<29 | 0x13000000 | N<<22
        //          | immr<<16 | imms<<10 | Rn<<5 | Rd.
        let cases: [(word: UInt32, mnemonic: String, operands: String)] = [
            // sf=0, opc=2, N=0, immr=0, imms=0, Rn=0, Rd=2.
            (0x5300_0002, "ubfx", "w2, w0, #0, #1"),
            // sf=1, opc=2, N=1, immr=0, imms=0, Rn=0, Rd=2.
            (0xd340_0002, "ubfx", "x2, x0, #0, #1"),
            // sf=0, opc=2, N=0, immr=31, imms=31, Rn=0, Rd=2.
            (0x531f_7c02, "lsr", "w2, w0, #31"),
            // sf=1, opc=2, N=1, immr=32, imms=0, Rn=0, Rd=2.
            (0xd360_0002, "ubfiz", "x2, x0, #32, #1"),
            // sf=1, opc=2, N=1, immr=0, imms=32, Rn=0, Rd=2.
            (0xd340_8002, "ubfx", "x2, x0, #0, #33"),
        ]
        for item in cases {
            let row = decode1(item.word)
            let message = String(format: "0x%08x", item.word)
            XCTAssertEqual(row.mnemonic, item.mnemonic, message)
            XCTAssertEqual(row.operands, item.operands, message)
        }
    }

    func testRejectBitfieldReservedWidthFields() {
        // Same field layout as the valid boundary cases above.
        let words: [UInt32] = [
            0x5340_0002, // sf=0, opc=2, N=1, immr=0, imms=0, Rn=0, Rd=2.
            0xd300_0002, // sf=1, opc=2, N=0, immr=0, imms=0, Rn=0, Rd=2.
            0x5320_0002, // sf=0, opc=2, N=0, immr=32, imms=0, Rn=0, Rd=2.
            0x5300_8002, // sf=0, opc=2, N=0, immr=0, imms=32, Rn=0, Rd=2.
        ]
        for word in words {
            XCTAssertEqual(decode1(word).mnemonic, "unknown", String(format: "0x%08x", word))
        }
    }
}
