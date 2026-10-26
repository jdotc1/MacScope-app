import Foundation
import XCTest
@testable import MacScope

final class ARM64StructuredSIMDMemoryTests: XCTestCase {
    func testStructureListsLanesAndPostIndexTextAndFields() throws {
        typealias Model = InstructionOperands
        // Existing bounded ARM64DisassemblyTests structure words, plus explicit SP/wrap variants.
        let fixtures: [(UInt32, String, String)] = [
            (0x4c407000, "ld1", "{v0.16b}, [x0]"),
            (0x4c40a420, "ld1", "{v0.8h, v1.8h}, [x1]"),
            (0x4c406840, "ld1", "{v0.4s, v1.4s, v2.4s}, [x2]"),
            (0x4c402c60, "ld1", "{v0.2d, v1.2d, v2.2d, v3.2d}, [x3]"),
            (0x0c408480, "ld2", "{v0.4h, v1.4h}, [x4]"),
            (0x0c4048a0, "ld3", "{v0.2s, v1.2s, v2.2s}, [x5]"),
            (0x0c4000c0, "ld4", "{v0.8b, v1.8b, v2.8b, v3.8b}, [x6]"),
            (0x0c0070c5, "st1", "{v5.8b}, [x6]"),
            (0x4c0088e0, "st2", "{v0.4s, v1.4s}, [x7]"),
            (0x0c0048a0, "st3", "{v0.2s, v1.2s, v2.2s}, [x5]"),
            (0x4c880ce0, "st4", "{v0.2d, v1.2d, v2.2d, v3.2d}, [x7], x8"),
            (0x4cdf2120, "ld1", "{v0.16b, v1.16b, v2.16b, v3.16b}, [x9], #64"),
            (0x0cdf80c0, "ld2", "{v0.8b, v1.8b}, [x6], #16"),
            (0x4c40ac1f, "ld1", "{v31.2d, v0.2d}, [x0]"),
            (0x0c407c20, "ld1", "{v0.1d}, [x1]"),
            (0x0c40ac20, "ld1", "{v0.1d, v1.1d}, [x1]"),
            (0x0d400c00, "ld1", "{v0.b}[3], [x0]"),
            (0x0d604840, "ld2", "{v0.h, v1.h}[1], [x2]"),
            (0x4d40a060, "ld3", "{v0.s, v1.s, v2.s}[2], [x3]"),
            (0x4d60a480, "ld4", "{v0.d, v1.d, v2.d, v3.d}[1], [x4]"),
            (0x4d00a060, "st3", "{v0.s, v1.s, v2.s}[2], [x3]"),
            (0x4d20a480, "st4", "{v0.d, v1.d, v2.d, v3.d}[1], [x4]"),
            (0x0d9f1420, "st1", "{v0.b}[5], [x1], #1"),
            (0x4dffb080, "ld4", "{v0.s, v1.s, v2.s, v3.s}[3], [x4], #16"),
            (0x0dc90020, "ld1", "{v0.b}[0], [x1], x9"),
            (0x0da90440, "st2", "{v0.b, v1.b}[1], [x2], x9"),
            (0x4d40c8c0, "ld1r", "{v0.4s}, [x6]"),
            (0x4d60c4e0, "ld2r", "{v0.8h, v1.8h}, [x7]"),
            (0x4d40e100, "ld3r", "{v0.16b, v1.16b, v2.16b}, [x8]"),
            (0x4d60e100, "ld4r", "{v0.16b, v1.16b, v2.16b, v3.16b}, [x8]"),
            (0x0dc9c020, "ld1r", "{v0.8b}, [x1], x9"),
            (0x4ddfc820, "ld1r", "{v0.4s}, [x1], #4"),
            (0x4dffc820, "ld2r", "{v0.4s, v1.4s}, [x1], #8"),
            (0x4c402fff, "ld1", "{v31.2d, v0.2d, v1.2d, v2.2d}, [sp]"),
            (0x4cdf23ff, "ld1", "{v31.16b, v0.16b, v1.16b, v2.16b}, [sp], #64"),
            (0x4c880fff, "st4", "{v31.2d, v0.2d, v1.2d, v2.2d}, [sp], x8"),
            (0x4dffb3ff, "ld4", "{v31.s, v0.s, v1.s, v2.s}[3], [sp], #16"),
            (0x0da907ff, "st2", "{v31.b, v0.b}[1], [sp], x9")
        ]
        let decoder = ARM64Decoder(validateStructuredOperands: true)
        var models: [UInt32: Model] = [:]
        for (word, mnemonic, operands) in fixtures {
            let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                              UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
            let decoded = try XCTUnwrap(decoder.decode(bytes, baseAddress: 0x1000, maxInstructionCount: 1).first)
            XCTAssertEqual(decoded.mnemonic, mnemonic, String(word, radix: 16))
            XCTAssertEqual(decoded.operands, operands, String(word, radix: 16))
            let model = try XCTUnwrap(decoded.structuredOperands)
            XCTAssertEqual(model.coverage, .complete)
            let rendered = try XCTUnwrap(ARM64OperandRenderer.render(model, legacyMnemonic: "WRONG", legacyOperands: "WRONG"))
            XCTAssertEqual(rendered.mnemonic, decoded.mnemonic)
            XCTAssertEqual(rendered.operands, decoded.operands)
            XCTAssertEqual(try JSONDecoder().decode(Model.self, from: JSONEncoder().encode(model)), model)
            models[word] = model
        }
        func list(_ word: UInt32) throws -> [Model.Register] {
            guard case let .registerList(registers) = try XCTUnwrap(models[word]).operands[0] else { throw NSError(domain: "missing list", code: 1) }
            return registers
        }
        func memory(_ word: UInt32) throws -> Model.Memory {
            guard case let .memory(memory) = try XCTUnwrap(models[word]).operands[1] else { throw NSError(domain: "missing memory", code: 2) }
            return memory
        }
        XCTAssertEqual(try list(0x4c402fff).map(\.index), [31, 0, 1, 2])
        XCTAssertEqual(try list(0x4c402fff).map(\.width), [128, 128, 128, 128])
        XCTAssertEqual(try list(0x4c402fff).first?.arrangement, .init(elementWidth: 64, laneCount: 2))
        XCTAssertEqual(try list(0x0c407c20).first?.width, 64)
        XCTAssertFalse(try memory(0x4c402fff).writeback)
        XCTAssertEqual(try memory(0x4cdf23ff).base.role, .stackPointer)
        XCTAssertEqual(try memory(0x4cdf23ff).indexing, .postIndex)
        XCTAssertTrue(try memory(0x4cdf23ff).writeback)
        XCTAssertEqual(try memory(0x4cdf23ff).displacement, 64)
        XCTAssertNil(try memory(0x4cdf23ff).index)
        XCTAssertEqual(try memory(0x4c880fff).base.role, .stackPointer)
        XCTAssertEqual(try memory(0x4c880fff).index?.index, 8)
        XCTAssertEqual(try memory(0x4c880fff).index?.width, 64)
        XCTAssertEqual(try memory(0x4c880fff).displacement, 0)
        XCTAssertEqual(try list(0x4dffb3ff).map(\.lane), [3, 3, 3, 3])
        XCTAssertEqual(try list(0x4dffb3ff).map(\.index), [31, 0, 1, 2])
        XCTAssertEqual(try list(0x4dffb3ff).first?.arrangement, .init(elementWidth: 32))
        XCTAssertEqual(try memory(0x4dffb3ff).displacement, 16)
        XCTAssertEqual(models[0x4dffb3ff]?.semantics?.memoryAccessWidth, 32)
        XCTAssertEqual(models[0x4dffb3ff]?.semantics?.memoryAccess, .read)
        XCTAssertEqual(try memory(0x0da907ff).base.role, .stackPointer)
        XCTAssertEqual(try memory(0x0da907ff).index?.index, 9)
        XCTAssertEqual(models[0x0da907ff]?.semantics?.memoryAccess, .write)
        XCTAssertEqual(try memory(0x4dffc820).displacement, 8)
        XCTAssertNil(try list(0x4dffc820).first?.lane)
        let element = try XCTUnwrap(list(0x4dffb3ff).first)
        let single = Model(coverage: .complete, opcodeClass: "element", operands: [.register(element)])
        XCTAssertEqual(ARM64OperandRenderer.render(single, legacyMnemonic: "WRONG", legacyOperands: "WRONG")?.operands, "v31.s[3]")
        let mixed = Model(coverage: .complete, opcodeClass: "ld1", operands: [.registerList([
            element, .init(bank: .simd, index: 0, width: 128, arrangement: .init(elementWidth: 32), lane: 2)
        ])])
        XCTAssertNil(ARM64OperandRenderer.render(mixed, legacyMnemonic: "WRONG", legacyOperands: "WRONG"))
        XCTAssertEqual(fixtures.count, 38)
    }
}
