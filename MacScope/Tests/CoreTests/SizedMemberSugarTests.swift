import XCTest
@testable import MacScope

/// Fixture-only coverage of semantic memory rendering; source text is deliberately absent.
final class SizedMemberSugarTests: XCTestCase {
    private func render(
        _ field: FieldDef, width: Int, extensionKind: MacIRMemoryAccess.ExtensionKind = .none,
        carrier: String = "w2", store: Bool = false, offset: Int = 8,
        typed: Bool = true, types: [TypeDefinition] = []
    ) -> String {
        let definition = TypeDefinition(kind: .struct, name: "Record", fields:
            offset == 0 ? [field] : [FieldDef(name: "prefix", type: "uint64_t"), field])
        let base = MacIRValue.argument(bindingID: .gpr(0))
        let address: MacIRValue = offset == 0 ? base
            : .binaryExpression(op: "+", left: base, right: .immediate(Int64(offset)))
        let value = MacIRValue.register(name: carrier, version: 1)
        let instruction = MacIRInstruction(
            source: .init(address: 0x1000, byteText: "", mnemonic: "redacted", operands: ""),
            operation: store ? .store(source: value, address: address) : .load(destination: value, address: address),
            memoryAccess: .init(byteWidth: width, extensionKind: extensionKind))
        var function = MacIRFunction(name: "fixture", startAddress: 0x1000, instructions: [instruction])
        function.parameters = [.init(index: 0, register: "x0", type: typed ? "struct Record *" : "uint64_t", name: "p")]
        return PseudocodePrinter().render(instruction: instruction, names: .init(function: function, types: [definition] + types))
    }

    func testWordLoadAndWidthMismatch() {
        let field = FieldDef(name: "count", type: "int")
        XCTAssertEqual(render(field, width: 4), "w2_1 = p->count")
        XCTAssertEqual(render(field, width: 2, extensionKind: .zero), "w2_1 = *(uint16_t *)(p + 0x8)")
    }

    func testTypedefWordLoadAndSignMismatch() {
        let alias = TypeDefinition(kind: .typedef, name: "JDIMENSION", fields: [.init(name: "", type: "unsigned int")])
        let field = FieldDef(name: "width", type: "JDIMENSION")
        XCTAssertEqual(render(field, width: 4, types: [alias]), "w2_1 = p->width")
        XCTAssertEqual(render(field, width: 4, extensionKind: .sign, carrier: "x2", types: [alias]),
                       "x2_1 = *(int32_t *)(p + 0x8)")
    }

    func testSignedWordLoadAndUnsignedRefusal() {
        XCTAssertEqual(render(.init(name: "count", type: "int"), width: 4, extensionKind: .sign, carrier: "x2"), "x2_1 = p->count")
        XCTAssertEqual(render(.init(name: "count", type: "unsigned int"), width: 4, extensionKind: .sign, carrier: "x2"),
                       "x2_1 = *(int32_t *)(p + 0x8)")
    }

    func testHalfwordLoadsRequireMatchingSignedness() {
        XCTAssertEqual(render(.init(name: "count", type: "unsigned short"), width: 2, extensionKind: .zero), "w2_1 = p->count")
        XCTAssertEqual(render(.init(name: "count", type: "short"), width: 2, extensionKind: .sign), "w2_1 = p->count")
        XCTAssertEqual(render(.init(name: "count", type: "unsigned short"), width: 2, extensionKind: .sign), "w2_1 = *(int16_t *)(p + 0x8)")
        XCTAssertEqual(render(.init(name: "count", type: "short"), width: 2, extensionKind: .zero), "w2_1 = *(uint16_t *)(p + 0x8)")
    }

    func testByteLoadsRequireMatchingSignedness() {
        for type in ["unsigned char", "_Bool"] {
            XCTAssertEqual(render(.init(name: "flag", type: type), width: 1, extensionKind: .zero), "w2_1 = p->flag")
        }
        XCTAssertEqual(render(.init(name: "flag", type: "signed char"), width: 1, extensionKind: .sign), "w2_1 = p->flag")
        XCTAssertEqual(render(.init(name: "flag", type: "signed char"), width: 1, extensionKind: .zero), "w2_1 = *(uint8_t *)(p + 0x8)")
    }

