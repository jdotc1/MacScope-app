import Foundation
import CryptoKit
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

enum RegionalSwitchSeed: CaseIterable {
    case jinit, j12init, j16initC4Negative
    var name: String {
        switch self {
        case .jinit: return "_jinit_color_deconverter"
        case .j12init: return "_j12init_color_deconverter"
        case .j16initC4Negative: return "_j16init_color_deconverter"
        }
    }
    var start: UInt64 {
        switch self {
        case .jinit: return 0x26c78
        case .j12init: return 0x2893c
        case .j16initC4Negative: return 0x2a69c
        }
    }
    var returnRow: Int {
        switch self {
        case .jinit: return 294
        case .j12init: return 284
        case .j16initC4Negative: return 281
        }
    }
    var callRows: [Int] {
        switch self {
        case .jinit: return [17, 23, 51, 86, 99, 120, 212, 234, 262, 274, 285, 317]
        case .j12init: return [17, 23, 51, 86, 121, 194, 227, 255, 275, 307]
        case .j16initC4Negative: return [17, 23, 51, 86, 121, 198, 231, 259]
        }
    }
    var rowCount: Int { self == .jinit ? 331 : self == .j12init ? 321 : 315 }
    var blockCount: Int { self == .jinit ? 101 : 98 }
    var fixtureSHA256: String {
        switch self {
        case .jinit: return "61d298bbfabb00132fa0a37496d7ff5b2cb642a187ea1527cc29444b2dd1dbb3"
        case .j12init: return "cbbbafd0df3ef8a3feb2107aeab0e8a8e109c6ba81db81c041ca36930fd32e94"
        case .j16initC4Negative: return "51455cb948105dbe49ec526d678dddcc093fde4801c5a01cee58e27e48fb9d43"
        }
    }
}

/// Prospective test adapter. Loading does not machine-decode, lift or render.
/// make() uses the complete recorded native input and production entry points.
/// No workspace reconstruction, header preprocessing, signature synthesis or
/// generated alternate-options "baseline" is permitted here.
struct RegionalSwitchFixture {
    enum Failure: Error { case invalid(String) }
    struct CapturedCall: Decodable {
        let lifted_index: Int
        let effect_ordinal: Int
        let source_address: String
        let baseline_line_number: Int
        let baseline_text: String
        let instruction_reflection: String
    }
    struct CapturedBlock: Decodable, Equatable {
        let index: Int
        let start_index: Int
        let end_index_exclusive: Int
        let start_address: String
        let last_source_address: String
        let successors: [Int]
        let predecessors: [Int]
        let is_loop_header: Bool
        init(_ block: BasicBlock, instructions: [MacIRInstruction]) {
            index = block.index; start_index = block.startIndex; end_index_exclusive = block.endIndex
            start_address = RegionalSwitchContext.hex(instructions[block.startIndex].source.address)
            last_source_address = RegionalSwitchContext.hex(instructions[block.endIndex - 1].source.address)
            successors = block.successors; predecessors = block.predecessors; is_loop_header = block.isLoopHeader
        }
    }
    struct CapturedSwitch: Decodable, Equatable {
        struct RegisterValue: Decodable, Equatable { let kind: String; let name: String; let version: Int }
        struct Immediate: Decodable, Equatable {
            let kind: String; let signed_value_decimal: String; let bit_pattern_hex: String
            func value() throws -> Int64 {
                guard kind == "immediate", let value = Int64(signed_value_decimal),
                      UInt64(bitPattern: value) == (try RegionalSwitchContext.address(bit_pattern_hex)) else {
                    throw Failure.invalid("invalid exact signed switch target")
                }
                return value
            }
        }
        struct Case: Decodable, Equatable {
            let ordinal: Int; let value_decimal: String
            let typed_target: Immediate
            let target_address: String?; let target_block: Int?
        }
        let source_address: String
        let lifted_index: Int
        let effect_ordinal: Int
        let input_row_indices: [Int]
        let selector: RegisterValue
        let cases: [Case]
        let default_target: Immediate?
        let default_address: String?
        let default_block: Int?
        let block: CapturedBlock?
        let ordered_distinct_target_blocks: [Int]
        let raw_table_targets: [String]?
        let raw_table_matches_ordered_cases: Bool?
        let case_values_match_ordinals: Bool
        let target_projection_matches_cfg_successors: Bool?
        let all_case_and_default_targets_resolve_to_blocks: Bool
    }
    struct Counts: Decodable { let raw_goto_lines: Int; let total_goto_lines: Int; let raw_branch_lines: Int }
    struct Capture: Decodable {
        let fixture_schema_version: Int
        let function: String
        let start: String
        let render_input_context: RegionalSwitchContext
        let input_rows: [InstructionRow]
        let signature_parameter_compatibility_indices: [RegionalSwitchParameterIndex]
        let canonical_text: String
        let schema_identity: SchemaIdentity
        let input_roundtrip: [String: Bool]
        let options_reflection: String
        let source_capture: String
        let source_capture_sha256: String
        let function_normalized_sha256: String
        let lifted_instruction_normalized_sha256: [String]
        let cfg_blocks: [CapturedBlock]
        let switch_facts: [CapturedSwitch]
        let calls: [CapturedCall]
        let ret_rows: [Int]
        let baseline_counts: Counts
        let authority_role: String
        let producer_replay: String
        let projected_model_replay: String

