import Foundation
import XCTest
@testable import MacScope

final class DirectVoidCallRenderingTests: XCTestCase {
    private let result = MacIRValue.register(name: "x0", version: 1)

    private func row(_ offset: UInt64, _ operation: MacIROperation,
                     mnemonic: String = "mov", operands: String = "") -> MacIRInstruction {
        MacIRInstruction(source: MacIRSourceSpan(address: 0x1000 + offset, byteText: "",
            mnemonic: mnemonic, operands: operands), operation: operation)
    }

    private func function(target: String = "callback", returnType: String? = "void",
                          mnemonic: String = "bl", hasResult: Bool = true,
                          following: [MacIRInstruction] = []) throws -> MacIRFunction {
        let signature = returnType.map { MacIRCallSignature(target: target, returnType: $0) }
        let frame = try XCTUnwrap(MacIRCallFrame(target: target, knownSignature: signature,
            controlInputs: .none, arguments: try XCTUnwrap(MacIRCallArguments([]))))
        return MacIRFunction(name: "caller", startAddress: 0x1000, returnType: "void",
            callTargets: [target], callSignatures: signature.map { [$0] } ?? [],
            instructions: [row(0, .call(frame: frame, result: hasResult ? result : nil),
                               mnemonic: mnemonic, operands: target)] + following
                + [row(0x100, .returnValue(nil), mnemonic: "ret")])
    }

    private func assertKept(_ function: MacIRFunction, file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertEqual(PseudocodePrinter.projectDirectVoidCallResults(function), function,
                       file: file, line: line)
    }

    func testKnownVoidDeadResultBecomesBareWithoutChangingFrameOrSource() throws {
        let original = try function()
        let projected = PseudocodePrinter.projectDirectVoidCallResults(original)
        guard case let .call(oldFrame, oldResult) = original.instructions[0].operation,
              case let .call(newFrame, newResult) = projected.instructions[0].operation else {
            return XCTFail("Expected direct calls")
        }
        XCTAssertNotNil(oldResult)
        XCTAssertNil(newResult)
        XCTAssertEqual(oldFrame, newFrame)
        XCTAssertEqual(original.instructions[0].source, projected.instructions[0].source)
        let text = PseudocodePrinter().print(function: original).text
        XCTAssertTrue(text.contains("callback();"), text)
        XCTAssertFalse(text.contains("= callback("), text)
    }

    func testPrototypeTableVoidAuthorityIsSufficient() throws {
        var value = try function(returnType: nil)
        value.callSignatures = [MacIRCallSignature(target: "callback", returnType: "void")]
        let projected = PseudocodePrinter.projectDirectVoidCallResults(value)
        guard case let .call(_, result) = projected.instructions[0].operation else {
            return XCTFail("Expected direct call")
        }
        XCTAssertNil(result)
    }

    func testStackFailureReturnOnlyAuthorityPreservesExistingFrame() throws {
        let original = try function(target: "___stack_chk_fail", returnType: nil)
        var expected = original
        guard case let .call(frame, _) = original.instructions[0].operation else {
            return XCTFail("Expected direct call")
        }
        expected.instructions[0].operation = .call(frame: frame, result: nil)
        XCTAssertEqual(PseudocodePrinter.projectDirectVoidCallResults(original), expected)
    }

    func testAlreadyBareCallsAreUnchanged() throws {
        for target in ["callback", "___stack_chk_fail"] {
            let value = try function(target: target, hasResult: false)
            assertKept(value)
        }
    }

    func testNonvoidLiveResultIsKept() throws {
        let read = row(4, .store(source: result, address: .register(name: "x19", version: 0)),
                       mnemonic: "str", operands: "x0, [x19]")
        let value = try function(returnType: "long", following: [read])
        assertKept(value)
        let text = PseudocodePrinter().print(function: value).text
        XCTAssertTrue(text.contains("= callback("), text)
    }

    func testVoidResultReadBeforeRedefinitionIsKept() throws {
        let read = row(4, .store(source: result, address: .register(name: "x19", version: 0)),
                       mnemonic: "str", operands: "x0, [x19]")
        assertKept(try function(following: [read]))
    }

    func testW0AliasReadBeforeRedefinitionIsKept() throws {
        let read = row(4, .store(source: .register(name: "w0", version: 1),
                               address: .register(name: "x19", version: 0)),
                       mnemonic: "str", operands: "w0, [x19]")
        assertKept(try function(following: [read]))
    }

