import Foundation
import XCTest
@testable import MacScope

final class ARM64ComplexTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    private func mnemonic(_ word: UInt32) -> String {
        String(text(word).split(separator: " ")[0])
    }

    func testFCADDVector() {
        XCTAssertEqual(text(0x2e42e420), "fcadd v0.4h, v1.4h, v2.4h, #90")
        XCTAssertEqual(text(0x2e42f420), "fcadd v0.4h, v1.4h, v2.4h, #270")
        XCTAssertEqual(text(0x6e42e420), "fcadd v0.8h, v1.8h, v2.8h, #90")
        XCTAssertEqual(text(0x6e42f420), "fcadd v0.8h, v1.8h, v2.8h, #270")
        XCTAssertEqual(text(0x2e82e420), "fcadd v0.2s, v1.2s, v2.2s, #90")
        XCTAssertEqual(text(0x2e82f420), "fcadd v0.2s, v1.2s, v2.2s, #270")
        XCTAssertEqual(text(0x6e82e420), "fcadd v0.4s, v1.4s, v2.4s, #90")
        XCTAssertEqual(text(0x6e82f420), "fcadd v0.4s, v1.4s, v2.4s, #270")
        XCTAssertEqual(text(0x6ec2e420), "fcadd v0.2d, v1.2d, v2.2d, #90")
        XCTAssertEqual(text(0x6ec2f420), "fcadd v0.2d, v1.2d, v2.2d, #270")
        XCTAssertEqual(text(0x6ed0e69f), "fcadd v31.2d, v20.2d, v16.2d, #90")
        XCTAssertEqual(text(0x6e92f630), "fcadd v16.4s, v17.4s, v18.4s, #270")
    }

    func testFCMLAVector() {
        XCTAssertEqual(text(0x2e42c420), "fcmla v0.4h, v1.4h, v2.4h, #0")
        XCTAssertEqual(text(0x2e42cc20), "fcmla v0.4h, v1.4h, v2.4h, #90")
        XCTAssertEqual(text(0x2e42d420), "fcmla v0.4h, v1.4h, v2.4h, #180")
        XCTAssertEqual(text(0x2e42dc20), "fcmla v0.4h, v1.4h, v2.4h, #270")
        XCTAssertEqual(text(0x6e42c420), "fcmla v0.8h, v1.8h, v2.8h, #0")
        XCTAssertEqual(text(0x6e42cc20), "fcmla v0.8h, v1.8h, v2.8h, #90")
        XCTAssertEqual(text(0x6e42d420), "fcmla v0.8h, v1.8h, v2.8h, #180")
        XCTAssertEqual(text(0x6e42dc20), "fcmla v0.8h, v1.8h, v2.8h, #270")
        XCTAssertEqual(text(0x2e82c420), "fcmla v0.2s, v1.2s, v2.2s, #0")
        XCTAssertEqual(text(0x2e82cc20), "fcmla v0.2s, v1.2s, v2.2s, #90")
        XCTAssertEqual(text(0x2e82d420), "fcmla v0.2s, v1.2s, v2.2s, #180")
        XCTAssertEqual(text(0x2e82dc20), "fcmla v0.2s, v1.2s, v2.2s, #270")
        XCTAssertEqual(text(0x6e82c420), "fcmla v0.4s, v1.4s, v2.4s, #0")
        XCTAssertEqual(text(0x6e82cc20), "fcmla v0.4s, v1.4s, v2.4s, #90")
        XCTAssertEqual(text(0x6e82d420), "fcmla v0.4s, v1.4s, v2.4s, #180")
        XCTAssertEqual(text(0x6e82dc20), "fcmla v0.4s, v1.4s, v2.4s, #270")
        XCTAssertEqual(text(0x6ec2c420), "fcmla v0.2d, v1.2d, v2.2d, #0")
        XCTAssertEqual(text(0x6ec2cc20), "fcmla v0.2d, v1.2d, v2.2d, #90")
        XCTAssertEqual(text(0x6ec2d420), "fcmla v0.2d, v1.2d, v2.2d, #180")
        XCTAssertEqual(text(0x6ec2dc20), "fcmla v0.2d, v1.2d, v2.2d, #270")
        XCTAssertEqual(text(0x6ed0d69f), "fcmla v31.2d, v20.2d, v16.2d, #180")
        XCTAssertEqual(text(0x6e52de30), "fcmla v16.8h, v17.8h, v18.8h, #270")
    }

    func testFCMLAByElement() {
        XCTAssertEqual(text(0x2f421020), "fcmla v0.4h, v1.4h, v2.h[0], #0")
        XCTAssertEqual(text(0x2f623020), "fcmla v0.4h, v1.4h, v2.h[1], #90")
        XCTAssertEqual(text(0x2f425020), "fcmla v0.4h, v1.4h, v2.h[0], #180")
        XCTAssertEqual(text(0x2f627020), "fcmla v0.4h, v1.4h, v2.h[1], #270")
        XCTAssertEqual(text(0x6f421020), "fcmla v0.8h, v1.8h, v2.h[0], #0")
        XCTAssertEqual(text(0x6f623020), "fcmla v0.8h, v1.8h, v2.h[1], #90")
        XCTAssertEqual(text(0x6f425820), "fcmla v0.8h, v1.8h, v2.h[2], #180")
        XCTAssertEqual(text(0x6f627820), "fcmla v0.8h, v1.8h, v2.h[3], #270")
        XCTAssertEqual(text(0x6f821020), "fcmla v0.4s, v1.4s, v2.s[0], #0")
        XCTAssertEqual(text(0x6f823820), "fcmla v0.4s, v1.4s, v2.s[1], #90")
        XCTAssertEqual(text(0x6f825020), "fcmla v0.4s, v1.4s, v2.s[0], #180")
        XCTAssertEqual(text(0x6f827820), "fcmla v0.4s, v1.4s, v2.s[1], #270")
        XCTAssertEqual(text(0x6f6f7a9f), "fcmla v31.8h, v20.8h, v15.h[3], #270")
        XCTAssertEqual(text(0x6f925a30), "fcmla v16.4s, v17.4s, v18.s[1], #180")
    }

    func testHalfByElementUsesMBitForVm() {
        XCTAssertEqual(text(0x2f521020), "fcmla v0.4h, v1.4h, v18.h[0], #0")
    }

    func testReservedComplexSlotsAreUnknown() {
        XCTAssertEqual(mnemonic(0x2e02c420), "unknown")
        XCTAssertEqual(mnemonic(0x2e02e420), "unknown")
        XCTAssertEqual(mnemonic(0x6e02c420), "unknown")
        XCTAssertEqual(mnemonic(0x2f021020), "unknown")
        XCTAssertEqual(mnemonic(0x2fc21020), "unknown")
    }
}