        struct SchemaIdentity: Decodable {
            let input_type: String; let row_type: String; let signature_schema_version: Int
            let optional_policy: String; let integer_policy: String; let equality_policy: String
        }
        func restoredInput() throws -> PseudocodeRenderInput {
            try render_input_context.restore(rows: input_rows, indices: signature_parameter_compatibility_indices)
        }
    }

    let seed: RegionalSwitchSeed
    /// Historical source witness only, not the actual schema2 render context.
    let capture: Capture
    let schema2InputAuthority: RegionalSchema2Fixture.Capture?
    let input: PseudocodeRenderInput
    let function: MacIRFunction
    let document: PseudocodeDocument
    var rows: [InstructionRow] { input.instructions }
    var baselineText: String { schema2InputAuthority?.canonical_text ?? capture.canonical_text }
    func requireCompleteInputAuthority() throws {
        guard let authority = schema2InputAuthority else {
            throw Failure.invalid("historical negative is not a complete schema2 capture")
        }
        try RegionalSchema2BuiltFixture.requireCompleteInputAuthority(input, capture: authority)
    }
    /// All oracle-consumed historical fields must bind to the new exact input.
    /// Reflected old IR fingerprints are explicitly not new model authority.
    static func requireHistoricalSourceWitness(_ witness: Capture,
                                               capture: RegionalSchema2Fixture.Capture,
                                               original: MacIRFunction) throws {
        let blocks = CFGBuilder.buildCFG(instructions: original.instructions).blocks.map {
            CapturedBlock($0, instructions: original.instructions)
        }
        guard witness.function == capture.function, witness.start == capture.start,
              witness.input_rows == capture.input_rows, witness.cfg_blocks == blocks,
              witness.canonical_text == capture.canonical_text,
              witness.switch_facts == capture.switch_facts,
              capture.lifted_rows.count == capture.input_rows.count,
              witness.ret_rows == capture.input_rows.indices.filter({ capture.input_rows[$0].mnemonic == "ret" }) else {
            throw Failure.invalid("historical color source witness does not bind to fresh input")
        }
        let lines = capture.canonical_text.components(separatedBy: "\n")
        guard lines.filter({ $0.contains("goto 0x") }).count == witness.baseline_counts.raw_goto_lines,
              lines.filter({ $0.contains("goto ") }).count == witness.baseline_counts.total_goto_lines,
              lines.filter({ $0.contains("__branch(") }).count == witness.baseline_counts.raw_branch_lines else {
            throw Failure.invalid("historical baseline counts do not bind exact fresh text")
        }
        for call in witness.calls {
            guard capture.lifted_rows.indices.contains(call.lifted_index),
                  capture.input_rows.indices.contains(call.lifted_index),
                  lines.indices.contains(call.baseline_line_number - 1) else {
                throw Failure.invalid("historical call witness coordinate out of range")
            }
            let row = capture.lifted_rows[call.lifted_index]
            guard row.index == call.lifted_index, row.effect_ordinal == call.effect_ordinal,
                  row.source_address == call.source_address,
                  RegionalSchema2Context.hex(capture.input_rows[call.lifted_index].address) == call.source_address,
                  lines[call.baseline_line_number - 1] == call.baseline_text else {
                throw Failure.invalid("historical call witness source/effect/text mismatch")
            }
        }
    }
    struct CallPayloadComparison {
        let row: Int; let address: UInt64; let baseline: String; let after: [String]
        var changedBeyondIndentation: Bool { after != [baseline] }
    }
    var callPayloads: [CallPayloadComparison] {
        capture.calls.map { call in
            let address = input.instructions[call.lifted_index].address
            return CallPayloadComparison(row: call.lifted_index, address: address,
                baseline: Self.payload(call.baseline_text),
                after: document.lines(sourcedAt: address).filter { $0.text.hasSuffix("// call") }.map { Self.payload($0.text) })
        }
    }
    static func payload(_ text: String) -> String { String(text.drop(while: { $0 == " " })) }

