import Foundation
import XCTest

/// New parser/arithmetic unit controls only. These authored snippets are not
/// captured corpus fixtures, production-behavior RED, or native scalar acceptance.
/// SOURCE_ONLY / NOT_RUN. Original-site controls await fresh capture/baseline binding.
final class NativeScalarOraclePrerequisiteTests: XCTestCase {
    private typealias C = OrdinaryC
    private typealias N = NativeScalarNoCallContract
    private struct Unit {
        let program: C.Program
        let scenario: C.Scenario
        func run() throws -> C.Result { try C.Machine(program: program, scenario: scenario).run() }
    }
    private func manifest(_ bodyCount: Int, terminal: N.Terminal = .value(name: "result", type: .i64),
                          payload: String = "return result; // parser-unit terminal") -> N.FrozenManifest {
        .init(signature: "int64_t native_oracle_unit(int64_t input) {",
            formals: [.init(name: "input", type: .i64)],
            sourceAddresses: (0...bodyCount).map { 0x1000 + UInt64($0 * 4) },
            terminalRow: bodyCount, terminalPayload: payload, terminal: terminal,
            labelAddresses: [], memoryEffects: [:])
    }
    private func lines(_ body: [String], manifest: N.FrozenManifest) -> [C.TextLine] {
        [.init(text: manifest.signature, source: nil, envelope: .signature)] +
        body.enumerated().map { .init(text: $0.element, source: manifest.sourceAddresses[$0.offset], envelope: .body) } +
        [.init(text: manifest.terminalPayload, source: manifest.sourceAddresses[manifest.terminalRow], envelope: .body),
         .init(text: "}", source: nil, envelope: .closingBrace)]
    }
    private func unit(_ body: [String], input: UInt64 = 0) throws -> Unit {
        let frozen = manifest(body.count)
        return try .init(program: N.program(lines: lines(body, manifest: frozen), manifest: frozen),
            scenario: N.scenario(name: "parser-prerequisite-only", inputs: ["input": .init(input, .i64)],
                                 memory: [:], manifest: frozen))
    }
    private func requireUndefined(_ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do { try action(); XCTFail("expected strict C refusal", file: file, line: line) }
        catch C.Failure.undefinedC { }
        catch { XCTFail("wrong failure: \(error)", file: file, line: line) }
    }

    func testRightShiftUsesPromotedLeftWidthNotRightOperandWidth() throws {
        let narrow = try unit(["uint32_t left = 0x80000000; uint64_t count = 1; shifted = left >> count; result = shifted;"])
        XCTAssertEqual(narrow.program.symbols["shifted"]?.type, C.CType.u32)
        let narrowResult = try narrow.run()
        XCTAssertEqual(narrowResult.terminal?.bits, 0x40000000)
        XCTAssertEqual(narrowResult.commits.first(where: { $0.name == "shifted" })?.value.type, C.CType.u32)
        let wide = try unit(["uint64_t left = 0x8000000000000000; uint32_t count = 1; shifted = left >> count; result = (int64_t)shifted;"])
        XCTAssertEqual(wide.program.symbols["shifted"]?.type, C.CType.u64)
        XCTAssertEqual(try wide.run().terminal?.bits, 0x4000000000000000)
        let promoted = try unit(["uint8_t left = 255; uint64_t count = 1; shifted = left >> count; result = shifted;"])
        XCTAssertEqual(promoted.program.symbols["shifted"]?.type, C.CType.i32)
        XCTAssertEqual(try promoted.run().terminal?.bits, 127)
    }

    func testRightShiftBoundaryCountsPrecedenceAndAssociativity() throws {
        let u32 = try unit(["uint32_t value = 0xffffffff; atZero = value >> (uint64_t)0; atLast = value >> (uint64_t)31; result = atZero + (uint64_t)atLast;"])
        XCTAssertEqual(try u32.run().terminal?.bits, 0x1_0000_0000)
        let u64 = try unit(["uint64_t value = 0x8000000000000000; atZero = value >> (uint32_t)0; atLast = value >> (uint32_t)63; result = (int64_t)atLast;"])
        let result = try u64.run()
        XCTAssertEqual(result.commits.first(where: { $0.name == "atZero" })?.value.bits, 0x8000000000000000)
        XCTAssertEqual(result.terminal?.bits, 1)
        XCTAssertEqual(try unit(["result = (uint32_t)64 >> 1 + 2;"]).run().terminal?.bits, 8)
        XCTAssertEqual(try unit(["result = (uint32_t)64 >> 2 >> 1;"]).run().terminal?.bits, 8)
        XCTAssertEqual(try unit(["result = (uint32_t)64 >> 2 << 1;"]).run().terminal?.bits, 32)
        XCTAssertEqual(try unit(["result = (uint32_t)8 >> 1 < 5;"]).run().terminal?.bits, 1)
    }

