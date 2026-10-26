import Foundation
import XCTest
@testable import MacScope

final class ARM64VectorShiftImmediateCompletionTests: XCTestCase {
    private func word(q: UInt32, u: UInt32, opcode: UInt32, immediate: UInt32,
                      rd: UInt32 = 0, rn: UInt32 = 31) -> UInt32 {
        0x0f00_0400 | (q << 30) | (u << 29) | (immediate << 16) | (opcode << 11) | (rn << 5) | rd
    }

    private func decode(_ word: UInt32, at address: UInt64 = 0x1000,
                        file: StaticString = #filePath, line: UInt = #line) throws -> DecodedInstruction {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
        let rows = ARM64Decoder().decode(Data(bytes), baseAddress: address, maxInstructionCount: 1)
        XCTAssertEqual(rows.count, 1, file: file, line: line)
        let row = try XCTUnwrap(rows.first, file: file, line: line)
        XCTAssertEqual(row.address, address, file: file, line: line)
        XCTAssertEqual(row.bytes, bytes, file: file, line: line)
        return row
    }

    private func assertDecoded(_ word: UInt32, at address: UInt64 = 0x1000,
                               mnemonic: String, operands: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try decode(word, at: address, file: file, line: line)
        let label = String(format: "0x%08x", word)
        XCTAssertEqual(row.mnemonic, mnemonic, label, file: file, line: line)
        XCTAssertEqual(row.operands, operands, label, file: file, line: line)
        XCTAssertNil(row.branchTarget, file: file, line: line)
        let model = try XCTUnwrap(row.structuredOperands, file: file, line: line)
        XCTAssertEqual(model.coverage, .unavailable, file: file, line: line)
        XCTAssertEqual(model.operands, [.opaque(operands)], file: file, line: line)
    }

    private func assertUnknown(_ word: UInt32,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try decode(word, file: file, line: line)
        XCTAssertEqual(row.mnemonic, "unknown", file: file, line: line)
        XCTAssertEqual(row.operands, String(format: "0x%08x", word), file: file, line: line)
    }

    func testAllObservedSSRAWordsDecodeExactly() throws {
        // Every observed word/address from the complete pre-change census.
        let cases: [(UInt64, UInt32, String)] = [
            (0x2c0e4, 0x4f7f1423, "v3.2d, v1.2d, #1"),
            (0x2c0ec, 0x4f7f1441, "v1.2d, v2.2d, #1"),
            (0x2c0f4, 0x4f7f1402, "v2.2d, v0.2d, #1"),
            (0x2c0fc, 0x4f7f1480, "v0.2d, v4.2d, #1"),
            (0x3d5f0, 0x4f781482, "v2.2d, v4.2d, #8"),
            (0x3d644, 0x4f781445, "v5.2d, v2.2d, #8"),
            (0x3d660, 0x4f781443, "v3.2d, v2.2d, #8"),
            (0x3d684, 0x4f781420, "v0.2d, v1.2d, #8"),
        ]
        for (address, word, operands) in cases {
            try assertDecoded(word, at: address, mnemonic: "ssra", operands: operands)
        }
    }

    func testAllObservedSRSRAWordsDecodeExactly() throws {
        // Every observed word/address from the complete pre-change census.
        let cases: [(UInt64, UInt32, String)] = [
            (0x57510, 0x4f1c3401, "v1.8h, v0.8h, #4"),
            (0x578ec, 0x4f1d3482, "v2.8h, v4.8h, #3"),
            (0x578f0, 0x4f1d3420, "v0.8h, v1.8h, #3"),
        ]
        for (address, word, operands) in cases {
            try assertDecoded(word, at: address, mnemonic: "srsra", operands: operands)
        }
    }

    func testAllObservedSQSHLUWordsDecodeExactly() throws {
        // Every observed word/address from the complete pre-change census.
        let cases: [(UInt64, UInt32, String)] = [
            (0x53000, 0x6f1864e7, "v7.8h, v7.8h, #8"),
            (0x53004, 0x6f186631, "v17.8h, v17.8h, #8"),
            (0x5300c, 0x6f186610, "v16.8h, v16.8h, #8"),
            (0x53014, 0x6f1864c6, "v6.8h, v6.8h, #8"),
            (0x53018, 0x6f186484, "v4.8h, v4.8h, #8"),
            (0x53020, 0x6f1864a4, "v4.8h, v5.8h, #8"),
            (0x53094, 0x6f1864c6, "v6.8h, v6.8h, #8"),
            (0x53098, 0x6f186484, "v4.8h, v4.8h, #8"),
            (0x530a0, 0x6f1864a4, "v4.8h, v5.8h, #8"),
            (0x53100, 0x6f1864c4, "v4.8h, v6.8h, #8"),
            (0x53104, 0x6f1864e6, "v6.8h, v7.8h, #8"),
            (0x5310c, 0x6f1864a5, "v5.8h, v5.8h, #8"),
        ]
        for (address, word, operands) in cases {
            try assertDecoded(word, at: address, mnemonic: "sqshlu", operands: operands)
        }
    }

