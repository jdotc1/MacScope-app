import XCTest
@testable import MacScope

final class MacIRExactVectorLoadTests: XCTestCase {
    private func source(_ bytes: String, _ mnemonic: String, _ operands: String) -> MacIRSourceSpan {
        .init(address: 0x1000, byteText: bytes, mnemonic: mnemonic, operands: operands)
    }

    // Removing load admission, a half definition, or the memory read fails this table.
    func testLoadEncodingsDefineBothHalvesWithoutReadingOldDestinations() throws {
        let cases: [(String, String, String, [Int], [Int])] = [
            ("20 08 c0 3d", "ldr", "q0, [x1, #32]", [1, 97], [32, 64]),
            ("00 e1 c0 3d", "ldr", "q0, [x8, #0x380]", [8, 97], [32, 64]),
            ("df 0b c0 3d", "ldr", "q31, [x30, #32]", [30, 97], [63, 95]),
            ("20 00 df 3c", "ldur", "q0, [x1, #-16]", [1, 97], [32, 64]),
            ("20 04 c1 3c", "ldr", "q0, [x1], #16", [1, 97], [1, 32, 64]),
            ("20 0c c1 3c", "ldr", "q0, [x1, #16]!", [1, 97], [1, 32, 64]),
            ("40 04 41 ad", "ldp", "q0, q1, [x2, #32]", [2, 97], [32, 33, 64, 65]),
            ("40 04 ff ad", "ldp", "q0, q1, [x2, #-32]!", [2, 97], [2, 32, 33, 64, 65]),
            ("40 04 c1 ac", "ldp", "q0, q1, [x2], #32", [2, 97], [2, 32, 33, 64, 65])
        ]
        for (bytes, mnemonic, operands, reads, writes) in cases {
            let row = source(bytes, mnemonic, operands)
            XCTAssertNotNil(MacIRBuilder.ssaExactVector(row), operands)
            let effects = MacIRBuilder.ssaEffects(for: row)
            XCTAssertEqual(effects.readViews.keys.sorted(), reads, operands)
            XCTAssertEqual(effects.writes.map(\.cell), writes, operands)
            XCTAssertTrue(effects.writes.allSatisfy { $0.bitWidth == 64 }, operands)
            XCTAssertTrue(effects.refusals.isEmpty, operands)
        }
    }

    // Changing effective-address timing, pair stride, width, or split source fails this test.
    func testLoadAddressesWholeReadsAndFinalWriteback() throws {
        let cases: [(String, String, String, Int, Int, Int64, Int64?)] = [
            ("20 08 c0 3d", "ldr", "q0, [x1, #32]", 1, 1, 32, nil),
            ("20 00 df 3c", "ldur", "q0, [x1, #-16]", 1, 1, -16, nil),
            ("20 04 c1 3c", "ldr", "q0, [x1], #16", 1, 1, 0, 16),
            ("20 0c c1 3c", "ldr", "q0, [x1, #16]!", 1, 1, 16, 16),
            ("40 04 41 ad", "ldp", "q0, q1, [x2, #32]", 2, 2, 32, nil),
            ("40 04 ff ad", "ldp", "q0, q1, [x2, #-32]!", 2, 2, -32, -32),
            ("40 04 c1 ac", "ldp", "q0, q1, [x2], #32", 2, 2, 0, 32)
        ]
        for (bytes, mnemonic, text, baseIndex, count, firstOffset, update) in cases {
            let row = source(bytes, mnemonic, text)
            let exact = try XCTUnwrap(MacIRBuilder.ssaExactVector(row))
            let oldBase = MacIRValue.register(name: "x\(baseIndex)", version: 3)
            let newBase = MacIRValue.register(name: "x\(baseIndex)", version: 4)
            func binding(_ value: MacIRValue, _ view: MacIRSSA.ScalarView) -> MacIRSSAState.Binding {
                .init(value: value, bitWidth: 64, view: view, origin: .instruction(0x1000))
            }
            var writes: [Int: MacIRSSAState.Binding] = [:]
            if update != nil { writes[baseIndex] = binding(newBase, .integer) }
            for index in 0..<count {
                writes[32 + index] = binding(.register(name: "lo\(index)", version: 5), .bits)
                writes[64 + index] = binding(.register(name: "hi\(index)", version: 5), .bits)
            }
            var state = BuilderState()
            state.ssa = .init(current: [baseIndex: binding(oldBase, .integer)], writes: writes, clobbers: [:])
            let emitted = try XCTUnwrap(MacIRBuilder.liftSSAExactVector(exact, source: row, state: &state))
            XCTAssertEqual(emitted.count, count * 3 + (update == nil ? 0 : 1), text)
            func address(_ offset: Int64) -> MacIRValue {
                offset == 0 ? oldBase : .binaryExpression(op: "+", left: oldBase, right: .immediate(offset))
            }
            for index in 0..<count {
                let whole = MacIRValue.register(name: "q\(index)", version: 5)
                let load = emitted[index * 3]
                XCTAssertEqual(load.operation, .load(destination: whole, address: address(firstOffset + Int64(index * 16))), text)
                XCTAssertEqual(load.memoryAccess?.byteWidth, 16, text)
                XCTAssertEqual(emitted[index * 3 + 1].operation, .assign(destination: writes[32 + index]!.value,
                    source: .unary(op: "__ssa_low64", value: whole)), text)
                XCTAssertEqual(emitted[index * 3 + 2].operation, .assign(destination: writes[64 + index]!.value,
                    source: .unary(op: "__ssa_high64", value: whole)), text)
                XCTAssertNil(emitted[index * 3 + 1].memoryAccess)
                XCTAssertNil(emitted[index * 3 + 2].memoryAccess)
            }
            if let update {
                XCTAssertEqual(emitted.last?.operation, .assign(destination: newBase, source: address(update)), text)
                XCTAssertNil(emitted.last?.memoryAccess)
            }
        }
    }

