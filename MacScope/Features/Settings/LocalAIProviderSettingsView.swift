import Foundation
import SwiftUI
import LumenUI

/// Native Settings presentation for MacScope's single app-global local AI provider.
///
/// The view deliberately owns no provider service, XPC connection, inference provider, process
/// control, authentication, download, or persistence authority. Its parent supplies an immutable
/// presentation snapshot and explicit intent closures backed by the app-global controller.
struct LocalAIProviderSettingsView: View {
    enum SectionKind: String, CaseIterable, Sendable {
        case localProvider = "MTPLX Connection"
        case inferenceReadiness = "Inference Readiness"
        case discoveredModels = "Discovered Models"
    }

    struct EndpointDraft: Equatable, Sendable {
        var origin: String
        var requestTimeoutMilliseconds: Int
        var resourceTimeoutMilliseconds: Int
        var inferencePolicy: Phase2LocalInferencePolicy? = .init()

        static func forMTPLX(_ endpoint: Phase2LocalProviderEndpoint?) -> Self {
            guard let endpoint, endpoint.inferencePolicy?.provider == .mtplx,
                  endpoint.inferencePolicy?.isValid == true else {
                return .init(origin: "http://127.0.0.1:8000", requestTimeoutMilliseconds: 900_000,
                             resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: .init())
            }
            return .init(origin: endpoint.endpointOrigin,
                         requestTimeoutMilliseconds: endpoint.requestTimeoutMilliseconds,
                         resourceTimeoutMilliseconds: endpoint.resourceTimeoutMilliseconds,
                         inferencePolicy: endpoint.inferencePolicy)
        }
    }

    enum ProviderStatus: Equatable, Sendable {
        case notConfigured
        case refreshRequired
        case checking
        case available
        case authenticationRequired
        case unavailable
        case incompatible
        case reconciliationRequired

        var title: String {
            switch self {
            case .notConfigured: "Not Configured"
            case .refreshRequired: "Refresh Required"
            case .checking: "Checking Provider"
            case .available: "Provider Available"
            case .authenticationRequired: "Authentication Required"
            case .unavailable: "Provider Unavailable"
            case .incompatible: "Incompatible Provider"
            case .reconciliationRequired: "Reconciliation Required"
            }
        }

        var detail: String {
            switch self {
            case .notConfigured:
                "Apply a literal loopback endpoint before checking for models."
            case .refreshRequired:
                "Refresh the MTPLX endpoint before choosing a model."
            case .checking:
                "MacScope is checking the current endpoint and model inventory."
            case .available:
                "The current loopback provider returned a valid model inventory."
            case .authenticationRequired:
                "The provider requires authentication, which this local preview does not support."
            case .unavailable:
                "MacScope could not reach the current loopback provider."
            case .incompatible:
                "The provider response did not satisfy MacScope's bounded protocol contract."
            case .reconciliationRequired:
                "Refresh the inventory before issuing another model action."
            }
        }

        var systemImage: String {
            AppLocalAISettingsChrome.statusSymbol(for: tone)
        }

        var tone: AppLocalAIStatusTone {
            switch self {
            case .notConfigured, .refreshRequired: .neutral
            case .checking: .inProgress
            case .available: .ready
            case .authenticationRequired, .reconciliationRequired: .warning
            case .unavailable, .incompatible: .error
            }
        }
    }

    enum Readiness: Equatable, Sendable {
        case notConfigured
        case endpointMissing
        case inventoryRequired
        case refreshing
        case authenticationRequired
        case providerUnavailable
        case selectionIdentityMismatch
        case selectedModelUnavailable
        case selectedModelUnloaded
        case ready
        case incompatible
        case reconciliationRequired

