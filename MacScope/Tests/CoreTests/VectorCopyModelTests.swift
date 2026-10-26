import Foundation
import XCTest
@testable import MacScope

final class VectorCopyModelTests: XCTestCase {
    func testInsertElementPreservesAllOtherBitsAndReadsBeforeWriting() throws {
        let descriptor = try XCTUnwrap(MacIRNEONBitView(kind: .insertElement,
            elementBits: 8, sourceLane: 15, destinationLane: 0))
        let result = descriptor.vectorBits(sourceLow: 0, sourceHigh: 0xab00_0000_0000_0000,
            oldLow: .max, oldHigh: 0x1234)
        XCTAssertEqual(result.low, 0xffff_ffff_ffff_ffab)
        XCTAssertEqual(result.high, 0x1234)
        let halfword = try XCTUnwrap(MacIRNEONBitView(kind: .insertElement,
            elementBits: 16, sourceLane: 0, destinationLane: 7))
        let high = halfword.vectorBits(sourceLow: 0xabcd, sourceHigh: 0,
            oldLow: 0x55, oldHigh: .max)
        XCTAssertEqual(high.low, 0x55)
        XCTAssertEqual(high.high, 0xabcd_ffff_ffff_ffff)
        XCTAssertNil(MacIRNEONBitView(kind: .insertElement, elementBits: 8, destinationLane: 16))
        XCTAssertNil(MacIRNEONBitView(kind: .duplicateElement, elementBits: 8))
    }

    func testInsertGPRTruncatesAndPreservesOtherHalf() throws {
        let word = try XCTUnwrap(MacIRNEONBitView(kind: .insertGPR, elementBits: 32, destinationLane: 3))
        XCTAssertTrue(word.sourceIsGPR)
        let bits = word.vectorBits(sourceLow: 0xffff_ffff_1234_5678, sourceHigh: .max,
            oldLow: 0x89, oldHigh: 0xaaaa_bbbb_cccc_dddd)
        XCTAssertEqual(bits.low, 0x89)
        XCTAssertEqual(bits.high, 0x1234_5678_cccc_dddd)
        let doubleword = try XCTUnwrap(MacIRNEONBitView(kind: .insertGPR, elementBits: 64, destinationLane: 1))
        let full = doubleword.vectorBits(sourceLow: .max, sourceHigh: 0, oldLow: 0x17, oldHigh: 0)
        XCTAssertEqual(full.low, 0x17)
        XCTAssertEqual(full.high, .max)
        XCTAssertNil(MacIRNEONBitView(kind: .insertGPR, elementBits: 32, sourceLane: 1))
        XCTAssertNil(MacIRBuilder.neonCopy(mnemonic: "ins", operandText: "v0.d[0], w1"))
        XCTAssertNil(MacIRBuilder.neonCopy(mnemonic: "ins", operandText: "v0.b[0], x1"))
        XCTAssertNil(MacIRBuilder.neonCopy(mnemonic: "ins", operandText: "v0.s[0], sp"))
        XCTAssertNotNil(MacIRBuilder.neonCopy(mnemonic: "ins", operandText: "v0.h[7], wzr"))
    }

    func testTableLookupRangeAndTBXPreservationWithQ0ZeroUpper() throws {
        let tbl = try XCTUnwrap(MacIRNEONTableLookup(kind: .tbl, width: .bytes8, tableCount: 1))
        let tbx = try XCTUnwrap(MacIRNEONTableLookup(kind: .tbx, width: .bytes8, tableCount: 1))
        let tables: [(low: UInt64, high: UInt64)] = [(0x0706_0504_0302_0100, 0x0f0e_0d0c_0b0a_0908)]
        let indices: (low: UInt64, high: UInt64) = (0xffff_ffff_ff10_0f00, .max)
        let zero = try XCTUnwrap(tbl.evaluate(tables: tables, index: indices, old: (.max, .max)))
        XCTAssertEqual(zero.low, 0x0f00)
        XCTAssertEqual(zero.high, 0)
        let preserve = try XCTUnwrap(tbx.evaluate(tables: tables, index: indices, old: (.max, .max)))
        XCTAssertEqual(preserve.low, 0xffff_ffff_ffff_0f00)
        XCTAssertEqual(preserve.high, 0)
        XCTAssertNotNil(MacIRBuilder.neonCopy(mnemonic: "tbl", operandText: "v0.16b, {v31.16b, v0.16b}, v0.16b"))
        XCTAssertNil(MacIRBuilder.neonCopy(mnemonic: "tbl", operandText: "v0.16b, {v1.16b, v3.16b}, v0.16b"))
        XCTAssertNil(MacIRBuilder.neonCopy(mnemonic: "tbl", operandText: "v0.16b, {v1.8b}, v0.16b"))
        XCTAssertNil(MacIRBuilder.neonCopy(mnemonic: "tbl", operandText: "v0.16b, {}, v0.16b"))
    }

