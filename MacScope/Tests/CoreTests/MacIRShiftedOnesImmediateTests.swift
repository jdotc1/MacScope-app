import XCTest
@testable import MacScope

final class MacIRShiftedOnesImmediateTests: XCTestCase {
    private func check(_ mnemonic: String, _ operands: String, bytes: String,
                       low: UInt64, high: UInt64,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let parsed = try XCTUnwrap(MacIRBuilder.neonMoveImmediate(mnemonic: mnemonic,
            operandText: operands), file: file, line: line)
        XCTAssertTrue(parsed.semantics.shiftingOnes, file: file, line: line)
        XCTAssertEqual(parsed.semantics.low, low, file: file, line: line)
        XCTAssertEqual(parsed.semantics.high, high, file: file, line: line)
        let source = MacIRSourceSpan(address: 0x1000, byteText: bytes,
                                    mnemonic: mnemonic, operands: operands)
        let exact = try XCTUnwrap(MacIRBuilder.ssaExactVector(source), file: file, line: line)
        guard case let .immediate(register, value) = exact else {
            return XCTFail("modified immediate lost its existing descriptor", file: file, line: line)
        }
        XCTAssertEqual(register, 0, file: file, line: line)
        XCTAssertEqual(value, parsed.semantics, file: file, line: line)
        let effects = MacIRBuilder.ssaEffects(for: source)
        XCTAssertTrue(effects.refusals.isEmpty, file: file, line: line)
        XCTAssertEqual(Set(effects.writes.map(\.cell)), Set([32, 64]), file: file, line: line)
        XCTAssertTrue(effects.reads.cells.isEmpty, file: file, line: line)
        for enabled in [false, true] {
            var rows = [InstructionRow(address: 0x1000, bytes: bytes, mnemonic: mnemonic,
                operands: operands, hasBreakpoint: false, comment: "")]
            rows.append(InstructionRow(address: 0x1004, bytes: "00 00 80 3d", mnemonic: "str",
                operands: "q0, [x0]", hasBreakpoint: false, comment: ""))
            if enabled {
                // Mixed scalar work prevents the vector-only leaf from bypassing SSA.
                rows.append(InstructionRow(address: 0x1008, bytes: "29 05 00 91", mnemonic: "add",
                    operands: "x9, x9, #1", hasBreakpoint: false, comment: ""))
            }
            rows.append(InstructionRow(address: enabled ? 0x100c : 0x1008, bytes: "c0 03 5f d6",
                mnemonic: "ret", operands: "", hasBreakpoint: false, comment: ""))
            let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: enabled)
                .buildFunction(name: "shifted_ones_immediate", startAddress: 0x1000, instructions: rows)
            XCTAssertEqual(function.ssaEnabled, enabled, file: file, line: line)
            let stored = try XCTUnwrap(function.instructions.compactMap { instruction -> MacIRValue? in
                guard instruction.source.address == 0x1004,
                      case let .store(value, _) = instruction.operation else { return nil }
                return value
            }.first, file: file, line: line)
            func hasUnavailable(_ value: MacIRValue) -> Bool {
                switch value {
                case let .unknown(name): return name.hasPrefix("unavailable_")
                case let .unary(_, inner): return hasUnavailable(inner)
                case let .binaryExpression(_, left, right): return hasUnavailable(left) || hasUnavailable(right)
                default: return false
                }
            }
            // A subsequent full128 consumer must see the new definition, not an
            // upper-lane tombstone left behind by the previously refused row.
            XCTAssertFalse(hasUnavailable(stored), file: file, line: line)
            let emitted = function.instructions.filter { $0.source.address == 0x1000 }
            XCTAssertFalse(emitted.contains { if case .unknown = $0.operation { return true }; return false },
                           file: file, line: line)
            if enabled {
                let info = try XCTUnwrap(function.ssaInfo, file: file, line: line)
                let row = try XCTUnwrap(info.sourceAddresses.firstIndex(of: 0x1000), file: file, line: line)
                for (cell, bits) in [(32, low), (64, high)] {
                    let id = try XCTUnwrap(info.plan.rowWriteBindings[row][cell], file: file, line: line)
                    let value = try XCTUnwrap(info.values[id], file: file, line: line)
                    if value == .immediate(0) {
                        XCTAssertEqual(bits, 0, file: file, line: line)
                    } else {
                        XCTAssertTrue(emitted.contains {
                            if case let .assign(destination, source) = $0.operation {
                                return destination == value && source == .immediate(Int64(bitPattern: bits))
                            }
                            return false
                        }, file: file, line: line)
                    }
                }
            } else {
                XCTAssertTrue(emitted.contains { $0.neonImmediate == parsed.semantics }, file: file, line: line)
            }
        }
    }

    // Arm mvni_advsimd Operation inverts AdvSIMDExpandImm's repeated lane.
    // cmode=1100 inserts eight ones; inversion must happen after insertion.
    func testInvertedShiftedOnesEightBothModes() throws {
        try check("mvni", "v0.4s, #7, msl #8", bytes: "e0 c4 00 6f",
                  low: 0xfffff800fffff800, high: 0xfffff800fffff800)
    }

    // cmode=1101 inserts sixteen ones; Q=0 clears the whole upper64.
    func testInvertedShiftedOnesSixteenMaximumBothModes() throws {
        try check("mvni", "v0.2s, #255, msl #16", bytes: "e0 d7 07 2f",
                  low: 0xff000000ff000000, high: 0)
    }

    func testMoveShiftedOnesEightZeroBothModes() throws {
        try check("movi", "v0.2s, #0, msl #8", bytes: "00 c4 00 0f",
                  low: 0x000000ff000000ff, high: 0)
    }

    func testMoveShiftedOnesSixteenZeroBothModes() throws {
        try check("movi", "v0.4s, #0, msl #16", bytes: "00 d4 00 4f",
                  low: 0x0000ffff0000ffff, high: 0x0000ffff0000ffff)
    }

    func testLogicalShiftRemainsDifferentFromShiftedOnes() throws {
        let lsl = try XCTUnwrap(MacIRBuilder.neonMoveImmediate(mnemonic: "mvni",
            operandText: "v0.4s, #7, lsl #8"))
        XCTAssertFalse(lsl.semantics.shiftingOnes)
        XCTAssertEqual(lsl.semantics.low, 0xfffff8fffffff8ff)
        XCTAssertEqual(lsl.semantics.high, lsl.semantics.low)
        let movi = try XCTUnwrap(MacIRBuilder.neonMoveImmediate(mnemonic: "movi",
            operandText: "v0.4s, #7, lsl #8"))
        XCTAssertEqual(movi.semantics.low, 0x0000070000000700)
    }

    func testMalformedShiftedOnesRefusedBothModes() {
        let invalid = ["v0.8h, #7, msl #8", "v0.16b, #7, msl #8",
                       "v0.4s, #7, msl #0", "v0.4s, #7, msl #24",
                       "v0.4s, #256, msl #8", "v0.4s, #7, msl #8 extra",
                       "v0.4s, #7, asr #8"]
        for operands in invalid {
            XCTAssertNil(MacIRBuilder.neonMoveImmediate(mnemonic: "mvni", operandText: operands))
            for enabled in [false, true] {
                let rows = [
                    InstructionRow(address: 0x1000, bytes: "e0 c4 00 6f", mnemonic: "mvni",
                        operands: operands, hasBreakpoint: false, comment: ""),
                    InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret",
                        operands: "", hasBreakpoint: false, comment: "")
                ]
                let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: enabled)
                    .buildFunction(name: "invalid_shifted_ones", startAddress: 0x1000, instructions: rows)
                XCTAssertTrue(function.instructions.contains {
                    if case .unknown = $0.operation { return $0.source.address == 0x1000 }; return false
                })
            }
        }
    }

    func testByteTextDisagreementCannotClaimExactImmediate() {
        for operands in ["v0.4s, #7, msl #16", "v0.4s, #7, lsl #8", "v1.4s, #7, msl #8"] {
            XCTAssertNil(MacIRBuilder.ssaExactVector(.init(address: 0x1000, byteText: "e0 c4 00 6f",
                mnemonic: "mvni", operands: operands)))
        }
        XCTAssertNil(MacIRBuilder.ssaExactVector(.init(address: 0x1000, byteText: "e0 c4 00 6f",
            mnemonic: "movi", operands: "v0.4s, #7, msl #8")))
    }
}
