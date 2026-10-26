import Foundation

enum Phase2ModelProfileMismatch: String, Hashable, Sendable {
    case providerFamily
    case providerBuild
    case providerAPICompatibility
    case endpointTransport
    case modelType
    case modelKey
    case modelSource
    case modelFormat
    case quantization
    case advertisedContext
    case backingDigest
    case loadedConfiguration
}

enum Phase2ModelProfileMatch: Equatable, Sendable {
    case exact
    case mismatch([Phase2ModelProfileMismatch])
}

/// Pure exact matcher from one provider observation to one immutable support recipe.
/// Display names, variants, disk size, and runtime instance IDs are deliberately absent.
struct Phase2ModelProfileMatcher: Sendable {
    func match(
        profile: Phase2ModelProfile,
        observedProvider: Phase2QualifiedProviderIdentity,
        observedSource: String,
        observedBackingDigest: Phase2ModelBackingDigest,
        model: Phase2LocalModelDescriptor,
        loadedConfiguration: Phase2LocalModelInstanceConfiguration
    ) -> Phase2ModelProfileMatch {
        var mismatches: [Phase2ModelProfileMismatch] = []

        if observedProvider.family != profile.provider.family { mismatches.append(.providerFamily) }
        if observedProvider.build != profile.provider.build { mismatches.append(.providerBuild) }
        if observedProvider.apiCompatibility != profile.provider.apiCompatibility {
            mismatches.append(.providerAPICompatibility)
        }
        if observedProvider.endpointTransport != profile.provider.endpointTransport {
            mismatches.append(.endpointTransport)
        }
        if model.type != profile.artifact.type { mismatches.append(.modelType) }
        if Array(model.key.utf8) != Array(profile.artifact.modelKey.utf8) {
            mismatches.append(.modelKey)
        }
        if Array(observedSource.utf8) != Array(profile.artifact.source.utf8) {
            mismatches.append(.modelSource)
        }
        if model.format != profile.artifact.format { mismatches.append(.modelFormat) }
        if model.quantization?.name != profile.artifact.quantizationName
            || model.quantization?.bitsPerWeight != profile.artifact.bitsPerWeight {
            mismatches.append(.quantization)
        }
        if observedBackingDigest != profile.artifact.backingDigest {
            mismatches.append(.backingDigest)
        }
        if model.maximumContextLength < profile.context.maximumInputTokens {
            mismatches.append(.advertisedContext)
        }
        if loadedConfiguration != profile.loadedConfiguration {
            mismatches.append(.loadedConfiguration)
        }

        return mismatches.isEmpty ? .exact : .mismatch(mismatches)
    }
}
