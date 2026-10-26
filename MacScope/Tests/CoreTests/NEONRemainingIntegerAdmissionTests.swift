import XCTest
@testable import MacScope

final class NEONRemainingIntegerAdmissionTests: XCTestCase {
    typealias Vector = MacIRNEONLaneOp.Vector

    // Packing only: this helper does not implement any instruction arithmetic.
    private func vector(_ lane: Int64, bits: Int, bytes: Int = 16) -> Vector {
        var result: Vector = (0, 0)
        let mask: UInt64 = bits == 64 ? .max : (UInt64(1) << bits) - 1
        for index in 0..<(bytes * 8 / bits) {
            let value = (UInt64(bitPattern: lane) & mask) << ((index * bits) % 64)
            if index * bits < 64 { result.low |= value } else { result.high |= value }
        }
        return result
    }

    private func arrangement(_ bits: Int, _ bytes: Int) -> String {
        "\(bytes * 8 / bits)\([8: "b", 16: "h", 32: "s", 64: "d"][bits]!)"
    }

    private func check(_ mnemonic: String, _ operands: String, n: Vector, m: Vector = (0, 0),
                       old: Vector = (0x123456789abcdef0, 0xfedcba9876543210), expected: Vector,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let label = "\(mnemonic) \(operands)"
        let parsed = try XCTUnwrap(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: mnemonic, operands: operands), label,
                                  file: file, line: line)
        let source = MacIRSourceSpan(address: 0x1000, byteText: "", mnemonic: mnemonic, operands: operands)
        let effects = MacIRBuilder.ssaEffects(for: source)
        XCTAssertTrue(effects.refusals.isEmpty, label, file: file, line: line)
        XCTAssertEqual(Set(effects.writes.map { $0.cell }), Set([32, 64]), label, file: file, line: line)
        XCTAssertEqual(effects.reads.contains(32), parsed.semantics.readsDestination, label, file: file, line: line)
        XCTAssertEqual(effects.reads.contains(64), parsed.semantics.readsDestination, label, file: file, line: line)
        XCTAssertTrue(effects.reads.contains(33), label, file: file, line: line)
        XCTAssertTrue(effects.reads.contains(65), label, file: file, line: line)
        XCTAssertFalse(effects.reads.contains(96), label, file: file, line: line)
        XCTAssertFalse(effects.reads.contains(97), label, file: file, line: line)
        XCTAssertFalse(effects.reads.contains(98), label, file: file, line: line)
        XCTAssertFalse(parsed.semantics.setsQC, label, file: file, line: line)
        let actual = parsed.semantics.evaluate(n: n, m: m, oldDestination: old)
        XCTAssertEqual(actual.low, expected.low, label, file: file, line: line)
        XCTAssertEqual(actual.high, expected.high, label, file: file, line: line)
    }

    func testSameWidthLiteralOraclesEveryArrangement() throws {
        // Arm add_advsimd.xml#Operation and sub_advsimd.xml#Operation.
        // Six independent lane answers, including carry/borrow and negative inputs.
        let rows: [(Int64, Int64, Int64, Int64)] = [
            (0, 0, 0, 0), (1, 2, 3, -1), (-1, 1, 0, -2),
            (-2, -3, -5, 1), (127, -1, 126, 128), (-128, 1, -127, -129)
        ]
        for (bits, bytes) in [(8, 8), (8, 16), (16, 8), (16, 16), (32, 8), (32, 16), (64, 16)] {
            let a = arrangement(bits, bytes)
            for (n, m, sum, difference) in rows {
                try check("add", "v0.\(a), v1.\(a), v2.\(a)", n: vector(n, bits: bits), m: vector(m, bits: bits),
                          expected: vector(sum, bits: bits, bytes: bytes))
                try check("sub", "v0.\(a), v1.\(a), v2.\(a)", n: vector(n, bits: bits), m: vector(m, bits: bits),
                          expected: vector(difference, bits: bits, bytes: bytes))
            }
        }
    }

    func testSignedLongLiteralOraclesEveryArrangementAndElementIndex() throws {
        // Arm smull_advsimd_vec.xml#Operation, smull_advsimd_elt.xml#Operation,
        // saddl_advsimd.xml#Operation and ssubl_advsimd.xml#Operation.
        let rows: [(Int64, Int64, Int64, Int64, Int64)] = [
            (0, 0, 0, 0, 0), (1, 2, 2, 3, -1), (-1, 3, -3, 2, -4),
            (2, -2, -4, 0, 4), (-2, -3, 6, -5, 1), (127, -1, -127, 126, 128)
        ]
        for bits in [8, 16, 32] {
            for high in [false, true] {
                let suffix = high ? "2" : ""
                let wide = arrangement(bits * 2, 16)
                let narrow = arrangement(bits, high ? 16 : 8)
                for (n, m, product, sum, difference) in rows {
                    let nHalf = vector(n, bits: bits, bytes: 8).low
                    let mHalf = vector(m, bits: bits, bytes: 8).low
                    // Nonselected halves contain different values to detect wrong Q selection.
                    let nv: Vector = high ? (0x5555555555555555, nHalf) : (nHalf, 0x5555555555555555)
                    let mv: Vector = high ? (0x3333333333333333, mHalf) : (mHalf, 0x3333333333333333)
                    let operands = "v0.\(wide), v1.\(narrow), v2.\(narrow)"
                    try check("smull\(suffix)", operands, n: nv, m: mv, expected: vector(product, bits: bits * 2))
                    try check("saddl\(suffix)", operands, n: nv, m: mv, expected: vector(sum, bits: bits * 2))
                    try check("ssubl\(suffix)", operands, n: nv, m: mv, expected: vector(difference, bits: bits * 2))
                    if bits == 8 { continue }
                    for index in 0..<(128 / bits) {
                        // Exactly the selected element carries m; poison every other element.
                        var indexed: Vector = (0x5555555555555555, 0x5555555555555555)
                        let mask = (UInt64(1) << bits) - 1
                        let shift = (index * bits) % 64
                        let field = (UInt64(bitPattern: m) & mask) << shift
                        if index * bits < 64 { indexed.low = (indexed.low & ~(mask << shift)) | field }
                        else { indexed.high = (indexed.high & ~(mask << shift)) | field }
                        let letter = bits == 16 ? "h" : "s"
                        try check("smull\(suffix)", "v0.\(wide), v1.\(narrow), v2.\(letter)[\(index)]",
                                  n: nv, m: indexed, expected: vector(product, bits: bits * 2))
                    }
                }
            }
        }
    }

    func testImmediateShiftLiteralOraclesEveryArrangement() throws {
        // Arm shl_advsimd.xml#Operation, sshr_advsimd.xml#Operation,
        // ssra_advsimd.xml#Operation and srsra_advsimd.xml#Operation.
        // n, old lane, SHL #1, SSHR #1, SSRA #1, SRSRA #1.
        let rows: [(Int64, Int64, Int64, Int64, Int64, Int64)] = [
            (0, 7, 0, 0, 7, 7), (1, 7, 2, 0, 7, 8),
            (-1, 7, -2, -1, 6, 7), (3, -2, 6, 1, -1, 0),
            (-3, -2, -6, -2, -4, -3), (126, -1, 252, 63, 62, 62)
        ]
        for (bits, bytes) in [(8, 8), (8, 16), (16, 8), (16, 16), (32, 8), (32, 16), (64, 16)] {
            let a = arrangement(bits, bytes)
            for (n, old, left, right, accumulated, rounded) in rows {
                for (mnemonic, result) in [("shl", left), ("sshr", right), ("ssra", accumulated), ("srsra", rounded)] {
                    try check(mnemonic, "v0.\(a), v1.\(a), #1", n: vector(n, bits: bits), old: vector(old, bits: bits),
                              expected: vector(result, bits: bits, bytes: bytes))
                }
            }
            // Boundary immediates: identity and full-width signed shift; no host shift-by-width oracle.
            try check("shl", "v0.\(a), v1.\(a), #0", n: vector(-3, bits: bits), expected: vector(-3, bits: bits, bytes: bytes))
            try check("sshr", "v0.\(a), v1.\(a), #\(bits)", n: vector(-3, bits: bits), expected: vector(-1, bits: bits, bytes: bytes))
            try check("ssra", "v0.\(a), v1.\(a), #\(bits)", n: vector(-3, bits: bits), old: vector(7, bits: bits),
                      expected: vector(6, bits: bits, bytes: bytes))
            try check("srsra", "v0.\(a), v1.\(a), #\(bits)", n: vector(-3, bits: bits), old: vector(7, bits: bits),
                      expected: vector(7, bits: bits, bytes: bytes))
        }
    }

    func testSubtractHighNarrowLiteralOraclesEveryArrangement() throws {
        // Arm subhn_advsimd.xml#Operation: subtract at wide width, keep high half;
        // SUBHN2 preserves the original low 64 bits exactly.
        // Six independently specified lane answers valid for 16/32/64-bit wide inputs.
        let rows: [(Int64, Int64, Int64)] = [
            (0, 0, 0), (0, 1, -1), (1, 0, 0), (-1, 0, -1), (-1, -1, 0), (-2, -1, -1)
        ]
        let old: Vector = (0x123456789abcdef0, 0xfedcba9876543210)
        for bits in [8, 16, 32] {
            for (n, m, answer) in rows {
                try check("subhn2", "v0.\(arrangement(bits, 16)), v1.\(arrangement(bits * 2, 16)), v2.\(arrangement(bits * 2, 16))",
                          n: vector(n, bits: bits * 2), m: vector(m, bits: bits * 2), old: old,
                          expected: (old.low, vector(answer, bits: bits, bytes: 8).low))
            }
        }
    }

    func testExactComparisonAndNarrowingLiteralOracles() throws {
        // Arm cmeq_advsimd_reg.xml#Operation, cmhi_advsimd.xml#Operation,
        // xtn_advsimd.xml#Operation. Comparisons return all-one true lanes.
        let comparisons: [(Int64, Int64, Int64, Int64)] = [
            (0, 0, -1, 0), (1, 0, 0, -1), (0, 1, 0, 0),
            (-1, 1, 0, -1), (-1, -1, -1, 0), (-2, -1, 0, 0)
        ]
        for (n, m, equality, higher) in comparisons {
            try check("cmeq", "v0.4s, v1.4s, v2.4s", n: vector(n, bits: 32), m: vector(m, bits: 32),
                      expected: vector(equality, bits: 32))
            try check("cmhi", "v0.8h, v1.8h, v2.8h", n: vector(n, bits: 16), m: vector(m, bits: 16),
                      expected: vector(higher, bits: 16))
        }
        for (n, low) in [(Int64(0), Int64(0)), (1, 1), (255, 255), (256, 0), (-1, 255), (-256, 0)] {
            try check("xtn", "v0.8b, v1.8h", n: vector(n, bits: 16), expected: vector(low, bits: 8, bytes: 8))
        }
    }

    func testExactPairwiseLiteralOracles() throws {
        // Arm addp_advsimd_vec.xml#Operation. Different first and second source
        // lanes prove the source boundary, while the last two rows prove pairing.
        let rows: [(Vector, Vector, Vector)] = [
            ((0, 0), (0, 0), (0, 0)),
            ((0x0101010101010101, 0x0101010101010101), (0x0202020202020202, 0x0202020202020202),
             (0x0202020202020202, 0x0404040404040404)),
            ((0xffffffffffffffff, 0xffffffffffffffff), (0, 0), (0xfefefefefefefefe, 0)),
            ((0x8080808080808080, 0x8080808080808080), (0x7f7f7f7f7f7f7f7f, 0x7f7f7f7f7f7f7f7f),
             (0, 0xfefefefefefefefe)),
            ((0x0807060504030201, 0x100f0e0d0c0b0a09), (0x1817161514131211, 0x201f1e1d1c1b1a19),
             (0x1f1b17130f0b0703, 0x3f3b37332f2b2723)),
            ((0x0100010001000100, 0x0302030203020302), (0x0504050405040504, 0x0706070607060706),
             (0x0505050501010101, 0x0d0d0d0d09090909))
        ]
        for (n, m, expected) in rows {
            try check("addp", "v0.16b, v1.16b, v2.16b", n: n, m: m, expected: expected)
        }
    }

    func testActualSSAEmissionPreservesDescriptorsAndAliasInputs() throws {
        let forms: [(String, String)] = [
            ("add", "v0.4h, v0.4h, v0.4h"), ("sub", "v0.8h, v0.8h, v0.8h"),
            ("smull", "v0.4s, v0.4h, v0.h[1]"), ("smull2", "v0.4s, v0.8h, v0.h[7]"),
            ("saddl", "v0.4s, v0.4h, v0.4h"), ("saddl2", "v0.4s, v0.8h, v0.8h"),
            ("ssubl", "v0.4s, v0.4h, v0.4h"), ("ssubl2", "v0.4s, v0.8h, v0.8h"),
            ("shl", "v0.8b, v0.8b, #1"), ("sshr", "v0.2d, v0.2d, #64"),
            ("ssra", "v0.2d, v0.2d, #1"), ("srsra", "v0.8h, v0.8h, #1"),
            ("subhn2", "v0.8h, v0.4s, v0.4s"), ("cmeq", "v0.4s, v0.4s, v0.4s"),
            ("cmhi", "v0.8h, v0.8h, v0.8h"), ("addp", "v0.16b, v0.16b, v0.16b"),
            ("xtn", "v0.8b, v0.8h")
        ]
        for (mnemonic, operands) in forms {
            func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
                InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
                               hasBreakpoint: false, comment: nil)
            }
            // BLR vetoes the vector-region route, selecting the actual SSA adapter.
            let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true)
                .buildFunction(name: "integer_lane_alias", startAddress: 0x1000,
                               instructions: [row(0x1000, mnemonic, operands), row(0x1004, "blr", "x8"), row(0x1008, "ret", "")])
            XCTAssertTrue(function.ssaEnabled, mnemonic)
            let info = try XCTUnwrap(function.ssaInfo, mnemonic)
            let parsed = try XCTUnwrap(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: mnemonic, operands: operands))
            let numeric = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1000 && $0.neonLaneOp != nil }, mnemonic)
            XCTAssertEqual(numeric.neonLaneOp, parsed.semantics, mnemonic)
            XCTAssertFalse(function.refusals.contains { $0.scope == .row(0x1000) }, mnemonic)
            guard case let .intrinsic(destination, name, arguments) = numeric.operation else {
                XCTFail("Expected typed lane intrinsic: \(mnemonic)"); continue
            }
            XCTAssertEqual(name, parsed.semantics.intrinsicName, mnemonic)
            XCTAssertEqual(arguments.count, parsed.semantics.arity, mnemonic)
            let output = try XCTUnwrap(destination, mnemonic)
            XCTAssertFalse(arguments.contains(output), "Aliased inputs must be read before writing the output")
            for (cell, projection) in [(32, "__ssa_low64"), (64, "__ssa_high64")] {
                let readID = try XCTUnwrap(info.plan.rowReadBindings[0][cell], mnemonic)
                let writeID = try XCTUnwrap(info.plan.rowWriteBindings[0][cell], mnemonic)
                XCTAssertNotEqual(readID, writeID, mnemonic)
                let value = try XCTUnwrap(info.values[writeID], mnemonic)
                XCTAssertTrue(function.instructions.contains {
                    guard case let .assign(destination, .unary(op, whole)) = $0.operation else { return false }
                    return destination == value && op == projection && whole == output
                }, mnemonic)
            }
        }
    }

    func testMalformedAndScalarFormsDoNotAcquireLaneAdmission() {
        for (mnemonic, operands) in [
            ("cmeq", "v0.8h, v1.8h, v2.8h"), ("cmeq", "v0.4s, v1.4s, #0"),
            ("cmhi", "v0.4s, v1.4s, v2.4s"), ("addp", "v0.8b, v1.8b, v2.8b"),
            ("xtn", "v0.4h, v1.4s"), ("add", "x0, x1, x2"), ("sub", "v0.8h, v1.4h, v2.8h"),
            ("smull", "v0.4s, v1.4h, v16.h[0]"), ("smull2", "v0.4s, v1.4h, v2.4h"),
            ("saddl", "v0.4s, v1.8h, v2.8h"), ("ssubl2", "v0.8h, v1.8b, v2.8b"),
            ("shl", "v0.8h, v1.8h, #16"), ("sshr", "v0.2d, v1.2d, #0"),
            ("ssra", "v0.4h, v1.4h, #17"), ("srsra", "v0.8h, v1.8h, #-1"),
            ("subhn2", "v0.4h, v1.4s, v2.4s"), ("subhn2", "v0.8h, v1.4s, v2.2d")
        ] {
            XCTAssertNil(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: mnemonic, operands: operands), mnemonic)
        }
    }
}
