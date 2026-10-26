import Foundation
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// Observed capture input binding for source 39a734962.
/// This binding does not itself grant compile/runtime acceptance.
enum RegionalSchema2Bindings39A {
    static let coverageReceiptSHA256 = "cb0dcef6046104ee86005e326376b62c862a840e5fe50a1fe60b8b4e103f57e1"
    static let selectionLedgerSHA256 = "56296a47a91e29eda0f2bb062f712d33a44db0e1df868a389c8c8d7c565063cb"
    static let binding = RegionalSchema2Fixture.Binding(
        resource_sha256: "fa6dba92646216251827bdef9a0e24bbd5fa432a933eb874bcedc1ad2ad7553f",
        source_main: "39a734962b84727de6bafeb6ef7e2211eff69ff1",
        capture_harness_sha256: "93dc461bb7407014a30a2619fcff1d99044a373a64c88a49b8aaa33a4027ac93",
        source_capture: "captures/current-integration-existing67-39a734962-v1/witness-metadata.json.document-metadata.json",
        capture_sha256: "7f64aaf0c1fbc7ca16f8d515c22cc5d4e1a77b94672b636b181d0a83a3795c4c",
        canonical_baseline: "measurements/current-integration-h0-39a734962-flags-off-v1/pseudocode-all.txt",
        baseline_sha256: "8d4425cbe9a8dab91f4984e49dfde708642e05ab542eafa1c99994bebd34c2fb",
        targets: [
            .init(function: "_null_convert", start: "0x3704",
                  canonical_text_sha256: "a46b891f1c99eafafff1c1ae3bb1faafb6fba07cfacc20aeed03c7abf4e0cf9f", input_rows: 84, cfg_blocks: 24),
            .init(function: "_extrgb_rgb_convert", start: "0x3854",
                  canonical_text_sha256: "c56094064e27f3eacea9a51d29ce8f6664a297fe1adab97a21d29d6fda865fee", input_rows: 26, cfg_blocks: 7),
            .init(function: "_simple_downscale", start: "0x17c88",
                  canonical_text_sha256: "19094ce1b0f304fd158a304dc7154aa726623e46c09f9b3fe3797ad54055ed6d", input_rows: 7, cfg_blocks: 2),
            .init(function: "_jinit_color_deconverter", start: "0x26c78",
                  canonical_text_sha256: "551e15d6a6289a140b433e8dc7182c897c88328bc77552a113e7f05aacd67a46", input_rows: 331, cfg_blocks: 101),
            .init(function: "_null_convert", start: "0x27b30",
                  canonical_text_sha256: "b7dc27fc542d3209a1081c77dd6d20cdb7aa9ce1d0a8ab91dda564a1ee582800", input_rows: 84, cfg_blocks: 24),
            .init(function: "_j12init_color_deconverter", start: "0x2893c",
                  canonical_text_sha256: "0f71380a5b8705fbcbf00bb44224011229d52324992be053aad026519ba7a6fa", input_rows: 321, cfg_blocks: 98),
            .init(function: "_simple_upscale", start: "0x30134",
                  canonical_text_sha256: "fe9260f65433e5d43dd758f2a7ffa295f51fcd01bdc1c6ca7c6ffbcc7e4f5252", input_rows: 7, cfg_blocks: 2),
            .init(function: "_noscale", start: "0x30150",
                  canonical_text_sha256: "c140d113992c9100376e0eed27f6a918f8c2b1424b83ddcd40d333603b431018", input_rows: 5, cfg_blocks: 2),
            .init(function: "_noscale", start: "0x30630",
                  canonical_text_sha256: "42f579cee6f35e04bc29412e87c504f2f4164d814c0cf0702ab82afbec0e4aa6", input_rows: 5, cfg_blocks: 2),
            .init(function: "_noscale", start: "0x30b10",
                  canonical_text_sha256: "0e34234616af822b102e51d823198c9be7f6de136176f8b41af33e158de5346e", input_rows: 5, cfg_blocks: 2),
            .init(function: "_skip_variable", start: "0x33418",
                  canonical_text_sha256: "48a8d34bdb719e8f630cb380f983a01a48fd739dc1a7febf1dee0abadb36bde9", input_rows: 58, cfg_blocks: 10),
            .init(function: "_jinit_upsampler", start: "0x3ae18",
                  canonical_text_sha256: "ef83ca5183a3b19954bfca97256608c17e61987141b6f3fea04f5084ffdb7bc3", input_rows: 216, cfg_blocks: 49),
            .init(function: "_j12init_upsampler", start: "0x3b774",
                  canonical_text_sha256: "24f2271ec1422b09c4c7c392d9ffa4c16d0d88721d22b610b35b8da838a20724", input_rows: 188, cfg_blocks: 43)
        ])
    static var resourceURL: URL {
        if let repo = ProcessInfo.processInfo.environment["PORTABLE_REPO"] {
            return URL(fileURLWithPath: repo).appendingPathComponent("MacScope/Tests/CoreTests/Fixtures/RegionalSchema2/39a734962/selected13.json")
        }
        return TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RegionalSchema2/39a734962/selected13.json")
    }
    static func prepare(function: String, start: UInt64) throws -> RegionalSchema2BuiltFixture.Prepared {
        try RegionalSchema2BuiltFixture.prepare(resource: resourceURL, binding: binding, function: function, start: start)
    }
    static func make(function: String, start: UInt64) throws -> RegionalSchema2BuiltFixture {
        try RegionalSchema2BuiltFixture.make(resource: resourceURL, binding: binding, function: function, start: start)
    }
}