    func testSSAIntegrationLoadDefinesBothHalvesAndFeedsExistingStore() throws {
        let rows = [
            InstructionRow(address: 0x1000, bytes: "20 08 c0 3d", mnemonic: "ldr", operands: "q0, [x1, #32]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "40 08 80 3d", mnemonic: "str", operands: "q0, [x2, #32]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = try XCTUnwrap(MacIRBuilder(ssaEnabled: true).buildSSAFunction(
            name: "exact_vector_load", startAddress: 0x1000, rows: rows, initialState: BuilderState(),
            jumpTables: [:], recoveredSwitches: [:], tailCalls: [:], isVariadic: false,
            slotCallContracts: [:], slotCallSignatures: [:], knownTailCallTargets: [:]))
        XCTAssertFalse(function.refusals.contains {
            $0.reason == .unknownEffects && ($0.scope == .row(0x1000) || $0.scope == .row(0x1004))
        })
        let info = try XCTUnwrap(function.ssaInfo)
        let lowID = try XCTUnwrap(info.plan.rowWriteBindings[0][32])
        let highID = try XCTUnwrap(info.plan.rowWriteBindings[0][64])
        let low = try XCTUnwrap(info.values[lowID]), high = try XCTUnwrap(info.values[highID])
        let loads = function.instructions.filter { $0.source.address == 0x1000 }
        XCTAssertEqual(loads.count, 3)
        guard case let .load(whole, _) = loads[0].operation else { return XCTFail("one wide memory read required") }
        XCTAssertEqual(loads[0].memoryAccess?.byteWidth, 16)
        XCTAssertEqual(loads[1].operation, .assign(destination: low, source: .unary(op: "__ssa_low64", value: whole)))
        XCTAssertEqual(loads[2].operation, .assign(destination: high, source: .unary(op: "__ssa_high64", value: whole)))
        let store = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1004 })
        guard case let .store(value, _) = store.operation else { return XCTFail("existing typed store required") }
        XCTAssertEqual(value, .binaryExpression(op: "__ssa_join_vector_halves", left: low, right: high))
        XCTAssertEqual(store.memoryAccess?.byteWidth, 16)
    }

    func testMissingPlannedUpperHalfRefusesBeforeInstallingAnyDestination() throws {
        let row = source("40 04 ff ad", "ldp", "q0, q1, [x2, #-32]!")
        let exact = try XCTUnwrap(MacIRBuilder.ssaExactVector(row))
        func binding(_ value: MacIRValue, _ view: MacIRSSA.ScalarView) -> MacIRSSAState.Binding {
            .init(value: value, bitWidth: 64, view: view, origin: .instruction(0x800))
        }
        let current: [Int: MacIRSSAState.Binding] = [
            2: binding(.register(name: "x2", version: 3), .integer),
            32: binding(.immediate(17), .bits), 64: binding(.immediate(23), .bits),
            33: binding(.immediate(29), .bits), 65: binding(.immediate(31), .bits)
        ]
        // The first pair destination is complete, but the second high definition is absent.
        let writes: [Int: MacIRSSAState.Binding] = [
            2: binding(.register(name: "x2", version: 4), .integer),
            32: binding(.register(name: "lo0", version: 5), .bits),
            64: binding(.register(name: "hi0", version: 5), .bits),
            33: binding(.register(name: "lo1", version: 5), .bits)
        ]
        var state = BuilderState()
        state.ssa = .init(current: current, writes: writes, clobbers: [:])
        XCTAssertNil(MacIRBuilder.liftSSAExactVector(exact, source: row, state: &state))
        let after = try XCTUnwrap(state.ssa)
        XCTAssertEqual(after.current.mapValues(\.value), current.mapValues(\.value))
        XCTAssertEqual(after.writes.mapValues(\.value), writes.mapValues(\.value))
        for (cell, before) in current {
            XCTAssertEqual(after.current[cell]?.bitWidth, before.bitWidth)
            XCTAssertEqual(after.current[cell]?.view, before.view)
            XCTAssertEqual(after.current[cell]?.origin, before.origin)
        }
    }

    func testHighestVectorDestinationDefinesItsOwnTwoHalves() throws {
        let row = source("df 0b c0 3d", "ldr", "q31, [x30, #32]")
        let exact = try XCTUnwrap(MacIRBuilder.ssaExactVector(row))
        let low = MacIRValue.register(name: "lo31", version: 9)
        let high = MacIRValue.register(name: "hi31", version: 9)
        let whole = MacIRValue.register(name: "q31", version: 9)
        let base = MacIRValue.register(name: "x30", version: 2)
        var state = BuilderState()
        state.ssa = .init(current: [
            30: .init(value: base, bitWidth: 64, view: .integer, origin: .instruction(0x800))
        ], writes: [
            63: .init(value: low, bitWidth: 64, view: .bits, origin: .instruction(0x1000)),
            95: .init(value: high, bitWidth: 64, view: .bits, origin: .instruction(0x1000))
        ], clobbers: [:])
        let emitted = try XCTUnwrap(MacIRBuilder.liftSSAExactVector(exact, source: row, state: &state))
        XCTAssertEqual(emitted.count, 3)
        XCTAssertEqual(emitted[0].operation, .load(destination: whole,
            address: .binaryExpression(op: "+", left: base, right: .immediate(32))))
        XCTAssertEqual(emitted[0].memoryAccess?.byteWidth, 16)
        XCTAssertEqual(emitted[1].operation, .assign(destination: low, source: .unary(op: "__ssa_low64", value: whole)))
        XCTAssertEqual(emitted[2].operation, .assign(destination: high, source: .unary(op: "__ssa_high64", value: whole)))
    }

    func testStackAddressFormsUseExactSPCellAndWideTransfers() throws {
        // These former SP exclusions are positive cases now that the shared descriptor owns them.
        let cases: [(String, String, String)] = [
            ("e0 0b c0 3d", "ldr", "q0, [sp, #32]"),
            ("e0 03 df 3c", "ldur", "q0, [sp, #-16]"),
            ("e0 07 41 ad", "ldp", "q0, q1, [sp, #32]"),
            ("e0 0b 80 3d", "str", "q0, [sp, #32]"),
            ("e0 03 9f 3c", "stur", "q0, [sp, #-16]"),
            ("e0 07 01 ad", "stp", "q0, q1, [sp, #32]")
        ]
        for (bytes, mnemonic, operands) in cases {
            let row = source(bytes, mnemonic, operands)
            XCTAssertNotNil(MacIRBuilder.ssaExactVector(row), operands)
            let effects = MacIRBuilder.ssaEffects(for: row)
            XCTAssertEqual(effects.readViews[31], .integer, operands)
            XCTAssertEqual(effects.readViews[97], .memoryEpoch, operands)
            XCTAssertTrue(effects.refusals.isEmpty, operands)
            if mnemonic.hasPrefix("ld") {
                XCTAssertEqual(effects.writes.map(\.cell), mnemonic == "ldp" ? [32, 33, 64, 65] : [32, 64], operands)
            } else {
                XCTAssertEqual(effects.writes.map(\.cell), [97], operands)
                XCTAssertNotNil(effects.readViews[32], operands)
                XCTAssertNotNil(effects.readViews[64], operands)
            }
        }
    }

    func testIndexedQStoreUsesOnlyAddressAndWidePayloadCellsInBothModes() throws {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                let row = source("20 68 a2 3c", "str", "q0, [x1, x2]")
                let exact = try XCTUnwrap(MacIRBuilder.ssaExactVector(row))
                guard case let .indexedStore(indexed) = exact else {
                    return XCTFail("Expected the exact indexed Q-store descriptor")
                }
                XCTAssertEqual(indexed.vector, "q0")
                XCTAssertEqual(indexed.effect, .store)
                XCTAssertEqual(indexed.base, "x1")
                XCTAssertEqual(indexed.index, "x2")
                XCTAssertEqual(indexed.extensionKind, .lsl)
                XCTAssertEqual(indexed.shift, 0)
                let effects = MacIRBuilder.ssaEffects(for: row)
                XCTAssertEqual(effects.readViews.keys.sorted(), [1, 2, 32, 64, 97])
                XCTAssertEqual(effects.readViews[1], .integer)
                XCTAssertEqual(effects.readViews[2], .integer)
                XCTAssertEqual(effects.readViews[32], .bits)
                XCTAssertEqual(effects.readViews[64], .bits)
                XCTAssertEqual(effects.readViews[97], .memoryEpoch)
                XCTAssertEqual(effects.writes.map(\.cell), [97])
                XCTAssertEqual(effects.writes.map(\.view), [.memoryEpoch])
                XCTAssertTrue(effects.refusals.isEmpty)
            }
        }
    }

    func testExcludedAddressFormsAndDisagreementsRemainUnclaimed() {
        let cases: [(String, String, String)] = [
            ("e0 0b c0 3d", "ldr", "q0, [x0, #32]"),
            ("20 08 c0 3d", "ldr", "q0, [sp, #32]"),
            ("e0 0b c0 3d", "ldr", "q0, [x31, #32]"),
            ("e0 0b c0 3d", "ldr", "q0, [sp, #16]"),
            ("e0 03 41 ad", "ldp", "q0, q0, [sp, #32]"),
            ("20 68 e2 3c", "ldr", "q0, [x1, x2]"),
            ("20 79 a8 3c", "str", "q0, [x9, x8, lsl #4]"),
            ("40 04 41 ac", "ldnp", "q0, q1, [x2, #32]"),
            ("40 00 41 ad", "ldp", "q0, q0, [x2, #32]"),
            ("20 08 c0 3d", "ldr", "q1, [x1, #32]"),
            ("20 08 c0 3d", "ldr", "q0, [x2, #32]"),
            ("20 08 c0 3d", "ldr", "q0, [x1, #16]"),
            ("20 08 c0 3d", "ldr", "q0, [x1, #--32]"),
            ("20 08 c0 3d", "str", "q0, [x1, #32]"),
            ("20 08 c0 3d", "ldr", "d0, [x1, #32]"),
            ("20 08 c0 3d", "ldr", "q0, [x1, #32]!"),
            ("", "ldr", "q0, [x1, #32]"),
            ("20 08 c0 3d 00", "ldr", "q0, [x1, #32]")
        ]
        for (bytes, mnemonic, operands) in cases {
            XCTAssertNil(MacIRBuilder.ssaExactVector(source(bytes, mnemonic, operands)), operands)
        }
    }
}

