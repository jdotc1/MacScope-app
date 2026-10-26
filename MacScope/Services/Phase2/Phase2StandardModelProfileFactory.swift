import Foundation

/// The complete, authoritative input needed to construct one reusable model profile.
/// Runtime endpoint, revision, lease, and loaded-instance identities are deliberately absent.
struct Phase2StandardModelProfileObservation: Hashable, Sendable {
    let profileVersion: Int
    let provider: Phase2QualifiedProviderIdentity
    let model: Phase2LocalModelDescriptor
    let source: String
    let backingDigest: Phase2ModelBackingDigest
    let loadedConfiguration: Phase2LocalModelInstanceConfiguration
    let context: Phase2ContextProfile
    let generation: Phase2GenerationProfile
    let hardwareTier: Phase2HardwareTier
    let workflow: Phase2QualificationWorkflow
    let authorityCeiling: Phase2QualificationAuthorityCeiling
    let toolCallMode: Phase2ToolCallMode
    let structuredOutputMode: Phase2StructuredOutputMode
    let protocolManifest: Phase2ModelProtocolManifest
}

enum Phase2StandardModelProfileFactoryError: String, Error, Equatable, Sendable {
    case modelNotLanguage = "model-not-language"
    case modelFormatUnavailable = "model-format-unavailable"
    case modelQuantizationUnavailable = "model-quantization-unavailable"
    case invalidObservation = "invalid-observation"
}

/// Pure construction seam for one exact reusable profile. It neither discovers nor fills in data.
struct Phase2StandardModelProfileFactory: Sendable {
    func makeProfile(
        from observation: Phase2StandardModelProfileObservation
    ) -> Result<Phase2ModelProfile, Phase2StandardModelProfileFactoryError> {
        guard observation.model.type == .language else {
            return .failure(.modelNotLanguage)
        }
        guard let format = observation.model.format else {
            return .failure(.modelFormatUnavailable)
        }
        guard let quantization = observation.model.quantization,
              let quantizationName = quantization.name
        else {
            return .failure(.modelQuantizationUnavailable)
        }

        do {
            let artifact = try Phase2ModelArtifactIdentity(
                modelKey: observation.model.key,
                source: observation.source,
                type: observation.model.type,
                format: format,
                quantizationName: quantizationName,
                bitsPerWeight: quantization.bitsPerWeight,
                backingDigest: observation.backingDigest
            )
            return .success(try Phase2ModelProfile(
                version: observation.profileVersion,
                provider: observation.provider,
                artifact: artifact,
                loadedConfiguration: observation.loadedConfiguration,
                context: observation.context,
                generation: observation.generation,
                hardwareTier: observation.hardwareTier,
                workflow: observation.workflow,
                authorityCeiling: observation.authorityCeiling,
                toolCallMode: observation.toolCallMode,
                structuredOutputMode: observation.structuredOutputMode,
                protocolManifest: observation.protocolManifest
            ))
        } catch {
            return .failure(.invalidObservation)
        }
    }
}
