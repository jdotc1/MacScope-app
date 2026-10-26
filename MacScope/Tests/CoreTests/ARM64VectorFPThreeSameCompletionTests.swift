import Foundation
import XCTest
@testable import MacScope

final class ARM64VectorFPThreeSameCompletionTests: XCTestCase {
    private let forms: [(UInt32, UInt32, UInt32, String)] = [
        (0, 0, 0x19, "fmla"), (0, 1, 0x19, "fmls"), (1, 1, 0x1a, "fabd"),
        (0, 0, 0x1f, "frecps"), (0, 1, 0x1f, "frsqrts")
    ]

    private func word(q: UInt32, sz: UInt32, u: UInt32, a: UInt32, opcode: UInt32,
                      rd: UInt32 = 0, rn: UInt32 = 31, rm: UInt32 = 1) -> UInt32 {
        0x0e20_0400 | (q << 30) | (u << 29) | (a << 23) | (sz << 22)
            | (rm << 16) | (opcode << 11) | (rn << 5) | rd
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

    private func assertDecoded(_ encoding: UInt32, at address: UInt64 = 0x1000,
                               mnemonic: String, operands: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try decode(encoding, at: address, file: file, line: line)
        let label = String(format: "0x%08x", encoding)
        XCTAssertEqual(row.mnemonic, mnemonic, label, file: file, line: line)
        XCTAssertEqual(row.operands, operands, label, file: file, line: line)
        XCTAssertNil(row.branchTarget, file: file, line: line)
        let model = try XCTUnwrap(row.structuredOperands, file: file, line: line)
        XCTAssertEqual(model.coverage, .unavailable, file: file, line: line)
        XCTAssertEqual(model.operands, [.opaque(operands)], file: file, line: line)
    }

    private func assertUnknown(_ encoding: UInt32,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try decode(encoding, file: file, line: line)
        XCTAssertEqual(row.mnemonic, "unknown", file: file, line: line)
        XCTAssertEqual(row.operands, String(format: "0x%08x", encoding), file: file, line: line)
    }

    private func assertFamily(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let (u, a, opcode, mnemonic) = try XCTUnwrap(forms.first { $0.3 == name }, file: file, line: line)
        for (q, sz, arrangement): (UInt32, UInt32, String) in [(0, 0, "2s"), (1, 0, "4s"), (1, 1, "2d")] {
            for (rd, rn, rm): (UInt32, UInt32, UInt32) in [(0, 31, 1), (31, 0, 31)] {
                try assertDecoded(word(q: q, sz: sz, u: u, a: a, opcode: opcode, rd: rd, rn: rn, rm: rm),
                    mnemonic: mnemonic, operands: "v\(rd).\(arrangement), v\(rn).\(arrangement), v\(rm).\(arrangement)",
                    file: file, line: line)
            }
        }
    }

    func testAllFourObservedOrdinaryFMLAWordsDecodeExactly() throws {
        let cases: [(UInt64, UInt32, String)] = [
            (0x3ce24, 0x4e25cc56, "v22.4s, v2.4s, v5.4s"),
            (0x3ce28, 0x4e30cc75, "v21.4s, v3.4s, v16.4s"),
            (0x3cf9c, 0x4e22cca7, "v7.4s, v5.4s, v2.4s"),
            (0x3cfa4, 0x4e21cc44, "v4.4s, v2.4s, v1.4s")
        ]
        for (address, encoding, operands) in cases {
            try assertDecoded(encoding, at: address, mnemonic: "fmla", operands: operands)
        }
    }

    func testFMLACoversAllocatedArrangementsAndRegister31() throws { try assertFamily("fmla") }
    func testFMLSCoversAllocatedArrangementsAndRegister31() throws { try assertFamily("fmls") }
    func testFABDCoversAllocatedArrangementsAndRegister31() throws { try assertFamily("fabd") }
    func testFRECPSCoversAllocatedArrangementsAndRegister31() throws { try assertFamily("frecps") }
    func testFRSQRTSCoversAllocatedArrangementsAndRegister31() throws { try assertFamily("frsqrts") }

    func testReservedAndExcludedCombinationsStayUnknownBesideExistingNeighbors() throws {
        for (u, a, opcode, _) in forms {
            try assertUnknown(word(q: 0, sz: 1, u: u, a: a, opcode: opcode)) // No .1d vector form.
        }
        for (q, sz): (UInt32, UInt32) in [(0, 0), (1, 0), (1, 1)] {
            for a: UInt32 in [0, 1] {
                for (u, opcode): (UInt32, UInt32) in [(1, 0x19), (0, 0x1d)] {
                    let encoding = word(q: q, sz: sz, u: u, a: a, opcode: opcode)
                    let bytes = (0..<4).map { UInt8(truncatingIfNeeded: encoding >> ($0 * 8)) }
                    // These tuples remain excluded from the ordinary helper.
                    let ordinary = ARM64Decoder().decodeSIMDThreeSame(word: encoding, bytes: bytes, address: 0x1000)
                    XCTAssertEqual(ordinary.mnemonic, "unknown")
                    XCTAssertEqual(ordinary.operands, String(format: "0x%08x", encoding))
                    if sz == 0 {
                        // The earlier shipping-extension route already owns
                        // these widening forms. Preserve its public decode.
                        let name = (a == 0 ? "fmlal" : "fmlsl") + (u == 1 ? "2" : "")
                        let dst = q == 0 ? "2s" : "4s", src = q == 0 ? "2h" : "4h"
                        try assertDecoded(encoding, mnemonic: name, operands: "v0.\(dst), v31.\(src), v1.\(src)")
                    } else {
                        try assertUnknown(encoding)
                    }
                }
            }
            try assertUnknown(word(q: q, sz: sz, u: 1, a: 1, opcode: 0x1f))
        }
        for (u, a, opcode, mnemonic): (UInt32, UInt32, UInt32, String) in [
            (0, 0, 0x1a, "fadd"), (0, 1, 0x1a, "fsub"), (1, 0, 0x1a, "faddp"),
            (0, 0, 0x1b, "fmulx"), (1, 0, 0x1b, "fmul"), (1, 0, 0x1f, "fdiv")
        ] {
            try assertDecoded(word(q: 1, sz: 0, u: u, a: a, opcode: opcode),
                              mnemonic: mnemonic, operands: "v0.4s, v31.4s, v1.4s")
        }
        // Existing separate FP16 and widening-by-element support is untouched.
        try assertDecoded(0x4e420c20, mnemonic: "fmla", operands: "v0.8h, v1.8h, v2.8h")
        try assertDecoded(0x0fb20820, mnemonic: "fmlal", operands: "v0.2s, v1.2h, v2.h[7]")
        // This newly admitted positive supplies the pre-fix behavioral red.
        try assertDecoded(0x4e25cc56, mnemonic: "fmla", operands: "v22.4s, v2.4s, v5.4s")
    }

    func testRecognizedFloatingFormsUseTypedFMLAOrRetainUnknownFallback() throws {
        for (u, a, opcode, mnemonic) in forms {
            let row = try decode(word(q: 1, sz: 0, u: u, a: a, opcode: opcode))
            XCTAssertEqual(row.mnemonic, mnemonic) // Missing decode supplies behavioral red.
            let rows = [InstructionRow(address: row.address, bytes: row.byteText,
                mnemonic: row.mnemonic, operands: row.operands, hasBreakpoint: false, comment: row.comment),
                InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret",
                    operands: "", hasBreakpoint: false, comment: nil)]
            let function = MacIRBuilder().buildFunction(name: "floating_three_same", instructions: rows)
            let first = try XCTUnwrap(function.instructions.first)
            if mnemonic == "fmla" {
                XCTAssertEqual(first.vectorFP?.semantics.operation, .fusedMultiplyAdd)
                XCTAssertNotNil(function.instructions.first { $0.vectorFPStatus != nil })
                XCTAssertNil(first.scalarFP)
                XCTAssertTrue(PseudocodePrinter().print(function: function).text.contains("normal completion"))
                continue
            }
            if case let .unknown(_, _, actualMnemonic, operands) = first.operation {
                XCTAssertEqual(actualMnemonic, row.mnemonic)
                XCTAssertEqual(operands, row.operands)
            } else {
                XCTFail("No exact ordinary vector FP lifter is authorized by this decoder change")
            }
            XCTAssertTrue(PseudocodePrinter().print(function: function).text.contains("__unknown("))
        }
    }
}
