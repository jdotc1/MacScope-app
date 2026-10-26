import Foundation
import XCTest
@testable import MacScope

final class SIMDNarrowingModelTests: XCTestCase {
    private typealias Lane = MacIRNEONLaneOp

    // Arm ISA_A64 2025-12: {ADDHN,RADDHN,SUBHN,RSUBHN}_advsimd,
    // Execute/Operation. Cover both Q encodings and all three legal sizes.
    func testEveryBinaryNarrowEncodingReachesTypedIR() throws {
        let kinds: [Lane.Kind] = [.addhn, .raddhn, .subhn, .rsubhn]
        for kind in kinds {
            for size: UInt32 in 0...2 {
                for high in [false, true] {
                    let rounded = kind == .raddhn || kind == .rsubhn
                    let subtract = kind == .subhn || kind == .rsubhn
                    let word: UInt32 = 0x0e20_0000 | (high ? 1 << 30 : 0)
                        | (rounded ? 1 << 29 : 0) | (size << 22)
                        | (subtract ? 6 << 12 : 4 << 12) | (2 << 16) | (1 << 5)
                    let words: [UInt32] = [word, 0xd65f_03c0]
                    let bytes = Data(words.flatMap { word in
                        withUnsafeBytes(of: word.littleEndian) { Array($0) }
                    })
                    let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1000,
                        maxInstructionCount: words.count).map { item in
                        InstructionRow(address: item.address, bytes: item.byteText,
                            mnemonic: item.mnemonic, operands: item.operands,
                            hasBreakpoint: false, comment: item.comment)
                    }
                    XCTAssertEqual(rows.first?.mnemonic, kind.rawValue + (high ? "2" : ""))
                    let function = MacIRBuilder().buildFunction(name: "binary_narrow",
                        startAddress: 0x1000, instructions: rows)
                    let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1000 })
                    let semantics = try XCTUnwrap(instruction.neonLaneOp)
                    XCTAssertEqual(semantics.kind, kind)
                    XCTAssertEqual(semantics.laneBits, 8 << Int(size))
                    XCTAssertEqual(semantics.highHalf, high)
                    XCTAssertFalse(semantics.setsQC)
                    guard case let .intrinsic(_, name, arguments) = instruction.operation else {
                        return XCTFail("missing typed binary-narrow operation")
                    }
                    XCTAssertEqual(name, semantics.intrinsicName)
                    XCTAssertEqual(arguments.count, high ? 3 : 2)
                }
            }
        }
    }

    func testWrappingRoundingBorrowAndDestinationHalves() throws {
        for bits in [8, 16, 32] {
            let wideBits = bits * 2
            func repeatWide(_ value: UInt64) -> Lane.Vector {
                var half: UInt64 = 0
                for position in stride(from: 0, to: 64, by: wideBits) {
                    half |= value << UInt64(position)
                }
                return (half, half)
            }
            let wideMax = wideBits == 64 ? UInt64.max : (UInt64(1) << UInt64(wideBits)) - 1
            let cases: [(Lane.Kind, Lane.Vector, Lane.Vector, UInt64)] = [
                (.addhn, repeatWide(wideMax), repeatWide(1), 0),
                (.raddhn, repeatWide(wideMax), (0, 0), 0),
                (.subhn, (0, 0), repeatWide(1), .max),
                (.rsubhn, (0, 0), repeatWide(1), 0)
            ]
            for (kind, n, m, expected) in cases {
                for high in [false, true] {
                    let semantics = try XCTUnwrap(Lane(kind: kind, isSigned: false,
                        laneBits: bits, highHalf: high))
                    let result = semantics.evaluate(n: n, m: m,
                        oldDestination: (0x1234_5678_9abc_def0, .max))
                    XCTAssertEqual(result.low, high ? 0x1234_5678_9abc_def0 : expected)
                    XCTAssertEqual(result.high, high ? expected : 0)
                    XCTAssertFalse(semantics.saturates(n: n, m: m))
                }
            }
        }
    }

    func testRoundingTieAndMalformedArrangements() throws {
        let rounded = try XCTUnwrap(Lane(kind: .raddhn, isSigned: false, laneBits: 8, highHalf: false))
        let result = rounded.evaluate(n: (0x0080_007f_ffff_0100, 0), m: (0, 0))
        XCTAssertEqual(result.low, 0x0100_0001)
        XCTAssertEqual(result.high, 0)
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "addhn", operandText: "v0.16b, v1.8h, v2.8h"))
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "addhn2", operandText: "v0.8b, v1.8h, v2.8h"))
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "subhn", operandText: "v0.8b, v1.8h, v2.4s"))
        XCTAssertNil(Lane(kind: .addhn, isSigned: true, laneBits: 8, highHalf: false))
        XCTAssertNil(Lane(kind: .rsubhn, isSigned: false, laneBits: 32, highHalf: false, shift: 1))
    }

    private func typedInstruction(_ word: UInt32) throws -> MacIRInstruction {
        let words: [UInt32] = [word, 0xd65f_03c0]
        let bytes = Data(words.flatMap { word in
            withUnsafeBytes(of: word.littleEndian) { Array($0) }
        })
        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x1000,
            maxInstructionCount: words.count).map { item in
            InstructionRow(address: item.address, bytes: item.byteText,
                mnemonic: item.mnemonic, operands: item.operands,
                hasBreakpoint: false, comment: item.comment)
        }
        let function = MacIRBuilder().buildFunction(name: "narrow_shift",
            startAddress: 0x1000, instructions: rows)
        return try XCTUnwrap(function.instructions.first { $0.source.address == 0x1000 })
    }

    func testImmediateRightShiftEncodingsAndEndpointSemantics() throws {
        // U/opcode from the named Arm vector shift-immediate encodings.
        let forms: [(Lane.Kind, UInt32, UInt32)] = [
            (.sshr, 0, 0), (.ushr, 1, 0), (.ssra, 0, 2), (.usra, 1, 2),
            (.srshr, 0, 4), (.urshr, 1, 4), (.srsra, 0, 6), (.ursra, 1, 6), (.sri, 1, 8)
        ]
        for (kind, u, opcode) in forms {
            for size: UInt32 in 0...3 {
                let bits = 8 << Int(size)
                for q: UInt32 in 0...1 where size < 3 || q == 1 {
                    for shift in [1, bits] {
                        let immediate = UInt32(2 * bits - shift)
                        let word = UInt32(0x0f00_0400) | (q << 30) | (u << 29)
                            | (immediate << 16) | (opcode << 11) | (1 << 5)
                        let instruction = try typedInstruction(word)
                        let semantics = try XCTUnwrap(instruction.neonLaneOp)
                        XCTAssertEqual(semantics.kind, kind)
                        XCTAssertEqual(semantics.shift, shift)
                        XCTAssertEqual(semantics.laneBits, bits)
                        XCTAssertFalse(semantics.setsQC)
                        guard case let .intrinsic(_, _, args) = instruction.operation else {
                            return XCTFail("missing typed shift")
                        }
                        XCTAssertEqual(args.count, semantics.readsDestination ? 2 : 1)
                    }
                }
            }
        }
        for bits in [8, 16, 32, 64] {
            for kind: Lane.Kind in [.sshr, .ushr, .srshr, .urshr, .ssra, .usra, .srsra, .ursra, .sri] {
                let lane = try XCTUnwrap(Lane(kind: kind, isSigned: false, laneBits: bits,
                    highHalf: false, shift: bits))
                let result = lane.evaluate(n: (.max, .max), oldDestination: (.max, .max))
                var repeatedOne: UInt64 = 0
                for offset in stride(from: 0, to: 64, by: bits) { repeatedOne |= UInt64(1) << UInt64(offset) }
                let expected: UInt64
                switch kind {
                case .sshr, .usra, .srsra, .sri: expected = .max
                case .ssra: expected = UInt64.max &- repeatedOne
                case .urshr: expected = repeatedOne
                default: expected = 0
                }
                XCTAssertEqual(result.low, expected, "\(kind) width \(bits)")
                XCTAssertEqual(result.high, expected)
            }
        }
        let signedRound = try XCTUnwrap(Lane(kind: .srsra, isSigned: false,
            laneBits: 8, highHalf: false, activeBytes: 8, shift: 1))
        let rounded = signedRound.evaluate(n: (0x8180_ff01_0302_7f7e, .max),
            oldDestination: (0x0101_0101_0101_0101, .max))
        XCTAssertEqual(rounded.low, 0xc2c1_0102_0302_4140)
        XCTAssertEqual(rounded.high, 0)
        let insert = try XCTUnwrap(Lane(kind: .sri, isSigned: false,
            laneBits: 8, highHalf: false, activeBytes: 8, shift: 4))
        let inserted = insert.evaluate(n: (.max, .max), oldDestination: (0xa0a0_a0a0_a0a0_a0a0, .max))
        XCTAssertEqual(inserted.low, 0xafaf_afaf_afaf_afaf)
        XCTAssertEqual(inserted.high, 0)
    }

    func testXTNEncodingsDiscardHighLaneBitsAndPreserveOnlySpecifiedHalf() throws {
        for size: UInt32 in 0...2 {
            for q: UInt32 in 0...1 {
                let word = UInt32(0x0e21_2800) | (q << 30) | (size << 22) | (1 << 5)
                let instruction = try typedInstruction(word)
                let lane = try XCTUnwrap(instruction.neonLaneOp)
                XCTAssertEqual(lane.kind, .xtn)
                XCTAssertEqual(lane.laneBits, 8 << Int(size))
                XCTAssertEqual(lane.highHalf, q == 1)
                let result = lane.evaluate(n: (.max, .max), oldDestination: (0x0123_4567_89ab_cdef, 0))
                XCTAssertEqual(result.low, q == 1 ? 0x0123_4567_89ab_cdef : UInt64.max)
                XCTAssertEqual(result.high, q == 1 ? UInt64.max : 0)
            }
        }
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "ushr", operandText: "v0.1d, v1.1d, #64"))
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "sshr", operandText: "v0.8b, v1.8b, #0"))
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "sri", operandText: "v0.8b, v1.8b, #9"))
    }

    func testRegisterCompareAndPairwiseEncodingsReachTypedIR() throws {
        let forms: [(Lane.Kind, UInt32, UInt32)] = [
            (.cmgt, 0, 6), (.cmhi, 1, 6), (.cmge, 0, 7), (.cmhs, 1, 7),
            (.cmtst, 0, 17), (.cmeq, 1, 17), (.addp, 0, 23)
        ]
        for (kind, u, opcode) in forms {
            for size: UInt32 in 0...3 {
                for q: UInt32 in 0...1 where size < 3 || q == 1 {
                    let word = UInt32(0x0e20_0400) | (q << 30) | (u << 29)
                        | (size << 22) | (opcode << 11) | (2 << 16) | (1 << 5)
                    let instruction = try typedInstruction(word)
                    let lane = try XCTUnwrap(instruction.neonLaneOp)
                    XCTAssertEqual(lane.kind, kind)
                    XCTAssertEqual(lane.laneBits, 8 << Int(size))
                    XCTAssertEqual(lane.activeBytes, q == 1 ? 16 : 8)
                    XCTAssertFalse(lane.setsQC)
                    guard case let .intrinsic(_, _, arguments) = instruction.operation else {
                        return XCTFail("missing typed compare/pairwise")
                    }
                    XCTAssertEqual(arguments.count, 2)
                }
            }
        }
        for q: UInt32 in 0...1 {
            let instruction = try typedInstruction(0x2ee2_1c20 | (q << 30))
            XCTAssertEqual(instruction.neonLaneOp?.kind, .bif)
            guard case let .intrinsic(_, _, arguments) = instruction.operation else {
                return XCTFail("missing typed BIF")
            }
            XCTAssertEqual(arguments.count, 3)
        }
    }

    func testCompareSignednessPairOrderingAndBIFPreservation() throws {
        for kind: Lane.Kind in [.cmeq, .cmgt, .cmge, .cmhi, .cmhs, .cmtst] {
            let lane = try XCTUnwrap(Lane(kind: kind, isSigned: false, laneBits: 64, highHalf: false))
            let result = lane.evaluate(n: (.max, 0x8000_0000_0000_0000), m: (0, .max))
            XCTAssertEqual(result.low, [.cmhi, .cmhs].contains(kind) ? UInt64.max : 0)
            XCTAssertEqual(result.high, kind == .cmtst ? UInt64.max : 0)
            let equal = lane.evaluate(n: (.max, 0), m: (.max, 0))
            XCTAssertEqual(equal.high, [.cmeq, .cmge, .cmhs].contains(kind) ? UInt64.max : 0)
        }
        let pair = try XCTUnwrap(Lane(kind: .addp, isSigned: false, laneBits: 8,
            highHalf: false, activeBytes: 8))
        let paired = pair.evaluate(n: (0x0807_0605_0403_0201, .max),
            m: (0x100f_0e0d_0c0b_0a09, .max))
        XCTAssertEqual(paired.low, 0x1f1b_1713_0f0b_0703)
        XCTAssertEqual(paired.high, 0)
        let insert = try XCTUnwrap(Lane(kind: .bif, isSigned: false, laneBits: 8,
            highHalf: false, activeBytes: 8))
        let inserted = insert.evaluate(n: (0x5555_5555_5555_5555, .max),
            m: (0xf0f0_f0f0_f0f0_f0f0, .max), oldDestination: (0xaaaa_aaaa_aaaa_aaaa, .max))
        XCTAssertEqual(inserted.low, 0xa5a5_a5a5_a5a5_a5a5)
        XCTAssertEqual(inserted.high, 0)
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "bif", operandText: "v0.8h, v1.8h, v2.8h"))
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "cmhi", operandText: "v0.8b, v1.8b, #0"))
        XCTAssertEqual(MacIRBuilder.neonLaneOperation(mnemonic: "cmgt", operandText: "v0.8b, v1.8b, #0")?.semantics.kind, .cmgtz)
    }
}
