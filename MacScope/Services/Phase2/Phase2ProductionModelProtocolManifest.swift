import Foundation

extension Phase2ModelProtocolManifest {
    /// Exact active F4C read-only protocol authorized for the app/worker connection.
    ///
    /// The app independently constructs and canonicalizes this manifest from the shared bundle's
    /// content-addressed components. Core tests separately prove that the prompt, schema, tool, and
    /// probe identities equal the executable worker artifacts. No provider or runtime input can
    /// substitute any part of the production protocol.
    static let productionGroundedReadOnly: Self = {
        let standard = Phase2AIWorkerProductionProtocol.standard
        let manifest = try! Self(
            version: 2,
            promptModules: standard.promptModules.map(appComponent),
            finalOutputSchema: appComponent(standard.finalOutputSchema),
            groundedContext: appComponent(standard.groundedContext),
            readToolRegistry: appComponent(standard.readToolRegistry),
            inferenceTransport: appComponent(standard.inferenceTransport),
            generationPolicy: appComponent(standard.generationPolicy),
            protocolProbeCatalog: appComponent(standard.protocolProbeCatalog!),
            liveQualificationCorpus: appComponent(standard.liveQualificationCorpus!),
            qualificationPolicy: appComponent(standard.qualificationPolicy),
            workflowAuthorityPolicy: appComponent(standard.workflowAuthorityPolicy)
        )
        requireCanonicalMatch(manifest, bundle: standard)
        return manifest
    }()

    /// Accepted F4B manifest retained solely so historical qualification evidence remains
    /// reproducible after F4C activation. Runtime negotiation never selects this manifest.
    static let acceptedF4BGroundedReadOnly: Self = {
        let accepted = Phase2AIWorkerProductionProtocol.acceptedF4BAudit
        let manifest = try! Self(
            promptModules: accepted.promptModules.map(appComponent),
            finalOutputSchema: appComponent(accepted.finalOutputSchema),
            groundedContext: appComponent(accepted.groundedContext),
            readToolRegistry: appComponent(accepted.readToolRegistry),
            inferenceTransport: appComponent(accepted.inferenceTransport),
            generationPolicy: appComponent(accepted.generationPolicy),
            qualificationPolicy: appComponent(accepted.qualificationPolicy),
            workflowAuthorityPolicy: appComponent(accepted.workflowAuthorityPolicy)
        )
        requireCanonicalMatch(manifest, bundle: accepted)
        return manifest
    }()

    /// Exact connection manifest for the separate Reconstruction R1 protocol.
    ///
    /// Reconstruction intentionally does not inhabit the persisted Assistant model-profile
    /// manifest: it has independent round and final schemas plus a tool-schema-set identity.
    /// This app-side view nevertheless freezes the complete bundle selected on the signed XPC
    /// connection and gives qualification/tests one canonical component inventory.
    static let productionReconstructionR1: Phase2ReconstructionModelProtocolManifest = {
        Phase2ReconstructionModelProtocolManifest(
            bundle: Phase2AIWorkerProductionProtocol.reconstructionR1
        )
    }()
    static let productionReconstructionSourceV10 = Phase2ReconstructionModelProtocolManifest(
        bundle: Phase2AIWorkerProductionProtocol.reconstructionSourceV10
    )
    static let productionReconstructionR2 = Phase2ReconstructionModelProtocolManifest(
        bundle: Phase2AIWorkerProductionProtocol.reconstructionR2
    )
}

/// App-side immutable view of the complete Reconstruction R1 connection authority.
///
/// This is deliberately separate from `Phase2ModelProtocolManifest`, whose v1/v2 shape is durable
/// Assistant qualification state. Adding Reconstruction-only fields to that type would change
/// historical profile semantics and package identities.
struct Phase2ReconstructionModelProtocolManifest: Equatable, Sendable {
    let manifestVersion: Int
    let promptModules: [Phase2AIWorkerProtocolComponentIdentity]
    let toolSchemaSet: Phase2AIWorkerProtocolComponentIdentity
    let roundOutputSchema: Phase2AIWorkerProtocolComponentIdentity
    let finalOutputSchema: Phase2AIWorkerProtocolComponentIdentity
    let groundedContext: Phase2AIWorkerProtocolComponentIdentity
    let readToolRegistry: Phase2AIWorkerProtocolComponentIdentity
    let inferenceTransport: Phase2AIWorkerProtocolComponentIdentity
    let generationPolicy: Phase2AIWorkerProtocolComponentIdentity
    let manifestDigest: String

    fileprivate init(bundle: Phase2AIWorkerProductionProtocolBundle) {
        precondition(bundle == Phase2AIWorkerProductionProtocol.reconstructionR1
                     || bundle == Phase2AIWorkerProductionProtocol.reconstructionR2
                     || bundle == Phase2AIWorkerProductionProtocol.reconstructionSourceV10)
        precondition(bundle.protocolProbeCatalog == nil && bundle.liveQualificationCorpus == nil)
        precondition(bundle.toolSchemaSet != nil && bundle.roundOutputSchema != nil)

        manifestVersion = bundle.manifestVersion
        promptModules = bundle.promptModules
        toolSchemaSet = bundle.toolSchemaSet!
        roundOutputSchema = bundle.roundOutputSchema!
        finalOutputSchema = bundle.finalOutputSchema
        groundedContext = bundle.groundedContext
        readToolRegistry = bundle.readToolRegistry
        inferenceTransport = bundle.inferenceTransport
        generationPolicy = bundle.generationPolicy
        manifestDigest = bundle.manifestDigest
    }
}

private func appComponent(
    _ identity: Phase2AIWorkerProtocolComponentIdentity
) -> Phase2ProtocolComponentIdentity {
    // Shared constants are compile-time-owned valid categorical IDs and SHA-256 digests.
    try! .init(id: identity.id, version: identity.version, sha256: identity.sha256)
}

private func workerComponent(
    _ identity: Phase2ProtocolComponentIdentity
) -> Phase2AIWorkerProtocolComponentIdentity {
    precondition(identity.availability == .available && identity.sha256 != nil)
    return .init(id: identity.id, version: identity.version, sha256: identity.sha256!)
}

private func requireCanonicalMatch(
    _ manifest: Phase2ModelProtocolManifest,
    bundle: Phase2AIWorkerProductionProtocolBundle
) {
    precondition(manifest.version == bundle.manifestVersion)
    precondition(manifest.promptModules.map(workerComponent) == bundle.promptModules)
    precondition(workerComponent(manifest.finalOutputSchema) == bundle.finalOutputSchema)
    precondition(workerComponent(manifest.groundedContext) == bundle.groundedContext)
    precondition(workerComponent(manifest.readToolRegistry) == bundle.readToolRegistry)
    precondition(workerComponent(manifest.inferenceTransport) == bundle.inferenceTransport)
    precondition(workerComponent(manifest.generationPolicy) == bundle.generationPolicy)
    precondition(
        manifest.protocolProbeCatalog.map(workerComponent) == bundle.protocolProbeCatalog
    )
    precondition(
        manifest.liveQualificationCorpus.map(workerComponent) == bundle.liveQualificationCorpus
    )
    precondition(workerComponent(manifest.qualificationPolicy) == bundle.qualificationPolicy)
    precondition(
        workerComponent(manifest.workflowAuthorityPolicy) == bundle.workflowAuthorityPolicy
    )
    precondition(
        Phase2ModelProfileCanonicalizer().protocolManifestDigest(for: manifest)
            == bundle.manifestDigest
    )
}
