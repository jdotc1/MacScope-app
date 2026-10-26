import Foundation

/// Frozen expected inputs for one exact standard profile. The app's non-injectable canonical
/// production-v2 qualification bundle is the sole authority; preflight never discovers,
/// substitutes, or repairs these values.
struct Phase2StandardModelProfileDefinition: Hashable, Sendable {
    /// Exact identity of the non-injectable production qualification definition singleton.
    let productionDefinitionIdentity: Phase2ProtocolComponentIdentity
    let profileVersion: Int
    let provider: Phase2QualifiedProviderIdentity
    let artifact: Phase2ModelArtifactIdentity
    let modelRevisionIdentity: Phase2ProtocolComponentIdentity
    let advertisedMaximumContextLength: Int
    let loadedConfiguration: Phase2LocalModelInstanceConfiguration
    let context: Phase2ContextProfile
    let generation: Phase2GenerationProfile
    let hardwareTier: Phase2HardwareTier
    let workflow: Phase2QualificationWorkflow
    let authorityCeiling: Phase2QualificationAuthorityCeiling
    let toolCallMode: Phase2ToolCallMode
    let structuredOutputMode: Phase2StructuredOutputMode
    let protocolManifest: Phase2ModelProtocolManifest
    /// Injected by the production qualification bundle; preflight only verifies its identity graph.
    let qualificationPolicy: Phase2ModelQualificationPolicy
    let inferenceMaximumTokens: Int
    let protocolProbeCatalogIdentity: Phase2ProtocolComponentIdentity
    let liveCorpusIdentity: Phase2ProtocolComponentIdentity
    let qualificationEnvironment: Phase2QualificationEnvironmentV2
}

/// Provider build evidence already bound by its collector to the process answering this endpoint.
/// A separately installed application version is not a valid substitute.
struct Phase2EndpointBoundProviderObservation: Equatable, Sendable {
    let endpointProfileID: UUID
    let endpointGeneration: UInt64
    let providerRevision: UInt64
    let identity: Phase2QualifiedProviderIdentity
    let runtimeIdentity: Phase2EndpointBoundProviderRuntimeIdentity?
}

struct Phase2LiveQualificationArtifactObservation: Equatable, Sendable {
    let source: String
    let backingDigest: Phase2ModelBackingDigest
    let modelRevision: Phase2ProtocolComponentIdentity
}

/// Immutable inputs captured by the app from one current provider revision.
struct Phase2LiveQualificationPreflightInput: Sendable {
    let standard: Phase2StandardModelProfileDefinition
    let snapshot: Phase2LocalAIProviderSnapshot
    let readyLease: Phase2ReadyInferenceLease?
    let explicitLoadedInstanceID: String?
    let providerObservation: Phase2EndpointBoundProviderObservation?
    let artifactObservation: Phase2LiveQualificationArtifactObservation?
    let contextObservation: Phase2ContextProfile?
    let generationObservation: Phase2GenerationProfile?
    let hardwareObservation: Phase2HardwareTier?
    let protocolManifestObservation: Phase2ModelProtocolManifest?
    let readToolRegistryObservation: Phase2ProtocolComponentIdentity?
    let qualificationPolicyObservation: Phase2ProtocolComponentIdentity?
    let protocolProbeCatalogObservation: Phase2ProtocolComponentIdentity?
    let liveCorpusObservation: Phase2ProtocolComponentIdentity?
    let environmentObservation: Phase2QualificationEnvironmentV2?
}

