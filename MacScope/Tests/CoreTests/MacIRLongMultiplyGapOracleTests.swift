import Foundation
import XCTest
@testable import MacScope

/// Focused new vectors only. No historical oracle corpus or baseline replay.
final class MacIRLongMultiplyGapOracleTests: XCTestCase {
    private let vectors: [(UInt64, UInt64, UInt64)] = [
        (0, 0, 0), (1, 1, UInt64.max),
        (0xffff_ffff, 2, 9), (0x8000_0000, 0xffff_ffff, 0),
        (0x8000_0000, 0x8000_0000, 0xc000_0000_0000_0000),
        (0x7fff_ffff, 0x7fff_ffff, 0x8000_0000_0000_0000),
        (0xdead_beef_ffff_fffe, 0xabcd_1234_8000_0001, UInt64.max),
        (0xffff_ffff, 0xffff_ffff, 1)
    ]

    // Independent ISA reference: interpret low W words as mathematical signed
    // 32-bit values, multiply in Int64 (cannot overflow), then accumulate mod 2^64.
    private func reference(_ mnemonic: String, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> UInt64 {
        let product: UInt64
        if mnemonic == "umsubl" {
            product = UInt64(UInt32(truncatingIfNeeded: a)) * UInt64(UInt32(truncatingIfNeeded: b))
        } else {
            let x = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: a)))
            let y = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: b)))
            product = UInt64(bitPattern: x * y)
        }
        return mnemonic == "smaddl" ? c &+ product : c &- product
    }

    private func execute(_ mnemonic: String, _ operands: String, _ seed: [UInt64]) throws -> [UInt64] {
#if L1_PORTABLE
        return try L1PortableBridge.execute(mnemonic, operands, seed)
#else
        let row = InstructionRow(address: A64MachineState.defaultPC, bytes: "00 00 00 00",
            mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil)
        let function = MacIRBuilder().buildFunction(name: "long_multiply_gap", instructions: [row])
        var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
        state.x = seed
        state.nzcv = 0b1011
        let before = state
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        try evaluator.run(function.instructions)
        XCTAssertEqual(evaluator.state.nzcv, before.nzcv)
        XCTAssertEqual(evaluator.state.sp, before.sp)
        XCTAssertEqual(evaluator.state.v, before.v)
        XCTAssertEqual(evaluator.state.memory, before.memory)
        XCTAssertEqual(evaluator.state.pc, A64MachineState.defaultPC + 4)
        return evaluator.state.x
#endif
    }

    private func check(_ mnemonic: String) throws {
        for (a, b, c) in vectors {
            var seed = [UInt64](repeating: 0x1122_3344_5566_7788, count: 31)
            seed[1] = a; seed[2] = b; seed[3] = c
            let result = try execute(mnemonic, "x0, w1, w2, x3", seed)
            XCTAssertEqual(result[0], reference(mnemonic, a, b, c), "\(mnemonic) \(a), \(b), \(c)")
            XCTAssertEqual(Array(result.dropFirst()), Array(seed.dropFirst()))
        }
    }

    func testSignedAddLongBoundariesAndWrapping() throws { try check("smaddl") }
    func testSignedSubtractLongBoundariesAndWrapping() throws { try check("smsubl") }
    func testUnsignedSubtractLongBoundariesAndWrapping() throws { try check("umsubl") }

    func testAliasedSourcesAndZeroRegisters() throws {
        for mnemonic in ["smaddl", "smsubl", "umsubl"] {
            var seed = [UInt64](repeating: 0, count: 31)
            seed[1] = 0xaaaa_bbbb_ffff_fffd; seed[2] = 7; seed[3] = UInt64.max
            for destination in [1, 2, 3] {
                let result = try execute(mnemonic, "x\(destination), w1, w2, x3", seed)
                XCTAssertEqual(result[destination], reference(mnemonic, seed[1], seed[2], seed[3]))
                for i in 0..<31 where i != destination { XCTAssertEqual(result[i], seed[i]) }
            }
            XCTAssertEqual(try execute(mnemonic, "x0, wzr, w2, x3", seed)[0], seed[3])
            XCTAssertEqual(try execute(mnemonic, "x0, w1, wzr, xzr", seed)[0], 0)
            XCTAssertEqual(try execute(mnemonic, "xzr, w1, w2, x3", seed), seed)
        }
    }

    func testMalformedAndWrongWidthFormsRemainUnlifted() {
        let invalid = ["w0, w1, w2, x3", "x0, x1, w2, x3", "x0, w1, x2, x3",
            "x0, w1, w2, w3", "sp, w1, w2, x3", "x0, wsp, w2, x3",
            "x0, w1, w2, sp", "x31, w1, w2, x3", "x0, w32, w2, x3",
            "x0, w01, w2, x3", "x0, w+1, w2, x3", "x0, w1, w2",
            "x0, w1, w2, x3, lsl #1", "v0.2d, v1.2s, v2.2s, v3.2d"]
        for mnemonic in ["smaddl", "smsubl", "umsubl"] {
            for operands in invalid {
#if L1_PORTABLE
                XCTAssertNil(MacIRBuilder().l1Lift(mnemonic, operands), "\(mnemonic) \(operands)")
#else
                let row = InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: mnemonic,
                    operands: operands, hasBreakpoint: false, comment: nil)
                let function = MacIRBuilder().buildFunction(name: "reject", instructions: [row])
                guard case .unknown = function.instructions[0].operation else {
                    XCTFail("expected unknown for \(mnemonic) \(operands)"); continue
                }
#endif
            }
        }
    }
}