    func testNewRegisterVersionDoesNotKeepDeadResultAlive() throws {
        let write = row(4, .assign(destination: .register(name: "x0", version: 2),
                                   source: .immediate(7)))
        let read = row(8, .store(source: .register(name: "w0", version: 2),
                               address: .register(name: "x19", version: 0)))
        let projected = PseudocodePrinter.projectDirectVoidCallResults(
            try function(following: [write, read]))
        guard case let .call(_, result) = projected.instructions[0].operation else {
            return XCTFail("Expected direct call")
        }
        XCTAssertNil(result)
    }

    func testTailCallEnvelopeIsUnchanged() throws {
        assertKept(try function(mnemonic: "b"))
    }

    func testUnknownReturnTypeEvenWithUnusedResultIsKept() throws {
        assertKept(try function(returnType: nil))
    }

    func testConflictingNonvoidPrototypeIsKept() throws {
        var value = try function()
        value.callSignatures = [MacIRCallSignature(target: "callback", returnType: "long")]
        assertKept(value)
    }

    func testUnknownOperationFailsClosed() throws {
        let unknown = row(4, .unknown(destination: nil, inputs: MacIRUnknownInputs(),
                                     mnemonic: "opaque", operands: ""))
        assertKept(try function(following: [unknown]))
    }

    func testFunctionReturnValueReadIsKept() throws {
        var value = try function()
        value.returnValue = result
        assertKept(value)
    }

    func testSSAFunctionIsUnchanged() throws {
        var value = try function()
        value.ssaEnabled = true
        assertKept(value)
    }

    func testSemanticAnnotationFailsClosed() throws {
        var annotated = row(4, .assign(destination: .register(name: "d0", version: 1),
                                       source: .register(name: "d1", version: 0)))
        annotated.scalarFP = MacIRScalarFP(operation: .negate, inputType: .binary64,
                                           resultType: .binary64)
        assertKept(try function(following: [annotated]))
    }

}

final class OwnCalleeReturnEvidenceTests: XCTestCase {
    private func row(_ address: UInt64, _ operation: MacIROperation,
                     mnemonic: String = "mov", operands: String = "") -> MacIRInstruction {
        MacIRInstruction(source: MacIRSourceSpan(address: address, byteText: "",
            mnemonic: mnemonic, operands: operands), operation: operation)
    }
    private func function(_ address: UInt64, _ rows: [MacIRInstruction]) -> MacIRFunction {
        MacIRFunction(name: "own_\(address)", startAddress: address, instructions: rows)
    }
    private func tail(_ address: UInt64, _ target: UInt64) throws -> MacIRInstruction {
        let frame = try XCTUnwrap(MacIRCallFrame(target: "own_\(target)", knownSignature: nil,
            controlInputs: .none, arguments: try XCTUnwrap(MacIRCallArguments([]))))
        return row(address, .call(frame: frame, result: nil), mnemonic: "b",
                   operands: "0x\(String(target, radix: 16))")
    }
    func testNoWriteReturnIsUnknownNotVoid() {
        let body = function(0x1000, [row(0x1000, .returnValue(nil), mnemonic: "ret")])
        let summary = MacIROwnCalleeReturnEvidence.collect(functions: [body]).summary(at: 0x1000)
        XCTAssertEqual(summary.outcome, .unknown)
        XCTAssertTrue(summary.writingPath.isEmpty)
    }
    func testIncomingX0ForwardingIsUnknown() {
        let body = function(0x1000, [row(0x1000,
            .returnValue(.register(name: "x0", version: 0)), mnemonic: "ret")])
        XCTAssertEqual(MacIROwnCalleeReturnEvidence.collect(functions: [body])
            .summary(at: 0x1000).outcome, .unknown)
    }
    func testW0WrittenOnOnlyOneBranchHasWritingPath() {
        let body = function(0x1000, [
            row(0x1000, .conditionalBranch(condition: "==", left: .register(name: "x1", version: 0),
                right: .immediate(0), target: .immediate(0x1008)), mnemonic: "cbz"),
            row(0x1004, .assign(destination: .register(name: "w0", version: 1), source: .immediate(1))),
            row(0x1008, .returnValue(nil), mnemonic: "ret")])
        let summary = MacIROwnCalleeReturnEvidence.collect(functions: [body]).summary(at: 0x1000)
        XCTAssertEqual(summary.outcome, .writesX0)
        XCTAssertEqual(summary.writingPath.map(\.instruction), [0x1000, 0x1004, 0x1008])
    }
    func testRecursivePairWithoutSeedStaysUnknown() throws {
        let a = function(0x1000, [try tail(0x1000, 0x2000)])
        let b = function(0x2000, [try tail(0x2000, 0x1000)])
        let report = MacIROwnCalleeReturnEvidence.collect(functions: [a, b])
        XCTAssertEqual(report.summary(at: 0x1000).outcome, .unknown)
        XCTAssertEqual(report.summary(at: 0x2000).outcome, .unknown)
    }
    func testTailChainPropagatesConcreteWriteWitness() throws {
        let a = function(0x1000, [try tail(0x1000, 0x2000)])
        let b = function(0x2000, [
            row(0x2000, .assign(destination: .register(name: "x0", version: 1), source: .immediate(7))),
            row(0x2004, .returnValue(nil), mnemonic: "ret")])
        let summary = MacIROwnCalleeReturnEvidence.collect(functions: [a, b]).summary(at: 0x1000)
        XCTAssertEqual(summary.outcome, .writesX0)
        XCTAssertEqual(summary.writingPath.map(\.instruction), [0x1000, 0x2000, 0x2004])
    }
    func testOpaqueIntrinsicStopsWitnessPath() {
        let body = function(0x1000, [
            row(0x1000, .assign(destination: .register(name: "w0", version: 1), source: .immediate(1))),
            row(0x1004, .intrinsic(destination: nil, name: "opaque", arguments: [])),
            row(0x1008, .returnValue(nil), mnemonic: "ret")])
        XCTAssertEqual(MacIROwnCalleeReturnEvidence.collect(functions: [body])
            .summary(at: 0x1000).outcome, .unknown)
    }
    func testExternalTailAndDuplicateBodyFailClosed() throws {
        let body = function(0x1000, [try tail(0x1000, 0x2000)])
        XCTAssertEqual(MacIROwnCalleeReturnEvidence.collect(functions: [body])
            .summary(at: 0x1000).outcome, .unknown)
        let written = function(0x1000, [
            row(0x1000, .assign(destination: .register(name: "x0", version: 1), source: .immediate(7))),
            row(0x1004, .returnValue(nil), mnemonic: "ret")])
        XCTAssertEqual(MacIROwnCalleeReturnEvidence.collect(functions: [body, written])
            .summary(at: 0x1000).outcome, .unknown)
    }
    func testOrdinaryCallCannotSeedOwnWrite() throws {
        let frame = try XCTUnwrap(MacIRCallFrame(target: "opaque", knownSignature: nil,
            controlInputs: .none, arguments: try XCTUnwrap(MacIRCallArguments([]))))
        let body = function(0x1000, [row(0x1000,
            .call(frame: frame, result: .register(name: "x0", version: 1)), mnemonic: "bl"),
            row(0x1004, .returnValue(nil), mnemonic: "ret")])
        XCTAssertEqual(MacIROwnCalleeReturnEvidence.collect(functions: [body])
            .summary(at: 0x1000).outcome, .unknown)
    }
}

