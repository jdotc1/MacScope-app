import Foundation
import XCTest
@testable import MacScope

/// Bit-exact expectations chosen independently of the lifter and its evaluator.
/// These tests check data results only; FPSR is deliberately not modeled.
final class MacIRScalarFPFidelityTests: XCTestCase {
    private func run(_ mnemonic: String, _ operands: String, seed: (inout A64MachineState) -> Void) throws -> A64MachineState {
        var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
        seed(&state)
        var function = MacIRBuilder().buildFunction(name: "fp_fidelity", instructions: [InstructionRow(address: A64MachineState.defaultPC, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil)])
        function.instructions[0].source.mnemonic = "redacted"
        function.instructions[0].source.operands = ""
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        try evaluator.run(function.instructions)
        return evaluator.state
    }

    func testBinary32AdditionRoundsTiesToEvenAtSourceWidth() throws {
        for (input, expected): (UInt64, UInt64) in [(0x3f800000, 0x3f800000), (0x3f800001, 0x3f800002)] {
            let final = try run("fadd", "s0, s1, s2") { $0.v[1].low = input; $0.v[2].low = 0x33800000; $0.v[0].high = UInt64.max }
            XCTAssertEqual(final.v[0].low, expected)
            XCTAssertEqual(final.v[0].high, 0)
        }
    }

    func testInvalidDivisionUsesPositiveDefaultNaN() throws {
        let final = try run("fdiv", "d0, d1, d2") { _ in }
        XCTAssertEqual(final.v[0].low, 0x7ff8000000000000)
    }

    func testSignalingNaNPriorityAndPayload() throws {
        let final = try run("fadd", "s0, s1, s2") { $0.v[1].low = 0x7fc00123; $0.v[2].low = 0xff800456 }
        XCTAssertEqual(final.v[0].low, 0xffc00456)
    }

    func testIntegralRoundingModesAndNegativeZero() throws {
        let even = try run("frintn", "d0, d1") { $0.v[1].low = Double(2.5).bitPattern }
        XCTAssertEqual(even.v[0].low, Double(2).bitPattern)
        let away = try run("frinta", "d0, d1") { $0.v[1].low = Double(-2.5).bitPattern }
        XCTAssertEqual(away.v[0].low, Double(-3).bitPattern)
        let negativeZero = try run("frintp", "s0, s1") { $0.v[1].low = 0x80000001 }
        XCTAssertEqual(negativeZero.v[0].low, 0x80000000)
    }

    func testFloatNarrowingRoundsOnceAndConvertsNaNPayload() throws {
        let tie = try run("fcvt", "s0, d1") { $0.v[1].low = 0x3ff0000010000000 }
        XCTAssertEqual(tie.v[0].low, 0x3f800000)
        let nan = try run("fcvt", "s0, d1") { $0.v[1].low = 0xfff0000000001234 }
        XCTAssertEqual(nan.v[0].low, 0xffc00000)
    }

    func testFloatToIntegerSaturatesAndMapsNaNToZero() throws {
        for (input, expected): (UInt64, UInt64) in [(0x7ff0000000000000, 0x7fffffffffffffff), (0xfff0000000000000, 0x8000000000000000), (0x7ff8000000000023, 0)] {
            let final = try run("fcvtzs", "x0, d1") { $0.v[1].low = input }
            XCTAssertEqual(final.x[0], expected)
        }
        let unsigned = try run("fcvtzu", "w0, d1") { $0.v[1].low = Double(4294967296).bitPattern }
        XCTAssertEqual(unsigned.x[0], 0xffffffff)
    }

    func testIntegerToFloatHasNoIntermediateDoubleRounding() throws {
        let final = try run("ucvtf", "s0, x1") { $0.x[1] = UInt64.max }
        XCTAssertEqual(final.v[0].low, 0x5f800000)
        let negative = try run("scvtf", "d0, x1") { $0.x[1] = UInt64.max }
        XCTAssertEqual(negative.v[0].low, Double(-1).bitPattern)
    }

