import Foundation
import XCTest
@testable import MacScope

/// DP04 A3: MacIR memory addressing consumes complete typed sidecars and must lower
/// exactly like the legacy text path; incomplete or mismatched sidecars fall back.
final class StructuredOperandConsumerTests: XCTestCase {
    private let decoder = ARM64Decoder(validateStructuredOperands: true)

    private func row(_ word: UInt32, at address: UInt64) throws -> InstructionRow {
        let bytes = Data((0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) })
        return InstructionRow(decoded: try XCTUnwrap(decoder.decode(bytes, baseAddress: address,
                                                                    maxInstructionCount: 1).first))
    }

    func testMemoryAddressingTypedAndTextTwinsLowerIdentically() throws {
        // A2 memory words (ARM64StructuredOperandEmissionTests) behind a small
        // prologue so SP-relative slots and frame bases are exercised.
        let memoryWords: [UInt32] = [
            0xf85f8020, // ldur x0, [x1, #-0x8]
            0xf8410420, // ldr x0, [x1], #0x10
            0xf81f0c62, // str x2, [x3, #-0x10]!
            0xf900083f, // str xzr, [x1, #0x10]
            0xb8255883, // str w3, [x4, w5, uxtw #2]
            0xf862c820, // ldr x0, [x1, w2, sxtw]
            0x694087e0, // ldpsw x0, x1, [sp, #4]
            0xa9bf7bfd, // stp x29, x30, [sp, #-0x10]!
            0x28c110a3, // ldp w3, w4, [x5], #8
        ]
        let prologue: [UInt32] = [0xd10083ff, 0x910003fd] // sub sp, sp, #0x20; mov x29, sp
        for word in memoryWords {
            var rows = try (prologue + [word]).enumerated().map { try row($0.element, at: 0x1000 + UInt64($0.offset * 4)) }
            rows.append(InstructionRow(address: 0x100c, bytes: "", mnemonic: "ret", operands: "",
                                       hasBreakpoint: false, comment: nil))
            let typedRow = rows[2]
            let span = MacIRSourceSpan(address: typedRow.address, byteText: typedRow.bytes,
                                       mnemonic: typedRow.mnemonic.lowercased(), operands: typedRow.operands,
                                       structuredOperands: typedRow.structuredOperands)
            XCTAssertNotNil(MacIRBuilder.typedMemoryOperand(of: span), "typed path not taken for \(typedRow.operands)")
            let textRows = rows.map { row -> InstructionRow in var copy = row; copy.structuredOperands = nil; return copy }
            let typed = MacIRBuilder().buildFunction(name: "typed", startAddress: 0x1000, instructions: rows)
            let text = MacIRBuilder().buildFunction(name: "text", startAddress: 0x1000, instructions: textRows)
            XCTAssertEqual(typed.instructions.map(\.operation), text.instructions.map(\.operation),
                           "\(typedRow.mnemonic) \(typedRow.operands)")
            XCTAssertEqual(typed.localVariables, text.localVariables, "\(typedRow.mnemonic) \(typedRow.operands)")
        }
    }

    func testMismatchedOrIncompleteSidecarFallsBackToText() throws {
        let decoded = try row(0xf85f8020, at: 0x1000) // ldur x0, [x1, #-0x8]
        // The same sidecar under different text must not be trusted.
        let mismatched = MacIRSourceSpan(address: 0x1000, byteText: decoded.bytes, mnemonic: "ldur",
                                         operands: "x0, [x1, #-0x10]",
                                         structuredOperands: decoded.structuredOperands)
        XCTAssertNil(MacIRBuilder.typedMemoryOperand(of: mismatched))
        let unavailable = MacIRSourceSpan(address: 0x1000, byteText: decoded.bytes, mnemonic: "ldur",
                                          operands: decoded.operands,
                                          structuredOperands: .unavailable(mnemonic: "ldur", operands: decoded.operands))
        XCTAssertNil(MacIRBuilder.typedMemoryOperand(of: unavailable))
        // A complete memory operand with an SP index never collapses to a stack slot.
        let spIndexed = InstructionOperands.Memory(
            base: .init(index: 31, width: 64, role: .stackPointer), index: .init(index: 2, width: 64))
        let value = MacIRBuilder.structuredMemoryValue(spIndexed, state: BuilderState())
        if case .stackSlot = value { XCTFail("an indexed SP address is computed, not a slot") }
    }

    private func shape(_ trees: [[ExprNode]]) -> [[String]] {
        trees.map { $0.map { "\($0.kind.rawValue):\($0.symbol):\($0.immediate):\($0.parentIndex.map(String.init) ?? "-")" } }
    }

    private func textTrees(_ row: InstructionRow) -> [[ExprNode]] {
        // The exporter's text path: top-level split with shift/extend regrouping.
        let tokens = BinExport2OperandParser.splitTopLevelOperands(row.operands)
        var grouped: [String] = []
        var index = 0
        let modifiers: Set<String> = ["lsl", "lsr", "asr", "ror", "rrx", "uxtw", "uxtx", "uxtb", "uxth",
                                      "sxtw", "sxtx", "sxtb", "sxth"]
        while index < tokens.count {
            if index + 1 < tokens.count,
               let word = tokens[index + 1].lowercased().split(separator: " ").first, modifiers.contains(String(word)) {
                grouped.append(tokens[index] + ", " + tokens[index + 1]); index += 2
            } else { grouped.append(tokens[index]); index += 1 }
        }
        return grouped.map { BinExport2OperandParser.parseOperandTree($0, arch: "arm64") }
    }

    func testBinExportTypedTreesMatchTextWhereTextIsRightAndImproveVectorAndExtendedIndex() throws {
        let parity: [UInt32] = [
            0x910003fd, 0xd10083ff, 0x7100141f, 0xd2800008, 0x92801fe2, 0xf2d579a3, 0x100000a0,
            0x8b090c4e, 0x4b540a72, 0xeb01001f, 0xcb0703e6, 0x8b2163e0, 0xf85f8020, 0xf8410420,
            0xf81f0c62, 0xf900083f, 0x694087e0, 0xa9bf7bfd, 0x28c110a3, 0x54000040, 0x14000002,
            0xb4000040, 0x36000040,
        ]
        for word in parity {
            let decoded = try row(word, at: 0x1_0000_1000)
            let typed = try XCTUnwrap(BinExport2OperandParser.structuredOperandTrees(
                decoded.structuredOperands, mnemonic: decoded.mnemonic, operands: decoded.operands),
                "\(decoded.mnemonic) \(decoded.operands)")
            XCTAssertEqual(shape(typed), shape(textTrees(decoded)), "\(decoded.mnemonic) \(decoded.operands)")
        }
        // Vector registers are registers, not symbols.
        let vector = try row(0x4fa28020, at: 0x1_0000_1000) // mul v0.4s, v1.4s, v2.s[1]
        let vectorTrees = try XCTUnwrap(BinExport2OperandParser.structuredOperandTrees(
            vector.structuredOperands, mnemonic: vector.mnemonic, operands: vector.operands))
        XCTAssertEqual(vectorTrees.map { $0.map(\.symbol) }, [["v0.4s"], ["v1.4s"], ["v2.s[1]"]])
        XCTAssertTrue(vectorTrees.allSatisfy { $0.count == 1 && $0[0].kind == .register })
        XCTAssertEqual(textTrees(vector).first?.first?.kind, .symbol, "the text parser reads v0.4s as a symbol")
        // An extended memory index is an op subtree, not a symbol "uxtw #2".
        let extended = try row(0xb8255883, at: 0x1_0000_1000) // str w3, [x4, w5, uxtw #2]
        let extendedTrees = try XCTUnwrap(BinExport2OperandParser.structuredOperandTrees(
            extended.structuredOperands, mnemonic: extended.mnemonic, operands: extended.operands))
        XCTAssertEqual(shape(extendedTrees)[1], ["7::0:-", "4:+:0:0", "5:x4:0:1", "4:uxtw:0:1", "5:w5:0:3", "2::2:3"])
        // Unavailable or mismatched sidecars keep the text path.
        XCTAssertNil(BinExport2OperandParser.structuredOperandTrees(
            .unavailable(mnemonic: "ldur", operands: "x0, [x1, #-0x8]"), mnemonic: "ldur", operands: "x0, [x1, #-0x8]"))
        let ldur = try row(0xf85f8020, at: 0x1_0000_1000)
        XCTAssertNil(BinExport2OperandParser.structuredOperandTrees(
            ldur.structuredOperands, mnemonic: "ldur", operands: "x0, [x1, #-0x10]"))
    }

    func testStructureMemoryFramesConfirmAgainstTypedRegisterLists() throws {
        func describe(_ value: MacIRBuilder.NEONInterleavedOperands?) -> String {
            value.map { "\($0.effect) \($0.activeBytes) \($0.elementBytes) \($0.structureCount) \($0.vectors) \($0.base) \($0.postIndex) \(String(describing: $0.incrementRegister))" } ?? "nil"
        }
        func describe(_ value: MacIRBuilder.NEONStructureLaneOperands?) -> String {
            value.map { "\($0.effect) \($0.elementBytes) \($0.laneIndex) \($0.structureCount) \($0.vectors) \($0.base) \($0.postIndex) \(String(describing: $0.incrementRegister))" } ?? "nil"
        }
        func stripped(_ row: InstructionRow) -> InstructionRow { var copy = row; copy.structuredOperands = nil; return copy }
        // Multiple structure: immediate post-index, register post-index, SP base with a wrapped list.
        for word: UInt32 in [0x4cdf_0500, 0x0c89_4120, 0x0c00_43ff] {
            let decoded = try row(word, at: 0x1000)
            XCTAssertNotNil(decoded.structuredOperands, decoded.operands)
            let typed = MacIRBuilder.neonInterleavedMemory(decoded)
            XCTAssertNotNil(typed, decoded.operands)
            XCTAssertEqual(describe(typed), describe(MacIRBuilder.neonInterleavedMemory(stripped(decoded))), decoded.operands)
        }
        // Structure lane: none, immediate and register post-index.
        for word: UInt32 in [0x0d60_2120, 0x0d9f_2120, 0x0de9_2120] {
            let decoded = try row(word, at: 0x1000)
            let typed = MacIRBuilder.neonStructureLaneMemory(decoded)
            XCTAssertNotNil(typed, decoded.operands)
            XCTAssertEqual(describe(typed), describe(MacIRBuilder.neonStructureLaneMemory(stripped(decoded))), decoded.operands)
        }
        // The typed confirmation really checks fields: `ld4 {v0.b-v3.b}[0], [x9]`.
        let lane = try row(0x0d60_2120, at: 0x1000)
        XCTAssertTrue(MacIRBuilder.typedStructureOperandsMatch(
            lane, vectorIndices: [0, 1, 2, 3], elementBits: 8, vectorBits: nil, lane: 0,
            base: 9, postIndex: false, incrementRegister: nil, immediateStride: 4))
        XCTAssertFalse(MacIRBuilder.typedStructureOperandsMatch(
            lane, vectorIndices: [0, 1, 2, 3], elementBits: 8, vectorBits: nil, lane: 1,
            base: 9, postIndex: false, incrementRegister: nil, immediateStride: 4), "wrong lane")
        XCTAssertFalse(MacIRBuilder.typedStructureOperandsMatch(
            stripped(lane), vectorIndices: [0, 1, 2, 3], elementBits: 8, vectorBits: nil, lane: 0,
            base: 9, postIndex: false, incrementRegister: nil, immediateStride: 4), "no sidecar")
    }
}
