import Foundation
import XCTest

@testable import MacScope

final class Phase2NativeModelCatalogDecoderTests: XCTestCase {
    func testAcceptsEmptyCatalog() throws {
        let catalog = try Phase2NativeModelCatalogDecoder().decode(
            Data(#"{"models":[]}"#.utf8)
        )

        XCTAssertTrue(catalog.models.isEmpty)
    }

    func testDecodesCompleteCatalogPreservesBothKindsAndSortsDeterministically() throws {
        let data = Data(#"""
        {
          "models": [
            {
              "type": "embedding",
              "publisher": "gaianet",
              "key": "z/embed",
              "display_name": "Embed",
              "quantization": {"name":"F16","bits_per_weight":16},
              "size_bytes": 274290560,
              "params_string": null,
              "loaded_instances": [],
              "max_context_length": 2048,
              "format": "gguf",
              "unknown_additive_field": {"nested":true}
            },
            {
              "type": "llm",
              "publisher": "google",
              "key": "a/gemma",
              "display_name": "Gemma",
              "architecture": "gemma4",
              "quantization": {"name":"Q4_K_M","bits_per_weight":4},
              "size_bytes": 17990911801,
              "params_string": "26B-A4B",
              "loaded_instances": [
                {"id":"instance-z","config":{"context_length":8192,"parallel":4}},
                {"id":"instance-a","config":{"context_length":4096,"eval_batch_size":512,"flash_attention":true,"num_experts":8,"offload_kv_cache_to_gpu":true}}
              ],
              "max_context_length": 262144,
              "format": "mlx",
              "capabilities": {
                "vision": true,
                "trained_for_tool_use": true,
                "reasoning": {"allowed_options":["off","low","high"],"default":"low"}
              },
              "description": "A model",
              "variants": ["a/gemma@q4", "a/gemma@q8"],
              "selected_variant": "a/gemma@q4"
            }
          ]
        }
        """#.utf8)

        let catalog = try Phase2NativeModelCatalogDecoder().decode(data)

        XCTAssertEqual(catalog.models.map(\.key), ["a/gemma", "z/embed"])
        XCTAssertEqual(catalog.models[0].kind, .llm)
        XCTAssertTrue(catalog.models[0].isChatCompletionsEligible)
        XCTAssertEqual(catalog.models[0].publisher, "google")
        XCTAssertEqual(catalog.models[0].displayName, "Gemma")
        XCTAssertEqual(catalog.models[0].architecture, "gemma4")
        XCTAssertEqual(catalog.models[0].quantization, .init(name: "Q4_K_M", bitsPerWeight: 4))
        XCTAssertEqual(catalog.models[0].sizeBytes, 17_990_911_801)
        XCTAssertEqual(catalog.models[0].parameters, "26B-A4B")
        XCTAssertEqual(catalog.models[0].loadedInstances.map(\.id), ["instance-a", "instance-z"])
        XCTAssertEqual(
            catalog.models[0].loadedInstances[0].configuration,
            .init(
                contextLength: 4_096,
                evaluationBatchSize: 512,
                parallelPredictions: nil,
                flashAttention: true,
                expertCount: 8,
                offloadsKVCacheToGPU: true
            )
        )
        XCTAssertEqual(catalog.models[0].maximumContextLength, 262_144)
        XCTAssertEqual(catalog.models[0].format, .mlx)
        XCTAssertEqual(
            catalog.models[0].capabilities,
            .init(
                supportsVision: true,
                trainedForToolUse: true,
                reasoning: .init(allowedOptions: [.off, .low, .high], defaultOption: .low)
            )
        )
        XCTAssertEqual(catalog.models[0].description, "A model")
        XCTAssertEqual(catalog.models[0].variants, ["a/gemma@q4", "a/gemma@q8"])
        XCTAssertEqual(catalog.models[0].selectedVariant, "a/gemma@q4")
        XCTAssertEqual(catalog.models[1].kind, .embedding)
        XCTAssertFalse(catalog.models[1].isChatCompletionsEligible)
    }

    func testRejectsMalformedTrailingInvalidUTF8AndDuplicateKeysAtAnyDepth() {
        let invalid: [Data] = [
            Data(#"{"models":[]"#.utf8),
            Data(#"{"models":[]} trailing"#.utf8),
            Data([0x7B, 0x22, 0x6D, 0x6F, 0x64, 0x65, 0x6C, 0x73, 0x22, 0x3A, 0x5B, 0xFF, 0x5D, 0x7D]),
            Data(#"{"models":[],"models":[]}"#.utf8),
            Data(validCatalog(extraModelFields: #", "display_name":"two""#).utf8),
            Data(validCatalog(instance: #"{"id":"one","id":"two","config":{"context_length":1}}"#).utf8),
            Data(validCatalog(instance: #"{"id":"one","config":{"context_length":1,"context_length":2}}"#).utf8),
            Data(validCatalog(extraModelFields: #","unknown":{"nested":1,"nested":2}"#).utf8),
        ]

        for data in invalid {
            XCTAssertThrowsError(try Phase2NativeModelCatalogDecoder().decode(data))
        }
    }

    func testRejectsDuplicateModelKeysAndInstanceIDs() {
        let model = validModel()
        let duplicateModels = "{\"models\":[\(model),\(model)]}"
        let duplicateInstances = validCatalog(instances: [
            #"{"id":"same","config":{"context_length":1}}"#,
            #"{"id":"same","config":{"context_length":1}}"#,
        ])

        XCTAssertThrowsError(try Phase2NativeModelCatalogDecoder().decode(Data(duplicateModels.utf8)))
        XCTAssertThrowsError(try Phase2NativeModelCatalogDecoder().decode(Data(duplicateInstances.utf8)))
    }

    func testRejectsWrongRequiredTypesEnumsNumbersAndContextBounds() {
        let invalid = [
            #"{"models":{}}"#,
            replacing(in: validCatalog(), #""type":"llm""#, with: #""type":"vision""#),
            replacing(in: validCatalog(), #""publisher":"publisher""#, with: #""publisher":1"#),
            replacing(in: validCatalog(), #""format":"gguf""#, with: #""format":"safetensors""#),
            replacing(in: validCatalog(), #""size_bytes":1"#, with: #""size_bytes":-1"#),
            replacing(in: validCatalog(), #""max_context_length":4096"#, with: #""max_context_length":0"#),
            validCatalog(instance: #"{"id":"one","config":{"context_length":0}}"#),
            validCatalog(instance: #"{"id":"one","config":{"context_length":4097}}"#),
            validCatalog(extraModelFields: #","capabilities":{"vision":true,"trained_for_tool_use":true,"reasoning":{"allowed_options":["turbo"],"default":"turbo"}}"#),
        ]

        for json in invalid {
            XCTAssertThrowsError(try Phase2NativeModelCatalogDecoder().decode(Data(json.utf8)), "Accepted \(json)")
        }
    }

    func testRejectsFloatingAndExponentSpellingsAtEveryKnownIntegerPath() {
        let integerFields: [(json: String, token: String)] = [
            (validCatalog(), #""size_bytes":1"#),
            (validCatalog(), #""max_context_length":4096"#),
            (validCatalog(instance: #"{"id":"one","config":{"context_length":11}}"#), #""context_length":11"#),
            (validCatalog(instance: #"{"id":"one","config":{"context_length":1,"eval_batch_size":12}}"#), #""eval_batch_size":12"#),
            (validCatalog(instance: #"{"id":"one","config":{"context_length":1,"parallel":13}}"#), #""parallel":13"#),
            (validCatalog(instance: #"{"id":"one","config":{"context_length":1,"num_experts":14}}"#), #""num_experts":14"#),
        ]

        for field in integerFields {
            let prefix = String(field.token.dropLast(1))
            for nonIntegerLexeme in ["1.0", "1e0"] {
                let json = replacing(in: field.json, field.token, with: prefix + nonIntegerLexeme)
                XCTAssertThrowsError(
                    try Phase2NativeModelCatalogDecoder().decode(Data(json.utf8)),
                    "Accepted non-integer spelling at \(field.token): \(nonIntegerLexeme)"
                )
            }
        }
    }

    func testAllowsFloatingAndExponentNumbersInUnknownAdditiveFields() throws {
        let data = Data(validCatalog(extraModelFields: #", "future_fraction":1.5, "future_exponent":1e3, "future_nested":{"size_bytes":2.5,"config":{"parallel":3e1}}"#).utf8)

        let catalog = try Phase2NativeModelCatalogDecoder().decode(data)

        XCTAssertEqual(catalog.models.map(\.key), ["model"])
    }

    func testRejectsExcessivelyNestedUnknownAdditiveFields() {
        let depth = 33
        let nested = String(repeating: "[", count: depth)
            + "null"
            + String(repeating: "]", count: depth)
        let json = validCatalog(extraModelFields: ",\"future\":\(nested)")

        XCTAssertThrowsError(
            try Phase2NativeModelCatalogDecoder().decode(Data(json.utf8))
        )
    }

    func testEnforcesEnvelopeCollectionAndStringBudgets() throws {
        let decoder = Phase2NativeModelCatalogDecoder()
        XCTAssertThrowsError(try decoder.decode(Data(repeating: 0x20, count: 2 * 1_024 * 1_024 + 1)))

        let tooManyModels = Array(repeating: validModel(), count: 513).joined(separator: ",")
        XCTAssertThrowsError(try decoder.decode(Data("{\"models\":[\(tooManyModels)]}".utf8)))

        let instances = (0..<33).map { "{\"id\":\"i\($0)\",\"config\":{\"context_length\":1}}" }
        XCTAssertThrowsError(try decoder.decode(Data(validCatalog(instances: instances).utf8)))

        let longKey = String(repeating: "é", count: 257)
        let longDisplayName = String(repeating: "é", count: 513)
        XCTAssertThrowsError(try decoder.decode(Data(replacing(in: validCatalog(), #""key":"model""#, with: "\"key\":\"\(longKey)\"").utf8)))
        XCTAssertThrowsError(try decoder.decode(Data(replacing(in: validCatalog(), #""display_name":"Model""#, with: "\"display_name\":\"\(longDisplayName)\"").utf8)))

        let variants = Array(repeating: #""variant""#, count: 65).joined(separator: ",")
        XCTAssertThrowsError(try decoder.decode(Data(validCatalog(extraModelFields: ", \"variants\":[\(variants)]").utf8)))

        let options = Array(repeating: #""off""#, count: 65).joined(separator: ",")
        XCTAssertThrowsError(try decoder.decode(Data(validCatalog(extraModelFields: ", \"capabilities\":{\"vision\":false,\"trained_for_tool_use\":false,\"reasoning\":{\"allowed_options\":[\(options)],\"default\":\"off\"}}").utf8)))

        let large = String(repeating: "x", count: 1_024)
        let manyModels = (0..<512).map { index in
            validModel(key: "model-\(index)", displayName: large, description: large)
        }.joined(separator: ",")
        XCTAssertThrowsError(try decoder.decode(Data("{\"models\":[\(manyModels)]}".utf8)))
    }
}

private func validCatalog(
    instance: String? = nil,
    instances: [String]? = nil,
    extraModelFields: String = ""
) -> String {
    let resolvedInstances = instances ?? instance.map { [$0] } ?? []
    return "{\"models\":[\(validModel(instances: resolvedInstances, extraFields: extraModelFields))]}"
}

private func validModel(
    key: String = "model",
    displayName: String = "Model",
    description: String? = nil,
    instances: [String] = [],
    extraFields: String = ""
) -> String {
    let descriptionField = description.map { ",\"description\":\"\($0)\"" } ?? ""
    let joinedInstances = instances.joined(separator: ",")
    return "{\"type\":\"llm\",\"publisher\":\"publisher\",\"key\":\"\(key)\",\"display_name\":\"\(displayName)\",\"quantization\":null,\"size_bytes\":1,\"params_string\":null,\"loaded_instances\":[\(joinedInstances)],\"max_context_length\":4096,\"format\":\"gguf\"\(descriptionField)\(extraFields)}"
}

private func replacing(in source: String, _ target: String, with replacement: String) -> String {
    source.replacingOccurrences(of: target, with: replacement)
}