enum Phase2LiveQualificationPreflightDeficiency: String, Hashable, Sendable {
    case standardContractInvalid = "standard-contract-invalid"
    case providerActivityNotIdle = "provider-activity-not-idle"
    case snapshotEndpointMissing = "snapshot-endpoint-missing"
    case acceptedInventoryMissing = "accepted-inventory-missing"
    case inventoryEndpointIdentityMismatch = "inventory-endpoint-identity-mismatch"
    case desiredSelectionMissing = "desired-selection-missing"
    case desiredSelectionMismatch = "desired-selection-mismatch"
    case authorizedSelectionMissing = "authorized-selection-missing"
    case authorizedSelectionMismatch = "authorized-selection-mismatch"
    case selectedModelMissing = "selected-model-missing"
    case selectedModelNotLanguage = "selected-model-not-language"
    case readyLeaseMissing = "ready-lease-missing"
    case readyLeaseMismatch = "ready-lease-mismatch"
    case loadedInstanceIDMissing = "loaded-instance-id-missing"
    case loadedInstanceAmbiguous = "loaded-instance-ambiguous"
    case loadedInstanceMissing = "loaded-instance-missing"
    case providerObservationMissing = "provider-observation-missing"
    case providerEndpointIdentityMismatch = "provider-endpoint-identity-mismatch"
    case providerRevisionMismatch = "provider-revision-mismatch"
    case providerFamilyMismatch = "provider-family-mismatch"
    case providerBuildMismatch = "provider-build-mismatch"
    case providerAPICompatibilityMismatch = "provider-api-compatibility-mismatch"
    case endpointTransportMismatch = "endpoint-transport-mismatch"
    case providerRuntimeBindingMissing = "provider-runtime-binding-missing"
    case artifactObservationMissing = "artifact-observation-missing"
    case artifactModelKeyMismatch = "artifact-model-key-mismatch"
    case artifactTypeMismatch = "artifact-type-mismatch"
    case artifactSourceMismatch = "artifact-source-mismatch"
    case artifactFormatMismatch = "artifact-format-mismatch"
    case artifactQuantizationMismatch = "artifact-quantization-mismatch"
    case artifactBackingDigestMismatch = "artifact-backing-digest-mismatch"
    case modelRevisionInvalid = "model-revision-invalid"
    case modelRevisionMismatch = "model-revision-mismatch"
    case advertisedContextInsufficient = "advertised-context-insufficient"
    case loadedConfigurationMismatch = "loaded-configuration-mismatch"
    case contextObservationMissing = "context-observation-missing"
    case contextMismatch = "context-mismatch"
    case generationObservationMissing = "generation-observation-missing"
    case generationMismatch = "generation-mismatch"
    case hardwareObservationMissing = "hardware-observation-missing"
    case hardwareMismatch = "hardware-mismatch"
    case protocolManifestObservationMissing = "protocol-manifest-observation-missing"
    case protocolManifestMismatch = "protocol-manifest-mismatch"
    case readToolRegistryObservationMissing = "read-tool-registry-observation-missing"
    case readToolRegistryMismatch = "read-tool-registry-mismatch"
    case qualificationPolicyObservationMissing = "qualification-policy-observation-missing"
    case qualificationPolicyMismatch = "qualification-policy-mismatch"
    case protocolProbeCatalogObservationMissing = "protocol-probe-catalog-observation-missing"
    case protocolProbeCatalogMismatch = "protocol-probe-catalog-mismatch"
    case liveCorpusObservationMissing = "live-corpus-observation-missing"
    case liveCorpusMismatch = "live-corpus-mismatch"
    case environmentObservationMissing = "environment-observation-missing"
    case environmentMismatch = "environment-mismatch"
    case standardProfileConstructionFailed = "standard-profile-construction-failed"
    case constructedProfileNotExact = "constructed-profile-not-exact"
}

struct Phase2LiveQualificationPreflightRejection: Equatable, Sendable {
    let deficiencies: [Phase2LiveQualificationPreflightDeficiency]

    init(deficiencies: [Phase2LiveQualificationPreflightDeficiency]) {
        self.deficiencies = Array(Set(deficiencies)).sorted { $0.rawValue < $1.rawValue }
    }
}

/// Launch-local authority. This value is intentionally neither Codable nor part of profile ID.
struct Phase2LiveQualificationRuntimeBinding: Equatable, Sendable {
    let endpointProfileID: UUID
    let endpointGeneration: UInt64
    let providerRevision: UInt64
    let readyLease: Phase2ReadyInferenceLease
    let modelKey: String
    let loadedInstanceID: String
    let loadedConfiguration: Phase2LocalModelInstanceConfiguration
    let provider: Phase2QualifiedProviderIdentity
    let providerRuntimeIdentity: Phase2EndpointBoundProviderRuntimeIdentity
    let advertisedMaximumContextLength: Int
    let artifactObservation: Phase2LiveQualificationArtifactObservation
}

struct Phase2LiveQualificationEvidenceBinding: Equatable, Sendable {
    let productionDefinition: Phase2ProtocolComponentIdentity
    let readToolRegistry: Phase2ProtocolComponentIdentity
    let qualificationPolicy: Phase2ProtocolComponentIdentity
    let protocolProbeCatalog: Phase2ProtocolComponentIdentity
    let liveCorpus: Phase2ProtocolComponentIdentity
    let environment: Phase2ProtocolComponentIdentity
    let qualificationEnvironment: Phase2QualificationEnvironmentV2
}

struct Phase2PreparedLiveQualification: Equatable, Sendable {
    let profile: Phase2ModelProfile
    let runtimeBinding: Phase2LiveQualificationRuntimeBinding
    let evidenceBinding: Phase2LiveQualificationEvidenceBinding
}

enum Phase2LiveQualificationPreflightResult: Equatable, Sendable {
    case prepared(Phase2PreparedLiveQualification)
    case rejected(Phase2LiveQualificationPreflightRejection)
}

/// Pure fail-closed validation. No branch performs HTTP, XPC, lifecycle, persistence, or UI work.
struct Phase2LiveQualificationPreflight: Sendable {
    private let contract: Phase2QualificationProfileContract

    init(selector: Phase2QualificationProfileSelector = .historicalF4C) {
        contract = .resolve(selector)
    }

    private static let qualificationPolicyID = "phase2.r1.qualification-policy.v2"
    private static let protocolProbeCatalogID = "phase2.r1.protocol-probes.v1"
    private static let environmentID = "phase2.r1.qualification-environment.v2"
    private static let productionLiveCorpusIdentity = Phase2LiveQualificationScenarioCatalog()
        .identity

