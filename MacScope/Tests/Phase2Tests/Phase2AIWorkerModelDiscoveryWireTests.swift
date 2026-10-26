import Foundation
import XCTest

@testable import MacScope

final class Phase2AIWorkerModelDiscoveryWireTests: XCTestCase {
    func testQualityDiscoveryTimeoutBoundaryAndWireSymmetryPreserveLegacyBounds() throws {
        let codec = Phase2AIWorkerModelDiscoveryWireCodec()
        let policy = Phase2LocalInferencePolicy()
        let valid = discoveryRequest(requestTimeoutMilliseconds: 900_000,
            resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: policy)
        XCTAssertEqual(try codec.decodeRequest(codec.encodeRequest(valid)), valid)
        assertRequestInvalid(discoveryRequest(requestTimeoutMilliseconds: 900_001,
            resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: policy))
        assertRequestInvalid(discoveryRequest(requestTimeoutMilliseconds: 900_000,
            resourceTimeoutMilliseconds: 899_999, inferencePolicy: policy))
        assertRequestInvalid(discoveryRequest(requestTimeoutMilliseconds: 31_000))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: codec.encodeRequest(valid)) as? [String: Any])
        object["requestTimeoutMilliseconds"] = 900_001
        XCTAssertThrowsError(try codec.decodeRequest(JSONSerialization.data(withJSONObject: object)))
    }

    func testRequestAndSuccessfulInventoryRoundTripPreserveClosedAuthorityIdentity() throws {
        let codec = Phase2AIWorkerModelDiscoveryWireCodec()
        let request = discoveryRequest()
        let reply = discoveryReply(inventory: .init(models: [discoveryModel()]))

        let requestData = try codec.encodeRequest(request)
        let replyData = try codec.encodeReply(reply)

        XCTAssertEqual(try codec.decodeRequest(requestData), request)
        XCTAssertEqual(try codec.decodeReply(replyData), reply)
        XCTAssertEqual(
            try topLevelKeys(requestData),
            [
                "endpointOrigin", "generation", "profileID", "requestID",
                "requestTimeoutMilliseconds", "resourceTimeoutMilliseconds", "schemaVersion",
            ]
        )
        XCTAssertEqual(
            try topLevelKeys(replyData),
            ["generation", "inventory", "profileID", "requestID", "schemaVersion", "status"]
        )
    }

    func testRequestRejectsUnknownKeysNoncanonicalEndpointAndTimeoutBounds() throws {
        let codec = Phase2AIWorkerModelDiscoveryWireCodec()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: codec.encodeRequest(discoveryRequest()))
                as? [String: Any]
        )
        object["credential"] = "secret"
        assertWireError(try JSONSerialization.data(withJSONObject: object), decode: codec.decodeRequest)

        object.removeValue(forKey: "credential")
        object["schemaVersion"] = 2
        XCTAssertThrowsError(
            try codec.decodeRequest(try JSONSerialization.data(withJSONObject: object))
        ) { XCTAssertEqual($0 as? Phase2AIWorkerWireError, .unsupportedProtocolVersion(2)) }

        object["schemaVersion"] = 1
        object["requestID"] = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        assertWireError(try JSONSerialization.data(withJSONObject: object), decode: codec.decodeRequest)

        assertRequestInvalid(discoveryRequest(endpointOrigin: "http://localhost:1234"))
        assertRequestInvalid(discoveryRequest(endpointOrigin: "http://127.0.0.1:1234/path"))
        assertRequestInvalid(discoveryRequest(generation: 0))
        assertRequestInvalid(discoveryRequest(requestTimeoutMilliseconds: 999))
        assertRequestInvalid(discoveryRequest(requestTimeoutMilliseconds: 30_001))
        assertRequestInvalid(discoveryRequest(resourceTimeoutMilliseconds: 999))
        assertRequestInvalid(discoveryRequest(resourceTimeoutMilliseconds: 120_001))
        assertRequestInvalid(
            discoveryRequest(
                requestTimeoutMilliseconds: 20_000,
                resourceTimeoutMilliseconds: 19_999
            )
        )
        XCTAssertThrowsError(
            try codec.decodeRequest(Data(repeating: 0x20, count: 2_049))
        ) { XCTAssertEqual($0 as? Phase2AIWorkerWireError, .envelopeTooLarge) }
    }

    func testDecoderRejectsDuplicateAndUnknownNestedJSONKeys() throws {
        let codec = Phase2AIWorkerModelDiscoveryWireCodec()
        let duplicateRequest = Data(
            "{\"schemaVersion\":1,\"schemaVersion\":1,\"requestID\":\"00000000-0000-0000-0000-000000000001\",\"profileID\":\"00000000-0000-0000-0000-000000000002\",\"generation\":1,\"endpointOrigin\":\"http://127.0.0.1:1234\",\"requestTimeoutMilliseconds\":10000,\"resourceTimeoutMilliseconds\":60000}".utf8
        )
        assertWireError(duplicateRequest, decode: codec.decodeRequest)

        var reply = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: codec.encodeReply(discoveryReply())
            ) as? [String: Any]
        )
        var inventory = try XCTUnwrap(reply["inventory"] as? [String: Any])
        var models = try XCTUnwrap(inventory["models"] as? [[String: Any]])
        models[0]["providerPath"] = "/private/model"
        inventory["models"] = models
        reply["inventory"] = inventory
        assertWireError(
            try JSONSerialization.data(withJSONObject: reply),
            decode: codec.decodeReply
        )
    }

    func testDecoderRejectsFloatingLexemesForIntegerFields() throws {
        let codec = Phase2AIWorkerModelDiscoveryWireCodec()
        let requestText = try XCTUnwrap(
            String(data: codec.encodeRequest(discoveryRequest()), encoding: .utf8)
        )
        for replacement in ["1.0", "1e0"] {
            let mutated = requestText.replacingOccurrences(
                of: "\"generation\":1",
                with: "\"generation\":\(replacement)"
            )
            assertWireError(Data(mutated.utf8), decode: codec.decodeRequest)
        }

        let replyText = try XCTUnwrap(
            String(data: codec.encodeReply(discoveryReply()), encoding: .utf8)
        )
        for field in ["sizeBytes", "maximumContextLength", "contextLength"] {
            let pattern = try NSRegularExpression(pattern: "\\\"\(field)\\\":([0-9]+)")
            let range = NSRange(replyText.startIndex..., in: replyText)
            let mutated = pattern.stringByReplacingMatches(
                in: replyText,
                range: range,
                withTemplate: "\"\(field)\":$1.0"
            )
            assertWireError(Data(mutated.utf8), decode: codec.decodeReply)
        }
    }

    func testReplyStatusAndInventoryPresenceAreClosed() {
        let statuses: [Phase2AIWorkerModelDiscoveryReply.Status] = [
            .authenticationRequired, .unavailable, .incompatible, .cancelled,
        ]
        for status in statuses {
            assertReplyValid(discoveryReply(status: status, inventory: nil))
            assertReplyInvalid(discoveryReply(status: status, inventory: .init(models: [])))
        }
        assertReplyInvalid(discoveryReply(status: .success, inventory: nil))
        assertReplyValid(discoveryReply(status: .success, inventory: .init(models: [])))
    }

    func testCatalogRejectsDuplicateModelAndLoadedInstanceIdentifiers() {
        let model = discoveryModel()
        assertReplyInvalid(
            discoveryReply(inventory: .init(models: [model, model]))
        )

        let duplicateInstance = discoveryInstance()
        assertReplyInvalid(
            discoveryReply(inventory: .init(models: [
                discoveryModel(
                    loadedInstances: [duplicateInstance, duplicateInstance]
                ),
            ]))
        )
    }

    func testCatalogEnforcesEveryFrozenCollectionCeiling() {
        assertReplyValid(
            discoveryReply(inventory: .init(models: (0..<512).map {
                discoveryModel(key: "model-\($0)", loadedInstances: [])
            }))
        )
        assertReplyInvalid(
            discoveryReply(inventory: .init(models: (0..<513).map {
                discoveryModel(key: "model-\($0)", loadedInstances: [])
            }))
        )
        assertReplyInvalid(
            discoveryReply(inventory: .init(models: [
                discoveryModel(loadedInstances: (0..<33).map {
                    discoveryInstance(id: "instance-\($0)")
                }),
            ]))
        )
        assertReplyInvalid(
            discoveryReply(inventory: .init(models: [
                discoveryModel(variants: (0..<65).map { "variant-\($0)" }),
            ]))
        )
        assertReplyInvalid(
            discoveryReply(inventory: .init(models: [
                discoveryModel(reasoningOptions: (0..<65).map { "option-\($0)" }),
            ]))
        )
    }

    func testCatalogEnforcesIdentifierMetadataAndEnvelopeByteCeilings() throws {
        assertReplyInvalid(discoveryReply(inventory: .init(models: [
            discoveryModel(key: String(repeating: "k", count: 513)),
        ])))
        assertReplyInvalid(discoveryReply(inventory: .init(models: [
            discoveryModel(displayName: String(repeating: "n", count: 1_025)),
        ])))
        assertReplyInvalid(discoveryReply(inventory: .init(models: [
            discoveryModel(loadedInstances: [
                discoveryInstance(id: String(repeating: "i", count: 513)),
            ]),
        ])))

        XCTAssertThrowsError(
            try Phase2AIWorkerModelDiscoveryWireCodec().decodeReply(
                Data(repeating: 0x20, count: 2_097_153)
            )
        ) { XCTAssertEqual($0 as? Phase2AIWorkerWireError, .envelopeTooLarge) }
    }

    func testCatalogSplitsCompactAndDescriptiveStringBounds() {
        assertReplyValid(discoveryReply(inventory: .init(models: [
            discoveryModel(
                displayName: String(repeating: "d", count: 1_024),
                summary: String(repeating: "s", count: 1_024)
            ),
        ])))
        assertReplyInvalid(discoveryReply(inventory: .init(models: [
            discoveryModel(publisher: String(repeating: "p", count: 513)),
        ])))
        assertReplyInvalid(discoveryReply(inventory: .init(models: [
            discoveryModel(architecture: String(repeating: "a", count: 513)),
        ])))
        assertReplyInvalid(discoveryReply(inventory: .init(models: [
            discoveryModel(summary: String(repeating: "s", count: 1_025)),
        ])))
    }

    func testCatalogAcceptsDecoderValidEmbeddingCapabilitiesAndNullableMetadata() {
        assertReplyValid(discoveryReply(inventory: .init(models: [
            discoveryModel(
                type: .embedding,
                architecture: "",
                quantization: .init(name: nil, bitsPerWeight: nil),
                parameters: "",
                capabilities: .init(
                    vision: false,
                    trainedForToolUse: false,
                    reasoning: nil
                ),
                summary: "",
                variants: []
            ),
        ])))
        assertReplyValid(discoveryReply(inventory: .init(models: [
            discoveryModel(
                quantization: .init(name: "", bitsPerWeight: 0),
                variants: ["same", "same"]
            ),
        ])))
    }

    func testCatalogRejectsAggregateStringPayloadAboveOneMiB() {
        let large = String(repeating: "x", count: 1_024)
        let models = (0..<512).map { index in
            discoveryModel(
                key: "model-\(index)",
                displayName: large,
                loadedInstances: [],
                summary: large,
                variants: []
            )
        }

        assertReplyInvalid(discoveryReply(inventory: .init(models: models)))
    }

    func testFailureReplyContainsNoInventoryCredentialsPathsOrRawProviderError() throws {
        let codec = Phase2AIWorkerModelDiscoveryWireCodec()
        let data = try codec.encodeReply(
            discoveryReply(status: .authenticationRequired, inventory: nil)
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(
            try topLevelKeys(data),
            ["generation", "profileID", "requestID", "schemaVersion", "status"]
        )
        XCTAssertFalse(text.contains("credential"))
        XCTAssertFalse(text.contains("providerError"))
        XCTAssertFalse(text.contains("path"))
    }

    private func assertRequestInvalid(
        _ request: Phase2AIWorkerModelDiscoveryRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try Phase2AIWorkerModelDiscoveryWireCodec().encodeRequest(request),
            file: file,
            line: line
        )
    }

    private func assertReplyValid(
        _ reply: Phase2AIWorkerModelDiscoveryReply,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNoThrow(
            try Phase2AIWorkerModelDiscoveryWireCodec().decodeReply(
                try Phase2AIWorkerModelDiscoveryWireCodec().encodeReply(reply)
            ),
            file: file,
            line: line
        )
    }

    private func assertReplyInvalid(
        _ reply: Phase2AIWorkerModelDiscoveryReply,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try Phase2AIWorkerModelDiscoveryWireCodec().encodeReply(reply),
            file: file,
            line: line
        )
    }

    private func assertWireError<Value>(
        _ data: Data,
        decode: (Data) throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try decode(data), file: file, line: line)
    }

    private func topLevelKeys(_ data: Data) throws -> [String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
    }
}