final class MacIRStackVectorMemoryTests: XCTestCase {
    private func function(_ operations: [(String, String, String)], ssa: Bool) throws -> MacIRFunction {
        // Legacy uses its existing SP-capable vector region. Only the SSA case
        // needs harmless scalar arithmetic to prevent that region preempting SSA.
        let prefix: [(String, String, String)] = ssa ? [("29 05 00 91", "add", "x9, x9, #1")] : []
        let assembly = prefix + operations + [("c0 03 5f d6", "ret", "")]
        let rows = assembly.enumerated().map { index, row in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: row.0,
                mnemonic: row.1, operands: row.2, hasBreakpoint: false, comment: nil)
        }
        let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(
            name: "stack_vector_memory", instructions: rows)
        XCTAssertEqual(function.ssaEnabled, ssa)
        XCTAssertFalse(function.instructions.contains {
            if case .unknown = $0.operation { return true }; return false
        })
        XCTAssertFalse(function.refusals.contains { $0.reason == .unknownEffects })
        if ssa { XCTAssertNotNil(function.ssaInfo) }
        return function
    }

    private func install(_ bytes: [UInt8], at address: UInt64, in state: inout A64MachineState) {
        for (offset, byte) in bytes.enumerated() { state.setByte(byte, at: address + UInt64(offset)) }
    }

    func testScaledSPTransferPreservesEveryBitInBothModes() throws {
        // LDR imm12=2 is 2*16=32, STR imm12=4 is 64. Little-endian
        // bytes 01..08 and 81..88 independently define the two 64-bit halves.
        let bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88]
        for mode in [false, true] {
            let f = try function([
                ("e0 0b c0 3d", "ldr", "q0, [sp, #32]"),
                ("e0 13 80 3d", "str", "q0, [sp, #64]")
            ], ssa: mode)
            var initial = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
            initial.sp = 0x8000
            initial.v[0] = .init(low: .max, high: .max)
            install(bytes, at: 0x8020, in: &initial)
            initial.setByte(0xa5, at: 0x803f); initial.setByte(0x5a, at: 0x8050)
            var evaluator = MacIRConcreteEvaluator(function: f, state: initial)
            try evaluator.run(f.instructions)
            XCTAssertEqual(evaluator.state.v[0], .init(low: 0x0807060504030201, high: 0x8887868584838281))
            XCTAssertEqual((0..<16).map { evaluator.state.byte(at: 0x8040 + UInt64($0)) }, bytes)
            XCTAssertEqual(evaluator.state.byte(at: 0x803f), 0xa5)
            XCTAssertEqual(evaluator.state.byte(at: 0x8050), 0x5a)
            XCTAssertEqual(evaluator.state.sp, 0x8000)
        }
    }

    func testUnscaledNegativeSPOffsetAndUnalignedStoreInBothModes() throws {
        // imm9=0x1f0 sign-extends to -16; imm9=24 is not scaled by 16.
        // The high half contains both the top bit and a distinct low byte.
        let bytes: [UInt8] = [0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 1,
                             0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe]
        for mode in [false, true] {
            let f = try function([
                ("e0 03 df 3c", "ldur", "q0, [sp, #-16]"),
                ("e0 83 81 3c", "stur", "q0, [sp, #24]")
            ], ssa: mode)
            var initial = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8))); initial.sp = 0x8000
            install(bytes, at: 0x7ff0, in: &initial)
            initial.setByte(0xa5, at: 0x8017); initial.setByte(0x5a, at: 0x8028)
            var evaluator = MacIRConcreteEvaluator(function: f, state: initial)
            try evaluator.run(f.instructions)
            XCTAssertEqual(evaluator.state.v[0], .init(low: 0x0123456789abcdef, high: 0xfedcba9876543210))
            XCTAssertEqual((0..<16).map { evaluator.state.byte(at: 0x8018 + UInt64($0)) }, bytes)
            XCTAssertEqual(evaluator.state.byte(at: 0x8017), 0xa5)
            XCTAssertEqual(evaluator.state.byte(at: 0x8028), 0x5a)
            XCTAssertEqual(evaluator.state.sp, 0x8000)
        }
    }

    func testPairPreIndexStoreAndPostIndexLoadUseSixteenByteStrideInBothModes() throws {
        // imm7=-2 means -32: first Q at 0x7fe0, second at 0x7ff0.
        // The post-index load reads those old-SP addresses before restoring 0x8000.
        for mode in [false, true] {
            let f = try function([
                ("e0 07 bf ad", "stp", "q0, q1, [sp, #-32]!"),
                ("e2 0f c1 ac", "ldp", "q2, q3, [sp], #32")
            ], ssa: mode)
            var initial = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8))); initial.sp = 0x8000
            initial.v[0] = .init(low: 0x0706050403020100, high: 0x0f0e0d0c0b0a0908)
            initial.v[1] = .init(low: 0x8786858483828180, high: 0x8f8e8d8c8b8a8988)
            initial.v[2] = .init(low: .max, high: .max)
            initial.v[3] = .init(low: .max, high: .max)
            initial.setByte(0xa5, at: 0x7fdf); initial.setByte(0x5a, at: 0x8000)
            var evaluator = MacIRConcreteEvaluator(function: f, state: initial)
            try evaluator.run(f.instructions)
            XCTAssertEqual(evaluator.state.v[2], .init(low: 0x0706050403020100, high: 0x0f0e0d0c0b0a0908))
            XCTAssertEqual(evaluator.state.v[3], .init(low: 0x8786858483828180, high: 0x8f8e8d8c8b8a8988))
            XCTAssertEqual((0..<32).map { evaluator.state.byte(at: 0x7fe0 + UInt64($0)) },
                [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f])
            XCTAssertEqual(evaluator.state.byte(at: 0x7fdf), 0xa5)
            XCTAssertEqual(evaluator.state.byte(at: 0x8000), 0x5a)
            XCTAssertEqual(evaluator.state.sp, 0x8000)
        }
    }

    func testSingleWritebackAndFollowingScalarLoadUseUpdatedSPInBothModes() throws {
        // Pre-index loads 0x8010, post-index stores there, then scalar LDR
        // must read 0x8020 rather than a stale entry-SP stack slot at 0x8000.
        let vectorBytes: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
                                   0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0]
        for mode in [false, true] {
            let f = try function([
                ("e0 0f c1 3c", "ldr", "q0, [sp, #16]!"),
                ("e0 07 81 3c", "str", "q0, [sp], #16"),
                ("e0 03 40 f9", "ldr", "x0, [sp]")
            ], ssa: mode)
            var initial = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8))); initial.sp = 0x8000
            install(vectorBytes, at: 0x8010, in: &initial)
            install([0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 1], at: 0x8020, in: &initial)
            install([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], at: 0x8000, in: &initial)
            var evaluator = MacIRConcreteEvaluator(function: f, state: initial)
            try evaluator.run(f.instructions)
            XCTAssertEqual(evaluator.state.v[0], .init(low: 0x8877665544332211, high: 0x00ffeeddccbbaa99))
            XCTAssertEqual((0..<16).map { evaluator.state.byte(at: 0x8010 + UInt64($0)) }, vectorBytes)
            XCTAssertEqual(evaluator.state.x[0], 0x0123456789abcdef)
            XCTAssertEqual(evaluator.state.sp, 0x8020)
        }
    }

    func testRepeatedPairStorePreservesBothSPMemoryElementsInBothModes() throws {
        for mode in [false, true] {
            let f = try function([
                ("e0 03 01 ad", "stp", "q0, q0, [sp, #32]"),
                ("e2 0f 41 ad", "ldp", "q2, q3, [sp, #32]")
            ], ssa: mode)
            var initial = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8))); initial.sp = 0x8000
            initial.v[0] = .init(low: 0x8000000000000001, high: 0x0000000000000080)
            var evaluator = MacIRConcreteEvaluator(function: f, state: initial)
            try evaluator.run(f.instructions)
            XCTAssertEqual(evaluator.state.v[2], .init(low: 0x8000000000000001, high: 0x0000000000000080))
            XCTAssertEqual(evaluator.state.v[3], .init(low: 0x8000000000000001, high: 0x0000000000000080))
            XCTAssertEqual(evaluator.state.byte(at: 0x8020), 1)
            XCTAssertEqual(evaluator.state.byte(at: 0x8027), 0x80)
            XCTAssertEqual(evaluator.state.byte(at: 0x8028), 0x80)
            XCTAssertEqual(evaluator.state.byte(at: 0x8030), 1)
            XCTAssertEqual(evaluator.state.byte(at: 0x8037), 0x80)
            XCTAssertEqual(evaluator.state.byte(at: 0x8038), 0x80)
            XCTAssertEqual(evaluator.state.sp, 0x8000)
        }
    }

    func testUnavailableSPRemainsUnknownInsteadOfBecomingAnEntryStackSlot() throws {
        let source = MacIRSourceSpan(address: 0x1000, byteText: "e0 03 80 3d",
            mnemonic: "str", operands: "q0, [sp]")
        let exact = try XCTUnwrap(MacIRBuilder.ssaExactVector(source))
        var state = BuilderState()
        state.ssa = .init(current: [
            31: .init(value: .unknown("unavailable_sp"), bitWidth: 64, view: .integer,
                      origin: .refusal(.unknownEffects, 0x800)),
            32: .init(value: .immediate(1), bitWidth: 64, view: .bits, origin: .instruction(0x900)),
            64: .init(value: .immediate(2), bitWidth: 64, view: .bits, origin: .instruction(0x900))
        ], writes: [:], clobbers: [:])
        let emitted = try XCTUnwrap(MacIRBuilder.liftSSAExactVector(exact, source: source, state: &state))
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].operation, .store(source:
            .binaryExpression(op: "__ssa_join_vector_halves", left: .immediate(1), right: .immediate(2)),
            address: .unknown("unavailable_sp")))
        XCTAssertEqual(emitted[0].memoryAccess?.byteWidth, 16)
    }

}