    func evaluate(
        _ input: Phase2LiveQualificationPreflightInput
    ) -> Phase2LiveQualificationPreflightResult {
        var deficiencies: Set<Phase2LiveQualificationPreflightDeficiency> = []
        let standard = input.standard

        validateStandardContract(standard, deficiencies: &deficiencies)

        guard let endpoint = input.snapshot.endpoint else {
            deficiencies.insert(.snapshotEndpointMissing)
            collectMissingObservations(input, deficiencies: &deficiencies)
            return rejected(deficiencies)
        }
        if input.snapshot.activity != .idle {
            deficiencies.insert(.providerActivityNotIdle)
        }

        let inventory: Phase2LocalModelInventory?
        if case .accepted(let accepted) = input.snapshot.observation {
            inventory = accepted
            if accepted.profileID != endpoint.profileID
                || accepted.generation != endpoint.generation
            {
                deficiencies.insert(.inventoryEndpointIdentityMismatch)
            }
        } else {
            inventory = nil
            deficiencies.insert(.acceptedInventoryMissing)
        }

        validateSelection(input, endpoint: endpoint, deficiencies: &deficiencies)
        validateLease(input, deficiencies: &deficiencies)

        let model = inventory?.models.first { $0.key == standard.artifact.modelKey }
        if inventory != nil, model == nil {
            deficiencies.insert(.selectedModelMissing)
        }
        if let model, model.type != .language {
            deficiencies.insert(.selectedModelNotLanguage)
        }

        let loadedInstance = validateLoadedInstance(
            input,
            model: model,
            deficiencies: &deficiencies
        )
        validateProviderObservation(input, endpoint: endpoint, deficiencies: &deficiencies)
        validateReusableObservations(input, model: model, deficiencies: &deficiencies)
        validateEvidenceObservations(input, deficiencies: &deficiencies)

        guard deficiencies.isEmpty,
              let model,
              let loadedInstance,
              let providerObservation = input.providerObservation,
              let providerRuntimeIdentity = providerObservation.runtimeIdentity,
              let artifactObservation = input.artifactObservation,
              let contextObservation = input.contextObservation,
              let generationObservation = input.generationObservation,
              let hardwareObservation = input.hardwareObservation,
              let manifestObservation = input.protocolManifestObservation,
              let readyLease = input.readyLease,
              let loadedInstanceID = input.explicitLoadedInstanceID,
              let readToolRegistry = input.readToolRegistryObservation,
              let policy = input.qualificationPolicyObservation,
              let probes = input.protocolProbeCatalogObservation,
              let liveCorpus = input.liveCorpusObservation,
              let qualificationEnvironment = input.environmentObservation,
              let environment = try? qualificationEnvironment.contentIdentity()
        else {
            return rejected(deficiencies)
        }

        let factoryObservation = Phase2StandardModelProfileObservation(
            profileVersion: standard.profileVersion,
            provider: providerObservation.identity,
            model: model,
            source: artifactObservation.source,
            backingDigest: artifactObservation.backingDigest,
            loadedConfiguration: loadedInstance.configuration,
            context: contextObservation,
            generation: generationObservation,
            hardwareTier: hardwareObservation,
            workflow: standard.workflow,
            authorityCeiling: standard.authorityCeiling,
            toolCallMode: standard.toolCallMode,
            structuredOutputMode: standard.structuredOutputMode,
            protocolManifest: manifestObservation
        )
        guard case .success(let profile) = Phase2StandardModelProfileFactory()
            .makeProfile(from: factoryObservation)
        else {
            deficiencies.insert(.standardProfileConstructionFailed)
            return rejected(deficiencies)
        }
        guard Phase2ModelProfileMatcher().match(
            profile: profile,
            observedProvider: providerObservation.identity,
            observedSource: artifactObservation.source,
            observedBackingDigest: artifactObservation.backingDigest,
            model: model,
            loadedConfiguration: loadedInstance.configuration
        ) == .exact else {
            deficiencies.insert(.constructedProfileNotExact)
            return rejected(deficiencies)
        }

        return .prepared(.init(
            profile: profile,
            runtimeBinding: .init(
                endpointProfileID: endpoint.profileID,
                endpointGeneration: endpoint.generation,
                providerRevision: providerObservation.providerRevision,
                readyLease: readyLease,
                modelKey: model.key,
                loadedInstanceID: loadedInstanceID,
                loadedConfiguration: loadedInstance.configuration,
                provider: providerObservation.identity,
                providerRuntimeIdentity: providerRuntimeIdentity,
                advertisedMaximumContextLength: model.maximumContextLength,
                artifactObservation: artifactObservation
            ),
            evidenceBinding: .init(
                productionDefinition: standard.productionDefinitionIdentity,
                readToolRegistry: readToolRegistry,
                qualificationPolicy: policy,
                protocolProbeCatalog: probes,
                liveCorpus: liveCorpus,
                environment: environment,
                qualificationEnvironment: qualificationEnvironment
            )
        ))
    }

