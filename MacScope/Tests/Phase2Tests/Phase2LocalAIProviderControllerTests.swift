import XCTest

@testable import MacScope

@MainActor
final class Phase2LocalAIProviderControllerTests: XCTestCase {
    func testLegacyStoredProfileStaysInertAndDoesNotFallThroughToProductDefault() async throws {
        let legacy = try Phase2LocalAIProviderPreference(endpointOrigin: "http://127.0.0.1:1234",
            requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 60_000,
            desiredSelection: .init(modelKey: "legacy-model", maximumTokens: 512))
        let preferences = RecordingControllerPreferenceStore(initialPreference: legacy)
        let discovery = ControllerDiscoveryProbe()
        let lifecycle = ControllerLifecycleProbe()
        let controller = Phase2LocalAIProviderController(endpoint: nil, discovery: discovery,
            lifecycle: lifecycle, preferenceStore: preferences, defaultPreference: try .mtplxQualityDefault())
        XCTAssertNil(controller.snapshot.endpoint)
        XCTAssertNil(controller.captureReadyInferenceLease())
        XCTAssertTrue(controller.hasUnsupportedProviderConfiguration)
        XCTAssertEqual(controller.snapshot.observation, .incompatible)
        XCTAssertEqual(preferences.storedPreference, legacy)
        controller.clearSelection()
        XCTAssertEqual(preferences.storedPreference, legacy, "Selection cleanup cannot retire a stored unsupported profile")
        XCTAssertEqual(preferences.saveCount, 0)
        XCTAssertEqual(preferences.clearCount, 0)
        let discoveryCalls = await discovery.callCount
        let lifecycleCalls = await lifecycle.callCount
        XCTAssertEqual(discoveryCalls, 0)
        XCTAssertEqual(lifecycleCalls, 0)
        try await controller.applyEndpoint(origin: "http://127.0.0.1:8000",
            requestTimeoutMilliseconds: 300_000, resourceTimeoutMilliseconds: 1_800_000,
            inferencePolicy: .init())
        XCTAssertFalse(controller.hasUnsupportedProviderConfiguration)
        XCTAssertEqual(controller.snapshot.endpoint?.providerKind, .mtplx)
        XCTAssertNil(controller.snapshot.desiredSelection, "Legacy model is never migrated into MTPLX")
        XCTAssertEqual(preferences.saveCount, 1)
    }

    func testAbsentPreferenceUsesExplicitMTPLXDefaultButNilPolicyApplyIsRejected() async throws {
        let preferences = RecordingControllerPreferenceStore(initialPreference: nil)
        let controller = Phase2LocalAIProviderController(endpoint: nil, discovery: ControllerDiscoveryProbe(),
            lifecycle: ControllerLifecycleProbe(), preferenceStore: preferences,
            defaultPreference: try .mtplxQualityDefault())
        let original = try XCTUnwrap(controller.snapshot.endpoint)
        XCTAssertEqual(original.providerKind, .mtplx)
        XCTAssertEqual(original.endpointOrigin, "http://127.0.0.1:8000")
        XCTAssertEqual(controller.snapshot.readiness, .inventoryRequired)
        XCTAssertFalse(controller.hasUnsupportedProviderConfiguration)
        for policy in [nil, Phase2LocalInferencePolicy(provider: .lmStudio)] {
            do {
                try await controller.applyEndpoint(origin: "http://127.0.0.1:1234",
                    requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 60_000,
                    inferencePolicy: policy)
                XCTFail("Unsupported policy cannot replace current endpoint")
            } catch { XCTAssertEqual(error as? Phase2LocalAIProviderControllerError, .unsupportedProvider) }
        }
        XCTAssertEqual(controller.snapshot.endpoint, original)
        XCTAssertEqual(preferences.saveCount, 0)
    }

    func testMTPLXManagementIsUnavailableWithoutDispatchOrPreferenceMutation() async throws {
        let fixture = try ControllerFixture()
        await fixture.discovery.enqueue(.success(fixture.loadedInventory))
        _ = try await fixture.controller.refresh()
        try fixture.controller.select(modelKey: ControllerFixture.modelKey, maximumTokens: 512)
        let prior = fixture.controller.snapshot
        do {
            _ = try await fixture.controller.load(modelKey: ControllerFixture.modelKey, requestedContextLength: 32_768)
            XCTFail("MTPLX management is unsupported")
        } catch { XCTAssertEqual(error as? Phase2LocalAIProviderControllerError, .managementUnavailable) }
        do {
            _ = try await fixture.controller.unload(modelKey: ControllerFixture.modelKey, instanceID: ControllerFixture.instanceID)
            XCTFail("MTPLX management is unsupported")
        } catch { XCTAssertEqual(error as? Phase2LocalAIProviderControllerError, .managementUnavailable) }
        XCTAssertEqual(fixture.controller.snapshot, prior)
        let calls = await fixture.lifecycle.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(fixture.controller.ownedInstances.isEmpty)
    }
    func testProviderRevisionAdvancesForEveryPublicationIncludingEqualState() throws {
        let fixture = try ControllerFixture()
        let initial = fixture.controller.snapshot

        fixture.controller.clearSelection()
        let first = fixture.controller.snapshot
        fixture.controller.clearSelection()
        let second = fixture.controller.snapshot

        XCTAssertEqual(first.revision, initial.revision + 1)
        XCTAssertEqual(second.revision, first.revision + 1)
        XCTAssertEqual(first.endpoint, second.endpoint)
        XCTAssertEqual(first.observation, second.observation)
        XCTAssertEqual(first.desiredSelection, second.desiredSelection)
        XCTAssertEqual(first.selection, second.selection)
        XCTAssertEqual(first.activity, second.activity)
    }

