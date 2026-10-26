import Foundation
import XCTest
@testable import MacScope

final class EntryLoopAdmissionTests: XCTestCase {
    private func row(_ address: UInt64, _ bytes: String, _ mnemonic: String, _ operands: String = "",
                     structured: InstructionOperands? = nil) -> InstructionRow {
        .init(address: address, bytes: bytes, mnemonic: mnemonic, operands: operands,
              hasBreakpoint: false, comment: nil, structuredOperands: structured)
    }

    private var addition: [InstructionRow] { [
        row(0x1000, "00 00 01 8b", "add", "x0, x0, x1"),
        row(0x1004, "42 04 00 f1", "subs", "x2, x2, #1"),
        row(0x1008, "c1 ff ff 54", "b.ne", "0x1000"),
        row(0x100c, "c0 03 5f d6", "ret")
    ] }

    private var swap: [InstructionRow] { [
        row(0x1000, "e3 03 00 aa", "mov", "x3, x0"),
        row(0x1004, "e0 03 01 aa", "mov", "x0, x1"),
        row(0x1008, "e1 03 03 aa", "mov", "x1, x3"),
        row(0x100c, "42 04 00 f1", "subs", "x2, x2, #1"),
        row(0x1010, "81 ff ff 54", "b.ne", "0x1000"),
        row(0x1014, "c0 03 5f d6", "ret")
    ] }

