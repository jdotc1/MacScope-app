import Foundation
import XCTest
@testable import MacScope

final class ARM64PrefetchTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    private func mnemonic(_ word: UInt32) -> String {
        String(text(word).split(separator: " ")[0])
    }

    func testUnsignedScaledPrefetch() {
        XCTAssertEqual(text(0xf9800000), "prfm pldl1keep, [x0]")
        XCTAssertEqual(text(0xf9800001), "prfm pldl1strm, [x0]")
        XCTAssertEqual(text(0xf9800002), "prfm pldl2keep, [x0]")
        XCTAssertEqual(text(0xf9800003), "prfm pldl2strm, [x0]")
        XCTAssertEqual(text(0xf9800004), "prfm pldl3keep, [x0]")
        XCTAssertEqual(text(0xf9800005), "prfm pldl3strm, [x0]")
        XCTAssertEqual(text(0xf9800006), "prfm #6, [x0]")
        XCTAssertEqual(text(0xf9800007), "prfm #7, [x0]")
        XCTAssertEqual(text(0xf9800008), "prfm plil1keep, [x0]")
        XCTAssertEqual(text(0xf9800009), "prfm plil1strm, [x0]")
        XCTAssertEqual(text(0xf980000a), "prfm plil2keep, [x0]")
        XCTAssertEqual(text(0xf980000b), "prfm plil2strm, [x0]")
        XCTAssertEqual(text(0xf980000c), "prfm plil3keep, [x0]")
        XCTAssertEqual(text(0xf980000d), "prfm plil3strm, [x0]")
        XCTAssertEqual(text(0xf980000e), "prfm #14, [x0]")
        XCTAssertEqual(text(0xf980000f), "prfm #15, [x0]")
        XCTAssertEqual(text(0xf9800010), "prfm pstl1keep, [x0]")
        XCTAssertEqual(text(0xf9800011), "prfm pstl1strm, [x0]")
        XCTAssertEqual(text(0xf9800012), "prfm pstl2keep, [x0]")
        XCTAssertEqual(text(0xf9800013), "prfm pstl2strm, [x0]")
        XCTAssertEqual(text(0xf9800014), "prfm pstl3keep, [x0]")
        XCTAssertEqual(text(0xf9800015), "prfm pstl3strm, [x0]")
        XCTAssertEqual(text(0xf9800016), "prfm #22, [x0]")
        XCTAssertEqual(text(0xf9800017), "prfm #23, [x0]")
        XCTAssertEqual(text(0xf9800018), "prfm #24, [x0]")
        XCTAssertEqual(text(0xf980001b), "prfm #27, [x0]")
        XCTAssertEqual(text(0xf980001f), "prfm #31, [x0]")
        XCTAssertEqual(text(0xf9800420), "prfm pldl1keep, [x1, #0x8]")
        XCTAssertEqual(text(0xf9bffc55), "prfm pstl3strm, [x2, #0x7ff8]")
        XCTAssertEqual(text(0xf9a0028a), "prfm plil2keep, [x20, #0x4000]")
        XCTAssertEqual(text(0xf98007c0), "prfm pldl1keep, [x30, #0x8]")
        XCTAssertEqual(text(0xf98007e0), "prfm pldl1keep, [sp, #0x8]")
    }

    func testRegisterOffsetPrefetch() {
        XCTAssertEqual(text(0xf8a46863), "prfm pldl2strm, [x3, x4]")
        XCTAssertEqual(text(0xf8a47863), "prfm pldl2strm, [x3, x4, lsl #3]")
        XCTAssertEqual(text(0xf8a648a4), "prfm pldl3keep, [x5, w6, uxtw]")
        XCTAssertEqual(text(0xf8a658a4), "prfm pldl3keep, [x5, w6, uxtw #3]")
        XCTAssertEqual(text(0xf8a1c800), "prfm pldl1keep, [x0, w1, sxtw]")
        XCTAssertEqual(text(0xf8a1d800), "prfm pldl1keep, [x0, w1, sxtw #3]")
        XCTAssertEqual(text(0xf8a6e8a0), "prfm pldl1keep, [x5, x6, sxtx]")
        XCTAssertEqual(text(0xf8bbfb91), "prfm pstl1strm, [x28, x27, sxtx #3]")
        XCTAssertEqual(text(0xf8a16be0), "prfm pldl1keep, [sp, x1]")
    }

    func testUnscaledPrefetch() {
        XCTAssertEqual(text(0xf8800100), "prfum pldl1keep, [x8]")
        XCTAssertEqual(text(0xf8900133), "prfum pstl2strm, [x9, #-0x100]")
        XCTAssertEqual(text(0xf89ff26d), "prfum plil3strm, [x19, #-0x1]")
        XCTAssertEqual(text(0xf88ff15f), "prfum #31, [x10, #0xff]")
        XCTAssertEqual(text(0xf88ff3e6), "prfum #6, [sp, #0xff]")
        XCTAssertEqual(text(0xf88003e0), "prfum pldl1keep, [sp]")
    }

    func testReservedPrefetchSlotsAreUnknown() {
        XCTAssertEqual(mnemonic(0xf8a10800), "unknown")
        XCTAssertEqual(mnemonic(0xf8a12800), "unknown")
        XCTAssertEqual(mnemonic(0xf8a18800), "unknown")
        XCTAssertEqual(mnemonic(0xf8a1a800), "unknown")
        XCTAssertEqual(mnemonic(0xf8800400), "unknown")
        XCTAssertEqual(mnemonic(0xf8800c00), "unknown")
        XCTAssertEqual(mnemonic(0xf8c00000), "unknown")
    }
    // RPRFM (Range Prefetch Memory, ARMv8.6) occupies the register-offset slot with Rt[4:3]=11
    // (Rt >= 24) — a DISTINCT instruction (`rprfm <prfop2|#imm6>, Xm, [Xn|SP]`), not prfm. The
    // decoder must not mis-render it as `prfm #24..#31, [base, index, ext]`; it returns `unknown`
    // until rprfm is implemented. (Regression: the initial prfm cut decoded these as prfm.)
    func testRangePrefetchSlotIsNotMisdecodedAsPrfm() {
        XCTAssertEqual(text(0xf8a04838), "rprfm pldkeep, x0, [x1]")   // now decoded as RPRFM (255ef6a era: unknown)
        XCTAssertEqual(text(0xf8a8e8fd), "rprfm #53, x8, [x7]")       // unnamed prfop2 -> decimal #imm
        XCTAssertEqual(text(0xf8befbff), "rprfm #63, x30, [sp]")
        // Valid prfm neighbours must STILL decode:
        XCTAssertEqual(text(0xf8a26820), "prfm pldl1keep, [x1, x2]")   // reg-offset, Rt<24
        XCTAssertEqual(text(0xf9800438), "prfm #24, [x1, #0x8]")       // scaled Rt=24: unnamed prfm
        XCTAssertEqual(text(0xf89fc038), "prfum #24, [x1, #-0x4]")     // unscaled Rt=24: unnamed prfum
    }
}
