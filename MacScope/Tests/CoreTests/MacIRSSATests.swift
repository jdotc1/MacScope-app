import Foundation
import XCTest
@testable import MacScope

final class MacIRSSATests: XCTestCase {
    func testPhiUnsignedProofReusesReconvergentDAG() throws {
        var function = lift(diamond)
        let values = (0..<18).map { MacIRValue.temporary(500 + $0) }
        function.phis = values.enumerated().map { index, value in
            let dependency: MacIRValue = index == 0
                ? .unary(op: "(uint64_t)", value: .immediate(1)) : values[index - 1]
            return MacIRPhi(blockAddress: 0x1010, destination: value, bitWidth: 64,
                incoming: [.init(predecessorAddress: 0x1008, value: dependency),
                           .init(predecessorAddress: 0x100c, value: dependency)])
        }
        function.returnValue = values.last
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        let document = PseudocodePrinter(options: options).print(function: function)
        for value in values {
            let declaration = try XCTUnwrap(document.lines.first {
                $0.kind == .declaration && $0.syntheticPhiEdge?.destination == value
            })
            XCTAssertTrue(declaration.text.trimmingCharacters(in: .whitespaces).hasPrefix("uint64_t "), declaration.text)
        }
    }

    func testPhiUnsignedProofPreservesOptimisticCycle() throws {
        var function = lift(diamond)
        let a = MacIRValue.temporary(600), b = MacIRValue.temporary(601)
        function.phis = [
            .init(blockAddress: 0x1010, destination: a, bitWidth: 64,
                incoming: [.init(predecessorAddress: 0x1008, value: b),
                           .init(predecessorAddress: 0x100c, value: .unary(op: "(uint64_t)", value: .immediate(1)))]),
            .init(blockAddress: 0x1010, destination: b, bitWidth: 64,
                incoming: [.init(predecessorAddress: 0x1008, value: a),
                           .init(predecessorAddress: 0x100c, value: a)])]
        function.returnValue = a
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        let document = PseudocodePrinter(options: options).print(function: function)
        for value in [a, b] {
            let declaration = try XCTUnwrap(document.lines.first {
                $0.kind == .declaration && $0.syntheticPhiEdge?.destination == value
            })
            XCTAssertTrue(declaration.text.trimmingCharacters(in: .whitespaces).hasPrefix("uint64_t "), declaration.text)
        }
    }

    func testPhiUnsignedProofPropagatesCycleVeto() throws {
        for veto in [MacIRValue.unknown("signed_or_unavailable"), .unary(op: "(int64_t)", value: .immediate(-1))] {
            var function = lift(diamond)
            let a = MacIRValue.temporary(700), b = MacIRValue.temporary(701)
            function.phis = [
                .init(blockAddress: 0x1010, destination: a, bitWidth: 64,
                    incoming: [.init(predecessorAddress: 0x1008, value: b),
                               .init(predecessorAddress: 0x100c, value: veto)]),
                .init(blockAddress: 0x1010, destination: b, bitWidth: 64,
                    incoming: [.init(predecessorAddress: 0x1008, value: a),
                               .init(predecessorAddress: 0x100c, value: a)])]
            function.returnValue = a
            var options = DecompilerOptions.default
            options.structureControlFlow = false
            let document = PseudocodePrinter(options: options).print(function: function)
            for value in [a, b] {
                let declaration = try XCTUnwrap(document.lines.first {
                    $0.kind == .declaration && $0.syntheticPhiEdge?.destination == value
                })
                XCTAssertTrue(declaration.text.trimmingCharacters(in: .whitespaces).hasPrefix("int64_t "), declaration.text)
            }
        }
    }

    func testPhiUnsignedProofKeepsWidthSpecificLeaves() throws {
        var function = lift(diamond)
        let a = MacIRValue.temporary(800), b = MacIRValue.temporary(801)
        let c = MacIRValue.temporary(802), d = MacIRValue.temporary(803)
        let cast32 = MacIRValue.unary(op: "(uint32_t)", value: .immediate(1))
        let cast64 = MacIRValue.unary(op: "(uint64_t)", value: .immediate(1))
        function.phis = [(a, 32, cast32), (b, 64, a), (c, 32, cast64), (d, 64, cast32)].map { value, width, source in
            MacIRPhi(blockAddress: 0x1010, destination: value, bitWidth: width,
                incoming: [.init(predecessorAddress: 0x1008, value: source),
                           .init(predecessorAddress: 0x100c, value: source)])
        }
        function.returnValue = .abiComposite(type: "widths", fragments: [a, b, c, d])
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        let document = PseudocodePrinter(options: options).print(function: function)
        for (value, type) in [(a, "uint32_t"), (b, "uint64_t"), (c, "int32_t"), (d, "int64_t")] {
            let declaration = try XCTUnwrap(document.lines.first {
                $0.kind == .declaration && $0.syntheticPhiEdge?.destination == value
            })
            XCTAssertTrue(declaration.text.trimmingCharacters(in: .whitespaces).hasPrefix(type + " "), declaration.text)
        }
    }

    func testAlphaEquivalencePreservesIdentitiesAndNonVersionText() {
        let expected: [SSAAlphaEquivalence.ExpectedIdentity: SSAAlphaEquivalence.Definition] = [
            .init(name: "x1", version: 8): .init(sourceRow: 0x1000, width: 64),
            .init(name: "w1", version: 7): .init(sourceRow: 0x1000, width: 64),
            .init(name: "x1", version: 10): .init(sourceRow: 0x1010, width: 64),
            .init(name: "x0", version: 9): .init(sourceRow: 0x1004, width: 64),
            .init(name: "w0", version: 6): .init(sourceRow: 0x1004, width: 64)
        ]
        let actual: [SSAAlphaEquivalence.Identity: SSAAlphaEquivalence.Definition] = [
            .init(cell: 1, version: 2): .init(sourceRow: 0x1000, width: 64),
            .init(cell: 1, version: 4): .init(sourceRow: 0x1000, width: 64),
            .init(cell: 0, version: 3): .init(sourceRow: 0x1004, width: 64)
        ]
        var identities = SSAAlphaEquivalence(expectedDefinitions: expected, actualDefinitions: actual)
        XCTAssertNil(identities.mismatch(actual: "x1_2 = x0_3;", expected: "x1_8 = x0_9;"))
        XCTAssertNil(identities.mismatch(actual: "w1_2 = w0_3;", expected: "w1_7 = w0_6;"),
                     "Different legacy view counters may name the same defining row")
        XCTAssertEqual(identities.mismatch(actual: "x1_4 = x0_3;", expected: "x1_8 = x0_9;"),
                       "One expected identity maps to different actual identities")
        XCTAssertNotNil(identities.mismatch(actual: "x1_2 = x0_3;", expected: "x1_10 = x0_9;"),
                        "Different defining rows cannot collapse to the same actual identity")
        XCTAssertNotNil(identities.mismatch(actual: "w1_4 = w0_3;", expected: "w1_7 = w0_6;"),
                        "An established W-view identity must retain its actual cell definition")
        var constants = SSAAlphaEquivalence(expectedDefinitions: expected, actualDefinitions: actual)
        XCTAssertEqual(constants.mismatch(actual: "x0_3 = 0x2;", expected: "x0_9 = 0x1;"),
                       "Text outside register version digits changed")
        var arguments = SSAAlphaEquivalence(expectedDefinitions: expected, actualDefinitions: actual)
        XCTAssertEqual(arguments.mismatch(actual: "x0_3 = _callee(x1_2, x2_1);", expected: "x0_9 = _callee(x1_8);"),
                       "Register occurrence count changed")
        var target = SSAAlphaEquivalence(expectedDefinitions: expected, actualDefinitions: actual)
        XCTAssertEqual(target.mismatch(actual: "x0_3 = _other(x1_2);", expected: "x0_9 = _callee(x1_8);"),
                       "Text outside register version digits changed")
        var views = SSAAlphaEquivalence(expectedDefinitions: expected, actualDefinitions: actual)
        XCTAssertNotNil(views.mismatch(actual: "w0_3 = 0x1;", expected: "x0_9 = 0x1;"))
        XCTAssertTrue(constants.forward.isEmpty, "Rejected comparisons must not change the shared map")
        XCTAssertEqual(identities.translatedExpected("w1_7 = w0_6;"), "w1_2 = w0_3;")
        XCTAssertNil(identities.translatedExpected("x1_10"), "Translation cannot invent a new correspondence")
    }

