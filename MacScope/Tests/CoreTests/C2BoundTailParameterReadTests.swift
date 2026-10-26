import Foundation
import XCTest
@testable import MacScope

final class C2BoundTailParameterReadTests: XCTestCase {
    private func fixture(
        requestedSSA: Bool = true, name: String = "_tail_caller", start: UInt64 = 0x1000,
        bytes: String = "00 04 00 14", target: UInt64 = 0x2000, callee: String = "_tail_callee",
        callerParameterType: String = "uint64_t", calleeParameterType: String = "uint64_t",
        operandPrefix: String = ""
    ) throws -> (MacIRFunction, MacIRInstruction, MacIRSourceSpan) {
        let row = InstructionRow(address: start, bytes: bytes, mnemonic: "b",
            operands: operandPrefix + "0x" + String(target, radix: 16), hasBreakpoint: false, comment: nil)
        let caller = FunctionSignatureOverride(returnType: "void",
            args: [ArgOverride(index: 0, name: "cinfo", type: callerParameterType)])
        let called = FunctionSignatureOverride(returnType: "void",
            args: [ArgOverride(index: 0, name: "cinfo", type: calleeParameterType)])
        let function = PseudocodePrinter().buildFunction(functionName: name,
            startAddress: start, signatureOverrides: [start: caller],
            authoredCallSignaturesByTarget: [callee: called],
            knownTailCallTargets: [target: callee],
            explicitCFGEnabled: true, ssaEnabled: requestedSSA, instructions: [row])
        XCTAssertEqual(function.ssaEnabled, requestedSSA)
        let call = try XCTUnwrap(function.instructions.first {
            if case .call = $0.operation { return true }; return false
        })
        guard case let .call(frame, result) = call.operation else {
            throw NSError(domain: "missing-tail-call", code: 1)
        }
        XCTAssertNil(result)
        XCTAssertEqual(frame.arguments.argument(at: .gpr(index: 0))?.value, .argument(bindingID: .gpr(0)))
        XCTAssertEqual(function.instructions.last?.operation, .returnValue(nil))
        let machine = MacIRSourceSpan(address: row.address, byteText: row.bytes,
            mnemonic: row.mnemonic, operands: row.operands, comment: row.comment,
            structuredOperands: row.structuredOperands)
        let returned = try XCTUnwrap(function.instructions.last)
        XCTAssertEqual(call.source.tailCallEffect,
            MacIRTailCallEffect(targetAddress: target, targetName: callee, phase: .call))
        XCTAssertEqual(returned.source.tailCallEffect,
            MacIRTailCallEffect(targetAddress: target, targetName: callee, phase: .returnAfterCall))
        var rawCall = call.source
        var rawReturn = returned.source
        rawCall.tailCallEffect = nil
        rawReturn.tailCallEffect = nil
        XCTAssertEqual(rawCall, machine)
        XCTAssertEqual(rawReturn, machine)
        return (function, call, machine)
    }

    func testBoundTypedTailFormalIsDirectReadInBothAccountingModes() throws {
        let (function, call, machine) = try fixture()
        let value = MacIRValue.argument(bindingID: .gpr(0))
        XCTAssertTrue(C2DataflowCensus.isBoundTypedTailParameterRead(value,
            instruction: call, machine: machine, function: function))
        let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
            deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
        let document = printer.print(function: function)
        XCTAssertTrue(document.lines.contains { $0.text.contains("_tail_callee(cinfo)") })
        for accounting in [false, true] {
            let result = C2DataflowCensus.analyze(function: function, document: document,
                machine: [machine], printer: printer, names: PseudocodeNameContext(function: function),
                ssaAccountingEnabled: accounting)
            XCTAssertNil(result.skippedReason)
            XCTAssertTrue(result.rows.isEmpty)
        }
    }

