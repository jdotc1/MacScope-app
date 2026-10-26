import XCTest
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

final class ConditionalAdditionFlagRefusalRegressionTests: XCTestCase {
    private enum Consumer { case cset, branch, csel }
    private enum Witness { case a, b, c, d }

    private func source(_ address: UInt64, _ mnemonic: String, _ operands: String) -> MacIRSourceSpan {
        .init(address: address, byteText: "", mnemonic: mnemonic, operands: operands)
    }

    private func seededState(_ prefix: String) -> BuilderState {
        var state = BuilderState()
        for register in [0, 8, 9, 10, 11, 12] {
            state.registerVersions["\(prefix)\(register)"] = 0
        }
        state.registerVersions["w0"] = 0
        return state
    }

    private func consumerRow(_ consumer: Consumer, prefix: String, suffix: String) -> MacIRSourceSpan {
        switch consumer {
        case .cset: return source(0x1008, "cset", "w0, \(suffix)")
        case .branch: return source(0x1008, "b.\(suffix)", "0x1040")
        case .csel: return source(0x1008, "csel", "\(prefix)0, \(prefix)11, \(prefix)12, \(suffix)")
        }
    }

    private func refusal(_ witness: Witness, consumer: Consumer,
                         file: StaticString = #filePath, line: UInt = #line) {
        for prefix in ["w", "x"] {
            let first: MacIRSourceSpan
            let second: MacIRSourceSpan
            let suffix: String
            switch witness {
            case .a:
                // R8=0,R9=1: CMN C=0; false guard selects NZCV=0, HS=false.
                first = source(0x1000, "cmn", "\(prefix)8, #0")
                second = source(0x1004, "ccmp", "\(prefix)9, #0, #0, hs")
                suffix = "hs"
            case .b:
                // R8=0,R9=0: false guard selects NZCV=1, so LT=true.
                first = source(0x1000, "cmn", "\(prefix)8, #0")
                second = source(0x1004, "ccmp", "\(prefix)9, #0, #1, hs")
                suffix = "lt"
            case .c:
                // R8=1,R9=0: executed CCMN 0+0 has C=0, HS=false.
                first = source(0x1000, "cmp", "\(prefix)8, #0")
                second = source(0x1004, "ccmn", "\(prefix)9, #0, #0, ne")
                suffix = "hs"
            case .d:
                // R8=1,R9=0,R10=INT_MIN at producer width: addition LT=true.
                first = source(0x1000, "cmp", "\(prefix)8, #0")
                second = source(0x1004, "ccmn", "\(prefix)9, \(prefix)10, #0, ne")
                suffix = "lt"
            }
            var state = seededState(prefix)
            let builder = MacIRBuilder(ssaEnabled: MacIRConfiguration.ssaEnabled)
            _ = builder.operation(for: first, state: &state)
            _ = builder.operation(for: second, state: &state)
            let row = consumerRow(consumer, prefix: prefix, suffix: suffix)
            let result = builder.operation(for: row, state: &state)
            switch consumer {
            case .branch:
                guard case let .intrinsic(destination, name, arguments) = result else {
                    XCTFail("Expected existing branch marker, not a fabricated predicate: \(result)", file: file, line: line)
                    continue
                }
                XCTAssertNil(destination, file: file, line: line)
                XCTAssertEqual(name, "branch_\(suffix)", file: file, line: line)
                XCTAssertEqual(arguments, [.immediate(0x1040)], file: file, line: line)
            case .cset, .csel:
                guard case let .unknown(_, _, mnemonic, operands) = result else {
                    XCTFail("Expected this consumer's existing unknown form: \(result)", file: file, line: line)
                    continue
                }
                XCTAssertEqual(mnemonic, row.mnemonic, file: file, line: line)
                XCTAssertEqual(operands, row.operands, file: file, line: line)
            }
        }
    }

