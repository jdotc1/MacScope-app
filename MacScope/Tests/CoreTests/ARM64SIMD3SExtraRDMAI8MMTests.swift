import Foundation
import XCTest
@testable import MacScope

final class ARM64SIMD3SExtraRDMAI8MMTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    private func mnemonic(_ word: UInt32) -> String {
        String(text(word).split(separator: " ")[0])
    }

    func testI8MMVectorThreeSameExtra() {
        XCTAssertEqual(text(0x0e829c20), "usdot v0.2s, v1.8b, v2.8b")
        XCTAssertEqual(text(0x4e829c20), "usdot v0.4s, v1.16b, v2.16b")
        XCTAssertEqual(text(0x4e9f9fff), "usdot v31.4s, v31.16b, v31.16b")
        XCTAssertEqual(text(0x4e82a420), "smmla v0.4s, v1.16b, v2.16b")
        XCTAssertEqual(text(0x4e9fa7ff), "smmla v31.4s, v31.16b, v31.16b")
        XCTAssertEqual(text(0x6e82a420), "ummla v0.4s, v1.16b, v2.16b")
        XCTAssertEqual(text(0x6e9fa7ff), "ummla v31.4s, v31.16b, v31.16b")
        XCTAssertEqual(text(0x4e82ac20), "usmmla v0.4s, v1.16b, v2.16b")
        XCTAssertEqual(text(0x4e9fafff), "usmmla v31.4s, v31.16b, v31.16b")
    }

    func testI8MMVectorByElement() {
        XCTAssertEqual(text(0x0f82f020), "usdot v0.2s, v1.8b, v2.4b[0]")
        XCTAssertEqual(text(0x4fa2f820), "usdot v0.4s, v1.16b, v2.4b[3]")
        XCTAssertEqual(text(0x4faff820), "usdot v0.4s, v1.16b, v15.4b[3]")
        XCTAssertEqual(text(0x4fbff820), "usdot v0.4s, v1.16b, v31.4b[3]")
        XCTAssertEqual(text(0x0f02f020), "sudot v0.2s, v1.8b, v2.4b[0]")
        XCTAssertEqual(text(0x4f22f820), "sudot v0.4s, v1.16b, v2.4b[3]")
        XCTAssertEqual(text(0x4f3ff820), "sudot v0.4s, v1.16b, v31.4b[3]")
    }

    func testRDMAVectorThreeSameExtra() {
        XCTAssertEqual(text(0x2e428420), "sqrdmlah v0.4h, v1.4h, v2.4h")
        XCTAssertEqual(text(0x6e428420), "sqrdmlah v0.8h, v1.8h, v2.8h")
        XCTAssertEqual(text(0x2e828420), "sqrdmlah v0.2s, v1.2s, v2.2s")
        XCTAssertEqual(text(0x6e828420), "sqrdmlah v0.4s, v1.4s, v2.4s")
        XCTAssertEqual(text(0x6e9f87ff), "sqrdmlah v31.4s, v31.4s, v31.4s")
        XCTAssertEqual(text(0x2e428c20), "sqrdmlsh v0.4h, v1.4h, v2.4h")
        XCTAssertEqual(text(0x6e428c20), "sqrdmlsh v0.8h, v1.8h, v2.8h")
        XCTAssertEqual(text(0x2e828c20), "sqrdmlsh v0.2s, v1.2s, v2.2s")
        XCTAssertEqual(text(0x6e828c20), "sqrdmlsh v0.4s, v1.4s, v2.4s")
    }

    func testRDMAVectorByElement() {
        XCTAssertEqual(text(0x2f42d020), "sqrdmlah v0.4h, v1.4h, v2.h[0]")
        XCTAssertEqual(text(0x6f72d820), "sqrdmlah v0.8h, v1.8h, v2.h[7]")
        XCTAssertEqual(text(0x2f82d020), "sqrdmlah v0.2s, v1.2s, v2.s[0]")
        XCTAssertEqual(text(0x6fa2d820), "sqrdmlah v0.4s, v1.4s, v2.s[3]")
        XCTAssertEqual(text(0x6f7fd820), "sqrdmlah v0.8h, v1.8h, v15.h[7]")
        XCTAssertEqual(text(0x6fbfd820), "sqrdmlah v0.4s, v1.4s, v31.s[3]")
        XCTAssertEqual(text(0x2f42f020), "sqrdmlsh v0.4h, v1.4h, v2.h[0]")
        XCTAssertEqual(text(0x6f72f820), "sqrdmlsh v0.8h, v1.8h, v2.h[7]")
        XCTAssertEqual(text(0x2f82f020), "sqrdmlsh v0.2s, v1.2s, v2.s[0]")
        XCTAssertEqual(text(0x6fa2f820), "sqrdmlsh v0.4s, v1.4s, v2.s[3]")
    }

    func testRDMAScalarThreeSameExtra() {
        XCTAssertEqual(text(0x7e428420), "sqrdmlah h0, h1, h2")
        XCTAssertEqual(text(0x7e5f87ff), "sqrdmlah h31, h31, h31")
        XCTAssertEqual(text(0x7e828420), "sqrdmlah s0, s1, s2")
        XCTAssertEqual(text(0x7e9f87ff), "sqrdmlah s31, s31, s31")
        XCTAssertEqual(text(0x7e428c20), "sqrdmlsh h0, h1, h2")
        XCTAssertEqual(text(0x7e828c20), "sqrdmlsh s0, s1, s2")
    }

    func testRDMAScalarByElement() {
        XCTAssertEqual(text(0x7f42d020), "sqrdmlah h0, h1, v2.h[0]")
        XCTAssertEqual(text(0x7f7fd820), "sqrdmlah h0, h1, v15.h[7]")
        XCTAssertEqual(text(0x7f82d020), "sqrdmlah s0, s1, v2.s[0]")
        XCTAssertEqual(text(0x7fbfd820), "sqrdmlah s0, s1, v31.s[3]")
        XCTAssertEqual(text(0x7f42f020), "sqrdmlsh h0, h1, v2.h[0]")
        XCTAssertEqual(text(0x7fa2f820), "sqrdmlsh s0, s1, v2.s[3]")
    }

    func testReservedSlotsAreUnknown() {
        XCTAssertEqual(mnemonic(0x0e029c20), "unknown")
        XCTAssertEqual(mnemonic(0x0ec29c20), "unknown")
        XCTAssertEqual(mnemonic(0x0e82a420), "unknown")
        XCTAssertEqual(mnemonic(0x4e42a420), "unknown")
        XCTAssertEqual(mnemonic(0x0e82ac20), "unknown")
        XCTAssertEqual(mnemonic(0x6e42a420), "unknown")
        XCTAssertEqual(mnemonic(0x6e028420), "unknown")
        XCTAssertEqual(mnemonic(0x6ec28420), "unknown")
        XCTAssertEqual(mnemonic(0x6e028c20), "unknown")
        XCTAssertEqual(mnemonic(0x4e82b420), "unknown")
        XCTAssertEqual(mnemonic(0x4e82bc20), "unknown")
        XCTAssertEqual(mnemonic(0x6e82ac20), "unknown")
        XCTAssertEqual(mnemonic(0x7e028420), "unknown")
        XCTAssertEqual(mnemonic(0x7ec28420), "unknown")
        XCTAssertEqual(mnemonic(0x5e428420), "unknown")
        XCTAssertEqual(mnemonic(0x7f02d020), "unknown")
        XCTAssertEqual(mnemonic(0x7fc2d020), "unknown")
    }
}