    func testFourRetainedPointerWrappersRequireSSACertificateInBothRequestedLifterModes() throws {
        let vectors: [(String, UInt64, String, UInt64, String, String)] = [
            ("_jpeg_destroy_compress", 0xe3c, "d3 69 00 14", 0x1b588, "_jpeg_destroy", "struct jpeg_compress_struct *"),
            ("_jpeg_abort_compress", 0xe40, "bc 69 00 14", 0x1b530, "_jpeg_abort", "struct jpeg_compress_struct *"),
            ("_jpeg_destroy_decompress", 0x213e0, "6a e8 ff 17", 0x1b588, "_jpeg_destroy", "struct jpeg_decompress_struct *"),
            ("_jpeg_abort_decompress", 0x213e4, "53 e8 ff 17", 0x1b530, "_jpeg_abort", "struct jpeg_decompress_struct *")
        ]
        // Fresh builder inputs for each requested mode. The explicit known-tail
        // map deliberately gives legacy lowering its existing product authority;
        // the new census exception still requires the retained SSA certificate.
        // Snapshot's automatic declared-tail handoff remains SSA-only, tested separately.
        for requestedSSA in [false, true] {
            for (name, start, bytes, target, callee, type) in vectors {
                let (function, call, machine) = try fixture(requestedSSA: requestedSSA,
                    name: name, start: start, bytes: bytes, target: target, callee: callee,
                    callerParameterType: type, calleeParameterType: "struct jpeg_common_struct *")
                XCTAssertEqual(C2DataflowCensus.isBoundTypedTailParameterRead(.argument(bindingID: .gpr(0)),
                    instruction: call, machine: machine, function: function), requestedSSA)
                XCTAssertEqual(call.source.tailCallEffect?.phase, .call)
                XCTAssertEqual(function.instructions.last?.source.tailCallEffect?.phase, .returnAfterCall)
            }
        }
    }

    func testTailReadRequiresPairedPhasesAndUnchangedRawSource() throws {
        for requestedSSA in [false, true] {
            let (original, call, machine) = try fixture(requestedSSA: requestedSSA)
            let entry = MacIRValue.argument(bindingID: .gpr(0))
            XCTAssertEqual(C2DataflowCensus.isBoundTypedTailParameterRead(entry,
                instruction: call, machine: machine, function: original), requestedSSA)
            let callPhase = try XCTUnwrap(call.source.tailCallEffect)
            let returnPhase = try XCTUnwrap(original.instructions.last?.source.tailCallEffect)
            let invalid: [(MacIRTailCallEffect?, MacIRTailCallEffect?)] = [
                (nil, returnPhase), (callPhase, nil), (returnPhase, callPhase),
                (.init(targetAddress: 0x3000, targetName: callPhase.targetName, phase: .call),
                 .init(targetAddress: 0x3000, targetName: callPhase.targetName, phase: .returnAfterCall)),
                (.init(targetAddress: callPhase.targetAddress, targetName: "_wrong", phase: .call),
                 .init(targetAddress: callPhase.targetAddress, targetName: "_wrong", phase: .returnAfterCall))
            ]
            for (badCall, badReturn) in invalid {
                var changed = original
                var retained = changed.ssaOriginalInstructions ?? changed.instructions
                for index in changed.instructions.indices {
                    switch changed.instructions[index].operation {
                    case .call: changed.instructions[index].source.tailCallEffect = badCall
                    case .returnValue: changed.instructions[index].source.tailCallEffect = badReturn
                    default: break
                    }
                }
                for index in retained.indices {
                    switch retained[index].operation {
                    case .call: retained[index].source.tailCallEffect = badCall
                    case .returnValue: retained[index].source.tailCallEffect = badReturn
                    default: break
                    }
                }
                changed.ssaOriginalInstructions = retained
                let changedCall = try XCTUnwrap(changed.instructions.first {
                    if case .call = $0.operation { return true }; return false
                })
                XCTAssertFalse(C2DataflowCensus.isBoundTypedTailParameterRead(entry,
                    instruction: changedCall, machine: machine, function: changed))
            }
            var changedRaw = machine
            changedRaw.comment = "different raw source"
            XCTAssertFalse(C2DataflowCensus.isBoundTypedTailParameterRead(entry,
                instruction: call, machine: changedRaw, function: original))
        }
    }

