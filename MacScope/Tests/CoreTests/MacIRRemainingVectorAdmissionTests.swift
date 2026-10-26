import XCTest
@testable import MacScope

final class MacIRRemainingVectorAdmissionTests: XCTestCase {
    typealias Lane = MacIRNEONLaneOp

    private func check(_ mnemonic: String, _ operands: String, bytes: String,
                       n: Lane.Vector, m: Lane.Vector = (0, 0),
                       old: Lane.Vector = (0xffffffffffffffff, 0xffffffffffffffff),
                       expected: Lane.Vector, saturated: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let source = MacIRSourceSpan(address: 0x1000, byteText: bytes,
                                    mnemonic: mnemonic, operands: operands)
        let parsed = try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: mnemonic,
            operandText: operands), file: file, line: line)
        let admitted = MacIRBuilder.ssaVectorPermutation(source)?.lane
            ?? MacIRBuilder.ssaIntegerLaneOperation(mnemonic: mnemonic, operands: operands)?.semantics
        XCTAssertEqual(admitted, parsed.semantics, file: file, line: line)
        let effects = MacIRBuilder.ssaEffects(for: source)
        XCTAssertTrue(effects.refusals.isEmpty, file: file, line: line)
        XCTAssertEqual(Set(effects.writes.map { $0.cell }), Set([32, 64]), file: file, line: line)
        XCTAssertFalse(effects.reads.contains(98), file: file, line: line)
        let observed = MacIRBuilder.ssaEffects(for: source, observesFPSR: true)
        XCTAssertTrue(observed.refusals.isEmpty, file: file, line: line)
        XCTAssertEqual(observed.reads.contains(98), parsed.semantics.setsQC, file: file, line: line)
        XCTAssertEqual(observed.writes.filter { $0.cell == 98 }.count,
                       parsed.semantics.setsQC ? 1 : 0, file: file, line: line)
        for ssa in [false, true] {
            var rows = [InstructionRow(address: 0x1000, bytes: bytes, mnemonic: mnemonic,
                operands: operands, hasBreakpoint: false, comment: "")]
            if ssa {
                // Prevent the vector-only leaf route from bypassing SSA dispatch.
                rows.append(InstructionRow(address: 0x1004, bytes: "29 05 00 91", mnemonic: "add",
                    operands: "x9, x9, #1", hasBreakpoint: false, comment: ""))
            }
            rows.append(InstructionRow(address: ssa ? 0x1008 : 0x1004, bytes: "c0 03 5f d6",
                mnemonic: "ret", operands: "", hasBreakpoint: false, comment: ""))
            let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa)
                .buildFunction(name: "vector_admission", startAddress: 0x1000, instructions: rows)
            XCTAssertEqual(function.ssaEnabled, ssa, file: file, line: line)
            let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1000 },
                                            file: file, line: line)
            let lane = try XCTUnwrap(instruction.neonLaneOp, file: file, line: line)
            XCTAssertEqual(lane, parsed.semantics, file: file, line: line)
            guard case let .intrinsic(_, name, arguments) = instruction.operation else {
                return XCTFail("missing typed lane operation", file: file, line: line)
            }
            XCTAssertEqual(name, lane.intrinsicName, file: file, line: line)
            XCTAssertEqual(arguments.count, lane.arity, file: file, line: line)
            let actual = lane.evaluate(n: n, m: m, oldDestination: old)
            XCTAssertEqual(actual.low, expected.low, file: file, line: line)
            XCTAssertEqual(actual.high, expected.high, file: file, line: line)
            XCTAssertEqual(lane.saturates(n: n, m: m), saturated, file: file, line: line)
        }
    }

    // Arm A64 2025-12 sqxtun_advsimd.xml Operation:
    // "(result[e*:esize], sat) = UnsignedSatQ{esize}(SInt(element));"
    // "if sat then FPSR().QC = '1'; end;" / "Vpart{datasize}(d, part) = result;"
    func testSQXTUN2BytesSaturationAndPreservedLowBothModes() throws {
        // [-1, 0, 255, 256, -32768, 32767, 1, 254] -> [0, 0, 255, 255, 0, 255, 1, 254].
        try check("sqxtun2", "v0.16b, v1.8h", bytes: "20 28 21 6e",
            n: (0x010000ff0000ffff, 0x00fe00017fff8000), old: (0x0123456789abcdef, 0),
            expected: (0x0123456789abcdef, 0xfe01ff00ffff0000), saturated: true)
    }

    func testSQXTUN2HalfwordsSignedBoundsBothModes() throws {
        // [-1, 65535, 65536, -2147483648] -> [0, 65535, 65535, 0].
        try check("sqxtun2", "v0.8h, v1.4s", bytes: "20 28 61 6e",
            n: (0x0000ffffffffffff, 0x8000000000010000), old: (0xfedcba9876543210, 0),
            expected: (0xfedcba9876543210, 0x0000ffffffff0000), saturated: true)
    }

    func testSQXTUN2WordsExactEndpointsBothModes() throws {
        // Both signed 64-bit inputs fit uint32 exactly; no QC event, no rounding.
        try check("sqxtun2", "v0.4s, v1.2d", bytes: "20 28 a1 6e",
            n: (0, 0x00000000ffffffff), old: (0x89abcdef01234567, 0xffffffffffffffff),
            expected: (0x89abcdef01234567, 0xffffffff00000000))
    }

    // Arm A64 2025-12 uzp2_advsimd.xml Operation:
    // "let zipped : bits(datasize*2) = operandh::operandl;"
    // "result[e*:esize] = zipped[(2*e+part)*:esize];" (part = 1).
    func testUZP2HalfwordsOddLaneOrderBothModes() throws {
        try check("uzp2", "v0.8h, v1.8h, v2.8h", bytes: "20 58 42 4e",
            n: (0x0003000200010000, 0x0007000600050004),
            m: (0x000b000a00090008, 0x000f000e000d000c),
            expected: (0x0007000500030001, 0x000f000d000b0009))
    }

    func testUZP2EightBytesClearsHighBothModes() throws {
        // Upper source halves must not participate in the Q=0 operation.
        try check("uzp2", "v0.8b, v1.8b, v2.8b", bytes: "20 58 02 0e",
            n: (0x0706050403020100, 0xffffffffffffffff),
            m: (0x0f0e0d0c0b0a0908, 0xeeeeeeeeeeeeeeee),
            expected: (0x0f0d0b0907050301, 0))
    }

    func testUZP2DoublewordsDestinationAliasesSourceBothModes() throws {
        try check("uzp2", "v0.2d, v0.2d, v2.2d", bytes: "00 58 c2 4e",
            n: (0x1111111111111111, 0x2222222222222222),
            m: (0x3333333333333333, 0x4444444444444444),
            old: (0x1111111111111111, 0x2222222222222222),
            expected: (0x2222222222222222, 0x4444444444444444))
    }

    // Arm A64 2025-12 dup_advsimd_elt.xml scalar Operation:
    // "element = operand[index*:esize];" / "V{datasize}(d) = result;"
    // Scalar datasize = esize and elements = 1: all other Vd bits are zero.
    func testScalarMoveByteFromHighestLaneBothModes() throws {
        try check("mov", "b0, v1.b[15]", bytes: "20 04 1f 5e",
            n: (0x0706050403020100, 0xab0e0d0c0b0a0908), expected: (0xab, 0))
    }

    func testScalarMoveHalfwordClearsAllOtherBitsBothModes() throws {
        try check("mov", "h0, v1.h[3]", bytes: "20 04 0e 5e",
            n: (0x8001000200010000, 0xffffffffffffffff), expected: (0x8001, 0))
    }

    func testScalarMoveDoublewordSelfAliasBothModes() throws {
        try check("mov", "d0, v0.d[1]", bytes: "00 04 18 5e",
            n: (0x0123456789abcdef, 0xfedcba9876543210),
            old: (0x0123456789abcdef, 0xfedcba9876543210),
            expected: (0xfedcba9876543210, 0))
    }
    func testAdmissionsKeepReservedAndMismatchedFormsRefused() {
        for (bytes, operands) in [
            ("20 58 c2 0e", "v0.1d, v1.1d, v2.1d"),
            ("20 58 42 4e", "v0.8h, v1.8h, v3.8h")
        ] {
            XCTAssertNil(MacIRBuilder.ssaVectorPermutation(.init(address: 0x1000,
                byteText: bytes, mnemonic: "uzp2", operands: operands)))
        }
        XCTAssertNil(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: "mov", operands: "b0, v1.b[16]"))
        XCTAssertNil(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: "mov", operands: "d0, v1.s[1]"))
        XCTAssertNil(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: "sqxtun2", operands: "v0.8b, v1.8h"))
        XCTAssertNil(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: "sqxtun", operands: "b0, h1"))
    }

}
