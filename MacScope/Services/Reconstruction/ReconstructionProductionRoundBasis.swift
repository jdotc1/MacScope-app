import Foundation

enum ReconstructionProductionRoundBasisError: Error, Equatable, Sendable {
    case jobNotFound
    case invalidCommittedAuthority
    case staleWorkspaceAnalysis
    case attachmentAuthorityMismatch
    case budgetExceeded
    case duplicateRoundID
    case unknownRoundID
    case registryCapacityExceeded
}

/// Raw immutable rows captured under database-owner isolation. Expensive canonical projection and
/// attachment byte verification intentionally happen only after this value leaves the actor.
struct ReconstructionProductionRoundRows: Sendable {
    let workspaceID: UUID
    let project: ReconstructionProjectRecord
    let manifest: ReconstructionCorpusManifest
    let job: ReconstructionJobRecord
    let checkpoint: ReconstructionCheckpoint
    let tasks: [ReconstructionTaskRecord]
    let toolReceipts: [ReconstructionToolReceipt]
    let modelReceipts: [ReconstructionModelReceipt]
    let taskCompletionAuthorities: [ReconstructionProductionTaskCompletionAuthority]
    let attachmentSources: [ReconstructionAttachmentSource]
    let evidence: [ReconstructionEvidenceRecord]
    let evidenceRelations: [ReconstructionEvidenceRelation]
    let evidenceGaps: [ReconstructionEvidenceGap]
    let checkpointRevisionsByID: [UUID: UInt64]
    let freshnessAuthority: ReconstructionFreshnessAuthority
    var checkpointHistory: [ReconstructionCheckpoint] = []
}

/// One project- and job-scoped read cut captured by `ReconstructionDatabaseOwner` in a single
/// actor turn. It contains only immutable DTOs and verified attachment handles; no database,
/// Store, or live analysis reference can cross into a worker or model call.
struct ReconstructionProductionRoundBasis: Sendable {
    static let maximumRegisteredRounds = 32

    let workspaceID: UUID
    let project: ReconstructionProjectRecord
    let manifest: ReconstructionCorpusManifest
    let job: ReconstructionJobRecord
    let checkpoint: ReconstructionCheckpoint
    let tasks: [ReconstructionTaskRecord]
    let toolReceipts: [ReconstructionToolReceipt]
    let modelReceipts: [ReconstructionModelReceipt]
    let taskCompletionAuthorities: [ReconstructionProductionTaskCompletionAuthority]
    let attachmentSources: [ReconstructionAttachmentSource]
    let evidenceCut: ReconstructionEvidenceCut
    let freshnessAuthority: ReconstructionFreshnessAuthority
    let snapshot: ReconstructionJobOrchestrationSnapshot
    let checkpointHistory: [ReconstructionCheckpoint]