    private func validateStandardContract(
        _ standard: Phase2StandardModelProfileDefinition,
        deficiencies: inout Set<Phase2LiveQualificationPreflightDeficiency>
    ) {
        let production = contract.production
        let canonicalPolicyIdentity = try? Phase2ModelProfileCanonicalizer()
            .qualificationPolicyIdentity(for: standard.qualificationPolicy)
        let policyIsBound = canonicalPolicyIdentity.map { canonicalPolicyIdentity in
            standard.protocolManifest.qualificationPolicy == canonicalPolicyIdentity
                && standard.qualificationPolicy.version == 2
                && standard.qualificationPolicy.protocolProbeCatalog
                    == standard.protocolProbeCatalogIdentity
                && standard.qualificationPolicy.liveQualificationCorpus
                    == standard.liveCorpusIdentity
                && standard.protocolManifest.version == 2
                && standard.protocolManifest.protocolProbeCatalog
                    == standard.protocolProbeCatalogIdentity
                && standard.protocolManifest.liveQualificationCorpus
                    == standard.liveCorpusIdentity
        } ?? false
        let componentNamesAreFrozen = component(
            standard.protocolManifest.qualificationPolicy,
            hasID: Self.qualificationPolicyID,
            version: 2
        ) && component(
            standard.protocolProbeCatalogIdentity,
            hasID: Self.protocolProbeCatalogID,
            version: 1
        )
        let liveCorpusIsProduction = standard.liveCorpusIdentity
            == Self.productionLiveCorpusIdentity
            && standard.liveCorpusIdentity.id
                == Phase2LiveQualificationScenarioCatalog.catalogID
        let definitionIsProduction = standard.productionDefinitionIdentity
                == production.definitionIdentity
            && standard.protocolProbeCatalogIdentity
                == production.protocolProbeCatalogIdentity
            && standard.liveCorpusIdentity == production.liveScenarioCatalog.identity
            && standard.modelRevisionIdentity == production.modelRevision.identity
            && standard.qualificationPolicy == production.policy
            && canonicalPolicyIdentity == production.policyIdentity
        let environmentIsAvailable = (try? standard.qualificationEnvironment.contentIdentity())
            .map { component($0, hasID: Self.environmentID, version: 2) }
            ?? false
        let hardwarePolicy = Phase2QualificationHardwarePolicy.thisM1Max64GiB
        let environmentMatchesHardwarePolicy = standard.qualificationEnvironment.hardwareModel
            == hardwarePolicy.hardwareModel
            && standard.qualificationEnvironment.processorFamily
                == hardwarePolicy.processorFamily
            && standard.qualificationEnvironment.physicalMemoryBytes
                == hardwarePolicy.physicalMemoryBytes
            && standard.qualificationEnvironment.physicalCoreCount
                == hardwarePolicy.physicalCoreCount
            && standard.qualificationEnvironment.logicalCoreCount
                == hardwarePolicy.logicalCoreCount
            && standard.qualificationEnvironment.performanceCoreCount
                == hardwarePolicy.performanceCoreCount
            && standard.qualificationEnvironment.efficiencyCoreCount
                == hardwarePolicy.efficiencyCoreCount
            && standard.hardwareTier.id == "apple-m1-max-64gb"
            && standard.hardwareTier.version == 1
        let environmentMatchesRequiredPlatform = production.environmentPolicy.accepts(
            standard.qualificationEnvironment
        )
        let modelRevisionIsFrozen = component(
            standard.modelRevisionIdentity,
            hasID: contract.modelRevisionIdentity.id,
            version: 1
        )
        let contextIsExact = standard.inferenceMaximumTokens
            == standard.context.reservedOutputTokens
            && standard.advertisedMaximumContextLength >= standard.context.maximumInputTokens
        let candidateIsExact = contract.selector != .qwen38V2Q6K || (
            standard.artifact.modelKey == "qwen3.8-27b-obliterated"
                && standard.artifact.source == "OBLITERATUS/Qwen3.8-27B-OBLITERATED"
                && standard.artifact.format == .gguf
                && standard.artifact.quantizationName == "Q6_K"
                && standard.artifact.backingDigest == (try? Phase2ModelBackingDigest.sha256(
                    production.modelRevision.localArtifactManifestSHA256
                ))
                && standard.advertisedMaximumContextLength == 262_144
                && standard.loadedConfiguration.effectiveContextLength == 32_768
                && standard.loadedConfiguration.parallelPredictions == 1
                && standard.context.maximumInputTokens == 32_768
                && standard.context.reservedOutputTokens == 4_096
        )
        guard standard.profileVersion > 0,
              standard.artifact.type == .language,
              standard.protocolManifest.isCertificationEligible,
              policyIsBound,
              componentNamesAreFrozen,
              liveCorpusIsProduction,
              definitionIsProduction,
              environmentIsAvailable,
              environmentMatchesHardwarePolicy,
              environmentMatchesRequiredPlatform,
              modelRevisionIsFrozen,
              contextIsExact,
              candidateIsExact
        else {
            deficiencies.insert(.standardContractInvalid)
            return
        }
    }

    private func validateSelection(
        _ input: Phase2LiveQualificationPreflightInput,
        endpoint: Phase2LocalProviderEndpoint,
        deficiencies: inout Set<Phase2LiveQualificationPreflightDeficiency>
    ) {
        let standard = input.standard
        guard let desired = input.snapshot.desiredSelection else {
            deficiencies.insert(.desiredSelectionMissing)
            if input.snapshot.selection == nil {
                deficiencies.insert(.authorizedSelectionMissing)
            }
            return
        }
        if desired.modelKey != standard.artifact.modelKey
            || desired.maximumTokens != standard.inferenceMaximumTokens
        {
            deficiencies.insert(.desiredSelectionMismatch)
        }
        guard let selection = input.snapshot.selection else {
            deficiencies.insert(.authorizedSelectionMissing)
            return
        }
        if selection.profileID != endpoint.profileID
            || selection.generation != endpoint.generation
            || selection.modelKey != standard.artifact.modelKey
            || selection.maximumTokens != standard.inferenceMaximumTokens
        {
            deficiencies.insert(.authorizedSelectionMismatch)
        }
    }

