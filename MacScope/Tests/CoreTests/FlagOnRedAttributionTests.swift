import Foundation
import XCTest
@testable import MacScope

@MainActor
final class FlagOnRedAttributionTests: XCTestCase {
    // Stack-local read-only fence encloses setup, body and teardown. No shared
    // snapshot state is needed when suites or test instances execute in parallel.
    override func invokeTest() {
        let before = NSDictionary(dictionary:
            UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:])
        defer {
            let after = UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:]
            XCTAssertTrue(before.isEqual(to: after),
                          "Mode tests must not change the application preference domain")
        }
        super.invokeTest()
    }


    // Dynamic task scope restores on return/throw, with no global writes.
    private func withSSA<T>(_ enabled: Bool, _ body: () throws -> T) rethrows -> T {
        try MacIRConfiguration.$ssaOverride.withValue(enabled, operation: body)
    }

    private func loopWithSavedArgument(restoringArgument: Bool) throws -> FinalCallCarrierFixture.Rendered {
        // x19 and x20 preserve the entry root and second argument. Only the
        // positive restores x1 before each BLR; the negative replaces that one
        // instruction with NOP, preserving every address and control edge.
        let words: [UInt32] = [
            0xaa0003f3, // 1000: MOV x19,x0
            0xaa0103f4, // 1004: MOV x20,x1
            0xf9400269, // 1008: LDR x9,[x19]
            0xf9400128, // 100c: LDR x8,[x9]
            0xaa1303e0, // 1010: MOV x0,x19
            restoringArgument ? 0xaa1403e1 : 0xd503201f, // 1014: MOV x1,x20 / NOP
            0xd63f0100, // 1018: BLR x8
            0x35ffff61, // 101c: CBNZ w1,1008
            0x54000041, // 1020: B.NE 1028
            0xd65f03c0, // 1024: RET
            0x97fffff6  // 1028: BL 1000
        ]
        let value = try FinalCallCarrierFixture.render(words: words)
        XCTAssertTrue(value.function.ssaEnabled)
        XCTAssertEqual(value.decoded[7].branchTarget, 0x1008)
        XCTAssertEqual(value.decoded[8].branchTarget, 0x1028)
        XCTAssertEqual(value.decoded[10].branchTarget, 0x1000)
        return value
    }

    private func callback(_ value: FinalCallCarrierFixture.Rendered,
                          at address: UInt64) throws -> (MacIRCallFrame, MacIRValue?) {
        let instruction = try XCTUnwrap(value.function.instructions.first { $0.source.address == address })
        guard case let .call(frame, result) = instruction.operation else {
            XCTFail("Expected callback at \(String(address, radix: 16))")
            throw NSError(domain: "FlagOnRedAttributionTests", code: 1)
        }
        return (frame, result)
    }

    func testAttributionP01A() throws {
        try withSSA(true) {
            let value = try loopWithSavedArgument(restoringArgument: true)
            let (frame, result) = try callback(value, at: 0x1018)
            XCTAssertEqual(frame.typedIndirectSignature?.parameters.count, 2)
            XCTAssertEqual(frame.typedIndirectSignature?.returnType, "void")
            XCTAssertEqual(frame.arguments.canonicalPhysicalEntriesForAudit.count, 2)
            XCTAssertTrue(frame.arguments.canonicalPhysicalEntriesForAudit.contains {
                if case .gpr(index: 1, carrierWidth: _) = $0.location { return true }
                return false
            })
            XCTAssertNil(result)
        }
    }

    func testAttributionP01B() throws {
        try withSSA(true) {
            let value = try loopWithSavedArgument(restoringArgument: false)
            let (frame, result) = try callback(value, at: 0x1018)
            XCTAssertNil(frame.typedIndirectSignature)
            XCTAssertEqual(frame.arguments.canonicalPhysicalEntriesForAudit.count, 1)
            XCTAssertFalse(frame.arguments.canonicalPhysicalEntriesForAudit.contains {
                if case .gpr(index: 1, carrierWidth: _) = $0.location { return true }
                return false
            })
            XCTAssertNotNil(result)
        }
    }

    func testAttributionP02A() throws {
        try withSSA(true) {
            let value = try FinalCallCarrierFixture.render()
            XCTAssertTrue(value.function.ssaEnabled)
            try value.assertMissingSecondArgument()
        }
    }

    func testAttributionP02B() throws {
        try withSSA(false) {
            let value = try FinalCallCarrierFixture.render()
            XCTAssertFalse(value.function.ssaEnabled)
            try value.assertTyped(arity: 2)
        }
    }

    // Pure acceptance predicates let the symbolic mutants fail the oracle
    // without deliberately recording XCTest failures from assertion helpers.
    private func terminalProvenanceMatches(_ function: MacIRFunction) -> Bool {
        guard function.ssaEnabled, function.instructions.count > 55,
              function.returnType == "int32_t",
              case let .call(_, result?) = function.instructions[43].operation,
              case let .assign(constant, .immediate(1)) = function.instructions[52].operation else { return false }
        let phis = function.phis.filter {
            $0.blockAddress == 0x21850 && SSAPropertyAssertions.physicalCell($0.destination) == 0
        }
        guard phis.count == 1, let phi = phis.first, phi.bitWidth == 64,
              phi.incoming == [
                .init(predecessorAddress: function.instructions[45].source.address, value: result),
                .init(predecessorAddress: function.instructions[52].source.address,
                      value: .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: constant)))
              ], case let .returnValue(returned) = function.instructions[55].operation else { return false }
        let view = MacIRValue.unary(op: "(uint32_t)", value: phi.destination)
        return function.returnValue == view && returned == view
    }

    private func origins(_ initial: Int, info: MacIRSSAInfo) -> Set<SSAPropertyAssertions.CellZeroOrigin>? {
        var pending = [initial], visited: Set<Int> = []
        var result: Set<SSAPropertyAssertions.CellZeroOrigin> = []
        while let raw = pending.popLast() {
            let id = info.plan.canonicalID(raw)
            guard visited.insert(id).inserted else { continue }
            guard info.plan.definitions.indices.contains(id) else { return nil }
            let definition = info.plan.definitions[id]
            guard definition.cell == 0 else { return nil }
            switch definition.origin {
            case .entry:
                guard case .argument? = info.values[id] else { return nil }
                result.insert(.entryX0)
            case let .instruction(address): result.insert(.instruction(address))
            case .callResult:
                let rows = info.plan.rowWriteBindings.indices.filter {
                    info.plan.rowWriteBindings[$0][0].map(info.plan.canonicalID) == id
                }
                guard rows.count == 1, let row = rows.first,
                      info.sourceAddresses.indices.contains(row) else { return nil }
                result.insert(.callResult(info.sourceAddresses[row]))
            case .phi:
                let phis = info.plan.phis.filter { info.plan.canonicalID($0.destination) == id }
                guard phis.count == 1, let phi = phis.first else { return nil }
                pending.append(contentsOf: phi.incoming.map(\.definition))
            case .callClobber, .refusal: return nil
            }
        }
        return result
    }

    private func nonterminalOriginsMatch(_ function: MacIRFunction) -> Bool {
        guard function.ssaEnabled, let info = function.ssaInfo,
              let block = function.cfg?.blocks.first(where: { $0.startAddress == 0x3aea8 }) else { return false }
        let phis = info.plan.phis.filter { $0.block == block.index && $0.cell == 0 }
        guard phis.count == 1, let phi = phis.first,
              phi.incoming.map(\.machineAddress) == [0x3ae80, 0x3aea4],
              origins(phi.incoming[0].definition, info: info) == [.entryX0, .callResult(0x3ae6c)],
              origins(phi.incoming[1].definition, info: info) == [.callResult(0x3aea4)],
              let row = info.sourceAddresses.firstIndex(of: 0x3aea8),
              let read = info.plan.rowReadBindings[row][0],
              info.plan.canonicalID(read) == info.plan.canonicalID(phi.destination),
              origins(read, info: info) == [.entryX0, .callResult(0x3ae6c), .callResult(0x3aea4)] else { return false }
        return true
    }

    func testAttributionP09A() throws {
        try withSSA(true) {
            return try MacIRConfiguration.$ssaOverride.withValue(true) {
                let fixture = try RegionalTerminalFixture.make(.finishDecompress)
                let function = fixture.function
                XCTAssertTrue(function.ssaEnabled)
                XCTAssertEqual(function.returnType, "int32_t")
                let phi = try XCTUnwrap(SSAPropertyAssertions.phi(function, block: 0x21850, cell: 0, width: 64,
                    incoming: [(predecessor: fixture.rows[45].address, producer: fixture.rows[43].address),
                               (predecessor: fixture.rows[52].address, producer: fixture.rows[52].address)]))
                SSAPropertyAssertions.assertView(function.returnValue, of: phi, width: 32)
                guard case let .returnValue(returned) = function.instructions[55].operation else {
                    return XCTFail("captured terminal must remain a return")
                }
                SSAPropertyAssertions.assertView(returned, of: phi, width: 32)
                XCTAssertTrue(terminalProvenanceMatches(function))
                RenderProperties.assertNoMarkers(fixture.document, rows: [55])
                let boundary = try XCTUnwrap(RegionalBoundaryPlan.prove(function: function,
                    cfg: CFGBuilder.buildCFG(instructions: function.instructions)))
                XCTAssertEqual(boundary.terminal?.exportRow, 53)
                XCTAssertEqual(boundary.terminal?.alias.value, function.returnValue)
            }
    }
    }

    func testAttributionP09B() throws {
        try withSSA(true) {
            return try MacIRConfiguration.$ssaOverride.withValue(true) {
                let fixture = try RegionalTerminalFixture.make(.finishDecompress)
                let function = fixture.function
                XCTAssertTrue(terminalProvenanceMatches(function), "validate the original before mutating its provenance")
                let index = try XCTUnwrap(function.phis.firstIndex {
                    $0.blockAddress == 0x21850 && SSAPropertyAssertions.physicalCell($0.destination) == 0
                })
                guard function.phis[index].incoming.count == 2 else {
                    return XCTFail("terminal mutant requires the original two predecessor slots")
                }
                var wrongPredecessor = function
                wrongPredecessor.phis[index].incoming[0].predecessor = .machine(fixture.rows[43].address)
                XCTAssertFalse(terminalProvenanceMatches(wrongPredecessor))
                let unrelated = try XCTUnwrap(function.instructions.enumerated().compactMap { row, instruction -> MacIRValue? in
                    guard row != 43, case let .call(_, result?) = instruction.operation,
                          result != function.phis[index].incoming[0].value else { return nil }
                    return result
                }.first)
                var wrongResult = function
                wrongResult.phis[index].incoming[0].value = unrelated
                XCTAssertFalse(terminalProvenanceMatches(wrongResult))
                XCTAssertEqual(wrongPredecessor.instructions, function.instructions)
                XCTAssertEqual(wrongResult.instructions, function.instructions)
                // A structured document is not used as the provenance oracle.
                XCTAssertEqual(wrongResult.cfg, function.cfg)
            }
    }
    }

    func testAttributionP10A() throws {
        try withSSA(true) {
            return try MacIRConfiguration.$ssaOverride.withValue(true) {
                let (fixture, rows, input, function) = try RegionalCallAttributionFixtures.nonterminal()
                XCTAssertTrue(function.ssaEnabled)
                let phi = try XCTUnwrap(SSAPropertyAssertions.phi(function, block: 0x3aea8, cell: 0, width: 64,
                    incoming: [(predecessor: 0x3ae80, producer: 0x3ae70),
                               (predecessor: 0x3aea4, producer: 0x3aea4)]))
                let info = try XCTUnwrap(function.ssaInfo)
                let graph = try XCTUnwrap(function.cfg)
                let block = try XCTUnwrap(graph.blocks.first { $0.startAddress == 0x3aea8 })
                let planned = try XCTUnwrap(info.plan.phis.first { $0.block == block.index && $0.cell == 0 })
                XCTAssertEqual(planned.incoming.map(\.machineAddress), [0x3ae80, 0x3aea4])
                let expected: [Set<SSAPropertyAssertions.CellZeroOrigin>] = [
                    [.entryX0, .callResult(0x3ae6c)], [.callResult(0x3aea4)]
                ]
                for (slot, expectedOrigins) in zip(planned.incoming, expected) {
                    XCTAssertEqual(SSAPropertyAssertions.cellZeroOrigins(slot.definition, info: info), expectedOrigins)
                }
                let row = try XCTUnwrap(info.sourceAddresses.firstIndex(of: 0x3aea8))
                let read = try XCTUnwrap(info.plan.rowReadBindings[row][0])
                XCTAssertEqual(info.plan.canonicalID(read), info.plan.canonicalID(planned.destination))
                XCTAssertEqual(SSAPropertyAssertions.cellZeroOrigins(read, info: info), expected[0].union(expected[1]))
                guard case let .assign(copied, source) = function.instructions[36].operation,
                      case let .store(stored, _) = function.instructions[39].operation else {
                    return XCTFail("join MOV and observed store must retain their operations")
                }
                SSAPropertyAssertions.assertView(source, of: phi, width: 64)
                SSAPropertyAssertions.assertView(stored, of: phi, width: 64)
                // MOV copies the selected X0 into X20; the later STR still reads
                // X0. The two SSA destinations are not interchangeable identities.
                XCTAssertEqual(rows[36].address, 0x3aea8)
                XCTAssertEqual(rows[36].mnemonic, "mov")
                XCTAssertEqual(MacIRBuilder.splitOperands(rows[36].operands), ["x20", "x0"])
                XCTAssertEqual(SSAPropertyAssertions.physicalCell(copied), 20)
                XCTAssertEqual(rows[39].address, 0x3aeb4)
                XCTAssertEqual(rows[39].mnemonic, "str")
                XCTAssertEqual(MacIRBuilder.splitOperands(rows[39].operands).first, "x0")
                let storeRow = try XCTUnwrap(info.sourceAddresses.firstIndex(of: rows[39].address))
                let storeRead = try XCTUnwrap(info.plan.rowReadBindings[storeRow][0])
                XCTAssertEqual(info.plan.canonicalID(read), info.plan.canonicalID(storeRead),
                               "MOV source and STR source read the same cell-0 definition")
                XCTAssertEqual(stored, source, "row 39 stores the unchanged X0 phi read by the row 36 MOV")
                XCTAssertTrue(nonterminalOriginsMatch(function))
                let program = try RegionalCallOracle.Program(rows: rows, function: function)
                let scenario = try RegionalCallOracle.UpsamplerScenarios.make(seed: fixture.seed,
                    name: "J23-nonterminal-origin", paths: [], invalidPrecision: true)
                let observed = try RegionalCallOracle.Machine(program: program, scenario: scenario).run()
                XCTAssertTrue(observed.returned)
                XCTAssertNil(observed.returnBits)
                XCTAssertEqual(observed.calls.map(\.row), [21])
                XCTAssertEqual(observed.rowVisits[26], 1)
                XCTAssertEqual(observed.rowVisits[36], 1)
                XCTAssertNil(observed.rowVisits[35], "allocation is bypassed on this captured path")
                let stores = observed.events.compactMap { event -> UInt64? in
                    if case let .store(row, _, bytes, bits) = event, row == 39, bytes == 8 { return bits }
                    return nil
                }
                XCTAssertEqual(stores, [try XCTUnwrap(observed.calls.first).result])
                var options = DecompilerOptions.default
                options.structureControlFlow = false
                let document = PseudocodePrinter(options: options).print(function: function, types: input.types,
                    nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
                    stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
                RenderProperties.assertNoMarkers(document, rows: [36])
            }
    }
    }

    func testAttributionP10B() throws {
        try withSSA(true) {
            return try MacIRConfiguration.$ssaOverride.withValue(true) {
                let (_, _, _, function) = try RegionalCallAttributionFixtures.nonterminal()
                XCTAssertTrue(nonterminalOriginsMatch(function), "validate the original before mutating its origins")
                let info = try XCTUnwrap(function.ssaInfo)
                let block = try XCTUnwrap(function.cfg?.blocks.first { $0.startAddress == 0x3aea8 })
                let plannedIndex = try XCTUnwrap(info.plan.phis.firstIndex { $0.block == block.index && $0.cell == 0 })
                let renderedIndex = try XCTUnwrap(function.phis.firstIndex {
                    $0.blockAddress == 0x3aea8 && SSAPropertyAssertions.physicalCell($0.destination) == 0
                })
                guard info.plan.phis[plannedIndex].incoming.count == 2,
                      function.phis[renderedIndex].incoming.count == 2 else {
                    return XCTFail("nonterminal mutant requires the original two predecessor slots")
                }
                let entry = try XCTUnwrap(info.plan.definitions.first { $0.cell == 0 && $0.origin == .entry }?.id)
                let allocation = try XCTUnwrap(info.plan.rowWriteBindings[35][0])
                for replacement in [entry, allocation] {
                    var mutant = function
                    var changedInfo = info
                    changedInfo.plan.phis[plannedIndex].incoming[0].definition = replacement
                    mutant.ssaInfo = changedInfo
                    mutant.phis[renderedIndex].incoming[0].value = try XCTUnwrap(info.values[info.plan.canonicalID(replacement)])
                    XCTAssertFalse(nonterminalOriginsMatch(mutant),
                        "bypass must retain both entry X0 and the earlier call, never the allocation-only value")
                    XCTAssertEqual(mutant.instructions[36], function.instructions[36])
                    XCTAssertEqual(mutant.instructions[39], function.instructions[39])
                    XCTAssertEqual(mutant.cfg, function.cfg)
                }
            }
    }
    }
}