    private func build(_ rows: [InstructionRow], ssa: Bool) -> MacIRFunction {
        MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa)
            .buildFunction(name: "bounded_entry_loop", instructions: rows)
    }

    private func admitted(_ rows: [InstructionRow]) throws -> MacIRFunction {
        let function = build(rows, ssa: true)
        XCTAssertTrue(function.ssaEnabled)
        XCTAssertTrue(MacIRBuilder.hasBoundedEntryLoopProof(function))
        _ = try XCTUnwrap(function.ssaInfo)
        return function
    }

    /// Deliberately distinct from the whole-list oracle (which refuses virtual
    /// entry). Interpret only actual emitted scalar operations and typed edges;
    /// bytes/text never supply arithmetic, branch decisions, or expected values.
    private func interpret(_ function: MacIRFunction, x0: UInt64, x1: UInt64, count: UInt64,
                           initialState: A64MachineState? = nil)
        throws -> (state: A64MachineState, initializations: Int, backedges: Int) {
        guard MacIRBuilder.hasBoundedEntryLoopProof(function), let info = function.ssaInfo,
              function.phis.allSatisfy({ $0.cell.map { (0..<29).contains($0) || $0 == 97 } == true }) else {
            throw MacIRConcreteEvaluator.Failure.harness("outside focused scalar entry fixture")
        }
        // Memory epoch is SSA ordering metadata, not a concrete machine register.
        // Its exact identities/edges remain checked; actual memory is executed below.
        let memoryEpochValues = Set(info.plan.definitions.filter { $0.view == .memoryEpoch }
            .compactMap { info.values[$0.id] })
        for phi in function.phis where phi.cell == 97 {
            guard let planned = info.plan.phis.first(where: { $0.cell == 97 }),
                  info.plan.definitions[planned.destination].view == .memoryEpoch,
                  planned.incoming.allSatisfy({ info.plan.definitions[$0.definition].view == .memoryEpoch }),
                  phi.incoming.count == 2,
                  phi.incoming[0].predecessor == .functionEntry,
                  phi.incoming[1].machineAddress == info.sourceAddresses[info.sourceAddresses.count - 2],
                  memoryEpochValues.contains(phi.destination),
                  phi.incoming.allSatisfy({ memoryEpochValues.contains($0.value) }) else {
                throw MacIRConcreteEvaluator.Failure.harness("invalid memory-epoch bookkeeping")
            }
        }
        var state = try initialState ?? A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
            from: Data("{}".utf8)))
        if initialState == nil { state.x[0] = x0; state.x[1] = x1; state.x[2] = count }
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        let groups = Dictionary(grouping: function.instructions, by: { $0.source.address })
        let addresses = info.sourceAddresses
        guard Set(groups.keys) == Set(addresses), let entry = addresses.first,
              let terminal = addresses.last else {
            throw MacIRConcreteEvaluator.Failure.harness("missing original source groups")
        }
        func copy(_ predecessor: MacIRPhiPredecessor, at target: UInt64,
                  evaluator: inout MacIRConcreteEvaluator) throws {
            // Snapshot ALL sources before writing ANY destination. In particular,
            // version0 entry registers cannot be reread after another phi writes.
            var snapshots: [(MacIRValue, MacIRConcreteEvaluator.Scalar)] = []
            for phi in function.phis where phi.blockAddress == target {
                let incoming = phi.incoming.filter { $0.predecessor == predecessor }
                guard incoming.count == 1, let value = incoming.first?.value else {
                    throw MacIRConcreteEvaluator.Failure.harness("not one exact typed incoming edge")
                }
                if phi.cell == 97 {
                    guard memoryEpochValues.contains(phi.destination), memoryEpochValues.contains(value) else {
                        throw MacIRConcreteEvaluator.Failure.harness("unproved memory-epoch edge")
                    }
                    continue // No numeric read/write of an SSA memory token.
                }
                snapshots.append((phi.destination, try evaluator.evaluate(value)))
            }
            guard !snapshots.isEmpty else {
                throw MacIRConcreteEvaluator.Failure.harness("expected entry-loop scalar phis")
            }
            for (destination, value) in snapshots { try evaluator.write(destination, value) }
        }
        try copy(.functionEntry, at: entry, evaluator: &evaluator)
        let initializations = 1
        var pc = entry, backedges = 0
        for _ in 0..<64 {
            guard let instructions = groups[pc], let index = addresses.firstIndex(of: pc) else {
                throw MacIRConcreteEvaluator.Failure.harness("execution left original source groups")
            }
            var branchTarget: UInt64?, sawBranch = false, sawReturn = false
            for instruction in instructions {
                switch instruction.operation {
                case let .assign(destination, source):
                    let value = try evaluator.evaluate(source)
                    try evaluator.write(destination, value)
                case let .binary(destination, op, left, right):
                    let value = try evaluator.evaluate(.binaryExpression(op: op, left: left, right: right))
                    try evaluator.write(destination, value)
                case let .load(destination, address):
                    let effective = try evaluator.evaluate(address).bits
                    try loadFixtureMemory(into: destination, at: effective,
                        access: instruction.memoryAccess, evaluator: &evaluator)
                case let .store(source, address):
                    let effective = try evaluator.evaluate(address).bits
                    let value = try evaluator.evaluate(source).bits
                    try storeFixtureMemory(value, at: effective,
                        access: instruction.memoryAccess, evaluator: &evaluator)
                case let .loadWriteback(destination, baseDestination, baseSource, delta, preIndex):
                    let base = try evaluator.evaluate(baseSource).bits
                    let updated = base &+ UInt64(bitPattern: delta)
                    try loadFixtureMemory(into: destination, at: preIndex ? updated : base,
                        access: instruction.memoryAccess, evaluator: &evaluator)
                    try evaluator.write(baseDestination, .int(updated, width: 64, signed: false))
                case let .storeWriteback(source, baseDestination, baseSource, delta, preIndex):
                    let base = try evaluator.evaluate(baseSource).bits
                    let value = try evaluator.evaluate(source).bits
                    let updated = base &+ UInt64(bitPattern: delta)
                    try storeFixtureMemory(value, at: preIndex ? updated : base,
                        access: instruction.memoryAccess, evaluator: &evaluator)
                    try evaluator.write(baseDestination, .int(updated, width: 64, signed: false))
                case let .conditionalBranch(condition, left, right, target):
                    guard !sawBranch, condition == "!=", index == addresses.count - 2 else {
                        throw MacIRConcreteEvaluator.Failure.harness("outside focused explicit NE branch")
                    }
                    sawBranch = true
                    let lhs = try evaluator.evaluate(left), rhs = try evaluator.evaluate(right)
                    let destination = try evaluator.evaluate(target).bits
                    guard destination == entry else {
                        throw MacIRConcreteEvaluator.Failure.harness("branch does not target original entry")
                    }
                    if try evaluator.compare(condition, lhs, rhs) { branchTarget = destination }
                case .returnValue:
                    guard pc == terminal, !sawReturn else {
                        throw MacIRConcreteEvaluator.Failure.harness("unexpected return terminator")
                    }
                    sawReturn = true // Stops interpretation, grants no return-contract authority.
                case .intrinsic(nil, "nop", let arguments) where arguments.isEmpty:
                    break
                case .intrinsic(nil, "compare", let arguments) where arguments.count == 2:
                    // Lifted conditionalBranch carries its actual compared values.
                    for argument in arguments { _ = try evaluator.evaluate(argument) }
                default:
                    throw MacIRConcreteEvaluator.Failure.unsupported("outside focused emitted scalar operations")
                }
            }
            if sawReturn { return (evaluator.state, initializations, backedges) }
            if let target = branchTarget {
                try copy(.machine(pc), at: target, evaluator: &evaluator)
                backedges += 1
                pc = target
            } else {
                guard index + 1 < addresses.count,
                      index != addresses.count - 2 || sawBranch else {
                    throw MacIRConcreteEvaluator.Failure.harness("missing explicit branch or return")
                }
                pc = addresses[index + 1]
            }
        }
        throw MacIRConcreteEvaluator.Failure.harness("focused fixture exceeded 64 source groups")
    }

    func testLiteralAdditionInitializesOnceAndPreservesUpperBitsInBothRequestedModes() throws {
        for enabled in [false, true] {
            let function = build(addition, ssa: enabled)
            if !enabled {
                XCTAssertFalse(function.ssaEnabled)
                XCTAssertNil(function.ssaInfo)
                XCTAssertNil(ScalarCFGStatePlan.admit(addition, hasExternalFacts: false))
                var narrowCountRows = addition
                narrowCountRows[1] = row(0x1004, "42 04 00 71", "subs", "w2, w2, #1")
                let narrowCount = build(narrowCountRows, ssa: enabled)
                XCTAssertFalse(narrowCount.ssaEnabled)
                XCTAssertNil(narrowCount.ssaInfo)
                continue // Deliberate legacy refusal, NOT a numeric success prediction.
            }
            let two = try interpret(function, x0: 5, x1: 3, count: 2)
            XCTAssertEqual(two.state.x[0], 11)
            XCTAssertEqual(two.initializations, 1)
            XCTAssertEqual(two.backedges, 1)
            let three = try interpret(function, x0: 5, x1: 3, count: 3)
            XCTAssertEqual(three.state.x[0], 14)
            XCTAssertEqual(three.initializations, 1)
            XCTAssertEqual(three.backedges, 2)
            let high = try interpret(function, x0: 0x100000005, x1: 3, count: 2)
            XCTAssertEqual(high.state.x[0], 0x10000000b)
            var narrowCountRows = addition
            narrowCountRows[1] = row(0x1004, "42 04 00 71", "subs", "w2, w2, #1")
            let narrowCount = build(narrowCountRows, ssa: enabled)
            let cleared = try interpret(narrowCount, x0: 5, x1: 3, count: 0x100000002)
            XCTAssertEqual(cleared.state.x[0], 11)
            XCTAssertEqual(cleared.state.x[2], 0, "W decrement must clear architectural upper bits")
            XCTAssertEqual(cleared.backedges, 1)
        }
    }

    func testLiteralSwapUsesParallelBackedgeCopiesInBothRequestedModes() throws {
        for enabled in [false, true] {
            let function = build(swap, ssa: enabled)
            if !enabled {
                XCTAssertFalse(function.ssaEnabled)
                XCTAssertNil(function.ssaInfo)
                XCTAssertNil(ScalarCFGStatePlan.admit(swap, hasExternalFacts: false))
                continue // Existing lexical refusal remains unchanged.
            }
            let result = try interpret(function, x0: 1, x1: 2, count: 3)
            XCTAssertEqual(result.state.x[0], 2)
            XCTAssertEqual(result.state.x[1], 1)
            XCTAssertEqual(result.initializations, 1)
            XCTAssertEqual(result.backedges, 2)
        }
    }

    func testLiteralAdditionAndSwapPreserveOriginalRowsAndEntryDefinitionsInBothModes() throws {
        for rows in [addition, swap] {
            for enabled in [false, true] {
                let function = build(rows, ssa: enabled)
                XCTAssertEqual(function.ssaEnabled, enabled)
                XCTAssertEqual(function.startAddress, 0x1000)
                XCTAssertEqual(function.endAddress, rows.last?.address.addressAfter())
                XCTAssertEqual(Set(function.instructions.map { $0.source.address }), Set(rows.map(\.address)))
                XCTAssertFalse(function.instructions.contains { $0.source.syntheticPhiEdge != nil })
                if !enabled {
                    // Legacy scalar CFG entry-loop admission intentionally remains refused.
                    XCTAssertNil(ScalarCFGStatePlan.admit(rows, hasExternalFacts: false))
                    XCTAssertNil(function.ssaInfo)
                    XCTAssertFalse(function.phis.contains { $0.incoming.contains { $0.predecessor == .functionEntry } })
                    continue
                }
                XCTAssertTrue(MacIRBuilder.hasBoundedEntryLoopProof(function))
                let info = try XCTUnwrap(function.ssaInfo)
                XCTAssertEqual(info.sourceAddresses, rows.map(\.address))
                let entries = info.plan.definitions.filter { $0.origin == .entry }
                XCTAssertEqual(entries.count, 98)
                XCTAssertEqual(Set(entries.map(\.cell)), Set(0..<98))
                XCTAssertFalse(info.plan.phis.isEmpty)
                for phi in info.plan.phis {
                    XCTAssertEqual(phi.incoming.count, 2)
                    guard phi.incoming.count == 2 else { continue }
                    XCTAssertEqual(phi.incoming[0].predecessor, .functionEntry)
                    XCTAssertEqual(phi.incoming[1].machineAddress, rows[rows.count - 2].address)
                    let initial = info.plan.definitions[phi.incoming[0].definition]
                    XCTAssertEqual(initial.origin, .entry)
                    XCTAssertEqual(initial.cell, phi.cell)
                }
                for (index, writes) in info.plan.rowWriteBindings.enumerated() {
                    for (cell, id) in writes {
                        XCTAssertEqual(info.plan.definitions[id].origin, .instruction(rows[index].address))
                        XCTAssertEqual(info.plan.definitions[id].cell, cell)
                    }
                }
            }
        }
    }

    func testByteTextSPCallAndExtraBlockRemainRefusedInBothModes() {
        let replacements = [
            row(0x1000, "00 00 01 8b", "add", "x0, x0, x3"), // bytes still name x1
            row(0x1000, "00 04 00 91", "add", "x0, x0, #1"), // outside closed opcode class
            row(0x1000, "e0 03 00 91", "mov", "x0, sp"),
            row(0x1000, "00 00 00 94", "bl", "0x1000"),
            row(0x1000, "20 00 00 b4", "cbz", "x0, 0x1004") // creates another block
        ]
        for replacement in replacements {
            var rows = addition
            rows[0] = replacement
            for enabled in [false, true] {
                let function = build(rows, ssa: enabled)
                XCTAssertFalse(function.ssaEnabled)
                XCTAssertNil(function.ssaInfo)
                XCTAssertFalse(MacIRBuilder.hasBoundedEntryLoopProof(function))
                XCTAssertFalse(function.phis.contains { $0.incoming.contains { $0.predecessor == .functionEntry } })
            }
        }
    }

    func testEntryProofRejectsChangedWidthAndWrongInitialValue() throws {
        let baseline = try admitted(addition)
        let index = try XCTUnwrap(baseline.phis.firstIndex { $0.cell == 0 })
        XCTAssertEqual(baseline.phis[index].bitWidth, 64)
        var narrow = baseline
        narrow.phis[index].bitWidth = 32
        narrow.ssaOriginalPhis = narrow.phis // Exercise width proof, not only retained-snapshot equality.
        XCTAssertFalse(MacIRBuilder.hasBoundedEntryLoopProof(narrow))
        var wrongInitial = baseline
        wrongInitial.phis[index].incoming[0].value = .immediate(123)
        wrongInitial.ssaOriginalPhis = wrongInitial.phis
        XCTAssertFalse(MacIRBuilder.hasBoundedEntryLoopProof(wrongInitial))
        var unknownInitial = baseline
        unknownInitial.phis[index].incoming[0].value = .unknown("unavailable_x0")
        unknownInitial.ssaOriginalPhis = unknownInitial.phis
        XCTAssertFalse(MacIRBuilder.hasBoundedEntryLoopProof(unknownInitial))
    }

    func testEntryProofRejectsExtraOriginalSourceAndSwappedEntryBackedge() throws {
        let baseline = try admitted(swap)
        var extra = baseline
        extra.instructions.append(.init(source: .init(address: 0x2000, byteText: "e0 03 01 aa",
            mnemonic: "mov", operands: "x0, x1"),
            operation: .assign(destination: .register(name: "x0", version: 99), source: .immediate(7))))
        extra.ssaOriginalInstructions = extra.instructions
        XCTAssertFalse(MacIRBuilder.hasBoundedEntryLoopProof(extra))
        var swapped = baseline
        let index = try XCTUnwrap(swapped.phis.firstIndex { $0.cell == 0 })
        swapped.phis[index].incoming.swapAt(0, 1)
        swapped.ssaOriginalPhis = swapped.phis
        XCTAssertFalse(MacIRBuilder.hasBoundedEntryLoopProof(swapped))
    }
    func testTypedMemoryDisagreementCannotUseByteTextAgreementInEitherMode() {
        let memory = InstructionOperands.Memory(base: .init(index: 1, width: 64),
            displacement: 1, indexing: .postIndex, writeback: true)
        let data = InstructionOperands.Operand.register(.init(index: 8, width: 32))
        let badSidecars: [InstructionOperands] = [
            .init(coverage: .complete, operands: [data, .memory(.init(base: .init(index: 2, width: 64),
                displacement: 1, indexing: .postIndex, writeback: true))]),
            .init(coverage: .complete, operands: [data, .memory(memory)],
                semantics: .init(memoryAccessWidth: 64, memoryAccess: .read)),
            .init(coverage: .complete, operands: [data, .memory(memory), .register(.init(index: 3, width: 64))],
                presentation: .init(omittedOperandIndices: [2])),
            .init(coverage: .complete, operands: [data, .memory(.init(base: .init(index: 1, width: 64),
                displacement: 1, indexing: .postIndex, writeback: false))])
        ]
        for sidecar in badSidecars {
            let rows = [
                row(0x1000, "28 14 40 38", "ldrb", "w8, [x1], #1", structured: sidecar),
                row(0x1004, "48 14 00 38", "strb", "w8, [x2], #1"),
                row(0x1008, "63 04 00 71", "subs", "w3, w3, #1"),
                row(0x100c, "a1 ff ff 54", "b.ne", "0x1000"),
                row(0x1010, "c0 03 5f d6", "ret")
            ]
            for enabled in [false, true] {
                let function = build(rows, ssa: enabled)
                XCTAssertFalse(function.ssaEnabled)
                XCTAssertNil(function.ssaInfo)
                XCTAssertFalse(MacIRBuilder.hasBoundedEntryLoopProof(function))
            }
        }
    }

    func testEntryCertificateRejectsChangedOperationUnderUnchangedMachineSource() throws {
        var changed = try admitted(addition)
        let index = try XCTUnwrap(changed.instructions.firstIndex {
            if case .binary(_, "+", _, _) = $0.operation { return true }
            return false
        })
        guard case let .binary(destination, _, left, right) = changed.instructions[index].operation else {
            return XCTFail("expected actual emitted addition")
        }
        changed.instructions[index].operation = .binary(destination: destination, op: "-", left: left, right: right)
        changed.ssaOriginalInstructions = changed.instructions
        XCTAssertFalse(MacIRBuilder.hasBoundedEntryLoopProof(changed))
    }

    func testPrintedEntryCopiesPrecedeEveryMachineBodyAndLoopTargetInBothModes() throws {
        for rows in [addition, swap] {
            for enabled in [false, true] {
                let function = build(rows, ssa: enabled)
                for structured in [false, true] {
                    let document = PseudocodePrinter(options: .init(structureControlFlow: structured,
                        deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
                        .print(function: function)
                    let initialLines = document.lines.enumerated().filter {
                        $0.element.kind == .instruction && $0.element.syntheticPhiEdge?.predecessor == .functionEntry
                    }
                    if !enabled {
                        XCTAssertTrue(initialLines.isEmpty)
                        XCTAssertNil(function.ssaInfo)
                        continue
                    }
                    XCTAssertTrue(MacIRBuilder.hasBoundedEntryLoopProof(function))
                    XCTAssertFalse(document.text.contains("__unavailable_cfg_phi"))
                    if structured {
                        let cfg = try XCTUnwrap(function.cfg?.compatibilityCFG)
                        let plan = try XCTUnwrap(EntryLoopNativeValuePlan.prove(function: function,
                            cfg: cfg, attemptLexical: false))
                        XCTAssertEqual(plan.declarations.count, function.phis.count)
                        XCTAssertTrue(initialLines.isEmpty)
                        XCTAssertTrue(document.text.contains("do {"))
                        XCTAssertFalse(document.text.contains("goto "))
                        XCTAssertFalse(document.text.contains("__entry_phi"))
                        XCTAssertFalse(document.text.contains("__edge_"))
                        XCTAssertTrue(plan.declarations.allSatisfy { $0.type == "uint64_t" })
                        continue
                    }
                    let firstMachine = try XCTUnwrap(document.lines.firstIndex { $0.sourceAddress != nil && $0.kind == .instruction })
                    func assignment(_ text: String) throws -> (destination: String, source: [String]) {
                        let tokens = try OrdinaryC.lex(text).map(\.text)
                        guard let equal = tokens.firstIndex(of: "="), equal > 0, tokens.last == ";" else {
                            throw MacIRConcreteEvaluator.Failure.harness("printed edge copy is not an assignment")
                        }
                        return (tokens[equal - 1], Array(tokens[(equal + 1)..<(tokens.count - 1)]))
                    }
                    var snapshotPositions: [Int] = [], writePositions: [Int] = []
                    for phi in function.phis {
                        let identity = MacIRPhiEdgeIdentity(blockAddress: phi.blockAddress,
                            predecessor: .functionEntry, destination: phi.destination)
                        let copies = initialLines.filter { $0.element.syntheticPhiEdge == identity }
                        XCTAssertEqual(copies.count, 2, "exactly one snapshot and one initial destination write")
                        guard copies.count == 2 else { continue }
                        let snapshot = try assignment(copies[0].element.text)
                        let write = try assignment(copies[1].element.text)
                        XCTAssertNotEqual(snapshot.destination, write.destination)
                        XCTAssertEqual(write.source, [snapshot.destination])
                        for copy in copies {
                            XCTAssertNil(copy.element.sourceAddress)
                            XCTAssertLessThan(copy.offset, firstMachine)
                        }
                        snapshotPositions.append(copies[0].offset)
                        writePositions.append(copies[1].offset)
                        let backedge = MacIRPhiEdgeIdentity(blockAddress: phi.blockAddress,
                            predecessor: .machine(rows[rows.count - 2].address), destination: phi.destination)
                        XCTAssertNotEqual(backedge, identity)
                        let machineCopies = document.lines.enumerated().filter {
                            $0.element.kind == .instruction && $0.element.syntheticPhiEdge == backedge
                                && $0.element.text.contains(" = ")
                        }
                        XCTAssertFalse(machineCopies.isEmpty, "original backedge retains its own typed assignment")
                        for copy in machineCopies {
                            XCTAssertNil(copy.element.sourceAddress)
                            XCTAssertGreaterThan(copy.offset, firstMachine)
                            XCTAssertEqual(copy.element.syntheticPhiEdge?.blockAddress, function.startAddress)
                        }
                    }
                    XCTAssertEqual(initialLines.count, function.phis.count * 2)
                    let lastSnapshot = try XCTUnwrap(snapshotPositions.max())
                    let firstWrite = try XCTUnwrap(writePositions.min())
                    let lastWrite = try XCTUnwrap(writePositions.max())
                    XCTAssertLessThan(lastSnapshot, firstWrite, "all initial sources precede every initial destination write")
                    // Every textual target/loop body begins after initialization;
                    // no backedge can target or repeat the one-time entry schedule.
                    for (index, line) in document.lines.enumerated() where line.kind == .instruction {
                        let text = line.text.trimmingCharacters(in: .whitespaces)
                        if text.hasSuffix(":") || text.hasPrefix("while (") || text == "do {" {
                            XCTAssertGreaterThan(index, lastWrite)
                        }
                    }
                    if !structured {
                        XCTAssertTrue(document.lines.contains { $0.text.trimmingCharacters(in: .whitespaces) == "L_1000:" })
                        XCTAssertTrue(document.lines.contains { $0.text.contains("goto L_1000;") })
                    }
                }
            }
        }
    }


    // These test-only helpers consume actual IR addresses, writeback operands and
    // retained memory widths. They do not decode words or infer instruction semantics.
    private func loadFixtureMemory(into destination: MacIRValue, at address: UInt64,
                                   access: MacIRMemoryAccess?, evaluator: inout MacIRConcreteEvaluator) throws {
        guard let access, [1, 2, 4].contains(access.byteWidth), access.extensionKind != .sign,
              case let .register(name, _) = destination, name.hasPrefix("w") else {
            throw MacIRConcreteEvaluator.Failure.harness("outside focused W memory load")
        }
        var bits: UInt64 = 0
        for offset in 0..<access.byteWidth {
            bits |= UInt64(evaluator.state.byte(at: address &+ UInt64(offset))) << UInt64(offset * 8)
        }
        try evaluator.write(destination, .int(bits, width: 32, signed: false))
    }

    private func storeFixtureMemory(_ bits: UInt64, at address: UInt64,
                                    access: MacIRMemoryAccess?, evaluator: inout MacIRConcreteEvaluator) throws {
        guard let access, [1, 2, 4].contains(access.byteWidth), access.extensionKind == .none else {
            throw MacIRConcreteEvaluator.Failure.harness("outside focused scalar memory store")
        }
        for offset in 0..<access.byteWidth {
            evaluator.state.setByte(UInt8(truncatingIfNeeded: bits >> UInt64(offset * 8)),
                                    at: address &+ UInt64(offset))
        }
    }

    private enum CapturedLoop: Equatable { case downscale, upscale, noscaleByte, noscaleHalf }

    private func capturedRows(_ start: UInt64, _ kind: CapturedLoop) -> [InstructionRow] {
        let scaled = kind == .downscale || kind == .upscale
        let sourceWidth = kind == .downscale ? 1 : 4
        let storeWidth = kind == .noscaleHalf ? 2 : 1
        func memory(_ mnemonic: String, data: Int, base: Int, width: Int,
                    displacement: Int64, post: Bool, load: Bool) -> InstructionOperands {
            .init(coverage: .complete, opcodeClass: mnemonic,
                operands: [.register(.init(index: data, width: 32)),
                    .memory(.init(base: .init(index: base, width: 64), displacement: displacement,
                        indexing: post ? .postIndex : .offset, writeback: post))],
                semantics: .init(memoryAccessWidth: width * 8, memoryAccess: load ? .read : .write))
        }
        let load = sourceWidth == 1 ? "ldrb" : "ldr"
        var rows = [row(start, sourceWidth == 1 ? "28 14 40 38" : "28 44 40 b8",
            load, "w8, [x1], #\(sourceWidth)", structured: memory(load, data: 8, base: 1,
                width: sourceWidth, displacement: Int64(sourceWidth), post: true, load: true))]
        if scaled {
            let offset: Int64 = kind == .downscale ? 0x1d8 : 0x220
            rows.append(row(start + 4, kind == .downscale ? "09 d8 41 b9" : "09 20 42 b9",
                "ldr", "w9, [x0, #0x\(String(offset, radix: 16))]", structured: memory("ldr", data: 9, base: 0,
                    width: 4, displacement: offset, post: false, load: true)))
            let shift = kind == .downscale ? "lsr" : "lsl"
            rows.append(row(start + 8, kind == .downscale ? "08 25 c9 1a" : "08 21 c9 1a",
                shift, "w8, w8, w9", structured: .unavailable(mnemonic: shift, operands: "w8, w8, w9")))
        }
        let storeAddress = start + UInt64(rows.count * 4)
        let store = storeWidth == 1 ? "strb" : "strh"
        rows.append(row(storeAddress, storeWidth == 1 ? "48 14 00 38" : "48 24 00 78",
            store, "w8, [x2], #\(storeWidth)", structured: memory(store, data: 8, base: 2,
                width: storeWidth, displacement: Int64(storeWidth), post: true, load: false)))
        rows.append(row(storeAddress + 4, "63 04 00 71", "subs", "w3, w3, #1",
            structured: .init(coverage: .complete, opcodeClass: "subs", operands: [
                .register(.init(index: 3, width: 32)), .register(.init(index: 3, width: 32)),
                .immediate(.init(.unsigned(1), encodedWidth: 12, encodedValue: 1, encodedShift: 0))],
                presentation: .init(mnemonic: "subs"))))
        let branchAddress = storeAddress + 8
        let symbol = kind == .downscale ? "_simple_downscale" : kind == .upscale ? "_simple_upscale" : "_noscale"
        rows.append(row(branchAddress, scaled ? "61 ff ff 54" : "a1 ff ff 54", "b.ne", symbol,
            structured: .init(coverage: .complete, opcodeClass: "b.cond", operands: [
                .pcRelative(.init(baseAddress: branchAddress, displacement: scaled ? -20 : -12)), .condition(.ne)],
                presentation: .init(mnemonic: "b", conditionSuffixOperandIndex: 1))))
        rows.append(row(branchAddress + 4, "c0 03 5f d6", "ret", structured: .unavailable(mnemonic: "ret", operands: "")))
        return rows
    }

    private func assertCapturedLoop(_ start: UInt64, _ kind: CapturedLoop,
                                    input: [UInt8], expected: [UInt8], sourceEnd: UInt64, destinationEnd: UInt64) throws {
        let rows = capturedRows(start, kind)
        let sources = rows.map { MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
            mnemonic: $0.mnemonic, operands: $0.operands, comment: $0.comment, structuredOperands: $0.structuredOperands) }
        for enabled in [false, true] {
            let function = build(rows, ssa: enabled)
            XCTAssertEqual(function.ssaEnabled, enabled)
            XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"),
                "Entry-loop transport grants no return-contract authority")
            XCTAssertEqual(Set(function.instructions.map(\.source)), Set(sources), "Original symbolic sources are not scratch CFG rows")
            let branch = try XCTUnwrap(function.instructions.first { $0.source.address == rows[rows.count - 2].address })
            guard case let .conditionalBranch(_, _, _, target) = branch.operation else { return XCTFail("real conditional operation") }
            if !enabled {
                XCTAssertNil(function.ssaInfo)
                XCTAssertFalse(MacIRBuilder.hasBoundedEntryLoopProof(function))
                XCTAssertEqual(target, .symbol(rows[rows.count - 2].operands), "Legacy symbol lowering is unchanged")
                if let cfg = function.cfg?.compatibilityCFG {
                    XCTAssertNil(EntryLoopNativeValuePlan.prove(function: function, cfg: cfg, attemptLexical: false))
                }
                XCTAssertFalse(PseudocodePrinter().print(function: function).text.contains("do {"),
                    "Symbol display is not numeric legacy branch authority")
                continue
            }
            XCTAssertTrue(MacIRBuilder.hasBoundedEntryLoopProof(function))
            XCTAssertFalse(function.refusals.contains { $0.detail == "entry block has an in-graph predecessor" })
            XCTAssertEqual(target, .immediate(Int64(start)))
            XCTAssertEqual(function.cfg?.blocks.count, 2)
            XCTAssertTrue(function.phis.contains { $0.incoming.contains { $0.predecessor == .functionEntry } })
            var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
            state.x[0] = 0x10000; state.x[1] = 0x20000; state.x[2] = 0x30000; state.x[3] = 0x100000002
            for (offset, byte) in input.enumerated() { state.setByte(byte, at: 0x20000 + UInt64(offset)) }
            state.setByte(1, at: kind == .downscale ? 0x101d8 : 0x10220)
            let result = try interpret(function, x0: 0, x1: 0, count: 0, initialState: state)
            XCTAssertEqual(expected.indices.map { result.state.byte(at: 0x30000 + UInt64($0)) }, expected)
            XCTAssertEqual(result.state.x[1], sourceEnd)
            XCTAssertEqual(result.state.x[2], destinationEnd)
            XCTAssertEqual(result.state.x[3], 0, "W decrement clears high bits")
            XCTAssertEqual(result.initializations, 1)
            XCTAssertEqual(result.backedges, 1)
        }
    }

    func testCapturedSymbolicDownscaleWithDecoderSidecarsInBothModes() throws {
        try assertCapturedLoop(0x17c88, .downscale, input: [0xff, 0x80], expected: [0x7f, 0x40],
            sourceEnd: 0x20002, destinationEnd: 0x30002)
    }

    func testCapturedSymbolicUpscaleWithDecoderSidecarsInBothModes() throws {
        try assertCapturedLoop(0x30134, .upscale, input: [0x81, 0, 0, 0, 0x02, 0x01, 0, 0], expected: [0x02, 0x04],
            sourceEnd: 0x20008, destinationEnd: 0x30002)
    }

    func testAllThreeCapturedSymbolicNoscaleBodiesWithDecoderSidecarsInBothModes() throws {
        try assertCapturedLoop(0x30150, .noscaleByte, input: [0x78, 0x56, 0x34, 0x12, 0xef, 0xcd, 0xab, 0x90],
            expected: [0x78, 0xef], sourceEnd: 0x20008, destinationEnd: 0x30002)
        for start in [UInt64(0x30630), 0x30b10] {
            try assertCapturedLoop(start, .noscaleHalf, input: [0x78, 0x56, 0x34, 0x12, 0xef, 0xcd, 0xab, 0x90],
                expected: [0x78, 0x56, 0xef, 0xcd], sourceEnd: 0x20008, destinationEnd: 0x30004)
        }
    }

    func testCapturedLoopRejectsDisagreeingConditionalAndUnavailableMetadataInBothModes() {
        let original = capturedRows(0x17c88, .downscale)
        let branch = original[5]
        var variants: [[InstructionRow]] = []
        for (bytes, text, sidecar) in [
            (branch.bytes, "0x17c8c", branch.structuredOperands),
            ("41 ff ff 54", branch.operands, branch.structuredOperands),
            (branch.bytes, branch.operands, InstructionOperands(coverage: .complete, opcodeClass: "b.cond",
                operands: [.pcRelative(.init(baseAddress: branch.address, displacement: -20)), .condition(.eq)],
                presentation: .init(mnemonic: "b", conditionSuffixOperandIndex: 1))),
            (branch.bytes, branch.operands, InstructionOperands(coverage: .complete, opcodeClass: "b.cond",
                operands: [.pcRelative(.init(baseAddress: branch.address, displacement: -16)), .condition(.ne)],
                presentation: .init(mnemonic: "b", conditionSuffixOperandIndex: 1)))
        ] {
            var changed = original
            changed[5] = row(branch.address, bytes, "b.ne", text, structured: sidecar)
            variants.append(changed)
        }
        // Signed radix lexemes are not byte text, even when UInt8 could parse zero.
        for bytes in ["63 04 -0 71", "63 04 +0 71", "63 04 +f 71"] {
            var malformedBytes = original
            malformedBytes[4] = row(original[4].address, bytes, original[4].mnemonic,
                original[4].operands, structured: original[4].structuredOperands)
            variants.append(malformedBytes)
        }
        var partial = original
        partial[2] = row(original[2].address, original[2].bytes, "lsr", "w8, w8, w9",
            structured: .init(coverage: .partial, operands: [.opaque("w8, w8, w9")]))
        variants.append(partial)
        var forgedUnavailable = original
        forgedUnavailable[6] = row(original[6].address, original[6].bytes, "ret",
            structured: .init(coverage: .unavailable, operands: [.opaque("")],
                presentation: .init(mnemonic: "ret"), semantics: .init(memoryAccessWidth: 32, memoryAccess: .read),
                legacyText: .init(mnemonic: "ret", operands: "")))
        variants.append(forgedUnavailable)
        var badMemory = original
        badMemory[0] = row(original[0].address, original[0].bytes, "ldrb", "w8, [x1], #1",
            structured: .init(coverage: .complete, opcodeClass: "ldrb", operands: [
                .register(.init(index: 8, width: 32)),
                .memory(.init(base: .init(index: 1, width: 64), displacement: 1, indexing: .postIndex, writeback: true))],
                semantics: .init(memoryAccessWidth: 32, memoryAccess: .read)))
        variants.append(badMemory)
        var extraBranch = original
        extraBranch[2] = row(original[2].address, "c1 ff ff 54", "b.ne", "_simple_downscale")
        variants.append(extraBranch)
        for rows in variants {
            for enabled in [false, true] {
                let function = build(rows, ssa: enabled)
                XCTAssertFalse(MacIRBuilder.hasBoundedEntryLoopProof(function))
                XCTAssertFalse(function.phis.contains { $0.incoming.contains { $0.predecessor == .functionEntry } })
            }
        }
    }

    /// The export seam symbolizes calls only. Use the SAME canonical numeric
    /// branch display in both modes; symbolic overlay is a separate SSA control.
    private func canonicalCapturedRows(_ start: UInt64, _ kind: CapturedLoop) -> [InstructionRow] {
        var rows = capturedRows(start, kind)
        rows[rows.count - 2].operands = String(format: "0x%016llx", start)
        return rows
    }

    private func assertStructuredCapturedLoop(_ start: UInt64, _ kind: CapturedLoop,
                                             symbolicSSAOnly: Bool = false) throws {
        let rows = symbolicSSAOnly ? capturedRows(start, kind) : canonicalCapturedRows(start, kind)
        let scaled = kind == .downscale || kind == .upscale
        for enabled in symbolicSSAOnly ? [true] : [false, true] {
            let function = build(rows, ssa: enabled)
            XCTAssertEqual(function.ssaEnabled, enabled)
            if enabled {
                XCTAssertFalse(function.refusals.contains { $0.detail == "entry block has an in-graph predecessor" })
            }
            // Legacy reconciliation remains authoritative for its own route.
            let proofFunction = enabled ? function : (RegionalLexicalProof(reconciled: function)?.function ?? function)
            let cfg = try XCTUnwrap(proofFunction.cfg?.compatibilityCFG)
            let plan = try XCTUnwrap(EntryLoopNativeValuePlan.prove(function: proofFunction,
                cfg: cfg, attemptLexical: false))
            XCTAssertEqual(plan.declarations.count, 3)
            XCTAssertEqual(plan.recurrenceCertificates.map(\.register), [1, 2, 3])
            XCTAssertEqual(plan.declarations.map(\.type), ["uint64_t", "uint64_t", "uint32_t"])
            XCTAssertEqual(plan.groups.map(\.count), scaled ? [2, 1, 1, 2, 1] : [2, 2, 1])
            XCTAssertEqual(plan.condition, "!=")
            XCTAssertEqual(plan.conditionValue, .unary(op: "(uint32_t)", value: .register(name: "w3", version: 1)))
            let document = PseudocodePrinter(options: .init(structureControlFlow: true,
                deadCodeElimination: false, nopElision: false, functionSizeGate: 1024)).print(function: function)
            XCTAssertNil(document.structureFallback)
            let region = try XCTUnwrap(document.regionTree)
            XCTAssertTrue(region.children.contains { $0.kind == .doWhileLoop })
            XCTAssertTrue(document.text.contains("do {"))
            XCTAssertTrue(document.text.contains("} while ((uint32_t)(w3_1) != 0x0);"))
            XCTAssertFalse(document.text.contains("goto "))
            XCTAssertFalse(document.lines.contains { $0.text.trimmingCharacters(in: .whitespaces).hasSuffix(":") })
            for marker in ["__entry_phi", "__edge_", "__unavailable_cfg_phi", "    int64_t x1_", "    int32_t w3_"] {
                XCTAssertFalse(document.text.contains(marker), marker)
            }
            let inputs = scaled ? ["arg1", "arg2", "arg3"] : ["in_x1", "in_x2", "in_w3"]
            XCTAssertTrue(document.text.contains("uint64_t x1_1 = (uint64_t)(\(inputs[0]));"))
            XCTAssertTrue(document.text.contains("uint64_t x2_1 = (uint64_t)(\(inputs[1]));"))
            XCTAssertTrue(document.text.contains("uint32_t w3_1 = (uint32_t)(\(inputs[2]));"))
            XCTAssertEqual(document.lines.count, scaled ? 16 : 14)
            for index in [0, rows.count - 4] {
                let effects = document.lines.filter { $0.sourceAddress == rows[index].address && $0.kind == .instruction }
                XCTAssertEqual(effects.count, 2, "Memory and writeback are separate ordered C statements")
                guard effects.count == 2 else { continue }
                XCTAssertTrue(effects[0].text.contains("*(uint"))
                XCTAssertTrue(effects[1].text.contains(index == 0 ? "x1_1 = " : "x2_1 = "))
                XCTAssertFalse(effects.contains { $0.text.contains(",") }, "No comma-tuple assignment")
                XCTAssertLessThan(effects[0].lineNumber, effects[1].lineNumber)
            }
            XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
            if enabled {
                XCTAssertTrue(MacIRBuilder.hasBoundedEntryLoopProof(function))
                XCTAssertEqual(function.phis.count, 4, "Original three scalar and memory-epoch phis remain")
                for (declaration, certificate) in zip(plan.declarations, plan.recurrenceCertificates) {
                    let phi = try XCTUnwrap(function.phis.first { $0.cell == certificate.register })
                    XCTAssertEqual(phi.incoming.map(\.predecessor), [.functionEntry, .machine(rows[rows.count - 2].address)])
                    XCTAssertEqual(declaration.initializer, EntryLoopCarryPlan.project(phi.incoming[0].value, phi.bitWidth))
                    XCTAssertEqual(declaration.storage, phi.incoming[1].value)
                    XCTAssertEqual(certificate.storage, declaration.storage)
                }
            }
        }
    }

    func testCanonicalDownscaleAndUpscaleStructureInBothModes() throws {
        try assertStructuredCapturedLoop(0x17c88, .downscale)
        try assertStructuredCapturedLoop(0x30134, .upscale)
    }

    func testAllThreeCanonicalNoscaleBodiesStructureInBothModes() throws {
        try assertStructuredCapturedLoop(0x30150, .noscaleByte)
        try assertStructuredCapturedLoop(0x30630, .noscaleHalf)
        try assertStructuredCapturedLoop(0x30b10, .noscaleHalf)
    }

    func testSealedSymbolicSSAOverlayUsesSameNativeLoopProof() throws {
        try assertStructuredCapturedLoop(0x17c88, .downscale, symbolicSSAOnly: true)
        try assertStructuredCapturedLoop(0x30134, .upscale, symbolicSSAOnly: true)
        try assertStructuredCapturedLoop(0x30150, .noscaleByte, symbolicSSAOnly: true)
        try assertStructuredCapturedLoop(0x30630, .noscaleHalf, symbolicSSAOnly: true)
        try assertStructuredCapturedLoop(0x30b10, .noscaleHalf, symbolicSSAOnly: true)
    }

    func testNativeEntryProjectionRejectsChangedPhiAndSourceAndSignedStorage() throws {
        let original = try admitted(canonicalCapturedRows(0x30150, .noscaleByte))
        let cfg = try XCTUnwrap(original.cfg?.compatibilityCFG)
        XCTAssertNotNil(EntryLoopNativeValuePlan.prove(function: original, cfg: cfg, attemptLexical: false))
        let index = try XCTUnwrap(original.phis.firstIndex { $0.cell == 1 })
        var wrongEntry = original
        wrongEntry.phis[index].incoming[0].value = .immediate(99)
        var wrongBackedge = original
        wrongBackedge.phis[index].incoming[1].value = .immediate(100)
        var wrongSource = original
        wrongSource.instructions[0].source.operands = "w8, [x1], #8"
        for changed in [wrongEntry, wrongBackedge, wrongSource] {
            XCTAssertFalse(MacIRBuilder.hasBoundedEntryLoopProof(changed))
            XCTAssertNil(EntryLoopNativeValuePlan.prove(function: changed, cfg: cfg, attemptLexical: false))
            XCTAssertFalse(PseudocodePrinter().print(function: changed).text.contains("do {"))
        }
        var signedStorage = original
        signedStorage.nameBindings.append(.init(target: .register(name: "x1", version: 1),
            name: "signed_carrier", type: "int64_t", kind: .registerTemporary))
        XCTAssertNil(EntryLoopNativeValuePlan.prove(function: signedStorage, cfg: cfg, attemptLexical: false))
        XCTAssertFalse(PseudocodePrinter().print(function: signedStorage).text.contains("do {"))
        // Independently exercise the unchanged native declared-type gate without
        // relying on seal invalidation: the legacy proof has no SSA certificate.
        let legacy = build(canonicalCapturedRows(0x30150, .noscaleByte), ssa: false)
        for function in [original, legacy] {
            let collision = PseudocodePrinter().print(function: function,
                registerNameOverrides: ["x1": "in_x2"])
            XCTAssertFalse(collision.text.contains("do {"), "A name collision cannot acquire a native loop")
        }
        var declared = RegionalLexicalProof(reconciled: legacy)?.function ?? legacy
        let legacyCFG = try XCTUnwrap(declared.cfg?.compatibilityCFG)
        XCTAssertNotNil(EntryLoopNativeValuePlan.prove(function: declared, cfg: legacyCFG, attemptLexical: false))
        declared.nameBindings.append(.init(target: .register(name: "x1", version: 1),
            name: "authored_signed_carrier", type: "int64_t", kind: .registerTemporary))
        XCTAssertNil(EntryLoopNativeValuePlan.prove(function: declared, cfg: legacyCFG, attemptLexical: false))
    }

}
