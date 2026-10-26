import Foundation

enum Phase2QualificationRuntimeProvenanceValidationError: Error, Equatable, Sendable {
    case invalidRevision
    case invalidDigest
    case invalidTimeRange
    case invalidScope
}

struct Phase2EndpointBoundProviderRuntimeIdentity: Hashable, Sendable {
    let endpoint: Phase2ProtocolComponentIdentity
    let processStart: Phase2ProtocolComponentIdentity
    let executableBuild: Phase2ProtocolComponentIdentity
    let apiProbe: Phase2ProtocolComponentIdentity

    init(
        endpoint: Phase2ProtocolComponentIdentity,
        processStart: Phase2ProtocolComponentIdentity,
        executableBuild: Phase2ProtocolComponentIdentity,
        apiProbe: Phase2ProtocolComponentIdentity
    ) throws {
        let expected = [
            (endpoint, "phase2.r1.provider-endpoint.v1"),
            (processStart, "phase2.r1.provider-process-start.v1"),
            (executableBuild, "phase2.r1.provider-executable-build.v1"),
            (apiProbe, "phase2.r1.provider-api-probe.v1"),
        ]
        guard expected.allSatisfy({ identity, id in
            identity.id == id && identity.version == 1
                && identity.availability == .available && identity.sha256 != nil
        }) else { throw Phase2QualificationRuntimeProvenanceValidationError.invalidScope }
        self.endpoint = endpoint
        self.processStart = processStart
        self.executableBuild = executableBuild
        self.apiProbe = apiProbe
    }

    func contentIdentity() throws -> Phase2ProtocolComponentIdentity {
        func object(_ value: Phase2ProtocolComponentIdentity) -> [String: Any] {
            ["id": value.id, "sha256": value.sha256!, "version": value.version]
        }
        return try Phase2QualificationV2Identity.make(
            id: "phase2.r1.endpoint-bound-provider-runtime.v1", version: 1,
            object: [
                "api_probe": object(apiProbe),
                "endpoint": object(endpoint),
                "executable_build": object(executableBuild),
                "process_start": object(processStart),
            ]
        )
    }
}

/// Launch-local binding for one exact qualification run. UUIDs and revisions are evidence here;
/// they do not enter the reusable model-profile identity.
struct Phase2QualificationRuntimeProvenance: Hashable, Sendable {
    let endpointProfileID: UUID
    let endpointGeneration: UInt64
    let providerRevision: UInt64
    let modelSource: String
    let modelRevisionIdentity: Phase2ProtocolComponentIdentity
    let productionDefinitionIdentity: Phase2ProtocolComponentIdentity
    let modelKeyIdentityDigest: String
    let loadedInstanceIdentityDigest: String
    let loadedConfigurationIdentityDigest: String
    let providerBuildObservationDigest: String
    let providerRuntimeIdentity: Phase2EndpointBoundProviderRuntimeIdentity
    let workerManifestDigest: String
    let measurementScopeIdentity: Phase2ProtocolComponentIdentity
    let startedAtEpochMilliseconds: Int64
    let endedAtEpochMilliseconds: Int64

