import Foundation

struct ReconstructionEvidenceToolProjector: ReconstructionToolProjecting {
    let family: ReconstructionToolProjectorFamily = .evidence
    let operations: Set<ReconstructionOperationID> = [.evidenceQuery, .evidenceGet]

    func project(
        request: ReconstructionToolRequestEnvelope,
        input: ReconstructionToolProjectorInput
    ) async throws -> ReconstructionToolProjectionResult {
        if request.operationID == .evidenceQuery, let query = request.retrievalQuery {
            if input.staleOperations.contains(request.operationID) {
                return .stale("The app-owned evidence frontier is stale.")
            }
            do {
                let packet = try ReconstructionRetrievalCompiler().compile(
                    cut: input.evidenceCut,
                    query: query
                )
                if packet.hasMore, let cursor = packet.nextCursor {
                    guard packet.records.count
                            <= ReconstructionToolRegistry.maximumOffset - request.offset else {
                        return .failed("Evidence continuation exceeds the app-owned read bound.")
                    }
                    // Evidence pagination is cursor-authoritative. Offset is only a binary
                    // initial/continuation marker and cannot diverge from the cursor.
                    let nextOffset = 1
                    let nextQuery = try ReconstructionRetrievalQuery(
                        corpusManifestSHA256: query.corpusManifestSHA256,
                        subject: query.subject,
                        operationIDs: query.operationIDs,
                        classifications: query.classifications,
                        cursor: cursor,
                        maximumRecords: query.maximumRecords,
                        maximumEncodedBytes: query.maximumEncodedBytes,
                        focus: query.focus
                    )
                    return .truncated(
                        payload: packet.canonicalBytes,
                        count: packet.records.count,
                        continuationRequest: .init(
                            operationID: request.operationID,
                            taskID: request.taskID,
                            subject: request.subject,
                            retrievalQuery: nextQuery,
                            offset: nextOffset,
                            maximumRecords: request.maximumRecords,
                            maximumEncodedBytes: request.maximumEncodedBytes
                        )
                    )
                }
                return .success(payload: packet.canonicalBytes, count: packet.records.count)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .failed("Evidence retrieval failed validation.")
            }
        }
        return try ReconstructionCanonicalPageProjector.project(request: request, input: input)
    }
}
