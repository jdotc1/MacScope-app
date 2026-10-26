import XCTest
@testable import MacScope

final class Phase2LocalAIProviderSettingsPresentationTests: XCTestCase {
    func testUnsupportedSavedProviderNoticeRequiresExplicitMTPLXApply() {
        var state = presentation(endpoint: nil, activity: .idle)
        XCTAssertNil(state.preservedLegacyNotice)
        state.hasUnsupportedProviderConfiguration = true
        XCTAssertEqual(state.preservedLegacyNotice,
            "Your saved legacy provider configuration is preserved and has not been migrated. No AI provider is activated. Review the MTPLX endpoint and settings, then explicitly click Apply Endpoint to save the MTPLX configuration.")
        XCTAssertFalse(state.canRefresh)
        XCTAssertNil(state.acceptedEndpointOrigin)
        XCTAssertNil(state.selectedModelKey)
        state.hasUnsupportedProviderConfiguration = false
        XCTAssertNil(state.preservedLegacyNotice)
    }

    func testNewDraftUsesExplicitMTPLXQualityBudgetsWithoutConvertingLegacyEndpoint() throws {
        let draft = LocalAIProviderSettingsView.EndpointDraft.forMTPLX(nil)
        XCTAssertEqual(draft.origin, "http://127.0.0.1:8000")
        XCTAssertEqual(draft.requestTimeoutMilliseconds, 900_000)
        XCTAssertEqual(draft.resourceTimeoutMilliseconds, 1_800_000)
        XCTAssertEqual(draft.inferencePolicy?.provider, .mtplx)
        XCTAssertEqual(draft.inferencePolicy?.reasoningEffort, .xhigh)
        XCTAssertEqual(draft.inferencePolicy?.isValid, true)
        let legacy = try Phase2LocalProviderEndpoint(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:1234", requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 30_000)
        XCTAssertEqual(LocalAIProviderSettingsView.EndpointDraft.forMTPLX(legacy), draft)
        XCTAssertNil(legacy.inferencePolicy)
        XCTAssertEqual(legacy.endpointOrigin, "http://127.0.0.1:1234")
        let current = try Phase2LocalProviderEndpoint(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:8080", requestTimeoutMilliseconds: 120_000,
            resourceTimeoutMilliseconds: 300_000, inferencePolicy: .init())
        XCTAssertEqual(LocalAIProviderSettingsView.EndpointDraft.forMTPLX(current).origin, current.endpointOrigin)
    }
    func testProviderStatusCopyIsClosedAndPayloadFree() {
        XCTAssertEqual(
            LocalAIProviderSettingsView.ProviderStatus.authenticationRequired.title,
            "Authentication Required"
        )
        XCTAssertEqual(
            LocalAIProviderSettingsView.ProviderStatus.unavailable.detail,
            "MacScope could not reach the current loopback provider."
        )
        XCTAssertEqual(
            LocalAIProviderSettingsView.ProviderStatus.incompatible.systemImage,
            AppLocalAISettingsChrome.statusSymbol(for: .error)
        )
        XCTAssertEqual(
            LocalAIProviderSettingsView.ProviderStatus.reconciliationRequired.title,
            "Reconciliation Required"
        )
        XCTAssertEqual(
            LocalAIProviderSettingsView.ProviderStatus.available.tone,
            .ready
        )
    }

    func testReadinessCopyDistinguishesSelectionLoadingAndAvailability() {
        XCTAssertEqual(
            LocalAIProviderSettingsView.Readiness.notConfigured.title,
            "Choose a Model"
        )
        XCTAssertEqual(
            LocalAIProviderSettingsView.Readiness.selectedModelUnavailable.title,
            "Selected Model Unavailable"
        )
        XCTAssertEqual(
            LocalAIProviderSettingsView.Readiness.selectedModelUnloaded.title,
            "Selected Model Not Loaded"
        )
        XCTAssertEqual(
            LocalAIProviderSettingsView.Readiness.ready.title,
            "Ready for MacScope"
        )
        XCTAssertEqual(
            LocalAIProviderSettingsView.Readiness.reconciliationRequired.detail,
            "Refresh the inventory to reconcile the last model operation before continuing."
        )
    }

    func testOnlyLanguageModelsAreInferenceCandidates() {
        let language = model(kind: .language)
        let embedding = model(kind: .embedding)

        XCTAssertTrue(language.isInferenceCandidate)
        XCTAssertFalse(embedding.isInferenceCandidate)
    }

    func testUnknownModelSizeShowsNothingInsteadOfZeroKB() {
        XCTAssertEqual(LocalAIProviderSettingsContainerView.sizeDescription(bytesOnDisk: 0), "")
        XCTAssertFalse(LocalAIProviderSettingsContainerView.sizeDescription(bytesOnDisk: 4_000_000_000).isEmpty)
    }

    func testLoadedStateRequiresAnObservedExactInstance() {
        XCTAssertFalse(model(kind: .language).isLoaded)
        XCTAssertTrue(
            model(
                kind: .language,
                loadedInstances: [
                    .init(
                        id: "instance-1",
                        effectiveContextLength: 16_384,
                        isOwnedByMacScope: true
                    )
                ]
            ).isLoaded
        )
    }

    func testRefreshRequiresAppliedEndpointAndIdleController() {
        let unavailable = presentation(endpoint: nil, activity: .idle)
        let idle = presentation(endpoint: "http://127.0.0.1:1234", activity: .idle)
        let busy = presentation(
            endpoint: "http://127.0.0.1:1234",
            activity: .refreshing
        )

        XCTAssertFalse(unavailable.canRefresh)
        XCTAssertTrue(idle.canRefresh)
        XCTAssertFalse(busy.canRefresh)
    }

    func testEveryActivityOtherThanIdleIsBusy() {
        XCTAssertFalse(LocalAIProviderSettingsView.Activity.idle.isBusy)
        XCTAssertTrue(LocalAIProviderSettingsView.Activity.refreshing.isBusy)
        XCTAssertTrue(LocalAIProviderSettingsView.Activity.performingLifecycle.isBusy)
        XCTAssertNil(LocalAIProviderSettingsView.Activity.idle.visibleStatus)
        XCTAssertNil(LocalAIProviderSettingsView.Activity.refreshing.visibleStatus)
        XCTAssertEqual(
            LocalAIProviderSettingsView.Activity.performingLifecycle.visibleStatus,
            "Updating model…"
        )
    }

    func testEmptyInventoryCopyFollowsProviderState() {
        let acceptedEmpty = presentation(
            endpoint: "http://127.0.0.1:1234",
            activity: .idle,
            providerStatus: .available
        )
        let reconciliation = presentation(
            endpoint: "http://127.0.0.1:1234",
            activity: .idle,
            providerStatus: .reconciliationRequired
        )

        XCTAssertEqual(acceptedEmpty.emptyInventoryTitle, "No Models Reported")
        XCTAssertEqual(
            acceptedEmpty.emptyInventoryDetail,
            "The provider returned a valid inventory with no models."
        )
        XCTAssertEqual(reconciliation.emptyInventoryTitle, "Reconciliation Required")
        XCTAssertEqual(
            reconciliation.emptyInventoryDetail,
            "Refresh the inventory to reconcile the last model operation."
        )
    }

    func testSettingsSidebarStructuralContractKeepsAllCategoriesReachable() {
        XCTAssertEqual(
            SettingsCategory.allCases.map(\.rawValue),
            [
                "analysis",
                "decompiler",
                "appearance",
                "keysAndDisplay",
                "colorTags",
                "plugins",
                "debugger",
                "localAI",
            ]
        )
        XCTAssertEqual(SettingsCategory.allCases.count, 8)
        XCTAssertEqual(SettingsCategory.localAI.title, "Local AI")
        XCTAssertEqual(
            SettingsCategory.localAI.systemImage,
            AppLocalAISettingsChrome.categorySymbol
        )
    }

    func testLocalAISettingsUsesTheFrozenNativeFormSections() {
        XCTAssertEqual(
            LocalAIProviderSettingsView.SectionKind.allCases.map(\.rawValue),
            [
                "MTPLX Connection",
                "Inference Readiness",
                "Discovered Models",
            ]
        )
    }

    func testAccessibilityIdentifiersAreStableAndExactIdentityQualified() {
        XCTAssertEqual(
            LocalAIProviderSettingsView.AccessibilityID.endpointOrigin,
            "local-ai.endpoint.origin"
        )
        XCTAssertEqual(
            LocalAIProviderSettingsView.AccessibilityID.modelRow("publisher/model-a"),
            "local-ai.model.publisher/model-a"
        )
        XCTAssertEqual(
            LocalAIProviderSettingsView.AccessibilityID.useForMacScope("publisher/model-a"),
            "local-ai.model.publisher/model-a.use"
        )
    }

    func testPresentationPreservesExactSelectedModelKeyAndMaximumTokens() {
        let value = LocalAIProviderSettingsView.Presentation(
            acceptedEndpointOrigin: "http://127.0.0.1:1234",
            providerStatus: .available,
            readiness: .ready,
            activity: .idle,
            models: [model(kind: .language)],
            selectedModelKey: "publisher/model-a",
            selectedMaximumTokens: 2_048,
            desiredSelection: nil,
            diagnostic: nil
        )

        XCTAssertEqual(value.selectedModelKey, "publisher/model-a")
        XCTAssertEqual(value.selectedMaximumTokens, 2_048)
        XCTAssertEqual(value.models.map(\.key), ["publisher/model-a"])
    }

    func testRestoredDesiredSelectionIsVisibleOnlyWhileRefreshIsRequired() {
        let desired = LocalAIProviderSettingsView.DesiredSelection(
            modelKey: "publisher/restored-model",
            maximumTokens: 1_024
        )
        let awaitingRefresh = presentation(
            endpoint: "http://127.0.0.1:1234",
            activity: .idle,
            providerStatus: .refreshRequired,
            desiredSelection: desired
        )
        let freshInventory = presentation(
            endpoint: "http://127.0.0.1:1234",
            activity: .idle,
            providerStatus: .available,
            desiredSelection: desired
        )

        XCTAssertEqual(awaitingRefresh.visibleDesiredSelection, desired)
        XCTAssertNil(freshInventory.visibleDesiredSelection)
    }

    func testAuthorizedSelectionSuppressesRestoredDesiredSelection() {
        let desired = LocalAIProviderSettingsView.DesiredSelection(
            modelKey: "publisher/restored-model",
            maximumTokens: 1_024
        )
        let value = LocalAIProviderSettingsView.Presentation(
            acceptedEndpointOrigin: "http://127.0.0.1:1234",
            providerStatus: .refreshRequired,
            readiness: .inventoryRequired,
            activity: .idle,
            models: [],
            selectedModelKey: "publisher/authorized-model",
            selectedMaximumTokens: 2_048,
            desiredSelection: desired,
            diagnostic: nil
        )

        XCTAssertNil(value.visibleDesiredSelection)
    }

    private func presentation(
        endpoint: String?,
        activity: LocalAIProviderSettingsView.Activity,
        providerStatus: LocalAIProviderSettingsView.ProviderStatus? = nil,
        desiredSelection: LocalAIProviderSettingsView.DesiredSelection? = nil
    ) -> LocalAIProviderSettingsView.Presentation {
        .init(
            acceptedEndpointOrigin: endpoint,
            providerStatus: providerStatus ?? (endpoint == nil ? .notConfigured : .available),
            readiness: .notConfigured,
            activity: activity,
            models: [],
            selectedModelKey: nil,
            selectedMaximumTokens: 2_048,
            desiredSelection: desiredSelection,
            diagnostic: nil
        )
    }

    private func model(
        kind: LocalAIProviderSettingsView.ModelKind,
        loadedInstances: [LocalAIProviderSettingsView.LoadedInstance] = []
    ) -> LocalAIProviderSettingsView.Model {
        .init(
            key: "publisher/model-a",
            displayName: "Model A",
            publisher: "Publisher",
            kind: kind,
            format: "GGUF",
            quantization: "Q4",
            sizeDescription: "4 GB",
            maximumContextLength: 32_768,
            loadedInstances: loadedInstances
        )
    }
}
