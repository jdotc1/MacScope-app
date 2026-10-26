import Foundation
import XCTest
@testable import MacScope

final class QCSaturationIntegrationTests: XCTestCase {
    typealias Lane = MacIRNEONLaneOp

    // Arm A64 XML2025-12, named files #Operation: SQSHLU uses signed input
    // shifted then UnsignedSatQ; SQSHRN/SQRSHRN use signed (rounded) shift then
    // SignedSatQ; SQDMULH doubles signed product; SQXTUN uses UnsignedSatQ.
    // Each operation sets FPSR.QC iff sat, never clears it otherwise.
    func testExactRetainedEncodingsReachTypedOrdinaryIR() throws {
        let cases: [(UInt32, String, String, Lane.Kind, String)] = [
            (0x6f1864e7, "sqshlu", "v7.8h, v7.8h, #8", .sqshlu, "neon_sqshlu_8h_shift8"),
            (0x4f58c0d0, "sqdmulh", "v16.8h, v6.8h, v8.h[1]", .sqdmulh, "neon_sqdmulh_8h_by_lane1"),
            (0x0f0b94e1, "sqshrn", "v1.8b, v7.8h, #5", .sqshrn, "neon_sqshrn_8b_from_8h_shift5_zero_high64"),
            (0x4f0b9601, "sqshrn2", "v1.16b, v16.8h, #5", .sqshrn, "neon_sqshrn2_16b_from_8h_shift5_keep_low64"),
            (0x0f0e9e45, "sqrshrn", "v5.8b, v18.8h, #2", .sqrshrn, "neon_sqrshrn_8b_from_8h_shift2_zero_high64"),
            (0x2e212820, "sqxtun", "v0.8b, v1.8h", .sqxtun, "neon_sqxtun_8b_from_8h_zero_high64")
        ]
        for (word, mnemonic, operands, kind, name) in cases {
            let bytes = Data((0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) })
            let decoded = try XCTUnwrap(ARM64Decoder().decode(bytes, baseAddress: 0x1000,
                                                             maxInstructionCount: 1).first)
            XCTAssertEqual(decoded.mnemonic, mnemonic)
            XCTAssertEqual(decoded.operands, operands)
            let row = InstructionRow(address: decoded.address, bytes: decoded.byteText,
                                     mnemonic: decoded.mnemonic, operands: decoded.operands,
                                     hasBreakpoint: false, comment: nil)
            let function = MacIRBuilder(ssaEnabled: false, ssaCancellation: { false })
                .buildFunction(name: "qc_leaf", startAddress: 0x1000, instructions: [row,
                    InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret",
                                   operands: "", hasBreakpoint: false, comment: nil)])
            let instruction = try XCTUnwrap(function.instructions.first)
            let descriptor = try XCTUnwrap(instruction.neonLaneOp)
            XCTAssertEqual(descriptor.kind, kind)
            XCTAssertTrue(descriptor.setsQC)
            XCTAssertEqual(descriptor.intrinsicName, name)
            guard case let .intrinsic(destination?, actualName, arguments) = instruction.operation else {
                return XCTFail("Expected typed lane operation, not unknown")
            }
            XCTAssertEqual(actualName, name)
            XCTAssertEqual(arguments.count, descriptor.arity)
            XCTAssertNotEqual(destination, .unknown("unavailable"))
        }
    }

    func testEveryRetainedQCEncodingHasExpectedTypedDescriptor() throws {
        // Each unique retained QC word is authored here; no corpus or fixture run.
        // Operation citations: sqshlu_advsimd, sqdmulh_advsimd_elt,
        // sqshrn_advsimd, sqrshrn_advsimd, sqxtun_advsimd XML2025-12 #Operation.
        let cases: [(UInt32, String, String, Lane.Kind, Int, Int, Bool, Int, Int?)] = [
            (0x6f1864e7, "sqshlu", "v7.8h, v7.8h, #8", .sqshlu, 16, 16, false, 8, nil),
            (0x6f186631, "sqshlu", "v17.8h, v17.8h, #8", .sqshlu, 16, 16, false, 8, nil),
            (0x6f186610, "sqshlu", "v16.8h, v16.8h, #8", .sqshlu, 16, 16, false, 8, nil),
            (0x6f1864c6, "sqshlu", "v6.8h, v6.8h, #8", .sqshlu, 16, 16, false, 8, nil),
            (0x6f186484, "sqshlu", "v4.8h, v4.8h, #8", .sqshlu, 16, 16, false, 8, nil),
            (0x6f1864a4, "sqshlu", "v4.8h, v5.8h, #8", .sqshlu, 16, 16, false, 8, nil),
            (0x6f1864c4, "sqshlu", "v4.8h, v6.8h, #8", .sqshlu, 16, 16, false, 8, nil),
            (0x6f1864e6, "sqshlu", "v6.8h, v7.8h, #8", .sqshlu, 16, 16, false, 8, nil),
            (0x6f1864a5, "sqshlu", "v5.8h, v5.8h, #8", .sqshlu, 16, 16, false, 8, nil),
            (0x4f58c0d0, "sqdmulh", "v16.8h, v6.8h, v8.h[1]", .sqdmulh, 16, 16, false, 0, 1),
            (0x4f58c023, "sqdmulh", "v3.8h, v1.8h, v8.h[1]", .sqdmulh, 16, 16, false, 0, 1),
            (0x4f68c064, "sqdmulh", "v4.8h, v3.8h, v8.h[2]", .sqdmulh, 16, 16, false, 0, 2),
            (0x4f48c004, "sqdmulh", "v4.8h, v0.8h, v8.h[0]", .sqdmulh, 16, 16, false, 0, 0),
            (0x4f78c044, "sqdmulh", "v4.8h, v2.8h, v8.h[3]", .sqdmulh, 16, 16, false, 0, 3),
            (0x0f56c0b5, "sqdmulh", "v21.4h, v5.4h, v6.h[1]", .sqdmulh, 16, 8, false, 0, 1),
            (0x0f56c070, "sqdmulh", "v16.4h, v3.4h, v6.h[1]", .sqdmulh, 16, 8, false, 0, 1),
            (0x0f66c212, "sqdmulh", "v18.4h, v16.4h, v6.h[2]", .sqdmulh, 16, 8, false, 0, 2),
            (0x0f46c032, "sqdmulh", "v18.4h, v1.4h, v6.h[0]", .sqdmulh, 16, 8, false, 0, 0),
            (0x0f76c041, "sqdmulh", "v1.4h, v2.4h, v6.h[3]", .sqdmulh, 16, 8, false, 0, 3),
            (0x0f58c0d0, "sqdmulh", "v16.4h, v6.4h, v8.h[1]", .sqdmulh, 16, 8, false, 0, 1),
            (0x0f58c023, "sqdmulh", "v3.4h, v1.4h, v8.h[1]", .sqdmulh, 16, 8, false, 0, 1),
            (0x0f68c064, "sqdmulh", "v4.4h, v3.4h, v8.h[2]", .sqdmulh, 16, 8, false, 0, 2),
            (0x0f48c004, "sqdmulh", "v4.4h, v0.4h, v8.h[0]", .sqdmulh, 16, 8, false, 0, 0),
            (0x0f78c044, "sqdmulh", "v4.4h, v2.4h, v8.h[3]", .sqdmulh, 16, 8, false, 0, 3),
            (0x4f58c070, "sqdmulh", "v16.8h, v3.8h, v8.h[1]", .sqdmulh, 16, 16, false, 0, 1),
            (0x4f58c067, "sqdmulh", "v7.8h, v3.8h, v8.h[1]", .sqdmulh, 16, 16, false, 0, 1),
            (0x4f68c0f1, "sqdmulh", "v17.8h, v7.8h, v8.h[2]", .sqdmulh, 16, 16, false, 0, 2),
            (0x4f48c011, "sqdmulh", "v17.8h, v0.8h, v8.h[0]", .sqdmulh, 16, 16, false, 0, 0),
            (0x4f78c0b1, "sqdmulh", "v17.8h, v5.8h, v8.h[3]", .sqdmulh, 16, 16, false, 0, 3),
            (0x0f0b94e1, "sqshrn", "v1.8b, v7.8h, #5", .sqshrn, 8, 16, false, 5, nil),
            (0x4f0b9601, "sqshrn2", "v1.16b, v16.8h, #5", .sqshrn, 8, 16, true, 5, nil),
            (0x0f0b9463, "sqshrn", "v3.8b, v3.8h, #5", .sqshrn, 8, 16, false, 5, nil),
            (0x4f0b9443, "sqshrn2", "v3.16b, v2.8h, #5", .sqshrn, 8, 16, true, 5, nil),
            (0x0f0b94a2, "sqshrn", "v2.8b, v5.8h, #5", .sqshrn, 8, 16, false, 5, nil),
            (0x4f0b9402, "sqshrn2", "v2.16b, v0.8h, #5", .sqshrn, 8, 16, true, 5, nil),
            (0x0f0b9480, "sqshrn", "v0.8b, v4.8h, #5", .sqshrn, 8, 16, false, 5, nil),
            (0x4f0b94c0, "sqshrn2", "v0.16b, v6.8h, #5", .sqshrn, 8, 16, true, 5, nil),
            (0x0f0e9e45, "sqrshrn", "v5.8b, v18.8h, #2", .sqrshrn, 8, 16, false, 2, nil),
            (0x0f0e9e86, "sqrshrn", "v6.8b, v20.8h, #2", .sqrshrn, 8, 16, false, 2, nil),
            (0x0f0e9c63, "sqrshrn", "v3.8b, v3.8h, #2", .sqrshrn, 8, 16, false, 2, nil),
            (0x0f0e9c84, "sqrshrn", "v4.8b, v4.8h, #2", .sqrshrn, 8, 16, false, 2, nil),
            (0x0f0e9c00, "sqrshrn", "v0.8b, v0.8h, #2", .sqrshrn, 8, 16, false, 2, nil),
            (0x0f0e9c42, "sqrshrn", "v2.8b, v2.8h, #2", .sqrshrn, 8, 16, false, 2, nil),
            (0x0f0e9c21, "sqrshrn", "v1.8b, v1.8h, #2", .sqrshrn, 8, 16, false, 2, nil),
            (0x0f0e9ce5, "sqrshrn", "v5.8b, v7.8h, #2", .sqrshrn, 8, 16, false, 2, nil),
            (0x0f0e9e06, "sqrshrn", "v6.8b, v16.8h, #2", .sqrshrn, 8, 16, false, 2, nil),
            (0x2e212820, "sqxtun", "v0.8b, v1.8h", .sqxtun, 8, 16, false, 0, nil),
            (0x2e212841, "sqxtun", "v1.8b, v2.8h", .sqxtun, 8, 16, false, 0, nil),
            (0x2e212800, "sqxtun", "v0.8b, v0.8h", .sqxtun, 8, 16, false, 0, nil),
        ]
        for (word, mnemonic, operands, kind, bits, bytes, high, shift, element) in cases {
            let data = Data((0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) })
            let decoded = try XCTUnwrap(ARM64Decoder().decode(data, baseAddress: 0x1000,
                                                             maxInstructionCount: 1).first)
            XCTAssertEqual(decoded.mnemonic, mnemonic)
            XCTAssertEqual(decoded.operands, operands)
            let parsed = try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: decoded.mnemonic,
                                                                      operandText: decoded.operands))
            let expected = try XCTUnwrap(Lane(kind: kind, isSigned: false, laneBits: bits,
                                              highHalf: high, activeBytes: bytes,
                                              shift: shift, elementIndex: element))
            XCTAssertEqual(parsed.semantics, expected)
            XCTAssertTrue(expected.setsQC)
        }
    }

    func testSignedToUnsignedShiftSaturatesWithoutHostOverflow() throws {
        // sqshlu_advsimd.xml#Operation: signed input << shift, UnsignedSatQ.
        let op = try XCTUnwrap(Lane(kind: .sqshlu, isSigned: false, laneBits: 16,
                                    highHalf: false, activeBytes: 8, shift: 8))
        let result = op.evaluate(n: (0x0100_00ff_ffff_0001, .max))
        XCTAssertEqual(result.low, 0xffff_ff00_0000_0100)
        XCTAssertEqual(result.high, 0)
        XCTAssertTrue(op.saturates(n: (0x0100_00ff_ffff_0001, 0), m: (0, 0)))
        XCTAssertFalse(op.saturates(n: (0x00ff_0001_0000_0002, .max), m: (0, 0)))
        let wide = try XCTUnwrap(Lane(kind: .sqshlu, isSigned: false, laneBits: 64,
                                      highHalf: false, shift: 63))
        XCTAssertEqual(wide.evaluate(n: (1, 2)).low, 0x8000_0000_0000_0000)
        XCTAssertEqual(wide.evaluate(n: (1, 2)).high, .max)
        XCTAssertTrue(wide.saturates(n: (1, 2), m: (0, 0)))
        XCTAssertEqual(wide.evaluate(n: (.max, 0)).low, 0)
    }

    func testSignedNarrowRoundingSaturationAndKeepLowHalf() throws {
        // sqshrn_advsimd.xml / sqrshrn_advsimd.xml #Operation. Shift is
        // arithmetic; rounding occurs BEFORE saturation, including negative ties.
        let op = try XCTUnwrap(Lane(kind: .sqshrn, isSigned: false, laneBits: 8,
                                    highHalf: false, shift: 2))
        let input: Lane.Vector = (0xfdff_fe00_01fc_0200, 0)
        XCTAssertEqual(op.evaluate(n: input).low, 0x8080_7f7f)
        XCTAssertEqual(op.evaluate(n: input).high, 0)
        XCTAssertTrue(op.saturates(n: input, m: (0, 0)))
        let rounded = try XCTUnwrap(Lane(kind: .sqrshrn, isSigned: false, laneBits: 8,
                                         highHalf: true, shift: 2))
        let roundedInput: Lane.Vector = (0xfdfe_fdff_01fd_01fe, 0)
        let result = rounded.evaluate(n: roundedInput, oldDestination: (0x0123_4567_89ab_cdef, .max))
        XCTAssertEqual(result.low, 0x0123_4567_89ab_cdef)
        XCTAssertEqual(result.high, 0x8080_7f7f)
        XCTAssertTrue(rounded.saturates(n: roundedInput, m: (0, 0)))
        XCTAssertFalse(rounded.saturates(n: (0xfdfe_fdff_01fd_01fc, 0), m: (0, 0)))
        let wide = try XCTUnwrap(Lane(kind: .sqrshrn, isSigned: false, laneBits: 32,
                                      highHalf: false, shift: 1))
        XCTAssertEqual(wide.evaluate(n: (0x7fff_ffff_ffff_ffff, 0x8000_0000_0000_0000)).low,
                       0x8000_0000_7fff_ffff)
    }

    func testDestinationAliasingAndRejectedOperandShapes() throws {
        let parsed = try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: "sqshrn2",
                                                                  operandText: "v1.16b, v1.8h, #5"))
        var state = BuilderState(parameters: [])
        state.permitsNEONBufferCarrier = true
        let prior = state.readRegister("v1")
        let operation = MacIRBuilder.liftNEONLane(parsed, state: &state)
        guard case let .intrinsic(_, _, arguments) = operation else { return XCTFail("Expected intrinsic") }
        XCTAssertEqual(arguments, [prior, prior])
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "sqshrn", operandText: "v0.8b, v1.8h, #0"))
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "sqrshrn", operandText: "v0.8b, v1.8h, #9"))
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "sqshlu", operandText: "v0.8h, v1.8h, #16"))
        XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: "sqdmulh", operandText: "v0.8h, v1.8h, v16.h[0]"))
    }
}
