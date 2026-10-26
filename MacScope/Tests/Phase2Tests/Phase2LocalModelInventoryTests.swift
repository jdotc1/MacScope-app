import Foundation
import XCTest
@testable import MacScope

final class Phase2LocalModelInventoryTests: XCTestCase {
    func testEndpointCanonicalizesLoopbackAndComposesWithInferenceConfiguration() throws {
        let profileID = UUID(uuidString: "2F94A1DE-5654-4F8A-9E46-93A0900B2350")!
        let endpoint = try Phase2LocalProviderEndpoint(
            profileID: profileID,
            generation: 7,
            endpointOrigin: "http://127.0.0.1:1234/",
            requestTimeoutMilliseconds: 5_000,
            resourceTimeoutMilliseconds: 30_000
        )

        XCTAssertEqual(endpoint.endpointOrigin, "http://127.0.0.1:1234")

        let configuration = try Phase2AIProviderConfiguration(
            endpoint: endpoint,
            model: "publisher/exact-model-key@q4_k_m",
            maximumTokens: 2_048
        )
        XCTAssertEqual(configuration.endpoint, endpoint)
        XCTAssertEqual(configuration.profileID, profileID)
        XCTAssertEqual(configuration.generation, 7)
        XCTAssertEqual(configuration.endpointOrigin, "http://127.0.0.1:1234")
        XCTAssertEqual(configuration.model, "publisher/exact-model-key@q4_k_m")
        XCTAssertEqual(configuration.maximumTokens, 2_048)
        XCTAssertEqual(configuration.requestTimeoutMilliseconds, 5_000)
        XCTAssertEqual(configuration.resourceTimeoutMilliseconds, 30_000)
    }

    func testExistingInferenceConfigurationRetainsValidationPrecedence() throws {
        XCTAssertThrowsError(try Phase2AIProviderConfiguration(
            profileID: UUID(),
            generation: 1,
            endpointOrigin: "http://127.0.0.1:1234",
            model: "",
            maximumTokens: 2_048,
            requestTimeoutMilliseconds: 999,
            resourceTimeoutMilliseconds: 30_000
        )) { error in
            XCTAssertEqual(
                error as? Phase2AIProviderConfiguration.ValidationError,
                .invalidModel
            )
        }
    }

    func testEndpointRejectsInvalidLifecycleAndNetworkValues() throws {
        let profileID = UUID()
        XCTAssertThrowsError(try Phase2LocalProviderEndpoint(
            profileID: profileID,
            generation: 0,
            endpointOrigin: "http://127.0.0.1:1234",
            requestTimeoutMilliseconds: 5_000,
            resourceTimeoutMilliseconds: 30_000
        )) { error in
            XCTAssertEqual(error as? Phase2LocalProviderEndpoint.ValidationError, .invalidGeneration)
        }
        XCTAssertThrowsError(try Phase2LocalProviderEndpoint(
            profileID: profileID,
            generation: 1,
            endpointOrigin: "http://localhost:1234",
            requestTimeoutMilliseconds: 5_000,
            resourceTimeoutMilliseconds: 30_000
        )) { error in
            XCTAssertEqual(error as? Phase2LocalProviderEndpoint.ValidationError, .invalidEndpoint)
        }
        XCTAssertThrowsError(try Phase2LocalProviderEndpoint(
            profileID: profileID,
            generation: 1,
            endpointOrigin: "http://[::1]:1234",
            requestTimeoutMilliseconds: 999,
            resourceTimeoutMilliseconds: 30_000
        )) { error in
            XCTAssertEqual(error as? Phase2LocalProviderEndpoint.ValidationError, .invalidRequestTimeout)
        }
        XCTAssertThrowsError(try Phase2LocalProviderEndpoint(
            profileID: profileID,
            generation: 1,
            endpointOrigin: "http://[::1]:1234",
            requestTimeoutMilliseconds: 5_000,
            resourceTimeoutMilliseconds: 4_999
        )) { error in
            XCTAssertEqual(error as? Phase2LocalProviderEndpoint.ValidationError, .invalidResourceTimeout)
        }
    }

