import Foundation
import XCTest
@testable import MacScope

final class MacIRSemanticFidelityTests: XCTestCase {
    private func run(_ mnemonic: String, _ operands: String, seed: (inout A64MachineState) -> Void) throws -> A64MachineState {
        var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
        seed(&state)
        var function = MacIRBuilder().buildFunction(name: "fidelity", instructions: [InstructionRow(address: A64MachineState.defaultPC, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil)])
        // Execution must use semantic IR, never the original assembly spelling.
        for index in function.instructions.indices {
            function.instructions[index].source.mnemonic = "redacted"
            function.instructions[index].source.operands = ""
        }
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        try evaluator.run(function.instructions)
        return evaluator.state
    }

    func testByteLoadHasExplicitZeroExtension() throws {
        let final = try run("ldrb", "w0, [x1]") { state in
            state.x[1] = 0x500080
            state.memory[0x500080] = 0x80
            state.memory[0x500081] = 0x7f
        }
        XCTAssertEqual(final.x[0], 0x80)
    }

    func testSignedHalfLoadSignExtendsToXRegister() throws {
        let final = try run("ldrsh", "x0, [x1]") { state in
            state.x[1] = 0x500080
            state.memory[0x500080] = 1
            state.memory[0x500081] = 0x80
        }
        XCTAssertEqual(final.x[0], 0xffffffffffff8001)
    }

    func testByteZeroStorePreservesAdjacentBytes() throws {
        let final = try run("strb", "wzr, [x1]") { state in
            state.x[1] = 0x500080
            for offset in 0..<8 { state.memory[0x500080 + UInt64(offset)] = 0xa5 }
        }
        XCTAssertEqual(final.byte(at: 0x500080), 0)
        for offset in 1..<8 { XCTAssertEqual(final.byte(at: 0x500080 + UInt64(offset)), 0xa5) }
    }

    func testSignedPairUsesFourByteStride() throws {
        let final = try run("ldpsw", "x0, x1, [x2]") { state in
            state.x[2] = 0x500080
            for (offset, byte) in [0, 0, 0, 0x80, 1, 0, 0, 0x80].enumerated() { state.memory[0x500080 + UInt64(offset)] = UInt8(byte) }
        }
        XCTAssertEqual(final.x[0], 0xffffffff80000000)
        XCTAssertEqual(final.x[1], 0xffffffff80000001)
    }
    func testLogicalRightShiftUsesBitPattern() throws {
        let final = try run("lsr", "x0, x1, #63") { $0.x[1] = 0x8000000000000000 }
        XCTAssertEqual(final.x[0], 1)
    }

    func testUnsignedDivisionAndArchitecturalExceptionalResults() throws {
        let high = try run("udiv", "x0, x1, x2") { $0.x[1] = UInt64.max; $0.x[2] = 2 }
        XCTAssertEqual(high.x[0], UInt64.max / 2)
        let zero = try run("udiv", "w0, w1, w2") { $0.x[1] = 19 }
        XCTAssertEqual(zero.x[0], 0)
        let overflow = try run("sdiv", "x0, x1, x2") { $0.x[1] = 0x8000000000000000; $0.x[2] = UInt64.max }
        XCTAssertEqual(overflow.x[0], 0x8000000000000000)
    }

    func testExplicitReturnTargetSurvivesSourceRedaction() throws {
        let final = try run("ret", "x7") { $0.x[7] = 0x400110; $0.x[30] = 0x400120 }
        XCTAssertEqual(final.pc, 0x400110)
    }

    func testSPByteLoadPreAndPostIndexWriteback() throws {
        let pre = try run("ldrsb", "x0, [sp, #3]!") { $0.sp = 0x500080; $0.memory[0x500083] = 0x80 }
        XCTAssertEqual(pre.sp, 0x500083)
        XCTAssertEqual(pre.x[0], 0xffffffffffffff80)
        let post = try run("ldrb", "w0, [sp], #3") { $0.sp = 0x500080; $0.memory[0x500080] = 0xfe }
        XCTAssertEqual(post.sp, 0x500083)
        XCTAssertEqual(post.x[0], 0xfe)
    }