private func discoveryRequest(
    generation: UInt64 = 1,
    endpointOrigin: String = "http://127.0.0.1:1234",
    requestTimeoutMilliseconds: Int = 10_000,
    resourceTimeoutMilliseconds: Int = 60_000,
    inferencePolicy: Phase2LocalInferencePolicy? = nil
) -> Phase2AIWorkerModelDiscoveryRequest {
    .init(
        schemaVersion: 1,
        requestID: discoveryID(1),
        profileID: discoveryID(2),
        generation: generation,
        endpointOrigin: endpointOrigin,
        requestTimeoutMilliseconds: requestTimeoutMilliseconds,
        resourceTimeoutMilliseconds: resourceTimeoutMilliseconds,
        inferencePolicy: inferencePolicy
    )
}

private func discoveryReply(
    status: Phase2AIWorkerModelDiscoveryReply.Status = .success,
    inventory: Phase2AIWorkerModelInventoryWire? = .init(models: [discoveryModel()])
) -> Phase2AIWorkerModelDiscoveryReply {
    .init(
        schemaVersion: 1,
        requestID: discoveryID(1),
        profileID: discoveryID(2),
        generation: 1,
        status: status,
        inventory: inventory
    )
}

private func discoveryModel(
    type: Phase2AIWorkerModelTypeWire = .llm,
    publisher: String = "publisher",
    key: String = "publisher/model",
    displayName: String = "Model",
    architecture: String? = "architecture",
    quantization: Phase2AIWorkerModelQuantizationWire? = .init(name: "Q4", bitsPerWeight: 4),
    parameters: String? = "7B",
    loadedInstances: [Phase2AIWorkerModelInstanceWire] = [discoveryInstance()],
    capabilities: Phase2AIWorkerModelCapabilitiesWire? = .init(
        vision: false,
        trainedForToolUse: true,
        reasoning: .init(allowedOptions: ["off", "on"], defaultOption: "off")
    ),
    summary: String? = "Local model",
    variants: [String] = ["publisher/model@q4"],
    reasoningOptions: [String] = ["off", "on"]
) -> Phase2AIWorkerModelWire {
    .init(
        type: type,
        publisher: publisher,
        key: key,
        displayName: displayName,
        architecture: architecture,
        quantization: quantization,
        sizeBytes: 1_000,
        parameters: parameters,
        loadedInstances: loadedInstances,
        maximumContextLength: 32_768,
        format: .gguf,
        capabilities: capabilities.map { value in
            .init(
                vision: value.vision,
                trainedForToolUse: value.trainedForToolUse,
                reasoning: value.reasoning == nil ? nil : .init(
                    allowedOptions: reasoningOptions,
                    defaultOption: reasoningOptions.first ?? "off"
                )
            )
        },
        summary: summary,
        variants: variants,
        selectedVariant: variants.first
    )
}

private func discoveryInstance(
    id: String = "publisher/model-instance"
) -> Phase2AIWorkerModelInstanceWire {
    .init(
        id: id,
        configuration: .init(
            contextLength: 4_096,
            evaluationBatchSize: 512,
            parallelPredictions: 1,
            flashAttention: true,
            expertCount: nil,
            offloadsKVCacheToGPU: true
        )
    )
}

private func discoveryID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}
