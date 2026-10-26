import XCTest
@testable import MacScope

final class RegisterAllocationMergeTests: XCTestCase {
    private func plan(_ assembly: [(String, String)]) throws -> ScalarCFGStatePlan {
        let rows = assembly.enumerated().map { index, instruction in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "00 00 00 00",
                           mnemonic: instruction.0, operands: instruction.1,
                           hasBreakpoint: false, comment: nil)
        }
        return try XCTUnwrap(ScalarCFGStatePlan.admit(rows, hasExternalFacts: false))
    }

    private func diamond() throws -> ScalarCFGStatePlan {
        try plan([("cbz", "x0, 0x100c"), ("nop", ""), ("b", "0x1010"),
                  ("nop", ""), ("ret", "")])
    }

    // A symbolic incoming-state contract, independent of scalar admission.
    private func earlyJoin(availableFirst: Bool = true) -> ScalarCFGStatePlan {
        let blocks = [
            BasicBlock(index: 0, startIndex: 0, endIndex: 1,
                       successors: [2, 3], predecessors: [], isLoopHeader: false),
            BasicBlock(index: 1, startIndex: 1, endIndex: 3,
                       successors: [], predecessors: availableFirst ? [2, 3] : [3, 2], isLoopHeader: false),
            BasicBlock(index: 2, startIndex: 3, endIndex: 6,
                       successors: [1], predecessors: [0], isLoopHeader: false),
            BasicBlock(index: 3, startIndex: 6, endIndex: 9,
                       successors: [1], predecessors: [0], isLoopHeader: false)
        ]
        let starts = Dictionary(uniqueKeysWithValues: blocks.map { ($0.startIndex, $0.index) })
        let cfg = CFG(blocks: blocks, entryIndex: 0, domTree: [0: 0, 1: 0, 2: 0, 3: 0],
                      postDomTree: [0: 1, 1: 1, 2: 1, 3: 1], loopHeaders: [],
                      backEdges: [], irreducibleBlocks: [], blockByStartIndex: starts,
                      hasUnresolvedTargets: false)
        return ScalarCFGStatePlan(cfg: cfg, blockAtStart: starts,
                                  blockAtEnd: Dictionary(uniqueKeysWithValues: blocks.map { ($0.endIndex - 1, $0.index) }),
                                  conditionalForks: [:], referencedXRegisters: [])
    }

    private func issuedPredecessor() -> BuilderState {
        var state = BuilderState()
        for _ in 0..<21 { state.writeRegister("x8") }
        state.registerVersionFloor = 20
        return state
    }

    private func assertMissingPredecessorFreshness(availableFirst: Bool,
                                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let plan = earlyJoin(availableFirst: availableFirst)
        let predecessor = issuedPredecessor()
        XCTAssertEqual(predecessor.registerVersions["x8"], 21, file: file, line: line)
        XCTAssertEqual(predecessor.nextRegisterTemporaryIndex, 21, file: file, line: line)
        var phis: [ScalarCFGStatePlan.PhiDraft] = []
        var state = plan.incoming(for: 1, entry: BuilderState(),
                                  outgoing: [2: predecessor], phis: &phis)
        XCTAssertEqual(state.registerVersionFloor, 20, file: file, line: line)
        XCTAssertEqual(state.nextRegisterTemporaryIndex, 21, file: file, line: line)
        XCTAssertEqual(state.registerVersions["x8"], 21, file: file, line: line)
        XCTAssertTrue(phis.isEmpty, file: file, line: line)
        let fresh = state.writeRegister("x8")
        XCTAssertEqual(fresh, .register(name: "x8", version: 22), file: file, line: line)
        let binding = try XCTUnwrap(state.registerNameBindingsByValue[fresh], file: file, line: line)
        XCTAssertEqual(binding.name, "tmp21", file: file, line: line)
        for (value, earlierBinding) in predecessor.registerNameBindingsByValue {
            XCTAssertNotEqual(fresh, value, file: file, line: line)
            XCTAssertNotEqual(binding.name, earlierBinding.name, file: file, line: line)
        }
    }

    func testMissingPredecessorCarriesAvailableCounters() throws {
        try assertMissingPredecessorFreshness(availableFirst: true)
    }

    func testMissingFirstPredecessorCarriesAvailableCounters() throws {
        try assertMissingPredecessorFreshness(availableFirst: false)
    }

    func testMissingPredecessorDoesNotImportAvailableValues() {
        let plan = earlyJoin()
        var predecessor = issuedPredecessor()
        let value = predecessor.readRegister("x8")
        predecessor.valueTypeHints[value] = "uint64_t"
        predecessor.stackSlotValues[16] = StackSlotValueFact(value: value, byteWidth: 8, carrierKind: .integer)
        var phis: [ScalarCFGStatePlan.PhiDraft] = []
        let state = plan.incoming(for: 1, entry: BuilderState(),
                                 outgoing: [2: predecessor], phis: &phis)
        for index in 0...30 {
            XCTAssertEqual(state.readRegister("x\(index)"), .unknown("unavailable_x\(index)"))
            XCTAssertEqual(state.readRegister("w\(index)"), .unknown("unavailable_w\(index)"))
        }
        XCTAssertTrue(state.currentIntegerDefinitionByIndex.isEmpty)
        XCTAssertTrue(state.registerNameBindingsByValue.isEmpty)
        XCTAssertTrue(state.registerNameBindingOrder.isEmpty)
        XCTAssertTrue(state.valueTypeHints.isEmpty)
        XCTAssertTrue(state.stackSlotValues.isEmpty)
        XCTAssertTrue(phis.isEmpty)
        for index in 0...31 { XCTAssertEqual(state.callResultVectorWidth[index], 0) }
    }

    func testMissingPredecessorPreservesHigherEntryCounters() {
        let plan = earlyJoin()
        var entry = BuilderState()
        entry.registerVersionFloor = 100
        entry.nextRegisterTemporaryIndex = 101
        entry.registerVersions["x8"] = 120
        entry.registerVersions["w9"] = 130
        var phis: [ScalarCFGStatePlan.PhiDraft] = []
        var state = plan.incoming(for: 1, entry: entry,
                                  outgoing: [2: issuedPredecessor()], phis: &phis)
        XCTAssertEqual(state.registerVersionFloor, 100)
        XCTAssertEqual(state.nextRegisterTemporaryIndex, 101)
        XCTAssertEqual(state.registerVersions, entry.registerVersions)
        let fresh = state.writeRegister("x8")
        XCTAssertEqual(fresh, .register(name: "x8", version: 121))
        XCTAssertEqual(state.registerNameBindingsByValue[fresh]?.name, "tmp101")
        XCTAssertEqual(state.registerVersions["w9"], 130)
        XCTAssertTrue(phis.isEmpty)
    }

    func testMissingPredecessorReservesBlockFloor() throws {
        let plan = try diamond()
        let join = try XCTUnwrap(plan.blockAtStart[4])
        let predecessor = try XCTUnwrap(plan.cfg.blocks[join].predecessors.first)
        var phis: [ScalarCFGStatePlan.PhiDraft] = []
        var state = plan.incoming(for: join, entry: BuilderState(),
                                  outgoing: [predecessor: BuilderState()], phis: &phis)
        XCTAssertEqual(state.registerVersionFloor, 18)
        XCTAssertEqual(state.nextRegisterTemporaryIndex, 18)
        XCTAssertEqual(state.readRegister("x8"), .unknown("unavailable_x8"))
        XCTAssertTrue(phis.isEmpty)
        let fresh = state.writeRegister("x8")
        XCTAssertEqual(fresh, .register(name: "x8", version: 19))
        XCTAssertEqual(state.registerNameBindingsByValue[fresh]?.name, "tmp18")
    }

    func testMissingPredecessorDoesNotReuseEarlierTemporary() throws {
        let plan = try diamond()
        let join = try XCTUnwrap(plan.blockAtStart[4])
        let predecessor = try XCTUnwrap(plan.cfg.blocks[join].predecessors.first)
        var earlier = BuilderState()
        let old = earlier.writeRegister("x8")
        let binding = try XCTUnwrap(earlier.registerNameBindingsByValue[old])
        XCTAssertEqual(binding.name, "tmp0")
        var phis: [ScalarCFGStatePlan.PhiDraft] = []
        var state = plan.incoming(for: join, entry: BuilderState(),
                                  outgoing: [predecessor: earlier], phis: &phis)
        let fresh = state.writeRegister("x8")
        XCTAssertNotEqual(fresh, old)
        XCTAssertEqual(state.registerNameBindingsByValue[fresh]?.name, "tmp18")
        XCTAssertNotEqual(state.registerNameBindingsByValue[fresh]?.name, binding.name)
        XCTAssertEqual(earlier.registerNameBindingsByValue[old], binding)
        XCTAssertEqual(earlier.readRegister("x8"), old)
    }

    func testAlreadyReservedSinglePredecessorPreservesState() throws {
        let plan = try diamond()
        let block = try XCTUnwrap(plan.blockAtStart[1])
        var original = BuilderState()
        let value = original.writeRegister("x8")
        original.registerVersionFloor = 200
        original.nextRegisterTemporaryIndex = 201
        original.valueTypeHints[value] = "uint64_t"
        original.recordUnmodeledDefiniteWrite(for: "x9")
        var phis: [ScalarCFGStatePlan.PhiDraft] = []
        let state = plan.incoming(for: block, entry: BuilderState(),
                                 outgoing: [plan.cfg.entryIndex: original], phis: &phis)
        XCTAssertEqual(state.registerVersionFloor, 200)
        XCTAssertEqual(state.nextRegisterTemporaryIndex, 201)
        XCTAssertEqual(state.registerVersions, original.registerVersions)
        XCTAssertEqual(state.registerNameBindingsByValue, original.registerNameBindingsByValue)
        XCTAssertEqual(state.registerNameBindingOrder, original.registerNameBindingOrder)
        XCTAssertEqual(state.valueTypeHints, original.valueTypeHints)
        XCTAssertEqual(state.unavailableRegisterValues, original.unavailableRegisterValues)
        XCTAssertEqual(Set(state.currentIntegerDefinitionByIndex.keys),
                       Set(original.currentIntegerDefinitionByIndex.keys))
        XCTAssertEqual(state.currentIntegerDefinitionByIndex[8]?.value,
                       original.currentIntegerDefinitionByIndex[8]?.value)
        XCTAssertEqual(state.currentIntegerDefinitionByIndex[8]?.width,
                       original.currentIntegerDefinitionByIndex[8]?.width)
        XCTAssertEqual(state.readRegister("x8"), value)
        XCTAssertEqual(state.readRegister("x9"), .unknown("unavailable_x9"))
        XCTAssertTrue(phis.isEmpty)
    }

    func testLowerBlockFloorNeverLowersInheritedReservation() throws {
        let plan = try diamond()
        let block = try XCTUnwrap(plan.blockAtStart[1])
        var original = BuilderState()
        original.registerVersionFloor = 200
        original.nextRegisterTemporaryIndex = 201
        for outgoing in [[:], [plan.cfg.entryIndex: original]] {
            var phis: [ScalarCFGStatePlan.PhiDraft] = []
            var state = plan.incoming(for: block, entry: original, outgoing: outgoing, phis: &phis)
            XCTAssertEqual(state.registerVersionFloor, 200)
            XCTAssertEqual(state.nextRegisterTemporaryIndex, 201)
            XCTAssertEqual(state.registerVersions, original.registerVersions)
            let fresh = state.writeRegister("x8")
            XCTAssertEqual(fresh, .register(name: "x8", version: 201))
            XCTAssertEqual(state.registerNameBindingsByValue[fresh]?.name, "tmp201")
        }
    }

    private func predecessors() -> (BuilderState, BuilderState) {
        var low = BuilderState()
        low.nextRegisterTemporaryIndex = 3
        var high = BuilderState()
        high.nextRegisterTemporaryIndex = 20
        high.writeRegister("x8")
        high.nextRegisterTemporaryIndex = 100
        high.writeRegister("x9")
        high.registerVersionFloor = 200
        high.registerVersions["x8"] = 300
        // Historical counters do not replace the current physical definitions.
        return (low, high)
    }

    func testNonFirstPredecessorContributesEveryAllocationCounter() throws {
        let plan = try diamond()
        let join = try XCTUnwrap(plan.blockAtStart[4])
        let incoming = plan.cfg.blocks[join].predecessors
        XCTAssertEqual(incoming.count, 2)
        let (low, high) = predecessors()
        var phis: [ScalarCFGStatePlan.PhiDraft] = []
        var state = plan.incoming(for: join, entry: BuilderState(),
                                  outgoing: [incoming[0]: low, incoming[1]: high], phis: &phis)
        XCTAssertEqual(state.registerVersionFloor, 200)
        XCTAssertEqual(state.nextRegisterTemporaryIndex, 101)
        XCTAssertEqual(state.registerVersions["x8"], 300)
        XCTAssertEqual(state.registerVersions["x9"], 1)
        XCTAssertEqual(state.readRegister("x8"), .unknown("unavailable_x8"))
        XCTAssertNil(state.currentIntegerDefinitionByIndex[8])
        XCTAssertTrue(phis.isEmpty)
        let fresh = state.writeRegister("x8")
        XCTAssertEqual(fresh, .register(name: "x8", version: 301))
        XCTAssertEqual(state.registerNameBindingsByValue[fresh]?.name, "tmp101")
        for (value, binding) in high.registerNameBindingsByValue {
            XCTAssertEqual(state.registerNameBindingsByValue[value], binding)
        }
    }

    func testPredecessorPermutationPreservesFreshness() throws {
        let plan = try diamond()
        let join = try XCTUnwrap(plan.blockAtStart[4])
        let incoming = plan.cfg.blocks[join].predecessors
        XCTAssertEqual(incoming.count, 2)
        let (low, high) = predecessors()
        var results: [BuilderState] = []
        for (first, second) in [(low, high), (high, low)] {
            var phis: [ScalarCFGStatePlan.PhiDraft] = []
            var state = plan.incoming(for: join, entry: BuilderState(),
                                      outgoing: [incoming[0]: first, incoming[1]: second], phis: &phis)
            XCTAssertEqual(state.registerVersionFloor, 200)
            XCTAssertEqual(state.nextRegisterTemporaryIndex, 101)
            let fresh = state.writeRegister("x8")
            XCTAssertEqual(fresh, .register(name: "x8", version: 301))
            XCTAssertEqual(state.registerNameBindingsByValue[fresh]?.name, "tmp101")
            for (value, binding) in high.registerNameBindingsByValue {
                XCTAssertEqual(state.registerNameBindingsByValue[value], binding)
                XCTAssertNotEqual(binding.name, state.registerNameBindingsByValue[fresh]?.name)
            }
            results.append(state)
        }
        XCTAssertEqual(results[0].registerVersions, results[1].registerVersions)
        XCTAssertEqual(results[0].nextRegisterTemporaryIndex, results[1].nextRegisterTemporaryIndex)
        XCTAssertEqual(results[0].registerNameBindingsByValue, results[1].registerNameBindingsByValue)
    }

    func testUnavailableBlockReservesWithoutInventingDefinitions() throws {
        let plan = try diamond()
        let join = try XCTUnwrap(plan.blockAtStart[4])
        var entry = BuilderState()
        entry.writeRegister("x8")
        var phis: [ScalarCFGStatePlan.PhiDraft] = []
        var state = plan.incoming(for: join, entry: entry, outgoing: [:], phis: &phis)
        XCTAssertEqual(state.registerVersionFloor, 18)
        XCTAssertEqual(state.nextRegisterTemporaryIndex, 18)
        XCTAssertEqual(state.registerVersions, entry.registerVersions)
        XCTAssertEqual(state.registerNameBindingsByValue, entry.registerNameBindingsByValue)
        XCTAssertTrue(state.currentIntegerDefinitionByIndex.isEmpty)
        XCTAssertTrue(phis.isEmpty)
        for index in 0...30 {
            XCTAssertEqual(state.readRegister("x\(index)"), .unknown("unavailable_x\(index)"))
            XCTAssertEqual(state.readRegister("w\(index)"), .unknown("unavailable_w\(index)"))
        }
        for index in 0...31 { XCTAssertEqual(state.callResultVectorWidth[index], 0) }
        let fresh = state.writeRegister("x8")
        XCTAssertEqual(fresh, .register(name: "x8", version: 19))
        XCTAssertEqual(state.registerNameBindingsByValue[fresh]?.name, "tmp18")
        XCTAssertEqual(state.readRegister("x9"), .unknown("unavailable_x9"))
    }

    func testPendingLoopBackedgeReservesBeforePhiWrites() throws {
        let plan = try plan([
            ("mov", "x8, #0"), ("cbz", "x0, 0x1014"),
            ("add", "x8, x8, x0"), ("subs", "x0, x0, #1"),
            ("b.ne", "0x1008"), ("mov", "x0, x8"), ("ret", "")
        ])
        let header = try XCTUnwrap(plan.blockAtStart[2])
        let incoming = plan.cfg.blocks[header].predecessors
        let forward = try XCTUnwrap(incoming.first { !plan.cfg.backEdges.contains(CFGEdge($0, header)) })
        XCTAssertTrue(incoming.contains { plan.cfg.backEdges.contains(CFGEdge($0, header)) })
        var entry = BuilderState()
        let old = entry.writeRegister("x8")
        var phis: [ScalarCFGStatePlan.PhiDraft] = []
        let state = plan.incoming(for: header, entry: entry, outgoing: [forward: entry], phis: &phis)
        let phi = try XCTUnwrap(phis.first { $0.register == "x8" })
        XCTAssertEqual(state.registerVersionFloor, 8)
        XCTAssertEqual(phi.destination, .register(name: "x8", version: 9))
        XCTAssertEqual(state.registerNameBindingsByValue[phi.destination]?.name, "tmp8")
        XCTAssertEqual(state.registerNameBindingsByValue[old], entry.registerNameBindingsByValue[old])
        XCTAssertEqual(state.readRegister("x8"), phi.destination)
        XCTAssertEqual(state.currentIntegerDefinitionByIndex[8]?.isJoinedDefinition, true)
        XCTAssertEqual(state.readRegister("x9"), .unknown("unavailable_x9"))
        XCTAssertEqual(state.callResultVectorWidth[0], 0)
        XCTAssertTrue(state.resolvedX0PhiReturnProducers.isEmpty)
        XCTAssertEqual(Set(phis.map(\.register)), ["x0", "x8"])
    }
}