    func testProductNumericOperandPrefixDoesNotBecomeDisplayNameAuthority() throws {
        XCTAssertEqual(MacIRTailCallProof.address("0x2000"), 0x2000)
        XCTAssertEqual(MacIRTailCallProof.address("#0x2000"), 0x2000)
        XCTAssertNil(MacIRTailCallProof.address("_tail_callee"))
        XCTAssertNil(MacIRTailCallProof.address("cinfo"))
    }

    func testRenamingFormalDoesNotChangePhysicalTailReadIdentity() throws {
        var (function, call, machine) = try fixture()
        function.parameters[0].name = "not_a_register"
        XCTAssertTrue(C2DataflowCensus.isBoundTypedTailParameterRead(.argument(bindingID: .gpr(0)),
            instruction: call, machine: machine, function: function))
    }

    func testTailReadDoesNotAdmitOtherOperandShapesOrBindings() throws {
        let (function, call, machine) = try fixture()
        let entry = MacIRValue.argument(bindingID: .gpr(0))
        let values: [MacIRValue] = [.argument(bindingID: .gpr(1)), .register(name: "cinfo", version: 0),
            .register(name: "x0", version: 0), .immediate(0),
            .unary(op: "(uint32_t)", value: entry),
            .binaryExpression(op: "+", left: entry, right: .immediate(0))]
        for value in values {
            XCTAssertFalse(C2DataflowCensus.isBoundTypedTailParameterRead(value,
                instruction: call, machine: machine, function: function))
        }
    }

    func testSameNamedFormalWithDifferentGPRBindingOrViewStillRefuses() throws {
        let (original, call, machine) = try fixture()
        for location in [MacIRABIParameterLocation.gpr(index: 1, carrierWidth: 64),
                         .gpr(index: 0, carrierWidth: 32)] {
            var function = original
            XCTAssertTrue(function.parameters[0].rebind(bindingID: location.bindingID, abiLocation: location))
            function.parameters[0].name = "cinfo"
            XCTAssertFalse(C2DataflowCensus.isBoundTypedTailParameterRead(.argument(bindingID: .gpr(0)),
                instruction: call, machine: machine, function: function))
        }
    }

    func testTypedCallWithoutRetainedTailCertificateStillRefuses() throws {
        let (original, call, machine) = try fixture()
        var withoutGraph = original
        withoutGraph.cfg = nil
        var withoutOriginal = original
        withoutOriginal.ssaOriginalInstructions = nil
        var legacy = original
        legacy.ssaEnabled = false
        var ordinaryBranch = original
        var graph = try XCTUnwrap(ordinaryBranch.cfg)
        let block = try XCTUnwrap(graph.blocks.first { $0.instructionRange.contains(0) })
        graph.terminators[block.index] = .unconditional(target: 0x2000)
        ordinaryBranch.cfg = graph
        for function in [withoutGraph, withoutOriginal, legacy, ordinaryBranch] {
            XCTAssertFalse(C2DataflowCensus.isBoundTypedTailParameterRead(.argument(bindingID: .gpr(0)),
                instruction: call, machine: machine, function: function))
        }
    }

    func testTailReadRequiresExactMachineSourceAndEntryDefinition() throws {
        let (original, call, machine) = try fixture()
        var wrongMachine = machine
        wrongMachine.operands = "0x3000"
        XCTAssertFalse(C2DataflowCensus.isBoundTypedTailParameterRead(.argument(bindingID: .gpr(0)),
            instruction: call, machine: wrongMachine, function: original))
        var changed = original
        var info = try XCTUnwrap(changed.ssaInfo)
        let row = try XCTUnwrap(info.sourceAddresses.firstIndex(of: machine.address))
        let read = try XCTUnwrap(info.plan.rowReadBindings[row][0])
        let definition = info.plan.canonicalID(read)
        info.plan.definitions[definition].origin = .instruction(0xffc)
        changed.ssaInfo = info
        XCTAssertFalse(C2DataflowCensus.isBoundTypedTailParameterRead(.argument(bindingID: .gpr(0)),
            instruction: call, machine: machine, function: changed))
    }
}
