import Foundation
import XCTest
@testable import MacScope

final class StructuredOperandModelTests: XCTestCase {
    private typealias Model = InstructionOperands

    func testExplicitSignedDecimalPresentation() {
        let immediate = Model(coverage: .complete, opcodeClass: "mov", operands: [.immediate(.init(.signed(-16), format: .decimal))])
        let memory = Model(coverage: .complete, opcodeClass: "ldr", operands: [.memory(.init(base: .init(index: 1, width: 64), displacement: -16, displacementFormat: .decimal))])
        XCTAssertEqual(ARM64OperandRenderer.render(immediate, legacyMnemonic: "WRONG", legacyOperands: "WRONG")?.operands, "#-16")
        XCTAssertEqual(ARM64OperandRenderer.render(memory, legacyMnemonic: "WRONG", legacyOperands: "WRONG")?.operands, "[x1, #-16]")
    }

    func testLegacyRowsAndLosslessPresentation() throws {
        // Pre-sidecar JSON remains readable, without inventing typed facts from its strings.
        let legacyJSON = Data(#"{"address":4096,"bytes":"c0 03 5f d6","mnemonic":"ret","operands":"","hasBreakpoint":false,"comment":null}"#.utf8)
        let legacyRow = try JSONDecoder().decode(InstructionRow.self, from: legacyJSON)
        XCTAssertEqual(legacyRow, InstructionRow(address: 4096, bytes: "c0 03 5f d6", mnemonic: "ret",
                                                operands: "", hasBreakpoint: false, comment: nil))
        let legacyDecode = DecodedInstruction(address: 4096, bytes: [0xc0, 0x03, 0x5f, 0xd6],
                                             mnemonic: "ret", operands: "", branchTarget: nil, comment: nil)
        XCTAssertEqual(legacyDecode.mnemonic, legacyRow.mnemonic)
        XCTAssertEqual(legacyDecode.operands, legacyRow.operands)

        XCTAssertNil(legacyRow.structuredOperands)
        XCTAssertNil(legacyDecode.structuredOperands)
        let sidecar = Model.unavailable(mnemonic: "ret", operands: "")
        var carried = legacyDecode
        carried.structuredOperands = sidecar
        let row = InstructionRow(decoded: carried)
        XCTAssertEqual(row.structuredOperands, sidecar)
        XCTAssertEqual(row.mnemonic, carried.mnemonic)
        XCTAssertEqual(row.operands, carried.operands)
        XCTAssertEqual(row.bytes, carried.byteText)
        XCTAssertEqual(try JSONDecoder().decode(InstructionRow.self, from: JSONEncoder().encode(row)), row)
        let decoded = ARM64Decoder(validateStructuredOperands: true).decode(Data([0xc0, 0x03, 0x5f, 0xd6]), baseAddress: 4096)[0]
        XCTAssertEqual(decoded.structuredOperands?.coverage, .unavailable)

        let sp = Model.Register(index: 31, width: 64, role: .stackPointer)
        let wsp = Model.Register(index: 31, width: 32, role: .stackPointer)
        let xzr = Model.Register(index: 31, width: 64, role: .zero)
        let wzr = Model.Register(index: 31, width: 32, role: .zero)
        let x0 = Model.Register(index: 0, width: 64)
        let x1 = Model.Register(index: 1, width: 64)
        let w2 = Model.Register(index: 2, width: 32)
        let v0 = Model.Register(bank: .simd, index: 0, width: 128,
                               arrangement: .init(elementWidth: 32, laneCount: 4))
        let v1 = Model.Register(bank: .simd, index: 1, width: 128,
                               arrangement: .init(elementWidth: 32, laneCount: 4))
        let h3 = Model.Register(bank: .simd, index: 3, width: 128,
                               arrangement: .init(elementWidth: 16), lane: 7)
        func complete(_ opcode: String, _ operands: [Model.Operand],
                      presentation: Model.Presentation = .init(), semantics: Model.Semantics? = nil) -> Model {
            .init(coverage: .complete, opcodeClass: opcode, operands: operands,
                  presentation: presentation, semantics: semantics)
        }
        let alias = complete("movz", [.register(x0), .immediate(.init(.unsigned(0x120000),
                             encodedWidth: 16, encodedValue: 0x12, encodedShift: 16))],
                             presentation: .init(mnemonic: "movz", alias: "mov"))
        let cases: [(Model, String, String)] = [
            (complete("mov", [.register(sp), .register(xzr)]), "mov", "sp, xzr"),
            (complete("mov", [.register(wsp), .register(wzr)]), "mov", "wsp, wzr"),
            (alias, "mov", "x0, #0x120000"),
            (complete("add", [.register(x0), .modifiedRegister(x1, .init(.lsl, amount: 0, omitWhenZero: true))]),
             "add", "x0, x1"),
            (complete("add", [.register(x0), .modifiedRegister(w2, .init(.uxtw, amount: 0, omitZeroAmount: true))]),
             "add", "x0, w2, uxtw"),
            (complete("movi", [.register(v0), .modifiedImmediate(.init(.unsigned(17), encodedWidth: 8),
                                                               .init(.msl, amount: 16))]),
             "movi", "v0.4s, #0x11, msl #16"),
            (complete("dup", [.register(v0), .register(h3)]), "dup", "v0.4s, v3.h[7]"),
            (complete("ldr", [.register(x0), .memory(.init(base: sp))],
                      semantics: .init(memoryAccessWidth: 64, memoryAccess: .read)), "ldr", "x0, [sp]"),
            (complete("ldr", [.register(x0), .memory(.init(base: sp))],
                      presentation: .init(omitZeroOffset: false)), "ldr", "x0, [sp, #0]"),
            (complete("ldr", [.register(x0), .memory(.init(base: sp, displacement: -16,
                         indexing: .preIndex, writeback: true))]), "ldr", "x0, [sp, #-0x10]!"),
            (complete("ldr", [.register(x0), .memory(.init(base: sp, indexing: .preIndex, writeback: true))]),
             "ldr", "x0, [sp, #0]!"),
            (complete("str", [.register(x0), .memory(.init(base: sp, indexing: .postIndex, writeback: true))],
                      semantics: .init(memoryAccessWidth: 64, memoryAccess: .write)), "str", "x0, [sp], #0"),
            (complete("ldr", [.register(x0), .memory(.init(base: x1, index: w2,
                                       modifier: .init(.sxtw, amount: 3)))]), "ldr", "x0, [x1, w2, sxtw #3]"),
            (complete("st2", [.registerList([v0, v1]), .memory(.init(base: sp, index: x1,
                         indexing: .postIndex, writeback: true))]), "st2", "{v0.4s, v1.4s}, [sp], x1"),
            (complete("st2", [.registerList([v0, v1]), .memory(.init(base: sp))],
                      presentation: .init(registerListBraces: false)), "st2", "v0.4s, v1.4s, [sp]"),
            (complete("ret", [.register(.init(index: 30, width: 64))],
                      presentation: .init(omittedOperandIndices: [0])), "ret", ""),
            (complete("b", [.pcRelative(.init(baseAddress: 0x1000, displacement: -4)), .condition(.ne)],
                      presentation: .init(conditionSuffixOperandIndex: 1)), "b.ne", "0x0000000000000ffc"),
            (complete("adrp", [.register(x0), .pcRelative(.init(baseAddress: 0x1fff,
                                           displacement: 0x1000, pageRelative: true))]),
             "adrp", "x0, 0x0000000000002000"),
            (complete("csel", [.register(x0), .register(x1), .register(xzr), .condition(.eq)]),
             "csel", "x0, x1, xzr, eq"),
            (complete("mrs", [.register(x0), .systemRegister(.init(encoding: 0xda10, spelling: "nzcv"))]),
             "mrs", "x0, nzcv"),
            (complete("mrs", [.register(x0), .systemRegister(.init(encoding: 0xda10))]),
             "mrs", "x0, s3_3_c4_c2_0"),
            (complete("dmb", [.option(.init(.barrier, value: 11, spelling: "ish"))]), "dmb", "ish"),
            (complete("prfm", [.option(.init(.prefetch, value: 31)), .memory(.init(base: x1))]),
             "prfm", "#0x1f, [x1]"),
            (complete("fmov", [.register(.init(bank: .simd, index: 2, width: 64)),
                               .immediate(.init(.floatingPoint(bitPattern: 0x8000000000000000, width: 64)))]),
             "fmov", "d2, #-0.0"),
            (complete("fmov", [.register(.init(bank: .simd, index: 2, width: 32)),
                               .immediate(.init(.floatingPoint(bitPattern: 0x3f800000, width: 32), encodedWidth: 8))]),
             "fmov", "s2, #1.0"),
            (complete("fmov", [.register(.init(bank: .simd, index: 2, width: 16)),
                               .immediate(.init(.floatingPoint(bitPattern: 0x3c00, width: 16)))]),
             "fmov", "h2, #1.0"),
            (complete("mov", [.register(x0), .immediate(.init(.unsigned(10), format: .decimal))]),
             "mov", "x0, #10"),
            (complete("mov", [.register(x0), .immediate(.init(.unsigned(1), format: .hexadecimal))]),
             "mov", "x0, #0x1"),
            (complete("mov", [.register(x0), .immediate(.init(.signed(.min)))]),
             "mov", "x0, #-0x8000000000000000"),
            (complete("mov", [.register(x0), .immediate(.init(.unsigned(1), format: .hexAddress))]),
             "mov", "x0, #0x0000000000000001"),
        ]
        for (model, mnemonic, operands) in cases {
            // Deliberately unrelated legacy strings make copying them a test failure.
            let rendered = try XCTUnwrap(ARM64OperandRenderer.render(model, legacyMnemonic: "WRONG", legacyOperands: "WRONG"))
            XCTAssertEqual(rendered.mnemonic, mnemonic)
            XCTAssertEqual(rendered.operands, operands)
            let roundtrip = try JSONDecoder().decode(Model.self, from: JSONEncoder().encode(model))
            XCTAssertEqual(roundtrip, model, "Codable lost typed fields for \(mnemonic) \(operands)")
            XCTAssertEqual(ARM64OperandRenderer.render(roundtrip, legacyMnemonic: "OTHER", legacyOperands: "OTHER"), rendered)
        }
        XCTAssertEqual(alias.opcodeClass, "movz", "alias display must not erase original opcode identity")
        XCTAssertNotEqual(sp, xzr)
        XCTAssertNotEqual(wsp, wzr)

        let unavailable = Model.unavailable(mnemonic: "legacy", operands: "{ V0.H },  #01  ")
        let partial = Model(coverage: .partial, opcodeClass: "partial", operands: [.register(x0), .opaque("unknown")])
        for model in [unavailable, partial] {
            let roundtrip = try JSONDecoder().decode(Model.self, from: JSONEncoder().encode(model))
            XCTAssertEqual(roundtrip, model)
            let result = try XCTUnwrap(ARM64OperandRenderer.render(roundtrip, legacyMnemonic: "raw", legacyOperands: "  untouched, #0001 "))
            XCTAssertEqual(result.mnemonic, model == unavailable ? "legacy" : "raw")
            XCTAssertEqual(result.operands, model == unavailable ? "{ V0.H },  #01  " : "  untouched, #0001 ")
        }
        let upperOverflow = Model.PCReference(baseAddress: .max, displacement: 1)
        let lowerOverflow = Model.PCReference(baseAddress: 0, displacement: -1)
        let minimumDisplacement = Model.PCReference(baseAddress: UInt64(1) << 63, displacement: .min)
        XCTAssertEqual(minimumDisplacement.target, 0)
        for reference in [upperOverflow, lowerOverflow] {
            XCTAssertNil(reference.target)
            XCTAssertNotNil(reference.diagnostic)
            XCTAssertNil(ARM64OperandRenderer.render(complete("b", [.pcRelative(reference)]),
                                                     legacyMnemonic: "b", legacyOperands: "0x0"))
        }
        let malformed = [
            complete("opaque", [.opaque("x0")]),
            complete("opaque", [.opaque("x0")], presentation: .init(omittedOperandIndices: [0])),
            complete("mov", [.register(.init(index: 31, width: 64))]),
            complete("mov", [.register(.init(index: 0, width: 64, role: .stackPointer))]),
            complete("dup", [.register(.init(bank: .simd, index: 0, width: 128,
                                       arrangement: .init(elementWidth: 16), lane: 8))]),
            complete("ldr", [.memory(.init(base: sp, indexing: .preIndex))]),
            complete("ldr", [.memory(.init(base: x1, index: w2, modifier: .init(.lsl, amount: 0)))]),
            complete("ret", [], presentation: .init(omittedOperandIndices: [0])),
            complete("b", [.register(x0)], presentation: .init(conditionSuffixOperandIndex: 0)),
            Model(architecture: .x86_64, coverage: .complete, opcodeClass: "ret"),
            Model(schemaVersion: 2, coverage: .complete, opcodeClass: "ret"),
        ]
        for model in malformed {
            XCTAssertNil(ARM64OperandRenderer.render(model, legacyMnemonic: "valid", legacyOperands: "x0"),
                         "invalid complete data must not silently acquire fallback semantics")
        }
    }
}
