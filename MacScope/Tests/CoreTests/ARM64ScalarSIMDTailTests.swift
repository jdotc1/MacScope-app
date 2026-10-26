import Foundation
import XCTest
@testable import MacScope

final class ARM64ScalarSIMDTailTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    private func mnemonic(_ word: UInt32) -> String {
        String(text(word).split(separator: " ")[0])
    }

    func testScalarFP16ThreeSame() {
        XCTAssertEqual(text(0x7ec21420), "fabd h0, h1, h2")
        XCTAssertEqual(text(0x7eda1738), "fabd h24, h25, h26")
        XCTAssertEqual(text(0x5e421c20), "fmulx h0, h1, h2")
        XCTAssertEqual(text(0x5e5a1f38), "fmulx h24, h25, h26")
        XCTAssertEqual(text(0x5e453c83), "frecps h3, h4, h5")
        XCTAssertEqual(text(0x5e5a3f38), "frecps h24, h25, h26")
        XCTAssertEqual(text(0x5ec83ce6), "frsqrts h6, h7, h8")
        XCTAssertEqual(text(0x5eda3f38), "frsqrts h24, h25, h26")
        XCTAssertEqual(text(0x5e4b2549), "fcmeq h9, h10, h11")
        XCTAssertEqual(text(0x5e5a2738), "fcmeq h24, h25, h26")
        XCTAssertEqual(text(0x7e4e25ac), "fcmge h12, h13, h14")
        XCTAssertEqual(text(0x7e5a2738), "fcmge h24, h25, h26")
        XCTAssertEqual(text(0x7ed1260f), "fcmgt h15, h16, h17")
        XCTAssertEqual(text(0x7eda2738), "fcmgt h24, h25, h26")
        XCTAssertEqual(text(0x7e542e72), "facge h18, h19, h20")
        XCTAssertEqual(text(0x7e5a2f38), "facge h24, h25, h26")
        XCTAssertEqual(text(0x7ed72ed5), "facgt h21, h22, h23")
        XCTAssertEqual(text(0x7eda2f38), "facgt h24, h25, h26")
    }

    func testScalarFP16ByElement() {
        XCTAssertEqual(text(0x5f021020), "fmla h0, h1, v2.h[0]")
        XCTAssertEqual(text(0x5f3f18c5), "fmla h5, h6, v15.h[7]")
        XCTAssertEqual(text(0x5f325020), "fmls h0, h1, v2.h[3]")
        XCTAssertEqual(text(0x5f3f58c5), "fmls h5, h6, v15.h[7]")
        XCTAssertEqual(text(0x5f139820), "fmul h0, h1, v3.h[5]")
        XCTAssertEqual(text(0x5f3f98c5), "fmul h5, h6, v15.h[7]")
        XCTAssertEqual(text(0x7f249820), "fmulx h0, h1, v4.h[6]")
        XCTAssertEqual(text(0x7f3f98c5), "fmulx h5, h6, v15.h[7]")
    }

    func testScalarLongByElement() {
        XCTAssertEqual(text(0x5f42b020), "sqdmull s0, h1, v2.h[0]")
        XCTAssertEqual(text(0x5f7fb8c5), "sqdmull s5, h6, v15.h[7]")
        XCTAssertEqual(text(0x5f82b020), "sqdmull d0, s1, v2.s[0]")
        XCTAssertEqual(text(0x5fbfb8c5), "sqdmull d5, s6, v31.s[3]")
        XCTAssertEqual(text(0x5f633020), "sqdmlal s0, h1, v3.h[2]")
        XCTAssertEqual(text(0x5fa43020), "sqdmlal d0, s1, v4.s[1]")
        XCTAssertEqual(text(0x5f457820), "sqdmlsl s0, h1, v5.h[4]")
        XCTAssertEqual(text(0x5f867820), "sqdmlsl d0, s1, v6.s[2]")
    }

    func testScalarLongThreeDifferent() {
        XCTAssertEqual(text(0x5e62d020), "sqdmull s0, h1, h2")
        XCTAssertEqual(text(0x5ea2d020), "sqdmull d0, s1, s2")
        XCTAssertEqual(text(0x5e629020), "sqdmlal s0, h1, h2")
        XCTAssertEqual(text(0x5ea29020), "sqdmlal d0, s1, s2")
        XCTAssertEqual(text(0x5e62b020), "sqdmlsl s0, h1, h2")
        XCTAssertEqual(text(0x5ea2b020), "sqdmlsl d0, s1, s2")
    }

    func testReservedSlotsAreUnknown() {
        XCTAssertEqual(mnemonic(0x5e420420), "unknown")  // A unmapped opcode
        XCTAssertEqual(mnemonic(0x5e428420), "unknown")  // A bit15=1
        XCTAssertEqual(mnemonic(0x5f020020), "unknown")  // B/C unmapped size=00 opcode
        XCTAssertEqual(mnemonic(0x5f023020), "unknown")  // C long opcode at size=00
        XCTAssertEqual(mnemonic(0x7f42b020), "unknown")  // C long opcode with U=1
        XCTAssertEqual(mnemonic(0x5fc2b020), "unknown")  // C long opcode at size=11
        XCTAssertEqual(mnemonic(0x5e620020), "unknown")  // D unmapped opcode
        XCTAssertEqual(mnemonic(0x5e229020), "unknown")  // D size=00
        XCTAssertEqual(mnemonic(0x7e629020), "unknown")  // D U=1
    }

    func testNeighborScalarThreeSameStillDecodes() {
        XCTAssertEqual(text(0x5e220c20), "sqadd b0, b1, b2")
        XCTAssertEqual(text(0x5ee28420), "add d0, d1, d2")
    }
}
