import XCTest
@testable import MacScope

final class NEONNarrowWideSemanticsTests: XCTestCase {
    typealias Lane = MacIRNEONLaneOp

    // Arm A64 XML 2025-12 raddhn_advsimd.xml#Operation and
    // subhn_advsimd.xml#Operation: rounded sum or difference, high half.
    func testBinaryNarrowBoundaryValues() throws {
        let cases: [(Lane.Kind, Int, UInt64, UInt64, UInt64)] = [
            (.raddhn, 8, 0, 0, 0), (.raddhn, 8, 127, 0, 0),
            (.raddhn, 8, 128, 0, 1), (.raddhn, 8, 65535, 0, 0),
            (.raddhn, 8, 65535, 65535, 0), (.raddhn, 16, 32768, 0, 1),
            (.raddhn, 32, 0x80000000, 0, 1), (.raddhn, 32, .max, .max, 0),
            (.subhn, 8, 0, 0, 0), (.subhn, 8, 0, 1, 255),
            (.subhn, 8, 255, 0, 0), (.subhn, 8, 256, 0, 1),
            (.subhn, 8, 0, 65535, 0), (.subhn, 16, 0, 1, 65535),
            (.subhn, 32, 0, 1, 0xffffffff), (.subhn, 32, .max, 0, 0xffffffff)
        ]
        for (kind, bits, a, b, expected) in cases {
            let op = try XCTUnwrap(Lane(kind: kind, isSigned: false, laneBits: bits, highHalf: false))
            let actual = op.evaluate(n: (a, 0), m: (b, 0), oldDestination: (.max, .max))
            XCTAssertEqual(actual.low & ((UInt64(1) << bits) - 1), expected)
            XCTAssertEqual(actual.high, 0)
            XCTAssertFalse(op.setsQC)
            XCTAssertFalse(op.saturates(n: (a, 0), m: (b, 0)))
        }
    }

