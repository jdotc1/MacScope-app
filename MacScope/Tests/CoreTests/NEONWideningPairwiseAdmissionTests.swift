import Foundation
import XCTest
@testable import MacScope

final class NEONWideningPairwiseAdmissionTests: XCTestCase {
    private func row(_ address: UInt64, _ bytes: String, _ mnemonic: String, _ operands: String) -> InstructionRow {
        .init(address: address, bytes: bytes, mnemonic: mnemonic, operands: operands,
              hasBreakpoint: false, comment: nil)
    }

    /// Focused interpretation of the actual emitted typed operation and SSA
    /// split assignments. This is not the whole-list oracle: that validator's
    /// standalone widening family intentionally accepts only vN snapshots.
    /// No source mnemonic, operands, instruction bytes or intrinsic name are
    /// consulted for arithmetic, and no product instruction is rewritten.
    private func interpret(_ function: MacIRFunction, sourceIndex: Int,
                           old: UInt64, oldHigh: UInt64? = nil,
                           narrowLow: UInt64 = .max, narrowHigh: UInt64 = .max) throws -> A64MachineState {
        var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
            from: Data("{}".utf8)))
        state.v[2] = .init(low: old, high: oldHigh ?? old)
        state.v[sourceIndex] = .init(low: narrowLow, high: narrowHigh)
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        for instruction in function.instructions {
            if let descriptor = instruction.neonWideningPairwise {
                XCTAssertEqual(descriptor.kind, .uadalp)
                XCTAssertEqual(descriptor.sourceElementBytes, 1)
                XCTAssertEqual(descriptor.activeBytes, 16)
                guard case let .intrinsic(destination?, _, arguments) = instruction.operation,
                      arguments.count == 2 else { throw MacIRConcreteEvaluator.Failure.unsupported("typed UADALP shape") }
                // Independent byte-pair arithmetic; read BOTH snapshots first.
                let n = try evaluator.evaluate(arguments[0])
                let d = try evaluator.evaluate(arguments[1])
                XCTAssertEqual(n.width, 128); XCTAssertEqual(d.width, 128)
                var result: [UInt64] = []
                for (bytes, accumulator) in [(n.bits, d.bits), (n.high, d.high)] {
                    var half: UInt64 = 0
                    for lane in 0..<4 {
                        let shift = lane * 16
                        let a = (bytes >> shift) & 255
                        let b = (bytes >> (shift + 8)) & 255
                        let prior = (accumulator >> shift) & 65535
                        half |= ((a + b + prior) & 65535) << shift
                    }
                    result.append(half)
                }
                try evaluator.write(destination, .init(bits: result[0], width: 128,
                    kind: .unsigned, high: result[1]))
            } else {
                switch instruction.operation {
                case let .assign(destination, value):
                    let value = try evaluator.evaluate(value)
                    try evaluator.write(destination, value)
                case let .binary(destination, op, left, right):
                    let value = try evaluator.evaluate(.binaryExpression(op: op, left: left, right: right))
                    try evaluator.write(destination, value)
                case .returnValue: break // No new authority for the return contract.
                case .intrinsic(nil, "nop", let arguments) where arguments.isEmpty: break
                default: throw MacIRConcreteEvaluator.Failure.unsupported("outside focused typed interpretation")
                }
            }
        }
        return evaluator.state
    }

    private func assertValues(ordinary: Bool, sourceIndex: Int, old: UInt64,
                              expected: UInt64, file: StaticString = #filePath, line: UInt = #line) throws {
        for ssa in [false, true] {
            var rows: [InstructionRow] = []
            if ordinary {
                // Scalar arithmetic prevents the earlier general-vector leaf
                // route from swallowing the actual ordinary SSA/legacy test.
                rows.append(row(0x1000, "08 01 00 91", "add", "x8, x8, #0"))
            }
            let address: UInt64 = ordinary ? 0x1004 : 0x1000
            rows.append(row(address, sourceIndex == 2 ? "42 68 20 6e" : "22 68 20 6e",
                "uadalp", "v2.8h, v\(sourceIndex).16b"))
            rows.append(row(address + 4, "c0 03 5f d6", "ret", ""))
            let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "pairwise", instructions: rows)
            XCTAssertEqual(function.ssaEnabled, ordinary && ssa, file: file, line: line)
            XCTAssertEqual(function.instructions.filter { $0.neonWideningPairwise != nil }.count, 1,
                           file: file, line: line)
            let result = try interpret(function, sourceIndex: sourceIndex, old: old)
            XCTAssertEqual(result.v[2].low, expected, file: file, line: line)
            XCTAssertEqual(result.v[2].high, expected, file: file, line: line)
        }
    }

    func testGeneralRegionWrapUsesOldDestinationInBothRequestedModes() throws {
        try assertValues(ordinary: false, sourceIndex: 1, old: 0xfffefffefffefffe,
                         expected: 0x01fc01fc01fc01fc)
    }

    func testGeneralRegionAliasingSnapshotsBothInputsInBothRequestedModes() throws {
        try assertValues(ordinary: false, sourceIndex: 2, old: 0xffffffffffffffff,
                         expected: 0x01fd01fd01fd01fd)
    }

    func testOrdinarySSAAndLegacyWrapPreserveBothHalves() throws {
        try assertValues(ordinary: true, sourceIndex: 1, old: 0xfffefffefffefffe,
                         expected: 0x01fc01fc01fc01fc)
    }

    func testOrdinarySSAAndLegacyAliasReadsPreWriteValue() throws {
        try assertValues(ordinary: true, sourceIndex: 2, old: 0xffffffffffffffff,
                         expected: 0x01fd01fd01fd01fd)
    }

    func testAsymmetricLanesDistinguishSourceFromAccumulatorAndHighFromLow() throws {
        for ordinary in [false, true] {
            for ssa in [false, true] {
                var rows: [InstructionRow] = []
                if ordinary { rows.append(row(0x1000, "08 01 00 91", "add", "x8, x8, #0")) }
                let address: UInt64 = ordinary ? 0x1004 : 0x1000
                rows.append(row(address, "22 68 20 6e", "uadalp", "v2.8h, v1.16b"))
                rows.append(row(address + 4, "c0 03 5f d6", "ret", ""))
                let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "asymmetric", instructions: rows)
                XCTAssertEqual(function.ssaEnabled, ordinary && ssa)
                let result = try interpret(function, sourceIndex: 1,
                    old: 0x0004000300020001, oldHigh: 0x006400c8012c0190,
                    narrowLow: 0x0807060504030201, narrowHigh: 0x10100f0e0d0c0b0a)
                XCTAssertEqual(result.v[2].low, 0x0013000e00090004)
                XCTAssertEqual(result.v[2].high, 0x008400e5014501a5)
            }
        }
    }

    func testExactEffectsReadAccumulatorAndSourceWithoutPhantomWrites() {
        let source = MacIRSourceSpan(address: 0x1000, byteText: "22 68 20 6e",
            mnemonic: "uadalp", operands: "v2.8h, v1.16b")
        let effects = MacIRBuilder.ssaEffects(for: source)
        XCTAssertEqual(effects.reads.cells, [33, 34, 65, 66])
        XCTAssertEqual(effects.writes.map(\.cell), [34, 66])
        XCTAssertTrue(effects.writes.allSatisfy { $0.bitWidth == 64 && $0.origin == .instruction(0x1000) })
        XCTAssertTrue(effects.refusals.isEmpty)
    }

    func testMismatchedTextAndUnsupportedWidthStayRefusedInBothModes() {
        for ssa in [false, true] {
            for (bytes, text) in [("22 68 20 6e", "v2.8h, v3.16b"),
                                  ("22 68 20 2e", "v2.4h, v1.8b"),
                                  ("22 68 20 6e", "v2.8h, v1.16b, v0.16b")] {
                let rows = [row(0x1000, "08 01 00 91", "add", "x8, x8, #0"),
                            row(0x1004, bytes, "uadalp", text)]
                let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "reject", instructions: rows)
                XCTAssertEqual(function.instructions.filter { $0.neonWideningPairwise != nil }.count, 0)
                XCTAssertTrue(function.instructions.contains { if case .unknown = $0.operation { return true }; return false })
            }
        }
    }

    func testCallClobberedInputIsNotInventedAsAnEntryVectorInEitherMode() {
        func unknown(_ value: MacIRValue) -> Bool {
            switch value {
            case .unknown: return true
            case let .unary(_, inner): return unknown(inner)
            case let .binaryExpression(_, left, right): return unknown(left) || unknown(right)
            default: return false
            }
        }
        for ssa in [false, true] {
            let rows = [row(0x1000, "20 00 00 94", "bl", "0x1080"),
                        row(0x1004, "22 68 20 6e", "uadalp", "v2.8h, v1.16b")]
            let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "clobber", instructions: rows)
            let typed = function.instructions.filter { $0.neonWideningPairwise != nil }
            XCTAssertEqual(typed.count, 1)
            for instruction in typed {
                guard case let .intrinsic(_, _, arguments) = instruction.operation else { return XCTFail("typed shape") }
                XCTAssertEqual(arguments.count, 2)
                XCTAssertTrue(arguments.allSatisfy(unknown))
            }
        }
    }
}

