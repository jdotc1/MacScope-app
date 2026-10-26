import XCTest
@testable import MacScope

final class MacIRVectorImmediateAndQStoreEffectsTests: XCTestCase {
    private func source(_ bytes: String, _ mnemonic: String, _ operands: String) -> MacIRSourceSpan {
        .init(address: 0x1000, byteText: bytes, mnemonic: mnemonic, operands: operands)
    }

    func testImmediateEncodingsHaveExactHalfValuesAndNoReads() throws {
        let cases: [(String, String, UInt64, UInt64)] = [
            ("00 e4 00 6f", "v0.2d, #0", 0, 0),
            ("20 e4 00 4f", "v0.16b, #1", 0x0101010101010101, 0x0101010101010101),
            ("20 e4 00 0f", "v0.8b, #1", 0x0101010101010101, 0),
            ("20 44 00 4f", "v0.4s, #1, lsl #16", 0x0001000000010000, 0x0001000000010000),
            ("20 e4 00 6f", "v0.2d, #0xff", 255, 255)
        ]
        for (bytes, operands, low, high) in cases {
            let row = source(bytes, "movi", operands)
            guard case let .immediate(register, value)? = MacIRBuilder.ssaExactVector(row) else {
                XCTFail("exact MOVI rejected: \(operands)"); continue
            }
            XCTAssertEqual(register, 0)
            XCTAssertEqual(value.low, low); XCTAssertEqual(value.high, high)
            let effects = MacIRBuilder.ssaEffects(for: row)
            XCTAssertEqual(effects.writes.map(\.cell), [32, 64])
            XCTAssertTrue(effects.readViews.isEmpty)
            XCTAssertTrue(effects.refusals.isEmpty)
        }
    }

    func testStoreEncodingsReadBothHalvesAndOnlyWriteMemoryAndWriteback() throws {
        let cases: [(String, String, String, [Int], [Int])] = [
            ("20 08 80 3d", "str", "q0, [x1, #32]", [1, 32, 64, 97], [97]),
            ("20 00 9f 3c", "stur", "q0, [x1, #-16]", [1, 32, 64, 97], [97]),
            ("40 04 01 ad", "stp", "q0, q1, [x2, #32]", [2, 32, 33, 64, 65, 97], [97]),
            ("40 04 bf ad", "stp", "q0, q1, [x2, #-32]!", [2, 32, 33, 64, 65, 97], [2, 97]),
            ("40 04 81 ac", "stp", "q0, q1, [x2], #32", [2, 32, 33, 64, 65, 97], [2, 97]),
            ("20 04 81 3c", "str", "q0, [x1], #16", [1, 32, 64, 97], [1, 97]),
            ("20 0c 81 3c", "str", "q0, [x1, #16]!", [1, 32, 64, 97], [1, 97])
        ]
        for (bytes, mnemonic, operands, reads, writes) in cases {
            let row = source(bytes, mnemonic, operands)
            XCTAssertNotNil(MacIRBuilder.ssaExactVector(row), operands)
            let effects = MacIRBuilder.ssaEffects(for: row)
            XCTAssertEqual(effects.readViews.keys.sorted(), reads, operands)
            XCTAssertEqual(effects.writes.map(\.cell), writes, operands)
            XCTAssertTrue(effects.refusals.isEmpty)
        }
    }

