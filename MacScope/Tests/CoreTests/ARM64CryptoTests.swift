import Foundation
import XCTest
@testable import MacScope

final class ARM64CryptoTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    private func mnemonic(_ word: UInt32) -> String {
        String(text(word).split(separator: " ")[0])
    }

    func testSM3SM4Decodes() {
        XCTAssertEqual(text(0xce420c20), "sm3ss1 v0.4s, v1.4s, v2.4s, v3.4s")
        XCTAssertEqual(text(0xce428020), "sm3tt1a v0.4s, v1.4s, v2.s[0]")
        XCTAssertEqual(text(0xce428420), "sm3tt1b v0.4s, v1.4s, v2.s[0]")
        XCTAssertEqual(text(0xce428820), "sm3tt2a v0.4s, v1.4s, v2.s[0]")
        XCTAssertEqual(text(0xce428c20), "sm3tt2b v0.4s, v1.4s, v2.s[0]")
        XCTAssertEqual(text(0xce42b020), "sm3tt1a v0.4s, v1.4s, v2.s[3]")
        XCTAssertEqual(text(0xce5fbfff), "sm3tt2b v31.4s, v31.4s, v31.s[3]")
        XCTAssertEqual(text(0xce62c020), "sm3partw1 v0.4s, v1.4s, v2.4s")
        XCTAssertEqual(text(0xce62c420), "sm3partw2 v0.4s, v1.4s, v2.4s")
        XCTAssertEqual(text(0xce62c820), "sm4ekey v0.4s, v1.4s, v2.4s")
        XCTAssertEqual(text(0xcec08420), "sm4e v0.4s, v1.4s")
        XCTAssertEqual(text(0xcec087ff), "sm4e v31.4s, v31.4s")
    }

    func testReservedCryptoSlotsAreUnknown() {
        XCTAssertEqual(mnemonic(0xce620020), "unknown")
        XCTAssertEqual(mnemonic(0xce620c20), "unknown")
        XCTAssertEqual(mnemonic(0xce62a020), "unknown")
        XCTAssertEqual(mnemonic(0xce62cc20), "unknown")
        XCTAssertEqual(mnemonic(0xce62fc20), "unknown")
        XCTAssertEqual(mnemonic(0xce42c020), "unknown")
        XCTAssertEqual(mnemonic(0xcec08820), "unknown")
        XCTAssertEqual(mnemonic(0xcec18020), "unknown")
        XCTAssertEqual(mnemonic(0xcec18420), "unknown")
        XCTAssertEqual(mnemonic(0xce028020), "unknown")
        XCTAssertEqual(mnemonic(0xcea20c20), "unknown")
        XCTAssertEqual(mnemonic(0xcec20c20), "unknown")
        XCTAssertEqual(mnemonic(0xcee20c20), "unknown")
    }
}