    func testSPWritebackThenPlainAccessUsesUpdatedBase() throws {
        for rows in [[("str", "x0, [sp, #-16]!"), ("ldr", "x1, [sp]")],
                     [("str", "x0, [sp], #16"), ("ldr", "x1, [sp, #-16]")],
                     [("str", "x0, [sp, #-16]!"), ("mov", "x29, sp"), ("ldr", "x1, [x29]")],
                     [("stp", "x0, x2, [sp, #-16]!"), ("ldr", "x1, [sp]")],
                     [("sub", "sp, sp, #32"), ("str", "x0, [sp, #-16]!"), ("ldr", "x1, [sp]")],
                     [("str", "x0, [sp, #-16]!"), ("add", "sp, sp, #16"), ("ldr", "x1, [sp, #-16]")],
                     [("str", "x0, [sp, #-16]!"), ("str", "x0, [sp, #-16]!"), ("ldr", "x1, [sp]")]] {
            var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
            state.sp = 0x500080
            state.x[0] = 0x12345678
            var function = MacIRBuilder().buildFunction(name: "sequence", instructions: rows.enumerated().map { index, row in
                InstructionRow(address: A64MachineState.defaultPC + UInt64(index * 4), bytes: "00 00 00 00", mnemonic: row.0, operands: row.1, hasBreakpoint: false, comment: nil)
            })
            for index in function.instructions.indices {
                function.instructions[index].source.mnemonic = "redacted"
                function.instructions[index].source.operands = ""
            }
            var evaluator = MacIRConcreteEvaluator(function: function, state: state)
            try evaluator.run(function.instructions)
            XCTAssertEqual(evaluator.state.x[1], 0x12345678, "\(rows)")
        }
    }

    func testReturnTargetBindingIsAudited() {
        var function = MacIRBuilder().buildFunction(name: "target_binding", instructions: [InstructionRow(address: 0x1000, bytes: "", mnemonic: "ret", operands: "x7", hasBreakpoint: false, comment: nil)])
        function.instructions[0].operation = .returnValue(nil)
        function.instructions[0].returnTarget = .argument(bindingID: .gpr(7))
        let audit = function.parameterBindingAudit()
        XCTAssertTrue(audit.records.contains { $0.bodyUses.contains { $0.address == 0x1000 } } || !audit.danglingBodyUses.isEmpty)
        function.parameters = []
        XCTAssertEqual(function.parameterBindingAudit().danglingBodyUses.count, 1)
    }

    func testSPPairWritebackTransfersThenUpdatesBase() throws {
        let stored = try run("stp", "x0, x1, [sp, #-16]!") { $0.sp = 0x500080; $0.x[0] = 0x12; $0.x[1] = 0x34 }
        XCTAssertEqual(stored.sp, 0x500070)
        XCTAssertEqual(stored.byte(at: 0x500070), 0x12)
        XCTAssertEqual(stored.byte(at: 0x500078), 0x34)
        for (mnemonic, operands, stride) in [("ldp", "x0, x1, [sp], #16", 8), ("ldpsw", "x0, x1, [sp], #16", 4)] {
            let loaded = try run(mnemonic, operands) { state in
                state.sp = 0x500080
                state.memory[0x500080] = 0x56
                state.memory[0x500080 + UInt64(stride)] = 0x78
            }
            XCTAssertEqual(loaded.sp, 0x500090)
            XCTAssertEqual(loaded.x[0], 0x56)
            XCTAssertEqual(loaded.x[1], 0x78)
        }
    }

    func testDivisionMSUBRemainderUsesDefinedArchitecturalHelper() throws {
        for (mnemonic, a, b, expected): (String, UInt64, UInt64, UInt64) in [
            ("udiv", UInt64.max, 2, 1), ("sdiv", 0x8000000000000000, UInt64.max, 0),
            ("sdiv", UInt64(bitPattern: -17), 0, UInt64(bitPattern: -17)),
            ("sdiv", UInt64(bitPattern: -17), 5, UInt64(bitPattern: -2))
        ] {
            var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
            state.x[1] = a; state.x[2] = b
            var function = MacIRBuilder().buildFunction(name: "remainder", instructions: [
                InstructionRow(address: A64MachineState.defaultPC, bytes: "", mnemonic: mnemonic, operands: "x9, x1, x2", hasBreakpoint: false, comment: nil),
                InstructionRow(address: A64MachineState.defaultPC + 4, bytes: "", mnemonic: "msub", operands: "x0, x9, x2, x1", hasBreakpoint: false, comment: nil)
            ])
            guard case let .intrinsic(_, name, _) = function.instructions[1].operation else { XCTFail("remainder must be explicit"); continue }
            XCTAssertEqual(name, mnemonic == "sdiv" ? "a64_srem64" : "a64_urem64")
            for i in function.instructions.indices { function.instructions[i].source.mnemonic = "redacted"; function.instructions[i].source.operands = "" }
            var evaluator = MacIRConcreteEvaluator(function: function, state: state)
            try evaluator.run(function.instructions)
            XCTAssertEqual(evaluator.state.x[0], expected)
        }
    }

