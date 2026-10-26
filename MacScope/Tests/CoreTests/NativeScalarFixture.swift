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

/// First three original sites, not relocated shape fixtures or complete-corpus coverage.
/// The remaining original sites can use the same transport without new grammar.
enum NativeScalarSeed: CaseIterable {
    case interleavedRGB8, entryNoscale8, nullRGB8
    case entryDownscale17c88, entryUpscale30134, entryNoscale30630, entryNoscale30b10
    static let originalThreeSeeds: [Self] = [.interleavedRGB8, .entryNoscale8, .nullRGB8]
    static let remainingEntrySeeds: [Self] = [.entryDownscale17c88, .entryUpscale30134, .entryNoscale30630, .entryNoscale30b10]
    var start: UInt64 {
        switch self { case .interleavedRGB8: return 0x3854
        case .entryNoscale8: return 0x30150
        case .nullRGB8: return 0x3704
        case .entryDownscale17c88: return 0x17c88
        case .entryUpscale30134: return 0x30134
        case .entryNoscale30630: return 0x30630
        case .entryNoscale30b10: return 0x30b10 }
    }
    var name: String {
        switch self { case .interleavedRGB8: return "_extrgb_rgb_convert"
        case .entryNoscale8: return "_noscale"
        case .nullRGB8: return "_null_convert"
        case .entryDownscale17c88: return "_simple_downscale"
        case .entryUpscale30134: return "_simple_upscale"
        case .entryNoscale30630, .entryNoscale30b10: return "_noscale" }
    }
    var rowCount: Int {
        switch self { case .interleavedRGB8: return 26; case .entryNoscale8: return 5; case .nullRGB8: return 84
        case .entryDownscale17c88, .entryUpscale30134: return 7
        case .entryNoscale30630, .entryNoscale30b10: return 5 }
    }
    var blockCount: Int {
        switch self { case .interleavedRGB8: return 7; case .entryNoscale8: return 2; case .nullRGB8: return 24
        case .entryDownscale17c88, .entryUpscale30134, .entryNoscale30630, .entryNoscale30b10: return 2 }
    }
    var baselineTextSHA256: String {
        switch self {
        case .interleavedRGB8: return "c56094064e27f3eacea9a51d29ce8f6664a297fe1adab97a21d29d6fda865fee"
        case .entryNoscale8: return "c140d113992c9100376e0eed27f6a918f8c2b1424b83ddcd40d333603b431018"
        case .nullRGB8: return "9a3c19d3ad63e8981a8cb9f04b097ec72d9f8a6e5f2cb6a1bddcc3aa45cc5aa2"
        case .entryDownscale17c88: return "19094ce1b0f304fd158a304dc7154aa726623e46c09f9b3fe3797ad54055ed6d"
        case .entryUpscale30134: return "fe9260f65433e5d43dd758f2a7ffa295f51fcd01bdc1c6ca7c6ffbcc7e4f5252"
        case .entryNoscale30630: return "42f579cee6f35e04bc29412e87c504f2f4164d814c0cf0702ab82afbec0e4aa6"
        case .entryNoscale30b10: return "0e34234616af822b102e51d823198c9be7f6de136176f8b41af33e158de5346e"
        }
    }
}

