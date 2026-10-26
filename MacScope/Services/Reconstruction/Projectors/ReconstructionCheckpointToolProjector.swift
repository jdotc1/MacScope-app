import Foundation

struct ReconstructionCheckpointToolProjector: ReconstructionToolProjecting {
    let family: ReconstructionToolProjectorFamily = .checkpoint
    let operations: Set<ReconstructionOperationID> = [.checkpointStatus]

    func project(
        request: ReconstructionToolRequestEnvelope,
        input: ReconstructionToolProjectorInput
    ) async throws -> ReconstructionToolProjectionResult {
        try ReconstructionCanonicalPageProjector.project(request: request, input: input)
    }
}
