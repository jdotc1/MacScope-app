import XCTest
@testable import MacScope

final class MacIRNEONBitClearImmediateTests: XCTestCase {
    private func source(_ operands: String, address: UInt64 = 0x3d224) -> MacIRSourceSpan {
        MacIRSourceSpan(address: address, byteText: "", mnemonic: "bic", operands: operands)
    }

    func testObservedTransformPairRetainsProductAndReplicatesMask() throws {
        // Native _jpeg_fdct_ifast, 0x3d224: bic.4s v12, #0xfe, lsl #8.
        // Before: q12_2 = 0xfe & ~(lsl #8), which discards the product.
        // Official src/jfdctfst.c:108,174-176: MULTIPLY/DESCALE consumes the
        // varying tmp10/tmp12 products. The mask clears bits 9...15 of each
        // 32-bit lane; it never replaces those products with a constant.
        let row = source("v12.4s, #0xfe, lsl #8")
        let parsed = try XCTUnwrap(MacIRBuilder.neonBitClearImmediate(
            mnemonic: row.mnemonic, operandText: row.operands))
        XCTAssertEqual(parsed.mask.low, 0x0000fe000000fe00)
        XCTAssertEqual(parsed.mask.high, 0x0000fe000000fe00)
        var state = BuilderState(parameters: [])
        let old = state.readRegister("q12")
        let effects = MacIRBuilder.liftNEONBitClearImmediate(parsed, source: row, state: &state)
        XCTAssertEqual(effects.count, 2)
        XCTAssertEqual(effects.map(\.source.address), [0x3d224, 0x3d224])
        guard case let .intrinsic(optionalMask, _, constantArguments) = effects[0].operation,
              case let .intrinsic(destination, _, arguments) = effects[1].operation else {
            return XCTFail("Expected a typed constant followed by typed logical BIC")
        }
        let mask = try XCTUnwrap(optionalMask)
        XCTAssertTrue(constantArguments.isEmpty)
        XCTAssertEqual(arguments, [old, mask])
        XCTAssertNotEqual(destination, old)
        XCTAssertEqual(effects[0].neonImmediate, parsed.mask)
        let logical = try XCTUnwrap(effects[1].neonLogical)
        XCTAssertEqual(logical.kind, .bic)
        XCTAssertEqual(logical.width, .bytes16)
        XCTAssertEqual(logical.evaluateHalf(n: 0x12345678abcdef01,
            m: parsed.mask.low, oldDestination: 0), 0x12340078abcd0101)
        XCTAssertEqual(logical.evaluateHalf(n: 0, m: parsed.mask.low, oldDestination: 0), 0)
        XCTAssertEqual(logical.evaluateHalf(n: UInt64.max, m: parsed.mask.high,
            oldDestination: 0), 0xffff01ffffff01ff)
    }

    func testLegalShapesAndEveryShift() throws {
        for (shape, bits, bytes) in [("8h", 16, 16), ("4s", 32, 16)] {
            for shift in stride(from: 0, to: bits, by: 8) {
                let parsed = try XCTUnwrap(MacIRBuilder.neonBitClearImmediate(mnemonic: "bic",
                    operandText: "v31.\(shape), #255, lsl #\(shift)"))
                XCTAssertEqual(parsed.mask.laneBits, bits)
                XCTAssertEqual(parsed.mask.activeBytes, bytes)
                XCTAssertEqual(parsed.mask.shift, shift)
                XCTAssertEqual(parsed.mask.high, bytes == 16 ? parsed.mask.low : 0)
            }
        }
        XCTAssertNotNil(MacIRBuilder.neonBitClearImmediate(mnemonic: "bic", operandText: "v0.4s, #0"))
    }

