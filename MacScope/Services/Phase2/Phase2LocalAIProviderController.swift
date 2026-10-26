import Combine
import Foundation

enum Phase2LocalAIProviderControllerError: Error, Equatable, Sendable {
    case busy
    case endpointMissing
    case nonLoopbackOptInRequired
    case nonLoopbackUnsupported
    case inventoryRequired
    case modelNotFound
    case instanceNotFound
    case instanceNotOwned
    case managementUnavailable
    case unsupportedProvider
}

/// Process-global, app-owned provider selection and readiness authority.
///
/// The controller composes the existing discovery and lifecycle seams but owns no network, XPC,
/// or inference implementation. Its injected persistence seam stores desired input only. Every async completion must present the landing token
/// captured for the exact endpoint revision that launched it before it may replace the snapshot.
@MainActor
final class Phase2LocalAIProviderController: ObservableObject {
    @Published private(set) var snapshot: Phase2LocalAIProviderSnapshot
    @Published private(set) var ownedInstances: Set<Phase2LocalModelOwnership> = []
    @Published private(set) var hasUnsupportedProviderConfiguration = false

    private let discovery: any Phase2LocalModelDiscovering
    private let lifecycle: any Phase2LocalModelLifecycleControlling
    private let preferenceStore: any Phase2LocalAIProviderPreferencePersisting
    private var endpoint: Phase2LocalProviderEndpoint?
    private var observation: Phase2LocalAIProviderObservation = .inventoryRequired
    private var desiredSelection: Phase2LocalAIDesiredSelection?
    private var selection: Phase2LocalAISelection?
    private var activity: Phase2LocalAIProviderActivity = .idle
    private var providerRevision: UInt64 = 1
    private var landingToken = UUID()
    private var retiringActivity: Phase2LocalAIProviderActivity?
    private var explicitlyCancelledDiscoveryRequestIDs: Set<UUID> = []

    /// Production composition keeps one discovery service, ownership ledger, and lifecycle service
    /// alive together for the controller's process lifetime.
    convenience init(
        endpoint: Phase2LocalProviderEndpoint? = nil,
        preferenceStore: any Phase2LocalAIProviderPreferencePersisting =
            InMemoryPhase2LocalAIProviderPreferenceStore(),
        defaultPreference: Phase2LocalAIProviderPreference? = nil
    ) {
        let discovery = AIAgentXPCModelDiscoveryService()
        let ownership = Phase2LocalModelOwnershipLedger()
        let lifecycle = AIAgentXPCModelLifecycleService(
            discovery: discovery,
            ownership: ownership
        )
        self.init(
            endpoint: endpoint,
            discovery: discovery,
            lifecycle: lifecycle,
            preferenceStore: preferenceStore,
            defaultPreference: defaultPreference
        )
    }

    init(
        endpoint: Phase2LocalProviderEndpoint?,
        discovery: any Phase2LocalModelDiscovering,
        lifecycle: any Phase2LocalModelLifecycleControlling,
        preferenceStore: any Phase2LocalAIProviderPreferencePersisting =
            InMemoryPhase2LocalAIProviderPreferenceStore(),
        defaultPreference: Phase2LocalAIProviderPreference? = nil
    ) {
        self.discovery = discovery
        self.lifecycle = lifecycle
        self.preferenceStore = preferenceStore

        let hadStoredPreference = endpoint == nil && preferenceStore.hasStoredPreference
        let restored = endpoint == nil ? preferenceStore.load() : nil
        // A stored legacy profile is not absence. Preserve it inert and require an
        // explicit Apply; never reinterpret its port/model or silently select defaults.
        let preference = restored ?? (endpoint == nil && !hadStoredPreference ? defaultPreference : nil)
        let candidate = endpoint ?? (try? preference?.makeEndpoint(profileID: UUID(), generation: 1))
        var unsupported = false
        if let candidate, Self.supports(candidate) {
            self.endpoint = candidate
            desiredSelection = endpoint == nil ? preference?.desiredSelection : nil
        } else {
            self.endpoint = nil
            desiredSelection = nil
            unsupported = endpoint != nil || preference != nil || hadStoredPreference
            if unsupported { observation = .incompatible }
        }
        snapshot = .init(
            endpoint: self.endpoint,
            observation: observation,
            desiredSelection: desiredSelection,
            selection: nil,
            activity: .idle,
            revision: providerRevision
        )
        hasUnsupportedProviderConfiguration = unsupported
    }

