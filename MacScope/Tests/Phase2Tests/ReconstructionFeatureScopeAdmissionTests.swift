import Foundation
import XCTest

@testable import MacScope

/// U06 admission through the existing database owner. The committed history mirrors
/// ReconstructionWorkspaceDatabaseAtomicityTests with synthetic constant-output oracle receipts.
/// No process capture, inference, or real-binary behavior is represented by these fixtures.
final class ReconstructionFeatureScopeAdmissionTests: XCTestCase {
    private struct Admitted {
        let database: WorkspaceDatabase
        let workspaceID: UUID
        let state: ReconstructionWorkspaceState
        let job: ReconstructionJobRecord
        let checkpoint: ReconstructionCheckpoint
        let function: ReconstructionFunctionCoordinate
        let seedEvidenceID: UUID
        let oracleEvidenceID: UUID
        let oracle: ReconstructionSourceOracle
        let freshness: ReconstructionFreshnessAuthority
    }

    private func committedOracleHistory() throws -> Admitted {
        let database = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: database.binaryID, evidenceSubjectUsesFunction: true)
        let function = try XCTUnwrap({ () -> ReconstructionFunctionCoordinate? in
            if case .function(let coordinate)? = foundation.task.identity.subject { return coordinate }
            return nil
        }(), "required synthetic fixture task must be function-scoped")
        let profiledJob = try ReconstructionJobRecord(jobID: foundation.job.jobID,
            reconstructionProjectID: foundation.job.reconstructionProjectID, objective: foundation.job.objective,
            objectiveSHA256: foundation.job.objectiveSHA256,
            creationCorpusManifestSHA256: foundation.job.creationCorpusManifestSHA256, state: foundation.job.state,
            currentCheckpointID: foundation.job.currentCheckpointID, terminalReason: nil,
            budget: foundation.job.budget, creationOrdinal: foundation.job.creationOrdinal ?? 1,
            sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID)
        let seedTaskID = UUID(), seedEvidenceID = UUID(), seedReceiptID = UUID()
        let sourceTask = ReconstructionTaskRecord(identity: try ReconstructionTaskIdentity.make(
            taskID: foundation.task.identity.taskID, jobID: foundation.job.jobID,
            kind: .executeSource, subject: .function(function), dependencyTaskIDs: [seedTaskID],
            operationContractIdentity: ReconstructionSourceExecutionTaskContract.oracle), state: .pending, diagnostic: nil)
        let seedTask = ReconstructionTaskRecord(identity: try ReconstructionTaskIdentity.make(
            taskID: seedTaskID, jobID: foundation.job.jobID, kind: .decompileNative,
            subject: .function(function), dependencyTaskIDs: [],
            operationContractIdentity: foundation.task.identity.operationContractIdentity), state: .completed, diagnostic: nil)
        let seedProducer = try ReconstructionDatabaseTestFixtures.makeProducer(operationID: ReconstructionOperationID.evidenceQuery.rawValue)
        let seedBytes = Data("Committed original function context".utf8)
        let seedReceipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: seedReceiptID,
            jobID: foundation.job.jobID, taskID: seedTaskID, checkpointRevision: 0,
            requestIdentitySHA256: String(repeating: "b", count: 64), producer: seedProducer,
            terminalState: .completed, outputEvidenceIDs: [seedEvidenceID], diagnostic: nil)
        let seed = try ReconstructionEvidenceRecord(evidenceID: seedEvidenceID, subject: .function(function),
            operationID: ReconstructionOperationID.evidenceQuery.rawValue, payloadKind: .text, payload: seedBytes,
            payloadByteCount: UInt64(seedBytes.count), payloadSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(seedBytes),
            facetDependencies: [], producer: seedProducer,
            citations: [try .init(citationID: UUID(), sourceEvidenceID: nil, subject: .function(function), locator: nil)],
            creatingJobID: foundation.job.jobID, creatingTaskID: seedTaskID,
            creatingCheckpointID: foundation.checkpoint.checkpointID, modelReceiptID: nil,
            toolReceiptID: seedReceiptID, classification: .acceptedCurrent, supersedesEvidenceID: nil,
            supersededByEvidenceID: nil, diagnostic: nil)
        // Function evidence is accepted-current only with its image current and a facet entry for the
        // function (empty, matching the records' empty facet dependencies).
        let base = try ReconstructionDatabaseTestFixtures.makeFreshnessAuthority(
            from: foundation, includesCurrentAnalysis: true)
        let freshness = try ReconstructionFreshnessAuthority(corpusManifestSHA256: base.corpusManifestSHA256,
            currentArtifacts: base.currentArtifacts, currentImages: base.currentImages,
            currentFacetFingerprints: [.function(function): [:]])
        func frontier(_ records: [ReconstructionEvidenceRecord], revisions: [UUID: UInt64]) throws -> String {
            let projection = try ReconstructionEvidenceProjector().project(records: records, relations: [], authority: freshness)
            return try ReconstructionEvidenceFrontier.canonicalSHA256(
                corpusManifestSHA256: foundation.manifest.canonicalSHA256, records: records,
                projectedClassificationsByEvidenceID: Dictionary(uniqueKeysWithValues: projection.records.map {
                    ($0.record.evidenceID, $0.classification)
                }), relations: [], gaps: foundation.state.evidenceGaps, checkpointRevisionsByID: revisions)
        }
        let parent = try ReconstructionCheckpoint.make(checkpointID: foundation.checkpoint.checkpointID,
            jobID: foundation.job.jobID, revision: 0, parentCheckpointID: nil, parentCheckpointSHA256: nil,
            corpusManifestSHA256: foundation.manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier([seed], revisions: [foundation.checkpoint.checkpointID: 0]),
            pendingTaskIDs: [sourceTask.identity.taskID], runningTaskIDs: [], completedTaskIDs: [seedTaskID],
            failedTaskIDs: [], blockedTaskIDs: [], unresolvedEvidenceGapSHA256: foundation.checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: [], toolReceiptIDs: [seedReceiptID], coordinatorState: .retrieving, terminalReason: nil)
        let initialState = try ReconstructionWorkspaceState(projects: foundation.state.projects,
            corpusManifests: foundation.state.corpusManifests, evidence: [seed], evidenceRelations: [],
            evidenceGaps: foundation.state.evidenceGaps, jobs: [profiledJob],
            tasks: [sourceTask, seedTask], checkpoints: [parent], toolReceipts: [seedReceipt], modelReceipts: [])
        try database.database.replaceReconstructionState(workspaceID: database.workspaceUUID, state: initialState)
        let producer = try ReconstructionDatabaseTestFixtures.makeProducer(operationID: ReconstructionSourceOracleEvidence.operationID)
        let hash = String(repeating: "a", count: 64)
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        let oracle = try ReconstructionSourceOracleEvidence.admit(authority: .init(
            projectID: foundation.project.projectID, jobID: foundation.job.jobID, function: function,
            execution: .init(originalImageSHA256: function.artifact.contentIdentity.digest,
                originalExecutableSHA256: function.artifact.contentIdentity.digest, originalSourceSHA256: nil,
                harnessSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(harness.sourceUTF8),
                compilerSHA256: hash, sdkIdentitySHA256: hash, compileProfileSHA256: hash,
                compileArgumentsSHA256: hash, executionArgumentsSHA256: hash,
                producerSHA256: producer.canonicalSHA256,
                standardOutput: Data(harness.inputs.map { "\($0):7\n" }.joined().utf8),
                sessionID: UUID(), requestID: UUID(), processIdentifier: 123,
                sampledProcessIDs: [123], exitCode: 0, observedProcessAbsent: true),
            evidenceIDs: [seedEvidenceID]))
        let bytes = try ReconstructionSourceOracleEvidence.encode(oracle)
        let evidenceID = UUID(), receiptID = UUID(), checkpointID = UUID()
        let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: receiptID,
            jobID: foundation.job.jobID, taskID: foundation.task.identity.taskID,
            checkpointRevision: 1, requestIdentitySHA256: hash, producer: producer,
            terminalState: .completed, outputEvidenceIDs: [evidenceID], diagnostic: nil)
        let record = try ReconstructionEvidenceRecord(evidenceID: evidenceID, subject: .function(function),
            operationID: ReconstructionSourceOracleEvidence.operationID, payloadKind: .structuredJSON, payload: bytes,
            payloadByteCount: UInt64(bytes.count), payloadSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(bytes),
            facetDependencies: [], producer: producer,
            citations: [try .init(citationID: seedEvidenceID, sourceEvidenceID: seedEvidenceID, subject: nil, locator: nil)],
            creatingJobID: foundation.job.jobID, creatingTaskID: foundation.task.identity.taskID,
            creatingCheckpointID: checkpointID, modelReceiptID: nil, toolReceiptID: receiptID,
            classification: .acceptedCurrent, supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        let successor = try ReconstructionCheckpoint.make(checkpointID: checkpointID,
            jobID: foundation.job.jobID, revision: 1, parentCheckpointID: foundation.checkpoint.checkpointID,
            parentCheckpointSHA256: parent.canonicalSHA256,
            corpusManifestSHA256: foundation.manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier([seed, record], revisions: [parent.checkpointID: 0, checkpointID: 1]),
            pendingTaskIDs: [], runningTaskIDs: [], completedTaskIDs: [sourceTask.identity.taskID, seedTaskID],
            failedTaskIDs: [], blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: foundation.checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: [], toolReceiptIDs: [seedReceiptID, receiptID], coordinatorState: .retrieving, terminalReason: nil)
        let committed = try database.database.commitReconstructionCheckpoint(workspaceID: database.workspaceUUID,
            mutation: ReconstructionCheckpointMutation(jobID: foundation.job.jobID,
                expectedParentCheckpointID: foundation.checkpoint.checkpointID,
                expectedParentCheckpointSHA256: parent.canonicalSHA256,
                expectedParentRevision: 0, evidence: [record], evidenceRelations: [],
                toolReceipts: [receipt], modelReceipts: [],
                taskTransitions: [.init(taskID: foundation.task.identity.taskID, expectedState: .pending,
                    successorState: .completed, diagnostic: nil)], freshnessAuthority: freshness,
                successorCheckpoint: successor))
        let job = try XCTUnwrap(committed.state.jobs.first { $0.jobID == foundation.job.jobID })
        return Admitted(database: database.database, workspaceID: database.workspaceUUID, state: committed.state,
            job: job, checkpoint: committed.checkpoint, function: function, seedEvidenceID: seedEvidenceID,
            oracleEvidenceID: evidenceID, oracle: oracle, freshness: freshness)
    }

    private func scope(_ history: Admitted, suite: String? = nil, caseCount: Int? = nil,
                       checkpoint: ReconstructionCheckpoint? = nil) throws -> ReconstructionFeatureScope {
        let checkpoint = checkpoint ?? history.checkpoint
        return try .make(projectID: history.job.reconstructionProjectID, jobID: history.job.jobID,
            feature: history.function,
            acceptedEvidenceIDs: [history.seedEvidenceID, history.oracleEvidenceID],
            scenarios: [.init(oracleEvidenceID: history.oracleEvidenceID,
                              suiteSHA256: suite ?? history.oracle.suiteSHA256,
                              caseCount: caseCount ?? history.oracle.inputs.count, role: .development)],
            dependencies: [], dependencyBasisEvidenceIDs: [history.seedEvidenceID],
            observationContract: .scalarU32ReturnV1, admittedAtCheckpointID: checkpoint.checkpointID,
            admittedAtCheckpointRevision: checkpoint.revision,
            admittedAtCheckpointSHA256: checkpoint.canonicalSHA256,
            evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256)
    }

    private func admit(_ history: Admitted, _ scope: ReconstructionFeatureScope) throws -> ReconstructionCommittedFeatureScope {
        try history.database.admitReconstructionFeatureScope(workspaceID: history.workspaceID,
            admission: .init(jobID: history.job.jobID, scope: scope, freshnessAuthority: history.freshness))
    }

    func testScalarOracleScopeIsAdmittedWithoutChangingJobStateAndReloads() throws {
        let history = try committedOracleHistory()
        let cut = try history.database.loadReconstructionState(workspaceID: history.workspaceID)
        let projection = try ReconstructionEvidenceProjector().project(records: cut.evidence, relations: [],
                                                                       authority: history.freshness)
        XCTAssertEqual(Set(projection.records.map(\.classification)), [.acceptedCurrent],
                       "fixture precondition: both cited records are accepted-current")
        let admitted = try scope(history)
        let committed = try admit(history, admitted)
        XCTAssertEqual(committed.job.featureScope, admitted)
        XCTAssertEqual(committed.job.recordSchemaVersion, ReconstructionJobRecord.featureScopeSchemaVersion)
        XCTAssertEqual(committed.job.state, history.job.state)
        XCTAssertEqual(committed.job.currentCheckpointID, history.job.currentCheckpointID)
        XCTAssertEqual(try committed.job.removingFeatureScope(), history.job)
        XCTAssertEqual(committed.state.tasks, history.state.tasks)
        XCTAssertEqual(committed.state.checkpoints, history.state.checkpoints)
        XCTAssertEqual(committed.state.evidence, history.state.evidence)
        let loaded = try history.database.loadReconstructionState(workspaceID: history.workspaceID)
        XCTAssertEqual(loaded, committed.state)

        XCTAssertEqual(try admit(history, admitted).state, committed.state, "re-admission is idempotent")
    }

    func testDifferentSecondScopeIsAConflictAndStateIsUnchanged() throws {
        let history = try committedOracleHistory()
        let first = try admit(history, try scope(history))
        let second = try ReconstructionFeatureScope.make(projectID: history.job.reconstructionProjectID,
            jobID: history.job.jobID, feature: history.function, acceptedEvidenceIDs: [history.oracleEvidenceID],
            scenarios: [.init(oracleEvidenceID: history.oracleEvidenceID, suiteSHA256: history.oracle.suiteSHA256,
                              caseCount: history.oracle.inputs.count, role: .development)],
            dependencies: [], dependencyBasisEvidenceIDs: [history.oracleEvidenceID],
            observationContract: .scalarU32ReturnV1, admittedAtCheckpointID: history.checkpoint.checkpointID,
            admittedAtCheckpointRevision: history.checkpoint.revision,
            admittedAtCheckpointSHA256: history.checkpoint.canonicalSHA256,
            evidenceFrontierSHA256: history.checkpoint.evidenceFrontierSHA256)
        XCTAssertThrowsError(try admit(history, second)) {
            XCTAssertEqual($0 as? WorkspaceDatabase.DatabaseError, .reconstructionIdentityConflict("feature scope"))
        }
        XCTAssertEqual(try history.database.loadReconstructionState(workspaceID: history.workspaceID), first.state)
    }

    func testMismatchedScenarioAndStaleCheckpointRejectWithoutMutation() throws {
        let history = try committedOracleHistory()
        XCTAssertThrowsError(try admit(history, try scope(history, suite: String(repeating: "d", count: 64)))) {
            XCTAssertEqual($0 as? WorkspaceDatabase.DatabaseError, .reconstructionStateInvalid("feature scope scenario"))
        }
        XCTAssertThrowsError(try admit(history, try scope(history, caseCount: history.oracle.inputs.count - 1))) {
            XCTAssertEqual($0 as? WorkspaceDatabase.DatabaseError, .reconstructionStateInvalid("feature scope scenario"))
        }
        let ancestor = try XCTUnwrap(history.state.checkpoints.first { $0.revision == 0 })
        XCTAssertThrowsError(try admit(history, try scope(history, checkpoint: ancestor))) {
            XCTAssertEqual($0 as? WorkspaceDatabase.DatabaseError,
                           .reconstructionCheckpointConflict("feature scope checkpoint changed"))
        }
        XCTAssertEqual(try history.database.loadReconstructionState(workspaceID: history.workspaceID), history.state)
    }
    private func replacing<Value: Codable>(_ value: Value, _ edit: (inout [String: Any]) throws -> Void) throws -> Value {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(value))
            as? [String: Any])
        try edit(&object)
        return try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func rows(_ history: Admitted, job: ReconstructionJobRecord? = nil,
                      checkpoint: ReconstructionCheckpoint? = nil,
                      freshness: ReconstructionFreshnessAuthority? = nil) throws -> ReconstructionProductionRoundRows {
        let project = try XCTUnwrap(history.state.projects.first)
        let manifest = try XCTUnwrap(history.state.corpusManifests.first {
            $0.canonicalSHA256 == history.checkpoint.corpusManifestSHA256
        })
        return ReconstructionProductionRoundRows(workspaceID: history.workspaceID,
            project: project, manifest: manifest, job: job ?? history.job,
            checkpoint: checkpoint ?? history.checkpoint, tasks: history.state.tasks,
            toolReceipts: history.state.toolReceipts, modelReceipts: [], taskCompletionAuthorities: [],
            attachmentSources: [], evidence: history.state.evidence, evidenceRelations: history.state.evidenceRelations,
            evidenceGaps: history.state.evidenceGaps,
            checkpointRevisionsByID: Dictionary(uniqueKeysWithValues: history.state.checkpoints.filter {
                Set(history.state.evidence.map(\.creatingCheckpointID)).contains($0.checkpointID)
            }.map { ($0.checkpointID, $0.revision) }), freshnessAuthority: freshness ?? history.freshness, checkpointHistory: history.state.checkpoints)
    }

    private func alteredScope(_ history: Admitted, feature: ReconstructionFunctionCoordinate? = nil,
                              accepted: [UUID]? = nil, extraScenario: Bool = false) throws -> ReconstructionFeatureScope {
        let ids = accepted ?? [history.seedEvidenceID, history.oracleEvidenceID]
        var scenarios = [ReconstructionFeatureScenario(oracleEvidenceID: history.oracleEvidenceID,
            suiteSHA256: history.oracle.suiteSHA256, caseCount: history.oracle.inputs.count, role: .development)]
        if extraScenario {
            scenarios.append(.init(oracleEvidenceID: history.seedEvidenceID,
                suiteSHA256: history.oracle.suiteSHA256, caseCount: history.oracle.inputs.count, role: .development))
        }
        return try .make(projectID: history.job.reconstructionProjectID, jobID: history.job.jobID,
            feature: feature ?? history.function, acceptedEvidenceIDs: ids, scenarios: scenarios,
            dependencies: [], dependencyBasisEvidenceIDs: [ids[0]], observationContract: .scalarU32ReturnV1,
            admittedAtCheckpointID: history.checkpoint.checkpointID,
            admittedAtCheckpointRevision: history.checkpoint.revision,
            admittedAtCheckpointSHA256: history.checkpoint.canonicalSHA256,
            evidenceFrontierSHA256: history.checkpoint.evidenceFrontierSHA256)
    }

    func testPersistedScopeAndTransientAdmissionShareFocusAndOracleEvidenceRules() throws {
        let history = try committedOracleHistory()
        let cut = try rows(history)
        let valid = try scope(history)
        let descriptor = try ReconstructionDatabaseOwner.operationDescriptor(for: valid, rows: cut)
        XCTAssertNoThrow(try ReconstructionDatabaseOwner.validateOperationDescriptor(descriptor, rows: cut))
        let foreignFunction = try replacing(history.function) { $0["startAddress"] = history.function.startAddress + 1 }
        let wrongFocus = try replacing(history.job) {
            $0["focus"] = try JSONSerialization.jsonObject(with:
                ReconstructionCanonicalJSON.encode(ReconstructionSubjectCoordinate.function(foreignFunction)))
        }
        XCTAssertThrowsError(try ReconstructionDatabaseOwner.validateOperationDescriptor(descriptor,
            rows: rows(history, job: wrongFocus)))
        XCTAssertThrowsError(try wrongFocus.admitting(valid))
        let missingBase = try alteredScope(history, accepted: [history.oracleEvidenceID])
        XCTAssertThrowsError(try admit(history, missingBase))
        XCTAssertThrowsError(try ReconstructionDatabaseOwner.operationDescriptor(for: missingBase, rows: cut))
        let multiple = try alteredScope(history, extraScenario: true)
        XCTAssertThrowsError(try admit(history, multiple))
        XCTAssertThrowsError(try ReconstructionDatabaseOwner.operationDescriptor(for: multiple, rows: cut))
        XCTAssertEqual(try history.database.loadReconstructionState(workspaceID: history.workspaceID), history.state)
    }

    func testPackageScopeRebindsScenarioToHistoricalOracleAndManifest() throws {
        let history = try committedOracleHistory()
        let valid = try scope(history)
        let scoped = try history.job.admitting(valid)
        func state(job: ReconstructionJobRecord, manifests: [ReconstructionCorpusManifest]? = nil) throws -> ReconstructionWorkspaceState {
            try ReconstructionWorkspaceState(projects: history.state.projects,
                corpusManifests: manifests ?? history.state.corpusManifests,
                evidence: history.state.evidence, evidenceRelations: history.state.evidenceRelations,
                evidenceGaps: history.state.evidenceGaps, jobs: [job], tasks: history.state.tasks,
                checkpoints: history.state.checkpoints, toolReceipts: history.state.toolReceipts, modelReceipts: [])
        }
        XCTAssertNoThrow(try ReconstructionPackageCodec.validateGraph(state(job: scoped)))
        let foreignFunction = try replacing(history.function) { $0["startAddress"] = history.function.startAddress + 1 }
        for tampered in [try scope(history, suite: String(repeating: "d", count: 64)),
                         try scope(history, caseCount: history.oracle.inputs.count - 1),
                         try alteredScope(history, feature: foreignFunction)] {
            XCTAssertThrowsError(try ReconstructionPackageCodec.validateGraph(state(job: history.job.admitting(tampered))))
        }
        // Tasks still own the feature in creation corpus M0. Only a declared dependency is
        // introduced in admission corpus M1; scope subjects must be resolved against M1.
        let originalManifest = try XCTUnwrap(history.state.corpusManifests.first)
        let dependency = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: .init(rawValue: UUID()), contentIdentity: history.function.artifact.contentIdentity,
            kind: .opaque, roles: [.dependency], executableMode: false, originalName: nil, diagnostic: nil)
        let artifacts = originalManifest.artifacts + [dependency]
        let later = try ReconstructionCorpusManifest(reconstructionProjectID: originalManifest.reconstructionProjectID,
            artifacts: artifacts, relations: originalManifest.relations,
            canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(
                reconstructionProjectID: originalManifest.reconstructionProjectID,
                artifacts: artifacts, relations: originalManifest.relations))
        let coordinate = ReconstructionArtifactCoordinate(occurrenceID: dependency.occurrenceID,
            contentIdentity: dependency.contentIdentity)
        let freshness = try ReconstructionFreshnessAuthority(corpusManifestSHA256: later.canonicalSHA256,
            currentArtifacts: history.freshness.currentArtifacts + [coordinate],
            currentImages: history.freshness.currentImages,
            currentFacetFingerprints: history.freshness.currentFacetFingerprints)
        let projection = try ReconstructionEvidenceProjector().project(records: history.state.evidence,
            relations: history.state.evidenceRelations, authority: freshness)
        let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(corpusManifestSHA256: later.canonicalSHA256,
            records: history.state.evidence,
            projectedClassificationsByEvidenceID: Dictionary(uniqueKeysWithValues: projection.records.map {
                ($0.record.evidenceID, $0.classification)
            }), relations: history.state.evidenceRelations, gaps: history.state.evidenceGaps,
            checkpointRevisionsByID: Dictionary(uniqueKeysWithValues: history.state.checkpoints.map {
                ($0.checkpointID, $0.revision)
            }))
        let old = history.checkpoint
        let admissionCheckpoint = try ReconstructionCheckpoint.make(checkpointID: old.checkpointID, jobID: old.jobID,
            revision: old.revision, parentCheckpointID: old.parentCheckpointID,
            parentCheckpointSHA256: old.parentCheckpointSHA256, corpusManifestSHA256: later.canonicalSHA256,
            evidenceFrontierSHA256: frontier, pendingTaskIDs: old.pendingTaskIDs, runningTaskIDs: old.runningTaskIDs,
            completedTaskIDs: old.completedTaskIDs, failedTaskIDs: old.failedTaskIDs, blockedTaskIDs: old.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: old.unresolvedEvidenceGapSHA256, modelReceiptIDs: old.modelReceiptIDs,
            toolReceiptIDs: old.toolReceiptIDs, coordinatorState: old.coordinatorState, terminalReason: old.terminalReason)
        let withDependency = try ReconstructionFeatureScope.make(projectID: valid.projectID, jobID: valid.jobID,
            feature: valid.feature, acceptedEvidenceIDs: valid.acceptedEvidenceIDs, scenarios: valid.scenarios,
            dependencies: [.init(kind: .callee, subject: .artifact(coordinate), symbol: nil,
                disposition: .modeledExternal, evidenceIDs: [history.seedEvidenceID])],
            dependencyBasisEvidenceIDs: valid.dependencyBasisEvidenceIDs, observationContract: valid.observationContract,
            admittedAtCheckpointID: admissionCheckpoint.checkpointID,
            admittedAtCheckpointRevision: admissionCheckpoint.revision,
            admittedAtCheckpointSHA256: admissionCheckpoint.canonicalSHA256,
            evidenceFrontierSHA256: admissionCheckpoint.evidenceFrontierSHA256)
        let laterState = try ReconstructionWorkspaceState(
            projects: history.state.projects.map { try replacing($0) { $0["currentCorpusManifestSHA256"] = later.canonicalSHA256 } },
            corpusManifests: history.state.corpusManifests + [later], evidence: history.state.evidence,
            evidenceRelations: history.state.evidenceRelations, evidenceGaps: history.state.evidenceGaps,
            jobs: [try history.job.admitting(withDependency)], tasks: history.state.tasks,
            checkpoints: history.state.checkpoints.map { $0.checkpointID == old.checkpointID ? admissionCheckpoint : $0 },
            toolReceipts: history.state.toolReceipts, modelReceipts: [])
        // Constructed local binding only: the historical helper selects admission M1. This
        // does not establish a supported corpus-migration workflow; the outer graph still pins
        // every checkpoint to the job's creation corpus and must reject this complete state.
        let historyIndex = try ReconstructionCorpusHistoryIndex(projects: laterState.projects,
            manifests: laterState.corpusManifests)
        XCTAssertNoThrow(try ReconstructionPackageCodec.validateFeatureScope(withDependency,
            job: XCTUnwrap(laterState.jobs.first), state: laterState,
            checkpoints: Dictionary(uniqueKeysWithValues: laterState.checkpoints.map { ($0.checkpointID, $0) }),
            corpusHistory: historyIndex))
        XCTAssertThrowsError(try ReconstructionPackageCodec.validateGraph(laterState)) {
            XCTAssertEqual($0 as? ReconstructionPackageValidationError, .stateGraphInvalid("checkpoint frontier"))
        }
        // Currency can disappear without deleting or invalidating the saved historical scope.
        XCTAssertEqual(ReconstructionFeatureScopeCurrency.of(valid, classifications: [:]), .stale(valid.acceptedEvidenceIDs))
        XCTAssertNoThrow(try ReconstructionPackageCodec.validateGraph(state(job: scoped)))
    }

    private func advance(_ history: Admitted) throws -> Admitted {
        let parent = history.checkpoint
        let successor = try ReconstructionCheckpoint.make(checkpointID: UUID(), jobID: history.job.jobID,
            revision: parent.revision + 1, parentCheckpointID: parent.checkpointID,
            parentCheckpointSHA256: parent.canonicalSHA256, corpusManifestSHA256: parent.corpusManifestSHA256,
            evidenceFrontierSHA256: parent.evidenceFrontierSHA256, pendingTaskIDs: parent.pendingTaskIDs,
            runningTaskIDs: parent.runningTaskIDs, completedTaskIDs: parent.completedTaskIDs,
            failedTaskIDs: parent.failedTaskIDs, blockedTaskIDs: parent.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: parent.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: parent.modelReceiptIDs, toolReceiptIDs: parent.toolReceiptIDs,
            coordinatorState: parent.coordinatorState, terminalReason: parent.terminalReason)
        let committed = try history.database.commitReconstructionCheckpoint(workspaceID: history.workspaceID,
            mutation: .init(jobID: history.job.jobID, expectedParentCheckpointID: parent.checkpointID,
                expectedParentCheckpointSHA256: parent.canonicalSHA256, expectedParentRevision: parent.revision,
                evidence: [], evidenceRelations: [], toolReceipts: [], modelReceipts: [], taskTransitions: [],
                freshnessAuthority: history.freshness, successorCheckpoint: successor))
        let job = try XCTUnwrap(committed.state.jobs.first { $0.jobID == history.job.jobID })
        return Admitted(database: history.database, workspaceID: history.workspaceID, state: committed.state,
            job: job, checkpoint: successor, function: history.function, seedEvidenceID: history.seedEvidenceID,
            oracleEvidenceID: history.oracleEvidenceID, oracle: history.oracle, freshness: history.freshness)
    }

    func testScopeAdmissionReconciliationPreservesExactJobAndAnchor() throws {
        let history = try committedOracleHistory()
        let valid = try scope(history)
        let committed = try admit(history, valid)
        let binding = ReconstructionWorkspaceStateBinding(workspaceID: history.workspaceID,
            documentID: UUID(), canonicalPackagePath: TestWorkRoot.authorityPath("synthetic-scope.macscope"))
        func cut(_ state: ReconstructionWorkspaceState) -> ReconstructionWorkspaceStateCut {
            .init(binding: binding, state: state, contentAvailability: state.corpusManifests.flatMap { $0.artifacts }.map {
                .init(contentIdentity: $0.contentIdentity, isAvailable: true)
            })
        }
        let decision = try ReconstructionWorkspaceStateReconciler.reconcile(package: cut(history.state),
            durable: .present(cut: cut(committed.state), corpusBasis: .untrusted))
        guard case .useDurableDescendant(let resolution) = decision else {
            return XCTFail("expected scope-only descendant, got \(decision)")
        }
        XCTAssertEqual(resolution.state, committed.state)
        XCTAssertEqual(try committed.job.removingFeatureScope(), history.job)
        XCTAssertEqual(try admit(history, valid).state, committed.state)
        let removal = try ReconstructionWorkspaceStateReconciler.reconcile(package: cut(committed.state),
            durable: .present(cut: cut(history.state), corpusBasis: .untrusted))
        // The older durable cut must never erase the package's set-once scope.
        if case .fastForwardDurableFromPackage(let kept) = removal {
            XCTAssertEqual(kept.state, committed.state)
        } else if case .conflict = removal {
            // A conservative conflict is also safe; do not accept the scope-less durable state.
        } else { XCTFail("scope removal accepted: \(removal)") }
        let advanced = try advance(history)
        XCTAssertEqual(advanced.job.featureScope, valid)
        XCTAssertEqual(advanced.job.featureScope?.admittedAtCheckpointID, history.checkpoint.checkpointID)
        XCTAssertNotEqual(advanced.job.currentCheckpointID, valid.admittedAtCheckpointID)
        let preserved = try ReconstructionWorkspaceStateReconciler.reconcile(package: cut(committed.state),
            durable: .present(cut: cut(advanced.state), corpusBasis: .untrusted))
        guard case .useDurableDescendant(let advancedResolution) = preserved else {
            return XCTFail("expected checkpoint descendant preserving scope, got \(preserved)")
        }
        XCTAssertEqual(advancedResolution.state, advanced.state)
        let combined = try ReconstructionWorkspaceStateReconciler.reconcile(package: cut(history.state),
            durable: .present(cut: cut(advanced.state), corpusBasis: .untrusted))
        guard case .conflict = combined else {
            return XCTFail("adding a scope while advancing must refuse: \(combined)")
        }
        // Same-scope admission is a historical no-op even after checkpoint advancement.
        XCTAssertEqual(try admit(history, valid).state, advanced.state)
    }

    func testTransientProjectionOfPersistedScopeRechecksCurrentCut() throws {
        let history = try committedOracleHistory()
        let valid = try scope(history)
        let committed = try admit(history, valid)
        let cut = try rows(history, job: committed.job)
        let descriptor = try ReconstructionDatabaseOwner.operationDescriptor(for: valid, rows: cut)
        XCTAssertNoThrow(try ReconstructionDatabaseOwner.validateOperationDescriptor(descriptor, rows: cut))
        let stale = try ReconstructionFreshnessAuthority(corpusManifestSHA256: history.freshness.corpusManifestSHA256,
            currentArtifacts: [], currentImages: [], currentFacetFingerprints: [:])
        XCTAssertThrowsError(try ReconstructionDatabaseOwner.validateOperationDescriptor(descriptor,
            rows: rows(history, job: committed.job, freshness: stale)))
        let widened = ReconstructionOperationDescriptor(version: descriptor.version, profileID: descriptor.profileID,
            projectID: descriptor.projectID, jobID: descriptor.jobID, function: descriptor.function,
            checkpointID: descriptor.checkpointID, checkpointRevision: descriptor.checkpointRevision,
            checkpointSHA256: descriptor.checkpointSHA256, corpusManifestSHA256: descriptor.corpusManifestSHA256,
            evidenceFrontierSHA256: descriptor.evidenceFrontierSHA256, evidenceIDs: descriptor.evidenceIDs,
            observation: descriptor.observation,
            dependencies: .init(compilerSHA256: descriptor.dependencies.compilerSHA256,
                sdkIdentitySHA256: descriptor.dependencies.sdkIdentitySHA256,
                harnessSHA256: descriptor.dependencies.harnessSHA256,
                compileProfileSHA256: descriptor.dependencies.compileProfileSHA256,
                compileArgumentsSHA256: descriptor.dependencies.compileArgumentsSHA256,
                executionArgumentsSHA256: descriptor.dependencies.executionArgumentsSHA256,
                declaredArtifacts: [history.function.artifact]))
        XCTAssertThrowsError(try ReconstructionDatabaseOwner.validateOperationDescriptor(widened, rows: cut))
        XCTAssertEqual(try history.database.loadReconstructionState(workspaceID: history.workspaceID), committed.state)
        let advanced = try advance(history)
        let currentCut = try rows(advanced)
        let currentDescriptor = try ReconstructionDatabaseOwner.operationDescriptor(for: valid, rows: currentCut)
        XCTAssertNotEqual(currentDescriptor.checkpointID, valid.admittedAtCheckpointID)
        XCTAssertNoThrow(try ReconstructionDatabaseOwner.validateOperationDescriptor(currentDescriptor, rows: currentCut))
        XCTAssertThrowsError(try ReconstructionDatabaseOwner.validateOperationDescriptor(descriptor, rows: currentCut))
        XCTAssertEqual(advanced.job.featureScope, valid)
    }

}