    static func load(_ seed: RegionalSwitchSeed) throws -> Capture {
        let base: URL
        if let repo = ProcessInfo.processInfo.environment["PORTABLE_REPO"] {
            base = URL(fileURLWithPath: repo).appendingPathComponent("MacScope/Tests/CoreTests/Fixtures/RegionalSwitch")
        } else {
            base = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/RegionalSwitch")
        }
        let data = try Data(contentsOf: base.appendingPathComponent(RegionalSwitchContext.hex(seed.start) + ".json"))
        guard sha256(data) == seed.fixtureSHA256 else { throw Failure.invalid("fixture bytes changed") }
        let capture = try JSONDecoder().decode(Capture.self, from: data)
        guard capture.fixture_schema_version == 1,
              capture.schema_identity.signature_schema_version == FunctionSignatureOverride.currentSchemaVersion,
              capture.function == seed.name,
              try RegionalSwitchContext.address(capture.start) == seed.start,
              capture.input_rows.count == seed.rowCount, capture.cfg_blocks.count == seed.blockCount,
              capture.calls.map(\.lifted_index) == seed.callRows, capture.ret_rows == [seed.returnRow],
              capture.lifted_instruction_normalized_sha256.count == seed.rowCount else {
            throw Failure.invalid("wrong capture identity or incomplete fixture")
        }
        return capture
    }

    /// This future test execution performs exactly one full-context producer lift
    /// and one default print. It does not run ARM64Decoder or replay the baseline capture.
    static func make(_ seed: RegionalSwitchSeed) throws -> Self {
        if seed == .j16initC4Negative { return try makeHistorical(seed) }
        let witness = try load(seed)
        let full = try RegionalSchema2Bindings39A.make(function: seed.name, start: seed.start)
        try requireHistoricalSourceWitness(witness, capture: full.capture, original: full.original)
        let fixture = Self(seed: seed, capture: witness, schema2InputAuthority: full.capture,
            input: full.input, function: full.original, document: full.document)
        try fixture.requireCompleteInputAuthority()
        return fixture
    }

