import Foundation

/// Pure codec/admission bridge. Existing tool receipts and checkpoint mutation remain the owners.
enum ReconstructionSourceOracleEvidence {
    static let operationID = "reconstruction.source.oracle"
    static let taskContract = "reconstruction.source.oracle.v1"
    enum Failure: Error, Equatable {
        case invalidAuthority, invalidExecution, invalidContext, invalidReceipt
        case invalidEvidenceCut, malformedPayload, noncanonicalPayload, invalidRecord
    }
    struct Context: Sendable {
        let authority: ReconstructionSourceOracleAuthority
        let task: ReconstructionTaskRecord
        let checkpoint: ReconstructionCheckpoint
        let toolReceipt: ReconstructionToolReceipt
        let expectedRequestIdentitySHA256: String
        let expectedProducer: ReconstructionProducerIdentity
        let committedEvidenceCut: [ReconstructionEvidenceRecord]
    }
    private struct Preimage: Codable {
        let version: Int
        let profileID: String
        let projectID: UUID
        let jobID: UUID
        let function: ReconstructionFunctionCoordinate
        let inputs: [UInt32]
        let outputs: [UInt32]
        let execution: ReconstructionSourceOracle.Execution
        let evidenceIDs: [UUID]
    }

    static func admit(authority: ReconstructionSourceOracleAuthority) throws -> ReconstructionSourceOracle {
        try validateAuthority(authority)
        let harness = try ReconstructionSourceBehaviorHarness.forProfile(authority.profileID)
        let outputs: [UInt32]
        do { outputs = try harness.decodeObservedOutputs(authority.execution.standardOutput) }
        catch { throw Failure.invalidExecution }
        let preimage = Preimage(version: ReconstructionSourceOracle.version,
            profileID: authority.profileID, projectID: authority.projectID,
            jobID: authority.jobID, function: authority.function, inputs: harness.inputs,
            outputs: outputs, execution: authority.execution,
            evidenceIDs: ReconstructionValidation.sortedUUIDs(authority.evidenceIDs))
        return ReconstructionSourceOracle(version: preimage.version, profileID: preimage.profileID,
            projectID: preimage.projectID, jobID: preimage.jobID, function: preimage.function,
            inputs: preimage.inputs, outputs: preimage.outputs, execution: preimage.execution,
            evidenceIDs: preimage.evidenceIDs, suiteSHA256: try ReconstructionCanonicalJSON.sha256(of: preimage))
    }

    static func encode(_ oracle: ReconstructionSourceOracle) throws -> Data {
        let bytes = try ReconstructionCanonicalJSON.encode(oracle)
        guard bytes.count <= ReconstructionSourceOracle.maximumPayloadBytes else { throw Failure.malformedPayload }
        return bytes
    }

    /// Structural/content validation only. Authentication remains the committed record, producer,
    /// receipt, task and checkpoint owner's responsibility; payload provenance cannot certify itself.
    static func decodeAndValidateCanonical(payload: Data) throws -> ReconstructionSourceOracle {
        guard !payload.isEmpty, payload.count <= ReconstructionSourceOracle.maximumPayloadBytes else { throw Failure.malformedPayload }
        let decoded: ReconstructionSourceOracle
        do {
            _ = try Phase2StrictJSONParser().parse(payload, limits: .init(
                maximumBytes: ReconstructionSourceOracle.maximumPayloadBytes, maximumDepth: 16,
                maximumTokens: 8_192, maximumMembersAndElements: 4_096))
            decoded = try JSONDecoder().decode(ReconstructionSourceOracle.self, from: payload)
        } catch { throw Failure.malformedPayload }
        guard try encode(decoded) == payload else { throw Failure.noncanonicalPayload }
        let local = try admit(authority: ReconstructionSourceOracleAuthority(projectID: decoded.projectID,
            jobID: decoded.jobID, function: decoded.function, execution: decoded.execution, evidenceIDs: decoded.evidenceIDs, profileID: decoded.profileID))
        guard payload == (try encode(local)) else { throw Failure.invalidAuthority }
        return decoded
    }

    static func decodeAndValidate(payload: Data, authority: ReconstructionSourceOracleAuthority) throws -> ReconstructionSourceOracle {
        let decoded = try decodeAndValidateCanonical(payload: payload)
        let expected = try admit(authority: authority)
        guard decoded == expected, payload == (try encode(expected)) else { throw Failure.invalidAuthority }
        return decoded
    }

