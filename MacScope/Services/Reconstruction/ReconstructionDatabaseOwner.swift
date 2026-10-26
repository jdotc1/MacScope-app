import Foundation

struct ReconstructionTaskTransition: Hashable, Sendable {
    let taskID: UUID
    let expectedState: ReconstructionTaskState
    let successorState: ReconstructionTaskState
    let diagnostic: ReconstructionDiagnostic?
    /// D13 decompiler backend recorded on a completed decompile/compare task.
    var decompileBackend: ReconstructionDecompileBackendRecord? = nil
}

struct ReconstructionCheckpointMutation: Sendable {
    let jobID: UUID
    let expectedParentCheckpointID: UUID
    let expectedParentCheckpointSHA256: String
    let expectedParentRevision: UInt64
    let evidence: [ReconstructionEvidenceRecord]
    let evidenceRelations: [ReconstructionEvidenceRelation]
    let evidenceGaps: [ReconstructionEvidenceGap]
    let toolReceipts: [ReconstructionToolReceipt]
    let modelReceipts: [ReconstructionModelReceipt]
    let finalResults: [ReconstructionFinalResultRecord]
    /// Newly discovered durable work. These records are committed atomically with the successor
    /// checkpoint; they never come from a live UI selection or a mutable analysis session.
    let newTasks: [ReconstructionTaskRecord]
    let taskTransitions: [ReconstructionTaskTransition]
    let freshnessAuthority: ReconstructionFreshnessAuthority
    let successorCheckpoint: ReconstructionCheckpoint
    /// Durable pause authority written atomically with `successorCheckpoint` and the job row.
    /// It is required exactly when the successor coordinator state is `.paused`.
    let successorPauseContext: ReconstructionJobPauseContext?
    /// Transient exact load snapshots; admitted into ordinary image rows by the same transaction.
    let analysisImports: [ReconstructionLoadedImageAdmission]

    init(
        jobID: UUID,
        expectedParentCheckpointID: UUID,
        expectedParentCheckpointSHA256: String,
        expectedParentRevision: UInt64,
        evidence: [ReconstructionEvidenceRecord],
        evidenceRelations: [ReconstructionEvidenceRelation],
        evidenceGaps: [ReconstructionEvidenceGap] = [],
        toolReceipts: [ReconstructionToolReceipt],
        modelReceipts: [ReconstructionModelReceipt],
        finalResults: [ReconstructionFinalResultRecord] = [],
        newTasks: [ReconstructionTaskRecord] = [],
        taskTransitions: [ReconstructionTaskTransition],
        freshnessAuthority: ReconstructionFreshnessAuthority,
        successorCheckpoint: ReconstructionCheckpoint,
        successorPauseContext: ReconstructionJobPauseContext? = nil,
        analysisImports: [ReconstructionLoadedImageAdmission] = []
    ) {
        self.jobID = jobID
        self.expectedParentCheckpointID = expectedParentCheckpointID
        self.expectedParentCheckpointSHA256 = expectedParentCheckpointSHA256
        self.expectedParentRevision = expectedParentRevision
        self.evidence = evidence
        self.evidenceRelations = evidenceRelations
        self.evidenceGaps = evidenceGaps
        self.toolReceipts = toolReceipts
        self.modelReceipts = modelReceipts
        self.finalResults = finalResults
        self.newTasks = newTasks
        self.taskTransitions = taskTransitions
        self.freshnessAuthority = freshnessAuthority
        self.successorCheckpoint = successorCheckpoint
        self.successorPauseContext = successorPauseContext
        self.analysisImports = analysisImports
    }
}

/// U06 admission request. The scope carries the checkpoint identity it was read at.
struct ReconstructionFeatureScopeAdmission: Sendable {
    let jobID: UUID
    let scope: ReconstructionFeatureScope
    let freshnessAuthority: ReconstructionFreshnessAuthority
}

struct ReconstructionCommittedFeatureScope: Hashable, Sendable {
    let state: ReconstructionWorkspaceState
    let job: ReconstructionJobRecord
    let commitSequence: UInt64
    /// F3: the durable job/task lifecycle timestamps after this commit (not part of `state`).
    var lifecycle: ReconstructionLifecycleTimestamps = .empty