    func testBinaryNarrowParserWidthsAndPreservedHalf() throws {
        for (bits, narrow, wide) in [(8, "8b", "8h"), (16, "4h", "4s"), (32, "2s", "2d")] {
            for mnemonic in ["raddhn", "subhn"] {
                let parsed = try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: mnemonic,
                    operandText: "v0.\(narrow), v1.\(wide), v2.\(wide)"))
                XCTAssertEqual(parsed.semantics.laneBits, bits)
                XCTAssertEqual(parsed.semantics.arity, 2)
                XCTAssertEqual(parsed.sources, ["v1", "v2"])
                let op = try XCTUnwrap(Lane(kind: parsed.semantics.kind, isSigned: false, laneBits: bits, highHalf: true))
                let actual = op.evaluate(n: (0, 0), m: (0, 0), oldDestination: (0x0123456789abcdef, .max))
                XCTAssertEqual(actual.low, 0x0123456789abcdef)
                XCTAssertEqual(actual.high, 0)
                XCTAssertEqual(op.arity, 3)
            }
        }
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "raddhn", operandText: "v0.8b, v1.8h, v2.4s"))
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "subhn", operandText: "v0.8b, v1.8h, v2.8h, #1"))
        XCTAssertNil(Lane(kind: .raddhn, isSigned: true, laneBits: 8, highHalf: false))
        XCTAssertNil(Lane(kind: .subhn, isSigned: false, laneBits: 64, highHalf: false))
    }

    // Arm smlsl_advsimd_vec.xml#Operation: upper SOURCE half, all destination
    // lanes updated. Unlike narrowing-2 forms it does not preserve low64.
    func testLongUpperSourceIsNotUpperDestination() throws {
        let op = try XCTUnwrap(Lane(kind: .mlsl, isSigned: true, laneBits: 32, highHalf: true))
        let actual = op.evaluate(n: (.max, 0x00000002ffffffff), m: (.max, 0x0000000300000002),
                                 oldDestination: (10, 20))
        XCTAssertEqual(actual.low, 12)
        XCTAssertEqual(actual.high, 14)
    }

    // Arm shrn_advsimd.xml#Operation; rshrn_advsimd.xml#Operation;
    // sqshrn_advsimd.xml#Operation. QC uses the shared lane predicate only.
    func testNarrowUpperHalfAndStickyPredicate() throws {
        for kind: Lane.Kind in [.shrn, .rshrn, .sqshrn] {
            let op = try XCTUnwrap(Lane(kind: kind, isSigned: false, laneBits: 8, highHalf: true, shift: 1))
            let actual = op.evaluate(n: (0x0100, 0), oldDestination: (0x123456789abcdef0, .max))
            XCTAssertEqual(actual.low, 0x123456789abcdef0)
            XCTAssertEqual(actual.high & 255, kind == .sqshrn ? 127 : 128)
            XCTAssertEqual(op.setsQC, kind == .sqshrn)
            XCTAssertEqual(op.saturates(n: (0x0100, 0), m: (0, 0)), kind == .sqshrn)
        }
    }

    // Each focused case checks the ordinary builder in both modes, then the
    // attached shared descriptor against literal hand-derived lane results.
    private func repeated(_ value: UInt64, bits: Int) -> UInt64 {
        var result: UInt64 = 0
        for offset in stride(from: 0, to: 64, by: bits) { result |= value << offset }
        return result
    }

    private func checkLift(_ mnemonic: String, operands: String, bits: Int,
                           n: Lane.Vector, m: Lane.Vector = (0, 0), old: Lane.Vector,
                           expected: Lane.Vector, file: StaticString = #filePath,
                           line: UInt = #line) throws {
        let source = MacIRSourceSpan(address: 0x1000, byteText: "", mnemonic: mnemonic, operands: operands)
        let admitted = try XCTUnwrap(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: mnemonic,
            operands: operands), file: file, line: line)
        let effects = MacIRBuilder.ssaEffects(for: source)
        XCTAssertTrue(effects.refusals.isEmpty, file: file, line: line)
        XCTAssertEqual(Set(effects.writes.map { $0.cell }), Set([32, 64]), file: file, line: line)
        XCTAssertEqual(effects.reads.contains(32), admitted.semantics.readsDestination, file: file, line: line)
        XCTAssertEqual(effects.reads.contains(64), admitted.semantics.readsDestination, file: file, line: line)
        XCTAssertFalse(effects.reads.contains(98), file: file, line: line)
        let baseRows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: mnemonic, operands: operands,
                           hasBreakpoint: false, comment: ""),
            InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
                           hasBreakpoint: false, comment: "")
        ]
        for ssa in [false, true] {
            var rows = baseRows
            if ssa {
                // A vector-only leaf is claimed by the legacy region before
                // SSA dispatch. Scalar arithmetic prevents that early claim.
                rows[1] = InstructionRow(address: 0x1008, bytes: "c0 03 5f d6", mnemonic: "ret",
                    operands: "", hasBreakpoint: false, comment: "")
                rows.insert(InstructionRow(address: 0x1004, bytes: "", mnemonic: "add",
                    operands: "x9, x9, #1", hasBreakpoint: false, comment: ""), at: 1)
            }
            let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa)
                .buildFunction(name: "narrow_long", startAddress: 0x1000, instructions: rows)
            XCTAssertEqual(function.ssaEnabled, ssa, file: file, line: line)
            let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1000 },
                                             file: file, line: line)
            let lane = try XCTUnwrap(instruction.neonLaneOp, file: file, line: line)
            XCTAssertEqual(lane, admitted.semantics, file: file, line: line)
            XCTAssertEqual(lane.laneBits, bits, file: file, line: line)
            guard case let .intrinsic(_, name, arguments) = instruction.operation else {
                return XCTFail("missing typed lane operation", file: file, line: line)
            }
            XCTAssertEqual(name, lane.intrinsicName, file: file, line: line)
            XCTAssertEqual(arguments.count, lane.arity, file: file, line: line)
            let actual = lane.evaluate(n: n, m: m, oldDestination: old)
            XCTAssertEqual(actual.low, expected.low, file: file, line: line)
            XCTAssertEqual(actual.high, expected.high, file: file, line: line)
            XCTAssertFalse(lane.setsQC, file: file, line: line)
        }
    }

    private func checkSignedSubtract(_ high: Bool, minimum: Bool, indexed: Bool = false) throws {
        for (bits, suffix, wide, negativeOne, minimumBits, negativeProduct) in [
            (8, "b", "8h", UInt64(0xff), UInt64(0x80), UInt64(0xff80)),
            (16, "h", "4s", UInt64(0xffff), UInt64(0x8000), UInt64(0xffff8000)),
            (32, "s", "2d", UInt64(0xffffffff), UInt64(0x80000000), UInt64(0xffffffff80000000))
        ] {
            if indexed && bits == 8 { continue }
            let a = repeated(minimum ? minimumBits : negativeOne, bits: bits)
            let b = repeated(minimum ? negativeOne : 2, bits: bits)
            // Unselected half is deliberately different. Both destination halves
            // are updated even for SMLSL2; neither is an insertion/keep half.
            let n: Lane.Vector = high ? (0, a) : (a, 0)
            let selected = minimum ? negativeOne : 2
            let m: Lane.Vector = indexed
                ? (bits == 16 ? selected << 32 : 0, bits == 32 ? selected : 0)
                : (high ? (0, b) : (b, 0))
            let old: Lane.Vector = minimum ? (0, 0)
                : (repeated(10, bits: bits * 2), repeated(20, bits: bits * 2))
            let expected: Lane.Vector = minimum
                ? (repeated(negativeProduct, bits: bits * 2), repeated(negativeProduct, bits: bits * 2))
                : (repeated(12, bits: bits * 2), repeated(22, bits: bits * 2))
            let narrow = "\((high ? 128 : 64) / bits)\(suffix)"
            let rhs = indexed ? "v2.\(suffix)[2]" : "v2.\(narrow)"
            try checkLift(high ? "smlsl2" : "smlsl",
                operands: "v0.\(wide), v1.\(narrow), \(rhs)", bits: bits,
                n: n, m: m, old: old, expected: expected)
        }
    }

    func testSMLSLNegativeProductBothModes() throws { try checkSignedSubtract(false, minimum: false) }
    func testSMLSLMinimumWrapBothModes() throws { try checkSignedSubtract(false, minimum: true) }
    func testSMLSLIndexedNegativeProductBothModes() throws { try checkSignedSubtract(false, minimum: false, indexed: true) }
    func testSMLSLIndexedMinimumWrapBothModes() throws { try checkSignedSubtract(false, minimum: true, indexed: true) }
    func testSMLSL2NegativeProductBothModes() throws { try checkSignedSubtract(true, minimum: false) }
    func testSMLSL2MinimumWrapBothModes() throws { try checkSignedSubtract(true, minimum: true) }

    private func checkNarrow(_ mnemonic: String, endpoint: Bool) throws {
        for (bits, suffix, wide, wideMaximum, narrowMaximum) in [
            (8, "b", "8h", UInt64(0xffff), UInt64(0xff)),
            (16, "h", "4s", UInt64(0xffffffff), UInt64(0xffff)),
            (32, "s", "2d", UInt64.max, UInt64(0xffffffff))
        ] {
            let high = mnemonic.hasSuffix("2")
            let rounded = mnemonic.hasPrefix("r")
            let shift = endpoint ? bits : 1
            let input = repeated(endpoint ? wideMaximum : 3, bits: bits * 2)
            // RShr(max, width, true) is 2^width, whose narrow low bits are zero.
            // RShr(3, 1, true) is 2; unrounded results are max and 1 respectively.
            let laneValue: UInt64 = endpoint ? (rounded ? 0 : narrowMaximum) : (rounded ? 2 : 1)
            let packed = repeated(laneValue, bits: bits)
            let old: Lane.Vector = (0x0123456789abcdef, 0xfedcba9876543210)
            let expected: Lane.Vector = high ? (old.low, packed) : (packed, 0)
            let narrow = "\((high ? 128 : 64) / bits)\(suffix)"
            try checkLift(mnemonic, operands: "v0.\(narrow), v1.\(wide), #\(shift)", bits: bits,
                          n: (input, input), old: old, expected: expected)
        }
    }

    func testRSHRNRoundingTieBothModes() throws { try checkNarrow("rshrn", endpoint: false) }
    func testRSHRNMaximumShiftBothModes() throws { try checkNarrow("rshrn", endpoint: true) }
    func testRSHRN2RoundingTieAndInsertionBothModes() throws { try checkNarrow("rshrn2", endpoint: false) }
    func testRSHRN2MaximumShiftAndInsertionBothModes() throws { try checkNarrow("rshrn2", endpoint: true) }
    func testSHRN2TruncationAndInsertionBothModes() throws { try checkNarrow("shrn2", endpoint: false) }
    func testSHRN2MaximumShiftAndInsertionBothModes() throws { try checkNarrow("shrn2", endpoint: true) }

    func testSHRN2InvalidOperandsRemainRefused() {
        for operands in ["v0.16b, v1.8h, #0", "v0.16b, v1.8h, #9",
                         "v0.8b, v1.8h, #1", "v0.16b, v1.4s, #1",
                         "v0.16b, v1.8h, #1, #1"] {
            XCTAssertNil(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: "shrn2", operands: operands))
        }
    }

    // Default mode keeps using the existing shared lane descriptor. These cases
    // also force actual SSA dispatch through checkLift's scalar instruction.
    private func checkHighNarrow(_ mnemonic: String, wrap: Bool) throws {
        // Literal wide inputs and extracted high halves, not a second evaluator.
        let subtract = mnemonic.hasPrefix("sub")
        let rounded = mnemonic.hasPrefix("radd")
        let high = mnemonic.hasSuffix("2")
        for (bits, suffix, wide, maximum, unit, subN0, subN1, rhs0, rhs1,
             subOut0, subOut1, addOut0, addOut1, roundN0, roundN1, roundOut0, roundOut1) in [
            (8, "b", "8h", UInt64(0xffff), UInt64(0x100),
             UInt64(0x1234), UInt64(0x9876), UInt64(0x0101), UInt64(0x0202),
             UInt64(0x11), UInt64(0x96), UInt64(0x13), UInt64(0x9a),
             UInt64(0x127f), UInt64(0x3480), UInt64(0x12), UInt64(0x35)),
            (16, "h", "4s", UInt64(0xffffffff), UInt64(0x10000),
             UInt64(0x12345678), UInt64(0x98765432), UInt64(0x01010101), UInt64(0x02020202),
             UInt64(0x1133), UInt64(0x9674), UInt64(0x1335), UInt64(0x9a78),
             UInt64(0x12347fff), UInt64(0x56788000), UInt64(0x1234), UInt64(0x5679)),
            (32, "s", "2d", UInt64.max, UInt64(0x100000000),
             UInt64(0x123456789abcdef0), UInt64(0x9876543210fedcba),
             UInt64(0x0101010101010101), UInt64(0x0202020202020202),
             UInt64(0x11335577), UInt64(0x96745230), UInt64(0x13355779), UInt64(0x9a785634),
             UInt64(0x123456787fffffff), UInt64(0x9abcdef080000000),
             UInt64(0x12345678), UInt64(0x9abcdef1))
        ] {
            let a0: UInt64 = wrap ? (subtract ? 0 : maximum) : (rounded ? roundN0 : subN0)
            let a1: UInt64 = wrap ? (subtract ? 1 : maximum) : (rounded ? roundN1 : subN1)
            let b0: UInt64 = wrap ? (rounded ? 0 : 1) : (rounded ? 0 : rhs0)
            let b1: UInt64 = wrap ? (rounded ? unit : maximum) : (rounded ? 0 : rhs1)
            let out0: UInt64 = wrap ? (subtract ? unit - 1 : 0)
                : (rounded ? roundOut0 : (subtract ? subOut0 : addOut0))
            let out1: UInt64 = wrap ? (subtract ? 0 : (rounded ? 1 : unit - 1))
                : (rounded ? roundOut1 : (subtract ? subOut1 : addOut1))
            // Both 64-bit source halves participate for base AND 2 forms.
            // Their different outputs catch using only the upper source half.
            let packed = (repeated(out0, bits: bits) & 0xffffffff)
                | (repeated(out1, bits: bits) << 32)
            let old: Lane.Vector = (0x0123456789abcdef, 0xfedcba9876543210)
            let expected: Lane.Vector = high ? (old.low, packed) : (packed, 0)
            let narrow = "\((high ? 128 : 64) / bits)\(suffix)"
            let operands = "v0.\(narrow), v1.\(wide), v2.\(wide)"
            let parsed = try XCTUnwrap(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: mnemonic,
                                                                           operands: operands))
            XCTAssertEqual(parsed.sources, ["v1", "v2"])
            XCTAssertEqual(parsed.destination, "v0")
            let source = MacIRSourceSpan(address: 0x1000, byteText: "", mnemonic: mnemonic, operands: operands)
            let reads = MacIRBuilder.ssaEffects(for: source).reads
            // Both source carriers are required, not only either physical half.
            for cell in [33, 65, 34, 66] { XCTAssertTrue(reads.contains(cell)) }
            try checkLift(mnemonic, operands: operands, bits: bits,
                          n: (repeated(a0, bits: bits * 2), repeated(a1, bits: bits * 2)),
                          m: (repeated(b0, bits: bits * 2), repeated(b1, bits: bits * 2)),
                          old: old, expected: expected)
        }
    }

    func testSUBHNHighBitsBothModes() throws { try checkHighNarrow("subhn", wrap: false) }
    func testSUBHNBorrowWrapBothModes() throws { try checkHighNarrow("subhn", wrap: true) }
    func testSUBHN2HighBitsAndKeepBothModes() throws { try checkHighNarrow("subhn2", wrap: false) }
    func testSUBHN2BorrowWrapAndKeepBothModes() throws { try checkHighNarrow("subhn2", wrap: true) }
    func testADDHNHighBitsBothModes() throws { try checkHighNarrow("addhn", wrap: false) }
    func testADDHNCarryWrapBothModes() throws { try checkHighNarrow("addhn", wrap: true) }
    func testADDHN2HighBitsAndKeepBothModes() throws { try checkHighNarrow("addhn2", wrap: false) }
    func testADDHN2CarryWrapAndKeepBothModes() throws { try checkHighNarrow("addhn2", wrap: true) }
    func testRADDHNRoundingBoundaryBothModes() throws { try checkHighNarrow("raddhn", wrap: false) }
    func testRADDHNRoundingWrapBothModes() throws { try checkHighNarrow("raddhn", wrap: true) }
    func testRADDHN2RoundingBoundaryAndKeepBothModes() throws { try checkHighNarrow("raddhn2", wrap: false) }
    func testRADDHN2RoundingWrapAndKeepBothModes() throws { try checkHighNarrow("raddhn2", wrap: true) }

    func testHighNarrowInvalidOperandsRemainRefused() {
        for mnemonic in ["subhn", "subhn2", "addhn", "addhn2", "raddhn", "raddhn2"] {
            let narrow = mnemonic.hasSuffix("2") ? "16b" : "8b"
            let wrongNarrow = mnemonic.hasSuffix("2") ? "8b" : "16b"
            for operands in ["v0.\(narrow), v1.8h, v2.4s",
                             "v0.\(wrongNarrow), v1.8h, v2.8h",
                             "v0.\(narrow), v1.8h, v2.8h, #1",
                             "v0.\(narrow), v1.8h"] {
                XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: mnemonic, operandText: operands))
                XCTAssertNil(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: mnemonic, operands: operands))
            }
        }
    }
}
