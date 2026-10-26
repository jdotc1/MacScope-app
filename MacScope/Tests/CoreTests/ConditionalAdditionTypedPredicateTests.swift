import XCTest
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

final class ConditionalAdditionTypedPredicateTests: XCTestCase {
    private func parameter(_ index: Int, width: Int, type: String, name: String) -> MacIRFunctionParameter {
        var result = MacIRFunctionParameter(index: index, register: "\(width == 32 ? "w" : "x")\(index)",
            type: type, name: name)
        result.sourcePosition = index
        result.evidence = .authoritativeUser
        return result
    }

    private func row(_ address: UInt64, _ bytes: String, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(address: address, bytes: bytes, mnemonic: mnemonic, operands: operands,
            hasBreakpoint: false, comment: nil)
    }

    private func lift(_ rows: [InstructionRow], parameters: [MacIRFunctionParameter], ssa: Bool) throws -> MacIRFunction {
        let plan = try XCTUnwrap(MacIRAuthoritativeParameterPlan(parameters: parameters, isVariadic: false))
        let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "typed_addition_predicate",
            authoritativeParameterPlan: plan, instructions: rows)
        XCTAssertEqual(function.ssaEnabled, ssa)
        return function
    }

    private func compoundTerm(_ function: MacIRFunction, second: Bool = true) throws -> MacIRValue {
        let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1008 })
        guard case let .compareToBool(_, "!=", compound, .immediate(0)) = instruction.operation,
              case let .binaryExpression(op, first, last) = compound, op == "&&" || op == "||" else {
            XCTFail("expected a complete typed compound predicate")
            throw Failure.missingPredicate
        }
        return second ? last : first
    }

    private enum Failure: Error { case missingPredicate }

    func testWordAdditionSignedConditionUsesEncodedSignedWidth() throws {
        // Derived encodings, not bytes from the original symbolic controls.
        let rows = [
            row(0x1000, "1f 00 00 71", "cmp", "w0, #0"),
            row(0x1004, "20 18 41 3a", "ccmn", "w1, #1, #0, ne"),
            row(0x1008, "e0 a7 9f 1a", "cset", "w0, lt"),
            row(0x100c, "c0 03 5f d6", "ret", "")
        ]
        let parameters = [parameter(0, width: 32, type: "uint32_t", name: "g"),
                          parameter(1, width: 32, type: "uint32_t", name: "a")]
        let ssa = MacIRConfiguration.ssaEnabled
        do {
            let function = try lift(rows, parameters: parameters, ssa: ssa)
            let a = MacIRValue.argument(bindingID: .gpr(1))
            let expected = MacIRValue.binaryExpression(op: "<",
                left: MacIRBuilder.signedProjection(a, width: 32, partner: .immediate(-1)),
                right: .immediate(-1))
            XCTAssertEqual(try compoundTerm(function), expected)
            let text = PseudocodePrinter().print(function: function).text
            XCTAssertTrue(text.contains("uint32_t a"), text)
            XCTAssertFalse(text.contains("(a < -0x1)"), text)
            // g=1,a=0: CCMN computes 0+1, so N=V=0 and LT is false.
            XCTAssertFalse(Int32(0) < -1)
        }
    }

    func testRegisterAdditionEqualityNegatesOnlyAfterUnsignedConversion() throws {
        for width in [32, 64] {
            let prefix = width == 32 ? "w" : "x"
            let parameters = [parameter(0, width: width, type: "int\(width)_t", name: "g"),
                              parameter(1, width: width, type: "int\(width)_t", name: "a"),
                              parameter(2, width: width, type: "int\(width)_t", name: "b")]
            func u(_ value: MacIRValue) -> MacIRValue { .unary(op: "(uint\(width)_t)", value: value) }
            let ssa = MacIRConfiguration.ssaEnabled
        do {
                for (suffix, bytes, relation) in [("eq", "e0 17 9f 1a", "=="), ("ne", "e0 07 9f 1a", "!=")] {
                    let function = try lift([
                        row(0x1000, width == 32 ? "1f 00 00 71" : "1f 00 00 f1", "cmp", prefix + "0, #0"),
                        row(0x1004, width == 32 ? "20 10 42 3a" : "20 10 42 ba", "ccmn", prefix + "1, " + prefix + "2, #0, ne"),
                        row(0x1008, bytes, "cset", "w0, " + suffix),
                        row(0x100c, "c0 03 5f d6", "ret", "")
                    ], parameters: parameters, ssa: ssa)
                    let a = MacIRValue.argument(bindingID: .gpr(1))
                    let b = MacIRValue.argument(bindingID: .gpr(2))
                    let negated = u(.binaryExpression(op: "-", left: u(.immediate(0)), right: u(b)))
                    XCTAssertEqual(try compoundTerm(function), .binaryExpression(op: relation, left: u(a), right: negated))
                    let text = PseudocodePrinter().print(function: function).text
                    XCTAssertTrue(text.contains("int\(width)_t b"), text)
                    XCTAssertFalse(text.contains("-(b)"), text)
                    // g=1,a=b=INT_MIN: addition is zero at the encoded width.
                    if width == 32 {
                        XCTAssertEqual(UInt32(bitPattern: Int32.min) &+ UInt32(bitPattern: Int32.min), 0)
                    } else {
                        XCTAssertEqual(UInt64(bitPattern: Int64.min) &+ UInt64(bitPattern: Int64.min), 0)
                    }
                }
            }
        }
    }

    func testExtendedAddendDoesNotAcquireAnUnprovedCArithmeticProof() throws {
        let parameters = [parameter(0, width: 64, type: "int64_t", name: "a"),
                          parameter(1, width: 32, type: "uint32_t", name: "b"),
                          parameter(2, width: 64, type: "int64_t", name: "z")]
        let ssa = MacIRConfiguration.ssaEnabled
        do {
            let function = try lift([
                row(0x1000, "1f c4 21 ab", "cmn", "x0, w1, sxtw #1"),
                row(0x1004, "40 08 40 fa", "ccmp", "x2, #0, #0, eq"),
                row(0x1008, "e0 17 9f 1a", "cset", "w0, eq"),
                row(0x100c, "c0 03 5f d6", "ret", "")
            ], parameters: parameters, ssa: ssa)
            let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1008 })
            guard case let .unknown(destination, inputs, mnemonic, operands) = instruction.operation else {
                return XCTFail("expected the destination-bearing CSET refusal")
            }
            XCTAssertEqual(destination, MacIRValue.register(name: "w0", version: 1))
            XCTAssertEqual(mnemonic, "cset")
            XCTAssertEqual(operands, "w0, eq")
            XCTAssertTrue(inputs.mayReadNZCV)
        }
    }

    func testFirstAdditionEqualityDoesNotRetainSignedNegation() throws {
        for width in [32, 64] {
            let prefix = width == 32 ? "w" : "x"
            let parameters = [parameter(0, width: width, type: "int\(width)_t", name: "a"),
                              parameter(1, width: width, type: "int\(width)_t", name: "b"),
                              parameter(2, width: width, type: "int\(width)_t", name: "z")]
            func u(_ value: MacIRValue) -> MacIRValue { .unary(op: "(uint\(width)_t)", value: value) }
            let ssa = MacIRConfiguration.ssaEnabled
        do {
                for (suffix, bytes, relation) in [("eq", "e0 17 9f 1a", "=="), ("ne", "e0 07 9f 1a", "!=")] {
                    let function = try lift([
                        row(0x1000, width == 32 ? "1f 00 01 2b" : "1f 00 01 ab", "cmn", prefix + "0, " + prefix + "1"),
                        row(0x1004, width == 32 ? "40 08 40 7a" : "40 08 40 fa", "ccmp", prefix + "2, #0, #0, eq"),
                        row(0x1008, bytes, "cset", "w0, " + suffix),
                        row(0x100c, "c0 03 5f d6", "ret", "")
                    ], parameters: parameters, ssa: ssa)
                    let a = MacIRValue.argument(bindingID: .gpr(0))
                    let b = MacIRValue.argument(bindingID: .gpr(1))
                    let negated = u(.binaryExpression(op: "-", left: u(.immediate(0)), right: u(b)))
                    XCTAssertEqual(try compoundTerm(function, second: false),
                        .binaryExpression(op: relation, left: u(a), right: negated))
                    let text = PseudocodePrinter().print(function: function).text
                    XCTAssertTrue(text.contains("int\(width)_t b"), text)
                    XCTAssertFalse(text.contains("-(b)"), text)
                }
            }
        }
    }

    func testAdditionCarryPhiRefusesSubtractionCarryReuse() throws {
        let parameters = [parameter(0, width: 64, type: "uint64_t", name: "g"),
                          parameter(1, width: 64, type: "uint64_t", name: "a"),
                          parameter(2, width: 64, type: "uint64_t", name: "b")]
        let rows = [
            row(0x1000, "60 00 00 b4", "cbz", "x0, 0x100c"),
            row(0x1004, "3f 00 00 b1", "cmn", "x1, #0"),
            row(0x1008, "02 00 00 14", "b", "0x1010"),
            row(0x100c, "5f 00 00 b1", "cmn", "x2, #0"),
            row(0x1010, "62 00 00 54", "b.hs", "0x101c"),
            row(0x1014, "00 00 80 52", "mov", "w0, #0"),
            row(0x1018, "c0 03 5f d6", "ret", ""),
            row(0x101c, "20 00 80 52", "mov", "w0, #1"),
            row(0x1020, "c0 03 5f d6", "ret", "")
        ]
        let ssa = MacIRConfiguration.ssaEnabled
        do {
            if ssa {
                let function = try lift(rows, parameters: parameters, ssa: ssa)
                let branch = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1010 })
                XCTAssertEqual(branch.operation, .intrinsic(destination: nil, name: "branch_hs",
                    arguments: [.immediate(0x101c)]))
            } else {
                // An unchanged direct native carry control, not an assertion
                // about reconciliation of the full native diamond.
                var state = BuilderState(parameters: parameters)
                let builder = MacIRBuilder(ssaEnabled: ssa)
                _ = builder.operation(for: MacIRSourceSpan(address: 0x100c, byteText: "5f 00 00 b1",
                    mnemonic: "cmn", operands: "x2, #0", comment: nil), state: &state)
                let branch = builder.operation(for: MacIRSourceSpan(address: 0x1010, byteText: "62 00 00 54",
                    mnemonic: "b.hs", operands: "0x101c", comment: nil), state: &state)
                func u(_ value: MacIRValue) -> MacIRValue { .unary(op: "(uint64_t)", value: value) }
                XCTAssertEqual(branch, .conditionalBranch(condition: ">",
                    left: u(.argument(bindingID: .gpr(2))),
                    right: u(.unary(op: "~", value: u(.immediate(0)))), target: .immediate(0x101c)))
            }
        }
    }
}
