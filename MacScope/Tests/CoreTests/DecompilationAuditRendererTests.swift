import Foundation
import XCTest
@testable import MacScope

/// Focused native regressions for audit printer rendering and module identity.
final class DecompilationAuditRendererTests: XCTestCase {
    func testExpressionTreeGrouping() {
        let a = MacIRValue.symbol("a"), b = MacIRValue.symbol("b"), c = MacIRValue.symbol("c")
        let function = MacIRFunction(name: "grouping", startAddress: 0x1000, instructions: [])
        let names = PseudocodeNameContext(function: function)
        let printer = PseudocodePrinter()
        let vectors: [(MacIRValue, String)] = [
            (.binaryExpression(op: "*", left: .binaryExpression(op: "+", left: a, right: b), right: c), "(a + b) * c"),
            (.binaryExpression(op: "-", left: a, right: .binaryExpression(op: "-", left: b, right: c)), "a - (b - c)"),
            (.unary(op: "-", value: .binaryExpression(op: "+", left: a, right: b)), "-(a + b)"),
            (.unary(op: "(uint64_t)", value: .binaryExpression(op: "+", left: a, right: b)), "(uint64_t)(a + b)"),
            (.unary(op: "-", value: .unary(op: "-", value: a)), "-(-(a))"),
            (.bitTest(value: .binaryExpression(op: "|", left: a, right: b), bit: 1), "(((a | b) >> 0x1) & 0x1)"),
            (.binaryExpression(op: "/", left: a, right: .binaryExpression(op: "*", left: b, right: c)), "a / (b * c)"),
            (.binaryExpression(op: "&", left: .binaryExpression(op: ">>", left: a, right: .immediate(1)), right: b), "(a >> 0x1) & b"),
            (.binaryExpression(op: "+", left: a, right: b), "a + b"),
        ]
        for (value, expected) in vectors {
            XCTAssertEqual(printer.valueText(for: value, names: names), expected)
        }
        // Exercise the operation consumer, not only the value helper.
        XCTAssertEqual(printer.render(operation: .binary(destination: .register(name: "x9", version: 1),
            op: "*", left: .binaryExpression(op: "+", left: a, right: b), right: c), names: names),
            "x9_1 = (a + b) * c")
    }

    func testLinearDCEKeepsLaterReachableReturn() {
        func instruction(_ address: UInt64, _ mnemonic: String, _ operation: MacIROperation) -> MacIRInstruction {
            .init(source: .init(address: address, byteText: "", mnemonic: mnemonic, operands: ""), operation: operation)
        }
        // The nops keep this input outside the short early-return/fallthrough folders.
        // The target return is reachable directly from the first instruction.
        let rows: [MacIRInstruction] = [
            instruction(0x1000, "cbz", .conditionalBranch(condition: "==", left: .argument(bindingID: .gpr(0)), right: .immediate(0), target: .immediate(0x1010))),
            instruction(0x1004, "ret", .returnValue(.immediate(111))),
            instruction(0x1008, "nop", .intrinsic(destination: nil, name: "nop", arguments: [])),
            instruction(0x100c, "nop", .intrinsic(destination: nil, name: "nop", arguments: [])),
            instruction(0x1010, "ret", .returnValue(.immediate(222))),
        ]
        let options = DecompilerOptions(structureControlFlow: false, deadCodeElimination: true,
                                        nopElision: false, functionSizeGate: 1024)
        let function = MacIRFunction(name: "reachable_return", startAddress: 0x1000, instructions: rows)
        let text = PseudocodePrinter(options: options).print(function: function).text
        XCTAssertTrue(text.contains("return 0x6f"), text)
        XCTAssertTrue(text.contains("return 0xde"), text)

        // A passing gate alone does not prove the emitter actually deletes a linear tail.
        let linear = MacIRFunction(name: "linear_tail", startAddress: 0x1000, instructions: [
            instruction(0x1000, "ret", .returnValue(.immediate(111))),
            instruction(0x1004, "ret", .returnValue(.immediate(222))),
        ])
        let elided = PseudocodePrinter(options: options).print(function: linear).text
        XCTAssertTrue(elided.contains("return 0x6f"), elided)
        XCTAssertFalse(elided.contains("return 0xde"), elided)
        var keepOptions = options
        keepOptions.deadCodeElimination = false
        let retained = PseudocodePrinter(options: keepOptions).print(function: linear).text
        XCTAssertTrue(retained.contains("return 0x6f"), retained)
        XCTAssertTrue(retained.contains("return 0xde"), retained)
    }

    func testPointerPropagationRequiresWholeGPRPointerLoad() {
        let node = TypeDefinition(id: UUID(), kind: .struct, name: "Node",
                                  fields: [FieldDef(name: "next", type: "struct Node *")])
        let parameter = MacIRFunctionParameter(index: 0, register: "x0", type: "struct Node *", name: "node")
        let gpr = MacIRValue.register(name: "x9", version: 1)
        // Vary each admission condition independently. Some cases deliberately model
        // inconsistent metadata to ensure the consumer fails closed, not real encodings.
        var cases: [(String, MacIRValue, MacIRMemoryAccess?, String?)] = []
        for width in [1, 2, 4, 16] {
            cases.append(("width \(width)", gpr, .init(byteWidth: width), nil))
        }
        cases += [
            ("whole pointer", gpr, .init(byteWidth: 8), "struct Node *"),
            ("missing facts", gpr, nil, nil),
            ("sign extension", gpr, .init(byteWidth: 8, extensionKind: .sign), nil),
            ("zero extension", gpr, .init(byteWidth: 8, extensionKind: .zero), nil),
            ("32-bit GPR", .register(name: "w9", version: 1), .init(byteWidth: 8), nil),
            ("FP carrier", .register(name: "d9", version: 1), .init(byteWidth: 8), nil),
            ("vector carrier", .register(name: "v9", version: 1), .init(byteWidth: 8), nil),
            ("temporary carrier", .temporary(9), .init(byteWidth: 8), nil),
        ]
        for (label, destination, access, expected) in cases {
            let row = MacIRInstruction(
                source: .init(address: 0x1000, byteText: "", mnemonic: "ldr", operands: ""),
                operation: .load(destination: destination, address: .argument(bindingID: .gpr(0))), memoryAccess: access)
            let function = MacIRFunction(name: "load", startAddress: 0x1000, parameters: [parameter], instructions: [row])
            let names = PseudocodeNameContext(function: function, types: [node])
            XCTAssertEqual(names.valueTypes[destination], expected, label)
        }
    }
}
