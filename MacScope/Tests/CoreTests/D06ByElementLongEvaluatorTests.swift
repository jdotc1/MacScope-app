import Foundation
import XCTest
@testable import MacScope

/// The concrete oracle consumer already snapshots every SSA input and delegates
/// to MacIRNEONLaneOp. These checks pin unary arity and destination aliases on
/// that real consumer, without adding a second mnemonic interpreter.
final class D06ByElementLongEvaluatorTests: XCTestCase {
    func testAliasedAccumulateSnapshotsOldDestinationAndElement() throws {
        let descriptor = try XCTUnwrap(MacIRNEONLaneOp(kind: .mlal, isSigned: false,
            laneBits: 32, highHalf: false, elementIndex: 3))
        let seed = A64OracleVector.State(gpr: nil, sp: nil, pc: nil, nzcv: nil,
            fpcr: nil, fpsr: "0x08000000", vectors: ["V0": "0xffffffffffffffffffffffffffffffff"], memory: nil)
        let state = try A64MachineState(seeding: seed)
        let function = MacIRBuilder().buildFunction(name: "alias", startAddress: 0x400100, instructions: [
            InstructionRow(address: 0x400100, bytes: "", mnemonic: "umlal", operands: "v0.2d, v0.2s, v0.s[3]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x400104, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ])
        let lane = try XCTUnwrap(function.instructions.first { $0.neonLaneOp != nil })
        XCTAssertEqual(lane.neonLaneOp, descriptor)
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        try evaluator.run([lane])
        XCTAssertEqual(evaluator.state.v[0].low, 0xffff_fffe_0000_0000)
        XCTAssertEqual(evaluator.state.v[0].high, 0xffff_fffe_0000_0000)
        XCTAssertEqual(evaluator.state.fpsr, 0x08000000)
    }

    func testUnaryImmediateClearsUpperHalfAndPreservesFPSR() throws {
        let descriptor = try XCTUnwrap(MacIRNEONLaneOp(kind: .srshr, isSigned: false,
            laneBits: 16, highHalf: false, activeBytes: 8, shift: 16))
        let seed = A64OracleVector.State(gpr: nil, sp: nil, pc: nil, nzcv: nil,
            fpcr: nil, fpsr: "0x08000000", vectors: ["V0": "0xffffffffffffffff8000800080008000"], memory: nil)
        var evaluator = MacIRConcreteEvaluator(function: MacIRFunction(name: "unary", startAddress: 0x400100, instructions: []), state: try A64MachineState(seeding: seed))
        try evaluator.executeNEONLaneOp(descriptor, operation: .intrinsic(destination: .register(name: "v0", version: 1),
            name: descriptor.intrinsicName, arguments: [.register(name: "v0", version: 0)]))
        XCTAssertEqual(evaluator.state.v[0].low, 0)
        XCTAssertEqual(evaluator.state.v[0].high, 0)
        XCTAssertEqual(evaluator.state.fpsr, 0x08000000)
    }
}