    private func validateLease(
        _ input: Phase2LiveQualificationPreflightInput,
        deficiencies: inout Set<Phase2LiveQualificationPreflightDeficiency>
    ) {
        guard let lease = input.readyLease else {
            deficiencies.insert(.readyLeaseMissing)
            return
        }
        guard lease == input.snapshot.readyInferenceLease,
              lease.configuration.model == input.standard.artifact.modelKey,
              lease.configuration.maximumTokens == input.standard.inferenceMaximumTokens
        else {
            deficiencies.insert(.readyLeaseMismatch)
            return
        }
    }

    private func validateLoadedInstance(
        _ input: Phase2LiveQualificationPreflightInput,
        model: Phase2LocalModelDescriptor?,
        deficiencies: inout Set<Phase2LiveQualificationPreflightDeficiency>
    ) -> Phase2LocalModelLoadedInstance? {
        guard let model else { return nil }
        guard !model.loadedInstances.isEmpty else {
            deficiencies.insert(.loadedInstanceMissing)
            return nil
        }
        guard model.loadedInstances.count == 1 else {
            deficiencies.insert(.loadedInstanceAmbiguous)
            return nil
        }
        guard let instanceID = input.explicitLoadedInstanceID,
              phase2IsBoundedIdentifier(instanceID, maximumBytes: 512)
        else {
            deficiencies.insert(.loadedInstanceIDMissing)
            return nil
        }
        let matches = model.loadedInstances.filter { $0.id == instanceID }
        guard matches.count == 1, let instance = matches.first else {
            deficiencies.insert(matches.count > 1 ? .loadedInstanceAmbiguous : .loadedInstanceMissing)
            return nil
        }
        if instance.configuration != input.standard.loadedConfiguration {
            deficiencies.insert(.loadedConfigurationMismatch)
        }
        return instance
    }

    private func validateProviderObservation(
        _ input: Phase2LiveQualificationPreflightInput,
        endpoint: Phase2LocalProviderEndpoint,
        deficiencies: inout Set<Phase2LiveQualificationPreflightDeficiency>
    ) {
        guard let observation = input.providerObservation else {
            deficiencies.insert(.providerObservationMissing)
            return
        }
        if observation.endpointProfileID != endpoint.profileID
            || observation.endpointGeneration != endpoint.generation
        {
            deficiencies.insert(.providerEndpointIdentityMismatch)
        }
        if observation.providerRevision != input.snapshot.revision {
            deficiencies.insert(.providerRevisionMismatch)
        }
        if observation.identity.family != input.standard.provider.family {
            deficiencies.insert(.providerFamilyMismatch)
        }
        if observation.identity.build != input.standard.provider.build {
            deficiencies.insert(.providerBuildMismatch)
        }
        if observation.identity.apiCompatibility != input.standard.provider.apiCompatibility {
            deficiencies.insert(.providerAPICompatibilityMismatch)
        }
        if observation.identity.endpointTransport != input.standard.provider.endpointTransport {
            deficiencies.insert(.endpointTransportMismatch)
        }
        guard observation.runtimeIdentity != nil else {
            deficiencies.insert(.providerRuntimeBindingMissing)
            return
        }
    }

    private func validateReusableObservations(
        _ input: Phase2LiveQualificationPreflightInput,
        model: Phase2LocalModelDescriptor?,
        deficiencies: inout Set<Phase2LiveQualificationPreflightDeficiency>
    ) {
        let standard = input.standard
        if let model {
            if contract.selector == .qwen38V2Q6K,
               model.publisher != "OBLITERATUS"
                || model.sizeBytesOnDisk != 22_431_004_152
                || model.maximumContextLength != 262_144
            {
                deficiencies.insert(.standardContractInvalid)
            }
            if model.key != standard.artifact.modelKey {
                deficiencies.insert(.artifactModelKeyMismatch)
            }
            if model.type != standard.artifact.type {
                deficiencies.insert(.artifactTypeMismatch)
            }
            if model.format != standard.artifact.format {
                deficiencies.insert(.artifactFormatMismatch)
            }
            if model.quantization?.name != standard.artifact.quantizationName
                || model.quantization?.bitsPerWeight != standard.artifact.bitsPerWeight
            {
                deficiencies.insert(.artifactQuantizationMismatch)
            }
            if model.maximumContextLength < standard.context.maximumInputTokens {
                deficiencies.insert(.advertisedContextInsufficient)
            }
        }
        if let artifact = input.artifactObservation {
            if artifact.source != standard.artifact.source {
                deficiencies.insert(.artifactSourceMismatch)
            }
            if artifact.backingDigest != standard.artifact.backingDigest {
                deficiencies.insert(.artifactBackingDigestMismatch)
            }
            if !component(
                artifact.modelRevision,
                hasID: contract.modelRevisionIdentity.id,
                version: 1
            ) {
                deficiencies.insert(.modelRevisionInvalid)
            }
            if artifact.modelRevision != standard.modelRevisionIdentity {
                deficiencies.insert(.modelRevisionMismatch)
            }
        } else {
            deficiencies.insert(.artifactObservationMissing)
        }
        compare(
            input.contextObservation,
            expected: standard.context,
            missing: .contextObservationMissing,
            mismatch: .contextMismatch,
            deficiencies: &deficiencies
        )
        compare(
            input.generationObservation,
            expected: standard.generation,
            missing: .generationObservationMissing,
            mismatch: .generationMismatch,
            deficiencies: &deficiencies
        )
        compare(
            input.hardwareObservation,
            expected: standard.hardwareTier,
            missing: .hardwareObservationMissing,
            mismatch: .hardwareMismatch,
            deficiencies: &deficiencies
        )
        compare(
            input.protocolManifestObservation,
            expected: standard.protocolManifest,
            missing: .protocolManifestObservationMissing,
            mismatch: .protocolManifestMismatch,
            deficiencies: &deficiencies
        )
    }

