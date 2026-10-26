import XCTest
@testable import MacScope

final class Phase2LocalAISelectionTests: XCTestCase {
    func testAuthorizeCapturesExactEndpointAndModelKeyWithoutUsingInstanceIdentity() throws {
        let endpoint = try makeEndpoint()
        let model = makeModel(
            key: "publisher/model",
            maximumContextLength: 16_384,
            instances: [makeInstance(id: "runtime-instance-1")]
        )
        let inventory = try makeInventory(endpoint: endpoint, models: [model])

        let selection = try Phase2LocalAISelection.authorize(
            endpoint: endpoint,
            inventory: inventory,
            modelKey: model.key,
            maximumTokens: 8_192
        )

        XCTAssertEqual(selection.profileID, endpoint.profileID)
        XCTAssertEqual(selection.generation, endpoint.generation)
        XCTAssertEqual(selection.modelKey, "publisher/model")
        XCTAssertEqual(selection.maximumTokens, 8_192)
        XCTAssertEqual(selection.configuration.endpoint, endpoint)
        XCTAssertEqual(selection.configuration.model, "publisher/model")
        XCTAssertNotEqual(selection.configuration.model, "runtime-instance-1")
    }

    func testAuthorizeRejectsProfileAndGenerationMismatches() throws {
        let endpoint = try makeEndpoint(generation: 7)
        let model = makeModel()
        let wrongProfile = try Phase2LocalModelInventory(
            profileID: UUID(),
            generation: endpoint.generation,
            models: [model]
        )
        let wrongGeneration = try Phase2LocalModelInventory(
            profileID: endpoint.profileID,
            generation: endpoint.generation + 1,
            models: [model]
        )

        for inventory in [wrongProfile, wrongGeneration] {
            XCTAssertThrowsError(try Phase2LocalAISelection.authorize(
                endpoint: endpoint,
                inventory: inventory,
                modelKey: model.key,
                maximumTokens: 256
            )) {
                XCTAssertEqual(
                    $0 as? Phase2LocalAISelectionValidationError,
                    .inventoryIdentityMismatch
                )
            }
        }
    }

    func testAuthorizeRejectsMissingAndEmbeddingModels() throws {
        let endpoint = try makeEndpoint()
        let languageInventory = try makeInventory(
            endpoint: endpoint,
            models: [makeModel(key: "language")]
        )
        XCTAssertThrowsError(try Phase2LocalAISelection.authorize(
            endpoint: endpoint,
            inventory: languageInventory,
            modelKey: "missing",
            maximumTokens: 1
        )) {
            XCTAssertEqual($0 as? Phase2LocalAISelectionValidationError, .modelMissing)
        }

        let embeddingInventory = try makeInventory(
            endpoint: endpoint,
            models: [makeModel(type: .embedding, key: "embedding")]
        )
        XCTAssertThrowsError(try Phase2LocalAISelection.authorize(
            endpoint: endpoint,
            inventory: embeddingInventory,
            modelKey: "embedding",
            maximumTokens: 1
        )) {
            XCTAssertEqual($0 as? Phase2LocalAISelectionValidationError, .modelNotLanguage)
        }
    }

    func testAuthorizeBoundsMaximumTokensByDescriptorAndGlobalCap() throws {
        let endpoint = try makeEndpoint()
        let inventory = try makeInventory(endpoint: endpoint, models: [
            makeModel(key: "small", maximumContextLength: 1_024),
            makeModel(key: "large", maximumContextLength: 32_768),
        ])

        XCTAssertNoThrow(try Phase2LocalAISelection.authorize(
            endpoint: endpoint,
            inventory: inventory,
            modelKey: "small",
            maximumTokens: 1_024
        ))
        XCTAssertNoThrow(try Phase2LocalAISelection.authorize(
            endpoint: endpoint,
            inventory: inventory,
            modelKey: "large",
            maximumTokens: 8_192
        ))

        for candidate in [0, 1_025] {
            XCTAssertThrowsError(try Phase2LocalAISelection.authorize(
                endpoint: endpoint,
                inventory: inventory,
                modelKey: "small",
                maximumTokens: candidate
            )) {
                XCTAssertEqual(
                    $0 as? Phase2LocalAISelectionValidationError,
                    .invalidMaximumTokens
                )
            }
        }
        XCTAssertThrowsError(try Phase2LocalAISelection.authorize(
            endpoint: endpoint,
            inventory: inventory,
            modelKey: "large",
            maximumTokens: 8_193
        )) {
            XCTAssertEqual($0 as? Phase2LocalAISelectionValidationError, .invalidMaximumTokens)
        }
    }

    func testAuthorizeFailsClosedForNonpositiveDescriptorContext() throws {
        let endpoint = try makeEndpoint()

        for maximumContextLength in [0, -1] {
            let inventory = try makeInventory(
                endpoint: endpoint,
                models: [makeModel(
                    key: "invalid-context",
                    maximumContextLength: maximumContextLength
                )]
            )

            XCTAssertThrowsError(try Phase2LocalAISelection.authorize(
                endpoint: endpoint,
                inventory: inventory,
                modelKey: "invalid-context",
                maximumTokens: 1
            )) {
                XCTAssertEqual(
                    $0 as? Phase2LocalAISelectionValidationError,
                    .invalidMaximumTokens
                )
            }
        }
    }

