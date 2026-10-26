import Foundation

/// Bridges inline source proposals into the existing evidence/receipt/checkpoint owner.
/// Context must be captured from committed state; none of its authority is taken from payload JSON.
enum ReconstructionSourceRevisionEvidence {
    static let operationID = "reconstruction.source.revision"
    static let taskContract = "reconstruction.source.revision.v1"
    enum Failure: Error, Equatable {
        case invalidContext, invalidReceipt, invalidRecord, invalidCitations, invalidEvidenceCut
        case invalidParentChain, revisionBudgetExhausted
    }
    struct Context: Sendable {
        let admissionAuthority: ReconstructionSourceRevisionAuthority
        let task: ReconstructionTaskRecord
        let checkpoint: ReconstructionCheckpoint
        let modelReceipt: ReconstructionModelReceipt
        let expectedRequestIdentitySHA256: String
        let committedEvidenceCut: [ReconstructionEvidenceRecord]
        /// Source records preceding this admission, supplied by the committed job history.
        let committedPriorRevisionRecords: [ReconstructionEvidenceRecord]
        /// Retained committed contexts for each preceding source record, in the same order.
        /// A second proposal must prove the first record through its own task/receipt/checkpoint.
        var priorRevisionContexts: [Context] = []
    }

    static func make(
        evidenceID: UUID,
        proposal: ReconstructionSourceRevisionProposal,
        context: Context
    ) throws -> ReconstructionEvidenceRecord {
        try validateContext(context, evidenceID: evidenceID)
        let revision = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal, authority: context.admissionAuthority)
        let payload = try ReconstructionSourceRevisionAdmission.encode(revision)
        let citations = try revision.evidenceIDs.map { id in
            try ReconstructionEvidenceCitation(citationID: id, sourceEvidenceID: id, subject: nil, locator: nil)
        }
        let record = try ReconstructionEvidenceRecord(evidenceID: evidenceID,
            subject: .function(revision.function), operationID: operationID, payloadKind: .structuredJSON,
            payload: payload, payloadByteCount: UInt64(payload.count),
            payloadSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(payload),
            facetDependencies: [], producer: context.modelReceipt.producer, citations: citations,
            creatingJobID: revision.jobID, creatingTaskID: context.task.identity.taskID,
            creatingCheckpointID: context.checkpoint.checkpointID, modelReceiptID: context.modelReceipt.receiptID,
            toolReceiptID: nil, classification: .acceptedCurrent, supersedesEvidenceID: nil,
            supersededByEvidenceID: nil, diagnostic: nil)
        _ = try validate(record: record, context: context)
        return record
    }

    static func validate(record: ReconstructionEvidenceRecord, context: Context) throws -> ReconstructionSourceRevision {
        try Task.checkCancellation()
        try validateContext(context, evidenceID: record.evidenceID)
        guard record.schemaVersion == ReconstructionEvidenceRecord.schemaVersion,
              record.operationID == operationID, record.payloadKind == .structuredJSON,
              record.subject == .function(context.admissionAuthority.function),
              record.creatingJobID == context.admissionAuthority.jobID,
              record.creatingTaskID == context.task.identity.taskID,
              record.creatingCheckpointID == context.checkpoint.checkpointID,
              record.modelReceiptID == context.modelReceipt.receiptID, record.toolReceiptID == nil,
              record.producer == context.modelReceipt.producer, record.classification == .acceptedCurrent,
              record.supersedesEvidenceID == nil, record.supersededByEvidenceID == nil,
              record.diagnostic == nil, record.facetDependencies.isEmpty,
              record.payloadByteCount == UInt64(record.payload.count),
              record.payloadSHA256 == ReconstructionSourceRevisionAdmission.sourceSHA256(record.payload) else { throw Failure.invalidRecord }
        let revision = try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: record.payload, authority: context.admissionAuthority)
        let citations = record.citations
        guard citations.count == revision.evidenceIDs.count,
              Set(citations.compactMap(\.sourceEvidenceID)) == Set(revision.evidenceIDs),
              Set(citations.map(\.citationID)).count == citations.count,
              citations.allSatisfy({ $0.subject == nil && $0.locator == nil && $0.sourceEvidenceID != nil }) else { throw Failure.invalidCitations }
        return revision
    }

    private static func validateContext(_ context: Context, evidenceID: UUID) throws {
        let authority = context.admissionAuthority
        try context.task.identity.verifyCanonicalIdentity()
        try context.checkpoint.verifyCanonicalIdentity()
        guard context.task.identity.jobID == authority.jobID, context.task.identity.kind == .modelRound,
              context.task.identity.operationContractIdentity == taskContract,
              context.task.identity.subject == .function(authority.function), context.task.state == .completed,
              context.checkpoint.jobID == authority.jobID,
              context.checkpoint.completedTaskIDs.contains(context.task.identity.taskID) else { throw Failure.invalidContext }
        let receipt = context.modelReceipt
        guard try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(receipt),
              try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(receipt.producer) == receipt.producer.canonicalSHA256,
              receipt.producer.operationIdentity == operationID,
              receipt.jobID == authority.jobID, receipt.taskID == context.task.identity.taskID,
              receipt.checkpointRevision == context.checkpoint.revision,
              receipt.requestIdentitySHA256 == context.expectedRequestIdentitySHA256,
              receipt.terminalState == .completed, receipt.diagnostic == nil,
              receipt.selectedHandleIDs.isEmpty, receipt.finalResultCommitment == nil,
              receipt.acceptedEvidenceIDs == [evidenceID],
              context.checkpoint.modelReceiptIDs.contains(receipt.receiptID) else { throw Failure.invalidReceipt }
        guard context.committedPriorRevisionRecords.count < 2 else { throw Failure.revisionBudgetExhausted }
        guard context.priorRevisionContexts.count == context.committedPriorRevisionRecords.count else {
            throw Failure.invalidParentChain
        }
        if let parent = authority.currentRevision {
            guard context.committedPriorRevisionRecords.count == 1, parent.parentRevisionSHA256 == nil,
                  let prior = context.committedPriorRevisionRecords.first,
                  let priorContext = context.priorRevisionContexts.first,
                  priorContext.admissionAuthority.currentRevision == nil,
                  priorContext.committedPriorRevisionRecords.isEmpty,
                  priorContext.priorRevisionContexts.isEmpty,
                  priorContext.task.identity.taskID != context.task.identity.taskID,
                  priorContext.modelReceipt.receiptID != receipt.receiptID,
                  context.checkpoint.revision > priorContext.checkpoint.revision,
                  context.checkpoint.checkpointID != priorContext.checkpoint.checkpointID,
                  prior.evidenceID != evidenceID,
                  try validate(record: prior, context: priorContext) == parent else {
                throw Failure.invalidParentChain
            }
        } else if !context.committedPriorRevisionRecords.isEmpty { throw Failure.invalidParentChain }
        var cut: [UUID: ReconstructionEvidenceRecord] = [:]
        for evidence in context.committedEvidenceCut {
            guard cut.updateValue(evidence, forKey: evidence.evidenceID) == nil else { throw Failure.invalidEvidenceCut }
        }
        for id in authority.admissibleEvidenceIDs {
            guard id != evidenceID, let evidence = cut[id], evidence.classification == .acceptedCurrent,
                  evidence.supersededByEvidenceID == nil,
                  evidence.payloadByteCount == UInt64(evidence.payload.count),
                  evidence.payloadSHA256 == ReconstructionSourceRevisionAdmission.sourceSHA256(evidence.payload) else { throw Failure.invalidEvidenceCut }
        }
    }
}
