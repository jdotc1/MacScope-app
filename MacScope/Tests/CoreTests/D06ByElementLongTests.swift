import Foundation
import XCTest
@testable import MacScope

final class D06ByElementLongTests: XCTestCase {
    private typealias Lane = MacIRNEONLaneOp

    func testEveryLongArrangementAndElementLimit() throws {
        for base in ["smull", "umull", "smlal", "umlal", "smlsl", "umlsl"] {
            for high in [false, true] {
                for bits in [16, 32] {
                    let name = base + (high ? "2" : "")
                    let wide = bits == 16 ? "4s" : "2d"
                    let suffix = bits == 16 ? "h" : "s"
                    let narrow = "\((high ? 128 : 64) / bits)\(suffix)"
                    let lastRegister = bits == 16 ? 15 : 31
                    for index in 0..<(128 / bits) {
                        let p = try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: name,
                            operandText: "v0.\(wide), v1.\(narrow), v\(lastRegister).\(suffix)[\(index)]"))
                        XCTAssertEqual(p.semantics.elementIndex, index)
                        XCTAssertEqual(p.semantics.highHalf, high)
                        XCTAssertEqual(p.semantics.isSigned, base.first == "s")
                        XCTAssertEqual(p.semantics.readsDestination, !base.hasSuffix("mull"))
                    }
                    for bad in [-1, 128 / bits] {
                        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: name,
                            operandText: "v0.\(wide), v1.\(narrow), v2.\(suffix)[\(bad)]"))
                    }
                }
            }
        }
        for (m, text) in [
            ("smull", "v0.4s, v1.4h, v16.h[0]"),
            ("smull", "v0.4s, v1.8h, v2.h[0]"),
            ("smull2", "v0.4s, v1.4h, v2.h[0]"),
            ("smull", "v0.2d, v1.2s, v32.s[0]"),
            ("smull", "v0.8h, v1.8b, v2.b[0]"),
            ("smull", "v0.4s, v1.4h, v2.s[0]"),
            ("smull", "v0.4s, v1.4h, v2.h[00]"),
            ("smull", "v0.4s, v1.4h, v2[h.[0]"),
            ("saddl", "v0.4s, v1.4h, v2.h[0]"),
            ("shl", "v0.1d, v1.1d, #1"),
            ("shl", "v0.4s, v1.2s, #1"),
            ("shl", "v0.4s, v1.4s, #32"),
            ("shl", "v0.4s, v1.4s, #-1"),
            ("srshr", "v0.4s, v1.4s, #0"),
            ("srshr", "v0.4s, v1.4s, #33")
        ] { XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: m, operandText: text), text) }
        XCTAssertNil(Lane(kind: .shl, isSigned: false, laneBits: -1, highHalf: false))
        XCTAssertNil(Lane(kind: .mull, isSigned: true, laneBits: 8, highHalf: false, elementIndex: 0))
    }

    func testSignedRoundingAtWidthAndIntMinWithoutOverflow() throws {
        for bits in [8, 16, 32, 64] {
            let mask = bits == 64 ? UInt64.max : (UInt64(1) << bits) - 1
            let minimum = UInt64(1) << (bits - 1)
            for shift in 1...bits {
                let op = try XCTUnwrap(Lane(kind: .srshr, isSigned: false, laneBits: bits, highHalf: false, shift: shift))
                XCTAssertEqual(op.sourceCount, 1)
                XCTAssertEqual(op.evaluate(n: (minimum, 0)).low & mask,
                    shift == bits ? 0 : (0 &- (minimum >> shift)) & mask)
                XCTAssertEqual(op.evaluate(n: (minimum - 1, 0)).low & mask,
                    shift == bits ? 0 : minimum >> shift)
            }
            let left = try XCTUnwrap(Lane(kind: .shl, isSigned: false, laneBits: bits, highHalf: false, shift: bits - 1))
            XCTAssertEqual(left.evaluate(n: (1, 0)).low & mask, minimum)
        }
    }

    func testHighHalfDoesNotOffsetSelectedElement() throws {
        let op = try XCTUnwrap(Lane(kind: .mull, isSigned: true, laneBits: 16, highHalf: true, elementIndex: 0))
        let value = op.evaluate(n: (0, 0x0004_0003_fffe_0001), m: (3, .max))
        XCTAssertEqual(value.low, 0xffff_fffa_0000_0003)
        XCTAssertEqual(value.high, 0x0000_000c_0000_0009)
        XCTAssertTrue(op.intrinsicName.contains("by_lane0"))
        let unsigned = try XCTUnwrap(Lane(kind: .mlal, isSigned: false, laneBits: 32, highHalf: false, elementIndex: 3))
        XCTAssertEqual(unsigned.evaluate(n: (.max, 0), m: (0, .max), oldDestination: (.max, .max)).low, 0xffff_fffe_0000_0000)
    }

    func testEmbeddedRealFDCTRowsLiftToTypedLaneOps() throws {
        // libjpeg-turbo 3.2.0, _jsimd_fdct_islow_neon, real bytes at these addresses.
        let rows: [(UInt64, [UInt8], String)] = [
            (0x56478, [0xa5, 0x54, 0x12, 0x4f], "shl"),
            (0x56488, [0x07, 0xa2, 0x70, 0x0f], "smull"),
            (0x5648c, [0x67, 0x22, 0x60, 0x0f], "smlal"),
            (0x56490, [0x10, 0xa2, 0x70, 0x4f], "smull2"),
            (0x56494, [0x70, 0x22, 0x60, 0x4f], "smlal2"),
            (0x56604, [0xa5, 0x24, 0x1e, 0x4f], "srshr")
        ]
        for (address, bytes, mnemonic) in rows {
            let decoded = try XCTUnwrap(ARM64Decoder().decode(Data(bytes), baseAddress: address).first)
            XCTAssertEqual(decoded.mnemonic, mnemonic)
            let parsed = try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: decoded.mnemonic, operandText: decoded.operands))
            XCTAssertEqual(parsed.semantics.kind.rawValue, ["shl", "srshr"].contains(mnemonic) ? mnemonic : mnemonic.hasPrefix("smull") ? "mull" : "mlal")
        }
    }
}