        var title: String {
            switch self {
            case .notConfigured: "Choose a Model"
            case .endpointMissing: "Apply an Endpoint"
            case .inventoryRequired: "Refresh Required"
            case .refreshing: "Refreshing"
            case .authenticationRequired: "Authentication Required"
            case .providerUnavailable: "Provider Unavailable"
            case .selectionIdentityMismatch: "Selection Is Stale"
            case .selectedModelUnavailable: "Selected Model Unavailable"
            case .selectedModelUnloaded: "Selected Model Not Loaded"
            case .ready: "Ready for MacScope"
            case .incompatible: "Provider Incompatible"
            case .reconciliationRequired: "Reconciliation Required"
            }
        }

        var detail: String {
            switch self {
            case .notConfigured:
                "Refresh the inventory, then explicitly choose a language model."
            case .endpointMissing:
                "Apply a literal loopback endpoint before checking readiness."
            case .inventoryRequired:
                "Refresh the exact endpoint inventory before checking readiness."
            case .refreshing:
                "Readiness will be evaluated from the new inventory."
            case .authenticationRequired:
                "Readiness is closed because authentication is not supported by this preview."
            case .providerUnavailable:
                "The selected model cannot be used until the provider is available."
            case .selectionIdentityMismatch:
                "The selection does not belong to the current endpoint generation."
            case .selectedModelUnavailable:
                "The exact selected model key is missing or is not eligible for chat inference."
            case .selectedModelUnloaded:
                "Make the selected model available in MTPLX before starting an inference request."
            case .ready:
                "The selected language model is available in the current MTPLX inventory."
            case .incompatible:
                "Readiness is closed because the provider contract could not be verified."
            case .reconciliationRequired:
                "Refresh the inventory to reconcile the last model operation before continuing."
            }
        }

        var systemImage: String {
            AppLocalAISettingsChrome.statusSymbol(for: tone)
        }

        var tone: AppLocalAIStatusTone {
            switch self {
            case .notConfigured, .endpointMissing, .inventoryRequired: .neutral
            case .refreshing: .inProgress
            case .authenticationRequired, .selectionIdentityMismatch,
                 .selectedModelUnavailable, .selectedModelUnloaded,
                 .reconciliationRequired:
                .warning
            case .providerUnavailable, .incompatible: .error
            case .ready: .ready
            }
        }
    }

    enum Activity: Equatable, Sendable {
        case idle
        case refreshing
        case performingLifecycle

        var isBusy: Bool { self != .idle }

        var visibleStatus: String? {
            switch self {
            case .idle, .refreshing: nil
            case .performingLifecycle: "Updating model…"
            }
        }
    }

    enum ModelKind: String, Equatable, Sendable {
        case language = "Language"
        case embedding = "Embedding"
    }

    struct LoadedInstance: Identifiable, Equatable, Sendable {
        let id: String
        let effectiveContextLength: Int
        let isOwnedByMacScope: Bool
    }

    struct Model: Identifiable, Equatable, Sendable {
        var id: String { key }

        let key: String
        let displayName: String
        let publisher: String
        let kind: ModelKind
        let format: String?
        let quantization: String?
        let sizeDescription: String
        let maximumContextLength: Int
        let loadedInstances: [LoadedInstance]

        var isInferenceCandidate: Bool { kind == .language }
        var isLoaded: Bool { !loadedInstances.isEmpty }
    }

    struct DesiredSelection: Equatable, Sendable {
        let modelKey: String
        let maximumTokens: Int
    }

    struct Presentation: Equatable, Sendable {
        let acceptedEndpointOrigin: String?
        let providerStatus: ProviderStatus
        let readiness: Readiness
        let activity: Activity
        let models: [Model]
        let selectedModelKey: String?
        let selectedMaximumTokens: Int
        let desiredSelection: DesiredSelection?
        let diagnostic: String?
        var inferencePolicy: Phase2LocalInferencePolicy? = nil
        var hasUnsupportedProviderConfiguration = false

        var preservedLegacyNotice: String? {
            guard hasUnsupportedProviderConfiguration else { return nil }
            return "Your saved legacy provider configuration is preserved and has not been migrated. No AI provider is activated. Review the MTPLX endpoint and settings, then explicitly click Apply Endpoint to save the MTPLX configuration."
        }

