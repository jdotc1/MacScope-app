import Foundation

/// Admission into the existing evidence owner. Runtime capture and committed provenance are
/// independent inputs; no payload can establish its own source, oracle or execution authority.
enum ReconstructionSourceEvaluationEvidence {
    static let operationID = "reconstruction.source.evaluate"
    static let taskContract = "reconstruction.source.evaluate.v1"
    enum Failure: Error, Equatable { case invalidContext, invalidReceipt, invalidSource, invalidOracle, invalidOutcome, invalidRecord }
    struct Context: Sendable {
        let sourceRecord: ReconstructionEvidenceRecord
        let sourceContext: ReconstructionSourceRevisionEvidence.Context
        let oracleRecord: ReconstructionEvidenceRecord
        let oracleContext: ReconstructionSourceOracleEvidence.Context
        let task: ReconstructionTaskRecord
        let checkpoint: ReconstructionCheckpoint
        let toolReceipt: ReconstructionToolReceipt
        let expectedRequestIdentitySHA256: String
        let expectedProducer: ReconstructionProducerIdentity
        let expectedCapturedOutcome: ReconstructionSourceEvaluation.CapturedOutcome
    }
    static func make(evidenceID: UUID, context: Context) throws -> ReconstructionEvidenceRecord {
        let source = try ReconstructionSourceRevisionEvidence.validate(record: context.sourceRecord, context: context.sourceContext)
        let oracle = try ReconstructionSourceOracleEvidence.validate(record: context.oracleRecord, context: context.oracleContext)
        guard let binding = source.requestBinding,
              source.profileID == oracle.profileID, source.projectID == oracle.projectID, source.jobID == oracle.jobID,
              source.function == oracle.function, source.oracleSuiteSHA256 == oracle.suiteSHA256,
              binding.requestSHA256 == context.sourceContext.expectedRequestIdentitySHA256,
              context.sourceContext.checkpoint.revision < context.checkpoint.revision,
              context.oracleContext.checkpoint.revision < context.checkpoint.revision,
              evidenceID != context.sourceRecord.evidenceID, evidenceID != context.oracleRecord.evidenceID else { throw Failure.invalidSource }
        let task = context.task, cp = context.checkpoint, receipt = context.toolReceipt
        try task.identity.verifyCanonicalIdentity()
        try cp.verifyCanonicalIdentity()
        guard task.identity.kind == .executeSource, task.identity.operationContractIdentity == taskContract,
              task.identity.jobID == source.jobID, task.identity.subject == .function(source.function),
              task.state == .completed, cp.jobID == source.jobID,
              cp.completedTaskIDs.contains(task.identity.taskID), cp.toolReceiptIDs.contains(receipt.receiptID) else { throw Failure.invalidContext }
        guard receipt.jobID == source.jobID, receipt.taskID == task.identity.taskID,
              receipt.checkpointRevision == cp.revision, receipt.terminalState == .completed,
              receipt.requestIdentitySHA256 == context.expectedRequestIdentitySHA256,
              receipt.outputEvidenceIDs == [evidenceID], receipt.evidenceReadAuthority == nil,
              receipt.producer == context.expectedProducer, receipt.producer.operationIdentity == operationID,
              receipt.producer.modelKey == nil, receipt.producer.endpointOrigin == nil,
              try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(receipt),
              try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(receipt.producer) == receipt.producer.canonicalSHA256 else { throw Failure.invalidReceipt }
        let captured = context.expectedCapturedOutcome
        guard ![ReconstructionSourceEvaluation.Status.cancelled, .transportFailed, .invalidAuthority, .changedInputs].contains(captured.status) else { throw Failure.invalidOutcome }
        guard captured.harnessSHA256 == oracle.execution.harnessSHA256 else { throw Failure.invalidOracle }
        if !captured.observations.isEmpty {
            guard captured.observations.map(\.input) == oracle.inputs else { throw Failure.invalidOutcome }
            let mismatches = zip(captured.observations, oracle.outputs).enumerated().compactMap { index, pair -> ReconstructionSourceEvaluation.Mismatch? in
                pair.0.output == pair.1 ? nil : .init(index: index, input: pair.0.input, expected: pair.1, actual: pair.0.output)
            }
            guard captured.mismatches == mismatches else { throw Failure.invalidOutcome }
        }
        func value(hash: String) -> ReconstructionSourceEvaluation {
            .init(version: 1, profileID: source.profileID,
                projectID: source.projectID, jobID: source.jobID, taskID: task.identity.taskID,
                checkpointRevision: cp.revision, evaluationRequestSHA256: context.expectedRequestIdentitySHA256,
                function: source.function, sourceEvidenceID: context.sourceRecord.evidenceID,
                sourcePayloadSHA256: context.sourceRecord.payloadSHA256, revisionSHA256: source.revisionSHA256,
                sourceSHA256: source.sourceSHA256, sourceRequestSHA256: binding.requestSHA256,
                oracleEvidenceID: context.oracleRecord.evidenceID, oraclePayloadSHA256: context.oracleRecord.payloadSHA256,
                oracleSuiteSHA256: oracle.suiteSHA256, producerSHA256: receipt.producer.canonicalSHA256,
                capturedOutcome: captured, evaluationSHA256: hash)
        }
        let evaluation = value(hash: try ReconstructionSourceEvaluationCodec.canonicalIdentity(value(hash: String(repeating: "0", count: 64))))
        try ReconstructionSourceEvaluationCodec.validate(evaluation)
        let payload = try ReconstructionSourceEvaluationCodec.encode(evaluation)
        let citations = try ReconstructionValidation.sortedUUIDs([context.sourceRecord.evidenceID, context.oracleRecord.evidenceID]).map {
            try ReconstructionEvidenceCitation(citationID: $0, sourceEvidenceID: $0, subject: nil, locator: nil)
        }
        return try ReconstructionEvidenceRecord(evidenceID: evidenceID, subject: .function(source.function),
            operationID: operationID, payloadKind: .structuredJSON, payload: payload,
            payloadByteCount: UInt64(payload.count), payloadSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(payload),
            facetDependencies: [], producer: receipt.producer, citations: citations,
            creatingJobID: source.jobID, creatingTaskID: task.identity.taskID,
            creatingCheckpointID: cp.checkpointID, modelReceiptID: nil, toolReceiptID: receipt.receiptID,
            classification: .acceptedCurrent, supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
    }
    static func validate(record: ReconstructionEvidenceRecord, context: Context) throws -> ReconstructionSourceEvaluation {
        let expected = try make(evidenceID: record.evidenceID, context: context)
        guard record == expected else { throw Failure.invalidRecord }
        return try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: record.payload)
    }
}