    init(rows: ReconstructionProductionRoundRows) throws {
        try WorkspaceDatabase.validateReconstructionProductionAttachmentSources(
            rows.attachmentSources
        )
        let classificationProjection = try ReconstructionEvidenceProjector().project(
            records: rows.evidence,
            relations: rows.evidenceRelations.filter { $0.kind != .resolvesGap },
            authority: rows.freshnessAuthority
        )
        var classifications: [UUID: ReconstructionEvidenceClassification] = [:]
        for projected in classificationProjection.records {
            guard classifications.updateValue(
                projected.classification,
                forKey: projected.record.evidenceID
            ) == nil else {
                throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
            }
        }
        let evidenceCut = try ReconstructionEvidenceCut(
            corpusManifestSHA256: rows.manifest.canonicalSHA256,
            records: rows.evidence,
            relations: rows.evidenceRelations,
            gaps: rows.evidenceGaps,
            frontierSHA256: rows.checkpoint.evidenceFrontierSHA256,
            projectedClassificationsByEvidenceID: classifications,
            checkpointRevisionsByID: rows.checkpointRevisionsByID
        )
        var terminalStates: [UUID: ReconstructionTaskState] = [:]
        var terminalRevisions: [UUID: UInt64] = [:]
        func recordTerminalState(
            taskID: UUID,
            receiptState: ReconstructionReceiptTerminalState,
            revision: UInt64
        ) throws {
            let state: ReconstructionTaskState = switch receiptState {
            case .completed, .truncated: .completed
            case .failed: .failed
            case .cancelled: .cancelled
            }
            if let priorRevision = terminalRevisions[taskID], priorRevision > revision { return }
            if terminalRevisions[taskID] == revision,
               let existing = terminalStates[taskID], existing != state {
                throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
            }
            terminalStates[taskID] = state
            terminalRevisions[taskID] = revision
        }
        for receipt in rows.toolReceipts {
            try recordTerminalState(
                taskID: receipt.taskID,
                receiptState: receipt.terminalState,
                revision: receipt.checkpointRevision
            )
        }
        for receipt in rows.modelReceipts {
            try recordTerminalState(
                taskID: receipt.taskID,
                receiptState: receipt.terminalState,
                revision: receipt.checkpointRevision
            )
        }
        guard let creationOrdinal = rows.job.creationOrdinal else {
            throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
        }
        let consecutiveModelRoundsWithoutEvidence = try
            ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: rows.job.jobID,
                    tasks: rows.tasks,
                    toolReceipts: rows.toolReceipts,
                    modelReceipts: rows.modelReceipts,
                    taskCompletionAuthorities: rows.taskCompletionAuthorities
                )
        let snapshot = ReconstructionJobOrchestrationSnapshot(
            jobID: rows.job.jobID,
            jobCreationOrder: creationOrdinal,
            checkpointID: rows.checkpoint.checkpointID,
            checkpointRevision: rows.checkpoint.revision,
            checkpointCorpusManifestSHA256: rows.checkpoint.corpusManifestSHA256,
            checkpointEvidenceFrontierSHA256: rows.checkpoint.evidenceFrontierSHA256,
            currentCorpusManifestSHA256: rows.manifest.canonicalSHA256,
            evidenceFrontierSHA256: evidenceCut.frontierSHA256,
            currentDurableJobState: rows.job.state,
            pauseContext: rows.job.pauseContext,
            maximumRoundsWithoutEvidence: rows.job.budget.maxRounds,
            tasks: rows.tasks,
            terminalReceiptStatesByTaskID: terminalStates,
            consecutiveModelRoundsWithoutEvidence: consecutiveModelRoundsWithoutEvidence,
            terminalReceiptCheckpointRevisionsByTaskID: terminalRevisions
        )
        try self.init(
            workspaceID: rows.workspaceID,
            project: rows.project,
            manifest: rows.manifest,
            job: rows.job,
            checkpoint: rows.checkpoint,
            tasks: rows.tasks,
            toolReceipts: rows.toolReceipts,
            modelReceipts: rows.modelReceipts,
            taskCompletionAuthorities: rows.taskCompletionAuthorities,
            attachmentSources: rows.attachmentSources,
            evidenceCut: evidenceCut,
            freshnessAuthority: rows.freshnessAuthority,
            snapshot: snapshot,
            checkpointHistory: rows.checkpointHistory
        )
    }

    init(
        workspaceID: UUID,
        project: ReconstructionProjectRecord,
        manifest: ReconstructionCorpusManifest,
        job: ReconstructionJobRecord,
        checkpoint: ReconstructionCheckpoint,
        tasks: [ReconstructionTaskRecord],
        toolReceipts: [ReconstructionToolReceipt],
        modelReceipts: [ReconstructionModelReceipt],
        taskCompletionAuthorities: [ReconstructionProductionTaskCompletionAuthority] = [],
        attachmentSources: [ReconstructionAttachmentSource],
        evidenceCut: ReconstructionEvidenceCut,
        freshnessAuthority: ReconstructionFreshnessAuthority,
        snapshot: ReconstructionJobOrchestrationSnapshot,
        checkpointHistory: [ReconstructionCheckpoint] = []
    ) throws {
        let expectedConsecutiveModelRoundsWithoutEvidence = try
            ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: job.jobID,
                    tasks: tasks,
                    toolReceipts: toolReceipts,
                    modelReceipts: modelReceipts,
                    taskCompletionAuthorities: taskCompletionAuthorities
                )
        guard let persistedCreationOrder = job.creationOrdinal,
              job.reconstructionProjectID == project.projectID,
              project.currentCorpusManifestSHA256 == manifest.canonicalSHA256,
              manifest.reconstructionProjectID == project.projectID,
              job.currentCheckpointID == checkpoint.checkpointID,
              checkpoint.jobID == job.jobID,
              checkpoint.corpusManifestSHA256 == manifest.canonicalSHA256,
              checkpoint.evidenceFrontierSHA256 == evidenceCut.frontierSHA256,
              evidenceCut.corpusManifestSHA256 == manifest.canonicalSHA256,
              freshnessAuthority.corpusManifestSHA256 == manifest.canonicalSHA256,
              snapshot.jobID == job.jobID,
              snapshot.jobCreationOrder == persistedCreationOrder,
              snapshot.checkpointID == checkpoint.checkpointID,
              snapshot.checkpointRevision == checkpoint.revision,
              snapshot.checkpointCorpusManifestSHA256
                == checkpoint.corpusManifestSHA256,
              snapshot.checkpointEvidenceFrontierSHA256
                == checkpoint.evidenceFrontierSHA256,
              snapshot.currentCorpusManifestSHA256 == manifest.canonicalSHA256,
              snapshot.evidenceFrontierSHA256 == evidenceCut.frontierSHA256,
              snapshot.currentDurableJobState == job.state,
              snapshot.pauseContext == job.pauseContext,
              snapshot.maximumRoundsWithoutEvidence == job.budget.maxRounds,
              snapshot.consecutiveModelRoundsWithoutEvidence
                == expectedConsecutiveModelRoundsWithoutEvidence,
              snapshot.consecutiveModelRoundsWithoutEvidence >= 0,
              snapshot.tasks == tasks,
              Set(tasks.map(\.identity.taskID)).count == tasks.count,
              Set(toolReceipts.map(\.receiptID)).count == toolReceipts.count,
              Set(modelReceipts.map(\.receiptID)).count == modelReceipts.count,
              Set(taskCompletionAuthorities.map(\.taskID)).count
                == taskCompletionAuthorities.count,
              tasks.allSatisfy({ $0.identity.jobID == job.jobID }),
              toolReceipts.allSatisfy({ $0.jobID == job.jobID }),
              modelReceipts.allSatisfy({ $0.jobID == job.jobID }) else {
            throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
        }

        guard Set(checkpointHistory.map(\.checkpointID)).count == checkpointHistory.count,
              checkpointHistory.allSatisfy({ $0.jobID == job.jobID && $0.revision <= checkpoint.revision }) else {
            throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
        }
        for retained in checkpointHistory { try retained.verifyCanonicalIdentity() }
        let expectedIdentities = Set(manifest.artifacts.map(\.contentIdentity))
        let suppliedIdentities = attachmentSources.map(\.contentIdentity)
        guard Set(suppliedIdentities).count == suppliedIdentities.count,
              Set(suppliedIdentities) == expectedIdentities else {
            throw ReconstructionProductionRoundBasisError.attachmentAuthorityMismatch
        }
        let encodedAuthorityByteCount = try Self.totalEncodedByteCount([
            Self.encodedByteCount(project),
            Self.encodedByteCount(manifest),
            Self.encodedByteCount(job),
            checkpoint.canonicalEncodedByteCount,
            Self.encodedByteCount(tasks),
            Self.encodedByteCount(toolReceipts),
            Self.encodedByteCount(modelReceipts),
            Self.encodedByteCount(taskCompletionAuthorities),
            Self.encodedByteCount(evidenceCut),
            checkpointHistory.isEmpty ? 0 : Self.encodedByteCount(checkpointHistory),
        ])
        guard tasks.count <= job.budget.maxTasks,
              evidenceCut.records.count <= job.budget.maxEvidenceRecords,
              checkpoint.canonicalEncodedByteCount <= job.budget.maxEncodedBytes,
              encodedAuthorityByteCount <= job.budget.maxEncodedBytes else {
            throw ReconstructionProductionRoundBasisError.budgetExceeded
        }

        self.workspaceID = workspaceID
        self.project = project
        self.manifest = manifest
        self.job = job
        self.checkpoint = checkpoint
        self.tasks = tasks
        self.toolReceipts = toolReceipts
        self.modelReceipts = modelReceipts
        self.taskCompletionAuthorities = taskCompletionAuthorities.sorted {
            $0.taskID.uuidString.lowercased() < $1.taskID.uuidString.lowercased()
        }
        self.attachmentSources = attachmentSources.sorted {
            $0.contentIdentity.digest < $1.contentIdentity.digest
        }
        self.evidenceCut = evidenceCut
        self.freshnessAuthority = freshnessAuthority
        self.snapshot = snapshot
        self.checkpointHistory = checkpointHistory.sorted { $0.revision < $1.revision }
    }

    private static func encodedByteCount<Value: Encodable>(_ value: Value) throws -> UInt64 {
        let count = try ReconstructionCanonicalJSON.encode(value).count
        return UInt64(count)
    }

    private static func totalEncodedByteCount(_ counts: [UInt64]) throws -> UInt64 {
        var total: UInt64 = 0
        for count in counts {
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else {
                throw ReconstructionProductionRoundBasisError.budgetExceeded
            }
            total = next
        }
        return total
    }
}

