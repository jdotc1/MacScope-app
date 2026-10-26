import Foundation
import XCTest
@testable import MacScope

/// RPRFM (Range Prefetch Memory, FEAT_RPRFM / ARMv8.6). Occupies the `prfm`
/// register-offset slot (size=11, opc=10, bit24=0, bit21=1, bits[11:10]=10) with
/// Rt[4:3]=11 (Rt>=24). Ground truth = otool (standard-syntax translation applied):
/// otool prints `rprfm #0x3f, ...` where MacScope emits `#63` (DECIMAL prfop2 per
/// house style, matching the existing `prfm #6` spelling). Index Xm is a plain
/// 64-bit register with NO extend/lsl.
final class ARM64RangePrefetchTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }
    private func mnemonic(_ word: UInt32) -> String { String(text(word).split(separator: " ")[0]) }

    // MARK: - Named prfop2 values (the only 4 otool/llvm-objdump name: 0/1/4/5)
    func testNamedPrfop2() {
        XCTAssertEqual(text(0xf8a24838), "rprfm pldkeep, x2, [x1]")   // prfop2=0
        XCTAssertEqual(text(0xf8a34899), "rprfm pstkeep, x3, [x4]")   // prfop2=1
        XCTAssertEqual(text(0xf8a548dc), "rprfm pldstrm, x5, [x6]")   // prfop2=4
        XCTAssertEqual(text(0xf8a7491d), "rprfm pststrm, x7, [x8]")   // prfop2=5
    }

    // MARK: - Unnamed prfop2 -> DECIMAL #imm (house style; otool prints #0xNN)
    func testUnnamedPrfop2Decimal() {
        XCTAssertEqual(text(0xf8a9495a), "rprfm #2, x9, [x10]")       // otool #0x2
        XCTAssertEqual(text(0xf8ab499b), "rprfm #3, x11, [x12]")      // otool #0x3
        XCTAssertEqual(text(0xf8ad49de), "rprfm #6, x13, [x14]")      // otool #0x6
        XCTAssertEqual(text(0xf8af7a1f), "rprfm #31, x15, [x16]")     // otool #0x1f
        XCTAssertEqual(text(0xf8b1ca58), "rprfm #32, x17, [x18]")     // otool #0x20
        XCTAssertEqual(text(0xf8befbff), "rprfm #63, x30, [sp]")      // otool #0x3f
    }

    // MARK: - Register/base edge cases
    func testRegisterEdges() {
        XCTAssertEqual(text(0xf8a04818), "rprfm pldkeep, x0, [x0]")
        XCTAssertEqual(text(0xf8bf4838), "rprfm pldkeep, xzr, [x1]")  // index Rm=31 -> xzr
        XCTAssertEqual(text(0xf8a24bf8), "rprfm pldkeep, x2, [sp]")   // base  Rn=31 -> sp
        XCTAssertEqual(text(0xf8befbdf), "rprfm #63, x30, [x30]")
    }

    // MARK: - Reserved: option[1]=0 (option in {0,1,4,5}) -> otool .long -> unknown
    func testReservedOptionBit1Zero() {
        XCTAssertEqual(mnemonic(0xf8a10838), "unknown")  // option=0 S=0
        XCTAssertEqual(mnemonic(0xf8a12838), "unknown")  // option=1 S=0
        XCTAssertEqual(mnemonic(0xf8a18838), "unknown")  // option=4 S=0
        XCTAssertEqual(mnemonic(0xf8a1b838), "unknown")  // option=5 S=1
        XCTAssertEqual(mnemonic(0xf8a11838), "unknown")  // option=0 S=1 (otool .long)
        // 0xf8a10c38 (the old "option=0 S=1" vector) has bits[11:10]=11, not 10:
        // it is LDRAB x24, [x1, #0x80]! (FEAT_PAuth pre-index), outside the
        // register-offset prfm slot; otool and llvm-objdump agree.
        XCTAssertEqual(mnemonic(0xf8a10c38), "ldrab")
        XCTAssertEqual(mnemonic(0xf8a1a838), "unknown")  // option=5 S=0
    }

    // MARK: - Neighbours must NOT regress (prfm reg-offset Rt<24, prfm scaled/prfum Rt>=24)
    func testNeighboursUnaffected() {
        XCTAssertEqual(text(0xf8a17820), "prfm pldl1keep, [x1, x1, lsl #3]")   // Rt=0 reg-offset stays prfm
        XCTAssertEqual(text(0xf9800838), "prfm #24, [x1, #0x10]")              // scaled Rt=24 stays prfm #imm
        XCTAssertEqual(text(0xf8801038), "prfum #24, [x1, #0x1]")             // unscaled Rt=24 stays prfum #imm
        XCTAssertEqual(text(0xf9800000), "prfm pldl1keep, [x0]")               // scaled Rt=0 stays prfm
    }
}
