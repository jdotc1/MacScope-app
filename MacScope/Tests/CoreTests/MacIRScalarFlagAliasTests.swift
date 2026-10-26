import XCTest
@testable import MacScope

// Authored only. Architectural expectations: Arm ANDS_log_imm Execute,
// CNEG_CSNEG alias, CSNEG Execute, SUBS Execute and ConditionHolds.
final class MacIRScalarFlagAliasTests: XCTestCase {
    private func source(_ mnemonic: String, _ operands: String, _ address: UInt64 = 0x1000) -> MacIRSourceSpan {
        .init(address: address, byteText: "", mnemonic: mnemonic, operands: operands)
    }
    private func state() -> BuilderState {
        var state = BuilderState()
        for prefix in ["w", "x"] { for index in 0...30 { state.registerVersions["\(prefix)\(index)"] = 0 } }
        return state
    }
    private func evaluate(_ value: MacIRValue, _ registers: [String: UInt64]) throws -> UInt64 {
        switch value {
        case let .immediate(value): return UInt64(bitPattern: value)
        case let .register(name, _): return try XCTUnwrap(registers[name], name)
        case let .argument(binding):
            guard case .gpr = binding.kind else { XCTFail("expected a scalar GPR input"); return 0 }
            return try XCTUnwrap(registers["x\(binding.value)"])
        case let .unary(op, value):
            let bits = try evaluate(value, registers)
            switch op {
            case "(uint32_t)", "(int32_t)": return bits & 0xffffffff
            case "(uint64_t)", "(int64_t)": return bits
            default: XCTFail("unexpected unary \(op)"); return 0
            }
        case let .binaryExpression(op, left, right):
            let a = try evaluate(left, registers), b = try evaluate(right, registers)
            switch op {
            case "&": return a & b
            case "-": return a &- b
            default: XCTFail("unexpected binary \(op)"); return 0
            }
        default: XCTFail("unexpected value \(value)"); return 0
        }
    }
    private func flags(_ comparison: BuilderComparison, width: Int,
                       registers: [String: UInt64], priorNZCV: UInt8) throws -> UInt8 {
        // Apply the emitted comparison's flag contract, not its mnemonic.
        // Prior NZCV is deliberately supplied as both 0000 and 1111.
        let mask = width == 32 ? UInt64(0xffffffff) : UInt64.max
        let a = try evaluate(comparison.left, registers) & mask
        let b = try evaluate(comparison.right, registers) & mask
        let result: UInt64, carry: Bool, overflow: Bool
        switch comparison.flagsKind {
        case .logicalResult: result = a; carry = false; overflow = false
        case .subtraction:
            result = (a &- b) & mask; carry = a >= b
            overflow = ((a ^ b) & (a ^ result) & (UInt64(1) << (width - 1))) != 0
        }
        var nzcv = priorNZCV
        nzcv = (result >> (width - 1) != 0 ? 8 : 0) | (result == 0 ? 4 : 0)
            | (carry ? 2 : 0) | (overflow ? 1 : 0)
        return nzcv
    }