    func testInventoryPreservesExactModelAndLoadedInstanceIdentity() throws {
        let profileID = UUID(uuidString: "51E5AA0B-9626-472E-8468-AFAFDD42DB6D")!
        let model = Phase2LocalModelDescriptor(
            type: .language,
            publisher: "publisher",
            key: "publisher/model@q4_k_m",
            displayName: "Model Display Name",
            architecture: "architecture",
            quantization: .init(name: "Q4_K_M", bitsPerWeight: 4),
            sizeBytesOnDisk: 15_000_000_000,
            parameterCountDescription: "30B-A3B",
            maximumContextLength: 262_144,
            format: .gguf,
            capabilities: .init(
                supportsVision: false,
                trainedForToolUse: true,
                reasoning: .init(allowedOptions: [.off], defaultOption: .off)
            ),
            variants: ["publisher/model@q4_k_m"],
            providerSelectedVariant: "publisher/model@q4_k_m",
            loadedInstances: [
                .init(
                    id: "instance-for-model-q4",
                    configuration: .init(
                        effectiveContextLength: 32_768,
                        evaluationBatchSize: 512,
                        parallelPredictions: 1,
                        flashAttention: true,
                        expertCount: 8,
                        offloadsKVCacheToGPU: true
                    )
                ),
            ]
        )
        let inventory = try Phase2LocalModelInventory(
            profileID: profileID,
            generation: 4,
            models: [model]
        )

        XCTAssertEqual(inventory.profileID, profileID)
        XCTAssertEqual(inventory.generation, 4)
        XCTAssertEqual(inventory.models.first?.key, "publisher/model@q4_k_m")
        XCTAssertEqual(inventory.models.first?.loadedInstances.first?.id, "instance-for-model-q4")
        XCTAssertNotEqual(
            inventory.models.first?.key,
            inventory.models.first?.loadedInstances.first?.id
        )
        XCTAssertEqual(inventory.models.first?.sizeBytesOnDisk, 15_000_000_000)
        XCTAssertEqual(inventory.models.first?.maximumContextLength, 262_144)
        XCTAssertEqual(
            inventory.models.first?.loadedInstances.first?.configuration.effectiveContextLength,
            32_768
        )
        XCTAssertTrue(inventory.models.first?.isInferenceCandidate == true)
    }

    func testEmbeddingIsPreservedWithoutBecomingInferenceCandidate() throws {
        let embedding = Phase2LocalModelDescriptor(
            type: .embedding,
            publisher: "publisher",
            key: "publisher/embedding",
            displayName: "Embedding",
            architecture: nil,
            quantization: nil,
            sizeBytesOnDisk: 274_290_560,
            parameterCountDescription: nil,
            maximumContextLength: 2_048,
            format: .gguf,
            capabilities: nil,
            variants: [],
            providerSelectedVariant: nil,
            loadedInstances: []
        )
        let inventory = try Phase2LocalModelInventory(
            profileID: UUID(),
            generation: 1,
            models: [embedding]
        )

        XCTAssertEqual(inventory.models, [embedding])
        XCTAssertFalse(embedding.isInferenceCandidate)
    }

    func testInventoryRejectsDuplicateModelKeysAndInstanceIDs() throws {
        let instance = Phase2LocalModelLoadedInstance(
            id: "shared-instance",
            configuration: .init(effectiveContextLength: 4_096)
        )
        let first = makeModel(key: "publisher/first", instances: [instance])
        let duplicateKey = makeModel(key: "publisher/first", instances: [])
        XCTAssertThrowsError(try Phase2LocalModelInventory(
            profileID: UUID(),
            generation: 1,
            models: [first, duplicateKey]
        )) { error in
            XCTAssertEqual(
                error as? Phase2LocalModelInventory.ValidationError,
                .duplicateModelKey("publisher/first")
            )
        }

        let second = makeModel(key: "publisher/second", instances: [instance])
        XCTAssertThrowsError(try Phase2LocalModelInventory(
            profileID: UUID(),
            generation: 1,
            models: [first, second]
        )) { error in
            XCTAssertEqual(
                error as? Phase2LocalModelInventory.ValidationError,
                .duplicateLoadedInstanceID("shared-instance")
            )
        }
    }