    func testSnapshotProjectsEndpointAndProviderObservationConditionsExactly() throws {
        let endpoint = try makeEndpoint()
        XCTAssertEqual(Phase2LocalAIProviderSnapshot().readiness, .endpointMissing)

        let pairs: [(Phase2LocalAIProviderObservation, Phase2LocalAIProviderReadiness)] = [
            (.inventoryRequired, .inventoryRequired),
            (.authenticationRequired, .authenticationRequired),
            (.unavailable, .unavailable),
            (.incompatible, .incompatible),
            (.reconciliationRequired, .reconciliationRequired),
        ]
        for (observation, expected) in pairs {
            let snapshot = Phase2LocalAIProviderSnapshot(
                endpoint: endpoint,
                observation: observation
            )
            XCTAssertEqual(snapshot.readiness, expected)
            XCTAssertNil(snapshot.inventory)
        }

        let inventory = try makeInventory(endpoint: endpoint, models: [makeModel()])
        let accepted = Phase2LocalAIProviderSnapshot(
            endpoint: endpoint,
            observation: .accepted(inventory)
        )
        XCTAssertEqual(accepted.inventory, inventory)
        XCTAssertEqual(accepted.readiness, .selectionRequired)
    }

    func testSnapshotFailsClosedForStaleAcceptedInventory() throws {
        let endpoint = try makeEndpoint(generation: 4)
        let stale = try Phase2LocalModelInventory(
            profileID: endpoint.profileID,
            generation: 3,
            models: [makeModel()]
        )
        let snapshot = Phase2LocalAIProviderSnapshot(
            endpoint: endpoint,
            observation: .accepted(stale)
        )

        XCTAssertEqual(snapshot.readiness, .inventoryRequired)
    }

    func testUnloadedSelectionRequiresLoadAndLoadedSelectionIsReady() throws {
        let endpoint = try makeEndpoint()
        let unloadedInventory = try makeInventory(
            endpoint: endpoint,
            models: [makeModel(key: "chosen")]
        )
        let selection = try Phase2LocalAISelection.authorize(
            endpoint: endpoint,
            inventory: unloadedInventory,
            modelKey: "chosen",
            maximumTokens: 2_048
        )
        let unloaded = Phase2LocalAIProviderSnapshot(
            endpoint: endpoint,
            observation: .accepted(unloadedInventory),
            selection: selection
        )
        XCTAssertEqual(unloaded.readiness, .loadRequired(modelKey: "chosen"))

        let loadedInventory = try makeInventory(endpoint: endpoint, models: [
            makeModel(
                key: "chosen",
                instances: [makeInstance(id: "one"), makeInstance(id: "two")]
            ),
        ])
        let loaded = Phase2LocalAIProviderSnapshot(
            endpoint: endpoint,
            observation: .accepted(loadedInventory),
            selection: selection
        )
        XCTAssertEqual(loaded.readiness, .ready(selection.configuration))
    }

    func testSnapshotRejectsSelectionFromAnotherEndpointGeneration() throws {
        let oldEndpoint = try makeEndpoint(generation: 1)
        let oldInventory = try makeInventory(
            endpoint: oldEndpoint,
            models: [makeModel(key: "chosen")]
        )
        let selection = try Phase2LocalAISelection.authorize(
            endpoint: oldEndpoint,
            inventory: oldInventory,
            modelKey: "chosen",
            maximumTokens: 128
        )
        let newEndpoint = try makeEndpoint(
            profileID: oldEndpoint.profileID,
            generation: 2
        )
        let newInventory = try makeInventory(
            endpoint: newEndpoint,
            models: [makeModel(key: "chosen", instances: [makeInstance()])]
        )

        let snapshot = Phase2LocalAIProviderSnapshot(
            endpoint: newEndpoint,
            observation: .accepted(newInventory),
            selection: selection
        )
        XCTAssertEqual(snapshot.readiness, .selectionIdentityMismatch)
    }

    func testSnapshotFailsClosedWhenSelectedModelDisappearsOrChangesType() throws {
        let endpoint = try makeEndpoint()
        let original = try makeInventory(
            endpoint: endpoint,
            models: [makeModel(key: "chosen")]
        )
        let selection = try Phase2LocalAISelection.authorize(
            endpoint: endpoint,
            inventory: original,
            modelKey: "chosen",
            maximumTokens: 128
        )

        let missing = try makeInventory(
            endpoint: endpoint,
            models: [makeModel(key: "other")]
        )
        XCTAssertEqual(
            Phase2LocalAIProviderSnapshot(
                endpoint: endpoint,
                observation: .accepted(missing),
                selection: selection
            ).readiness,
            .selectedModelMissing
        )

        let embedding = try makeInventory(endpoint: endpoint, models: [
            makeModel(type: .embedding, key: "chosen", instances: [makeInstance()]),
        ])
        XCTAssertEqual(
            Phase2LocalAIProviderSnapshot(
                endpoint: endpoint,
                observation: .accepted(embedding),
                selection: selection
            ).readiness,
            .selectedModelNotLanguage
        )
    }