    init(state: ReconstructionWorkspaceState, job: ReconstructionJobRecord, commitSequence: UInt64 = 0) {
        self.state = state
        self.job = job
        self.commitSequence = commitSequence
    }
}

struct ReconstructionCorpusMutation: Sendable {
    let projectID: UUID
    let expectedCurrentManifestSHA256: String?
    let successorManifest: ReconstructionCorpusManifest
    let attachmentSources: [ReconstructionAttachmentSource]
}

struct ReconstructionInitialJobMutation: Hashable, Sendable {
    let jobID: UUID
    let projectID: UUID
    let selectedOccurrenceIDs: [ReconstructionArtifactOccurrenceID]
    let objective: String
    let budget: ReconstructionJobBudget
    let focus: ReconstructionSubjectCoordinate?
    let sourceProfileID: String?

    init(jobID: UUID, projectID: UUID,
         selectedOccurrenceIDs: [ReconstructionArtifactOccurrenceID], objective: String,
         budget: ReconstructionJobBudget, focus: ReconstructionSubjectCoordinate? = nil,
         sourceProfileID: String? = nil) {
        self.jobID = jobID
        self.projectID = projectID
        self.selectedOccurrenceIDs = selectedOccurrenceIDs
        self.objective = objective
        self.budget = budget
        self.focus = focus
        self.sourceProfileID = sourceProfileID
    }
}

struct ReconstructionCommittedInitialJob: Hashable, Sendable {
    let state: ReconstructionWorkspaceState
    let job: ReconstructionJobRecord
    let checkpoint: ReconstructionCheckpoint
    let commitSequence: UInt64
    /// F3: the durable job/task lifecycle timestamps after this commit (not part of `state`).
    var lifecycle: ReconstructionLifecycleTimestamps = .empty

    init(
        state: ReconstructionWorkspaceState,
        job: ReconstructionJobRecord,
        checkpoint: ReconstructionCheckpoint,
        commitSequence: UInt64 = 0
    ) {
        self.state = state
        self.job = job
        self.checkpoint = checkpoint
        self.commitSequence = commitSequence
    }
}

struct ReconstructionCommittedCorpus: Sendable {
    let state: ReconstructionWorkspaceState
    let attachmentSources: [ReconstructionAttachmentSource]
    let commitSequence: UInt64
    /// F3: the durable job/task lifecycle timestamps after this commit (not part of `state`).
    var lifecycle: ReconstructionLifecycleTimestamps = .empty

    init(
        state: ReconstructionWorkspaceState,
        attachmentSources: [ReconstructionAttachmentSource],
        commitSequence: UInt64 = 0
    ) {
        self.state = state
        self.attachmentSources = attachmentSources
        self.commitSequence = commitSequence
    }
}

struct ReconstructionCommittedCheckpoint: Hashable, Sendable {
    let state: ReconstructionWorkspaceState
    let checkpoint: ReconstructionCheckpoint
    let idempotentToolReceiptIDs: [UUID]
    let idempotentModelReceiptIDs: [UUID]
    let commitSequence: UInt64
    /// F3: the durable job/task lifecycle timestamps after this commit (not part of `state`).
    var lifecycle: ReconstructionLifecycleTimestamps = .empty

    init(
        state: ReconstructionWorkspaceState,
        checkpoint: ReconstructionCheckpoint,
        idempotentToolReceiptIDs: [UUID],
        idempotentModelReceiptIDs: [UUID],
        commitSequence: UInt64 = 0
    ) {
        self.state = state
        self.checkpoint = checkpoint
        self.idempotentToolReceiptIDs = idempotentToolReceiptIDs
        self.idempotentModelReceiptIDs = idempotentModelReceiptIDs
        self.commitSequence = commitSequence
    }
}

enum ReconstructionDatabaseOwnerError: Error, Equatable, Sendable {
    case revoked
    case databaseFileMoved
}

private final class ReconstructionCommitSequencer: @unchecked Sendable {
    private struct Scope: Hashable {
        let databaseIdentity: String
        let workspaceID: UUID
    }

    private let lock = NSLock()
    private var sequencesByScope: [Scope: UInt64] = [:]

