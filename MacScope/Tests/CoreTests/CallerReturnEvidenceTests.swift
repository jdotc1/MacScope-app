import XCTest
@testable import MacScope

final class CallerReturnEvidenceTests: XCTestCase {
    private func rows(_ start: UInt64, _ operations: [(String, String)]) -> [InstructionRow] {
        operations.enumerated().map { index, op in
            InstructionRow(address: start + UInt64(index * 4), bytes: "", mnemonic: op.0,
                           operands: op.1, hasBreakpoint: false, comment: nil)
        }
    }

    private var leaf: [InstructionRow] {
        rows(0x1000, [("ldr", "x8, [x0]"), ("str", "x8, [x1]"), ("ret", "")])
    }

    private func snapshot(_ caller: [(String, String)] = []) -> WorkspaceSnapshot {
        var analysis = ImageAnalysis()
        analysis.functions = [FunctionSummary(id: UUID(), name: "copy_leaf", startAddress: 0x1000,
                                               endAddress: 0x100c, confidence: 1)]
        analysis.instructions = leaf
        if !caller.isEmpty {
            analysis.functions.append(FunctionSummary(id: UUID(), name: "caller", startAddress: 0x2000,
                endAddress: 0x2000 + UInt64(caller.count * 4), confidence: 1))
            analysis.instructions += rows(0x2000, caller)
        }
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "fixture", path: "/tmp/caller-return-fixture",
            kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
        return snapshot
    }

