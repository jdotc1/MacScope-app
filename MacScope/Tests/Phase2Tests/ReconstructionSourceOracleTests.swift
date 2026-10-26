import Foundation
import XCTest
@testable import MacScope

final class ReconstructionSourceOracleTests: XCTestCase {
    func testProfileDispatchRejectsForeignOracleAuthorityAndPreservesScalarPayload() throws {
        let base = try authority()
        let scalar = try ReconstructionSourceOracleEvidence.admit(authority: base)
        let bytes = try ReconstructionSourceOracleEvidence.encode(scalar)
        XCTAssertEqual(try ReconstructionSourceOracleEvidence.encode(
            ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(payload: bytes)), bytes)
        for profile in ["arm64-c-adler32-combine-record-v1", "unknown-profile"] {
            let foreign = ReconstructionSourceOracleAuthority(projectID: base.projectID, jobID: base.jobID,
                function: base.function, execution: base.execution, evidenceIDs: base.evidenceIDs, profileID: profile)
            XCTAssertThrowsError(try ReconstructionSourceOracleEvidence.admit(authority: foreign))
            XCTAssertThrowsError(try ReconstructionSourceOracleEvidence.decodeAndValidate(payload: bytes, authority: foreign))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object["profileID"] = profile
            XCTAssertThrowsError(try ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(
                payload: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])))
        }
    }

    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "ac000000-0000-0000-0000-%012d", n))! }
    private func sha(_ text: String) -> String { ReconstructionSourceRevisionAdmission.sourceSHA256(Data(text.utf8)) }
    private func producer() throws -> ReconstructionProducerIdentity {
        let p = try ReconstructionProducerIdentity(macScopeBuildIdentity: sha("build"), macScopeSourceIdentity: sha("source"),
            operationIdentity: ReconstructionSourceOracleEvidence.operationID, registryIdentity: sha("registry"),
            protocolIdentity: sha("protocol"), toolchainIdentity: sha("toolchain"), canonicalSHA256: sha("placeholder"))
        return try .init(macScopeBuildIdentity: p.macScopeBuildIdentity, macScopeSourceIdentity: p.macScopeSourceIdentity,
            operationIdentity: p.operationIdentity, registryIdentity: p.registryIdentity, protocolIdentity: p.protocolIdentity,
            toolchainIdentity: p.toolchainIdentity, canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalProducerSHA256(p))
    }
    private func authority() throws -> ReconstructionSourceOracleAuthority {
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: id(1)),
            contentIdentity: try .init(algorithm: .sha256, digest: sha("original binary"), byteCount: 32))
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: id(2), imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: sha("analysis"), startAddress: 0x1000, endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        // Synthetic observed transcript exercises admission only. Deliberately constant outputs
        // prove this codec never substitutes the expected saturation formula for an observation.
        let observed = Data(harness.inputs.map { "\($0):7\n" }.joined().utf8)
        return .init(projectID: id(3), jobID: id(4), function: function,
            execution: .init(originalImageSHA256: artifact.contentIdentity.digest,
                originalExecutableSHA256: sha("original executable"), originalSourceSHA256: sha("original source"),
                harnessSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(harness.sourceUTF8),
                compilerSHA256: sha("compiler"), sdkIdentitySHA256: sha("sdk"), compileProfileSHA256: sha("profile"),
                compileArgumentsSHA256: sha("fixed compile arguments"), executionArgumentsSHA256: sha("fixed execution arguments"),
                producerSHA256: try producer().canonicalSHA256, standardOutput: observed,
                sessionID: id(10), requestID: id(11), processIdentifier: 123,
                sampledProcessIDs: [123], exitCode: 0, observedProcessAbsent: true), evidenceIDs: [id(5)])
    }
    private func context(request: String? = nil, outputID: UUID? = nil) throws -> ReconstructionSourceOracleEvidence.Context {
        let authority = try authority(), producer = try producer()
        let task = ReconstructionTaskRecord(identity: try .make(taskID: id(6), jobID: id(4), kind: .retrieveEvidence,
            subject: .function(authority.function), dependencyTaskIDs: [], operationContractIdentity: ReconstructionSourceOracleEvidence.taskContract),
            state: .completed, diagnostic: nil)
        let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: id(7), jobID: id(4), taskID: id(6),
            checkpointRevision: 1, requestIdentitySHA256: sha("request"), producer: producer,
            terminalState: .completed, outputEvidenceIDs: [outputID ?? id(8)], diagnostic: nil)
        let checkpoint = try ReconstructionCheckpoint.make(checkpointID: id(9), jobID: id(4), revision: 1,
            parentCheckpointID: id(12), parentCheckpointSHA256: sha("parent"), corpusManifestSHA256: sha("corpus"),
            evidenceFrontierSHA256: sha("frontier"), pendingTaskIDs: [], runningTaskIDs: [], completedTaskIDs: [id(6)],
            failedTaskIDs: [], blockedTaskIDs: [], unresolvedEvidenceGapSHA256: sha("gaps"),
            modelReceiptIDs: [], toolReceiptIDs: [id(7)], coordinatorState: .checkpointing, terminalReason: nil)
        let bytes = Data("original function observation".utf8)
        let evidence = try ReconstructionEvidenceRecord(evidenceID: id(5), subject: .function(authority.function),
            operationID: ReconstructionSourceOracleEvidence.operationID, payloadKind: .text, payload: bytes,
            payloadByteCount: UInt64(bytes.count), payloadSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(bytes),
            facetDependencies: [], producer: producer, citations: [], creatingJobID: id(4), creatingTaskID: id(13),
            creatingCheckpointID: id(12), modelReceiptID: nil, toolReceiptID: id(14), classification: .acceptedCurrent,
            supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        return .init(authority: authority, task: task, checkpoint: checkpoint, toolReceipt: receipt,
            expectedRequestIdentitySHA256: request ?? sha("request"), expectedProducer: producer, committedEvidenceCut: [evidence])
    }
    private func alteredExecution(_ edit: (inout [String: Any]) -> Void) throws -> ReconstructionSourceOracleAuthority {
        let base = try authority()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(base.execution)) as? [String: Any])
        edit(&object)
        let execution = try JSONDecoder().decode(ReconstructionSourceOracle.Execution.self, from: JSONSerialization.data(withJSONObject: object))
        return .init(projectID: base.projectID, jobID: base.jobID, function: base.function, execution: execution, evidenceIDs: base.evidenceIDs)
    }
    private func alteredRecord(_ record: ReconstructionEvidenceRecord, _ edit: (inout [String: Any]) -> Void) throws -> ReconstructionEvidenceRecord {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(record)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(ReconstructionEvidenceRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testOrdered37CaseObservationRoundtripDoesNotInventExpectedFormula() throws {
        let authority = try authority(), oracle = try ReconstructionSourceOracleEvidence.admit(authority: authority)
        XCTAssertEqual(oracle.inputs, try ReconstructionSourceBehaviorHarness.saturatingIncrementV1().inputs)
        XCTAssertEqual(oracle.inputs.count, 37)
        XCTAssertEqual(oracle.outputs, Array(repeating: 7, count: 37))
        let bytes = try ReconstructionSourceOracleEvidence.encode(oracle)
        XCTAssertEqual(try ReconstructionSourceOracleEvidence.decodeAndValidate(payload: bytes, authority: authority), oracle)
        XCTAssertNotEqual(oracle.suiteSHA256, ReconstructionSourceRevisionAdmission.sourceSHA256(bytes))
        XCTAssertEqual(try ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(payload: bytes), oracle)
    }
    func testOracleRecordUsesActualCanonicalToolReceiptAndCheckpoint() throws {
        let context = try context(), record = try ReconstructionSourceOracleEvidence.make(evidenceID: id(8), context: context)
        XCTAssertEqual(record.toolReceiptID, context.toolReceipt.receiptID)
        XCTAssertNil(record.modelReceiptID)
        let decoded = try JSONDecoder().decode(ReconstructionEvidenceRecord.self, from: ReconstructionCanonicalJSON.encode(record))
        XCTAssertEqual(try ReconstructionSourceOracleEvidence.validate(record: decoded, context: context).suiteSHA256,
                       try ReconstructionSourceOracleEvidence.admit(authority: context.authority).suiteSHA256)
        XCTAssertThrowsError(try ReconstructionSourceOracleEvidence.make(evidenceID: id(8), context: self.context(request: sha("wrong"))))
        XCTAssertThrowsError(try ReconstructionSourceOracleEvidence.make(evidenceID: id(8), context: self.context(outputID: id(90))))
    }
    func testObservedOrderBoundsTerminalCleanupAndHarnessCannotBeReplaced() throws {
        let authority = try authority()
        let text = String(decoding: authority.execution.standardOutput, as: UTF8.self)
        let lines = text.split(separator: "\n")
        for transcript in [lines.reversed().joined(separator: "\n") + "\n", text + "0:7\n", String(repeating: "x", count: 16_385), "0:7\n"] {
            XCTAssertThrowsError(try ReconstructionSourceOracleEvidence.admit(authority: alteredExecution { $0["standardOutput"] = Data(transcript.utf8).base64EncodedString() }))
        }
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["exitCode"] = 1 }, { $0["observedProcessAbsent"] = false },
            { $0["sampledProcessIDs"] = [] }, { $0["harnessSHA256"] = self.sha("changed") },
            { $0["originalImageSHA256"] = self.sha("different image") }
        ]
        for edit in edits { XCTAssertThrowsError(try ReconstructionSourceOracleEvidence.admit(authority: alteredExecution(edit))) }
    }
    func testHostilePayloadCannotRehashInventedOracleOrToolchainAuthority() throws {
        let authority = try authority(), bytes = try ReconstructionSourceOracleEvidence.encode(ReconstructionSourceOracleEvidence.admit(authority: authority))
        for key in ["compilerSHA256", "sdkIdentitySHA256", "originalExecutableSHA256", "producerSHA256"] {
            let invented = try alteredExecution { $0[key] = sha("invented") }
            let forgedBytes = try ReconstructionSourceOracleEvidence.encode(ReconstructionSourceOracleEvidence.admit(authority: invented))
            // The new suite digest is valid locally, but it cannot replace the owner's actual cut.
            XCTAssertNoThrow(try ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(payload: forgedBytes))
            XCTAssertThrowsError(try ReconstructionSourceOracleEvidence.decodeAndValidate(payload: forgedBytes, authority: authority))
        }
        XCTAssertThrowsError(try ReconstructionSourceOracleEvidence.decodeAndValidate(payload: bytes + Data(" ".utf8), authority: authority))
        XCTAssertThrowsError(try ReconstructionSourceOracleEvidence.decodeAndValidate(payload: Data(repeating: 32, count: 65_537), authority: authority))
        let string = String(decoding: bytes, as: UTF8.self)
        XCTAssertThrowsError(try ReconstructionSourceOracleEvidence.decodeAndValidate(payload: Data(string.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1").utf8), authority: authority))
    }
    func testPureCanonicalDecoderRecomputesSuiteAndFixedInputsAndObservedOutputs() throws {
        let bytes = try ReconstructionSourceOracleEvidence.encode(ReconstructionSourceOracleEvidence.admit(authority: authority()))
        for key in ["suiteSHA256", "inputs", "outputs", "version", "profileID"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            switch key {
            case "suiteSHA256": object[key] = sha("invented suite")
            case "inputs": object[key] = Array(try ReconstructionSourceBehaviorHarness.saturatingIncrementV1().inputs.reversed())
            case "outputs": object[key] = Array(repeating: 8, count: 37)
            case "version": object[key] = 2
            default: object[key] = "other-profile"
            }
            let decoded = try JSONDecoder().decode(ReconstructionSourceOracle.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(payload: ReconstructionSourceOracleEvidence.encode(decoded)), key)
        }
    }
    func testRecordSubjectCitationAndReceiptTamperingReject() throws {
        let context = try context(), record = try ReconstructionSourceOracleEvidence.make(evidenceID: id(8), context: context)
        let wrongSubject = try JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(ReconstructionSubjectCoordinate.artifact(context.authority.function.artifact)))
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["subject"] = wrongSubject },
            { $0["toolReceiptID"] = self.id(90).uuidString },
            { $0["creatingTaskID"] = self.id(90).uuidString },
            { $0["citations"] = [] },
            { $0["payloadSHA256"] = self.sha("tampered") }
        ]
        for edit in edits { XCTAssertThrowsError(try ReconstructionSourceOracleEvidence.validate(record: alteredRecord(record, edit), context: context)) }
    }
}