extension NEONWideningPairwiseAdmissionTests {
    func testNoCallCounterpartRetainsKnownEntryCarriersInBothModes() throws {
        for ssa in [false, true] {
            for ordinary in [false, true] {
                var rows: [InstructionRow] = []
                if ordinary { rows.append(row(0x1000, "08 01 00 91", "add", "x8, x8, #0")) }
                // The original negative's exact UADALP row, with no BL.
                rows.append(row(0x1004, "22 68 20 6e", "uadalp", "v2.8h, v1.16b"))
                let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "no_call", instructions: rows)
                XCTAssertEqual(function.ssaEnabled, ordinary && ssa)
                let result = try interpret(function, sourceIndex: 1, old: 0xfffefffefffefffe)
                XCTAssertEqual(result.v[2].low, 0x01fc01fc01fc01fc)
                XCTAssertEqual(result.v[2].high, 0x01fc01fc01fc01fc)
            }
        }
    }

    func testRealVectorRewriteAfterCallSuppliesNewUADALPProducersInBothModes() throws {
        let rows = [row(0x1000, "20 00 00 94", "bl", "0x1080"),
                    row(0x1004, "21 e4 00 4f", "movi", "v1.16b, #1"),
                    row(0x1008, "02 84 00 4f", "movi", "v2.8h, #0"),
                    row(0x100c, "22 68 20 6e", "uadalp", "v2.8h, v1.16b"),
                    // The region already owns these vector constants; no new
                    // ordinary-legacy MOVI admission is borrowed by this test.
                    row(0x1010, "a3 ff ff b5", "cbnz", "x3, 0x1004"),
                    row(0x1014, "c0 03 5f d6", "ret", "")]
        for ssa in [false, true] {
            let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "rewritten_after_call", instructions: rows)
            XCTAssertFalse(function.ssaEnabled, "The actual general-vector region owns both requested modes")
            let one = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1004 && $0.neonImmediate != nil })
            let zero = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1008 && $0.neonImmediate != nil })
            XCTAssertEqual(one.neonImmediate?.low, 0x0101010101010101)
            XCTAssertEqual(one.neonImmediate?.high, 0x0101010101010101)
            XCTAssertEqual(zero.neonImmediate?.low, 0)
            XCTAssertEqual(zero.neonImmediate?.high, 0)
            let accumulation = try XCTUnwrap(function.instructions.first { $0.neonWideningPairwise != nil })
            guard case let .intrinsic(oneDestination?, _, _) = one.operation,
                  case let .intrinsic(zeroDestination?, _, _) = zero.operation,
                  case let .intrinsic(_, _, arguments) = accumulation.operation else {
                return XCTFail("actual typed producer shape")
            }
            XCTAssertEqual(arguments, [oneDestination, zeroDestination],
                "Both actual post-call full-vector producers, not stale entry values, feed UADALP")
        }
    }

    func testCallAliasTombstonesAndPartialCarryDoNotInventWholeVectorValues() throws {
        var state = BuilderState()
        let preservedD8 = state.readRegister("d8")
        state.invalidateAppleCallerSavedState()
        XCTAssertEqual(state.readRegister("v1"), .unknown("unavailable_v1"))
        XCTAssertEqual(state.readRegister("q1"), .unknown("unavailable_q1"))
        XCTAssertEqual(state.readRegister("d8"), preservedD8, "Callee-preserved low64 is not poisoned")
        let qWrite = state.writeRegister("q1")
        XCTAssertEqual(state.readRegister("q1"), qWrite)
        XCTAssertEqual(state.readRegister("v1"), .unknown("unavailable_v1"),
            "Unsupported legacy cross-spelling recovery stays refused, not renamed into a phantom producer")
        let vWrite = state.writeRegister("v1")
        XCTAssertEqual(state.readRegister("v1"), vWrite)
        let partial = try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: "xtn2", operandText: "v2.16b, v1.8h"))
        XCTAssertTrue(partial.semantics.readsDestination)
        let operation = MacIRBuilder.liftNEONLane(partial, state: &state)
        guard case let .intrinsic(_, _, arguments) = operation else { return XCTFail("typed partial producer") }
        XCTAssertEqual(arguments.last, .unknown("unavailable_v2"),
            "A new partial result identity still depends on the unknown unwritten destination lanes")
    }

    func testCallPreservedLowHalvesDoNotInventFullV8InputsInBothModes() {
        func unknown(_ value: MacIRValue) -> Bool {
            switch value {
            case .unknown: return true
            case let .unary(_, inner): return unknown(inner)
            case let .binaryExpression(_, left, right): return unknown(left) || unknown(right)
            default: return false
            }
        }
        for ssa in [false, true] {
            for (bytes, operands) in [("02 69 20 6e", "v2.8h, v8.16b"),
                                       ("28 68 20 6e", "v8.8h, v1.16b")] {
                let rows = [row(0x1000, "20 00 00 94", "bl", "0x1080"),
                            row(0x1004, bytes, "uadalp", operands)]
                let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "upper_clobber", instructions: rows)
                let typed = function.instructions.filter { $0.neonWideningPairwise != nil }
                XCTAssertEqual(typed.count, 1)
                for instruction in typed {
                    guard case let .intrinsic(_, _, arguments) = instruction.operation else { return XCTFail("typed shape") }
                    XCTAssertEqual(arguments.count, 2)
                    XCTAssertTrue(arguments.allSatisfy(unknown))
                }
            }
        }
        for region in [false, true] {
            var state = BuilderState()
            state.permitsNEONBufferCarrier = region
            state.permitsNEONScalarViewCarrier = region
            let d8 = state.readRegister("d8")
            let d15 = state.readRegister("d15")
            state.invalidateAppleCallerSavedState()
            XCTAssertEqual(state.readRegister("d8"), d8)
            XCTAssertEqual(state.readRegister("d15"), d15)
            XCTAssertTrue(unknown(state.readRegister("v8")))
            XCTAssertTrue(unknown(state.readRegister("q8")))
            if !region {
                let q8 = state.writeRegister("q8")
                XCTAssertEqual(state.readRegister("q8"), q8)
                XCTAssertTrue(unknown(state.readRegister("v8")), "No cross-spelling producer is invented")
            }
            let v8 = state.writeRegister("v8")
            XCTAssertEqual(state.readRegister("v8"), v8)
        }
    }

}
