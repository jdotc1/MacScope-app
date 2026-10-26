import XCTest
@testable import MacScope

final class UnprovenCallArgumentTests: XCTestCase {
    func testIndirectCallOnlyAssertsConstructedX0() throws {
        try check([("mov", "x0, x19"), ("blr", "x8")], target: "(*x8)",
                  count: 1, comment: "/* unproven args: x1, x2 */")
    }

    func testHigherConstructedRegisterForcesCarriedGap() throws {
        try check([("mov", "x0, x19"), ("mov", "x2, #3"), ("blr", "x8")],
                  target: "(*x8)", count: 3, comment: nil)
    }

    func testKnownSignatureKeepsItsArity() throws {
        try check([("mov", "x0, x19"), ("bl", "_malloc")], target: "_malloc",
                  count: 1, comment: nil)
    }

    func testDefinitionBeforePreviousCallIsUnproven() throws {
        // Seed a retained carrier in the builder seam: call invalidation can make
        // caller-saved registers unavailable, but cannot grant construction proof.
        var state = BuilderState(parameters: [])
        state.writeRegister("x2")
        state.invalidateAppleCallerSavedState()
        state.currentIntegerDefinitionByIndex[2] = .init(value: .register(name: "x2", version: 1), width: 64)
        state.unavailableRegisterValues.remove("x2")
        state.unavailableRegisterValues.remove("w2")
        state.writeRegister("x0")
        let frame = try XCTUnwrap(state.callFrame(target: "_opaque", knownSignature: nil,
            controlInputs: .none, recoverObjectiveCTail: false))
        let function = build([("mov", "x2, #3"), ("bl", "_first"),
                              ("mov", "x0, x19"), ("blr", "x8")])
        XCTAssertEqual(frame.unknownArgumentCount, 1)
        XCTAssertEqual(frame.unprovenArgumentRegisters, ["x2"])
        let calls = function.instructions.compactMap { instruction -> MacIRCallFrame? in
            guard case let .call(frame, _) = instruction.operation else { return nil }
            return frame
        }
        XCTAssertEqual(calls.last?.unknownRenderValues().count, 1)
    }

    func testDirectUntypedCallUsesSameConstructionRule() throws {
        try check([("mov", "x0, x19"), ("bl", "_opaque")], target: "_opaque",
                  count: 1, comment: "/* unproven args: x1, x2 */")
    }

    private let signature = FunctionSignatureOverride(returnType: "void", args: [
        ArgOverride(index: 0, name: "context", type: "uint64_t"),
        ArgOverride(index: 1, name: "carried1", type: "uint64_t"),
        ArgOverride(index: 2, name: "carried2", type: "uint64_t")])

    private func build(_ operations: [(String, String)]) -> MacIRFunction {
        let rows = (operations + [("ret", "")]).enumerated().map { index, op in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "", mnemonic: op.0,
                           operands: op.1, hasBreakpoint: false, comment: nil)
        }
        return PseudocodePrinter().buildFunction(functionName: "caller", startAddress: 0x1000,
            signatureOverrides: [0x1000: signature], instructions: rows)
    }

    private func check(_ operations: [(String, String)], target: String, count: Int,
                       comment: String?, file: StaticString = #filePath, line: UInt = #line) throws {
        let function = build(operations)
        let frame = try XCTUnwrap(function.instructions.compactMap { instruction -> MacIRCallFrame? in
            guard case let .call(frame, _) = instruction.operation, frame.target == target else { return nil }
            return frame
        }.first, file: file, line: line)
        let values = frame.knownSignature == nil ? frame.unknownRenderValues() : frame.denseFixedRenderValues()
        XCTAssertEqual(values.count, count, file: file, line: line)
        let text = PseudocodePrinter().print(function: function).text
        if let comment {
            XCTAssertTrue(text.contains(comment), text, file: file, line: line)
        } else {
            XCTAssertFalse(text.contains("unproven args:"), text, file: file, line: line)
        }
        if frame.knownSignature == nil {
            let callLine = try XCTUnwrap(text.components(separatedBy: .newlines).first {
                $0.contains("\(target)(")
            }, text, file: file, line: line)
            let argumentList = try XCTUnwrap(callLine.components(separatedBy: "\(target)(").last?
                .components(separatedBy: ")").first, file: file, line: line)
            XCTAssertEqual(argumentList.split(separator: ",").count, count, callLine, file: file, line: line)
        }
    }
}