    func testTSTOraclePreservesFullResultAndOverwritesEveryFlag() throws {
        let vectors: [(String, Int, UInt64, UInt64, UInt64, UInt8)] = [
            ("zero64", 64, 0x0, 0x8000000000000000, 0x0, 0b0100),
            ("sign64", 64, 0x8000000000000000, 0x8000000000000000, 0x8000000000000000, 0b1000),
            ("ones64", 64, 0xffffffffffffffff, 0x8080808080808080, 0x8080808080808080, 0b1000),
            ("low64", 64, 0x1, 0x8000000000000000, 0x0, 0b0100),
            ("positive64", 64, 0x7fffffffffffffff, 0x8080808080808080, 0x0080808080808080, 0b0000),
            ("zero32", 32, 0x0, 0x80000000, 0x0, 0b0100),
            ("sign32", 32, 0x80000000, 0x80000000, 0x80000000, 0b1000),
            ("ones32", 32, 0xffffffff, 0xff, 0xff, 0b0000),
        ]
        for (name, width, input, mask, expected, expectedFlags) in vectors {
            for prior in [UInt8(0), UInt8(15)] {
                var state = state()
                state.lastComparison = .init(left: .unknown("prior_\(prior)"), right: .immediate(0))
                let reg = width == 32 ? "w8" : "x8"
                let row = source("tst", "\(reg), #0x\(String(mask, radix: 16))")
                let operation = MacIRBuilder(ssaEnabled: true).operation(for: row, state: &state)
                guard case let .intrinsic(destination, intrinsic, arguments) = operation else {
                    XCTFail("TST must emit compare: \(name)"); continue
                }
                XCTAssertNil(destination); XCTAssertEqual(intrinsic, "compare"); XCTAssertEqual(arguments.count, 2)
                XCTAssertEqual(try evaluate(arguments[0], [reg: input]), expected, name)
                let comparison = try XCTUnwrap(state.lastComparison)
                guard case .logicalResult = comparison.flagsKind else { XCTFail("logical flags required"); continue }
                XCTAssertEqual(try flags(comparison, width: width, registers: [reg: input], priorNZCV: prior), expectedFlags, name)
                guard case let .unary(cast, _) = comparison.left else { XCTFail("full signed-width projection required"); continue }
                XCTAssertEqual(cast, width == 32 ? "(int32_t)" : "(int64_t)")
                let signed = width == 32 ? Int64(Int32(bitPattern: UInt32(expected))) : Int64(bitPattern: expected)
                XCTAssertEqual(signed < 0, expectedFlags & 8 != 0, "LT/GE sign boundary \(name)")
                let effects = MacIRBuilder.ssaEffects(for: row)
                XCTAssertEqual(effects.writes.map(\.cell), [96])
                XCTAssertEqual(effects.writes.first?.bitWidth, 4)
                XCTAssertEqual(state.registerVersions[reg], 0)
            }
        }
    }

    func testCNEGOracleUsesNNotSignedLTAndPreservesFlags() throws {
        let vectors: [(String, Int, UInt64, UInt64, String, UInt64, UInt64, UInt8)] = [
            ("zero32", 32, 0x0, 0x0, "mi", 0x0, 0x0, 0b0110),
            ("sign32", 32, 0x80000000, 0x0, "mi", 0x80000000, 0x80000000, 0b1010),
            ("ones32", 32, 0xffffffff, 0x0, "mi", 0xffffffff, 0x1, 0b1010),
            ("positive32", 32, 0x1, 0x0, "mi", 0x1, 0x1, 0b0010),
            ("overflow32", 32, 0x7fffffff, 0xffffffff, "mi", 0x5, 0xfffffffb, 0b1001),
            ("reverseOverflow32", 32, 0x80000000, 0x1, "mi", 0x5, 0x5, 0b0011),
            ("sign64", 64, 0x8000000000000000, 0x0, "mi", 0x8000000000000000, 0x8000000000000000, 0b1010),
            ("ones64", 64, 0xffffffffffffffff, 0x0, "mi", 0xffffffffffffffff, 0x1, 0b1010),
            ("pl32", 32, 0x1, 0x0, "pl", 0x1, 0xffffffff, 0b0010),
        ]
        for (name, width, a, b, condition, input, expected, expectedFlags) in vectors {
            for prior in [UInt8(0), UInt8(15)] {
                for aliasesSource in [true, false] {
                    var state = state()
                    let prefix = width == 32 ? "w" : "x"
                    let left = "\(prefix)8", right = "\(prefix)9", sourceReg = "\(prefix)10"
                    let destinationReg = aliasesSource ? sourceReg : "\(prefix)11"
                    let builder = MacIRBuilder(ssaEnabled: true)
                    _ = builder.operation(for: source("cmp", "\(left), \(right)"), state: &state)
                    let before = try XCTUnwrap(state.lastComparison)
                    let registers = [left: a, right: b, sourceReg: input]
                    let beforeFlags = try flags(before, width: width, registers: registers, priorNZCV: prior)
                    XCTAssertEqual(beforeFlags, expectedFlags, name)
                    let row = source("cneg", "\(destinationReg), \(sourceReg), \(condition)", 0x1004)
                    let operation = builder.operation(for: row, state: &state)
                    guard case let .select(destination, predicate, lhs, rhs, yes, no) = operation else {
                        XCTFail("CNEG must emit select: \(name)"); continue
                    }
                    let l = try evaluate(lhs, registers), r = try evaluate(rhs, registers)
                    XCTAssertTrue(["!=", "=="].contains(predicate))
                    let taken = predicate == "!=" ? l != r : l == r
                    XCTAssertEqual(try evaluate(taken ? yes : no, registers), expected, name)
                    if width == 32 { XCTAssertLessThanOrEqual(try evaluate(taken ? yes : no, registers), 0xffffffff) }
                    XCTAssertNotEqual(destination, .register(name: sourceReg, version: 0))
                    let after = try XCTUnwrap(state.lastComparison)
                    XCTAssertEqual(after.left, before.left); XCTAssertEqual(after.right, before.right)
                    XCTAssertEqual(try flags(after, width: width, registers: registers, priorNZCV: beforeFlags), beforeFlags)
                    let effects = MacIRBuilder.ssaEffects(for: row)
                    XCTAssertNotNil(effects.readViews[96]); XCTAssertFalse(effects.writes.contains { $0.cell == 96 })
                    XCTAssertEqual(effects.writes.first?.bitWidth, width)
                }
            }
        }
    }