        var isBusy: Bool { activity.isBusy }
        var canRefresh: Bool { acceptedEndpointOrigin != nil && !isBusy }

        /// A restored preference is presentation-only until a fresh exact inventory authorizes it.
        /// Never show it beside an actual selection or after discovery has left Refresh Required.
        var visibleDesiredSelection: DesiredSelection? {
            guard providerStatus == .refreshRequired,
                  selectedModelKey == nil
            else { return nil }
            return desiredSelection
        }

        var emptyInventoryTitle: String {
            switch providerStatus {
            case .checking: "Refreshing Models"
            case .available: "No Models Reported"
            case .authenticationRequired: "Authentication Required"
            case .unavailable: "Provider Unavailable"
            case .incompatible: "Incompatible Provider"
            case .reconciliationRequired: "Reconciliation Required"
            case .notConfigured, .refreshRequired: "No Models Discovered"
            }
        }

        var emptyInventoryDetail: String {
            switch providerStatus {
            case .notConfigured:
                "Apply a literal loopback endpoint before refreshing its model inventory."
            case .refreshRequired:
                "Refresh the current endpoint to discover its model inventory."
            case .checking:
                "MacScope is requesting a fresh model inventory."
            case .available:
                "The provider returned a valid inventory with no models."
            case .authenticationRequired:
                "This preview cannot authenticate with the configured provider."
            case .unavailable:
                "Check that the local provider is running, then refresh again."
            case .incompatible:
                "The provider response did not satisfy MacScope's bounded protocol contract."
            case .reconciliationRequired:
                "Refresh the inventory to reconcile the last model operation."
            }
        }
    }

    struct Actions {
        let applyEndpoint: @MainActor (EndpointDraft) async -> Void
        let refresh: @MainActor () async -> Void
        let useForMacScope: @MainActor (_ modelKey: String, _ maximumTokens: Int) async -> Void
        let clearSelection: @MainActor () async -> Void
        let cancel: @MainActor () async -> Void
    }

    enum AccessibilityID {
        static let endpointOrigin = "local-ai.endpoint.origin"
        static let samplingMode = "local-ai.endpoint.sampling-mode"
        static let requestTimeout = "local-ai.endpoint.request-timeout"
        static let resourceTimeout = "local-ai.endpoint.resource-timeout"
        static let applyEndpoint = "local-ai.endpoint.apply"
        static let refresh = "local-ai.inventory.refresh"
        static let providerStatus = "local-ai.provider.status"
        static let readiness = "local-ai.readiness.status"
        static let emptyInventory = "local-ai.inventory.empty"
        static let cancel = "local-ai.activity.cancel"
        static let lifecycleActivity = "local-ai.activity.lifecycle"
        static let clearSelection = "local-ai.selection.clear"
        static let desiredSelection = "local-ai.selection.desired"

        static func modelRow(_ modelKey: String) -> String {
            "local-ai.model.\(modelKey)"
        }

        static func useForMacScope(_ modelKey: String) -> String {
            "local-ai.model.\(modelKey).use"
        }

    }

    @Binding private var endpointDraft: EndpointDraft
    let presentation: Presentation
    let actions: Actions

    @State private var requestedMaximumTokens: Int

    init(
        endpointDraft: Binding<EndpointDraft>,
        presentation: Presentation,
        actions: Actions
    ) {
        _endpointDraft = endpointDraft
        self.presentation = presentation
        self.actions = actions
        _requestedMaximumTokens = State(initialValue: presentation.selectedMaximumTokens)
    }

    var body: some View {
        // Form is the sole scroll and grouping owner for this native Settings category.
        Form {
            providerSection
            readinessSection
            modelsSection
            Section {
                localityFootnote
            }
        }
        .formStyle(.grouped)
        .onChange(of: presentation.selectedMaximumTokens) { _, value in
            requestedMaximumTokens = value
        }
    }