    /// Outside current capture coverage: retain the explicit historical reduced j16 negative.
    private static func makeHistorical(_ seed: RegionalSwitchSeed) throws -> Self {
        guard seed == .j16initC4Negative else { throw Failure.invalid("historical route is negative-only") }
        let capture = try load(seed)
        let input = try capture.restoredInput()
        let printer = PseudocodePrinter(options: .default)
        guard normalizedReflection(String(reflecting: DecompilerOptions.default)) == normalizedReflection(capture.options_reflection) else {
            throw Failure.invalid("default option drift; do not redefine capture authority")
        }
        let function = printer.buildFunction(functionName: input.functionName, startAddress: input.startAddress,
            jumpTables: input.jumpTables, objcSelectors: input.objcSelectors, constantStrings: input.constantStrings,
            signatureOverrides: input.signatureOverrides, authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            callerReturnWidth: input.callerReturnWidth, types: input.types, instructions: input.instructions)
        let capturedLines = capture.canonical_text.components(separatedBy: "\n")
        let baselineCallLines = try capture.calls.map { call in
            guard capturedLines.indices.contains(call.baseline_line_number - 1) else {
                throw Failure.invalid("call row \(call.lifted_index): captured line \(call.baseline_line_number) is out of range")
            }
            return capturedLines[call.baseline_line_number - 1]
        }
        RenderProperties.assertCallShape(function, callRows: capture.calls.map(\.lifted_index),
            decoded: input.instructions, baselineCallLines: baselineCallLines)
        let returnRow = try RenderProperties.returnRow(decoded: input.instructions)
        guard returnRow == seed.returnRow else {
            throw Failure.invalid("decoded RET row: \(returnRow) != captured \(seed.returnRow)")
        }
        RenderProperties.assertReturnShape(function, returnRow: returnRow)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        guard cfg.blocks.count == capture.cfg_blocks.count else {
            throw Failure.invalid("CFG block count: \(cfg.blocks.count) != captured \(capture.cfg_blocks.count)")
        }
        for row in [198, 259, 279, 281] {
            guard let expected = capture.cfg_blocks.first(where: {
                $0.start_index <= row && row < $0.end_index_exclusive
            }), let actual = cfg.blocks.first(where: {
                $0.startIndex <= row && row < $0.endIndex
            }) else {
                throw Failure.invalid("CFG row \(row): missing captured or current block")
            }
            guard actual.startIndex == expected.start_index, actual.endIndex == expected.end_index_exclusive,
                  actual.successors == expected.successors else {
                throw Failure.invalid("CFG row \(row): span \(actual.startIndex)..<\(actual.endIndex), successors \(actual.successors) != captured span \(expected.start_index)..<\(expected.end_index_exclusive), successors \(expected.successors)")
            }
        }
        let document = printer.print(function: function, types: input.types, nameOverrides: input.nameOverrides,
            registerNameOverrides: input.registerNameOverrides, stackLocalOverrides: input.stackLocalOverrides,
            resolvedIndirectCalls: input.resolvedIndirectCalls)
        let fixture = Self(seed: seed, capture: capture, schema2InputAuthority: nil,
            input: input, function: function, document: document)
        for comparison in fixture.callPayloads {
            guard !comparison.changedBeyondIndentation else {
                throw Failure.invalid("call row \(comparison.row): \(comparison.after) != captured \(comparison.baseline)")
            }
        }
        return fixture
    }
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func reflectionSHA256<T>(_ value: T) -> String {
        sha256(Data(normalizedReflection(String(reflecting: value)).utf8))
    }
    static func normalizedReflection(_ source: String) -> String {
        var text = source
        for prefix in ["MacScopeAnalysisCore.", "MacScope.", "RenderAll."] {
            text = text.replacingOccurrences(of: prefix, with: "")
        }
        // Native numeric Set ordering is unspecified. Preserve every member;
        // do not normalize arrays, dictionaries, other sets, text or nil values.
        let pattern = try! NSRegularExpression(pattern: #"Set\(\[([0-9, ]*)\]\)"#)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let body = Range(match.range(at: 1), in: text)!
            let members = text[body].split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces))! }.sorted()
            text.replaceSubrange(Range(match.range, in: text)!, with: "Set([" + members.map(String.init).joined(separator: ", ") + "])")
        }
        return text
    }
}
