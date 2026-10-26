import Foundation
import XCTest
@testable import MacScope

final class ARM64StructuredOperandEmissionTests: XCTestCase {
    func testFoundationWordTableTextAndFields() throws {
        typealias Model = InstructionOperands
        let pc: UInt64 = 0x100001000
        // Bounded literal words from D06, ARM64DisassemblyTests and SIMDByElementScalarTests.
        let words: [(UInt32, String, String)] = [
            (0x910003fd, "mov", "x29, sp"),
            (0xd10083ff, "sub", "sp, sp, #0x20"),
            (0x7100141f, "cmp", "w0, #5"),
            (0xd2800008, "mov", "x8, #0"),
            (0xd2aacf01, "mov", "x1, #0x56780000"),
            (0x92801fe2, "mov", "x2, #-0x100"),
            (0xf2d579a3, "movk", "x3, #0xabcd, lsl #32"),
            (0x100000a0, "adr", "x0, 0x0000000100001014"),
            (0x8b090c4e, "add", "x14, x2, x9, lsl #3"),
            (0x4b540a72, "sub", "w18, w19, w20, lsr #2"),
            (0xeb01001f, "cmp", "x0, x1"),
            (0xcb0703e6, "neg", "x6, x7"),
            (0x8b25c883, "add", "x3, x4, w5, sxtw #2"),
            (0x8b2163e0, "add", "x0, sp, x1"),
            (0xf85f8020, "ldur", "x0, [x1, #-0x8]"),
            (0xf8410420, "ldr", "x0, [x1], #0x10"),
            (0xf81f0c62, "str", "x2, [x3, #-0x10]!"),
            (0xf900083f, "str", "xzr, [x1, #0x10]"),
            (0xb8255883, "str", "w3, [x4, w5, uxtw #2]"),
            (0xf862c820, "ldr", "x0, [x1, w2, sxtw]"),
            (0x694087e0, "ldpsw", "x0, x1, [sp, #4]"),
            (0xa9bf7bfd, "stp", "x29, x30, [sp, #-0x10]!"),
            (0x28c110a3, "ldp", "w3, w4, [x5], #8"),
            (0x54000040, "b.eq", "0x0000000100001008"),
            (0x14000002, "b", "0x0000000100001008"),
            (0xb4000040, "cbz", "x0, 0x0000000100001008"),
            (0x36000040, "tbz", "w0, #0, 0x0000000100001008"),
            (0xd53b4200, "mrs", "x0, nzcv"),
            (0xd51b4201, "msr", "nzcv, x1"),
            (0xd539b04a, "mrs", "x10, s3_1_c11_c0_2"),
            (0x4fa28020, "mul", "v0.4s, v1.4s, v2.s[1]"),
            (0x6f720020, "mla", "v0.8h, v1.8h, v2.h[3]"),
            (0x4e629485, "mla", "v5.8h, v4.8h, v2.8h"),
            (0x0e229485, "mla", "v5.8b, v4.8b, v2.8b")
        ]
        let decoder = ARM64Decoder(validateStructuredOperands: true)
        func decode(_ word: UInt32, at address: UInt64) throws -> DecodedInstruction {
            let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                              UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
            return try XCTUnwrap(decoder.decode(bytes, baseAddress: address, maxInstructionCount: 1).first)
        }
        var models: [UInt32: Model] = [:]
        for (word, mnemonic, operands) in words {
            let decoded = try decode(word, at: pc)
            XCTAssertEqual(decoded.mnemonic, mnemonic, String(word, radix: 16))
            XCTAssertEqual(decoded.operands, operands, String(word, radix: 16))
            let model = try XCTUnwrap(decoded.structuredOperands)
            XCTAssertEqual(model.coverage, .complete, String(word, radix: 16))
            let rendered = try XCTUnwrap(ARM64OperandRenderer.render(model, legacyMnemonic: "WRONG", legacyOperands: "WRONG"))
            XCTAssertEqual(rendered.mnemonic, decoded.mnemonic)
            XCTAssertEqual(rendered.operands, decoded.operands)
            XCTAssertEqual(InstructionRow(decoded: decoded).structuredOperands, model)
            models[word] = model
        }
        func register(_ word: UInt32, _ index: Int) throws -> Model.Register {
            guard case let .register(value) = try XCTUnwrap(models[word]).operands[index] else {
                XCTFail("missing register"); throw NSError(domain: "fixture", code: 1)
            }
            return value
        }
        func memory(_ word: UInt32) throws -> Model.Memory {
            let operand = try XCTUnwrap(models[word]?.operands.last)
            guard case let .memory(value) = operand else { XCTFail("missing memory"); throw NSError(domain: "fixture", code: 2) }
            return value
        }
        XCTAssertEqual(try register(0xd10083ff, 0).role, .stackPointer)
        XCTAssertEqual(try register(0xf900083f, 0).role, .zero)
        XCTAssertEqual(models[0xd2800008]?.opcodeClass, "movz")
        XCTAssertEqual(models[0x92801fe2]?.opcodeClass, "movn")
        guard case let .immediate(movz) = try XCTUnwrap(models[0xd2aacf01]).operands[1] else { return XCTFail("missing MOVZ bits") }
        XCTAssertEqual(movz.encodedWidth, 16)
        XCTAssertEqual(movz.encodedValue, 0x5678)
        XCTAssertEqual(movz.encodedShift, 16)
        guard case let .modifiedRegister(naturalRegister, naturalExtension) = try XCTUnwrap(models[0x8b2163e0]).operands[2] else { return XCTFail("missing extension") }
        XCTAssertEqual(naturalRegister.width, 64)
        XCTAssertEqual(naturalExtension.kind, .uxtx)
        XCTAssertEqual(naturalExtension.presentationKind, .lsl)
        XCTAssertEqual(try memory(0xf85f8020).displacement, -8)
        XCTAssertFalse(try memory(0xf85f8020).writeback)
        XCTAssertEqual(try memory(0xf8410420).indexing, .postIndex)
        XCTAssertTrue(try memory(0xf8410420).writeback)
        XCTAssertEqual(try memory(0xf81f0c62).indexing, .preIndex)
        XCTAssertEqual(try memory(0xf81f0c62).displacement, -16)
        XCTAssertEqual(try memory(0xb8255883).modifier?.kind, .uxtw)
        XCTAssertEqual(try memory(0xb8255883).modifier?.amount, 2)
        XCTAssertEqual(try memory(0xb8255883).index?.width, 32)
        XCTAssertEqual(models[0xb8255883]?.semantics?.memoryAccess, .write)
        XCTAssertEqual(models[0x694087e0]?.semantics?.memoryAccessWidth, 32)
        XCTAssertEqual(models[0x694087e0]?.semantics?.memoryAccess, .read)
        XCTAssertEqual(try register(0x694087e0, 0).width, 64)
        XCTAssertEqual(try memory(0x694087e0).base.role, .stackPointer)
        XCTAssertEqual(models[0x54000040]?.operands.last, .condition(.eq))
        guard case let .systemRegister(sysreg) = try XCTUnwrap(models[0xd53b4200]).operands[1] else { return XCTFail("missing system bits") }
        XCTAssertEqual(sysreg.encoding, 0xda10)
        XCTAssertEqual(sysreg.spelling, "nzcv")
        XCTAssertEqual(try register(0x4fa28020, 2).lane, 1)
        XCTAssertEqual(try register(0x4fa28020, 2).arrangement?.elementWidth, 32)
        XCTAssertEqual(try register(0x6f720020, 2).lane, 3)
        XCTAssertEqual(try register(0x6f720020, 2).index, 2)
        XCTAssertEqual(try register(0x4e629485, 0).arrangement?.laneCount, 8)
        XCTAssertEqual(try register(0x0e229485, 0).width, 64)

        let page = try decode(0xd0000008, at: 0x10000000c)
        let pageModel = try XCTUnwrap(page.structuredOperands)
        XCTAssertEqual(pageModel.coverage, .complete)
        XCTAssertEqual(page.operands, "x8, 0x0000000100002000")
        let pageRendered = try XCTUnwrap(ARM64OperandRenderer.render(pageModel, legacyMnemonic: "WRONG", legacyOperands: "WRONG"))
        XCTAssertEqual(pageRendered.mnemonic, page.mnemonic)
        XCTAssertEqual(pageRendered.operands, page.operands)
        guard case let .pcRelative(pageReference) = pageModel.operands[1] else { return XCTFail("missing page reference") }
        XCTAssertTrue(pageReference.pageRelative)
        XCTAssertEqual(pageReference.displacement, 8192)

        let overflow = try decode(0x100000a0, at: UInt64.max - 3)
        let overflowModel = try XCTUnwrap(overflow.structuredOperands)
        XCTAssertEqual(overflowModel.coverage, .partial)
        guard case let .pcRelative(reference) = overflowModel.operands[1] else { return XCTFail("missing overflow reference") }
        XCTAssertNil(reference.target)
        XCTAssertNotNil(reference.diagnostic)
        let overflowRendered = try XCTUnwrap(ARM64OperandRenderer.render(overflowModel, legacyMnemonic: overflow.mnemonic, legacyOperands: overflow.operands))
        XCTAssertEqual(overflowRendered.mnemonic, "adr")
        XCTAssertEqual(overflowRendered.operands, "x0, <address overflow>")

        let opaque = try decode(0x4e284820, at: pc)
        let opaqueModel = try XCTUnwrap(opaque.structuredOperands)
        XCTAssertEqual(opaqueModel.coverage, .unavailable)
        XCTAssertEqual(opaqueModel.operands, [.opaque("v0.16b, v1.16b")])
        let opaqueRendered = try XCTUnwrap(ARM64OperandRenderer.render(opaqueModel, legacyMnemonic: opaque.mnemonic, legacyOperands: opaque.operands))
        XCTAssertEqual(opaqueRendered.mnemonic, "aese")
        XCTAssertEqual(opaqueRendered.operands, "v0.16b, v1.16b")
        // 35 complete samples, one checked overflow and one deliberately unmigrated sample.
        XCTAssertEqual(words.count, 34)
    }
}
