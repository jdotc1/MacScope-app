import Foundation
import XCTest
@testable import MacScope

extension MacIRSSATests {
    private struct WidthJoinVector {
        let id: String
        let bytes: String
        let registers: [Int: UInt64]
        let expectedX8: UInt64
        let phiWidth: Int
    }

    // Fixed raw-byte proposals with independent full-register expected values.
    // The production decoder and the existing concrete CFG evaluator execute them.
    private var widthJoinVectors: [WidthJoinVector] {
        [
            .init(id: "high_incoming_W",
                  bytes: "60 00 00 b4 e8 03 01 2a 02 00 00 14 e8 03 02 aa e0 03 08 aa c0 03 5f d6",
                  registers: [0: 0x0000000000000001, 1: 0xa5a5a5a512345678, 2: 0x1122334455667788, 8: 0xdeadbeeffeedface, 30: 0x0000000000002000],
                  expectedX8: 0x0000000012345678, phiWidth: 64),
            .init(id: "high_incoming_X",
                  bytes: "60 00 00 b4 e8 03 01 2a 02 00 00 14 e8 03 02 aa e0 03 08 aa c0 03 5f d6",
                  registers: [1: 0xa5a5a5a512345678, 2: 0x1122334455667788, 8: 0xdeadbeeffeedface, 30: 0x0000000000002000],
                  expectedX8: 0x1122334455667788, phiWidth: 64),
            .init(id: "bit31_set_W",
                  bytes: "60 00 00 b4 08 00 b0 52 02 00 00 14 e8 03 02 aa e0 03 08 aa c0 03 5f d6",
                  registers: [0: 0x0000000000000001, 2: 0x1234567880000000, 8: 0xffffffffffffffff, 30: 0x0000000000002000],
                  expectedX8: 0x0000000080000000, phiWidth: 64),
            .init(id: "bit31_set_X",
                  bytes: "60 00 00 b4 08 00 b0 52 02 00 00 14 e8 03 02 aa e0 03 08 aa c0 03 5f d6",
                  registers: [2: 0x1234567880000000, 8: 0xffffffffffffffff, 30: 0x0000000000002000],
                  expectedX8: 0x1234567880000000, phiWidth: 64),
            .init(id: "word_overflow_W",
                  bytes: "60 00 00 b4 28 04 00 11 02 00 00 14 48 04 00 91 e0 03 08 aa c0 03 5f d6",
                  registers: [0: 0x0000000000000001, 1: 0x12345678ffffffff, 2: 0x76543210ffffffff, 8: 0xdeadbeef11111111, 30: 0x0000000000002000],
                  expectedX8: 0x0000000000000000, phiWidth: 64),
            .init(id: "word_overflow_X",
                  bytes: "60 00 00 b4 28 04 00 11 02 00 00 14 48 04 00 91 e0 03 08 aa c0 03 5f d6",
                  registers: [1: 0x12345678ffffffff, 2: 0x76543210ffffffff, 8: 0xdeadbeef11111111, 30: 0x0000000000002000],
                  expectedX8: 0x7654321100000000, phiWidth: 64),
            .init(id: "preserve_x_high_W",
                  bytes: "60 00 00 b4 08 05 00 11 02 00 00 14 08 05 00 91 e0 03 08 aa c0 03 5f d6",
                  registers: [0: 0x0000000000000001, 8: 0x89abcdef7fffffff, 30: 0x0000000000002000],
                  expectedX8: 0x0000000080000000, phiWidth: 64),
            .init(id: "preserve_x_high_X",
                  bytes: "60 00 00 b4 08 05 00 11 02 00 00 14 08 05 00 91 e0 03 08 aa c0 03 5f d6",
                  registers: [8: 0x89abcdef7fffffff, 30: 0x0000000000002000],
                  expectedX8: 0x89abcdef80000000, phiWidth: 64),
            .init(id: "all_word_join_W",
                  bytes: "60 00 00 b4 e8 03 01 2a 02 00 00 14 e8 03 02 2a e0 03 08 aa c0 03 5f d6",
                  registers: [0: 0x0000000000000001, 1: 0xffff111180000001, 2: 0x22223333ffffffff, 8: 0xdeadbeef55555555, 30: 0x0000000000002000],
                  expectedX8: 0x0000000080000001, phiWidth: 32),
            .init(id: "all_word_join_W2",
                  bytes: "60 00 00 b4 e8 03 01 2a 02 00 00 14 e8 03 02 2a e0 03 08 aa c0 03 5f d6",
                  registers: [1: 0xffff111180000001, 2: 0x22223333ffffffff, 8: 0xdeadbeef55555555, 30: 0x0000000000002000],
                  expectedX8: 0x00000000ffffffff, phiWidth: 32),
        ]
    }