    private var samplingOverride: Phase2LocalSamplingOverride? {
        endpointDraft.inferencePolicy?.sampling
    }

    private func updateSampling(_ sampling: Phase2LocalSamplingOverride?,
                                reasoningEffort: Phase2LocalReasoningEffort? = nil) {
        let policy = endpointDraft.inferencePolicy ?? .init()
        endpointDraft.inferencePolicy = policy.withSampling(sampling, reasoningEffort: reasoningEffort)
    }

    private func samplingBinding<Value>(
        _ keyPath: KeyPath<Phase2LocalSamplingOverride, Value>,
        _ make: @escaping (Phase2LocalSamplingOverride, Value) -> Phase2LocalSamplingOverride
    ) -> Binding<Value> {
        Binding(
            get: { (samplingOverride ?? .groundedDefault)[keyPath: keyPath] },
            set: { updateSampling(make(samplingOverride ?? .groundedDefault, $0)) }
        )
    }

    @ViewBuilder private var samplingControls: some View {
        Picker("Sampling", selection: Binding(
            get: { samplingOverride != nil },
            set: { override in
                updateSampling(override ? .groundedDefault : nil,
                               reasoningEffort: override ? .medium : nil)
            }
        )) {
            Text("Use MTPLX model settings").tag(false)
            Text("MacScope override").tag(true)
        }
        .accessibilityIdentifier(AccessibilityID.samplingMode)
        if samplingOverride != nil {
            TextField("Temperature", value: samplingBinding(\.temperature) {
                .init(temperature: $1, topP: $0.topP, topK: $0.topK)
            }, format: .number.precision(.fractionLength(0...2)))
            TextField("Top P", value: samplingBinding(\.topP) {
                .init(temperature: $0.temperature, topP: $1, topK: $0.topK)
            }, format: .number.precision(.fractionLength(0...2)))
            TextField("Top K", value: samplingBinding(\.topK) {
                .init(temperature: $0.temperature, topP: $0.topP, topK: $1)
            }, format: .number)
            Picker("Reasoning effort", selection: Binding(
                get: { endpointDraft.inferencePolicy?.reasoningEffort ?? .medium },
                set: { updateSampling(samplingOverride, reasoningEffort: $0) }
            )) {
                Text("Medium").tag(Phase2LocalReasoningEffort.medium)
                Text("Xhigh").tag(Phase2LocalReasoningEffort.xhigh)
                Text("Auto (model default)").tag(Phase2LocalReasoningEffort.auto)
            }
        }
        Text(samplingOverride == nil
            ? "MTPLX applies each model's own sampling, reasoning and MTP depth. Maximum output is set per model below. Apply Endpoint to save."
            : "MacScope sends these values with every request. Maximum output is set per model below. Apply Endpoint to save.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var providerSection: some View {
        Section(SectionKind.localProvider.rawValue) {
            VStack(alignment: .leading, spacing: AppLocalAISettingsChrome.controlRowSpacing) {
                LabeledContent("Provider", value: "MTPLX")
                if endpointDraft.inferencePolicy != nil {
                    samplingControls
                }
                TextField("Loopback endpoint", text: $endpointDraft.origin)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.settingsIdentifier)
                    .frame(minWidth: AppLocalAISettingsChrome.endpointFieldMinWidth)
                    .accessibilityIdentifier(AccessibilityID.endpointOrigin)

                HStack(spacing: AppLocalAISettingsChrome.controlRowSpacing) {
                    timeoutField(
                        "Request timeout",
                        value: $endpointDraft.requestTimeoutMilliseconds,
                        identifier: AccessibilityID.requestTimeout
                    )
                    timeoutField(
                        "Resource timeout",
                        value: $endpointDraft.resourceTimeoutMilliseconds,
                        identifier: AccessibilityID.resourceTimeout
                    )
                }

                HStack(spacing: Lumen.Space.s4) {
                    Button("Apply Endpoint") {
                        Task { await actions.applyEndpoint(endpointDraft) }
                    }
                    .accessibilityIdentifier(AccessibilityID.applyEndpoint)
                    .disabled(presentation.isBusy || endpointDraft.origin.isEmpty
                        || endpointDraft.inferencePolicy?.provider != .mtplx
                        || endpointDraft.inferencePolicy?.isValid != true)

                    Button {
                        Task { await actions.refresh() }
                    } label: {
                        Label("Refresh Models", systemImage: AppLocalAISettingsChrome.refreshSymbol)
                    }
                    .accessibilityIdentifier(AccessibilityID.refresh)
                    .disabled(!presentation.canRefresh)

                    if presentation.isBusy {
                        Button("Cancel") {
                            Task { await actions.cancel() }
                        }
                        .accessibilityIdentifier(AccessibilityID.cancel)
                    }

                    Spacer(minLength: 0)
                }

                statusLabel(
                    title: presentation.providerStatus.title,
                    detail: presentation.providerStatus.detail,
                    systemImage: presentation.providerStatus.systemImage,
                    tone: presentation.providerStatus.tone,
                    identifier: AccessibilityID.providerStatus
                )
            }
        }
    }