    func test32BitRemainderSequencesPreserveWidthAndAliasing() throws {
        let cases: [(String, UInt64, UInt64, UInt64)] = [
            ("udiv", 0xffff_ffff, 2, 1),
            ("udiv", 0x8000_0000, 3, 2),
            ("udiv", 0x8000_0001, 0, 0x8000_0001),
            ("sdiv", 0x8000_0000, 0xffff_ffff, 0),
            ("sdiv", 0x8000_0000, 3, 0xffff_fffe),
            ("sdiv", 0xffff_ffef, 5, 0xffff_fffe),
            ("sdiv", 0xffff_ffef, 0, 0xffff_ffef),
            ("sdiv", 17, 0xffff_fffb, 2)
        ]
        for (mnemonic, a, b, expected) in cases {
            for destination in [0, 1, 2, 9] {
                for commuted in [false, true] {
                    var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
                    // Poison upper bits: W reads must discard them and every W write zero-extends.
                    state.x[1] = 0xa5a5_a5a5_0000_0000 | a
                    state.x[2] = 0x5a5a_5a5a_0000_0000 | b
                    state.x[0] = UInt64.max; state.x[9] = UInt64.max
                    var function = MacIRBuilder().buildFunction(name: "remainder32", instructions: [
                        InstructionRow(address: A64MachineState.defaultPC, bytes: "", mnemonic: mnemonic, operands: "w9, w1, w2", hasBreakpoint: false, comment: nil),
                        InstructionRow(address: A64MachineState.defaultPC + 4, bytes: "", mnemonic: "msub", operands: "w\(destination), \(commuted ? "w2, w9" : "w9, w2"), w1", hasBreakpoint: false, comment: nil)
                    ])
                    guard case let .intrinsic(_, name, _) = function.instructions[1].operation else {
                        XCTFail("32-bit remainder must be explicit"); continue
                    }
                    XCTAssertEqual(name, mnemonic == "sdiv" ? "a64_srem32" : "a64_urem32")
                    for i in function.instructions.indices {
                        function.instructions[i].source.mnemonic = "redacted"
                        function.instructions[i].source.operands = ""
                    }
                    var evaluator = MacIRConcreteEvaluator(function: function, state: state)
                    try evaluator.run(function.instructions)
                    XCTAssertEqual(evaluator.state.x[destination], expected,
                                   "\(mnemonic) a=\(a) b=\(b) destination=w\(destination) commuted=\(commuted)")
                }
            }
        }
    }

    func testRemainderFoldRejectsDiscardedQuotientsAndControlFlowJoins() {
        let examples: [[(String, String)]] = [
            [("sdiv", "xzr, x1, x2"), ("msub", "x0, xzr, x2, x1")],
            [("cbz", "x3, 0x1008"), ("sdiv", "x9, x1, x2"), ("msub", "x0, x9, x2, x1")],
            [("sdiv", "x1, x1, x2"), ("msub", "x0, x1, x2, x1")],
            [("sdiv", "x9, x1, x2"), ("nop", ""), ("msub", "x0, x9, x2, x1")]
        ]
        for rows in examples {
            let function = MacIRBuilder().buildFunction(name: "not_remainder", instructions: rows.enumerated().map { i, row in
                InstructionRow(address: 0x1000 + UInt64(i * 4), bytes: "", mnemonic: row.0, operands: row.1, hasBreakpoint: false, comment: nil)
            })
            guard case .binary = function.instructions.last!.operation else { XCTFail("must retain MSUB when exact quotient dominance is not proven: \(rows)"); continue }
        }
    }

}
