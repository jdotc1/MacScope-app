import Foundation
import XCTest
@testable import MacScope

final class ReconstructionProductionSourceAuthorityTests: XCTestCase {
    func testFixtureRetainsCanonicalGenesisAndExactCheckpointParentChain() throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        let checkpoints = fixture.basis.checkpointHistory + [fixture.basis.checkpoint]
        let genesis = try XCTUnwrap(checkpoints.first)
        XCTAssertEqual(checkpoints.map(\.revision), [0, 1, 2])
        XCTAssertNil(genesis.parentCheckpointID)
        XCTAssertNil(genesis.parentCheckpointSHA256)
        XCTAssertEqual(genesis.coordinatorState, .created)
        XCTAssertTrue(genesis.modelReceiptIDs.isEmpty)
        XCTAssertTrue(genesis.toolReceiptIDs.isEmpty)
        for checkpoint in checkpoints { try checkpoint.verifyCanonicalIdentity() }
        for (parent, child) in zip(checkpoints, checkpoints.dropFirst()) {
            XCTAssertEqual(child.parentCheckpointID, parent.checkpointID)
            XCTAssertEqual(child.parentCheckpointSHA256, parent.canonicalSHA256)
            XCTAssertEqual(child.revision, parent.revision + 1)
        }
    }

    func testSourceBaseBudgetRetainsSmallObservationWithItsFullAuthority() throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        let observation = try XCTUnwrap(fixture.basis.evidenceCut.records.first {
            $0.evidenceID == ProductionSourceOwnerFixture.id(23)
        })
        XCTAssertEqual(observation.payload, Data("controlled original function observation".utf8))
        XCTAssertEqual(observation.payload.count, 40)
        let compiler = ReconstructionContextCompiler(
            maximumContextBytes: ReconstructionSourceContextCompiler.maximumBaseContextBytes)
        // The cap applies to the complete canonical packet, including coordinates and provenance.
        // A small observation must not be mistaken for a packet that fits the former 2 KiB cap:
        // it travels alone on a flagged oversize page with its evidence bytes intact (lead 0351).
        let oversize = try ReconstructionRetrievalCompiler().compileSourceBase(cut: fixture.basis.evidenceCut,
            query: fixture.sourceQuery(maximumEncodedBytes: 2_048))
        XCTAssertTrue(oversize.oversizePage)
        XCTAssertNil(oversize.recordTooLarge)
        XCTAssertGreaterThan(oversize.encodedByteCount, 2_048)
        XCTAssertEqual(oversize.records.map(\.record), [observation])
        let query = try fixture.sourceQuery()
        let boundedQuery = try compiler.boundedQuery(cut: fixture.basis.evidenceCut, query: query,
            allowedGapSubjects: [], allowedGapCategories: [])
        let packet = try ReconstructionRetrievalCompiler().compileSourceBase(
            cut: fixture.basis.evidenceCut, query: boundedQuery)
        XCTAssertGreaterThan(packet.encodedByteCount, 2_048)
        XCTAssertLessThanOrEqual(packet.encodedByteCount, boundedQuery.maximumEncodedBytes)
        XCTAssertEqual(packet.records.map(\.record), [observation])
        XCTAssertEqual(packet.records.first?.checkpointRevision, 1)
        let base = try compiler.compileSourceBase(cut: fixture.basis.evidenceCut, query: query)
        XCTAssertLessThanOrEqual(base.canonicalBytes.count,
            ReconstructionSourceContextCompiler.maximumBaseContextBytes)
        let request = try fixture.request()
        let envelope = try JSONDecoder().decode(ReconstructionSourceContextCompiler.Envelope.self,
            from: request.context.canonicalBytes)
        XCTAssertEqual(envelope.baseContext, base.canonicalBytes)
        XCTAssertEqual(envelope.oracle.evidenceID, ProductionSourceOwnerFixture.id(26))
        XCTAssertEqual(envelope.oracle.inputs, fixture.oracle.inputs)
        XCTAssertEqual(envelope.oracle.outputs, fixture.oracle.outputs)
        XCTAssertEqual(envelope.oracle.inputs.count, 37)
        XCTAssertEqual(request.context.evidenceIDs,
            [ProductionSourceOwnerFixture.id(23), ProductionSourceOwnerFixture.id(26)])
        XCTAssertLessThanOrEqual(request.context.canonicalBytes.count,
            ReconstructionSourceContextCompiler.maximumContextBytes)
    }

    func testCapturedAuthorityBindsExactRequestAndDeliveredIDs() throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        let request = try fixture.request()
        let captured = try ReconstructionProductionSourceAuthority.capture(request: request, basis: fixture.basis)
        let binding = try XCTUnwrap(captured.authority.requestBinding)
        XCTAssertEqual(binding.canonicalRequestBytes, try ReconstructionCanonicalJSON.encode(request))
        XCTAssertEqual(binding.requestSHA256, try ReconstructionCanonicalJSON.sha256(of: request))
        XCTAssertEqual(binding.taskID, request.taskID)
        XCTAssertEqual(captured.authority.admissibleEvidenceIDs, Set(request.context.evidenceIDs))
        XCTAssertEqual(captured.authority.oracleSuiteSHA256, fixture.oracle.suiteSHA256)
        XCTAssertTrue(captured.priorRecords.isEmpty)
    }

    func testAlteredContextOrDeliveredIDsCannotAcquireAuthority() throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        let request = try fixture.request()
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: request.context.canonicalBytes) as? [String: Any])
        envelope["domain"] = "invented-presentation"
        let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        let altered = ReconstructionRetrievedContext(canonicalBytes: bytes,
            canonicalSHA256: ProductionSourceOwnerFixture.sha(bytes), evidenceIDs: request.context.evidenceIDs)
        XCTAssertThrowsError(try ReconstructionProductionSourceAuthority.capture(
            request: fixture.request(context: altered), basis: fixture.basis))
        let omitted = ReconstructionRetrievedContext(canonicalBytes: request.context.canonicalBytes,
            canonicalSHA256: request.context.canonicalSHA256,
            evidenceIDs: request.context.evidenceIDs + [ProductionSourceOwnerFixture.id(999)])
        XCTAssertThrowsError(try ReconstructionProductionSourceAuthority.capture(
            request: fixture.request(context: omitted), basis: fixture.basis))
    }

    func testDifferentOracleAndStaleCheckpointCannotReplaceCommittedAuthority() throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        XCTAssertThrowsError(try ReconstructionProductionSourceAuthority.capture(
            request: fixture.request(oracleSHA256: ProductionSourceOwnerFixture.sha(Data("other oracle".utf8))),
            basis: fixture.basis))
        let request = try fixture.request()
        let stale = try ProductionSourceOwnerFixture.alter(request) { $0["checkpointRevision"] = 1 }
        XCTAssertThrowsError(try ReconstructionProductionSourceAuthority.capture(request: stale, basis: fixture.basis))
    }

    func testOperationAdmissionAcceptsOnlyExactCommittedLegacyCut() throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        let rows = try operationRows(fixture)
        let descriptor = try operationDescriptor(fixture)
        XCTAssertNoThrow(try ReconstructionDatabaseOwner.validateOperationDescriptor(descriptor, rows: rows))
        XCTAssertEqual(descriptor.evidenceIDs, fixture.basis.evidenceCut.records.map(\.evidenceID))
        XCTAssertTrue(descriptor.dependencies.declaredArtifacts.isEmpty,
            "Empty declarations are not a proof of dependency independence")
        for field in ["project", "job", "checkpoint", "revision", "checkpointDigest", "manifest", "frontier"] {
            XCTAssertThrowsError(try ReconstructionDatabaseOwner.validateOperationDescriptor(
                operationDescriptor(fixture, changed: field), rows: rows), field) {
                XCTAssertEqual($0 as? ReconstructionOperationAdmissionError, .staleCut, field)
            }
        }
    }

    func testOperationAdmissionRejectsUnboundEvidenceObservationAndDependencies() throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        let rows = try operationRows(fixture)
        for field in ["evidence", "missingBase", "suite", "payload", "compiler", "sdk", "harness",
                      "compileProfile", "compileArguments", "executionArguments", "artifact"] {
            XCTAssertThrowsError(try ReconstructionDatabaseOwner.validateOperationDescriptor(
                operationDescriptor(fixture, changed: field), rows: rows), field)
        }
        XCTAssertThrowsError(try ReconstructionDatabaseOwner.validateOperationDescriptor(
            operationDescriptor(fixture), rows: operationRows(fixture, omitReceipts: true)))
        XCTAssertThrowsError(try ReconstructionDatabaseOwner.validateOperationDescriptor(
            operationDescriptor(fixture), rows: operationRows(fixture, staleAnalysis: true)))
    }

    func testOperationAdmissionRejectsMalformedAndOversizedDescriptors() throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        for field in ["version", "contract", "duplicateEvidence", "tooMuchEvidence", "tooManyArtifacts", "digest"] {
            XCTAssertThrowsError(try operationDescriptor(fixture, changed: field).validateShape(), field)
        }
    }

    func testOperationAdmissionRejectsDisabledProfilesBeforeOwnerReadAndHonorsRevocation() async throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        let database = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let owner = ReconstructionDatabaseOwner(database: database.database, databaseAuthorityValidator: {
            XCTFail("Disabled and unknown operation profiles must reject before reading a database cut")
        })
        for profile in ["arm64-c-adler32-combine-record-v1", "unknown-profile"] {
            do {
                _ = try await owner.captureOperationAdmission(workspaceID: database.workspaceUUID,
                    descriptor: operationDescriptor(fixture, profile: profile))
                XCTFail("Unsupported profile admitted")
            } catch {
                XCTAssertEqual(error as? ReconstructionOperationAdmissionError, .unsupportedProfile)
            }
        }
        await owner.revoke()
        do {
            _ = try await owner.captureOperationAdmission(workspaceID: database.workspaceUUID,
                descriptor: operationDescriptor(fixture))
            XCTFail("Revoked owner admitted a descriptor")
        } catch {
            XCTAssertEqual(error as? ReconstructionDatabaseOwnerError, .revoked)
        }
    }

    func testProfileDispatchRetainsLegacyNilJobAndBindsCapturedSourceAuthority() throws {
        let fixture = try ProductionSourceOwnerFixture.make(), request = try fixture.request()
        XCTAssertNil(fixture.basis.job.sourceProfileID)
        let captured = try ReconstructionProductionSourceAuthority.capture(request: request, basis: fixture.basis)
        XCTAssertEqual(captured.authority.profileID, request.profileID)
        XCTAssertEqual(try ReconstructionProductionSourceAuthority.committedOracle(
            function: fixture.function, basis: fixture.basis).profileID, request.profileID)
        XCTAssertFalse(ReconstructionSourceProfile.admits(nil))
        for profile in ["arm64-c-adler32-combine-record-v1", "unknown-profile"] {
            let foreign = try ProductionSourceOwnerFixture.alter(request) { $0["profileID"] = profile }
            XCTAssertThrowsError(try ReconstructionProductionSourceAuthority.capture(request: foreign, basis: fixture.basis))
            XCTAssertThrowsError(try ProductionSourceOwnerFixture.alter(fixture.basis.job) { $0["sourceProfileID"] = profile })
            let binding = try XCTUnwrap(captured.authority.requestBinding)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: binding.canonicalRequestBytes) as? [String: Any])
            var objective = try XCTUnwrap(object["objective"] as? [String: Any])
            objective["sourceProfileID"] = profile; object["objective"] = objective
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.makeRequestBinding(canonicalRequestBytes: bytes,
                requestSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(bytes), authority: captured.authority,
                expectedTaskID: binding.taskID, expectedRoundID: binding.roundID,
                expectedCheckpointRevision: binding.checkpointRevision))
        }
    }

    private func operationRows(_ fixture: ProductionSourceOwnerFixture, omitReceipts: Bool = false,
                               staleAnalysis: Bool = false) throws -> ReconstructionProductionRoundRows {
        let basis = fixture.basis
        let job = try ProductionSourceOwnerFixture.alter(basis.job) {
            $0["sourceProfileID"] = ReconstructionSourceRevision.profileID
        }
        return .init(workspaceID: basis.workspaceID, project: basis.project, manifest: basis.manifest,
            job: job, checkpoint: basis.checkpoint, tasks: basis.tasks,
            toolReceipts: omitReceipts ? [] : basis.toolReceipts, modelReceipts: basis.modelReceipts,
            taskCompletionAuthorities: basis.taskCompletionAuthorities, attachmentSources: [],
            evidence: basis.evidenceCut.records, evidenceRelations: basis.evidenceCut.relations,
            evidenceGaps: basis.evidenceCut.gaps,
            checkpointRevisionsByID: basis.evidenceCut.checkpointRevisionsByID,
            freshnessAuthority: try .init(corpusManifestSHA256: basis.manifest.canonicalSHA256,
                currentArtifacts: [fixture.function.artifact],
                currentImages: staleAnalysis ? [] : basis.freshnessAuthority.currentImages,
                currentFacetFingerprints: [.function(fixture.function): [:]]),
            checkpointHistory: basis.checkpointHistory)
    }

    private func operationDescriptor(_ fixture: ProductionSourceOwnerFixture, changed: String = "",
                                     profile: String = ReconstructionSourceRevision.profileID) throws
        -> ReconstructionOperationDescriptor {
        let basis = fixture.basis
        let execution = fixture.oracle.execution
        let oracleRecord = try XCTUnwrap(basis.evidenceCut.records.first {
            $0.operationID == ReconstructionSourceOracleEvidence.operationID
        })
        let other = ProductionSourceOwnerFixture.hash("different operation commitment")
        func digest(_ field: String, _ original: String) -> String { changed == field ? other : original }
        var ids = basis.evidenceCut.records.map(\.evidenceID)
        if changed == "evidence" { ids.append(UUID()) }
        if changed == "duplicateEvidence" { ids.append(oracleRecord.evidenceID) }
        if changed == "tooMuchEvidence" { ids += (0..<65).map { _ in UUID() } }
        if changed == "missingBase" { ids = [oracleRecord.evidenceID] }
        var artifacts: [ReconstructionArtifactCoordinate] = []
        if changed == "artifact" || changed == "tooManyArtifacts" {
            artifacts = (0..<(changed == "artifact" ? 1 : 17)).map { _ in
                .init(occurrenceID: .init(rawValue: UUID()), contentIdentity: fixture.function.artifact.contentIdentity)
            }
        }
        return .init(version: changed == "version" ? 2 : 1, profileID: profile,
            projectID: changed == "project" ? UUID() : basis.project.projectID,
            jobID: changed == "job" ? UUID() : basis.job.jobID, function: fixture.function,
            checkpointID: changed == "checkpoint" ? UUID() : basis.checkpoint.checkpointID,
            checkpointRevision: basis.checkpoint.revision + (changed == "revision" ? 1 : 0),
            checkpointSHA256: changed == "digest" ? "invalid" : digest("checkpointDigest", basis.checkpoint.canonicalSHA256),
            corpusManifestSHA256: digest("manifest", basis.manifest.canonicalSHA256),
            evidenceFrontierSHA256: digest("frontier", basis.evidenceCut.frontierSHA256), evidenceIDs: ids,
            observation: .init(contractID: changed == "contract" ? "unknown" : ReconstructionSourceExecutionTaskContract.oracle,
                evidenceID: oracleRecord.evidenceID, payloadSHA256: digest("payload", oracleRecord.payloadSHA256),
                suiteSHA256: digest("suite", fixture.oracle.suiteSHA256)),
            dependencies: .init(compilerSHA256: digest("compiler", execution.compilerSHA256),
                sdkIdentitySHA256: digest("sdk", execution.sdkIdentitySHA256),
                harnessSHA256: digest("harness", execution.harnessSHA256),
                compileProfileSHA256: digest("compileProfile", execution.compileProfileSHA256),
                compileArgumentsSHA256: digest("compileArguments", execution.compileArgumentsSHA256),
                executionArgumentsSHA256: digest("executionArguments", execution.executionArgumentsSHA256),
                declaredArtifacts: artifacts))
    }

    func testPendingDirectDescriptorRetainsSourceRequestWithoutAuthorizingExecution() throws {
        let fixture = try ProductionSourceOwnerFixture.make(sourceState: .pending)
        XCTAssertFalse(ReconstructionProductionPreparedRoundBuilder.modelExecutionIsDurablyAuthorized(fixture.basis.tasks))
        let prepared = try ReconstructionProductionPreparedRoundBuilder.makeDirectCommitDescriptor(from: fixture.basis)
        let request = try XCTUnwrap(prepared.sourceRevisionRequest)
        XCTAssertEqual(request.taskID, fixture.model.identity.taskID)
        XCTAssertEqual(request.context, try fixture.request().context)
        XCTAssertTrue(prepared.requests.isEmpty)
        XCTAssertNil(prepared.finalSynthesisRequest)
    }
}