    func testRightShiftRejectsNegativeSignedAndUnmaskedCounts() throws {
        requireUndefined { _ = try self.unit(["result = (uint32_t)1 >> -1;"]).run() }
        requireUndefined { _ = try self.unit(["result = (uint32_t)1 >> (uint64_t)32;"]).run() }
        requireUndefined { _ = try self.unit(["result = (uint32_t)1 >> (uint64_t)33;"]).run() }
        requireUndefined { _ = try self.unit(["result = (uint64_t)1 >> (uint32_t)64;"]).run() }
        requireUndefined { _ = try self.unit(["result = (uint32_t)1 >> (uint64_t)0xffffffffffffffff;"]).run() }
        requireUndefined { _ = try self.unit(["result = (int32_t)-1 >> 1;"]).run() }
        requireUndefined { _ = try self.unit(["result = (int64_t)-1 >> 0;"]).run() }
        XCTAssertEqual(try unit(["result = (int32_t)0x7fffffff >> (uint64_t)31;"]).run().terminal?.bits, 0)
        XCTAssertEqual(try unit(["result = (uint32_t)0x80000000 >> ((uint64_t)33 & (uint64_t)31);"]).run().terminal?.bits,
                       0x40000000, "only the parsed expression supplies the architectural mask")
    }

    func testNoCallAdapterDoesNotAdmitTupleOrHiddenHelper() {
        XCTAssertThrowsError(try unit(["left, right = 1, 2; result = left;"]))
        XCTAssertThrowsError(try unit(["result = __adrp(0x1000);"]))
        XCTAssertThrowsError(try unit(["result = 1; if (false) { ignored = hidden_helper(input); }"]))
    }