    private func assertUnknown(_ mnemonic: String, _ operands: String, state: inout BuilderState,
                               file: StaticString = #filePath, line: UInt = #line) {
        let operation = MacIRBuilder(ssaEnabled: true).operation(for: source(mnemonic, operands, 0x1004), state: &state)
        guard case .unknown = operation else { return XCTFail("expected refusal: \(mnemonic) \(operands)", file: file, line: line) }
    }

    func testInvalidTSTFormsRemainUnknown() {
        for operands in ["x8, #0", "x8, #0xffffffffffffffff", "w8, #0xffffffff",
                         "w8, #0x100000000", "x8, #0xno", "x8, #0x5", "x8, #-1",
                         "w8, w9, lsl #1", "x31, #1", "x99, #1", "sp, #1", "w8, x9", "xzr, #1"] {
            var state = state(); assertUnknown("tst", operands, state: &state)
        }
    }

    func testUnprovenCNEGFlagsAndInvalidRegistersRemainUnknown() {
        for mode in ["absent", "unknownWriter", "ccmp", "phi", "unknownWidth", "unsupportedWidth"] {
            var state = state()
            let comparison = BuilderComparison(left: .register(name: "w8", version: 0), right: .immediate(0))
            state.recordPlainComparison(comparison)
            switch mode {
            case "absent": state.lastComparison = nil
            case "unknownWriter": state.sawConditionalCompareSinceComparison = true
            case "ccmp": state.pendingConditionalCompare = .init(mnemonic: "ccmp", left: comparison.left,
                right: .immediate(0), nzcv: 0, guardSuffix: "eq", firstComparison: comparison, sourceAddress: 0x1000)
            case "phi": state.flagsPhiContext = .init(blockAddress: 0x1000, rowAddress: 0x1004, incomings: [])
            case "unknownWidth": state.lastComparison = .init(left: .immediate(0), right: .immediate(0))
            default:
                let binding = MacIRParameterBindingID.entryStack(byteOffset: 0)
                state.parameters = [MacIRFunctionParameter(
                    id: .recovered(binding), bindingID: binding, sourcePosition: 0,
                    abiLocation: .entryStack(byteOffset: 0, size: 2, alignment: 2),
                    type: "int16_t", evidence: .authoritativeUser)].compactMap { $0 }
                XCTAssertEqual(state.argumentBitWidths[binding], 16)
                state.lastComparison = .init(left: .argument(bindingID: binding), right: .immediate(0))
            }
            assertUnknown("cneg", "w10, w10, mi", state: &state)
        }
        for operands in ["w10, x10, mi", "sp, w10, mi", "w99, w10, mi", "w10, wzr, mi"] {
            var state = state()
            state.recordPlainComparison(.init(left: .register(name: "w8", version: 0), right: .immediate(0)))
            assertUnknown("cneg", operands, state: &state)
        }
    }
    func testExistingConditionalAliasFormsStillEmitSelect() {
        for mnemonic in ["cneg", "cinc", "cinv"] {
            for condition in ["eq", "ne"] {
                var state = state()
                let builder = MacIRBuilder(ssaEnabled: true)
                _ = builder.operation(for: source("cmp", "w8, w9"), state: &state)
                let operation = builder.operation(for: source(mnemonic, "w10, w11, \(condition)", 0x1004), state: &state)
                guard case .select = operation else { XCTFail("existing alias regressed"); continue }
            }
        }
    }

    // Exercise the production SSA lift before the independent displayed-use proof.
    private func composedSSA(_ rows: [MacIRSourceSpan]) -> MacIRFunction {
        let instructions = rows.map {
            InstructionRow(address: $0.address, bytes: "", mnemonic: $0.mnemonic,
                operands: $0.operands, hasBreakpoint: false, comment: nil)
        }
        let function = MacIRBuilder(ssaEnabled: true).buildFunction(name: "composed_flags",
            startAddress: 0x1000, instructions: instructions)
        XCTAssertTrue(function.ssaEnabled)
        XCTAssertNotNil(function.ssaInfo)
        return function
    }

