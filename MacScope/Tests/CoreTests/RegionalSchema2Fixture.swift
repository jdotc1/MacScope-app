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

/// Bound schema2 loader. There is deliberately no implicit resource, seed
/// migration, producer lift, candidate render, ARM decoder or signature synthesis.
/// Bindings must be installed from observed new-input evidence after independent
/// applicability review. Loading is not semantic or product acceptance.
enum RegionalSchema2Fixture {
    enum Failure: Error { case invalid(String) }
    static let sourceMain = "39a734962b84727de6bafeb6ef7e2211eff69ff1"
    static let harnessSHA256 = "93dc461bb7407014a30a2619fcff1d99044a373a64c88a49b8aaa33a4027ac93"
    static let captureStatus = "CAPTURE_COMPLETE_INPUTS_ONLY_NOT_TEST_OR_PRODUCT_ACCEPTANCE"
    static let roundtrip: [String: Bool] = [
        "codable_payload_semantically_equal": true,
        "restored_render_input_semantically_equal": true,
        "signature_compatibility_index_ledger_equal": true,
        "restored_signature_compatibility_indices_equal": true,
        "json_serialization_transport_semantically_equal": true,
        "input_row_optional_keys_present": true
    ]
    struct Target: Decodable, Equatable {
        let function: String
        let start: String
        let canonical_text_sha256: String
        let input_rows: Int
        let cfg_blocks: Int
    }
    /// Independent external binding, never inferred from the resource being loaded.
    /// The separately pinned RegionalSchema2Bindings39A supplies observed exact input evidence.
    struct Binding: Decodable {
        let resource_sha256: String
        let source_main: String
        let capture_harness_sha256: String
        let source_capture: String
        let capture_sha256: String
        let canonical_baseline: String
        let baseline_sha256: String
        let targets: [Target]
    }
    struct Schema: Decodable, Equatable {
        let input_type: String
        let row_type: String
        let signature_schema_version: Int
        let optional_policy: String
        let integer_policy: String
        let equality_policy: String
        static var expected: Self {
            .init(input_type: "PseudocodeRenderInput", row_type: "InstructionRow",
                signature_schema_version: FunctionSignatureOverride.currentSchemaVersion,
                optional_policy: "encodeIfPresent(nil) emits null; deliberate custom-schema omissions retain native meaning",
                integer_policy: "UInt64 dictionary keys and explicit targets use canonical hex; native Codable integers remain exact integers",
                equality_policy: "native Codable/Equatable semantic equality plus exact signature compatibility-index ledger restored by dictionary/key/position/row-token and recaptured")
        }
    }
    struct LiftedRow: Decodable {
        let index: Int
        let effect_ordinal: Int
        let source_address: String
    }
    struct Capture: Decodable {
        let diagnostic_kind: String
        let schema_version: Int
        let schema_identity: Schema
        let function: String
        let start: String
        let input_rows: [InstructionRow]
        let render_input_context: RegionalSchema2Context
        let signature_parameter_compatibility_indices: [RegionalSchema2ParameterIndex]
        let canonical_text: String
        let canonical_text_sha256: String
        let cfg_blocks: [NativeScalarFixture.FrozenBlock]
        let switch_facts: [RegionalSwitchFixture.CapturedSwitch]
        let lifted_rows: [LiftedRow]
        let input_roundtrip: [String: Bool]
        let text_identical: Bool
        let options_reflection: String
        let canonical_reference: String
        var observedTarget: Target {
            .init(function: function, start: start, canonical_text_sha256: canonical_text_sha256,
                  input_rows: input_rows.count, cfg_blocks: cfg_blocks.count)
        }
        func restoredInput() throws -> PseudocodeRenderInput {
            // Context.restore checks all 17 stored context fields, every native
            // InstructionRow field and the separate exact three-map index ledger.
            try render_input_context.restore(rows: input_rows, indices: signature_parameter_compatibility_indices)
        }
    }
    private struct Corpus: Decodable {
        let fixture_schema_version: Int
        let source_main: String
        let capture_harness_sha256: String
        let source_capture: String
        let capture_sha256: String
        let canonical_baseline: String
        let baseline_sha256: String
        let capture_status: String
        let records: [Capture]
    }

    static func load(resource: URL, binding: Binding) throws -> [Capture] {
        let data = try Data(contentsOf: resource)
        guard sha256(data) == binding.resource_sha256,
              binding.source_main == sourceMain, binding.capture_harness_sha256 == harnessSHA256,
              !binding.source_capture.isEmpty, !binding.canonical_baseline.isEmpty,
              [binding.capture_sha256, binding.baseline_sha256].allSatisfy(isSHA256),
              !binding.targets.isEmpty,
              Set(binding.targets.map(\.start)).count == binding.targets.count else {
            throw Failure.invalid("unbound schema2 source/resource/target identity")
        }
        // Inspect stored envelope, not native custom-schema internals. Missing is
        // distinct from explicit null; native signature omissions retain meaning.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["records"] as? [[String: Any]], records.count == binding.targets.count else {
            throw Failure.invalid("missing schema2 records")
        }
        let rowKeys: Set<String> = ["address", "bytes", "mnemonic", "operands", "hasBreakpoint", "comment", "structuredOperands"]
        for record in records {
            guard let context = record["render_input_context"] as? [String: Any],
                  Set(context.keys) == RegionalSchema2Context.requiredKeys,
                  context["direct_call_void_result_targets"] is [String: Any],
                  let rows = record["input_rows"] as? [[String: Any]], !rows.isEmpty,
                  rows.allSatisfy({ Set($0.keys) == rowKeys }) else {
                throw Failure.invalid("incomplete schema2 context or InstructionRow envelope")
            }
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard corpus.fixture_schema_version == 2, corpus.source_main == binding.source_main,
              corpus.capture_harness_sha256 == binding.capture_harness_sha256,
              corpus.source_capture == binding.source_capture, corpus.capture_sha256 == binding.capture_sha256,
              corpus.canonical_baseline == binding.canonical_baseline, corpus.baseline_sha256 == binding.baseline_sha256,
              corpus.capture_status == captureStatus,
              corpus.records.map(\.observedTarget) == binding.targets else {
            throw Failure.invalid("wrong schema2 provenance or ordered observed targets; schema1 is not migratable")
        }
        for capture in corpus.records {
            guard capture.schema_version == 2, capture.diagnostic_kind == "regional_switch_exact_input_v2",
                  capture.schema_identity == Schema.expected, capture.input_roundtrip == roundtrip,
                  capture.text_identical, !capture.options_reflection.isEmpty, !capture.canonical_reference.isEmpty,
                  capture.function == capture.render_input_context.function_name,
                  capture.start == capture.render_input_context.start_address,
                  capture.input_rows.first?.address == (try RegionalSchema2Context.address(capture.start)),
                  sha256(Data(capture.canonical_text.utf8)) == capture.canonical_text_sha256 else {
                throw Failure.invalid("incomplete native schema2 capture identity/roundtrip/text")
            }
        }
        return corpus.records
    }
    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