    private func decodedWidthRows(_ bytes: String) throws -> [InstructionRow] {
        let data = try XCTUnwrap(A64OracleHex.bytes(bytes.replacingOccurrences(of: " ", with: "")))
        let decoded = ARM64Decoder().decode(Data(data), baseAddress: 0x1000,
                                            maxInstructionCount: data.count / 4)
        XCTAssertEqual(decoded.count, data.count / 4)
        XCTAssertFalse(decoded.contains { $0.mnemonic == "unknown" || $0.mnemonic == "unavailable" })
        return decoded.map {
            InstructionRow(address: $0.address, bytes: $0.byteText, mnemonic: $0.mnemonic,
                           operands: $0.operands, hasBreakpoint: false, comment: $0.comment)
        }
    }

    func testDecodedWidthJoinVectorsPreserveAllSixtyFourBits() throws {
        for vector in widthJoinVectors {
            let rows = try decodedWidthRows(vector.bytes)
            let function = MacIRBuilder(ssaEnabled: true).buildFunction(
                name: "width_join", startAddress: 0x1000,
                callerReturnWidth: .x0, instructions: rows)
            XCTAssertNotNil(function.ssaInfo, vector.id)
            let phi = try XCTUnwrap(SSAPropertyAssertions.phi(function, block: 0x1010,
                cell: 8, width: vector.phiWidth,
                incoming: [(0x1008, 0x1004), (0x100c, 0x100c)]), vector.id)
            let move = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1010 }, vector.id)
            guard case let .assign(_, source) = move.operation else {
                return XCTFail("\(vector.id): join must retain its architectural X read")
            }
            SSAPropertyAssertions.assertView(source, of: phi, width: 64)
            SSAPropertyAssertions.assertOrdinaryUsesDominated(function)
            var initial = try A64MachineState(seeding:
                JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
            initial.pc = 0x1000
            initial.sp = 0x8000
            initial.nzcv = 0
            for (register, value) in vector.registers { initial.x[register] = value }
            var evaluator = MacIRConcreteEvaluator(function: function, state: initial)
            do {
                try evaluator.runScalarCFG(function.instructions)
            } catch {
                XCTFail("\(vector.id): raw-byte vector could not execute: \(error)")
                throw error
            }
            XCTAssertEqual(evaluator.state.x[8], vector.expectedX8, vector.id)
            XCTAssertEqual(evaluator.state.x[0], vector.expectedX8, vector.id)
            XCTAssertEqual(evaluator.state.x[3], 0, vector.id)
            XCTAssertEqual(evaluator.state.x[4], 0, vector.id)
            XCTAssertEqual(evaluator.state.pc, initial.x[30], vector.id)
            XCTAssertEqual(evaluator.state.memory, initial.memory, vector.id)
        }
    }

    func testDecodedMixedWidthEntryLoopRecordsItsRequiredRefusal() throws {
        let rows = try decodedWidthRows(
            "60 00 00 b4 08 05 00 11 02 00 00 14 08 05 00 91 e3 03 08 aa 84 04 00 d1 44 ff ff b5 e0 03 08 aa c0 03 5f d6")
        let function = MacIRBuilder(ssaEnabled: true).buildFunction(
            name: "mixed_width_entry_loop", startAddress: 0x1000,
            callerReturnWidth: .x0, instructions: rows)
        XCTAssertNil(function.ssaInfo,
                     "the decoded backedge targets entry, so this fixture cannot certify SSA loop values")
        XCTAssertTrue(function.refusals.contains {
            $0.scope == .function && $0.detail == "entry block has an in-graph predecessor"
        })
    }

    func testVectorHalfExtractionPreservesBitsAndRejectsScalarInputs() throws {
        let rows = try decodedWidthRows("c0 03 5f d6")
        let function = MacIRBuilder(ssaEnabled: false).buildFunction(name: "half_extract", instructions: rows)
        var initial = try A64MachineState(seeding:
            JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
        initial.v[8] = .init(low: 0x7ff8_0000_0000_1234, high: 0xfedc_ba98_7654_3210)
        var evaluator = MacIRConcreteEvaluator(function: function, state: initial)
        let vector = MacIRValue.register(name: "v8", version: 0)
        let low = try evaluator.evaluate(.unary(op: "__ssa_low64", value: vector))
        let high = try evaluator.evaluate(.unary(op: "__ssa_high64", value: vector))
        XCTAssertEqual(low.bits, initial.v[8].low)
        XCTAssertEqual(high.bits, initial.v[8].high)
        XCTAssertEqual(low.width, 64)
        XCTAssertEqual(high.width, 64)
        XCTAssertEqual(low.kind, .unsigned)
        XCTAssertEqual(high.kind, .unsigned)
        let roundTrip = try evaluator.evaluate(.binaryExpression(op: "__ssa_join_vector_halves",
            left: .unary(op: "__ssa_low64", value: vector),
            right: .unary(op: "__ssa_high64", value: vector)))
        XCTAssertEqual(roundTrip.bits, initial.v[8].low)
        XCTAssertEqual(roundTrip.high, initial.v[8].high)
        XCTAssertEqual(roundTrip.width, 128)
        XCTAssertEqual(roundTrip.kind, .unsigned)
        for op in ["__ssa_low64", "__ssa_high64"] {
            XCTAssertThrowsError(try evaluator.evaluate(.unary(op: op, value: .immediate(7)))) { error in
                XCTAssertEqual(error as? MacIRConcreteEvaluator.Failure,
                    .unsupported("vector half extraction requires a 128-bit value"))
            }
        }
    }

    func testEvaluatorWritesOnlyTheNamedSSARegisterHalf() throws {
        let rows = try decodedWidthRows("c0 03 5f d6")
        let retained = MacIRBuilder(ssaEnabled: false).buildFunction(name: "half_writes", instructions: rows)
        var function = retained
        let low = MacIRValue.register(name: "v8", version: 1)
        let high = MacIRValue.register(name: "vh8", version: 1)
        let lowEntry = MacIRValue.register(name: "v8", version: 0)
        let highEntry = MacIRValue.register(name: "vh8", version: 0)
        let floating = MacIRValue.register(name: "d9", version: 1)
        let definitions: [MacIRSSA.Definition] = [
            .init(id: 0, cell: 40, bitWidth: 64, view: .bits, origin: .instruction(0x1000)),
            .init(id: 1, cell: 72, bitWidth: 64, view: .bits, origin: .instruction(0x1000)),
            .init(id: 2, cell: 40, bitWidth: 64, view: .bits, origin: .entry),
            .init(id: 3, cell: 72, bitWidth: 64, view: .bits, origin: .entry),
            .init(id: 4, cell: 41, bitWidth: 64, view: .float64, origin: .instruction(0x1004))
        ]
        function.ssaInfo = .init(plan: .init(definitions: definitions, phis: [],
            rowReadBindings: [], rowWriteBindings: [], blockEntryBindings: [], blockExitBindings: [],
            liveIn: [], liveOut: [], aliases: [:], refusals: []),
            values: [0: low, 1: high, 2: lowEntry, 3: highEntry, 4: floating], sourceAddresses: [])
        var initial = try A64MachineState(seeding:
            JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
        initial.v[8] = .init(low: 0x0123_4567_89ab_cdef, high: 0xfedc_ba98_7654_3210)
        initial.v[9] = .init(low: 0, high: .max)
        var evaluator = MacIRConcreteEvaluator(function: function, state: initial)
        let entryLow = try evaluator.evaluate(lowEntry)
        let entryHigh = try evaluator.evaluate(highEntry)
        XCTAssertEqual(entryLow.bits, initial.v[8].low)
        XCTAssertEqual(entryHigh.bits, initial.v[8].high)
        XCTAssertEqual(entryLow.width, 64)
        XCTAssertEqual(entryHigh.width, 64)
        XCTAssertEqual(entryLow.kind, .unsigned)
        XCTAssertEqual(entryHigh.kind, .unsigned)
        let payload: UInt64 = 0x7ff8_0000_0000_1234
        try evaluator.write(low, .init(bits: payload, width: 64, kind: .float))
        XCTAssertEqual(evaluator.state.v[8].low, payload)
        XCTAssertEqual(evaluator.state.v[8].high, initial.v[8].high)
        let storedLow = try evaluator.evaluate(low)
        XCTAssertEqual(storedLow.bits, payload)
        XCTAssertEqual(storedLow.width, 64)
        XCTAssertEqual(storedLow.kind, .unsigned)
        try evaluator.write(high, .init(bits: 0x8000_0000_0000_0001, width: 64, kind: .unsigned))
        XCTAssertEqual(evaluator.state.v[8].low, payload)
        XCTAssertEqual(evaluator.state.v[8].high, 0x8000_0000_0000_0001)
        let storedHigh = try evaluator.evaluate(high)
        XCTAssertEqual(storedHigh.bits, 0x8000_0000_0000_0001)
        XCTAssertEqual(storedHigh.width, 64)
        XCTAssertEqual(storedHigh.kind, .unsigned)
        try evaluator.write(floating, .int(2, width: 64, signed: true))
        XCTAssertEqual(evaluator.state.v[9].low, Double(2).bitPattern)
        XCTAssertEqual(evaluator.state.v[9].high, 0)
        XCTAssertEqual(try evaluator.evaluate(floating).kind, .float)
        var withoutSSA = MacIRConcreteEvaluator(function: retained, state: initial)
        try withoutSSA.write(low, .int(payload, width: 64, signed: false))
        XCTAssertEqual(withoutSSA.state.v[8].low, payload)
        XCTAssertEqual(withoutSSA.state.v[8].high, 0)
        XCTAssertEqual(try withoutSSA.evaluate(low).width, 128)
        XCTAssertThrowsError(try withoutSSA.write(high, .int(7, width: 64, signed: false)))
    }

}