    init(
        endpointProfileID: UUID,
        endpointGeneration: UInt64,
        providerRevision: UInt64,
        modelSource: String,
        modelRevisionIdentity: Phase2ProtocolComponentIdentity,
        productionDefinitionIdentity: Phase2ProtocolComponentIdentity,
        modelKeyIdentityDigest: String,
        loadedInstanceIdentityDigest: String,
        loadedConfigurationIdentityDigest: String,
        providerBuildObservationDigest: String,
        providerRuntimeIdentity: Phase2EndpointBoundProviderRuntimeIdentity,
        workerManifestDigest: String,
        measurementScopeIdentity: Phase2ProtocolComponentIdentity,
        startedAtEpochMilliseconds: Int64,
        endedAtEpochMilliseconds: Int64
    ) throws {
        guard endpointGeneration > 0, endpointGeneration <= UInt64(Int64.max),
              providerRevision > 0, providerRevision <= UInt64(Int64.max)
        else { throw Phase2QualificationRuntimeProvenanceValidationError.invalidRevision }
        guard phase2IsModelSource(modelSource),
              Self.isAvailable(
                  modelRevisionIdentity,
                  id: "phase2.r1.qwen3-coder-30b-a3b-instruct-8bit.model-revision.v1"
              ),
              Self.isAvailable(
                  productionDefinitionIdentity,
                  id: "phase2.r1.standard-qualification-definition.v1"
              )
        else { throw Phase2QualificationRuntimeProvenanceValidationError.invalidScope }
        guard [modelKeyIdentityDigest, loadedInstanceIdentityDigest,
               loadedConfigurationIdentityDigest, providerBuildObservationDigest,
               workerManifestDigest].allSatisfy(phase2IsSHA256Hex)
        else { throw Phase2QualificationRuntimeProvenanceValidationError.invalidDigest }
        guard measurementScopeIdentity.availability == .available,
              measurementScopeIdentity.sha256 != nil
        else { throw Phase2QualificationRuntimeProvenanceValidationError.invalidScope }
        guard startedAtEpochMilliseconds >= 0,
              endedAtEpochMilliseconds >= startedAtEpochMilliseconds
        else { throw Phase2QualificationRuntimeProvenanceValidationError.invalidTimeRange }

        self.endpointProfileID = endpointProfileID
        self.endpointGeneration = endpointGeneration
        self.providerRevision = providerRevision
        self.modelSource = modelSource
        self.modelRevisionIdentity = modelRevisionIdentity
        self.productionDefinitionIdentity = productionDefinitionIdentity
        self.modelKeyIdentityDigest = modelKeyIdentityDigest
        self.loadedInstanceIdentityDigest = loadedInstanceIdentityDigest
        self.loadedConfigurationIdentityDigest = loadedConfigurationIdentityDigest
        self.providerBuildObservationDigest = providerBuildObservationDigest
        self.providerRuntimeIdentity = providerRuntimeIdentity
        self.workerManifestDigest = workerManifestDigest
        self.measurementScopeIdentity = measurementScopeIdentity
        self.startedAtEpochMilliseconds = startedAtEpochMilliseconds
        self.endedAtEpochMilliseconds = endedAtEpochMilliseconds
    }

    func contentIdentity() throws -> Phase2ProtocolComponentIdentity {
        try Phase2QualificationV2Identity.make(
            id: "phase2.r1.qualification-runtime-provenance.v3",
            version: 3,
            object: [
                "ended_at_epoch_milliseconds": endedAtEpochMilliseconds,
                "endpoint_generation": Int64(endpointGeneration),
                "endpoint_profile_id": endpointProfileID.uuidString.uppercased(),
                "endpoint_bound_provider_runtime": component(
                    try providerRuntimeIdentity.contentIdentity()
                ),
                "loaded_configuration_identity_digest": loadedConfigurationIdentityDigest,
                "loaded_instance_identity_digest": loadedInstanceIdentityDigest,
                "measurement_scope": [
                    "id": measurementScopeIdentity.id,
                    "sha256": measurementScopeIdentity.sha256!,
                    "version": measurementScopeIdentity.version,
                ],
                "model_key_identity_digest": modelKeyIdentityDigest,
                "model_revision": component(modelRevisionIdentity),
                "model_source": modelSource,
                "production_qualification_definition": component(
                    productionDefinitionIdentity
                ),
                "provider_build_observation_digest": providerBuildObservationDigest,
                "provider_revision": Int64(providerRevision),
                "started_at_epoch_milliseconds": startedAtEpochMilliseconds,
                "worker_manifest_digest": workerManifestDigest,
            ]
        )
    }

    private func component(_ identity: Phase2ProtocolComponentIdentity) -> [String: Any] {
        ["id": identity.id, "sha256": identity.sha256!, "version": identity.version]
    }

    private static func isAvailable(
        _ identity: Phase2ProtocolComponentIdentity,
        id: String
    ) -> Bool {
        identity.id == id
            && identity.version == 1
            && identity.availability == .available
            && identity.sha256 != nil
    }
}