    func testAlphaEquivalenceRejectsCollapsedViewsFromDifferentRows() {
        let expected: [SSAAlphaEquivalence.ExpectedIdentity: SSAAlphaEquivalence.Definition] = [
            .init(name: "x0", version: 1): .init(sourceRow: 0x1000, width: 64),
            .init(name: "w0", version: 1): .init(sourceRow: 0x1004, width: 64)
        ]
        let actual: [SSAAlphaEquivalence.Identity: SSAAlphaEquivalence.Definition] = [
            .init(cell: 0, version: 3): .init(sourceRow: 0x1000, width: 64),
            .init(cell: 0, version: 4): .init(sourceRow: 0x1004, width: 64),
            .init(cell: 0, version: 5): .init(sourceRow: 0x1004, width: 32)
        ]
        var collapsed = SSAAlphaEquivalence(expectedDefinitions: expected, actualDefinitions: actual)
        XCTAssertNil(collapsed.mismatch(actual: "x0_3", expected: "x0_1"))
        XCTAssertEqual(collapsed.mismatch(actual: "w0_3", expected: "w0_1"),
                       "Defining source row or width changed",
                       "W and X from different rows must never share an actual identity")
        XCTAssertNil(collapsed.mismatch(actual: "w0_4", expected: "w0_1"),
                     "Equal legacy version digits from distinct views are independent keys")
        var width = SSAAlphaEquivalence(expectedDefinitions: expected, actualDefinitions: actual)
        XCTAssertEqual(width.mismatch(actual: "w0_5", expected: "w0_1"),
                       "Defining source row or width changed")
        var missing = SSAAlphaEquivalence()
        XCTAssertEqual(missing.mismatch(actual: "x0_3", expected: "x0_1"),
                       "Register identity is missing defining-row provenance")
    }

    func testAlphaEquivalenceCollectsTypedFunctionDefinitions() {
        let instructions = rows([("mov", "w1, #7"), ("mov", "x0, x1"), ("ret", "")])
        let expected = MacIRBuilder(ssaEnabled: false).buildFunction(
            name: "alpha_definitions", startAddress: 0x1000,
            callerReturnWidth: .x0, instructions: instructions)
        let actual = lift(instructions)
        var identities = SSAAlphaEquivalence(expected: expected, actual: actual)
        for (actualRow, expectedRow) in zip(actual.instructions, expected.instructions) {
            XCTAssertEqual(actualRow.source, expectedRow.source)
            XCTAssertNil(identities.mismatch(actual: String(describing: actualRow.operation),
                                            expected: String(describing: expectedRow.operation)))
        }
    }

    private func rows(_ assembly: [(String, String)], at base: UInt64 = 0x1000) -> [InstructionRow] {
        assembly.enumerated().map { index, item in
            InstructionRow(address: base + UInt64(index * 4), bytes: "00 00 00 00",
                           mnemonic: item.0, operands: item.1, hasBreakpoint: false, comment: nil)
        }
    }

    private func lift(_ rows: [InstructionRow], width: MacIRCallerReturnEvidence.Width = .x0) -> MacIRFunction {
        MacIRBuilder(ssaEnabled: true).buildFunction(name: "ssa_property", startAddress: rows[0].address,
                                                   callerReturnWidth: width, instructions: rows)
    }

    private var diamond: [InstructionRow] {
        rows([("cbz", "x0, 0x100c"), ("mov", "x1, #11"), ("b", "0x1010"),
              ("mov", "x1, #23"), ("mov", "x0, x1"), ("ret", "")])
    }

    private var loop: [InstructionRow] {
        rows([("mov", "x1, #0"), ("cbz", "x0, 0x2014"), ("add", "x1, x1, x0"),
              ("sub", "x0, x0, #1"), ("b", "0x2004"), ("mov", "x0, x1"), ("ret", "")], at: 0x2000)
    }