    func testNoCallAdapterBindsFormalsWithoutSeedingArchitecturalNames() throws {
        let frozen = manifest(1)
        XCTAssertThrowsError(try N.scenario(name: "wrong-input", inputs: ["x0": .init(0, .i64)], memory: [:], manifest: frozen))
        XCTAssertThrowsError(try N.scenario(name: "extra-input", inputs: ["input": .init(0, .i64), "x0_1": .init(0, .i64)], memory: [:], manifest: frozen))
        XCTAssertThrowsError(try N.scenario(name: "wrong-type", inputs: ["input": .init(0, .u64)], memory: [:], manifest: frozen))
        XCTAssertThrowsError(try unit(["result = x0_1;"]))
        let highBits: UInt64 = 0x8000000000000040
        let result = try unit(["address = (uint64_t)input; result = (int64_t)(address >> (uint32_t)63);"], input: highBits).run()
        XCTAssertEqual(result.commits.first(where: { $0.name == "address" })?.value.bits, highBits)
        XCTAssertEqual(result.terminal?.bits, 1)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.consumedResponses, 0)
    }

    func testNoCallAdapterRejectsFormalMapContradictionAndUnavailableMarker() {
        let valid = manifest(1)
        let wrong = N.FrozenManifest(signature: valid.signature, formals: [.init(name: "other", type: .i64)],
            sourceAddresses: valid.sourceAddresses, terminalRow: valid.terminalRow,
            terminalPayload: valid.terminalPayload, terminal: valid.terminal,
            labelAddresses: [], memoryEffects: [:])
        XCTAssertThrowsError(try N.contract(wrong))
        XCTAssertThrowsError(try N.contract(manifest(1, terminal: .value(name: "unresolved_return_contract", type: .i64),
            payload: "return unresolved_return_contract;")))
    }

    func testNoCallVoidObservationPreservesExactProtectedTerminal() throws {
        let frozen = manifest(1, terminal: .void, payload: "return; // exact parser-unit void terminal")
        let actual = lines(["uint32_t discarded = (uint32_t)input;"], manifest: frozen)
        let program = try N.program(lines: actual, manifest: frozen)
        let scenario = try N.scenario(name: "void-observation", inputs: ["input": .init(7, .i64)], memory: [:], manifest: frozen)
        let result = try C.Machine(program: program, scenario: scenario).run()
        XCTAssertTrue(result.returned); XCTAssertNil(result.terminal)
        var changed = actual
        changed[changed.count - 2] = .init(text: "return 0;", source: frozen.sourceAddresses[frozen.terminalRow], envelope: .body)
        XCTAssertThrowsError(try N.program(lines: changed, manifest: frozen))
        var duplicated = actual
        duplicated.insert(actual[actual.count - 2], at: actual.count - 1)
        XCTAssertThrowsError(try N.program(lines: duplicated, manifest: frozen))
    }

    func testFrozenABIEnvelopeInitializesOnlyExternallyBoundNames() throws {
        let comment = "/* ABI inputs: x7:int64_t recorded_input */"
        let frozen = N.FrozenManifest(signature: "int64_t native_abi_unit(\(comment)) {",
            formals: [.init(name: "recorded_input", type: .i64)], sourceAddresses: [0x1000, 0x1004],
            terminalRow: 1, terminalPayload: "return result;", terminal: .value(name: "result", type: .i64),
            labelAddresses: [], memoryEffects: [:], entryEnvelope: .frozenABIInputs(comment: comment))
        let actual = lines(["result = recorded_input;"], manifest: frozen)
        let program = try N.program(lines: actual, manifest: frozen)
        let scenario = try N.scenario(name: "ABI-envelope-parser-unit", inputs: ["recorded_input": .init(7, .i64)],
                                      memory: [:], manifest: frozen)
        let result = try C.Machine(program: program, scenario: scenario).run()
        XCTAssertEqual(result.terminal?.bits, 7)
        try N.requireTerminal(result, manifest: frozen)
        XCTAssertNil(program.symbols["x7"]); XCTAssertNil(program.symbols["x7_0"])
        XCTAssertThrowsError(try N.scenario(name: "not-an-input", inputs: ["x7": .init(7, .i64)], memory: [:], manifest: frozen))
        var wrongMode = frozen; wrongMode.entryEnvelope = .declaredFormals
        XCTAssertThrowsError(try N.contract(wrongMode))
        var changed = actual
        changed[0] = .init(text: "int64_t native_abi_unit(int64_t recorded_input) {", source: nil, envelope: .signature)
        XCTAssertThrowsError(try N.program(lines: changed, manifest: frozen), "do not rewrite ABI-only headers to fit C formals")
        var wrongComment = frozen; wrongComment.entryEnvelope = .frozenABIInputs(comment: "/* ABI inputs: changed */")
        XCTAssertThrowsError(try N.contract(wrongComment))
    }

    func testUnavailableTerminalIsNonnumericAndRequiresExactCapability() throws {
        let frozen = manifest(1, terminal: .unavailableReturnContract, payload: "return unresolved_return_contract; // parser-unit marker")
        let actual = lines(["uint32_t discarded = (uint32_t)input;"], manifest: frozen)
        let program = try N.program(lines: actual, manifest: frozen)
        XCTAssertNil(program.symbols["unresolved_return_contract"])
        XCTAssertTrue(program.code.contains { if case .unavailableReturn = $0.node { return true }; return false })
        let scenario = try N.scenario(name: "nonnumeric-parser-unit", inputs: ["input": .init(7, .i64)], memory: [:], manifest: frozen)
        let result = try C.Machine(program: program, scenario: scenario).run()
        XCTAssertTrue(result.returned); XCTAssertNil(result.terminal)
        XCTAssertEqual(result.unavailableTerminal, .unresolvedReturnContract)
        XCTAssertFalse(result.commits.contains { $0.name == "unresolved_return_contract" })
        try N.requireTerminal(result, manifest: frozen)
        var noCapability = try N.contract(frozen); noCapability.noCallUnavailableTerminal = false
        XCTAssertThrowsError(try C.Program(lines: actual, contract: noCapability))
        XCTAssertThrowsError(try N.requireTerminal(result, manifest: manifest(1, terminal: .void, payload: "return;")))
        let void = C.Result(memory: [:], returned: true)
        XCTAssertThrowsError(try N.requireTerminal(void, manifest: frozen))
    }

    func testUnavailableTerminalRejectsReuseArithmeticDuplicationAndWrongSource() throws {
        let frozen = manifest(1, terminal: .unavailableReturnContract, payload: "return unresolved_return_contract;")
        XCTAssertThrowsError(try N.program(lines: lines(["discarded = unresolved_return_contract;"], manifest: frozen), manifest: frozen))
        XCTAssertThrowsError(try N.program(lines: lines(["uint64_t unresolved_return_contract = 0;"], manifest: frozen), manifest: frozen))
        XCTAssertThrowsError(try unit(["uint64_t unresolved_return_contract = 0; result = 1;"]))
        let actual = lines(["uint32_t discarded = (uint32_t)input;"], manifest: frozen)
        for payload in ["return 0;", "return;", "return unresolved_return_contract + 0;", "return unresolved_return_contract; discarded = 0;"] {
            var changed = actual
            changed[changed.count - 2] = .init(text: payload, source: frozen.sourceAddresses[1], envelope: .body)
            XCTAssertThrowsError(try N.program(lines: changed, manifest: frozen), payload)
        }
        var duplicated = actual
        duplicated.insert(actual[actual.count - 2], at: actual.count - 1)
        XCTAssertThrowsError(try N.program(lines: duplicated, manifest: frozen))
        var wrongRow = actual
        wrongRow[wrongRow.count - 2] = .init(text: frozen.terminalPayload, source: frozen.sourceAddresses[0], envelope: .body)
        XCTAssertThrowsError(try N.program(lines: wrongRow, manifest: frozen))
        let premature = [actual[0], actual[2], actual[1], actual[3]]
        XCTAssertThrowsError(try N.program(lines: premature, manifest: frozen), "marker is not a mid-body value/statement")
    }
}
