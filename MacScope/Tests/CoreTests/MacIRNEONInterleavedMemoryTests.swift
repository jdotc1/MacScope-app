import XCTest
@testable import MacScope

/// New42 focused native source tests. Native target/execution remain owner-owned.
final class MacIRNEONInterleavedMemoryTests: XCTestCase {
    func testFourHalfwordLoadAndThreeHalfwordStoreExecuteExactBytes() throws {
        func machine() throws -> A64MachineState {
            try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
                from: Data("{}".utf8)))
        }
        func packed(_ bytes: [UInt8]) -> UInt64 {
            bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        let empty = MacIRFunction(name: "structure", startAddress: 0x8000, instructions: [])
        let load = try XCTUnwrap(MacIRNEONInterleavedMemory(effect: .load, activeBytes: 8,
            baseRegister: "x0", oldBase: .register(name: "x0", version: 0),
            vectors: (0..<4).map { .register(name: "v\($0)", version: 1) },
            baseDestination: .register(name: "x0", version: 1), firstByteSequence: 0,
            structureCount: 4, elementBytes: 2))
        var input = try machine()
        input.x[0] = 0x1000
        for offset in 0..<32 { input.setByte(UInt8(offset + 1), at: 0x1000 + UInt64(offset)) }
        for index in 0..<4 { input.v[index] = .init(low: 0xffff, high: 0xffff) }
        var reader = MacIRConcreteEvaluator(function: empty, state: input)
        try reader.executeNEONInterleavedMemory(load)
        XCTAssertEqual(reader.state.x[0], 0x1020)
        XCTAssertEqual(reader.state.v[0], .init(low: packed([1,2,9,10,17,18,25,26]), high: 0))
        XCTAssertEqual(reader.state.v[1], .init(low: packed([3,4,11,12,19,20,27,28]), high: 0))
        XCTAssertEqual(reader.state.v[2], .init(low: packed([5,6,13,14,21,22,29,30]), high: 0))
        XCTAssertEqual(reader.state.v[3], .init(low: packed([7,8,15,16,23,24,31,32]), high: 0))

        let store = try XCTUnwrap(MacIRNEONInterleavedMemory(effect: .store, activeBytes: 8,
            baseRegister: "x1", oldBase: .register(name: "x1", version: 0),
            vectors: (0..<3).map { .register(name: "v\($0)", version: 0) },
            baseDestination: nil, firstByteSequence: 0, structureCount: 3, elementBytes: 2))
        var output = try machine()
        output.x[1] = 0x2000
        output.v[0] = .init(low: packed([1,2,3,4,5,6,7,8]), high: 0)
        output.v[1] = .init(low: packed([11,12,13,14,15,16,17,18]), high: 0)
        output.v[2] = .init(low: packed([21,22,23,24,25,26,27,28]), high: 0)
        var writer = MacIRConcreteEvaluator(function: empty, state: output)
        try writer.executeNEONInterleavedMemory(store)
        XCTAssertEqual(writer.state.x[1], 0x2000)
        XCTAssertEqual((0..<24).map { writer.state.byte(at: 0x2000 + UInt64($0)) },
            [1,2,11,12,21,22,3,4,13,14,23,24,5,6,15,16,25,26,7,8,17,18,27,28])
    }

    func testWrapFrameHasExplicitByteOrderAndDelayedBase() throws {
        let d = try XCTUnwrap(MacIRNEONInterleavedMemory(effect: .load, activeBytes: 8,
            baseRegister: "x9", oldBase: .register(name: "x9", version: 0),
            vectors: [.register(name: "v31", version: 1), .register(name: "v0", version: 1)],
            baseDestination: .register(name: "x9", version: 1), firstByteSequence: 32))
        XCTAssertEqual(d.byteCount, 16)
        XCTAssertEqual(d.effectCount, 3)
        XCTAssertEqual(d.fixedPostDelta, 16)
        XCTAssertEqual(d.orderedBytes.map(\.sequence), Array(32..<48))
        XCTAssertEqual(d.orderedBytes.map(\.vector), (0..<16).map { $0%2 })
        XCTAssertEqual(d.orderedBytes.map(\.lane), (0..<16).map { $0/2 })
        XCTAssertEqual(Set([d,d]).count, 1)
        let step = try XCTUnwrap(MacIRNEONInterleavedMemoryStep(frame: d, ordinal: 2))
        XCTAssertEqual(step.identity(sourceAddress: 0x1234), .init(sourceAddress: 0x1234, effectOrdinal: 2))
        XCTAssertNil(MacIRNEONInterleavedMemoryStep(frame: d, ordinal: 3))
        XCTAssertNil(MacIRNEONInterleavedMemory(effect: .load, activeBytes: 8,
            baseRegister: "x9", oldBase: .register(name: "x9", version: 0),
            vectors: [.register(name: "v31", version: 1), .register(name: "v1", version: 1)],
            baseDestination: nil, firstByteSequence: 0))
    }

    func testRegisterPostSnapshotsSameBaseAndWrappedLD4() throws {
        let post = try XCTUnwrap(MacIRNEONContiguousRegisterPost(
            incrementRegister: "x9", oldIncrement: .register(name: "x9", version: 0)))
        let frame = try XCTUnwrap(MacIRNEONInterleavedMemory(effect: .load, activeBytes: 8,
            baseRegister: "x9", oldBase: .register(name: "x9", version: 0),
            vectors: [31,0,1,2].map { .register(name: "v\($0)", version: 1) },
            baseDestination: .register(name: "x9", version: 1), firstByteSequence: 0,
            structureCount: 4, elementBytes: 2, registerPost: post))
        XCTAssertEqual(frame.fixedPostDelta, 0)
        XCTAssertEqual(frame.byteCount, 32)
        var input = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
            from: Data("{}".utf8)))
        input.x[9] = 0x1000
        for offset in 0..<32 { input.setByte(UInt8(offset + 1), at: 0x1000 + UInt64(offset)) }
        let function = MacIRFunction(name: "ld4-post", startAddress: 0x8100, instructions: [])
        var evaluator = MacIRConcreteEvaluator(function: function, state: input)
        try evaluator.executeNEONInterleavedMemory(frame)
        // x9 is read as the increment before the delayed writeback to x9.
        XCTAssertEqual(evaluator.state.x[9], 0x2000)
        let expected: [[UInt8]] = [
            [1,2,9,10,17,18,25,26], [3,4,11,12,19,20,27,28],
            [5,6,13,14,21,22,29,30], [7,8,15,16,23,24,31,32]
        ]
        for (index, register) in [31,0,1,2].enumerated() {
            let low = expected[index].enumerated().reduce(UInt64(0)) {
                $0 | UInt64($1.element) << ($1.offset * 8)
            }
            XCTAssertEqual(evaluator.state.v[register], .init(low: low, high: 0))
        }
    }

    func testSPWrappedST3UsesOriginalBaseWithoutWriteback() throws {
        let frame = try XCTUnwrap(MacIRNEONInterleavedMemory(effect: .store, activeBytes: 8,
            baseRegister: "sp", oldBase: .register(name: "sp", version: 0),
            vectors: [31,0,1].map { .register(name: "v\($0)", version: 0) },
            baseDestination: nil, firstByteSequence: 0, structureCount: 3, elementBytes: 1))
        var input = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
            from: Data("{}".utf8)))
        input.sp = 0x3000
        input.v[31] = .init(low: 0x0807060504030201, high: 0)
        input.v[0] = .init(low: 0x1817161514131211, high: 0)
        input.v[1] = .init(low: 0x2827262524232221, high: 0)
        let function = MacIRFunction(name: "st3-sp", startAddress: 0x8200, instructions: [])
        var evaluator = MacIRConcreteEvaluator(function: function, state: input)
        try evaluator.executeNEONInterleavedMemory(frame)
        XCTAssertEqual(evaluator.state.sp, 0x3000)
        XCTAssertEqual((0..<24).map { evaluator.state.byte(at: 0x3000 + UInt64($0)) },
            [1,17,33,2,18,34,3,19,35,4,20,36,5,21,37,6,22,38,7,23,39,8,24,40])
    }
}