    func testRefreshPublishesExactAcceptedInventoryAndClosedReadiness() async throws {
        let fixture = try ControllerFixture()
        await fixture.discovery.enqueue(.success(fixture.loadedInventory))

        let outcome = try await fixture.controller.refresh()

        XCTAssertEqual(outcome, .success(fixture.loadedInventory))
        XCTAssertEqual(fixture.controller.snapshot.inventory, fixture.loadedInventory)
        let adopted = try XCTUnwrap(fixture.controller.snapshot.selection,
            "The sole served chat model is selected without a saved choice")
        XCTAssertEqual(adopted.modelKey, ControllerFixture.modelKey)
        XCTAssertEqual(adopted.maximumTokens, Phase2LocalAIProviderController.adoptedMaximumTokens)
        XCTAssertEqual(fixture.controller.snapshot.readiness, .ready(adopted.configuration))
        XCTAssertEqual(fixture.controller.snapshot.activity, .idle)
        let callCount = await fixture.discovery.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testSoleServedChatModelIsAdoptedWhenTheSavedChoiceIsAbsentOrNotServed() async throws {
        let retired = try Phase2LocalAIDesiredSelection(modelKey: "publisher/retired-model", maximumTokens: 512)
        let cases: [(name: String, desired: Phase2LocalAIDesiredSelection?)] = [
            ("absent", nil), ("not served", retired),
        ]
        for testCase in cases {
            let preference = try Phase2LocalAIProviderPreference(endpointOrigin: "http://127.0.0.1:8000",
                requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 60_000,
                desiredSelection: testCase.desired, inferencePolicy: .init(effectiveContextTokens: 32_768))
            let store = RecordingControllerPreferenceStore(initialPreference: preference)
            let discovery = ControllerDiscoveryProbe()
            let controller = Phase2LocalAIProviderController(endpoint: nil, discovery: discovery,
                lifecycle: ControllerLifecycleProbe(), preferenceStore: store)
            let endpoint = try XCTUnwrap(controller.snapshot.endpoint, testCase.name)
            await discovery.enqueue(.success(try Phase2LocalModelInventory(
                profileID: endpoint.profileID, generation: endpoint.generation,
                models: [controllerModel(instances: [.init(id: ControllerFixture.instanceID,
                    configuration: ControllerFixture.configuration)])])))

            _ = try await controller.refresh()

            let selection = try XCTUnwrap(controller.snapshot.selection, testCase.name)
            XCTAssertEqual(selection.modelKey, ControllerFixture.modelKey, testCase.name)
            XCTAssertEqual(selection.maximumTokens,
                testCase.desired?.maximumTokens ?? Phase2LocalAIProviderController.adoptedMaximumTokens,
                testCase.name)
            XCTAssertEqual(controller.snapshot.readiness, .ready(selection.configuration), testCase.name)
            XCTAssertEqual(controller.snapshot.desiredSelection?.modelKey, ControllerFixture.modelKey, testCase.name)
            XCTAssertEqual(store.storedPreference?.desiredSelection?.modelKey, ControllerFixture.modelKey,
                testCase.name)
            XCTAssertEqual(store.saveCount, 1, testCase.name)
        }
    }

    func testSeveralServedChatModelsLeaveTheChoiceWithTheUser() async throws {
        let fixture = try ControllerFixture()
        let inventory = try Phase2LocalModelInventory(
            profileID: fixture.endpoint.profileID,
            generation: fixture.endpoint.generation,
            models: [
                controllerModel(instances: [.init(id: ControllerFixture.instanceID,
                    configuration: ControllerFixture.configuration)]),
                controllerModel(key: "publisher/second-model", instances: [.init(id: "second-instance",
                    configuration: ControllerFixture.configuration)]),
            ]
        )
        await fixture.discovery.enqueue(.success(inventory))

        _ = try await fixture.controller.refresh()

        XCTAssertNil(fixture.controller.snapshot.selection)
        XCTAssertNil(fixture.controller.snapshot.desiredSelection)
        XCTAssertEqual(fixture.controller.snapshot.readiness, .selectionRequired)
    }

    func testRefreshIfNotReadyDiscoversOnlyWhileTheAssistantIsNotReady() async throws {
        let fixture = try ControllerFixture()
        await fixture.discovery.enqueue(.success(fixture.loadedInventory))

        await fixture.controller.refreshIfNotReady()

        XCTAssertEqual(fixture.controller.snapshot.inventory, fixture.loadedInventory)
        guard case .ready = fixture.controller.snapshot.readiness else {
            return XCTFail("Opening the Assistant refreshes a stale inventory into readiness")
        }
        await fixture.controller.refreshIfNotReady()
        let callCount = await fixture.discovery.callCount
        XCTAssertEqual(callCount, 1, "A ready Assistant does not probe the provider again")
    }

    func testRefreshNormalizesIdentityMismatchedSuccessToIncompatible() async throws {
        let fixture = try ControllerFixture()
        let mismatched = try Phase2LocalModelInventory(
            profileID: UUID(),
            generation: fixture.endpoint.generation,
            models: fixture.loadedInventory.models
        )
        await fixture.discovery.enqueue(.success(mismatched))

        let outcome = try await fixture.controller.refresh()

        XCTAssertEqual(outcome, .incompatible)
        XCTAssertEqual(fixture.controller.snapshot.readiness, .incompatible)
        XCTAssertNil(fixture.controller.snapshot.inventory)
    }

    func testRefreshFailureCategoriesRemainDistinctAndPayloadFree() async throws {
        let cases: [(Phase2LocalModelDiscoveryOutcome, Phase2LocalAIProviderReadiness)] = [
            (.authenticationRequired, .authenticationRequired),
            (.unavailable, .unavailable),
            (.incompatible, .incompatible),
        ]
        for (outcome, expected) in cases {
            let fixture = try ControllerFixture()
            await fixture.discovery.enqueue(outcome)

            _ = try await fixture.controller.refresh()

            XCTAssertEqual(fixture.controller.snapshot.readiness, expected)
            XCTAssertNil(fixture.controller.snapshot.inventory)
        }
    }

    func testRefreshClassifiesCodecAndWireFailuresAsIncompatible() async throws {
        let codecFixture = try ControllerFixture()
        await codecFixture.discovery.enqueue(
            error: Phase2AIWorkerModelDiscoveryAppCodecError.identityMismatch
        )

        _ = try? await codecFixture.controller.refresh()

        XCTAssertEqual(codecFixture.controller.snapshot.readiness, .incompatible)

        let wireFixture = try ControllerFixture()
        await wireFixture.discovery.enqueue(error: Phase2AIWorkerWireError.envelopeTooLarge)

        _ = try? await wireFixture.controller.refresh()

        XCTAssertEqual(wireFixture.controller.snapshot.readiness, .incompatible)
    }

    func testRefreshClassifiesTransportFailureAsUnavailable() async throws {
        let fixture = try ControllerFixture()
        await fixture.discovery.enqueue(error: AIAgentXPCTransportError.unavailable("offline"))

        _ = try? await fixture.controller.refresh()

        XCTAssertEqual(fixture.controller.snapshot.readiness, .unavailable)
    }

    func testControllerSerializesOperationsBeforeCallingDependencies() async throws {
        let fixture = try ControllerFixture()
        await fixture.discovery.suspendNext()
        let refresh = Task { try await fixture.controller.refresh() }
        await fixture.discovery.waitForCallCount(1)
        XCTAssertEqual(fixture.controller.snapshot.readiness, .inventoryRequired)

        XCTAssertThrowsError(
            try fixture.controller.select(modelKey: ControllerFixture.modelKey, maximumTokens: 512)
        ) { XCTAssertEqual($0 as? Phase2LocalAIProviderControllerError, .busy) }
        do {
            _ = try await fixture.controller.refresh()
            XCTFail("a concurrent refresh must fail before a second discovery")
        } catch {
            XCTAssertEqual(error as? Phase2LocalAIProviderControllerError, .busy)
        }
        let discoveryCallCount = await fixture.discovery.callCount
        XCTAssertEqual(discoveryCallCount, 1)

        await fixture.discovery.completeSuspended(.success(fixture.loadedInventory))
        _ = try await refresh.value
    }

    func testEndpointReplacementSuppressesLateRefreshAndInvalidatesObservation() async throws {
        let fixture = try ControllerFixture()
        await fixture.discovery.suspendNext()
        let refresh = Task { try await fixture.controller.refresh() }
        await fixture.discovery.waitForCallCount(1)
        try await fixture.controller.applyEndpoint(
            origin: "http://[::1]:4321",
            requestTimeoutMilliseconds: 5_000,
            resourceTimeoutMilliseconds: 20_000,
            inferencePolicy: .init(effectiveContextTokens: 32_768)
        )
        let replacement = try XCTUnwrap(fixture.controller.snapshot.endpoint)
        XCTAssertTrue(fixture.controller.snapshot.activity.isBusy)
        do {
            _ = try await fixture.controller.refresh()
            XCTFail("replacement must remain gated until the exact old refresh drains")
        } catch {
            XCTAssertEqual(error as? Phase2LocalAIProviderControllerError, .busy)
        }
        await fixture.discovery.completeSuspended(.success(fixture.loadedInventory))
        _ = try? await refresh.value

        XCTAssertEqual(fixture.controller.snapshot.endpoint, replacement)
        XCTAssertNil(fixture.controller.snapshot.inventory)
        XCTAssertEqual(fixture.controller.snapshot.readiness, .inventoryRequired)
        XCTAssertEqual(fixture.controller.snapshot.activity, .idle)
        let cancelledRequestIDs = await fixture.discovery.cancelledRequestIDs
        XCTAssertEqual(cancelledRequestIDs.count, 1)
    }

    func testExplicitRefreshCancellationCancelsExactRequestAndSuppressesLateSuccess() async throws {
        let fixture = try ControllerFixture()
        await fixture.discovery.suspendNext()
        let refresh = Task { try await fixture.controller.refresh() }
        await fixture.discovery.waitForCallCount(1)
        let activeRequestID: UUID
        guard case .discovering(let requestID) = fixture.controller.snapshot.activity else {
            return XCTFail("expected an exact active discovery identity")
        }
        activeRequestID = requestID

        await fixture.controller.cancelCurrentOperation()
        await fixture.discovery.completeSuspended(.success(fixture.loadedInventory))
        _ = try await refresh.value

        let cancelledRequestIDs = await fixture.discovery.cancelledRequestIDs
        XCTAssertEqual(cancelledRequestIDs, [activeRequestID])
        XCTAssertNil(fixture.controller.snapshot.inventory)
        XCTAssertEqual(fixture.controller.snapshot.activity, .idle)
    }

    func testSelectionIsPurelyLocalAndBuildsImmutableExactConfiguration() async throws {
        let fixture = try ControllerFixture()
        await fixture.discovery.enqueue(.success(fixture.loadedInventory))
        _ = try await fixture.controller.refresh()
        let discoveryCallsBeforeSelection = await fixture.discovery.callCount

        try fixture.controller.select(
            modelKey: ControllerFixture.modelKey,
            maximumTokens: 1_024
        )

        let selection = try XCTUnwrap(fixture.controller.snapshot.selection)
        XCTAssertEqual(selection.profileID, fixture.endpoint.profileID)
        XCTAssertEqual(selection.generation, fixture.endpoint.generation)
        XCTAssertEqual(selection.modelKey, ControllerFixture.modelKey)
        XCTAssertEqual(selection.configuration.endpoint, fixture.endpoint)
        XCTAssertEqual(selection.configuration.model, ControllerFixture.modelKey)
        XCTAssertEqual(selection.configuration.maximumTokens, 1_024)
        XCTAssertEqual(
            fixture.controller.snapshot.readiness,
            .ready(selection.configuration)
        )
        let discoveryCallsAfterSelection = await fixture.discovery.callCount
        let lifecycleCallCount = await fixture.lifecycle.callCount
        XCTAssertEqual(discoveryCallsAfterSelection, discoveryCallsBeforeSelection)
        XCTAssertEqual(lifecycleCallCount, 0)
    }

    func testApplyEndpointPreservesProfileAdvancesGenerationAndClearsRuntimeState() async throws {
        let fixture = try ControllerFixture()
        await fixture.discovery.enqueue(.success(fixture.loadedInventory))
        _ = try await fixture.controller.refresh()
        try fixture.controller.select(modelKey: ControllerFixture.modelKey, maximumTokens: 512)

        try await fixture.controller.applyEndpoint(
            origin: "http://[::1]:4321",
            requestTimeoutMilliseconds: 5_000,
            resourceTimeoutMilliseconds: 20_000,
            inferencePolicy: .init(effectiveContextTokens: 32_768)
        )

        let replacement = try XCTUnwrap(fixture.controller.snapshot.endpoint)
        XCTAssertEqual(replacement.profileID, fixture.endpoint.profileID)
        XCTAssertEqual(replacement.generation, fixture.endpoint.generation + 1)
        XCTAssertEqual(replacement.endpointOrigin, "http://[::1]:4321")
        XCTAssertNil(fixture.controller.snapshot.selection)
        XCTAssertNil(fixture.controller.snapshot.inventory)
        XCTAssertTrue(fixture.controller.ownedInstances.isEmpty)
        XCTAssertEqual(fixture.controller.snapshot.readiness, .inventoryRequired)
    }

    func testEndpointAdmissionCanonicalizesLocalhostAndRejectsUnsupportedRemoteOptIn()
        async throws
    {
        let fixture = try ControllerFixture()

        try await fixture.controller.applyEndpoint(
            origin: "http://LOCALHOST:4321/",
            requestTimeoutMilliseconds: 5_000,
            resourceTimeoutMilliseconds: 20_000,
            inferencePolicy: .init(effectiveContextTokens: 32_768)
        )

        let accepted = try XCTUnwrap(fixture.controller.snapshot.endpoint)
        XCTAssertEqual(accepted.endpointOrigin, "http://127.0.0.1:4321")
        XCTAssertEqual(accepted.profileID, fixture.endpoint.profileID)
        XCTAssertEqual(accepted.generation, fixture.endpoint.generation + 1)

        do {
            try await fixture.controller.applyEndpoint(
                origin: "http://192.168.1.20:1234",
                requestTimeoutMilliseconds: 5_000,
                resourceTimeoutMilliseconds: 20_000,
                inferencePolicy: .init(effectiveContextTokens: 32_768)
            )
            XCTFail("A non-loopback origin must require explicit user opt-in")
        } catch {
            XCTAssertEqual(
                error as? Phase2LocalAIProviderControllerError,
                .nonLoopbackOptInRequired
            )
        }
        do {
            try await fixture.controller.applyEndpoint(
                origin: "http://192.168.1.20:1234",
                requestTimeoutMilliseconds: 5_000,
                resourceTimeoutMilliseconds: 20_000,
                allowNonLoopback: true
            )
            XCTFail("This product has no remote-provider authority even after opt-in")
        } catch {
            XCTAssertEqual(
                error as? Phase2LocalAIProviderControllerError,
                .nonLoopbackUnsupported
            )
        }
        XCTAssertEqual(fixture.controller.snapshot.endpoint, accepted)
    }

    func testRestoredPreferenceMintsFreshRuntimeAuthorityWithoutRestoringReadiness() async throws {
        let desired = try Phase2LocalAIDesiredSelection(
            modelKey: ControllerFixture.modelKey,
            maximumTokens: 512
        )
        let preference = try Phase2LocalAIProviderPreference(
            endpointOrigin: "http://127.0.0.1:8000",
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000,
            desiredSelection: desired,
            inferencePolicy: .init(effectiveContextTokens: 32_768)
        )
        let store = InMemoryPhase2LocalAIProviderPreferenceStore(initialPreference: preference)
        let firstDiscovery = ControllerDiscoveryProbe()
        let firstLifecycle = ControllerLifecycleProbe()
        let first = Phase2LocalAIProviderController(
            endpoint: nil,
            discovery: firstDiscovery,
            lifecycle: firstLifecycle,
            preferenceStore: store
        )
        let second = Phase2LocalAIProviderController(
            endpoint: nil,
            discovery: ControllerDiscoveryProbe(),
            lifecycle: ControllerLifecycleProbe(),
            preferenceStore: store
        )

        let firstEndpoint = try XCTUnwrap(first.snapshot.endpoint)
        let secondEndpoint = try XCTUnwrap(second.snapshot.endpoint)
        XCTAssertEqual(firstEndpoint.generation, 1)
        XCTAssertEqual(secondEndpoint.generation, 1)
        XCTAssertNotEqual(firstEndpoint.profileID, secondEndpoint.profileID)
        XCTAssertEqual(first.snapshot.desiredSelection, desired)
        XCTAssertNil(first.snapshot.selection)
        XCTAssertEqual(first.snapshot.readiness, .inventoryRequired)
        XCTAssertTrue(first.ownedInstances.isEmpty)
        let discoveryCallCount = await firstDiscovery.callCount
        let lifecycleCallCount = await firstLifecycle.callCount
        XCTAssertEqual(discoveryCallCount, 0)
        XCTAssertEqual(lifecycleCallCount, 0)
    }

    func testFreshInventoryReauthorizesExactRestoredPreference() async throws {
        let desired = try Phase2LocalAIDesiredSelection(
            modelKey: ControllerFixture.modelKey,
            maximumTokens: 512
        )
        let preference = try Phase2LocalAIProviderPreference(
            endpointOrigin: "http://127.0.0.1:8000",
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000,
            desiredSelection: desired,
            inferencePolicy: .init(effectiveContextTokens: 32_768)
        )
        let discovery = ControllerDiscoveryProbe()
        let controller = Phase2LocalAIProviderController(
            endpoint: nil,
            discovery: discovery,
            lifecycle: ControllerLifecycleProbe(),
            preferenceStore: InMemoryPhase2LocalAIProviderPreferenceStore(
                initialPreference: preference
            )
        )
        let endpoint = try XCTUnwrap(controller.snapshot.endpoint)
        let loaded = Phase2LocalModelLoadedInstance(
            id: ControllerFixture.instanceID,
            configuration: ControllerFixture.configuration
        )
        let inventory = try Phase2LocalModelInventory(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: [controllerModel(instances: [loaded])]
        )
        await discovery.enqueue(.success(inventory))

        _ = try await controller.refresh()

        XCTAssertEqual(controller.snapshot.desiredSelection, desired)
        XCTAssertEqual(controller.snapshot.selection?.modelKey, desired.modelKey)
        XCTAssertEqual(controller.snapshot.selection?.maximumTokens, desired.maximumTokens)
        XCTAssertEqual(
            controller.snapshot.readiness,
            .ready(try XCTUnwrap(controller.snapshot.selection).configuration)
        )
    }

    func testExplicitSelectionAndEndpointEditsPersistIntentButClearDoesNotEraseEndpoint() async throws {
        let endpoint = try ControllerFixture.endpoint(generation: 9)
        let discovery = ControllerDiscoveryProbe()
        let store = InMemoryPhase2LocalAIProviderPreferenceStore()
        let controller = Phase2LocalAIProviderController(
            endpoint: endpoint,
            discovery: discovery,
            lifecycle: ControllerLifecycleProbe(),
            preferenceStore: store
        )
        let inventory = try Phase2LocalModelInventory(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: [controllerModel(instances: [.init(id: ControllerFixture.instanceID,
                configuration: ControllerFixture.configuration)])]
        )
        await discovery.enqueue(.success(inventory))
        _ = try await controller.refresh()

        try controller.select(modelKey: ControllerFixture.modelKey, maximumTokens: 512)
        XCTAssertEqual(store.load()?.desiredSelection?.modelKey, ControllerFixture.modelKey)

        try await controller.applyEndpoint(
            origin: "http://[::1]:4321",
            requestTimeoutMilliseconds: 5_000,
            resourceTimeoutMilliseconds: 20_000,
            inferencePolicy: .init(effectiveContextTokens: 32_768)
        )
        XCTAssertEqual(store.load()?.endpointOrigin, "http://[::1]:4321")
        XCTAssertEqual(store.load()?.desiredSelection?.modelKey, ControllerFixture.modelKey)

        controller.clearSelection()
        XCTAssertEqual(store.load()?.endpointOrigin, "http://[::1]:4321")
        XCTAssertNil(store.load()?.desiredSelection)
    }

    func testRestoredDesiredSelectionSurvivesMissingTypeAndContextDriftWithoutPersistenceWrites()
        async throws
    {
        let desired = try Phase2LocalAIDesiredSelection(
            modelKey: ControllerFixture.modelKey,
            maximumTokens: 512
        )
        let preference = try Phase2LocalAIProviderPreference(
            endpointOrigin: "http://127.0.0.1:8000",
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000,
            desiredSelection: desired,
            inferencePolicy: .init(effectiveContextTokens: 32_768)
        )
        let cases: [(
            name: String,
            models: [Phase2LocalModelDescriptor],
            readiness: Phase2LocalAIProviderReadiness
        )] = [
            ("missing", [], .selectedModelMissing),
            (
                "embedding",
                [controllerModel(type: .embedding, instances: [])],
                .selectedModelNotLanguage
            ),
            (
                "context shrink",
                [controllerModel(maximumContextLength: 256, instances: [])],
                .selectionIdentityMismatch
            ),
        ]

        for testCase in cases {
            let store = RecordingControllerPreferenceStore(initialPreference: preference)
            let discovery = ControllerDiscoveryProbe()
            let controller = Phase2LocalAIProviderController(
                endpoint: nil,
                discovery: discovery,
                lifecycle: ControllerLifecycleProbe(),
                preferenceStore: store
            )
            let endpoint = try XCTUnwrap(controller.snapshot.endpoint, testCase.name)
            let inventory = try Phase2LocalModelInventory(
                profileID: endpoint.profileID,
                generation: endpoint.generation,
                models: testCase.models
            )
            await discovery.enqueue(.success(inventory))

            _ = try await controller.refresh()

            XCTAssertEqual(controller.snapshot.desiredSelection, desired, testCase.name)
            XCTAssertNil(controller.snapshot.selection, testCase.name)
            XCTAssertEqual(controller.snapshot.readiness, testCase.readiness, testCase.name)
            XCTAssertEqual(store.storedPreference, preference, testCase.name)
            XCTAssertEqual(store.saveCount, 0, testCase.name)
            XCTAssertEqual(store.clearCount, 0, testCase.name)
        }
    }

    func testProviderObservationsAndLifecycleDoNotWriteDesiredPreference() async throws {
        let desired = try Phase2LocalAIDesiredSelection(
            modelKey: ControllerFixture.modelKey,
            maximumTokens: 512
        )
        let preference = try Phase2LocalAIProviderPreference(
            endpointOrigin: "http://127.0.0.1:8000",
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000,
            desiredSelection: desired,
            inferencePolicy: .init(effectiveContextTokens: 32_768)
        )
        let store = RecordingControllerPreferenceStore(initialPreference: preference)
        let discovery = ControllerDiscoveryProbe()
        let lifecycle = ControllerLifecycleProbe()
        let controller = Phase2LocalAIProviderController(
            endpoint: nil,
            discovery: discovery,
            lifecycle: lifecycle,
            preferenceStore: store
        )
        let endpoint = try XCTUnwrap(controller.snapshot.endpoint)
        let instance = Phase2LocalModelLoadedInstance(
            id: ControllerFixture.instanceID,
            configuration: ControllerFixture.configuration
        )
        let unloadedInventory = try Phase2LocalModelInventory(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: [controllerModel(instances: [])]
        )
        let loadedInventory = try Phase2LocalModelInventory(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: [controllerModel(instances: [instance])]
        )

        await discovery.enqueue(.success(unloadedInventory))
        _ = try await controller.refresh()
        await discovery.enqueue(.unavailable)
        _ = try await controller.refresh()
        await discovery.enqueue(.success(unloadedInventory))
        _ = try await controller.refresh()
        await discovery.enqueue(.success(loadedInventory))
        _ = try await controller.refresh()

        XCTAssertEqual(controller.snapshot.desiredSelection, desired)
        XCTAssertEqual(controller.snapshot.readiness, .ready(
            try XCTUnwrap(controller.snapshot.selection).configuration
        ))
        XCTAssertEqual(store.storedPreference, preference)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(store.clearCount, 0)
    }

    private func controllerModel(
        type: Phase2LocalModelType = .language,
        key: String = ControllerFixture.modelKey,
        maximumContextLength: Int = 32_768,
        instances: [Phase2LocalModelLoadedInstance]
    ) -> Phase2LocalModelDescriptor {
        .init(
            type: type,
            publisher: "publisher",
            key: key,
            displayName: "Exact Model",
            architecture: "arm64",
            quantization: nil,
            sizeBytesOnDisk: 1,
            parameterCountDescription: nil,
            maximumContextLength: maximumContextLength,
            format: .mlx,
            capabilities: nil,
            variants: [],
            providerSelectedVariant: nil,
            loadedInstances: instances
        )
    }
}

private final class RecordingControllerPreferenceStore:
    Phase2LocalAIProviderPreferencePersisting
{
    private(set) var storedPreference: Phase2LocalAIProviderPreference?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    init(initialPreference: Phase2LocalAIProviderPreference?) {
        storedPreference = initialPreference
    }

    func load() -> Phase2LocalAIProviderPreference? {
        storedPreference
    }

    func save(_ preference: Phase2LocalAIProviderPreference) {
        saveCount += 1
        storedPreference = preference
    }

    func clear() {
        clearCount += 1
        storedPreference = nil
    }
}

private struct ControllerFixture {
    static let profileID = UUID(uuidString: "4F410ED1-9059-4E4C-B76F-A94D42C4899D")!
    static let modelKey = "publisher/exact-model"
    static let instanceID = "runtime-instance"
    static let configuration = Phase2LocalModelInstanceConfiguration(
        effectiveContextLength: 32_768,
        evaluationBatchSize: 512,
        parallelPredictions: 1,
        flashAttention: true,
        expertCount: 8,
        offloadsKVCacheToGPU: true
    )