    func testIntegerStoresAndWidthRefusals() {
        for (type, width) in [("signed char", 1), ("short", 2), ("int", 4)] {
            XCTAssertEqual(render(.init(name: "value", type: type), width: width, store: true), "p->value = w2_1")
            let wrongWidth = width == 1 ? 2 : 1
            XCTAssertEqual(render(.init(name: "value", type: type), width: wrongWidth, store: true),
                           "*(uint\(wrongWidth * 8)_t *)(p + 0x8) = w2_1")
        }
    }

    func testFloatingLoadsStoresAndClassRefusals() {
        for (type, width, carrier) in [("float", 4, "s2"), ("double", 8, "d2")] {
            let field = FieldDef(name: "value", type: type)
            XCTAssertEqual(render(field, width: width, carrier: carrier), "\(carrier)_1 = p->value")
            XCTAssertEqual(render(field, width: width, carrier: carrier, store: true), "p->value = \(carrier)_1")
            XCTAssertEqual(render(.init(name: "value", type: width == 4 ? "int" : "int64_t"), width: width, carrier: carrier),
                           "\(carrier)_1 = *(\(type) *)(p + 0x8)")
        }
        XCTAssertEqual(render(.init(name: "value", type: "float"), width: 4), "w2_1 = *(uint32_t *)(p + 0x8)")
        XCTAssertEqual(render(.init(name: "value", type: "float"), width: 4, store: true), "*(uint32_t *)(p + 0x8) = w2_1")
    }

    func testBareBaseAndUntypedRefusal() {
        let field = FieldDef(name: "first", type: "int")
        XCTAssertEqual(render(field, width: 4, offset: 0), "w2_1 = p->first")
        XCTAssertEqual(render(field, width: 4, offset: 0, typed: false), "w2_1 = *(uint32_t *)(p)")
    }

    func testAggregatesArraysBitfieldsAndInteriorOffsetsRefuse() {
        XCTAssertEqual(render(.init(name: "value", type: "int"), width: 4), "w2_1 = p->value")
        let inner = TypeDefinition(kind: .struct, name: "Inner", fields: [.init(name: "value", type: "int")])
        for field in [FieldDef(name: "nested", type: "Inner"), .init(name: "array", type: "int[1]"),
                      .init(name: "bits", type: "unsigned int", bitWidth: 4)] {
            XCTAssertEqual(render(field, width: 4, types: [inner]), "w2_1 = *(uint32_t *)(p + 0x8)")
        }
        XCTAssertEqual(render(.init(name: "value", type: "int"), width: 1, extensionKind: .zero, offset: 9),
                       "w2_1 = *(uint8_t *)(p + 0x9)")
    }

    func testPropagatedPointerSupportsSizedField() {
        let type = TypeDefinition(kind: .struct, name: "Node", fields: [
            .init(name: "next", type: "struct Node *"), .init(name: "count", type: "int")])
        let pointer = MacIRValue.register(name: "x8", version: 1)
        let source = MacIRSourceSpan(address: 0x1000, byteText: "", mnemonic: "redacted", operands: "")
        let first = MacIRInstruction(source: source, operation: .load(destination: pointer, address: .argument(bindingID: .gpr(0))),
                                     memoryAccess: .init(byteWidth: 8))
        let second = MacIRInstruction(source: source, operation: .load(destination: .register(name: "w2", version: 1),
            address: .binaryExpression(op: "+", left: pointer, right: .immediate(8))), memoryAccess: .init(byteWidth: 4))
        var function = MacIRFunction(name: "walk", startAddress: 0x1000, instructions: [first, second])
        function.parameters = [.init(index: 0, register: "x0", type: "struct Node *", name: "p")]
        XCTAssertEqual(PseudocodePrinter().render(instruction: second, names: .init(function: function, types: [type])),
                       "w2_1 = x8_1->count")
    }