    static func make(evidenceID: UUID, context: Context) throws -> ReconstructionEvidenceRecord {
        try validateContext(context, evidenceID: evidenceID)
        let oracle = try admit(authority: context.authority)
        let payload = try encode(oracle)
        let citations = try oracle.evidenceIDs.map {
            try ReconstructionEvidenceCitation(citationID: $0, sourceEvidenceID: $0, subject: nil, locator: nil)
        }
        return try ReconstructionEvidenceRecord(evidenceID: evidenceID, subject: .function(oracle.function),
            operationID: operationID, payloadKind: .structuredJSON, payload: payload,
            payloadByteCount: UInt64(payload.count), payloadSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(payload),
            facetDependencies: [], producer: context.toolReceipt.producer, citations: citations,
            creatingJobID: oracle.jobID, creatingTaskID: context.task.identity.taskID,
            creatingCheckpointID: context.checkpoint.checkpointID, modelReceiptID: nil,
            toolReceiptID: context.toolReceipt.receiptID, classification: .acceptedCurrent,
            supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
    }

    static func validate(record: ReconstructionEvidenceRecord, context: Context) throws -> ReconstructionSourceOracle {
        try validateContext(context, evidenceID: record.evidenceID)
        let expected = try make(evidenceID: record.evidenceID, context: context)
        guard record == expected else { throw Failure.invalidRecord }
        return try decodeAndValidate(payload: record.payload, authority: context.authority)
    }

    private static func validateAuthority(_ authority: ReconstructionSourceOracleAuthority) throws {
        let execution = authority.execution
        guard ReconstructionSourceProfile.admits(authority.profileID),
              authority.function.image.architecture == .arm64,
              authority.function.artifact.contentIdentity.algorithm == .sha256,
              authority.function.artifact.contentIdentity.byteCount > 0,
              authority.function.endAddressExclusive > authority.function.startAddress,
              authority.function.boundarySchemaVersion == 1,
              authority.function.image.selectedSliceIndex.map({ $0 >= 0 }) ?? true,
              authority.function.artifact.contentIdentity.digest == execution.originalImageSHA256,
              !authority.evidenceIDs.isEmpty, authority.evidenceIDs.count <= 64,
              Set(authority.evidenceIDs).count == authority.evidenceIDs.count else { throw Failure.invalidAuthority }
        let hashes = [authority.function.analysisFingerprintSHA256, execution.originalImageSHA256, execution.originalExecutableSHA256,
            execution.harnessSHA256, execution.compilerSHA256, execution.sdkIdentitySHA256,
            execution.compileProfileSHA256, execution.compileArgumentsSHA256,
            execution.executionArgumentsSHA256, execution.producerSHA256] + [execution.originalSourceSHA256].compactMap { $0 }
        for hash in hashes { try ReconstructionValidation.requireSHA256(hash, field: "oracle authority") }
        let harness = try ReconstructionSourceBehaviorHarness.forProfile(authority.profileID)
        guard harness.inputs.count == 37,
              execution.harnessSHA256 == ReconstructionSourceRevisionAdmission.sourceSHA256(harness.sourceUTF8),
              execution.exitCode == 0, execution.observedProcessAbsent,
              execution.processIdentifier > 0, !execution.sampledProcessIDs.isEmpty,
              execution.sampledProcessIDs.count <= 1_024,
              execution.sampledProcessIDs.allSatisfy({ $0 > 0 }),
              Set(execution.sampledProcessIDs).count == execution.sampledProcessIDs.count,
              execution.sampledProcessIDs.contains(execution.processIdentifier) else { throw Failure.invalidExecution }
        _ = try harness.decodeObservedOutputs(execution.standardOutput)
    }

    private static func validateContext(_ context: Context, evidenceID: UUID) throws {
        try validateAuthority(context.authority)
        let task = context.task, checkpoint = context.checkpoint, receipt = context.toolReceipt
        try task.identity.verifyCanonicalIdentity()
        guard task.identity.jobID == context.authority.jobID,
              task.identity.subject == .function(context.authority.function),
              task.identity.kind != .modelRound, task.state == .completed,
              task.identity.operationContractIdentity == taskContract,
              checkpoint.jobID == context.authority.jobID,
              checkpoint.completedTaskIDs.contains(task.identity.taskID),
              checkpoint.toolReceiptIDs.contains(receipt.receiptID) else { throw Failure.invalidContext }
        try checkpoint.verifyCanonicalIdentity()
        guard receipt.jobID == context.authority.jobID, receipt.taskID == task.identity.taskID,
              receipt.checkpointRevision == checkpoint.revision, receipt.terminalState == .completed, receipt.diagnostic == nil,
              receipt.outputEvidenceIDs == [evidenceID], receipt.evidenceReadAuthority == nil,
              receipt.requestIdentitySHA256 == context.expectedRequestIdentitySHA256,
              receipt.producer == context.expectedProducer,
              receipt.producer.operationIdentity == operationID,
              receipt.producer.modelKey == nil, receipt.producer.endpointOrigin == nil,
              receipt.producer.canonicalSHA256 == context.authority.execution.producerSHA256,
              try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(receipt),
              try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(receipt.producer) == receipt.producer.canonicalSHA256 else {
            throw Failure.invalidReceipt
        }
        var cut: [UUID: ReconstructionEvidenceRecord] = [:]
        for record in context.committedEvidenceCut {
            guard cut.updateValue(record, forKey: record.evidenceID) == nil else { throw Failure.invalidEvidenceCut }
        }
        for id in context.authority.evidenceIDs {
            guard id != evidenceID, let record = cut[id],
                  record.classification == .acceptedCurrent || record.classification == .acceptedHistorical,
                  record.payloadByteCount == UInt64(record.payload.count),
                  record.payloadSHA256 == ReconstructionSourceRevisionAdmission.sourceSHA256(record.payload) else {
                throw Failure.invalidEvidenceCut
            }
        }
    }
}
