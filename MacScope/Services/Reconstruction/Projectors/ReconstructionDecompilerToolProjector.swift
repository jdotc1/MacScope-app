import Foundation

struct ReconstructionDecompilerToolProjector: ReconstructionToolProjecting {
    let family: ReconstructionToolProjectorFamily = .decompiler
    let operations: Set<ReconstructionOperationID> = [
        .decompilerNative, .decompilerMacScope, .decompilerCompare, .analysisMacScopeRefresh,
    ]

    func project(
        request: ReconstructionToolRequestEnvelope,
        input: ReconstructionToolProjectorInput
    ) async throws -> ReconstructionToolProjectionResult {
        if request.operationID == .analysisMacScopeRefresh {
            try Task.checkCancellation()
            guard case .function(let function)? = request.subject else {
                return .failed("The analysis demand has no exact function authority.")
            }
            _ = try ReconstructionMacScopeAnalysisDemand.enumerationTask(
                for: function, tasks: input.tasks, evidenceCut: input.evidenceCut)
            return .success(payload: try ReconstructionMacScopeAnalysisDemand
                .acknowledgement(for: request), count: 1)
        }
        return try ReconstructionCanonicalPageProjector.project(request: request, input: input)
    }
}