final class OwnDirectDeadResultRenderingTests: XCTestCase {
    private let result = MacIRValue.register(name: "x0", version: 1)
    private func row(_ address: UInt64, _ operation: MacIROperation,
                     mnemonic: String, operands: String) -> MacIRInstruction {
        MacIRInstruction(source: MacIRSourceSpan(address: address, byteText: "",
            mnemonic: mnemonic, operands: operands), operation: operation)
    }
    private func function(_ following: [MacIRInstruction]) throws -> MacIRFunction {
        let frame = try XCTUnwrap(MacIRCallFrame(target: "own", knownSignature: nil,
            controlInputs: .none, arguments: try XCTUnwrap(MacIRCallArguments([]))))
        return MacIRFunction(name: "caller", startAddress: 0x1000, instructions:
            [row(0x1000, .call(frame: frame, result: result), mnemonic: "bl", operands: "own")] + following)
    }
    private func kill(_ address: UInt64 = 0x1004) -> MacIRInstruction {
        row(address, .assign(destination: .register(name: "w0", version: 2), source: .immediate(0)),
            mnemonic: "mov", operands: "w0, #0")
    }
    private func assertAssignmentKept(_ original: MacIRFunction,
                                      ownCalls: Set<UInt64> = [0x1000], target: String = "own",
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(PseudocodePrinter.projectDirectVoidCallResults(original,
            ownDirectCallAddresses: ownCalls), original, file: file, line: line)
        let text = PseudocodePrinter().print(function: original, ownDirectCallAddresses: ownCalls).text
        XCTAssertTrue(text.contains("= \(target)("), text, file: file, line: line)
    }
    func testOwnDeadResultBecomesBareWithoutCalleeVoidClaim() throws {
        let original = try function([kill(), row(0x1008, .returnValue(nil), mnemonic: "ret", operands: "")])
        let projected = PseudocodePrinter.projectDirectVoidCallResults(original, ownDirectCallAddresses: [0x1000])
        guard case let .call(oldFrame, _) = original.instructions[0].operation,
              case let .call(newFrame, newResult) = projected.instructions[0].operation else {
            return XCTFail("Expected preserved call")
        }
        XCTAssertNil(newResult)
        XCTAssertEqual(oldFrame, newFrame)
        XCTAssertEqual(projected.returnType, original.returnType)
        XCTAssertEqual(projected.callSignatures, original.callSignatures)
        XCTAssertEqual(projected.instructions.map(\.source), original.instructions.map(\.source))
        XCTAssertEqual(projected.instructions.count, original.instructions.count)
        let document = PseudocodePrinter().print(function: original, ownDirectCallAddresses: [0x1000])
        XCTAssertTrue(document.text.contains("own();"), document.text)
        XCTAssertFalse(document.text.contains("= own("), document.text)
        XCTAssertEqual(document.returnType, original.returnType)
        XCTAssertEqual(document.callSignatures, original.callSignatures)
    }
    func testExternalIdentityAbsentKeepsEvenDeadResult() throws {
        let original = try function([kill()])
        assertAssignmentKept(original, ownCalls: [])
    }
    func testReadOnOneBranchKeepsResult() throws {
        let original = try function([
            row(0x1004, .conditionalBranch(condition: "==", left: .register(name: "x1", version: 0),
                right: .immediate(0), target: .immediate(0x1010)), mnemonic: "cbz", operands: "x1, 0x1010"),
            row(0x1008, .assign(destination: .register(name: "x2", version: 1), source: result),
                mnemonic: "mov", operands: "x2, x0"), kill(0x1010)])
        assertAssignmentKept(original)
    }
    func testNextCallWithUnrecoveredX0ArgumentKeepsResult() throws {
        let frame = try XCTUnwrap(MacIRCallFrame(target: "next", knownSignature: nil,
            controlInputs: .none, arguments: try XCTUnwrap(MacIRCallArguments([]))))
        let original = try function([row(0x1004, .call(frame: frame, result: nil),
            mnemonic: "bl", operands: "next"), kill(0x1008)])
        assertAssignmentKept(original)
    }
    func testFoldedRawReadBeforeWriteKeepsResult() throws {
        let original = try function([row(0x1004,
            .assign(destination: .register(name: "x2", version: 1), source: .immediate(7)),
            mnemonic: "mov", operands: "x2, x0"), kill(0x1008)])
        assertAssignmentKept(original)
    }
    func testReadModifyWriteIsNotAKill() throws {
        let original = try function([row(0x1004,
            .binary(destination: .register(name: "x0", version: 2), op: "+", left: .immediate(7), right: .immediate(1)),
            mnemonic: "add", operands: "x0, x0, #1")])
        assertAssignmentKept(original)
    }
    func testReturnAndRecursiveTailKeepResult() throws {
        let ret = try function([row(0x1004, .returnValue(nil), mnemonic: "ret", operands: "")])
        assertAssignmentKept(ret)
        let frame = try XCTUnwrap(MacIRCallFrame(target: "caller", knownSignature: nil,
            controlInputs: .none, arguments: try XCTUnwrap(MacIRCallArguments([]))))
        let tail = try function([row(0x1004, .call(frame: frame, result: nil),
            mnemonic: "b", operands: "0x1000")])
        assertAssignmentKept(tail)
    }
    func testRecursivePairKeepsBothRenderedAssignments() throws {
        var caller = try function([
            row(0x1004, .returnValue(nil), mnemonic: "ret", operands: "")])
        caller.instructions[0].source.operands = "0x2000"
        let frame = try XCTUnwrap(MacIRCallFrame(target: "caller", knownSignature: nil,
            controlInputs: .none, arguments: try XCTUnwrap(MacIRCallArguments([]))))
        let own = MacIRFunction(name: "own", startAddress: 0x2000, instructions: [
            row(0x2000, .call(frame: frame, result: result), mnemonic: "bl", operands: "0x1000"),
            row(0x2004, .returnValue(nil), mnemonic: "ret", operands: "")])
        let report = MacIROwnCalleeReturnEvidence.collect(functions: [caller, own])
        XCTAssertEqual(report.summary(at: 0x1000).outcome, .unknown)
        XCTAssertEqual(report.summary(at: 0x2000).outcome, .unknown)
        assertAssignmentKept(caller)
        assertAssignmentKept(own, ownCalls: [0x2000], target: "caller")
    }
}
