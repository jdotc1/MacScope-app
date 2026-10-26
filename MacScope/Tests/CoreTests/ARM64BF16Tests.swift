import Foundation
import XCTest
@testable import MacScope

final class ARM64BF16Tests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    private func mnemonic(_ word: UInt32) -> String {
        String(text(word).split(separator: " ")[0])
    }

    func testBFDOTVector() {
        XCTAssertEqual(text(0x2e42fc20), "bfdot v0.2s, v1.4h, v2.4h")
        XCTAssertEqual(text(0x6e42fc20), "bfdot v0.4s, v1.8h, v2.8h")
        XCTAssertEqual(text(0x6e5ffe30), "bfdot v16.4s, v17.8h, v31.8h")
        XCTAssertEqual(text(0x2e47fe8a), "bfdot v10.2s, v20.4h, v7.4h")
    }

    func testBFDOTByElement() {
        XCTAssertEqual(text(0x0f42f020), "bfdot v0.2s, v1.4h, v2.2h[0]")
        XCTAssertEqual(text(0x0f62f020), "bfdot v0.2s, v1.4h, v2.2h[1]")
        XCTAssertEqual(text(0x0f42f820), "bfdot v0.2s, v1.4h, v2.2h[2]")
        XCTAssertEqual(text(0x0f62f820), "bfdot v0.2s, v1.4h, v2.2h[3]")
        XCTAssertEqual(text(0x4f62f820), "bfdot v0.4s, v1.8h, v2.2h[3]")
        XCTAssertEqual(text(0x4f6ff820), "bfdot v0.4s, v1.8h, v15.2h[3]")
        XCTAssertEqual(text(0x4f5ff820), "bfdot v0.4s, v1.8h, v31.2h[2]")
        XCTAssertEqual(text(0x4f72f285), "bfdot v5.4s, v20.8h, v18.2h[1]")
    }

    func testBFMMLAVector() {
        XCTAssertEqual(text(0x6e42ec20), "bfmmla v0.4s, v1.8h, v2.8h")
        XCTAssertEqual(text(0x6e56eeb4), "bfmmla v20.4s, v21.8h, v22.8h")
        XCTAssertEqual(text(0x6e5defdf), "bfmmla v31.4s, v30.8h, v29.8h")
    }

    func testBFMLALVector() {
        XCTAssertEqual(text(0x2ec2fc20), "bfmlalb v0.4s, v1.8h, v2.8h")
        XCTAssertEqual(text(0x6ec2fc20), "bfmlalt v0.4s, v1.8h, v2.8h")
        XCTAssertEqual(text(0x2edffe30), "bfmlalb v16.4s, v17.8h, v31.8h")
        XCTAssertEqual(text(0x6edffe30), "bfmlalt v16.4s, v17.8h, v31.8h")
    }

    func testBFMLALByElement() {
        XCTAssertEqual(text(0x0fc2f020), "bfmlalb v0.4s, v1.8h, v2.h[0]")
        XCTAssertEqual(text(0x0fd2f020), "bfmlalb v0.4s, v1.8h, v2.h[1]")
        XCTAssertEqual(text(0x0ff2f820), "bfmlalb v0.4s, v1.8h, v2.h[7]")
        XCTAssertEqual(text(0x4fc2f020), "bfmlalt v0.4s, v1.8h, v2.h[0]")
        XCTAssertEqual(text(0x4ff2f820), "bfmlalt v0.4s, v1.8h, v2.h[7]")
        XCTAssertEqual(text(0x0ffff820), "bfmlalb v0.4s, v1.8h, v15.h[7]")
        XCTAssertEqual(text(0x4ffff020), "bfmlalt v0.4s, v1.8h, v15.h[3]")
        XCTAssertEqual(text(0x4fcafa85), "bfmlalt v5.4s, v20.8h, v10.h[4]")
    }

    func testBFCVTScalar() {
        XCTAssertEqual(text(0x1e634020), "bfcvt h0, s1")
        XCTAssertEqual(text(0x1e634285), "bfcvt h5, s20")
        XCTAssertEqual(text(0x1e6343ff), "bfcvt h31, s31")
    }

    func testBFCVTNVector() {
        XCTAssertEqual(text(0x0ea16820), "bfcvtn v0.4h, v1.4s")
        XCTAssertEqual(text(0x4ea16820), "bfcvtn2 v0.8h, v1.4s")
        XCTAssertEqual(text(0x0ea16bf0), "bfcvtn v16.4h, v31.4s")
        XCTAssertEqual(text(0x4ea16954), "bfcvtn2 v20.8h, v10.4s")
    }

    func testReservedBF16SlotsAreUnknown() {
        XCTAssertEqual(mnemonic(0x2e02fc20), "unknown")
        XCTAssertEqual(mnemonic(0x6e02fc20), "unknown")
        XCTAssertEqual(mnemonic(0x2e82fc20), "unknown")
        XCTAssertEqual(mnemonic(0x6e82fc20), "unknown")
        XCTAssertEqual(mnemonic(0x2e42ec20), "unknown")
        XCTAssertEqual(mnemonic(0x6e02ec20), "unknown")
        XCTAssertEqual(mnemonic(0x6e82ec20), "unknown")
        XCTAssertEqual(mnemonic(0x6ec2ec20), "unknown")
        XCTAssertEqual(mnemonic(0x2e02ec20), "unknown")
        XCTAssertEqual(mnemonic(0x2e82ec20), "unknown")
        XCTAssertEqual(mnemonic(0x2ec2ec20), "unknown")
        XCTAssertEqual(mnemonic(0x0ee16820), "unknown")
        XCTAssertEqual(mnemonic(0x4ee16820), "unknown")
        XCTAssertEqual(mnemonic(0x1e234020), "unknown")
        XCTAssertEqual(mnemonic(0x1ea34020), "unknown")
        XCTAssertEqual(mnemonic(0x1ee34020), "unknown")
    }
}