    func testExtractUsesActiveSourceHalvesAndRejectsOutOfRangeOffset() throws {
        let extract = try XCTUnwrap(MacIRNEONExtract(width: .bytes8, byteOffset: 7))
        let result = extract.evaluate(nLow: 0x0706_0504_0302_0100, nHigh: .max,
            mLow: 0x0f0e_0d0c_0b0a_0908, mHigh: .max)
        XCTAssertEqual(result.low, 0x0e0d_0c0b_0a09_0807)
        XCTAssertEqual(result.high, 0)
        XCTAssertNil(MacIRBuilder.neonCopy(mnemonic: "ext", operandText: "v0.8b, v1.8b, v2.8b, #8"))
        XCTAssertNil(MacIRBuilder.neonCopy(mnemonic: "ext", operandText: "v0.8b, v1.16b, v2.8b, #0"))
    }

    func testEachNewEncodingLiftsTypedIRAndDestinationAliasIsSnapshot() throws {
        func row(_ offset: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
            .init(address: 0x1000 + offset, bytes: "", mnemonic: mnemonic, operands: operands,
                hasBreakpoint: false, comment: nil)
        }
        let rows = [row(0, "ins", "v0.d[1], x1"),
                    row(4, "ins", "v0.s[3], v0.s[0]"),
                    row(8, "tbl", "v0.16b, {v0.16b, v1.16b}, v0.16b"),
                    row(12, "ext", "v0.16b, v0.16b, v0.16b, #8"),
                    row(16, "ret", "")]
        let function = MacIRBuilder().buildFunction(name: "copy_rows", startAddress: 0x1000, instructions: rows)
        let insGPR = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1000 })
        XCTAssertEqual(insGPR.neonBitView?.kind, .insertGPR)
        let insVector = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1004 })
        XCTAssertEqual(insVector.neonBitView?.kind, .insertElement)
        guard case let .intrinsic(destination?, _, arguments) = insVector.operation else {
            return XCTFail("INS must carry typed semantics")
        }
        XCTAssertEqual(arguments.count, 2)
        XCTAssertEqual(arguments[0], arguments[1])
        XCTAssertNotEqual(destination, arguments[0])
        let table = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1008 })
        XCTAssertEqual(table.neonTableLookup?.tableCount, 2)
        guard case let .intrinsic(_, _, tableArguments) = table.operation else { return XCTFail("TBL") }
        XCTAssertEqual(tableArguments[0], tableArguments[2])
        XCTAssertEqual(function.instructions.first { $0.source.address == 0x100c }?.neonExtract?.byteOffset, 8)
    }
    func testUMOVAllLaneWidthsZeroExtendIntoPhysicalGPR() throws {
        for (bits, letter, index, prefix, encoding) in [(8, "b", 15, "w", UInt32(0x0e1f3c22)),
            (16, "h", 7, "w", 0x0e1e3c22), (32, "s", 3, "w", 0x0e1c3c22), (64, "d", 1, "x", 0x4e183c22)] {
            let descriptor = try XCTUnwrap(MacIRNEONBitView(kind: .unsignedMoveElement,
                elementBits: bits, sourceLane: index))
            XCTAssertTrue(descriptor.resultIsGPR)
            let expected: UInt64 = bits == 64 ? .max : (UInt64(1) << bits) - 1
            XCTAssertEqual(descriptor.selectedBits(low: 0, high: .max), expected)
            let operandText = "\(prefix)2, v1.\(letter)[\(index)]"
            let bytes = withUnsafeBytes(of: encoding.littleEndian) { Data($0) }
            let decoded = try XCTUnwrap(ARM64Decoder().decode(bytes, baseAddress: 0x2000,
                maxInstructionCount: 1).first)
            XCTAssertEqual(decoded.mnemonic, "umov")
            XCTAssertEqual(decoded.operands, operandText)
            let parsed = try XCTUnwrap(MacIRBuilder.neonCopy(mnemonic: "umov", operandText: operandText))
            var state = BuilderState(parameters: [])
            state.permitsNEONBufferCarrier = true
            _ = state.writeRegister("x2") // A prior full-width value must not leak.
            let source = MacIRSourceSpan(address: 0x2000, byteText: "", mnemonic: "umov",
                operands: operandText, comment: nil)
            let instruction = MacIRBuilder.liftNEONCopy(parsed, source: source, state: &state)
            XCTAssertEqual(instruction.neonBitView?.elementBits, bits)
            guard case let .intrinsic(destination?, _, arguments) = instruction.operation else {
                return XCTFail("UMOV must carry typed extraction semantics")
            }
            XCTAssertEqual(arguments.count, 1)
            let wideRead = state.readRegister("x2")
            if bits < 64 {
                XCTAssertEqual(wideRead, .unary(op: "(uint64_t)",
                    value: .unary(op: "(uint32_t)", value: destination)))
            } else { XCTAssertEqual(wideRead, destination) }
        }
        XCTAssertNil(MacIRBuilder.neonCopy(mnemonic: "umov", operandText: "x0, v1.s[0]"))
        XCTAssertNil(MacIRBuilder.neonCopy(mnemonic: "umov", operandText: "w0, v1.d[0]"))
        XCTAssertNil(MacIRBuilder.neonCopy(mnemonic: "umov", operandText: "w0, v1.b[16]"))
        XCTAssertNotNil(MacIRBuilder.neonCopy(mnemonic: "umov", operandText: "wzr, v1.b[15]"))
    }

}