    func commit<Value>(
        databaseIdentity: String,
        workspaceID: UUID,
        operation: () throws -> Value
    ) throws -> (value: Value, sequence: UInt64) {
        try lock.withLock {
            let scope = Scope(
                databaseIdentity: databaseIdentity,
                workspaceID: workspaceID
            )
            let current = sequencesByScope[scope] ?? 0
            let (next, overflow) = current.addingReportingOverflow(1)
            guard !overflow else {
                throw WorkspaceDatabase.DatabaseError.reconstructionStateInvalid(
                    "database owner commit sequence exhausted"
                )
            }
            let value = try operation()
            sequencesByScope[scope] = next
            return (value, next)
        }
    }
}

/// Read-only facts at one exact committed cut. No execution API accepts this value, and it
/// cannot be persisted or reused to advance a job. A later read must re-enter the database owner.
struct ReconstructionOperationAdmissionSnapshot: Hashable, Sendable {
    let workspaceID: UUID
    let descriptor: ReconstructionOperationDescriptor

    fileprivate init(workspaceID: UUID, descriptor: ReconstructionOperationDescriptor) {
        self.workspaceID = workspaceID
        self.descriptor = descriptor
    }
}

/// The product-side serialization boundary for durable reconstruction mutations. Workers and
/// model providers exchange immutable DTOs; only this actor is allowed to advance a checkpoint.
actor ReconstructionDatabaseOwner {
    private static let commitSequencer = ReconstructionCommitSequencer()
    private var database: WorkspaceDatabase?
    private var databaseAuthorityValidator: (@Sendable () throws -> Void)?
    private var databaseAuthorityPostvalidator: (@Sendable () throws -> Void)?

    init(
        database: WorkspaceDatabase,
        attachmentVaultRootURL: URL? = nil,
        databaseAuthorityValidator: @escaping @Sendable () throws -> Void = {},
        databaseAuthorityPostvalidator: @escaping @Sendable () throws -> Void = {}
    ) {
        self.database = database
        self.databaseAuthorityValidator = databaseAuthorityValidator
        self.databaseAuthorityPostvalidator = databaseAuthorityPostvalidator
        if let attachmentVaultRootURL {
            database.configureReconstructionAttachmentVault(
                rootURL: attachmentVaultRootURL
            )
        }
    }

    /// Permanently closes this owner and waits for actor quiescence. All database operations are
    /// synchronous actor turns, so when this method returns any earlier operation has finished and
    /// no later operation can enter SQLite or the attachment vault through this owner. Clearing the
    /// owner-held database and validator references also releases the runtime lease captured by the
    /// validator, allowing the physical sidecar to close and be discarded.
    func revoke() {
        database = nil
        databaseAuthorityValidator = nil
        databaseAuthorityPostvalidator = nil
    }

    func load(workspaceID: UUID) throws -> ReconstructionWorkspaceState {
        try withActiveDatabase { database in
            try database.loadReconstructionState(workspaceID: workspaceID)
        }
    }

    func lifecycle(workspaceID: UUID) throws -> ReconstructionLifecycleTimestamps {
        try withActiveDatabase { database in
            try database.reconstructionLifecycleTimestamps(workspaceID: workspaceID)
        }
    }

    func reconstructionProjectionSnapshotForTesting(
        workspaceID: UUID
    ) throws -> [String] {
        try withActiveDatabase { database in
            try database.reconstructionProjectionSnapshotForTesting(workspaceID: workspaceID)
        }
    }

    func commitCorpus(
        workspaceID: UUID,
        mutation: ReconstructionCorpusMutation
    ) throws -> ReconstructionCommittedCorpus {
        try withActiveDatabase { database in
            let sequenced = try Self.commitSequencer.commit(
                databaseIdentity: database.reconstructionCommitSequencingIdentity,
                workspaceID: workspaceID
            ) {
                let durableSources = try database.publishDurableReconstructionAttachmentSources(
                    mutation.attachmentSources,
                    for: mutation.successorManifest
                )
                return try database.commitReconstructionCorpus(
                    workspaceID: workspaceID,
                    mutation: ReconstructionCorpusMutation(
                        projectID: mutation.projectID,
                        expectedCurrentManifestSHA256: mutation.expectedCurrentManifestSHA256,
                        successorManifest: mutation.successorManifest,
                        attachmentSources: durableSources
                    )
                )
            }
            var committed = ReconstructionCommittedCorpus(
                state: sequenced.value.state,
                attachmentSources: sequenced.value.attachmentSources,
                commitSequence: sequenced.sequence
            )
            committed.lifecycle = sequenced.value.lifecycle
            return committed
        }
    }

    func commitInitialJob(
        workspaceID: UUID,
        mutation: ReconstructionInitialJobMutation
    ) throws -> ReconstructionCommittedInitialJob {
        try withActiveDatabase { database in
            let sequenced = try Self.commitSequencer.commit(
                databaseIdentity: database.reconstructionCommitSequencingIdentity,
                workspaceID: workspaceID
            ) {
                try database.commitInitialReconstructionJob(
                    workspaceID: workspaceID,
                    mutation: mutation
                )
            }
            var committed = ReconstructionCommittedInitialJob(
                state: sequenced.value.state,
                job: sequenced.value.job,
                checkpoint: sequenced.value.checkpoint,
                commitSequence: sequenced.sequence
            )
            committed.lifecycle = sequenced.value.lifecycle
            return committed
        }
    }

    func admitFeatureScope(
        workspaceID: UUID,
        admission: ReconstructionFeatureScopeAdmission
    ) throws -> ReconstructionCommittedFeatureScope {
        try withActiveDatabase { database in
            let sequenced = try Self.commitSequencer.commit(
                databaseIdentity: database.reconstructionCommitSequencingIdentity,
                workspaceID: workspaceID
            ) {
                try database.admitReconstructionFeatureScope(
                    workspaceID: workspaceID,
                    admission: admission
                )
            }
            var committed = ReconstructionCommittedFeatureScope(
                state: sequenced.value.state,
                job: sequenced.value.job,
                commitSequence: sequenced.sequence
            )
            committed.lifecycle = sequenced.value.lifecycle
            return committed
        }
    }

    func availableDurableAttachmentSources(
        workspaceID: UUID
    ) throws -> [ReconstructionAttachmentSource] {
        try withActiveDatabase { database in
            try database.availableDurableReconstructionAttachmentSources(
                workspaceID: workspaceID
            )
        }
    }

    /// Captures every durable row and authority token for one production round while this actor
    /// owns the database boundary. Attachment verification and canonical projection deliberately
    /// happen only after these immutable rows leave actor isolation.
    func captureProductionRoundRows(
        workspaceID: UUID,
        jobID: UUID
    ) throws -> ReconstructionProductionRoundRows {
        try withActiveDatabase { database in
            try database.captureReconstructionProductionRoundRows(
                workspaceID: workspaceID,
                jobID: jobID
            )
        }
    }

    /// Initial job creation cannot require an observation that the job has not captured yet.
    /// Bind a descriptor only after capture, under the same current database/path authority.
    func captureOperationAdmission(
        workspaceID: UUID, descriptor: ReconstructionOperationDescriptor
    ) throws -> ReconstructionOperationAdmissionSnapshot {
        try descriptor.validateShape()
        return try withActiveDatabase { database in
            let rows = try database.captureReconstructionProductionRoundRows(
                workspaceID: workspaceID, jobID: descriptor.jobID)
            try Self.validateOperationDescriptor(descriptor, rows: rows)
            return ReconstructionOperationAdmissionSnapshot(workspaceID: workspaceID, descriptor: descriptor)
        }
    }

    /// Pure validation for the owner's immutable rows, also exercised with synthetic test cuts.
    /// Returning successfully does not mint an admission snapshot or an execution capability.
    nonisolated static func validateOperationDescriptor(
        _ descriptor: ReconstructionOperationDescriptor, rows: ReconstructionProductionRoundRows
    ) throws {
        try descriptor.validateShape()
        let checkpoint = rows.checkpoint
        guard descriptor.projectID == rows.project.projectID,
              descriptor.jobID == rows.job.jobID,
              rows.job.reconstructionProjectID == descriptor.projectID,
              rows.job.sourceProfileID == descriptor.profileID,
              rows.job.currentCheckpointID == descriptor.checkpointID,
              checkpoint.jobID == descriptor.jobID, checkpoint.checkpointID == descriptor.checkpointID,
              checkpoint.revision == descriptor.checkpointRevision,
              checkpoint.canonicalSHA256 == descriptor.checkpointSHA256,
              checkpoint.corpusManifestSHA256 == descriptor.corpusManifestSHA256,
              checkpoint.evidenceFrontierSHA256 == descriptor.evidenceFrontierSHA256,
              rows.project.currentCorpusManifestSHA256 == descriptor.corpusManifestSHA256,
              rows.manifest.reconstructionProjectID == descriptor.projectID,
              rows.manifest.canonicalSHA256 == descriptor.corpusManifestSHA256,
              rows.freshnessAuthority.corpusManifestSHA256 == descriptor.corpusManifestSHA256 else {
            throw ReconstructionOperationAdmissionError.staleCut
        }
        try checkpoint.verifyCanonicalIdentity()
        if let focus = rows.job.focus {
            guard focus == .function(descriptor.function) || focus == .artifact(descriptor.function.artifact) else {
                throw ReconstructionOperationAdmissionError.invalidDescriptor
            }
        }
        if let scope = rows.job.featureScope {
            guard scope.projectID == descriptor.projectID, scope.jobID == descriptor.jobID,
                  scope.feature == descriptor.function,
                  scope.observationContract.sourceProfileID == descriptor.profileID,
                  scope.scenarios.count == 1,
                  scope.scenarios.contains(where: {
                      $0.oracleEvidenceID == descriptor.observation.evidenceID
                        && $0.suiteSHA256 == descriptor.observation.suiteSHA256
                  }),
                  Set(descriptor.evidenceIDs).isSubset(of: scope.citedEvidenceIDs),
                  Set(descriptor.dependencies.declaredArtifacts).isSubset(of: scope.declaredArtifacts) else {
                throw ReconstructionOperationAdmissionError.invalidDescriptor
            }
            try scope.validateScenarioBindings(recordsByID: Dictionary(
                rows.evidence.map { ($0.evidenceID, $0) }, uniquingKeysWith: { first, _ in first }))
        }
        let artifacts = Set(rows.manifest.artifacts.map {
            ReconstructionArtifactCoordinate(occurrenceID: $0.occurrenceID, contentIdentity: $0.contentIdentity)
        })
        let dependencies = descriptor.dependencies
        guard artifacts.contains(descriptor.function.artifact),
              Set(dependencies.declaredArtifacts).isSubset(of: artifacts),
              Set(dependencies.declaredArtifacts).isSubset(of: Set(rows.freshnessAuthority.currentArtifacts)) else {
            throw ReconstructionOperationAdmissionError.invalidDependencies
        }
        let projection = try ReconstructionEvidenceProjector().project(records: rows.evidence,
            relations: rows.evidenceRelations.filter { $0.kind != .resolvesGap }, authority: rows.freshnessAuthority)
        var classifications: [UUID: ReconstructionEvidenceClassification] = [:]
        for projected in projection.records {
            guard classifications.updateValue(projected.classification,
                forKey: projected.record.evidenceID) == nil else {
                throw ReconstructionOperationAdmissionError.invalidEvidence
            }
        }
        // Reuse the existing frontier contract; do not trust raw acceptedCurrent flags or a
        // caller's plausible checkpoint digest when the projected cut has changed.
        let cut = try ReconstructionEvidenceCut(corpusManifestSHA256: rows.manifest.canonicalSHA256,
            records: rows.evidence, relations: rows.evidenceRelations, gaps: rows.evidenceGaps,
            frontierSHA256: checkpoint.evidenceFrontierSHA256,
            projectedClassificationsByEvidenceID: classifications,
            checkpointRevisionsByID: rows.checkpointRevisionsByID)
        let byID = Dictionary(uniqueKeysWithValues: cut.records.map { ($0.evidenceID, $0) })
        for id in descriptor.evidenceIDs {
            guard let record = byID[id], classifications[id] == .acceptedCurrent,
                  record.supersededByEvidenceID == nil else {
                throw ReconstructionOperationAdmissionError.invalidEvidence
            }
            switch record.subject {
            case .function(let function):
                guard function == descriptor.function else { throw ReconstructionOperationAdmissionError.invalidEvidence }
            case .artifact(let artifact):
                guard dependencies.declaredArtifacts.contains(artifact) else {
                    throw ReconstructionOperationAdmissionError.invalidEvidence
                }
            case .image: throw ReconstructionOperationAdmissionError.invalidEvidence
            }
        }
        let candidates = cut.records.filter {
            $0.creatingJobID == descriptor.jobID && $0.subject == .function(descriptor.function)
                && $0.operationID == ReconstructionSourceOracleEvidence.operationID
                && classifications[$0.evidenceID] == .acceptedCurrent
        }
        guard candidates.count == 1, let record = candidates.first,
              record.evidenceID == descriptor.observation.evidenceID,
              record.payloadSHA256 == descriptor.observation.payloadSHA256,
              let task = rows.tasks.first(where: { $0.identity.taskID == record.creatingTaskID }),
              let receipt = rows.toolReceipts.first(where: { $0.receiptID == record.toolReceiptID }),
              let originalCheckpoint = ([checkpoint] + rows.checkpointHistory).first(where: {
                  $0.checkpointID == record.creatingCheckpointID
              }) else { throw ReconstructionOperationAdmissionError.invalidObservation }
        let oracle = try ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(payload: record.payload)
        guard oracle.profileID == descriptor.profileID, oracle.projectID == descriptor.projectID,
              oracle.jobID == descriptor.jobID, oracle.function == descriptor.function,
              oracle.suiteSHA256 == descriptor.observation.suiteSHA256,
              Set(oracle.evidenceIDs).isSubset(of: Set(descriptor.evidenceIDs)) else {
            throw ReconstructionOperationAdmissionError.invalidObservation
        }
        let execution = oracle.execution
        guard dependencies.compilerSHA256 == execution.compilerSHA256,
              dependencies.sdkIdentitySHA256 == execution.sdkIdentitySHA256,
              dependencies.harnessSHA256 == execution.harnessSHA256,
              dependencies.compileProfileSHA256 == execution.compileProfileSHA256,
              dependencies.compileArgumentsSHA256 == execution.compileArgumentsSHA256,
              dependencies.executionArgumentsSHA256 == execution.executionArgumentsSHA256 else {
            throw ReconstructionOperationAdmissionError.invalidDependencies
        }
        _ = try ReconstructionSourceOracleEvidence.validate(record: record, context: .init(
            authority: .init(projectID: oracle.projectID, jobID: oracle.jobID, function: oracle.function,
                execution: execution, evidenceIDs: oracle.evidenceIDs),
            task: task, checkpoint: originalCheckpoint, toolReceipt: receipt,
            expectedRequestIdentitySHA256: receipt.requestIdentitySHA256, expectedProducer: receipt.producer,
            committedEvidenceCut: cut.records))
    }

    /// Natural transient projection for the first scalar scope. The caller must run the shared
    /// current-cut validator before persisting; constructing this DTO grants no authority.
    nonisolated static func operationDescriptor(
        for scope: ReconstructionFeatureScope, rows: ReconstructionProductionRoundRows
    ) throws -> ReconstructionOperationDescriptor {
        guard scope.scenarios.count == 1, let scenario = scope.scenarios.first,
              let record = rows.evidence.first(where: { $0.evidenceID == scenario.oracleEvidenceID }) else {
            throw ReconstructionOperationAdmissionError.invalidObservation
        }
        try scope.validateScenarioBindings(recordsByID: Dictionary(
            rows.evidence.map { ($0.evidenceID, $0) }, uniquingKeysWith: { first, _ in first }))
        let oracle = try ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(payload: record.payload)
        let execution = oracle.execution
        return ReconstructionOperationDescriptor(version: ReconstructionOperationDescriptor.version,
            profileID: scope.observationContract.sourceProfileID, projectID: scope.projectID,
            jobID: scope.jobID, function: scope.feature, checkpointID: rows.checkpoint.checkpointID,
            checkpointRevision: rows.checkpoint.revision, checkpointSHA256: rows.checkpoint.canonicalSHA256,
            corpusManifestSHA256: rows.checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: rows.checkpoint.evidenceFrontierSHA256,
            evidenceIDs: scope.acceptedEvidenceIDs,
            observation: .init(contractID: ReconstructionSourceExecutionTaskContract.oracle,
                evidenceID: record.evidenceID, payloadSHA256: record.payloadSHA256, suiteSHA256: scenario.suiteSHA256),
            dependencies: .init(compilerSHA256: execution.compilerSHA256,
                sdkIdentitySHA256: execution.sdkIdentitySHA256, harnessSHA256: execution.harnessSHA256,
                compileProfileSHA256: execution.compileProfileSHA256,
                compileArgumentsSHA256: execution.compileArgumentsSHA256,
                executionArgumentsSHA256: execution.executionArgumentsSHA256,
                declaredArtifacts: scope.declaredArtifacts.sorted { $0.occurrenceID.rawValue.uuidString < $1.occurrenceID.rawValue.uuidString }))
    }

    func commit(
        _ mutation: ReconstructionCheckpointMutation
    ) throws -> ReconstructionCommittedCheckpoint {
        try withActiveDatabase { database in
            let workspaceID = try database.reconstructionWorkspaceID(
                containingJobID: mutation.jobID
            )
            return try Self.commitCheckpoint(
                database: database,
                workspaceID: workspaceID,
                mutation: mutation
            )
        }
    }

    func commit(
        workspaceID: UUID,
        mutation: ReconstructionCheckpointMutation
    ) throws -> ReconstructionCommittedCheckpoint {
        try withActiveDatabase { database in
            try Self.commitCheckpoint(
                database: database,
                workspaceID: workspaceID,
                mutation: mutation
            )
        }
    }

    private func activeDatabase() throws -> WorkspaceDatabase {
        guard let database, let databaseAuthorityValidator,
              databaseAuthorityPostvalidator != nil else {
            throw ReconstructionDatabaseOwnerError.revoked
        }
        try databaseAuthorityValidator()
        guard try !database.reconstructionMainDatabaseFileHasMoved() else {
            throw ReconstructionDatabaseOwnerError.databaseFileMoved
        }
        return database
    }

    /// Executes one complete owner operation between path-identity checks. A failed operation
    /// remains the primary error even if the post-check also fails; a successful operation is not
    /// released to its caller unless the post-check proves the same bound sidecar authority.
    // Internal so the topic-scoped replay journal extension uses the same before/after authority
    // fence. It does not expose the database or a second persistence owner to callers.
    func withActiveDatabase<Value>(
        _ operation: (WorkspaceDatabase) throws -> Value
    ) throws -> Value {
        let database = try activeDatabase()
        let result: Result<Value, Error>
        do {
            result = .success(try operation(database))
        } catch {
            result = .failure(error)
        }
        switch result {
        case .success(let value):
            try validatePostoperationAuthority(database: database)
            return value
        case .failure(let primaryError):
            do {
                try validatePostoperationAuthority(database: database)
            } catch {
                // The operation's error is the durable semantic. The post-check still ran, but a
                // path-identity error must not erase the original database/vault diagnostic.
            }
            throw primaryError
        }
    }

    private func activePostvalidator() throws -> @Sendable () throws -> Void {
        guard let databaseAuthorityPostvalidator else {
            throw ReconstructionDatabaseOwnerError.revoked
        }
        return databaseAuthorityPostvalidator
    }

    private func validatePostoperationAuthority(
        database: WorkspaceDatabase
    ) throws {
        guard try !database.reconstructionMainDatabaseFileHasMoved() else {
            throw ReconstructionDatabaseOwnerError.databaseFileMoved
        }
        try activePostvalidator()()
    }

    private static func commitCheckpoint(
        database: WorkspaceDatabase,
        workspaceID: UUID,
        mutation: ReconstructionCheckpointMutation
    ) throws -> ReconstructionCommittedCheckpoint {
        let sequenced = try commitSequencer.commit(
            databaseIdentity: database.reconstructionCommitSequencingIdentity,
            workspaceID: workspaceID
        ) {
            try database.commitReconstructionCheckpoint(
                workspaceID: workspaceID,
                mutation: mutation
            )
        }
        var committed = ReconstructionCommittedCheckpoint(
            state: sequenced.value.state,
            checkpoint: sequenced.value.checkpoint,
            idempotentToolReceiptIDs: sequenced.value.idempotentToolReceiptIDs,
            idempotentModelReceiptIDs: sequenced.value.idempotentModelReceiptIDs,
            commitSequence: sequenced.sequence
        )
        committed.lifecycle = sequenced.value.lifecycle
        return committed
    }
}