    func testInventoryDeterministicallySortsModelsAndLoadedInstancesByExactIdentity() throws {
        let laterInstance = Phase2LocalModelLoadedInstance(
            id: "instance-é",
            configuration: .init(effectiveContextLength: 4_096)
        )
        let earlierInstance = Phase2LocalModelLoadedInstance(
            id: "instance-z",
            configuration: .init(effectiveContextLength: 8_192)
        )
        let laterModel = makeModel(
            key: "publisher/é-model",
            instances: [laterInstance, earlierInstance]
        )
        let earlierModel = makeModel(key: "publisher/z-model", instances: [])

        let inventory = try Phase2LocalModelInventory(
            profileID: UUID(),
            generation: 1,
            models: [laterModel, earlierModel]
        )

        XCTAssertEqual(
            inventory.models.map(\.key),
            ["publisher/z-model", "publisher/é-model"]
        )
        XCTAssertEqual(
            inventory.models[1].loadedInstances.map(\.id),
            ["instance-z", "instance-é"]
        )
    }

    func testAppCodecMapsOneStrictWireSnapshotWithoutChangingProviderFacts() throws {
        let endpoint = try Phase2LocalProviderEndpoint(
            profileID: UUID(uuidString: "DE46ECA6-C412-42C3-B71B-D9717F587217")!,
            generation: 9,
            endpointOrigin: "http://[::1]:1234",
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000
        )
        let requestID = UUID(uuidString: "A4665B43-E16B-42BB-A2ED-74295BB688D5")!
        let appCodec = Phase2AIWorkerModelDiscoveryAppCodec()
        let wireCodec = Phase2AIWorkerModelDiscoveryWireCodec()

        XCTAssertEqual(
            try wireCodec.decodeRequest(appCodec.encodeRequest(
                endpoint: endpoint,
                requestID: requestID
            )),
            .init(
                schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
                requestID: requestID,
                profileID: endpoint.profileID,
                generation: endpoint.generation,
                endpointOrigin: endpoint.endpointOrigin,
                requestTimeoutMilliseconds: endpoint.requestTimeoutMilliseconds,
                resourceTimeoutMilliseconds: endpoint.resourceTimeoutMilliseconds
            )
        )

        let reply = Phase2AIWorkerModelDiscoveryReply(
            schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
            requestID: requestID,
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            status: .success,
            inventory: .init(models: [appDiscoveryWireModel()])
        )
        let outcome = try appCodec.decodeReply(
            wireCodec.encodeReply(reply),
            expectedRequestID: requestID,
            endpoint: endpoint
        )
        guard case .success(let inventory) = outcome else {
            return XCTFail("expected a successful whole-snapshot inventory")
        }
        let model = try XCTUnwrap(inventory.models.first)
        XCTAssertEqual(inventory.profileID, endpoint.profileID)
        XCTAssertEqual(inventory.generation, endpoint.generation)
        XCTAssertEqual(model.key, "publisher/exact-key@q4")
        XCTAssertEqual(model.loadedInstances.first?.id, "runtime-instance")
        XCTAssertEqual(model.sizeBytesOnDisk, 15_000_000_000)
        XCTAssertEqual(model.maximumContextLength, 262_144)
        XCTAssertEqual(
            model.loadedInstances.first?.configuration.effectiveContextLength,
            32_768
        )
    }