    private func validateEvidenceObservations(
        _ input: Phase2LiveQualificationPreflightInput,
        deficiencies: inout Set<Phase2LiveQualificationPreflightDeficiency>
    ) {
        compare(
            input.readToolRegistryObservation,
            expected: input.standard.protocolManifest.readToolRegistry,
            missing: .readToolRegistryObservationMissing,
            mismatch: .readToolRegistryMismatch,
            deficiencies: &deficiencies
        )
        compare(
            input.qualificationPolicyObservation,
            expected: input.standard.protocolManifest.qualificationPolicy,
            missing: .qualificationPolicyObservationMissing,
            mismatch: .qualificationPolicyMismatch,
            deficiencies: &deficiencies
        )
        compare(
            input.protocolProbeCatalogObservation,
            expected: input.standard.protocolProbeCatalogIdentity,
            missing: .protocolProbeCatalogObservationMissing,
            mismatch: .protocolProbeCatalogMismatch,
            deficiencies: &deficiencies
        )
        compare(
            input.liveCorpusObservation,
            expected: input.standard.liveCorpusIdentity,
            missing: .liveCorpusObservationMissing,
            mismatch: .liveCorpusMismatch,
            deficiencies: &deficiencies
        )
        guard let environmentObservation = input.environmentObservation else {
            deficiencies.insert(.environmentObservationMissing)
            return
        }
        if environmentObservation != input.standard.qualificationEnvironment
            || (try? environmentObservation.contentIdentity()) == nil
        {
            deficiencies.insert(.environmentMismatch)
        }
    }

    private func collectMissingObservations(
        _ input: Phase2LiveQualificationPreflightInput,
        deficiencies: inout Set<Phase2LiveQualificationPreflightDeficiency>
    ) {
        if input.readyLease == nil { deficiencies.insert(.readyLeaseMissing) }
        if input.providerObservation == nil { deficiencies.insert(.providerObservationMissing) }
        if input.artifactObservation == nil { deficiencies.insert(.artifactObservationMissing) }
        if input.contextObservation == nil { deficiencies.insert(.contextObservationMissing) }
        if input.generationObservation == nil { deficiencies.insert(.generationObservationMissing) }
        if input.hardwareObservation == nil { deficiencies.insert(.hardwareObservationMissing) }
        if input.protocolManifestObservation == nil {
            deficiencies.insert(.protocolManifestObservationMissing)
        }
        if input.readToolRegistryObservation == nil {
            deficiencies.insert(.readToolRegistryObservationMissing)
        }
        if input.qualificationPolicyObservation == nil {
            deficiencies.insert(.qualificationPolicyObservationMissing)
        }
        if input.protocolProbeCatalogObservation == nil {
            deficiencies.insert(.protocolProbeCatalogObservationMissing)
        }
        if input.liveCorpusObservation == nil { deficiencies.insert(.liveCorpusObservationMissing) }
        if input.environmentObservation == nil { deficiencies.insert(.environmentObservationMissing) }
    }

    private func compare<Value: Equatable>(
        _ observation: Value?,
        expected: Value,
        missing: Phase2LiveQualificationPreflightDeficiency,
        mismatch: Phase2LiveQualificationPreflightDeficiency,
        deficiencies: inout Set<Phase2LiveQualificationPreflightDeficiency>
    ) {
        guard let observation else {
            deficiencies.insert(missing)
            return
        }
        if observation != expected {
            deficiencies.insert(mismatch)
        }
    }

    private func component(
        _ identity: Phase2ProtocolComponentIdentity,
        hasID id: String,
        version: Int
    ) -> Bool {
        identity.id == id
            && identity.version == version
            && identity.availability == .available
            && identity.sha256 != nil
    }

    private func rejected(
        _ deficiencies: Set<Phase2LiveQualificationPreflightDeficiency>
    ) -> Phase2LiveQualificationPreflightResult {
        .rejected(.init(deficiencies: Array(deficiencies)))
    }
}

/// A second, independently collected observation made immediately before or after a live phase.
/// The runner owns collection and timing; this value and its matcher remain pure and reusable.
struct Phase2LiveQualificationFreshObservation: Sendable {
    let snapshot: Phase2LocalAIProviderSnapshot
    let readyLease: Phase2ReadyInferenceLease
    let explicitLoadedInstanceID: String
    let providerObservation: Phase2EndpointBoundProviderObservation
    let artifactObservation: Phase2LiveQualificationArtifactObservation
    let contextObservation: Phase2ContextProfile
    let generationObservation: Phase2GenerationProfile
    let hardwareObservation: Phase2HardwareTier
    let productionDefinitionObservation: Phase2ProtocolComponentIdentity
    let protocolManifestObservation: Phase2ModelProtocolManifest
    let readToolRegistryObservation: Phase2ProtocolComponentIdentity
    let qualificationPolicyObservation: Phase2ProtocolComponentIdentity
    let protocolProbeCatalogObservation: Phase2ProtocolComponentIdentity
    let liveCorpusObservation: Phase2ProtocolComponentIdentity
    let environmentObservation: Phase2QualificationEnvironmentV2
}