    func testACsetRefusesFalseCMNCarryGuard() { refusal(.a, consumer: .cset) }
    func testABranchRefusesFalseCMNCarryGuard() { refusal(.a, consumer: .branch) }
    func testACselRefusesFalseCMNCarryGuard() { refusal(.a, consumer: .csel) }
    func testBCsetRefusesLostLiteralOverflow() { refusal(.b, consumer: .cset) }
    func testBBranchRefusesLostLiteralOverflow() { refusal(.b, consumer: .branch) }
    func testBCselRefusesLostLiteralOverflow() { refusal(.b, consumer: .csel) }
    func testCCsetRefusesZeroCCMNCarry() { refusal(.c, consumer: .cset) }
    func testCBranchRefusesZeroCCMNCarry() { refusal(.c, consumer: .branch) }
    func testCCselRefusesZeroCCMNCarry() { refusal(.c, consumer: .csel) }
    func testDCsetRefusesRegisterCCMNOverflow() { refusal(.d, consumer: .cset) }
    func testDBranchRefusesRegisterCCMNOverflow() { refusal(.d, consumer: .branch) }
    func testDCselRefusesRegisterCCMNOverflow() { refusal(.d, consumer: .csel) }

    private func positive(firstMnemonic: String = "cmp", firstOperands: String = "x8, #0",
                          secondMnemonic: String = "ccmn", secondOperands: String, suffix: String,
                          legacy: String, ssa: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        var state = seededState("x")
        let builder = MacIRBuilder(ssaEnabled: MacIRConfiguration.ssaEnabled)
        _ = builder.operation(for: source(0x1000, firstMnemonic, firstOperands), state: &state)
        _ = builder.operation(for: source(0x1004, secondMnemonic, secondOperands), state: &state)
        let row = consumerRow(.cset, prefix: "x", suffix: suffix)
        let operation = builder.operation(for: row, state: &state)
        guard case .compareToBool = operation else {
            return XCTFail("Previously exact chain must stay admitted: \(operation)", file: file, line: line)
        }
        var function = MacIRFunction(name: "literal_compound", startAddress: 0x1000,
            instructions: [.init(source: row, operation: operation)])
        function.ssaEnabled = MacIRConfiguration.ssaEnabled
        let actual = PseudocodePrinter().render(operation: operation,
            names: PseudocodeNameContext(function: function))
        XCTAssertEqual(actual, MacIRConfiguration.ssaEnabled ? ssa : legacy, file: file, line: line)
    }

    func testCCMNOneSignedLTKeepsLiteralText() {
        positive(secondOperands: "x9, #1, #0, ne", suffix: "lt",
            legacy: "w0_1 = (x8_0 != 0x0) && ((((x9_0 & 0x8000000000000000) == 0 ? (int64_t)x9_0 : -1 - (int64_t)(uint64_t)~x9_0)) < -0x1)",
            ssa: "w0_1 = (x8_0 != 0x0) && ((((x9_0 & 0x8000000000000000) == 0 ? (int64_t)x9_0 : -1 - (int64_t)(uint64_t)~x9_0)) < -0x1)")
    }

    func testCCMNOneUnsignedHIKeepsLiteralText() {
        positive(secondOperands: "x9, #1, #0, ne", suffix: "hi",
            legacy: "w0_1 = (x8_0 != 0x0) && ((uint64_t)(x9_0) > (uint64_t)(-0x1))",
            ssa: "w0_1 = (x8_0 != 0x0) && ((uint64_t)(x9_0) > (uint64_t)(-0x1))")
    }

    func testCCMNRegisterEQKeepsLiteralText() {
        positive(secondOperands: "x9, x10, #0, ne", suffix: "eq",
            legacy: "w0_1 = (x8_0 != 0x0) && ((uint64_t)(x9_0) == (uint64_t)((uint64_t)(0x0) - (uint64_t)(x10_0)))",
            ssa: "w0_1 = (x8_0 != 0x0) && ((uint64_t)(x9_0) == (uint64_t)((uint64_t)(0x0) - (uint64_t)(x10_0)))")
    }

    func testCCMNRegisterNEKeepsLiteralText() {
        positive(secondOperands: "x9, x10, #0, ne", suffix: "ne",
            legacy: "w0_1 = (x8_0 == 0x0) || ((uint64_t)(x9_0) != (uint64_t)((uint64_t)(0x0) - (uint64_t)(x10_0)))",
            ssa: "w0_1 = (x8_0 == 0x0) || ((uint64_t)(x9_0) != (uint64_t)((uint64_t)(0x0) - (uint64_t)(x10_0)))")
    }

