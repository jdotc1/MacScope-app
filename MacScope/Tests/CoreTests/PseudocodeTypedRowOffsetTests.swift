import XCTest
@testable import MacScope

final class PseudocodeTypedRowOffsetTests: XCTestCase {
    func testEightBitRowsUsePointerElements() throws {
        try checkRows(type: "JSAMPROW *", rowType: "uint8_t *", alias: "JSAMPROW")
    }

    func testTwelveBitRowsUsePointerElements() throws {
        try checkRows(type: "J12SAMPROW *", rowType: "uint16_t *", alias: "J12SAMPROW")
    }

    func testSixteenBitRowsUsePointerElements() throws {
        try checkRows(type: "uint16_t **", rowType: nil, alias: nil)
    }

    func testNonMultipleOffsetUsesBytePointerBase() throws {
        let text = try render(type: "uint16_t **", offset: .immediate(3))
        XCTAssertTrue(text.contains("(uint8_t *)(rows) + 0x3"), text)
        XCTAssertFalse(text.contains("rows + 0x3"), text)
        // The byte-address adjustment must restore T** before dereferencing,
        // preserving a pointer-sized row load rather than a uint8_t load.
        XCTAssertTrue(text.contains("    x3_1 = *((uint16_t **)((uint8_t *)(rows) + 0x3));"), text)
        XCTAssertTrue(text.contains("    x7_1 = *((uint16_t **)((uint8_t *)(rows) + 0x3));"), text)
        let minus = try renderAddress(op: "-", base: .argument(bindingID: .gpr(0)), bytes: 3)
        XCTAssertTrue(minus.contains("    x3_1 = *((uint16_t **)((uint8_t *)(rows) - 0x3));"), minus)
        XCTAssertTrue(minus.contains("    *((uint16_t **)((uint8_t *)(rows) - 0x3)) = x9_0;"), minus)
        let multiple = try renderAddress(op: "-", base: .argument(bindingID: .gpr(0)), bytes: 8)
        XCTAssertTrue(multiple.contains("    x3_1 = *(rows - 0x1);"), multiple)
        let effect = try renderAddress(op: "+", base: .unary(op: "(uint16_t **)",
            value: .unknown("next_rows()")), bytes: 3)
        let loadLine = try XCTUnwrap(effect.split(separator: "\n").first { $0.contains("x3_1 =") })
        XCTAssertTrue(loadLine.contains("*((uint16_t **)((uint8_t *)((uint16_t **)(next_rows())) + 0x3))"), effect)
        XCTAssertEqual(loadLine.components(separatedBy: "next_rows()").count - 1, 1, effect)
        // Record pointees, including aliases, require byte-address semantics.
        let record = TypeDefinition(kind: .struct, name: "Record",
            fields: [FieldDef(name: "value", type: "uint64_t")])
        let recordAlias = TypeDefinition(kind: .typedef, name: "RecordAlias",
            fields: [FieldDef(name: "", type: "struct Record")])
        for type in ["struct Record *", "RecordAlias *"] {
            let excluded = try render(type: type, offset: .immediate(8), types: [record, recordAlias])
            XCTAssertTrue(excluded.contains("x2_1 = (\(type))((uint8_t *)(rows) + 0x8);"), excluded)
            XCTAssertTrue(excluded.contains("(uint8_t *)(rows)"), excluded)
        }
        // Foo** has pointer elements even when the record layout is unknown.
        let pointerElement = try render(type: "struct Opaque **", offset: .immediate(8))
        XCTAssertTrue(pointerElement.contains("x2_1 = rows + 0x1;"), pointerElement)
        let scalarElement = try render(type: "uint16_t *", offset: .immediate(8))
        XCTAssertTrue(scalarElement.contains("x2_1 = rows + 0x4;"), scalarElement)
        // Duplicate IDs must not turn an ABI-only comment into a pointer declaration.
        let metadataOnly = try duplicateParameterIDText()
        XCTAssertTrue(metadataOnly.contains("/* ABI inputs:"), metadataOnly)
        XCTAssertTrue(metadataOnly.contains("x2_1 = rows + 0x8;"), metadataOnly)
        XCTAssertFalse(metadataOnly.contains("rows + 0x1"), metadataOnly)
        let cycle = [TypeDefinition(kind: .typedef, name: "CycleA",
                                    fields: [FieldDef(name: "", type: "CycleB")]),
                     TypeDefinition(kind: .typedef, name: "CycleB",
                                    fields: [FieldDef(name: "", type: "CycleA")])]
        let unknown = try render(type: "CycleA", offset: .immediate(8), types: cycle)
        XCTAssertTrue(unknown.contains("x2_1 = rows + 0x8;"), unknown)
    }