    private func isComposedGuardRefusal(_ detail: C2DataflowCensus.RefusalDetail,
                                        guardID: String) -> Bool {
        guard let failure = detail.guardedFailure else { return false }
        return detail.instructionAddress == 0x1004
            && failure.conjunct == .oldGateFailed
            && failure.guardID == guardID
            && detail.reason == failure.conjunct.reason
    }

    private func assertComposedGuardRefusal(_ function: MacIRFunction,
                                            machine: [MacIRSourceSpan], registers: Set<String>,
                                            guardID: String) {
        let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
            deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
        let projected = MacIRFPEnvironmentPseudocodeProjection.project(function)
        let document = printer.print(function: function)
        var names = PseudocodeNameContext(function: projected)
        names.redundantCompareIndices = printer.redundantCompareIndices(function: projected, names: names)
        let result = C2DataflowCensus.analyze(function: projected, document: document,
            machine: machine, printer: printer, names: names, ssaAccountingEnabled: true)
        let refusals = result.refusalDetails.filter { isComposedGuardRefusal($0, guardID: guardID) }
        XCTAssertEqual(Set(refusals.compactMap(\.register)), registers)
        XCTAssertTrue(refusals.allSatisfy { $0.displayedLineNumber != nil && $0.valueName != nil })
        XCTAssertTrue(document.lines.contains { $0.kind == .instruction && $0.sourceAddress == 0x1004 })
        XCTAssertTrue(result.rows.isEmpty, "conservative coverage refusal is not a stale-value finding")
    }

