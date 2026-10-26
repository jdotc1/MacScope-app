import Foundation
import XCTest
@testable import MacScope

final class ReconstructionSourceRevisionEvidenceTests: XCTestCase {
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "a9000000-0000-0000-0000-%012d", n))! }
    private func sha(_ s: String) -> String { ReconstructionSourceRevisionAdmission.sourceSHA256(Data(s.utf8)) }
    private func producer(_ operation: String) throws -> ReconstructionProducerIdentity {
        let p = try ReconstructionProducerIdentity(macScopeBuildIdentity: sha("build"), macScopeSourceIdentity: sha("source"),
            operationIdentity: operation, registryIdentity: sha("registry"), protocolIdentity: sha("protocol"),
            modelKey: "fixture-model", endpointOrigin: "http://127.0.0.1:8000", canonicalSHA256: sha("placeholder"))
        return try .init(macScopeBuildIdentity: p.macScopeBuildIdentity, macScopeSourceIdentity: p.macScopeSourceIdentity,
            operationIdentity: p.operationIdentity, registryIdentity: p.registryIdentity, protocolIdentity: p.protocolIdentity,
            modelKey: p.modelKey, endpointOrigin: p.endpointOrigin,
            canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalProducerSHA256(p))
    }
    private func context(prior: [ReconstructionEvidenceRecord] = [], current: ReconstructionSourceRevision? = nil,
                         receiptEvidenceID: UUID? = nil, request: String? = nil,
                         priorContexts: [ReconstructionSourceRevisionEvidence.Context] = []) throws -> ReconstructionSourceRevisionEvidence.Context {
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: id(1)),
            contentIdentity: try .init(algorithm: .sha256, digest: sha("binary"), byteCount: 32))
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: id(2), imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: sha("analysis"), startAddress: 0x1000, endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
        let authority = ReconstructionSourceRevisionAuthority(projectID: id(3), jobID: id(4), function: function,
            objectiveSHA256: sha("objective"), evidenceFrontierSHA256: sha("frontier"), oracleSuiteSHA256: sha("oracle"),
            admissibleEvidenceIDs: [id(5)], currentRevision: current)
        let offset = prior.count * 100
        let task = ReconstructionTaskRecord(identity: try .make(taskID: id(6 + offset), jobID: id(4), kind: .modelRound,
            subject: .function(function), dependencyTaskIDs: [], operationContractIdentity: ReconstructionSourceRevisionEvidence.taskContract),
            state: .completed, diagnostic: nil)
        let receipt = try ReconstructionReceiptAuthority.makeModelReceipt(receiptID: id(7 + offset), jobID: id(4), taskID: id(6 + offset),
            checkpointRevision: UInt64(prior.count + 1), requestIdentitySHA256: sha("request"),
            producer: producer(ReconstructionSourceRevisionEvidence.operationID), terminalState: .completed,
            selectedHandleIDs: [], acceptedEvidenceIDs: [receiptEvidenceID ?? id(8)], diagnostic: nil)
        let checkpoint = try ReconstructionCheckpoint.make(checkpointID: id(9 + offset), jobID: id(4), revision: UInt64(prior.count + 1),
            parentCheckpointID: priorContexts.last?.checkpoint.checkpointID ?? id(10),
            parentCheckpointSHA256: priorContexts.last?.checkpoint.canonicalSHA256 ?? sha("parent"), corpusManifestSHA256: sha("corpus"),
            evidenceFrontierSHA256: sha("new-frontier"), pendingTaskIDs: [], runningTaskIDs: [], completedTaskIDs: [id(6 + offset)],
            failedTaskIDs: [], blockedTaskIDs: [], unresolvedEvidenceGapSHA256: sha("gaps"),
            modelReceiptIDs: [id(7 + offset)], toolReceiptIDs: [], coordinatorState: .checkpointing, terminalReason: nil)
        let payload = Data("independent admitted oracle observation".utf8)
        let evidence = try ReconstructionEvidenceRecord(evidenceID: id(5), subject: .function(function),
            operationID: "reconstruction.function.review", payloadKind: .text, payload: payload,
            payloadByteCount: UInt64(payload.count), payloadSHA256: sha(String(decoding: payload, as: UTF8.self)),
            facetDependencies: [], producer: producer("reconstruction.function.review"), citations: [],
            creatingJobID: id(4), creatingTaskID: id(11), creatingCheckpointID: id(10), modelReceiptID: nil,
            toolReceiptID: id(12), classification: .acceptedCurrent, supersedesEvidenceID: nil,
            supersededByEvidenceID: nil, diagnostic: nil)
        return .init(admissionAuthority: authority, task: task, checkpoint: checkpoint, modelReceipt: receipt,
            expectedRequestIdentitySHA256: request ?? sha("request"), committedEvidenceCut: [evidence],
            committedPriorRevisionRecords: prior, priorRevisionContexts: priorContexts)
    }
    private func proposal(parent: String? = nil) -> ReconstructionSourceRevisionProposal {
        let bytes = Data("#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x == UINT32_MAX ? x : x + 1; }\n".utf8)
        return .init(parentRevisionSHA256: parent, sourceUTF8: bytes,
            claimedSourceSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(bytes), evidenceIDs: [id(5)])
    }
    private func mutate(_ record: ReconstructionEvidenceRecord, _ edit: (inout [String: Any]) -> Void) throws -> ReconstructionEvidenceRecord {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(record)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(ReconstructionEvidenceRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testSourceRecordRoundtripsExistingEvidenceCodec() throws {
        let context = try context()
        let record = try ReconstructionSourceRevisionEvidence.make(evidenceID: id(8), proposal: proposal(), context: context)
        let revision = try ReconstructionSourceRevisionEvidence.validate(record: record, context: context)
        XCTAssertEqual(revision.status, .proposed)
        XCTAssertEqual(record.modelReceiptID, context.modelReceipt.receiptID)
        XCTAssertEqual(record.citations.map(\.sourceEvidenceID), [id(5)])
        let decoded = try JSONDecoder().decode(ReconstructionEvidenceRecord.self, from: ReconstructionCanonicalJSON.encode(record))
        XCTAssertEqual(try ReconstructionSourceRevisionEvidence.validate(record: decoded, context: context), revision)
    }
    func testRejectsRecordPayloadSubjectReceiptAndCitationTampering() throws {
        let context = try context()
        let record = try ReconstructionSourceRevisionEvidence.make(evidenceID: id(8), proposal: proposal(), context: context)
        let badDigest = try mutate(record) { $0["payloadSHA256"] = sha("tampered") }
        XCTAssertThrowsError(try ReconstructionSourceRevisionEvidence.validate(record: badDigest, context: context))
        let artifactSubject = try JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(ReconstructionSubjectCoordinate.artifact(context.admissionAuthority.function.artifact)))
        let wrongSubject = try mutate(record) { $0["subject"] = artifactSubject }
        XCTAssertThrowsError(try ReconstructionSourceRevisionEvidence.validate(record: wrongSubject, context: context))
        let wrongReceipt = try mutate(record) { $0["modelReceiptID"] = id(90).uuidString }
        XCTAssertThrowsError(try ReconstructionSourceRevisionEvidence.validate(record: wrongReceipt, context: context))
        let wrongCitation = try mutate(record) { $0["citations"] = [["citationID": id(5).uuidString, "sourceEvidenceID": id(91).uuidString]] }
        XCTAssertThrowsError(try ReconstructionSourceRevisionEvidence.validate(record: wrongCitation, context: context))
        var forgedRevision = try XCTUnwrap(JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
        forgedRevision["oracleSuiteSHA256"] = sha("invented-oracle")
        let forgedBytes = try JSONSerialization.data(withJSONObject: forgedRevision, options: [.sortedKeys, .withoutEscapingSlashes])
        let forgedPayload = try mutate(record) {
            $0["payload"] = forgedBytes.base64EncodedString(); $0["payloadByteCount"] = forgedBytes.count
            $0["payloadSHA256"] = ReconstructionSourceRevisionAdmission.sourceSHA256(forgedBytes)
        }
        XCTAssertThrowsError(try ReconstructionSourceRevisionEvidence.validate(record: forgedPayload, context: context))
    }
    func testRejectsWrongRequestOrReceiptMembership() throws {
        XCTAssertThrowsError(try ReconstructionSourceRevisionEvidence.make(evidenceID: id(8), proposal: proposal(),
            context: context(request: sha("other-request"))))
        XCTAssertThrowsError(try ReconstructionSourceRevisionEvidence.make(evidenceID: id(8), proposal: proposal(),
            context: context(receiptEvidenceID: id(90))))
    }
    func testParentChainAndTwoRevisionLimit() throws {
        let firstContext = try context()
        let parentRecord = try ReconstructionSourceRevisionEvidence.make(evidenceID: id(8), proposal: proposal(), context: firstContext)
        let parent = try ReconstructionSourceRevisionEvidence.validate(record: parentRecord, context: firstContext)
        let childContext = try context(prior: [parentRecord], current: parent, receiptEvidenceID: id(13), priorContexts: [firstContext])
        let childRecord = try ReconstructionSourceRevisionEvidence.make(evidenceID: id(13), proposal: proposal(parent: parent.revisionSHA256), context: childContext)
        let child = try ReconstructionSourceRevisionEvidence.validate(record: childRecord, context: childContext)
        XCTAssertEqual(child.parentRevisionSHA256, parent.revisionSHA256)
        XCTAssertNotEqual(firstContext.task.identity.taskID, childContext.task.identity.taskID)
        XCTAssertNotEqual(firstContext.modelReceipt.receiptID, childContext.modelReceipt.receiptID)
        XCTAssertNotEqual(firstContext.checkpoint.checkpointID, childContext.checkpoint.checkpointID)
        XCTAssertThrowsError(try ReconstructionSourceRevisionEvidence.make(evidenceID: id(13), proposal: proposal(parent: parent.revisionSHA256),
            context: context(current: parent, receiptEvidenceID: id(13))))
        XCTAssertThrowsError(try ReconstructionSourceRevisionEvidence.make(evidenceID: id(14), proposal: proposal(parent: child.revisionSHA256),
            context: context(prior: [parentRecord, childRecord], current: child, receiptEvidenceID: id(14), priorContexts: [firstContext, childContext]))) {
            XCTAssertEqual($0 as? ReconstructionSourceRevisionEvidence.Failure, .revisionBudgetExhausted)
        }
    }
    func testRejectsForgedParentProvenanceAndMissingRetainedHistory() throws {
        let firstContext = try context()
        let parentRecord = try ReconstructionSourceRevisionEvidence.make(evidenceID: id(8), proposal: proposal(), context: firstContext)
        let parent = try ReconstructionSourceRevisionEvidence.validate(record: parentRecord, context: firstContext)
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["modelReceiptID"] = NSNull(); $0["toolReceiptID"] = self.id(90).uuidString },
            { $0["creatingTaskID"] = self.id(90).uuidString },
            { $0["creatingCheckpointID"] = self.id(90).uuidString },
            { $0["citations"] = [] }
        ]
        for change in changes {
            let forged = try mutate(parentRecord, change)
            XCTAssertThrowsError(try ReconstructionSourceRevisionEvidence.make(evidenceID: id(13),
                proposal: proposal(parent: parent.revisionSHA256),
                context: context(prior: [forged], current: parent, receiptEvidenceID: id(13), priorContexts: [firstContext])))
        }
        XCTAssertThrowsError(try ReconstructionSourceRevisionEvidence.make(evidenceID: id(13),
            proposal: proposal(parent: parent.revisionSHA256),
            context: context(prior: [parentRecord], current: parent, receiptEvidenceID: id(13))))
        var reused = try context(prior: [parentRecord], current: parent, receiptEvidenceID: id(13), priorContexts: [firstContext])
        reused.priorRevisionContexts = [reused]
        XCTAssertThrowsError(try ReconstructionSourceRevisionEvidence.make(evidenceID: id(13),
            proposal: proposal(parent: parent.revisionSHA256), context: reused))
    }

}