    private func state(seed: UInt64) throws -> A64MachineState {
        var state = try A64MachineState(seeding:
            JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
        for index in state.x.indices { state.x[index] = seed &* 17 &+ UInt64(index) }
        state.x[0] = seed
        state.x[30] = 0x9000
        return state
    }

    /// Deliberately limited machine oracle for these authored scalar rows. It
    /// reads architectural registers and wrapping machine arithmetic directly;
    /// it does not inspect MacIR, phi destinations, or rendered pseudocode.
    private func interpret(_ rows: [InstructionRow], state initial: A64MachineState) throws -> A64MachineState {
        enum OracleError: Error { case unsupported(String), invalidPC(UInt64), exhausted }
        var result = initial
        let byAddress = Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) })
        var pc = rows[0].address
        func read(_ text: String) throws -> UInt64 {
            if text == "xzr" || text == "wzr" { return 0 }
            if text.hasPrefix("#"), let immediate = Int64(text.dropFirst()) { return UInt64(bitPattern: immediate) }
            guard let prefix = text.first, prefix == "x" || prefix == "w",
                  let index = Int(text.dropFirst()), result.x.indices.contains(index) else {
                throw OracleError.unsupported(text)
            }
            return prefix == "w" ? UInt64(UInt32(truncatingIfNeeded: result.x[index])) : result.x[index]
        }
        func write(_ text: String, _ value: UInt64) throws {
            guard let prefix = text.first, prefix == "x" || prefix == "w",
                  let index = Int(text.dropFirst()), result.x.indices.contains(index) else {
                throw OracleError.unsupported(text)
            }
            result.x[index] = prefix == "w" ? UInt64(UInt32(truncatingIfNeeded: value)) : value
        }
        func target(_ text: String) throws -> UInt64 {
            guard text.hasPrefix("0x"), let value = UInt64(text.dropFirst(2), radix: 16) else {
                throw OracleError.unsupported(text)
            }
            return value
        }
        for _ in 0..<256 {
            guard let row = byAddress[pc] else { throw OracleError.invalidPC(pc) }
            let operands = row.operands.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var next = pc + 4
            switch row.mnemonic {
            case "mov": try write(operands[0], read(operands[1]))
            case "add": try write(operands[0], read(operands[1]) &+ read(operands[2]))
            case "sub": try write(operands[0], read(operands[1]) &- read(operands[2]))
            case "cbz": if try read(operands[0]) == 0 { next = try target(operands[1]) }
            case "cbnz": if try read(operands[0]) != 0 { next = try target(operands[1]) }
            case "b": next = try target(operands[0])
            case "ret": result.pc = result.x[30]; return result
            default: throw OracleError.unsupported(row.mnemonic)
            }
            pc = next
        }
        throw OracleError.exhausted
    }

    func testDiamondAndLoopAgreeWithArchitecturalRowsForSixteenSeededStates() throws {
        for fixture in [diamond, loop] {
            let function = lift(fixture)
            XCTAssertNotNil(function.cfg)
            XCTAssertFalse(function.phis.isEmpty)
            SSAPropertyAssertions.assertOrdinaryUsesDominated(function)
            for seed in UInt64(0)..<16 {
                let initial = try state(seed: seed)
                let expected = try interpret(fixture, state: initial)
                var evaluator = MacIRConcreteEvaluator(function: function, state: initial)
                try evaluator.runScalarCFG(function.instructions, maximumSteps: 256)
                XCTAssertEqual(evaluator.state.x[0], expected.x[0], "entry \(fixture[0].address), seed \(seed)")
                XCTAssertEqual(evaluator.state.x[1], expected.x[1], "entry \(fixture[0].address), seed \(seed)")
                XCTAssertEqual(evaluator.state.pc, expected.pc)
                XCTAssertEqual(evaluator.state.memory, initial.memory)
            }
        }
    }

    func testPhiSlotsUsePredecessorLastRowsInAddressOrder() throws {
        let function = lift(diamond)
        let phi = try XCTUnwrap(SSAPropertyAssertions.phi(function, block: 0x1010, cell: 1, width: 64,
            incoming: [(0x1008, 0x1004), (0x100c, 0x100c)]))
        guard case let .assign(_, source) = function.instructions[4].operation else {
            return XCTFail("the original join move must consume its phi")
        }
        SSAPropertyAssertions.assertView(source, of: phi, width: 64)
        // The fallthrough predecessor's last row is a MOV, not a branch.
        XCTAssertEqual(phi.incoming.last?.machineAddress, diamond[3].address)
        assertUniqueDefinitions(function)
    }

    func testLoopPhisCaptureTheLatchDefinitions() throws {
        let function = lift(loop)
        let counter = try XCTUnwrap(function.phis.first {
            $0.blockAddress == 0x2004 && SSAPropertyAssertions.physicalCell($0.destination) == 0
        })
        XCTAssertEqual(counter.bitWidth, 64)
        XCTAssertEqual(counter.incoming.map(\.machineAddress), [0x2000, 0x2010])
        XCTAssertEqual(counter.incoming.first?.value, .argument(bindingID: .gpr(0)))
        let decrement = try XCTUnwrap(function.instructions.first { $0.source.address == 0x200c })
        guard case let .binary(destination, _, _, _) = decrement.operation else {
            return XCTFail("the loop latch must retain its decrement definition")
        }
        XCTAssertEqual(counter.incoming.last?.value, destination)
        _ = try XCTUnwrap(SSAPropertyAssertions.phi(function, block: 0x2004, cell: 1, width: 64,
            incoming: [(0x2000, 0x2000), (0x2010, 0x2008)]))
        SSAPropertyAssertions.assertOrdinaryUsesDominated(function)
        assertUniqueDefinitions(function)
    }

    func testDeadAndAgreedCellsDoNotAcquirePhis() {
        let fixture = rows([("mov", "x3, #9"), ("cbz", "x0, 0x1014"),
                            ("mov", "x1, #11"), ("mov", "x2, #41"), ("b", "0x101c"),
                            ("mov", "x1, #23"), ("mov", "x2, #53"),
                            ("add", "x0, x1, x3"), ("ret", "")])
        let function = lift(fixture)
        XCTAssertEqual(function.phis.filter { $0.blockAddress == 0x101c }.count, 1)
        XCTAssertFalse(function.phis.contains { SSAPropertyAssertions.physicalCell($0.destination) == 2 })
        XCTAssertFalse(function.phis.contains { SSAPropertyAssertions.physicalCell($0.destination) == 3 })
        for phi in function.phis {
            XCTAssertGreaterThan(Set(phi.incoming.map(\.value)).count, 1)
            XCTAssertTrue(function.instructions.contains { instruction in
                (RegionalBoundaryPlan.values(instruction.operation) ?? []).contains(phi.destination)
            }, "a persisted phi must have a semantic use")
        }
    }

    func testMixedWidthPhiPersistsZeroExtensionAndWReadTruncation() throws {
        let fixture = rows([("cbz", "x0, 0x100c"), ("mov", "w8, w1"), ("b", "0x1010"),
                            ("mov", "x8, x2"), ("mov", "w0, w8"), ("ret", "")])
        let function = lift(fixture, width: .w0)
        let phi = try XCTUnwrap(SSAPropertyAssertions.phi(function, block: 0x1010, cell: 8, width: 64,
            incoming: [(0x1008, 0x1004), (0x100c, 0x100c)]))
        guard case let .assign(_, source) = function.instructions[4].operation else {
            return XCTFail("W read must remain an ordinary move")
        }
        SSAPropertyAssertions.assertView(source, of: phi, width: 32)
        for seed in UInt64(0)..<16 {
            var initial = try state(seed: seed)
            initial.x[1] = 0xa5a5_a5a5_8000_0000 | seed
            initial.x[2] = 0xfedc_ba98_1234_5600 | seed
            let expected = try interpret(fixture, state: initial)
            var evaluator = MacIRConcreteEvaluator(function: function, state: initial)
            try evaluator.runScalarCFG(function.instructions)
            XCTAssertEqual(evaluator.state.x[0], expected.x[0], "seed \(seed)")
            XCTAssertEqual(evaluator.state.x[8], expected.x[8], "seed \(seed)")
        }
    }

    func testNarrowPhiZeroExtendsItsXRead() throws {
        let fixture = rows([("cbz", "x0, 0x100c"), ("mov", "w8, w1"), ("b", "0x1010"),
                            ("mov", "w8, w2"), ("mov", "x0, x8"), ("ret", "")])
        let function = lift(fixture)
        let phi = try XCTUnwrap(SSAPropertyAssertions.phi(function, block: 0x1010, cell: 8, width: 32,
            incoming: [(0x1008, 0x1004), (0x100c, 0x100c)]))
        guard case let .assign(_, source) = function.instructions[4].operation else {
            return XCTFail("X read must remain an ordinary move")
        }
        SSAPropertyAssertions.assertView(source, of: phi, width: 64)
    }

    private func graph(_ rows: [InstructionRow]) throws -> MacIRCFG {
        // Only the decoded architectural transfers define this planner input.
        // The placeholder operation contributes no values to the effects oracle.
        let instructions = rows.map { row in
            MacIRInstruction(source: .init(address: row.address, byteText: row.bytes,
                mnemonic: row.mnemonic, operands: row.operands),
                operation: .intrinsic(destination: nil, name: "planner_row", arguments: []))
        }
        return try XCTUnwrap(MacIRCFG.build(instructions: instructions, jumpTables: [:],
            knownTailCallTargets: [:], authoredCallSignaturesByTarget: [:]))
    }

    private func effect(_ address: UInt64, reads: [Int] = [],
                        writes: [(cell: Int, width: Int)] = []) -> MacIRSSA.RowEffects {
        .init(address: address, reads: .init(reads), writes: writes.map {
            .init(cell: $0.cell, bitWidth: $0.width, origin: .instruction(address))
        })
    }

    func testPlannerPropagatesLoopLivenessToTheLeastFixedPoint() throws {
        let cfg = try graph(loop)
        let effects = [
            effect(0x2000, writes: [(1, 64)]),
            effect(0x2004, reads: [0, 7]),
            effect(0x2008, reads: [0, 1], writes: [(1, 64)]),
            effect(0x200c, reads: [0], writes: [(0, 64)]),
            effect(0x2010), effect(0x2014, reads: [1], writes: [(0, 64)]),
            effect(0x2018, reads: [0])
        ]
        let plan = try MacIRSSA.plan(cfg: cfg, rows: effects)
        let header = try XCTUnwrap(cfg.blocks.first { $0.startAddress == 0x2004 })
        let body = try XCTUnwrap(cfg.blocks.first { $0.startAddress == 0x2008 })
        XCTAssertTrue(plan.liveIn[header.index].contains(7))
        XCTAssertTrue(plan.liveIn[body.index].contains(7),
                      "a body visited before its header in the backward sweep still needs the next iteration's use")
        XCTAssertFalse(plan.phis.contains { $0.cell == 7 }, "loop-invariant entry value needs no nontrivial phi")
        XCTAssertEqual(Set(plan.phis.filter { $0.block == header.index }.map(\.cell)), [0, 1])
        let counter = try XCTUnwrap(plan.phis.first { $0.block == header.index && $0.cell == 0 })
        XCTAssertEqual(plan.rowReadBindings[1][0], counter.destination)
        XCTAssertEqual(plan.rowReadBindings[3][0], counter.destination)
        XCTAssertEqual(counter.incoming.map(\.machineAddress), [0x2000, 0x2010])
        XCTAssertEqual(plan.definitions[counter.incoming[0].definition].origin, .entry)
        XCTAssertEqual(plan.definitions[counter.incoming[1].definition].origin, .instruction(0x200c))
    }

    func testPlannerRetainsTheReturnCellAndPrunesDeadWrites() throws {
        let fixture = rows([("cbz", "x2, 0x100c"), ("mov", "w0, #7"), ("b", "0x1010"),
                            ("mov", "w0, #0"), ("ret", "")])
        let cfg = try graph(fixture)
        let effects = [effect(0x1000, reads: [2]), effect(0x1004, writes: [(0, 32), (9, 64)]),
                       effect(0x1008), effect(0x100c, writes: [(0, 32), (9, 64)]),
                       effect(0x1010, reads: [0])]
        let plan = try MacIRSSA.plan(cfg: cfg, rows: effects)
        XCTAssertEqual(plan.phis.count, 1)
        let phi = try XCTUnwrap(plan.phis.first)
        XCTAssertEqual(phi.cell, 0)
        XCTAssertEqual(cfg.blocks[phi.block].startAddress, 0x1010)
        XCTAssertEqual(plan.definitions[phi.destination].bitWidth, 32)
        XCTAssertEqual(phi.incoming.map(\.machineAddress), [0x1008, 0x100c])
        XCTAssertEqual(phi.incoming.map { plan.definitions[$0.definition].origin },
                       [.instruction(0x1004), .instruction(0x100c)])
        XCTAssertEqual(plan.rowReadBindings[4][0], phi.destination,
                       "contract uncertainty must not erase the architectural return-cell read")
        XCTAssertFalse(plan.phis.contains { $0.cell == 9 })
    }

    func testPlannerSolvesCyclicWidthConstraintsAtTheirMaximum() throws {
        let cfg = try graph(loop)
        let effects = [effect(0x2000, writes: [(8, 32)]), effect(0x2004, reads: [0]),
                       effect(0x2008, reads: [8], writes: [(8, 64)]),
                       effect(0x200c, reads: [0], writes: [(0, 64)]), effect(0x2010),
                       effect(0x2014, reads: [8], writes: [(0, 64)]), effect(0x2018, reads: [0])]
        let plan = try MacIRSSA.plan(cfg: cfg, rows: effects)
        let phi = try XCTUnwrap(plan.phis.first { $0.cell == 8 })
        XCTAssertEqual(plan.definitions[phi.destination].bitWidth, 64)
        XCTAssertEqual(phi.incoming.map { plan.definitions[$0.definition].bitWidth }, [32, 64])
        XCTAssertEqual(plan.rowReadBindings[2][8], phi.destination)
        XCTAssertEqual(plan.rowReadBindings[5][8], phi.destination)
    }

    func testPlannerKeepsScalarLowHalfAndFreshCallClobberHighHalfSeparate() throws {
        let fixture = rows([("fmov", "d8, #1.5"), ("fmov", "d9, #0.5"), ("mov", "x19, #2"),
                            ("bl", "_opaque"), ("str", "q8, [x21]"), ("fadd", "d8, d8, d9"),
                            ("sub", "x19, x19, #1"), ("cbnz", "x19, 0x300c"),
                            ("str", "d8, [x20]"), ("ret", "")], at: 0x3000)
        let cfg = try graph(fixture)
        var effects = fixture.map { effect($0.address) }
        effects[0].writes = [.init(cell: 40, bitWidth: 64, view: .float64, origin: .instruction(0x3000))]
        effects[1].writes = [.init(cell: 41, bitWidth: 64, view: .float64, origin: .instruction(0x3004))]
        effects[2].writes = [.init(cell: 19, bitWidth: 64, origin: .instruction(0x3008))]
        effects[3].writes = [72, 73].map {
            .init(cell: $0, bitWidth: 64, view: .bits, origin: .callClobber(0x300c))
        }
        effects[4].reads = .init([40, 72])
        // A bit-preserving store does not request a numeric reinterpretation.
        effects[5].reads = .init([40, 41])
        effects[5].readViews = [40: .float64, 41: .float64]
        effects[5].writes = [.init(cell: 40, bitWidth: 64, view: .float64, origin: .instruction(0x3014)),
                             .init(cell: 72, bitWidth: 64, view: .bits, origin: .instruction(0x3014))]
        effects[6] = effect(0x3018, reads: [19], writes: [(19, 64)])
        effects[7].reads = .init([19])
        effects[8].reads = .init([40])
        effects[8].readViews = [40: .float64]
        let plan = try MacIRSSA.plan(cfg: cfg, rows: effects)
        let low = try XCTUnwrap(plan.phis.first { $0.cell == 40 })
        XCTAssertEqual(plan.definitions[low.destination].view, .float64)
        XCTAssertEqual(low.incoming.map(\.machineAddress), [0x3008, 0x301c])
        XCTAssertEqual(plan.rowReadBindings[4][40], low.destination)
        let high = try XCTUnwrap(plan.rowReadBindings[4][72])
        XCTAssertEqual(plan.rowWriteBindings[3][72], high)
        XCTAssertEqual(plan.definitions[high].origin, .callClobber(0x300c))
        XCTAssertFalse(plan.phis.contains { $0.cell == 72 || $0.cell == 73 })

        var packedEffects = effects
        packedEffects[5].readViews[40] = .bits
        let packedPlan = try MacIRSSA.plan(cfg: cfg, rows: packedEffects)
        let packedLow = try XCTUnwrap(packedPlan.phis.first { $0.cell == 40 })
        XCTAssertEqual(packedPlan.definitions[packedLow.destination].view, .bits,
                       "mixed scalar and packed uses require a bit-preserving carrier")
    }

    func testPlannerPreservesRefusalOriginInTheExactPredecessorSlot() throws {
        let fixture = rows([("cbz", "x0, 0x100c"), ("ldaxr", "x1, [x2]"), ("b", "0x1010"),
                            ("mov", "x1, #2"), ("mov", "x0, x1"), ("ret", "")])
        let cfg = try graph(fixture)
        var effects = [effect(0x1000, reads: [0]), effect(0x1004, reads: [2]), effect(0x1008),
                       effect(0x100c, writes: [(1, 64)]), effect(0x1010, reads: [1], writes: [(0, 64)]),
                       effect(0x1014, reads: [0])]
        let refusal = MacIRRefusal(reason: .unknownEffects, scope: .cell(1, 0x1004), detail: "unsupported atomic load")
        effects[1].writes = [.init(cell: 1, bitWidth: 64, origin: .refusal(.unknownEffects, 0x1004))]
        effects[1].refusals = [refusal]
        let plan = try MacIRSSA.plan(cfg: cfg, rows: effects)
        let phi = try XCTUnwrap(plan.phis.first { $0.cell == 1 })
        XCTAssertEqual(phi.incoming.map(\.machineAddress), [0x1008, 0x100c])
        XCTAssertEqual(plan.definitions[phi.incoming[0].definition].origin, .refusal(.unknownEffects, 0x1004))
        XCTAssertEqual(plan.definitions[phi.incoming[1].definition].origin, .instruction(0x100c))
        XCTAssertEqual(plan.rowReadBindings[4][1], phi.destination)
        XCTAssertTrue(plan.refusals.contains(refusal))
    }

    func testPlannerCancellationAfterPlacementReturnsNoPartialPlan() throws {
        let cfg = try graph(diamond)
        let effects = [effect(0x1000, reads: [0]), effect(0x1004, writes: [(1, 64)]),
                       effect(0x1008), effect(0x100c, writes: [(1, 64)]),
                       effect(0x1010, reads: [1], writes: [(0, 64)]), effect(0x1014, reads: [0])]
        var cancelled = false
        var reachedRenaming = false
        XCTAssertThrowsError(try MacIRSSA.plan(cfg: cfg, rows: effects,
            cancelled: { cancelled }, beforeRenaming: {
                reachedRenaming = true
                cancelled = true
            })) { error in
                XCTAssertEqual(error as? MacIRSSA.PlanningError, .cancelled)
            }
        XCTAssertTrue(reachedRenaming, "the test must reach the post-placement cancellation boundary")
    }

    func testPlannerRefusesAnEntryBackedgeWithoutCreatingAnEntryBlock() throws {
        let fixture = rows([("add", "x0, x0, #1"), ("cbnz", "x0, 0x1000"), ("ret", "")])
        let cfg = try graph(fixture)
        let effects = [effect(0x1000, reads: [0], writes: [(0, 64)]),
                       effect(0x1004, reads: [0]), effect(0x1008, reads: [0])]
        XCTAssertThrowsError(try MacIRSSA.plan(cfg: cfg, rows: effects)) { error in
            XCTAssertEqual(error as? MacIRSSA.PlanningError, .entryBlockHasPredecessor)
        }
    }

    func testUnknownLeavesAreEntryClobberRefusalOrReturnContractValues() throws {
        let fixture = rows([("mov", "x19, x0"), ("bl", "_opaque"),
                            ("ldaxr", "x1, [x2]"), ("add", "x0, x1, x3"), ("ret", "")])
        let function = lift(fixture)
        let info = try XCTUnwrap(function.ssaInfo)
        let consumedClobber = try XCTUnwrap(info.plan.rowReadBindings[3][3])
        XCTAssertEqual(info.plan.definitions[consumedClobber].origin, .callClobber(0x1004))
        let consumedRefusal = try XCTUnwrap(info.plan.rowReadBindings[3][1])
        XCTAssertEqual(info.plan.definitions[consumedRefusal].origin, .refusal(.unknownEffects, 0x1008))
        var attributedUnknowns: Set<MacIRValue> = []
        var sawClobber = false
        var sawRefusal = false
        for (id, value) in info.values {
            guard case let .unknown(marker) = value else { continue }
            let definition = info.plan.definitions[id]
            switch definition.origin {
            case .entry:
                XCTAssertTrue(marker.hasPrefix("unbound_"), marker)
            case .callClobber:
                sawClobber = true
                // Retained straight-line controls keep their existing spelling;
                // the exact SSA origin, rather than that spelling, is authority.
                XCTAssertTrue(marker.hasPrefix("clobbered_") || marker.hasPrefix("unavailable_"), marker)
            case let .refusal(reason, address):
                sawRefusal = true
                XCTAssertTrue(function.refusals.contains {
                    $0.reason == reason && ($0.scope == .row(address)
                        || $0.scope == .cell(definition.cell, address) || $0.scope == .function)
                }, "refused value requires its reason and source scope")
            case .instruction, .callResult, .phi:
                XCTFail("a regular definition cannot invent an unattributed unknown: \(marker)")
            }
            attributedUnknowns.insert(value)
        }
        XCTAssertTrue(sawClobber, "the fixture must exercise a consumed caller-clobbered value")
        XCTAssertTrue(sawRefusal, "the fixture must exercise an unsupported writer")
        func unknowns(_ value: MacIRValue) -> [MacIRValue] {
            switch value {
            case .unknown: return [value]
            case let .unary(_, inner), let .bitTest(inner, _): return unknowns(inner)
            case let .binaryExpression(_, left, right): return unknowns(left) + unknowns(right)
            case let .abiComposite(_, fragments): return fragments.flatMap(unknowns)
            default: return []
            }
        }
        let operands = function.instructions.flatMap { RegionalBoundaryPlan.values($0.operation) ?? [] }
            + function.phis.flatMap { $0.incoming.map(\.value) }
            + (function.returnValue.map { [$0] } ?? [])
        for value in operands.flatMap(unknowns) {
            XCTAssertTrue(attributedUnknowns.contains(value)
                || value == .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker),
                "every published unknown leaf must have one of the four declared origins")
        }
    }

    func testEvaluatorBitcastsPreserveNaNPayloadsAndVectorHalfOrder() throws {
        let function = MacIRBuilder(ssaEnabled: false).buildFunction(name: "bitcast_oracle",
            instructions: rows([("ret", "")]))
        var evaluator = MacIRConcreteEvaluator(function: function, state: try state(seed: 0))
        let binary64Patterns: [UInt64] = [0x8000_0000_0000_0000, 0x7ff8_0000_0000_1234, 0x3ff8_0000_0000_0000]
        for bits in binary64Patterns {
            let reinterpreted = MacIRValue.unary(op: "__ssa_bitcast_f64", value: .immediate(Int64(bitPattern: bits)))
            let floating = try evaluator.evaluate(reinterpreted)
            XCTAssertEqual(floating.bits, bits)
            XCTAssertEqual(floating.width, 64)
            XCTAssertEqual(floating.kind, .float)
            let roundTrip = try evaluator.evaluate(.unary(op: "__ssa_bitcast_u64", value: reinterpreted))
            XCTAssertEqual(roundTrip.bits, bits)
            XCTAssertEqual(roundTrip.kind, .unsigned)
        }
        let binary32Patterns: [UInt64] = [0x8000_0000, 0x7fc0_1234, 0x3fc0_0000]
        for bits in binary32Patterns {
            let reinterpreted = MacIRValue.unary(op: "__ssa_bitcast_f32", value: .immediate(Int64(bits)))
            let floating = try evaluator.evaluate(reinterpreted)
            XCTAssertEqual(floating.bits, bits)
            XCTAssertEqual(floating.width, 32)
            XCTAssertEqual(floating.kind, .float)
            let roundTrip = try evaluator.evaluate(.unary(op: "__ssa_bitcast_u32", value: reinterpreted))
            XCTAssertEqual(roundTrip.bits, bits)
            XCTAssertEqual(roundTrip.width, 32)
            XCTAssertEqual(roundTrip.kind, .unsigned)
        }
        let joined = try evaluator.evaluate(.binaryExpression(op: "__ssa_join_vector_halves",
            left: .unary(op: "__ssa_bitcast_f64", value: .immediate(Int64(bitPattern: 0x7ff8_0000_0000_1234))),
            right: .immediate(Int64(bitPattern: 0xfedc_ba98_7654_3210))))
        XCTAssertEqual(joined.width, 128)
        XCTAssertEqual(joined.kind, .unsigned)
        XCTAssertEqual(joined.bits, 0x7ff8_0000_0000_1234)
        XCTAssertEqual(joined.high, 0xfedc_ba98_7654_3210)
    }

    private func assertUniqueDefinitions(_ function: MacIRFunction,
                                         file: StaticString = #filePath, line: UInt = #line) {
        struct Identity: Hashable { let cell: Int; let version: Int }
        struct PhiIdentity: Hashable { let cell: Int; let block: UInt64 }
        let definitions = function.instructions.flatMap { SSAPropertyAssertions.definitions($0.operation) }
            + function.phis.map(\.destination)
        let identities = definitions.compactMap { value -> Identity? in
            guard case let .register(_, version) = value,
                  let cell = SSAPropertyAssertions.physicalCell(value) else { return nil }
            return Identity(cell: cell, version: version)
        }
        XCTAssertEqual(Set(identities).count, identities.count,
                       "each physical-cell version must have one definition", file: file, line: line)
        let phiIdentities = function.phis.compactMap { phi -> PhiIdentity? in
            guard let cell = SSAPropertyAssertions.physicalCell(phi.destination) else { return nil }
            return PhiIdentity(cell: cell, block: phi.blockAddress)
        }
        XCTAssertEqual(Set(phiIdentities).count, function.phis.count,
                       "a block has at most one phi per physical cell", file: file, line: line)
        guard let cfg = function.cfg else {
            return XCTFail("SSA function must retain its complete CFG", file: file, line: line)
        }
        func dominates(_ definition: Int, _ use: Int) -> Bool {
            var current = use
            for _ in cfg.blocks.indices {
                if current == definition { return true }
                guard cfg.idom.indices.contains(current), cfg.idom[current] >= 0,
                      cfg.idom[current] != current else { return false }
                current = cfg.idom[current]
            }
            return false
        }
        func producerLeaf(_ value: MacIRValue) -> MacIRValue {
            if case let .unary(_, inner) = value { return producerLeaf(inner) }
            return value
        }
        for phi in function.phis {
            guard let block = cfg.blocks.first(where: { $0.startAddress == phi.blockAddress }) else {
                XCTFail("phi must identify a graph block", file: file, line: line)
                continue
            }
            let addresses = block.predecessors.map { predecessor in
                function.instructions[cfg.blocks[predecessor].instructionRange.upperBound - 1].source.address
            }
            XCTAssertEqual(phi.incoming.map(\.machineAddress), addresses.map(Optional.some), file: file, line: line)
            for (incoming, predecessor) in zip(phi.incoming, block.predecessors) {
                let value = producerLeaf(incoming.value)
                guard case .register = value else { continue }
                let row = function.instructions.firstIndex {
                    SSAPropertyAssertions.definitions($0.operation).contains(value)
                }
                let producerBlock = row.flatMap { row in
                    cfg.blocks.first { $0.instructionRange.contains(row) }?.index
                } ?? function.phis.first(where: { $0.destination == value }).flatMap { producer in
                    cfg.blocks.first { $0.startAddress == producer.blockAddress }?.index
                }
                guard let producerBlock else {
                    XCTFail("incoming SSA register must have a definition", file: file, line: line)
                    continue
                }
                XCTAssertTrue(dominates(producerBlock, predecessor),
                              "incoming definition must be available at its named predecessor exit", file: file, line: line)
            }
        }
    }

    private final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var observations = 0
        private var cancellations = 0
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            cancellations += 1
        }
        func observe() -> Bool {
            lock.lock(); defer { lock.unlock() }
            observations += 1
            return cancelled
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return observations }
        var cancellationCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    }

    func testCancellationBetweenPlacementAndRenamingPublishesOnlyTheFallback() {
        let token = CancellationToken()
        let function = MacIRBuilder(ssaEnabled: true, ssaCancellation: { token.observe() },
                                    ssaBeforeRenaming: { token.cancel() })
            .buildFunction(name: "cancelled_ssa", startAddress: diamond[0].address,
                           callerReturnWidth: .x0, instructions: diamond)
        XCTAssertNil(function.cfg)
        XCTAssertNil(function.ssaInfo)
        XCTAssertTrue(function.phis.isEmpty)
        XCTAssertEqual(function.refusals.count, 1)
        XCTAssertEqual(function.refusals.first?.reason, .cancelled)
        XCTAssertEqual(function.refusals.first?.scope, .function)
        XCTAssertGreaterThan(token.count, 0)
        XCTAssertEqual(token.cancellationCount, 1, "latched cancellation must not retry the SSA transaction")
        let defined = Set(function.instructions.flatMap { SSAPropertyAssertions.definitions($0.operation) })
        if let value = function.returnValue, case .register = value {
            XCTAssertTrue(defined.contains(value), "cancelled result must not reference an abandoned phi")
        }
    }

    func testCancellationAtPublicationDiscardsScalarAndRetainedResults() {
        let entryBackedge = rows([("add", "x0, x0, #1"), ("cbnz", "x1, 0x1000"), ("ret", "")])
        for fixture in [diamond, entryBackedge] {
            let token = CancellationToken()
            let function = MacIRBuilder(ssaEnabled: true, ssaCancellation: { token.observe() },
                ssaBeforeFinalization: { token.cancel() })
                .buildFunction(name: "cancelled_publication", instructions: fixture)
            XCTAssertNil(function.cfg)
            XCTAssertNil(function.ssaInfo)
            XCTAssertNil(function.returnValue)
            XCTAssertTrue(function.phis.isEmpty)
            XCTAssertEqual(function.refusals.map(\.reason), [.cancelled])
            XCTAssertEqual(function.refusals.map(\.scope), [.function])
            XCTAssertEqual(token.cancellationCount, 1)
            XCTAssertEqual(function.instructions.map(\.source.address), fixture.map(\.address))
            for instruction in function.instructions {
                guard case let .unknown(destination, inputs, _, _) = instruction.operation else {
                    XCTFail("publication cancellation must discard every privately lifted operation")
                    continue
                }
                XCTAssertNil(destination)
                for read in inputs.mayRead + inputs.definiteRead {
                    XCTAssertEqual(read.value, .unknown("cancelled_\(read.register)"))
                }
            }
        }
    }

    func testCancellationAtEarlyVectorPublicationDiscardsTheCompleteRegion() throws {
        // Reuse the decoded MOVI/non-entry-loop fixture from the existing
        // unknown-GPR vector tests; its first row proves region admission.
        let words: [UInt32] = [0x4f00e4e4, 0xd280012e, 0xd280006a, 0x4e183c8e,
                              0x9b0a7dcf, 0x2a0e03f0, 0xd503201f, 0xb5ffffe5, 0xd65f03c0]
        let bytes = words.reduce(into: Data()) { bytes, word in
            var value = word.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        let decoded = ARM64Decoder().decode(bytes, baseAddress: 0x1000, maxInstructionCount: words.count)
        XCTAssertEqual(decoded.count, words.count)
        XCTAssertFalse(decoded.contains { ["unknown", "unavailable"].contains($0.mnemonic) })
        let fixture = decoded.map { InstructionRow(address: $0.address, bytes: $0.byteText,
            mnemonic: $0.mnemonic, operands: $0.operands, hasBreakpoint: false, comment: $0.comment) }
        XCTAssertTrue(MacIRBuilder.attemptsGeneralVectorRegion(fixture))
        let renaming = CancellationToken()
        let control = MacIRBuilder(ssaEnabled: true, ssaCancellation: { false },
            ssaBeforeRenaming: { renaming.cancel() })
            .buildFunction(name: "vector_publication", startAddress: 0x1000, instructions: fixture)
        let vector = try XCTUnwrap(control.instructions.first { $0.source.address == 0x1000 })
        XCTAssertNotNil(vector.neonImmediate, "the control must take the successful vector-region path")
        XCTAssertNotNil(control.cfg)
        XCTAssertNil(control.ssaInfo)
        XCTAssertEqual(renaming.cancellationCount, 0, "the control must return before scalar SSA renaming")

        let cancellation = CancellationToken()
        let function = MacIRBuilder(ssaEnabled: true, ssaCancellation: { cancellation.observe() },
            ssaBeforeRenaming: { renaming.cancel() },
            ssaBeforeFinalization: { cancellation.cancel() })
            .buildFunction(name: "vector_publication", startAddress: 0x1000, instructions: fixture)
        XCTAssertEqual(renaming.cancellationCount, 0, "cancellation must not re-enter scalar SSA")
        XCTAssertEqual(cancellation.cancellationCount, 1, "a latched cancellation must finalize only once")
        XCTAssertNil(function.cfg)
        XCTAssertNil(function.ssaInfo)
        XCTAssertNil(function.returnValue)
        XCTAssertTrue(function.phis.isEmpty)
        XCTAssertEqual(function.refusals.map(\.reason), [.cancelled])
        XCTAssertEqual(function.refusals.map(\.scope), [.function])
        XCTAssertEqual(function.instructions.map(\.source.address), fixture.map(\.address))
        for instruction in function.instructions {
            guard case let .unknown(destination, inputs, _, _) = instruction.operation else {
                XCTFail("cancelled vector output must come solely from the fresh opaque row pass")
                continue
            }
            XCTAssertNil(destination)
            XCTAssertNil(instruction.neonImmediate)
            for read in inputs.mayRead + inputs.definiteRead {
                XCTAssertEqual(read.value, .unknown("cancelled_\(read.register)"))
            }
        }
    }

    func testUndecodableRowHasOneAttributedRefusalAnnotation() {
        let fixture = rows([("udf", "#0")])
        let function = lift(fixture)
        XCTAssertEqual(function.refusals.map(\.reason), [.undecodableRow])
        XCTAssertEqual(function.refusals.map(\.scope), [.row(0x1000)])
        let document = PseudocodePrinter().print(function: function)
        let annotations = document.lines.filter { $0.refusal != nil }
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations.first?.source?.address, 0x1000)
        XCTAssertNil(annotations.first?.sourceAddress)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000).count, 1)
    }

    func testImplicitFlagBranchKeepsTakenCopiesOnItsOwnEdge() throws {
        let fixture = rows([("mov", "x1, #1"), ("cbz", "x0, 0x1010"),
            ("mov", "x1, #2"), ("b.eq", "0x1018"), ("mov", "x1, #3"),
            ("b", "0x1018"), ("mov", "x0, x1"), ("ret", "")])
        let function = lift(fixture)
        let phi = try XCTUnwrap(SSAPropertyAssertions.phi(function, block: 0x1018, cell: 1,
            width: 64, incoming: [(0x100c, 0x1008), (0x1014, 0x1010)]))
        guard case .intrinsic(nil, "branch_eq", [.immediate(0x1018)]) = function.instructions[3].operation else {
            return XCTFail("the implicit flag branch must retain its operation")
        }
        let document = PseudocodePrinter(options: .init(structureControlFlow: false,
            deadCodeElimination: false, nopElision: false, functionSizeGate: 1024)).print(function: function)
        XCTAssertFalse(document.text.contains("__unavailable_cfg_phi"))
        let branch = try XCTUnwrap(document.lines(sourcedAt: 0x100c).first)
        XCTAssertTrue(branch.text.contains("__branch_eq(L_edge_"))
        let incoming = document.lines.filter {
            $0.syntheticPhiEdge?.blockAddress == phi.blockAddress
                && $0.syntheticPhiEdge?.machineAddress == 0x100c
        }
        // 041fd2aca (PseudocodePrinter.swift snapshotName/qualifier, ssaEnabled only): SSA phi
        // snapshots are plain temporaries without the legacy `const` qualifier.
        XCTAssertFalse(incoming.contains { $0.text.contains("const ") }, incoming.map(\.text).joined(separator: "\n"))
        XCTAssertTrue(incoming.contains { $0.text.range(of: #"^\s*uint64_t __edge_\d+_\d+_\d+ = x1_2;$"#, options: .regularExpression) != nil },
                      incoming.map(\.text).joined(separator: "\n"))
        XCTAssertTrue(incoming.contains { $0.text.contains("goto L_1018") })
        XCTAssertTrue(incoming.allSatisfy { $0.sourceAddress == nil })
    }

    func testConditionalCopyStubPreservesBranchSourceAndTargetIdentity() throws {
        let fixture = rows([("mov", "x1, #1"), ("cbz", "x0, 0x1010"),
            ("mov", "x1, #2"), ("cbz", "x2, 0x1018"), ("mov", "x1, #3"),
            ("b", "0x1018"), ("mov", "x0, x1"), ("ret", "")])
        let function = lift(fixture)
        let document = PseudocodePrinter(options: .init(structureControlFlow: false,
            deadCodeElimination: false, nopElision: false, functionSizeGate: 1024)).print(function: function)
        let branchLines = document.lines(sourcedAt: 0x100c)
        XCTAssertEqual(branchLines.count, 1)
        let branch = try XCTUnwrap(branchLines.first)
        XCTAssertTrue(branch.text.contains("goto L_edge_"))
        let normalized = RenderProperties.normalize(document, rows: fixture, allowing: [.labelSpelling])
        let normalizedBranch = normalized.filter { $0.sourceRow == 3 }
        XCTAssertEqual(normalizedBranch.count, 1)
        XCTAssertTrue(try XCTUnwrap(normalizedBranch.first).text.contains("goto 0x1018;"))
        let stubIndex = try XCTUnwrap(document.lines.firstIndex {
            $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("L_edge_")
                && $0.text.hasSuffix(":") && $0.syntheticPhiEdge?.machineAddress == 0x100c
        })
        let edge = try XCTUnwrap(document.lines[stubIndex].syntheticPhiEdge)
        XCTAssertEqual(edge.blockAddress, 0x1018)
        var wrongPredecessor = document
        wrongPredecessor.lines[stubIndex].source?.syntheticPhiEdge = .init(
            blockAddress: edge.blockAddress, predecessorAddress: 0x1004, destination: edge.destination)
        let rejected = RenderProperties.normalize(wrongPredecessor, rows: fixture, allowing: [.labelSpelling])
        let rejectedBranch = rejected.filter { $0.sourceRow == 3 }
        XCTAssertEqual(rejectedBranch.count, 1)
        XCTAssertTrue(try XCTUnwrap(rejectedBranch.first).text.contains("goto L_edge_"),
            "a split label belonging to another predecessor is not equivalent to this branch")
    }

    func testPresentationPhiReachabilityPreservesLiveCyclesAndNestedViews() {
        let a = MacIRValue.register(name: "w1", version: 1)
        let b = MacIRValue.register(name: "x2", version: 1)
        let c = MacIRValue.register(name: "x7", version: 1)
        let d = MacIRValue.register(name: "vh3", version: 1)
        let phis = [
            MacIRPhi(blockAddress: 0x1010, destination: a, bitWidth: 32,
                incoming: [.init(predecessorAddress: 0x1000, value: .immediate(1)),
                           .init(predecessorAddress: 0x1020, value: .unary(op: "uint32_t", value: b))], cell: 1),
            MacIRPhi(blockAddress: 0x1020, destination: b, bitWidth: 64,
                incoming: [.init(predecessorAddress: 0x1010, value: a)], cell: 2),
            MacIRPhi(blockAddress: 0x1030, destination: c, bitWidth: 64,
                incoming: [.init(predecessorAddress: 0x1000, value: .unknown("unavailable_x7")),
                           .init(predecessorAddress: 0x1040, value: d)], cell: 7),
            MacIRPhi(blockAddress: 0x1040, destination: d, bitWidth: 64,
                incoming: [.init(predecessorAddress: 0x1030, value: c)], cell: 67)
        ]
        let viewed = MacIRValue.unary(op: "uint64_t", value: .unary(op: "uint32_t", value: a))
        var function = MacIRFunction(name: "phi_dependencies", startAddress: 0x1000,
            returnValue: viewed, instructions: [], phis: phis)
        function.ssaEnabled = true
        let original = function
        XCTAssertEqual(PseudocodePrinter.presentationPhis(function), Array(phis.prefix(2)),
            "A live cycle retains all incoming dependencies; an unseeded cycle has no printed copies")
        XCTAssertEqual(function, original, "Presentation pruning must not alter persisted semantic evidence")
        function.returnValue = .abiComposite(type: "pair", fragments: [viewed, .bitTest(value: d, bit: 2)])
        XCTAssertEqual(PseudocodePrinter.presentationPhis(function), phis,
            "A nested high-half use retains its whole cycle, including an unavailable incoming")
        function.ssaEnabled = false
        function.returnValue = nil
        XCTAssertEqual(PseudocodePrinter.presentationPhis(function), phis,
            "Legacy presentation keeps every supplied phi")
    }

    func testPresentationPhiReachabilityIncludesImplicitAndRecoveredInputs() {
        let value = MacIRValue.register(name: "x4", version: 2)
        let phi = MacIRPhi(blockAddress: 0x1010, destination: value, bitWidth: 64,
            incoming: [.init(predecessorAddress: 0x1000, value: .immediate(7))], cell: 4)
        let source = MacIRSourceSpan(address: 0x1010, byteText: "", mnemonic: "ret", operands: "")
        let instructions = [
            MacIRInstruction(source: source, operation: .returnValue(nil), returnTarget: value),
            MacIRInstruction(source: source, operation: .stackSlotRead(destination: .temporary(0),
                slot: .stackSlot(offset: 0), value: value)),
            MacIRInstruction(source: source, operation: .unknown(destination: nil,
                inputs: .init(mayRead: [.init(register: "x4", value: value)]), mnemonic: "opaque", operands: ""))
        ]
        for instruction in instructions {
            var function = MacIRFunction(name: "implicit_dependency", startAddress: 0x1000,
                instructions: [instruction], phis: [phi])
            function.ssaEnabled = true
            XCTAssertEqual(PseudocodePrinter.presentationPhis(function), [phi],
                "Recovered values and control sidecars keep their exact phi dependency")
        }
    }

    func testComparisonPresentationUsesOnlyExactRemoteFlagDefinition() throws {
        let function = lift(rows([("cmp", "w1, #1"), ("cbz", "x0, 0x1010"),
            ("bl", "_opaque"), ("ret", ""), ("b.eq", "0x1018"),
            ("mov", "x0, #3"), ("ret", "")]))
        let original = function.instructions[4].operation
        guard case .intrinsic(nil, "branch_eq", [.immediate(0x1018)]) = original,
              case let .intrinsic(nil, "compare", operands) = function.instructions[0].operation else {
            return XCTFail("remote consumer must retain an intrinsic and its independent compare producer")
        }
        let presentation = PseudocodePrinter.ssaComparisonPresentation(of: function)
        XCTAssertEqual(presentation.instructions[4].operation, .conditionalBranch(
            condition: "==", left: operands[0], right: operands[1], target: .immediate(0x1018)))
        XCTAssertEqual(function.instructions[4].operation, original)
        XCTAssertEqual(presentation.instructions.map(\.source), function.instructions.map(\.source))
        XCTAssertEqual(presentation.phis, function.phis)
        XCTAssertEqual(presentation.returnValue, function.returnValue)

        let clobbered = lift(rows([("cmp", "w1, #1"), ("bl", "_opaque"),
            ("b.eq", "0x1010"), ("mov", "x0, #3"), ("ret", "")]))
        guard case .intrinsic(nil, "branch_eq", _) = clobbered.instructions[2].operation else {
            return XCTFail("opaque call must invalidate comparison authority")
        }
        XCTAssertEqual(PseudocodePrinter.ssaComparisonPresentation(of: clobbered), clobbered)
        let merged = lift(rows([("cmp", "w1, #1"), ("cbz", "x0, 0x1010"),
            ("cmp", "w1, #2"), ("b", "0x1014"), ("mov", "x2, #0"),
            ("b.eq", "0x101c"), ("mov", "x0, #3"), ("ret", "")]))
        // 94c68a453 (flags-phi join lift, ssaEnabled): both incoming edges carry a recorded
        // comparison, so this consumer is lifted off the intrinsic; presentation leaves it as is.
        if case .intrinsic(nil, "branch_eq", _) = merged.instructions[5].operation {
            return XCTFail("a join whose every incoming edge records a comparison lifts through the flags phi")
        }
        XCTAssertEqual(PseudocodePrinter.ssaComparisonPresentation(of: merged), merged)
    }
}