    /// Captures executable authority from exactly one current, idle controller snapshot.
    /// Desired preferences and cached selections cannot produce a lease without fresh readiness.
    func captureReadyInferenceLease() -> Phase2ReadyInferenceLease? {
        snapshot.readyInferenceLease
    }

    /// Revalidates the complete launch-local authority identity after an asynchronous turn.
    func isCurrent(_ lease: Phase2ReadyInferenceLease) -> Bool {
        snapshot.readyInferenceLease == lease
    }

    private func replaceEndpoint(_ replacement: Phase2LocalProviderEndpoint?) async {
        let previousActivity = activity
        landingToken = UUID()
        endpoint = replacement
        hasUnsupportedProviderConfiguration = false
        observation = .inventoryRequired
        selection = nil
        if replacement == nil {
            desiredSelection = nil
            preferenceStore.clear()
        } else {
            persistDesiredPreference()
        }
        ownedInstances.removeAll(keepingCapacity: false)
        retiringActivity = previousActivity.isBusy ? previousActivity : nil
        activity = previousActivity.isBusy ? previousActivity : .idle
        publish()

        switch previousActivity {
        case .idle:
            break
        case .discovering(let requestID):
            await discovery.cancel(requestID: requestID)
        case .performingLifecycle(let effectID):
            await lifecycle.cancel(effectID: effectID)
        }
    }

    func applyEndpoint(
        origin: String,
        requestTimeoutMilliseconds: Int,
        resourceTimeoutMilliseconds: Int,
        allowNonLoopback: Bool = false,
        inferencePolicy: Phase2LocalInferencePolicy? = nil
    ) async throws {
        let canonicalOrigin: String
        switch Phase2LocalAIEndpointAdmissionPolicy.classify(origin) {
        case .loopback(let origin):
            canonicalOrigin = origin
        case .nonLoopback:
            throw allowNonLoopback
                ? Phase2LocalAIProviderControllerError.nonLoopbackUnsupported
                : Phase2LocalAIProviderControllerError.nonLoopbackOptInRequired
        case .invalid:
            throw Phase2LocalProviderEndpoint.ValidationError.invalidEndpoint
        }
        guard let inferencePolicy, inferencePolicy.isValid, inferencePolicy.provider == .mtplx else {
            throw Phase2LocalAIProviderControllerError.unsupportedProvider
        }
        let profileID = endpoint?.profileID ?? UUID()
        let generation: UInt64
        if let current = endpoint {
            let (next, overflow) = current.generation.addingReportingOverflow(1)
            guard !overflow, next > 0 else {
                throw Phase2LocalProviderEndpoint.ValidationError.invalidGeneration
            }
            generation = next
        } else {
            generation = 1
        }
        let replacement = try Phase2LocalProviderEndpoint(
            profileID: profileID,
            generation: generation,
            endpointOrigin: canonicalOrigin,
            requestTimeoutMilliseconds: requestTimeoutMilliseconds,
            resourceTimeoutMilliseconds: resourceTimeoutMilliseconds,
            inferencePolicy: inferencePolicy
        )
        await replaceEndpoint(replacement)
    }

    private static func supports(_ endpoint: Phase2LocalProviderEndpoint) -> Bool {
        endpoint.inferencePolicy?.isValid == true && endpoint.inferencePolicy?.provider == .mtplx
    }