    private var readinessSection: some View {
        Section(SectionKind.inferenceReadiness.rawValue) {
            VStack(alignment: .leading, spacing: AppLocalAISettingsChrome.controlRowSpacing) {
                statusLabel(
                    title: presentation.readiness.title,
                    detail: presentation.readiness.detail,
                    systemImage: presentation.readiness.systemImage,
                    tone: presentation.readiness.tone,
                    identifier: AccessibilityID.readiness
                )

                if let selectedModelKey = presentation.selectedModelKey {
                    VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                        Text("Selected model")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s4) {
                            Text(selectedModelKey)
                                .font(AppTypography.settingsIdentifier)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(selectedModelKey)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Clear Selection") {
                                Task { await actions.clearSelection() }
                            }
                            .fixedSize()
                            .layoutPriority(1)
                            .accessibilityIdentifier(AccessibilityID.clearSelection)
                            .disabled(presentation.isBusy)
                        }
                    }
                } else if let desiredSelection = presentation.visibleDesiredSelection {
                    VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                        Text("Restored preference — awaiting refresh")
                            .font(.headline)
                        Text(desiredSelection.modelKey)
                            .font(AppTypography.settingsIdentifier)
                            .textSelection(.enabled)
                            .lineLimit(AppLocalAISettingsChrome.modelKeyLineLimit)
                            .truncationMode(.middle)
                            .help(desiredSelection.modelKey)
                        Text("Maximum output: \(desiredSelection.maximumTokens.formatted()) tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(
                            "This saved preference is not authorized or ready until a fresh inventory validates the exact model key."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.desiredSelection)
                }

