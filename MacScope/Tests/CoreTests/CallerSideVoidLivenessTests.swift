import Foundation
import XCTest
@testable import MacScope

final class CallerSideVoidLivenessTests: XCTestCase {
    private typealias Literal = (String, String, String)
    private let ret: Literal = ("c0 03 5f d6", "ret", "")
    private let killX: Literal = ("00 00 80 d2", "mov", "x0, #0")
    private let killW: Literal = ("00 00 80 52", "mov", "w0, #0")

    private func rows(_ start: UInt64, _ source: [Literal]) -> [InstructionRow] {
        source.enumerated().map { index, row in
            InstructionRow(address: start + UInt64(index * 4), bytes: row.0,
                mnemonic: row.1, operands: row.2, hasBreakpoint: false, comment: nil)
        }
    }

    private func fixture(_ continuation: [Literal], ssa: Bool, typedConsumer: Bool = false,
                         preservedBranchInput: Bool = false)
        -> (functions: [MacIRFunction], calls: [MacIRSourceSpan]) {
        let prefix: [Literal] = preservedBranchInput
            ? [("f4 03 00 aa", "mov", "x20, x0"), ("ff f7 ff 97", "bl", "0x1000")]
            : [("00 f8 ff 97", "bl", "0x1000")]
        let callerRows = rows(0x3000, prefix + continuation)
        let consumer = FunctionSignatureOverride(returnType: "void", args: [
            ArgOverride(index: 0, name: "value", type: "uint64_t")
        ])
        let own: [UInt64: FunctionSignatureOverride] = [
            0x3000: FunctionSignatureOverride(returnType: "uint64_t", args: preservedBranchInput
                ? [ArgOverride(index: 0, name: "branchInput", type: "uint64_t")] : []),
            0x2000: consumer
        ]
        let authored = typedConsumer ? ["0x2000": consumer] : [:]
        let bodies: [(UInt64, String, [InstructionRow])] = [
            (0x1000, "callback", rows(0x1000, [("e0 00 80 d2", "mov", "x0, #7"), ret])),
            (0x2000, "consume", rows(0x2000, [ret])),
            (0x3000, "caller", callerRows)
        ]
        let functions = bodies.map { start, name, body in
            PseudocodePrinter().buildFunction(functionName: name, startAddress: start,
                signatureOverrides: own, authoredCallSignaturesByTarget: authored,
                explicitCFGEnabled: ssa, ssaEnabled: ssa, instructions: body)
        }
        let calls = callerRows.filter { ["bl", "b"].contains($0.mnemonic) }.map {
            MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
                mnemonic: $0.mnemonic, operands: $0.operands)
        }
        return (functions, calls)
    }

    private func loopWithUnknownClobberPhi() -> (functions: [MacIRFunction], calls: [MacIRSourceSpan]) {
        let callback = PseudocodePrinter().buildFunction(functionName: "callback", startAddress: 0x1000,
            explicitCFGEnabled: true, ssaEnabled: true,
            instructions: rows(0x1000, [("e0 00 80 d2", "mov", "x0, #7"), ret]))
        let body = rows(0x3000, [("54 00 80 52", "mov", "w20, #2"),
            ("ff f7 ff 97", "bl", "0x1000"), killX,
            ("94 06 00 51", "sub", "w20, w20, #1"),
            ("b4 ff ff 35", "cbnz", "w20, 0x3004"), ret])
        let caller = PseudocodePrinter().buildFunction(functionName: "caller", startAddress: 0x3000,
            signatureOverrides: [0x3000: .init(returnType: "void", args: [])],
            explicitCFGEnabled: true, ssaEnabled: true, instructions: body)
        let calls = body.filter { $0.mnemonic == "bl" }.map {
            MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
                mnemonic: $0.mnemonic, operands: $0.operands)
        }
        return ([callback, caller], calls)
    }

    private func admitted(_ fixture: (functions: [MacIRFunction], calls: [MacIRSourceSpan])) -> Set<UInt64> {
        MacIRCallerReturnEvidence.discardedDirectCallTargets(functions: fixture.functions,
            directCalls: fixture.calls, callerWidths: [:])
    }

    func testBothPhysicalWidthsMustBeOverwrittenBeforeAnyUse() throws {
        for ssa in [false, true] {
            for kill in [killX, killW] {
                let input = fixture([kill, ret], ssa: ssa)
                XCTAssertEqual(try XCTUnwrap(input.functions.first { $0.startAddress == 0x3000 }).ssaEnabled, ssa)
                XCTAssertTrue(admitted(input).contains(0x1000))
            }
        }
    }

    func testTypedAndUntypedNextCallArgumentsVetoBeforeLaterKill() throws {
        for ssa in [false, true] {
            let typed = fixture([("ff fb ff 97", "bl", "0x2000"), killX, ret],
                                ssa: ssa, typedConsumer: true)
            let caller = try XCTUnwrap(typed.functions.first { $0.startAddress == 0x3000 })
            let next = try XCTUnwrap(caller.instructions.first { $0.source.address == 0x3004 })
            guard case let .call(frame, _) = next.operation else { return XCTFail("Expected typed consumer") }
            XCTAssertNotNil(frame.knownSignature)
            let callback = try XCTUnwrap(caller.instructions.first { $0.source.address == 0x3000 })
            guard case let .call(_, callbackResult?) = callback.operation else {
                return XCTFail("Expected the callback result")
            }
            let arguments = frame.arguments.canonicalPhysicalEntriesForAudit
            XCTAssertEqual(arguments.count, 1)
            let argument = try XCTUnwrap(arguments.first)
            XCTAssertEqual(argument.location, .gpr(index: 0, carrierWidth: 64))
            XCTAssertEqual(argument.value, callbackResult)
            XCTAssertFalse(admitted(typed).contains(0x1000))

            var untyped = fixture([("20 01 3f d6", "blr", "x9"), killX, ret], ssa: ssa)
            XCTAssertFalse(admitted(untyped).contains(0x1000))
            let index = try XCTUnwrap(untyped.functions[2].instructions.firstIndex { $0.source.address == 0x3004 })
            guard case let .call(old, result) = untyped.functions[2].instructions[index].operation else {
                return XCTFail("Expected indirect consumer")
            }
            let empty = try XCTUnwrap(MacIRCallArguments([]))
            let hidden = try XCTUnwrap(MacIRCallFrame(target: old.target, knownSignature: nil,
                controlInputs: old.controlInputs, arguments: empty, unknownArgumentCount: 0))
            untyped.functions[2].instructions[index].operation = .call(frame: hidden, result: result)
            XCTAssertFalse(admitted(untyped).contains(0x1000),
                "An empty untyped frame cannot prove that the ABI input is unread")
        }
    }

    func testStoresComparesReturnsAndReadModifyWritesVeto() {
        let uses: [Literal] = [
            ("60 02 00 f9", "str", "x0, [x19]"),
            ("60 02 00 b9", "str", "w0, [x19]"),
            ("01 00 00 f9", "str", "x1, [x0]"),
            ("01 84 40 f8", "ldr", "x1, [x0], #8"),
            ("1f 00 00 f1", "cmp", "x0, #0"),
            ("1f 00 00 71", "cmp", "w0, #0"),
            ("00 04 00 91", "add", "x0, x0, #1")
        ]
        for ssa in [false, true] {
            for use in uses {
                XCTAssertFalse(admitted(fixture([use, killX, ret], ssa: ssa)).contains(0x1000), use.2)
            }
            XCTAssertFalse(admitted(fixture([ret], ssa: ssa)).contains(0x1000))
        }
    }

    func testOneLiveBranchVetoesAndTwoKilledBranchesPermit() throws {
        for ssa in [false, true] {
            // Preserve a nonconstant incoming value, independent of the callback result.
            let branch: Literal = ("74 00 00 b4", "cbz", "x20, 0x3014")
            let jump: Literal = ("02 00 00 14", "b", "0x3018")
            let live = fixture([branch, killX, jump, ("60 02 00 f9", "str", "x0, [x19]"), ret],
                               ssa: ssa, preservedBranchInput: true)
            let dead = fixture([branch, killX, jump, killW, ret], ssa: ssa, preservedBranchInput: true)
            for input in [live, dead] {
                let caller = try XCTUnwrap(input.functions.first { $0.startAddress == 0x3000 })
                XCTAssertEqual(caller.ssaEnabled, ssa)
                let copy = try XCTUnwrap(caller.instructions.first { $0.source.address == 0x3000 })
                guard case let .assign(saved, incoming) = copy.operation else {
                    return XCTFail("Expected preserved incoming branch value")
                }
                XCTAssertEqual(incoming, .argument(bindingID: .gpr(0)))
                let callback = try XCTUnwrap(caller.instructions.first { $0.source.address == 0x3004 })
                guard case let .call(_, callbackResult?) = callback.operation else {
                    return XCTFail("Expected the callback result")
                }
                let conditional = try XCTUnwrap(caller.instructions.first { $0.source.address == 0x3008 })
                guard case let .conditionalBranch(condition, left, right, target) = conditional.operation else {
                    return XCTFail("Expected both structural branch paths")
                }
                XCTAssertEqual(condition, "==")
                XCTAssertEqual(left, saved)
                XCTAssertNotEqual(left, callbackResult)
                XCTAssertEqual(right, .immediate(0))
                XCTAssertEqual(target, .immediate(0x3014))
            }
            XCTAssertFalse(admitted(live).contains(0x1000))
            XCTAssertTrue(admitted(dead).contains(0x1000))

            let unavailable = fixture([("62 00 00 34", "cbz", "w2, 0x3010"), killX,
                                       ("02 00 00 14", "b", "0x3014"), killW, ret], ssa: ssa)
            let caller = try XCTUnwrap(unavailable.functions.first { $0.startAddress == 0x3000 })
            let conditional = try XCTUnwrap(caller.instructions.first { $0.source.address == 0x3004 })
            guard case let .conditionalBranch(_, left, _, _) = conditional.operation else {
                return XCTFail("Expected the call-clobbered branch input")
            }
            XCTAssertEqual(left, .unknown("unavailable_w2"))
            XCTAssertFalse(admitted(unavailable).contains(0x1000))
        }
    }

    func testLiveCyclesOpenBranchesAndOpaqueEffectsRefuse() {
        let boundaries: [Literal] = [("00 00 00 14", "b", "0x3004"),
            ("ff 03 00 14", "b", "0x4000"), ("20 01 1f d6", "br", "x9"),
            ("00 00 20 d4", "brk", "#0")]
        for ssa in [false, true] {
            for boundary in boundaries {
                XCTAssertFalse(admitted(fixture([boundary, killX, ret], ssa: ssa)).contains(0x1000))
            }
        }
    }

    func testEveryCallerMustHaveADiscardProof() {
        for ssa in [false, true] {
            var input = fixture([killX, ret], ssa: ssa)
            XCTAssertTrue(admitted(input).contains(0x1000))
            let liveRows = rows(0x4000, [("00 f4 ff 97", "bl", "0x1000"),
                ("60 02 00 f9", "str", "x0, [x19]"), killX, ret])
            let live = PseudocodePrinter().buildFunction(functionName: "second_caller", startAddress: 0x4000,
                explicitCFGEnabled: ssa, ssaEnabled: ssa, instructions: liveRows)
            input.functions.append(live)
            input.calls.append(MacIRSourceSpan(address: 0x4000, byteText: "00 f4 ff 97",
                mnemonic: "bl", operands: "0x1000"))
            XCTAssertFalse(admitted(input).contains(0x1000))
        }
    }

    func testMissingInventoryMissingLiftAndUnknownCallCannotDisappear() throws {
        for ssa in [false, true] {
            let valid = fixture([killX, ret], ssa: ssa)
            XCTAssertTrue(admitted(valid).contains(0x1000))
            XCTAssertTrue(admitted((valid.functions, [])).isEmpty)
            var missing = valid
            missing.functions[2].instructions.removeAll { $0.source.address == 0x3000 }
            XCTAssertFalse(admitted(missing).contains(0x1000))
            var unknown = valid
            let index = try XCTUnwrap(unknown.functions[2].instructions.firstIndex { $0.source.address == 0x3000 })
            unknown.functions[2].instructions[index].operation = .unknown(destination: nil, mnemonic: "bl", operands: "unmodeled direct call")
            XCTAssertFalse(admitted(unknown).contains(0x1000))
            var noCaller = valid
            noCaller.functions.removeLast()
            XCTAssertFalse(admitted(noCaller).contains(0x1000))
        }
    }

    func testDuplicateCallerSourceAndRawSiteRefuse() throws {
        for ssa in [false, true] {
            let valid = fixture([killX, ret], ssa: ssa)
            var caller = valid
            caller.functions.append(valid.functions[2])
            XCTAssertTrue(admitted(caller).isEmpty)
            var source = valid
            source.functions[2].instructions.append(try XCTUnwrap(source.functions[2].instructions.first))
            XCTAssertFalse(admitted(source).contains(0x1000))
            var raw = valid
            raw.calls.append(try XCTUnwrap(raw.calls.first))
            XCTAssertTrue(admitted(raw).isEmpty)
        }
    }

    func testUnknownIdentityRefusesButResolvedUnrelatedTargetDoesNotAlias() {
        for ssa in [false, true] {
            let valid = fixture([killX, ret], ssa: ssa)
            var unknown = valid
            unknown.calls.append(MacIRSourceSpan(address: 0x9000, byteText: "00 04 00 94",
                mnemonic: "bl", operands: "ambiguous_symbol"))
            XCTAssertTrue(admitted(unknown).isEmpty)
            var unrelated = valid
            unrelated.calls.append(MacIRSourceSpan(address: 0x9000, byteText: "00 04 00 94",
                mnemonic: "bl", operands: "0xa000"))
            XCTAssertTrue(admitted(unrelated).contains(0x1000))
        }
    }

    func testDirectTailVetoesAnOtherwiseDiscardedBLToTheSameTarget() throws {
        for ssa in [false, true] {
            let valid = fixture([killX, ret], ssa: ssa)
            XCTAssertTrue(admitted(valid).contains(0x1000))
            var tail = valid
            let body = PseudocodePrinter().buildFunction(functionName: "tail_caller", startAddress: 0x4000,
                explicitCFGEnabled: ssa, ssaEnabled: ssa,
                instructions: rows(0x4000, [("00 f4 ff 17", "b", "0x1000")]))
            let retained = try XCTUnwrap(body.instructions.first { $0.source.address == 0x4000 })
            XCTAssertEqual(retained.source.mnemonic, "b")
            tail.functions.append(body)
            tail.calls.append(MacIRSourceSpan(address: 0x4000, byteText: "00 f4 ff 17",
                mnemonic: "b", operands: "0x1000"))
            XCTAssertFalse(admitted(tail).contains(0x1000))
            var overlapping = tail
            let candidateEntry = try XCTUnwrap(overlapping.functions[0].instructions.first)
            overlapping.functions[0].instructions.removeAll()
            overlapping.functions[overlapping.functions.count - 1].instructions.append(candidateEntry)
            XCTAssertFalse(admitted(overlapping).contains(0x1000))
            var unowned = tail
            unowned.functions.removeLast()
            XCTAssertFalse(admitted(unowned).contains(0x1000))
            var missing = tail
            missing.calls.removeLast()
            XCTAssertTrue(admitted(missing).isEmpty)
            var unknown = valid
            unknown.calls.append(MacIRSourceSpan(address: 0x4000, byteText: "00 f4 ff 17",
                mnemonic: "b", operands: "ambiguous_tail"))
            XCTAssertTrue(admitted(unknown).isEmpty)
        }
    }

    func testUniquelyOwnedLocalEntryBackedgeIsNotATailInvocation() {
        for ssa in [false, true] {
            var input = fixture([killX, ret], ssa: ssa)
            input.functions[0] = PseudocodePrinter().buildFunction(functionName: "callback", startAddress: 0x1000,
                explicitCFGEnabled: ssa, ssaEnabled: ssa,
                instructions: rows(0x1000, [("61 00 00 34", "cbz", "w1, 0x100c"),
                    ("22 00 80 d2", "mov", "x2, #1"), ("fe ff ff 17", "b", "0x1000"), ret]))
            input.calls.append(MacIRSourceSpan(address: 0x1008, byteText: "fe ff ff 17",
                mnemonic: "b", operands: "0x1000"))
            XCTAssertTrue(admitted(input).contains(0x1000))
        }
    }

    func testUnrelatedUnknownPhiDoesNotVetoCallerOnlyDeadness() throws {
        let input = loopWithUnknownClobberPhi()
        let caller = try XCTUnwrap(input.functions.first { $0.startAddress == 0x3000 })
        XCTAssertTrue(caller.ssaEnabled)
        let phi = try XCTUnwrap(caller.phis.first { $0.cell == 2 })
        XCTAssertTrue(phi.incoming.contains { if case .unknown = $0.value { return true }; return false })
        let strict = MacIRCallerReturnEvidence.collectCallSites(functions: input.functions, callerWidths: [:])
        let site = try XCTUnwrap(strict[0x3000]?.first { $0.address == 0x3004 })
        XCTAssertEqual(site.consumption, .unknown)
        XCTAssertTrue(admitted(input).contains(0x1000))
    }

    func testExactResultPhiEscapeStillVetoesCallerOnlyDeadness() throws {
        var input = loopWithUnknownClobberPhi()
        XCTAssertTrue(admitted(input).contains(0x1000))
        let callerIndex = try XCTUnwrap(input.functions.firstIndex { $0.startAddress == 0x3000 })
        let call = try XCTUnwrap(input.functions[callerIndex].instructions.first { $0.source.address == 0x3004 })
        guard case let .call(_, result?) = call.operation else { return XCTFail("Expected a planned call result") }
        let phiIndex = try XCTUnwrap(input.functions[callerIndex].phis.firstIndex { $0.cell == 2 })
        let incomingIndex = try XCTUnwrap(input.functions[callerIndex].phis[phiIndex].incoming.indices.first)
        input.functions[callerIndex].phis[phiIndex].incoming[incomingIndex].value =
            .unary(op: "(uint64_t)", value: result)
        XCTAssertFalse(admitted(input).contains(0x1000))
    }

    func testModeledUnknownSourceBeforeKillRefusesCallerOnlyDeadness() throws {
        for ssa in [false, true] {
            var input = fixture([killX, ret], ssa: ssa)
            XCTAssertTrue(admitted(input).contains(0x1000))
            let index = try XCTUnwrap(input.functions[2].instructions.firstIndex { $0.source.address == 0x3004 })
            guard case let .assign(destination, _) = input.functions[2].instructions[index].operation else {
                return XCTFail("Expected the literal result overwrite")
            }
            input.functions[2].instructions[index].operation = .assign(destination: destination,
                source: .unknown("opaque_overwrite_input"))
            XCTAssertFalse(admitted(input).contains(0x1000))
        }
    }
}