    private func renderAddress(op: String, base: MacIRValue, bytes: Int64) throws -> String {
        let parameter = try XCTUnwrap(MacIRFunctionParameter(
            id: .init(rawValue: "auth:rows"), bindingID: .gpr(0), sourcePosition: 0,
            abiLocation: .gpr(index: 0, carrierWidth: 64), type: "uint16_t **", name: "rows",
            evidence: .authoritativeUser))
        let address = MacIRValue.binaryExpression(op: op, left: base, right: .immediate(bytes))
        let operations: [MacIROperation] = [
            .load(destination: .register(name: "x3", version: 1), address: address),
            .store(source: .register(name: "x9", version: 0), address: address),
        ]
        let function = MacIRFunction(name: "typed_address", startAddress: 0x3000,
            parameters: [parameter], instructions: operations.enumerated().map { index, operation in
                MacIRInstruction(source: .init(address: 0x3000 + UInt64(index * 4),
                    byteText: "", mnemonic: "fixture", operands: ""), operation: operation)
            })
        return PseudocodePrinter().print(function: function).text
    }

    private func checkRows(type: String, rowType: String?, alias: String?) throws {
        let catalog: [TypeDefinition]
        if let rowType, let alias {
            catalog = [TypeDefinition(kind: .typedef, name: alias,
                                      fields: [FieldDef(name: "", type: rowType)])]
        } else {
            catalog = []
        }
        let text = try render(type: type, offset: .immediate(8), types: catalog)
        XCTAssertTrue(text.contains("x2_1 = rows + 0x1;"), text)
        XCTAssertTrue(text.contains("x3_1 = *(rows + 0x1);"), text)
        XCTAssertTrue(text.contains("x4_1, x5_1 = *(rows), rows + 0x1;"), text)
        XCTAssertTrue(text.contains("x6_1 = rows + 0x1;"), text)
        XCTAssertTrue(text.contains("x7_1 = *(rows + 0x1);"), text)
        XCTAssertFalse(text.contains("rows + 0x8"), text)
        let arrayAlias = TypeDefinition(kind: .typedef, name: "RowArray",
                                       fields: [FieldDef(name: "", type: type)])
        let aliasText = try render(type: "RowArray", offset: .immediate(8), types: catalog + [arrayAlias])
        XCTAssertTrue(aliasText.contains("x2_1 = rows + 0x1;"), aliasText)
        XCTAssertTrue(aliasText.contains("x6_1 = rows + 0x1;"), aliasText)
        XCTAssertFalse(aliasText.contains("rows + 0x8"), aliasText)

    }

    private func duplicateParameterIDText() throws -> String {
        let parameters = try (0...1).map { index in
            try XCTUnwrap(MacIRFunctionParameter(id: .init(rawValue: "same"),
                bindingID: .gpr(index), sourcePosition: 0,
                abiLocation: .gpr(index: index, carrierWidth: 64),
                type: "uint16_t **", name: index == 0 ? "rows" : "other",
                evidence: .authoritativeUser))
        }
        let function = MacIRFunction(name: "metadata_only", startAddress: 0x2000,
            parameters: parameters, instructions: [MacIRInstruction(
                source: .init(address: 0x2000, byteText: "", mnemonic: "fixture", operands: ""),
                operation: .binary(destination: .register(name: "x2", version: 1), op: "+",
                    left: .argument(bindingID: .gpr(0)), right: .immediate(8)))])
        return PseudocodePrinter().print(function: function).text
    }

    private func render(type: String, offset: MacIRValue,
                        types: [TypeDefinition] = []) throws -> String {
        let parameter = try XCTUnwrap(MacIRFunctionParameter(
            id: .init(rawValue: "auth:rows"), bindingID: .gpr(0), sourcePosition: 0,
            abiLocation: .gpr(index: 0, carrierWidth: 64), type: type, name: "rows",
            evidence: .authoritativeUser))
        let rows = MacIRValue.argument(bindingID: .gpr(0))
        let address = MacIRValue.binaryExpression(op: "+", left: rows, right: offset)
        var operations: [MacIROperation] = [
            .binary(destination: .register(name: "x2", version: 1), op: "+", left: rows, right: offset),
            .load(destination: .register(name: "x3", version: 1), address: address),
            .binary(destination: .register(name: "x6", version: 1), op: "+", left: offset, right: rows),
            .load(destination: .register(name: "x7", version: 1),
                  address: .binaryExpression(op: "+", left: offset, right: rows)),
        ]
        if case let .immediate(delta) = offset {
            operations.append(.loadWriteback(destination: .register(name: "x4", version: 1),
                baseDestination: .register(name: "x5", version: 1), baseSource: rows,
                delta: delta, preIndex: false))
        }
        let function = MacIRFunction(name: "typed_rows", startAddress: 0x1000,
            parameters: [parameter], instructions: operations.enumerated().map { index, operation in
                MacIRInstruction(source: .init(address: 0x1000 + UInt64(index * 4),
                    byteText: "", mnemonic: "fixture", operands: ""), operation: operation)
            })
        return PseudocodePrinter().print(function: function, types: types).text
    }
}