/// Immutable original native inputs are authority. There is deliberately no
/// reflected-IR decoder, baseline re-render, workspace reconstruction, ARM decoder,
/// reduced context, current-candidate-derived baseline, or recovery-path fallback.
struct NativeScalarFixture {
    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { switch self { case let .invalid(text): return text } }
    }
    struct FrozenBlock: Decodable, Equatable {
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
            start_address = NativeScalarContext.hex(instructions[block.startIndex].source.address)
            last_source_address = NativeScalarContext.hex(instructions[block.endIndex - 1].source.address)
            successors = block.successors; predecessors = block.predecessors; is_loop_header = block.isLoopHeader
        }
    }
    struct Capture: Decodable {
        struct Schema: Decodable {
            let input_type: String
            let row_type: String
            let signature_schema_version: Int
            let optional_policy: String
            let integer_policy: String
            let equality_policy: String
        }
        let schema_version: Int
        let schema_identity: Schema
        let function: String
        let start: String
        let input_rows: [InstructionRow]
        let render_input_context: NativeScalarContext
        let signature_parameter_compatibility_indices: [NativeScalarParameterIndex]
        let canonical_text: String
        let canonical_text_sha256: String
        let cfg_blocks: [FrozenBlock]
        let input_roundtrip: [String: Bool]
        let text_identical: Bool
        /// Present only for a schema2 view. The reduced legacy fields below are
        /// projections for existing consumers, never complete render authority.
        let schema2_input_authority: RegionalSchema2Fixture.Capture?
        var signature: String { canonical_text.components(separatedBy: "\n")[0] }
        var terminalPayload: String {
            canonical_text.components(separatedBy: "\n").dropLast().last!
                .trimmingCharacters(in: .whitespaces)
        }
        func restoredInput() throws -> PseudocodeRenderInput {
            if schema_version == 2 {
                guard let full = schema2_input_authority else {
                    throw Failure.invalid("schema2 native view lacks complete authority")
                }
                let input = try full.restoredInput()
                guard full.schema_version == schema_version, full.function == function, full.start == start,
                      full.schema_identity.input_type == schema_identity.input_type,
                      full.schema_identity.row_type == schema_identity.row_type,
                      full.schema_identity.signature_schema_version == schema_identity.signature_schema_version,
                      full.schema_identity.optional_policy == schema_identity.optional_policy,
                      full.schema_identity.integer_policy == schema_identity.integer_policy,
                      full.schema_identity.equality_policy == schema_identity.equality_policy,
                      full.input_rows == input_rows, full.cfg_blocks == cfg_blocks,
                      full.canonical_text == canonical_text, full.canonical_text_sha256 == canonical_text_sha256,
                      full.input_roundtrip == input_roundtrip, full.text_identical == text_identical,
                      NativeScalarContext(input) == render_input_context,
                      NativeScalarParameterIndex.capture(input) == signature_parameter_compatibility_indices else {
                    throw Failure.invalid("schema2 native consumer projection changed source facts")
                }
                try RegionalSchema2BuiltFixture.requireCompleteInputAuthority(input, capture: full)
                return input
            }
            guard schema_version == 1, schema2_input_authority == nil else {
                throw Failure.invalid("unknown native view schema")
            }
            return try render_input_context.restore(rows: input_rows, indices: signature_parameter_compatibility_indices)
        }
        static func schema2View(_ full: RegionalSchema2Fixture.Capture, input: PseudocodeRenderInput) -> Self {
            let schema = full.schema_identity
            return .init(schema_version: full.schema_version,
                schema_identity: .init(input_type: schema.input_type, row_type: schema.row_type,
                    signature_schema_version: schema.signature_schema_version, optional_policy: schema.optional_policy,
                    integer_policy: schema.integer_policy, equality_policy: schema.equality_policy),
                function: full.function, start: full.start, input_rows: full.input_rows,
                render_input_context: NativeScalarContext(input),
                signature_parameter_compatibility_indices: NativeScalarParameterIndex.capture(input),
                canonical_text: full.canonical_text, canonical_text_sha256: full.canonical_text_sha256,
                cfg_blocks: full.cfg_blocks, input_roundtrip: full.input_roundtrip,
                text_identical: full.text_identical, schema2_input_authority: full)
        }
    }
    private struct Corpus: Decodable {
        let fixture_schema_version: Int
        let source_main: String
        let baseline_sha256: String
        let capture_sha256: String
        let capture_status: String
        let records: [Capture]
    }
    let seed: NativeScalarSeed
    let capture: Capture
    let input: PseudocodeRenderInput
    /// Built once, before candidate rendering, from the complete frozen native
    /// input. Supplies original typed identities, never candidate scalar values.
    let original: MacIRFunction
    let document: PseudocodeDocument
    var rows: [InstructionRow] { input.instructions }
    var baselineText: String { capture.canonical_text }
    var originalParameters: [MacIRFunctionParameter] { original.parameters }
    var originalTerminal: MacIROperation { original.instructions.last!.operation }

    static func load(_ seed: NativeScalarSeed) throws -> Capture {
        if NativeScalarSeed.remainingEntrySeeds.contains(seed) { return try loadRemainingEntry(seed) }
        let url = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/NativeScalar/first-three-current-main.json")
        let data = try Data(contentsOf: url)
        // Inspect explicit optional-key presence without inventing native Codable
        // keys that the authoritative model intentionally omits.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["records"] as? [[String: Any]], records.count == 3 else {
            throw Failure.invalid("missing exact nativeScalar fixture resource")
        }
        for record in records {
            guard let context = record["render_input_context"] as? [String: Any],
                  Set(context.keys) == Set(["image_slot", "function_name", "start_address", "jump_tables",
                    "objc_selectors", "constant_strings", "name_overrides", "signature_overrides",
                    "authored_call_signatures_by_target", "register_name_overrides", "stack_local_overrides",
                    "types", "resolved_indirect_calls", "slot_call_contracts", "caller_return_width", "caller_return_type"]),
                  let rows = record["input_rows"] as? [[String: Any]],
                  rows.allSatisfy({ $0.keys.contains("comment") && $0.keys.contains("structuredOperands") }) else {
                throw Failure.invalid("incomplete current-main context or omitted original optional envelope")
            }
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard corpus.fixture_schema_version == 1,
              corpus.source_main == "9a9b5613904a8cb632ca41fa65a39dbafb01571a",
              corpus.baseline_sha256 == "2c756bee83d78cac7cdb1a8667dece21883f904fd5129b5ab4bba20f097e0a28",
              corpus.capture_sha256 == "ef0e24f721570732b0d45b454fbb4935e1500d69beca4ead8d2a06bba9288035",
              corpus.capture_status == "CAPTURE_COMPLETE_INPUTS_ONLY_NOT_TEST_OR_PRODUCT_ACCEPTANCE",
              Set(corpus.records.map(\.start)) == Set(NativeScalarSeed.originalThreeSeeds.map { NativeScalarContext.hex($0.start) }),
              let capture = corpus.records.first(where: { $0.start == NativeScalarContext.hex(seed.start) }),
              capture.schema_version == 1, capture.schema_identity.input_type == "PseudocodeRenderInput",
              capture.schema_identity.row_type == "InstructionRow",
              capture.schema_identity.signature_schema_version == FunctionSignatureOverride.currentSchemaVersion,
              capture.function == seed.name, capture.render_input_context.function_name == seed.name,
              capture.render_input_context.start_address == capture.start,
              capture.input_rows.count == seed.rowCount, capture.cfg_blocks.count == seed.blockCount,
              capture.canonical_text_sha256 == seed.baselineTextSHA256,
              SHA256.hash(data: Data(capture.canonical_text.utf8)).map({ String(format: "%02x", $0) }).joined() == seed.baselineTextSHA256,
              capture.text_identical,
              capture.input_roundtrip == ["codable_payload_semantically_equal": true,
                "input_row_optional_keys_present": true, "json_serialization_transport_semantically_equal": true,
                "restored_render_input_semantically_equal": true, "signature_compatibility_index_ledger_equal": true],
              capture.input_rows.enumerated().allSatisfy({ pair in
                pair.element.address == seed.start + UInt64(pair.offset * 4) && pair.element.byteWidth == 4
              }), capture.input_rows.last?.mnemonic == "ret" else {
            throw Failure.invalid("wrong original nativeScalar identity or incomplete successful capture")
        }
        return capture
    }

    // Separate next input: original-three resource and validation are unchanged.
    private static func loadRemainingEntry(_ seed: NativeScalarSeed) throws -> Capture {
        let url = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/NativeScalar/remaining-entry-current-main.json")
        let data = try Data(contentsOf: url)
        // Inspect explicit optional-key presence without inventing native Codable
        // keys that the authoritative model intentionally omits.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["records"] as? [[String: Any]], records.count == 4 else {
            throw Failure.invalid("missing exact nativeScalar fixture resource")
        }
        for record in records {
            guard let context = record["render_input_context"] as? [String: Any],
                  Set(context.keys) == Set(["image_slot", "function_name", "start_address", "jump_tables",
                    "objc_selectors", "constant_strings", "name_overrides", "signature_overrides",
                    "authored_call_signatures_by_target", "register_name_overrides", "stack_local_overrides",
                    "types", "resolved_indirect_calls", "slot_call_contracts", "caller_return_width", "caller_return_type"]),
                  let rows = record["input_rows"] as? [[String: Any]],
                  rows.allSatisfy({ $0.keys.contains("comment") && $0.keys.contains("structuredOperands") }) else {
                throw Failure.invalid("incomplete current-main context or omitted original optional envelope")
            }
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard corpus.fixture_schema_version == 1,
              corpus.source_main == "9a9b5613904a8cb632ca41fa65a39dbafb01571a",
              corpus.baseline_sha256 == "2c756bee83d78cac7cdb1a8667dece21883f904fd5129b5ab4bba20f097e0a28",
              corpus.capture_sha256 == "ef0e24f721570732b0d45b454fbb4935e1500d69beca4ead8d2a06bba9288035",
              corpus.capture_status == "CAPTURE_COMPLETE_INPUTS_ONLY_NOT_TEST_OR_PRODUCT_ACCEPTANCE",
              Set(corpus.records.map(\.start)) == Set(NativeScalarSeed.remainingEntrySeeds.map { NativeScalarContext.hex($0.start) }),
              let capture = corpus.records.first(where: { $0.start == NativeScalarContext.hex(seed.start) }),
              capture.schema_version == 1, capture.schema_identity.input_type == "PseudocodeRenderInput",
              capture.schema_identity.row_type == "InstructionRow",
              capture.schema_identity.signature_schema_version == FunctionSignatureOverride.currentSchemaVersion,
              capture.function == seed.name, capture.render_input_context.function_name == seed.name,
              capture.render_input_context.start_address == capture.start,
              capture.input_rows.count == seed.rowCount, capture.cfg_blocks.count == seed.blockCount,
              capture.canonical_text_sha256 == seed.baselineTextSHA256,
              SHA256.hash(data: Data(capture.canonical_text.utf8)).map({ String(format: "%02x", $0) }).joined() == seed.baselineTextSHA256,
              capture.text_identical,
              capture.input_roundtrip == ["codable_payload_semantically_equal": true,
                "input_row_optional_keys_present": true, "json_serialization_transport_semantically_equal": true,
                "restored_render_input_semantically_equal": true, "signature_compatibility_index_ledger_equal": true],
              capture.input_rows.enumerated().allSatisfy({ pair in
                pair.element.address == seed.start + UInt64(pair.offset * 4) && pair.element.byteWidth == 4
              }), capture.input_rows.last?.mnemonic == "ret" else {
            throw Failure.invalid("wrong original nativeScalar identity or incomplete successful capture")
        }
        return capture
    }

    /// One full-input build bound to source 39a734962 and candidate print. The old schema1
    /// resources/loaders remain historical evidence and are never render authority.
    static func make(_ seed: NativeScalarSeed) throws -> Self {
        let full = try RegionalSchema2Bindings39A.make(function: seed.name, start: seed.start)
        guard full.rows.count == seed.rowCount, full.capture.cfg_blocks.count == seed.blockCount,
              full.capture.canonical_text_sha256 == seed.baselineTextSHA256 else {
            throw Failure.invalid("same-site native seed source/text identity drift")
        }
        let view = Capture.schema2View(full.capture, input: full.input)
        _ = try view.restoredInput()
        return .init(seed: seed, capture: view, input: full.input,
                     original: full.original, document: full.document)
    }

    /// Original native display identity only. Candidate values never come from
    /// this producer helper, and no candidate identifier is decoded as a register.
    func originalName(_ value: MacIRValue) -> String {
        PseudocodePrinter(options: .default).valueText(for: value,
            names: PseudocodeNameContext(function: original, types: input.types,
                callTargetRenames: input.nameOverrides, registerNameOverrides: input.registerNameOverrides))
    }
    var textLines: [OrdinaryC.TextLine] {
        document.lines.map { line in
            let kind: OrdinaryC.EnvelopeKind
            switch line.kind {
            case .signature: kind = .signature
            case .metadata: kind = .metadata
            case .closingBrace: kind = .closingBrace
            default: kind = .body
            }
            return .init(text: line.text, source: line.sourceAddress, envelope: kind)
        }
    }
}