    func testMalformedAndOtherFamiliesDoNotEnterImmediatePath() {
        for operands in ["v0.4h, #1", "v0.2s, #1", "v0.16b, #1", "v0.2d, #1", "v32.4s, #1", "v01.4s, #1",
                         "v0.4s, #256", "v0.4s, #-1", "v0.4s, #1, lsl #32",
                         "v0.4h, #1, lsl #16", "v0.4s, #1, lsl #7",
                         "v0.4s, #1, msl #8", "v0.4s,,#1", "v0.4s, #1,",
                         "x0, x1, x2", "v0.16b, v1.16b, v2.16b"] {
            XCTAssertNil(MacIRBuilder.neonBitClearImmediate(mnemonic: "bic", operandText: operands), operands)
        }
        XCTAssertNil(MacIRBuilder.neonBitClearImmediate(mnemonic: "orr", operandText: "v0.4s, #1"))
        XCTAssertNotNil(MacIRBuilder.neonLogical(mnemonic: "bic", operandText: "v0.16b, v1.16b, v2.16b"))
    }

    func testSSAReadsBothOldHalvesAndDefinesBothNewHalves() {
        let effects = MacIRBuilder.ssaEffects(for: source("v12.4s, #0xfe, lsl #8"))
        XCTAssertTrue(effects.reads.contains(44))
        XCTAssertTrue(effects.reads.contains(76))
        XCTAssertTrue(effects.writes.contains { $0.cell == 44 })
        XCTAssertTrue(effects.writes.contains { $0.cell == 76 })
    }

    func testUnavailableInputIsNotTurnedIntoKnownBits() throws {
        let row = source("v12.4s, #0xfe, lsl #8")
        let parsed = try XCTUnwrap(MacIRBuilder.neonBitClearImmediate(mnemonic: "bic", operandText: row.operands))
        var state = BuilderState(parameters: [])
        state.callUnavailableRegisterValues.insert("q12")
        let effects = MacIRBuilder.liftNEONBitClearImmediate(parsed, source: row, state: &state)
        guard case let .intrinsic(_, _, arguments) = effects[1].operation else { return XCTFail() }
        XCTAssertEqual(arguments.first, .unknown("unavailable_q12"))
    }

    func testBuilderRoutesKeepTypedEffectsAndScalarBIC() {
        for ssa in [false, true] {
          for forceOrdinaryRoute in [false, true] {
            // Scalar BIC already excludes the branch-free vector-region route.
            // Exercise ordinary SSA/legacy lowering both with and without an
            // undecoded prefix; do not infer region coverage from this flag.
            let operations = (forceOrdinaryRoute ? [("unknown", "")] : [])
                + [("bic", "v12.4s, #0xfe, lsl #8"), ("bic", "x0, x1, x2"), ("ret", "")]
            let start: UInt64 = forceOrdinaryRoute ? 0x3d220 : 0x3d224
            let rows = operations.enumerated().map { index, operation in
                InstructionRow(address: start + UInt64(index * 4), bytes: "",
                    mnemonic: operation.0, operands: operation.1, hasBreakpoint: false, comment: nil)
            }
            let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "_mask_fixture",
                startAddress: start, instructions: rows)
            let route = "ssa=\(ssa), forceOrdinaryRoute=\(forceOrdinaryRoute)"
            let actual = "actual=\(String(describing: function.instructions.map(\.operation)))"
            if ssa {
                XCTAssertNotNil(function.ssaInfo,
                    "Ordinary SSA fixture must not fall back to legacy lowering (\(route)); \(actual)")
            }
            let vector = function.instructions.filter { $0.source.address == 0x3d224 }
            XCTAssertGreaterThanOrEqual(vector.count, 2, "\(route); \(actual)")
            XCTAssertEqual(vector.filter { $0.neonImmediate != nil }.count, 1, "\(route); \(actual)")
            XCTAssertEqual(vector.filter { $0.neonLogical != nil }.count, 1, "\(route); \(actual)")
            let scalar = function.instructions.filter { $0.source.address == 0x3d228 }
            let diagnostic = "Scalar BIC changed (\(route)); actual=\(String(describing: scalar.map(\.operation)))"
            XCTAssertEqual(scalar.count, 1, diagnostic)
            XCTAssertNil(scalar.first?.neonLogical, diagnostic)
            guard case let .binary(destination, op, _, right) = scalar.first?.operation,
                  case let .register(name, _) = destination,
                  case let .unary(complement, _) = right else {
                XCTFail(diagnostic)
                continue
            }
            XCTAssertEqual(name, "x0", diagnostic)
            XCTAssertEqual(op, "&", diagnostic)
            XCTAssertEqual(complement, "~", diagnostic)
          }
        }
    }
}
