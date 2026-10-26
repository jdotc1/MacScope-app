import XCTest
@testable import MacScope

final class UnwindAuditExecutionTests: XCTestCase {
    func testLinearNOPIsOneBodyObservation() throws {
        let result = try run([0xd503201f, 0xd65f03c0])
        XCTAssertEqual(result.observations.map(\.pc), [0x1000])
        XCTAssertEqual(result.scope, "modeled_leaf_body")
        XCTAssertEqual(result.loopClosures, 0)
    }

    func testUnknownLoopClosesOnlyAfterExactFullStateRecurrence() throws {
        let result = try run([0xf100011f, 0x54ffffe1, 0xd65f03c0])
        XCTAssertEqual(Set(result.observations.map(\.pc)), [0x1000, 0x1004])
        XCTAssertEqual(result.loopVisits, 2)
        XCTAssertEqual(result.loopClosures, 1)
        XCTAssertTrue(result.observations.contains { !$0.certain })
    }

    func testKnownRecurrentLoopDoesNotInventReturn() throws {
        assertFailure("no_supported_observation") {
            try run([0xd2800000, 0xf100001f, 0x54ffffe0, 0xd65f03c0])
        }
    }

    func testMultipleBackedgesDecline() throws {
        assertFailure("cfg_loop_shape_not_modeled") {
            try run([0xd503201f, 0x54ffffe1, 0xd503201f, 0x54ffffe1, 0xd65f03c0])
        }
    }

    func testCallInsideLoopDeclines() throws {
        assertFailure("cfg_loop_call_not_modeled") {
            try run([0xa9bf7bfd, 0x910003fd, 0x940003fe, 0x54ffffe1, 0xa8c17bfd, 0xd65f03c0],
                    mode: "frame", callees: [0x2000])
        }
    }

    func testUnrestoredReturnOverridesEarlierObservation() throws {
        assertFailure("unmodeled_return_state") {
            try run([0xd28000f3, 0xd503201f, 0xd65f03c0])
        }
    }

    func testObservationBudgetDeclinesBeforeAcceptance() throws {
        var limits = UnwindAuditLimits()
        limits.maxObservations = 0
        assertFailure("observation_limit") {
            try run([0xd503201f, 0xd65f03c0], limits: limits)
        }
    }

    func testLoopCallModelObservesOriginalBLAndClosesRecurrence() throws {
        var suspensions = 0
        let result = try callLoop { state, pc in
            suspensions += 1
            XCTAssertEqual(pc, 0x1008)
            XCTAssertEqual(state.registers[30], .constant(0x100c))
            XCTAssertEqual(state.sp, .stack(displacement: -16))
            XCTAssertEqual(state.registers[29], .stack(displacement: -16))
            for register in 0..<19 { XCTAssertFalse(state.registers[register].known) }
            for register in 19..<29 {
                XCTAssertEqual(state.registers[register], .original(register: register, displacement: 0))
            }
            return try self.frameRecovery(state)
        }
        XCTAssertEqual(result.scope, "synchronous_call_sites")
        XCTAssertEqual(Set(result.observations.map(\.pc)), [0x1008])
        XCTAssertEqual(suspensions, 2)
        XCTAssertEqual(result.loopVisits, 2)
        XCTAssertEqual(result.loopClosures, 1)
        XCTAssertTrue(result.observations.contains { $0.certain })
        XCTAssertTrue(result.observations.contains { !$0.certain })
        for observation in result.observations {
            XCTAssertEqual(observation.recovered["SP"], .stack(displacement: 0))
            XCTAssertEqual(observation.recovered["x30"], .original(register: 30, displacement: 0))
        }
    }