    func testCMNOneLTGuardKeepsLiteralText() {
        positive(firstMnemonic: "cmn", firstOperands: "x8, #1",
            secondMnemonic: "ccmp", secondOperands: "x9, #0, #0, lt", suffix: "eq",
            legacy: "w0_1 = ((((x8_0 & 0x8000000000000000) == 0 ? (int64_t)x8_0 : -1 - (int64_t)(uint64_t)~x8_0)) < -0x1) && (x9_0 == 0x0)",
            ssa: "w0_1 = ((((x8_0 & 0x8000000000000000) == 0 ? (int64_t)x8_0 : -1 - (int64_t)(uint64_t)~x8_0)) < -0x1) && (x9_0 == 0x0)")
    }

    func testPlainCMPCCMPKeepsLiteralText() {
        positive(secondMnemonic: "ccmp", secondOperands: "x9, #0, #0, ne", suffix: "eq",
            legacy: "w0_1 = (x8_0 != 0x0) && (x9_0 == 0x0)",
            ssa: "w0_1 = (x8_0 != 0x0) && (x9_0 == 0x0)")
    }

    private func metadataOperation(prefix: String, firstAddition: Bool, addend: String,
                                   suffix: String) -> MacIROperation {
        var state = seededState(prefix)
        let builder = MacIRBuilder(ssaEnabled: MacIRConfiguration.ssaEnabled)
        let first = firstAddition
            ? source(0x1000, "cmn", "\(prefix)8, \(addend)")
            : source(0x1000, "cmp", "\(prefix)8, #0")
        let second = firstAddition
            ? source(0x1004, "ccmp", "\(prefix)9, #0, #0, \(suffix)")
            : source(0x1004, "ccmn", "\(prefix)9, \(addend), #0, ne")
        _ = builder.operation(for: first, state: &state)
        _ = builder.operation(for: second, state: &state)
        return builder.operation(for: consumerRow(.cset, prefix: prefix,
            suffix: firstAddition ? "eq" : suffix), state: &state)
    }

    func testZeroRegisterAddendsRefuseOverflowDespiteLoweredZero() {
        for prefix in ["w", "x"] {
            for firstAddition in [false, true] {
                let result = metadataOperation(prefix: prefix, firstAddition: firstAddition,
                    addend: "\(prefix)zr", suffix: "lt")
                guard case .unknown = result else {
                    XCTFail("Register syntax is not an immediate certificate: \(result)")
                    continue
                }
                let literal = metadataOperation(prefix: prefix, firstAddition: firstAddition,
                    addend: "#0", suffix: "lt")
                guard case .compareToBool = literal else {
                    XCTFail("Literal zero is safe for V-dependent suffixes: \(literal)")
                    continue
                }
            }
        }
    }

    func testWordModuloZeroImmediateRefusesCarryAtProducerWidth() {
        // Synthetic parser input, not an architectural immediate encoding.
        for firstAddition in [false, true] {
            let word = metadataOperation(prefix: "w", firstAddition: firstAddition,
                addend: "#0x100000000", suffix: "hs")
            guard case .unknown = word else {
                XCTFail("This parsed literal is zero at W32: \(word)")
                continue
            }
            let doubleword = metadataOperation(prefix: "x", firstAddition: firstAddition,
                addend: "#0x100000000", suffix: "hs")
            guard case .compareToBool = doubleword else {
                XCTFail("The same literal is nonzero at W64: \(doubleword)")
                continue
            }
        }
    }

    func testWordMinimumImmediateRefusesOverflowAtProducerWidth() {
        // Synthetic parser input, not an architectural immediate encoding.
        for firstAddition in [false, true] {
            let word = metadataOperation(prefix: "w", firstAddition: firstAddition,
                addend: "#0x80000000", suffix: "lt")
            guard case .unknown = word else {
                XCTFail("This parsed literal is INT_MIN at W32: \(word)")
                continue
            }
            let doubleword = metadataOperation(prefix: "x", firstAddition: firstAddition,
                addend: "#0x80000000", suffix: "lt")
            guard case .compareToBool = doubleword else {
                XCTFail("The same literal is not INT_MIN at W64: \(doubleword)")
                continue
            }
        }
    }
}
