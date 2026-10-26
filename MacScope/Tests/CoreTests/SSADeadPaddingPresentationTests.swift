import XCTest
@testable import MacScope

final class SSADeadPaddingPresentationTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String,
                     _ operation: MacIROperation) -> MacIRInstruction {
        .init(source: .init(address: address, byteText: "00 00 00 00",
                            mnemonic: mnemonic, operands: operands), operation: operation)
    }

    // The branch skips an unreachable ordinary block with one internal successor.
    // An optional second unreachable block ends in one external fallthrough edge.
    private func fixture(ssa: Bool, tail: Bool) throws -> MacIRFunction {
        let joined = MacIRValue.register(name: "x8", version: 3)
        var rows = [
            row(0x1000, "b", "0x1008", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x1008)])),
            row(0x1004, "nop", "", .intrinsic(destination: nil, name: "padding", arguments: [])),
            row(0x1008, "ret", "", .returnValue(joined))
        ]
        if tail { rows.append(row(0x100c, "nop", "", .intrinsic(destination: nil, name: "padding", arguments: []))) }
        let phi = MacIRPhi(blockAddress: 0x1008, destination: joined, bitWidth: 64,
            incoming: [.init(predecessorAddress: 0x1000, value: .immediate(1)),
                       .init(predecessorAddress: 0x1004, value: .immediate(2))])
        var function = MacIRFunction(name: "padding_phi", startAddress: 0x1000,
                                     instructions: rows, phis: [phi])
        function.ssaEnabled = ssa
        function.cfg = try XCTUnwrap(MacIRCFG.build(instructions: rows, jumpTables: [:],
            knownTailCallTargets: [:], authoredCallSignaturesByTarget: [:]))
        let graph = try XCTUnwrap(function.cfg)
        XCTAssertEqual(graph.compatibilityCFG.blocks[1].successors, [2])
        if tail {
            XCTAssertTrue(graph.unreachable.contains(3))
            XCTAssertEqual(graph.compatibilityCFG.blocks[3].successors, [])
            XCTAssertEqual(graph.blocks[3].successors, [.init(from: 3, to: nil, kind: .fallthrough, label: nil)])
            XCTAssertEqual(graph.terminators[3], .none)
        }
        return function
    }

    private func render(_ function: MacIRFunction) -> PseudocodeDocument {
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        return PseudocodePrinter(options: options).print(function: function)
    }

    // Source-derived preimage goldens: the old completeEdges predicate accepts
    // the internal successor and refuses the external-only tail. No baseline
    // build or previously passed selector is replayed to obtain these goldens.
    private let preimageHeader = [
        "int64_t padding_phi(void) {",
        "    // entry 0x0000000000001000; no stack frame; calls none"
    ]

    private func assertOffIdentity(_ function: MacIRFunction, body: [String],
                                   kinds: [PseudocodeLineKind], sources: [MacIRSourceSpan?],
                                   fallback: PseudocodeStructureFallback?,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let document = render(function)
        let expected = preimageHeader + body + ["}"]
        XCTAssertEqual(Array(document.text.utf8), Array(expected.joined(separator: "\n").utf8), file: file, line: line)
        XCTAssertEqual(document.lines.map(\.lineNumber), Array(1...expected.count), file: file, line: line)
        XCTAssertEqual(document.lines.map(\.kind), [.signature, .metadata] + kinds + [.closingBrace], file: file, line: line)
        XCTAssertEqual(document.lines.map(\.source), [nil, nil] + sources + [nil], file: file, line: line)
        XCTAssertTrue(document.lines.allSatisfy { $0.refusal == nil }, file: file, line: line)
        XCTAssertEqual(document.structureFallback, fallback, file: file, line: line)
        // Also compare all line fields, including token identities, to the legacy
        // compatibility-graph route whose old Boolean admission is unchanged.
        var legacy = function
        legacy.cfg = nil
        XCTAssertEqual(document.lines, render(legacy).lines, file: file, line: line)
    }

    func testOffIdentityPositive() throws {
        let function = try fixture(ssa: false, tail: false)
        let rows = function.instructions
        assertOffIdentity(function, body: [
            "    int64_t x8_3;",
            "        const int64_t __edge_0_2_0 = 0x1;",
            "        x8_3 = __edge_0_2_0;",
            "    goto L_1008;",
            "    __padding();",
            "        const int64_t __edge_1_2_0 = 0x2;",
            "        x8_3 = __edge_1_2_0;",
            "    L_1008:",
            "    return x8_3;"
        ], kinds: [.declaration] + Array(repeating: .instruction, count: 8),
           sources: [nil, rows[0].source, rows[0].source, rows[0].source,
                     rows[1].source, rows[1].source, rows[1].source, rows[2].source, rows[2].source],
           fallback: nil)
    }

    func testOffIdentityNegative() throws {
        let function = try fixture(ssa: false, tail: true)
        assertOffIdentity(function, body: ["    __unavailable_cfg_phi();"],
                          kinds: [.instruction], sources: [nil], fallback: .unstructurableCFG)
    }

    func testOnAdmitsPersistedUnreachablePadding() throws {
        let function = try fixture(ssa: true, tail: true)
        let original = function
        let document = render(function)
        XCTAssertFalse(document.text.contains("__unavailable_cfg_phi"), document.text)
        XCTAssertTrue(document.text.contains("return x8_3;"), document.text)
        XCTAssertTrue(document.lines.contains { $0.sourceAddress == 0x100c && $0.text.contains("__padding()") })
        XCTAssertNil(document.structureFallback)
        XCTAssertEqual(function, original, "Presentation must not mutate architectural evidence")
    }

    private func assertRefusal(_ mutate: (inout MacIRCFG) -> Void,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        var function = try fixture(ssa: true, tail: true)
        var graph = try XCTUnwrap(function.cfg)
        mutate(&graph)
        // Retain the compatibility projection: each test contradicts exactly one
        // persisted source obligation while keeping the candidate tail external.
        function.cfg = graph
        let document = render(function)
        XCTAssertTrue(document.text.contains("__unavailable_cfg_phi();"), document.text, file: file, line: line)
        XCTAssertFalse(document.text.contains("__edge_"), document.text, file: file, line: line)
        XCTAssertFalse(document.text.contains("__padding();"), document.text, file: file, line: line)
        XCTAssertEqual(document.structureFallback, .unstructurableCFG, file: file, line: line)
    }

    func testOnRefusesReachableBlock() throws {
        try assertRefusal { $0.unreachable.removeAll { $0 == 3 } }
    }

    func testOnRefusesTwoEdges() throws {
        try assertRefusal { $0.blocks[3].successors.append(.init(from: 3, to: nil, kind: .fallthrough, label: nil)) }
    }

    func testOnRefusesNonNilDestination() throws {
        try assertRefusal { $0.blocks[3].successors[0].to = 2 }
    }
}
