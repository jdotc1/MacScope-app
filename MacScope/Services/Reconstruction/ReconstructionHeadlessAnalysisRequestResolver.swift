import Foundation

enum ReconstructionHeadlessAnalysisRequestResolutionError: Error, Equatable, Sendable {
    case invalidCommittedCorpus
    case staleAuthority
    case unsupportedTask
    case missingOccurrence
    case missingAttachment
}

/// Resolves batch work exclusively from a committed corpus manifest and durable attachment
/// sources captured before execution. No window, selection, Store, or database object crosses
/// this boundary.
struct ReconstructionHeadlessAnalysisRequestResolver: ReconstructionHeadlessAnalysisRequestResolving {
    private let manifest: ReconstructionCorpusManifest
    private let sourcesByIdentity: [ReconstructionContentIdentity: ReconstructionAttachmentSource]
    private let imagesByOccurrence: [ReconstructionArtifactOccurrenceID: ReconstructionImageBinding]
    private let overridesByOccurrence: [ReconstructionArtifactOccurrenceID: [UInt64: AddressOverride]]

    init(
        manifest: ReconstructionCorpusManifest,
        attachmentSources: [ReconstructionAttachmentSource],
        imagesByOccurrence: [
            ReconstructionArtifactOccurrenceID: ReconstructionImageBinding
        ] = [:],
        overridesByOccurrence: [
            ReconstructionArtifactOccurrenceID: [UInt64: AddressOverride]
        ] = [:]
    ) throws {
        guard try ReconstructionCorpusCanonicalizer.canonicalSHA256(of: manifest)
                == manifest.canonicalSHA256 else {
            throw ReconstructionHeadlessAnalysisRequestResolutionError.invalidCommittedCorpus
        }
        let manifestOccurrences = Set(manifest.artifacts.map(\.occurrenceID))
        guard Set(imagesByOccurrence.keys).isSubset(of: manifestOccurrences),
              Set(overridesByOccurrence.keys).isSubset(of: manifestOccurrences) else {
            throw ReconstructionHeadlessAnalysisRequestResolutionError.missingOccurrence
        }
        var sources: [ReconstructionContentIdentity: ReconstructionAttachmentSource] = [:]
        for source in attachmentSources {
            guard sources.updateValue(source, forKey: source.contentIdentity) == nil else {
                throw ReconstructionHeadlessAnalysisRequestResolutionError.invalidCommittedCorpus
            }
        }
        self.manifest = manifest
        self.sourcesByIdentity = sources
        self.imagesByOccurrence = imagesByOccurrence
        self.overridesByOccurrence = overridesByOccurrence
    }

    func request(
        for task: ReconstructionTaskRecord,
        authority: ReconstructionBatchAuthority
    ) async throws -> ReconstructionHeadlessAnalysisRequest {
        try Task.checkCancellation()
        guard task.identity.jobID == authority.jobID,
              authority.corpusManifestSHA256 == manifest.canonicalSHA256 else {
            throw ReconstructionHeadlessAnalysisRequestResolutionError.staleAuthority
        }
        guard task.state == .pending || task.state == .running,
              let subject = task.identity.subject else {
            throw ReconstructionHeadlessAnalysisRequestResolutionError.unsupportedTask
        }
        let artifact: ReconstructionArtifactCoordinate
        let image: ReconstructionImageBinding?
        let functionID: UUID?
        let functionCoordinate: ReconstructionFunctionCoordinate?
        let imageAuthorityIntent: ReconstructionHeadlessImageAuthorityIntent
        switch (task.identity.kind, subject) {
        case (.ingest, let .artifact(value)),
             (.classify, let .artifact(value)),
             (.discoverRelations, let .artifact(value)):
            artifact = value
            image = nil
            functionID = nil
            functionCoordinate = nil
            imageAuthorityIntent = .existingImage
        case (.loadBinary, let .artifact(value)):
            artifact = value
            image = imagesByOccurrence[value.occurrenceID]
            functionID = nil
            functionCoordinate = nil
            imageAuthorityIntent = .initialLoad
        case (.loadBinary, let .image(value)):
            artifact = value.artifact
            image = value.image
            functionID = nil
            functionCoordinate = nil
            imageAuthorityIntent = .initialLoad
        case (.indexImage, let .image(value)),
             (.enumerateFunctions, let .image(value)):
            artifact = value.artifact
            guard imagesByOccurrence[value.artifact.occurrenceID] == value.image else {
                throw ReconstructionHeadlessAnalysisRequestResolutionError.missingOccurrence
            }
            image = value.image
            functionID = nil
            functionCoordinate = nil
            imageAuthorityIntent = .existingImage
        case (.decompileNative, let .function(value)),
             (.decompileMacScope, let .function(value)),
             (.compareDecompilers, let .function(value)):
            artifact = value.artifact
            image = value.image
            functionID = value.functionUUIDHint
            functionCoordinate = value
            imageAuthorityIntent = .existingImage
        default:
            throw ReconstructionHeadlessAnalysisRequestResolutionError.unsupportedTask
        }
        guard let occurrence = manifest.artifacts.first(where: {
            $0.occurrenceID == artifact.occurrenceID
        }), occurrence.contentIdentity == artifact.contentIdentity else {
            throw ReconstructionHeadlessAnalysisRequestResolutionError.missingOccurrence
        }
        guard let source = sourcesByIdentity[occurrence.contentIdentity],
              source.contentIdentity == artifact.contentIdentity else {
            throw ReconstructionHeadlessAnalysisRequestResolutionError.missingAttachment
        }
        return .init(
            source: source,
            artifact: artifact,
            image: image,
            functionID: functionID,
            overrides: overridesByOccurrence[occurrence.occurrenceID] ?? [:],
            imageAuthorityIntent: imageAuthorityIntent,
            functionCoordinate: functionCoordinate
        )
    }
}
