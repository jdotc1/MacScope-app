import Foundation

struct ReconstructionGapsToolProjector: ReconstructionToolProjecting {
    let family: ReconstructionToolProjectorFamily = .gaps
    let operations: Set<ReconstructionOperationID> = [.gapsPage]

    func project(
        request: ReconstructionToolRequestEnvelope,
        input: ReconstructionToolProjectorInput
    ) async throws -> ReconstructionToolProjectionResult {
        try ReconstructionCanonicalPageProjector.project(request: request, input: input)
    }
}