/// Synthetic execution receipts test owner admission only; these observations are deliberately
/// constant and are not native original-function execution evidence or a qualified oracle.
struct ProductionSourceOwnerFixture {
    let basis: ReconstructionProductionRoundBasis
    let function: ReconstructionFunctionCoordinate
    let oracle: ReconstructionSourceOracle
    let model: ReconstructionTaskRecord
    let sourceCheckpoint: ReconstructionTaskRecord

    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "be000000-0000-0000-0000-%012d", value))!
    }
    static func sha(_ bytes: Data) -> String { ReconstructionSourceRevisionAdmission.sourceSHA256(bytes) }
    static func hash(_ text: String) -> String { sha(Data(text.utf8)) }
    static func alter<T: Codable>(_ value: T, edit: (inout [String: Any]) -> Void) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(value)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    static func producer(_ operation: String) throws -> ReconstructionProducerIdentity {
        let p = try ReconstructionProducerIdentity(macScopeBuildIdentity: hash("build"),
            macScopeSourceIdentity: hash("source"), operationIdentity: operation,
            registryIdentity: hash("registry"), protocolIdentity: hash("protocol"),
            toolchainIdentity: hash("toolchain"), canonicalSHA256: hash("placeholder"))
        let digest = try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(p)
        return try alter(p) { $0["canonicalSHA256"] = digest }
    }
    static func task(_ number: Int, jobID: UUID, kind: ReconstructionTaskKind,
                     subject: ReconstructionSubjectCoordinate? = nil, dependencies: [UUID] = [],
                     state: ReconstructionTaskState = .completed, contract: String? = nil) throws -> ReconstructionTaskRecord {
        .init(identity: try .make(taskID: id(number), jobID: jobID, kind: kind, subject: subject,
            dependencyTaskIDs: dependencies, operationContractIdentity: contract ?? "reconstruction.\(kind.rawValue).v1"),
            state: state, diagnostic: nil)
    }

    static func make(sourceState: ReconstructionTaskState = .running) throws -> Self {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(workspaceBinaryID: id(1))
        let jobID = foundation.job.jobID
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity)
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: id(2), imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: hash("analysis"), startAddress: 0x1000, endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
        let ingest = try task(10, jobID: jobID, kind: .ingest, subject: .artifact(artifact))
        let retrieve = try task(11, jobID: jobID, kind: .retrieveEvidence, dependencies: [ingest.identity.taskID],
            contract: ReconstructionProductionTaskContract.evidenceQuery)
        let ordinaryModel = try task(12, jobID: jobID, kind: .modelRound, dependencies: [retrieve.identity.taskID])
        let ordinaryCheckpoint = try task(13, jobID: jobID, kind: .checkpoint, dependencies: [ordinaryModel.identity.taskID])
        let oracleTask = try task(14, jobID: jobID, kind: .retrieveEvidence, subject: .function(function),
            contract: ReconstructionSourceOracleEvidence.taskContract)
        let model = try task(15, jobID: jobID, kind: .modelRound, subject: .function(function),
            dependencies: [ordinaryCheckpoint.identity.taskID], state: sourceState,
            contract: ReconstructionSourceRevisionEvidence.taskContract)
        let sourceCheckpoint = try task(16, jobID: jobID, kind: .checkpoint,
            dependencies: [model.identity.taskID], state: .pending)
        let tasks = [ingest, retrieve, ordinaryModel, ordinaryCheckpoint, oracleTask, model, sourceCheckpoint]
        let ordinaryReceipt = try ReconstructionReceiptAuthority.makeModelReceipt(receiptID: id(20), jobID: jobID,
            taskID: ordinaryModel.identity.taskID, checkpointRevision: 1, requestIdentitySHA256: hash("ordinary request"),
            producer: producer(ReconstructionProductionTaskContract.modelRound), terminalState: .completed,
            selectedHandleIDs: [], acceptedEvidenceIDs: [], diagnostic: nil)
        let oracleProducer = try producer(ReconstructionSourceOracleEvidence.operationID)
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        let authority = ReconstructionSourceOracleAuthority(projectID: foundation.project.projectID, jobID: jobID,
            function: function, execution: .init(originalImageSHA256: artifact.contentIdentity.digest,
                originalExecutableSHA256: artifact.contentIdentity.digest, originalSourceSHA256: hash("original source"),
                harnessSHA256: sha(harness.sourceUTF8), compilerSHA256: hash("compiler"), sdkIdentitySHA256: hash("SDK"),
                compileProfileSHA256: hash("profile"), compileArgumentsSHA256: hash("compile arguments"),
                executionArgumentsSHA256: hash("run arguments"), producerSHA256: oracleProducer.canonicalSHA256,
                standardOutput: Data(harness.inputs.map { "\($0):7\n" }.joined().utf8), sessionID: id(21), requestID: id(22),
                processIdentifier: 123, sampledProcessIDs: [123], exitCode: 0, observedProcessAbsent: true), evidenceIDs: [id(23)])
        let observation = Data("controlled original function observation".utf8)
        let baseRecord = try ReconstructionEvidenceRecord(evidenceID: id(23), subject: .function(function),
            operationID: "reconstruction.function.review", payloadKind: .text, payload: observation,
            payloadByteCount: UInt64(observation.count), payloadSHA256: sha(observation), facetDependencies: [],
            producer: oracleProducer, citations: [], creatingJobID: jobID, creatingTaskID: oracleTask.identity.taskID,
            creatingCheckpointID: id(25), modelReceiptID: nil, toolReceiptID: id(24), classification: .acceptedCurrent,
            supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        let oracleReceipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: id(24), jobID: jobID,
            taskID: oracleTask.identity.taskID, checkpointRevision: 1, requestIdentitySHA256: hash("oracle request"),
            producer: oracleProducer, terminalState: .completed, outputEvidenceIDs: [id(26)], diagnostic: nil)
        let originalTasks = tasks.filter {
            $0.identity.taskID != model.identity.taskID && $0.identity.taskID != sourceCheckpoint.identity.taskID
        }
        let genesisFrontier = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: foundation.manifest.canonicalSHA256, records: [],
            projectedClassificationsByEvidenceID: [:], relations: [], gaps: [], checkpointRevisionsByID: [:])
        let genesis = try checkpoint(id: id(28), revision: 0, parent: nil, manifest: foundation.manifest,
            frontier: genesisFrontier, tasks: originalTasks.map { .init(identity: $0.identity, state: .pending, diagnostic: nil) },
            modelReceipts: [], toolReceipts: [], jobID: jobID, coordinatorState: .created)
        let originalCheckpoint = try checkpoint(id: id(25), revision: 1, parent: genesis, manifest: foundation.manifest,
            frontier: hash("initial frontier"), tasks: originalTasks,
            modelReceipts: [ordinaryReceipt], toolReceipts: [oracleReceipt], jobID: jobID)
        let oracleRecord = try ReconstructionSourceOracleEvidence.make(evidenceID: id(26), context: .init(authority: authority,
            task: oracleTask, checkpoint: originalCheckpoint, toolReceipt: oracleReceipt,
            expectedRequestIdentitySHA256: hash("oracle request"), expectedProducer: oracleProducer, committedEvidenceCut: [baseRecord]))
        let oracle = try ReconstructionSourceOracleEvidence.admit(authority: authority)
        let records = [baseRecord, oracleRecord]
        let basis = try rebuild(foundation: foundation, tasks: tasks, records: records,
            modelReceipts: [ordinaryReceipt], toolReceipts: [oracleReceipt], history: [genesis, originalCheckpoint],
            function: function, revision: 2, checkpointID: id(27), parent: originalCheckpoint)
        return .init(basis: basis, function: function, oracle: oracle, model: model, sourceCheckpoint: sourceCheckpoint)
    }

    static func checkpoint(id: UUID, revision: UInt64, parent: ReconstructionCheckpoint?,
        manifest: ReconstructionCorpusManifest, frontier: String, tasks: [ReconstructionTaskRecord],
        modelReceipts: [ReconstructionModelReceipt], toolReceipts: [ReconstructionToolReceipt], jobID: UUID,
        coordinatorState: ReconstructionJobState = .retrieving) throws -> ReconstructionCheckpoint {
        try .make(checkpointID: id, jobID: jobID, revision: revision, parentCheckpointID: parent?.checkpointID,
            parentCheckpointSHA256: parent?.canonicalSHA256, corpusManifestSHA256: manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier, pendingTaskIDs: tasks.filter { $0.state == .pending }.map(\.identity.taskID),
            runningTaskIDs: tasks.filter { $0.state == .running }.map(\.identity.taskID),
            completedTaskIDs: tasks.filter { $0.state == .completed }.map(\.identity.taskID), failedTaskIDs: [], blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: ReconstructionEvidenceGapFrontier.canonicalSHA256(for: []),
            modelReceiptIDs: modelReceipts.map(\.receiptID), toolReceiptIDs: toolReceipts.map(\.receiptID),
            coordinatorState: coordinatorState, terminalReason: nil)
    }
    static func rebuild(foundation: ReconstructionDatabaseTestFixtures.StateFixture, tasks: [ReconstructionTaskRecord],
        records: [ReconstructionEvidenceRecord], modelReceipts: [ReconstructionModelReceipt], toolReceipts: [ReconstructionToolReceipt],
        history: [ReconstructionCheckpoint], function: ReconstructionFunctionCoordinate, revision: UInt64,
        checkpointID: UUID, parent: ReconstructionCheckpoint?) throws -> ReconstructionProductionRoundBasis {
        let classifications = Dictionary(uniqueKeysWithValues: records.map { ($0.evidenceID, ReconstructionEvidenceClassification.acceptedCurrent) })
        var revisions: [UUID: UInt64] = [:]
        for record in records { revisions[record.creatingCheckpointID] = history.first { $0.checkpointID == record.creatingCheckpointID }?.revision ?? revision }
        let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(corpusManifestSHA256: foundation.manifest.canonicalSHA256,
            records: records, projectedClassificationsByEvidenceID: classifications, relations: [], gaps: [], checkpointRevisionsByID: revisions)
        let cut = try ReconstructionEvidenceCut(corpusManifestSHA256: foundation.manifest.canonicalSHA256, records: records,
            relations: [], gaps: [], frontierSHA256: frontier, projectedClassificationsByEvidenceID: classifications, checkpointRevisionsByID: revisions)
        let checkpoint = try checkpoint(id: checkpointID, revision: revision, parent: parent, manifest: foundation.manifest,
            frontier: frontier, tasks: tasks, modelReceipts: modelReceipts, toolReceipts: toolReceipts, jobID: foundation.job.jobID)
        let job = try ReconstructionJobRecord(jobID: foundation.job.jobID, reconstructionProjectID: foundation.project.projectID,
            objective: foundation.job.objective, objectiveSHA256: foundation.job.objectiveSHA256,
            creationCorpusManifestSHA256: foundation.manifest.canonicalSHA256, state: .retrieving,
            currentCheckpointID: checkpointID, terminalReason: nil,
            budget: .init(maxRounds: 8, maxTasks: 32, maxEvidenceRecords: 128, maxEncodedBytes: 1_048_576), creationOrdinal: 1)
        let snapshot = ReconstructionJobOrchestrationSnapshot(jobID: job.jobID, jobCreationOrder: 1,
            checkpointID: checkpointID, checkpointRevision: revision, checkpointCorpusManifestSHA256: foundation.manifest.canonicalSHA256,
            checkpointEvidenceFrontierSHA256: frontier, currentCorpusManifestSHA256: foundation.manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier, currentDurableJobState: .retrieving, pauseContext: nil, maximumRoundsWithoutEvidence: 8,
            tasks: tasks, terminalReceiptStatesByTaskID: Dictionary(uniqueKeysWithValues: modelReceipts.map { ($0.taskID, ReconstructionTaskState.completed) }),
            consecutiveModelRoundsWithoutEvidence: 1)
        return try .init(workspaceID: id(30), project: foundation.project, manifest: foundation.manifest, job: job,
            checkpoint: checkpoint, tasks: tasks, toolReceipts: toolReceipts, modelReceipts: modelReceipts,
            taskCompletionAuthorities: [.init(taskID: id(11), firstCompletedAtRevision: 1), .init(taskID: id(12), firstCompletedAtRevision: 1)],
            attachmentSources: foundation.manifest.artifacts.map { .init(contentIdentity: $0.contentIdentity,
                verifiedURL: TestWorkRoot.authorityURL("source-owner-fixture-\($0.contentIdentity.digest)")) },
            evidenceCut: cut, freshnessAuthority: .init(corpusManifestSHA256: foundation.manifest.canonicalSHA256,
                currentArtifacts: [function.artifact], currentImages: [.init(artifact: function.artifact, image: function.image,
                    analysisFingerprintSHA256: function.analysisFingerprintSHA256)],
                currentFacetFingerprints: [:]), snapshot: snapshot, checkpointHistory: history)
    }
    func sourceQuery(maximumEncodedBytes: Int = ReconstructionSourceContextCompiler.maximumBaseContextBytes) throws
        -> ReconstructionRetrievalQuery {
        try ReconstructionRetrievalQuery(corpusManifestSHA256: basis.manifest.canonicalSHA256,
            subject: .function(function), operationIDs: MacScopeAnalysisCore.ReconstructionOperationID.allCases, classifications: [.acceptedCurrent],
            cursor: nil, maximumRecords: 4, maximumEncodedBytes: maximumEncodedBytes, focus: basis.job.focus)
    }
    func request(context: ReconstructionRetrievedContext? = nil, oracleSHA256: String? = nil,
                 parentSHA256: String? = nil) throws -> ReconstructionSourceRevisionRequest {
        let query = try sourceQuery()
        let context = try context ?? ReconstructionSourceContextCompiler().compile(cut: basis.evidenceCut, query: query,
            function: function, oracleSuiteSHA256: oracle.suiteSHA256, parentRevisionSHA256: parentSHA256)
        return try .init(protocolVersion: 10, objective: .init(jobID: basis.job.jobID,
            text: basis.job.objective, sha256: basis.job.objectiveSHA256), projectID: basis.project.projectID, jobID: basis.job.jobID,
            taskID: model.identity.taskID, checkpointRevision: basis.checkpoint.revision, roundID: Self.id(31), function: function,
            corpusManifestSHA256: basis.manifest.canonicalSHA256, evidenceFrontierSHA256: basis.evidenceCut.frontierSHA256,
            oracleSuiteSHA256: oracleSHA256 ?? oracle.suiteSHA256, profileID: ReconstructionSourceRevision.profileID,
            parentRevisionSHA256: parentSHA256, context: context)
    }
}