    func testPairStoreAddressesAndUpdateUseOldBaseAndBothPhiHalves() throws {
        for (bytes, text, firstOffset) in [
            ("40 04 bf ad", "q0, q1, [x2, #-32]!", Int64(-32)),
            ("40 04 81 ac", "q0, q1, [x2], #32", Int64(0))
        ] {
            let row = source(bytes, "stp", text)
            let exact = try XCTUnwrap(MacIRBuilder.ssaExactVector(row))
            let oldBase = MacIRValue.register(name: "x2", version: 3)
            let newBase = MacIRValue.register(name: "x2", version: 4)
            func half(_ name: String) -> MacIRSSAState.Binding {
                .init(value: .register(name: name, version: 2), bitWidth: 64,
                      view: .bits, origin: .phi(block: 1))
            }
            var state = BuilderState()
            state.ssa = .init(current: [
                2: .init(value: oldBase, bitWidth: 64, view: .integer, origin: .instruction(0x800)),
                32: half("lo0"), 64: half("hi0"), 33: half("lo1"), 65: half("hi1")
            ], writes: [2: .init(value: newBase, bitWidth: 64, view: .integer, origin: .instruction(0x1000))], clobbers: [:])
            let expectedValues = [state.readRegister("q0"), state.readRegister("q1")]
            let emitted = try XCTUnwrap(MacIRBuilder.liftSSAExactVector(exact, source: row, state: &state))
            XCTAssertEqual(emitted.count, 3)
            for index in 0..<2 {
                let delta = firstOffset + Int64(index * 16)
                let address: MacIRValue = delta == 0 ? oldBase
                    : .binaryExpression(op: "+", left: oldBase, right: .immediate(delta))
                XCTAssertEqual(emitted[index].operation, .store(source: expectedValues[index], address: address))
                XCTAssertEqual(emitted[index].memoryAccess?.byteWidth, 16)
                guard case .binaryExpression(op: "__ssa_join_vector_halves", left: _, right: _) = expectedValues[index] else {
                    XCTFail("both phi halves must feed the store"); continue
                }
            }
            XCTAssertEqual(emitted[2].operation, .assign(destination: newBase,
                source: .binaryExpression(op: "+", left: oldBase, right: .immediate(firstOffset == 0 ? 32 : -32))))
            XCTAssertNil(emitted[2].memoryAccess)
        }
    }

    func testRepeatedRegisterPairKeepsBothStores() throws {
        let row = source("40 00 01 ad", "stp", "q0, q0, [x2, #32]")
        let exact = try XCTUnwrap(MacIRBuilder.ssaExactVector(row))
        var state = BuilderState()
        let base = MacIRValue.register(name: "x2", version: 1)
        state.ssa = .init(current: [
            2: .init(value: base, bitWidth: 64, view: .integer, origin: .instruction(0x800)),
            32: .init(value: .immediate(7), bitWidth: 64, view: .bits, origin: .instruction(0x900)),
            64: .init(value: .immediate(11), bitWidth: 64, view: .bits, origin: .instruction(0x900))
        ], writes: [:], clobbers: [:])
        let value = state.readRegister("q0")
        let emitted = try XCTUnwrap(MacIRBuilder.liftSSAExactVector(exact, source: row, state: &state))
        XCTAssertEqual(emitted.count, 2)
        for index in 0..<2 {
            XCTAssertEqual(emitted[index].operation, .store(source: value,
                address: .binaryExpression(op: "+", left: base, right: .immediate(Int64(32 + index * 16)))))
            XCTAssertEqual(emitted[index].memoryAccess?.byteWidth, 16)
        }
        let effects = MacIRBuilder.ssaEffects(for: row)
        XCTAssertEqual(effects.readViews.keys.sorted(), [2, 32, 64, 97])
        XCTAssertEqual(effects.writes.map(\.cell), [97])
    }

    func testUnavailableUpperHalfIsNeverInventedByStore() throws {
        let row = source("20 08 80 3d", "str", "q0, [x1, #32]")
        let exact = try XCTUnwrap(MacIRBuilder.ssaExactVector(row))
        var state = BuilderState()
        state.ssa = .init(current: [
            1: .init(value: .register(name: "x1", version: 0), bitWidth: 64, view: .integer, origin: .entry),
            32: .init(value: .immediate(7), bitWidth: 64, view: .bits, origin: .instruction(0x800)),
            64: .init(value: .unknown("unavailable_upper"), bitWidth: 64, view: .bits, origin: .callClobber(0x900))
        ], writes: [:], clobbers: [:])
        let emitted = try XCTUnwrap(MacIRBuilder.liftSSAExactVector(exact, source: row, state: &state))
        guard case let .store(value, _) = emitted[0].operation else { return XCTFail("store required") }
        XCTAssertEqual(value, .unknown("unavailable_upper"))
    }

