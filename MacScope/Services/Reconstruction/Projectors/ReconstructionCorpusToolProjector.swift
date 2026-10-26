import Foundation

struct ReconstructionCorpusToolProjector: ReconstructionToolProjecting {
    let family: ReconstructionToolProjectorFamily = .corpus
    let operations: Set<ReconstructionOperationID> = [
        .corpusSummary, .corpusArtifactsPage, .corpusArtifactDescribe,
        .corpusRelationsPage, .corpusSearch,
    ]

    func project(
        request: ReconstructionToolRequestEnvelope,
        input: ReconstructionToolProjectorInput
    ) async throws -> ReconstructionToolProjectionResult {
        try ReconstructionCanonicalPageProjector.project(request: request, input: input)
    }
}