    private func render(_ snapshot: WorkspaceSnapshot) -> String {
        PseudocodeView.document(for: snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary),
                                options: .default).text
    }

    private func warm(_ snapshot: WorkspaceSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true), file: file, line: line)
    }

    // C2.1: direct BL + x0 read establishes only the non-void side.
    func testDirectCallResultReadResolvesPassThroughReturn() {
        let value = snapshot([("bl", "0x1000"), ("ldr", "x9, [x0]"), ("ret", "")])
        warm(value)
        let text = render(value)
        XCTAssertFalse(text.contains("unresolved_return_contract"), text)
        XCTAssertTrue(text.contains("return arg0;"), text)
        XCTAssertFalse(text.hasPrefix("void "), text)
        var changed = value
        changed.instructions[4].operands = "x9, [x1]"
        XCTAssertNil(changed.imageWideIndirectCalls(in: .primary, compute: false))
        XCTAssertTrue(render(changed).contains("return unresolved_return_contract;"))
        XCTAssertEqual(render(value), text, "a mutated copy must not invalidate the original memo")
    }

    // C2.2: writes and intervening calls sever the original result's lifetime.
    func testRedefinitionOrAnotherCallDoesNotWitnessOriginalResult() {
        for middle in [[("mov", "x0, #0")], [("mov", "w0, #0")], [("bl", "0x3000")], [("blr", "x8")]] {
            let value = snapshot([("bl", "0x1000")] + middle + [("ldr", "x9, [x0]"), ("ret", "")])
            warm(value)
            XCTAssertTrue(render(value).contains("return unresolved_return_contract;"))
        }
    }

    // C2.3: absence of witnesses, including tail calls, never establishes void.
    func testNoCallerOrTailBranchKeepsUnresolvedReturn() {
        for caller: [(String, String)] in [[], [("b", "0x1000")], [("bl", "0x1000"), ("ret", "")]] {
            let value = snapshot(caller)
            warm(value)
            XCTAssertTrue(render(value).contains("return unresolved_return_contract;"))
        }
    }

    // C2.4: local/cold/incomplete reports retain the existing fallback.
    func testColdLocalCancelledAndOverCapReportsKeepUnresolvedReturn() {
        let cold = snapshot([("bl", "0x1000"), ("ldr", "x9, [x0]"), ("ret", "")])
        XCTAssertTrue(render(cold).contains("return unresolved_return_contract;"))
        XCTAssertNil(cold.imageWideIndirectCalls(in: .primary, compute: false))
        let local = PseudocodePrinter().buildFunction(functionName: "copy_leaf", startAddress: 0x1000,
                                                     instructions: leaf)
        XCTAssertEqual(local.returnValue, .unknown("unresolved_return_contract"))
        var checkpoints = 0
        XCTAssertNil(cold.imageWideIndirectCalls(in: .primary, compute: true, checkpoint: {
            checkpoints += 1
            return checkpoints < 5
        }))
        XCTAssertTrue(render(cold).contains("return unresolved_return_contract;"))
        var capped = snapshot([("bl", "0x1000"), ("ldr", "x9, [x0]"), ("ret", "")])
        capped.functions += (0..<WorkspaceSnapshot.maximumImageWideIndirectCallFunctions).map { index in
            FunctionSummary(id: UUID(), name: "unused", startAddress: 0x10000 + UInt64(index * 4),
                            endAddress: 0x10004 + UInt64(index * 4), confidence: 1)
        }
        XCTAssertNil(capped.imageWideIndirectCalls(in: .primary, compute: true))
        XCTAssertTrue(render(capped).contains("return unresolved_return_contract;"))
    }

    // C2.5: explicit return authority wins even over a conflicting caller width.
    func testAuthoredReturnAuthorityIsUnaffected() {
        for type in ["void", "uint64_t *"] {
            var value = snapshot([("bl", "0x1000"), ("mov", "w9, w0"), ("ret", "")])
            var override = AddressOverride()
            override.signature = FunctionSignatureOverride(returnType: type, args: [
                ArgOverride(index: 0, name: "p", type: "uint64_t *"),
                ArgOverride(index: 1, name: "out", type: "uint64_t *")])
            value.addressOverrides[ImageAddress(slot: .primary, address: 0x1000)] = override
            let before = render(value)
            warm(value)
            XCTAssertEqual(render(value), before)
        }
    }

    // C2.6: only exclusively w0 observations narrow the returned width.
    func testW0OnlyWitnessReturns32Bits() {
        let value = snapshot([("bl", "0x1000"), ("mov", "w9, w0"),
                              ("mov", "x0, #0"), ("ret", "")])
        warm(value)
        let text = render(value)
        XCTAssertFalse(text.contains("unresolved_return_contract"), text)
        XCTAssertNotNil(text.range(of: #"\b(u?int32_t) copy_leaf\("#, options: .regularExpression), text)
        XCTAssertTrue(text.contains("return ") && text.contains("arg0"), text)

        let mixed = snapshot([("bl", "0x1000"), ("mov", "w9, w0"), ("ldr", "x10, [x0]"), ("ret", "")])
        warm(mixed)
        let mixedText = render(mixed)
        XCTAssertTrue(mixedText.contains("return arg0;"), mixedText)
        XCTAssertNil(mixedText.range(of: #"\b(u?int32_t) copy_leaf\("#, options: .regularExpression), mixedText)

        for suffix in [[("cmp", "x0, #0"), ("ret", "")],
                       [("opaque", "x8"), ("ldr", "x10, [x0]"), ("ret", "")]] {
            let wider = snapshot([("bl", "0x1000"), ("mov", "w9, w0")] + suffix)
            warm(wider)
            let widerText = render(wider)
            XCTAssertTrue(widerText.contains("return arg0;"), widerText)
            XCTAssertNil(widerText.range(of: #"\b(u?int32_t) copy_leaf\("#, options: .regularExpression), widerText)
        }

        var twoCallers = value
        twoCallers.functions.append(FunctionSummary(id: UUID(), name: "framed_caller", startAddress: 0x3000,
                                                     endAddress: 0x3014, confidence: 1))
        twoCallers.instructions += rows(0x3000, [("stp", "x29, x30, [sp, #-0x10]!"),
            ("bl", "0x1000"), ("ldr", "x9, [x0]"), ("ldp", "x29, x30, [sp], #0x10"), ("ret", "")])
        warm(twoCallers)
        let twoText = render(twoCallers)
        XCTAssertTrue(twoText.contains("return arg0;"), twoText)
        XCTAssertNil(twoText.range(of: #"\b(u?int32_t) copy_leaf\("#, options: .regularExpression), twoText)
    }
}


extension CallerReturnEvidenceTests {
    private func callerIR(_ operations: [(String, String)]) -> MacIRFunction {
        PseudocodePrinter().buildFunction(functionName: "caller", startAddress: 0x2000,
                                         instructions: rows(0x2000, operations))
    }

    private func width(_ caller: MacIRFunction) -> MacIRCallerReturnEvidence.Width? {
        MacIRCallerReturnEvidence.collect(functions: [
            MacIRFunction(name: "f", startAddress: 0x1000, instructions: []), caller
        ])[0x1000]
    }

    func testPhiJoinedResultWithWideLoadKeepsX0() throws {
        // ScalarCFGStatePlan does not admit BL. Model the review's joined SSA
        // explicitly rather than depending on the legacy linear lift's state.
        let linear = callerIR([("bl", "0x1000"), ("mov", "w9, w0"), ("ret", "")])
        var call = try XCTUnwrap(linear.instructions.first)
        guard case let .call(_, result?) = call.operation else {
            return XCTFail("fixture must have a call result")
        }
        call.source.address = 0x2004
        var read = linear.instructions[1]
        read.source.address = 0x2008
        let other = MacIRValue.register(name: "x0", version: 100)
        let joined = MacIRValue.register(name: "x0", version: 101)
        func instruction(_ address: UInt64, _ mnemonic: String, _ operands: String,
                         _ operation: MacIROperation) -> MacIRInstruction {
            MacIRInstruction(source: MacIRSourceSpan(address: address, byteText: "",
                mnemonic: mnemonic, operands: operands), operation: operation)
        }
        let caller = MacIRFunction(name: "caller", startAddress: 0x2000, instructions: [
            instruction(0x2000, "cbz", "x2, 0x2010", .conditionalBranch(condition: "==",
                left: .argument(bindingID: .gpr(2)), right: .immediate(0), target: .immediate(0x2010))),
            call, read,
            instruction(0x200c, "b", "0x2014", .intrinsic(destination: nil, name: "branch",
                arguments: [.immediate(0x2014)])),
            instruction(0x2010, "mov", "x0, x1", .assign(destination: other,
                source: .argument(bindingID: .gpr(1)))),
            instruction(0x2014, "ldr", "x10, [x0]", .load(destination: .register(name: "x10", version: 1),
                address: joined)),
            instruction(0x2018, "ret", "", .returnValue(nil))
        ], phis: [MacIRPhi(blockAddress: 0x2014, destination: joined, bitWidth: 64, incoming: [
            .init(predecessorAddress: 0x200c, value: result),
            .init(predecessorAddress: 0x2010, value: other)
        ])])
        XCTAssertFalse(caller.phis.isEmpty, "the fixture must exercise the joined value")
        XCTAssertEqual(width(caller), .x0)
        let callee = MacIRBuilder().buildFunction(name: "copy_leaf", startAddress: 0x1000,
            callerReturnWidth: width(caller), instructions: leaf)
        let text = PseudocodePrinter().print(function: callee).text
        XCTAssertTrue(text.contains("return arg0;"), text)
        XCTAssertNil(text.range(of: #"\b(u?int32_t) copy_leaf\("#, options: .regularExpression), text)

        var transitive = caller
        let joinedAgain = MacIRValue.register(name: "x12", version: 1)
        transitive.phis.insert(MacIRPhi(blockAddress: 0x2014, destination: joinedAgain, bitWidth: 64,
            incoming: [.init(predecessorAddress: 0x2010, value: joined)]), at: 0)
        transitive.instructions[5].operation = .load(destination: .register(name: "x10", version: 1),
                                                    address: joinedAgain)
        XCTAssertEqual(width(transitive), .x0, "phi traversal must reach a fixed point independent of order")

        var narrowJoin = caller
        narrowJoin.instructions[5].operation = .assign(destination: .register(name: "x10", version: 1),
            source: .unary(op: "(uint32_t)", value: joined))
        narrowJoin.instructions[5].source.mnemonic = "mov"
        narrowJoin.instructions[5].source.operands = "w10, w0"
        // The narrow-phi control must not also forward the live x0 at RET.
        narrowJoin.instructions[6] = instruction(0x2018, "mov", "x0, #0",
            .assign(destination: .register(name: "x0", version: 102), source: .immediate(0)))
        narrowJoin.instructions.append(instruction(0x201c, "ret", "", .returnValue(nil)))
        XCTAssertEqual(width(narrowJoin), .w0, "a resolved phi with only narrow uses is safe")

        var noWitness = caller
        noWitness.instructions[2].operation = .intrinsic(destination: nil, name: "nop", arguments: [])
        noWitness.instructions[2].source.mnemonic = "nop"
        noWitness.instructions[2].source.operands = ""
        XCTAssertNil(width(noWitness), "a wide phi use must not create a direct-read witness")
    }

    func testCopiedResultWithWideUseKeepsX0() {
        let caller = callerIR([("bl", "0x1000"), ("mov", "w10, w0"),
                               ("mov", "x9, x0"), ("mov", "x0, #0"),
                               ("ldr", "x11, [x9]"), ("ret", "")])
        XCTAssertEqual(width(caller), .x0)
    }

    func testNarrowCopyWithLaterWideUseKeepsX0() {
        let caller = callerIR([("bl", "0x1000"), ("mov", "w9, w0"),
                               ("mov", "x0, #0"), ("ldr", "x10, [x9]"), ("ret", "")])
        XCTAssertEqual(width(caller), .x0, "every use of a copy must be classified as 32-bit")
        let narrowCopies = callerIR([("bl", "0x1000"), ("mov", "w9, w0"),
                                      ("mov", "x0, #0"), ("mov", "w10, w9"), ("ret", "")])
        XCTAssertEqual(width(narrowCopies), .w0, "an actual w-register copy read stays narrow")
    }

    func testUnclassifiedCopiedUseAfterCarrierOverwriteKeepsX0() {
        let caller = callerIR([("bl", "0x1000"), ("mov", "w9, w0"),
                               ("mov", "x0, #0"), ("opaque", "x8, x9"), ("ret", "")])
        XCTAssertEqual(width(caller), .x0)
    }

    func testPureW0ReadStillNarrowsAfterUseAudit() {
        XCTAssertEqual(width(callerIR([("bl", "0x1000"), ("mov", "w9, w0"),
                                      ("mov", "x0, #0"), ("ret", "")])), .w0)
    }

    func testLiveResultAtReturnKeepsX0() {
        let caller = callerIR([("bl", "0x1000"), ("cmp", "w0, #0"), ("ret", "")])
        XCTAssertEqual(width(caller), .x0, "RET can forward all 64 bits to the caller's caller")
    }

    func testLiveResultAtLaterAnalyzedCallKeepsX0() {
        let caller = callerIR([("bl", "0x1000"), ("cmp", "w0, #0"),
                               ("bl", "0x3000"), ("ret", "")])
        guard case let .call(_, result?) = caller.instructions[0].operation,
              case let .call(frame, _) = caller.instructions[2].operation else {
            return XCTFail("fixture must retain both direct calls")
        }
        XCTAssertTrue(frame.bindingValues.contains(result), "g receives the live x0 result")
        let g = MacIRBuilder().buildFunction(name: "g", startAddress: 0x3000,
            instructions: rows(0x3000, [("ldr", "x9, [x0]"), ("ret", "")]))
        XCTAssertTrue(g.parameters.contains { $0.bindingID == .gpr(0) })
        let evidence = MacIRCallerReturnEvidence.collect(functions: [
            MacIRFunction(name: "f", startAddress: 0x1000, instructions: []), caller, g
        ])
        XCTAssertEqual(evidence[0x1000], .x0)
    }

    func testOverwriteBeforeReturnStillNarrowsW0Comparison() {
        let caller = callerIR([("bl", "0x1000"), ("cmp", "w0, #0"),
                               ("mov", "x0, #0"), ("ret", "")])
        XCTAssertEqual(width(caller), .w0)
    }

    func testReturnedCopyAfterCarrierOverwriteKeepsX0() {
        var caller = callerIR([("bl", "0x1000"), ("mov", "w9, w0"),
                               ("mov", "x0, #0"), ("ret", "")])
        guard case let .assign(copy, _) = caller.instructions[1].operation else {
            return XCTFail("fixture must retain the narrow copy")
        }
        // Model an explicit return operand after the witness walk has stopped
        // at the carrier overwrite. Even a narrow copy cannot evade the audit.
        caller.instructions[3].operation = .returnValue(copy)
        XCTAssertEqual(width(caller), .x0)
    }
}

extension CallerReturnEvidenceTests {
    private func diagnosedCallSite(_ caller: MacIRFunction) -> CallSiteContract? {
        MacIRCallerReturnEvidence.collectCallSites(functions: [
            MacIRFunction(name: "callee", startAddress: 0x1000, instructions: []), caller
        ], callerWidths: [0x1000: .x0])[caller.startAddress]?.first
    }

    func testRawReadDiagnosticsRecordImmediateAndLaterReadingPCs() throws {
        let caller = callerIR([("bl", "0x1000"), ("mov", "x9, x0"), ("nop", ""),
                               ("ldr", "x10, [x0]"), ("mov", "x0, #0"), ("ret", "")])
        let site = try XCTUnwrap(diagnosedCallSite(caller))
        XCTAssertEqual(site.consumption, .read(width: 64, type: nil))
        XCTAssertEqual(site.rawReads, [
            .init(readingPC: 0x2004, path: [0x2000, 0x2004]),
            .init(readingPC: 0x200c, path: [0x2000, 0x2004, 0x2008, 0x200c])
        ])
    }

    func testRawReadDiagnosticsRecordDeterministicBranchPath() throws {
        let caller = callerIR([("bl", "0x1000"), ("cbz", "x2, 0x2010"), ("nop", ""),
                               ("b", "0x2014"), ("nop", ""), ("ldr", "x9, [x0]"),
                               ("mov", "x0, #0"), ("ret", "")])
        let site = try XCTUnwrap(diagnosedCallSite(caller))
        XCTAssertEqual(site.consumption, .read(width: 64, type: nil))
        XCTAssertEqual(site.rawReads, [.init(readingPC: 0x2014, path: [0x2000, 0x2004, 0x2010, 0x2014])])
        var reordered = caller
        reordered.instructions.reverse()
        XCTAssertEqual(diagnosedCallSite(reordered)?.rawReads, site.rawReads)
    }

    func testRawReadDiagnosticsAreEmptyWhenContinuationIsOpaque() throws {
        let caller = callerIR([("bl", "0x1000"), ("mov", "x9, x0"), ("opaque", "x8"), ("ret", "")])
        let site = try XCTUnwrap(diagnosedCallSite(caller))
        XCTAssertEqual(site.consumption, .unknown)
        XCTAssertTrue(site.rawReads.isEmpty)
    }

    func testRawReadDiagnosticsAreEmptyWhenAnotherDefinitionReachesRead() throws {
        let caller = callerIR([("bl", "0x1000"), ("cbz", "x2, 0x2010"), ("mov", "x0, #0"),
                               ("b", "0x2014"), ("nop", ""), ("ldr", "x9, [x0]"),
                               ("mov", "x0, #0"), ("ret", "")])
        let site = try XCTUnwrap(diagnosedCallSite(caller))
        XCTAssertEqual(site.consumption, .unknown)
        XCTAssertTrue(site.rawReads.isEmpty)
    }
}

final class SlotTargetReachabilityTests: XCTestCase {
    func testSCCReachMatchesPerQueryWalkForPhiCycleAndDiamond() {
        let a = MacIRValue.register(name: "x8", version: 1)
        let b = MacIRValue.register(name: "x9", version: 1)
        let left = MacIRValue.register(name: "x10", version: 1)
        let right = MacIRValue.register(name: "x11", version: 1)
        let diamond = MacIRValue.register(name: "x12", version: 1)
        let empty = MacIRValue.register(name: "x13", version: 1)
        let t1 = MacIRValue.immediate(0x1000), t2 = MacIRValue.immediate(0x2000)
        let t3 = MacIRValue.immediate(0x3000)
        func phi(_ destination: MacIRValue, _ values: [MacIRValue]) -> MacIRPhi {
            MacIRPhi(blockAddress: 0x8000, destination: destination, bitWidth: 64,
                incoming: values.map { .init(predecessorAddress: 0x8000, value: $0) })
        }
        let function = MacIRFunction(name: "reach", startAddress: 0x8000, instructions: [
            MacIRInstruction(source: MacIRSourceSpan(address: 0x8000, byteText: "",
                mnemonic: "ret", operands: ""), operation: .returnValue(nil))
        ], phis: [phi(a, [b, t1]), phi(b, [a, t2]), phi(left, [a]),
                  phi(right, [a, t3]), phi(diamond, [left, right]), phi(empty, [empty])])
        let starts: Set<UInt64> = [0x1000, 0x2000, 0x3000]
        let terminal = MacIRValue.binaryExpression(op: "+", left: t1, right: t2)
        let queries = [a, b, left, right, diamond, empty, terminal, diamond, a]
        let expected: [Set<UInt64>] = [[0x1000, 0x2000], [0x1000, 0x2000], [0x1000, 0x2000],
            [0x1000, 0x2000, 0x3000], [0x1000, 0x2000, 0x3000], [], [0x3000],
            [0x1000, 0x2000, 0x3000], [0x1000, 0x2000]]

        // Independent, test-only per-query walk. This fixture has no instruction
        // definitions: constants are literals/arithmetic, and forwarding is phi
        // incoming or expression components, as in the pre-memo traversal.
        func constant(_ value: MacIRValue) -> Int64? {
            switch value {
            case let .immediate(number): return number
            case let .binaryExpression(op, lhs, rhs):
                guard let lhs = constant(lhs), let rhs = constant(rhs), op == "+" else { return nil }
                let sum = lhs.addingReportingOverflow(rhs)
                return sum.overflow ? nil : sum.partialValue
            default: return nil
            }
        }
        func reference(_ root: MacIRValue) -> Set<UInt64> {
            var pending = [root], visited: Set<MacIRValue> = [], found: Set<UInt64> = []
            while let value = pending.popLast() {
                guard visited.insert(value).inserted else { continue }
                if let number = constant(value), number >= 0, starts.contains(UInt64(number)) {
                    found.insert(UInt64(number))
                    continue
                }
                switch value {
                case let .binaryExpression(_, lhs, rhs): pending += [lhs, rhs]
                case let .unary(_, inner), let .bitTest(inner, _): pending.append(inner)
                case let .abiComposite(_, fragments): pending += fragments
                default: break
                }
                for phi in function.phis where phi.destination == value { pending += phi.incoming.map(\.value) }
            }
            return found
        }
        XCTAssertEqual(queries.map(reference), expected)
        for ordered in [queries, Array(queries.reversed())] {
            let actual = MacIRSlotReturnAuthority.targetSetsForTesting(function: function, starts: starts,
                queries: ordered.map { ($0, 0) })
            XCTAssertEqual(actual, ordered.map(reference))
        }
    }
}

final class DominanceIntervalTests: XCTestCase {
    private func fixture(_ successors: [[Int]]) -> CFG {
        let blocks = successors.indices.map { index in
            BasicBlock(index: index, startIndex: index * 2, endIndex: index * 2 + 2,
                       successors: successors[index],
                       predecessors: successors.indices.filter { successors[$0].contains(index) },
                       isLoopHeader: false)
        }
        return CFG(blocks: blocks, entryIndex: 0,
                   domTree: CFGBuilder.computeDominators(blocks: blocks, entryIndex: 0),
                   postDomTree: [:], loopHeaders: [], backEdges: [], irreducibleBlocks: [],
                   blockByStartIndex: Dictionary(uniqueKeysWithValues: blocks.map { ($0.startIndex, $0.index) }),
                   hasUnresolvedTargets: false)
    }

    private func compareWithReference(_ cfg: CFG, file: StaticString = #filePath, line: UInt = #line) {
        let intervals = MacIRSlotReturnAuthority.DominanceIntervals(domTree: cfg.domTree)
        let blocks = Dictionary(uniqueKeysWithValues: cfg.blocks.flatMap { block in
            block.instructionRange.map { ($0, block.index) }
        })
        // The original caller-return predicate, including its guard order and
        // cycle bound. CFGBuilder.dominates has different absent/equality rules.
        func reference(_ definition: Int, _ use: Int) -> Bool {
            guard !cfg.hasUnresolvedTargets, let source = blocks[definition], let destination = blocks[use],
                  cfg.domTree[destination] != nil else { return false }
            if source == destination { return definition < use }
            var block = destination
            var seen: Set<Int> = []
            while seen.insert(block).inserted, let parent = cfg.domTree[block], parent != block {
                if parent == source { return true }
                block = parent
            }
            return false
        }
        // Two instructions per block cover same-block earlier, equal and later
        // positions; -1 also exercises missing instruction-to-block mappings.
        let indices = [-1] + blocks.keys.sorted()
        for definition in indices {
            for use in indices {
                XCTAssertEqual(intervals.dominates(definition, use, cfg: cfg, blocks: blocks),
                               reference(definition, use), "definition=\(definition), use=\(use)",
                               file: file, line: line)
            }
        }
    }

    func testDiamond() {
        compareWithReference(fixture([[1, 2], [3], [3], []]))
    }

    func testLoop() {
        compareWithReference(fixture([[1], [2, 3], [1], []]))
    }

    func testNestedLoop() {
        compareWithReference(fixture([[1], [2, 5], [3, 4], [2], [1], []]))
    }

    func testUnreachableBlockAndUnresolvedTargets() {
        var cfg = fixture([[1, 2], [3], [3], [], [5], []])
        XCTAssertNil(cfg.domTree[4])
        XCTAssertNil(cfg.domTree[5])
        compareWithReference(cfg)
        cfg.hasUnresolvedTargets = true
        compareWithReference(cfg)
    }

    func testMissingParentsCyclesAndSeparateRootsRetainWalkSemantics() {
        var cfg = fixture([[], [], [], [], [], []])
        for parents in [[0: 0, 1: 0, 2: 2, 3: 2],
                        [0: 0, 1: 2, 2: 1, 3: 2],
                        [0: 0, 1: 4, 2: 1], [:]] {
            cfg.domTree = parents
            compareWithReference(cfg)
        }
    }
}
