import Foundation

struct ReconstructionImageFunctionToolProjector: ReconstructionToolProjecting {
    let family: ReconstructionToolProjectorFamily = .imageFunction
    let operations: Set<ReconstructionOperationID> = [
        .imagesPage, .functionsPage, .functionReview,
    ]

    func project(
        request: ReconstructionToolRequestEnvelope,
        input: ReconstructionToolProjectorInput
    ) async throws -> ReconstructionToolProjectionResult {
        try ReconstructionCanonicalPageProjector.project(request: request, input: input)
    }
}
