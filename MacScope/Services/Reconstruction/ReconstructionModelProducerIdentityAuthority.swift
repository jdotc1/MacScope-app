import Foundation

/// Durable MacScope identities which are independent of one model-provider lease.
struct ReconstructionModelProducerIdentityContext: Hashable, Sendable {
    let macScopeBuildIdentity: String
    let macScopeSourceIdentity: String
    let operationIdentity: String
    let registryIdentity: String
    let protocolIdentity: String
    let toolchainIdentity: String?

    /// Derives production receipt context only from the canonical, Release-eligible provenance
    /// resource already sealed into the signed app. No mutable checkout, provider revision,
    /// endpoint generation, absolute path, or newly synthesized digest enters this identity.
    static func production(
        provenance: Phase2QualificationGateBuildProvenance
    ) -> Self {
        let artifacts = Phase2ReconstructionProtocolArtifacts.make()
        return .init(
            // This is the generator's existing SHA-256 over the complete selected build-input
            // closure. The toolchain is bound independently below.
            macScopeBuildIdentity: provenance.selectedBuildInputsSHA256,
            // The canonical Git tree identifies source independently of commit metadata.
            macScopeSourceIdentity: provenance.gitHeadTree,
            operationIdentity: "reconstruction.\(ReconstructionTaskKind.modelRound.rawValue).v1",
            registryIdentity: artifacts.toolRegistry.identity.sha256,
            protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
            // Xcode's build identifier is the existing sealed toolchain coordinate. Detailed
            // compiler/SDK fields remain independently present in the provenance payload.
            toolchainIdentity: provenance.xcodeBuild
        )
    }
}

/// App-only model identity authoring layered over the worker-safe receipt authority.
///
/// Keeping this extension in its own source file prevents the AnalysisWorker target from taking a
/// source dependency on Phase 2 provider configuration and lease types. The durable receipt digest
/// implementation remains shared by every target that validates reconstruction packages.
extension ReconstructionReceiptAuthority {
    static let modelConfigurationIdentitySchemaVersion = 1

    /// Produces the durable model identity from the lease's observed inventory and immutable
    /// configuration. `providerRevision` and endpoint generation intentionally have no path into
    /// this durable authority because both are launch-local connection coordinates.
    static func makeModelProducerIdentity(
        lease: Phase2ReadyInferenceLease,
        context: ReconstructionModelProducerIdentityContext
    ) throws -> ReconstructionProducerIdentity {
        let configuration = lease.configuration
        let configurationSHA256 = try canonicalModelConfigurationSHA256(configuration)
        let provisional = try ReconstructionProducerIdentity(
            macScopeBuildIdentity: context.macScopeBuildIdentity,
            macScopeSourceIdentity: context.macScopeSourceIdentity,
            operationIdentity: context.operationIdentity,
            registryIdentity: context.registryIdentity,
            protocolIdentity: context.protocolIdentity,
            nativeProviderIdentity: nil,
            nativeCapabilityIdentities: [],
            modelKey: configuration.model,
            endpointOrigin: configuration.endpointOrigin,
            observedModelInventorySHA256: lease.observedModelInventorySHA256,
            observedConfigurationSHA256: configurationSHA256,
            toolchainIdentity: context.toolchainIdentity,
            canonicalSHA256: String(repeating: "0", count: 64)
        )
        return try ReconstructionProducerIdentity(
            schemaVersion: provisional.schemaVersion,
            macScopeBuildIdentity: provisional.macScopeBuildIdentity,
            macScopeSourceIdentity: provisional.macScopeSourceIdentity,
            operationIdentity: provisional.operationIdentity,
            registryIdentity: provisional.registryIdentity,
            protocolIdentity: provisional.protocolIdentity,
            nativeProviderIdentity: provisional.nativeProviderIdentity,
            nativeCapabilityIdentities: provisional.nativeCapabilityIdentities,
            modelKey: provisional.modelKey,
            endpointOrigin: provisional.endpointOrigin,
            observedModelInventorySHA256: provisional.observedModelInventorySHA256,
            observedConfigurationSHA256: provisional.observedConfigurationSHA256,
            toolchainIdentity: provisional.toolchainIdentity,
            canonicalSHA256: try ReconstructionEvidenceIntegrity
                .canonicalProducerSHA256(provisional)
        )
    }

    static func canonicalModelConfigurationSHA256(
        _ configuration: Phase2AIProviderConfiguration
    ) throws -> String {
        try Task.checkCancellation()
        return try ReconstructionCanonicalJSON.sha256(
            of: ReconstructionModelConfigurationPreimage(
                schemaVersion: modelConfigurationIdentitySchemaVersion,
                profileID: configuration.profileID,
                endpointOrigin: configuration.endpointOrigin,
                model: configuration.model,
                maximumTokens: configuration.maximumTokens,
                requestTimeoutMilliseconds: configuration.requestTimeoutMilliseconds,
                resourceTimeoutMilliseconds: configuration.resourceTimeoutMilliseconds
            )
        )
    }
}

private struct ReconstructionModelConfigurationPreimage: Encodable {
    let schemaVersion: Int
    let profileID: UUID
    let endpointOrigin: String
    let model: String
    let maximumTokens: Int
    let requestTimeoutMilliseconds: Int
    let resourceTimeoutMilliseconds: Int
}
