import Foundation
import XCTest
@testable import MacScope

final class ARM64VectorFMOVImmediateTests: XCTestCase {
    // Expected spellings were checked with retained LLVM 21 llvm-objdump.
    // MacScope puts the arrangement on the destination and uses the scalar
    // FMOV convention of eight fractional digits. These are decoder tests,
    // not a claim that vector FMOV is supported by the IR lifter.
    private let immediates: [(UInt32, String)] = [
        (0x00, "#2.00000000"),
        (0x10, "#4.00000000"),
        (0x20, "#8.00000000"),
        (0x30, "#16.00000000"),
        (0x3f, "#31.00000000"),
        (0x40, "#0.12500000"),
        (0x4f, "#0.24218750"),
        (0x70, "#1.00000000"),
        (0x7f, "#1.93750000"),
        (0x80, "#-2.00000000"),
        (0xbf, "#-31.00000000"),
        (0xc0, "#-0.12500000"),
        (0xff, "#-1.93750000")
    ]

    private func word(q: UInt32, op: UInt32, imm8: UInt32, rd: UInt32) -> UInt32 {
        0x0f00_f400 | (q << 30) | (op << 29)
            | ((imm8 >> 5) << 16) | ((imm8 & 0x1f) << 5) | rd
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

    private func assertFMOV(_ word: UInt32, operands: String,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try decode(word, file: file, line: line)
        let label = String(format: "0x%08x", word)
        XCTAssertEqual(row.mnemonic, "fmov", label, file: file, line: line)
        XCTAssertEqual(row.operands, operands, label, file: file, line: line)
        XCTAssertNil(row.branchTarget, file: file, line: line)
    }

    private func assertUnknown(_ word: UInt32,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try decode(word, file: file, line: line)
        XCTAssertEqual(row.mnemonic, "unknown", file: file, line: line)
        XCTAssertEqual(row.operands, String(format: "0x%08x", word), file: file, line: line)
    }

    private func assertArrangement(q: UInt32, op: UInt32, arrangement: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        for (imm8, text) in immediates {
            for rd: UInt32 in [0, 31] {
                try assertFMOV(word(q: q, op: op, imm8: imm8, rd: rd),
                               operands: "v\(rd).\(arrangement), \(text)", file: file, line: line)
            }
        }
    }

    func testActualWordDecodesInExistingTextStyleWithHonestOperandMetadata() throws {
        // Actual refusal witness: bytes 00 f4 01 6f at 0x6724, imm8=0x20.
        XCTAssertEqual(word(q: 1, op: 1, imm8: 0x20, rd: 0), 0x6f01_f400)
        let row = try decode(0x6f01_f400, at: 0x6724)
        XCTAssertEqual(row.byteText, "00 f4 01 6f")
        XCTAssertEqual(row.mnemonic, "fmov")
        XCTAssertEqual(row.operands, "v0.2d, #8.00000000")
        XCTAssertNil(row.branchTarget)
        XCTAssertNil(row.comment)

        let model = try XCTUnwrap(row.structuredOperands)
        XCTAssertEqual(model.coverage, .unavailable)
        XCTAssertEqual(model.operands, [.opaque("v0.2d, #8.00000000")])
        let rendered = try XCTUnwrap(ARM64OperandRenderer.render(
            model, legacyMnemonic: row.mnemonic, legacyOperands: row.operands))
        XCTAssertEqual(rendered.mnemonic, "fmov")
        XCTAssertEqual(rendered.operands, "v0.2d, #8.00000000")
    }

    func testTwoSingleLanesExpandSignExponentFractionAndDestination31() throws {
        try assertArrangement(q: 0, op: 0, arrangement: "2s")
    }

    func testFourSingleLanesExpandSignExponentFractionAndDestination31() throws {
        try assertArrangement(q: 1, op: 0, arrangement: "4s")
    }

    func testTwoDoubleLanesExpandSignExponentFractionAndDestination31() throws {
        try assertArrangement(q: 1, op: 1, arrangement: "2d")
    }

    func testReservedDoubleQZeroAndOutOfScopeO2RemainUnknownBesideAdmittedControl() throws {
        for imm8: UInt32 in [0x00, 0x20, 0x3f, 0x40, 0xff] {
            for rd: UInt32 in [0, 31] {
                try assertUnknown(word(q: 0, op: 1, imm8: imm8, rd: rd))
            }
        }
        for q: UInt32 in [0, 1] {
            for op: UInt32 in [0, 1] {
                for rd: UInt32 in [0, 31] {
                    // o2=1/op=0 is allocated FP16, deliberately still outside
                    // this change; o2=1/op=1 remains unallocated.
                    try assertUnknown(word(q: q, op: op, imm8: 0x20, rd: rd) | 0x800)
                }
            }
        }
        // This paired positive, not the already-correct refusals, is the
        // behavioral-red assertion on the decoder before FMOV support.
        try assertFMOV(0x6f01_f400, operands: "v0.2d, #8.00000000")
    }

    func testAdjacentMOVIMVNIAndLogicalFormsStayUnchangedBesideAdmittedControl() throws {
        let neighbors: [(UInt32, String, String)] = [
            (0x6f00_e400, "movi", "v0.2d, #0"),
            (0x4f07_e7e0, "movi", "v0.16b, #0xff"),
            (0x0f02_e6a0, "movi", "v0.8b, #0x55"),
            (0x6f07_07e0, "mvni", "v0.4s, #0xff"),
            (0x0f00_c400, "movi", "v0.2s, #0, msl #8"),
            (0x6f00_d400, "mvni", "v0.4s, #0, msl #16")
        ]
        for (word, mnemonic, operands) in neighbors {
            let row = try decode(word)
            XCTAssertEqual(row.mnemonic, mnemonic)
            XCTAssertEqual(row.operands, operands)
        }
        // The later ORR/BIC decoder authorization supersedes only these six
        // newly authored gap expectations, not any original-pin expectation.
        let logicalNeighbors: [(UInt32, String, String)] = [
            (0x0f00_1420, "orr", "v0.2s, #1"),
            (0x4f00_1420, "orr", "v0.4s, #1"),
            (0x2f00_1420, "bic", "v0.2s, #1"),
            (0x6f00_1420, "bic", "v0.4s, #1"),
            (0x4f00_9420, "orr", "v0.8h, #1"),
            (0x6f00_9420, "bic", "v0.8h, #1")
        ]
        for (word, mnemonic, operands) in logicalNeighbors {
            let row = try decode(word)
            XCTAssertEqual(row.mnemonic, mnemonic)
            XCTAssertEqual(row.operands, operands)
        }
        try assertFMOV(0x0f03_f600, operands: "v0.2s, #1.00000000")
    }

    private func logicalWord(q: UInt32, op: UInt32, cmode: UInt32,
                             imm8: UInt32, rd: UInt32) -> UInt32 {
        (word(q: q, op: op, imm8: imm8, rd: rd) & ~0x0000_f000) | (cmode << 12)
    }

    private func assertLogicalFamily(op: UInt32, halfwords: Bool,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let modes: [(UInt32, Int)] = halfwords ? [(9, 0), (11, 8)] : [(1, 0), (3, 8), (5, 16), (7, 24)]
        for (cmode, shift) in modes {
            for q: UInt32 in [0, 1] {
                let arrangement = halfwords ? (q == 0 ? "4h" : "8h") : (q == 0 ? "2s" : "4s")
                for rd: UInt32 in [0, 31] {
                    for (imm8, immediate): (UInt32, String) in [(0, "#0"), (0xff, "#0xff")] {
                        let encoding = logicalWord(q: q, op: op, cmode: cmode, imm8: imm8, rd: rd)
                        let row = try decode(encoding, file: file, line: line)
                        let mnemonic = op == 0 ? "orr" : "bic"
                        let suffix = shift == 0 ? "" : ", lsl #\(shift)"
                        let operands = "v\(rd).\(arrangement), \(immediate)\(suffix)"
                        let label = String(format: "0x%08x", encoding)
                        XCTAssertEqual(row.mnemonic, mnemonic, label, file: file, line: line)
                        XCTAssertEqual(row.operands, operands, label, file: file, line: line)
                        XCTAssertNil(row.branchTarget, file: file, line: line)
                        let model = try XCTUnwrap(row.structuredOperands, file: file, line: line)
                        XCTAssertEqual(model.coverage, .unavailable, file: file, line: line)
                        XCTAssertEqual(model.operands, [.opaque(operands)], file: file, line: line)
                    }
                }
            }
        }
    }

    func testORRWordImmediatesDecodeBothWidthsAllShiftsAndDestination31() throws {
        try assertLogicalFamily(op: 0, halfwords: false)
    }

    func testBICWordImmediatesDecodeBothWidthsAllShiftsAndDestination31() throws {
        try assertLogicalFamily(op: 1, halfwords: false)
    }

    func testORRHalfwordImmediatesDecodeBothWidthsAllShiftsAndDestination31() throws {
        try assertLogicalFamily(op: 0, halfwords: true)
    }

    func testBICHalfwordImmediatesDecodeBothWidthsAllShiftsAndActualWord() throws {
        XCTAssertEqual(logicalWord(q: 1, op: 1, cmode: 11, imm8: 0xff, rd: 5), 0x6f07_b7e5)
        let actual = try decode(0x6f07_b7e5, at: 0x1b8d8)
        XCTAssertEqual(actual.byteText, "e5 b7 07 6f")
        XCTAssertEqual(actual.mnemonic, "bic")
        XCTAssertEqual(actual.operands, "v5.8h, #0xff, lsl #8")
        try assertLogicalFamily(op: 1, halfwords: true)
    }

    func testLogicalO2RefusalsAndExistingImmediateNeighborsRemainUnchanged() throws {
        for cmode: UInt32 in [1, 3, 5, 7, 9, 11] {
            for q: UInt32 in [0, 1] {
                for op: UInt32 in [0, 1] {
                    try assertUnknown(logicalWord(q: q, op: op, cmode: cmode, imm8: 0xff, rd: 31) | 0x800)
                }
            }
        }
        try assertUnknown(0x2f01_f400) // Reserved double-precision FMOV with Q=0.
        try assertUnknown(0x4f01_fc00) // Out-of-scope FP16 FMOV, o2=1.
        try assertFMOV(0x6f01_f400, operands: "v0.2d, #8.00000000")
        let neighbors: [(UInt32, String, String)] = [
            (0x0f00_0420, "movi", "v0.2s, #1"),
            (0x4f00_6420, "movi", "v0.4s, #1, lsl #24"),
            (0x2f00_8420, "mvni", "v0.4h, #1"),
            (0x6f00_a420, "mvni", "v0.8h, #1, lsl #8"),
            (0x0f00_c400, "movi", "v0.2s, #0, msl #8"),
            (0x6f00_d400, "mvni", "v0.4s, #0, msl #16"),
            (0x4f07_e7e0, "movi", "v0.16b, #0xff"),
            (0x6f00_e400, "movi", "v0.2d, #0")
        ]
        for (word, mnemonic, operands) in neighbors {
            let row = try decode(word)
            XCTAssertEqual(row.mnemonic, mnemonic)
            XCTAssertEqual(row.operands, operands)
        }
        // Only this newly admitted positive causes the pre-fix behavioral red;
        // the o2 refusals and even-cmode/FMOV neighbors already pass.
        let admitted = try decode(0x6f07_b7e5)
        XCTAssertEqual(admitted.mnemonic, "bic")
        XCTAssertEqual(admitted.operands, "v5.8h, #0xff, lsl #8")
    }

    func testDecodedLogicalImmediatesKeepActualBuilderUnknownFallback() throws {
        for (word, mnemonic, operands): (UInt32, String, String) in [
            (0x4f00_1420, "orr", "v0.4s, #1"),
            (0x6f00_1420, "bic", "v0.4s, #1"),
            (0x4f07_77e0, "orr", "v0.4s, #0xff, lsl #24"),
            (0x6f07_b7e5, "bic", "v5.8h, #0xff, lsl #8")
        ] {
            let decoded = try decode(word, at: 0x1000)
            // This admission assertion supplies the pre-fix red. The existing
            // Builder refusal must remain honest after decoding is enabled.
            XCTAssertEqual(decoded.mnemonic, mnemonic)
            XCTAssertEqual(decoded.operands, operands)
            let rows = [InstructionRow(address: decoded.address, bytes: decoded.byteText,
                mnemonic: decoded.mnemonic, operands: decoded.operands,
                hasBreakpoint: false, comment: decoded.comment),
                InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret",
                    operands: "", hasBreakpoint: false, comment: nil)]
            let function = MacIRBuilder().buildFunction(name: "logical_immediate", instructions: rows)
            XCTAssertFalse(function.instructions.isEmpty)
            guard !function.instructions.isEmpty else { continue }
            if case let .unknown(_, _, actualMnemonic, actualOperands) = function.instructions[0].operation {
                XCTAssertEqual(actualMnemonic, decoded.mnemonic)
                XCTAssertEqual(actualOperands, decoded.operands)
            } else {
                XCTFail("A vector logical immediate must retain the actual unknown operation")
            }
            let text = PseudocodePrinter().print(function: function).text
            XCTAssertTrue(text.contains("__unknown("), text)
        }
    }

}