    @discardableResult
    func refresh() async throws -> Phase2LocalModelDiscoveryOutcome {
        guard !hasUnsupportedProviderConfiguration else { throw Phase2LocalAIProviderControllerError.unsupportedProvider }
        guard case .idle = activity else { throw Phase2LocalAIProviderControllerError.busy }
        guard let endpoint else { throw Phase2LocalAIProviderControllerError.endpointMissing }

        let requestID = UUID()
        let token = landingToken
        observation = .inventoryRequired
        activity = .discovering(requestID: requestID)
        publish()

        let outcome: Phase2LocalModelDiscoveryOutcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await discovery.discoverModels(endpoint: endpoint, requestID: requestID)
            } onCancel: { [discovery] in
                Task { await discovery.cancel(requestID: requestID) }
            }
        } catch {
            guard token == landingToken else {
                releaseRetirement(for: .discovering(requestID: requestID))
                throw CancellationError()
            }
            if explicitlyCancelledDiscoveryRequestIDs.remove(requestID) != nil {
                activity = .idle
                publish()
                return .cancelled
            }
            observation = discoveryFailureObservation(for: error)
            activity = .idle
            publish()
            throw error
        }

        let wasExplicitlyCancelled = explicitlyCancelledDiscoveryRequestIDs.remove(requestID) != nil
        guard !wasExplicitlyCancelled,
              token == landingToken,
              self.endpoint == endpoint,
              activity == .discovering(requestID: requestID)
        else {
            if token == landingToken, activity == .discovering(requestID: requestID) {
                activity = .idle
                publish()
            } else {
                releaseRetirement(for: .discovering(requestID: requestID))
            }
            return .cancelled
        }

        let reportedOutcome: Phase2LocalModelDiscoveryOutcome
        switch outcome {
        case .success(let candidate)
            where candidate.profileID == endpoint.profileID
                && candidate.generation == endpoint.generation:
            accept(candidate, endpoint: endpoint)
            reportedOutcome = outcome
        case .cancelled:
            reportedOutcome = .cancelled
        case .authenticationRequired:
            observation = .authenticationRequired
            reportedOutcome = .authenticationRequired
        case .unavailable:
            observation = .unavailable
            reportedOutcome = .unavailable
        case .incompatible:
            observation = .incompatible
            reportedOutcome = .incompatible
        case .success:
            observation = .incompatible
            reportedOutcome = .incompatible
        }
        activity = .idle
        publish()
        return reportedOutcome
    }

    func select(modelKey: String, maximumTokens: Int) throws {
        guard case .idle = activity else { throw Phase2LocalAIProviderControllerError.busy }
        guard let endpoint else { throw Phase2LocalAIProviderControllerError.endpointMissing }
        guard case .accepted(let inventory) = observation else {
            throw Phase2LocalAIProviderControllerError.inventoryRequired
        }
        let desired = try Phase2LocalAIDesiredSelection(
            modelKey: modelKey,
            maximumTokens: maximumTokens,
            inferencePolicy: endpoint.inferencePolicy
        )
        selection = try .authorize(
            endpoint: endpoint,
            inventory: inventory,
            modelKey: modelKey,
            maximumTokens: maximumTokens
        )
        desiredSelection = desired
        persistDesiredPreference()
        publish()
    }

    func clearSelection() {
        guard case .idle = activity else { return }
        guard endpoint != nil else { return }
        desiredSelection = nil
        selection = nil
        persistDesiredPreference()
        publish()
    }

    /// Historical API surface remains closed: MTPLX is externally managed.
    @discardableResult
    func load(modelKey: String, requestedContextLength: Int) async throws -> Phase2LocalModelLifecycleOutcome {
        guard case .idle = activity else { throw Phase2LocalAIProviderControllerError.busy }
        throw Phase2LocalAIProviderControllerError.managementUnavailable
    }

    @discardableResult
    func unload(modelKey: String, instanceID: String) async throws -> Phase2LocalModelLifecycleOutcome {
        guard case .idle = activity else { throw Phase2LocalAIProviderControllerError.busy }
        throw Phase2LocalAIProviderControllerError.managementUnavailable
    }

    func cancelCurrentOperation() async {
        switch activity {
        case .idle:
            break
        case .discovering(let requestID):
            explicitlyCancelledDiscoveryRequestIDs.insert(requestID)
            await discovery.cancel(requestID: requestID)
        case .performingLifecycle(let effectID):
            await lifecycle.cancel(effectID: effectID)
        }
    }

    private func publish() {
        if providerRevision < UInt64.max {
            providerRevision += 1
        } else {
            // Exhaustion is practically unreachable, but wrapping would recreate stale authority.
            // Freeze the controller in a closed state instead.
            observation = .reconciliationRequired
            selection = nil
            activity = .idle
        }
        snapshot = .init(
            endpoint: endpoint,
            observation: observation,
            desiredSelection: desiredSelection,
            selection: selection,
            activity: activity,
            revision: providerRevision
        )
    }

    private func releaseRetirement(for completedActivity: Phase2LocalAIProviderActivity) {
        guard retiringActivity == completedActivity else { return }
        retiringActivity = nil
        explicitlyCancelledDiscoveryRequestIDs.removeAll(keepingCapacity: false)
        if activity == completedActivity {
            activity = .idle
            publish()
        }
    }

    private func discoveryFailureObservation(
        for error: any Error
    ) -> Phase2LocalAIProviderObservation {
        if error is Phase2AIWorkerModelDiscoveryAppCodecError
            || error is Phase2AIWorkerWireError {
            return .incompatible
        }
        if let transportError = error as? AIAgentXPCTransportError {
            switch transportError {
            case .malformedReply, .protocolMismatch, .terminalProtocolMismatch:
                return .incompatible
            case .unavailable, .invalidated:
                return .unavailable
            }
        }
        return .unavailable
    }

    private func accept(
        _ inventory: Phase2LocalModelInventory,
        endpoint: Phase2LocalProviderEndpoint
    ) {
        observation = .accepted(inventory)
        if let desiredSelection {
            selection = try? .authorize(
                endpoint: endpoint,
                inventory: inventory,
                modelKey: desiredSelection.modelKey,
                maximumTokens: desiredSelection.maximumTokens
            )
        } else {
            selection = nil
        }
        // MacScope uses whatever MTPLX serves: when the saved choice is absent or no
        // longer served and exactly one chat model is eligible, adopt and remember it.
        // With several eligible models the explicit choice stays with the user, and a
        // saved model that is still served keeps its own readiness diagnosis.
        let savedModelIsServed = desiredSelection.map { desired in
            inventory.models.contains { $0.key == desired.modelKey }
        } ?? false
        if selection == nil,
           !savedModelIsServed,
           let adopted = Self.soleEligibleSelection(
            endpoint: endpoint,
            inventory: inventory,
            preferredMaximumTokens: desiredSelection?.maximumTokens
           ),
           let desired = try? Phase2LocalAIDesiredSelection(
            modelKey: adopted.modelKey,
            maximumTokens: adopted.maximumTokens,
            inferencePolicy: endpoint.inferencePolicy
           ) {
            selection = adopted
            desiredSelection = desired
            persistDesiredPreference()
        }
        ownedInstances = Set(ownedInstances.filter { ownership in
            guard ownership.profileID == endpoint.profileID,
                  ownership.generation == endpoint.generation,
                  let model = inventory.models.first(where: {
                      $0.key == ownership.modelKey
                  })
            else { return false }
            return model.loadedInstances.contains(where: { $0.id == ownership.instanceID })
        })
    }

    static let adoptedMaximumTokens = Phase2LocalInferencePolicy.defaultMaximumOutputTokens

    private static func soleEligibleSelection(
        endpoint: Phase2LocalProviderEndpoint,
        inventory: Phase2LocalModelInventory,
        preferredMaximumTokens: Int?
    ) -> Phase2LocalAISelection? {
        let eligible = inventory.models.filter { $0.type == .language }.compactMap { model in
            [preferredMaximumTokens, min(adoptedMaximumTokens, model.maximumContextLength)]
                .compactMap { $0 }.lazy.compactMap {
                try? Phase2LocalAISelection.authorize(
                    endpoint: endpoint,
                    inventory: inventory,
                    modelKey: model.key,
                    maximumTokens: $0
                )
            }.first
        }
        return eligible.count == 1 ? eligible[0] : nil
    }

    /// Refreshes the loopback inventory when the Assistant is not ready and the
    /// controller is idle, so opening the Assistant needs no manual Refresh Models.
    func refreshIfNotReady() async {
        guard !hasUnsupportedProviderConfiguration,
              endpoint != nil,
              case .idle = activity
        else { return }
        if case .ready = snapshot.readiness { return }
        _ = try? await refresh()
    }

    private func persistDesiredPreference() {
        guard let endpoint,
              let preference = try? Phase2LocalAIProviderPreference(
                endpointOrigin: endpoint.endpointOrigin,
                requestTimeoutMilliseconds: endpoint.requestTimeoutMilliseconds,
                resourceTimeoutMilliseconds: endpoint.resourceTimeoutMilliseconds,
                desiredSelection: desiredSelection,
                inferencePolicy: endpoint.inferencePolicy
              )
        else {
            preferenceStore.clear()
            return
        }
        preferenceStore.save(preference)
    }
}