/// Shared, bounded handoff between the cut provider and plan builder. A basis is retained only
/// across the model branch; deterministic pre-inference commits remove it immediately.
actor ReconstructionProductionRoundBasisRegistry {
    private struct Entry: Sendable {
        let basis: ReconstructionProductionRoundBasis
        let authority: ReconstructionToolAuthorityCut
        let objective: ReconstructionRequestObjective?
        let sourceOracleFunction: ReconstructionFunctionCoordinate?
        let sourceOracleRequested: Bool
        let transientAnalysis: ReconstructionTransientAnalysis?
    }

    private var entriesByRoundID: [UUID: Entry] = [:]

    init() {}

    init(
        basis: ReconstructionProductionRoundBasis,
        prepared: ReconstructionPreparedModelRound
    ) {
        entriesByRoundID[prepared.roundID] = Entry(
            basis: basis,
            authority: prepared.authority,
            objective: prepared.objective,
            sourceOracleFunction: prepared.sourceOracleFunction,
            sourceOracleRequested: prepared.sourceOracleRequested,
            transientAnalysis: prepared.transientAnalysis
        )
    }

    func register(
        _ basis: ReconstructionProductionRoundBasis,
        prepared: ReconstructionPreparedModelRound
    ) throws {
        let roundID = prepared.roundID
        guard entriesByRoundID[roundID] == nil else {
            throw ReconstructionProductionRoundBasisError.duplicateRoundID
        }
        guard entriesByRoundID.count
                < ReconstructionProductionRoundBasis.maximumRegisteredRounds else {
            throw ReconstructionProductionRoundBasisError.registryCapacityExceeded
        }
        guard prepared.evidenceCut == basis.evidenceCut,
              prepared.authority.roundID == roundID,
              prepared.authority.jobID == basis.job.jobID,
              prepared.authority.checkpointRevision == basis.checkpoint.revision,
              prepared.authority.corpusManifestSHA256 == basis.manifest.canonicalSHA256,
              prepared.authority.evidenceFrontierSHA256 == basis.evidenceCut.frontierSHA256 else {
            throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
        }
        entriesByRoundID[roundID] = Entry(
            basis: basis,
            authority: prepared.authority,
            objective: prepared.objective,
            sourceOracleFunction: prepared.sourceOracleFunction,
            sourceOracleRequested: prepared.sourceOracleRequested,
            transientAnalysis: prepared.transientAnalysis
        )
    }

    func basis(roundID: UUID) throws -> ReconstructionProductionRoundBasis {
        guard let basis = entriesByRoundID[roundID]?.basis else {
            throw ReconstructionProductionRoundBasisError.unknownRoundID
        }
        return basis
    }

    func basis(roundID: UUID, objective: ReconstructionRequestObjective?) throws
        -> ReconstructionProductionRoundBasis {
        guard let entry = entriesByRoundID[roundID], entry.objective == objective else {
            throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
        }
        return entry.basis
    }

    func basis(roundID: UUID, prepared: ReconstructionPreparedModelRound) throws
        -> ReconstructionProductionRoundBasis {
        guard prepared.roundID == roundID,
              let entry = entriesByRoundID[roundID],
              entry.authority == prepared.authority,
              entry.objective == prepared.objective,
              entry.sourceOracleFunction == prepared.sourceOracleFunction,
              entry.sourceOracleRequested == prepared.sourceOracleRequested,
              entry.transientAnalysis == prepared.transientAnalysis,
              prepared.evidenceCut == entry.basis.evidenceCut else {
            throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
        }
        return entry.basis
    }

    @discardableResult
    func remove(
        roundID: UUID,
        matching snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound
    ) -> ReconstructionProductionRoundBasis? {
        guard prepared.roundID == roundID,
              let entry = entriesByRoundID[roundID],
              entry.authority == prepared.authority,
              entry.objective == prepared.objective,
              entry.sourceOracleFunction == prepared.sourceOracleFunction,
              entry.sourceOracleRequested == prepared.sourceOracleRequested,
              entry.transientAnalysis == prepared.transientAnalysis,
              entry.basis.snapshot == snapshot,
              prepared.evidenceCut == entry.basis.evidenceCut,
              prepared.authority.roundID == roundID else {
            return nil
        }
        return entriesByRoundID.removeValue(forKey: roundID)?.basis
    }
}