    func testComposedTSTEQScalarFlagsAndSSACensusRefusal() throws {
        let rows = [source("tst", "x3, #8"), source("csel", "x0, x1, x2, eq", 0x1004),
                    source("ret", "", 0x1008)]
        let function = composedSSA(rows)
        let compare = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1000 })
        guard case let .intrinsic(nil, name, arguments) = compare.operation else {
            return XCTFail("SSA TST must retain its scalar comparison")
        }
        XCTAssertEqual(name, "compare")
        XCTAssertEqual(arguments.count, 2)
        guard arguments.count == 2 else { return }
        guard case let .unary(cast, _) = arguments[0] else { return XCTFail("full-width projection lost") }
        XCTAssertEqual(cast, "(int64_t)")
        let selection = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1004 })
        guard case let .select(_, predicate, lhs, rhs, yes, no) = selection.operation else {
            return XCTFail("SSA CSEL must remain a select")
        }
        XCTAssertEqual(predicate, "==")
        let vectors: [(UInt64, UInt64, UInt8, UInt64)] = [
            (0, 0, 0b0100, 0x1111), (8, 8, 0b0000, 0x2222),
            (UInt64.max, 8, 0b0000, 0x2222), (0x8000000000000000, 0, 0b0100, 0x1111)
        ]
        for (input, expectedResult, expectedFlags, selected) in vectors {
            let registers: [String: UInt64] = ["x3": input, "x1": 0x1111, "x2": 0x2222]
            XCTAssertEqual(try evaluate(arguments[0], registers), expectedResult)
            XCTAssertEqual(try evaluate(arguments[1], registers), 0)
            let taken = try evaluate(lhs, registers) == evaluate(rhs, registers)
            XCTAssertEqual(try evaluate(taken ? yes : no, registers), selected)
            for prior in [UInt8(0), UInt8(15)] {
                var state = state()
                _ = MacIRBuilder(ssaEnabled: true).operation(for: rows[0], state: &state)
                let before = try XCTUnwrap(state.lastComparison)
                guard case .logicalResult = before.flagsKind else { return XCTFail("logical flags lost") }
                XCTAssertEqual(try evaluate(before.left, registers), expectedResult)
                XCTAssertEqual(try flags(before, width: 64, registers: registers, priorNZCV: prior), expectedFlags)
                _ = MacIRBuilder(ssaEnabled: true).operation(for: rows[1], state: &state)
                let after = try XCTUnwrap(state.lastComparison)
                XCTAssertEqual(after.left, before.left); XCTAssertEqual(after.right, before.right)
                XCTAssertEqual(try flags(after, width: 64, registers: registers, priorNZCV: expectedFlags), expectedFlags)
            }
        }
        assertComposedGuardRefusal(function, machine: rows, registers: ["x1", "x2"],
                                   guardID: "old.logical-left")
    }

    func testComposedCNEGMIAndPLOverflowFlagsAndSSACensusRefusal() throws {
        for suffix in ["mi", "pl"] {
            let rows = [source("cmp", "x8, x9"), source("cneg", "x0, x10, \(suffix)", 0x1004),
                        source("ret", "", 0x1008)]
            let function = composedSSA(rows)
            let selection = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1004 })
            guard case let .select(_, predicate, lhs, rhs, yes, no) = selection.operation else {
                return XCTFail("SSA CNEG must retain the sign-bit selection")
            }
            XCTAssertEqual(predicate, suffix == "mi" ? "!=" : "==")
            // Both V=1 directions separate N from N xor V, for both aliases.
            let vectors: [(UInt64, UInt64, UInt8, Bool)] = [
                (0x7fffffffffffffff, UInt64.max, 0b1001, true),
                (0x8000000000000000, 1, 0b0011, false)
            ]
            for (a, b, expectedFlags, negative) in vectors {
                let registers: [String: UInt64] = ["x8": a, "x9": b, "x10": 5]
                let l = try evaluate(lhs, registers), r = try evaluate(rhs, registers)
                let taken = predicate == "!=" ? l != r : l == r
                let negate = suffix == "mi" ? negative : !negative
                XCTAssertEqual(try evaluate(taken ? yes : no, registers), negate ? UInt64.max - 4 : 5)
                for prior in [UInt8(0), UInt8(15)] {
                    var state = state()
                    _ = MacIRBuilder(ssaEnabled: true).operation(for: rows[0], state: &state)
                    let before = try XCTUnwrap(state.lastComparison)
                    guard case .subtraction = before.flagsKind else { return XCTFail("subtraction flags lost") }
                    XCTAssertEqual(try flags(before, width: 64, registers: registers, priorNZCV: prior), expectedFlags)
                    _ = MacIRBuilder(ssaEnabled: true).operation(for: rows[1], state: &state)
                    let after = try XCTUnwrap(state.lastComparison)
                    XCTAssertEqual(after.left, before.left); XCTAssertEqual(after.right, before.right)
                    XCTAssertEqual(try flags(after, width: 64, registers: registers, priorNZCV: expectedFlags), expectedFlags)
                }
            }
            assertComposedGuardRefusal(function, machine: rows, registers: ["x10"],
                                       guardID: "old.alias-condition")
        }
    }

    func testComposedGuardRefusalSelectionRequiresExactTypedIdentity() {
        func detail(reason: String, address: UInt64? = 0x1004,
                    failure: C2DataflowCensus.GuardedFailure?) -> C2DataflowCensus.RefusalDetail {
            .init(reason: reason, instructionAddress: address, mnemonic: "csel",
                  register: "x1", valueName: "x1_0", displayedLineNumber: 1,
                  guardedFailure: failure)
        }
        for guardID in ["old.logical-left", "old.alias-condition"] {
            let failure = C2DataflowCensus.GuardedFailure(conjunct: .oldGateFailed,
                guardID: guardID, sourceFile: #fileID, sourceLine: #line)
            let valid = detail(reason: failure.conjunct.reason, failure: failure)
            XCTAssertTrue(isComposedGuardRefusal(valid, guardID: guardID))
            let wrongCategory = C2DataflowCensus.GuardedFailure(conjunct: .unsupportedShape,
                guardID: guardID, sourceFile: #fileID, sourceLine: #line)
            let wrongGuard = C2DataflowCensus.GuardedFailure(conjunct: .oldGateFailed,
                guardID: "old.unrelated", sourceFile: #fileID, sourceLine: #line)
            let unrelated = [
                detail(reason: "printed operand is not a direct machine read", failure: failure),
                detail(reason: "guarded select arm needs path-predicate proof", failure: failure),
                detail(reason: failure.conjunct.reason, failure: nil),
                detail(reason: failure.conjunct.reason, address: 0x1008, failure: failure),
                detail(reason: failure.conjunct.reason, address: nil, failure: failure),
                detail(reason: wrongCategory.conjunct.reason, failure: wrongCategory),
                detail(reason: failure.conjunct.reason, failure: wrongGuard)
            ]
            XCTAssertTrue(unrelated.allSatisfy { !isComposedGuardRefusal($0, guardID: guardID) })
            XCTAssertEqual(([valid] + unrelated).filter {
                isComposedGuardRefusal($0, guardID: guardID)
            }, [valid])
        }
    }

}
