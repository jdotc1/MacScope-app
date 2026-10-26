import XCTest
@testable import MacScope

final class MacIRNEONLaneMemoryTests: XCTestCase {
    func testConsecutiveStructureLaneRowsCarryTransferAndByteOrdinals() throws {
        let rows = [
            InstructionRow(address: 0x9000, bytes: "20 21 00 0d", mnemonic: "st3",
                           operands: "{v0.b, v1.b, v2.b}[0], [x9]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x9004, bytes: "23 21 00 0d", mnemonic: "st3",
                           operands: "{v3.b, v4.b, v5.b}[0], [x9]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x9008, bytes: "c0 03 5f d6", mnemonic: "ret",
                           operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "two_st3_lanes", instructions: rows)
        let first = try XCTUnwrap(function.instructions.first { $0.source.address == 0x9000 }?.neonStructureLaneMemory?.frame)
        let second = try XCTUnwrap(function.instructions.first { $0.source.address == 0x9004 }?.neonStructureLaneMemory?.frame)
        XCTAssertEqual([first.frameSequence, second.frameSequence], [0, 1])
        XCTAssertEqual([first.firstByteSequence, second.firstByteSequence], [0, 3])
        let input = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
            from: Data("{}".utf8)))
        let evaluator = MacIRConcreteEvaluator(function: function, state: input)
        try evaluator.validateNEONStructureLaneMemory(function.instructions)
    }

    func testExactFootprintComplementAndDelayedBase() throws {
        let f = try XCTUnwrap(MacIRNEONLaneMemory(effect:.load,elementBytes:2,laneIndex:0,
            baseRegister:"x0",oldBase:.register(name:"x0",version:0),oldVector:.register(name:"v31",version:0),
            destination:.register(name:"v31",version:1),baseDestination:.register(name:"x0",version:1),
            frameSequence:0,firstByteSequence:0))
        XCTAssertEqual(f.byteCount,2)
        XCTAssertEqual(f.preservedVectorBytes,Array(2..<16))
        XCTAssertEqual(f.fixedPostDelta,2)
        XCTAssertEqual(f.effectCount,2)
        XCTAssertNotNil(MacIRNEONLaneMemoryStep(frame:f,ordinal:1))
        XCTAssertNil(MacIRNEONLaneMemoryStep(frame:f,ordinal:2))
        XCTAssertNil(MacIRNEONLaneMemory(effect:.load,elementBytes:8,laneIndex:2,
            baseRegister:"x0",oldBase:.register(name:"x0",version:0),oldVector:.register(name:"v0",version:0),
            destination:.register(name:"v0",version:1),baseDestination:nil,frameSequence:0,firstByteSequence:0))
    }

    func testStructureLaneLD4PreservesOtherBytesAndSnapshotsSameBasePost() throws {
        let post = try XCTUnwrap(MacIRNEONContiguousRegisterPost(
            incrementRegister: "x9", oldIncrement: .register(name: "x9", version: 0)))
        let frame = try XCTUnwrap(MacIRNEONStructureLaneMemory(effect: .load,
            elementBytes: 2, laneIndex: 3, structureCount: 4,
            baseRegister: "x9", oldBase: .register(name: "x9", version: 0),
            oldVectors: [31,0,1,2].map { .register(name: "v\($0)", version: 0) },
            destinations: [31,0,1,2].map { .register(name: "v\($0)", version: 1) },
            baseDestination: .register(name: "x9", version: 1), frameSequence: 0,
            firstByteSequence: 0, registerPost: post))
        XCTAssertEqual(frame.byteCount, 8)
        XCTAssertEqual(frame.effectCount, 5)
        XCTAssertEqual(frame.fixedPostDelta, 0)
        XCTAssertEqual(frame.orderedBytes.map(\.vector), [0,0,1,1,2,2,3,3])
        XCTAssertEqual(frame.orderedBytes.map(\.lane), [6,7,6,7,6,7,6,7])
        XCTAssertEqual(frame.preservedVectorBytes, Array(0..<6) + Array(8..<16))
        var input = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
            from: Data("{}".utf8)))
        input.x[9] = 0x1000
        for byte in 0..<8 { input.setByte(UInt8(byte + 1), at: 0x1000 + UInt64(byte)) }
        for register in [31,0,1,2] {
            input.v[register] = .init(low: 0xaaaaaaaaaaaaaaaa, high: 0xbbbbbbbbbbbbbbbb)
        }
        let function = MacIRFunction(name: "ld4-lane", startAddress: 0x8300, instructions: [])
        var evaluator = MacIRConcreteEvaluator(function: function, state: input)
        try evaluator.executeNEONStructureLaneMemory(frame)
        XCTAssertEqual(evaluator.state.x[9], 0x2000)
        for (index, register) in [31,0,1,2].enumerated() {
            let low = UInt64(index * 2 + 1) << 48 | UInt64(index * 2 + 2) << 56 | 0xaaaaaaaaaaaa
            XCTAssertEqual(evaluator.state.v[register], .init(low: low, high: 0xbbbbbbbbbbbbbbbb))
        }
    }

    func testStructureLaneWrappedST3FromSPUsesSelectedLaneOnly() throws {
        let frame = try XCTUnwrap(MacIRNEONStructureLaneMemory(effect: .store,
            elementBytes: 4, laneIndex: 2, structureCount: 3,
            baseRegister: "sp", oldBase: .register(name: "sp", version: 0),
            oldVectors: [31,0,1].map { .register(name: "v\($0)", version: 0) },
            destinations: [], baseDestination: .register(name: "sp", version: 1),
            frameSequence: 0, firstByteSequence: 0))
        XCTAssertEqual(frame.byteCount, 12)
        XCTAssertEqual(frame.fixedPostDelta, 12)
        var input = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
            from: Data("{}".utf8)))
        input.sp = 0x3000
        input.v[31] = .init(low: 0, high: 0xaaa4aaa3aaa2aaa1)
        input.v[0] = .init(low: 0, high: 0xbbb4bbb3bbb2bbb1)
        input.v[1] = .init(low: 0, high: 0xccc4ccc3ccc2ccc1)
        let function = MacIRFunction(name: "st3-lane", startAddress: 0x8400, instructions: [])
        var evaluator = MacIRConcreteEvaluator(function: function, state: input)
        try evaluator.executeNEONStructureLaneMemory(frame)
        XCTAssertEqual(evaluator.state.sp, 0x300c)
        XCTAssertEqual((0..<12).map { evaluator.state.byte(at: 0x3000 + UInt64($0)) },
            [0xa1,0xaa,0xa2,0xaa,0xb1,0xbb,0xb2,0xbb,0xc1,0xcc,0xc2,0xcc])
    }
}