                if let activityStatus = presentation.activity.visibleStatus {
                    Label(
                        activityStatus,
                        systemImage: AppLocalAISettingsChrome.refreshSymbol
                    )
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.lifecycleActivity)
                }

                if let notice = presentation.preservedLegacyNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("localAI.preservedLegacyConfiguration")
                }

                if let diagnostic = presentation.diagnostic, !diagnostic.isEmpty {
                    Text(diagnostic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var modelsSection: some View {
        Section(SectionKind.discoveredModels.rawValue) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if presentation.models.isEmpty {
                    ContentUnavailableView(
                        presentation.emptyInventoryTitle,
                        systemImage: AppLocalAISettingsChrome.categorySymbol,
                        description: Text(presentation.emptyInventoryDetail)
                    )
                    .accessibilityIdentifier(AccessibilityID.emptyInventory)
                    .padding(.vertical, Lumen.Space.s7)
                } else {
                    ForEach(Array(presentation.models.enumerated()), id: \.element.id) { index, model in
                        modelRow(model)
                        if index < presentation.models.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func modelRow(_ model: Model) -> some View {
        VStack(alignment: .leading, spacing: AppLocalAISettingsChrome.modelRowTextSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s4) {
                Text(model.displayName)
                    .font(.headline)
                    .lineLimit(2)
                Label(
                    model.kind.rawValue,
                    systemImage: model.kind == .language
                        ? AppLocalAISettingsChrome.languageModelSymbol
                        : AppLocalAISettingsChrome.embeddingModelSymbol
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if presentation.selectedModelKey == model.key {
                    Label("Selected", systemImage: AppLocalAISettingsChrome.loadedModelSymbol)
                        .font(.caption)
                }
                Spacer(minLength: 0)
                Label(
                    model.isLoaded ? "Loaded" : "Not Loaded",
                    systemImage: model.isLoaded
                        ? AppLocalAISettingsChrome.loadedModelSymbol
                        : AppLocalAISettingsChrome.unloadedModelSymbol
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(model.key)
                .font(AppTypography.settingsIdentifier)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            Text(modelMetadata(model))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isInferenceCandidate {
                languageModelActions(model)
            } else {
                Label("Embedding models cannot be used for chat inference.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.loadedInstances) { instance in
                loadedInstanceRow(instance, model: model)
            }
        }
        .padding(.vertical, Lumen.Space.s5)
        .frame(minHeight: AppLocalAISettingsChrome.modelRowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.modelRow(model.key))
    }

    private func languageModelActions(_ model: Model) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Text("Model loading, unloading and context are managed in MTPLX.")
                .font(.caption).foregroundStyle(.secondary)

            Stepper(
                "Maximum output: \(maximumTokens(for: model).formatted()) tokens",
                value: maximumTokensBinding(for: model),
                in: 1...maximumAllowedTokens(for: model),
                step: 128
            )

            HStack(spacing: Lumen.Space.s4) {
                Button("Use for MacScope") {
                    let maximumTokens = maximumTokens(for: model)
                    Task { await actions.useForMacScope(model.key, maximumTokens) }
                }
                .accessibilityIdentifier(AccessibilityID.useForMacScope(model.key))
                .disabled(presentation.isBusy)
            }
        }
    }

    private func loadedInstanceRow(_ instance: LoadedInstance, model: Model) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s4) {
            HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s4) {
                Label("Instance", systemImage: "memorychip")
                    .font(.caption)
                Text(instance.id)
                    .font(AppTypography.settingsIdentifier)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(instance.id)
                Text("\(instance.effectiveContextLength.formatted()) context")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !instance.isOwnedByMacScope {
                    Text("Managed externally")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(instanceAccessibilityLabel(instance, model: model))
            Spacer(minLength: 0)
        }
    }

    private func timeoutField(
        _ title: String,
        value: Binding<Int>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Milliseconds", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: AppLocalAISettingsChrome.timeoutFieldWidth)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel("\(title) in milliseconds")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLabel(
        title: String,
        detail: String,
        systemImage: String,
        tone: AppLocalAIStatusTone,
        identifier: String
    ) -> some View {
        HStack(alignment: .top, spacing: Lumen.Space.s4) {
            Image(systemName: systemImage)
                .foregroundStyle(AppLocalAISettingsChrome.statusColor(for: tone))
                .frame(width: AppLocalAISettingsChrome.statusSymbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var localityFootnote: some View {
        Label(
            "MacScope connects only to the configured MTPLX loopback endpoint. Model files and lifecycle are managed in MTPLX; MacScope does not download, load or unload them. MTPLX is a separate local service and may have its own network behavior.",
            systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func modelMetadata(_ model: Model) -> String {
        var components = [model.publisher, model.sizeDescription]
        if let format = model.format, !format.isEmpty { components.append(format) }
        if let quantization = model.quantization, !quantization.isEmpty {
            components.append(quantization)
        }
        components.append("up to \(model.maximumContextLength.formatted()) context")
        return components.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func instanceAccessibilityLabel(_ instance: LoadedInstance, model: Model) -> String {
        let ownership = instance.isOwnedByMacScope ? "owned by MacScope" : "managed externally"
        return "\(model.displayName), instance \(instance.id), \(instance.effectiveContextLength) token context, \(ownership)"
    }

    private func maximumAllowedTokens(for model: Model) -> Int {
        max(1, min(16_384, model.maximumContextLength))
    }

    private func maximumTokens(for model: Model) -> Int {
        min(max(1, requestedMaximumTokens), maximumAllowedTokens(for: model))
    }

    private func maximumTokensBinding(for model: Model) -> Binding<Int> {
        Binding(
            get: { maximumTokens(for: model) },
            set: { requestedMaximumTokens = min($0, maximumAllowedTokens(for: model)) }
        )
    }

}

/// Production adapter between the app-global controller and the authority-free Settings view.
/// Keep this wrapper outside `SettingsView` so every Settings presentation observes the same
/// controller snapshot and maps the domain's closed states identically.
@MainActor
struct LocalAIProviderSettingsContainerView: View {
    @ObservedObject private var controller: Phase2LocalAIProviderController
    @State private var endpointDraft: LocalAIProviderSettingsView.EndpointDraft
    @State private var boundedOperationDiagnostic: String?

    init(controller: Phase2LocalAIProviderController) {
        self.controller = controller
        let endpoint = controller.snapshot.endpoint
        _endpointDraft = State(initialValue: .forMTPLX(endpoint))
    }

    var body: some View {
        LocalAIProviderSettingsView(
            endpointDraft: $endpointDraft,
            presentation: presentation,
            actions: actions
        )
        .onChange(of: controller.snapshot.endpoint) { _, endpoint in
            endpointDraft = .forMTPLX(endpoint)
        }
    }

    private var actions: LocalAIProviderSettingsView.Actions {
        .init(
            applyEndpoint: { draft in
                boundedOperationDiagnostic = nil
                do {
                    try await controller.applyEndpoint(
                        origin: draft.origin,
                        requestTimeoutMilliseconds: draft.requestTimeoutMilliseconds,
                        resourceTimeoutMilliseconds: draft.resourceTimeoutMilliseconds,
                        inferencePolicy: draft.inferencePolicy
                    )
                } catch {
                    boundedOperationDiagnostic = "The endpoint or timeout values are invalid."
                }
            },
            refresh: {
                boundedOperationDiagnostic = nil
                do {
                    try await controller.refresh()
                } catch {
                    boundedOperationDiagnostic = "The provider inventory could not be refreshed."
                }
            },
            useForMacScope: { modelKey, maximumTokens in
                boundedOperationDiagnostic = nil
                do {
                    try controller.select(modelKey: modelKey, maximumTokens: maximumTokens)
                } catch {
                    boundedOperationDiagnostic = "The selected model is not eligible for inference."
                }
            },
            clearSelection: {
                boundedOperationDiagnostic = nil
                controller.clearSelection()
            },
            cancel: {
                boundedOperationDiagnostic = nil
                await controller.cancelCurrentOperation()
            }
        )
    }

    private var presentation: LocalAIProviderSettingsView.Presentation {
        let snapshot = controller.snapshot
        return .init(
            acceptedEndpointOrigin: snapshot.endpoint?.endpointOrigin,
            providerStatus: providerStatus(snapshot),
            readiness: readiness(snapshot),
            activity: activity(snapshot.activity),
            models: models(snapshot),
            selectedModelKey: snapshot.selection?.modelKey,
            selectedMaximumTokens: snapshot.selection?.maximumTokens
                ?? desiredSelection(snapshot)?.maximumTokens
                ?? Phase2LocalInferencePolicy.defaultMaximumOutputTokens,
            desiredSelection: desiredSelection(snapshot),
            diagnostic: boundedOperationDiagnostic,
            inferencePolicy: snapshot.endpoint?.inferencePolicy,
            hasUnsupportedProviderConfiguration: controller.hasUnsupportedProviderConfiguration
        )
    }

    private func desiredSelection(
        _ snapshot: Phase2LocalAIProviderSnapshot
    ) -> LocalAIProviderSettingsView.DesiredSelection? {
        guard case .inventoryRequired = snapshot.observation,
              snapshot.selection == nil,
              let desired = snapshot.desiredSelection
        else { return nil }
        return .init(
            modelKey: desired.modelKey,
            maximumTokens: desired.maximumTokens
        )
    }

    private func providerStatus(
        _ snapshot: Phase2LocalAIProviderSnapshot
    ) -> LocalAIProviderSettingsView.ProviderStatus {
        guard snapshot.endpoint != nil else { return .notConfigured }
        if case .discovering = snapshot.activity { return .checking }
        switch snapshot.observation {
        case .inventoryRequired: return .refreshRequired
        case .accepted: return .available
        case .authenticationRequired: return .authenticationRequired
        case .unavailable: return .unavailable
        case .incompatible: return .incompatible
        case .reconciliationRequired: return .reconciliationRequired
        }
    }

    private func readiness(
        _ snapshot: Phase2LocalAIProviderSnapshot
    ) -> LocalAIProviderSettingsView.Readiness {
        if case .discovering = snapshot.activity { return .refreshing }
        switch snapshot.readiness {
        case .endpointMissing: return .endpointMissing
        case .inventoryRequired: return .inventoryRequired
        case .authenticationRequired: return .authenticationRequired
        case .unavailable: return .providerUnavailable
        case .incompatible: return .incompatible
        case .reconciliationRequired: return .reconciliationRequired
        case .selectionRequired: return .notConfigured
        case .selectionIdentityMismatch: return .selectionIdentityMismatch
        case .selectedModelMissing, .selectedModelNotLanguage:
            return .selectedModelUnavailable
        case .loadRequired: return .selectedModelUnloaded
        case .ready: return .ready
        }
    }

    private func activity(
        _ activity: Phase2LocalAIProviderActivity
    ) -> LocalAIProviderSettingsView.Activity {
        switch activity {
        case .idle: return .idle
        case .discovering: return .refreshing
        case .performingLifecycle: return .performingLifecycle
        }
    }

    /// MTPLX does not report a pack size, so an unknown (zero) size shows nothing.
    nonisolated static func sizeDescription(bytesOnDisk: UInt64) -> String {
        guard bytesOnDisk > 0 else { return "" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(min(bytesOnDisk, UInt64(Int64.max))),
            countStyle: .file
        )
    }

    private func models(
        _ snapshot: Phase2LocalAIProviderSnapshot
    ) -> [LocalAIProviderSettingsView.Model] {
        guard let endpoint = snapshot.endpoint else { return [] }
        return snapshot.inventory?.models.map { model in
            .init(
                key: model.key,
                displayName: model.displayName,
                publisher: model.publisher,
                kind: model.type == .language ? .language : .embedding,
                format: model.format?.rawValue.uppercased(),
                quantization: quantizationDescription(model.quantization),
                sizeDescription: Self.sizeDescription(bytesOnDisk: model.sizeBytesOnDisk),
                maximumContextLength: model.maximumContextLength,
                loadedInstances: model.loadedInstances.map { instance in
                    .init(
                        id: instance.id,
                        effectiveContextLength: instance.configuration.effectiveContextLength,
                        isOwnedByMacScope: controller.ownedInstances.contains(.init(
                            profileID: endpoint.profileID,
                            generation: endpoint.generation,
                            modelKey: model.key,
                            instanceID: instance.id
                        ))
                    )
                }
            )
        } ?? []
    }

    private func quantizationDescription(
        _ quantization: Phase2LocalModelQuantization?
    ) -> String? {
        guard let quantization else { return nil }
        if let name = quantization.name, !name.isEmpty { return name }
        if let bits = quantization.bitsPerWeight {
            return "\(bits.formatted()) bits/weight"
        }
        return nil
    }
}