protocol ReconstructionProductionPreparedRoundBuilding: Sendable {
    func makePreparedRound(
        from basis: ReconstructionProductionRoundBasis
    ) async throws -> ReconstructionPreparedModelRound
}

protocol ReconstructionProductionBatchScheduling: Sendable {
    func executeReadyTasks(
        _ tasks: [ReconstructionTaskRecord],
        authority: ReconstructionBatchAuthority,
        budget: ReconstructionBatchBudget,
        allowedTaskKinds: Set<ReconstructionTaskKind>?
    ) async throws -> [ReconstructionTerminalTaskResult]
}

extension ReconstructionProductionBatchScheduling {
    /// Preserve the unrestricted call through protocol existentials. The
    /// scheduler receives the complete graph without a task-kind stage filter.
    func executeReadyTasks(
        _ tasks: [ReconstructionTaskRecord],
        authority: ReconstructionBatchAuthority,
        budget: ReconstructionBatchBudget
    ) async throws -> [ReconstructionTerminalTaskResult] {
        try await executeReadyTasks(
            tasks, authority: authority, budget: budget, allowedTaskKinds: nil
        )
    }
}

protocol ReconstructionProductionControllableBatchScheduling:
    ReconstructionProductionBatchScheduling
{
    func pause(jobID: UUID) async
    func resume(jobID: UUID) async
    func retire(jobID: UUID) async
}