    let endpoint: Phase2LocalProviderEndpoint
    let unloadedInventory: Phase2LocalModelInventory
    let loadedInventory: Phase2LocalModelInventory
    let loadReceipt: Phase2LocalModelLifecycleReceipt
    let unloadReceipt: Phase2LocalModelLifecycleReceipt
    let ownedIdentity: Phase2LocalModelOwnership
    let discovery = ControllerDiscoveryProbe()
    let lifecycle = ControllerLifecycleProbe()
    let controller: Phase2LocalAIProviderController

    @MainActor
    init() throws {
        endpoint = try Self.endpoint(generation: 9)
        unloadedInventory = try .init(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: [Self.model(instances: [])]
        )
        let instance = Phase2LocalModelLoadedInstance(
            id: Self.instanceID,
            configuration: Self.configuration
        )
        loadedInventory = try .init(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: [Self.model(instances: [instance])]
        )
        loadReceipt = .load(
            modelKey: Self.modelKey,
            instance: instance,
            loadTimeSeconds: 0.25
        )
        unloadReceipt = .unload(modelKey: Self.modelKey, instanceID: Self.instanceID)
        ownedIdentity = .init(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            modelKey: Self.modelKey,
            instanceID: Self.instanceID
        )
        controller = .init(endpoint: endpoint, discovery: discovery, lifecycle: lifecycle)
    }