    func testAliasesEnumsAndUnsupportedScalarShapes() {
        let dimension = TypeDefinition(kind: .typedef, name: "Dimension", fields: [.init(name: "", type: "unsigned short")])
        let alias = TypeDefinition(kind: .typedef, name: "Alias", fields: [.init(name: "", type: "Dimension")])
        XCTAssertEqual(render(.init(name: "value", type: "Alias"), width: 2, extensionKind: .zero, types: [dimension, alias]),
                       "w2_1 = p->value")
        XCTAssertEqual(render(.init(name: "value", type: "Alias"), width: 2, extensionKind: .sign, types: [dimension, alias]),
                       "w2_1 = *(int16_t *)(p + 0x8)")
        let signed = TypeDefinition(kind: .enum, name: "SignedChoice", fields: [.init(name: "negative", type: "-1")])
        let unsigned = TypeDefinition(kind: .enum, name: "Choice", fields: [.init(name: "positive", type: "1")])
        XCTAssertEqual(render(.init(name: "value", type: "SignedChoice"), width: 4, extensionKind: .sign, carrier: "x2", types: [signed]),
                       "x2_1 = p->value")
        XCTAssertEqual(render(.init(name: "value", type: "Choice"), width: 4, types: [unsigned]), "w2_1 = p->value")
        XCTAssertEqual(render(.init(name: "value", type: "Choice"), width: 4, extensionKind: .sign, carrier: "x2", types: [unsigned]),
                       "x2_1 = *(int32_t *)(p + 0x8)")
        let arrayAlias = TypeDefinition(kind: .typedef, name: "ArrayAlias", fields: [.init(name: "", type: "int[1]")])
        XCTAssertEqual(render(.init(name: "value", type: "ArrayAlias"), width: 4, types: [arrayAlias]), "w2_1 = *(uint32_t *)(p + 0x8)")
        XCTAssertEqual(render(.init(name: "value", type: "int"), width: 4, carrier: "x2"), "x2_1 = *(uint32_t *)(p + 0x8)")
        XCTAssertEqual(render(.init(name: "value", type: "float"), width: 4, carrier: "d2"), "d2_1 = *(float *)(p + 0x8)")
    }

    func testExplicitZeroOffsetAndPairWritebackBoundaries() {
        let type = TypeDefinition(kind: .struct, name: "Record", fields: [
            .init(name: "first", type: "int"), .init(name: "second", type: "int")])
        let base = MacIRValue.argument(bindingID: .gpr(0))
        let first = MacIRValue.register(name: "w2", version: 1)
        let second = MacIRValue.register(name: "w3", version: 1)
        let updated = MacIRValue.register(name: "x0", version: 1)
        let source = MacIRSourceSpan(address: 0x1000, byteText: "", mnemonic: "redacted", operands: "")
        let cases: [(MacIROperation, String)] = [
            (.load(destination: first, address: .binaryExpression(op: "+", left: base, right: .immediate(0))), "w2_1 = p->first"),
            (.intrinsic(destination: nil, name: "restore_pair", arguments: [first, second, base]),
             "w2_1, w3_1 = *(uint32_t *)(p), *(uint32_t *)(p + 0x4)"),
            (.intrinsic(destination: nil, name: "save_pair", arguments: [first, second, base]),
             "*(uint32_t *)(p), *(uint32_t *)(p + 0x4) = w2_1, w3_1"),
            (.loadWriteback(destination: first, baseDestination: updated, baseSource: base, delta: 4, preIndex: false),
             "w2_1, x0_1 = *(uint32_t *)(p), p + 0x4"),
            (.storeWriteback(source: first, baseDestination: updated, baseSource: base, delta: 4, preIndex: false),
             "*(uint32_t *)(p), x0_1 = w2_1, p + 0x4"),
        ]
        for (operation, expected) in cases {
            let instruction = MacIRInstruction(source: source, operation: operation, memoryAccess: .init(byteWidth: 4))
            var function = MacIRFunction(name: "boundary", startAddress: 0x1000, instructions: [instruction])
            function.parameters = [.init(index: 0, register: "x0", type: "struct Record *", name: "p")]
            XCTAssertEqual(PseudocodePrinter().render(instruction: instruction, names: .init(function: function, types: [type])), expected)
        }
    }
}