enum Phase2LiveQualificationFreshnessDeficiency: String, Hashable, Sendable {
    case loadedInstanceMismatch = "loaded-instance-mismatch"
    case loadedInstanceMultiplicityMismatch = "loaded-instance-multiplicity-mismatch"
    case loadedConfigurationMismatch = "loaded-configuration-mismatch"
    case advertisedContextMismatch = "advertised-context-mismatch"
    case modelKeyMismatch = "model-key-mismatch"
    case modelTypeMismatch = "model-type-mismatch"
    case modelFormatMismatch = "model-format-mismatch"
    case modelQuantizationMismatch = "model-quantization-mismatch"
    case contextMismatch = "context-mismatch"
    case hardwareTierMismatch = "hardware-tier-mismatch"
    case productionDefinitionMismatch = "production-definition-mismatch"
    case endpointIdentityMismatch = "endpoint-identity-mismatch"
    case providerRevisionMismatch = "provider-revision-mismatch"
    case providerIdentityMismatch = "provider-identity-mismatch"
    case readyLeaseMismatch = "ready-lease-mismatch"
    case providerProcessStartMismatch = "provider-process-start-mismatch"
    case providerEndpointBindingMismatch = "provider-endpoint-binding-mismatch"
    case providerExecutableBuildMismatch = "provider-executable-build-mismatch"
    case providerAPIProbeMismatch = "provider-api-probe-mismatch"
    case modelArtifactMismatch = "model-artifact-mismatch"
    case modelRevisionMismatch = "model-revision-mismatch"
    case generationMismatch = "generation-mismatch"
    case protocolManifestMismatch = "protocol-manifest-mismatch"
    case readToolRegistryMismatch = "read-tool-registry-mismatch"
    case qualificationPolicyMismatch = "qualification-policy-mismatch"
    case protocolProbeCatalogMismatch = "protocol-probe-catalog-mismatch"
    case liveCorpusMismatch = "live-corpus-mismatch"
    case environmentMismatch = "environment-mismatch"
}

struct Phase2LiveQualificationFreshnessResult: Equatable, Sendable {
    let deficiencies: [Phase2LiveQualificationFreshnessDeficiency]

    var isCurrent: Bool { deficiencies.isEmpty }

    init(deficiencies: Set<Phase2LiveQualificationFreshnessDeficiency>) {
        self.deficiencies = deficiencies.sorted { $0.rawValue < $1.rawValue }
    }
}

/// Exact no-I/O comparison used at each runner revalidation boundary. Any missing, ambiguous, or
/// changed run-critical observation fails closed instead of attempting to repair authority.
struct Phase2LiveQualificationFreshObservationMatcher: Sendable {
    private let contract: Phase2QualificationProfileContract

    init(selector: Phase2QualificationProfileSelector = .historicalF4C) {
        contract = .resolve(selector)
    }