    static func endpoint(generation: UInt64) throws -> Phase2LocalProviderEndpoint {
        try .init(
            profileID: profileID,
            generation: generation,
            endpointOrigin: "http://127.0.0.1:8000",
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000,
            inferencePolicy: .init(effectiveContextTokens: 32_768)
        )
    }

    private static func model(
        instances: [Phase2LocalModelLoadedInstance]
    ) -> Phase2LocalModelDescriptor {
        .init(
            type: .language,
            publisher: "publisher",
            key: modelKey,
            displayName: "Exact Model",
            architecture: "arm64",
            quantization: nil,
            sizeBytesOnDisk: 1,
            parameterCountDescription: nil,
            maximumContextLength: 32_768,
            format: .mlx,
            capabilities: nil,
            variants: [],
            providerSelectedVariant: nil,
            loadedInstances: instances
        )
    }
}

private actor ControllerDiscoveryProbe: Phase2LocalModelDiscovering {
    private enum Response: Sendable {
        case outcome(Phase2LocalModelDiscoveryOutcome)
        case failure(any Error & Sendable)
    }

    private var queued: [Response] = []
    private var shouldSuspendNext = false
    private var suspended: CheckedContinuation<Phase2LocalModelDiscoveryOutcome, Never>?
    private(set) var requestIDs: [UUID] = []
    private(set) var cancelledRequestIDs: [UUID] = []

    var callCount: Int { requestIDs.count }

    func enqueue(_ outcome: Phase2LocalModelDiscoveryOutcome) {
        queued.append(.outcome(outcome))
    }

    func enqueue(error: any Error & Sendable) {
        queued.append(.failure(error))
    }

    func suspendNext() {
        shouldSuspendNext = true
    }

    func discoverModels(
        endpoint: Phase2LocalProviderEndpoint,
        requestID: UUID
    ) async throws -> Phase2LocalModelDiscoveryOutcome {
        requestIDs.append(requestID)
        if shouldSuspendNext {
            shouldSuspendNext = false
            return await withCheckedContinuation { suspended = $0 }
        }
        guard !queued.isEmpty else { return .unavailable }
        switch queued.removeFirst() {
        case .outcome(let outcome):
            return outcome
        case .failure(let error):
            throw error
        }
    }

    func cancel(requestID: UUID) {
        cancelledRequestIDs.append(requestID)
    }

    func completeSuspended(_ outcome: Phase2LocalModelDiscoveryOutcome) {
        suspended?.resume(returning: outcome)
        suspended = nil
    }

    func waitForCallCount(_ expected: Int) async {
        for _ in 0..<2_000 {
            if callCount >= expected { return }
            await Task.yield()
        }
    }
}

private actor ControllerLifecycleProbe: Phase2LocalModelLifecycleControlling {
    private var queued: [Phase2LocalModelLifecycleOutcome] = []
    private var shouldSuspendNext = false
    private var suspended: CheckedContinuation<Phase2LocalModelLifecycleOutcome, Never>?
    private(set) var commands: [Phase2LocalModelLifecycleCommand] = []
    private(set) var cancelledEffectIDs: [UUID] = []

    var callCount: Int { commands.count }

    func enqueue(_ outcome: Phase2LocalModelLifecycleOutcome) {
        queued.append(outcome)
    }

    func suspendNext() {
        shouldSuspendNext = true
    }

    func perform(
        command: Phase2LocalModelLifecycleCommand,
        endpoint: Phase2LocalProviderEndpoint,
        acceptedInventory: Phase2LocalModelInventory
    ) async throws -> Phase2LocalModelLifecycleOutcome {
        commands.append(command)
        if shouldSuspendNext {
            shouldSuspendNext = false
            return await withCheckedContinuation { suspended = $0 }
        }
        guard !queued.isEmpty else { return .unavailableBeforeDispatch }
        return queued.removeFirst()
    }

    func cancel(effectID: UUID) {
        cancelledEffectIDs.append(effectID)
    }

    func completeSuspended(_ outcome: Phase2LocalModelLifecycleOutcome) {
        suspended?.resume(returning: outcome)
        suspended = nil
    }

    func waitForCallCount(_ expected: Int) async {
        for _ in 0..<2_000 {
            if callCount >= expected { return }
            await Task.yield()
        }
    }
}
