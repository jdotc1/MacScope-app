import Foundation
import XCTest
@testable import MacScope

final class ARM64MTETests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    private func mnemonic(_ word: UInt32) -> String {
        String(text(word).split(separator: " ")[0])
    }

    func testDataProcessingPointerTags() {
        XCTAssertEqual(text(0x9ac21020), "irg x0, x1, x2")
        XCTAssertEqual(text(0x9adf1020), "irg x0, x1")
        XCTAssertEqual(text(0x9ad612b4), "irg x20, x21, x22")
        XCTAssertEqual(text(0x9ac610bf), "irg sp, x5, x6")
        XCTAssertEqual(text(0x9ac813e7), "irg x7, sp, x8")
        XCTAssertEqual(text(0x9adf13fe), "irg x30, sp")

        XCTAssertEqual(text(0x9ac21420), "gmi x0, x1, x2")
        XCTAssertEqual(text(0x9ad617f4), "gmi x20, sp, x22")
        XCTAssertEqual(text(0x9acb1549), "gmi x9, x10, x11")

        XCTAssertEqual(text(0x9ac20020), "subp x0, x1, x2")
        XCTAssertEqual(text(0x9ad603f4), "subp x20, sp, x22")
        XCTAssertEqual(text(0x9adf03e9), "subp x9, sp, sp")

        XCTAssertEqual(text(0xbac20020), "subps x0, x1, x2")
        XCTAssertEqual(text(0xbad603f4), "subps x20, sp, x22")
        XCTAssertEqual(text(0xbac2003f), "subps xzr, x1, x2")
    }

    func testAddSubtractImmediateWithTags() {
        XCTAssertEqual(text(0x91800020), "addg x0, x1, #0, #0")
        XCTAssertEqual(text(0x91810420), "addg x0, x1, #0x10, #1")
        XCTAssertEqual(text(0x91bf3c20), "addg x0, x1, #0x3f0, #0xf")
        XCTAssertEqual(text(0x91830fff), "addg sp, sp, #0x30, #3")
        XCTAssertEqual(text(0x918f1eb4), "addg x20, x21, #0xf0, #7")

        XCTAssertEqual(text(0xd1800020), "subg x0, x1, #0, #0")
        XCTAssertEqual(text(0xd1810420), "subg x0, x1, #0x10, #1")
        XCTAssertEqual(text(0xd1bf3c20), "subg x0, x1, #0x3f0, #0xf")
        XCTAssertEqual(text(0xd1830fff), "subg sp, sp, #0x30, #3")
        XCTAssertEqual(text(0xd18f1eb4), "subg x20, x21, #0xf0, #7")
    }

    func testLoadStoreMemoryTags() {
        XCTAssertEqual(text(0xd9200820), "stg x0, [x1]")
        XCTAssertEqual(text(0xd9201820), "stg x0, [x1, #0x10]")
        XCTAssertEqual(text(0xd93f0820), "stg x0, [x1, #-0x100]")
        XCTAssertEqual(text(0xd92ff820), "stg x0, [x1, #0xff0]")
        XCTAssertEqual(text(0xd9201be0), "stg x0, [sp, #0x10]")
        XCTAssertEqual(text(0xd9201c20), "stg x0, [x1, #0x10]!")
        XCTAssertEqual(text(0xd9201420), "stg x0, [x1], #0x10")
        XCTAssertEqual(text(0xd93f0fe0), "stg x0, [sp, #-0x100]!")
        XCTAssertEqual(text(0xd93f06b4), "stg x20, [x21], #-0x100")

        XCTAssertEqual(text(0xd9a00820), "st2g x0, [x1]")
        XCTAssertEqual(text(0xd9a01820), "st2g x0, [x1, #0x10]")
        XCTAssertEqual(text(0xd9a01c20), "st2g x0, [x1, #0x10]!")
        XCTAssertEqual(text(0xd9a01420), "st2g x0, [x1], #0x10")
        XCTAssertEqual(text(0xd9a02be0), "st2g x0, [sp, #0x20]")

        XCTAssertEqual(text(0xd9600820), "stzg x0, [x1]")
        XCTAssertEqual(text(0xd9601820), "stzg x0, [x1, #0x10]")
        XCTAssertEqual(text(0xd9601c20), "stzg x0, [x1, #0x10]!")
        XCTAssertEqual(text(0xd9601420), "stzg x0, [x1], #0x10")
        XCTAssertEqual(text(0xd97ffbe0), "stzg x0, [sp, #-0x10]")

        XCTAssertEqual(text(0xd9e00820), "stz2g x0, [x1]")
        XCTAssertEqual(text(0xd9e01820), "stz2g x0, [x1, #0x10]")
        XCTAssertEqual(text(0xd9e01c20), "stz2g x0, [x1, #0x10]!")
        XCTAssertEqual(text(0xd9e01420), "stz2g x0, [x1], #0x10")
        XCTAssertEqual(text(0xd9e03be0), "stz2g x0, [sp, #0x30]")

        XCTAssertEqual(text(0xd9600020), "ldg x0, [x1]")
        XCTAssertEqual(text(0xd9601020), "ldg x0, [x1, #0x10]")
        XCTAssertEqual(text(0xd97f0020), "ldg x0, [x1, #-0x100]")
        XCTAssertEqual(text(0xd96ff020), "ldg x0, [x1, #0xff0]")
        XCTAssertEqual(text(0xd96013f4), "ldg x20, [sp, #0x10]")

        XCTAssertEqual(text(0xd9a00020), "stgm x0, [x1]")
        XCTAssertEqual(text(0xd9a003f4), "stgm x20, [sp]")
        XCTAssertEqual(text(0xd9200020), "stzgm x0, [x1]")
        XCTAssertEqual(text(0xd92003f4), "stzgm x20, [sp]")
        XCTAssertEqual(text(0xd9e00020), "ldgm x0, [x1]")
        XCTAssertEqual(text(0xd9e003f4), "ldgm x20, [sp]")
    }

    func testStoreAllocationTagPair() {
        XCTAssertEqual(text(0x69000440), "stgp x0, x1, [x2]")
        XCTAssertEqual(text(0x69008440), "stgp x0, x1, [x2, #0x10]")
        XCTAssertEqual(text(0x69200440), "stgp x0, x1, [x2, #-0x400]")
        XCTAssertEqual(text(0x691f8440), "stgp x0, x1, [x2, #0x3f0]")
        XCTAssertEqual(text(0x69808440), "stgp x0, x1, [x2, #0x10]!")
        XCTAssertEqual(text(0x68808440), "stgp x0, x1, [x2], #0x10")
        XCTAssertEqual(text(0x690157f4), "stgp x20, x21, [sp, #0x20]")
    }

    func testReservedMTESlotsAreUnknown() {
        XCTAssertEqual(mnemonic(0x9ac20420), "unknown")
        XCTAssertEqual(mnemonic(0x9ac21820), "unknown")
        XCTAssertEqual(mnemonic(0x9ac21c20), "unknown")
        XCTAssertEqual(mnemonic(0xd9201020), "unknown")
        XCTAssertEqual(mnemonic(0xd9a01020), "unknown")
        XCTAssertEqual(mnemonic(0xd9e01020), "unknown")
        XCTAssertEqual(mnemonic(0xd9000820), "unknown")
        XCTAssertEqual(mnemonic(0xe9000440), "unknown")
    }
}