    func testAppCodecRejectsStaleReplyIdentityAndGeneration() throws {
        let endpoint = try Phase2LocalProviderEndpoint(
            profileID: UUID(),
            generation: 3,
            endpointOrigin: "http://127.0.0.1:1234",
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000
        )
        let requestID = UUID()
        let wireCodec = Phase2AIWorkerModelDiscoveryWireCodec()
        let appCodec = Phase2AIWorkerModelDiscoveryAppCodec()

        for reply in [
            Phase2AIWorkerModelDiscoveryReply(
                schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
                requestID: UUID(),
                profileID: endpoint.profileID,
                generation: endpoint.generation,
                status: .success,
                inventory: .init(models: [])
            ),
            Phase2AIWorkerModelDiscoveryReply(
                schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
                requestID: requestID,
                profileID: UUID(),
                generation: endpoint.generation,
                status: .success,
                inventory: .init(models: [])
            ),
            Phase2AIWorkerModelDiscoveryReply(
                schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
                requestID: requestID,
                profileID: endpoint.profileID,
                generation: endpoint.generation + 1,
                status: .success,
                inventory: .init(models: [])
            ),
        ] {
            XCTAssertThrowsError(try appCodec.decodeReply(
                wireCodec.encodeReply(reply),
                expectedRequestID: requestID,
                endpoint: endpoint
            )) { error in
                XCTAssertEqual(
                    error as? Phase2AIWorkerModelDiscoveryAppCodecError,
                    .identityMismatch
                )
            }
        }
    }

    func testAppCodecPreservesClosedFailureStatusesWithoutInventory() throws {
        let endpoint = try Phase2LocalProviderEndpoint(
            profileID: UUID(),
            generation: 1,
            endpointOrigin: "http://127.0.0.1:1234",
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000
        )
        let requestID = UUID()
        let wireCodec = Phase2AIWorkerModelDiscoveryWireCodec()
        let appCodec = Phase2AIWorkerModelDiscoveryAppCodec()
        let pairs: [(Phase2AIWorkerModelDiscoveryReply.Status, Phase2LocalModelDiscoveryOutcome)] = [
            (.authenticationRequired, .authenticationRequired),
            (.unavailable, .unavailable),
            (.incompatible, .incompatible),
            (.cancelled, .cancelled),
        ]

        for (status, expected) in pairs {
            let data = try wireCodec.encodeReply(.init(
                schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
                requestID: requestID,
                profileID: endpoint.profileID,
                generation: endpoint.generation,
                status: status,
                inventory: nil
            ))
            XCTAssertEqual(
                try appCodec.decodeReply(
                    data,
                    expectedRequestID: requestID,
                    endpoint: endpoint
                ),
                expected
            )
        }
    }

    private func makeModel(
        key: String,
        instances: [Phase2LocalModelLoadedInstance]
    ) -> Phase2LocalModelDescriptor {
        .init(
            type: .language,
            publisher: "publisher",
            key: key,
            displayName: key,
            architecture: nil,
            quantization: nil,
            sizeBytesOnDisk: 1,
            parameterCountDescription: nil,
            maximumContextLength: 4_096,
            format: nil,
            capabilities: nil,
            variants: [],
            providerSelectedVariant: nil,
            loadedInstances: instances
        )
    }
}

private func appDiscoveryWireModel() -> Phase2AIWorkerModelWire {
    .init(
        type: .llm,
        publisher: "publisher",
        key: "publisher/exact-key@q4",
        displayName: "Display Name",
        architecture: "qwen",
        quantization: .init(name: "Q4_K_M", bitsPerWeight: 4),
        sizeBytes: 15_000_000_000,
        parameters: "30B-A3B",
        loadedInstances: [
            .init(
                id: "runtime-instance",
                configuration: .init(
                    contextLength: 32_768,
                    evaluationBatchSize: 512,
                    parallelPredictions: 1,
                    flashAttention: true,
                    expertCount: 8,
                    offloadsKVCacheToGPU: true
                )
            ),
        ],
        maximumContextLength: 262_144,
        format: .gguf,
        capabilities: .init(
            vision: false,
            trainedForToolUse: true,
            reasoning: .init(allowedOptions: ["off"], defaultOption: "off")
        ),
        summary: "Provider summary",
        variants: ["publisher/exact-key@q4"],
        selectedVariant: "publisher/exact-key@q4"
    )
}
