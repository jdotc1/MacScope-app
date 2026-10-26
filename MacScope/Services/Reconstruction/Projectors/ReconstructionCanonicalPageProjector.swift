import CryptoKit
import Foundation

enum ReconstructionCanonicalPageProjector {
    static func project(
        request: ReconstructionToolRequestEnvelope,
        input: ReconstructionToolProjectorInput
    ) throws -> ReconstructionToolProjectionResult {
        try Task.checkCancellation()
        if input.staleOperations.contains(request.operationID) {
            return .stale("The app-owned source snapshot is stale.")
        }
        guard let items = input.projectedItemsByOperation[request.operationID], !items.isEmpty else {
            return .unavailable("No bounded result is available for this read.")
        }
        guard request.offset < items.count else {
            return .unavailable("The requested app-owned page is exhausted.")
        }
        var selected: [Data] = []
        var payloadSize = 2
        var index = request.offset
        var selectedEvidenceCount = 0
        var selectedRecordCount = 0
        while index < items.count, selectedRecordCount < request.maximumRecords {
            if selected.count.isMultiple(of: 64) { try Task.checkCancellation() }
            let candidate = items[index]
            let candidateRecordCount = candidate.payload.semanticRecordCount
            guard candidateRecordCount <= request.maximumRecords - selectedRecordCount else {
                break
            }
            if candidate.evidence != nil {
                try Task.checkCancellation()
                guard selectedEvidenceCount < 16 else { break }
                selectedEvidenceCount += 1
            }
            let canonicalPayload = candidate.canonicalPayload
            let delimiterBytes = selected.isEmpty ? 0 : 1
            guard payloadSize + delimiterBytes <= request.maximumEncodedBytes,
                  canonicalPayload.count <= request.maximumEncodedBytes - payloadSize - delimiterBytes else {
                break
            }
            do {
                let object = try JSONSerialization.jsonObject(
                    with: canonicalPayload,
                    options: [.fragmentsAllowed]
                )
                let canonical = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
                )
                guard canonical == canonicalPayload else {
                    throw ReconstructionCanonicalPageError.nonCanonicalItem
                }
                selected.append(canonical)
                selectedRecordCount += candidateRecordCount
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .failed("Projected data is not canonical JSON.")
            }
            payloadSize += canonicalPayload.count + delimiterBytes
            index += 1
        }
        let payload = arrayPayload(selected)
        let hasMore = index < items.count
        if hasMore, selected.isEmpty {
            return .failed("A projected item exceeds the app-owned byte budget.")
        }
        let evidenceCandidates = try selectedEvidenceCandidates(
            items[request.offset..<index],
            request: request,
            input: input
        )
        if hasMore {
            let continuation = ReconstructionToolRequest(
                operationID: request.operationID,
                taskID: request.taskID,
                subject: request.subject,
                retrievalQuery: request.retrievalQuery,
                offset: index,
                maximumRecords: request.maximumRecords,
                maximumEncodedBytes: request.maximumEncodedBytes
            )
            return .truncated(
                payload: payload,
                count: selectedRecordCount,
                continuationRequest: continuation,
                evidenceCandidates: evidenceCandidates
            )
        }
        return .success(
            payload: payload,
            count: selectedRecordCount,
            evidenceCandidates: evidenceCandidates
        )
    }

    private static func arrayPayload(_ items: [Data]) -> Data {
        var result = Data("[".utf8)
        for (index, item) in items.enumerated() {
            if index > 0 { result.append(0x2c) }
            result.append(item)
        }
        result.append(0x5d)
        return result
    }

    private static func selectedEvidenceCandidates(
        _ items: ArraySlice<ReconstructionProjectedReadItem>,
        request: ReconstructionToolRequestEnvelope,
        input: ReconstructionToolProjectorInput
    ) throws -> [ReconstructionEvidenceCandidate] {
        let evidence = items.compactMap(\.evidence)
        guard !evidence.isEmpty else { return [] }
        guard let cut = input.evidenceAuthorityCutsByOperation[request.operationID] else {
            throw ReconstructionToolBrokerError.invalidEvidenceAuthorityCut
        }
        return try evidence.enumerated().map { index, blueprint in
            if index.isMultiple(of: 4) { try Task.checkCancellation() }
            return try ReconstructionEvidenceCandidate(
                evidenceID: blueprint.evidenceID,
                subject: blueprint.subject,
                operationID: blueprint.operationID,
                payloadKind: blueprint.payloadKind,
                payload: blueprint.payload,
                payloadByteCount: UInt64(blueprint.payload.count),
                payloadSHA256: SHA256.hash(data: blueprint.payload)
                    .map { String(format: "%02x", $0) }.joined(),
                facetDependencies: blueprint.facetDependencies,
                producer: cut.producer,
                citations: blueprint.citations,
                creatingJobID: cut.creatingJobID,
                creatingTaskID: cut.creatingTaskID,
                creatingCheckpointID: cut.creatingCheckpointID,
                modelReceiptID: cut.modelReceiptID,
                toolReceiptID: cut.toolReceiptID,
                supersedesEvidenceID: blueprint.supersedesEvidenceID,
                diagnostic: blueprint.diagnostic
            )
        }
    }
}

private enum ReconstructionCanonicalPageError: Error {
    case nonCanonicalItem
}
