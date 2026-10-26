import XCTest
@testable import MacScope

final class MacIRTailCallLoweringTests: XCTestCase {
    private func rows(_ operations: [(String, String)]) -> [InstructionRow] {
        operations.enumerated().map { index, operation in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "",
                           mnemonic: operation.0, operands: operation.1,
                           hasBreakpoint: false, comment: nil)
        }
    }

    private func build(
        _ operations: [(String, String)],
        knownTargets: [UInt64: String] = [:],
        jumpTables: [UInt64: [UInt64]] = [:],
        returnLocation: DarwinARM64RichReturnLocation = .single(.gpr(index: 0, carrierWidth: 64)),
        returnType: String = "uint64_t"
    ) -> MacIRFunction {
        MacIRBuilder().buildFunction(
            name: "_tail_fixture", startAddress: 0x1000,
            jumpTables: jumpTables,
            authoritativeReturnLocation: returnLocation,
            authoritativeReturnType: returnType,
            knownTailCallTargets: knownTargets,
            instructions: rows(operations)
        )
    }

    private func operation(
        at address: UInt64, in function: MacIRFunction,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> MacIROperation {
        try XCTUnwrap(function.instructions.first { $0.source.address == address },
                      file: file, line: line).operation
    }

    private func assertCallAndReturnEquivalent(
        _ tail: MacIRFunction, to ordinary: MacIRFunction, at address: UInt64,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let effects = tail.instructions.filter { $0.source.address == address }.map(\.operation)
        let ordinaryEffects = ordinary.instructions.suffix(2).map(\.operation)
        XCTAssertEqual(effects.count, 2, "one tail row must emit call then return", file: file, line: line)
        guard effects.count == 2 else { return }
        guard case .call = effects[0] else {
            return XCTFail("tail branch must use the existing call operation", file: file, line: line)
        }
        guard case .returnValue = effects[1] else {
            return XCTFail("tail call must immediately terminate with returnValue", file: file, line: line)
        }
        XCTAssertEqual(effects, ordinaryEffects,
                       "reuse BL/BLR argument binding, call result, and explicit return contract",
                       file: file, line: line)
        XCTAssertEqual(tail.callTargets, ordinary.callTargets, file: file, line: line)
        XCTAssertEqual(tail.callSignatures, ordinary.callSignatures, file: file, line: line)
        XCTAssertEqual(tail.returnValue, ordinary.returnValue, file: file, line: line)

        // Appending an unreachable IR block makes a missing terminator
        // observable even when the architectural tail branch was the last row.
        var withDeadSuccessor = tail.instructions
        withDeadSuccessor.append(MacIRInstruction(
            source: MacIRSourceSpan(address: address + 4, byteText: "c0 03 5f d6",
                                   mnemonic: "ret", operands: ""),
            operation: .returnValue(.immediate(99))))
        let cfg = CFGBuilder.buildCFG(instructions: withDeadSuccessor)
        let callIndex = try XCTUnwrap(withDeadSuccessor.firstIndex {
            $0.source.address == address
        }, file: file, line: line)
        let tailBlock = try XCTUnwrap(cfg.blocks.first {
            $0.instructionRange.contains(callIndex)
        }, file: file, line: line)
        XCTAssertTrue(tailBlock.successors.isEmpty,
                      "tail call must have no fall-through edge", file: file, line: line)
        let deadBlock = try XCTUnwrap(cfg.blocks.last, file: file, line: line)
        XCTAssertNotEqual(tailBlock.index, deadBlock.index, file: file, line: line)
        XCTAssertTrue(deadBlock.predecessors.isEmpty, file: file, line: line)
    }

    private func assertDirectTail(
        _ prefix: [(String, String)],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let address = 0x1000 + UInt64(prefix.count * 4)
        let tail = build(prefix + [("b", "0x2000")], knownTargets: [0x2000: "_callee"])
        let ordinary = build(prefix + [("bl", "_callee"), ("ret", "")])
        try assertCallAndReturnEquivalent(tail, to: ordinary, at: address, file: file, line: line)
        let text = PseudocodePrinter().print(function: tail).text
        XCTAssertTrue(text.contains("return _callee("), text, file: file, line: line)
        XCTAssertFalse(text.contains("__branch("), text, file: file, line: line)
        XCTAssertFalse(text.contains("unresolved_return_contract"), text, file: file, line: line)
    }

    private func assertRefusedDirectTail(
        _ operations: [(String, String)], at address: UInt64,
        knownTargets: [UInt64: String] = [0x2000: "_callee"],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let function = build(operations, knownTargets: knownTargets)
        XCTAssertEqual(try operation(at: address, in: function, file: file, line: line),
                       .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x2000)]),
                       file: file, line: line)
        XCTAssertFalse(function.instructions.contains {
            guard $0.source.address == address else { return false }
            if case .call = $0.operation { return true }
            return false
        }, file: file, line: line)
        let text = PseudocodePrinter().print(function: function).text
        // A retained external branch stays explicit in every presentation.
        GotoLabelWellFormednessTests.assertTransfer(text, target: 0x2000)
    }

    func testLeafKnownFunctionBranchLowersLikeBLAndRet() throws {
        try assertDirectTail([])
    }

    func testAdjacentFrameRestoreBranchLowersLikeBLAndRet() throws {
        try assertDirectTail([
            ("stp", "x29, x30, [sp, #-16]!"),
            ("mov", "x0, #7"),
            ("ldp", "x29, x30, [sp], #16"),
        ])
    }

    func testClangNonAdjacentFrameRestoreBranchLowersLikeBLAndRet() throws {
        try assertDirectTail([
            ("sub", "sp, sp, #0x30"),
            ("stp", "x29, x30, [sp, #0x20]"),
            ("stp", "x20, x19, [sp, #0x10]"),
            ("mov", "x0, #7"),
            ("ldp", "x29, x30, [sp, #0x20]"),
            ("ldp", "x20, x19, [sp, #0x10]"),
            ("add", "sp, sp, #0x30"),
        ])
    }

    func testBalancedIndirectBranchKeepsOpaqueBranch() throws {
        let function = build([("br", "x8")], knownTargets: [0x2000: "_callee"])
        XCTAssertEqual(try operation(at: 0x1000, in: function),
                       .intrinsic(destination: nil, name: "branch_register",
                                  arguments: [.register(name: "x8", version: 0)]))
        XCTAssertTrue(function.callTargets.isEmpty)
        XCTAssertEqual(function.instructions.count, 1)
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("__branch_register(x8_0)"), text)
        XCTAssertFalse(text.contains("// call"), text)
        XCTAssertFalse(text.contains("return "), text)
    }

    func testVoidReturnContractDoesNotReturnTheCalleeResult() throws {
        let tail = build([("b", "0x2000")], knownTargets: [0x2000: "_callee"],
                         returnLocation: .void, returnType: "void")
        let ordinary = build([("bl", "_callee"), ("ret", "")],
                             returnLocation: .void, returnType: "void")
        try assertCallAndReturnEquivalent(tail, to: ordinary, at: 0x1000)
        XCTAssertEqual(tail.instructions.last?.operation, .returnValue(nil))
        let text = PseudocodePrinter().print(function: tail).text
        XCTAssertTrue(text.contains("_callee();"), text)
        XCTAssertTrue(text.contains("return;"), text)
        XCTAssertFalse(text.contains("return _callee("), text)
    }

    func testUnknownReturnContractRemainsUnresolvedAfterTailCall() throws {
        let function = MacIRBuilder().buildFunction(
            name: "_unknown_return_tail", startAddress: 0x1000,
            authoritativeReturnLocation: nil, authoritativeReturnType: nil,
            callerReturnWidth: nil,
            knownTailCallTargets: [0x2000: "_callee"],
            instructions: rows([("b", "0x2000")]))
        guard case .call = try operation(at: 0x1000, in: function) else {
            return XCTFail("the transfer can be proven without inventing a return contract")
        }
        XCTAssertEqual(function.instructions.last?.operation,
                       .returnValue(.unknown("unresolved_return_contract")))
        XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("_callee("), text)
        XCTAssertTrue(text.contains("unresolved_return_contract"), text)
        XCTAssertFalse(text.contains("return _callee("), text)
    }

    func testReturnTypeSpellingAloneDoesNotInventAReturnLocation() {
        let function = MacIRBuilder().buildFunction(name: "_type_only", startAddress: 0x1000,
            authoritativeReturnType: "void", knownTailCallTargets: [0x2000: "_callee"],
            instructions: rows([("b", "0x2000")]))
        XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
    }

    func testKnownTailTargetReusesExistingCallSignature() throws {
        // The exact address is supplied independently of the catalog name.
        // No signature is inferred merely because an address was admitted.
        let prefix = [("mov", "x0, #0x8000")]
        let tail = build(prefix + [("b", "0x2000")], knownTargets: [0x2000: "_strlen"])
        let ordinary = build(prefix + [("bl", "_strlen"), ("ret", "")])
        try assertCallAndReturnEquivalent(tail, to: ordinary, at: 0x1004)
        guard case let .call(frame, _) = try operation(at: 0x1004, in: tail) else {
            return XCTFail("expected known-signature tail call")
        }
        XCTAssertEqual(frame.knownSignature?.target, "_strlen")
        XCTAssertEqual(frame.knownSignature?.parameters.count, 1)
        XCTAssertEqual(frame.knownSignature?.returnType, "size_t")
    }

    func testLeafCatalogTailCallSeedsUntouchedIncomingArguments() throws {
        let tail = build([("b", "0x2000")], knownTargets: [0x2000: "_memcpy"])
        let ordinary = build([("bl", "_memcpy"), ("ret", "")])
        try assertCallAndReturnEquivalent(tail, to: ordinary, at: 0x1000)
        XCTAssertEqual(tail.parameters, ordinary.parameters)
        XCTAssertEqual(tail.parameters.count, 3, "untouched catalog arguments are entry parameters")
    }

    func testIntraFunctionBranchKeepsItsSuccessor() throws {
        let function = build([
            ("b", "0x1008"), ("mov", "x0, #99"),
            ("mov", "x0, #7"), ("ret", ""),
        ], knownTargets: [0x2000: "_callee"])
        XCTAssertEqual(try operation(at: 0x1000, in: function),
                       .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x1008)]))
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let entry = try XCTUnwrap(cfg.blocks.first)
        let targetAddresses = entry.successors.map {
            function.instructions[cfg.blocks[$0].startIndex].source.address
        }
        XCTAssertEqual(targetAddresses, [0x1008])
        XCTAssertTrue(function.callTargets.isEmpty)
    }

    func testUnknownExternalAddressDoesNotBorrowAnotherFunctionsName() throws {
        try assertRefusedDirectTail([("b", "0x2000")], at: 0x1000,
                                    knownTargets: [0x2004: "_callee"])
    }

    func testEmptyKnownTargetMapKeepsDirectBranch() throws {
        try assertRefusedDirectTail([("b", "0x2000")], at: 0x1000, knownTargets: [:])
    }

    func testDisplayNameAloneDoesNotProveAFunctionStart() throws {
        let function = build([("b", "_callee")], knownTargets: [:])
        XCTAssertEqual(try operation(at: 0x1000, in: function),
                       .intrinsic(destination: nil, name: "branch", arguments: [.symbol("_callee")]))
        XCTAssertTrue(function.callTargets.isEmpty)
    }

    func testUnbalancedStackKeepsDirectBranch() throws {
        try assertRefusedDirectTail([
            ("stp", "x29, x30, [sp, #-16]!"),
            ("ldp", "x29, x30, [sp]"),
            ("b", "0x2000"),
        ], at: 0x1008)
    }

    func testLinkRegisterClobberAfterRestoreKeepsDirectBranch() throws {
        try assertRefusedDirectTail([
            ("stp", "x29, x30, [sp, #-16]!"),
            ("ldp", "x29, x30, [sp], #16"),
            ("mov", "x30, x1"),
            ("b", "0x2000"),
        ], at: 0x100c)
    }

    func testIncomingBranchAfterRestoreKeepsDirectBranch() throws {
        // The candidate's entry path is straight. A separate, later block
        // enters strictly after its restore, not at the function entry.
        try assertRefusedDirectTail([
            ("stp", "x29, x30, [sp, #-16]!"),
            ("ldp", "x29, x30, [sp], #16"),
            ("mov", "x0, #7"),
            ("b", "0x2000"),
            ("b", "0x1008"),
        ], at: 0x100c)
    }

    func testWrongSavedSlotKeepsDirectBranch() throws {
        try assertRefusedDirectTail([
            ("sub", "sp, sp, #32"),
            ("stp", "x29, x30, [sp, #16]"),
            ("ldp", "x29, x30, [sp]"),
            ("add", "sp, sp, #32"),
            ("b", "0x2000"),
        ], at: 0x1010)
    }

    func testUnclassifiedWindowInstructionKeepsDirectBranch() throws {
        try assertRefusedDirectTail([
            ("stp", "x29, x30, [sp, #-16]!"),
            ("ldp", "x29, x30, [sp], #16"),
            ("mrs", "x12, nzcv"),
            ("b", "0x2000"),
        ], at: 0x100c)
    }

    func testRecoveredSwitchWinsOverBalancedTailCallProof() throws {
        let function = build([
            ("stp", "x29, x30, [sp, #-16]!"),
            ("mov", "x0, #1"),
            ("ldp", "x29, x30, [sp], #16"),
            ("br", "x2"),
            ("mov", "x0, #99"), ("ret", ""), // Not a table target.
            ("mov", "x0, #10"), ("ret", ""),
            ("mov", "x0, #20"), ("ret", ""),
        ], knownTargets: [0x2000: "_callee"],
           jumpTables: [0x100c: [0x1018, 0x1020]])
        XCTAssertEqual(try operation(at: 0x100c, in: function), .switchDispatch(
            index: .unknown("unproven_switch_selector"),
            cases: [
                MacIRSwitchCase(value: 0, target: .immediate(0x1018)),
                MacIRSwitchCase(value: 1, target: .immediate(0x1020)),
            ], defaultTarget: nil))
        XCTAssertTrue(function.callTargets.isEmpty)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let dispatchIndex = try XCTUnwrap(function.instructions.firstIndex { $0.source.address == 0x100c })
        let dispatchBlock = try XCTUnwrap(cfg.blocks.first { $0.instructionRange.contains(dispatchIndex) })
        let successors = Set(dispatchBlock.successors.map {
            function.instructions[cfg.blocks[$0].startIndex].source.address
        })
        XCTAssertEqual(successors, Set<UInt64>([0x1018, 0x1020]))
        XCTAssertFalse(successors.contains(0x1010), "switch must not acquire a fall-through edge")
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("switch ("), text)
        XCTAssertFalse(text.contains("__branch_register("), text)
    }
    // Authored encodings, not a decoder receipt: B uses signed imm26 * 4;
    // 0x14000400 branches from 0x1000 to 0x2000. The printer consumes the
    // explicit instruction rows below; decoding is outside this test boundary.
    private func publicTailRows(unbalanced: Bool = false) -> [InstructionRow] {
        if unbalanced {
            return [
                InstructionRow(address: 0x1000, bytes: "ff 43 00 d1", mnemonic: "sub",
                    operands: "sp, sp, #16", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1004, bytes: "ff 03 00 14", mnemonic: "b",
                    operands: "0x2000", hasBreakpoint: false, comment: nil)
            ]
        }
        return [InstructionRow(address: 0x1000, bytes: "00 04 00 14", mnemonic: "b",
            operands: "0x2000", hasBreakpoint: false, comment: nil)]
    }

    func testPublicPrinterForwardsExactTailTargetAndIndependentReturnAuthority() {
        let signature = FunctionSignatureOverride(returnType: "uint64_t", args: [])
        let text = PseudocodePrinter().print(functionName: "_public_tail", startAddress: 0x1000,
            signatureOverrides: [0x1000: signature], knownTailCallTargets: [0x2000: "_callee"],
            instructions: publicTailRows()).text
        XCTAssertTrue(text.contains("return _callee("), text)
        XCTAssertFalse(text.contains("unresolved_return_contract"), text)
        XCTAssertFalse(text.contains("__branch("), text)
        let bounded = PseudocodePrinter().printBoundedText(functionName: "_public_tail",
            startAddress: 0x1000, signatureOverrides: [0x1000: signature],
            knownTailCallTargets: [0x2000: "_callee"], instructions: publicTailRows(),
            maximumUTF8Bytes: 65536)
        XCTAssertTrue(bounded.text.contains("_callee("), bounded.text)
        XCTAssertFalse(bounded.text.contains("unresolved_return_contract"), bounded.text)
        XCTAssertFalse(bounded.text.contains("__branch("), bounded.text)
        XCTAssertFalse(bounded.wasTruncated)
    }

    func testPublicPrinterDoesNotBorrowCalleeAuthorityForUnknownFunctionReturn() {
        let text = PseudocodePrinter().print(functionName: "_public_tail", startAddress: 0x1000,
            knownTailCallTargets: [0x2000: "_callee"], instructions: publicTailRows()).text
        XCTAssertTrue(text.contains("_callee("), text)
        XCTAssertTrue(text.contains("return unresolved_return_contract;"), text)
        XCTAssertFalse(text.contains("return _callee("), text)
    }

    func testPublicPrinterKeepsUnknownTargetAndUnbalancedFrameAsBranches() {
        let signature = FunctionSignatureOverride(returnType: "uint64_t", args: [])
        for (targets, unbalanced) in [([UInt64: String](), false),
                                      ([UInt64(0x2004): "_callee"], false),
                                      ([UInt64(0x2000): "_callee"], true)] {
            let text = PseudocodePrinter().print(functionName: "_public_tail", startAddress: 0x1000,
                signatureOverrides: [0x1000: signature], knownTailCallTargets: targets,
                instructions: publicTailRows(unbalanced: unbalanced)).text
            XCTAssertFalse(text.contains("return _callee("), text)
            XCTAssertTrue(text.contains("__branch(0x2000)") || text.contains("goto 0x2000;"), text)
        }
    }

    func testWorkspaceTailTargetMapRequiresFlagAndUniqueOriginalIdentity() {
        func snapshot(duplicate: Bool) -> WorkspaceSnapshot {
            var analysis = ImageAnalysis()
            analysis.functions = [
                FunctionSummary(id: UUID(), name: "_public_tail", startAddress: 0x1000, endAddress: 0x1004, confidence: 1),
                FunctionSummary(id: UUID(), name: "_callee", startAddress: 0x2000, endAddress: 0x2004, confidence: 1)
            ]
            if duplicate {
                analysis.functions.append(FunctionSummary(id: UUID(), name: "_other", startAddress: 0x2000,
                    endAddress: 0x2004, confidence: 1))
            }
            analysis.instructions = publicTailRows()
            var result = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
            result.insertImage(binary: BinaryImage(id: UUID(), name: "fixture", path: "/fixture/tail-handoff",
                kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
            result.addressOverrides[.primary(0x2000)] = AddressOverride(customName: "_display_only")
            return result
        }
        XCTAssertFalse(MacIRConfiguration.installedTestBaseline?.returnContract ?? false)
        XCTAssertTrue(snapshot(duplicate: false).pseudocodeRenderInput(selectedAddress: 0x1000,
            in: .primary).knownTailCallTargets.isEmpty)
        MacIRConfiguration.$returnContractOverride.withValue(false) {
            XCTAssertTrue(snapshot(duplicate: false).pseudocodeRenderInput(selectedAddress: 0x1000,
                in: .primary).knownTailCallTargets.isEmpty)
        }
        MacIRConfiguration.$returnContractOverride.withValue(true) {
            XCTAssertEqual(snapshot(duplicate: false).pseudocodeRenderInput(selectedAddress: 0x1000,
                in: .primary).knownTailCallTargets[0x2000], "_callee")
            XCTAssertNil(snapshot(duplicate: true).pseudocodeRenderInput(selectedAddress: 0x1000,
                in: .primary).knownTailCallTargets[0x2000])
        }
    }

    func testWorkspaceCensusTailHandoffRequiresFlagAndIndependentFrameAuthority() {
        for enabled in [false, true] {
            MacIRConfiguration.$returnContractOverride.withValue(enabled) {
                MacIRConfiguration.$ssaOverride.withValue(true) {
                    MacIRConfiguration.$explicitCFGOverride.withValue(true) {
                        for (targetStart, unbalanced) in [(UInt64(0x2000), false),
                                                         (UInt64(0x2004), false),
                                                         (UInt64(0x2000), true)] {
                            var analysis = ImageAnalysis()
                            analysis.functions = [
                                FunctionSummary(id: UUID(), name: "_identity_tail", startAddress: 0x1000,
                                    endAddress: unbalanced ? 0x1008 : 0x1004, confidence: 1),
                                FunctionSummary(id: UUID(), name: "_callee", startAddress: targetStart,
                                    endAddress: targetStart + 4, confidence: 1)
                            ]
                            analysis.instructions = publicTailRows(unbalanced: unbalanced)
                            var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
                            snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "fixture",
                                path: "/fixture/tail-identity", kind: "executable", architecture: "arm64",
                                slot: .primary), analysis: analysis)
                            let input = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
                            XCTAssertEqual(input.knownTailCallTargets[targetStart], enabled ? "_callee" : nil)
                            XCTAssertNil(input.signatureOverrides[0x1000])
                            let result = DecompilerC2DataflowCensusTests.buildFunction(
                                printer: PseudocodePrinter(), input: input)
                            let rejected = !enabled || unbalanced || targetStart != 0x2000
                            XCTAssertEqual(result.refusals.contains { $0.reason == .targetOutsideFunction }, rejected)
                            XCTAssertEqual(result.instructions.contains {
                                if case .call = $0.operation { return true }; return false
                            }, !rejected)
                            if !rejected {
                                XCTAssertEqual(result.returnValue, .unknown("unresolved_return_contract"))
                            }
                        }
                    }
                }
            }
        }
    }

    func testWorkspaceIndirectSourceKeepsFlagGateAndUniqueOriginalIdentity() {
        for enabled in [false, true] {
            MacIRConfiguration.$returnContractOverride.withValue(enabled) {
                for duplicate in [false, true] {
                    var analysis = ImageAnalysis()
                    analysis.functions = [
                        FunctionSummary(id: UUID(), name: "_public_tail", startAddress: 0x1000,
                            endAddress: 0x1008, confidence: 1),
                        FunctionSummary(id: UUID(), name: "_callee", startAddress: 0x2000,
                            endAddress: 0x2004, confidence: 1)
                    ]
                    if duplicate {
                        analysis.functions.append(FunctionSummary(id: UUID(), name: "_other",
                            startAddress: 0x2000, endAddress: 0x2004, confidence: 1))
                    }
                    analysis.instructions = publicTailRows() + [InstructionRow(address: 0x1004,
                        bytes: "20 00 1f d6", mnemonic: "br", operands: "x1",
                        hasBreakpoint: false, comment: nil)]
                    var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
                    snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "fixture",
                        path: "/fixture/indirect-identity", kind: "executable", architecture: "arm64",
                        slot: .primary), analysis: analysis)
                    snapshot.addressOverrides[.primary(0x2000)] = AddressOverride(customName: "_display_only")
                    let input = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
                    XCTAssertEqual(input.knownTailCallTargets.isEmpty, !enabled)
                    XCTAssertEqual(input.knownTailCallTargets[0x2000], enabled && !duplicate ? "_callee" : nil)
                }
            }
        }
    }

}