    func testLoopCallModelMissingAndInternalTargetsRefuse() throws {
        let targets: [Set<UInt64>] = [[], [0x1000], [0x1008]]
        for callees in targets {
            assertFailure("cfg_call_target_not_modeled") {
                try callLoop(callees: callees)
            }
        }
        assertFailure("cfg_call_target_not_modeled") {
            try callLoop(words: [0xa9bf7bfd, 0x910003fd, 0x94000001,
                                 0x54ffffe1, 0xa8c17bfd, 0xd65f03c0], callees: [0x100c])
        }
        // A recursive BL to the caller entry is not an independently owned callee.
        assertFailure("cfg_call_target_not_modeled") {
            try callLoop(words: [0xa9bf7bfd, 0x910003fd, 0x97fffffe,
                                 0x54ffffe1, 0xa8c17bfd, 0xd65f03c0], callees: [0x1000])
        }
    }

    func testLoopCallModelRefusesEscapedStackAddress() throws {
        assertFailure("stack_address_escapes_call") {
            try callLoop(words: [0xa9bf7bfd, 0x910003fd, 0x910003e0,
                                 0x940003fd, 0x54ffffe1, 0xa8c17bfd, 0xd65f03c0])
        }
    }

    func testLoopCallModelStillExcludesFramelessCalls() throws {
        assertFailure("frameless_nonleaf_not_modeled") {
            try run([0x94000400, 0x54ffffe1, 0xd65f03c0], callees: [0x2000],
                    model: .boundedLoopCalls)
        }
    }

    func testLoopCallModelBudgetsRefuseBeforeAcceptance() throws {
        var limits = UnwindAuditLimits()
        limits.maxPaths = 1
        assertFailure("cfg_path_limit") { try callLoop(limits: limits) }
        limits = .init(); limits.maxSteps = 3
        assertFailure("cfg_work_limit") { try callLoop(limits: limits) }
        limits = .init(); limits.maxObservations = 1
        assertFailure("observation_limit") { try callLoop(limits: limits) }
        limits = .init(); limits.maxInstructions = 5
        assertFailure("function_instruction_limit") { try callLoop(limits: limits) }
    }

    func testLoopCallModelChangingPreservedStateExhaustsHeaderBudget() throws {
        var limits = UnwindAuditLimits()
        limits.maxPaths = 4
        // Known conditional backedge stays taken; x19 changes on every visit.
        assertFailure("cfg_loop_state_limit") {
            try callLoop(words: [0xa9bf7bfd, 0x910003fd, 0x940003fe,
                                 0x91000673, 0xeb1f03ff, 0x54ffffa0,
                                 0xa8c17bfd, 0xd65f03c0], limits: limits)
        }
    }

    func testLoopCallModelClearsFlagsBeforeConditionalBackedge() throws {
        // CMP xzr,xzr sets Z before BL. An EQ after return must still fork:
        // the callee summary clears flags, so this cannot become a proven no-exit loop.
        let result = try callLoop(words: [0xa9bf7bfd, 0x910003fd, 0xeb1f03ff,
                                         0x940003fd, 0x54ffffe0, 0xa8c17bfd, 0xd65f03c0])
        XCTAssertTrue(result.observations.contains { !$0.certain })
        XCTAssertEqual(result.loopClosures, 1)
        XCTAssertEqual(Set(result.observations.map(\.pc)), [0x100c])
    }

    func testLoopCallModelRefusesSequentialLoopsAndExternalTailBranch() throws {
        assertFailure("cfg_loop_shape_not_modeled") {
            try callLoop(words: [0xa9bf7bfd, 0x910003fd, 0x940003fe,
                                 0x54ffffe1, 0xd503201f, 0x54ffffe1,
                                 0xa8c17bfd, 0xd65f03c0])
        }
        XCTAssertThrowsError(try callLoop(words: [0xa9bf7bfd, 0x910003fd, 0x140003fe,
                                                 0x54ffffe1, 0xa8c17bfd, 0xd65f03c0])) { error in
            XCTAssertEqual((error as? UnwindAuditModelError)?.code, "cfg_edge_not_modeled")
            XCTAssertEqual((error as? UnwindAuditModelError)?.address, 0x1008)
        }
    }