    func testSSAIntegrationMaterializesConstantsWithoutWideResplitting() throws {
        for (bytes, operands, highValue, expectedCount) in [
            ("20 e4 00 4f", "v0.16b, #1", UInt64(0x0101010101010101), 2),
            ("20 e4 00 0f", "v0.8b, #1", UInt64(0), 1)
        ] {
            let rows = [
                InstructionRow(address: 0x1000, bytes: bytes, mnemonic: "movi", operands: operands, hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1004, bytes: "20 08 80 3d", mnemonic: "str", operands: "q0, [x1, #32]", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
            ]
            let function = try XCTUnwrap(MacIRBuilder(ssaEnabled: true).buildSSAFunction(
                name: "exact_vector", startAddress: 0x1000, rows: rows, initialState: BuilderState(),
                jumpTables: [:], recoveredSwitches: [:], tailCalls: [:], isVariadic: false,
                slotCallContracts: [:], slotCallSignatures: [:], knownTailCallTargets: [:]))
            XCTAssertFalse(function.refusals.contains {
                $0.reason == .unknownEffects && ($0.scope == .row(0x1000) || $0.scope == .row(0x1004))
            })
            let info = try XCTUnwrap(function.ssaInfo)
            let lowID = try XCTUnwrap(info.plan.rowWriteBindings[0][32])
            let highID = try XCTUnwrap(info.plan.rowWriteBindings[0][64])
            let low = try XCTUnwrap(info.values[lowID]), high = try XCTUnwrap(info.values[highID])
            let constants = function.instructions.filter { $0.source.address == 0x1000 }
            XCTAssertEqual(constants.count, expectedCount)
            XCTAssertEqual(constants[0].operation, .assign(destination: low, source: .immediate(0x0101010101010101)))
            if expectedCount == 2 {
                XCTAssertEqual(constants[1].operation, .assign(destination: high, source: .immediate(Int64(bitPattern: highValue))))
            } else { XCTAssertEqual(high, .immediate(0)) }
            let store = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1004 })
            guard case let .store(value, _) = store.operation else { return XCTFail("typed store required") }
            XCTAssertEqual(value, .binaryExpression(op: "__ssa_join_vector_halves", left: low, right: high))
            XCTAssertEqual(store.memoryAccess?.byteWidth, 16)
        }
    }

    func testStackStoreEncodingReadsSPAndBothVectorHalves() throws {
        let row = source("e0 0b 80 3d", "str", "q0, [sp, #32]")
        XCTAssertNotNil(MacIRBuilder.ssaExactVector(row))
        let effects = MacIRBuilder.ssaEffects(for: row)
        XCTAssertEqual(effects.readViews.keys.sorted(), [31, 32, 64, 97])
        XCTAssertEqual(effects.writes.map(\.cell), [97])
        XCTAssertTrue(effects.refusals.isEmpty)
    }

    func testUnsupportedOrDisagreeingFormsRemainOutsideAdmission() {
        let cases: [(String, String, String)] = [
            ("", "movi", "v0.16b, #1"),
            ("20 e4 00 4f", "movi", "v1.16b, #1"),
            ("20 e4 00 4f", "movi", "v0.16b, #2"),
            ("20 e4 00 4f", "mvni", "v0.16b, #1"),
            ("20 e4 00 2f", "movi", "d0, #0xff"),
            ("20 08 80 3d", "str", "q0, [x1, #16]"),
            ("20 08 80 3d", "str", "q0, [x1, #--32]"),
            ("20 08 80 3d", "str", "q0, [x1, x2]"),
            ("40 04 01 ac", "stnp", "q0, q1, [x2, #32]"),
            ("20 00 9f 3c", "stur", "d0, [x1, #-16]"),
            ("20 08 80 3d 00", "str", "q0, [x1, #32]")
        ]
        for (bytes, mnemonic, operands) in cases {
            XCTAssertNil(MacIRBuilder.ssaExactVector(source(bytes, mnemonic, operands)), operands)
        }
    }
}
