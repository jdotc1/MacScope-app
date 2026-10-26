import Foundation

/// App-owned translation for the separate, connection-scoped configuration control plane.
struct Phase2AIWorkerConfigurationAppCodec: Sendable {
    private let wireCodec: Phase2AIWorkerConfigurationWireCodec

    init(wireCodec: Phase2AIWorkerConfigurationWireCodec = .init()) {
        self.wireCodec = wireCodec
    }

    func encodeConfiguration(
        _ configuration: Phase2AIProviderConfiguration,
        protocolBundle: Phase2AIWorkerProductionProtocolBundle =
            Phase2AIWorkerProductionProtocol.standard
    ) throws -> Data {
        guard protocolBundle == Phase2AIWorkerProductionProtocol.standard
                || protocolBundle == Phase2AIWorkerProductionProtocol.assistantR2
                || protocolBundle == Phase2AIWorkerProductionProtocol.assistantR3
                || protocolBundle == Phase2AIWorkerProductionProtocol.assistantR4
                || protocolBundle == Phase2AIWorkerProductionProtocol.reconstructionR1
                || protocolBundle == Phase2AIWorkerProductionProtocol.reconstructionR2
                || protocolBundle == Phase2AIWorkerProductionProtocol.reconstructionSourceV10 else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        let manifestDigest = protocolBundle.manifestDigest
        return try wireCodec.encodeConfiguration(
            .init(
                schemaVersion: Phase2AIWorkerConfigurationWireCodec.schemaVersion,
                profileID: configuration.profileID,
                generation: configuration.generation,
                endpointOrigin: configuration.endpointOrigin,
                model: configuration.model,
                protocolManifestDigest: manifestDigest,
                maximumTokens: configuration.maximumTokens,
                requestTimeoutMilliseconds: configuration.requestTimeoutMilliseconds,
                resourceTimeoutMilliseconds: configuration.resourceTimeoutMilliseconds,
                inferencePolicy: configuration.inferencePolicy
            )
        )
    }

    func decodeAcknowledgement(
        _ data: Data
    ) throws -> Phase2AIWorkerConfigurationAcknowledgement {
        try wireCodec.decodeAcknowledgement(data)
    }
}