    private func assertBoundaries(_ forms: [(UInt32, UInt32, String)], left: Bool,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        // Both endpoints, every allocated Q/element width, and register 31.
        let widths: [(UInt32, UInt32, String)] = [
            (0, 8, "8b"), (1, 8, "16b"), (0, 16, "4h"), (1, 16, "8h"),
            (0, 32, "2s"), (1, 32, "4s"), (1, 64, "2d")
        ]
        for (opcode, u, mnemonic) in forms {
            for (q, bits, arrangement) in widths {
                for shift in (left ? [0, bits - 1] : [1, bits]) {
                    for (rd, rn): (UInt32, UInt32) in [(0, 31), (31, 0)] {
                        let immediate = left ? bits + shift : 2 * bits - shift
                        let encoding = word(q: q, u: u, opcode: opcode, immediate: immediate, rd: rd, rn: rn)
                        let amount = shift < 10 ? "\(shift)" : String(format: "0x%x", shift)
                        try assertDecoded(encoding, mnemonic: mnemonic,
                            operands: "v\(rd).\(arrangement), v\(rn).\(arrangement), #\(amount)", file: file, line: line)
                    }
                }
            }
        }
    }

    func testAccumulateRightShiftFormsCoverAllWidthsAndEndpoints() throws {
        try assertBoundaries([(2, 0, "ssra"), (2, 1, "usra"), (6, 0, "srsra"), (6, 1, "ursra")], left: false)
    }

    func testSaturatingLeftShiftFormsCoverAllWidthsAndEndpoints() throws {
        try assertBoundaries([(12, 1, "sqshlu"), (14, 0, "sqshl"), (14, 1, "uqshl")], left: true)
    }

    func testReservedFormsAndPriorNeighborsStayUnchangedBesideAdmittedControl() throws {
        for (opcode, u): (UInt32, UInt32) in [(2, 0), (2, 1), (6, 0), (6, 1), (12, 1), (14, 0), (14, 1)] {
            try assertUnknown(word(q: 0, u: u, opcode: opcode, immediate: 64)) // No vector .1d.
        }
        for bits: UInt32 in [8, 16, 32, 64] {
            try assertUnknown(word(q: 1, u: 0, opcode: 12, immediate: bits)) // SQSHLU requires U=1.
        }
        for opcode: UInt32 in [0x1c, 0x1f] {
            for u: UInt32 in [0, 1] {
                try assertUnknown(word(q: 1, u: u, opcode: opcode, immediate: 32)) // Fixed-point forms stay out of scope.
            }
        }
        let neighbors: [(UInt32, String, String)] = [
            (0x0f0f0420, "sshr", "v0.8b, v1.8b, #1"),
            (0x6f100420, "ushr", "v0.8h, v1.8h, #0x10"),
            (0x0f1c2420, "srshr", "v0.4h, v1.4h, #4"),
            (0x6f382420, "urshr", "v0.4s, v1.4s, #8"),
            (0x6f194420, "sri", "v0.8h, v1.8h, #7"),
            (0x0f085420, "shl", "v0.8b, v1.8b, #0"),
            (0x6f0c5420, "sli", "v0.16b, v1.16b, #4")
        ]
        for (word, mnemonic, operands) in neighbors {
            try assertDecoded(word, mnemonic: mnemonic, operands: operands)
        }
        // Already-correct refusals/neighbor decodes do not supply behavioral red.
        try assertDecoded(0x4f7f1423, mnemonic: "ssra", operands: "v3.2d, v1.2d, #1")
    }

    func testRecognizedShiftFormsUseTypedSemanticsOrRetainUnknownFallback() throws {
        for (opcode, u, mnemonic): (UInt32, UInt32, String) in [
            (2, 0, "ssra"), (2, 1, "usra"), (6, 0, "srsra"), (6, 1, "ursra"),
            (12, 1, "sqshlu"), (14, 0, "sqshl"), (14, 1, "uqshl")
        ] {
            let row = try decode(word(q: 1, u: u, opcode: opcode, immediate: 16, rd: 0, rn: 1))
            XCTAssertEqual(row.mnemonic, mnemonic) // Missing decode supplies behavioral red.
            let rows = [InstructionRow(address: row.address, bytes: row.byteText,
                mnemonic: row.mnemonic, operands: row.operands, hasBreakpoint: false, comment: row.comment),
                InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret",
                    operands: "", hasBreakpoint: false, comment: nil)]
            let function = MacIRBuilder().buildFunction(name: "shift_immediate", instructions: rows)
            let first = try XCTUnwrap(function.instructions.first)
            if ["ssra", "usra", "srsra", "ursra", "sqshlu"].contains(mnemonic) {
                XCTAssertEqual(first.neonLaneOp?.kind.rawValue, mnemonic)
                XCTAssertEqual(first.neonLaneOp?.setsQC, mnemonic == "sqshlu")
                guard case .intrinsic = first.operation else { return XCTFail("Expected typed shift") }
                continue
            }
            if case let .unknown(_, _, mnemonic, operands) = first.operation {
                XCTAssertEqual(mnemonic, row.mnemonic)
                XCTAssertEqual(operands, row.operands)
            } else {
                XCTFail("Unmodeled saturating shift must remain unknown")
            }
            XCTAssertTrue(PseudocodePrinter().print(function: function).text.contains("__unknown("))
        }
    }
}