    func testMetadataOnlyInventoryRefreshPreservesSelectionAndConfiguration() throws {
        let endpoint = try makeEndpoint()
        let initial = try makeInventory(
            endpoint: endpoint,
            models: [makeModel(key: "chosen", displayName: "Before")]
        )
        let selection = try Phase2LocalAISelection.authorize(
            endpoint: endpoint,
            inventory: initial,
            modelKey: "chosen",
            maximumTokens: 512
        )
        let refreshed = try makeInventory(endpoint: endpoint, models: [
            makeModel(
                key: "chosen",
                displayName: "After",
                instances: [makeInstance(id: "fresh-runtime-instance")]
            ),
        ])

        let snapshot = Phase2LocalAIProviderSnapshot(
            endpoint: endpoint,
            observation: .accepted(refreshed),
            selection: selection
        )
        XCTAssertEqual(snapshot.selection, selection)
        XCTAssertEqual(snapshot.readiness, .ready(selection.configuration))
    }

    func testContextCapabilityDriftInvalidatesReadiness() throws {
        let endpoint = try makeEndpoint()
        let initial = try makeInventory(
            endpoint: endpoint,
            models: [makeModel(key: "chosen", maximumContextLength: 4_096)]
        )
        let selection = try Phase2LocalAISelection.authorize(
            endpoint: endpoint,
            inventory: initial,
            modelKey: "chosen",
            maximumTokens: 4_096
        )
        let reduced = try makeInventory(endpoint: endpoint, models: [
            makeModel(
                key: "chosen",
                maximumContextLength: 2_048,
                instances: [makeInstance()]
            ),
        ])

        let snapshot = Phase2LocalAIProviderSnapshot(
            endpoint: endpoint,
            observation: .accepted(reduced),
            selection: selection
        )
        XCTAssertEqual(snapshot.readiness, .selectionIdentityMismatch)
    }

    func testNonpositiveContextDriftInvalidatesReadinessWithoutTrapping() throws {
        let endpoint = try makeEndpoint()
        let initial = try makeInventory(
            endpoint: endpoint,
            models: [makeModel(key: "chosen", maximumContextLength: 4_096)]
        )
        let selection = try Phase2LocalAISelection.authorize(
            endpoint: endpoint,
            inventory: initial,
            modelKey: "chosen",
            maximumTokens: 1
        )

        for maximumContextLength in [0, -1] {
            let invalid = try makeInventory(endpoint: endpoint, models: [
                makeModel(
                    key: "chosen",
                    maximumContextLength: maximumContextLength,
                    instances: [makeInstance()]
                ),
            ])
            let snapshot = Phase2LocalAIProviderSnapshot(
                endpoint: endpoint,
                observation: .accepted(invalid),
                selection: selection
            )
            XCTAssertEqual(snapshot.readiness, .selectionIdentityMismatch)
        }
    }

    func testActivityBusyProjectionIsClosedAndDeterministic() {
        XCTAssertFalse(Phase2LocalAIProviderActivity.idle.isBusy)
        XCTAssertTrue(Phase2LocalAIProviderActivity.discovering(requestID: UUID()).isBusy)
        XCTAssertTrue(Phase2LocalAIProviderActivity.performingLifecycle(effectID: UUID()).isBusy)
    }

    private func makeEndpoint(
        profileID: UUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        generation: UInt64 = 1
    ) throws -> Phase2LocalProviderEndpoint {
        try Phase2LocalProviderEndpoint(
            profileID: profileID,
            generation: generation,
            endpointOrigin: "http://127.0.0.1:1234",
            requestTimeoutMilliseconds: 5_000,
            resourceTimeoutMilliseconds: 30_000
        )
    }

    private func makeInventory(
        endpoint: Phase2LocalProviderEndpoint,
        models: [Phase2LocalModelDescriptor]
    ) throws -> Phase2LocalModelInventory {
        try Phase2LocalModelInventory(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: models
        )
    }

    private func makeModel(
        type: Phase2LocalModelType = .language,
        key: String = "model",
        displayName: String = "Model",
        maximumContextLength: Int = 16_384,
        instances: [Phase2LocalModelLoadedInstance] = []
    ) -> Phase2LocalModelDescriptor {
        Phase2LocalModelDescriptor(
            type: type,
            publisher: "Publisher",
            key: key,
            displayName: displayName,
            architecture: "arm64",
            quantization: nil,
            sizeBytesOnDisk: 1_024,
            parameterCountDescription: "1B",
            maximumContextLength: maximumContextLength,
            format: .gguf,
            capabilities: nil,
            summary: nil,
            variants: [],
            providerSelectedVariant: nil,
            loadedInstances: instances
        )
    }

    private func makeInstance(
        id: String = "runtime-instance"
    ) -> Phase2LocalModelLoadedInstance {
        Phase2LocalModelLoadedInstance(
            id: id,
            configuration: Phase2LocalModelInstanceConfiguration(
                effectiveContextLength: 4_096
            )
        )
    }
}