    func testFixedPointConversionsScaleByPowerOfTwo() throws {
        let real = try run("scvtf", "d0, x1, #3") { $0.x[1] = 9 }
        XCTAssertEqual(real.v[0].low, Double(1.125).bitPattern)
        let integer = try run("fcvtzs", "x0, d1, #3") { $0.v[1].low = Double(1.125).bitPattern }
        XCTAssertEqual(integer.x[0], 9)
    }
    func testHalfPrecisionArithmeticRemainsUnlifted() {
        let function = MacIRBuilder().buildFunction(name: "half", instructions: [InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "fadd", operands: "h0, h1, h2", hasBreakpoint: false, comment: nil)])
        guard case .unknown = function.instructions[0].operation else { return XCTFail("half precision arithmetic is out of scope") }
    }

    func testFPSRExpectationIsUnsupportedEvenWhenExpectedFlagsAreZero() throws {
        let vectors = try A64OracleFile.load().vectors
        let vector = try XCTUnwrap(vectors.first { $0.asm.hasPrefix("fadd s") && $0.expected.fpsr.flatMap(A64OracleHex.uint64) == 0 })
        XCTAssertEqual(A64OracleRunner.run(vector).status, .unsupported)
    }

    func testSubnormalArithmeticDoesNotFlushToZero() throws {
        let halfNormal = try run("fmul", "s0, s1, s2") { $0.v[1].low = 0x00800000; $0.v[2].low = 0x3f000000 }
        XCTAssertEqual(halfNormal.v[0].low, 0x00400000)
        let roundedSubnormal = try run("fmul", "s0, s1, s2") { $0.v[1].low = 1; $0.v[2].low = 0x3fc00000 }
        XCTAssertEqual(roundedSubnormal.v[0].low, 2)
    }

    func testIntegerToBinary32AvoidsKnownDoubleRoundingTrap() throws {
        let final = try run("ucvtf", "s0, x1") { $0.x[1] = 0x4000004000000001 }
        XCTAssertEqual(final.v[0].low, 0x5e800001)
    }

    func testMinMaxDistinguishSignedZeroAndNumberNaNs() throws {
        let maximum = try run("fmax", "d0, d1, d2") { $0.v[1].low = 0x8000000000000000 }
        XCTAssertEqual(maximum.v[0].low, 0)
        let minimum = try run("fmin", "d0, d1, d2") { $0.v[1].low = 0x8000000000000000 }
        XCTAssertEqual(minimum.v[0].low, 0x8000000000000000)
        let number = try run("fmaxnm", "s0, s1, s2") { $0.v[1].low = 0x7fc00123; $0.v[2].low = 0x3f800000 }
        XCTAssertEqual(number.v[0].low, 0x3f800000)
        let signaling = try run("fminnm", "s0, s1, s2") { $0.v[1].low = 0x7f800123; $0.v[2].low = 0x3f800000 }
        XCTAssertEqual(signaling.v[0].low, 0x7fc00123)
    }

    func testSignOperationsPreserveSignalingNaNPayloadAndSqrtInvalidIsCanonical() throws {
        let absolute = try run("fabs", "s0, s1") { $0.v[1].low = 0xff800123 }
        XCTAssertEqual(absolute.v[0].low, 0x7f800123)
        let negated = try run("fneg", "d0, d1") { $0.v[1].low = 0x7ff0000000000123 }
        XCTAssertEqual(negated.v[0].low, 0xfff0000000000123)
        let invalid = try run("fsqrt", "d0, d1") { $0.v[1].low = Double(-1).bitPattern }
        XCTAssertEqual(invalid.v[0].low, 0x7ff8000000000000)
    }

    func testConversionMnemonicRoundingModes() throws {
        for (mnemonic, expected): (String, UInt64) in [("fcvtns", 2), ("fcvtas", 3), ("fcvtms", 2), ("fcvtps", 3), ("fcvtzs", 2), ("fcvtnu", 2), ("fcvtau", 3), ("fcvtmu", 2), ("fcvtpu", 3), ("fcvtzu", 2)] {
            let final = try run(mnemonic, "x0, d1") { $0.v[1].low = Double(2.5).bitPattern }
            XCTAssertEqual(final.x[0], expected, mnemonic)
        }
    }

    func testNonDefaultFPCRIsExplicitlyUnsupported() throws {
        XCTAssertThrowsError(try run("fadd", "s0, s1, s2") { $0.fpcr = 1 << 24 }) { error in
            guard case .unsupported = error as? MacIRConcreteEvaluator.Failure else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testTypedMetadataSurvivesPrinterConstructionAndTypeInference() throws {
        let rows = [("ldrsb", "x0, [x1]"), ("fadd", "s0, s1, s2"), ("ret", "x7")].enumerated().map { index, row in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "00 00 00 00", mnemonic: row.0, operands: row.1, hasBreakpoint: false, comment: nil)
        }
        let direct = MacIRBuilder().buildFunction(name: "metadata", startAddress: 0x1000, instructions: rows)
        let printer = PseudocodePrinter().buildFunction(functionName: "metadata", startAddress: 0x1000, instructions: rows)
        XCTAssertEqual(printer.instructions, direct.instructions)
        XCTAssertEqual(LocalTypeInferencePass.infer(function: direct).instructions, direct.instructions)
        XCTAssertEqual(direct.instructions[0].memoryAccess, MacIRMemoryAccess(byteWidth: 1, extensionKind: .sign))
        XCTAssertEqual(direct.instructions[1].scalarFP?.inputType, .binary32)
        XCTAssertEqual(direct.instructions[1].scalarFP?.resultType, .binary32)
        XCTAssertNotNil(direct.instructions[2].returnTarget)
        var changed = direct.instructions[0]
        changed.memoryAccess = MacIRMemoryAccess(byteWidth: 2, extensionKind: .zero)
        XCTAssertNotEqual(changed, direct.instructions[0], "semantic metadata participates in Hashable identity")
        XCTAssertEqual(Set([changed, direct.instructions[0]]).count, 2)
        let cfg = CFGBuilder.buildCFG(instructions: direct.instructions)
        _ = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: direct.instructions, collectDiagnostics: true)
        XCTAssertEqual(direct.instructions, printer.instructions)
    }

    func testFusedArithmeticRoundsOnceAfterSourceRedaction() throws {
        let narrow = try run("fmadd", "s0, s1, s2, s3") {
            $0.v[1].low = 0x3f800001; $0.v[2].low = 0x3f7ffffe; $0.v[3].low = 0xbf800000
        }
        XCTAssertEqual(narrow.v[0].low, 0xa8800000)
        let wide = try run("fmadd", "d0, d1, d2, d3") {
            $0.v[1].low = 0x3ff0000000000001; $0.v[2].low = 0x3feffffffffffffe; $0.v[3].low = 0xbff0000000000000
        }
        XCTAssertEqual(wide.v[0].low, 0xb970000000000000)
    }

    func testFusedDestinationAliasingReadsAllOldSources() throws {
        for destination in 1...3 {
            let result = try run("fmadd", "d\(destination), d1, d2, d3") {
                $0.v[1].low = Double(2).bitPattern; $0.v[2].low = Double(3).bitPattern; $0.v[3].low = Double(5).bitPattern
            }
            XCTAssertEqual(result.v[destination].low, Double(11).bitPattern)
        }
    }

    func testScalarSIMDIntegerCarrierIsNotNumericallyRecastAsFloat() throws {
        let integer = try run("fcvtzs", "s0, s1") { $0.v[1].low = UInt64(Float(3.75).bitPattern); $0.v[0].high = UInt64.max; $0.v[0].low = UInt64.max }
        XCTAssertEqual(integer.v[0].low, 3)
        XCTAssertEqual(integer.v[0].high, 0)
        let real = try run("scvtf", "s0, s1") { $0.v[1].low = 3 }
        XCTAssertEqual(real.v[0].low, UInt64(Float(3).bitPattern))
    }

    func testScalarSIMDIntegerOnlyInputDoesNotInventFloatParameter() {
        let function = MacIRBuilder().buildFunction(name: "raw_carrier", instructions: [InstructionRow(address: 0x1000, bytes: "", mnemonic: "scvtf", operands: "d0, d1", hasBreakpoint: false, comment: nil)])
        XCTAssertTrue(function.parameters.isEmpty)
        guard case .intrinsic = function.instructions[0].operation else { return XCTFail("scalar carrier conversion must lift") }
    }

    func testScalarSIMDIntegerBitsSurviveMovesSpillsAndNumericUses() throws {
        let tails: [[(String, String)]] = [
            [("fmov", "w1, s0")],
            [("str", "s0, [sp]"), ("ldr", "s2, [sp]"), ("fmov", "w1, s2")],
            [("scvtf", "s2, s0")],
            [("fadd", "s2, s0, s0")]
        ]
        for (index, tail) in tails.enumerated() {
            var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
            state.sp = 0x500080
            state.v[1].low = UInt64(Float(-3.75).bitPattern)
            let rows = [("fcvtzs", "s0, s1")] + tail
            var function = MacIRBuilder().buildFunction(name: "simd_carrier_sequence", instructions: rows.enumerated().map { i, row in
                InstructionRow(address: A64MachineState.defaultPC + UInt64(i * 4), bytes: "", mnemonic: row.0, operands: row.1, hasBreakpoint: false, comment: nil)
            })
            XCTAssertEqual(function.instructions[0].scalarFP?.resultType, .signed32)
            XCTAssertEqual(function.instructions[0].scalarFP?.storageResultType, .binary32)
            for i in function.instructions.indices { function.instructions[i].source.mnemonic = "redacted"; function.instructions[i].source.operands = "" }
            var evaluator = MacIRConcreteEvaluator(function: function, state: state)
            try evaluator.run(function.instructions)
            if index < 2 { XCTAssertEqual(evaluator.state.x[1], 0xfffffffd) }
            if index == 2 { XCTAssertEqual(evaluator.state.v[2].low, UInt64(Float(-3).bitPattern)) }
            if index == 3 { XCTAssertEqual(evaluator.state.v[2].low, 0xfffffffd) }
        }
    }

}