    func testLoopCallModelRefusesIndirectCallAtOriginalPC() throws {
        XCTAssertThrowsError(try callLoop(words: [0xa9bf7bfd, 0x910003fd, 0xd63f0000,
                                                 0x54ffffe1, 0xa8c17bfd, 0xd65f03c0])) { error in
            XCTAssertEqual((error as? UnwindAuditModelError)?.code, "unsupported_control_flow")
            XCTAssertEqual((error as? UnwindAuditModelError)?.address, 0x1008)
        }
    }

    func testLoopCallModelRetainsConcreteBadRuleRecoveryAtOriginalPC() throws {
        // The original 32-byte allocation conflicts with the 16-byte compact frame rule.
        let result = try callLoop(words: [0xa9be7bfd, 0x910003fd, 0x940003fe,
                                         0x54ffffe1, 0xa8c27bfd, 0xd65f03c0])
        let first = try XCTUnwrap(result.observations.first)
        XCTAssertTrue(first.certain)
        XCTAssertEqual(first.pc, 0x1008)
        XCTAssertEqual(first.recovered["SP"], .stack(displacement: -16))
        XCTAssertEqual(first.recovered["x29"], .original(register: 29, displacement: 0))
        XCTAssertEqual(first.recovered["x30"], .original(register: 30, displacement: 0))
    }

    func testLoopCallModelDoesNotInventReturnAfterRecurrence() throws {
        assertFailure("no_supported_observation") {
            try callLoop(words: [0xa9bf7bfd, 0x910003fd, 0x940003fe,
                                 0xeb1f03ff, 0x54ffffc0, 0xa8c17bfd, 0xd65f03c0])
        }
    }

    private func frameRecovery(_ state: UnwindAuditMachine) throws -> [String: UnwindAuditValue] {
        var recovered = Dictionary(uniqueKeysWithValues: (19...30).map { ("x\($0)", state.registers[$0]) })
        recovered["SP"] = try state.registers[29].add(16)
        if let slot = state.registers[29].stackDisplacement {
            recovered["x29"] = state.memory[slot]
            recovered["x30"] = state.memory[slot + 8]
        }
        return recovered
    }

    private func callLoop(
        words: [UInt32] = [0xa9bf7bfd, 0x910003fd, 0x940003fe, 0x54ffffe1, 0xa8c17bfd, 0xd65f03c0],
        callees: Set<UInt64> = [0x2000], limits: UnwindAuditLimits = .init(),
        recover: ((UnwindAuditMachine, UInt64) throws -> [String: UnwindAuditValue])? = nil
    ) throws -> UnwindAuditExecutionResult {
        let bytes = Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
        let instructions = try UnwindAuditInstruction.decode(data: bytes, start: 0x1000, maximum: 16_384)
        return try UnwindAuditExecution.run(instructions: instructions, mode: "frame", calleeEntries: callees,
                                             limits: limits, model: .boundedLoopCalls) { state, pc in
            if let recover { return try recover(state, pc) }
            return try self.frameRecovery(state)
        }
    }

    private func run(_ words: [UInt32], mode: String = "frameless", callees: Set<UInt64> = [],
                     limits: UnwindAuditLimits = .init(),
                     model: UnwindAuditModel = .boundedLoops) throws -> UnwindAuditExecutionResult {
        let bytes = Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
        let instructions = try UnwindAuditInstruction.decode(data: bytes, start: 0x1000, maximum: limits.maxInstructions)
        return try UnwindAuditExecution.run(instructions: instructions, mode: mode, calleeEntries: callees, limits: limits, model: model) { state, _ in
            var recovered = Dictionary(uniqueKeysWithValues: (19...30).map { ("x\($0)", state.registers[$0]) })
            recovered["SP"] = state.sp
            return recovered
        }
    }

    private func assertFailure(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                               _ body: () throws -> UnwindAuditExecutionResult) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? UnwindAuditModelError)?.code, code, file: file, line: line)
        }
    }
}