    func compare(
        prepared: Phase2PreparedLiveQualification,
        observation: Phase2LiveQualificationFreshObservation
    ) -> Phase2LiveQualificationFreshnessResult {
        var deficiencies: Set<Phase2LiveQualificationFreshnessDeficiency> = []
        let runtime = prepared.runtimeBinding
        let evidence = prepared.evidenceBinding
        let provider = observation.providerObservation
        let inventoryEndpointMatches: Bool
        if case .accepted(let inventory) = observation.snapshot.observation {
            inventoryEndpointMatches = inventory.profileID == runtime.endpointProfileID
                && inventory.generation == runtime.endpointGeneration
        } else {
            inventoryEndpointMatches = false
        }

        if observation.snapshot.endpoint?.profileID != runtime.endpointProfileID
            || observation.snapshot.endpoint?.generation != runtime.endpointGeneration
            || provider.endpointProfileID != runtime.endpointProfileID
            || provider.endpointGeneration != runtime.endpointGeneration
            || !inventoryEndpointMatches
        {
            deficiencies.insert(.endpointIdentityMismatch)
        }
        if observation.snapshot.revision != runtime.providerRevision
            || provider.providerRevision != runtime.providerRevision
        {
            deficiencies.insert(.providerRevisionMismatch)
        }
        if provider.identity != runtime.provider {
            deficiencies.insert(.providerIdentityMismatch)
        }
        if observation.readyLease != runtime.readyLease
            || observation.snapshot.readyInferenceLease != runtime.readyLease
        {
            deficiencies.insert(.readyLeaseMismatch)
        }

        let freshModel = acceptedModel(
            in: observation.snapshot,
            modelKey: runtime.modelKey
        )
        if observation.explicitLoadedInstanceID != runtime.loadedInstanceID {
            deficiencies.insert(.loadedInstanceMismatch)
        }
        if let freshModel {
            if contract.selector == .qwen38V2Q6K,
               freshModel.publisher != "OBLITERATUS"
                || freshModel.sizeBytesOnDisk != 22_431_004_152
                || freshModel.maximumContextLength != 262_144
            {
                deficiencies.insert(.modelArtifactMismatch)
            }
            let loadedInstances = freshModel.loadedInstances
            if loadedInstances.count != 1 {
                deficiencies.insert(.loadedInstanceMultiplicityMismatch)
            } else if let instance = loadedInstances.first {
                if instance.id != runtime.loadedInstanceID {
                    deficiencies.insert(.loadedInstanceMismatch)
                }
                if instance.configuration != runtime.loadedConfiguration {
                    deficiencies.insert(.loadedConfigurationMismatch)
                }
            }
            if freshModel.maximumContextLength != runtime.advertisedMaximumContextLength {
                deficiencies.insert(.advertisedContextMismatch)
            }

            let observedConfiguration = loadedInstances.count == 1
                ? loadedInstances[0].configuration
                : runtime.loadedConfiguration
            if case .mismatch(let mismatches) = Phase2ModelProfileMatcher().match(
                profile: prepared.profile,
                observedProvider: provider.identity,
                observedSource: observation.artifactObservation.source,
                observedBackingDigest: observation.artifactObservation.backingDigest,
                model: freshModel,
                loadedConfiguration: observedConfiguration
            ) {
                mapProfileMismatches(mismatches, into: &deficiencies)
            }
        } else {
            deficiencies.insert(.modelKeyMismatch)
        }

        if provider.runtimeIdentity?.endpoint != runtime.providerRuntimeIdentity.endpoint {
            deficiencies.insert(.providerEndpointBindingMismatch)
        }
        if provider.runtimeIdentity?.processStart != runtime.providerRuntimeIdentity.processStart {
            deficiencies.insert(.providerProcessStartMismatch)
        }
        if provider.runtimeIdentity?.executableBuild
            != runtime.providerRuntimeIdentity.executableBuild
        {
            deficiencies.insert(.providerExecutableBuildMismatch)
        }
        if provider.runtimeIdentity?.apiProbe != runtime.providerRuntimeIdentity.apiProbe {
            deficiencies.insert(.providerAPIProbeMismatch)
        }

        if observation.artifactObservation.source != runtime.artifactObservation.source
            || observation.artifactObservation.backingDigest
                != runtime.artifactObservation.backingDigest
        {
            deficiencies.insert(.modelArtifactMismatch)
        }
        if observation.artifactObservation.modelRevision
            != runtime.artifactObservation.modelRevision
        {
            deficiencies.insert(.modelRevisionMismatch)
        }
        if observation.contextObservation != prepared.profile.context {
            deficiencies.insert(.contextMismatch)
        }
        if observation.generationObservation != prepared.profile.generation {
            deficiencies.insert(.generationMismatch)
        }
        if observation.hardwareObservation != prepared.profile.hardwareTier {
            deficiencies.insert(.hardwareTierMismatch)
        }
        if observation.productionDefinitionObservation != evidence.productionDefinition
            || observation.productionDefinitionObservation
                != contract.definitionIdentity
        {
            deficiencies.insert(.productionDefinitionMismatch)
        }
        if observation.protocolManifestObservation != prepared.profile.protocolManifest {
            deficiencies.insert(.protocolManifestMismatch)
        }
        if observation.readToolRegistryObservation != evidence.readToolRegistry {
            deficiencies.insert(.readToolRegistryMismatch)
        }
        if observation.qualificationPolicyObservation != evidence.qualificationPolicy {
            deficiencies.insert(.qualificationPolicyMismatch)
        }
        if observation.protocolProbeCatalogObservation != evidence.protocolProbeCatalog {
            deficiencies.insert(.protocolProbeCatalogMismatch)
        }
        if observation.liveCorpusObservation != evidence.liveCorpus {
            deficiencies.insert(.liveCorpusMismatch)
        }
        if observation.environmentObservation != evidence.qualificationEnvironment
            || (try? observation.environmentObservation.contentIdentity()) != evidence.environment
        {
            deficiencies.insert(.environmentMismatch)
        }

        return .init(deficiencies: deficiencies)
    }

    private func mapProfileMismatches(
        _ mismatches: [Phase2ModelProfileMismatch],
        into deficiencies: inout Set<Phase2LiveQualificationFreshnessDeficiency>
    ) {
        for mismatch in mismatches {
            switch mismatch {
            case .providerFamily, .providerBuild, .providerAPICompatibility,
                    .endpointTransport:
                deficiencies.insert(.providerIdentityMismatch)
            case .modelType:
                deficiencies.insert(.modelTypeMismatch)
            case .modelKey:
                deficiencies.insert(.modelKeyMismatch)
            case .modelSource, .backingDigest:
                deficiencies.insert(.modelArtifactMismatch)
            case .modelFormat:
                deficiencies.insert(.modelFormatMismatch)
            case .quantization:
                deficiencies.insert(.modelQuantizationMismatch)
            case .advertisedContext:
                deficiencies.insert(.advertisedContextMismatch)
            case .loadedConfiguration:
                deficiencies.insert(.loadedConfigurationMismatch)
            }
        }
    }

    private func acceptedModel(
        in snapshot: Phase2LocalAIProviderSnapshot,
        modelKey: String
    ) -> Phase2LocalModelDescriptor? {
        guard case .accepted(let inventory) = snapshot.observation else { return nil }
        return inventory.models.first { $0.key == modelKey }
    }
}