extension ReconstructionBatchScheduler:
    ReconstructionProductionControllableBatchScheduling
{}

protocol ReconstructionProductionBatchExecutionBuilding: Sendable {
    func makeScheduler(
        for basis: ReconstructionProductionRoundBasis,
        authority: ReconstructionBatchAuthority
    ) async throws -> any ReconstructionProductionBatchScheduling
}

enum ReconstructionProductionBatchExecutionControllerError: Error, Equatable, Sendable {
    case jobAuthorityMismatch(expected: UUID, actual: UUID)
    case paused(UUID)
    case retired(UUID)
    case constructionInProgress(UUID)
}

/// One job-scoped lifecycle controller with a fresh child scheduler for each immutable cut. The
/// session retains this actor for pause/resume/retire; the cut provider uses the same actor as its
/// execution factory. Replacing a cut only quiesces the previous child; the single job admission
/// is retired exactly once by `retireJobAuthority` when this controller is finally retired.
actor ReconstructionProductionBatchExecutionController:
    ReconstructionProductionBatchExecutionBuilding,
    ReconstructionJobSessionScheduling
{
    typealias Builder = @Sendable (
        ReconstructionProductionRoundBasis,
        ReconstructionBatchAuthority
    ) async throws -> any ReconstructionProductionControllableBatchScheduling
    typealias JobAuthorityRetirement = @Sendable () async -> Void

    private enum Lifecycle: Equatable {
        case active
        case paused
        case retired
    }

    nonisolated let durableJobID: UUID
    private let builder: Builder
    private let retireJobAuthority: JobAuthorityRetirement
    private var lifecycle: Lifecycle = .active
    private var isConstructing = false
    private var currentScheduler: (
        any ReconstructionProductionControllableBatchScheduling
    )?

    init(
        durableJobID: UUID,
        builder: @escaping Builder,
        retireJobAuthority: @escaping JobAuthorityRetirement
    ) {
        self.durableJobID = durableJobID
        self.builder = builder
        self.retireJobAuthority = retireJobAuthority
    }

    func makeScheduler(
        for basis: ReconstructionProductionRoundBasis,
        authority: ReconstructionBatchAuthority
    ) async throws -> any ReconstructionProductionBatchScheduling {
        guard basis.job.jobID == durableJobID else {
            throw ReconstructionProductionBatchExecutionControllerError
                .jobAuthorityMismatch(
                    expected: durableJobID,
                    actual: basis.job.jobID
                )
        }
        guard authority.jobID == durableJobID else {
            throw ReconstructionProductionBatchExecutionControllerError
                .jobAuthorityMismatch(
                    expected: durableJobID,
                    actual: authority.jobID
                )
        }
        switch lifecycle {
        case .active:
            break
        case .paused:
            throw ReconstructionProductionBatchExecutionControllerError.paused(durableJobID)
        case .retired:
            throw ReconstructionProductionBatchExecutionControllerError.retired(durableJobID)
        }
        guard !isConstructing else {
            throw ReconstructionProductionBatchExecutionControllerError
                .constructionInProgress(durableJobID)
        }
        isConstructing = true
        do {
            let candidate = try await builder(basis, authority)
            guard lifecycle == .active else {
                isConstructing = false
                await candidate.pause(jobID: durableJobID)
                throw lifecycle == .paused
                    ? ReconstructionProductionBatchExecutionControllerError.paused(durableJobID)
                    : ReconstructionProductionBatchExecutionControllerError.retired(durableJobID)
            }
            if let currentScheduler {
                self.currentScheduler = nil
                await currentScheduler.pause(jobID: durableJobID)
            }
            guard lifecycle == .active else {
                isConstructing = false
                await candidate.pause(jobID: durableJobID)
                throw lifecycle == .paused
                    ? ReconstructionProductionBatchExecutionControllerError.paused(durableJobID)
                    : ReconstructionProductionBatchExecutionControllerError.retired(durableJobID)
            }
            currentScheduler = candidate
            isConstructing = false
            return candidate
        } catch {
            isConstructing = false
            throw error
        }
    }

    func pause(jobID: UUID) async {
        guard jobID == durableJobID, lifecycle == .active else { return }
        lifecycle = .paused
        await currentScheduler?.pause(jobID: durableJobID)
    }

    func resume(jobID: UUID) async {
        guard jobID == durableJobID, lifecycle == .paused else { return }
        await currentScheduler?.resume(jobID: durableJobID)
        guard lifecycle == .paused else { return }
        lifecycle = .active
    }

    func retire(jobID: UUID) async {
        guard jobID == durableJobID, lifecycle != .retired else { return }
        lifecycle = .retired
        let scheduler = currentScheduler
        currentScheduler = nil
        await scheduler?.pause(jobID: durableJobID)
        await retireJobAuthority()
    }
}
